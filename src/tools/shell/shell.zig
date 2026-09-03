const std = @import("std");
const builtin = @import("builtin");
const command_admission = @import("../../core/permissions/command_admission.zig");
const command_contract = @import("../../core/execution/command_contract.zig");
const command_environment = @import("../../core/execution/command_environment.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const managed_contract = @import("../../core/execution/managed_execution_contract.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const terminal_identity = @import("../../core/terminal/identity.zig");
const terminal_action_executor = @import("../../core/terminal/action_executor.zig");
const terminal_managed_observer = @import("../../core/terminal/managed_observer.zig");
const terminal_operation = @import("../../core/terminal/operation.zig");
const terminal_store = @import("../../core/terminal/store.zig");
const shell_resolver = @import("../../core/terminal/shell_resolver.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const terminal_contracts = @import("../../core/terminal/contracts.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const result_commit = @import("../../core/tooling/result_commit.zig");
const result_store = @import("../../core/session/result_store.zig");
const types = @import("../../core/shared/types.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const Action = enum {
    run,
    interact,
    stop,
};

const ShellKind = enum { executable };

pub const ShellInput = struct {
    kind: ShellKind,
    path: []const u8,
    clean_start: bool = false,
};

pub const Input = struct {
    action: Action,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    profile: ?command_environment.Profile = null,
    shell: ?ShellInput = null,
    tty: bool = false,
    yield_time_ms: u32 = managed_contract.default_yield_time_ms,
    timeout_ms: ?u64 = null,
    session_id: ?[]const u8 = null,
    chars: ?[]const u8 = null,
    force: bool = false,
};

pub const public_field_names = blk: {
    const fields = @typeInfo(Input).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, index| names[index] = field.name;
    break :blk names;
};

pub const ActionFieldContract = struct {
    allowed: []const []const u8,
    required: []const []const u8,
    conflicts: []const tool_result_errors.TerminalActionFieldConflict = &.{},
};

pub fn actionFieldContract(action: Action) ActionFieldContract {
    return switch (action) {
        .run => .{
            .allowed = &.{ "action", "command", "cwd", "profile", "shell", "tty", "yield_time_ms", "timeout_ms" },
            .required = &.{ "action", "command" },
            .conflicts = &.{.{ "profile", "shell" }},
        },
        .interact => .{
            .allowed = &.{ "action", "session_id", "chars", "yield_time_ms" },
            .required = &.{ "action", "session_id" },
        },
        .stop => .{
            .allowed = &.{ "action", "session_id", "force" },
            .required = &.{ "action", "session_id" },
        },
    };
}

const OwnedInput = struct {
    arena_state: std.heap.ArenaAllocator.State,
    value: Input,

    fn deinit(self: *OwnedInput, alloc: Allocator) void {
        self.arena_state.promote(alloc).deinit();
        self.* = undefined;
    }
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var raw = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        args_json,
        .{ .allocate = .alloc_always },
    ) catch return decodeFailure(ctx);
    if (raw != .object) return decodeFailure(ctx);
    const raw_action = raw.object.get("action") orelse return decodeFailure(ctx);
    if (raw_action != .string) return decodeFailure(ctx);
    const action = std.meta.stringToEnum(Action, raw_action.string) orelse
        return decodeFailure(ctx);
    elideKnownNullFields(&raw.object);

    var correction_scratch: ActionFieldCorrectionScratch = .{};
    defer correction_scratch.deinit(ctx.allocator);
    if (try actionFieldCorrection(
        ctx.allocator,
        action,
        raw.object,
        &correction_scratch,
    )) |correction| {
        return .{ .failure = try tool_result_errors.terminalActionFieldCorrectionJson(
            ctx.allocator,
            correction,
        ) };
    }
    normalizeCompositeArgument(arena, &raw, "shell") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return decodeFailure(ctx),
    };
    var input = std.json.parseFromValueLeaky(Input, arena, raw, .{}) catch
        return decodeFailure(ctx);
    if (raw.object.get("yield_time_ms") == null) {
        input.yield_time_ms = defaultYieldTime(action);
    }
    const owned = try ctx.allocator.create(OwnedInput);
    owned.* = .{
        .arena_state = arena_state.state,
        .value = input,
    };
    arena_state.state = .init;
    return .{ .input = .{
        .ptr = owned,
        .deinit_fn = inputDeinit,
    } };
}

fn defaultYieldTime(action: Action) u32 {
    return switch (action) {
        .run => managed_contract.default_yield_time_ms,
        .interact => managed_contract.default_wait_ceiling_ms,
        .stop => 0,
    };
}

fn effective_interact_yield_time(has_input: bool, requested_ms: u32) u32 {
    if (!has_input) {
        return @min(
            @max(requested_ms, managed_contract.default_wait_ceiling_ms),
            managed_contract.max_wait_ceiling_ms,
        );
    }
    return @min(requested_ms, managed_contract.max_yield_time_ms);
}

fn decodeFailure(
    ctx: tool_dispatch.DispatchContext,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return .{ .failure = try ctx.allocator.dupe(
        u8,
        "shell arguments must match the advertised action schema",
    ) };
}

fn normalizeCompositeArgument(
    alloc: Allocator,
    root: *std.json.Value,
    field_name: []const u8,
) !void {
    const value = root.object.getPtr(field_name) orelse return;
    try tool_args.normalizeCompositeObjectValue(alloc, value);
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *OwnedInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn elideKnownNullFields(object: *std.json.ObjectMap) void {
    for (public_field_names[1..]) |field_name| {
        const value = object.get(field_name) orelse continue;
        if (value == .null or
            (value == .string and tool_args.isNullPlaceholderText(value.string)))
        {
            _ = object.orderedRemove(field_name);
        }
    }
}

const ActionFieldCorrectionScratch = struct {
    invalid_fields: std.ArrayList([]const u8) = .empty,
    missing_fields: [public_field_names.len][]const u8 = undefined,
    conflicts: [public_field_names.len]tool_result_errors.TerminalActionFieldConflict = undefined,

    fn deinit(self: *ActionFieldCorrectionScratch, alloc: Allocator) void {
        self.invalid_fields.deinit(alloc);
        self.* = undefined;
    }
};

fn actionFieldCorrection(
    alloc: Allocator,
    action: Action,
    object: std.json.ObjectMap,
    scratch: *ActionFieldCorrectionScratch,
) Allocator.Error!?tool_result_errors.TerminalActionFieldCorrection {
    const field_contract = actionFieldContract(action);
    try scratch.invalid_fields.ensureTotalCapacity(alloc, object.count());
    var fields = object.iterator();
    while (fields.next()) |entry| {
        var allowed = false;
        for (field_contract.allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) scratch.invalid_fields.appendAssumeCapacity(entry.key_ptr.*);
    }
    sort_utils.sort(
        []const u8,
        scratch.invalid_fields.items,
        {},
        struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan,
    );
    var missing_count: usize = 0;
    for (field_contract.required) |name| {
        if (object.get(name) != null) continue;
        scratch.missing_fields[missing_count] = name;
        missing_count += 1;
    }
    var conflict_count: usize = 0;
    for (field_contract.conflicts) |conflict| {
        if (object.get(conflict[0]) == null or object.get(conflict[1]) == null) continue;
        scratch.conflicts[conflict_count] = conflict;
        conflict_count += 1;
    }
    if (scratch.invalid_fields.items.len == 0 and
        missing_count == 0 and
        conflict_count == 0)
    {
        return null;
    }
    return .{
        .action = @tagName(action),
        .invalid_fields = scratch.invalid_fields.items,
        .missing_fields = scratch.missing_fields[0..missing_count],
        .allowed_fields = field_contract.allowed,
        .conflicts = scratch.conflicts[0..conflict_count],
    };
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(OwnedInput).value;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    return switch (input.action) {
        .run => validateRun(ctx, arena, input),
        .interact => validateInteract(ctx, input),
        .stop => null,
    };
}

fn validateInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!?[]u8 {
    if (input.yield_time_ms > managed_contract.max_wait_ceiling_ms) {
        return try ctx.allocator.dupe(
            u8,
            "shell interact yield_time_ms must be between 0 and 300000",
        );
    }
    if (input.chars) |chars| {
        if (chars.len > terminal_contracts.max_write_bytes) {
            return try ctx.allocator.dupe(u8, "shell interact chars exceed 65536 bytes");
        }
    }
    return null;
}

fn validateRun(
    ctx: tool_dispatch.DispatchContext,
    arena: Allocator,
    input: Input,
) tool_dispatch.DispatchError!?[]u8 {
    const command = input.command orelse
        return try ctx.allocator.dupe(u8, "shell run requires command");
    if (command.len == 0 or command.len > terminal_contracts.max_command_bytes) {
        return try ctx.allocator.dupe(u8, "shell run command is invalid");
    }
    if (input.profile != null and input.shell != null) {
        return try ctx.allocator.dupe(u8, "shell run fields profile and shell are mutually exclusive");
    }
    if (!input.tty and input.shell != null) {
        return try ctx.allocator.dupe(u8, "shell run explicit shell requires tty=true");
    }
    if (input.yield_time_ms > managed_contract.max_yield_time_ms) {
        return try ctx.allocator.dupe(u8, "shell yield_time_ms must be between 0 and 30000");
    }
    _ = resolveCwd(arena, ctx, input.cwd) catch |err| {
        return try std.fmt.allocPrint(
            ctx.allocator,
            "shell run cwd is invalid: {s}",
            .{@errorName(err)},
        );
    };
    if (!input.tty) {
        _ = commandEnvironment(arena, ctx, input.profile) catch |err| {
            return try std.fmt.allocPrint(
                ctx.allocator,
                "shell run profile is invalid: {s}",
                .{@errorName(err)},
            );
        };
    }
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .run => callRun(ctx, input),
        .interact => callInteract(ctx, input),
        .stop => callStop(ctx, input),
    };
}

