const std = @import("std");
const agent_runtime = @import("../agent/agent_runtime.zig");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const command_admission = @import("../permissions/command_admission.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const app_callbacks = @import("app_callbacks.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const host = @import("../hosts/host.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const background_runtime = @import("../background/background_runtime.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const hooks = @import("../hooks/hooks.zig");
const io_mod = @import("../shared/io.zig");
const mcp_elicitation_interaction = @import("../mcp/elicitation_interaction.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const permission_gate = @import("../permissions/permission_gate.zig");
const permissions = @import("../permissions/permissions.zig");
const prompt_policy_contract = @import("../config/prompt_policy.zig");
const model_provider = @import("../config/model_provider.zig");
const session_runtime = @import("../session/session.zig");
const session_child_store = @import("../session/session_child_store.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const subagent_agent_adapter = @import("../subagent/agent_adapter.zig");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_execution = @import("../subagent/execution.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("../tooling/tool_args.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_projection_mod = @import("../tooling/tool_projection.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const context_contract = @import("../workspace/context_contract.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_set = @import("../gateway/provider_set.zig");
const test_builtin_gateway = if (@import("builtin").is_test)
    @import("../../builtins/gateway.zig")
else
    struct {};
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const tool_presentation = @import("../tooling/tool_presentation.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const web_fetch_runtime = @import("../tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../tooling/web_search_runtime.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const js_host_workspace = @import("../hosts/js_host_workspace.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;

pub fn Runtime(comptime App: type) type {
    return struct {
        const ToolAuthorityView = struct {
            mode: PermissionMode,
            grants: []const PermissionGrant,
            rules: types.PermissionRuleSet,
        };

        fn appAccessScope(app: *const App) ?workspace_access.AccessScope {
            if (comptime @hasDecl(App, "workspaceAccessScope")) {
                return app.workspaceAccessScope();
            }
            return null;
        }

        fn appHostWorkspaceInfo(app: *const App) ?*const js_host_workspace.Info {
            if (comptime @hasDecl(App, "workspaceHostInfo")) {
                return app.workspaceHostInfo();
            }
            return null;
        }

        fn modelVisibleProjectContext(app: *App) []const u8 {
            if (comptime @hasField(App, "context_enabled")) {
                if (!app.context_enabled) return "";
            }
            if (app.worker.active_context_snapshot) |snapshot| return snapshot.modelVisibleBytes();
            return app.context_snapshot.modelVisibleBytes();
        }

        fn childToolContext(root_context: tool_runtime.Context) tool_runtime.Context {
            var child_context = root_context;
            child_context.tracker = null;
            return child_context;
        }

        pub fn toolContext(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                null,
            );
        }

        pub fn toolContextForSubagent(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            admission: subagent_domain.AdmissionSnapshot,
        ) tool_runtime.Context {
            return toolContextWithAuthority(
                app,
                ignored_list_entries,
                max_list_entries,
                max_read_file_bytes,
                max_read_file_lines,
                max_read_file_line_len,
                max_command_output_bytes,
                gateway_retry_count,
                gateway_chat_url,
                .{
                    .mode = admission.permission_mode,
                    .grants = admission.grants,
                    .rules = admission.rules,
                },
            );
        }

        fn toolContextWithAuthority(
            app: *App,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            authority: ?ToolAuthorityView,
        ) tool_runtime.Context {
            const host_workspace = appHostWorkspaceInfo(app);
            const workspace_root = if (host_workspace) |info|
                info.root()
            else
                app.workspace_root;
            const agent_settings = app.worker.effectiveAgentTurnSettings();
            const permission_snapshot = if (authority) |snapshot|
                worker_runtime.PermissionSnapshot{
                    .mode = snapshot.mode,
                }
            else
                app_permission_runtime.Runtime(App).livePermissionSnapshot(app);
            const permission_grants = if (authority) |snapshot|
                snapshot.grants
            else
                app.permission_engine.grants.items;
            const permission_rules = if (authority) |snapshot|
                snapshot.rules
            else
                app.permission_engine.rules;
            const child_capability =
                if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(app)
                else
                    null;
            const selected_provider = provider_runtime.provider(app);
            const provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                app.providerSet().select(selected_provider).capabilities
            else if (selected_provider == .gateway)
                provider_set.Bundle.Capabilities{ .fx_search = true, .vision_fallback = true }
            else
                provider_set.Bundle.Capabilities{};
            var ctx: tool_runtime.Context = .{
                .workspace_root = workspace_root,
                .access_scope = if (host_workspace != null)
                    workspace_access.AccessScope.primaryOnly(workspace_root)
                else
                    appAccessScope(app),
                .ignored_list_entries = ignored_list_entries,
                .max_list_entries = max_list_entries,
                .max_read_file_bytes = max_read_file_bytes,
                .max_read_file_lines = max_read_file_lines,
                .max_read_file_line_len = max_read_file_line_len,
                .max_command_output_bytes = max_command_output_bytes,
                .max_tool_result_bytes = agent_settings.max_tool_result_bytes,
                .api_key = app.auth.apiKey() orelse "",
                .agent_stream_provider = if (comptime @hasDecl(App, "agentStreamProvider"))
                    app.agentStreamProvider()
                else
                    agent_stream_provider.unavailable_provider,
                .gateway_team = app.auth.gatewayTeam(),
                .credential_source = app.auth.credentialSource(),
                .account_id = app.auth.accountId(),
                .provider = selected_provider,
                .provider_capabilities = provider_capabilities,
                .oauth_transport = app.auth.oauthTransport(),
                .secret_store = if (comptime @hasDecl(@TypeOf(app.auth), "secretStore"))
                    app.auth.secretStore()
                else
                    host.unavailable_secret_store,
                .model = provider_runtime.model(app),
                .gateway_retry_count = gateway_retry_count,
                .gateway_chat_url = gateway_chat_url,
                .gateway_models_path = if (comptime @hasField(App, "web_search_models_path")) app.web_search_models_path else "/v1/models",
                .agent_step_limit = app.agent_step_limit,
                .fast_mode = agent_settings.fast_mode,
                .effort = agent_settings.effort,
                .first_call_tool_choice = agent_settings.first_call_tool_choice,
                .tool_registry = if (comptime @hasDecl(App, "toolRegistry")) app.toolRegistry() else .{},
                .subagent_host = if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).subagentHost(app)
                else
                    null,
                .subagent_caller_id = if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).activeSessionId(app)
                else
                    null,
                .permission_mode = permission_snapshot.mode,
                .permission_grants = permission_grants,
                .permission_rules = permission_rules,
                .worker = &app.worker,
                .permission_prompter = tool_admission.workerPrompter(&app.worker),
                .cancel_flag = &app.worker.worker_cancel_requested,
                .background = &app.background,
                .session_child_capability = child_capability,
                .terminal_client = if (comptime @hasField(App, "terminal_client"))
                    &app.terminal_client
                else
                    null,
                .session = &app.session,
                .session_allocator = app.alloc,
                .skills_dir = app.skills.dir,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else true,
                .context_registry = app.contextRegistry(),
                .output_chunk_ctx = @ptrCast(app),
                .on_output_chunk = app_callbacks.Bindings(App).onCommandOutputChunk,
                .background_url_ctx = @ptrCast(app),
                .on_background_url_ready = app_callbacks.Bindings(App).onBackgroundUrlReady,
                .workspace_executor = if (comptime @hasDecl(App, "workspaceExecutor")) app.workspaceExecutor() else null,
                .host_sandbox_default = if (host_workspace) |info| switch (info.permission) {
                    .allow_sandboxed => .allow_sandboxed,
                    .prompt => .prompt,
                } else .none,
                .permission_reviewer_provider = if (comptime @hasDecl(App, "permissionReviewerProvider")) app.permissionReviewerProvider() else null,
                .tracker = &app.change_tracker,
                .mcp_ctx = @ptrCast(app),
                .mcp_has_tool = if (comptime runtime_profile.allows(App, .mcp)) mcpHasTool else null,
                .mcp_validate_tool = if (comptime runtime_profile.allows(App, .mcp)) validateMcpTool else null,
                .mcp_call_tool = if (comptime runtime_profile.allows(App, .mcp)) callMcpTool else null,
                .mcp_search_tools = if (comptime runtime_profile.allows(App, .mcp)) searchMcpTools else null,
                .mcp_tool_schema = if (comptime runtime_profile.allows(App, .mcp)) mcpToolSchemaJson else null,
                .mcp_call_feature = if (comptime runtime_profile.allows(App, .mcp)) callMcpFeature else null,
                .mcp_progress_ctx = @ptrCast(app),
                .on_mcp_progress = app_callbacks.Bindings(App).onMcpProgress,
                .lifecycle_view = app.lifecycle_view,
                .lifecycle_scope = lifecycleContext(app).scope,
            };
            if (comptime @hasField(App, "web_fetch_runtime")) {
                ctx.web_fetch_runtime = &app.web_fetch_runtime;
                ctx.web_fetch_artifact_store = app.session.webFetchArtifactStore();
                ctx.web_fetch_artifact_error = app.session.webFetchArtifactError();
                ctx.web_fetch_progress_ctx = @ptrCast(app);
                ctx.on_web_fetch_progress = app_callbacks.Bindings(App).onWebFetchProgress;
            }
            if (comptime @hasField(App, "web_search_runtime")) {
                if (provider_capabilities.fx_search) {
                    app.web_search_runtime.configure(.{
                        .api_key = app.auth.apiKey() orelse "",
                        .credential_source = app.auth.credentialSource(),
                        .gateway_team = app.auth.gatewayTeam(),
                        .worker_model = provider_runtime.model(app),
                        .gateway_retry_count = gateway_retry_count,
                        .gateway_chat_url = gateway_chat_url,
                        .usage = &app.session.usage,
                        .usage_allocator = app.alloc,
                    });
                    ctx.web_search_backend = app.web_search_runtime.dispatchBackend();
                }
                ctx.web_search_runtime_ready = false;
                ctx.web_search_progress_ctx = @ptrCast(app);
                ctx.on_web_search_progress = app_callbacks.Bindings(App).onWebSearchProgress;
            }
            if (comptime runtime_profile.allows(App, .mcp) and
                @hasDecl(@TypeOf(app.worker), "requestMcpElicitationAnswerBlocking") and
                @hasDecl(App, "urlOpener"))
            {
                ctx.mcp_input_responder = .{
                    .context = @ptrCast(app),
                    .capabilities = .{ .form = true, .url = true },
                    .legacy_url_manual_completion = true,
                    .callback = respondToMcpInput,
                };
            }
            ctx.model_capability_resolver = app_callbacks.Bindings(App).modelCapabilityResolver(app);
            return ctx;
        }

        fn respondToMcpInput(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            origin: tool_mcp_runtime.InputOrigin,
            required: tool_mcp_runtime.InputRequired,
        ) anyerror![]const u8 {
            return mcp_elicitation_interaction.respond(alloc, origin, required, .{
                .questioner = .{ .context = raw_ctx, .ask_fn = askMcpQuestion },
                .browser = .{ .context = raw_ctx, .open_fn = openMcpUrl },
                .capabilities = .{ .form = true, .url = true },
            });
        }

        fn askMcpQuestion(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            entries: []const types.QuestionBatchEntry,
            deadline_ms: i64,
            lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
        ) anyerror!?[][]u8 {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            var watch = DeadlineWatch{
                .app = app,
                .deadline_ms = deadline_ms,
                .lifecycle_cancel_flag = lifecycle_cancel_flag,
            };
            const watcher = try std.Thread.spawn(.{}, DeadlineWatch.run, .{&watch});
            defer {
                watch.done.store(true, .release);
                watcher.join();
            }

            const c_alloc = std.heap.c_allocator;
            const answers = try app.worker.requestMcpElicitationAnswerBlocking(c_alloc, entries) orelse {
                if (watch.timed_out.load(.acquire)) return error.McpInputTimedOut;
                return null;
            };
            defer freeMcpAnswers(c_alloc, answers);
            const copy = try alloc.alloc([]u8, answers.len);
            errdefer alloc.free(copy);
            var copied: usize = 0;
            errdefer for (copy[0..copied]) |answer| alloc.free(answer);
            while (copied < answers.len) : (copied += 1) {
                copy[copied] = try alloc.dupe(u8, answers[copied]);
            }
            return copy;
        }

        fn openMcpUrl(
            raw_ctx: ?*anyopaque,
            alloc: Allocator,
            url: []const u8,
        ) anyerror!bool {
            const app: *App = @ptrCast(@alignCast(raw_ctx.?));
            return app.urlOpener().open(alloc, url);
        }

        fn freeMcpAnswers(alloc: Allocator, answers: [][]u8) void {
            for (answers) |answer| alloc.free(answer);
            alloc.free(answers);
        }

        const DeadlineWatch = struct {
            app: *App,
            deadline_ms: i64,
            lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
            done: std.atomic.Value(bool) = .init(false),
            timed_out: std.atomic.Value(bool) = .init(false),

            fn run(self: *DeadlineWatch) void {
                while (!self.done.load(.acquire)) {
                    const cancelled = self.app.worker.worker_cancel_requested.load(.acquire);
                    const lifecycle_cancelled = if (self.lifecycle_cancel_flag) |flag|
                        flag.load(.acquire)
                    else
                        false;
                    const timed_out = currentAwakeMillis() >= self.deadline_ms;
                    if (cancelled or lifecycle_cancelled or timed_out) {
                        if (timed_out and !cancelled and !lifecycle_cancelled) {
                            self.timed_out.store(true, .release);
                        }
                        if (self.app.worker.cancelPendingQuestionBatch()) return;
                    }
                    io_mod.sleep(20 * std.time.ns_per_ms);
                }
            }
        };

        fn currentAwakeMillis() i64 {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
            return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
                std.math.minInt(i64)
            else
                std.math.maxInt(i64);
        }

        fn mcpHasTool(raw_ctx: *anyopaque, name: []const u8, access: tool_mcp_runtime.Access) bool {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.hasMcpTool(name, access);
        }

        fn validateMcpTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "validateMcpTool")) {
                return app.validateMcpTool(arena, name, arguments_json, access);
            }
            return .not_available;
        }

        fn callMcpTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            return app.callMcpTool(arena, name, arguments_json, max_tool_result_bytes, options);
        }

        fn searchMcpTools(raw_ctx: *anyopaque, arena: Allocator, query: *const tool_mcp_runtime.PreparedQuery, limit: usize, permission_rules: types.PermissionRuleSet, _: @import("../config/context_limits.zig").Values, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.SearchResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "searchMcpTools")) {
                return app.searchMcpTools(arena, query, limit, permission_rules, access);
            }
            return .{ .model_output = try arena.dupe(u8, "{\"tools\":[],\"count\":0}") };
        }

        fn mcpToolSchemaJson(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, permission_rules: types.PermissionRuleSet, _: @import("../config/context_limits.zig").Values, access: tool_mcp_runtime.Access) anyerror!?tool_mcp_runtime.ToolSchemaResult {
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            if (comptime @hasDecl(App, "mcpToolSchemaJson")) {
                return app.mcpToolSchemaJson(arena, name, permission_rules, access);
            }
            return null;
        }

        fn callMcpFeature(
            raw_ctx: *anyopaque,
            arena: Allocator,
            request: tool_mcp_runtime.FeatureRequest,
            options: tool_mcp_runtime.FeatureCallOptions,
        ) anyerror!tool_mcp_runtime.FeatureResult {
            if (comptime !@hasDecl(App, "acquireMcpRuntime")) {
                return error.McpRuntimeUnavailable;
            }
            const app: *App = @ptrCast(@alignCast(raw_ctx));
            var lease = app.acquireMcpRuntime() orelse return error.McpRuntimeUnavailable;
            defer lease.deinit();
            return lease.runtime.callFeatureForModel(arena, request, options);
        }

        pub fn resolveToolActionDisplayTarget(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            const ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            return tool_presentation.resolveTerminalDisplayTarget(
                arena,
                ctx.tool_registry,
                ctx.workspace_root,
                ctx.terminal_client,
                call,
            );
        }

        pub fn releaseAgentTerminalLease(
            app: *App,
            session_id: []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            return tool_runtime.release_agent_terminal_lease(
                toolContext(
                    app,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                session_id,
            );
        }

        pub fn describeToolAction(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .active, null);
        }

        pub fn describeToolActionCompleted(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .completed, null);
        }

        pub fn describeToolActionDenied(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            display_target: ?[]const u8,
            label: []const u8,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return formatToolAction(ctx, arena, call, display_target, .denied, label);
        }

        pub fn requestToolPermissionSync(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            revalidation: ?agent_runtime.LivePermissionRevalidation,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            var ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            ctx.permission_review_turn = review_turn;
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
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

        pub fn requestPreparedFileMutationPermissionSync(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            prepared: *tool_admission.PreparedFileMutationCall,
            review_turn: permission_auto_classifier.ReviewTurnContext,
            permission_mode: PermissionMode,
            local_grants: []const PermissionGrant,
            live_authority: ?agent_runtime.LiveToolAuthority,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !command_admission.PermissionOutcome {
            var ctx = tool_runtime.withAdvertisedDynamicToolNames(
                toolContext(
                    app,
                    ignored_list_entries,
                    max_list_entries,
                    max_read_file_bytes,
                    max_read_file_lines,
                    max_read_file_line_len,
                    max_command_output_bytes,
                    gateway_retry_count,
                    gateway_chat_url,
                ),
                advertised_dynamic_tool_names,
            );
            ctx.permission_review_turn = review_turn;
            const admission = ctx.admissionInputWithLiveAuthority(live_authority);
            return tool_admission.requestPreparedFileMutationPermissionOutcome(
                admission,
                arena,
                call,
                prepared,
                permission_mode,
                local_grants,
            );
        }

        pub fn validateToolCall(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolCallValidationResult {
            return tool_runtime.validateToolCall(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn checkToolAvailability(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !?[]const u8 {
            return tool_runtime.checkToolAvailability(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), arena, call);
        }

        pub fn permissionTargetForCall(
            app: *App,
            arena: Allocator,
            call: ToolCall,
            advertised_dynamic_tool_names: []const []const u8,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) ![]const u8 {
            const ctx = tool_runtime.withAdvertisedDynamicToolNames(toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url), advertised_dynamic_tool_names);
            return tool_admission.permissionTargetForCall(ctx.admissionInput(), arena, call);
        }

        pub fn executeToolCall(
            app: *App,
            request: agent_runtime.ToolExecutionRequest,
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !agent_runtime.ToolExecutionResult {
            var ctx = toolContext(app, ignored_list_entries, max_list_entries, max_read_file_bytes, max_read_file_lines, max_read_file_line_len, max_command_output_bytes, gateway_retry_count, gateway_chat_url);
            ctx.root_user_intent_context = request.root_user_intent_context;
            ctx.root_user_messages = request.root_user_messages;
            ctx.root_user_evidence_complete = request.root_user_evidence_complete;
            ctx.session_grants = request.session_grants;
            ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
            ctx.max_tool_result_bytes = request.max_tool_result_bytes;
            return tool_runtime.executeToolCallAuthorized(ctx, request);
        }

        pub fn appendStaticContextMessage(
            app: *App,
            arena: Allocator,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            try app.contextRegistry().appendDefaultStatic(.{
                .project_context = modelVisibleProjectContext(app),
            }, arena, messages);
            var snapshot = if (comptime @hasDecl(App, "snapshotMcpModelCatalog"))
                try app.snapshotMcpModelCatalog(
                    arena,
                    if (comptime @hasField(App, "permission_engine")) app.permission_engine.rules else .{},
                    false,
                )
            else
                try mcp_model_catalog.Snapshot.empty(arena);
            defer snapshot.deinit(arena);
            const section = try mcp_model_catalog.render(arena, snapshot);
            if (section.text.len > 0) {
                try messages.append(arena, .{ .role = .system, .content = section.text });
            }
            if (section.notice) |notice| try pushMcpModelCatalogNotice(app, notice);
        }

        fn pushMcpModelCatalogNotice(app: *App, notice: []const u8) !void {
            if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice")) {
                if (!try app.session.claimContextNotice(std.heap.c_allocator, notice)) return;
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, notice);
            defer std.heap.c_allocator.free(body);
            try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                .topic = "context",
                .tone = .warning,
                .body = body,
                .visibility = .full_only,
            });
        }

        pub fn appendTransientRuntimeContextMessage(
            app: *App,
            arena: Allocator,
            messages: *std.ArrayList(ChatMessage),
            ignored_list_entries: []const []const u8,
            max_list_entries: usize,
            max_read_file_bytes: usize,
            max_read_file_lines: usize,
            max_read_file_line_len: usize,
            max_command_output_bytes: usize,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            _ = ignored_list_entries;
            _ = max_list_entries;
            _ = max_read_file_bytes;
            _ = max_read_file_lines;
            _ = max_read_file_line_len;
            _ = max_command_output_bytes;
            _ = gateway_retry_count;
            _ = gateway_chat_url;
            const permission_snapshot = app_permission_runtime.Runtime(App).livePermissionSnapshot(app);
            const host_workspace = appHostWorkspaceInfo(app);
            const workspace_root = if (host_workspace) |info|
                info.root()
            else
                app.workspace_root;
            try app.contextRegistry().appendDefaultTransient(.{
                .workspace_root = workspace_root,
                .host_workspace = if (host_workspace) |info| .{
                    .root = info.root(),
                    .cwd = info.cwd(),
                    .home = info.home(),
                } else null,
                .access_scope = if (host_workspace != null)
                    workspace_access.AccessScope.primaryOnly(workspace_root)
                else
                    appAccessScope(app),
                .interactive = true,
                .permission_mode = permission_snapshot.mode,
                .tracker = &app.change_tracker,
                .background = &app.background,
                .session = &app.session,
            }, arena, messages);
        }

        pub fn refreshProjectContext(app: *App, targets: []const context_contract.ApplicableTarget) context_contract.ProviderError!void {
            app.context_snapshot.deinit(app.alloc);
            if (!app.context_enabled) return;

            app.context_snapshot = app.contextRegistry().gatherDefaultSnapshot(app.alloc, .{
                .workspace_root = app.workspace_root,
                .access_scope = appAccessScope(app),
                .targets = targets,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            }) catch |err| {
                debug_trace.logf("context", "gather failed err={s}", .{@errorName(err)});
                return err;
            };
            if (comptime @hasDecl(App, "writeDomainNotice")) {
                for (app.context_snapshot.notices) |notice| {
                    const should_emit = if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice"))
                        try app.session.claimContextNotice(app.alloc, notice)
                    else
                        true;
                    if (should_emit) {
                        const body = try types.renderContextNoticeBody(app.alloc, notice);
                        defer app.alloc.free(body);
                        app.writeDomainNotice(.{
                            .topic = "context",
                            .tone = .warning,
                            .body = body,
                            .visibility = .full_only,
                        }, true) catch return error.WriteFailed;
                    }
                }
            }
        }

        pub fn fetchModelIds(
            app: *App,
            provider: model_catalog.Provider,
            catalog_endpoint: []const u8,
        ) !std.ArrayList([]u8) {
            const result = model_catalog.fetchWithPublicFallback(provider, app.alloc, .{
                .access = app.auth.modelCatalogAccess(),
                .endpoint = catalog_endpoint,
            });
            var catalog = switch (result) {
                .loaded => |loaded| loaded.catalog,
                .failed => |failed| return failed.failure.asError(),
            };
            defer model_catalog.freeModelCatalog(app.alloc, &catalog);
            return model_catalog.projectModelIds(app.alloc, catalog.items);
        }

        pub fn processQueuedPrompt(
            app: *App,
            job: worker_runtime.QueuedPrompt,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
        ) !void {
            var snapshot_ownership = worker_runtime.ActivePromptSnapshotOwnership.init(job.images);
            app.worker.beginActivePromptSnapshots(&snapshot_ownership);
            defer app.worker.endActivePromptSnapshots(&snapshot_ownership);
            app.worker.active_context_snapshot = &job.context_snapshot;
            defer app.worker.active_context_snapshot = null;
            app.worker.setActiveAgentTurnSettings(job.agent_settings);
            defer app.worker.clearActiveAgentTurnSettings();
            var preflight_context_notices: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
            defer preflight_context_notices.deinit();
            var postflight_context_notices: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
            defer postflight_context_notices.deinit();
            for (job.context_snapshot.notices) |notice| {
                try appendClaimedContextNotice(app, &preflight_context_notices.writer, notice);
            }

            var bounded_skills = try app.skills.buildBoundedSystemPromptSection(
                std.heap.c_allocator,
                if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            );
            defer bounded_skills.deinit(std.heap.c_allocator);
            if (bounded_skills.notice) |notice| {
                try appendClaimedContextNotice(app, &postflight_context_notices.writer, notice);
            }
            if (bounded_skills.diagnostic_notice) |notice| {
                try appendClaimedContextNotice(app, &postflight_context_notices.writer, notice);
            }
            const skills_section = bounded_skills.text;
            const explicit_bindings = try std.heap.c_allocator.alloc(skill_invocation.ExplicitBinding, job.skill_bindings.len);
            defer std.heap.c_allocator.free(explicit_bindings);
            for (job.skill_bindings, 0..) |binding, index| {
                explicit_bindings[index] = .{ .name = binding.name, .path = binding.path };
            }
            var explicit_skills = try skill_invocation.buildExplicitPromptSection(
                std.heap.c_allocator,
                .{ .skills = app.skills.items, .diagnostics = app.skills.diagnostics },
                job.prompt,
                explicit_bindings,
                if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            );
            defer explicit_skills.deinit(std.heap.c_allocator);
            if (explicit_skills.notice) |notice| {
                try appendClaimedContextNotice(app, &postflight_context_notices.writer, notice);
            }
            if (explicit_skills.diagnostic_notice) |notice| {
                try appendClaimedContextNotice(app, &postflight_context_notices.writer, notice);
            }
            if (preflight_context_notices.written().len > 0) {
                try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                    .topic = "context",
                    .tone = .warning,
                    .body = preflight_context_notices.written(),
                    .visibility = .full_only,
                });
            }
            if (comptime @hasDecl(App, "waitForRequiredMcp")) {
                const failure = try app.waitForRequiredMcp(
                    std.heap.c_allocator,
                    &app.worker.worker_cancel_requested,
                );
                if (failure) |message| {
                    defer std.heap.c_allocator.free(message);
                    try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                        .topic = "mcp",
                        .tone = .warning,
                        .body = message,
                    });
                    return error.McpRequiredServerUnavailable;
                }
            }
            var tool_projection = try app.snapshotModelToolProjection(
                std.heap.c_allocator,
                job.permission_mode,
            );
            defer tool_projection.deinit(std.heap.c_allocator);
            const session_child_capability =
                if (comptime @hasField(App, "session_persistence"))
                    app_session_runtime.Runtime(App).childCapability(app)
                else
                    null;

            const deps = app_callbacks.Bindings(App).agentRuntimeDeps(app);
            const semantic_presentation = app_callbacks.Bindings(App).semanticPresentationSink(app);
            const config = buildQueuedPromptConfig(
                app,
                job,
                skills_section,
                explicit_skills.text,
                gateway_retry_count,
                gateway_chat_url,
                &tool_projection,
                session_child_capability,
            );
            const process_result = agent_runtime.processQueuedPrompt(&deps, semantic_presentation, lifecycleContext(app), config, job);
            if (postflight_context_notices.written().len > 0) {
                try app_worker_runtime.Runtime(App).pushSemanticNotice(app, .{
                    .topic = "context",
                    .tone = .warning,
                    .body = postflight_context_notices.written(),
                    .visibility = .full_only,
                });
            }
            try process_result;
        }

        fn lifecycleContext(app: *App) agent_runtime.LifecycleContext {
            return .{
                .view = app.lifecycle_view,
                .scope = .{
                    .kind = .interactive,
                    .workspace_root = app.workspace_root,
                    .session_id = if (comptime @hasField(App, "session_persistence"))
                        app_session_runtime.Runtime(App).activeSessionId(app)
                    else
                        null,
                },
                .outcome_allocator = app.alloc,
            };
        }

        pub fn runSubagentChild(
            raw: ?*anyopaque,
            turn: *subagent_execution.TurnContext,
            message: subagent_domain.QueuedMessage,
            admission: subagent_domain.AdmissionSnapshot,
            cancel: *std.atomic.Value(bool),
        ) subagent_execution.ServiceError!subagent_execution.RunOutcome {
            const app: *App = @ptrCast(@alignCast(raw.?));
            const alloc = std.heap.c_allocator;
            var child_projection = app.snapshotSubagentModelToolProjection(
                alloc,
                admission.permission_mode,
                admission.rules,
            ) catch
                return error.OutOfMemory;
            defer child_projection.deinit(alloc);
            var bounded_skills = app.skills.buildBoundedSystemPromptSection(
                alloc,
                if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            ) catch return error.OutOfMemory;
            defer bounded_skills.deinit(alloc);
            var explicit_skills = skill_invocation.buildExplicitPromptSection(
                alloc,
                .{ .skills = app.skills.items, .diagnostics = app.skills.diagnostics },
                message.content,
                &.{},
                if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            ) catch return error.OutOfMemory;
            defer explicit_skills.deinit(alloc);
            const prompt_policy = app.promptPolicy();
            const tool_context = childToolContext(app.subagentToolContextForAdmission(admission));
            const providers = if (comptime @hasDecl(App, "providerSet"))
                app.providerSet()
            else
                provider_set.Set{
                    .gateway = .{
                        .capabilities = tool_context.provider_capabilities,
                        .agent_stream = tool_context.agent_stream_provider,
                        .permission_reviewer = tool_context.permission_reviewer_provider,
                    },
                    .codex = .{
                        .capabilities = tool_context.provider_capabilities,
                        .agent_stream = tool_context.agent_stream_provider,
                        .permission_reviewer = tool_context.permission_reviewer_provider,
                    },
                    .grok = .{
                        .capabilities = tool_context.provider_capabilities,
                        .agent_stream = tool_context.agent_stream_provider,
                        .permission_reviewer = tool_context.permission_reviewer_provider,
                    },
                };
            return subagent_agent_adapter.run(.{
                .host = app_session_runtime.Runtime(App).subagentHost(app) orelse
                    return error.ProviderFailed,
                .tool_context = tool_context,
                .provider_set = providers,
                .system_prompt = prompt_policy.system_prompt,
                .model_prompt_overlay = prompt_policy.modelPromptOverlay(admission.model),
                .skills_prompt_section = bounded_skills.text,
                .explicit_skills_prompt_section = explicit_skills.text,
                .advertised_tool_names = child_projection.advertised_names,
                .advertised_functions = child_projection.advertised_functions,
                .custom_tool_guidance = child_projection.custom_guidance,
                .context_registry = app.contextRegistry(),
                .context_enabled = if (comptime @hasField(App, "context_enabled")) app.context_enabled else true,
                .project_context = modelVisibleProjectContext(app),
                .lifecycle_view = app.lifecycle_view,
            }, turn, message, admission, cancel);
        }

        fn appendClaimedContextNotice(app: *App, writer: *std.Io.Writer, notice: []const u8) !void {
            const should_emit = if (comptime @hasDecl(@TypeOf(app.session), "claimContextNotice"))
                try app.session.claimContextNotice(std.heap.c_allocator, notice)
            else
                true;
            if (!should_emit) return;
            if (writer.buffered().len > 0 and !std.mem.endsWith(u8, writer.buffered(), "\n")) {
                try writer.writeByte('\n');
            }
            const body = try types.renderContextNoticeBody(std.heap.c_allocator, notice);
            defer std.heap.c_allocator.free(body);
            try writer.writeAll(body);
        }

        fn buildQueuedPromptConfig(
            app: *App,
            job: worker_runtime.QueuedPrompt,
            skills_section: []const u8,
            explicit_skills_section: []const u8,
            gateway_retry_count: usize,
            gateway_chat_url: []const u8,
            tool_projection: *const tool_projection_mod.EffectiveToolProjection,
            session_child_capability: ?*session_child_store.SessionChildCapability,
        ) agent_runtime.Config {
            const prompt_policy = app.promptPolicy();
            return .{
                .system_prompt = prompt_policy.system_prompt,
                .model_prompt_overlay = prompt_policy.modelPromptOverlay(job.model),
                .skills_prompt_section = skills_section,
                .explicit_skills_prompt_section = explicit_skills_section,
                .gateway_retry_count = gateway_retry_count,
                .recovery_pause_flag = if (comptime @hasField(@TypeOf(app.worker), "worker_recovery_pause_requested"))
                    &app.worker.worker_recovery_pause_requested
                else
                    null,
                .gateway_chat_url = gateway_chat_url,
                .advertised_tool_names = tool_projection.advertised_names,
                .advertised_functions = tool_projection.advertised_functions,
                .provider_capabilities = if (comptime @hasDecl(App, "providerSet"))
                    app.providerSet().select(job.provider).capabilities
                else if (job.provider == .gateway)
                    .{ .fx_search = true, .vision_fallback = true }
                else
                    .{},
                .custom_tool_guidance = tool_projection.custom_guidance,
                .agent_step_limit = app.agent_step_limit,
                .max_tool_result_bytes = job.agent_settings.max_tool_result_bytes,
                .cancel_flag = &app.worker.worker_cancel_requested,
                .review_enabled = false,
                .fast_mode = job.agent_settings.fast_mode,
                .effort = job.agent_settings.effort,
                .first_call_tool_choice = job.agent_settings.first_call_tool_choice,
                .workspace_root = app.workspace_root,
                .access_scope = appAccessScope(app),
                .origin = if (app.session_persistence.writable) |writable|
                    if (writable.external_prompt_origin == .persistent_child) .subagent else .root
                else
                    .root,
                .root_user_messages = if (app.session_persistence.writable) |writable|
                    writable.external_root_user_messages
                else
                    &.{},
                .root_user_evidence_complete = if (app.session_persistence.writable) |writable|
                    writable.external_root_user_evidence_complete
                else
                    false,
                .current_prompt_is_root_authority = if (app.session_persistence.writable) |writable|
                    writable.external_prompt_origin == .persistent_child
                else
                    false,
                .session_child_capability = session_child_capability,
                .context_limits = if (comptime @hasField(App, "context_limits")) app.context_limits else .{},
            };
        }
    };
}

