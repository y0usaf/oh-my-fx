const std = @import("std");
const context_contract = @import("../workspace/context_contract.zig");
const io_mod = @import("../shared/io.zig");
const permissions = @import("../permissions/permissions.zig");
const types = @import("../shared/types.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const tool_admission = @import("../tooling/tool_admission.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

/// Owned terminal output produced by a loop-specific classifier. The
/// preparation result takes ownership of `model_output` on success.
pub const CallbackTerminal = struct {
    model_output: []u8,
    status: ToolStatus = .success,
};

pub const ClassifierFn = *const fn (
    ctx: ?*anyopaque,
    alloc: Allocator,
    call: ToolCall,
) anyerror!?CallbackTerminal;

pub const CandidateClassifierFn = *const fn (
    ctx: ?*anyopaque,
    alloc: Allocator,
    call: ToolCall,
) anyerror!bool;

pub const Classifiers = struct {
    ctx: ?*anyopaque = null,
    idempotent: ClassifierFn,
    validation: ClassifierFn,
    availability: ClassifierFn,
    stop_policy: ClassifierFn,
    deferred_dynamic: ?CandidateClassifierFn = null,
};

pub const Config = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    advertised_dynamic_tool_names: []const []const u8 = &.{},
    cancel_flag: ?*std.atomic.Value(bool) = null,
    classifiers: Classifiers,
};

pub const ToolStatus = enum {
    success,
    failure,
};

pub const TerminalKind = enum {
    idempotent_skip,
    validation_failure,
    availability_failure,
    unsupported,
    stop_policy,
    file_mutation_failure,
};

/// A terminal classification made before permission, visible lifecycle, or
/// execution. `model_output == null` for unsupported calls so each live loop
/// can retain its existing exact unsupported-tool wording.
pub const Terminal = struct {
    kind: TerminalKind,
    model_output: ?[]u8 = null,
    status: ToolStatus = .failure,

    pub fn deinit(self: *Terminal, alloc: Allocator) void {
        if (self.model_output) |output| alloc.free(output);
        self.* = undefined;
    }
};

pub const CandidateKind = enum {
    registered,
    advertised_dynamic,
    deferred_dynamic,
    /// Applicability projection could not prove a canonical target, so the
    /// owning loop must preserve the existing permission/dispatch path.
    legacy_target_resolution,
};

