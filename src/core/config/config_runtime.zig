const std = @import("std");
const agent_steps = @import("agent_steps.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const settings_store = @import("settings_store.zig");
const project_config = @import("../mcp/project_config.zig");
const model_provider = @import("model_provider.zig");
const model_preferences = @import("model_preferences.zig");
const update_target = @import("../upgrade/update_target.zig");
pub const context_limits = @import("context_limits.zig");

const Allocator = std.mem.Allocator;
const max_settings_bytes: usize = 64 * 1024;
pub const default_permission_mode: types.PermissionMode = .auto;

pub const Paths = struct {
    home_dir: ?[]u8 = null,
    user_settings: ?[]u8 = null,
    workspace_settings: []u8,
    home_fx_dir: ?[]u8 = null,
    sessions_dir: ?[]u8 = null,
    workspace_root: []u8,

    pub fn deinit(self: *Paths, alloc: Allocator) void {
        if (self.home_dir) |path| alloc.free(path);
        if (self.user_settings) |path| alloc.free(path);
        alloc.free(self.workspace_settings);
        if (self.home_fx_dir) |path| alloc.free(path);
        if (self.sessions_dir) |path| alloc.free(path);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }
};

pub const Settings = struct {
    models: model_preferences.Preferences = .{},
    provider: ?model_provider.ProviderId = null,
    permission_mode: ?types.PermissionMode = null,
    credential_source: ?types.CredentialSource = null,
    yolo_acknowledged: ?bool = null,
    max_agent_steps: ?usize = null,
    max_tool_result_bytes: ?usize = null,
    context_limits: context_limits.Overrides = .{},
    first_call_tool_choice: ?types.ToolChoice = null,
    context: ?bool = null,
    fast_mode: ?bool = null,
    slash_menu_categories: ?bool = null,
    collapse_tool_calls: ?bool = null,
    auto_upgrade: ?bool = null,
    update_channel: ?update_target.Channel = null,
    startup_scrollback: ?bool = null,
    prompt_history_enabled: ?bool = null,
    effort: ?types.ReasoningEffort = null,
    statusline_context: ?bool = null,
    statusline_session: ?bool = null,
    statusline_workspace: ?bool = null,
    notification_turn_end: ?bool = null,
    notification_attention_required: ?bool = null,
    notification_max: ?bool = null,
    permission_rules: types.PermissionRuleSet = .{},
    has_permission_rules: bool = false,

    pub fn deinit(self: *Settings, alloc: Allocator) void {
        self.models.deinit(alloc);
        self.permission_rules.deinit(alloc);
        self.* = .{};
    }
};

pub const ProjectMcpChoiceLoad = struct {
    choices: project_config.ProjectMcpChoices = .{},
    diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty,

    pub fn deinit(self: *ProjectMcpChoiceLoad, alloc: Allocator) void {
        self.choices.deinit(alloc);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        self.diagnostics.deinit(alloc);
        self.* = undefined;
    }
};

pub const StartupStatusSettings = struct {
    model: ?[]u8 = null,
    permission_mode: ?types.PermissionMode = null,
    max_agent_steps: ?usize = null,

    pub fn deinit(self: *StartupStatusSettings, alloc: Allocator) void {
        if (self.model) |value| alloc.free(value);
        self.* = .{};
    }
};

pub const ConfigLayer = enum {
    user,
    project,
};

pub const ConfigSource = enum {
    compiled_default,
    user_global,
    project,
    user_workspace,
    process_override,
};

pub const ModelSource = ConfigSource;

pub const ConfigSources = struct {
    models: ProviderModelSources = .{},
    provider: ConfigSource = .compiled_default,
    permission_mode: ConfigSource = .compiled_default,
    effort: ConfigSource = .compiled_default,
    fast_mode: ConfigSource = .compiled_default,
    slash_menu_categories: ConfigSource = .compiled_default,
    collapse_tool_calls: ConfigSource = .compiled_default,
    startup_scrollback: ConfigSource = .compiled_default,
    prompt_history_enabled: ConfigSource = .compiled_default,
    statusline_context: ConfigSource = .compiled_default,
    statusline_session: ConfigSource = .compiled_default,
    notification_turn_end: ConfigSource = .compiled_default,
    notification_attention_required: ConfigSource = .compiled_default,
    notification_max: ConfigSource = .compiled_default,
};

pub const ProviderModelSources = struct {
    values: [std.meta.fields(model_provider.ProviderId).len]ConfigSource =
        [_]ConfigSource{.compiled_default} ** std.meta.fields(model_provider.ProviderId).len,

    pub fn get(self: ProviderModelSources, provider: model_provider.ProviderId) ConfigSource {
        return self.values[@intFromEnum(provider)];
    }

    pub fn set(self: *ProviderModelSources, provider: model_provider.ProviderId, source: ConfigSource) void {
        self.values[@intFromEnum(provider)] = source;
    }
};

pub fn resolveContextLimits(settings: *const Settings, command_line: []const context_limits.Override) context_limits.Values {
    var values = context_limits.Values{};
    values.apply(settings.context_limits);
    values.applyCommandLine(command_line);
    return values;
}

pub const PermissionSourceViews = struct {
    user: types.PermissionRuleSet = .{},
    local: types.PermissionRuleSet = .{},
    user_shadowed_by_local: bool = false,

    pub fn deinit(self: *PermissionSourceViews, alloc: Allocator) void {
        self.user.deinit(alloc);
        self.local.deinit(alloc);
        self.* = .{};
    }
};

pub const ConfigDiagnosticCause = enum {
    malformed_settings,
    settings_too_large,
    durable_path_unsafe,
    private_state_permissions_unsupported,
    invalid_model_id,
    ignored_project_user_only_setting,
    legacy_workspace_preferences,
    manual_backup_available,
    retired_skill_match_fuzzy,
    invalid_context_limits,
    invalid_additional_directories,
};

pub const ConfigDiagnostic = struct {
    layer: ConfigLayer,
    cause: ConfigDiagnosticCause,
    setting_key: ?[]u8 = null,
    recovery_path: ?[]u8 = null,

    pub fn reportAtStartup(self: ConfigDiagnostic) bool {
        return self.cause != .legacy_workspace_preferences;
    }

    pub fn deinit(self: *ConfigDiagnostic, alloc: Allocator) void {
        if (self.setting_key) |key| alloc.free(key);
        if (self.recovery_path) |path| alloc.free(path);
        self.* = undefined;
    }
};

pub fn writeDiagnosticMetadata(writer: *std.Io.Writer, diagnostic: ConfigDiagnostic) !void {
    if (diagnostic.setting_key) |key| try writer.print("; key={s}", .{key});
    if (diagnostic.recovery_path) |path| try writer.print("; recovery={s}", .{path});
    if (diagnostic.cause == .retired_skill_match_fuzzy) {
        try writer.writeAll("; remove skill_match_fuzzy; skills now load only through explicit invocation or the skill tool");
    }
    if (diagnostic.cause == .invalid_context_limits) {
        try writer.writeAll("; context_limits keys must be documented limit names with a non-negative integer or \"off\" value");
    }
    if (diagnostic.cause == .invalid_additional_directories) {
        try writer.print(
            "; additional_directories must be an array of at most {d} unique absolute directory paths for the current primary workspace",
            .{workspace_access.max_additional_directories},
        );
    }
}

pub const DetailedSettings = struct {
    settings: Settings,
    diagnostics: []ConfigDiagnostic = &.{},
    model_source: ?ModelSource = null,
    sources: ConfigSources = .{},
    permission_sources: PermissionSourceViews = .{},
    prompt_history_store_allowed: bool = true,
    additional_directories: ?[][]u8 = null,
    additional_directory_sources: ?[][]u8 = null,

    pub fn deinit(self: *DetailedSettings, alloc: Allocator) void {
        self.settings.deinit(alloc);
        self.permission_sources.deinit(alloc);
        if (self.additional_directories) |paths| freeStringSlice(alloc, paths);
        if (self.additional_directory_sources) |paths| freeStringSlice(alloc, paths);
        if (self.diagnostics.len > 0) {
            for (self.diagnostics) |*diagnostic| diagnostic.deinit(alloc);
            alloc.free(self.diagnostics);
        }
        self.* = undefined;
    }
};

pub fn discoverPaths(alloc: Allocator, workspace_root: []const u8) !Paths {
    return discoverPathsWithOptionalHome(alloc, io_mod.getenv("HOME"), workspace_root);
}

pub fn discoverPathsFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !Paths {
    return discoverPathsWithOptionalHome(alloc, home_dir, workspace_root);
}

pub fn loadMergedSettings(alloc: Allocator, workspace_root: []const u8) !Settings {
    var paths = try discoverPaths(alloc, workspace_root);
    defer paths.deinit(alloc);
    return loadMergedSettingsFromPaths(alloc, paths);
}

pub fn loadProjectMcpChoices(
    alloc: Allocator,
    workspace_root: []const u8,
) !ProjectMcpChoiceLoad {
    const home = io_mod.getenv("HOME") orelse return .{};
    return loadProjectMcpChoicesFromHome(alloc, home, workspace_root);
}

pub fn loadProjectMcpChoicesFromHome(
    alloc: Allocator,
    home: []const u8,
    workspace_root: []const u8,
) !ProjectMcpChoiceLoad {
    var store = try settings_store.Store.initFromHome(alloc, home, .read_only);
    defer store.deinit(alloc);
    var primary = try store.loadPrimary(alloc);
    defer primary.deinit(alloc);
    const bytes = switch (primary) {
        .absent => return .{},
        .valid => |value| value,
        .invalid => return error.InvalidSettingsFormat,
        .oversized => return error.SettingsPrimaryTooLarge,
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettingsFormat;
    const workspaces = parsed.value.object.get("workspaces") orelse return .{};
    if (workspaces != .object) return error.InvalidSettingsFormat;
    const normalized_root = normalizeWorkspaceRoot(workspace_root);
    const workspace = workspaces.object.get(normalized_root) orelse return .{};

    var result: ProjectMcpChoiceLoad = .{};
    errdefer result.deinit(alloc);
    result.choices = project_config.parseChoices(
        alloc,
        workspace,
        &result.diagnostics,
    ) catch return error.InvalidSettingsFormat;
    return result;
}

pub fn loadMergedSettingsFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !Settings {
    var paths = try discoverPathsFromHome(alloc, home_dir, workspace_root);
    defer paths.deinit(alloc);
    return loadMergedSettingsFromPaths(alloc, paths);
}

pub fn loadMergedSettingsDetailedFromHome(
    alloc: Allocator,
    home_dir: []const u8,
    workspace_root: []const u8,
) !DetailedSettings {
    return loadMergedSettingsDetailedWithOptionalHome(alloc, home_dir, workspace_root);
}

pub fn loadMergedSettingsDetailed(alloc: Allocator, workspace_root: []const u8) !DetailedSettings {
    return loadMergedSettingsDetailedWithOptionalHome(alloc, io_mod.getenv("HOME"), workspace_root);
}

fn loadMergedSettingsDetailedWithOptionalHome(
    alloc: Allocator,
    home_dir: ?[]const u8,
    workspace_root: []const u8,
) !DetailedSettings {
    var settings = Settings{};
    errdefer settings.deinit(alloc);
    var diagnostics: std.ArrayList(ConfigDiagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        diagnostics.deinit(alloc);
    }
    var sources = ConfigSources{};
    var permission_sources = PermissionSourceViews{};
    errdefer permission_sources.deinit(alloc);
    var prompt_history_store_allowed = home_dir != null;
    var additional_directories: ?[][]u8 = null;
    errdefer if (additional_directories) |paths| freeStringSlice(alloc, paths);
    var additional_directory_sources: ?[][]u8 = null;
    errdefer if (additional_directory_sources) |paths| freeStringSlice(alloc, paths);
    const detailed_merge_state: DetailedSettingsMergeState = .{
        .settings = &settings,
        .sources = &sources,
        .permission_sources = &permission_sources,
        .diagnostics = &diagnostics,
        .prompt_history_store_allowed = &prompt_history_store_allowed,
    };

    var user_root: ?std.json.Parsed(std.json.Value) = null;
    defer if (user_root) |*parsed| parsed.deinit();

    if (home_dir) |home| {
        var store: ?settings_store.Store = settings_store.Store.initFromHome(alloc, home, .read_only) catch |err| blk: {
            prompt_history_store_allowed = false;
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = diagnosticCauseForUserStoreError(err),
            });
            break :blk null;
        };
        if (store) |*usable_store| {
            defer usable_store.deinit(alloc);
            var primary = usable_store.loadPrimary(alloc) catch |err| blk: {
                prompt_history_store_allowed = false;
                try diagnostics.append(alloc, .{
                    .layer = .user,
                    .cause = diagnosticCauseForUserStoreError(err),
                });
                break :blk settings_store.PrimaryLoad.absent;
            };
            defer primary.deinit(alloc);
            switch (primary) {
                .absent => {},
                .invalid => {
                    prompt_history_store_allowed = false;
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                    if (usable_store.newestValidBackupPath(alloc) catch null) |recovery_path| {
                        try diagnostics.append(alloc, .{
                            .layer = .user,
                            .cause = .manual_backup_available,
                            .recovery_path = recovery_path,
                        });
                    }
                },
                .oversized => {
                    prompt_history_store_allowed = false;
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .settings_too_large });
                    if (usable_store.newestValidBackupPath(alloc) catch null) |recovery_path| {
                        try diagnostics.append(alloc, .{
                            .layer = .user,
                            .cause = .manual_backup_available,
                            .recovery_path = recovery_path,
                        });
                    }
                },
                .valid => |bytes| {
                    user_root = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
                    if (user_root.?.value != .object) {
                        prompt_history_store_allowed = false;
                        try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                        user_root.?.deinit();
                        user_root = null;
                    }
                },
            }
        }
    }

    const project_path = try std.fs.path.join(alloc, &.{ workspace_root, ".fx.json" });
    defer alloc.free(project_path);
    const project_text = readOptionalFile(alloc, project_path) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        try diagnostics.append(alloc, .{
            .layer = .project,
            .cause = switch (err) {
                error.StreamTooLong => .settings_too_large,
                error.DurablePathUnsafe => .durable_path_unsafe,
                else => .malformed_settings,
            },
        });
        break :blk null;
    };
    defer if (project_text) |text| alloc.free(text);
    if (project_text) |text| {
        if (std.json.parseFromSlice(std.json.Value, alloc, text, .{})) |parsed_value| {
            var parsed = parsed_value;
            defer parsed.deinit();
            if (parsed.value != .object) {
                try diagnostics.append(alloc, .{ .layer = .project, .cause = .malformed_settings });
            } else {
                try appendIgnoredProjectProfileSettingDiagnostics(alloc, &diagnostics, parsed.value);
                try mergeDetailedSettingsLayer(
                    alloc,
                    &detailed_merge_state,
                    parsed.value,
                    .project,
                    false,
                    .project,
                    .project,
                    .none,
                );
            }
        } else |err| {
            if (err == error.OutOfMemory) return err;
            try diagnostics.append(alloc, .{ .layer = .project, .cause = .malformed_settings });
        }
    }

    if (user_root) |parsed| {
        if (parsed.value.object.contains("additional_directories")) {
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = .invalid_additional_directories,
                .setting_key = try alloc.dupe(u8, "additional_directories"),
            });
        }
        if (hasLegacyWorkspacePreferences(parsed.value)) {
            try diagnostics.append(alloc, .{
                .layer = .user,
                .cause = .legacy_workspace_preferences,
            });
        }
        try mergeDetailedSettingsLayer(
            alloc,
            &detailed_merge_state,
            parsed.value,
            .profile,
            false,
            .user,
            .user_global,
            .user,
        );
    }

    if (user_root) |parsed| {
        const workspaces = parsed.value.object.get("workspaces");
        if (workspaces) |workspaces_value| {
            if (workspaces_value != .object) {
                try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
            } else if (workspaces_value.object.get(workspace_root)) |workspace_value| {
                if (workspace_value != .object) {
                    try diagnostics.append(alloc, .{ .layer = .user, .cause = .malformed_settings });
                } else {
                    if (workspace_value.object.get("additional_directories")) |value| {
                        const parsed_directories = parseAdditionalDirectories(
                            alloc,
                            workspace_root,
                            value,
                        ) catch |err| blk: {
                            if (err == error.OutOfMemory) return err;
                            try diagnostics.append(alloc, .{
                                .layer = .user,
                                .cause = .invalid_additional_directories,
                                .setting_key = try alloc.dupe(u8, "additional_directories"),
                            });
                            break :blk null;
                        };
                        if (parsed_directories) |directories| {
                            additional_directories = directories.canonical;
                            additional_directory_sources = directories.sources;
                        }
                    }
                    try mergeDetailedSettingsLayer(
                        alloc,
                        &detailed_merge_state,
                        workspace_value,
                        .profile,
                        true,
                        .user,
                        .user_workspace,
                        .local,
                    );
                }
            }
        }
    }

    if (io_mod.getenv("FX_MODEL")) |model_override| {
        if (std.mem.trim(u8, model_override, " \t\r\n").len > 0) {
            sources.models.set(settings.provider orelse .gateway, .process_override);
        }
    }

    return .{
        .settings = settings,
        .diagnostics = try diagnostics.toOwnedSlice(alloc),
        .model_source = sources.models.get(settings.provider orelse .gateway),
        .sources = sources,
        .permission_sources = permission_sources,
        .prompt_history_store_allowed = prompt_history_store_allowed,
        .additional_directories = additional_directories,
        .additional_directory_sources = additional_directory_sources,
    };
}

