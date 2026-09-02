const std = @import("std");
const contracts = @import("../../core/terminal/contracts.zig");
const client = @import("../../core/terminal/client.zig");
const identity = @import("../../core/terminal/identity.zig");
const operation = @import("../../core/terminal/operation.zig");
const store = @import("../../core/terminal/store.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const command_environment = @import("../../core/execution/command_environment.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const workspace_access = @import("../../core/workspace/workspace_access.zig");
const shell_resolver = @import("../../core/terminal/shell_resolver.zig");

const Allocator = std.mem.Allocator;

pub const exec_timeout_min_ms: u64 = 1;
pub const exec_timeout_max_ms: u64 = 600_000;

const ShellKind = enum { user_login, executable };
pub const Action = enum {
    exec,
    start,
    read,
    screen,
    write,
    wait,
    monitor,
    inspect,
    list,
    resize,
    signal,
    close,
};
const ReturnKind = enum { started, exit, quiet, match };
const PayloadKind = enum { text, keys, controls, paste };
const MonitorConditionKind = enum {
    process_exit,
    exit_code,
    signal,
    output_contains,
    output_matches,
    output_quiet,
    screen_matches,
    tcp_ready,
    http_ready,
    path_exists,
    path_changed,
    path_size,
    custom_probe,
};
const NotifyKind = enum {
    on_match,
    on_state_change,
    on_exit,
    every_check,
    every_n_checks,
    interval,
};
const LifetimeKind = enum { until_match, until_session_end, duration };
const MonitorOperationKind = enum { add, update, pause, @"resume", remove };
const composite_argument_fields = [_][]const u8{
    "shell",
    "return_when",
    "dimensions",
    "initial_monitors",
    "write",
    "monitor",
};

pub const ShellInput = struct {
    kind: ShellKind = .user_login,
    path: ?[]const u8 = null,
    clean_start: bool = false,
};

pub const ReturnInput = struct {
    kind: ReturnKind,
    duration_ms: ?u64 = null,
    pattern: ?[]const u8 = null,
};

pub const DimensionsInput = struct {
    rows: u16,
    columns: u16,
};

pub const WriteInput = struct {
    kind: PayloadKind,
    text: ?[]const u8 = null,
    keys: []const contracts.NamedKey = &.{},
    controls: []const u8 = &.{},
};

pub const MonitorConditionInput = struct {
    kind: MonitorConditionKind,
    pattern: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    exit_code: ?i32 = null,
    signal: ?contracts.Signal = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    path: ?[]const u8 = null,
    minimum_bytes: ?u64 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

pub const NotifyInput = struct {
    kind: NotifyKind,
    count: ?u32 = null,
    interval_ms: ?u64 = null,
};

pub const LifetimeInput = struct {
    kind: LifetimeKind,
    duration_ms: ?u64 = null,
};

pub const MonitorDefinitionInput = struct {
    condition: MonitorConditionInput,
    check_interval_ms: ?u64 = null,
    notify: NotifyInput,
    lifetime: LifetimeInput,
};

pub const MonitorOperationInput = struct {
    kind: MonitorOperationKind,
    monitor_id: ?[]const u8 = null,
    definition: ?MonitorDefinitionInput = null,
};

/// Public semantic terminal input. Authority and persistence fields are
/// intentionally absent; Core derives them from the current fx session.
pub const Input = struct {
    action: Action,
    session_id: ?[]const u8 = null,

    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,
    profile: ?command_environment.Profile = null,
    timeout_ms: ?u64 = null,
    shell: ?ShellInput = null,
    backend: ?contracts.Backend = null,
    return_when: ?ReturnInput = null,
    wait_ceiling_ms: ?u64 = null,
    dimensions: ?DimensionsInput = null,
    initial_monitors: []const MonitorDefinitionInput = &.{},

    cursor_segment: ?u64 = null,
    cursor_offset: ?u64 = null,
    after_event_id: u64 = 0,
    acknowledge_event_id: ?u64 = null,
    max_events: u16 = 64,

    write: ?WriteInput = null,
    lease: contracts.WriteLeaseIntent = .use,
    monitor: ?MonitorOperationInput = null,

    task_id: ?[]const u8 = null,
    workspace_root: ?[]const u8 = null,
    rows: ?u16 = null,
    columns: ?u16 = null,
    signal: ?contracts.Signal = null,
    close_policy: ?contracts.ClosePolicy = null,
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
        .exec => .{
            .allowed = &.{ "action", "command", "cwd", "profile", "timeout_ms" },
            .required = &.{ "action", "command", "timeout_ms" },
        },
        .start => .{
            .allowed = &.{ "action", "cwd", "command", "profile", "shell", "backend", "return_when", "wait_ceiling_ms", "dimensions", "initial_monitors" },
            .required = &.{"action"},
            .conflicts = &.{.{ "profile", "shell" }},
        },
        .read => .{
            .allowed = &.{ "action", "session_id", "cursor_segment", "cursor_offset" },
            .required = &.{ "action", "session_id", "cursor_segment" },
        },
        .screen => .{
            .allowed = &.{ "action", "session_id" },
            .required = &.{ "action", "session_id" },
        },
        .write => .{
            .allowed = &.{ "action", "session_id", "write", "lease" },
            .required = &.{ "action", "session_id" },
        },
        .wait => .{
            .allowed = &.{ "action", "session_id", "return_when", "wait_ceiling_ms" },
            .required = &.{ "action", "session_id", "return_when", "wait_ceiling_ms" },
        },
        .monitor => .{
            .allowed = &.{ "action", "session_id", "monitor" },
            .required = &.{ "action", "session_id", "monitor" },
        },
        .inspect => .{
            .allowed = &.{ "action", "session_id", "after_event_id", "acknowledge_event_id", "max_events" },
            .required = &.{ "action", "session_id" },
        },
        .list => .{
            .allowed = &.{ "action", "task_id", "workspace_root", "backend" },
            .required = &.{"action"},
        },
        .resize => .{
            .allowed = &.{ "action", "session_id", "rows", "columns" },
            .required = &.{ "action", "session_id", "rows", "columns" },
        },
        .signal => .{
            .allowed = &.{ "action", "session_id", "signal" },
            .required = &.{ "action", "session_id", "signal" },
        },
        .close => .{
            .allowed = &.{ "action", "session_id", "close_policy" },
            .required = &.{ "action", "session_id", "close_policy" },
        },
    };
}

fn actionFieldNames(action: Action) []const []const u8 {
    return actionFieldContract(action).allowed;
}

fn actionAllowsField(action: Action, field_name: []const u8) bool {
    for (actionFieldNames(action)) |allowed_name| {
        if (std.mem.eql(u8, allowed_name, field_name)) return true;
    }
    return false;
}

fn isPublicField(field_name: []const u8) bool {
    for (public_field_names) |known_name| {
        if (std.mem.eql(u8, known_name, field_name)) return true;
    }
    return false;
}

fn fieldNameLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// The advertised schema requires every public field and tells the model to
/// send null for the ones the selected action does not use. Models routinely
/// serialize that null as the literal text "null", so the decoder treats it as
/// the absence it was meant to express.
fn isNullPlaceholder(value: std.json.Value) bool {
    return switch (value) {
        .null => true,
        .string => |text| tool_args.isNullPlaceholderText(text),
        else => false,
    };
}

fn elideKnownNullFields(object: *std.json.ObjectMap) void {
    for (public_field_names[1..]) |field_name| {
        const value = object.get(field_name) orelse continue;
        if (!isNullPlaceholder(value)) continue;
        _ = object.orderedRemove(field_name);
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
    const contract = actionFieldContract(action);
    try scratch.invalid_fields.ensureTotalCapacity(alloc, object.count());
    for (public_field_names) |field_name| {
        if (object.get(field_name) == null) continue;
        var allowed = false;
        for (contract.allowed) |allowed_name| {
            if (std.mem.eql(u8, allowed_name, field_name)) {
                allowed = true;
                break;
            }
        }
        if (allowed) continue;
        scratch.invalid_fields.appendAssumeCapacity(field_name);
    }
    const unknown_start = scratch.invalid_fields.items.len;
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (isPublicField(entry.key_ptr.*)) continue;
        scratch.invalid_fields.appendAssumeCapacity(entry.key_ptr.*);
    }
    sort_utils.sort(
        []const u8,
        scratch.invalid_fields.items[unknown_start..],
        {},
        fieldNameLessThan,
    );

    var missing_count: usize = 0;
    for (contract.required) |field_name| {
        if (object.get(field_name) != null) continue;
        scratch.missing_fields[missing_count] = field_name;
        missing_count += 1;
    }

    var conflict_count: usize = 0;
    for (contract.conflicts) |conflict| {
        if (object.get(conflict[0]) == null or object.get(conflict[1]) == null) continue;
        scratch.conflicts[conflict_count] = conflict;
        conflict_count += 1;
    }

    if (scratch.invalid_fields.items.len == 0 and missing_count == 0 and conflict_count == 0) return null;
    return .{
        .action = @tagName(action),
        .invalid_fields = scratch.invalid_fields.items,
        .missing_fields = scratch.missing_fields[0..missing_count],
        .allowed_fields = contract.allowed,
        .conflicts = scratch.conflicts[0..conflict_count],
    };
}

const OwnedInput = struct {
    arena_state: std.heap.ArenaAllocator.State,
    value: Input,
    lease_explicit: bool,

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
    ) catch {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "terminal arguments must match the advertised action schema",
        ) };
    };
    if (raw != .object) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "terminal arguments must match the advertised action schema",
        ) };
    }
    const raw_action = raw.object.get("action") orelse {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "terminal arguments must match the advertised action schema",
        ) };
    };
    if (raw_action != .string) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "terminal arguments must match the advertised action schema",
        ) };
    }
    const action = std.meta.stringToEnum(Action, raw_action.string) orelse {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "terminal arguments must match the advertised action schema",
        ) };
    };
    if (action == .exec) {
        if (raw.object.get("timeout_ms")) |timeout_value| {
            if (timeout_value != .integer) {
                return .{ .failure = try ctx.allocator.dupe(
                    u8,
                    "terminal exec field \"timeout_ms\" must be an integer between 1 and 600000",
                ) };
            }
        }
    }
    elideKnownNullFields(&raw.object);
    const lease_explicit = raw.object.get("lease") != null;
    var correction_scratch: ActionFieldCorrectionScratch = .{};
    defer correction_scratch.deinit(ctx.allocator);
    if (try actionFieldCorrection(ctx.allocator, action, raw.object, &correction_scratch)) |correction| {
        return .{ .failure = try tool_result_errors.terminalActionFieldCorrectionJson(
            ctx.allocator,
            correction,
        ) };
    }

    normalizeCompositeArguments(arena, &raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            return .{ .failure = try ctx.allocator.dupe(
                u8,
                "terminal arguments must match the advertised action schema",
            ) };
        },
    };

    const input = std.json.parseFromValueLeaky(
        Input,
        arena,
        raw,
        .{},
    ) catch {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "terminal arguments must match the advertised action schema",
        ) };
    };
    const owned = try ctx.allocator.create(OwnedInput);
    owned.* = .{
        .arena_state = arena_state.state,
        .value = input,
        .lease_explicit = lease_explicit,
    };
    arena_state.state = .init;
    return .{ .input = .{
        .ptr = owned,
        .deinit_fn = inputDeinit,
    } };
}

