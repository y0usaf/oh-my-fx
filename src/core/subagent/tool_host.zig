const std = @import("std");
const builtin = @import("builtin");
const approval_persistence = @import("approval_persistence.zig");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const auto_classifier_context = @import("../permissions/auto_classifier_context.zig");
const communication = @import("communication.zig");
const communication_manager = @import("communication_manager.zig");
const create_store = @import("create_store.zig");
const communication_store = @import("communication_store.zig");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const manager_mod = @import("manager.zig");
const tool_result = @import("tool_result.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const model_provider = @import("../config/model_provider.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const inspect_wait_external_poll_ms: i64 = 100;

const TargetAuthorizationTestHook = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (?*anyopaque) void,
};

const TestHooks = struct {
    var after_target_authorization: ?TargetAuthorizationTestHook = null;
};

fn runAfterTargetAuthorizationTestHook() void {
    if (comptime builtin.is_test) {
        const hook = TestHooks.after_target_authorization orelse return;
        hook.run_fn(hook.context);
    }
}

pub const RecoveryState = enum(u8) {
    pending,
    scheduled,
    running,
    deferred,
    complete,
};

const RecoveryTrigger = enum {
    automatic,
    explicit,
};

const RecoveryStartDecision = enum {
    schedule,
    start,
    wait,
    no_effect,
};

const RecoveryFinishOutcome = enum {
    fully_reconciled,
    incomplete,
    failed,
};

fn decideRecoveryStart(
    state: RecoveryState,
    trigger: RecoveryTrigger,
) RecoveryStartDecision {
    return switch (state) {
        .pending => switch (trigger) {
            .automatic => .schedule,
            .explicit => .start,
        },
        .scheduled, .running => switch (trigger) {
            .automatic => .no_effect,
            .explicit => .wait,
        },
        .deferred => switch (trigger) {
            .automatic => .no_effect,
            .explicit => .start,
        },
        .complete => .no_effect,
    };
}

fn recoveryStateAfterFinish(outcome: RecoveryFinishOutcome) RecoveryState {
    return switch (outcome) {
        .fully_reconciled => .complete,
        .incomplete, .failed => .deferred,
    };
}

pub const BackgroundRecoveryError = error{ThreadSpawnFailed};

pub const Defaults = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool = false,
    conversation_language: session.ConversationLanguage,
};

pub const ChildRunner = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (
        ?*anyopaque,
        *execution.TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome = unavailableChildRun,
};

fn unavailableChildRun(
    _: ?*anyopaque,
    _: *execution.TurnContext,
    _: domain.QueuedMessage,
    _: domain.AdmissionSnapshot,
    _: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    return error.ProviderFailed;
}

pub const ExecuteOptions = struct {
    caller_id: []const u8,
    invocation_id: []const u8,
    parent_permission_mode: types.PermissionMode = .yolo,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    defaults: Defaults,
    max_result_bytes: usize,
    timestamp_ms: i64,
    relationship_approval_id: ?[]const u8 = null,
    identity_epoch: u64 = 0,
};

pub const MessageSendOptions = struct {
    caller_id: []const u8,
    invocation_id: []const u8,
    child_id: []const u8,
    content: []const u8,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
};

pub const HumanCommandOptions = struct {
    invocation_id: []const u8,
    defaults: Defaults,
    expected_generation: ?u64 = null,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
};

pub const ApprovalResolveOptions = struct {
    request_id: []const u8,
    child_id: []const u8,
    decision: types.ToolPermissionDecision,
    feedback: ?[]const u8 = null,
    timestamp_ms: i64,
};

fn buildHumanQueuedRootUserContext(
    alloc: Allocator,
    command: domain.Command,
) !?[]u8 {
    const current_request = humanQueuedRootUserMessage(command);
    return if (current_request) |request|
        try auto_classifier_context.buildCanonicalRootUserContext(
            alloc,
            request,
            &.{},
        )
    else
        null;
}

fn humanQueuedRootUserMessage(command: domain.Command) ?[]const u8 {
    return switch (command) {
        .create => |create| create.prompt,
        .message => |message| switch (message) {
            .send => |send| send.content,
            .milestone => null,
        },
        .inspect, .relationship, .configure, .lifecycle => null,
    };
}

const ModelCommandOutcome = union(enum) {
    result: manager_mod.Result,
    relationship_approval: domain.RelationshipCommand,
    adapter_failure: struct {
        child_id: ?[]const u8,
        code: []const u8,
        retryable: bool = false,
    },

    fn deinit(self: *ModelCommandOutcome, alloc: Allocator) void {
        switch (self.*) {
            .result => |*result| result.deinit(alloc),
            .relationship_approval, .adapter_failure => {},
        }
        self.* = undefined;
    }
};