const ToolActionState = enum { active, completed, denied };

fn formatToolAction(
    ctx: tool_runtime.Context,
    arena: Allocator,
    call: ToolCall,
    display_target: ?[]const u8,
    state: ToolActionState,
    denied_label: ?[]const u8,
) ![]const u8 {
    if (std.mem.eql(u8, call.name, "web_search") or tool_presentation.isProviderSearchAlias(call.name)) {
        return formatWebSearchAction(arena, call, state, denied_label);
    }
    const spec = ctx.tool_registry.lookup(call.name) orelse {
        if (dynamicMcpActionLabel(state)) |label| {
            if (mcpToolAvailable(ctx, call.name)) {
                return formatToolActionValue(arena, label, call.name);
            }
        }
        return formatMissingSpecToolAction(arena, state, denied_label, call.name);
    };
    if (try tool_presentation.formatRunCommandActivity(arena, ctx.tool_registry, ctx.workspace_root, call)) |activity| {
        defer arena.free(activity.detail);
        const label = if (activity.compatibility_tool) |compatibility_tool|
            specLabel(compatibility_tool, state, denied_label)
        else switch (state) {
            .active => "Running",
            .completed => "Ran",
            .denied => denied_label.?,
        };
        return formatToolActionValue(
            arena,
            label,
            activity.detail,
        );
    }
    if (std.mem.eql(u8, call.name, "write_file") or
        std.mem.eql(u8, call.name, "edit_file"))
    {
        return formatToolActionValue(
            arena,
            specLabel(spec, state, denied_label),
            display_target orelse spec.label_arg_default,
        );
    }
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    const value = display_target orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    return formatToolActionValue(arena, presentationLabel(presentation, state, denied_label), value);
}