fn normalizeCompositeArguments(
    alloc: Allocator,
    root: *std.json.Value,
) !void {
    for (composite_argument_fields) |field_name| {
        const value = root.object.getPtr(field_name) orelse continue;
        if (value.* != .string) continue;
        const decoded = try std.json.parseFromSliceLeaky(
            std.json.Value,
            alloc,
            value.string,
            .{ .allocate = .alloc_always },
        );
        if (decoded != .object and decoded != .array) {
            return error.InvalidCompositeArgument;
        }
        value.* = decoded;
    }

    const initial_monitors = root.object.getPtr("initial_monitors") orelse return;
    if (initial_monitors.* != .array) return;
    for (initial_monitors.array.items) |*monitor| {
        if (monitor.* != .object) continue;
        const condition = monitor.object.getPtr("condition") orelse continue;
        if (condition.* != .object) continue;
        const interval = condition.object.get("check_interval_ms") orelse continue;
        _ = condition.object.orderedRemove("check_interval_ms");
        if (monitor.object.get("check_interval_ms") == null) {
            try monitor.object.put(alloc, "check_interval_ms", interval);
        }
    }
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *OwnedInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = &erased.as(OwnedInput).value;
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (input.action == .exec) {
        if (input.command == null) {
            return try ctx.allocator.dupe(u8, "terminal exec arguments are invalid: MissingCommand");
        }
        if (input.command.?.len > contracts.max_command_bytes) {
            return try ctx.allocator.dupe(u8, "terminal exec arguments are invalid: InvalidCommand");
        }
        const timeout_ms = input.timeout_ms orelse {
            return try ctx.allocator.dupe(u8, "terminal exec arguments are invalid: MissingTimeout");
        };
        if (timeout_ms < exec_timeout_min_ms or timeout_ms > exec_timeout_max_ms) {
            return try ctx.allocator.dupe(u8, "terminal exec arguments are invalid: InvalidTimeout");
        }
        _ = resolveCwd(arena, ctx, input.cwd) catch |err| {
            return try std.fmt.allocPrint(
                ctx.allocator,
                "terminal exec arguments are invalid: {s}",
                .{@errorName(err)},
            );
        };
        _ = commandEnvironment(arena, ctx, input.profile) catch |err| {
            return try std.fmt.allocPrint(
                ctx.allocator,
                "terminal exec arguments are invalid: {s}",
                .{@errorName(err)},
            );
        };
        return null;
    }
    if (input.action == .start and input.profile != null and input.shell != null) {
        return try ctx.allocator.dupe(u8, "terminal start fields \"profile\" and \"shell\" are mutually exclusive");
    }
    const request = semanticRequest(arena, ctx, input) catch |err| {
        return @as(?[]u8, try std.fmt.allocPrint(
            ctx.allocator,
            "terminal {s} arguments are invalid: {s}",
            .{ @tagName(input.action), @errorName(err) },
        ));
    };
    request.validate() catch |err| {
        return @as(?[]u8, try std.fmt.allocPrint(
            ctx.allocator,
            "terminal {s} arguments are invalid: {s}",
            .{ @tagName(input.action), @errorName(err) },
        ));
    };
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const owned = erased.as(OwnedInput);
    const input = &owned.value;
    if (input.action == .exec) return callExec(ctx, input);
    if (input.action == .write and input.write != null and !owned.lease_explicit) {
        return call_atomic_write(ctx, input);
    }
    return callDurable(ctx, input);
}

