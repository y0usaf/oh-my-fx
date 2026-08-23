//! OpenAI Responses API transport shared by platform OpenAI keys and Azure
//! OpenAI resources. Generalizes the Codex responses client over descriptor
//! auth styles (`bearer`, `azure_api_key`) and `{ENV}` endpoint templates.
const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const model_provider = @import("../core/config/model_provider.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const chat_completions = @import("chat_completions.zig");

const Allocator = std.mem.Allocator;
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

/// Per-stream resource bounds; tests shrink these to exercise the ceilings.
pub const ResponsesLimits = struct {
    aggregate_bytes: usize = max_sse_aggregate_bytes,
    events: usize = max_sse_events,
    tool_calls: usize = max_tool_calls,
    tool_identity_bytes: usize = max_tool_identity_bytes,
    tool_arguments_bytes: usize = max_tool_arguments_bytes,
    provider_state_bytes: usize = max_provider_state_bytes,
};

/// Builds the transport for one descriptor-driven Responses provider. The
/// descriptor is comptime-lifetime data, so borrowing it as the opaque
/// provider context is safe for the process lifetime.
pub fn providerFor(descriptor: *const model_provider.Descriptor) stream_provider.Provider {
    return .{
        .context = @constCast(descriptor),
        .observes_gateway_usage = descriptor.observes_gateway_usage,
        .build_fn = buildRequest,
        .stream_fn = streamCompletion,
    };
}

pub fn expectedCredentialSource(descriptor: *const model_provider.Descriptor) types.CredentialSource {
    return .{ .provider_api_key = descriptor.id };
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.InvalidOpenAIResponsesModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenAIResponsesModel;
    }
}

fn validateReplayMessage(message: types.ChatMessage, limits: ResponsesLimits) !void {
    if (message.provider_state_json) |state_json| {
        if (state_json.len > limits.provider_state_bytes) return error.OpenAIResponsesProviderStateTooLarge;
    }
    if (message.tool_calls.len > limits.tool_calls) return error.OpenAIResponsesToolCallLimitExceeded;
    for (message.tool_calls) |call| {
        if (call.id.len == 0 or call.id.len > limits.tool_identity_bytes or
            call.name.len == 0 or call.name.len > limits.tool_identity_bytes)
        {
            return error.OpenAIResponsesToolCallLimitExceeded;
        }
        if (call.arguments_json.len > limits.tool_arguments_bytes) {
            return error.OpenAIResponsesToolArgumentsTooLarge;
        }
    }
}

