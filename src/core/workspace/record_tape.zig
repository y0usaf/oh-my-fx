//! FX_RECORD tape writer and replay reader.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const magic = "FXTP\x01";

pub const Kind = enum(u8) {
    stdout = 1,
    stdin = 2,
    resize = 3,
    sigint = 4,
    marker = 5,
    _,
};

const State = struct {
    enabled: bool = false,
    failed: bool = false,
    record_stdin: bool = false,
    file: ?std.Io.File = null,
    path: ?[]u8 = null,
    path_alloc: ?Allocator = null,
    start_ms: i64 = 0,
    last_ms: i64 = 0,
};

var state_mutex: std.Io.Mutex = .init;
var state: State = .{};

fn nowMs() i64 {
    return io_mod.milliTimestamp();
}

pub const CaptureStatus = union(enum) {
    inactive,
    active: []u8,
    failed,

    pub fn deinit(self: *CaptureStatus, alloc: Allocator) void {
        switch (self.*) {
            .active => |path| alloc.free(path),
            .inactive, .failed => {},
        }
        self.* = undefined;
    }
};

pub fn configureFromEnv(
    alloc: Allocator,
    workspace_root: []const u8,
    initial_cols: u16,
    initial_rows: u16,
    fx_version: []const u8,
    record_requested: bool,
) !void {
    _ = workspace_root;

    const configured_path = if (io_mod.getenv("FX_RECORD")) |raw_path|
        std.mem.trim(u8, raw_path, " \t\r\n")
    else
        "";
    if (configured_path.len > 0) {
        configure(alloc, configured_path, initial_cols, initial_rows, fx_version) catch |err| {
            if (record_requested) return err;
            return;
        };
    } else if (record_requested) {
        try configureAutomatic(alloc, initial_cols, initial_rows, fx_version);
    } else {
        return;
    }

    if (io_mod.getenv("FX_RECORD_INPUT")) |raw_value| {
        const value = std.mem.trim(u8, raw_value, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(value, "1") or
            std.ascii.eqlIgnoreCase(value, "true") or
            std.ascii.eqlIgnoreCase(value, "on"))
        {
            const zio = io_mod.getIo();
            state_mutex.lockUncancelable(zio);
            defer state_mutex.unlock(zio);
            state.record_stdin = true;
        }
    }
}

pub fn configure(
    alloc: Allocator,
    path: []const u8,
    initial_cols: u16,
    initial_rows: u16,
    fx_version: []const u8,
) !void {
    try configureWithOptions(alloc, path, initial_cols, initial_rows, fx_version, false, false);
}

fn configureAutomatic(
    alloc: Allocator,
    initial_cols: u16,
    initial_rows: u16,
    fx_version: []const u8,
) !void {
    const home = if (io_mod.getenv("HOME")) |value| blk: {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else null;
    } else null;
    const root = if (home) |value|
        try profile_paths.recordingsDir(alloc, value)
    else
        try std.fs.path.join(alloc, &.{ io_mod.getenv("TMPDIR") orelse "/tmp", "fx-recordings" });
    defer alloc.free(root);
    try io_mod.makeDirRecursive(root);

    var attempts: u8 = 0;
    while (attempts < 8) : (attempts += 1) {
        var random_bytes: [6]u8 = undefined;
        io_mod.getIo().random(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try std.fmt.allocPrint(alloc, "{s}/fx-record-{d}-{s}.fxtape", .{ root, nowMs(), random_hex });
        defer alloc.free(path);

        configureWithOptions(alloc, path, initial_cols, initial_rows, fx_version, true, true) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return;
    }
    return error.PathAlreadyExists;
}

fn configureWithOptions(
    alloc: Allocator,
    path: []const u8,
    initial_cols: u16,
    initial_rows: u16,
    fx_version: []const u8,
    exclusive: bool,
    private: bool,
) !void {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (state.enabled) return;

    try ensureParentDir(path);

    const file = try openTape(path, exclusive, private);
    errdefer file.close(zio);

    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);

    const header = buildHeader(initial_cols, initial_rows, fx_version);
    try file.writeStreamingAll(zio, &header.fixed);
    if (header.version_tail.len > 0) {
        try file.writeStreamingAll(zio, header.version_tail);
    }

    const now = nowMs();
    state = .{
        .enabled = true,
        .file = file,
        .path = owned_path,
        .path_alloc = alloc,
        .start_ms = now,
        .last_ms = now,
    };
}

