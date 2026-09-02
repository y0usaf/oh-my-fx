const std = @import("std");
const approval_persistence = @import("approval_persistence.zig");
const approval_registry = @import("approval_registry.zig");
const communication = @import("communication.zig");
const communication_manager = @import("communication_manager.zig");
const communication_store = @import("communication_store.zig");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const manager_mod = @import("manager.zig");
const resume_admission = @import("resume_admission.zig");
const tool_result = @import("tool_result.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const types = @import("../shared/types.zig");
const session_store = @import("../session/session_store.zig");

const Allocator = std.mem.Allocator;

pub const consumer_id = "subagent-manager-ui";
pub const max_nodes: usize = domain.max_page_limit;
pub const max_activity: usize = 16;
pub const max_approvals: usize = 8;
pub const pending_approval_page_limit: usize = 8;
pub const max_summary_bytes: usize = 512;

pub const DegradedReason = enum {
    session_unavailable,
    invalid_record,
    record_too_large,
    path_unsafe,
    store_failure,
};

pub const ActivityKind = communication.DeliveryKind;

pub const Activity = struct {
    sequence: u64,
    revision: u64,
    timestamp_ms: i64,
    kind: ActivityKind,
    summary: []u8,

    pub fn deinit(self: *Activity, alloc: Allocator) void {
        alloc.free(self.summary);
        self.* = undefined;
    }
};

pub const Approval = struct {
    id: []u8,
    kind: communication.ApprovalKind,
    status: communication.ApprovalStatus,
    label: []u8,
    explanation: ?[]u8,
    command: ?[]u8 = null,
    file: ?permission_request.FileApprovalRequest = null,

    pub fn deinit(self: *Approval, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.label);
        if (self.explanation) |value| alloc.free(value);
        if (self.command) |value| alloc.free(value);
        if (self.file) |value| {
            permission_request.deinitFileApprovalRequest(alloc, value);
        }
        self.* = undefined;
    }
};

pub const PendingApproval = struct {
    child_id: []u8,
    child_name: []u8,
    request: Approval,
    tool_arguments_preview: ?[]u8 = null,

    pub fn deinit(self: *PendingApproval, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.child_name);
        self.request.deinit(alloc);
        if (self.tool_arguments_preview) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Node = struct {
    child_id: []u8,
    parent_id: []u8,
    name: []u8,
    mode: domain.Mode,
    state: domain.State,
    generation: u64,
    depth: usize,
    relationship_issue: ?manager_mod.TreeRelationshipIssue,
    configuration: ?domain.Configuration = null,
    external_busy: bool = false,
    unread_count: usize = 0,
    unread_truncated: bool = false,
    through_sequence: u64 = 0,
    stale: bool = false,
    degraded: ?DegradedReason = null,
    failure_reason: ?[]u8 = null,
    activity: []Activity,
    approvals: []Approval,

    pub fn deinit(self: *Node, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.parent_id);
        alloc.free(self.name);
        if (self.configuration) |*configuration| configuration.deinit(alloc);
        if (self.failure_reason) |reason| alloc.free(reason);
        for (self.activity) |*value| value.deinit(alloc);
        alloc.free(self.activity);
        for (self.approvals) |*value| value.deinit(alloc);
        alloc.free(self.approvals);
        self.* = undefined;
    }
};

pub const CancellationCapability = enum {
    available,
    external_owner,
    inactive,
};

pub fn cancellationCapability(
    state: domain.State,
    external_busy: bool,
) CancellationCapability {
    if (external_busy) return .external_owner;
    return switch (state) {
        .queued, .running, .awaiting_approval, .interrupted => .available,
        .idle,
        .completed,
        .failed,
        .cancelled,
        .archived,
        => .inactive,
    };
}

pub const Snapshot = struct {
    root_id: []u8,
    revision: u64,
    approval_revision: u64,
    content_hash: u64,
    restart_required: bool,
    nodes: []Node,
    pending_approvals: []PendingApproval,
    pending_approval_total: usize = 0,
    pending_approval_offset: usize = 0,
    pending_approval_previous_offset: ?usize = null,
    pending_approval_next_offset: ?usize = null,
    page_cursor: ?[]u8 = null,
    next_cursor: ?[]u8,
    diagnostics: []manager_mod.TreeDiagnostic,
    diagnostics_truncated: bool,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.root_id);
        for (self.nodes) |*node| node.deinit(alloc);
        alloc.free(self.nodes);
        for (self.pending_approvals) |*approval| approval.deinit(alloc);
        alloc.free(self.pending_approvals);
        if (self.page_cursor) |cursor| alloc.free(cursor);
        if (self.next_cursor) |cursor| alloc.free(cursor);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(alloc);
        alloc.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const LoadResult = union(enum) {
    snapshot: Snapshot,
    degraded: manager_mod.FailureCode,

    pub fn deinit(self: *LoadResult, alloc: Allocator) void {
        switch (self.*) {
            .snapshot => |*snapshot| snapshot.deinit(alloc),
            .degraded => {},
        }
        self.* = undefined;
    }
};

pub const Source = struct {
    root_id: []const u8,
    manager: *manager_mod.Manager,
    sessions: *session_store.Store,
    owner: ?*execution.Owner = null,
    approval_registry: ?*approval_registry.Registry = null,
    pending_approval_offset: usize = 0,
};

