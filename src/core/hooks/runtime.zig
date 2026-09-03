const std = @import("std");
const definitions = @import("definitions.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const HookEvent = definitions.HookKind;

const RegisteredHook = struct {
    event: HookEvent,
    name: []u8,
    ctx: *anyopaque,
};

const RegisteredPreToolUseHandler = struct {
    hook: RegisteredHook,
    run: *const fn (
        ctx: *anyopaque,
        input: definitions.PreToolUseInput,
    ) definitions.HandlerError!definitions.PreToolUseAction,
};

const RegisteredStopHandler = struct {
    hook: RegisteredHook,
    run: *const fn (
        ctx: *anyopaque,
        input: definitions.StopInput,
    ) definitions.HandlerError!definitions.StopAction,
};

fn RegisteredSideEffectHandler(comptime Input: type) type {
    return struct {
        hook: RegisteredHook,
        run: *const fn (*anyopaque, Input) definitions.HandlerError!void,
    };
}

const RegisteredPostTurnEndHandler = RegisteredSideEffectHandler(definitions.PostTurnEndInput);
const RegisteredAttentionRequiredHandler = RegisteredSideEffectHandler(definitions.AttentionRequiredInput);

pub const Runtime = struct {
    alloc: Allocator,
    pre_tool_use_handlers: std.ArrayList(RegisteredPreToolUseHandler) = .empty,
    stop_handlers: std.ArrayList(RegisteredStopHandler) = .empty,
    post_turn_end_handlers: std.ArrayList(RegisteredPostTurnEndHandler) = .empty,
    attention_required_handlers: std.ArrayList(RegisteredAttentionRequiredHandler) = .empty,
    frozen: bool = false,

    pub fn init(alloc: Allocator) Runtime {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Runtime) void {
        deinitRegisteredHooks(self.alloc, self.pre_tool_use_handlers.items);
        self.pre_tool_use_handlers.deinit(self.alloc);
        deinitRegisteredHooks(self.alloc, self.stop_handlers.items);
        self.stop_handlers.deinit(self.alloc);
        deinitRegisteredHooks(self.alloc, self.post_turn_end_handlers.items);
        self.post_turn_end_handlers.deinit(self.alloc);
        deinitRegisteredHooks(self.alloc, self.attention_required_handlers.items);
        self.attention_required_handlers.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn registerPreToolUse(
        self: *Runtime,
        handler: definitions.PreToolUseHandler,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.validateRegistration(
            .pre_tool_use,
            handler.name,
            self.pre_tool_use_handlers.items,
        );

        const hook = try self.copyHook(.pre_tool_use, handler.name, handler.ctx);
        errdefer self.alloc.free(hook.name);
        try self.pre_tool_use_handlers.append(self.alloc, .{
            .hook = hook,
            .run = handler.run,
        });
    }

    pub fn registerStop(
        self: *Runtime,
        handler: definitions.StopHandler,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.validateRegistration(
            .stop,
            handler.name,
            self.stop_handlers.items,
        );

        const hook = try self.copyHook(.stop, handler.name, handler.ctx);
        errdefer self.alloc.free(hook.name);
        try self.stop_handlers.append(self.alloc, .{
            .hook = hook,
            .run = handler.run,
        });
    }

    pub fn registerPostTurnEnd(
        self: *Runtime,
        handler: definitions.PostTurnEndHandler,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.registerSideEffect(
            .post_turn_end,
            handler,
            &self.post_turn_end_handlers,
        );
    }

    pub fn registerAttentionRequired(
        self: *Runtime,
        handler: definitions.AttentionRequiredHandler,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.registerSideEffect(
            .attention_required,
            handler,
            &self.attention_required_handlers,
        );
    }

    fn registerSideEffect(
        self: *Runtime,
        event: HookEvent,
        handler: anytype,
        registered_handlers: anytype,
    ) (Allocator.Error || definitions.RegistrationError)!void {
        try self.validateRegistration(event, handler.name, registered_handlers.items);
        const hook = try self.copyHook(event, handler.name, handler.ctx);
        errdefer self.alloc.free(hook.name);
        try registered_handlers.append(self.alloc, .{
            .hook = hook,
            .run = handler.run,
        });
    }

    pub fn freeze(self: *Runtime) RuntimeView {
        self.frozen = true;
        return self.currentView();
    }

    pub fn view(self: *const Runtime) definitions.ViewError!RuntimeView {
        if (!self.frozen) return error.RuntimeNotFrozen;
        return self.currentView();
    }

    fn currentView(self: *const Runtime) RuntimeView {
        return .{
            .pre_tool_use_handlers = self.pre_tool_use_handlers.items,
            .stop_handlers = self.stop_handlers.items,
            .post_turn_end_handlers = self.post_turn_end_handlers.items,
            .attention_required_handlers = self.attention_required_handlers.items,
        };
    }

    fn validateRegistration(
        self: *const Runtime,
        event: HookEvent,
        name: []const u8,
        registered_handlers: anytype,
    ) definitions.RegistrationError!void {
        if (self.frozen) return error.RuntimeFrozen;
        try validateHandlerName(name);
        for (registered_handlers) |registered| {
            std.debug.assert(registered.hook.event == event);
            if (std.mem.eql(u8, registered.hook.name, name)) return error.DuplicateHandlerName;
        }
    }

    fn copyHook(
        self: *Runtime,
        event: HookEvent,
        name: []const u8,
        ctx: *anyopaque,
    ) Allocator.Error!RegisteredHook {
        return .{
            .event = event,
            .name = try self.alloc.dupe(u8, name),
            .ctx = ctx,
        };
    }
};

pub const RuntimeView = struct {
    pre_tool_use_handlers: []const RegisteredPreToolUseHandler,
    stop_handlers: []const RegisteredStopHandler,
    post_turn_end_handlers: []const RegisteredPostTurnEndHandler,
    attention_required_handlers: []const RegisteredAttentionRequiredHandler,

    pub fn empty() RuntimeView {
        return .{
            .pre_tool_use_handlers = &.{},
            .stop_handlers = &.{},
            .post_turn_end_handlers = &.{},
            .attention_required_handlers = &.{},
        };
    }

    pub fn hasPreToolUse(self: RuntimeView) bool {
        return self.pre_tool_use_handlers.len != 0;
    }

    pub fn runPreToolUse(
        self: RuntimeView,
        alloc: Allocator,
        input: definitions.PreToolUseInput,
    ) definitions.MutationDispatchError!definitions.PreToolUseOutcome {
        if (self.pre_tool_use_handlers.len == 0) return .unchanged;

        var dispatch = PreToolUseDispatch{
            .alloc = alloc,
            .input = input,
        };
        errdefer dispatch.deinit();
        return try dispatch.run(self.pre_tool_use_handlers);
    }

    pub fn hasStop(self: RuntimeView) bool {
        return self.stop_handlers.len != 0;
    }

    pub fn runStop(
        self: RuntimeView,
        alloc: Allocator,
        input: definitions.StopInput,
    ) definitions.StopOutcome {
        if (self.stop_handlers.len == 0) return .allow;

        const dispatch = StopDispatch{
            .alloc = alloc,
            .input = input,
        };
        return dispatch.run(self.stop_handlers);
    }

    pub fn hasPostTurnEnd(self: RuntimeView) bool {
        return self.post_turn_end_handlers.len != 0;
    }

    pub fn runPostTurnEnd(
        self: RuntimeView,
        input: definitions.PostTurnEndInput,
    ) void {
        runSideEffectHandlers(input, self.post_turn_end_handlers);
    }

    pub fn hasAttentionRequired(self: RuntimeView) bool {
        return self.attention_required_handlers.len != 0;
    }

    pub fn runAttentionRequired(
        self: RuntimeView,
        input: definitions.AttentionRequiredInput,
    ) void {
        runSideEffectHandlers(input, self.attention_required_handlers);
    }
};

const PreToolUseDispatch = struct {
    alloc: Allocator,
    input: definitions.PreToolUseInput,
    current_arguments: ?[]u8 = null,

    fn deinit(self: *PreToolUseDispatch) void {
        if (self.current_arguments) |arguments_json| self.alloc.free(arguments_json);
        self.current_arguments = null;
    }

    fn run(
        self: *PreToolUseDispatch,
        handlers: []const RegisteredPreToolUseHandler,
    ) definitions.MutationDispatchError!definitions.PreToolUseOutcome {
        for (handlers) |handler| {
            switch (try self.runHandler(handler)) {
                .next => {},
                .blocked => |reason| return .{ .blocked = reason },
            }
        }

        return self.takeOutcome();
    }

    fn runHandler(
        self: *PreToolUseDispatch,
        handler: RegisteredPreToolUseHandler,
    ) definitions.MutationDispatchError!PreToolUseActionResult {
        const trace = HandlerTrace.start(
            handler.hook,
            self.input.invocation,
            self.input.call_id,
        );
        const action = handler.run(handler.hook.ctx, self.handlerInput()) catch |err| {
            trace.fail(err);
            return switch (err) {
                error.Failed => error.HandlerFailed,
                error.Cancelled => error.Cancelled,
            };
        };
        return applyPreToolUseAction(
            self.alloc,
            action,
            &self.current_arguments,
            trace,
        );
    }

    fn takeOutcome(self: *PreToolUseDispatch) definitions.PreToolUseOutcome {
        if (self.current_arguments) |arguments_json| {
            self.current_arguments = null;
            return .{ .rewritten = arguments_json };
        }
        return .unchanged;
    }

    fn handlerInput(self: PreToolUseDispatch) definitions.PreToolUseInput {
        var input = self.input;
        if (self.current_arguments) |arguments_json| input.arguments_json = arguments_json;
        return input;
    }
};

const PreToolUseActionResult = union(enum) {
    next,
    blocked: []u8,
};

fn applyPreToolUseAction(
    alloc: Allocator,
    action: definitions.PreToolUseAction,
    current_arguments: *?[]u8,
    trace: HandlerTrace,
) definitions.MutationDispatchError!PreToolUseActionResult {
    switch (action) {
        .continue_ => {
            trace.finish("continue");
            return .next;
        },
        .rewrite_arguments => |borrowed| {
            if (borrowed.len > definitions.Limits.arguments_json_bytes) {
                trace.finish("rewrite_too_large");
                return error.HandlerOutputTooLarge;
            }

            const copied = alloc.dupe(u8, borrowed) catch {
                trace.finish("copy_failed");
                return error.OutOfMemory;
            };
            validateJsonObject(alloc, copied) catch |err| {
                alloc.free(copied);
                trace.fail(err);
                return err;
            };

            if (current_arguments.*) |previous| alloc.free(previous);
            current_arguments.* = copied;
            trace.finish("rewrite");
            return .next;
        },
        .block => |borrowed| {
            if (borrowed.len == 0 or !std.unicode.utf8ValidateSlice(borrowed)) {
                trace.finish("invalid_block");
                return error.InvalidHandlerOutput;
            }
            if (borrowed.len > definitions.Limits.reason_bytes) {
                trace.finish("block_too_large");
                return error.HandlerOutputTooLarge;
            }

            const reason = alloc.dupe(u8, borrowed) catch {
                trace.finish("copy_failed");
                return error.OutOfMemory;
            };
            if (current_arguments.*) |previous| {
                alloc.free(previous);
                current_arguments.* = null;
            }
            trace.finish("block");
            return .{ .blocked = reason };
        },
    }
}

const StopActionResult = union(enum) {
    next,
    done: definitions.StopOutcome,
};

const StopDispatch = struct {
    alloc: Allocator,
    input: definitions.StopInput,

    fn run(
        self: StopDispatch,
        handlers: []const RegisteredStopHandler,
    ) definitions.StopOutcome {
        for (handlers) |handler| {
            switch (self.runHandler(handler)) {
                .next => {},
                .done => |outcome| return outcome,
            }
        }
        return .allow;
    }

    fn runHandler(
        self: StopDispatch,
        handler: RegisteredStopHandler,
    ) StopActionResult {
        const trace = HandlerTrace.start(
            handler.hook,
            self.input.invocation,
            null,
        );
        const action = handler.run(handler.hook.ctx, self.input) catch |err| {
            trace.fail(err);
            return .{ .done = .allow };
        };
        return applyStopAction(
            self.alloc,
            action,
            self.input.can_continue,
            trace,
        );
    }
};

fn applyStopAction(
    alloc: Allocator,
    action: definitions.StopAction,
    can_continue: bool,
    trace: HandlerTrace,
) StopActionResult {
    switch (action) {
        .allow => {
            trace.finish("allow");
            return .next;
        },
        .continue_once => |borrowed| {
            if (!can_continue) {
                trace.finish("continue_not_allowed");
                return .{ .done = .allow };
            }
            if (borrowed.len > definitions.Limits.context_bytes or
                !std.unicode.utf8ValidateSlice(borrowed))
            {
                trace.finish("invalid_continue");
                return .{ .done = .allow };
            }

            const context = alloc.dupe(u8, borrowed) catch {
                trace.finish("copy_failed");
                return .{ .done = .allow };
            };
            trace.finish("continue_once");
            return .{ .done = .{ .continue_once = context } };
        },
    }
}

fn runSideEffectHandlers(input: anytype, handlers: anytype) void {
    for (handlers) |handler| {
        const trace = HandlerTrace.start(
            handler.hook,
            input.invocation,
            null,
        );
        handler.run(handler.hook.ctx, input) catch |err| {
            trace.fail(err);
            continue;
        };
        trace.finish("ok");
    }
}

fn deinitRegisteredHooks(alloc: Allocator, registered_handlers: anytype) void {
    for (registered_handlers) |handler| alloc.free(handler.hook.name);
}

fn validateHandlerName(name: []const u8) definitions.RegistrationError!void {
    if (name.len == 0) return error.EmptyHandlerName;
    if (name.len > definitions.Limits.handler_name_bytes) return error.HandlerNameTooLong;
    for (name) |byte| {
        const valid = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        if (!valid) return error.InvalidHandlerName;
    }
}

fn validateJsonObject(
    alloc: Allocator,
    arguments_json: []const u8,
) definitions.MutationDispatchError!void {
    if (!std.unicode.utf8ValidateSlice(arguments_json)) return error.InvalidHandlerOutput;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidHandlerOutput;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHandlerOutput;
}

const HandlerTrace = struct {
    event: HookEvent,
    handler_name: []const u8,
    invocation: definitions.Invocation,
    call_id: ?[]const u8,
    started_ms: i64,

    fn start(
        hook: RegisteredHook,
        invocation: definitions.Invocation,
        call_id: ?[]const u8,
    ) HandlerTrace {
        const trace: HandlerTrace = .{
            .event = hook.event,
            .handler_name = hook.name,
            .invocation = invocation,
            .call_id = call_id,
            .started_ms = io_mod.milliTimestamp(),
        };
        trace.emitStart();
        return trace;
    }

    fn finish(self: HandlerTrace, outcome: []const u8) void {
        const duration_ms = self.durationMs();
        const trace_ctx = traceContext(self.invocation);
        if (self.call_id) |id| {
            debug_trace.eventf(
                "hooks",
                "handler_finish",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} call_id={s} duration_ms={d} outcome={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), id, duration_ms, outcome },
            );
        } else {
            debug_trace.eventf(
                "hooks",
                "handler_finish",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} duration_ms={d} outcome={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), duration_ms, outcome },
            );
        }
    }

    fn fail(self: HandlerTrace, err: anyerror) void {
        const duration_ms = self.durationMs();
        const trace_ctx = traceContext(self.invocation);
        if (self.call_id) |id| {
            debug_trace.eventf(
                "hooks",
                "handler_finish",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} call_id={s} duration_ms={d} outcome=error error={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), id, duration_ms, @errorName(err) },
            );
        } else {
            debug_trace.eventf(
                "hooks",
                "handler_finish",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} duration_ms={d} outcome=error error={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), duration_ms, @errorName(err) },
            );
        }
    }

    fn emitStart(self: HandlerTrace) void {
        const trace_ctx = traceContext(self.invocation);
        if (self.call_id) |id| {
            debug_trace.eventf(
                "hooks",
                "handler_start",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s} call_id={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind), id },
            );
        } else {
            debug_trace.eventf(
                "hooks",
                "handler_start",
                trace_ctx,
                "lifecycle_event={s} handler={s} scope={s}",
                .{ self.event.definition().lifecycle_event, self.handler_name, @tagName(self.invocation.scope.kind) },
            );
        }
    }

    fn durationMs(self: HandlerTrace) i64 {
        return @max(io_mod.milliTimestamp() - self.started_ms, 0);
    }
};

