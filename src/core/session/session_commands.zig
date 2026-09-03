const std = @import("std");
const app_permission_runtime = @import("../app/app_permission_runtime.zig");
const app_session_runtime = @import("../app/app_session_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const collections = @import("../shared/collections.zig");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const output_contracts = @import("../output/output_contracts.zig");
const permissions = @import("../permissions/permissions.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const prompt_history_runtime = @import("../app/prompt_history_runtime.zig");
const provider_runtime = @import("../app/provider_runtime.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const render_request = @import("../../ui/render_request.zig");

const freeStringList = collections.freeStringList;
const containsIgnoreCase = text_utils.containsIgnoreCase;
const permissions_usage = "usage: /permissions [ask|auto|yolo|reset]\n       /permissions remember <allow|deny> <tool-name> <arguments-json>\n       /permissions revoke <rule-id>";

pub fn reportUserSettingsCommit(
    app: anytype,
    label: []const u8,
    patch: config_runtime.UserSettingsPatch,
    outcome: config_runtime.CommitOutcome,
    session_error: ?anyerror,
    // False when the caller announces state; drops the redundant "saved" line.
    announce_commit: bool,
) !?config_runtime.ConfigSources {
    var detailed = loadDetailedSettingsForNotice(app) catch |err| {
        debug_trace.logf(
            "config",
            "{s} post-commit source resolution failed err={s}",
            .{ label, @errorName(err) },
        );
        try writeUserSettingsCommitUnknownSource(
            app,
            label,
            outcome,
            session_error,
            err,
        );
        return null;
    };
    defer detailed.deinit(app.alloc);
    if (postCommitResolutionError(detailed)) |err| {
        debug_trace.logf(
            "config",
            "{s} post-commit source resolution diagnostic err={s}",
            .{ label, @errorName(err) },
        );
        try writeUserSettingsCommitUnknownSource(
            app,
            label,
            outcome,
            session_error,
            err,
        );
        return null;
    }

    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();

    const benign_commit = "saved to user settings (scope=user)";
    try out.writer.writeAll(benign_commit);
    try appendShadowedUserSources(&out.writer, patch, detailed.sources);
    try appendCommitCleanup(&out.writer, outcome);
    if (session_error) |err| {
        try out.writer.print("; current-session recovery degraded ({s})", .{@errorName(err)});
    }
    const text = try out.toOwnedSlice();
    defer app.alloc.free(text);
    // Keep the line when any warning suffix was appended.
    if (announce_commit or !std.mem.eql(u8, text, benign_commit)) {
        try app.writeDomainNotice(.{ .topic = label, .tone = .neutral, .body = text }, true);
    }
    return detailed.sources;
}

fn writeUserSettingsCommitUnknownSource(
    app: anytype,
    label: []const u8,
    outcome: config_runtime.CommitOutcome,
    session_error: ?anyerror,
    resolution_error: anyerror,
) !void {
    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();

    try out.writer.print(
        "saved to user settings (scope=user); next-startup source unknown ({s})",
        .{@errorName(resolution_error)},
    );
    try appendCommitCleanup(&out.writer, outcome);
    if (session_error) |err| {
        try out.writer.print("; current-session recovery degraded ({s})", .{@errorName(err)});
    }
    const text = try out.toOwnedSlice();
    defer app.alloc.free(text);
    try app.writeDomainNotice(.{ .topic = label, .tone = .warning, .body = text }, true);
}

pub fn reportUserSettingsFailure(
    app: anytype,
    label: []const u8,
    err: anyerror,
    cleanup: config_runtime.LegacyCleanup,
    runtime_changed: bool,
) !void {
    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();

    if (err == error.SettingsCommitIndeterminate) {
        try out.writer.print(
            "user settings persistence uncertain (scope=user, error={s})",
            .{@errorName(err)},
        );
    } else {
        try out.writer.print(
            "{s}not saved to user settings ({s})",
            .{ if (runtime_changed) "active for this process but " else "", @errorName(err) },
        );
    }
    try appendLegacyCleanup(&out.writer, cleanup);
    const text = try out.toOwnedSlice();
    defer app.alloc.free(text);
    try app.writeDomainNotice(.{ .topic = label, .tone = .@"error", .body = text }, true);
}

fn loadDetailedSettingsForNotice(app: anytype) !config_runtime.DetailedSettings {
    if (comptime @hasDecl(@TypeOf(app.*), "loadDetailedSettingsForNotice")) {
        return app.loadDetailedSettingsForNotice();
    }
    return config_runtime.loadMergedSettingsDetailed(app.alloc, app.workspace_root);
}

fn postCommitResolutionError(
    detailed: config_runtime.DetailedSettings,
) ?anyerror {
    for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.layer != .user) continue;
        switch (diagnostic.cause) {
            .malformed_settings => return error.InvalidSettingsFormat,
            .settings_too_large => return error.SettingsPrimaryTooLarge,
            .durable_path_unsafe => return error.DurablePathUnsafe,
            .private_state_permissions_unsupported => return error.PrivateStatePermissionsUnsupported,
            .invalid_model_id => return error.InvalidModelValue,
            .retired_skill_match_fuzzy => return error.InvalidSettingsFormat,
            .invalid_context_limits => return error.InvalidSettingsFormat,
            .invalid_additional_directories => return error.InvalidSettingsFormat,
            .ignored_project_user_only_setting,
            .legacy_workspace_preferences,
            .manual_backup_available,
            => {},
        }
    }
    return null;
}

fn appendShadowedUserSources(
    writer: *std.Io.Writer,
    patch: config_runtime.UserSettingsPatch,
    sources: config_runtime.ConfigSources,
) !void {
    var wrote_header = false;
    const model_source = if (patch.model_preference) |preference|
        sources.models.get(preference.provider)
    else
        .compiled_default;
    try appendShadowedUserSource(writer, "model", patch.model_preference != null, model_source, &wrote_header);
    try appendShadowedUserSource(writer, "permission_mode", patch.permission_mode != null, sources.permission_mode, &wrote_header);
    try appendShadowedUserSource(writer, "effort", patch.effort != null, sources.effort, &wrote_header);
    try appendShadowedUserSource(writer, "fast_mode", patch.fast_mode != null, sources.fast_mode, &wrote_header);
    try appendShadowedUserSource(writer, "startup_scrollback", patch.startup_scrollback != null, sources.startup_scrollback, &wrote_header);
    try appendShadowedUserSource(writer, "prompt_history", patch.prompt_history_enabled != null, sources.prompt_history_enabled, &wrote_header);
    if (patch.statusline_item) |item| {
        const source: ?config_runtime.ConfigSource = switch (item.item) {
            .context => sources.statusline_context,
            .session => sources.statusline_session,
            .workspace => null,
        };
        if (source) |resolved| {
            const field = switch (item.item) {
                .context => "statusLine.context",
                .session => "statusLine.session",
                .workspace => unreachable,
            };
            try appendShadowedUserSource(writer, field, true, resolved, &wrote_header);
        }
    }
    try appendShadowedUserSource(
        writer,
        "notifications.turn_end",
        patch.notification_turn_end != null,
        sources.notification_turn_end,
        &wrote_header,
    );
    try appendShadowedUserSource(
        writer,
        "notifications.attention_required",
        patch.notification_attention_required != null,
        sources.notification_attention_required,
        &wrote_header,
    );
    try appendShadowedUserSource(
        writer,
        "notifications.max",
        patch.notification_max != null,
        sources.notification_max,
        &wrote_header,
    );
}

fn appendShadowedUserSource(
    writer: *std.Io.Writer,
    field: []const u8,
    present: bool,
    source: config_runtime.ConfigSource,
    wrote_header: *bool,
) !void {
    if (!present or source == .user_global) return;
    if (!wrote_header.*) {
        try writer.writeAll("; fresh sessions here use higher-precedence ");
        wrote_header.* = true;
    } else {
        try writer.writeAll(", ");
    }
    try writer.print("{s}={s}", .{ field, @tagName(source) });
}

fn appendCommitCleanup(writer: *std.Io.Writer, outcome: config_runtime.CommitOutcome) !void {
    switch (outcome) {
        .unchanged => {},
        .committed => |committed| try appendLegacyCleanup(writer, committed.cleanup),
    }
}

fn appendLegacyCleanup(writer: *std.Io.Writer, cleanup: config_runtime.LegacyCleanup) !void {
    if (cleanup.fields_removed > 0) {
        try writer.print(
            "; normalized {d} legacy value{s} across {d} workspace{s}",
            .{
                cleanup.fields_removed,
                if (cleanup.fields_removed == 1) "" else "s",
                cleanup.workspaces_changed,
                if (cleanup.workspaces_changed == 1) "" else "s",
            },
        );
    }
    for (cleanup.recovery_paths) |path| {
        try writer.print("; recovery={s}", .{path});
    }
}

pub fn Commands(comptime App: type) type {
    return struct {
        fn update_channel_label(app: *App) []const u8 {
            if (comptime @hasField(App, "upgrader")) {
                const Upgrader = @TypeOf(app.upgrader);
                if (comptime @hasDecl(Upgrader, "channel")) {
                    return app.upgrader.channel().label();
                }
            }
            return "stable";
        }

        pub fn showStatus(app: *App) !void {
            const auth = app.auth.statusSnapshot();
            const text = try (output_contracts.StatusSnapshot{
                .model = provider_runtime.model(app),
                .provider = provider_runtime.provider(app),
                .update_channel = update_channel_label(app),
                .build_channel = if (@hasDecl(App, "build_update_channel")) App.build_update_channel.label() else "stable",
                .build_revision = if (@hasDecl(App, "build_revision")) App.build_revision else "",
                .auth = auth,
                .auth_help = auth.missingHelp(.interactive),
                .permission_mode = app.permission_engine.mode,
                .workspace_root = app.workspace_root,
                .history_turns = app.session.historyLen(),
                .session_permission_grants = app.permission_engine.grants.items.len,
                .agent_step_limit = app.agent_step_limit,
            }).renderInteractiveBody(app.alloc);
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{ .topic = "status", .tone = .neutral, .body = text }, true);
        }

        pub fn handleSettings(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (trimmed.len == 0) {
                try writeSettingsStatus(app);
                return;
            }

            const first = splitFirstWord(trimmed) orelse {
                try writeSettingsUsage(app);
                return;
            };
            if (!std.ascii.eqlIgnoreCase(first.word, "startup-scrollback")) {
                try writeSettingsUsage(app);
                return;
            }

            const value_split = splitFirstWord(first.rest);
            if (value_split) |split| {
                if (split.rest.len != 0) {
                    try writeSettingsUsage(app);
                    return;
                }
                if (std.ascii.eqlIgnoreCase(split.word, "on")) {
                    try saveStartupScrollbackSetting(app, true);
                    return;
                }
                if (std.ascii.eqlIgnoreCase(split.word, "off")) {
                    try saveStartupScrollbackSetting(app, false);
                    return;
                }
                try writeSettingsUsage(app);
                return;
            }

            var settings = config_runtime.loadMergedSettings(app.alloc, app.workspace_root) catch |err| {
                try writeSettingsLoadError(app, err);
                return;
            };
            defer settings.deinit(app.alloc);

            try saveStartupScrollbackSetting(app, !(settings.startup_scrollback orelse true));
        }

        pub fn handleModel(app: *App, query: []const u8) !void {
            if (query.len == 0) {
                try app.writeDomainNotice(.{ .topic = "model", .tone = .neutral, .body = provider_runtime.model(app) }, true);
                return;
            }

            const resolved = try resolveModelQuery(app, query);
            defer app.alloc.free(resolved);
            try setResolvedModel(app, resolved, true);
        }

        pub fn handlePermissions(app: *App, rest: []const u8) !void {
            if (rest.len == 0) {
                try writePermissionsStatus(app);
                return;
            }

            if (std.ascii.eqlIgnoreCase(rest, "ask")) {
                try app_permission_runtime.Runtime(App).selectMode(app, .ask);
                try app.writeDomainNotice(.{ .topic = "permissions", .tone = .neutral, .body = "mode set to ask" }, true);
                return;
            }

            if (std.ascii.eqlIgnoreCase(rest, "auto")) {
                try app_permission_runtime.Runtime(App).selectMode(app, .auto);
                try app.writeDomainNotice(.{ .topic = "permissions", .tone = .neutral, .body = "mode set to auto" }, true);
                return;
            }

            if (std.ascii.eqlIgnoreCase(rest, "yolo")) {
                try app_permission_runtime.Runtime(App).selectMode(app, .yolo);
                try app.writeDomainNotice(.{ .topic = "permissions", .tone = .warning, .body = "mode set to yolo" }, true);
                return;
            }

            if (std.ascii.eqlIgnoreCase(rest, "reset")) {
                try app_permission_runtime.Runtime(App).reset(app);
                try app.writeDomainNotice(.{ .topic = "permissions", .tone = .neutral, .body = "permissions reset to ask, session grants cleared" }, true);
                return;
            }

            try app.writeDomainNotice(.{ .topic = "permissions", .tone = .@"error", .body = permissions_usage }, true);
        }

        pub fn handleAllowlist(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (trimmed.len == 0) {
                try writeAllowlistStatus(app, .effective);
                return;
            }

            const first = splitFirstWord(trimmed).?;
            if (std.ascii.eqlIgnoreCase(first.word, "view")) {
                const view = parseAllowlistView(first.rest) orelse {
                    try writeAllowlistUsage(app);
                    return;
                };
                try writeAllowlistStatus(app, view);
                return;
            }

            var permission_scope: config_runtime.PermissionScope = .local;
            var action = first;
            if (std.ascii.eqlIgnoreCase(first.word, "user") or
                std.ascii.eqlIgnoreCase(first.word, "local"))
            {
                permission_scope = if (std.ascii.eqlIgnoreCase(first.word, "user")) .user else .local;
                action = splitFirstWord(first.rest) orelse {
                    try writeAllowlistUsage(app);
                    return;
                };
            }

            if (std.ascii.eqlIgnoreCase(action.word, "add")) {
                try handleAllowlistAdd(app, permission_scope, action.rest);
                return;
            }

            if (std.ascii.eqlIgnoreCase(action.word, "remove")) {
                try handleAllowlistRemove(app, permission_scope, action.rest);
                return;
            }

            if (std.ascii.eqlIgnoreCase(action.word, "reset")) {
                try handleAllowlistReset(app, permission_scope, action.rest);
                return;
            }

            try writeAllowlistUsage(app);
        }

        pub fn handleHistory(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (std.ascii.eqlIgnoreCase(trimmed, "off")) {
                app.prompt_history.disable();
                var attempt = config_runtime.attemptUserPreferences(
                    app.alloc,
                    .{ .prompt_history_enabled = false },
                );
                defer attempt.deinit(app.alloc);
                switch (attempt) {
                    .failure => |failure| {
                        try reportUserSettingsFailure(
                            app,
                            "history",
                            failure.err,
                            failure.cleanup,
                            true,
                        );
                        return;
                    },
                    .outcome => |outcome| _ = try reportUserSettingsCommit(
                        app,
                        "history",
                        .{ .prompt_history_enabled = false },
                        outcome,
                        null,
                        true,
                    ),
                }
                return;
            }

            if (std.ascii.eqlIgnoreCase(trimmed, "on")) {
                var attempt = config_runtime.attemptUserPreferences(
                    app.alloc,
                    .{ .prompt_history_enabled = true },
                );
                defer attempt.deinit(app.alloc);
                switch (attempt) {
                    .failure => |failure| {
                        app.prompt_history.disable();
                        try reportUserSettingsFailure(
                            app,
                            "history",
                            failure.err,
                            failure.cleanup,
                            false,
                        );
                        return;
                    },
                    .outcome => |outcome| {
                        app.prompt_history.enable();
                        _ = try reportUserSettingsCommit(
                            app,
                            "history",
                            .{ .prompt_history_enabled = true },
                            outcome,
                            null,
                            true,
                        );
                    },
                }
                return;
            }

            try app.writeDomainNotice(.{ .topic = "history", .tone = .@"error", .body = "prompt history options: on, off" }, true);
        }

        fn writeAllowlistUsage(app: *App) !void {
            try app.writeDomainNotice(.{
                .topic = "allowlist",
                .tone = .@"error",
                .body = "usage: /allowlist [view [effective|local|user]|[local|user] add|remove|reset ...]",
            }, true);
        }

        fn handleAllowlistAdd(
            app: *App,
            permission_scope: config_runtime.PermissionScope,
            raw: []const u8,
        ) !void {
            const target = (try parseAllowlistTargetAlloc(app.alloc, app.toolRegistry(), raw)) orelse {
                try app.writeDomainNotice(.{
                    .topic = "allowlist",
                    .tone = .@"error",
                    .body = "usage: /allowlist add [command|tool|url|web-fetch-domain] <pattern>",
                }, true);
                return;
            };
            defer target.deinit(app.alloc);

            var outcome = config_runtime.addPermissionRule(
                app.alloc,
                permission_scope,
                permissionWorkspaceRoot(app, permission_scope),
                target.category,
                target.pattern,
                .allow,
            ) catch |err| {
                const notice_rule_write_fail = try std.fmt.allocPrint(
                    app.alloc,
                    "failed to add rule to settings (scope={s}, error={s})",
                    .{ @tagName(permission_scope), @errorName(err) },
                );
                defer app.alloc.free(notice_rule_write_fail);
                try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .@"error", .body = notice_rule_write_fail }, true);
                debug_trace.logf(
                    "config",
                    "allowlist add failed scope={s} err={s}",
                    .{ @tagName(permission_scope), @errorName(err) },
                );
                return;
            };
            defer outcome.deinit(app.alloc);

            try finishAllowlistMutation(app, permission_scope, "added", target);
        }

        fn handleAllowlistRemove(
            app: *App,
            permission_scope: config_runtime.PermissionScope,
            raw: []const u8,
        ) !void {
            const target = (try parseAllowlistTargetAlloc(app.alloc, app.toolRegistry(), raw)) orelse {
                try app.writeDomainNotice(.{
                    .topic = "allowlist",
                    .tone = .@"error",
                    .body = "usage: /allowlist remove [command|tool|url|web-fetch-domain] <pattern>",
                }, true);
                return;
            };
            defer target.deinit(app.alloc);

            var outcome = config_runtime.removePermissionRule(
                app.alloc,
                permission_scope,
                permissionWorkspaceRoot(app, permission_scope),
                target.category,
                target.pattern,
            ) catch |err| {
                const notice = try std.fmt.allocPrint(
                    app.alloc,
                    "failed to remove rule from settings (scope={s}, error={s})",
                    .{ @tagName(permission_scope), @errorName(err) },
                );
                defer app.alloc.free(notice);
                try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .@"error", .body = notice }, true);
                debug_trace.logf(
                    "config",
                    "allowlist remove failed scope={s} err={s}",
                    .{ @tagName(permission_scope), @errorName(err) },
                );
                return;
            };
            defer outcome.deinit(app.alloc);
            if (outcome == .unchanged) {
                const msg = try formatAllowlistChange(app.alloc, "no matching rule for", target, permission_scope, "");
                defer app.alloc.free(msg);
                try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .neutral, .body = msg }, true);
                return;
            }

            try finishAllowlistMutation(app, permission_scope, "removed", target);
        }

        fn handleAllowlistReset(
            app: *App,
            permission_scope: config_runtime.PermissionScope,
            raw: []const u8,
        ) !void {
            const reset_scope = parseAllowlistResetScope(raw) orelse {
                try app.writeDomainNotice(.{
                    .topic = "allowlist",
                    .tone = .@"error",
                    .body = "usage: /allowlist reset [commands|tools|urls|web-fetch-domains|all]",
                }, true);
                return;
            };

            var outcome = config_runtime.removeAllowlistRules(
                app.alloc,
                permission_scope,
                permissionWorkspaceRoot(app, permission_scope),
                reset_scope,
            ) catch |err| {
                const notice_reset_fail = try std.fmt.allocPrint(
                    app.alloc,
                    "failed to reset rules in settings (scope={s}, error={s})",
                    .{ @tagName(permission_scope), @errorName(err) },
                );
                defer app.alloc.free(notice_reset_fail);
                try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .@"error", .body = notice_reset_fail }, true);
                debug_trace.logf(
                    "config",
                    "allowlist reset failed scope={s} err={s}",
                    .{ @tagName(permission_scope), @errorName(err) },
                );
                return;
            };
            defer outcome.deinit(app.alloc);
            const removed: usize = switch (outcome) {
                .unchanged => 0,
                .committed => |committed| committed.permission_rules_removed,
            };

            var detailed = loadDetailedSettingsForNotice(app) catch |err| {
                const msg = try std.fmt.allocPrint(
                    app.alloc,
                    "reset {s}: removed {d} rule{s} (scope={s}); saved but effective source unknown and runtime reload failed ({s})",
                    .{
                        allowlistResetScopeLabel(reset_scope),
                        removed,
                        if (removed == 1) "" else "s",
                        @tagName(permission_scope),
                        @errorName(err),
                    },
                );
                defer app.alloc.free(msg);
                try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .warning, .body = msg }, true);
                return;
            };
            defer detailed.deinit(app.alloc);
            if (postCommitResolutionError(detailed)) |err| {
                const msg = try std.fmt.allocPrint(
                    app.alloc,
                    "reset {s}: removed {d} rule{s} (scope={s}); saved but effective source unknown and runtime reload failed ({s})",
                    .{
                        allowlistResetScopeLabel(reset_scope),
                        removed,
                        if (removed == 1) "" else "s",
                        @tagName(permission_scope),
                        @errorName(err),
                    },
                );
                defer app.alloc.free(msg);
                try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .warning, .body = msg }, true);
                return;
            }
            replaceEffectivePermissionRules(app, &detailed);

            const shadow = permissionShadowLabel(detailed.permission_sources, permission_scope);
            const msg = try std.fmt.allocPrint(
                app.alloc,
                "reset {s}: removed {d} rule{s} (scope={s}){s}{s}",
                .{
                    allowlistResetScopeLabel(reset_scope),
                    removed,
                    if (removed == 1) "" else "s",
                    @tagName(permission_scope),
                    if (shadow.len > 0) "; user rules shadowed by " else "",
                    shadow,
                },
            );
            defer app.alloc.free(msg);
            try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .neutral, .body = msg }, true);
        }

        pub fn toggleFast(app: *App) !void {
            try toggleFastForModel(app, provider_runtime.model(app), true);
        }

        fn toggleFastForModel(app: *App, model: []const u8, announce: bool) !void {
            if (app.fast_mode) {
                try applyFastMode(app, false, announce, true);
                return;
            }
            if (!model_capabilities.resolveForApp(App, app, model).supports_fast_mode) {
                if (announce) {
                    try app.writeDomainNotice(.{
                        .topic = "fast",
                        .tone = .neutral,
                        .body = "This model does not come with a fast mode.",
                    }, true);
                }
                app.shell.render_requests.request(.footer);
                return;
            }

            try applyFastMode(app, !app.fast_mode, announce, true);
        }

        fn applyFastMode(app: *App, enabled: bool, announce: bool, persist: bool) !void {
            const previous = app.fast_mode;
            app.fast_mode = enabled;
            app.worker.syncQueuedPromptFastMode(app.fast_mode);
            debug_trace.logf(
                "session",
                "fast mode changed old={s} new={s} model={s} supports_fast={s}",
                .{
                    if (previous) "true" else "false",
                    if (app.fast_mode) "true" else "false",
                    provider_runtime.model(app),
                    if (model_capabilities.resolveForApp(App, app, provider_runtime.model(app)).supports_fast_mode) "true" else "false",
                },
            );

            if (persist) {
                try persistPreferenceTargets(
                    app,
                    .{ .fast_mode = app.fast_mode },
                    "fast",
                    !announce,
                );
            }

            if (announce) {
                const label = if (app.fast_mode) "on" else "off";
                try app.writeDomainNotice(.{ .topic = "fast", .tone = .neutral, .body = label }, true);
                if (comptime @hasDecl(App, "playInteractionSound")) app.playInteractionSound();
            }
            app.shell.render_requests.request(.footer);
        }

        fn applyEffort(app: *App, effort: types.ReasoningEffort, announce: bool, persist: bool) !void {
            app.effort = effort;
            app.worker.syncQueuedPromptEffort(app.effort);

            if (persist) {
                try persistPreferenceTargets(
                    app,
                    .{ .effort = app.effort },
                    "effort",
                    !announce,
                );
            }

            if (announce) {
                try app.writeDomainNotice(.{ .topic = "effort", .tone = .neutral, .body = app.effort.label() }, true);
            }
            app.shell.render_requests.request(.footer);
        }

        pub fn selectEffortFromSettings(app: *App, effort: types.ReasoningEffort) !void {
            try applyEffort(app, effort, false, true);
        }

        pub fn selectModelFromPicker(app: *App, model: []const u8, effort: types.ReasoningEffort, fast_mode: bool) !void {
            try setResolvedModelRuntime(app, model, true);
            var patch = app_session_runtime.SessionPreferencePatch{
                .provider = provider_runtime.provider(app),
                .model = model,
            };
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (capabilities.reasoning_efforts.len == 0) {
                if (capabilities.supports_fast_mode) {
                    try applyFastMode(app, fast_mode, false, false);
                    patch.fast_mode = fast_mode;
                }
            } else {
                try applyEffort(app, effort, false, false);
                patch.effort = effort;
                if (capabilities.supports_fast_mode) {
                    try applyFastMode(app, fast_mode, false, false);
                    patch.fast_mode = fast_mode;
                }
            }
            try persistPreferenceTargets(app, patch, "model picker", false);
        }

        fn permissionWorkspaceRoot(
            app: *App,
            permission_scope: config_runtime.PermissionScope,
        ) ?[]const u8 {
            return switch (permission_scope) {
                .user => null,
                .local => app.workspace_root,
            };
        }

        fn replaceEffectivePermissionRules(
            app: *App,
            detailed: *config_runtime.DetailedSettings,
        ) void {
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
            if (detailed.settings.has_permission_rules) {
                app.permission_engine.replaceRules(app.alloc, detailed.settings.permission_rules);
                detailed.settings.permission_rules = .{};
                detailed.settings.has_permission_rules = false;
            } else {
                app.permission_engine.rules.deinit(app.alloc);
                app.permission_engine.rules = .{};
            }
        }

        fn finishAllowlistMutation(
            app: *App,
            permission_scope: config_runtime.PermissionScope,
            verb: []const u8,
            target: AllowlistTarget,
        ) !void {
            var detailed = loadDetailedSettingsForNotice(app) catch |err| {
                const detail = try std.fmt.allocPrint(
                    app.alloc,
                    "saved but effective source unknown and runtime reload failed ({s})",
                    .{@errorName(err)},
                );
                defer app.alloc.free(detail);
                const msg = try formatAllowlistChange(app.alloc, verb, target, permission_scope, detail);
                defer app.alloc.free(msg);
                try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .warning, .body = msg }, true);
                return;
            };
            defer detailed.deinit(app.alloc);
            if (postCommitResolutionError(detailed)) |err| {
                const detail = try std.fmt.allocPrint(
                    app.alloc,
                    "saved but effective source unknown and runtime reload failed ({s})",
                    .{@errorName(err)},
                );
                defer app.alloc.free(detail);
                const msg = try formatAllowlistChange(app.alloc, verb, target, permission_scope, detail);
                defer app.alloc.free(msg);
                try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .warning, .body = msg }, true);
                return;
            }
            replaceEffectivePermissionRules(app, &detailed);

            const shadow = permissionShadowLabel(detailed.permission_sources, permission_scope);
            const detail = if (shadow.len > 0)
                try std.fmt.allocPrint(app.alloc, "user rules shadowed by {s}", .{shadow})
            else
                try app.alloc.dupe(u8, "");
            defer app.alloc.free(detail);
            const msg = try formatAllowlistChange(app.alloc, verb, target, permission_scope, detail);
            defer app.alloc.free(msg);
            try app.writeDomainNotice(.{ .topic = "allowlist", .tone = .neutral, .body = msg }, true);
        }

        fn writeAllowlistStatus(app: *App, view: AllowlistView) !void {
            var detailed = loadDetailedSettingsForNotice(app) catch |err| {
                try writeSettingsLoadError(app, err);
                return;
            };
            defer detailed.deinit(app.alloc);
            for (detailed.diagnostics) |diagnostic| {
                switch (diagnostic.cause) {
                    .durable_path_unsafe => {
                        try writeSettingsLoadError(app, error.DurablePathUnsafe);
                        return;
                    },
                    .private_state_permissions_unsupported => {
                        try writeSettingsLoadError(app, error.PrivateStatePermissionsUnsupported);
                        return;
                    },
                    else => {},
                }
            }
            replaceEffectivePermissionRules(app, &detailed);

            const rules = switch (view) {
                .effective => app.permission_engine.rules.rules,
                .local => detailed.permission_sources.local.rules,
                .user => detailed.permission_sources.user.rules,
            };

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();

            if (hasAllowlistRules(rules)) {
                try out.writer.print("{s} persistent allow rules:\n", .{@tagName(view)});
                try writeAllowlistRuleGroups(&out.writer, rules);
            } else {
                try out.writer.print("{s} persistent allow rules: (none)\n", .{@tagName(view)});
            }
            const shadow = permissionShadowLabel(detailed.permission_sources, .user);
            if ((view == .effective or view == .user) and
                detailed.permission_sources.user.rules.len > 0 and
                shadow.len > 0)
            {
                try out.writer.print("user rules are shadowed by {s}\n", .{shadow});
            }
            const web_fetch_warning_count = permissions.webFetchRuleWarningCount(rules);
            if (web_fetch_warning_count > 0) {
                try out.writer.print("ignored {d} malformed web_fetch rule{s}; expected domain:<canonical-hostname>\n", .{
                    web_fetch_warning_count,
                    if (web_fetch_warning_count == 1) "" else "s",
                });
            }

            const text = try out.toOwnedSlice();
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{
                .topic = "allowlist",
                .tone = if (web_fetch_warning_count == 0) .neutral else .warning,
                .body = std.mem.trimEnd(u8, text, "\n"),
            }, true);
        }

        fn writePermissionsStatus(app: *App) !void {
            const status = try app.permission_engine.formatPermissionsNoticeBody(app.alloc, app.workspace_root);
            defer app.alloc.free(status);
            const notice = try std.fmt.allocPrint(app.alloc, "{s}\n{s}", .{ status, permissions_usage });
            defer app.alloc.free(notice);
            try app.writeDomainNotice(.{ .topic = "permissions", .tone = .neutral, .body = notice }, true);
        }

        fn writeSettingsStatus(app: *App) !void {
            var detailed = config_runtime.loadMergedSettingsDetailed(app.alloc, app.workspace_root) catch |err| {
                try writeSettingsLoadError(app, err);
                return;
            };
            defer detailed.deinit(app.alloc);
            const settings = &detailed.settings;

            const startup_scrollback_label = if (settings.startup_scrollback orelse true) "on" else "off";
            const msg = try std.fmt.allocPrint(app.alloc, "model: {s}\nmodel_config_source: {s}\npermission_mode: {s}\nworkspace: {s}\nstep_limit: {d}\nstartup_scrollback: {s}", .{
                provider_runtime.model(app),
                @tagName(detailed.sources.models.get(.gateway)),
                permissions.permissionModeLabel(app.permission_engine.mode),
                app.workspace_root,
                app.agent_step_limit,
                startup_scrollback_label,
            });
            defer app.alloc.free(msg);
            try app.writeDomainNotice(.{ .topic = "settings", .tone = .neutral, .body = msg }, true);
        }

        fn saveStartupScrollbackSetting(app: *App, enabled: bool) !void {
            var attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                .{ .startup_scrollback = enabled },
            );
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| {
                    try reportUserSettingsFailure(
                        app,
                        "startup-scrollback",
                        failure.err,
                        failure.cleanup,
                        false,
                    );
                    return;
                },
                .outcome => |outcome| {
                    const sources = try reportUserSettingsCommit(
                        app,
                        "startup-scrollback",
                        .{ .startup_scrollback = enabled },
                        outcome,
                        null,
                        false,
                    );
                    const label = if (enabled) "on" else "off";
                    var out: std.Io.Writer.Allocating = .init(app.alloc);
                    defer out.deinit();
                    try out.writer.print("startup_scrollback: {s} ", .{label});
                    if (sources) |resolved| {
                        switch (resolved.startup_scrollback) {
                            .user_global => try out.writer.writeAll(
                                "(applies on next launch)",
                            ),
                            else => try out.writer.print(
                                "(saved user default; current source={s})",
                                .{@tagName(resolved.startup_scrollback)},
                            ),
                        }
                    } else {
                        try out.writer.writeAll(
                            "(saved user default; next-launch source unknown)",
                        );
                    }
                    const msg = try out.toOwnedSlice();
                    defer app.alloc.free(msg);
                    try app.writeDomainNotice(.{ .topic = "settings", .tone = .neutral, .body = msg }, true);
                    return;
                },
            }
        }

        fn writeSettingsUsage(app: *App) !void {
            try app.writeDomainNotice(.{
                .topic = "settings",
                .tone = .@"error",
                .body = "usage: /settings [startup-scrollback [on|off]]",
            }, true);
        }

        fn writeSettingsLoadError(app: *App, err: anyerror) !void {
            const msg = try std.fmt.allocPrint(app.alloc, "Failed to load settings: {s}", .{@errorName(err)});
            defer app.alloc.free(msg);
            try app.writeDomainNotice(.{ .topic = "settings", .tone = .@"error", .body = msg }, true);
        }

        fn fetchModelIds(app: *App) !std.ArrayList([]u8) {
            return app.fetchModelIds();
        }

        fn resolveModelQuery(app: *App, query: []const u8) ![]u8 {
            if (try app.snapshotCachedModelIds(app.alloc)) |snapshot| {
                var ids = snapshot;
                defer freeStringList(app.alloc, &ids);
                if (try resolveModelQueryFromIds(app.alloc, ids.items, query)) |resolved| {
                    return resolved;
                }
            }

            var ids = fetchModelIds(app) catch {
                return app.alloc.dupe(u8, query);
            };
            defer freeStringList(app.alloc, &ids);

            if (try resolveModelQueryFromIds(app.alloc, ids.items, query)) |resolved| {
                return resolved;
            }

            return app.alloc.dupe(u8, query);
        }

        fn setResolvedModel(app: *App, resolved: []const u8, announce: bool) !void {
            try setResolvedModelRuntime(app, resolved, announce);
            try persistPreferenceTargets(
                app,
                .{
                    .provider = provider_runtime.provider(app),
                    .model = resolved,
                },
                "model",
                !announce,
            );
        }

        fn persistPreferenceTargets(
            app: *App,
            patch: app_session_runtime.SessionPreferencePatch,
            label: []const u8,
            // False when the caller announces state; failures still report.
            announce_commit: bool,
        ) !void {
            var result = if (comptime @hasDecl(App, "persistRuntimePreferences")) blk: {
                break :blk app.persistRuntimePreferences(patch);
            } else blk: {
                var committed = app_session_runtime.PreferenceCommitResult{};
                const attempt = config_runtime.attemptUserPreferences(
                    app.alloc,
                    patch.userSettingsPatch(),
                );
                switch (attempt) {
                    .outcome => |outcome| committed.settings_outcome = outcome,
                    .failure => |failure| {
                        committed.settings_error = failure.err;
                        committed.settings_failure_cleanup = failure.cleanup;
                    },
                }
                break :blk committed;
            };
            defer result.deinit(app.alloc);

            if (result.settings_error) |err| {
                debug_trace.logf(
                    "session",
                    "{s} settings persistence failed err={s}",
                    .{ label, @errorName(err) },
                );
                try reportUserSettingsFailure(
                    app,
                    label,
                    err,
                    result.settings_failure_cleanup,
                    true,
                );
            } else if (result.settings_outcome) |outcome| {
                _ = try reportUserSettingsCommit(
                    app,
                    label,
                    patch.userSettingsPatch(),
                    outcome,
                    result.session_error,
                    announce_commit,
                );
            }
            if (result.session_error) |err| {
                debug_trace.logf(
                    "session",
                    "{s} session persistence failed err={s}",
                    .{ label, @errorName(err) },
                );
                if (result.settings_outcome == null) {
                    try app.writeDomainNotice(.{
                        .topic = label,
                        .tone = .@"error",
                        .body = "failed to persist current session",
                    }, true);
                }
            }
        }

        fn setResolvedModelRuntime(app: *App, resolved: []const u8, announce: bool) !void {
            if (!std.mem.eql(u8, provider_runtime.model(app), resolved)) {
                try provider_runtime.replaceModel(app, resolved);
            }
            const selected = provider_runtime.model(app);
            try app.worker.syncQueuedPromptModel(std.heap.c_allocator, selected);
            if (comptime @hasDecl(App, "persistAcceptedModel")) try app.persistAcceptedModel(selected);
            // Keep the session or workspace discriminator while updating the
            // model shown as secondary terminal-tab context.
            app_session_runtime.Runtime(App).syncTerminalTitle(app);

            if (announce) {
                const active_response = if (comptime @hasField(App, "stream"))
                    app.stream.active
                else
                    false;
                const prefix: []const u8 = if (active_response) "Next turn will use " else "Switched to ";
                const line = try std.fmt.allocPrint(app.alloc, "{s}{s}", .{ prefix, selected });
                defer app.alloc.free(line);
                try app.writeDomainNotice(.{ .topic = "", .tone = .neutral, .body = line }, true);
                if (comptime @hasDecl(App, "playInteractionSound")) app.playInteractionSound();
            }
        }

        fn resolveModelQueryFromIds(alloc: std.mem.Allocator, ids: []const []u8, query: []const u8) !?[]u8 {
            for (ids) |id| {
                if (std.ascii.eqlIgnoreCase(id, query)) {
                    return try alloc.dupe(u8, id);
                }
            }

            var best_score: i32 = 0;
            var best_id: ?[]const u8 = null;

            for (ids) |id| {
                const score = fuzzyModelScore(id, query);
                if (score > best_score) {
                    best_score = score;
                    best_id = id;
                }
            }

            if (best_id) |id| {
                return try alloc.dupe(u8, id);
            }

            return null;
        }
    };
}

