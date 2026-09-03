const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const secret = @import("../core/auth/secret.zig");
const agent_stream_provider = @import("../core/agent/stream_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");

pub fn isRetryableGatewayError(err: anyerror) bool {
    return err == error.HttpConnectionClosing or
        err == error.ConnectionResetByPeer or
        err == error.ConnectionTimedOut;
}

pub fn networkFailureEvidence(
    err: anyerror,
    delivery: DeliveryCertainty.State,
) ?agent_stream_provider.NetworkFailureEvidence {
    const cause: agent_stream_provider.NetworkFailureCause = if (err == error.SystemResumed)
        .system_resumed
    else if (isRetryableAgentNetworkError(err))
        .transport_interrupted
    else
        return null;
    return .{ .cause = cause, .delivery = delivery };
}

fn isRetryableAgentNetworkError(err: anyerror) bool {
    return err == error.TlsInitializationFailed or
        err == error.ConnectionSetupTimedOut or
        err == error.UnknownHostName or
        err == error.NameServerFailure or
        err == error.NoAddressReturned or
        err == error.DetectingNetworkConfigurationFailed or
        err == error.AddressUnavailable or
        err == error.ConnectionPending or
        err == error.ConnectionRefused or
        err == error.HostUnreachable or
        err == error.NetworkUnreachable or
        err == error.NetworkDown or
        err == error.Timeout or
        err == error.WouldBlock or
        err == error.WriteFailed or
        err == error.ReadFailed or
        isRetryableGatewayError(err);
}

fn connectedIoFailure(
    cancelled: bool,
    system_resumed: bool,
    transport_error: anyerror,
) anyerror {
    if (cancelled) return error.Cancelled;
    if (system_resumed) return error.SystemResumed;
    return transport_error;
}

fn connectedIoFailureWithWatch(
    watch: ?*ConnectedRequestWatch,
    cancelled: bool,
    system_resumed: bool,
    transport_error: anyerror,
) anyerror {
    const mapped = connectedIoFailure(cancelled, system_resumed, transport_error);
    return if (watch) |state| state.finish_error(mapped) else mapped;
}

const HttpResult = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *HttpResult, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const PostResult = HttpResult;
pub const GetResult = HttpResult;

pub const GatewayJsonResult = union(enum) {
    /// Owned response body; the caller frees it with the request allocator.
    success: []u8,
    http_status: std.http.Status,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        switch (self.*) {
            .success => |body| alloc.free(body),
            .http_status => {},
        }
        self.* = undefined;
    }
};

pub const StreamCallback = agent_stream_provider.StreamCallback;
pub const ToolStartCallback = agent_stream_provider.ToolStartCallback;

const gateway_retry_base_delay_ns: u64 = 150 * std.time.ns_per_ms;
const gateway_connection_setup_timeout_ms: i64 = 30_000;
const gateway_retry_after_max_ns: u64 = 5 * std.time.ns_per_s;
const gateway_transfer_buffer_bytes: usize = 256 * 1024;
const provider_failure_detail_max_bytes: usize = 600;
const generation_response_max_bytes: usize = 128 * 1024;
const generation_lookup_timeout_ms: i64 = 30_000;
// Covers a 4 MiB string at worst-case JSON escaping plus SSE framing.
const max_sse_event_line_bytes: usize = 32 * 1024 * 1024;
const e2e_gateway_chat_url_env = "FX_E2E_GATEWAY_CHAT_URL";
const e2e_gateway_models_url_env = "FX_E2E_GATEWAY_MODELS_URL";
const e2e_gateway_credits_url_env = "FX_E2E_GATEWAY_CREDITS_URL";
const default_gateway_base_url = "https://ai-gateway.vercel.sh";
pub const vercel_ai_gateway_team_header = "x-vercel-ai-gateway-team";
/// Identifies fx on every AI Gateway request; the zig std.http default
/// (`zig/<version> (std.http)`) is never sent to the gateway.
pub const user_agent = "fx/" ++ build_options.app_version;
var resolved_model_trace_emitted = std.atomic.Value(bool).init(false);
var test_cancel_watcher_spawn_error: ?anyerror = null;

pub const StreamResult = struct {
    status: std.http.Status,
    completion: types.ModelCompletion = .{},
    err_body: ?[]u8 = null,
    retry_after_seconds: ?u64 = null,

    /// Frees all owned response buffers allocated for this stream result.
    pub fn deinit(self: *StreamResult, alloc: std.mem.Allocator) void {
        if (self.err_body) |body| alloc.free(body);
        if (self.completion.content) |content| alloc.free(content);
        if (self.completion.generation_id) |id| alloc.free(id);
        if (self.completion.billing) |billing| alloc.free(@constCast(billing.model));
        for (self.completion.tool_calls) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
            if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
            if (call.provider_result) |provider_result| alloc.free(provider_result);
        }
        if (self.completion.tool_calls.len > 0) alloc.free(self.completion.tool_calls);
        if (self.completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
        const status = self.status;
        self.* = .{ .status = status };
    }
};

/// Possibly-sent model requests are retried by the agent so transport retries
/// cannot multiply the logical response budget. Other gateway consumers keep
/// their existing bounded transport retry behavior.
pub const ProviderAttemptOwner = enum {
    transport,
    agent,
};

pub fn fetchGatewayJson(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
) !GatewayJsonResult {
    var result = try fetchGatewayGetAtUrl(alloc, api_key, gateway_team, url, e2e_gateway_models_url_env);
    if (failedGatewayJsonStatus(result.status)) |status| {
        result.deinit(alloc);
        return .{ .http_status = status };
    }

    return .{ .success = result.body };
}

pub fn fetchGatewayGetResult(alloc: std.mem.Allocator, api_key: ?[]const u8, path: []const u8) !GetResult {
    return fetchGatewayGet(alloc, api_key, null, path, e2e_gateway_credits_url_env);
}

pub fn fetchGatewayGenerationResult(
    alloc: std.mem.Allocator,
    api_key: []const u8,
    gateway_team: ?[]const u8,
    gateway_origin: []const u8,
    generation_id: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GetResult {
    if (!types.validGatewayGenerationId(generation_id)) return error.InvalidGenerationId;
    var operation = GenerationLookupOperation{
        .alloc = alloc,
        .api_key = api_key,
        .gateway_team = gateway_team,
        .gateway_origin = gateway_origin,
        .generation_id = generation_id,
    };
    return runBoundedHttpOperation(
        GetResult,
        alloc,
        cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(generation_lookup_timeout_ms),
        }),
        &operation,
    );
}

const GenerationLookupOperation = struct {
    alloc: std.mem.Allocator,
    api_key: []const u8,
    gateway_team: ?[]const u8,
    gateway_origin: []const u8,
    generation_id: []const u8,

    fn run(self: *@This()) !GetResult {
        const path = try std.fmt.allocPrint(
            self.alloc,
            "/v1/generation?id={s}",
            .{self.generation_id},
        );
        defer self.alloc.free(path);
        const url = try std.fmt.allocPrint(
            self.alloc,
            "{s}{s}",
            .{ self.gateway_origin, path },
        );
        defer self.alloc.free(url);
        const uri = try std.Uri.parse(url);

        var client: std.http.Client = .{
            .allocator = self.alloc,
            .io = io_mod.getIo(),
        };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(
            self.alloc,
            "Bearer {s}",
            .{self.api_key},
        );
        defer secret.zeroAndFree(self.alloc, auth_header);
        var extra_headers_buf: [1]std.http.Header = undefined;
        const extra_headers = gatewayModelCatalogExtraHeaders(
            &extra_headers_buf,
            self.gateway_team,
        );
        var req = try client.request(.GET, uri, .{
            .headers = .{
                .authorization = .{ .override = auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = user_agent },
            },
            .extra_headers = extra_headers,
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();
        try req.sendBodiless();
        if (req.connection) |conn| try conn.flush();

        var response = try req.receiveHead(&.{});
        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body = reader.allocRemaining(
            self.alloc,
            .limited(generation_response_max_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.GatewayGenerationResponseTooLarge,
            else => return err,
        };
        return .{ .status = response.head.status, .body = body };
    }
};

fn fetchGatewayGet(alloc: std.mem.Allocator, api_key: ?[]const u8, gateway_team: ?[]const u8, path: []const u8, e2e_url_env: []const u8) !GetResult {
    const default_url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ gatewayBaseUrl(), path });
    defer alloc.free(default_url);

    return fetchGatewayGetAtUrl(alloc, api_key, gateway_team, default_url, e2e_url_env);
}

fn fetchGatewayGetAtUrl(alloc: std.mem.Allocator, api_key: ?[]const u8, gateway_team: ?[]const u8, default_url: []const u8, e2e_url_env: []const u8) !GetResult {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const url = try resolveE2eGatewayUrl(e2e_url_env, default_url);

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);

    var headers: std.http.Client.Request.Headers = .{};
    headers.user_agent = .{ .override = user_agent };
    if (api_key) |key| {
        auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
        headers.authorization = .{ .override = auth_header.? };
    }
    var extra_headers_buf: [1]std.http.Header = undefined;
    const extra_headers = gatewayModelCatalogExtraHeaders(&extra_headers_buf, gateway_team);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = headers,
        .extra_headers = extra_headers,
        .response_writer = &out.writer,
        .redirect_behavior = .unhandled,
    });

    return .{
        .status = result.status,
        .body = try out.toOwnedSlice(),
    };
}

pub fn fetchGatewayJsonCancellable(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const request_url = try resolveE2eGatewayUrl(e2e_gateway_models_url_env, url);
    return fetchGatewayJsonAtUrlCancellable(alloc, api_key, gateway_team, request_url, cancel_flag);
}

fn fetchGatewayJsonAtUrlCancellable(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GatewayJsonResult {
    var operation = GatewayJsonFetchOperation{
        .alloc = alloc,
        .api_key = api_key,
        .gateway_team = gateway_team,
        .url = url,
        .cancel_flag = cancel_flag,
    };
    return runCancellableGatewayJsonFetch(alloc, cancel_flag, &operation);
}

const GatewayJsonFetchOperation = struct {
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !GatewayJsonResult {
        return fetchGatewayJsonAtUrlCore(
            self.alloc,
            self.api_key,
            self.gateway_team,
            self.url,
            self.cancel_flag,
        );
    }
};

fn runCancellableGatewayJsonFetch(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    operation: *GatewayJsonFetchOperation,
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const Event = union(enum) {
        request: anyerror!GatewayJsonResult,
        cancelled: anyerror!void,
    };
    const Runner = struct {
        fn run(value: *GatewayJsonFetchOperation) anyerror!GatewayJsonResult {
            return value.run();
        }
    };
    const Cleanup = struct {
        fn drain(result_alloc: std.mem.Allocator, select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_result = request_result catch continue;
                    late_result.deinit(result_alloc);
                },
                .cancelled => {},
            };
        }
    };

    var select_buffer: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.cancelled, waitForBoundedCancellation, .{cancel_flag}) catch |err| return err;
    select.concurrent(.request, Runner.run, .{operation}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    switch (event) {
        .request => |request_result| {
            Cleanup.drain(alloc, &select);
            if (cancel_flag.load(.seq_cst)) {
                var result = request_result catch return error.Cancelled;
                result.deinit(alloc);
                return error.Cancelled;
            }
            return request_result;
        },
        .cancelled => |cancel_result| {
            cancel_result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            return error.Cancelled;
        },
    }
}

fn fetchGatewayJsonAtUrlCore(
    alloc: std.mem.Allocator,
    api_key: ?[]const u8,
    gateway_team: ?[]const u8,
    url: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !GatewayJsonResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| secret.zeroAndFree(alloc, value);

    var headers: std.http.Client.Request.Headers = .{};
    headers.accept_encoding = .omit;
    headers.user_agent = .{ .override = user_agent };
    if (api_key) |key| {
        auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key});
        headers.authorization = .{ .override = auth_header.? };
    }
    var extra_headers_buf: [1]std.http.Header = undefined;
    const extra_headers = gatewayModelCatalogExtraHeaders(&extra_headers_buf, gateway_team);

    var req = client.request(.GET, uri, .{
        .headers = headers,
        .extra_headers = extra_headers,
        .redirect_behavior = .unhandled,
    }) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    defer req.deinit();
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (req.connection) |conn|
        try spawn_gateway_cancel_watcher(&cancel_watch_done, cancel_flag, null, null, null, conn.stream_writer.stream)
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    req.sendBodiless() catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (req.connection) |conn| {
        conn.flush() catch |err| {
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            return err;
        };
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = req.receiveHead(&.{}) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (failedGatewayJsonStatus(response.head.status)) |status| return .{ .http_status = status };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var transfer_buffer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    _ = reader.streamRemaining(&out.writer) catch |err| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    return .{ .success = try out.toOwnedSlice() };
}

fn failedGatewayJsonStatus(status: std.http.Status) ?std.http.Status {
    return if (status == .ok) null else status;
}