fn formatWebSearchAction(arena: Allocator, call: ToolCall, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    const args = tool_args.parseToolArgsObject(arena, call.arguments_json) catch {
        return formatInvalidArgsToolAction(arena, state, denied_label);
    };
    const label = switch (state) {
        .active => "Searching",
        .completed => "Searched",
        .denied => denied_label.?,
    };
    return formatToolActionValue(arena, label, try tool_presentation.formatWebSearchActionDetail(arena, args));
}

fn formatMissingSpecToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8, name: []const u8) ![]const u8 {
    return switch (state) {
        .active => formatToolActionValue(arena, "Working", name),
        .completed => formatToolActionValue(arena, "Completed", name),
        .denied => formatToolActionValue(arena, denied_label.?, name),
    };
}

fn formatInvalidArgsToolAction(arena: Allocator, state: ToolActionState, denied_label: ?[]const u8) ![]const u8 {
    return switch (state) {
        .active => std.fmt.allocPrint(arena, "● Working…\x1b[0m", .{}),
        .completed => formatToolActionValue(arena, "Completed", "tool call"),
        .denied => formatToolActionValue(arena, denied_label.?, "tool call"),
    };
}

fn formatToolActionValue(arena: Allocator, label: []const u8, value: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "● {s}\x1b[0m \x1b[38;5;245m{s}\x1b[0m", .{ label, value });
}