fn startsWithWord(text: []const u8, word: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(text, word)) return false;
    if (text.len == word.len) return true;
    return text[word.len] == ' ' or text[word.len] == '\t';
}

const AllowlistKind = enum {
    command,
    tool,
    url,
    web_fetch_domain,
};

const AllowlistTarget = struct {
    kind: AllowlistKind,
    category: []const u8,
    pattern: []const u8,
    pattern_owned: bool = false,

    fn deinit(self: AllowlistTarget, alloc: std.mem.Allocator) void {
        if (self.pattern_owned) alloc.free(self.pattern);
    }
};

fn parseAllowlistTargetAlloc(
    alloc: std.mem.Allocator,
    tool_registry: tool_dispatch.Registry,
    raw: []const u8,
) !?AllowlistTarget {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const kind_split = splitFirstWord(trimmed) orelse return null;
    const pattern = parseQuotedOrRest(kind_split.rest);
    if (pattern.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(kind_split.word, "web-fetch-domain")) {
        const canonical = permissions.canonicalWebFetchDomainPattern(alloc, pattern) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        return .{
            .kind = .web_fetch_domain,
            .category = permissions.web_fetch_permission,
            .pattern = canonical,
            .pattern_owned = true,
        };
    }

    return parseAllowlistTarget(tool_registry, raw);
}

