const std = @import("std");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session_child_store = @import("../session/session_child_store.zig");
const types = @import("../shared/types.zig");
const communication = @import("communication.zig");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;
const schema_version: u64 = 6;
const base64_delivery_schema_version: u64 = 5;
const previous_capacity_schema_version: u64 = 4;
const pre_capacity_schema_version: u64 = 3;
const process_epoch_schema_version: u64 = 2;
const legacy_schema_version: u64 = 1;
pub const max_record_bytes: usize = 512 * 1024;
pub const mutation_reserve_bytes: usize = 64 * 1024;
pub const max_canonical_record_bytes: usize =
    max_record_bytes - mutation_reserve_bytes;
pub const metadata_budget_bytes: usize = 32 * 1024;
pub const retained_delivery_budget_bytes: usize =
    communication.max_retained_delivery_canonical_bytes;
pub const subsequent_mutation_budget_bytes: usize =
    communication.max_retained_delivery_canonical_bytes;
const record_file = "communication.json";
const lock_file = "subagent-control.lock";
const lock_deadline_ms: u64 = 2000;

const WireRecord = struct {
    schema_version: u64,
    ledger: communication.Ledger,
};

const WireMessageV5 = struct {
    encoding: []u8,
    data: []u8,
};

const WireDeliveryPayloadV5 = union(communication.DeliveryKind) {
    message: WireMessageV5,
    milestone: []u8,
    terminal: domain.State,
    interval: struct {
        state: domain.State,
        coalesced_ticks: u32,
    },
    approval: []u8,
    tool_activity: communication.ToolActivity,
};

const WireDeliveryV5 = struct {
    sequence: u64,
    revision: u64,
    id: []u8,
    source_id: []u8,
    target_id: []u8,
    work_id: ?[]u8 = null,
    operation_id: ?[]u8 = null,
    timestamp_ms: i64,
    payload: WireDeliveryPayloadV5,
};

const WireLedgerV5 = struct {
    session_id: []u8,
    capacity_version: u64 = 0,
    generation: u64 = 0,
    next_sequence: u64 = 1,
    deliveries: []WireDeliveryV5,
    cursors: []communication.ConsumerCursor,
    retention_targets: ?[]communication.RetentionTarget = null,
    work_notifications: []communication.WorkNotification,
    approvals: []communication.Approval,
    parent_turn_evicted_through: u64 = 0,
    authority_generation: u64 = 0,
    authority_grants: []types.PermissionGrant,
    legacy_operation_replay_closed: bool = false,
    model_replay_floor: u64 = 0,
    human_replay_floor: u64 = 0,
    model_epoch_high: u64 = 0,
    human_epoch_high: u64 = 0,
};

const WireRecordV5 = struct {
    schema_version: u64,
    ledger: WireLedgerV5,
};

const WirePermissionGrantV6 = struct {
    tool_name: []u8,
    target_path: WireMessageV5,
};

const WireApprovalV6 = struct {
    id: []u8,
    kind: communication.ApprovalKind,
    child_id: []u8,
    root_id: []u8,
    work_id: ?[]u8,
    relationship: ?communication.RelationshipApproval = null,
    prepared_fingerprint: [32]u8,
    identity_fingerprint: [32]u8,
    label: []u8,
    explanation: ?[]u8,
    command: ?WireMessageV5 = null,
    file: ?permission_request.FileApprovalRequest = null,
    grants: []WirePermissionGrantV6,
    status: communication.ApprovalStatus,
    created_at_ms: i64,
    resolved_at_ms: ?i64 = null,
    resolved_revision: ?u64 = null,
};

const WireLedgerV6 = struct {
    session_id: []u8,
    capacity_version: u64 = 0,
    generation: u64 = 0,
    next_sequence: u64 = 1,
    deliveries: []WireDeliveryV5,
    cursors: []communication.ConsumerCursor,
    retention_targets: ?[]communication.RetentionTarget = null,
    work_notifications: []communication.WorkNotification,
    approvals: []WireApprovalV6,
    parent_turn_evicted_through: u64 = 0,
    authority_generation: u64 = 0,
    authority_grants: []WirePermissionGrantV6,
    legacy_operation_replay_closed: bool = false,
    model_replay_floor: u64 = 0,
    human_replay_floor: u64 = 0,
    model_epoch_high: u64 = 0,
    human_epoch_high: u64 = 0,
};

