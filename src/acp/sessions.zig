const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const mcp_servers = @import("mcp_servers.zig");
const server = @import("server.zig");
const session_test_controls = @import("session_test_controls.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_store = @import("../core/session/session_store.zig");
const js_host_session_store = @import("../core/session/js_host_session_store.zig");
const session_runtime = @import("../core/session/session.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const mcp_contract = @import("../core/mcp/mcp_contract.zig");
const project_config = @import("../core/mcp/project_config.zig");
const workspace_config = @import("../core/mcp/workspace_config.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const host = @import("../core/hosts/host.zig");
const host_target = @import("../core/hosts/target.zig");
const credentials = @import("../core/auth/credentials.zig");
const model_provider = @import("../core/config/model_provider.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const subagent_resume_admission = @import("../core/subagent/resume_admission.zig");
const types = @import("../core/shared/types.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const command_specs = @import("../core/slash_commands/command_specs.zig");
const test_builtin_gateway = if (builtin.is_test)
    @import("../builtins/gateway.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;
const writeJsonStr = jsonrpc.writeJsonStr;

pub fn handleNewWasmSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    try server.releaseActiveSession(state);

    var durable = try freshAcpState(state, alloc);
    var durable_owned = true;
    defer if (durable_owned) durable.deinit(alloc);
    const session_id = try alloc.dupe(u8, durable.id);
    var session_id_owned = true;
    defer if (session_id_owned) alloc.free(session_id);
    const model = try alloc.dupe(u8, durable.preferences.model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model);
    var session_rt = session_runtime.SessionRuntime.initWithProviders(
        state.cfg.max_history_turns,
        state.cfg.provider_set.deferredUsageProviders(),
    );
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    const revision = js_host_session_store.commit(alloc, durable, null) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to create session",
        });
    var revision_owned = true;
    defer if (revision_owned) alloc.free(revision);

    state.active_session = .{
        .session_id = session_id,
        .wasm_state = durable,
        .wasm_revision = revision,
        .model = model,
        .provider = durable.preferences.provider,
        .mode = state.cfg.mode_registry.default_mode_id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = state.fast_mode,
        .effort = state.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = state.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = session_rt,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    durable_owned = false;
    revision_owned = false;
    session_id_owned = false;
    model_owned = false;
    session_rt_owned = false;

    try writeNewSessionResponse(state, alloc, msg, session_id);
}

pub fn commitWasmSessionLocked(alloc: Allocator, session: *server.ActiveSessionState) !void {
    const base = if (session.wasm_state) |*value| value else return error.SessionPersistenceUnavailable;
    var next = try base.dupe(alloc);
    var next_owned = true;
    defer if (next_owned) next.deinit(alloc);
    const history = try session.session_rt.snapshotHistory(alloc);
    types.freeHistoryTurnSlice(alloc, next.history);
    next.history = history;
    const permission_state = try session.session_rt.snapshotPermissionState(alloc);
    next.permission_state.deinit(alloc);
    next.permission_state = permission_state;
    next.context_history_start = session.session_rt.context_history_start;
    next.conversation_language = session.session_rt.languageSnapshot();
    next.updated_at_ms = io_mod.milliTimestamp();
    alloc.free(next.preferences.model);
    next.preferences.model = try alloc.dupe(u8, session.model);
    next.preferences.provider = session.provider;
    next.preferences.effort = session.effort;
    next.preferences.fast_mode = session.fast_mode;
    const usage = try session.session_rt.usage.snapshot(alloc);
    if (next.usage) |*old| old.deinit(alloc);
    next.usage = usage;

    const revision = try js_host_session_store.commit(alloc, next, session.wasm_revision);
    if (session.wasm_revision) |old| alloc.free(old);
    session.wasm_revision = revision;
    base.deinit(alloc);
    session.wasm_state = next;
    next_owned = false;
}

pub fn commitWasmSession(alloc: Allocator, session: *server.ActiveSessionState) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    try commitWasmSessionLocked(alloc, session);
}

pub fn handleNewSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    var mcp_configs = mcp_servers.parse(alloc, msg.params_raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = mcp_servers.parseErrorMessage(err),
        }),
    };
    defer mcp_configs.deinit(alloc);
    if (!state.cfg.allow_acp_mcp and mcp_configs.items.items.len > 0) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "MCP servers are unavailable in this runtime",
        });
    }
    if (state.cfg.allow_acp_mcp) try appendProjectMcpConfigs(state, alloc, &mcp_configs);
    retireReducedActiveMcp(state, alloc, mcp_configs.items.items);
    var mcp_preparation = try mcp_servers.prepare(
        alloc,
        &mcp_configs,
        state.client_elicitation,
        server.legacyUrlCompletionSink(state),
    );
    defer mcp_preparation.deinit(alloc);
    switch (mcp_preparation) {
        .ready => {},
        .failed => |message| return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
        }),
    }
    const session_mcp = mcp_preparation.takeRuntime();
    var session_mcp_owned = true;
    defer if (session_mcp_owned) {
        if (session_mcp) |runtime| {
            runtime.deinit();
            alloc.destroy(runtime);
        }
    };

    var store = (if (state.cfg.home_override) |home|
        session_store.Store.initFromHome(alloc, home, state.workspace_root)
    else
        session_store.Store.init(alloc, state.workspace_root)) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session store not available",
        });
    var store_owned = true;
    defer if (store_owned) store.deinit(alloc);

    var initial = try freshAcpState(state, alloc);
    defer initial.deinit(alloc);
    var writable = store.startWritableSessionWithOptions(
        alloc,
        initial,
        session_test_controls.logOptions(),
    ) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = "Failed to create session" });
    var writable_owned = true;
    defer if (writable_owned) writable.deinit(alloc);

    const session_id = try alloc.dupe(u8, writable.active_id);
    var session_id_owned = true;
    defer if (session_id_owned) alloc.free(session_id);
    const model_copy = try alloc.dupe(u8, state.selected_model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model_copy);
    const session_dir = try session_store.sessionDirPath(alloc, store.sessions_dir, writable.active_id);
    defer alloc.free(session_dir);
    var session_rt = session_runtime.SessionRuntime.initWithProviders(
        state.cfg.max_history_turns,
        state.cfg.provider_set.deferredUsageProviders(),
    );
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    _ = try session_rt.initializeProfileUsage(alloc, io_mod.getenv("HOME"));
    if (writable.state.usage) |usage| {
        try session_rt.usage.restore(
            alloc,
            usage,
            writable.state.created_at_ms,
        );
    } else {
        session_rt.usage.restoreLegacyWallDuration(
            writable.state.created_at_ms,
        );
    }
    session_rt.configureWebFetchArtifacts(alloc, session_dir);
    server.cancelAndReapActivePrompt(state);
    activateSession(state, store, .{
        .session_id = session_id,
        .writable = writable,
        .model = model_copy,
        .provider = state.provider,
        .fast_mode = state.fast_mode,
        .effort = state.effort,
        .session_rt = session_rt,
        .mcp = session_mcp,
    }) catch {
        _ = store.discardPristineStartedSession(alloc, &writable);
        writable_owned = false;
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to save active session",
        });
    };
    writable_owned = false;
    store_owned = false;
    session_id_owned = false;
    model_owned = false;
    session_rt_owned = false;
    session_mcp_owned = false;

    try writeNewSessionResponse(state, alloc, msg, session_id);
}

