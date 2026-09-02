const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_converted_content_bytes: usize = 10 * 1024 * 1024;

pub const Kind = enum {
    text,
    html,
    binary,
};

pub const Classification = struct {
    kind: Kind,
    mime_type: []u8,
    declared: bool,

    pub fn deinit(self: *Classification, alloc: Allocator) void {
        alloc.free(self.mime_type);
        self.* = .{ .kind = .binary, .mime_type = &.{}, .declared = false };
    }
};
