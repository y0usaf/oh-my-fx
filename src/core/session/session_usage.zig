const std = @import("std");
const builtin = @import("builtin");
const secret = @import("../auth/secret.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const generation_fact_codec = @import("generation_fact_codec.zig");
const generation_usage = @import("generation_usage_provider.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const stream_provider = @import("../agent/stream_provider.zig");
const model_provider = @import("../config/model_provider.zig");
const credential_authority = @import("../auth/credential_authority.zig");
pub const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const max_models: usize = 32;
const max_pending_generations: usize = 16;
const max_publication_backlog: usize = 16;
const max_usage_incidents: usize = 16;
const max_model_bytes: usize = 1024;
const max_origin_bytes: usize = 2048;
const max_team_bytes: usize = 255;
const max_identifier_bytes: usize = 8 * 1024;
const max_active_invocations: usize = 64;
const shutdown_reconciliation_budget_ms: usize = 250;
pub const max_snapshot_bytes: usize = 256 * 1024;

/// Completeness of the saved billing window rendered by `/cost`.
pub const Availability = enum {
    /// Every billable invocation has an authoritative generation record.
    complete,
    /// Known generation identities still require reconciliation.
    pending,
    /// Billing may have occurred without a recoverable authoritative record.
    incomplete,
    /// The persisted session predates usage accounting.
    legacy,
};

/// Billing consequence of one logical Gateway invocation across retries.
pub const DeliveryOutcome = enum {
    /// Delivery was proven not to create a billable generation.
    unbilled,
    /// A validated generation identity can be reconciled.
    observed_generation,
    /// Delivery succeeded but no usable generation identity was returned.
    possibly_billed_without_identity,
    /// Transport evidence cannot prove whether a billable generation was created.
    ambiguous_delivery,
};

/// Host-owned durable sink. Its context and allocator remain borrowed until
/// the sink is unset; `persist` must not retain the snapshot, checkpoint, or
/// reconfigure the sink.
pub const UsageCheckpointSink = struct {
    context: *anyopaque,
    allocator: Allocator,
    persist: *const fn (context: *anyopaque, snapshot: Snapshot) anyerror!void,
};

/// Host-owned local-profile publication sink. The callback receives a borrowed
/// event and must return only after it is durably accepted or deduplicated.
pub const ProfilePublicationSink = struct {
    context: *anyopaque,
    allocator: Allocator,
    publish: *const fn (
        context: *anyopaque,
        event: usage_report.ProfileEvent,
    ) anyerror!void,
};

const ProfilePublicationBatch = struct {
    pending: []usage_report.PendingMarker,
    incidents: []usage_report.Incident,
    facts: []usage_report.GenerationFact,
    checkpoint_changed: bool,

    fn deinit(self: *ProfilePublicationBatch, alloc: Allocator) void {
        for (self.pending) |*marker| marker.deinit(alloc);
        alloc.free(self.pending);
        alloc.free(self.incidents);
        for (self.facts) |*fact| fact.deinit(alloc);
        alloc.free(self.facts);
        self.* = undefined;
    }
};

/// One admitted provider invocation. `begin` durably reserves it before network I/O;
/// every successful reservation must terminate through `fail` or `complete`.
pub const InvocationObservation = struct {
    usage: ?*Usage,
    sequence: u64 = 0,
    started_at_ms: i64,

    pub fn begin(usage: ?*Usage) !InvocationObservation {
        return .{
            .usage = usage,
            .sequence = if (usage) |ledger| try ledger.reserveInvocationDurably() else 0,
            .started_at_ms = io_mod.milliTimestamp(),
        };
    }

    pub fn fail(self: InvocationObservation, outcome: DeliveryOutcome) !void {
        const ledger = self.usage orelse return;
        try ledger.finishInvocationDurably(self.sequence, self.elapsedMs(), outcome);
    }

    pub fn complete(
        self: InvocationObservation,
        alloc: Allocator,
        completion: types.ModelCompletion,
        usage_outcome: stream_provider.UsageOutcome,
    ) !void {
        const ledger = self.usage orelse return;
        switch (usage_outcome) {
            .unavailable => |availability| {
                const delivery: DeliveryOutcome = switch (availability) {
                    .unbilled => .unbilled,
                    .possibly_billed => if (completion.delivery_ambiguous)
                        .ambiguous_delivery
                    else
                        .possibly_billed_without_identity,
                };
                try ledger.finishInvocationDurably(self.sequence, self.elapsedMs(), delivery);
                if (delivery == .possibly_billed_without_identity) {
                    debug_trace.logf(
                        "session",
                        "usage billing incomplete sequence={d} reason=generation_identity_missing",
                        .{self.sequence},
                    );
                }
                return;
            },
            .exact, .deferred => {},
        }
        const delivery: DeliveryOutcome = if (completion.delivery_ambiguous)
            .ambiguous_delivery
        else if (!completion.generation_metadata_invalid)
            .observed_generation
        else
            .possibly_billed_without_identity;
        if (completion.generation_metadata_invalid) {
            try ledger.finishInvocationDurably(self.sequence, self.elapsedMs(), delivery);
            debug_trace.logf(
                "session",
                "usage generation ignored sequence={d} metadata_invalid=true",
                .{self.sequence},
            );
            return;
        }
        switch (usage_outcome) {
            .exact => |provider| {
                const generation_id = completion.generation_id orelse {
                    try ledger.finishInvocationDurably(
                        self.sequence,
                        self.elapsedMs(),
                        if (completion.delivery_ambiguous)
                            .ambiguous_delivery
                        else
                            .possibly_billed_without_identity,
                    );
                    debug_trace.logf(
                        "session",
                        "usage billing incomplete sequence={d} reason=generation_identity_missing",
                        .{self.sequence},
                    );
                    return;
                };
                const billing = completion.billing orelse {
                    try ledger.finishInvocationDurably(
                        self.sequence,
                        self.elapsedMs(),
                        if (completion.delivery_ambiguous)
                            .ambiguous_delivery
                        else
                            .possibly_billed_without_identity,
                    );
                    debug_trace.logf(
                        "session",
                        "usage billing incomplete sequence={d} reason=exact_usage_missing",
                        .{self.sequence},
                    );
                    return;
                };
                const accepted = try ledger.finishExactInvocationDurably(
                    alloc,
                    self.sequence,
                    self.elapsedMs(),
                    delivery,
                    provider,
                    generation_id,
                    billing,
                );
                if (!accepted) return;
                debug_trace.logf(
                    "session",
                    "usage exact generation settled sequence={d} id={s}",
                    .{ self.sequence, generation_id },
                );
            },
            .deferred => |reference| {
                const accepted = try ledger.finishDeferredInvocationDurably(
                    alloc,
                    self.sequence,
                    self.elapsedMs(),
                    delivery,
                    reference,
                );
                if (!accepted) return;
                debug_trace.logf(
                    "session",
                    "usage generation queued sequence={d} id={s}",
                    .{ self.sequence, reference.generation_id },
                );
                ledger.flushProfilePublications();
            },
            .unavailable => unreachable,
        }
    }

    fn elapsedMs(self: InvocationObservation) u64 {
        const ended_at_ms = io_mod.milliTimestamp();
        if (ended_at_ms <= self.started_at_ms) return 0;
        return std.math.cast(u64, ended_at_ms - self.started_at_ms) orelse
            std.math.maxInt(u64);
    }
};

const GenerationRecord = generation_usage.Record;

pub const ModelAggregate = struct {
    model: []u8,
    first_sequence: u64,
    total_cost: f64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: ?u64 = null,
    request_count: ?u64 = null,
    billable_web_search_calls: u64 = 0,

    fn deinit(self: *ModelAggregate, alloc: Allocator) void {
        alloc.free(self.model);
        self.* = undefined;
    }

    fn dupe(self: ModelAggregate, alloc: Allocator) Allocator.Error!ModelAggregate {
        return .{
            .model = try alloc.dupe(u8, self.model),
            .first_sequence = self.first_sequence,
            .total_cost = self.total_cost,
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_read_tokens = self.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens,
            .reasoning_tokens = self.reasoning_tokens,
            .request_count = self.request_count,
            .billable_web_search_calls = self.billable_web_search_calls,
        };
    }
};

pub const PendingGeneration = struct {
    id: []u8,
    sequence: u64,
    provider: model_provider.ProviderId = .gateway,
    origin: []u8,
    team: ?[]u8,
    credential_source: ?types.CredentialSource = null,
    credential_identity: ?credential_authority.Identity = null,
    account_id: ?[]u8 = null,
    observed_at_ms: ?i64 = null,

    fn deinit(self: *PendingGeneration, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.origin);
        if (self.team) |team| alloc.free(team);
        if (self.account_id) |account_id| alloc.free(account_id);
        self.* = undefined;
    }

    fn dupe(self: PendingGeneration, alloc: Allocator) Allocator.Error!PendingGeneration {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const origin = try alloc.dupe(u8, self.origin);
        errdefer alloc.free(origin);
        const team = if (self.team) |value| try alloc.dupe(u8, value) else null;
        errdefer if (team) |value| alloc.free(value);
        const account_id = if (self.account_id) |value| try alloc.dupe(u8, value) else null;
        return .{
            .id = id,
            .sequence = self.sequence,
            .provider = self.provider,
            .origin = origin,
            .team = team,
            .credential_source = self.credential_source,
            .credential_identity = self.credential_identity,
            .account_id = account_id,
            .observed_at_ms = self.observed_at_ms,
        };
    }
};

pub const Snapshot = struct {
    billing: Availability,
    api_duration_complete: bool,
    wall_duration_complete: bool,
    code_complete: bool,
    next_sequence: u64,
    settled_through_sequence: u64,
    api_duration_ms: u64,
    wall_duration_ms: u64,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64 = null,
    request_count: ?u64 = null,
    billable_web_search_calls: u64,
    lines_added: u64,
    lines_removed: u64,
    models: []ModelAggregate,
    pending: []PendingGeneration,
    publication_backlog: []usage_report.GenerationFact = &.{},
    incidents: []usage_report.Incident = &.{},

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.models) |*model| model.deinit(alloc);
        alloc.free(self.models);
        for (self.pending) |*generation| generation.deinit(alloc);
        alloc.free(self.pending);
        for (self.publication_backlog) |*fact| fact.deinit(alloc);
        if (self.publication_backlog.len > 0) alloc.free(self.publication_backlog);
        if (self.incidents.len > 0) alloc.free(self.incidents);
        self.* = undefined;
    }
};

/// True when a durable session can still contribute profile usage that is not
/// proven present in the profile ledger.
pub fn needsProfileRecovery(snapshot: Snapshot) bool {
    return snapshot.settled_through_sequence != snapshot.next_sequence - 1 or
        snapshot.pending.len > 0 or
        snapshot.publication_backlog.len > 0 or
        snapshot.incidents.len > 0;
}

