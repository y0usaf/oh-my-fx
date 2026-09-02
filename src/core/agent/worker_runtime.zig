const std = @import("std");
const secret = @import("../auth/secret.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const image_attachments = @import("../images/image_attachments.zig");
const context_contract = @import("../workspace/context_contract.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const permission_request = @import("../permissions/permission_request.zig");
const notification_contract = @import("../notifications/notification_contract.zig");
const session_runtime = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");
const assistant_presentation = @import("assistant_presentation.zig");

pub const AgentTurnSettings = struct {
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    first_call_tool_choice: types.ToolChoice = .auto,
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
};

pub const SkillBinding = struct {
    name: []u8,
    path: []u8,
};

pub const SkillDisplaySpan = struct {
    raw_start: usize,
    raw_end: usize,
    name: []u8,
    path: []u8,
    display_source: ?skill_contract.SkillSource = null,
    owns_trailing_separator: bool = false,
};

pub const BeginPromptWithSkillBindings = struct {
    prompt: types.UserTurn,
    skill_bindings: []SkillBinding = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
};

pub const QueueReviewDraft = struct {
    input: []u8,
    pasted_blocks: []paste_blocks.PastedBlock = &.{},
    image_tokens: []entity_spans.ImageTokenSpan = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
};

pub const QueuedPrompt = struct {
    turn_id: u64 = 0,
    /// The active turn that may consume this prompt as steering. When that turn
    /// finishes, the target is cleared in place so admission order is retained.
    steer_target_turn_id: ?u64 = null,
    prompt: []u8,
    images: []types.ImageAttachment,
    authorized_image_catalog: []types.ImageAttachment = &.{},
    model: []u8,
    provider: model_provider.ProviderId = .gateway,
    api_key: []u8,
    gateway_team: ?[]u8 = null,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    permission_mode: types.PermissionMode,
    history: []types.HistoryTurn,
    root_user_intent_context: []u8 = &.{},
    grants: []types.PermissionGrant,
    skill_bindings: []SkillBinding = &.{},
    skill_display_spans: []SkillDisplaySpan = &.{},
    review_draft: ?QueueReviewDraft = null,
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    agent_settings: AgentTurnSettings = .{},
    snapshot_file_ownerships: []types.SnapshotFileOwnership = &.{},
    /// Present only when an explicit host action resumes a durable paused
    /// model turn. The same ownership rules as the other queued fields apply.
    recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null,
    /// True when this output surface already contains the checkpoint's
    /// assistant source. Recovery still restores the source for overlap and
    /// persistence, but publishes only novel continuation text.
    recovery_source_already_presented: bool = false,
    /// The interactive transcript already contains this exact user turn.
    /// Worker begin publishes only its identity so the UI can consume the
    /// pending owner without painting a duplicate card.
    user_prompt_already_presented: bool = false,
};

pub const ActivePromptSnapshotOwnership = struct {
    /// Owns snapshot deletion until the files are transferred to accepted
    /// history or handed to a reference-counted finished-turn owner.
    images: []const types.ImageAttachment,
    state: enum {
        active,
        handed_off,
        preserved,
        discarded,
    } = .active,
    shared_ownership: ?types.SnapshotFileOwnership = null,

    pub fn init(images: []const types.ImageAttachment) ActivePromptSnapshotOwnership {
        return .{ .images = images };
    }

    fn ensureSharedOwnership(
        self: *ActivePromptSnapshotOwnership,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        if (self.images.len == 0) return null;
        if (self.shared_ownership) |ownership| return ownership;
        const ownership = (try SnapshotFileOwnershipState.create(alloc, self.images)).handle();
        self.shared_ownership = ownership;
        return ownership;
    }

    fn handoff(
        self: *ActivePromptSnapshotOwnership,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        if (self.state != .active or self.images.len == 0) return null;
        const ownership = (try self.ensureSharedOwnership(alloc)).?;
        self.state = .handed_off;
        return ownership;
    }

    fn preserve(self: *ActivePromptSnapshotOwnership) bool {
        if (self.images.len == 0) return false;
        switch (self.state) {
            .active => {
                if (self.shared_ownership) |ownership| ownership.transfer();
                self.state = .preserved;
                return true;
            },
            .handed_off => {
                if (self.shared_ownership) |ownership| ownership.transfer();
                return true;
            },
            .preserved => return true,
            .discarded => return false,
        }
    }

    fn deinit(self: *ActivePromptSnapshotOwnership) void {
        if (self.state == .active) {
            if (self.shared_ownership) |ownership| {
                ownership.release();
            } else {
                image_attachments.deleteUnreferencedImageSnapshots(self.images, &.{});
            }
            self.state = .discarded;
        }
    }
};

const SnapshotFileOwnershipState = struct {
    alloc: std.mem.Allocator,
    images: []types.ImageAttachment,
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    transferred: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn create(
        alloc: std.mem.Allocator,
        images: []const types.ImageAttachment,
    ) !*SnapshotFileOwnershipState {
        const owned_images = try types.dupeImageAttachmentSlice(alloc, images);
        errdefer types.freeImageAttachmentSlice(alloc, owned_images);
        const state = try alloc.create(SnapshotFileOwnershipState);
        state.* = .{
            .alloc = alloc,
            .images = owned_images,
        };
        return state;
    }

    fn handle(self: *SnapshotFileOwnershipState) types.SnapshotFileOwnership {
        return .{
            .ctx = self,
            .retain_fn = retain,
            .release_fn = release,
            .transfer_fn = transfer,
        };
    }

    fn retain(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        _ = self.references.fetchAdd(1, .seq_cst);
    }

    fn release(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        if (self.references.fetchSub(1, .seq_cst) != 1) return;
        if (!self.transferred.load(.seq_cst)) {
            image_attachments.deleteUnreferencedImageSnapshots(self.images, &.{});
        }
        const alloc = self.alloc;
        types.freeImageAttachmentSlice(alloc, self.images);
        alloc.destroy(self);
    }

    fn transfer(raw: *anyopaque) void {
        const self: *SnapshotFileOwnershipState = @ptrCast(@alignCast(raw));
        self.transferred.store(true, .seq_cst);
    }
};

fn historyTurnImages(turn: types.HistoryTurn) []const types.ImageAttachment {
    return switch (turn) {
        .assistant => |value| value.user.images,
        .background_command => |value| value.user.images,
        .interrupted => |value| value.user.images,
        .compacted_summary => &.{},
    };
}

fn sameImageSnapshots(
    left: []const types.ImageAttachment,
    right: []const types.ImageAttachment,
) bool {
    if (left.len == 0 or left.len != right.len) return false;
    for (left) |image| {
        const other = image_attachments.findById(right, image.id) orelse return false;
        if (!optionalBytesEqual(image.snapshot_path, other.snapshot_path) or
            !optionalBytesEqual(image.snapshot_sha256, other.snapshot_sha256))
        {
            return false;
        }
    }
    return true;
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

pub const PermissionSnapshot = struct {
    mode: types.PermissionMode,
};

pub const CommandOutputChunk = struct {
    lifecycle_id: ?types.ToolLifecycleId = null,
    stream: command_output_content.Stream,
    text: []u8,
};

pub const QueuePreview = struct {
    count: usize = 0,
    steering_count: usize = 0,
    paused: bool = false,
};

pub const QueueReviewReason = enum {
    manual,
    post_cancel,
};

pub const PromptDraftKind = enum { queued, steering };

pub const QueuedPromptDraft = struct {
    turn_id: u64,
    kind: PromptDraftKind = .queued,
    prompt: []u8,
    images: []types.ImageAttachment,
    skill_display_spans: []SkillDisplaySpan,
    review_draft: ?QueueReviewDraft = null,

    pub fn reviewInput(self: QueuedPromptDraft) []const u8 {
        return if (self.review_draft) |review| review.input else self.prompt;
    }

    pub fn reviewSkillDisplaySpans(
        self: QueuedPromptDraft,
    ) []const SkillDisplaySpan {
        return if (self.review_draft) |review|
            review.skill_display_spans
        else
            self.skill_display_spans;
    }
};

const PreparedQueuedPromptDraft = struct {
    turn_id: u64,
    kind: PromptDraftKind,
    prompt: []u8,
    images: []types.ImageAttachment,
    authorized_image_catalog: []types.ImageAttachment,
    skill_bindings: []SkillBinding,
    skill_display_spans: []SkillDisplaySpan,
    review_draft: ?QueueReviewDraft,
};

const PreparedHistoryPropagation = struct {
    history: []types.HistoryTurn,
    root_user_intent_context: []u8,
    authorized_image_catalog: []types.ImageAttachment,
    snapshot_file_ownerships: ?[]types.SnapshotFileOwnership,
    added_snapshot_ownership: ?types.SnapshotFileOwnership,

    fn deinit(self: PreparedHistoryPropagation, alloc: std.mem.Allocator) void {
        types.freeHistoryTurnSlice(alloc, self.history);
        alloc.free(self.root_user_intent_context);
        types.freeImageAttachmentSlice(alloc, self.authorized_image_catalog);
        if (self.added_snapshot_ownership) |ownership| ownership.release();
        if (self.snapshot_file_ownerships) |ownerships| alloc.free(ownerships);
    }
};

pub fn freeQueuedPromptDraft(alloc: std.mem.Allocator, draft: QueuedPromptDraft) void {
    alloc.free(draft.prompt);
    types.freeImageAttachmentSlice(alloc, draft.images);
    freeSkillDisplaySpans(alloc, draft.skill_display_spans);
    freeQueueReviewDraftOpt(alloc, draft.review_draft);
}

pub fn freeQueuedPromptDrafts(alloc: std.mem.Allocator, drafts: []QueuedPromptDraft) void {
    for (drafts) |draft| freeQueuedPromptDraft(alloc, draft);
    if (drafts.len > 0) alloc.free(drafts);
}

pub fn dupeQueueReviewDraft(
    alloc: std.mem.Allocator,
    draft: QueueReviewDraft,
) !QueueReviewDraft {
    const input = try alloc.dupe(u8, draft.input);
    errdefer alloc.free(input);

    const pasted_blocks: []paste_blocks.PastedBlock = if (draft.pasted_blocks.len > 0)
        try alloc.alloc(paste_blocks.PastedBlock, draft.pasted_blocks.len)
    else
        @constCast(&.{});
    var pasted_count: usize = 0;
    errdefer {
        for (pasted_blocks[0..pasted_count]) |block| alloc.free(block.text);
        if (pasted_blocks.len > 0) alloc.free(pasted_blocks);
    }
    while (pasted_count < draft.pasted_blocks.len) : (pasted_count += 1) {
        pasted_blocks[pasted_count] = .{
            .id = draft.pasted_blocks[pasted_count].id,
            .text = try alloc.dupe(u8, draft.pasted_blocks[pasted_count].text),
            .line_count = draft.pasted_blocks[pasted_count].line_count,
            .span = draft.pasted_blocks[pasted_count].span,
        };
    }

    const image_tokens: []entity_spans.ImageTokenSpan = if (draft.image_tokens.len > 0)
        try alloc.dupe(entity_spans.ImageTokenSpan, draft.image_tokens)
    else
        @constCast(&.{});
    errdefer if (image_tokens.len > 0) alloc.free(image_tokens);

    const skill_display_spans = try dupeSkillDisplaySpans(
        alloc,
        draft.skill_display_spans,
    );
    return .{
        .input = input,
        .pasted_blocks = pasted_blocks,
        .image_tokens = image_tokens,
        .skill_display_spans = skill_display_spans,
    };
}

pub fn freeQueueReviewDraft(
    alloc: std.mem.Allocator,
    draft: QueueReviewDraft,
) void {
    alloc.free(draft.input);
    for (draft.pasted_blocks) |block| alloc.free(block.text);
    if (draft.pasted_blocks.len > 0) alloc.free(draft.pasted_blocks);
    if (draft.image_tokens.len > 0) alloc.free(draft.image_tokens);
    freeSkillDisplaySpans(alloc, draft.skill_display_spans);
}

fn freeQueueReviewDraftOpt(
    alloc: std.mem.Allocator,
    draft: ?QueueReviewDraft,
) void {
    if (draft) |owned| freeQueueReviewDraft(alloc, owned);
}

fn freePreparedQueuedPromptDraft(alloc: std.mem.Allocator, draft: PreparedQueuedPromptDraft) void {
    alloc.free(draft.prompt);
    types.freeImageAttachmentSlice(alloc, draft.images);
    types.freeImageAttachmentSlice(alloc, draft.authorized_image_catalog);
    freeSkillBindings(alloc, draft.skill_bindings);
    freeSkillDisplaySpans(alloc, draft.skill_display_spans);
    freeQueueReviewDraftOpt(alloc, draft.review_draft);
}

fn skillBindingsFromDisplaySpans(
    alloc: std.mem.Allocator,
    spans: []const SkillDisplaySpan,
) ![]SkillBinding {
    var bindings: std.ArrayList(SkillBinding) = .empty;
    errdefer {
        for (bindings.items) |binding| {
            alloc.free(binding.name);
            alloc.free(binding.path);
        }
        bindings.deinit(alloc);
    }
    for (spans) |span| {
        var already_present = false;
        for (bindings.items) |binding| {
            if (std.mem.eql(u8, binding.path, span.path)) {
                already_present = true;
                break;
            }
        }
        if (already_present) continue;

        const name = try alloc.dupe(u8, span.name);
        errdefer alloc.free(name);
        const path = try alloc.dupe(u8, span.path);
        errdefer alloc.free(path);
        try bindings.append(alloc, .{ .name = name, .path = path });
    }
    if (bindings.items.len == 0) {
        bindings.deinit(alloc);
        return &.{};
    }
    return bindings.toOwnedSlice(alloc);
}

pub const StateSnapshot = struct {
    processing: bool = false,
    active_turn_id: u64 = 0,
    queued_count: usize = 0,
    pending_event_count: usize = 0,
    queue_review_reason: ?QueueReviewReason = null,
    cancel_requested: bool = false,
    pending_permission_request: ?permission_request.OwnedPermissionRequest = null,
    pending_permission_review: ?PendingPermissionReview = null,

    pub fn deinit(self: StateSnapshot, alloc: std.mem.Allocator) void {
        if (self.pending_permission_request) |request| {
            var owned = request;
            owned.deinit(alloc);
        }
    }
};

pub const PendingPermissionReview = struct {
    request_id: u64,
    review: *const diff_mod.FileReview,
};

pub const FinalizationFailure = struct {
    turn_id: u64,
    outcome: types.TurnPresentationOutcome,
};

pub const InteractiveAdmissionSnapshot = union(enum) {
    open,
    stopped,
    finalization_failed: FinalizationFailure,
};

pub const PermissionSubmissionResult = enum {
    accepted,
    stale,
    no_pending,
};

const OwnedQuestionOption = struct {
    label: []u8,
    description: ?[]u8 = null,
};

const OwnedQuestionEntry = struct {
    question: []u8,
    options: []OwnedQuestionOption,
};

pub const QuestionPromptSource = enum {
    agent_question,
    route_recovery,
    mcp_elicitation,
};

const OwnedQuestionBatch = struct {
    entries: []OwnedQuestionEntry,
    source: QuestionPromptSource = .agent_question,
};

const QuestionResponse = union(enum) {
    pending,
    cancelled,
    answered: [][]u8,
};

pub const PendingQuestionBatchSnapshot = struct {
    entries: []types.QuestionBatchEntry,
    source: QuestionPromptSource = .agent_question,

    pub fn deinit(self: PendingQuestionBatchSnapshot, alloc: std.mem.Allocator) void {
        for (self.entries) |entry| {
            alloc.free(@constCast(entry.question));
            for (entry.options) |opt| {
                alloc.free(@constCast(opt.label));
                if (opt.description) |desc| alloc.free(@constCast(desc));
            }
            alloc.free(@constCast(entry.options));
        }
        alloc.free(self.entries);
    }
};

pub const WorkerEvent = union(enum) {
    begin_prompt: types.UserTurn,
    begin_prompt_with_skill_bindings: BeginPromptWithSkillBindings,
    begin_presented_prompt: u64,
    append_user_feedback: []u8,
    assistant_presentation: assistant_presentation.Event,
    notification: notification_contract.Notification,
    question_requested,
    open_model_picker,
    semantic_notice: types.SemanticNotice,
    route_recovery_status: types.RouteRecoveryStatus,
    clear_route_recovery_status,
    api_status_text: []u8,
    command_output: CommandOutputChunk,
    command_output_complete: ?types.ToolLifecycleId,
    tool_lifecycle: types.ToolLifecycleEvent,
    turn_token_update: types.TurnTokenProgress,
    turn_phase_update: types.TurnPhaseUpdate,
    diff_block: diff_mod.DiffEntryPayload,
    finish_prompt: types.FinishedPrompt,
    session_grant: types.PermissionGrant,
    error_text: types.SemanticNotice,
};

pub const WorkerEventBatch = struct {
    events: std.ArrayList(WorkerEvent),
    cancel_requested: bool,
};

pub const WorkerRuntime = struct {
    worker_mutex: std.Io.Mutex = .init,
    worker_cond: std.Io.Condition = .init,
    /// One admission-ordered queue for ordinary prompts and steering. Steering
    /// remains in place until its target turn consumes or demotes it.
    queued_prompts: std.ArrayList(QueuedPrompt) = .empty,
    worker_events: std.ArrayList(WorkerEvent) = .empty,
    worker_processing: bool = false,
    active_turn_id: u64 = 0,
    worker_stop_requested: bool = false,
    finalization_failure: ?FinalizationFailure = null,
    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_recovery_pause_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker_connectivity_wait_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set under `worker_mutex` once the active turn publishes its terminal
    /// recovery pause. The turn may still be finalizing, but cannot perform
    /// more model work, so one continuation may queue before processing clears.
    recovery_continuation_ready: bool = false,
    queued_prompt_count: usize = 0,
    /// `null` means admission is open; otherwise queue take is paused for review.
    queue_admission: ?QueueReviewReason = null,
    /// When true, `waitAndTakeNextPrompt` will not start a turn.
    turn_start_held: bool = false,
    next_permission_request_id: u64 = 1,
    pending_permission_response: ?permission_request.OwnedPermissionResponse = null,
    pending_permission_request_shared: ?permission_request.OwnedPermissionRequest = null,
    pending_permission_review: ?*const diff_mod.FileReview = null,
    pending_permission_waiting: bool = false,
    pending_question_shared: ?OwnedQuestionBatch = null,
    pending_question_response: QuestionResponse = .pending,
    agent_turn_settings: AgentTurnSettings = .{},
    active_agent_turn_settings: ?AgentTurnSettings = null,
    active_context_snapshot: ?*const context_contract.GatheredContextSnapshot = null,
    active_prompt_snapshot_ownership: ?*ActivePromptSnapshotOwnership = null,
    preserve_prompt_snapshot_turn_id: ?u64 = null,

    pub fn deinit(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        if (self.pending_permission_response) |response| {
            self.discardPermissionResponse(response, "deinit");
        }
        self.pending_permission_response = null;
        if (self.pending_permission_request_shared) |*request| request.deinit(alloc);
        self.pending_permission_request_shared = null;
        self.pending_permission_review = null;
        freeOwnedQuestionBatchOpt(alloc, self.pending_question_shared);
        self.pending_question_shared = null;
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = .pending;

        for (self.queued_prompts.items) |prompt| discardQueuedPrompt(alloc, prompt, &.{});
        self.queued_prompts.deinit(alloc);

        for (self.worker_events.items) |event| freeWorkerEvent(alloc, event);
        self.worker_events.deinit(alloc);
    }

    pub fn requestStop(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        self.worker_stop_requested = true;
        self.worker_cond.broadcast(io_mod.getIo());
        self.worker_mutex.unlock(io_mod.getIo());
    }

    pub fn requestShutdown(self: *WorkerRuntime) void {
        self.worker_cancel_requested.store(true, .seq_cst);
        self.requestStop();
    }

    pub fn requestCancel(self: *WorkerRuntime) void {
        debug_trace.logf("worker", "cancel requested processing={s} queued={d}", .{ if (self.worker_processing) "true" else "false", self.queuedPromptCount() });
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "processing={s} queued={d} active_tool_known=false", .{ if (self.worker_processing) "true" else "false", self.queuedPromptCount() });
        self.worker_cancel_requested.store(true, .seq_cst);
    }

    /// Interrupt the current gateway wait while preserving its recovery
    /// checkpoint. The ordinary cancel flag wakes the existing socket watcher;
    /// agent policy distinguishes the typed pause flag at the boundary.
    pub fn requestRecoveryPause(self: *WorkerRuntime) void {
        debug_trace.eventf("recovery", "pause_requested", .{}, "source=interactive_try_later", .{});
        self.worker_recovery_pause_requested.store(true, .seq_cst);
        self.worker_cancel_requested.store(true, .seq_cst);
    }

    pub fn requestCancelWithQueueReview(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        const paused = self.beginQueueReviewLocked(.post_cancel);
        debug_trace.logf("worker", "cancel requested processing={s} queued={d} queue_paused={s}", .{
            if (self.worker_processing) "true" else "false",
            self.queued_prompt_count,
            if (paused) "true" else "false",
        });
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "processing={s} queued={d} queue_paused={s} active_tool_known=false", .{
            if (self.worker_processing) "true" else "false",
            self.queued_prompt_count,
            if (paused) "true" else "false",
        });
        self.worker_cancel_requested.store(true, .seq_cst);
        return paused;
    }

    pub fn cancelApprovalTurn(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        _ = self.beginQueueReviewLocked(.post_cancel);
        self.worker_cancel_requested.store(true, .seq_cst);
        _ = self.resolvePendingPermissionLocked(
            permission_request.OwnedPermissionResponse.init(
                std.heap.c_allocator,
                .deny,
                null,
            ),
        );
    }

    pub fn isCancelRequested(self: *const WorkerRuntime) bool {
        return self.worker_cancel_requested.load(.seq_cst);
    }

    pub fn isConnectivityWaitActive(self: *const WorkerRuntime) bool {
        return self.worker_connectivity_wait_active.load(.seq_cst);
    }

    pub fn pushEvent(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try dupeWorkerEvent(alloc, event);
        errdefer freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    /// Transfers an already-owned event into the queue on success.
    /// Every heap payload in `event` must have been allocated by `alloc`.
    pub fn pushOwnedEvent(self: *WorkerRuntime, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.append(alloc, event);
        self.applyRecoveryStateEvent(event);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Transfers already-owned events to the front of the queue on success.
    /// Every heap payload must have been allocated by `alloc`.
    pub fn prependOwnedEvents(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        events: []const WorkerEvent,
    ) !void {
        if (events.len == 0) return;
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        try self.worker_events.insertSlice(alloc, 0, events);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn pushTurnFinished(self: *WorkerRuntime, alloc: std.mem.Allocator, event: types.TurnFinished) !void {
        std.debug.assert(event.turn_id != 0);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.worker_events.append(alloc, .{ .tool_lifecycle = .{
            .turn_finished = event,
        } }) catch {
            self.latchFinalizationFailureLocked(.{
                .turn_id = event.turn_id,
                .outcome = event.outcome,
            });
            return error.TurnFinalizationDeliveryFailed;
        };
        self.applyRecoveryStateEvent(.{ .tool_lifecycle = .{
            .turn_finished = event,
        } });
        self.worker_cond.broadcast(io_mod.getIo());
    }

    fn applyRecoveryStateEvent(self: *WorkerRuntime, event: WorkerEvent) void {
        switch (event) {
            .route_recovery_status => |status| {
                self.worker_connectivity_wait_active.store(
                    status.action == .waiting_for_connectivity,
                    .seq_cst,
                );
                self.recovery_continuation_ready = status.action == .paused;
            },
            .clear_route_recovery_status,
            .finish_prompt,
            .error_text,
            => {
                self.worker_connectivity_wait_active.store(false, .seq_cst);
                self.recovery_continuation_ready = false;
            },
            .tool_lifecycle => |lifecycle| switch (lifecycle) {
                .turn_finished => self.worker_connectivity_wait_active.store(false, .seq_cst),
                .provisional, .authoritative_started, .progress, .terminal => return,
            },
            else => return,
        }
    }

    pub fn latchFinalizationFailure(self: *WorkerRuntime, failure: FinalizationFailure) void {
        std.debug.assert(failure.turn_id != 0);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.latchFinalizationFailureLocked(failure);
    }

    fn latchFinalizationFailureLocked(self: *WorkerRuntime, failure: FinalizationFailure) void {
        if (self.finalization_failure == null) {
            self.finalization_failure = failure;
        } else {
            debug_trace.logf(
                "worker",
                "duplicate finalization failure ignored turn_id={d} first_turn_id={d}",
                .{ failure.turn_id, self.finalization_failure.?.turn_id },
            );
        }
        self.worker_stop_requested = true;
        self.worker_cancel_requested.store(true, .seq_cst);
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn interactiveAdmissionSnapshot(self: *WorkerRuntime) InteractiveAdmissionSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.finalization_failure) |failure| {
            return .{ .finalization_failed = failure };
        }
        if (self.worker_stop_requested) return .stopped;
        return .open;
    }

    pub fn takeEventBatch(self: *WorkerRuntime) WorkerEventBatch {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const events = self.worker_events;
        self.worker_events = .empty;
        return .{
            .events = events,
            .cancel_requested = self.worker_cancel_requested.load(.seq_cst),
        };
    }

    pub fn takeEvents(self: *WorkerRuntime) std.ArrayList(WorkerEvent) {
        return self.takeEventBatch().events;
    }

    pub fn enqueuePrompt(self: *WorkerRuntime, alloc: std.mem.Allocator, prompt: QueuedPrompt) !void {
        try self.admitPrompt(alloc, prompt, false);
    }

    /// Transfers `prompt` to the active turn when steering is requested and the
    /// turn still accepts guidance. Otherwise it enters the ordinary FIFO.
    pub fn admitPrompt(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        prompt: QueuedPrompt,
        steer_if_active: bool,
    ) !void {
        var queued = prompt;
        if (queued.turn_id == 0) queued.turn_id = debug_trace.nextTurnId();

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.finalization_failure != null) return error.TurnFinalizationDeliveryFailed;
        if (self.worker_stop_requested) return error.WorkerStopped;
        if (queued.recovery_checkpoint != null and
            !recoveryContinuationAdmission(
                self.worker_processing,
                self.queued_prompt_count,
                self.recovery_continuation_ready,
            ))
        {
            return error.RecoveryBusy;
        }
        queued.agent_settings = self.agent_turn_settings;
        if (steer_if_active and
            self.worker_processing and
            self.active_turn_id != 0 and
            queued.images.len == 0 and
            queued.skill_bindings.len == 0 and
            queued.skill_display_spans.len == 0)
        {
            queued.steer_target_turn_id = self.active_turn_id;
        }
        try self.enqueuePromptLocked(alloc, queued);
    }

    fn enqueuePromptLocked(self: *WorkerRuntime, alloc: std.mem.Allocator, queued: QueuedPrompt) !void {
        try self.queued_prompts.append(alloc, queued);
        self.queued_prompt_count += 1;
        debug_trace.logf(
            "worker",
            "queued prompt bytes={d} queue_depth={d} fast_mode={s} effort={s}",
            .{ queued.prompt.len, self.queued_prompt_count, if (queued.agent_settings.fast_mode) "true" else "false", queued.agent_settings.effort.label() },
        );
        debug_trace.eventf(
            "worker",
            "prompt_enqueue",
            .{ .turn_id = queued.turn_id },
            "prompt_bytes={d} queue_depth={d} fast_mode={s} effort={s}",
            .{ queued.prompt.len, self.queued_prompt_count, if (queued.agent_settings.fast_mode) "true" else "false", queued.agent_settings.effort.label() },
        );
        self.worker_cond.broadcast(io_mod.getIo());
    }

    /// Returns allocator-owned steering text for `turn_id`, removing only those
    /// entries from the shared admission-ordered queue.
    pub fn takeSteering(self: *WorkerRuntime, alloc: std.mem.Allocator, turn_id: u64) ![][]u8 {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.worker_processing or
            self.active_turn_id != turn_id or
            self.queue_admission != null)
        {
            return &.{};
        }

        var steering_count: usize = 0;
        for (self.queued_prompts.items) |prompt| {
            if (prompt.steer_target_turn_id == turn_id) steering_count += 1;
        }
        if (steering_count == 0) return &.{};

        const messages = try alloc.alloc([]u8, steering_count);
        var copied: usize = 0;
        errdefer {
            for (messages[0..copied]) |text| alloc.free(text);
            alloc.free(messages);
        }
        const events = try alloc.alloc(WorkerEvent, steering_count);
        var event_count: usize = 0;
        errdefer {
            for (events[0..event_count]) |event| freeWorkerEvent(alloc, event);
            alloc.free(events);
        }
        for (self.queued_prompts.items) |prompt| {
            if (prompt.steer_target_turn_id != turn_id) continue;
            messages[copied] = try alloc.dupe(u8, prompt.prompt);
            copied += 1;
            events[event_count] = .{
                .append_user_feedback = try alloc.dupe(u8, prompt.prompt),
            };
            event_count += 1;
        }
        try self.worker_events.ensureUnusedCapacity(alloc, events.len);
        for (events) |event| self.worker_events.appendAssumeCapacity(event);
        alloc.free(events);

        var index: usize = 0;
        while (index < self.queued_prompts.items.len) {
            if (self.queued_prompts.items[index].steer_target_turn_id != turn_id) {
                index += 1;
                continue;
            }
            const prompt = self.queued_prompts.orderedRemove(index);
            freeQueuedPrompt(alloc, prompt);
            if (self.queued_prompt_count > 0) self.queued_prompt_count -= 1;
        }
        debug_trace.eventf("worker", "prompt_steering_consumed", .{ .turn_id = turn_id }, "count={d}", .{messages.len});
        self.worker_cond.broadcast(io_mod.getIo());
        return messages;
    }

    pub fn beginQueueReview(self: *WorkerRuntime, reason: QueueReviewReason) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.beginQueueReviewLocked(reason);
    }

    fn beginQueueReviewLocked(self: *WorkerRuntime, reason: QueueReviewReason) bool {
        if (self.queued_prompts.items.len == 0) return false;
        if (self.queue_admission) |current| {
            if (reason == .post_cancel and current != .post_cancel) {
                self.queue_admission = .post_cancel;
            }
        } else {
            self.queue_admission = reason;
            debug_trace.logf("worker", "queue review started reason={s} queued={d}", .{ @tagName(reason), self.queued_prompt_count });
            debug_trace.eventf("worker", "queue_review_started", .{}, "reason={s} queued={d}", .{ @tagName(reason), self.queued_prompt_count });
        }
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    pub fn queueReviewReason(self: *WorkerRuntime) ?QueueReviewReason {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.queue_admission;
    }

    pub fn resumeQueueReview(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const reason = self.queue_admission orelse return false;
        self.queue_admission = null;
        debug_trace.logf("worker", "queue review resumed reason={s} queued={d}", .{ @tagName(reason), self.queued_prompt_count });
        debug_trace.eventf("worker", "queue_review_resumed", .{}, "reason={s} queued={d}", .{ @tagName(reason), self.queued_prompt_count });
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    /// Hold turn admission only when no turn is active or queued.
    pub fn tryHoldTurnStart(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.worker_processing or self.queued_prompt_count > 0 or self.turn_start_held) {
            return false;
        }
        self.turn_start_held = true;
        debug_trace.logf("worker", "turn start hold acquired", .{});
        return true;
    }

    pub fn releaseTurnStartHold(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (!self.turn_start_held) return;
        self.turn_start_held = false;
        debug_trace.logf("worker", "turn start hold released", .{});
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn snapshotQueuedPromptDrafts(self: *WorkerRuntime, alloc: std.mem.Allocator) ![]QueuedPromptDraft {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        const draft_count = self.queued_prompts.items.len;
        if (draft_count == 0) return &.{};
        const drafts = try alloc.alloc(QueuedPromptDraft, draft_count);
        var filled: usize = 0;
        errdefer {
            for (drafts[0..filled]) |draft| freeQueuedPromptDraft(alloc, draft);
            alloc.free(drafts);
        }
        while (filled < draft_count) : (filled += 1) {
            const queued = self.queued_prompts.items[filled];
            const prompt = try alloc.dupe(u8, queued.prompt);
            errdefer alloc.free(prompt);
            const images = try types.dupeImageAttachmentSlice(alloc, queued.images);
            errdefer types.freeImageAttachmentSlice(alloc, images);
            const skill_display_spans = try dupeSkillDisplaySpans(alloc, queued.skill_display_spans);
            errdefer freeSkillDisplaySpans(alloc, skill_display_spans);
            const review_draft = if (queued.review_draft) |review|
                try dupeQueueReviewDraft(alloc, review)
            else
                null;
            drafts[filled] = .{
                .turn_id = queued.turn_id,
                .kind = if (queued.steer_target_turn_id != null) .steering else .queued,
                .prompt = prompt,
                .images = images,
                .skill_display_spans = skill_display_spans,
                .review_draft = review_draft,
            };
        }
        return drafts;
    }

    pub fn replaceQueuedPromptDrafts(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        drafts: []const QueuedPromptDraft,
    ) !bool {
        if (drafts.len == 0) return true;

        const prepared = try alloc.alloc(PreparedQueuedPromptDraft, drafts.len);
        var prepared_count: usize = 0;
        var partial_cleanup = true;
        errdefer if (partial_cleanup) {
            for (prepared[0..prepared_count]) |replacement| freePreparedQueuedPromptDraft(alloc, replacement);
            alloc.free(prepared);
        };
        while (prepared_count < drafts.len) : (prepared_count += 1) {
            const draft = drafts[prepared_count];
            const prompt = try alloc.dupe(u8, draft.prompt);
            errdefer alloc.free(prompt);
            const images = try types.dupeImageAttachmentSlice(alloc, draft.images);
            errdefer types.freeImageAttachmentSlice(alloc, images);
            const skill_bindings = try skillBindingsFromDisplaySpans(alloc, draft.skill_display_spans);
            errdefer freeSkillBindings(alloc, skill_bindings);
            const skill_display_spans = try dupeSkillDisplaySpans(alloc, draft.skill_display_spans);
            errdefer freeSkillDisplaySpans(alloc, skill_display_spans);
            const review_draft = if (draft.review_draft) |review|
                try dupeQueueReviewDraft(alloc, review)
            else
                null;
            prepared[prepared_count] = .{
                .turn_id = draft.turn_id,
                .kind = draft.kind,
                .prompt = prompt,
                .images = images,
                .authorized_image_catalog = &.{},
                .skill_bindings = skill_bindings,
                .skill_display_spans = skill_display_spans,
                .review_draft = review_draft,
            };
        }
        partial_cleanup = false;
        defer {
            for (prepared) |replacement| freePreparedQueuedPromptDraft(alloc, replacement);
            alloc.free(prepared);
        }

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.queue_admission == null) return false;

        for (prepared, 0..) |replacement, replacement_index| {
            for (prepared[0..replacement_index]) |prior| {
                if (prior.turn_id == replacement.turn_id) return false;
            }
            var found = false;
            for (self.queued_prompts.items) |queued| {
                if (queued.turn_id != replacement.turn_id) continue;
                found = true;
                break;
            }
            if (!found) return false;
        }

        for (prepared) |*replacement| {
            for (self.queued_prompts.items) |queued| {
                if (queued.turn_id != replacement.turn_id) continue;
                replacement.authorized_image_catalog = try session_runtime.replace_image_catalog_current_images(
                    alloc,
                    queued.authorized_image_catalog,
                    queued.images,
                    replacement.images,
                );
                break;
            }
        }

        for (prepared) |*replacement| {
            for (self.queued_prompts.items) |*queued| {
                if (queued.turn_id != replacement.turn_id) continue;
                std.mem.swap([]u8, &queued.prompt, &replacement.prompt);
                std.mem.swap([]types.ImageAttachment, &queued.images, &replacement.images);
                std.mem.swap([]types.ImageAttachment, &queued.authorized_image_catalog, &replacement.authorized_image_catalog);
                std.mem.swap([]SkillBinding, &queued.skill_bindings, &replacement.skill_bindings);
                std.mem.swap([]SkillDisplaySpan, &queued.skill_display_spans, &replacement.skill_display_spans);
                std.mem.swap(?QueueReviewDraft, &queued.review_draft, &replacement.review_draft);
                image_attachments.deleteUnreferencedImageSnapshots(
                    replacement.images,
                    queued.authorized_image_catalog,
                );
                debug_trace.logf("worker", "queued prompt draft replaced turn_id={d} bytes={d}", .{ queued.turn_id, queued.prompt.len });
                debug_trace.eventf("worker", "queue_review_committed", .{ .turn_id = queued.turn_id }, "prompt_bytes={d}", .{queued.prompt.len});
                break;
            }
        }
        debug_trace.eventf("worker", "queue_review_batch_committed", .{}, "updated={d}", .{prepared.len});
        return true;
    }

    pub fn deleteQueuedPromptDraft(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        retained_images: []const types.ImageAttachment,
    ) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        var removed: ?QueuedPrompt = null;
        var kind: PromptDraftKind = .queued;
        for (self.queued_prompts.items, 0..) |queued, index| {
            if (queued.turn_id != turn_id) continue;
            kind = if (queued.steer_target_turn_id != null) .steering else .queued;
            removed = self.queued_prompts.orderedRemove(index);
            if (self.queued_prompt_count > 0) self.queued_prompt_count -= 1;
            break;
        }
        const remaining = self.queued_prompt_count;
        self.worker_mutex.unlock(io_mod.getIo());

        const prompt = removed orelse return false;
        discardQueuedPrompt(alloc, prompt, retained_images);
        debug_trace.eventf("worker", "queue_review_deleted", .{ .turn_id = turn_id }, "kind={s} remaining={d}", .{ @tagName(kind), remaining });
        return true;
    }

    pub fn waitAndTakeNextPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        while ((self.queued_prompts.items.len == 0 or
            self.queue_admission != null or
            self.turn_start_held) and !self.worker_stop_requested)
        {
            self.worker_processing = false;
            self.active_turn_id = 0;
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }
        return self.takeNextPromptLocked(alloc);
    }

    /// Nonblocking queue take for single-threaded hosts. Returns null while the
    /// queue is empty, paused for review, held, or stopped.
    pub fn tryTakeNextPrompt(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.queued_prompts.items.len == 0 or
            self.queue_admission != null or
            self.turn_start_held or
            self.worker_stop_requested)
        {
            return null;
        }
        return self.takeNextPromptLocked(alloc);
    }

    fn takeNextPromptLocked(self: *WorkerRuntime, alloc: std.mem.Allocator) !?QueuedPrompt {
        if (self.worker_stop_requested or self.queued_prompts.items.len == 0) return null;

        const queued = self.queued_prompts.items[0];
        if (queued.recovery_checkpoint == null and queued.user_prompt_already_presented) {
            try self.worker_events.append(alloc, .{
                .begin_presented_prompt = queued.turn_id,
            });
        } else if (queued.recovery_checkpoint == null) {
            const begin_prompt = try types.dupeUserTurn(alloc, .{ .text = queued.prompt, .images = queued.images });
            errdefer types.freeUserTurn(alloc, begin_prompt);
            if (queued.skill_bindings.len > 0 or queued.skill_display_spans.len > 0) {
                const skill_bindings = try dupeSkillBindings(alloc, queued.skill_bindings);
                errdefer freeSkillBindings(alloc, skill_bindings);
                const skill_display_spans = try dupeSkillDisplaySpans(alloc, queued.skill_display_spans);
                errdefer freeSkillDisplaySpans(alloc, skill_display_spans);
                try self.worker_events.append(alloc, .{
                    .begin_prompt_with_skill_bindings = .{
                        .prompt = begin_prompt,
                        .skill_bindings = skill_bindings,
                        .skill_display_spans = skill_display_spans,
                    },
                });
            } else {
                try self.worker_events.append(alloc, .{ .begin_prompt = begin_prompt });
            }
        }

        var job = self.queued_prompts.orderedRemove(0);
        freeQueueReviewDraftOpt(alloc, job.review_draft);
        job.review_draft = null;
        if (self.queued_prompt_count > 0) self.queued_prompt_count -= 1;
        self.worker_cancel_requested.store(false, .seq_cst);
        self.worker_recovery_pause_requested.store(false, .seq_cst);
        self.worker_connectivity_wait_active.store(false, .seq_cst);
        self.recovery_continuation_ready = false;
        self.worker_processing = true;
        self.active_turn_id = job.turn_id;
        debug_trace.logf(
            "worker",
            "begin prompt bytes={d} remaining_queue={d} fast_mode={s} effort={s}",
            .{ job.prompt.len, self.queued_prompt_count, if (job.agent_settings.fast_mode) "true" else "false", job.agent_settings.effort.label() },
        );
        debug_trace.eventf(
            "worker",
            "worker_begin",
            .{ .turn_id = job.turn_id },
            "prompt_bytes={d} remaining_queue={d} cancel_reset=true fast_mode={s} effort={s}",
            .{ job.prompt.len, self.queued_prompt_count, if (job.agent_settings.fast_mode) "true" else "false", job.agent_settings.effort.label() },
        );
        return job;
    }

    pub fn finishProcessing(self: *WorkerRuntime) void {
        debug_trace.logf("worker", "finish processing queued={d}", .{self.queuedPromptCount()});
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        // Close steering admission without moving entries, preserving the exact
        // order in which steering and ordinary prompts were submitted.
        const finished_turn_id = self.active_turn_id;
        for (self.queued_prompts.items) |*prompt| {
            if (prompt.steer_target_turn_id == finished_turn_id) {
                prompt.steer_target_turn_id = null;
            }
        }
        self.worker_processing = false;
        self.active_turn_id = 0;
        self.worker_connectivity_wait_active.store(false, .seq_cst);
        self.worker_cond.broadcast(io_mod.getIo());
        self.worker_mutex.unlock(io_mod.getIo());
    }

    pub fn waitUntilIdle(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        while (self.worker_processing) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }
    }

    pub fn isProcessing(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.worker_processing;
    }

    pub fn snapshotState(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) permission_request.RequestCloneError!StateSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return .{
            .processing = self.worker_processing,
            .active_turn_id = self.active_turn_id,
            .queued_count = self.queued_prompt_count,
            .pending_event_count = self.worker_events.items.len,
            .queue_review_reason = self.queue_admission,
            .cancel_requested = self.worker_cancel_requested.load(.seq_cst),
            .pending_permission_request = if (self.permissionRequestAwaitingDecisionLocked()) blk: {
                const request = &self.pending_permission_request_shared.?;
                break :blk try permission_request.OwnedPermissionRequest.dupe(alloc, request.view());
            } else null,
            .pending_permission_review = if (self.permissionRequestAwaitingDecisionLocked())
                if (self.pending_permission_review) |review|
                    .{
                        .request_id = self.pending_permission_request_shared.?.id,
                        .review = review,
                    }
                else
                    null
            else
                null,
        };
    }

    pub fn activeTurnId(self: *WorkerRuntime) u64 {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_turn_id;
    }

    pub fn queuePreview(self: *WorkerRuntime) QueuePreview {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        const count = self.queued_prompts.items.len;
        if (count == 0) return .{};
        var steering_count: usize = 0;
        for (self.queued_prompts.items) |prompt| {
            if (prompt.steer_target_turn_id != null) steering_count += 1;
        }
        return .{
            .count = count,
            .steering_count = steering_count,
            .paused = self.queue_admission != null,
        };
    }

    pub fn queuedPromptCount(self: *WorkerRuntime) usize {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.queued_prompt_count;
    }

    pub fn clearQueuedPrompts(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        retained_images: []const types.ImageAttachment,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        self.clearQueuedPromptsLocked(alloc, retained_images);
    }

    /// Clears the queue while atomically transferring deletion responsibility
    /// for a matching active or finished turn to the supplied retained images.
    pub fn clearQueuedPromptsForSessionTransition(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        turn_id: u64,
        retained_images: []const types.ImageAttachment,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (retained_images.len > 0) {
            _ = self.preservePromptSnapshotsLocked(turn_id, retained_images);
        }
        self.clearQueuedPromptsLocked(alloc, retained_images);
    }

    fn clearQueuedPromptsLocked(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        retained_images: []const types.ImageAttachment,
    ) void {
        const dropped = self.queued_prompt_count;
        if (dropped > 0) {
            debug_trace.logf("worker", "clear queued prompts dropped={d}", .{dropped});
            debug_trace.eventf("worker", "queued_prompts_cleared", .{}, "dropped={d}", .{dropped});
        }
        for (self.queued_prompts.items) |prompt| {
            discardQueuedPrompt(alloc, prompt, retained_images);
        }
        self.queued_prompts.clearRetainingCapacity();
        self.queued_prompt_count = 0;
        self.queue_admission = null;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn discardEvents(self: *WorkerRuntime, alloc: std.mem.Allocator) void {
        var events = self.takeEvents();
        defer events.deinit(alloc);
        for (events.items) |event| freeWorkerEvent(alloc, event);
    }

    pub fn syncQueuedPromptModel(self: *WorkerRuntime, alloc: std.mem.Allocator, model: []const u8) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            const next_model = try alloc.dupe(u8, model);
            alloc.free(prompt.model);
            prompt.model = next_model;
        }
    }

    pub fn syncQueuedPromptPermissionSnapshot(self: *WorkerRuntime, snapshot: PermissionSnapshot) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            prompt.permission_mode = snapshot.mode;
        }
    }

    pub fn syncQueuedPromptFastMode(self: *WorkerRuntime, enabled: bool) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.fast_mode = enabled;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.fast_mode = enabled;
    }

    pub fn syncQueuedPromptEffort(self: *WorkerRuntime, effort: types.ReasoningEffort) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.agent_turn_settings.effort = effort;
        for (self.queued_prompts.items) |*prompt| prompt.agent_settings.effort = effort;
    }

    pub fn setActiveAgentTurnSettings(self: *WorkerRuntime, settings: AgentTurnSettings) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_agent_turn_settings = settings;
    }

    pub fn clearActiveAgentTurnSettings(self: *WorkerRuntime) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        self.active_agent_turn_settings = null;
    }

    pub fn effectiveAgentTurnSettings(self: *WorkerRuntime) AgentTurnSettings {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        return self.active_agent_turn_settings orelse self.agent_turn_settings;
    }

    pub fn syncQueuedPromptPermissionState(self: *WorkerRuntime, alloc: std.mem.Allocator, grants: []const types.PermissionGrant, snapshot: PermissionSnapshot) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| {
            const next_grants = try types.dupePermissionGrantSlice(alloc, grants);
            types.freePermissionGrantSlice(alloc, prompt.grants);
            prompt.grants = next_grants;
            prompt.permission_mode = snapshot.mode;
        }
    }

    pub fn propagateHistoryTurn(self: *WorkerRuntime, alloc: std.mem.Allocator, turn: types.HistoryTurn, max_history_turns: usize) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.queued_prompts.items.len == 0) return;
        const active_ownership = if (self.active_prompt_snapshot_ownership) |ownership|
            try ownership.ensureSharedOwnership(alloc)
        else
            null;
        const prepared = try alloc.alloc(
            PreparedHistoryPropagation,
            self.queued_prompts.items.len,
        );
        var prepared_count: usize = 0;
        var committed = false;
        defer {
            if (!committed) {
                for (prepared[0..prepared_count]) |entry| entry.deinit(alloc);
            }
            alloc.free(prepared);
        }

        while (prepared_count < self.queued_prompts.items.len) : (prepared_count += 1) {
            const prompt = self.queued_prompts.items[prepared_count];
            const next_image_catalog = try session_runtime.merge_image_catalog_history_turn(
                alloc,
                prompt.authorized_image_catalog,
                turn,
            );
            errdefer types.freeImageAttachmentSlice(alloc, next_image_catalog);
            const next_root_user_intent_context = try auto_classifier_context.refreshQueuedRootUserContext(
                alloc,
                prompt.prompt,
                prompt.root_user_intent_context,
                turn,
            );
            errdefer alloc.free(next_root_user_intent_context);
            const next_history = try appendHistoryTurnProjection(
                alloc,
                prompt.history,
                turn,
                max_history_turns,
            );
            errdefer types.freeHistoryTurnSlice(alloc, next_history);

            const next_snapshot_file_ownerships = if (active_ownership) |ownership| blk: {
                const ownership_count = std.math.add(
                    usize,
                    prompt.snapshot_file_ownerships.len,
                    1,
                ) catch return error.OutOfMemory;
                const ownerships = try alloc.alloc(
                    types.SnapshotFileOwnership,
                    ownership_count,
                );
                std.mem.copyForwards(
                    types.SnapshotFileOwnership,
                    ownerships[0..prompt.snapshot_file_ownerships.len],
                    prompt.snapshot_file_ownerships,
                );
                ownership.retain();
                ownerships[prompt.snapshot_file_ownerships.len] = ownership;
                break :blk ownerships;
            } else null;
            errdefer {
                if (next_snapshot_file_ownerships) |ownerships| {
                    ownerships[ownerships.len - 1].release();
                    alloc.free(ownerships);
                }
            }

            prepared[prepared_count] = .{
                .history = next_history,
                .root_user_intent_context = next_root_user_intent_context,
                .authorized_image_catalog = next_image_catalog,
                .snapshot_file_ownerships = next_snapshot_file_ownerships,
                .added_snapshot_ownership = if (next_snapshot_file_ownerships) |ownerships|
                    ownerships[ownerships.len - 1]
                else
                    null,
            };
        }

        for (self.queued_prompts.items, prepared) |*prompt, next| {
            types.freeHistoryTurnSlice(alloc, prompt.history);
            prompt.history = next.history;
            if (prompt.root_user_intent_context.len > 0) alloc.free(prompt.root_user_intent_context);
            prompt.root_user_intent_context = next.root_user_intent_context;
            types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
            prompt.authorized_image_catalog = next.authorized_image_catalog;
            if (next.snapshot_file_ownerships) |ownerships| {
                if (prompt.snapshot_file_ownerships.len > 0) {
                    alloc.free(prompt.snapshot_file_ownerships);
                }
                prompt.snapshot_file_ownerships = ownerships;
            }
        }
        committed = true;
    }

    pub fn beginActivePromptSnapshots(
        self: *WorkerRuntime,
        ownership: *ActivePromptSnapshotOwnership,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        std.debug.assert(self.active_prompt_snapshot_ownership == null);
        if (self.preserve_prompt_snapshot_turn_id == self.active_turn_id) {
            _ = ownership.preserve();
            self.preserve_prompt_snapshot_turn_id = null;
        }
        self.active_prompt_snapshot_ownership = ownership;
    }

    pub fn handoffActivePromptSnapshots(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
    ) !?types.SnapshotFileOwnership {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const ownership = self.active_prompt_snapshot_ownership orelse return null;
        return ownership.handoff(alloc);
    }

    pub fn endActivePromptSnapshots(
        self: *WorkerRuntime,
        ownership: *ActivePromptSnapshotOwnership,
    ) void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        std.debug.assert(self.active_prompt_snapshot_ownership == ownership);
        self.active_prompt_snapshot_ownership = null;
        ownership.deinit();
    }

    fn preservePromptSnapshotsLocked(
        self: *WorkerRuntime,
        turn_id: u64,
        images: []const types.ImageAttachment,
    ) bool {
        if (turn_id == 0 or images.len == 0) return false;

        var preserved = false;
        if (self.active_turn_id == turn_id) {
            if (self.active_prompt_snapshot_ownership) |ownership| {
                if (sameImageSnapshots(ownership.images, images)) {
                    preserved = ownership.preserve();
                }
            } else {
                // The unique active turn bridges queue take to ownership
                // registration while both operations remain mutex-serialized.
                self.preserve_prompt_snapshot_turn_id = turn_id;
                preserved = true;
            }
        }
        for (self.worker_events.items) |*event| {
            if (event.* != .finish_prompt) continue;
            const finished = &event.finish_prompt;
            const finished_images = historyTurnImages(finished.turn);
            if (!sameImageSnapshots(finished_images, images)) continue;
            if (finished.snapshot_file_ownership) |ownership| {
                ownership.transfer();
                preserved = true;
            }
        }
        return preserved;
    }

    pub fn propagateGrant(self: *WorkerRuntime, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        for (self.queued_prompts.items) |*prompt| try appendGrantToQueuedPrompt(alloc, prompt, tool_name, target_path);
    }

    pub fn requestPermissionBlocking(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        request: permission_request.PermissionRequest,
    ) permission_request.RequestCloneError!permission_request.OwnedPermissionResponse {
        return self.requestPermissionBlockingWithReview(alloc, request, null);
    }

    pub fn requestPermissionBlockingWithReview(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        request: permission_request.PermissionRequest,
        review: ?*const diff_mod.FileReview,
    ) permission_request.RequestCloneError!permission_request.OwnedPermissionResponse {
        return self.requestPermissionBlockingObserved(alloc, request, review, null) catch |err| switch (err) {
            error.PermissionRegistrationFailed,
            error.PermissionCapacityExceeded,
            => unreachable,
            else => |request_err| return request_err,
        };
    }

    pub const PermissionRequestObserver = struct {
        context: *anyopaque,
        observe_fn: *const fn (
            *anyopaque,
            *WorkerRuntime,
            permission_request.PermissionRequest,
        ) error{
            OutOfMemory,
            PermissionRegistrationFailed,
            PermissionCapacityExceeded,
        }!void,
    };

    pub fn requestPermissionBlockingObserved(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        request: permission_request.PermissionRequest,
        review: ?*const diff_mod.FileReview,
        observer: ?PermissionRequestObserver,
    ) (permission_request.RequestCloneError || error{
        PermissionRegistrationFailed,
        PermissionCapacityExceeded,
    })!permission_request.OwnedPermissionResponse {
        var shared_request: ?permission_request.OwnedPermissionRequest =
            try permission_request.OwnedPermissionRequest.dupe(
                alloc,
                request,
            );
        errdefer if (shared_request) |*owned| owned.deinit(alloc);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        shared_request.?.id = try self.allocatePermissionRequestIdLocked();
        if (self.pending_permission_request_shared) |*old| old.deinit(alloc);
        self.pending_permission_request_shared = shared_request.?;
        shared_request = null;
        self.pending_permission_review = review;
        if (self.pending_permission_response) |response| {
            self.discardPermissionResponse(response, "request_replaced");
        }
        self.pending_permission_response = null;
        self.pending_permission_waiting = true;

        if (observer) |value| {
            value.observe_fn(
                value.context,
                self,
                self.pending_permission_request_shared.?.view(),
            ) catch |err| {
                self.pending_permission_waiting = false;
                self.pending_permission_request_shared.?.deinit(alloc);
                self.pending_permission_request_shared = null;
                self.pending_permission_review = null;
                return err;
            };
        }

        while (self.pending_permission_response == null and !self.worker_stop_requested) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }

        const response = self.pending_permission_response orelse
            permission_request.OwnedPermissionResponse.init(alloc, .deny, null);
        self.pending_permission_waiting = false;
        self.pending_permission_response = null;
        if (self.pending_permission_request_shared) |*old| {
            old.deinit(alloc);
            self.pending_permission_request_shared = null;
        }
        self.pending_permission_review = null;
        return response;
    }

    pub fn submitPermissionResponse(
        self: *WorkerRuntime,
        expected_request_id: u64,
        response: permission_request.OwnedPermissionResponse,
    ) PermissionSubmissionResult {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.permissionSubmissionBlockedLocked(expected_request_id)) |blocked| {
            self.discardPermissionResponse(response, @tagName(blocked));
            return blocked;
        }
        std.debug.assert(self.resolvePendingPermissionLocked(response));
        return .accepted;
    }

    pub const PermissionCommitError = error{
        OutOfMemory,
        PermissionCommitFailed,
        PermissionCapacityExceeded,
    };

    pub const PermissionCommit = struct {
        context: *anyopaque,
        commit_fn: *const fn (*anyopaque) PermissionCommitError!void,
    };

    /// Keeps canonical pending-request identity stable across a durable host
    /// commit. The response becomes visible and the waiter wakes only after the
    /// callback succeeds. On callback failure the owned response is discarded.
    pub fn submitPermissionResponseAfterCommit(
        self: *WorkerRuntime,
        expected_request_id: u64,
        response: permission_request.OwnedPermissionResponse,
        commit: ?PermissionCommit,
    ) PermissionCommitError!PermissionSubmissionResult {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        if (self.permissionSubmissionBlockedLocked(expected_request_id)) |blocked| {
            self.discardPermissionResponse(response, @tagName(blocked));
            return blocked;
        }
        if (commit) |effect| effect.commit_fn(effect.context) catch |err| {
            self.discardPermissionResponse(response, "commit_failed");
            return err;
        };
        std.debug.assert(self.resolvePendingPermissionLocked(response));
        return .accepted;
    }

    fn permissionSubmissionBlockedLocked(
        self: *const WorkerRuntime,
        expected_request_id: u64,
    ) ?PermissionSubmissionResult {
        if (!self.permissionRequestAwaitedLocked() or
            self.pending_permission_response != null)
        {
            return .no_pending;
        }
        if (self.pending_permission_request_shared.?.id != expected_request_id) {
            return .stale;
        }
        return null;
    }

    fn allocatePermissionRequestIdLocked(
        self: *WorkerRuntime,
    ) error{RequestIdExhausted}!u64 {
        const request_id = self.next_permission_request_id;
        if (request_id == 0) return error.RequestIdExhausted;
        self.next_permission_request_id = std.math.add(
            u64,
            request_id,
            1,
        ) catch 0;
        return request_id;
    }

    fn permissionRequestAwaitedLocked(self: *const WorkerRuntime) bool {
        return self.worker_processing and
            !self.worker_stop_requested and
            self.pending_permission_waiting and
            self.pending_permission_request_shared != null;
    }

    fn permissionRequestAwaitingDecisionLocked(
        self: *const WorkerRuntime,
    ) bool {
        return self.permissionRequestAwaitedLocked() and
            self.pending_permission_response == null;
    }

    fn resolvePendingPermissionLocked(
        self: *WorkerRuntime,
        response: permission_request.OwnedPermissionResponse,
    ) bool {
        if (!self.permissionRequestAwaitingDecisionLocked()) {
            self.discardPermissionResponse(response, "unawaited");
            return false;
        }
        self.pending_permission_response = response;
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    fn discardPermissionResponse(
        _: *WorkerRuntime,
        response: permission_request.OwnedPermissionResponse,
        reason: []const u8,
    ) void {
        var owned = response;
        if (owned.feedback) |feedback| {
            debug_trace.logf(
                "permission",
                "approval feedback discarded reason={s} bytes={d}",
                .{ reason, feedback.len },
            );
        }
        owned.deinit();
    }

    pub fn requestQuestionBatchAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .agent_question);
    }

    pub fn requestRouteRecoveryAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .route_recovery);
    }

    pub fn requestMcpElicitationAnswerBlocking(self: *WorkerRuntime, alloc: std.mem.Allocator, entries: []const types.QuestionBatchEntry) !?[][]u8 {
        return self.requestQuestionBatchAnswerBlockingWithSource(alloc, entries, .mcp_elicitation);
    }

    fn requestQuestionBatchAnswerBlockingWithSource(
        self: *WorkerRuntime,
        alloc: std.mem.Allocator,
        entries: []const types.QuestionBatchEntry,
        source: QuestionPromptSource,
    ) !?[][]u8 {
        const owned = try dupeOwnedQuestionBatch(alloc, entries, source);
        var owns_pending_question = true;
        errdefer if (owns_pending_question) freeOwnedQuestionBatch(alloc, owned);

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());

        std.debug.assert(self.pending_question_shared == null);
        self.pending_question_shared = owned;
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = .pending;
        self.worker_events.append(alloc, .question_requested) catch |err| {
            self.pending_question_shared = null;
            self.pending_question_response = .pending;
            return err;
        };
        owns_pending_question = false;
        self.worker_cond.broadcast(io_mod.getIo());

        while (self.pending_question_response == .pending and !self.worker_stop_requested) {
            self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
        }

        if (self.pending_question_shared) |pending| {
            freeOwnedQuestionBatch(alloc, pending);
            self.pending_question_shared = null;
        }

        const response = self.pending_question_response;
        self.pending_question_response = .pending;
        return switch (response) {
            .answered => |labels| labels,
            .cancelled, .pending => null,
        };
    }

    pub fn submitQuestionBatchAnswer(self: *WorkerRuntime, alloc: std.mem.Allocator, answers: ?[]const []const u8) !void {
        var new_response: QuestionResponse = .cancelled;
        if (answers) |labels| {
            const dup = try alloc.alloc([]u8, labels.len);
            errdefer alloc.free(dup);
            var filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < filled) : (i += 1) alloc.free(dup[i]);
            }
            while (filled < labels.len) : (filled += 1) dup[filled] = try alloc.dupe(u8, labels[filled]);
            new_response = .{ .answered = dup };
        }

        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.pending_question_shared == null or self.pending_question_response != .pending) {
            freeQuestionResponse(alloc, new_response);
            debug_trace.logf("worker", "ignored late question response pending=false", .{});
            return;
        }
        freeQuestionResponse(alloc, self.pending_question_response);
        self.pending_question_response = new_response;
        self.worker_cond.broadcast(io_mod.getIo());
    }

    pub fn cancelPendingQuestionBatch(self: *WorkerRuntime) bool {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        if (self.pending_question_shared == null or self.pending_question_response != .pending) return false;
        self.pending_question_response = .cancelled;
        self.worker_cond.broadcast(io_mod.getIo());
        return true;
    }

    pub fn snapshotPendingQuestionBatch(self: *WorkerRuntime, alloc: std.mem.Allocator) !?PendingQuestionBatchSnapshot {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const pending = self.pending_question_shared orelse return null;
        return try dupePendingBatchSnapshot(alloc, pending);
    }

    pub fn pendingQuestionBatchSource(self: *WorkerRuntime) QuestionPromptSource {
        self.worker_mutex.lockUncancelable(io_mod.getIo());
        defer self.worker_mutex.unlock(io_mod.getIo());
        const pending = self.pending_question_shared orelse return .agent_question;
        return pending.source;
    }
};