const ParsedAdditionalDirectories = struct {
    canonical: [][]u8,
    sources: [][]u8,
};

fn parseAdditionalDirectories(
    alloc: Allocator,
    workspace_root: []const u8,
    value: std.json.Value,
) !ParsedAdditionalDirectories {
    if (value != .array) return error.InvalidAdditionalDirectories;

    var raw_paths: std.ArrayList([]const u8) = .empty;
    defer raw_paths.deinit(alloc);
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidAdditionalDirectories;
        if (raw_paths.items.len >= workspace_access.max_additional_directories) {
            return error.InvalidAdditionalDirectories;
        }
        for (raw_paths.items) |path| {
            if (std.mem.eql(u8, path, item.string)) return error.InvalidAdditionalDirectories;
        }
        try raw_paths.append(alloc, item.string);
    }

    var access = workspace_access.WorkspaceAccess.init(
        alloc,
        workspace_root,
        raw_paths.items,
        &.{},
        false,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAdditionalDirectories,
    };
    defer access.deinit(alloc);
    const canonical = try access.savedDirectoriesAlloc(alloc);
    errdefer freeStringSlice(alloc, canonical);
    return .{
        .canonical = canonical,
        .sources = try access.savedSourcePathsAlloc(alloc),
    };
}

fn hasLegacyWorkspacePreferences(root: std.json.Value) bool {
    if (root != .object) return false;
    const workspaces = root.object.get("workspaces") orelse return false;
    if (workspaces != .object) return false;

    var iterator = workspaces.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const workspace = entry.value_ptr.object;
        inline for (&.{
            "model",
            "effort",
            "fast_mode",
            "slash_menu_categories",
            "collapse_tool_calls",
            "startup_scrollback",
        }) |key| {
            if (workspace.contains(key)) return true;
        }
        if (workspace.get("prompt_history")) |value| {
            if (value == .object and value.object.contains("enabled")) return true;
        }
        if (workspace.get("statusLine")) |value| {
            if (value == .object and
                (value.object.contains("context") or
                    value.object.contains("session")))
            {
                return true;
            }
        }
    }
    return false;
}