pub const AttachCandidate = struct {
    session_id: []u8,
    title: ?[]u8,
    workspace_root: ?[]u8,
    preview: ?[]u8,
    updated_at_ms: i64,
    history_len: usize,
    control_present: bool = false,
    parent_id: ?[]u8 = null,
    state: ?domain.State = null,
    generation: u64 = 0,
    external_busy: bool = false,
    eligible: bool = true,
    failure: ?manager_mod.FailureCode = null,

    pub fn deinit(self: *AttachCandidate, alloc: Allocator) void {
        alloc.free(self.session_id);
        if (self.title) |value| alloc.free(value);
        if (self.workspace_root) |value| alloc.free(value);
        if (self.preview) |value| alloc.free(value);
        if (self.parent_id) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn relationshipAction(self: AttachCandidate, root_id: []const u8) domain.RelationshipAction {
        const parent_id = self.parent_id orelse return .attach;
        return if (std.mem.eql(u8, parent_id, root_id)) .detach else .reparent;
    }

    pub fn busy(self: AttachCandidate) bool {
        if (self.external_busy) return true;
        return if (self.state) |state|
            state == .queued or state == .running or state == .awaiting_approval
        else
            false;
    }
};

pub const AttachPage = struct {
    candidates: []AttachCandidate,
    has_more: bool,
    continuation: ?resume_admission.ActionableContinuation = null,

    pub fn deinit(self: *AttachPage, alloc: Allocator) void {
        for (self.candidates) |*candidate| candidate.deinit(alloc);
        alloc.free(self.candidates);
        if (self.continuation) |*continuation| continuation.deinit(alloc);
        self.* = undefined;
    }
};

/// Projects the canonical profile-visible resume discovery page into attach
/// eligibility. Relationship and lifecycle labels come from manager inspect;
/// the UI never infers or mutates a control record.
pub fn loadAttachPage(
    alloc: Allocator,
    source: Source,
    continuation: ?session_store.ResumableSessionContinuation,
) !AttachPage {
    var page = try resume_admission.listActionablePage(
        source.sessions.*,
        alloc,
        .all_workspaces,
        source.root_id,
        continuation,
        session_store.default_resume_page_limit,
    );
    defer page.deinit(alloc);

    const candidates = try alloc.alloc(AttachCandidate, page.summaries.items.len);
    var built: usize = 0;
    errdefer {
        for (candidates[0..built]) |*candidate| candidate.deinit(alloc);
        alloc.free(candidates);
    }
    for (page.summaries.items) |summary| {
        candidates[built] = try projectAttachCandidate(alloc, source, summary);
        built += 1;
    }
    const next_continuation = page.continuation;
    page.continuation = null;
    return .{
        .candidates = candidates,
        .has_more = page.has_more,
        .continuation = next_continuation,
    };
}

fn projectAttachCandidate(
    alloc: Allocator,
    source: Source,
    summary: session_store.SessionSummary,
) !AttachCandidate {
    const session_id = try alloc.dupe(u8, summary.id);
    errdefer alloc.free(session_id);
    const title = if (summary.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const workspace_root = if (summary.workspace_root) |value| try alloc.dupe(u8, value) else null;
    errdefer if (workspace_root) |value| alloc.free(value);
    const preview = if (summary.preview) |value| try alloc.dupe(u8, value) else null;
    errdefer if (preview) |value| alloc.free(value);
    var candidate: AttachCandidate = .{
        .session_id = session_id,
        .title = title,
        .workspace_root = workspace_root,
        .preview = preview,
        .updated_at_ms = summary.updated_at_ms,
        .history_len = summary.history_len,
        .external_busy = if (source.owner) |owner|
            owner.externalBusy(summary.id)
        else
            false,
    };
    errdefer candidate.deinit(alloc);

    var command = try domain.validateCommand(alloc, .{ .inspect = .{
        .id = summary.id,
        .sections = &.{ .status, .relationship },
    } });
    defer command.deinit(alloc);
    var result = try source.manager.execute(alloc, command, .{
        .actor_id = source.root_id,
        .timestamp_ms = 0,
    });
    defer result.deinit(alloc);
    switch (result) {
        .inspection => |inspection| {
            candidate.control_present = true;
            candidate.state = inspection.status;
            candidate.generation = inspection.generation;
            candidate.parent_id = if (inspection.parent_id) |parent_id|
                try alloc.dupe(u8, parent_id)
            else
                null;
        },
        .failure => |failure| {
            if (failure.code != .control_not_found) {
                candidate.failure = failure.code;
                candidate.eligible = false;
            }
        },
        .receipt => unreachable,
    }
    if (candidate.busy()) candidate.eligible = false;
    return candidate;
}

pub const child_history_page_limit: usize = 20;
pub const max_child_history_pages: usize = 3;
pub const max_child_messages: usize = 16;

pub const TurnSource = union(enum) {
    not_applicable,
    ordinary_human,
    manager_source: struct {
        source_id: []const u8,
        identity_source: ?domain.OperationIdentitySource,
    },
    unavailable,
};

/// Pure provenance association. Message content is intentionally absent from
/// this contract, so equal prompts cannot influence source identity.
pub fn resolveTurnSource(
    work_id: ?[]const u8,
    messages: []const domain.QueuedMessage,
) TurnSource {
    const id = work_id orelse return .ordinary_human;
    for (messages) |message| {
        if (std.mem.eql(u8, message.id, id)) {
            const identity = tool_result.parseBoundOperationId(message.id);
            return .{ .manager_source = .{
                .source_id = message.source_id,
                .identity_source = if (identity) |value| value.source else null,
            } };
        }
    }
    if (tool_result.parseBoundOperationId(id)) |identity| {
        return .{ .manager_source = .{
            .source_id = "",
            .identity_source = identity.source,
        } };
    }
    return .unavailable;
}

pub const OwnedTurnSource = union(enum) {
    not_applicable,
    ordinary_human,
    manager_source: struct {
        source_id: []u8,
        identity_source: ?domain.OperationIdentitySource,
    },
    unavailable,

    pub fn deinit(self: *OwnedTurnSource, alloc: Allocator) void {
        switch (self.*) {
            .manager_source => |source| alloc.free(source.source_id),
            .not_applicable, .ordinary_human, .unavailable => {},
        }
        self.* = undefined;
    }
};

pub const ChildChatPage = struct {
    history: session_store.HistoryPage,
    sources: []OwnedTurnSource,

    pub fn deinit(self: *ChildChatPage, alloc: Allocator) void {
        self.history.deinit(alloc);
        for (self.sources) |*source| source.deinit(alloc);
        alloc.free(self.sources);
        self.* = undefined;
    }
};

/// Fixed-size owned page window. Pages are oldest-to-newest. Loading farther
/// back evicts from the newer edge; returning to the live edge reloads the
/// authoritative newest page rather than retaining a second history source.
pub const ChildChatPageCache = struct {
    pages: std.ArrayList(ChildChatPage) = .empty,
    has_newest: bool = false,

    pub fn deinit(self: *ChildChatPageCache, alloc: Allocator) void {
        self.clear(alloc);
        self.pages.deinit(alloc);
        self.* = .{};
    }

    pub fn clear(self: *ChildChatPageCache, alloc: Allocator) void {
        for (self.pages.items) |*page| page.deinit(alloc);
        self.pages.clearRetainingCapacity();
        self.has_newest = false;
    }

    pub fn resetNewest(
        self: *ChildChatPageCache,
        alloc: Allocator,
        page_value: ChildChatPage,
    ) !void {
        var page = page_value;
        errdefer page.deinit(alloc);
        self.clear(alloc);
        try self.pages.append(alloc, page);
        self.has_newest = true;
    }

    pub fn replaceNewest(
        self: *ChildChatPageCache,
        alloc: Allocator,
        page_value: ChildChatPage,
    ) !void {
        var page = page_value;
        errdefer page.deinit(alloc);
        if (!self.has_newest or self.pages.items.len == 0) {
            page.deinit(alloc);
            return;
        }
        self.pages.items[self.pages.items.len - 1].deinit(alloc);
        self.pages.items[self.pages.items.len - 1] = page;
    }

    pub fn addOlder(
        self: *ChildChatPageCache,
        alloc: Allocator,
        page_value: ChildChatPage,
    ) !void {
        var page = page_value;
        errdefer page.deinit(alloc);
        try self.pages.insert(alloc, 0, page);
        if (self.pages.items.len <= max_child_history_pages) return;
        var evicted = self.pages.pop().?;
        evicted.deinit(alloc);
        self.has_newest = false;
    }

    pub fn olderCursor(self: ChildChatPageCache) ?[]const u8 {
        if (self.pages.items.len == 0) return null;
        return self.pages.items[0].history.next_cursor;
    }
};

pub const ChildMessage = struct {
    id: []u8,
    source_id: []u8,
    identity_source: ?domain.OperationIdentitySource,
    content: []u8,
    status: domain.QueueStatus,
    created_at_ms: i64,

    pub fn deinit(self: *ChildMessage, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.source_id);
        alloc.free(self.content);
        self.* = undefined;
    }
};

pub const ChildChat = struct {
    child_id: []u8,
    parent_id: ?[]u8,
    mode: domain.Mode,
    state: domain.State,
    generation: u64,
    configuration: domain.Configuration,
    external_busy: bool,
    failure_reason: ?[]u8 = null,
    messages: []ChildMessage,
    activity: []Activity,
    live: ?execution.LivePresentation,
    page: ?ChildChatPage,

    pub fn deinit(self: *ChildChat, alloc: Allocator) void {
        alloc.free(self.child_id);
        if (self.parent_id) |parent_id| alloc.free(parent_id);
        self.configuration.deinit(alloc);
        if (self.failure_reason) |reason| alloc.free(reason);
        for (self.messages) |*message| message.deinit(alloc);
        alloc.free(self.messages);
        for (self.activity) |*item| item.deinit(alloc);
        alloc.free(self.activity);
        if (self.live) |*live| live.deinit(alloc);
        if (self.page) |*page| page.deinit(alloc);
        self.* = undefined;
    }

    pub fn takePage(self: *ChildChat) ChildChatPage {
        const page = self.page.?;
        self.page = null;
        return page;
    }

    pub fn messageable(self: ChildChat) bool {
        return self.mode == .persistent and self.state != .archived;
    }

    pub fn busy(self: ChildChat) bool {
        if (self.external_busy) return true;
        return self.state == .queued or
            self.state == .running or
            self.state == .awaiting_approval;
    }

    /// Returned labels borrow either `worker_status_projection` or this
    /// child chat's live presentation and share their lifetime.
    pub fn activityProjection(
        self: *const ChildChat,
        worker_status_projection: ?activity_runtime.ActivityProjection,
    ) activity_runtime.ActivityProjection {
        if (worker_status_projection) |projection| return projection;
        if (!self.busy()) return .none;
        if (self.live) |live| {
            for (live.events, 0..) |_, reverse_index| {
                const event = live.events[live.events.len - 1 - reverse_index];
                const lifecycle = switch (event) {
                    .tool_lifecycle => |value| value,
                    else => continue,
                };
                switch (lifecycle) {
                    .provisional => |value| return .{ .turn_thinking = .{
                        .label = value.tool_name orelse "tool",
                        .tone = .thinking,
                    } },
                    .authoritative_started => |value| return .{ .turn_thinking = .{
                        .label = value.tool_name,
                        .tone = .thinking,
                    } },
                    .progress => |value| return .{ .turn_thinking = .{
                        .label = value.text,
                        .tone = .thinking,
                    } },
                    .terminal => |value| return .{ .turn_thinking = .{
                        .label = value.outcome.summary,
                        .tone = switch (value.outcome.kind) {
                            .completed => .success,
                            .denied, .cancelled, .failed => .danger,
                            .deferred => .thinking,
                        },
                    } },
                    .turn_finished => {},
                }
            }
            if (live.tools.len > 0) {
                const tool = live.tools[live.tools.len - 1];
                return .{ .turn_thinking = .{
                    .label = tool.tool_name,
                    .tone = switch (tool.phase) {
                        .started => .thinking,
                        .succeeded => .success,
                        .failed, .denied => .danger,
                    },
                } };
            }
        }
        return .none;
    }
};

pub const ChildUnavailable = enum {
    not_found,
    unreadable,
    invalid,
    store_failure,
};

pub const ChildChatLoadResult = union(enum) {
    chat: ChildChat,
    stale_cursor,
    unavailable: ChildUnavailable,

    pub fn deinit(self: *ChildChatLoadResult, alloc: Allocator) void {
        switch (self.*) {
            .chat => |*chat| chat.deinit(alloc),
            .stale_cursor, .unavailable => {},
        }
        self.* = undefined;
    }
};

/// Builds one allocator-owned, bounded projection from authoritative manager,
/// communication, approval, and execution state. No transcript is opened.
pub fn load(alloc: Allocator, source: Source) !LoadResult {
    return loadPage(alloc, source, null, null);
}

/// Builds one bounded page. A stale cursor restarts at the authoritative root,
/// where the manager resolves the page containing the immutable anchor.
pub fn loadPage(
    alloc: Allocator,
    source: Source,
    cursor: ?[]const u8,
    anchor_id: ?[]const u8,
) !LoadResult {
    return loadPageWithTreeLimit(
        alloc,
        source,
        cursor,
        anchor_id,
        max_nodes,
    );
}

fn loadPageWithTreeLimit(
    alloc: Allocator,
    source: Source,
    cursor: ?[]const u8,
    anchor_id: ?[]const u8,
    tree_limit: usize,
) !LoadResult {
    std.debug.assert(tree_limit > 0 and tree_limit <= max_nodes);
    var tree_result = try source.manager.snapshot(alloc, .{
        .root_id = source.root_id,
        .cursor = cursor,
        .limit = tree_limit,
        .hide_terminal_one_off = true,
    });
    var restarted = false;

    switch (tree_result) {
        .failure => |failure| {
            tree_result.deinit(alloc);
            return .{ .degraded = failure.code };
        },
        .snapshot => |snapshot| if (snapshot.restart_required) {
            tree_result.deinit(alloc);
            restarted = true;
            tree_result = try source.manager.snapshot(alloc, .{
                .root_id = source.root_id,
                .anchor_id = anchor_id,
                .limit = tree_limit,
                .hide_terminal_one_off = true,
            });
        },
    }

    const tree = switch (tree_result) {
        .failure => |failure| {
            tree_result.deinit(alloc);
            return .{ .degraded = failure.code };
        },
        .snapshot => |*snapshot| snapshot,
    };
    if (tree.restart_required) {
        tree_result.deinit(alloc);
        return .{ .degraded = .graph_changed };
    }
    defer tree_result.deinit(alloc);
    return projectTreePage(alloc, source, tree, restarted);
}

/// Loads one bounded canonical history page and the manager-owned metadata
/// required to present it. The returned value owns every allocation.
pub fn loadChildChat(
    alloc: Allocator,
    source: Source,
    child_id: []const u8,
    cursor: ?[]const u8,
) !ChildChatLoadResult {
    var history = source.sessions.loadHistoryPage(
        alloc,
        child_id,
        cursor,
        child_history_page_limit,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StaleHistoryPageCursor => .stale_cursor,
        error.SessionNotFound => .{ .unavailable = .not_found },
        error.InvalidSessionId,
        error.InvalidHistoryPageLimit,
        error.InvalidHistoryPageCursor,
        error.SessionPathUnsafe,
        => .{ .unavailable = .invalid },
        error.UnsupportedSessionFormat,
        error.CorruptSession,
        => .{ .unavailable = .unreadable },
        error.SessionStoreUnavailable => .{ .unavailable = .store_failure },
    };
    errdefer history.deinit(alloc);

    var capability = source.sessions.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        history.deinit(alloc);
        return switch (err) {
            error.OutOfMemory => unreachable,
            error.SessionNotFound => .{ .unavailable = .not_found },
            error.InvalidSessionId, error.SessionPathUnsafe => .{ .unavailable = .invalid },
            error.PrivateStatePermissionsUnsupported,
            error.SessionStoreUnavailable,
            error.SessionChildStoreFailed,
            => .{ .unavailable = .store_failure },
        };
    };
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = child_id,
    };
    var record = control.load(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        history.deinit(alloc);
        return switch (err) {
            error.OutOfMemory => unreachable,
            error.ControlNotFound => .{ .unavailable = .not_found },
            error.InvalidControlRecord,
            error.UnsupportedControlSchema,
            error.ControlRecordTooLarge,
            => .{ .unavailable = .unreadable },
            error.ControlPathUnsafe => .{ .unavailable = .invalid },
            error.PrivateStatePermissionsUnsupported,
            error.ControlStoreFailed,
            => .{ .unavailable = .store_failure },
        };
    };
    defer record.deinit(alloc);

    const sources = try projectTurnSources(alloc, history.turns, record.queue);
    errdefer freeTurnSources(alloc, sources);
    const messages = try projectChildMessages(alloc, history.turns, record.queue);
    errdefer freeChildMessages(alloc, messages);
    var live = if (source.owner) |owner|
        try owner.snapshotLivePresentation(alloc, child_id)
    else
        null;
    errdefer if (live) |*value| value.deinit(alloc);
    if (live) |*value| {
        if (historyContainsWorkId(history.turns, value.work_id)) {
            value.deinit(alloc);
            live = null;
        }
    }
    const activity = projectChildActivity(
        alloc,
        &capability,
        child_id,
        source.root_id,
        if (live) |value| value.work_id else null,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (live) |*value| value.deinit(alloc);
        freeChildMessages(alloc, messages);
        freeTurnSources(alloc, sources);
        history.deinit(alloc);
        return .{ .unavailable = .unreadable };
    };
    errdefer freeActivity(alloc, activity);

    const owned_child_id = try alloc.dupe(u8, record.child_id);
    errdefer alloc.free(owned_child_id);
    const parent_id = if (record.parent_id) |parent_id_value|
        try alloc.dupe(u8, parent_id_value)
    else
        null;
    errdefer if (parent_id) |parent_id_value| alloc.free(parent_id_value);
    var configuration = try record.configuration.clone(alloc);
    errdefer configuration.deinit(alloc);
    const failure_reason = try cloneLatestFailureReason(alloc, record.events);
    errdefer if (failure_reason) |reason| alloc.free(reason);
    const external_busy = if (source.owner) |owner|
        owner.externalBusy(child_id)
    else
        false;

    return .{ .chat = .{
        .child_id = owned_child_id,
        .parent_id = parent_id,
        .mode = record.mode,
        .state = record.state,
        .generation = record.generation,
        .configuration = configuration,
        .external_busy = external_busy,
        .failure_reason = failure_reason,
        .messages = messages,
        .activity = activity,
        .live = live,
        .page = .{
            .history = history,
            .sources = sources,
        },
    } };
}