/// One genuine execution candidate. Every target path is owned by this value.
pub const Candidate = struct {
    kind: CandidateKind,
    applicable_targets: []context_contract.ApplicableTarget = &.{},

    pub fn deinit(self: *Candidate, alloc: Allocator) void {
        freeApplicableTargets(alloc, self.applicable_targets);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    terminal: Terminal,
    candidate: Candidate,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .terminal => |*terminal| terminal.deinit(alloc),
            .candidate => |*candidate| candidate.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const ReadyCallBatch = struct {
    preparations: []?Result,
    /// Owns only the list storage; target paths remain owned by preparations.
    applicable_targets: std.ArrayList(context_contract.ApplicableTarget) = .empty,

    pub fn init(alloc: Allocator, call_count: usize) Allocator.Error!ReadyCallBatch {
        const preparations = try alloc.alloc(?Result, call_count);
        @memset(preparations, null);
        return .{ .preparations = preparations };
    }

    pub fn deinit(
        self: *ReadyCallBatch,
        storage_alloc: Allocator,
        preparation_alloc: Allocator,
    ) void {
        self.applicable_targets.deinit(preparation_alloc);
        for (self.preparations) |*maybe_preparation| {
            if (maybe_preparation.*) |*preparation| preparation.deinit(preparation_alloc);
        }
        storage_alloc.free(self.preparations);
        self.* = undefined;
    }

    pub fn prepare(
        self: *ReadyCallBatch,
        alloc: Allocator,
        index: usize,
        call: ToolCall,
        config: Config,
    ) !void {
        std.debug.assert(index < self.preparations.len);
        std.debug.assert(self.preparations[index] == null);

        var preparation = try prepareReadyCall(alloc, call, config);
        errdefer preparation.deinit(alloc);
        switch (preparation) {
            .terminal => {},
            .candidate => |candidate| {
                try self.applicable_targets.appendSlice(alloc, candidate.applicable_targets);
            },
        }
        self.preparations[index] = preparation;
    }
};

/// Classifies one effective `.ready` lifecycle call without permission,
/// presentation, execution, or product-state mutation.
pub fn prepareReadyCall(alloc: Allocator, call: ToolCall, config: Config) !Result {
    if (call.provenance == .provider_executed or call.argument_integrity == .malformed_json) {
        return error.NotLifecycleReady;
    }
    try checkCancellation(config.cancel_flag);

    const tool = config.tool_registry.lookup(call.name) orelse {
        if (isAdvertisedDynamic(config.advertised_dynamic_tool_names, call.name)) {
            if (try classifyWithCallback(
                alloc,
                config.cancel_flag,
                config.classifiers,
                config.classifiers.validation,
                call,
            )) |terminal| {
                return .{ .terminal = terminalFromCallback(.validation_failure, terminal) };
            }
            if (try classifyWithCallback(
                alloc,
                config.cancel_flag,
                config.classifiers,
                config.classifiers.availability,
                call,
            )) |terminal| {
                return .{ .terminal = terminalFromCallback(.availability_failure, terminal) };
            }
            if (try classifyWithCallback(
                alloc,
                config.cancel_flag,
                config.classifiers,
                config.classifiers.stop_policy,
                call,
            )) |terminal| {
                return .{ .terminal = terminalFromCallback(.stop_policy, terminal) };
            }
            return .{ .candidate = .{ .kind = .advertised_dynamic } };
        }
        if (config.classifiers.deferred_dynamic) |classify| {
            if (try classify(config.classifiers.ctx, alloc, call)) {
                return .{ .candidate = .{ .kind = .deferred_dynamic } };
            }
        }
        return .{ .terminal = .{ .kind = .unsupported } };
    };

    if (try classifyWithCallback(
        alloc,
        config.cancel_flag,
        config.classifiers,
        config.classifiers.idempotent,
        call,
    )) |terminal| {
        return .{ .terminal = terminalFromCallback(.idempotent_skip, terminal) };
    }

    if (try classifyWithCallback(
        alloc,
        config.cancel_flag,
        config.classifiers,
        config.classifiers.validation,
        call,
    )) |terminal| {
        return .{ .terminal = terminalFromCallback(.validation_failure, terminal) };
    }

    if (try classifyWithCallback(
        alloc,
        config.cancel_flag,
        config.classifiers,
        config.classifiers.availability,
        call,
    )) |terminal| {
        return .{ .terminal = terminalFromCallback(.availability_failure, terminal) };
    }
    if (try classifyWithCallback(
        alloc,
        config.cancel_flag,
        config.classifiers,
        config.classifiers.stop_policy,
        call,
    )) |terminal| {
        return .{ .terminal = terminalFromCallback(.stop_policy, terminal) };
    }

    const targets = if (file_mutation_contract.isToolName(call.name)) blk: {
        var projection = try tool_admission.prepareFileMutationCall(alloc, call, .{
            .tool_registry = config.tool_registry,
            .workspace_root = config.workspace_root,
        });
        switch (projection) {
            .tool_failure => |reason| {
                try checkCancellationWithOutput(alloc, config.cancel_flag, @constCast(reason));
                return .{ .terminal = .{
                    .kind = .file_mutation_failure,
                    .model_output = @constCast(reason),
                } };
            },
            .prepared => |*prepared| {
                defer prepared.deinit(alloc);
                break :blk try dupeSingleApplicableTarget(alloc, prepared.targetPath(), .file);
            },
        }
    } else switch (try prepareRegisteredApplicableTargets(alloc, config.workspace_root, config.access_scope, call, tool.*)) {
        .prepared => |prepared| prepared,
        .legacy_candidate => return .{ .candidate = .{ .kind = .legacy_target_resolution } },
    };
    errdefer freeApplicableTargets(alloc, targets);
    try checkCancellation(config.cancel_flag);

    return .{ .candidate = .{
        .kind = .registered,
        .applicable_targets = targets,
    } };
}

fn classifyWithCallback(
    alloc: Allocator,
    cancel_flag: ?*std.atomic.Value(bool),
    classifiers: Classifiers,
    classifier: ClassifierFn,
    call: ToolCall,
) anyerror!?CallbackTerminal {
    const terminal = try classifier(classifiers.ctx, alloc, call) orelse return null;
    errdefer alloc.free(terminal.model_output);
    try checkCancellation(cancel_flag);
    return terminal;
}

fn terminalFromCallback(kind: TerminalKind, terminal: CallbackTerminal) Terminal {
    return .{
        .kind = kind,
        .model_output = terminal.model_output,
        .status = terminal.status,
    };
}

fn checkCancellation(cancel_flag: ?*std.atomic.Value(bool)) error{Cancelled}!void {
    if (cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }
}

fn checkCancellationWithOutput(
    alloc: Allocator,
    cancel_flag: ?*std.atomic.Value(bool),
    output: []u8,
) error{Cancelled}!void {
    checkCancellation(cancel_flag) catch |err| {
        alloc.free(output);
        return err;
    };
}

fn isAdvertisedDynamic(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

const RegisteredTargetPreparation = union(enum) {
    prepared: []context_contract.ApplicableTarget,
    legacy_candidate,
};

fn prepareRegisteredApplicableTargets(
    alloc: Allocator,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope,
    call: ToolCall,
    tool: tool_dispatch.Tool,
) Allocator.Error!RegisteredTargetPreparation {
    if (try isCapturedCommandCall(alloc, call, tool)) {
        const command_cwd = permissions.resolveCommandCwdForCallInScope(
            alloc,
            access_scope orelse workspace_access.AccessScope.primaryOnly(workspace_root),
            call,
        ) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => .legacy_candidate,
            };
        };
        defer alloc.free(@constCast(command_cwd));
        return .{ .prepared = try dupeSingleApplicableTarget(
            alloc,
            command_cwd,
            .directory,
        ) };
    }

    var permission_targets = permissions.permissionTargetsForCallInScope(
        alloc,
        access_scope orelse workspace_access.AccessScope.primaryOnly(workspace_root),
        call,
        tool.permission_target_kind,
    ) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => .legacy_candidate,
        };
    };
    defer permission_targets.deinit(alloc);

    const target_kind = filesystemTargetKind(tool.executor_kind);
    const applicable_targets: []context_contract.ApplicableTarget = if (target_kind) |kind|
        try applicableTargetsFromPermissionTargets(alloc, permission_targets.items, kind)
    else
        @constCast(&.{});

    return .{ .prepared = applicable_targets };
}

