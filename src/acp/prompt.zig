const std = @import("std");
const std_builtin = @import("builtin");
const command_admission = @import("../core/permissions/command_admission.zig");
const auth_runtime = @import("../core/auth/auth_runtime.zig");
const credentials = @import("../core/auth/credentials.zig");
const model_provider = @import("../core/config/model_provider.zig");
const host = @import("../core/hosts/host.zig");
const host_target = @import("../core/hosts/target.zig");
const io_mod = @import("../core/shared/io.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const server = @import("server.zig");
const sessions = @import("sessions.zig");
const agent_runtime = @import("../core/agent/agent_runtime.zig");
const diff_mod = @import("../core/output/diff.zig");
const file_mutation = @import("../core/tooling/file_mutation.zig");
const file_mutation_contract = @import("../core/tooling/file_mutation_contract.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const mcp_model_catalog = @import("../core/mcp/model_catalog.zig");
const mcp_elicitation = @import("../core/mcp/elicitation.zig");
const mrtr = @import("../core/mcp/mrtr.zig");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const auto_classifier_context = @import("../core/permissions/auto_classifier_context.zig");
const permission_gate = @import("../core/permissions/permission_gate.zig");
const permission_request = @import("../core/permissions/permission_request.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_log = @import("../core/session/session_log.zig");
const session_store = @import("../core/session/session_store.zig");
const session_runtime = @import("../core/session/session.zig");
const session_usage = @import("../core/session/session_usage.zig");
const subagent_agent_adapter = @import("../core/subagent/agent_adapter.zig");
const subagent_domain = @import("../core/subagent/domain.zig");
const subagent_execution = @import("../core/subagent/execution.zig");
const subagent_resume_admission = @import("../core/subagent/resume_admission.zig");
const parent_delivery_projector = @import("../core/subagent/parent_delivery_projector.zig");
const usage_recovery = @import("../core/session/usage_recovery.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const skill_invocation = @import("../core/skills/skill_invocation.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const display_width = @import("../core/shared/display_width.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const tool_projection_mod = @import("../core/tooling/tool_projection.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_admission = @import("../core/tooling/tool_admission.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_specs = @import("../core/tooling/tool_specs.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const tool_mcp_runtime = @import("../core/tooling/tool_mcp_runtime.zig");
const tool_presentation = @import("../core/tooling/tool_presentation.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const tool_runtime = @import("../core/tooling/tool_runtime.zig");
const command_output_content = @import("../core/tooling/command_output_content.zig");
const builtin_tools = @import("../builtins/tools.zig");
const test_builtin_gateway = if (std_builtin.is_test)
    @import("../builtins/gateway.zig")
else
    struct {};
const types = @import("../core/shared/types.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;

pub const no_active_session_rpc_error = jsonrpc.RpcError{
    .code = ErrorCode.invalid_params,
    .message = "No active session",
};
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const McpHasToolFn = tool_mcp_runtime.HasToolFn;

pub const TerminalOutcome = union(enum) {
    stop_reason: acp_types.StopReason,
    rpc_error: jsonrpc.RpcError,
};

const AcpContext = struct {
    alloc: Allocator,
    state: *server.ServerState,
    session_id: []const u8,
    /// Tool-call IDs already announced with a pending update. Keys are owned
    /// copies of provider call ids so the ID stays stable from permission
    /// review through execution.
    published_tool_calls: std.StringHashMapUnmanaged(void) = .empty,
    stop_reason: acp_types.StopReason = .end_turn,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    /// Mode and permission policy captured at prompt dispatch so mid-turn
    /// session/set_mode changes never mutate a running turn.
    captured_mode: ?[]const u8 = null,
    captured_permission_mode: ?PermissionMode = null,

    fn deinitPublishedToolCalls(self: *AcpContext) void {
        var keys = self.published_tool_calls.keyIterator();
        while (keys.next()) |key| self.alloc.free(key.*);
        self.published_tool_calls.deinit(self.alloc);
    }

    fn sendUpdate(self: *AcpContext, update_json: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeSessionUpdate(&out.writer, self.session_id, update_json);
        try self.state.writer.writeNotification(self.alloc, "session/update", out.writer.buffered());
    }

    fn sendAgentText(self: *AcpContext, text: []const u8) !void {
        const plain = try stripAnsiAlloc(self.alloc, text);
        defer if (plain.ptr != text.ptr) self.alloc.free(plain);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeAgentMessageChunk(&out.writer, plain);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendModelRecoveryStatus(
        self: *AcpContext,
        status: types.RouteRecoveryStatus,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeModelRecoveryInfoUpdate(
            &out.writer,
            status,
            self.state.active_session.?.writable != null,
        );
        try self.sendUpdate(out.writer.buffered());
    }

    fn clearModelRecoveryStatus(self: *AcpContext) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeModelRecoveryInfoUpdate(&out.writer, null, false);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallPending(self: *AcpContext, arena: Allocator, call: ToolCall) ![]const u8 {
        if (self.published_tool_calls.getKey(call.id)) |published| return published;
        const registry = self.toolRegistry();
        const title = describeToolTitle(registry, arena, call) catch "Tool call";
        const kind = mapToolKind(call.name);

        const owned_id = try self.alloc.dupe(u8, call.id);
        errdefer self.alloc.free(owned_id);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCall(&out.writer, owned_id, title, kind, .pending);
        try self.sendUpdate(out.writer.buffered());
        try self.published_tool_calls.put(self.alloc, owned_id, {});
        return owned_id;
    }

    fn sendToolCallProgressText(self: *AcpContext, tool_call_id: []const u8, text: ?[]const u8) !void {
        const plain = if (text) |value| try stripAnsiAlloc(self.alloc, value) else null;
        defer if (plain) |value| if (text) |original| {
            if (value.ptr != original.ptr) self.alloc.free(value);
        };
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCallUpdate(&out.writer, tool_call_id, .in_progress, plain);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendWebSearchProgress(self: *AcpContext, tool_call_id: []const u8, progress: types.WebSearchProgress) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try writeWebSearchProgressUpdate(self.alloc, &out.writer, tool_call_id, progress);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendWebFetchProgress(self: *AcpContext, tool_call_id: []const u8, progress: types.WebFetchProgress) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try writeWebFetchProgressUpdate(self.alloc, &out.writer, tool_call_id, progress);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallCompletedWithCommandResult(self: *AcpContext, tool_call_id: []const u8, result_text: ?[]const u8, command_result_json: ?[]const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCallUpdateWithCommandResult(&out.writer, tool_call_id, .completed, result_text, command_result_json);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallError(self: *AcpContext, tool_call_id: []const u8, err_text: []const u8) !void {
        try self.sendToolCallErrorWithCommandResult(tool_call_id, err_text, null);
    }

    fn sendToolCallErrorWithCommandResult(self: *AcpContext, tool_call_id: []const u8, err_text: []const u8, command_result_json: ?[]const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCallUpdateWithCommandResult(&out.writer, tool_call_id, .failed, err_text, command_result_json);
        try self.sendUpdate(out.writer.buffered());
    }

    fn toolContext(self: *AcpContext) tool_runtime.Context {
        const session = if (self.state.active_session) |*active| active else unreachable;
        const provider_capabilities = self.state.cfg.provider_set.select(session.provider).capabilities;
        if (provider_capabilities.fx_search) {
            self.state.web_search_runtime.configure(.{
                .api_key = session.api_key,
                .credential_source = session.credential_source,
                .gateway_team = self.state.gateway_team,
                .worker_model = session.model,
                .gateway_retry_count = self.state.cfg.gateway_retry_count,
                .gateway_chat_url = self.state.cfg.gateway_chat_url,
                .usage = &session.session_rt.usage,
                .usage_allocator = self.state.alloc,
            });
        }
        var tc: tool_runtime.Context = .{
            .workspace_root = self.state.workspace_root,
            .access_scope = self.state.workspace_access.scope(self.state.workspace_root),
            .ignored_list_entries = self.state.cfg.ignored_list_entries,
            .max_list_entries = self.state.cfg.max_list_entries,
            .max_read_file_bytes = self.state.cfg.max_read_file_bytes,
            .max_read_file_lines = self.state.cfg.max_read_file_lines,
            .max_read_file_line_len = self.state.cfg.max_read_file_line_len,
            .max_command_output_bytes = self.state.cfg.max_command_output_bytes,
            .max_tool_result_bytes = session.max_tool_result_bytes,
            .api_key = session.api_key,
            .agent_stream_provider = server.streamProviderFor(self.state, session.provider),
            .credential_source = session.credential_source,
            .account_id = session.account_id,
            .provider = session.provider,
            .provider_capabilities = provider_capabilities,
            .oauth_transport = self.state.cfg.gateway_provider.oauth_transport,
            .secret_store = self.state.cfg.secret_store,
            .gateway_team = self.state.gateway_team,
            .model = session.model,
            .gateway_retry_count = self.state.cfg.gateway_retry_count,
            .gateway_chat_url = self.state.cfg.gateway_chat_url,
            .gateway_models_path = self.state.cfg.gateway_models_path,
            .agent_step_limit = session.agent_step_limit,
            .fast_mode = session.fast_mode,
            .effort = session.effort,
            .first_call_tool_choice = session.first_call_tool_choice,
            .permission_mode = self.captured_permission_mode orelse session.permission_mode,
            .permission_grants = session.session_grants,
            .permission_rules = session.permission_rules,
            .tool_registry = self.toolRegistry(),
            .permission_reviewer_provider = self.state.cfg.provider_set.select(session.provider).permission_reviewer,
            .auto_classifier = self.auto_classifier,
            .subagent_host = self.state.subagent_host,
            .subagent_caller_id = session.session_id,
            .worker = &self.state.worker,
            .permission_prompter = if (self.state.initialized) .{
                .context = @ptrCast(self),
                .request_fn = requestAcpPermission,
                .retain_grant_fn = retainAcpGrant,
            } else null,
            .cancel_flag = &session.cancel_flag,
            .background = &self.state.background,
            .session = &session.session_rt,
            .session_allocator = self.alloc,
            .skills_dir = self.state.skills.dir,
            .context_limits = self.state.context_limits,
            .context_enabled = self.state.context_enabled,
            .context_registry = self.state.cfg.context_registry,
            .output_chunk_ctx = @ptrCast(self),
            .on_output_chunk = onCommandOutputChunk,
            .mcp_progress_ctx = @ptrCast(self),
            .on_mcp_progress = onMcpProgress,
            .background_url_ctx = @ptrCast(self),
            .on_background_url_ready = onBackgroundUrlReady,
            .session_child_capability = if (session.writable) |*writable|
                writable.childCapability() catch null
            else
                null,
            .terminal_client = &self.state.terminal_client,
            .web_fetch_runtime = &self.state.web_fetch_runtime,
            .web_fetch_artifact_store = session.session_rt.webFetchArtifactStore(),
            .web_fetch_artifact_error = session.session_rt.webFetchArtifactError(),
            .web_search_runtime_ready = false,
            .web_search_backend = if (provider_capabilities.fx_search) self.state.web_search_runtime.dispatchBackend() else null,
            .model_capability_resolver = .{
                .ctx = @ptrCast(self),
                .resolve_fn = resolveModelCapabilities,
            },
            .interactive = false,
            .lifecycle_view = self.state.lifecycle_view,
            .lifecycle_scope = .{
                .kind = .acp,
                .workspace_root = session.workspace_root,
                .session_id = session.session_id,
            },
        };
        if (comptime !host_target.is_wasm) {
            if (session.mcp != null) {
                tc.mcp_ctx = @ptrCast(self);
                tc.mcp_has_tool = mcpHasTool;
                tc.mcp_validate_tool = mcpValidateTool;
                tc.mcp_call_tool = mcpCallTool;
                tc.mcp_search_tools = mcpSearchTools;
                tc.mcp_tool_schema = mcpToolSchemaJson;
                tc.mcp_call_feature = mcpCallFeature;
            }
        }
        return tc;
    }

    fn modelVisibleProjectContext(self: *const AcpContext) []const u8 {
        if (!self.state.context_enabled) return "";
        return self.state.context_snapshot.modelVisibleBytes();
    }

    fn toolRegistry(self: *const AcpContext) tool_dispatch.Registry {
        return activeToolSet(self.state).registry;
    }
};

fn activeToolSet(state: *const server.ServerState) tool_set_contract.ToolSet {
    if (comptime host_target.is_wasm) return tool_set_contract.empty;
    return if (state.cfg.allow_native_tools) builtin_tools.advertisement_set else tool_set_contract.empty;
}

const AcpElicitationResponderContext = struct {
    const AcceptedLegacyUrl = struct {
        acp_id: []u8,

        fn deinit(self: *AcceptedLegacyUrl, alloc: Allocator) void {
            alloc.free(self.acp_id);
            self.* = undefined;
        }
    };

    acp: *AcpContext,
    tool_call_id: []const u8,
    operation_cancel_flag: ?*const std.atomic.Value(bool),
    accepted_url_ids: std.ArrayListUnmanaged([]u8) = .empty,
    accepted_legacy_urls: std.ArrayListUnmanaged(AcceptedLegacyUrl) = .empty,

    fn deinit(self: *AcpElicitationResponderContext) void {
        for (self.accepted_url_ids.items) |id| self.acp.state.alloc.free(id);
        self.accepted_url_ids.deinit(self.acp.state.alloc);
        for (self.accepted_legacy_urls.items) |*accepted| {
            server.removeLegacyUrl(self.acp.state, accepted.acp_id);
            accepted.deinit(self.acp.state.alloc);
        }
        self.accepted_legacy_urls.deinit(self.acp.state.alloc);
        self.* = undefined;
    }

    fn responder(self: *AcpElicitationResponderContext) ?tool_mcp_runtime.InputResponder {
        const capabilities = self.acp.state.client_elicitation;
        if (!capabilities.any()) return null;
        return .{
            .context = @ptrCast(self),
            .capabilities = capabilities,
            .callback = respondToAcpMcpInput,
            .continuation_terminal = finishAcpUrlElicitations,
        };
    }
};

const Osc8Link = struct {
    uri: []const u8,
    end: usize,
};

/// Parses an OSC-8 hyperlink sequence (`ESC ]8;params;uri ST`) starting at
/// `index`. An empty uri marks the end of a hyperlink span.
fn parseOsc8Link(text: []const u8, index: usize) ?Osc8Link {
    if (!std.mem.startsWith(u8, text[index..], "\x1b]8;")) return null;
    const end = display_width.ansiSequenceEnd(text, index);
    var body_end = end;
    if (body_end > index and text[body_end - 1] == 0x07) {
        body_end -= 1;
    } else if (body_end >= index + 2 and text[body_end - 2] == 0x1b and text[body_end - 1] == '\\') {
        body_end -= 2;
    }
    const body_start = index + "\x1b]8;".len;
    if (body_end < body_start) return null;
    const body = text[body_start..body_end];
    const separator = std.mem.findScalar(u8, body, ';') orelse return null;
    return .{ .uri = body[separator + 1 ..], .end = end };
}

/// Removes ANSI escape sequences so ACP clients receive Markdown-compatible
/// text. OSC-8 hyperlinks become Markdown links so their targets survive the
/// conversion. Returns the original slice when no escape byte is present;
/// callers free the result only when it differs from the input.
fn stripAnsiAlloc(alloc: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, text, 0x1b) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var open_link_uri: ?[]const u8 = null;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            if (parseOsc8Link(text, index)) |link| {
                if (link.uri.len > 0) {
                    if (open_link_uri == null) {
                        try out.append(alloc, '[');
                        open_link_uri = link.uri;
                    }
                } else if (open_link_uri) |uri| {
                    try appendMarkdownLinkClose(alloc, &out, uri);
                    open_link_uri = null;
                }
                index = link.end;
            } else {
                index = display_width.ansiSequenceEnd(text, index);
            }
        } else {
            try out.append(alloc, text[index]);
            index += 1;
        }
    }
    // A link left open by a chunk boundary still closes with its target so
    // the emitted Markdown stays balanced.
    if (open_link_uri) |uri| try appendMarkdownLinkClose(alloc, &out, uri);
    return try out.toOwnedSlice(alloc);
}

fn appendMarkdownLinkClose(alloc: Allocator, out: *std.ArrayList(u8), uri: []const u8) !void {
    try out.appendSlice(alloc, "](");
    try out.appendSlice(alloc, uri);
    try out.append(alloc, ')');
}

/// Runs a prompt turn under the mode and permission policy captured at
/// dispatch. Mid-turn session/set_mode changes only affect later prompts.
pub fn handlePrompt(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    captured_mode: []const u8,
    captured_permission_mode: PermissionMode,
) !TerminalOutcome {
    const session = if (state.active_session) |*active| active else return .{
        .rpc_error = no_active_session_rpc_error,
    };
    if (!try server.selectCredentialForProvider(state, session.provider)) {
        return .{ .rpc_error = .{
            .code = ErrorCode.invalid_request,
            .message = if (session.provider == .codex)
                credentials.missing_chatgpt_credential_message
            else if (session.provider == .grok)
                credentials.missing_grok_credential_message
            else
                credentials.missing_credential_message,
        } };
    }

    const params = msg.params_raw orelse return .{
        .rpc_error = .{
            .code = ErrorCode.invalid_params,
            .message = "Missing params",
        },
    };

    var prompt_input = parsePromptInput(alloc, params) catch |err| switch (err) {
        error.UnsupportedPromptImage => return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Image prompt blocks are not supported",
            },
        },
        else => return err,
    };
    defer prompt_input.deinit(alloc);
    const prompt_text = prompt_input.text;

    if (prompt_input.continue_recovery and prompt_text.len != 0) {
        return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Recovery continuation cannot include a new prompt",
            },
        };
    }
    if (!prompt_input.continue_recovery and prompt_text.len == 0) {
        return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Empty prompt",
            },
        };
    }

    try refreshProjectContext(
        state,
        alloc,
        prompt_input.targets,
        prompt_input.omissions,
        prompt_input.omission_summary,
    );

    session.pending_prompt_id = msg.id;
    defer session.pending_prompt_id = null;

    var ctx = AcpContext{
        .alloc = alloc,
        .state = state,
        .session_id = session.session_id,
        .captured_mode = captured_mode,
        .captured_permission_mode = captured_permission_mode,
    };
    defer ctx.deinitPublishedToolCalls();

    var recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null;
    defer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (prompt_input.continue_recovery) {
        const writable = if (session.writable) |*value| value else return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "This session does not support durable recovery",
            },
        };
        const checkpoint = writable.state.recovery_checkpoint orelse return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "No paused model response to continue",
            },
        };
        recovery_checkpoint = try checkpoint.dupe(alloc);
    }

    var tool_projection = try state.cfg.mode_registry.buildModelToolProjection(alloc, activeToolSet(state), captured_mode, .{
        .permission_mode = captured_permission_mode,
        .permission_rules = session.permission_rules,
        .mcp_runtime = session.mcp,
        .subagent_available = state.subagent_host != null,
    });
    defer tool_projection.deinit(alloc);

    var bounded_skills = try state.skills.buildBoundedSystemPromptSection(alloc, state.context_limits);
    defer bounded_skills.deinit(alloc);
    if (bounded_skills.notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    if (bounded_skills.diagnostic_notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    for (state.context_snapshot.notices) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    const skills_section = bounded_skills.text;

    const owned_prompt = try alloc.dupe(
        u8,
        if (recovery_checkpoint) |checkpoint| checkpoint.user.text else prompt_text,
    );
    defer alloc.free(owned_prompt);
    var explicit_skills = try skill_invocation.buildExplicitPromptSection(
        alloc,
        .{ .skills = state.skills.items, .diagnostics = state.skills.diagnostics },
        owned_prompt,
        &.{},
        state.context_limits,
    );
    defer explicit_skills.deinit(alloc);
    if (explicit_skills.notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    if (explicit_skills.diagnostic_notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);

    session.session_rt.setConversationLanguageFromUserMessage(owned_prompt);
    const context_history = try session.session_rt.snapshotContextHistory(alloc);
    defer types.freeHistoryTurnSlice(alloc, context_history);
    var context_snapshot = try state.context_snapshot.dupe(alloc);
    defer context_snapshot.deinit(alloc);
    const root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
        alloc,
        owned_prompt,
        session.session_rt.history.items,
    );
    defer alloc.free(root_user_intent_context);

    const current_images = if (recovery_checkpoint) |checkpoint| checkpoint.user.images else &.{};
    const authorized_image_catalog = try session.session_rt.snapshotImageCatalog(alloc, current_images);
    defer types.freeImageAttachmentSlice(alloc, authorized_image_catalog);

    const job: worker_runtime.QueuedPrompt = .{
        .turn_id = if (recovery_checkpoint) |checkpoint| checkpoint.turn_id else 0,
        .prompt = @constCast(owned_prompt),
        .images = @constCast(current_images),
        .authorized_image_catalog = authorized_image_catalog,
        .model = session.model,
        .api_key = @constCast(session.api_key),
        .credential_source = session.credential_source,
        .account_id = if (session.account_id) |account_id| @constCast(account_id) else null,
        .provider = session.provider,
        .gateway_team = state.gateway_team,
        .permission_mode = captured_permission_mode,
        .history = context_history,
        .root_user_intent_context = root_user_intent_context,
        .grants = session.session_grants,
        .context_snapshot = context_snapshot,
        .recovery_checkpoint = recovery_checkpoint,
        .recovery_source_already_presented = recovery_checkpoint != null,
    };

    session.session_rt.usage.configureCheckpointSink(
        if (session.writable != null)
            .{
                .context = @ptrCast(&ctx),
                .allocator = alloc,
                .persist = persistUsageCheckpoint,
            }
        else
            null,
    );
    if (comptime @import("builtin").os.tag != .wasi) {
        if (state.cfg.provider_set.select(session.provider).deferred_usage != null) {
            if (session.credential_source) |source| {
                session.session_rt.usage.replaceProviderReconciliationCredential(
                    alloc,
                    session.provider,
                    source,
                    session.account_id,
                    session.api_key,
                );
            }
        }
    }
    defer session.session_rt.usage.configureCheckpointSink(null);
    const deps = agentRuntimeDeps(&ctx);
    var agent_config = buildAgentConfig(state, session, .{
        .skills_prompt_section = skills_section,
        .explicit_skills_prompt_section = explicit_skills.text,
        .advertised_tool_names = tool_projection.advertised_names,
        .advertised_functions = tool_projection.advertised_functions,
        .custom_tool_guidance = tool_projection.custom_guidance,
    });
    agent_config.session_child_capability = if (session.writable) |*writable|
        writable.childCapability() catch null
    else
        null;
    agent_runtime.processQueuedPrompt(&deps, null, .{
        .view = state.lifecycle_view,
        .scope = .{
            .kind = .acp,
            .workspace_root = session.workspace_root,
            .session_id = session.session_id,
        },
        .outcome_allocator = alloc,
    }, agent_config, job) catch |err| {
        if (err == error.NonInteractivePermissionRequired) {
            ctx.stop_reason = .refused;
        } else {
            return err;
        }
    };

    if (session.cancel_flag.load(.seq_cst)) {
        ctx.stop_reason = .cancelled;
    }

    return .{ .stop_reason = ctx.stop_reason };
}

pub fn runSubagentChild(
    raw: ?*anyopaque,
    turn: *subagent_execution.TurnContext,
    message: subagent_domain.QueuedMessage,
    admission: subagent_domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) subagent_execution.ServiceError!subagent_execution.RunOutcome {
    const state: *server.ServerState = @ptrCast(@alignCast(raw.?));
    const subagent_host = state.subagent_host orelse return error.ProviderFailed;
    const alloc = state.alloc;
    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    const active = if (state.active_session) |*session| session else {
        state.subagent_authority_mutex.unlock(io_mod.getIo());
        return error.ProviderFailed;
    };
    const session_id = active.session_id;
    const captured_mode = active.mode;
    const mcp = active.mcp;
    state.subagent_authority_mutex.unlock(io_mod.getIo());
    var ctx = AcpContext{
        .alloc = alloc,
        .state = state,
        .session_id = session_id,
        .captured_mode = captured_mode,
        .captured_permission_mode = admission.permission_mode,
    };
    defer ctx.deinitPublishedToolCalls();
    var child_projection = state.cfg.mode_registry.buildModelToolProjection(
        alloc,
        builtin_tools.advertisement_set,
        captured_mode,
        .{
            .permission_mode = admission.permission_mode,
            .permission_rules = admission.rules,
            .mcp_runtime = mcp,
            .subagent_available = true,
        },
    ) catch return error.OutOfMemory;
    defer child_projection.deinit(alloc);
    var bounded_skills = state.skills.buildBoundedSystemPromptSection(
        alloc,
        state.context_limits,
    ) catch return error.OutOfMemory;
    defer bounded_skills.deinit(alloc);
    var explicit_skills = skill_invocation.buildExplicitPromptSection(
        alloc,
        .{ .skills = state.skills.items, .diagnostics = state.skills.diagnostics },
        message.content,
        &.{},
        state.context_limits,
    ) catch return error.OutOfMemory;
    defer explicit_skills.deinit(alloc);
    return subagent_agent_adapter.run(.{
        .host = subagent_host,
        .tool_context = ctx.toolContext(),
        .provider_set = state.cfg.provider_set,
        .system_prompt = state.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = state.cfg.prompt_policy.modelPromptOverlay(admission.model),
        .skills_prompt_section = bounded_skills.text,
        .explicit_skills_prompt_section = explicit_skills.text,
        .advertised_tool_names = child_projection.advertised_names,
        .advertised_functions = child_projection.advertised_functions,
        .custom_tool_guidance = child_projection.custom_guidance,
        .context_registry = state.cfg.context_registry,
        .context_enabled = state.context_enabled,
        .project_context = state.context_snapshot.modelVisibleBytes(),
        .lifecycle_view = state.lifecycle_view,
    }, turn, message, admission, cancel);
}

fn refreshProjectContext(
    state: *server.ServerState,
    alloc: Allocator,
    targets: []const context_contract.ApplicableTarget,
    omissions: []const context_contract.ContextOmissionInput,
    omission_summary: ?context_contract.ContextOmissionSummary,
) context_contract.ProviderError!void {
    state.context_snapshot.deinit(alloc);
    if (!state.context_enabled) return;

    state.context_snapshot = state.cfg.context_registry.gatherDefaultSnapshot(alloc, .{
        .workspace_root = state.workspace_root,
        .access_scope = state.workspace_access.scope(state.workspace_root),
        .targets = targets,
        .omissions = omissions,
        .omission_summary = omission_summary,
        .context_limits = state.context_limits,
    }) catch |err| {
        debug_trace.logf("context", "acp gather failed err={s}", .{@errorName(err)});
        return err;
    };
}

const AgentConfigSections = struct {
    skills_prompt_section: []const u8,
    explicit_skills_prompt_section: []const u8,
    advertised_tool_names: []const []const u8 = &.{},
    advertised_functions: []const model_tool_schema.FunctionSchema = &.{},
    custom_tool_guidance: []const u8,
};

fn buildAgentConfig(state: *server.ServerState, session: *server.ActiveSessionState, sections: AgentConfigSections) agent_runtime.Config {
    return .{
        .system_prompt = state.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = state.cfg.prompt_policy.modelPromptOverlay(session.model),
        .skills_prompt_section = sections.skills_prompt_section,
        .explicit_skills_prompt_section = sections.explicit_skills_prompt_section,
        .gateway_retry_count = state.cfg.gateway_retry_count,
        .gateway_chat_url = state.cfg.gateway_chat_url,
        .advertised_tool_names = sections.advertised_tool_names,
        .advertised_functions = sections.advertised_functions,
        .provider_capabilities = state.cfg.provider_set.select(session.provider).capabilities,
        .custom_tool_guidance = sections.custom_tool_guidance,
        .agent_step_limit = session.agent_step_limit,
        .max_tool_result_bytes = session.max_tool_result_bytes,
        .cancel_flag = &session.cancel_flag,
        .fast_mode = session.fast_mode,
        .effort = session.effort,
        .first_call_tool_choice = session.first_call_tool_choice,
        .workspace_root = state.workspace_root,
        .access_scope = state.workspace_access.scope(state.workspace_root),
        .origin = if (session.writable) |writable|
            if (writable.external_prompt_origin == .persistent_child) .subagent else .root
        else
            .root,
        .root_user_messages = if (session.writable) |writable|
            writable.external_root_user_messages
        else
            &.{},
        .root_user_evidence_complete = if (session.writable) |writable|
            writable.external_root_user_evidence_complete
        else
            false,
        .current_prompt_is_root_authority = if (session.writable) |writable|
            writable.external_prompt_origin == .persistent_child
        else
            false,
        .context_limits = state.context_limits,
    };
}

const ParsedPromptInput = struct {
    text: []u8,
    continue_recovery: bool = false,
    targets: []context_contract.ApplicableTarget = &.{},
    omissions: []context_contract.ContextOmissionInput = &.{},
    omission_summary: ?context_contract.ContextOmissionSummary = null,

    fn deinit(self: *ParsedPromptInput, alloc: Allocator) void {
        alloc.free(self.text);
        for (self.targets) |target| alloc.free(@constCast(target.path));
        if (self.targets.len > 0) alloc.free(self.targets);
        for (self.omissions) |omission| alloc.free(@constCast(omission.source));
        if (self.omissions.len > 0) alloc.free(self.omissions);
        self.* = undefined;
    }
};

fn parsePromptInput(alloc: Allocator, params_json: []const u8) !ParsedPromptInput {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params_json, .{}) catch
        return .{ .text = try alloc.dupe(u8, "") };
    defer parsed.deinit();

    if (parsed.value != .object) return .{ .text = try alloc.dupe(u8, "") };

    const continue_recovery = blk: {
        const meta = parsed.value.object.get("_meta") orelse break :blk false;
        if (meta != .object) break :blk false;
        const fx = meta.object.get("fx") orelse break :blk false;
        if (fx != .object) break :blk false;
        const value = fx.object.get("continueRecovery") orelse break :blk false;
        break :blk value == .bool and value.bool;
    };

    const prompt_arr = parsed.value.object.get("prompt") orelse
        return .{ .text = try alloc.dupe(u8, ""), .continue_recovery = continue_recovery };
    if (prompt_arr != .array) return .{ .text = try alloc.dupe(u8, ""), .continue_recovery = continue_recovery };

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(alloc);
    var targets: std.ArrayList(context_contract.ApplicableTarget) = .empty;
    defer {
        for (targets.items) |target| alloc.free(@constCast(target.path));
        targets.deinit(alloc);
    }
    var omissions: std.ArrayList(context_contract.ContextOmissionInput) = .empty;
    var omission_summary: context_contract.ContextOmissionSummaryBuilder = .{};
    defer {
        for (omissions.items) |omission| alloc.free(@constCast(omission.source));
        omissions.deinit(alloc);
    }

    for (prompt_arr.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string) continue;

        if (std.mem.eql(u8, block_type.string, "text")) {
            if (block.object.get("text")) |text_val| {
                if (text_val == .string) {
                    if (text_buf.items.len > 0) try text_buf.append(alloc, '\n');
                    try text_buf.appendSlice(alloc, text_val.string);
                }
            }
        } else if (std.mem.eql(u8, block_type.string, "image")) {
            return error.UnsupportedPromptImage;
        } else if (std.mem.eql(u8, block_type.string, "resource")) {
            if (block.object.get("resource")) |resource| {
                if (resource == .object) {
                    const uri = if (resource.object.get("uri")) |uri_value|
                        if (uri_value == .string) uri_value.string else ""
                    else
                        "";
                    if (uri.len > 0) {
                        if (try localFileTargetPath(alloc, uri)) |path| {
                            errdefer alloc.free(path);
                            try targets.append(alloc, .{ .path = path, .kind = .file });
                        } else {
                            var duplicate = false;
                            for (omissions.items) |omission| {
                                if (omission.reason == .unsafe_target and std.mem.eql(u8, omission.source, uri)) {
                                    duplicate = true;
                                    break;
                                }
                            }
                            if (!duplicate) {
                                if (omissions.items.len < context_contract.Limits.project_omission_records) {
                                    const source = try alloc.dupe(u8, uri);
                                    errdefer alloc.free(source);
                                    try omissions.append(alloc, .{
                                        .source = source,
                                        .reason = .unsafe_target,
                                    });
                                } else {
                                    omission_summary.add(uri, .unsafe_target);
                                }
                            }
                        }
                    }
                    if (resource.object.get("text")) |text_val| {
                        if (text_val == .string) {
                            if (text_buf.items.len > 0) try text_buf.append(alloc, '\n');
                            if (uri.len > 0) {
                                try text_buf.appendSlice(alloc, "File: ");
                                try text_buf.appendSlice(alloc, uri);
                                try text_buf.append(alloc, '\n');
                            }
                            try text_buf.appendSlice(alloc, text_val.string);
                        }
                    }
                }
            }
        }
    }

    var result = ParsedPromptInput{
        .text = try alloc.dupe(u8, text_buf.items),
        .continue_recovery = continue_recovery,
    };
    errdefer result.deinit(alloc);
    result.targets = try targets.toOwnedSlice(alloc);
    result.omissions = try omissions.toOwnedSlice(alloc);
    result.omission_summary = omission_summary.finish();
    return result;
}

