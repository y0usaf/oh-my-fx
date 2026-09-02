const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_result_errors = @import("tool_result_errors.zig");
const model_request_budget = @import("model_request_budget.zig");
const session_usage = @import("../session/session_usage.zig");
const web_search_contract = @import("web_search_contract.zig");
const web_search_policy = @import("web_search_policy.zig");
const web_search_provider = @import("web_search_provider.zig");
const test_builtin_tools = if (@import("builtin").is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;

pub const ClockFn = *const fn (*anyopaque) i64;

var default_clock_context: u8 = 0;

pub const Clock = struct {
    ctx: *anyopaque = @ptrCast(&default_clock_context),
    now_fn: ClockFn = defaultNow,

    fn now(self: Clock) i64 {
        return self.now_fn(self.ctx);
    }
};

pub const Config = struct {
    provider: ?web_search_provider.Provider = null,
    clock: Clock = .{},
    policy: ?web_search_policy.WebSearchPolicy = null,
    api_key: []const u8 = "",
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    worker_model: []const u8 = "",
    gateway_retry_count: usize = 3,
    gateway_chat_url: []const u8 = "https://ai-gateway.vercel.sh/v3/ai/language-model",
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
};

pub const Inputs = web_search_provider.Inputs;

const OwnedInputs = struct {
    api_key: []u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]u8 = null,
    worker_model: []u8,
    gateway_retry_count: usize,
    gateway_chat_url: []u8,
    // The usage pointer and allocator borrow the parent session's lifetime.
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,

    fn deinit(self: *OwnedInputs, alloc: Allocator) void {
        alloc.free(self.api_key);
        if (self.gateway_team) |team| alloc.free(team);
        alloc.free(self.worker_model);
        alloc.free(self.gateway_chat_url);
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedInputs) Inputs {
        return .{
            .api_key = self.api_key,
            .credential_source = self.credential_source,
            .gateway_team = self.gateway_team,
            .worker_model = self.worker_model,
            .gateway_retry_count = self.gateway_retry_count,
            .gateway_chat_url = self.gateway_chat_url,
            .usage = self.usage,
            .usage_allocator = self.usage_allocator,
        };
    }
};

pub const ExecutionOutput = web_search_contract.ExecutionOutput;