fn gatewayBaseUrl() []const u8 {
    const override = io_mod.getenv("FX_GATEWAY_BASE_URL") orelse return default_gateway_base_url;
    // The base URL carries the bearer token; only a loopback HTTP override is
    // trusted for local testing.
    if (!isLoopbackHttpUrl(override)) {
        debug_trace.logf("stream", "ignoring FX_GATEWAY_BASE_URL: not loopback http", .{});
        return default_gateway_base_url;
    }
    return override;
}

pub fn generationBaseUrl() []const u8 {
    return std.mem.trimEnd(u8, gatewayBaseUrl(), "/");
}

pub fn isTrustedGenerationOrigin(origin: []const u8) bool {
    return std.mem.eql(u8, origin, default_gateway_base_url) or
        isLoopbackHttpUrl(origin);
}

pub fn postGatewayCompletion(
    alloc: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
) !PostResult {
    const request_url = try resolveE2eGatewayUrl(e2e_gateway_chat_url_env, chat_url);
    var attempt: usize = 0;
    while (attempt < retry_count) : (attempt += 1) {
        debug_trace.logf("stream", "open attempt={d}/{d} url={s} payload_bytes={d}", .{ attempt + 1, retry_count, request_url, payload.len });
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
        defer secret.zeroAndFree(alloc, auth_header);

        const extra_headers = [_]std.http.Header{
            .{ .name = "HTTP-Referer", .value = "https://github.com/vercel-labs/fx" },
            .{ .name = "X-Title", .value = "fx" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "ai-gateway-protocol-version", .value = "0.0.1" },
            .{ .name = "ai-language-model-specification-version", .value = "4" },
            .{ .name = "ai-language-model-id", .value = model },
            .{ .name = "ai-language-model-streaming", .value = "false" },
        };

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const result = client.fetch(.{
            .location = .{ .url = request_url },
            .method = .POST,
            .payload = payload,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = user_agent },
            },
            .extra_headers = &extra_headers,
            .response_writer = &out.writer,
        }) catch |err| {
            if (isRetryableGatewayError(err) and attempt + 1 < retry_count) {
                io_mod.sleep((attempt + 1) * 150 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };

        if (isRetryableGatewayStatus(result.status) and attempt + 1 < retry_count) {
            const delay_ns = retryBackoffDelayNs(attempt);
            debug_trace.logf("stream", "retrying status={d} attempt={d} delay_ms={d}", .{ @intFromEnum(result.status), attempt + 1, delay_ns / std.time.ns_per_ms });
            io_mod.sleep(delay_ns);
            continue;
        }

        return .{
            .status = result.status,
            .body = try out.toOwnedSlice(),
        };
    }

    return error.HttpConnectionClosing;
}

/// Monotonic request-delivery evidence. It becomes possibly sent before the
/// first body write so any later transport failure is treated as potentially billed.
pub const DeliveryCertainty = agent_stream_provider.DeliveryCertainty;

const ConnectionSetupOutcome = union(enum) {
    request_succeeded,
    request_failed: anyerror,
};

const ConnectionSetupAction = union(enum) {
    succeed,
    retry,
    fail: anyerror,
    cancelled,
};

const ConnectionSetupSnapshot = struct {
    attempt: usize,
    attempt_limit: usize,
    now: std.Io.Clock.Timestamp,
    deadline: std.Io.Clock.Timestamp,
    cancelled: bool,
    delivery: DeliveryCertainty.State,
    outcome: ConnectionSetupOutcome,
};

const ConnectionSetupDecision = struct {
    action: ConnectionSetupAction,
};

fn decideConnectionSetup(snapshot: ConnectionSetupSnapshot) ConnectionSetupDecision {
    if (snapshot.cancelled) return .{ .action = .cancelled };
    if (!std.Io.Clock.Timestamp.compare(snapshot.now, .lt, snapshot.deadline)) {
        return .{ .action = .{ .fail = error.ConnectionSetupTimedOut } };
    }

    return switch (snapshot.outcome) {
        .request_succeeded => .{ .action = .succeed },
        .request_failed => |err| if (isRetryableConnectionSetupError(err) and
            snapshot.delivery == .definitely_unsent and
            snapshot.attempt < snapshot.attempt_limit)
            .{ .action = .retry }
        else
            .{ .action = .{ .fail = err } },
    };
}

fn isRetryableConnectionSetupError(err: anyerror) bool {
    return err == error.TlsInitializationFailed or isRetryableGatewayError(err);
}

const ConnectionSetupTiming = struct {
    timeout_ms: i64 = gateway_connection_setup_timeout_ms,
};

const ResponseHeadTiming = struct {
    timeout_ms: i64 = 30_000,
};

const ConnectionSetupEpoch = struct {
    deadline: std.Io.Clock.Timestamp,

    fn init(timing: ConnectionSetupTiming) ConnectionSetupEpoch {
        const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        return .{
            .deadline = .{
                .clock = .awake,
                .raw = started.raw.addDuration(.fromMilliseconds(timing.timeout_ms)),
            },
        };
    }
};

const RequestOpenOverride = struct {
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        client: *std.http.Client,
        method: std.http.Method,
        uri: std.Uri,
        options: std.http.Client.RequestOptions,
    ) anyerror!std.http.Client.Request,
};

const StreamCoreOptions = struct {
    setup_timing: ConnectionSetupTiming = .{},
    response_head_timing: ResponseHeadTiming = .{},
    request_open_override: ?RequestOpenOverride = null,
};

const ConnectedRequestWatch = struct {
    const Phase = enum(u8) {
        sending,
        awaiting_head,
        streaming,
        completed,
        timed_out,
        cancelled,
        system_resumed,
    };

    phase: std.atomic.Value(Phase) = .init(.sending),
    response_head_deadline: std.Io.Clock.Timestamp = undefined,
    timing: ResponseHeadTiming,

    fn init(timing: ResponseHeadTiming) ConnectedRequestWatch {
        return .{ .timing = timing };
    }

    fn arm_response_head(self: *ConnectedRequestWatch) ?anyerror {
        self.response_head_deadline = std.Io.Clock.Timestamp.fromNow(
            io_mod.getIo(),
            .{
                .clock = .awake,
                .raw = .fromMilliseconds(self.timing.timeout_ms),
            },
        );
        if (self.phase.cmpxchgStrong(
            .sending,
            .awaiting_head,
            .seq_cst,
            .seq_cst,
        )) |winner| return phase_error(winner);
        return null;
    }

    fn commit_response_head(self: *ConnectedRequestWatch) ?anyerror {
        if (self.phase.cmpxchgStrong(
            .awaiting_head,
            .streaming,
            .seq_cst,
            .seq_cst,
        )) |winner| return phase_error(winner);
        return null;
    }

    fn finish(self: *ConnectedRequestWatch) ?anyerror {
        var current = self.phase.load(.seq_cst);
        while (is_active(current)) {
            if (self.phase.cmpxchgWeak(
                current,
                .completed,
                .seq_cst,
                .seq_cst,
            )) |observed| {
                current = observed;
                continue;
            }
            return null;
        }
        return phase_error(current);
    }

    fn finish_error(
        self: *ConnectedRequestWatch,
        transport_error: anyerror,
    ) anyerror {
        return self.finish() orelse transport_error;
    }

    fn win(self: *ConnectedRequestWatch, winner: Phase) bool {
        std.debug.assert(!is_active(winner));
        std.debug.assert(winner != .completed);
        var current = self.phase.load(.seq_cst);
        while (is_active(current)) {
            if (self.phase.cmpxchgWeak(
                current,
                winner,
                .seq_cst,
                .seq_cst,
            )) |observed| {
                current = observed;
                continue;
            }
            return true;
        }
        return false;
    }

    fn win_response_head_timeout(self: *ConnectedRequestWatch) bool {
        return self.phase.cmpxchgStrong(
            .awaiting_head,
            .timed_out,
            .seq_cst,
            .seq_cst,
        ) == null;
    }

    fn response_head_expired(
        self: *const ConnectedRequestWatch,
        now: std.Io.Clock.Timestamp,
    ) bool {
        if (self.phase.load(.seq_cst) != .awaiting_head) return false;
        return !std.Io.Clock.Timestamp.compare(
            now,
            .lt,
            self.response_head_deadline,
        );
    }

    fn is_active(phase: Phase) bool {
        return switch (phase) {
            .sending, .awaiting_head, .streaming => true,
            .completed, .timed_out, .cancelled, .system_resumed => false,
        };
    }

    fn phase_error(phase: Phase) ?anyerror {
        return switch (phase) {
            .timed_out => error.Timeout,
            .cancelled => error.Cancelled,
            .system_resumed => error.SystemResumed,
            .sending, .awaiting_head, .streaming, .completed => null,
        };
    }
};

const RequestOpenOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
    request_open_override: ?RequestOpenOverride,

    fn run(self: *@This()) anyerror!std.http.Client.Request {
        if (self.request_open_override) |request_open| {
            return request_open.run(
                request_open.ctx,
                self.client,
                .POST,
                self.uri,
                self.options,
            );
        }
        return self.client.request(.POST, self.uri, self.options);
    }
};

fn openGatewayRequestBounded(
    client: *std.http.Client,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
    request_open_override: ?RequestOpenOverride,
    epoch: *ConnectionSetupEpoch,
    cancel_flag: *std.atomic.Value(bool),
) anyerror!std.http.Client.Request {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, epoch.deadline)) {
        return error.ConnectionSetupTimedOut;
    }

    const Event = union(enum) {
        request: anyerror!std.http.Client.Request,
        cancelled: anyerror!void,
        deadline: anyerror!void,
    };
    const Cleanup = struct {
        fn drain(select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_request = request_result catch continue;
                    late_request.deinit();
                },
                .cancelled, .deadline => {},
            };
        }
    };

    var operation = RequestOpenOperation{
        .client = client,
        .uri = uri,
        .options = options,
        .request_open_override = request_open_override,
    };
    var select_buffer: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.cancelled, waitForBoundedCancellation, .{cancel_flag}) catch |err| return err;
    select.concurrent(.deadline, waitForBoundedDeadline, .{epoch.deadline}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.request, RequestOpenOperation.run, .{&operation}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    while (true) {
        const event = select.await() catch |err| {
            Cleanup.drain(&select);
            return err;
        };
        switch (event) {
            .request => |request_result| {
                Cleanup.drain(&select);
                if (cancel_flag.load(.seq_cst)) {
                    var cancelled_request = request_result catch return error.Cancelled;
                    cancelled_request.deinit();
                    return error.Cancelled;
                }

                var owned_request = request_result catch |request_err| return request_err;
                const result_now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (!std.Io.Clock.Timestamp.compare(result_now, .lt, epoch.deadline)) {
                    owned_request.deinit();
                    return error.ConnectionSetupTimedOut;
                }
                return owned_request;
            },
            .cancelled => |cancelled_result| {
                cancelled_result catch |err| {
                    Cleanup.drain(&select);
                    return err;
                };
                Cleanup.drain(&select);
                return error.Cancelled;
            },
            .deadline => |deadline_result| {
                deadline_result catch |err| {
                    Cleanup.drain(&select);
                    return err;
                };
                Cleanup.drain(&select);
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                return error.ConnectionSetupTimedOut;
            },
        }
    }
}

fn sleepGatewaySetupRetry(
    delay_ns: u64,
    epoch: *ConnectionSetupEpoch,
    cancel_flag: *std.atomic.Value(bool),
) anyerror!void {
    const retry_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromNanoseconds(@intCast(delay_ns)),
    });

    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, epoch.deadline)) {
            return error.ConnectionSetupTimedOut;
        }
        if (!std.Io.Clock.Timestamp.compare(now, .lt, retry_deadline)) return;

        var sleep_ns: i96 = 10 * std.time.ns_per_ms;
        sleep_ns = @min(sleep_ns, now.raw.durationTo(retry_deadline.raw).toNanoseconds());
        sleep_ns = @min(sleep_ns, now.raw.durationTo(epoch.deadline.raw).toNanoseconds());
        if (sleep_ns <= 0) continue;
        try io_mod.getIo().sleep(.fromNanoseconds(sleep_ns), .awake);
    }
}

fn testAwakeTimestamp(milliseconds: i64) std.Io.Clock.Timestamp {
    return .{
        .clock = .awake,
        .raw = .fromNanoseconds(@as(i96, milliseconds) * std.time.ns_per_ms),
    };
}

pub const StreamRequest = struct {
    api_key: []const u8,
    model: []const u8,
    retry_count: usize,
    chat_url: []const u8,
    payload: []const u8,
    team: ?[]const u8 = null,
    /// Borrowed until `streamGatewayCompletion` returns.
    session_id: ?[]const u8 = null,
    trace_ctx: debug_trace.TraceContext = .{},
    content_capture_limit: ?usize = null,
    delivery: ?*DeliveryCertainty = null,
    admission: ?agent_stream_provider.Admission = null,
    on_reasoning_chunk: ?StreamCallback = null,
    on_tool_input_chunk: ?StreamCallback = null,
    provider_attempt_owner: ProviderAttemptOwner = .transport,
};