fn parseAllowlistTarget(tool_registry: tool_dispatch.Registry, raw: []const u8) ?AllowlistTarget {
    const trimmed = std.mem.trim(u8, raw, " \t");
    const kind_split = splitFirstWord(trimmed) orelse return null;
    const pattern = parseQuotedOrRest(kind_split.rest);
    if (pattern.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(kind_split.word, "command")) {
        return .{ .kind = .command, .category = "bash", .pattern = pattern };
    }
    if (std.ascii.eqlIgnoreCase(kind_split.word, "url")) {
        return .{ .kind = .url, .category = "url", .pattern = pattern };
    }
    if (std.ascii.eqlIgnoreCase(kind_split.word, "tool")) {
        if (std.mem.eql(u8, pattern, permissions.web_fetch_permission)) return null;
        if (!isKnownAllowlistTool(tool_registry, pattern)) return null;
        return .{ .kind = .tool, .category = permissions.permissionNameForTool(pattern), .pattern = "*" };
    }

    return null;
}

fn isKnownAllowlistTool(tool_registry: tool_dispatch.Registry, name: []const u8) bool {
    if (tool_registry.lookup(name) != null) return true;

    const categories = [_][]const u8{
        "edit",
        "read",
        "glob",
        "grep",
        "skill",
        "memory",
        permissions.web_search_permission,
    };
    for (categories) |category| {
        if (std.mem.eql(u8, name, category)) return true;
    }
    return false;
}

