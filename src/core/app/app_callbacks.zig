const std = @import("std");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const command_admission = @import("../permissions/command_admission.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const core_input_runtime = @import("../input/runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const change_tracker_mod = @import("../workspace/change_tracker.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("../tooling/file_mutation.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const gateway_error_format = @import("../shared/gateway_error_format.zig");
const io_mod = @import("../shared/io.zig");
const session_runtime = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_usage = @import("../session/session_usage.zig");
const parent_delivery_projector = @import("../subagent/parent_delivery_projector.zig");
const task_helpers = @import("../tasks/task_helpers.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const activity_runtime = @import("../output/activity_runtime.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const ui_render = @import("../../ui/render.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const WorkerEvent = worker_runtime.WorkerEvent;

const reset_style = ui_render.reset_style;

fn preparedDiffPayload(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !diff_mod.DiffEntryPayload {
    return preparedDiffPayloadWithFullAllocator(alloc, alloc, handoff);
}

fn preparedDiffPayloadWithFullAllocator(
    alloc: Allocator,
    full_alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !diff_mod.DiffEntryPayload {
    return diff_mod.formatFileChangePayload(
        alloc,
        full_alloc,
        handoff.preview,
        handoff.tracker.previous_content,
        if (handoff.full_view) |snapshot| .{
            .after_content = snapshot.after_content,
            .lifecycle_id = snapshot.lifecycle_id,
        } else null,
        .{
            .added_fg = ui_render.diff_added_style,
            .removed_fg = ui_render.diff_removed_style,
            .context_fg = ui_render.dim_style,
            .added_marker_fg = ui_render.diff_added_marker_style,
            .removed_marker_fg = ui_render.diff_removed_marker_style,
            .reset = ui_render.reset_style,
        },
    );
}





pub fn Bindings(comptime App: type) type {
    return struct {
        pub fn agentRuntimeDeps(app: *App) agent_runtime.AgentRuntimeDeps {
            var deps: agent_runtime.AgentRuntimeDeps = .{
                .ctx = @ptrCast(app),
                .agent_stream_provider = if (comptime @hasDecl(App, "agentStreamProvider"))
                    app.agentStreamProvider()
                else
                    agent_stream_provider.unavailable_provider,
                .cooperative_transport_pulse = if (comptime @hasDecl(App, "cooperativeTransportPulse")) .{
                    .ctx = @ptrCast(app),
                    .run = cooperativeTransportPulse,
                } else null,
                .tool_registry = if (comptime @hasDecl(App, "toolRegistry")) app.toolRegistry() else .{},
                .context_registry = if (comptime @hasDecl(App, "contextRegistry")) app.contextRegistry() else null,
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else false,
                .snapshot_root_permission_mode = if (comptime @hasField(App, "permission_engine"))
                    agentSnapshotRootPermissionMode
                else
                    null,
                .finalize_turn = agentFinalizeTurn,
                .take_steering = if (comptime @hasDecl(@TypeOf(app.worker), "takeSteering")) agentTakeSteering else null,
                .prepare_parent_turn_context = agentPrepareParentTurnContext,
                .acknowledge_parent_turn_context = agentAcknowledgeParentTurnContext,
                .append_runtime_context = agentAppendRuntimeContext,
                .append_static_context = agentAppendStaticContext,
                .validate_tool_call = agentValidateToolCall,
                .check_tool_availability = agentCheckToolAvailability,
                .request_tool_permission = agentRequestToolPermission,
                .request_prepared_file_mutation_permission = agentRequestPreparedFileMutationPermission,
                .resolve_tool_action_display_target = if (comptime @hasDecl(App, "resolveToolActionDisplayTarget"))
                    agentResolveToolActionDisplayTarget
                else
                    null,
                .describe_tool_action = agentDescribeToolAction,
                .describe_tool_action_completed = agentDescribeToolActionCompleted,
                .describe_tool_action_denied = agentDescribeToolActionDenied,
                .permission_target_for_call = agentPermissionTargetForCall,
                .execute_tool_call = agentExecuteToolCall,
                .publish_committed_file_handoff = agentPublishCommittedFileHandoff,
                .propagate_history_turn = agentPropagateHistoryTurn,
                .recovery_checkpoint = if (comptime @hasField(App, "session_persistence"))
                    if (app.session_persistence.writable != null)
                        .{
                            .set = agentSetRecoveryCheckpoint,
                        }
                    else
                        null
                else
                    null,
                .propagate_grant = agentPropagateGrant,
                .push_event = agentPushEvent,
                .push_text = agentPushText,
                .push_tool_lifecycle = agentPushToolLifecycle,
                .push_diff_block = agentPushDiffBlock,
                .push_system_notice = agentPushSystemNotice,
                .push_interactive_notice = agentPushInteractiveNotice,
                .push_context_notice = agentPushContextNotice,
                .push_route_recovery_status = agentPushRouteRecoveryStatus,
                .push_command_output_complete = agentPushCommandOutputComplete,
                .push_http_error = agentPushHttpError,
                .refresh_gateway_credential = if (comptime @hasField(App, "auth"))
                    refreshGatewayCredential
                else
                    null,
                .request_route_recovery = if (comptime @hasDecl(@TypeOf(app.worker), "requestRouteRecoveryAnswerBlocking"))
                    agentRequestRouteRecovery
                else
                    null,
                .available_model_capabilities = agentAvailableModelCapabilities,
                .resolve_model_capabilities = agentResolveModelCapabilities,
                .format_tool_execution_error = agentFormatToolExecutionError,
                .record_tool_call_rejected = agentRecordToolCallRejected,
                .report_usage = agentReportUsage,
                .report_inner_tool_usage = agentReportInnerToolUsage,
                .usage_allocator = app.alloc,
                .diff_marker_styles = .{
                    .added = ui_render.diff_added_marker_style,
                    .removed = ui_render.diff_removed_marker_style,
                },
            };
            if (comptime @hasField(@TypeOf(app.session), "usage")) {
                deps.usage = &app.session.usage;
                if (comptime @hasField(App, "session_persistence") and
                    @hasField(@TypeOf(app.session_persistence), "writable"))
                {
                    app.session.usage.configureCheckpointSink(
                        if (app.session_persistence.writable != null)
                            .{
                                .context = @ptrCast(app),
                                .allocator = app.alloc,
                                .persist = agentPersistUsageCheckpoint,
                            }
                        else
                            null,
                    );
                }
            }
            if (comptime @hasDecl(App, "releaseAgentTerminalLease")) {
                deps.release_agent_terminal_lease = agentReleaseTerminalLease;
            }
            return deps;
        }

        fn agentReleaseTerminalLease(ctx: *anyopaque, session_id: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.releaseAgentTerminalLease(session_id);
        }

        fn refreshGatewayCredential(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
            source: credentials.Source,
            mode: auth_runtime.CredentialRefreshMode,
            expected_account_id: ?[]const u8,
        ) !?[]u8 {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return auth_runtime.refreshCredentialTokenForAccount(
                app.auth.oauthTransport(),
                alloc,
                source,
                mode,
                expected_account_id,
            );
        }

        pub fn modelCapabilityResolver(app: *App) model_capabilities.Resolver {
            return .{
                .ctx = @ptrCast(app),
                .resolve_fn = agentResolveModelCapabilities,
            };
        }

        pub fn semanticPresentationSink(app: *App) agent_runtime.SemanticPresentationSink {
            return .{
                .ctx = @ptrCast(app),
                .table = agentPushTable,
                .code_block = agentPushCodeBlock,
                .thematic_rule = agentPushThematicRule,
            };
        }

        pub fn workerEventHandlers(app: *App) app_worker_runtime.WorkerEventHandlers {
            return .{
                .ctx = @ptrCast(app),
                .tool_lifecycle = worker_tool_lifecycle_presenter(app),
                .write_user_prompt = workerBridgeWriteUserPrompt,
                .write_user_prompt_with_skill_bindings = workerBridgeWriteUserPromptWithSkillBindings,
                .append_text = workerBridgeAppendText,
                .append_table = workerBridgeAppendTable,
                .append_code_block = workerBridgeAppendCodeBlock,
                .append_thematic_rule = workerBridgeAppendThematicRule,
                .drain_assistant_text = workerBridgeDrainAssistantText,
                .open_model_picker = workerBridgeOpenModelPicker,
                .semantic_notice = workerBridgeSemanticNotice,
                .command_output = workerBridgeCommandOutput,
                .command_output_complete = workerBridgeCommandOutputComplete,
                .diff_block = workerBridgeDiffBlock,
                .append_history_turn = workerBridgeAppendHistoryTurn,
                .session_grant = workerBridgeSessionGrant,
                .error_text = workerBridgeErrorText,
            };
        }

        pub fn worker_tool_lifecycle_presenter(
            app: *App,
        ) activity_runtime.LifecyclePresenter {
            return .{
                .ctx = @ptrCast(app),
                .snapshot_fn = worker_tool_lifecycle_snapshot,
                .record_fn = worker_tool_lifecycle_record,
                .apply_fn = worker_apply_tool_lifecycle,
                .finish_batch_fn = worker_finish_tool_lifecycle_batch,
            };
        }

        fn worker_tool_lifecycle_snapshot(
            raw_ctx: *anyopaque,
        ) activity_runtime.LifecycleSnapshot {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return .{
                .finalized_turn_watermark = app.shell.finalizedToolTurnWatermark(),
                .active_tool_count = app.shell.activeToolActivityCount(),
                .focused_entry_id = app.shell.focusedToolEntryId(),
                .focused_activity_kind = app.shell.focusedToolActivityKind(),
                .activity = app.shell.activityProjection(),
            };
        }

        fn worker_tool_lifecycle_record(
            raw_ctx: *anyopaque,
            id: types.ToolLifecycleId,
        ) ?activity_runtime.ToolPresentationRecord {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.shell.toolActivityRecord(id);
        }

        fn worker_apply_tool_lifecycle(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
            event: types.ToolLifecycleEvent,
        ) !activity_runtime.LifecycleTransition {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            const previous_focused_entry_id = app.shell.focusedToolEntryId();
            const preserve_normal_buffer_anchor = if (comptime @hasField(App, "terminal"))
                app.terminal.alternate_screen_owner != .none
            else
                false;
            const applied_activity_kind = if (preserve_normal_buffer_anchor)
                try app.shell.applyToolLifecyclePreservingNormalBufferAnchor(alloc, event)
            else
                try app.shell.applyToolLifecycle(alloc, event);
            return .{
                .previous_focused_entry_id = previous_focused_entry_id,
                .snapshot = worker_tool_lifecycle_snapshot(raw_ctx),
                .applied_activity_kind = applied_activity_kind,
                .terminal_record = switch (event) {
                    .terminal => |terminal| app.shell.toolActivityRecord(terminal.id),
                    .provisional, .authoritative_started, .progress, .turn_finished => null,
                },
            };
        }

        fn worker_finish_tool_lifecycle_batch(
            raw_ctx: *anyopaque,
            alloc: std.mem.Allocator,
        ) !void {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            try app.shell.finishLifecycleBatch(alloc);
        }

        pub fn onCommandOutputChunk(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, stream: command_output_content.Stream, chunk: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (app.worker.worker_cancel_requested.load(.seq_cst)) return;
            try app_worker_runtime.Runtime(App).pushCommandOutput(app, lifecycle_id, stream, chunk);
        }

        pub fn onMcpProgress(ctx: *anyopaque, lifecycle_id: types.ToolLifecycleId, text: []const u8) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var label_buf: [512]u8 = undefined;
            const label = std.fmt.bufPrint(
                &label_buf,
                "{s}● {s}{s}",
                .{ ui_render.bold_style, text, reset_style },
            ) catch ui_render.bold_style ++ "● MCP progress" ++ reset_style;
            app_worker_runtime.Runtime(App).pushToolLifecycle(app, .{ .progress = .{
                .id = lifecycle_id,
                .text = label,
            } }) catch |err| {
                debug_trace.logf("mcp", "failed to publish MCP tool progress err={s}", .{@errorName(err)});
                return;
            };
            debug_trace.logf("mcp", "queued MCP tool progress turn_id={d}", .{lifecycle_id.turn_id});
        }

        pub fn onWebSearchProgress(ctx: *anyopaque, call_id: []const u8, progress: types.WebSearchProgress) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            app_worker_runtime.Runtime(App).pushWebSearchProgress(app, call_id, progress) catch {};
        }

        pub fn onWebFetchProgress(ctx: *anyopaque, call_id: []const u8, progress: types.WebFetchProgress) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            app_worker_runtime.Runtime(App).pushWebFetchProgress(app, call_id, progress) catch {};
        }

        pub fn onInnerToolUsage(ctx: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void {
            agentReportInnerToolUsage(ctx, tool_name, usage);
        }

        pub fn onBackgroundUrlReady(ctx: *anyopaque, task_id: u64, url: []const u8) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const notice = task_helpers.backgroundServerReadyNotice(std.heap.c_allocator, task_id, url, app.session.languageSnapshot()) catch return;
            defer std.heap.c_allocator.free(notice.body);
            app_worker_runtime.Runtime(App).pushSemanticNotice(app, notice) catch {};
        }

        pub fn onTaskCompletion(ctx: *anyopaque, completion: task_helpers.TaskCompletion) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const notice = task_helpers.backgroundCompletionNotice(std.heap.c_allocator, completion, app.session.languageSnapshot()) catch return;
            defer std.heap.c_allocator.free(notice.body);
            app_worker_runtime.Runtime(App).pushSemanticNotice(app, notice) catch {};
        }

        fn agentAppendRuntimeContext(ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.appendRuntimeContextMessage(arena, messages);
        }

        fn cooperativeTransportPulse(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.cooperativeTransportPulse();
        }

        fn agentFinalizeTurn(ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, _: ?types.ProviderCompletionDisposition) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.worker.pushTurnFinished(std.heap.c_allocator, .{
                .turn_id = turn_id,
                .outcome = outcome,
            });
        }

        fn agentTakeSteering(ctx: *anyopaque, arena: std.mem.Allocator, turn_id: u64) ![]const []const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            const owned = try app.worker.takeSteering(std.heap.c_allocator, turn_id);
            if (owned.len == 0) return &.{};
            defer {
                for (owned) |text| std.heap.c_allocator.free(text);
                std.heap.c_allocator.free(owned);
            }
            const result = try arena.alloc([]const u8, owned.len);
            for (owned, result) |text, *dest| dest.* = try arena.dupe(u8, text);
            return result;
        }

        fn agentAppendStaticContext(ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "appendStaticContextMessage")) {
                try app.appendStaticContextMessage(arena, messages);
            }
        }

        fn agentPrepareParentTurnContext(
            ctx: *anyopaque,
            arena: Allocator,
        ) !?agent_runtime.PreparedParentTurnContext {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "session_persistence")) {
                const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return null;
                const session_id = app_session_runtime.Runtime(App).activeSessionId(app) orelse return null;
                return parent_delivery_projector.prepare(
                    arena,
                    host.sessions,
                    session_id,
                    host.manager.options.child_store,
                );
            }
            return null;
        }

        fn agentAcknowledgeParentTurnContext(
            ctx: *anyopaque,
            arena: Allocator,
            acknowledgements: []const agent_runtime.ParentTurnDeliveryAck,
        ) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "session_persistence")) {
                const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return;
                const retirement_ready = parent_delivery_projector
                    .acknowledgeWithRetirementSignal(
                    arena,
                    host.sessions,
                    host.manager.options.child_store,
                    acknowledgements,
                );
                if (retirement_ready) {
                    host.requestRetirementSweep(io_mod.milliTimestamp());
                }
            }
        }

        fn agentResolveModelCapabilities(ctx: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "resolveModelCapabilitiesForRequest")) {
                return app.resolveModelCapabilitiesForRequest(model);
            }
            if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
                return app.resolvedModelCapabilities(model);
            }
            if (comptime @hasDecl(App, "providerSet")) {
                return app.providerSet().select(provider_runtime.provider(app)).fallbackModelCapabilities(model);
            }
            return model_capabilities.capabilitiesForModel(model);
        }

        fn agentAvailableModelCapabilities(ctx: *anyopaque, model: []const u8) model_capabilities.Capabilities {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
                return app.resolvedModelCapabilities(model);
            }
            if (comptime @hasDecl(App, "providerSet")) {
                return app.providerSet().select(provider_runtime.provider(app)).fallbackModelCapabilities(model);
            }
            return model_capabilities.capabilitiesForModel(model);
        }

        fn agentRequestToolPermission(ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.requestToolPermissionSyncWithAdvertised(arena, call, review_turn, permission_mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names);
        }

        fn agentSnapshotRootPermissionMode(ctx: *anyopaque) PermissionMode {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app_permission_runtime.Runtime(App).livePermissionSnapshot(app).mode;
        }

        fn agentRequestPreparedFileMutationPermission(ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.requestPreparedFileMutationPermissionSyncWithAdvertised(arena, call, prepared, review_turn, permission_mode, local_grants, live_authority, advertised_dynamic_tool_names);
        }

        fn agentValidateToolCall(ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.validateToolCall(arena, call);
        }

        fn agentCheckToolAvailability(ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.checkToolAvailability(arena, call);
        }

        fn agentResolveToolActionDisplayTarget(ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.resolveToolActionDisplayTarget(arena, call);
        }

        fn agentDescribeToolAction(ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.describeToolActionWithAdvertised(arena, call, display_target, advertised_dynamic_tool_names);
        }

        fn agentDescribeToolActionCompleted(ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.describeToolActionCompletedWithAdvertised(arena, call, display_target, advertised_dynamic_tool_names);
        }

        fn agentDescribeToolActionDenied(ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.describeToolActionDeniedWithAdvertised(arena, call, display_target, label, advertised_dynamic_tool_names);
        }

        fn agentPermissionTargetForCall(ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.permissionTargetForCallWithAdvertised(arena, call, advertised_dynamic_tool_names);
        }

        fn agentExecuteToolCall(
            ctx: *anyopaque,
            request: agent_runtime.ToolExecutionRequest,
        ) !ToolExecutionResult {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.executeToolCallWithAdvertised(request);
        }

        fn agentRecordToolCallRejected(
            ctx: *anyopaque,
            _: Allocator,
            call: ToolCall,
            model_output: []const u8,
            _: ?[]const u8,
        ) !void {
            _ = ctx;
            diagnostics.recordToolCallResult(.{
                .name = call.name,
                .arguments_json = call.arguments_json,
                .model_output = model_output,
                .ok = false,
                .started_at_ms = io_mod.milliTimestamp(),
            });
        }

        fn agentPublishCommittedFileHandoff(
            ctx: *anyopaque,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondaryPublicationReport {
            const app: *App = @ptrCast(@alignCast(ctx));
            return .{
                .diff = publishCommittedDiff(app, handoff),
                .tracker = publishCommittedTracker(app, handoff),
            };
        }

        fn publishCommittedDiff(
            app: *App,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondarySinkOutcome {
            const payload = preparedDiffPayload(
                std.heap.c_allocator,
                handoff,
            ) catch |err| {
                debug_trace.logf(
                    "tool",
                    "committed file diff projection failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            app_worker_runtime.Runtime(App).pushDiffBlock(app, payload) catch |err| {
                diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
                debug_trace.logf(
                    "tool",
                    "committed file diff publication failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            return .published;
        }

        fn publishCommittedTracker(
            app: *App,
            handoff: file_mutation.CommittedFileHandoff,
        ) agent_runtime.SecondarySinkOutcome {
            if (comptime !@hasField(App, "change_tracker")) return .skipped;

            const path = app.alloc.dupe(u8, handoff.tracker.raw_path) catch |err| {
                debug_trace.logf(
                    "tool",
                    "committed file tracker path clone failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            const previous_content = if (handoff.tracker.previous_content) |content|
                app.alloc.dupe(u8, content) catch |err| {
                    app.alloc.free(path);
                    debug_trace.logf(
                        "tool",
                        "committed file tracker preimage clone failed err={s}",
                        .{@errorName(err)},
                    );
                    return .failed;
                }
            else
                null;
            app.change_tracker.pushOperation(app.alloc, .{
                .kind = switch (handoff.tracker.kind) {
                    .write => change_tracker_mod.OperationKind.write,
                    .edit => change_tracker_mod.OperationKind.edit,
                },
                .path = path,
                .previous_content = previous_content,
                .timestamp_ms = handoff.tracker.committed_at_ms,
            }) catch |err| {
                app.alloc.free(path);
                if (previous_content) |content| app.alloc.free(content);
                debug_trace.logf(
                    "tool",
                    "committed file tracker publication failed err={s}",
                    .{@errorName(err)},
                );
                return .failed;
            };
            return .published;
        }

        fn agentPropagateHistoryTurn(ctx: *anyopaque, turn: HistoryTurn) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).propagateHistoryTurn(app, turn, app.session.max_history_turns);
        }

        fn agentSetRecoveryCheckpoint(
            ctx: *anyopaque,
            checkpoint: session_codec.RecoveryCheckpoint,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).setRecoveryCheckpoint(app, checkpoint);
        }

        fn agentPersistUsageCheckpoint(
            ctx: *anyopaque,
            snapshot: session_usage.Snapshot,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_session_runtime.Runtime(App).persistUsageCheckpoint(app, snapshot);
        }

        fn agentPropagateGrant(ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).propagateGrant(app, tool_name, target_path);
        }

        fn agentPushEvent(ctx: *anyopaque, event: WorkerEvent) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var owned_event = event;
            if (event == .finish_prompt and
                comptime @hasDecl(@TypeOf(app.worker), "handoffActivePromptSnapshots"))
            {
                var finished = event.finish_prompt;
                finished.snapshot_file_ownership =
                    try app.worker.handoffActivePromptSnapshots(std.heap.c_allocator);
                owned_event = .{ .finish_prompt = finished };
            }
            defer worker_runtime.freeWorkerEvent(std.heap.c_allocator, owned_event);
            try app_worker_runtime.Runtime(App).pushEvent(app, owned_event);
        }

        fn agentPushText(ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            switch (emission) {
                .assistant_source => {},
                .assistant_rendered => |text| try app_worker_runtime.Runtime(App).pushText(app, text),
                .operational => |text| try app_worker_runtime.Runtime(App).pushText(app, text),
            }
        }

        fn agentPushTable(ctx: *anyopaque, table: assistant_presentation.TablePayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushTable(app, table);
            var owned = table;
            owned.deinit(std.heap.c_allocator);
        }

        fn agentPushCodeBlock(ctx: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushCodeBlock(app, block);
            var owned = block;
            owned.deinit(std.heap.c_allocator);
        }

        fn agentPushThematicRule(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushThematicRule(app);
        }

        fn agentPushToolLifecycle(
            ctx: *anyopaque,
            event: types.ToolLifecycleEvent,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushToolLifecycle(app, event);
        }

        fn agentPushDiffBlock(ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            errdefer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
            try app_worker_runtime.Runtime(App).pushDiffBlock(app, payload);
        }

        fn agentPushSystemNotice(ctx: *anyopaque, text: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                .topic = "system",
                .tone = .neutral,
                .body = text,
            });
        }

        fn agentPushInteractiveNotice(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, notice);
        }

        fn agentPushContextNotice(ctx: *anyopaque, text: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice")) {
                if (!try app.session.claimContextNotice(std.heap.c_allocator, text)) return;
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, text);
            defer std.heap.c_allocator.free(body);
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                .topic = "context",
                .tone = .warning,
                .body = body,
                .visibility = .full_only,
            });
        }

        fn agentPushRouteRecoveryStatus(ctx: *anyopaque, status: types.RouteRecoveryStatus) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushEvent(app, .{ .route_recovery_status = status });
        }

        fn agentPushCommandOutputComplete(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app_worker_runtime.Runtime(App).pushCommandOutputComplete(app, lifecycle_id);
        }

        fn agentPushHttpError(ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
            const message = if (auth_failure) |failure|
                try failure.renderText(std.heap.c_allocator)
            else
                try gateway_error_format.formatHttpErrorMessage(std.heap.c_allocator, status, detail);
            defer std.heap.c_allocator.free(message);
            const label = if (auth_failure != null)
                try std.fmt.allocPrint(
                    std.heap.c_allocator,
                    "⚠ {s} · Run /setup to choose another source.",
                    .{message},
                )
            else
                try std.fmt.allocPrint(std.heap.c_allocator, "⚠ {s}", .{message});
            defer std.heap.c_allocator.free(label);
            try app_worker_runtime.Runtime(App).pushEvent(app, .{ .api_status_text = label });
        }

        fn agentRequestRouteRecovery(ctx: *anyopaque, arena: Allocator, request: agent_runtime.RouteRecoveryRequest) !agent_runtime.RouteRecoveryDecision {
            const app: *App = @ptrCast(@alignCast(ctx));
            const question = switch (request.finish_reason) {
                .content_filter => "Response blocked by content filter. What should fx do?",
                else => if (request.replay_safe)
                    try std.fmt.allocPrint(
                        arena,
                        "Route failed after {d} attempt{s} for {s}. What should fx do?",
                        .{
                            request.semantic_attempts,
                            if (request.semantic_attempts == 1) "" else "s",
                            request.route_model,
                        },
                    )
                else switch (request.unsafe_no_retry_reason orelse .assistant_output) {
                    .assistant_output => "Route failed after assistant output started. What should fx do?",
                    .tool_start => "Route failed after tool use started. What should fx do?",
                },
            };
            var options_buf: [3]types.QuestionOption = undefined;
            var option_count: usize = 0;
            if (request.finish_reason == .provider_error and request.replay_safe and request.fast_mode) {
                options_buf[option_count] = .{
                    .label = "Disable Fast",
                    .description = "Retry the selected model without Fast.",
                };
                option_count += 1;
            }
            options_buf[option_count] = .{
                .label = "Change model",
                .description = "Open the model picker and leave this prompt stopped.",
            };
            option_count += 1;
            options_buf[option_count] = .{
                .label = "Try again later",
                .description = "Stop this prompt and try again later.",
            };
            option_count += 1;

            const entry = types.QuestionBatchEntry{
                .question = question,
                .options = options_buf[0..option_count],
            };
            const answers = try app.worker.requestRouteRecoveryAnswerBlocking(std.heap.c_allocator, &.{entry});
            defer if (answers) |owned| {
                for (owned) |label| std.heap.c_allocator.free(label);
                std.heap.c_allocator.free(owned);
            };
            const label = if (answers) |owned|
                if (owned.len > 0) owned[0] else "Try again later"
            else
                "Try again later";
            if (std.mem.eql(u8, label, "Disable Fast")) return .disable_fast;
            if (std.mem.eql(u8, label, "Change model") or std.mem.eql(u8, label, "Switch model")) {
                try app_worker_runtime.Runtime(App).pushEvent(app, .open_model_picker);
                return .switch_model;
            }
            return .cancel;
        }

        fn agentFormatToolExecutionError(ctx: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            return app.formatToolExecutionErrorForAgent(arena, tool_name, err);
        }

        fn agentReportUsage(ctx: *anyopaque, usage: types.Usage) void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (usage.input_tokens) |input| app.total_input_tokens = input;
            if (usage.output_tokens) |output| app.total_output_tokens = output;
        }

        fn agentReportInnerToolUsage(ctx: *anyopaque, tool_name: []const u8, usage: types.ToolUsage) void {
            if (!std.mem.eql(u8, tool_name, "web_search")) return;
            const app: *App = @ptrCast(@alignCast(ctx));
            app.total_web_search_requests +|= @as(u64, usage.web_search_requests);
        }

        fn workerBridgeWriteUserPrompt(ctx: *anyopaque, prompt: types.UserTurn) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeUserPromptCard(prompt);
        }

        fn workerBridgeWriteUserPromptWithSkillBindings(
            ctx: *anyopaque,
            prompt: types.UserTurn,
            skill_bindings: []const worker_runtime.SkillBinding,
            skill_display_spans: []const worker_runtime.SkillDisplaySpan,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "writeUserPromptCardWithSkillBindings")) {
                try app.writeUserPromptCardWithSkillBindings(prompt, skill_bindings, skill_display_spans);
            } else {
                try app.writeUserPromptCard(prompt);
            }
        }

        fn workerBridgeAppendText(ctx: *anyopaque, text: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.pacer.enqueue(app.alloc, text);
        }

        fn workerBridgeAppendTable(ctx: *anyopaque, table: assistant_presentation.TablePayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var owned = table;
            var handed_off = false;
            errdefer if (!handed_off) owned.deinit(app.alloc);
            if (comptime @hasDecl(App, "appendAssistantTable")) {
                try app.appendAssistantTable(owned);
                handed_off = true;
                return;
            }
            owned.deinit(app.alloc);
            handed_off = true;
        }

        fn workerBridgeAppendCodeBlock(ctx: *anyopaque, block: assistant_presentation.CodeBlockPayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var owned = block;
            var handed_off = false;
            errdefer if (!handed_off) owned.deinit(app.alloc);
            if (comptime @hasDecl(App, "appendAssistantCodeBlock")) {
                try app.appendAssistantCodeBlock(owned);
                handed_off = true;
                return;
            }
            owned.deinit(app.alloc);
            handed_off = true;
        }

        fn workerBridgeAppendThematicRule(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "appendAssistantThematicRule")) {
                try app.appendAssistantThematicRule();
            }
        }

        fn workerBridgeDrainAssistantText(ctx: *anyopaque) !app_worker_runtime.AssistantTextDrainResult {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.pacer.flushPresentationAtBoundary(
                app.alloc,
                io_mod.nanoTimestamp(),
                app.pacerCallbacks(),
            );
            return .drained;
        }

        fn workerBridgeOpenModelPicker(ctx: *anyopaque) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasField(App, "input_runtime") and
                provider_runtime.supported(App) and
                @hasDecl(App, "modelCompletions"))
            {
                try input_completion_runtime.CompletionRuntime(App).openCurrentModelPicker(app);
            }
        }

        fn workerBridgeSemanticNotice(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(notice, true);
        }

        fn workerBridgeCommandOutput(
            ctx: *anyopaque,
            lifecycle_id: ?types.ToolLifecycleId,
            stream: command_output_content.Stream,
            text: []const u8,
        ) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "writeCommandOutputChunkForLifecycle")) {
                try app.writeCommandOutputChunkForLifecycle(lifecycle_id, stream, text, true);
                return;
            }
            try app.writeCommandOutputChunk(stream, text, true);
        }

        fn workerBridgeCommandOutputComplete(ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (comptime @hasDecl(App, "flushCommandOutputSummaryForLifecycle")) {
                try app.flushCommandOutputSummaryForLifecycle(lifecycle_id, true);
                return;
            }
            try app.flushCommandOutputSummary(true);
        }

        fn workerBridgeDiffBlock(ctx: *anyopaque, payload: diff_mod.DiffEntryPayload) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.registerAndEmitDiffBlock(payload);
        }

        fn workerBridgeAppendHistoryTurn(ctx: *anyopaque, finished: types.FinishedPrompt) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (try app.pacer.deferFinish(app.alloc, finished)) return;
            try appendHistoryTurn(app, finished);
        }

        fn workerBridgeSessionGrant(ctx: *anyopaque, grant: types.PermissionGrant) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.allowToolForSession(grant.tool_name, grant.target_path);
        }

        fn workerBridgeErrorText(ctx: *anyopaque, notice: types.SemanticNotice) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(notice, true);
        }

        fn appendHistoryTurn(app: *App, finished: types.FinishedPrompt) !void {
            if (comptime @hasDecl(App, "appendFinishedPrompt")) {
                try app.appendFinishedPrompt(finished);
                return;
            }
            if (comptime @hasDecl(App, "appendHistoryTurn")) {
                try app.appendHistoryTurn(finished.turn);
                if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
                return;
            }
            try app_session_runtime.Runtime(App).appendFinishedPrompt(app, finished);
        }
    };
}