fn writeNewSessionResponse(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    session_id: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try writeProviderConfigOption(&out.writer, state.active_session.?.provider);
        try out.writer.writeAll(",");
    }
    try writeModelConfigOption(
        &out.writer,
        state.active_session.?.model,
        state.capability_resolver.catalogEntries(),
    );
    try out.writer.writeAll(",");
    try writeModeConfigOption(
        &out.writer,
        state.cfg.mode_registry,
        state.cfg.mode_registry.default_mode_id,
    );
    try out.writer.writeAll("],\"modes\":{\"currentModeId\":");
    try writeJsonStr(state.cfg.mode_registry.default_mode_id, &out.writer);
    try out.writer.writeAll(",\"availableModes\":");
    try writeModesArray(&out.writer, state.cfg.mode_registry);
    try out.writer.writeAll("}}");

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());

    const commands_json = try buildSlashCommandsJson(alloc);
    defer alloc.free(commands_json);
    try sendAvailableCommands(state, alloc, session_id, commands_json);
}

pub fn handleLoadWasmSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();
    const session_id = if (parsed.value == .object)
        if (parsed.value.object.get("sessionId")) |value|
            if (value == .string) value.string else return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" })
        else
            return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" })
    else
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" });

    if (state.active_session) |*active| {
        if (sameSessionId(active.session_id, session_id)) {
            for (active.session_rt.history.items) |turn| try sendHistoryTurnAsUpdates(state, alloc, session_id, turn);
            return writeLoadSessionResponse(state, alloc, msg, active.model);
        }
    }

    var loaded = (js_host_session_store.load(alloc, session_id) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = "Session could not be loaded" })) orelse
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Session not found" });
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(alloc);
    const sid_copy = try alloc.dupe(u8, loaded.state.id);
    var sid_owned = true;
    defer if (sid_owned) alloc.free(sid_copy);
    if (loaded.state.preferences.provider != .gateway) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Subscription models are unavailable in this WASM runtime",
        });
    }
    const model_copy = try alloc.dupe(u8, loaded.state.preferences.model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model_copy);
    var session_rt = session_runtime.SessionRuntime.initWithProviders(state.cfg.max_history_turns, state.cfg.provider_set.deferredUsageProviders());
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    try session_rt.restoreWithPermissionState(
        alloc,
        loaded.state.conversation_language,
        loaded.state.history,
        loaded.state.context_history_start,
        loaded.state.permission_state,
    );
    if (loaded.state.usage) |usage| try session_rt.usage.restore(alloc, usage, loaded.state.created_at_ms);

    try server.releaseActiveSession(state);
    state.active_session = .{
        .session_id = sid_copy,
        .wasm_state = loaded.state,
        .wasm_revision = loaded.revision,
        .model = model_copy,
        .provider = loaded.state.preferences.provider,
        .mode = state.cfg.mode_registry.default_mode_id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = loaded.state.preferences.fast_mode,
        .effort = loaded.state.preferences.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = state.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = session_rt,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    loaded_owned = false;
    sid_owned = false;
    model_owned = false;
    session_rt_owned = false;
    for (state.active_session.?.session_rt.history.items) |turn| try sendHistoryTurnAsUpdates(state, alloc, session_id, turn);
    try writeLoadSessionResponse(state, alloc, msg, state.active_session.?.model);
}