fn buildRequest(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"store\":false,\"stream\":true,\"input\":[");
    try writeInput(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');

    _ = try writeTools(writer, alloc, request.serialized_tools, request.selected_dynamic_tool_schemas);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);
    try writer.writeAll(",\"parallel_tool_calls\":true");

    // Reasoning effort opts into encrypted reasoning replay for stateless
    // multi-turn continuity; without it the parameter set stays minimal.
    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeAll(",\"summary\":\"auto\"}");
        try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    }

    if (request.provider_options.fast) try writer.writeAll(",\"service_tier\":\"priority\"");
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});

    if (request.response_format) |format| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
        try writer.writeAll(",\"strict\":true}}");
    }

    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeInput(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => {
                const text = message.content orelse continue;
                if (text.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"developer\",\"content\":");
                try std.json.Stringify.value(text, .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_part = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"input_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                };
                if (verified_images) |images| {
                    if (message_index == messages.len - 1) {
                        for (images) |image| {
                            if (!first_part) try writer.writeByte(',');
                            try writeInputImage(writer, alloc, image);
                            first_part = false;
                        }
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                try validateReplayMessage(message, .{});
                // Raw reasoning items captured from the terminal event replay
                // verbatim so `store:false` conversations keep their chain.
                if (message.provider_state_json) |state_json| {
                    var state = std.json.parseFromSlice(std.json.Value, alloc, state_json, .{}) catch
                        return error.InvalidOpenAIResponsesProviderState;
                    defer state.deinit();
                    if (state.value != .array) return error.InvalidOpenAIResponsesProviderState;
                    for (state.value.array.items) |item| {
                        if (item != .object) return error.InvalidOpenAIResponsesProviderState;
                        try writeComma(writer, &first);
                        try std.json.Stringify.value(item, .{}, writer);
                    }
                }
                if (message.content) |content| if (content.len > 0) {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeAll(",\"annotations\":[]}]}");
                };
                for (message.tool_calls) |call| {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeByte('}');
                }
            },
            .tool => {
                // Outputs are keyed by call_id alone, never by item id.
                try writeComma(writer, &first);
                try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"output\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeInputImage(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}");
}

/// Emits `"tools":[...]` in flat Responses layout (no nested `function:{}`).
fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    serialized_tools: []const u8,
    selected_dynamic_schemas: []const []const u8,
) !usize {
    var count: usize = 0;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolSchema;

    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();
    try tools_out.writer.writeAll(",\"tools\":[");
    for (parsed.value.array.items) |tool| {
        if (try writeFunctionTool(&tools_out.writer, tool, count != 0)) count += 1;
    }
    for (selected_dynamic_schemas) |schema_json| {
        var selected = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolSchema,
        };
        defer selected.deinit();
        if (try writeFunctionTool(&tools_out.writer, selected.value, count != 0)) count += 1;
    }
    try tools_out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(tools_out.written());
    return count;
}

fn writeFunctionTool(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const object = value.object;
    const kind = object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return false;
    const name = object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = object.get("inputSchema") orelse object.get("parameters") orelse return false;
    if (parameters != .object) return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeAll(",\"strict\":false}");
    return true;
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn streamCompletion(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    var result = streamCompletionCore(context, alloc, request) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (requestDeadlineExpired(request)) return error.Timeout;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return error.Timeout;
    }
    return result;
}

fn requestDeadlineExpired(request: stream_provider.Request) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

/// Header carrying the raw key when the style is not bearer. Azure authenticates
/// with its legacy `api-key` header; bearer credentials ride Authorization.
fn apiKeyHeaderName(style: model_provider.HeaderStyle) ?[]const u8 {
    return switch (style) {
        .bearer => null,
        .x_api_key => "x-api-key",
        .azure_api_key => "api-key",
    };
}

fn resolveResponsesUrl(alloc: Allocator, descriptor: *const model_provider.Descriptor) ![]u8 {
    var name_buf: [64]u8 = undefined;
    if (e2eEnvName(&name_buf, model_provider.providerSlug(descriptor.id), "_CHAT_URL")) |name| {
        if (io_mod.getenv(name)) |override| {
            if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenAIResponsesEndpoint;
            return alloc.dupe(u8, override);
        }
    }
    return chat_completions.resolveEndpointUrl(alloc, descriptor.base_url, "/responses");
}

fn e2eEnvName(buf: []u8, slug: []const u8, kind: []const u8) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll("FX_E2E_") catch return null;
    for (slug) |ch| {
        const mapped: u8 = switch (ch) {
            'a'...'z' => ch - 32,
            '-', '.' => '_',
            else => ch,
        };
        writer.writeByte(mapped) catch return null;
    }
    writer.writeAll(kind) catch return null;
    return writer.buffered();
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
    /// Set for bearer credentials; null suppresses Authorization entirely so
    /// header-style credentials never leak onto the default header.
    auth_header: ?[]const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (self.auth_header) |value|
                    std.http.Client.Request.Headers.Value{ .override = value }
                else
                    .omit,
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn streamCompletionCore(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source) |source| {
        if (!source.eql(.{ .provider_api_key = descriptor.id })) {
            return error.OpenAIResponsesCredentialRequired;
        }
    }
    try validateModel(request.model);

    var extra_headers_buf: [4]std.http.Header = undefined;
    var extra_count: usize = 0;
    var auth_header: ?[]u8 = null;
    errdefer if (auth_header) |value| secret.zeroAndFree(alloc, value);
    if (apiKeyHeaderName(descriptor.auth_header)) |name| {
        extra_headers_buf[extra_count] = .{ .name = name, .value = request.api_key };
        extra_count += 1;
    } else {
        auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    }
    extra_headers_buf[extra_count] = .{ .name = "accept", .value = "text/event-stream" };
    extra_count += 1;
    if (request.session_id) |session_id| if (session_id.len > 0) {
        extra_headers_buf[extra_count] = .{ .name = "session_id", .value = session_id };
        extra_count += 1;
        extra_headers_buf[extra_count] = .{ .name = "x-client-request-id", .value = session_id };
        extra_count += 1;
    };

    const request_endpoint = try resolveResponsesUrl(alloc, descriptor);
    defer alloc.free(request_endpoint);
    const uri = try std.Uri.parse(request_endpoint);

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

    http_request.transfer_encoding = .{ .content_length = request.payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(request.payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "provider error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "provider error response exceeded the local limit");
        } else bounded_body;
        return .{
            .status = response.head.status,
            .err_body = body,
            .ownership = .owned,
        };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const completion = try consumeSse(
        alloc,
        reader,
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.on_reasoning_chunk,
        request.on_tool_input_chunk,
        request.cancel_flag,
        request.content_capture_limit,
        .{},
    );
    return .{
        .status = .ok,
        .completion = completion,
        .ownership = .owned,
    };
}

const ToolAccumulator = struct {
    output_index: i64,
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            // Event type lives in the JSON payload; `event:` lines are noise.
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenAIResponsesSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenAIResponsesSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) return self.pending_line.items;
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.OpenAIResponsesSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) return fragment;
            try self.pending_line.appendSlice(alloc, fragment);
            return self.pending_line.items;
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
    limits: ResponsesLimits,
) anyerror!types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var provider_state: std.Io.Writer.Allocating = .init(alloc);
    defer provider_state.deinit();
    var provider_state_count: usize = 0;
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var terminal_seen = false;
    var saw_content_delta = false;
    var event_count: usize = 0;
    var aggregate_bytes: usize = 0;

    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        event_count = try checkedAccumulatedSize(event_count, 1, limits.events);
        aggregate_bytes = try checkedAccumulatedSize(aggregate_bytes, json_text.len, limits.aggregate_bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidOpenAIResponsesSseEvent;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event_type = stringField(parsed.value.object, "type") orelse continue;

        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const item = parsed.value.object.get("item") orelse continue;
            if (item != .object) continue;
            const item_type = stringField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, item_type, "function_call")) {
                const call_id = stringField(item.object, "call_id") orelse continue;
                const name = stringField(item.object, "name") orelse continue;
                if (findTool(tools.items, output_index) == null) {
                    try appendTool(alloc, &tools, output_index, call_id, name, limits);
                    if (on_tool_start) |callback| callback(callback_ctx, call_id, name, null);
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta") or
            std.mem.eql(u8, event_type, "response.refusal.delta"))
        {
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            saw_content_delta = true;
            on_content_chunk(callback_ctx, delta);
            try appendCaptured(alloc, &content, delta, content_capture_limit);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            if (on_reasoning_chunk) |callback| callback(callback_ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
            if (on_reasoning_chunk) |callback| callback(callback_ctx, "\n\n");
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            const index = findTool(tools.items, output_index) orelse continue;
            try appendToolArguments(alloc, &tools.items[index].arguments, delta, limits.tool_arguments_bytes);
            if (on_tool_input_chunk) |callback| callback(callback_ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            // The terminal arguments are authoritative; re-emit only whatever
            // extends what was already streamed so downstream sees one story.
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const arguments = stringField(parsed.value.object, "arguments") orelse continue;
            const index = findTool(tools.items, output_index) orelse continue;
            const previous_len = tools.items[index].arguments.items.len;
            if (std.mem.startsWith(u8, arguments, tools.items[index].arguments.items)) {
                const suffix = arguments[previous_len..];
                try appendToolArguments(alloc, &tools.items[index].arguments, suffix, limits.tool_arguments_bytes);
                if (suffix.len > 0) if (on_tool_input_chunk) |callback| callback(callback_ctx, suffix);
            } else {
                tools.items[index].arguments.clearRetainingCapacity();
                try appendToolArguments(alloc, &tools.items[index].arguments, arguments, limits.tool_arguments_bytes);
            }
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const item = parsed.value.object.get("item") orelse continue;
            if (item != .object) continue;
            const item_type = stringField(item.object, "type") orelse continue;
            if (std.mem.eql(u8, item_type, "function_call")) {
                if (findTool(tools.items, output_index)) |index| {
                    if (stringField(item.object, "arguments")) |arguments| {
                        if (tools.items[index].arguments.items.len == 0) {
                            try appendToolArguments(alloc, &tools.items[index].arguments, arguments, limits.tool_arguments_bytes);
                        }
                    }
                }
            } else if (std.mem.eql(u8, item_type, "reasoning") and
                stringField(item.object, "encrypted_content") != null)
            {
                var encoded: std.Io.Writer.Allocating = .init(alloc);
                defer encoded.deinit();
                try std.json.Stringify.value(item, .{}, &encoded.writer);
                const framed_size = try checkedAccumulatedSize(encoded.written().len, 2, limits.provider_state_bytes);
                _ = try checkedAccumulatedSize(provider_state.written().len, framed_size, limits.provider_state_bytes);
                if (provider_state_count == 0) {
                    try provider_state.writer.writeByte('[');
                } else {
                    try provider_state.writer.writeByte(',');
                }
                try provider_state.writer.writeAll(encoded.written());
                provider_state_count += 1;
            } else if (std.mem.eql(u8, item_type, "message") and !saw_content_delta) {
                if (item.object.get("content")) |parts| if (parts == .array) {
                    for (parts.array.items) |part| {
                        if (part != .object) continue;
                        const text = stringField(part.object, "text") orelse stringField(part.object, "refusal") orelse continue;
                        on_content_chunk(callback_ctx, text);
                        try appendCaptured(alloc, &content, text, content_capture_limit);
                    }
                };
            }
        } else if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.done") or
            std.mem.eql(u8, event_type, "response.incomplete"))
        {
            const response_value = parsed.value.object.get("response") orelse continue;
            if (response_value != .object) continue;
            terminal_seen = true;
            const status = stringField(response_value.object, "status");
            finish_reason = finishReason(status, response_value.object, tools.items.len > 0);
            usage = parseUsage(response_value.object);
            if (stringField(response_value.object, "id")) |id| {
                generation_id = try alloc.dupe(u8, id);
            }
            break;
        } else if (std.mem.eql(u8, event_type, "response.failed") or
            std.mem.eql(u8, event_type, "error"))
        {
            return error.OpenAIResponsesResponseFailed;
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!terminal_seen) return error.OpenAIResponsesStreamIncomplete;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_provider_state = if (provider_state_count > 0) state: {
        try provider_state.writer.writeByte(']');
        break :state try provider_state.toOwnedSlice();
    } else null;
    errdefer if (owned_provider_state) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = if (tools.items.len > 0)
        try alloc.alloc(types.ToolCall, tools.items.len)
    else
        &.{};
    errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
    var initialized: usize = 0;
    errdefer for (owned_tools[0..initialized]) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
    };
    for (tools.items, 0..) |*tool, index| {
        const arguments = if (tool.arguments.items.len > 0)
            try tool.arguments.toOwnedSlice(alloc)
        else
            try alloc.dupe(u8, "{}");
        tool.arguments = .empty;
        owned_tools[index] = .{
            .id = tool.id,
            .name = tool.name,
            .arguments_json = arguments,
        };
        tool.id = &.{};
        tool.name = &.{};
        initialized += 1;
    }
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .provider_state_json = owned_provider_state,
        .finish_reason = finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
        .usage = usage,
    };
}