const WordSplit = struct {
    word: []const u8,
    rest: []const u8,
};

fn splitFirstWord(text: []const u8) ?WordSplit {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    for (trimmed, 0..) |c, idx| {
        if (c == ' ' or c == '\t') {
            return .{
                .word = trimmed[0..idx],
                .rest = std.mem.trimStart(u8, trimmed[idx + 1 ..], " \t"),
            };
        }
    }
    return .{ .word = trimmed, .rest = "" };
}

fn parseQuotedOrRest(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len > 0 and trimmed[0] == '"') {
        if (std.mem.findScalarPos(u8, trimmed, 1, '"')) |close| {
            return trimmed[1..close];
        }
        return trimmed[1..];
    }
    return trimmed;
}

fn parseAllowlistResetScope(raw: []const u8) ?config_runtime.AllowlistResetScope {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return .all;
    if (std.ascii.eqlIgnoreCase(trimmed, "command") or std.ascii.eqlIgnoreCase(trimmed, "commands")) return .commands;
    if (std.ascii.eqlIgnoreCase(trimmed, "tool") or std.ascii.eqlIgnoreCase(trimmed, "tools")) return .tools;
    if (std.ascii.eqlIgnoreCase(trimmed, "url") or std.ascii.eqlIgnoreCase(trimmed, "urls")) return .urls;
    if (std.ascii.eqlIgnoreCase(trimmed, "web-fetch-domain") or std.ascii.eqlIgnoreCase(trimmed, "web-fetch-domains")) return .web_fetch_domains;
    return null;
}

