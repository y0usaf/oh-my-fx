const std = @import("std");

pub const default_max_provider_attempts: usize = 10;
pub const max_retry_after_seconds: u64 = 30;

pub const FailureCause = enum {
    transport_interrupted,
    response_interrupted,
    provider_unavailable,
    rate_limited,
    system_resumed,
    authentication,
    request_limit_reached,
    content_filter,
};

pub const Delivery = enum {
    definitely_unsent,
    possibly_sent,
};

pub const OutputEvidence = enum {
    none,
    partial,
};

pub const ToolEvidence = enum {
    none,
    proven_unexecuted,
    confirmed,
    uncertain,
};

pub const AttemptState = struct {
    consumed: usize,
    limit: usize = default_max_provider_attempts,

    pub fn remaining(self: AttemptState) usize {
        return self.limit -| self.consumed;
    }
};

/// Ephemeral backoff state. AttemptState remains the durable request budget.
pub const RetryPacingState = union(enum) {
    idle,
    implicit: struct {
        cause: FailureCause,
        attempt: usize,
    },

    fn afterFailure(
        self: RetryPacingState,
        cause: FailureCause,
        retry_after_seconds: ?u64,
    ) RetryPacingState {
        if (retry_after_seconds != null) return .idle;
        return switch (self) {
            .idle => .{ .implicit = .{ .cause = cause, .attempt = 1 } },
            .implicit => |previous| if (previous.cause == cause)
                .{ .implicit = .{
                    .cause = cause,
                    .attempt = previous.attempt +| 1,
                } }
            else
                .{ .implicit = .{ .cause = cause, .attempt = 1 } },
        };
    }
};

pub const Strategy = enum {
    retry_request,
    continue_response,
    regenerate_tool,
    continue_after_confirmed_tool,
    reconcile_tool,
    pause,
    stop,
};

pub const RequiredAction = enum {
    none,
    continue_later,
    inspect_uncertain_tool,
    change_request,
};

pub const Evidence = struct {
    cause: FailureCause,
    delivery: Delivery,
    attempts: AttemptState,
    output: OutputEvidence = .none,
    tool: ToolEvidence = .none,
    pacing: RetryPacingState = .idle,
    retry_after_seconds: ?u64 = null,
    cancelled: bool = false,
};

pub const Decision = struct {
    strategy: Strategy,
    delay_ns: u64 = 0,
    next_pacing: RetryPacingState = .idle,
    reserve_provider_attempt: bool = false,
    required_action: RequiredAction = .none,
};

/// Pure model-response policy. It describes the next effect but never sleeps,
/// sends, mutates stream state, or persists a checkpoint.
pub noinline fn decide(evidence: Evidence) Decision {
    if (evidence.cancelled) return .{ .strategy = .stop };

    switch (evidence.cause) {
        .content_filter => return .{
            .strategy = .stop,
            .required_action = .change_request,
        },
        .request_limit_reached => return .{
            .strategy = .pause,
            .required_action = .continue_later,
        },
        else => {},
    }

    if (evidence.attempts.remaining() == 0) {
        return .{
            .strategy = .pause,
            .required_action = if (evidence.tool == .uncertain)
                .inspect_uncertain_tool
            else
                .continue_later,
        };
    }

    const strategy: Strategy = if (evidence.delivery == .definitely_unsent)
        .retry_request
    else switch (evidence.tool) {
        .proven_unexecuted => .regenerate_tool,
        .confirmed => .continue_after_confirmed_tool,
        .uncertain => .reconcile_tool,
        .none => if (evidence.output == .partial)
            .continue_response
        else
            .retry_request,
    };
    const next_pacing = evidence.pacing.afterFailure(
        evidence.cause,
        evidence.retry_after_seconds,
    );
    const delay_ns = if (evidence.retry_after_seconds) |seconds| blk: {
        const bounded_seconds: u64 = @min(seconds, max_retry_after_seconds);
        break :blk bounded_seconds * std.time.ns_per_s;
    } else switch (next_pacing) {
        .idle => unreachable,
        .implicit => |pacing| retryDelayNs(pacing.attempt),
    };
    return .{
        .strategy = strategy,
        .delay_ns = delay_ns,
        .next_pacing = next_pacing,
        .reserve_provider_attempt = true,
    };
}

/// Delay before the next provider request after `attempt` consecutive implicit
/// backoffs: 250 ms,
/// 1 s, then exponential growth capped at 30 s.
pub fn retryDelayNs(attempt: usize) u64 {
    if (attempt == 0) return 0;
    if (attempt == 1) return 250 * std.time.ns_per_ms;

    var seconds: u64 = 1;
    var current: usize = 2;
    while (current < attempt and seconds < max_retry_after_seconds) : (current += 1) {
        seconds = @min(seconds * 2, max_retry_after_seconds);
    }
    return seconds * std.time.ns_per_s;
}

/// Fast is an optimization, not a recovery requirement. A replay-safe
/// provider outage may fall back to the canonical route without changing the
/// semantic request budget.
pub fn shouldDisableFastRoute(
    fast_mode: bool,
    cause: FailureCause,
    replay_safe: bool,
) bool {
    return fast_mode and cause == .provider_unavailable and replay_safe;
}

pub const ContinuationProbeOutcome = enum {
    may_extend,
    cannot_extend,
    budget_exhausted,
};

pub const ContinuationProbe = struct {
    outcome: ContinuationProbeOutcome,
    comparisons: usize,
};

/// Determines whether more incoming bytes could extend the overlap while
/// performing no more than `comparison_budget` byte comparisons.
pub fn probeContinuationExtension(
    existing: []const u8,
    incoming: []const u8,
    comparison_budget: usize,
) ContinuationProbe {
    if (incoming.len >= existing.len) return .{
        .outcome = .cannot_extend,
        .comparisons = 0,
    };

    const candidate_count = existing.len - incoming.len;
    var comparisons: usize = 0;
    var start: usize = 0;
    while (start < candidate_count) : (start += 1) {
        var matched = true;
        for (incoming, 0..) |byte, offset| {
            if (comparisons == comparison_budget) return .{
                .outcome = .budget_exhausted,
                .comparisons = comparisons,
            };
            comparisons += 1;
            if (existing[start + offset] != byte) {
                matched = false;
                break;
            }
        }
        if (matched) return .{
            .outcome = .may_extend,
            .comparisons = comparisons,
        };
    }
    return .{
        .outcome = .cannot_extend,
        .comparisons = comparisons,
    };
}

/// Returns only the longest byte-exact suffix/prefix overlap in linear time.
/// This deliberately avoids fuzzy or semantic matching, which could delete
/// legitimate output.
pub fn exactContinuationOverlap(
    alloc: std.mem.Allocator,
    existing: []const u8,
    incoming: []const u8,
) !usize {
    if (existing.len == 0 or incoming.len == 0) return 0;

    const prefix = try alloc.alloc(usize, incoming.len);
    defer alloc.free(prefix);
    prefix[0] = 0;

    var matched: usize = 0;
    var incoming_idx: usize = 1;
    while (incoming_idx < incoming.len) : (incoming_idx += 1) {
        while (matched > 0 and incoming[incoming_idx] != incoming[matched]) {
            matched = prefix[matched - 1];
        }
        if (incoming[incoming_idx] == incoming[matched]) matched += 1;
        prefix[incoming_idx] = matched;
    }

    matched = 0;
    for (existing) |byte| {
        while (matched > 0 and
            (matched == incoming.len or incoming[matched] != byte))
        {
            matched = prefix[matched - 1];
        }
        if (incoming[matched] == byte) matched += 1;
    }
    return matched;
}