fn appendTool(
    alloc: Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    output_index: i64,
    call_id: []const u8,
    name: []const u8,
    limits: ResponsesLimits,
) !void {
    if (tools.items.len >= limits.tool_calls or call_id.len == 0 or call_id.len > limits.tool_identity_bytes or
        name.len == 0 or name.len > limits.tool_identity_bytes)
    {
        return error.OpenAIResponsesToolCallLimitExceeded;
    }
    const id = try alloc.dupe(u8, call_id);
    errdefer alloc.free(id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try tools.append(alloc, .{
        .output_index = output_index,
        .id = id,
        .name = owned_name,
    });
}

fn appendToolArguments(
    alloc: Allocator,
    arguments: *std.ArrayList(u8),
    delta: []const u8,
    maximum: usize,
) !void {
    _ = checkedAccumulatedSize(arguments.items.len, delta.len, maximum) catch
        return error.OpenAIResponsesToolArgumentsTooLarge;
    try arguments.appendSlice(alloc, delta);
}

fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.OpenAIResponsesResourceLimitExceeded;
    if (next > maximum) return error.OpenAIResponsesResourceLimitExceeded;
    return next;
}

fn appendCaptured(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    limit: ?usize,
) !void {
    const remaining = if (limit) |maximum| maximum -| @min(maximum, content.items.len) else delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn findTool(tools: []const ToolAccumulator, output_index: i64) ?usize {
    for (tools, 0..) |tool, index| if (tool.output_index == output_index) return index;
    return null;
}

fn finishReason(
    status: ?[]const u8,
    response: std.json.ObjectMap,
    has_tools: bool,
) types.ProviderFinishReason {
    const value = status orelse return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, value, "completed")) return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, value, "incomplete")) {
        if (response.get("incomplete_details")) |details| if (details == .object) {
            if (stringField(details.object, "reason")) |reason| {
                if (std.mem.eql(u8, reason, "max_output_tokens")) return .length;
                if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
            }
        };
        return .provider_error;
    }
    if (std.mem.eql(u8, value, "failed") or std.mem.eql(u8, value, "cancelled")) return .provider_error;
    return if (has_tools) .tool_calls else .other;
}

