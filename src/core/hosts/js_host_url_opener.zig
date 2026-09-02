const std = @import("std");
const host = @import("host.zig");

extern "fx" fn fx_open_url(url_ptr: [*]const u8, url_len: usize) i32;

pub const opener: host.UrlOpener = .{ .open_fn = open };

fn open(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    url: []const u8,
) host.UrlOpenError!bool {
    return openWith(fx_open_url, url);
}

fn openWith(call: anytype, url: []const u8) bool {
    return call(url.ptr, url.len) == 1;
}
