const std = @import("std");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const domain = @import("domain.zig");
const io_mod = @import("../shared/io.zig");
const session_child_store = @import("../session/session_child_store.zig");
const tool_result = @import("tool_result.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const schema_version: u64 = 7;
const root_context_schema_version: u64 = 6;
const permission_mode_schema_version: u64 = 5;
const manager_epoch_schema_version: u64 = 4;
const process_epoch_schema_version: u64 = 3;
const legacy_schema_version: u64 = 2;
const max_record_bytes: usize = 512 * 1024;
const record_file = "control.json";
const lock_file = "subagent-control.lock";
const lock_deadline_ms: u64 = 2000;

pub const Record = struct {
    child_id: []u8,
    generation: u64,
    parent_id: ?[]u8,
    mode: domain.Mode,
    configuration: domain.Configuration,
    state: domain.State,
    archived_from: ?domain.State = null,
    queue: []domain.QueuedMessage,
    events: []domain.Event,
    operations: []domain.OperationReceipt,
    next_event_sequence: u64,
    notification_cursor: u64,
    events_evicted_through: u64 = 0,
    queue_evicted: bool = false,
    legacy_replay_closed: bool = false,
    model_replay_floor: u64 = 0,
    human_replay_floor: u64 = 0,
    model_epoch_high: u64 = 0,
    human_epoch_high: u64 = 0,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.child_id);
        if (self.parent_id) |id| alloc.free(id);
        self.configuration.deinit(alloc);
        for (self.queue) |*message| message.deinit(alloc);
        alloc.free(self.queue);
        for (self.events) |*event| event.deinit(alloc);
        alloc.free(self.events);
        for (self.operations) |*operation| operation.deinit(alloc);
        alloc.free(self.operations);
        self.* = undefined;
    }

    /// Returns an owned copy; caller frees it with `deinit`.
    pub fn clone(self: Record, alloc: Allocator) !Record {
        const child_id = try alloc.dupe(u8, self.child_id);
        errdefer alloc.free(child_id);
        const parent_id = if (self.parent_id) |id| try alloc.dupe(u8, id) else null;
        errdefer if (parent_id) |id| alloc.free(id);
        var configuration = try self.configuration.clone(alloc);
        errdefer configuration.deinit(alloc);
        const queue = try cloneQueue(alloc, self.queue);
        errdefer freeQueue(alloc, queue);
        const events = try cloneEvents(alloc, self.events);
        errdefer freeEvents(alloc, events);
        return .{
            .child_id = child_id,
            .generation = self.generation,
            .parent_id = parent_id,
            .mode = self.mode,
            .configuration = configuration,
            .state = self.state,
            .archived_from = self.archived_from,
            .queue = queue,
            .events = events,
            .operations = try cloneOperations(alloc, self.operations),
            .next_event_sequence = self.next_event_sequence,
            .notification_cursor = self.notification_cursor,
            .events_evicted_through = self.events_evicted_through,
            .queue_evicted = self.queue_evicted,
            .legacy_replay_closed = self.legacy_replay_closed,
            .model_replay_floor = self.model_replay_floor,
            .human_replay_floor = self.human_replay_floor,
            .model_epoch_high = self.model_epoch_high,
            .human_epoch_high = self.human_epoch_high,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
        };
    }
};

pub const LoadError = error{
    OutOfMemory,
    ControlNotFound,
    InvalidControlRecord,
    UnsupportedControlSchema,
    ControlRecordTooLarge,
    ControlPathUnsafe,
    PrivateStatePermissionsUnsupported,
    ControlStoreFailed,
};

pub const SaveError = error{
    OutOfMemory,
    ControlIdentityMismatch,
    ControlRecordTooLarge,
    ControlPathUnsafe,
    PrivateStatePermissionsUnsupported,
    ControlCommitIndeterminate,
    ControlStoreFailed,
};

pub const LockError = error{
    OutOfMemory,
    ControlLockBusy,
    ControlLockUnsupported,
    ControlPathUnsafe,
    PrivateStatePermissionsUnsupported,
    ControlStoreFailed,
};

inline fn failOptionalRecord(err: anytype) @TypeOf(err)!?Record {
    return @errorCast(failOptionalRecordDynamic(err));
}

noinline fn failOptionalRecordDynamic(err: anyerror) anyerror!?Record {
    return err;
}


pub const Store = struct {
    capability: *session_child_store.SessionChildCapability,
    expected_child_id: []const u8,

    pub fn acquireLock(self: Store) LockError!io_mod.TimedAdvisoryLock {
        return self.capability.acquireTimedAdvisoryLock(
            .subagent_control,
            lock_file,
            lock_deadline_ms,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LockBusy => error.ControlLockBusy,
            error.LockUnsupported => error.ControlLockUnsupported,
            error.SessionPathUnsafe => error.ControlPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.ControlStoreFailed,
        };
    }

    /// Returns an owned record, or null when no control record exists.
    pub fn loadOptional(self: Store, alloc: Allocator) LoadError!?Record {
        var file = self.capability.openFileReadOnly(
            alloc,
            .subagent_control,
            record_file,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return failOptionalRecord(error.OutOfMemory),
            error.SessionPathUnsafe => return failOptionalRecord(error.ControlPathUnsafe),
            error.PrivateStatePermissionsUnsupported => {
                return failOptionalRecord(error.PrivateStatePermissionsUnsupported);
            },
            else => return failOptionalRecord(error.ControlStoreFailed),
        };
        defer file.deinit();
        const bytes = file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
            error.OutOfMemory => return failOptionalRecord(error.OutOfMemory),
            error.StreamTooLong => return failOptionalRecord(error.ControlRecordTooLarge),
            else => return failOptionalRecord(error.ControlStoreFailed),
        };
        defer alloc.free(bytes);
        var record = parseRecord(alloc, bytes) catch |err|
            return failOptionalRecord(err);
        errdefer record.deinit(alloc);
        if (!std.mem.eql(u8, record.child_id, self.expected_child_id)) {
            return failOptionalRecord(error.InvalidControlRecord);
        }
        return record;
    }

    /// Returns an owned record; caller frees it with `Record.deinit`.
    pub fn load(self: Store, alloc: Allocator) LoadError!Record {
        return (try self.loadOptional(alloc)) orelse error.ControlNotFound;
    }

    pub fn save(self: Store, alloc: Allocator, record: Record) SaveError!void {
        if (!std.mem.eql(u8, record.child_id, self.expected_child_id)) {
            return error.ControlIdentityMismatch;
        }
        var retained = record.clone(alloc) catch return error.OutOfMemory;
        defer retained.deinit(alloc);
        prepareForSave(alloc, &retained) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ControlRecordTooLarge => error.ControlRecordTooLarge,
        };
        validateRecordSemanticsForRecord(retained) catch
            return error.ControlRecordTooLarge;
        const bytes = renderRecord(alloc, retained) catch return error.OutOfMemory;
        defer alloc.free(bytes);
        std.debug.assert(bytes.len <= max_record_bytes);
        var entry = self.capability.atomicReplace(
            alloc,
            .subagent_control,
            record_file,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.ControlPathUnsafe,
            error.PrivateStatePermissionsUnsupported => {
                return error.PrivateStatePermissionsUnsupported;
            },
            error.SessionChildCommitIndeterminate => {
                return error.ControlCommitIndeterminate;
            },
            else => return error.ControlStoreFailed,
        };
        entry.deinit(alloc);
    }
};

pub const PrepareError = error{ OutOfMemory, ControlRecordTooLarge };

/// Canonical-byte retention preparation. Active work is never selected for
/// compaction; terminal persistent queue payloads, receipt epochs, and their
/// now-unreferenced event prefix are reduced together until the record fits.
pub fn prepareForSave(alloc: Allocator, record: *Record) PrepareError!void {
    return prepareForSaveLimit(alloc, record, max_record_bytes);
}

fn prepareForSaveLimit(
    alloc: Allocator,
    record: *Record,
    byte_limit: usize,
) PrepareError!void {
    var terminal_queue_compacted = false;
    while (true) {
        const bytes = renderRecord(alloc, record.*) catch return error.OutOfMemory;
        const fits = bytes.len <= byte_limit;
        alloc.free(bytes);
        if (fits) return;

        if (!terminal_queue_compacted) {
            terminal_queue_compacted = true;
            if (try compactTerminalQueue(alloc, record)) {
                _ = try evictUnrequiredEventPrefix(alloc, record);
                continue;
            }
        }
        if (try evictOldestReceiptHorizon(alloc, record)) {
            _ = try evictUnrequiredEventPrefix(alloc, record);
            continue;
        }
        if (try evictUnrequiredEventPrefix(alloc, record)) continue;
        return error.ControlRecordTooLarge;
    }
}