fn recoveryContinuationAdmission(
    processing: bool,
    queued_count: usize,
    terminal_pause_ready: bool,
) bool {
    return queued_count == 0 and (!processing or terminal_pause_ready);
}

fn dupeOwnedQuestionEntry(alloc: std.mem.Allocator, entry: types.QuestionBatchEntry) !OwnedQuestionEntry {
    const question_dup = try alloc.dupe(u8, entry.question);
    errdefer alloc.free(question_dup);
    const options_dup = try alloc.alloc(OwnedQuestionOption, entry.options.len);
    errdefer alloc.free(options_dup);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(options_dup[i].label);
            if (options_dup[i].description) |d| alloc.free(d);
        }
    }
    while (filled < entry.options.len) : (filled += 1) {
        const src = entry.options[filled];
        const label_dup = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label_dup);
        const desc_dup: ?[]u8 = if (src.description) |d| try alloc.dupe(u8, d) else null;
        options_dup[filled] = .{ .label = label_dup, .description = desc_dup };
    }
    return .{ .question = question_dup, .options = options_dup };
}

fn freeOwnedQuestionEntry(alloc: std.mem.Allocator, entry: OwnedQuestionEntry) void {
    alloc.free(entry.question);
    for (entry.options) |opt| {
        alloc.free(opt.label);
        if (opt.description) |d| alloc.free(d);
    }
    alloc.free(entry.options);
}