const WireRecordV6 = struct {
    schema_version: u64,
    ledger: WireLedgerV6,
};

const DecodedWireText = struct {
    value: []u8,
    encoding: enum { plain, base64 },

    pub fn jsonParse(
        alloc: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !DecodedWireText {
        return switch (try source.peekNextTokenType()) {
            .string => .{
                .value = try std.json.innerParse([]u8, alloc, source, options),
                .encoding = .plain,
            },
            .object_begin => blk: {
                const message = try std.json.innerParse(
                    WireMessageV5,
                    alloc,
                    source,
                    options,
                );
                if (!std.mem.eql(u8, message.encoding, "base64")) {
                    return error.UnexpectedToken;
                }
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(
                    message.data,
                ) catch return error.UnexpectedToken;
                const decoded = try alloc.alloc(u8, decoded_len);
                std.base64.standard.Decoder.decode(decoded, message.data) catch
                    return error.UnexpectedToken;
                const canonical = try alloc.alloc(
                    u8,
                    std.base64.standard.Encoder.calcSize(decoded.len),
                );
                defer alloc.free(canonical);
                const encoded = std.base64.standard.Encoder.encode(canonical, decoded);
                if (!std.mem.eql(u8, encoded, message.data)) {
                    return error.UnexpectedToken;
                }
                break :blk .{ .value = decoded, .encoding = .base64 };
            },
            else => error.UnexpectedToken,
        };
    }
};

const DecodedWirePermissionGrant = struct {
    tool_name: []u8,
    target_path: DecodedWireText,
};

const DecodedWireDeliveryPayload = union(communication.DeliveryKind) {
    message: DecodedWireText,
    milestone: []u8,
    terminal: domain.State,
    interval: struct {
        state: domain.State,
        coalesced_ticks: u32,
    },
    approval: []u8,
    tool_activity: communication.ToolActivity,
};

const DecodedWireDelivery = struct {
    sequence: u64,
    revision: u64,
    id: []u8,
    source_id: []u8,
    target_id: []u8,
    work_id: ?[]u8 = null,
    operation_id: ?[]u8 = null,
    timestamp_ms: i64,
    payload: DecodedWireDeliveryPayload,
};

const DecodedWireApproval = struct {
    id: []u8,
    kind: communication.ApprovalKind,
    child_id: []u8,
    root_id: []u8,
    work_id: ?[]u8,
    relationship: ?communication.RelationshipApproval = null,
    prepared_fingerprint: [32]u8,
    identity_fingerprint: ?[32]u8 = null,
    label: []u8,
    explanation: ?[]u8,
    command: ?DecodedWireText = null,
    file: ?permission_request.FileApprovalRequest = null,
    grants: []DecodedWirePermissionGrant,
    status: communication.ApprovalStatus,
    created_at_ms: i64,
    resolved_at_ms: ?i64 = null,
    resolved_revision: ?u64 = null,
};

const DecodedWireLedger = struct {
    session_id: []u8,
    capacity_version: u64 = 0,
    generation: u64 = 0,
    next_sequence: u64 = 1,
    deliveries: []DecodedWireDelivery,
    cursors: []communication.ConsumerCursor,
    retention_targets: ?[]communication.RetentionTarget = null,
    work_notifications: []communication.WorkNotification,
    approvals: []DecodedWireApproval,
    parent_turn_evicted_through: u64 = 0,
    authority_generation: u64 = 0,
    authority_grants: []DecodedWirePermissionGrant,
    legacy_operation_replay_closed: bool = false,
    model_replay_floor: u64 = 0,
    human_replay_floor: u64 = 0,
    model_epoch_high: u64 = 0,
    human_epoch_high: u64 = 0,
};

const DecodedWireRecord = struct {
    schema_version: u64,
    ledger: DecodedWireLedger,
};

comptime {
    // 224 KiB live state + 32 KiB metadata + one retained and one subsequent
    // 96 KiB delivery fit below 448 KiB, leaving 64 KiB below the file cap.
    if (communication.max_irreducible_canonical_bytes +
        metadata_budget_bytes +
        retained_delivery_budget_bytes +
        subsequent_mutation_budget_bytes >
        max_canonical_record_bytes)
    {
        @compileError("communication capacity budgets exceed the canonical record envelope");
    }
}

pub const LoadError = error{
    OutOfMemory,
    CommunicationNotFound,
    InvalidCommunicationRecord,
    UnsupportedCommunicationSchema,
    CommunicationRecordTooLarge,
    CommunicationPathUnsafe,
    PrivateStatePermissionsUnsupported,
    CommunicationStoreFailed,
};

pub const SaveError = error{
    OutOfMemory,
    CommunicationIdentityMismatch,
    InvalidCommunicationRecord,
    CommunicationCapacityExceeded,
    CommunicationRecordTooLarge,
    CommunicationPathUnsafe,
    PrivateStatePermissionsUnsupported,
    CommunicationCommitIndeterminate,
    CommunicationStoreFailed,
};

pub const LockError = error{
    OutOfMemory,
    CommunicationLockBusy,
    CommunicationLockUnsupported,
    CommunicationPathUnsafe,
    PrivateStatePermissionsUnsupported,
    CommunicationStoreFailed,
};

pub const Store = struct {
    capability: *session_child_store.SessionChildCapability,
    expected_session_id: []const u8,

    pub fn acquireLock(self: Store) LockError!io_mod.TimedAdvisoryLock {
        return self.capability.acquireTimedAdvisoryLock(
            .subagent_control,
            lock_file,
            lock_deadline_ms,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LockBusy => error.CommunicationLockBusy,
            error.LockUnsupported => error.CommunicationLockUnsupported,
            error.SessionPathUnsafe => error.CommunicationPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.CommunicationStoreFailed,
        };
    }

    /// Returns an owned ledger, or null when no communication record exists.
    pub fn loadOptional(self: Store, alloc: Allocator) LoadError!?communication.Ledger {
        var file = self.capability.openFileReadOnly(
            alloc,
            .subagent_control,
            record_file,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.CommunicationPathUnsafe,
            error.PrivateStatePermissionsUnsupported => return error.PrivateStatePermissionsUnsupported,
            else => return error.CommunicationStoreFailed,
        };
        defer file.deinit();
        const bytes = file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.CommunicationRecordTooLarge,
            else => return error.CommunicationStoreFailed,
        };
        defer alloc.free(bytes);
        var ledger = try decode(alloc, bytes);
        errdefer ledger.deinit(alloc);
        if (!std.mem.eql(u8, ledger.session_id, self.expected_session_id)) {
            return error.InvalidCommunicationRecord;
        }
        return ledger;
    }

    /// Returns an owned ledger; caller frees it with `Ledger.deinit`.
    pub fn load(self: Store, alloc: Allocator) LoadError!communication.Ledger {
        return (try self.loadOptional(alloc)) orelse error.CommunicationNotFound;
    }

    pub fn save(self: Store, alloc: Allocator, ledger: communication.Ledger) SaveError!void {
        if (!std.mem.eql(u8, ledger.session_id, self.expected_session_id)) {
            return error.CommunicationIdentityMismatch;
        }
        communication.validateLedger(ledger) catch
            return error.InvalidCommunicationRecord;
        const bytes = encode(alloc, ledger) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CommunicationCapacityExceeded => error.CommunicationCapacityExceeded,
            error.CommunicationRecordTooLarge => error.CommunicationRecordTooLarge,
        };
        defer alloc.free(bytes);
        var entry = self.capability.atomicReplace(
            alloc,
            .subagent_control,
            record_file,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.CommunicationPathUnsafe,
            error.PrivateStatePermissionsUnsupported => return error.PrivateStatePermissionsUnsupported,
            error.SessionChildCommitIndeterminate => return error.CommunicationCommitIndeterminate,
            else => return error.CommunicationStoreFailed,
        };
        entry.deinit(alloc);
    }
};

