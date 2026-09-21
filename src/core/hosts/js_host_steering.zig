const std = @import("std");

const Allocator = std.mem.Allocator;
const max_message_bytes: usize = 64 * 1024;
const max_messages: usize = 64;

extern "fx" fn fx_steering_take(output_ptr: [*]u8, output_cap: usize) i32;
extern "fx" fn fx_steering_close() void;

pub fn close() void {
    fx_steering_close();
}

/// Drains host-owned libfx steering text into allocator-owned messages.
pub fn takeAll(alloc: Allocator) ![][]u8 {
    const scratch = try alloc.alloc(u8, max_message_bytes);
    defer alloc.free(scratch);
    var messages: std.ArrayList([]u8) = .empty;
    errdefer {
        for (messages.items) |text| alloc.free(text);
        messages.deinit(alloc);
    }

    for (0..max_messages) |_| {
        const raw = fx_steering_take(scratch.ptr, scratch.len);
        if (raw == 0) break;
        if (raw < 0) return error.HostSteeringFailed;
        const len: usize = @intCast(raw);
        if (len > scratch.len) return error.HostSteeringFailed;
        const owned = try alloc.dupe(u8, scratch[0..len]);
        errdefer alloc.free(owned);
        try messages.append(alloc, owned);
    }
    if (messages.items.len == 0) {
        messages.deinit(alloc);
        return &.{};
    }
    return messages.toOwnedSlice(alloc);
}
