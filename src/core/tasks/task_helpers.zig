const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const process_supervisor = @import("../background/process_supervisor.zig");
const command_contract = @import("../execution/command_contract.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_runtime = @import("../session/session.zig");

const Allocator = std.mem.Allocator;

pub const StopSelection = process_supervisor.StopSelection;
pub const TaskState = process_supervisor.TaskState;
pub const TaskCompletion = process_supervisor.TaskCompletion;
pub const ConversationLanguage = session_runtime.ConversationLanguage;

pub fn taskStateLabel(state: TaskState) []const u8 {
    return switch (state) {
        .running => "running",
        .exited => "exited",
        .failed => "failed",
        .stopped => "stopped",
        .dead => "dead",
        .stale => "stale",
    };
}

pub fn parseTaskSelection(target: []const u8) !StopSelection {
    const trimmed = std.mem.trim(u8, target, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "last")) return .last;
    return .{ .id = try std.fmt.parseInt(u64, trimmed, 10) };
}

pub fn readExternalTaskLogTail(alloc: Allocator, log_path: []const u8, max_bytes: usize, max_lines: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), log_path, .{});
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    const size: usize = @intCast(stat.size);
    const tail_size = @min(size, max_bytes);
    const start = size - tail_size;

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &read_buf);
    if (start > 0) try reader.seekTo(start);
    const read_limit = std.math.add(usize, tail_size, 1) catch tail_size;
    const content = try reader.interface.allocRemaining(alloc, std.Io.Limit.limited(read_limit));
    defer alloc.free(content);

    const tail = tailLogSlice(content, start, max_lines);
    return std.fmt.allocPrint(alloc, "[logs] {s}\n{s}", .{ log_path, tail });
}

pub fn readExternalTaskLogSummary(alloc: Allocator, log_path: []const u8, max_head_bytes: usize, max_tail_bytes: usize, max_lines: usize) ![]u8 {
    return readExternalTaskLogSummaryWithTopic(alloc, log_path, max_head_bytes, max_tail_bytes, max_lines, true);
}

pub fn readExternalTaskLogSummaryBody(alloc: Allocator, log_path: []const u8, max_head_bytes: usize, max_tail_bytes: usize, max_lines: usize) ![]u8 {
    return readExternalTaskLogSummaryWithTopic(alloc, log_path, max_head_bytes, max_tail_bytes, max_lines, false);
}

fn readExternalTaskLogSummaryWithTopic(alloc: Allocator, log_path: []const u8, max_head_bytes: usize, max_tail_bytes: usize, max_lines: usize, include_topic: bool) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), log_path, .{});
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    const size: usize = @intCast(stat.size);

    const head = try readLogRange(alloc, &file, 0, @min(size, max_head_bytes));
    defer alloc.free(head);

    const tail_size = @min(size, max_tail_bytes);
    const tail_start = size - tail_size;
    const tail_raw = try readLogRange(alloc, &file, tail_start, tail_size);
    defer alloc.free(tail_raw);

    const head_slice = head[0..firstLinesEnd(head, max_lines)];
    const tail_slice = tailLogSlice(tail_raw, tail_start, max_lines);

    return formatTaskLogSummary(alloc, log_path, size, head_slice, tail_slice, include_topic);
}

pub fn readManagedTaskLogTail(
    alloc: Allocator,
    file: *session_child_store.ManagedFile,
    display_path: []const u8,
    max_bytes: usize,
    max_lines: usize,
) ![]u8 {
    const stat = try file.stat();
    const size: usize = @intCast(stat.size);
    const tail_size = @min(size, max_bytes);
    const start = size - tail_size;
    const content = try file.readRange(alloc, start, tail_size);
    defer alloc.free(content);

    const tail = tailLogSlice(content, start, max_lines);
    return std.fmt.allocPrint(
        alloc,
        "[logs] {s}\n{s}",
        .{ display_path, tail },
    );
}

pub fn readManagedTaskLogSummary(
    alloc: Allocator,
    file: *session_child_store.ManagedFile,
    display_path: []const u8,
    max_head_bytes: usize,
    max_tail_bytes: usize,
    max_lines: usize,
) ![]u8 {
    return readManagedTaskLogSummaryWithTopic(alloc, file, display_path, max_head_bytes, max_tail_bytes, max_lines, true);
}

pub fn readManagedTaskLogSummaryBody(
    alloc: Allocator,
    file: *session_child_store.ManagedFile,
    display_path: []const u8,
    max_head_bytes: usize,
    max_tail_bytes: usize,
    max_lines: usize,
) ![]u8 {
    return readManagedTaskLogSummaryWithTopic(alloc, file, display_path, max_head_bytes, max_tail_bytes, max_lines, false);
}

fn readManagedTaskLogSummaryWithTopic(
    alloc: Allocator,
    file: *session_child_store.ManagedFile,
    display_path: []const u8,
    max_head_bytes: usize,
    max_tail_bytes: usize,
    max_lines: usize,
    include_topic: bool,
) ![]u8 {
    const stat = try file.stat();
    const size: usize = @intCast(stat.size);
    const head = try file.readRange(alloc, 0, @min(size, max_head_bytes));
    defer alloc.free(head);

    const tail_size = @min(size, max_tail_bytes);
    const tail_start = size - tail_size;
    const tail_raw = try file.readRange(alloc, tail_start, tail_size);
    defer alloc.free(tail_raw);

    const head_slice = head[0..firstLinesEnd(head, max_lines)];
    const tail_slice = tailLogSlice(tail_raw, tail_start, max_lines);

    return formatTaskLogSummary(alloc, display_path, size, head_slice, tail_slice, include_topic);
}