fn callRun(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (input.tty) {
        return callTtyRun(ctx, input);
    }
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const execution_authority = ctx.execution_authority orelse return unavailable(ctx);
    const authority = switch (execution_authority) {
        .run_command => |value| value,
        else => return unavailable(ctx),
    };
    const command = input.command orelse return unavailable(ctx);
    var request_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer request_arena_state.deinit();
    const request_arena = request_arena_state.allocator();
    const cwd = resolveCwd(request_arena, ctx, input.cwd) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "shell run cwd is invalid: {s}",
            .{@errorName(err)},
        ) };
    };
    const environment = commandEnvironment(
        request_arena,
        ctx,
        input.profile,
    ) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "shell run profile is invalid: {s}",
            .{@errorName(err)},
        ) };
    };
    var execution_id_buffer: [64]u8 = undefined;
    const execution_id = runtime.generatedId(&execution_id_buffer) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.startCaptured(ctx.allocator, .{
        .execution_id = execution_id,
        .command = command,
        .cwd = cwd,
        .environment = environment,
        .authority = authority,
        .max_output_bytes = ctx.max_command_output_bytes,
        .timeout_ms = if (input.timeout_ms) |value|
            std.math.cast(usize, value) orelse return unavailable(ctx)
        else
            ctx.command_timeout_ms,
        .command_artifact_dir = ctx.command_artifact_dir,
        .replay_capability = ctx.session_child_capability,
        .output_chunk_lifecycle_id = ctx.output_chunk_lifecycle_id,
        .output_chunk_ctx = ctx.output_chunk_ctx,
        .on_output_chunk = ctx.on_output_chunk,
        .yield_time_ms = input.yield_time_ms,
        .cancel_flag = ctx.cancel_flag,
    }) catch |err| {
        if (err == error.Cancelled and
            ctx.cancel_flag != null and
            ctx.cancel_flag.?.load(.seq_cst))
        {
            return error.Cancelled;
        }
        return runtimeFailure(ctx, err);
    };
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .command);
}

fn callInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    ensureOwnedTtyIndexed(ctx, runtime, session_id) catch |err|
        return runtimeFailure(ctx, err);
    const chars = input.chars orelse "";
    const yield_time_ms = effective_interact_yield_time(chars.len != 0, input.yield_time_ms);
    if (runtime.isTombstone(session_id)) {
        if (chars.len != 0) return runtimeFailure(ctx, error.ExecutionTerminal);
        if (runtime.retainedTerminalSnapshot(ctx.allocator, session_id) catch |err|
            return runtimeFailure(ctx, err)) |retained|
        {
            var prepared = retained;
            defer prepared.deinit(ctx.allocator);
            return finishPrepared(ctx, runtime, &prepared, .command);
        }
    }
    if (runtime.backendFor(session_id) == .tty) {
        return callTtyInteract(ctx, input, yield_time_ms);
    }
    if (chars.len != 0) return runtimeFailure(ctx, error.InvalidBackend);
    var prepared = runtime.wait(
        ctx.allocator,
        session_id,
        yield_time_ms,
        ctx.cancel_flag,
    ) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .command);
}