fn localFileTargetPath(alloc: Allocator, uri_text: []const u8) Allocator.Error!?[]u8 {
    const uri = std.Uri.parse(uri_text) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or
        uri.user != null or
        uri.password != null or
        uri.host != null or
        uri.port != null or
        uri.query != null or
        uri.fragment != null)
    {
        return null;
    }

    const encoded_path = switch (uri.path) {
        .raw, .percent_encoded => |path| path,
    };
    const decoded_storage = try alloc.dupe(u8, encoded_path);
    defer alloc.free(decoded_storage);

    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < decoded_storage.len) {
        const byte = if (decoded_storage[read_index] == '%') blk: {
            if (decoded_storage.len - read_index < 3) return null;
            const value = std.fmt.parseInt(
                u8,
                decoded_storage[read_index + 1 .. read_index + 3],
                16,
            ) catch return null;
            read_index += 3;
            break :blk value;
        } else blk: {
            const value = decoded_storage[read_index];
            read_index += 1;
            break :blk value;
        };
        if (byte == 0) return null;
        decoded_storage[write_index] = byte;
        write_index += 1;
    }
    const decoded_path = decoded_storage[0..write_index];
    if (!std.fs.path.isAbsolute(decoded_path)) return null;

    var components = std.mem.splitScalar(u8, decoded_path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return null;
    }

    return io_mod.realpathAlloc(alloc, decoded_path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn agentRuntimeDeps(ctx: *AcpContext) agent_runtime.AgentRuntimeDeps {
    const session = if (ctx.state.active_session) |*active| active else unreachable;
    return .{
        .ctx = @ptrCast(ctx),
        .agent_stream_provider = server.streamProviderFor(ctx.state, ctx.state.active_session.?.provider),
        .flush_assistant_stream_per_content_chunk = host_target.is_wasm,
        .tool_registry = ctx.toolRegistry(),
        .context_registry = ctx.state.cfg.context_registry,
        .context_enabled = ctx.state.context_enabled,
        .finalize_turn = finalizeTurn,
        .release_agent_terminal_lease = releaseAgentTerminalLease,
        .prepare_parent_turn_context = prepareParentTurnContext,
        .acknowledge_parent_turn_context = acknowledgeParentTurnContext,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermissionOutcomeWithRequest,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermissionOutcomeForRuntime,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolActionCompleted,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = if (comptime host_target.is_wasm) executeWebToolCall else executeToolCall,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .publish_deferred_tool_completion = publishDeferredToolCompletion,
        .propagate_history_turn = propagateHistoryTurn,
        .recovery_checkpoint = if (session.writable != null)
            .{
                .set = setRecoveryCheckpoint,
            }
        else
            null,
        .propagate_grant = retainAcpGrant,
        .push_event = pushEvent,
        .push_text = pushText,
        .push_route_recovery_status = pushRouteRecoveryStatus,
        .push_tool_lifecycle = pushToolLifecycle,
        .push_diff_block = pushDiffBlock,
        .push_system_notice = pushSystemNotice,
        .push_context_notice = pushContextNotice,
        .push_command_output_complete = pushCommandOutputComplete,
        .push_http_error = pushHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .available_model_capabilities = availableModelCapabilities,
        .resolve_model_capabilities = resolveModelCapabilities,
        .format_tool_execution_error = formatToolExecutionError,
        .record_tool_call_rejected = recordToolCallRejected,
        .usage = &session.session_rt.usage,
        .usage_allocator = ctx.state.alloc,
    };
}

fn releaseAgentTerminalLease(raw_ctx: *anyopaque, session_id: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.release_agent_terminal_lease(ctx.toolContext(), session_id);
}

fn refreshGatewayCredential(
    raw: *anyopaque,
    alloc: Allocator,
    source: types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw));
    return server.refreshModelCredential(
        @ptrCast(ctx.state),
        alloc,
        source,
        mode,
        expected_account_id,
    );
}

