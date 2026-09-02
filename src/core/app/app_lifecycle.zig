const std = @import("std");
const io_mod = @import("../shared/io.zig");
const agent_steps = @import("../config/agent_steps.zig");
const config_runtime = @import("../config/config_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const host = @import("../hosts/host.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const record_tape = @import("../workspace/record_tape.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const update_target = @import("../upgrade/update_target.zig");
const notification_sound = @import("../notifications/sound.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");
const ui_render = @import("../../ui/render.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const ui_terminal = @import("../../ui/terminal/terminal.zig");
const terminal_diff = @import("../../ui/render_engine/terminal_diff.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const PermissionMode = types.PermissionMode;
const CursorPosition = shell_runtime.CursorPosition;
const TerminalState = shell_runtime.TerminalState;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
pub const ResizeHandler = shell_runtime.ResizeHandler;
pub const default_permission_mode = config_runtime.default_permission_mode;

/// Compile-time terminal restoration for one async-signal-safe `write(2)` call.
/// Resets terminal modes and ends with a newline before the next shell prompt.
const abnormal_exit_restore_prefix = "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[?1049l\x1b[?7h\x1b[4l\x1b[?6l\x1b[0m\x1b[?25h\x1b[?2031l\x1b[?2004l";
const abnormal_exit_restore = abnormal_exit_restore_prefix ++ "\x1b[<u\x1b[>4;0m\n";
const tmux_abnormal_exit_restore = abnormal_exit_restore_prefix ++ "\x1b[>4;0m\n";
const normal_exit_restore_prefix = ui_terminal.theme_notification_disable_sequence ++ "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[4l\x1b[?6l\x1b[?2004l";
const normal_exit_restore = normal_exit_restore_prefix ++ "\x1b[<u\x1b[>4;0m";
const tmux_normal_exit_restore = normal_exit_restore_prefix ++ "\x1b[>4;0m";
const alternate_screen_enter = "\x1b[?1049h";
const alternate_mouse_tracking_enter = "\x1b[?1000h\x1b[?1006h";
const terminal_takeover_reset = "\x1b[?2026l\x1b[?1000l\x1b[?1002l\x1b[?1004l\x1b[?1006l\x1b[?1l\x1b>\x1b[?2004l\x1b[<u\x1b[>4;0m\x1b[4l\x1b[?6l\x1b[?7h\x1b[0m\x1b[?25h";

/// Original handlers, written at bootstrap and restored at shutdown.
/// Signal context never mutates them.
var old_sigterm_action: ?std.posix.Sigaction = null;
var old_sighup_action: ?std.posix.Sigaction = null;

/// Restores terminal state, installs the default disposition, and re-raises.
/// Must remain async-signal-safe: only `write(2)`, `sigaction(2)`, and `raise(3)`.
fn abnormalExitHandlerWithRestore(comptime restore: []const u8, sig: std.posix.SIG) void {
    // Signal context cannot recover from a failed async-signal-safe write.
    _ = std.c.write(
        std.posix.STDOUT_FILENO,
        restore.ptr,
        restore.len,
    );

    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &default_action, null);
    _ = std.c.raise(sig);
}

fn abnormalExitHandler(sig: std.posix.SIG) callconv(.c) void {
    abnormalExitHandlerWithRestore(abnormal_exit_restore, sig);
}

fn tmuxAbnormalExitHandler(sig: std.posix.SIG) callconv(.c) void {
    abnormalExitHandlerWithRestore(tmux_abnormal_exit_restore, sig);
}

/// Install handlers for SIGTERM and SIGHUP so an externally-terminated
/// fx restores terminal state before dying. SIGINT is not included
/// because raw mode disables terminal-generated SIGINT.
pub fn installAbnormalExitHandlers(tmux: ?[]const u8) void {
    if (!shell_runtime.supports_resize_signal) return;

    const handler: std.posix.Sigaction.handler_fn = if (tmux == null)
        abnormalExitHandler
    else
        tmuxAbnormalExitHandler;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, &act, &old_term);
    old_sigterm_action = old_term;

    var old_hup: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.HUP, &act, &old_hup);
    old_sighup_action = old_hup;
}

pub fn uninstallAbnormalExitHandlers() void {
    if (!shell_runtime.supports_resize_signal) return;

    if (old_sigterm_action) |old| {
        std.posix.sigaction(std.posix.SIG.TERM, &old, null);
        old_sigterm_action = null;
    }
    if (old_sighup_action) |old| {
        std.posix.sigaction(std.posix.SIG.HUP, &old, null);
        old_sighup_action = null;
    }
}

pub const StartupState = struct {
    workspace_root: []u8 = &.{},
    workspace_access: workspace_access.WorkspaceAccess = .{},
    credential: ?credentials.Credential = null,
    credential_onboarding_skipped: bool = false,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    provider: model_provider.ProviderId = .gateway,
    selected_model: []u8 = &.{},
    configured_model: []u8 = &.{},
    model_source: config_runtime.ModelSource = .compiled_default,
    permission_mode: PermissionMode = default_permission_mode,
    yolo_acknowledged: bool = false,
    permission_rules: types.PermissionRuleSet = .{},
    agent_step_limit: usize,
    max_tool_result_bytes: usize = tool_result_limits.default_max_tool_result_bytes,
    context_limits: config_runtime.context_limits.Values = .{},
    context_enabled: bool = true,
    fast_mode: bool = false,
    fast_mode_source: config_runtime.ConfigSource = .compiled_default,
    slash_menu_categories: bool = true,
    collapse_tool_calls: bool = false,
    auto_upgrade: bool = true,
    update_channel: update_target.Channel = .stable,
    startup_scrollback: bool = true,
    prompt_history_enabled: bool = true,
    prompt_history_store_allowed: bool = true,
    config_diagnostics: []config_runtime.ConfigDiagnostic = &.{},
    effort: types.ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    statusline_context: bool = false,
    statusline_session: bool = false,
    statusline_workspace: bool = false,
    notification_turn_end: bool = false,
    notification_attention_required: bool = false,
    notification_max: bool = false,
    theme_monitor_enabled: bool = false,

    pub fn deinit(self: *StartupState, alloc: Allocator) void {
        self.workspace_access.deinit(alloc);
        if (self.workspace_root.len > 0) alloc.free(self.workspace_root);
        if (self.credential) |*credential| credential.deinit(alloc);
        if (self.selected_model.len > 0) alloc.free(self.selected_model);
        if (self.configured_model.len > 0) alloc.free(self.configured_model);
        self.permission_rules.deinit(alloc);
        if (self.config_diagnostics.len > 0) {
            for (self.config_diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.config_diagnostics);
        }
        self.* = .{ .agent_step_limit = self.agent_step_limit };
    }

    pub fn takeWorkspaceRoot(self: *StartupState) []u8 {
        const value = self.workspace_root;
        self.workspace_root = &.{};
        return value;
    }

    pub fn takeWorkspaceAccess(self: *StartupState) workspace_access.WorkspaceAccess {
        const value = self.workspace_access;
        self.workspace_access = .{};
        return value;
    }

    pub fn apiKey(self: *const StartupState) ?[]const u8 {
        const credential = self.credential orelse return null;
        if (credential.needsRefreshAt(io_mod.milliTimestamp())) return null;
        return credential.token;
    }

    pub fn modelCatalogAccess(self: *const StartupState) credentials.CatalogAccess {
        return credentials.catalogAccessAt(self.credential, io_mod.milliTimestamp());
    }

    pub fn gatewayTeam(self: *const StartupState) ?[]const u8 {
        const credential = self.credential orelse return null;
        if (credential.needsRefreshAt(io_mod.milliTimestamp())) return null;
        return credential.gatewayTeam();
    }

    pub fn takeCredential(self: *StartupState) ?credentials.Credential {
        const value = self.credential;
        self.credential = null;
        return value;
    }

    pub fn takeSelectedModel(self: *StartupState) []u8 {
        const value = self.selected_model;
        self.selected_model = &.{};
        return value;
    }

    pub fn takePermissionRules(self: *StartupState) types.PermissionRuleSet {
        const value = self.permission_rules;
        self.permission_rules = .{};
        return value;
    }
};

pub const StartupStatus = struct {
    workspace_root: []u8,
    provider: model_provider.ProviderId = .gateway,
    selected_model: []const u8,
    owned_selected_model: ?[]u8 = null,
    auth: auth_runtime.StatusSnapshot = .{},
    permission_mode: PermissionMode,
    agent_step_limit: usize,
    update_channel: update_target.Channel = .stable,
    config_diagnostics: []config_runtime.ConfigDiagnostic = &.{},

    pub fn deinit(self: *StartupStatus, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        if (self.owned_selected_model) |model| alloc.free(model);
        self.auth.deinit(alloc);
        if (self.config_diagnostics.len > 0) {
            for (self.config_diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.config_diagnostics);
        }
        self.* = undefined;
    }
};

const StartupStatusModel = struct {
    value: []const u8,
    owned: ?[]u8 = null,
};

pub const BootstrapConfig = struct {
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    terminal_title: host.TerminalTitle,
    footer_rows: u16,
    startup_min_body_rows: u16 = 0,
    default_model: []const u8,
    default_agent_step_limit: usize,
    secret_store: host.SecretStore,
    resize_handler: ResizeHandler,
    fx_version: []const u8 = "",
    record_requested: bool = false,
};

pub fn loadStartupState(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, transport, secret_store, workspace_root, default_model, default_agent_step_limit, null, .refresh_if_needed);
}