pub const Runtime = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    root_id: []u8,
    host_authority: authority.HostResolver,
    child_runner: ChildRunner,
    manager: manager_mod.Manager,
    durable_approvals: approval_persistence.DurableRegistry,
    approvals: approval_registry.Registry,
    authority_resolver: authority.Resolver,
    owner: execution.Owner,
    recovery_mutex: std.Io.Mutex = .init,
    recovery_condition: std.Io.Condition = .init,
    recovery_thread: ?std.Thread = null,
    recovery_state: std.atomic.Value(RecoveryState) = .init(.pending),

    pub fn create(
        alloc: Allocator,
        sessions: *session_store.Store,
        root_id: []const u8,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    ) !*Runtime {
        try domain.validateId(root_id);
        const runtime = try alloc.create(Runtime);
        errdefer alloc.destroy(runtime);
        const owned_root = try alloc.dupe(u8, root_id);
        errdefer alloc.free(owned_root);

        runtime.* = .{
            .alloc = alloc,
            .sessions = sessions,
            .root_id = owned_root,
            .host_authority = host_authority,
            .child_runner = child_runner,
            .manager = .{ .sessions = sessions },
            .durable_approvals = .{ .alloc = alloc, .sessions = sessions },
            .approvals = undefined,
            .authority_resolver = undefined,
            .owner = undefined,
        };
        runtime.approvals = .{
            .alloc = alloc,
            .persistence = runtime.durable_approvals.interface(),
        };
        runtime.authority_resolver = .{
            .sessions = sessions,
            .host = host_authority,
        };
        runtime.owner = runtime.ownerValue();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.recovery_thread) |thread| thread.join();
        self.recovery_thread = null;
        const had_owned_work = self.owner.started_any;
        self.owner.deinit();
        if (had_owned_work) {
            var recovery_owner = self.ownerValue();
            _ = recovery_owner.recoverTree(
                self.root_id,
                io_mod.milliTimestamp(),
            ) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "host exit recovery failed root_id={s} outcome={s}",
                    .{ self.root_id, @errorName(err) },
                );
            };
            recovery_owner.deinit();
        }
        self.approvals.deinit();
        self.alloc.free(self.root_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    /// Refreshes borrowed host pointers after an embedding runtime moves.
    /// Callers must do this before any child work starts.
    pub fn rebind(
        self: *Runtime,
        sessions: *session_store.Store,
        child_runner_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        std.debug.assert(self.owner.slots.items.len == 0);
        std.debug.assert(self.recovery_thread == null);
        self.sessions = sessions;
        self.manager.sessions = sessions;
        self.durable_approvals.sessions = sessions;
        self.authority_resolver.sessions = sessions;
        self.authority_resolver.host = self.host_authority;
        self.owner.sessions = sessions;
        self.child_runner.context = child_runner_context;
        self.host_authority = host_authority;
        self.authority_resolver.host = host_authority;
    }

    pub fn issueOperationIdentity(
        self: *Runtime,
        alloc: Allocator,
        invocation_id: []const u8,
        source: domain.OperationIdentitySource,
    ) !u64 {
        return issueManagerOperationIdentity(
            alloc,
            self.sessions,
            self.root_id,
            self.manager.options.child_store,
            invocation_id,
            source,
        );
    }

    fn ownerValue(self: *Runtime) execution.Owner {
        return .{
            .alloc = self.alloc,
            .sessions = self.sessions,
            .manager = &self.manager,
            .services = .{
                .context = self,
                .capture_fn = captureAdmission,
                .run_fn = runChild,
            },
            .live_authority = &self.authority_resolver,
            .approval_registry = &self.approvals,
            .retirement_root_id = self.root_id,
            .notification_clock = .{
                .now_fn = notificationNow,
            },
            .notification_poller = .{
                .context = self,
                .poll_fn = pollNotification,
            },
        };
    }

    fn notificationNow(_: ?*anyopaque) i64 {
        return io_mod.milliTimestamp();
    }

    fn pollNotification(
        raw: ?*anyopaque,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        now_ms: i64,
    ) communication_manager.Error!communication_manager.PollOutcome {
        const self: *Runtime = @ptrCast(@alignCast(raw orelse
            return error.StoreUnavailable));
        var delivery_manager = communication_manager.Manager{
            .sessions = self.sessions,
            .child_store_options = self.manager.options.child_store,
        };
        return delivery_manager.poll(alloc, child_id, work_id, now_ms);
    }

    pub fn execute(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        options: ExecuteOptions,
    ) ![]u8 {
        if (command.* == .inspect) {
            return self.executeModelInspection(alloc, command.*, options);
        }
        if (command.* == .create and
            !try self.callerMayCreate(alloc, options.caller_id))
        {
            return boundedFailureAlloc(
                alloc,
                options.invocation_id,
                null,
                "invalid_state",
                false,
                options.max_result_bytes,
            );
        }
        if (!try self.admitModelCommand(
            alloc,
            command,
            options.caller_id,
            options.parent_permission_mode,
        )) {
            return boundedFailureAlloc(
                alloc,
                options.invocation_id,
                commandTarget(command.*),
                "permission_escalation",
                false,
                options.max_result_bytes,
            );
        }
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            try self.issueOperationIdentity(alloc, options.invocation_id, .model);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            options.invocation_id,
            .model,
            identity_epoch,
        );
        defer alloc.free(operation_id);
        const identity_admitted = try self.operationIdentityOutstanding(
            alloc,
            operation_id,
        );
        self.recoverIfNeeded(options.timestamp_ms);

        var outcome = try self.executeModelMutation(
            alloc,
            command,
            options,
            operation_id,
            identity_epoch,
            identity_admitted,
        );
        defer outcome.deinit(alloc);
        self.finishModelOutcome(alloc, operation_id, &outcome);
        return switch (outcome) {
            .result => |result| self.encodeResult(
                alloc,
                operation_id,
                result,
                options.max_result_bytes,
                null,
            ),
            .relationship_approval => |relationship| encodeRelationshipApprovalIntent(
                alloc,
                operation_id,
                relationship,
                options.max_result_bytes,
            ),
            .adapter_failure => |failure| boundedFailureAlloc(
                alloc,
                operation_id,
                failure.child_id,
                failure.code,
                failure.retryable,
                options.max_result_bytes,
            ),
        };
    }

    fn executeModelInspection(
        self: *Runtime,
        alloc: Allocator,
        command: domain.Command,
        options: ExecuteOptions,
    ) ![]u8 {
        std.debug.assert(command == .inspect);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            options.invocation_id,
            .model,
            0,
        );
        defer alloc.free(operation_id);
        self.recoverIfNeeded(options.timestamp_ms);
        const target_id = command.inspect.id;
        const wait = command.inspect.wait;
        const deadline = if (wait) |requested|
            std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
                .clock = .awake,
                .raw = .fromMilliseconds(@intCast(requested.timeout_ms)),
            })
        else
            null;

        while (true) {
            var waiter = execution.ChildWaiter{ .child_id = target_id };
            if (wait != null) try self.owner.registerChildWaiter(&waiter);
            defer if (waiter.registered) self.owner.unregisterChildWaiter(&waiter);

            if (!std.mem.eql(u8, options.caller_id, self.root_id) and
                !try self.isAttached(self.root_id, options.caller_id))
            {
                return tool_result.failureAlloc(
                    alloc,
                    operation_id,
                    null,
                    "rejected",
                    "caller_unavailable",
                    false,
                    null,
                );
            }
            if (!std.mem.eql(u8, target_id, options.caller_id) and
                !try self.isAttached(options.caller_id, target_id))
            {
                return tool_result.failureAlloc(
                    alloc,
                    operation_id,
                    target_id,
                    "rejected",
                    "child_unavailable",
                    false,
                    null,
                );
            }
            runAfterTargetAuthorizationTestHook();

            var result = try self.manager.execute(alloc, command, .{
                .actor_id = options.caller_id,
                .target_authorization = .{ .attached_to_root = self.root_id },
                .timestamp_ms = options.timestamp_ms,
            });
            defer result.deinit(alloc);

            const requested_wait = wait orelse return self.encodeResult(
                alloc,
                operation_id,
                result,
                options.max_result_bytes,
                null,
            );
            const inspection = switch (result) {
                .inspection => |*value| value,
                .receipt => unreachable,
                .failure => return self.encodeResult(
                    alloc,
                    operation_id,
                    result,
                    options.max_result_bytes,
                    null,
                ),
            };
            if (domain.inspectWaitSatisfied(
                requested_wait,
                inspection.generation,
                inspection.status.?,
            )) {
                return self.encodeResult(
                    alloc,
                    operation_id,
                    result,
                    options.max_result_bytes,
                    null,
                );
            }

            const remaining = deadline.?.durationFromNow(io_mod.getIo());
            if (remaining.raw.nanoseconds <= 0) {
                return self.encodeResult(
                    alloc,
                    operation_id,
                    result,
                    options.max_result_bytes,
                    "wait_timed_out",
                );
            }
            const poll_duration = std.Io.Duration.fromMilliseconds(
                inspect_wait_external_poll_ms,
            );
            _ = try waiter.wait(.{
                .clock = .awake,
                .raw = .{
                    .nanoseconds = @min(
                        remaining.raw.nanoseconds,
                        poll_duration.nanoseconds,
                    ),
                },
            });
        }
    }

    fn executeModelMutation(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        options: ExecuteOptions,
        operation_id: []const u8,
        identity_epoch: u64,
        identity_admitted: bool,
    ) !ModelCommandOutcome {
        if (command.* == .message and command.message == .send) {
            var result = try self.sendMessageWithOperation(
                alloc,
                command.*,
                operation_id,
                options.caller_id,
                options.root_user_intent_context,
                options.root_user_messages,
                options.root_user_evidence_complete,
                options.timestamp_ms,
                .model,
                identity_epoch,
                identity_admitted,
            );
            normalizeRetiredResult(identity_admitted, &result);
            return .{ .result = result };
        }
        if (identity_admitted and
            !std.mem.eql(u8, options.caller_id, self.root_id) and
            !try self.isAttached(self.root_id, options.caller_id))
        {
            return .{ .result = .{ .failure = .{
                .code = .caller_unavailable,
            } } };
        }

        const target = commandTarget(command.*);
        if (target) |target_id| {
            const relationship_external = switch (command.*) {
                .relationship => |value| value.action != .detach,
                else => false,
            };
            if (identity_admitted and
                !relationship_external and
                !std.mem.eql(u8, target_id, options.caller_id) and
                !try self.isAttached(options.caller_id, target_id))
            {
                return .{ .result = .{ .failure = .{
                    .code = .child_unavailable,
                } } };
            }
        }
        if (command.* == .create or command.* == .configure or command.* == .lifecycle) {
            runAfterTargetAuthorizationTestHook();
        }

        if (!try self.admitModelCommand(
            alloc,
            command,
            options.caller_id,
            options.parent_permission_mode,
        )) {
            return .{ .adapter_failure = .{
                .child_id = commandTarget(command.*),
                .code = "permission_escalation",
            } };
        }

        if (command.* == .create) try applyCreateDefaults(alloc, &command.create, options.defaults);
        var context = manager_mod.Context{
            .actor_id = options.caller_id,
            .root_user_intent_context = options.root_user_intent_context,
            .root_user_messages = options.root_user_messages,
            .root_user_evidence_complete = options.root_user_evidence_complete,
            .operation_id = operation_id,
            .operation_identity_source = .model,
            .operation_identity_epoch = identity_epoch,
            .operation_identity_admitted = identity_admitted,
            .timestamp_ms = options.timestamp_ms,
        };
        if (command.* == .relationship) {
            const relationship = command.relationship;
            if (relationship.action != .detach and
                options.relationship_approval_id == null)
            {
                if (!identity_admitted) {
                    return .{ .result = .{ .failure = .{
                        .code = .operation_replay_expired,
                    } } };
                }
                const parent_id = relationship.parent_id orelse options.caller_id;
                self.approvals.registerRelationship(
                    operation_id,
                    relationship.id,
                    self.root_id,
                    relationship.action,
                    parent_id,
                    operation_id,
                    relationshipApprovalLabel(relationship.action),
                    identity_admitted,
                    options.timestamp_ms,
                ) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    if (err == error.CapacityExceeded) {
                        return .{ .adapter_failure = .{
                            .child_id = relationship.id,
                            .code = "communication_capacity_exceeded",
                        } };
                    }
                    return .{ .adapter_failure = .{
                        .child_id = relationship.id,
                        .code = "approval_registration_failed",
                    } };
                };
                return .{ .relationship_approval = relationship };
            }
            context.relationship_authorization = if (relationship.action == .detach)
                .none
            else if (options.relationship_approval_id) |approval_id|
                .{ .approval = approval_id }
            else
                .none;
        }

        var result = try self.executeAuthorizedCommand(
            alloc,
            command.*,
            context,
            options.defaults,
        );
        normalizeRetiredResult(identity_admitted, &result);
        return .{ .result = result };
    }

    /// Applies the model-tool-only child permission boundary. Root callers use
    /// the current turn's effective mode; child callers are resolved from live
    /// control state on every check.
    pub fn admitModelCommand(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        caller_id: []const u8,
        root_permission_mode: types.PermissionMode,
    ) authority.Error!bool {
        const requested: ?types.PermissionMode = switch (command.*) {
            .create => |create_command| if (create_command.permission_mode_explicit)
                create_command.configuration.permission_mode
            else
                null,
            .configure => |configure| configure.permission_mode orelse return true,
            .inspect, .message, .relationship, .lifecycle => return true,
        };
        const parent_permission_mode = if (std.mem.eql(u8, caller_id, self.root_id))
            root_permission_mode
        else blk: {
            var snapshot = try self.authority_resolver.resolve(alloc, caller_id);
            defer snapshot.deinit(alloc);
            break :blk snapshot.permission_mode;
        };
        const admitted = authority.admitChildPermission(
            parent_permission_mode,
            requested,
        ) catch return false;
        if (command.* == .create and !command.create.permission_mode_explicit) {
            command.create.configuration.permission_mode = admitted;
        }
        return true;
    }

    fn callerMayCreate(
        self: *Runtime,
        alloc: Allocator,
        caller_id: []const u8,
    ) error{OutOfMemory}!bool {
        if (std.mem.eql(u8, caller_id, self.root_id)) return true;
        var capability = self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            caller_id,
            self.manager.options.child_store,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => false,
        };
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = caller_id,
        };
        var record = (store.loadOptional(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => false,
        }) orelse return false;
        defer record.deinit(alloc);
        return record.mode != .one_off;
    }

    /// Typed human adapter for the same canonical command/effect path used by
    /// the model tool. Human relationship submission is itself the explicit
    /// authorization; all validation and state mutation remain manager-owned.
    pub fn executeHumanCommand(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        options: HumanCommandOptions,
    ) !manager_mod.Result {
        if (command.* == .inspect) {
            self.recoverIfNeeded(options.timestamp_ms);
            const target_id = command.inspect.id;
            if (!std.mem.eql(u8, target_id, self.root_id) and
                !try self.isAttached(self.root_id, target_id))
            {
                return .{ .failure = .{ .code = .child_unavailable } };
            }
            runAfterTargetAuthorizationTestHook();
            return self.manager.execute(alloc, command.*, .{
                .actor_id = self.root_id,
                .target_authorization = .{ .attached_to_root = self.root_id },
                .timestamp_ms = options.timestamp_ms,
            });
        }
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            try self.issueOperationIdentity(alloc, options.invocation_id, .human);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            options.invocation_id,
            .human,
            identity_epoch,
        );
        defer alloc.free(operation_id);
        const identity_admitted = try self.operationIdentityOutstanding(
            alloc,
            operation_id,
        );
        self.recoverIfNeeded(options.timestamp_ms);

        var result = try self.executeHumanMutation(
            alloc,
            command,
            options,
            operation_id,
            identity_epoch,
            identity_admitted,
        );
        normalizeRetiredResult(identity_admitted, &result);
        self.finishOperationResult(alloc, operation_id, &result);
        return result;
    }

    fn executeHumanMutation(
        self: *Runtime,
        alloc: Allocator,
        command: *domain.Command,
        options: HumanCommandOptions,
        operation_id: []const u8,
        identity_epoch: u64,
        identity_admitted: bool,
    ) !manager_mod.Result {
        const owned_root_user_intent_context = try buildHumanQueuedRootUserContext(
            alloc,
            command.*,
        );
        defer if (owned_root_user_intent_context) |context| alloc.free(context);
        const root_user_intent_context = owned_root_user_intent_context orelse "";
        const root_user_message = humanQueuedRootUserMessage(command.*);
        const root_user_messages: []const []const u8 = if (root_user_message) |message|
            &.{message}
        else
            &.{};
        if (command.* == .message and command.message == .send) {
            return self.sendMessageWithOperation(
                alloc,
                command.*,
                operation_id,
                self.root_id,
                root_user_intent_context,
                root_user_messages,
                root_user_message != null,
                options.timestamp_ms,
                .human,
                identity_epoch,
                identity_admitted,
            );
        }

        if (commandTarget(command.*)) |target_id| {
            const relationship_external = command.* == .relationship;
            if (identity_admitted and
                !relationship_external and
                !std.mem.eql(u8, target_id, self.root_id) and
                !try self.isAttached(self.root_id, target_id))
            {
                return .{ .failure = .{ .code = .child_unavailable } };
            }
        }
        if (command.* == .configure or command.* == .lifecycle) {
            runAfterTargetAuthorizationTestHook();
        }

        if (command.* == .create) try applyCreateDefaults(alloc, &command.create, options.defaults);
        return self.executeAuthorizedCommand(
            alloc,
            command.*,
            .{
                .actor_id = self.root_id,
                .root_user_intent_context = root_user_intent_context,
                .root_user_messages = root_user_messages,
                .root_user_evidence_complete = root_user_message != null,
                .operation_id = operation_id,
                .operation_identity_source = .human,
                .operation_identity_epoch = identity_epoch,
                .operation_identity_admitted = identity_admitted,
                .expected_generation = options.expected_generation,
                .relationship_authorization = if (command.* == .relationship and
                    command.relationship.action != .detach)
                    .direct
                else
                    .none,
                .timestamp_ms = options.timestamp_ms,
            },
            options.defaults,
        );
    }

    pub fn resolveApproval(
        self: *Runtime,
        options: ApprovalResolveOptions,
    ) approval_registry.Error!approval_registry.ResolveResult {
        const resolved = self.approvals.resolve(
            options.request_id,
            options.child_id,
            options.decision,
            options.feedback,
            options.timestamp_ms,
        ) catch |err| {
            if (self.relationshipApprovalIsTerminal(
                options.child_id,
                options.request_id,
            ) catch false) {
                self.completeOperationIdentity(options.request_id) catch
                    return error.CommitFailed;
            }
            return err;
        };
        switch (resolved) {
            .accepted => {
                if (options.decision == .deny) {
                    self.completeOperationIdentity(options.request_id) catch
                        return error.CommitFailed;
                }
                return .accepted;
            },
            .rejected => return .rejected,
            .relationship_ready => return self.continueApprovedRelationship(
                options,
            ),
        }
    }

    fn continueApprovedRelationship(
        self: *Runtime,
        options: ApprovalResolveOptions,
    ) approval_registry.Error!approval_registry.ResolveResult {
        var continuation = self.durable_approvals.loadRelationshipContinuation(
            options.child_id,
            options.request_id,
        ) catch |err| return self.relationshipContinuationLoadFailed(
            options,
            err,
        );
        defer continuation.deinit(self.alloc);

        if (!std.mem.eql(u8, continuation.root_id, self.root_id) or
            !std.mem.eql(u8, continuation.operation_id, options.request_id))
        {
            return self.terminalizeRelationshipContinuation(
                options,
                "identity_mismatch",
            );
        }
        const identity = tool_result.parseBoundOperationId(
            continuation.operation_id,
        ) orelse return self.terminalizeRelationshipContinuation(
            options,
            "invalid_operation_identity",
        );
        if (identity.authority != .manager or
            identity.source != .model or identity.epoch == 0)
        {
            return self.terminalizeRelationshipContinuation(
                options,
                "invalid_operation_identity",
            );
        }
        if (continuation.status == .consumed) {
            return self.finishAppliedRelationship(
                options,
                continuation.action,
            );
        }
        if (continuation.status != .allowed_once) {
            return self.terminalizeRelationshipContinuation(
                options,
                "identity_mismatch",
            );
        }

        const identity_admitted = self.operationIdentityOutstanding(
            self.alloc,
            continuation.operation_id,
        ) catch |err| {
            return self.releaseRelationshipContinuation(
                options,
                if (err == error.OutOfMemory)
                    error.OutOfMemory
                else
                    error.CommitFailed,
                @errorName(err),
            );
        };
        if (!identity_admitted) {
            return self.terminalizeRelationshipContinuation(
                options,
                "operation_identity_retired",
            );
        }

        var command = domain.validateCommand(self.alloc, .{ .relationship = .{
            .action = continuation.action,
            .id = continuation.child_id,
            .parent_id = continuation.prospective_parent_id,
        } }) catch |err| {
            return if (err == error.OutOfMemory)
                self.releaseRelationshipContinuation(
                    options,
                    error.OutOfMemory,
                    @errorName(err),
                )
            else
                self.terminalizeRelationshipContinuation(
                    options,
                    @errorName(err),
                );
        };
        defer command.deinit(self.alloc);
        var result = self.manager.execute(self.alloc, command, .{
            .actor_id = self.root_id,
            .operation_id = continuation.operation_id,
            .operation_identity_source = identity.source,
            .operation_identity_epoch = identity.epoch,
            .operation_identity_admitted = true,
            .relationship_authorization = .{
                .approval = options.request_id,
            },
            .timestamp_ms = options.timestamp_ms,
        }) catch {
            return self.releaseRelationshipContinuation(
                options,
                error.OutOfMemory,
                "OutOfMemory",
            );
        };
        defer result.deinit(self.alloc);
        switch (result) {
            .receipt => {
                var observed = self.durable_approvals.loadRelationshipContinuation(
                    options.child_id,
                    options.request_id,
                ) catch |err| return self.relationshipContinuationLoadFailed(
                    options,
                    err,
                );
                defer observed.deinit(self.alloc);
                if (observed.status != .consumed) {
                    return self.releaseRelationshipContinuation(
                        options,
                        error.CommitFailed,
                        "approval_not_consumed",
                    );
                }
                return self.finishAppliedRelationship(
                    options,
                    continuation.action,
                );
            },
            .failure => |failure| return if (failure.retryable)
                self.releaseRelationshipContinuation(
                    options,
                    error.CommitFailed,
                    @tagName(failure.code),
                )
            else
                self.terminalizeRelationshipContinuation(
                    options,
                    @tagName(failure.code),
                ),
            .inspection => unreachable,
        }
    }

    fn finishAppliedRelationship(
        self: *Runtime,
        options: ApprovalResolveOptions,
        action: domain.RelationshipAction,
    ) approval_registry.Error!approval_registry.ResolveResult {
        try self.approvals.completeRelationship(
            options.request_id,
            options.child_id,
            .succeeded,
            options.timestamp_ms,
        );
        self.retireResolvedRelationshipIdentity(
            options.request_id,
            options.child_id,
        );
        debug_trace.logf(
            "subagent",
            "relationship approval applied request_id={s} child_id={s} action={s}",
            .{
                options.request_id,
                options.child_id,
                @tagName(action),
            },
        );
        return .accepted;
    }

    fn relationshipContinuationLoadFailed(
        self: *Runtime,
        options: ApprovalResolveOptions,
        err: approval_persistence.Error,
    ) approval_registry.Error {
        if (!relationshipContinuationLoadRetryable(err)) {
            return self.terminalizeRelationshipContinuation(
                options,
                @errorName(err),
            );
        }
        return self.releaseRelationshipContinuation(
            options,
            if (err == error.OutOfMemory)
                error.OutOfMemory
            else
                error.CommitFailed,
            @errorName(err),
        );
    }

    fn releaseRelationshipContinuation(
        self: *Runtime,
        options: ApprovalResolveOptions,
        result_error: approval_registry.Error,
        reason: []const u8,
    ) approval_registry.Error {
        self.approvals.completeRelationship(
            options.request_id,
            options.child_id,
            .retryable_failure,
            options.timestamp_ms,
        ) catch |err| return err;
        debug_trace.logf(
            "subagent",
            "relationship approval deferred request_id={s} child_id={s} outcome={s}",
            .{ options.request_id, options.child_id, reason },
        );
        return result_error;
    }

    fn terminalizeRelationshipContinuation(
        self: *Runtime,
        options: ApprovalResolveOptions,
        reason: []const u8,
    ) approval_registry.Error {
        self.approvals.completeRelationship(
            options.request_id,
            options.child_id,
            .terminal_failure,
            options.timestamp_ms,
        ) catch |err| return err;
        self.retireResolvedRelationshipIdentity(
            options.request_id,
            options.child_id,
        );
        debug_trace.logf(
            "subagent",
            "relationship approval invalidated request_id={s} child_id={s} outcome={s}",
            .{ options.request_id, options.child_id, reason },
        );
        return error.StaleRequest;
    }

    fn retireResolvedRelationshipIdentity(
        self: *Runtime,
        request_id: []const u8,
        child_id: []const u8,
    ) void {
        self.completeOperationIdentity(request_id) catch |err| {
            debug_trace.logf(
                "subagent",
                "relationship approval identity cleanup failed request_id={s} child_id={s} outcome={s}",
                .{ request_id, child_id, @errorName(err) },
            );
        };
    }

    fn relationshipApprovalIsTerminal(
        self: *Runtime,
        child_id: []const u8,
        request_id: []const u8,
    ) !bool {
        const alloc = self.alloc;
        var capability = try self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            self.manager.options.child_store,
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var ledger = (try store.loadOptional(alloc)) orelse return false;
        defer ledger.deinit(alloc);
        const approval = communication.findApproval(
            ledger.approvals,
            request_id,
        ) orelse return false;
        const relationship = approval.relationship orelse return false;
        if (!std.mem.eql(u8, relationship.operation_id, request_id)) {
            return false;
        }
        return switch (approval.status) {
            .denied, .cancelled, .stale, .consumed => true,
            .pending, .allowed_once, .allowed_always => false,
        };
    }

    /// Completes restart reconciliation for an explicit subagent operation.
    /// An admitted background attempt finishes first; a deferred attempt may
    /// then be retried once by this caller. Recovery never starts child work.
    pub fn reconcileAfterRestart(
        self: *Runtime,
        timestamp_ms: i64,
    ) execution.RecoveryError!execution.RecoveryReport {
        const io = io_mod.getIo();
        self.recovery_mutex.lockUncancelable(io);
        defer self.recovery_mutex.unlock(io);

        while (true) {
            const state = self.recovery_state.load(.acquire);
            switch (decideRecoveryStart(state, .explicit)) {
                .no_effect => return .{},
                .wait => {
                    std.debug.assert(state == .scheduled);
                    self.recovery_condition.waitUncancelable(io, &self.recovery_mutex);
                },
                .start => {
                    switch (state) {
                        .pending => if (self.recovery_state.cmpxchgStrong(
                            .pending,
                            .running,
                            .acq_rel,
                            .acquire,
                        ) != null) continue,
                        .deferred => self.recovery_state.store(.running, .release),
                        else => unreachable,
                    }
                    return self.runRecoveryLocked(timestamp_ms);
                },
                .schedule => unreachable,
            }
        }
    }

    fn runRecoveryLocked(
        self: *Runtime,
        timestamp_ms: i64,
    ) execution.RecoveryError!execution.RecoveryReport {
        std.debug.assert(self.recovery_state.load(.acquire) == .running);
        const report = self.owner.recoverTree(
            self.root_id,
            timestamp_ms,
        ) catch |err| {
            self.requestRetirementSweep(timestamp_ms);
            self.finishRecoveryLocked(.failed);
            return err;
        };
        self.requestRetirementSweep(timestamp_ms);
        self.finishRecoveryLocked(if (report.fullyReconciled())
            .fully_reconciled
        else
            .incomplete);
        return report;
    }

    fn finishRecoveryLocked(self: *Runtime, outcome: RecoveryFinishOutcome) void {
        self.recovery_state.store(recoveryStateAfterFinish(outcome), .release);
        self.recovery_condition.broadcast(io_mod.getIo());
    }

    /// Admits at most one automatic restart reconciliation for this host.
    /// Partial or failed work remains deferred until an explicit operation.
    pub fn requestBackgroundRecovery(
        self: *Runtime,
        timestamp_ms: i64,
    ) BackgroundRecoveryError!void {
        while (true) {
            const state = self.recovery_state.load(.acquire);
            switch (decideRecoveryStart(state, .automatic)) {
                .no_effect => return,
                .schedule => {
                    if (self.recovery_state.cmpxchgStrong(
                        .pending,
                        .scheduled,
                        .acq_rel,
                        .acquire,
                    ) != null) continue;
                    break;
                },
                .start, .wait => unreachable,
            }
        }

        self.recovery_thread = std.Thread.spawn(
            .{},
            backgroundRecoveryMain,
            .{ self, timestamp_ms },
        ) catch {
            const io = io_mod.getIo();
            self.recovery_mutex.lockUncancelable(io);
            self.recovery_state.store(.deferred, .release);
            self.recovery_condition.broadcast(io);
            self.recovery_mutex.unlock(io);
            return error.ThreadSpawnFailed;
        };
    }

    pub fn recoveryState(self: *const Runtime) RecoveryState {
        return self.recovery_state.load(.acquire);
    }

    pub fn requestRetirementSweep(self: *Runtime, timestamp_ms: i64) void {
        if (comptime builtin.single_threaded) return;
        self.owner.requestRetirementSweep(timestamp_ms) catch |err| {
            debug_trace.logf(
                "subagent",
                "retirement sweep wake failed root_id={s} outcome={s}",
                .{ self.root_id, @errorName(err) },
            );
            return;
        };
        debug_trace.logf(
            "subagent",
            "retirement sweep requested root_id={s}",
            .{self.root_id},
        );
    }

    fn backgroundRecoveryMain(self: *Runtime, timestamp_ms: i64) void {
        const io = io_mod.getIo();
        self.recovery_mutex.lockUncancelable(io);
        std.debug.assert(self.recovery_state.load(.acquire) == .scheduled);
        self.recovery_state.store(.running, .release);
        const report = self.runRecoveryLocked(timestamp_ms) catch |err| {
            self.recovery_mutex.unlock(io);
            debug_trace.logf(
                "subagent",
                "background host recovery deferred root_id={s} trigger=automatic state=deferred outcome={s}",
                .{ self.root_id, @errorName(err) },
            );
            return;
        };
        const final_state = self.recovery_state.load(.acquire);
        self.recovery_mutex.unlock(io);
        debug_trace.logf(
            "subagent",
            "background host recovery finished root_id={s} trigger=automatic state={s} changed={d} interrupted={d} completed={d} busy={d} failed={d}",
            .{
                self.root_id,
                @tagName(final_state),
                report.sessions_changed,
                report.work_interrupted,
                report.work_completed,
                report.sessions_external_busy,
                report.sessions_failed,
            },
        );
    }

    /// Typed human/model shared `message.send` path. The invocation identity is
    /// stable across retries; the returned manager result is allocator-owned.
    pub fn sendMessage(
        self: *Runtime,
        alloc: Allocator,
        options: MessageSendOptions,
    ) !manager_mod.Result {
        var command = try domain.validateCommand(alloc, .{ .message = .{ .send = .{
            .id = options.child_id,
            .content = options.content,
        } } });
        defer command.deinit(alloc);
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            try self.issueOperationIdentity(alloc, options.invocation_id, .human);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            options.invocation_id,
            .human,
            identity_epoch,
        );
        defer alloc.free(operation_id);
        const identity_admitted = try self.operationIdentityOutstanding(
            alloc,
            operation_id,
        );
        self.recoverIfNeeded(options.timestamp_ms);
        const owned_root_user_intent_context = try buildHumanQueuedRootUserContext(
            alloc,
            command,
        );
        defer if (owned_root_user_intent_context) |context| alloc.free(context);
        const root_user_messages = [_][]const u8{options.content};
        var result = try self.sendMessageWithOperation(
            alloc,
            command,
            operation_id,
            options.caller_id,
            owned_root_user_intent_context orelse "",
            &root_user_messages,
            true,
            options.timestamp_ms,
            .human,
            identity_epoch,
            identity_admitted,
        );
        normalizeRetiredResult(identity_admitted, &result);
        self.finishOperationResult(alloc, operation_id, &result);
        return result;
    }

    fn sendMessageWithOperation(
        self: *Runtime,
        alloc: Allocator,
        command: domain.Command,
        operation_id: []const u8,
        caller_id: []const u8,
        root_user_intent_context: []const u8,
        root_user_messages: []const []const u8,
        root_user_evidence_complete: bool,
        timestamp_ms: i64,
        identity_source: domain.OperationIdentitySource,
        identity_epoch: u64,
        identity_admitted: bool,
    ) !manager_mod.Result {
        std.debug.assert(command == .message and command.message == .send);
        const send = command.message.send;
        if (identity_admitted and
            !std.mem.eql(u8, caller_id, self.root_id) and
            !try self.isAttached(self.root_id, caller_id))
        {
            return .{ .failure = .{ .code = .caller_unavailable } };
        }
        if (identity_admitted and !std.mem.eql(u8, send.id, caller_id)) {
            const directly_related =
                try self.isDirectParent(caller_id, send.id) or
                try self.isDirectParent(send.id, caller_id);
            if (!directly_related and !try self.isAttached(caller_id, send.id)) {
                return .{ .failure = .{ .code = .child_unavailable } };
            }
        }
        var context: manager_mod.Context = .{
            .actor_id = caller_id,
            .root_user_intent_context = root_user_intent_context,
            .root_user_messages = root_user_messages,
            .root_user_evidence_complete = root_user_evidence_complete,
            .operation_id = operation_id,
            .operation_identity_source = identity_source,
            .operation_identity_epoch = identity_epoch,
            .operation_identity_admitted = identity_admitted,
            .timestamp_ms = timestamp_ms,
        };
        if (identity_admitted and
            std.mem.eql(u8, caller_id, self.root_id) and
            !std.mem.eql(u8, send.id, caller_id))
        {
            context.target_authorization = .{ .attached_to_root = self.root_id };
        }
        const result = try self.manager.execute(alloc, command, context);
        if (result == .receipt) self.requestStart(result.receipt.target_id, false);
        return result;
    }

    fn executeAuthorizedCommand(
        self: *Runtime,
        alloc: Allocator,
        command: domain.Command,
        context: manager_mod.Context,
        defaults: Defaults,
    ) !manager_mod.Result {
        var mutable_context = context;
        if (mutable_context.operation_identity_admitted and
            (command == .configure or command == .lifecycle))
        {
            mutable_context.target_authorization = .{
                .attached_to_root = self.root_id,
            };
        }
        var result = if (command == .create)
            try self.createChild(alloc, command, &mutable_context, defaults)
        else if (command == .lifecycle and command.lifecycle.action == .close)
            if (mutable_context.operation_identity_admitted)
                try self.owner.close(alloc, command.lifecycle.id, mutable_context)
            else
                try self.manager.execute(alloc, command, mutable_context)
        else if (command == .relationship and command.relationship.action == .detach)
            try self.owner.detach(alloc, command.relationship.id, mutable_context)
        else
            try self.manager.execute(alloc, command, mutable_context);
        errdefer result.deinit(alloc);

        if (result == .receipt) switch (command) {
            .create => if (command.create.prompt != null) {
                self.requestStart(result.receipt.target_id, false);
            },
            .message => |message| switch (message) {
                .send => self.requestStart(result.receipt.target_id, false),
                .milestone => {},
            },
            .lifecycle => |lifecycle| switch (lifecycle.action) {
                .cancel => try self.owner.completeCommittedCancellation(
                    lifecycle.id,
                    context.timestamp_ms,
                ),
                .@"resume", .reopen => self.requestStart(
                    lifecycle.id,
                    lifecycle.action == .@"resume",
                ),
                .close => {},
            },
            .relationship => self.requestRetirementSweep(context.timestamp_ms),
            .inspect, .configure => {},
        };
        return result;
    }

    fn recoverIfNeeded(self: *Runtime, timestamp_ms: i64) void {
        _ = self.reconcileAfterRestart(timestamp_ms) catch |err| {
            debug_trace.logf(
                "subagent",
                "lazy host recovery failed root_id={s} outcome={s}",
                .{ self.root_id, @errorName(err) },
            );
        };
    }

    fn requestStart(self: *Runtime, child_id: []const u8, retry_interrupted: bool) void {
        _ = self.owner.start(child_id, retry_interrupted) catch |err| {
            debug_trace.logf(
                "subagent",
                "child wake failed child_id={s} outcome={s}",
                .{ child_id, @errorName(err) },
            );
        };
    }

    fn createChild(
        self: *Runtime,
        alloc: Allocator,
        command: domain.Command,
        context: *manager_mod.Context,
        defaults: Defaults,
    ) !manager_mod.Result {
        var capability = self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.root_id,
            self.manager.options.child_store,
        ) catch |err| return mapCreateCapabilityError(err);
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = self.root_id,
        };
        var lock = store.acquireLock() catch |err| return mapCreateLockError(err);
        defer lock.release();
        const existing = store.loadOptional(alloc) catch |err|
            return mapCreateLoadError(err);
        var record = if (existing) |value|
            value
        else
            try create_store.Record.init(alloc, self.root_id);
        defer record.deinit(alloc);

        const operation_id = context.operation_id orelse
            return .{ .failure = .{ .code = .operation_id_required } };
        const request_identity = domain.OperationRequestFingerprintInput{
            .command = command,
            .actor_id = context.actor_id,
            .target_id = "",
            .source_id = null,
            .effective_parent_id = context.actor_id,
        };
        const request_fingerprint = domain.operationRequestFingerprint(
            request_identity,
        );
        const legacy_request_fingerprint =
            domain.legacyImplicitAutoCreateRequestFingerprint(request_identity);
        var child_id: []const u8 = undefined;
        var legacy_implicit_auto = false;
        if (record.find(operation_id)) |entry| {
            const primary_matches = std.mem.eql(
                u8,
                &entry.request_fingerprint,
                &request_fingerprint,
            );
            const legacy_matches = legacy_request_fingerprint != null and
                std.mem.eql(
                    u8,
                    &entry.request_fingerprint,
                    &legacy_request_fingerprint.?,
                );
            if (!primary_matches and !legacy_matches) {
                return .{ .failure = .{ .code = .operation_conflict } };
            }
            legacy_implicit_auto = !primary_matches and legacy_matches;
            child_id = entry.child_id;
        } else if (record.classify(operation_id) == .expired) {
            return .{ .failure = .{ .code = .operation_replay_expired } };
        } else {
            const reserved_id = try session_store.generateSessionId(alloc);
            defer alloc.free(reserved_id);
            try record.append(
                alloc,
                operation_id,
                request_fingerprint,
                reserved_id,
            );
            store.save(alloc, record) catch |err| {
                if (err != error.CommitIndeterminate or
                    !try reservationWasCommitted(
                        alloc,
                        store,
                        operation_id,
                        request_fingerprint,
                        reserved_id,
                    )) return mapCreateSaveError(err);
            };
            child_id = record.find(operation_id).?.child_id;
        }

        var effective_command = command;
        if (legacy_implicit_auto) {
            effective_command.create.configuration.permission_mode = .auto;
        }
        context.created_child_id = child_id;
        var result = try self.manager.execute(alloc, effective_command, context.*);
        if (result != .failure or result.failure.code != .session_not_found) return result;
        result.deinit(alloc);

        var state = try freshChildState(
            alloc,
            child_id,
            self.sessions.workspace_root,
            effective_command.create,
            defaults,
        );
        defer state.deinit(alloc);
        var writable = self.sessions.startWritableSession(alloc, state) catch |err| {
            if (err == error.SessionAlreadyExists) {
                return self.manager.execute(alloc, effective_command, context.*);
            }
            return error.SessionStoreUnavailable;
        };
        result = self.manager.execute(alloc, effective_command, context.*) catch |err| {
            _ = self.sessions.discardPristineStartedSession(alloc, &writable);
            return err;
        };
        if (result == .failure and result.failure.code != .control_commit_indeterminate) {
            _ = self.sessions.discardPristineStartedSession(alloc, &writable);
            return result;
        }
        writable.log.park();
        writable.deinit(alloc);
        return result;
    }

    fn operationIdentityOutstanding(
        self: *Runtime,
        alloc: Allocator,
        operation_id: []const u8,
    ) !bool {
        var capability = try self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.root_id,
            self.manager.options.child_store,
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = self.root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse return false;
        defer record.deinit(alloc);
        return record.hasOutstanding(operation_id);
    }

    fn finishModelOutcome(
        self: *Runtime,
        alloc: Allocator,
        operation_id: []const u8,
        outcome: *ModelCommandOutcome,
    ) void {
        const resolution: create_store.IdentityResolution = switch (outcome.*) {
            .result => |result| operationIdentityResolution(result),
            .relationship_approval => .pending_approval,
            .adapter_failure => |failure| if (failure.retryable)
                .retryable_failure
            else
                .stable_failure,
        };
        if (create_store.identityFinalization(resolution) == .retain) return;
        self.finalizeOperationIdentity(
            operation_id,
            .retire,
        ) catch {
            outcome.deinit(alloc);
            outcome.* = .{ .result = .{ .failure = .{
                .code = .control_commit_indeterminate,
                .retryable = true,
            } } };
        };
    }

    fn finishOperationResult(
        self: *Runtime,
        alloc: Allocator,
        operation_id: []const u8,
        result: *manager_mod.Result,
    ) void {
        const finalization = create_store.identityFinalization(
            operationIdentityResolution(result.*),
        );
        if (finalization == .retain) return;
        self.finalizeOperationIdentity(operation_id, finalization) catch {
            result.deinit(alloc);
            result.* = .{ .failure = .{
                .code = .control_commit_indeterminate,
                .retryable = true,
            } };
        };
    }

    pub fn abortOperationIdentity(
        self: *Runtime,
        invocation_id: []const u8,
        source: domain.OperationIdentitySource,
        identity_epoch: u64,
    ) !void {
        if (identity_epoch == 0) return;
        const operation_id = try tool_result.boundOperationIdAlloc(
            self.alloc,
            invocation_id,
            source,
            identity_epoch,
        );
        defer self.alloc.free(operation_id);
        try self.finalizeOperationIdentity(operation_id, .retire);
    }

    fn completeOperationIdentity(
        self: *Runtime,
        operation_id: []const u8,
    ) !void {
        return self.finalizeOperationIdentity(operation_id, .retire);
    }

    fn finalizeOperationIdentity(
        self: *Runtime,
        operation_id: []const u8,
        finalization: create_store.IdentityFinalization,
    ) !void {
        const alloc = self.alloc;
        var capability = try self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.root_id,
            self.manager.options.child_store,
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = self.root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse return;
        defer record.deinit(alloc);
        if (!try record.finalizeIdentity(
            alloc,
            operation_id,
            finalization,
        )) return;
        store.save(alloc, record) catch |err| {
            if (err != error.CommitIndeterminate or
                !try outstandingIdentityCompletionWasCommitted(
                    alloc,
                    store,
                    operation_id,
                ))
            {
                return err;
            }
        };
    }

    fn encodeResult(
        self: *Runtime,
        alloc: Allocator,
        operation_id: []const u8,
        result: manager_mod.Result,
        max_result_bytes: usize,
        status_override: ?[]const u8,
    ) ![]u8 {
        _ = self;
        var requested: std.Io.Writer.Allocating = .init(alloc);
        defer requested.deinit();
        var child_id: ?[]const u8 = null;
        var status: []const u8 = "accepted";
        var error_code: ?[]const u8 = null;
        var retryable = false;
        var cursor: ?[]const u8 = null;
        switch (result) {
            .receipt => |receipt| {
                child_id = receipt.target_id;
                status = @tagName(receipt.code);
                try requested.writer.print(
                    "{{\"outcome\":\"{s}\",\"generation\":{d},\"event_sequence\":{d}}}",
                    .{ @tagName(receipt.code), receipt.generation, receipt.event_sequence },
                );
            },
            .inspection => |inspection| {
                child_id = inspection.child_id;
                status = status_override orelse
                    if (inspection.status) |state| @tagName(state) else "inspected";
                cursor = inspection.next_cursor;
                try std.json.Stringify.value(inspection, .{}, &requested.writer);
            },
            .failure => |failure| {
                error_code = @tagName(failure.code);
                retryable = failure.retryable;
                status = "rejected";
                try requested.writer.writeAll("null");
            },
        }
        const requested_json = requested.writer.buffered();
        var encoded = try tool_result.outcomeAlloc(alloc, .{
            .ok = result != .failure,
            .operation_id = operation_id,
            .child_id = child_id,
            .status = status,
            .error_code = error_code,
            .retryable = retryable,
            .requested_json = requested_json,
            .cursor = cursor,
        });
        if (encoded.len <= max_result_bytes) return encoded;
        alloc.free(encoded);
        encoded = try tool_result.failureAlloc(
            alloc,
            operation_id,
            child_id,
            "rejected",
            "result_too_large",
            true,
            cursor,
        );
        return encoded;
    }

    fn isAttached(self: *Runtime, root_id: []const u8, candidate: []const u8) !bool {
        var result = try self.manager.snapshot(self.alloc, .{
            .root_id = root_id,
            .anchor_id = candidate,
            .limit = 1,
        });
        defer result.deinit(self.alloc);
        return switch (result) {
            .failure => false,
            .snapshot => |snapshot| snapshot.nodes.len == 1 and
                std.mem.eql(u8, snapshot.nodes[0].child_id, candidate),
        };
    }

    fn isDirectParent(
        self: *Runtime,
        child_id: []const u8,
        candidate_parent_id: []const u8,
    ) !bool {
        return self.manager.isDirectParent(
            self.alloc,
            child_id,
            candidate_parent_id,
        );
    }
};