fn persistUsageCheckpoint(
    raw_ctx: *anyopaque,
    snapshot: session_usage.Snapshot,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const active = if (ctx.state.active_session) |*session|
        session
    else
        return error.SessionPersistenceUnavailable;
    if (!std.mem.eql(u8, active.session_id, ctx.session_id)) {
        return error.SessionPersistenceUnavailable;
    }
    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer active.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (active.writable) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const store = if (active.store) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        ctx.alloc,
        writable,
        snapshot,
    );
    if (writable.degradedTail() != null) {
        var current = try currentAcpState(
            ctx.alloc,
            active,
            writable,
            recovery_checkpoint.timestamp_ms,
        );
        defer current.deinit(ctx.alloc);
        try writable.retryDegradedWithStateReplacement(
            ctx.alloc,
            current,
            .{},
        );
    }
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        recovery_checkpoint.timestamp_ms,
        .retry_expected_tail,
        .{ .checkpoint_interval = 0 },
    );
    try store.finishUsageRecoveryCheckpoint(
        writable.active_id,
        recovery_checkpoint,
    );
}

fn resolveModelCapabilities(
    raw_ctx: *anyopaque,
    _: Allocator,
    model: []const u8,
) model_capabilities.ResolveError!model_capabilities.Capabilities {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return .{};
    const bundle = ctx.state.cfg.provider_set.select(session.provider);
    return ctx.state.capability_resolver.resolve(
        ctx.state.alloc,
        bundle.model_catalog orelse return bundle.fallbackModelCapabilities(model),
        .{
            .access = credentials.catalogAccessForCredentialAndAccount(
                session.credential_source,
                session.api_key,
                ctx.state.gateway_team,
                session.account_id,
            ),
            .endpoint = ctx.state.cfg.gateway_models_path,
            .cancel_flag = &session.cancel_flag,
        },
        model,
        bundle.fallbackModelCapabilities(model),
    );
}

