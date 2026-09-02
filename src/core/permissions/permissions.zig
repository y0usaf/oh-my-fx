const std = @import("std");
const command_environment = @import("../execution/command_environment.zig");

const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const text_utils = @import("../shared/text_utils.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const vision_contracts = @import("../agent/runtime/vision_contracts.zig");
const tool_args = @import("../tooling/tool_args.zig");
const output_contracts = @import("../output/output_contracts.zig");
const types = @import("../shared/types.zig");

pub const PermissionMode = types.PermissionMode;
pub const ToolPermissionDecision = types.ToolPermissionDecision;

pub const PermissionCallTarget = struct {
    role: []const u8,
    path: []u8,
};

pub const PermissionCallTargets = struct {
    items: []PermissionCallTarget,

    pub fn deinit(self: *PermissionCallTargets, alloc: std.mem.Allocator) void {
        for (self.items) |target| alloc.free(target.path);
        alloc.free(self.items);
        self.* = .{ .items = &.{} };
    }
};

const ResolvedPermissionCallTarget = struct {
    role: []const u8,
    path: []const u8,
};

pub const PermissionEngine = struct {
    mode: types.PermissionMode = .ask,
    grants: std.ArrayList(types.PermissionGrant) = .empty,
    rules: types.PermissionRuleSet = .{},

    pub fn deinit(self: *PermissionEngine, alloc: std.mem.Allocator) void {
        clearAllowedTools(alloc, &self.grants);
        self.grants.deinit(alloc);
        self.rules.deinit(alloc);
    }

    pub fn clear(self: *PermissionEngine, alloc: std.mem.Allocator) void {
        clearAllowedTools(alloc, &self.grants);
    }

    pub fn isAllowed(self: PermissionEngine, tool_name: []const u8, target_path: []const u8) bool {
        return isToolAllowed(self.grants.items, tool_name, target_path);
    }

    pub fn allow(self: *PermissionEngine, alloc: std.mem.Allocator, tool_name: []const u8, target_path: []const u8) !void {
        try allowToolForSession(alloc, &self.grants, tool_name, target_path);
    }

    pub fn replaceRules(self: *PermissionEngine, alloc: std.mem.Allocator, next_rules: types.PermissionRuleSet) void {
        self.rules.deinit(alloc);
        self.rules = next_rules;
    }

    pub fn configuredRuleDecision(self: PermissionEngine, alloc: std.mem.Allocator, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) !RuleDecision {
        return ruleDecisionFor(alloc, self.rules, workspace_root, tool_name, target_path, target_kind);
    }

    pub fn formatPermissionsText(self: PermissionEngine, alloc: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
        return formatPermissionsStatus(alloc, workspace_root, self.mode, self.grants.items, self.rules);
    }

    pub fn formatPermissionsNoticeBody(self: PermissionEngine, alloc: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
        return (output_contracts.PermissionsSnapshot{
            .workspace_root = workspace_root,
            .mode = self.mode,
            .grants = self.grants.items,
            .rules = self.rules,
        }).renderInteractiveBody(alloc);
    }
};

pub const RuleDecision = types.RuleDecision;

pub const PermissionTargetKind = enum {
    none,
    path_existing,
    path_optional_existing,
    path_create_parent,
    path_existing_parent,
    command_cwd,
    url,
};

pub const web_search_permission = "web_search";
pub const web_fetch_permission = "web_fetch";
pub const yolo_warning_text = "YOLO enabled: fx permission checks disabled";

pub fn isWebSearchToolName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, web_search_permission);
}

pub fn isWebFetchToolName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, web_fetch_permission);
}

pub fn permissionModeLabel(mode: PermissionMode) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .auto => "auto",
        .yolo => "yolo",
    };
}

pub fn permissionDecisionFromIndex(index: u8) ToolPermissionDecision {
    return switch (index) {
        0 => .once,
        1 => .always,
        else => .deny,
    };
}

pub fn clearAllowedTools(alloc: std.mem.Allocator, grants: *std.ArrayList(types.PermissionGrant)) void {
    for (grants.items) |grant| {
        alloc.free(grant.tool_name);
        alloc.free(grant.target_path);
    }
    grants.clearRetainingCapacity();
}

pub fn isToolAllowed(grants: []const types.PermissionGrant, tool_name: []const u8, target_path: []const u8) bool {
    for (grants) |entry| {
        if (std.mem.eql(u8, entry.tool_name, tool_name) and std.mem.eql(u8, entry.target_path, target_path)) {
            return true;
        }
    }
    return false;
}

pub fn allowToolForSession(
    alloc: std.mem.Allocator,
    grants: *std.ArrayList(types.PermissionGrant),
    permission_name: []const u8,
    pattern: []const u8,
) !void {
    if (isToolAllowed(grants.items, permission_name, pattern)) return;
    try appendOwnedGrant(alloc, grants, permission_name, pattern);
}

pub fn permissionTargetForCall(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) ![]const u8 {
    if (isTypedFileMutationTool(call.name)) {
        return error.TypedFileMutationTargetRequired;
    }

    if (std.mem.eql(u8, call.name, "install_skill")) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        const source = try tool_args.requiredStringArg(args, "source");
        if (tool_args.optionalStringArg(args, "skill")) |skill| {
            return std.fmt.allocPrint(arena, "{s}#{s}", .{ source, skill });
        }
        return arena.dupe(u8, source);
    }

    if (std.mem.eql(u8, call.name, "skill")) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        return arena.dupe(u8, try tool_args.requiredStringArg(args, "name"));
    }

    if (isWebSearchToolName(call.name)) {
        return arena.dupe(u8, web_search_permission);
    }

    if (isWebFetchToolName(call.name)) {
        const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
        return webFetchDomainTargetForUrl(arena, try tool_args.requiredStringArg(args, "url"));
    }

    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);

    return switch (target_kind) {
        .command_cwd => blk: {
            const command = try tool_args.requiredStringArg(args, "command");
            const cwd = try resolveCommandCwdFromArgs(arena, workspace_root, args);
            break :blk std.fmt.allocPrint(arena, "{s}::{s}", .{ cwd, command });
        },
        .url => arena.dupe(u8, try tool_args.requiredStringArg(args, "url")),
        .path_optional_existing => blk: {
            const path_arg = tool_args.optionalStringArg(args, "path") orelse ".";
            break :blk if (std.mem.eql(u8, path_arg, "."))
                arena.dupe(u8, workspace_root)
            else
                try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
        },
        .path_create_parent => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            const target_path = try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .create);
            break :blk std.fs.path.dirname(target_path) orelse target_path;
        },
        .path_existing_parent => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            const target_path = try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
            break :blk std.fs.path.dirname(target_path) orelse target_path;
        },
        .path_existing => blk: {
            const path_arg = try tool_args.requiredStringArg(args, "path");
            break :blk try resolveFileToolPath(arena, workspace_root, call.name, path_arg, .existing);
        },
        .none => try arena.dupe(u8, call.name),
    };
}

pub fn resolveCommandCwdForCallInScope(
    alloc: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const args = try tool_args.parseToolArgsObject(scratch, call.arguments_json);
    const cwd = try resolveCommandCwdFromArgsInScope(scratch, scope, args);
    return alloc.dupe(u8, cwd);
}

fn resolveCommandCwdFromArgs(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    args: std.json.ObjectMap,
) ![]const u8 {
    const cwd_input = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
    if (std.mem.eql(u8, cwd_input, ".")) return arena.dupe(u8, workspace_root);
    return pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, cwd_input);
}

fn resolveCommandCwdFromArgsInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    args: std.json.ObjectMap,
) ![]const u8 {
    const cwd_input = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
    if (std.mem.eql(u8, cwd_input, ".")) return arena.dupe(u8, scope.primary_directory);
    return pathing.resolveWorkspaceOrExternalPath(arena, scope.primary_directory, cwd_input);
}