fn isProfileOnlySettingKey(key: []const u8) bool {
    inline for (&.{
        "model",
        "models",
        "provider",
        "codex_model",
        "grok_model",
        "effort",
        "fast_mode",
        "slash_menu_categories",
        "collapse_tool_calls",
        "startup_scrollback",
        "prompt_history",
        "statusLine",
        "notifications",
        "context_limits",
        "skill_match_fuzzy",
        "first_call_tool_choice",
        "auto_upgrade",
        "update_channel",
        "permission_mode",
        "credential_source",
        "yolo_acknowledged",
        "permission",
        "additional_directories",
    }) |profile_key| {
        if (std.mem.eql(u8, key, profile_key)) return true;
    }
    return false;
}

fn appendIgnoredProjectProfileSettingDiagnostics(
    alloc: Allocator,
    diagnostics: *std.ArrayList(ConfigDiagnostic),
    root: std.json.Value,
) !void {
    if (root != .object) return;
    var iterator = root.object.iterator();
    while (iterator.next()) |entry| {
        if (!isProfileOnlySettingKey(entry.key_ptr.*)) continue;
        try diagnostics.append(alloc, .{
            .layer = .project,
            .cause = .ignored_project_user_only_setting,
            .setting_key = try alloc.dupe(u8, entry.key_ptr.*),
        });
    }
}

fn updateConfigSources(sources: *ConfigSources, settings: Settings, source: ConfigSource) void {
    inline for (std.meta.tags(model_provider.ProviderId)) |provider| {
        if (settings.models.get(provider) != null) sources.models.set(provider, source);
    }
    if (settings.provider != null) sources.provider = source;
    if (settings.permission_mode != null) sources.permission_mode = source;
    if (settings.effort != null) sources.effort = source;
    if (settings.fast_mode != null) sources.fast_mode = source;
    if (settings.slash_menu_categories != null) sources.slash_menu_categories = source;
    if (settings.collapse_tool_calls != null) sources.collapse_tool_calls = source;
    if (settings.startup_scrollback != null) sources.startup_scrollback = source;
    if (settings.prompt_history_enabled != null) sources.prompt_history_enabled = source;
    if (settings.statusline_context != null) sources.statusline_context = source;
    if (settings.statusline_session != null) sources.statusline_session = source;
    if (settings.notification_turn_end != null) sources.notification_turn_end = source;
    if (settings.notification_attention_required != null) sources.notification_attention_required = source;
    if (settings.notification_max != null) sources.notification_max = source;
}

