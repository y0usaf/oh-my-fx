const std = @import("std");
const permission_request = @import("../permissions/permission_request.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const types = @import("../shared/types.zig");
const domain = @import("domain.zig");
const tool_result = @import("tool_result.zig");

const Allocator = std.mem.Allocator;

pub const max_deliveries: usize = 256;
pub const max_consumers: usize = 16;
pub const max_retention_targets: usize = max_deliveries;
pub const max_approvals: usize = 64;
pub const max_active_work_notifications: usize = 8;
pub const max_active_work_notification_bytes: usize = 48 * 1024;
pub const max_live_approvals: usize = max_approvals;
pub const max_authority_grants: usize = domain.max_admission_items;
pub const max_consumer_cursor_bytes: usize = 16 * 1024;
pub const max_retention_target_bytes: usize = 64 * 1024;
pub const max_retained_delivery_canonical_bytes: usize = 96 * 1024;
pub const capacity_contract_version: u64 = 2;
pub const max_delivery_content_bytes: usize = domain.max_message_bytes;
pub const max_approval_projection_bytes: usize = domain.max_message_bytes +
    2 * std.Io.Dir.max_path_bytes + 1024;
pub const max_live_approval_bytes: usize = 192 * 1024;
pub const max_authority_grant_bytes: usize = 128 * 1024;
pub const max_irreducible_canonical_bytes: usize = 224 * 1024;
pub const max_trusted_context_bytes: usize = 16 * 1024;
pub const max_delivery_page: usize = domain.max_page_limit;

pub const DeliveryKind = enum {
    message,
    milestone,
    terminal,
    interval,
    approval,
    tool_activity,
};

pub const Projection = enum {
    human,
    parent_turn,
};

pub const ToolActivityPhase = enum {
    started,
    succeeded,
    failed,
    denied,
};

pub const ToolActivity = struct {
    tool_name: []u8,
    phase: ToolActivityPhase,
};

pub const DeliveryPayload = union(DeliveryKind) {
    message: []u8,
    milestone: []u8,
    terminal: domain.State,
    interval: struct {
        state: domain.State,
        coalesced_ticks: u32,
    },
    approval: []u8,
    tool_activity: ToolActivity,

    pub fn deinit(self: *DeliveryPayload, alloc: Allocator) void {
        switch (self.*) {
            .message, .milestone, .approval => |value| alloc.free(value),
            .tool_activity => |value| alloc.free(value.tool_name),
            .terminal, .interval => {},
        }
        self.* = undefined;
    }

    pub fn clone(self: DeliveryPayload, alloc: Allocator) !DeliveryPayload {
        return switch (self) {
            .message => |value| .{ .message = try alloc.dupe(u8, value) },
            .milestone => |value| .{ .milestone = try alloc.dupe(u8, value) },
            .terminal => |value| .{ .terminal = value },
            .interval => |value| .{ .interval = value },
            .approval => |value| .{ .approval = try alloc.dupe(u8, value) },
            .tool_activity => |value| .{ .tool_activity = .{
                .tool_name = try alloc.dupe(u8, value.tool_name),
                .phase = value.phase,
            } },
        };
    }
};

/// One immutable, allocator-owned communication envelope. It is manager
/// metadata and is never appended to either session transcript.
pub const Delivery = struct {
    sequence: u64,
    revision: u64,
    id: []u8,
    source_id: []u8,
    target_id: []u8,
    work_id: ?[]u8 = null,
    operation_id: ?[]u8 = null,
    timestamp_ms: i64,
    payload: DeliveryPayload,

    pub fn deinit(self: *Delivery, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.source_id);
        alloc.free(self.target_id);
        if (self.work_id) |value| alloc.free(value);
        if (self.operation_id) |value| alloc.free(value);
        self.payload.deinit(alloc);
        self.* = undefined;
    }

    pub fn clone(self: Delivery, alloc: Allocator) !Delivery {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const source_id = try alloc.dupe(u8, self.source_id);
        errdefer alloc.free(source_id);
        const target_id = try alloc.dupe(u8, self.target_id);
        errdefer alloc.free(target_id);
        const work_id = if (self.work_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (work_id) |value| alloc.free(value);
        const operation_id = if (self.operation_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (operation_id) |value| alloc.free(value);
        return .{
            .sequence = self.sequence,
            .revision = self.revision,
            .id = id,
            .source_id = source_id,
            .target_id = target_id,
            .work_id = work_id,
            .operation_id = operation_id,
            .timestamp_ms = self.timestamp_ms,
            .payload = try self.payload.clone(alloc),
        };
    }
};

pub const DeliveryInput = struct {
    id: []const u8,
    source_id: []const u8,
    target_id: []const u8,
    work_id: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    operation_identity_admitted: bool = false,
    timestamp_ms: i64,
    payload: union(DeliveryKind) {
        message: []const u8,
        milestone: []const u8,
        terminal: domain.State,
        interval: struct { state: domain.State, coalesced_ticks: u32 },
        approval: []const u8,
        tool_activity: struct {
            tool_name: []const u8,
            phase: ToolActivityPhase,
        },
    },
};

pub const ConsumerCursor = struct {
    consumer_id: []u8,
    target_id: []u8,
    projection: Projection = .human,
    acknowledged_sequence: u64 = 0,
    partial_message_sequence: u64 = 0,
    partial_message_offset: u64 = 0,
    stale: bool = false,

    pub fn deinit(self: *ConsumerCursor, alloc: Allocator) void {
        alloc.free(self.consumer_id);
        alloc.free(self.target_id);
        self.* = undefined;
    }

    pub fn clone(self: ConsumerCursor, alloc: Allocator) !ConsumerCursor {
        const consumer_id = try alloc.dupe(u8, self.consumer_id);
        errdefer alloc.free(consumer_id);
        return .{
            .consumer_id = consumer_id,
            .target_id = try alloc.dupe(u8, self.target_id),
            .projection = self.projection,
            .acknowledged_sequence = self.acknowledged_sequence,
            .partial_message_sequence = self.partial_message_sequence,
            .partial_message_offset = self.partial_message_offset,
            .stale = self.stale,
        };
    }
};

/// Bounded target-scoped evidence that a projection has lost retained data.
/// This also protects consumers whose first read happens after the eviction.
pub const RetentionTarget = struct {
    target_id: []u8,
    human_evicted_through: u64 = 0,
    parent_turn_evicted_through: u64 = 0,

    pub fn deinit(self: *RetentionTarget, alloc: Allocator) void {
        alloc.free(self.target_id);
        self.* = undefined;
    }

    pub fn clone(self: RetentionTarget, alloc: Allocator) !RetentionTarget {
        return .{
            .target_id = try alloc.dupe(u8, self.target_id),
            .human_evicted_through = self.human_evicted_through,
            .parent_turn_evicted_through = self.parent_turn_evicted_through,
        };
    }
};

pub const WorkNotification = struct {
    work_id: []u8,
    policy: domain.NotificationPolicy,
    started_at_ms: i64,
    next_due_ms: ?i64,
    stopped: bool = false,

    pub fn deinit(self: *WorkNotification, alloc: Allocator) void {
        alloc.free(self.work_id);
        self.policy.deinit(alloc);
        self.* = undefined;
    }

    pub fn clone(self: WorkNotification, alloc: Allocator) !WorkNotification {
        const work_id = try alloc.dupe(u8, self.work_id);
        errdefer alloc.free(work_id);
        return .{
            .work_id = work_id,
            .policy = try self.policy.clone(alloc),
            .started_at_ms = self.started_at_ms,
            .next_due_ms = self.next_due_ms,
            .stopped = self.stopped,
        };
    }
};

pub const ApprovalKind = enum { tool, relationship };
pub const ApprovalStatus = enum {
    pending,
    allowed_once,
    allowed_always,
    denied,
    cancelled,
    stale,
    consumed,
};

pub const RelationshipApproval = struct {
    action: domain.RelationshipAction,
    prospective_parent_id: []u8,
    operation_id: []u8,

    pub fn deinit(self: *RelationshipApproval, alloc: Allocator) void {
        alloc.free(self.prospective_parent_id);
        alloc.free(self.operation_id);
        self.* = undefined;
    }

    pub fn clone(self: RelationshipApproval, alloc: Allocator) !RelationshipApproval {
        const prospective_parent_id = try alloc.dupe(u8, self.prospective_parent_id);
        errdefer alloc.free(prospective_parent_id);
        return .{
            .action = self.action,
            .prospective_parent_id = prospective_parent_id,
            .operation_id = try alloc.dupe(u8, self.operation_id),
        };
    }
};

/// Durable projection of one canonical prepared request. The executable
/// payload is represented by its canonical digest; human surfaces receive only
/// the bounded label, explanation, command projection, and optional file review
/// exposed by fx.
pub const Approval = struct {
    id: []u8,
    kind: ApprovalKind,
    child_id: []u8,
    root_id: []u8,
    work_id: ?[]u8,
    relationship: ?RelationshipApproval = null,
    prepared_fingerprint: [32]u8,
    identity_fingerprint: [32]u8 = [_]u8{0} ** 32,
    label: []u8,
    explanation: ?[]u8,
    command: ?[]u8 = null,
    file: ?permission_request.FileApprovalRequest = null,
    grants: []types.PermissionGrant,
    status: ApprovalStatus,
    created_at_ms: i64,
    resolved_at_ms: ?i64 = null,
    resolved_revision: ?u64 = null,

    pub fn deinit(self: *Approval, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        if (self.work_id) |value| alloc.free(value);
        if (self.relationship) |*value| value.deinit(alloc);
        alloc.free(self.label);
        if (self.explanation) |value| alloc.free(value);
        if (self.command) |value| alloc.free(value);
        if (self.file) |value| {
            permission_request.deinitFileApprovalRequest(alloc, value);
        }
        types.freePermissionGrantSlice(alloc, self.grants);
        self.* = undefined;
    }

    pub fn clone(self: Approval, alloc: Allocator) !Approval {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const child_id = try alloc.dupe(u8, self.child_id);
        errdefer alloc.free(child_id);
        const root_id = try alloc.dupe(u8, self.root_id);
        errdefer alloc.free(root_id);
        const work_id = if (self.work_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (work_id) |value| alloc.free(value);
        var relationship = if (self.relationship) |value| try value.clone(alloc) else null;
        errdefer if (relationship) |*value| value.deinit(alloc);
        const label = try alloc.dupe(u8, self.label);
        errdefer alloc.free(label);
        const explanation = if (self.explanation) |value| try alloc.dupe(u8, value) else null;
        errdefer if (explanation) |value| alloc.free(value);
        const command = if (self.command) |value| try alloc.dupe(u8, value) else null;
        errdefer if (command) |value| alloc.free(value);
        const file = if (self.file) |value|
            try permission_request.dupeFileApprovalRequest(alloc, value)
        else
            null;
        errdefer if (file) |value| {
            permission_request.deinitFileApprovalRequest(alloc, value);
        };
        return .{
            .id = id,
            .kind = self.kind,
            .child_id = child_id,
            .root_id = root_id,
            .work_id = work_id,
            .relationship = relationship,
            .prepared_fingerprint = self.prepared_fingerprint,
            .identity_fingerprint = self.identity_fingerprint,
            .label = label,
            .explanation = explanation,
            .command = command,
            .file = file,
            .grants = try types.dupePermissionGrantSlice(alloc, self.grants),
            .status = self.status,
            .created_at_ms = self.created_at_ms,
            .resolved_at_ms = self.resolved_at_ms,
            .resolved_revision = self.resolved_revision,
        };
    }
};

pub const Ledger = struct {
    session_id: []u8,
    capacity_version: u64 = 0,
    generation: u64 = 0,
    next_sequence: u64 = 1,
    deliveries: []Delivery,
    cursors: []ConsumerCursor,
    /// Optional so schema-v1 records written before target-scoped retention
    /// evidence deserialize without a migration branch.
    retention_targets: ?[]RetentionTarget = null,
    work_notifications: []WorkNotification,
    approvals: []Approval,
    /// Retained for schema-v1 compatibility. Route-scoped `ConsumerCursor.stale`
    /// is authoritative for retention loss.
    parent_turn_evicted_through: u64 = 0,
    authority_generation: u64 = 0,
    authority_grants: []types.PermissionGrant,
    legacy_operation_replay_closed: bool = false,
    model_replay_floor: u64 = 0,
    human_replay_floor: u64 = 0,
    model_epoch_high: u64 = 0,
    human_epoch_high: u64 = 0,

    pub fn init(alloc: Allocator, session_id: []const u8) !Ledger {
        try domain.validateId(session_id);
        const owned_session_id = try alloc.dupe(u8, session_id);
        errdefer alloc.free(owned_session_id);
        const deliveries = try alloc.alloc(Delivery, 0);
        errdefer alloc.free(deliveries);
        const cursors = try alloc.alloc(ConsumerCursor, 0);
        errdefer alloc.free(cursors);
        const retention_targets = try alloc.alloc(RetentionTarget, 0);
        errdefer alloc.free(retention_targets);
        const work_notifications = try alloc.alloc(WorkNotification, 0);
        errdefer alloc.free(work_notifications);
        const approvals = try alloc.alloc(Approval, 0);
        errdefer alloc.free(approvals);
        return .{
            .session_id = owned_session_id,
            .capacity_version = capacity_contract_version,
            .deliveries = deliveries,
            .cursors = cursors,
            .retention_targets = retention_targets,
            .work_notifications = work_notifications,
            .approvals = approvals,
            .authority_grants = try alloc.alloc(types.PermissionGrant, 0),
        };
    }

    pub fn deinit(self: *Ledger, alloc: Allocator) void {
        alloc.free(self.session_id);
        for (self.deliveries) |*value| value.deinit(alloc);
        alloc.free(self.deliveries);
        for (self.cursors) |*value| value.deinit(alloc);
        alloc.free(self.cursors);
        if (self.retention_targets) |targets| {
            for (targets) |*value| value.deinit(alloc);
            alloc.free(targets);
        }
        for (self.work_notifications) |*value| value.deinit(alloc);
        alloc.free(self.work_notifications);
        for (self.approvals) |*value| value.deinit(alloc);
        alloc.free(self.approvals);
        types.freePermissionGrantSlice(alloc, self.authority_grants);
        self.* = undefined;
    }

    pub fn clone(self: Ledger, alloc: Allocator) !Ledger {
        const session_id = try alloc.dupe(u8, self.session_id);
        errdefer alloc.free(session_id);
        const deliveries = try cloneSlice(Delivery, alloc, self.deliveries);
        errdefer freeSlice(Delivery, alloc, deliveries);
        const cursors = try cloneSlice(ConsumerCursor, alloc, self.cursors);
        errdefer freeSlice(ConsumerCursor, alloc, cursors);
        const retention_targets = if (self.retention_targets) |targets|
            try cloneSlice(RetentionTarget, alloc, targets)
        else
            null;
        errdefer if (retention_targets) |targets|
            freeSlice(RetentionTarget, alloc, targets);
        const work_notifications = try cloneSlice(WorkNotification, alloc, self.work_notifications);
        errdefer freeSlice(WorkNotification, alloc, work_notifications);
        const approvals = try cloneSlice(Approval, alloc, self.approvals);
        errdefer freeSlice(Approval, alloc, approvals);
        return .{
            .session_id = session_id,
            .capacity_version = self.capacity_version,
            .generation = self.generation,
            .next_sequence = self.next_sequence,
            .deliveries = deliveries,
            .cursors = cursors,
            .retention_targets = retention_targets,
            .work_notifications = work_notifications,
            .approvals = approvals,
            .parent_turn_evicted_through = self.parent_turn_evicted_through,
            .authority_generation = self.authority_generation,
            .authority_grants = try types.dupePermissionGrantSlice(alloc, self.authority_grants),
            .legacy_operation_replay_closed = self.legacy_operation_replay_closed,
            .model_replay_floor = self.model_replay_floor,
            .human_replay_floor = self.human_replay_floor,
            .model_epoch_high = self.model_epoch_high,
            .human_epoch_high = self.human_epoch_high,
        };
    }
};

pub const MutationError = error{
    OutOfMemory,
    InvalidDelivery,
    GenerationExhausted,
    SequenceExhausted,
    TooManyConsumers,
    TooManyRetentionTargets,
    InvalidCursor,
    StaleCursor,
    InvalidNotification,
    UndeclaredMilestone,
    DuplicateMilestone,
    InvalidApproval,
    ApprovalConflict,
    AuthorityExhausted,
    CapacityExceeded,
    ReplayExpired,
};

pub const ValidationError = error{InvalidLedger};

/// Pure semantic validation for the durable communication boundary.
pub fn validateLedger(ledger: Ledger) ValidationError!void {
    domain.validateId(ledger.session_id) catch return error.InvalidLedger;
    if (ledger.capacity_version > capacity_contract_version) {
        return error.InvalidLedger;
    }
    const retention_target_count = if (ledger.retention_targets) |targets|
        targets.len
    else
        0;
    if (ledger.next_sequence == 0 or
        ledger.deliveries.len > max_deliveries or
        ledger.cursors.len > max_consumers or
        retention_target_count > max_retention_targets or
        ledger.approvals.len > max_approvals)
    {
        return error.InvalidLedger;
    }
    if (ledger.parent_turn_evicted_through >= ledger.next_sequence) {
        return error.InvalidLedger;
    }
    if (ledger.model_replay_floor > ledger.model_epoch_high +| 1 or
        ledger.human_replay_floor > ledger.human_epoch_high +| 1)
    {
        return error.InvalidLedger;
    }
    if (!ledger.legacy_operation_replay_closed and
        (ledger.model_replay_floor != 0 or ledger.human_replay_floor != 0 or
            ledger.model_epoch_high != 0 or ledger.human_epoch_high != 0))
    {
        return error.InvalidLedger;
    }
    var has_bound_operation = false;
    var prior_sequence: u64 = 0;
    var prior_delivery_revision: u64 = 0;
    for (ledger.deliveries, 0..) |delivery, index| {
        const input = deliveryAsInput(delivery);
        validateDeliveryInput(input) catch return error.InvalidLedger;
        if (delivery.sequence == 0 or delivery.revision == 0 or
            delivery.revision > ledger.generation or
            delivery.revision <= prior_delivery_revision or
            (index != 0 and delivery.sequence != prior_sequence + 1) or
            delivery.sequence >= ledger.next_sequence)
        {
            return error.InvalidLedger;
        }
        if (ledger.capacity_version == capacity_contract_version and
            !deliveryAdmissionFits(delivery))
        {
            return error.InvalidLedger;
        }
        for (ledger.deliveries[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, delivery.id)) return error.InvalidLedger;
        }
        if (delivery.operation_id) |operation_id| {
            if (tool_result.parseBoundOperationId(operation_id)) |identity| {
                has_bound_operation = true;
                if (identity.authority == .manager) {
                    const high = switch (identity.source) {
                        .model => ledger.model_epoch_high,
                        .human => ledger.human_epoch_high,
                    };
                    if (identity.epoch > high) return error.InvalidLedger;
                }
            }
        }
        prior_sequence = delivery.sequence;
        prior_delivery_revision = delivery.revision;
    }
    if (has_bound_operation and !ledger.legacy_operation_replay_closed) {
        return error.InvalidLedger;
    }
    if (ledger.deliveries.len != 0 and prior_sequence + 1 != ledger.next_sequence) {
        return error.InvalidLedger;
    }
    for (ledger.cursors, 0..) |cursor, index| {
        validateConsumerId(cursor.consumer_id) catch return error.InvalidLedger;
        domain.validateId(cursor.target_id) catch return error.InvalidLedger;
        if (cursor.acknowledged_sequence >= ledger.next_sequence) {
            return error.InvalidLedger;
        }
        if ((cursor.partial_message_sequence == 0) !=
            (cursor.partial_message_offset == 0) or
            (cursor.projection == .human and
                cursor.partial_message_sequence != 0) or
            (cursor.partial_message_sequence != 0 and
                !validPartialMessageCursor(ledger.deliveries, cursor)))
        {
            return error.InvalidLedger;
        }
        if (cursor.acknowledged_sequence != 0 and
            (ledger.deliveries.len == 0 or
                cursor.acknowledged_sequence >= ledger.deliveries[0].sequence) and
            !deliverySequenceTargets(
                ledger.deliveries,
                cursor.acknowledged_sequence,
                cursor.target_id,
                cursor.projection,
            ))
        {
            return error.InvalidLedger;
        }
        for (ledger.cursors[0..index]) |prior| {
            if (std.mem.eql(u8, prior.consumer_id, cursor.consumer_id) and
                std.mem.eql(u8, prior.target_id, cursor.target_id) and
                prior.projection == cursor.projection)
            {
                return error.InvalidLedger;
            }
        }
    }
    const retention_targets = ledger.retention_targets orelse &.{};
    for (retention_targets, 0..) |target, index| {
        domain.validateId(target.target_id) catch return error.InvalidLedger;
        if ((target.human_evicted_through == 0 and
            target.parent_turn_evicted_through == 0) or
            target.human_evicted_through >= ledger.next_sequence or
            target.parent_turn_evicted_through >= ledger.next_sequence)
        {
            return error.InvalidLedger;
        }
        for (retention_targets[0..index]) |prior| {
            if (std.mem.eql(u8, prior.target_id, target.target_id)) {
                return error.InvalidLedger;
            }
        }
    }
    for (ledger.work_notifications, 0..) |work, index| {
        domain.validateOperationId(work.work_id) catch return error.InvalidLedger;
        validatePolicy(work.policy) catch return error.InvalidLedger;
        if (work.stopped != (work.next_due_ms == null) and
            work.policy.report_interval_ms != null)
        {
            return error.InvalidLedger;
        }
        for (ledger.work_notifications[0..index]) |prior| {
            if (std.mem.eql(u8, prior.work_id, work.work_id)) return error.InvalidLedger;
        }
    }
    for (ledger.approvals, 0..) |approval, index| {
        domain.validateOperationId(approval.id) catch return error.InvalidLedger;
        domain.validateId(approval.child_id) catch return error.InvalidLedger;
        domain.validateId(approval.root_id) catch return error.InvalidLedger;
        if (approval.work_id) |value| domain.validateOperationId(value) catch
            return error.InvalidLedger;
        validateContent(approval.label) catch return error.InvalidLedger;
        if (approval.explanation) |value| validateContent(value) catch
            return error.InvalidLedger;
        if (approval.command) |value| validateApprovalProjection(value) catch
            return error.InvalidLedger;
        if (approval.file) |file| {
            _ = permission_request.fileRequestFootprint(.{
                .label = approval.label,
                .explanation = approval.explanation,
                .file = file,
                .amendment_allowed = false,
            }) catch return error.InvalidLedger;
        }
        if ((approval.status == .pending) != (approval.resolved_at_ms == null) or
            (approval.status == .pending) != (approval.resolved_revision == null) or
            (approval.resolved_revision != null and
                (approval.resolved_revision.? == 0 or
                    approval.resolved_revision.? > ledger.generation)) or
            approval.grants.len > domain.max_admission_items)
        {
            return error.InvalidLedger;
        }
        switch (approval.kind) {
            .tool => if (approval.work_id == null or approval.relationship != null) {
                return error.InvalidLedger;
            },
            .relationship => if (approval.work_id != null or
                approval.relationship == null or approval.file != null or
                approval.command != null or approval.grants.len != 0)
            {
                return error.InvalidLedger;
            },
        }
        if (approval.relationship) |relationship| {
            if (relationship.action == .detach) return error.InvalidLedger;
            domain.validateId(relationship.prospective_parent_id) catch
                return error.InvalidLedger;
            domain.validateOperationId(relationship.operation_id) catch
                return error.InvalidLedger;
        }
        for (approval.grants) |grant| {
            validateContent(grant.tool_name) catch return error.InvalidLedger;
            validateApprovalProjection(grant.target_path) catch
                return error.InvalidLedger;
        }
        if (!std.mem.eql(
            u8,
            &approval.identity_fingerprint,
            &approvalIdentityFingerprint(approvalAsInput(approval)),
        )) return error.InvalidLedger;
        for (ledger.approvals[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, approval.id)) return error.InvalidLedger;
        }
    }
    if (ledger.authority_grants.len > max_authority_grants) {
        return error.InvalidLedger;
    }
    for (ledger.authority_grants, 0..) |grant, index| {
        validateContent(grant.tool_name) catch return error.InvalidLedger;
        validateApprovalProjection(grant.target_path) catch
            return error.InvalidLedger;
        for (ledger.authority_grants[0..index]) |prior| {
            if (std.mem.eql(u8, prior.tool_name, grant.tool_name) and
                std.mem.eql(u8, prior.target_path, grant.target_path))
            {
                return error.InvalidLedger;
            }
        }
    }
    if (ledger.capacity_version == capacity_contract_version and
        !capacityContractSatisfied(ledger))
    {
        return error.InvalidLedger;
    }
}

pub const CanonicalBudgetUsage = struct {
    active_work_count: usize,
    active_work_bytes: usize,
    live_approval_count: usize,
    live_approval_bytes: usize,
    authority_grant_count: usize,
    authority_grant_bytes: usize,
    consumer_cursor_bytes: usize,
    retention_target_bytes: usize,
    total_irreducible_bytes: usize,
};

const CollectionCharge = struct {
    count: usize = 0,
    bytes: usize = 2,

    fn add(self: *CollectionCharge, value: anytype) bool {
        const value_bytes = canonicalJsonBytes(value) orelse return false;
        return self.addBytes(value_bytes);
    }

    fn addBytes(self: *CollectionCharge, value_bytes: usize) bool {
        if (self.count != 0) {
            self.bytes = std.math.add(usize, self.bytes, 1) catch return false;
        }
        self.bytes = std.math.add(usize, self.bytes, value_bytes) catch
            return false;
        self.count = std.math.add(usize, self.count, 1) catch return false;
        return true;
    }
};

/// Mutable timestamps, revisions, and cursors are charged at their widest
/// canonical representation so later progress cannot invalidate admission.
pub fn canonicalBudgetUsage(ledger: Ledger) ?CanonicalBudgetUsage {
    var work: CollectionCharge = .{};
    for (ledger.work_notifications) |notification| {
        if (!notification.stopped and !addWorkBudgetCharge(&work, notification)) {
            return null;
        }
    }
    var approvals: CollectionCharge = .{};
    for (ledger.approvals) |approval| {
        if (approvalIsLive(approval) and
            !addApprovalBudgetCharge(&approvals, approval))
        {
            return null;
        }
    }
    var grants: CollectionCharge = .{};
    for (ledger.authority_grants) |grant| {
        const grant_bytes = canonicalPermissionGrantWireBytes(grant) orelse
            return null;
        if (!grants.addBytes(grant_bytes)) return null;
    }
    var cursors: CollectionCharge = .{};
    for (ledger.cursors) |cursor| {
        if (!addCursorBudgetCharge(&cursors, cursor)) return null;
    }
    var retention: CollectionCharge = .{};
    for (ledger.retention_targets orelse &.{}) |target| {
        if (!addRetentionBudgetCharge(&retention, target)) return null;
    }
    var total = std.math.add(usize, work.bytes, approvals.bytes) catch return null;
    total = std.math.add(usize, total, grants.bytes) catch return null;
    total = std.math.add(usize, total, cursors.bytes) catch return null;
    total = std.math.add(usize, total, retention.bytes) catch return null;
    return .{
        .active_work_count = work.count,
        .active_work_bytes = work.bytes,
        .live_approval_count = approvals.count,
        .live_approval_bytes = approvals.bytes,
        .authority_grant_count = grants.count,
        .authority_grant_bytes = grants.bytes,
        .consumer_cursor_bytes = cursors.bytes,
        .retention_target_bytes = retention.bytes,
        .total_irreducible_bytes = total,
    };
}

pub fn capacityContractSatisfied(ledger: Ledger) bool {
    for (ledger.deliveries) |delivery| {
        if (!deliveryAdmissionFits(delivery)) return false;
    }
    const usage = canonicalBudgetUsage(ledger) orelse return false;
    return budgetUsageWithinLimits(usage);
}

fn budgetUsageWithinLimits(usage: CanonicalBudgetUsage) bool {
    return usage.active_work_count <= max_active_work_notifications and
        usage.active_work_bytes <= max_active_work_notification_bytes and
        usage.live_approval_count <= max_live_approvals and
        usage.live_approval_bytes <= max_live_approval_bytes and
        usage.authority_grant_count <= max_authority_grants and
        usage.authority_grant_bytes <= max_authority_grant_bytes and
        usage.consumer_cursor_bytes <= max_consumer_cursor_bytes and
        usage.retention_target_bytes <= max_retention_target_bytes and
        usage.total_irreducible_bytes <= max_irreducible_canonical_bytes;
}

fn canonicalJsonBytes(value: anytype) ?usize {
    var buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&buffer);
    std.json.Stringify.value(value, .{}, &discarding.writer) catch return null;
    return std.math.cast(usize, discarding.fullCount());
}