fn specLabel(spec: *const tool_dispatch.Tool, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => spec.action_label,
        .completed => spec.completed_action_label,
        .denied => denied_label.?,
    };
}

fn presentationLabel(presentation: tool_dispatch.CallPresentation, state: ToolActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => presentation.action_label,
        .completed => presentation.completed_action_label,
        .denied => denied_label.?,
    };
}

fn dynamicMcpActionLabel(state: ToolActionState) ?[]const u8 {
    return switch (state) {
        .active => "Running MCP",
        .completed => "Ran MCP",
        .denied => null,
    };
}

fn mcpToolAvailable(ctx: tool_runtime.Context, name: []const u8) bool {
    var advertised = false;
    for (ctx.advertised_dynamic_tool_names) |advertised_name| {
        if (std.mem.eql(u8, advertised_name, name)) {
            advertised = true;
            break;
        }
    }
    if (!advertised) return false;
    const raw_ctx = ctx.mcp_ctx orelse return false;
    const has_tool = ctx.mcp_has_tool orelse return false;
    return has_tool(raw_ctx, name, ctx.mcp_access);
}

const test_ignored_list_entries = [_][]const u8{ ".git", "zig-out" };
const test_gateway_chat_url = "https://gateway.test/chat";
const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.web_search,
    test_builtin_tools.terminal,
    test_builtin_tools.memory,
    test_builtin_tools.grep_files,
    test_builtin_tools.skill,
    test_builtin_tools.install_skill,
    test_builtin_tools.subagent,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_label_tool = tool_dispatch.Tool{
    .name = "custom_registered_tool",
    .description = "Custom registered test tool.",
    .model_schema = .{
        .name = "custom_registered_tool",
        .description = "Custom registered test tool.",
    },
    .action_label = "Custom running",
    .completed_action_label = "Custom ran",
    .label_arg_kind = .name,
    .label_arg_default = "custom fallback",
    .decode = test_builtin_tools.memory.decode,
    .call = test_builtin_tools.memory.call,
    .reads_only_fn = test_builtin_tools.memory.reads_only_fn,
    .irreversible_fn = test_builtin_tools.memory.irreversible_fn,
};
const custom_registry_tools = [_]tool_dispatch.Tool{custom_label_tool};
const custom_tool_registry = tool_dispatch.Registry{ .tools = custom_registry_tools[0..] };