pub fn loadStartupStateWithoutCredentials(alloc: Allocator, default_model: []const u8, default_agent_step_limit: usize) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, workspace_root, default_model, default_agent_step_limit, null, null);
}

pub fn loadEmbeddedStartupState(
    alloc: Allocator,
    home_dir: []const u8,
    workspace_root: []const u8,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupState {
    const owned_workspace_root = try io_mod.realpathAlloc(alloc, workspace_root);
    return loadStartupStateFromOwnedWorkspace(
        alloc,
        oauth_transport.unavailable_provider,
        host.unavailable_secret_store,
        owned_workspace_root,
        default_model,
        default_agent_step_limit,
        home_dir,
        null,
    );
}

pub fn loadCatalogStartupState(
    alloc: Allocator,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupState {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, secret_store, workspace_root, default_model, default_agent_step_limit, null, .stored);
}

pub fn loadStartupStatus(
    alloc: Allocator,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !StartupStatus {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    errdefer alloc.free(workspace_root);
    debug_trace.configureFromEnv(alloc, workspace_root);

    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, workspace_root);
    defer detailed.deinit(alloc);
    const settings = &detailed.settings;

    const configured_selection = try configuredProviderSelection(default_model, settings);
    const selected_model = try loadStartupStatusModel(alloc, configured_selection.model, null);
    errdefer if (selected_model.owned) |model| alloc.free(model);

    var auth_status = try auth_runtime.loadStatusSnapshotForProvider(
        alloc,
        secret_store,
        configured_selection.provider,
        settings.credential_source,
    );
    errdefer auth_status.deinit(alloc);

    const result = StartupStatus{
        .workspace_root = workspace_root,
        .provider = configured_selection.provider,
        .selected_model = selected_model.value,
        .owned_selected_model = selected_model.owned,
        .auth = auth_status,
        .permission_mode = loadPermissionMode(settings.permission_mode),
        .agent_step_limit = loadAgentStepLimit(default_agent_step_limit, settings.max_agent_steps),
        .update_channel = settings.update_channel orelse .stable,
        .config_diagnostics = detailed.diagnostics,
    };
    auth_status.owned_team = null;
    detailed.diagnostics = &.{};
    return result;
}

pub fn applyWorkspaceLaunch(
    self: *StartupState,
    alloc: Allocator,
    command_line_directories: []const []const u8,
    saved_suppressed: bool,
) !void {
    try self.workspace_access.applyLaunch(
        alloc,
        self.workspace_root,
        command_line_directories,
        saved_suppressed,
    );
}

fn loadStartupStateForWorkspace(alloc: Allocator, workspace_root: []const u8, default_model: []const u8, default_agent_step_limit: usize) !StartupState {
    const owned_workspace_root = try alloc.dupe(u8, workspace_root);
    return loadStartupStateFromOwnedWorkspace(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, owned_workspace_root, default_model, default_agent_step_limit, null, null);
}

const CredentialLoadMode = credentials.LoadMode;

fn loadStartupStateFromOwnedWorkspace(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    owned_workspace_root: []u8,
    default_model: []const u8,
    default_agent_step_limit: usize,
    profile_home: ?[]const u8,
    credential_mode: ?CredentialLoadMode,
) !StartupState {
    var state = StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);

    state.workspace_root = owned_workspace_root;
    debug_trace.configureFromEnv(alloc, state.workspace_root);
    var detailed = if (profile_home) |home_dir|
        try config_runtime.loadMergedSettingsDetailedFromHome(alloc, home_dir, state.workspace_root)
    else
        try config_runtime.loadMergedSettingsDetailed(alloc, state.workspace_root);
    defer detailed.deinit(alloc);
    const settings = &detailed.settings;

    state.workspace_access = try workspace_access.WorkspaceAccess.init(
        alloc,
        state.workspace_root,
        detailed.additional_directory_sources orelse &.{},
        &.{},
        false,
    );

    const configured_selection = try configuredProviderSelection(default_model, settings);
    state.provider = configured_selection.provider;
    state.configured_model = try alloc.dupe(u8, configured_selection.model);
    state.model_source = detailed.model_source orelse .compiled_default;
    state.selected_model = try loadInitialModel(alloc, configured_selection.model, null);
    if (hasProcessModelOverride()) state.model_source = .process_override;
    state.config_diagnostics = detailed.diagnostics;
    detailed.diagnostics = &.{};
    state.prompt_history_enabled = settings.prompt_history_enabled orelse true;
    state.prompt_history_store_allowed = detailed.prompt_history_store_allowed;
    if (credential_mode) |mode| {
        const resolution = try credentials.resolveForProvider(
            alloc,
            transport,
            secret_store,
            mode,
            state.provider,
            settings.credential_source,
        );
        state.credential = resolution.credential;
        state.stored_key_status = resolution.stored_key_status;
    }
    state.permission_mode = loadPermissionMode(settings.permission_mode);
    state.yolo_acknowledged = settings.yolo_acknowledged orelse false;
    state.permission_rules = try types.dupePermissionRuleSet(alloc, settings.permission_rules);
    state.agent_step_limit = loadAgentStepLimit(default_agent_step_limit, settings.max_agent_steps);
    state.max_tool_result_bytes = tool_result_limits.resolveMaxToolResultBytes(settings.max_tool_result_bytes, tool_result_limits.default_max_tool_result_bytes);
    state.context_limits = config_runtime.resolveContextLimits(settings, &.{});
    state.context_enabled = settings.context orelse true;
    state.fast_mode = settings.fast_mode orelse
        (state.provider == .gateway and state.model_source == .compiled_default);
    state.fast_mode_source = detailed.sources.fast_mode;
    state.slash_menu_categories = settings.slash_menu_categories orelse true;
    state.collapse_tool_calls = settings.collapse_tool_calls orelse false;
    state.auto_upgrade = settings.auto_upgrade orelse true;
    state.update_channel = settings.update_channel orelse .stable;
    state.startup_scrollback = settings.startup_scrollback orelse true;
    state.effort = settings.effort orelse .auto;
    state.first_call_tool_choice = settings.first_call_tool_choice orelse .auto;
    state.statusline_context = settings.statusline_context orelse false;
    state.statusline_session = settings.statusline_session orelse false;
    state.statusline_workspace = settings.statusline_workspace orelse false;
    const sound_override = soundEnvOverride();
    const sound_on_override: ?bool = if (sound_override) |level| level != .off else null;
    const max_override: ?bool = if (sound_override) |level| level == .max else null;
    state.notification_turn_end = sound_on_override orelse settings.notification_turn_end orelse notification_sound.default_enabled;
    state.notification_attention_required = sound_on_override orelse settings.notification_attention_required orelse notification_sound.default_enabled;
    state.notification_max = max_override orelse settings.notification_max orelse false;

    return state;
}

