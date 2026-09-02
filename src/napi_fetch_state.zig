const std = @import("std");

pub const Handle = i32;

pub const TerminalKind = enum {
    success,
    failure,
    aborted,
};

pub const Terminal = struct {
    handle: Handle,
    kind: TerminalKind,
};

pub const Phase = union(enum) {
    idle,
    cancel_pending,
    request_pending: Handle,
    awaiting_response: Handle,
    streaming: Handle,
    terminal: Terminal,
    shutdown,
};

pub const Event = union(enum) {
    open: Handle,
    take_request,
    start: Handle,
    push: Handle,
    finish: Handle,
    fail: Handle,
    close: Handle,
    cancel,
    shutdown,
};

pub const Action = enum {
    applied,
    stale,
    no_request,
    cancelled,
    unavailable,
    shutting_down,
};

pub const StaleReason = enum {
    no_active_fetch,
    handle_mismatch,
    phase_mismatch,
    terminal,
    shutdown,
};

pub const Decision = struct {
    phase: Phase,
    action: Action,
    stale_reason: ?StaleReason = null,
};

pub fn decide(phase: Phase, event: Event) Decision {
    return switch (event) {
        .open => |handle| switch (phase) {
            .idle => .{
                .phase = .{ .request_pending = handle },
                .action = .applied,
            },
            .cancel_pending => .{ .phase = .idle, .action = .cancelled },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
            else => .{ .phase = phase, .action = .unavailable },
        },
        .take_request => switch (phase) {
            .request_pending => |handle| .{
                .phase = .{ .awaiting_response = handle },
                .action = .applied,
            },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
            else => .{ .phase = phase, .action = .no_request },
        },
        .start => |handle| switch (phase) {
            .awaiting_response => |active| if (active == handle)
                .{ .phase = .{ .streaming = handle }, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .push => |handle| switch (phase) {
            .streaming => |active| if (active == handle)
                .{ .phase = phase, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .finish => |handle| switch (phase) {
            .streaming => |active| if (active == handle)
                .{
                    .phase = .{ .terminal = .{ .handle = handle, .kind = .success } },
                    .action = .applied,
                }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .fail => |handle| switch (phase) {
            .awaiting_response, .streaming => |active| if (active == handle)
                .{
                    .phase = .{ .terminal = .{ .handle = handle, .kind = .failure } },
                    .action = .applied,
                }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .close => |handle| switch (phase) {
            .request_pending, .awaiting_response, .streaming => |active| if (active == handle)
                .{ .phase = .idle, .action = .applied }
            else
                stale(phase, handle),
            .terminal => |terminal| if (terminal.handle == handle)
                .{ .phase = .idle, .action = .applied }
            else
                stale(phase, handle),
            else => stale(phase, handle),
        },
        .cancel => switch (phase) {
            .idle => .{ .phase = .cancel_pending, .action = .applied },
            .request_pending, .awaiting_response, .streaming => |handle| .{
                .phase = .{ .terminal = .{ .handle = handle, .kind = .aborted } },
                .action = .applied,
            },
            .shutdown => .{ .phase = .shutdown, .action = .shutting_down },
            else => .{ .phase = phase, .action = .no_request },
        },
        .shutdown => switch (phase) {
            .shutdown => .{ .phase = .shutdown, .action = .no_request },
            else => .{ .phase = .shutdown, .action = .applied },
        },
    };
}

pub fn is_active(phase: Phase, handle: Handle) bool {
    return switch (phase) {
        .request_pending, .awaiting_response, .streaming => |active| active == handle,
        else => false,
    };
}

fn stale(phase: Phase, handle: Handle) Decision {
    return .{
        .phase = phase,
        .action = .stale,
        .stale_reason = switch (phase) {
            .idle, .cancel_pending => .no_active_fetch,
            .shutdown => .shutdown,
            .terminal => |terminal| if (terminal.handle == handle) .terminal else .handle_mismatch,
            .request_pending, .awaiting_response, .streaming => |active| if (active == handle)
                .phase_mismatch
            else
                .handle_mismatch,
        },
    };
}

fn expectDecision(expected: Decision, actual: Decision) !void {
    try std.testing.expectEqualDeep(expected, actual);
}