fn call_atomic_write(
    ctx: tool_dispatch.DispatchContext,
    input: *const Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var acquire = input.*;
    acquire.lease = .acquire;
    acquire.write = null;
    var acquired = try callDurable(ctx, &acquire);
    switch (acquired) {
        .failure => return acquired,
        .success => {},
    }
    defer acquired.deinit(ctx.allocator);

    var use = input.*;
    use.lease = .use;
    var used = callDurable(ctx, &use) catch |err| {
        release_atomic_write_after_failure(ctx, input);
        return err;
    };
    switch (used) {
        .failure => {
            release_atomic_write_after_failure(ctx, input);
            return used;
        },
        .success => {},
    }
    defer used.deinit(ctx.allocator);

    var released = try release_atomic_write(ctx, input);
    switch (released) {
        .failure => return released,
        .success => {},
    }
    defer released.deinit(ctx.allocator);

    return merge_atomic_write_results(ctx.allocator, used, released);
}

fn release_atomic_write(
    ctx: tool_dispatch.DispatchContext,
    input: *const Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var release = input.*;
    release.lease = .release;
    release.write = null;
    var cleanup_ctx = ctx;
    cleanup_ctx.cancel_flag = null;
    return callDurable(cleanup_ctx, &release);
}

fn release_atomic_write_after_failure(
    ctx: tool_dispatch.DispatchContext,
    input: *const Input,
) void {
    var released = release_atomic_write(ctx, input) catch |err| {
        debug_trace.logf(
            "terminal",
            "atomic write cleanup failed session_id={s} err={s}",
            .{ input.session_id orelse "", @errorName(err) },
        );
        return;
    };
    defer released.deinit(ctx.allocator);
    switch (released) {
        .success => {},
        .failure => debug_trace.logf(
            "terminal",
            "atomic write cleanup was rejected session_id={s}",
            .{input.session_id orelse ""},
        ),
    }
}

fn merge_atomic_write_results(
    alloc: Allocator,
    used: tool_dispatch.ToolResult,
    released: tool_dispatch.ToolResult,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const used_body = switch (used) {
        .success => |value| value,
        .failure => return error.InvalidToolArguments,
    };
    var parsed_used = try std.json.parseFromSlice(
        contracts.Result,
        alloc,
        used_body,
        .{},
    );
    defer parsed_used.deinit();
    const accepted_bytes = switch (parsed_used.value) {
        .success => |success| switch (success) {
            .write => |write| write.accepted_bytes,
            else => return error.InvalidToolArguments,
        },
        .failure => return error.InvalidToolArguments,
    };

    const released_body = switch (released) {
        .success => |value| value,
        .failure => return error.InvalidToolArguments,
    };
    var parsed_released = try std.json.parseFromSlice(
        contracts.Result,
        alloc,
        released_body,
        .{},
    );
    defer parsed_released.deinit();
    return switch (parsed_released.value) {
        .success => |success| switch (success) {
            .write => |write| stringifyResult(alloc, .{ .success = .{
                .write = .{
                    .session = write.session,
                    .accepted_bytes = accepted_bytes,
                },
            } }),
            else => error.InvalidToolArguments,
        },
        .failure => error.InvalidToolArguments,
    };
}