pub fn streamGatewayCompletion(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const expected_provider_tool_name = try expectedProviderToolName(alloc, request.payload);
    return streamGatewayCompletionCore(
        alloc,
        request,
        callback_ctx,
        on_content_chunk,
        on_tool_start,
        cancel_flag,
        expected_provider_tool_name,
        true,
    );
}

fn expectedProviderToolName(alloc: std.mem.Allocator, payload: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tools = parsed.value.object.get("tools") orelse return null;
    if (tools != .array) return null;

    for (tools.array.items) |tool| {
        if (tool != .object) continue;
        const tool_type = tool.object.get("type") orelse continue;
        const id = tool.object.get("id") orelse continue;
        const name = tool.object.get("name") orelse continue;
        if (tool_type != .string or id != .string or name != .string) continue;
        if (std.mem.eql(u8, tool_type.string, "provider") and
            std.mem.eql(u8, id.string, "gateway.perplexity_search") and
            std.mem.eql(u8, name.string, "perplexity_search"))
        {
            return "perplexity_search";
        }
        if (std.mem.eql(u8, tool_type.string, "provider") and
            std.mem.eql(u8, id.string, "gateway.parallel_search") and
            std.mem.eql(u8, name.string, "parallel_search"))
        {
            return "parallel_search";
        }
    }
    return null;
}

pub fn streamGatewayRequiredToolCompletionBounded(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    return runBoundedCompletion(alloc, request, null, deadline, cancel_flag);
}

/// Use only when the request advertises the named tool as provider-executed.
pub fn streamGatewayProviderToolCompletionBounded(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    expected_provider_tool_name: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    return runBoundedCompletion(alloc, request, expected_provider_tool_name, deadline, cancel_flag);
}

fn runBoundedCompletion(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    expected_provider_tool_name: ?[]const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !StreamResult {
    var operation = BoundedGatewayOperation{
        .alloc = alloc,
        .request = request,
        .expected_provider_tool_name = expected_provider_tool_name,
        .cancel_flag = cancel_flag,
    };
    return runBoundedStreamOperation(alloc, cancel_flag, deadline, &operation);
}

const BoundedGatewayOperation = struct {
    alloc: std.mem.Allocator,
    request: StreamRequest,
    expected_provider_tool_name: ?[]const u8,
    cancel_flag: *std.atomic.Value(bool),

    fn run(self: *@This()) !StreamResult {
        return streamGatewayCompletionCore(
            self.alloc,
            self.request,
            @ptrCast(&bounded_stream_discard_ctx),
            discardBoundedContent,
            null,
            self.cancel_flag,
            self.expected_provider_tool_name,
            false,
        );
    }
};

var bounded_stream_discard_ctx: u8 = 0;

fn discardBoundedContent(_: *anyopaque, _: []const u8) void {}

fn streamGatewayCompletionCore(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
    expected_provider_tool_name: ?[]const u8,
    watch_connected_socket: bool,
) !StreamResult {
    return streamGatewayCompletionCoreWithOptions(
        alloc,
        request,
        callback_ctx,
        on_content_chunk,
        on_tool_start,
        cancel_flag,
        expected_provider_tool_name,
        watch_connected_socket,
        .{},
    );
}

fn streamGatewayCompletionCoreWithOptions(
    alloc: std.mem.Allocator,
    request: StreamRequest,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    cancel_flag: *std.atomic.Value(bool),
    expected_provider_tool_name: ?[]const u8,
    watch_connected_socket: bool,
    core_options: StreamCoreOptions,
) !StreamResult {
    const model = request.model;
    const payload = request.payload;
    const retry_count = switch (request.provider_attempt_owner) {
        .agent => 1,
        .transport => request.retry_count,
    };
    const trace_ctx = request.trace_ctx;
    const request_url = try resolveE2eGatewayUrl(e2e_gateway_chat_url_env, request.chat_url);
    const uri = try std.Uri.parse(request_url);

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer alloc.free(auth_header);

    var extra_headers_buf: [9]std.http.Header = undefined;
    const extra_headers = gatewayExtraHeaders(
        &extra_headers_buf,
        model,
        request.team,
        request.session_id,
    );

    if (request.admission) |admission| try admission.admit();
    var attempt: usize = 0;
    var delivery_ambiguous = false;
    var request_body_possibly_sent = false;
    var setup_epoch: ?ConnectionSetupEpoch = null;
    while (attempt < retry_count) : (attempt += 1) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        if (setup_epoch == null) {
            setup_epoch = ConnectionSetupEpoch.init(core_options.setup_timing);
        }
        const epoch = &setup_epoch.?;
        const setup_delivery: DeliveryCertainty.State = if (request_body_possibly_sent)
            .possibly_sent
        else if (request.delivery) |delivery|
            delivery.load()
        else
            .definitely_unsent;

        debug_trace.eventf("gateway", "before_http_open_connect", trace_ctx, "attempt={d} attempt_limit={d} retries_used={d}", .{ attempt + 1, retry_count, attempt });
        debug_trace.eventf("gateway", "before_request_open", trace_ctx, "attempt={d} attempt_limit={d} retries_used={d} payload_bytes={d}", .{ attempt + 1, retry_count, attempt, payload.len });
        var req = openGatewayRequestBounded(&client, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = user_agent },
            },
            .extra_headers = extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }, core_options.request_open_override, epoch, cancel_flag) catch |err| {
            debug_trace.eventf("gateway", "http_open_connect_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            const decision = decideConnectionSetup(.{
                .attempt = attempt + 1,
                .attempt_limit = retry_count,
                .now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
                .deadline = epoch.deadline,
                .cancelled = cancel_flag.load(.seq_cst),
                .delivery = setup_delivery,
                .outcome = .{ .request_failed = err },
            });
            switch (decision.action) {
                .retry => {
                    sleepGatewaySetupRetry(
                        (attempt + 1) * gateway_retry_base_delay_ns,
                        epoch,
                        cancel_flag,
                    ) catch |sleep_err| return @as(anyerror!StreamResult, sleep_err);
                    continue;
                },
                .fail => |terminal_err| return @as(anyerror!StreamResult, terminal_err),
                .cancelled => return error.Cancelled,
                .succeed => unreachable,
            }
        };
        const setup_success = decideConnectionSetup(.{
            .attempt = attempt + 1,
            .attempt_limit = retry_count,
            .now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
            .deadline = epoch.deadline,
            .cancelled = cancel_flag.load(.seq_cst),
            .delivery = setup_delivery,
            .outcome = .request_succeeded,
        });
        switch (setup_success.action) {
            .succeed => {},
            .fail => |terminal_err| {
                req.deinit();
                return @as(anyerror!StreamResult, terminal_err);
            },
            .cancelled => {
                req.deinit();
                return error.Cancelled;
            },
            .retry => unreachable,
        }
        setup_epoch = null;
        defer req.deinit();
        debug_trace.eventf("gateway", "after_http_open_connect", trace_ctx, "attempt={d}", .{attempt + 1});
        debug_trace.eventf("gateway", "after_request_open", trace_ctx, "attempt={d}", .{attempt + 1});

        var cancel_watch_done = std.atomic.Value(bool).init(false);
        var system_resumed = std.atomic.Value(bool).init(false);
        var connected_watch = ConnectedRequestWatch.init(core_options.response_head_timing);
        const cancel_watcher = if (watch_connected_socket)
            if (req.connection) |conn|
                spawn_gateway_cancel_watcher(&cancel_watch_done, cancel_flag, &system_resumed, null, &connected_watch, conn.stream_writer.stream) catch |err| {
                    debug_trace.eventf("gateway", "cancel_watcher_spawn_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
                    return @as(anyerror!StreamResult, err);
                }
            else
                null
        else
            null;
        const active_connected_watch: ?*ConnectedRequestWatch = if (cancel_watcher != null)
            &connected_watch
        else
            null;
        defer {
            cancel_watch_done.store(true, .seq_cst);
            if (cancel_watcher) |thread| thread.join();
        }
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;

        req.transfer_encoding = .{ .content_length = payload.len };
        var send_buf: [8192]u8 = undefined;
        debug_trace.eventf("gateway", "before_request_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });
        request_body_possibly_sent = true;
        if (request.delivery) |delivery| delivery.markPossiblySent();
        var body_writer = req.sendBodyUnflushed(&send_buf) catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        body_writer.writer.writeAll(payload) catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        body_writer.end() catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        req.connection.?.flush() catch |err| {
            debug_trace.eventf("gateway", "request_send_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        debug_trace.eventf("gateway", "after_request_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });
        debug_trace.eventf("gateway", "after_send", trace_ctx, "attempt={d} payload_bytes={d}", .{ attempt + 1, payload.len });

        if (active_connected_watch) |watch| {
            if (watch.arm_response_head()) |err| return @as(anyerror!StreamResult, err);
        }
        debug_trace.eventf("gateway", "before_receive_head", trace_ctx, "attempt={d}", .{attempt + 1});
        var response = req.receiveHead(&.{}) catch |err| {
            debug_trace.eventf("gateway", "receive_head_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            const mapped = connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            );
            if (mapped == error.Cancelled or mapped == error.SystemResumed) {
                return @as(anyerror!StreamResult, mapped);
            }
            if (request.provider_attempt_owner == .transport and
                isRetryableGatewayError(mapped) and attempt + 1 < retry_count)
            {
                delivery_ambiguous = true;
                try sleepGatewayRetry((attempt + 1) * 150 * std.time.ns_per_ms, cancel_flag);
                continue;
            }
            return @as(anyerror!StreamResult, mapped);
        };
        if (active_connected_watch) |watch| {
            if (watch.commit_response_head()) |err| return @as(anyerror!StreamResult, err);
        }
        debug_trace.eventf("gateway", "after_receive_head", trace_ctx, "attempt={d} status={d}", .{ attempt + 1, @intFromEnum(response.head.status) });
        const resolved_model_seen_in_head = traceResolvedModelHeader(response.head, model, trace_ctx);

        if (response.head.status != .ok) {
            const status = response.head.status;
            if (@intFromEnum(status) >= 500) delivery_ambiguous = true;
            const retry_after_seconds = retryAfterSeconds(response.head);
            const retry_delay_ns = if (request.provider_attempt_owner == .transport and
                isRetryableGatewayStatus(status) and attempt + 1 < retry_count)
                retryDelayNsForResponse(response.head, attempt)
            else
                null;
            debug_trace.logf("stream", "http status={d} attempt={d}", .{ @intFromEnum(status), attempt + 1 });
            var err_out: std.Io.Writer.Allocating = .init(alloc);
            defer err_out.deinit();
            var err_buf: [4096]u8 = undefined;
            const err_reader = response.reader(&err_buf);
            _ = err_reader.streamRemaining(&err_out.writer) catch {};
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            if (retry_delay_ns) |delay_ns| {
                debug_trace.eventf("gateway", "http_status_retry", trace_ctx, "attempt={d} status={d} delay_ms={d}", .{
                    attempt + 1,
                    @intFromEnum(status),
                    delay_ns / std.time.ns_per_ms,
                });
                try sleepGatewayRetry(delay_ns, cancel_flag);
                continue;
            }
            return .{
                .status = status,
                .err_body = err_out.toOwnedSlice() catch null,
                .retry_after_seconds = retry_after_seconds,
                .completion = .{
                    .delivery_ambiguous = delivery_ambiguous,
                },
            };
        }

        var transfer_buf: [gateway_transfer_buffer_bytes]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        debug_trace.eventf("gateway", "before_sse_consume", trace_ctx, "attempt={d}", .{attempt + 1});
        var completion = consumeSseStreamTraced(
            alloc,
            body_reader,
            callback_ctx,
            on_content_chunk,
            on_tool_start,
            request.on_reasoning_chunk,
            request.on_tool_input_chunk,
            cancel_flag,
            .{ .requested_model = model, .ctx = trace_ctx },
            expected_provider_tool_name,
            request.content_capture_limit,
        ) catch |err| {
            debug_trace.eventf("gateway", "sse_consume_error", trace_ctx, "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
            return @as(anyerror!StreamResult, connectedIoFailureWithWatch(
                active_connected_watch,
                cancel_flag.load(.seq_cst),
                system_resumed.load(.seq_cst),
                err,
            ));
        };
        if (active_connected_watch) |watch| {
            if (watch.finish()) |err| {
                deinitGatewayCompletion(alloc, &completion);
                return @as(anyerror!StreamResult, err);
            }
        }
        if (cancel_flag.load(.seq_cst)) {
            deinitGatewayCompletion(alloc, &completion);
            return error.Cancelled;
        }
        if (system_resumed.load(.seq_cst)) {
            deinitGatewayCompletion(alloc, &completion);
            return error.SystemResumed;
        }
        completion.delivery_ambiguous = delivery_ambiguous;
        if (!resolved_model_seen_in_head) traceResolvedModelMissingOnce(model, trace_ctx);
        debug_trace.eventf("gateway", "after_sse_consume", trace_ctx, "attempt={d} finish_reason={s} content_bytes={d} tool_call_count={d}", .{
            attempt + 1,
            finish_reason_label(completion.finish_reason),
            if (completion.content) |content| content.len else 0,
            completion.tool_calls.len,
        });
        debug_trace.logf(
            "stream",
            "completed attempt={d} finish_reason={s} content_bytes={d} tool_calls={d}",
            .{
                attempt + 1,
                finish_reason_label(completion.finish_reason),
                if (completion.content) |content| content.len else 0,
                completion.tool_calls.len,
            },
        );
        debug_trace.eventf(
            "gateway",
            "stream_complete",
            trace_ctx,
            "attempt={d} finish_reason={s} content_bytes={d} tool_call_count={d} tool_calls={d}",
            .{
                attempt + 1,
                finish_reason_label(completion.finish_reason),
                if (completion.content) |content| content.len else 0,
                completion.tool_calls.len,
                completion.tool_calls.len,
            },
        );

        return .{
            .status = .ok,
            .completion = completion,
        };
    }

    return error.HttpConnectionClosing;
}

fn gatewayExtraHeaders(
    buf: []std.http.Header,
    model: []const u8,
    team: ?[]const u8,
    session_id: ?[]const u8,
) []const std.http.Header {
    std.debug.assert(buf.len >= 9);
    var len: usize = 0;
    buf[len] = .{ .name = "HTTP-Referer", .value = "https://github.com/vercel-labs/fx" };
    len += 1;
    buf[len] = .{ .name = "X-Title", .value = "fx" };
    len += 1;
    buf[len] = .{ .name = "ai-gateway-protocol-version", .value = "0.0.1" };
    len += 1;
    buf[len] = .{ .name = "ai-language-model-specification-version", .value = "4" };
    len += 1;
    buf[len] = .{ .name = "ai-language-model-id", .value = model };
    len += 1;
    buf[len] = .{ .name = "ai-language-model-streaming", .value = "true" };
    len += 1;
    if (team) |gateway_team| {
        if (gateway_team.len > 0) {
            buf[len] = .{ .name = vercel_ai_gateway_team_header, .value = gateway_team };
            len += 1;
        }
    }
    if (session_id) |id| {
        if (id.len > 0) {
            buf[len] = .{ .name = "x-session-id", .value = id };
            len += 1;
            buf[len] = .{ .name = "x-session-affinity", .value = id };
            len += 1;
        }
    }
    return buf[0..len];
}

fn gatewayModelCatalogExtraHeaders(buf: []std.http.Header, team: ?[]const u8) []const std.http.Header {
    std.debug.assert(buf.len >= 1);
    var len: usize = 0;
    if (team) |gateway_team| {
        if (gateway_team.len > 0) {
            buf[len] = .{ .name = vercel_ai_gateway_team_header, .value = gateway_team };
            len += 1;
        }
    }
    return buf[0..len];
}

fn headerValue(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn sleepGatewayRetry(delay_ns: u64, cancel_flag: *std.atomic.Value(bool)) (std.Io.Cancelable || error{Cancelled})!void {
    var remaining_ns = delay_ns;
    while (remaining_ns > 0) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const sleep_ns = @min(remaining_ns, 10 * std.time.ns_per_ms);
        try io_mod.getIo().sleep(.fromNanoseconds(@intCast(sleep_ns)), .awake);
        remaining_ns -= sleep_ns;
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
}

fn runBoundedStreamOperation(
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: anytype,
) !StreamResult {
    return runBoundedHttpOperation(
        StreamResult,
        alloc,
        cancel_flag,
        deadline,
        operation,
    );
}

pub fn runBoundedHttpOperation(
    comptime Result: type,
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    operation: anytype,
) !Result {
    if (cancel_flag.load(.seq_cst)) {
        debug_trace.logf("stream", "bounded termination cause=cancellation phase=admission", .{});
        return error.Cancelled;
    }
    std.debug.assert(deadline.clock == .awake);

    const zio = io_mod.getIo();
    const now = std.Io.Clock.Timestamp.now(zio, .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
        debug_trace.logf("stream", "bounded termination cause=deadline phase=admission", .{});
        return error.Timeout;
    }

    const Event = union(enum) {
        request: anyerror!Result,
        cancelled: anyerror!void,
        deadline: anyerror!void,
    };
    const Operation = @TypeOf(operation);
    const Runner = struct {
        fn run(value: Operation) anyerror!Result {
            return value.run();
        }
    };
    const Cleanup = struct {
        fn drain(result_alloc: std.mem.Allocator, select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .request => |request_result| {
                    var late_result = request_result catch continue;
                    late_result.deinit(result_alloc);
                },
                .cancelled, .deadline => {},
            };
        }
    };

    var select_buffer: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(zio, &select_buffer);
    select.concurrent(.cancelled, waitForBoundedCancellation, .{cancel_flag}) catch |err| {
        return err;
    };
    select.concurrent(.deadline, waitForBoundedDeadline, .{deadline}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.request, Runner.run, .{operation}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    switch (event) {
        .request => |request_result| {
            Cleanup.drain(alloc, &select);
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=request_result", .{});
                var owned_result = request_result catch return error.Cancelled;
                owned_result.deinit(alloc);
                return error.Cancelled;
            }
            return request_result;
        },
        .cancelled => |cancel_result| {
            cancel_result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            debug_trace.logf("stream", "bounded termination cause=cancellation phase=control", .{});
            return error.Cancelled;
        },
        .deadline => |deadline_result| {
            deadline_result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            if (cancel_flag.load(.seq_cst)) {
                debug_trace.logf("stream", "bounded termination cause=cancellation phase=deadline_cleanup", .{});
                return error.Cancelled;
            }
            debug_trace.logf("stream", "bounded termination cause=deadline phase=control", .{});
            return error.Timeout;
        },
    }
}

fn waitForBoundedCancellation(cancel_flag: *std.atomic.Value(bool)) anyerror!void {
    while (!cancel_flag.load(.seq_cst)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForBoundedDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

const GatewayCancelWatcher = struct {
    fn run(
        done: *std.atomic.Value(bool),
        cancel_flag: *std.atomic.Value(bool),
        system_resumed: ?*std.atomic.Value(bool),
        deadline: ?std.Io.Clock.Timestamp,
        connected_watch: ?*ConnectedRequestWatch,
        stream: std.Io.net.Stream,
    ) void {
        var previous = SuspendClockSample.now();
        while (!done.load(.seq_cst)) {
            if (cancel_flag.load(.seq_cst)) {
                if (connected_watch == null or connected_watch.?.win(.cancelled)) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                }
                return;
            }
            const current = SuspendClockSample.now();
            if (system_resumed != null and suspendGapDetected(previous, current)) {
                if (cancel_flag.load(.seq_cst)) {
                    if (connected_watch == null or connected_watch.?.win(.cancelled)) {
                        stream.shutdown(io_mod.getIo(), .both) catch {};
                    }
                    return;
                }
                if (connected_watch == null or connected_watch.?.win(.system_resumed)) {
                    system_resumed.?.store(true, .seq_cst);
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                }
                return;
            }
            if (deadline) |limit| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (!std.Io.Clock.Timestamp.compare(now, .lt, limit)) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
            }
            if (connected_watch) |watch| {
                const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
                if (watch.response_head_expired(now) and watch.win_response_head_timeout()) {
                    stream.shutdown(io_mod.getIo(), .both) catch {};
                    return;
                }
                if (watch.phase.load(.seq_cst) == .completed) return;
            }
            previous = current;
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }
};

const suspend_gap_tolerance_ns: i128 = 100 * std.time.ns_per_ms;

const SuspendClockSample = struct {
    awake_ns: i128,
    boot_ns: i128,

    fn now() SuspendClockSample {
        const io = io_mod.getIo();
        return .{
            .awake_ns = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds()),
            .boot_ns = @intCast(std.Io.Clock.Timestamp.now(io, .boot).raw.toNanoseconds()),
        };
    }
};

fn suspendGapDetected(previous: SuspendClockSample, current: SuspendClockSample) bool {
    const awake_elapsed = current.awake_ns - previous.awake_ns;
    const boot_elapsed = current.boot_ns - previous.boot_ns;
    if (awake_elapsed < 0 or boot_elapsed < 0) return false;
    return boot_elapsed - awake_elapsed > suspend_gap_tolerance_ns;
}

pub fn spawnHttpCancelWatcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    stream: std.Io.net.Stream,
) !std.Thread {
    return spawn_gateway_cancel_watcher(done, cancel_flag, null, null, null, stream);
}

pub fn spawnHttpCancelWatcherBounded(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    stream: std.Io.net.Stream,
) !std.Thread {
    return spawn_gateway_cancel_watcher(done, cancel_flag, null, deadline, null, stream);
}

fn spawn_gateway_cancel_watcher(
    done: *std.atomic.Value(bool),
    cancel_flag: *std.atomic.Value(bool),
    system_resumed: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    connected_watch: ?*ConnectedRequestWatch,
    stream: std.Io.net.Stream,
) !std.Thread {
    if (builtin.is_test) {
        if (test_cancel_watcher_spawn_error) |err| return err;
    }
    return std.Thread.spawn(.{}, GatewayCancelWatcher.run, .{
        done,
        cancel_flag,
        system_resumed,
        deadline,
        connected_watch,
        stream,
    });
}

fn resolveE2eGatewayUrl(env_name: []const u8, default_url: []const u8) ![]const u8 {
    return selectE2eGatewayUrl(io_mod.getenv(env_name), default_url);
}

fn selectE2eGatewayUrl(override_url: ?[]const u8, default_url: []const u8) ![]const u8 {
    const override = override_url orelse return default_url;
    if (!isLoopbackHttpUrl(override)) return error.InvalidE2EGatewayUrl;
    return override;
}

pub fn isLoopbackHttpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null)
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