fn compactTerminalQueue(alloc: Allocator, record: *Record) error{OutOfMemory}!bool {
    if (record.mode == .one_off) return false;
    var retained_count: usize = 0;
    for (record.queue) |message| {
        if (!isTerminalQueueStatus(message.status) or
            terminalNeedsRecovery(record.generation, record.events, message))
        {
            retained_count += 1;
        }
    }
    if (retained_count == record.queue.len) return false;
    const retained = try alloc.alloc(domain.QueuedMessage, retained_count);
    var retained_index: usize = 0;
    for (record.queue) |*message| {
        if (isTerminalQueueStatus(message.status) and
            !terminalNeedsRecovery(record.generation, record.events, message.*))
        {
            message.deinit(alloc);
            continue;
        }
        retained[retained_index] = message.*;
        retained_index += 1;
    }
    alloc.free(record.queue);
    record.queue = retained;
    record.queue_evicted = true;
    return true;
}

fn terminalNeedsRecovery(
    generation: u64,
    events: []const domain.Event,
    message: domain.QueuedMessage,
) bool {
    var index = events.len;
    while (index != 0) {
        index -= 1;
        const event = events[index];
        switch (event.kind) {
            .work_transition => |transition| {
                if (!std.mem.eql(u8, transition.work_item_id, message.id)) continue;
                return event.revision == generation;
            },
            else => {},
        }
    }
    return true;
}

fn evictOldestReceiptHorizon(alloc: Allocator, record: *Record) error{OutOfMemory}!bool {
    if (record.operations.len <= 1) return false;
    const evicted_index = oldestCommittedIssuanceReceiptIndex(record.operations);
    const evicted_identity = tool_result.parseBoundOperationId(
        record.operations[evicted_index].id,
    );
    const retained = try alloc.alloc(
        domain.OperationReceipt,
        record.operations.len - 1,
    );
    @memcpy(retained[0..evicted_index], record.operations[0..evicted_index]);
    @memcpy(retained[evicted_index..], record.operations[evicted_index + 1 ..]);
    record.operations[evicted_index].deinit(alloc);
    alloc.free(record.operations);
    record.operations = retained;
    if (evicted_identity) |identity| {
        if (identity.authority != .manager) {
            record.legacy_replay_closed = true;
            return true;
        }
        const next = identity.epoch +| 1;
        const source = identity.source;
        switch (source) {
            .model => record.model_replay_floor = @max(record.model_replay_floor, next),
            .human => record.human_replay_floor = @max(record.human_replay_floor, next),
        }
    } else {
        record.legacy_replay_closed = true;
    }
    return true;
}

fn oldestCommittedIssuanceReceiptIndex(
    operations: []const domain.OperationReceipt,
) usize {
    var selected: ?usize = null;
    var selected_epoch: u64 = 0;
    for (operations, 0..) |operation, index| {
        const identity = tool_result.parseBoundOperationId(operation.id);
        if (identity == null or identity.?.authority == .process_local) return index;
        if (selected == null or identity.?.epoch < selected_epoch) {
            selected = index;
            selected_epoch = identity.?.epoch;
        }
    }
    return selected.?;
}

fn evictUnrequiredEventPrefix(alloc: Allocator, record: *Record) error{OutOfMemory}!bool {
    if (record.events.len == 0) return false;
    var first_required = record.next_event_sequence;
    for (record.operations) |operation| {
        first_required = @min(first_required, operation.event_sequence);
    }
    for (record.queue) |message| {
        for (record.events) |event| switch (event.kind) {
            .work_transition => |transition| {
                if (std.mem.eql(u8, transition.work_item_id, message.id)) {
                    first_required = @min(first_required, event.sequence);
                    break;
                }
            },
            else => {},
        };
    }
    const first_retained_sequence = record.events[0].sequence;
    if (first_required <= first_retained_sequence) return false;
    const remove_u64 = @min(
        first_required - first_retained_sequence,
        @as(u64, @intCast(record.events.len)),
    );
    const remove_count: usize = @intCast(remove_u64);
    if (remove_count == 0) return false;
    const retained = try alloc.alloc(domain.Event, record.events.len - remove_count);
    @memcpy(retained, record.events[remove_count..]);
    const evicted_through = record.events[remove_count - 1].sequence;
    for (record.events[0..remove_count]) |*event| event.deinit(alloc);
    record.events_evicted_through = evicted_through;
    record.notification_cursor = @max(
        record.notification_cursor,
        record.events_evicted_through,
    );
    alloc.free(record.events);
    record.events = retained;
    return true;
}

fn isTerminalQueueStatus(status: domain.QueueStatus) bool {
    return status == .completed or status == .failed or status == .cancelled;
}

pub fn validateManagedRecord(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    expected_child_id: []const u8,
) LoadError!void {
    var store = Store{
        .capability = capability,
        .expected_child_id = expected_child_id,
    };
    var record = (try store.loadOptional(alloc)) orelse return;
    record.deinit(alloc);
}

/// Returns an owned JSON record; caller frees it with `alloc.free`.
fn renderRecord(alloc: Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;

    try writer.print("{{\"schema_version\":{d},\"child_id\":", .{schema_version});
    try writeJsonString(writer, record.child_id);
    try writer.print(",\"generation\":{d},\"parent_id\":", .{record.generation});
    try writeOptionalString(writer, record.parent_id);
    try writer.writeAll(",\"mode\":");
    try writeJsonString(writer, @tagName(record.mode));
    try writer.writeAll(",\"configuration\":");
    try renderConfiguration(writer, record.configuration);
    try writer.writeAll(",\"state\":");
    try writeJsonString(writer, @tagName(record.state));
    try writer.writeAll(",\"archived_from\":");
    if (record.archived_from) |state| {
        try writeJsonString(writer, @tagName(state));
    } else try writer.writeAll("null");
    try writer.writeAll(",\"queue\":[");
    for (record.queue, 0..) |message, index| {
        if (index != 0) try writer.writeByte(',');
        try renderMessage(writer, message);
    }
    try writer.writeAll("],\"events\":[");
    for (record.events, 0..) |event, index| {
        if (index != 0) try writer.writeByte(',');
        try renderEvent(writer, event);
    }
    try writer.writeAll("],\"operations\":[");
    for (record.operations, 0..) |operation, index| {
        if (index != 0) try writer.writeByte(',');
        try renderOperation(writer, operation);
    }
    try writer.print(
        "],\"next_event_sequence\":{d},\"notification_cursor\":{d},\"events_evicted_through\":{d},\"queue_evicted\":{},\"legacy_replay_closed\":{},\"model_replay_floor\":{d},\"human_replay_floor\":{d},\"model_epoch_high\":{d},\"human_epoch_high\":{d},\"created_at_ms\":{d},\"updated_at_ms\":{d}}}",
        .{
            record.next_event_sequence,
            record.notification_cursor,
            record.events_evicted_through,
            record.queue_evicted,
            record.legacy_replay_closed,
            record.model_replay_floor,
            record.human_replay_floor,
            record.model_epoch_high,
            record.human_epoch_high,
            record.created_at_ms,
            record.updated_at_ms,
        },
    );
    return out.toOwnedSlice();
}

fn renderConfiguration(
    writer: *std.Io.Writer,
    configuration: domain.Configuration,
) !void {
    try writer.writeAll("{\"name\":");
    try writeJsonString(writer, configuration.name);
    try writer.writeAll(",\"model\":");
    try writeOptionalString(writer, configuration.model);
    try writer.writeAll(",\"effort\":");
    if (configuration.effort) |effort| {
        try writeJsonString(writer, effort.label());
    } else try writer.writeAll("null");
    try writer.writeAll(",\"permission_mode\":");
    try writeJsonString(writer, @tagName(configuration.permission_mode));
    try writer.writeAll(",\"notifications\":");
    try renderNotifications(writer, configuration.notifications);
    try writer.writeByte('}');
}

fn renderNotifications(
    writer: *std.Io.Writer,
    notifications: domain.NotificationPolicy,
) !void {
    try writer.print(
        "{{\"terminal\":{{\"completed\":{},\"failed\":{},\"cancelled\":{}}},\"milestones\":[",
        .{
            notifications.terminal.completed,
            notifications.terminal.failed,
            notifications.terminal.cancelled,
        },
    );
    for (notifications.milestones, 0..) |name, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, name);
    }
    try writer.writeAll("],\"report_interval_ms\":");
    try writeOptionalU64(writer, notifications.report_interval_ms);
    try writer.writeAll(",\"report_duration_ms\":");
    try writeOptionalU64(writer, notifications.report_duration_ms);
    try writer.writeAll(",\"stop_conditions\":[");
    for (notifications.stop_conditions, 0..) |condition, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, @tagName(condition));
    }
    try writer.writeAll("]}");
}