pub fn permissionTargetsForCall(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) !PermissionCallTargets {
    if (isTypedFileMutationTool(call.name)) {
        return error.TypedFileMutationTargetRequired;
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    if (std.mem.eql(u8, call.name, "vision")) {
        const request = vision_contracts.parse_vision_request(
            scratch,
            call.arguments_json,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolArguments,
        };
        defer request.deinit(scratch);
        if (request.paths()) |paths| {
            const targets = try scratch.alloc(ResolvedPermissionCallTarget, paths.len);
            for (paths, 0..) |path, index| {
                const resolved = try pathing.resolveWorkspaceOrExternalPath(
                    scratch,
                    workspace_root,
                    path,
                );
                for (targets[0..index]) |previous| {
                    if (std.mem.eql(u8, previous.path, resolved)) {
                        return error.InvalidToolArguments;
                    }
                }
                targets[index] = .{ .role = "image", .path = resolved };
            }
            return ownedPermissionCallTargets(alloc, targets);
        }
    }

    const target = try permissionTargetForCall(scratch, workspace_root, call, target_kind);
    return ownedPermissionCallTargets(alloc, &.{.{ .role = "target", .path = target }});
}

pub fn permissionTargetsForCallInScope(
    alloc: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) !PermissionCallTargets {
    if (target_kind != .command_cwd) {
        return permissionTargetsForCall(alloc, scope.primary_directory, call, target_kind);
    }
    const target = try permissionTargetForCallInScope(alloc, scope, call, target_kind);
    defer alloc.free(@constCast(target));
    return ownedPermissionCallTargets(alloc, &.{.{ .role = "target", .path = target }});
}

pub fn permissionTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
    target_kind: PermissionTargetKind,
) ![]const u8 {
    if (target_kind != .command_cwd) {
        return permissionTargetForCall(arena, scope.primary_directory, call, target_kind);
    }
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const command = try tool_args.requiredStringArg(args, "command");
    const cwd = try resolveCommandCwdFromArgsInScope(arena, scope, args);
    return std.fmt.allocPrint(arena, "{s}::{s}", .{ cwd, command });
}

/// Resolves the canonical requested path without requiring it to exist.
/// Callers must first establish that the tool's ordinary target contract is
/// an existing `path` argument.
pub fn missingPathTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const path_arg = try tool_args.requiredStringArg(args, "path");
    return resolveFileToolPath(
        arena,
        scope.primary_directory,
        call.name,
        path_arg,
        .create,
    );
}

/// Returns a normalized scope-checked identity for an existing-path request
/// whose filesystem lookup failed before the tool could report that failure.
/// This does not establish that the path exists or authorize execution.
pub fn unresolvedPathTargetForCallInScope(
    arena: std.mem.Allocator,
    scope: workspace_access.AccessScope,
    call: types.ToolCall,
) ![]const u8 {
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const raw = std.mem.trim(
        u8,
        try tool_args.requiredStringArg(args, "path"),
        " \t\r\n",
    );
    if (raw.len == 0 or raw.len > std.fs.max_path_bytes or
        !std.unicode.utf8ValidateSlice(raw) or
        std.mem.findScalar(u8, raw, 0) != null or
        std.mem.startsWith(u8, raw, "~"))
    {
        return error.InvalidPath;
    }
    const resolved = if (std.fs.path.isAbsolute(raw))
        try std.fs.path.resolve(arena, &.{raw})
    else
        try std.fs.path.resolve(arena, &.{ scope.primary_directory, raw });
    if (!scope.contains(resolved)) return error.PathOutsideWorkspace;
    return resolved;
}

fn isTypedFileMutationTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file");
}