pub const Usage = struct {
    mutex: std.Io.Mutex = .init,
    checkpoint_mutex: std.Io.Mutex = .init,
    checkpoint_sink: ?UsageCheckpointSink = null,
    publication_mutex: std.Io.Mutex = .init,
    publication_sink: ?ProfilePublicationSink = null,
    billing: Availability,
    api_duration_complete: bool,
    wall_duration_complete: bool,
    code_complete: bool,
    next_sequence: u64 = 1,
    settled_through_sequence: u64 = 0,
    api_duration_ms: u64 = 0,
    wall_duration_ms: u64 = 0,
    active_started_at_ms: i64 = 0,
    active_sequences: [max_active_invocations]u64 = undefined,
    active_sequence_count: usize = 0,
    total_cost: f64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: ?u64,
    request_count: ?u64,
    billable_web_search_calls: u64 = 0,
    lines_added: u64 = 0,
    lines_removed: u64 = 0,
    models: std.ArrayList(ModelAggregate) = .empty,
    pending: std.ArrayList(PendingGeneration) = .empty,
    publication_backlog: std.ArrayList(usage_report.GenerationFact) = .empty,
    incidents: [max_usage_incidents]usage_report.Incident = undefined,
    incident_count: usize = 0,
    dirty: bool = false,
    reconciliation_mutex: std.Io.Mutex = .init,
    reconciliation_thread: ?std.Thread = null,
    reconciliation_done: std.atomic.Value(bool) = .init(true),
    reconciliation_cancel: std.atomic.Value(bool) = .init(false),
    reconciliation_work_epoch: std.atomic.Value(u64) = .init(0),
    reconciliation_key_digest: ?[Sha256.digest_length]u8 = null,
    reconciliation_authority: ?ReconciliationAuthority = null,
    reconciliation_credential_blocked: bool = false,
    generation_usage_providers: generation_usage.Set = .{},

    pub fn initFresh() Usage {
        return .{
            .billing = .complete,
            .api_duration_complete = true,
            .wall_duration_complete = true,
            .code_complete = true,
            .reasoning_tokens = 0,
            .request_count = 0,
        };
    }

    pub fn initFreshWithProvider(provider: generation_usage.Provider) Usage {
        var usage = initFresh();
        usage.generation_usage_providers = generation_usage.Set.gatewayOnly(provider);
        return usage;
    }

    pub fn initFreshWithProviders(providers: generation_usage.Set) Usage {
        var usage = initFresh();
        usage.generation_usage_providers = providers;
        return usage;
    }

    pub fn initLegacy() Usage {
        return .{
            .billing = .legacy,
            .api_duration_complete = false,
            .wall_duration_complete = false,
            .code_complete = false,
            .reasoning_tokens = null,
            .request_count = null,
        };
    }

    pub fn deinit(self: *Usage, alloc: Allocator) void {
        self.stopReconciliation();
        self.clearOwned(alloc);
        self.* = undefined;
    }

    pub fn resetFresh(self: *Usage, alloc: Allocator) void {
        self.stopReconciliation();
        self.reset(alloc, true);
    }

    pub fn resetLegacy(self: *Usage, alloc: Allocator) void {
        self.stopReconciliation();
        self.reset(alloc, false);
    }

    pub fn restoreLegacyWallDuration(
        self: *Usage,
        session_started_at_ms: i64,
    ) void {
        const now_ms = io_mod.milliTimestamp();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (session_started_at_ms <= 0 or session_started_at_ms > now_ms) return;
        self.wall_duration_complete = true;
        self.active_started_at_ms = session_started_at_ms;
    }

    pub fn reserveInvocation(self: *Usage) !u64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.active_started_at_ms == 0) {
            self.active_started_at_ms = io_mod.milliTimestamp();
        }
        const sequence = self.next_sequence;
        if (self.active_sequence_count == max_active_invocations) {
            debug_trace.logf(
                "session",
                "usage invocation reservation failed reason=active_capacity limit={d}",
                .{max_active_invocations},
            );
            return error.UsageCapacityExceeded;
        }
        const next_sequence = std.math.add(u64, sequence, 1) catch {
            debug_trace.logf(
                "session",
                "usage invocation reservation failed reason=sequence_overflow sequence={d}",
                .{sequence},
            );
            return error.UsageSequenceOverflow;
        };
        self.next_sequence = next_sequence;
        self.active_sequences[self.active_sequence_count] = sequence;
        self.active_sequence_count += 1;
        self.dirty = true;
        return sequence;
    }

    pub fn configureCheckpointSink(self: *Usage, sink: ?UsageCheckpointSink) void {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        defer self.checkpoint_mutex.unlock(io_mod.getIo());
        self.checkpoint_sink = sink;
    }

    pub fn configurePublicationSink(
        self: *Usage,
        sink: ?ProfilePublicationSink,
    ) void {
        self.publication_mutex.lockUncancelable(io_mod.getIo());
        self.publication_sink = sink;
        self.publication_mutex.unlock(io_mod.getIo());
        if (sink != null) self.flushProfilePublications();
    }

    pub fn persistCheckpoint(self: *Usage) bool {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        defer self.checkpoint_mutex.unlock(io_mod.getIo());
        return self.persistCheckpointBestEffortLocked();
    }

    fn reserveInvocationDurably(self: *Usage) !u64 {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        defer self.checkpoint_mutex.unlock(io_mod.getIo());
        const sequence = try self.reserveInvocation();
        self.persistCheckpointRequiredLocked() catch |err| {
            self.finishInvocation(sequence, 0, .unbilled);
            return err;
        };
        return sequence;
    }

    fn finishInvocationDurably(
        self: *Usage,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
    ) !void {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        self.finishInvocation(sequence, duration_ms, outcome);
        _ = self.persistCheckpointBestEffortLocked();
        self.checkpoint_mutex.unlock(io_mod.getIo());
        self.flushProfilePublications();
    }

    fn finishObservedInvocationDurably(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        id: []const u8,
        origin: []const u8,
        team: ?[]const u8,
    ) !bool {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        const accepted = self.finishObservedInvocationAccepted(
            alloc,
            sequence,
            duration_ms,
            outcome,
            id,
            origin,
            team,
        ) catch |err| {
            self.markBillingIncomplete();
            _ = self.persistCheckpointBestEffortLocked();
            debug_trace.logf(
                "session",
                "usage generation checkpointed incomplete reason={s}",
                .{@errorName(err)},
            );
            self.checkpoint_mutex.unlock(io_mod.getIo());
            self.flushProfilePublications();
            return false;
        };
        _ = self.persistCheckpointBestEffortLocked();
        self.checkpoint_mutex.unlock(io_mod.getIo());
        return accepted;
    }

    fn finishDeferredInvocationDurably(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        reference: stream_provider.DeferredUsageReference,
    ) !bool {
        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        const accepted = self.finishDeferredInvocationAccepted(
            alloc,
            sequence,
            duration_ms,
            outcome,
            reference,
        ) catch |err| {
            self.markBillingIncomplete();
            _ = self.persistCheckpointBestEffortLocked();
            debug_trace.logf(
                "session",
                "usage generation checkpointed incomplete reason={s}",
                .{@errorName(err)},
            );
            self.checkpoint_mutex.unlock(io_mod.getIo());
            self.flushProfilePublications();
            return false;
        };
        _ = self.persistCheckpointBestEffortLocked();
        self.checkpoint_mutex.unlock(io_mod.getIo());
        return accepted;
    }

    fn finishExactInvocationDurably(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        provider: model_provider.ProviderId,
        external_id: []const u8,
        billing: types.ProviderBilling,
    ) !bool {
        var canonical_buffer: [30]u8 = undefined;
        const canonical_id = canonicalExactGenerationId(
            provider,
            external_id,
            &canonical_buffer,
        ) catch |err| {
            try self.finishInvocationDurably(
                sequence,
                duration_ms,
                if (outcome == .ambiguous_delivery)
                    .ambiguous_delivery
                else
                    .possibly_billed_without_identity,
            );
            debug_trace.logf(
                "session",
                "usage exact generation rejected reason={s}",
                .{@errorName(err)},
            );
            return false;
        };
        const record = GenerationRecord{
            .id = canonical_id,
            .created_at_ms = billing.created_at_ms,
            .model = billing.model,
            .total_cost = billing.total_cost,
            .input_tokens = billing.input_tokens,
            .output_tokens = billing.output_tokens,
            .cache_read_tokens = billing.cache_read_tokens,
            .cache_write_tokens = billing.cache_write_tokens,
            .reasoning_tokens = billing.reasoning_tokens,
            .billable_web_search_calls = billing.billable_web_search_calls,
        };
        validateGenerationRecord(record) catch |err| {
            try self.finishInvocationDurably(
                sequence,
                duration_ms,
                if (outcome == .ambiguous_delivery)
                    .ambiguous_delivery
                else
                    .possibly_billed_without_identity,
            );
            debug_trace.logf(
                "session",
                "usage exact generation rejected reason={s}",
                .{@errorName(err)},
            );
            return false;
        };

        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        const durable_bridge = self.checkpoint_sink != null;
        const accepted = self.finishExactInvocationAccepted(
            alloc,
            sequence,
            duration_ms,
            outcome,
            provider,
            canonical_id,
            record,
            durable_bridge,
        ) catch |err| {
            self.markBillingIncomplete();
            _ = self.persistCheckpointBestEffortLocked();
            self.checkpoint_mutex.unlock(io_mod.getIo());
            debug_trace.logf(
                "session",
                "usage exact generation checkpointed incomplete reason={s}",
                .{@errorName(err)},
            );
            return false;
        };
        if (!accepted) {
            _ = self.persistCheckpointBestEffortLocked();
            self.checkpoint_mutex.unlock(io_mod.getIo());
            return false;
        }
        if (durable_bridge and !self.persistCheckpointBestEffortLocked()) {
            self.checkpoint_mutex.unlock(io_mod.getIo());
            return false;
        }
        self.checkpoint_mutex.unlock(io_mod.getIo());
        if (durable_bridge) self.flushProfilePublications();
        return true;
    }

    fn finishExactInvocationAccepted(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        provider: model_provider.ProviderId,
        generation_id: []const u8,
        record: GenerationRecord,
        durable_bridge: bool,
    ) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.finishInvocationUnlocked(sequence, duration_ms, outcome)) return false;
        try self.observeGenerationFieldsUnlocked(
            alloc,
            sequence,
            generation_id,
            provider,
            exactUsageOrigin(provider),
            null,
            null,
            null,
            null,
        );
        if (durable_bridge) {
            try self.stagePublicationBacklogUnlocked(
                alloc,
                generationFactBorrowed(record),
            );
        } else {
            try self.applyGenerationUnlocked(alloc, record, false);
        }
        return true;
    }

    fn persistCheckpointRequiredLocked(self: *Usage) !void {
        const sink = self.checkpoint_sink orelse return;
        var persisted = try self.snapshotCurrent(sink.allocator);
        defer persisted.deinit(sink.allocator);
        try sink.persist(sink.context, persisted);
        self.markClean(persisted);
    }

    fn persistCheckpointBestEffortLocked(self: *Usage) bool {
        const sink = self.checkpoint_sink orelse return true;
        var persisted = self.snapshotCurrent(sink.allocator) catch |err| {
            self.markBillingIncomplete();
            debug_trace.logf(
                "session",
                "usage checkpoint unavailable; billing marked incomplete reason={s}",
                .{@errorName(err)},
            );
            return false;
        };
        defer persisted.deinit(sink.allocator);
        sink.persist(sink.context, persisted) catch |err| {
            self.markBillingIncomplete();
            debug_trace.logf(
                "session",
                "usage checkpoint unavailable; billing marked incomplete reason={s}",
                .{@errorName(err)},
            );
            return false;
        };
        self.markClean(persisted);
        return true;
    }

    pub fn finishInvocation(
        self: *Usage,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        _ = self.finishInvocationUnlocked(sequence, duration_ms, outcome);
    }

    pub fn finishObservedInvocation(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        id: []const u8,
        origin: []const u8,
        team: ?[]const u8,
    ) !void {
        _ = try self.finishObservedInvocationAccepted(
            alloc,
            sequence,
            duration_ms,
            outcome,
            id,
            origin,
            team,
        );
    }

    fn finishObservedInvocationAccepted(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        id: []const u8,
        origin: []const u8,
        team: ?[]const u8,
    ) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.finishInvocationUnlocked(sequence, duration_ms, outcome)) return false;
        try validateGenerationId(id);
        try validateOrigin(origin);
        if (team) |value| try validateTeam(value);
        self.observeGenerationUnlocked(alloc, sequence, id, origin, team) catch |err| {
            self.billing = .incomplete;
            self.dirty = true;
            return err;
        };
        return true;
    }

    pub fn finishDeferredInvocation(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        reference: stream_provider.DeferredUsageReference,
    ) !void {
        _ = try self.finishDeferredInvocationAccepted(
            alloc,
            sequence,
            duration_ms,
            outcome,
            reference,
        );
    }

    fn finishDeferredInvocationAccepted(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
        reference: stream_provider.DeferredUsageReference,
    ) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.finishInvocationUnlocked(sequence, duration_ms, outcome)) return false;
        try validateGenerationId(reference.generation_id);
        try validateOrigin(reference.scope);
        if (reference.tenant) |value| try validateTeam(value);
        if (reference.account_id) |value| try validateIdentifier(value);
        self.observeGenerationAuthorityUnlocked(alloc, sequence, reference) catch |err| {
            self.billing = .incomplete;
            self.dirty = true;
            return err;
        };
        return true;
    }

    fn finishInvocationUnlocked(
        self: *Usage,
        sequence: u64,
        duration_ms: u64,
        outcome: DeliveryOutcome,
    ) bool {
        if (sequence == 0 or sequence >= self.next_sequence) {
            self.billing = .incomplete;
            self.api_duration_complete = false;
            self.dirty = true;
            return false;
        }
        const active_index = for (self.active_sequences[0..self.active_sequence_count], 0..) |active, index| {
            if (active == sequence) break index;
        } else return false;
        self.active_sequence_count -= 1;
        self.active_sequences[active_index] = self.active_sequences[self.active_sequence_count];
        self.api_duration_ms = std.math.add(u64, self.api_duration_ms, duration_ms) catch {
            self.billing = .incomplete;
            self.api_duration_complete = false;
            self.dirty = true;
            return false;
        };
        switch (outcome) {
            .unbilled, .observed_generation => {},
            .possibly_billed_without_identity, .ambiguous_delivery => {
                self.billing = .incomplete;
                self.recordIncidentUnlocked(.incomplete, io_mod.milliTimestamp());
            },
        }
        if (self.active_sequence_count == 0) {
            self.settled_through_sequence = self.next_sequence - 1;
        }
        self.dirty = true;
        return true;
    }

    fn observeGenerationUnlocked(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        id: []const u8,
        origin: []const u8,
        team: ?[]const u8,
    ) !void {
        return self.observeGenerationFieldsUnlocked(
            alloc,
            sequence,
            id,
            .gateway,
            origin,
            team,
            null,
            null,
            null,
        );
    }

    fn observeGenerationAuthorityUnlocked(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        reference: stream_provider.DeferredUsageReference,
    ) !void {
        return self.observeGenerationFieldsUnlocked(
            alloc,
            sequence,
            reference.generation_id,
            reference.provider,
            reference.scope,
            reference.tenant,
            reference.credential_source,
            reference.credential_identity,
            reference.account_id,
        );
    }

    fn observeGenerationFieldsUnlocked(
        self: *Usage,
        alloc: Allocator,
        sequence: u64,
        id: []const u8,
        provider: model_provider.ProviderId,
        origin: []const u8,
        team: ?[]const u8,
        credential_source: ?types.CredentialSource,
        credential_identity: ?credential_authority.Identity,
        account_id: ?[]const u8,
    ) !void {
        for (self.pending.items) |pending| {
            if (pending.sequence == sequence and !std.mem.eql(u8, pending.id, id)) {
                self.billing = .incomplete;
                self.dirty = true;
                return error.ConflictingGenerationIdentity;
            }
            if (std.mem.eql(u8, pending.id, id)) {
                if (pending.sequence != sequence or
                    pending.provider != provider or
                    !std.mem.eql(u8, pending.origin, origin) or
                    !optionalStringsEqual(pending.team, team) or
                    pending.credential_source != credential_source or
                    !optionalCredentialIdentitiesEqual(pending.credential_identity, credential_identity) or
                    !optionalStringsEqual(pending.account_id, account_id))
                {
                    self.billing = .incomplete;
                    self.dirty = true;
                    return error.ConflictingGenerationIdentity;
                }
                return;
            }
        }
        if (self.pending.items.len >= max_pending_generations) {
            self.billing = .incomplete;
            self.dirty = true;
            return error.UsageCapacityExceeded;
        }
        var added_identifier_bytes = std.math.add(usize, id.len, origin.len) catch
            return self.failOverflow();
        if (team) |value| {
            added_identifier_bytes = std.math.add(
                usize,
                added_identifier_bytes,
                value.len,
            ) catch return self.failOverflow();
        }
        if (account_id) |value| {
            added_identifier_bytes = std.math.add(
                usize,
                added_identifier_bytes,
                value.len,
            ) catch return self.failOverflow();
        }
        const next_identifier_bytes = std.math.add(
            usize,
            self.identifierBytesUnlocked(),
            added_identifier_bytes,
        ) catch return self.failOverflow();
        if (next_identifier_bytes > max_identifier_bytes) {
            self.billing = .incomplete;
            self.dirty = true;
            return error.UsageCapacityExceeded;
        }
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const owned_origin = try alloc.dupe(u8, origin);
        errdefer alloc.free(owned_origin);
        const owned_team = if (team) |value| try alloc.dupe(u8, value) else null;
        errdefer if (owned_team) |value| alloc.free(value);
        const owned_account_id = if (account_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (owned_account_id) |value| alloc.free(value);
        try self.pending.append(alloc, .{
            .id = owned_id,
            .sequence = sequence,
            .provider = provider,
            .origin = owned_origin,
            .team = owned_team,
            .credential_source = credential_source,
            .credential_identity = credential_identity,
            .account_id = owned_account_id,
            .observed_at_ms = io_mod.milliTimestamp(),
        });
        if (self.billing == .complete) self.billing = .pending;
        self.dirty = true;
    }

    pub fn applyGeneration(self: *Usage, alloc: Allocator, record: GenerationRecord) !void {
        try validateGenerationRecord(record);
        const fact = generationFactBorrowed(record);

        self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
        const publication = self.publishFact(fact);
        if (publication != .durable and self.checkpoint_sink != null) {
            self.stagePublicationBacklog(alloc, fact) catch |err| {
                self.checkpoint_mutex.unlock(io_mod.getIo());
                self.flushProfilePublications();
                return err;
            };
            if (!self.persistCheckpointBestEffortLocked()) {
                self.checkpoint_mutex.unlock(io_mod.getIo());
                self.flushProfilePublications();
                return error.ProfilePublicationRecoveryUnavailable;
            }
            self.checkpoint_mutex.unlock(io_mod.getIo());
            self.flushProfilePublications();
            // The rollback-readable event omits the richer publication fact,
            // so the pending generation remains the canonical recovery bridge
            // even when the sidecar preserves the full backlog.
            return;
        }
        if (publication == .failed) {
            self.stagePublicationBacklog(alloc, fact) catch |err| {
                self.checkpoint_mutex.unlock(io_mod.getIo());
                self.flushProfilePublications();
                return err;
            };
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        self.applyGenerationUnlocked(
            alloc,
            record,
            publication == .durable,
        ) catch |err| {
            self.mutex.unlock(io_mod.getIo());
            self.checkpoint_mutex.unlock(io_mod.getIo());
            self.flushProfilePublications();
            return err;
        };
        self.mutex.unlock(io_mod.getIo());
        _ = self.persistCheckpointBestEffortLocked();
        self.checkpoint_mutex.unlock(io_mod.getIo());
        if (publication == .failed) self.flushProfilePublications();
    }

    fn applyGenerationUnlocked(
        self: *Usage,
        alloc: Allocator,
        record: GenerationRecord,
        published: bool,
    ) !void {
        const pending_index = for (self.pending.items, 0..) |pending, index| {
            if (std.mem.eql(u8, pending.id, record.id)) break index;
        } else {
            if (published) self.removePublicationBacklogUnlocked(alloc, record.id);
            return;
        };
        const pending_sequence = self.pending.items[pending_index].sequence;

        const model_index = for (self.models.items, 0..) |model, index| {
            if (std.mem.eql(u8, model.model, record.model)) break index;
        } else null;
        if (model_index == null and self.models.items.len >= max_models) {
            self.billing = .incomplete;
            self.dirty = true;
            return error.UsageCapacityExceeded;
        }
        if (model_index == null) {
            const resolved_pending = self.pending.items[pending_index];
            var removed_identifier_bytes = resolved_pending.id.len +|
                resolved_pending.origin.len;
            if (resolved_pending.team) |team| removed_identifier_bytes +|= team.len;
            if (resolved_pending.account_id) |account_id| removed_identifier_bytes +|= account_id.len;
            const next_identifier_bytes = std.math.add(
                usize,
                self.identifierBytesUnlocked() -| removed_identifier_bytes,
                record.model.len,
            ) catch return self.failOverflow();
            if (next_identifier_bytes > max_identifier_bytes) {
                self.billing = .incomplete;
                self.dirty = true;
                return error.UsageCapacityExceeded;
            }
        }

        const next_total_cost = self.total_cost + record.total_cost;
        if (!std.math.isFinite(next_total_cost)) {
            self.billing = .incomplete;
            self.dirty = true;
            return error.UsageOverflow;
        }
        const next_input_tokens = std.math.add(u64, self.input_tokens, record.input_tokens) catch return self.failOverflow();
        const next_output_tokens = std.math.add(u64, self.output_tokens, record.output_tokens) catch return self.failOverflow();
        const next_cache_read_tokens = std.math.add(u64, self.cache_read_tokens, record.cache_read_tokens) catch return self.failOverflow();
        const next_cache_write_tokens = std.math.add(u64, self.cache_write_tokens, record.cache_write_tokens) catch return self.failOverflow();
        const next_reasoning_tokens = try addOptionalCounter(
            self.reasoning_tokens,
            record.reasoning_tokens,
        );
        const next_request_count = if (self.request_count) |requests|
            std.math.add(u64, requests, 1) catch return self.failOverflow()
        else
            null;
        const next_web_search_calls = std.math.add(
            u64,
            self.billable_web_search_calls,
            record.billable_web_search_calls,
        ) catch return self.failOverflow();

        var owned_model: ?[]u8 = null;
        errdefer if (owned_model) |model| alloc.free(model);
        if (model_index == null) {
            owned_model = try alloc.dupe(u8, record.model);
            try self.models.ensureUnusedCapacity(alloc, 1);
        }

        if (model_index) |index| {
            try addRecordToModel(&self.models.items[index], record, pending_sequence);
        } else {
            var model = ModelAggregate{
                .model = owned_model.?,
                .first_sequence = pending_sequence,
                .reasoning_tokens = 0,
                .request_count = 0,
            };
            owned_model = null;
            try addRecordToModel(&model, record, pending_sequence);
            self.models.appendAssumeCapacity(model);
        }
        self.sortModelsBySequenceUnlocked();

        self.total_cost = next_total_cost;
        self.input_tokens = next_input_tokens;
        self.output_tokens = next_output_tokens;
        self.cache_read_tokens = next_cache_read_tokens;
        self.cache_write_tokens = next_cache_write_tokens;
        self.reasoning_tokens = next_reasoning_tokens;
        self.request_count = next_request_count;
        self.billable_web_search_calls = next_web_search_calls;

        var removed = self.pending.orderedRemove(pending_index);
        removed.deinit(alloc);
        if (published) self.removePublicationBacklogUnlocked(alloc, record.id);
        if (self.billing == .pending and self.pending.items.len == 0) {
            self.billing = .complete;
        }
        self.dirty = true;
    }

    const PublicationResult = enum {
        not_configured,
        durable,
        failed,
    };

    fn publishFact(
        self: *Usage,
        fact: usage_report.GenerationFact,
    ) PublicationResult {
        self.publication_mutex.lockUncancelable(io_mod.getIo());
        defer self.publication_mutex.unlock(io_mod.getIo());
        const sink = self.publication_sink orelse return .not_configured;
        sink.publish(sink.context, .{ .generation = fact }) catch |err| {
            debug_trace.logf(
                "session",
                "usage profile publication failed id={s} reason={s}",
                .{ fact.id, @errorName(err) },
            );
            return .failed;
        };
        return .durable;
    }

    fn stagePublicationBacklog(
        self: *Usage,
        alloc: Allocator,
        fact: usage_report.GenerationFact,
    ) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.stagePublicationBacklogUnlocked(alloc, fact);
    }

    fn stagePublicationBacklogUnlocked(
        self: *Usage,
        alloc: Allocator,
        fact: usage_report.GenerationFact,
    ) !void {
        const pending_exists = for (self.pending.items) |pending| {
            if (std.mem.eql(u8, pending.id, fact.id)) break true;
        } else false;
        if (!pending_exists) return;
        for (self.publication_backlog.items) |existing| {
            if (!std.mem.eql(u8, existing.id, fact.id)) continue;
            if (!usage_report.GenerationFact.eql(existing, fact)) {
                self.billing = .incomplete;
                self.recordIncidentUnlocked(.incomplete, fact.created_at_ms);
                self.dirty = true;
                return error.ConflictingGenerationRecord;
            }
            return;
        }
        if (self.publication_backlog.items.len == max_publication_backlog) {
            self.billing = .incomplete;
            self.recordIncidentUnlocked(.incomplete, fact.created_at_ms);
            self.dirty = true;
            return error.UsageCapacityExceeded;
        }
        var owned = try fact.dupe(alloc);
        errdefer owned.deinit(alloc);
        try self.publication_backlog.append(alloc, owned);
        self.dirty = true;
    }

    fn snapshotProfilePublications(
        self: *Usage,
        alloc: Allocator,
    ) !ProfilePublicationBatch {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        const observed_at_ms = @max(io_mod.milliTimestamp(), 0);
        var checkpoint_changed = false;
        for (self.pending.items) |*pending| {
            if (pending.observed_at_ms != null) continue;
            pending.observed_at_ms = observed_at_ms;
            self.dirty = true;
            checkpoint_changed = true;
        }

        const pending = try alloc.alloc(
            usage_report.PendingMarker,
            self.pending.items.len,
        );
        errdefer alloc.free(pending);
        var copied_pending: usize = 0;
        errdefer for (pending[0..copied_pending]) |*marker| marker.deinit(alloc);
        for (self.pending.items, 0..) |generation, index| {
            pending[index] = .{
                .id = try alloc.dupe(u8, generation.id),
                .observed_at_ms = generation.observed_at_ms.?,
            };
            copied_pending += 1;
        }

        const incidents = try alloc.dupe(
            usage_report.Incident,
            self.incidents[0..self.incident_count],
        );
        errdefer alloc.free(incidents);

        const facts = try alloc.alloc(
            usage_report.GenerationFact,
            self.publication_backlog.items.len,
        );
        errdefer alloc.free(facts);
        var copied_facts: usize = 0;
        errdefer for (facts[0..copied_facts]) |*fact| fact.deinit(alloc);
        for (self.publication_backlog.items, 0..) |fact, index| {
            facts[index] = try fact.dupe(alloc);
            copied_facts += 1;
        }

        return .{
            .pending = pending,
            .incidents = incidents,
            .facts = facts,
            .checkpoint_changed = checkpoint_changed,
        };
    }

    fn flushProfilePublications(self: *Usage) void {
        self.publication_mutex.lockUncancelable(io_mod.getIo());
        const sink = self.publication_sink orelse {
            self.publication_mutex.unlock(io_mod.getIo());
            return;
        };

        var batch = self.snapshotProfilePublications(sink.allocator) catch |err| {
            self.publication_mutex.unlock(io_mod.getIo());
            debug_trace.logf(
                "session",
                "usage profile publication copy failed reason={s}",
                .{@errorName(err)},
            );
            return;
        };
        defer batch.deinit(sink.allocator);

        for (batch.pending) |marker| {
            sink.publish(sink.context, .{ .pending = marker }) catch |err| {
                debug_trace.logf(
                    "session",
                    "usage profile pending publication failed id={s} reason={s}",
                    .{ marker.id, @errorName(err) },
                );
            };
        }
        var published_any = false;
        for (batch.incidents) |incident| {
            sink.publish(sink.context, .{ .incident = incident }) catch |err| {
                debug_trace.logf(
                    "session",
                    "usage profile incident publication failed reason={s}",
                    .{@errorName(err)},
                );
                continue;
            };
            self.mutex.lockUncancelable(io_mod.getIo());
            self.removeIncidentUnlocked(incident);
            self.mutex.unlock(io_mod.getIo());
            published_any = true;
        }

        for (batch.facts) |fact| {
            sink.publish(sink.context, .{ .generation = fact }) catch |err| {
                debug_trace.logf(
                    "session",
                    "usage profile backlog retry failed id={s} reason={s}",
                    .{ fact.id, @errorName(err) },
                );
                continue;
            };
            self.mutex.lockUncancelable(io_mod.getIo());
            self.applyGenerationUnlocked(
                sink.allocator,
                generationRecordBorrowed(fact),
                true,
            ) catch |err| {
                self.billing = .incomplete;
                self.recordIncidentUnlocked(.incomplete, fact.created_at_ms);
                self.removePublicationBacklogUnlocked(sink.allocator, fact.id);
                self.dirty = true;
                debug_trace.logf(
                    "session",
                    "usage profile backlog settlement failed id={s} reason={s}",
                    .{ fact.id, @errorName(err) },
                );
            };
            self.mutex.unlock(io_mod.getIo());
            published_any = true;
        }
        self.publication_mutex.unlock(io_mod.getIo());

        if (batch.checkpoint_changed or published_any) {
            self.checkpoint_mutex.lockUncancelable(io_mod.getIo());
            _ = self.persistCheckpointBestEffortLocked();
            self.checkpoint_mutex.unlock(io_mod.getIo());
        }
    }

    fn removePublicationBacklogUnlocked(
        self: *Usage,
        alloc: Allocator,
        id: []const u8,
    ) void {
        const index = for (self.publication_backlog.items, 0..) |fact, fact_index| {
            if (std.mem.eql(u8, fact.id, id)) break fact_index;
        } else return;
        var removed = self.publication_backlog.orderedRemove(index);
        removed.deinit(alloc);
    }

    fn removeIncidentUnlocked(
        self: *Usage,
        incident: usage_report.Incident,
    ) void {
        const index = for (self.incidents[0..self.incident_count], 0..) |existing, incident_index| {
            if (existing.occurred_at_ms == incident.occurred_at_ms and
                existing.completeness == incident.completeness)
            {
                break incident_index;
            }
        } else return;
        if (index + 1 < self.incident_count) {
            std.mem.copyForwards(
                usage_report.Incident,
                self.incidents[index .. self.incident_count - 1],
                self.incidents[index + 1 .. self.incident_count],
            );
        }
        self.incident_count -= 1;
        self.dirty = true;
    }

    fn recordIncidentUnlocked(
        self: *Usage,
        completeness: usage_report.Completeness,
        occurred_at_ms: i64,
    ) void {
        if (occurred_at_ms < 0) return;
        for (self.incidents[0..self.incident_count]) |incident| {
            if (incident.occurred_at_ms == occurred_at_ms and
                incident.completeness == completeness)
            {
                return;
            }
        }
        if (self.incident_count == max_usage_incidents) {
            var newest_at_ms = occurred_at_ms;
            for (self.incidents[0..self.incident_count]) |incident| {
                newest_at_ms = @max(newest_at_ms, incident.occurred_at_ms);
            }
            self.incidents[0] = .{
                .occurred_at_ms = newest_at_ms,
                .completeness = .incomplete,
            };
            self.incident_count = 1;
            return;
        }
        self.incidents[self.incident_count] = .{
            .occurred_at_ms = occurred_at_ms,
            .completeness = completeness,
        };
        self.incident_count += 1;
    }

    fn sortModelsBySequenceUnlocked(self: *Usage) void {
        var index: usize = 1;
        while (index < self.models.items.len) : (index += 1) {
            var current = index;
            while (current > 0 and
                self.models.items[current - 1].first_sequence >
                    self.models.items[current].first_sequence)
            {
                std.mem.swap(
                    ModelAggregate,
                    &self.models.items[current - 1],
                    &self.models.items[current],
                );
                current -= 1;
            }
        }
    }

    pub fn recordCommittedLines(self: *Usage, additions: usize, deletions: usize) !void {
        const additions_u64 = std.math.cast(u64, additions) orelse return error.UsageOverflow;
        const deletions_u64 = std.math.cast(u64, deletions) orelse return error.UsageOverflow;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.lines_added = std.math.add(u64, self.lines_added, additions_u64) catch {
            self.code_complete = false;
            self.dirty = true;
            return error.UsageOverflow;
        };
        self.lines_removed = std.math.add(u64, self.lines_removed, deletions_u64) catch {
            self.code_complete = false;
            self.dirty = true;
            return error.UsageOverflow;
        };
        self.dirty = true;
    }

    /// Returns an owned point-in-time snapshot. The caller must call `deinit`.
    pub fn snapshot(self: *Usage, alloc: Allocator) !Snapshot {
        self.finishReconciliationIfDone();
        return self.snapshotCurrent(alloc);
    }

    fn snapshotCurrent(self: *Usage, alloc: Allocator) !Snapshot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        const models = try alloc.alloc(ModelAggregate, self.models.items.len);
        errdefer alloc.free(models);
        var copied_models: usize = 0;
        errdefer for (models[0..copied_models]) |*model| model.deinit(alloc);
        for (self.models.items, 0..) |model, index| {
            models[index] = try model.dupe(alloc);
            copied_models += 1;
        }

        const pending = try alloc.alloc(PendingGeneration, self.pending.items.len);
        errdefer alloc.free(pending);
        var copied_pending: usize = 0;
        errdefer for (pending[0..copied_pending]) |*generation| generation.deinit(alloc);
        for (self.pending.items, 0..) |generation, index| {
            pending[index] = try generation.dupe(alloc);
            copied_pending += 1;
        }

        const publication_backlog = try alloc.alloc(
            usage_report.GenerationFact,
            self.publication_backlog.items.len,
        );
        errdefer alloc.free(publication_backlog);
        var copied_publications: usize = 0;
        errdefer for (publication_backlog[0..copied_publications]) |*fact| {
            fact.deinit(alloc);
        };
        for (self.publication_backlog.items, 0..) |fact, index| {
            publication_backlog[index] = try fact.dupe(alloc);
            copied_publications += 1;
        }

        const incidents = try alloc.dupe(
            usage_report.Incident,
            self.incidents[0..self.incident_count],
        );
        errdefer alloc.free(incidents);

        const now_ms = io_mod.milliTimestamp();
        if (self.active_started_at_ms == 0) self.active_started_at_ms = now_ms;
        const active_elapsed_ms = if (now_ms > self.active_started_at_ms)
            std.math.cast(u64, now_ms - self.active_started_at_ms) orelse
                std.math.maxInt(u64)
        else
            0;
        const wall_duration_ms = std.math.add(
            u64,
            self.wall_duration_ms,
            active_elapsed_ms,
        ) catch std.math.maxInt(u64);
        return .{
            .billing = if (self.active_sequence_count > 0)
                .incomplete
            else
                self.billing,
            .api_duration_complete = self.api_duration_complete and
                self.active_sequence_count == 0,
            .wall_duration_complete = self.wall_duration_complete and
                wall_duration_ms != std.math.maxInt(u64),
            .code_complete = self.code_complete,
            .next_sequence = self.next_sequence,
            .settled_through_sequence = self.settled_through_sequence,
            .api_duration_ms = self.api_duration_ms,
            .wall_duration_ms = wall_duration_ms,
            .total_cost = self.total_cost,
            .input_tokens = self.input_tokens,
            .output_tokens = self.output_tokens,
            .cache_read_tokens = self.cache_read_tokens,
            .cache_write_tokens = self.cache_write_tokens,
            .reasoning_tokens = self.reasoning_tokens,
            .request_count = self.request_count,
            .billable_web_search_calls = self.billable_web_search_calls,
            .lines_added = self.lines_added,
            .lines_removed = self.lines_removed,
            .models = models,
            .pending = pending,
            .publication_backlog = publication_backlog,
            .incidents = incidents,
        };
    }

    /// Returns the current session through the shared usage-report contract.
    pub fn reportSnapshot(
        self: *Usage,
        alloc: Allocator,
    ) !usage_report.Snapshot {
        var source_snapshot = try self.snapshot(alloc);
        defer source_snapshot.deinit(alloc);

        const models = try alloc.alloc(
            usage_report.SessionModelSource,
            source_snapshot.models.len,
        );
        defer alloc.free(models);
        for (source_snapshot.models, 0..) |model, index| {
            models[index] = .{
                .model = model.model,
                .total_cost = model.total_cost,
                .input_tokens = model.input_tokens,
                .output_tokens = model.output_tokens,
                .cache_read_tokens = model.cache_read_tokens,
                .cache_write_tokens = model.cache_write_tokens,
                .reasoning_tokens = model.reasoning_tokens,
                .request_count = model.request_count,
            };
        }

        const snapshot_time_ms = @max(io_mod.milliTimestamp(), 0);
        const wall_duration_ms = std.math.cast(i64, source_snapshot.wall_duration_ms) orelse
            snapshot_time_ms;
        return usage_report.buildSessionSnapshot(alloc, .{
            .snapshot_time_ms = snapshot_time_ms,
            .session_started_at_ms = @max(snapshot_time_ms -| wall_duration_ms, 0),
            .completeness = switch (source_snapshot.billing) {
                .complete => .complete,
                .pending => .pending,
                .incomplete => .incomplete,
                .legacy => .legacy,
            },
            .total_cost = source_snapshot.total_cost,
            .input_tokens = source_snapshot.input_tokens,
            .output_tokens = source_snapshot.output_tokens,
            .cache_read_tokens = source_snapshot.cache_read_tokens,
            .cache_write_tokens = source_snapshot.cache_write_tokens,
            .reasoning_tokens = source_snapshot.reasoning_tokens,
            .request_count = source_snapshot.request_count,
            .models = models,
            .activity = .{
                .api_duration_complete = source_snapshot.api_duration_complete,
                .wall_duration_complete = source_snapshot.wall_duration_complete,
                .code_complete = source_snapshot.code_complete,
                .api_duration_ms = source_snapshot.api_duration_ms,
                .wall_duration_ms = source_snapshot.wall_duration_ms,
                .lines_added = source_snapshot.lines_added,
                .lines_removed = source_snapshot.lines_removed,
            },
        });
    }

    pub fn restore(
        self: *Usage,
        alloc: Allocator,
        source: Snapshot,
        session_started_at_ms: i64,
    ) !void {
        self.stopReconciliation();
        try validateSnapshot(source);

        var copied = try dupeSnapshotOwned(alloc, source);
        errdefer copied.deinit(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        self.clearOwnedUnlocked(alloc);
        self.billing = copied.billing;
        self.api_duration_complete = copied.api_duration_complete;
        self.wall_duration_complete = copied.wall_duration_complete;
        self.code_complete = copied.code_complete;
        self.next_sequence = copied.next_sequence;
        self.settled_through_sequence = copied.settled_through_sequence;
        self.api_duration_ms = copied.api_duration_ms;
        // Wall time is derived from durable session creation; restoring a
        // checkpoint's elapsed value as well would count the same span twice.
        self.wall_duration_ms = 0;
        const now_ms = io_mod.milliTimestamp();
        if (session_started_at_ms <= 0 or session_started_at_ms > now_ms) {
            self.wall_duration_complete = false;
            self.active_started_at_ms = now_ms;
        } else {
            self.active_started_at_ms = session_started_at_ms;
        }
        self.active_sequence_count = 0;
        self.total_cost = copied.total_cost;
        self.input_tokens = copied.input_tokens;
        self.output_tokens = copied.output_tokens;
        self.cache_read_tokens = copied.cache_read_tokens;
        self.cache_write_tokens = copied.cache_write_tokens;
        self.reasoning_tokens = copied.reasoning_tokens;
        self.request_count = copied.request_count;
        self.billable_web_search_calls = copied.billable_web_search_calls;
        self.lines_added = copied.lines_added;
        self.lines_removed = copied.lines_removed;
        self.models = .fromOwnedSlice(copied.models);
        self.pending = .fromOwnedSlice(copied.pending);
        self.publication_backlog = .fromOwnedSlice(copied.publication_backlog);
        self.incident_count = copied.incidents.len;
        std.mem.copyForwards(
            usage_report.Incident,
            self.incidents[0..self.incident_count],
            copied.incidents,
        );
        if (copied.incidents.len > 0) alloc.free(copied.incidents);
        copied = undefined;
        self.dirty = false;
        self.mutex.unlock(io_mod.getIo());
        self.flushProfilePublications();
    }

    pub fn isDirty(self: *Usage) bool {
        self.finishReconciliationIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.dirty;
    }

    pub fn startReconciliation(
        self: *Usage,
        alloc: Allocator,
        api_key: []const u8,
    ) void {
        self.startReconciliationWithCredential(
            alloc,
            api_key,
            .{ .provider = .gateway, .credential_identity = null },
            false,
            null,
        );
    }

    pub fn startDeferredReconciliation(
        self: *Usage,
        alloc: Allocator,
        reference: stream_provider.DeferredUsageReference,
        credential: []const u8,
    ) void {
        self.startReconciliationWithCredential(
            alloc,
            credential,
            .{
                .provider = reference.provider,
                .credential_identity = reference.credential_identity,
            },
            false,
            null,
        );
    }

    /// Installs the host's authoritative credential regardless of the prior key.
    pub fn replaceReconciliationCredential(
        self: *Usage,
        alloc: Allocator,
        api_key: []const u8,
    ) void {
        self.startReconciliationWithCredential(
            alloc,
            api_key,
            self.reconciliation_authority orelse .{ .provider = .gateway, .credential_identity = null },
            true,
            null,
        );
    }

    pub fn replaceProviderReconciliationCredential(
        self: *Usage,
        alloc: Allocator,
        provider: model_provider.ProviderId,
        source: types.CredentialSource,
        account_id: ?[]const u8,
        credential: []const u8,
    ) void {
        const identity = credential_authority.derive(source, account_id) orelse {
            self.mutex.lockUncancelable(io_mod.getIo());
            const has_pending = self.pending.items.len > 0;
            self.mutex.unlock(io_mod.getIo());
            if (!has_pending) {
                self.startReconciliationWithCredential(
                    alloc,
                    credential,
                    .{ .provider = provider, .credential_identity = null },
                    true,
                    null,
                );
                return;
            }
            self.clearReconciliationCredential();
            debug_trace.logf(
                "session",
                "usage reconciliation withheld provider={s} source={s} reason=stable_credential_identity_unavailable",
                .{ @tagName(provider), @tagName(source) },
            );
            return;
        };
        self.startReconciliationWithCredential(
            alloc,
            credential,
            .{
                .provider = provider,
                .credential_identity = identity,
            },
            true,
            null,
        );
    }

    /// Replaces a producer's key only while that key is still authoritative.
    pub fn refreshReconciliationCredential(
        self: *Usage,
        alloc: Allocator,
        expected_api_key: []const u8,
        refreshed_api_key: []const u8,
    ) void {
        self.startReconciliationWithCredential(
            alloc,
            refreshed_api_key,
            self.reconciliation_authority orelse .{ .provider = .gateway, .credential_identity = null },
            true,
            expected_api_key,
        );
    }

    /// Cancels credential work and rejects stale producer starts until replaced.
    pub fn clearReconciliationCredential(self: *Usage) void {
        self.reconciliation_cancel.store(true, .seq_cst);
        self.reconciliation_mutex.lockUncancelable(io_mod.getIo());
        defer self.reconciliation_mutex.unlock(io_mod.getIo());
        self.reconciliation_cancel.store(true, .seq_cst);
        _ = self.reconciliation_work_epoch.fetchAdd(1, .seq_cst);
        const thread = self.reconciliation_thread;
        self.reconciliation_thread = null;
        if (thread) |handle| handle.join();
        self.reconciliation_done.store(true, .seq_cst);
        self.reconciliation_cancel.store(false, .seq_cst);
        self.reconciliation_key_digest = null;
        self.reconciliation_authority = null;
        self.reconciliation_credential_blocked = true;
    }

    fn startReconciliationWithCredential(
        self: *Usage,
        alloc: Allocator,
        api_key: []const u8,
        authority: ReconciliationAuthority,
        replace_existing: bool,
        expected_api_key: ?[]const u8,
    ) void {
        if (api_key.len == 0) return;
        const key_digest = reconciliationKeyDigest(api_key);
        const expected_digest = if (expected_api_key) |expected|
            reconciliationKeyDigest(expected)
        else
            null;
        self.reconciliation_mutex.lockUncancelable(io_mod.getIo());
        defer self.reconciliation_mutex.unlock(io_mod.getIo());
        const authoritative_replace =
            replace_existing and expected_api_key == null;
        if (self.reconciliation_credential_blocked and
            !authoritative_replace)
        {
            return;
        }
        if (authoritative_replace) {
            self.reconciliation_credential_blocked = false;
        }
        const same_key = if (self.reconciliation_key_digest) |active_digest|
            std.mem.eql(u8, &active_digest, &key_digest)
        else
            false;
        const same_authority = if (self.reconciliation_authority) |active|
            active.eql(authority)
        else
            false;
        if (self.reconciliation_key_digest) |active_digest| {
            if (!same_key) {
                if (!replace_existing) return;
                if (expected_digest) |expected| {
                    if (!std.mem.eql(u8, &active_digest, &expected)) return;
                }
            }
        }
        _ = self.reconciliation_work_epoch.fetchAdd(1, .seq_cst);
        if (self.reconciliation_thread) |thread| {
            if (same_key and same_authority and !self.reconciliation_done.load(.seq_cst)) return;
            self.reconciliation_cancel.store(true, .seq_cst);
            self.reconciliation_thread = null;
            thread.join();
            self.reconciliation_done.store(true, .seq_cst);
            self.reconciliation_cancel.store(false, .seq_cst);
        }
        self.reconciliation_key_digest = key_digest;
        self.reconciliation_authority = authority;
        if (builtin.is_test) return;

        self.mutex.lockUncancelable(io_mod.getIo());
        const still_has_pending = self.pending.items.len > 0;
        self.mutex.unlock(io_mod.getIo());
        if (!still_has_pending) return;

        const api_key_copy = alloc.dupe(u8, api_key) catch |err| {
            debug_trace.logf(
                "session",
                "usage reconciliation start failed reason={s}",
                .{@errorName(err)},
            );
            return;
        };
        self.reconciliation_cancel.store(false, .seq_cst);
        self.reconciliation_done.store(false, .seq_cst);
        self.reconciliation_key_digest = key_digest;
        self.reconciliation_thread = std.Thread.spawn(
            .{},
            reconciliationThreadMain,
            .{ self, alloc, api_key_copy, authority, self.generation_usage_providers },
        ) catch |err| {
            self.reconciliation_done.store(true, .seq_cst);
            debug_trace.logf(
                "session",
                "usage reconciliation start failed reason={s}",
                .{@errorName(err)},
            );
            secret.zeroAndFree(alloc, api_key_copy);
            return;
        };
    }

    pub fn cancelReconciliation(self: *Usage) void {
        self.stopReconciliation();
    }

    /// Gives the current worker a bounded drain, then cancels it so one-shot
    /// hosts can persist prompt results without turning exit into an API wait.
    pub fn finishReconciliationBeforeShutdown(self: *Usage) void {
        for (0..shutdown_reconciliation_budget_ms / 5) |_| {
            if (self.reconciliation_done.load(.seq_cst)) {
                self.finishReconciliationIfDone();
                return;
            }
            io_mod.sleep(5 * std.time.ns_per_ms);
        }
        self.stopReconciliation();
    }

    pub fn finishProfilePublicationsBeforeShutdown(self: *Usage) void {
        self.flushProfilePublications();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.publication_backlog.items.len > 0) {
            debug_trace.logf(
                "session",
                "usage profile publication incomplete facts={d}",
                .{self.publication_backlog.items.len},
            );
        }
    }

    fn finishReconciliationIfDone(self: *Usage) void {
        if (!self.reconciliation_done.load(.seq_cst)) return;
        self.reconciliation_mutex.lockUncancelable(io_mod.getIo());
        if (!self.reconciliation_done.load(.seq_cst)) {
            self.reconciliation_mutex.unlock(io_mod.getIo());
            return;
        }
        const thread = self.reconciliation_thread;
        self.reconciliation_thread = null;
        if (thread) |handle| {
            self.reconciliation_cancel.store(true, .seq_cst);
            handle.join();
            self.reconciliation_cancel.store(false, .seq_cst);
        }
        self.reconciliation_done.store(true, .seq_cst);
        self.reconciliation_mutex.unlock(io_mod.getIo());
    }

    fn stopReconciliation(self: *Usage) void {
        self.reconciliation_cancel.store(true, .seq_cst);
        self.reconciliation_mutex.lockUncancelable(io_mod.getIo());
        self.reconciliation_cancel.store(true, .seq_cst);
        const thread = self.reconciliation_thread;
        self.reconciliation_thread = null;
        if (thread) |handle| handle.join();
        self.reconciliation_done.store(true, .seq_cst);
        self.reconciliation_cancel.store(false, .seq_cst);
        self.reconciliation_mutex.unlock(io_mod.getIo());
    }

    fn markBillingIncomplete(self: *Usage) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.billing = .incomplete;
        self.recordIncidentUnlocked(.incomplete, @max(io_mod.milliTimestamp(), 0));
        self.dirty = true;
    }

    fn rejectPendingGeneration(self: *Usage, alloc: Allocator, id: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const pending_index = for (self.pending.items, 0..) |pending, index| {
            if (std.mem.eql(u8, pending.id, id)) break index;
        } else null;
        if (pending_index) |index| {
            var removed = self.pending.orderedRemove(index);
            self.recordIncidentUnlocked(
                .incomplete,
                removed.observed_at_ms orelse io_mod.milliTimestamp(),
            );
            removed.deinit(alloc);
        }
        self.billing = .incomplete;
        self.dirty = true;
        self.mutex.unlock(io_mod.getIo());
        self.flushProfilePublications();
    }

    pub fn markCodeIncomplete(self: *Usage) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.code_complete = false;
        self.dirty = true;
    }

    pub fn markClean(self: *Usage, persisted: Snapshot) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.matchesSnapshotUnlocked(persisted)) return;
        self.dirty = false;
    }

    fn failOverflow(self: *Usage) error{UsageOverflow} {
        self.billing = .incomplete;
        self.dirty = true;
        return error.UsageOverflow;
    }

    fn identifierBytesUnlocked(self: *const Usage) usize {
        var total: usize = 0;
        for (self.models.items) |model| total +|= model.model.len;
        for (self.pending.items) |generation| {
            total +|= generation.id.len;
            total +|= generation.origin.len;
            if (generation.team) |team| total +|= team.len;
            if (generation.account_id) |account_id| total +|= account_id.len;
        }
        for (self.publication_backlog.items) |fact| {
            total +|= fact.id.len;
            total +|= fact.model.len;
        }
        return total;
    }

    fn matchesSnapshotUnlocked(self: *const Usage, snapshot_value: Snapshot) bool {
        if (self.active_sequence_count > 0) return false;
        if (self.billing != snapshot_value.billing or
            self.api_duration_complete != snapshot_value.api_duration_complete or
            self.wall_duration_complete != snapshot_value.wall_duration_complete or
            self.code_complete != snapshot_value.code_complete or
            self.next_sequence != snapshot_value.next_sequence or
            self.settled_through_sequence != snapshot_value.settled_through_sequence or
            self.api_duration_ms != snapshot_value.api_duration_ms or
            self.total_cost != snapshot_value.total_cost or
            self.input_tokens != snapshot_value.input_tokens or
            self.output_tokens != snapshot_value.output_tokens or
            self.cache_read_tokens != snapshot_value.cache_read_tokens or
            self.cache_write_tokens != snapshot_value.cache_write_tokens or
            self.reasoning_tokens != snapshot_value.reasoning_tokens or
            self.request_count != snapshot_value.request_count or
            self.billable_web_search_calls != snapshot_value.billable_web_search_calls or
            self.lines_added != snapshot_value.lines_added or
            self.lines_removed != snapshot_value.lines_removed or
            self.models.items.len != snapshot_value.models.len or
            self.pending.items.len != snapshot_value.pending.len or
            self.publication_backlog.items.len != snapshot_value.publication_backlog.len or
            self.incident_count != snapshot_value.incidents.len)
        {
            return false;
        }
        for (self.models.items, snapshot_value.models) |model, saved| {
            if (!std.mem.eql(u8, model.model, saved.model) or
                model.first_sequence != saved.first_sequence or
                model.total_cost != saved.total_cost or
                model.input_tokens != saved.input_tokens or
                model.output_tokens != saved.output_tokens or
                model.cache_read_tokens != saved.cache_read_tokens or
                model.cache_write_tokens != saved.cache_write_tokens or
                model.reasoning_tokens != saved.reasoning_tokens or
                model.request_count != saved.request_count or
                model.billable_web_search_calls != saved.billable_web_search_calls)
            {
                return false;
            }
        }
        for (self.pending.items, snapshot_value.pending) |generation, saved| {
            if (!std.mem.eql(u8, generation.id, saved.id) or
                generation.sequence != saved.sequence or
                !std.mem.eql(u8, generation.origin, saved.origin) or
                !optionalStringsEqual(generation.team, saved.team) or
                generation.provider != saved.provider or
                generation.credential_source != saved.credential_source or
                !optionalCredentialIdentitiesEqual(generation.credential_identity, saved.credential_identity) or
                !optionalStringsEqual(generation.account_id, saved.account_id) or
                generation.observed_at_ms != saved.observed_at_ms)
            {
                return false;
            }
        }
        for (self.publication_backlog.items, snapshot_value.publication_backlog) |fact, saved| {
            if (!usage_report.GenerationFact.eql(fact, saved)) return false;
        }
        for (self.incidents[0..self.incident_count], snapshot_value.incidents) |incident, saved| {
            if (incident.occurred_at_ms != saved.occurred_at_ms or
                incident.completeness != saved.completeness)
            {
                return false;
            }
        }
        return true;
    }

    fn clearOwned(self: *Usage, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.clearOwnedUnlocked(alloc);
    }

    fn reset(self: *Usage, alloc: Allocator, fresh: bool) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.pending.items.len > 0 or self.active_sequence_count > 0) {
            debug_trace.logf(
                "session",
                "usage reset drops live state pending={d} active={d}",
                .{ self.pending.items.len, self.active_sequence_count },
            );
        }
        self.clearOwnedUnlocked(alloc);
        self.billing = if (fresh) .complete else .legacy;
        self.api_duration_complete = fresh;
        self.wall_duration_complete = fresh;
        self.code_complete = fresh;
        self.next_sequence = 1;
        self.settled_through_sequence = 0;
        self.api_duration_ms = 0;
        self.wall_duration_ms = 0;
        self.active_started_at_ms = io_mod.milliTimestamp();
        self.active_sequence_count = 0;
        self.total_cost = 0;
        self.input_tokens = 0;
        self.output_tokens = 0;
        self.cache_read_tokens = 0;
        self.cache_write_tokens = 0;
        self.reasoning_tokens = if (fresh) 0 else null;
        self.request_count = if (fresh) 0 else null;
        self.billable_web_search_calls = 0;
        self.lines_added = 0;
        self.lines_removed = 0;
        self.incident_count = 0;
        self.dirty = false;
    }

    fn clearOwnedUnlocked(self: *Usage, alloc: Allocator) void {
        for (self.models.items) |*model| model.deinit(alloc);
        self.models.deinit(alloc);
        self.models = .empty;
        for (self.pending.items) |*generation| generation.deinit(alloc);
        self.pending.deinit(alloc);
        self.pending = .empty;
        for (self.publication_backlog.items) |*fact| fact.deinit(alloc);
        self.publication_backlog.deinit(alloc);
        self.publication_backlog = .empty;
    }
};

