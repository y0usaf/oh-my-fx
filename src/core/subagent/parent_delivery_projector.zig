const std = @import("std");
const runtime_deps = @import("../agent/runtime/deps.zig");
const communication = @import("communication.zig");
const communication_manager = @import("communication_manager.zig");
const communication_store = @import("communication_store.zig");
const domain = @import("domain.zig");
const relationship_index = @import("relationship_index.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const types = @import("../shared/types.zig");
const session_store = @import("../session/session_store.zig");

const Allocator = std.mem.Allocator;

pub const consumer_id = "parent-model";
const parent_turn_limit: usize = communication.max_delivery_page;
const parent_relationship_scan_limit =
    relationship_index.max_candidate_reads -
    session_store.relationship_migration_candidate_limit;

pub const Error = error{OutOfMemory};

const PrepareLimits = struct {
    turn: usize = parent_turn_limit,
    relationship_scan: usize = parent_relationship_scan_limit,
};

const PrepareCounters = struct {
    discovery_session_ids: usize = 0,
    discovery_control_reads: usize = 0,
    discovery_owned_ids: usize = 0,
    child_pages: usize = 0,
    delivery_candidates: usize = 0,
    accepted_deliveries: usize = 0,
    render_attempts: usize = 0,
};

pub fn prepare(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_session_id: []const u8,
    child_store_options: session_child_store.Options,
) Error!?runtime_deps.PreparedParentTurnContext {
    return prepareWithCounters(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
        null,
    );
}

fn prepareWithCounters(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_session_id: []const u8,
    child_store_options: session_child_store.Options,
    counters: ?*PrepareCounters,
) Error!?runtime_deps.PreparedParentTurnContext {
    return prepareWithLimits(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
        counters,
        .{},
    );
}

fn prepareWithLimits(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_session_id: []const u8,
    child_store_options: session_child_store.Options,
    counters: ?*PrepareCounters,
    limits: PrepareLimits,
) Error!?runtime_deps.PreparedParentTurnContext {
    std.debug.assert(limits.turn > 0 and limits.turn <= parent_turn_limit);
    std.debug.assert(
        limits.relationship_scan > 0 and
            limits.relationship_scan <= parent_relationship_scan_limit,
    );
    domain.validateId(parent_session_id) catch return null;
    relationship_index.recoverForQuery(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            traceDiscoveryFailure(parent_session_id, err);
            return null;
        },
    };
    const migration = relationship_index.migrateLegacyPage(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            traceMigrationFailure(parent_session_id, err);
            break :blk relationship_index.MigrationStats{};
        },
    };
    if (counters) |stats| {
        stats.discovery_session_ids += migration.candidate_reads;
        stats.discovery_control_reads += migration.candidate_reads;
        stats.discovery_owned_ids += migration.candidate_reads;
    }
    var child_page = relationship_index.deliveryPage(
        alloc,
        sessions,
        parent_session_id,
        child_store_options,
        limits.turn,
        limits.relationship_scan,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (err == error.InvalidIndex) {
                relationship_index.repairForQuery(
                    alloc,
                    sessions,
                    parent_session_id,
                    child_store_options,
                ) catch |repair_err| switch (repair_err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => traceDiscoveryFailure(
                        parent_session_id,
                        repair_err,
                    ),
                };
            }
            traceDiscoveryFailure(parent_session_id, err);
            return null;
        },
    };
    defer child_page.deinit(alloc);
    if (counters) |stats| {
        stats.discovery_session_ids += child_page.slots_read;
        stats.discovery_owned_ids += child_page.candidates.len;
    }
    sortRelationshipCandidates(child_page.candidates);

    var delivery_manager = communication_manager.Manager{
        .sessions = sessions,
        .child_store_options = child_store_options,
    };
    var deliveries: std.ArrayList(communication.ParentDeliveryPart) = .empty;
    defer freeDeliveries(alloc, &deliveries);
    var prepared_context: ?[]u8 = null;
    errdefer if (prepared_context) |context| alloc.free(context);

    var deferred_offset: ?u64 = null;
    var delivery_candidates: usize = 0;
    for (child_page.candidates, 0..) |candidate, candidate_index| {
        const remaining = limits.turn - delivery_candidates;
        if (remaining == 0) {
            for (child_page.candidates[candidate_index..]) |unprocessed| {
                noteDeferredOffset(
                    &deferred_offset,
                    unprocessed.slot,
                    child_page.start_offset,
                    child_page.high_watermark,
                );
            }
            break;
        }
        if (counters) |stats| stats.discovery_control_reads += 1;
        const later_candidates = child_page.candidates.len - candidate_index - 1;
        const reserved = @min(later_candidates, remaining - 1);
        const child_limit = remaining - reserved;
        // One bounded read gives this child its fair share of the remaining
        // global budget. Unread communication remains durable while relationship
        // discovery advances independently and returns after a full rotation.
        var page = delivery_manager.prepareParentBoundaryPage(
            alloc,
            candidate.child_id,
            consumer_id,
            parent_session_id,
            .turn_boundary,
            null,
            child_limit,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                tracePrepareSkip(candidate.child_id, parent_session_id, err);
                continue;
            },
        };
        defer page.deinit(alloc);
        delivery_candidates += page.deliveries.len;
        if (counters) |stats| {
            stats.child_pages += 1;
            stats.delivery_candidates += page.deliveries.len;
        }
        for (page.deliveries) |delivery| {
            var cloned = try delivery.clone(alloc);
            var appended = false;
            errdefer if (!appended) cloned.deinit(alloc);
            try deliveries.append(alloc, cloned);
            appended = true;
            const updated_context = communication.renderTrustedContext(
                alloc,
                deliveries.items,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TrustedContextTooLarge => {
                    var omitted = deliveries.items[deliveries.items.len - 1];
                    deliveries.items.len -= 1;
                    omitted.deinit(alloc);
                    noteDeferredOffset(
                        &deferred_offset,
                        candidate.slot,
                        child_page.start_offset,
                        child_page.high_watermark,
                    );
                    break;
                },
            };
            if (counters) |stats| {
                stats.accepted_deliveries += 1;
                stats.render_attempts += 1;
            }
            if (prepared_context) |previous| alloc.free(previous);
            prepared_context = updated_context;
        }
    }
    const next_delivery_offset = deferred_offset orelse child_page.next_offset;
    if (deliveries.items.len == 0) {
        relationship_index.advanceDelivery(
            alloc,
            sessions,
            parent_session_id,
            child_store_options,
            child_page.start_offset,
            next_delivery_offset,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => traceDiscoveryAdvanceFailure(parent_session_id, err),
        };
        return null;
    }

    const context = prepared_context orelse return null;
    prepared_context = null;
    errdefer alloc.free(context);
    const acknowledgements = try buildAcknowledgements(
        alloc,
        deliveries.items,
        child_page.start_offset,
        next_delivery_offset,
    );
    return .{
        .content = context,
        .acknowledgements = acknowledgements,
    };
}

