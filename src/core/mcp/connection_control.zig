const std = @import("std");
const operation_control = @import("operation_control.zig");

pub fn check(io: std.Io, control: Control) error{ Cancelled, McpRequestTimedOut }!void {
    if (control.cancellation().cancelled()) return error.Cancelled;
    if (control.deadline) |deadline| {
        if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io, .awake), .lt, deadline)) return error.McpRequestTimedOut;
    }
}

pub const Control = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    /// Milliseconds from the start of the startup operation to its deadline,
    /// fixed when the operation starts so timeout messages can name it.
    startup_span_ms: ?u32 = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,

    pub fn cancellation(self: Control) operation_control.CancellationSources {
        return .{ .caller = self.cancel_flag, .runtime = self.lifecycle_cancel_flag };
    }

    /// Reserve half of the remaining startup budget for initialization when an
    /// older stdio server ignores discovery instead of returning method-not-found.
    pub fn discoveryProbeAt(self: Control, now: std.Io.Clock.Timestamp) Control {
        const end = self.deadline orelse return self;
        const remaining = std.math.sub(i96, end.raw.nanoseconds, now.raw.nanoseconds) catch std.math.maxInt(i96);
        if (remaining <= 0) return self;
        var probe = self;
        probe.deadline = .{ .clock = end.clock, .raw = .{ .nanoseconds = now.raw.nanoseconds +| @divFloor(@max(remaining, 0), 2) } };
        return probe;
    }

    /// Existing deadlines belong to the whole connection operation, including fallback.
    pub fn startAt(self: Control, now: std.Io.Clock.Timestamp, timeout_ms: u32) Control {
        var started = self.withStartupSpan(now, timeout_ms);
        if (started.deadline == null) started.deadline = startupDeadline(now, timeout_ms, null);
        return started;
    }

    /// Fixes the span of the whole startup operation: the time left before an
    /// earlier deadline, or the configured timeout that will set one.
    /// Fallbacks and restarts inherit the first value.
    pub fn withStartupSpan(self: Control, now: std.Io.Clock.Timestamp, timeout_ms: u32) Control {
        if (self.startup_span_ms != null) return self;
        var spanned = self;
        spanned.startup_span_ms = if (self.deadline) |deadline| millisUntil(now, deadline) else timeout_ms;
        return spanned;
    }
};

/// Whole milliseconds from `now` until `deadline`, rounded up and saturated.
fn millisUntil(now: std.Io.Clock.Timestamp, deadline: std.Io.Clock.Timestamp) u32 {
    const remaining = std.math.sub(i96, deadline.raw.nanoseconds, now.raw.nanoseconds) catch
        return std.math.maxInt(u32);
    if (remaining <= 0) return 0;
    const millis = @divFloor(remaining +| (std.time.ns_per_ms - 1), std.time.ns_per_ms);
    return std.math.cast(u32, millis) orelse std.math.maxInt(u32);
}

pub fn startupTimeout(configured_timeout_ms: u32, override: ?std.Io.Duration) std.Io.Duration {
    return override orelse .{ .nanoseconds = @as(i96, configured_timeout_ms) * std.time.ns_per_ms };
}

pub fn startupDeadline(
    now: std.Io.Clock.Timestamp,
    configured_timeout_ms: u32,
    override: ?std.Io.Duration,
) std.Io.Clock.Timestamp {
    const duration = startupTimeout(configured_timeout_ms, override);
    const nanoseconds = std.math.add(i96, now.raw.nanoseconds, duration.nanoseconds) catch std.math.maxInt(i96);
    return .{ .clock = now.clock, .raw = .{ .nanoseconds = nanoseconds } };
}

test "startup uses configured timeouts and a private override" {
    for ([_]u32{ 250, 2_000, 5_000, 30_000, 60_000 }) |timeout_ms| {
        try std.testing.expectEqual(@as(i64, timeout_ms), startupTimeout(timeout_ms, null).toMilliseconds());
    }
    try std.testing.expectEqual(@as(i64, 2_000), startupTimeout(60_000, .fromSeconds(2)).toMilliseconds());
}

test "fallback and restart cannot extend a started operation" {
    const now = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = 123 * std.time.ns_per_ms } };
    const control = (Control{}).startAt(now, 1_500);
    const later = startupDeadline(now, 1_000, null);
    const fallback = control.startAt(later, 30_000);
    const restart = fallback.startAt(later, 60_000);
    try std.testing.expectEqual(@as(i64, 1_500), now.durationTo(control.deadline.?).raw.toMilliseconds());
    try std.testing.expectEqual(control.deadline.?, fallback.deadline.?);
    try std.testing.expectEqual(control.deadline.?, restart.deadline.?);
}

test "startup span is fixed when the operation starts" {
    const now = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = 5 * std.time.ns_per_s } };
    const later = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = now.raw.nanoseconds + 700 * std.time.ns_per_ms } };

    const configured = (Control{}).startAt(now, 1_500);
    try std.testing.expectEqual(@as(?u32, 1_500), configured.startup_span_ms);
    try std.testing.expectEqual(@as(?u32, 1_500), configured.startAt(later, 30_000).startup_span_ms);
    try std.testing.expectEqual(@as(?u32, 1_500), configured.discoveryProbeAt(later).startup_span_ms);

    const caller_deadline = Control{ .deadline = startupDeadline(now, 0, .fromSeconds(2)) };
    try std.testing.expectEqual(@as(?u32, 2_000), caller_deadline.withStartupSpan(now, 30_000).startup_span_ms);
    const almost = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = now.raw.nanoseconds + 1 } };
    try std.testing.expectEqual(@as(?u32, 2_000), caller_deadline.withStartupSpan(almost, 30_000).startup_span_ms);
    const spent = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = now.raw.nanoseconds + 3 * std.time.ns_per_s } };
    try std.testing.expectEqual(@as(?u32, 0), caller_deadline.withStartupSpan(spent, 30_000).startup_span_ms);
    // A tool call's deadline can outlast the configured startup timeout.
    const long_deadline = Control{ .deadline = startupDeadline(now, 0, .fromSeconds(60)) };
    try std.testing.expectEqual(@as(?u32, 60_000), long_deadline.withStartupSpan(now, 30_000).startup_span_ms);

    const explicit = Control{ .deadline = caller_deadline.deadline, .startup_span_ms = 45_000 };
    try std.testing.expectEqual(@as(?u32, 45_000), explicit.startAt(later, 30_000).startup_span_ms);
}

test "deadline arithmetic saturates without changing the clock" {
    const now = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = std.math.maxInt(i96) - 1 } };
    const deadline = startupDeadline(now, std.math.maxInt(u32), null);
    try std.testing.expectEqual(std.math.maxInt(i96), deadline.raw.nanoseconds);
    try std.testing.expectEqual(now.clock, deadline.clock);
}

test "silent discovery leaves initialization inside the original deadline" {
    const now = std.Io.Clock.Timestamp{ .clock = .awake, .raw = .{ .nanoseconds = 0 } };
    const whole = (Control{}).startAt(now, 1_500);
    const probe = whole.discoveryProbeAt(now);
    try std.testing.expectEqual(@as(i64, 750), probe.deadline.?.raw.toMilliseconds());
    try std.testing.expectEqual(@as(i64, 1_500), whole.deadline.?.raw.toMilliseconds());
    const elapsed = startupDeadline(now, 1_000, null);
    try std.testing.expectEqual(@as(i64, 1_250), whole.discoveryProbeAt(elapsed).deadline.?.raw.toMilliseconds());
}