const DetailedPermissionSource = enum {
    none,
    user,
    local,
};

const DetailedSettingsMergeState = struct {
    settings: *Settings,
    sources: *ConfigSources,
    permission_sources: *PermissionSourceViews,
    diagnostics: *std.ArrayList(ConfigDiagnostic),
    prompt_history_store_allowed: *bool,
};

fn mergeDetailedSettingsLayer(
    alloc: Allocator,
    state: *const DetailedSettingsMergeState,
    value: std.json.Value,
    settings_layer: SettingsLayer,
    tolerate_non_object_user_containers: bool,
    diagnostic_layer: ConfigLayer,
    source: ConfigSource,
    permission_source: DetailedPermissionSource,
) !void {
    if (parseSettingsValueForLayer(
        alloc,
        value,
        settings_layer,
        tolerate_non_object_user_containers,
        source != .user_workspace,
    )) |layer_settings| {
        var incoming = layer_settings;
        defer incoming.deinit(alloc);
        incoming.context_limits.retag(switch (source) {
            .user_global => .user_global,
            .user_workspace => .user_workspace,
            else => .compiled_default,
        });
        if (source == .user_workspace) {
            incoming.update_channel = null;
        }
        updateConfigSources(state.sources, incoming, source);
        if (incoming.has_permission_rules) {
            switch (permission_source) {
                .none => {},
                .user => {
                    state.permission_sources.user.deinit(alloc);
                    state.permission_sources.user = try types.dupePermissionRuleSet(alloc, incoming.permission_rules);
                },
                .local => {
                    state.permission_sources.local.deinit(alloc);
                    state.permission_sources.local = try types.dupePermissionRuleSet(alloc, incoming.permission_rules);
                    state.permission_sources.user_shadowed_by_local = true;
                },
            }
        }
        mergeSettings(state.settings, &incoming, alloc);
    } else |err| {
        if (err == error.OutOfMemory) return err;
        if (diagnostic_layer == .user and err == error.InvalidModelValue) state.prompt_history_store_allowed.* = false;
        try state.diagnostics.append(alloc, .{
            .layer = diagnostic_layer,
            .cause = diagnosticCauseForParseError(err),
        });
    }
}

fn diagnosticCauseForParseError(err: anyerror) ConfigDiagnosticCause {
    return switch (err) {
        error.InvalidModelValue => .invalid_model_id,
        error.RetiredSkillMatchFuzzy => .retired_skill_match_fuzzy,
        error.InvalidContextLimitsType,
        error.UnknownContextLimit,
        error.InvalidContextLimitValue,
        => .invalid_context_limits,
        else => .malformed_settings,
    };
}

fn diagnosticCauseForUserStoreError(err: anyerror) ConfigDiagnosticCause {
    return switch (err) {
        error.DurablePathUnsafe => .durable_path_unsafe,
        error.PrivateStatePermissionsUnsupported => .private_state_permissions_unsupported,
        else => .malformed_settings,
    };
}

pub fn loadStartupStatusSettings(alloc: Allocator, workspace_root: []const u8) !StartupStatusSettings {
    var paths = try discoverPaths(alloc, workspace_root);
    defer paths.deinit(alloc);
    return loadStartupStatusSettingsFromPaths(alloc, paths);
}

pub fn loadStartupStatusSettingsFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !StartupStatusSettings {
    var paths = try discoverPathsFromHome(alloc, home_dir, workspace_root);
    defer paths.deinit(alloc);
    return loadStartupStatusSettingsFromPaths(alloc, paths);
}

pub fn ensureStateLayout(paths: Paths) !void {
    if (paths.home_fx_dir) |dir| try ensureAbsoluteDir(dir);
    if (paths.sessions_dir) |dir| try ensureAbsoluteDir(dir);
}

pub fn parsePermissionMode(raw: []const u8) ?types.PermissionMode {
    if (std.ascii.eqlIgnoreCase(raw, "ask")) return .ask;
    if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(raw, "yolo")) return .yolo;
    return null;
}

pub fn parsePermissionAction(raw: []const u8) ?types.PermissionAction {
    if (std.ascii.eqlIgnoreCase(raw, "allow")) return .allow;
    if (std.ascii.eqlIgnoreCase(raw, "ask")) return .ask;
    if (std.ascii.eqlIgnoreCase(raw, "deny")) return .deny;
    return null;
}

pub fn makeAbsolutePath(path_abs: []const u8) !void {
    const zio = io_mod.getIo();
    var root = try std.Io.Dir.openDirAbsolute(zio, "/", .{});
    defer root.close(zio);

    const relative_to_root = std.mem.trimStart(u8, path_abs, "/");
    if (relative_to_root.len == 0) return;
    try root.createDirPath(zio, relative_to_root);
}

fn ensureAbsoluteDir(path_abs: []const u8) !void {
    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, path_abs, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try makeAbsolutePath(path_abs);
            return;
        },
        else => return err,
    };
    dir.close(zio);
}

pub fn userSettingsPath(alloc: Allocator) !?[]u8 {
    const home = io_mod.getenv("HOME") orelse return null;
    return try profile_paths.settingsPath(alloc, home);
}

pub const AllowlistResetScope = settings_store.AllowlistResetScope;
pub const PermissionMutation = settings_store.PermissionMutation;
pub const PermissionScope = settings_store.PermissionScope;
pub const StatuslineItem = settings_store.StatuslineItem;
pub const UserSettingsPatch = settings_store.UserSettingsPatch;
pub const WorkspaceDirectoryMutation = settings_store.WorkspaceDirectoryMutation;
pub const CommitOutcome = settings_store.CommitOutcome;
pub const LegacyCleanup = settings_store.LegacyCleanup;

pub const CommitFailure = struct {
    err: anyerror,
    cleanup: LegacyCleanup = .{},

    pub fn deinit(self: *CommitFailure, alloc: Allocator) void {
        self.cleanup.deinit(alloc);
        self.* = undefined;
    }
};