fn availableModelCapabilities(
    raw_ctx: *anyopaque,
    model: []const u8,
) model_capabilities.Capabilities {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return .{};
    return ctx.state.capability_resolver.available(
        model,
        ctx.state.cfg.provider_set.select(session.provider).fallbackModelCapabilities(model),
    );
}

fn finalizeTurn(raw_ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) !void {
    std.debug.assert(turn_id != 0);
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (disposition == .length_limited) {
        ctx.stop_reason = .max_output_tokens;
    } else if (outcome == .failed or outcome == .paused) {
        ctx.stop_reason = .refused;
    }
}

fn appendRuntimeContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else unreachable;
    try ctx.state.cfg.context_registry.appendDefaultTransient(.{
        .workspace_root = ctx.state.workspace_root,
        .access_scope = ctx.state.workspace_access.scope(ctx.state.workspace_root),
        .interactive = false,
        .permission_mode = ctx.captured_permission_mode orelse session.permission_mode,
        .tracker = null,
        .background = &ctx.state.background,
        .session = &session.session_rt,
    }, arena, messages);
}

fn prepareParentTurnContext(
    raw_ctx: *anyopaque,
    arena: Allocator,
) !?agent_runtime.PreparedParentTurnContext {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const subagent_host = ctx.state.subagent_host orelse return null;
    const session = if (ctx.state.active_session) |*active| active else return null;
    return parent_delivery_projector.prepare(
        arena,
        subagent_host.sessions,
        session.session_id,
        subagent_host.manager.options.child_store,
    );
}

fn acknowledgeParentTurnContext(
    raw_ctx: *anyopaque,
    arena: Allocator,
    acknowledgements: []const agent_runtime.ParentTurnDeliveryAck,
) void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const subagent_host = ctx.state.subagent_host orelse return;
    const retirement_ready = parent_delivery_projector
        .acknowledgeWithRetirementSignal(
        arena,
        subagent_host.sessions,
        subagent_host.manager.options.child_store,
        acknowledgements,
    );
    if (retirement_ready) {
        subagent_host.requestRetirementSweep(io_mod.milliTimestamp());
    }
}

fn appendStaticContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.state.cfg.context_registry.appendDefaultStatic(.{
        .project_context = ctx.modelVisibleProjectContext(),
    }, arena, messages);
    const active_session = if (ctx.state.active_session) |*session| session else null;
    var snapshot = if (active_session) |session|
        if (session.mcp) |mcp|
            try mcp.snapshotModelCatalog(arena, session.permission_rules, false)
        else
            try mcp_model_catalog.Snapshot.empty(arena)
    else
        try mcp_model_catalog.Snapshot.empty(arena);
    defer snapshot.deinit(arena);
    const section = try mcp_model_catalog.render(arena, snapshot);
    if (section.text.len > 0) {
        try messages.append(arena, .{ .role = .system, .content = section.text });
    }
    if (section.notice) |notice| try pushContextNotice(raw_ctx, notice);
}

