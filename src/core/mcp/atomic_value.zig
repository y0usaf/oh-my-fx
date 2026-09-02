const std = @import("std");
const host_target = @import("../hosts/target.zig");

/// wasm32 lacks 64-bit atomics, so `std.atomic.Value(u64)` fails to compile
/// there. WASM builds run single-threaded, so a plain value with the same
/// API is sound on that target while native builds keep real atomics.
pub fn Value(comptime T: type) type {
    if (!host_target.is_wasm) return std.atomic.Value(T);
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .raw = value };
        }

        pub fn load(self: *const Self, comptime _: std.builtin.AtomicOrder) T {
            return self.raw;
        }

        pub fn store(self: *Self, value: T, comptime _: std.builtin.AtomicOrder) void {
            self.raw = value;
        }

        pub fn fetchAdd(self: *Self, operand: T, comptime _: std.builtin.AtomicOrder) T {
            const previous = self.raw;
            self.raw +%= operand;
            return previous;
        }

        pub fn cmpxchgWeak(
            self: *Self,
            expected: T,
            new: T,
            comptime _: std.builtin.AtomicOrder,
            comptime _: std.builtin.AtomicOrder,
        ) ?T {
            if (self.raw != expected) return self.raw;
            self.raw = new;
            return null;
        }
    };
}