const FileTargetEvaluationError = error{
    OutOfMemory,
    Canceled,
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

const FileTargetResolverError = @typeInfo(@typeInfo(@TypeOf(pathing.resolveFileMutationTargetBounded)).@"fn".return_type.?).error_union.error_set;

const FileTargetDraft = struct {
    kind: file_mutation_contract.PermissionTargetKind,
    disposition: file_mutation_contract.FileTargetDisposition,
    path_end: usize,
    expected_identity: ?file_mutation_contract.FileIdentity,
    rule: types.RuleDecision = .none,
    session_grant_allowed: bool = false,
};

const FileTargetWalk = struct {
    anchor_identity: file_mutation_contract.FileIdentity,
    target_identity: ?file_mutation_contract.FileIdentity,
};

const FileTargetWalkResult = union(enum) {
    failure: file_mutation_contract.FileTargetResolutionFailure,
    ok: FileTargetWalk,
};

const FileTargetPolicyDecision = union(enum) {
    denied_target_index: usize,
    prompt_required: bool,
};

pub fn prepareFileMutationTargets(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    input: file_mutation_contract.FileMutationInput,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPreparationResult {
    const mode: types.ResolveMode = switch (input) {
        .write => .create,
        .edit => .existing,
    };

    var primary_path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var secondary_path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var bounded_component_scratch: [file_mutation_contract.max_file_target_components]pathing.BoundedFileTargetComponent = undefined;
    const bounded = pathing.resolveFileMutationTargetBounded(
        workspace_root,
        input.path(),
        mode,
        &primary_path_scratch,
        &secondary_path_scratch,
        &bounded_component_scratch,
    ) catch |err| {
        const failure = normalizeFileTargetResolverError(err) catch |operational| return operational;
        return .{ .target_resolution_failure = failure };
    };

    if (!boundedResolutionValid(bounded)) {
        return .{ .target_resolution_failure = .invalid_path };
    }

    const component_count = bounded.relative_components.len;
    const traversal_count = component_count - 1;
    const worst_case_item_count = @max(component_count, 2);
    const proof_charge = file_mutation_contract.proofCharge(
        bounded.canonical_target_path.len,
        component_count,
        traversal_count,
        worst_case_item_count,
    ) orelse return .{ .target_resolution_failure = .policy_proof_too_large };
    if (proof_charge > file_mutation_contract.max_file_target_proof_bytes) {
        return .{ .target_resolution_failure = .policy_proof_too_large };
    }

    var traversal_scratch: [file_mutation_contract.max_file_target_components]file_mutation_contract.TraversalDirectory = undefined;
    const traversal = traversal_scratch[0..traversal_count];
    const walk = switch (try walkFileTargetDirectories(bounded, mode, traversal)) {
        .failure => |failure| return .{ .target_resolution_failure = failure },
        .ok => |value| value,
    };

    var draft_scratch: [file_mutation_contract.max_file_target_components + 1]FileTargetDraft = undefined;
    const item_count = assembleFileTargetDrafts(bounded, walk, traversal, &draft_scratch);
    const drafts = draft_scratch[0..item_count];

    return .{ .prepared = try ownedResolvedFileTargets(
        alloc,
        bounded,
        walk.anchor_identity,
        traversal,
        drafts,
    ) };
}

pub fn evaluatePreparedFileMutationTargets(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    kind: file_mutation_contract.Kind,
    prepared: *file_mutation_contract.ResolvedFileMutationTargets,
    permission_mode: types.PermissionMode,
    rules: types.PermissionRuleSet,
    session_grants: []const types.PermissionGrant,
    local_grants: []const types.PermissionGrant,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPolicyResult {
    return evaluatePreparedFileMutationTargetsInScope(
        alloc,
        workspace_access.AccessScope.primaryOnly(workspace_root),
        kind,
        prepared,
        permission_mode,
        rules,
        session_grants,
        local_grants,
    );
}

pub fn evaluatePreparedFileMutationTargetsInScope(
    alloc: std.mem.Allocator,
    access_scope: workspace_access.AccessScope,
    kind: file_mutation_contract.Kind,
    prepared: *file_mutation_contract.ResolvedFileMutationTargets,
    _: types.PermissionMode,
    rules: types.PermissionRuleSet,
    session_grants: []const types.PermissionGrant,
    local_grants: []const types.PermissionGrant,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPolicyResult {
    const workspace_root = access_scope.primary_directory;
    var resolved = prepared.*;
    prepared.relinquish();
    defer resolved.deinit(alloc);
    if (!resolved.proofValid()) {
        return .{ .target_resolution_failure = .invalid_path };
    }

    var draft_scratch: [file_mutation_contract.max_file_target_components + 1]FileTargetDraft = undefined;
    const drafts = draft_scratch[0..resolved.items.len];
    for (resolved.items, drafts) |item, *draft| {
        draft.* = .{
            .kind = item.kind,
            .disposition = item.disposition,
            .path_end = item.path_end,
            .expected_identity = item.expected_identity,
        };
    }

    const tool_name = switch (kind) {
        .write => "write_file",
        .edit => "edit_file",
    };
    const prompt_required = switch (decideFileTargetPolicy(
        resolved.canonical_target_path,
        workspace_root,
        tool_name,
        rules,
        session_grants,
        local_grants,
        drafts,
    )) {
        .denied_target_index => |target_index| return .{ .policy_denied = .{ .target_index = target_index } },
        .prompt_required => |prompt| prompt,
    };

    const evaluated = try policyEvaluatedTargetsFromResolved(
        alloc,
        &resolved,
        drafts,
        prompt_required,
    );
    return .{ .evaluated = evaluated };
}

/// Consumes a structurally validated target proof and projects policy-neutral
/// execution targets for YOLO admission.
pub fn authorizePreparedFileMutationTargets(
    alloc: std.mem.Allocator,
    prepared: *file_mutation_contract.ResolvedFileMutationTargets,
) error{OutOfMemory}!file_mutation_contract.FileTargetPolicyResult {
    var resolved = prepared.*;
    prepared.relinquish();
    defer resolved.deinit(alloc);
    if (!resolved.proofValid()) {
        return .{ .target_resolution_failure = .invalid_path };
    }

    var draft_scratch: [file_mutation_contract.max_file_target_components + 1]FileTargetDraft = undefined;
    const drafts = draft_scratch[0..resolved.items.len];
    for (resolved.items, drafts) |item, *draft| {
        draft.* = .{
            .kind = item.kind,
            .disposition = item.disposition,
            .path_end = item.path_end,
            .expected_identity = item.expected_identity,
            .rule = .allow,
        };
    }

    return .{ .evaluated = try policyEvaluatedTargetsFromResolved(
        alloc,
        &resolved,
        drafts,
        false,
    ) };
}

pub fn evaluateFileMutationTargets(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    input: file_mutation_contract.FileMutationInput,
    permission_mode: types.PermissionMode,
    rules: types.PermissionRuleSet,
    session_grants: []const types.PermissionGrant,
    local_grants: []const types.PermissionGrant,
) FileTargetEvaluationError!file_mutation_contract.FileTargetPolicyResult {
    var prepared = switch (try prepareFileMutationTargets(
        alloc,
        workspace_root,
        input,
    )) {
        .target_resolution_failure => |failure| return .{ .target_resolution_failure = failure },
        .prepared => |value| value,
    };
    return evaluatePreparedFileMutationTargets(
        alloc,
        workspace_root,
        std.meta.activeTag(input),
        &prepared,
        permission_mode,
        rules,
        session_grants,
        local_grants,
    );
}

fn walkFileTargetDirectories(
    bounded: pathing.BoundedFileTargetResolution,
    mode: types.ResolveMode,
    traversal: []file_mutation_contract.TraversalDirectory,
) FileTargetEvaluationError!FileTargetWalkResult {
    const zio = io_mod.getIo();
    var current_dir = std.Io.Dir.openDirAbsolute(
        zio,
        bounded.canonical_target_path[0..bounded.anchor_path_end],
        .{ .follow_symlinks = false },
    ) catch |err| {
        const failure = normalizeDirOpenError(err) catch |operational| return operational;
        return .{ .failure = failure };
    };
    defer current_dir.close(zio);

    const anchor_stat = current_dir.statFile(zio, ".", .{ .follow_symlinks = false }) catch |err| {
        const failure = normalizeStatFileError(err) catch |operational| return operational;
        return .{ .failure = failure };
    };
    if (anchor_stat.kind != .directory) {
        return .{ .failure = .not_directory };
    }
    const anchor_identity = pathing.fileIdentity(
        try pathing.descriptorDevice(current_dir.handle),
        anchor_stat,
    );

    var missing_parent_seen = false;
    for (bounded.relative_components[0..traversal.len], 0..) |component, component_index| {
        const path_end = component.end;
        if (missing_parent_seen) {
            traversal[component_index] = .{
                .component_index = component_index,
                .path_end = path_end,
                .state = .{ .create = .{ .permission_target_index = undefined } },
            };
            continue;
        }

        const component_name = bounded.canonical_target_path[component.start..component.end];
        const next_dir = current_dir.openDir(zio, component_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                if (mode == .existing) {
                    return .{ .failure = .file_not_found };
                }
                missing_parent_seen = true;
                traversal[component_index] = .{
                    .component_index = component_index,
                    .path_end = path_end,
                    .state = .{ .create = .{ .permission_target_index = undefined } },
                };
                continue;
            },
            else => {
                const failure = normalizeDirOpenError(err) catch |operational| return operational;
                return .{ .failure = failure };
            },
        };

        const child_stat = next_dir.statFile(zio, ".", .{ .follow_symlinks = false }) catch |err| {
            next_dir.close(zio);
            const failure = normalizeStatFileError(err) catch |operational| return operational;
            return .{ .failure = failure };
        };
        if (child_stat.kind != .directory) {
            next_dir.close(zio);
            return .{ .failure = .not_directory };
        }
        const child_device = pathing.descriptorDevice(next_dir.handle) catch |err| {
            next_dir.close(zio);
            return err;
        };
        const child_identity = pathing.fileIdentity(child_device, child_stat);
        traversal[component_index] = .{
            .component_index = component_index,
            .path_end = path_end,
            .state = .{ .existing = child_identity },
        };

        current_dir.close(zio);
        current_dir = next_dir;
    }

    const target_component = bounded.relative_components[bounded.relative_components.len - 1];
    const target_name = bounded.canonical_target_path[target_component.start..target_component.end];
    var target_identity: ?file_mutation_contract.FileIdentity = null;
    if (!missing_parent_seen) {
        const target_stat = current_dir.statFile(zio, target_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => if (mode == .existing) {
                return .{ .failure = .file_not_found };
            } else null,
            else => {
                const failure = normalizeStatFileError(err) catch |operational| return operational;
                return .{ .failure = failure };
            },
        };
        if (target_stat) |stat| {
            target_identity = pathing.fileIdentity(
                try pathing.directoryEntryDevice(current_dir, target_name),
                stat,
            );
        }
    }

    return .{ .ok = .{
        .anchor_identity = anchor_identity,
        .target_identity = target_identity,
    } };
}

fn assembleFileTargetDrafts(
    bounded: pathing.BoundedFileTargetResolution,
    walk: FileTargetWalk,
    traversal: []file_mutation_contract.TraversalDirectory,
    drafts: []FileTargetDraft,
) usize {
    var item_count: usize = 0;
    drafts[item_count] = .{
        .kind = .target,
        .disposition = .target_entry,
        .path_end = bounded.canonical_target_path.len,
        .expected_identity = walk.target_identity,
    };
    item_count += 1;

    if (traversal.len == 0) {
        drafts[item_count] = .{
            .kind = .parent,
            .disposition = .existing_parent,
            .path_end = bounded.anchor_path_end,
            .expected_identity = walk.anchor_identity,
        };
    } else {
        const parent_index = traversal.len - 1;
        drafts[item_count] = switch (traversal[parent_index].state) {
            .existing => |identity| .{
                .kind = .parent,
                .disposition = .existing_parent,
                .path_end = traversal[parent_index].path_end,
                .expected_identity = identity,
            },
            .create => .{
                .kind = .parent,
                .disposition = .create_parent,
                .path_end = traversal[parent_index].path_end,
                .expected_identity = null,
            },
        };
        switch (traversal[parent_index].state) {
            .existing => {},
            .create => traversal[parent_index].state.create.permission_target_index = item_count,
        }
    }
    item_count += 1;

    var parent_index = if (traversal.len > 1) traversal.len - 1 else 0;
    while (parent_index > 0) {
        parent_index -= 1;
        switch (traversal[parent_index].state) {
            .existing => {},
            .create => {
                traversal[parent_index].state.create.permission_target_index = item_count;
                drafts[item_count] = .{
                    .kind = .parent,
                    .disposition = .create_parent,
                    .path_end = traversal[parent_index].path_end,
                    .expected_identity = null,
                };
                item_count += 1;
            },
        }
    }
    return item_count;
}

fn decideFileTargetPolicy(
    canonical_target_path: []const u8,
    workspace_root: []const u8,
    tool_name: []const u8,
    rules: types.PermissionRuleSet,
    session_grants: []const types.PermissionGrant,
    local_grants: []const types.PermissionGrant,
    drafts: []FileTargetDraft,
) FileTargetPolicyDecision {
    var first_denied_index: ?usize = null;
    for (drafts, 0..) |*draft, index| {
        const target_path = canonical_target_path[0..draft.path_end];
        draft.rule = fileTargetRuleDecision(rules, workspace_root, tool_name, target_path);
        draft.session_grant_allowed =
            sessionGrantAllowed(session_grants, tool_name, target_path) or
            sessionGrantAllowed(local_grants, tool_name, target_path);
        if (draft.rule == .deny and first_denied_index == null) {
            first_denied_index = index;
        }
    }
    if (first_denied_index) |target_index| {
        return .{ .denied_target_index = target_index };
    }

    var prompt_required = false;
    for (drafts) |draft| {
        if (draft.session_grant_allowed) continue;
        switch (draft.rule) {
            .allow => {},
            .ask => prompt_required = true,
            .none => prompt_required = true,
            .deny => unreachable,
        }
    }
    return .{ .prompt_required = prompt_required };
}

fn ownedResolvedFileTargets(
    alloc: std.mem.Allocator,
    bounded: pathing.BoundedFileTargetResolution,
    anchor_identity: file_mutation_contract.FileIdentity,
    traversal: []const file_mutation_contract.TraversalDirectory,
    drafts: []const FileTargetDraft,
) error{OutOfMemory}!file_mutation_contract.ResolvedFileMutationTargets {
    const canonical_target_path = try alloc.dupe(u8, bounded.canonical_target_path);
    errdefer alloc.free(canonical_target_path);
    const relative_components = try alloc.alloc(file_mutation_contract.PathSpan, bounded.relative_components.len);
    errdefer alloc.free(relative_components);
    const traversal_directories = try alloc.alloc(file_mutation_contract.TraversalDirectory, traversal.len);
    errdefer alloc.free(traversal_directories);
    const items = try alloc.alloc(file_mutation_contract.ResolvedPermissionTarget, drafts.len);
    errdefer alloc.free(items);

    for (bounded.relative_components, relative_components) |source, *destination| {
        destination.* = .{ .start = source.start, .end = source.end };
    }
    @memcpy(traversal_directories, traversal);
    for (drafts, items) |draft, *item| {
        item.* = .{
            .kind = draft.kind,
            .disposition = draft.disposition,
            .path_end = draft.path_end,
            .expected_identity = draft.expected_identity,
        };
    }

    return .{
        .canonical_target_path = canonical_target_path,
        .anchor = .{
            .scope = if (bounded.anchor_is_external) .external else .workspace,
            .path_end = bounded.anchor_path_end,
            .identity = anchor_identity,
            .relative_components = relative_components,
        },
        .traversal_directories = traversal_directories,
        .items = items,
    };
}

fn policyEvaluatedTargetsFromResolved(
    alloc: std.mem.Allocator,
    resolved: *file_mutation_contract.ResolvedFileMutationTargets,
    drafts: []const FileTargetDraft,
    prompt_required: bool,
) error{OutOfMemory}!file_mutation_contract.PolicyEvaluatedFileTargets {
    const items = try alloc.alloc(file_mutation_contract.EvaluatedPermissionTarget, drafts.len);
    errdefer alloc.free(items);
    for (drafts, items) |draft, *item| {
        item.* = .{
            .kind = draft.kind,
            .disposition = draft.disposition,
            .path_end = draft.path_end,
            .expected_identity = draft.expected_identity,
            .rule = draft.rule,
            .session_grant_allowed = draft.session_grant_allowed,
        };
    }

    alloc.free(@constCast(resolved.items));
    const evaluated: file_mutation_contract.PolicyEvaluatedFileTargets = .{
        .canonical_target_path = resolved.canonical_target_path,
        .anchor = resolved.anchor,
        .traversal_directories = resolved.traversal_directories,
        .items = items,
        .prompt_required = prompt_required,
    };
    resolved.relinquish();
    return evaluated;
}

fn boundedResolutionValid(resolution: pathing.BoundedFileTargetResolution) bool {
    if (resolution.canonical_target_path.len == 0) return false;
    if (!std.fs.path.isAbsolute(resolution.canonical_target_path)) return false;
    if (resolution.anchor_path_end == 0 or resolution.anchor_path_end > resolution.canonical_target_path.len) return false;
    if (resolution.relative_components.len == 0) return false;
    if (resolution.relative_components.len > file_mutation_contract.max_file_target_components) return false;

    var expected_start = if (resolution.anchor_path_end == 1)
        resolution.anchor_path_end
    else
        resolution.anchor_path_end + 1;
    for (resolution.relative_components) |component| {
        if (component.start != expected_start) return false;
        if (component.end <= component.start or component.end > resolution.canonical_target_path.len) return false;
        expected_start = component.end + 1;
    }
    return resolution.relative_components[resolution.relative_components.len - 1].end == resolution.canonical_target_path.len;
}

fn fileTargetRuleDecision(
    rules: types.PermissionRuleSet,
    workspace_root: []const u8,
    tool_name: []const u8,
    target_path: []const u8,
) types.RuleDecision {
    const pattern = if (pathing.pathInside(workspace_root, target_path))
        workspaceRelativePermissionPath(workspace_root, target_path)
    else
        target_path;
    return evaluateRulesetForTool(rules.rules, permissionNameForTool(tool_name), tool_name, pattern) orelse .none;
}

fn workspaceRelativePermissionPath(workspace_root: []const u8, target_path: []const u8) []const u8 {
    if (std.mem.eql(u8, workspace_root, target_path)) return ".";
    if (std.mem.eql(u8, workspace_root, "/")) return target_path[1..];
    return target_path[workspace_root.len + 1 ..];
}

fn normalizeFileTargetResolverError(err: FileTargetResolverError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.PathOutsideWorkspace => .path_outside_workspace,
        error.FileNotFound => .file_not_found,
        error.HomeNotSet => .home_not_set,
        error.InvalidPath => .invalid_path,
        error.WorkspaceUnavailable => .workspace_unavailable,
        error.TooManyPathComponents => .too_many_path_components,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.NotDir => .not_directory,
        error.SymLinkLoop => .symlink_loop,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.NotLink, error.IsDir, error.PathAlreadyExists => .path_state_changed,
        error.OperationUnsupported, error.UnsupportedReparsePointType => .unsupported_path_operation,
        error.NoDevice,
        error.NetworkNotFound,
        error.UnrecognizedVolume,
        error.InputOutput,
        error.FileSystem,
        error.FileTooBig,
        error.NoSpaceLeft,
        error.ReadOnlyFileSystem,
        error.DeviceBusy,
        error.FileBusy,
        error.PipeBusy,
        error.FileLocksUnsupported,
        error.WouldBlock,
        error.AntivirusInterference,
        error.Streaming,
        => .filesystem_unavailable,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn normalizeDirOpenError(err: std.Io.Dir.OpenError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.FileNotFound => .file_not_found,
        error.NotDir => .not_directory,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.SymLinkLoop => .symlink_loop,
        error.NoDevice, error.NetworkNotFound => .filesystem_unavailable,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn normalizeStatFileError(err: std.Io.Dir.StatFileError) FileTargetEvaluationError!file_mutation_contract.FileTargetResolutionFailure {
    return switch (err) {
        error.FileNotFound => .file_not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.NotDir => .not_directory,
        error.SymLinkLoop => .symlink_loop,
        error.NameTooLong => .name_too_long,
        error.BadPathName => .bad_path_name,
        error.IsDir, error.PathAlreadyExists => .path_state_changed,
        error.PipeBusy,
        error.NoDevice,
        error.NetworkNotFound,
        error.AntivirusInterference,
        error.FileTooBig,
        error.NoSpaceLeft,
        error.ReadOnlyFileSystem,
        error.DeviceBusy,
        error.FileLocksUnsupported,
        error.FileBusy,
        error.WouldBlock,
        error.Streaming,
        => .filesystem_unavailable,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn ownedPermissionCallTargets(
    alloc: std.mem.Allocator,
    source: []const ResolvedPermissionCallTarget,
) !PermissionCallTargets {
    const items = try alloc.alloc(PermissionCallTarget, source.len);
    errdefer alloc.free(items);

    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |target| alloc.free(target.path);
    }

    for (source, 0..) |target, index| {
        items[index] = .{
            .role = target.role,
            .path = try alloc.dupe(u8, target.path),
        };
        initialized += 1;
    }
    return .{ .items = items };
}

pub fn resolveFileToolPath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    tool_name: []const u8,
    path_arg: []const u8,
    mode: types.ResolveMode,
) ![]const u8 {
    if (!allowsExternalPath(tool_name)) {
        return pathing.resolveWorkspacePath(arena, workspace_root, path_arg, mode);
    }

    return switch (mode) {
        .existing => pathing.resolveWorkspaceOrExternalPath(arena, workspace_root, path_arg),
        .create => pathing.resolveWorkspaceOrExternalCreatePath(arena, workspace_root, path_arg),
    };
}

const external_path_tools = [_][]const u8{
    "read_file",
    "glob_files",
    "grep_files",
    "write_file",
    "edit_file",
};

pub fn allowsExternalPath(tool_name: []const u8) bool {
    for (external_path_tools) |eligible| {
        if (std.mem.eql(u8, tool_name, eligible)) return true;
    }
    return false;
}


pub fn isFilesystemMutationTool(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file");
}

pub fn displayTargetForPolicy(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) ![]u8 {
    return switch (target_kind) {
        .command_cwd => displayCommandTarget(alloc, workspace_root, target_path),
        .path_existing, .path_optional_existing, .path_create_parent, .path_existing_parent => displayPathTarget(alloc, workspace_root, target_path),
        else => alloc.dupe(u8, target_path),
    };
}

pub fn ruleDecisionFor(alloc: std.mem.Allocator, rules: types.PermissionRuleSet, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) !RuleDecision {
    const permission = permissionNameForTool(tool_name);
    const pattern = try patternForRuleMatch(alloc, workspace_root, tool_name, target_path, target_kind);
    defer alloc.free(pattern);

    return evaluateRulesetForTool(rules.rules, permission, tool_name, pattern) orelse .none;
}

pub fn ruleDecisionForPermissionPattern(rules: types.PermissionRuleSet, permission: []const u8, pattern: []const u8, fallback: RuleDecision) RuleDecision {
    return evaluateRuleset(rules.rules, permission, pattern) orelse fallback;
}

pub fn rulesDenyAllTargetsForPermission(rules: types.PermissionRuleSet, permission: []const u8) bool {
    return rulesDenyAllTargetsForPermissionAndTool(rules, permission, null);
}

pub fn rulesDenyAllTargetsForTool(rules: types.PermissionRuleSet, tool_name: []const u8) bool {
    if (isWebFetchToolName(tool_name)) return false;
    return rulesDenyAllTargetsForPermissionAndTool(rules, permissionNameForTool(tool_name), tool_name);
}

fn rulesDenyAllTargetsForPermissionAndTool(rules: types.PermissionRuleSet, permission: []const u8, tool_name: ?[]const u8) bool {
    var last_global_deny_index: ?usize = null;
    for (rules.rules, 0..) |rule, index| {
        if (!ruleMatchesPermission(rule.permission, permission, tool_name)) continue;
        if (!isGlobalTargetPattern(rule.pattern)) continue;
        last_global_deny_index = switch (rule.action) {
            .allow, .ask => null,
            .deny => index,
        };
    }

    const deny_index = last_global_deny_index orelse return false;
    for (rules.rules[deny_index + 1 ..]) |rule| {
        if (!ruleMatchesPermission(rule.permission, permission, tool_name)) continue;
        switch (rule.action) {
            .deny => {},
            .allow, .ask => {
                const decision = evaluateRulesetForTool(rules.rules, permission, tool_name, rule.pattern) orelse .none;
                if (decision == .allow or decision == .ask) return false;
            },
        }
    }

    return true;
}

pub fn sessionGrantAllowed(grants: []const types.PermissionGrant, tool_name: []const u8, target_path: []const u8) bool {
    const permission = permissionNameForTool(tool_name);
    const pattern = patternForSessionGrantMatch(tool_name, target_path);

    if (std.mem.eql(u8, permission, web_fetch_permission)) {
        if (!isCanonicalWebFetchDomainPattern(pattern)) return false;
        for (grants) |grant| {
            if (!std.mem.eql(u8, grant.tool_name, web_fetch_permission)) continue;
            if (!isCanonicalWebFetchDomainPattern(grant.target_path)) continue;
            if (std.mem.eql(u8, grant.target_path, pattern)) return true;
        }
        return false;
    }

    for (grants) |grant| {
        if (!permissionPatternMatchesTool(grant.tool_name, permission, tool_name)) continue;
        if (std.mem.eql(u8, permission, "bash")) {
            if (!std.mem.eql(u8, grant.target_path, pattern)) continue;
        } else if (!permissionPatternMatchesTarget(grant.target_path, pattern)) continue;
        return true;
    }
    return false;
}

const path_always_permissions = [_][]const u8{
    "edit",
    "read",
    "glob",
    "grep",
};

pub fn suggestedSessionGrants(alloc: std.mem.Allocator, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) ![]types.PermissionGrant {
    const permission = permissionNameForTool(tool_name);
    var grants: std.ArrayList(types.PermissionGrant) = .empty;
    errdefer {
        clearAllowedTools(alloc, &grants);
        grants.deinit(alloc);
    }

    if (std.mem.eql(u8, permission, "bash")) {
        const command = patternForSessionGrantMatch(tool_name, target_path);

        try appendOwnedGrant(alloc, &grants, "bash", command);
        return grants.toOwnedSlice(alloc);
    }

    if (isPathBasedTool(target_kind) and workspace_root.len > 0 and pathing.pathInside(workspace_root, target_path)) {
        const workspace_pattern = try directoryTreePattern(alloc, workspace_root);
        defer alloc.free(workspace_pattern);

        for (path_always_permissions) |path_permission| {
            try appendOwnedGrant(alloc, &grants, path_permission, workspace_pattern);
        }
        return grants.toOwnedSlice(alloc);
    }

    if (isPathBasedTool(target_kind)) {
        if (externalPathGrantRoot(alloc, workspace_root, target_path)) |external_root| {
            defer alloc.free(external_root);
            const external_pattern = try directoryTreePattern(alloc, external_root);
            defer alloc.free(external_pattern);

            try appendOwnedGrant(alloc, &grants, permission, external_pattern);
            return grants.toOwnedSlice(alloc);
        }
    }

    try appendOwnedGrant(alloc, &grants, permission, patternForSessionGrantMatch(tool_name, target_path));
    return grants.toOwnedSlice(alloc);
}

pub const FileGrantOfferError = error{
    OutOfMemory,
    UnsupportedFileGrantOffer,
    ScopeProjectionTooLarge,
};

pub fn structuredFileGrantOffer(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    tool_name: []const u8,
    targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) FileGrantOfferError!file_mutation_contract.FileGrantOffer {
    if (!file_mutation_contract.isToolName(tool_name)) {
        return error.UnsupportedFileGrantOffer;
    }

    var grants: std.ArrayList(types.PermissionGrant) = .empty;
    errdefer {
        clearAllowedTools(alloc, &grants);
        grants.deinit(alloc);
    }
    for (targets.items) |target| {
        const suggestions = suggestedSessionGrants(
            alloc,
            workspace_root,
            tool_name,
            targets.permissionPath(target),
            .path_existing,
        ) catch return error.OutOfMemory;
        defer types.freePermissionGrantSlice(alloc, suggestions);
        for (suggestions) |grant| {
            if (!isStructuredFilePermission(grant.tool_name)) {
                return error.UnsupportedFileGrantOffer;
            }
            try appendNormalizedFileGrant(
                alloc,
                &grants,
                grant.tool_name,
                grant.target_path,
            );
        }
    }
    if (grants.items.len == 0) return error.UnsupportedFileGrantOffer;

    const scope: file_mutation_contract.FileApprovalScope = switch (targets.anchor.scope) {
        .workspace => blk: {
            const workspace_pattern = directoryTreePattern(
                alloc,
                workspace_root,
            ) catch return error.OutOfMemory;
            defer alloc.free(workspace_pattern);
            _ = literalDirectoryTreeRoot(workspace_pattern) orelse
                return error.UnsupportedFileGrantOffer;
            for (grants.items) |grant| {
                if (!std.mem.eql(u8, grant.target_path, workspace_pattern)) {
                    return error.UnsupportedFileGrantOffer;
                }
            }
            break :blk .workspace_files;
        },
        .external => blk: {
            const first_root = literalDirectoryTreeRoot(
                grants.items[0].target_path,
            ) orelse return error.UnsupportedFileGrantOffer;
            for (grants.items[1..]) |grant| {
                const root = literalDirectoryTreeRoot(grant.target_path) orelse
                    return error.UnsupportedFileGrantOffer;
                if (!std.mem.eql(u8, first_root, root)) {
                    return error.UnsupportedFileGrantOffer;
                }
            }
            const encoded_root = text_utils.encodeTerminalSafePathTail(
                alloc,
                first_root,
                file_mutation_contract.max_external_scope_tail_bytes,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PathBasenameTooLong => return error.ScopeProjectionTooLarge,
            };
            break :blk .{ .external_tree = encoded_root.bytes };
        },
    };
    errdefer switch (scope) {
        .workspace_files => {},
        .external_tree => |root_tail| alloc.free(@constCast(root_tail)),
    };

    return .{
        .grants = try grants.toOwnedSlice(alloc),
        .scope = scope,
    };
}

fn isStructuredFilePermission(permission: []const u8) bool {
    for (path_always_permissions) |candidate| {
        if (std.mem.eql(u8, permission, candidate)) return true;
    }
    return false;
}

fn appendNormalizedFileGrant(
    alloc: std.mem.Allocator,
    grants: *std.ArrayList(types.PermissionGrant),
    permission: []const u8,
    pattern: []const u8,
) error{OutOfMemory}!void {
    var index: usize = 0;
    while (index < grants.items.len) {
        const current = grants.items[index];
        if (!std.mem.eql(u8, current.tool_name, permission)) {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, current.target_path, pattern) or
            directoryTreePatternContains(current.target_path, pattern))
        {
            return;
        }
        if (directoryTreePatternContains(pattern, current.target_path)) {
            const removed = grants.orderedRemove(index);
            alloc.free(removed.tool_name);
            alloc.free(removed.target_path);
            continue;
        }
        index += 1;
    }
    try appendOwnedGrant(alloc, grants, permission, pattern);
}

fn directoryTreePatternContains(
    broader_pattern: []const u8,
    narrower_pattern: []const u8,
) bool {
    const broader_root = directoryTreeRoot(broader_pattern) orelse return false;
    const narrower_root = directoryTreeRoot(narrower_pattern) orelse return false;
    return std.mem.eql(u8, broader_root, narrower_root) or
        pathing.pathInside(broader_root, narrower_root);
}

fn directoryTreeRoot(pattern: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, pattern, "/**")) return null;
    const root = pattern[0 .. pattern.len - "/**".len];
    return if (root.len == 0) "/" else root;
}

fn literalDirectoryTreeRoot(pattern: []const u8) ?[]const u8 {
    const root = directoryTreeRoot(pattern) orelse return null;
    if (std.mem.findScalar(u8, root, '*') != null) return null;
    if (std.mem.findScalar(u8, root, '?') != null) return null;
    return root;
}

fn appendOwnedGrant(
    alloc: std.mem.Allocator,
    grants: *std.ArrayList(types.PermissionGrant),
    permission_name: []const u8,
    pattern: []const u8,
) !void {
    const owned_permission = try alloc.dupe(u8, permission_name);
    errdefer alloc.free(owned_permission);

    const owned_pattern = try alloc.dupe(u8, pattern);
    errdefer alloc.free(owned_pattern);

    try grants.append(alloc, .{
        .tool_name = owned_permission,
        .target_path = owned_pattern,
    });
}

pub fn formatPermissionsStatus(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    mode: types.PermissionMode,
    grants: []const types.PermissionGrant,
    rules: types.PermissionRuleSet,
) ![]u8 {
    return (output_contracts.PermissionsSnapshot{
        .workspace_root = workspace_root,
        .mode = mode,
        .grants = grants,
        .rules = rules,
    }).renderText(alloc);
}

pub fn permissionNameForTool(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "read_file")) return "read";
    if (std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "edit_file")) return "edit";
    if (std.mem.eql(u8, tool_name, "glob_files")) return "glob";
    if (std.mem.eql(u8, tool_name, "grep_files")) return "grep";
    if (std.mem.eql(u8, tool_name, "run_command")) return "bash";
    if (isWebFetchToolName(tool_name)) return web_fetch_permission;
    if (std.mem.eql(u8, tool_name, "skill") or std.mem.eql(u8, tool_name, "install_skill")) return "skill";
    return tool_name;
}