const FakeWorker = struct {
    worker_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    events: std.ArrayList(WorkerEvent) = .empty,
    propagated_history_turns: usize = 0,
    propagated_grants: usize = 0,
    active_snapshot_transfers: usize = 0,
    active_turn_id: u64 = 1,
    fail_diff_push: bool = false,
    fail_semantic_push: bool = false,
    fail_command_output_push: bool = false,

    fn deinit(self: *FakeWorker) void {
        for (self.events.items) |event| worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
        self.events.deinit(std.heap.c_allocator);
    }

    pub fn pushEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        const owned = try worker_runtime.dupeWorkerEvent(alloc, event);
        errdefer worker_runtime.freeWorkerEvent(alloc, owned);
        try self.pushOwnedEvent(alloc, owned);
    }

    pub fn pushOwnedEvent(self: *FakeWorker, alloc: std.mem.Allocator, event: WorkerEvent) !void {
        if (self.fail_diff_push) {
            switch (event) {
                .diff_block => return error.TestDiffPublicationFailure,
                else => {},
            }
        }
        if (self.fail_semantic_push) {
            switch (event) {
                .assistant_presentation => |presentation| switch (presentation) {
                    .table, .code_block => return error.TestSemanticPresentationPublicationFailure,
                    .text, .thematic_rule => {},
                },
                else => {},
            }
        }
        if (self.fail_command_output_push) {
            switch (event) {
                .command_output => return error.OutOfMemory,
                else => {},
            }
        }
        try self.events.append(alloc, event);
    }

    pub fn pushTurnFinished(self: *FakeWorker, alloc: std.mem.Allocator, event: types.TurnFinished) !void {
        try self.events.append(alloc, .{ .tool_lifecycle = .{
            .turn_finished = event,
        } });
    }

    pub fn propagateHistoryTurn(self: *FakeWorker, alloc: std.mem.Allocator, turn: HistoryTurn, max_history_turns: usize) !void {
        _ = alloc;
        _ = turn;
        _ = max_history_turns;
        self.propagated_history_turns += 1;
    }

    pub fn propagateGrant(self: *FakeWorker, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        _ = alloc;
        _ = tool_name;
        _ = target_path;
        self.propagated_grants += 1;
    }

    pub fn transferActivePromptSnapshots(self: *FakeWorker) void {
        self.active_snapshot_transfers += 1;
    }

    pub fn activeTurnId(self: *FakeWorker) u64 {
        return self.active_turn_id;
    }
};