fn gatherTestProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendTestStaticContext(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
    const content = try std.fmt.allocPrint(alloc, "provider static:{s}", .{input.project_context});
    try messages.append(alloc, .{ .role = .system, .content = content });
}

fn appendTestTransientContext(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
    const content = try std.fmt.allocPrint(
        alloc,
        "provider transient:{s}:{s}",
        .{ input.workspace_root, @tagName(input.permission_mode) },
    );
    try messages.append(alloc, .{ .role = .system, .content = content });
}

const test_context_provider = context_contract.Provider{
    .id = "test.default_context",
    .gather_project_context_fn = gatherTestProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendTestStaticContext,
    .append_transient_fn = appendTestTransientContext,
};
const test_context_registry = context_contract.Registry{ .default_provider = test_context_provider };
const test_prompt_policy = prompt_policy_contract.Policy{
    .system_prompt = "test system prompt",
    .model_prompt_overlay_fn = struct {
        fn overlay(model: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, model, "test-model")) "test model overlay" else null;
        }
    }.overlay,
};

var refresh_gather_calls: usize = 0;
var refresh_targets_match: bool = false;
var refresh_gather_error: context_contract.ProviderError = error.WriteFailed;

fn gatherFreshProjectContext(alloc: Allocator, input: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    refresh_gather_calls += 1;
    refresh_targets_match = input.targets.len == 1 and
        input.targets[0].kind == .file and
        std.mem.eql(u8, input.targets[0].path, "/tmp/workspace/images/example.png");
    const content = try std.fmt.allocPrint(alloc, "fresh:{s}", .{input.workspace_root});
    errdefer alloc.free(content);
    const notices = try alloc.alloc([]u8, 1);
    errdefer alloc.free(notices);
    notices[0] = try alloc.dupe(u8, "fresh context notice");
    return .{ .content = content, .notices = notices };
}