pub fn permissionRuleCategoryForGrant(permission_name: []const u8) ?[]const u8 {
    return permissionNameForTool(permission_name);
}

/// Returns the persistent rule pattern for a session grant. Caller owns the returned slice.
pub fn permissionRulePatternForGrant(alloc: std.mem.Allocator, workspace_root: []const u8, permission_name: []const u8, pattern: []const u8) ![]u8 {
    const permission = permissionNameForTool(permission_name);
    if (isWebSearchToolName(permission)) return alloc.dupe(u8, "*");
    if (std.mem.eql(u8, permission, web_fetch_permission)) return canonicalWebFetchDomainPattern(alloc, pattern);
    if (std.mem.eql(u8, permission, "bash")) {
        if (command_environment.isExplicitPermissionCommandIdentity(pattern)) {
            return alloc.dupe(u8, pattern);
        }
        if (std.mem.find(u8, pattern, "::")) |separator| {
            return alloc.dupe(u8, pattern[separator + 2 ..]);
        }
        return alloc.dupe(u8, pattern);
    }

    if (std.mem.eql(u8, permission, "url") or
        std.mem.eql(u8, permission, "skill"))
    {
        return alloc.dupe(u8, pattern);
    }

    if (std.fs.path.isAbsolute(pattern) and pathing.pathInside(workspace_root, pattern)) {
        if (directoryTreePatternMatches(pattern, workspace_root)) return alloc.dupe(u8, "*");

        const relative = std.fs.path.relative(alloc, "/", null, workspace_root, pattern) catch return alloc.dupe(u8, pattern);
        if (relative.len == 0) {
            alloc.free(relative);
            return alloc.dupe(u8, "*");
        }
        return relative;
    }

    return alloc.dupe(u8, pattern);
}

