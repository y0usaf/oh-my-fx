const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const background_runtime = @import("../background/background_runtime.zig");
const vision_contracts = @import("../agent/runtime/vision_contracts.zig");
const command_admission = @import("../permissions/command_admission.zig");
const command_environment = @import("../execution/command_environment.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const diff_mod = @import("../output/diff.zig");
const pathing = @import("../workspace/pathing.zig");
const permission_auto_classifier = @import("../permissions/auto_classifier.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permissions = @import("../permissions/permissions.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_mcp_runtime = @import("tool_mcp_runtime.zig");
const tool_presentation = @import("tool_presentation.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const context_limits = @import("../config/context_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const current_branch = @import("../workspace/current_branch.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const BackgroundRuntime = background_runtime.BackgroundRuntime;
const WorkerRuntime = worker_runtime.WorkerRuntime;

pub const HostSandboxDefault = enum {
    none,
    allow_sandboxed,
    prompt,
};

pub const SessionPermissionStateProvider = struct {
    context: *anyopaque,
    snapshot_fn: *const fn (
        context: *anyopaque,
        alloc: Allocator,
    ) anyerror!session_permission_state.State,

    pub fn snapshot(
        self: SessionPermissionStateProvider,
        alloc: Allocator,
    ) !session_permission_state.State {
        return self.snapshot_fn(self.context, alloc);
    }
};

/// Borrowed capabilities required for permission admission. The leaf never
/// owns, persists, or extends any referenced runtime state.
pub const Input = struct {
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    permission_review_turn: ?permission_auto_classifier.ReviewTurnContext = null,
    permission_grants: []const PermissionGrant,
    permission_rules: types.PermissionRuleSet,
    session_permission_state: ?*const session_permission_state.State = null,
    session_permission_state_provider: ?SessionPermissionStateProvider = null,
    tool_registry: tool_dispatch.Registry,
    worker: *WorkerRuntime,
    permission_prompter: ?permission_prompter.Prompter = null,
    background: *BackgroundRuntime,
    advertised_dynamic_tool_names: []const []const u8,
    mcp_runtime: tool_mcp_runtime.RuntimeCapabilities,
    context_limits: context_limits.Values = .{},
    auto_classifier: permission_auto_classifier.Classifier = .disabled(),
    host_sandbox_default: HostSandboxDefault = .none,
};

fn registeredTool(input: Input, name: []const u8) ?*const tool_dispatch.Tool {
    return input.tool_registry.lookup(name);
}

fn accessScope(input: Input) workspace_access.AccessScope {
    return input.access_scope orelse workspace_access.AccessScope.primaryOnly(input.workspace_root);
}

fn permissionTargetKind(registry: tool_dispatch.Registry, name: []const u8) permissions.PermissionTargetKind {
    return if (registry.lookup(name)) |tool| tool.permission_target_kind else .none;
}

fn toolHasPermissionContract(input: Input, name: []const u8) bool {
    return registeredTool(input, name) != null;
}

fn toolRequiresApproval(input: Input, name: []const u8) bool {
    return if (registeredTool(input, name)) |spec| spec.requires_approval else false;
}

fn registeredTerminalCallReadsOnly(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !bool {
    const tool = registeredTool(input, call.name) orelse return false;
    if (tool.executor_kind != .terminal) return false;
    const decode_ctx = tool_dispatch.DispatchContext{
        .allocator = arena,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
    };
    const decoded = try tool.decode(decode_ctx, call.arguments_json);
    return switch (decoded) {
        .failure => |reason| blk: {
            arena.free(reason);
            break :blk false;
        },
        .input => |tool_input| blk: {
            defer tool_input.deinit(arena);
            if (tool.validate) |validate| {
                if (try validate(decode_ctx, tool_input)) |reason| {
                    arena.free(reason);
                    break :blk false;
                }
            }
            break :blk tool.reads_only_fn(tool_input);
        },
    };
}

fn toolApprovalPolicy(input: Input, name: []const u8) tool_dispatch.ApprovalPolicy {
    return if (registeredTool(input, name)) |spec| spec.approval_policy else .standard;
}

pub fn callUsesCommandAuthority(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
) !bool {
    const tool = registry.lookup(call.name) orelse return false;
    if (tool.executor_kind == .run_command) return true;
    const expected_action = tool.captured_command_action orelse return false;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    return std.mem.eql(u8, action, expected_action);
}

fn isRunCommandCall(input: Input, arena: Allocator, call: ToolCall) !bool {
    return callUsesCommandAuthority(input.tool_registry, arena, call);
}

fn permissionNameForCall(input: Input, arena: Allocator, call: ToolCall) ![]const u8 {
    return if (try isRunCommandCall(input, arena, call)) "run_command" else call.name;
}

fn permissionTargetKindForCall(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !permissions.PermissionTargetKind {
    return if (try isRunCommandCall(input, arena, call))
        .command_cwd
    else
        permissionTargetKind(input.tool_registry, call.name);
}

fn registeredWebSearchTarget(input: Input, name: []const u8) ?[]const u8 {
    const spec = registeredTool(input, name) orelse return null;
    if (spec.executor_kind != .web_search) return null;
    return spec.name;
}

pub const FileMutationPreflight = union(enum) {
    allowed: file_mutation_contract.FileExecutionAuthorization,
    prompt: file_mutation_contract.FileExecutionAuthorization,
    permission_required: file_mutation_contract.FileExecutionAuthorization,
    policy_denied,
    tool_failure: []const u8,
};

pub const FileMutationPreflightRequest = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
    permission_rules: types.PermissionRuleSet,
    session_grants: []const PermissionGrant = &.{},
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant = &.{},
    can_prompt: bool,
    session_permission_state: ?*const session_permission_state.State = null,
    prepare_permission_identity: bool = false,
};

pub const FileMutationPreparationRequest = struct {
    tool_registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    access_scope: ?workspace_access.AccessScope = null,
};

pub const PreparedFileMutationCall = struct {
    call_id: []u8,
    arguments_hash: types.ContentHash,
    workspace_root: []u8,
    input: file_mutation_contract.FileMutationInput,
    targets: file_mutation_contract.ResolvedFileMutationTargets,
    workspace_root_owned: bool = true,
    call_id_owned: bool = true,
    input_owned: bool = true,

    pub fn targetPath(self: PreparedFileMutationCall) []const u8 {
        return self.targets.canonical_target_path;
    }

    pub fn externalActionIdentity(
        self: PreparedFileMutationCall,
    ) ?FileMutationActionIdentity {
        if (self.targets.anchor.scope != .external) return null;
        return FileMutationActionIdentity.init(
            self.targets.canonical_target_path,
            self.input,
        );
    }

    pub fn deinit(self: *PreparedFileMutationCall, alloc: Allocator) void {
        if (self.input_owned) {
            self.input.deinit(alloc);
            self.input_owned = false;
        }
        self.targets.deinit(alloc);
        if (self.call_id_owned) {
            alloc.free(self.call_id);
            self.call_id_owned = false;
        }
        if (self.workspace_root_owned) {
            alloc.free(self.workspace_root);
            self.workspace_root_owned = false;
        }
    }

    fn takeInput(self: *PreparedFileMutationCall) file_mutation_contract.FileMutationInput {
        std.debug.assert(self.input_owned);
        self.input_owned = false;
        return self.input;
    }

    fn takeTargets(self: *PreparedFileMutationCall) file_mutation_contract.ResolvedFileMutationTargets {
        std.debug.assert(self.targets.owns_memory);
        const targets = self.targets;
        self.targets.relinquish();
        return targets;
    }
};

/// Canonical, provider-call-ID-independent identity for one external file
/// mutation request. The fixed-size value is safe to retain for one agent turn
/// without retaining decoded tool inputs or filesystem proof allocations.
pub const FileMutationActionIdentity = struct {
    kind: file_mutation_contract.Kind,
    target_hash: types.ContentHash,
    first_argument_hash: types.ContentHash,
    second_argument_hash: types.ContentHash,

    fn init(
        canonical_target_path: []const u8,
        input: file_mutation_contract.FileMutationInput,
    ) FileMutationActionIdentity {
        var identity: FileMutationActionIdentity = .{
            .kind = std.meta.activeTag(input),
            .target_hash = hashIdentityField(canonical_target_path),
            .first_argument_hash = undefined,
            .second_argument_hash = undefined,
        };
        switch (input) {
            .write => |write| {
                identity.first_argument_hash = hashIdentityField(write.content);
                identity.second_argument_hash = hashIdentityField(
                    "write-file-no-second-argument",
                );
            },
            .edit => |edit| {
                identity.first_argument_hash = hashIdentityField(edit.old_string);
                identity.second_argument_hash = hashIdentityField(edit.new_string);
            },
        }
        return identity;
    }

    pub fn eql(
        a: FileMutationActionIdentity,
        b: FileMutationActionIdentity,
    ) bool {
        return std.meta.eql(a, b);
    }
};

fn hashIdentityField(value: []const u8) types.ContentHash {
    var digest: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return digest;
}

pub const FileMutationPreparation = union(enum) {
    prepared: PreparedFileMutationCall,
    tool_failure: []const u8,
};

const FileMutationDecodeResult = union(enum) {
    input: file_mutation_contract.FileMutationInput,
    failure: []const u8,
};

var file_mutation_decode_count: usize = 0;
var file_mutation_resolution_count: usize = 0;

fn decodeFileMutationInput(
    arena: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !FileMutationDecodeResult {
    const tool = registry.lookup(call.name) orelse return .{
        .failure = try arena.dupe(
            u8,
            "file mutation tool is not registered",
        ),
    };
    const kind: file_mutation_contract.Kind = switch (tool.executor_kind) {
        .write_file => .write,
        .edit_file => .edit,
        else => return .{ .failure = try arena.dupe(
            u8,
            "unsupported file mutation tool",
        ) },
    };
    const take_input = tool.take_file_mutation_input_fn orelse return .{
        .failure = try arena.dupe(
            u8,
            "file mutation tool registration is missing canonical input ownership",
        ),
    };

    if (builtin.is_test) file_mutation_decode_count += 1;
    const decode_ctx = tool_dispatch.DispatchContext{ .allocator = arena };
    const decoded = try tool.decode(decode_ctx, call.arguments_json);
    return switch (decoded) {
        .failure => |reason| .{ .failure = reason },
        .input => |tool_input| blk: {
            var tool_input_owned = true;
            defer if (tool_input_owned) tool_input.deinit(arena);
            if (tool.validate) |validate| {
                if (try validate(decode_ctx, tool_input)) |reason| {
                    break :blk .{ .failure = reason };
                }
            }
            var input = take_input(tool_input, arena);
            tool_input_owned = false;
            if (std.meta.activeTag(input) != kind) {
                input.deinit(arena);
                break :blk .{ .failure = try arena.dupe(
                    u8,
                    "file mutation tool registration returned mismatched input kind",
                ) };
            }
            break :blk .{ .input = input };
        },
    };
}

pub fn prepareFileMutationCall(
    alloc: Allocator,
    call: ToolCall,
    request: FileMutationPreparationRequest,
) !FileMutationPreparation {
    var input = switch (try decodeFileMutationInput(
        alloc,
        request.tool_registry,
        call,
    )) {
        .failure => |reason| return .{ .tool_failure = reason },
        .input => |value| value,
    };
    var input_owned = true;
    defer if (input_owned) input.deinit(alloc);

    if (builtin.is_test) file_mutation_resolution_count += 1;
    var targets = switch (try permissions.prepareFileMutationTargets(
        alloc,
        request.workspace_root,
        input,
    )) {
        .target_resolution_failure => |failure| return .{ .tool_failure = try std.fmt.allocPrint(
            alloc,
            "file mutation target resolution failed: {s}",
            .{@tagName(failure)},
        ) },
        .prepared => |value| value,
    };
    errdefer targets.deinit(alloc);

    const workspace_root = try alloc.dupe(u8, request.workspace_root);
    errdefer alloc.free(workspace_root);
    const call_id = try alloc.dupe(u8, call.id);
    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    input_owned = false;
    return .{ .prepared = .{
        .call_id = call_id,
        .arguments_hash = arguments_hasher.finalResult(),
        .workspace_root = workspace_root,
        .input = input,
        .targets = targets,
    } };
}

pub fn preflightPreparedFileMutation(
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    request: FileMutationPreflightRequest,
) !FileMutationPreflight {
    defer prepared.deinit(arena);

    const expected_kind: file_mutation_contract.Kind =
        if (std.mem.eql(u8, call.name, "write_file"))
            .write
        else if (std.mem.eql(u8, call.name, "edit_file"))
            .edit
        else
            return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    if (std.meta.activeTag(prepared.input) != expected_kind or
        !std.mem.eql(u8, prepared.call_id, call.id) or
        !std.mem.eql(u8, prepared.workspace_root, request.workspace_root))
    {
        return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    }
    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    if (!std.mem.eql(u8, &prepared.arguments_hash, &arguments_hasher.finalResult())) {
        return .{ .tool_failure = "prepared file mutation no longer matches tool call" };
    }

    var input = prepared.takeInput();
    var input_owned = true;
    defer if (input_owned) input.deinit(arena);
    var targets = prepared.takeTargets();

    const policy_result = if (request.permission_mode == .yolo)
        try permissions.authorizePreparedFileMutationTargets(arena, &targets)
    else
        try permissions.evaluatePreparedFileMutationTargetsInScope(
            arena,
            request.access_scope orelse workspace_access.AccessScope.primaryOnly(request.workspace_root),
            expected_kind,
            &targets,
            request.permission_mode,
            request.permission_rules,
            request.session_grants,
            request.local_grants,
        );
    var policy_targets = switch (policy_result) {
        .target_resolution_failure => |failure| {
            return .{ .tool_failure = try std.fmt.allocPrint(
                arena,
                "file mutation target resolution failed: {s}",
                .{@tagName(failure)},
            ) };
        },
        .policy_denied => return .policy_denied,
        .evaluated => |evaluated| evaluated,
    };
    var policy_targets_owned = true;
    defer if (policy_targets_owned) policy_targets.deinitOwned(arena);

    const edit_prompt_required = policy_targets.prompt_required;
    const equality_prompt_required =
        request.permission_mode != .yolo and
        policy_targets.items[0].expected_identity != null and
        try fileMutationEqualityDisclosureRequiresPrompt(
            arena,
            request,
            policy_targets.canonical_target_path,
        );

    var authorization: file_mutation_contract.FileExecutionAuthorization = .{
        .input = input,
        .policy_targets = policy_targets,
        .read_disclosure_required = equality_prompt_required,
    };
    const state_may_decide = if (request.session_permission_state) |state|
        state.rules.items.len > 0
    else
        false;
    if (!edit_prompt_required and
        !equality_prompt_required and
        !state_may_decide and
        !request.prepare_permission_identity)
    {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .allowed = authorization };
    }
    if (!request.can_prompt and edit_prompt_required and equality_prompt_required) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .permission_required = authorization };
    }

    authorization.prepared = switch (try file_mutation.prepareResolvedTarget(
        arena,
        call,
        input,
        policy_targets,
    )) {
        .semantic_failure => |reason| return .{ .tool_failure = reason },
        .prepared => |value| value,
    };
    if (request.session_permission_state) |state| {
        const key = permissionStateKeyForPreparedFileMutation(
            arena,
            authorization.prepared.?,
        ) catch null;
        if (key) |resolved_key| switch (session_permission_state.decide(state.*, resolved_key)) {
            .deny => return .policy_denied,
            .allow => {
                input_owned = false;
                policy_targets_owned = false;
                return .{ .allowed = authorization };
            },
            .unresolved => {},
        };
    }
    const prompt_required = if (file_mutation_contract.preparedMutationIsNoop(
        authorization.prepared.?,
    ))
        equality_prompt_required
    else
        edit_prompt_required;
    if (!prompt_required or request.prepare_permission_identity) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .allowed = authorization };
    }
    authorization.approval_intent = if (file_mutation_contract.preparedMutationIsNoop(
        authorization.prepared.?,
    ))
        .equality_disclosure
    else
        .mutation;
    if (!request.can_prompt) {
        input_owned = false;
        policy_targets_owned = false;
        return .{ .permission_required = authorization };
    }
    authorization.grant_offer = permissions.structuredFileGrantOffer(
        arena,
        request.workspace_root,
        call.name,
        policy_targets,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedFileGrantOffer,
        error.ScopeProjectionTooLarge,
        => return .{ .tool_failure = "file mutation permission scope could not be represented safely" },
    };
    input_owned = false;
    policy_targets_owned = false;
    return .{ .prompt = authorization };
}

pub fn preflightFileMutation(
    arena: Allocator,
    call: ToolCall,
    request: FileMutationPreflightRequest,
) !FileMutationPreflight {
    var prepared = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = request.tool_registry,
        .workspace_root = request.workspace_root,
    })) {
        .tool_failure => |reason| return .{ .tool_failure = reason },
        .prepared => |value| value,
    };
    defer prepared.deinit(arena);
    return preflightPreparedFileMutation(arena, call, &prepared, request);
}

