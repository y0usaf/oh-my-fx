const std = @import("std");
const model_capabilities = @import("../config/model_capabilities.zig");
const image_attachments = @import("../images/image_attachments.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const model_provider = @import("../config/model_provider.zig");
const credential_authority = @import("../auth/credential_authority.zig");

const Allocator = std.mem.Allocator;

/// Transport parser callback shapes. Provider boundaries expose `EventSink`;
/// concrete reducers may use these adapters internally.
pub const StreamCallback = *const fn (ctx: *anyopaque, chunk: []const u8) void;
pub const ToolStartCallback = *const fn (
    ctx: *anyopaque,
    tool_id: []const u8,
    tool_name: []const u8,
    label_value: ?[]const u8,
) void;

pub const Event = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
    tool_started: struct {
        id: []const u8,
        name: []const u8,
        label: ?[]const u8 = null,
    },
    tool_input_delta: []const u8,
};

pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (context: *anyopaque, event: Event) void,

    pub fn emit(self: EventSink, event: Event) void {
        self.emit_fn(self.context, event);
    }
};

pub const Admission = struct {
    context: ?*anyopaque = null,
    admit_fn: ?*const fn (context: *anyopaque) anyerror!void = null,

    /// Providers call this exactly once after request serialization and
    /// validation succeed, immediately before delivery can become possible.
    pub fn admit(self: Admission) !void {
        const admit_fn = self.admit_fn orelse return error.ProviderAdmissionMissing;
        try admit_fn(self.context orelse return error.ProviderAdmissionMissing);
    }
};

/// Monotonic evidence for whether a request could have reached its provider.
/// Core uses it to distinguish safe retries from potentially billed delivery.
pub const DeliveryCertainty = struct {
    state: std.atomic.Value(State) = .init(.definitely_unsent),

    pub const State = enum(u8) {
        definitely_unsent,
        possibly_sent,
    };

    pub fn init() DeliveryCertainty {
        return .{};
    }

    pub fn markPossiblySent(self: *DeliveryCertainty) void {
        self.state.store(.possibly_sent, .seq_cst);
    }

    pub fn load(self: *const DeliveryCertainty) State {
        return self.state.load(.seq_cst);
    }
};

/// Selects the layer that owns retries for a provider request.
/// Agent-owned model attempts must not be retried again by the transport.
pub const ProviderAttemptOwner = enum {
    transport,
    agent,
};

pub const NetworkFailureCause = enum {
    transport_interrupted,
    system_resumed,
};

/// Stable native transport evidence consumed by model recovery policy.
/// Providers that cannot distinguish failure stages leave this unset.
pub const NetworkFailureEvidence = struct {
    cause: NetworkFailureCause,
    delivery: DeliveryCertainty.State,
};

pub const AttemptEvidence = struct {
    provider_admitted: bool = false,
    network_failure: ?NetworkFailureEvidence = null,
};

/// Gives a cooperative single-threaded host a chance to publish UI and runtime
/// state while provider transport remains pending.
pub const CooperativePulse = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) anyerror!void,

    pub fn pulse(self: CooperativePulse) anyerror!void {
        try self.run(self.ctx);
    }
};

pub const VisionMode = enum {
    unavailable,
    optional,
    required,
};

pub const BuildBudget = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const StructuredResponseFormat = struct {
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
};

pub const DynamicFunctionTool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
};

pub const ToolSelection = struct {
    registry: tool_dispatch.Registry = .{},
    advertised_names: []const []const u8 = &.{},
    advertised_functions: []const model_tool_schema.FunctionSchema = &.{},
    additional_functions: []const model_tool_schema.FunctionSchema = &.{},
    selected_dynamic: []const DynamicFunctionTool = &.{},

    pub fn advertisedFunction(self: ToolSelection, name: []const u8) ?model_tool_schema.FunctionSchema {
        for (self.advertised_functions) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }
};

pub const CredentialLease = struct {
    secret: []const u8,
    source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    tenant: ?[]const u8 = null,
};

/// Pure provider input used by request serializers and permission reviewers.
/// Every slice and JSON value is borrowed for the call.
pub const RequestData = struct {
    model: []const u8,
    messages: []const types.ChatMessage,
    tools: ToolSelection = .{},
    tool_choice: types.ToolChoice,
    vision_mode: VisionMode = .unavailable,
    provider_options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32 = null,
    budget: ?BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,
};