pub fn bootstrapInteractiveApp(cfg: BootstrapConfig) !StartupState {
    try cfg.terminal.ensureInteractive();
    try cfg.terminal.captureOriginalTermios();

    cfg.shell.sync_updates_enabled = shell_runtime.detectSyncUpdatesEnabled(cfg.alloc);
    cfg.shell.history_reset_uses_ris = shell_runtime.detectHistoryResetUsesRis(cfg.alloc);
    cfg.shell.layout = minimalLayout();
    try cfg.shell.initBacking(cfg.alloc);

    var state = try loadCatalogStartupState(
        cfg.alloc,
        cfg.secret_store,
        cfg.default_model,
        cfg.default_agent_step_limit,
    );
    errdefer state.deinit(cfg.alloc);

    state.credential_onboarding_skipped = credentialOnboardingDisabled();

    errdefer shutdownInteractiveShell(
        cfg.terminal,
        cfg.shell,
        cfg.metrics,
        cfg.terminal_title,
    );

    try cfg.terminal.enableRawMode();
    cfg.terminal.installResizeSignal(cfg.resize_handler);
    installAbnormalExitHandlers(io_mod.getenv("TMUX"));
    cfg.shell.layout = try cfg.terminal.queryLayout(cfg.footer_rows);

    record_tape.configureFromEnv(
        cfg.alloc,
        state.workspace_root,
        cfg.shell.layout.cols,
        cfg.shell.layout.rows,
        cfg.fx_version,
        cfg.record_requested,
    ) catch |err| {
        debug_trace.logf("record", "startup recording failed err={s}", .{@errorName(err)});
        return error.RecordingStartFailed;
    };

    // The shadow VT is load-bearing: frame commit diffs the target
    // surface against it and records the accepted terminal state.
    try cfg.shell.enableShadowVt(cfg.alloc);

    ui_render.setTruecolorSupport(ui_render.truecolorSupportedForValues(
        io_mod.getenv("COLORTERM"),
        io_mod.getenv("TERM_PROGRAM"),
    ));
    const theme = ui_render.detectTheme(cfg.alloc, cfg.terminal);
    ui_render.initTheme(theme.light, theme.rgb);
    state.theme_monitor_enabled = ui_render.explicitThemeOverride() == null;

    const cursor = cfg.terminal.queryCursorPosition() catch blk: {
        break :blk CursorPosition{
            .row = cfg.shell.layout.content_bottom,
            .col = 1,
        };
    };
    const start_row = blk: {
        var row = cursor.row;
        if (cursor.col > 1 and row < cfg.shell.layout.rows) row += 1;
        break :blk row;
    };
    var launch_start_row = start_row;
    const effective_startup_min_body_rows = try prepareStartupViewport(
        cfg.shell,
        cfg.metrics,
        &launch_start_row,
        cfg.startup_min_body_rows,
        state.startup_scrollback,
    );
    // Enable keyboard/paste protocol modes and disable autowrap for the
    // interactive session. Shutdown restores each mode.
    try enableInteractiveTerminalModes(cfg.shell, cfg.metrics);
    try cfg.shell.initViewportWithReservedRows(cfg.metrics, launch_start_row, effective_startup_min_body_rows);

    return state;
}