fn fileMutationEqualityDisclosureRequiresPrompt(
    arena: Allocator,
    request: FileMutationPreflightRequest,
    target_path: []const u8,
) !bool {
    return switch (try permissions.ruleDecisionFor(
        arena,
        request.permission_rules,
        request.workspace_root,
        "read_file",
        target_path,
        permissionTargetKind(request.tool_registry, "read_file"),
    )) {
        .allow, .none => false,
        .deny => true,
        .ask => !permissions.sessionGrantAllowed(
            request.session_grants,
            "read_file",
            target_path,
        ) and !permissions.sessionGrantAllowed(
            request.local_grants,
            "read_file",
            target_path,
        ),
    };
}

const FileMutationAdmission = union(enum) {
    resolved: command_admission.PermissionOutcome,
    prompt: struct {
        authorization: file_mutation_contract.FileExecutionAuthorization,
    },
};

fn fileMutationTargetsContainConfiguredAsk(
    targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) bool {
    for (targets.items) |target| {
        if (target.rule == .ask and !target.session_grant_allowed) return true;
    }
    return false;
}

fn fileMutationAuthorizationMayUseAutoReview(
    authorization: file_mutation_contract.FileExecutionAuthorization,
) bool {
    if (authorization.prepared == null) return false;
    const intent = authorization.approval_intent orelse return false;
    return intent == .mutation and
        !fileMutationTargetsContainConfiguredAsk(authorization.policy_targets);
}

fn fileMutationAuthorizationMayBypassAutoReview(
    input: Input,
    authorization: file_mutation_contract.FileExecutionAuthorization,
) bool {
    const prepared = authorization.prepared orelse return false;
    const intent = authorization.approval_intent orelse return false;
    const target_path = authorization.policy_targets.canonical_target_path;
    const target_is_reversible = accessScope(input).contains(target_path) or
        std.meta.activeTag(prepared.preimage) == .absent;
    return intent == .mutation and
        !authorization.read_disclosure_required and
        target_is_reversible and
        !sensitiveAutoWriteTarget(target_path) and
        !fileMutationTargetsContainConfiguredAsk(authorization.policy_targets);
}

