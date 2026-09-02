const std = @import("std");
const types = @import("../shared/types.zig");

pub const HookKind = enum {
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,

    pub fn definition(self: HookKind) HookDefinition {
        return switch (self) {
            .pre_tool_use => pre_tool_use,
            .stop => stop,
            .post_turn_end => post_turn_end,
            .attention_required => attention_required,
        };
    }
};

pub const HookDefinition = struct {
    kind: HookKind,
    lifecycle_event: []const u8,
    agent_loop_point: []const u8,
    purpose: []const u8,
};

pub const pre_tool_use = HookDefinition{
    .kind = .pre_tool_use,
    .lifecycle_event = "PreToolUse",
    .agent_loop_point = "before local tool validation, permissions, and execution",
    .purpose = "lets handlers keep a call unchanged, rewrite its arguments, or block it",
};

pub const stop = HookDefinition{
    .kind = .stop,
    .lifecycle_event = "Stop",
    .agent_loop_point = "after a terminal assistant candidate before turn finalization",
    .purpose = "lets handlers allow completion or request one synthetic continuation",
};

pub const post_turn_end = HookDefinition{
    .kind = .post_turn_end,
    .lifecycle_event = "PostTurnEnd",
    .agent_loop_point = "after a terminal turn outcome is accepted",
    .purpose = "lets handlers observe terminal turns and run side effects without changing the turn outcome",
};

pub const attention_required = HookDefinition{
    .kind = .attention_required,
    .lifecycle_event = "AttentionRequired",
    .agent_loop_point = "after a user decision prompt becomes active",
    .purpose = "lets handlers observe when a foreground turn is waiting for user attention",
};

pub const all_hooks = [_]HookDefinition{
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,
};

pub const ScopeKind = enum {
    interactive,
    ask,
    acp,
    subagent,
};

pub const Scope = struct {
    kind: ScopeKind,
    workspace_root: []const u8,
    session_id: ?[]const u8 = null,
    subagent_id: ?u64 = null,
};

pub const Invocation = struct {
    scope: Scope,
    turn_id: ?u64 = null,
};

pub const Limits = struct {
    pub const handler_name_bytes = 128;
    pub const reason_bytes = 4 * 1024;
    pub const context_bytes = 64 * 1024;
    pub const arguments_json_bytes = 1024 * 1024;
};

pub const RegistrationError = error{
    EmptyHandlerName,
    HandlerNameTooLong,
    InvalidHandlerName,
    DuplicateHandlerName,
    RuntimeFrozen,
};

pub const ViewError = error{
    RuntimeNotFrozen,
};

pub const HandlerError = error{
    Failed,
    Cancelled,
};

pub const MutationDispatchError = error{
    OutOfMemory,
    HandlerFailed,
    Cancelled,
    InvalidHandlerOutput,
    HandlerOutputTooLarge,
};

pub const PreToolUseInput = struct {
    invocation: Invocation,
    step_index: usize,
    call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
};

pub const PreToolUseAction = union(enum) {
    continue_,
    rewrite_arguments: []const u8,
    block: []const u8,
};

pub const PreToolUseOutcome = union(enum) {
    unchanged,
    rewritten: []u8,
    blocked: []u8,

    pub fn deinit(self: *PreToolUseOutcome, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .rewritten => |arguments_json| alloc.free(arguments_json),
            .blocked => |reason| alloc.free(reason),
            .unchanged => {},
        }
        self.* = .unchanged;
    }
};

pub const PreToolUseHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: PreToolUseInput,
    ) HandlerError!PreToolUseAction,
};

pub const StopInput = struct {
    invocation: Invocation,
    step_index: usize,
    assistant_text: []const u8,
    provider_disposition: types.ProviderCompletionDisposition,
    can_continue: bool,
};

pub const StopAction = union(enum) {
    allow,
    continue_once: []const u8,
};

pub const StopOutcome = union(enum) {
    allow,
    continue_once: []u8,

    pub fn deinit(self: *StopOutcome, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .continue_once => |context| alloc.free(context),
            .allow => {},
        }
        self.* = .allow;
    }
};

pub const StopHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: StopInput,
    ) HandlerError!StopAction,
};

pub const PostTurnEndInput = struct {
    invocation: Invocation,
    outcome: types.TurnPresentationOutcome,
    provider_disposition: ?types.ProviderCompletionDisposition = null,
};

pub const PostTurnEndHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: PostTurnEndInput,
    ) HandlerError!void,
};

pub const AttentionKind = enum {
    permission,
    question,
    route_recovery,
};

pub const AttentionRequiredInput = struct {
    invocation: Invocation,
    kind: AttentionKind,
};

pub const AttentionRequiredHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: AttentionRequiredInput,
    ) HandlerError!void,
};


