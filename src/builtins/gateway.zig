const std = @import("std");
const builtin = @import("builtin");

pub const permission_reviewer = @import("gateway/permission_reviewer.zig");

const api_key_validator_contract = @import("../core/auth/api_key_validator.zig");
const agent_stream_provider_contract = @import("../core/agent/stream_provider.zig");
const credentials = @import("../core/auth/credentials.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const secret = @import("../core/auth/secret.zig");
const collections = @import("../core/shared/collections.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_error_format = @import("../core/shared/gateway_error_format.zig");
const gateway_client = @import("../gateway/client.zig");
const vercel_failure_diagnostics = @import("../gateway/vercel_failure_diagnostics.zig");
const vercel_protocol = @import("../gateway/vercel_protocol.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_generation_usage = @import("../gateway/generation_usage.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const credential_authority = @import("../core/auth/credential_authority.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const vercel_model_policy = @import("../gateway/vercel_model_policy.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const shared_types = @import("../core/shared/types.zig");
const session_usage = @import("../core/session/session_usage.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const sort_utils = @import("../core/shared/sort_utils.zig");

const Allocator = std.mem.Allocator;
const FetchGatewayGetResultFn = *const fn (Allocator, ?[]const u8, []const u8) anyerror!gateway_client.GetResult;

const Request = web_search_contract.ProviderRequest;
const Response = web_search_contract.ProviderResponse;
const ProgressFn = web_search_contract.ProgressFn;

pub const default_model = "moonshotai/kimi-k3";
pub const default_chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model";
pub const models_path = "/coding-agent/v1/models";
const credits_path = "/coding-agent/v1/credits";
pub const retry_count: usize = 3;
pub const chat_url_env = "FX_GATEWAY_CHAT_URL";
pub const default_model_catalog_base_url = "https://ai-gateway.vercel.sh";
const base_url_env = "FX_GATEWAY_BASE_URL";
const e2e_gateway_models_url_env = "FX_E2E_GATEWAY_MODELS_URL";
const oauth_request_timeout_ms: i64 = 15_000;
const oauth_response_max_bytes: usize = 64 * 1024;

const web_search_system_prompt = "Research the user's query with the web_search tool and preserve sources for citation.";
const perplexity_search_backend_id = web_search_contract.SearchBackendId{ .value = "ai_gateway_perplexity_search" };
const parallel_search_backend_id = web_search_contract.SearchBackendId{ .value = "ai_gateway_parallel_search" };
const default_web_search_backend_order = [_]web_search_contract.SearchBackendId{
    perplexity_search_backend_id,
    parallel_search_backend_id,
};
const perplexity_search_backend = [_]web_search_contract.SearchBackendId{perplexity_search_backend_id};
const parallel_search_backend = [_]web_search_contract.SearchBackendId{parallel_search_backend_id};
const default_web_search_backend_policies = [_]web_search_policy.BackendPolicy{
    .{
        .id = perplexity_search_backend_id,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .post_filter,
        },
    },
    .{
        .id = parallel_search_backend_id,
        .features = .{
            .max_uses = .best_effort,
            .allowed_domains = .pass_through,
            .blocked_domains = .pass_through,
            .ordered_sources = true,
            .usage = true,
            .terminal_incomplete = true,
            .timeout = true,
            .cancellation = true,
            .result_bounds = .pass_through,
        },
    },
};

pub const default_web_search_policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = &default_web_search_backend_order,
    .backend_policies = &default_web_search_backend_policies,
};

pub const default_web_search_provider = web_search_provider.Provider{
    .policy = default_web_search_policy,
    .input_overhead_bytes = web_search_system_prompt.len,
    .preferred_backends_fn = resolvePreferredWebSearchBackends,
    .execute_fn = executeWebSearchProvider,
};

pub const chat_url_provider = gateway_provider.ChatUrlProvider{
    .resolve_fn = resolveChatUrlForProvider,
};

pub fn agentChatUrl() []const u8 {
    return resolveChatUrl(default_chat_url, io_mod.getenv(chat_url_env));
}

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub const credits_provider = gateway_provider.CreditsProvider{
    .fetch_fn = fetchCredits,
};

pub const api_key_validator = api_key_validator_contract.Provider{
    .validate_fn = validateApiKey,
};

pub const oauth_transport_provider = oauth_transport.Provider{
    .execute_fn = executeOAuthRequest,
};

pub const generation_usage_provider = gateway_generation_usage.provider;

pub const agent_stream_provider = agent_stream_provider_contract.Provider{
    .stream_fn = streamAgentCompletion,
};

pub const provider_bundle = provider_set.Bundle{
    .capabilities = .{ .fx_search = true, .vision_fallback = true },
    .presentation = provider_catalog.find(.gateway),
    .auth_strategy = .vercel,
    .fallback_model_capabilities_fn = vercel_model_policy.capabilitiesForModel,
    .agent_stream = agent_stream_provider,
    .cli_model_catalog = cli_model_catalog_provider,
    .model_catalog = model_catalog_provider,
    .permission_reviewer = permission_reviewer.provider,
    .deferred_usage = generation_usage_provider,
    .credits = credits_provider,
    .fx_search = default_web_search_provider,
};

pub const provider = gateway_provider.Provider{
    .oauth_transport = oauth_transport_provider,
    .chat_url = chat_url_provider,
};

pub fn buildAgentRequest(
    alloc: Allocator,
    request: agent_stream_provider_contract.RequestData,
) anyerror![]u8 {
    const budget: ?vercel_protocol.BuildBudget = if (request.budget) |value|
        .{ .deadline = value.deadline, .cancel_flag = value.cancel_flag }
    else
        null;
    if (budget) |active| try active.check();

    const tools_json = try buildAgentToolsJson(alloc, request);
    defer alloc.free(tools_json);

    if (request.verified_images) |images| {
        const response_format = request.response_format orelse
            return error.MissingStructuredResponseFormat;
        const body = try vercel_protocol.buildGatewayRequestBodyWithVerifiedImagesAndBudget(
            alloc,
            tools_json,
            request.messages,
            images,
            request.provider_options,
            request.tool_choice,
            .{
                .name = response_format.name,
                .description = response_format.description,
                .schema = response_format.schema,
            },
            budget orelse .{},
        );
        return finalizeAgentRequestBody(alloc, request.model, body);
    }
    if (request.response_format != null) return error.StructuredResponseRequiresVerifiedImages;

    if (request.vision_mode != .required) {
        const body = if (budget) |active|
            vercel_protocol.buildGatewayRequestBodyWithOptionsAndBudget(
                alloc,
                tools_json,
                request.messages,
                request.provider_options,
                request.tool_choice,
                request.max_output_tokens,
                active,
            )
        else
            vercel_protocol.buildGatewayRequestBodyWithOptionsAndOutputLimit(
                alloc,
                tools_json,
                request.messages,
                request.provider_options,
                request.tool_choice,
                request.max_output_tokens,
            );
        return finalizeAgentRequestBody(alloc, request.model, try body);
    }

    if (request.vision_mode == .required) {
        const body = if (budget) |active|
            vercel_protocol.buildGatewayRequiredToolRequestBodyWithOptionsAndBudget(
                alloc,
                tools_json,
                request.messages,
                request.provider_options,
                request.max_output_tokens,
                active,
            )
        else
            vercel_protocol.buildGatewayRequiredToolRequestBodyWithOptionsAndOutputLimit(
                alloc,
                tools_json,
                request.messages,
                request.provider_options,
                request.max_output_tokens,
            );
        return finalizeAgentRequestBody(alloc, request.model, try body);
    }

    unreachable;
}

fn resolveGatewayProviderOptions(
    model: []const u8,
    effort: shared_types.ReasoningEffort,
    fast_mode: bool,
) model_capabilities.ResolvedProviderOptions {
    return model_capabilities.resolveProviderOptionsForCapabilities(
        vercel_model_policy.capabilitiesForModel(model),
        effort,
        fast_mode,
    );
}

fn buildAgentToolsJson(
    alloc: Allocator,
    request: agent_stream_provider_contract.RequestData,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    var first = true;

    if (request.vision_mode == .required) {
        const vision = request.tools.registry.lookup("vision") orelse
            return error.VisionToolNotRegistered;
        try model_tool_schema.writeBuiltinFunctionSchema(alloc, &out.writer, vision.model_schema);
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }

    for (request.tools.advertised_names) |name| {
        if (!first) try out.writer.writeByte(',');
        first = false;
        if (request.tools.advertisedFunction(name)) |function| {
            try model_tool_schema.writeBuiltinFunctionSchema(alloc, &out.writer, function);
        } else {
            const tool = request.tools.registry.lookup(name) orelse return error.AdvertisedToolNotRegistered;
            const write_advertisement = tool.write_provider_advertisement_fn orelse
                return error.AdvertisedToolSchemaMissing;
            try write_advertisement(alloc, &out.writer);
        }
    }
    for (request.tools.additional_functions) |tool| {
        if (toolNameSelected(request.tools.advertised_names, tool.name)) continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try model_tool_schema.writeBuiltinFunctionSchema(alloc, &out.writer, tool);
    }
    for (request.tools.selected_dynamic) |tool| {
        if (toolNameSelected(request.tools.advertised_names, tool.name)) continue;
        if (!first) try out.writer.writeByte(',');
        first = false;
        try writeDynamicFunctionTool(&out.writer, tool);
    }
    if (request.vision_mode == .optional and
        !toolNameSelected(request.tools.advertised_names, "vision"))
    {
        const vision = request.tools.registry.lookup("vision") orelse
            return error.VisionToolNotRegistered;
        if (!first) try out.writer.writeByte(',');
        try model_tool_schema.writeBuiltinFunctionSchema(alloc, &out.writer, vision.model_schema);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn toolNameSelected(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

fn writeDynamicFunctionTool(
    writer: *std.Io.Writer,
    tool: agent_stream_provider_contract.DynamicFunctionTool,
) !void {
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(tool.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(tool.description, .{}, writer);
    try writer.writeAll(",\"inputSchema\":");
    try std.json.Stringify.value(tool.input_schema, .{}, writer);
    try writer.writeByte('}');
}

fn finalizeAgentRequestBody(
    alloc: Allocator,
    model: []const u8,
    body: []u8,
) ![]u8 {
    if (!std.mem.eql(u8, model, "zai/glm-5.2")) return body;

    errdefer alloc.free(body);
    const identified = try vercel_protocol.withRequestUserAgent(
        alloc,
        body,
        gateway_client.user_agent,
    );
    alloc.free(body);
    return identified;
}

fn streamAgentCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: agent_stream_provider_contract.ModelRequest,
) anyerror!agent_stream_provider_contract.Result {
    if (request.credential.source == .chatgpt_subscription or request.credential.source == .grok_subscription) {
        return agent_stream_provider_contract.failResult(
            error.SubscriptionCredentialCannotAuthorizeGateway,
        );
    }
    const payload = try buildAgentRequest(alloc, request.data());
    defer alloc.free(payload);
    var events = request.events;
    const result = gateway_client.streamGatewayCompletion(
        alloc,
        .{
            .api_key = request.credential.secret,
            .team = request.credential.tenant,
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .chat_url = agentChatUrl(),
            .payload = payload,
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = request.content_capture_limit,
            .delivery = request.delivery,
            .admission = request.admission,
            .on_reasoning_chunk = EventBridge.reasoning,
            .on_tool_input_chunk = EventBridge.toolInput,
            .provider_attempt_owner = switch (request.provider_attempt_owner) {
                .transport => .transport,
                .agent => .agent,
            },
        },
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        request.cancel_flag,
    ) catch |err| {
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(
            err,
            request.delivery.load(),
        );
        return err;
    };
    const diagnostics = if (result.status == .ok)
        vercel_failure_diagnostics.FailureDiagnostics{}
    else
        vercel_failure_diagnostics.collect(alloc, payload, result.err_body);
    if (result.status != .ok) return .{ .failed = .{
        .kind = failureKind(result.status),
        .detail = result.err_body,
        .diagnostics = .{
            .schema = diagnostics.schema,
            .request_shape = diagnostics.request_shape,
        },
        .retry_after_seconds = result.retry_after_seconds,
        .ownership = .owned,
    } };
    return .{ .completed = .{
        .completion = result.completion,
        .usage = gatewayUsageOutcome(request, result.completion),
        .ownership = .owned,
    } };
}

fn gatewayUsageOutcome(
    request: agent_stream_provider_contract.ModelRequest,
    completion: shared_types.ModelCompletion,
) agent_stream_provider_contract.UsageOutcome {
    const reference = gatewayUsageReference(request, completion) orelse
        return .{ .unavailable = .possibly_billed };
    return if (completion.billing != null)
        .{ .exact = .gateway }
    else
        .{ .deferred = reference };
}

fn gatewayUsageReference(
    request: agent_stream_provider_contract.ModelRequest,
    completion: shared_types.ModelCompletion,
) ?agent_stream_provider_contract.DeferredUsageReference {
    const generation_id = completion.generation_id orelse return null;
    const source = request.credential.source orelse return null;
    return .{
        .provider = .gateway,
        .generation_id = generation_id,
        .scope = gateway_client.generationBaseUrl(),
        .tenant = request.credential.tenant,
        .account_id = request.credential.account_id,
        .credential_source = source,
        .credential_identity = credential_authority.derive(
            source,
            request.credential.account_id,
        ),
    };
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *agent_stream_provider_contract.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label } });
    }
};

fn failureKind(status: std.http.Status) agent_stream_provider_contract.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

fn fetchCredits(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    if (input.credential_source == .chatgpt_subscription) {
        return creditsErrorSnapshot(alloc, "AI Gateway credits are unavailable for a ChatGPT subscription.");
    }
    if (input.credential_source == .grok_subscription) {
        return creditsErrorSnapshot(alloc, "AI Gateway credits are unavailable for a Grok subscription.");
    }
    return fetchCreditsWithFetch(
        alloc,
        input.credential,
        input.tenant,
        gateway_client.fetchGatewayGetResult,
    );
}

/// An fx login can reach several teams, so `/v1/credits` rejects it outright
/// unless the request names one. The endpoint reads the team from a `teamId`
/// query value and ignores `x-vercel-ai-gateway-team`, which is the reverse of
/// the inference endpoint. An API key carries its own team and resolves to no
/// team here, so the query value is added for logins only.
fn fetchCreditsWithFetch(
    alloc: Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    fetch_fn: FetchGatewayGetResultFn,
) output_contracts.CreditsSnapshot {
    var team_path: ?[]u8 = null;
    defer if (team_path) |path| alloc.free(path);
    if (gateway_team) |team| {
        if (shared_types.validGatewayTeam(team)) {
            team_path = std.fmt.allocPrint(alloc, "{s}?teamId={s}", .{ credits_path, team }) catch {
                return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
            };
        } else {
            debug_trace.logf("credits", "team omitted from query; not url safe len={d}", .{team.len});
        }
    }

    var result = fetch_fn(alloc, api_key, team_path orelse credits_path) catch {
        return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
    };
    defer result.deinit(alloc);

    if (result.status != .ok) {
        const message = gateway_error_format.formatHttpErrorMessage(alloc, result.status, result.body) catch {
            return creditsErrorSnapshot(alloc, "failed to fetch credits from gateway");
        };
        return .{ .err_message = message };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, result.body, .{}) catch {
        return creditsErrorSnapshot(alloc, "invalid JSON response from gateway");
    };
    defer parsed.deinit();

    return creditsSnapshotFromJsonValue(alloc, parsed.value) catch {
        return creditsErrorSnapshot(alloc, "invalid JSON response from gateway");
    };
}

fn creditsSnapshotFromJsonValue(
    alloc: Allocator,
    value: std.json.Value,
) !output_contracts.CreditsSnapshot {
    if (value != .object) {
        return creditsErrorSnapshot(alloc, "unexpected response format from gateway");
    }

    const obj = value.object;
    var snapshot = output_contracts.CreditsSnapshot{};
    errdefer snapshot.deinit(alloc);

    if (obj.get("balance")) |field| {
        if (field == .string) snapshot.balance = try alloc.dupe(u8, field.string);
    }
    if (obj.get("used")) |field| {
        if (field == .string) snapshot.used = try alloc.dupe(u8, field.string);
    }
    if (obj.get("plan")) |field| {
        if (field == .string) snapshot.plan = try alloc.dupe(u8, field.string);
    }

    return snapshot;
}

fn creditsErrorSnapshot(
    alloc: Allocator,
    message: []const u8,
) output_contracts.CreditsSnapshot {
    return .{
        .raw_json = null,
        .err_message = alloc.dupe(u8, message) catch null,
    };
}

fn executeOAuthRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: oauth_transport.Request,
) !oauth_transport.Response {
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = request.cancel_flag orelse &local_cancel;
    const deadline = request.deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(oauth_request_timeout_ms),
    });
    var operation = OAuthHttpOperation{
        .alloc = alloc,
        .request = request,
    };
    return gateway_client.runBoundedHttpOperation(
        oauth_transport.Response,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

const OAuthHttpOperation = struct {
    alloc: Allocator,
    request: oauth_transport.Request,

    pub fn run(self: *@This()) !oauth_transport.Response {
        var client: std.http.Client = .{
            .allocator = self.alloc,
            .io = io_mod.getIo(),
        };
        defer client.deinit();

        const response_buffer = try self.alloc.alloc(u8, oauth_response_max_bytes + 1);
        defer secret.zeroAndFree(self.alloc, response_buffer);
        var response_writer = std.Io.Writer.fixed(response_buffer);

        const result = client.fetch(.{
            .location = .{ .url = self.request.url },
            .method = switch (self.request.method) {
                .get => .GET,
                .post_form, .post_json => .POST,
            },
            .payload = self.request.payload,
            .headers = .{
                .content_type = switch (self.request.method) {
                    .get => .default,
                    .post_form => .{ .override = "application/x-www-form-urlencoded" },
                    .post_json => .{ .override = "application/json" },
                },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
                .authorization = if (self.request.authorization) |value|
                    .{ .override = value }
                else
                    .default,
            },
            .redirect_behavior = .unhandled,
            .response_writer = &response_writer,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OAuthResponseTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > oauth_response_max_bytes) return error.OAuthResponseTooLarge;

        return .{
            .disposition = if (result.status == .ok) .accepted else .rejected,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn validateApiKey(
    _: ?*anyopaque,
    alloc: Allocator,
    api_key: []const u8,
) api_key_validator_contract.Result {
    var result = gateway_client.fetchGatewayGetResult(alloc, api_key, models_path) catch |err| {
        debug_trace.logf("auth", "api key validation failed err={s}", .{@errorName(err)});
        return .unavailable;
    };
    defer result.deinit(alloc);
    return apiKeyValidationForStatus(result.status);
}

fn apiKeyValidationForStatus(status: std.http.Status) api_key_validator_contract.Result {
    return switch (status) {
        .ok => .accepted,
        .unauthorized, .forbidden => .refused,
        else => .unavailable,
    };
}

pub fn preferredWebSearchBackendsOverride(raw: ?[]const u8) !?[]const web_search_contract.SearchBackendId {
    const value = raw orelse return null;
    if (value.len == 0) return null;
    if (std.mem.eql(u8, value, "ai_gateway_perplexity_search")) return &perplexity_search_backend;
    if (std.mem.eql(u8, value, "ai_gateway_parallel_search")) return &parallel_search_backend;
    return error.InvalidWebSearchBackend;
}

pub fn selectedWebSearchBackend() !web_search_contract.SearchBackendId {
    if (try preferredWebSearchBackendsOverride(io_mod.getenv("FX_WEB_SEARCH_BACKEND"))) |backends| {
        return backends[0];
    }
    return default_web_search_backend_order[0];
}

fn resolvePreferredWebSearchBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
    return preferredWebSearchBackendsOverride(io_mod.getenv("FX_WEB_SEARCH_BACKEND"));
}

fn executeWebSearchProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: Request,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    return executeGatewayWorker(alloc, .{
        .api_key = inputs.api_key,
        .credential_source = inputs.credential_source,
        .team = inputs.gateway_team,
        .model = inputs.worker_model,
        .retry_count = inputs.gateway_retry_count,
        .chat_url = inputs.gateway_chat_url,
        .usage = inputs.usage,
        .usage_allocator = inputs.usage_allocator,
    }, request, on_progress, progress_ctx);
}

pub fn chatUrl(fallback: []const u8) []const u8 {
    return resolveChatUrl(fallback, io_mod.getenv(chat_url_env));
}

pub fn defaultChatUrl() []const u8 {
    return chatUrl(default_chat_url);
}

fn resolveChatUrlForProvider(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return chatUrl(fallback);
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const result = model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    });
    return switch (result) {
        .loaded => |loaded| project: {
            var catalog = loaded.catalog;
            defer freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :project .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failed| .{ .failure = failed },
    };
}

pub fn resolveChatUrl(fallback: []const u8, override: ?[]const u8) []const u8 {
    const candidate = override orelse return fallback;
    // The chat URL carries the bearer token and full request payload; only a
    // loopback HTTP override is trusted for local testing.
    if (!gateway_client.isLoopbackHttpUrl(candidate)) return fallback;
    return candidate;
}

pub const StreamFn = *const fn (
    *anyopaque,
    Allocator,
    []const u8,
    ?[]const u8,
    []const u8,
    usize,
    []const u8,
    []const u8,
    []const u8,
    std.Io.Clock.Timestamp,
    *gateway_client.DeliveryCertainty,
    *std.atomic.Value(bool),
) anyerror!gateway_client.StreamResult;

var default_stream_ctx: u8 = 0;

pub const GatewayWorkerConfig = struct {
    api_key: []const u8,
    credential_source: ?shared_types.CredentialSource = null,
    team: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    stream_ctx: *anyopaque = @ptrCast(&default_stream_ctx),
    stream_fn: StreamFn = streamGatewayWorker,
};

pub const ProviderToolInput = struct {
    backend: web_search_contract.SearchBackendId,
    allowed_domains: ?[]const []const u8 = null,
    blocked_domains: ?[]const []const u8 = null,
    max_results: u8,
    max_output_tokens: u32 = 4096,
    max_output_chars: usize,
};

pub fn executeGatewayWorker(
    alloc: Allocator,
    config: GatewayWorkerConfig,
    request: Request,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    if (config.api_key.len == 0 or config.model.len == 0 or config.chat_url.len == 0) {
        return error.MissingGatewaySearchConfiguration;
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const deadline = deadlineAfterMs(request.timeout_ms);
    if (on_progress) |progress| progress(progress_ctx orelse return error.MissingProgressContext, .{ .query_update = request.query });

    const tools_json = try providerToolsJson(alloc, .{
        .backend = request.backend,
        .allowed_domains = request.allowed_domains,
        .blocked_domains = request.blocked_domains,
        .max_results = request.max_results,
        .max_output_tokens = request.max_output_tokens,
        .max_output_chars = request.max_output_chars,
    });
    defer alloc.free(tools_json);

    const messages = [_]shared_types.ChatMessage{
        .{ .role = .system, .content = web_search_system_prompt },
        .{ .role = .user, .content = request.query },
    };
    const payload = try vercel_protocol.buildGatewayRequiredToolRequestBodyWithMaxOutputTokens(alloc, tools_json, &messages, request.max_output_tokens);
    defer alloc.free(payload);

    const usage_observation = try session_usage.InvocationObservation.begin(config.usage);
    var delivery = gateway_client.DeliveryCertainty.init();
    const provider_tool_name = try selectedToolName(request.backend);
    var stream = config.stream_fn(
        config.stream_ctx,
        alloc,
        config.api_key,
        config.team,
        config.model,
        @max(config.retry_count, 1),
        config.chat_url,
        payload,
        provider_tool_name,
        deadline,
        &delivery,
        @constCast(request.cancel_flag),
    ) catch |err| {
        try usage_observation.fail(if (delivery.load() == .possibly_sent)
            .ambiguous_delivery
        else
            .unbilled);
        return err;
    };
    defer stream.deinit(alloc);
    const usage_outcome = gatewayWorkerUsageOutcome(config, stream.completion);
    if (stream.status == .ok) {
        try usage_observation.complete(
            config.usage_allocator,
            stream.completion,
            usage_outcome,
        );
    } else {
        try usage_observation.fail(.unbilled);
    }
    if (!builtin.is_test and stream.status == .ok and std.meta.activeTag(usage_outcome) == .deferred) {
        if (config.usage) |ledger| {
            ledger.startDeferredReconciliation(
                config.usage_allocator,
                usage_outcome.deferred,
                config.api_key,
            );
        }
    }
    if (stream.status != .ok) return error.GatewayRequestFailed;
    return normalizeGatewayCompletion(alloc, request, stream.completion, on_progress, progress_ctx);
}

fn gatewayWorkerUsageOutcome(
    config: GatewayWorkerConfig,
    completion: shared_types.ModelCompletion,
) agent_stream_provider_contract.UsageOutcome {
    const generation_id = completion.generation_id orelse
        return .{ .unavailable = .possibly_billed };
    const source = config.credential_source orelse .ai_gateway_api_key;
    const reference = agent_stream_provider_contract.DeferredUsageReference{
        .provider = .gateway,
        .generation_id = generation_id,
        .scope = gateway_client.generationBaseUrl(),
        .tenant = config.team,
        .credential_source = source,
        .credential_identity = credential_authority.derive(
            source,
            null,
        ),
    };
    return if (completion.billing != null)
        .{ .exact = .gateway }
    else
        .{ .deferred = reference };
}

fn deadlineAfterMs(timeout_ms: u32) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
}

pub fn providerToolsJson(alloc: Allocator, input: ProviderToolInput) ![]u8 {
    if (hasValues(input.allowed_domains) and hasValues(input.blocked_domains)) {
        return error.ConflictingDomainFilters;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (input.backend.eql(perplexity_search_backend_id)) {
        try out.writer.print(
            "[{{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"args\":{{\"maxResults\":{d},\"maxTokens\":{d}",
            .{ input.max_results, input.max_output_tokens },
        );
        if (hasValues(input.allowed_domains)) {
            try writePerplexityDomains(alloc, &out.writer, input.allowed_domains.?, false);
        } else if (hasValues(input.blocked_domains)) {
            try writePerplexityDomains(alloc, &out.writer, input.blocked_domains.?, true);
        }
        try out.writer.writeAll("}}]");
    } else if (input.backend.eql(parallel_search_backend_id)) {
        try out.writer.print(
            "[{{\"type\":\"provider\",\"id\":\"gateway.parallel_search\",\"name\":\"parallel_search\",\"args\":{{\"mode\":\"one-shot\",\"maxResults\":{d}",
            .{input.max_results},
        );
        if (hasValues(input.allowed_domains)) {
            try writeParallelDomains(&out.writer, "includeDomains", input.allowed_domains.?);
        } else if (hasValues(input.blocked_domains)) {
            try writeParallelDomains(&out.writer, "excludeDomains", input.blocked_domains.?);
        }
        try out.writer.print(",\"excerpts\":{{\"maxCharsTotal\":{d}}}}}}}]", .{input.max_output_chars});
    } else {
        return error.InvalidWebSearchBackend;
    }
    return try out.toOwnedSlice();
}

fn streamGatewayWorker(
    _: *anyopaque,
    alloc: Allocator,
    api_key: []const u8,
    team: ?[]const u8,
    model: []const u8,
    request_retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    expected_provider_tool_name: []const u8,
    deadline: std.Io.Clock.Timestamp,
    delivery: *gateway_client.DeliveryCertainty,
    cancel_flag: *std.atomic.Value(bool),
) !gateway_client.StreamResult {
    return gateway_client.streamGatewayProviderToolCompletionBounded(
        alloc,
        .{
            .api_key = api_key,
            .team = team,
            .model = model,
            .retry_count = request_retry_count,
            .chat_url = chat_url,
            .payload = payload,
            .delivery = delivery,
        },
        expected_provider_tool_name,
        deadline,
        cancel_flag,
    );
}

fn normalizeGatewayCompletion(
    alloc: Allocator,
    request: Request,
    completion: shared_types.ModelCompletion,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    var content: std.ArrayList(web_search_contract.ResultItem) = .empty;
    errdefer deinitItems(alloc, &content);

    var search_requests: u32 = 0;
    const admission = shared_types.authoritativeToolAdmission(completion);
    const admitted = switch (admission) {
        .admitted => true,
        .reject_duplicate_identity => blk: {
            try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "provider search tool identity is duplicated") });
            break :blk false;
        },
        .reject_malformed_identity => |failure| blk: {
            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(
                alloc,
                "provider search tool identity is malformed ({s})",
                .{@tagName(failure)},
            ) });
            break :blk false;
        },
        .reject_malformed_provider_result => |failure| blk: {
            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(
                alloc,
                "provider search result identity is malformed ({s})",
                .{@tagName(failure)},
            ) });
            break :blk false;
        },
        .reject_malformed_provider_arguments => blk: {
            try content.append(alloc, .{
                .error_text = try alloc.dupe(
                    u8,
                    "provider search tool arguments are malformed",
                ),
            });
            break :blk false;
        },
    };
    if (admitted) {
        const expected_tool_name = try selectedToolName(request.backend);
        var provider_call: ?shared_types.ToolCall = null;
        for (completion.tool_calls) |call| {
            if (call.provenance != .provider_executed or !std.mem.eql(u8, call.name, expected_tool_name)) {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned an unexpected tool call") });
                break;
            }
            if (provider_call != null) {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned multiple provider search calls") });
                break;
            }
            provider_call = call;
        }

        if (content.items.len == 0) {
            if (provider_call) |call| {
                if (call.provider_result) |provider_result| {
                    search_requests += 1;
                    map_result: {
                        const hits = parseSearchHits(alloc, provider_result, request.max_results) catch |err| {
                            try content.append(alloc, .{ .error_text = try std.fmt.allocPrint(alloc, "provider search result decode failed: {s}", .{@errorName(err)}) });
                            break :map_result;
                        };
                        errdefer deinitHits(alloc, hits);
                        try content.append(alloc, .{ .search = .{
                            .tool_use_id = try alloc.dupe(u8, call.id),
                            .content = hits,
                        } });
                        if (on_progress) |progress| progress(progress_ctx orelse return error.MissingProgressContext, .{
                            .results_received = .{
                                .query = request.query,
                                .result_count = hits.len,
                            },
                        });
                    }
                } else {
                    try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "provider search returned no result") });
                }
            } else {
                try content.append(alloc, .{ .error_text = try alloc.dupe(u8, "private worker returned no provider search call") });
            }
        }
    }

    if (completion.finish_reason == null) {
        try content.append(alloc, .{ .terminal_incomplete = .{
            .stop_reason = try alloc.dupe(u8, "missing_provider_finish"),
            .message = try alloc.dupe(u8, "private web search worker stopped before completion"),
        } });
    } else if (completion.finish_reason == .provider_error or completion.finish_reason == .content_filter) {
        const reason = completion.finish_reason.?;
        try content.append(alloc, .{ .terminal_incomplete = .{
            .stop_reason = try alloc.dupe(u8, reason.label()),
            .message = try alloc.dupe(u8, "private web search worker reported an unsuccessful completion"),
        } });
    }

    return .{
        .content = try content.toOwnedSlice(alloc),
        .stop_reason = if (completion.finish_reason) |reason| try alloc.dupe(u8, reason.label()) else null,
        .usage = .{
            .input_tokens = completion.usage.input_tokens orelse 0,
            .output_tokens = completion.usage.output_tokens orelse 0,
            .web_search_requests = search_requests,
        },
    };
}