pub fn acknowledge(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_store_options: session_child_store.Options,
    acknowledgements: []const runtime_deps.ParentTurnDeliveryAck,
) void {
    _ = acknowledgeWithRetirementSignal(
        alloc,
        sessions,
        child_store_options,
        acknowledgements,
    );
}

pub fn acknowledgeWithRetirementSignal(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_store_options: session_child_store.Options,
    acknowledgements: []const runtime_deps.ParentTurnDeliveryAck,
) bool {
    var delivery_manager = communication_manager.Manager{
        .sessions = sessions,
        .child_store_options = child_store_options,
    };
    var discovery_parent_id: ?[]const u8 = null;
    var discovery_start_offset: ?u64 = null;
    var discovery_next_offset: ?u64 = null;
    var all_acknowledged = true;
    var final_result_acknowledged = false;
    for (acknowledgements) |ack| {
        const signals_retirement = delivery_manager
            .acknowledgeParentBoundaryWithFinalResultSignal(
            alloc,
            ack.child_id,
            consumer_id,
            ack.target_session_id,
            .{
                .sequence = ack.through_sequence,
                .delivery_id = ack.delivery_id,
                .start_offset = ack.start_offset,
                .end_offset = ack.end_offset,
                .total_bytes = ack.total_bytes,
            },
        ) catch |err| {
            all_acknowledged = false;
            debug_trace.logf(
                "subagent",
                "parent delivery acknowledgement failed child_id={s} parent_id={s} sequence={d} outcome={s}",
                .{ ack.child_id, ack.target_session_id, ack.through_sequence, @errorName(err) },
            );
            continue;
        };
        final_result_acknowledged = signals_retirement or final_result_acknowledged;
        if (signals_retirement) {
            debug_trace.logf(
                "subagent",
                "final result acknowledgement committed child_id={s} parent_id={s}",
                .{ ack.child_id, ack.target_session_id },
            );
        }
        const start = ack.discovery_start_offset orelse {
            all_acknowledged = false;
            continue;
        };
        const next = ack.discovery_next_offset orelse {
            all_acknowledged = false;
            continue;
        };
        if (discovery_parent_id) |parent_id| {
            if (!std.mem.eql(u8, parent_id, ack.target_session_id) or
                discovery_start_offset.? != start or
                discovery_next_offset.? != next)
            {
                all_acknowledged = false;
            }
        } else {
            discovery_parent_id = ack.target_session_id;
            discovery_start_offset = start;
            discovery_next_offset = next;
        }
    }
    if (all_acknowledged) {
        relationship_index.advanceDelivery(
            alloc,
            sessions,
            discovery_parent_id orelse return final_result_acknowledged,
            child_store_options,
            discovery_start_offset orelse return final_result_acknowledged,
            discovery_next_offset orelse return final_result_acknowledged,
        ) catch |err| traceDiscoveryAdvanceFailure(
            discovery_parent_id orelse return final_result_acknowledged,
            err,
        );
    }
    return final_result_acknowledged;
}