const ReconciliationAuthority = struct {
    provider: model_provider.ProviderId,
    credential_identity: ?credential_authority.Identity,

    fn eql(self: ReconciliationAuthority, other: ReconciliationAuthority) bool {
        return self.provider == other.provider and
            optionalCredentialIdentitiesEqual(self.credential_identity, other.credential_identity);
    }
};

pub fn validateSnapshot(snapshot: Snapshot) !void {
    if (snapshot.next_sequence == 0) return error.InvalidUsageSnapshot;
    if (snapshot.settled_through_sequence >= snapshot.next_sequence) {
        return error.InvalidUsageSnapshot;
    }
    if (!std.math.isFinite(snapshot.total_cost) or snapshot.total_cost < 0) {
        return error.InvalidUsageSnapshot;
    }
    if (snapshot.models.len > max_models or
        snapshot.pending.len > max_pending_generations or
        snapshot.publication_backlog.len > max_publication_backlog or
        snapshot.incidents.len > max_usage_incidents)
    {
        return error.UsageCapacityExceeded;
    }
    if (snapshot.billing == .complete and snapshot.pending.len != 0) {
        return error.InvalidUsageSnapshot;
    }
    if (snapshot.billing == .pending and snapshot.pending.len == 0) {
        return error.InvalidUsageSnapshot;
    }
    var identifier_bytes: usize = 0;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;
    var cache_read_tokens: u64 = 0;
    var cache_write_tokens: u64 = 0;
    var reasoning_tokens: ?u64 = if (snapshot.reasoning_tokens == null)
        null
    else
        0;
    var request_count: ?u64 = if (snapshot.request_count == null)
        null
    else
        0;
    var billable_web_search_calls: u64 = 0;
    var total_cost: f64 = 0;
    for (snapshot.models, 0..) |model, index| {
        try validateModel(model.model);
        if (model.first_sequence == 0 or model.first_sequence >= snapshot.next_sequence) {
            return error.InvalidUsageSnapshot;
        }
        if (!std.math.isFinite(model.total_cost) or model.total_cost < 0) {
            return error.InvalidUsageSnapshot;
        }
        total_cost += model.total_cost;
        if (!std.math.isFinite(total_cost)) return error.InvalidUsageSnapshot;
        identifier_bytes = std.math.add(usize, identifier_bytes, model.model.len) catch
            return error.UsageCapacityExceeded;
        input_tokens = std.math.add(u64, input_tokens, model.input_tokens) catch
            return error.InvalidUsageSnapshot;
        output_tokens = std.math.add(u64, output_tokens, model.output_tokens) catch
            return error.InvalidUsageSnapshot;
        cache_read_tokens = std.math.add(u64, cache_read_tokens, model.cache_read_tokens) catch
            return error.InvalidUsageSnapshot;
        cache_write_tokens = std.math.add(u64, cache_write_tokens, model.cache_write_tokens) catch
            return error.InvalidUsageSnapshot;
        reasoning_tokens = addOptionalCounter(
            reasoning_tokens,
            model.reasoning_tokens,
        ) catch return error.InvalidUsageSnapshot;
        request_count = addOptionalCounter(
            request_count,
            model.request_count,
        ) catch return error.InvalidUsageSnapshot;
        if (model.cache_read_tokens > model.input_tokens or
            model.cache_write_tokens > model.input_tokens)
        {
            return error.InvalidUsageSnapshot;
        }
        if (model.reasoning_tokens) |reasoning| {
            if (reasoning > model.output_tokens) return error.InvalidUsageSnapshot;
        }
        billable_web_search_calls = std.math.add(
            u64,
            billable_web_search_calls,
            model.billable_web_search_calls,
        ) catch return error.InvalidUsageSnapshot;
        for (snapshot.models[0..index]) |prior| {
            if (std.mem.eql(u8, prior.model, model.model)) return error.InvalidUsageSnapshot;
        }
        if (index > 0 and
            snapshot.models[index - 1].first_sequence >= model.first_sequence)
        {
            return error.InvalidUsageSnapshot;
        }
    }
    if (input_tokens != snapshot.input_tokens or
        output_tokens != snapshot.output_tokens or
        cache_read_tokens != snapshot.cache_read_tokens or
        cache_write_tokens != snapshot.cache_write_tokens or
        reasoning_tokens != snapshot.reasoning_tokens or
        request_count != snapshot.request_count or
        billable_web_search_calls != snapshot.billable_web_search_calls)
    {
        return error.InvalidUsageSnapshot;
    }
    const cost_tolerance = @max(1e-12, snapshot.total_cost * 1e-12);
    if (@abs(total_cost - snapshot.total_cost) > cost_tolerance) {
        return error.InvalidUsageSnapshot;
    }
    for (snapshot.pending, 0..) |generation, index| {
        try validateGenerationId(generation.id);
        try validateOrigin(generation.origin);
        if (generation.team) |team| try validateTeam(team);
        if (generation.account_id) |account_id| try validateIdentifier(account_id);
        if (generation.credential_identity != null and generation.credential_source == null) {
            return error.InvalidUsageSnapshot;
        }
        if (generation.credential_source) |source| {
            if (!model_provider.authorizesCredential(generation.provider, source)) {
                return error.InvalidUsageSnapshot;
            }
        }
        if (generation.sequence == 0 or generation.sequence >= snapshot.next_sequence) {
            return error.InvalidUsageSnapshot;
        }
        if (generation.observed_at_ms) |observed_at_ms| {
            if (observed_at_ms < 0) return error.InvalidUsageSnapshot;
        }
        identifier_bytes = std.math.add(usize, identifier_bytes, generation.id.len) catch
            return error.UsageCapacityExceeded;
        identifier_bytes = std.math.add(usize, identifier_bytes, generation.origin.len) catch
            return error.UsageCapacityExceeded;
        if (generation.team) |team| {
            identifier_bytes = std.math.add(usize, identifier_bytes, team.len) catch
                return error.UsageCapacityExceeded;
        }
        if (generation.account_id) |account_id| {
            identifier_bytes = std.math.add(usize, identifier_bytes, account_id.len) catch
                return error.UsageOverflow;
        }
        for (snapshot.pending[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, generation.id) or
                prior.sequence == generation.sequence)
            {
                return error.InvalidUsageSnapshot;
            }
        }
    }
    for (snapshot.publication_backlog, 0..) |fact, index| {
        usage_report.validateFact(fact) catch return error.InvalidUsageSnapshot;
        identifier_bytes = std.math.add(usize, identifier_bytes, fact.id.len) catch
            return error.UsageCapacityExceeded;
        identifier_bytes = std.math.add(usize, identifier_bytes, fact.model.len) catch
            return error.UsageCapacityExceeded;
        for (snapshot.publication_backlog[0..index]) |prior| {
            if (!std.mem.eql(u8, prior.id, fact.id)) continue;
            if (!usage_report.GenerationFact.eql(prior, fact)) {
                return error.InvalidUsageSnapshot;
            }
            return error.InvalidUsageSnapshot;
        }
    }
    for (snapshot.incidents) |incident| {
        if (incident.occurred_at_ms < 0 or
            (incident.completeness != .pending and
                incident.completeness != .incomplete))
        {
            return error.InvalidUsageSnapshot;
        }
    }
    if (identifier_bytes > max_identifier_bytes) return error.UsageCapacityExceeded;
}