pub const ModePolicy = union(enum) {
    full,
    active: struct {
        registry: mode_registry.Registry,
        id: []const u8,
    },

    fn allows(self: ModePolicy, tool_set: tool_set_contract.ToolSet, tool_name: []const u8) bool {
        return switch (self) {
            .full => true,
            .active => |active| active.registry.toolAllowed(tool_set, active.id, tool_name),
        };
    }
};

pub const CapabilityPolicy = struct {
    tool_set: tool_set_contract.ToolSet,
    mode: ModePolicy,
};

pub fn captureHostAuthorityWithMcpView(
    alloc: Allocator,
    policy: CapabilityPolicy,
    integration_names: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
    mcp_view: ?*const mcp_access.View,
) !authority.HostAuthority {
    var tool_names: std.ArrayList([]const u8) = .empty;
    defer tool_names.deinit(alloc);
    for (policy.tool_set.registry.tools) |registered_tool| {
        if (!policy.mode.allows(policy.tool_set, registered_tool.name)) continue;
        if (permissions.rulesDenyAllTargetsForTool(rules, registered_tool.name)) continue;
        try tool_names.append(alloc, registered_tool.name);
    }
    return authority.HostAuthority.captureWithPermissionStateAndMcpView(
        alloc,
        tool_names.items,
        integration_names,
        rules,
        grants,
        permission_state,
        mcp_view,
    );
}

