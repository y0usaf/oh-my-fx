const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const permission_gate = @import("../../core/permissions/permission_gate.zig");
const read_tracker = @import("../../core/workspace/read_tracker.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const write_file_impl = @import("write_file.zig");

const Allocator = std.mem.Allocator;

// Allow freshness snapshots for files larger than read_file can show the model.
const max_snapshot_file_bytes: usize = 10 * 1024 * 1024;
// Keep one tool result under common model input limits without a tokenizer.
const max_model_output_bytes: usize = 256 * 1024;
// Bound tiny-line files so one read cannot dominate a turn.
const max_line_count: usize = 2000;
const line_truncated_suffix = "... (line truncated)";

const whitespace = " \t\r\n";

/// Typed input for the built-in read_file tool.
pub const Input = struct {
    path: []u8,
    start_line: usize = 1,
    line_count: usize = tool_dispatch.default_max_read_file_lines,

    /// Frees the owned normalized path.
    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = .{ .path = &.{} };
    }
};

/// Decodes read_file JSON into an owned Input released by ToolInput.deinit.
pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_file arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_file arguments must be an object") };
    }

    const path_value = parsed.value.object.get("path") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_file requires string field \"path\"") };
    };
    if (path_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_file field \"path\" must be a string") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .path = try ctx.allocator.dupe(u8, path_value.string),
    };
    errdefer input.deinit(ctx.allocator);

    switch (try parseOptionalPositive(ctx.allocator, parsed.value.object, "start_line")) {
        .missing => {},
        .value => |value| input.start_line = value,
        .failure => |body| return .{ .failure = body },
    }
    switch (try parseOptionalPositive(ctx.allocator, parsed.value.object, "line_count")) {
        .missing => {},
        .value => |value| input.line_count = @min(value, max_line_count),
        .failure => |body| return .{ .failure = body },
    }

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

const PositiveParse = union(enum) {
    missing,
    value: usize,
    failure: []u8,
};

fn parseOptionalPositive(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) tool_dispatch.DispatchError!PositiveParse {
    const value = object.get(key) orelse return .missing;
    if (value != .integer or value.integer < 1) {
        return .{ .failure = try std.fmt.allocPrint(alloc, "read_file field \"{s}\" must be a positive integer", .{key}) };
    }
    return .{ .value = @intCast(value.integer) };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

/// Normalizes and validates the owned Input before permission checks.
pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const trimmed = std.mem.trim(u8, input.path, whitespace);
    try replacePath(ctx.allocator, input, trimmed);

    if (input.path.len == 0) {
        return try ctx.allocator.dupe(u8, "read_file field \"path\" must not be empty");
    }
    return null;
}

fn replacePath(alloc: Allocator, input: *Input, next: []const u8) tool_dispatch.DispatchError!void {
    if (std.mem.eql(u8, input.path, next)) return;
    const owned = try alloc.dupe(u8, next);
    replaceOwnedPath(alloc, input, owned);
}

fn replaceOwnedPath(alloc: Allocator, input: *Input, owned: []u8) void {
    alloc.free(input.path);
    input.path = owned;
}