const FakeSession = struct {
    max_history_turns: usize = 8,
    history_appends: usize = 0,

    fn languageSnapshot(self: *FakeSession) types.ConversationLanguage {
        _ = self;
        return types.ConversationLanguage.default();
    }

    pub fn appendHistoryEntry(self: *FakeSession, alloc: std.mem.Allocator, turn: types.HistoryTurn) !void {
        _ = alloc;
        _ = turn;
        self.history_appends += 1;
    }
};

const FakePacer = struct {
    text: std.ArrayList(u8) = .empty,
    defer_history: bool = false,
    enqueue_count: usize = 0,
    flush_count: usize = 0,

    fn deinit(self: *FakePacer, alloc: std.mem.Allocator) void {
        self.text.deinit(alloc);
    }

    fn enqueue(self: *FakePacer, alloc: std.mem.Allocator, text: []const u8) !void {
        self.enqueue_count += 1;
        try self.text.appendSlice(alloc, text);
    }

    fn deferFinish(self: *FakePacer, alloc: std.mem.Allocator, finished: types.FinishedPrompt) !bool {
        _ = alloc;
        _ = finished;
        return self.defer_history;
    }

    pub fn flushPresentationAtBoundary(
        self: *FakePacer,
        alloc: std.mem.Allocator,
        now_ns: i128,
        callbacks: anytype,
    ) !void {
        _ = alloc;
        _ = now_ns;
        _ = callbacks;
        self.flush_count += 1;
        self.text.clearRetainingCapacity();
    }
};

