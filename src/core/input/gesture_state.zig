const std = @import("std");

pub const ctrl_c_exit_window_ms: i64 = 3000;
pub const escape_clear_window_ms: i64 = 500;

pub const State = struct {
    ctrl_c_exit_armed_ms: ?i64 = null,
    escape_clear_armed_ms: ?i64 = null,

    pub fn ctrlCExitArmed(self: State) bool {
        return self.ctrl_c_exit_armed_ms != null;
    }

    pub fn ctrlCExitArmedAt(self: State) ?i64 {
        return self.ctrl_c_exit_armed_ms;
    }

    pub fn escapeClearArmed(self: State) bool {
        return self.escape_clear_armed_ms != null;
    }

    pub fn escapeClearArmedAt(self: State) ?i64 {
        return self.escape_clear_armed_ms;
    }
};

pub const PressResult = enum {
    armed,
    activated,
};

pub const PressTransition = struct {
    next: State,
    result: PressResult,
};

pub const ClearTransition = struct {
    next: State,
    cleared: bool,
};

pub const ResetTransition = struct {
    next: State,
    cleared_ctrl_c_exit: bool,
    cleared_escape_clear: bool,

    pub fn clearedAny(self: ResetTransition) bool {
        return self.cleared_ctrl_c_exit or self.cleared_escape_clear;
    }
};

pub fn pressCtrlCExit(current: State, now_ms: i64) PressTransition {
    if (current.ctrl_c_exit_armed_ms) |armed_ms| {
        if (now_ms - armed_ms < ctrl_c_exit_window_ms) {
            return .{ .next = current, .result = .activated };
        }
    }

    var next = current;
    next.ctrl_c_exit_armed_ms = now_ms;
    return .{ .next = next, .result = .armed };
}

pub fn pressEscapeClear(current: State, now_ms: i64) PressTransition {
    if (current.escape_clear_armed_ms) |armed_ms| {
        if (now_ms - armed_ms <= escape_clear_window_ms) {
            var next = current;
            next.escape_clear_armed_ms = null;
            return .{ .next = next, .result = .activated };
        }
    }

    var next = current;
    next.escape_clear_armed_ms = now_ms;
    return .{ .next = next, .result = .armed };
}

pub fn disarmCtrlCExit(current: State) ClearTransition {
    var next = current;
    next.ctrl_c_exit_armed_ms = null;
    return .{ .next = next, .cleared = current.ctrl_c_exit_armed_ms != null };
}

pub fn disarmEscapeClear(current: State) ClearTransition {
    var next = current;
    next.escape_clear_armed_ms = null;
    return .{ .next = next, .cleared = current.escape_clear_armed_ms != null };
}

pub fn expireCtrlCExit(current: State, now_ms: i64) ClearTransition {
    const armed_ms = current.ctrl_c_exit_armed_ms orelse return .{
        .next = current,
        .cleared = false,
    };
    if (now_ms - armed_ms < ctrl_c_exit_window_ms) {
        return .{ .next = current, .cleared = false };
    }
    return disarmCtrlCExit(current);
}

pub fn expireEscapeClear(current: State, now_ms: i64) ClearTransition {
    const armed_ms = current.escape_clear_armed_ms orelse return .{
        .next = current,
        .cleared = false,
    };
    if (now_ms - armed_ms <= escape_clear_window_ms) {
        return .{ .next = current, .cleared = false };
    }
    return disarmEscapeClear(current);
}

pub fn reset(current: State) ResetTransition {
    return .{
        .next = .{},
        .cleared_ctrl_c_exit = current.ctrl_c_exit_armed_ms != null,
        .cleared_escape_clear = current.escape_clear_armed_ms != null,
    };
}