fn sensitiveAutoWriteTarget(path: []const u8) bool {
    return pathContainsComponentSequence(path, &.{ ".git", "hooks" }) or
        pathContainsComponentSequence(path, &.{ ".git", "config" }) or
        pathContainsComponentSequence(path, &.{ ".git", "config.worktree" }) or
        pathContainsComponentSequence(path, &.{ ".ssh", "authorized_keys" }) or
        pathContainsComponentSequence(path, &.{ ".ssh", "config" }) or
        pathContainsComponentSequence(path, &.{ "Library", "LaunchAgents" }) or
        pathContainsComponentSequence(path, &.{ "Library", "LaunchDaemons" }) or
        pathContainsComponentSequence(path, &.{ ".config", "autostart" }) or
        pathContainsComponentSequence(path, &.{ ".config", "fish", "config.fish" }) or
        pathContainsComponentSequence(path, &.{".zshrc"}) or
        pathContainsComponentSequence(path, &.{".bashrc"}) or
        pathContainsComponentSequence(path, &.{".bash_profile"}) or
        pathContainsComponentSequence(path, &.{".profile"});
}

fn pathContainsComponentSequence(
    path: []const u8,
    expected: []const []const u8,
) bool {
    if (expected.len == 0) return false;
    var matched: usize = 0;
    var index: usize = 0;
    while (index < path.len) {
        while (index < path.len and std.fs.path.isSep(path[index])) : (index += 1) {}
        const start = index;
        while (index < path.len and !std.fs.path.isSep(path[index])) : (index += 1) {}
        if (start == index) break;
        const component = path[start..index];
        if (std.mem.eql(u8, component, expected[matched])) {
            matched += 1;
            if (matched == expected.len) return true;
        } else {
            matched = if (std.mem.eql(u8, component, expected[0])) 1 else 0;
        }
    }
    return false;
}

fn fileMutationPermissionTargets(
    arena: Allocator,
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) ![]permissions.PermissionCallTarget {
    const targets = try arena.alloc(
        permissions.PermissionCallTarget,
        policy_targets.items.len,
    );
    for (policy_targets.items, 0..) |item, index| {
        targets[index] = .{
            .role = @tagName(item.kind),
            .path = try arena.dupe(
                u8,
                policy_targets.permissionPath(item),
            ),
        };
    }
    return targets;
}

fn schemaForReview(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    is_dynamic_tool: bool,
) !?[]const u8 {
    if (!is_dynamic_tool) return null;
    const context = input.mcp_runtime.context orelse return null;
    const tool_schema = input.mcp_runtime.tool_schema orelse return null;
    const result = (try tool_schema(
        context,
        arena,
        call.name,
        input.permission_rules,
        input.context_limits,
        input.mcp_runtime.access,
    )) orelse return null;
    return switch (result) {
        .selected => |payload| payload.model_output,
        .rejected => null,
    };
}

fn reviewRequestForCall(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
    is_dynamic_tool: bool,
    file_authorization: ?file_mutation_contract.FileExecutionAuthorization,
) !permission_auto_classifier.ReviewRequest {
    const action: permission_auto_classifier.Action =
        if (file_authorization) |authorization| blk: {
            const prepared = authorization.prepared orelse
                return error.FileMutationNotPrepared;
            break :blk .{ .file_mutation = .{
                .tool_name = call.name,
                .display_path = prepared.display_path,
                .preimage = switch (prepared.preimage) {
                    .absent => .absent,
                    .present => .present,
                },
                .additions = prepared.review.additions,
                .deletions = prepared.review.deletions,
                .review = prepared.review,
            } };
        } else if (try isRunCommandCall(input, arena, call)) blk: {
            const command = try runCommandContext(input, arena, call);
            break :blk .{ .command = .{
                .command = command.command,
                .resolved_cwd = command.resolved_cwd,
                .background = command.background,
                .target_os = command.target_os,
            } };
        } else blk: {
            break :blk .{ .tool = .{
                .tool_name = call.name,
                .arguments_json = call.arguments_json,
                .schema_json = try schemaForReview(
                    input,
                    arena,
                    call,
                    is_dynamic_tool,
                ),
                .schema_required = is_dynamic_tool,
            } };
        };
    var review_turn = input.permission_review_turn orelse
        return error.PermissionReviewContextUnavailable;
    const action_provenance = permission_auto_classifier.deriveActionProvenance(
        action,
        call.arguments_json,
        review_turn.current_turn_untrusted_messages,
    );
    const prior_tool_results = try permission_auto_classifier.selectPriorToolResults(
        arena,
        review_turn.current_turn_untrusted_messages,
        review_turn.target_call_id,
    );
    review_turn.current_turn_untrusted_messages = &.{};
    return .{
        .review_turn = review_turn,
        .proven_bindings = try provenBindingsForAction(arena, action),
        .action_provenance = action_provenance,
        .prior_tool_results = prior_tool_results,
        .targets = targets,
        .action = action,
    };
}

fn provenBindingsForAction(
    arena: Allocator,
    action: permission_auto_classifier.Action,
) !permission_auto_classifier.ProvenBindings {
    const command = switch (action) {
        .command => |value| value,
        .file_mutation, .tool => return .{},
    };
    const expected = try directGitPushBranch(arena, command.command) orelse
        return .{};
    const branch = try current_branch.read(arena, command.resolved_cwd) orelse
        return .{};
    return if (std.mem.eql(u8, expected, branch))
        .{ .current_branch = branch }
    else
        .{};
}

fn directGitPushBranch(
    arena: Allocator,
    command: []const u8,
) Allocator.Error!?[]const u8 {
    if (command_lex.unsafe_compound_indicator(command)) return null;
    var argv = command_lex.tokenize_argv(arena, command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer argv.deinit(arena);
    if (argv.tokens.len < 4 or
        !std.mem.eql(u8, argv.tokens[0].value, "git") or
        !std.mem.eql(u8, argv.tokens[1].value, "push"))
    {
        return null;
    }
    for (argv.tokens) |token| {
        if (!token.quoted and (command_lex.redirection_kind(token.value) != null or
            std.mem.eql(u8, token.value, "|") or
            std.mem.eql(u8, token.value, "||") or
            std.mem.eql(u8, token.value, "&&") or
            std.mem.eql(u8, token.value, ";") or
            std.mem.eql(u8, token.value, "&"))) return null;
    }
    const branch = argv.tokens[argv.tokens.len - 1];
    if (branch.value.len == 0 or branch.value[0] == '-' or
        std.mem.eql(u8, branch.value, "HEAD") or
        !literalShellToken(branch.raw))
    {
        return null;
    }
    return try arena.dupe(u8, branch.value);
}

fn literalShellToken(raw: []const u8) bool {
    var in_single = false;
    var in_double = false;
    var escaped = false;
    for (raw) |byte| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\' and !in_single) {
            escaped = true;
            continue;
        }
        if (byte == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (byte == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single) continue;
        if (byte == '$' or byte == '`') return false;
        if (!in_double and (byte == '*' or byte == '?' or byte == '[' or
            byte == '~')) return false;
    }
    return !escaped and !in_single and !in_double;
}

/// An unavailable or invalid automatic review never executes anything. It is
/// returned to the primary model as neutral advisory unavailability.
fn traceReviewerUnavailable(call: ToolCall) void {
    debug_trace.logf(
        "permission",
        "event=auto_review_result tool_name={s} decision=unavailable fallback_reason=reviewer_unavailable recovery=agent_replan execution_started=false call_id={s}",
        .{ call.name, call.id },
    );
}

fn reviewerUnavailableOutcome(call: ToolCall) command_admission.PermissionOutcome {
    traceReviewerUnavailable(call);
    return .{
        .decision = .deny,
        .denial_reason = .review_unavailable,
    };
}

/// Reduces advisory review into exact execution or a model-visible hold.
fn nonAllowAutoReviewOutcome(
    arena: Allocator,
    request: permission_auto_classifier.ReviewRequest,
    review: permission_auto_classifier.ParseOutcome,
) !?command_admission.PermissionOutcome {
    return switch (permission_auto_classifier.validatedHostDisposition(
        request,
        review,
    )) {
        .clear => null,
        .unavailable => .{
            .decision = .deny,
            .denial_reason = .review_unavailable,
        },
        .caution => switch (review) {
            .valid => |result| if (result.decision == .caution)
                .{
                    .decision = .deny,
                    .denial_reason = .review_caution,
                    .auto_review_result = result,
                }
            else blk: {
                const safety_override = permission_auto_classifier.hostSafetyOverride(request);
                std.debug.assert(safety_override != .none);
                break :blk .{
                    .decision = .deny,
                    .denial_reason = .review_caution,
                    .auto_review_result = .{
                        .risk = .high,
                        .decision = .caution,
                        .rationale = try arena.dupe(
                            u8,
                            permission_auto_classifier.hostSafetyRationale(safety_override),
                        ),
                    },
                };
            },
            .invalid => unreachable,
        },
    };
}