fn projectTurnSources(
    alloc: Allocator,
    turns: []const session.HistoryTurn,
    messages: []const domain.QueuedMessage,
) ![]OwnedTurnSource {
    const sources = try alloc.alloc(OwnedTurnSource, turns.len);
    var built: usize = 0;
    errdefer {
        for (sources[0..built]) |*source| source.deinit(alloc);
        alloc.free(sources);
    }
    for (turns) |turn| {
        const resolved: TurnSource = if (turn == .compacted_summary)
            .not_applicable
        else
            resolveTurnSource(session.historyTurnWorkId(turn), messages);
        sources[built] = switch (resolved) {
            .not_applicable => .not_applicable,
            .ordinary_human => .ordinary_human,
            .unavailable => .unavailable,
            .manager_source => |source| .{
                .manager_source = .{
                    .source_id = try alloc.dupe(u8, source.source_id),
                    .identity_source = source.identity_source,
                },
            },
        };
        built += 1;
    }
    return sources;
}

fn freeTurnSources(alloc: Allocator, sources: []OwnedTurnSource) void {
    for (sources) |*source| source.deinit(alloc);
    alloc.free(sources);
}

fn historyContainsWorkId(turns: []const session.HistoryTurn, work_id: []const u8) bool {
    for (turns) |turn| {
        const candidate = session.historyTurnWorkId(turn) orelse continue;
        if (std.mem.eql(u8, candidate, work_id)) return true;
    }
    return false;
}