fn dupeOwnedQuestionBatch(
    alloc: std.mem.Allocator,
    entries: []const types.QuestionBatchEntry,
    source: QuestionPromptSource,
) !OwnedQuestionBatch {
    const owned_entries = try alloc.alloc(OwnedQuestionEntry, entries.len);
    errdefer alloc.free(owned_entries);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) freeOwnedQuestionEntry(alloc, owned_entries[i]);
    }
    while (filled < entries.len) : (filled += 1) owned_entries[filled] = try dupeOwnedQuestionEntry(alloc, entries[filled]);
    return .{ .entries = owned_entries, .source = source };
}

fn freeOwnedQuestionBatch(alloc: std.mem.Allocator, owned: OwnedQuestionBatch) void {
    for (owned.entries) |entry| freeOwnedQuestionEntry(alloc, entry);
    alloc.free(owned.entries);
}

fn freeOwnedQuestionBatchOpt(alloc: std.mem.Allocator, owned: ?OwnedQuestionBatch) void {
    if (owned) |o| freeOwnedQuestionBatch(alloc, o);
}

fn freeQuestionResponse(alloc: std.mem.Allocator, response: QuestionResponse) void {
    switch (response) {
        .answered => |labels| {
            for (labels) |label| alloc.free(label);
            alloc.free(labels);
        },
        .cancelled, .pending => {},
    }
}