fn isCapturedCommandCall(
    alloc: Allocator,
    call: ToolCall,
    tool: tool_dispatch.Tool,
) Allocator.Error!bool {
    if (tool.executor_kind == .run_command) return true;
    const expected_action = tool.captured_command_action orelse return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const action = parsed.value.object.get("action") orelse return false;
    return action == .string and std.mem.eql(u8, action.string, expected_action);
}

/// Reprojects a prepared registered ordinary candidate immediately before its
/// permission boundary. A mismatch means the scope used for project context is
/// no longer the scope the raw permission/dispatch path would observe.
pub fn ordinaryApplicableTargetsFresh(
    alloc: Allocator,
    call: ToolCall,
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    candidate: *const Candidate,
) Allocator.Error!bool {
    return ordinaryApplicableTargetsFreshInScope(
        alloc,
        call,
        tool_registry,
        workspace_root,
        null,
        candidate,
    );
}

pub fn ordinaryApplicableTargetsFreshInScope(
    alloc: Allocator,
    call: ToolCall,
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope,
    candidate: *const Candidate,
) Allocator.Error!bool {
    switch (candidate.kind) {
        .advertised_dynamic, .deferred_dynamic => return true,
        .registered => if (candidate.applicable_targets.len == 0) return true,
        .legacy_target_resolution => {},
    }
    const tool = tool_registry.lookup(call.name) orelse return false;

    const current_preparation = try prepareRegisteredApplicableTargets(
        alloc,
        workspace_root,
        access_scope,
        call,
        tool.*,
    );
    const current = switch (current_preparation) {
        .legacy_candidate => return candidate.kind == .legacy_target_resolution,
        .prepared => |targets| targets,
    };
    defer freeApplicableTargets(alloc, current);
    if (candidate.kind == .legacy_target_resolution) return current.len == 0;
    return applicableTargetsEqual(candidate.applicable_targets, current);
}