/// Reads the validated file and returns an owned tool result body.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return readFileFailure(ctx.allocator, err, input.path);
    };

    const zio = io_mod.getIo();
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), target, .no_follow) catch |err| {
        return readFileFailure(
            ctx.allocator,
            if (err == error.DurablePathUnsafe) error.NotRegularFile else err,
            target,
        );
    };
    defer file.close(zio);

    const stat = file.stat(zio) catch |err| {
        return readFileFailure(ctx.allocator, err, target);
    };
    const truncated_by_size = stat.size > max_snapshot_file_bytes;
    const read_len: usize = @intCast(@min(stat.size, max_snapshot_file_bytes));
    const content = try arena.alloc(u8, read_len);
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(zio, &read_buf);
    const actual_len = readIntoBuffer(&reader.interface, content) catch |err| {
        return readFileFailure(ctx.allocator, err, target);
    };
    const text = content[0..actual_len];
    const rel = pathing.workspaceRelativePath(arena, ctx.workspace_root, target) catch target;

    if (!text_utils.isModelSafeText(text)) {
        tool_dispatch.reportToolResultMemory(ctx, .{
            .model_view_covers_full_file = false,
        });
        return .{ .success = try std.fmt.allocPrint(
            ctx.allocator,
            "<path>{s}</path>\n<content>binary or non-utf8 file omitted ({d} bytes)</content>",
            .{ rel, stat.size },
        ) };
    }

    var selected = input.*;
    selected.line_count = @min(selected.line_count, ctx.max_read_file_lines);

    var records: std.ArrayList(LineRecord) = .empty;
    defer freeLineRecords(arena, &records);
    const scan = try selectLinesFromContent(arena, text, &selected, ctx.max_read_file_line_len, &records);
    const snapshot_covers_full_file = !truncated_by_size and actual_len == stat.size;
    const model_view_covers_full_file = snapshot_covers_full_file and modelViewCoversFullFile(&selected, scan, records.items.len);
    try recordSuccessfulRead(ctx, target, stat, scan.content_hash, model_view_covers_full_file, snapshot_covers_full_file);
    tool_dispatch.reportToolResultMemory(ctx, .{
        .model_view_covers_full_file = model_view_covers_full_file,
    });

    return .{ .success = try formatReadOutput(ctx.allocator, rel, &selected, records.items, scan, snapshot_covers_full_file) };
}

fn readFileFailure(alloc: Allocator, err: anyerror, path: []const u8) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (tool_result_errors.isFilesystemAccessDenied(err)) {
        return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(alloc, "read_file", path, err) };
    }
    if (err == error.NotRegularFile) {
        const details = [_]tool_result_errors.Detail{
            .{ .name = "field", .value = .{ .string = "path" } },
            .{ .name = "path", .value = .{ .string = path } },
            .{ .name = "error", .value = .{ .string = @errorName(err) } },
        };
        return .{ .failure = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "read_file",
            .message = "read_file requires a regular file",
            .details = &details,
            .suggestion = "Use glob_files to inspect directory contents, then choose a regular file.",
        }) };
    }
    const details = [_]tool_result_errors.Detail{
        .{ .name = "field", .value = .{ .string = "path" } },
        .{ .name = "path", .value = .{ .string = path } },
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return .{ .failure = try tool_result_errors.toolExecutionFailureJson(alloc, .{
        .tool_name = "read_file",
        .message = "read_file failed",
        .details = &details,
        .suggestion = "Run glob_files to discover matching paths, or check the path relative to the workspace.",
    }) };
}