fn renderMessage(writer: *std.Io.Writer, message: domain.QueuedMessage) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, message.id);
    try writer.writeAll(",\"source_id\":");
    try writeJsonString(writer, message.source_id);
    try writer.writeAll(",\"content\":");
    try writeJsonString(writer, message.content);
    try writer.writeAll(",\"root_user_intent_context\":");
    try writeJsonString(writer, message.root_user_intent_context);
    try writer.writeAll(",\"root_user_messages\":[");
    for (message.root_user_messages, 0..) |root_user_message, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJsonString(writer, root_user_message);
    }
    try writer.print("],\"root_user_evidence_complete\":{}", .{
        message.root_user_evidence_complete,
    });
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, @tagName(message.status));
    try writer.writeAll(",\"cancellation_reason\":");
    try writeOptionalString(writer, message.cancellation_reason);
    try writer.print(",\"created_at_ms\":{d}}}", .{message.created_at_ms});
}

fn renderEvent(writer: *std.Io.Writer, event: domain.Event) !void {
    try writer.print("{{\"sequence\":{d},\"revision\":{d},\"id\":", .{
        event.sequence,
        event.revision,
    });
    try writeJsonString(writer, event.id);
    try writer.print(",\"timestamp_ms\":{d},\"kind\":", .{event.timestamp_ms});
    try writeJsonString(writer, @tagName(event.kind));
    switch (event.kind) {
        .created, .configured => {},
        .message_queued => |value| {
            try writer.writeAll(",\"message_id\":");
            try writeJsonString(writer, value.message_id);
        },
        .relationship_changed => |value| {
            try writer.writeAll(",\"previous_parent_id\":");
            try writeOptionalString(writer, value.previous_parent_id);
            try writer.writeAll(",\"parent_id\":");
            try writeOptionalString(writer, value.parent_id);
        },
        .lifecycle_changed => |value| {
            try writer.writeAll(",\"previous\":");
            try writeJsonString(writer, @tagName(value.previous));
            try writer.writeAll(",\"current\":");
            try writeJsonString(writer, @tagName(value.current));
        },
        .work_transition => |value| {
            try writer.writeAll(",\"work_item_id\":");
            try writeJsonString(writer, value.work_item_id);
            try writer.writeAll(",\"previous\":");
            if (value.previous) |status| {
                try writeJsonString(writer, @tagName(status));
            } else try writer.writeAll("null");
            try writer.writeAll(",\"current\":");
            try writeJsonString(writer, @tagName(value.current));
            try writer.writeAll(",\"reason\":");
            try writeOptionalString(writer, value.reason);
        },
        .milestone_emitted => |value| {
            try writer.writeAll(",\"operation_id\":");
            try writeJsonString(writer, value.operation_id);
            try writer.writeAll(",\"source_child_id\":");
            try writeJsonString(writer, value.source_child_id);
            try writer.writeAll(",\"target_parent_id\":");
            try writeJsonString(writer, value.target_parent_id);
            try writer.writeAll(",\"work_item_id\":");
            try writeJsonString(writer, value.work_item_id);
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, value.name);
        },
    }
    try writer.writeByte('}');
}

fn renderOperation(
    writer: *std.Io.Writer,
    operation: domain.OperationReceipt,
) !void {
    const request_fingerprint = std.fmt.bytesToHex(operation.request_fingerprint, .lower);
    const fingerprint = std.fmt.bytesToHex(operation.fingerprint, .lower);
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, operation.id);
    try writer.writeAll(",\"request_fingerprint\":");
    try writeJsonString(writer, &request_fingerprint);
    try writer.writeAll(",\"fingerprint\":");
    try writeJsonString(writer, &fingerprint);
    try writer.writeAll(",\"code\":");
    try writeJsonString(writer, @tagName(operation.code));
    try writer.writeAll(",\"target_id\":");
    try writeJsonString(writer, operation.target_id);
    try writer.writeAll(",\"identity_source\":");
    if (operation.identity_source) |source| {
        try writeJsonString(writer, @tagName(source));
    } else try writer.writeAll("null");
    try writer.writeAll(",\"identity_epoch\":");
    try writeOptionalU64(writer, operation.identity_epoch);
    try writer.print(
        ",\"generation\":{d},\"event_sequence\":{d}}}",
        .{ operation.generation, operation.event_sequence },
    );
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| try writeJsonString(writer, text) else try writer.writeAll("null");
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |number| try writer.print("{d}", .{number}) else try writer.writeAll("null");
}

/// Returns an owned record; caller frees it with `Record.deinit`.
fn parseRecord(alloc: Allocator, bytes: []const u8) LoadError!Record {
    if (bytes.len > max_record_bytes) return error.ControlRecordTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidControlRecord,
    };
    defer parsed.deinit();
    const root = requireObject(parsed.value) catch return error.InvalidControlRecord;
    const version = requireU64(root, "schema_version") catch
        return error.InvalidControlRecord;
    if (version < legacy_schema_version or version > schema_version) {
        return error.UnsupportedControlSchema;
    }
    const common_fields = [_][]const u8{
        "schema_version",      "child_id",
        "generation",          "parent_id",
        "mode",                "configuration",
        "state",               "archived_from",
        "queue",               "events",
        "operations",          "next_event_sequence",
        "notification_cursor", "created_at_ms",
        "updated_at_ms",
    };
    const current_fields = [_][]const u8{
        "schema_version",      "child_id",
        "generation",          "parent_id",
        "mode",                "configuration",
        "state",               "archived_from",
        "queue",               "events",
        "operations",          "next_event_sequence",
        "notification_cursor", "events_evicted_through",
        "queue_evicted",       "legacy_replay_closed",
        "model_replay_floor",  "human_replay_floor",
        "model_epoch_high",    "human_epoch_high",
        "created_at_ms",       "updated_at_ms",
    };
    const object = exactObject(
        parsed.value,
        if (version >= process_epoch_schema_version)
            &current_fields
        else
            &common_fields,
    ) catch return error.InvalidControlRecord;

    const child_id_raw = requireString(object, "child_id") catch
        return error.InvalidControlRecord;
    domain.validateId(child_id_raw) catch return error.InvalidControlRecord;
    const parent_id_raw = optionalString(object, "parent_id") catch
        return error.InvalidControlRecord;
    if (parent_id_raw) |id| {
        domain.validateId(id) catch return error.InvalidControlRecord;
        if (std.mem.eql(u8, child_id_raw, id)) return error.InvalidControlRecord;
    }
    const child_id = try alloc.dupe(u8, child_id_raw);
    errdefer alloc.free(child_id);
    const parent_id = if (parent_id_raw) |id| try alloc.dupe(u8, id) else null;
    errdefer if (parent_id) |id| alloc.free(id);
    var configuration = try parseConfiguration(
        alloc,
        object.get("configuration") orelse return error.InvalidControlRecord,
        version,
    );
    errdefer configuration.deinit(alloc);
    const queue = try parseQueue(
        alloc,
        object.get("queue") orelse return error.InvalidControlRecord,
        version,
    );
    errdefer freeQueue(alloc, queue);
    const events = try parseEvents(
        alloc,
        object.get("events") orelse return error.InvalidControlRecord,
    );
    errdefer freeEvents(alloc, events);
    const operations = try parseOperations(
        alloc,
        object.get("operations") orelse return error.InvalidControlRecord,
        version,
    );
    errdefer freeOperations(alloc, operations);
    const generation = requireU64(object, "generation") catch
        return error.InvalidControlRecord;
    const next_event_sequence = requireU64(object, "next_event_sequence") catch
        return error.InvalidControlRecord;
    const notification_cursor = requireU64(object, "notification_cursor") catch
        return error.InvalidControlRecord;
    const has_replay_fields = version != legacy_schema_version;
    const events_evicted_through = if (has_replay_fields)
        requireU64(object, "events_evicted_through") catch return error.InvalidControlRecord
    else
        0;
    const queue_evicted = if (has_replay_fields)
        requireBool(object, "queue_evicted") catch return error.InvalidControlRecord
    else
        false;
    const legacy_replay_closed = if (has_replay_fields)
        requireBool(object, "legacy_replay_closed") catch return error.InvalidControlRecord
    else
        true;
    const stored_model_replay_floor = if (has_replay_fields)
        requireU64(object, "model_replay_floor") catch return error.InvalidControlRecord
    else
        0;
    const stored_human_replay_floor = if (has_replay_fields)
        requireU64(object, "human_replay_floor") catch return error.InvalidControlRecord
    else
        0;
    const stored_model_epoch_high = if (has_replay_fields)
        requireU64(object, "model_epoch_high") catch return error.InvalidControlRecord
    else
        0;
    const stored_human_epoch_high = if (has_replay_fields)
        requireU64(object, "human_epoch_high") catch return error.InvalidControlRecord
    else
        0;
    if (stored_model_replay_floor > stored_model_epoch_high +| 1 or
        stored_human_replay_floor > stored_human_epoch_high +| 1 or
        (!legacy_replay_closed and (stored_model_replay_floor != 0 or
            stored_human_replay_floor != 0 or
            stored_model_epoch_high != 0 or
            stored_human_epoch_high != 0)))
    {
        return error.InvalidControlRecord;
    }
    const has_manager_epochs = version >= manager_epoch_schema_version;
    const model_replay_floor = if (has_manager_epochs)
        stored_model_replay_floor
    else
        0;
    const human_replay_floor = if (has_manager_epochs)
        stored_human_replay_floor
    else
        0;
    const model_epoch_high = if (has_manager_epochs)
        stored_model_epoch_high
    else
        0;
    const human_epoch_high = if (has_manager_epochs)
        stored_human_epoch_high
    else
        0;
    const mode = parseEnum(domain.Mode, requireString(object, "mode") catch
        return error.InvalidControlRecord) catch return error.InvalidControlRecord;
    const state = parseEnum(domain.State, requireString(object, "state") catch
        return error.InvalidControlRecord) catch return error.InvalidControlRecord;
    const archived_from = parseOptionalEnum(
        domain.State,
        object.get("archived_from") orelse return error.InvalidControlRecord,
    ) catch return error.InvalidControlRecord;
    validateRecordSemantics(
        child_id,
        generation,
        mode,
        state,
        archived_from,
        queue,
        events,
        operations,
        next_event_sequence,
        notification_cursor,
        events_evicted_through,
        queue_evicted,
        legacy_replay_closed,
        model_replay_floor,
        human_replay_floor,
        model_epoch_high,
        human_epoch_high,
        if (version == process_epoch_schema_version)
            .process_local
        else
            .manager,
    ) catch return error.InvalidControlRecord;
    return .{
        .child_id = child_id,
        .generation = generation,
        .parent_id = parent_id,
        .mode = mode,
        .configuration = configuration,
        .state = state,
        .archived_from = archived_from,
        .queue = queue,
        .events = events,
        .operations = operations,
        .next_event_sequence = next_event_sequence,
        .notification_cursor = notification_cursor,
        .events_evicted_through = events_evicted_through,
        .queue_evicted = queue_evicted,
        .legacy_replay_closed = legacy_replay_closed,
        .model_replay_floor = model_replay_floor,
        .human_replay_floor = human_replay_floor,
        .model_epoch_high = model_epoch_high,
        .human_epoch_high = human_epoch_high,
        .created_at_ms = requireI64(object, "created_at_ms") catch
            return error.InvalidControlRecord,
        .updated_at_ms = requireI64(object, "updated_at_ms") catch
            return error.InvalidControlRecord,
    };
}