fn callDurable(
    ctx: tool_dispatch.DispatchContext,
    input: *const Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const runtime = ctx.terminal_client orelse return structuredFailure(
        ctx,
        durableAction(input.action).?,
        null,
        .unsupported_host,
        false,
    );
    const owner = ctx.session_child_capability orelse return structuredFailure(
        ctx,
        durableAction(input.action).?,
        null,
        .authority_denied,
        false,
    );
    const durable_session_id = ctx.terminal_owner_session_id orelse
        return structuredFailure(
            ctx,
            durableAction(input.action).?,
            null,
            .authority_denied,
            false,
        );
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var profile_user_buffer: [64]u8 = undefined;
    const profile_user = identity.profileUser(&profile_user_buffer) orelse return structuredFailure(
        ctx,
        durableAction(input.action).?,
        input.session_id,
        .unsupported_host,
        false,
    );

    var request = buildRequest(
        arena,
        ctx,
        owner,
        durable_session_id,
        profile_user,
        input,
    ) catch |err| {
        debug_trace.logf(
            "terminal",
            "public request preparation failed action={s} err={s}",
            .{ @tagName(input.action), @errorName(err) },
        );
        if (err == error.TerminalSessionNotFound and
            input.action == .list and input.session_id == null)
        {
            return projectResult(ctx, .{ .success = .{
                .list = .{ .sessions = &.{} },
            } });
        }
        return structuredFailure(
            ctx,
            durableAction(input.action).?,
            input.session_id,
            mapErrorCode(err),
            false,
        );
    };
    defer request.deinit();

    const correlation_id = runtime.nextCorrelationId();
    runtime.admit(
        ctx.background_lifecycle_allocator,
        correlation_id,
        request.value,
    ) catch |err| {
        debug_trace.logf(
            "terminal",
            "public request admission failed action={s} err={s}",
            .{ @tagName(input.action), @errorName(err) },
        );
        return structuredFailure(
            ctx,
            durableAction(input.action).?,
            request.sessionId(),
            mapErrorCode(err),
            err == error.QueueFull,
        );
    };

    var cancellation_sent = false;
    while (true) {
        if (runtime.takeCompletionFor(correlation_id)) |completion_value| {
            var completion = completion_value;
            defer completion.deinit();
            return resultFromCompletion(
                ctx,
                durableAction(input.action).?,
                request.sessionId(),
                completion,
            );
        }
        if (!cancellation_sent) {
            if (ctx.cancel_flag) |cancel_flag| {
                if (cancel_flag.load(.acquire)) {
                    _ = runtime.cancel(correlation_id);
                    cancellation_sent = true;
                }
            }
        }
        io_mod.sleep(2 * std.time.ns_per_ms);
    }
}

pub fn release_agent_write_lease(
    ctx: tool_dispatch.DispatchContext,
    session_id: []const u8,
) !void {
    const input = Input{
        .action = .write,
        .session_id = session_id,
        .lease = .release,
    };
    const result = try callDurable(ctx, &input);
    defer result.deinit(ctx.allocator);
    const body = switch (result) {
        .success => |value| value,
        .failure => |value| value,
    };
    var parsed = std.json.parseFromSlice(
        contracts.Result,
        ctx.allocator,
        body,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidTerminalLeaseCleanupResult,
    };
    defer parsed.deinit();
    return switch (parsed.value) {
        .success => |success| switch (success) {
            .write => {},
            else => error.InvalidTerminalLeaseCleanupResult,
        },
        .failure => |failure| switch (failure.code) {
            .session_not_found, .lease_conflict => {},
            else => error.TerminalLeaseCleanupFailed,
        },
    };
}

fn callExec(
    ctx: tool_dispatch.DispatchContext,
    input: *const Input,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const backend = ctx.run_command_backend orelse return .{
        .failure = try ctx.allocator.dupe(u8, "terminal exec backend is unavailable\n"),
    };
    const command = input.command orelse return .{
        .failure = try ctx.allocator.dupe(u8, "terminal exec requires string field \"command\""),
    };
    const timeout_ms = input.timeout_ms orelse return .{
        .failure = try ctx.allocator.dupe(u8, "terminal exec requires integer field \"timeout_ms\""),
    };
    const cwd = resolveCwd(ctx.allocator, ctx, input.cwd) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "Unable to resolve command cwd: {s}",
            .{@errorName(err)},
        ) };
    };
    defer ctx.allocator.free(@constCast(cwd));
    var environment_arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer environment_arena_state.deinit();
    const environment_value = commandEnvironment(
        environment_arena_state.allocator(),
        ctx,
        input.profile,
    ) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "Unable to resolve terminal exec profile: {s}",
            .{@errorName(err)},
        ) };
    };
    return backend.execute(ctx, .{
        .command = command,
        .resolved_cwd = cwd,
        .environment = environment_value,
        .timeout_ms = timeout_ms,
    });
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

fn durableAction(action: Action) ?contracts.Action {
    return switch (action) {
        .exec => null,
        .start => .start,
        .read => .read,
        .screen => .screen,
        .write => .write,
        .wait => .wait,
        .monitor => .monitor,
        .inspect => .inspect,
        .list => .list,
        .resize => .resize,
        .signal => .signal,
        .close => .close,
    };
}

pub fn isCapturedCommand(erased: tool_dispatch.ToolInput) bool {
    return erased.as(OwnedInput).value.action == .exec;
}

const PreparedRequest = struct {
    value: contracts.ActionRequest,
    authority: ?operation.OwnedAuthorityClaim = null,
    owner_authority: ?operation.OwnedOwnerCatalogClaim = null,
    persistence: ?operation.PreparedAuthority = null,

    fn sessionId(self: *const PreparedRequest) ?[]const u8 {
        return operation.authoritySessionId(self.value);
    }

    fn deinit(self: *PreparedRequest) void {
        if (self.authority) |*authority| authority.deinit();
        if (self.owner_authority) |*authority| authority.deinit();
        if (self.persistence) |*persistence| persistence.deinit();
        self.* = undefined;
    }
};