const HeaderMatch = struct {
    name: []const u8,
    value: []const u8,
};

fn isRetryableGatewayStatus(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests,
        .internal_server_error,
        .bad_gateway,
        .service_unavailable,
        .gateway_timeout,
        => true,
        else => false,
    };
}

fn retryDelayNsForResponse(head: std.http.Client.Response.Head, attempt: usize) u64 {
    if (retryAfterDelayNs(head)) |delay_ns| return delay_ns;
    return retryBackoffDelayNs(attempt);
}

fn retryBackoffDelayNs(attempt: usize) u64 {
    const multiplier: u64 = @intCast(attempt + 1);
    return multiplier * gateway_retry_base_delay_ns;
}

fn retryAfterDelayNs(head: std.http.Client.Response.Head) ?u64 {
    const seconds = retryAfterSeconds(head) orelse return null;
    const delay = std.math.mul(u64, seconds, std.time.ns_per_s) catch gateway_retry_after_max_ns;
    return @min(delay, gateway_retry_after_max_ns);
}

fn retryAfterSeconds(head: std.http.Client.Response.Head) ?u64 {
    const raw = findHeaderValue(head, "retry-after") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch |err| switch (err) {
        error.Overflow => std.math.maxInt(u64),
        error.InvalidCharacter => null,
    };
}

fn findHeaderValue(head: std.http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn traceResolvedModelHeader(head: std.http.Client.Response.Head, requested_model: []const u8, trace_ctx: debug_trace.TraceContext) bool {
    if (findResolvedModelHeader(head)) |header| {
        traceResolvedModelOnce(requested_model, header.name, header.value, trace_ctx);
        return true;
    }
    return false;
}

fn traceResolvedModelOnce(requested_model: []const u8, source: []const u8, resolved_model: []const u8, trace_ctx: debug_trace.TraceContext) void {
    if (resolved_model_trace_emitted.swap(true, .acq_rel)) return;

    debug_trace.eventf(
        "gateway",
        "resolved_model",
        trace_ctx,
        "requested_model={s} source={s} resolved_model={s}",
        .{ requested_model, source, resolved_model },
    );
}

fn traceResolvedModelMissingOnce(requested_model: []const u8, trace_ctx: debug_trace.TraceContext) void {
    if (resolved_model_trace_emitted.swap(true, .acq_rel)) return;

    debug_trace.eventf(
        "gateway",
        "resolved_model_missing",
        trace_ctx,
        "requested_model={s}",
        .{requested_model},
    );
}

fn findResolvedModelHeader(head: std.http.Client.Response.Head) ?HeaderMatch {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (isResolvedModelHeaderName(header.name)) {
            return .{
                .name = header.name,
                .value = std.mem.trim(u8, header.value, " \t\r\n"),
            };
        }
    }
    return null;
}

fn isResolvedModelHeaderName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "x-vercel-ai-gateway-model") or
        std.ascii.eqlIgnoreCase(name, "x-vercel-ai-gateway-model-id") or
        std.ascii.eqlIgnoreCase(name, "x-ai-gateway-model") or
        std.ascii.eqlIgnoreCase(name, "ai-gateway-model") or
        std.ascii.eqlIgnoreCase(name, "ai-language-model-id");
}

