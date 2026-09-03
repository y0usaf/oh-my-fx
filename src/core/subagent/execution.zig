const std = @import("std");
const agent_runtime = @import("../agent/agent_runtime.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const runtime_assistant_stream = @import("../agent/runtime/assistant_stream.zig");
const runtime_config = @import("../agent/runtime/config.zig");
const runtime_deps = @import("../agent/runtime/deps.zig");
const runtime_lifecycle = @import("../agent/runtime/lifecycle.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const authority_mod = @import("authority.zig");
const approval_registry_mod = @import("approval_registry.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const TurnPreferences = struct {
    provider: @import("../config/model_provider.zig").ProviderId = .gateway,
    model: []const u8,
    effort: types.ReasoningEffort,
};

pub const CaptureRequest = struct {
    child_id: []const u8,
    parent_id: []const u8,
    source_id: []const u8,
    preferences: TurnPreferences,
};

pub const RunOutcome = enum { completed, awaiting_approval, paused };

pub const ServiceError = error{
    OutOfMemory,
    AdmissionFailed,
    ProviderFailed,
    Cancelled,
};

pub const Services = struct {
    context: ?*anyopaque = null,
    capture_fn: *const fn (
        ?*anyopaque,
        Allocator,
        CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot,
    run_fn: *const fn (
        ?*anyopaque,
        *TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) ServiceError!RunOutcome,

    pub fn capture(
        self: Services,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        return self.capture_fn(self.context, alloc, request);
    }

    pub fn run(
        self: Services,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        return self.run_fn(self.context, turn, message, admission, cancel);
    }
};

pub const CommitError = error{
    OutOfMemory,
    InvalidWorkId,
    TurnAlreadyCommitted,
    SessionCommitFailed,
};

pub const TurnContext = struct {
    alloc: Allocator,
    runtime: session.SessionRuntime,
    worker: worker_runtime.WorkerRuntime = .{},
    managed_executions: managed_execution.Runtime,
    loaded: *session_store.LoadedWritableSession,
    live_authority: ?*authority_mod.Resolver = null,
    approval_registry: ?*approval_registry_mod.Registry = null,
    approval_worker_route: ?approval_registry_mod.WorkerRoute = null,
    child_id: ?[]const u8 = null,
    active_work_id: ?[]const u8 = null,
    phase_context: ?*anyopaque = null,
    phase_fn: ?*const fn (
        *anyopaque,
        []const u8,
        []const u8,
        child_state.Phase,
    ) anyerror!void = null,
    failure_diagnostic: ?[]u8 = null,
    committed: bool = false,

    pub fn init(
        alloc: Allocator,
        loaded: *session_store.LoadedWritableSession,
        max_history_turns: usize,
    ) !TurnContext {
        var runtime = session.SessionRuntime{ .max_history_turns = max_history_turns };
        errdefer runtime.deinit(alloc);
        try runtime.restoreWithPermissionState(
            alloc,
            loaded.state.conversation_language,
            loaded.state.history,
            loaded.state.context_history_start,
            loaded.state.permission_state,
        );
        return .{
            .alloc = alloc,
            .runtime = runtime,
            .managed_executions = managed_execution.Runtime.init(alloc),
            .loaded = loaded,
        };
    }

    pub fn deinit(self: *TurnContext) void {
        if (self.failure_diagnostic) |diagnostic| self.alloc.free(diagnostic);
        self.managed_executions.deinit();
        self.worker.deinit(self.alloc);
        self.runtime.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn setFailureDiagnostic(
        self: *TurnContext,
        code: []const u8,
        detail: []const u8,
    ) Allocator.Error!void {
        if (self.failure_diagnostic != null) return;
        const safe_detail = if (text_utils.isModelSafeText(detail))
            text_utils.utf8PrefixByBytes(
                detail,
                domain.max_cancellation_reason_bytes -| code.len -| 2,
            )
        else
            "";
        self.failure_diagnostic = if (safe_detail.len == 0)
            try self.alloc.dupe(u8, text_utils.utf8PrefixByBytes(
                code,
                domain.max_cancellation_reason_bytes,
            ))
        else
            try std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ code, safe_detail });
    }

    pub fn failureDiagnostic(self: *const TurnContext) ?[]const u8 {
        return self.failure_diagnostic;
    }

    pub fn sessionRuntime(self: *TurnContext) *session.SessionRuntime {
        return &self.runtime;
    }

    pub fn snapshotRecoveryCheckpoint(
        self: *const TurnContext,
        alloc: Allocator,
    ) Allocator.Error!?session_codec.RecoveryCheckpoint {
        const checkpoint = self.loaded.state.recovery_checkpoint orelse return null;
        return try checkpoint.dupe(alloc);
    }

    pub fn childCapability(
        self: *TurnContext,
    ) !*session_child_store.SessionChildCapability {
        return self.loaded.childCapability();
    }

    pub fn workerRuntime(self: *TurnContext) *worker_runtime.WorkerRuntime {
        return &self.worker;
    }

    pub fn managedExecutionRuntime(self: *TurnContext) *managed_execution.Runtime {
        return &self.managed_executions;
    }

    pub fn appendLiveText(_: *TurnContext, _: []const u8) void {}

    pub fn appendLiveEvent(
        _: *TurnContext,
        _: worker_runtime.WorkerEvent,
    ) void {}

    pub fn resolveLiveAuthority(
        self: *TurnContext,
        alloc: Allocator,
    ) authority_mod.Error!authority_mod.Snapshot {
        const resolver = self.live_authority orelse
            return error.HostAuthorityUnavailable;
        return resolver.resolve(
            alloc,
            self.child_id orelse return error.ChildNotAttached,
        );
    }

    pub fn liveToolAuthorityProvider(
        self: *TurnContext,
    ) runtime_deps.LiveToolAuthorityProvider {
        return .{ .context = self, .resolve_fn = resolveLiveToolAction };
    }

    pub fn toolActivityRecorder(self: *TurnContext) runtime_deps.ToolActivityRecorder {
        return .{ .context = self, .record_fn = recordToolActivity };
    }

    pub fn permissionPrompter(self: *TurnContext) permission_prompter.Prompter {
        return .{ .context = self, .request_fn = requestChildPermission };
    }

    fn requestChildPermission(
        raw: *anyopaque,
        alloc: Allocator,
        request: permission_request.PermissionRequest,
        call: types.ToolCall,
        review: ?*const @import("../output/diff.zig").FileReview,
        grant_offer: ?[]const types.PermissionGrant,
    ) !permission_request.OwnedPermissionResponse {
        const self: *TurnContext = @ptrCast(@alignCast(raw));
        const child_id = self.child_id orelse return error.ChildNotAttached;
        const work_id = self.active_work_id orelse return error.StaleRequest;
        const prepared = approval_registry_mod.preparedRequestFingerprint(request);
        const grant = types.PermissionGrant{
            .tool_name = @constCast(call.name),
            .target_path = @constCast(request.command orelse call.name),
        };
        var context = PermissionObservation{
            .turn = self,
            .stable_id = approval_registry_mod.stableApprovalId(
                child_id,
                work_id,
                prepared,
            ),
            .grants = grant_offer orelse &.{grant},
        };
        return self.worker.requestPermissionBlockingObserved(
            alloc,
            request,
            review,
            .{ .context = &context, .observe_fn = PermissionObservation.observe },
        );
    }

    const PermissionObservation = struct {
        turn: *TurnContext,
        stable_id: [64]u8,
        grants: []const types.PermissionGrant,

        fn observe(
            raw: *anyopaque,
            _: *worker_runtime.WorkerRuntime,
            request: permission_request.PermissionRequest,
        ) error{
            OutOfMemory,
            PermissionRegistrationFailed,
            PermissionCapacityExceeded,
        }!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.turn.registerApproval(
                self.turn.alloc,
                &self.stable_id,
                request,
                self.grants,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CapacityExceeded => error.PermissionCapacityExceeded,
                else => error.PermissionRegistrationFailed,
            };
        }
    };

    fn resolveLiveToolAction(
        raw: *anyopaque,
        alloc: Allocator,
        call: types.ToolCall,
        workspace_root: []const u8,
        target: []const u8,
        target_kind: tool_dispatch.PermissionTargetKind,
    ) !runtime_deps.ResolvedLiveToolAuthority {
        const self: *TurnContext = @ptrCast(@alignCast(raw));
        const snapshot = try self.resolveLiveAuthority(alloc);
        const decision = try authority_mod.decideToolAuthority(
            alloc,
            snapshot.view(),
            workspace_root,
            call.name,
            target,
            target_kind,
        );
        const permission_state = try alloc.create(session_permission_state.State);
        permission_state.* = snapshot.permission_state;
        return .{
            .authority = .{
                .generation = snapshot.generation,
                .root_id = snapshot.root_id,
                .tools = snapshot.tools,
                .integrations = snapshot.integrations,
                .rules = snapshot.rules,
                .grants = snapshot.grants,
                .permission_state = permission_state,
                .permission_mode = snapshot.permission_mode,
            },
            .decision = switch (decision) {
                .allow => .allow,
                .ask => .ask,
                .deny => .deny,
                .unavailable => .unavailable,
            },
        };
    }

    fn recordToolActivity(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: runtime_deps.ToolActivityPhase,
    ) !void {}

    pub fn registerApproval(
        self: *TurnContext,
        alloc: Allocator,
        stable_request_id: []const u8,
        request: permission_request.PermissionRequest,
        grants: []const types.PermissionGrant,
    ) (approval_registry_mod.Error || authority_mod.Error)!void {
        const registry = self.approval_registry orelse
            return error.RegistryClosed;
        const worker_route = self.approval_worker_route orelse
            return error.RegistryClosed;
        const child_id = self.child_id orelse return error.ChildNotAttached;
        const work_id = self.active_work_id orelse return error.StaleRequest;
        var authority = try self.resolveLiveAuthority(alloc);
        defer authority.deinit(alloc);
        try self.transitionPhase(work_id, .awaiting_approval);
        registry.registerTool(
            stable_request_id,
            child_id,
            authority.root_id,
            work_id,
            request,
            grants,
            worker_route,
            io_mod.milliTimestamp(),
        ) catch |err| {
            try self.transitionPhase(work_id, .running);
            return err;
        };
    }

    fn transitionPhase(
        self: *TurnContext,
        work_id: []const u8,
        phase: child_state.Phase,
    ) approval_registry_mod.Error!void {
        const apply = self.phase_fn orelse return error.CommitFailed;
        apply(
            self.phase_context orelse return error.CommitFailed,
            self.child_id orelse return error.CommitFailed,
            work_id,
            phase,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CommitFailed,
        };
    }

    pub fn commit(
        self: *TurnContext,
        work_id: []const u8,
        turn: types.HistoryTurn,
        total_input_tokens: u64,
        total_output_tokens: u64,
        timestamp_ms: i64,
    ) CommitError!void {
        if (self.committed) return error.TurnAlreadyCommitted;
        var committed_turn = session.dupeHistoryTurn(self.alloc, turn) catch
            return error.OutOfMemory;
        defer session.freeHistoryTurn(self.alloc, committed_turn);
        session.copyWorkIdToTurn(self.alloc, &committed_turn, work_id) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidWorkId, error.ConflictingWorkId => error.InvalidWorkId,
            };
        };
        self.runtime.appendHistoryEntry(self.alloc, committed_turn) catch
            return error.OutOfMemory;
        _ = self.loaded.appendEvent(
            self.alloc,
            .{ .history_turn_committed = .{
                .conversation_language = self.runtime.languageSnapshot(),
                .total_input_tokens = total_input_tokens,
                .total_output_tokens = total_output_tokens,
                .work_id = @constCast(work_id),
                .turn = committed_turn,
            } },
            timestamp_ms,
            .retry_expected_tail,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionCommitFailed,
        };
        self.committed = true;
    }

    pub fn setRecoveryCheckpoint(
        self: *TurnContext,
        checkpoint: session_codec.RecoveryCheckpoint,
        timestamp_ms: i64,
    ) CommitError!void {
        _ = self.loaded.appendEvent(
            self.alloc,
            .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
            timestamp_ms,
            .retry_expected_tail,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionCommitFailed,
        };
    }
};

pub const NormalAgentError = error{
    OutOfMemory,
    Cancelled,
    AgentExecutionFailed,
};

pub fn runNormalAgentTurn(
    agent: *agent_runtime.Agent,
    deps: *const runtime_deps.AgentRuntimeDeps,
    semantic_presentation: ?runtime_assistant_stream.SemanticPresentationSink,
    lifecycle: runtime_lifecycle.LifecycleContext,
    config: runtime_config.Config,
    prompt: worker_runtime.QueuedPrompt,
) NormalAgentError!void {
    agent_runtime.processAgentPrompt(
        agent,
        deps,
        semantic_presentation,
        lifecycle,
        config,
        prompt,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        else => error.AgentExecutionFailed,
    };
}