fn validateToolCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.state.active_session) |session| {
        const mode = ctx.captured_mode orelse session.mode;
        if (try ctx.state.cfg.mode_registry.toolPolicyDeniedJson(arena, activeToolSet(ctx.state), mode, call.name)) |reason| {
            return .{ .failure = reason };
        }
    }
    return tool_runtime.validateToolCall(ctx.toolContext(), arena, call);
}

fn checkToolAvailability(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.checkToolAvailability(ctx.toolContext(), arena, call);
}

fn requestPreparedFileMutationPermissionOutcomeForRuntime(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    tool_ctx.permission_review_turn = review_turn;
    const admission = tool_ctx.admissionInputWithLiveAuthority(live_authority);
    return tool_admission.requestPreparedFileMutationPermissionOutcome(
        admission,
        arena,
        call,
        prepared,
        permission_mode,
        local_grants,
    );
}

fn requestToolPermissionOutcome(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, permission_mode: PermissionMode, local_grants: []const PermissionGrant, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    return tool_admission.requestPermissionOutcome(
        tool_ctx.admissionInput(),
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

fn requestToolPermissionOutcomeWithRequest(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    tool_ctx.permission_review_turn = review_turn;
    const admission = tool_ctx.admissionInputWithLiveAuthority(live_authority);
    return if (revalidation) |request| switch (request) {
        .action => |action| tool_admission.revalidateLiveActionPermissionOutcome(
            admission,
            arena,
            call,
            permission_mode,
            local_grants,
            action.authority,
            action.human_approval,
        ),
    } else tool_admission.requestPermissionOutcome(
        admission,
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

const TestReviewTurn = struct {
    tool_calls: [1]ToolCall,
    root_messages: [1][]const u8,

    fn init(root_text: []const u8, call: ToolCall) TestReviewTurn {
        return .{
            .tool_calls = .{call},
            .root_messages = .{root_text},
        };
    }

    fn context(self: *const TestReviewTurn) permission_auto_classifier.ReviewTurnContext {
        return .{
            .model = "openai/gpt-5",
            .pending_assistant = .{ .role = .assistant, .tool_calls = &self.tool_calls },
            .target_call_id = self.tool_calls[0].id,
            .origin = .root,
            .current_root_request = self.root_messages[0],
        };
    }
};

fn requestAcpPermission(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    call: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    var validated_arguments: std.Io.Writer.Allocating = .init(alloc);
    defer validated_arguments.deinit();
    try writeValidatedToolArguments(alloc, &validated_arguments.writer, call.arguments_json);

    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const request_id = server.beginPermissionRequest(ctx.state) orelse return error.PermissionRequestAlreadyPending;
    errdefer {
        server.cancelPermissionRequest(ctx.state, request_id);
        _ = server.awaitPermissionDecision(ctx.state, request_id);
    }

    var pending_arena = std.heap.ArenaAllocator.init(alloc);
    defer pending_arena.deinit();
    const tool_call_id = try ctx.sendToolCallPending(pending_arena.allocator(), call);

    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    try params.writer.writeAll("{\"sessionId\":");
    try jsonrpc.writeJsonStr(ctx.session_id, &params.writer);
    try params.writer.writeAll(",\"toolCall\":{\"toolCallId\":");
    try jsonrpc.writeJsonStr(tool_call_id, &params.writer);
    try params.writer.writeAll(",\"title\":");
    try jsonrpc.writeJsonStr(request.label, &params.writer);
    try params.writer.writeAll(",\"kind\":");
    try jsonrpc.writeJsonStr(mapToolKind(call.name).jsonString(), &params.writer);
    try params.writer.writeAll(",\"status\":\"pending\",\"rawInput\":");
    try params.writer.writeAll(validated_arguments.written());
    try params.writer.writeAll("},\"options\":[");
    try writePermissionOption(&params.writer, "allow_once", "Allow once", "allow_once");
    try params.writer.writeByte(',');
    try writePermissionOption(&params.writer, "allow_always", "Allow for this session", "allow_always");
    try params.writer.writeByte(',');
    try writePermissionOption(&params.writer, "reject_once", "Reject", "reject_once");
    try params.writer.writeAll("]}");

    try ctx.state.writer.writeRequest(
        alloc,
        .{ .integer = @intCast(request_id) },
        "session/request_permission",
        params.writer.buffered(),
    );
    const decision = server.awaitPermissionDecision(ctx.state, request_id);
    return permission_request.OwnedPermissionResponse.init(alloc, decision, null);
}

fn writeValidatedToolArguments(alloc: Allocator, writer: *std.Io.Writer, arguments_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch
        return error.InvalidToolArgumentsJson;
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn writePermissionOption(
    writer: *std.Io.Writer,
    option_id: []const u8,
    name: []const u8,
    kind: []const u8,
) !void {
    try writer.writeAll("{\"optionId\":");
    try jsonrpc.writeJsonStr(option_id, writer);
    try writer.writeAll(",\"name\":");
    try jsonrpc.writeJsonStr(name, writer);
    try writer.writeAll(",\"kind\":");
    try jsonrpc.writeJsonStr(kind, writer);
    try writer.writeByte('}');
}

fn describeToolAction(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
}

fn resolveToolActionDisplayTarget(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.resolveTerminalDisplayTarget(
        arena,
        ctx.toolRegistry(),
        ctx.state.workspace_root,
        &ctx.state.terminal_client,
        call,
    );
}

fn describeToolActionCompleted(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
}

fn describeToolActionDenied(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const action = try tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ label, action });
}

fn lifecycleDynamicMcpToolAvailable(ctx: *AcpContext, name: []const u8, advertised_dynamic_tool_names: []const []const u8) bool {
    if (comptime host_target.is_wasm) return false;
    return dynamicMcpToolAvailable(ctx.toolRegistry(), name, advertised_dynamic_tool_names, @ptrCast(ctx), mcpHasTool, .unrestricted);
}

fn dynamicMcpToolAvailable(registry: tool_dispatch.Registry, name: []const u8, advertised_dynamic_tool_names: []const []const u8, mcp_ctx: ?*anyopaque, has_tool: ?McpHasToolFn, access: tool_mcp_runtime.Access) bool {
    if (!tool_presentation.isAdvertisedDynamicMcpName(registry, name, advertised_dynamic_tool_names)) return false;
    const raw_ctx = mcp_ctx orelse return false;
    const has = has_tool orelse return false;
    return has(raw_ctx, name, access);
}

fn permissionTargetForCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(
        ctx.toolContext(),
        advertised_dynamic_tool_names,
    );
    return tool_admission.permissionTargetForCall(tool_ctx.admissionInput(), arena, call);
}

fn executeWebToolCall(
    _: *anyopaque,
    request: agent_runtime.ToolExecutionRequest,
) !ToolExecutionResult {
    return agent_runtime.unavailableHostToolResult(request.result_allocator);
}

fn executeToolCall(
    raw_ctx: *anyopaque,
    request: agent_runtime.ToolExecutionRequest,
) !ToolExecutionResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));

    const acp_id = ctx.sendToolCallPending(request.call_allocator, request.call) catch "call_unknown";
    ctx.sendToolCallProgressText(acp_id, null) catch {};

    var tool_ctx = ctx.toolContext();
    var elicitation_responder = AcpElicitationResponderContext{
        .acp = ctx,
        .tool_call_id = acp_id,
        .operation_cancel_flag = tool_ctx.cancel_flag,
    };
    defer elicitation_responder.deinit();
    tool_ctx.mcp_input_responder = elicitation_responder.responder();
    tool_ctx.root_user_intent_context = request.root_user_intent_context;
    tool_ctx.root_user_messages = request.root_user_messages;
    tool_ctx.root_user_evidence_complete = request.root_user_evidence_complete;
    var progress_ctx = AcpWebSearchProgressContext{ .ctx = ctx, .tool_call_id = acp_id };
    var fetch_progress_ctx = AcpWebFetchProgressContext{ .ctx = ctx, .tool_call_id = acp_id };
    tool_ctx.web_search_progress_ctx = @ptrCast(&progress_ctx);
    tool_ctx.on_web_search_progress = onWebSearchProgress;
    tool_ctx.web_fetch_progress_ctx = @ptrCast(&fetch_progress_ctx);
    tool_ctx.on_web_fetch_progress = onWebFetchProgress;
    tool_ctx.session_grants = request.session_grants;
    tool_ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
    tool_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    const result = tool_runtime.executeToolCallAuthorized(
        tool_ctx,
        request,
    ) catch |err| {
        const err_text = try formatToolExecutionError(
            raw_ctx,
            request.result_allocator,
            request.call.name,
            err,
        );
        sendAuthorizedToolCallError(ctx, request, acp_id, err, err_text);
        return err;
    };

    return completeAuthorizedToolCallTransport(ctx, request, acp_id, result);
}

fn sendAuthorizedToolCallError(
    ctx: *AcpContext,
    _: agent_runtime.ToolExecutionRequest,
    acp_id: []const u8,
    _: anyerror,
    err_text: []const u8,
) void {
    ctx.sendToolCallError(acp_id, err_text) catch {};
}

fn completeAuthorizedToolCallTransport(
    ctx: *AcpContext,
    request: agent_runtime.ToolExecutionRequest,
    acp_id: []const u8,
    result: ToolExecutionResult,
) ToolExecutionResult {
    return completeToolCallTransport(ctx, request.call, acp_id, result);
}

fn completeToolCallTransport(
    ctx: *AcpContext,
    call: ToolCall,
    acp_id: []const u8,
    result: ToolExecutionResult,
) ToolExecutionResult {
    const output_text = toolUpdateContentText(result);
    if (result.status == .failure) {
        ctx.sendToolCallErrorWithCommandResult(
            acp_id,
            output_text,
            result.command_result_json,
        ) catch {};
        return result;
    }
    if (file_mutation_contract.isToolName(call.name) and
        result.committed_file_handoff != null)
    {
        var deferred = result;
        deferred.deferred_tool_completion = .{
            .transport_id = acp_id,
            .content_text = output_text,
            .command_result_json = result.command_result_json,
        };
        return deferred;
    }
    ctx.sendToolCallCompletedWithCommandResult(
        acp_id,
        output_text,
        result.command_result_json,
    ) catch {};
    return result;
}

