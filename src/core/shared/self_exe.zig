const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");

const Allocator = std.mem.Allocator;

const linux_self_exe = "/proc/self/exe";

/// Returns an owned path that re-execs this process. Linux uses
/// `/proc/self/exe` so replacing the on-disk binary does not break later spawns.
pub const ReexecError = Allocator.Error || error{ExecutableNotFound};

pub fn pathForReexec(alloc: Allocator) ReexecError![]u8 {
    if (testProductExe()) |path| return alloc.dupe(u8, path);
    return productionPathForReexec(alloc);
}

fn productionPathForReexec(alloc: Allocator) ReexecError![]u8 {
    if (comptime builtin.os.tag == .linux) return alloc.dupe(u8, linux_self_exe);
    return std.process.executablePathAlloc(io_mod.getIo(), alloc) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ExecutableNotFound,
    };
}

/// Returns an owned path another process can use to launch fx. Linux prefers
/// the on-disk path, falling back to `/proc/<pid>/exe` after replacement.
pub fn pathForPeerReexec(alloc: Allocator) ![]u8 {
    if (testProductExe()) |path| return alloc.dupe(u8, path);
    return productionPathForPeerReexec(alloc);
}

fn productionPathForPeerReexec(alloc: Allocator) ![]u8 {
    if (comptime builtin.os.tag == .linux) {
        const pid = std.c.getpid();
        if (std.process.executablePathAlloc(io_mod.getIo(), alloc)) |resolved| {
            defer alloc.free(resolved);
            if (onDiskPathIsExecutable(resolved)) return alloc.dupe(u8, resolved);
            debug_trace.logf(
                "self_exe",
                "peer re-exec falling back to /proc/{d}/exe on-disk={s}",
                .{ pid, resolved },
            );
        } else |err| {
            debug_trace.logf(
                "self_exe",
                "peer re-exec falling back to /proc/{d}/exe reason={s}",
                .{ pid, @errorName(err) },
            );
        }
        return std.fmt.allocPrint(alloc, "/proc/{d}/exe", .{pid});
    }
    const path_z = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(path_z);
    return alloc.dupe(u8, path_z);
}

fn onDiskPathIsExecutable(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

fn sameFile(left: []const u8, right: []const u8) !bool {
    var left_file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), left, .{});
    defer left_file.close(io_mod.getIo());
    var right_file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), right, .{});
    defer right_file.close(io_mod.getIo());
    const left_stat = try left_file.stat(io_mod.getIo());
    const right_stat = try right_file.stat(io_mod.getIo());
    return left_stat.inode == right_stat.inode;
}

fn testProductExe() ?[]const u8 {
    if (comptime !builtin.is_test) return null;
    const path_z = std.c.getenv("FX_TEST_PRODUCT_EXE") orelse return null;
    const path = std.mem.sliceTo(path_z, 0);
    return if (path.len == 0) null else path;
}