fn dupePendingEntrySnapshot(alloc: std.mem.Allocator, pending: OwnedQuestionEntry) !types.QuestionBatchEntry {
    const question_dup = try alloc.dupe(u8, pending.question);
    errdefer alloc.free(question_dup);
    const options_dup = try alloc.alloc(types.QuestionOption, pending.options.len);
    errdefer alloc.free(options_dup);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(options_dup[i].label));
            if (options_dup[i].description) |d| alloc.free(@constCast(d));
        }
    }
    while (filled < pending.options.len) : (filled += 1) {
        const src = pending.options[filled];
        const label_dup = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label_dup);
        const desc_dup: ?[]const u8 = if (src.description) |d| try alloc.dupe(u8, d) else null;
        options_dup[filled] = .{ .label = label_dup, .description = desc_dup };
    }
    return .{ .question = question_dup, .options = options_dup };
}

fn dupePendingBatchSnapshot(alloc: std.mem.Allocator, pending: OwnedQuestionBatch) !PendingQuestionBatchSnapshot {
    const entries_dup = try alloc.alloc(types.QuestionBatchEntry, pending.entries.len);
    errdefer alloc.free(entries_dup);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(@constCast(entries_dup[i].question));
            for (entries_dup[i].options) |opt| {
                alloc.free(@constCast(opt.label));
                if (opt.description) |d| alloc.free(@constCast(d));
            }
            alloc.free(@constCast(entries_dup[i].options));
        }
    }
    while (filled < pending.entries.len) : (filled += 1) entries_dup[filled] = try dupePendingEntrySnapshot(alloc, pending.entries[filled]);
    return .{ .entries = entries_dup, .source = pending.source };
}

