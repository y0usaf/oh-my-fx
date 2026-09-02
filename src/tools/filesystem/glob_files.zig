const std = @import("std");
const builtin = @import("builtin");
const glob_pattern = @import("../../core/workspace/glob_pattern.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const workspace_files = @import("../../core/workspace/workspace_files.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

const OutputMode = enum {
    matches,
    count,
};

/// Typed input for the built-in glob_files tool.
pub const Input = struct {
    pattern: []u8,
    path: []u8,
    mode: OutputMode = .matches,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.pattern);
        alloc.free(self.path);
        self.* = .{ .pattern = &.{}, .path = &.{}, .mode = .matches };
    }
};

/// Decodes glob_files JSON into an owned Input released by ToolInput.deinit.
pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files arguments must be an object") };
    }

    const pattern_value = parsed.value.object.get("pattern") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files requires string field \"pattern\"") };
    };
    if (pattern_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "glob_files field \"pattern\" must be a string") };
    }

    const path_value = parsed.value.object.get("path");
    const path_string: ?[]const u8 = if (path_value) |value| switch (value) {
        .string => |path| path,
        else => null,
    } else null;

    const mode_value = parsed.value.object.get("mode");
    const mode: OutputMode = if (mode_value) |value| switch (value) {
        .string => |raw| if (std.mem.eql(u8, raw, "count")) .count else .matches,
        else => .matches,
    } else .matches;

    const owned_pattern = try ctx.allocator.dupe(u8, pattern_value.string);
    errdefer ctx.allocator.free(owned_pattern);
    const owned_path = try ctx.allocator.dupe(u8, path_string orelse ".");
    errdefer ctx.allocator.free(owned_path);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .pattern = owned_pattern,
        .path = owned_path,
        .mode = mode,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

/// Searches the resolved root and returns an owned tool result body.
pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callWithWorkspaceOptions(ctx, erased, .{});
}

fn callWithWorkspaceOptions(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput, workspace_options: workspace_files.Options) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const requested_root = resolveSearchRoot(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (tool_result_errors.isFilesystemAccessDenied(err)) {
            return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", input.path, err) };
        }
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve glob search root: {s} ({s})", .{ input.path, @errorName(err) }) };
    };
    const static_base = if (requested_root.is_directory)
        extractStaticGlobBase(input.pattern)
    else
        StaticGlobBase{ .base = "", .pattern = input.pattern };
    const maybe_root = if (requested_root.is_directory)
        resolveStaticBaseRoot(arena, requested_root.absolute, static_base.base) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (tool_result_errors.isFilesystemAccessDenied(err)) {
                return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", requested_root.absolute, err) };
            }
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to resolve glob search root: {s} ({s})", .{ input.path, @errorName(err) }) };
        }
    else
        requested_root;
    const root = maybe_root orelse {
        if (input.mode == .count) {
            return .{ .success = try formatCount(ctx.allocator, input.pattern, 0, false, workspace_files.default_candidate_cap, 0) };
        }
        return .{ .success = try formatMatches(ctx.allocator, input.pattern, &.{}, false, false, workspace_files.default_candidate_cap, 0, ctx.max_list_entries) };
    };
    const root_relative = try pathing.workspaceRelativePath(arena, ctx.workspace_root, root.absolute);
    var compiled_pattern = glob_pattern.Pattern.compile(arena, static_base.pattern) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PatternTooLong => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "glob_files field \"pattern\" must be at most {d} bytes", .{glob_pattern.max_pattern_bytes}) },
    };
    defer compiled_pattern.deinit(arena);

    var matches: std.ArrayList([]u8) = .empty;
    defer matches.deinit(arena);
    var match_count: usize = 0;
    var output_truncated = false;
    var candidate_incomplete = false;
    var candidate_cap: usize = workspace_files.default_candidate_cap;
    var skipped_overlong: usize = 0;
    const is_scoped_search_root = root_relative.len > 0 and !std.mem.eql(u8, root_relative, ".");
    var discovery_options = workspace_options;
    discovery_options.include_untracked = is_scoped_search_root;
    discovery_options.force_fallback = discovery_options.force_fallback or is_scoped_search_root;
    discovery_options.include_hidden = discovery_options.include_hidden or shouldIncludeHidden(root_relative, input.pattern);
    discovery_options.sort_paths = true;

    if (root.is_directory) {
        const discovered = discoverWorkspaceFiles(arena, root.absolute, ctx.ignored_list_entries, discovery_options) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (tool_result_errors.isFilesystemAccessDenied(err)) {
                return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", root.absolute, err) };
            }
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to discover glob candidates: {s} ({s})", .{ root.absolute, @errorName(err) }) };
        };
        var candidate_files = discovered.files;
        candidate_incomplete = discovered.incomplete;
        candidate_cap = discovered.candidate_cap;
        skipped_overlong = discovered.skipped_overlong;
        if (shouldMergeRootUntracked(root_relative, discovered, discovery_options)) {
            const merged = mergeRootUntrackedCandidates(arena, root.absolute, ctx.ignored_list_entries, discovered) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (tool_result_errors.isFilesystemAccessDenied(err)) {
                    return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(ctx.allocator, "glob_files", root.absolute, err) };
                }
                return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "Unable to discover glob candidates: {s} ({s})", .{ root.absolute, @errorName(err) }) };
            };
            candidate_files = merged.files;
            candidate_incomplete = candidate_incomplete or merged.incomplete;
            skipped_overlong += merged.skipped_overlong;
        }

        for (candidate_files) |candidate| {
            if (!compiled_pattern.matchesPath(candidate)) continue;

            match_count += 1;
            if (input.mode == .count) continue;

            if (matches.items.len >= ctx.max_list_entries) {
                output_truncated = true;
                break;
            }

            try matches.append(arena, try joinRelativeSearchPath(arena, root_relative, candidate));
        }
    } else {
        const basename = std.fs.path.basename(root_relative);
        if (compiled_pattern.matchesPath(basename)) {
            match_count += 1;
            if (input.mode == .matches) {
                try matches.append(arena, try arena.dupe(u8, root_relative));
            }
        }
    }

    if (input.mode == .count) {
        return .{ .success = try formatCount(ctx.allocator, input.pattern, match_count, candidate_incomplete, candidate_cap, skipped_overlong) };
    }
    return .{ .success = try formatMatches(ctx.allocator, input.pattern, matches.items, output_truncated, candidate_incomplete, candidate_cap, skipped_overlong, ctx.max_list_entries) };
}