fn openTape(path: []const u8, exclusive: bool, private: bool) !std.Io.File {
    const zio = io_mod.getIo();
    if (std.fs.path.isAbsolute(path)) {
        if (private) {
            return std.Io.Dir.createFileAbsolute(zio, path, .{
                .truncate = !exclusive,
                .exclusive = exclusive,
                .permissions = .fromMode(0o600),
            });
        }
        return std.Io.Dir.createFileAbsolute(zio, path, .{ .truncate = !exclusive, .exclusive = exclusive });
    }
    if (private) {
        return std.Io.Dir.cwd().createFile(zio, path, .{
            .truncate = !exclusive,
            .exclusive = exclusive,
            .permissions = .fromMode(0o600),
        });
    }
    return std.Io.Dir.cwd().createFile(zio, path, .{ .truncate = !exclusive, .exclusive = exclusive });
}

const Header = struct {
    fixed: [header_len]u8,
    version_tail: []const u8,
};

fn buildHeader(initial_cols: u16, initial_rows: u16, fx_version: []const u8) Header {
    var header: Header = .{
        .fixed = undefined,
        .version_tail = fx_version,
    };
    @memcpy(header.fixed[0..magic.len], magic);
    var idx: usize = magic.len;
    std.mem.writeInt(u16, header.fixed[idx..][0..2], initial_cols, .little);
    idx += 2;
    std.mem.writeInt(u16, header.fixed[idx..][0..2], initial_rows, .little);
    idx += 2;
    std.mem.writeInt(i64, header.fixed[idx..][0..8], nowMs(), .little);
    idx += 8;
    header.fixed[idx] = @intCast(@min(fx_version.len, @as(usize, 255)));
    return header;
}

fn writeFrame(kind: Kind, payload: []const u8) void {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    writeFrameLocked(zio, kind, payload);
}

fn writeFrameLocked(zio: std.Io, kind: Kind, payload: []const u8) void {
    if (!state.enabled) return;
    const file = state.file orelse {
        stopCaptureLocked(zio, true);
        return;
    };

    const now = nowMs();
    const delta: i32 = @intCast(std.math.clamp(now - state.last_ms, 0, std.math.maxInt(i32)));
    state.last_ms = now;

    var header: [9]u8 = undefined;
    std.mem.writeInt(i32, header[0..4], delta, .little);
    header[4] = @intFromEnum(kind);
    const len: u32 = @intCast(@min(payload.len, std.math.maxInt(u32)));
    std.mem.writeInt(u32, header[5..9], len, .little);

    file.writeStreamingAll(zio, &header) catch {
        stopCaptureLocked(zio, true);
        return;
    };
    if (len > 0) {
        file.writeStreamingAll(zio, payload[0..len]) catch {
            stopCaptureLocked(zio, true);
            return;
        };
    }
}

pub fn recordStdout(bytes: []const u8) void {
    if (bytes.len == 0) return;
    writeFrame(.stdout, bytes);
}

pub fn recordStdin(bytes: []const u8) void {
    if (bytes.len == 0) return;

    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (!state.record_stdin) return;
    writeFrameLocked(zio, .stdin, bytes);
}

pub fn recordResize(cols: u16, rows: u16) void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], cols, .little);
    std.mem.writeInt(u16, payload[2..4], rows, .little);
    writeFrame(.resize, &payload);
}

pub fn recordSigint() void {
    writeFrame(.sigint, "");
}

pub fn recordMarker(label: []const u8) void {
    writeFrame(.marker, label);
}

pub fn shutdown() void {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    stopCaptureLocked(zio, false);
}

pub fn captureStatus(alloc: Allocator) !CaptureStatus {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (state.enabled and state.path != null) {
        return .{ .active = try alloc.dupe(u8, state.path.?) };
    }
    return if (state.failed) .failed else .inactive;
}