pub fn appendIncidentOwned(
    alloc: Allocator,
    snapshot: *Snapshot,
    incident: usage_report.Incident,
) !void {
    if (incident.occurred_at_ms < 0 or
        (incident.completeness != .pending and
            incident.completeness != .incomplete))
    {
        return error.InvalidUsageSnapshot;
    }
    for (snapshot.incidents) |existing| {
        if (existing.occurred_at_ms == incident.occurred_at_ms and
            existing.completeness == incident.completeness)
        {
            return;
        }
    }

    if (snapshot.incidents.len == max_usage_incidents) {
        var newest_at_ms = incident.occurred_at_ms;
        for (snapshot.incidents) |existing| {
            newest_at_ms = @max(newest_at_ms, existing.occurred_at_ms);
        }
        const next = try alloc.alloc(usage_report.Incident, 1);
        next[0] = .{
            .occurred_at_ms = newest_at_ms,
            .completeness = .incomplete,
        };
        alloc.free(snapshot.incidents);
        snapshot.incidents = next;
        return;
    }

    const next = try alloc.alloc(
        usage_report.Incident,
        snapshot.incidents.len + 1,
    );
    if (snapshot.incidents.len > 0) {
        std.mem.copyForwards(
            usage_report.Incident,
            next[0..snapshot.incidents.len],
            snapshot.incidents,
        );
    }
    next[snapshot.incidents.len] = incident;
    if (snapshot.incidents.len > 0) alloc.free(snapshot.incidents);
    snapshot.incidents = next;
}