const AllowlistView = enum {
    effective,
    local,
    user,
};

fn parseAllowlistView(raw: []const u8) ?AllowlistView {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "effective")) return .effective;
    if (std.ascii.eqlIgnoreCase(trimmed, "local")) return .local;
    if (std.ascii.eqlIgnoreCase(trimmed, "user")) return .user;
    return null;
}

fn permissionShadowLabel(
    views: config_runtime.PermissionSourceViews,
    permission_scope: config_runtime.PermissionScope,
) []const u8 {
    if (permission_scope != .user or views.user.rules.len == 0) return "";
    if (views.user_shadowed_by_local) return "local settings";
    return "";
}

fn allowlistResetScopeLabel(scope: config_runtime.AllowlistResetScope) []const u8 {
    return switch (scope) {
        .all => "all",
        .commands => "commands",
        .tools => "tools",
        .urls => "urls",
        .web_fetch_domains => "web-fetch-domains",
    };
}

const AllowlistDisplayKind = enum {
    tool,
    command,
    url,
    web_fetch_domain,
};

const AllowlistRuleGroup = struct {
    kind: AllowlistDisplayKind,
    name: []const u8,
};

fn hasAllowlistRules(rules: []const types.PermissionRule) bool {
    for (rules) |rule| {
        if (allowlistRuleDisplayable(rule)) return true;
    }
    return false;
}