fn callStop(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    ensureOwnedTtyIndexed(ctx, runtime, session_id) catch |err|
        return runtimeFailure(ctx, err);
    if (runtime.isTombstone(session_id)) {
        if (runtime.retainedTerminalSnapshot(ctx.allocator, session_id) catch |err|
            return runtimeFailure(ctx, err)) |retained|
        {
            var prepared = retained;
            defer prepared.deinit(ctx.allocator);
            return finishPrepared(ctx, runtime, &prepared, .stop);
        }
    }
    if (runtime.backendFor(session_id) == .tty) {
        if (runtime.stateFor(session_id)) |state| {
            if (state != .running) {
                return finishTerminalTtyStop(ctx, runtime, session_id, state);
            }
        }
        refreshTtyExecution(ctx, runtime, session_id, "") catch |err|
            return runtimeFailure(ctx, err);
        if (runtime.stateFor(session_id)) |state| {
            if (state != .running) {
                return finishTerminalTtyStop(ctx, runtime, session_id, state);
            }
        }
        return callTtyStop(ctx, input);
    }
    var prepared = runtime.stop(
        ctx.allocator,
        session_id,
        input.force,
    ) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

const ParsedTerminalExecution = struct {
    result: terminal_contracts.OwnedResult,

    fn deinit(self: *ParsedTerminalExecution, alloc: Allocator) void {
        self.result.deinit(alloc);
        self.* = undefined;
    }
};

fn callTtyRun(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const owner = ctx.session_child_capability orelse return unavailable(ctx);
    const durable_session_id = ctx.terminal_owner_session_id orelse return unavailable(ctx);
    const command = input.command orelse return unavailable(ctx);
    const cwd = resolveCwd(ctx.allocator, ctx, input.cwd) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    defer ctx.allocator.free(@constCast(cwd));
    var shell_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer shell_arena_state.deinit();
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    const shell = ttyShell(shell_arena_state.allocator(), input, configured) catch |err|
        return runtimeFailure(ctx, err);
    const environment = shell_resolver.environmentForShellSpec(
        shell_arena_state.allocator(),
        configured,
        shell,
    ) catch |err| return runtimeFailure(ctx, err);
    requireTtyShellAuthority(ctx, .{
        .command = command,
        .resolved_cwd = cwd,
        .target_os = builtin.os.tag,
        .environment = environment,
        .execution_mode = .tty,
    }) catch |err| return runtimeFailure(ctx, err);
    runtime.reserveTtyCapacity() catch |err| return runtimeFailure(ctx, err);
    var capacity_reserved = true;
    defer if (capacity_reserved) runtime.releaseTtyCapacity();
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = terminal_identity.profileUser(&profile_user_buffer) orelse
        return unavailable(ctx);
    var persistence = terminal_operation.prepareStartPersistence(ctx.allocator, .{
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = ctx.workspace_root,
        .cwd = cwd,
        .transport_role = ctx.terminal_transport_role,
        .backend = .native,
        .actor = .agent,
        .controls = .full(),
        .lifetime = .session,
    }) catch |err| return runtimeFailure(ctx, err);
    defer persistence.deinit();
    const request = terminal_contracts.ActionRequest{ .start = .{
        .cwd = cwd,
        .command = command,
        .shell = shell,
        .backend = .native,
        .return_when = if (input.yield_time_ms == 0) .started else .exit,
        .wait_ceiling_ms = @max(@as(u64, 1), input.yield_time_ms),
        .timeout_ms = input.timeout_ms,
        .persistence = persistence.view(),
    } };
    var executed = executeTerminal(ctx, request) catch |err|
        return runtimeFailure(ctx, err);
    defer executed.deinit(ctx.allocator);
    const started = switch (executed.result.view()) {
        .failure => return cloneTerminalFailure(ctx, executed.result.view()),
        .success => |success| switch (success) {
            .start => |value| value,
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    };
    var session_owned = true;
    defer if (session_owned) closeTtyBestEffort(ctx, started.session.session_id);
    const initial_state = terminal_managed_observer.snapshotState(started.session, started.outcome);
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        started.session.session_id,
        initial_state,
        null,
    ) catch |err| return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);
    finalizeCompletedTty(ctx, started.session.session_id, observed.state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.registerTty(ctx.allocator, .{
        .execution_id = started.session.session_id,
        .command = command,
        .cwd = cwd,
        .state = observed.state,
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = observed.state == .running,
        .capacity_reserved = true,
        .replay_capability = ctx.session_child_capability,
    }) catch |err| return runtimeFailure(ctx, err);
    capacity_reserved = false;
    session_owned = false;
    defer prepared.deinit(ctx.allocator);
    _ = owner;
    return finishPrepared(ctx, runtime, &prepared, .command);
}

fn callTtyInteract(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
    yield_time_ms: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    if (runtime.isTombstone(session_id)) {
        return runtimeFailure(ctx, error.ExecutionTerminal);
    }
    var state: managed_execution.SnapshotState = .running;
    var accepted_bytes: ?u32 = null;
    const chars = input.chars orelse "";
    if (chars.len != 0) {
        if (runtime.backendFor(session_id) != .tty) {
            return runtimeFailure(ctx, error.InvalidBackend);
        }
        var ready = executeAuthorizedTerminal(ctx, session_id, .{ .wait = .{
            .session_id = session_id,
            .return_when = .started,
            .safety_ceiling_ms = 20_000,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer ready.deinit(ctx.allocator);
        const ready_result = switch (ready.result.view()) {
            .failure => return cloneTerminalFailure(ctx, ready.result.view()),
            .success => |success| switch (success) {
                .wait => |value| value,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };
        if (ready_result.session.lifecycle != .running) {
            return runtimeFailure(ctx, error.TerminalNotReady);
        }

        var acquired = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .lease = .acquire,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer acquired.deinit(ctx.allocator);
        switch (acquired.result.view()) {
            .failure => return cloneTerminalFailure(ctx, acquired.result.view()),
            .success => |success| switch (success) {
                .write => {},
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        }
        var release_needed = true;
        defer if (release_needed) releaseTtyLease(ctx, session_id);

        var used = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .payload = .{ .text = chars },
            .lease = .use,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer used.deinit(ctx.allocator);
        accepted_bytes = switch (used.result.view()) {
            .failure => return cloneTerminalFailure(ctx, used.result.view()),
            .success => |success| switch (success) {
                .write => |value| value.accepted_bytes,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };

        var released = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
            .session_id = session_id,
            .lease = .release,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer released.deinit(ctx.allocator);
        const facts = switch (released.result.view()) {
            .failure => return cloneTerminalFailure(ctx, released.result.view()),
            .success => |success| switch (success) {
                .write => |value| value.session,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };
        release_needed = false;
        state = terminal_managed_observer.snapshotState(facts, null);
    }
    const waiter_id = runtime.reserveExternalWait(session_id) catch |err|
        return runtimeFailure(ctx, err);
    defer runtime.releaseExternalWait(session_id, waiter_id);
    if (state == .running and yield_time_ms != 0) {
        var waited = executeAuthorizedTerminal(ctx, session_id, .{ .wait = .{
            .session_id = session_id,
            .return_when = .exit,
            .safety_ceiling_ms = yield_time_ms,
            .authority = null,
        } }) catch |err| return runtimeFailure(ctx, err);
        defer waited.deinit(ctx.allocator);
        const result = switch (waited.result.view()) {
            .failure => return cloneTerminalFailure(ctx, waited.result.view()),
            .success => |success| switch (success) {
                .wait => |value| value,
                else => return runtimeFailure(ctx, error.InvalidTerminalResult),
            },
        };
        state = terminal_managed_observer.snapshotState(result.session, result.outcome);
    }
    if (accepted_bytes != null and yield_time_ms == 0) {
        io_mod.sleep(100 * std.time.ns_per_ms);
    }
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        session_id,
        state,
        runtime.ttyCursorFor(session_id),
    ) catch |err|
        return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);
    if (runtime.externalWaitPreempted(session_id, waiter_id)) {
        return runtimeFailure(ctx, error.WaitPreempted);
    }
    finalizeCompletedTty(ctx, session_id, observed.state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = observed.state,
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return if (accepted_bytes) |count|
        finishPreparedWithAccepted(ctx, runtime, &prepared, count)
    else
        finishPrepared(ctx, runtime, &prepared, .command);
}

fn callTtyStop(
    ctx: tool_dispatch.DispatchContext,
    input: Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.managed_executions orelse return unavailable(ctx);
    const session_id = input.session_id orelse return unavailable(ctx);
    runtime.preemptWait(session_id);
    var signaled = executeAuthorizedTerminal(ctx, session_id, .{ .signal = .{
        .session_id = session_id,
        .signal = if (input.force) .kill else .terminate,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer signaled.deinit(ctx.allocator);
    switch (signaled.result.view()) {
        .failure => return cloneTerminalFailure(ctx, signaled.result.view()),
        .success => |success| switch (success) {
            .signal => {},
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    }

    var stopped_status: ?command_contract.CommandStatus = null;
    var waited = executeAuthorizedTerminal(ctx, session_id, .{ .wait = .{
        .session_id = session_id,
        .return_when = .exit,
        .safety_ceiling_ms = 2_000,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer waited.deinit(ctx.allocator);
    const wait_result = switch (waited.result.view()) {
        .failure => return cloneTerminalFailure(ctx, waited.result.view()),
        .success => |success| switch (success) {
            .wait => |value| value,
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    };
    stopped_status = statusFromOutcome(wait_result.outcome);
    var observed = terminal_managed_observer.observe(
        ttyObserverContext(ctx, runtime) orelse return unavailable(ctx),
        session_id,
        terminal_managed_observer.snapshotState(wait_result.session, wait_result.outcome),
        runtime.ttyCursorFor(session_id),
    ) catch |err| return runtimeFailure(ctx, err);
    defer observed.deinit(ctx.allocator);

    var closed = executeAuthorizedTerminal(ctx, session_id, .{ .close = .{
        .session_id = session_id,
        .policy = if (input.force) .force else .graceful,
        .authority = null,
    } }) catch |err| return runtimeFailure(ctx, err);
    defer closed.deinit(ctx.allocator);
    switch (closed.result.view()) {
        .failure => return cloneTerminalFailure(ctx, closed.result.view()),
        .success => |success| switch (success) {
            .close => {},
            else => return runtimeFailure(ctx, error.InvalidTerminalResult),
        },
    }
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = .{ .stopped = stopped_status },
        .output = observed.output,
        .replay_output = observed.replay_output,
        .next_cursor = observed.next_cursor,
        .output_incomplete = observed.output_incomplete,
        .error_name = if (observed.timed_out) "TimeoutExpired" else null,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

fn ttyShell(
    alloc: Allocator,
    input: Input,
    configured_login_shell: ?[]const u8,
) !terminal_contracts.ShellSpec {
    if (input.shell) |shell| return .{ .executable = .{
        .path = shell.path,
        .clean_start = shell.clean_start,
    } };
    return shell_resolver.profileShell(
        alloc,
        configured_login_shell,
        input.profile orelse .user,
    );
}

fn requireTtyShellAuthority(
    ctx: tool_dispatch.DispatchContext,
    command_ctx: command_admission.CommandContext,
) !void {
    const execution_authority = ctx.execution_authority orelse
        return error.CommandAuthorityContextMismatch;
    const command_authority = switch (execution_authority) {
        .run_command => |value| value,
        .ordinary, .file_mutation, .vision_paths => return error.CommandAuthorityContextMismatch,
    };
    const shell_allowed = switch (command_authority) {
        .shell_allowed => |value| value,
        .direct_only => return error.CommandAdmissionChanged,
    };
    if (!shell_allowed.fingerprint.matches(command_ctx)) {
        return error.CommandAuthorityContextMismatch;
    }
}

fn executeTerminal(
    ctx: tool_dispatch.DispatchContext,
    request: terminal_contracts.ActionRequest,
) !ParsedTerminalExecution {
    return .{ .result = try terminal_action_executor.execute(.{
        .alloc = ctx.allocator,
        .lifecycle_allocator = ctx.lifecycle_allocator,
        .runtime = ctx.terminal_client orelse return error.TerminalUnavailable,
        .cancel_flag = ctx.cancel_flag,
    }, request) };
}

fn executeAuthorizedTerminal(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    request: terminal_contracts.ActionRequest,
) !ParsedTerminalExecution {
    var authority = try reloadTerminalAuthority(ctx, session_id);
    defer authority.deinit();
    const authorized: terminal_contracts.ActionRequest = switch (request) {
        .read => |value| .{ .read = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .write => |value| .{ .write = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .wait => |value| .{ .wait = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .signal => |value| .{ .signal = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .close => |value| .{ .close = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .screen => |value| .{ .screen = blk: {
            var owned = value;
            owned.authority = authority.view();
            break :blk owned;
        } },
        .start, .inspect, .list, .resize => return error.InvalidTerminalRequest,
    };
    return executeTerminal(ctx, authorized);
}

fn reloadTerminalAuthority(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) !terminal_operation.OwnedAuthorityClaim {
    const owner = ctx.session_child_capability orelse return error.TerminalAuthorityUnavailable;
    const durable_session_id = ctx.terminal_owner_session_id orelse
        return error.TerminalAuthorityUnavailable;
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = terminal_identity.profileUser(&profile_user_buffer) orelse
        return error.TerminalAuthorityUnavailable;
    return terminal_store.reloadOwnerAuthorityClaim(ctx.allocator, owner, .{
        .terminal_session_id = session_id,
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.terminal_transport_role,
        .actor = .agent,
    });
}

fn cloneTerminalFailure(
    ctx: tool_dispatch.DispatchContext,
    result: terminal_contracts.Result,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (result == .success) return runtimeFailure(ctx, error.InvalidTerminalResult);
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();
    std.json.Stringify.value(result, .{}, &out.writer) catch
        return error.OutOfMemory;
    return .{ .failure = try out.toOwnedSlice() };
}

fn statusFromOutcome(
    outcome: terminal_contracts.ReturnOutcome,
) ?command_contract.CommandStatus {
    return switch (outcome) {
        .exited => |code| .{ .exit_code = code },
        .signal => |signal| .{ .signal = signal },
        .started, .condition_met, .safety_ceiling, .cancelled => null,
    };
}

fn releaseTtyLease(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) void {
    var released = executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
        .session_id = session_id,
        .lease = .release,
        .authority = null,
    } }) catch |err| {
        debug_trace.logf(
            "shell",
            "TTY write lease release failed session_id={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return;
    };
    released.deinit(ctx.allocator);
}

pub fn releaseAgentWriteLease(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) !void {
    var released = try executeAuthorizedTerminal(ctx, session_id, .{ .write = .{
        .session_id = session_id,
        .lease = .release,
        .authority = null,
    } });
    defer released.deinit(ctx.allocator);
    switch (released.result.view()) {
        .success => |success| switch (success) {
            .write => {},
            else => return error.InvalidTerminalLeaseCleanupResult,
        },
        .failure => |failure| switch (failure.code) {
            .session_not_found, .lease_conflict => {},
            else => return error.TerminalLeaseCleanupFailed,
        },
    }
}

fn finalizeCompletedTty(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
    state: managed_execution.SnapshotState,
) !void {
    switch (state) {
        .completed => {},
        .running, .stopped, .lost => return,
    }
    var closed = try executeAuthorizedTerminal(ctx, session_id, .{ .close = .{
        .session_id = session_id,
        .policy = .graceful,
        .authority = null,
    } });
    defer closed.deinit(ctx.allocator);
    switch (closed.result.view()) {
        .failure => return error.TerminalCloseFailed,
        .success => |success| switch (success) {
            .close => {},
            else => return error.InvalidTerminalResult,
        },
    }
}

fn closeTtyBestEffort(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) void {
    var closed = executeAuthorizedTerminal(ctx, session_id, .{ .close = .{
        .session_id = session_id,
        .policy = .force,
        .authority = null,
    } }) catch |err| {
        debug_trace.logf(
            "shell",
            "unpublished TTY cleanup failed session_id={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return;
    };
    closed.deinit(ctx.allocator);
}

fn finishPreparedWithAccepted(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
    accepted_bytes: u32,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const body = formatSnapshotWithLimit(
        ctx.allocator,
        prepared.snapshot,
        accepted_bytes,
        ctx.max_tool_result_bytes,
    ) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    errdefer ctx.allocator.free(body);
    publishSnapshotMetadata(ctx, prepared.snapshot) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    handoffPreparedDelivery(ctx, runtime, prepared.reservation_id) catch
        return runtimeFailure(ctx, error.ResultCommitFailed);
    return .{ .success = body };
}

fn ensureOwnedTtyIndexed(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
) !void {
    if (runtime.stateFor(session_id) != null) return;
    const observer = ttyObserverContext(ctx, runtime) orelse return;
    try terminal_managed_observer.syncOwned(observer);
}

fn refreshTtyExecution(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
    command: []const u8,
) !void {
    return terminal_managed_observer.refresh(
        ttyObserverContext(ctx, runtime) orelse
            return error.TerminalAuthorityUnavailable,
        session_id,
        command,
    );
}

fn ttyObserverContext(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
) ?terminal_managed_observer.Context {
    return .{
        .alloc = ctx.allocator,
        .lifecycle_allocator = ctx.lifecycle_allocator,
        .terminal_client = ctx.terminal_client orelse return null,
        .managed_runtime = runtime,
        .owner = ctx.session_child_capability orelse return null,
        .durable_session_id = ctx.terminal_owner_session_id orelse return null,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.terminal_transport_role,
        .max_output_bytes = ctx.max_command_output_bytes,
        .cancel_flag = ctx.cancel_flag,
    };
}

fn finishTerminalTtyStop(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    session_id: []const u8,
    state: managed_execution.SnapshotState,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    finalizeCompletedTty(ctx, session_id, state) catch |err|
        return runtimeFailure(ctx, err);
    var prepared = runtime.updateTty(ctx.allocator, .{
        .execution_id = session_id,
        .command = "",
        .state = state,
        .max_output_bytes = ctx.max_command_output_bytes,
        .published_running = true,
    }) catch |err| return runtimeFailure(ctx, err);
    defer prepared.deinit(ctx.allocator);
    return finishPrepared(ctx, runtime, &prepared, .stop);
}

fn finishPrepared(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    prepared: *managed_execution.PreparedSnapshot,
    action: enum { command, stop },
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const body = formatSnapshotWithLimit(
        ctx.allocator,
        prepared.snapshot,
        null,
        ctx.max_tool_result_bytes,
    ) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try ctx.allocator.dupe(u8, "shell result is unavailable") };
    };
    errdefer ctx.allocator.free(body);
    publishSnapshotMetadata(ctx, prepared.snapshot) catch |err| {
        runtime.cancelDelivery(
            prepared.snapshot.execution_id,
            prepared.reservation_id,
        ) catch {};
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return runtimeFailure(ctx, err);
    };
    handoffPreparedDelivery(ctx, runtime, prepared.reservation_id) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "shell result commit failed") };
    };
    const failed = switch (action) {
        .command => snapshotFailed(prepared.snapshot),
        .stop => stop_result_failed(prepared.snapshot.state),
    };
    return if (failed)
        .{ .failure = body }
    else
        .{ .success = body };
}

fn publishSnapshotMetadata(
    ctx: tool_dispatch.DispatchContext,
    snapshot: managed_execution.Snapshot,
) !void {
    if (ctx.command_result_json_sink == null and
        ctx.tool_result_memory_sink == null) return;
    const status: ?command_contract.CommandStatus = switch (snapshot.state) {
        .completed => |value| value,
        .stopped => |value| value,
        .lost => .indeterminate,
        .running => return,
    };
    const projection: command_contract.StatusProjection = if (status) |value|
        command_contract.projectStatus(value)
    else
        .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = false,
        };
    const timed_out = if (snapshot.error_name) |name|
        std.mem.eql(u8, name, "TimeoutExpired")
    else
        false;
    var memory = types.ToolResultMemory{
        .output_bytes = snapshot.stdout_bytes +| snapshot.stderr_bytes,
        .stored_output_bytes = snapshot.stdout_bytes +| snapshot.stderr_bytes,
        .truncated = snapshot.output_truncated,
    };
    if (ctx.tool_result_memory_sink != null) {
        if (snapshot.output_file) |handle| {
            memory.command_output_replay = .{ .available = .{
                .handle = try ctx.allocator.dupe(u8, handle),
                .framed_bytes = snapshot.output_framed_bytes,
            } };
        }
    }
    errdefer if (memory.command_output_replay) |replay| switch (replay) {
        .available => |descriptor| ctx.allocator.free(@constCast(descriptor.handle)),
        .unavailable => {},
    };
    const completed = switch (snapshot.state) {
        .completed => true,
        .running, .stopped, .lost => false,
    };
    if (timed_out) {
        memory.command_process_presentation = .timed_out;
    } else if (completed) {
        if (projection.signal) |signal| {
            memory.command_process_presentation = .{ .signal = signal };
        } else if (projection.exit_code) |exit_code| {
            if (exit_code != 0) {
                memory.command_process_presentation = .{ .exit_code = exit_code };
            }
        }
    }
    if (ctx.command_result_json_sink != null) {
        const command_result = command_contract.CommandResult{
            .command = snapshot.command,
            .cwd = snapshot.cwd,
            .exit_code = projection.exit_code,
            .signal = projection.signal,
            .timed_out = timed_out,
            .termination_indeterminate = projection.termination_indeterminate,
            .output_incomplete = snapshot.output_incomplete,
            .duration_ms = snapshot.duration_ms,
            .stdout_bytes = snapshot.stdout_bytes,
            .stderr_bytes = snapshot.stderr_bytes,
            .truncated = snapshot.output_truncated,
            .output_file = snapshot.output_file,
        };
        const command_result_json = try command_result.toJson(ctx.allocator);
        tool_dispatch.reportCommandResultJson(ctx, command_result_json);
    }
    if (ctx.tool_result_memory_sink != null) {
        tool_dispatch.reportToolResultMemory(ctx, memory);
    }
}

fn handoffPreparedDelivery(
    ctx: tool_dispatch.DispatchContext,
    runtime: *managed_execution.Runtime,
    reservation_id: u64,
) !void {
    if (ctx.result_commit_sink == null) {
        return runtime.commitReservation(reservation_id);
    }
    tool_dispatch.reportResultCommit(ctx, result_commit.Token{
        .context = runtime,
        .identity = reservation_id,
        .commit_fn = commitManagedDelivery,
        .cancel_fn = cancelManagedDelivery,
    });
}

fn commitManagedDelivery(raw: *anyopaque, reservation_id: u64) !void {
    const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
    return runtime.commitReservation(reservation_id);
}

fn cancelManagedDelivery(raw: *anyopaque, reservation_id: u64) void {
    const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
    runtime.cancelReservation(reservation_id) catch |err| {
        debug_trace.logf(
            "shell",
            "managed delivery cancellation failed reservation={d} err={s}",
            .{ reservation_id, @errorName(err) },
        );
    };
}

fn formatSnapshot(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
) ![]u8 {
    return formatSnapshotWithLimit(
        alloc,
        snapshot,
        accepted_bytes,
        tool_result_limits.default_max_tool_result_bytes,
    );
}

fn formatSnapshotWithLimit(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    max_bytes: usize,
) ![]u8 {
    const inline_max_bytes = @min(
        max_bytes,
        result_store.large_result_threshold_bytes,
    );
    if (try formatModelSafeSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        snapshot.output_delta,
        snapshot.output_truncated,
        inline_max_bytes,
    )) |full| {
        if (full.len <= inline_max_bytes) return full;
        alloc.free(full);
    }

    var minimum: usize = 0;
    var maximum: usize = @min(snapshot.output_delta.len, inline_max_bytes);
    var best: ?[]u8 = null;
    errdefer if (best) |value| alloc.free(value);
    while (minimum <= maximum) {
        const content_budget = minimum + (maximum - minimum) / 2;
        const marker = "\n... bytes omitted; use full_output_handle for exact output ...\n";
        var projected_writer: std.Io.Writer.Allocating = .init(alloc);
        defer projected_writer.deinit();
        try text_utils.writeHeadTailBounded(
            &projected_writer.writer,
            snapshot.output_delta,
            content_budget,
            marker,
            .up,
        );
        const projected = try projected_writer.toOwnedSlice();
        defer alloc.free(projected);
        const candidate = (try formatModelSafeSnapshotRaw(
            alloc,
            snapshot,
            accepted_bytes,
            projected,
            true,
            inline_max_bytes,
        )) orelse {
            if (content_budget == 0) break;
            maximum = content_budget - 1;
            continue;
        };
        if (candidate.len <= inline_max_bytes) {
            if (best) |value| alloc.free(value);
            best = candidate;
            minimum = content_budget + 1;
        } else {
            alloc.free(candidate);
            if (content_budget == 0) break;
            maximum = content_budget - 1;
        }
    }
    if (best) |value| return value;
    return formatSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        "",
        true,
    );
}

fn formatModelSafeSnapshotRaw(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    output_delta: []const u8,
    output_truncated: bool,
    max_encoded_bytes: usize,
) !?[]u8 {
    if (text_utils.isModelSafeText(output_delta)) {
        return try formatSnapshotRaw(
            alloc,
            snapshot,
            accepted_bytes,
            output_delta,
            output_truncated,
        );
    }
    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        output_delta,
        max_encoded_bytes,
    );
    defer encoded.deinit(alloc);
    if (encoded.truncated) return null;
    return try formatSnapshotRaw(
        alloc,
        snapshot,
        accepted_bytes,
        encoded.bytes,
        output_truncated,
    );
}

fn formatSnapshotRaw(
    alloc: Allocator,
    snapshot: managed_execution.Snapshot,
    accepted_bytes: ?u32,
    output_delta: []const u8,
    output_truncated: bool,
) ![]u8 {
    const status = switch (snapshot.state) {
        .completed => |value| value,
        .stopped => |value| value,
        .lost => .indeterminate,
        .running => null,
    };
    const projection: command_contract.StatusProjection = if (status) |value|
        command_contract.projectStatus(value)
    else
        .{
            .exit_code = null,
            .signal = null,
            .termination_indeterminate = false,
        };
    const retry_guidance: ?[]const u8 = if (snapshot.output_incomplete)
        "Command output is incomplete. Inspect external state and available output before retrying; do not blindly rerun a command that may have changed state."
    else switch (snapshot.state) {
        .lost => "Execution status is indeterminate. Inspect external state before retrying; do not blindly rerun a command that may have changed state.",
        .running, .completed, .stopped => null,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(.{
        .session_id = if (snapshot.retained) snapshot.execution_id else null,
        .state = snapshotStateName(snapshot.state),
        .backend = @tagName(snapshot.backend),
        .persistence = @tagName(snapshot.persistence),
        .output_truncated = output_truncated,
        .output_incomplete = snapshot.output_incomplete,
        .output_terminal_safe = true,
        .full_output_handle = snapshot.output_file,
        .exit_code = projection.exit_code,
        .signal = projection.signal,
        .termination_indeterminate = projection.termination_indeterminate,
        .duration_ms = snapshot.duration_ms,
        .accepted_bytes = accepted_bytes,
        .@"error" = snapshot.error_name,
        .retry_guidance = retry_guidance,
        .output_delta = output_delta,
    }, .{}, &out.writer);
    return try out.toOwnedSlice();
}

fn snapshotStateName(state: managed_execution.SnapshotState) []const u8 {
    return switch (state) {
        .running => "running",
        .completed => "completed",
        .stopped => "stopped",
        .lost => "lost",
    };
}

fn snapshotFailed(snapshot: managed_execution.Snapshot) bool {
    if (snapshot.output_incomplete) return true;
    return switch (snapshot.state) {
        .running => false,
        .completed => |status| switch (status) {
            .exit_code => |code| code != 0,
            .signal, .indeterminate => true,
            .finished => false,
        },
        .stopped, .lost => true,
    };
}

fn stop_result_failed(state: managed_execution.SnapshotState) bool {
    return switch (state) {
        .lost => true,
        .stopped => |status| if (status) |value| switch (value) {
            .indeterminate => true,
            .exit_code, .signal, .finished => false,
        } else false,
        .running, .completed => false,
    };
}

test "shell stop fails closed only for lost or indeterminate outcomes" {
    try std.testing.expect(stop_result_failed(.lost));
    try std.testing.expect(stop_result_failed(.{ .stopped = .indeterminate }));
    try std.testing.expect(!stop_result_failed(.{ .stopped = .{ .signal = 9 } }));
    try std.testing.expect(!stop_result_failed(.{ .completed = .{ .exit_code = 0 } }));
}

fn runtimeFailure(
    ctx: tool_dispatch.DispatchContext,
    err: anyerror,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"error\":{{\"tool\":\"shell\",\"code\":\"{s}\",\"retryable\":false}}}}",
        .{@errorName(err)},
    ) };
}

fn unavailable(
    ctx: tool_dispatch.DispatchContext,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(
        u8,
        "{\"error\":{\"tool\":\"shell\",\"code\":\"unavailable\",\"retryable\":false}}",
    ) };
}

fn resolveCwd(
    arena: Allocator,
    ctx: tool_dispatch.DispatchContext,
    requested: ?[]const u8,
) ![]const u8 {
    const scope = ctx.access_scope orelse
        workspace_access.AccessScope.primaryOnly(ctx.workspace_root);
    const value = requested orelse return arena.dupe(u8, scope.primary_directory);
    if (std.mem.eql(u8, value, ".")) {
        return arena.dupe(u8, scope.primary_directory);
    }
    return pathing.resolveWorkspaceOrExternalPath(
        arena,
        scope.primary_directory,
        value,
    );
}

fn commandEnvironment(
    alloc: Allocator,
    ctx: tool_dispatch.DispatchContext,
    profile: ?command_environment.Profile,
) !command_environment.Environment {
    if (ctx.captured_command_host == .workspace_clean) {
        if (profile != null) return error.InvalidWorkspaceInput;
        return .workspace_clean;
    }
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    return shell_resolver.environment(alloc, configured, profile);
}

pub fn isCapturedCommand(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return input.action == .run and !input.tty;
}

pub fn isProcessLocal(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .run => !input.tty,
        .interact => input.chars == null or input.chars.?.len == 0,
        .stop => true,
    };
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .interact => input.chars == null or input.chars.?.len == 0,
        .run, .stop => false,
    };
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const action = std.meta.stringToEnum(
        Action,
        tool_args.optionalStringArg(args, "action") orelse return null,
    ) orelse return null;
    return switch (action) {
        .run => .{
            .activity_kind = .command,
            .action_label = "Running",
            .completed_action_label = "Ran",
            .label_arg_kind = .command,
            .label_arg_default = "command",
        },
        .interact => if (tool_args.optionalStringArg(args, "chars")) |chars|
            if (chars.len == 0)
                sessionPresentation("Waiting for", "Observed")
            else
                sessionPresentation("Sending input to", "Sent input to")
        else
            sessionPresentation("Waiting for", "Observed"),
        .stop => sessionPresentation("Stopping", "Stopped"),
    };
}

fn sessionPresentation(
    action_label: []const u8,
    completed_action_label: []const u8,
) tool_dispatch.CallPresentation {
    return .{
        .activity_kind = .command,
        .action_label = action_label,
        .completed_action_label = completed_action_label,
        .label_arg_kind = .session_id,
        .label_arg_default = "shell execution",
    };
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "shell action fields are closed and command authority covers every run" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "action", "command", "cwd", "profile", "shell", "tty", "yield_time_ms", "timeout_ms" },
        actionFieldContract(.run).allowed,
    );
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "action", "session_id", "chars", "yield_time_ms" },
        actionFieldContract(.interact).allowed,
    );
}

test "shell interact classification follows optional input" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const cases = [_]struct {
        json: []const u8,
        reads_only: bool,
        process_local: bool,
    }{
        .{
            .json = "{\"action\":\"interact\",\"session_id\":\"shell-1\"}",
            .reads_only = true,
            .process_local = true,
        },
        .{
            .json = "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"chars\":\"\"}",
            .reads_only = true,
            .process_local = true,
        },
        .{
            .json = "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"chars\":\"hello\\n\"}",
            .reads_only = false,
            .process_local = false,
        },
    };
    for (cases) |case| {
        const decoded = try decode(ctx, case.json);
        switch (decoded) {
            .failure => |failure| {
                defer alloc.free(failure);
                return error.TestUnexpectedResult;
            },
            .input => |input| {
                defer input.deinit(alloc);
                try std.testing.expectEqual(case.reads_only, readsOnly(input));
                try std.testing.expectEqual(case.process_local, isProcessLocal(input));
            },
        }
    }

    const oversized = try alloc.alloc(u8, terminal_contracts.max_write_bytes + 1);
    defer alloc.free(oversized);
    const failure = try validateInteract(ctx, .{
        .action = .interact,
        .session_id = "shell-1",
        .chars = oversized,
    }) orelse return error.TestUnexpectedResult;
    defer alloc.free(failure);
    try std.testing.expect(std.mem.find(u8, failure, "exceed") != null);
}

test "TTY execution requires matching shell authority" {
    const command_ctx = command_admission.CommandContext{
        .command = "pwd",
        .resolved_cwd = "/workspace",
        .target_os = builtin.os.tag,
        .environment = .{ .clean = "/bin/bash" },
        .execution_mode = .tty,
    };
    try std.testing.expectError(
        error.CommandAdmissionChanged,
        requireTtyShellAuthority(.{
            .allocator = std.testing.allocator,
            .execution_authority = .{ .run_command = .{
                .direct_only = .init(command_ctx),
            } },
        }, command_ctx),
    );

    try requireTtyShellAuthority(.{
        .allocator = std.testing.allocator,
        .execution_authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .auto_classifier,
        } } },
    }, command_ctx);

    var changed = command_ctx;
    changed.environment = .{ .user = "/bin/bash" };
    try std.testing.expectError(
        error.CommandAuthorityContextMismatch,
        requireTtyShellAuthority(.{
            .allocator = std.testing.allocator,
            .execution_authority = .{ .run_command = .{ .shell_allowed = .{
                .fingerprint = .init(command_ctx),
                .source = .auto_classifier,
            } } },
        }, changed),
    );
}