fn projectChildMessages(
    alloc: Allocator,
    turns: []const session.HistoryTurn,
    messages: []const domain.QueuedMessage,
) ![]ChildMessage {
    var active_count: usize = 0;
    for (messages) |message| {
        if (historyContainsWorkId(turns, message.id)) continue;
        switch (message.status) {
            .pending, .running, .awaiting_approval, .interrupted => active_count += 1,
            .completed, .failed, .cancelled => {},
        }
    }
    const keep = @min(active_count, max_child_messages);
    const projected = try alloc.alloc(ChildMessage, keep);
    var built: usize = 0;
    errdefer {
        for (projected[0..built]) |*message| message.deinit(alloc);
        alloc.free(projected);
    }
    var skip = active_count - keep;
    for (messages) |message| {
        if (historyContainsWorkId(turns, message.id)) continue;
        switch (message.status) {
            .completed, .failed, .cancelled => continue,
            .pending, .running, .awaiting_approval, .interrupted => {},
        }
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        const id = try alloc.dupe(u8, message.id);
        errdefer alloc.free(id);
        const source_id = try alloc.dupe(u8, message.source_id);
        errdefer alloc.free(source_id);
        projected[built] = .{
            .id = id,
            .source_id = source_id,
            .identity_source = if (tool_result.parseBoundOperationId(message.id)) |identity|
                identity.source
            else
                null,
            .content = try alloc.dupe(u8, message.content),
            .status = message.status,
            .created_at_ms = message.created_at_ms,
        };
        built += 1;
    }
    return projected;
}

fn freeChildMessages(alloc: Allocator, messages: []ChildMessage) void {
    for (messages) |*message| message.deinit(alloc);
    alloc.free(messages);
}