const FakeShell = struct {
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    render_requests: render_request.RenderRequestState = .{},
    lifecycle: transcript_runtime.TranscriptRuntime = .{},
    preserved_anchor_apply_count: usize = 0,

    pub fn replaceableEntryId(self: *FakeShell) ?u32 {
        _ = self;
        return null;
    }

    pub fn setRawEntryClass(self: *FakeShell, entry_id: u32, class: transcript_runtime.RawEntryClass) bool {
        _ = entry_id;
        self.last_class = class;
        return true;
    }

    pub fn applyToolLifecycle(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        return self.lifecycle.applyToolLifecycle(alloc, event);
    }

    pub fn applyToolLifecyclePreservingNormalBufferAnchor(
        self: *FakeShell,
        alloc: std.mem.Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        self.preserved_anchor_apply_count += 1;
        return self.lifecycle.applyToolLifecyclePreservingNormalBufferAnchor(alloc, event);
    }

    pub fn finishLifecycleBatch(
        self: *FakeShell,
        alloc: std.mem.Allocator,
    ) !void {
        return self.lifecycle.finishLifecycleBatch(alloc);
    }

    pub fn activityProjection(
        self: *const FakeShell,
    ) activity_runtime.ActivityProjection {
        return self.lifecycle.activityProjection();
    }

    pub fn focusedToolEntryId(self: *const FakeShell) ?u32 {
        return self.lifecycle.focusedToolEntryId();
    }

    pub fn focusedToolActivityKind(
        self: *const FakeShell,
    ) ?types.ToolActivityKind {
        return self.lifecycle.focusedToolActivityKind();
    }

    pub fn activeToolActivityCount(self: *const FakeShell) usize {
        return self.lifecycle.activeToolActivityCount();
    }

    pub fn toolActivityRecord(
        self: *const FakeShell,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        return self.lifecycle.toolActivityRecord(id);
    }

    pub fn finalizedToolTurnWatermark(self: *const FakeShell) u64 {
        return self.lifecycle.finalizedToolTurnWatermark();
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    worker: FakeWorker = .{},
    session: FakeSession = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    model_completion_values: []const []const u8 = &.{},
    change_tracker: change_tracker_mod.ChangeTracker = .{},
    shell: FakeShell = .{},
    terminal: struct {
        alternate_screen_owner: enum { none, active } = .none,
    } = .{},
    pacer: FakePacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,
    user_prompt_count: usize = 0,
    command_output_count: usize = 0,
    command_output_complete_count: usize = 0,
    last_command_output_lifecycle_turn_id: ?u64 = null,
    last_command_output_lifecycle_call_id: []const u8 = "",
    last_command_output_complete_lifecycle_turn_id: ?u64 = null,
    last_command_output_complete_lifecycle_call_id: []const u8 = "",
    history_append_count: usize = 0,
    summary_append_count: usize = 0,
    last_summary: ?types.TurnSummary = null,
    grant_count: usize = 0,
    diff_register_count: usize = 0,
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    last_notice_topic: std.ArrayList(u8) = .empty,
    last_notice_tone: types.NoticeTone = .information,
    last_notice_visibility: types.NoticeVisibility = .compact_and_full,
    last_notice_record: bool = false,
    capability_request_count: usize = 0,

    fn init(alloc: std.mem.Allocator) FakeApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *FakeApp) void {
        self.worker.deinit();
        self.input_runtime.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.change_tracker.deinit(self.alloc);
        self.shell.lifecycle.deinit(self.alloc);
        self.pacer.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.last_notice_topic.deinit(self.alloc);
    }

    pub fn modelCompletions(self: *FakeApp, _: []const u8, out: *[32][]const u8) usize {
        const count = @min(self.model_completion_values.len, out.len);
        for (self.model_completion_values[0..count], 0..) |value, index| {
            out[index] = value;
        }
        return count;
    }

    pub fn resolveModelCapabilitiesForRequest(
        self: *FakeApp,
        model: []const u8,
    ) !model_capabilities.Capabilities {
        self.capability_request_count += 1;
        const efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};
        return model_capabilities.resolveCapabilities(
            model,
            .{ .reasoning_efforts = .fromSlice(&efforts) },
        );
    }

    fn storeLifecycleId(
        turn_id: *?u64,
        call_id: *[]const u8,
        lifecycle_id: ?types.ToolLifecycleId,
    ) void {
        if (lifecycle_id) |id| {
            turn_id.* = id.turn_id;
            call_id.* = id.call_id;
        } else {
            turn_id.* = null;
            call_id.* = "";
        }
    }

    fn appendRuntimeContextMessage(self: *FakeApp, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        _ = self;
        try messages.append(arena, .{ .role = .system, .content = "runtime" });
    }

    fn requestToolPermissionSyncWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, _: ?agent_runtime.LiveToolAuthority, _: ?agent_runtime.LivePermissionRevalidation, _: []const []const u8) !command_admission.PermissionOutcome {
        _ = self;
        _ = arena;
        _ = call;
        _ = review_turn;
        _ = permission_mode;
        _ = local_grants;
        return .{
            .decision = .once,
            .execution_authority = .ordinary,
        };
    }

    fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, _: ?agent_runtime.LiveToolAuthority, _: []const []const u8) !command_admission.PermissionOutcome {
        _ = self;
        _ = call;
        _ = review_turn;
        _ = permission_mode;
        _ = local_grants;
        prepared.deinit(arena);
        return .{
            .decision = .once,
            .execution_authority = .ordinary,
        };
    }

    fn validateToolCall(self: *FakeApp, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        _ = self;
        return .{ .failure = try std.fmt.allocPrint(arena, "invalid {s}", .{call.name}) };
    }

    fn checkToolAvailability(self: *FakeApp, _: Allocator, _: ToolCall) !?[]const u8 {
        _ = self;
        return null;
    }

    fn describeToolActionWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "run {s}", .{call.name});
    }

    fn describeToolActionCompletedWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "done {s}", .{call.name});
    }

    fn describeToolActionDeniedWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "denied {s} {s}", .{ call.name, label });
    }

    fn permissionTargetForCallWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, _: []const []const u8) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "target:{s}", .{call.id});
    }

    fn executeToolCallWithAdvertised(
        self: *FakeApp,
        request: agent_runtime.ToolExecutionRequest,
    ) !ToolExecutionResult {
        _ = self;
        _ = request;
        return .{ .model_output = "tool output" };
    }

    fn registerAndEmitDiffBlock(self: *FakeApp, payload: agent_runtime.DiffEntryPayload) !void {
        defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
        self.diff_register_count += 1;
        try self.transcript.appendSlice(self.alloc, payload.preview);
    }

    fn formatToolExecutionErrorForAgent(self: *FakeApp, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "{s}:{s}", .{ tool_name, @errorName(err) });
    }

    fn writeUserPromptCard(self: *FakeApp, prompt: types.UserTurn) !void {
        _ = prompt;
        self.user_prompt_count += 1;
    }

    pub fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, record: bool) !void {
        self.last_notice_topic.clearRetainingCapacity();
        try self.last_notice_topic.appendSlice(self.alloc, notice.topic);
        self.last_notice_tone = notice.tone;
        self.last_notice_visibility = notice.visibility;
        self.last_notice_record = record;
        try self.transcript.appendSlice(self.alloc, notice.body);
    }

    fn pacerCallbacks(self: *FakeApp) void {
        _ = self;
    }

    fn writeCommandOutputChunk(self: *FakeApp, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        _ = stream;
        _ = text;
        _ = record;
        self.command_output_count += 1;
    }

    fn writeCommandOutputChunkForLifecycle(self: *FakeApp, lifecycle_id: ?types.ToolLifecycleId, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        storeLifecycleId(
            &self.last_command_output_lifecycle_turn_id,
            &self.last_command_output_lifecycle_call_id,
            lifecycle_id,
        );
        try self.writeCommandOutputChunk(stream, text, record);
    }

    fn flushCommandOutputSummary(self: *FakeApp, record: bool) !void {
        try self.flushCommandOutputSummaryForLifecycle(null, record);
    }

    fn flushCommandOutputSummaryForLifecycle(self: *FakeApp, lifecycle_id: ?types.ToolLifecycleId, record: bool) !void {
        _ = record;
        storeLifecycleId(
            &self.last_command_output_complete_lifecycle_turn_id,
            &self.last_command_output_complete_lifecycle_call_id,
            lifecycle_id,
        );
        self.command_output_complete_count += 1;
    }

    pub fn appendHistoryTurn(self: *FakeApp, turn: types.HistoryTurn) !void {
        _ = turn;
        self.history_append_count += 1;
    }

    pub fn appendFinishedPrompt(self: *FakeApp, finished: types.FinishedPrompt) !void {
        _ = finished.turn;
        self.history_append_count += 1;
        if (finished.snapshot_file_ownership) |ownership| ownership.transfer();
        if (finished.summary) |summary| {
            self.summary_append_count += 1;
            self.last_summary = summary;
        }
    }

    fn allowToolForSession(self: *FakeApp, tool_name: []const u8, target_path: []const u8) !void {
        _ = tool_name;
        _ = target_path;
        self.grant_count += 1;
    }

    pub fn writeTranscript(self: *FakeApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    pub fn writeTranscriptClassified(self: *FakeApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(text, record);
    }

    pub fn appendReplaceableTranscriptLine(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLine(text);
    }

    pub fn appendReplaceableTranscriptLineSilent(self: *FakeApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    pub fn appendReplaceableTranscriptLineSilentClassified(self: *FakeApp, text: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_class = class;
        return self.appendReplaceableTranscriptLineSilent(text);
    }

    pub fn replaceTrailingTranscriptLine(self: *FakeApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    pub fn replaceTrailingTranscriptLineSilent(self: *FakeApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }
};

const NoOverridePersistentApp = struct {
    alloc: Allocator,
    shell: FakeShell = .{},
    pacer: FakePacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,
    replaceable_count: usize = 0,
    replaceable_silent_count: usize = 0,
    replace_count: usize = 0,
    replace_silent_count: usize = 0,
    session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
    fn deinit(self: *NoOverridePersistentApp) void {
        self.shell.lifecycle.deinit(self.alloc);
        self.pacer.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.session.deinit(self.alloc);
        self.* = undefined;
    }

    fn writeUserPromptCard(self: *NoOverridePersistentApp, prompt: types.UserTurn) !void {
        _ = self;
        _ = prompt;
    }

    fn writeDomainNotice(self: *NoOverridePersistentApp, notice: types.SemanticNotice, record: bool) !void {
        _ = self;
        _ = notice;
        _ = record;
    }

    fn pacerCallbacks(self: *NoOverridePersistentApp) void {
        _ = self;
    }

    fn writeCommandOutputChunk(self: *NoOverridePersistentApp, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        _ = self;
        _ = stream;
        _ = text;
        _ = record;
    }

    fn flushCommandOutputSummary(self: *NoOverridePersistentApp, record: bool) !void {
        _ = self;
        _ = record;
    }

    fn allowToolForSession(self: *NoOverridePersistentApp, tool_name: []const u8, target_path: []const u8) !void {
        _ = self;
        _ = tool_name;
        _ = target_path;
    }

    fn writeTranscript(self: *NoOverridePersistentApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
    }

    fn writeTranscriptClassified(self: *NoOverridePersistentApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        _ = class;
        try self.writeTranscript(text, record);
    }

    fn registerAndEmitDiffBlock(self: *NoOverridePersistentApp, payload: agent_runtime.DiffEntryPayload) !void {
        _ = self;
        diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    }

    fn appendReplaceableTranscriptLine(self: *NoOverridePersistentApp, text: []const u8) !u32 {
        self.replaceable_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_count);
    }

    fn appendReplaceableTranscriptLineSilent(self: *NoOverridePersistentApp, text: []const u8) !u32 {
        self.replaceable_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return @intCast(self.replaceable_silent_count);
    }

    fn replaceTrailingTranscriptLine(self: *NoOverridePersistentApp, text: []const u8) !bool {
        self.replace_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }

    fn replaceTrailingTranscriptLineSilent(self: *NoOverridePersistentApp, text: []const u8) !bool {
        self.replace_silent_count += 1;
        try self.transcript.appendSlice(self.alloc, text);
        return false;
    }
};








const committed_preview_lines = [_]diff_mod.PreviewLine{
    .{
        .op = .deletion,
        .old_line = 1,
        .text = "before",
    },
    .{
        .op = .addition,
        .new_line = 1,
        .text = "after",
    },
};

fn testCommittedFileHandoff() file_mutation.CommittedFileHandoff {
    return file_mutation.CommittedFileHandoff.init(
        .{
            .path = "tracked.txt",
            .lines = &committed_preview_lines,
            .additions = 1,
            .deletions = 1,
            .truncated = false,
        },
        .{
            .kind = .edit,
            .raw_path = "/tmp/workspace/tracked.txt",
            .previous_content = "before\n",
            .committed_at_ms = 42,
        },
    );
}












