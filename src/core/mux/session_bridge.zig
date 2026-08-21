const std = @import("std");
const io_mod = @import("../shared/io.zig");
const terminal_engine = @import("../terminal/engine.zig");

const Allocator = std.mem.Allocator;
const endpoint_name = "mux.sock";
const private_socket_permissions = std.Io.File.Permissions.fromMode(0o600);
const max_input_bytes: usize = 4096;
const max_snapshot_bytes: usize = 8 * 1024 * 1024;
const listener_poll_ms: i32 = 50;

extern "c" fn write(fd: c_int, bytes: [*]const u8, len: usize) isize;

const Command = enum(u8) {
    screen = 'S',
    input = 'I',
};

pub const Runtime = struct {
    alloc: ?Allocator = null,
    endpoint_path: []u8 = &.{},
    server: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    snapshot: std.ArrayList(u8) = .empty,
    input: std.ArrayList(u8) = .empty,
    input_offset: usize = 0,

    pub fn start(
        self: *Runtime,
        alloc: Allocator,
        sessions_dir: []const u8,
        session_id: []const u8,
    ) !void {
        if (self.thread != null) return;
        const session_dir = try std.fs.path.join(alloc, &.{ sessions_dir, session_id });
        defer alloc.free(session_dir);
        self.endpoint_path = try std.fs.path.join(alloc, &.{ session_dir, endpoint_name });
        errdefer {
            alloc.free(self.endpoint_path);
            self.endpoint_path = &.{};
        }
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), self.endpoint_path) catch {};
        const address = try std.Io.net.UnixAddress.init(self.endpoint_path);
        self.server = try address.listen(io_mod.getIo(), .{});
        errdefer {
            self.server.?.deinit(io_mod.getIo());
            self.server = null;
        }
        try std.Io.Dir.cwd().setFilePermissions(
            io_mod.getIo(),
            self.endpoint_path,
            private_socket_permissions,
            .{ .follow_symlinks = false },
        );
        self.alloc = alloc;
        self.stopping.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, serverMain, .{self});
    }

    pub fn isStarted(self: *const Runtime) bool {
        return self.alloc != null;
    }

    pub fn deinit(self: *Runtime) void {
        const alloc = self.alloc orelse return;
        self.stopping.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.server) |*server| server.deinit(io_mod.getIo());
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), self.endpoint_path) catch {};
        alloc.free(self.endpoint_path);
        self.snapshot.deinit(alloc);
        self.input.deinit(alloc);
        self.* = .{};
    }

    /// Called by the interactive app thread, which exclusively owns `grid`.
    pub fn publish(self: *Runtime, grid: ?*const terminal_engine.Grid) void {
        const alloc = self.alloc orelse return;
        const source = grid orelse return;
        const payload = source.checkpointPayload(alloc) catch return;
        defer alloc.free(payload);
        if (payload.len > max_snapshot_bytes) return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.snapshot.clearRetainingCapacity();
        self.snapshot.appendSlice(alloc, payload) catch self.snapshot.clearRetainingCapacity();
    }

    /// Returns one queued byte to the app event loop.
    pub fn takeInputByte(self: *Runtime) ?u8 {
        if (self.alloc == null) return null;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.input_offset >= self.input.items.len) {
            self.input.clearRetainingCapacity();
            self.input_offset = 0;
            return null;
        }
        const byte = self.input.items[self.input_offset];
        self.input_offset += 1;
        return byte;
    }

    fn serverMain(self: *Runtime) void {
        while (!self.stopping.load(.acquire)) {
            const server = &(self.server orelse return);
            if (!listenerReady(server.socket.handle)) continue;
            var stream = server.accept(io_mod.getIo()) catch continue;
            defer stream.close(io_mod.getIo());
            self.handleClient(stream.socket.handle) catch {};
        }
    }

    fn handleClient(self: *Runtime, fd: std.posix.fd_t) !void {
        var command_byte: [1]u8 = undefined;
        try readExact(fd, &command_byte);
        const command: Command = std.enums.fromInt(Command, command_byte[0]) orelse return error.InvalidMuxCommand;
        switch (command) {
            .screen => try self.writeSnapshot(fd),
            .input => try self.readInput(fd),
        }
    }

    fn writeSnapshot(self: *Runtime, fd: std.posix.fd_t) !void {
        const alloc = self.alloc orelse return error.MuxBridgeStopped;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        const copy = alloc.dupe(u8, self.snapshot.items) catch |err| {
            self.mutex.unlock(io);
            return err;
        };
        self.mutex.unlock(io);
        defer alloc.free(copy);
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(copy.len), .little);
        try writeAll(fd, &header);
        try writeAll(fd, copy);
    }

    fn readInput(self: *Runtime, fd: std.posix.fd_t) !void {
        const alloc = self.alloc orelse return error.MuxBridgeStopped;
        var header: [4]u8 = undefined;
        try readExact(fd, &header);
        const len: usize = std.mem.readInt(u32, &header, .little);
        if (len > max_input_bytes) return error.MuxInputTooLarge;
        const bytes = try alloc.alloc(u8, len);
        defer alloc.free(bytes);
        try readExact(fd, bytes);
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.input_offset > 0) {
            const remaining = self.input.items[self.input_offset..];
            std.mem.copyForwards(u8, self.input.items[0..remaining.len], remaining);
            self.input.items.len = remaining.len;
            self.input_offset = 0;
        }
        if (self.input.items.len + bytes.len > max_input_bytes) return error.MuxInputFull;
        try self.input.appendSlice(alloc, bytes);
    }
};