fn parseSearchHits(alloc: Allocator, json_text: []const u8, max_results: u8) ![]web_search_contract.Source {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    const values = searchResultValues(parsed.value) orelse return &.{};
    var hits: std.ArrayList(web_search_contract.Source) = .empty;
    errdefer deinitHitsList(alloc, &hits);
    for (values) |value| {
        if (hits.items.len >= max_results) break;
        const hit = try decodeSearchHit(alloc, value) orelse continue;
        try hits.append(alloc, hit);
    }
    return try hits.toOwnedSlice(alloc);
}

fn searchResultValues(value: std.json.Value) ?[]const std.json.Value {
    if (value == .array) return value.array.items;
    if (value != .object) return null;
    inline for (&.{ "results", "sources", "data", "response" }) |name| {
        if (value.object.get(name)) |nested| {
            if (searchResultValues(nested)) |values| return values;
        }
    }
    return null;
}

fn decodeSearchHit(alloc: Allocator, value: std.json.Value) !?web_search_contract.Source {
    if (value != .object) return null;
    const url = stringField(value.object, &.{ "url", "link" }) orelse return null;
    if (!isSafeCitationUrl(url)) return null;
    const title = stringField(value.object, &.{ "title", "name" }) orelse url;
    const owned_title = try alloc.dupe(u8, title);
    errdefer alloc.free(owned_title);
    return .{
        .title = owned_title,
        .url = try alloc.dupe(u8, url),
    };
}