pub const Runtime = struct {
    provider: ?web_search_provider.Provider,
    clock: Clock,
    policy: web_search_policy.WebSearchPolicy,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    worker_model: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    usage: ?*session_usage.Usage,
    usage_allocator: Allocator,
    config_mutex: std.Io.Mutex = .init,
    fallback_cancel_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(config: Config) Runtime {
        return .{
            .provider = config.provider,
            .clock = config.clock,
            .policy = config.policy orelse if (config.provider) |provider| provider.policy else .{},
            .api_key = config.api_key,
            .credential_source = config.credential_source,
            .gateway_team = config.gateway_team,
            .worker_model = config.worker_model,
            .gateway_retry_count = config.gateway_retry_count,
            .gateway_chat_url = config.gateway_chat_url,
            .usage = config.usage,
            .usage_allocator = config.usage_allocator,
        };
    }

    pub fn deinit(_: *Runtime) void {}

    pub fn configure(self: *Runtime, inputs: Inputs) void {
        self.config_mutex.lockUncancelable(io_mod.getIo());
        defer self.config_mutex.unlock(io_mod.getIo());
        self.api_key = inputs.api_key;
        self.credential_source = inputs.credential_source;
        self.gateway_team = inputs.gateway_team;
        self.worker_model = inputs.worker_model;
        self.gateway_retry_count = inputs.gateway_retry_count;
        self.gateway_chat_url = inputs.gateway_chat_url;
        self.usage = inputs.usage;
        self.usage_allocator = inputs.usage_allocator;
    }

    pub fn dispatchBackend(self: *Runtime) tool_dispatch.WebSearchBackend {
        return .{ .ctx = @ptrCast(self), .execute_fn = executeForDispatch };
    }

    pub fn execute(
        self: *Runtime,
        alloc: Allocator,
        request: web_search_contract.Request,
        cancel_flag: *std.atomic.Value(bool),
    ) !ExecutionOutput {
        return self.executeWithProgress(alloc, request, cancel_flag, null, null);
    }

    pub fn executeWithProgress(
        self: *Runtime,
        alloc: Allocator,
        input: web_search_contract.Request,
        cancel_flag: *std.atomic.Value(bool),
        on_progress: ?web_search_contract.ProgressFn,
        progress_ctx: ?*anyopaque,
    ) !ExecutionOutput {
        const started_at_ms = self.clock.now();
        var inputs = try self.inputsSnapshot(alloc);
        defer inputs.deinit(alloc);
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        var policy = self.policy;
        if (self.provider) |provider| {
            if (try provider.preferredBackends()) |preferred_backends| {
                policy.preferred_backends = preferred_backends;
            }
        }
        const selected_backend = web_search_policy.selectBackend(policy, .{
            .has_allowed_domains = hasValues(input.allowed_domains),
            .has_blocked_domains = hasValues(input.blocked_domains),
        }) orelse return error.UnsupportedWebSearchFeatures;
        if (!model_request_budget.searchWorkerInputFitsLimit(
            if (self.provider) |provider| provider.input_overhead_bytes else 0,
            input.query,
            input.allowed_domains,
            input.blocked_domains,
            self.policy.max_input_bytes,
        )) return error.WebSearchRequestTooLarge;
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const request = web_search_contract.ProviderRequest{
            .backend = selected_backend.id,
            .query = input.query,
            .allowed_domains = input.allowed_domains,
            .blocked_domains = input.blocked_domains,
            .max_uses = self.policy.max_uses,
            .max_results = self.policy.max_results,
            .max_output_tokens = self.policy.max_output_tokens,
            .max_output_chars = self.policy.max_output_chars,
            .timeout_ms = self.policy.timeout_ms,
            .cancel_flag = cancel_flag,
        };

        const transport_started_at_ms = self.clock.now();
        var response = self.executeProvider(alloc, inputs.borrowed(), request, on_progress, progress_ctx) catch |err| {
            if (shouldRecordFailedNetworkCall(err)) {
                recordNetworkCall(inputs.worker_model, transport_started_at_ms, self.clock.now(), 0, null, null, @errorName(err));
            }
            return err;
        };
        defer response.deinit(alloc);

        const transport_finished_at_ms = self.clock.now();
        const usage = response.usage;
        const web_search_requests = if (usage) |value| value.web_search_requests else 0;
        recordNetworkCall(inputs.worker_model, transport_started_at_ms, transport_finished_at_ms, @intFromEnum(std.http.Status.ok), usage, response.stop_reason, "");
        const results = response.takeContent();
        const duration_ms = elapsedMs(started_at_ms, self.clock.now());
        debug_trace.logf("web_search", "complete backend={s} model={s} duration_ms={d} requests={d} stop_reason={s}", .{
            selected_backend.id.value,
            inputs.worker_model,
            duration_ms,
            web_search_requests,
            response.stop_reason orelse "(none)",
        });
        return .{
            .output = .{
                .query = input.query,
                .results = results,
                .incomplete = hasTerminalIncomplete(results),
                .duration_ms = duration_ms,
                .web_search_requests = web_search_requests,
            },
            .inner_usage = usage,
        };
    }

    fn inputsSnapshot(self: *Runtime, alloc: Allocator) !OwnedInputs {
        self.config_mutex.lockUncancelable(io_mod.getIo());
        defer self.config_mutex.unlock(io_mod.getIo());
        const api_key = try alloc.dupe(u8, self.api_key);
        errdefer alloc.free(api_key);
        const gateway_team = if (self.gateway_team) |team| try alloc.dupe(u8, team) else null;
        errdefer if (gateway_team) |team| alloc.free(team);
        const worker_model = try alloc.dupe(u8, self.worker_model);
        errdefer alloc.free(worker_model);
        const gateway_chat_url = try alloc.dupe(u8, self.gateway_chat_url);
        return .{
            .api_key = api_key,
            .credential_source = self.credential_source,
            .gateway_team = gateway_team,
            .worker_model = worker_model,
            .gateway_retry_count = self.gateway_retry_count,
            .gateway_chat_url = gateway_chat_url,
            .usage = self.usage,
            .usage_allocator = self.usage_allocator,
        };
    }

    fn executeProvider(
        self: *Runtime,
        alloc: Allocator,
        inputs: Inputs,
        request: web_search_contract.ProviderRequest,
        on_progress: ?web_search_contract.ProgressFn,
        progress_ctx: ?*anyopaque,
    ) !web_search_contract.ProviderResponse {
        const provider = self.provider orelse return error.MissingWebSearchProvider;
        return provider.execute(alloc, inputs, request, on_progress, progress_ctx);
    }
};

const ProgressForwarder = struct {
    dispatch: tool_dispatch.DispatchContext,

    fn onProgress(raw_ctx: *anyopaque, progress: web_search_contract.Progress) void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        const callback = self.dispatch.on_web_search_progress orelse return;
        const callback_ctx = self.dispatch.web_search_progress_ctx orelse return;
        const update: types.WebSearchProgress = switch (progress) {
            .query_update => |query| .{ .query_started = query },
            .results_received => |entry| .{ .results_received = .{
                .query = entry.query,
                .result_count = entry.result_count,
            } },
        };
        callback(callback_ctx, self.dispatch.tool_call_id, update);
    }
};