const StreamedToolInputState = enum {
    open,
    ended,
    finalized,
};

const SseStreamedToolInput = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),
    state: StreamedToolInputState = .open,
    label_sent: bool = false,

    fn deinit(self: *SseStreamedToolInput, alloc: std.mem.Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const ProviderResultState = enum {
    none,
    preliminary,
    final,
};

const SseToolCallAccumulator = struct {
    id: std.ArrayList(u8),
    name: std.ArrayList(u8),
    arguments: std.ArrayList(u8),
    provisional_id: std.ArrayList(u8) = .empty,
    argument_integrity: types.ToolArgumentIntegrity = .valid,
    provider_result: ?[]u8 = null,
    provider_result_state: ProviderResultState = .none,
    final_identity: types.FinalToolIdentity = .valid,
    provenance: types.ToolExecutionProvenance = .fx_local,

    fn deinit(self: *SseToolCallAccumulator, alloc: std.mem.Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.provisional_id.deinit(alloc);
        if (self.provider_result) |result| alloc.free(result);
        self.* = undefined;
    }
};

const ResolvedModelTrace = struct {
    requested_model: []const u8,
    ctx: debug_trace.TraceContext,
};

const StreamStateAnomaly = enum {
    invalid_start,
    conflicting_start,
    late_start,
    unmatched_or_late_delta,
    unmatched_or_duplicate_end,
};

var test_force_sse_preview_failure = false;

fn traceStreamStateAnomaly(reason: StreamStateAnomaly) void {
    debug_trace.logf("sse", "event=stream_state_anomaly reason={s}", .{@tagName(reason)});
}

fn canonicalSseEventType(event_type: []const u8) []const u8 {
    inline for (.{
        "response-metadata",
        "text-start",
        "text-delta",
        "text-end",
        "reasoning-start",
        "reasoning-delta",
        "reasoning-end",
        "tool-input-start",
        "tool-input-delta",
        "tool-input-end",
        "tool-call",
        "tool-result",
        "source",
        "file",
        "raw",
        "error",
        "start",
        "start-step",
        "finish-step",
        "finish",
    }) |known| {
        if (std.mem.eql(u8, event_type, known)) return known;
    }
    return "unknown";
}

fn traceParsedSseEvent(alloc: std.mem.Allocator, root: std.json.Value, json_bytes: usize) void {
    if (!debug_trace.isScopeEnabled("sse")) return;

    const event_type = if (root == .object)
        if (root.object.get("type")) |type_value|
            if (type_value == .string)
                canonicalSseEventType(type_value.string)
            else
                "invalid"
        else
            "invalid"
    else
        "invalid";

    if (builtin.is_test and test_force_sse_preview_failure) {
        debug_trace.logf("sse", "event type={s} bytes={d} preview=<preview-error>", .{
            event_type,
            json_bytes,
        });
        return;
    }

    const preview_text = debug_trace.keylessJsonValuePreview(alloc, root) catch {
        debug_trace.logf("sse", "event type={s} bytes={d} preview=<preview-error>", .{
            event_type,
            json_bytes,
        });
        return;
    };
    defer alloc.free(preview_text);
    debug_trace.logf("sse", "event type={s} bytes={d} preview={s}", .{
        event_type,
        json_bytes,
        preview_text,
    });
}

fn traceMalformedSseEvent(json_bytes: usize) void {
    debug_trace.logf("sse", "event type=invalid bytes={d} preview=<invalid-json>", .{json_bytes});
}

fn setProviderResultFailure(
    failure: *?types.ProviderResultIdentityFailure,
    value: types.ProviderResultIdentityFailure,
) void {
    if (failure.* == null) failure.* = value;
}

fn findStreamedToolInput(records: []const SseStreamedToolInput, id: []const u8) ?usize {
    for (records, 0..) |record, i| {
        if (std.mem.eql(u8, record.id.items, id)) return i;
    }
    return null;
}

fn jsonValuesEqual(lhs: std.json.Value, rhs: std.json.Value) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .null => true,
        .bool => |value| value == rhs.bool,
        .integer => |value| value == rhs.integer,
        .float => |value| value == rhs.float,
        .number_string => |value| std.mem.eql(u8, value, rhs.number_string),
        .string => |value| std.mem.eql(u8, value, rhs.string),
        .array => |values| blk: {
            if (values.items.len != rhs.array.items.len) break :blk false;
            for (values.items, rhs.array.items) |left, right| {
                if (!jsonValuesEqual(left, right)) break :blk false;
            }
            break :blk true;
        },
        .object => |fields| blk: {
            if (fields.count() != rhs.object.count()) break :blk false;
            var iterator = fields.iterator();
            while (iterator.next()) |field| {
                const right = rhs.object.get(field.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(field.value_ptr.*, right)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn serializedJsonEqual(
    alloc: std.mem.Allocator,
    lhs: []const u8,
    rhs: []const u8,
) std.mem.Allocator.Error!bool {
    if (std.mem.eql(u8, lhs, rhs)) return true;

    var left = std.json.parseFromSlice(std.json.Value, alloc, lhs, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer left.deinit();
    var right = std.json.parseFromSlice(std.json.Value, alloc, rhs, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer right.deinit();
    return jsonValuesEqual(left.value, right.value);
}

fn findEquivalentEndedStreamedToolInput(
    alloc: std.mem.Allocator,
    records: []const SseStreamedToolInput,
    final_name: []const u8,
    final_arguments: []const u8,
) std.mem.Allocator.Error!?usize {
    if (final_name.len == 0) return null;

    for (records, 0..) |record, i| {
        if (record.state != .ended) continue;
        if (!std.mem.eql(u8, record.name.items, final_name)) continue;
        if (try serializedJsonEqual(alloc, record.arguments.items, final_arguments)) return i;
    }
    return null;
}

fn initStreamedToolInput(
    alloc: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
) !SseStreamedToolInput {
    var record: SseStreamedToolInput = .{
        .id = .empty,
        .name = .empty,
        .arguments = .empty,
    };
    errdefer record.deinit(alloc);
    try record.id.appendSlice(alloc, id);
    try record.name.appendSlice(alloc, name);
    return record;
}

fn streamedToolInputId(
    root: std.json.Value,
    anomaly: StreamStateAnomaly,
) ?[]const u8 {
    const id_value = root.object.get("id") orelse {
        traceStreamStateAnomaly(anomaly);
        return null;
    };
    if (id_value != .string or id_value.string.len == 0) {
        traceStreamStateAnomaly(anomaly);
        return null;
    }
    return id_value.string;
}

const ToolArgumentSource = enum {
    final_string,
    streamed_fallback,
};

const FinalToolInputState = enum {
    absent,
    valid,
    malformed,
};

fn appendSerializedToolArguments(
    alloc: std.mem.Allocator,
    destination: *std.ArrayList(u8),
    serialized: []const u8,
    call_id: []const u8,
    tool_name: []const u8,
    source: ToolArgumentSource,
) !types.ToolArgumentIntegrity {
    const integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, serialized);
    if (integrity == .valid) {
        try destination.appendSlice(alloc, serialized);
        return .valid;
    }

    try destination.appendSlice(alloc, "{}");
    debug_trace.logf(
        "sse",
        "event=tool_argument_integrity call_id={s} tool_name={s} source={s} bytes={d} failure=malformed_json",
        .{ call_id, tool_name, @tagName(source), serialized.len },
    );
    return .malformed_json;
}

fn appendSupportedFinalInput(
    alloc: std.mem.Allocator,
    destination: *std.ArrayList(u8),
    input: std.json.Value,
    call_id: []const u8,
    tool_name: []const u8,
) !types.ToolArgumentIntegrity {
    switch (input) {
        .string => |value| {
            return try appendSerializedToolArguments(
                alloc,
                destination,
                value,
                call_id,
                tool_name,
                .final_string,
            );
        },
        .object, .array => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            std.json.Stringify.value(input, .{}, &out.writer) catch return error.OutOfMemory;
            try destination.appendSlice(alloc, out.written());
            return .valid;
        },
        else => {
            try destination.appendSlice(alloc, "{}");
            debug_trace.logf(
                "sse",
                "event=tool_argument_integrity call_id={s} tool_name={s} source=final_value input_kind={s} failure=malformed_json",
                .{ call_id, tool_name, @tagName(input) },
            );
            return .malformed_json;
        },
    }
}

fn stringifyJsonValueOwned(alloc: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn deinitGatewayCompletion(alloc: std.mem.Allocator, completion: *types.ModelCompletion) void {
    if (completion.content) |content| alloc.free(content);
    if (completion.generation_id) |id| alloc.free(id);
    if (completion.billing) |billing| alloc.free(@constCast(billing.model));
    for (completion.tool_calls) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
        if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
        if (call.provider_result) |provider_result| alloc.free(provider_result);
    }
    if (completion.tool_calls.len > 0) alloc.free(completion.tool_calls);
    if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
    completion.* = .{};
}

fn clippedDupe(alloc: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    const clipped = trimmed[0..@min(trimmed.len, max_bytes)];
    return try alloc.dupe(u8, clipped);
}

fn replaceProviderFailureDetail(alloc: std.mem.Allocator, current: *?[]u8, text: []const u8) !void {
    if (text.len == 0) return;
    const owned = try clippedDupe(alloc, text, provider_failure_detail_max_bytes);
    if (owned.len == 0) {
        alloc.free(owned);
        return;
    }
    if (current.*) |old| alloc.free(old);
    current.* = owned;
}

fn replaceProviderFailureMessage(
    alloc: std.mem.Allocator,
    current: *?[]u8,
    text: []const u8,
) !void {
    const combined = try std.fmt.allocPrint(alloc, "provider_error: {s}", .{text});
    defer alloc.free(combined);
    try replaceProviderFailureDetail(alloc, current, combined);
}

fn jsonValueString(value: std.json.Value) ?[]const u8 {
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn captureProviderFailureObject(
    alloc: std.mem.Allocator,
    current: *?[]u8,
    object: std.json.ObjectMap,
    include_type: bool,
) !bool {
    const code = if (object.get("code")) |value|
        jsonValueString(value)
    else if (include_type)
        if (object.get("type")) |value| jsonValueString(value) else null
    else
        null;
    const message = if (object.get("message")) |value| jsonValueString(value) else null;
    if (code) |code_text| {
        if (message) |message_text| {
            const combined = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ code_text, message_text });
            defer alloc.free(combined);
            try replaceProviderFailureDetail(alloc, current, combined);
            return true;
        }
    }

    const message_keys = [_][]const u8{ "message", "detail", "details", "reason" };
    for (&message_keys) |key| {
        if (object.get(key)) |value| {
            if (jsonValueString(value)) |text| {
                try replaceProviderFailureMessage(alloc, current, text);
                return true;
            }
        }
    }
    if (code) |code_text| {
        try replaceProviderFailureDetail(alloc, current, code_text);
        return true;
    }
    return false;
}

fn captureProviderFailureDetail(alloc: std.mem.Allocator, current: *?[]u8, root: std.json.Value) !void {
    if (root != .object or current.* != null) return;
    if (try captureProviderFailureObject(alloc, current, root.object, false)) return;
    if (root.object.get("error")) |value| {
        if (jsonValueString(value)) |text| {
            try replaceProviderFailureMessage(alloc, current, text);
            return;
        }
        if (value == .object) {
            if (try captureProviderFailureObject(alloc, current, value.object, true)) return;
            const rendered = try stringifyJsonValueOwned(alloc, value);
            defer alloc.free(rendered);
            try replaceProviderFailureDetail(alloc, current, rendered);
            return;
        }
    }
    if (root.object.get("providerError")) |value| {
        if (jsonValueString(value)) |text| {
            try replaceProviderFailureMessage(alloc, current, text);
            return;
        }
        if (value == .object) {
            if (try captureProviderFailureObject(alloc, current, value.object, true)) return;
        }
        const rendered = try stringifyJsonValueOwned(alloc, value);
        defer alloc.free(rendered);
        try replaceProviderFailureDetail(alloc, current, rendered);
    }
}

fn materializeToolCalls(
    alloc: std.mem.Allocator,
    accumulators: []const SseToolCallAccumulator,
) ![]const types.ToolCall {
    if (accumulators.len == 0) return &.{};

    const calls = try alloc.alloc(types.ToolCall, accumulators.len);
    var initialized: usize = 0;
    errdefer {
        for (calls[0..initialized]) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
            if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
            if (call.provider_result) |provider_result| alloc.free(provider_result);
        }
        alloc.free(calls);
    }

    for (accumulators, 0..) |acc, i| {
        const id = try alloc.dupe(u8, acc.id.items);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, acc.name.items);
        errdefer alloc.free(name);
        const arguments = try alloc.dupe(u8, acc.arguments.items);
        errdefer alloc.free(arguments);
        const provisional_id = if (acc.provisional_id.items.len > 0)
            try alloc.dupe(u8, acc.provisional_id.items)
        else
            null;
        errdefer if (provisional_id) |value| alloc.free(value);
        const provider_result = if (acc.provider_result_state == .final)
            if (acc.provider_result) |result| try alloc.dupe(u8, result) else null
        else
            null;
        errdefer if (provider_result) |result| alloc.free(result);

        calls[i] = .{
            .id = id,
            .name = name,
            .arguments_json = arguments,
            .argument_integrity = acc.argument_integrity,
            .provisional_id = provisional_id,
            .provider_result = provider_result,
            .final_identity = acc.final_identity,
            .provenance = acc.provenance,
        };
        initialized += 1;
    }

    return calls;
}

fn extractFirstJsonStringValue(args: []const u8) ?[]const u8 {
    const colon = std.mem.findScalar(u8, args, ':') orelse return null;
    var i = colon + 1;
    while (i < args.len and args[i] == ' ') : (i += 1) {}
    if (i >= args.len or args[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < args.len) : (i += 1) {
        if (args[i] == '\\') {
            i += 1;
            continue;
        }
        if (args[i] == '"') return args[start..i];
    }
    return null;
}

fn isReasoningSseEvent(event_type: []const u8) bool {
    return std.mem.startsWith(u8, event_type, "reasoning-");
}

fn finish_reason_label(finish_reason: ?types.ProviderFinishReason) []const u8 {
    return if (finish_reason) |reason| reason.label() else "(none)";
}

fn traceSseTermination(trace: ?ResolvedModelTrace, cause: []const u8, finish_reason: ?types.ProviderFinishReason) void {
    debug_trace.logf("stream", "termination cause={s} finish_reason={s}", .{
        cause,
        finish_reason_label(finish_reason),
    });
    if (trace) |resolved| {
        debug_trace.eventf("gateway", "sse_termination", resolved.ctx, "cause={s} finish_reason={s}", .{
            cause,
            finish_reason_label(finish_reason),
        });
    }
}

const SseFinishEvent = struct {
    finish_reason: types.ProviderFinishReason,
    usage: types.Usage = .{},
};

const SseFinishParseError = error{
    InvalidProviderFinishReason,
    UnknownProviderFinishReason,
};

fn parseSseFinishEvent(
    alloc: std.mem.Allocator,
    root: std.json.Value,
    provider_failure_detail: *?[]u8,
) !SseFinishEvent {
    const finish_reason = try parseSseFinishReason(root);
    if (finish_reason == .provider_error) {
        try captureProviderFailureDetail(alloc, provider_failure_detail, root);
    }
    return .{
        .finish_reason = finish_reason,
        .usage = parseSseUsage(root),
    };
}

fn parseSseFinishReason(root: std.json.Value) SseFinishParseError!types.ProviderFinishReason {
    if (root != .object) return error.InvalidProviderFinishReason;
    const finish_reason_value = root.object.get("finishReason") orelse
        return error.InvalidProviderFinishReason;
    if (finish_reason_value != .object) return error.InvalidProviderFinishReason;
    const unified_value = finish_reason_value.object.get("unified") orelse
        return error.InvalidProviderFinishReason;
    if (unified_value != .string) return error.InvalidProviderFinishReason;
    return types.ProviderFinishReason.parse_unified(unified_value.string) orelse
        error.UnknownProviderFinishReason;
}

fn parseSseUsage(root: std.json.Value) types.Usage {
    if (root != .object) return .{};
    const usage_value = root.object.get("usage") orelse return .{};
    if (usage_value != .object) return .{};
    return .{
        .input_tokens = parseSseTokenTotal(usage_value, "inputTokens"),
        .output_tokens = parseSseTokenTotal(usage_value, "outputTokens"),
    };
}

fn parseSseTokenTotal(usage_value: std.json.Value, key: []const u8) ?u64 {
    if (usage_value != .object) return null;
    const token_value = usage_value.object.get(key) orelse return null;
    if (token_value != .object) return null;
    const total_value = token_value.object.get("total") orelse return null;
    if (total_value != .integer or total_value.integer < 0) return null;
    return @intCast(total_value.integer);
}

const SseBillingParseError = std.mem.Allocator.Error || error{InvalidSseBilling};

fn parseSseBilling(
    alloc: std.mem.Allocator,
    root: std.json.Value,
    created_at_ms: ?i64,
    tools: []const SseToolCallAccumulator,
) SseBillingParseError!types.ProviderBilling {
    const timestamp = created_at_ms orelse return error.InvalidSseBilling;
    const usage = if (root == .object)
        root.object.get("usage") orelse return error.InvalidSseBilling
    else
        return error.InvalidSseBilling;
    if (usage != .object) return error.InvalidSseBilling;
    const input = usage.object.get("inputTokens") orelse
        return error.InvalidSseBilling;
    const output = usage.object.get("outputTokens") orelse
        return error.InvalidSseBilling;
    if (input != .object or output != .object) return error.InvalidSseBilling;

    const provider_metadata = root.object.get("providerMetadata") orelse
        return error.InvalidSseBilling;
    if (provider_metadata != .object) return error.InvalidSseBilling;
    const gateway = provider_metadata.object.get("gateway") orelse
        return error.InvalidSseBilling;
    if (gateway != .object) return error.InvalidSseBilling;
    const routing = gateway.object.get("routing") orelse
        return error.InvalidSseBilling;
    if (routing != .object) return error.InvalidSseBilling;
    const model_value = routing.object.get("canonicalSlug") orelse
        return error.InvalidSseBilling;
    if (model_value != .string or
        model_value.string.len == 0 or
        model_value.string.len > 1024)
    {
        return error.InvalidSseBilling;
    }
    for (model_value.string) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidSseBilling;
    }

    const cost_value = gateway.object.get("cost") orelse
        return error.InvalidSseBilling;
    if (cost_value != .string) return error.InvalidSseBilling;
    const total_cost = std.fmt.parseFloat(f64, cost_value.string) catch
        return error.InvalidSseBilling;
    if (!std.math.isFinite(total_cost) or total_cost < 0) {
        return error.InvalidSseBilling;
    }

    var billable_web_search_calls: u64 = 0;
    for (tools) |tool| {
        if (tool.provenance != .provider_executed) continue;
        if (!std.mem.eql(u8, tool.name.items, "web_search") and
            !std.mem.endsWith(u8, tool.name.items, "_search"))
        {
            continue;
        }
        billable_web_search_calls = std.math.add(
            u64,
            billable_web_search_calls,
            1,
        ) catch return error.InvalidSseBilling;
    }

    const input_tokens = try parseBillingInteger(input.object.get("total"));
    const output_tokens = try parseBillingInteger(output.object.get("total"));
    const cache_read_tokens = try parseOptionalBillingInteger(
        input.object.get("cacheRead"),
    );
    const cache_write_tokens = try parseOptionalBillingInteger(
        input.object.get("cacheWrite"),
    );
    const reasoning_tokens = try parseOptionalNullableBillingInteger(
        output.object.get("reasoning"),
    );
    if (cache_read_tokens > input_tokens or
        cache_write_tokens > input_tokens or
        (reasoning_tokens != null and reasoning_tokens.? > output_tokens))
    {
        return error.InvalidSseBilling;
    }

    return .{
        .created_at_ms = timestamp,
        .model = try alloc.dupe(u8, model_value.string),
        .total_cost = total_cost,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = cache_read_tokens,
        .cache_write_tokens = cache_write_tokens,
        .reasoning_tokens = reasoning_tokens,
        .billable_web_search_calls = billable_web_search_calls,
    };
}

fn parseBillingInteger(value: ?std.json.Value) error{InvalidSseBilling}!u64 {
    const actual = value orelse return error.InvalidSseBilling;
    if (actual != .integer or actual.integer < 0) {
        return error.InvalidSseBilling;
    }
    return @intCast(actual.integer);
}

fn parseOptionalBillingInteger(
    value: ?std.json.Value,
) error{InvalidSseBilling}!u64 {
    return if (value) |actual| try parseBillingInteger(actual) else 0;
}

fn parseOptionalNullableBillingInteger(
    value: ?std.json.Value,
) error{InvalidSseBilling}!?u64 {
    return if (value) |actual|
        if (actual == .null) null else try parseBillingInteger(actual)
    else
        null;
}

const SseLineRead = union(enum) {
    line: []const u8,
    read_failed,
    eof,
};

const SseEventRead = union(enum) {
    data: []const u8,
    done,
    ignored,
    read_failed,
    eof,
};

const SseEventReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    max_line_bytes: usize,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn releaseLine(self: *@This()) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *@This(), alloc: std.mem.Allocator, reader: anytype) !SseEventRead {
        const line = switch (try self.readLine(alloc, reader)) {
            .line => |line| line,
            .read_failed => return .read_failed,
            .eof => return .eof,
        };

        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) return .ignored;
        if (trimmed[0] == ':') return .ignored;

        if (std.mem.eql(u8, trimmed, "DONE")) return .done;

        const data_prefix = "data: ";
        if (!std.mem.startsWith(u8, trimmed, data_prefix)) return .ignored;

        const json_text = trimmed[data_prefix.len..];
        if (std.mem.eql(u8, json_text, "[DONE]")) return .done;
        return .{ .data = json_text };
    }

    fn readLine(self: *@This(), alloc: std.mem.Allocator, reader: anytype) !SseLineRead {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.GatewaySseReadStalled;
                    if (buffered.len > self.max_line_bytes - self.pending_line.items.len) {
                        return error.GatewaySseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return .read_failed,
            } orelse {
                if (self.pending_line.items.len > 0) return .{ .line = self.pending_line.items };
                return .eof;
            };

            if (fragment.len > self.max_line_bytes - self.pending_line.items.len) {
                return error.GatewaySseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return .{ .line = fragment };
            try self.pending_line.appendSlice(alloc, fragment);
            return .{ .line = self.pending_line.items };
        }
    }
};

