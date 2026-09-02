const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const grok_session = @import("../core/auth/grok_session.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const responses_protocol = @import("responses_protocol.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");

const Allocator = std.mem.Allocator;
const endpoint = "https://cli-chat-proxy.grok.com/v1/responses";
// The proxy gates this as Grok wire compatibility; fx identifies itself separately below.
const proxy_compatibility_version = "1.0.6";
const e2e_endpoint_env = "FX_E2E_XAI_GROK_RESPONSES_URL";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_provider_state_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidXaiGrokModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidXaiGrokModel;
    }
}

pub fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    for (request.messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
        try instructions.writer.writeAll(text);
    }
    if (instructions.written().len == 0) try instructions.writer.writeAll("You are a helpful assistant.");

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true,\"instructions\":");
    try std.json.Stringify.value(instructions.written(), .{}, writer);
    try writer.writeAll(",\"input\":[");
    try writeResponsesInput(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');

    _ = try responses_protocol.writeTools(writer, alloc, request.tools);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    try writer.writeAll(",\"parallel_tool_calls\":true,\"include\":[\"reasoning.encrypted_content\"]");
    try writer.writeAll(",\"text\":{\"verbosity\":\"low\"");
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":true}");
    }
    try writer.writeByte('}');

    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeAll(",\"summary\":\"auto\"}");
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeResponsesInput(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    return responses_protocol.writeInput(writer, alloc, messages, images, .{
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    }) catch |err| switch (err) {
        error.ProviderStateTooLarge => error.XaiGrokProviderStateTooLarge,
        error.InvalidProviderState => error.InvalidXaiGrokProviderState,
        error.ToolCallLimitExceeded => error.XaiGrokToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.XaiGrokToolArgumentsTooLarge,
        else => err,
    };
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (request.credential.source != .grok_subscription) {
        return stream_provider.failResult(error.GrokSubscriptionCredentialRequired);
    }
    const account_id = request.credential.account_id orelse
        return stream_provider.failResult(error.GrokSubscriptionAccountRequired);
    if (!grok_session.validAccountId(account_id)) {
        return stream_provider.failResult(error.InvalidGrokSubscriptionAccount);
    }
    try validateModel(request.model);
    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);
    var result = streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
        if (requestDeadlineExpired(request)) return stream_provider.failResult(error.Timeout);
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return stream_provider.failResult(error.Timeout);
    }
    return result;
}

fn requestDeadlineExpired(request: stream_provider.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: []const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    const account_id = request.credential.account_id.?;
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.credential.secret});
    defer secret.zeroAndFree(alloc, auth_header);
    const request_endpoint = if (io_mod.getenv(e2e_endpoint_env)) |override| endpoint: {
        if (!gateway_client.isLoopbackHttpUrl(override)) {
            return stream_provider.failResult(error.InvalidE2EXaiGrokEndpoint);
        }
        break :endpoint override;
    } else endpoint;
    const uri = try std.Uri.parse(request_endpoint);

    var extra_headers_buf: [8]std.http.Header = undefined;
    var extra_count: usize = 0;
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-authenticateresponse", .value = "authenticate-response" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-grok-client-version", .value = proxy_compatibility_version };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-grok-client-identifier", .value = "fx" };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-grok-model-override", .value = request.model };
    extra_count += 1;
    extra_headers_buf[extra_count] = .{ .name = "x-grok-user-id", .value = account_id };
    extra_count += 1;
    if (request.session_id) |session_id| if (session_id.len > 0) {
        extra_headers_buf[extra_count] = .{ .name = "x-grok-conv-id", .value = session_id };
        extra_count += 1;
    };

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
        .extra_headers = extra_headers_buf[0..extra_count],
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
            connect_deadline = deadline;
        }
    }
    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        if (request.deadline) |deadline|
            try gateway_client.spawnHttpCancelWatcherBounded(
                &cancel_watch_done,
                request.cancel_flag,
                deadline,
                connection.stream_writer.stream,
            )
        else
            try gateway_client.spawnHttpCancelWatcher(
                &cancel_watch_done,
                request.cancel_flag,
                connection.stream_writer.stream,
            )
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "xAI Grok error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "xAI Grok error response exceeded the local limit");
        } else bounded_body;
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .ownership = .owned,
        } };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    var completion = try consumeSse(
        alloc,
        reader,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        EventBridge.toolInput,
        request.cancel_flag,
        request.content_capture_limit,
    );
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completion,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }
    const usage_outcome: stream_provider.UsageOutcome = usage: {
        if (completion.generation_id == null) {
            break :usage .{ .unavailable = .possibly_billed };
        }
        completion.billing = try responses_protocol.buildSubscriptionBilling(
            alloc,
            .grok,
            request.model,
            @max(io_mod.milliTimestamp(), 0),
            completion.usage,
        ) orelse break :usage .{ .unavailable = .possibly_billed };
        break :usage .{ .exact = .grok };
    };
    return .{ .completed = .{
        .completion = completion,
        .usage = usage_outcome,
        .ownership = .owned,
    } };
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
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

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
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

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,

    const Line = struct {
        bytes: []const u8,
        wire_bytes: usize,
    };

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate_bytes = responses_protocol.checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            ) catch return error.XaiGrokResourceLimitExceeded;
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.XaiGrokSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.XaiGrokSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) {
                    return .{
                        .bytes = self.pending_line.items,
                        .wire_bytes = self.pending_line.items.len,
                    };
                }
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.XaiGrokSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) {
                return .{
                    .bytes = fragment,
                    .wire_bytes = fragment.len + 1,
                };
            }
            try self.pending_line.appendSlice(alloc, fragment);
            return .{
                .bytes = self.pending_line.items,
                .wire_bytes = self.pending_line.items.len + 1,
            };
        }
    }
};