fn writeAllowlistRuleGroups(writer: *std.Io.Writer, rules: []const types.PermissionRule) !void {
    try writeAllowlistSection(writer, rules, .tool);
    try writeAllowlistSection(writer, rules, .command);
    try writeAllowlistSection(writer, rules, .url);
    try writeAllowlistSection(writer, rules, .web_fetch_domain);
}

fn writeAllowlistSection(writer: *std.Io.Writer, rules: []const types.PermissionRule, kind: AllowlistDisplayKind) !void {
    if (!hasAllowlistKind(rules, kind)) return;

    switch (kind) {
        .tool => try writer.writeAll("  tools:\n"),
        .command => try writer.writeAll("  commands:\n"),
        .url => try writer.writeAll("  urls:\n"),
        .web_fetch_domain => try writer.writeAll("  web-fetch domains:\n"),
    }

    for (rules, 0..) |rule, idx| {
        if (!allowlistRuleDisplayable(rule)) continue;
        const group = allowlistRuleGroup(rule);
        if (group.kind != kind) continue;
        if (allowlistGroupSeen(rules[0..idx], group)) continue;
        try writeAllowlistGroupLine(writer, rules, group);
    }
}

fn hasAllowlistKind(rules: []const types.PermissionRule, kind: AllowlistDisplayKind) bool {
    for (rules) |rule| {
        if (!allowlistRuleDisplayable(rule)) continue;
        if (allowlistRuleGroup(rule).kind == kind) return true;
    }
    return false;
}

fn writeAllowlistGroupLine(writer: *std.Io.Writer, rules: []const types.PermissionRule, group: AllowlistRuleGroup) !void {
    switch (group.kind) {
        .tool => try writer.print("    {s}: ", .{group.name}),
        .command, .url, .web_fetch_domain => try writer.writeAll("    "),
    }

    var first = true;
    for (rules) |rule| {
        if (!allowlistRuleDisplayable(rule)) continue;
        if (!sameAllowlistGroup(allowlistRuleGroup(rule), group)) continue;
        if (!first) try writer.writeAll(", ");
        first = false;
        try writeAllowlistPattern(writer, group, rule.pattern);
    }
    try writer.writeByte('\n');
}

fn writeAllowlistPattern(writer: *std.Io.Writer, group: AllowlistRuleGroup, pattern: []const u8) !void {
    if (group.kind == .tool and std.mem.eql(u8, pattern, "*") and isWorkspacePathToolPermission(group.name)) {
        try writer.writeAll("workspace");
        return;
    }
    try writer.writeAll(pattern);
}

fn isWorkspacePathToolPermission(permission: []const u8) bool {
    const path_permissions = [_][]const u8{
        "edit",
        "read",
        "glob",
        "grep",
    };
    for (path_permissions) |path_permission| {
        if (std.mem.eql(u8, permission, path_permission)) return true;
    }
    return false;
}