test "shell decoder preserves null omission and rejects cross action fields" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const decoded = try decode(
        ctx,
        "{\"action\":\"run\",\"command\":\"true\",\"cwd\":null,\"profile\":null,\"tty\":false,\"yield_time_ms\":0,\"timeout_ms\":null}",
    );
    switch (decoded) {
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(isCapturedCommand(input));
        },
    }
    const invalid = try decode(
        ctx,
        "{\"action\":\"interact\",\"session_id\":\"shell-session\",\"command\":\"true\"}",
    );
    switch (invalid) {
        .input => |input| {
            defer input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
            try std.testing.expect(std.mem.find(u8, failure, "invalid_action_fields") != null);
        },
    }
}

test "shell decoder applies action specific observation defaults" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const run_decoded = try decode(ctx, "{\"action\":\"run\",\"command\":\"true\"}");
    switch (run_decoded) {
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(
                @as(u32, 30_000),
                input.as(OwnedInput).value.yield_time_ms,
            );
        },
    }
    const interact_decoded = try decode(
        ctx,
        "{\"action\":\"interact\",\"session_id\":\"shell-session\"}",
    );
    switch (interact_decoded) {
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(
                @as(u32, 5_000),
                input.as(OwnedInput).value.yield_time_ms,
            );
        },
    }
}