fn isSafeCitationUrl(url: []const u8) bool {
    const authority_start = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        return false;
    var authority_end = authority_start;
    while (authority_end < url.len) : (authority_end += 1) {
        const char = url[authority_end];
        if (char < 0x20 or char == 0x7f or std.ascii.isWhitespace(char)) return false;
        if (char == '/' or char == '?' or char == '#') break;
    }
    if (authority_end == authority_start) return false;
    if (std.mem.findScalar(u8, url[authority_start..authority_end], '@') != null) return false;
    for (url[authority_end..]) |char| {
        if (char < 0x20 or char == 0x7f or std.ascii.isWhitespace(char)) return false;
    }
    return true;
}

fn stringField(object: std.json.ObjectMap, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        const value = object.get(name) orelse continue;
        if (value == .string) return value.string;
    }
    return null;
}

fn selectedToolName(backend: web_search_contract.SearchBackendId) ![]const u8 {
    if (backend.eql(perplexity_search_backend_id)) return "perplexity_search";
    if (backend.eql(parallel_search_backend_id)) return "parallel_search";
    return error.InvalidWebSearchBackend;
}

fn writePerplexityDomains(alloc: Allocator, writer: *std.Io.Writer, domains: []const []const u8, blocked: bool) !void {
    try writer.writeAll(",\"searchDomainFilter\":[");
    for (domains, 0..) |domain, index| {
        if (index > 0) try writer.writeByte(',');
        if (blocked) {
            const prefixed = try std.fmt.allocPrint(alloc, "-{s}", .{domain});
            defer alloc.free(prefixed);
            try std.json.Stringify.value(prefixed, .{}, writer);
        } else {
            try std.json.Stringify.value(domain, .{}, writer);
        }
    }
    try writer.writeByte(']');
}