pub fn deinitPrepared(
    alloc: Allocator,
    prepared: *runtime_deps.PreparedParentTurnContext,
) void {
    alloc.free(prepared.content);
    for (prepared.acknowledgements) |ack| {
        alloc.free(ack.child_id);
        alloc.free(ack.target_session_id);
        alloc.free(ack.delivery_id);
    }
    alloc.free(prepared.acknowledgements);
    prepared.* = undefined;
}

fn buildAcknowledgements(
    alloc: Allocator,
    deliveries: []const communication.ParentDeliveryPart,
    discovery_start_offset: u64,
    discovery_next_offset: u64,
) Error![]runtime_deps.ParentTurnDeliveryAck {
    var acknowledgements: std.ArrayList(runtime_deps.ParentTurnDeliveryAck) = .empty;
    errdefer {
        for (acknowledgements.items) |ack| {
            alloc.free(ack.child_id);
            alloc.free(ack.target_session_id);
            alloc.free(ack.delivery_id);
        }
        acknowledgements.deinit(alloc);
    }
    for (deliveries) |delivery| {
        const child_id = try alloc.dupe(u8, delivery.source_id);
        errdefer alloc.free(child_id);
        const target_session_id = try alloc.dupe(u8, delivery.target_id);
        errdefer alloc.free(target_session_id);
        const delivery_id = try alloc.dupe(u8, delivery.id);
        errdefer alloc.free(delivery_id);
        try acknowledgements.append(alloc, .{
            .child_id = child_id,
            .target_session_id = target_session_id,
            .through_sequence = delivery.sequence,
            .delivery_id = delivery_id,
            .start_offset = switch (delivery.payload) {
                .message => |message| message.offset,
                else => 0,
            },
            .end_offset = switch (delivery.payload) {
                .message => |message| message.end_offset,
                else => 0,
            },
            .total_bytes = switch (delivery.payload) {
                .message => |message| message.total_bytes,
                else => 0,
            },
            .discovery_start_offset = discovery_start_offset,
            .discovery_next_offset = discovery_next_offset,
        });
    }
    return acknowledgements.toOwnedSlice(alloc);
}

fn freeDeliveries(
    alloc: Allocator,
    deliveries: *std.ArrayList(communication.ParentDeliveryPart),
) void {
    for (deliveries.items) |*delivery| delivery.deinit(alloc);
    deliveries.deinit(alloc);
}

fn sortRelationshipCandidates(candidates: []relationship_index.Candidate) void {
    var index: usize = 1;
    while (index < candidates.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and
            std.mem.order(
                u8,
                candidates[cursor - 1].child_id,
                candidates[cursor].child_id,
            ) == .gt) : (cursor -= 1)
        {
            std.mem.swap(
                relationship_index.Candidate,
                &candidates[cursor - 1],
                &candidates[cursor],
            );
        }
    }
}

fn noteDeferredOffset(
    current: *?u64,
    candidate: u64,
    start: u64,
    high_watermark: u64,
) void {
    const selected = current.* orelse {
        current.* = candidate;
        return;
    };
    if (circularSlotDistance(candidate, start, high_watermark) <
        circularSlotDistance(selected, start, high_watermark))
    {
        current.* = candidate;
    }
}

fn circularSlotDistance(slot: u64, start: u64, high_watermark: u64) u64 {
    return if (slot >= start)
        slot - start
    else
        high_watermark - start + slot;
}

fn traceDiscoveryFailure(parent_id: []const u8, err: anyerror) void {
    debug_trace.logf(
        "subagent",
        "parent delivery child discovery failed parent_id={s} outcome={s}",
        .{ parent_id, @errorName(err) },
    );
}

fn traceMigrationFailure(parent_id: []const u8, err: anyerror) void {
    debug_trace.logf(
        "subagent",
        "parent delivery relationship migration deferred parent_id={s} outcome={s}",
        .{ parent_id, @errorName(err) },
    );
}

fn traceDiscoveryAdvanceFailure(parent_id: []const u8, err: anyerror) void {
    debug_trace.logf(
        "subagent",
        "parent delivery discovery cursor advance deferred parent_id={s} outcome={s}",
        .{ parent_id, @errorName(err) },
    );
}