pub const CommitAttempt = union(enum) {
    outcome: CommitOutcome,
    failure: CommitFailure,

    pub fn deinit(self: *CommitAttempt, alloc: Allocator) void {
        switch (self.*) {
            .outcome => |*outcome| outcome.deinit(alloc),
            .failure => |*failure| failure.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn attemptUserPreferences(
    alloc: Allocator,
    patch: UserSettingsPatch,
) CommitAttempt {
    const home = io_mod.getenv("HOME") orelse return .{ .failure = .{ .err = error.HomeNotSet } };
    var store = settings_store.Store.initFromHome(alloc, home, .writable) catch |err| {
        return .{ .failure = .{ .err = err } };
    };
    defer store.deinit(alloc);
    const outcome = store.applyUserPatch(alloc, patch) catch |err| {
        return .{ .failure = .{
            .err = err,
            .cleanup = store.takeFailureCleanup(),
        } };
    };
    return .{ .outcome = outcome };
}

pub fn attemptProjectMcpMutation(
    alloc: Allocator,
    workspace_root: []const u8,
    action: project_config.ProjectMcpAction,
) CommitAttempt {
    const home = io_mod.getenv("HOME") orelse return .{ .failure = .{ .err = error.HomeNotSet } };
    var store = settings_store.Store.initFromHome(alloc, home, .writable) catch |err| {
        return .{ .failure = .{ .err = err } };
    };
    defer store.deinit(alloc);
    const outcome = store.applyProjectMcpMutation(alloc, .{
        .workspace_root = workspace_root,
        .action = action,
    }) catch |err| return .{ .failure = .{
        .err = err,
        .cleanup = store.takeFailureCleanup(),
    } };
    return .{ .outcome = outcome };
}

pub fn setUserPreferences(
    alloc: Allocator,
    patch: UserSettingsPatch,
) !CommitOutcome {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    return store.applyUserPatch(alloc, patch);
}

pub fn mutateWorkspaceDirectory(
    alloc: Allocator,
    mutation: WorkspaceDirectoryMutation,
) !CommitOutcome {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    return store.applyWorkspaceDirectoryPatch(alloc, mutation);
}

pub fn mutatePermission(
    alloc: Allocator,
    mutation: PermissionMutation,
) !CommitOutcome {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    return store.applyPermissionPatch(alloc, mutation);
}

pub fn addPermissionRule(
    alloc: Allocator,
    scope: PermissionScope,
    workspace_root: ?[]const u8,
    category: []const u8,
    pattern: []const u8,
    action: types.PermissionAction,
) !CommitOutcome {
    return mutatePermission(alloc, .{
        .scope = scope,
        .workspace_root = workspace_root,
        .patch = .{ .add = .{
            .category = category,
            .pattern = pattern,
            .action = action,
        } },
    });
}

pub fn removePermissionRule(
    alloc: Allocator,
    scope: PermissionScope,
    workspace_root: ?[]const u8,
    category: []const u8,
    pattern: []const u8,
) !CommitOutcome {
    return mutatePermission(alloc, .{
        .scope = scope,
        .workspace_root = workspace_root,
        .patch = .{ .remove = .{
            .category = category,
            .pattern = pattern,
        } },
    });
}

pub fn removeAllowlistRules(
    alloc: Allocator,
    permission_scope: PermissionScope,
    workspace_root: ?[]const u8,
    reset_scope: AllowlistResetScope,
) !CommitOutcome {
    return mutatePermission(alloc, .{
        .scope = permission_scope,
        .workspace_root = workspace_root,
        .patch = .{ .reset = reset_scope },
    });
}

fn discoverPathsWithOptionalHome(alloc: Allocator, home_dir: ?[]const u8, workspace_root: []const u8) !Paths {
    const trimmed_workspace = normalizeWorkspaceRoot(workspace_root);
    if (trimmed_workspace.len == 0) return error.InvalidWorkspaceRoot;

    var paths: Paths = .{
        .workspace_settings = undefined,
        .workspace_root = try alloc.dupe(u8, trimmed_workspace),
    };
    errdefer alloc.free(paths.workspace_root);

    if (home_dir) |home| {
        paths.home_dir = try alloc.dupe(u8, home);
        errdefer alloc.free(paths.home_dir.?);

        paths.home_fx_dir = try profile_paths.rootDir(alloc, home);
        errdefer alloc.free(paths.home_fx_dir.?);

        paths.user_settings = try profile_paths.settingsPath(alloc, home);
        errdefer alloc.free(paths.user_settings.?);

        paths.sessions_dir = try profile_paths.sessionsDir(alloc, home);
        errdefer alloc.free(paths.sessions_dir.?);
    }

    paths.workspace_settings = try std.fs.path.join(alloc, &.{ trimmed_workspace, ".fx.json" });
    errdefer alloc.free(paths.workspace_settings);

    return paths;
}

pub fn loadMergedSettingsFromPaths(alloc: Allocator, paths: Paths) !Settings {
    var settings = Settings{};
    errdefer settings.deinit(alloc);

    const user_text = try readOptionalUserSettingsFile(alloc, paths);
    defer if (user_text) |owned| alloc.free(owned);

    if (user_text) |text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSettingsShape;

        try mergeSettingsFile(&settings, alloc, paths.workspace_settings);

        var user_settings = try parseSettingsValueForLayer(alloc, parsed.value, .profile, false, true);
        defer user_settings.deinit(alloc);
        user_settings.context_limits.retag(.user_global);
        mergeSettings(&settings, &user_settings, alloc);

        try mergeWorkspaceOverridesFromValue(&settings, alloc, parsed.value, paths.workspace_root);
        return settings;
    }

    try mergeSettingsFile(&settings, alloc, paths.workspace_settings);

    return settings;
}

pub fn loadStartupStatusSettingsFromPaths(alloc: Allocator, paths: Paths) !StartupStatusSettings {
    return loadStartupStatusSettingsFromPathsFast(alloc, paths) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var settings = try loadMergedSettingsFromPaths(alloc, paths);
            defer settings.deinit(alloc);
            return startupStatusSettingsFromSettings(alloc, settings);
        },
    };
}

fn loadStartupStatusSettingsFromPathsFast(alloc: Allocator, paths: Paths) !StartupStatusSettings {
    var settings = StartupStatusSettings{};
    errdefer settings.deinit(alloc);

    const user_text = try readOptionalUserSettingsFile(alloc, paths);
    defer if (user_text) |owned| alloc.free(owned);

    if (try readOptionalFile(alloc, paths.workspace_settings)) |workspace_text| {
        defer alloc.free(workspace_text);
        var workspace_settings = try parseStartupStatusSettingsJson(alloc, workspace_text, null, .project);
        defer workspace_settings.deinit(alloc);
        mergeStartupStatusSettings(&settings, &workspace_settings, alloc);
    }

    if (user_text) |text| {
        var user_settings = try parseStartupStatusSettingsJson(alloc, text, null, .profile);
        defer user_settings.deinit(alloc);
        mergeStartupStatusSettings(&settings, &user_settings, alloc);
    }

    if (user_text) |text| {
        var override_settings = try parseStartupStatusSettingsJson(alloc, text, paths.workspace_root, .profile);
        defer override_settings.deinit(alloc);
        mergeStartupStatusSettings(&settings, &override_settings, alloc);
    }

    return settings;
}

fn readOptionalUserSettingsFile(alloc: Allocator, paths: Paths) !?[]u8 {
    if (paths.home_dir) |home| {
        var store = try settings_store.Store.initFromHome(alloc, home, .read_only);
        defer store.deinit(alloc);
        var primary = try store.loadPrimary(alloc);
        errdefer primary.deinit(alloc);
        return switch (primary) {
            .absent => null,
            .valid => |bytes| blk: {
                primary = .absent;
                break :blk bytes;
            },
            .invalid => error.InvalidSettingsFormat,
            .oversized => error.StreamTooLong,
        };
    }
    if (paths.user_settings) |path| return try readOptionalFile(alloc, path);
    return null;
}

fn startupStatusSettingsFromSettings(alloc: Allocator, settings: Settings) !StartupStatusSettings {
    return .{
        .model = if (settings.models.get(.gateway)) |model| try alloc.dupe(u8, model) else null,
        .permission_mode = settings.permission_mode,
        .max_agent_steps = settings.max_agent_steps,
    };
}

fn mergeStartupStatusSettings(target: *StartupStatusSettings, incoming: *StartupStatusSettings, alloc: Allocator) void {
    if (incoming.model) |value| {
        if (target.model) |current| alloc.free(current);
        target.model = value;
        incoming.model = null;
    }
    if (incoming.permission_mode) |value| target.permission_mode = value;
    if (incoming.max_agent_steps) |value| target.max_agent_steps = value;
}