fn prepareStartupViewport(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    launch_start_row: *u16,
    startup_min_body_rows: u16,
    startup_scrollback: bool,
) !u16 {
    if (startup_scrollback and launch_start_row.* > 1) {
        try pushLaunchRowsIntoScrollback(shell, metrics, launch_start_row.* - 1);
        launch_start_row.* = 1;
    } else if (shell.layout.content_bottom > 0) {
        const reserve_rows = @min(startup_min_body_rows, shell.layout.content_bottom);
        const max_start_row = if (reserve_rows > 0)
            shell.layout.content_bottom - reserve_rows + 1
        else
            shell.layout.content_bottom;
        if (launch_start_row.* > max_start_row) {
            try pushLaunchRowsIntoScrollback(shell, metrics, launch_start_row.* - max_start_row);
            launch_start_row.* = max_start_row;
        }
    }
    return startup_min_body_rows;
}

fn pushLaunchRowsIntoScrollback(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    rows: u16,
) !void {
    if (rows == 0 or shell.layout.rows == 0) return;
    debug_trace.logf("render", "launch_scrollback_push rows={d} cols={d} content_bottom={d}", .{
        rows,
        shell.layout.cols,
        shell.layout.content_bottom,
    });
    var cursor_buf: [32]u8 = undefined;
    const cursor = try ui_terminal.moveCursorSequence(&cursor_buf, shell.layout.rows, 1);
    try writeLifecycleTerminalBytes(shell, metrics, cursor);

    var newlines: [64]u8 = undefined;
    @memset(newlines[0..], '\n');
    var remaining = rows;
    while (remaining > 0) {
        const count: u16 = @min(remaining, newlines.len);
        try writeLifecycleTerminalBytes(shell, metrics, newlines[0..count]);
        remaining -= count;
    }
}