pub fn endpointPath(alloc: Allocator, sessions_dir: []const u8, session_id: []const u8) ![]u8 {
    const session_dir = try std.fs.path.join(alloc, &.{ sessions_dir, session_id });
    defer alloc.free(session_dir);
    return std.fs.path.join(alloc, &.{ session_dir, endpoint_name });
}

pub fn requestScreen(alloc: Allocator, endpoint_path: []const u8) !terminal_engine.Grid {
    var stream = try connect(endpoint_path);
    defer stream.close(io_mod.getIo());
    try writeAll(stream.socket.handle, &.{@intFromEnum(Command.screen)});
    var header: [4]u8 = undefined;
    try readExact(stream.socket.handle, &header);
    const len: usize = std.mem.readInt(u32, &header, .little);
    if (len == 0) return error.MuxScreenUnavailable;
    if (len > max_snapshot_bytes) return error.MuxScreenTooLarge;
    const payload = try alloc.alloc(u8, len);
    defer alloc.free(payload);
    try readExact(stream.socket.handle, payload);
    return terminal_engine.Grid.restoreCheckpoint(alloc, payload);
}

pub fn sendInput(endpoint_path: []const u8, bytes: []const u8) !void {
    if (bytes.len > max_input_bytes) return error.MuxInputTooLarge;
    var stream = try connect(endpoint_path);
    defer stream.close(io_mod.getIo());
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(Command.input);
    std.mem.writeInt(u32, header[1..5], @intCast(bytes.len), .little);
    try writeAll(stream.socket.handle, &header);
    try writeAll(stream.socket.handle, bytes);
}

fn connect(endpoint_path: []const u8) !std.Io.net.Stream {
    const address = try std.Io.net.UnixAddress.init(endpoint_path);
    return address.connect(io_mod.getIo());
}

fn listenerReady(handle: std.Io.net.Socket.Handle) bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&poll_fds, listener_poll_ms) catch return false;
    if (ready == 0) return false;
    return (poll_fds[0].revents & std.posix.POLL.IN) != 0;
}

fn readExact(fd: std.posix.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try std.posix.read(fd, bytes[offset..]);
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0) return error.MuxWriteFailed;
        if (count == 0) return error.NoProgress;
        offset += @intCast(count);
    }
}

test "mux session endpoint is scoped to the durable session" {
    const path = try endpointPath(std.testing.allocator, "/tmp/fx/sessions", "session-1");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/fx/sessions/session-1/mux.sock", path);
}

test "mux session bridge exchanges screen checkpoints and input" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "session", .default_dir);
    const sessions_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(sessions_dir);

    var bridge: Runtime = .{};
    try bridge.start(alloc, sessions_dir, "session");
    defer bridge.deinit();

    var grid = try terminal_engine.Grid.init(alloc, 12, 4);
    defer grid.deinit();
    try grid.feed("attached");
    grid.cursor_shape = .bar;
    bridge.publish(&grid);

    const endpoint = try endpointPath(alloc, sessions_dir, "session");
    defer alloc.free(endpoint);
    var restored = try requestScreen(alloc, endpoint);
    defer restored.deinit();
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try restored.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("attached", row.items);
    try std.testing.expectEqual(@as(@TypeOf(restored.cursor_shape), .bar), restored.cursor_shape);

    try sendInput(endpoint, "xy");
    const deadline = io_mod.milliTimestamp() + 1000;
    var first: ?u8 = null;
    while (first == null and io_mod.milliTimestamp() < deadline) {
        first = bridge.takeInputByte();
        if (first == null) io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(?u8, 'x'), first);
    try std.testing.expectEqual(@as(?u8, 'y'), bridge.takeInputByte());
    try std.testing.expectEqual(@as(?u8, null), bridge.takeInputByte());
}