fn addWorkBudgetCharge(
    charge: *CollectionCharge,
    notification: WorkNotification,
) bool {
    var worst_case = notification;
    worst_case.started_at_ms = std.math.minInt(i64);
    worst_case.next_due_ms = std.math.minInt(i64);
    worst_case.stopped = false;
    return charge.add(worst_case);
}

fn addApprovalBudgetCharge(
    charge: *CollectionCharge,
    approval: Approval,
) bool {
    var worst_case = approval;
    worst_case.status = .allowed_once;
    worst_case.resolved_at_ms = std.math.minInt(i64);
    worst_case.resolved_revision = std.math.maxInt(u64);
    const bytes = canonicalApprovalWireBytes(worst_case) orelse return false;
    return charge.addBytes(bytes);
}

fn canonicalApprovalWireBytes(approval: Approval) ?usize {
    var empty_grants: [domain.max_admission_items]types.PermissionGrant = undefined;
    if (approval.grants.len > empty_grants.len) return null;
    for (approval.grants, empty_grants[0..approval.grants.len]) |grant, *empty| {
        empty.* = .{
            .tool_name = grant.tool_name,
            .target_path = @constCast(""),
        };
    }
    var base = approval;
    base.command = null;
    base.grants = empty_grants[0..approval.grants.len];
    var bytes = canonicalJsonBytes(base) orelse return null;
    if (approval.command) |command| {
        bytes = std.math.add(
            usize,
            bytes,
            canonicalBase64TextBytes(command),
        ) catch return null;
    }
    for (approval.grants) |grant| {
        bytes = std.math.add(
            usize,
            bytes,
            canonicalBase64TextBytes(grant.target_path),
        ) catch return null;
    }
    return bytes;
}