pub fn shutdownInteractiveShell(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    terminal_title: host.TerminalTitle,
) void {
    leaveAlternateScreens(terminal, shell, metrics);
    terminal.uninstallResizeSignal();
    uninstallAbnormalExitHandlers();
    _ = writeLifecycleTerminalBytes(shell, metrics, normalExitRestoreSequence(io_mod.getenv("TMUX"))) catch {};
    terminal_title.clear();
    record_tape.shutdown();
    finishLeavingInteractiveMode(terminal, shell, metrics);
}

/// Cooked-mode handoff for Ctrl-Z / SIGTSTP. Same terminal restore as
/// shutdown, but keeps signal handlers, title, and recording so resume can
/// continue the same session.
fn suspendTerminalForJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) void {
    leaveAlternateScreens(terminal, shell, metrics);
    _ = writeLifecycleTerminalBytes(shell, metrics, normalExitRestoreSequence(io_mod.getenv("TMUX"))) catch {};
    finishLeavingInteractiveMode(terminal, shell, metrics);
}

/// Raise SIGTSTP after restoring cooked mode; on SIGCONT rebuild interactive
/// terminal state and request a full repaint. Platforms without job-control
/// signals (same set as `supports_resize_signal`) are a no-op.
pub fn suspendToJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    footer_rows: u16,
) !void {
    if (!shell_runtime.supports_resize_signal) return;

    suspendTerminalForJobControl(terminal, shell, metrics);
    _ = std.c.raise(std.posix.SIG.TSTP);
    try resumeTerminalAfterJobControl(terminal, shell, metrics, footer_rows);
}

fn leaveAlternateScreens(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) void {
    switch (terminal.alternate_screen_owner) {
        .none => {},
        .file_approval => _ = leaveApprovalScreen(terminal, shell, metrics) catch {},
        .full_transcript => _ = leaveFullTranscriptScreen(terminal, shell, metrics) catch {},
        .catalog_menu => _ = leaveCatalogMenuScreen(terminal, shell, metrics) catch {},
        .subagent_manager => _ = leaveSubagentManagerScreen(terminal, shell, metrics) catch {},
        .terminal_session => _ = leaveTerminalSessionScreen(terminal, shell, metrics) catch {},
    }
}

fn finishLeavingInteractiveMode(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) void {
    shell.footer_viewport.eraseCurrentFrame(shell, metrics) catch {};
    terminal.disableRawMode();
    emitShutdownCleanupAndResume(shell, metrics);
}

/// Re-arm raw mode after a job-control continue, re-query layout in case the
/// terminal was resized while stopped, then request a full repaint.
fn resumeTerminalAfterJobControl(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    footer_rows: u16,
) !void {
    shell.layout = terminal.queryLayout(footer_rows) catch shell.layout;
    try terminal.captureOriginalTermios();
    try terminal.enableRawMode();
    try enableInteractiveTerminalModes(shell, metrics);
    try shell.requestTerminalReset(metrics);
    shell.render_requests.request(.first_frame);
}

fn enableInteractiveTerminalModes(shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        ui_terminal.interactiveModeEnableSequence(io_mod.getenv("TMUX")),
    );
}

fn normalExitRestoreSequence(tmux: ?[]const u8) []const u8 {
    return if (tmux == null)
        normal_exit_restore
    else
        tmux_normal_exit_restore;
}

/// Full transcript steady state is `active`: the terminal owns the
/// full-transcript alternate screen and the shell projection is active.
/// The drift states exist only while a recovery or approval handoff path
/// is resolving a partially transitioned screen.
const FullTranscriptLifecycleState = enum {
    inactive,
    active,
    terminal_only,
    projection_only,
};