fn appendGrantToQueuedPrompt(alloc: std.mem.Allocator, prompt: *QueuedPrompt, tool_name: []const u8, target_path: []const u8) !void {
    for (prompt.grants) |grant| {
        if (std.mem.eql(u8, grant.tool_name, tool_name) and std.mem.eql(u8, grant.target_path, target_path)) return;
    }
    const tool_name_dup = try alloc.dupe(u8, tool_name);
    errdefer alloc.free(tool_name_dup);
    const target_path_dup = try alloc.dupe(u8, target_path);
    errdefer alloc.free(target_path_dup);
    const current = prompt.grants;
    const next = try alloc.alloc(types.PermissionGrant, current.len + 1);
    errdefer alloc.free(next);
    if (current.len > 0) std.mem.copyForwards(types.PermissionGrant, next[0..current.len], current);
    next[current.len] = .{ .tool_name = tool_name_dup, .target_path = target_path_dup };
    alloc.free(current);
    prompt.grants = next;
}

fn dupeStringSlice(alloc: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    if (values.len == 0) return &.{};
    const copy = try alloc.alloc([]u8, values.len);
    errdefer alloc.free(copy);

    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) alloc.free(copy[i]);
    }
    while (filled < values.len) : (filled += 1) {
        copy[filled] = try alloc.dupe(u8, values[filled]);
    }
    return copy;
}