fn patternForRuleMatch(alloc: std.mem.Allocator, workspace_root: []const u8, tool_name: []const u8, target_path: []const u8, target_kind: PermissionTargetKind) ![]u8 {
    const permission = permissionNameForTool(tool_name);
    if (std.mem.eql(u8, permission, web_fetch_permission)) {
        return alloc.dupe(u8, target_path);
    }
    if (std.mem.eql(u8, permission, "bash")) {
        const identity = if (command_environment.isExplicitPermissionCommandIdentity(target_path))
            target_path
        else if (std.mem.find(u8, target_path, "::")) |separator|
            target_path[separator + 2 ..]
        else
            target_path;
        return alloc.dupe(u8, command_environment.commandFromPermissionIdentity(identity));
    }
    return displayTargetForPolicy(alloc, workspace_root, target_path, target_kind);
}

pub fn patternForSessionGrantMatch(tool_name: []const u8, target_path: []const u8) []const u8 {
    const permission = permissionNameForTool(tool_name);
    if (std.mem.eql(u8, permission, "bash")) {
        if (command_environment.isExplicitPermissionCommandIdentity(target_path)) {
            return target_path;
        }
        if (std.mem.find(u8, target_path, "::")) |separator| return target_path[separator + 2 ..];
    }
    return target_path;
}

