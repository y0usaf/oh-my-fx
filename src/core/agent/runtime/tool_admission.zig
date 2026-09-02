const std = @import("std");
const builtin = @import("builtin");
const permission_auto_classifier = @import("../../permissions/auto_classifier.zig");
const command_admission = @import("../../permissions/command_admission.zig");
const permissions = @import("../../permissions/permissions.zig");
const types = @import("../../shared/types.zig");
const pathing = @import("../../workspace/pathing.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const file_mutation_contract = @import("../../tooling/file_mutation_contract.zig");
const tooling_tool_admission = @import("../../tooling/tool_admission.zig");
const tool_dispatch = @import("../../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../../builtins/tools.zig")
else
    struct {};
const io_mod = @import("../../shared/io.zig");

const runtime_deps = @import("deps.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolCall = types.ToolCall;
const ToolPermissionDecision = types.ToolPermissionDecision;
const TraceContext = debug_trace.TraceContext;
const AgentRuntimeDeps = runtime_deps.AgentRuntimeDeps;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

const TerminalValidationDigest = [std.crypto.hash.sha2.Sha256.digest_length]u8;
const PermissionActionId = [std.crypto.hash.sha2.Sha256.digest_length]u8;
const max_turn_review_cautions: usize = 64;
const max_consecutive_malformed_argument_batches: usize = 3;

const CachedCaution = struct {
    exact_id: PermissionActionId,
    risk: permission_auto_classifier.Risk,
    rationale: []u8,
};

pub const TurnReviewCache = struct {
    cautions: std.ArrayList(CachedCaution) = .empty,

    pub fn deinit(self: *TurnReviewCache, alloc: Allocator) void {
        for (self.cautions.items) |entry| alloc.free(entry.rationale);
        self.cautions.deinit(alloc);
        self.* = .{};
    }

    pub fn rememberCaution(
        self: *TurnReviewCache,
        alloc: Allocator,
        call: ToolCall,
        outcome: command_admission.PermissionOutcome,
    ) Allocator.Error!void {
        if (outcome.denial_reason != .review_caution) return;
        const review = outcome.auto_review_result orelse return;
        if (review.decision != .caution) return;
        const exact_id = permissionActionId(call);
        for (self.cautions.items) |entry| {
            if (std.mem.eql(u8, &entry.exact_id, &exact_id)) return;
        }
        if (self.cautions.items.len == max_turn_review_cautions) return;
        const rationale = try alloc.dupe(u8, review.rationale);
        errdefer alloc.free(rationale);
        try self.cautions.append(alloc, .{
            .exact_id = exact_id,
            .risk = review.risk,
            .rationale = rationale,
        });
    }

    pub fn cachedCaution(
        self: *const TurnReviewCache,
        call: ToolCall,
    ) ?command_admission.PermissionOutcome {
        const exact_id = permissionActionId(call);
        for (self.cautions.items) |entry| {
            if (!std.mem.eql(u8, &entry.exact_id, &exact_id)) continue;
            return .{
                .decision = .deny,
                .denial_reason = .review_caution,
                .auto_review_result = .{
                    .risk = entry.risk,
                    .decision = .caution,
                    .rationale = entry.rationale,
                },
            };
        }
        return null;
    }
};

fn permissionActionId(call: ToolCall) PermissionActionId {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.permission-action.v1\x00");
    hash.update(call.name);
    hash.update("\x00");
    hash.update(call.arguments_json);
    return hash.finalResult();
}

const TerminalValidationDigestDecision = struct {
    append_current: bool,
    repeated: bool,
};

fn containsTerminalValidationDigest(
    digests: []const TerminalValidationDigest,
    wanted: TerminalValidationDigest,
) bool {
    for (digests) |digest| {
        if (std.mem.eql(u8, digest[0..], wanted[0..])) return true;
    }
    return false;
}

fn terminalValidationDigestDecision(
    previous: []const TerminalValidationDigest,
    current: []const TerminalValidationDigest,
    digest: TerminalValidationDigest,
) TerminalValidationDigestDecision {
    return .{
        .append_current = !containsTerminalValidationDigest(current, digest),
        .repeated = containsTerminalValidationDigest(previous, digest),
    };
}

pub const TerminalValidationRetryState = struct {
    previous: std.ArrayList(TerminalValidationDigest) = .empty,
    current: std.ArrayList(TerminalValidationDigest) = .empty,
    stop_after_batch: bool = false,

    pub fn deinit(self: *TerminalValidationRetryState, alloc: Allocator) void {
        self.previous.deinit(alloc);
        self.current.deinit(alloc);
        self.* = .{};
    }

    pub fn beginBatch(self: *TerminalValidationRetryState) void {
        self.current.clearRetainingCapacity();
        self.stop_after_batch = false;
    }

    pub fn observe(
        self: *TerminalValidationRetryState,
        alloc: Allocator,
        call: ToolCall,
        model_output: []const u8,
    ) Allocator.Error!void {
        if (!std.mem.eql(u8, call.name, "terminal")) return;
        if (try tool_result_errors.inspectTerminalActionFieldCorrection(
            alloc,
            model_output,
        ) == null) return;

        var digest: TerminalValidationDigest = undefined;
        std.crypto.hash.sha2.Sha256.hash(model_output, &digest, .{});
        const decision = terminalValidationDigestDecision(
            self.previous.items,
            self.current.items,
            digest,
        );
        if (decision.append_current) try self.current.append(alloc, digest);
        self.stop_after_batch = self.stop_after_batch or decision.repeated;
    }

    pub fn finishBatch(self: *TerminalValidationRetryState) bool {
        if (self.stop_after_batch) return true;
        const previous = self.previous;
        self.previous = self.current;
        self.current = previous;
        self.current.clearRetainingCapacity();
        return false;
    }
};

pub const MalformedArgumentsRetryState = struct {
    consecutive_malformed_batches: usize = 0,
    current_call_count: usize = 0,
    current_malformed_count: usize = 0,

    pub fn beginBatch(self: *MalformedArgumentsRetryState) void {
        self.current_call_count = 0;
        self.current_malformed_count = 0;
    }

    pub fn observe(self: *MalformedArgumentsRetryState, call: ToolCall) void {
        self.current_call_count += 1;
        if (call.argument_integrity != .malformed_json) return;
        self.current_malformed_count += 1;
    }

    pub fn finishBatch(self: *MalformedArgumentsRetryState) bool {
        const all_malformed = self.current_call_count > 0 and
            self.current_call_count == self.current_malformed_count;
        if (!all_malformed) {
            self.consecutive_malformed_batches = 0;
            return false;
        }
        if (self.consecutive_malformed_batches < max_consecutive_malformed_argument_batches) {
            self.consecutive_malformed_batches += 1;
        }
        return self.consecutive_malformed_batches == max_consecutive_malformed_argument_batches;
    }
};

/// Human denials retained only for the current agent turn. Entries use the
/// canonical external file action rather than the provider's tool-call ID.
pub const TurnFileMutationDenials = struct {
    identities: std.ArrayList(
        tooling_tool_admission.FileMutationActionIdentity,
    ) = .empty,

    pub noinline fn deinit(self: *TurnFileMutationDenials, alloc: Allocator) void {
        self.identities.deinit(alloc);
        self.* = .{};
    }

    pub fn rememberHumanDenial(
        self: *TurnFileMutationDenials,
        alloc: Allocator,
        identity: tooling_tool_admission.FileMutationActionIdentity,
        outcome: command_admission.PermissionOutcome,
    ) Allocator.Error!void {
        const reason = outcome.denial_reason orelse
            outcome.decision.denialReason() orelse return;
        if (outcome.decision != .deny or reason != .user_denied) return;
        if (self.preservedOutcome(identity) != null) return;
        try self.identities.append(alloc, identity);
    }

    pub fn preservedOutcome(
        self: TurnFileMutationDenials,
        identity: tooling_tool_admission.FileMutationActionIdentity,
    ) ?command_admission.PermissionOutcome {
        for (self.identities.items) |denied| {
            if (denied.eql(identity)) {
                return .{
                    .decision = .deny,
                    .denial_reason = .user_denied,
                };
            }
        }
        return null;
    }
};

pub fn deferVisibleLifecycleUntilAfterPermission(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "web_fetch") or
        file_mutation_contract.isToolName(tool_name);
}

pub fn deferCapturedCommandLifecycleForAutoPermissionNotice(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
    permission_mode: PermissionMode,
    interactive_presentation: bool,
) !bool {
    return interactive_presentation and
        permission_mode == .auto and
        try tooling_tool_admission.callUsesCommandAuthority(
            registry,
            arena,
            call,
        );
}

pub fn requestToolPermissionTraced(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    review_turn: permission_auto_classifier.ReviewTurnContext,
    mode: PermissionMode,
    local_grants: []const PermissionGrant,
    live_authority: ?runtime_tool_contracts.LiveToolAuthority,
    revalidation: ?runtime_tool_contracts.LivePermissionRevalidation,
    advertised_dynamic_tool_names: []const []const u8,
    workspace_root: []const u8,
    ctx: TraceContext,
) !command_admission.PermissionOutcome {
    const target_class = classifyPermissionTarget(hooks, arena, call, advertised_dynamic_tool_names, workspace_root);
    tracePermissionRequest(call, mode, local_grants.len, target_class, ctx);
    const outcome = hooks.request_tool_permission(hooks.ctx, arena, call, review_turn, mode, local_grants, live_authority, revalidation, advertised_dynamic_tool_names) catch |err| {
        return permissionErrorOutcome(arena, call, mode, err, target_class, ctx);
    };
    tracePermissionOutcome(call, mode, local_grants.len, target_class, ctx, outcome);
    return outcome;
}

pub fn requestPreparedFileMutationPermissionTraced(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    prepared: *tooling_tool_admission.PreparedFileMutationCall,
    review_turn: permission_auto_classifier.ReviewTurnContext,
    mode: PermissionMode,
    local_grants: []const PermissionGrant,
    live_authority: ?runtime_tool_contracts.LiveToolAuthority,
    advertised_dynamic_tool_names: []const []const u8,
    workspace_root: []const u8,
    ctx: TraceContext,
) !command_admission.PermissionOutcome {
    const target_class = classifyPermissionTarget(hooks, arena, call, advertised_dynamic_tool_names, workspace_root);
    tracePermissionRequest(call, mode, local_grants.len, target_class, ctx);
    const request = hooks.request_prepared_file_mutation_permission orelse {
        return permissionErrorOutcome(
            arena,
            call,
            mode,
            error.PreparedFileMutationPermissionUnavailable,
            target_class,
            ctx,
        );
    };
    const outcome = request(hooks.ctx, arena, call, prepared, review_turn, mode, local_grants, live_authority, advertised_dynamic_tool_names) catch |err| {
        return permissionErrorOutcome(arena, call, mode, err, target_class, ctx);
    };
    tracePermissionOutcome(call, mode, local_grants.len, target_class, ctx, outcome);
    return outcome;
}

fn tracePermissionRequest(
    call: ToolCall,
    mode: PermissionMode,
    local_grant_count: usize,
    target_class: []const u8,
    ctx: TraceContext,
) void {
    debug_trace.eventf("permission", "before_permission_wait", ctx, "call_id={s} tool_name={s} permission_mode={s} local_grants={d} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), local_grant_count, target_class });
    debug_trace.eventf("permission", "permission_requested", ctx, "call_id={s} tool_name={s} permission_mode={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), target_class });
}

fn permissionErrorOutcome(
    arena: Allocator,
    call: ToolCall,
    mode: PermissionMode,
    err: anyerror,
    target_class: []const u8,
    ctx: TraceContext,
) anyerror!command_admission.PermissionOutcome {
    if (try tooling_tool_admission.permissionTargetResolutionFailureMessage(arena, call.name, err)) |failure| {
        debug_trace.eventf("permission", "permission_target_resolution_error", ctx, "call_id={s} tool_name={s} permission_mode={s} err={s} outside_workspace={s} approval_source=tool_layer", .{ call.id, call.name, @tagName(mode), @errorName(err), target_class });
        return .{ .tool_failure = failure };
    }
    debug_trace.eventf("permission", "permission_error", ctx, "call_id={s} tool_name={s} permission_mode={s} err={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), @errorName(err), target_class });
    return err;
}

fn tracePermissionOutcome(
    call: ToolCall,
    mode: PermissionMode,
    local_grant_count: usize,
    target_class: []const u8,
    ctx: TraceContext,
    outcome: command_admission.PermissionOutcome,
) void {
    const source = permissionOutcomeSource(outcome, mode, local_grant_count);
    if (outcome.tool_failure) |failure| {
        debug_trace.eventf("permission", "after_permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision=tool_failure approval_source={s} outside_workspace={s} model_output_bytes={d}", .{ call.id, call.name, @tagName(mode), source, target_class, failure.len });
        debug_trace.eventf("permission", "permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision=tool_failure approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), source, target_class });
    } else {
        debug_trace.eventf("permission", "after_permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision={s} approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), permissionDecisionName(outcome.decision), source, target_class });
        debug_trace.eventf("permission", "permission_decision", ctx, "call_id={s} tool_name={s} permission_mode={s} decision={s} approval_source={s} outside_workspace={s}", .{ call.id, call.name, @tagName(mode), permissionDecisionName(outcome.decision), source, target_class });
    }
}

fn classifyPermissionTarget(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8, workspace_root: []const u8) []const u8 {
    if (file_mutation_contract.isToolName(call.name)) return "unknown";
    const target = hooks.permission_target_for_call(hooks.ctx, arena, call, advertised_dynamic_tool_names) catch |err| {
        return if (err == error.PathOutsideWorkspace) "true" else "unknown";
    };
    const path_part = if (std.mem.indexOf(u8, target, "::")) |sep| target[0..sep] else target;
    if (!std.fs.path.isAbsolute(path_part)) return "not_path";
    return if (pathing.pathInside(workspace_root, path_part)) "false" else "true";
}

fn permissionOutcomeSource(
    outcome: command_admission.PermissionOutcome,
    mode: PermissionMode,
    local_grant_count: usize,
) []const u8 {
    if (outcome.tool_failure != null) return "tool_failure";
    if (outcome.decision.isDenied()) return "denied";
    if (outcome.execution_authority) |authority| {
        switch (authority) {
            .ordinary => {},
            .run_command => |command_authority| switch (command_authority) {
                .direct_only => return "direct_only",
                .shell_allowed => |shell| return @tagName(shell.source),
            },
            .file_mutation => return "file_mutation",
            .vision_paths => return "vision_paths",
        }
    }
    if (local_grant_count > 0) return "session_grant_or_rule";
    return switch (mode) {
        .auto => "auto_or_rule",
        .ask => "interactive_or_rule",
        .yolo => "yolo",
    };
}

pub noinline fn permissionDeniedStatusLabel(reason: types.ToolPermissionDenialReason) []const u8 {
    return switch (reason) {
        .user_denied => "Denied",
        .auto_denied => "Denied by auto agent",
        .review_caution => "Safety caution",
        .review_unavailable => "Review unavailable",
        .policy_denied => "Denied",
        .permission_required => "Permission required",
    };
}

fn permissionDecisionName(decision: ToolPermissionDecision) []const u8 {
    return @tagName(decision);
}

pub fn retainSessionGrant(hooks: *const AgentRuntimeDeps, arena: Allocator, local_grants: *std.ArrayList(PermissionGrant), permission: []const u8, pattern: []const u8) !void {
    const grant = PermissionGrant{
        .tool_name = try arena.dupe(u8, permission),
        .target_path = try arena.dupe(u8, pattern),
    };
    try appendLocalGrant(arena, local_grants, grant);
    try propagateGrant(hooks, grant);
}

pub fn repeatedDynamicMcpFailure(
    arena: Allocator,
    current_turn_messages: []const types.ChatMessage,
    call: ToolCall,
    advertised_dynamic_tool_names: []const []const u8,
) !?ToolExecutionResult {
    if (!containsName(advertised_dynamic_tool_names, call.name)) return null;
    if (!try hasTwoEquivalentDynamicMcpFailures(
        arena,
        current_turn_messages,
        call,
    )) return null;
    return .{
        .status = .failure,
        .model_output = try arena.dupe(
            u8,
            "Repeated MCP tool call blocked: two equivalent attempts failed. Change the top-level argument structure, reselect the tool, ask the user, or stop.",
        ),
    };
}

fn hasTwoEquivalentDynamicMcpFailures(
    arena: Allocator,
    messages: []const types.ChatMessage,
    current_call: ToolCall,
) !bool {
    var matching_failures: usize = 0;
    var batch_end = messages.len;
    while (batch_end > 0) {
        var assistant_index = batch_end;
        var found_assistant = false;
        while (assistant_index > 0) {
            assistant_index -= 1;
            if (messages[assistant_index].role == .assistant) {
                found_assistant = true;
                break;
            }
        }
        if (!found_assistant) return false;

        const calls = messages[assistant_index].tool_calls;
        const results = messages[assistant_index + 1 .. batch_end];
        var completed_calls: usize = 0;
        var matching_in_batch: usize = 0;
        var target_completed = false;
        for (calls) |prior_call| {
            const status = completedResultStatus(results, prior_call) orelse continue;
            completed_calls += 1;
            if (std.mem.eql(u8, prior_call.name, "mcp_select_tool") and
                status == .success)
            {
                return false;
            }
            if (!std.mem.eql(u8, prior_call.name, current_call.name)) continue;
            target_completed = true;
            if (status != .failure or
                !try sameTopLevelArgumentShape(
                    arena,
                    prior_call.arguments_json,
                    current_call.arguments_json,
                ))
            {
                return false;
            }
            matching_in_batch += 1;
        }
        if (target_completed) {
            matching_failures += matching_in_batch;
            if (matching_failures >= 2) return true;
        } else if (completed_calls > 0) {
            return false;
        }
        batch_end = assistant_index;
    }
    return false;
}

fn completedResultStatus(
    messages: []const types.ChatMessage,
    call: ToolCall,
) ?types.PersistedToolStatus {
    var matched: ?types.PersistedToolStatus = null;
    for (messages) |message| {
        if (message.role != .tool) continue;
        const call_id = message.tool_call_id orelse continue;
        if (!std.mem.eql(u8, call_id, call.id)) continue;
        if (matched != null or
            message.tool_name == null or
            !std.mem.eql(u8, message.tool_name.?, call.name) or
            message.tool_result_status == null)
        {
            return null;
        }
        matched = message.tool_result_status.?;
    }
    return matched;
}

fn sameTopLevelArgumentShape(
    alloc: Allocator,
    left_json: []const u8,
    right_json: []const u8,
) Allocator.Error!bool {
    var left = try parseArgumentValue(alloc, left_json);
    defer if (left) |*parsed| parsed.deinit();
    var right = try parseArgumentValue(alloc, right_json);
    defer if (right) |*parsed| parsed.deinit();
    if (left == null or right == null) return left == null and right == null;

    const left_value = left.?.value;
    const right_value = right.?.value;
    if (std.meta.activeTag(left_value) != std.meta.activeTag(right_value)) return false;
    if (left_value != .object) return true;
    if (left_value.object.count() != right_value.object.count()) return false;
    var fields = left_value.object.iterator();
    while (fields.next()) |field| {
        const right_field = right_value.object.get(field.key_ptr.*) orelse return false;
        if (std.meta.activeTag(field.value_ptr.*) != std.meta.activeTag(right_field)) {
            return false;
        }
    }
    return true;
}

fn parseArgumentValue(
    alloc: Allocator,
    bytes: []const u8,
) Allocator.Error!?std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn containsName(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn appendLocalGrant(arena: Allocator, grants: *std.ArrayList(PermissionGrant), grant: PermissionGrant) !void {
    if (permissions.sessionGrantAllowed(grants.items, grant.tool_name, grant.target_path)) return;
    try grants.append(arena, grant);
}

pub fn applyInitialSessionGrants(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    local_grants: *std.ArrayList(PermissionGrant),
    workspace_root: []const u8,
    call: ToolCall,
    target_path: []const u8,
) !void {
    const command_call = try tooling_tool_admission.callUsesCommandAuthority(
        hooks.tool_registry,
        arena,
        call,
    );
    const permission_name = if (command_call) "run_command" else call.name;
    const target_kind = if (command_call)
        tool_dispatch.PermissionTargetKind.command_cwd
    else if (hooks.tool_registry.lookup(call.name)) |tool|
        tool.permission_target_kind
    else
        .none;
    const grants = try permissions.suggestedSessionGrants(
        arena,
        workspace_root,
        permission_name,
        target_path,
        target_kind,
    );
    for (grants) |grant| {
        try appendLocalGrant(arena, local_grants, grant);
        try propagateGrant(hooks, grant);
    }
}

pub fn applyFrozenFileMutationSessionGrants(
    arena: Allocator,
    hooks: *const AgentRuntimeDeps,
    local_grants: *std.ArrayList(PermissionGrant),
    frozen_grants: []const PermissionGrant,
) !void {
    for (frozen_grants) |grant| {
        const existed = permissions.sessionGrantAllowed(
            local_grants.items,
            grant.tool_name,
            grant.target_path,
        );
        try appendLocalGrant(arena, local_grants, grant);
        if (!existed) try propagateGrant(hooks, grant);
    }
}

pub fn appendFrozenFileMutationGrants(
    arena: Allocator,
    grants: *std.ArrayList(PermissionGrant),
    frozen_grants: []const PermissionGrant,
) !void {
    for (frozen_grants) |grant| {
        try appendLocalGrant(arena, grants, grant);
    }
}

fn propagateGrant(hooks: *const AgentRuntimeDeps, grant: PermissionGrant) !void {
    try hooks.propagate_grant(hooks.ctx, grant.tool_name, grant.target_path);
    try hooks.push_event(hooks.ctx, .{ .session_grant = .{
        .tool_name = try std.heap.c_allocator.dupe(u8, grant.tool_name),
        .target_path = try std.heap.c_allocator.dupe(u8, grant.target_path),
    } });
}

pub fn registeredToolValidationFailure(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall) !?ToolExecutionResult {
    return switch (try toolCallValidation(hooks, arena, call)) {
        .not_registered => null,
        .valid => null,
        .failure => |reason| .{ .model_output = reason, .status = .failure },
    };
}

pub fn toolCallValidation(
    hooks: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
) !runtime_tool_contracts.ToolCallValidationResult {
    if (call.provider_result != null) return .{ .valid = .{} };
    const validate = hooks.validate_tool_call orelse return .{ .valid = .{} };
    return validate(hooks.ctx, arena, call);
}

pub fn toolAvailabilityFailure(hooks: *const AgentRuntimeDeps, arena: Allocator, call: ToolCall) !?ToolExecutionResult {
    if (call.provider_result != null) return null;
    const check = hooks.check_tool_availability orelse return null;
    const reason = try check(hooks.ctx, arena, call) orelse return null;
    return .{ .model_output = reason, .status = .failure };
}

pub noinline fn recordRejectedToolCall(
    deps: *const AgentRuntimeDeps,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const record = deps.record_tool_call_rejected orelse return;
    try record(deps.ctx, arena, call, model_output, command_result_json);
}