pub fn handleListWasmSessions(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const entries = js_host_session_store.list(alloc) catch
        return state.writer.writeResponse(alloc, msg.id, "{\"sessions\":[]}");
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessions\":[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"sessionId\":");
        try writeJsonStr(entry.id, &out.writer);
        try out.writer.writeAll(",\"cwd\":");
        try writeJsonStr(state.workspace_root, &out.writer);
        try out.writer.writeAll(",\"updatedAt\":");
        const iso = try formatIso8601(alloc, entry.updated_at_ms);
        defer alloc.free(iso);
        try writeJsonStr(iso, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

pub fn handleRemoveWasmSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing params" });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();
    const value = if (parsed.value == .object) parsed.value.object.get("sessionId") else null;
    const session_id = if (value) |id| if (id == .string) id.string else return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" }) else return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" });
    js_host_session_store.remove(session_id) catch return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.internal_error, .message = "Failed to remove session" });
    if (state.active_session) |*active| {
        if (sameSessionId(active.session_id, session_id)) try server.releaseActiveSession(state);
    }
    try state.writer.writeResponse(alloc, msg.id, "null");
}

const RestoreKind = enum {
    load,
    reconnect,

    fn replaysHistory(self: RestoreKind) bool {
        return self == .load;
    }
};

pub fn handleLoadSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    return handleRestoreSession(state, alloc, msg, .load);
}

pub fn handleResumeSession(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    return handleRestoreSession(state, alloc, msg, .reconnect);
}