fn canonicalPermissionGrantWireBytes(grant: types.PermissionGrant) ?usize {
    var base = grant;
    base.target_path = @constCast("");
    const base_bytes = canonicalJsonBytes(base) orelse return null;
    return std.math.add(
        usize,
        base_bytes,
        canonicalBase64TextBytes(grant.target_path),
    ) catch null;
}

fn canonicalBase64TextBytes(value: []const u8) usize {
    return "{\"encoding\":\"base64\",\"data\":\"\"}".len +
        std.base64.standard.Encoder.calcSize(value.len);
}

fn addCursorBudgetCharge(
    charge: *CollectionCharge,
    cursor: ConsumerCursor,
) bool {
    var worst_case = cursor;
    worst_case.acknowledged_sequence = std.math.maxInt(u64);
    worst_case.partial_message_sequence = std.math.maxInt(u64);
    worst_case.partial_message_offset = std.math.maxInt(u64);
    worst_case.stale = false;
    return charge.add(worst_case);
}

fn addRetentionBudgetCharge(
    charge: *CollectionCharge,
    target: RetentionTarget,
) bool {
    var worst_case = target;
    worst_case.human_evicted_through = std.math.maxInt(u64);
    worst_case.parent_turn_evicted_through = std.math.maxInt(u64);
    return charge.add(worst_case);
}

pub fn canonicalDeliveryWireBytes(delivery: Delivery) ?usize {
    if (delivery.payload != .message) return canonicalJsonBytes(delivery);
    var without_content = delivery;
    without_content.payload = .{ .message = @constCast("") };
    const fixed_bytes = canonicalJsonBytes(without_content) orelse return null;
    const encoded_bytes = std.base64.standard.Encoder.calcSize(
        delivery.payload.message.len,
    );
    const encoded_object_overhead =
        "{\"encoding\":\"base64\",\"data\":\"\"}".len - "\"\"".len;
    return std.math.add(
        usize,
        fixed_bytes,
        encoded_object_overhead + encoded_bytes,
    ) catch null;
}

fn deliveryAdmissionFits(delivery: Delivery) bool {
    const bytes = canonicalDeliveryWireBytes(delivery) orelse return false;
    return bytes <= max_retained_delivery_canonical_bytes;
}

fn approvalIsLive(approval: Approval) bool {
    return approval.status == .pending or approval.status == .allowed_once;
}

fn usageWithCollection(
    current: CanonicalBudgetUsage,
    old_bytes: usize,
    new_count: usize,
    new_bytes: usize,
    comptime collection: enum { work, approvals, grants, cursors, retention },
) ?CanonicalBudgetUsage {
    var updated = current;
    updated.total_irreducible_bytes = std.math.sub(
        usize,
        updated.total_irreducible_bytes,
        old_bytes,
    ) catch return null;
    updated.total_irreducible_bytes = std.math.add(
        usize,
        updated.total_irreducible_bytes,
        new_bytes,
    ) catch return null;
    switch (collection) {
        .work => {
            updated.active_work_count = new_count;
            updated.active_work_bytes = new_bytes;
        },
        .approvals => {
            updated.live_approval_count = new_count;
            updated.live_approval_bytes = new_bytes;
        },
        .grants => {
            updated.authority_grant_count = new_count;
            updated.authority_grant_bytes = new_bytes;
        },
        .cursors => {
            updated.consumer_cursor_bytes = new_bytes;
        },
        .retention => {
            updated.retention_target_bytes = new_bytes;
        },
    }
    return updated;
}

fn workAdmissionFits(ledger: Ledger, candidate: WorkNotification) bool {
    const current = canonicalBudgetUsage(ledger) orelse return false;
    var replacement: CollectionCharge = .{};
    for (ledger.work_notifications) |work| {
        if (work.stopped or std.mem.eql(u8, work.work_id, candidate.work_id)) {
            continue;
        }
        if (!addWorkBudgetCharge(&replacement, work)) return false;
    }
    if (!addWorkBudgetCharge(&replacement, candidate)) return false;
    const updated = usageWithCollection(
        current,
        current.active_work_bytes,
        replacement.count,
        replacement.bytes,
        .work,
    ) orelse return false;
    return budgetUsageWithinLimits(updated);
}

fn approvalAdmissionFits(ledger: Ledger, candidate: Approval) bool {
    const current = canonicalBudgetUsage(ledger) orelse return false;
    var retained: CollectionCharge = .{};
    for (ledger.approvals) |approval| {
        if (approvalIsLive(approval) and
            !addApprovalBudgetCharge(&retained, approval))
        {
            return false;
        }
    }
    if (!addApprovalBudgetCharge(&retained, candidate)) return false;
    const updated = usageWithCollection(
        current,
        current.live_approval_bytes,
        retained.count,
        retained.bytes,
        .approvals,
    ) orelse return false;
    return budgetUsageWithinLimits(updated);
}

fn selectNewGrants(
    existing: []const types.PermissionGrant,
    grants: []const types.PermissionGrant,
    admitted: *[domain.max_admission_items]bool,
) usize {
    admitted.* = [_]bool{false} ** domain.max_admission_items;
    var count: usize = 0;
    for (grants, 0..) |grant, index| {
        if (permissions.sessionGrantAllowed(
            existing,
            grant.tool_name,
            grant.target_path,
        )) continue;
        var covered = false;
        for (0..index) |prior_index| {
            if (!admitted.*[prior_index]) continue;
            if (permissions.sessionGrantAllowed(
                grants[prior_index .. prior_index + 1],
                grant.tool_name,
                grant.target_path,
            )) {
                covered = true;
                break;
            }
        }
        if (covered) continue;
        admitted.*[index] = true;
        count += 1;
    }
    return count;
}

fn grantAdmissionFits(
    ledger: Ledger,
    grants: []const types.PermissionGrant,
    admitted: *const [domain.max_admission_items]bool,
) bool {
    const current = canonicalBudgetUsage(ledger) orelse return false;
    var retained: CollectionCharge = .{};
    for (ledger.authority_grants) |grant| {
        const grant_bytes = canonicalPermissionGrantWireBytes(grant) orelse
            return false;
        if (!retained.addBytes(grant_bytes)) return false;
    }
    for (grants, 0..) |grant, index| {
        if (!admitted.*[index]) continue;
        const grant_bytes = canonicalPermissionGrantWireBytes(grant) orelse
            return false;
        if (!retained.addBytes(grant_bytes)) return false;
    }
    const updated = usageWithCollection(
        current,
        current.authority_grant_bytes,
        retained.count,
        retained.bytes,
        .grants,
    ) orelse return false;
    return budgetUsageWithinLimits(updated);
}

fn cursorAdmissionFits(ledger: Ledger, candidate: ConsumerCursor) bool {
    const current = canonicalBudgetUsage(ledger) orelse return false;
    var retained: CollectionCharge = .{};
    for (ledger.cursors) |cursor| {
        if (!addCursorBudgetCharge(&retained, cursor)) return false;
    }
    if (!addCursorBudgetCharge(&retained, candidate)) return false;
    const updated = usageWithCollection(
        current,
        current.consumer_cursor_bytes,
        retained.count,
        retained.bytes,
        .cursors,
    ) orelse return false;
    return budgetUsageWithinLimits(updated);
}

fn retentionAdmissionFits(ledger: Ledger, candidate: RetentionTarget) bool {
    const current = canonicalBudgetUsage(ledger) orelse return false;
    var retained: CollectionCharge = .{};
    for (ledger.retention_targets orelse &.{}) |target| {
        if (!addRetentionBudgetCharge(&retained, target)) return false;
    }
    if (!addRetentionBudgetCharge(&retained, candidate)) return false;
    const updated = usageWithCollection(
        current,
        current.retention_target_bytes,
        retained.count,
        retained.bytes,
        .retention,
    ) orelse return false;
    return budgetUsageWithinLimits(updated);
}

pub const AppendResult = union(enum) {
    appended: u64,
    duplicate: u64,
};

/// Pure append reduction. On success the ledger owns all newly allocated data.
pub fn appendDelivery(
    alloc: Allocator,
    ledger: *Ledger,
    input: DeliveryInput,
) MutationError!AppendResult {
    try validateDeliveryInput(input);
    for (ledger.deliveries) |delivery| {
        if (!std.mem.eql(u8, delivery.id, input.id)) continue;
        return if (deliveryInputMatches(delivery, input))
            .{ .duplicate = delivery.sequence }
        else
            error.InvalidDelivery;
    }
    const identity = deliveryOperationIdentity(input);
    switch (identity) {
        .none => {},
        .legacy => if (ledger.legacy_operation_replay_closed) {
            return error.ReplayExpired;
        },
        .bound => |bound| switch (bound.authority) {
            .process_local => return error.ReplayExpired,
            .manager => if (bound.epoch < switch (bound.source) {
                .model => ledger.model_replay_floor,
                .human => ledger.human_replay_floor,
            } or !input.operation_identity_admitted) {
                return error.ReplayExpired;
            },
        },
    }
    const sequence = ledger.next_sequence;
    if (sequence == 0) return error.SequenceExhausted;
    const next_sequence = std.math.add(u64, sequence, 1) catch
        return error.SequenceExhausted;
    const next_generation = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    var delivery = try ownDelivery(alloc, sequence, next_generation, input);
    errdefer delivery.deinit(alloc);
    if (!deliveryAdmissionFits(delivery)) return error.CapacityExceeded;

    if (ledger.deliveries.len == max_deliveries) {
        try recordRetentionLoss(
            alloc,
            ledger,
            ledger.deliveries[0],
            delivery,
        );
        markStaleCursorsForEviction(ledger.cursors, ledger.deliveries[0]);
        ledger.deliveries[0].deinit(alloc);
        std.mem.copyForwards(
            Delivery,
            ledger.deliveries[0 .. ledger.deliveries.len - 1],
            ledger.deliveries[1..],
        );
        ledger.deliveries[ledger.deliveries.len - 1] = delivery;
    } else {
        ledger.deliveries = try alloc.realloc(ledger.deliveries, ledger.deliveries.len + 1);
        ledger.deliveries[ledger.deliveries.len - 1] = delivery;
    }
    ledger.next_sequence = next_sequence;
    ledger.generation = next_generation;
    noteDeliveryIdentity(ledger, identity);
    return .{ .appended = sequence };
}

pub const Page = struct {
    generation: u64,
    deliveries: []Delivery,
    through_sequence: u64,
    has_more: bool,
    retention_gap_through: ?u64 = null,

    pub fn deinit(self: *Page, alloc: Allocator) void {
        freeSlice(Delivery, alloc, self.deliveries);
        self.* = undefined;
    }
};

pub const ParentMessagePart = struct {
    logical_message_id: []const u8,
    offset: u64,
    end_offset: u64,
    total_bytes: u64,
    more: bool,
    content: []u8,
};

pub const ParentDeliveryKind = enum {
    message,
    milestone,
    terminal,
    interval,
    approval,
    tool_activity,
    retention_gap,
};

pub const ParentDeliveryPayload = union(ParentDeliveryKind) {
    message: ParentMessagePart,
    milestone: []u8,
    terminal: domain.State,
    interval: struct {
        state: domain.State,
        coalesced_ticks: u32,
    },
    approval: struct {
        label: []u8,
        truncated: bool,
        total_bytes: u64,
    },
    tool_activity: ToolActivity,
    retention_gap: struct {
        evicted_through: u64,
    },
};

/// One deterministic parent-model projection unit. Message parts preserve the
/// immutable delivery identity while exposing explicit byte continuation
/// metadata; the byte boundaries are always valid UTF-8 boundaries.
pub const ParentDeliveryPart = struct {
    sequence: u64,
    revision: u64,
    id: []u8,
    source_id: []u8,
    target_id: []u8,
    work_id: ?[]u8 = null,
    operation_id: ?[]u8 = null,
    timestamp_ms: i64,
    payload: ParentDeliveryPayload,

    pub fn deinit(self: *ParentDeliveryPart, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.source_id);
        alloc.free(self.target_id);
        if (self.work_id) |value| alloc.free(value);
        if (self.operation_id) |value| alloc.free(value);
        switch (self.payload) {
            .message => |value| alloc.free(value.content),
            .milestone => |value| alloc.free(value),
            .approval => |value| alloc.free(value.label),
            .tool_activity => |value| alloc.free(value.tool_name),
            .terminal, .interval, .retention_gap => {},
        }
        self.* = undefined;
    }

    pub fn clone(self: ParentDeliveryPart, alloc: Allocator) !ParentDeliveryPart {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const source_id = try alloc.dupe(u8, self.source_id);
        errdefer alloc.free(source_id);
        const target_id = try alloc.dupe(u8, self.target_id);
        errdefer alloc.free(target_id);
        const work_id = if (self.work_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (work_id) |value| alloc.free(value);
        const operation_id = if (self.operation_id) |value| try alloc.dupe(u8, value) else null;
        errdefer if (operation_id) |value| alloc.free(value);
        return .{
            .sequence = self.sequence,
            .revision = self.revision,
            .id = id,
            .source_id = source_id,
            .target_id = target_id,
            .work_id = work_id,
            .operation_id = operation_id,
            .timestamp_ms = self.timestamp_ms,
            .payload = switch (self.payload) {
                .message => |value| .{ .message = .{
                    .logical_message_id = id,
                    .offset = value.offset,
                    .end_offset = value.end_offset,
                    .total_bytes = value.total_bytes,
                    .more = value.more,
                    .content = try alloc.dupe(u8, value.content),
                } },
                .milestone => |value| .{ .milestone = try alloc.dupe(u8, value) },
                .terminal => |value| .{ .terminal = value },
                .interval => |value| .{ .interval = .{
                    .state = value.state,
                    .coalesced_ticks = value.coalesced_ticks,
                } },
                .approval => |value| .{ .approval = .{
                    .label = try alloc.dupe(u8, value.label),
                    .truncated = value.truncated,
                    .total_bytes = value.total_bytes,
                } },
                .tool_activity => |value| .{ .tool_activity = .{
                    .tool_name = try alloc.dupe(u8, value.tool_name),
                    .phase = value.phase,
                } },
                .retention_gap => |value| .{ .retention_gap = value },
            },
        };
    }
};

pub const ParentPage = struct {
    generation: u64,
    deliveries: []ParentDeliveryPart,
    through_sequence: u64,
    has_more: bool,

    pub fn deinit(self: *ParentPage, alloc: Allocator) void {
        freeSlice(ParentDeliveryPart, alloc, self.deliveries);
        self.* = undefined;
    }
};

pub const ParentAcknowledgement = struct {
    sequence: u64,
    delivery_id: []const u8,
    start_offset: u64,
    end_offset: u64,
    total_bytes: u64,
};

const parent_retention_gap_id = "fx-retention-gap";

pub fn acknowledgementForParentPart(
    part: ParentDeliveryPart,
) ParentAcknowledgement {
    return .{
        .sequence = part.sequence,
        .delivery_id = part.id,
        .start_offset = switch (part.payload) {
            .message => |message| message.offset,
            else => 0,
        },
        .end_offset = switch (part.payload) {
            .message => |message| message.end_offset,
            else => 0,
        },
        .total_bytes = switch (part.payload) {
            .message => |message| message.total_bytes,
            else => 0,
        },
    };
}