fn validateRecordSemantics(
    child_id: []const u8,
    generation: u64,
    mode: domain.Mode,
    state: domain.State,
    archived_from: ?domain.State,
    queue: []const domain.QueuedMessage,
    events: []const domain.Event,
    operations: []const domain.OperationReceipt,
    next_event_sequence: u64,
    notification_cursor: u64,
    events_evicted_through: u64,
    queue_evicted: bool,
    legacy_replay_closed: bool,
    model_replay_floor: u64,
    human_replay_floor: u64,
    model_epoch_high: u64,
    human_epoch_high: u64,
    expected_identity_authority: domain.OperationIdentityAuthority,
) !void {
    if (generation == 0 and (events.len != 0 or events_evicted_through != 0)) {
        return error.InvalidControlRecord;
    }
    if (generation != 0 and events.len == 0 and events_evicted_through == 0) {
        return error.InvalidControlRecord;
    }
    if (model_replay_floor > model_epoch_high +| 1 or
        human_replay_floor > human_epoch_high +| 1)
    {
        return error.InvalidControlRecord;
    }
    if (!legacy_replay_closed and (model_replay_floor != 0 or
        human_replay_floor != 0 or model_epoch_high != 0 or
        human_epoch_high != 0))
    {
        return error.InvalidControlRecord;
    }
    if ((state == .archived) != (archived_from != null) or
        archived_from == .archived)
    {
        return error.InvalidControlRecord;
    }
    var running: usize = 0;
    var awaiting: usize = 0;
    var pending: usize = 0;
    var interrupted: usize = 0;
    for (queue, 0..) |message, index| {
        if (message.root_user_intent_context.len > 0 and
            !auto_classifier_context.isCanonicalRootUserContext(
                message.root_user_intent_context,
            ))
        {
            return error.InvalidControlRecord;
        }
        if (message.root_user_evidence_complete !=
            (message.root_user_messages.len > 0))
        {
            return error.InvalidControlRecord;
        }
        var root_user_bytes: usize = 0;
        for (message.root_user_messages) |root_user_message| {
            if (root_user_message.len == 0) return error.InvalidControlRecord;
            root_user_bytes = std.math.add(
                usize,
                root_user_bytes,
                root_user_message.len,
            ) catch return error.InvalidControlRecord;
            if (root_user_bytes > domain.max_root_user_evidence_bytes) {
                return error.InvalidControlRecord;
            }
        }
        const requires_reason = message.status == .cancelled or
            message.status == .interrupted;
        if (requires_reason != (message.cancellation_reason != null)) {
            return error.InvalidControlRecord;
        }
        switch (message.status) {
            .running => running += 1,
            .awaiting_approval => awaiting += 1,
            .pending => pending += 1,
            .interrupted => interrupted += 1,
            else => {},
        }
        for (queue[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, message.id)) return error.InvalidControlRecord;
        }
    }
    if (running + awaiting > 1) return error.InvalidControlRecord;
    if (mode == .one_off and queue.len != 1) return error.InvalidControlRecord;
    switch (state) {
        .running => if (running != 1 or awaiting != 0) return error.InvalidControlRecord,
        .awaiting_approval => if (awaiting != 1 or running != 0) return error.InvalidControlRecord,
        .queued => if (pending + interrupted == 0 or running != 0 or awaiting != 0)
            return error.InvalidControlRecord,
        .interrupted => if (interrupted == 0 or running != 0 or awaiting != 0)
            return error.InvalidControlRecord,
        .idle => if (mode != .persistent or pending != 0 or running != 0 or
            awaiting != 0 or interrupted != 0) return error.InvalidControlRecord,
        .completed => if (mode != .one_off or queue[0].status != .completed) return error.InvalidControlRecord,
        .failed => if (mode != .one_off or queue[0].status != .failed) return error.InvalidControlRecord,
        .cancelled => if (mode != .one_off or queue[0].status != .cancelled) return error.InvalidControlRecord,
        .archived => if (running != 0 or awaiting != 0 or pending != 0)
            return error.InvalidControlRecord,
    }
    const event_count = std.math.cast(u64, events.len) orelse return error.InvalidControlRecord;
    const retained_end = std.math.add(u64, events_evicted_through, event_count) catch
        return error.InvalidControlRecord;
    if (retained_end == std.math.maxInt(u64) or next_event_sequence != retained_end + 1) {
        return error.InvalidControlRecord;
    }
    if (notification_cursor >= next_event_sequence) return error.InvalidControlRecord;
    var prior_revision: u64 = 0;
    for (events, 0..) |event, index| {
        const offset = std.math.cast(u64, index + 1) orelse return error.InvalidControlRecord;
        const expected = std.math.add(u64, events_evicted_through, offset) catch
            return error.InvalidControlRecord;
        if (event.sequence != expected or event.revision == 0 or
            event.revision > generation or event.revision < prior_revision or
            (index != 0 and event.revision > prior_revision + 1) or
            !eventPayloadIsCanonical(child_id, event))
        {
            return error.InvalidControlRecord;
        }
        prior_revision = event.revision;
    }
    if (events.len != 0 and prior_revision != generation) return error.InvalidControlRecord;
    var prior_operation_generation: u64 = 0;
    for (operations, 0..) |operation, index| {
        if (!std.mem.eql(u8, operation.target_id, child_id) or
            operation.generation <= prior_operation_generation or
            operation.generation > generation or operation.event_sequence == 0 or
            operation.event_sequence <= events_evicted_through or
            operation.event_sequence >= next_event_sequence or
            (operation.identity_source == null) != (operation.identity_epoch == null))
        {
            return error.InvalidControlRecord;
        }
        const bound = tool_result.parseBoundOperationId(operation.id);
        if (operation.identity_source) |source| {
            const identity = bound orelse return error.InvalidControlRecord;
            if (!legacy_replay_closed or identity.source != source or
                identity.epoch != operation.identity_epoch.?)
            {
                return error.InvalidControlRecord;
            }
            if (identity.authority != expected_identity_authority and
                !(expected_identity_authority == .manager and
                    identity.authority == .process_local))
            {
                return error.InvalidControlRecord;
            }
            const high = switch (source) {
                .model => model_epoch_high,
                .human => human_epoch_high,
            };
            if (identity.authority == expected_identity_authority and
                identity.epoch > high)
            {
                return error.InvalidControlRecord;
            }
        } else if (bound != null) {
            return error.InvalidControlRecord;
        }
        const event_index = operation.event_sequence - events_evicted_through - 1;
        const event = events[@intCast(event_index)];
        if (event.revision != operation.generation or
            !std.mem.eql(u8, event.id, operation.id) or
            !outcomeMatchesEvent(operation.code, event.kind)) return error.InvalidControlRecord;
        prior_operation_generation = operation.generation;
        for (operations[0..index]) |prior| if (std.mem.eql(u8, prior.id, operation.id) and
            prior.identity_source == operation.identity_source and
            prior.identity_epoch == operation.identity_epoch)
        {
            return error.InvalidControlRecord;
        };
    }
    for (queue) |message| {
        var status: ?domain.QueueStatus = null;
        var final_reason: ?[]const u8 = null;
        var saw_transition = false;
        for (events) |event| switch (event.kind) {
            .work_transition => |transition| {
                if (!std.mem.eql(u8, transition.work_item_id, message.id)) continue;
                const requires_reason = transition.current == .cancelled or
                    transition.current == .interrupted;
                const permits_reason = requires_reason or transition.current == .failed;
                if (transition.previous != status or
                    !validWorkTransition(status, transition.current) or
                    (requires_reason and transition.reason == null) or
                    (!permits_reason and transition.reason != null))
                {
                    return error.InvalidControlRecord;
                }
                status = transition.current;
                final_reason = transition.reason;
                saw_transition = true;
            },
            else => {},
        };
        if (!saw_transition or status != message.status or
            (message.status != .failed and
                !optionalBytesEqual(final_reason, message.cancellation_reason)))
        {
            return error.InvalidControlRecord;
        }
    }
    for (events) |event| switch (event.kind) {
        .work_transition => |transition| {
            var found = false;
            for (queue) |message| {
                if (std.mem.eql(u8, transition.work_item_id, message.id)) {
                    found = true;
                    break;
                }
            }
            if (!found and !queue_evicted) return error.InvalidControlRecord;
        },
        else => {},
    };
}