fn handleRestoreSession(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    kind: RestoreKind,
) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    const session_id = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("sessionId")) |v| {
                if (v == .string) break :blk v.string;
            }
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing sessionId" });
    };

    var mcp_configs = switch (kind) {
        .load => mcp_servers.parse(alloc, msg.params_raw),
        .reconnect => mcp_servers.parseResume(alloc, msg.params_raw),
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = mcp_servers.parseErrorMessage(err),
        }),
    };
    defer mcp_configs.deinit(alloc);
    if (!state.cfg.allow_acp_mcp) {
        if (mcp_configs.items.items.len > 0) {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "MCP servers are unavailable in this runtime",
            });
        }
    } else {
        try appendProjectMcpConfigs(state, alloc, &mcp_configs);
    }
    retireReducedActiveMcp(state, alloc, mcp_configs.items.items);
    var mcp_preparation = try mcp_servers.prepare(
        alloc,
        &mcp_configs,
        state.client_elicitation,
        server.legacyUrlCompletionSink(state),
    );
    defer mcp_preparation.deinit(alloc);
    switch (mcp_preparation) {
        .ready => {},
        .failed => |message| return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = message,
        }),
    }
    const session_mcp = mcp_preparation.takeRuntime();
    var session_mcp_owned = true;
    defer if (session_mcp_owned) {
        if (session_mcp) |runtime| {
            runtime.deinit();
            alloc.destroy(runtime);
        }
    };

    if (state.active_session) |*active| {
        if (sameSessionId(active.session_id, session_id)) {
            server.cancelAndReapActivePrompt(state);
            server.disableSubagentHost(state);
            state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
            const previous_mcp = active.mcp;
            active.mcp = session_mcp;
            session_mcp_owned = false;
            server.applySessionMode(
                state.cfg.mode_registry,
                active,
                state.cfg.mode_registry.default_mode_id,
            );
            state.subagent_authority_mutex.unlock(io_mod.getIo());
            if (previous_mcp) |runtime| {
                runtime.retireAndWait();
                runtime.deinit();
                alloc.destroy(runtime);
            }
            server.enableSubagentHost(state);
            if (kind.replaysHistory()) {
                for (active.session_rt.history.items) |turn| {
                    try sendHistoryTurnAsUpdates(state, alloc, session_id, turn);
                }
            }
            try sendPendingRecoveryUpdate(
                state,
                alloc,
                session_id,
                if (active.writable) |*writable| writable.state.recovery_checkpoint else null,
            );
            return writeLoadSessionResponse(
                state,
                alloc,
                msg,
                active.model,
            );
        }
    }

    var store = (if (state.cfg.home_override) |home|
        session_store.Store.initFromHome(alloc, home, state.workspace_root)
    else
        session_store.Store.init(alloc, state.workspace_root)) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session store not available",
        });
    var store_owned = true;
    defer if (store_owned) store.deinit(alloc);

    const seed_preferences = session_codec.DurableSessionPreferences{
        .provider = state.provider,
        .model = state.configured_model,
        .effort = state.effort,
        .fast_mode = state.fast_mode,
    };
    var writable = subagent_resume_admission.resumeForExternalPrompt(
        store,
        alloc,
        .{ .id = session_id },
        state.workspace_root,
        .{
            .seed_preferences = seed_preferences,
            .log = session_test_controls.logOptions(),
        },
    ) catch |err| return handleLoadFailure(state, alloc, msg, err);
    var writable_owned = true;
    defer if (writable_owned) writable.deinit(alloc);

    const sid_copy = try alloc.dupe(u8, writable.state.id);
    var sid_owned = true;
    defer if (sid_owned) alloc.free(sid_copy);
    const effective_provider = if (state.process_model_override)
        state.provider
    else
        writable.state.preferences.provider;
    const effective_model = if (state.process_model_override)
        state.selected_model
    else
        writable.state.preferences.model;
    if (!try server.selectCredentialForProvider(state, effective_provider)) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = if (effective_provider == .codex)
                credentials.missing_chatgpt_credential_message
            else if (effective_provider == .grok)
                credentials.missing_grok_credential_message
            else
                credentials.missing_credential_message,
        });
    }
    const model_copy = try alloc.dupe(u8, effective_model);
    var model_owned = true;
    defer if (model_owned) alloc.free(model_copy);

    var session_rt = session_runtime.SessionRuntime.initWithProviders(
        state.cfg.max_history_turns,
        state.cfg.provider_set.deferredUsageProviders(),
    );
    var session_rt_owned = true;
    defer if (session_rt_owned) session_rt.deinit(alloc);
    _ = try session_rt.initializeProfileUsage(alloc, io_mod.getenv("HOME"));
    try session_rt.restoreWithPermissionState(
        alloc,
        writable.state.conversation_language,
        writable.state.history,
        writable.state.context_history_start,
        writable.state.permission_state,
    );
    if (writable.state.usage) |usage| {
        try session_rt.usage.restore(
            alloc,
            usage,
            writable.state.created_at_ms,
        );
    } else {
        session_rt.usage.restoreLegacyWallDuration(
            writable.state.created_at_ms,
        );
    }
    const session_dir = try session_store.sessionDirPath(alloc, store.sessions_dir, session_id);
    defer alloc.free(session_dir);

    session_rt.configureWebFetchArtifacts(alloc, session_dir);
    server.cancelAndReapActivePrompt(state);
    activateSession(state, store, .{
        .session_id = sid_copy,
        .writable = writable,
        .model = model_copy,
        .provider = effective_provider,
        .fast_mode = writable.state.preferences.fast_mode,
        .effort = writable.state.preferences.effort,
        .session_rt = session_rt,
        .mcp = session_mcp,
    }) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to save active session",
        });
    writable_owned = false;
    store_owned = false;
    sid_owned = false;
    model_owned = false;
    session_rt_owned = false;
    session_mcp_owned = false;
    if (kind.replaysHistory()) {
        for (state.active_session.?.writable.?.state.history) |turn| {
            try sendHistoryTurnAsUpdates(state, alloc, session_id, turn);
        }
    }
    try sendPendingRecoveryUpdate(
        state,
        alloc,
        session_id,
        state.active_session.?.writable.?.state.recovery_checkpoint,
    );

    try writeLoadSessionResponse(
        state,
        alloc,
        msg,
        state.active_session.?.model,
    );
}

fn detachActiveMcpForAuthorityReduction(
    state: *server.ServerState,
    active: *server.ActiveSessionState,
) *mcp_runtime.McpRuntime {
    server.cancelAndReapActivePrompt(state);
    server.disableSubagentHost(state);
    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    const previous = active.mcp.?;
    active.mcp = null;
    state.subagent_authority_mutex.unlock(io_mod.getIo());
    return previous;
}

fn retireReducedActiveMcp(
    state: *server.ServerState,
    alloc: Allocator,
    next_configs: []const mcp_contract.McpServerConfig,
) void {
    const active = if (state.active_session) |*value| value else return;
    const runtime = active.mcp orelse return;
    if (!runtime.workspaceAuthorityReducedAgainstConfigs(
        next_configs,
        .acp_startup,
    )) return;
    const previous = detachActiveMcpForAuthorityReduction(state, active);
    previous.retireAndWait();
    previous.deinit();
    alloc.destroy(previous);
    server.enableSubagentHost(state);
}