fn consumeSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.ModelCompletion {
    var reducer = responses_protocol.Reducer.init(alloc);
    defer reducer.deinit(alloc);
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    const callbacks = responses_protocol.StreamCallbacks{
        .context = callback_ctx,
        .on_content = on_content_chunk,
        .on_tool_start = on_tool_start,
        .on_reasoning = on_reasoning_chunk,
        .on_tool_input = on_tool_input_chunk,
    };
    const stream_limits = responses_protocol.StreamLimits{
        .aggregate_bytes = max_sse_aggregate_bytes,
        .count_json_bytes = false,
        .events = max_sse_events,
        .tool_calls = max_tool_calls,
        .tool_identity_bytes = max_tool_identity_bytes,
        .tool_arguments_bytes = max_tool_arguments_bytes,
        .provider_state_bytes = max_provider_state_bytes,
    };
    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (reducer.applyJson(
            alloc,
            json_text,
            callbacks,
            cancel_flag,
            content_capture_limit,
            stream_limits,
        ) catch |err| return mapReducerError(err)) break;
    }
    return reducer.finish(alloc, cancel_flag, stream_limits) catch |err|
        return mapReducerError(err);
}

fn mapReducerError(err: anyerror) anyerror {
    return switch (err) {
        error.InvalidEvent => error.InvalidXaiGrokSseEvent,
        error.ResponseFailed => error.XaiGrokResponseFailed,
        error.StreamIncomplete => error.XaiGrokStreamIncomplete,
        error.ToolCallLimitExceeded => error.XaiGrokToolCallLimitExceeded,
        error.ToolArgumentsTooLarge => error.XaiGrokToolArgumentsTooLarge,
        error.ResourceLimitExceeded => error.XaiGrokResourceLimitExceeded,
        else => err,
    };
}

fn buildEventCountSse(alloc: Allocator, event_count: usize) ![]u8 {
    const terminal_json = "{\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}";
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (1..event_count) |_| try out.writer.writeAll("data: {}\n\n");
    try out.writer.writeAll("data: ");
    try out.writer.writeAll(terminal_json);
    try out.writer.writeAll("\n\n");
    return out.toOwnedSlice();
}

fn buildIgnoredAggregateSse(alloc: Allocator, wire_bytes: usize) ![]u8 {
    const mixed_ignored_and_data = ": keepalive\n\nretry: 1000\ndata: {}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n";
    if (wire_bytes < mixed_ignored_and_data.len + terminal.len) return error.NoSpaceLeft;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(mixed_ignored_and_data);
    var remaining = wire_bytes - mixed_ignored_and_data.len - terminal.len;
    while (remaining > 0) {
        const line_wire_bytes = @min(remaining, max_sse_line_bytes + 1);
        if (line_wire_bytes > 1) {
            try out.writer.writeByte(':');
            try out.writer.splatByteAll('a', line_wire_bytes - 2);
        }
        try out.writer.writeByte('\n');
        remaining -= line_wire_bytes;
    }
    try out.writer.writeAll(terminal);
    return out.toOwnedSlice();
}

fn buildToolArgumentsSse(alloc: Allocator, argument_bytes: usize) ![]u8 {
    const chunk_count: usize = 8;
    const delta_prefix = "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"";
    const delta_suffix = "\"}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0," ++
            "\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"terminal\"}}\n\n",
    );
    const bytes_per_chunk = argument_bytes / chunk_count;
    var remainder = argument_bytes % chunk_count;
    for (0..chunk_count) |_| {
        const extra: usize = if (remainder > 0) 1 else 0;
        remainder -|= extra;
        try out.writer.writeAll(delta_prefix);
        try out.writer.splatByteAll('a', bytes_per_chunk + extra);
        try out.writer.writeAll(delta_suffix);
    }
    try out.writer.writeAll(terminal);
    return out.toOwnedSlice();
}

fn buildProviderStateSse(alloc: Allocator, provider_state_bytes: usize) ![]u8 {
    const item_count: usize = 8;
    const event_prefix = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":";
    const item_prefix = "{\"id\":\"rs\",\"type\":\"reasoning\",\"encrypted_content\":\"";
    const item_suffix = "\"}";
    const event_suffix = "}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    const framing_bytes = 2 + (item_count - 1) + item_count * (item_prefix.len + item_suffix.len);
    const content_bytes = provider_state_bytes - framing_bytes;
    const bytes_per_item = content_bytes / item_count;
    var remainder = content_bytes % item_count;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (0..item_count) |_| {
        const extra: usize = if (remainder > 0) 1 else 0;
        remainder -|= extra;
        try out.writer.writeAll(event_prefix);
        try out.writer.writeAll(item_prefix);
        try out.writer.splatByteAll('a', bytes_per_item + extra);
        try out.writer.writeAll(item_suffix);
        try out.writer.writeAll(event_suffix);
    }
    try out.writer.writeAll(terminal);
    return out.toOwnedSlice();
}