fn executeForDispatch(
    raw_ctx: *anyopaque,
    ctx: tool_dispatch.DispatchContext,
    request: web_search_contract.Request,
) anyerror!web_search_contract.ExecutionOutput {
    const self: *Runtime = @ptrCast(@alignCast(raw_ctx));
    var progress_forwarder = ProgressForwarder{ .dispatch = ctx };
    return self.executeWithProgress(
        ctx.allocator,
        request,
        ctx.cancel_flag orelse &self.fallback_cancel_flag,
        if (ctx.on_web_search_progress != null) ProgressForwarder.onProgress else null,
        if (ctx.on_web_search_progress != null) @ptrCast(&progress_forwarder) else null,
    );
}

fn defaultNow(_: *anyopaque) i64 {
    return io_mod.milliTimestamp();
}

fn elapsedMs(started_at_ms: i64, finished_at_ms: i64) u64 {
    if (finished_at_ms <= started_at_ms) return 0;
    return @intCast(finished_at_ms - started_at_ms);
}

fn recordNetworkCall(
    model: []const u8,
    started_at_ms: i64,
    finished_at_ms: i64,
    status: u16,
    usage: ?types.ToolUsage,
    stop_reason: ?[]const u8,
    error_name: []const u8,
) void {
    var call: diagnostics.NetworkCall = .{
        .kind = .web_search,
        .started_at_ms = started_at_ms,
        .duration_ms = clampU64ToU32(elapsedMs(started_at_ms, finished_at_ms)),
        .status = status,
        .input_tokens = if (usage) |value| clampU64ToU32(value.input_tokens) else 0,
        .output_tokens = if (usage) |value| clampU64ToU32(value.output_tokens) else 0,
        .is_web_search = true,
        .web_search_requests = if (usage) |value| value.web_search_requests else 0,
    };
    call.setModel(model);
    if (stop_reason) |reason| call.setTerminalStopReason(reason);
    if (error_name.len > 0) call.setError(error_name);
    diagnostics.recordNetworkCall(call);
}

fn clampU64ToU32(value: u64) u32 {
    return @intCast(@min(value, std.math.maxInt(u32)));
}

fn shouldRecordFailedNetworkCall(err: anyerror) bool {
    return switch (err) {
        error.Cancelled,
        error.ConflictingDomainFilters,
        error.MissingGatewaySearchConfiguration,
        error.MissingWebSearchProvider,
        error.OutOfMemory,
        => false,
        else => true,
    };
}

fn hasValues(maybe_strings: ?[]const []const u8) bool {
    return if (maybe_strings) |strings| strings.len > 0 else false;
}

fn hasTerminalIncomplete(items: []const web_search_contract.ResultItem) bool {
    for (items) |item| {
        if (item == .terminal_incomplete) return true;
    }
    return false;
}