fn gatherFailingProjectContext(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    refresh_gather_calls += 1;
    return refresh_gather_error;
}

fn appendNoopStaticContext(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContext(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {}

const fresh_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.fresh_context",
    .gather_project_context_fn = gatherFreshProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContext,
    .append_transient_fn = appendNoopTransientContext,
} };
const failing_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.failing_context",
    .gather_project_context_fn = gatherFailingProjectContext,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContext,
    .append_transient_fn = appendNoopTransientContext,
} };

const RefreshContextApp = struct {
    alloc: Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    context_enabled: bool,
    context_snapshot: context_contract.GatheredContextSnapshot,
    context_registry: context_contract.Registry,
    context_notices: std.ArrayList(u8) = .empty,
    context_notice_tone: ?types.NoticeTone = null,
    context_notice_visibility: ?types.NoticeVisibility = null,
    session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },

    fn contextRegistry(self: *const RefreshContextApp) context_contract.Registry {
        return self.context_registry;
    }

    fn deinit(self: *RefreshContextApp) void {
        self.context_snapshot.deinit(self.alloc);
        self.context_notices.deinit(self.alloc);
        self.session.deinit(self.alloc);
    }

    fn writeDomainNotice(self: *RefreshContextApp, notice: types.SemanticNotice, _: bool) !void {
        self.context_notice_tone = notice.tone;
        self.context_notice_visibility = notice.visibility;
        try self.context_notices.appendSlice(self.alloc, notice.body);
    }
};

