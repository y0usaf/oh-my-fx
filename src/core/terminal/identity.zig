const std = @import("std");
const builtin = @import("builtin");

/// Stable local profile identity used only inside private terminal authority.
pub fn profileUser(buffer: *[64]u8) ?[]const u8 {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        return std.fmt.bufPrint(buffer, "uid-{d}", .{std.c.getuid()}) catch null;
    }
    return null;
}