fn captureGenerationMetadata(
    alloc: std.mem.Allocator,
    root: std.json.Value,
    generation_id: *?[]u8,
    invalid: *bool,
) !void {
    if (root != .object) return;
    const provider_metadata = root.object.get("providerMetadata") orelse return;
    if (provider_metadata != .object) {
        invalid.* = true;
        return;
    }
    const gateway = provider_metadata.object.get("gateway") orelse return;
    if (gateway != .object) {
        invalid.* = true;
        return;
    }
    const generation_value = gateway.object.get("generationId") orelse return;
    if (generation_value != .string or !types.validGatewayGenerationId(generation_value.string)) {
        invalid.* = true;
        return;
    }
    if (generation_id.*) |existing| {
        if (!std.mem.eql(u8, existing, generation_value.string)) invalid.* = true;
        return;
    }
    generation_id.* = try alloc.dupe(u8, generation_value.string);
}

/// Decodes an AI Gateway SSE response from a transport-owned reader.
///
/// The returned completion and every populated child buffer are owned by
/// `alloc`. This is the shared protocol boundary used by native HTTP and web
/// host transports; transports remain responsible for status and headers.
pub fn consumeGatewaySseStream(
    alloc: std.mem.Allocator,
    reader: *std.Io.Reader,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_reasoning_chunk: ?StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.ModelCompletion {
    return consumeSseStreamTraced(
        alloc,
        reader,
        callback_ctx,
        on_content_chunk,
        on_tool_start,
        on_reasoning_chunk,
        null,
        cancel_flag,
        null,
        null,
        content_capture_limit,
    );
}

fn consumeSseStreamTraced(
    alloc: std.mem.Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: StreamCallback,
    on_tool_start: ?ToolStartCallback,
    on_reasoning_chunk: ?StreamCallback,
    on_tool_input_chunk: ?StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    resolved_model_trace: ?ResolvedModelTrace,
    expected_provider_tool_name: ?[]const u8,
    content_capture_limit: ?usize,
) !types.ModelCompletion {
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(alloc);

    var streamed_tool_inputs: std.ArrayList(SseStreamedToolInput) = .empty;
    defer {
        for (streamed_tool_inputs.items) |*record| record.deinit(alloc);
        streamed_tool_inputs.deinit(alloc);
    }

    var tool_accumulators: std.ArrayList(SseToolCallAccumulator) = .empty;
    defer {
        for (tool_accumulators.items) |*acc| acc.deinit(alloc);
        tool_accumulators.deinit(alloc);
    }

    var finish_reason_holder: ?types.ProviderFinishReason = null;
    var finish_usage: types.Usage = .{};
    var finish_billing: ?types.ProviderBilling = null;
    defer if (finish_billing) |billing| alloc.free(@constCast(billing.model));
    var generation_id: ?[]u8 = null;
    defer if (generation_id) |id| alloc.free(id);
    var resolved_model: ?[]u8 = null;
    defer if (resolved_model) |model| alloc.free(model);
    var response_timestamp_ms: ?i64 = null;
    var response_timestamp_invalid = false;
    var generation_metadata_invalid = false;
    var provider_result_identity_failure: ?types.ProviderResultIdentityFailure = null;
    var provider_failure_detail: ?[]u8 = null;
    defer if (provider_failure_detail) |detail| alloc.free(detail);
    var data_event_count: usize = 0;

    var event_reader = SseEventReader{ .max_line_bytes = max_sse_event_line_bytes };
    defer event_reader.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) {
            traceSseTermination(resolved_model_trace, "cancellation", finish_reason_holder);
            break;
        }

        const event = try event_reader.next(alloc, reader);
        defer event_reader.releaseLine();

        const json_text = switch (event) {
            .data => |json_text| json_text,
            .done => {
                traceSseTermination(resolved_model_trace, "done_without_finish", finish_reason_holder);
                break;
            },
            .ignored => continue,
            .read_failed => {
                if (cancel_flag.load(.seq_cst)) {
                    traceSseTermination(resolved_model_trace, "cancellation", finish_reason_holder);
                    break;
                }
                traceSseTermination(resolved_model_trace, "read_failure", finish_reason_holder);
                return error.ReadFailed;
            },
            .eof => {
                traceSseTermination(resolved_model_trace, "eof_without_finish", finish_reason_holder);
                break;
            },
        };
        data_event_count += 1;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            traceMalformedSseEvent(json_text.len);
            continue;
        };
        defer parsed.deinit();

        const root = parsed.value;
        traceParsedSseEvent(alloc, root, json_text.len);
        if (root != .object) continue;
        try captureGenerationMetadata(
            alloc,
            root,
            &generation_id,
            &generation_metadata_invalid,
        );

        const type_val = root.object.get("type") orelse continue;
        if (type_val != .string) continue;
        const event_type = type_val.string;

        if (std.mem.eql(u8, event_type, "response-metadata")) {
            if (root.object.get("timestamp")) |timestamp_value| {
                if (timestamp_value == .string) {
                    const timestamp = types.parseGatewayTimestamp(
                        timestamp_value.string,
                    ) catch null;
                    if (timestamp) |valid_timestamp| {
                        if (response_timestamp_ms) |existing| {
                            if (existing != valid_timestamp) {
                                response_timestamp_invalid = true;
                                response_timestamp_ms = null;
                            }
                        } else if (!response_timestamp_invalid) {
                            response_timestamp_ms = valid_timestamp;
                        }
                    } else {
                        response_timestamp_invalid = true;
                        response_timestamp_ms = null;
                    }
                } else {
                    response_timestamp_invalid = true;
                    response_timestamp_ms = null;
                }
            }
            if (root.object.get("modelId")) |model_val| {
                if (model_val == .string and model_val.string.len > 0 and model_val.string.len <= 128) {
                    if (resolved_model) |existing| {
                        if (!std.mem.eql(u8, existing, model_val.string)) {
                            generation_metadata_invalid = true;
                        }
                    } else {
                        resolved_model = try alloc.dupe(u8, model_val.string);
                    }
                } else {
                    generation_metadata_invalid = true;
                }
            }
            if (resolved_model_trace) |trace| {
                if (root.object.get("modelId")) |model_val| {
                    if (model_val == .string and model_val.string.len > 0) {
                        traceResolvedModelOnce(trace.requested_model, "sse.response-metadata.modelId", model_val.string, trace.ctx);
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "error")) {
            try captureProviderFailureDetail(alloc, &provider_failure_detail, root);
        } else if (std.mem.eql(u8, event_type, "text-delta")) {
            if (root.object.get("delta")) |delta_val| {
                if (delta_val == .string and delta_val.string.len > 0) {
                    const retained = if (content_capture_limit) |limit|
                        delta_val.string[0..@min(delta_val.string.len, limit -| content_buf.items.len)]
                    else
                        delta_val.string;
                    try content_buf.appendSlice(alloc, retained);
                    on_content_chunk(callback_ctx, delta_val.string);
                }
            }
        } else if (std.mem.eql(u8, event_type, "reasoning-delta")) {
            if (on_reasoning_chunk) |callback| {
                if (root.object.get("delta")) |delta_val| {
                    if (delta_val == .string and delta_val.string.len > 0) {
                        callback(callback_ctx, delta_val.string);
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "tool-input-start")) {
            const id = streamedToolInputId(root, .invalid_start) orelse continue;
            const name = if (root.object.get("toolName")) |name_value|
                if (name_value == .string) name_value.string else ""
            else
                "";

            if (findStreamedToolInput(streamed_tool_inputs.items, id)) |index| {
                const existing = &streamed_tool_inputs.items[index];
                if (existing.state != .open) {
                    traceStreamStateAnomaly(.late_start);
                } else if (!std.mem.eql(u8, existing.name.items, name)) {
                    traceStreamStateAnomaly(.conflicting_start);
                }
                continue;
            }

            var record = try initStreamedToolInput(alloc, id, name);
            streamed_tool_inputs.append(alloc, record) catch |err| {
                record.deinit(alloc);
                return err;
            };
            if (name.len > 0) {
                if (on_tool_start) |cb| cb(callback_ctx, id, name, null);
            }
        } else if (std.mem.eql(u8, event_type, "tool-input-delta") or
            std.mem.eql(u8, event_type, "tool-input-end"))
        {
            const is_delta = std.mem.eql(u8, event_type, "tool-input-delta");
            const anomaly: StreamStateAnomaly = if (is_delta)
                .unmatched_or_late_delta
            else
                .unmatched_or_duplicate_end;
            const id = streamedToolInputId(root, anomaly) orelse continue;
            const index = findStreamedToolInput(streamed_tool_inputs.items, id) orelse {
                traceStreamStateAnomaly(anomaly);
                continue;
            };
            const record = &streamed_tool_inputs.items[index];
            if (record.state != .open) {
                traceStreamStateAnomaly(anomaly);
                continue;
            }
            if (is_delta) {
                const delta_value = root.object.get("delta") orelse continue;
                if (delta_value != .string) continue;
                try record.arguments.appendSlice(alloc, delta_value.string);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, delta_value.string);
            } else {
                record.state = .ended;
            }
        } else if (std.mem.eql(u8, event_type, "tool-call")) {
            var acc: SseToolCallAccumulator = .{
                .id = .empty,
                .name = .empty,
                .arguments = .empty,
            };
            var acc_owned = true;
            defer if (acc_owned) acc.deinit(alloc);

            acc.final_identity = finalToolIdentity(root.object.get("toolCallId"));
            if (acc.final_identity == .valid) {
                try acc.id.appendSlice(alloc, root.object.get("toolCallId").?.string);
            }

            var duplicate_final_id = false;
            if (acc.final_identity == .valid) {
                for (tool_accumulators.items) |prior| {
                    if (prior.final_identity == .valid and
                        std.mem.eql(u8, prior.id.items, acc.id.items))
                    {
                        duplicate_final_id = true;
                        break;
                    }
                }
            }

            var stream_index = if (acc.final_identity == .valid)
                findStreamedToolInput(streamed_tool_inputs.items, acc.id.items)
            else
                null;

            const final_name_value = root.object.get("toolName");
            if (final_name_value) |name_val| {
                if (name_val == .string) try acc.name.appendSlice(alloc, name_val.string);
            }
            if (acc.name.items.len == 0 and final_name_value == null) {
                if (stream_index) |index| {
                    try acc.name.appendSlice(alloc, streamed_tool_inputs.items[index].name.items);
                }
            }

            var final_name_compatible = true;
            if (stream_index) |index| {
                if (final_name_value) |name_value| {
                    const record = &streamed_tool_inputs.items[index];
                    if (name_value != .string or
                        !std.mem.eql(u8, name_value.string, record.name.items))
                    {
                        final_name_compatible = false;
                        setProviderResultFailure(
                            &provider_result_identity_failure,
                            .conflicting_tool_name,
                        );
                    }
                }
            }

            const final_input_state = if (root.object.get("input")) |input_value| blk: {
                const integrity = try appendSupportedFinalInput(
                    alloc,
                    &acc.arguments,
                    input_value,
                    acc.id.items,
                    acc.name.items,
                );
                acc.argument_integrity = integrity;
                break :blk if (integrity == .valid)
                    FinalToolInputState.valid
                else
                    FinalToolInputState.malformed;
            } else FinalToolInputState.absent;
            if (stream_index == null and
                final_input_state == .valid and
                final_name_compatible and
                acc.final_identity == .valid and
                !duplicate_final_id)
            {
                stream_index = try findEquivalentEndedStreamedToolInput(
                    alloc,
                    streamed_tool_inputs.items,
                    acc.name.items,
                    acc.arguments.items,
                );
            }
            if (final_input_state == .absent and
                final_name_compatible and
                acc.final_identity == .valid and
                !duplicate_final_id)
            {
                if (stream_index) |index| {
                    const record = &streamed_tool_inputs.items[index];
                    switch (record.state) {
                        .ended => acc.argument_integrity = try appendSerializedToolArguments(
                            alloc,
                            &acc.arguments,
                            record.arguments.items,
                            acc.id.items,
                            acc.name.items,
                            .streamed_fallback,
                        ),
                        .open => setProviderResultFailure(
                            &provider_result_identity_failure,
                            .incomplete_streamed_input,
                        ),
                        .finalized => setProviderResultFailure(
                            &provider_result_identity_failure,
                            .invalid_tool_input,
                        ),
                    }
                } else {
                    setProviderResultFailure(
                        &provider_result_identity_failure,
                        .invalid_tool_input,
                    );
                }
            }

            if (root.object.get("providerExecuted")) |provider_value| {
                if (provider_value == .bool) {
                    if (provider_value.bool) acc.provenance = .provider_executed;
                } else {
                    setProviderResultFailure(
                        &provider_result_identity_failure,
                        .malformed_provider_executed,
                    );
                }
            } else if (expected_provider_tool_name) |expected_name| {
                if (final_name_compatible and
                    std.mem.eql(u8, acc.name.items, expected_name))
                {
                    acc.provenance = .provider_executed;
                }
            }

            if (stream_index) |index| {
                const record = &streamed_tool_inputs.items[index];
                if (!std.mem.eql(u8, record.id.items, acc.id.items)) {
                    try acc.provisional_id.appendSlice(alloc, record.id.items);
                }
                if (final_name_compatible and
                    !record.label_sent and
                    acc.argument_integrity == .valid)
                {
                    if (on_tool_start) |cb| {
                        if (extractFirstJsonStringValue(acc.arguments.items)) |value| {
                            record.label_sent = true;
                            cb(callback_ctx, record.id.items, record.name.items, value);
                        }
                    }
                }
            }

            try tool_accumulators.append(alloc, acc);
            acc_owned = false;
            if (stream_index) |index| {
                streamed_tool_inputs.items[index].state = .finalized;
            }
        } else if (std.mem.eql(u8, event_type, "tool-result")) {
            const result_identity = finalToolIdentity(root.object.get("toolCallId"));
            if (result_identity != .valid) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    switch (result_identity) {
                        .absent => .absent,
                        .empty => .empty,
                        .wrong_type => .wrong_type,
                        .valid => unreachable,
                    },
                );
                continue;
            }

            const result_id = root.object.get("toolCallId").?.string;
            var matched_index: ?usize = null;
            var match_count: usize = 0;
            for (tool_accumulators.items, 0..) |candidate, i| {
                if (candidate.final_identity == .valid and std.mem.eql(u8, candidate.id.items, result_id)) {
                    match_count += 1;
                    matched_index = i;
                }
            }
            if (match_count != 1) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    if (match_count == 0) .unmatched else .ambiguous,
                );
                continue;
            }

            const acc = &tool_accumulators.items[matched_index.?];
            if (acc.provenance != .provider_executed) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    .provenance_contradiction,
                );
                continue;
            }
            if (acc.provider_result_state == .final) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    .duplicate_result,
                );
                continue;
            }

            const preliminary = if (root.object.get("preliminary")) |preliminary_value| blk: {
                if (preliminary_value != .bool) {
                    setProviderResultFailure(
                        &provider_result_identity_failure,
                        .malformed_preliminary,
                    );
                    continue;
                }
                break :blk preliminary_value.bool;
            } else false;

            const result_value = root.object.get("result") orelse {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    .missing_result,
                );
                continue;
            };
            if (result_value == .null) {
                setProviderResultFailure(
                    &provider_result_identity_failure,
                    .missing_result,
                );
                continue;
            }

            const owned_result = try stringifyJsonValueOwned(alloc, result_value);
            if (acc.provider_result) |old_result| alloc.free(old_result);
            acc.provider_result = owned_result;
            acc.provider_result_state = if (preliminary) .preliminary else .final;
        } else if (std.mem.eql(u8, event_type, "finish")) {
            const finish_event = parseSseFinishEvent(alloc, root, &provider_failure_detail) catch |err| {
                switch (err) {
                    error.UnknownProviderFinishReason => {
                        traceSseTermination(resolved_model_trace, "invalid_finish", null);
                        return error.InvalidProviderFinishReason;
                    },
                    else => return err,
                }
            };
            finish_reason_holder = finish_event.finish_reason;
            finish_usage = finish_event.usage;
            finish_billing = parseSseBilling(
                alloc,
                root,
                if (response_timestamp_invalid) null else response_timestamp_ms,
                tool_accumulators.items,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidSseBilling => invalid: {
                    debug_trace.logf(
                        "sse",
                        "stream billing ignored reason=invalid_terminal_metadata",
                        .{},
                    );
                    break :invalid null;
                },
            };
            traceSseTermination(resolved_model_trace, "valid_finish", finish_reason_holder);
            break;
        }
    }

    var completion: types.ModelCompletion = .{};
    errdefer deinitGatewayCompletion(alloc, &completion);

    if (content_buf.items.len > 0) {
        completion.content = try alloc.dupe(u8, content_buf.items);
    }

    completion.tool_calls = try materializeToolCalls(alloc, tool_accumulators.items);

    completion.provider_result_identity_failure = provider_result_identity_failure;
    completion.provider_failure_detail = provider_failure_detail;
    provider_failure_detail = null;
    completion.generation_id = generation_id;
    generation_id = null;
    completion.billing = finish_billing;
    finish_billing = null;
    completion.generation_metadata_invalid = generation_metadata_invalid;
    completion.finish_reason = finish_reason_holder;
    completion.usage = finish_usage;

    debug_trace.logf(
        "stream",
        "sse summary events={d} finish_reason={s}",
        .{
            data_event_count,
            finish_reason_label(completion.finish_reason),
        },
    );

    return completion;
}