const EncodeError = error{
    OutOfMemory,
    CommunicationCapacityExceeded,
    CommunicationRecordTooLarge,
};

fn encode(alloc: Allocator, ledger: communication.Ledger) EncodeError![]u8 {
    return encodeLimit(alloc, ledger, max_record_bytes);
}

fn encodeLimit(
    alloc: Allocator,
    ledger: communication.Ledger,
    byte_limit: usize,
) EncodeError![]u8 {
    var retained = ledger.clone(alloc) catch return error.OutOfMemory;
    defer retained.deinit(alloc);
    communication.compactStoppedWorkNotifications(alloc, &retained) catch
        return error.OutOfMemory;
    var approvals_compacted = false;
    while (true) {
        if (retained.capacity_version == 0 and
            communication.capacityContractSatisfied(retained))
        {
            retained.capacity_version = communication.capacity_contract_version;
            const migrated = try encodeCanonical(alloc, retained);
            if (migrated.len <= @min(byte_limit, max_canonical_record_bytes)) {
                return migrated;
            }
            alloc.free(migrated);
            retained.capacity_version = 0;
        }
        const capacity_bound =
            retained.capacity_version == communication.capacity_contract_version;
        const canonical_limit = if (capacity_bound)
            @min(byte_limit, max_canonical_record_bytes)
        else
            byte_limit;
        const bytes = try encodeCanonical(alloc, retained);
        if (bytes.len <= canonical_limit) return bytes;
        alloc.free(bytes);
        if (!approvals_compacted) {
            approvals_compacted = true;
            if (try communication.compactResolvedApprovals(alloc, &retained)) {
                continue;
            }
        }
        if (retained.deliveries.len <= 1) {
            return if (capacity_bound)
                error.CommunicationCapacityExceeded
            else
                error.CommunicationRecordTooLarge;
        }
        _ = communication.evictOldestDelivery(alloc, &retained) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CapacityExceeded => error.CommunicationCapacityExceeded,
            else => error.CommunicationRecordTooLarge,
        };
    }
}