pub const FullTranscriptApprovalTransition = enum {
    inactive,
    closed,
    handed_off,
};

fn fullTranscriptLifecycleState(
    terminal: *const TerminalState,
    shell: *const TranscriptRuntime,
) FullTranscriptLifecycleState {
    const terminal_active = terminal.fullTranscriptScreenActive();
    const projection_active = shell.fullTranscriptActive();
    if (terminal_active and projection_active) return .active;
    if (terminal_active) return .terminal_only;
    if (projection_active) return .projection_only;
    return .inactive;
}

fn fullTranscriptActive(
    terminal: *const TerminalState,
    shell: *const TranscriptRuntime,
) bool {
    return fullTranscriptStateIsActive(fullTranscriptLifecycleState(terminal, shell));
}

fn fullTranscriptStateIsActive(state: FullTranscriptLifecycleState) bool {
    return state != .inactive;
}

fn fullTranscriptStateOwnsAlternateScreen(state: FullTranscriptLifecycleState) bool {
    return state == .active or state == .terminal_only;
}

fn fullTranscriptStateDrifted(state: FullTranscriptLifecycleState) bool {
    return state == .terminal_only or state == .projection_only;
}

pub fn closeFullTranscriptIfActive(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !bool {
    if (!fullTranscriptActive(terminal, shell)) return false;
    try closeFullTranscript(alloc, terminal, shell, metrics);
    return true;
}

pub fn recoverFullTranscriptDriftBeforeRender(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !bool {
    const state = fullTranscriptLifecycleState(terminal, shell);
    if (!fullTranscriptStateDrifted(state)) return false;

    debug_trace.logf(
        "full_transcript",
        "reconcile_before_render state={s} action=recover_to_inline",
        .{@tagName(state)},
    );
    try closeFullTranscript(alloc, terminal, shell, metrics);
    return true;
}

pub fn transitionFullTranscriptForApproval(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    approval_screen_active: bool,
) !FullTranscriptApprovalTransition {
    const state = fullTranscriptLifecycleState(terminal, shell);
    if (!fullTranscriptStateIsActive(state)) return .inactive;

    if (approval_screen_active and fullTranscriptStateOwnsAlternateScreen(state)) {
        try handoffFullTranscriptToApproval(alloc, terminal, shell, metrics);
        return .handed_off;
    }

    try closeFullTranscript(alloc, terminal, shell, metrics);
    return .closed;
}

pub fn enterApprovalScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try enterAlternateScreen(terminal, shell, metrics, .file_approval);
}

pub fn leaveApprovalScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .file_approval);
}

pub fn approvalInlineRestoreTransition(
    terminal: *const TerminalState,
) terminal_diff.FrameTerminalTransition {
    if (!terminal.fileApprovalScreenActive()) return .none;
    return .{ .restore_normal_screen = .{
        .mouse_tracking_active = terminal.alternate_mouse_tracking_active,
    } };
}

pub fn commitApprovalInlineRestore(terminal: *TerminalState) void {
    if (!terminal.fileApprovalScreenActive()) return;
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .none;
    terminal.alternate_frame_layout = .{};
}

pub fn setApprovalScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    enabled: bool,
) !void {
    try setAlternateScreenMouseTracking(terminal, shell, metrics, .file_approval, enabled);
}

pub fn enterCatalogMenuScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try enterAlternateScreen(terminal, shell, metrics, .catalog_menu);
}

pub fn leaveCatalogMenuScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .catalog_menu);
}

pub fn handoffCatalogMenuToSubagentManager(terminal: *TerminalState) !void {
    if (!terminal.catalogMenuScreenActive()) return error.CatalogMenuScreenNotActive;
    terminal.alternate_screen_owner = .subagent_manager;
    terminal.alternate_frame_layout = .{};
}

pub fn handoffApprovalToSubagentManager(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (!terminal.fileApprovalScreenActive()) return error.ApprovalScreenNotActive;
    try setAlternateScreenMouseTracking(
        terminal,
        shell,
        metrics,
        .file_approval,
        false,
    );
    terminal.alternate_screen_owner = .subagent_manager;
    terminal.alternate_frame_layout = .{};
}

pub fn enterSubagentManagerScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    try enterAlternateScreen(terminal, shell, metrics, .subagent_manager);
}

pub fn leaveSubagentManagerScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .subagent_manager);
}

pub fn enterTerminalSessionScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    try enterAlternateScreen(terminal, shell, metrics, .terminal_session);
    try writeLifecycleTerminalBytes(shell, metrics, terminal_takeover_reset ++ "\x1b[2J\x1b[H");
}

pub fn leaveTerminalSessionScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (!terminal.terminalSessionScreenActive()) return;
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        terminal_takeover_reset ++ ui_terminal.alternate_screen_leave_sequence,
    );
    try enableInteractiveTerminalModes(shell, metrics);
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .none;
    terminal.alternate_frame_layout = .{};
}