fn validateRecordSemanticsForRecord(record: Record) !void {
    return validateRecordSemantics(
        record.child_id,
        record.generation,
        record.mode,
        record.state,
        record.archived_from,
        record.queue,
        record.events,
        record.operations,
        record.next_event_sequence,
        record.notification_cursor,
        record.events_evicted_through,
        record.queue_evicted,
        record.legacy_replay_closed,
        record.model_replay_floor,
        record.human_replay_floor,
        record.model_epoch_high,
        record.human_epoch_high,
        .manager,
    );
}

fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn validWorkTransition(previous: ?domain.QueueStatus, current: domain.QueueStatus) bool {
    const prior = previous orelse return current == .pending;
    return switch (prior) {
        .pending => current == .running or current == .failed or
            current == .cancelled or current == .interrupted,
        .running => current == .completed or current == .failed or
            current == .cancelled or current == .interrupted or
            current == .awaiting_approval,
        .awaiting_approval => current == .running or current == .completed or
            current == .cancelled or current == .interrupted,
        .interrupted => current == .running or current == .cancelled or current == .interrupted,
        .completed, .failed, .cancelled => false,
    };
}

fn eventPayloadIsCanonical(child_id: []const u8, event: domain.Event) bool {
    return switch (event.kind) {
        .message_queued => |message| std.mem.eql(u8, message.message_id, event.id),
        .milestone_emitted => |milestone| std.mem.eql(u8, milestone.operation_id, event.id) and
            std.mem.eql(u8, milestone.source_child_id, child_id),
        .work_transition => |transition| std.mem.eql(u8, transition.work_item_id, event.id),
        .created, .relationship_changed, .configured, .lifecycle_changed => true,
    };
}

fn outcomeMatchesEvent(code: domain.OutcomeCode, kind: domain.EventKind) bool {
    return switch (code) {
        .created => kind == .created,
        .message_queued => kind == .message_queued,
        .relationship_changed => kind == .relationship_changed,
        .configured => kind == .configured,
        .lifecycle_changed => kind == .lifecycle_changed,
        .milestone_emitted => kind == .milestone_emitted,
    };
}

fn parseConfiguration(
    alloc: Allocator,
    value: std.json.Value,
    version: u64,
) LoadError!domain.Configuration {
    const object = exactObject(
        value,
        if (version >= permission_mode_schema_version)
            &.{ "name", "model", "effort", "permission_mode", "notifications" }
        else
            &.{ "name", "model", "effort", "notifications" },
    ) catch
        return error.InvalidControlRecord;
    const name_raw = requireString(object, "name") catch return error.InvalidControlRecord;
    validateText(name_raw, domain.max_name_bytes) catch return error.InvalidControlRecord;
    const model_raw = optionalString(object, "model") catch return error.InvalidControlRecord;
    if (model_raw) |model| validateText(model, domain.max_model_bytes) catch
        return error.InvalidControlRecord;
    const effort = parseOptionalReasoningEffort(
        object.get("effort") orelse return error.InvalidControlRecord,
    ) catch return error.InvalidControlRecord;
    const name = try alloc.dupe(u8, name_raw);
    errdefer alloc.free(name);
    const model = if (model_raw) |raw| try alloc.dupe(u8, raw) else null;
    errdefer if (model) |owned| alloc.free(owned);
    return .{
        .name = name,
        .model = model,
        .effort = effort,
        .permission_mode = if (version >= permission_mode_schema_version)
            parseEnum(
                types.PermissionMode,
                requireString(object, "permission_mode") catch
                    return error.InvalidControlRecord,
            ) catch return error.InvalidControlRecord
        else
            .auto,
        .notifications = try parseNotifications(
            alloc,
            object.get("notifications") orelse return error.InvalidControlRecord,
        ),
    };
}