fn encodeCanonical(alloc: Allocator, ledger: communication.Ledger) error{OutOfMemory}![]u8 {
    return encodeWireCanonical(
        alloc,
        if (ledger.capacity_version == communication.capacity_contract_version)
            schema_version
        else
            pre_capacity_schema_version,
        ledger,
    );
}

fn encodeWireCanonical(
    alloc: Allocator,
    version: u64,
    ledger: communication.Ledger,
) error{OutOfMemory}![]u8 {
    if (version == schema_version) {
        return encodeWireCanonicalV6(alloc, ledger);
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(WireRecord{
        .schema_version = version,
        .ledger = ledger,
    }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn encodeWireCanonicalV6(
    alloc: Allocator,
    ledger: communication.Ledger,
) error{OutOfMemory}![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deliveries = try arena.alloc(WireDeliveryV5, ledger.deliveries.len);
    for (ledger.deliveries, deliveries) |delivery, *wire| {
        wire.* = .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .id = delivery.id,
            .source_id = delivery.source_id,
            .target_id = delivery.target_id,
            .work_id = delivery.work_id,
            .operation_id = delivery.operation_id,
            .timestamp_ms = delivery.timestamp_ms,
            .payload = switch (delivery.payload) {
                .message => |content| .{ .message = try encodeWireTextV6(
                    arena,
                    content,
                ) },
                .milestone => |value| .{ .milestone = value },
                .terminal => |value| .{ .terminal = value },
                .interval => |value| .{ .interval = .{
                    .state = value.state,
                    .coalesced_ticks = value.coalesced_ticks,
                } },
                .approval => |value| .{ .approval = value },
                .tool_activity => |value| .{ .tool_activity = value },
            },
        };
    }
    const approvals = try arena.alloc(WireApprovalV6, ledger.approvals.len);
    for (ledger.approvals, approvals) |approval, *wire| {
        wire.* = .{
            .id = approval.id,
            .kind = approval.kind,
            .child_id = approval.child_id,
            .root_id = approval.root_id,
            .work_id = approval.work_id,
            .relationship = approval.relationship,
            .prepared_fingerprint = approval.prepared_fingerprint,
            .identity_fingerprint = approval.identity_fingerprint,
            .label = approval.label,
            .explanation = approval.explanation,
            .command = if (approval.command) |command|
                try encodeWireTextV6(arena, command)
            else
                null,
            .file = approval.file,
            .grants = try encodeWireGrantsV6(arena, approval.grants),
            .status = approval.status,
            .created_at_ms = approval.created_at_ms,
            .resolved_at_ms = approval.resolved_at_ms,
            .resolved_revision = approval.resolved_revision,
        };
    }
    const authority_grants = try encodeWireGrantsV6(
        arena,
        ledger.authority_grants,
    );
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(WireRecordV6{
        .schema_version = schema_version,
        .ledger = .{
            .session_id = ledger.session_id,
            .capacity_version = ledger.capacity_version,
            .generation = ledger.generation,
            .next_sequence = ledger.next_sequence,
            .deliveries = deliveries,
            .cursors = ledger.cursors,
            .retention_targets = ledger.retention_targets,
            .work_notifications = ledger.work_notifications,
            .approvals = approvals,
            .parent_turn_evicted_through = ledger.parent_turn_evicted_through,
            .authority_generation = ledger.authority_generation,
            .authority_grants = authority_grants,
            .legacy_operation_replay_closed = ledger.legacy_operation_replay_closed,
            .model_replay_floor = ledger.model_replay_floor,
            .human_replay_floor = ledger.human_replay_floor,
            .model_epoch_high = ledger.model_epoch_high,
            .human_epoch_high = ledger.human_epoch_high,
        },
    }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn encodeWireGrantsV6(
    arena: Allocator,
    grants: []const types.PermissionGrant,
) error{OutOfMemory}![]WirePermissionGrantV6 {
    const encoded = try arena.alloc(WirePermissionGrantV6, grants.len);
    for (grants, encoded) |grant, *wire| {
        wire.* = .{
            .tool_name = grant.tool_name,
            .target_path = try encodeWireTextV6(arena, grant.target_path),
        };
    }
    return encoded;
}

fn encodeWireTextV6(
    arena: Allocator,
    content: []const u8,
) error{OutOfMemory}!WireMessageV5 {
    const encoded = try arena.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(content.len),
    );
    _ = std.base64.standard.Encoder.encode(encoded, content);
    return .{
        .encoding = @constCast("base64"),
        .data = encoded,
    };
}

fn encodeWireCanonicalV5(
    alloc: Allocator,
    ledger: communication.Ledger,
) error{OutOfMemory}![]u8 {
    const deliveries = try alloc.alloc(WireDeliveryV5, ledger.deliveries.len);
    defer alloc.free(deliveries);
    var encoded_messages: std.ArrayList([]u8) = .empty;
    defer {
        for (encoded_messages.items) |message| alloc.free(message);
        encoded_messages.deinit(alloc);
    }
    for (ledger.deliveries, 0..) |delivery, index| {
        deliveries[index] = .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .id = delivery.id,
            .source_id = delivery.source_id,
            .target_id = delivery.target_id,
            .work_id = delivery.work_id,
            .operation_id = delivery.operation_id,
            .timestamp_ms = delivery.timestamp_ms,
            .payload = switch (delivery.payload) {
                .message => |content| blk: {
                    const encoded = try alloc.alloc(
                        u8,
                        std.base64.standard.Encoder.calcSize(content.len),
                    );
                    errdefer alloc.free(encoded);
                    _ = std.base64.standard.Encoder.encode(
                        encoded,
                        content,
                    );
                    try encoded_messages.append(alloc, encoded);
                    break :blk .{ .message = .{
                        .encoding = @constCast("base64"),
                        .data = encoded,
                    } };
                },
                .milestone => |value| .{ .milestone = value },
                .terminal => |value| .{ .terminal = value },
                .interval => |value| .{ .interval = .{
                    .state = value.state,
                    .coalesced_ticks = value.coalesced_ticks,
                } },
                .approval => |value| .{ .approval = value },
                .tool_activity => |value| .{ .tool_activity = value },
            },
        };
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(WireRecordV5{
        .schema_version = base64_delivery_schema_version,
        .ledger = .{
            .session_id = ledger.session_id,
            .capacity_version = ledger.capacity_version,
            .generation = ledger.generation,
            .next_sequence = ledger.next_sequence,
            .deliveries = deliveries,
            .cursors = ledger.cursors,
            .retention_targets = ledger.retention_targets,
            .work_notifications = ledger.work_notifications,
            .approvals = ledger.approvals,
            .parent_turn_evicted_through = ledger.parent_turn_evicted_through,
            .authority_generation = ledger.authority_generation,
            .authority_grants = ledger.authority_grants,
            .legacy_operation_replay_closed = ledger.legacy_operation_replay_closed,
            .model_replay_floor = ledger.model_replay_floor,
            .human_replay_floor = ledger.human_replay_floor,
            .model_epoch_high = ledger.model_epoch_high,
            .human_epoch_high = ledger.human_epoch_high,
        },
    }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn decode(alloc: Allocator, bytes: []const u8) LoadError!communication.Ledger {
    if (bytes.len > max_record_bytes) return error.CommunicationRecordTooLarge;
    var parsed = std.json.parseFromSlice(DecodedWireRecord, alloc, bytes, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (try hasUnsupportedSchemaVersion(alloc, bytes)) {
                return error.UnsupportedCommunicationSchema;
            }
            return error.InvalidCommunicationRecord;
        },
    };
    defer parsed.deinit();
    const version = parsed.value.schema_version;
    if (version != schema_version and
        version != base64_delivery_schema_version and
        version != previous_capacity_schema_version and
        version != pre_capacity_schema_version and
        version != process_epoch_schema_version and version != legacy_schema_version)
    {
        return error.UnsupportedCommunicationSchema;
    }
    if (version >= base64_delivery_schema_version and
        parsed.value.ledger.capacity_version !=
            communication.capacity_contract_version)
    {
        return error.InvalidCommunicationRecord;
    }
    const deliveries = try decodeWireDeliveries(
        alloc,
        parsed.value.ledger.deliveries,
        version >= base64_delivery_schema_version,
    );
    defer alloc.free(deliveries);
    const encoded_private_text = version == schema_version;
    const approvals = try decodeApprovalsV5V6(
        alloc,
        parsed.value.ledger.approvals,
        encoded_private_text,
    );
    defer freeBorrowedApprovalsV5V6(alloc, approvals);
    const authority_grants = try decodeWireGrantsV5V6(
        alloc,
        parsed.value.ledger.authority_grants,
        encoded_private_text,
    );
    defer alloc.free(authority_grants);
    const wire = parsed.value.ledger;
    var borrowed = communication.Ledger{
        .session_id = wire.session_id,
        .capacity_version = if (version == schema_version)
            wire.capacity_version
        else
            0,
        .generation = wire.generation,
        .next_sequence = wire.next_sequence,
        .deliveries = deliveries,
        .cursors = wire.cursors,
        .retention_targets = wire.retention_targets,
        .work_notifications = wire.work_notifications,
        .approvals = approvals,
        .parent_turn_evicted_through = wire.parent_turn_evicted_through,
        .authority_generation = wire.authority_generation,
        .authority_grants = authority_grants,
        .legacy_operation_replay_closed = wire.legacy_operation_replay_closed,
        .model_replay_floor = wire.model_replay_floor,
        .human_replay_floor = wire.human_replay_floor,
        .model_epoch_high = wire.model_epoch_high,
        .human_epoch_high = wire.human_epoch_high,
    };
    if (version == process_epoch_schema_version or
        version == legacy_schema_version)
    {
        borrowed.legacy_operation_replay_closed = true;
        borrowed.model_replay_floor = 0;
        borrowed.human_replay_floor = 0;
        borrowed.model_epoch_high = 0;
        borrowed.human_epoch_high = 0;
    }
    if (version == legacy_schema_version) {
        for (borrowed.approvals) |*approval| {
            if (approval.status != .pending and approval.resolved_revision == null) {
                approval.resolved_revision = borrowed.generation;
            }
        }
    }
    communication.validateLedger(borrowed) catch return error.InvalidCommunicationRecord;
    if (version == schema_version) {
        const canonical_bytes = canonicalWireByteCount(
            alloc,
            schema_version,
            borrowed,
        ) catch return error.OutOfMemory;
        if (canonical_bytes > max_canonical_record_bytes) {
            return error.InvalidCommunicationRecord;
        }
    } else if (communication.capacityContractSatisfied(borrowed)) {
        borrowed.capacity_version = communication.capacity_contract_version;
        const canonical_bytes = canonicalWireByteCount(
            alloc,
            schema_version,
            borrowed,
        ) catch return error.OutOfMemory;
        if (canonical_bytes > max_canonical_record_bytes) {
            borrowed.capacity_version = 0;
        }
    }
    return borrowed.clone(alloc) catch return error.OutOfMemory;
}

fn hasUnsupportedSchemaVersion(alloc: Allocator, bytes: []const u8) error{OutOfMemory}!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const value = parsed.value.object.get("schema_version") orelse return false;
    if (value != .integer or value.integer < 0) return false;
    const version = std.math.cast(u64, value.integer) orelse return false;
    return version != schema_version and
        version != base64_delivery_schema_version and
        version != previous_capacity_schema_version and
        version != pre_capacity_schema_version and
        version != process_epoch_schema_version and
        version != legacy_schema_version;
}

fn decodeApprovalsV5V6(
    alloc: Allocator,
    approvals: []const DecodedWireApproval,
    encoded_private_text: bool,
) LoadError![]communication.Approval {
    const decoded = try alloc.alloc(communication.Approval, approvals.len);
    var built: usize = 0;
    errdefer {
        for (decoded[0..built]) |approval| {
            alloc.free(approval.grants);
        }
        alloc.free(decoded);
    }
    for (approvals) |approval| {
        if (approval.command) |command| {
            if ((command.encoding == .base64) != encoded_private_text) {
                return error.InvalidCommunicationRecord;
            }
        }
        const identity_fingerprint = approval.identity_fingerprint orelse
            if (encoded_private_text)
                return error.InvalidCommunicationRecord
            else
                [_]u8{0} ** 32;
        const grants = try decodeWireGrantsV5V6(
            alloc,
            approval.grants,
            encoded_private_text,
        );
        decoded[built] = .{
            .id = approval.id,
            .kind = approval.kind,
            .child_id = approval.child_id,
            .root_id = approval.root_id,
            .work_id = approval.work_id,
            .relationship = approval.relationship,
            .prepared_fingerprint = approval.prepared_fingerprint,
            .identity_fingerprint = identity_fingerprint,
            .label = approval.label,
            .explanation = approval.explanation,
            .command = if (approval.command) |command| command.value else null,
            .file = approval.file,
            .grants = grants,
            .status = approval.status,
            .created_at_ms = approval.created_at_ms,
            .resolved_at_ms = approval.resolved_at_ms,
            .resolved_revision = approval.resolved_revision,
        };
        built += 1;
    }
    return decoded;
}

fn decodeWireGrantsV5V6(
    alloc: Allocator,
    grants: []const DecodedWirePermissionGrant,
    encoded_private_text: bool,
) LoadError![]types.PermissionGrant {
    const decoded = try alloc.alloc(types.PermissionGrant, grants.len);
    errdefer alloc.free(decoded);
    for (grants, decoded) |grant, *output| {
        if ((grant.target_path.encoding == .base64) != encoded_private_text) {
            return error.InvalidCommunicationRecord;
        }
        output.* = .{
            .tool_name = grant.tool_name,
            .target_path = grant.target_path.value,
        };
    }
    return decoded;
}

fn freeBorrowedApprovalsV5V6(
    alloc: Allocator,
    approvals: []communication.Approval,
) void {
    for (approvals) |approval| {
        alloc.free(approval.grants);
    }
    alloc.free(approvals);
}

fn decodeWireDeliveries(
    alloc: Allocator,
    deliveries: []const DecodedWireDelivery,
    encoded_message_text: bool,
) LoadError![]communication.Delivery {
    const decoded = try alloc.alloc(communication.Delivery, deliveries.len);
    errdefer alloc.free(decoded);
    for (deliveries, decoded) |delivery, *output| {
        if (delivery.payload == .message and
            (delivery.payload.message.encoding == .base64) != encoded_message_text)
        {
            return error.InvalidCommunicationRecord;
        }
        output.* = .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .id = delivery.id,
            .source_id = delivery.source_id,
            .target_id = delivery.target_id,
            .work_id = delivery.work_id,
            .operation_id = delivery.operation_id,
            .timestamp_ms = delivery.timestamp_ms,
            .payload = switch (delivery.payload) {
                .message => |message| .{ .message = message.value },
                .milestone => |value| .{ .milestone = value },
                .terminal => |value| .{ .terminal = value },
                .interval => |value| .{ .interval = .{
                    .state = value.state,
                    .coalesced_ticks = value.coalesced_ticks,
                } },
                .approval => |value| .{ .approval = value },
                .tool_activity => |value| .{ .tool_activity = value },
            },
        };
    }
    return decoded;
}

fn canonicalWireByteCount(
    alloc: Allocator,
    version: u64,
    ledger: communication.Ledger,
) error{OutOfMemory}!usize {
    const bytes = try encodeWireCanonical(alloc, version, ledger);
    defer alloc.free(bytes);
    return bytes.len;
}

fn checkCommunicationCodecAllocationFailures(alloc: Allocator) !void {
    var ledger = try communication.Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    _ = try communication.appendDelivery(alloc, &ledger, .{
        .id = "delivery",
        .source_id = "child",
        .target_id = "parent",
        .timestamp_ms = 1,
        .payload = .{ .message = "hello" },
    });
    const bytes = try encode(alloc, ledger);
    defer alloc.free(bytes);
    var restored = try decode(alloc, bytes);
    defer restored.deinit(alloc);
}