fn buildRequest(
    arena: Allocator,
    ctx: tool_dispatch.DispatchContext,
    owner: *@import("../../core/session/session_child_store.zig").SessionChildCapability,
    durable_session_id: []const u8,
    profile_user: []const u8,
    input: *const Input,
) !PreparedRequest {
    if (input.action == .start) {
        const cwd = try resolveCwd(arena, ctx, input.cwd);
        const definitions = try buildMonitorDefinitions(arena, input.initial_monitors);
        const repeated_probes = try repeatedProbeAuthority(arena, definitions);
        var persistence = try operation.prepareStartPersistence(arena, .{
            .profile_user = profile_user,
            .durable_session_id = durable_session_id,
            .workspace_root = ctx.workspace_root,
            .cwd = cwd,
            .transport_role = ctx.terminal_transport_role,
            .backend = input.backend orelse .native,
            .actor = .agent,
            .controls = .full(),
            .lifetime = .session,
            .repeated_probes = repeated_probes,
        });
        errdefer persistence.deinit();
        const request = startRequest(arena, input, cwd, definitions, persistence.view()) catch |err| {
            return err;
        };
        try operation.validate(request);
        return .{ .value = request, .persistence = persistence };
    }

    if (input.action == .list) {
        var owner_authority = try store.loadOrCreateOwnerCatalogClaim(
            arena,
            owner,
            .{
                .profile_user = profile_user,
                .durable_session_id = durable_session_id,
                .workspace_root = ctx.workspace_root,
                .transport_role = ctx.terminal_transport_role,
                .actor = .agent,
            },
        );
        errdefer owner_authority.deinit();
        const request = try build_list_request(
            arena,
            ctx,
            input,
            owner_authority.view(),
        );
        try operation.validate(request);
        return .{ .value = request, .owner_authority = owner_authority };
    }

    const authority_session_id = try arena.dupe(
        u8,
        input.session_id orelse return error.InvalidSessionId,
    );
    var authority = try store.reloadOwnerAuthorityClaim(arena, owner, .{
        .terminal_session_id = authority_session_id,
        .profile_user = profile_user,
        .durable_session_id = durable_session_id,
        .workspace_root = ctx.workspace_root,
        .transport_role = ctx.terminal_transport_role,
        .actor = .agent,
    });
    errdefer authority.deinit();
    const claim = authority.view();
    const request = try buildAuthorizedRequest(arena, input, authority_session_id, claim);
    try operation.validate(request);
    return .{ .value = request, .authority = authority };
}

inline fn failActionRequest(err: anytype) @TypeOf(err)!contracts.ActionRequest {
    return @errorCast(failActionRequestDynamic(err));
}

noinline fn failActionRequestDynamic(err: anyerror) anyerror!contracts.ActionRequest {
    return err;
}


fn buildAuthorizedRequest(
    arena: Allocator,
    input: *const Input,
    session_id: []const u8,
    authority: ?contracts.AuthorityClaim,
) !contracts.ActionRequest {
    return switch (input.action) {
        .exec => unreachable,
        .start => unreachable,
        .read => .{ .read = .{
            .session_id = session_id,
            .cursor = .{
                .segment = input.cursor_segment orelse
                    return failActionRequest(error.InvalidRawCursor),
                .offset = input.cursor_offset orelse 0,
            },
            .authority = authority,
        } },
        .screen => .{ .screen = .{
            .session_id = session_id,
            .authority = authority,
        } },
        .write => .{ .write = .{
            .session_id = session_id,
            .payload = if (input.write) |write|
                buildWritePayload(arena, write) catch |err|
                    return failActionRequest(err)
            else
                null,
            .lease = input.lease,
            .authority = authority,
        } },
        .wait => .{ .wait = .{
            .session_id = session_id,
            .return_when = buildReturnCondition(input.return_when orelse
                return failActionRequest(error.MissingReturnCondition)) catch |err|
                return failActionRequest(err),
            .safety_ceiling_ms = input.wait_ceiling_ms orelse
                return failActionRequest(error.MissingWaitCeiling),
            .authority = authority,
        } },
        .monitor => .{ .monitor = .{
            .session_id = session_id,
            .operation = buildMonitorOperation(input.monitor orelse
                return failActionRequest(error.InvalidMonitor)) catch |err|
                return failActionRequest(err),
            .authority = authority,
        } },
        .inspect => .{ .inspect = .{
            .session_id = session_id,
            .authority = authority,
            .after_event_id = input.after_event_id,
            .acknowledge_event_id = input.acknowledge_event_id,
            .max_events = input.max_events,
        } },
        .list => unreachable,
        .resize => .{ .resize = .{
            .session_id = session_id,
            .dimensions = .{
                .rows = input.rows orelse
                    return failActionRequest(error.InvalidDimensions),
                .columns = input.columns orelse
                    return failActionRequest(error.InvalidDimensions),
            },
            .authority = authority,
        } },
        .signal => .{ .signal = .{
            .session_id = session_id,
            .signal = input.signal orelse
                return failActionRequest(error.InvalidRequest),
            .authority = authority,
        } },
        .close => .{ .close = .{
            .session_id = session_id,
            .policy = input.close_policy orelse
                return failActionRequest(error.InvalidRequest),
            .authority = authority,
        } },
    };
}

fn semanticRequest(
    arena: Allocator,
    ctx: tool_dispatch.DispatchContext,
    input: *const Input,
) !contracts.ActionRequest {
    if (input.action == .exec) return error.InvalidRequest;
    if (input.action == .start) {
        const cwd = try resolveCwd(arena, ctx, input.cwd);
        const definitions = try buildMonitorDefinitions(arena, input.initial_monitors);
        return startRequest(arena, input, cwd, definitions, null);
    }
    if (input.action == .list) {
        return build_list_request(arena, ctx, input, null);
    }
    const session_id = input.session_id orelse return error.InvalidSessionId;
    return buildAuthorizedRequest(arena, input, session_id, null);
}