fn formatCount(
    alloc: Allocator,
    pattern: []const u8,
    match_count: usize,
    candidate_incomplete: bool,
    candidate_cap: usize,
    skipped_overlong: usize,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("[glob] count {d} matches for {s}\n", .{ match_count, pattern }) catch return error.OutOfMemory;
    try writeCandidateNotes(&out.writer, candidate_incomplete, candidate_cap, skipped_overlong);
    return try out.toOwnedSlice();
}

fn formatMatches(
    alloc: Allocator,
    pattern: []const u8,
    matches: []const []const u8,
    output_truncated: bool,
    candidate_incomplete: bool,
    candidate_cap: usize,
    skipped_overlong: usize,
    max_list_entries: usize,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (matches.len == 0) {
        out.writer.print("[glob] no matches for {s}\n", .{pattern}) catch return error.OutOfMemory;
        try writeCandidateNotes(&out.writer, candidate_incomplete, candidate_cap, skipped_overlong);
        return try out.toOwnedSlice();
    }

    out.writer.print("[glob] {d} matches for {s}\n", .{ matches.len, pattern }) catch return error.OutOfMemory;
    for (matches) |match| {
        out.writer.print(" - {s}\n", .{match}) catch return error.OutOfMemory;
    }
    if (output_truncated) {
        out.writer.print("... truncated to first {d} matches\n", .{max_list_entries}) catch return error.OutOfMemory;
    }
    try writeCandidateNotes(&out.writer, candidate_incomplete, candidate_cap, skipped_overlong);

    return try out.toOwnedSlice();
}

fn writeCandidateNotes(writer: anytype, candidate_incomplete: bool, candidate_cap: usize, skipped_overlong: usize) tool_dispatch.DispatchError!void {
    if (candidate_incomplete) {
        writer.print("... candidate list may be incomplete; candidate cap {d} reached before all files were discovered\n", .{candidate_cap}) catch return error.OutOfMemory;
    }
    if (skipped_overlong > 0) {
        writer.print("... skipped {d} overlong candidate path{s}\n", .{ skipped_overlong, if (skipped_overlong == 1) "" else "s" }) catch return error.OutOfMemory;
    }
}