fn parseUsage(response: std.json.ObjectMap) types.Usage {
    const value = response.get("usage") orelse return .{};
    if (value != .object) return .{};
    // Reasoning tokens are a subset of output_tokens on the wire, so keeping
    // the raw totals folds them into Usage.output_tokens.
    return .{
        .input_tokens = unsignedField(value.object, "input_tokens"),
        .output_tokens = unsignedField(value.object, "output_tokens"),
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = integerField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

test "platform requests put system prompts in developer input items with strict tools" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
    };
    const body = try providerFor(model_provider.ProviderId.openai.descriptor()).build(std.testing.allocator, .{
        .model = "gpt-5.4",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high"), .fast = true },
        .max_output_tokens = 4096,
        .response_format = .{
            .name = "result",
            .description = "Structured result",
            .schema_json = "{\"type\":\"object\"}",
        },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Read it.\"}]}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\"},\"strict\":false}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"auto\",\"parallel_tool_calls\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":{\"effort\":\"high\",\"summary\":\"auto\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"include\":[\"reasoning.encrypted_content\"]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\":\"priority\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\":4096") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"result\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"strict\":true}}") != null);
}

test "minimal requests omit reasoning include and structured output" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Hello." }};
    const body = try providerFor(model_provider.ProviderId.openai.descriptor()).build(std.testing.allocator, .{
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"include\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"format\"") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\"") == null);
}