pub const ParentDeliveryState = enum {
    idle,
    running,
    turn_boundary,
};

pub const BoundaryDecision = enum { wait, inject };

/// Parent-model delivery is permitted only while constructing a new turn.
pub fn decideParentBoundary(state: ParentDeliveryState) BoundaryDecision {
    return switch (state) {
        .idle, .running => .wait,
        .turn_boundary => .inject,
    };
}

/// Returns an owned bounded page beginning after this consumer/target route's
/// durable acknowledgement. Other targets never consume page capacity.
pub fn pageForTarget(
    alloc: Allocator,
    ledger: Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    expected_generation: ?u64,
    limit: usize,
) MutationError!Page {
    return pageForProjection(
        alloc,
        ledger,
        consumer_id,
        target_id,
        .human,
        expected_generation,
        limit,
    );
}

/// Returns up to `limit` owned parent-visible parts in ledger order. An
/// unfinished message part ends the page so no later sequence can overtake it.
pub fn pageForParentTurn(
    alloc: Allocator,
    ledger: Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    expected_generation: ?u64,
    limit: usize,
) MutationError!ParentPage {
    try validateConsumerId(consumer_id);
    domain.validateId(target_id) catch return error.InvalidCursor;
    if (limit == 0 or limit > max_delivery_page) return error.InvalidCursor;
    if (expected_generation) |generation| {
        if (generation != ledger.generation) return error.StaleCursor;
    }
    const stored_cursor = findCursor(
        ledger.cursors,
        consumer_id,
        target_id,
        .parent_turn,
    );
    const retention_gap = retentionGapThrough(
        ledger,
        target_id,
        .parent_turn,
    );
    if (retention_gap == 0 and
        (if (stored_cursor) |cursor| cursor.stale else false))
    {
        return error.StaleCursor;
    }
    if ((stored_cursor == null and retention_gap != 0) or
        if (stored_cursor) |cursor| cursor.stale else false)
    {
        var gap = try ownParentRetentionGap(
            alloc,
            ledger.session_id,
            target_id,
            retention_gap,
        );
        errdefer gap.deinit(alloc);
        const deliveries = try alloc.alloc(ParentDeliveryPart, 1);
        deliveries[0] = gap;
        return .{
            .generation = ledger.generation,
            .deliveries = deliveries,
            .through_sequence = retention_gap,
            .has_more = hasParentDeliveryAfter(
                ledger.deliveries,
                target_id,
                retention_gap,
            ),
        };
    }
    const acknowledged = if (stored_cursor) |cursor|
        cursor.acknowledged_sequence
    else
        0;
    const partial_sequence = if (stored_cursor) |cursor|
        cursor.partial_message_sequence
    else
        0;
    const partial_offset = if (stored_cursor) |cursor|
        cursor.partial_message_offset
    else
        0;
    var awaiting_partial = partial_sequence != 0;
    var selected: std.ArrayList(ParentDeliveryPart) = .empty;
    errdefer {
        for (selected.items) |*delivery| delivery.deinit(alloc);
        selected.deinit(alloc);
    }
    var through_sequence = acknowledged;
    var has_more = false;
    for (ledger.deliveries) |delivery| {
        if (delivery.sequence <= acknowledged or
            !std.mem.eql(u8, delivery.target_id, target_id) or
            !visibleInProjection(delivery, .parent_turn)) continue;
        if (awaiting_partial) {
            if (delivery.sequence != partial_sequence) continue;
            awaiting_partial = false;
        }
        if (selected.items.len == limit) {
            has_more = true;
            break;
        }
        var part = try ownParentDeliveryPart(
            alloc,
            delivery,
            if (delivery.sequence == partial_sequence) partial_offset else 0,
        );
        errdefer part.deinit(alloc);
        try selected.append(alloc, part);
        through_sequence = part.sequence;
        if (part.payload == .message and part.payload.message.more) {
            has_more = true;
            break;
        }
    }
    if (awaiting_partial) return error.StaleCursor;
    return .{
        .generation = ledger.generation,
        .deliveries = try selected.toOwnedSlice(alloc),
        .through_sequence = through_sequence,
        .has_more = has_more,
    };
}

fn pageForProjection(
    alloc: Allocator,
    ledger: Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    projection: Projection,
    expected_generation: ?u64,
    limit: usize,
) MutationError!Page {
    try validateConsumerId(consumer_id);
    domain.validateId(target_id) catch return error.InvalidCursor;
    if (limit == 0 or limit > max_delivery_page) return error.InvalidCursor;
    if (expected_generation) |generation| {
        if (generation != ledger.generation) return error.StaleCursor;
    }
    const stored_cursor = findCursor(
        ledger.cursors,
        consumer_id,
        target_id,
        projection,
    );
    const retention_gap = retentionGapThrough(ledger, target_id, projection);
    if (retention_gap == 0 and
        (if (stored_cursor) |cursor| cursor.stale else false))
    {
        return error.StaleCursor;
    }
    const gap_pending = (stored_cursor == null and retention_gap != 0) or
        if (stored_cursor) |cursor| cursor.stale else false;
    const acknowledged = if (gap_pending)
        retention_gap
    else if (stored_cursor) |cursor|
        cursor.acknowledged_sequence
    else
        0;
    var selected: std.ArrayList(Delivery) = .empty;
    errdefer {
        for (selected.items) |*delivery| delivery.deinit(alloc);
        selected.deinit(alloc);
    }
    var has_more = false;
    var through_sequence = acknowledged;
    for (ledger.deliveries) |delivery| {
        if (delivery.sequence <= acknowledged or
            !std.mem.eql(u8, delivery.target_id, target_id) or
            !visibleInProjection(delivery, projection)) continue;
        if (selected.items.len == limit) {
            has_more = true;
            break;
        }
        var cloned = try delivery.clone(alloc);
        errdefer cloned.deinit(alloc);
        try selected.append(alloc, cloned);
        through_sequence = delivery.sequence;
    }
    return .{
        .generation = ledger.generation,
        .deliveries = try selected.toOwnedSlice(alloc),
        .through_sequence = through_sequence,
        .has_more = has_more,
        .retention_gap_through = if (gap_pending) retention_gap else null,
    };
}

fn hasParentDeliveryAfter(
    deliveries: []const Delivery,
    target_id: []const u8,
    sequence: u64,
) bool {
    for (deliveries) |delivery| {
        if (delivery.sequence > sequence and
            std.mem.eql(u8, delivery.target_id, target_id) and
            visibleInProjection(delivery, .parent_turn))
        {
            return true;
        }
    }
    return false;
}

fn selectParentDeliveryPart(
    alloc: Allocator,
    deliveries: []const Delivery,
    target_id: []const u8,
    cursor: ?ConsumerCursor,
) MutationError!?ParentDeliveryPart {
    const acknowledged = if (cursor) |value| value.acknowledged_sequence else 0;
    const partial_sequence = if (cursor) |value|
        value.partial_message_sequence
    else
        0;
    const partial_offset = if (cursor) |value| value.partial_message_offset else 0;
    for (deliveries) |delivery| {
        if (delivery.sequence <= acknowledged or
            !std.mem.eql(u8, delivery.target_id, target_id) or
            !visibleInProjection(delivery, .parent_turn)) continue;
        if (partial_sequence != 0 and delivery.sequence != partial_sequence) {
            continue;
        }
        return try ownParentDeliveryPart(
            alloc,
            delivery,
            if (delivery.sequence == partial_sequence) partial_offset else 0,
        );
    }
    if (partial_sequence != 0) return error.StaleCursor;
    return null;
}