fn traceContext(invocation: definitions.Invocation) debug_trace.TraceContext {
    return .{
        .turn_id = invocation.turn_id orelse 0,
        .subagent_id = invocation.scope.subagent_id orelse 0,
    };
}

fn testInvocation() definitions.Invocation {
    return .{
        .scope = .{
            .kind = .interactive,
            .workspace_root = "/tmp/workspace",
            .session_id = "session",
        },
        .turn_id = 42,
    };
}

const TestHandler = struct {
    fn continueTool(_: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        return .continue_;
    }

    fn allowStop(_: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        return .allow;
    }

    fn notePostTurnEnd(_: *anyopaque, _: definitions.PostTurnEndInput) definitions.HandlerError!void {}

    fn noteAttentionRequired(_: *anyopaque, _: definitions.AttentionRequiredInput) definitions.HandlerError!void {}
};

const RewriteCapture = struct {
    order: [4]u8 = undefined,
    count: usize = 0,
    second_saw_first: bool = false,
    third_called: bool = false,
    mutable_rewrite: [7]u8 = .{ '{', '"', 'a', '"', ':', '1', '}' },

    fn note(self: *RewriteCapture, value: u8) void {
        self.order[self.count] = value;
        self.count += 1;
    }

    fn first(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *RewriteCapture = @ptrCast(@alignCast(raw));
        self.note(1);
        return .{ .rewrite_arguments = &self.mutable_rewrite };
    }

    fn second(raw: *anyopaque, input: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *RewriteCapture = @ptrCast(@alignCast(raw));
        self.note(2);
        self.second_saw_first = std.mem.eql(u8, input.arguments_json, "{\"a\":1}");
        return .{ .rewrite_arguments = "{\"b\":2}" };
    }

    fn block(raw: *anyopaque, input: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *RewriteCapture = @ptrCast(@alignCast(raw));
        self.note(3);
        if (!std.mem.eql(u8, input.arguments_json, "{\"b\":2}")) return error.Failed;
        return .{ .block = "blocked by policy" };
    }

    fn third(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *RewriteCapture = @ptrCast(@alignCast(raw));
        self.third_called = true;
        return .continue_;
    }
};