fn commandTarget(command: domain.Command) ?[]const u8 {
    return switch (command) {
        .create => null,
        .message => |message| switch (message) {
            .send => |send| send.id,
            .milestone => null,
        },
        .inspect => |value| value.id,
        .relationship => |value| value.id,
        .configure => |value| value.id,
        .lifecycle => |value| value.id,
    };
}

fn relationshipContinuationLoadRetryable(
    err: approval_persistence.Error,
) bool {
    return switch (err) {
        error.OutOfMemory,
        error.LockBusy,
        error.StoreUnavailable,
        error.CommitIndeterminate,
        => true,
        error.ChildNotAttached,
        error.RelationshipCycle,
        error.GraphTooDeep,
        error.InvalidRequest,
        error.RequestConflict,
        error.RequestResolved,
        error.LockUnsupported,
        error.CapacityExceeded,
        => false,
    };
}

fn operationIdentityResolution(
    result: manager_mod.Result,
) create_store.IdentityResolution {
    return switch (result) {
        .receipt => .receipt,
        .inspection => .stable_failure,
        .failure => |failure| if (failure.code == .control_commit_indeterminate)
            .commit_indeterminate
        else if (failure.retryable)
            .retryable_failure
        else
            .stable_failure,
    };
}

fn normalizeRetiredResult(
    identity_admitted: bool,
    result: *manager_mod.Result,
) void {
    if (identity_admitted or result.* != .failure or result.failure.retryable) {
        return;
    }
    if (result.failure.code == .operation_conflict or
        result.failure.code == .operation_replay_expired)
    {
        return;
    }
    result.* = .{ .failure = .{ .code = .operation_replay_expired } };
}

