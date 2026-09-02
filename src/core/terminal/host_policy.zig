const std = @import("std");
const contracts = @import("contracts.zig");

pub const queue_capacity: usize = 16;
pub const outcome_capacity: usize = 32;

pub const IdleFacts = struct {
    connected_clients: usize = 0,
    pending_requests: usize = 0,
    live_work: usize = 0,
    monitor_required: bool = false,
};

pub fn idleEligible(facts: IdleFacts) bool {
    return facts.connected_clients == 0 and
        facts.pending_requests == 0 and
        facts.live_work == 0 and
        !facts.monitor_required;
}

pub const QueueAdmission = enum {
    admit,
    full,
    stopping,
};

pub fn classifyQueueAdmission(
    queued: usize,
    capacity: usize,
    stopping: bool,
) QueueAdmission {
    if (stopping) return .stopping;
    if (queued >= capacity) return .full;
    return .admit;
}

pub const ConnectionEvidence = enum {
    connected,
    endpoint_missing,
    refused,
    failed,
};

pub const LockEvidence = enum {
    acquired,
    held,
    unavailable,
};

pub const IdentityEvidence = enum {
    absent,
    live,
    dead,
    unverifiable,
};

pub const Reconciliation = enum {
    reuse_connected,
    wait_for_authority,
    start_host,
    remove_stale_then_start,
    preserve_identity_conflict,
    unavailable,
};

pub fn classifyReconciliation(
    connection: ConnectionEvidence,
    lock: LockEvidence,
    identity: IdentityEvidence,
) Reconciliation {
    if (connection == .connected) return .reuse_connected;
    return switch (lock) {
        .held => .wait_for_authority,
        .unavailable => .unavailable,
        .acquired => switch (identity) {
            .live, .unverifiable => .preserve_identity_conflict,
            .absent, .dead => if (connection == .endpoint_missing)
                .start_host
            else
                .remove_stale_then_start,
        },
    };
}

pub const PendingRequests = struct {
    values: [outcome_capacity]?contracts.CorrelationId = @splat(null),

    pub fn add(
        self: *PendingRequests,
        correlation_id: contracts.CorrelationId,
    ) error{ DuplicateCorrelation, CapacityExceeded }!void {
        correlation_id.validate() catch return error.DuplicateCorrelation;
        var free_index: ?usize = null;
        for (self.values, 0..) |entry, index| {
            if (entry) |existing| {
                if (existing.value == correlation_id.value) {
                    return error.DuplicateCorrelation;
                }
            } else if (free_index == null) {
                free_index = index;
            }
        }
        self.values[free_index orelse return error.CapacityExceeded] = correlation_id;
    }

    pub fn complete(
        self: *PendingRequests,
        correlation_id: contracts.CorrelationId,
    ) bool {
        return self.remove(correlation_id);
    }

    pub fn cancel(
        self: *PendingRequests,
        correlation_id: contracts.CorrelationId,
    ) bool {
        return self.remove(correlation_id);
    }

    pub fn contains(
        self: *const PendingRequests,
        correlation_id: contracts.CorrelationId,
    ) bool {
        for (self.values) |entry| {
            if (entry) |existing| {
                if (existing.value == correlation_id.value) return true;
            }
        }
        return false;
    }

    fn remove(
        self: *PendingRequests,
        correlation_id: contracts.CorrelationId,
    ) bool {
        for (&self.values) |*entry| {
            const existing = entry.* orelse continue;
            if (existing.value != correlation_id.value) continue;
            entry.* = null;
            return true;
        }
        return false;
    }
};