fn projectChildActivity(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    child_id: []const u8,
    target_id: []const u8,
    live_work_id: ?[]const u8,
) communication_store.LoadError![]Activity {
    const store = communication_store.Store{
        .capability = capability,
        .expected_session_id = child_id,
    };
    const maybe_ledger = try store.loadOptional(alloc);
    if (maybe_ledger == null) return alloc.alloc(Activity, 0);
    var ledger = maybe_ledger.?;
    defer ledger.deinit(alloc);
    var relevant: usize = 0;
    for (ledger.deliveries) |delivery| {
        if (std.mem.eql(u8, delivery.target_id, target_id) and
            !deliveryMatchesWork(delivery, live_work_id)) relevant += 1;
    }
    const keep = @min(relevant, max_activity);
    const activity = try alloc.alloc(Activity, keep);
    var built: usize = 0;
    errdefer {
        for (activity[0..built]) |*item| item.deinit(alloc);
        alloc.free(activity);
    }
    var skip = relevant - keep;
    for (ledger.deliveries) |delivery| {
        if (!std.mem.eql(u8, delivery.target_id, target_id) or
            deliveryMatchesWork(delivery, live_work_id)) continue;
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        activity[built] = .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .timestamp_ms = delivery.timestamp_ms,
            .kind = std.meta.activeTag(delivery.payload),
            .summary = try activitySummary(alloc, delivery.payload),
        };
        built += 1;
    }
    return activity;
}

fn deliveryMatchesWork(
    delivery: communication.Delivery,
    work_id: ?[]const u8,
) bool {
    const expected = work_id orelse return false;
    const actual = delivery.work_id orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn freeActivity(alloc: Allocator, activity: []Activity) void {
    for (activity) |*item| item.deinit(alloc);
    alloc.free(activity);
}

fn projectTreePage(
    alloc: Allocator,
    source: Source,
    tree: *const manager_mod.TreeSnapshot,
    restarted: bool,
) !LoadResult {
    var pending = try projectPendingApprovals(alloc, source);
    errdefer pending.deinit(alloc);
    const nodes = try alloc.alloc(Node, tree.nodes.len);
    var built: usize = 0;
    errdefer {
        for (nodes[0..built]) |*node| node.deinit(alloc);
        alloc.free(nodes);
    }
    for (tree.nodes) |tree_node| {
        nodes[built] = try projectNode(alloc, source, tree_node);
        built += 1;
    }
    const content_hash = snapshotContentHash(
        tree.*,
        nodes,
        pending.approvals,
        pending.revision,
        pending.total,
        pending.offset,
        tree.page_cursor,
        restarted,
    );

    const root_id = try alloc.dupe(u8, tree.root_id);
    errdefer alloc.free(root_id);
    const page_cursor = if (tree.page_cursor) |cursor| try alloc.dupe(u8, cursor) else null;
    errdefer if (page_cursor) |cursor| alloc.free(cursor);
    const next_cursor = if (tree.next_cursor) |cursor| try alloc.dupe(u8, cursor) else null;
    errdefer if (next_cursor) |cursor| alloc.free(cursor);
    const diagnostics = try cloneDiagnostics(alloc, tree.diagnostics);
    errdefer freeDiagnostics(alloc, diagnostics);
    return .{ .snapshot = .{
        .root_id = root_id,
        .revision = tree.revision,
        .approval_revision = pending.revision,
        .content_hash = content_hash,
        .restart_required = restarted,
        .nodes = nodes,
        .pending_approvals = pending.approvals,
        .pending_approval_total = pending.total,
        .pending_approval_offset = pending.offset,
        .pending_approval_previous_offset = pending.previous_offset,
        .pending_approval_next_offset = pending.next_offset,
        .page_cursor = page_cursor,
        .next_cursor = next_cursor,
        .diagnostics = diagnostics,
        .diagnostics_truncated = tree.diagnostics_truncated,
    } };
}

const PendingApprovalProjection = struct {
    revision: u64,
    total: usize,
    offset: usize,
    previous_offset: ?usize,
    next_offset: ?usize,
    approvals: []PendingApproval,

    fn deinit(self: *PendingApprovalProjection, alloc: Allocator) void {
        for (self.approvals) |*approval| approval.deinit(alloc);
        alloc.free(self.approvals);
        self.* = undefined;
    }
};

fn projectPendingApprovals(
    alloc: Allocator,
    source: Source,
) !PendingApprovalProjection {
    const registry = source.approval_registry orelse return .{
        .revision = 0,
        .total = 0,
        .offset = 0,
        .previous_offset = null,
        .next_offset = null,
        .approvals = try alloc.alloc(PendingApproval, 0),
    };
    var routes = try registry.snapshotPendingRoutes(
        alloc,
        source.pending_approval_offset,
        pending_approval_page_limit,
    );
    defer routes.deinit(alloc);

    var approvals: std.ArrayList(PendingApproval) = .empty;
    errdefer {
        for (approvals.items) |*approval| approval.deinit(alloc);
        approvals.deinit(alloc);
    }
    try approvals.ensureTotalCapacity(alloc, routes.routes.len);
    for (routes.routes) |route| {
        if (try projectPendingApproval(alloc, source, route)) |approval| {
            approvals.appendAssumeCapacity(approval);
        }
    }
    return .{
        .revision = routes.revision,
        .total = routes.total,
        .offset = routes.offset,
        .previous_offset = routes.previous_offset,
        .next_offset = routes.next_offset,
        .approvals = try approvals.toOwnedSlice(alloc),
    };
}

fn projectPendingApproval(
    alloc: Allocator,
    source: Source,
    route: approval_registry.PendingRoute,
) !?PendingApproval {
    var capability = source.sessions.openSubagentControlCapabilityReadOnly(
        alloc,
        route.child_id,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    defer capability.deinit();

    const communication_state = communication_store.Store{
        .capability = &capability,
        .expected_session_id = route.child_id,
    };
    const maybe_ledger = communication_state.loadOptional(alloc) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    var ledger = maybe_ledger orelse return null;
    defer ledger.deinit(alloc);
    const approval = communication.findApproval(
        ledger.approvals,
        route.request_id,
    ) orelse return null;
    if (approval.status != .pending or
        !std.mem.eql(u8, approval.child_id, route.child_id) or
        !std.mem.eql(u8, approval.root_id, source.root_id)) return null;

    const child_id = try alloc.dupe(u8, route.child_id);
    errdefer alloc.free(child_id);
    const child_name = child_name: {
        const control = control_store.Store{
            .capability = &capability,
            .expected_child_id = route.child_id,
        };
        var record = control.load(alloc) catch break :child_name try alloc.dupe(u8, route.child_id);
        defer record.deinit(alloc);
        break :child_name try alloc.dupe(u8, record.configuration.name);
    };
    errdefer alloc.free(child_name);
    var request = try projectApproval(alloc, approval.*);
    errdefer request.deinit(alloc);
    const tool_arguments_preview = if (route.tool_arguments_preview) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (tool_arguments_preview) |value| alloc.free(value);
    return .{
        .child_id = child_id,
        .child_name = child_name,
        .request = request,
        .tool_arguments_preview = tool_arguments_preview,
    };
}

pub fn acknowledge(
    alloc: Allocator,
    source: Source,
    child_id: []const u8,
    through_sequence: u64,
) communication_manager.Error!void {
    if (through_sequence == 0) return;
    var manager = communication_manager.Manager{ .sessions = source.sessions };
    try manager.acknowledge(
        alloc,
        child_id,
        consumer_id,
        source.root_id,
        through_sequence,
    );
}

fn projectNode(alloc: Allocator, source: Source, tree_node: manager_mod.TreeNode) !Node {
    var node = try initNode(
        alloc,
        tree_node,
        if (source.owner) |owner|
            owner.externalBusy(tree_node.child_id)
        else
            false,
    );
    errdefer node.deinit(alloc);

    var capability = source.sessions.openSubagentControlCapabilityReadOnly(
        alloc,
        tree_node.child_id,
        .{},
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        node.degraded = mapOpenError(err);
        return node;
    };
    defer capability.deinit();
    const control = control_store.Store{
        .capability = &capability,
        .expected_child_id = tree_node.child_id,
    };
    var record = control.load(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        node.degraded = mapControlLoadError(err);
        return node;
    };
    defer record.deinit(alloc);
    node.configuration = try record.configuration.clone(alloc);
    node.failure_reason = try cloneLatestFailureReason(alloc, record.events);

    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = tree_node.child_id,
    };
    const maybe_ledger = store.loadOptional(alloc) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        node.degraded = mapLoadError(err);
        return node;
    };
    if (maybe_ledger == null) return node;
    var ledger = maybe_ledger.?;
    defer ledger.deinit(alloc);
    try projectLedger(alloc, &node, ledger, source.root_id);
    return node;
}