fn mergeWorkspaceOverridesFromValue(target: *Settings, alloc: Allocator, root_value: std.json.Value, workspace_root: []const u8) !void {
    if (root_value != .object) return error.InvalidSettingsShape;

    const workspaces_val = root_value.object.get("workspaces") orelse return;
    if (workspaces_val != .object) return;

    const override_val = workspaces_val.object.get(workspace_root) orelse return;
    if (override_val != .object) return;

    var override_settings = try parseSettingsValueForLayer(alloc, override_val, .profile, true, false);
    defer override_settings.deinit(alloc);
    override_settings.update_channel = null;
    override_settings.context_limits.retag(.user_workspace);
    mergeSettings(target, &override_settings, alloc);
}

fn mergeSettingsFile(target: *Settings, alloc: Allocator, path: []const u8) !void {
    const bytes = (try readOptionalFile(alloc, path)) orelse return;
    defer alloc.free(bytes);

    var parsed = try parseSettingsJsonForLayer(alloc, bytes, .project);
    defer parsed.deinit(alloc);
    mergeSettings(target, &parsed, alloc);
}

fn readOptionalFile(alloc: Allocator, path: []const u8) !?[]u8 {
    var file = io_mod.openExistingRegularFile(
        std.Io.Dir.cwd(),
        path,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.size > max_settings_bytes) return error.StreamTooLong;
    return try io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1);
}

fn parseSettingsJson(alloc: Allocator, json_text: []const u8) !Settings {
    return parseSettingsJsonForLayer(alloc, json_text, .profile);
}

fn parseSettingsJsonForLayer(alloc: Allocator, json_text: []const u8, layer: SettingsLayer) !Settings {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    return parseSettingsValueForLayer(alloc, parsed.value, layer, false, true);
}

const JsonStringToken = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: JsonStringToken, alloc: Allocator) void {
        if (self.owned) |value| alloc.free(value);
    }
};

const SettingsLayer = enum {
    profile,
    project,
};

fn parseStartupStatusSettingsJson(
    alloc: Allocator,
    json_text: []const u8,
    target_workspace: ?[]const u8,
    layer: SettingsLayer,
) !StartupStatusSettings {
    var scanner = std.json.Scanner.initCompleteInput(alloc, json_text);
    defer scanner.deinit();

    var settings = try parseStartupStatusObject(&scanner, alloc, target_workspace, layer);
    errdefer settings.deinit(alloc);
    try expectConfigJsonToken(try scanner.next(), .end_of_document);
    return settings;
}

fn parseStartupStatusObject(
    scanner: *std.json.Scanner,
    alloc: Allocator,
    target_workspace: ?[]const u8,
    layer: SettingsLayer,
) anyerror!StartupStatusSettings {
    try expectConfigJsonToken(try scanner.next(), .object_begin);
    var settings = StartupStatusSettings{};
    errdefer settings.deinit(alloc);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => return settings,
            .string, .allocated_string => {
                const key = try configJsonStringFromToken(token);
                defer key.deinit(alloc);

                if (target_workspace) |workspace| {
                    if (std.mem.eql(u8, key.text, "workspaces")) {
                        var workspace_settings = try parseStartupStatusWorkspaceOverrides(scanner, alloc, workspace);
                        defer workspace_settings.deinit(alloc);
                        mergeStartupStatusSettings(&settings, &workspace_settings, alloc);
                    } else {
                        try scanner.skipValue();
                    }
                } else if (layer == .profile and std.mem.eql(u8, key.text, "model")) {
                    try readStartupStatusModel(scanner, alloc, &settings);
                } else if (layer == .profile and std.mem.eql(u8, key.text, "permission_mode")) {
                    settings.permission_mode = try readStartupStatusPermissionMode(scanner);
                } else if (std.mem.eql(u8, key.text, "max_agent_steps")) {
                    settings.max_agent_steps = try readStartupStatusUsize(scanner);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeConfigJsonToken(alloc, token);
                return error.InvalidSettingsShape;
            },
        }
    }
}

fn parseStartupStatusWorkspaceOverrides(scanner: *std.json.Scanner, alloc: Allocator, target_workspace: []const u8) anyerror!StartupStatusSettings {
    try expectConfigJsonToken(try scanner.next(), .object_begin);
    var settings = StartupStatusSettings{};
    errdefer settings.deinit(alloc);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => return settings,
            .string, .allocated_string => {
                const key = try configJsonStringFromToken(token);
                defer key.deinit(alloc);

                if (std.mem.eql(u8, key.text, target_workspace)) {
                    var workspace_settings = try parseStartupStatusObject(scanner, alloc, null, .profile);
                    defer workspace_settings.deinit(alloc);
                    mergeStartupStatusSettings(&settings, &workspace_settings, alloc);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeConfigJsonToken(alloc, token);
                return error.InvalidSettingsShape;
            },
        }
    }
}

fn readStartupStatusModel(scanner: *std.json.Scanner, alloc: Allocator, settings: *StartupStatusSettings) !void {
    const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
    switch (token) {
        .string, .allocated_string => {
            const value = try configJsonStringFromToken(token);
            defer value.deinit(alloc);
            const trimmed = std.mem.trim(u8, value.text, " \t\r\n");
            if (trimmed.len == 0) return;
            const owned = try alloc.dupe(u8, trimmed);
            if (settings.model) |current| alloc.free(current);
            settings.model = owned;
        },
        else => {
            freeConfigJsonToken(alloc, token);
            return error.InvalidModelType;
        },
    }
}

fn readStartupStatusPermissionMode(scanner: *std.json.Scanner) !types.PermissionMode {
    const token = try scanner.next();
    switch (token) {
        .string => |value| return parsePermissionMode(value) orelse error.InvalidPermissionMode,
        else => return error.InvalidPermissionModeType,
    }
}

fn readStartupStatusUsize(scanner: *std.json.Scanner) !usize {
    const token = try scanner.next();
    switch (token) {
        .number => |raw| return std.fmt.parseUnsigned(usize, raw, 10) catch error.InvalidMaxAgentStepsValue,
        else => return error.InvalidMaxAgentStepsType,
    }
}

fn configJsonStringFromToken(token: std.json.Token) !JsonStringToken {
    return switch (token) {
        .string => |text| .{ .text = text },
        .allocated_string => |text| .{ .text = text, .owned = text },
        else => error.InvalidSettingsShape,
    };
}

fn freeConfigJsonToken(alloc: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |text| alloc.free(text),
        .allocated_number => |text| alloc.free(text),
        else => {},
    }
}

fn expectConfigJsonToken(token: std.json.Token, comptime expected: std.json.TokenType) !void {
    const actual: std.json.TokenType = switch (token) {
        .object_begin => .object_begin,
        .object_end => .object_end,
        .array_begin => .array_begin,
        .array_end => .array_end,
        .true => .true,
        .false => .false,
        .null => .null,
        .number, .partial_number, .allocated_number => .number,
        .string, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .allocated_string => .string,
        .end_of_document => .end_of_document,
    };
    if (actual != expected) return error.InvalidSettingsShape;
}

fn parseSettingsValueForLayer(
    alloc: Allocator,
    root: std.json.Value,
    layer: SettingsLayer,
    tolerate_non_object_user_containers: bool,
    parse_workspace_statusline: bool,
) !Settings {
    if (root != .object) return error.InvalidSettingsShape;

    var settings = Settings{};
    errdefer settings.deinit(alloc);

    if (layer == .profile) try parseProfileOnlyFields(
        &settings,
        alloc,
        root,
        tolerate_non_object_user_containers,
        parse_workspace_statusline,
    );
    try parseProjectSafeFields(&settings, root);

    return settings;
}

