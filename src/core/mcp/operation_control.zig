const std = @import("std");
const atomic_value = @import("atomic_value.zig");

pub const CancellationState = enum {
    active,
    caller_cancelled,
    runtime_retired,
    caller_cancelled_and_runtime_retired,

    pub fn cancelled(self: CancellationState) bool {
        return self != .active;
    }
};

pub fn cancellationState(
    caller_cancelled: bool,
    runtime_retired: bool,
) CancellationState {
    if (caller_cancelled and runtime_retired) {
        return .caller_cancelled_and_runtime_retired;
    }
    if (caller_cancelled) return .caller_cancelled;
    if (runtime_retired) return .runtime_retired;
    return .active;
}

pub const CancellationSources = struct {
    caller: ?*const std.atomic.Value(bool) = null,
    runtime: ?*const std.atomic.Value(bool) = null,

    pub fn state(self: CancellationSources) CancellationState {
        return cancellationState(
            if (self.caller) |flag| flag.load(.acquire) else false,
            if (self.runtime) |flag| flag.load(.acquire) else false,
        );
    }

    pub fn cancelled(self: CancellationSources) bool {
        return self.state().cancelled();
    }
};

pub const DeadlineGate = struct {
    deadline_ms: atomic_value.Value(i64),

    pub fn init(deadline_ms: i64) DeadlineGate {
        return .{ .deadline_ms = .init(deadline_ms) };
    }

    pub fn pauseUntil(self: *DeadlineGate, deadline_ms: i64) void {
        self.deadline_ms.store(deadline_ms, .release);
    }

    pub fn resumeAt(self: *DeadlineGate, now_ms: i64, timeout_ms: u32) void {
        self.deadline_ms.store(resumedDeadlineMs(now_ms, timeout_ms), .release);
    }

    pub fn expired(self: *const DeadlineGate, now_ms: i64) bool {
        return now_ms >= self.deadline_ms.load(.acquire);
    }

    pub fn currentDeadlineMs(self: *const DeadlineGate) i64 {
        return self.deadline_ms.load(.acquire);
    }
};

fn resumedDeadlineMs(now_ms: i64, timeout_ms: u32) i64 {
    return std.math.add(i64, now_ms, timeout_ms) catch std.math.maxInt(i64);
}