fn parseNotifications(
    alloc: Allocator,
    value: std.json.Value,
) LoadError!domain.NotificationPolicy {
    const object = exactObject(value, &.{
        "terminal",
        "milestones",
        "report_interval_ms",
        "report_duration_ms",
        "stop_conditions",
    }) catch return error.InvalidControlRecord;
    const terminal_object = exactObject(
        object.get("terminal") orelse return error.InvalidControlRecord,
        &.{ "completed", "failed", "cancelled" },
    ) catch return error.InvalidControlRecord;
    const milestone_value = object.get("milestones") orelse
        return error.InvalidControlRecord;
    if (milestone_value != .array or milestone_value.array.items.len > domain.max_milestones) {
        return error.InvalidControlRecord;
    }
    var milestone_views: std.ArrayList([]const u8) = .empty;
    defer milestone_views.deinit(alloc);
    for (milestone_value.array.items) |item| {
        if (item != .string) return error.InvalidControlRecord;
        try milestone_views.append(alloc, item.string);
    }
    const stop_value = object.get("stop_conditions") orelse
        return error.InvalidControlRecord;
    if (stop_value != .array or stop_value.array.items.len > domain.max_stop_conditions) {
        return error.InvalidControlRecord;
    }
    var stop_conditions: std.ArrayList(domain.StopCondition) = .empty;
    defer stop_conditions.deinit(alloc);
    for (stop_value.array.items) |item| {
        if (item != .string) return error.InvalidControlRecord;
        try stop_conditions.append(
            alloc,
            parseEnum(domain.StopCondition, item.string) catch
                return error.InvalidControlRecord,
        );
    }
    return domain.validateNotificationPolicy(alloc, .{
        .terminal = .{
            .completed = requireBool(terminal_object, "completed") catch
                return error.InvalidControlRecord,
            .failed = requireBool(terminal_object, "failed") catch
                return error.InvalidControlRecord,
            .cancelled = requireBool(terminal_object, "cancelled") catch
                return error.InvalidControlRecord,
        },
        .milestones = milestone_views.items,
        .report_interval_ms = optionalU64(object, "report_interval_ms") catch
            return error.InvalidControlRecord,
        .report_duration_ms = optionalU64(object, "report_duration_ms") catch
            return error.InvalidControlRecord,
        .stop_conditions = stop_conditions.items,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidControlRecord,
    };
}

fn parseQueue(
    alloc: Allocator,
    value: std.json.Value,
    version: u64,
) LoadError![]domain.QueuedMessage {
    if (value != .array) return error.InvalidControlRecord;
    var messages: std.ArrayList(domain.QueuedMessage) = .empty;
    errdefer {
        for (messages.items) |*message| message.deinit(alloc);
        messages.deinit(alloc);
    }
    for (value.array.items) |item| {
        const object = exactObject(item, if (version == schema_version)
            &.{
                "id",
                "source_id",
                "content",
                "root_user_intent_context",
                "root_user_messages",
                "root_user_evidence_complete",
                "status",
                "cancellation_reason",
                "created_at_ms",
            }
        else if (version == root_context_schema_version)
            &.{
                "id",
                "source_id",
                "content",
                "root_user_intent_context",
                "status",
                "cancellation_reason",
                "created_at_ms",
            }
        else
            &.{
                "id",
                "source_id",
                "content",
                "status",
                "cancellation_reason",
                "created_at_ms",
            }) catch return error.InvalidControlRecord;
        const id_raw = requireString(object, "id") catch return error.InvalidControlRecord;
        domain.validateOperationId(id_raw) catch return error.InvalidControlRecord;
        const source_raw = requireString(object, "source_id") catch
            return error.InvalidControlRecord;
        domain.validateId(source_raw) catch return error.InvalidControlRecord;
        const content_raw = requireString(object, "content") catch
            return error.InvalidControlRecord;
        validateText(content_raw, domain.max_message_bytes) catch
            return error.InvalidControlRecord;
        const root_user_intent_context_raw = if (version >= root_context_schema_version)
            requireString(object, "root_user_intent_context") catch
                return error.InvalidControlRecord
        else
            "";
        if (root_user_intent_context_raw.len > 0 and
            !auto_classifier_context.isCanonicalRootUserContext(
                root_user_intent_context_raw,
            ))
        {
            return error.InvalidControlRecord;
        }
        const root_user_evidence_complete = if (version == schema_version)
            requireBool(object, "root_user_evidence_complete") catch
                return error.InvalidControlRecord
        else
            false;
        const root_user_messages = if (version == schema_version)
            try parseRootUserMessages(
                alloc,
                object.get("root_user_messages") orelse
                    return error.InvalidControlRecord,
                root_user_evidence_complete,
            )
        else
            try alloc.alloc([]u8, 0);
        errdefer freeRootUserMessages(alloc, root_user_messages);
        const reason_raw = optionalString(object, "cancellation_reason") catch
            return error.InvalidControlRecord;
        if (reason_raw) |reason| {
            validateText(reason, domain.max_cancellation_reason_bytes) catch
                return error.InvalidControlRecord;
        }
        const id = try alloc.dupe(u8, id_raw);
        errdefer alloc.free(id);
        const source_id = try alloc.dupe(u8, source_raw);
        errdefer alloc.free(source_id);
        const content = try alloc.dupe(u8, content_raw);
        errdefer alloc.free(content);
        const root_user_intent_context = try alloc.dupe(
            u8,
            root_user_intent_context_raw,
        );
        errdefer if (root_user_intent_context.len > 0) {
            alloc.free(root_user_intent_context);
        };
        const reason = if (reason_raw) |raw| try alloc.dupe(u8, raw) else null;
        errdefer if (reason) |owned| alloc.free(owned);
        try messages.append(alloc, .{
            .id = id,
            .source_id = source_id,
            .content = content,
            .root_user_intent_context = root_user_intent_context,
            .root_user_messages = root_user_messages,
            .root_user_evidence_complete = root_user_evidence_complete,
            .status = parseEnum(
                domain.QueueStatus,
                requireString(object, "status") catch return error.InvalidControlRecord,
            ) catch return error.InvalidControlRecord,
            .cancellation_reason = reason,
            .created_at_ms = requireI64(object, "created_at_ms") catch
                return error.InvalidControlRecord,
        });
    }
    return messages.toOwnedSlice(alloc);
}

fn parseRootUserMessages(
    alloc: Allocator,
    value: std.json.Value,
    complete: bool,
) LoadError![][]u8 {
    if (value != .array) return error.InvalidControlRecord;
    if (complete != (value.array.items.len > 0)) return error.InvalidControlRecord;
    const messages = try alloc.alloc([]u8, value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (messages[0..initialized]) |message| alloc.free(message);
        alloc.free(messages);
    }
    var total_bytes: usize = 0;
    for (value.array.items) |item| {
        if (item != .string or item.string.len == 0) return error.InvalidControlRecord;
        total_bytes = std.math.add(usize, total_bytes, item.string.len) catch
            return error.InvalidControlRecord;
        if (total_bytes > domain.max_root_user_evidence_bytes) {
            return error.InvalidControlRecord;
        }
        messages[initialized] = try alloc.dupe(u8, item.string);
        initialized += 1;
    }
    return messages;
}

fn freeRootUserMessages(alloc: Allocator, messages: [][]u8) void {
    for (messages) |message| alloc.free(message);
    alloc.free(messages);
}

fn parseEvents(alloc: Allocator, value: std.json.Value) LoadError![]domain.Event {
    if (value != .array) return error.InvalidControlRecord;
    var events: std.ArrayList(domain.Event) = .empty;
    errdefer {
        for (events.items) |*event| event.deinit(alloc);
        events.deinit(alloc);
    }
    var previous_sequence: ?u64 = null;
    for (value.array.items) |item| {
        const object = requireObject(item) catch return error.InvalidControlRecord;
        const sequence = requireU64(object, "sequence") catch return error.InvalidControlRecord;
        const revision = requireU64(object, "revision") catch return error.InvalidControlRecord;
        if (previous_sequence) |previous| {
            if (sequence <= previous) return error.InvalidControlRecord;
        }
        previous_sequence = sequence;
        const id_raw = requireString(object, "id") catch return error.InvalidControlRecord;
        domain.validateOperationId(id_raw) catch return error.InvalidControlRecord;
        const timestamp_ms = requireI64(object, "timestamp_ms") catch
            return error.InvalidControlRecord;
        var event_kind: ?domain.EventKind = parseEventKind(alloc, item) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidControlRecord,
        };
        errdefer if (event_kind) |*kind| kind.deinit(alloc);
        const id = try alloc.dupe(u8, id_raw);
        var event = domain.Event{
            .sequence = sequence,
            .revision = revision,
            .id = id,
            .timestamp_ms = timestamp_ms,
            .kind = event_kind.?,
        };
        event_kind = null;
        errdefer event.deinit(alloc);
        try events.append(alloc, event);
    }
    return events.toOwnedSlice(alloc);
}