fn parseProfileOnlyFields(
    settings: *Settings,
    alloc: Allocator,
    root: std.json.Value,
    tolerate_non_object_user_containers: bool,
    parse_workspace_statusline: bool,
) !void {
    if (root.object.contains("skill_match_fuzzy")) return error.RetiredSkillMatchFuzzy;
    if (root.object.get("model")) |model_value| {
        const value = model_value;
        if (value != .string) return error.InvalidModelType;
        settings_store.validateModel(value.string) catch return error.InvalidModelValue;
        try settings.models.putCopy(alloc, .gateway, value.string);
    }

    if (root.object.get("provider")) |provider_value| {
        if (provider_value != .string) return error.InvalidProviderType;
        settings.provider = model_provider.parse(provider_value.string) orelse
            return error.InvalidProviderValue;
    }

    if (root.object.get("codex_model")) |model_value| {
        if (model_value != .string) return error.InvalidCodexModelType;
        settings_store.validateModel(model_value.string) catch return error.InvalidCodexModelValue;
        try settings.models.putCopy(alloc, .codex, model_value.string);
    }

    if (root.object.get("grok_model")) |model_value| {
        if (model_value != .string) return error.InvalidGrokModelType;
        settings_store.validateModel(model_value.string) catch return error.InvalidGrokModelValue;
        try settings.models.putCopy(alloc, .grok, model_value.string);
    }

    if (root.object.get("models")) |models_value| {
        if (models_value != .object) return error.InvalidModelType;
        inline for (std.meta.tags(model_provider.ProviderId)) |provider| {
            if (models_value.object.get(@tagName(provider))) |model_value| {
                if (model_value != .string) return error.InvalidModelType;
                settings_store.validateModel(model_value.string) catch return error.InvalidModelValue;
                try settings.models.putCopy(alloc, provider, model_value.string);
            }
        }
    }

    if (root.object.get("permission_mode")) |permission_mode_value| {
        const value = permission_mode_value;
        if (value != .string) return error.InvalidPermissionModeType;
        settings.permission_mode = parsePermissionMode(value.string) orelse return error.InvalidPermissionMode;
    }

    if (root.object.get("credential_source")) |credential_source_value| {
        if (credential_source_value != .string) return error.InvalidCredentialSourceType;
        settings.credential_source = types.parseCredentialSource(credential_source_value.string) orelse
            return error.InvalidCredentialSource;
    }

    if (root.object.get("yolo_acknowledged")) |acknowledged_value| {
        if (acknowledged_value != .bool) return error.InvalidYoloAcknowledgedType;
        settings.yolo_acknowledged = acknowledged_value.bool;
    }

    if (root.object.get("context_limits")) |context_limits_value| {
        settings.context_limits = try context_limits.parseJsonObject(context_limits_value);
    }

    if (root.object.get("first_call_tool_choice")) |first_call_tool_choice_value| {
        const value = first_call_tool_choice_value;
        if (value != .string) return error.InvalidFirstCallToolChoiceType;
        const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
        if (types.ToolChoice.parse(trimmed)) |choice| {
            settings.first_call_tool_choice = choice;
        } else if (trimmed.len > 0) {
            debug_trace.logf("core", "ignoring invalid first_call_tool_choice value={s}", .{trimmed});
        }
    }

    if (root.object.get("fast_mode")) |fast_mode_value| {
        const value = fast_mode_value;
        if (value != .bool) return error.InvalidFastModeType;
        settings.fast_mode = value.bool;
    }

    if (root.object.get("slash_menu_categories")) |slash_menu_categories_value| {
        const value = slash_menu_categories_value;
        if (value != .bool) return error.InvalidSlashMenuCategoriesType;
        settings.slash_menu_categories = value.bool;
    }

    if (root.object.get("collapse_tool_calls")) |collapse_tool_calls_value| {
        const value = collapse_tool_calls_value;
        if (value != .bool) return error.InvalidCollapseToolCallsType;
        settings.collapse_tool_calls = value.bool;
    }

    if (root.object.get("auto_upgrade")) |auto_upgrade_value| {
        const value = auto_upgrade_value;
        if (value != .bool) return error.InvalidAutoUpgradeType;
        settings.auto_upgrade = value.bool;
    }

    if (root.object.get("update_channel")) |update_channel_value| {
        const value = update_channel_value;
        if (value != .string) return error.InvalidUpdateChannelType;
        settings.update_channel = update_target.Channel.parse(value.string) orelse
            return error.InvalidUpdateChannelValue;
    }

    if (root.object.get("startup_scrollback")) |startup_scrollback_value| {
        const value = startup_scrollback_value;
        if (value != .bool) return error.InvalidStartupScrollbackType;
        settings.startup_scrollback = value.bool;
    }

    if (root.object.get("prompt_history")) |prompt_history_value| {
        if (prompt_history_value != .object) return error.InvalidPromptHistoryType;
        if (prompt_history_value.object.get("enabled")) |enabled| {
            if (enabled != .bool) return error.InvalidPromptHistoryEnabledType;
            settings.prompt_history_enabled = enabled.bool;
        }
    }

    if (root.object.get("effort")) |effort_value| {
        const value = effort_value;
        switch (value) {
            .string => |raw| settings.effort = types.ReasoningEffort.parse(raw) orelse return error.InvalidEffortValue,
            .null => settings.effort = .auto,
            else => return error.InvalidEffortType,
        }
    }

    if (root.object.get("statusLine")) |statusline_value| {
        const value = statusline_value;
        if (value != .object) {
            if (!tolerate_non_object_user_containers) return error.InvalidStatusLineType;
        } else {
            if (value.object.get("context")) |v| {
                if (v != .bool) return error.InvalidStatusLineContextType;
                settings.statusline_context = v.bool;
            }
            if (value.object.get("session")) |v| {
                if (v != .bool) return error.InvalidStatusLineSessionType;
                settings.statusline_session = v.bool;
            }
            if (parse_workspace_statusline) {
                if (value.object.get("workspace")) |v| {
                    if (v != .bool) return error.InvalidStatusLineWorkspaceType;
                    settings.statusline_workspace = v.bool;
                }
            }
        }
    }

    if (root.object.get("notifications")) |notifications_value| {
        if (notifications_value != .object) return error.InvalidNotificationsType;
        if (notifications_value.object.get("turn_end")) |value| {
            if (value != .bool) return error.InvalidNotificationTurnEndType;
            settings.notification_turn_end = value.bool;
        }
        if (notifications_value.object.get("attention_required")) |value| {
            if (value != .bool) return error.InvalidNotificationAttentionRequiredType;
            settings.notification_attention_required = value.bool;
        }
        if (notifications_value.object.get("max")) |value| {
            if (value != .bool) return error.InvalidNotificationMaxType;
            settings.notification_max = value.bool;
        }
    }

    if (root.object.get("permission")) |permission_value| {
        const value = permission_value;
        settings.permission_rules.deinit(alloc);
        settings.permission_rules = try parsePermissionConfig(alloc, value);
        settings.has_permission_rules = true;
    }
}

