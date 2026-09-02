const std = @import("std");

pub const ignored_directory_names: []const []const u8 = &.{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".next",
    "dist",
    "build",
    "coverage",
};

pub fn pathContainsIgnoredDirectory(path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (isIgnoredDirectoryName(component.name)) return true;
    }
    return false;
}

pub fn isIgnoredDirectoryName(name: []const u8) bool {
    for (ignored_directory_names) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}