fn relationshipApprovalLabel(action: domain.RelationshipAction) []const u8 {
    return switch (action) {
        .attach => "Attach existing subagent",
        .reparent => "Reparent subagent",
        .detach => unreachable,
    };
}

fn encodeRelationshipApprovalIntent(
    alloc: Allocator,
    operation_id: []const u8,
    relationship: domain.RelationshipCommand,
    max_result_bytes: usize,
) ![]u8 {
    var requested: std.Io.Writer.Allocating = .init(alloc);
    defer requested.deinit();
    try requested.writer.writeAll("{\"action\":");
    try std.json.Stringify.value(@tagName(relationship.action), .{}, &requested.writer);
    try requested.writer.writeAll(",\"approval_id\":");
    try std.json.Stringify.value(operation_id, .{}, &requested.writer);
    try requested.writer.writeByte('}');

    const encoded = try tool_result.outcomeAlloc(alloc, .{
        .ok = true,
        .operation_id = operation_id,
        .child_id = relationship.id,
        .status = "awaiting_approval",
        .error_code = null,
        .retryable = false,
        .requested_json = requested.writer.buffered(),
        .cursor = null,
    });
    if (encoded.len <= max_result_bytes) return encoded;
    alloc.free(encoded);
    return boundedFailureAlloc(
        alloc,
        operation_id,
        relationship.id,
        "result_too_large",
        false,
        max_result_bytes,
    );
}