const FakeProvider = struct {
    calls: usize = 0,
    last_backend: ?web_search_contract.SearchBackendId = null,
    preferred_backends: ?[]const web_search_contract.SearchBackendId = null,
    configured_inputs_seen: bool = false,
    response_kind: enum { empty, source, incomplete, interleaved_incomplete } = .empty,
    transport_error: ?enum { cancelled, timeout } = null,

    fn provider(self: *@This()) web_search_provider.Provider {
        return .{
            .context = @ptrCast(self),
            .policy = test_policy,
            .preferred_backends_fn = preferredBackends,
            .execute_fn = executeProvider,
        };
    }

    fn preferredBackends(raw_ctx: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx orelse return error.MissingTestProvider));
        return self.preferred_backends;
    }

    fn executeProvider(
        raw_ctx: ?*anyopaque,
        alloc: Allocator,
        inputs: Inputs,
        request: web_search_contract.ProviderRequest,
        on_progress: ?web_search_contract.ProgressFn,
        progress_ctx: ?*anyopaque,
    ) !web_search_contract.ProviderResponse {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx orelse return error.MissingTestProvider));
        self.configured_inputs_seen = std.mem.eql(u8, inputs.api_key, "provider-key") and
            std.mem.eql(u8, inputs.worker_model, "provider/private-worker") and
            inputs.gateway_retry_count == 2 and
            std.mem.eql(u8, inputs.gateway_chat_url, "https://gateway.test/chat");
        return execute(@ptrCast(self), alloc, request, on_progress, progress_ctx);
    }

    fn execute(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        request: web_search_contract.ProviderRequest,
        _: ?web_search_contract.ProgressFn,
        _: ?*anyopaque,
    ) anyerror!web_search_contract.ProviderResponse {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        self.last_backend = request.backend;
        if (self.transport_error) |transport_error| {
            return switch (transport_error) {
                .cancelled => error.Cancelled,
                .timeout => error.TimeoutExpired,
            };
        }
        return switch (self.response_kind) {
            .empty => .{},
            .source => .{
                .content = try alloc.dupe(web_search_contract.ResultItem, &.{
                    .{ .search = .{
                        .tool_use_id = try alloc.dupe(u8, "search_1"),
                        .content = try alloc.dupe(web_search_contract.Source, &.{
                            .{
                                .title = try alloc.dupe(u8, "Zig release"),
                                .url = try alloc.dupe(u8, "https://ziglang.org/download/"),
                            },
                        }),
                    } },
                }),
                .usage = .{ .input_tokens = 12, .output_tokens = 34, .web_search_requests = 1 },
            },
            .incomplete => .{
                .content = try alloc.dupe(web_search_contract.ResultItem, &.{
                    .{ .commentary = try alloc.dupe(u8, "partial") },
                    .{ .terminal_incomplete = .{
                        .stop_reason = try alloc.dupe(u8, "max_tokens"),
                        .message = try alloc.dupe(u8, "incomplete"),
                    } },
                }),
                .stop_reason = try alloc.dupe(u8, "max_tokens"),
                .usage = .{ .web_search_requests = 1 },
            },
            .interleaved_incomplete => .{
                .content = try alloc.dupe(web_search_contract.ResultItem, &.{
                    .{ .commentary = try alloc.dupe(u8, "commentary A") },
                    .{ .search = .{
                        .tool_use_id = try alloc.dupe(u8, "search_1"),
                        .content = try alloc.dupe(web_search_contract.Source, &.{
                            .{
                                .title = try alloc.dupe(u8, "Zig release"),
                                .url = try alloc.dupe(u8, "https://ziglang.org/download/"),
                            },
                        }),
                    } },
                    .{ .error_text = try alloc.dupe(u8, "too_many_requests") },
                    .{ .commentary = try alloc.dupe(u8, "commentary B") },
                    .{ .search = .{
                        .tool_use_id = try alloc.dupe(u8, "search_2"),
                        .content = try alloc.dupe(web_search_contract.Source, &.{
                            .{
                                .title = try alloc.dupe(u8, "Release notes"),
                                .url = try alloc.dupe(u8, "https://ziglang.org/release-notes/"),
                            },
                        }),
                    } },
                    .{ .terminal_incomplete = .{
                        .stop_reason = try alloc.dupe(u8, "max_tokens"),
                        .message = try alloc.dupe(u8, "incomplete"),
                    } },
                }),
                .stop_reason = try alloc.dupe(u8, "max_tokens"),
                .usage = .{ .input_tokens = 12, .output_tokens = 34, .web_search_requests = 2 },
            },
        };
    }
};

const test_primary_backend = web_search_contract.SearchBackendId{ .value = "test.primary" };
const test_secondary_backend = web_search_contract.SearchBackendId{ .value = "test.secondary" };
const test_backend_order = [_]web_search_contract.SearchBackendId{ test_primary_backend, test_secondary_backend };
const test_backend_policies = [_]web_search_policy.BackendPolicy{
    .{
        .id = test_primary_backend,
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
        .id = test_secondary_backend,
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
const test_policy = web_search_policy.WebSearchPolicy{
    .preferred_backends = &test_backend_order,
    .backend_policies = &test_backend_policies,
};

fn fakeRuntime(fake: *FakeProvider) Runtime {
    return Runtime.init(.{
        .provider = fake.provider(),
        .worker_model = "provider/private-worker",
    });
}

var permission_decider_calls: usize = 0;

fn denyPermission(_: *const tool_dispatch.Tool, _: tool_dispatch.ToolInput, _: tool_dispatch.DispatchContext) @import("../permissions/permission_gate.zig").Decision {
    permission_decider_calls += 1;
    return .{ .action = .deny, .reason = "test deny" };
}

fn allowPermission(_: *const tool_dispatch.Tool, _: tool_dispatch.ToolInput, _: tool_dispatch.DispatchContext) @import("../permissions/permission_gate.zig").Decision {
    permission_decider_calls += 1;
    return .{ .action = .allow, .reason = "test allow" };
}

const SearchConfigStress = struct {
    runtime: *Runtime,
    inputs: Inputs,

    fn run(self: SearchConfigStress) void {
        for (0..2000) |_| self.runtime.configure(self.inputs);
    }
};