fn initNode(
    alloc: Allocator,
    tree_node: manager_mod.TreeNode,
    external_busy: bool,
) !Node {
    const child_id = try alloc.dupe(u8, tree_node.child_id);
    errdefer alloc.free(child_id);
    const parent_id = try alloc.dupe(u8, tree_node.parent_id);
    errdefer alloc.free(parent_id);
    const name = try alloc.dupe(u8, tree_node.name);
    errdefer alloc.free(name);
    const empty_activity = try alloc.alloc(Activity, 0);
    errdefer alloc.free(empty_activity);
    const empty_approvals = try alloc.alloc(Approval, 0);
    return .{
        .child_id = child_id,
        .parent_id = parent_id,
        .name = name,
        .mode = tree_node.mode,
        .state = tree_node.state,
        .generation = tree_node.generation,
        .depth = tree_node.depth,
        .relationship_issue = tree_node.relationship_issue,
        .external_busy = external_busy,
        .activity = empty_activity,
        .approvals = empty_approvals,
    };
}

fn projectLedger(
    alloc: Allocator,
    node: *Node,
    ledger: communication.Ledger,
    target_id: []const u8,
) !void {
    const acknowledged = acknowledgedSequence(ledger, target_id);
    node.stale = cursorStale(ledger, target_id);

    var relevant_count: usize = 0;
    var unread_count: usize = 0;
    var latest_sequence: u64 = 0;
    for (ledger.deliveries) |delivery| {
        if (!std.mem.eql(u8, delivery.target_id, target_id)) continue;
        relevant_count += 1;
        latest_sequence = delivery.sequence;
        if (delivery.sequence > acknowledged) unread_count += 1;
    }
    node.unread_count = @min(unread_count, max_activity);
    node.unread_truncated = unread_count > max_activity;
    node.through_sequence = @max(
        latest_sequence,
        communication.retentionGapThrough(ledger, target_id, .human),
    );

    const activity_count = @min(relevant_count, max_activity);
    const activity = try alloc.alloc(Activity, activity_count);
    var built_activity: usize = 0;
    errdefer {
        for (activity[0..built_activity]) |*value| value.deinit(alloc);
        alloc.free(activity);
    }
    var skip = relevant_count - activity_count;
    for (ledger.deliveries) |delivery| {
        if (!std.mem.eql(u8, delivery.target_id, target_id)) continue;
        if (skip > 0) {
            skip -= 1;
            continue;
        }
        activity[built_activity] = .{
            .sequence = delivery.sequence,
            .revision = delivery.revision,
            .timestamp_ms = delivery.timestamp_ms,
            .kind = std.meta.activeTag(delivery.payload),
            .summary = try activitySummary(alloc, delivery.payload),
        };
        built_activity += 1;
    }

    var pending_count: usize = 0;
    for (ledger.approvals) |approval| {
        if (approval.status == .pending and
            std.mem.eql(u8, approval.root_id, target_id)) pending_count += 1;
    }
    const approval_count = @min(pending_count, max_approvals);
    const approvals = try alloc.alloc(Approval, approval_count);
    var built_approvals: usize = 0;
    errdefer {
        for (approvals[0..built_approvals]) |*value| value.deinit(alloc);
        alloc.free(approvals);
    }
    var approval_skip = pending_count - approval_count;
    for (ledger.approvals) |approval| {
        if (approval.status != .pending or
            !std.mem.eql(u8, approval.root_id, target_id)) continue;
        if (approval_skip > 0) {
            approval_skip -= 1;
            continue;
        }
        approvals[built_approvals] = try projectApproval(alloc, approval);
        built_approvals += 1;
    }

    alloc.free(node.activity);
    alloc.free(node.approvals);
    node.activity = activity;
    node.approvals = approvals;
}

fn acknowledgedSequence(ledger: communication.Ledger, target_id: []const u8) u64 {
    for (ledger.cursors) |cursor| {
        if (cursor.projection == .human and
            std.mem.eql(u8, cursor.consumer_id, consumer_id) and
            std.mem.eql(u8, cursor.target_id, target_id))
        {
            return cursor.acknowledged_sequence;
        }
    }
    return 0;
}

fn cursorStale(ledger: communication.Ledger, target_id: []const u8) bool {
    for (ledger.cursors) |cursor| {
        if (cursor.projection == .human and
            std.mem.eql(u8, cursor.consumer_id, consumer_id) and
            std.mem.eql(u8, cursor.target_id, target_id))
        {
            return cursor.stale;
        }
    }
    return communication.retentionGapThrough(ledger, target_id, .human) != 0;
}

fn activitySummary(alloc: Allocator, payload: communication.DeliveryPayload) ![]u8 {
    return switch (payload) {
        .message => |value| dupeBounded(alloc, value),
        .milestone => |value| dupeBounded(alloc, value),
        .terminal => |state| std.fmt.allocPrint(alloc, "state: {s}", .{@tagName(state)}),
        .interval => |value| std.fmt.allocPrint(
            alloc,
            "state: {s} ({d} coalesced updates)",
            .{ @tagName(value.state), value.coalesced_ticks },
        ),
        .approval => |value| dupeBounded(alloc, value),
        .tool_activity => |value| std.fmt.allocPrint(
            alloc,
            "{s}: {s}",
            .{ value.tool_name[0..@min(value.tool_name.len, max_summary_bytes)], @tagName(value.phase) },
        ),
    };
}