test "prior-turn history replays function calls and outputs keyed by call id" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be concise." },
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .content = "Reading now.",
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
            .provider_state_json = "[{\"id\":\"rs_1\",\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}]",
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try providerFor(model_provider.ProviderId.openai.descriptor()).build(std.testing.allocator, .{
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "{\"id\":\"rs_1\",\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"contents\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "item_id") == null);
}

test "serializes each verified image directly once" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try providerFor(model_provider.ProviderId.openai.descriptor()).build(std.testing.allocator, .{
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
        .verified_images = &images,
    });
    defer std.testing.allocator.free(body);

    const marker = "\"type\":\"input_image\"";
    const first = std.mem.find(u8, body, marker) orelse return error.TestExpectedImage;
    try std.testing.expect(std.mem.findPos(u8, body, first + marker.len, marker) == null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
}

test "azure resources target /responses under the api-key header style" {
    const alloc = std.testing.allocator;
    const azure_descriptor = model_provider.Descriptor{
        .id = .azure_openai,
        .label = "Azure OpenAI",
        .protocol = .openai_responses,
        .auth = .{ .env_api_key = &.{} },
        .auth_header = .azure_api_key,
        .base_url = "https://my-resource.openai.azure.com/openai/v1",
        .default_model = "gpt-5.4",
    };
    try std.testing.expectEqualStrings("api-key", apiKeyHeaderName(azure_descriptor.auth_header).?);
    try std.testing.expect(apiKeyHeaderName(model_provider.ProviderId.openai.descriptor().auth_header) == null);

    const url = try resolveResponsesUrl(alloc, &azure_descriptor);
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://my-resource.openai.azure.com/openai/v1/responses", url);

    const platform_descriptor = model_provider.ProviderId.openai.descriptor();
    try std.testing.expect(std.mem.endsWith(u8, platform_descriptor.base_url, "/v1"));
    const platform_url = try chat_completions.resolveEndpointUrl(alloc, platform_descriptor.base_url, "/responses");
    defer alloc.free(platform_url);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", platform_url);
}

test "e2e env names derive uppercase slugs" {
    var buf: [64]u8 = undefined;
    const name = e2eEnvName(&buf, "azure-openai", "_CHAT_URL").?;
    try std.testing.expectEqualStrings("FX_E2E_AZURE_OPENAI_CHAT_URL", name);
}