const OutputHandler = struct {
    output: []const u8,
    action: enum { rewrite, block, stop } = .rewrite,

    fn runTool(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *OutputHandler = @ptrCast(@alignCast(raw));
        return switch (self.action) {
            .rewrite => .{ .rewrite_arguments = self.output },
            .block => .{ .block = self.output },
            .stop => .continue_,
        };
    }

    fn runStop(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *OutputHandler = @ptrCast(@alignCast(raw));
        return .{ .continue_once = self.output };
    }
};

const ErrorHandler = struct {
    cancelled: bool,

    fn runTool(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *ErrorHandler = @ptrCast(@alignCast(raw));
        if (self.cancelled) return error.Cancelled;
        return error.Failed;
    }

    fn runStop(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *ErrorHandler = @ptrCast(@alignCast(raw));
        if (self.cancelled) return error.Cancelled;
        return error.Failed;
    }
};

const StopCapture = struct {
    calls: usize = 0,
    third_called: bool = false,
    mutable_context: [8]u8 = .{ 'c', 'o', 'n', 't', 'i', 'n', 'u', 'e' },

    fn allow(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *StopCapture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .allow;
    }

    fn continueOnce(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *StopCapture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .continue_once = &self.mutable_context };
    }

    fn third(raw: *anyopaque, _: definitions.StopInput) definitions.HandlerError!definitions.StopAction {
        const self: *StopCapture = @ptrCast(@alignCast(raw));
        self.third_called = true;
        return .allow;
    }
};