fn allowlistGroupSeen(rules: []const types.PermissionRule, group: AllowlistRuleGroup) bool {
    for (rules) |rule| {
        if (!allowlistRuleDisplayable(rule)) continue;
        if (sameAllowlistGroup(allowlistRuleGroup(rule), group)) return true;
    }
    return false;
}

fn allowlistRuleGroup(rule: types.PermissionRule) AllowlistRuleGroup {
    if (std.mem.eql(u8, rule.permission, "bash")) {
        return .{ .kind = .command, .name = "command" };
    }
    if (std.mem.eql(u8, rule.permission, "url")) {
        return .{ .kind = .url, .name = "url" };
    }
    if (std.mem.eql(u8, rule.permission, permissions.web_fetch_permission)) {
        return .{ .kind = .web_fetch_domain, .name = "web-fetch-domain" };
    }
    return .{ .kind = .tool, .name = rule.permission };
}

fn allowlistRuleDisplayable(rule: types.PermissionRule) bool {
    if (rule.action != .allow) return false;
    if (std.mem.eql(u8, rule.permission, permissions.web_fetch_permission)) {
        return permissions.isCanonicalWebFetchDomainPattern(rule.pattern);
    }
    return true;
}

fn sameAllowlistGroup(a: AllowlistRuleGroup, b: AllowlistRuleGroup) bool {
    return a.kind == b.kind and std.mem.eql(u8, a.name, b.name);
}

fn formatAllowlistChange(
    alloc: std.mem.Allocator,
    verb: []const u8,
    target: AllowlistTarget,
    permission_scope: config_runtime.PermissionScope,
    detail: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s} ", .{verb});
    switch (target.kind) {
        .command => try out.writer.print("command: \"{s}\"", .{target.pattern}),
        .url => try out.writer.print("url: \"{s}\"", .{target.pattern}),
        .tool => try out.writer.print("tool {s}: \"{s}\"", .{ target.category, target.pattern }),
        .web_fetch_domain => try out.writer.print("web-fetch-domain: \"{s}\"", .{target.pattern}),
    }
    try out.writer.print(" (scope={s})", .{@tagName(permission_scope)});
    if (detail.len > 0) try out.writer.print("; {s}", .{detail});
    return out.toOwnedSlice();
}

/// Scores prefix and substring matches above token, subsequence, and partial matches.
/// Higher scores rank first; zero means no match.
pub fn fuzzyModelScore(id: []const u8, query: []const u8) i32 {
    if (query.len == 0) return 0;
    if (id.len == 0) return 0;

    if (containsIgnoreCase(id, query)) {
        const bonus: i32 = @intCast(@min(query.len, 50));
        if (std.mem.startsWith(u8, id, query) or
            (id.len > query.len and id[id.len - query.len - 1] == '/' and
                std.ascii.eqlIgnoreCase(id[id.len - query.len ..], query)))
        {
            return 120 + bonus;
        }
        return 100 + bonus;
    }

    var tokens_buf: [16][]const u8 = undefined;
    const token_count = splitQueryTokens(query, &tokens_buf);
    if (token_count > 1) {
        var all_present = true;
        for (tokens_buf[0..token_count]) |token| {
            if (!containsIgnoreCase(id, token)) {
                all_present = false;
                break;
            }
        }
        if (all_present) {
            return 80 + @as(i32, @intCast(token_count)) * 5;
        }
    }

    var qi: usize = 0;
    var matched: usize = 0;
    for (id) |c| {
        if (qi < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[qi])) {
            qi += 1;
            matched += 1;
        }
    }
    if (qi == query.len) {
        return 40 + @as(i32, @intCast(@min(matched, 20)));
    }

    if (token_count >= 1) {
        var any_match = false;
        for (tokens_buf[0..token_count]) |token| {
            if (containsIgnoreCase(id, token)) {
                any_match = true;
                break;
            }
        }
        if (any_match) return 20;
    }

    return 0;
}

fn splitQueryTokens(query: []const u8, out: *[16][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < query.len and count < 16) {
        while (i < query.len and isSplitter(query[i])) : (i += 1) {}
        const start = i;
        while (i < query.len and !isSplitter(query[i])) : (i += 1) {}
        if (i > start) {
            out[count] = query[start..i];
            count += 1;
        }
    }
    return count;
}

fn isSplitter(c: u8) bool {
    return c == ' ' or c == '-' or c == '/' or c == '_';
}

const FakeSession = struct {
    history_len: usize = 0,

    fn historyLen(self: *FakeSession) usize {
        return self.history_len;
    }
};

const FakeWorker = struct {
    synced_mode: ?types.PermissionMode = null,
    synced_state_mode: ?types.PermissionMode = null,
    synced_model: ?[]u8 = null,
    synced_model_alloc: ?std.mem.Allocator = null,
    synced_fast_mode: ?bool = null,
    fast_sync_count: usize = 0,
    synced_effort: ?types.ReasoningEffort = null,
    effort_sync_count: usize = 0,

    fn deinit(self: *FakeWorker) void {
        if (self.synced_model) |model| self.synced_model_alloc.?.free(model);
        self.* = .{};
    }

    pub fn syncQueuedPromptPermissionSnapshot(self: *FakeWorker, snapshot: worker_runtime.PermissionSnapshot) void {
        self.synced_mode = snapshot.mode;
    }

    pub fn syncQueuedPromptPermissionState(self: *FakeWorker, alloc: std.mem.Allocator, grants: []const types.PermissionGrant, snapshot: worker_runtime.PermissionSnapshot) !void {
        _ = alloc;
        _ = grants;
        self.synced_state_mode = snapshot.mode;
    }

    fn syncQueuedPromptModel(self: *FakeWorker, alloc: std.mem.Allocator, model: []const u8) !void {
        if (self.synced_model) |old| {
            self.synced_model_alloc.?.free(old);
            self.synced_model = null;
            self.synced_model_alloc = null;
        }
        self.synced_model = try alloc.dupe(u8, model);
        self.synced_model_alloc = alloc;
    }

    fn syncQueuedPromptFastMode(self: *FakeWorker, enabled: bool) void {
        self.synced_fast_mode = enabled;
        self.fast_sync_count += 1;
    }

    fn syncQueuedPromptEffort(self: *FakeWorker, effort: types.ReasoningEffort) void {
        self.synced_effort = effort;
        self.effort_sync_count += 1;
    }
};

const FakeHistoryCommandApp = struct {
    alloc: std.mem.Allocator,
    workspace_root: []u8,
    prompt_history: prompt_history_runtime.PromptHistoryRuntime = .{},
    transcript: std.ArrayList(u8) = .empty,
    last_tone: ?types.NoticeTone = null,

    fn init(
        alloc: std.mem.Allocator,
        home: []const u8,
        workspace_root: []const u8,
    ) !FakeHistoryCommandApp {
        var app = FakeHistoryCommandApp{
            .alloc = alloc,
            .workspace_root = try alloc.dupe(u8, workspace_root),
        };
        errdefer app.deinit();
        _ = try app.prompt_history.initialize(alloc, home, true, true);
        return app;
    }

    fn deinit(self: *FakeHistoryCommandApp) void {
        self.prompt_history.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.alloc.free(self.workspace_root);
        self.* = undefined;
    }

    fn writeDomainNotice(self: *FakeHistoryCommandApp, notice: types.SemanticNotice, _: bool) !void {
        self.last_tone = notice.tone;
        try self.transcript.appendSlice(self.alloc, notice.body);
        try self.transcript.append(self.alloc, '\n');
    }
};