fn publishCommittedFileHandoff(
    _: *anyopaque,
    _: file_mutation.CommittedFileHandoff,
) agent_runtime.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn publishDeferredToolCompletion(
    raw_ctx: *anyopaque,
    completion: agent_runtime.DeferredToolCompletion,
) agent_runtime.TransportPublicationOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendToolCallCompletedWithCommandResult(
        completion.transport_id,
        completion.content_text,
        completion.command_result_json,
    ) catch |err| {
        debug_trace.logf(
            "acp",
            "deferred ACP completion publication failed call_id={s} err={s}",
            .{ completion.transport_id, @errorName(err) },
        );
        return .failed;
    };
    return .published;
}

const AcpWebSearchProgressContext = struct {
    ctx: *AcpContext,
    tool_call_id: []const u8,
};

const AcpWebFetchProgressContext = struct {
    ctx: *AcpContext,
    tool_call_id: []const u8,
};

fn onWebSearchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebSearchProgress) void {
    const progress_ctx: *AcpWebSearchProgressContext = @ptrCast(@alignCast(raw_ctx));
    progress_ctx.ctx.sendWebSearchProgress(progress_ctx.tool_call_id, progress) catch {};
}

fn onWebFetchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebFetchProgress) void {
    const progress_ctx: *AcpWebFetchProgressContext = @ptrCast(@alignCast(raw_ctx));
    progress_ctx.ctx.sendWebFetchProgress(progress_ctx.tool_call_id, progress) catch {};
}

fn writeWebSearchProgressUpdate(alloc: Allocator, writer: *std.Io.Writer, tool_call_id: []const u8, progress: types.WebSearchProgress) !void {
    const text = try tool_presentation.formatWebSearchProgressPlain(alloc, progress);
    defer alloc.free(text);
    try acp_types.writeToolCallUpdate(writer, tool_call_id, .in_progress, text);
}

fn writeWebFetchProgressUpdate(alloc: Allocator, writer: *std.Io.Writer, tool_call_id: []const u8, progress: types.WebFetchProgress) !void {
    const text = try tool_presentation.formatWebFetchProgressPlain(alloc, progress);
    defer alloc.free(text);
    try acp_types.writeToolCallUpdate(writer, tool_call_id, .in_progress, text);
}

fn recordToolCallRejected(
    raw_ctx: *anyopaque,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const acp_id = ctx.sendToolCallPending(arena, call) catch "call_unknown";
    ctx.sendToolCallErrorWithCommandResult(
        acp_id,
        toolUpdateContentText(.{
            .status = .failure,
            .model_output = model_output,
        }),
        command_result_json,
    ) catch {};
}

fn toolUpdateContentText(result: ToolExecutionResult) []const u8 {
    if (!text_utils.isModelSafeText(result.model_output)) {
        debug_trace.logf(
            "acp",
            "tool update omitted binary or non-utf8 output bytes={d}",
            .{result.model_output.len},
        );
        return "binary or non-utf8 tool output omitted";
    }
    if (result.status == .failure and
        (tool_result_errors.isToolPermissionDeniedOutput(result.model_output) or
            tool_result_errors.isToolReviewHeldOutput(result.model_output)))
    {
        return result.model_output;
    }
    return text_utils.utf8PrefixByBytes(result.model_output, 200);
}

fn propagateHistoryTurn(raw_ctx: *anyopaque, turn: HistoryTurn) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.state.active_session) |*session| {
        try persistAcpHistoryTurn(ctx.alloc, session, turn);
    }
}

fn persistAcpHistoryTurn(
    alloc: Allocator,
    session: *server.ActiveSessionState,
    turn: HistoryTurn,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    try session.session_rt.appendHistoryEntry(alloc, turn);
    if (comptime host_target.is_wasm) {
        try sessions.commitWasmSessionLocked(alloc, session);
        return;
    }
    const writable = if (session.writable) |*value| value else return;
    try subagent_resume_admission.retainExternalRootUserTurn(
        alloc,
        writable,
        turn,
    );
    if (writable.degradedTail() != null) {
        const now_ms = io_mod.milliTimestamp();
        var current = try currentAcpState(alloc, session, writable, now_ms);
        defer current.deinit(alloc);
        if (current.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
        current.recovery_checkpoint = null;
        try writable.retryDegradedWithStateReplacement(
            alloc,
            current,
            .{},
        );
        if (current.usage) |usage| session.session_rt.usage.markClean(usage);
        return;
    }
    _ = writable.appendEvent(
        alloc,
        .{ .history_turn_committed = .{
            .conversation_language = session.session_rt.languageSnapshot(),
            .total_input_tokens = writable.state.total_input_tokens,
            .total_output_tokens = writable.state.total_output_tokens,
            .turn = turn,
        } },
        io_mod.milliTimestamp(),
        .retry_expected_tail,
        .{},
    ) catch |err| switch (err) {
        error.EventFrameTooLarge => {
            try commitAcpStateReplacement(alloc, session, writable, true);
            return;
        },
        else => return err,
    };
}


fn setRecoveryCheckpoint(
    raw_ctx: *anyopaque,
    checkpoint: session_codec.RecoveryCheckpoint,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*value| value else return error.SessionPersistenceUnavailable;
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*value| value else return error.SessionPersistenceUnavailable;
    const now_ms = io_mod.milliTimestamp();
    _ = writable.appendEvent(
        ctx.alloc,
        .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
        now_ms,
        .retry_expected_tail,
        .{},
    ) catch |err| switch (err) {
        error.EventFrameTooLarge => {
            var current = try currentAcpState(ctx.alloc, session, writable, now_ms);
            defer current.deinit(ctx.alloc);
            if (current.recovery_checkpoint) |*old| old.deinit(ctx.alloc);
            current.recovery_checkpoint = try checkpoint.dupe(ctx.alloc);
            _ = try writable.commitStateReplacement(
                ctx.alloc,
                current,
                .compaction,
                .retry_expected_tail,
                .{},
            );
        },
        else => return err,
    };
}

fn currentAcpState(
    alloc: Allocator,
    session: *server.ActiveSessionState,
    writable: *session_store.LoadedWritableSession,
    now_ms: i64,
) !session_codec.DurableSessionState {
    var state = try writable.state.dupe(alloc);
    errdefer state.deinit(alloc);
    const history = try session.session_rt.snapshotHistory(alloc);
    types.freeHistoryTurnSlice(alloc, state.history);
    state.history = history;
    const permission_state = try session.session_rt.snapshotPermissionState(alloc);
    state.permission_state.deinit(alloc);
    state.permission_state = permission_state;
    state.conversation_language = session.session_rt.languageSnapshot();
    state.updated_at_ms = now_ms;
    const usage = try session.session_rt.usage.snapshot(alloc);
    if (state.usage) |*old| old.deinit(alloc);
    state.usage = usage;
    return state;
}

fn commitAcpStateReplacement(
    alloc: Allocator,
    session: *server.ActiveSessionState,
    writable: *session_store.LoadedWritableSession,
    clear_recovery_checkpoint: bool,
) !void {
    const now_ms = io_mod.milliTimestamp();
    var state = try currentAcpState(alloc, session, writable, now_ms);
    defer state.deinit(alloc);
    if (clear_recovery_checkpoint) {
        if (state.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
        state.recovery_checkpoint = null;
    }
    _ = try writable.commitStateReplacement(
        alloc,
        state,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    if (state.usage) |usage| {
        session.session_rt.usage.markClean(usage);
    }
}

/// Stores grants on the active ACP session without persisting them.
fn retainAcpGrant(raw_ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.state.subagent_authority_mutex.unlock(io_mod.getIo());
    const session = if (ctx.state.active_session) |*active| active else return;
    try session.retainGrant(ctx.alloc, tool_name, target_path);
}

fn pushEvent(raw_ctx: *anyopaque, event: worker_runtime.WorkerEvent) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    switch (event) {
        .clear_route_recovery_status => try ctx.clearModelRecoveryStatus(),
        else => {},
    }
    worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
}

fn pushRouteRecoveryStatus(
    raw_ctx: *anyopaque,
    status: types.RouteRecoveryStatus,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.sendModelRecoveryStatus(status);
}

fn pushText(raw_ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const text = switch (emission) {
        .assistant_source => return,
        .assistant_rendered => |text| text,
        .operational => |text| text,
    };
    if (text.len == 0) return;
    ctx.sendAgentText(text) catch {};
}

fn pushToolLifecycle(raw_ctx: *anyopaque, event: types.ToolLifecycleEvent) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    switch (event) {
        .authoritative_started => |started| {
            var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
            defer arena_state.deinit();
            _ = try ctx.sendToolCallPending(arena_state.allocator(), .{
                .id = started.id.call_id,
                .name = started.tool_name,
                .arguments_json = started.arguments_json orelse "{}",
            });
        },
        .provisional, .progress, .terminal, .turn_finished => {},
    }
}

fn pushSystemNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendAgentText(text) catch {};
}

fn pushContextNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return;
    if (!try session.session_rt.claimContextNotice(ctx.alloc, text)) return;
    try pushSystemNotice(raw_ctx, text);
}

fn pushDiffBlock(raw_ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
    defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    try pushText(raw_ctx, .{ .operational = payload.preview });
}

fn pushCommandOutputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}

fn pushHttpError(raw_ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var buf: [1024]u8 = undefined;
    const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
    const owned_message = if (auth_failure) |failure|
        try failure.renderText(ctx.alloc)
    else
        null;
    defer if (owned_message) |message| ctx.alloc.free(message);
    const msg = owned_message orelse if (detail.len > 0)
        std.fmt.bufPrint(&buf, "HTTP {d}: {s}", .{ @intFromEnum(status), detail }) catch "HTTP error"
    else
        std.fmt.bufPrint(&buf, "HTTP {d}", .{@intFromEnum(status)}) catch "HTTP error";
    ctx.sendAgentText(msg) catch {};
}

fn formatToolExecutionError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return tool_result_errors.formatToolExecutionErrorJson(arena, tool_name, err);
}

fn onCommandOutputChunk(raw_ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, _: command_output_content.Stream, chunk: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const id = lifecycle_id orelse return;
    try ctx.sendToolCallProgressText(id.call_id, chunk);
}

fn onMcpProgress(raw_ctx: *anyopaque, lifecycle_id: types.ToolLifecycleId, text: []const u8) void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendToolCallProgressText(lifecycle_id.call_id, text) catch |err| {
        debug_trace.logf("mcp", "failed to publish ACP MCP progress err={s}", .{@errorName(err)});
    };
}