const PostTurnEndCapture = struct {
    order: [4]u8 = undefined,
    count: usize = 0,
    saw_scope: bool = false,
    saw_turn_id: bool = false,
    saw_outcome: bool = false,
    saw_disposition: bool = false,

    fn note(self: *PostTurnEndCapture, value: u8) void {
        self.order[self.count] = value;
        self.count += 1;
    }

    fn first(raw: *anyopaque, input: definitions.PostTurnEndInput) definitions.HandlerError!void {
        const self: *PostTurnEndCapture = @ptrCast(@alignCast(raw));
        self.note(1);
        self.saw_scope = input.invocation.scope.kind == .interactive and
            std.mem.eql(u8, input.invocation.scope.workspace_root, "/tmp/workspace") and
            std.mem.eql(u8, input.invocation.scope.session_id orelse "", "session");
        self.saw_turn_id = input.invocation.turn_id == 42;
        self.saw_outcome = input.outcome == .completed;
        self.saw_disposition = input.provider_disposition == .length_limited;
    }

    fn failing(raw: *anyopaque, _: definitions.PostTurnEndInput) definitions.HandlerError!void {
        const self: *PostTurnEndCapture = @ptrCast(@alignCast(raw));
        self.note(2);
        return error.Failed;
    }

    fn cancelled(raw: *anyopaque, _: definitions.PostTurnEndInput) definitions.HandlerError!void {
        const self: *PostTurnEndCapture = @ptrCast(@alignCast(raw));
        self.note(3);
        return error.Cancelled;
    }

    fn fourth(raw: *anyopaque, _: definitions.PostTurnEndInput) definitions.HandlerError!void {
        const self: *PostTurnEndCapture = @ptrCast(@alignCast(raw));
        self.note(4);
    }
};

