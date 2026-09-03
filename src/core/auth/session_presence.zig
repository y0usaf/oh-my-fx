const std = @import("std");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

pub fn profileFile(
    file_name: []const u8,
    max_bytes: usize,
) host.SecretStorePresence {
    if (comptime host_target.is_wasm) return .missing;
    return profileFileFromHome(io_mod.getenv("HOME"), file_name, max_bytes);
}

fn profileFileFromHome(
    home_value: ?[]const u8,
    file_name: []const u8,
    max_bytes: usize,
) host.SecretStorePresence {
    const home = home_value orelse return .unavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        home,
        .{ .iterate = true },
    ) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer home_dir.close(io_mod.getIo());

    var profile_dir = home_dir.openDir(
        io_mod.getIo(),
        profile_paths.root_dir_name,
        .{ .iterate = true, .follow_symlinks = false },
    ) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer profile_dir.close(io_mod.getIo());

    var file = profile_dir.openFile(io_mod.getIo(), file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch return .unavailable;
    if (stat.kind != .file or
        stat.nlink != 1 or
        stat.permissions.toMode() & 0o077 != 0 or
        stat.size == 0 or
        stat.size > max_bytes)
    {
        return .unavailable;
    }
    return .present;
}

test "missing native profile root is unavailable" {
    try std.testing.expectEqual(
        host.SecretStorePresence.unavailable,
        profileFileFromHome(null, "auth.json", 1024),
    );
}