test "SSE accumulates function call deltas and folds terminal usage" {
    const sse_text =
        "event: response.created\n" ++
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_abc\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"message\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"output_index\":1,\"delta\":\"hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":2,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":2,\"delta\":\"{\\\"path\\\":\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":2,\"delta\":\"\\\"README.md\\\"\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":2,\"arguments\":\"{\\\"path\\\":\\\"README.md\\\",\\\"depth\\\":2}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"opaque\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_abc\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"total_tokens\":14,\"output_tokens_details\":{\"reasoning_tokens\":1}}}}\n\n";
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        tool_input: std.ArrayList(u8) = .empty,
        saw_read_file: bool = false,

        fn contentChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolInputChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_input.appendSlice(std.testing.allocator, chunk) catch unreachable;
        }
        fn toolStart(raw: *anyopaque, _: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.saw_read_file = std.mem.eql(u8, name, "read_file");
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    defer capture.tool_input.deinit(std.testing.allocator);
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        &capture,
        Capture.contentChunk,
        Capture.toolStart,
        null,
        Capture.toolInputChunk,
        &cancelled,
        null,
        .{},
    );
    defer {
        if (completion.content) |value| std.testing.allocator.free(@constCast(value));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
        if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
        if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
    }
    try std.testing.expectEqualStrings("hello", capture.content.items);
    try std.testing.expect(capture.saw_read_file);
    // Streamed deltas plus the done-event remainder surface exactly once.
    try std.testing.expectEqualStrings("{\"path\":\"README.md\",\"depth\":2}", capture.tool_input.items);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\",\"depth\":2}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings(types.ProviderFinishReason.tool_calls.label(), completion.finish_reason.?.label());
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 4), completion.usage.output_tokens);
    try std.testing.expectEqualStrings("resp_abc", completion.generation_id.?);
    try std.testing.expect(std.mem.find(u8, completion.provider_state_json.?, "\"encrypted_content\":\"opaque\"") != null);
}

fn consumeResponsesTestSse(sse_text: []const u8, limits: ResponsesLimits) !types.GatewayCompletion {
    var reader: std.Io.Reader = .fixed(sse_text);
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    return consumeSse(
        std.testing.allocator,
        &reader,
        &callback_context,
        struct {
            fn ignore(_: *anyopaque, _: []const u8) void {}
        }.ignore,
        null,
        null,
        null,
        &cancelled,
        null,
        limits,
    );
}

fn freeResponsesTestCompletion(completion: types.GatewayCompletion) void {
    if (completion.content) |value| std.testing.allocator.free(@constCast(value));
    types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    if (completion.generation_id) |value| std.testing.allocator.free(@constCast(value));
    if (completion.provider_state_json) |value| std.testing.allocator.free(@constCast(value));
}

test "SSE rejects failure events and unterminated streams" {
    try expectResponsesSseError(
        error.OpenAIResponsesResponseFailed,
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}\n\n",
        .{},
    );
    try expectResponsesSseError(
        error.OpenAIResponsesResponseFailed,
        "data: {\"type\":\"error\",\"code\":\"invalid_request\",\"message\":\"bad\"}\n\n",
        .{},
    );
    try expectResponsesSseError(
        error.OpenAIResponsesStreamIncomplete,
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\"}}\n\n",
        .{},
    );
    try expectResponsesSseError(
        error.InvalidOpenAIResponsesSseEvent,
        "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"oops\"}\n\ndata: {not json}\n\n",
        .{},
    );
}

fn expectResponsesSseError(expected: anyerror, sse_text: []const u8, limits: ResponsesLimits) !void {
    const result = consumeResponsesTestSse(sse_text, limits);
    if (result) |completion| {
        freeResponsesTestCompletion(completion);
        return error.TestExpectedResponsesSseError;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

test "wrong-origin credentials are rejected before network I/O" {
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = stream_provider.DeliveryCertainty.init();
    var evidence: stream_provider.AttemptEvidence = .{};
    var callback_context: u8 = 0;
    try std.testing.expectError(
        error.OpenAIResponsesCredentialRequired,
        providerFor(model_provider.ProviderId.azure_openai.descriptor()).stream(std.testing.allocator, .{
            .api_key = "gateway-key",
            .credential_source = .ai_gateway_api_key,
            .team = null,
            .model = "gpt-5.4",
            .retry_count = 1,
            .chat_url = "",
            .payload = "{}",
            .trace_ctx = .{},
            .content_capture_limit = null,
            .delivery = &delivery,
            .attempt_evidence = &evidence,
            .callback_ctx = @ptrCast(&callback_context),
            .on_content_chunk = struct {
                fn ignore(_: *anyopaque, _: []const u8) void {}
            }.ignore,
            .on_tool_start = null,
            .on_reasoning_chunk = null,
            .cancel_flag = &cancelled,
        }),
    );
    try std.testing.expectEqual(stream_provider.DeliveryCertainty.State.definitely_unsent, delivery.load());
}