/// Transfer the existing alternate buffer directly back to the manager.
/// The child modes are removed before ownership changes, so a failed write
/// leaves terminal-session cleanup armed.
pub fn handoffTerminalSessionToSubagentManager(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (!terminal.terminalSessionScreenActive()) {
        return error.TerminalSessionScreenNotActive;
    }
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        terminal_takeover_reset ++ "\x1b[2J\x1b[H",
    );
    try enableInteractiveTerminalModes(shell, metrics);
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .subagent_manager;
    terminal.alternate_frame_layout = .{};
}

pub fn openFullTranscript(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (terminal.alternate_screen_owner != .none and !terminal.fullTranscriptScreenActive()) {
        return error.AlternateScreenAlreadyOwned;
    }

    try setFullTranscriptProjection(alloc, shell, .full);
    errdefer {
        if (terminal.fullTranscriptScreenActive()) {
            leaveFullTranscriptScreen(terminal, shell, metrics) catch {};
        }
        setFullTranscriptProjection(alloc, shell, .inline_mode) catch {};
    }

    try enterFullTranscriptScreen(terminal, shell, metrics);
}

pub fn closeFullTranscript(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    const primary_restore = shell.fullTranscriptPrimaryRestore();
    debug_trace.logf(
        "full_transcript",
        "close_full_transcript restore={s}",
        .{@tagName(primary_restore)},
    );
    const primary_recovery = if (primary_restore == .changed_resized)
        try shell.prepareRestoredPrimaryTranscriptRecovery(alloc)
    else
        null;
    defer if (primary_recovery) |bytes| alloc.free(bytes);
    if (terminal.fullTranscriptScreenActive()) {
        try leaveFullTranscriptScreen(terminal, shell, metrics);
    }
    try setFullTranscriptProjection(alloc, shell, .inline_mode);
    switch (primary_restore) {
        .changed => {},
        .changed_resized => if (primary_recovery) |bytes| {
            try writeLifecycleTerminalBytes(shell, metrics, bytes);
            shell.repaintRestoredPrimaryTranscriptAfterResize();
        },
        .exact => shell.retainRestoredPrimaryTranscript(),
        .resized => shell.repaintRestoredPrimaryTranscriptAfterResize(),
    }
}

pub fn handoffFullTranscriptToApproval(
    alloc: Allocator,
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
) !void {
    if (!fullTranscriptStateOwnsAlternateScreen(fullTranscriptLifecycleState(terminal, shell))) {
        return error.FullTranscriptScreenNotActive;
    }
    try setFullTranscriptScreenMouseTracking(terminal, shell, metrics, true);
    const from = shell.transcriptPresentationDepth();
    try setFullTranscriptProjection(alloc, shell, .inline_mode);
    debug_trace.logf(
        "full_transcript",
        "depth_transition from={s} to=inline route=root trigger=approval_handoff",
        .{switch (from) {
            .inline_mode => "inline",
            .full => "full",
        }},
    );
    terminal.alternate_screen_owner = .file_approval;
    terminal.alternate_frame_layout = .{};
}

fn setFullTranscriptProjection(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    depth: transcript_presentation.Depth,
) !void {
    _ = try shell.setTranscriptPresentationDepth(alloc, depth);
}

fn enterFullTranscriptScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try enterAlternateScreen(terminal, shell, metrics, .full_transcript);
}

fn leaveFullTranscriptScreen(terminal: *TerminalState, shell: *TranscriptRuntime, metrics: *Metrics) !void {
    try leaveAlternateScreen(terminal, shell, metrics, .full_transcript);
}

fn setFullTranscriptScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    enabled: bool,
) !void {
    try setAlternateScreenMouseTracking(terminal, shell, metrics, .full_transcript, enabled);
}

fn enterAlternateScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
) !void {
    if (terminal.alternate_screen_owner == owner) return;
    if (terminal.alternate_screen_owner != .none) return error.AlternateScreenAlreadyOwned;
    // Keep the flag set if the write fails so shutdown still attempts a restore.
    terminal.alternate_screen_owner = owner;
    terminal.alternate_frame_layout = .{};
    try writeLifecycleTerminalBytes(shell, metrics, alternate_screen_enter);
}

fn leaveAlternateScreen(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
) !void {
    if (terminal.alternate_screen_owner != owner) return;
    const restore = ui_terminal.alternateScreenLeaveSequence(
        terminal.alternate_mouse_tracking_active,
    );
    try writeLifecycleTerminalBytes(shell, metrics, restore);
    terminal.alternate_mouse_tracking_active = false;
    terminal.alternate_screen_owner = .none;
    terminal.alternate_frame_layout = .{};
}