fn freeStringSlice(alloc: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

fn appendHistoryTurnProjection(
    alloc: std.mem.Allocator,
    current: []const types.HistoryTurn,
    turn: types.HistoryTurn,
    max_history_turns: usize,
) ![]types.HistoryTurn {
    const combined_len = std.math.add(usize, current.len, 1) catch
        return error.OutOfMemory;
    const combined = try alloc.alloc(types.HistoryTurn, combined_len);
    defer alloc.free(combined);
    std.mem.copyForwards(types.HistoryTurn, combined[0..current.len], current);
    combined[current.len] = turn;
    return session_runtime.snapshotOwnedContextHistory(
        alloc,
        combined,
        0,
        max_history_turns,
    );
}

pub fn freeQueuedPrompt(alloc: std.mem.Allocator, prompt: QueuedPrompt) void {
    alloc.free(prompt.prompt);
    types.freeImageAttachmentSlice(alloc, prompt.images);
    types.freeImageAttachmentSlice(alloc, prompt.authorized_image_catalog);
    alloc.free(prompt.model);
    secret.zeroAndFree(alloc, prompt.api_key);
    if (prompt.gateway_team) |team| alloc.free(team);
    if (prompt.account_id) |account_id| alloc.free(account_id);
    types.freeHistoryTurnSlice(alloc, prompt.history);
    if (prompt.root_user_intent_context.len > 0) alloc.free(prompt.root_user_intent_context);
    types.freePermissionGrantSlice(alloc, prompt.grants);
    freeSkillBindings(alloc, prompt.skill_bindings);
    freeSkillDisplaySpans(alloc, prompt.skill_display_spans);
    freeQueueReviewDraftOpt(alloc, prompt.review_draft);
    var context_snapshot = prompt.context_snapshot;
    context_snapshot.deinit(alloc);
    for (prompt.snapshot_file_ownerships) |ownership| ownership.release();
    if (prompt.snapshot_file_ownerships.len > 0) {
        alloc.free(prompt.snapshot_file_ownerships);
    }
    if (prompt.recovery_checkpoint) |checkpoint| {
        var owned = checkpoint;
        owned.deinit(alloc);
    }
}

fn discardQueuedPrompt(
    alloc: std.mem.Allocator,
    prompt: QueuedPrompt,
    retained_images: []const types.ImageAttachment,
) void {
    image_attachments.deleteUnreferencedImageSnapshots(prompt.images, retained_images);
    freeQueuedPrompt(alloc, prompt);
}

fn checkHistoryPropagationAllocation(
    alloc: std.mem.Allocator,
    snapshot_path: []const u8,
    fail_index: usize,
) !bool {
    {
        var file = try std.Io.Dir.createFileAbsolute(
            std.testing.io,
            snapshot_path,
            .{ .truncate = true },
        );
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    var images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast(snapshot_path),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    const turn: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("active"), .images = &images },
        .assistant = @constCast("done"),
    } };

    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);
    const first = try makePrompt(alloc, "first queued", "model");
    var owns_first = true;
    errdefer if (owns_first) freeQueuedPrompt(alloc, first);
    try runtime.enqueuePrompt(alloc, first);
    owns_first = false;
    const second = try makePrompt(alloc, "second queued", "model");
    var owns_second = true;
    errdefer if (owns_second) freeQueuedPrompt(alloc, second);
    try runtime.enqueuePrompt(alloc, second);
    owns_second = false;

    var active = ActivePromptSnapshotOwnership.init(&images);
    runtime.beginActivePromptSnapshots(&active);
    defer runtime.endActivePromptSnapshots(&active);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = fail_index },
    );
    runtime.propagateHistoryTurn(failing.allocator(), turn, 8) catch |err| {
        if (!failing.has_induced_failure) return err;
        for (runtime.queued_prompts.items) |prompt| {
            try std.testing.expectEqual(@as(usize, 0), prompt.history.len);
            try std.testing.expectEqual(@as(usize, 0), prompt.authorized_image_catalog.len);
            try std.testing.expectEqual(@as(usize, 0), prompt.snapshot_file_ownerships.len);
        }
        return false;
    };

    for (runtime.queued_prompts.items) |prompt| {
        try std.testing.expectEqual(@as(usize, 1), prompt.history.len);
        try std.testing.expectEqual(@as(usize, 1), prompt.authorized_image_catalog.len);
        try std.testing.expectEqual(@as(usize, 1), prompt.snapshot_file_ownerships.len);
    }
    return true;
}