fn writeParallelDomains(writer: *std.Io.Writer, name: []const u8, domains: []const []const u8) !void {
    try writer.print(",\"sourcePolicy\":{{\"{s}\":[", .{name});
    for (domains, 0..) |domain, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(domain, .{}, writer);
    }
    try writer.writeAll("]}");
}

fn boundedDupe(alloc: Allocator, text: []const u8, max_len: usize) ![]u8 {
    return try alloc.dupe(u8, text[0..@min(text.len, max_len)]);
}

fn hasValues(values: ?[]const []const u8) bool {
    return if (values) |actual| actual.len > 0 else false;
}

fn deinitItems(alloc: Allocator, items: *std.ArrayList(web_search_contract.ResultItem)) void {
    for (items.items) |item| item.deinit(alloc);
    items.deinit(alloc);
}

fn deinitHitsList(alloc: Allocator, hits: *std.ArrayList(web_search_contract.Source)) void {
    for (hits.items) |hit| hit.deinit(alloc);
    hits.deinit(alloc);
}

fn deinitHits(alloc: Allocator, hits: []web_search_contract.Source) void {
    for (hits) |hit| hit.deinit(alloc);
    if (hits.len > 0) alloc.free(hits);
}

fn expectGatewayWorkerAdapterExecutes(backend: web_search_contract.SearchBackendId) !void {
    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var fake = FakeStream{};
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var response = try executeGatewayWorker(alloc, .{
        .api_key = "key",
        .team = "team_123",
        .model = "provider/model",
        .retry_count = 1,
        .chat_url = "https://ai-gateway.vercel.sh/v3/ai/language-model",
        .usage = &usage,
        .usage_allocator = alloc,
        .stream_ctx = @ptrCast(&fake),
        .stream_fn = FakeStream.execute,
    }, .{
        .backend = backend,
        .query = "latest Zig release",
        .max_results = 1,
        .cancel_flag = &cancel_flag,
    }, null, null);
    defer response.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("team_123", fake.team.?);
    const deadline = fake.deadline orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(std.Io.Clock.awake, deadline.clock);
    try std.testing.expect(std.Io.Clock.Timestamp.compare(
        std.Io.Clock.Timestamp.now(std.testing.io, .awake),
        .lt,
        deadline,
    ));
    try std.testing.expect(fake.saw_inner_prompt);
    try std.testing.expect(fake.saw_output_bound);
    try std.testing.expect(fake.saw_required_tool_choice);
    try std.testing.expect(fake.saw_expected_provider_tool);
    var usage_snapshot = try usage.snapshot(alloc);
    defer usage_snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), usage_snapshot.pending.len);
    if (backend.eql(perplexity_search_backend_id)) {
        try std.testing.expect(fake.saw_perplexity);
        try std.testing.expect(!fake.saw_parallel);
    } else {
        try std.testing.expect(backend.eql(parallel_search_backend_id));
        try std.testing.expect(!fake.saw_perplexity);
        try std.testing.expect(fake.saw_parallel);
    }
    try std.testing.expectEqual(@as(usize, 1), response.content[0].search.content.len);
    try std.testing.expectEqual(@as(u32, 1), response.usage.?.web_search_requests);
}