/// Borrowed typed request. Providers own validation, wire serialization,
/// endpoint selection, headers, HTTP, and stream reduction.
pub const ModelRequest = struct {
    credential: CredentialLease,
    session_id: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    messages: []const types.ChatMessage,
    tools: ToolSelection = .{},
    tool_choice: types.ToolChoice,
    vision_mode: VisionMode = .unavailable,
    provider_options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32 = null,
    budget: ?BuildBudget = null,
    verified_images: ?[]const image_attachments.VerifiedSnapshot = null,
    response_format: ?StructuredResponseFormat = null,
    trace_ctx: debug_trace.TraceContext,
    content_capture_limit: ?usize,
    /// Optional absolute provider deadline. Transports that support bounded
    /// execution must stop in-flight I/O before returning `error.Timeout`.
    deadline: ?std.Io.Clock.Timestamp = null,
    cooperative_pulse: ?CooperativePulse = null,
    delivery: *DeliveryCertainty,
    attempt_evidence: *AttemptEvidence,
    events: EventSink,
    admission: Admission = .{},
    cancel_flag: *std.atomic.Value(bool),
    provider_attempt_owner: ProviderAttemptOwner = .transport,

    pub fn data(self: ModelRequest) RequestData {
        return .{
            .model = self.model,
            .messages = self.messages,
            .tools = self.tools,
            .tool_choice = self.tool_choice,
            .vision_mode = self.vision_mode,
            .provider_options = self.provider_options,
            .max_output_tokens = self.max_output_tokens,
            .budget = self.budget,
            .verified_images = self.verified_images,
            .response_format = self.response_format,
        };
    }
};

pub const ResultOwnership = enum {
    borrowed,
    owned,
};

pub const FailureKind = enum {
    invalid_request,
    unauthorized,
    forbidden,
    request_too_large,
    rate_limited,
    server_error,
    bad_gateway,
    unavailable,
    gateway_timeout,
    provider_error,
};

pub const FailureDiagnostics = struct {
    schema: ?[]u8 = null,
    request_shape: ?[]u8 = null,
};

pub const DeferredUsageReference = struct {
    provider: model_provider.ProviderId,
    generation_id: []const u8,
    scope: []const u8,
    tenant: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    credential_source: types.CredentialSource,
    credential_identity: ?credential_authority.Identity,
};

pub const UsageUnavailable = enum {
    unbilled,
    possibly_billed,
};

pub const UsageOutcome = union(enum) {
    exact: model_provider.ProviderId,
    deferred: DeferredUsageReference,
    unavailable: UsageUnavailable,
};

pub const Completed = struct {
    completion: types.ModelCompletion = .{},
    usage: UsageOutcome = .{ .unavailable = .unbilled },
    ownership: ResultOwnership = .borrowed,
};

pub const Failure = struct {
    kind: FailureKind,
    detail: ?[]u8 = null,
    diagnostics: FailureDiagnostics = .{},
    retry_after_seconds: ?u64 = null,
    ownership: ResultOwnership = .borrowed,
};

pub const Result = union(enum) {
    completed: Completed,
    failed: Failure,

    /// Providers mark allocated response fields as `owned`; test and embedded
    /// providers may return stable borrowed fields instead.
    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .completed => |completed| if (completed.ownership == .owned) {
                if (completed.completion.content) |content| alloc.free(@constCast(content));
                if (completed.completion.generation_id) |id| alloc.free(@constCast(id));
                if (completed.completion.billing) |billing| alloc.free(@constCast(billing.model));
                types.freeToolCallSlice(alloc, @constCast(completed.completion.tool_calls));
                if (completed.completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
                if (completed.completion.provider_state_json) |state| alloc.free(@constCast(state));
            },
            .failed => |failure| if (failure.ownership == .owned) {
                if (failure.detail) |detail| alloc.free(detail);
                if (failure.diagnostics.schema) |schema| alloc.free(schema);
                if (failure.diagnostics.request_shape) |shape| alloc.free(shape);
            },
        }
        self.* = undefined;
    }
};

pub inline fn failResult(err: anytype) @TypeOf(err)!Result {
    return @errorCast(failResultDynamic(err));
}

noinline fn failResultDynamic(err: anyerror) anyerror!Result {
    return err;
}

pub const StreamFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    request: ModelRequest,
) anyerror!Result;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight `stream` returns.
    context: ?*anyopaque = null,
    stream_fn: StreamFn,

    pub fn stream(self: Provider, alloc: Allocator, request: ModelRequest) !Result {
        return self.stream_fn(self.context, alloc, request);
    }
};

fn unavailableStream(_: ?*anyopaque, _: Allocator, _: ModelRequest) anyerror!Result {
    return failResult(error.AgentStreamProviderUnavailable);
}

pub const unavailable_provider = Provider{
    .stream_fn = unavailableStream,
};