fn readIntoBuffer(reader: *std.Io.Reader, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try reader.readSliceShort(buffer[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}

const LineRecord = struct {
    number: usize,
    text: []u8,
};

const ReadScan = struct {
    total_lines: usize,
    content_hash: read_tracker.ContentHash,
    display_truncated: bool,
};

const DisplayBudget = struct {
    width: usize = 1,
    bytes: usize = 0,
};

const LineSelectionState = struct {
    alloc: Allocator,
    input: *const Input,
    max_line_len: usize,
    records: *std.ArrayList(LineRecord),
    display_truncated: bool = false,
    stop_display: bool = false,
    budget: DisplayBudget = .{},

    fn keepLine(self: *LineSelectionState, line_number: usize, text: []const u8) !void {
        if (self.stop_display) return;
        if (line_number < self.input.start_line) return;
        if (self.records.items.len >= self.input.line_count) {
            self.display_truncated = true;
            self.stop_display = true;
            return;
        }
        const width = digitCount(line_number);
        if (width > self.budget.width) {
            self.budget.bytes += self.records.items.len * (width - self.budget.width);
            self.budget.width = width;
        }
        const clipped_len = @min(text.len, self.max_line_len);
        const line_truncated = text.len > self.max_line_len;
        const display_len = clipped_len + if (line_truncated) line_truncated_suffix.len else 0;
        const rendered_bytes = self.budget.bytes + renderedLineBytes(self.budget.width, display_len);
        if (rendered_bytes > max_model_output_bytes) {
            self.display_truncated = true;
            self.stop_display = true;
            return;
        }
        const display_text = try self.alloc.alloc(u8, display_len);
        errdefer self.alloc.free(display_text);
        @memcpy(display_text[0..clipped_len], text[0..clipped_len]);
        if (line_truncated) {
            self.display_truncated = true;
            @memcpy(display_text[clipped_len..], line_truncated_suffix);
        }
        try self.records.append(self.alloc, .{
            .number = line_number,
            .text = display_text,
        });
        self.budget.bytes = rendered_bytes;
    }
};

fn selectLinesFromContent(
    alloc: Allocator,
    content: []const u8,
    input: *const Input,
    max_line_len: usize,
    records: *std.ArrayList(LineRecord),
) !ReadScan {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);

    var selection = LineSelectionState{
        .alloc = alloc,
        .input = input,
        .max_line_len = max_line_len,
        .records = records,
    };
    var line_number: usize = 1;
    var total_lines: usize = 0;

    var start: usize = 0;
    while (start < content.len) : (line_number += 1) {
        const end = std.mem.findScalarPos(u8, content, start, '\n') orelse content.len;
        const line = content[start..end];
        total_lines = line_number;
        try selection.keepLine(line_number, line);
        if (end == content.len) break;
        start = end + 1;
    }

    return .{
        .total_lines = total_lines,
        .content_hash = hasher.finalResult(),
        .display_truncated = selection.display_truncated,
    };
}

fn modelViewCoversFullFile(input: *const Input, scan: ReadScan, returned_lines: usize) bool {
    return !scan.display_truncated and input.start_line == 1 and returned_lines == scan.total_lines;
}

fn recordSuccessfulRead(
    ctx: tool_dispatch.DispatchContext,
    path: []const u8,
    stat: std.Io.File.Stat,
    content_hash: read_tracker.ContentHash,
    model_view_covers_full_file: bool,
    snapshot_covers_full_file: bool,
) tool_dispatch.DispatchError!void {
    const tracker = ctx.read_tracker orelse return;
    try tracker.record(path, .{
        .mtime_ns = stat.mtime.nanoseconds,
        .content_hash = content_hash,
        .model_view_covers_full_file = model_view_covers_full_file,
        .snapshot_covers_full_file = snapshot_covers_full_file,
    });
}

fn formatReadOutput(
    alloc: Allocator,
    rel: []const u8,
    input: *const Input,
    records: []const LineRecord,
    scan: ReadScan,
    snapshot_covers_full_file: bool,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("<path>{s}</path>\n<content>\n", .{rel}) catch return error.OutOfMemory;
    if (records.len > 0) {
        writeRecords(&out.writer, records) catch return error.OutOfMemory;
    } else if (scan.total_lines > 0 and input.start_line > scan.total_lines) {
        out.writer.print("... [start_line {d} is beyond end of file; total lines {d}]\n", .{ input.start_line, scan.total_lines }) catch return error.OutOfMemory;
    }

    const include_sentinel = !modelViewCoversFullFile(input, scan, records.len) or !snapshot_covers_full_file;
    if (include_sentinel and (records.len > 0 or scan.display_truncated)) {
        writeTruncationSentinel(&out.writer, records.len, scan.total_lines, snapshot_covers_full_file) catch return error.OutOfMemory;
    }
    out.writer.writeAll("</content>") catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

fn writeRecords(writer: *std.Io.Writer, records: []const LineRecord) !void {
    const width = digitCount(records[records.len - 1].number);
    try writeRecordsWithWidth(writer, records, width);
}

fn writeRecordsWithWidth(writer: *std.Io.Writer, records: []const LineRecord, width: usize) !void {
    for (records) |record| {
        try writer.print("{d}", .{record.number});
        var pad = width - digitCount(record.number);
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
        try writer.writeByte('\t');
        try writer.writeAll(record.text);
        try writer.writeByte('\n');
    }
}

fn writeTruncationSentinel(writer: *std.Io.Writer, shown_lines: usize, total_lines: usize, snapshot_covers_full_file: bool) !void {
    if (snapshot_covers_full_file) {
        try writer.print("... [showing {d} of {d} lines; use start_line/line_count to read more.]\n", .{ shown_lines, total_lines });
    } else {
        try writer.print("... [showing {d} of at least {d} lines; file snapshot was capped before EOF.]\n", .{ shown_lines, total_lines });
    }
}

fn renderedLineBytes(width: usize, text_len: usize) usize {
    return width + 1 + text_len + 1;
}

fn freeLineRecords(alloc: Allocator, records: *std.ArrayList(LineRecord)) void {
    for (records.items) |record| alloc.free(record.text);
    records.deinit(alloc);
}

fn digitCount(value: usize) usize {
    var n = value;
    var count: usize = 1;
    while (n >= 10) : (n /= 10) count += 1;
    return count;
}

/// Reports that read_file only observes filesystem state.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

/// Reports that read_file has no irreversible side effects.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const read_file_dispatch_tool = tool_dispatch.Tool{
    .name = "read_file",
    .description = "Read file dispatch test fixture.",
    .model_schema = .{
        .name = "read_file",
        .description = "Read file dispatch test fixture.",
    },
    .executor_kind = .read_file,
    .activity_kind = .read,
    .permission_target_kind = .path_existing,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

const write_file_dispatch_tool = tool_dispatch.Tool{
    .name = "write_file",
    .description = "Write file dispatch test fixture.",
    .model_schema = .{
        .name = "write_file",
        .description = "Write file dispatch test fixture.",
    },
    .executor_kind = .write_file,
    .activity_kind = .write,
    .requires_approval = true,
    .permission_target_kind = .path_create_parent,
    .decode = write_file_impl.decode,
    .validate = write_file_impl.validate,
    .call = write_file_impl.call,
    .take_file_mutation_input_fn = write_file_impl.takeFileMutationInput,
    .reads_only_fn = write_file_impl.readsOnly,
    .irreversible_fn = write_file_impl.isIrreversible,
};

fn dispatchReadFileInWorkspace(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{read_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{ .allocator = alloc, .permission_mode = .auto, .workspace_root = workspace_root }, registry, .{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = args_json,
    });
}

fn dispatchReadFile(alloc: Allocator, args_json: []const u8) !tool_dispatch.DispatchResult {
    return dispatchReadFileInWorkspace(alloc, "", args_json);
}

fn dispatchReadFileWithTrackerInWorkspace(alloc: Allocator, workspace_root: []const u8, args_json: []const u8, tracker: *read_tracker.ReadTracker) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{read_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
        .read_tracker = tracker,
    }, registry, .{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = args_json,
    });
}

