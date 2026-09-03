const std = @import("std");
const profile_usage_runtime = @import("../session/profile_usage_runtime.zig");
const usage_recovery = @import("../session/usage_recovery.zig");
const usage_report = @import("../session/usage_report.zig");

const Allocator = std.mem.Allocator;

/// Reads one local profile snapshot. It never initializes credentials or
/// contacts the Gateway.
pub fn collect(
    alloc: Allocator,
    home_path: []const u8,
    scope: usage_report.Scope,
    snapshot_time_ms: i64,
) !usage_report.Snapshot {
    var runtime: profile_usage_runtime.Runtime = .{};
    defer runtime.deinit(alloc);
    const outcome = try runtime.initialize(alloc, home_path);
    if (outcome != .available) {
        return runtime.lastError() orelse error.ProfileUsageUnavailable;
    }

    var recovery = try usage_recovery.collectFromHomeConservative(
        alloc,
        home_path,
    );
    defer recovery.deinit(alloc);
    return runtime.snapshot(alloc, scope, snapshot_time_ms, .{
        .facts = recovery.facts,
        .incidents = recovery.incidents,
        .pending = recovery.pending,
        .unknown_pending = recovery.unknown_pending,
    });
}

test "usage CLI collection does not create profile state for an empty home" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_mod = @import("../shared/io.zig");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var report = try collect(
        alloc,
        home,
        .days_30,
        std.time.ms_per_day * 40,
    );
    defer report.deinit(alloc);
    try std.testing.expectEqual(usage_report.Coverage.not_started, report.coverage);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(io_mod.getIo(), ".fx", .{}),
    );
}
