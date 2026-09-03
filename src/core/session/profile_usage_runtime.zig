const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_usage_store = @import("profile_usage_store.zig");
const session_usage = @import("session_usage.zig");
const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;

pub const InitializeOutcome = enum {
    available,
    unavailable,
};

pub const Recovery = struct {
    facts: []const usage_report.GenerationFact = &.{},
    incidents: []const usage_report.Incident = &.{},
    pending: []const usage_report.PendingMarker = &.{},
    unknown_pending: bool = false,
};

pub const Runtime = struct {
    /// Serializes the store and its diagnostic state across the reconciliation
    /// worker and interactive usage refreshes.
    mutex: std.Io.Mutex = .init,
    store: ?profile_usage_store.Store = null,
    last_error: ?anyerror = null,

    pub fn initialize(
        self: *Runtime,
        alloc: Allocator,
        home_path: ?[]const u8,
    ) !InitializeOutcome {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.store) |*store| store.deinit(alloc);
        self.store = null;
        self.last_error = null;
        const home = home_path orelse return .unavailable;
        self.store = profile_usage_store.Store.initFromHome(alloc, home) catch |err| {
            if (err == error.OutOfMemory) return err;
            self.last_error = err;
            debug_trace.logf(
                "usage",
                "profile usage initialization unavailable reason={s}",
                .{@errorName(err)},
            );
            return .unavailable;
        };
        return .available;
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.store) |*store| store.deinit(alloc);
        self.store = null;
        self.last_error = null;
    }

    pub fn publisherSink(
        self: *Runtime,
        alloc: Allocator,
    ) session_usage.ProfilePublicationSink {
        return .{
            .context = self,
            .allocator = alloc,
            .publish = publishEvent,
        };
    }

    pub fn isAvailable(self: *const Runtime) bool {
        return self.store != null;
    }

    pub fn snapshot(
        self: *Runtime,
        alloc: Allocator,
        scope: usage_report.Scope,
        snapshot_time_ms: i64,
        recovery: Recovery,
    ) !usage_report.Snapshot {
        if (scope == .session) return error.InvalidUsageScope;
        var loaded = try self.load(alloc);
        defer loaded.deinit(alloc);
        return buildSnapshot(alloc, loaded, scope, snapshot_time_ms, recovery);
    }

    pub fn rollingSnapshots(
        self: *Runtime,
        alloc: Allocator,
        snapshot_time_ms: i64,
        recovery: Recovery,
    ) ![3]usage_report.Snapshot {
        const scopes = [_]usage_report.Scope{
            .days_30,
            .days_7,
            .hours_24,
        };
        var loaded = try self.load(alloc);
        defer loaded.deinit(alloc);
        var snapshots: [scopes.len]usage_report.Snapshot = undefined;
        var built: usize = 0;
        errdefer for (snapshots[0..built]) |*item| item.deinit(alloc);
        for (scopes, 0..) |scope, index| {
            snapshots[index] = try buildSnapshot(
                alloc,
                loaded,
                scope,
                snapshot_time_ms,
                recovery,
            );
            built += 1;
        }
        return snapshots;
    }

    fn load(self: *Runtime, alloc: Allocator) !profile_usage_store.Loaded {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const store = if (self.store) |*value| value else return error.ProfileUsageUnavailable;
        const loaded = store.load(alloc) catch |err| {
            self.last_error = err;
            return err;
        };
        self.last_error = null;
        return loaded;
    }

    pub fn lastError(self: *Runtime) ?anyerror {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.last_error;
    }

    fn publishEvent(
        context: *anyopaque,
        event: usage_report.ProfileEvent,
    ) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const store = if (self.store) |*value| value else return error.ProfileUsageUnavailable;
        const outcome = store.appendEvent(std.heap.c_allocator, event) catch |err| {
            self.last_error = err;
            return err;
        };
        if (outcome == .conflict) {
            self.last_error = error.ConflictingUsagePublication;
            return error.ConflictingUsagePublication;
        }
        self.last_error = null;
    }
};

fn buildSnapshot(
    alloc: Allocator,
    loaded: profile_usage_store.Loaded,
    scope: usage_report.Scope,
    snapshot_time_ms: i64,
    recovery: Recovery,
) !usage_report.Snapshot {
    var coverage_started_at_ms = loaded.coverage_started_at_ms;
    for (recovery.facts) |fact| {
        coverage_started_at_ms = if (coverage_started_at_ms) |started_at_ms|
            @min(started_at_ms, fact.created_at_ms)
        else
            fact.created_at_ms;
    }
    for (recovery.incidents) |incident| {
        coverage_started_at_ms = if (coverage_started_at_ms) |started_at_ms|
            @min(started_at_ms, incident.occurred_at_ms)
        else
            incident.occurred_at_ms;
    }
    for (recovery.pending) |marker| {
        coverage_started_at_ms = if (coverage_started_at_ms) |started_at_ms|
            @min(started_at_ms, marker.observed_at_ms)
        else
            marker.observed_at_ms;
    }

    const facts = try alloc.alloc(
        usage_report.GenerationFact,
        loaded.facts.len + recovery.facts.len,
    );
    defer alloc.free(facts);
    std.mem.copyForwards(
        usage_report.GenerationFact,
        facts[0..loaded.facts.len],
        loaded.facts,
    );
    std.mem.copyForwards(
        usage_report.GenerationFact,
        facts[loaded.facts.len..],
        recovery.facts,
    );

    var durable_fact_ids: std.StringHashMapUnmanaged(void) = .empty;
    defer durable_fact_ids.deinit(alloc);
    try durable_fact_ids.ensureTotalCapacity(
        alloc,
        @intCast(loaded.facts.len),
    );
    for (loaded.facts) |fact| durable_fact_ids.putAssumeCapacity(fact.id, {});

    var unknown_pending = recovery.unknown_pending;
    const incidents = try alloc.alloc(
        usage_report.Incident,
        loaded.incidents.len +
            recovery.incidents.len +
            recovery.facts.len +
            loaded.pending.len +
            recovery.pending.len +
            @intFromBool(unknown_pending),
    );
    defer alloc.free(incidents);
    std.mem.copyForwards(
        usage_report.Incident,
        incidents[0..loaded.incidents.len],
        loaded.incidents,
    );
    var incident_count = loaded.incidents.len;
    for (recovery.incidents) |incident| {
        incidents[incident_count] = incident;
        incident_count += 1;
    }
    for (recovery.facts) |fact| {
        if (durable_fact_ids.contains(fact.id)) continue;
        if (fact.created_at_ms >= snapshot_time_ms) {
            unknown_pending = true;
            continue;
        }
        incidents[incident_count] = .{
            .occurred_at_ms = fact.created_at_ms,
            .completeness = .pending,
        };
        incident_count += 1;
    }
    inline for (.{ loaded.pending, recovery.pending }) |markers| {
        for (markers) |marker| {
            if (durable_fact_ids.contains(marker.id)) continue;
            if (marker.observed_at_ms >= snapshot_time_ms) {
                unknown_pending = true;
                continue;
            }
            incidents[incident_count] = .{
                .occurred_at_ms = marker.observed_at_ms,
                .completeness = .pending,
            };
            incident_count += 1;
        }
    }
    if (unknown_pending) {
        incidents[incident_count] = .{
            .occurred_at_ms = @max(snapshot_time_ms -| 1, 0),
            .completeness = .incomplete,
        };
        incident_count += 1;
    }

    return usage_report.buildRollingSnapshot(
        alloc,
        scope,
        snapshot_time_ms,
        coverage_started_at_ms,
        facts,
        incidents[0..incident_count],
    );
}