fn automaticReviewOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
    is_dynamic_tool: bool,
    file_authorization: ?file_mutation_contract.FileExecutionAuthorization,
) !command_admission.PermissionOutcome {
    if (!input.auto_classifier.enabled()) return reviewerUnavailableOutcome(call);
    if (input.permission_review_turn == null) return reviewerUnavailableOutcome(call);

    const request = try reviewRequestForCall(
        input,
        arena,
        call,
        targets,
        is_dynamic_tool,
        file_authorization,
    );
    const review = try runAutomaticReview(input, arena, call, request);
    const safety_override = permission_auto_classifier.hostSafetyOverride(request);
    if (permission_auto_classifier.hostDisposition(review) == .clear and
        safety_override != .none)
    {
        debug_trace.logf(
            "permission",
            "event=auto_review_host_override tool_name={s} reason={s} execution_started=false call_id={s}",
            .{ call.name, @tagName(safety_override), call.id },
        );
    }
    if (try nonAllowAutoReviewOutcome(arena, request, review)) |blocked| return blocked;
    var outcome = if (file_authorization) |authorization|
        command_admission.PermissionOutcome{
            .decision = .once,
            .execution_authority = .{
                .file_mutation = authorization,
            },
        }
    else
        try permissionOutcomeForDecision(
            input,
            arena,
            call,
            .once,
            .auto_classifier,
        );
    outcome.auto_review_result = review.valid;
    return outcome;
}

fn runAutomaticReview(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    request: permission_auto_classifier.ReviewRequest,
) !permission_auto_classifier.ParseOutcome {
    const started_ms = io_mod.milliTimestamp();
    debug_trace.logf(
        "permission",
        "event=auto_review_start tool_name={s} action_kind={s} call_id={s}",
        .{ call.name, @tagName(std.meta.activeTag(request.action)), call.id },
    );
    const review = input.auto_classifier.review(arena, request) catch |err| {
        debug_trace.logf(
            "permission",
            "event=auto_review_result tool_name={s} decision=cancelled_or_error fallback_reason={s} elapsed_ms={d} execution_started=false call_id={s}",
            .{ call.name, @errorName(err), io_mod.milliTimestamp() - started_ms, call.id },
        );
        return err;
    };
    switch (review) {
        .valid => |result| debug_trace.logf(
            "permission",
            "event=auto_review_result tool_name={s} decision={s} fallback_reason=none elapsed_ms={d} execution_started=false call_id={s}",
            .{ call.name, @tagName(result.decision), io_mod.milliTimestamp() - started_ms, call.id },
        ),
        .invalid => debug_trace.logf(
            "permission",
            "event=auto_review_result tool_name={s} decision=unavailable fallback_reason=invalid_or_unavailable recovery=agent_replan elapsed_ms={d} execution_started=false call_id={s}",
            .{ call.name, io_mod.milliTimestamp() - started_ms, call.id },
        ),
    }
    return review;
}

fn resolveOrdinaryPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
    is_dynamic_tool: bool,
    permission_mode: PermissionMode,
) !command_admission.PermissionOutcome {
    const command_call = try isRunCommandCall(input, arena, call);
    if (command_call) {
        const default_outcome = defaultRunCommandPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
        );
        if (default_outcome.execution_authority != null) return default_outcome;
    }
    if (toolApprovalPolicy(input, call.name) == .ask_only) {
        return if (permission_mode == .auto)
            ordinaryPermissionOutcome(.once)
        else
            .{ .decision = .permission_required };
    }
    if (permission_mode == .auto and
        !command_call and
        !is_dynamic_tool and
        try registeredTerminalCallReadsOnly(input, arena, call))
    {
        return ordinaryPermissionOutcome(.once);
    }
    if (!command_call and !toolRequiresApproval(input, call.name) and !is_dynamic_tool) {
        return ordinaryPermissionOutcome(.once);
    }

    if (permission_mode == .auto) {
        if (command_call) {
            const command = try runCommandContext(input, arena, call);
            if (try command_effect.knownReversibleAutoCommand(
                arena,
                command.command,
                command.background,
            )) {
                return shellPermissionOutcome(
                    command,
                    .once,
                    .auto_mode,
                );
            }
        }
        return automaticReviewOutcome(
            input,
            arena,
            call,
            targets,
            is_dynamic_tool,
            null,
        );
    }

    return .{ .decision = .permission_required };
}

fn resolveFileMutationAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !FileMutationAdmission {
    return resolveFileMutationPreflightAdmission(
        input,
        arena,
        call,
        permission_mode,
        try preflightFileMutation(
            arena,
            call,
            fileMutationPreflightRequest(input, permission_mode, local_grants),
        ),
    );
}

fn resolvePreparedFileMutationAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !FileMutationAdmission {
    return resolveFileMutationPreflightAdmission(
        input,
        arena,
        call,
        permission_mode,
        try preflightPreparedFileMutation(
            arena,
            call,
            prepared,
            fileMutationPreflightRequest(input, permission_mode, local_grants),
        ),
    );
}

fn fileMutationPreflightRequest(
    input: Input,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) FileMutationPreflightRequest {
    return .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
        .permission_rules = input.permission_rules,
        .session_grants = input.permission_grants,
        .permission_mode = permission_mode,
        .local_grants = local_grants,
        .can_prompt = input.permission_prompter != null or permission_mode == .auto,
        .session_permission_state = input.session_permission_state,
    };
}

fn resolveFileMutationPreflightAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    preflight: FileMutationPreflight,
) !FileMutationAdmission {
    return switch (preflight) {
        .tool_failure => |reason| .{ .resolved = .{ .tool_failure = reason } },
        .policy_denied => .{ .resolved = .{ .decision = .policy_denied } },
        .allowed => |authorization| .{ .resolved = .{
            .decision = .once,
            .execution_authority = .{ .file_mutation = authorization },
        } },
        .permission_required, .prompt => |authorization| blk: {
            if (permission_mode == .auto and
                fileMutationAuthorizationMayBypassAutoReview(input, authorization))
            {
                break :blk .{ .resolved = .{
                    .decision = .once,
                    .execution_authority = .{ .file_mutation = authorization },
                } };
            }
            if (permission_mode == .auto and
                fileMutationAuthorizationMayUseAutoReview(authorization))
            {
                const targets = try fileMutationPermissionTargets(
                    arena,
                    authorization.policy_targets,
                );
                const reviewed = try automaticReviewOutcome(
                    input,
                    arena,
                    call,
                    targets,
                    false,
                    authorization,
                );
                if (reviewed.decision != .permission_required) {
                    break :blk .{ .resolved = reviewed };
                }
                // Model ask carries auto_review_result. Without a prompter, keep
                // that reviewed outcome instead of dropping the rationale on the
                // prompt unavailable path. Bare reviewer-unavailable still falls
                // through so site requirement tags are preserved.
                if (input.permission_prompter == null and reviewed.auto_review_result != null) {
                    break :blk .{ .resolved = reviewed };
                }
            }
            break :blk .{ .prompt = .{
                .authorization = authorization,
            } };
        },
    };
}

pub fn requestPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    if (input.session_permission_state == null) {
        if (input.session_permission_state_provider) |provider| {
            var snapshot = try provider.snapshot(arena);
            defer snapshot.deinit(arena);
            var resolved = input;
            resolved.session_permission_state = &snapshot;
            resolved.session_permission_state_provider = null;
            return requestPermissionOutcomeResolved(
                resolved,
                arena,
                call,
                permission_mode,
                local_grants,
            );
        }
    }
    return requestPermissionOutcomeResolved(
        input,
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

fn requestPermissionOutcomeResolved(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    if (file_mutation_contract.isToolName(call.name)) {
        return requestFileMutationPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
            local_grants,
        );
    }
    const is_mcp_tool = isAvailableDynamicTool(input, call.name);
    const command_call = try isRunCommandCall(input, arena, call);
    if (!toolHasPermissionContract(input, call.name) and
        !is_mcp_tool and
        !command_call)
    {
        return ordinaryPermissionOutcome(.once);
    }
    const permission_name = try permissionNameForCall(input, arena, call);
    const target_kind = try permissionTargetKindForCall(input, arena, call);
    var targets = permissionTargetsForCall(input, arena, call) catch |err| {
        if (try permissionTargetResolutionFailureMessage(arena, call.name, err)) |failure| {
            return .{ .tool_failure = failure };
        }
        return err;
    };
    defer targets.deinit(arena);
    const vision_path_authority = visionPathExecutionAuthority(
        arena,
        call,
        targets.items,
    ) catch |err| switch (err) {
        error.InvalidToolArguments => return .{
            .tool_failure = "Vision paths must reference regular files.",
        },
        else => return err,
    };
    const policy_targets = if (vision_path_authority) |authority|
        try visionPathPermissionTargets(arena, authority)
    else
        targets.items;
    const vision_path_label = if (vision_path_authority) |authority|
        try formatVisionPathPermissionLabel(arena, authority)
    else
        null;
    if (permission_mode == .yolo) {
        return bindVisionPathExecutionAuthority(try permissionOutcomeForDecision(
            input,
            arena,
            call,
            .once,
            .yolo,
        ), vision_path_authority);
    }
    var configured_ask = false;
    var all_targets_authorized_by_rule = true;
    var used_session_grant = false;
    for (policy_targets) |target| {
        switch (try permissions.ruleDecisionFor(arena, input.permission_rules, input.workspace_root, permission_name, target.path, target_kind)) {
            .deny => return .{ .decision = .policy_denied },
            .allow => {},
            .ask => {
                if (permissions.sessionGrantAllowed(local_grants, permission_name, target.path)) {
                    used_session_grant = true;
                    continue;
                }
                configured_ask = true;
            },
            .none => all_targets_authorized_by_rule = false,
        }
    }

    if (input.session_permission_state) |state| {
        const key = permissionStateKeyForCall(input, arena, call) catch null;
        if (key) |resolved_key| switch (session_permission_state.decide(state.*, resolved_key)) {
            .deny => return .{
                .decision = .policy_denied,
                .denial_reason = .policy_denied,
            },
            .allow => return bindVisionPathExecutionAuthority(
                try permissionOutcomeForDecision(
                    input,
                    arena,
                    call,
                    .once,
                    .session_state,
                ),
                vision_path_authority,
            ),
            .unresolved => {},
        };
    }

    if (configured_ask) {
        if (input.permission_prompter == null) return .{
            .decision = noninteractivePermissionRequired(call, "configured_rule_ask"),
            .denial_reason = .permission_required,
            .requirement = .configured_rule,
        };
        return bindVisionPathExecutionAuthority(
            try promptPermissionOutcome(
                input,
                arena,
                call,
                null,
                vision_path_label,
                .configured_rule,
            ),
            vision_path_authority,
        );
    }

    if (all_targets_authorized_by_rule) {
        return bindVisionPathExecutionAuthority(try permissionOutcomeForDecision(
            input,
            arena,
            call,
            .once,
            if (used_session_grant) .session_grant else .configured_rule,
        ), vision_path_authority);
    }
    if (sessionGrantsAllowAll(local_grants, permission_name, policy_targets)) {
        return bindVisionPathExecutionAuthority(
            try permissionOutcomeForDecision(input, arena, call, .once, .session_grant),
            vision_path_authority,
        );
    }
    if (input.host_sandbox_default == .allow_sandboxed and
        try isRunCommandCall(input, arena, call))
    {
        return shellPermissionOutcome(
            try runCommandContext(input, arena, call),
            .once,
            .js_host,
        );
    }
    const resolution = try resolveOrdinaryPermissionOutcome(
        input,
        arena,
        call,
        policy_targets,
        is_mcp_tool,
        permission_mode,
    );
    if (resolution.decision != .permission_required) {
        return bindVisionPathExecutionAuthority(resolution, vision_path_authority);
    }
    const unavailable_requirement: command_admission.PermissionRequirement = .approval_required;
    if (input.permission_prompter == null) {
        _ = noninteractivePermissionRequired(
            call,
            if (try isRunCommandCall(input, arena, call))
                "command_requires_approval"
            else
                "tool_requires_approval",
        );
        var blocked = resolution;
        blocked.denial_reason = .permission_required;
        blocked.requirement = unavailable_requirement;
        return bindVisionPathExecutionAuthority(blocked, vision_path_authority);
    }
    return bindVisionPathExecutionAuthority(
        try promptPermissionOutcome(
            input,
            arena,
            call,
            resolution.auto_review_result,
            vision_path_label,
            unavailable_requirement,
        ),
        vision_path_authority,
    );
}