const SearchRoot = struct {
    absolute: []const u8,
    is_directory: bool,
};

fn resolveSearchRoot(arena: Allocator, workspace_root: []const u8, requested: []const u8) !SearchRoot {
    const absolute = try pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, requested);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return .{ .absolute = absolute, .is_directory = false },
        else => return err,
    };
    dir.close(io_mod.getIo());
    return .{ .absolute = absolute, .is_directory = true };
}

fn resolveStaticBaseRoot(arena: Allocator, requested_root: []const u8, static_base: []const u8) !?SearchRoot {
    if (static_base.len == 0 or std.mem.eql(u8, static_base, ".")) {
        return .{ .absolute = requested_root, .is_directory = true };
    }
    const absolute = pathing.resolveWorkspacePath(arena, requested_root, static_base, .existing) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return null,
        else => return err,
    };
    dir.close(io_mod.getIo());
    return .{ .absolute = absolute, .is_directory = true };
}

const StaticGlobBase = struct {
    base: []const u8,
    pattern: []const u8,
};

fn extractStaticGlobBase(pattern: []const u8) StaticGlobBase {
    const first_glob = firstGlobChar(pattern) orelse {
        const dirname = std.fs.path.dirname(pattern) orelse return .{ .base = "", .pattern = pattern };
        return .{ .base = dirname, .pattern = std.fs.path.basename(pattern) };
    };
    const static_prefix = pattern[0..first_glob];
    const last_sep = lastPathSeparator(static_prefix) orelse return .{ .base = "", .pattern = pattern };
    if (last_sep == 0 and isPathSeparator(static_prefix[0])) {
        return .{ .base = static_prefix[0..1], .pattern = pattern[1..] };
    }
    return .{ .base = static_prefix[0..last_sep], .pattern = pattern[last_sep + 1 ..] };
}

fn firstGlobChar(pattern: []const u8) ?usize {
    for (pattern, 0..) |ch, index| {
        switch (ch) {
            '*', '?', '[', '{' => return index,
            else => {},
        }
    }
    return null;
}

fn lastPathSeparator(path: []const u8) ?usize {
    var index = path.len;
    while (index > 0) {
        index -= 1;
        if (isPathSeparator(path[index])) return index;
    }
    return null;
}

fn isPathSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn joinRelativeSearchPath(arena: Allocator, root_relative: []const u8, child_relative: []const u8) ![]u8 {
    if (std.mem.eql(u8, root_relative, ".") or root_relative.len == 0) {
        return arena.dupe(u8, child_relative);
    }
    return std.fs.path.join(arena, &.{ root_relative, child_relative });
}

fn shouldIncludeHidden(root_relative: []const u8, pattern: []const u8) bool {
    return workspace_files.pathContainsHiddenDirectoryComponent(root_relative) or patternContainsHiddenDirectoryComponent(pattern);
}

const MergedRootCandidates = struct {
    files: []const []const u8,
    incomplete: bool = false,
    skipped_overlong: usize = 0,
};

fn discoverWorkspaceFiles(arena: Allocator, absolute_root: []const u8, ignored: []const []const u8, options: workspace_files.Options) !workspace_files.Result {
    var discover_options = options;
    discover_options.ignored_names = ignored;
    return workspace_files.discover(arena, absolute_root, discover_options);
}

fn shouldMergeRootUntracked(root_relative: []const u8, result: workspace_files.Result, options: workspace_files.Options) bool {
    return result.source == .git and !options.include_untracked and !options.force_fallback and (root_relative.len == 0 or std.mem.eql(u8, root_relative, "."));
}