fn stopCaptureLocked(zio: std.Io, failed: bool) void {
    if (failed) debug_trace.logf("record", "capture stopped after a frame write failure", .{});
    if (state.file) |*file| file.close(zio);
    if (state.path) |path| state.path_alloc.?.free(path);
    state = .{ .failed = failed };
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try io_mod.makeDirRecursive(parent);
}

pub const ReplayHeader = struct {
    cols: u16,
    rows: u16,
    epoch_ms: i64,
    version: []const u8,
};

pub const ReplayFrame = struct {
    delta_ms: i32,
    kind: Kind,
    payload: []const u8,
};

pub const Parser = struct {
    bytes: []const u8,
    pos: usize = 0,
    header: ReplayHeader,

    pub fn init(bytes: []const u8) !Parser {
        if (bytes.len < header_len) return error.TapeTooShort;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadTapeMagic;

        var idx: usize = magic.len;
        const cols = std.mem.readInt(u16, bytes[idx..][0..2], .little);
        idx += 2;
        const rows = std.mem.readInt(u16, bytes[idx..][0..2], .little);
        idx += 2;
        const epoch_ms = std.mem.readInt(i64, bytes[idx..][0..8], .little);
        idx += 8;
        const version_len = bytes[idx];
        idx += 1;
        if (idx + version_len > bytes.len) return error.TruncatedVersion;
        const version = bytes[idx .. idx + version_len];
        idx += version_len;

        return .{
            .bytes = bytes,
            .pos = idx,
            .header = .{
                .cols = cols,
                .rows = rows,
                .epoch_ms = epoch_ms,
                .version = version,
            },
        };
    }

    pub fn next(self: *Parser) !?ReplayFrame {
        if (self.pos >= self.bytes.len) return null;
        if (self.pos + 9 > self.bytes.len) return error.TruncatedFrameHeader;

        const delta_ms = std.mem.readInt(i32, self.bytes[self.pos..][0..4], .little);
        const kind_raw = self.bytes[self.pos + 4];
        const payload_len = std.mem.readInt(u32, self.bytes[self.pos + 5 ..][0..4], .little);
        const start = self.pos + 9;
        const end = start + payload_len;
        if (end > self.bytes.len) return error.TruncatedFramePayload;

        self.pos = end;
        return .{
            .delta_ms = delta_ms,
            .kind = @enumFromInt(kind_raw),
            .payload = self.bytes[start..end],
        };
    }
};

const header_len = magic.len + 2 + 2 + 8 + 1;

var test_empty_env: std.process.Environ.Map = std.process.Environ.Map.init(std.heap.c_allocator);

fn resetEnvForTest() void {
    io_mod.setEnvironMap(&test_empty_env);
}

fn tapePath(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn readFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn appendHeader(out: *std.ArrayList(u8), alloc: Allocator, cols: u16, rows: u16, epoch_ms: i64, version: []const u8) !void {
    try out.appendSlice(alloc, magic);
    var fixed: [2 + 2 + 8 + 1]u8 = undefined;
    std.mem.writeInt(u16, fixed[0..2], cols, .little);
    std.mem.writeInt(u16, fixed[2..4], rows, .little);
    std.mem.writeInt(i64, fixed[4..12], epoch_ms, .little);
    fixed[12] = @intCast(@min(version.len, @as(usize, 255)));
    try out.appendSlice(alloc, &fixed);
    try out.appendSlice(alloc, version);
}

fn appendFrame(out: *std.ArrayList(u8), alloc: Allocator, delta_ms: i32, kind: u8, payload: []const u8) !void {
    var fixed: [9]u8 = undefined;
    std.mem.writeInt(i32, fixed[0..4], delta_ms, .little);
    fixed[4] = kind;
    std.mem.writeInt(u32, fixed[5..9], @intCast(payload.len), .little);
    try out.appendSlice(alloc, &fixed);
    try out.appendSlice(alloc, payload);
}

fn expectNoFrame(bytes: []const u8) !void {
    var parser = try Parser.init(bytes);
    try testing.expect((try parser.next()) == null);
}

