fn appendProjectMcpConfigs(
    state: *server.ServerState,
    alloc: Allocator,
    configs: *mcp_servers.OwnedServerConfigs,
) !void {
    var choices = if (state.cfg.home_override) |home|
        config_runtime.loadProjectMcpChoicesFromHome(alloc, home, state.workspace_root) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("mcp", "ACP workspace MCP choices unavailable err={s}", .{@errorName(err)});
            return;
        }
    else
        config_runtime.loadProjectMcpChoices(alloc, state.workspace_root) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf("mcp", "ACP workspace MCP choices unavailable err={s}", .{@errorName(err)});
            return;
        };
    defer choices.deinit(alloc);

    var workspace = try workspace_config.load(
        alloc,
        state.workspace_root,
        .workspace,
        choices.choices,
    );
    defer workspace.deinit(alloc);
    for (workspace.diagnostics.items) |diagnostic| {
        var name_buf: [256]u8 = undefined;
        var variable_buf: [160]u8 = undefined;
        debug_trace.logf(
            "mcp",
            "ACP workspace MCP config skipped cause={s} server={s} field={s} variable={s}",
            .{
                @tagName(diagnostic.cause),
                if (diagnostic.server_name) |name|
                    debug_trace.terminalPreview(name_buf[0..], name)
                else
                    "none",
                if (diagnostic.environment_field) |field| @tagName(field) else "none",
                if (diagnostic.environment_variable) |name|
                    debug_trace.terminalPreview(variable_buf[0..], name)
                else
                    "none",
            },
        );
    }
    try project_config.appendWorkspaceAfterAcpPrimary(
        alloc,
        &configs.items,
        &workspace.configs,
    );
}

fn sendPendingRecoveryUpdate(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    checkpoint: ?session_codec.RecoveryCheckpoint,
) !void {
    const recovery = checkpoint orelse return;
    try sendUserHistoryChunk(state, alloc, session_id, recovery.user.text);
    try sendExecutionHistory(state, alloc, session_id, recovery.execution);
    if (recovery.assistant_source.len > 0) {
        try sendAgentHistoryChunk(state, alloc, session_id, recovery.assistant_source);
    }
    const attempt = recovery.consumed_provider_attempts +| @intFromBool(recovery.outstanding_reservation);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeModelRecoveryInfoUpdate(&out.writer, .{
        .kind = .terminal_provider_error,
        .failed_attempt = attempt,
        .attempt_limit = recovery.max_provider_attempts,
        .cause = recovery.cause,
        .action = .paused,
        .required_action = if (recovery.tool_state == .uncertain)
            .inspect_uncertain_tool
        else
            .continue_later,
        .diagnostic = types.ModelFailureDiagnostic.forCause(recovery.cause),
    }, true);
    try out.writer.writeByte('}');
    try state.writer.writeNotification(
        alloc,
        "session/update",
        out.writer.buffered(),
    );
}

fn sameSessionId(active_session_id: []const u8, requested_session_id: []const u8) bool {
    return std.mem.eql(u8, active_session_id, requested_session_id);
}

fn writeLoadSessionResponse(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    model: []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try writeProviderConfigOption(&out.writer, state.active_session.?.provider);
        try out.writer.writeAll(",");
    }
    try writeModelConfigOption(
        &out.writer,
        model,
        state.capability_resolver.catalogEntries(),
    );
    try out.writer.writeAll(",");
    try writeModeConfigOption(
        &out.writer,
        state.cfg.mode_registry,
        state.cfg.mode_registry.default_mode_id,
    );
    try out.writer.writeAll("],\"modes\":{\"currentModeId\":");
    try writeJsonStr(state.cfg.mode_registry.default_mode_id, &out.writer);
    try out.writer.writeAll(",\"availableModes\":");
    try writeModesArray(&out.writer, state.cfg.mode_registry);
    try out.writer.writeAll("}}");

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