fn makeTestContextSnapshot(alloc: Allocator, provider_id: []const u8, content: []const u8) !context_contract.GatheredContextSnapshot {
    const owned_provider_id = try alloc.dupe(u8, provider_id);
    errdefer alloc.free(owned_provider_id);
    return .{ .contribution = .{
        .provider_id = owned_provider_id,
        .content = try alloc.dupe(u8, content),
    } };
}

fn testToolContext(app: *FakeApp) tool_runtime.Context {
    return Runtime(FakeApp).toolContext(app, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
}

const ProjectionBarrier = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn wait(self: *ProjectionBarrier) void {
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    }
};

const FakeApp = struct {
    alloc: Allocator,
    agent_stream_provider: agent_stream_provider.Provider = agent_stream_provider.unavailable_provider,
    workspace_root: []const u8 = "/tmp/workspace",
    auth: auth_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    selected_provider: model_provider.ProviderId = .gateway,
    permission_engine: permissions.PermissionEngine = .{},
    agent_step_limit: usize = 8,
    fast_mode: bool = true,
    effort: types.ReasoningEffort = types.ReasoningEffort.literal("high"),
    worker: worker_runtime.WorkerRuntime = .{},
    background: background_runtime.BackgroundRuntime = .{},
    session: session_runtime.SessionRuntime = .{ .max_history_turns = 4 },
    session_persistence: app_session_runtime.Persistence = .{},
    skills_dir: []const u8 = "/tmp/skills",
    context_snapshot: context_contract.GatheredContextSnapshot,
    permission_state: app_permission_runtime.State = .{},
    change_tracker: change_tracker.ChangeTracker = .{},
    skills: skill_runtime.Runtime = .{},
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,
    append_context_count: usize = 0,
    snapshot_tools_count: usize = 0,
    snapshot_permission_mode: ?PermissionMode = null,
    snapshot_permission_rule_pattern: ?[]const u8 = null,
    snapshot_barrier: ?*ProjectionBarrier = null,
    snapshot_tools_error: ?anyerror = null,
    snapshot_custom_guidance: []const u8 = "",
    mcp_name: []const u8 = "mcp_lookup",
    mcp_has_tool_calls: usize = 0,
    mcp_result: []const u8 = "{\"ok\":true}",
    diff_blocks: usize = 0,
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{
        .provider = test_builtin_gateway.default_web_search_provider,
    }),
    web_search_models_path: []const u8 = "/models",
    lifecycle_runtime: hooks.Runtime,
    lifecycle_view: hooks.RuntimeView,
    tool_registry: tool_dispatch.Registry = test_tool_registry,
    context_registry: context_contract.Registry = test_context_registry,

    fn init(alloc: Allocator) !FakeApp {
        var lifecycle_runtime = hooks.Runtime.init(alloc);
        const lifecycle_view = lifecycle_runtime.freeze();
        var app = FakeApp{
            .alloc = alloc,
            .lifecycle_runtime = lifecycle_runtime,
            .lifecycle_view = lifecycle_view,
            .context_snapshot = try makeTestContextSnapshot(alloc, "test.default_context", "project context"),
        };
        errdefer app.context_snapshot.deinit(alloc);
        var credential = credentials.Credential{
            .token = try alloc.dupe(u8, "api-key"),
            .source = .ai_gateway_api_key,
        };
        defer credential.deinit(alloc);
        _ = app.auth.adoptCredential(alloc, &credential);
        errdefer app.auth.deinit(alloc);
        try app.selected_model.appendSlice(alloc, "test-model");
        return app;
    }

    fn toolRegistry(self: *const FakeApp) tool_dispatch.Registry {
        return self.tool_registry;
    }

    fn contextRegistry(self: *const FakeApp) context_contract.Registry {
        return self.context_registry;
    }

    fn snapshotMcpModelCatalog(
        _: *FakeApp,
        alloc: Allocator,
        _: types.PermissionRuleSet,
        _: bool,
    ) !mcp_model_catalog.Snapshot {
        return mcp_model_catalog.Snapshot.empty(alloc);
    }

    fn promptPolicy(_: *const FakeApp) prompt_policy_contract.Policy {
        return test_prompt_policy;
    }

    pub fn agentStreamProvider(self: *const FakeApp) agent_stream_provider.Provider {
        return self.agent_stream_provider;
    }

    fn deinit(self: *FakeApp) void {
        self.auth.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.context_snapshot.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.background.deinit(self.alloc);
        self.session.deinit(self.alloc);
        self.change_tracker.deinit(self.alloc);
        self.lifecycle_runtime.deinit();
    }

    fn hasMcpTool(self: *FakeApp, name: []const u8, _: tool_mcp_runtime.Access) bool {
        self.mcp_has_tool_calls += 1;
        return std.mem.eql(u8, name, self.mcp_name);
    }

    fn callMcpTool(self: *FakeApp, arena: Allocator, name: []const u8, arguments_json: []const u8, _: usize, _: tool_mcp_runtime.CallOptions) !?tool_mcp_runtime.CallResult {
        _ = arguments_json;
        if (!self.hasMcpTool(name, .unrestricted)) return null;
        return .{ .model_output = try arena.dupe(u8, self.mcp_result) };
    }

    fn subagentToolContextForAdmission(
        self: *FakeApp,
        admission: subagent_domain.AdmissionSnapshot,
    ) tool_runtime.Context {
        return Runtime(FakeApp).toolContextForSubagent(
            self,
            &test_ignored_list_entries,
            100,
            1024,
            40,
            120,
            2048,
            2,
            test_gateway_chat_url,
            admission,
        );
    }

    fn snapshotModelToolProjection(
        self: *FakeApp,
        alloc: Allocator,
        permission_mode: PermissionMode,
    ) !tool_projection_mod.EffectiveToolProjection {
        self.snapshot_tools_count += 1;
        self.snapshot_permission_mode = permission_mode;
        if (self.snapshot_barrier) |barrier| barrier.wait();
        self.snapshot_permission_rule_pattern = if (self.permission_engine.rules.rules.len > 0)
            self.permission_engine.rules.rules[0].pattern
        else
            null;
        if (self.snapshot_tools_error) |err| return err;
        const advertised_names = try alloc.alloc([]const u8, 0);
        errdefer alloc.free(advertised_names);
        const advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0);
        errdefer alloc.free(advertised_functions);
        return .{
            .advertised_names = advertised_names,
            .advertised_functions = advertised_functions,
            .custom_guidance = try alloc.dupe(u8, self.snapshot_custom_guidance),
        };
    }

    fn snapshotSubagentModelToolProjection(
        self: *FakeApp,
        alloc: Allocator,
        permission_mode: PermissionMode,
        permission_rules: types.PermissionRuleSet,
    ) !tool_projection_mod.EffectiveToolProjection {
        self.snapshot_tools_count += 1;
        self.snapshot_permission_mode = permission_mode;
        if (self.snapshot_barrier) |barrier| barrier.wait();
        self.snapshot_permission_rule_pattern = if (permission_rules.rules.len > 0)
            permission_rules.rules[0].pattern
        else
            null;
        if (self.snapshot_tools_error) |err| return err;
        const advertised_names = try alloc.alloc([]const u8, 0);
        errdefer alloc.free(advertised_names);
        const advertised_functions = try alloc.alloc(model_tool_schema.FunctionSchema, 0);
        errdefer alloc.free(advertised_functions);
        return .{
            .advertised_names = advertised_names,
            .advertised_functions = advertised_functions,
            .custom_guidance = try alloc.dupe(u8, self.snapshot_custom_guidance),
        };
    }

    pub fn appendRuntimeContextMessage(self: *FakeApp, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
        self.append_context_count += 1;
        try Runtime(FakeApp).appendTransientRuntimeContextMessage(self, arena, messages, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestToolPermissionSync(self: *FakeApp, arena: Allocator, call: ToolCall, permission_mode: PermissionMode, local_grants: []const PermissionGrant) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestToolPermissionSync(self, arena, call, "", permission_mode, local_grants, null, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestToolPermissionSyncWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestToolPermissionSync(self, arena, call, review_turn, permission_mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn requestPreparedFileMutationPermissionSyncWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
        return Runtime(FakeApp).requestPreparedFileMutationPermissionSync(self, arena, call, prepared, review_turn, permission_mode, local_grants, live_authority, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn validateToolCall(self: *FakeApp, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
        return Runtime(FakeApp).validateToolCall(self, arena, call, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn checkToolAvailability(self: *FakeApp, arena: Allocator, call: ToolCall) !?[]const u8 {
        return Runtime(FakeApp).checkToolAvailability(self, arena, call, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolAction(self: *FakeApp, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).describeToolAction(self, arena, call, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolAction(self, arena, call, display_target, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionCompleted(self: *FakeApp, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).describeToolActionCompleted(self, arena, call, null, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionCompletedWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionCompleted(self, arena, call, display_target, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionDenied(self: *FakeApp, arena: Allocator, call: ToolCall, label: []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionDenied(self, arena, call, null, label, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn describeToolActionDeniedWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).describeToolActionDenied(self, arena, call, display_target, label, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn permissionTargetForCall(self: *FakeApp, arena: Allocator, call: ToolCall) ![]const u8 {
        return Runtime(FakeApp).permissionTargetForCall(self, arena, call, &.{}, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn permissionTargetForCallWithAdvertised(self: *FakeApp, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
        return Runtime(FakeApp).permissionTargetForCall(self, arena, call, advertised_dynamic_tool_names, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn executeToolCall(self: *FakeApp, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
        return Runtime(FakeApp).executeToolCall(self, request, &test_ignored_list_entries, 100, 1024, 40, 120, 2048, 2, test_gateway_chat_url);
    }

    pub fn executeToolCallWithAdvertised(self: *FakeApp, request: agent_runtime.ToolExecutionRequest) !agent_runtime.ToolExecutionResult {
        return self.executeToolCall(request);
    }

    pub fn registerAndEmitDiffBlock(self: *FakeApp, payload: agent_runtime.DiffEntryPayload) !void {
        _ = payload;
        self.diff_blocks += 1;
    }

    pub fn formatToolExecutionErrorForAgent(self: *FakeApp, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "Tool {s} failed: {s}", .{ tool_name, @errorName(err) });
    }
};

fn testAgentStreamProvider(stream_fn: agent_stream_provider.StreamFn) agent_stream_provider.Provider {
    var provider = test_builtin_gateway.agent_stream_provider;
    provider.stream_fn = stream_fn;
    return provider;
}

fn makeQueuedPrompt(alloc: Allocator) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, "draft an issue"),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "api-key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    };
}