fn exactApprovalLocalGrants(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    local_grants: []const PermissionGrant,
    authority: command_admission.ToolExecutionAuthority,
) ![]const PermissionGrant {
    switch (authority) {
        .file_mutation => |authorization| {
            const offer = authorization.grant_offer orelse return local_grants;
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + offer.grants.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            @memcpy(grants[local_grants.len..], offer.grants);
            return grants;
        },
        .ordinary, .run_command => {
            var targets = try permissionTargetsForCall(input, arena, call);
            defer targets.deinit(arena);
            const permission_name = try permissionNameForCall(input, arena, call);
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + targets.items.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            for (targets.items, grants[local_grants.len..]) |target, *grant| {
                grant.* = .{
                    .tool_name = try arena.dupe(
                        u8,
                        permissions.permissionNameForTool(permission_name),
                    ),
                    .target_path = try arena.dupe(
                        u8,
                        permissions.patternForSessionGrantMatch(
                            permission_name,
                            target.path,
                        ),
                    ),
                };
            }
            return grants;
        },
        .vision_paths => |vision_authority| {
            const grants = try arena.alloc(
                PermissionGrant,
                local_grants.len + vision_authority.targets.len,
            );
            @memcpy(grants[0..local_grants.len], local_grants);
            for (vision_authority.targets, grants[local_grants.len..]) |target, *grant| {
                grant.* = .{
                    .tool_name = try arena.dupe(
                        u8,
                        permissions.permissionNameForTool(call.name),
                    ),
                    .target_path = try arena.dupe(
                        u8,
                        permissions.patternForSessionGrantMatch(
                            call.name,
                            target.canonical_path,
                        ),
                    ),
                };
            }
            return grants;
        },
    }
}

/// Re-applies the complete current permission policy to the exact child
/// action. A prior exact approval satisfies new Ask decisions for this action,
/// but never bypasses a current Deny decision. Always remains durable through
/// the refreshed shared grant; this local proof covers only the current call.
pub fn revalidateLiveActionPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
    authority: command_admission.ToolExecutionAuthority,
    human_approval: command_admission.HumanApprovalProvenance,
) !command_admission.PermissionOutcome {
    const revalidation_grants = if (human_approval != .none)
        try exactApprovalLocalGrants(
            input,
            arena,
            call,
            local_grants,
            authority,
        )
    else
        local_grants;
    var outcome = switch (authority) {
        .ordinary => try requestPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
            revalidation_grants,
        ),
        .run_command => |expected| blk: {
            const outcome = try requestPermissionOutcome(
                input,
                arena,
                call,
                permission_mode,
                revalidation_grants,
            );
            if (!outcome.decision.isDenied()) {
                const actual = switch (outcome.execution_authority orelse
                    break :blk invalidLiveActionOutcome()) {
                    .run_command => |value| value,
                    .ordinary, .file_mutation, .vision_paths => break :blk invalidLiveActionOutcome(),
                };
                if (!commandAuthorityFingerprint(expected).eql(
                    commandAuthorityFingerprint(actual),
                )) break :blk invalidLiveActionOutcome();
            }
            break :blk outcome;
        },
        .file_mutation => try requestPermissionOutcome(
            input,
            arena,
            call,
            permission_mode,
            revalidation_grants,
        ),
        .vision_paths => |expected| blk: {
            const canonical_call = try canonicalVisionPathCall(arena, call, expected);
            const refreshed = try requestPermissionOutcome(
                input,
                arena,
                canonical_call,
                permission_mode,
                revalidation_grants,
            );
            if (!refreshed.decision.isDenied()) {
                const actual = switch (refreshed.execution_authority orelse
                    break :blk invalidLiveActionOutcome()) {
                    .vision_paths => |value| value,
                    .ordinary, .run_command, .file_mutation => break :blk invalidLiveActionOutcome(),
                };
                if (!visionPathAuthoritiesEqual(expected, actual)) {
                    break :blk invalidLiveActionOutcome();
                }
            }
            break :blk refreshed;
        },
    };
    if (human_approval != .none and
        outcome.tool_failure == null and
        !outcome.decision.isDenied())
    {
        outcome.decision = switch (human_approval) {
            .once => .once,
            .always => .always,
            .none => unreachable,
        };
        outcome.human_approval = human_approval;
    }
    return outcome;
}

fn commandAuthorityFingerprint(
    authority: command_admission.CommandExecutionAuthority,
) command_admission.AdmissionFingerprint {
    return switch (authority) {
        .direct_only => |fingerprint| fingerprint,
        .shell_allowed => |allowed| allowed.fingerprint,
    };
}

fn canonicalVisionPathCall(
    arena: Allocator,
    call: ToolCall,
    authority: command_admission.VisionPathExecutionAuthority,
) !ToolCall {
    var request = try vision_contracts.parse_vision_request(arena, call.arguments_json);
    defer request.deinit(arena);
    const paths = request.paths() orelse return error.InvalidToolArguments;
    if (paths.len != authority.targets.len) return error.InvalidToolArguments;

    const canonical_paths = try arena.alloc([]const u8, authority.targets.len);
    for (authority.targets, canonical_paths) |target, *canonical_path| {
        canonical_path.* = target.canonical_path;
    }

    var arguments: std.Io.Writer.Allocating = .init(arena);
    defer arguments.deinit();
    try arguments.writer.writeAll("{\"paths\":");
    try std.json.Stringify.value(canonical_paths, .{}, &arguments.writer);
    try arguments.writer.writeAll(",\"focus\":");
    try std.json.Stringify.value(request.focus, .{}, &arguments.writer);
    try arguments.writer.writeByte('}');
    return .{
        .id = call.id,
        .name = call.name,
        .arguments_json = try arguments.toOwnedSlice(),
    };
}

fn visionPathAuthoritiesEqual(
    expected: command_admission.VisionPathExecutionAuthority,
    actual: command_admission.VisionPathExecutionAuthority,
) bool {
    if (expected.targets.len != actual.targets.len) return false;
    for (expected.targets, actual.targets) |expected_target, actual_target| {
        if (!std.mem.eql(
            u8,
            expected_target.canonical_path,
            actual_target.canonical_path,
        ) or !std.meta.eql(expected_target.identity, actual_target.identity)) {
            return false;
        }
    }
    return true;
}

fn invalidLiveActionOutcome() command_admission.PermissionOutcome {
    return .{
        .decision = .policy_denied,
        .denial_reason = .policy_denied,
        .tool_failure = "live authority no longer matches the prepared action",
    };
}

fn requestFileMutationPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    return requestFileMutationPermissionOutcomeFromAdmission(
        input,
        arena,
        call,
        try resolveFileMutationAdmission(
            input,
            arena,
            call,
            permission_mode,
            local_grants,
        ),
    );
}

pub fn requestPreparedFileMutationPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    prepared: *PreparedFileMutationCall,
    permission_mode: PermissionMode,
    local_grants: []const PermissionGrant,
) !command_admission.PermissionOutcome {
    return requestFileMutationPermissionOutcomeFromAdmission(
        input,
        arena,
        call,
        try resolvePreparedFileMutationAdmission(
            input,
            arena,
            call,
            prepared,
            permission_mode,
            local_grants,
        ),
    );
}