fn mergeRootUntrackedCandidates(
    arena: Allocator,
    absolute_root: []const u8,
    ignored: []const []const u8,
    discovered: workspace_files.Result,
) !MergedRootCandidates {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(arena);
    try files.appendSlice(arena, discovered.files);

    var seen = std.StringHashMap(void).init(arena);
    defer seen.deinit();
    for (discovered.files) |path| {
        try seen.put(path, {});
    }

    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute_root, .{ .iterate = true }) catch {
        return .{ .files = try files.toOwnedSlice(arena) };
    };
    defer dir.close(io_mod.getIo());

    var incomplete = false;
    var skipped_overlong: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io_mod.getIo())) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (rootNameIgnored(ignored, entry.name)) continue;
        if (seen.contains(entry.name)) continue;
        if (entry.name.len > workspace_files.max_relative_path_bytes) {
            skipped_overlong += 1;
            continue;
        }
        if (files.items.len >= discovered.candidate_cap) {
            incomplete = true;
            break;
        }
        const owned = try arena.dupe(u8, entry.name);
        try seen.put(owned, {});
        try files.append(arena, owned);
    }

    sortCandidatePaths(files.items);
    return .{
        .files = try files.toOwnedSlice(arena),
        .incomplete = incomplete,
        .skipped_overlong = skipped_overlong,
    };
}

fn rootNameIgnored(ignored: []const []const u8, name: []const u8) bool {
    for (ignored) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn sortCandidatePaths(paths: [][]const u8) void {
    sort_utils.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn patternContainsHiddenDirectoryComponent(pattern: []const u8) bool {
    return workspace_files.pathContainsHiddenDirectoryComponent(pattern);
}

/// Reports that glob_files only observes filesystem names and metadata.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

/// Reports that glob_files has no irreversible side effects.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

const glob_files_dispatch_tool = tool_dispatch.Tool{
    .name = "glob_files",
    .description = "Glob files dispatch test fixture.",
    .model_schema = .{
        .name = "glob_files",
        .description = "Glob files dispatch test fixture.",
    },
    .executor_kind = .glob_files,
    .activity_kind = .list,
    .permission_target_kind = .path_optional_existing,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

fn validateStackInput(alloc: Allocator, input: *Input, workspace_root: []const u8) !?[]u8 {
    return validate(.{ .allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = input, .deinit_fn = noopInputDeinit });
}

fn expectDecodeFailure(args_json: []const u8, reason: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(reason, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

fn expectDecodeInput(args_json: []const u8, pattern: []const u8, input_path: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
        .input => |erased| {
            defer erased.deinit(alloc);
            const input = erased.as(Input);
            try std.testing.expectEqualStrings(pattern, input.pattern);
            try std.testing.expectEqualStrings(input_path, input.path);
        },
    }
}

fn globArgsJson(alloc: Allocator, pattern: []const u8, maybe_path: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"pattern\":");
    try std.json.Stringify.value(pattern, .{}, &out.writer);
    if (maybe_path) |path| {
        try out.writer.writeAll(",\"path\":");
        try std.json.Stringify.value(path, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn dispatchGlobFiles(alloc: Allocator, workspace_root: []const u8, pattern: []const u8, maybe_path: ?[]const u8) !tool_dispatch.DispatchResult {
    const args = try globArgsJson(alloc, pattern, maybe_path);
    defer alloc.free(args);

    return dispatchGlobFilesRaw(alloc, workspace_root, args);
}

fn dispatchGlobFilesRaw(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{glob_files_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
    }, registry, .{
        .id = "call_1",
        .name = "glob_files",
        .arguments_json = args_json,
    });
}

fn runGitForTest(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "git");
    try argv.appendSlice(alloc, args);

    const result = std.process.run(alloc, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return error.SkipZigTest;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

fn writeTempFile(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) ![]u8 {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn writeTempFileWithMtime(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
    content: []const u8,
    mtime_ns: i96,
) ![]u8 {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
    try file.setTimestamps(io_mod.getIo(), .{
        .access_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = mtime_ns } },
    });
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn countEmittedResultLines(body: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, " - ")) count += 1;
    }
    return count;
}

fn createNumberedFiles(tmp: *std.testing.TmpDir, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "many/file-{d:0>4}.txt", .{i});
        if (std.fs.path.dirname(name)) |parent| {
            try tmp.dir.createDirPath(io_mod.getIo(), parent);
        }
        {
            var file = try tmp.dir.createFile(std.testing.io, name, .{});
            defer file.close(io_mod.getIo());
            try file.writeStreamingAll(io_mod.getIo(), "x\n");
        }
    }
}