const AcpInputResponse = struct {
    key: []const u8,
    json: []u8,

    fn deinit(self: *AcpInputResponse, alloc: Allocator) void {
        alloc.free(self.json);
        self.* = undefined;
    }
};

fn respondToAcpMcpInput(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    required: tool_mcp_runtime.InputRequired,
) anyerror![]const u8 {
    const responder: *AcpElicitationResponderContext = @ptrCast(@alignCast(raw_ctx));
    const requests = try mrtr.parseRequestJsonForWire(
        alloc,
        required.input_requests_json,
        origin.wire,
        .{},
    );
    defer {
        for (requests) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    if (requests.len == 0) return error.McpInputRequired;

    const responses = try alloc.alloc(AcpInputResponse, requests.len);
    var response_count: usize = 0;
    errdefer {
        for (responses[0..response_count]) |*response| response.deinit(alloc);
        alloc.free(responses);
    }

    var cancelled = false;
    for (requests) |request| {
        const response_json = if (cancelled)
            try alloc.dupe(u8, "{\"action\":\"cancel\"}")
        else response: {
            const input_request = switch (request.payload) {
                .elicitation_create => |value| value,
                else => return error.McpInputRequired,
            };
            if (!responder.acp.state.client_elicitation.supports(input_request.mode)) {
                return error.McpInputRequired;
            }
            const direct = try requestAcpElicitation(
                responder,
                alloc,
                origin,
                input_request,
            );
            if (std.mem.eql(u8, direct, "{\"action\":\"cancel\"}")) cancelled = true;
            break :response direct;
        };
        responses[response_count] = .{ .key = request.key, .json = response_json };
        response_count += 1;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    for (responses, 0..) |response, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(response.key, .{}, &out.writer);
        try out.writer.writeByte(':');
        try out.writer.writeAll(response.json);
    }
    try out.writer.writeByte('}');
    const result = try out.toOwnedSlice();
    for (responses) |*response| response.deinit(alloc);
    alloc.free(responses);
    return result;
}

fn requestAcpElicitation(
    responder: *AcpElicitationResponderContext,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    input_request: mcp_elicitation.Request,
) ![]u8 {
    const state = responder.acp.state;
    const outbound_id = (try server.beginOutboundRequest(state, .elicitation)) orelse
        return error.McpInputRequired;
    var awaiting = true;
    errdefer if (awaiting) {
        server.cancelOutboundRequest(state, outbound_id);
        if (server.awaitOutboundResponse(state, outbound_id, .elicitation)) |owned| {
            var response = owned;
            response.deinit(state.alloc);
        }
    };

    var id_buffer: [48]u8 = undefined;
    const url_id = if (input_request.mode == .url)
        try std.fmt.bufPrint(&id_buffer, "fx-{d}", .{outbound_id})
    else
        null;
    const legacy_source_id = if (origin.wire.isLegacy() and input_request.mode == .url)
        input_request.elicitation_id orelse return error.McpInputRequired
    else
        null;
    var legacy_url_retained = false;
    if (legacy_source_id) |source_id| {
        if (!try server.reserveLegacyUrl(
            state,
            origin,
            source_id,
            url_id.?,
            responder.acp.session_id,
            responder.tool_call_id,
        )) return error.McpInputRequired;
        if (activeMcp(responder.acp)) |runtime| {
            runtime.reconcileLegacyUrlCompletion(
                origin,
                source_id,
                server.legacyUrlCompletionSink(state),
            );
        }
    }
    defer if (legacy_source_id != null and !legacy_url_retained) {
        server.removeLegacyUrl(state, url_id.?);
    };
    const display_message = try formatAcpElicitationMessage(alloc, origin.server_name, input_request);
    defer alloc.free(display_message);
    const params = try mcp_elicitation.projectToAcpCreateParams(
        alloc,
        input_request,
        .{ .session = .{
            .session_id = responder.acp.session_id,
            .tool_call_id = responder.tool_call_id,
        } },
        url_id,
        display_message,
        .{},
    );
    defer alloc.free(params);
    try state.writer.writeRequest(
        alloc,
        .{ .integer = @intCast(outbound_id) },
        "elicitation/create",
        params,
    );

    const maybe_response = try awaitAcpElicitationResponse(
        state,
        outbound_id,
        origin,
        responder.operation_cancel_flag,
    );
    awaiting = false;
    var response = maybe_response orelse return error.Cancelled;
    defer response.deinit(state.alloc);
    if (response.cancelled) return error.Cancelled;
    if (response.error_json != null) return error.McpInputRequired;
    const response_json = response.result_json orelse return error.McpInputRequired;

    var projected_request = try mcp_elicitation.parseRequest(alloc, .acp, params, .{});
    defer projected_request.deinit(alloc);
    const canonical_response = try mcp_elicitation.canonicalResponse(
        alloc,
        projected_request,
        response_json,
        .{},
    );
    errdefer alloc.free(canonical_response);
    const action = try mcp_elicitation.validateResponse(
        alloc,
        projected_request,
        canonical_response,
        .{},
    );
    var transition_state: mcp_elicitation.RequestState = .pending;
    const live_witness = if (activeMcp(responder.acp)) |runtime|
        runtime.inputIdentityWitness(origin.server_name)
    else
        null;
    const transition = mcp_elicitation.decideTransition(
        transition_state,
        bindingForAcpInput(responder, origin),
        answerBindingForAcpInput(responder, origin, live_witness),
        acpAwakeMillis(),
        live_witness != null,
    );
    switch (transition) {
        .consume => transition_state = .consumed,
        .reject => return error.McpInputRequired,
    }
    std.debug.assert(transition_state == .consumed);

    if (input_request.mode == .url and action == .accept) {
        if (legacy_source_id != null) {
            const runtime = activeMcp(responder.acp) orelse return error.McpInputRequired;
            const accept_result = runtime.acceptLegacyUrlCompletion(
                origin,
                url_id.?,
                server.legacyUrlCompletionSink(state),
            ) orelse return error.McpInputRequired;
            if (accept_result == .awaiting_completion) {
                const retained_acp_id = try state.alloc.dupe(u8, url_id.?);
                errdefer state.alloc.free(retained_acp_id);
                try responder.accepted_legacy_urls.append(state.alloc, .{
                    .acp_id = retained_acp_id,
                });
                legacy_url_retained = true;
            }
        } else {
            const retained_id = try state.alloc.dupe(u8, url_id.?);
            errdefer state.alloc.free(retained_id);
            try responder.accepted_url_ids.append(state.alloc, retained_id);
        }
    }
    return canonical_response;
}

fn formatAcpElicitationMessage(
    alloc: Allocator,
    server_name: []const u8,
    request: mcp_elicitation.Request,
) ![]u8 {
    return switch (request.mode) {
        .form => std.fmt.allocPrint(
            alloc,
            "Fx received a form request from MCP server {s}. {s}",
            .{ server_name, request.message },
        ),
        .url => std.fmt.allocPrint(
            alloc,
            "Fx received a URL request from MCP server {s} for host {s}. {s}",
            .{ server_name, request.url_host orelse "unknown", request.message },
        ),
        .unknown => error.McpInputRequired,
    };
}

fn bindingForAcpInput(
    responder: *AcpElicitationResponderContext,
    origin: tool_mcp_runtime.InputOrigin,
) mcp_elicitation.Binding {
    return .{
        .server_name = origin.server_name,
        .scope = .{ .acp_session = .{
            .session_id = responder.acp.session_id,
            .tool_call_id = responder.tool_call_id,
        } },
        .runtime_generation = origin.runtime_generation,
        .connection_generation = origin.connection_generation,
        .client_generation = origin.client_generation,
        .catalog_generation = origin.catalog_generation,
        .request_generation = origin.request_generation,
        .auth_generation = origin.auth_generation,
        .deadline_ms = origin.deadline_ms,
    };
}

fn answerBindingForAcpInput(
    responder: *AcpElicitationResponderContext,
    origin: tool_mcp_runtime.InputOrigin,
    witness: ?tool_mcp_runtime.InputIdentityWitness,
) mcp_elicitation.AnswerBinding {
    const current: tool_mcp_runtime.InputIdentityWitness = witness orelse .{
        .runtime_generation = origin.runtime_generation,
        .connection_generation = origin.connection_generation,
        .client_generation = origin.client_generation,
        .catalog_generation = origin.catalog_generation,
        .auth_generation = origin.auth_generation,
    };
    return .{
        .server_name = origin.server_name,
        .scope = .{ .acp_session = .{
            .session_id = responder.acp.session_id,
            .tool_call_id = responder.tool_call_id,
        } },
        .runtime_generation = current.runtime_generation,
        .connection_generation = current.connection_generation,
        .client_generation = current.client_generation,
        .catalog_generation = current.catalog_generation,
        .request_generation = origin.request_generation,
        .auth_generation = current.auth_generation,
    };
}

const AcpElicitationWait = union(enum) {
    response: ?server.OutboundResponse,
    deadline: anyerror!void,
    cancelled: anyerror!void,
};

fn awaitAcpElicitationResponse(
    state: *server.ServerState,
    id: u64,
    origin: tool_mcp_runtime.InputOrigin,
    operation_cancel_flag: ?*const std.atomic.Value(bool),
) !?server.OutboundResponse {
    const Cleanup = struct {
        fn drain(state_alloc: Allocator, select: *std.Io.Select(AcpElicitationWait)) void {
            while (select.cancel()) |item| switch (item) {
                .response => |maybe_response| if (maybe_response) |owned| {
                    var response = owned;
                    response.deinit(state_alloc);
                },
                .deadline, .cancelled => {},
            };
        }
    };

    var select_buffer: [3]AcpElicitationWait = undefined;
    var select: std.Io.Select(AcpElicitationWait) = .init(io_mod.getIo(), &select_buffer);
    try select.concurrent(.response, server.awaitOutboundResponse, .{ state, id, server.OutboundKind.elicitation });
    select.concurrent(.deadline, waitForAcpElicitationDeadline, .{origin.deadline_ms}) catch |err| {
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    select.concurrent(.cancelled, waitForAcpElicitationCancellation, .{
        origin.lifecycle_cancel_flag,
        operation_cancel_flag,
    }) catch |err| {
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    const event = select.await() catch |err| {
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    return switch (event) {
        .response => |response| result: {
            Cleanup.drain(state.alloc, &select);
            break :result response;
        },
        .deadline, .cancelled => result: {
            server.cancelOutboundRequest(state, id);
            Cleanup.drain(state.alloc, &select);
            break :result null;
        },
    };
}

fn waitForAcpElicitationDeadline(deadline_ms: i64) anyerror!void {
    while (acpAwakeMillis() < deadline_ms) {
        const remaining = deadline_ms - acpAwakeMillis();
        try io_mod.getIo().sleep(.fromMilliseconds(@intCast(@max(@min(remaining, 20), 1))), .awake);
    }
}

fn waitForAcpElicitationCancellation(
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
    operation_cancel_flag: ?*const std.atomic.Value(bool),
) anyerror!void {
    while ((lifecycle_cancel_flag == null or !lifecycle_cancel_flag.?.load(.acquire)) and
        (operation_cancel_flag == null or !operation_cancel_flag.?.load(.acquire)))
    {
        try io_mod.getIo().sleep(.fromMilliseconds(10), .awake);
    }
}

fn acpAwakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

fn finishAcpUrlElicitations(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    _: tool_mcp_runtime.InputOrigin,
    outcome: tool_mcp_runtime.ContinuationTerminal,
) void {
    const responder: *AcpElicitationResponderContext = @ptrCast(@alignCast(raw_ctx));
    for (responder.accepted_url_ids.items) |id| {
        if (outcome == .completed) {
            var params: std.Io.Writer.Allocating = .init(alloc);
            defer params.deinit();
            params.writer.writeAll("{\"elicitationId\":") catch continue;
            std.json.Stringify.value(id, .{}, &params.writer) catch continue;
            params.writer.writeByte('}') catch continue;
            responder.acp.state.writer.writeNotification(
                alloc,
                "elicitation/complete",
                params.writer.buffered(),
            ) catch {};
        }
        responder.acp.state.alloc.free(id);
    }
    responder.accepted_url_ids.clearRetainingCapacity();
    for (responder.accepted_legacy_urls.items) |*accepted| {
        if (outcome != .completed) {
            server.removeLegacyUrl(responder.acp.state, accepted.acp_id);
        }
        accepted.deinit(responder.acp.state.alloc);
    }
    responder.accepted_legacy_urls.clearRetainingCapacity();
}

fn mcpHasTool(raw_ctx: *anyopaque, name: []const u8, access: tool_mcp_runtime.Access) bool {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return false;
    return mcp.hasToolWithAccess(name, access);
}

fn mcpValidateTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const runtime = activeMcp(ctx) orelse return .not_available;
    return runtime.validateToolArgumentsByNameWithAccess(
        arena,
        name,
        arguments_json,
        access,
    );
}

fn mcpCallTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return null;
    return mcp.callToolByNameWithOptions(
        arena,
        name,
        arguments_json,
        max_tool_result_bytes,
        options,
    );
}

fn mcpSearchTools(raw_ctx: *anyopaque, arena: Allocator, query: *const tool_mcp_runtime.PreparedQuery, limit: usize, permission_rules: types.PermissionRuleSet, limits: config_runtime.context_limits.Values, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.SearchResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return error.McpServerNotFound;
    return mcp.searchToolsPrepared(arena, query, limit, permission_rules, limits, access);
}

fn mcpToolSchemaJson(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, permission_rules: types.PermissionRuleSet, limits: config_runtime.context_limits.Values, access: tool_mcp_runtime.Access) anyerror!?tool_mcp_runtime.ToolSchemaResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return null;
    return mcp.toolSchemaJsonByNameWithAccess(
        arena,
        name,
        permission_rules,
        limits,
        access,
    );
}

fn mcpCallFeature(
    raw_ctx: *anyopaque,
    arena: Allocator,
    request: tool_mcp_runtime.FeatureRequest,
    options: tool_mcp_runtime.FeatureCallOptions,
) anyerror!tool_mcp_runtime.FeatureResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return error.McpRuntimeUnavailable;
    return mcp.callFeatureForModel(arena, request, options);
}

