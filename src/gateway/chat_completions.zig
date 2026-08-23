const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const io_mod = @import("../core/shared/io.zig");
const model_provider = @import("../core/config/model_provider.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

/// Builds the transport for one descriptor-driven OpenAI-compatible provider.
/// The descriptor is comptime-lifetime data, so borrowing it as the opaque
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
    if (model.len == 0 or model.len > 256) return error.InvalidChatCompletionsModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidChatCompletionsModel;
    }
}

/// Substitutes `{ENV}` segments from the environment and appends `suffix`.
/// Missing variables surface as a loud error instead of a malformed URL.
pub fn resolveEndpointUrl(
    alloc: Allocator,
    base_template: []const u8,
    suffix: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = base_template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return error.MalformedProviderBaseUrl;
        try out.appendSlice(alloc, rest[0..open]);
        const name = rest[open + 1 .. close];
        const value = io_mod.getenv(name) orelse return error.ProviderEndpointVariableUnset;
        try out.appendSlice(alloc, value);
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(alloc, rest);
    try out.appendSlice(alloc, suffix);
    return out.toOwnedSlice(alloc);
}

fn buildRequest(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    _ = context;
    try validateModel(request.model);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");

    try writeMessages(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');

    _ = try writeTools(
        writer,
        alloc,
        request.serialized_tools,
        request.selected_dynamic_tool_schemas,
        request.tool_registry,
        request.vision_mode,
    );
    const tool_choice: types.ToolChoice = if (request.vision_mode == .required)
        .required
    else
        request.tool_choice;
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(tool_choice.label(), .{}, writer);
    if (request.provider_options.reasoning) |*effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
        try writer.writeByte('}');
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    if (request.response_format) |format| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
        try writer.writeAll(",\"strict\":true}}}");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeMessages(
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
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(text, .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                const text = message.content orelse "";
                const attach_images = verified_images != null and message_index == messages.len - 1;
                try writeComma(writer, &first);
                if (!attach_images) {
                    try writer.writeAll("{\"role\":\"user\",\"content\":");
                    try std.json.Stringify.value(text, .{}, writer);
                    try writer.writeByte('}');
                    continue;
                }
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_part = true;
                if (text.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(text, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                }
                for (verified_images.?) |image| {
                    if (!first_part) try writer.writeByte(',');
                    try writeImagePart(writer, alloc, image);
                    first_part = false;
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                const has_content = message.content != null and message.content.?.len > 0;
                if (!has_content and message.tool_calls.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\"");
                if (has_content) {
                    try writer.writeAll(",\"content\":");
                    try std.json.Stringify.value(message.content.?, .{}, writer);
                }
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    var first_call = true;
                    for (message.tool_calls) |call| {
                        if (call.id.len == 0 or call.id.len > max_tool_identity_bytes or
                            call.name.len == 0 or call.name.len > max_tool_identity_bytes or
                            call.arguments_json.len > max_tool_arguments_bytes)
                        {
                            return error.ChatCompletionsToolCallLimitExceeded;
                        }
                        if (!first_call) try writer.writeByte(',');
                        first_call = false;
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(call.arguments_json, .{}, writer);
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeImagePart(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}");
}

/// Emits `"tools":[...]` in OpenAI chat-completions shape. Inputs arrive as the
/// shared gateway function envelope (`{type,name,description,inputSchema}`);
/// each entry is converted, not rebuilt, so one schema source feeds every
/// provider.
fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    serialized_tools: []const u8,
    selected_dynamic_schemas: []const []const u8,
    registry: tool_dispatch.Registry,
    vision_mode: stream_provider.VisionMode,
) !usize {
    const gateway_schema = @import("../core/tooling/gateway_schema.zig");

    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(alloc);
    try combined.appendSlice(alloc, "[");

    if (vision_mode == .required) {
        const vision_tool = registry.lookup("vision") orelse return error.VisionToolNotRegistered;
        const vision_json = try gateway_schema.builtinFunctionSchemaJsonAlloc(alloc, vision_tool.gateway_schema);
        defer alloc.free(vision_json);
        try combined.appendSlice(alloc, vision_json);
    } else {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToolSchema,
        };
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidToolSchema;
        for (parsed.value.array.items, 0..) |tool, index| {
            if (index > 0) try combined.appendSlice(alloc, ",");
            var rendered: std.Io.Writer.Allocating = .init(alloc);
            defer rendered.deinit();
            try std.json.Stringify.value(tool, .{}, &rendered.writer);
            try combined.appendSlice(alloc, rendered.written());
        }
        for (selected_dynamic_schemas) |schema_json| {
            if (combined.items.len > 1) try combined.appendSlice(alloc, ",");
            try combined.appendSlice(alloc, schema_json);
        }
    }
    try combined.appendSlice(alloc, "]");

    var converted: std.Io.Writer.Allocating = .init(alloc);
    defer converted.deinit();
    const converted_writer = &converted.writer;
    var parsed_combined = std.json.parseFromSlice(std.json.Value, alloc, combined.items, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    defer parsed_combined.deinit();

    var count: usize = 0;
    try converted_writer.writeAll(",\"tools\":[");
    for (parsed_combined.value.array.items) |value| {
        if (try convertFunctionTool(converted_writer, value, count != 0)) count += 1;
    }
    try converted_writer.writeByte(']');
    if (count > 0) try writer.writeAll(converted.written());
    return count;
}

fn convertFunctionTool(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const object = value.object;
    const kind = object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return false;
    const name = object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = object.get("inputSchema") orelse object.get("parameters") orelse return false;
    if (parameters != .object) return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeAll("}}");
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

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = self.auth_header },
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = &.{
                .{ .name = "accept", .value = "text/event-stream" },
            },
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn resolveChatUrl(alloc: Allocator, descriptor: *const model_provider.Descriptor) ![]u8 {
    const e2e_override = e2eChatUrlEnvValue(descriptor);
    if (e2e_override) |override| {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EChatCompletionsEndpoint;
        return alloc.dupe(u8, override);
    }
    return resolveEndpointUrl(alloc, descriptor.base_url, "/chat/completions");
}

fn e2eChatUrlEnvValue(descriptor: *const model_provider.Descriptor) ?[]const u8 {
    var name_buf: [64]u8 = undefined;
    const name = e2eEnvName(&name_buf, model_provider.providerSlug(descriptor.id), "_CHAT_URL") orelse return null;
    return io_mod.getenv(name);
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

fn streamCompletionCore(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source) |source| {
        const expected: types.CredentialSource = .{ .provider_api_key = descriptor.id };
        if (!source.eql(expected)) return error.ChatCompletionsCredentialRequired;
    }
    try validateModel(request.model);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer secret.zeroAndFree(alloc, auth_header);
    const request_endpoint = try resolveChatUrl(alloc, descriptor);
    defer alloc.free(request_endpoint);
    const uri = try std.Uri.parse(request_endpoint);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
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
    );
    return .{
        .status = .ok,
        .completion = completion,
        .ownership = .owned,
    };
}

const ToolAccumulator = struct {
    index: i64,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

fn finishReasonFromWire(raw: []const u8) ?types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length")) return .length;
    if (std.mem.eql(u8, raw, "tool_calls") or std.mem.eql(u8, raw, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    return null;
}

fn checkedAccumulatedSize(current: usize, added: usize, limit: usize) !usize {
    const sum = std.math.add(usize, current, added) catch return error.ChatCompletionsSseEventTooLarge;
    if (sum > limit) return error.ChatCompletionsSseEventTooLarge;
    return sum;
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
            self.aggregate_bytes = try checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            );
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            // Providers emit keep-alive comment lines such as
            // ": OPENROUTER PROCESSING" between data events.
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
                    if (buffered.len == 0) return error.ChatCompletionsSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.ChatCompletionsSseEventTooLarge;
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
                return error.ChatCompletionsSseEventTooLarge;
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
) anyerror!types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var sse: SseReader = .{};
    defer sse.deinit(alloc);

    var finish_reason: ?types.ProviderFinishReason = null;
    var usage = types.Usage{};

    while (try sse.next(alloc, reader)) |data| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch
            return error.InvalidChatCompletionsStreamEvent;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidChatCompletionsStreamEvent;

        if (parsed.value.object.get("choices")) |choices_value| {
            if (choices_value == .array) {
                for (choices_value.array.items) |choice| {
                    if (choice != .object) continue;
                    try consumeChoice(
                        alloc,
                        choice.object,
                        &content,
                        content_capture_limit,
                        callback_ctx,
                        on_content_chunk,
                        on_reasoning_chunk,
                        on_tool_input_chunk,
                        on_tool_start,
                        &tools,
                        &finish_reason,
                    );
                }
            }
        }
        if (parsed.value.object.get("usage")) |usage_value| {
            if (usage_value == .object) {
                usage = usageFromWire(usage_value.object, usage);
            }
        }
    }

    const captured_content: ?[]const u8 = if (content.items.len > 0)
        try content.toOwnedSlice(alloc)
    else
        null;
    errdefer if (captured_content) |value| alloc.free(@constCast(value));
    const tool_calls = try materializeToolCalls(alloc, tools.items);
    errdefer types.freeToolCallSlice(alloc, tool_calls);
    return .{
        .content = captured_content,
        .tool_calls = tool_calls,
        .finish_reason = finish_reason,
        .usage = usage,
    };
}

fn usageFromWire(object: std.json.ObjectMap, base: types.Usage) types.Usage {
    var result = base;
    if (object.get("prompt_tokens")) |value| {
        if (value == .integer and value.integer >= 0) result.input_tokens = @intCast(value.integer);
    }
    if (object.get("completion_tokens")) |value| {
        if (value == .integer and value.integer >= 0) result.output_tokens = @intCast(value.integer);
    }
    return result;
}

fn consumeChoice(
    alloc: Allocator,
    object: std.json.ObjectMap,
    content: *std.ArrayList(u8),
    content_capture_limit: ?usize,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    tools: *std.ArrayList(ToolAccumulator),
    finish_reason: *?types.ProviderFinishReason,
) !void {
    if (object.get("delta")) |delta_value| {
        if (delta_value == .object) {
            const delta = delta_value.object;
            if (delta.get("content")) |chunk| {
                if (chunk == .string and chunk.string.len > 0) {
                    on_content_chunk(callback_ctx, chunk.string);
                    if (content_capture_limit == null or content.items.len < content_capture_limit.?) {
                        const accepted = if (content_capture_limit) |limit|
                            chunk.string[0..@min(chunk.string.len, limit -| content.items.len)]
                        else
                            chunk.string;
                        try content.appendSlice(alloc, accepted);
                    }
                }
            }
            if (on_reasoning_chunk) |callback| {
                for ([_][]const u8{ "reasoning", "reasoning_content" }) |key| {
                    if (delta.get(key)) |chunk| {
                        if (chunk == .string and chunk.string.len > 0) {
                            callback(callback_ctx, chunk.string);
                        }
                    }
                }
            }
            if (delta.get("tool_calls")) |calls_value| {
                if (calls_value == .array) {
                    for (calls_value.array.items) |call_value| {
                        if (call_value != .object) continue;
                        try accumulateToolCallDelta(
                            alloc,
                            call_value.object,
                            tools,
                            callback_ctx,
                            on_tool_start,
                            on_tool_input_chunk,
                        );
                    }
                }
            }
        }
    }
    if (object.get("finish_reason")) |finish_value| {
        if (finish_value == .string) {
            if (finishReasonFromWire(finish_value.string)) |reason| {
                if (finish_reason.* == null) finish_reason.* = reason;
            }
        }
    }
}

fn accumulateToolCallDelta(
    alloc: Allocator,
    object: std.json.ObjectMap,
    tools: *std.ArrayList(ToolAccumulator),
    callback_ctx: *anyopaque,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
) !void {
    const index: i64 = blk: {
        if (object.get("index")) |value| {
            if (value == .integer and value.integer >= 0) break :blk value.integer;
        }
        break :blk @intCast(tools.items.len);
    };

    var target: ?*ToolAccumulator = null;
    for (tools.items) |*tool| {
        if (tool.index == index) target = tool;
    }
    if (target == null) {
        if (tools.items.len >= max_tool_calls) return error.ChatCompletionsToolCallLimitExceeded;
        try tools.append(alloc, .{ .index = index });
        target = &tools.items[tools.items.len - 1];
    }
    const tool = target.?;

    if (optionalString(object.get("id"))) |id| {
        if (id.len > 0 and id.len <= max_tool_identity_bytes and
            !std.mem.eql(u8, tool.id.items, id))
        {
            tool.id.clearRetainingCapacity();
            try tool.id.appendSlice(alloc, id);
        }
    }
    if (deltaFunctionObject(object)) |function| {
        if (optionalString(function.get("name"))) |name| {
            if (name.len > 0 and name.len <= max_tool_identity_bytes and
                !std.mem.eql(u8, tool.name.items, name))
            {
                tool.name.clearRetainingCapacity();
                try tool.name.appendSlice(alloc, name);
            }
        }
        if (optionalString(function.get("arguments"))) |arguments| {
            if (arguments.len > 0) {
                const projected = tool.arguments.items.len + arguments.len;
                if (projected > max_tool_arguments_bytes) return error.ChatCompletionsToolArgumentsTooLarge;
                try tool.arguments.appendSlice(alloc, arguments);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, arguments);
            }
        }
    }

    if (!tool.announced and tool.id.items.len > 0 and tool.name.items.len > 0) {
        if (on_tool_start) |callback| callback(callback_ctx, tool.id.items, tool.name.items, null);
        tool.announced = true;
    }
}

fn deltaFunctionObject(object: std.json.ObjectMap) ?std.json.ObjectMap {
    const value = object.get("function") orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const unwrapped = value orelse return null;
    if (unwrapped != .string) return null;
    return unwrapped.string;
}

fn materializeToolCalls(
    alloc: Allocator,
    accumulators: []const ToolAccumulator,
) ![]const types.ToolCall {
    var calls: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (calls.items) |call| types.freeToolCall(alloc, call);
        calls.deinit(alloc);
    }
    for (accumulators) |*accumulator| {
        if (accumulator.id.items.len == 0 or accumulator.name.items.len == 0) continue;
        try calls.append(alloc, .{
            .id = try alloc.dupe(u8, accumulator.id.items),
            .name = try alloc.dupe(u8, accumulator.name.items),
            .arguments_json = try alloc.dupe(u8, accumulator.arguments.items),
        });
    }
    return calls.toOwnedSlice(alloc);
}

test "endpoint resolution substitutes environment templates" {
    const alloc = std.testing.allocator;
    const direct = try resolveEndpointUrl(alloc, "https://api.example.com/v1", "/chat/completions");
    defer alloc.free(direct);
    try std.testing.expectEqualStrings("https://api.example.com/v1/chat/completions", direct);
    try std.testing.expectError(
        error.ProviderEndpointVariableUnset,
        resolveEndpointUrl(alloc, "https://x/{MISSING_VAR_TEST}/y", ""),
    );
}

test "e2e env names derive uppercase slugs" {
    var buf: [64]u8 = undefined;
    const name = e2eEnvName(&buf, "google-vertex", "_CHAT_URL").?;
    try std.testing.expectEqualStrings("FX_E2E_GOOGLE_VERTEX_CHAT_URL", name);
}