const FakeStream = struct {
    calls: usize = 0,
    fail_before_send: bool = false,
    fail_after_send: bool = false,
    team: ?[]const u8 = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    saw_perplexity: bool = false,
    saw_parallel: bool = false,
    saw_inner_prompt: bool = false,
    saw_output_bound: bool = false,
    saw_required_tool_choice: bool = false,
    saw_expected_provider_tool: bool = false,

    fn execute(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        _: []const u8,
        team: ?[]const u8,
        _: []const u8,
        _: usize,
        _: []const u8,
        payload: []const u8,
        expected_provider_tool_name: []const u8,
        deadline: std.Io.Clock.Timestamp,
        delivery: *gateway_client.DeliveryCertainty,
        _: *std.atomic.Value(bool),
    ) anyerror!gateway_client.StreamResult {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        if (self.fail_before_send) return error.AccessDenied;
        if (self.fail_after_send) {
            delivery.markPossiblySent();
            return error.ConnectionResetByPeer;
        }
        self.team = team;
        self.deadline = deadline;
        self.saw_perplexity = std.mem.find(u8, payload, "gateway.perplexity_search") != null;
        self.saw_parallel = std.mem.find(u8, payload, "gateway.parallel_search") != null;
        self.saw_inner_prompt = std.mem.find(u8, payload, "Research the user's query with the web_search tool and preserve sources for citation.") != null;
        self.saw_output_bound = std.mem.find(u8, payload, "\"maxOutputTokens\":4096") != null;
        self.saw_required_tool_choice = std.mem.find(u8, payload, "\"toolChoice\":{\"type\":\"required\"}") != null;
        const tool_name = if (self.saw_parallel) "parallel_search" else "perplexity_search";
        self.saw_expected_provider_tool = std.mem.eql(u8, expected_provider_tool_name, tool_name);
        return .{
            .status = .ok,
            .completion = .{
                .generation_id = try alloc.dupe(
                    u8,
                    "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
                ),
                .finish_reason = .stop,
                .tool_calls = try alloc.dupe(shared_types.ToolCall, &.{
                    .{
                        .id = try alloc.dupe(u8, "search_1"),
                        .name = try alloc.dupe(u8, tool_name),
                        .arguments_json = try alloc.dupe(u8, "{}"),
                        .provider_result = try alloc.dupe(u8, "{\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"},{\"title\":\"Zig downloads\",\"url\":\"https://ziglang.org/download\"}]}"),
                        .provenance = .provider_executed,
                    },
                }),
                .usage = .{ .input_tokens = 2, .output_tokens = 3 },
            },
        };
    }
};