test "shell interaction wait bounds empty observations without delaying writes" {
    const cases = [_]struct {
        has_input: bool,
        requested_ms: u32,
        expected_ms: u32,
    }{
        .{ .has_input = false, .requested_ms = 0, .expected_ms = 5_000 },
        .{ .has_input = false, .requested_ms = 1_000, .expected_ms = 5_000 },
        .{ .has_input = false, .requested_ms = 5_000, .expected_ms = 5_000 },
        .{ .has_input = false, .requested_ms = 45_000, .expected_ms = 45_000 },
        .{ .has_input = false, .requested_ms = 300_000, .expected_ms = 300_000 },
        .{ .has_input = true, .requested_ms = 0, .expected_ms = 0 },
        .{ .has_input = true, .requested_ms = 1_000, .expected_ms = 1_000 },
        .{ .has_input = true, .requested_ms = 30_000, .expected_ms = 30_000 },
        .{ .has_input = true, .requested_ms = 300_000, .expected_ms = 30_000 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected_ms,
            effective_interact_yield_time(case.has_input, case.requested_ms),
        );
    }

    const failure = try validateInteract(
        .{ .allocator = std.testing.allocator },
        .{
            .action = .interact,
            .session_id = "shell-1",
            .yield_time_ms = managed_contract.max_wait_ceiling_ms + 1,
        },
    ) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(failure);
    try std.testing.expect(std.mem.find(u8, failure, "between 0 and 300000") != null);

    const overflow = try decode(
        .{ .allocator = std.testing.allocator },
        "{\"action\":\"interact\",\"session_id\":\"shell-1\",\"yield_time_ms\":4294967296}",
    );
    switch (overflow) {
        .input => |input| {
            defer input.deinit(std.testing.allocator);
            return error.TestUnexpectedResult;
        },
        .failure => |message| std.testing.allocator.free(message),
    }
}