fn setAlternateScreenMouseTracking(
    terminal: *TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    owner: shell_runtime.AlternateScreenOwner,
    enabled: bool,
) !void {
    if (terminal.alternate_screen_owner != owner or
        terminal.alternate_mouse_tracking_active == enabled)
    {
        return;
    }
    if (enabled) {
        // Keep the state armed on an enable write failure so leave/shutdown
        // still attempts to restore the terminal mode.
        terminal.alternate_mouse_tracking_active = true;
        try writeLifecycleTerminalBytes(shell, metrics, alternate_mouse_tracking_enter);
        return;
    }

    // Keep the state armed on a disable failure so leave/shutdown still
    // attempts to restore the terminal mode.
    try writeLifecycleTerminalBytes(
        shell,
        metrics,
        ui_terminal.alternate_mouse_tracking_leave_sequence,
    );
    terminal.alternate_mouse_tracking_active = false;
}

fn emitShutdownCleanupAndResume(shell: *TranscriptRuntime, metrics: *Metrics) void {
    if (shell.sync_updates_enabled) {
        _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[?2026l") catch {};
    }
    _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[?7h\x1b[0m") catch {};

    var cursor_buf: [32]u8 = undefined;
    if (ui_terminal.moveCursorSequence(&cursor_buf, shutdownCleanupRow(shell), 1)) |cursor| {
        _ = writeLifecycleTerminalBytes(shell, metrics, cursor) catch {};
    } else |_| {}
    _ = writeLifecycleTerminalBytes(shell, metrics, "\x1b[J\x1b[?25h\n") catch {};
}

pub fn writeLifecycleTerminalBytes(shell: *TranscriptRuntime, metrics: *Metrics, bytes: []const u8) !void {
    try shell.stdout_file.writeStreamingAll(io_mod.getIo(), bytes);
    if (shell.shadow_vt) |grid| {
        grid.feed(bytes) catch |err| debug_trace.logf(
            "render",
            "lifecycle_shadow_feed_drop bytes={d} err={s}",
            .{ bytes.len, @errorName(err) },
        );
    }
    record_tape.recordStdout(bytes);
    metrics.ansi_bytes += bytes.len;
}

fn shutdownCleanupRow(shell: *const TranscriptRuntime) u16 {
    const row = if (shell.footer_viewport.has_frame)
        shell.footer_viewport.geometry.top
    else
        shell.cursor_row;

    if (row == 0) return 1;
    if (shell.layout.rows == 0) return row;
    return @min(row, shell.layout.rows);
}

fn loadPermissionMode(configured: ?PermissionMode) PermissionMode {
    const fallback = configured orelse default_permission_mode;
    const mode = io_mod.getenv("FX_PERMISSION_MODE") orelse return fallback;
    return config_runtime.parsePermissionMode(mode) orelse fallback;
}

fn loadAgentStepLimit(fallback: usize, configured: ?usize) usize {
    return agent_steps.resolveMaxAgentStepsWithOverride(
        configured,
        fallback,
        io_mod.getenv("FX_MAX_AGENT_STEPS"),
    );
}

fn configuredProviderSelection(
    default_model: []const u8,
    settings: *const config_runtime.Settings,
) !model_provider.ProviderSelection {
    const provider = settings.provider orelse .gateway;
    const model = settings.models.get(provider) orelse switch (provider) {
        .gateway => default_model,
        .codex => return error.CodexModelNotSelected,
        .grok => return error.GrokModelNotSelected,
    };
    return .{ .provider = provider, .model = model };
}

fn initialModelId(default_model: []const u8, configured: ?[]const u8) []const u8 {
    const model = io_mod.getenv("FX_MODEL") orelse return configured orelse default_model;
    const trimmed = std.mem.trim(u8, model, " \t\r\n");
    return if (trimmed.len > 0) trimmed else configured orelse default_model;
}

fn loadInitialModel(alloc: Allocator, default_model: []const u8, configured: ?[]const u8) ![]u8 {
    return alloc.dupe(u8, initialModelId(default_model, configured));
}

fn hasProcessModelOverride() bool {
    const model = io_mod.getenv("FX_MODEL") orelse return false;
    return std.mem.trim(u8, model, " \t\r\n").len > 0;
}

fn loadStartupStatusModel(alloc: Allocator, default_model: []const u8, configured: ?[]const u8) !StartupStatusModel {
    const owned = try alloc.dupe(u8, initialModelId(default_model, configured));
    return .{ .value = owned, .owned = owned };
}

fn credentialOnboardingDisabled() bool {
    const value = io_mod.getenv("FX_SKIP_ONBOARDING") orelse return false;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return false;
    return !std.mem.eql(u8, trimmed, "0") and !std.ascii.eqlIgnoreCase(trimmed, "false");
}

const SoundEnvLevel = enum { off, on, max };

fn soundEnvOverride() ?SoundEnvLevel {
    const value = io_mod.getenv("FX_SOUND") orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "max")) return .max;
    const off = std.mem.eql(u8, trimmed, "0") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "off");
    return if (off) .off else .on;
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const EnvEntry) !*TestEnv {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        for (entries) |entry| {
            try self.map.put(entry.key, entry.value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn minimalLayout() types.Layout {
    return .{
        .rows = 1,
        .cols = 1,
        .content_bottom = 1,
        .divider_top_row = 1,
        .input_row = 1,
        .divider_bottom_row = 1,
        .hint_row = 1,
    };
}

fn writeFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}