fn requestFileMutationPermissionOutcomeFromAdmission(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    admission: FileMutationAdmission,
) !command_admission.PermissionOutcome {
    return switch (admission) {
        .resolved => |outcome| outcome,
        .prompt => |pending| blk: {
            const unavailable: command_admission.PermissionOutcome = .{
                .decision = .permission_required,
                .denial_reason = .permission_required,
                .requirement = if (fileMutationTargetsContainConfiguredAsk(
                    pending.authorization.policy_targets,
                ))
                    .configured_rule
                else
                    .approval_required,
            };
            const prompter = input.permission_prompter orelse break :blk unavailable;
            var authorization = pending.authorization;
            const request_view = try fileMutationPermissionRequest(
                "file_mutation",
                authorization,
            );
            const review = if (authorization.prepared) |*prepared|
                &prepared.review
            else
                return error.RequestProjectionTooLarge;
            var response = prompter.request(
                std.heap.c_allocator,
                request_view,
                call,
                review,
                authorization.grant_offer.?.grants,
            ) catch |err| switch (err) {
                error.PermissionPromptUnavailable => break :blk unavailable,
                else => return err,
            };
            defer response.deinit();
            var outcome: command_admission.PermissionOutcome = .{
                .decision = response.decision,
                .execution_authority = if (response.decision.isDenied()) null else .{
                    .file_mutation = authorization,
                },
                .human_approval = humanApprovalProvenance(response.decision),
            };
            if (response.decision == .deny) {
                outcome.denial_reason = .user_denied;
            }
            outcome.feedback = try copyPermissionFeedback(arena, &response);
            break :blk outcome;
        },
    };
}

fn fileMutationPermissionRequest(
    label: []const u8,
    authorization: file_mutation_contract.FileExecutionAuthorization,
) permission_request.RequestCloneError!permission_request.PermissionRequest {
    const prepared = authorization.prepared orelse
        return error.RequestProjectionTooLarge;
    const offer = authorization.grant_offer orelse
        return error.RequestProjectionTooLarge;
    const intent = authorization.approval_intent orelse
        return error.RequestProjectionTooLarge;
    const request: permission_request.PermissionRequest = .{
        .label = label,
        .file = .{
            .kind = prepared.kind,
            .intent = intent,
            .preview = prepared.preview,
            .scope = offer.scope,
        },
    };
    _ = try permission_request.fileRequestFootprint(request);
    return request;
}

fn ordinaryPermissionOutcome(decision: ToolPermissionDecision) command_admission.PermissionOutcome {
    return .{
        .decision = decision,
        .execution_authority = if (decision.isDenied()) null else .ordinary,
    };
}

fn visionPathExecutionAuthority(
    arena: Allocator,
    call: ToolCall,
    targets: []const permissions.PermissionCallTarget,
) !?command_admission.VisionPathExecutionAuthority {
    if (!std.mem.eql(u8, call.name, "vision") or
        targets.len == 0 or
        !std.mem.eql(u8, targets[0].role, "image"))
    {
        return null;
    }
    const execution_targets = try arena.alloc(
        command_admission.VisionPathExecutionTarget,
        targets.len,
    );
    for (targets, execution_targets) |target, *execution_target| {
        if (!std.mem.eql(u8, target.role, "image")) {
            return error.InvalidToolArguments;
        }
        var source = image_attachments.openVisionRegularFile(target.path) catch
            return error.InvalidToolArguments;
        defer source.close();
        execution_target.* = .{
            .canonical_path = try arena.dupe(u8, target.path),
            .identity = source.identity,
        };
    }
    return .{ .targets = execution_targets };
}

fn visionPathPermissionTargets(
    arena: Allocator,
    authority: command_admission.VisionPathExecutionAuthority,
) ![]const permissions.PermissionCallTarget {
    const targets = try arena.alloc(
        permissions.PermissionCallTarget,
        authority.targets.len,
    );
    for (authority.targets, targets) |execution_target, *target| {
        target.* = .{
            .role = "image",
            .path = @constCast(execution_target.canonical_path),
        };
    }
    return targets;
}

fn bindVisionPathExecutionAuthority(
    outcome: command_admission.PermissionOutcome,
    vision_authority: ?command_admission.VisionPathExecutionAuthority,
) !command_admission.PermissionOutcome {
    const authority = vision_authority orelse return outcome;
    var bound = outcome;
    if (bound.execution_authority) |execution_authority| {
        switch (execution_authority) {
            .ordinary => bound.execution_authority = .{ .vision_paths = authority },
            .run_command, .file_mutation, .vision_paths => {},
        }
    }
    return bound;
}

fn permissionOutcomeForDecision(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    decision: ToolPermissionDecision,
    source: command_admission.ShellAuthorizationSource,
) !command_admission.PermissionOutcome {
    if (decision.isDenied()) return .{ .decision = decision };
    if (!try isRunCommandCall(input, arena, call)) {
        return ordinaryPermissionOutcome(decision);
    }
    const command_ctx = runCommandContext(input, arena, call) catch {
        return .{ .decision = .permission_required };
    };
    return shellPermissionOutcome(command_ctx, decision, source);
}

fn shellPermissionOutcome(
    command_ctx: command_admission.CommandContext,
    decision: ToolPermissionDecision,
    source: command_admission.ShellAuthorizationSource,
) command_admission.PermissionOutcome {
    if (decision.isDenied()) return .{ .decision = decision };
    return .{
        .decision = decision,
        .execution_authority = .{ .run_command = .{ .shell_allowed = .{
            .fingerprint = .init(command_ctx),
            .source = source,
        } } },
    };
}

fn permissionOutcomeForResponse(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    response: *const permission_request.OwnedPermissionResponse,
    source: command_admission.ShellAuthorizationSource,
) !command_admission.PermissionOutcome {
    var outcome = try permissionOutcomeForDecision(
        input,
        arena,
        call,
        response.decision,
        source,
    );
    outcome.human_approval = humanApprovalProvenance(response.decision);
    if (response.decision == .deny) outcome.denial_reason = .user_denied;
    outcome.feedback = try copyPermissionFeedback(arena, response);
    return outcome;
}

fn humanApprovalProvenance(
    decision: ToolPermissionDecision,
) command_admission.HumanApprovalProvenance {
    return switch (decision) {
        .once => .once,
        .always => .always,
        .deny, .policy_denied, .permission_required => .none,
    };
}

/// Blocks on the configured interactive permission prompter and converts the
/// response into an outcome.
fn promptPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    auto_review_result: ?permission_auto_classifier.Result,
    label_override: ?[]const u8,
    unavailable_requirement: command_admission.PermissionRequirement,
) !command_admission.PermissionOutcome {
    const request = try interactivePermissionRequest(input, arena, call, label_override);
    const unavailable: command_admission.PermissionOutcome = .{
        .decision = .permission_required,
        .denial_reason = .permission_required,
        .requirement = unavailable_requirement,
        .auto_review_result = auto_review_result,
    };
    const prompter = input.permission_prompter orelse return unavailable;
    const grant_offer = if (try isRunCommandCall(input, arena, call))
        try exactApprovalLocalGrants(input, arena, call, &.{}, .ordinary)
    else
        null;
    var response = prompter.request(
        std.heap.c_allocator,
        request,
        call,
        null,
        grant_offer,
    ) catch |err| switch (err) {
        error.PermissionPromptUnavailable => return unavailable,
        else => return err,
    };
    defer response.deinit();
    var outcome = try permissionOutcomeForResponse(
        input,
        arena,
        call,
        &response,
        if (response.decision == .always) .interactive_always else .interactive_once,
    );
    outcome.auto_review_result = auto_review_result;
    return outcome;
}

fn requestWorkerPermission(
    raw: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    _: ToolCall,
    review: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    const worker: *WorkerRuntime = @ptrCast(@alignCast(raw));
    return worker.requestPermissionBlockingWithReview(alloc, request, review);
}

pub fn workerPrompter(worker: *WorkerRuntime) permission_prompter.Prompter {
    return .{
        .context = @ptrCast(worker),
        .request_fn = requestWorkerPermission,
    };
}

fn copyPermissionFeedback(
    arena: Allocator,
    response: *const permission_request.OwnedPermissionResponse,
) !?[]const u8 {
    const feedback = response.feedback orelse return null;
    if (feedback.len == 0) return null;
    return @as([]const u8, try arena.dupe(u8, feedback));
}

fn defaultRunCommandPermissionOutcome(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
) command_admission.PermissionOutcome {
    const command_ctx = runCommandContext(input, arena, call) catch {
        return .{ .decision = .permission_required };
    };
    return switch (command_admission.defaultForRunCommand(
        arena,
        command_ctx,
        permission_mode,
    )) {
        .direct_only => |fingerprint| .{
            .decision = .once,
            .execution_authority = .{ .run_command = .{ .direct_only = fingerprint } },
        },
        .approval_required => .{ .decision = .permission_required },
    };
}