fn cloneLatestFailureReason(
    alloc: Allocator,
    events: []const domain.Event,
) Allocator.Error!?[]u8 {
    const failure = manager_mod.latestWorkFailure(events) orelse return null;
    const owned: ?[]u8 = try alloc.dupe(u8, failure.reason);
    return owned;
}

fn projectApproval(alloc: Allocator, approval: communication.Approval) !Approval {
    const id = try alloc.dupe(u8, approval.id);
    errdefer alloc.free(id);
    const label = try dupeBounded(alloc, approval.label);
    errdefer alloc.free(label);
    const explanation = if (approval.explanation) |value|
        try dupeBounded(alloc, value)
    else
        null;
    errdefer if (explanation) |value| alloc.free(value);
    const command = if (approval.command) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (command) |value| alloc.free(value);
    const file = if (approval.file) |value|
        try permission_request.dupeFileApprovalRequest(alloc, value)
    else
        null;
    errdefer if (file) |value| {
        permission_request.deinitFileApprovalRequest(alloc, value);
    };
    return .{
        .id = id,
        .kind = approval.kind,
        .status = approval.status,
        .label = label,
        .explanation = explanation,
        .command = command,
        .file = file,
    };
}

fn dupeBounded(alloc: Allocator, value: []const u8) ![]u8 {
    return alloc.dupe(u8, value[0..@min(value.len, max_summary_bytes)]);
}

fn cloneDiagnostics(
    alloc: Allocator,
    diagnostics: []const manager_mod.TreeDiagnostic,
) ![]manager_mod.TreeDiagnostic {
    const out = try alloc.alloc(manager_mod.TreeDiagnostic, diagnostics.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*diagnostic| diagnostic.deinit(alloc);
        alloc.free(out);
    }
    for (diagnostics) |diagnostic| {
        const session_id = try alloc.dupe(u8, diagnostic.session_id);
        errdefer alloc.free(session_id);
        const parent_id = if (diagnostic.parent_id) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (parent_id) |value| alloc.free(value);
        out[built] = .{
            .session_id = session_id,
            .parent_id = parent_id,
            .code = diagnostic.code,
        };
        built += 1;
    }
    return out;
}

fn freeDiagnostics(alloc: Allocator, diagnostics: []manager_mod.TreeDiagnostic) void {
    for (diagnostics) |*diagnostic| diagnostic.deinit(alloc);
    alloc.free(diagnostics);
}

fn mapOpenError(err: session_store.OpenSubagentControlError) DegradedReason {
    return switch (err) {
        error.SessionNotFound => .session_unavailable,
        error.SessionPathUnsafe, error.InvalidSessionId => .path_unsafe,
        error.PrivateStatePermissionsUnsupported,
        error.SessionStoreUnavailable,
        error.SessionChildStoreFailed,
        => .store_failure,
        error.OutOfMemory => unreachable,
    };
}

fn snapshotContentHash(
    tree: manager_mod.TreeSnapshot,
    nodes: []const Node,
    pending_approvals: []const PendingApproval,
    approval_revision: u64,
    pending_approval_total: usize,
    pending_approval_offset: usize,
    page_cursor: ?[]const u8,
    restarted: bool,
) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(tree.root_id);
    hashValue(&hash, tree.revision);
    hashValue(&hash, approval_revision);
    hashValue(&hash, pending_approval_total);
    hashValue(&hash, pending_approval_offset);
    hashValue(&hash, restarted);
    if (page_cursor) |cursor| hash.update(cursor);
    for (nodes) |node| {
        hash.update(node.child_id);
        hash.update(node.parent_id);
        hash.update(node.name);
        hashValue(&hash, node.mode);
        hashValue(&hash, node.state);
        hashValue(&hash, node.generation);
        hashValue(&hash, node.depth);
        if (node.relationship_issue) |issue| hashValue(&hash, issue);
        if (node.configuration) |configuration| {
            hash.update(configuration.name);
            if (configuration.model) |model| hash.update(model);
            if (configuration.effort) |effort| {
                const effort_label = effort.label();
                hashValue(&hash, effort_label.len);
                hash.update(effort_label);
            }
            hashValue(&hash, configuration.permission_mode);
            hashValue(&hash, configuration.notifications.terminal.completed);
            hashValue(&hash, configuration.notifications.terminal.failed);
            hashValue(&hash, configuration.notifications.terminal.cancelled);
            for (configuration.notifications.milestones) |milestone| hash.update(milestone);
            if (configuration.notifications.report_interval_ms) |interval| hashValue(&hash, interval);
            if (configuration.notifications.report_duration_ms) |duration| hashValue(&hash, duration);
            for (configuration.notifications.stop_conditions) |condition| hashValue(&hash, condition);
        }
        hashValue(&hash, node.external_busy);
        hashValue(&hash, node.unread_count);
        hashValue(&hash, node.unread_truncated);
        hashValue(&hash, node.through_sequence);
        hashValue(&hash, node.stale);
        if (node.degraded) |reason| hashValue(&hash, reason);
        if (node.failure_reason) |reason| hash.update(reason);
        for (node.activity) |activity| {
            hashValue(&hash, activity.sequence);
            hashValue(&hash, activity.revision);
            hashValue(&hash, activity.kind);
            hash.update(activity.summary);
        }
        for (node.approvals) |approval| {
            hash.update(approval.id);
            hashValue(&hash, approval.kind);
            hashValue(&hash, approval.status);
            hash.update(approval.label);
            if (approval.explanation) |explanation| hash.update(explanation);
            if (approval.command) |command| hash.update(command);
        }
    }
    for (pending_approvals) |approval| {
        hash.update(approval.child_id);
        hash.update(approval.child_name);
        hash.update(approval.request.id);
        hashValue(&hash, approval.request.kind);
        hashValue(&hash, approval.request.status);
        hash.update(approval.request.label);
        if (approval.request.explanation) |explanation| hash.update(explanation);
        if (approval.request.command) |command| hash.update(command);
        if (approval.tool_arguments_preview) |preview| hash.update(preview);
    }
    for (tree.diagnostics) |diagnostic| {
        hash.update(diagnostic.session_id);
        if (diagnostic.parent_id) |parent_id| hash.update(parent_id);
        hashValue(&hash, diagnostic.code);
    }
    hashValue(&hash, tree.diagnostics_truncated);
    return hash.final();
}