fn parseEventKind(alloc: Allocator, value: std.json.Value) !domain.EventKind {
    const object = try requireObject(value);
    const kind_raw = try requireString(object, "kind");
    const tag = std.meta.stringToEnum(std.meta.Tag(domain.EventKind), kind_raw) orelse
        return error.InvalidControlRecord;
    return switch (tag) {
        .created => blk: {
            _ = try exactObject(value, &.{ "sequence", "revision", "id", "timestamp_ms", "kind" });
            break :blk .created;
        },
        .configured => blk: {
            _ = try exactObject(value, &.{ "sequence", "revision", "id", "timestamp_ms", "kind" });
            break :blk .configured;
        },
        .message_queued => blk: {
            const exact = try exactObject(value, &.{
                "sequence",
                "revision",
                "id",
                "timestamp_ms",
                "kind",
                "message_id",
            });
            const message_id = try requireString(exact, "message_id");
            domain.validateOperationId(message_id) catch
                return error.InvalidControlRecord;
            break :blk .{ .message_queued = .{
                .message_id = try alloc.dupe(u8, message_id),
            } };
        },
        .relationship_changed => blk: {
            const exact = try exactObject(value, &.{
                "sequence",
                "revision",
                "id",
                "timestamp_ms",
                "kind",
                "previous_parent_id",
                "parent_id",
            });
            const previous_raw = try optionalString(exact, "previous_parent_id");
            const parent_raw = try optionalString(exact, "parent_id");
            if (previous_raw) |id| domain.validateId(id) catch
                return error.InvalidControlRecord;
            if (parent_raw) |id| domain.validateId(id) catch
                return error.InvalidControlRecord;
            const previous = if (previous_raw) |id| try alloc.dupe(u8, id) else null;
            errdefer if (previous) |id| alloc.free(id);
            break :blk .{ .relationship_changed = .{
                .previous_parent_id = previous,
                .parent_id = if (parent_raw) |id| try alloc.dupe(u8, id) else null,
            } };
        },
        .lifecycle_changed => blk: {
            const exact = try exactObject(value, &.{
                "sequence",
                "revision",
                "id",
                "timestamp_ms",
                "kind",
                "previous",
                "current",
            });
            break :blk .{ .lifecycle_changed = .{
                .previous = try parseEnum(domain.State, try requireString(exact, "previous")),
                .current = try parseEnum(domain.State, try requireString(exact, "current")),
            } };
        },
        .work_transition => blk: {
            const exact = try exactObject(value, &.{
                "sequence",
                "revision",
                "id",
                "timestamp_ms",
                "kind",
                "work_item_id",
                "previous",
                "current",
                "reason",
            });
            const work_id = try requireString(exact, "work_item_id");
            domain.validateOperationId(work_id) catch return error.InvalidControlRecord;
            const previous = try parseOptionalEnum(
                domain.QueueStatus,
                exact.get("previous") orelse return error.InvalidControlRecord,
            );
            const current = try parseEnum(
                domain.QueueStatus,
                try requireString(exact, "current"),
            );
            const reason_raw = try optionalString(exact, "reason");
            if (reason_raw) |reason| validateText(
                reason,
                domain.max_cancellation_reason_bytes,
            ) catch return error.InvalidControlRecord;
            const owned_work_id = try alloc.dupe(u8, work_id);
            errdefer alloc.free(owned_work_id);
            break :blk .{ .work_transition = .{
                .work_item_id = owned_work_id,
                .previous = previous,
                .current = current,
                .reason = if (reason_raw) |reason| try alloc.dupe(u8, reason) else null,
            } };
        },
        .milestone_emitted => blk: {
            const exact = try exactObject(value, &.{
                "sequence",
                "revision",
                "id",
                "timestamp_ms",
                "kind",
                "operation_id",
                "source_child_id",
                "target_parent_id",
                "work_item_id",
                "name",
            });
            const operation_raw = try requireString(exact, "operation_id");
            const source_raw = try requireString(exact, "source_child_id");
            const target_raw = try requireString(exact, "target_parent_id");
            const work_raw = try requireString(exact, "work_item_id");
            const name_raw = try requireString(exact, "name");
            domain.validateOperationId(operation_raw) catch return error.InvalidControlRecord;
            domain.validateId(source_raw) catch return error.InvalidControlRecord;
            domain.validateId(target_raw) catch return error.InvalidControlRecord;
            domain.validateOperationId(work_raw) catch return error.InvalidControlRecord;
            validateText(name_raw, domain.max_name_bytes) catch
                return error.InvalidControlRecord;
            const operation_id = try alloc.dupe(u8, operation_raw);
            errdefer alloc.free(operation_id);
            const source_id = try alloc.dupe(u8, source_raw);
            errdefer alloc.free(source_id);
            const target_id = try alloc.dupe(u8, target_raw);
            errdefer alloc.free(target_id);
            const work_id = try alloc.dupe(u8, work_raw);
            errdefer alloc.free(work_id);
            break :blk .{ .milestone_emitted = .{
                .operation_id = operation_id,
                .source_child_id = source_id,
                .target_parent_id = target_id,
                .work_item_id = work_id,
                .name = try alloc.dupe(u8, name_raw),
            } };
        },
    };
}

fn parseOperations(
    alloc: Allocator,
    value: std.json.Value,
    version: u64,
) LoadError![]domain.OperationReceipt {
    if (value != .array) return error.InvalidControlRecord;
    var operations: std.ArrayList(domain.OperationReceipt) = .empty;
    errdefer {
        for (operations.items) |*operation| operation.deinit(alloc);
        operations.deinit(alloc);
    }
    for (value.array.items) |item| {
        const has_identity = version >= process_epoch_schema_version;
        const object = exactObject(item, if (has_identity) &.{
            "id",
            "request_fingerprint",
            "fingerprint",
            "code",
            "target_id",
            "identity_source",
            "identity_epoch",
            "generation",
            "event_sequence",
        } else &.{
            "id",
            "request_fingerprint",
            "fingerprint",
            "code",
            "target_id",
            "generation",
            "event_sequence",
        }) catch return error.InvalidControlRecord;
        const id_raw = requireString(object, "id") catch return error.InvalidControlRecord;
        domain.validateOperationId(id_raw) catch return error.InvalidControlRecord;
        const target_raw = requireString(object, "target_id") catch
            return error.InvalidControlRecord;
        domain.validateId(target_raw) catch return error.InvalidControlRecord;
        const request_fingerprint = try parseFingerprint(object, "request_fingerprint");
        const fingerprint = try parseFingerprint(object, "fingerprint");
        const identity_source = if (has_identity)
            try parseOptionalEnum(
                domain.OperationIdentitySource,
                object.get("identity_source") orelse return error.InvalidControlRecord,
            )
        else
            null;
        const identity_epoch = if (has_identity)
            optionalU64(object, "identity_epoch") catch return error.InvalidControlRecord
        else
            null;
        if ((identity_source == null) != (identity_epoch == null)) {
            return error.InvalidControlRecord;
        }
        for (operations.items) |operation| {
            if (std.mem.eql(u8, operation.id, id_raw) and
                operation.identity_source == identity_source and
                operation.identity_epoch == identity_epoch)
            {
                return error.InvalidControlRecord;
            }
        }
        var operation = try makeOperationReceipt(
            alloc,
            id_raw,
            target_raw,
            request_fingerprint,
            fingerprint,
            parseEnum(
                domain.OutcomeCode,
                requireString(object, "code") catch return error.InvalidControlRecord,
            ) catch return error.InvalidControlRecord,
            requireU64(object, "generation") catch return error.InvalidControlRecord,
            requireU64(object, "event_sequence") catch
                return error.InvalidControlRecord,
            identity_source,
            identity_epoch,
        );
        errdefer operation.deinit(alloc);
        try operations.append(alloc, operation);
    }
    return operations.toOwnedSlice(alloc);
}

fn makeOperationReceipt(
    alloc: Allocator,
    id_source: []const u8,
    target_source: []const u8,
    request_fingerprint: [32]u8,
    fingerprint: [32]u8,
    code: domain.OutcomeCode,
    generation: u64,
    event_sequence: u64,
    identity_source: ?domain.OperationIdentitySource,
    identity_epoch: ?u64,
) !domain.OperationReceipt {
    const id = try alloc.dupe(u8, id_source);
    errdefer alloc.free(id);
    return .{
        .id = id,
        .request_fingerprint = request_fingerprint,
        .fingerprint = fingerprint,
        .code = code,
        .target_id = try alloc.dupe(u8, target_source),
        .generation = generation,
        .event_sequence = event_sequence,
        .identity_source = identity_source,
        .identity_epoch = identity_epoch,
    };
}

fn parseFingerprint(object: std.json.ObjectMap, key: []const u8) ![32]u8 {
    const raw = try requireString(object, key);
    if (raw.len != 64) return error.InvalidControlRecord;
    var fingerprint: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&fingerprint, raw) catch return error.InvalidControlRecord;
    const canonical = std.fmt.bytesToHex(fingerprint, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidControlRecord;
    return fingerprint;
}

fn exactObject(value: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    const object = try requireObject(value);
    if (object.count() != keys.len) return error.InvalidControlRecord;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidControlRecord;
    }
    return object;
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidControlRecord;
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidControlRecord;
    if (value != .string) return error.InvalidControlRecord;
    return value.string;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return error.InvalidControlRecord;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidControlRecord,
    };
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidControlRecord;
    if (value != .bool) return error.InvalidControlRecord;
    return value.bool;
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidControlRecord;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidControlRecord,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidControlRecord,
        else => error.InvalidControlRecord,
    };
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return error.InvalidControlRecord;
    return switch (value) {
        .null => null,
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidControlRecord,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidControlRecord,
        else => error.InvalidControlRecord,
    };
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidControlRecord;
    return switch (value) {
        .integer => |number| number,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch
            error.InvalidControlRecord,
        else => error.InvalidControlRecord,
    };
}

fn parseEnum(comptime T: type, raw: []const u8) !T {
    return std.meta.stringToEnum(T, raw) orelse error.InvalidControlRecord;
}

fn parseOptionalEnum(comptime T: type, value: std.json.Value) !?T {
    return switch (value) {
        .null => null,
        .string => |raw| try parseEnum(T, raw),
        else => error.InvalidControlRecord,
    };
}

fn parseOptionalReasoningEffort(value: std.json.Value) !?types.ReasoningEffort {
    return switch (value) {
        .null => null,
        .string => |raw| types.ReasoningEffort.parse(raw) orelse error.InvalidControlRecord,
        else => error.InvalidControlRecord,
    };
}