/// Returns whether two snapshots have the same rollback-readable usage shape.
pub fn rollbackProjectionEql(first: Snapshot, second: Snapshot) bool {
    return billingProjectionEql(first, second) and
        first.api_duration_complete == second.api_duration_complete and
        first.wall_duration_complete == second.wall_duration_complete and
        first.code_complete == second.code_complete and
        first.api_duration_ms == second.api_duration_ms and
        first.wall_duration_ms == second.wall_duration_ms and
        first.lines_added == second.lines_added and
        first.lines_removed == second.lines_removed;
}

/// Returns whether two current-schema snapshots contain the same usage state.
pub fn snapshotEql(first: Snapshot, second: Snapshot) bool {
    if (!rollbackProjectionEql(first, second) or
        first.reasoning_tokens != second.reasoning_tokens or
        first.request_count != second.request_count or
        first.publication_backlog.len != second.publication_backlog.len or
        first.incidents.len != second.incidents.len)
    {
        return false;
    }
    for (first.models, second.models) |left, right| {
        if (left.reasoning_tokens != right.reasoning_tokens or
            left.request_count != right.request_count)
        {
            return false;
        }
    }
    for (first.pending, second.pending) |left, right| {
        if (left.observed_at_ms != right.observed_at_ms) return false;
    }
    for (first.publication_backlog, second.publication_backlog) |left, right| {
        if (!usage_report.GenerationFact.eql(left, right)) return false;
    }
    for (first.incidents, second.incidents) |left, right| {
        if (left.occurred_at_ms != right.occurred_at_ms or
            left.completeness != right.completeness)
        {
            return false;
        }
    }
    return true;
}