fn project_list_filters(input: *const Input) contracts.ListFilters {
    return .{
        .task_id = if (input.task_id) |task_id|
            if (task_id.len == 0) null else task_id
        else
            null,
        .workspace_root = if (input.workspace_root) |workspace_root|
            if (workspace_root.len == 0) null else workspace_root
        else
            null,
        .backend = input.backend,
    };
}

fn build_list_request(
    arena: Allocator,
    ctx: tool_dispatch.DispatchContext,
    input: *const Input,
    owner_authority: ?contracts.OwnerCatalogAuthorityClaim,
) !contracts.ActionRequest {
    var filters = project_list_filters(input);
    if (filters.workspace_root) |root| {
        filters.workspace_root = try resolveCwd(arena, ctx, root);
    }
    filters.owner_authority = owner_authority;
    return .{ .list = filters };
}

fn startRequest(
    arena: Allocator,
    input: *const Input,
    cwd: []const u8,
    definitions: []const contracts.MonitorDefinition,
    persistence: ?contracts.StartPersistence,
) !contracts.ActionRequest {
    const command: ?[]const u8 = if (input.command) |value|
        if (value.len == 0) null else value
    else
        null;
    return .{ .start = .{
        .cwd = cwd,
        .command = command,
        .shell = try buildStartShell(arena, input),
        .backend = input.backend orelse .native,
        .return_when = if (input.return_when) |condition|
            try buildReturnCondition(condition)
        else if (command != null)
            .started
        else
            null,
        .wait_ceiling_ms = input.wait_ceiling_ms,
        .dimensions = if (input.dimensions) |value|
            .{ .rows = value.rows, .columns = value.columns }
        else
            null,
        .initial_monitors = definitions,
        .persistence = persistence,
    } };
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

fn buildShell(input: ShellInput) !contracts.ShellSpec {
    return switch (input.kind) {
        .user_login => .user_login,
        .executable => .{ .executable = .{
            .path = input.path orelse return error.InvalidShell,
            .clean_start = input.clean_start,
        } },
    };
}

fn buildStartShell(arena: Allocator, input: *const Input) !contracts.ShellSpec {
    if (input.shell) |shell| return buildShell(shell);
    const profile = input.profile orelse .user;
    var login_shell_buffer: [4096]u8 = undefined;
    const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
    return shell_resolver.profileShell(arena, configured, profile);
}

fn buildReturnCondition(input: ReturnInput) !contracts.ReturnCondition {
    return switch (input.kind) {
        .started => .started,
        .exit => .exit,
        .quiet => .{ .quiet = input.duration_ms orelse
            return error.InvalidReturnCondition },
        .match => .{ .match = input.pattern orelse
            return error.InvalidReturnCondition },
    };
}

fn buildWritePayload(
    arena: Allocator,
    input: WriteInput,
) !contracts.WritePayload {
    return switch (input.kind) {
        .text => .{ .text = input.text orelse return error.InvalidWritePayload },
        .paste => .{ .paste = input.text orelse return error.InvalidWritePayload },
        .keys => .{ .keys = input.keys },
        .controls => blk: {
            const controls = try arena.alloc(
                contracts.ControlInput,
                input.controls.len,
            );
            for (input.controls, 0..) |character, index| {
                controls[index] = .{ .character = character };
            }
            break :blk .{ .controls = controls };
        },
    };
}

fn buildMonitorDefinitions(
    arena: Allocator,
    inputs: []const MonitorDefinitionInput,
) ![]contracts.MonitorDefinition {
    const definitions = try arena.alloc(contracts.MonitorDefinition, inputs.len);
    for (inputs, 0..) |input, index| {
        definitions[index] = try buildMonitorDefinition(input);
    }
    return definitions;
}

fn buildMonitorDefinition(input: MonitorDefinitionInput) !contracts.MonitorDefinition {
    const condition = try buildMonitorCondition(input.condition);
    return .{
        .condition = condition,
        .check_schedule = if (condition.requires_polling())
            .{ .interval_ms = input.check_interval_ms orelse
                return error.MissingCheckSchedule }
        else
            null,
        .notify_schedule = try buildNotifySchedule(input.notify),
        .lifetime = try buildMonitorLifetime(input.lifetime),
    };
}

fn buildMonitorCondition(input: MonitorConditionInput) !contracts.MonitorCondition {
    return switch (input.kind) {
        .process_exit => .process_exit,
        .exit_code => .{ .exit_code = input.exit_code orelse
            return error.InvalidMonitorCondition },
        .signal => .{ .signal = input.signal orelse
            return error.InvalidMonitorCondition },
        .output_contains => .{ .output_contains = input.pattern orelse
            return error.InvalidMonitorCondition },
        .output_matches => .{ .output_matches = input.pattern orelse
            return error.InvalidMonitorCondition },
        .output_quiet => .{ .output_quiet_ms = input.duration_ms orelse
            return error.InvalidMonitorCondition },
        .screen_matches => .{ .screen_matches = input.pattern orelse
            return error.InvalidMonitorCondition },
        .tcp_ready => .{ .tcp_ready = .{
            .host = input.host orelse return error.InvalidMonitorCondition,
            .port = input.port orelse return error.InvalidMonitorCondition,
        } },
        .http_ready => .{ .http_ready = input.pattern orelse
            return error.InvalidMonitorCondition },
        .path_exists => .{ .path_exists = input.path orelse
            return error.InvalidMonitorCondition },
        .path_changed => .{ .path_changed = input.path orelse
            return error.InvalidMonitorCondition },
        .path_size => .{ .path_size = .{
            .path = input.path orelse return error.InvalidMonitorCondition,
            .minimum_bytes = input.minimum_bytes orelse
                return error.InvalidMonitorCondition,
        } },
        .custom_probe => .{ .custom_probe = .{
            .command = input.command orelse return error.InvalidMonitorCondition,
            .cwd = input.cwd orelse return error.InvalidMonitorCondition,
        } },
    };
}

fn buildNotifySchedule(input: NotifyInput) !contracts.NotifySchedule {
    return switch (input.kind) {
        .on_match => .on_match,
        .on_state_change => .on_state_change,
        .on_exit => .on_exit,
        .every_check => .every_check,
        .every_n_checks => .{ .every_n_checks = input.count orelse
            return error.InvalidSchedule },
        .interval => .{ .interval = .{
            .interval_ms = input.interval_ms orelse return error.InvalidSchedule,
        } },
    };
}

fn buildMonitorLifetime(input: LifetimeInput) !contracts.MonitorLifetime {
    return switch (input.kind) {
        .until_match => .until_match,
        .until_session_end => .until_session_end,
        .duration => .{ .duration_ms = input.duration_ms orelse
            return error.InvalidMonitorLifetime },
    };
}

fn buildMonitorOperation(input: MonitorOperationInput) !contracts.MonitorOperation {
    return switch (input.kind) {
        .add => .{ .add = try buildMonitorDefinition(input.definition orelse
            return error.InvalidMonitor) },
        .update => .{ .update = .{
            .monitor_id = input.monitor_id orelse return error.InvalidMonitor,
            .definition = try buildMonitorDefinition(input.definition orelse
                return error.InvalidMonitor),
        } },
        .pause => .{ .pause = input.monitor_id orelse return error.InvalidMonitor },
        .@"resume" => .{ .@"resume" = input.monitor_id orelse
            return error.InvalidMonitor },
        .remove => .{ .remove = input.monitor_id orelse return error.InvalidMonitor },
    };
}

fn repeatedProbeAuthority(
    arena: Allocator,
    definitions: []const contracts.MonitorDefinition,
) ![]contracts.RepeatedProbeAuthority {
    var count: usize = 0;
    for (definitions) |definition| {
        if (definition.condition == .custom_probe) count += 1;
    }
    const probes = try arena.alloc(contracts.RepeatedProbeAuthority, count);
    var index: usize = 0;
    for (definitions) |definition| {
        if (definition.condition != .custom_probe) continue;
        const probe = definition.condition.custom_probe;
        probes[index] = .{
            .command = probe.command,
            .cwd = probe.cwd,
            .check_schedule = definition.check_schedule orelse
                return error.MissingCheckSchedule,
            .notify_schedule = definition.notify_schedule,
            .lifetime = definition.lifetime,
        };
        index += 1;
    }
    return probes;
}

fn resultFromCompletion(
    ctx: tool_dispatch.DispatchContext,
    action: contracts.Action,
    session_id: ?[]const u8,
    completion: client.Completion,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (completion.frame) |*frame| {
        return switch (frame.message().payload) {
            .response => |response| projectResult(ctx, response),
            else => structuredFailure(
                ctx,
                action,
                session_id,
                .protocol_incompatible,
                false,
            ),
        };
    }
    return structuredFailure(
        ctx,
        action,
        session_id,
        switch (completion.kind) {
            .cancelled => .cancelled,
            .unavailable => if (completion.is_missing_capability(
                contracts.protocol_capability_complete_process_tree_signals,
            ))
                .unsupported_host
            else
                .protocol_incompatible,
            .disconnected => .session_lost,
            .response => .protocol_incompatible,
        },
        completion.kind == .disconnected,
    );
}

fn stringifyResult(
    alloc: Allocator,
    result: contracts.Result,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(result, .{}, &out.writer) catch
        return error.OutOfMemory;
    const body = try out.toOwnedSlice();
    return switch (result) {
        .success => .{ .success = body },
        .failure => .{ .failure = body },
    };
}

fn projectResult(
    ctx: tool_dispatch.DispatchContext,
    result: contracts.Result,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const projected = terminalActionPresentation(result);
    const tool_result = try stringifyResult(ctx.allocator, result);
    if (projected) |presentation_value| {
        tool_dispatch.reportToolResultMemory(ctx, .{
            .terminal_action_presentation = presentation_value,
        });
    }
    return tool_result;
}

pub fn mapAuthorizedResult(
    alloc: Allocator,
    result: tool_dispatch.DispatchResult,
) Allocator.Error!tool_dispatch.DispatchResult {
    if (result.status != .failure or result.status_detail != null) return result;
    var parsed = std.json.parseFromSlice(
        contracts.Result,
        alloc,
        result.body,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return result,
    };
    defer parsed.deinit();
    const code = switch (parsed.value) {
        .success => return result,
        .failure => |failure| failure.code,
    };
    var mapped = result;
    mapped.status_detail = try alloc.dupe(
        u8,
        terminalFailurePresentation(code).detail(),
    );
    return mapped;
}

fn structuredFailure(
    ctx: tool_dispatch.DispatchContext,
    action: contracts.Action,
    session_id: ?[]const u8,
    code: contracts.StructuredErrorCode,
    retryable: bool,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return projectResult(ctx, .{ .failure = .{
        .action = action,
        .code = code,
        .session_id = session_id,
        .retryable = retryable,
    } });
}

fn terminalActionPresentation(
    result: contracts.Result,
) ?types.TerminalActionPresentation {
    return switch (result) {
        .success => |success| switch (success) {
            .start => |value| .{ .returned = terminalReturnPresentation(value.outcome) },
            .wait => |value| .{ .returned = terminalReturnPresentation(value.outcome) },
            .read, .screen, .write, .monitor, .inspect, .list, .resize, .signal, .close => null,
        },
        .failure => |failure| .{ .failed = terminalFailurePresentation(failure.code) },
    };
}

fn terminalReturnPresentation(
    outcome: contracts.ReturnOutcome,
) types.TerminalReturnPresentation {
    return switch (outcome) {
        .started => .started,
        .condition_met => .condition_met,
        .safety_ceiling => .safety_ceiling,
        .cancelled => .cancelled,
        .exited => |code| .{ .exited = code },
        .signal => |signal| .{ .signal = signal },
    };
}

fn terminalFailurePresentation(
    code: contracts.StructuredErrorCode,
) types.TerminalFailurePresentation {
    return switch (code) {
        .invalid_request => .invalid_request,
        .path_outside_workspace => .path_outside_workspace,
        .unsupported_host => .unsupported_host,
        .shell_unavailable => .shell_unavailable,
        .pty_unavailable => .pty_unavailable,
        .startup_failed => .startup_failed,
        .process_identity_unavailable => .process_identity_unavailable,
        .session_lost => .session_lost,
        .session_not_found => .session_not_found,
        .invalid_lifecycle => .invalid_lifecycle,
        .authority_denied => .authority_denied,
        .authority_retired => .authority_retired,
        .lease_conflict => .lease_conflict,
        .cursor_gap => .cursor_gap,
        .screen_unavailable => .screen_unavailable,
        .monitor_unavailable => .monitor_unavailable,
        .protocol_incompatible => .protocol_incompatible,
        .capacity_exceeded => .capacity_exceeded,
        .cancelled => .cancelled,
    };
}

fn mapErrorCode(err: anyerror) contracts.StructuredErrorCode {
    return switch (err) {
        error.TerminalSessionNotFound,
        error.InvalidSessionId,
        => .session_not_found,
        error.QueueFull, error.CapacityExceeded => .capacity_exceeded,
        error.ProtocolIncompatible => .protocol_incompatible,
        error.AuthorityRevoked,
        error.ActorRoleMismatch,
        error.PrincipalMismatch,
        error.StaleAuthorityGeneration,
        error.InvalidHolderProof,
        error.ControlDenied,
        => .authority_denied,
        error.TerminalAuthorityRetired => .authority_retired,
        error.Cancelled => .cancelled,
        else => .invalid_request,
    };
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    const input = erased.as(OwnedInput).value;
    return switch (input.action) {
        .read, .screen, .list => true,
        .inspect => input.acknowledge_event_id == null,
        else => false,
    };
}

pub fn presentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const action_text = tool_args.optionalStringArg(args, "action") orelse return null;
    const action = std.meta.stringToEnum(Action, action_text) orelse return null;
    return switch (action) {
        .exec => callPresentation("Running", "Ran", .command, "command"),
        .start => blk: {
            const command = tool_args.optionalStringArg(args, "command");
            break :blk callPresentation(
                "Starting",
                "Started",
                if (command != null and command.?.len > 0) .command else .none,
                "interactive shell",
            );
        },
        .read => sessionPresentation("Reading output from", "Read output from"),
        .screen => sessionPresentation("Capturing screen from", "Captured screen from"),
        .write => writePresentation(args),
        .wait => sessionPresentation("Waiting for", "Finished waiting for"),
        .monitor => monitorPresentation(args),
        .inspect => sessionPresentation("Inspecting", "Inspected"),
        .list => callPresentation("Listing", "Listed", .none, "terminal sessions"),
        .resize => sessionPresentation("Resizing", "Resized"),
        .signal => signalPresentation(args),
        .close => closePresentation(args),
    };
}

