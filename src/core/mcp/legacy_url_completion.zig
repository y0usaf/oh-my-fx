const std = @import("std");
const elicitation = @import("elicitation.zig");
const tool_subscription = @import("tool_subscription.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");

const Allocator = std.mem.Allocator;

pub const Waiter = struct {
    binding: elicitation.Binding,
    ids: []const []const u8,
    completed: []bool,
    signal: tool_mcp_runtime.LegacyUrlCompletionSignal = .{},
};

pub const WireCompletionIdentity = struct {
    server_name: []const u8,
    elicitation_id: []const u8,
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    auth_generation: u64,
};

pub const EarlyCompletion = struct {
    server_name: []u8,
    elicitation_id: []u8,
    runtime_generation: u64,
    connection_generation: u64,
    client_generation: u64,
    auth_generation: u64,
    window_generation: u64,
    deadline_ms: i64,
    logout_fenced: bool = false,

    pub fn deinit(self: *EarlyCompletion, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.elicitation_id);
        self.* = undefined;
    }
};

pub const Candidate = struct {
    pub const Status = enum { issued, early, logout_fenced, handled };

    server_name: []u8,
    elicitation_id: []u8,
    runtime_generation: u64,
    connection_generation: u64,
    client_generation: u64,
    auth_generation: u64,
    status: Status = .issued,

    pub fn deinit(self: *Candidate, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.elicitation_id);
        self.* = undefined;
    }
};

pub const Publication = struct {
    sink: tool_mcp_runtime.LegacyUrlCompletionSink,
    id: []u8,
};

pub const ReplayStep = union(enum) {
    done,
    progressed,
    publication: Publication,
};

pub const Window = struct {
    source: tool_subscription.NotificationSource,
    runtime_generation: u64,
    generation: u64,
};

pub fn candidateMatchesWire(candidate: Candidate, completion: WireCompletionIdentity) bool {
    return candidate.runtime_generation == completion.runtime_generation and
        candidate.connection_generation == completion.connection_generation and
        candidate.client_generation == completion.client_generation and
        candidate.auth_generation == completion.auth_generation and
        std.mem.eql(u8, candidate.server_name, completion.server_name) and
        std.mem.eql(u8, candidate.elicitation_id, completion.elicitation_id);
}

pub fn candidateMatchesWaiterId(candidate: Candidate, waiter: *const Waiter, id: []const u8) bool {
    return candidate.runtime_generation == waiter.binding.runtime_generation and
        candidate.connection_generation == waiter.binding.connection_generation and
        candidate.client_generation == waiter.binding.client_generation and
        candidate.auth_generation == waiter.binding.auth_generation and
        std.mem.eql(u8, candidate.server_name, waiter.binding.server_name) and
        std.mem.eql(u8, candidate.elicitation_id, id);
}

pub fn apply(
    waiter: *Waiter,
    completion: elicitation.LegacyUrlCompletionIdentity,
    now_ms: i64,
) bool {
    if (waiter.signal.status.load(.acquire) != .pending) return false;
    const transition = elicitation.decideLegacyUrlCompletion(
        waiter.binding,
        waiter.ids,
        waiter.completed,
        completion,
        now_ms,
        true,
    );
    switch (transition) {
        .record => |record| {
            waiter.completed[record.index] = true;
            if (record.all_complete) {
                waiter.signal.status.store(.completed, .release);
                waiter.signal.wake.store(true, .release);
            }
            return true;
        },
        .reject => return false,
    }
}

pub fn wireCompletionTargetsWaiter(waiter: *const Waiter, completion: WireCompletionIdentity) bool {
    if (!std.mem.eql(u8, waiter.binding.server_name, completion.server_name) or
        waiter.binding.runtime_generation != completion.runtime_generation or
        waiter.binding.connection_generation != completion.connection_generation or
        waiter.binding.client_generation != completion.client_generation or
        waiter.binding.auth_generation != completion.auth_generation)
    {
        return false;
    }
    for (waiter.ids) |id| {
        if (std.mem.eql(u8, id, completion.elicitation_id)) return true;
    }
    return false;
}