fn finalToolIdentity(value: ?std.json.Value) types.FinalToolIdentity {
    const actual = value orelse return .absent;
    if (actual != .string) return .wrong_type;
    return if (actual.string.len == 0) .empty else .valid;
}

fn readTraceFileForTest(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 65536);
}

// Gateway `tool-call` events may send `input` as parsed JSON instead of a
// serialized string. Normalize it so downstream tool dispatch always receives
// a JSON argument buffer.

const BoundedProbeStage = enum {
    request_open,
    dns,
    connect,
    tls,
    send,
    response_head,
    response_body,
    retry_sleep,
};

const BoundedProbeMode = enum {
    success,
    wait,
    success_and_cancel,
    wait_and_mark_cancel_when_task_is_cancelled,
};

const BoundedProbe = struct {
    alloc: std.mem.Allocator,
    cancel_flag: *std.atomic.Value(bool),
    mode: BoundedProbeMode,
    stage: BoundedProbeStage = .request_open,
    request_starts: usize = 0,
    active_tasks: usize = 0,
    network_opens: usize = 0,
    reached_stage: ?BoundedProbeStage = null,

    fn run(self: *@This()) anyerror!StreamResult {
        self.request_starts += 1;
        self.active_tasks += 1;
        defer self.active_tasks -= 1;
        self.network_opens += 1;
        self.reached_stage = self.stage;

        switch (self.mode) {
            .success => return self.successResult(),
            .wait => {
                try io_mod.getIo().sleep(.fromSeconds(5), .awake);
                return error.TestRequestDidNotBlock;
            },
            .success_and_cancel => {
                self.cancel_flag.store(true, .seq_cst);
                return self.successResult();
            },
            .wait_and_mark_cancel_when_task_is_cancelled => {
                io_mod.getIo().sleep(.fromSeconds(5), .awake) catch |err| {
                    if (err == error.Canceled) self.cancel_flag.store(true, .seq_cst);
                    return err;
                };
                return error.TestRequestDidNotBlock;
            },
        }
    }

    fn successResult(self: *@This()) !StreamResult {
        return .{
            .status = .ok,
            .completion = .{
                .content = try self.alloc.dupe(u8, "ok"),
                .finish_reason = .stop,
            },
        };
    }
};

