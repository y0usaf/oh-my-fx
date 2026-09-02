const std = @import("std");
const io_mod = @import("../shared/io.zig");
const background_store = @import("background_store.zig");
const process_supervisor = @import("process_supervisor.zig");
const server_detection = @import("server_detection.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);

const Allocator = std.mem.Allocator;

pub fn refreshPersistedRecordLiveness(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    record: *background_store.Record,
) !void {
    io_mod.e2eFailIfDurableMutationAttempted();
    const external_path = externalLogPath(record.*);
    if (record.state == .stopped or record.state == .exited or record.state == .failed or record.state == .dead or record.state == .stale) {
        if (external_path) |path| {
            if (!absoluteFileExists(path)) {
                try setRecordDiagnostic(alloc, record, "log file is missing");
            }
        }
        record.updated_at_ms = io_mod.milliTimestamp();
        return;
    }

    clearRecordDiagnostic(alloc, record);

    if (!background_process_provider.isValidPidText(record.pid)) {
        record.state = .stale;
        record.expect_url = false;
        try setRecordDiagnostic(alloc, record, "pid is missing or invalid");
        record.updated_at_ms = io_mod.milliTimestamp();
        return;
    }

    if (external_path != null and !absoluteFileExists(external_path.?)) {
        record.state = .stale;
        record.expect_url = false;
        try setRecordDiagnostic(alloc, record, "log file is missing");
        record.updated_at_ms = io_mod.milliTimestamp();
        return;
    }

    if (external_path) |path| {
        if (try detectExitCodeFromExternalPath(alloc, path)) |exit_code| {
            record.expect_url = false;
            record.exit_code = exit_code;
            record.state = if (exit_code == 0) .exited else .failed;
            try setRecordDiagnostic(alloc, record, "exit marker observed");
            record.updated_at_ms = io_mod.milliTimestamp();
            return;
        }
    }

    const token_text = record.process_token orelse {
        record.state = .stale;
        record.expect_url = false;
        record.exit_code = null;
        try setRecordDiagnostic(
            alloc,
            record,
            "legacy record has no process identity token",
        );
        record.updated_at_ms = io_mod.milliTimestamp();
        return;
    };
    const process_token = process_supervisor.ProcessInstanceToken.parse(
        token_text,
    ) catch {
        record.state = .stale;
        record.expect_url = false;
        record.exit_code = null;
        try setRecordDiagnostic(
            alloc,
            record,
            "process identity token is invalid",
        );
        record.updated_at_ms = io_mod.milliTimestamp();
        return;
    };
    const token_match = process_provider.matchToken(
        alloc,
        record.pid,
        process_token,
    );
    if (token_match == .missing or token_match == .mismatched) {
        record.state = .dead;
        record.expect_url = false;
        record.exit_code = null;
        try setRecordDiagnostic(alloc, record, "pid is not running");
        record.updated_at_ms = io_mod.milliTimestamp();
        return;
    }
    if (token_match == .unavailable) return;

    if (external_path) |path| {
        if (record.server_url == null) {
            if (try server_detection.detectServerUrl(alloc, path)) |url| {
                record.server_url = url;
                record.expect_url = false;
            }
        }
    }

    record.state = .running;
    record.updated_at_ms = io_mod.milliTimestamp();
}

pub fn detectExitCodeFromExternalPath(
    alloc: Allocator,
    external_path: []const u8,
) !?i32 {
    var file = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        external_path,
        .{},
    );
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    const size: usize = @intCast(stat.size);
    const tail_size: usize = @min(size, 4096);
    if (tail_size < size) {
        _ = std.c.lseek(file.handle, @intCast(size - tail_size), std.posix.SEEK.SET);
    }
    const content = try io_mod.readFileToEnd(alloc, &file, tail_size + 1);
    defer alloc.free(content);

    return detectExitCodeFromContent(content);
}

pub fn detectExitCodeFromContent(content: []const u8) !?i32 {
    const marker_index = std.mem.findLast(
        u8,
        content,
        background_process_provider.exit_marker,
    ) orelse return null;
    const value_start = marker_index + background_process_provider.exit_marker.len;
    var value_end = value_start;
    while (value_end < content.len and content[value_end] >= '0' and content[value_end] <= '9') : (value_end += 1) {}
    if (value_end == value_start) return null;
    return try std.fmt.parseInt(i32, content[value_start..value_end], 10);
}

pub fn absoluteFileExists(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

fn externalLogPath(record: background_store.Record) ?[]const u8 {
    const storage = record.log_storage orelse return record.log_path;
    return switch (storage) {
        .external => |value| value.path,
        .managed_session => null,
    };
}

fn clearRecordDiagnostic(alloc: Allocator, record: *background_store.Record) void {
    if (record.diagnostic) |diagnostic| {
        alloc.free(diagnostic);
        record.diagnostic = null;
    }
}

fn setRecordDiagnostic(
    alloc: Allocator,
    record: *background_store.Record,
    diagnostic: []const u8,
) !void {
    clearRecordDiagnostic(alloc, record);
    record.diagnostic = try alloc.dupe(u8, diagnostic);
}

fn testRecord(alloc: Allocator, log_path: []const u8) !background_store.Record {
    const pid = try alloc.dupe(u8, "12345");
    errdefer alloc.free(pid);
    const command = try alloc.dupe(u8, "npm run dev");
    errdefer alloc.free(command);
    const cwd = try alloc.dupe(u8, "/tmp/fx");
    errdefer alloc.free(cwd);
    const owned_log_path = try alloc.dupe(u8, log_path);
    errdefer alloc.free(owned_log_path);

    return .{
        .id = 1,
        .pid = pid,
        .command = command,
        .cwd = cwd,
        .log_path = owned_log_path,
        .expect_url = true,
        .started_at_ms = 1,
        .updated_at_ms = 2,
        .state = .running,
    };
}

fn tmpPath(alloc: Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn writeAbsoluteFile(path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        path,
        .{ .truncate = true },
    );
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}