fn freshAcpState(
    state: *server.ServerState,
    alloc: Allocator,
) !session_codec.DurableSessionState {
    const now = io_mod.milliTimestamp();
    const id = try session_store.generateSessionId(alloc);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, state.workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, state.workspace_root);
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, state.configured_model);
    errdefer alloc.free(model);
    const history = try alloc.alloc(types.HistoryTurn, 0);
    errdefer alloc.free(history);
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = now,
        .updated_at_ms = now,
        .conversation_language = session_runtime.ConversationLanguage.default(),
        .preferences = .{
            .provider = state.provider,
            .model = model,
            .effort = state.effort,
            .fast_mode = state.fast_mode,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

const SessionActivation = struct {
    session_id: []u8,
    writable: session_store.LoadedWritableSession,
    model: []u8,
    provider: model_provider.ProviderId,
    fast_mode: bool,
    effort: types.ReasoningEffort,
    session_rt: session_runtime.SessionRuntime,
    mcp: ?*mcp_runtime.McpRuntime,
};

fn activateSession(
    state: *server.ServerState,
    store: session_store.Store,
    activation: SessionActivation,
) !void {
    try server.releaseActiveSession(state);
    state.active_session = .{
        .session_id = activation.session_id,
        .store = store,
        .writable = activation.writable,
        .model = activation.model,
        .provider = activation.provider,
        .mode = state.cfg.mode_registry.default_mode_id,
        .workspace_root = state.workspace_root,
        .api_key = state.api_key,
        .credential_source = state.credential_source,
        .account_id = state.account_id,
        .agent_step_limit = state.agent_step_limit,
        .max_tool_result_bytes = state.max_tool_result_bytes,
        .fast_mode = activation.fast_mode,
        .effort = activation.effort,
        .first_call_tool_choice = state.first_call_tool_choice,
        .permission_mode = state.permission_mode,
        .permission_rules = state.permission_rules,
        .session_rt = activation.session_rt,
        .mcp = activation.mcp,
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    server.enableSubagentHost(state);
    state.active_session.?.session_rt.attachProfileUsagePublisher(state.alloc);
    if (state.cfg.provider_set.select(activation.provider).deferred_usage == null) {
        state.active_session.?.session_rt.usage.clearReconciliationCredential();
    } else if (state.credential_source) |source| {
        state.active_session.?.session_rt.usage.replaceProviderReconciliationCredential(
            state.alloc,
            activation.provider,
            source,
            state.account_id,
            state.api_key,
        );
    } else {
        state.active_session.?.session_rt.usage.clearReconciliationCredential();
    }
    activateManagedBackground(state, store);
}

fn activateManagedBackground(
    state: *server.ServerState,
    store: session_store.Store,
) void {
    const active = if (state.active_session) |*session| session else return;
    const writable = if (active.writable) |*value| value else return;
    state.background.restoreWorkspaceFromStore(
        std.heap.c_allocator,
        store,
        state.workspace_root,
        writable.active_id,
    ) catch {};
    state.background.restoreFromManagedPersistence(
        std.heap.c_allocator,
        writable.childCapability() catch return,
        writable.active_id,
        state.workspace_root,
    ) catch {};
}

fn handleLoadFailure(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    err: anyerror,
) !void {
    debug_trace.logf(
        "acp",
        "session operation=load outcome=failed error={s}",
        .{@errorName(err)},
    );
    if (err == error.SessionCommitIndeterminate) {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to commit session workspace rebind",
        });
        state.terminate_connection = true;
        return;
    }
    if (err == error.SessionWorkspaceRebindFailed) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to persist session workspace rebind",
        });
    }
    if (err == error.SessionBusy) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session is busy",
        });
    }
    if (err == error.InvalidSessionId) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid session ID",
        });
    }
    if (err == error.OneOffSessionNotResumable) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "One-off child sessions cannot accept additional prompts",
        });
    }
    if (err == error.InvalidSessionFormat or
        err == error.UnsupportedSessionSchema or
        err == error.LegacySessionTooLarge or
        err == error.LegacySessionReadResourceExhausted or
        err == error.SessionAuthorityBoundaryUnavailable or
        err == error.SessionAuthorityIntentCleanupPending or
        err == error.SessionPathUnsafe or
        err == error.DurablePathUnsafe)
    {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Session could not be loaded",
        });
    }
    return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Session not found",
    });
}