fn checkFinishOwnershipHandoffAllocation(
    alloc: std.mem.Allocator,
    snapshot_path: []const u8,
) !void {
    {
        var file = try std.Io.Dir.createFileAbsolute(
            std.testing.io,
            snapshot_path,
            .{ .truncate = true },
        );
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "snapshot");
    }
    const images = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast(snapshot_path),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    }};
    var active = ActivePromptSnapshotOwnership.init(&images);
    const ownership = active.handoff(alloc) catch |err| {
        active.deinit();
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.accessAbsolute(std.testing.io, snapshot_path, .{}),
        );
        return err;
    };
    active.deinit();
    ownership.?.release();
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, snapshot_path, .{}),
    );
}

pub fn dupeSkillBindings(alloc: std.mem.Allocator, bindings: []const SkillBinding) ![]SkillBinding {
    if (bindings.len == 0) return &.{};
    const copy = try alloc.alloc(SkillBinding, bindings.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(copy[i].name);
            alloc.free(copy[i].path);
        }
        alloc.free(copy);
    }
    while (filled < bindings.len) : (filled += 1) {
        copy[filled] = .{
            .name = try alloc.dupe(u8, bindings[filled].name),
            .path = try alloc.dupe(u8, bindings[filled].path),
        };
    }
    return copy;
}

pub fn freeSkillBindings(alloc: std.mem.Allocator, bindings: []SkillBinding) void {
    for (bindings) |binding| {
        alloc.free(binding.name);
        alloc.free(binding.path);
    }
    if (bindings.len > 0) alloc.free(bindings);
}

pub fn dupeSkillDisplaySpans(alloc: std.mem.Allocator, spans: []const SkillDisplaySpan) ![]SkillDisplaySpan {
    if (spans.len == 0) return &.{};
    const copy = try alloc.alloc(SkillDisplaySpan, spans.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            alloc.free(copy[i].name);
            alloc.free(copy[i].path);
        }
        alloc.free(copy);
    }
    while (filled < spans.len) : (filled += 1) {
        copy[filled] = .{
            .raw_start = spans[filled].raw_start,
            .raw_end = spans[filled].raw_end,
            .name = try alloc.dupe(u8, spans[filled].name),
            .path = try alloc.dupe(u8, spans[filled].path),
            .display_source = spans[filled].display_source,
            .owns_trailing_separator = spans[filled].owns_trailing_separator,
        };
    }
    return copy;
}

pub fn freeSkillDisplaySpans(alloc: std.mem.Allocator, spans: []SkillDisplaySpan) void {
    for (spans) |span| {
        alloc.free(span.name);
        alloc.free(span.path);
    }
    if (spans.len > 0) alloc.free(spans);
}

pub fn dupeWorkerEvent(alloc: std.mem.Allocator, event: WorkerEvent) !WorkerEvent {
    return switch (event) {
        .begin_prompt => |prompt| .{ .begin_prompt = try types.dupeUserTurn(alloc, prompt) },
        .begin_prompt_with_skill_bindings => |begin| blk: {
            const prompt = try types.dupeUserTurn(alloc, begin.prompt);
            errdefer types.freeUserTurn(alloc, prompt);
            const skill_bindings = try dupeSkillBindings(alloc, begin.skill_bindings);
            errdefer freeSkillBindings(alloc, skill_bindings);
            const skill_display_spans = try dupeSkillDisplaySpans(alloc, begin.skill_display_spans);
            break :blk .{ .begin_prompt_with_skill_bindings = .{
                .prompt = prompt,
                .skill_bindings = skill_bindings,
                .skill_display_spans = skill_display_spans,
            } };
        },
        .begin_presented_prompt => |turn_id| .{ .begin_presented_prompt = turn_id },
        .append_user_feedback => |text| .{ .append_user_feedback = try alloc.dupe(u8, text) },
        .assistant_presentation => |presentation| .{
            .assistant_presentation = try presentation.clone(alloc),
        },
        .notification => |notification| .{ .notification = notification },
        .question_requested => .question_requested,
        .open_model_picker => .open_model_picker,
        .semantic_notice => |notice| .{ .semantic_notice = try types.dupeSemanticNotice(alloc, notice) },
        .route_recovery_status => |status| .{ .route_recovery_status = status },
        .clear_route_recovery_status => .clear_route_recovery_status,
        .api_status_text => |text| .{ .api_status_text = try alloc.dupe(u8, text) },
        .command_output => |chunk| .{ .command_output = .{
            .lifecycle_id = if (chunk.lifecycle_id) |id| .{
                .turn_id = id.turn_id,
                .call_id = try alloc.dupe(u8, id.call_id),
            } else null,
            .stream = chunk.stream,
            .text = try alloc.dupe(u8, chunk.text),
        } },
        .command_output_complete => |lifecycle_id| .{ .command_output_complete = if (lifecycle_id) |id| .{
            .turn_id = id.turn_id,
            .call_id = try alloc.dupe(u8, id.call_id),
        } else null },
        .tool_lifecycle => |lifecycle| .{
            .tool_lifecycle = try dupeToolLifecycleEvent(alloc, lifecycle),
        },
        .turn_token_update => |update| .{ .turn_token_update = update },
        .turn_phase_update => |update| .{ .turn_phase_update = update },
        .diff_block => |payload| blk: {
            const preview = try alloc.dupe(u8, payload.preview);
            errdefer alloc.free(preview);
            const full = if (payload.full) |source| full_value: {
                const content = try alloc.dupe(u8, source.content);
                errdefer alloc.free(content);
                const call_id = try alloc.dupe(u8, source.lifecycle_id.call_id);
                break :full_value diff_mod.FullDiff{
                    .content = content,
                    .lifecycle_id = .{
                        .turn_id = source.lifecycle_id.turn_id,
                        .call_id = call_id,
                    },
                };
            } else null;
            errdefer if (full) |owned| owned.deinit(alloc);
            break :blk .{ .diff_block = .{
                .preview = preview,
                .additions = payload.additions,
                .deletions = payload.deletions,
                .full = full,
            } };
        },
        .finish_prompt => |finished| .{ .finish_prompt = try types.dupeFinishedPrompt(alloc, finished) },
        .session_grant => |grant| blk: {
            const tool_name = try alloc.dupe(u8, grant.tool_name);
            errdefer alloc.free(tool_name);
            const target_path = try alloc.dupe(u8, grant.target_path);
            break :blk .{ .session_grant = .{
                .tool_name = tool_name,
                .target_path = target_path,
            } };
        },
        .error_text => |notice| .{ .error_text = try types.dupeSemanticNotice(alloc, notice) },
    };
}