fn ownParentDeliveryPart(
    alloc: Allocator,
    delivery: Delivery,
    raw_start_offset: u64,
) MutationError!ParentDeliveryPart {
    const id = try alloc.dupe(u8, delivery.id);
    errdefer alloc.free(id);
    const source_id = try alloc.dupe(u8, delivery.source_id);
    errdefer alloc.free(source_id);
    const target_id = try alloc.dupe(u8, delivery.target_id);
    errdefer alloc.free(target_id);
    const work_id = if (delivery.work_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (work_id) |value| alloc.free(value);
    const operation_id = if (delivery.operation_id) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (operation_id) |value| alloc.free(value);
    var part = ParentDeliveryPart{
        .sequence = delivery.sequence,
        .revision = delivery.revision,
        .id = id,
        .source_id = source_id,
        .target_id = target_id,
        .work_id = work_id,
        .operation_id = operation_id,
        .timestamp_ms = delivery.timestamp_ms,
        .payload = undefined,
    };
    part.payload = switch (delivery.payload) {
        .message => |content| blk: {
            const start = std.math.cast(usize, raw_start_offset) orelse
                return error.InvalidCursor;
            if (start >= content.len or !utf8Boundary(content, start)) {
                return error.InvalidCursor;
            }
            const end = selectMessagePartEnd(delivery, start) orelse
                return error.InvalidDelivery;
            break :blk .{ .message = .{
                .logical_message_id = id,
                .offset = raw_start_offset,
                .end_offset = @intCast(end),
                .total_bytes = @intCast(content.len),
                .more = end != content.len,
                .content = try alloc.dupe(u8, content[start..end]),
            } };
        },
        .milestone => |value| .{ .milestone = try alloc.dupe(u8, value) },
        .terminal => |value| .{ .terminal = value },
        .interval => |value| .{ .interval = .{
            .state = value.state,
            .coalesced_ticks = value.coalesced_ticks,
        } },
        .approval => |value| blk: {
            const end = selectApprovalPartEnd(delivery) orelse
                return error.InvalidDelivery;
            break :blk .{ .approval = .{
                .label = try alloc.dupe(u8, value[0..end]),
                .truncated = end != value.len,
                .total_bytes = @intCast(value.len),
            } };
        },
        .tool_activity => return error.InvalidDelivery,
    };
    return part;
}

fn ownParentRetentionGap(
    alloc: Allocator,
    source_id_value: []const u8,
    target_id_value: []const u8,
    evicted_through: u64,
) MutationError!ParentDeliveryPart {
    if (evicted_through == 0) return error.InvalidCursor;
    const id = try alloc.dupe(u8, parent_retention_gap_id);
    errdefer alloc.free(id);
    const source_id = try alloc.dupe(u8, source_id_value);
    errdefer alloc.free(source_id);
    const target_id = try alloc.dupe(u8, target_id_value);
    return .{
        .sequence = evicted_through,
        .revision = 0,
        .id = id,
        .source_id = source_id,
        .target_id = target_id,
        .timestamp_ms = 0,
        .payload = .{ .retention_gap = .{
            .evicted_through = evicted_through,
        } },
    };
}

/// Pure acknowledgement reduction. Repeating the same acknowledgement is safe.
pub fn acknowledgeTarget(
    alloc: Allocator,
    ledger: *Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    sequence: u64,
) MutationError!void {
    return acknowledgeProjection(
        alloc,
        ledger,
        consumer_id,
        target_id,
        .human,
        sequence,
    );
}

pub fn acknowledgeParentTurn(
    alloc: Allocator,
    ledger: *Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    acknowledgement: ParentAcknowledgement,
) MutationError!void {
    try validateConsumerId(consumer_id);
    domain.validateId(target_id) catch return error.InvalidCursor;
    if (acknowledgement.sequence == 0 or
        acknowledgement.sequence >= ledger.next_sequence)
    {
        return error.InvalidCursor;
    }
    const existing = findCursor(
        ledger.cursors,
        consumer_id,
        target_id,
        .parent_turn,
    );
    const retention_gap = retentionGapThrough(
        ledger.*,
        target_id,
        .parent_turn,
    );
    if (std.mem.eql(
        u8,
        acknowledgement.delivery_id,
        parent_retention_gap_id,
    )) {
        if (acknowledgement.sequence != retention_gap or
            acknowledgement.start_offset != 0 or
            acknowledgement.end_offset != 0 or
            acknowledgement.total_bytes != 0)
        {
            return error.InvalidCursor;
        }
        if (existing) |cursor| {
            if (!cursor.stale and
                cursor.acknowledged_sequence >= retention_gap)
            {
                return;
            }
            if (!cursor.stale) return error.InvalidCursor;
        }
        try recoverCursor(
            alloc,
            ledger,
            consumer_id,
            target_id,
            .parent_turn,
            retention_gap,
        );
        return;
    }
    if (existing) |cursor| {
        if (cursor.stale) return error.StaleCursor;
        if (parentAcknowledgementAlreadyApplied(
            ledger.deliveries,
            cursor,
            target_id,
            acknowledgement,
        )) return;
    } else if (retention_gap != 0) {
        return error.StaleCursor;
    }

    var expected = (try selectParentDeliveryPart(
        alloc,
        ledger.deliveries,
        target_id,
        existing,
    )) orelse return error.InvalidCursor;
    defer expected.deinit(alloc);
    if (!parentAcknowledgementMatches(expected, acknowledgement)) {
        return error.InvalidCursor;
    }
    const next_generation = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    const more = switch (expected.payload) {
        .message => |message| message.more,
        else => false,
    };
    if (findCursorMutable(
        ledger.cursors,
        consumer_id,
        target_id,
        .parent_turn,
    )) |cursor| {
        if (more) {
            cursor.partial_message_sequence = acknowledgement.sequence;
            cursor.partial_message_offset = acknowledgement.end_offset;
        } else {
            cursor.acknowledged_sequence = acknowledgement.sequence;
            cursor.partial_message_sequence = 0;
            cursor.partial_message_offset = 0;
        }
        ledger.generation = next_generation;
        return;
    }
    if (ledger.cursors.len == max_consumers) return error.CapacityExceeded;
    const candidate = ConsumerCursor{
        .consumer_id = @constCast(consumer_id),
        .target_id = @constCast(target_id),
        .projection = .parent_turn,
        .acknowledged_sequence = if (more) 0 else acknowledgement.sequence,
        .partial_message_sequence = if (more) acknowledgement.sequence else 0,
        .partial_message_offset = if (more) acknowledgement.end_offset else 0,
        .stale = false,
    };
    if (!cursorAdmissionFits(ledger.*, candidate)) return error.CapacityExceeded;
    const owned_id = try alloc.dupe(u8, consumer_id);
    errdefer alloc.free(owned_id);
    const owned_target_id = try alloc.dupe(u8, target_id);
    errdefer alloc.free(owned_target_id);
    ledger.cursors = try alloc.realloc(ledger.cursors, ledger.cursors.len + 1);
    ledger.cursors[ledger.cursors.len - 1] = candidate;
    ledger.cursors[ledger.cursors.len - 1].consumer_id = owned_id;
    ledger.cursors[ledger.cursors.len - 1].target_id = owned_target_id;
    ledger.generation = next_generation;
}

fn parentAcknowledgementMatches(
    part: ParentDeliveryPart,
    acknowledgement: ParentAcknowledgement,
) bool {
    if (part.sequence != acknowledgement.sequence) return false;
    if (!std.mem.eql(u8, part.id, acknowledgement.delivery_id)) return false;
    return switch (part.payload) {
        .message => |message| message.offset == acknowledgement.start_offset and
            message.end_offset == acknowledgement.end_offset and
            message.total_bytes == acknowledgement.total_bytes,
        else => acknowledgement.start_offset == 0 and
            acknowledgement.end_offset == 0 and
            acknowledgement.total_bytes == 0,
    };
}

fn parentAcknowledgementAlreadyApplied(
    deliveries: []const Delivery,
    cursor: ConsumerCursor,
    target_id: []const u8,
    acknowledgement: ParentAcknowledgement,
) bool {
    const delivery = findDeliveryBySequence(
        deliveries,
        acknowledgement.sequence,
    ) orelse return false;
    if (!std.mem.eql(u8, delivery.id, acknowledgement.delivery_id) or
        !std.mem.eql(u8, delivery.target_id, target_id) or
        !visibleInProjection(delivery, .parent_turn))
    {
        return false;
    }
    switch (delivery.payload) {
        .message => |content| {
            if (acknowledgement.total_bytes != content.len or
                acknowledgement.start_offset >= acknowledgement.end_offset or
                acknowledgement.end_offset > content.len)
            {
                return false;
            }
            const start = std.math.cast(usize, acknowledgement.start_offset) orelse
                return false;
            const end = std.math.cast(usize, acknowledgement.end_offset) orelse
                return false;
            if (!utf8Boundary(content, start) or !utf8Boundary(content, end)) {
                return false;
            }
            const applied_through = if (cursor.acknowledged_sequence >=
                acknowledgement.sequence)
                content.len
            else if (cursor.partial_message_sequence == acknowledgement.sequence)
                std.math.cast(usize, cursor.partial_message_offset) orelse
                    return false
            else
                return false;
            var offset: usize = 0;
            while (offset < applied_through) {
                const part_end = selectMessagePartEnd(delivery, offset) orelse
                    return false;
                if (offset == start and part_end == end) return true;
                if (part_end <= offset or part_end > applied_through) return false;
                offset = part_end;
            }
            return false;
        },
        else => return cursor.acknowledged_sequence >= acknowledgement.sequence and
            acknowledgement.start_offset == 0 and
            acknowledgement.end_offset == 0 and
            acknowledgement.total_bytes == 0,
    }
}

fn findDeliveryBySequence(
    deliveries: []const Delivery,
    sequence: u64,
) ?Delivery {
    for (deliveries) |delivery| {
        if (delivery.sequence == sequence) return delivery;
    }
    return null;
}

fn acknowledgeProjection(
    alloc: Allocator,
    ledger: *Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    projection: Projection,
    sequence: u64,
) MutationError!void {
    try validateConsumerId(consumer_id);
    domain.validateId(target_id) catch return error.InvalidCursor;
    if (sequence >= ledger.next_sequence) return error.InvalidCursor;
    const retention_gap = retentionGapThrough(
        ledger.*,
        target_id,
        projection,
    );
    for (ledger.cursors) |*cursor| {
        if (!std.mem.eql(u8, cursor.consumer_id, consumer_id) or
            !std.mem.eql(u8, cursor.target_id, target_id) or
            cursor.projection != projection) continue;
        if (cursor.stale) {
            if (!sequenceRecoversRetention(
                ledger.*,
                target_id,
                projection,
                retention_gap,
                sequence,
            )) return error.StaleCursor;
            const next_generation = std.math.add(u64, ledger.generation, 1) catch
                return error.GenerationExhausted;
            cursor.acknowledged_sequence = sequence;
            cursor.partial_message_sequence = 0;
            cursor.partial_message_offset = 0;
            cursor.stale = false;
            ledger.generation = next_generation;
            return;
        }
        if (sequence < cursor.acknowledged_sequence) return error.StaleCursor;
        if (sequence == cursor.acknowledged_sequence) return;
        if (!deliverySequenceTargets(
            ledger.deliveries,
            sequence,
            target_id,
            projection,
        )) {
            return error.InvalidCursor;
        }
        const next_generation = std.math.add(u64, ledger.generation, 1) catch
            return error.GenerationExhausted;
        cursor.acknowledged_sequence = sequence;
        ledger.generation = next_generation;
        return;
    }
    if (retention_gap != 0) {
        if (!sequenceRecoversRetention(
            ledger.*,
            target_id,
            projection,
            retention_gap,
            sequence,
        )) return error.StaleCursor;
        try recoverCursor(
            alloc,
            ledger,
            consumer_id,
            target_id,
            projection,
            sequence,
        );
        return;
    }
    if (ledger.cursors.len == max_consumers) return error.CapacityExceeded;
    const candidate = ConsumerCursor{
        .consumer_id = @constCast(consumer_id),
        .target_id = @constCast(target_id),
        .projection = projection,
        .acknowledged_sequence = sequence,
        .partial_message_sequence = 0,
        .partial_message_offset = 0,
        .stale = false,
    };
    if (!cursorAdmissionFits(ledger.*, candidate)) {
        return error.CapacityExceeded;
    }
    const next_generation = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    const owned_id = try alloc.dupe(u8, consumer_id);
    errdefer alloc.free(owned_id);
    const owned_target_id = try alloc.dupe(u8, target_id);
    errdefer alloc.free(owned_target_id);
    if (sequence != 0 and
        !deliverySequenceTargets(
            ledger.deliveries,
            sequence,
            target_id,
            projection,
        ))
    {
        return error.InvalidCursor;
    }
    ledger.cursors = try alloc.realloc(ledger.cursors, ledger.cursors.len + 1);
    ledger.cursors[ledger.cursors.len - 1] = .{
        .consumer_id = owned_id,
        .target_id = owned_target_id,
        .projection = projection,
        .acknowledged_sequence = sequence,
        .partial_message_sequence = 0,
        .partial_message_offset = 0,
        .stale = false,
    };
    ledger.generation = next_generation;
}

fn sequenceRecoversRetention(
    ledger: Ledger,
    target_id: []const u8,
    projection: Projection,
    retention_gap: u64,
    sequence: u64,
) bool {
    if (retention_gap == 0 or sequence < retention_gap) return false;
    return sequence == retention_gap or deliverySequenceTargets(
        ledger.deliveries,
        sequence,
        target_id,
        projection,
    );
}

fn recoverCursor(
    alloc: Allocator,
    ledger: *Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    projection: Projection,
    sequence: u64,
) MutationError!void {
    const next_generation = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    if (findCursorMutable(
        ledger.cursors,
        consumer_id,
        target_id,
        projection,
    )) |cursor| {
        cursor.acknowledged_sequence = sequence;
        cursor.partial_message_sequence = 0;
        cursor.partial_message_offset = 0;
        cursor.stale = false;
        ledger.generation = next_generation;
        return;
    }
    if (ledger.cursors.len == max_consumers) return error.CapacityExceeded;
    const candidate = ConsumerCursor{
        .consumer_id = @constCast(consumer_id),
        .target_id = @constCast(target_id),
        .projection = projection,
        .acknowledged_sequence = sequence,
        .partial_message_sequence = 0,
        .partial_message_offset = 0,
        .stale = false,
    };
    if (!cursorAdmissionFits(ledger.*, candidate)) {
        return error.CapacityExceeded;
    }
    const owned_id = try alloc.dupe(u8, consumer_id);
    errdefer alloc.free(owned_id);
    const owned_target_id = try alloc.dupe(u8, target_id);
    errdefer alloc.free(owned_target_id);
    ledger.cursors = try alloc.realloc(ledger.cursors, ledger.cursors.len + 1);
    ledger.cursors[ledger.cursors.len - 1] = candidate;
    ledger.cursors[ledger.cursors.len - 1].consumer_id = owned_id;
    ledger.cursors[ledger.cursors.len - 1].target_id = owned_target_id;
    ledger.generation = next_generation;
}

fn visibleInProjection(delivery: Delivery, projection: Projection) bool {
    return switch (projection) {
        .human => true,
        .parent_turn => switch (delivery.payload) {
            .message, .milestone, .terminal, .interval, .approval => true,
            .tool_activity => false,
        },
    };
}

pub const RenderError = error{
    OutOfMemory,
    TrustedContextTooLarge,
};

/// Returns bounded trusted system context. The caller acknowledges only after
/// this projection has been injected at a parent turn boundary. Each envelope
/// is JSON encoded so child-controlled content cannot escape its data field.
pub fn renderTrustedContext(
    alloc: Allocator,
    deliveries: []const ParentDeliveryPart,
) RenderError![]u8 {
    var buffer: [max_trusted_context_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeTrustedContext(&writer, deliveries) catch
        return error.TrustedContextTooLarge;
    return alloc.dupe(u8, writer.buffered()) catch error.OutOfMemory;
}

fn writeTrustedContext(
    writer: *std.Io.Writer,
    deliveries: []const ParentDeliveryPart,
) !void {
    writer.writeAll("<subagent_deliveries trusted_runtime_context=\"true\">\n") catch
        return error.WriteFailed;
    for (deliveries) |delivery| {
        writer.writeAll("- ") catch return error.WriteFailed;
        std.json.Stringify.value(delivery, .{}, writer) catch
            return error.WriteFailed;
        writer.writeByte('\n') catch return error.WriteFailed;
    }
    writer.writeAll("</subagent_deliveries>\n") catch
        return error.WriteFailed;
}

fn parentDeliveryPartFits(part: ParentDeliveryPart) bool {
    var buffer: [max_trusted_context_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeTrustedContext(&writer, &.{part}) catch return false;
    return true;
}

fn selectMessagePartEnd(delivery: Delivery, start: usize) ?usize {
    const content = delivery.payload.message;
    const full = borrowedParentMessagePart(delivery, start, content.len);
    if (parentDeliveryPartFits(full)) return content.len;

    var low = start;
    var high = content.len;
    while (low < high) {
        var candidate = low + (high - low + 1) / 2;
        candidate = utf8BoundaryAtOrBefore(content, start, candidate);
        if (candidate == low) {
            candidate = utf8NextBoundary(content, low) orelse return null;
        }
        if (candidate > high) return null;
        const probe = borrowedParentMessagePart(delivery, start, candidate);
        if (parentDeliveryPartFits(probe)) {
            low = candidate;
        } else {
            high = utf8BoundaryBefore(content, candidate) orelse return null;
        }
    }
    return if (low > start) low else null;
}

fn selectApprovalPartEnd(delivery: Delivery) ?usize {
    const label = delivery.payload.approval;
    const full = borrowedParentApprovalPart(delivery, label.len, false);
    if (parentDeliveryPartFits(full)) return label.len;
    if (!parentDeliveryPartFits(borrowedParentApprovalPart(delivery, 0, true))) {
        return null;
    }

    var low: usize = 0;
    var high = utf8BoundaryBefore(label, label.len) orelse return 0;
    while (low < high) {
        var candidate = low + (high - low + 1) / 2;
        candidate = utf8BoundaryAtOrBefore(label, low, candidate);
        if (candidate == low) {
            candidate = utf8NextBoundary(label, low) orelse return low;
        }
        if (candidate > high) return low;
        const probe = borrowedParentApprovalPart(delivery, candidate, true);
        if (parentDeliveryPartFits(probe)) {
            low = candidate;
        } else {
            high = utf8BoundaryBefore(label, candidate) orelse return low;
        }
    }
    return low;
}

fn borrowedParentApprovalPart(
    delivery: Delivery,
    end: usize,
    truncated: bool,
) ParentDeliveryPart {
    return .{
        .sequence = delivery.sequence,
        .revision = delivery.revision,
        .id = delivery.id,
        .source_id = delivery.source_id,
        .target_id = delivery.target_id,
        .work_id = delivery.work_id,
        .operation_id = delivery.operation_id,
        .timestamp_ms = delivery.timestamp_ms,
        .payload = .{ .approval = .{
            .label = delivery.payload.approval[0..end],
            .truncated = truncated,
            .total_bytes = @intCast(delivery.payload.approval.len),
        } },
    };
}

fn borrowedParentMessagePart(
    delivery: Delivery,
    start: usize,
    end: usize,
) ParentDeliveryPart {
    return .{
        .sequence = delivery.sequence,
        .revision = delivery.revision,
        .id = delivery.id,
        .source_id = delivery.source_id,
        .target_id = delivery.target_id,
        .work_id = delivery.work_id,
        .operation_id = delivery.operation_id,
        .timestamp_ms = delivery.timestamp_ms,
        .payload = .{ .message = .{
            .logical_message_id = delivery.id,
            .offset = @intCast(start),
            .end_offset = @intCast(end),
            .total_bytes = @intCast(delivery.payload.message.len),
            .more = end != delivery.payload.message.len,
            .content = delivery.payload.message[start..end],
        } },
    };
}

fn utf8Boundary(content: []const u8, offset: usize) bool {
    return offset <= content.len and
        (offset == content.len or (content[offset] & 0xc0) != 0x80);
}

fn utf8BoundaryAtOrBefore(
    content: []const u8,
    start: usize,
    raw_offset: usize,
) usize {
    var offset = @min(raw_offset, content.len);
    while (offset > start and !utf8Boundary(content, offset)) : (offset -= 1) {}
    return offset;
}

fn utf8BoundaryBefore(content: []const u8, offset: usize) ?usize {
    if (offset == 0) return null;
    var prior = offset - 1;
    while (prior != 0 and !utf8Boundary(content, prior)) : (prior -= 1) {}
    return prior;
}

fn utf8NextBoundary(content: []const u8, offset: usize) ?usize {
    if (offset >= content.len) return null;
    const sequence_len = std.unicode.utf8ByteSequenceLength(content[offset]) catch
        return null;
    const next = std.math.add(usize, offset, sequence_len) catch return null;
    return if (next <= content.len) next else null;
}

pub const PollDecision = union(enum) {
    none,
    emit: u32,
    stop,
};

/// Pure stored-snapshot polling. It never schedules work or invokes a model.
pub fn pollNotification(
    work: *WorkNotification,
    state: domain.State,
    now_ms: i64,
) MutationError!PollDecision {
    if (work.stopped) return .none;
    if (isTerminal(state) and hasStop(work.policy.stop_conditions, .terminal)) {
        work.stopped = true;
        work.next_due_ms = null;
        return .stop;
    }
    if (work.policy.report_duration_ms) |duration| {
        const duration_i64 = std.math.cast(i64, duration) orelse
            return error.InvalidNotification;
        const deadline = std.math.add(i64, work.started_at_ms, duration_i64) catch
            return error.InvalidNotification;
        if (now_ms >= deadline and hasStop(work.policy.stop_conditions, .duration_elapsed)) {
            work.stopped = true;
            work.next_due_ms = null;
            return .stop;
        }
    }
    const due = work.next_due_ms orelse return .none;
    if (now_ms < due) return .none;
    const interval = work.policy.report_interval_ms orelse
        return error.InvalidNotification;
    const elapsed = std.math.sub(i64, now_ms, due) catch
        return error.InvalidNotification;
    const elapsed_u64 = std.math.cast(u64, elapsed) orelse
        return error.InvalidNotification;
    const ticks_u64 = elapsed_u64 / interval + 1;
    const ticks = std.math.cast(u32, @min(ticks_u64, std.math.maxInt(u32))) orelse
        return error.InvalidNotification;
    const advance_u64 = std.math.mul(u64, ticks_u64, interval) catch
        return error.InvalidNotification;
    const advance = std.math.cast(i64, advance_u64) orelse
        return error.InvalidNotification;
    work.next_due_ms = std.math.add(i64, due, advance) catch null;
    if (work.next_due_ms == null) work.stopped = true;
    return .{ .emit = ticks };
}

/// Returns the next time this stored policy needs evaluation. Duration expiry
/// can precede the next report interval, so callers must schedule the earlier
/// durable boundary.
pub fn nextNotificationCheck(work: WorkNotification) MutationError!?i64 {
    if (work.stopped) return null;
    var next_check = work.next_due_ms orelse return null;
    if (work.policy.report_duration_ms) |duration| {
        if (!hasStop(work.policy.stop_conditions, .duration_elapsed)) {
            return next_check;
        }
        const duration_i64 = std.math.cast(i64, duration) orelse
            return error.InvalidNotification;
        const deadline = std.math.add(i64, work.started_at_ms, duration_i64) catch
            return error.InvalidNotification;
        next_check = @min(next_check, deadline);
    }
    return next_check;
}

pub fn terminalEnabled(policy: domain.NotificationPolicy, state: domain.State) bool {
    return switch (state) {
        .completed => policy.terminal.completed,
        .failed => policy.terminal.failed,
        .cancelled => policy.terminal.cancelled,
        else => false,
    };
}

/// Applies terminal stop policy independently from terminal payload delivery.
/// Returns true only when durable notification state changed.
pub fn applyTerminalStop(work: *WorkNotification, state: domain.State) bool {
    if (!isTerminal(state) or !hasStop(work.policy.stop_conditions, .terminal) or
        work.stopped) return false;
    work.stopped = true;
    work.next_due_ms = null;
    return true;
}

pub fn milestoneDeclared(work: WorkNotification, name: []const u8) bool {
    for (work.policy.milestones) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Captures the notification policy for one admitted work item. Repeating an
/// admission replaces only a not-yet-running stale capture for the same ID.
pub fn upsertWorkNotification(
    alloc: Allocator,
    ledger: *Ledger,
    work_id: []const u8,
    policy: domain.NotificationPolicy,
    started_at_ms: i64,
) MutationError!void {
    domain.validateOperationId(work_id) catch return error.InvalidNotification;
    validatePolicy(policy) catch return error.InvalidNotification;
    const interval_i64 = if (policy.report_interval_ms) |value|
        std.math.cast(i64, value) orelse return error.InvalidNotification
    else
        null;
    const next_due = if (interval_i64) |value|
        std.math.add(i64, started_at_ms, value) catch
            return error.InvalidNotification
    else
        null;
    const next_generation = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    const owned_work_id = try alloc.dupe(u8, work_id);
    const owned_policy = policy.clone(alloc) catch |err| {
        alloc.free(owned_work_id);
        return err;
    };
    var replacement = WorkNotification{
        .work_id = owned_work_id,
        .policy = owned_policy,
        .started_at_ms = started_at_ms,
        .next_due_ms = next_due,
    };
    errdefer replacement.deinit(alloc);
    if (!workAdmissionFits(ledger.*, replacement)) {
        return error.CapacityExceeded;
    }
    for (ledger.work_notifications) |*work| {
        if (!std.mem.eql(u8, work.work_id, work_id)) continue;
        work.deinit(alloc);
        work.* = replacement;
        ledger.generation = next_generation;
        return;
    }
    try compactStoppedWorkNotifications(alloc, ledger);
    ledger.work_notifications = try alloc.realloc(
        ledger.work_notifications,
        ledger.work_notifications.len + 1,
    );
    ledger.work_notifications[ledger.work_notifications.len - 1] = replacement;
    ledger.generation = next_generation;
}

/// Drops notification captures whose stop state is already durable. Active
/// entries are moved without cloning, so their policy and scheduling state are
/// byte-for-byte unchanged.
pub fn compactStoppedWorkNotifications(
    alloc: Allocator,
    ledger: *Ledger,
) error{OutOfMemory}!void {
    var active_count: usize = 0;
    for (ledger.work_notifications) |work| {
        if (!work.stopped) active_count += 1;
    }
    if (active_count == ledger.work_notifications.len) return;
    const retained = try alloc.alloc(WorkNotification, active_count);
    var retained_index: usize = 0;
    for (ledger.work_notifications) |*work| {
        if (work.stopped) {
            work.deinit(alloc);
            continue;
        }
        retained[retained_index] = work.*;
        retained_index += 1;
    }
    alloc.free(ledger.work_notifications);
    ledger.work_notifications = retained;
}

/// Marks every captured work policy stopped before the effectful owner
/// compacts and commits the ledger. Returns the number changed.
pub fn stopAllWorkNotifications(ledger: *Ledger) usize {
    var changed: usize = 0;
    for (ledger.work_notifications) |*work| {
        if (stopWorkNotification(work)) changed += 1;
    }
    return changed;
}

pub fn stopWorkNotification(work: *WorkNotification) bool {
    if (work.stopped) return false;
    work.stopped = true;
    work.next_due_ms = null;
    return true;
}

/// Drops approval history only after it can no longer authorize an effect.
/// Pending and allow-once approvals remain durable, and the newest resolved
/// approval is retained until a later store mutation makes its wakeup safe.
pub fn compactResolvedApprovals(
    alloc: Allocator,
    ledger: *Ledger,
) error{OutOfMemory}!bool {
    if (ledger.approvals.len <= 1) return false;
    var retained_count: usize = 0;
    for (ledger.approvals) |approval| {
        if (approval.status == .pending or approval.status == .allowed_once or
            approval.resolved_revision == ledger.generation)
        {
            retained_count += 1;
        }
    }
    if (retained_count == ledger.approvals.len) return false;
    const retained = try alloc.alloc(Approval, retained_count);
    var retained_index: usize = 0;
    for (ledger.approvals) |*approval| {
        if (approval.status == .pending or approval.status == .allowed_once or
            approval.resolved_revision == ledger.generation)
        {
            retained[retained_index] = approval.*;
            retained_index += 1;
        } else {
            approval.deinit(alloc);
        }
    }
    alloc.free(ledger.approvals);
    ledger.approvals = retained;
    return true;
}

/// Evicts one oldest delivery while preserving target/projection-specific
/// retention evidence. Selection is pure; callers remain responsible for
/// measuring the canonical persisted representation between reductions.
pub fn evictOldestDelivery(
    alloc: Allocator,
    ledger: *Ledger,
) MutationError!bool {
    if (ledger.deliveries.len == 0) return false;
    const retained = try alloc.alloc(Delivery, ledger.deliveries.len - 1);
    errdefer alloc.free(retained);
    const evicted = ledger.deliveries[0];
    try recordRetentionLoss(alloc, ledger, evicted, null);
    markStaleCursorsForEviction(ledger.cursors, evicted);
    @memcpy(retained, ledger.deliveries[1..]);
    ledger.deliveries[0].deinit(alloc);
    alloc.free(ledger.deliveries);
    ledger.deliveries = retained;
    return true;
}

pub fn findWorkNotification(
    notifications: []WorkNotification,
    work_id: []const u8,
) ?*WorkNotification {
    for (notifications) |*work| {
        if (std.mem.eql(u8, work.work_id, work_id)) return work;
    }
    return null;
}

pub const RelationshipApprovalInput = struct {
    action: domain.RelationshipAction,
    prospective_parent_id: []const u8,
    operation_id: []const u8,
};

pub const ApprovalInput = struct {
    id: []const u8,
    kind: ApprovalKind,
    child_id: []const u8,
    root_id: []const u8,
    work_id: ?[]const u8,
    relationship: ?RelationshipApprovalInput = null,
    prepared_fingerprint: [32]u8,
    label: []const u8,
    explanation: ?[]const u8,
    command: ?[]const u8 = null,
    file: ?permission_request.FileApprovalRequest = null,
    grants: []const types.PermissionGrant,
    created_at_ms: i64,
    operation_identity_admitted: bool = false,
};

/// Canonical immutable request identity. Grants are hashed as a sorted set so
/// equivalent permission scopes replay regardless of input ordering.
pub fn approvalIdentityFingerprint(input: ApprovalInput) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.approval-identity.v2\x00");
    hashString(&hash, @tagName(input.kind));
    hashString(&hash, input.id);
    hashString(&hash, input.child_id);
    hashString(&hash, input.root_id);
    hashOptionalString(&hash, input.work_id);
    if (input.relationship) |relationship| {
        hash.update("relationship\x00");
        hashString(&hash, @tagName(relationship.action));
        hashString(&hash, relationship.prospective_parent_id);
        hashString(&hash, relationship.operation_id);
    } else {
        hash.update("no-relationship\x00");
    }
    hash.update(&input.prepared_fingerprint);
    hashString(&hash, input.label);
    hashOptionalString(&hash, input.explanation);
    if (input.command) |command| {
        hash.update("command-projection\x00");
        hashString(&hash, command);
    }
    hashNormalizedGrants(&hash, input.grants);
    if (input.file) |file| {
        hash.update("file-projection\x00");
        const file_fingerprint = preparedRequestFingerprint(.{
            .label = input.label,
            .explanation = input.explanation,
            .file = file,
            .amendment_allowed = false,
        });
        hash.update(&file_fingerprint);
        if (file.scope == .external_tree) {
            hashString(&hash, file.scope.external_tree);
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub const RegisterApprovalResult = enum { registered, replay };

pub fn registerApproval(
    alloc: Allocator,
    ledger: *Ledger,
    input: ApprovalInput,
) MutationError!RegisterApprovalResult {
    domain.validateOperationId(input.id) catch return error.InvalidApproval;
    domain.validateId(input.child_id) catch return error.InvalidApproval;
    domain.validateId(input.root_id) catch return error.InvalidApproval;
    if (input.work_id) |value| domain.validateOperationId(value) catch
        return error.InvalidApproval;
    validateContent(input.label) catch return error.InvalidApproval;
    if (input.explanation) |value| validateContent(value) catch
        return error.InvalidApproval;
    if (input.command) |value| validateApprovalProjection(value) catch
        return error.InvalidApproval;
    if (input.file) |file| {
        _ = permission_request.fileRequestFootprint(.{
            .label = input.label,
            .explanation = input.explanation,
            .file = file,
            .amendment_allowed = false,
        }) catch return error.InvalidApproval;
    }
    if (input.grants.len > domain.max_admission_items) return error.InvalidApproval;
    for (input.grants) |grant| {
        validateContent(grant.tool_name) catch return error.InvalidApproval;
        validateApprovalProjection(grant.target_path) catch
            return error.InvalidApproval;
    }
    switch (input.kind) {
        .tool => if (input.work_id == null or input.relationship != null) {
            return error.InvalidApproval;
        },
        .relationship => if (input.work_id != null or
            input.relationship == null or input.file != null or
            input.command != null or input.grants.len != 0)
        {
            return error.InvalidApproval;
        },
    }
    if (input.relationship) |relationship| {
        if (relationship.action == .detach) return error.InvalidApproval;
        domain.validateId(relationship.prospective_parent_id) catch
            return error.InvalidApproval;
        domain.validateOperationId(relationship.operation_id) catch
            return error.InvalidApproval;
    }
    const identity_fingerprint = approvalIdentityFingerprint(input);
    for (ledger.approvals) |approval| {
        if (!std.mem.eql(u8, approval.id, input.id)) continue;
        return if (std.mem.eql(
            u8,
            &approval.identity_fingerprint,
            &identity_fingerprint,
        ))
            .replay
        else
            error.ApprovalConflict;
    }
    const next_generation = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    const id = try alloc.dupe(u8, input.id);
    errdefer alloc.free(id);
    const child_id = try alloc.dupe(u8, input.child_id);
    errdefer alloc.free(child_id);
    const root_id = try alloc.dupe(u8, input.root_id);
    errdefer alloc.free(root_id);
    const work_id = if (input.work_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (work_id) |value| alloc.free(value);
    var relationship: ?RelationshipApproval = null;
    if (input.relationship) |value| {
        relationship = try ownRelationshipApproval(alloc, value);
    }
    errdefer if (relationship) |*value| value.deinit(alloc);
    const label = try alloc.dupe(u8, input.label);
    errdefer alloc.free(label);
    const explanation = if (input.explanation) |value| try alloc.dupe(u8, value) else null;
    errdefer if (explanation) |value| alloc.free(value);
    const command = if (input.command) |value| try alloc.dupe(u8, value) else null;
    errdefer if (command) |value| alloc.free(value);
    const file = if (input.file) |value|
        permission_request.dupeFileApprovalRequest(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidApproval,
        }
    else
        null;
    errdefer if (file) |value| {
        permission_request.deinitFileApprovalRequest(alloc, value);
    };
    const grants = try types.dupePermissionGrantSlice(alloc, input.grants);
    errdefer types.freePermissionGrantSlice(alloc, grants);
    const candidate = Approval{
        .id = id,
        .kind = input.kind,
        .child_id = child_id,
        .root_id = root_id,
        .work_id = work_id,
        .relationship = relationship,
        .prepared_fingerprint = input.prepared_fingerprint,
        .identity_fingerprint = identity_fingerprint,
        .label = label,
        .explanation = explanation,
        .command = command,
        .file = file,
        .grants = grants,
        .status = .pending,
        .created_at_ms = input.created_at_ms,
    };
    if (!approvalAdmissionFits(ledger.*, candidate)) {
        return error.CapacityExceeded;
    }
    if (ledger.approvals.len == max_approvals) {
        var removable: ?usize = null;
        for (ledger.approvals, 0..) |approval, index| {
            if (!approvalIsLive(approval)) {
                removable = index;
                break;
            }
        }
        const index = removable orelse return error.CapacityExceeded;
        const retained = try alloc.alloc(Approval, ledger.approvals.len);
        var retained_index: usize = 0;
        for (ledger.approvals, 0..) |approval, approval_index| {
            if (approval_index == index) continue;
            retained[retained_index] = approval;
            retained_index += 1;
        }
        retained[retained_index] = candidate;
        ledger.approvals[index].deinit(alloc);
        alloc.free(ledger.approvals);
        ledger.approvals = retained;
    } else {
        ledger.approvals = try alloc.realloc(
            ledger.approvals,
            ledger.approvals.len + 1,
        );
        ledger.approvals[ledger.approvals.len - 1] = candidate;
    }
    ledger.generation = next_generation;
    return .registered;
}

fn ownRelationshipApproval(
    alloc: Allocator,
    input: RelationshipApprovalInput,
) !RelationshipApproval {
    const prospective_parent_id = try alloc.dupe(u8, input.prospective_parent_id);
    errdefer alloc.free(prospective_parent_id);
    return .{
        .action = input.action,
        .prospective_parent_id = prospective_parent_id,
        .operation_id = try alloc.dupe(u8, input.operation_id),
    };
}

pub fn findApproval(approvals: []Approval, id: []const u8) ?*Approval {
    for (approvals) |*approval| {
        if (std.mem.eql(u8, approval.id, id)) return approval;
    }
    return null;
}

pub fn invalidatePendingApprovals(
    ledger: *Ledger,
    child_id: []const u8,
    status: ApprovalStatus,
    timestamp_ms: i64,
) MutationError!usize {
    if (status != .cancelled and status != .stale) return error.InvalidApproval;
    var changed: usize = 0;
    for (ledger.approvals) |approval| {
        if (approval.status != .pending or
            !std.mem.eql(u8, approval.child_id, child_id)) continue;
        changed += 1;
    }
    if (changed == 0) return 0;
    const revision = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    for (ledger.approvals) |*approval| {
        if (approval.status != .pending or
            !std.mem.eql(u8, approval.child_id, child_id)) continue;
        approval.status = status;
        approval.resolved_at_ms = timestamp_ms;
        approval.resolved_revision = revision;
    }
    ledger.generation = revision;
    return changed;
}

/// Reconciles unresolved tool approvals against canonical work state after a
/// restart. Relationship approvals have no work identity and remain pending.
pub fn reconcilePendingWorkApprovals(
    ledger: *Ledger,
    child_id: []const u8,
    queue: []const domain.QueuedMessage,
    timestamp_ms: i64,
) MutationError!usize {
    var changed: usize = 0;
    for (ledger.approvals) |approval| {
        if (approval.status != .pending or
            !std.mem.eql(u8, approval.child_id, child_id)) continue;
        const work_id = approval.work_id orelse continue;
        if (approvalStatusForWork(queue, work_id) != null) changed += 1;
    }
    if (changed == 0) return 0;
    const revision = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    for (ledger.approvals) |*approval| {
        if (approval.status != .pending or
            !std.mem.eql(u8, approval.child_id, child_id)) continue;
        const work_id = approval.work_id orelse continue;
        const status = approvalStatusForWork(queue, work_id) orelse continue;
        approval.status = status;
        approval.resolved_at_ms = timestamp_ms;
        approval.resolved_revision = revision;
    }
    ledger.generation = revision;
    return changed;
}

fn approvalStatusForWork(
    queue: []const domain.QueuedMessage,
    work_id: []const u8,
) ?ApprovalStatus {
    for (queue) |work| {
        if (!std.mem.eql(u8, work.id, work_id)) continue;
        return switch (work.status) {
            .cancelled => .cancelled,
            .completed, .failed, .interrupted => .stale,
            .pending, .running, .awaiting_approval => null,
        };
    }
    return .stale;
}

pub const LiveAuthority = struct {
    generation: u64,
    root_id: []const u8,
    tools: []const []const u8,
    integrations: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: ?*const session_permission_state.State = null,
    permission_mode: types.PermissionMode = .yolo,
};

pub const ToolAuthorityDecision = enum { allow, ask, deny, unavailable };

/// Applies existing rule/grant precedence to one live authority snapshot.
pub fn decideToolAuthority(
    alloc: Allocator,
    authority: LiveAuthority,
    workspace_root: []const u8,
    tool_name: []const u8,
    target: []const u8,
    target_kind: permissions.PermissionTargetKind,
) !ToolAuthorityDecision {
    if (!contains(authority.tools, tool_name) and
        !contains(authority.integrations, tool_name))
    {
        return .unavailable;
    }
    if (authority.permission_mode == .yolo) return .allow;
    const permission_name = if (target_kind == .command_cwd and
        std.mem.eql(u8, tool_name, "terminal"))
        "run_command"
    else
        tool_name;
    return switch (try permissions.ruleDecisionFor(
        alloc,
        authority.rules,
        workspace_root,
        permission_name,
        target,
        target_kind,
    )) {
        .allow => .allow,
        .deny => .deny,
        .ask => if (permissions.sessionGrantAllowed(authority.grants, permission_name, target)) .allow else .ask,
        .none => if (permissions.sessionGrantAllowed(authority.grants, permission_name, target)) .allow else .ask,
    };
}

pub const ApprovalResponse = struct {
    request_id: []const u8,
    child_id: []const u8,
    decision: types.ToolPermissionDecision,
    timestamp_ms: i64,
};

pub const ApprovalContext = struct {
    attached: bool,
    child_cancelled: bool,
    child_closed: bool,
};

pub const ApprovalDecision = union(enum) {
    reject: enum { stale, wrong_child, detached, cancelled, closed, resolved, invalid },
    accept_once,
    accept_always,
    deny,
};

/// Pure exact-once response decision. Effects must commit this state (and, for
/// always, the root grant/generation) before waking the originating waiter.
pub fn decideApprovalResponse(
    approval: Approval,
    response: ApprovalResponse,
    context: ApprovalContext,
) ApprovalDecision {
    if (!std.mem.eql(u8, approval.id, response.request_id)) return .{ .reject = .stale };
    if (!std.mem.eql(u8, approval.child_id, response.child_id)) return .{ .reject = .wrong_child };
    if (approval.status != .pending) return .{ .reject = .resolved };
    if (!context.attached) return .{ .reject = .detached };
    if (context.child_cancelled) return .{ .reject = .cancelled };
    if (context.child_closed) return .{ .reject = .closed };
    return switch (response.decision) {
        .once => .accept_once,
        .always => if (approval.grants.len == 0) .{ .reject = .invalid } else .accept_always,
        .deny => .deny,
        .policy_denied, .permission_required => .{ .reject = .invalid },
    };
}

pub fn applyApprovalDecision(
    approval: *Approval,
    decision: ApprovalDecision,
    timestamp_ms: i64,
    revision: u64,
) MutationError!void {
    if (approval.status != .pending or revision == 0) return error.ApprovalConflict;
    approval.status = switch (decision) {
        .accept_once => .allowed_once,
        .accept_always => .allowed_always,
        .deny => .denied,
        .reject => return error.InvalidApproval,
    };
    approval.resolved_at_ms = timestamp_ms;
    approval.resolved_revision = revision;
}

/// Adds canonical permission-core grants to the tree root and increments the
/// generation only when authority changes. The caller persists before wakeup.
pub fn applyAlwaysGrants(
    alloc: Allocator,
    ledger: *Ledger,
    grants: []const types.PermissionGrant,
) MutationError!bool {
    if (grants.len > domain.max_admission_items) return error.InvalidApproval;
    for (grants) |grant| {
        validateContent(grant.tool_name) catch return error.InvalidApproval;
        validateApprovalProjection(grant.target_path) catch
            return error.InvalidApproval;
    }
    var admitted = [_]bool{false} ** domain.max_admission_items;
    const added_count = selectNewGrants(
        ledger.authority_grants,
        grants,
        &admitted,
    );
    if (added_count == 0) return false;
    if (!grantAdmissionFits(ledger.*, grants, &admitted)) {
        return error.CapacityExceeded;
    }
    const next_authority_generation = std.math.add(
        u64,
        ledger.authority_generation,
        1,
    ) catch return error.AuthorityExhausted;
    const next_generation = std.math.add(u64, ledger.generation, 1) catch
        return error.GenerationExhausted;
    const replacement = try alloc.alloc(
        types.PermissionGrant,
        ledger.authority_grants.len + added_count,
    );
    errdefer alloc.free(replacement);
    var initialized: usize = ledger.authority_grants.len;
    errdefer for (replacement[ledger.authority_grants.len..initialized]) |grant| {
        alloc.free(grant.tool_name);
        alloc.free(grant.target_path);
    };
    for (grants, 0..) |grant, index| {
        if (!admitted[index]) continue;
        const tool_name = try alloc.dupe(u8, grant.tool_name);
        errdefer alloc.free(tool_name);
        const target_path = try alloc.dupe(u8, grant.target_path);
        replacement[initialized] = .{
            .tool_name = tool_name,
            .target_path = target_path,
        };
        initialized += 1;
    }
    @memcpy(replacement[0..ledger.authority_grants.len], ledger.authority_grants);
    alloc.free(ledger.authority_grants);
    ledger.authority_grants = replacement;
    ledger.authority_generation = next_authority_generation;
    ledger.generation = next_generation;
    return true;
}

/// Canonical digest of the exact prepared request, kept separately from its
/// redacted durable projection.
pub fn preparedRequestFingerprint(request: permission_request.PermissionRequest) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.prepared-permission.v1\x00");
    hashString(&hash, request.label);
    hashOptionalString(&hash, request.explanation);
    if (request.tool_arguments_preview) |preview| {
        hash.update("tool-arguments-preview\x00");
        hashString(&hash, preview);
    }
    hashOptionalString(&hash, request.command);
    hashBool(&hash, request.amendment_allowed);
    if (request.file) |file| {
        hash.update("file\x00");
        hashString(&hash, @tagName(file.kind));
        hashString(&hash, @tagName(file.intent));
        hashString(&hash, file.preview.path);
        hashU64(&hash, file.preview.path_basename_start);
        hashBool(&hash, file.preview.path_source_truncated);
        hashU64(&hash, file.preview.additions);
        hashU64(&hash, file.preview.deletions);
        hashBool(&hash, file.preview.truncated);
        hashString(&hash, @tagName(file.scope));
        for (file.preview.lines) |line| {
            hashString(&hash, @tagName(line.op));
            hashOptionalU32(&hash, line.old_line);
            hashOptionalU32(&hash, line.new_line);
            hashString(&hash, line.text);
        }
    } else hash.update("no-file\x00");
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn stableDeliveryId(
    source_id: []const u8,
    work_id: []const u8,
    kind: []const u8,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.delivery.v1\x00");
    hashString(&hash, source_id);
    hashString(&hash, work_id);
    hashString(&hash, kind);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn stableIntervalDeliveryId(
    source_id: []const u8,
    work_id: []const u8,
    due_ms: i64,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.interval-delivery.v1\x00");
    hashString(&hash, source_id);
    hashString(&hash, work_id);
    hashU64(&hash, @as(u64, @bitCast(due_ms)));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn stableToolActivityId(
    source_id: []const u8,
    work_id: []const u8,
    call_id: []const u8,
    phase: ToolActivityPhase,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.tool-activity.v1\x00");
    hashString(&hash, source_id);
    hashString(&hash, work_id);
    hashString(&hash, call_id);
    hashString(&hash, @tagName(phase));
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn stableApprovalId(
    child_id: []const u8,
    work_id: []const u8,
    prepared_fingerprint: [32]u8,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.approval.v1\x00");
    hashString(&hash, child_id);
    hashString(&hash, work_id);
    hash.update(&prepared_fingerprint);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn approvalAsInput(approval: Approval) ApprovalInput {
    return .{
        .id = approval.id,
        .kind = approval.kind,
        .child_id = approval.child_id,
        .root_id = approval.root_id,
        .work_id = approval.work_id,
        .relationship = if (approval.relationship) |relationship| .{
            .action = relationship.action,
            .prospective_parent_id = relationship.prospective_parent_id,
            .operation_id = relationship.operation_id,
        } else null,
        .prepared_fingerprint = approval.prepared_fingerprint,
        .label = approval.label,
        .explanation = approval.explanation,
        .command = approval.command,
        .file = approval.file,
        .grants = approval.grants,
        .created_at_ms = approval.created_at_ms,
    };
}

pub fn relationshipPreparedFingerprint(
    action: domain.RelationshipAction,
    child_id: []const u8,
    prospective_parent_id: []const u8,
    operation_id: []const u8,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.relationship-approval.v1\x00");
    hashString(&hash, @tagName(action));
    hashString(&hash, child_id);
    hashString(&hash, prospective_parent_id);
    hashString(&hash, operation_id);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashNormalizedGrants(
    hash: *std.crypto.hash.sha2.Sha256,
    grants: []const types.PermissionGrant,
) void {
    hashU64(hash, grants.len);
    for (0..grants.len) |rank| {
        var selected: usize = 0;
        for (grants, 0..) |candidate, candidate_index| {
            var candidate_rank: usize = 0;
            for (grants, 0..) |other, other_index| {
                if (grantLess(other, other_index, candidate, candidate_index)) {
                    candidate_rank += 1;
                }
            }
            if (candidate_rank == rank) {
                selected = candidate_index;
                break;
            }
        }
        hashString(hash, grants[selected].tool_name);
        hashString(hash, grants[selected].target_path);
    }
}

fn grantLess(
    left: types.PermissionGrant,
    left_index: usize,
    right: types.PermissionGrant,
    right_index: usize,
) bool {
    const tool_order = std.mem.order(u8, left.tool_name, right.tool_name);
    if (tool_order != .eq) return tool_order == .lt;
    const target_order = std.mem.order(u8, left.target_path, right.target_path);
    if (target_order != .eq) return target_order == .lt;
    return left_index < right_index;
}

fn validateDeliveryInput(input: DeliveryInput) MutationError!void {
    domain.validateOperationId(input.id) catch return error.InvalidDelivery;
    domain.validateId(input.source_id) catch return error.InvalidDelivery;
    domain.validateId(input.target_id) catch return error.InvalidDelivery;
    if (input.work_id) |value| domain.validateOperationId(value) catch
        return error.InvalidDelivery;
    if (input.operation_id) |value| domain.validateOperationId(value) catch
        return error.InvalidDelivery;
    switch (input.payload) {
        .message, .approval => |value| validateContent(value) catch return error.InvalidDelivery,
        .milestone => |value| if (value.len == 0 or value.len > domain.max_name_bytes or
            !std.unicode.utf8ValidateSlice(value) or
            std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidDelivery,
        .terminal => |value| if (!isTerminal(value)) return error.InvalidDelivery,
        .interval => |value| if (value.coalesced_ticks == 0) return error.InvalidDelivery,
        .tool_activity => |value| if (value.tool_name.len == 0 or
            value.tool_name.len > domain.max_admission_item_bytes or
            !std.unicode.utf8ValidateSlice(value.tool_name) or
            std.mem.indexOfScalar(u8, value.tool_name, 0) != null)
        {
            return error.InvalidDelivery;
        },
    }
}

fn deliveryAsInput(delivery: Delivery) DeliveryInput {
    return .{
        .id = delivery.id,
        .source_id = delivery.source_id,
        .target_id = delivery.target_id,
        .work_id = delivery.work_id,
        .operation_id = delivery.operation_id,
        .timestamp_ms = delivery.timestamp_ms,
        .payload = switch (delivery.payload) {
            .message => |value| .{ .message = value },
            .milestone => |value| .{ .milestone = value },
            .terminal => |value| .{ .terminal = value },
            .interval => |value| .{ .interval = .{
                .state = value.state,
                .coalesced_ticks = value.coalesced_ticks,
            } },
            .approval => |value| .{ .approval = value },
            .tool_activity => |value| .{ .tool_activity = .{
                .tool_name = value.tool_name,
                .phase = value.phase,
            } },
        },
    };
}

fn validatePolicy(policy: domain.NotificationPolicy) !void {
    if (policy.milestones.len > domain.max_milestones or
        policy.stop_conditions.len == 0 or
        policy.stop_conditions.len > domain.max_stop_conditions or
        (policy.report_duration_ms != null and policy.report_interval_ms == null))
    {
        return error.InvalidNotification;
    }
    if (policy.report_interval_ms) |value| if (value == 0) {
        return error.InvalidNotification;
    };
    if (policy.report_duration_ms) |value| if (value == 0) {
        return error.InvalidNotification;
    };
    for (policy.milestones, 0..) |name, index| {
        if (name.len == 0 or name.len > domain.max_name_bytes or
            !std.unicode.utf8ValidateSlice(name) or
            std.mem.indexOfScalar(u8, name, 0) != null)
        {
            return error.InvalidNotification;
        }
        for (policy.milestones[0..index]) |prior| {
            if (std.mem.eql(u8, prior, name)) return error.InvalidNotification;
        }
    }
    for (policy.stop_conditions, 0..) |condition, index| {
        if (condition == .duration_elapsed and policy.report_duration_ms == null) {
            return error.InvalidNotification;
        }
        for (policy.stop_conditions[0..index]) |prior| {
            if (prior == condition) return error.InvalidNotification;
        }
    }
}

fn validateContent(value: []const u8) !void {
    return validateBoundedContent(value, max_delivery_content_bytes);
}

fn validateApprovalProjection(value: []const u8) !void {
    return validateBoundedContent(value, max_approval_projection_bytes);
}

fn validateBoundedContent(value: []const u8, max_bytes: usize) !void {
    if (value.len == 0 or value.len > max_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.indexOfScalar(u8, value, 0) != null)
    {
        return error.InvalidDelivery;
    }
}

fn ownDelivery(
    alloc: Allocator,
    sequence: u64,
    revision: u64,
    input: DeliveryInput,
) !Delivery {
    const id = try alloc.dupe(u8, input.id);
    errdefer alloc.free(id);
    const source_id = try alloc.dupe(u8, input.source_id);
    errdefer alloc.free(source_id);
    const target_id = try alloc.dupe(u8, input.target_id);
    errdefer alloc.free(target_id);
    const work_id = if (input.work_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (work_id) |value| alloc.free(value);
    const operation_id = if (input.operation_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (operation_id) |value| alloc.free(value);
    return .{
        .sequence = sequence,
        .revision = revision,
        .id = id,
        .source_id = source_id,
        .target_id = target_id,
        .work_id = work_id,
        .operation_id = operation_id,
        .timestamp_ms = input.timestamp_ms,
        .payload = switch (input.payload) {
            .message => |value| .{ .message = try alloc.dupe(u8, value) },
            .milestone => |value| .{ .milestone = try alloc.dupe(u8, value) },
            .terminal => |value| .{ .terminal = value },
            .interval => |value| .{ .interval = .{
                .state = value.state,
                .coalesced_ticks = value.coalesced_ticks,
            } },
            .approval => |value| .{ .approval = try alloc.dupe(u8, value) },
            .tool_activity => |value| .{ .tool_activity = .{
                .tool_name = try alloc.dupe(u8, value.tool_name),
                .phase = value.phase,
            } },
        },
    };
}

fn deliveryInputMatches(delivery: Delivery, input: DeliveryInput) bool {
    if (!std.mem.eql(u8, delivery.source_id, input.source_id) or
        !std.mem.eql(u8, delivery.target_id, input.target_id) or
        !optionalEqual(delivery.work_id, input.work_id) or
        !optionalEqual(delivery.operation_id, input.operation_id) or
        @as(DeliveryKind, delivery.payload) != @as(DeliveryKind, input.payload))
    {
        return false;
    }
    return switch (delivery.payload) {
        .message => |value| std.mem.eql(u8, value, input.payload.message),
        .milestone => |value| std.mem.eql(u8, value, input.payload.milestone),
        .terminal => |value| value == input.payload.terminal,
        .interval => |value| value.state == input.payload.interval.state and
            value.coalesced_ticks == input.payload.interval.coalesced_ticks,
        .approval => |value| std.mem.eql(u8, value, input.payload.approval),
        .tool_activity => |value| value.phase == input.payload.tool_activity.phase and
            std.mem.eql(u8, value.tool_name, input.payload.tool_activity.tool_name),
    };
}

fn validateConsumerId(value: []const u8) MutationError!void {
    if (value.len == 0 or value.len > domain.max_operation_id_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.indexOfScalar(u8, value, 0) != null)
    {
        return error.InvalidCursor;
    }
}

fn findCursor(
    cursors: []const ConsumerCursor,
    consumer_id: []const u8,
    target_id: []const u8,
    projection: Projection,
) ?ConsumerCursor {
    for (cursors) |cursor| {
        if (std.mem.eql(u8, cursor.consumer_id, consumer_id) and
            std.mem.eql(u8, cursor.target_id, target_id) and
            cursor.projection == projection)
        {
            return cursor;
        }
    }
    return null;
}

fn findCursorMutable(
    cursors: []ConsumerCursor,
    consumer_id: []const u8,
    target_id: []const u8,
    projection: Projection,
) ?*ConsumerCursor {
    for (cursors) |*cursor| {
        if (std.mem.eql(u8, cursor.consumer_id, consumer_id) and
            std.mem.eql(u8, cursor.target_id, target_id) and
            cursor.projection == projection)
        {
            return cursor;
        }
    }
    return null;
}

pub fn retentionGapThrough(
    ledger: Ledger,
    target_id: []const u8,
    projection: Projection,
) u64 {
    for (ledger.retention_targets orelse &.{}) |target| {
        if (!std.mem.eql(u8, target.target_id, target_id)) continue;
        return switch (projection) {
            .human => target.human_evicted_through,
            .parent_turn => target.parent_turn_evicted_through,
        };
    }
    return 0;
}

pub fn parentTurnDeliveryFullyAcknowledged(
    ledger: Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    delivery_id: []const u8,
) bool {
    const cursor = findCursor(
        ledger.cursors,
        consumer_id,
        target_id,
        .parent_turn,
    ) orelse return false;
    if (cursor.stale or cursor.partial_message_sequence != 0 or
        retentionGapThrough(ledger, target_id, .parent_turn) != 0)
    {
        return false;
    }
    for (ledger.deliveries) |delivery| {
        if (!std.mem.eql(u8, delivery.id, delivery_id) or
            !std.mem.eql(u8, delivery.target_id, target_id) or
            delivery.payload != .message)
        {
            continue;
        }
        return cursor.acknowledged_sequence >= delivery.sequence;
    }
    return false;
}

pub fn stableFinalResultFullyAcknowledged(
    ledger: Ledger,
    consumer_id: []const u8,
    target_id: []const u8,
    delivery_id: []const u8,
) bool {
    for (ledger.deliveries) |delivery| {
        if (!std.mem.eql(u8, delivery.id, delivery_id) or
            delivery.payload != .message)
        {
            continue;
        }
        const work_id = delivery.work_id orelse return false;
        const stable_id = stableDeliveryId(
            delivery.source_id,
            work_id,
            "final-result",
        );
        if (!std.mem.eql(u8, &stable_id, delivery.id)) return false;
        return parentTurnDeliveryFullyAcknowledged(
            ledger,
            consumer_id,
            target_id,
            delivery_id,
        );
    }
    return false;
}

const DeliveryOperationIdentity = union(enum) {
    none,
    legacy,
    bound: domain.BoundOperationIdentity,
};

fn deliveryOperationIdentity(input: DeliveryInput) DeliveryOperationIdentity {
    const operation_id = input.operation_id orelse return .none;
    if (tool_result.parseBoundOperationId(operation_id)) |bound| {
        return .{ .bound = bound };
    }
    return switch (input.payload) {
        .message, .milestone => .legacy,
        .approval, .tool_activity, .terminal, .interval => .none,
    };
}

fn noteDeliveryIdentity(
    ledger: *Ledger,
    identity: DeliveryOperationIdentity,
) void {
    switch (identity) {
        .none => {},
        .legacy => {},
        .bound => |bound| {
            ledger.legacy_operation_replay_closed = true;
            if (bound.authority != .manager) return;
            switch (bound.source) {
                .model => ledger.model_epoch_high = @max(ledger.model_epoch_high, bound.epoch),
                .human => ledger.human_epoch_high = @max(ledger.human_epoch_high, bound.epoch),
            }
        },
    }
}

fn noteEvictedDeliveryIdentity(
    ledger: *Ledger,
    delivery: Delivery,
    additional: ?Delivery,
) void {
    switch (deliveryOperationIdentity(deliveryAsInput(delivery))) {
        .none => {},
        .legacy => ledger.legacy_operation_replay_closed = true,
        .bound => |bound| {
            if (bound.authority != .manager) {
                ledger.legacy_operation_replay_closed = true;
                return;
            }
            var next = bound.epoch +| 1;
            for (ledger.deliveries) |retained| {
                if (retained.sequence == delivery.sequence) continue;
                const retained_identity = switch (deliveryOperationIdentity(
                    deliveryAsInput(retained),
                )) {
                    .bound => |identity| identity,
                    .none, .legacy => continue,
                };
                if (retained_identity.authority != .manager or
                    retained_identity.source != bound.source)
                {
                    continue;
                }
                next = @min(next, retained_identity.epoch);
            }
            if (additional) |retained| {
                const retained_identity = switch (deliveryOperationIdentity(
                    deliveryAsInput(retained),
                )) {
                    .bound => |identity| identity,
                    .none, .legacy => null,
                };
                if (retained_identity) |identity| {
                    if (identity.authority == .manager and
                        identity.source == bound.source)
                    {
                        next = @min(next, identity.epoch);
                    }
                }
            }
            switch (bound.source) {
                .model => ledger.model_replay_floor = @max(ledger.model_replay_floor, next),
                .human => ledger.human_replay_floor = @max(ledger.human_replay_floor, next),
            }
        },
    }
}

fn recordRetentionLoss(
    alloc: Allocator,
    ledger: *Ledger,
    delivery: Delivery,
    additional: ?Delivery,
) MutationError!void {
    if (ledger.retention_targets) |targets| {
        for (targets) |*target| {
            if (!std.mem.eql(u8, target.target_id, delivery.target_id)) continue;
            target.human_evicted_through = @max(
                target.human_evicted_through,
                delivery.sequence,
            );
            if (visibleInProjection(delivery, .parent_turn)) {
                target.parent_turn_evicted_through = @max(
                    target.parent_turn_evicted_through,
                    delivery.sequence,
                );
            }
            noteEvictedDeliveryIdentity(ledger, delivery, additional);
            return;
        }
        if (targets.len == max_retention_targets) {
            return error.CapacityExceeded;
        }
    }

    const candidate = RetentionTarget{
        .target_id = @constCast(delivery.target_id),
        .human_evicted_through = delivery.sequence,
        .parent_turn_evicted_through = if (visibleInProjection(
            delivery,
            .parent_turn,
        ))
            delivery.sequence
        else
            0,
    };
    if (!retentionAdmissionFits(ledger.*, candidate)) {
        return error.CapacityExceeded;
    }
    const target_id = try alloc.dupe(u8, delivery.target_id);
    errdefer alloc.free(target_id);
    const old_len = if (ledger.retention_targets) |targets| targets.len else 0;
    const new_targets = if (ledger.retention_targets) |targets|
        try alloc.realloc(targets, targets.len + 1)
    else
        try alloc.alloc(RetentionTarget, 1);
    new_targets[old_len] = .{
        .target_id = target_id,
        .human_evicted_through = delivery.sequence,
        .parent_turn_evicted_through = if (visibleInProjection(
            delivery,
            .parent_turn,
        ))
            delivery.sequence
        else
            0,
    };
    ledger.retention_targets = new_targets;
    noteEvictedDeliveryIdentity(ledger, delivery, additional);
}

fn markStaleCursorsForEviction(
    cursors: []ConsumerCursor,
    delivery: Delivery,
) void {
    for (cursors) |*cursor| {
        if (cursor.stale or
            (cursor.acknowledged_sequence >= delivery.sequence and
                cursor.partial_message_sequence != delivery.sequence) or
            !std.mem.eql(u8, cursor.target_id, delivery.target_id) or
            !visibleInProjection(delivery, cursor.projection)) continue;
        cursor.stale = true;
    }
}

fn validPartialMessageCursor(
    deliveries: []const Delivery,
    cursor: ConsumerCursor,
) bool {
    if (cursor.partial_message_sequence <= cursor.acknowledged_sequence) {
        return false;
    }
    for (deliveries) |delivery| {
        if (delivery.sequence != cursor.partial_message_sequence) continue;
        if (!std.mem.eql(u8, delivery.target_id, cursor.target_id) or
            !visibleInProjection(delivery, .parent_turn) or
            delivery.payload != .message)
        {
            return false;
        }
        const offset = std.math.cast(usize, cursor.partial_message_offset) orelse
            return false;
        return offset > 0 and offset < delivery.payload.message.len and
            utf8Boundary(delivery.payload.message, offset);
    }
    return false;
}

fn deliverySequenceTargets(
    deliveries: []const Delivery,
    sequence: u64,
    target_id: []const u8,
    projection: Projection,
) bool {
    for (deliveries) |delivery| {
        if (delivery.sequence == sequence) {
            return std.mem.eql(u8, delivery.target_id, target_id) and
                visibleInProjection(delivery, projection);
        }
    }
    return false;
}

fn isTerminal(state: domain.State) bool {
    return switch (state) {
        .completed, .failed, .cancelled => true,
        else => false,
    };
}

fn hasStop(values: []const domain.StopCondition, needle: domain.StopCondition) bool {
    for (values) |value| if (value == needle) return true;
    return false;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn cloneSlice(comptime T: type, alloc: Allocator, values: []const T) ![]T {
    const out = try alloc.alloc(T, values.len);
    errdefer alloc.free(out);
    var copied: usize = 0;
    errdefer for (out[0..copied]) |*value| value.deinit(alloc);
    for (values, 0..) |value, index| {
        out[index] = try value.clone(alloc);
        copied += 1;
    }
    return out;
}

fn freeSlice(comptime T: type, alloc: Allocator, values: []T) void {
    for (values) |*value| value.deinit(alloc);
    alloc.free(values);
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashU64(hash, value.len);
    hash.update(value);
}

fn hashOptionalString(hash: *std.crypto.hash.sha2.Sha256, value: ?[]const u8) void {
    hashBool(hash, value != null);
    if (value) |text| hashString(hash, text);
}

fn hashBool(hash: *std.crypto.hash.sha2.Sha256, value: bool) void {
    hash.update(&.{@intFromBool(value)});
}

fn hashOptionalU32(hash: *std.crypto.hash.sha2.Sha256, value: ?u32) void {
    hashBool(hash, value != null);
    if (value) |number| hashU64(hash, number);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, std.math.cast(u64, value) orelse std.math.maxInt(u64), .little);
    hash.update(&bytes);
}

fn checkRetentionGapAllocationFailures(alloc: Allocator) !void {
    var ledger = try Ledger.init(alloc, "child");
    defer ledger.deinit(alloc);
    const retention_target_id = try alloc.dupe(u8, "parent");
    ledger.retention_targets.? = alloc.realloc(
        ledger.retention_targets.?,
        1,
    ) catch |err| {
        alloc.free(retention_target_id);
        return err;
    };
    ledger.retention_targets.?[0] = .{
        .target_id = retention_target_id,
        .human_evicted_through = 1,
        .parent_turn_evicted_through = 1,
    };
    ledger.next_sequence = 2;

    var parent = try pageForParentTurn(
        alloc,
        ledger,
        "parent-model",
        "parent",
        null,
        1,
    );
    defer parent.deinit(alloc);
    try acknowledgeParentTurn(
        alloc,
        &ledger,
        "parent-model",
        "parent",
        acknowledgementForParentPart(parent.deliveries[0]),
    );

    var human = try pageForTarget(
        alloc,
        ledger,
        "human",
        "parent",
        null,
        1,
    );
    defer human.deinit(alloc);
    try acknowledgeTarget(
        alloc,
        &ledger,
        "human",
        "parent",
        human.through_sequence,
    );
}

fn fillEscapingUnicodeMessage(content: []u8) void {
    const pattern = "\"\\\n🦎";
    var offset: usize = 0;
    while (offset + pattern.len <= content.len) : (offset += pattern.len) {
        @memcpy(content[offset..][0..pattern.len], pattern);
    }
    @memset(content[offset..], 'x');
}