fn activeMcp(ctx: *AcpContext) ?*mcp_runtime.McpRuntime {
    const session = if (ctx.state.active_session) |*active| active else return null;
    return session.mcp;
}

fn onBackgroundUrlReady(_: *anyopaque, _: u64, _: []const u8) void {}

pub fn mapToolKind(tool_name: []const u8) acp_types.ToolCallKind {
    if (std.mem.eql(u8, tool_name, "glob_files")) return .read;
    if (std.mem.eql(u8, tool_name, "grep_files")) return .search;
    if (std.mem.eql(u8, tool_name, "read_file")) return .read;
    if (std.mem.eql(u8, tool_name, "ast_symbols")) return .search;
    if (std.mem.eql(u8, tool_name, "web_fetch")) return .read;
    if (std.mem.eql(u8, tool_name, "web_search")) return .search;
    if (std.mem.eql(u8, tool_name, "write_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "edit_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "terminal")) return .execute;
    if (std.mem.eql(u8, tool_name, "run_command")) return .execute;
    if (std.mem.eql(u8, tool_name, "memory")) return .other;
    if (std.mem.eql(u8, tool_name, "skill")) return .other;
    if (std.mem.eql(u8, tool_name, "install_skill")) return .other;
    return .other;
}

fn describeToolTitle(registry: tool_dispatch.Registry, arena: Allocator, call: ToolCall) ![]const u8 {
    if (tool_dispatch.toolCallPresentation(arena, registry, call)) |presentation| {
        return std.fmt.allocPrint(arena, "{s}", .{presentation.action_label});
    }
    return std.fmt.allocPrint(arena, "{s}", .{call.name});
}


























const AcpContextRegistryFixture = struct {
    var gather_calls: usize = 0;
    var gather_error: ?context_contract.ProviderError = null;
    var static_context: ?[]const u8 = null;
    var transient_calls: usize = 0;
    var transient_permission_mode: ?PermissionMode = null;

    fn reset() void {
        gather_calls = 0;
        gather_error = null;
        static_context = null;
        transient_calls = 0;
        transient_permission_mode = null;
    }

    fn gather(alloc: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
        gather_calls += 1;
        if (gather_error) |err| return err;
        return .{ .content = try std.fmt.allocPrint(alloc, "ACP registry context {d}", .{gather_calls}) };
    }

    fn appendStatic(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        static_context = input.project_context;
        try messages.append(alloc, .{ .role = .system, .content = input.project_context });
    }

    fn appendTransient(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        transient_calls += 1;
        transient_permission_mode = input.permission_mode;
        try messages.append(alloc, .{ .role = .system, .content = "ACP registry transient" });
    }
};

const test_acp_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.acp_context",
    .gather_project_context_fn = AcpContextRegistryFixture.gather,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = AcpContextRegistryFixture.appendStatic,
    .append_transient_fn = AcpContextRegistryFixture.appendTransient,
} };

const test_acp_modes = [_]mode_registry.ModeSpec{
    .{ .id = "normal", .name = "Normal" },
    .{
        .id = "plan",
        .name = "Plan",
        .permission_mode = .ask,
        .tool_policy = .read_only,
        .tool_policy_denial_message = "Plan mode only allows read-only workspace inspection tools.",
    },
};

const test_acp_mode_registry = mode_registry.Registry{
    .default_mode_id = "normal",
    .modes = test_acp_modes[0..],
};

fn testModelPromptOverlay(model: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, model, "test-model")) "ACP test model overlay" else null;
}

fn testServerConfig() server.Config {
    return .{
        .default_model = "test-model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1",
        .gateway_models_path = "/models",
        .gateway_provider = test_builtin_gateway.provider,
        .provider_set = provider_set.gateway_only(test_builtin_gateway.provider_bundle),
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "test",
            .model_prompt_overlay_fn = testModelPromptOverlay,
        },
        .ignored_list_entries = &.{},
        .max_list_entries = 32,
        .max_read_file_bytes = 1024 * 1024,
        .max_read_file_lines = 1000,
        .max_read_file_line_len = 4096,
        .max_command_output_bytes = 1024 * 1024,
        .max_tool_result_bytes = 1024 * 1024,
        .max_history_turns = 8,
        .context_registry = test_acp_context_registry,
        .mode_registry = test_acp_mode_registry,
    };
}

fn initTestAcpState(alloc: Allocator, workspace_root: []const u8, mode: PermissionMode) !server.ServerState {
    const owned_workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(owned_workspace);
    const session_id = try alloc.dupe(u8, "session_1");
    errdefer alloc.free(session_id);
    const model = try alloc.dupe(u8, "test-model");
    errdefer alloc.free(model);
    const api_key = try alloc.dupe(u8, "test-api-key");
    errdefer alloc.free(api_key);

    const cfg = testServerConfig();
    return .{
        .alloc = alloc,
        .cfg = cfg,
        .writer = jsonrpc.Writer.init(),
        .workspace_root = owned_workspace,
        .api_key = api_key,
        .credential_source = .ai_gateway_api_key,
        .web_search_runtime = @import("../core/tooling/web_search_runtime.zig").Runtime.init(.{
            .provider = cfg.provider_set.gateway.fx_search.?,
        }),
        .active_session = .{
            .session_id = session_id,
            .model = model,
            .mode = "normal",
            .workspace_root = owned_workspace,
            .api_key = api_key,
            .credential_source = .ai_gateway_api_key,
            .agent_step_limit = 4,
            .max_tool_result_bytes = 1024 * 1024,
            .fast_mode = false,
            .effort = .auto,
            .first_call_tool_choice = .auto,
            .permission_mode = mode,
            .permission_rules = .{},
            .session_rt = .{ .max_history_turns = 8 },
            .cancel_flag = std.atomic.Value(bool).init(false),
            .pending_prompt_id = null,
        },
    };
}








fn testPermissionRuleSet(alloc: Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRuleSet {
    var rules = types.PermissionRuleSet{
        .rules = try alloc.alloc(types.PermissionRule, 1),
    };
    errdefer alloc.free(rules.rules);

    const owned_permission = try alloc.dupe(u8, permission);
    errdefer alloc.free(owned_permission);

    const owned_pattern = try alloc.dupe(u8, pattern);
    rules.rules[0] = .{
        .permission = owned_permission,
        .pattern = owned_pattern,
        .action = action,
    };
    return rules;
}

fn writeArgsJson(alloc: Allocator, path: []const u8, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    try out.writer.writeAll(",\"content\":");
    try std.json.Stringify.value(content, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn createSymlinkOrSkip(dir: std.Io.Dir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) {
            return error.SkipZigTest;
        }
        return err;
    };
}