pub fn runCommandContext(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !command_admission.CommandContext {
    if (!try isRunCommandCall(input, arena, call)) return error.NotRunCommand;
    const args = try tool_args.parseToolArgsObject(arena, call.arguments_json);
    const command = try tool_args.requiredStringArg(args, "command");
    const tool = registeredTool(input, call.name) orelse return error.NotRunCommand;
    const cwd = switch (tool.captured_command_host) {
        .workspace_clean => try arena.dupe(u8, input.workspace_root),
        .native => blk: {
            const cwd_arg = tool_args.nullablePlaceholderStringArg(args, "cwd") orelse ".";
            break :blk if (std.mem.eql(u8, cwd_arg, "."))
                try arena.dupe(u8, input.workspace_root)
            else
                try pathing.resolveWorkspaceOrExternalPath(arena, input.workspace_root, cwd_arg);
        },
    };
    const environment_value: command_environment.Environment = switch (tool.captured_command_host) {
        .workspace_clean => .workspace_clean,
        .native => blk: {
            const profile_raw = tool_args.nullablePlaceholderStringArg(args, "profile");
            const profile: ?command_environment.Profile = if (profile_raw) |raw|
                std.meta.stringToEnum(command_environment.Profile, raw) orelse
                    return error.InvalidCommandProfile
            else
                null;
            var login_shell_buffer: [4096]u8 = undefined;
            const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
            break :blk try shell_resolver.environment(arena, configured, profile);
        },
    };
    return .{
        .command = command,
        .resolved_cwd = cwd,
        .background = false,
        .target_os = builtin.os.tag,
        .environment = environment_value,
    };
}

pub fn permissionStateKeyForCall(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !session_permission_state.RuleKey {
    if (file_mutation_contract.isToolName(call.name)) {
        return error.PreparedFileMutationRequired;
    }
    if (try isRunCommandCall(input, arena, call)) {
        const command = try runCommandContext(input, arena, call);
        return session_permission_state.commandKeyV2(
            arena,
            command.command,
            command.resolved_cwd,
            if (command.background) "background" else "foreground",
            @tagName(command.target_os),
        );
    }

    var canonical: std.Io.Writer.Allocating = .init(arena);
    defer canonical.deinit();
    try writeIdentityField(&canonical.writer, "fx-permission-state-v1");
    var targets = try permissionTargetsForCall(input, arena, call);
    defer targets.deinit(arena);
    try writeIdentityField(&canonical.writer, call.name);
    try writeIdentityField(&canonical.writer, call.arguments_json);
    for (targets.items) |target| {
        try writeIdentityField(&canonical.writer, target.role);
        try writeIdentityField(&canonical.writer, target.path);
    }
    const bytes = try canonical.toOwnedSlice();
    return session_permission_state.RuleKey.init(.structured_tool, bytes);
}

pub const PreparedPermissionStateAction = struct {
    key: session_permission_state.RuleKey,
    display_identity: []const u8,
};

pub fn preparePermissionStateAction(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) !PreparedPermissionStateAction {
    if (!file_mutation_contract.isToolName(call.name)) {
        const request = try interactivePermissionRequest(input, arena, call, null);
        return .{
            .key = try permissionStateKeyForCall(input, arena, call),
            .display_identity = try arena.dupe(u8, request.label),
        };
    }

    var prepared_call = switch (try prepareFileMutationCall(arena, call, .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
    })) {
        .prepared => |prepared| prepared,
        .tool_failure => return error.PermissionStatePreparationFailed,
    };
    defer prepared_call.deinit(arena);
    const preflight = try preflightPreparedFileMutation(arena, call, &prepared_call, .{
        .tool_registry = input.tool_registry,
        .workspace_root = input.workspace_root,
        .access_scope = input.access_scope,
        .permission_rules = input.permission_rules,
        .permission_mode = .ask,
        .can_prompt = true,
        .prepare_permission_identity = true,
    });
    const authorization = switch (preflight) {
        .allowed, .prompt, .permission_required => |authorization| authorization,
        .policy_denied => return error.PermissionStatePreparationDenied,
        .tool_failure => return error.PermissionStatePreparationFailed,
    };
    const prepared = authorization.prepared orelse
        return error.PermissionStatePreparationFailed;
    return .{
        .key = try permissionStateKeyForPreparedFileMutation(arena, prepared),
        .display_identity = try filePermissionStateDisplay(arena, prepared),
    };
}

fn permissionStateKeyForPreparedFileMutation(
    arena: Allocator,
    prepared: file_mutation_contract.PreparedFileMutation,
) !session_permission_state.RuleKey {
    var canonical: std.Io.Writer.Allocating = .init(arena);
    defer canonical.deinit();
    try writeIdentityField(&canonical.writer, "fx-permission-state-file-v1");
    try writeIdentityField(&canonical.writer, prepared.tool_name);
    try writeIdentityField(&canonical.writer, &prepared.arguments_hash);
    try writeIdentityField(&canonical.writer, prepared.target_path);
    try writeIdentityField(&canonical.writer, @tagName(prepared.kind));
    switch (prepared.preimage) {
        .absent => try writeIdentityField(&canonical.writer, "preimage-absent"),
        .present => |preimage| {
            try writeIdentityField(&canonical.writer, "preimage-present");
            try writeIdentityField(&canonical.writer, &preimage.content_hash);
        },
    }
    var after_hash: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared.after_content, &after_hash, .{});
    try writeIdentityField(&canonical.writer, &after_hash);
    for (prepared.policy_targets.items) |target| {
        try writeIdentityField(
            &canonical.writer,
            prepared.policy_targets.canonical_target_path[0..target.path_end],
        );
        try writeIdentityField(&canonical.writer, @tagName(target.kind));
        try writeIdentityField(&canonical.writer, @tagName(target.disposition));
        if (target.expected_identity) |identity| {
            try writeIdentityU64(&canonical.writer, identity.device);
            try writeIdentityU64(&canonical.writer, identity.inode);
            try writeIdentityField(&canonical.writer, @tagName(identity.kind));
        } else {
            try writeIdentityField(&canonical.writer, "identity-absent");
        }
    }
    const bytes = try canonical.toOwnedSlice();
    return session_permission_state.RuleKey.init(.file_mutation, bytes);
}

fn filePermissionStateDisplay(
    arena: Allocator,
    prepared: file_mutation_contract.PreparedFileMutation,
) ![]const u8 {
    var after_hash: types.ContentHash = undefined;
    std.crypto.hash.sha2.Sha256.hash(prepared.after_content, &after_hash, .{});
    const after_hex = std.fmt.bytesToHex(after_hash[0..8].*, .lower);
    return switch (prepared.preimage) {
        .absent => try std.fmt.allocPrint(
            arena,
            "{s} {s} preimage=absent after={s}",
            .{ prepared.tool_name, prepared.display_path, &after_hex },
        ),
        .present => |preimage| blk: {
            const before_hex = std.fmt.bytesToHex(
                preimage.content_hash[0..8].*,
                .lower,
            );
            break :blk try std.fmt.allocPrint(
                arena,
                "{s} {s} preimage={s} after={s}",
                .{ prepared.tool_name, prepared.display_path, &before_hex, &after_hex },
            );
        },
    };
}

fn writeIdentityU64(writer: *std.Io.Writer, value: u64) !void {
    var bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    try writeIdentityField(writer, &bytes);
}

fn writeIdentityField(writer: *std.Io.Writer, value: []const u8) !void {
    const value_len = std.math.cast(u64, value.len) orelse
        return error.InvalidPermissionIdentity;
    var length: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &length, value_len, .big);
    try writer.writeAll(&length);
    try writer.writeAll(value);
}

fn interactivePermissionRequest(
    input: Input,
    arena: Allocator,
    call: ToolCall,
    label_override: ?[]const u8,
) !permission_request.PermissionRequest {
    if (try isRunCommandCall(input, arena, call)) {
        const context = try runCommandContext(input, arena, call);
        if (label_override) |label| {
            return .{
                .label = label,
                .amendment_allowed = true,
            };
        }
        return .{
            .label = try tool_presentation.formatRunCommandPermissionLabel(
                arena,
                context.command,
            ),
            .command = try command_environment.formatApprovalCommand(
                arena,
                context.environment,
                context.command,
            ),
            .amendment_allowed = true,
        };
    }
    const tool_arguments_preview = if (isAvailableDynamicTool(input, call.name)) blk: {
        const encoded = try text_utils.encodeTerminalSafe(
            arena,
            call.arguments_json,
            permission_request.max_tool_arguments_preview_bytes,
        );
        break :blk encoded.bytes;
    } else null;
    return .{
        .label = label_override orelse try tool_presentation.formatPermissionLabel(
            arena,
            input.tool_registry,
            call,
        ),
        .tool_arguments_preview = tool_arguments_preview,
    };
}

fn formatVisionPathPermissionLabel(
    arena: Allocator,
    authority: command_admission.VisionPathExecutionAuthority,
) ![]const u8 {
    var label_len: usize = "vision ".len;
    for (authority.targets, 0..) |target, index| {
        if (index > 0) label_len = std.math.add(usize, label_len, ", ".len) catch
            return error.RequestProjectionTooLarge;
        label_len = std.math.add(usize, label_len, target.canonical_path.len) catch
            return error.RequestProjectionTooLarge;
        if (label_len > diff_mod.max_encoded_label_bytes) {
            return error.RequestProjectionTooLarge;
        }
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try out.writer.writeAll("vision ");
    for (authority.targets, 0..) |target, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(target.canonical_path);
    }
    return try out.toOwnedSlice();
}

fn noninteractivePermissionRequired(call: ToolCall, reason: []const u8) ToolPermissionDecision {
    debug_trace.logf(
        "core",
        "tool permission unavailable mode=headless approval_required=true reason={s} tool={s}",
        .{ reason, call.name },
    );
    return .permission_required;
}