fn stubFetchCreditsError(
    _: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return error.StubFetchFailed;
}

fn stubFetchInvalidCreditsJson(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{"),
    };
}

fn stubFetchCreditsObject(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{\"balance\":\"10\",\"used\":\"2\",\"plan\":\"pro\"}"),
    };
}

var captured_credits_path: [256]u8 = undefined;
var captured_credits_path_len: usize = 0;

fn stubCaptureCreditsPath(
    alloc: Allocator,
    _: ?[]const u8,
    path: []const u8,
) anyerror!gateway_client.GetResult {
    captured_credits_path_len = @min(path.len, captured_credits_path.len);
    @memcpy(
        captured_credits_path[0..captured_credits_path_len],
        path[0..captured_credits_path_len],
    );
    return .{
        .status = .ok,
        .body = try alloc.dupe(u8, "{\"balance\":\"10\",\"total_used\":\"2\"}"),
    };
}

fn stubFetchForbiddenCredits(
    alloc: Allocator,
    _: ?[]const u8,
    _: []const u8,
) anyerror!gateway_client.GetResult {
    return .{
        .status = .forbidden,
        .body = try alloc.dupe(u8, "{\"error\":{\"code\":\"credit_card_required\",\"message\":\"Buy credits to use AI Gateway.\"}}"),
    };
}

pub fn fetchModelIds(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, null, .full);
}

pub fn fetchModelIdsCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, cancel_flag, .full);
}

pub fn fetchPickerModelIdsCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList([]u8) {
    return fetchModelIdsForView(alloc, access, path, cancel_flag, .picker);
}

pub fn fetchModelCatalog(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, null, .full);
}

pub fn fetchModelCatalogCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, cancel_flag, .full);
}