fn applicableTargetsEqual(
    expected: []const context_contract.ApplicableTarget,
    current: []const context_contract.ApplicableTarget,
) bool {
    if (expected.len != current.len) return false;
    for (expected, current) |left, right| {
        if (left.kind != right.kind or !std.mem.eql(u8, left.path, right.path)) {
            return false;
        }
    }
    return true;
}

fn applicableTargetsFromPermissionTargets(
    alloc: Allocator,
    permission_targets: []const permissions.PermissionCallTarget,
    kind: context_contract.TargetKind,
) Allocator.Error![]context_contract.ApplicableTarget {
    const targets = try alloc.alloc(context_contract.ApplicableTarget, permission_targets.len);
    var initialized: usize = 0;
    errdefer {
        for (targets[0..initialized]) |target| alloc.free(@constCast(target.path));
        alloc.free(targets);
    }
    for (permission_targets, targets) |permission_target, *target| {
        target.* = .{
            .path = try alloc.dupe(u8, permission_target.path),
            .kind = kind,
        };
        initialized += 1;
    }
    return targets;
}

fn filesystemTargetKind(kind: tool_dispatch.ExecutorKind) ?context_contract.TargetKind {
    return switch (kind) {
        .glob_files, .grep_files => .directory,
        .read_file => .file,
        else => null,
    };
}

fn dupeSingleApplicableTarget(
    alloc: Allocator,
    path: []const u8,
    kind: context_contract.TargetKind,
) Allocator.Error![]context_contract.ApplicableTarget {
    const targets = try alloc.alloc(context_contract.ApplicableTarget, 1);
    errdefer alloc.free(targets);
    targets[0] = .{
        .path = try alloc.dupe(u8, path),
        .kind = kind,
    };
    return targets;
}

fn freeApplicableTargets(alloc: Allocator, targets: []context_contract.ApplicableTarget) void {
    for (targets) |target| alloc.free(@constCast(target.path));
    if (targets.len > 0) alloc.free(targets);
}

fn testNoClassification(_: ?*anyopaque, _: Allocator, _: ToolCall) anyerror!?CallbackTerminal {
    return null;
}

const test_classifiers: Classifiers = .{
    .idempotent = testNoClassification,
    .validation = testNoClassification,
    .availability = testNoClassification,
    .stop_policy = testNoClassification,
};








fn checkPreparationAllocationFailures(alloc: Allocator, workspace: []const u8) !void {
    const builtin_tools = @import("../../builtins/tools.zig");
    const tools = [_]tool_dispatch.Tool{builtin_tools.write_file};
    var result = try prepareReadyCall(alloc, .{
        .id = "write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"build/new.txt\",\"content\":\"contents\"}",
    }, .{
        .tool_registry = .{ .tools = &tools },
        .workspace_root = workspace,
        .classifiers = test_classifiers,
    });
    defer result.deinit(alloc);
    try std.testing.expect(result == .candidate);
}