fn dispatchReadFileWithTracker(alloc: Allocator, args_json: []const u8, tracker: *read_tracker.ReadTracker) !tool_dispatch.DispatchResult {
    return dispatchReadFileWithTrackerInWorkspace(alloc, "", args_json, tracker);
}

fn allowDecision(_: *const tool_dispatch.Tool, _: tool_dispatch.ToolInput, _: tool_dispatch.DispatchContext) permission_gate.Decision {
    return .{ .action = .allow, .reason = "allowed by test" };
}

fn writeFileArgsJson(alloc: Allocator, path: []const u8, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    try out.writer.writeAll(",\"content\":");
    try std.json.Stringify.value(content, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchWriteFileWithTracker(
    alloc: Allocator,
    workspace_root: []const u8,
    path: []const u8,
    content: []const u8,
    tracker: *read_tracker.ReadTracker,
) !tool_dispatch.DispatchResult {
    const args_json = try writeFileArgsJson(alloc, path, content);
    defer alloc.free(args_json);

    const registry = tool_dispatch.Registry{ .tools = &.{write_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .permission_decider = allowDecision,
        .workspace_root = workspace_root,
        .read_tracker = tracker,
    }, registry, .{
        .id = "call_2",
        .name = "write_file",
        .arguments_json = args_json,
    });
}

fn tmpPath(alloc: Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn readAbsolute(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

fn validateStackInput(alloc: Allocator, input: *Input, workspace_root: []const u8) !?[]u8 {
    return validate(.{ .allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = input, .deinit_fn = noopInputDeinit });
}

fn longLineText(alloc: Allocator, line_count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        try out.appendSlice(alloc, "x\n");
    }
    return try out.toOwnedSlice(alloc);
}