fn callPresentation(
    active: []const u8,
    completed: []const u8,
    target_kind: tool_dispatch.LabelArgKind,
    target_default: []const u8,
) tool_dispatch.CallPresentation {
    return .{
        .activity_kind = .command,
        .action_label = active,
        .completed_action_label = completed,
        .label_arg_kind = target_kind,
        .label_arg_default = target_default,
    };
}

fn sessionPresentation(
    active: []const u8,
    completed: []const u8,
) tool_dispatch.CallPresentation {
    return callPresentation(
        active,
        completed,
        .session_id,
        "terminal session",
    );
}

fn writePresentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const lease_text = tool_args.optionalStringArg(args, "lease") orelse "use";
    const lease = std.meta.stringToEnum(contracts.WriteLeaseIntent, lease_text) orelse return null;
    return switch (lease) {
        .use => sessionPresentation("Sending input to", "Sent input to"),
        .acquire => sessionPresentation("Acquiring control of", "Acquired control of"),
        .release => sessionPresentation("Releasing control of", "Released control of"),
        .revoke => sessionPresentation("Revoking control of", "Revoked control of"),
    };
}

fn monitorPresentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const monitor_value = args.get("monitor") orelse return null;
    if (monitor_value != .object) return null;
    const kind_text = tool_args.optionalStringArg(monitor_value.object, "kind") orelse return null;
    const kind = std.meta.stringToEnum(MonitorOperationKind, kind_text) orelse return null;
    return switch (kind) {
        .add => sessionPresentation("Adding monitor to", "Added monitor to"),
        .update => sessionPresentation("Updating monitor for", "Updated monitor for"),
        .pause => sessionPresentation("Pausing monitor for", "Paused monitor for"),
        .@"resume" => sessionPresentation("Resuming monitor for", "Resumed monitor for"),
        .remove => sessionPresentation("Removing monitor from", "Removed monitor from"),
    };
}

fn signalPresentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const signal_text = tool_args.optionalStringArg(args, "signal") orelse return null;
    const signal = std.meta.stringToEnum(contracts.Signal, signal_text) orelse return null;
    return switch (signal) {
        .hangup => sessionPresentation("Sending hangup to", "Sent hangup to"),
        .interrupt => sessionPresentation("Sending interrupt to", "Sent interrupt to"),
        .quit => sessionPresentation("Sending quit to", "Sent quit to"),
        .terminate => sessionPresentation("Sending terminate to", "Sent terminate to"),
        .kill => sessionPresentation("Sending kill to", "Sent kill to"),
    };
}

fn closePresentation(args: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    const policy_text = tool_args.optionalStringArg(args, "close_policy") orelse return null;
    const policy = std.meta.stringToEnum(contracts.ClosePolicy, policy_text) orelse return null;
    return switch (policy) {
        .graceful => sessionPresentation("Closing", "Closed"),
        .force => sessionPresentation("Killing", "Killed"),
    };
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}






