fn boundedFailureAlloc(
    alloc: Allocator,
    operation_id: []const u8,
    child_id: ?[]const u8,
    error_code: []const u8,
    retryable: bool,
    max_result_bytes: usize,
) ![]u8 {
    const encoded = try tool_result.failureAlloc(
        alloc,
        operation_id,
        child_id,
        "rejected",
        error_code,
        retryable,
        null,
    );
    if (encoded.len <= max_result_bytes) return encoded;
    alloc.free(encoded);
    return tool_result.failureAlloc(
        alloc,
        operation_id,
        null,
        "rejected",
        "result_too_large",
        retryable,
        null,
    );
}

fn applyCreateDefaults(
    alloc: Allocator,
    create: *domain.CreateCommand,
    defaults: Defaults,
) !void {
    if (create.configuration.model == null) {
        create.configuration.model = try alloc.dupe(u8, defaults.model);
    }
    if (create.configuration.effort == null) create.configuration.effort = defaults.effort;
}

fn freshChildState(
    alloc: Allocator,
    child_id: []const u8,
    workspace_root: []const u8,
    create: domain.CreateCommand,
    defaults: Defaults,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try alloc.dupe(u8, child_id);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, create.configuration.model orelse defaults.model);
    errdefer alloc.free(model);
    const history = try alloc.alloc(types.HistoryTurn, 0);
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = defaults.conversation_language,
        .preferences = .{
            .provider = defaults.provider,
            .model = model,
            .effort = create.configuration.effort orelse defaults.effort,
            .fast_mode = defaults.fast_mode,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

fn reservationWasCommitted(
    alloc: Allocator,
    store: create_store.Store,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    child_id: []const u8,
) !bool {
    var observed = (try store.loadOptional(alloc)) orelse return false;
    defer observed.deinit(alloc);
    const entry = observed.find(operation_id) orelse return false;
    return std.mem.eql(u8, &entry.request_fingerprint, &request_fingerprint) and
        std.mem.eql(u8, entry.child_id, child_id);
}

fn issueManagerOperationIdentity(
    alloc: Allocator,
    sessions: *session_store.Store,
    root_id: []const u8,
    child_store_options: session_child_store.Options,
    invocation_id: []const u8,
    source: domain.OperationIdentitySource,
) !u64 {
    var capability = try sessions.openSubagentControlCapabilityWritable(
        alloc,
        root_id,
        child_store_options,
    );
    defer capability.deinit();
    const store = create_store.Store{
        .capability = &capability,
        .expected_root_id = root_id,
    };
    var lock = try store.acquireLock();
    defer lock.release();
    const existing = try store.loadOptional(alloc);
    var record = if (existing) |value|
        value
    else
        try create_store.Record.init(alloc, root_id);
    defer record.deinit(alloc);
    if (record.outstandingEpochForInvocation(invocation_id, source)) |epoch| {
        return epoch;
    }
    const epoch = try record.reserveIdentity(alloc, invocation_id, source);
    const operation_id = try tool_result.boundOperationIdAlloc(
        alloc,
        invocation_id,
        source,
        epoch,
    );
    defer alloc.free(operation_id);
    store.save(alloc, record) catch |err| {
        if (err != error.CommitIndeterminate or
            !try outstandingIdentityWasCommitted(
                alloc,
                store,
                operation_id,
            ))
        {
            return err;
        }
    };
    return epoch;
}

fn outstandingIdentityWasCommitted(
    alloc: Allocator,
    store: create_store.Store,
    operation_id: []const u8,
) !bool {
    var observed = (try store.loadOptional(alloc)) orelse return false;
    defer observed.deinit(alloc);
    return observed.hasOutstanding(operation_id);
}

fn outstandingIdentityCompletionWasCommitted(
    alloc: Allocator,
    store: create_store.Store,
    operation_id: []const u8,
) !bool {
    var observed = (try store.loadOptional(alloc)) orelse return true;
    defer observed.deinit(alloc);
    return !observed.hasOutstanding(operation_id);
}

fn mapCreateCapabilityError(err: session_store.OpenSubagentControlError) manager_mod.Result {
    return .{ .failure = .{ .code = switch (err) {
        error.InvalidSessionId, error.SessionNotFound => .session_not_found,
        error.SessionPathUnsafe, error.PrivateStatePermissionsUnsupported => .control_path_unsafe,
        error.OutOfMemory, error.SessionStoreUnavailable, error.SessionChildStoreFailed => .store_failure,
    } } };
}

fn mapCreateLockError(err: create_store.LockError) manager_mod.Result {
    return .{ .failure = .{ .code = switch (err) {
        error.LockBusy => .control_lock_busy,
        error.LockUnsupported => .control_lock_unsupported,
        error.PathUnsafe, error.PrivateStatePermissionsUnsupported => .control_path_unsafe,
        error.OutOfMemory, error.StoreFailed => .store_failure,
    }, .retryable = err == error.LockBusy } };
}

fn mapCreateLoadError(err: create_store.LoadError) manager_mod.Result {
    return .{ .failure = .{ .code = switch (err) {
        error.InvalidRecord, error.UnsupportedSchema => .control_record_invalid,
        error.RecordTooLarge => .control_record_too_large,
        error.PathUnsafe, error.PrivateStatePermissionsUnsupported => .control_path_unsafe,
        error.RecordNotFound, error.OutOfMemory, error.StoreFailed => .store_failure,
    } } };
}

fn mapCreateSaveError(err: create_store.SaveError) manager_mod.Result {
    return .{ .failure = .{ .code = switch (err) {
        error.RecordTooLarge => .control_record_too_large,
        error.PathUnsafe, error.PrivateStatePermissionsUnsupported => .control_path_unsafe,
        error.CommitIndeterminate => .control_commit_indeterminate,
        error.IdentityMismatch => .control_record_invalid,
        error.OutOfMemory, error.StoreFailed => .store_failure,
    }, .retryable = err == error.CommitIndeterminate } };
}

fn captureAdmission(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: execution.CaptureRequest,
) execution.ServiceError!domain.AdmissionSnapshot {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    var snapshot = self.authority_resolver.resolve(alloc, request.child_id) catch
        return error.AdmissionFailed;
    defer snapshot.deinit(alloc);
    return domain.captureAdmission(alloc, .{
        .parent_id = request.parent_id,
        .source_id = request.source_id,
        .model = request.preferences.model,
        .provider = request.preferences.provider,
        .effort = request.preferences.effort,
        .permission_mode = snapshot.permission_mode,
        .tool_names = snapshot.tools,
        .rules = snapshot.rules,
        .grants = snapshot.grants,
        .permission_state = snapshot.permission_state,
        .integration_names = snapshot.integrations,
        .authority_generation = if (snapshot.mcp_view) |view|
            mcp_access.authorityGeneration(view)
        else
            0,
        .mcp_view = snapshot.mcp_view,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AdmissionFailed,
    };
}

fn runChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    message: domain.QueuedMessage,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.child_runner.run_fn(
        self.child_runner.context,
        turn,
        message,
        admission,
        cancel,
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
};

const AlwaysBusyControlLock = struct {
    now_ms: i64 = 0,

    fn tryLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
        return false;
    }

    fn now(raw: ?*anyopaque) i64 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return self.now_ms;
    }

    fn sleep(raw: ?*anyopaque, millis: u64) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.now_ms += @intCast(millis);
    }

    fn options(self: *@This()) session_child_store.Options {
        return .{ .lock_ops = .{
            .ctx = self,
            .try_lock = tryLock,
            .now_ms = now,
            .sleep_ms = sleep,
        } };
    }
};

