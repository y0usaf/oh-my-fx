const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const max_message_bytes: usize = 64 * 1024;
pub const max_messages: usize = 64;
pub const max_queued_bytes: usize = 1024 * 1024;

pub const EnqueueError = Allocator.Error || error{
    EmptySteeringMessage,
    SteeringMessageTooLarge,
    SteeringQueueFull,
    SteeringNotActive,
};

/// Owns bounded libfx steering text shared by the ACP reader and prompt worker.
pub const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    messages: std.ArrayListUnmanaged([]u8) = .empty,
    queued_bytes: usize = 0,
    accepting: bool = false,

    pub fn open(self: *Runtime, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.clearLocked(alloc, "new_turn");
        self.accepting = true;
    }

    pub fn enqueue(self: *Runtime, alloc: Allocator, text: []const u8) EnqueueError!void {
        if (text.len == 0) return error.EmptySteeringMessage;
        if (text.len > max_message_bytes) return error.SteeringMessageTooLarge;

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.accepting) return error.SteeringNotActive;
        if (self.messages.items.len >= max_messages or
            self.queued_bytes > max_queued_bytes - text.len)
        {
            return error.SteeringQueueFull;
        }
        const owned = try alloc.dupe(u8, text);
        errdefer alloc.free(owned);
        try self.messages.append(alloc, owned);
        self.queued_bytes += owned.len;
    }

    /// Returns result-allocator-owned text and releases the queue-owned copies.
    pub fn takeAll(
        self: *Runtime,
        backing: Allocator,
        result_alloc: Allocator,
        close_if_empty: bool,
    ) Allocator.Error![][]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.messages.items.len == 0) {
            if (close_if_empty) self.accepting = false;
            return &.{};
        }

        const result = try result_alloc.alloc([]u8, self.messages.items.len);
        var copied: usize = 0;
        errdefer {
            for (result[0..copied]) |text| result_alloc.free(text);
            result_alloc.free(result);
        }
        for (self.messages.items, 0..) |text, index| {
            result[index] = try result_alloc.dupe(u8, text);
            copied += 1;
        }
        for (self.messages.items) |text| backing.free(text);
        self.messages.clearRetainingCapacity();
        self.queued_bytes = 0;
        return result;
    }

    pub fn close(self: *Runtime, alloc: Allocator, reason: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.accepting = false;
        self.clearLocked(alloc, reason);
    }

    pub fn clear(self: *Runtime, alloc: Allocator, reason: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.clearLocked(alloc, reason);
    }

    fn clearLocked(self: *Runtime, alloc: Allocator, reason: []const u8) void {
        if (self.messages.items.len > 0) {
            debug_trace.logf(
                "libfx",
                "dropped steering messages={d} bytes={d} reason={s}",
                .{ self.messages.items.len, self.queued_bytes, reason },
            );
        }
        for (self.messages.items) |text| alloc.free(text);
        self.messages.clearRetainingCapacity();
        self.queued_bytes = 0;
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.close(alloc, "runtime_deinit");
        self.messages.deinit(alloc);
        self.* = .{};
    }
};

test "libfx steering runtime preserves order and releases drained storage" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.open(alloc);

    try runtime.enqueue(alloc, "first");
    try runtime.enqueue(alloc, "second");
    const messages = try runtime.takeAll(alloc, alloc, false);
    defer {
        for (messages) |text| alloc.free(text);
        alloc.free(messages);
    }
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("first", messages[0]);
    try std.testing.expectEqualStrings("second", messages[1]);
    try std.testing.expectEqual(@as(usize, 0), runtime.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.queued_bytes);
}

test "libfx steering runtime bounds each message and total queue" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);
    runtime.open(alloc);

    try std.testing.expectError(error.EmptySteeringMessage, runtime.enqueue(alloc, ""));
    const oversized = try alloc.alloc(u8, max_message_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.SteeringMessageTooLarge, runtime.enqueue(alloc, oversized));

    const message = "x" ** (max_queued_bytes / max_messages);
    for (0..max_messages) |_| try runtime.enqueue(alloc, message);
    try std.testing.expectError(error.SteeringQueueFull, runtime.enqueue(alloc, "overflow"));
    runtime.clear(alloc, "test");
    try std.testing.expectEqual(@as(usize, 0), runtime.queued_bytes);
}
