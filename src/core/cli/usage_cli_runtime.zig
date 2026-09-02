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