const AttentionRequiredCapture = struct {
    order: [4]u8 = undefined,
    count: usize = 0,
    saw_input: bool = false,

    fn note(self: *AttentionRequiredCapture, value: u8) void {
        self.order[self.count] = value;
        self.count += 1;
    }

    fn first(raw: *anyopaque, input: definitions.AttentionRequiredInput) definitions.HandlerError!void {
        const self: *AttentionRequiredCapture = @ptrCast(@alignCast(raw));
        self.note(1);
        self.saw_input = input.invocation.scope.kind == .interactive and
            input.invocation.turn_id == 42 and
            input.kind == .route_recovery;
    }

    fn failing(raw: *anyopaque, _: definitions.AttentionRequiredInput) definitions.HandlerError!void {
        const self: *AttentionRequiredCapture = @ptrCast(@alignCast(raw));
        self.note(2);
        return error.Failed;
    }

    fn cancelled(raw: *anyopaque, _: definitions.AttentionRequiredInput) definitions.HandlerError!void {
        const self: *AttentionRequiredCapture = @ptrCast(@alignCast(raw));
        self.note(3);
        return error.Cancelled;
    }

    fn fourth(raw: *anyopaque, _: definitions.AttentionRequiredInput) definitions.HandlerError!void {
        const self: *AttentionRequiredCapture = @ptrCast(@alignCast(raw));
        self.note(4);
    }
};

const ConcurrentHandler = struct {
    calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn run(raw: *anyopaque, _: definitions.PreToolUseInput) definitions.HandlerError!definitions.PreToolUseAction {
        const self: *ConcurrentHandler = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .seq_cst);
        return .continue_;
    }
};

const ConcurrentRun = struct {
    view: RuntimeView,
    failed: *std.atomic.Value(bool),

    fn run(self: ConcurrentRun) void {
        var outcome = self.view.runPreToolUse(std.heap.page_allocator, .{
            .invocation = testInvocation(),
            .step_index = 1,
            .call_id = "call",
            .tool_name = "tool",
            .arguments_json = "{}",
        }) catch {
            self.failed.store(true, .seq_cst);
            return;
        };
        outcome.deinit(std.heap.page_allocator);
    }
};