test "shell decoder rejects removed handoff and legacy actions" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const run_decoded = try decode(
        ctx,
        "{\"action\":\"run\",\"command\":\"sleep 30\",\"yield_time_ms\":0,\"handoff\":\"next_turn\"}",
    );
    switch (run_decoded) {
        .failure => |failure| alloc.free(failure),
        .input => |input| {
            defer input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }

    const wait_decoded = try decode(
        ctx,
        "{\"action\":\"wait\",\"session_id\":\"shell-session\"}",
    );
    switch (wait_decoded) {
        .input => |input| {
            defer input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
        },
    }
}

test "stopped execution is a successful shell observation without command failure metadata" {
    const alloc = std.testing.allocator;
    const statuses = [_]command_contract.CommandStatus{
        .{ .signal = 15 },
        .{ .exit_code = 143 },
    };
    for (statuses) |status| {
        var memory: ?types.ToolResultMemory = null;
        try publishSnapshotMetadata(.{
            .allocator = alloc,
            .tool_result_memory_sink = &memory,
        }, .{
            .execution_id = @constCast("shell-stopped"),
            .command = @constCast("sleep 60"),
            .cwd = @constCast("/tmp"),
            .retained = true,
            .state = .{ .stopped = status },
            .output_delta = @constCast(""),
            .output_truncated = false,
        });
        try std.testing.expect(memory != null);
        try std.testing.expect(memory.?.command_process_presentation == null);
    }
}