fn validateText(text: []const u8, max_bytes: usize) !void {
    if (text.len == 0 or text.len > max_bytes or !std.unicode.utf8ValidateSlice(text)) {
        return error.InvalidControlRecord;
    }
    if (std.mem.findScalar(u8, text, 0) != null) return error.InvalidControlRecord;
}

fn cloneQueue(alloc: Allocator, source: []const domain.QueuedMessage) ![]domain.QueuedMessage {
    const result = try alloc.alloc(domain.QueuedMessage, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*message| message.deinit(alloc);
        alloc.free(result);
    }
    for (source) |message| {
        result[initialized] = try message.clone(alloc);
        initialized += 1;
    }
    return result;
}

fn cloneEvents(alloc: Allocator, source: []const domain.Event) ![]domain.Event {
    const result = try alloc.alloc(domain.Event, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*event| event.deinit(alloc);
        alloc.free(result);
    }
    for (source) |event| {
        result[initialized] = try event.clone(alloc);
        initialized += 1;
    }
    return result;
}

fn cloneOperations(
    alloc: Allocator,
    source: []const domain.OperationReceipt,
) ![]domain.OperationReceipt {
    const result = try alloc.alloc(domain.OperationReceipt, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*operation| operation.deinit(alloc);
        alloc.free(result);
    }
    for (source) |operation| {
        result[initialized] = try operation.clone(alloc);
        initialized += 1;
    }
    return result;
}

fn freeQueue(alloc: Allocator, messages: []domain.QueuedMessage) void {
    for (messages) |*message| message.deinit(alloc);
    alloc.free(messages);
}

fn freeEvents(alloc: Allocator, events: []domain.Event) void {
    for (events) |*event| event.deinit(alloc);
    alloc.free(events);
}

fn freeOperations(alloc: Allocator, operations: []domain.OperationReceipt) void {
    for (operations) |*operation| operation.deinit(alloc);
    alloc.free(operations);
}

fn testRecord(alloc: Allocator) !Record {
    var notifications = try domain.validateNotificationPolicy(alloc, .{
        .milestones = &.{"halfway"},
        .report_interval_ms = 1000,
        .report_duration_ms = 5000,
        .stop_conditions = &.{ .terminal, .duration_elapsed },
    });
    errdefer notifications.deinit(alloc);
    const child_id = try alloc.dupe(u8, "child-id");
    errdefer alloc.free(child_id);
    const parent_id = try alloc.dupe(u8, "parent-id");
    errdefer alloc.free(parent_id);
    const name = try alloc.dupe(u8, "research");
    errdefer alloc.free(name);
    const queue = try alloc.alloc(domain.QueuedMessage, 0);
    errdefer alloc.free(queue);
    const events = try alloc.alloc(domain.Event, 0);
    errdefer alloc.free(events);
    const operations = try alloc.alloc(domain.OperationReceipt, 0);
    return .{
        .child_id = child_id,
        .generation = 0,
        .parent_id = parent_id,
        .mode = .persistent,
        .configuration = .{
            .name = name,
            .model = null,
            .effort = types.ReasoningEffort.literal("future-tier"),
            .notifications = notifications,
        },
        .state = .idle,
        .queue = queue,
        .events = events,
        .operations = operations,
        .next_event_sequence = 1,
        .notification_cursor = 0,
        .created_at_ms = 1,
        .updated_at_ms = 2,
    };
}











fn testBorrowedMessage(
    id: []const u8,
    status: domain.QueueStatus,
    reason: ?[]const u8,
) domain.QueuedMessage {
    return .{
        .id = @constCast(id),
        .source_id = @constCast("parent-id"),
        .content = @constCast("work"),
        .status = status,
        .cancellation_reason = if (reason) |value| @constCast(value) else null,
        .created_at_ms = 1,
    };
}

fn testBorrowedWorkEvent(
    sequence: u64,
    revision: u64,
    id: []const u8,
    previous: ?domain.QueueStatus,
    current: domain.QueueStatus,
    reason: ?[]const u8,
) domain.Event {
    return .{
        .sequence = sequence,
        .revision = revision,
        .id = @constCast(id),
        .timestamp_ms = 1,
        .kind = .{ .work_transition = .{
            .work_item_id = @constCast(id),
            .previous = previous,
            .current = current,
            .reason = if (reason) |value| @constCast(value) else null,
        } },
    };
}

fn expectInvalidExecutionState(
    mode: domain.Mode,
    state: domain.State,
    archived_from: ?domain.State,
    queue: []const domain.QueuedMessage,
    events: []const domain.Event,
    generation: u64,
) !void {
    try std.testing.expectError(
        error.InvalidControlRecord,
        validateRecordSemantics(
            "child-id",
            generation,
            mode,
            state,
            archived_from,
            queue,
            events,
            &.{},
            std.math.cast(u64, events.len + 1).?,
            0,
            0,
            false,
            false,
            0,
            0,
            0,
            0,
            .manager,
        ),
    );
}

fn expectInvalidSequence(
    queue: []const domain.QueuedMessage,
    events: []const domain.Event,
    operations: []const domain.OperationReceipt,
    generation: u64,
    next_event_sequence: u64,
) !void {
    try std.testing.expectError(
        error.InvalidControlRecord,
        validateRecordSemantics(
            "child-id",
            generation,
            .persistent,
            .idle,
            null,
            queue,
            events,
            operations,
            next_event_sequence,
            0,
            0,
            false,
            false,
            0,
            0,
            0,
            0,
            .manager,
        ),
    );
}



fn checkControlCompactionAllocationFailures(alloc: Allocator) !void {
    var record = try testRecord(alloc);
    defer record.deinit(alloc);
    const ids = [_][]const u8{ "work-1", "work-2", "work-3" };
    const queue = try alloc.alloc(domain.QueuedMessage, ids.len);
    var queue_initialized: usize = 0;
    var queue_transferred = false;
    errdefer if (!queue_transferred) {
        for (queue[0..queue_initialized]) |*message| message.deinit(alloc);
        alloc.free(queue);
    };
    for (ids, 0..) |id, index| {
        const owned_id = try alloc.dupe(u8, id);
        errdefer alloc.free(owned_id);
        const source_id = try alloc.dupe(u8, "parent-id");
        errdefer alloc.free(source_id);
        const content = try alloc.alloc(u8, 4096);
        errdefer alloc.free(content);
        @memset(content, @intCast('a' + index));
        queue[index] = .{
            .id = owned_id,
            .source_id = source_id,
            .content = content,
            .status = .completed,
            .created_at_ms = @intCast(index),
        };
        queue_initialized += 1;
    }

    const events = try alloc.alloc(domain.Event, ids.len * 3);
    var events_initialized: usize = 0;
    var events_transferred = false;
    errdefer if (!events_transferred) {
        for (events[0..events_initialized]) |*event| event.deinit(alloc);
        alloc.free(events);
    };
    for (ids) |id| {
        inline for (0..3) |transition_index| {
            const event_id = try alloc.dupe(u8, id);
            errdefer alloc.free(event_id);
            const work_item_id = try alloc.dupe(u8, id);
            errdefer alloc.free(work_item_id);
            const sequence: u64 = @intCast(events_initialized + 1);
            events[events_initialized] = .{
                .sequence = sequence,
                .revision = sequence,
                .id = event_id,
                .timestamp_ms = @intCast(sequence),
                .kind = .{ .work_transition = .{
                    .work_item_id = work_item_id,
                    .previous = switch (transition_index) {
                        0 => null,
                        1 => .pending,
                        2 => .running,
                        else => unreachable,
                    },
                    .current = switch (transition_index) {
                        0 => .pending,
                        1 => .running,
                        2 => .completed,
                        else => unreachable,
                    },
                    .reason = null,
                } },
            };
            events_initialized += 1;
        }
    }
    alloc.free(record.queue);
    record.queue = queue;
    queue_transferred = true;
    alloc.free(record.events);
    record.events = events;
    events_transferred = true;
    record.generation = events.len;
    record.next_event_sequence = events.len + 1;
    record.updated_at_ms = @intCast(events.len);
    try validateRecordSemanticsForRecord(record);

    const raw = renderRecord(alloc, record) catch return error.OutOfMemory;
    defer alloc.free(raw);
    var retained = try record.clone(alloc);
    defer retained.deinit(alloc);
    try prepareForSaveLimit(alloc, &retained, raw.len - 1);
    try validateRecordSemanticsForRecord(retained);
    try std.testing.expectEqual(@as(usize, 1), retained.queue.len);
    try std.testing.expectEqualStrings("work-3", retained.queue[0].id);
}



fn fuzzControlRecord(_: void, smith: *std.testing.Smith) !void {
    var buffer: [8192]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var record = parseRecord(std.testing.allocator, buffer[0..len]) catch return;
    record.deinit(std.testing.allocator);
}