fn mapControlLoadError(err: control_store.LoadError) DegradedReason {
    return switch (err) {
        error.ControlNotFound => .session_unavailable,
        error.InvalidControlRecord,
        error.UnsupportedControlSchema,
        => .invalid_record,
        error.ControlRecordTooLarge => .record_too_large,
        error.ControlPathUnsafe => .path_unsafe,
        error.PrivateStatePermissionsUnsupported,
        error.ControlStoreFailed,
        => .store_failure,
        error.OutOfMemory => unreachable,
    };
}

fn hashValue(hash: *std.hash.Wyhash, value: anytype) void {
    var copy = value;
    hash.update(std.mem.asBytes(&copy));
}

fn mapLoadError(err: communication_store.LoadError) DegradedReason {
    return switch (err) {
        error.CommunicationNotFound => .session_unavailable,
        error.InvalidCommunicationRecord,
        error.UnsupportedCommunicationSchema,
        => .invalid_record,
        error.CommunicationRecordTooLarge => .record_too_large,
        error.CommunicationPathUnsafe => .path_unsafe,
        error.PrivateStatePermissionsUnsupported,
        error.CommunicationStoreFailed,
        => .store_failure,
        error.OutOfMemory => unreachable,
    };
}

fn checkExtendedProjectionAllocationFailures(alloc: Allocator) !void {
    var command = try domain.validateCommand(alloc, .{ .create = .{
        .name = "configured child",
        .mode = .persistent,
        .model = "openai/gpt-5",
        .effort = types.ReasoningEffort.literal("high"),
        .notifications = .{
            .milestones = &.{ "halfway", "verified" },
            .report_interval_ms = 5000,
            .report_duration_ms = 60000,
            .stop_conditions = &.{ .terminal, .duration_elapsed },
        },
    } });
    defer command.deinit(alloc);
    const nodes = try alloc.alloc(Node, 1);
    errdefer alloc.free(nodes);
    nodes[0] = try initNode(alloc, .{
        .child_id = @constCast("child-id"),
        .parent_id = @constCast("root-id"),
        .name = @constCast("configured child"),
        .mode = .persistent,
        .state = .idle,
        .generation = 1,
        .depth = 0,
    }, false);
    errdefer nodes[0].deinit(alloc);
    nodes[0].configuration = try command.create.configuration.clone(alloc);
    const root_id = try alloc.dupe(u8, "root-id");
    errdefer alloc.free(root_id);
    const page_cursor = try alloc.dupe(u8, "page-cursor");
    errdefer alloc.free(page_cursor);
    const next_cursor = try alloc.dupe(u8, "next-cursor");
    errdefer alloc.free(next_cursor);
    const diagnostics = try alloc.alloc(manager_mod.TreeDiagnostic, 0);
    errdefer alloc.free(diagnostics);
    const pending_approvals = try alloc.alloc(PendingApproval, 0);
    errdefer alloc.free(pending_approvals);
    var snapshot = Snapshot{
        .root_id = root_id,
        .revision = 1,
        .approval_revision = 0,
        .content_hash = 1,
        .restart_required = false,
        .nodes = nodes,
        .pending_approvals = pending_approvals,
        .page_cursor = page_cursor,
        .next_cursor = next_cursor,
        .diagnostics = diagnostics,
        .diagnostics_truncated = false,
    };
    snapshot.deinit(alloc);
}

fn findNodeInProjection(nodes: []const Node, child_id: []const u8) ?*const Node {
    for (nodes) |*node| {
        if (std.mem.eql(u8, node.child_id, child_id)) return node;
    }
    return null;
}

fn testChildChatPage(
    alloc: Allocator,
    session_id_value: []const u8,
    work_id: []const u8,
    source_id: []const u8,
    next_cursor_value: ?[]const u8,
) !ChildChatPage {
    const turns = try alloc.alloc(session.HistoryTurn, 1);
    var built_turns: usize = 0;
    errdefer {
        for (turns[0..built_turns]) |*turn| session.freeHistoryTurn(alloc, turn.*);
        alloc.free(turns);
    }
    turns[0] = try session.makeAssistantTurn(alloc, "prompt", "answer");
    built_turns = 1;
    try session.copyWorkIdToTurn(alloc, &turns[0], work_id);
    const session_id = try alloc.dupe(u8, session_id_value);
    errdefer alloc.free(session_id);
    const next_cursor = if (next_cursor_value) |value| try alloc.dupe(u8, value) else null;
    errdefer if (next_cursor) |value| alloc.free(value);
    const sources = try alloc.alloc(OwnedTurnSource, 1);
    errdefer alloc.free(sources);
    sources[0] = .{ .manager_source = .{
        .source_id = try alloc.dupe(u8, source_id),
        .identity_source = null,
    } };
    return .{
        .history = .{
            .session_id = session_id,
            .revision_ms = 1,
            .history_len = 1,
            .turns = turns,
            .next_cursor = next_cursor,
        },
        .sources = sources,
    };
}

fn checkChildChatPageCacheAllocationFailures(alloc: Allocator) !void {
    var cache = ChildChatPageCache{};
    defer cache.deinit(alloc);
    try cache.resetNewest(
        alloc,
        try testChildChatPage(alloc, "newest", "work-newest", "root", "older-1"),
    );
    try cache.addOlder(
        alloc,
        try testChildChatPage(alloc, "older-1", "work-1", "parent-1", "older-2"),
    );
    try cache.addOlder(
        alloc,
        try testChildChatPage(alloc, "older-2", "work-2", "parent-2", "older-3"),
    );
    try cache.addOlder(
        alloc,
        try testChildChatPage(alloc, "older-3", "work-3", "parent-3", null),
    );
}

fn checkTurnSourceProjectionAllocationFailures(alloc: Allocator) !void {
    var turn = try session.makeAssistantTurn(alloc, "same prompt", "answer");
    defer session.freeHistoryTurn(alloc, turn);
    try session.copyWorkIdToTurn(alloc, &turn, "work-source");
    const messages = [_]domain.QueuedMessage{.{
        .id = @constCast("work-source"),
        .source_id = @constCast("parent-source"),
        .content = @constCast("same prompt"),
        .created_at_ms = 1,
    }};
    const sources = try projectTurnSources(alloc, &.{turn}, &messages);
    freeTurnSources(alloc, sources);
}

fn makeProjectionTaggedHistory(alloc: Allocator, count: usize) ![]session.HistoryTurn {
    const turns = try alloc.alloc(session.HistoryTurn, count);
    var built: usize = 0;
    errdefer {
        for (turns[0..built]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(turns);
    }
    while (built < count) : (built += 1) {
        var prompt_buf: [64]u8 = undefined;
        const prompt = try std.fmt.bufPrint(&prompt_buf, "stored prompt {d}", .{built});
        turns[built] = try session.makeAssistantTurn(alloc, prompt, "stored answer");
        var work_buf: [32]u8 = undefined;
        const work_id = try std.fmt.bufPrint(&work_buf, "work-{d:0>2}", .{built});
        try session.copyWorkIdToTurn(alloc, &turns[built], work_id);
    }
    return turns;
}