fn parseProjectSafeFields(settings: *Settings, root: std.json.Value) !void {
    if (root.object.get("max_agent_steps")) |max_agent_steps_value| {
        const value = max_agent_steps_value;
        if (value != .integer) return error.InvalidMaxAgentStepsType;
        if (value.integer < 0) return error.InvalidMaxAgentStepsValue;
        settings.max_agent_steps = std.math.cast(usize, value.integer) orelse return error.InvalidMaxAgentStepsValue;
    }

    if (root.object.get("max_tool_result_bytes")) |max_tool_result_bytes_value| {
        const value = max_tool_result_bytes_value;
        if (value != .integer) return error.InvalidMaxToolResultBytesType;
        if (value.integer < @as(i64, @intCast(tool_result_limits.min_configured_tool_result_bytes))) return error.InvalidMaxToolResultBytesValue;
        settings.max_tool_result_bytes = std.math.cast(usize, value.integer) orelse return error.InvalidMaxToolResultBytesValue;
    }

    if (root.object.get("context")) |context_value| {
        const value = context_value;
        if (value != .bool) return error.InvalidContextType;
        settings.context = value.bool;
    }
}

fn mergeSettings(target: *Settings, incoming: *Settings, alloc: Allocator) void {
    target.models.mergeOwnedFrom(alloc, &incoming.models);
    if (incoming.provider) |value| target.provider = value;
    if (incoming.permission_mode) |value| target.permission_mode = value;
    if (incoming.credential_source) |value| target.credential_source = value;
    if (incoming.yolo_acknowledged) |value| target.yolo_acknowledged = value;
    if (incoming.max_agent_steps) |value| target.max_agent_steps = value;
    if (incoming.max_tool_result_bytes) |value| target.max_tool_result_bytes = value;
    target.context_limits.merge(incoming.context_limits);
    if (incoming.first_call_tool_choice) |value| target.first_call_tool_choice = value;
    if (incoming.context) |value| target.context = value;
    if (incoming.fast_mode) |value| target.fast_mode = value;
    if (incoming.slash_menu_categories) |value| target.slash_menu_categories = value;
    if (incoming.collapse_tool_calls) |value| target.collapse_tool_calls = value;
    if (incoming.auto_upgrade) |value| target.auto_upgrade = value;
    if (incoming.update_channel) |value| target.update_channel = value;
    if (incoming.startup_scrollback) |value| target.startup_scrollback = value;
    if (incoming.prompt_history_enabled) |value| target.prompt_history_enabled = value;
    if (incoming.effort) |value| target.effort = value;

    if (incoming.statusline_context) |value| target.statusline_context = value;
    if (incoming.statusline_session) |value| target.statusline_session = value;
    if (incoming.statusline_workspace) |value| target.statusline_workspace = value;
    if (incoming.notification_turn_end) |value| target.notification_turn_end = value;
    if (incoming.notification_attention_required) |value| target.notification_attention_required = value;
    if (incoming.notification_max) |value| target.notification_max = value;

    if (incoming.has_permission_rules) {
        target.permission_rules.deinit(alloc);
        target.permission_rules = incoming.permission_rules;
        incoming.permission_rules = .{};
        target.has_permission_rules = true;
        incoming.has_permission_rules = false;
    }
}

fn parsePermissionConfig(alloc: Allocator, value: std.json.Value) !types.PermissionRuleSet {
    var rules: std.ArrayList(types.PermissionRule) = .empty;
    errdefer {
        for (rules.items) |rule| {
            alloc.free(rule.permission);
            alloc.free(rule.pattern);
        }
        rules.deinit(alloc);
    }

    switch (value) {
        .string => |action| {
            try rules.append(alloc, try parsePermissionRuleFromParts(alloc, "*", "*", parsePermissionAction(action) orelse return error.InvalidPermissionAction));
        },
        .object => |permission_map| {
            var it = permission_map.iterator();
            while (it.next()) |entry| {
                const permission = std.mem.trim(u8, entry.key_ptr.*, " \t\r\n");
                if (permission.len == 0) return error.InvalidPermissionRuleTool;

                switch (entry.value_ptr.*) {
                    .string => |action| {
                        try rules.append(alloc, try parsePermissionRuleFromParts(alloc, permission, "*", parsePermissionAction(action) orelse return error.InvalidPermissionAction));
                    },
                    .object => |pattern_map| {
                        var pattern_it = pattern_map.iterator();
                        while (pattern_it.next()) |pattern_entry| {
                            if (pattern_entry.value_ptr.* != .string) return error.InvalidPermissionAction;
                            const pattern = std.mem.trim(u8, pattern_entry.key_ptr.*, " \t\r\n");
                            try rules.append(alloc, try parsePermissionRuleFromParts(alloc, permission, pattern, parsePermissionAction(pattern_entry.value_ptr.*.string) orelse return error.InvalidPermissionAction));
                        }
                    },
                    else => return error.InvalidPermissionRulesType,
                }
            }
        },
        else => return error.InvalidPermissionRulesType,
    }

    return .{ .rules = try rules.toOwnedSlice(alloc) };
}

fn freeStringSlice(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

fn parsePermissionRuleFromParts(alloc: Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRule {
    const owned_permission = try alloc.dupe(u8, permission);
    errdefer alloc.free(owned_permission);

    return .{
        .permission = owned_permission,
        .pattern = try alloc.dupe(u8, pattern),
        .action = action,
    };
}

fn serializeJsonObject(alloc: Allocator, root: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeJsonValue(&out.writer, root);
    return try out.toOwnedSlice();
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| try std.json.Stringify.value(s, .{}, writer),
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .number_string => |s| try writer.writeAll(s),
    }
}

fn normalizeWorkspaceRoot(workspace_root: []const u8) []const u8 {
    var end = workspace_root.len;
    while (end > 1 and workspace_root[end - 1] == '/') {
        end -= 1;
    }
    return workspace_root[0..end];
}

fn writeFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn writeRepeatedByteAbsolute(path: []const u8, byte: u8, count: usize) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());

    var chunk: [1024]u8 = undefined;
    @memset(&chunk, byte);

    var remaining = count;
    while (remaining > 0) {
        const n = @min(remaining, chunk.len);
        try file.writeStreamingAll(io_mod.getIo(), chunk[0..n]);
        remaining -= n;
    }
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

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn expectPermissionRule(rule: types.PermissionRule, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !void {
    try std.testing.expectEqualStrings(permission, rule.permission);
    try std.testing.expectEqualStrings(pattern, rule.pattern);
    try std.testing.expectEqual(action, rule.action);
}

fn expectIgnoredProjectKey(diagnostics: []const ConfigDiagnostic, key: []const u8) !void {
    for (diagnostics) |diagnostic| {
        if (diagnostic.layer != .project or
            diagnostic.cause != .ignored_project_user_only_setting or
            diagnostic.setting_key == null)
        {
            continue;
        }
        if (std.mem.eql(u8, diagnostic.setting_key.?, key)) return;
    }
    return error.TestExpectedEqual;
}

fn readSettingsBytesForTest(alloc: Allocator, home: []const u8) ![]u8 {
    const path = try profile_paths.settingsPath(alloc, home);
    defer alloc.free(path);

    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_settings_bytes);
}

fn expectOneTrailingNewline(bytes: []const u8) !void {
    try std.testing.expect(bytes.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), bytes[bytes.len - 1]);
    if (bytes.len > 1) {
        try std.testing.expect(bytes[bytes.len - 2] != '\n');
    }
}

fn workspaceOverrideObject(root: *std.json.Value, workspace_root: []const u8) !*std.json.ObjectMap {
    if (root.* != .object) return error.InvalidSettingsShape;
    const workspaces = root.object.getPtr("workspaces") orelse return error.TestExpectedEqual;
    if (workspaces.* != .object) return error.TestExpectedEqual;
    const workspace = workspaces.object.getPtr(workspace_root) orelse return error.TestExpectedEqual;
    if (workspace.* != .object) return error.TestExpectedEqual;
    return &workspace.object;
}







































































