const std = @import("std");
const text_scalar = @import("text_scalar.zig");

pub const State = struct {
    owner: ?text_scalar.Owner = null,
};

pub const BeginTransition = struct {
    next: State,
    should_report: bool,
};

pub fn begin(current: State, owner: text_scalar.Owner) BeginTransition {
    if (current.owner == owner) {
        return .{ .next = current, .should_report = false };
    }
    return .{
        .next = .{ .owner = owner },
        .should_report = true,
    };
}

pub fn clear() State {
    return .{};
}


