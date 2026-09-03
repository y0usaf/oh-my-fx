const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const types = @import("../shared/types.zig");
const session_store = @import("session_store.zig");
const session_usage = @import("session_usage.zig");
const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;
const max_recovery_facts: usize = 4096;
const max_recovery_incidents: usize = 4096;
const max_recovery_pending: usize = 4096;

pub const OwnedRecovery = struct {
    facts: []usage_report.GenerationFact,
    incidents: []usage_report.Incident,
    pending: []usage_report.PendingMarker,
    unknown_pending: bool,

    pub fn deinit(self: *OwnedRecovery, alloc: Allocator) void {
        for (self.facts) |*fact| fact.deinit(alloc);
        alloc.free(self.facts);
        alloc.free(self.incidents);
        for (self.pending) |hint| alloc.free(hint.id);
        alloc.free(self.pending);
        self.* = undefined;
    }
};

/// Collects unresolved publication state through the bounded recovery
/// registry. Only marked sessions are loaded; historical session directories
/// are never scanned.
pub fn collectFromHome(
    alloc: Allocator,
    home_path: []const u8,
) !OwnedRecovery {
    return collectFromHomeCancelable(alloc, home_path, null);
}

fn collectFromHomeCancelable(
    alloc: Allocator,
    home_path: []const u8,
    cancel_requested: ?*const std.atomic.Value(bool),
) !OwnedRecovery {
    if (cancelRequested(cancel_requested)) return error.Cancelled;
    var store = session_store.Store.initReadOnlyFromHome(
        alloc,
        home_path,
        "/",
    ) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    defer store.deinit(alloc);

    var marked_sessions = try store.listUsageRecoverySessions(alloc);
    defer {
        for (marked_sessions.items) |*entry| entry.deinit(alloc);
        marked_sessions.deinit(alloc);
    }

    var facts: std.ArrayList(usage_report.GenerationFact) = .empty;
    errdefer {
        for (facts.items) |*fact| fact.deinit(alloc);
        facts.deinit(alloc);
    }
    var incidents: std.ArrayList(usage_report.Incident) = .empty;
    errdefer incidents.deinit(alloc);
    var pending_hints: std.ArrayList(usage_report.PendingMarker) = .empty;
    errdefer {
        for (pending_hints.items) |hint| alloc.free(hint.id);
        pending_hints.deinit(alloc);
    }
    var unknown_pending = false;

    for (marked_sessions.items) |marked| {
        if (cancelRequested(cancel_requested)) return error.Cancelled;
        var state = store.loadReadOnly(alloc, marked.id) catch {
            unknown_pending = true;
            continue;
        };
        defer state.deinit(alloc);
        const usage = state.usage orelse {
            unknown_pending = true;
            continue;
        };
        if (!session_usage.needsProfileRecovery(usage)) {
            if (marked.protected_updated_at_ms) |protected| {
                if (state.updated_at_ms >= protected) continue;
            }
            unknown_pending = true;
            continue;
        }
        if (marked.protected_updated_at_ms) |protected| {
            if (state.updated_at_ms < protected) {
                unknown_pending = true;
            }
        }

        if (usage.settled_through_sequence != usage.next_sequence - 1) {
            unknown_pending = true;
        }
        for (usage.publication_backlog) |fact| {
            if (facts.items.len == max_recovery_facts) {
                unknown_pending = true;
                break;
            }
            try facts.append(alloc, try fact.dupe(alloc));
        }
        for (usage.incidents) |incident| {
            if (incidents.items.len == max_recovery_incidents) {
                unknown_pending = true;
                break;
            }
            try incidents.append(alloc, incident);
        }
        for (usage.pending) |pending| {
            if (pending_hints.items.len == max_recovery_pending) {
                unknown_pending = true;
                break;
            }
            const id = try alloc.dupe(u8, pending.id);
            errdefer alloc.free(id);
            try pending_hints.append(alloc, .{
                .id = id,
                .observed_at_ms = pending.observed_at_ms orelse
                    @max(state.updated_at_ms, 0),
            });
        }
        if (usage.billing == .incomplete and
            usage.incidents.len == 0 and
            usage.settled_through_sequence == usage.next_sequence - 1)
        {
            if (incidents.items.len == max_recovery_incidents) {
                unknown_pending = true;
            } else {
                try incidents.append(alloc, .{
                    .occurred_at_ms = @max(state.updated_at_ms, 0),
                    .completeness = .incomplete,
                });
            }
        }
    }

    return .{
        .facts = try facts.toOwnedSlice(alloc),
        .incidents = try incidents.toOwnedSlice(alloc),
        .pending = try pending_hints.toOwnedSlice(alloc),
        .unknown_pending = unknown_pending,
    };
}

pub fn collectFromHomeConservative(
    alloc: Allocator,
    home_path: []const u8,
) !OwnedRecovery {
    return collectFromHome(
        alloc,
        home_path,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf(
            "usage",
            "local usage recovery incomplete reason={s}",
            .{@errorName(err)},
        );
        return unknown(alloc);
    };
}

pub fn collectFromHomeConservativeCancelable(
    alloc: Allocator,
    home_path: []const u8,
    cancel_requested: *const std.atomic.Value(bool),
) !OwnedRecovery {
    return collectFromHomeCancelable(
        alloc,
        home_path,
        cancel_requested,
    ) catch |err| {
        if (err == error.OutOfMemory or err == error.Cancelled) return err;
        debug_trace.logf(
            "usage",
            "local usage recovery incomplete reason={s}",
            .{@errorName(err)},
        );
        return unknown(alloc);
    };
}

fn cancelRequested(cancel_requested: ?*const std.atomic.Value(bool)) bool {
    return if (cancel_requested) |flag| flag.load(.seq_cst) else false;
}

fn empty(alloc: Allocator) Allocator.Error!OwnedRecovery {
    return .{
        .facts = try alloc.alloc(usage_report.GenerationFact, 0),
        .incidents = try alloc.alloc(usage_report.Incident, 0),
        .pending = try alloc.alloc(usage_report.PendingMarker, 0),
        .unknown_pending = false,
    };
}

fn unknown(alloc: Allocator) Allocator.Error!OwnedRecovery {
    var recovery = try empty(alloc);
    recovery.unknown_pending = true;
    return recovery;
}