fn isPathBasedTool(target_kind: PermissionTargetKind) bool {
    return switch (target_kind) {
        .path_existing, .path_optional_existing, .path_create_parent, .path_existing_parent => true,
        else => false,
    };
}

fn externalPathGrantRoot(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8) ?[]u8 {
    if (!std.fs.path.isAbsolute(target_path)) return null;
    if (workspace_root.len > 0 and pathing.pathInside(workspace_root, target_path)) return null;

    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), target_path, .{}) catch null;
    if (stat) |s| {
        if (s.kind == .directory) return alloc.dupe(u8, target_path) catch null;
    }

    const parent = std.fs.path.dirname(target_path) orelse return null;
    return alloc.dupe(u8, parent) catch null;
}

fn directoryTreePattern(alloc: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, dir_path, "/")) return std.fmt.allocPrint(alloc, "{s}**", .{dir_path});
    return std.fmt.allocPrint(alloc, "{s}/**", .{dir_path});
}

fn evaluateRuleset(rules: []const types.PermissionRule, permission: []const u8, pattern: []const u8) ?RuleDecision {
    return evaluateRulesetForTool(rules, permission, null, pattern);
}

fn evaluateRulesetForTool(rules: []const types.PermissionRule, permission: []const u8, tool_name: ?[]const u8, pattern: []const u8) ?RuleDecision {
    if (std.mem.eql(u8, permission, web_fetch_permission)) {
        return evaluateWebFetchRuleset(rules, pattern);
    }

    var matched: ?RuleDecision = null;
    for (rules) |rule| {
        if (!ruleMatchesPermission(rule.permission, permission, tool_name)) continue;
        const action: RuleDecision = switch (rule.action) {
            .allow => .allow,
            .ask => .ask,
            .deny => .deny,
        };
        if (!ruleTargetMatches(permission, action, rule.pattern, pattern)) continue;
        matched = action;
    }
    return matched;
}