/// Returns whether two snapshots have the same billing-relevant projection.
pub fn billingProjectionEql(first: Snapshot, second: Snapshot) bool {
    if (first.billing != second.billing or
        first.next_sequence != second.next_sequence or
        first.settled_through_sequence != second.settled_through_sequence or
        first.total_cost != second.total_cost or
        first.input_tokens != second.input_tokens or
        first.output_tokens != second.output_tokens or
        first.cache_read_tokens != second.cache_read_tokens or
        first.cache_write_tokens != second.cache_write_tokens or
        first.billable_web_search_calls !=
            second.billable_web_search_calls or
        first.models.len != second.models.len or
        first.pending.len != second.pending.len)
    {
        return false;
    }
    for (first.models, second.models) |left, right| {
        if (!std.mem.eql(u8, left.model, right.model) or
            left.first_sequence != right.first_sequence or
            left.total_cost != right.total_cost or
            left.input_tokens != right.input_tokens or
            left.output_tokens != right.output_tokens or
            left.cache_read_tokens != right.cache_read_tokens or
            left.cache_write_tokens != right.cache_write_tokens or
            left.billable_web_search_calls !=
                right.billable_web_search_calls)
        {
            return false;
        }
    }
    for (first.pending, second.pending) |left, right| {
        if (!std.mem.eql(u8, left.id, right.id) or
            left.sequence != right.sequence or
            !std.mem.eql(u8, left.origin, right.origin) or
            !optionalStringsEqual(left.team, right.team) or
            left.provider != right.provider or
            left.credential_source != right.credential_source or
            !optionalCredentialIdentitiesEqual(left.credential_identity, right.credential_identity) or
            !optionalStringsEqual(left.account_id, right.account_id))
        {
            return false;
        }
    }
    return true;
}