fn readIdentityProcessFd(fd: std.c.fd_t, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read_count = std.c.read(fd, bytes.ptr + offset, bytes.len - offset);
        switch (std.c.errno(read_count)) {
            .SUCCESS => {
                if (read_count == 0) return error.ProcessPipeFailed;
                offset += @intCast(read_count);
            },
            .INTR => continue,
            else => return error.ProcessPipeFailed,
        }
    }
}

fn writeIdentityProcessFd(fd: std.c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const write_count = std.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        switch (std.c.errno(write_count)) {
            .SUCCESS => offset += @intCast(write_count),
            .INTR => continue,
            else => return error.ProcessPipeFailed,
        }
    }
}

fn closeIdentityProcessFd(fd: std.c.fd_t) void {
    const file: std.Io.File = .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
    file.close(io_mod.getIo());
}

fn waitIdentityProcess(pid: std.c.pid_t) !u8 {
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(pid, &status, 0);
        switch (std.c.errno(waited)) {
            .SUCCESS => {
                if (waited != pid or (status & 0x7f) != 0) {
                    return error.ProcessWaitFailed;
                }
                return @intCast((status >> 8) & 0xff);
            },
            .INTR => continue,
            else => return error.ProcessWaitFailed,
        }
    }
}

fn forkIdentityIssuer(
    home: []const u8,
    workspace: []const u8,
    root_id: []const u8,
    invocation_id: []const u8,
    marker: u64,
    ready_fd: std.c.fd_t,
    start_fd: std.c.fd_t,
    result_fd: std.c.fd_t,
) !std.c.pid_t {
    const pid = std.c.fork();
    if (pid < 0) return error.ProcessForkFailed;
    if (pid != 0) return pid;

    writeIdentityProcessFd(ready_fd, &.{1}) catch std.c._exit(100);
    var start: [1]u8 = undefined;
    readIdentityProcessFd(start_fd, &start) catch std.c._exit(101);
    const alloc = std.heap.c_allocator;
    var sessions = session_store.Store.initFromHome(
        alloc,
        home,
        workspace,
    ) catch std.c._exit(102);
    const epoch = issueManagerOperationIdentity(
        alloc,
        &sessions,
        root_id,
        .{},
        invocation_id,
        .model,
    ) catch std.c._exit(103);
    const result = [2]u64{ marker, epoch };
    writeIdentityProcessFd(result_fd, std.mem.asBytes(&result)) catch
        std.c._exit(104);
    sessions.deinit(alloc);
    std.c._exit(0);
}

fn forceDurableReplayHorizon(
    alloc: Allocator,
    sessions: *session_store.Store,
    root_id: []const u8,
    child_id: []const u8,
    horizon: u64,
) !void {
    {
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            root_id,
            .{},
        );
        defer capability.deinit();
        const store = create_store.Store{
            .capability = &capability,
            .expected_root_id = root_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse
            return error.TestUnexpectedResult;
        defer record.deinit(alloc);
        record.identity_epoch_high = horizon;
        record.legacy_replay_closed = true;
        record.model_replay_floor = horizon;
        record.human_replay_floor = horizon;
        record.model_epoch_high = horizon;
        record.human_epoch_high = horizon;
        try store.save(alloc, record);
    }
    {
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var record = (try store.loadOptional(alloc)) orelse
            return error.TestUnexpectedResult;
        defer record.deinit(alloc);
        record.legacy_replay_closed = true;
        record.model_replay_floor = horizon;
        record.human_replay_floor = horizon;
        record.model_epoch_high = horizon;
        record.human_epoch_high = horizon;
        try store.save(alloc, record);
    }
    {
        var capability = try sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            .{},
        );
        defer capability.deinit();
        const store = communication_store.Store{
            .capability = &capability,
            .expected_session_id = child_id,
        };
        var lock = try store.acquireLock();
        defer lock.release();
        var ledger = if (try store.loadOptional(alloc)) |existing|
            existing
        else
            try communication.Ledger.init(alloc, child_id);
        defer ledger.deinit(alloc);
        ledger.legacy_operation_replay_closed = true;
        ledger.model_replay_floor = horizon;
        ledger.human_replay_floor = horizon;
        ledger.model_epoch_high = horizon;
        ledger.human_epoch_high = horizon;
        try store.save(alloc, ledger);
    }
}

fn testOptions(caller_id: []const u8, invocation_id: []const u8) ExecuteOptions {
    return .{
        .caller_id = caller_id,
        .invocation_id = invocation_id,
        .defaults = .{
            .provider = .gateway,
            .model = "test/model",
            .effort = types.ReasoningEffort.literal("high"),
            .conversation_language = session.ConversationLanguage.literal("en"),
        },
        .max_result_bytes = 64 * 1024,
        .timestamp_ms = 10,
    };
}

fn testHumanOptions(invocation_id: []const u8) HumanCommandOptions {
    return .{
        .invocation_id = invocation_id,
        .defaults = .{
            .provider = .gateway,
            .model = "test/model",
            .effort = types.ReasoningEffort.literal("high"),
            .conversation_language = session.ConversationLanguage.literal("en"),
        },
        .timestamp_ms = 10,
    };
}

const AuthorizationRaceIds = struct {
    const root = "01J00000000000000000000000";
    const actor = "01J00000000000000000000001";
    const replacement = "01J00000000000000000000002";
    const target = "01J00000000000000000000003";
};