fn evaluateWebFetchRuleset(rules: []const types.PermissionRule, pattern: []const u8) ?RuleDecision {
    if (!isCanonicalWebFetchDomainPattern(pattern)) return null;

    var matched: ?RuleDecision = null;
    for (rules) |rule| {
        if (!std.mem.eql(u8, rule.permission, web_fetch_permission)) continue;
        if (!isCanonicalWebFetchDomainPattern(rule.pattern)) continue;
        if (!std.mem.eql(u8, rule.pattern, pattern)) continue;
        matched = switch (rule.action) {
            .allow => .allow,
            .ask => .ask,
            .deny => .deny,
        };
    }
    return matched;
}

pub fn webFetchRuleWarningCount(rules: []const types.PermissionRule) usize {
    var count: usize = 0;
    for (rules) |rule| {
        if (!std.mem.eql(u8, rule.permission, web_fetch_permission)) continue;
        if (isCanonicalWebFetchDomainPattern(rule.pattern)) continue;
        count += 1;
    }
    return count;
}

fn ruleMatchesPermission(rule_permission: []const u8, permission: []const u8, tool_name: ?[]const u8) bool {
    if (wildcardMatch(rule_permission, permission)) return true;
    const name = tool_name orelse return false;
    if (wildcardMatch(rule_permission, name)) return true;
    return false;
}

fn permissionPatternMatchesTool(pattern: []const u8, permission: []const u8, tool_name: ?[]const u8) bool {
    return ruleMatchesPermission(pattern, permission, tool_name);
}

fn permissionPatternMatchesTarget(pattern: []const u8, candidate: []const u8) bool {
    if (directoryTreePatternMatches(pattern, candidate)) return true;
    return wildcardMatch(pattern, candidate);
}

fn ruleTargetMatches(permission: []const u8, action: RuleDecision, pattern: []const u8, candidate: []const u8) bool {
    if (action != .allow or
        !std.mem.eql(u8, permission, "bash"))
    {
        return permissionPatternMatchesTarget(pattern, candidate);
    }

    if (!containsWildcard(pattern)) return std.mem.eql(u8, pattern, candidate);
    if (!isStaticCommand(pattern, true) or !isStaticCommand(candidate, false)) return false;
    return staticCommandWildcardMatch(pattern, candidate);
}

fn containsWildcard(pattern: []const u8) bool {
    return std.mem.findScalar(u8, pattern, '*') != null or
        std.mem.findScalar(u8, pattern, '?') != null;
}

fn isStaticCommand(command: []const u8, allow_wildcards: bool) bool {
    if (command.len == 0) return false;
    if (firstWordIsAssignment(command)) return false;

    var index: usize = 0;
    var in_word = false;
    while (index < command.len) {
        const char = command[index];
        if (char == ' ' or char == '\t') {
            if (!in_word) return false;
            while (index < command.len and (command[index] == ' ' or command[index] == '\t')) : (index += 1) {}
            if (index == command.len) return false;
            in_word = false;
            continue;
        }

        if (char == '\'') {
            const literal_start = index + 1;
            const literal_end = std.mem.findScalarPos(u8, command, literal_start, '\'') orelse return false;
            const literal = command[literal_start..literal_end];
            if (!std.unicode.utf8ValidateSlice(literal)) return false;
            if (std.mem.findScalar(u8, literal, 0) != null or
                std.mem.findScalar(u8, literal, '\r') != null or
                std.mem.findScalar(u8, literal, '\n') != null)
            {
                return false;
            }
            in_word = true;
            index = literal_end + 1;
            continue;
        }

        if (!isStaticUnquotedByte(char) and !(allow_wildcards and (char == '*' or char == '?'))) return false;
        in_word = true;
        index += 1;
    }
    return in_word;
}

fn firstWordIsAssignment(command: []const u8) bool {
    const first_word_end = std.mem.findAny(u8, command, " \t") orelse command.len;
    const first_word = command[0..first_word_end];
    const equals = std.mem.findScalar(u8, first_word, '=') orelse return false;
    const name = first_word[0..equals];
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }
    return true;
}

fn isStaticUnquotedByte(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or switch (char) {
        '_', '.', '/', ',', ':', '+', '=', '%', '@', '-' => true,
        else => false,
    };
}

fn staticCommandWildcardMatch(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var in_single_quote = false;
    var star_index: ?usize = null;
    var star_candidate_index: usize = 0;

    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len) {
            const char = pattern[pattern_index];
            if (!in_single_quote and char == '*') {
                star_index = pattern_index;
                pattern_index += 1;
                star_candidate_index = candidate_index;
                continue;
            }
            if ((!in_single_quote and char == '?') or char == candidate[candidate_index]) {
                if (char == '\'') in_single_quote = !in_single_quote;
                pattern_index += 1;
                candidate_index += 1;
                continue;
            }
        }

        const star = star_index orelse return false;
        star_candidate_index += 1;
        candidate_index = star_candidate_index;
        pattern_index = star + 1;
        in_single_quote = false;
    }

    while (pattern_index < pattern.len and !in_single_quote and pattern[pattern_index] == '*') : (pattern_index += 1) {}
    return pattern_index == pattern.len;
}

fn directoryTreePatternMatches(pattern: []const u8, candidate: []const u8) bool {
    if (!std.mem.endsWith(u8, pattern, "/**")) return false;
    if (std.mem.eql(u8, pattern, "/**")) return std.mem.startsWith(u8, candidate, "/");

    const dir = pattern[0 .. pattern.len - "/**".len];
    if (std.mem.eql(u8, candidate, dir)) return true;
    return candidate.len > dir.len and
        std.mem.startsWith(u8, candidate, dir) and
        candidate[dir.len] == '/';
}

fn wildcardMatch(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var star_index: ?usize = null;
    var star_candidate_index: usize = 0;

    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == candidate[candidate_index]))
        {
            pattern_index += 1;
            candidate_index += 1;
            continue;
        }
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_candidate_index = candidate_index;
            continue;
        }

        const star = star_index orelse return false;
        star_candidate_index += 1;
        candidate_index = star_candidate_index;
        pattern_index = star + 1;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') : (pattern_index += 1) {}
    return pattern_index == pattern.len;
}

fn isGlobalTargetPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    for (pattern) |char| {
        if (char != '*') return false;
    }
    return true;
}

pub fn webFetchDomainTargetForUrl(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    const scheme_end = std.mem.find(u8, url, "://") orelse return error.InvalidToolArguments;
    const authority_start = scheme_end + "://".len;
    const authority_end = authorityEnd(url, authority_start);
    if (authority_end == authority_start) return error.InvalidToolArguments;

    const authority = url[authority_start..authority_end];
    if (std.mem.findScalar(u8, authority, '@') != null) return error.InvalidToolArguments;
    const host = hostFromAuthority(authority) orelse return error.InvalidToolArguments;
    return canonicalWebFetchDomainPattern(alloc, host);
}

pub fn canonicalWebFetchDomainPattern(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const host_raw = if (std.mem.startsWith(u8, raw, "domain:")) raw["domain:".len..] else raw;
    if (std.mem.find(u8, host_raw, "://") != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '/') != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '*') != null) return error.InvalidToolArguments;
    if (std.mem.findScalar(u8, host_raw, '?') != null) return error.InvalidToolArguments;

    const host = stripOneRootDot(host_raw);
    if (!isCanonicalizableWebFetchHost(host)) return error.InvalidToolArguments;

    const target = try alloc.alloc(u8, "domain:".len + host.len);
    errdefer alloc.free(target);
    @memcpy(target[0.."domain:".len], "domain:");
    for (host, 0..) |char, index| {
        target["domain:".len + index] = std.ascii.toLower(char);
    }
    return target;
}