pub fn writeSnapshot(writer: *std.Io.Writer, snapshot: Snapshot) !void {
    try validateSnapshot(snapshot);
    // Keep the durable session payload in the exact pre-usage-dashboard
    // shape. Older fx binaries reject unknown snapshot fields instead of
    // ignoring them; richer metrics and recovery hints live in the validated
    // session sidecar.
    try writer.writeAll("{\"billing\":");
    try std.json.Stringify.value(@tagName(snapshot.billing), .{}, writer);
    try writer.print(
        ",\"api_duration_complete\":{s},\"wall_duration_complete\":{s},\"code_complete\":{s},\"next_sequence\":{d},\"settled_through_sequence\":{d},\"api_duration_ms\":{d},\"wall_duration_ms\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"billable_web_search_calls\":{d},\"lines_added\":{d},\"lines_removed\":{d},\"models\":[",
        .{
            if (snapshot.api_duration_complete) "true" else "false",
            if (snapshot.wall_duration_complete) "true" else "false",
            if (snapshot.code_complete) "true" else "false",
            snapshot.next_sequence,
            snapshot.settled_through_sequence,
            snapshot.api_duration_ms,
            snapshot.wall_duration_ms,
            snapshot.total_cost,
            snapshot.input_tokens,
            snapshot.output_tokens,
            snapshot.cache_read_tokens,
            snapshot.cache_write_tokens,
            snapshot.billable_web_search_calls,
            snapshot.lines_added,
            snapshot.lines_removed,
        },
    );
    for (snapshot.models, 0..) |model, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"model\":");
        try std.json.Stringify.value(model.model, .{}, writer);
        try writer.print(
            ",\"first_sequence\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"billable_web_search_calls\":{d}}}",
            .{
                model.first_sequence,
                model.total_cost,
                model.input_tokens,
                model.output_tokens,
                model.cache_read_tokens,
                model.cache_write_tokens,
                model.billable_web_search_calls,
            },
        );
    }
    try writer.writeAll("],\"pending\":[");
    for (snapshot.pending, 0..) |pending, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(pending.id, .{}, writer);
        try writer.print(",\"sequence\":{d},\"provider\":", .{pending.sequence});
        try std.json.Stringify.value(@tagName(pending.provider), .{}, writer);
        try writer.writeAll(",\"origin\":");
        try std.json.Stringify.value(pending.origin, .{}, writer);
        try writer.writeAll(",\"team\":");
        if (pending.team) |team| {
            try std.json.Stringify.value(team, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writePendingAuthority(writer, pending);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

/// Writes the current usage schema for storage outside the rollback-readable
/// session event stream.
pub fn writeRichSnapshot(writer: *std.Io.Writer, snapshot: Snapshot) !void {
    try validateSnapshot(snapshot);
    try writer.writeAll("{\"schema_version\":3,\"billing\":");
    try std.json.Stringify.value(@tagName(snapshot.billing), .{}, writer);
    try writer.print(
        ",\"api_duration_complete\":{s},\"wall_duration_complete\":{s},\"code_complete\":{s},\"next_sequence\":{d},\"settled_through_sequence\":{d},\"api_duration_ms\":{d},\"wall_duration_ms\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{
            if (snapshot.api_duration_complete) "true" else "false",
            if (snapshot.wall_duration_complete) "true" else "false",
            if (snapshot.code_complete) "true" else "false",
            snapshot.next_sequence,
            snapshot.settled_through_sequence,
            snapshot.api_duration_ms,
            snapshot.wall_duration_ms,
            snapshot.total_cost,
            snapshot.input_tokens,
            snapshot.output_tokens,
            snapshot.cache_read_tokens,
            snapshot.cache_write_tokens,
        },
    );
    try writeOptionalU64(writer, snapshot.reasoning_tokens);
    try writer.writeAll(",\"request_count\":");
    try writeOptionalU64(writer, snapshot.request_count);
    try writer.print(
        ",\"billable_web_search_calls\":{d},\"lines_added\":{d},\"lines_removed\":{d},\"models\":[",
        .{
            snapshot.billable_web_search_calls,
            snapshot.lines_added,
            snapshot.lines_removed,
        },
    );
    for (snapshot.models, 0..) |model, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"model\":");
        try std.json.Stringify.value(model.model, .{}, writer);
        try writer.print(
            ",\"first_sequence\":{d},\"total_cost\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
            .{
                model.first_sequence,
                model.total_cost,
                model.input_tokens,
                model.output_tokens,
                model.cache_read_tokens,
                model.cache_write_tokens,
            },
        );
        try writeOptionalU64(writer, model.reasoning_tokens);
        try writer.writeAll(",\"request_count\":");
        try writeOptionalU64(writer, model.request_count);
        try writer.print(
            ",\"billable_web_search_calls\":{d}}}",
            .{model.billable_web_search_calls},
        );
    }
    try writer.writeAll("],\"pending\":[");
    for (snapshot.pending, 0..) |pending, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try std.json.Stringify.value(pending.id, .{}, writer);
        try writer.print(",\"sequence\":{d},\"provider\":", .{pending.sequence});
        try std.json.Stringify.value(@tagName(pending.provider), .{}, writer);
        try writer.writeAll(",\"origin\":");
        try std.json.Stringify.value(pending.origin, .{}, writer);
        try writer.writeAll(",\"team\":");
        if (pending.team) |team| {
            try std.json.Stringify.value(team, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writePendingAuthority(writer, pending);
        try writer.writeAll(",\"observed_at_ms\":");
        if (pending.observed_at_ms) |observed_at_ms| {
            try writer.print("{d}", .{observed_at_ms});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"publication_backlog\":[");
    for (snapshot.publication_backlog, 0..) |fact, index| {
        if (index > 0) try writer.writeByte(',');
        try generation_fact_codec.write(writer, fact);
    }
    try writer.writeAll("],\"incidents\":[");
    for (snapshot.incidents, 0..) |incident, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print(
            "{{\"occurred_at_ms\":{d},\"completeness\":",
            .{incident.occurred_at_ms},
        );
        try std.json.Stringify.value(@tagName(incident.completeness), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writePendingAuthority(writer: *std.Io.Writer, pending: PendingGeneration) !void {
    try writer.writeAll(",\"credential_source\":");
    if (pending.credential_source) |source| {
        try std.json.Stringify.value(@tagName(source), .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"credential_identity\":");
    if (pending.credential_identity) |identity| {
        const hex = std.fmt.bytesToHex(identity.bytes, .lower);
        try std.json.Stringify.value(&hex, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"account_id\":");
    if (pending.account_id) |account_id| {
        try std.json.Stringify.value(account_id, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

/// Parses either the rollback-readable or current usage snapshot schema.
pub fn parseSnapshotValue(alloc: Allocator, value: std.json.Value) !Snapshot {
    if (value != .object) {
        return error.InvalidUsageSnapshot;
    }
    const legacy = value.object.count() == 18;
    const schema_version = if (legacy)
        @as(u64, 1)
    else
        try parseNonNegativeInteger(value.object.get("schema_version"));
    if (!legacy) {
        if (value.object.count() != 23 or (schema_version != 2 and schema_version != 3)) {
            return error.InvalidUsageSnapshot;
        }
    }
    const billing_value = value.object.get("billing") orelse return error.InvalidUsageSnapshot;
    if (billing_value != .string) return error.InvalidUsageSnapshot;
    const billing = std.meta.stringToEnum(Availability, billing_value.string) orelse
        return error.InvalidUsageSnapshot;
    const api_complete = try parseBool(value.object.get("api_duration_complete"));
    const wall_complete = try parseBool(value.object.get("wall_duration_complete"));
    const code_complete = try parseBool(value.object.get("code_complete"));
    const next_sequence = try parseNonNegativeInteger(value.object.get("next_sequence"));
    const settled_through_sequence = try parseNonNegativeInteger(
        value.object.get("settled_through_sequence"),
    );
    const api_duration_ms = try parseNonNegativeInteger(value.object.get("api_duration_ms"));
    const wall_duration_ms = try parseNonNegativeInteger(value.object.get("wall_duration_ms"));
    const total_cost = try parseNonNegativeNumber(value.object.get("total_cost"));
    const input_tokens = try parseNonNegativeInteger(value.object.get("input_tokens"));
    const output_tokens = try parseNonNegativeInteger(value.object.get("output_tokens"));
    const cache_read_tokens = try parseNonNegativeInteger(value.object.get("cache_read_tokens"));
    const cache_write_tokens = try parseNonNegativeInteger(value.object.get("cache_write_tokens"));
    const reasoning_tokens = if (legacy)
        null
    else blk: {
        const field = value.object.get("reasoning_tokens") orelse
            return error.InvalidUsageSnapshot;
        break :blk try parseOptionalNonNegativeInteger(field);
    };
    const request_count = if (legacy)
        null
    else blk: {
        const field = value.object.get("request_count") orelse
            return error.InvalidUsageSnapshot;
        break :blk try parseOptionalNonNegativeInteger(field);
    };
    const billable_web_search_calls = try parseNonNegativeInteger(
        value.object.get("billable_web_search_calls"),
    );
    const lines_added = try parseNonNegativeInteger(value.object.get("lines_added"));
    const lines_removed = try parseNonNegativeInteger(value.object.get("lines_removed"));
    const models_value = value.object.get("models") orelse return error.InvalidUsageSnapshot;
    const pending_value = value.object.get("pending") orelse return error.InvalidUsageSnapshot;
    if (models_value != .array or pending_value != .array) return error.InvalidUsageSnapshot;
    if (models_value.array.items.len > max_models or pending_value.array.items.len > max_pending_generations) {
        return error.UsageCapacityExceeded;
    }

    const models = try alloc.alloc(ModelAggregate, models_value.array.items.len);
    errdefer alloc.free(models);
    var model_count: usize = 0;
    errdefer for (models[0..model_count]) |*model| model.deinit(alloc);
    for (models_value.array.items, 0..) |model_value, index| {
        const expected_model_fields: usize = if (legacy) 8 else 10;
        if (model_value != .object or
            model_value.object.count() != expected_model_fields)
        {
            return error.InvalidUsageSnapshot;
        }
        const model_name = model_value.object.get("model") orelse return error.InvalidUsageSnapshot;
        if (model_name != .string) return error.InvalidUsageSnapshot;
        const first_sequence = try parseNonNegativeInteger(model_value.object.get("first_sequence"));
        const model_total_cost = try parseNonNegativeNumber(model_value.object.get("total_cost"));
        const model_input_tokens = try parseNonNegativeInteger(model_value.object.get("input_tokens"));
        const model_output_tokens = try parseNonNegativeInteger(model_value.object.get("output_tokens"));
        const model_cache_read_tokens = try parseNonNegativeInteger(model_value.object.get("cache_read_tokens"));
        const model_cache_write_tokens = try parseNonNegativeInteger(model_value.object.get("cache_write_tokens"));
        const model_reasoning_tokens = if (legacy)
            null
        else blk: {
            const field = model_value.object.get("reasoning_tokens") orelse
                return error.InvalidUsageSnapshot;
            break :blk try parseOptionalNonNegativeInteger(field);
        };
        const model_request_count = if (legacy)
            null
        else blk: {
            const field = model_value.object.get("request_count") orelse
                return error.InvalidUsageSnapshot;
            break :blk try parseOptionalNonNegativeInteger(field);
        };
        const model_web_search_calls = try parseNonNegativeInteger(
            model_value.object.get("billable_web_search_calls"),
        );
        models[index] = .{
            .model = try alloc.dupe(u8, model_name.string),
            .first_sequence = first_sequence,
            .total_cost = model_total_cost,
            .input_tokens = model_input_tokens,
            .output_tokens = model_output_tokens,
            .cache_read_tokens = model_cache_read_tokens,
            .cache_write_tokens = model_cache_write_tokens,
            .reasoning_tokens = model_reasoning_tokens,
            .request_count = model_request_count,
            .billable_web_search_calls = model_web_search_calls,
        };
        model_count += 1;
    }

    const pending = try alloc.alloc(PendingGeneration, pending_value.array.items.len);
    errdefer alloc.free(pending);
    var pending_count: usize = 0;
    errdefer for (pending[0..pending_count]) |*generation| generation.deinit(alloc);
    for (pending_value.array.items, 0..) |pending_entry, index| {
        if (pending_entry != .object) return error.InvalidUsageSnapshot;
        const provider_scoped = pending_entry.object.contains("provider");
        const has_observed_at = pending_entry.object.contains("observed_at_ms");
        const expected_pending_fields: usize = if (provider_scoped)
            if (has_observed_at) 9 else 8
        else if (has_observed_at)
            5
        else
            4;
        if (pending_entry != .object or
            pending_entry.object.count() != expected_pending_fields)
        {
            return error.InvalidUsageSnapshot;
        }
        const id_value = pending_entry.object.get("id") orelse return error.InvalidUsageSnapshot;
        const origin_value = pending_entry.object.get("origin") orelse return error.InvalidUsageSnapshot;
        const team_value = pending_entry.object.get("team") orelse return error.InvalidUsageSnapshot;
        if (id_value != .string or origin_value != .string) return error.InvalidUsageSnapshot;
        const sequence = try parseNonNegativeInteger(pending_entry.object.get("sequence"));
        const observed_at_ms = if (!has_observed_at) null else blk: {
            const field = pending_entry.object.get("observed_at_ms") orelse
                return error.InvalidUsageSnapshot;
            break :blk try parseOptionalNonNegativeI64(field);
        };
        if (team_value != .null and team_value != .string) return error.InvalidUsageSnapshot;
        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const origin = try alloc.dupe(u8, origin_value.string);
        errdefer alloc.free(origin);
        const team = switch (team_value) {
            .null => null,
            .string => |text| try alloc.dupe(u8, text),
            else => unreachable,
        };
        errdefer if (team) |text| alloc.free(text);
        const provider = if (provider_scoped) provider: {
            const field = pending_entry.object.get("provider") orelse return error.InvalidUsageSnapshot;
            if (field != .string) return error.InvalidUsageSnapshot;
            break :provider model_provider.parse(field.string) orelse return error.InvalidUsageSnapshot;
        } else .gateway;
        const credential_source = if (provider_scoped)
            try parseCredentialSourceOptional(pending_entry.object.get("credential_source"))
        else
            null;
        const credential_identity = if (provider_scoped)
            try parseCredentialIdentityOptional(pending_entry.object.get("credential_identity"))
        else
            null;
        const account_id = if (provider_scoped)
            try parseOptionalOwnedString(alloc, pending_entry.object.get("account_id"))
        else
            null;
        errdefer if (account_id) |text| alloc.free(text);
        pending[index] = .{
            .id = id,
            .sequence = sequence,
            .provider = provider,
            .origin = origin,
            .team = team,
            .credential_source = credential_source,
            .credential_identity = credential_identity,
            .account_id = account_id,
            .observed_at_ms = observed_at_ms,
        };
        pending_count += 1;
    }

    const publication_backlog = if (legacy) blk: {
        break :blk try alloc.alloc(usage_report.GenerationFact, 0);
    } else blk: {
        const backlog_value = value.object.get("publication_backlog") orelse
            return error.InvalidUsageSnapshot;
        if (backlog_value != .array or
            backlog_value.array.items.len > max_publication_backlog)
        {
            return error.InvalidUsageSnapshot;
        }
        const backlog = try alloc.alloc(
            usage_report.GenerationFact,
            backlog_value.array.items.len,
        );
        errdefer alloc.free(backlog);
        var backlog_count: usize = 0;
        errdefer for (backlog[0..backlog_count]) |*fact| fact.deinit(alloc);
        for (backlog_value.array.items, 0..) |fact_value, index| {
            backlog[index] = generation_fact_codec.parse(
                alloc,
                fact_value,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidGenerationFact => return error.InvalidUsageSnapshot,
            };
            backlog_count += 1;
        }
        break :blk backlog;
    };
    errdefer {
        for (publication_backlog) |*fact| fact.deinit(alloc);
        if (publication_backlog.len > 0) alloc.free(publication_backlog);
    }

    const incidents = if (legacy) blk: {
        break :blk try alloc.alloc(usage_report.Incident, 0);
    } else blk: {
        const incidents_value = value.object.get("incidents") orelse
            return error.InvalidUsageSnapshot;
        if (incidents_value != .array or
            incidents_value.array.items.len > max_usage_incidents)
        {
            return error.InvalidUsageSnapshot;
        }
        const owned_incidents = try alloc.alloc(
            usage_report.Incident,
            incidents_value.array.items.len,
        );
        errdefer alloc.free(owned_incidents);
        for (incidents_value.array.items, 0..) |incident_value, index| {
            if (incident_value != .object or incident_value.object.count() != 2) {
                return error.InvalidUsageSnapshot;
            }
            const completeness_value = incident_value.object.get("completeness") orelse
                return error.InvalidUsageSnapshot;
            if (completeness_value != .string) return error.InvalidUsageSnapshot;
            const completeness = std.meta.stringToEnum(
                usage_report.Completeness,
                completeness_value.string,
            ) orelse return error.InvalidUsageSnapshot;
            owned_incidents[index] = .{
                .occurred_at_ms = try parseNonNegativeI64(
                    incident_value.object.get("occurred_at_ms"),
                ),
                .completeness = completeness,
            };
        }
        break :blk owned_incidents;
    };
    errdefer if (incidents.len > 0) alloc.free(incidents);

    const snapshot = Snapshot{
        .billing = billing,
        .api_duration_complete = api_complete,
        .wall_duration_complete = wall_complete,
        .code_complete = code_complete,
        .next_sequence = next_sequence,
        .settled_through_sequence = settled_through_sequence,
        .api_duration_ms = api_duration_ms,
        .wall_duration_ms = wall_duration_ms,
        .total_cost = total_cost,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = cache_read_tokens,
        .cache_write_tokens = cache_write_tokens,
        .reasoning_tokens = reasoning_tokens,
        .request_count = request_count,
        .billable_web_search_calls = billable_web_search_calls,
        .lines_added = lines_added,
        .lines_removed = lines_removed,
        .models = models,
        .pending = pending,
        .publication_backlog = publication_backlog,
        .incidents = incidents,
    };
    try validateSnapshot(snapshot);
    return snapshot;
}

fn parseBool(value: ?std.json.Value) !bool {
    const actual = value orelse return error.InvalidUsageSnapshot;
    if (actual != .bool) return error.InvalidUsageSnapshot;
    return actual.bool;
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn reconciliationThreadMain(
    usage: *Usage,
    alloc: Allocator,
    api_key: []u8,
    authority: ReconciliationAuthority,
    providers: generation_usage.Set,
) void {
    defer secret.zeroAndFree(alloc, api_key);
    defer usage.reconciliation_done.store(true, .seq_cst);
    var observed_epoch = usage.reconciliation_work_epoch.load(.seq_cst);
    while (!usage.reconciliation_cancel.load(.seq_cst)) {
        reconcilePendingBlocking(
            usage,
            alloc,
            api_key,
            &usage.reconciliation_cancel,
            authority,
            providers,
            30,
        );
        if (usage.reconciliation_cancel.load(.seq_cst)) return;
        const current_epoch = usage.reconciliation_work_epoch.load(.seq_cst);
        if (current_epoch != observed_epoch) {
            observed_epoch = current_epoch;
            continue;
        }
        usage.reconciliation_done.store(true, .seq_cst);
        if (usage.reconciliation_cancel.load(.seq_cst)) return;
        const confirmed_epoch = usage.reconciliation_work_epoch.load(.seq_cst);
        if (confirmed_epoch == observed_epoch) return;
        usage.reconciliation_done.store(false, .seq_cst);
        observed_epoch = confirmed_epoch;
    }
}

fn reconciliationKeyDigest(api_key: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(api_key, &digest, .{});
    return digest;
}

fn reconcilePendingBlocking(
    usage: *Usage,
    alloc: Allocator,
    api_key: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    authority: ReconciliationAuthority,
    providers: generation_usage.Set,
    max_attempts: usize,
) void {
    if (api_key.len == 0 or cancel_flag.load(.seq_cst)) return;
    var attempt: usize = 0;
    while (attempt < max_attempts and !cancel_flag.load(.seq_cst)) : (attempt += 1) {
        var current = usage.snapshot(alloc) catch |err| {
            debug_trace.logf(
                "session",
                "usage reconciliation snapshot failed reason={s}",
                .{@errorName(err)},
            );
            usage.markBillingIncomplete();
            return;
        };
        defer current.deinit(alloc);
        if (current.pending.len == 0) return;

        var retry_needed = false;
        for (current.pending) |pending| {
            if (pending.provider != authority.provider or
                !optionalCredentialIdentitiesEqual(
                    pending.credential_identity,
                    authority.credential_identity,
                ))
            {
                continue;
            }
            const provider = providers.select(pending.provider) orelse {
                retry_needed = true;
                continue;
            };
            var outcome = provider.lookup(alloc, .{
                .credential = api_key,
                .tenant = pending.team,
                .origin = pending.origin,
                .generation_id = pending.id,
                .cancel_flag = cancel_flag,
            }) catch |err| {
                if (err == error.Cancelled) return;
                debug_trace.logf(
                    "session",
                    "usage generation lookup failed attempt={d} reason={s}",
                    .{ attempt + 1, @errorName(err) },
                );
                retry_needed = true;
                continue;
            };
            defer outcome.deinit(alloc);
            switch (outcome) {
                .retry => {
                    debug_trace.logf(
                        "session",
                        "usage generation lookup retry attempt={d}",
                        .{attempt + 1},
                    );
                    retry_needed = true;
                    continue;
                },
                .preserve_pending => {
                    debug_trace.logf(
                        "session",
                        "usage generation lookup preserved attempt={d}",
                        .{attempt + 1},
                    );
                    continue;
                },
                .reject => {
                    debug_trace.logf(
                        "session",
                        "usage generation lookup rejected attempt={d}",
                        .{attempt + 1},
                    );
                    usage.rejectPendingGeneration(alloc, pending.id);
                },
                .found => |record| {
                    usage.applyGeneration(alloc, record) catch |err| {
                        debug_trace.logf(
                            "session",
                            "usage generation apply failed reason={s}",
                            .{@errorName(err)},
                        );
                        usage.markBillingIncomplete();
                    };
                },
            }
        }
        if (!retry_needed) return;
        if (attempt + 1 < max_attempts and
            !waitForReconciliationRetry(cancel_flag))
        {
            return;
        }
    }
}

fn waitForReconciliationRetry(cancel_flag: *std.atomic.Value(bool)) bool {
    const slices: usize = 200;
    for (0..slices) |_| {
        if (cancel_flag.load(.seq_cst)) return false;
        io_mod.getIo().sleep(.fromMilliseconds(5), .awake) catch |err| {
            debug_trace.logf(
                "session",
                "usage reconciliation retry wait failed reason={s}",
                .{@errorName(err)},
            );
            return false;
        };
    }
    return !cancel_flag.load(.seq_cst);
}

fn addRecordToModel(model: *ModelAggregate, record: GenerationRecord, sequence: u64) !void {
    const total_cost = model.total_cost + record.total_cost;
    if (!std.math.isFinite(total_cost)) return error.UsageOverflow;
    const input_tokens = std.math.add(u64, model.input_tokens, record.input_tokens) catch
        return error.UsageOverflow;
    const output_tokens = std.math.add(u64, model.output_tokens, record.output_tokens) catch
        return error.UsageOverflow;
    const cache_read_tokens = std.math.add(u64, model.cache_read_tokens, record.cache_read_tokens) catch
        return error.UsageOverflow;
    const cache_write_tokens = std.math.add(u64, model.cache_write_tokens, record.cache_write_tokens) catch
        return error.UsageOverflow;
    const reasoning_tokens = try addOptionalCounter(
        model.reasoning_tokens,
        record.reasoning_tokens,
    );
    const request_count = if (model.request_count) |requests|
        std.math.add(u64, requests, 1) catch return error.UsageOverflow
    else
        null;
    const web_search_calls = std.math.add(
        u64,
        model.billable_web_search_calls,
        record.billable_web_search_calls,
    ) catch return error.UsageOverflow;
    model.total_cost = total_cost;
    model.input_tokens = input_tokens;
    model.output_tokens = output_tokens;
    model.cache_read_tokens = cache_read_tokens;
    model.cache_write_tokens = cache_write_tokens;
    model.reasoning_tokens = reasoning_tokens;
    model.request_count = request_count;
    model.billable_web_search_calls = web_search_calls;
    model.first_sequence = @min(model.first_sequence, sequence);
}

fn validateGenerationRecord(record: GenerationRecord) !void {
    usage_report.validateFact(generationFactBorrowed(record)) catch {
        return error.InvalidGenerationRecord;
    };
}

fn generationFactBorrowed(record: GenerationRecord) usage_report.GenerationFact {
    return .{
        .id = @constCast(record.id),
        .created_at_ms = record.created_at_ms,
        .model = @constCast(record.model),
        .input_tokens = record.input_tokens,
        .output_tokens = record.output_tokens,
        .cache_read_tokens = record.cache_read_tokens,
        .cache_write_tokens = record.cache_write_tokens,
        .reasoning_tokens = record.reasoning_tokens,
        .billable_web_search_calls = record.billable_web_search_calls,
        .total_cost = record.total_cost,
    };
}

fn generationRecordBorrowed(
    fact: usage_report.GenerationFact,
) GenerationRecord {
    return .{
        .id = fact.id,
        .created_at_ms = fact.created_at_ms,
        .model = fact.model,
        .total_cost = fact.total_cost,
        .input_tokens = fact.input_tokens,
        .output_tokens = fact.output_tokens,
        .cache_read_tokens = fact.cache_read_tokens,
        .cache_write_tokens = fact.cache_write_tokens,
        .reasoning_tokens = fact.reasoning_tokens,
        .billable_web_search_calls = fact.billable_web_search_calls,
    };
}

fn addOptionalCounter(first: ?u64, second: ?u64) error{UsageOverflow}!?u64 {
    if (first == null or second == null) return null;
    return std.math.add(u64, first.?, second.?) catch error.UsageOverflow;
}

pub fn dupeSnapshotOwned(alloc: Allocator, source: Snapshot) !Snapshot {
    const models = try alloc.alloc(ModelAggregate, source.models.len);
    errdefer alloc.free(models);
    var copied_models: usize = 0;
    errdefer for (models[0..copied_models]) |*model| model.deinit(alloc);
    for (source.models, 0..) |model, index| {
        models[index] = try model.dupe(alloc);
        copied_models += 1;
    }

    const pending = try alloc.alloc(PendingGeneration, source.pending.len);
    errdefer alloc.free(pending);
    var copied_pending: usize = 0;
    errdefer for (pending[0..copied_pending]) |*generation| generation.deinit(alloc);
    for (source.pending, 0..) |generation, index| {
        pending[index] = try generation.dupe(alloc);
        copied_pending += 1;
    }

    const publication_backlog = try alloc.alloc(
        usage_report.GenerationFact,
        source.publication_backlog.len,
    );
    errdefer alloc.free(publication_backlog);
    var copied_publications: usize = 0;
    errdefer for (publication_backlog[0..copied_publications]) |*fact| {
        fact.deinit(alloc);
    };
    for (source.publication_backlog, 0..) |fact, index| {
        publication_backlog[index] = try fact.dupe(alloc);
        copied_publications += 1;
    }

    const incidents = try alloc.dupe(usage_report.Incident, source.incidents);
    errdefer alloc.free(incidents);

    return .{
        .billing = source.billing,
        .api_duration_complete = source.api_duration_complete,
        .wall_duration_complete = source.wall_duration_complete,
        .code_complete = source.code_complete,
        .next_sequence = source.next_sequence,
        .settled_through_sequence = source.settled_through_sequence,
        .api_duration_ms = source.api_duration_ms,
        .wall_duration_ms = source.wall_duration_ms,
        .total_cost = source.total_cost,
        .input_tokens = source.input_tokens,
        .output_tokens = source.output_tokens,
        .cache_read_tokens = source.cache_read_tokens,
        .cache_write_tokens = source.cache_write_tokens,
        .reasoning_tokens = source.reasoning_tokens,
        .request_count = source.request_count,
        .billable_web_search_calls = source.billable_web_search_calls,
        .lines_added = source.lines_added,
        .lines_removed = source.lines_removed,
        .models = models,
        .pending = pending,
        .publication_backlog = publication_backlog,
        .incidents = incidents,
    };
}

fn canonicalExactGenerationId(
    provider: model_provider.ProviderId,
    external_id: []const u8,
    buffer: *[30]u8,
) ![]const u8 {
    if (provider == .gateway) {
        try validateGenerationId(external_id);
        return external_id;
    }
    try validateExternalGenerationId(external_id);
    var digest: [Sha256.digest_length]u8 = undefined;
    var hash = Sha256.init(.{});
    hash.update(@tagName(provider));
    hash.update(&.{0});
    hash.update(external_id);
    hash.final(&digest);
    const encoded = std.fmt.bytesToHex(digest[0..13].*, .upper);
    @memcpy(buffer[0..4], "gen_");
    @memcpy(buffer[4..], &encoded);
    return buffer;
}

fn exactUsageOrigin(provider: model_provider.ProviderId) []const u8 {
    return switch (provider) {
        .gateway => "exact/gateway",
        .codex => "exact/codex",
        .grok => "exact/grok",
    };
}

fn validateGenerationId(id: []const u8) !void {
    if (!types.validGatewayGenerationId(id)) return error.InvalidGenerationId;
}

fn validateExternalGenerationId(id: []const u8) !void {
    if (id.len == 0 or id.len > max_identifier_bytes or !std.unicode.utf8ValidateSlice(id)) {
        return error.InvalidGenerationId;
    }
    for (id) |byte| if (std.ascii.isControl(byte)) return error.InvalidGenerationId;
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_bytes) {
        return error.InvalidModel;
    }
    for (model) |char| {
        if (char < 0x21 or char > 0x7e) return error.InvalidModel;
    }
}

fn validateOrigin(origin: []const u8) !void {
    if (origin.len == 0 or origin.len > max_origin_bytes) {
        return error.InvalidGatewayOrigin;
    }
    for (origin) |char| {
        if (char < 0x21 or char > 0x7e) return error.InvalidGatewayOrigin;
    }
}

fn validateTeam(team: []const u8) !void {
    if (team.len == 0 or team.len > max_team_bytes) {
        return error.InvalidGatewayTeam;
    }
    for (team) |char| {
        if (char < 0x21 or char > 0x7e) return error.InvalidGatewayTeam;
    }
}

fn validateIdentifier(value: []const u8) !void {
    if (value.len == 0 or value.len > max_model_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidCredentialIdentity;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidCredentialIdentity;
}

fn parseNonNegativeNumber(value: ?std.json.Value) !f64 {
    const actual = value orelse return error.InvalidGenerationRecord;
    const number: f64 = switch (actual) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch
            return error.InvalidGenerationRecord,
        else => return error.InvalidGenerationRecord,
    };
    if (!std.math.isFinite(number) or number < 0) return error.InvalidGenerationRecord;
    return number;
}

fn parseNonNegativeInteger(value: ?std.json.Value) !u64 {
    const actual = value orelse return error.InvalidGenerationRecord;
    return switch (actual) {
        .integer => |integer| if (integer >= 0)
            std.math.cast(u64, integer) orelse error.InvalidGenerationRecord
        else
            error.InvalidGenerationRecord,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch
            error.InvalidGenerationRecord,
        else => error.InvalidGenerationRecord,
    };
}

fn parseOptionalNonNegativeInteger(value: ?std.json.Value) !?u64 {
    const actual = value orelse return null;
    if (actual == .null) return null;
    return try parseNonNegativeInteger(actual);
}

fn parseNonNegativeI64(value: ?std.json.Value) !i64 {
    const parsed = try parseNonNegativeInteger(value);
    return std.math.cast(i64, parsed) orelse error.InvalidGenerationRecord;
}

fn parseOptionalNonNegativeI64(value: ?std.json.Value) !?i64 {
    const actual = value orelse return null;
    if (actual == .null) return null;
    return try parseNonNegativeI64(actual);
}

fn parseCredentialSourceOptional(value: ?std.json.Value) !?types.CredentialSource {
    const actual = value orelse return error.InvalidUsageSnapshot;
    return switch (actual) {
        .null => null,
        .string => |text| types.parseCredentialSource(text) orelse return error.InvalidUsageSnapshot,
        else => error.InvalidUsageSnapshot,
    };
}

fn parseCredentialIdentityOptional(value: ?std.json.Value) !?credential_authority.Identity {
    const actual = value orelse return error.InvalidUsageSnapshot;
    return switch (actual) {
        .null => null,
        .string => |hex| identity: {
            var bytes: [Sha256.digest_length]u8 = undefined;
            _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidUsageSnapshot;
            const canonical = std.fmt.bytesToHex(bytes, .lower);
            if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidUsageSnapshot;
            break :identity credential_authority.Identity{ .bytes = bytes };
        },
        else => error.InvalidUsageSnapshot,
    };
}

fn parseOptionalOwnedString(alloc: Allocator, value: ?std.json.Value) !?[]u8 {
    const actual = value orelse return error.InvalidUsageSnapshot;
    return switch (actual) {
        .null => null,
        .string => |text| try alloc.dupe(u8, text),
        else => error.InvalidUsageSnapshot,
    };
}

fn optionalStringsEqual(first: ?[]const u8, second: ?[]const u8) bool {
    if (first == null or second == null) return first == null and second == null;
    return std.mem.eql(u8, first.?, second.?);
}

fn optionalCredentialIdentitiesEqual(
    first: ?credential_authority.Identity,
    second: ?credential_authority.Identity,
) bool {
    if (first == null or second == null) return first == null and second == null;
    return first.?.eql(second.?);
}

fn testGatewayUsageOutcome(
    generation_id: []const u8,
    immediate: bool,
) stream_provider.UsageOutcome {
    return if (immediate)
        .{ .exact = .gateway }
    else
        .{ .deferred = testGatewayUsageReference(
            generation_id,
            "https://ai-gateway.vercel.sh",
        ) };
}

fn testGatewayUsageReference(
    generation_id: []const u8,
    scope: []const u8,
) stream_provider.DeferredUsageReference {
    return .{
        .provider = .gateway,
        .generation_id = generation_id,
        .scope = scope,
        .credential_source = .ai_gateway_api_key,
        .credential_identity = credential_authority.derive(
            .ai_gateway_api_key,
            null,
        ),
    };
}