test "lost shell snapshot preserves indeterminate execution guidance" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-lost"),
        .command = @constCast("mutating-command"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .lost,
        .output_delta = @constCast(""),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("termination_indeterminate").?.bool);
    try std.testing.expect(std.mem.find(
        u8,
        object.get("retry_guidance").?.string,
        "do not blindly rerun",
    ) != null);
}

test "completed shell snapshot reports incomplete output without losing status" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-incomplete"),
        .command = @constCast("mutating-command"),
        .cwd = @constCast("/tmp"),
        .retained = false,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast("partial output"),
        .output_truncated = false,
        .output_incomplete = true,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("completed", object.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 0), object.get("exit_code").?.integer);
    try std.testing.expect(object.get("output_incomplete").?.bool);
    try std.testing.expect(std.mem.find(
        u8,
        object.get("retry_guidance").?.string,
        "do not blindly rerun",
    ) != null);
}

test "shell snapshot keeps bounded head tail and control metadata" {
    const alloc = std.testing.allocator;
    const output = "HEAD_SENTINEL\n" ++ ("x" ** (70 * 1024)) ++ "\nTAIL_SENTINEL";
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-large"),
        .command = @constCast("large-output"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast(output),
        .output_truncated = false,
        .output_file = @constCast("fx-command-replay-large.bin"),
    }, null);
    defer alloc.free(body);

    try std.testing.expect(body.len <= 16 * 1024);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings(
        "fx-command-replay-large.bin",
        object.get("full_output_handle").?.string,
    );
    try std.testing.expect(object.get("output_truncated").?.bool);
    const projected = object.get("output_delta").?.string;
    try std.testing.expect(std.mem.find(u8, projected, "HEAD_SENTINEL") != null);
    try std.testing.expect(std.mem.find(u8, projected, "TAIL_SENTINEL") != null);
    try std.testing.expect(std.mem.find(u8, projected, "bytes omitted") != null);
}

test "shell snapshot projects hostile bytes as readable terminal-safe text" {
    const alloc = std.testing.allocator;
    const raw = "\x1b[31mRED\x1b[0m\rREWRITE\t\x00\xff\nCONTROL_TAIL\n";
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-hostile"),
        .command = @constCast("hostile-output"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast(raw),
        .output_truncated = false,
        .output_file = @constCast("fx-command-replay-hostile.bin"),
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const output_value = parsed.value.object.get("output_delta") orelse
        return error.TestExpectedEqual;
    if (output_value != .string) return error.TestUnexpectedResult;
    const terminal_safe = parsed.value.object.get("output_terminal_safe") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(terminal_safe.bool);
    try std.testing.expect(std.mem.find(u8, output_value.string, "\\x1b") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "\\x00") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "\\xff") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "CONTROL_TAIL") != null);
    try std.testing.expectEqualStrings(
        "fx-command-replay-hostile.bin",
        parsed.value.object.get("full_output_handle").?.string,
    );
}