const TargetAuthorizationBarrier = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn pause(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    fn hook(self: *@This()) TargetAuthorizationTestHook {
        return .{
            .context = self,
            .run_fn = pause,
        };
    }

    fn waitUntilEntered(self: *@This()) !void {
        const deadline = io_mod.milliTimestamp() + 5_000;
        while (!self.entered.load(.seq_cst) and
            io_mod.milliTimestamp() < deadline)
        {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        if (!self.entered.load(.seq_cst)) return error.TestUnexpectedResult;
    }
};

fn createAuthorizationRaceChild(
    alloc: Allocator,
    manager: *manager_mod.Manager,
    actor_id: []const u8,
    child_id: []const u8,
    operation_id: []const u8,
    name: []const u8,
) !void {
    var create = try domain.validateCommand(alloc, .{ .create = .{
        .name = name,
        .mode = .persistent,
    } });
    defer create.deinit(alloc);
    var result = try manager.execute(alloc, create, .{
        .actor_id = actor_id,
        .operation_id = operation_id,
        .created_child_id = child_id,
        .timestamp_ms = 1,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result == .receipt);
    try std.testing.expectEqual(domain.OutcomeCode.created, result.receipt.code);
}

fn createAuthorizationRaceTree(
    alloc: Allocator,
    env: *TestEnvironment,
    manager: *manager_mod.Manager,
) !void {
    for ([_][]const u8{
        AuthorizationRaceIds.actor,
        AuthorizationRaceIds.replacement,
        AuthorizationRaceIds.target,
    }) |session_id| {
        try env.createSession(alloc, session_id);
    }
    try createAuthorizationRaceChild(
        alloc,
        manager,
        AuthorizationRaceIds.root,
        AuthorizationRaceIds.actor,
        "create-authorization-actor",
        "stale caller",
    );
    try createAuthorizationRaceChild(
        alloc,
        manager,
        AuthorizationRaceIds.root,
        AuthorizationRaceIds.replacement,
        "create-authorization-replacement",
        "replacement parent",
    );
    try createAuthorizationRaceChild(
        alloc,
        manager,
        AuthorizationRaceIds.actor,
        AuthorizationRaceIds.target,
        "create-authorization-target",
        "private target configuration",
    );
}

const PausedInspect = struct {
    host: *Runtime,
    result: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        const alloc = std.heap.c_allocator;
        var inspect = domain.validateCommand(alloc, .{ .inspect = .{
            .id = AuthorizationRaceIds.target,
            .sections = &.{.configuration},
        } }) catch |err| {
            self.failure = err;
            return;
        };
        defer inspect.deinit(alloc);
        self.result = self.host.execute(
            alloc,
            &inspect,
            testOptions(AuthorizationRaceIds.actor, "stale-inspect"),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const PausedConfigure = struct {
    host: *Runtime,
    result: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        const alloc = std.heap.c_allocator;
        var configure = domain.validateCommand(alloc, .{ .configure = .{
            .id = AuthorizationRaceIds.target,
            .name = "unauthorized replacement",
        } }) catch |err| {
            self.failure = err;
            return;
        };
        defer configure.deinit(alloc);
        self.result = self.host.execute(
            alloc,
            &configure,
            testOptions(AuthorizationRaceIds.actor, "stale-configure"),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const PausedPermissionConfigure = struct {
    host: *Runtime,
    result: ?[]u8 = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        const alloc = std.heap.c_allocator;
        var configure = domain.validateCommand(alloc, .{ .configure = .{
            .id = AuthorizationRaceIds.target,
            .permission_mode = .yolo,
        } }) catch |err| {
            self.failure = err;
            return;
        };
        defer configure.deinit(alloc);
        self.result = self.host.execute(
            alloc,
            &configure,
            testOptions(AuthorizationRaceIds.actor, "stale-permission-configure"),
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

fn resultOperationIdAlloc(alloc: Allocator, result_json: []const u8) ![]u8 {
    return resultStringAlloc(alloc, result_json, "operation_id");
}

fn terminalDeliveryCount(
    alloc: Allocator,
    sessions: *session_store.Store,
    child_id: []const u8,
    state: domain.State,
) !usize {
    var capability = try sessions.openSubagentControlCapabilityReadOnly(
        alloc,
        child_id,
        .{},
    );
    defer capability.deinit();
    const store = communication_store.Store{
        .capability = &capability,
        .expected_session_id = child_id,
    };
    var ledger = try store.load(alloc);
    defer ledger.deinit(alloc);
    var count: usize = 0;
    for (ledger.deliveries) |delivery| switch (delivery.payload) {
        .terminal => |terminal| if (terminal == state) {
            count += 1;
        },
        else => {},
    };
    return count;
}

fn resultStringAlloc(
    alloc: Allocator,
    result_json: []const u8,
    key: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result_json, .{});
    defer parsed.deinit();
    const raw = parsed.value.object.get(key) orelse return error.TestUnexpectedResult;
    if (raw != .string) return error.TestUnexpectedResult;
    return alloc.dupe(u8, raw.string);
}

const BlockingChild = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(
        raw: ?*anyopaque,
        _: *execution.TurnContext,
        _: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome {
        const self: *BlockingChild = @ptrCast(@alignCast(raw.?));
        self.started.store(true, .seq_cst);
        while (!cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        return error.Cancelled;
    }
};

const RecoverySyncBarrier = struct {
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *RecoverySyncBarrier = @ptrCast(@alignCast(raw.?));
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    fn waitUntilEntered(self: *RecoverySyncBarrier) !void {
        const deadline = io_mod.milliTimestamp() + 5_000;
        while (!self.entered.load(.seq_cst) and
            io_mod.milliTimestamp() < deadline)
        {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        if (!self.entered.load(.seq_cst)) return error.TestUnexpectedResult;
    }
};

const ConcurrentRecovery = struct {
    host: *Runtime,
    timestamp_ms: i64,
    ready: *std.atomic.Value(usize),
    start: *std.atomic.Value(bool),
    completed: *std.atomic.Value(usize),
    report: execution.RecoveryReport = .{},
    failure: ?anyerror = null,

    fn run(self: *ConcurrentRecovery) void {
        _ = self.ready.fetchAdd(1, .seq_cst);
        while (!self.start.load(.seq_cst)) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        self.report = self.host.reconcileAfterRestart(self.timestamp_ms) catch |err| {
            self.failure = err;
            _ = self.completed.fetchAdd(1, .seq_cst);
            return;
        };
        _ = self.completed.fetchAdd(1, .seq_cst);
    }
};

const ConcurrentCreate = struct {
    host: *Runtime,
    root_id: []const u8,
    identity_epoch: u64,
    encoded: ?[]u8 = null,
    failed: bool = false,

    fn run(self: *ConcurrentCreate) void {
        const alloc = std.heap.c_allocator;
        var command = domain.validateCommand(alloc, .{ .create = .{
            .name = "concurrent-worker",
            .mode = .persistent,
        } }) catch {
            self.failed = true;
            return;
        };
        defer command.deinit(alloc);
        var options = testOptions(self.root_id, "concurrent-create");
        options.identity_epoch = self.identity_epoch;
        self.encoded = self.host.execute(alloc, &command, options) catch {
            self.failed = true;
            return;
        };
    }
};

const CreateSyncFailure = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *CreateSyncFailure = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == 1) return error.InjectedParentSyncFailure;
    }
};

const FailFirstTwoDirSyncs = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *FailFirstTwoDirSyncs = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls <= 2) return error.InjectedDirSyncFailure;
    }
};

const CountingChild = struct {
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn run(
        raw: ?*anyopaque,
        turn: *execution.TurnContext,
        message: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        _: *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome {
        const self: *CountingChild = @ptrCast(@alignCast(raw.?));
        const history_turn = session.makeAssistantTurn(
            turn.alloc,
            message.content,
            "completed",
        ) catch return error.OutOfMemory;
        defer session.freeHistoryTurn(turn.alloc, history_turn);
        turn.commit(message.id, history_turn, 1, 1, io_mod.milliTimestamp()) catch
            return error.ProviderFailed;
        _ = self.completed.fetchAdd(1, .seq_cst);
        return .completed;
    }

    fn waitFor(self: *CountingChild, expected: usize) !void {
        const deadline = io_mod.milliTimestamp() + 15_000;
        while (self.completed.load(.seq_cst) < expected and
            io_mod.milliTimestamp() < deadline)
        {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        if (self.completed.load(.seq_cst) != expected) {
            return error.TestUnexpectedResult;
        }
    }
};

const ReleasableLiveChild = struct {
    entered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(
        raw: ?*anyopaque,
        turn: *execution.TurnContext,
        message: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome {
        const self: *ReleasableLiveChild = @ptrCast(@alignCast(raw.?));
        turn.appendLiveText(message.content);
        turn.toolActivityRecorder().record(
            "call-live",
            "read_file",
            .started,
        ) catch return error.ProviderFailed;
        _ = self.entered.fetchAdd(1, .seq_cst);
        while (!self.release.load(.seq_cst) and !cancel.load(.seq_cst)) {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (cancel.load(.seq_cst)) return error.Cancelled;
        const history_turn = session.makeAssistantTurn(
            turn.alloc,
            message.content,
            "completed",
        ) catch return error.OutOfMemory;
        defer session.freeHistoryTurn(turn.alloc, history_turn);
        turn.commit(message.id, history_turn, 1, 1, io_mod.milliTimestamp()) catch
            return error.ProviderFailed;
        _ = self.completed.fetchAdd(1, .seq_cst);
        return .completed;
    }

    fn waitFor(
        self: *ReleasableLiveChild,
        field: *std.atomic.Value(usize),
        expected: usize,
    ) !void {
        const deadline = io_mod.milliTimestamp() + 15_000;
        while (field.load(.seq_cst) < expected and
            io_mod.milliTimestamp() < deadline)
        {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (field.load(.seq_cst) != expected) return error.TestUnexpectedResult;
        _ = self;
    }
};

const HeldCancellationChild = struct {
    entered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(
        raw: ?*anyopaque,
        _: *execution.TurnContext,
        _: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome {
        const self: *HeldCancellationChild = @ptrCast(@alignCast(raw.?));
        _ = self.entered.fetchAdd(1, .seq_cst);
        while (!self.release.load(.seq_cst)) {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (cancel.load(.seq_cst)) return error.Cancelled;
        return error.ProviderFailed;
    }

    fn waitFor(self: *HeldCancellationChild, expected: usize) !void {
        const deadline = io_mod.milliTimestamp() + 5_000;
        while (self.entered.load(.seq_cst) < expected and
            io_mod.milliTimestamp() < deadline)
        {
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (self.entered.load(.seq_cst) != expected) {
            return error.TestUnexpectedResult;
        }
    }
};

const ReleaseAfterWaiterRegistration = struct {
    owner: *execution.Owner,
    runner: *ReleasableLiveChild,
    observed_registration: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ReleaseAfterWaiterRegistration) void {
        const deadline = io_mod.milliTimestamp() + 5_000;
        while (io_mod.milliTimestamp() < deadline) {
            self.owner.mutex.lockUncancelable(io_mod.getIo());
            const registered = self.owner.child_waiters.items.len != 0;
            self.owner.mutex.unlock(io_mod.getIo());
            if (registered) {
                self.observed_registration.store(true, .seq_cst);
                self.runner.release.store(true, .seq_cst);
                return;
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
    }
};

const ConcurrentInspectWait = struct {
    host: *Runtime,
    root_id: []const u8,
    child_id: []const u8,
    encoded: ?[]u8 = null,
    failure: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ConcurrentInspectWait) void {
        const alloc = std.heap.c_allocator;
        var inspect = domain.validateCommand(alloc, .{ .inspect = .{
            .id = self.child_id,
            .sections = &.{ .status, .messages },
            .wait = .{
                .until = .settled,
                .timeout_ms = domain.max_inspect_wait_ms,
            },
        } }) catch |err| {
            self.failure = err;
            self.completed.store(true, .seq_cst);
            return;
        };
        defer inspect.deinit(alloc);
        self.encoded = self.host.execute(
            alloc,
            &inspect,
            testOptions(self.root_id, "concurrent-inspect-wait"),
        ) catch |err| {
            self.failure = err;
            self.completed.store(true, .seq_cst);
            return;
        };
        self.completed.store(true, .seq_cst);
    }
};

fn waitForRegisteredChildWaiter(owner: *execution.Owner) !void {
    const deadline = io_mod.milliTimestamp() + 15_000;
    while (io_mod.milliTimestamp() < deadline) {
        owner.mutex.lockUncancelable(io_mod.getIo());
        const registered = owner.child_waiters.items.len != 0;
        owner.mutex.unlock(io_mod.getIo());
        if (registered) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestUnexpectedResult;
}