fn tracePrepareSkip(child_id: []const u8, parent_id: []const u8, err: anyerror) void {
    debug_trace.logf(
        "subagent",
        "parent delivery projection skipped child_id={s} parent_id={s} outcome={s}",
        .{ child_id, parent_id, @errorName(err) },
    );
}

fn testState(
    alloc: Allocator,
    id: []const u8,
    workspace: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, workspace);
    errdefer alloc.free(origin);
    const current = try alloc.dupe(u8, workspace);
    errdefer alloc.free(current);
    const model = try alloc.dupe(u8, "test/model");
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{ .model = model, .effort = types.ReasoningEffort.literal("high"), .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

const TestEnvironment = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    store: session_store.Store,

    fn init(alloc: Allocator) !TestEnvironment {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        return .{
            .tmp = tmp,
            .home = home,
            .workspace = workspace,
            .store = try session_store.Store.initFromHome(alloc, home, workspace),
        };
    }

    fn deinit(self: *TestEnvironment, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn createSession(self: *TestEnvironment, alloc: Allocator, id: []const u8) !void {
        var state = try testState(alloc, id, self.workspace);
        defer state.deinit(alloc);
        var loaded = try self.store.startWritableSession(alloc, state);
        loaded.deinit(alloc);
    }

    fn indexSession(self: *TestEnvironment, alloc: Allocator, id: []const u8) !void {
        try self.commitSession(alloc, id, 2);
    }

    fn commitSession(
        self: *TestEnvironment,
        alloc: Allocator,
        id: []const u8,
        timestamp_ms: i64,
    ) !void {
        var loaded = try self.store.resumeForWrite(alloc, id);
        defer loaded.deinit(alloc);
        const user_text = try alloc.dupe(u8, "index migration candidate");
        const assistant = try alloc.dupe(u8, "indexed");
        const turn: session.HistoryTurn = .{ .assistant = .{
            .user = .{ .text = user_text },
            .assistant = assistant,
        } };
        defer session.freeHistoryTurn(alloc, turn);
        _ = try loaded.appendEvent(
            alloc,
            .{ .history_turn_committed = .{
                .conversation_language = loaded.state.conversation_language,
                .total_input_tokens = 1,
                .total_output_tokens = 1,
                .turn = turn,
            } },
            timestamp_ms,
            .retry_expected_tail,
            .{},
        );
        _ = loaded.publishCommitLifecycle(alloc);
        var page = try self.store.listResumablePage(alloc, null, null);
        page.deinit(alloc);
    }
};

const FailSyncFileAt = struct {
    calls: usize = 0,
    fail_at: usize,

    fn syncFile(raw: ?*anyopaque, _: std.Io.File) anyerror!void {
        const self: *FailSyncFileAt = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == self.fail_at) return error.InjectedSyncFailure;
    }
};

fn validateCreate(alloc: Allocator, name: []const u8) !domain.Command {
    return domain.validateCommand(alloc, .{ .create = .{
        .name = name,
        .mode = .persistent,
    } });
}

fn validateSend(alloc: Allocator, id: []const u8, content: []const u8) !domain.Command {
    return domain.validateCommand(alloc, .{ .message = .{ .send = .{
        .id = id,
        .content = content,
    } } });
}

fn validateDetach(alloc: Allocator, id: []const u8) !domain.Command {
    return domain.validateCommand(alloc, .{ .relationship = .{
        .action = .detach,
        .id = id,
    } });
}

fn preparePersistentChild(
    alloc: Allocator,
    env: *TestEnvironment,
    parent_id: []const u8,
    child_id: []const u8,
    name: []const u8,
) !void {
    try env.createSession(alloc, child_id);
    var manager = @import("manager.zig").Manager{ .sessions = &env.store };
    var create = try validateCreate(alloc, name);
    defer create.deinit(alloc);
    var result = try manager.execute(alloc, create, .{
        .actor_id = parent_id,
        .operation_id = name,
        .created_child_id = child_id,
        .timestamp_ms = 1,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result == .receipt);
}

fn sendFromChild(
    alloc: Allocator,
    env: *TestEnvironment,
    child_id: []const u8,
    parent_id: []const u8,
    operation_id: []const u8,
    content: []const u8,
) !void {
    var manager = @import("manager.zig").Manager{ .sessions = &env.store };
    var send = try validateSend(alloc, parent_id, content);
    defer send.deinit(alloc);
    var result = try manager.execute(alloc, send, .{
        .actor_id = child_id,
        .operation_id = operation_id,
        .timestamp_ms = 2,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result == .receipt);
}

fn expectNoPrepared(
    alloc: Allocator,
    env: *TestEnvironment,
    parent_id: []const u8,
) !void {
    const prepared = try prepare(alloc, &env.store, parent_id, .{});
    try std.testing.expect(prepared == null);
}