pub fn fetchPickerModelCatalog(alloc: std.mem.Allocator, access: credentials.CatalogAccess, path: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, null, .picker);
}

pub fn fetchPickerModelCatalogCancellable(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !std.ArrayList(ModelCatalogEntry) {
    return fetchModelCatalogForView(alloc, access, path, cancel_flag, .picker);
}

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

pub const ModelCatalogEntry = model_catalog.ModelCatalogEntry;
pub const freeModelCatalog = model_catalog.freeModelCatalog;

fn parseSortedModelIds(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList([]u8) {
    return parseModelIdsForView(alloc, json_text, .full);
}

const ModelCatalogView = model_catalog.View;

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const response = fetchModelCatalogResponse(
        alloc,
        input.access,
        input.endpoint,
        input.cancel_flag,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = catalogRequestFailure(err) };
    };
    const json_text = switch (response) {
        .success => |body| body,
        .http_status => |status| return .{
            .failure = model_catalog.failureForHttpStatus(status),
        },
    };
    defer alloc.free(json_text);

    const catalog = parseModelCatalogForView(alloc, json_text, input.view) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

fn fetchModelIdsForView(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    view: ModelCatalogView,
) !std.ArrayList([]u8) {
    var catalog = try fetchModelCatalogForView(alloc, access, path, cancel_flag, view);
    defer freeModelCatalog(alloc, &catalog);

    return model_catalog.projectModelIds(alloc, catalog.items);
}

fn fetchModelCatalogForView(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    view: ModelCatalogView,
) !std.ArrayList(ModelCatalogEntry) {
    const response = try fetchModelCatalogResponse(alloc, access, path, cancel_flag);
    const json_text = switch (response) {
        .success => |body| body,
        .http_status => |status| return model_catalog.failureForHttpStatus(status).asError(),
    };
    defer alloc.free(json_text);

    return parseModelCatalogForView(alloc, json_text, view);
}

fn fetchModelCatalogResponse(
    alloc: std.mem.Allocator,
    access: credentials.CatalogAccess,
    path: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) !gateway_client.GatewayJsonResult {
    if (cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }

    const team_path = try modelCatalogTeamPath(alloc, path, access);
    defer if (team_path) |owned| alloc.free(owned);

    const model_catalog_url = try modelCatalogUrl(
        alloc,
        team_path orelse path,
        io_mod.getenv(base_url_env),
    );
    defer alloc.free(model_catalog_url);

    const api_key = access.authorizationCredential();
    const gateway_team = modelCatalogHeaderTeam(access);
    return if (cancel_flag) |flag|
        gateway_client.fetchGatewayJsonCancellable(alloc, api_key, gateway_team, model_catalog_url, flag)
    else
        gateway_client.fetchGatewayJson(alloc, api_key, gateway_team, model_catalog_url);
}

fn modelCatalogTeamPath(
    alloc: Allocator,
    path: []const u8,
    access: credentials.CatalogAccess,
) Allocator.Error!?[]u8 {
    if (access.credentialSource() != .fx_login) return null;
    const team = access.teamContext() orelse return null;
    if (!shared_types.validGatewayTeam(team)) return null;
    return try std.fmt.allocPrint(alloc, "{s}?teamId={s}", .{ path, team });
}

fn modelCatalogHeaderTeam(access: credentials.CatalogAccess) ?[]const u8 {
    if (access.credentialSource() == .fx_login) return null;
    return access.teamContext();
}

fn catalogRequestFailure(err: anyerror) model_catalog.Failure {
    if (err == error.OutOfMemory) return .{ .category = .resource_exhausted };
    if (err == error.Cancelled) return .{ .category = .cancellation };
    if (isInvalidGatewayResponse(err)) return .{ .category = .malformed_response };
    return .{
        .category = .transport,
        .retryable = gateway_client.isRetryableGatewayError(err),
    };
}

fn isInvalidGatewayResponse(err: anyerror) bool {
    return switch (err) {
        error.HttpConnectionHeaderUnsupported,
        error.HttpContentEncodingUnsupported,
        error.HttpHeaderContinuationsUnsupported,
        error.HttpHeadersInvalid,
        error.HttpTransferEncodingUnsupported,
        error.InvalidContentLength,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpHeadersOversize,
        error.UnsupportedCompressionMethod,
        => true,
        else => false,
    };
}

fn modelCatalogUrl(alloc: Allocator, path: []const u8, base_url_override: ?[]const u8) ![]u8 {
    const base_url = if (base_url_override) |candidate| blk: {
        if (gateway_client.isLoopbackHttpUrl(candidate)) break :blk candidate;
        debug_trace.logf("gateway", "ignoring {s}: not loopback http", .{base_url_env});
        break :blk default_model_catalog_base_url;
    } else default_model_catalog_base_url;

    return std.fmt.allocPrint(alloc, "{s}{s}", .{ base_url, path });
}

var stable_models_test_environ: ?*std.process.Environ.Map = null;

fn stableModelsTestEnviron() !*const std.process.Environ.Map {
    if (stable_models_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_models_test_environ = map;
    return map;
}

const ModelsUrlTestEnv = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: std.mem.Allocator, models_url: []const u8) !*ModelsUrlTestEnv {
        _ = try stableModelsTestEnviron();

        const self = try alloc.create(ModelsUrlTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put(e2e_gateway_models_url_env, models_url);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *ModelsUrlTestEnv) void {
        if (stable_models_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn installLoopbackModelsEnv(alloc: std.mem.Allocator, port: u16) !*ModelsUrlTestEnv {
    const models_url = try std.fmt.allocPrint(
        alloc,
        "http://127.0.0.1:{d}/v1/models",
        .{port},
    );
    defer alloc.free(models_url);
    return ModelsUrlTestEnv.install(alloc, models_url);
}

fn expectModelCatalogTeamHeaderOmitted(gateway_team: ?[]const u8) !void {
    var fixture = try gateway_client.TestModelCatalogFixture.init();
    defer fixture.deinit();
    try fixture.start();
    try std.testing.expect(fixture.waitForAcceptStart(5000));

    const env = try installLoopbackModelsEnv(std.testing.allocator, fixture.port());
    defer env.deinit();

    var ids = try fetchModelIds(std.testing.allocator, credentials.catalogAccessForCredential(.ai_gateway_api_key, "test-key", gateway_team), models_path);
    defer collections.freeStringList(std.testing.allocator, &ids);

    try std.testing.expectEqualStrings("Bearer test-key", fixture.capturedHeaderValue("authorization").?);
    try std.testing.expect(fixture.capturedHeaderValue(gateway_client.vercel_ai_gateway_team_header) == null);
    if (fixture.failure()) |err| return err;
}

fn parseModelIdsForView(
    alloc: std.mem.Allocator,
    json_text: []const u8,
    view: ModelCatalogView,
) !std.ArrayList([]u8) {
    var catalog = try parseModelCatalogForView(alloc, json_text, view);
    defer freeModelCatalog(alloc, &catalog);

    return model_catalog.projectModelIds(alloc, catalog.items);
}

pub fn parseModelCatalogForView(
    alloc: std.mem.Allocator,
    json_text: []const u8,
    view: ModelCatalogView,
) !std.ArrayList(ModelCatalogEntry) {
    var catalog = try parseSortedModelCatalog(alloc, json_text);
    switch (view) {
        .full => return catalog,
        .picker => {
            defer freeModelCatalog(alloc, &catalog);
            return model_catalog.projectPickerModelCatalog(alloc, catalog.items);
        },
    }
}

fn parseSortedModelCatalog(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList(ModelCatalogEntry) {
    var candidates: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer freeModelCatalog(alloc, &candidates);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedResponse;
    const data_value = parsed.value.object.get("data") orelse return error.MalformedResponse;
    if (data_value != .array) return error.MalformedResponse;

    for (data_value.array.items) |entry| {
        const candidate = (try parseModelCatalogEntry(alloc, entry)) orelse continue;
        candidates.append(alloc, candidate) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, candidate);
            return err;
        };
    }

    sort_utils.sort(ModelCatalogEntry, candidates.items, {}, model_catalog.compareModelCatalogEntries);

    return candidates;
}

fn parsePickerModelIds(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList([]u8) {
    return parseModelIdsForView(alloc, json_text, .picker);
}

fn parsePickerModelCatalog(alloc: std.mem.Allocator, json_text: []const u8) !std.ArrayList(ModelCatalogEntry) {
    return parseModelCatalogForView(alloc, json_text, .picker);
}

fn parseModelCatalogEntry(alloc: std.mem.Allocator, entry: std.json.Value) !?ModelCatalogEntry {
    if (entry != .object) return null;

    const model_type = if (entry.object.get("type")) |type_value| blk: {
        if (type_value == .string and !std.ascii.eqlIgnoreCase(type_value.string, "language")) {
            return null;
        }
        break :blk if (type_value == .string) type_value.string else "";
    } else "";

    const id_value = entry.object.get("id") orelse return null;
    if (id_value != .string) return null;

    const released = if (entry.object.get("released")) |value|
        switch (value) {
            .integer => value.integer,
            else => 0,
        }
    else
        0;

    const tags_value = entry.object.get("tags");
    const has_tool_use = optionalTagListContains(tags_value, "tool-use");
    var reasoning_efforts = try parseReasoningEfforts(alloc, entry.object.get("reasoning_options"));
    errdefer reasoning_efforts.deinit(alloc);
    const has_reasoning = optionalTagListContains(tags_value, "reasoning") or reasoning_efforts.items.len > 0;
    const supports_fast_mode = supportsFastMode(entry.object);
    const has_vision = optionalTagListContains(tags_value, "vision");
    const has_file_input = optionalTagListContains(tags_value, "file-input");
    const has_web_search = optionalTagListContains(tags_value, "web-search");
    const has_explicit_caching = optionalTagListContains(tags_value, "explicit-caching");
    const has_implicit_caching = optionalTagListContains(tags_value, "implicit-caching");

    const context_window = optionalUnsignedU32(entry.object.get("context_window"));
    const max_tokens = optionalUnsignedU32(entry.object.get("max_tokens"));
    const web_search_price = try parseWebSearchPrice(alloc, entry.object.get("pricing"));
    errdefer if (web_search_price) |value| alloc.free(value);

    const id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(id);
    const owned_model_type = try alloc.dupe(u8, model_type);
    errdefer alloc.free(owned_model_type);

    return .{
        .id = id,
        .model_type = owned_model_type,
        .released = released,
        .has_tool_use = has_tool_use,
        .has_reasoning = has_reasoning,
        .reasoning_efforts = reasoning_efforts,
        .supports_fast_mode = supports_fast_mode,
        .has_vision = has_vision,
        .has_file_input = has_file_input,
        .has_web_search = has_web_search,
        .has_explicit_caching = has_explicit_caching,
        .has_implicit_caching = has_implicit_caching,
        .context_window = context_window,
        .max_tokens = max_tokens,
        .web_search_price = web_search_price,
    };
}

fn parseReasoningEfforts(alloc: std.mem.Allocator, options: ?std.json.Value) !std.ArrayList(shared_types.ReasoningEffort) {
    var efforts: std.ArrayList(shared_types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);

    const value = options orelse return efforts;
    if (value != .array) return efforts;
    for (value.array.items) |option| {
        if (option != .object) continue;
        const option_type = option.object.get("type") orelse continue;
        if (option_type != .string or !std.mem.eql(u8, option_type.string, "effort")) continue;
        const values = option.object.get("values") orelse continue;
        if (values != .array) continue;
        for (values.array.items) |raw| {
            if (efforts.items.len >= shared_types.ReasoningEffort.max_options) break;
            if (raw != .string) continue;
            const effort = shared_types.ReasoningEffort.parse(raw.string) orelse continue;
            if (effort.isDefault()) continue;
            try efforts.append(alloc, effort);
        }
        break;
    }
    return efforts;
}

fn hasToggleOption(options: ?std.json.Value) bool {
    const value = options orelse return false;
    if (value != .array) return false;
    for (value.array.items) |option| {
        if (option != .object) continue;
        const option_type = option.object.get("type") orelse continue;
        if (option_type == .string and std.mem.eql(u8, option_type.string, "toggle")) return true;
    }
    return false;
}

fn supportsFastMode(entry: std.json.ObjectMap) bool {
    if (hasToggleOption(entry.get("fast_options"))) return true;

    const pricing = entry.get("pricing");
    if (hasObjectField(pricing, "fast")) return true;

    const owned_by = entry.get("owned_by") orelse return false;
    if (owned_by != .string or !std.ascii.eqlIgnoreCase(owned_by.string, "openai")) return false;
    return hasObjectField(objectField(pricing, "service_tiers"), "priority");
}

fn objectField(value: ?std.json.Value, key: []const u8) ?std.json.Value {
    const actual = value orelse return null;
    if (actual != .object) return null;
    return actual.object.get(key);
}

fn hasObjectField(value: ?std.json.Value, key: []const u8) bool {
    const field = objectField(value, key) orelse return false;
    return field == .object;
}

fn optionalUnsignedU32(value: ?std.json.Value) u32 {
    const actual = value orelse return 0;
    if (actual != .integer or actual.integer <= 0) return 0;
    return std.math.cast(u32, actual.integer) orelse 0;
}

fn parseWebSearchPrice(alloc: std.mem.Allocator, pricing: ?std.json.Value) !?[]u8 {
    const pricing_value = pricing orelse return null;
    if (pricing_value != .object) return null;
    const price = pricing_value.object.get("web_search") orelse return null;
    return switch (price) {
        .string => |value| try alloc.dupe(u8, value),
        .integer, .float => blk: {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try std.json.Stringify.value(price, .{}, &out.writer);
            break :blk try out.toOwnedSlice();
        },
        else => null,
    };
}

fn optionalTagListContains(value: ?std.json.Value, needle: []const u8) bool {
    return if (value) |actual| tagListContains(actual, needle) else false;
}

fn tagListContains(value: std.json.Value, needle: []const u8) bool {
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item == .string and std.ascii.eqlIgnoreCase(item.string, needle)) return true;
    }
    return false;
}

fn idsContain(ids: []const []const u8, needle: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, needle)) return true;
    }
    return false;
}
