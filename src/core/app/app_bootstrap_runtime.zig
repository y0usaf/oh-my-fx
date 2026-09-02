const std = @import("std");
const app_lifecycle = @import("app_lifecycle.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_input_runtime = @import("app_input_runtime.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const app_runtime_setup = @import("app_runtime_setup.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const host = @import("../hosts/host.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const record_tape = @import("../workspace/record_tape.zig");
const statusline_identity = @import("../workspace/statusline_identity.zig");
const shared_io = @import("../shared/io.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const update_target = @import("../upgrade/update_target.zig");
const core_input_runtime = @import("../input/runtime.zig");
const ui_render = @import("../../ui/render.zig");
const ui_input = @import("../../ui/input/runtime.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const Allocator = std.mem.Allocator;

pub const CapabilityProviders = struct {
    load_mcp_runtime: mcp_runtime.LoadRuntimeFn,
    skill_root_policy: skill_contract.RootPolicy,
    terminal_title: host.TerminalTitle,
};

fn BootstrapDeps(comptime App: type) type {
    return struct {
        const BootstrapInteractiveAppFn = *const fn (app_lifecycle.BootstrapConfig) anyerror!app_lifecycle.StartupState;
        const ConfigureSessionPreferencesFn = *const fn (
            *App,
            model_provider.ProviderId,
            []const u8,
            config_runtime.ModelSource,
            []const u8,
            types.ReasoningEffort,
            bool,
        ) anyerror!void;
        const InitializePersistenceFn = *const fn (*App, bool) anyerror!void;
        const StageRequestedResumeViewFn = *const fn (*App) app_session_runtime.ResumeViewStage;
        const PublishStagedResumeViewFn = *const fn (*App, u32) anyerror!void;
        const LoadSkillsFn = *const fn (
            Allocator,
            []const u8,
            skill_contract.RootPolicy,
        ) app_runtime_setup.LoadSkillsError!app_runtime_setup.LoadedSkills;
        const WelcomeMessageFn = *const fn (Allocator) anyerror![]u8;
        const BeginFreshPersistedSessionFn = *const fn (*App) anyerror!void;
        const EnableSessionStoresFn = *const fn (*App) void;
        bootstrap_interactive_app: BootstrapInteractiveAppFn,
        configure_session_preferences: ConfigureSessionPreferencesFn,
        initialize_persistence: InitializePersistenceFn,
        stage_requested_resume_view: StageRequestedResumeViewFn,
        publish_staged_resume_view: PublishStagedResumeViewFn,
        load_mcp_runtime: mcp_runtime.LoadRuntimeFn,
        load_skills: LoadSkillsFn,
        skill_root_policy: skill_contract.RootPolicy,
        welcome_message: WelcomeMessageFn,
        begin_fresh_persisted_session: BeginFreshPersistedSessionFn,
        enable_session_stores: EnableSessionStoresFn,
        terminal_title: host.TerminalTitle,
    };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn bootstrap(
            app: *App,
            footer_rows: u16,
            default_model: []const u8,
            default_agent_step_limit: usize,
            resize_handler: app_lifecycle.ResizeHandler,
            record_requested: bool,
            capability_providers: CapabilityProviders,
        ) !void {
            try bootstrapWithDeps(
                app,
                footer_rows,
                default_model,
                default_agent_step_limit,
                resize_handler,
                record_requested,
                defaultDeps(capability_providers),
            );
        }

        fn defaultDeps(capability_providers: CapabilityProviders) BootstrapDeps(App) {
            return .{
                .bootstrap_interactive_app = bootstrapInteractiveAppDefault,
                .configure_session_preferences = configureSessionPreferencesDefault,
                .initialize_persistence = initializePersistenceDefault,
                .stage_requested_resume_view = stageRequestedResumeViewDefault,
                .publish_staged_resume_view = publishStagedResumeViewDefault,
                .load_mcp_runtime = capability_providers.load_mcp_runtime,
                .load_skills = app_runtime_setup.loadSkills,
                .skill_root_policy = capability_providers.skill_root_policy,
                .welcome_message = welcomeMessageDefault,
                .begin_fresh_persisted_session = beginFreshPersistedSessionDefault,
                .enable_session_stores = enableSessionStoresDefault,
                .terminal_title = capability_providers.terminal_title,
            };
        }

        fn bootstrapInteractiveAppDefault(cfg: app_lifecycle.BootstrapConfig) !app_lifecycle.StartupState {
            return app_lifecycle.bootstrapInteractiveApp(cfg);
        }

        fn initializePersistenceDefault(
            app: *App,
            required: bool,
        ) !void {
            try app_session_runtime.Runtime(App).initializePersistence(
                app,
                required,
            );
        }

        fn stageRequestedResumeViewDefault(app: *App) app_session_runtime.ResumeViewStage {
            return app_session_runtime.Runtime(App).stageRequestedResumeView(app);
        }

        fn publishStagedResumeViewDefault(app: *App, entry_id: u32) !void {
            try app_session_runtime.Runtime(App).publishStagedResumeView(app, entry_id);
        }

        fn configureSessionPreferencesDefault(
            app: *App,
            provider: model_provider.ProviderId,
            configured_model: []const u8,
            model_source: config_runtime.ModelSource,
            selected_model: []const u8,
            effort: types.ReasoningEffort,
            fast_mode: bool,
        ) !void {
            try app_session_runtime.Runtime(App).configureStartupPreferences(
                app,
                provider,
                configured_model,
                model_source,
                selected_model,
                effort,
                fast_mode,
            );
        }

        fn welcomeMessageDefault(alloc: Allocator) ![]u8 {
            return ui_render.welcomeMessage(alloc);
        }

        fn beginFreshPersistedSessionDefault(app: *App) !void {
            try app_session_runtime.Runtime(App).beginFreshPersistedSession(app);
        }

        fn enableSessionStoresDefault(app: *App) void {
            app_session_runtime.Runtime(App).enableSessionStores(app);
        }

        // Neutral one-line summary inline; the full detail stays behind Ctrl+O.
        fn writeCollapsedStartupNotice(app: *App, topic: []const u8, summary_lead: []const u8, detail: []const u8) !void {
            const summary = try std.fmt.allocPrint(app.alloc, "{s} (ctrl o to view)", .{summary_lead});
            defer app.alloc.free(summary);
            try app.writeDomainNotice(.{ .topic = topic, .tone = .neutral, .body = summary }, true);
            try app.writeDomainNotice(.{ .topic = topic, .tone = .neutral, .body = detail, .visibility = .full_only }, true);
        }

        fn bootstrapWithDeps(
            app: *App,
            footer_rows: u16,
            default_model: []const u8,
            default_agent_step_limit: usize,
            resize_handler: app_lifecycle.ResizeHandler,
            record_requested: bool,
            deps: BootstrapDeps(App),
        ) !void {
            errdefer app.deinit();

            var startup = try deps.bootstrap_interactive_app(.{
                .alloc = app.alloc,
                .terminal = &app.terminal,
                .shell = &app.shell,
                .metrics = &app.metrics,
                .terminal_title = deps.terminal_title,
                .footer_rows = footer_rows,
                .startup_min_body_rows = ui_render.welcome_message_reserved_rows,
                .default_model = default_model,
                .default_agent_step_limit = default_agent_step_limit,
                .secret_store = if (comptime @hasDecl(App, "secretStore"))
                    app.secretStore()
                else
                    host.unavailable_secret_store,
                .resize_handler = resize_handler,
                .fx_version = App.app_version,
                .record_requested = record_requested,
            });
            defer startup.deinit(app.alloc);

            app.workspace_root = startup.takeWorkspaceRoot();
            if (comptime @hasDecl(App, "adoptWorkspaceAccess")) {
                app.adoptWorkspaceAccess(startup.takeWorkspaceAccess());
            }
            if (startup.takeCredential()) |credential_value| {
                var credential = credential_value;
                defer credential.deinit(app.alloc);
                _ = app.auth.adoptCredential(app.alloc, &credential);
            }
            app.auth.recordStartupStatus(
                startup.stored_key_status,
                startup.credential_onboarding_skipped,
            );
            if (comptime @hasDecl(@TypeOf(app.auth), "refreshChatGptSourceInventory")) {
                app.auth.refreshChatGptSourceInventory(app.alloc) catch |err| {
                    debug_trace.logf("auth", "startup ChatGPT inventory refresh failed err={s}", .{@errorName(err)});
                };
            } else {
                app.auth.refreshSourceInventory(app.alloc) catch |err| {
                    debug_trace.logf("auth", "startup source inventory refresh failed err={s}", .{@errorName(err)});
                };
            }
            const startup_auth_view = app.auth.view();
            if (startup_auth_view.active_source == null and !startup_auth_view.onboarding_skipped) {
                app.auth.openOnboardingPicker(app.alloc);
            }
            if (comptime @hasField(App, "terminal_input_runtime") and @hasField(App, "terminal")) {
                // Own theme protocol bytes even under FX_THEME; probing stays gated.
                app.terminal_input_runtime.terminal_theme_monitor.start();
                if (startup.theme_monitor_enabled) {
                    app.terminal.enableThemeNotifications() catch |err| {
                        debug_trace.logf("theme", "theme_notification_enable_failed err={s}", .{@errorName(err)});
                    };
                    app.terminal.requestThemeColorScheme() catch |err| {
                        debug_trace.logf("theme", "theme_color_scheme_query_failed err={s}", .{@errorName(err)});
                    };
                }
            }
            var prompt_history_unavailable = false;
            if (comptime @hasField(App, "prompt_history")) {
                prompt_history_unavailable =
                    (try app.prompt_history.initialize(
                        app.alloc,
                        shared_io.getenv("HOME"),
                        startup.prompt_history_enabled,
                        startup.prompt_history_store_allowed,
                    )) == .unavailable;
            }
            if (comptime @hasField(App, "session") and
                @hasDecl(@TypeOf(app.session), "initializeProfileUsage"))
            {
                _ = try app.session.initializeProfileUsage(
                    app.alloc,
                    shared_io.getenv("HOME"),
                );
            }

            var selected_model = startup.takeSelectedModel();
            defer if (selected_model.len > 0) app.alloc.free(selected_model);
            if (comptime @hasField(App, "provider_selection")) {
                app.provider_selection.adoptOwned(startup.provider, &selected_model);
            } else {
                try provider_runtime.replaceModel(app, selected_model);
            }
            const active_model = provider_runtime.model(app);
            try deps.configure_session_preferences(
                app,
                startup.provider,
                startup.configured_model,
                startup.model_source,
                active_model,
                startup.effort,
                startup.fast_mode,
            );
            app.permission_engine.mode = startup.permission_mode;
            app.permission_engine.replaceRules(app.alloc, startup.takePermissionRules());
            app.agent_step_limit = startup.agent_step_limit;
            app.worker.agent_turn_settings.max_tool_result_bytes = startup.max_tool_result_bytes;
            if (comptime @hasField(App, "context_limits")) app.context_limits = startup.context_limits;
            app.worker.agent_turn_settings.first_call_tool_choice = startup.first_call_tool_choice;
            app.worker.agent_turn_settings.fast_mode = startup.fast_mode;
            app.worker.agent_turn_settings.effort = startup.effort;
            app.context_enabled = startup.context_enabled;
            app.fast_mode = startup.fast_mode;
            app.input_runtime.slash_menu_categories = startup.slash_menu_categories;
            app.shell.collapse_tool_calls = startup.collapse_tool_calls;
            app.auto_upgrade_enabled = startup.auto_upgrade;
            app.upgrader.configure_channel(startup.update_channel);
            app.effort = startup.effort;
            app.shell.setCommandOutputRenderPolicy(
                app_render_runtime.Runtime(App).shellStyles(),
            );
            app.permission_state.yolo_acknowledged = startup.yolo_acknowledged;
            app_permission_runtime.Runtime(App).initializeYoloWarning(app);
            app.statusline_context = startup.statusline_context;
            app.statusline_session = startup.statusline_session;
            if (comptime @hasField(App, "workspace_identity")) {
                app.workspace_identity.enabled = startup.statusline_workspace;
            }
            if (comptime @hasDecl(App, "setNotificationPreferences")) {
                app.setNotificationPreferences(
                    startup.notification_turn_end,
                    startup.notification_attention_required,
                    startup.notification_max,
                );
            }
            try deps.initialize_persistence(
                app,
                app.requested_resume != null,
            );
            const staged_resume_view = if (app.requested_resume != null)
                deps.stage_requested_resume_view(app)
            else
                app_session_runtime.ResumeViewStage.none;
            const profile_mcp = try deps.load_mcp_runtime(
                app.alloc,
                app.workspace_root,
                .{ .form = true, .url = true },
            );
            if (comptime @hasDecl(App, "installInitialMcpRuntime")) {
                app.installInitialMcpRuntime(profile_mcp);
            } else {
                app.mcp_runtime = profile_mcp;
            }

            const loaded = try deps.load_skills(
                std.heap.c_allocator,
                app.workspace_root,
                deps.skill_root_policy,
            );
            skill_runtime.traceDiagnostics("interactive_startup", loaded.diagnostics);
            app.skills.replaceLoaded(std.heap.c_allocator, loaded.dir, loaded.skills, loaded.diagnostics);

            if (app.requested_resume == null) {
                const welcome_message = try deps.welcome_message(app.alloc);
                defer app.alloc.free(welcome_message);
                var welcome_preview_buf: [96]u8 = undefined;
                const welcome_preview = debug_trace.terminalPreview(welcome_preview_buf[0..], welcome_message);
                debug_trace.logf(
                    "paint",
                    "welcome_write bytes={d} reserved_rows={d} has_version={s} has_help={s} has_feedback={s} preview=\"{s}\"",
                    .{
                        welcome_message.len,
                        ui_render.welcome_message_reserved_rows,
                        if (std.mem.find(u8, welcome_message, " v") != null) "true" else "false",
                        if (std.mem.find(u8, welcome_message, "Run /help") != null) "true" else "false",
                        if (std.mem.find(u8, welcome_message, "Feedback?") != null) "true" else "false",
                        welcome_preview,
                    },
                );
                try app.writeTranscriptClassified(welcome_message, true, .welcome);
                if (comptime @hasDecl(App, "presentProjectMcpPrompt")) {
                    try app.presentProjectMcpPrompt();
                }
            }
            if (app.skills.diagnostics.len > 0) {
                var notice_writer: std.Io.Writer.Allocating = .init(app.alloc);
                defer notice_writer.deinit();
                skill_runtime.writeDiagnosticSummary(app.alloc, &notice_writer.writer, app.skills.diagnostics) catch return error.OutOfMemory;
                const skills_body = notice_writer.toOwnedSlice() catch return error.OutOfMemory;
                defer app.alloc.free(skills_body);
                if (comptime @hasField(App, "session") and @hasDecl(@TypeOf(app.session), "claimContextNotice")) {
                    _ = try app.session.claimContextNotice(app.alloc, skills_body);
                }

                const skills_summary = try std.fmt.allocPrint(app.alloc, "{d} discovery issue{s}; some skills may be missing", .{
                    app.skills.diagnostics.len,
                    if (app.skills.diagnostics.len == 1) "" else "s",
                });
                defer app.alloc.free(skills_summary);
                try writeCollapsedStartupNotice(app, "skills", skills_summary, skills_body);
            }
            if (comptime @hasField(App, "auth")) {
                const auth_view = app.auth.view();
                if (auth_view.active_source == null and auth_view.stored_key_status == .unavailable) {
                    debug_trace.logf("keychain", "interactive read skipped", .{});
                    try app.writeDomainNotice(.{
                        .topic = "keychain",
                        .tone = .warning,
                        .body = "fx could not access " ++ credentials.stored_key_backend_label ++ ". Continuing without an API key.",
                    }, true);
                }
            }
            var recording = try record_tape.captureStatus(app.alloc);
            defer recording.deinit(app.alloc);
            if (recording == .active) {
                const recording_body = try std.fmt.allocPrint(
                    app.alloc,
                    "visual terminal capture: {s}\nvisible terminal content, including typed prompt text, is recorded",
                    .{recording.active},
                );
                defer app.alloc.free(recording_body);
                try app.writeDomainNotice(.{
                    .topic = "recording",
                    .tone = .warning,
                    .body = recording_body,
                }, true);
            }
            {
                var detail_writer: std.Io.Writer.Allocating = .init(app.alloc);
                defer detail_writer.deinit();
                var reported: usize = 0;
                for (startup.config_diagnostics) |diagnostic| {
                    if (!diagnostic.reportAtStartup()) continue;
                    if (reported > 0) try detail_writer.writer.writeByte('\n');
                    try detail_writer.writer.print(
                        "{s}: {s}",
                        .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
                    );
                    try config_runtime.writeDiagnosticMetadata(&detail_writer.writer, diagnostic);
                    reported += 1;
                }
                if (reported > 0) {
                    const summary = try std.fmt.allocPrint(app.alloc, "{d} configuration issue{s}", .{
                        reported,
                        if (reported == 1) "" else "s",
                    });
                    defer app.alloc.free(summary);
                    try writeCollapsedStartupNotice(app, "config", summary, detail_writer.written());
                }
            }
            if (comptime @hasField(App, "prompt_history")) {
                if (prompt_history_unavailable) {
                    try app.writeDomainNotice(.{
                        .topic = "history",
                        .tone = .warning,
                        .body = "durable prompt history unavailable",
                    }, true);
                } else {
                    app_input_runtime.Runtime(App).loadAndInstallPromptHistory(
                        app,
                    ) catch |err| {
                        app.prompt_history.writes_available = false;
                        debug_trace.logf(
                            "prompt_history",
                            "startup load failed err={s}",
                            .{@errorName(err)},
                        );
                        const history_body = try std.fmt.allocPrint(
                            app.alloc,
                            "failed to load durable prompt history ({s})",
                            .{@errorName(err)},
                        );
                        defer app.alloc.free(history_body);
                        try app.writeDomainNotice(.{
                            .topic = "history",
                            .tone = .warning,
                            .body = history_body,
                        }, true);
                    };
                }
            }

            if (app.requested_resume == null) {
                try deps.begin_fresh_persisted_session(app);
                deps.enable_session_stores(app);
                app_session_runtime.Runtime(App).syncTerminalTitleWith(app, deps.terminal_title);
            }

            switch (staged_resume_view) {
                .none => {},
                .ready => |entry_id| try deps.publish_staged_resume_view(app, entry_id),
            }
            app.shell.render_requests.request(.first_frame);
        }
    };
}

const TestCapture = struct {
    alloc: Allocator,
    bootstrap_calls: usize = 0,
    footer_rows: u16 = 0,
    default_model: []const u8 = "",
    default_agent_step_limit: usize = 0,
    fx_version: []const u8 = "",
    configured_model: [64]u8 = undefined,
    configured_model_len: usize = 0,
    configured_model_source: config_runtime.ModelSource = .compiled_default,
    runtime_model: [64]u8 = undefined,
    runtime_model_len: usize = 0,
    configured_effort: types.ReasoningEffort = .auto,
    configured_fast_mode: bool = false,
    initialize_required: bool = false,
    load_skills_workspace: []const u8 = "",
    load_skills_workspace_root_count: usize = 0,
    load_skills_global_root_count: usize = 0,
    transcript_recorded: bool = false,
    begin_calls: usize = 0,
    enable_calls: usize = 0,
    title: [64]u8 = undefined,
    title_len: usize = 0,
    bootstrap_error: ?anyerror = null,
    bootstrap_init_backing_before_error: bool = false,
    load_skills_error: ?app_runtime_setup.LoadSkillsError = null,
    emit_skill_diagnostic: bool = false,
    emit_config_diagnostics: bool = false,
    startup_with_credential: bool = true,
    onboarding_skipped: bool = true,
    early_notice_palette_initialized: bool = false,
    events: [16][]const u8 = undefined,
    event_count: usize = 0,

    fn init(alloc: Allocator) TestCapture {
        return .{ .alloc = alloc };
    }

    fn titleText(self: *const TestCapture) []const u8 {
        return self.title[0..self.title_len];
    }

    fn configuredModel(self: *const TestCapture) []const u8 {
        return self.configured_model[0..self.configured_model_len];
    }

    fn runtimeModel(self: *const TestCapture) []const u8 {
        return self.runtime_model[0..self.runtime_model_len];
    }

    fn recordEvent(self: *TestCapture, event: []const u8) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    fn eventSlice(self: *const TestCapture) []const []const u8 {
        return self.events[0..self.event_count];
    }
};

var active_capture: ?*TestCapture = null;

const TestApp = struct {
    pub const app_version = "0.2.10-test";

    alloc: Allocator,
    terminal: shell_runtime.TerminalState = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    metrics: types.Metrics = .{},
    workspace_root: []u8 = &.{},
    auth: auth_runtime.Runtime = .{},
    selected_model: std.ArrayList(u8) = .empty,
    permission_engine: permissions.PermissionEngine = .{},
    agent_step_limit: usize = 0,
    worker: worker_runtime.WorkerRuntime = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: ui_input.Runtime = .{},
    context_enabled: bool = true,
    fast_mode: bool = false,
    auto_upgrade_enabled: bool = true,
    upgrader: auto_upgrade.AutoUpgrade = .{},
    effort: types.ReasoningEffort = .auto,
    permission_state: app_permission_runtime.State = .{},
    statusline_context: bool = false,
    statusline_session: bool = false,
    workspace_identity: statusline_identity.Runtime = .{},
    requested_resume: ?u8 = null,
    mcp_runtime: ?*mcp_runtime.McpRuntime = null,
    skills: skill_runtime.Runtime = .{},
    transcript: std.ArrayList(u8) = .empty,
    transcript_recorded: bool = false,
    begin_fresh_called: bool = false,
    deinit_calls: usize = 0,

    fn init(alloc: Allocator) TestApp {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *TestApp) void {
        self.deinit_calls += 1;
        if (self.workspace_root.len > 0) {
            self.alloc.free(self.workspace_root);
            self.workspace_root = &.{};
        }
        self.auth.deinit(self.alloc);
        self.workspace_identity.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        if (self.mcp_runtime) |runtime| {
            runtime.deinit();
            self.alloc.destroy(runtime);
            self.mcp_runtime = null;
        }
        self.skills.deinit(std.heap.c_allocator);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
    }

    fn writeTranscript(self: *TestApp, text: []const u8, record: bool) !void {
        self.transcript_recorded = record;
        try self.transcript.appendSlice(self.alloc, text);
        active_capture.?.recordEvent("welcome");
    }

    fn writeTranscriptClassified(self: *TestApp, text: []const u8, record: bool, class: transcript_runtime.RawEntryClass) !void {
        _ = class;
        try self.writeTranscript(text, record);
    }

    fn writeDomainNotice(self: *TestApp, semantic_notice: types.SemanticNotice, record: bool) !void {
        const styles = self.shell.retainedTranscriptStyles();
        active_capture.?.early_notice_palette_initialized =
            styles.notice_information_style.len > 0 and
            styles.system_notice_text_style.len > 0 and
            styles.reset_style.len > 0;
        const notice = if (semantic_notice.topic.len > 0)
            try std.fmt.allocPrint(self.alloc, "● {c}{s}: {s}{s}\n", .{
                std.ascii.toUpper(semantic_notice.topic[0]),
                semantic_notice.topic[1..],
                semantic_notice.body,
                if (semantic_notice.visibility == .full_only) " [full-only]" else "",
            })
        else
            try std.fmt.allocPrint(self.alloc, "● {s}{s}\n", .{
                semantic_notice.body,
                if (semantic_notice.visibility == .full_only) " [full-only]" else "",
            });
        defer self.alloc.free(notice);
        try self.writeTranscriptClassified(notice, record, .subagent_status);
    }
};

fn setTerminalTitleLabelForTest(_: ?*anyopaque, label: []const u8) void {
    const capture = active_capture.?;
    capture.title_len = @min(label.len, capture.title.len);
    @memcpy(capture.title[0..capture.title_len], label[0..capture.title_len]);
    capture.recordEvent("title");
}

fn clearTerminalTitleForTest(_: ?*anyopaque) void {
    const capture = active_capture.?;
    capture.title_len = 0;
    capture.recordEvent("title_clear");
}