pub fn isCanonicalWebFetchDomainPattern(pattern: []const u8) bool {
    if (!std.mem.startsWith(u8, pattern, "domain:")) return false;
    const host = pattern["domain:".len..];
    if (!isCanonicalizableWebFetchHost(host)) return false;
    if (std.mem.endsWith(u8, host, ".")) return false;
    for (host) |char| {
        if (std.ascii.isAlphabetic(char) and std.ascii.isUpper(char)) return false;
    }
    return true;
}

fn stripOneRootDot(host: []const u8) []const u8 {
    if (host.len > 1 and host[host.len - 1] == '.') return host[0 .. host.len - 1];
    return host;
}

fn isCanonicalizableWebFetchHost(host: []const u8) bool {
    if (host.len == 0) return false;
    if (host[0] == '[') return isCanonicalizableWebFetchIpv6Literal(host);
    if (std.mem.findScalar(u8, host, ':') != null) return false;
    var label_len: usize = 0;
    for (host) |char| {
        if (char <= 0x20 or char >= 0x7f) return false;
        if (char == '*' or char == '?' or char == '/' or char == '\\') return false;
        if (char == '.') {
            if (label_len == 0) return false;
            label_len = 0;
            continue;
        }
        if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
        label_len += 1;
    }
    return label_len > 0;
}

fn isCanonicalizableWebFetchIpv6Literal(host: []const u8) bool {
    if (host.len < 3 or host[host.len - 1] != ']') return false;
    const inner = host[1 .. host.len - 1];
    if (std.mem.findScalar(u8, inner, '%') != null) return false;
    for (inner) |char| {
        if (char <= 0x20 or char >= 0x7f) return false;
        if (std.ascii.isAlphabetic(char) and std.ascii.isUpper(char)) return false;
        if (!std.ascii.isHex(char) and char != ':' and char != '.') return false;
    }
    _ = std.Io.net.Ip6Address.parse(inner, 0) catch return false;
    return true;
}

fn authorityEnd(url: []const u8, start: usize) usize {
    var index = start;
    while (index < url.len) : (index += 1) {
        switch (url[index]) {
            '/', '?', '#' => return index,
            else => {},
        }
    }
    return url.len;
}

fn hostFromAuthority(authority: []const u8) ?[]const u8 {
    if (authority.len == 0) return null;
    if (authority[0] == '[') {
        const end = std.mem.findScalar(u8, authority, ']') orelse return null;
        if (end == 1) return null;
        if (end + 1 < authority.len and authority[end + 1] != ':') return null;
        return authority[0 .. end + 1];
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len;
    if (colon == 0) return null;
    return authority[0..colon];
}

fn displayPathTarget(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(target_path) and pathing.pathInside(workspace_root, target_path)) {
        const relative = std.fs.path.relative(alloc, "/", null, workspace_root, target_path) catch return alloc.dupe(u8, target_path);
        if (relative.len == 0) {
            alloc.free(relative);
            return alloc.dupe(u8, ".");
        }
        return relative;
    }
    return alloc.dupe(u8, target_path);
}

fn displayCommandTarget(alloc: std.mem.Allocator, workspace_root: []const u8, target_path: []const u8) ![]u8 {
    const separator = std.mem.find(u8, target_path, "::") orelse return alloc.dupe(u8, target_path);
    const cwd = target_path[0..separator];
    const command = command_environment.commandFromPermissionIdentity(
        target_path[separator + 2 ..],
    );

    const display_cwd = try (if (std.mem.eql(u8, cwd, workspace_root))
        alloc.dupe(u8, ".")
    else if (std.fs.path.isAbsolute(cwd) and pathing.pathInside(workspace_root, cwd))
        (std.fs.path.relative(alloc, "/", null, workspace_root, cwd) catch alloc.dupe(u8, cwd))
    else
        alloc.dupe(u8, cwd));
    defer alloc.free(display_cwd);

    return std.fmt.allocPrint(alloc, "{s}::{s}", .{ display_cwd, command });
}

fn ownedRuleSet(alloc: std.mem.Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRuleSet {
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

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectGrant(grant: types.PermissionGrant, permission: []const u8, pattern: []const u8) !void {
    try std.testing.expectEqualStrings(permission, grant.tool_name);
    try std.testing.expectEqualStrings(pattern, grant.target_path);
}

fn freeGrants(alloc: std.mem.Allocator, grants: []types.PermissionGrant) void {
    for (grants) |grant| {
        alloc.free(grant.tool_name);
        alloc.free(grant.target_path);
    }
    alloc.free(grants);
}

fn checkAllowToolForSessionAllocFailures(alloc: std.mem.Allocator) !void {
    var grants: std.ArrayList(types.PermissionGrant) = .empty;
    defer {
        clearAllowedTools(alloc, &grants);
        grants.deinit(alloc);
    }

    try allowToolForSession(alloc, &grants, "edit", "/tmp/workspace/src/main.zig");
}

fn checkSuggestedSessionGrantsAllocFailures(alloc: std.mem.Allocator) !void {
    const command_grants = try suggestedSessionGrants(alloc, "/tmp/workspace", "run_command", "/tmp/workspace::git status --short", .command_cwd);
    defer freeGrants(alloc, command_grants);

    const path_grants = try suggestedSessionGrants(alloc, "/tmp/workspace", "write_file", "/tmp/workspace/src/main.zig", .path_create_parent);
    defer freeGrants(alloc, path_grants);
}






































fn testFileTargets(
    canonical_path: []const u8,
    external: bool,
    items: *[1]file_mutation_contract.EvaluatedPermissionTarget,
) file_mutation_contract.PolicyEvaluatedFileTargets {
    items.* = .{.{
        .kind = .target,
        .disposition = .target_entry,
        .path_end = canonical_path.len,
        .expected_identity = null,
        .rule = .ask,
        .session_grant_allowed = true,
    }};
    return .{
        .canonical_target_path = canonical_path,
        .anchor = .{
            .scope = if (external) .external else .workspace,
            .path_end = canonical_path.len,
            .identity = .{
                .device = 0,
                .inode = 0,
                .kind = .directory,
            },
            .relative_components = &.{},
        },
        .traversal_directories = &.{},
        .items = items,
        .prompt_required = true,
    };
}

fn deinitTestFileGrantOffer(
    alloc: std.mem.Allocator,
    offer: file_mutation_contract.FileGrantOffer,
) void {
    types.freePermissionGrantSlice(alloc, @constCast(offer.grants));
    switch (offer.scope) {
        .workspace_files => {},
        .external_tree => |root_tail| alloc.free(@constCast(root_tail)),
    }
}

fn checkStructuredFileGrantOfferAllocationFailures(
    alloc: std.mem.Allocator,
) !void {
    var items: [1]file_mutation_contract.EvaluatedPermissionTarget = undefined;
    const offer = try structuredFileGrantOffer(
        alloc,
        "/tmp/workspace",
        "write_file",
        testFileTargets("/tmp/workspace/src/main.zig", false, &items),
    );
    defer deinitTestFileGrantOffer(alloc, offer);
    try std.testing.expect(offer.scope == .workspace_files);
}

fn checkExternalStructuredFileGrantOfferAllocationFailures(
    alloc: std.mem.Allocator,
) !void {
    var items: [1]file_mutation_contract.EvaluatedPermissionTarget = undefined;
    const offer = try structuredFileGrantOffer(
        alloc,
        "/tmp/workspace",
        "edit_file",
        testFileTargets("/tmp/external/project/file.txt", true, &items),
    );
    defer deinitTestFileGrantOffer(alloc, offer);
    try std.testing.expectEqualStrings(
        "/tmp/external/project",
        offer.scope.external_tree,
    );
}








fn testWriteMutationInput(path: []const u8) file_mutation_contract.FileMutationInput {
    return .{ .write = .{
        .path = @constCast(path),
        .content = @constCast("x"),
    } };
}

fn testEditMutationInput(path: []const u8) file_mutation_contract.FileMutationInput {
    return .{ .edit = .{
        .path = @constCast(path),
        .old_string = @constCast("a"),
        .new_string = @constCast("b"),
    } };
}


fn checkFileTargetPreparationAllocationFailures(alloc: std.mem.Allocator, workspace: []const u8) !void {
    var prepared = switch (try prepareFileMutationTargets(
        alloc,
        workspace,
        testWriteMutationInput("existing/nested/file.txt"),
    )) {
        .target_resolution_failure => return error.TestUnexpectedResult,
        .prepared => |value| value,
    };
    defer prepared.deinit(alloc);
}