const LoopbackGatewayMode = enum {
    reset_on_accept,
    tls_handshake_stall,
    request_send_stall,
    response_head_stall,
    response_body_stall,
    response_body_delayed_success,
    response_body_progress,
    retry_once,
    retry_once_then_success,
    success,
    success_capture,
    model_catalog_success,
    private_model_catalog_success,
};

const LoopbackGatewayFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    mode: LoopbackGatewayMode,
    hold_ms: u64,
    thread: ?std.Thread = null,
    server_open: bool = true,
    accept_started: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(bool) = .init(false),
    reached_stage: std.atomic.Value(bool) = .init(false),
    request_headers: [16 * 1024]u8 = undefined,
    request_headers_len: std.atomic.Value(usize) = .init(0),
    failure: ?anyerror = null,

    fn init(mode: LoopbackGatewayMode, hold_ms: u64) !@This() {
        var fixture: @This() = .{
            .server = undefined,
            .mode = mode,
            .hold_ms = hold_ms,
        };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        std.debug.assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.server_open) return;

        const zio = self.io();
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            self.wakeAccept();
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
        self.server_open = false;
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn waitForAcceptStart(self: *@This(), timeout_ms: u64) bool {
        return self.waitForSignal(&self.accept_started, timeout_ms);
    }

    fn waitForStageOrDone(self: *@This(), request_done: *std.atomic.Value(bool)) bool {
        while (!self.reached_stage.load(.seq_cst)) {
            if (request_done.load(.seq_cst) or self.stopping.load(.seq_cst)) return false;
            sleepBlocking(1);
        }
        return true;
    }

    fn waitForSignal(self: *@This(), signal: *std.atomic.Value(bool), timeout_ms: u64) bool {
        var remaining_ms = timeout_ms;
        while (remaining_ms > 0) : (remaining_ms -= 1) {
            if (signal.load(.seq_cst)) return true;
            if (self.stopping.load(.seq_cst)) return false;
            sleepBlocking(1);
        }
        return signal.load(.seq_cst);
    }

    fn wakeAccept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        var stream = address.connect(zio, .{
            .mode = .stream,
        }) catch return;
        stream.close(zio);
    }

    fn sleepBlocking(milliseconds: u64) void {
        var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
        sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
    }

    fn hold(self: *@This()) void {
        var remaining_ms = self.hold_ms;
        while (remaining_ms > 0 and !self.stopping.load(.seq_cst)) {
            const sleep_ms: u64 = @min(remaining_ms, 10);
            sleepBlocking(sleep_ms);
            remaining_ms -= sleep_ms;
        }
    }

    fn markStage(self: *@This()) void {
        self.reached_stage.store(true, .seq_cst);
    }

    fn captureRequestHeaders(self: *@This(), headers: []const u8) void {
        const len = @min(headers.len, self.request_headers.len);
        @memcpy(self.request_headers[0..len], headers[0..len]);
        self.request_headers_len.store(len, .seq_cst);
    }

    fn capturedHeaderValue(self: *@This(), name: []const u8) ?[]const u8 {
        const len = self.request_headers_len.load(.seq_cst);
        if (len == 0) return null;
        return rawHeaderValue(self.request_headers[0..len], name);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and err == error.SocketNotListening) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        self.accept_started.store(true, .seq_cst);
        var stream = try self.server.accept(zio);
        defer stream.close(zio);
        if (self.stopping.load(.seq_cst)) return;
        self.accepted.store(true, .seq_cst);

        switch (self.mode) {
            .reset_on_accept => {
                const reset_on_close: std.posix.linger = .{
                    .onoff = 1,
                    .linger = 0,
                };
                try std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.LINGER,
                    std.mem.asBytes(&reset_on_close),
                );
                self.markStage();
            },
            .tls_handshake_stall => {
                self.markStage();
                self.hold();
            },
            .request_send_stall => {
                const receive_buffer: c_int = 1024;
                std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.RCVBUF,
                    std.mem.asBytes(&receive_buffer),
                ) catch {};
                self.markStage();
                self.hold();
            },
            .response_head_stall => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                self.hold();
            },
            .response_body_stall => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"text-delta\",\"id\":\"partial\",\"delta\":\"partial\"}\n\n",
                );
                self.markStage();
                self.hold();
            },
            .response_body_delayed_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n",
                );
                self.markStage();
                self.hold();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n",
                );
            },
            .response_body_progress => {
                try readLoopbackGatewayRequest(zio, stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n",
                );
                self.markStage();
                for (0..30) |_| {
                    if (self.stopping.load(.seq_cst)) return;
                    writeLoopbackGatewayBytes(zio, stream, ": progress\n\n") catch return;
                    sleepBlocking(20);
                }
                self.hold();
            },
            .retry_once => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 503 Service Unavailable\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                );
            },
            .retry_once_then_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 503 Service Unavailable\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                );

                var recovered_stream = try self.server.accept(zio);
                defer recovered_stream.close(zio);
                try readLoopbackGatewayRequest(zio, recovered_stream, self);
                try writeLoopbackGatewayBytes(
                    zio,
                    recovered_stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n",
                );
            },
            .success => {
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n",
                );
                self.hold();
            },
            .success_capture => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: text/event-stream\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "data: {\"type\":\"text-delta\",\"id\":\"answer\",\"delta\":\"ok\"}\n\n" ++
                        "data: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\"}}\n\n",
                );
            },
            .model_catalog_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: application/json\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        loopback_model_catalog_json,
                );
            },
            .private_model_catalog_success => {
                try readLoopbackGatewayRequest(zio, stream, self);
                self.markStage();
                try writeLoopbackGatewayBytes(
                    zio,
                    stream,
                    "HTTP/1.1 200 OK\r\n" ++
                        "Content-Type: application/json\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        loopback_private_model_catalog_json,
                );
            },
        }
    }
};

const loopback_model_catalog_json =
    "{\"data\":[{\"id\":\"openai/gpt-5\",\"type\":\"language\",\"tags\":[\"reasoning\",\"tool-use\",\"vision\",\"file-input\",\"web-search\",\"explicit-caching\",\"implicit-caching\"],\"context_window\":256000,\"max_tokens\":32000},{\"id\":\"anthropic/claude-opus-4\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000},{\"id\":\"anthropic/claude-sonnet-4\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000}]}";

const loopback_private_model_catalog_json =
    "{\"data\":[{\"id\":\"openai/gpt-5\",\"type\":\"language\",\"tags\":[\"reasoning\",\"tool-use\",\"vision\",\"file-input\",\"web-search\",\"explicit-caching\",\"implicit-caching\"],\"context_window\":256000,\"max_tokens\":32000},{\"id\":\"anthropic/claude-opus-4\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000},{\"id\":\"anthropic/claude-sonnet-4\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000},{\"id\":\"private/blue-hornbill\",\"type\":\"language\",\"tags\":[\"tool-use\"],\"context_window\":200000}]}";

const RequestOpenProbe = struct {
    attempts: usize = 0,
    tls_failure_attempt: ?usize = null,
    delays_ms: [3]i64 = .{ 0, 0, 0 },

    fn requestOpenOverride(self: *@This()) RequestOpenOverride {
        return .{ .ctx = @ptrCast(self), .run = open };
    }

    fn open(
        raw_ctx: *anyopaque,
        client: *std.http.Client,
        method: std.http.Method,
        uri: std.Uri,
        options: std.http.Client.RequestOptions,
    ) anyerror!std.http.Client.Request {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        const attempt_index = self.attempts;
        self.attempts += 1;
        if (attempt_index < self.delays_ms.len) {
            const delay_ms = self.delays_ms[attempt_index];
            if (delay_ms > 0) {
                try io_mod.getIo().sleep(.fromMilliseconds(delay_ms), .awake);
            }
        }
        if (self.tls_failure_attempt == attempt_index) {
            return error.TlsInitializationFailed;
        }
        return client.request(method, uri, options);
    }
};

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

fn readLoopbackGatewayRequest(zio: std.Io, stream: std.Io.net.Stream, fixture: *LoopbackGatewayFixture) !void {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(zio, &socket_buffer);
    var request: [16 * 1024]u8 = undefined;
    var header_len: usize = 0;

    while (header_len < request.len) {
        request[header_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.TestRequestClosedEarly,
            else => return err,
        };
        header_len += 1;
        if (!std.mem.endsWith(u8, request[0..header_len], "\r\n\r\n")) continue;

        const headers = request[0 .. header_len - 4];
        fixture.captureRequestHeaders(headers);
        if (loopbackContentLength(headers)) |content_length| {
            reader.interface.discardAll(content_length) catch |err| switch (err) {
                error.EndOfStream => return error.TestRequestClosedEarly,
                else => return err,
            };
        }
        return;
    }

    return error.TestRequestTooLarge;
}

fn rawHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon_index = std.mem.findScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon_index], " \t");
        if (!std.ascii.eqlIgnoreCase(header_name, name)) continue;
        return std.mem.trim(u8, line[colon_index + 1 ..], " \t");
    }
    return null;
}

fn loopbackContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const name = "content-length:";
        if (line.len < name.len or !std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " \t"), 10) catch null;
    }
    return null;
}

fn writeLoopbackGatewayBytes(zio: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(zio, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