pub fn handleListSessions(state: *server.ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    var params_arena = std.heap.ArenaAllocator.init(alloc);
    defer params_arena.deinit();
    const params = parseListSessionsParams(params_arena.allocator(), msg) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    var store = (if (state.cfg.home_override) |home|
        session_store.Store.initReadOnlyFromHome(alloc, home, params.cwd orelse state.workspace_root)
    else
        session_store.Store.initReadOnly(alloc, params.cwd orelse state.workspace_root)) catch {
        try state.writer.writeResponse(alloc, msg.id, "{\"sessions\":[]}");
        return;
    };
    defer store.deinit(alloc);

    var page = store.listSessionPage(
        alloc,
        if (params.cwd != null) .current_workspace else .all_workspaces,
        params.continuation,
        session_store.session_list_default_limit,
    ) catch {
        try state.writer.writeResponse(alloc, msg.id, "{\"sessions\":[]}");
        return;
    };
    defer page.deinit(alloc);
    var next_cursor_buf: [320]u8 = undefined;
    const next_cursor = if (page.has_more and page.summaries.items.len > 0)
        try std.fmt.bufPrint(&next_cursor_buf, "v1:{d}:{s}", .{
            page.summaries.items[page.summaries.items.len - 1].updated_at_ms,
            page.summaries.items[page.summaries.items.len - 1].id,
        })
    else
        null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"sessions\":[");
    var wrote_session = false;
    for (page.summaries.items) |summary| {
        const workspace_root = summary.workspace_root orelse {
            debug_trace.logf(
                "acp",
                "session operation=list outcome=omitted id={s} reason=workspace_unknown",
                .{summary.id},
            );
            continue;
        };
        if (!std.fs.path.isAbsolute(workspace_root)) {
            debug_trace.logf(
                "acp",
                "session operation=list outcome=omitted id={s} reason=workspace_not_absolute",
                .{summary.id},
            );
            continue;
        }
        if (wrote_session) try out.writer.writeAll(",");
        wrote_session = true;
        try out.writer.writeAll("{\"sessionId\":");
        try writeJsonStr(summary.id, &out.writer);
        try out.writer.writeAll(",\"cwd\":");
        try writeJsonStr(workspace_root, &out.writer);
        if (summary.title) |title| {
            try out.writer.writeAll(",\"title\":");
            try writeJsonStr(title, &out.writer);
        }
        try out.writer.writeAll(",\"updatedAt\":");
        const iso = try formatIso8601(alloc, summary.updated_at_ms);
        defer alloc.free(iso);
        try writeJsonStr(iso, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");
    if (next_cursor) |cursor| {
        try out.writer.writeAll(",\"nextCursor\":");
        try writeJsonStr(cursor, &out.writer);
    }
    try out.writer.writeAll("}");

    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

const ListSessionsParams = struct {
    cwd: ?[]const u8 = null,
    continuation: ?session_store.ResumableSessionContinuation = null,
};

fn parseListSessionsParams(
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !ListSessionsParams {
    const raw = msg.params_raw orelse return .{};
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return error.InvalidParams;
    if (parsed.value != .object) return error.InvalidParams;
    var result = ListSessionsParams{};
    if (parsed.value.object.get("cwd")) |cwd| {
        if (cwd != .null) {
            if (cwd != .string or !std.fs.path.isAbsolute(cwd.string)) {
                return error.InvalidParams;
            }
            result.cwd = cwd.string;
        }
    }
    if (parsed.value.object.get("cursor")) |cursor| {
        if (cursor != .null) {
            if (cursor != .string) return error.InvalidParams;
            result.continuation = parseListCursor(cursor.string) catch
                return error.InvalidParams;
        }
    }
    return result;
}

fn parseListCursor(raw: []const u8) !session_store.ResumableSessionContinuation {
    if (raw.len == 0 or raw.len > 320) return error.InvalidParams;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidParams, "v1")) {
        return error.InvalidParams;
    }
    const updated_at_ms = std.fmt.parseInt(
        i64,
        fields.next() orelse return error.InvalidParams,
        10,
    ) catch return error.InvalidParams;
    const id = fields.next() orelse return error.InvalidParams;
    if (updated_at_ms < 0 or fields.next() != null) return error.InvalidParams;
    session_store.validateSessionId(id) catch return error.InvalidParams;
    return .{ .updated_at_ms = updated_at_ms, .id = id };
}

fn sendHistoryTurnAsUpdates(state: *server.ServerState, alloc: Allocator, session_id: []const u8, turn: types.HistoryTurn) !void {
    const user_text: []const u8 = switch (turn) {
        .assistant => |a| a.user.text,
        .background_command => |b| b.user.text,
        .interrupted => |i| i.user.text,
        .compacted_summary => |c| c.summary,
    };

    try sendUserHistoryChunk(state, alloc, session_id, user_text);

    switch (turn) {
        .assistant => |assistant| {
            try sendExecutionHistory(state, alloc, session_id, assistant.execution);
            try sendAgentHistoryChunk(state, alloc, session_id, assistant.assistant);
        },
        .background_command => |background| {
            try sendExecutionHistory(state, alloc, session_id, background.execution);
            if (background.assistant) |assistant| {
                if (assistant.len > 0) {
                    try sendAgentHistoryChunk(state, alloc, session_id, assistant);
                }
            }
            try sendAgentHistoryChunk(state, alloc, session_id, "[background command]");
        },
        .interrupted => |i| {
            try sendExecutionHistory(state, alloc, session_id, i.execution);
            if (i.assistant) |assistant| {
                if (assistant.len > 0) try sendAgentHistoryChunk(state, alloc, session_id, assistant);
            }
            try sendAgentHistoryChunk(
                state,
                alloc,
                session_id,
                session_runtime.interruptedTurnNotice(i).body,
            );
        },
        .compacted_summary => {},
    }
}

fn sendUserHistoryChunk(state: *server.ServerState, alloc: Allocator, session_id: []const u8, text: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeUserMessageChunk(&out.writer, text);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn sendExecutionHistory(
    state: *server.ServerState,
    alloc: Allocator,
    session_id: []const u8,
    execution: types.ExecutionMemory,
) !void {
    const text = try session_runtime.formatExecutionReplayContext(alloc, execution) orelse return;
    defer alloc.free(text);
    try sendAgentHistoryChunk(state, alloc, session_id, text);
}

fn sendAgentHistoryChunk(state: *server.ServerState, alloc: Allocator, session_id: []const u8, text: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeAgentMessageChunk(&out.writer, text);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn sendAvailableCommands(state: *server.ServerState, alloc: Allocator, session_id: []const u8, commands_json: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, &out.writer);
    try out.writer.writeAll(",\"update\":");
    try acp_types.writeAvailableCommandsUpdate(&out.writer, commands_json);
    try out.writer.writeAll("}");
    try state.writer.writeNotification(alloc, "session/update", out.writer.buffered());
}

fn buildSlashCommandsJson(alloc: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const commands = [_]struct { name: []const u8, description: []const u8, hint: ?[]const u8 }{
        .{ .name = "compact", .description = "Compact conversation history", .hint = null },
        .{ .name = "undo", .description = "Undo last file change", .hint = null },
        .{ .name = "changes", .description = "Show file changes in this session", .hint = null },
        .{ .name = "review", .description = "Toggle post-edit review", .hint = null },
        .{ .name = "clear", .description = "Clear the screen", .hint = null },
        .{ .name = "reset", .description = "Reset session", .hint = null },
        .{ .name = "help", .description = "Show available commands", .hint = null },
        .{ .name = "status", .description = "Show current status", .hint = null },
        .{ .name = "model", .description = "Switch model", .hint = "model name" },
        .{ .name = "permissions", .description = "Show permission settings", .hint = null },
        .{ .name = "allowlist", .description = "Manage persistent allow rules", .hint = "add command \"git *\"" },
        .{ .name = "rules", .description = "Show active rules", .hint = null },
        .{ .name = "settings", .description = "Show settings", .hint = null },
        .{ .name = "credits", .description = "Show credit balance", .hint = null },
        .{ .name = "mcp", .description = "Show MCP server status", .hint = null },
        .{ .name = "skills", .description = "Show installed skills", .hint = null },
        .{ .name = "fast", .description = "Toggle fast mode for supported models", .hint = null },
    };

    try out.writer.writeAll("[");
    for (commands, 0..) |cmd, i| {
        if (i > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"name\":");
        try writeJsonStr(cmd.name, &out.writer);
        try out.writer.writeAll(",\"description\":");
        try writeJsonStr(cmd.description, &out.writer);
        if (cmd.hint) |hint| {
            try out.writer.writeAll(",\"input\":{\"hint\":");
            try writeJsonStr(hint, &out.writer);
            try out.writer.writeAll("}");
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");

    return try alloc.dupe(u8, out.writer.buffered());
}

fn formatIso8601(alloc: Allocator, timestamp_ms: i64) ![]u8 {
    const epoch_secs: u64 = @intCast(@divTrunc(timestamp_ms, 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

pub fn writeModelConfigOption(
    w: *std.Io.Writer,
    current: []const u8,
    catalog: ?[]const model_catalog.ModelCatalogEntry,
) !void {
    try w.writeAll("{\"id\":\"model\",\"name\":\"Model\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(current, w);
    try w.writeAll(",\"options\":[");
    const entries = catalog orelse &.{};
    var wrote_current = false;
    for (entries, 0..) |entry, i| {
        const id = entry.id;
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"value\":");
        try writeJsonStr(id, w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(id, w);
        try w.writeAll("}");
        if (std.mem.eql(u8, id, current)) wrote_current = true;
    }
    if (!wrote_current) {
        if (entries.len > 0) try w.writeAll(",");
        try w.writeAll("{\"value\":");
        try writeJsonStr(current, w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(current, w);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

pub fn writeProviderConfigOption(
    w: *std.Io.Writer,
    current: model_provider.ProviderId,
) !void {
    try w.writeAll("{\"id\":\"provider\",\"name\":\"Provider\",\"category\":\"model\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(@tagName(current), w);
    try w.writeAll(",\"options\":[{\"value\":\"gateway\",\"name\":\"Vercel AI Gateway\"},{\"value\":\"codex\",\"name\":\"Codex subscription\"}");
    if (comptime !host_target.is_wasm) {
        try w.writeAll(",{\"value\":\"grok\",\"name\":\"Grok subscription\"}");
    }
    try w.writeAll("]}");
}

pub fn writeModeConfigOption(
    w: *std.Io.Writer,
    registry: mode_registry.Registry,
    current: []const u8,
) !void {
    try w.writeAll("{\"id\":\"mode\",\"name\":\"Session Mode\",\"description\":\"Controls how the agent requests permission\",\"category\":\"mode\",\"type\":\"select\",\"currentValue\":");
    try writeJsonStr(current, w);
    try w.writeAll(",\"options\":[");
    for (registry.modes, 0..) |mode, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"value\":");
        try writeJsonStr(mode.id, w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(mode.name, w);
        try w.writeAll(",\"description\":");
        try writeJsonStr(mode.description, w);
        try w.writeAll(",\"permissionMode\":");
        try writeJsonStr(@tagName(mode.permission_mode), w);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeModesArray(w: *std.Io.Writer, registry: mode_registry.Registry) !void {
    try w.writeAll("[");
    for (registry.modes, 0..) |mode, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonStr(mode.id, w);
        try w.writeAll(",\"name\":");
        try writeJsonStr(mode.name, w);
        try w.writeAll(",\"description\":");
        try writeJsonStr(mode.description, w);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

fn gatherNoopContextForTest(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopStaticContextForTest(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContextForTest(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}