const FakeApp = struct {
    alloc: std.mem.Allocator,
    workspace_root: []u8,
    tool_registry: tool_dispatch.Registry = .{},
    selected_model: std.ArrayList(u8) = .empty,
    selected_provider: model_provider.ProviderId = .gateway,
    auth: auth_runtime.Runtime = .{},
    permission_engine: permissions.PermissionEngine = .{},
    permission_state: app_permission_runtime.State = .{},
    session: FakeSession = .{},
    worker: FakeWorker = .{},
    shell: struct {
        render_requests: render_request.RenderRequestState = .{},
    } = .{},
    transcript: std.ArrayList(u8) = .empty,
    agent_step_limit: usize = 24,
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    cached_ids: ?[]const []const u8 = null,
    gateway_metadata_model: ?[]const u8 = null,
    gateway_metadata: model_capabilities.GatewayMetadata = .{},
    fetch_ids: []const []const u8 = &.{},
    fail_fetch: bool = false,
    last_tone: ?types.NoticeTone = null,
    preference_commit_count: usize = 0,
    last_preference_model: std.ArrayList(u8) = .empty,
    last_preference_provider: ?model_provider.ProviderId = null,
    last_preference_effort: ?types.ReasoningEffort = null,
    last_preference_fast_mode: ?bool = null,
    preference_settings_error: ?anyerror = null,
    preference_session_error: ?anyerror = null,
    preference_failure_cleanup: config_runtime.LegacyCleanup = .{},
    post_commit_resolution_error: ?anyerror = null,
    post_commit_resolution_diagnostic: ?config_runtime.ConfigDiagnosticCause = null,
    post_commit_resolution_count: usize = 0,
    permission_mode_preference_commit_count: usize = 0,
    last_preference_permission_mode: ?types.PermissionMode = null,
    semantic_write_count: usize = 0,
    terminal_title_label: [128]u8 = undefined,
    terminal_title_label_len: usize = 0,

    fn init(alloc: std.mem.Allocator, workspace_root: []const u8, model: []const u8) !FakeApp {
        var app = FakeApp{
            .alloc = alloc,
            .workspace_root = try alloc.dupe(u8, workspace_root),
        };
        errdefer app.deinit();
        try app.selected_model.appendSlice(alloc, model);
        return app;
    }

    fn deinit(self: *FakeApp) void {
        self.selected_model.deinit(self.alloc);
        self.auth.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.worker.deinit();
        self.transcript.deinit(self.alloc);
        self.last_preference_model.deinit(self.alloc);
        self.preference_failure_cleanup.deinit(self.alloc);
        self.alloc.free(self.workspace_root);
        self.* = undefined;
    }

    fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.semantic_write_count += 1;
        self.last_tone = notice.tone;
        const rendered = if (notice.topic.len > 0)
            try std.fmt.allocPrint(self.alloc, "● {c}{s}: {s}\n", .{
                std.ascii.toUpper(notice.topic[0]),
                notice.topic[1..],
                notice.body,
            })
        else
            try std.fmt.allocPrint(self.alloc, "● {s}\n", .{notice.body});
        defer self.alloc.free(rendered);
        try self.transcript.appendSlice(self.alloc, rendered);
    }

    fn text(self: *const FakeApp) []const u8 {
        return self.transcript.items;
    }

    fn clearTranscript(self: *FakeApp) void {
        self.transcript.clearRetainingCapacity();
    }

    fn toolRegistry(self: *const FakeApp) tool_dispatch.Registry {
        return self.tool_registry;
    }

    // Public so `@hasDecl` sees it from the session runtime, which is where
    // the terminal title is now resolved.
    pub fn terminalTitle(self: *FakeApp) host.TerminalTitle {
        return .{
            .context = self,
            .set_fn = setTerminalTitleLabelForTest,
            .clear_fn = clearTerminalTitleForTest,
        };
    }

    fn setTerminalTitleLabelForTest(raw: ?*anyopaque, label: []const u8) void {
        const self: *FakeApp = @ptrCast(@alignCast(raw.?));
        self.terminal_title_label_len = @min(label.len, self.terminal_title_label.len);
        @memcpy(
            self.terminal_title_label[0..self.terminal_title_label_len],
            label[0..self.terminal_title_label_len],
        );
    }

    fn clearTerminalTitleForTest(raw: ?*anyopaque) void {
        const self: *FakeApp = @ptrCast(@alignCast(raw.?));
        self.terminal_title_label_len = 0;
    }

    fn terminalTitleLabelText(self: *const FakeApp) []const u8 {
        return self.terminal_title_label[0..self.terminal_title_label_len];
    }

    fn snapshotCachedModelIds(self: *FakeApp, alloc: std.mem.Allocator) !?std.ArrayList([]u8) {
        if (self.cached_ids) |ids| return try makeStringList(alloc, ids);
        return null;
    }

    pub fn persistPermissionModePreference(self: *FakeApp, mode: types.PermissionMode) !void {
        self.permission_mode_preference_commit_count += 1;
        self.last_preference_permission_mode = mode;
    }

    pub fn resolvedModelCapabilities(self: *FakeApp, model: []const u8) model_capabilities.Capabilities {
        if (self.gateway_metadata_model) |metadata_model| {
            if (std.mem.eql(u8, metadata_model, model)) {
                return model_capabilities.resolveCapabilities(model, self.gateway_metadata);
            }
        }
        return model_capabilities.capabilitiesForModel(model);
    }

    fn setGatewayControls(
        self: *FakeApp,
        model: []const u8,
        efforts: []const types.ReasoningEffort,
        supports_fast_mode: bool,
    ) void {
        self.gateway_metadata_model = model;
        self.gateway_metadata = .{
            .reasoning_efforts = .fromSlice(efforts),
            .supports_fast_mode = supports_fast_mode,
        };
    }

    fn fetchModelIds(self: *FakeApp) !std.ArrayList([]u8) {
        if (self.fail_fetch) return error.FetchFailed;
        return makeStringList(self.alloc, self.fetch_ids);
    }

    fn loadDetailedSettingsForNotice(self: *FakeApp) !config_runtime.DetailedSettings {
        self.post_commit_resolution_count += 1;
        if (self.post_commit_resolution_error) |err| return err;
        if (self.post_commit_resolution_diagnostic) |cause| {
            const diagnostics = try self.alloc.alloc(config_runtime.ConfigDiagnostic, 1);
            diagnostics[0] = .{ .layer = .user, .cause = cause };
            return .{
                .settings = .{},
                .diagnostics = diagnostics,
            };
        }
        return config_runtime.loadMergedSettingsDetailed(self.alloc, self.workspace_root);
    }

    fn persistRuntimePreferences(
        self: *FakeApp,
        patch: app_session_runtime.SessionPreferencePatch,
    ) app_session_runtime.PreferenceCommitResult {
        self.preference_commit_count += 1;
        self.last_preference_provider = patch.provider;
        self.last_preference_model.clearRetainingCapacity();
        if (patch.model) |model| {
            self.last_preference_model.appendSlice(self.alloc, model) catch
                return .{ .settings_error = error.OutOfMemory };
        }
        self.last_preference_effort = patch.effort;
        self.last_preference_fast_mode = patch.fast_mode;
        if (self.preference_settings_error == null) {
            const attempt = config_runtime.attemptUserPreferences(
                self.alloc,
                patch.userSettingsPatch(),
            );
            return switch (attempt) {
                .outcome => |outcome| .{
                    .settings_outcome = outcome,
                    .session_error = self.preference_session_error,
                },
                .failure => |failure| .{
                    .settings_error = failure.err,
                    .settings_failure_cleanup = failure.cleanup,
                    .session_error = self.preference_session_error,
                },
            };
        }
        const cleanup = self.preference_failure_cleanup;
        self.preference_failure_cleanup = .{};
        return .{
            .settings_error = self.preference_settings_error,
            .settings_failure_cleanup = cleanup,
            .session_error = self.preference_session_error,
        };
    }
};

fn makeStringList(alloc: std.mem.Allocator, ids: []const []const u8) !std.ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(alloc, &list);
    for (ids) |id| {
        try list.append(alloc, try alloc.dupe(u8, id));
    }
    return list;
}

fn expectTranscriptContains(app: *const FakeApp, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, app.text(), needle) != null);
}

fn writeFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}