test "shell snapshot keeps a hostile output tail within the result limit" {
    const alloc = std.testing.allocator;
    const raw = ("\xff" ** (70 * 1024)) ++ "\nCONTROL_TAIL";
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-hostile-large"),
        .command = @constCast("hostile-large-output"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .completed = .{ .exit_code = 0 } },
        .output_delta = @constCast(raw),
        .output_truncated = false,
        .output_file = @constCast("fx-command-replay-hostile-large.bin"),
    }, null);
    defer alloc.free(body);

    try std.testing.expect(body.len <= 16 * 1024);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const output_value = parsed.value.object.get("output_delta") orelse
        return error.TestExpectedEqual;
    if (output_value != .string) return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, output_value.string, "\\xff") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "bytes omitted") != null);
    try std.testing.expect(std.mem.find(u8, output_value.string, "CONTROL_TAIL") != null);
    try std.testing.expect(parsed.value.object.get("output_truncated").?.bool);
}

test "running shell snapshot leaves continuation intent to the caller" {
    const alloc = std.testing.allocator;
    const body = try formatSnapshot(alloc, .{
        .execution_id = @constCast("shell-running"),
        .command = @constCast("long-command"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .running,
        .output_delta = @constCast(""),
        .output_truncated = false,
    }, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("next_action") == null);
    try std.testing.expectEqualStrings(
        "shell-running",
        parsed.value.object.get("session_id").?.string,
    );
    try std.testing.expectEqualStrings(
        "running",
        parsed.value.object.get("state").?.string,
    );
}

test "registered shell empty observation waits through one managed execution" {
    if (comptime @import("builtin").os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    var streamed_bytes = std.atomic.Value(usize).init(0);
    const StreamCapture = struct {
        fn append(
            raw: *anyopaque,
            _: ?types.ToolLifecycleId,
            _: command_contract.CommandOutputStream,
            chunk: []const u8,
        ) !void {
            const count: *std.atomic.Value(usize) = @ptrCast(@alignCast(raw));
            _ = count.fetchAdd(chunk.len, .seq_cst);
        }
    };
    const spec = tool_dispatch.Tool{
        .name = "shell",
        .description = "shell",
        .model_schema = .{ .name = "shell", .description = "shell" },
        .executor_kind = .terminal,
        .activity_kind = .command,
        .requires_approval = true,
        .decode = decode,
        .validate = validate,
        .call = call,
        .captured_command_action = "run",
        .captured_command_fn = isCapturedCommand,
        .process_local_fn = isProcessLocal,
        .reads_only_fn = readsOnly,
        .irreversible_fn = isIrreversible,
    };
    const registry = tool_dispatch.Registry{ .tools = &.{spec} };
    var environment_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer environment_arena_state.deinit();
    const environment = try commandEnvironment(
        environment_arena_state.allocator(),
        .{ .allocator = alloc, .workspace_root = "/tmp" },
        .clean,
    );
    const command_ctx = command_admission.CommandContext{
        .command = "sleep 2; printf done",
        .resolved_cwd = "/tmp",
        .target_os = @import("builtin").os.tag,
        .environment = environment,
    };
    const authority = command_admission.CommandExecutionAuthority{
        .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .yolo,
        },
    };
    var start_status_detail: ?[]u8 = null;
    defer if (start_status_detail) |detail| alloc.free(detail);
    const started = try tool_dispatch.dispatchAuthorizedToolCall(
        .{
            .allocator = alloc,
            .workspace_root = "/tmp",
            .tool_call_id = "shell-integration",
            .managed_executions = &runtime,
            .execution_authority = .{ .run_command = authority },
            .max_command_output_bytes = 4096,
            .output_chunk_lifecycle_id = .{
                .turn_id = 1,
                .call_id = "shell-integration",
            },
            .output_chunk_ctx = &streamed_bytes,
            .on_output_chunk = StreamCapture.append,
        },
        registry,
        .{
            .id = "shell-integration",
            .name = "shell",
            .arguments_json = "{\"action\":\"run\",\"command\":\"sleep 2; printf done\",\"cwd\":\"/tmp\",\"profile\":\"clean\",\"yield_time_ms\":0}",
        },
        &start_status_detail,
    );
    defer started.deinit(alloc);
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.success, started.status);
    try std.testing.expect(std.mem.find(u8, started.body, "\"state\":\"running\"") != null);
    var started_json = try std.json.parseFromSlice(std.json.Value, alloc, started.body, .{});
    defer started_json.deinit();
    const execution_id = started_json.value.object.get("session_id") orelse
        return error.TestExpectedEqual;
    const interact_arguments = try std.fmt.allocPrint(
        alloc,
        "{{\"action\":\"interact\",\"session_id\":\"{s}\",\"yield_time_ms\":1000}}",
        .{execution_id.string},
    );
    defer alloc.free(interact_arguments);

    var wait_status_detail: ?[]u8 = null;
    defer if (wait_status_detail) |detail| alloc.free(detail);
    var command_result_json: ?[]const u8 = null;
    defer if (command_result_json) |json| alloc.free(@constCast(json));
    var tool_result_memory: ?types.ToolResultMemory = null;
    defer if (tool_result_memory) |memory| {
        if (memory.command_output_replay) |replay| switch (replay) {
            .available => |descriptor| alloc.free(@constCast(descriptor.handle)),
            .unavailable => {},
        };
    };
    const waited = try tool_dispatch.dispatchAuthorizedToolCall(
        .{
            .allocator = alloc,
            .workspace_root = "/tmp",
            .tool_call_id = "shell-wait",
            .managed_executions = &runtime,
            .max_command_output_bytes = 4096,
            .command_result_json_sink = &command_result_json,
            .tool_result_memory_sink = &tool_result_memory,
        },
        registry,
        .{
            .id = "shell-wait",
            .name = "shell",
            .arguments_json = interact_arguments,
        },
        &wait_status_detail,
    );
    defer waited.deinit(alloc);
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.success, waited.status);
    try std.testing.expect(std.mem.find(u8, waited.body, "\"state\":\"completed\"") != null);
    try std.testing.expect(std.mem.find(u8, waited.body, "done") != null);
    try std.testing.expectEqual(@as(usize, "done".len), streamed_bytes.load(.seq_cst));
    try std.testing.expect(std.mem.find(
        u8,
        command_result_json orelse return error.TestExpectedEqual,
        "\"kind\":\"command\"",
    ) != null);
    const replay = tool_result_memory.?.command_output_replay orelse
        return error.TestExpectedEqual;
    try std.testing.expect(replay == .available);
}

test "shell delivery advances only after result commit" {
    if (comptime @import("builtin").os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var runtime = managed_execution.Runtime.init(alloc);
    defer runtime.deinit();
    const command_ctx = command_admission.CommandContext{
        .command = "printf commit-token",
        .resolved_cwd = "/tmp",
        .target_os = @import("builtin").os.tag,
        .environment = .legacy,
    };
    var prepared = try runtime.startCaptured(alloc, .{
        .execution_id = "delivery-commit",
        .command = command_ctx.command,
        .cwd = command_ctx.resolved_cwd,
        .environment = command_ctx.environment,
        .authority = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = .yolo,
        } },
        .max_output_bytes = 4096,
        .timeout_ms = 2000,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
    });
    defer prepared.deinit(alloc);
    var commit_token: ?result_commit.Token = null;
    var result = try finishPrepared(
        .{
            .allocator = alloc,
            .result_commit_sink = &commit_token,
        },
        &runtime,
        &prepared,
        .command,
    );
    defer result.deinit(alloc);
    try std.testing.expect(commit_token != null);
    try std.testing.expectError(
        error.ExecutionBusy,
        runtime.wait(alloc, "delivery-commit", 0, null),
    );
    commit_token.?.cancel();
    var replayed = try runtime.wait(alloc, "delivery-commit", 2000, null);
    defer replayed.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        replayed.snapshot.output_delta,
        "commit-token",
    ) != null);
    try runtime.commitDelivery(
        replayed.snapshot.execution_id,
        replayed.reservation_id,
    );
}