pub fn permissionTargetResolutionFailureMessage(
    arena: Allocator,
    tool_name: []const u8,
    err: anyerror,
) !?[]const u8 {
    return switch (err) {
        error.PathOutsideWorkspace,
        error.FileNotFound,
        error.HomeNotSet,
        error.InvalidPath,
        error.WorkspaceUnavailable,
        => try std.fmt.allocPrint(
            arena,
            "Permission target resolution failed for {s}: {s}",
            .{ tool_name, @errorName(err) },
        ),
        else => null,
    };
}

fn permissionTargetsForCall(input: Input, arena: Allocator, call: ToolCall) !permissions.PermissionCallTargets {
    if (isAvailableDynamicTool(input, call.name)) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        items[0] = .{ .role = "target", .path = try arena.dupe(u8, call.name) };
        return .{ .items = items };
    }
    if (registeredWebSearchTarget(input, call.name)) |target_name| {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{
            .role = "target",
            .path = try arena.dupe(u8, target_name),
        };
        return .{ .items = items };
    }
    const tool = registeredTool(input, call.name) orelse return error.UnsupportedTool;
    if (try isRunCommandCall(input, arena, call)) {
        const items = try arena.alloc(permissions.PermissionCallTarget, 1);
        errdefer arena.free(items);
        items[0] = .{
            .role = "target",
            .path = try commandPermissionTarget(input, arena, call),
        };
        return .{ .items = items };
    }
    return permissions.permissionTargetsForCallInScope(
        arena,
        accessScope(input),
        call,
        tool.permission_target_kind,
    );
}

fn commandPermissionTarget(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) ![]u8 {
    const context = try runCommandContext(input, arena, call);
    const identity = try command_environment.permissionCommandIdentity(
        arena,
        context.environment,
        context.command,
    );
    return std.fmt.allocPrint(
        arena,
        "{s}::{s}",
        .{ context.resolved_cwd, identity },
    );
}

fn sessionGrantsAllowAll(grants: []const PermissionGrant, tool_name: []const u8, targets: []const permissions.PermissionCallTarget) bool {
    for (targets) |target| {
        if (!permissions.sessionGrantAllowed(grants, tool_name, target.path)) return false;
    }
    return true;
}

pub fn permissionTargetForCall(input: Input, arena: Allocator, call: ToolCall) ![]const u8 {
    if (isAvailableDynamicTool(input, call.name)) return arena.dupe(u8, call.name);
    if (registeredWebSearchTarget(input, call.name)) |target_name| return arena.dupe(u8, target_name);
    const tool = registeredTool(input, call.name) orelse return error.UnsupportedTool;
    if (try isRunCommandCall(input, arena, call)) {
        return commandPermissionTarget(input, arena, call);
    }
    return permissions.permissionTargetForCallInScope(
        arena,
        accessScope(input),
        call,
        tool.permission_target_kind,
    );
}

/// Resolves the target used only for inherited live-authority checks. A
/// missing existing-path target still needs an authority decision before the
/// tool itself can return its ordinary structured failure.
pub fn permissionTargetForLiveAuthority(
    input: Input,
    arena: Allocator,
    call: ToolCall,
) ![]const u8 {
    return permissionTargetForCall(input, arena, call) catch |err| {
        if (!recoverableExistingPathResolutionFailure(err)) return err;
        const tool = registeredTool(input, call.name) orelse return err;
        if (tool.permission_target_kind != .path_existing) {
            return err;
        }
        return permissions.missingPathTargetForCallInScope(
            arena,
            accessScope(input),
            call,
        ) catch |fallback_err| {
            if (!recoverableExistingPathResolutionFailure(fallback_err)) {
                return fallback_err;
            }
            return permissions.unresolvedPathTargetForCallInScope(
                arena,
                accessScope(input),
                call,
            );
        };
    };
}

fn recoverableExistingPathResolutionFailure(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        error.PermissionDenied,
        => true,
        else => false,
    };
}

fn isAvailableDynamicTool(input: Input, name: []const u8) bool {
    return tool_mcp_runtime.isAvailableDynamicTool(.{
        .is_registered_tool = registeredTool(input, name) != null,
        .advertised_dynamic_tool_names = input.advertised_dynamic_tool_names,
        .runtime = input.mcp_runtime,
    }, name);
}

fn checkFileMutationPreparationAllocationFailures(alloc: Allocator, workspace: []const u8) !void {
    var prepared = switch (try prepareFileMutationCall(alloc, .{
        .id = "allocation-write",
        .name = "write_file",
        .arguments_json = "{\"path\":\"nested/file.txt\",\"content\":\"hello\\n\"}",
    }, .{
        .tool_registry = test_admission_registry,
        .workspace_root = workspace,
    })) {
        .tool_failure => return error.TestExpectedPreparedFileMutation,
        .prepared => |value| value,
    };
    defer prepared.deinit(alloc);
}

fn decodeRegistryOwnedWrite(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    if (!std.mem.eql(u8, args_json, "registry-owned")) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "expected registry-owned write input",
        ) };
    }
    return test_builtin_tools.write_file.decode(
        ctx,
        "{\"path\":\"registered.txt\",\"content\":\"registered\\n\"}",
    );
}

const FakeAutoClassifier = struct {
    calls: usize = 0,
    decision: permission_auto_classifier.Decision = .clear,
    risk: permission_auto_classifier.Risk = .low,
    rationale: []const u8 = "test automatic review",
    invalid: bool = false,
    review_model: []const u8 = "",
    review_root_text: []const u8 = "",
    review_target_call_id: []const u8 = "",
    review_untrusted_message_count: usize = 0,
    proven_current_branch: ?[]const u8 = null,
    action_provenance: permission_auto_classifier.ActionProvenance = .not_observed,
    action_tag: ?std.meta.Tag(permission_auto_classifier.Action) = null,
    exact_command: ?[]const u8 = null,
    exact_arguments_json: ?[]const u8 = null,
    schema_json: ?[]const u8 = null,
    file_display_path: ?[]const u8 = null,
    file_additions: usize = 0,
    file_deletions: usize = 0,
    file_review_rows: usize = 0,

    fn classify(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        request: permission_auto_classifier.ReviewRequest,
    ) anyerror!permission_auto_classifier.ParseOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        self.review_model = request.review_turn.model;
        self.review_root_text = request.review_turn.current_root_request;
        self.review_target_call_id = request.review_turn.target_call_id;
        self.review_untrusted_message_count = request.review_turn.current_turn_untrusted_messages.len;
        self.proven_current_branch = request.proven_bindings.current_branch;
        self.action_provenance = request.action_provenance;
        self.action_tag = std.meta.activeTag(request.action);
        switch (request.action) {
            .command => |command| self.exact_command = command.command,
            .file_mutation => |file| {
                self.file_display_path = file.display_path;
                self.file_additions = file.additions;
                self.file_deletions = file.deletions;
                var viewport = try file.review.viewport(alloc, 0, 1);
                defer viewport.deinit(alloc);
                self.file_review_rows = viewport.total_rows;
            },
            .tool => |tool| {
                self.exact_arguments_json = tool.arguments_json;
                self.schema_json = tool.schema_json;
            },
        }
        if (self.invalid) return .invalid;
        return .{ .valid = .{
            .risk = self.risk,
            .decision = self.decision,
            .rationale = try alloc.dupe(u8, self.rationale),
        } };
    }
};

const test_admission_registry = tool_dispatch.Registry{ .tools = &.{
    test_builtin_tools.glob_files,
    test_builtin_tools.terminal,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
} };

fn testInputWithClassifier(
    worker: *WorkerRuntime,
    background: *BackgroundRuntime,
    classifier: permission_auto_classifier.Classifier,
) Input {
    return .{
        .workspace_root = "/tmp/workspace",
        .permission_grants = &.{},
        .permission_rules = .{},
        .tool_registry = test_admission_registry,
        .worker = worker,
        .background = background,
        .advertised_dynamic_tool_names = &.{},
        .mcp_runtime = .{},
        .auto_classifier = classifier,
        .permission_review_turn = testReviewTurn(),
    };
}

const test_review_tool_calls = [_]ToolCall{
    .{ .id = "test-review", .name = "terminal", .arguments_json = "{\"action\":\"exec\",\"command\":\"printf test\"}" },
};
const test_review_root_messages = [_][]const u8{"test root request"};

fn testReviewTurn() permission_auto_classifier.ReviewTurnContext {
    return .{
        .model = "openai/gpt-5",
        .pending_assistant = .{ .role = .assistant, .tool_calls = &test_review_tool_calls },
        .target_call_id = "test-review",
        .origin = .root,
        .current_root_request = test_review_root_messages[0],
    };
}

const RecordingPrompter = struct {
    calls: usize = 0,
    decision: ToolPermissionDecision = .once,
    last_call_id: ?[]const u8 = null,
    last_label_len: usize = 0,
    last_label: ?[]const u8 = null,
    last_command: ?[]const u8 = null,
    last_grant_offer: ?[]const PermissionGrant = null,

    fn request(
        raw: *anyopaque,
        alloc: Allocator,
        request_view: permission_request.PermissionRequest,
        call: ToolCall,
        _: ?*const diff_mod.FileReview,
        grant_offer: ?[]const PermissionGrant,
    ) anyerror!permission_request.OwnedPermissionResponse {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last_call_id = call.id;
        self.last_label_len = request_view.label.len;
        self.last_label = request_view.label;
        self.last_command = request_view.command;
        self.last_grant_offer = grant_offer;
        return permission_request.OwnedPermissionResponse.init(alloc, self.decision, null);
    }

    fn prompter(self: *@This()) permission_prompter.Prompter {
        return .{ .context = @ptrCast(self), .request_fn = request };
    }
};