pub fn freeWorkerEvent(alloc: std.mem.Allocator, event: WorkerEvent) void {
    switch (event) {
        .begin_prompt => |prompt| types.freeUserTurn(alloc, prompt),
        .begin_prompt_with_skill_bindings => |begin| {
            types.freeUserTurn(alloc, begin.prompt);
            freeSkillBindings(alloc, begin.skill_bindings);
            freeSkillDisplaySpans(alloc, begin.skill_display_spans);
        },
        .begin_presented_prompt => {},
        .append_user_feedback => |text| alloc.free(text),
        .assistant_presentation => |presentation| {
            var owned = presentation;
            owned.deinit(alloc);
        },
        .notification => {},
        .open_model_picker => {},
        .semantic_notice => |notice| types.freeSemanticNotice(alloc, notice),
        .route_recovery_status => {},
        .clear_route_recovery_status => {},
        .api_status_text => |text| alloc.free(text),
        .command_output => |chunk| {
            if (chunk.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
            alloc.free(chunk.text);
        },
        .command_output_complete => |lifecycle_id| {
            if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
        },
        .tool_lifecycle => |lifecycle| freeToolLifecycleEvent(alloc, lifecycle),
        .diff_block => |payload| diff_mod.freeDiffEntryPayload(alloc, payload),
        .finish_prompt => |finished| types.freeFinishedPrompt(alloc, finished),
        .session_grant => |grant| {
            alloc.free(grant.tool_name);
            alloc.free(grant.target_path);
        },
        .error_text => |notice| types.freeSemanticNotice(alloc, notice),
        else => {},
    }
}

pub fn dupeToolLifecycleEvent(
    alloc: std.mem.Allocator,
    event: types.ToolLifecycleEvent,
) !types.ToolLifecycleEvent {
    return switch (event) {
        .provisional => |started| blk: {
            const call_id = try alloc.dupe(u8, started.id.call_id);
            errdefer alloc.free(call_id);
            const tool_name = if (started.tool_name) |name| try alloc.dupe(u8, name) else null;
            break :blk .{ .provisional = .{
                .id = .{ .turn_id = started.id.turn_id, .call_id = call_id },
                .presentation_group_id = started.presentation_group_id,
                .tool_name = tool_name,
                .activity_kind = started.activity_kind,
            } };
        },
        .authoritative_started => |started| blk: {
            const call_id = try alloc.dupe(u8, started.id.call_id);
            errdefer alloc.free(call_id);
            const alias = if (started.reconciles_provisional_call_id) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (alias) |value| alloc.free(value);
            const tool_name = try alloc.dupe(u8, started.tool_name);
            errdefer alloc.free(tool_name);
            const arguments_json = if (started.arguments_json) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (arguments_json) |value| alloc.free(value);
            break :blk .{ .authoritative_started = .{
                .id = .{ .turn_id = started.id.turn_id, .call_id = call_id },
                .presentation_group_id = started.presentation_group_id,
                .reconciles_provisional_call_id = alias,
                .tool_name = tool_name,
                .activity_kind = started.activity_kind,
                .arguments_json = arguments_json,
                .place_after_current_transcript = started.place_after_current_transcript,
            } };
        },
        .progress => |progress| blk: {
            const call_id = try alloc.dupe(u8, progress.id.call_id);
            errdefer alloc.free(call_id);
            const text = try alloc.dupe(u8, progress.text);
            break :blk .{ .progress = .{
                .id = .{ .turn_id = progress.id.turn_id, .call_id = call_id },
                .text = text,
            } };
        },
        .terminal => |terminal| blk: {
            const call_id = try alloc.dupe(u8, terminal.id.call_id);
            errdefer alloc.free(call_id);
            const summary = try alloc.dupe(u8, terminal.outcome.summary);
            errdefer alloc.free(summary);
            const result = if (terminal.result) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (result) |value| alloc.free(value);
            const result_memory = try dupeToolResultMemory(alloc, terminal.result_memory);
            errdefer freeToolResultMemory(alloc, result_memory);
            const command_artifact_handle = if (terminal.command_artifact_handle) |handle|
                try alloc.dupe(u8, handle)
            else
                null;
            errdefer if (command_artifact_handle) |handle| alloc.free(handle);
            break :blk .{ .terminal = .{
                .id = .{ .turn_id = terminal.id.turn_id, .call_id = call_id },
                .outcome = .{
                    .kind = terminal.outcome.kind,
                    .summary = summary,
                },
                .result = result,
                .result_memory = result_memory,
                .command_artifact_handle = command_artifact_handle,
            } };
        },
        .turn_finished => |finished| .{ .turn_finished = finished },
    };
}

pub fn freeToolLifecycleEvent(
    alloc: std.mem.Allocator,
    event: types.ToolLifecycleEvent,
) void {
    switch (event) {
        .provisional => |started| {
            alloc.free(@constCast(started.id.call_id));
            if (started.tool_name) |name| alloc.free(@constCast(name));
        },
        .authoritative_started => |started| {
            alloc.free(@constCast(started.id.call_id));
            if (started.reconciles_provisional_call_id) |alias| {
                alloc.free(@constCast(alias));
            }
            alloc.free(@constCast(started.tool_name));
            if (started.arguments_json) |arguments_json| {
                alloc.free(@constCast(arguments_json));
            }
        },
        .progress => |progress| {
            alloc.free(@constCast(progress.id.call_id));
            alloc.free(@constCast(progress.text));
        },
        .terminal => |terminal| {
            alloc.free(@constCast(terminal.id.call_id));
            alloc.free(@constCast(terminal.outcome.summary));
            if (terminal.result) |result| alloc.free(@constCast(result));
            freeToolResultMemory(alloc, terminal.result_memory);
            if (terminal.command_artifact_handle) |handle| alloc.free(@constCast(handle));
        },
        .turn_finished => {},
    }
}

fn dupeToolResultMemory(
    alloc: std.mem.Allocator,
    source: ?types.ToolResultMemory,
) !?types.ToolResultMemory {
    const memory = source orelse return null;
    const output_handle = if (memory.output_handle) |handle|
        try alloc.dupe(u8, handle)
    else
        null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (memory.preview) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (preview) |value| alloc.free(value);
    const command_output_replay = if (memory.command_output_replay) |replay|
        try types.dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);
    return .{
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = memory.output_bytes,
        .stored_output_bytes = memory.stored_output_bytes,
        .truncated = memory.truncated,
        .model_view_covers_full_file = memory.model_view_covers_full_file,
        .command_output_replay = command_output_replay,
        .command_process_presentation = memory.command_process_presentation,
        .terminal_action_presentation = memory.terminal_action_presentation,
    };
}

fn freeToolResultMemory(
    alloc: std.mem.Allocator,
    memory: ?types.ToolResultMemory,
) void {
    const value = memory orelse return;
    if (value.output_handle) |handle| alloc.free(@constCast(handle));
    if (value.preview) |preview| alloc.free(@constCast(preview));
    if (value.command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    }
}

fn makePrompt(alloc: std.mem.Allocator, text: []const u8, model: []const u8) !QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, model),
        .api_key = try alloc.dupe(u8, "key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    };
}

fn makeGrant(alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !types.PermissionGrant {
    return .{ .tool_name = try alloc.dupe(u8, tool_name), .target_path = try alloc.dupe(u8, target_path) };
}

fn makePromptWithGrant(alloc: std.mem.Allocator, text: []const u8, model: []const u8, tool_name: []const u8, target_path: []const u8) !QueuedPrompt {
    var prompt = try makePrompt(alloc, text, model);
    errdefer freeQueuedPrompt(alloc, prompt);
    const grants = try alloc.alloc(types.PermissionGrant, 1);
    grants[0] = try makeGrant(alloc, tool_name, target_path);
    alloc.free(prompt.grants);
    prompt.grants = grants;
    return prompt;
}

fn freeEventList(alloc: std.mem.Allocator, events: *std.ArrayList(WorkerEvent)) void {
    for (events.items) |event| freeWorkerEvent(alloc, event);
    events.deinit(alloc);
}

fn checkStateSnapshotFailurePreservesPendingEvents(alloc: std.mem.Allocator) !void {
    const owner_alloc = std.testing.allocator;
    var runtime = WorkerRuntime{};
    defer runtime.deinit(owner_alloc);

    try runtime.pushEvent(owner_alloc, .{ .command_output_complete = null });
    runtime.worker_processing = true;
    runtime.pending_permission_waiting = true;
    runtime.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            owner_alloc,
            .{ .id = 17, .label = "pending command completion" },
        );

    var snapshot = runtime.snapshotState(alloc) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), runtime.worker_events.items.len);
        try std.testing.expect(runtime.worker_events.items[0] == .command_output_complete);
        try std.testing.expectEqualStrings(
            "pending command completion",
            runtime.pending_permission_request_shared.?.label,
        );
        return err;
    };
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.pending_event_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.worker_events.items.len);
    try std.testing.expect(runtime.worker_events.items[0] == .command_output_complete);
}

const QueueTakeThreadState = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
    job: ?QueuedPrompt = null,
};

fn runQueueTake(state: *QueueTakeThreadState, runtime: *WorkerRuntime) void {
    state.started.store(true, .seq_cst);
    state.job = runtime.waitAndTakeNextPrompt(std.testing.allocator) catch |err| {
        state.err = err;
        state.finished.store(true, .seq_cst);
        return;
    };
    state.finished.store(true, .seq_cst);
}

const EnqueueThreadState = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
};

fn runEnqueuePrompt(state: *EnqueueThreadState, runtime: *WorkerRuntime, text: []const u8, model: []const u8) void {
    const prompt = makePrompt(std.testing.allocator, text, model) catch |err| {
        state.err = err;
        return;
    };
    state.started.store(true, .seq_cst);
    runtime.enqueuePrompt(std.testing.allocator, prompt) catch |err| {
        freeQueuedPrompt(std.testing.allocator, prompt);
        state.err = err;
        return;
    };
}

fn waitForEnqueueThreadStart(state: *EnqueueThreadState) !void {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (state.started.load(.seq_cst)) return;
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn checkToolLifecycleDupAllocationFailure(alloc: std.mem.Allocator) !void {
    const owned = try dupeToolLifecycleEvent(alloc, .{ .authoritative_started = .{
        .id = .{ .turn_id = 7, .call_id = "final" },
        .reconciles_provisional_call_id = "provisional",
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    defer freeToolLifecycleEvent(alloc, owned);

    try std.testing.expectEqualStrings(
        "final",
        owned.authoritative_started.id.call_id,
    );
    try std.testing.expectEqualStrings(
        "provisional",
        owned.authoritative_started.reconciles_provisional_call_id.?,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        owned.authoritative_started.tool_name,
    );
}

fn checkSemanticWorkerEventDuplicationAllocationFailure(alloc: std.mem.Allocator) !void {
    const ordinary = try dupeWorkerEvent(alloc, .{ .semantic_notice = .{
        .topic = "context",
        .tone = .warning,
        .body = "source limit reached",
        .visibility = .full_only,
    } });
    defer freeWorkerEvent(alloc, ordinary);

    const error_event = try dupeWorkerEvent(alloc, .{ .error_text = .{
        .topic = "github",
        .tone = .@"error",
        .body = "publish failed",
    } });
    defer freeWorkerEvent(alloc, error_event);

    try std.testing.expectEqualStrings("context", ordinary.semantic_notice.topic);
    try std.testing.expectEqualStrings("source limit reached", ordinary.semantic_notice.body);
    try std.testing.expectEqualStrings("github", error_event.error_text.topic);
    try std.testing.expectEqualStrings("publish failed", error_event.error_text.body);
}

fn checkSemanticNoticeEnqueueAllocationFailure(alloc: std.mem.Allocator) !void {
    var runtime = WorkerRuntime{};
    defer runtime.deinit(alloc);

    try runtime.pushEvent(alloc, .{ .semantic_notice = .{
        .topic = "permissions",
        .tone = .success,
        .body = "approval",
        .visibility = .full_only,
    } });
    var events = runtime.takeEvents();
    defer freeEventList(alloc, &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0] == .semantic_notice);
    try std.testing.expectEqualStrings("permissions", events.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings("approval", events.items[0].semantic_notice.body);
}

const PermissionThreadState = struct {
    decision: ?types.ToolPermissionDecision = null,
    err: ?anyerror = null,
};

fn runPermissionRequest(state: *PermissionThreadState, runtime: *WorkerRuntime, label: []const u8) void {
    var response = runtime.requestPermissionBlocking(
        std.testing.allocator,
        .{ .label = label },
    ) catch |err| {
        state.err = err;
        return;
    };
    defer response.deinit();
    state.decision = response.decision;
}

fn submitPermissionDecisionForTest(
    runtime: *WorkerRuntime,
    request_id: u64,
    decision: types.ToolPermissionDecision,
) PermissionSubmissionResult {
    return runtime.submitPermissionResponse(
        request_id,
        permission_request.OwnedPermissionResponse.init(
            std.testing.allocator,
            decision,
            null,
        ),
    );
}

fn waitForPermissionLabel(worker: *WorkerRuntime, expected: []const u8) !u64 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        var snapshot = try worker.snapshotState(std.testing.allocator);
        defer snapshot.deinit(std.testing.allocator);
        if (snapshot.pending_permission_request) |request| {
            try std.testing.expectEqualStrings(expected, request.label);
            try std.testing.expect(request.id != 0);
            return request.id;
        }
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

const QuestionThreadState = struct {
    answers: ?[][]u8 = null,
    err: ?anyerror = null,
};

fn runQuestionRequest(state: *QuestionThreadState, runtime: *WorkerRuntime, entries: []const types.QuestionBatchEntry) void {
    state.answers = runtime.requestQuestionBatchAnswerBlocking(std.testing.allocator, entries) catch |err| {
        state.err = err;
        return;
    };
}

fn runRouteRecoveryRequest(state: *QuestionThreadState, runtime: *WorkerRuntime, entries: []const types.QuestionBatchEntry) void {
    state.answers = runtime.requestRouteRecoveryAnswerBlocking(std.testing.allocator, entries) catch |err| {
        state.err = err;
        return;
    };
}

fn waitForQuestionSnapshot(worker: *WorkerRuntime) !PendingQuestionBatchSnapshot {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (try worker.snapshotPendingQuestionBatch(std.testing.allocator)) |snapshot| return snapshot;
        io_mod.sleep(1 * std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn freeAnswers(alloc: std.mem.Allocator, answers: ?[][]u8) void {
    if (answers) |labels| {
        for (labels) |label| alloc.free(label);
        alloc.free(labels);
    }
}