fn formatTaskLogSummary(
    alloc: Allocator,
    display_path: []const u8,
    size: usize,
    head: []const u8,
    tail: []const u8,
    include_topic: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (include_topic) try out.writer.writeAll("[logs] ");
    try out.writer.print("{s}\nbytes={d}\n<head>\n{s}</head>\n<tail>\n{s}</tail>\n", .{
        display_path,
        size,
        head,
        tail,
    });
    return try out.toOwnedSlice();
}

pub fn formatBackgroundCommandNotice(alloc: Allocator, task_id: u64, background: command_contract.BackgroundCommand, language: ConversationLanguage) ![]u8 {
    _ = language;
    if (background.url) |url| {
        return std.fmt.allocPrint(alloc, "Background #{d}: server running at {s}. Log: {s}", .{ task_id, url, background.log_path });
    }

    if (background.expect_url) {
        return std.fmt.allocPrint(alloc, "Background #{d}: server started. Waiting for local URL. Log: {s}", .{ task_id, background.log_path });
    }

    return std.fmt.allocPrint(alloc, "Background #{d}: command started. Log: {s}", .{ task_id, background.log_path });
}

/// Returns a semantic notice whose body is owned by the caller.
pub fn backgroundLaunchNotice(alloc: Allocator, task_id: u64, background: command_contract.BackgroundCommand, language: ConversationLanguage) !types.SemanticNotice {
    _ = language;
    const body = if (background.url) |url|
        try std.fmt.allocPrint(alloc, "Command #{d} started. Server: {s}. Log: {s}", .{ task_id, url, background.log_path })
    else if (background.expect_url)
        try std.fmt.allocPrint(alloc, "Command #{d} started. Waiting for local URL. Log: {s}", .{ task_id, background.log_path })
    else
        try std.fmt.allocPrint(alloc, "Command #{d} started. Log: {s}", .{ task_id, background.log_path });
    return .{
        .topic = "background",
        .tone = .neutral,
        .body = body,
    };
}

/// Returns a semantic notice whose body is owned by the caller.
pub fn backgroundServerReadyNotice(alloc: Allocator, task_id: u64, url: []const u8, language: ConversationLanguage) !types.SemanticNotice {
    _ = language;
    return .{
        .topic = "background",
        .tone = .neutral,
        .body = try std.fmt.allocPrint(alloc, "Command #{d} server ready at {s}.", .{ task_id, url }),
    };
}

/// Returns a semantic notice whose body is owned by the caller.
pub fn backgroundCompletionNotice(alloc: Allocator, completion: TaskCompletion, language: ConversationLanguage) !types.SemanticNotice {
    _ = language;
    const tone: types.NoticeTone = switch (completion.state) {
        .exited, .running => .neutral,
        .failed, .dead, .stale => .@"error",
        .stopped => .cancelled,
    };
    const body = switch (completion.state) {
        .exited => try std.fmt.allocPrint(alloc, "Command #{d} completed successfully.", .{completion.id}),
        .failed => if (completion.exit_code) |code|
            try std.fmt.allocPrint(alloc, "Command #{d} failed (exit {d}).", .{ completion.id, code })
        else
            try std.fmt.allocPrint(alloc, "Command #{d} failed.", .{completion.id}),
        .stopped => try std.fmt.allocPrint(alloc, "Command #{d} stopped.", .{completion.id}),
        .dead => try std.fmt.allocPrint(alloc, "Command #{d} is no longer running.", .{completion.id}),
        .stale => try std.fmt.allocPrint(alloc, "Command #{d} is stale.", .{completion.id}),
        .running => try std.fmt.allocPrint(alloc, "Command #{d} is running.", .{completion.id}),
    };
    return .{
        .topic = "background",
        .tone = tone,
        .body = body,
    };
}

fn tailLogSlice(content: []const u8, window_start: usize, max_lines: usize) []const u8 {
    var slice = content;
    if (window_start > 0) {
        slice = if (std.mem.findScalar(u8, slice, '\n')) |newline_index|
            slice[newline_index + 1 ..]
        else
            slice[slice.len..];
    }
    return slice[finalLinesStart(slice, max_lines)..];
}

fn readLogRange(alloc: Allocator, file: *std.Io.File, start: usize, len: usize) ![]u8 {
    if (len == 0) return alloc.dupe(u8, "");
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &read_buf);
    try reader.seekTo(start);
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out);
    const read_len = try reader.interface.readSliceShort(out);
    if (read_len == out.len) return out;
    const resized = try alloc.realloc(out, read_len);
    return resized;
}

fn firstLinesEnd(text: []const u8, max_lines: usize) usize {
    if (max_lines == 0) return 0;

    var separator_count: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte != '\n') continue;
        separator_count += 1;
        if (separator_count == max_lines) return i + 1;
    }

    return text.len;
}

fn finalLinesStart(text: []const u8, max_lines: usize) usize {
    if (max_lines == 0) return text.len;

    var separator_count: usize = 0;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        if (text[i] != '\n') continue;
        if (i == text.len - 1) continue;

        separator_count += 1;
        if (separator_count == max_lines) return i + 1;
    }

    return 0;
}

fn writeAbsoluteFile(path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn tmpPath(alloc: Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}
