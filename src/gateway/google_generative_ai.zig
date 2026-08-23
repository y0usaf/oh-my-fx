const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
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

/// Builds the transport for one descriptor-driven Google Generative Language
/// provider (Gemini API and Vertex AI share the wire protocol). The descriptor
/// is comptime-lifetime data, so borrowing it as the opaque provider context is
/// safe for the process lifetime.
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
    if (model.len == 0 or model.len > 256) return error.InvalidGoogleGenerativeAiModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidGoogleGenerativeAiModel;
    }
    if (std.mem.indexOf(u8, model, "..") != null or
        std.mem.indexOfAny(u8, model, "?&") != null) return error.InvalidGoogleGenerativeAiModel;
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

/// `{base}/models/{model}:streamGenerateContent?alt=sse`. Bare model ids gain
/// the `models/` collection prefix; values already carrying a collection are
/// passed through unchanged, matching the official SDK's substitution rule.
pub fn endpointUrl(alloc: Allocator, base_template: []const u8, model: []const u8) ![]u8 {
    try validateModel(model);
    const prefixed: []const u8 = if (std.mem.startsWith(u8, model, "models/") or
        std.mem.startsWith(u8, model, "tunedModels/"))
        model
    else
        try std.fmt.allocPrint(alloc, "models/{s}", .{model});
    defer if (prefixed.ptr != model.ptr) alloc.free(prefixed);
    const suffix = try std.fmt.allocPrint(alloc, "/{s}:streamGenerateContent?alt=sse", .{prefixed});
    defer alloc.free(suffix);
    return resolveEndpointUrl(alloc, base_template, suffix);
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

    try writer.writeAll("{\"contents\":[");
    try writeContents(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');
    try writeSystemInstruction(writer, request.messages);
    _ = try writeTools(writer, alloc, request);
    try writeGenerationConfig(writer, alloc, request);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Emits `contents[]`: user/model turns with text, inlineData images on the
/// trailing user turn, functionCall replay on assistant turns, and consecutive
/// tool results merged into one `role:"user"` functionResponse turn.
fn writeContents(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    var open_tool_turn = false;
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => continue,
            .user => {
                const text = message.content orelse "";
                const attach_images = verified_images != null and message_index == messages.len - 1;
                const has_text = text.len > 0;
                if (!has_text and !attach_images) continue;
                try closeToolTurn(writer, &open_tool_turn);
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"parts\":[");
                var first_part = true;
                if (has_text) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(text, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                }
                if (attach_images) {
                    for (verified_images.?) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeImagePart(writer, alloc, image);
                        first_part = false;
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                const has_content = message.content != null and message.content.?.len > 0;
                if (!has_content and message.tool_calls.len == 0) continue;
                try closeToolTurn(writer, &open_tool_turn);
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"model\",\"parts\":[");
                var first_part = true;
                if (has_content) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(message.content.?, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                }
                for (message.tool_calls) |call| {
                    if (!first_part) try writer.writeByte(',');
                    try writeFunctionCallPart(writer, alloc, call);
                    first_part = false;
                }
                try writer.writeAll("]}");
            },
            .tool => {
                const name = resolveToolName(messages, message_index) orelse continue;
                const response = message.content orelse "";
                if (!open_tool_turn) {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"role\":\"user\",\"parts\":[");
                    open_tool_turn = true;
                } else {
                    try writer.writeByte(',');
                }
                try writer.writeAll("{\"functionResponse\":{\"name\":");
                try std.json.Stringify.value(name, .{}, writer);
                try writer.writeAll(",\"response\":{\"output\":");
                try std.json.Stringify.value(response, .{}, writer);
                try writer.writeAll("}}}");
            },
        }
    }
    try closeToolTurn(writer, &open_tool_turn);
}

fn closeToolTurn(writer: *std.Io.Writer, open: *bool) !void {
    if (!open.*) return;
    try writer.writeAll("]}");
    open.* = false;
}

/// Function responses are matched by name on the wire, so the call id is
/// resolved against earlier assistant turns; `tool_name` covers orphaned
/// results whose assistant turn was dropped. Unresolvable results are skipped
/// because a functionResponse without a name is rejected by the API.
fn resolveToolName(messages: []const types.ChatMessage, tool_index: usize) ?[]const u8 {
    const message = messages[tool_index];
    if (message.tool_call_id) |id| {
        var scan = tool_index;
        while (scan > 0) {
            scan -= 1;
            for (messages[scan].tool_calls) |call| {
                if (std.mem.eql(u8, call.id, id)) return call.name;
            }
            if (messages[scan].role != .assistant and messages[scan].role != .tool) break;
        }
    }
    if (message.tool_name) |name| {
        if (name.len > 0) return name;
    }
    return null;
}

fn writeImagePart(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"inlineData\":{\"mimeType\":");
    try std.json.Stringify.value(image.media_type, .{}, writer);
    try writer.writeAll(",\"data\":");
    try std.json.Stringify.value(encoded, .{}, writer);
    try writer.writeAll("}}");
}

fn writeFunctionCallPart(writer: *std.Io.Writer, alloc: Allocator, call: types.ToolCall) !void {
    if (call.name.len == 0 or call.name.len > max_tool_identity_bytes) {
        return error.GoogleGenerativeAiToolIdentityInvalid;
    }
    if (call.arguments_json.len > max_tool_arguments_bytes) {
        return error.GoogleGenerativeAiToolArgumentsTooLarge;
    }
    try writer.writeAll("{\"functionCall\":{\"name\":");
    try std.json.Stringify.value(call.name, .{}, writer);
    try writer.writeAll(",\"args\":");
    var normalized: bool = false;
    if (call.arguments_json.len > 0) {
        const parsed: ?std.json.Parsed(std.json.Value) =
            std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        if (parsed) |*document| {
            defer document.deinit();
            if (document.value == .object) {
                try std.json.Stringify.value(document.value, .{}, writer);
                normalized = true;
            }
        }
    }
    if (!normalized) try writer.writeAll("{}");
    try writer.writeAll("}}");
}

fn writeSystemInstruction(writer: *std.Io.Writer, messages: []const types.ChatMessage) !void {
    var any = false;
    for (messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (!any) try writer.writeAll(",\"systemInstruction\":{\"parts\":[");
        if (any) try writer.writeByte(',');
        try writer.writeAll("{\"text\":");
        try std.json.Stringify.value(text, .{}, writer);
        try writer.writeByte('}');
        any = true;
    }
    if (any) try writer.writeAll("]}");
}

/// Emits `"tools":[{"functionDeclarations":[...]}]"` plus `"toolConfig"` in
/// Gemini shape. Inputs arrive as the shared gateway function envelope
/// (`{type,name,description,inputSchema}`); each entry is converted, not
/// rebuilt, and every declaration lives inside ONE wrapper object. JSON Schema
/// dialects pass through verbatim under `parametersJsonSchema`.
fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) !usize {
    const gateway_schema = @import("../core/tooling/gateway_schema.zig");

    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(alloc);
    try combined.appendSlice(alloc, "[");

    if (request.vision_mode == .required) {
        const vision_tool = request.tool_registry.lookup("vision") orelse return error.VisionToolNotRegistered;
        const vision_json = try gateway_schema.builtinFunctionSchemaJsonAlloc(alloc, vision_tool.gateway_schema);
        defer alloc.free(vision_json);
        try combined.appendSlice(alloc, vision_json);
    } else {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, request.serialized_tools, .{}) catch |err| switch (err) {
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
        for (request.selected_dynamic_tool_schemas) |schema_json| {
            if (combined.items.len > 1) try combined.appendSlice(alloc, ",");
            try combined.appendSlice(alloc, schema_json);
        }
    }
    try combined.appendSlice(alloc, "]");

    var parsed_combined = std.json.parseFromSlice(std.json.Value, alloc, combined.items, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    defer parsed_combined.deinit();

    var converted: std.Io.Writer.Allocating = .init(alloc);
    defer converted.deinit();
    const converted_writer = &converted.writer;
    var count: usize = 0;
    for (parsed_combined.value.array.items) |value| {
        if (try convertFunctionDeclaration(converted_writer, value, count != 0)) count += 1;
    }
    if (count == 0) return 0;
    try writer.writeAll(",\"tools\":[{\"functionDeclarations\":[");
    try writer.writeAll(converted.written());
    try writer.writeAll("]}]");
    const effective_choice: types.ToolChoice = if (request.vision_mode == .required)
        .required
    else
        request.tool_choice;
    try writer.writeAll(",\"toolConfig\":{\"functionCallingConfig\":{\"mode\":");
    try std.json.Stringify.value(functionCallingMode(effective_choice), .{}, writer);
    try writer.writeAll("}}");
    return count;
}

fn functionCallingMode(choice: types.ToolChoice) []const u8 {
    return switch (choice) {
        .auto => "AUTO",
        .none => "NONE",
        .required => "ANY",
    };
}

fn convertFunctionDeclaration(writer: *std.Io.Writer, value: std.json.Value, comma: bool) !bool {
    if (value != .object) return false;
    const object = value.object;
    const kind = object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return false;
    const name = object.get("name") orelse return false;
    if (name != .string or name.string.len == 0) return false;
    const parameters = object.get("inputSchema") orelse object.get("parameters") orelse return false;
    if (parameters != .object) return false;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parametersJsonSchema\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeByte('}');
    return true;
}

/// Emits `"generationConfig"`: everything the SDK hoists stays top-level
/// (done above), while maxOutputTokens and structured-output hints live here.
fn writeGenerationConfig(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) !void {
    if (request.max_output_tokens == null and request.response_format == null) return;
    try writer.writeAll(",\"generationConfig\":{");
    if (request.max_output_tokens) |limit| {
        try writer.print("\"maxOutputTokens\":{d}", .{limit});
    }
    if (request.response_format) |format| {
        var schema = try std.json.parseFromSlice(std.json.Value, alloc, format.schema_json, .{});
        defer schema.deinit();
        if (schema.value != .object) return error.InvalidStructuredResponseSchema;
        if (request.max_output_tokens != null) try writer.writeByte(',');
        try writer.writeAll("\"responseMimeType\":\"application/json\",\"responseSchema\":");
        try std.json.Stringify.value(schema.value, .{}, writer);
    }
    try writer.writeByte('}');
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
    api_key: []const u8,
    /// Header storage owned by the caller's frame. `client.request` borrows
    /// `extra_headers` by pointer, and the head is only written after
    /// `runBoundedHttpOperation` has returned on a different thread, so the
    /// runtime-valued entry cannot live in `run`'s frame.
    extra_headers: [2]std.http.Header = undefined,

    pub fn run(self: *@This()) !OpenedRequest {
        self.extra_headers = .{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "x-goog-api-key", .value = self.api_key },
        };
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .omit,
                .accept_encoding = .omit,
                .user_agent = .{ .override = gateway_client.user_agent },
            },
            .extra_headers = &self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

fn e2eChatUrlEnvValue(descriptor: *const model_provider.Descriptor) ?[]const u8 {
    var name_buf: [64]u8 = undefined;
    const name = e2eEnvName(&name_buf, model_provider.providerSlug(descriptor.id), "_CHAT_URL") orelse return null;
    return io_mod.getenv(name);
}

fn e2eEnvName(buf: []u8, slug: []const u8, kind: []const u8) ?[]const u8 {
    var fba_writer: std.Io.Writer = .fixed(buf);
    fba_writer.writeAll("FX_E2E_") catch return null;
    for (slug) |ch| {
        const mapped: u8 = switch (ch) {
            'a'...'z' => ch - 32,
            '-', '.' => '_',
            else => ch,
        };
        fba_writer.writeByte(mapped) catch return null;
    }
    fba_writer.writeAll(kind) catch return null;
    return fba_writer.buffered();
}

fn resolveStreamUrl(alloc: Allocator, descriptor: *const model_provider.Descriptor, model: []const u8) ![]u8 {
    const e2e_override = e2eChatUrlEnvValue(descriptor);
    if (e2e_override) |override| {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EGenerativeAiEndpoint;
        return alloc.dupe(u8, override);
    }
    return endpointUrl(alloc, descriptor.base_url, model);
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
        if (!source.eql(expected)) return error.GoogleGenerativeAiCredentialRequired;
    }
    try validateModel(request.model);
    const request_endpoint = try resolveStreamUrl(alloc, descriptor, request.model);
    defer alloc.free(request_endpoint);
    const uri = try std.Uri.parse(request_endpoint);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .api_key = request.api_key,
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
    const outcome = try consumeSse(
        alloc,
        reader,
        .{
            .ctx = request.callback_ctx,
            .on_content_chunk = request.on_content_chunk,
            .on_tool_start = request.on_tool_start,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
        },
        request.content_capture_limit,
        request.cancel_flag,
    );
    errdefer {
        if (outcome.completion.content) |content| alloc.free(@constCast(content));
        types.freeToolCallSlice(alloc, @constCast(outcome.completion.tool_calls));
        if (outcome.error_event_body) |body| alloc.free(body);
    }
    if (outcome.error_event_body) |body| {
        return .{
            .status = outcome.error_status,
            .completion = outcome.completion,
            .err_body = body,
            .ownership = .owned,
        };
    }
    return .{
        .status = .ok,
        .completion = outcome.completion,
        .ownership = .owned,
    };
}

const StreamHandlers = struct {
    ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback = null,
};

const StreamOutcome = struct {
    completion: types.GatewayCompletion = .{},
    /// Raw JSON of a mid-stream `{"error":{...}}` event, owned by the caller.
    error_event_body: ?[]u8 = null,
    error_status: std.http.Status = .internal_server_error,
};

/// One completed Gemini functionCall. Calls arrive whole (no partial args), so
/// accumulation is trivial; ids are synthesized positionally because the wire
/// carries none, which keeps them stable across resume replays.
const ToolEntry = struct {
    id: []u8,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolEntry, alloc: Allocator) void {
        alloc.free(self.id);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

fn finishReasonFromWire(raw: []const u8) ?types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "STOP")) return .stop;
    if (std.mem.eql(u8, raw, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, raw, "SAFETY")) return .content_filter;
    return .provider_error;
}

fn checkedAccumulatedSize(current: usize, added: usize, limit: usize) !usize {
    const sum = std.math.add(usize, current, added) catch return error.GoogleGenerativeAiSseEventTooLarge;
    if (sum > limit) return error.GoogleGenerativeAiSseEventTooLarge;
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

    /// Yields trimmed payloads of `data:` frames. There is no `[DONE]`
    /// sentinel on this protocol: the stream simply ends.
    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate_bytes = try checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            );
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            self.release();
            return std.mem.trim(u8, trimmed["data:".len..], " \t");
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.GoogleGenerativeAiSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.GoogleGenerativeAiSseEventTooLarge;
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
                return error.GoogleGenerativeAiSseEventTooLarge;
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
    handlers: StreamHandlers,
    content_capture_limit: ?usize,
    cancel_flag: *std.atomic.Value(bool),
) anyerror!StreamOutcome {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ToolEntry) = .empty;
    errdefer {
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
            return error.GoogleGenerativeAiInvalidStreamEvent;
        defer parsed.deinit();
        if (parsed.value != .object) return error.GoogleGenerativeAiInvalidStreamEvent;
        const event = parsed.value.object;

        // Mid-stream failures arrive as ordinary data frames carrying an
        // `error` object; surface them as a provider error with the raw event
        // captured as the error body.
        if (event.get("error")) |error_value| {
            if (error_value == .object) {
                var status: std.http.Status = .internal_server_error;
                if (error_value.object.get("code")) |code| {
                    if (code == .integer and code.integer >= 400 and code.integer <= 599) {
                        status = @enumFromInt(@as(u10, @intCast(code.integer)));
                    }
                }
                const captured = try alloc.dupe(u8, data);
                errdefer alloc.free(captured);
                const captured_content: ?[]const u8 = if (content.items.len > 0)
                    try content.toOwnedSlice(alloc)
                else
                    null;
                const tool_calls = try materializeToolCalls(alloc, tools.items);
                for (tools.items) |*tool| tool.deinit(alloc);
                tools.deinit(alloc);
                return .{
                    .completion = .{
                        .content = captured_content,
                        .tool_calls = tool_calls,
                        .finish_reason = finish_reason orelse .provider_error,
                        .usage = usage,
                    },
                    .error_event_body = captured,
                    .error_status = status,
                };
            }
        }

        if (event.get("candidates")) |candidates_value| {
            // Only index 0 participates, matching the reference clients.
            if (candidates_value == .array and candidates_value.array.items.len > 0) {
                const candidate = candidates_value.array.items[0];
                if (candidate == .object) {
                    if (candidate.object.get("content")) |content_value| {
                        if (content_value == .object) {
                            if (content_value.object.get("parts")) |parts_value| {
                                if (parts_value == .array) {
                                    try consumeParts(
                                        alloc,
                                        parts_value.array.items,
                                        &content,
                                        content_capture_limit,
                                        handlers,
                                        &tools,
                                    );
                                }
                            }
                        }
                    }
                    if (candidate.object.get("finishReason")) |reason_value| {
                        if (reason_value == .string) {
                            if (finishReasonFromWire(reason_value.string)) |reason| {
                                if (finish_reason == null) finish_reason = reason;
                            }
                        }
                    }
                }
            }
        } else if (event.get("promptFeedback")) |feedback_value| {
            // A fully blocked prompt yields no candidates at all.
            if (feedback_value == .object) {
                if (feedback_value.object.get("blockReason")) |block_value| {
                    if (block_value == .string and block_value.string.len > 0) {
                        if (finish_reason == null) finish_reason = .content_filter;
                    }
                }
            }
        }

        if (event.get("usageMetadata")) |usage_value| {
            if (usage_value == .object) {
                usage = usageFromMetadata(usage_value.object);
            }
        }
    }

    const captured_content: ?[]const u8 = if (content.items.len > 0)
        try content.toOwnedSlice(alloc)
    else
        null;
    errdefer if (captured_content) |value| alloc.free(@constCast(value));
    const emitted_tool_calls = tools.items.len > 0;
    const tool_calls = try materializeToolCalls(alloc, tools.items);
    for (tools.items) |*tool| tool.deinit(alloc);
    tools.deinit(alloc);
    errdefer types.freeToolCallSlice(alloc, tool_calls);
    return .{
        .completion = .{
            .content = captured_content,
            .tool_calls = tool_calls,
            .finish_reason = if (emitted_tool_calls) .tool_calls else finish_reason,
            .usage = usage,
        },
    };
}

fn consumeParts(
    alloc: Allocator,
    parts: []const std.json.Value,
    content: *std.ArrayList(u8),
    content_capture_limit: ?usize,
    handlers: StreamHandlers,
    tools: *std.ArrayList(ToolEntry),
) !void {
    for (parts) |part| {
        if (part != .object) continue;
        const object = part.object;

        if (object.get("functionCall")) |call_value| {
            if (call_value == .object) try accumulateFunctionCall(alloc, call_value.object, handlers, tools);
            continue;
        }

        const text = optionalString(object.get("text")) orelse continue;
        if (text.len == 0) continue;
        const thought = if (object.get("thought")) |flag| flag == .bool and flag.bool else false;
        if (thought) {
            if (handlers.on_reasoning_chunk) |callback| callback(handlers.ctx, text);
            continue;
        }
        handlers.on_content_chunk(handlers.ctx, text);
        if (content_capture_limit == null or content.items.len < content_capture_limit.?) {
            const accepted = if (content_capture_limit) |limit|
                text[0..@min(text.len, limit -| content.items.len)]
            else
                text;
            try content.appendSlice(alloc, accepted);
        }
    }
}

fn accumulateFunctionCall(
    alloc: Allocator,
    object: std.json.ObjectMap,
    handlers: StreamHandlers,
    tools: *std.ArrayList(ToolEntry),
) !void {
    const name = optionalString(object.get("name")) orelse return;
    if (name.len == 0 or name.len > max_tool_identity_bytes) {
        return error.GoogleGenerativeAiToolIdentityInvalid;
    }
    if (tools.items.len >= max_tool_calls) return error.GoogleGenerativeAiToolCallLimitExceeded;

    var entry: ToolEntry = .{
        .id = try std.fmt.allocPrint(alloc, "call_{d}", .{tools.items.len}),
    };
    try entry.name.appendSlice(alloc, name);
    if (object.get("args")) |args_value| {
        if (args_value == .object) {
            var rendered: std.Io.Writer.Allocating = .init(alloc);
            defer rendered.deinit();
            try std.json.Stringify.value(args_value, .{}, &rendered.writer);
            if (rendered.written().len > max_tool_arguments_bytes) {
                return error.GoogleGenerativeAiToolArgumentsTooLarge;
            }
            try entry.arguments.appendSlice(alloc, rendered.written());
        }
    }
    tools.append(alloc, entry) catch |err| {
        entry.deinit(alloc);
        return err;
    };
    const tool = &tools.items[tools.items.len - 1];
    if (handlers.on_tool_start) |callback| {
        callback(handlers.ctx, tool.id, tool.name.items, null);
    }
    if (handlers.on_tool_input_chunk) |callback| {
        if (tool.arguments.items.len > 0) callback(handlers.ctx, tool.arguments.items);
    }
}

fn materializeToolCalls(
    alloc: Allocator,
    entries: []const ToolEntry,
) ![]const types.ToolCall {
    var calls: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (calls.items) |call| types.freeToolCall(alloc, call);
        calls.deinit(alloc);
    }
    for (entries) |entry| {
        try calls.append(alloc, .{
            .id = try alloc.dupe(u8, entry.id),
            .name = try alloc.dupe(u8, entry.name.items),
            .arguments_json = try alloc.dupe(u8, entry.arguments.items),
        });
    }
    return calls.toOwnedSlice(alloc);
}

/// Last-wins cumulative totals; thinking tokens count as output, cached prompt
/// tokens are reported as cache reads rather than fresh input.
fn usageFromMetadata(object: std.json.ObjectMap) types.Usage {
    const prompt = wireCount(object, "promptTokenCount");
    const cached = wireCount(object, "cachedContentTokenCount");
    const candidates = wireCount(object, "candidatesTokenCount");
    const thoughts = wireCount(object, "thoughtsTokenCount");
    return .{
        .input_tokens = if (prompt) |total| total -| (cached orelse 0) else null,
        .output_tokens = if (candidates != null or thoughts != null)
            (candidates orelse 0) +| (thoughts orelse 0)
        else
            null,
    };
}

fn wireCount(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const unwrapped = value orelse return null;
    if (unwrapped != .string) return null;
    return unwrapped.string;
}

test "endpoint resolution substitutes environment templates" {
    const alloc = std.testing.allocator;
    const direct = try resolveEndpointUrl(alloc, "https://api.example.com/v1", "/x");
    defer alloc.free(direct);
    try std.testing.expectEqualStrings("https://api.example.com/v1/x", direct);
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

test "endpoint urls follow the sdk model substitution rules" {
    const alloc = std.testing.allocator;
    const bare = try endpointUrl(alloc, "https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-flash");
    defer alloc.free(bare);
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
        bare,
    );
    const tuned = try endpointUrl(alloc, "https://example.test/v1", "tunedModels/mine");
    defer alloc.free(tuned);
    try std.testing.expectEqualStrings("https://example.test/v1/tunedModels/mine:streamGenerateContent?alt=sse", tuned);
    try std.testing.expectError(error.InvalidGoogleGenerativeAiModel, endpointUrl(alloc, "https://example.test", "../etc"));
}

test "request body shapes contents system instruction tools and config" {
    const alloc = std.testing.allocator;
    var snapshot: image_attachments.VerifiedSnapshot = .{
        .bytes = try alloc.dupe(u8, "abc"),
        .media_type = "image/png",
    };
    defer snapshot.deinit(alloc);
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be terse." },
        .{ .role = .user, .content = "Hi" },
        .{
            .role = .assistant,
            .content = "Checking weather.",
            .tool_calls = &.{
                .{ .id = "call_0", .name = "get_weather", .arguments_json = "{\"city\":\"Paris\"}" },
            },
        },
        .{
            .role = .tool,
            .tool_call_id = "call_0",
            .tool_name = "get_weather",
            .content = "18C sunny",
        },
        .{ .role = .user, .content = "Summarize" },
    };
    const body = try buildRequest(null, alloc, .{
        .model = "gemini-2.5-flash",
        .serialized_tools =
        \\[{"type":"function","name":"get_weather","description":"Get weather","inputSchema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]
        ,
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 256,
        .verified_images = &.{snapshot},
    });
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"contents\":" ++
            "[{\"role\":\"user\",\"parts\":[{\"text\":\"Hi\"}]}," ++
            "{\"role\":\"model\",\"parts\":[{\"text\":\"Checking weather.\"}," ++
            "{\"functionCall\":{\"name\":\"get_weather\",\"args\":{\"city\":\"Paris\"}}}]}," ++
            "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"get_weather\",\"response\":{\"output\":\"18C sunny\"}}}]}," ++
            "{\"role\":\"user\",\"parts\":[{\"text\":\"Summarize\"}," ++
            "{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"YWJj\"}}]}]," ++
            "\"systemInstruction\":{\"parts\":[{\"text\":\"Be terse.\"}]}," ++
            "\"tools\":[{\"functionDeclarations\":[" ++
            "{\"name\":\"get_weather\",\"description\":\"Get weather\"," ++
            "\"parametersJsonSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}" ++
            "]}]," ++
            "\"toolConfig\":{\"functionCallingConfig\":{\"mode\":\"AUTO\"}}," ++
            "\"generationConfig\":{\"maxOutputTokens\":256}}",
        body,
    );
}

test "structured output maps onto generationConfig response mime and schema" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Plan it" },
    };
    const body = try buildRequest(null, alloc, .{
        .model = "gemini-2.5-flash",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .response_format = .{
            .name = "plan",
            .description = "A plan",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"steps\":{\"type\":\"array\"}}}",
        },
    });
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"Plan it\"}]}]," ++
            "\"generationConfig\":{\"responseMimeType\":\"application/json\"," ++
            "\"responseSchema\":{\"type\":\"object\",\"properties\":{\"steps\":{\"type\":\"array\"}}}}}",
        body,
    );
}

test "orphaned tool results replay under their recorded tool name" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "go" },
        .{
            .role = .tool,
            .tool_call_id = "call_from_dropped_turn",
            .tool_name = "get_weather",
            .content = "18C sunny",
        },
        .{ .role = .tool, .tool_call_id = "call_unresolvable", .content = "" },
    };
    const body = try buildRequest(null, alloc, .{
        .model = "gemini-2.5-flash",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"contents\":[" ++
            "{\"role\":\"user\",\"parts\":[{\"text\":\"go\"}]}," ++
            "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"get_weather\"," ++
            "\"response\":{\"output\":\"18C sunny\"}}}]}]}",
        body,
    );
}

fn appendChunk(ctx: *anyopaque, chunk: []const u8) void {
    const self: *StreamCapture = @ptrCast(@alignCast(ctx));
    self.content.appendSlice(std.testing.allocator, chunk) catch {
        self.failed = true;
    };
}

fn appendReasoning(ctx: *anyopaque, chunk: []const u8) void {
    const self: *StreamCapture = @ptrCast(@alignCast(ctx));
    self.reasoning.appendSlice(std.testing.allocator, chunk) catch {
        self.failed = true;
    };
}

fn recordToolStart(
    ctx: *anyopaque,
    tool_id: []const u8,
    tool_name: []const u8,
    label_value: ?[]const u8,
) void {
    const self: *StreamCapture = @ptrCast(@alignCast(ctx));
    self.tool_id = std.testing.allocator.dupe(u8, tool_id) catch return;
    self.tool_name = std.testing.allocator.dupe(u8, tool_name) catch return;
    self.tool_label = label_value;
}

fn recordToolInput(ctx: *anyopaque, chunk: []const u8) void {
    const self: *StreamCapture = @ptrCast(@alignCast(ctx));
    self.tool_input.appendSlice(std.testing.allocator, chunk) catch {
        self.failed = true;
    };
}

const StreamCapture = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_input: std.ArrayList(u8) = .empty,
    tool_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    tool_label: ?[]const u8 = null,
    failed: bool = false,

    fn deinit(self: *StreamCapture) void {
        self.content.deinit(std.testing.allocator);
        self.reasoning.deinit(std.testing.allocator);
        self.tool_input.deinit(std.testing.allocator);
        if (self.tool_id) |id| std.testing.allocator.free(id);
        if (self.tool_name) |name| std.testing.allocator.free(name);
        self.* = undefined;
    }
};

fn consumeFixture(alloc: Allocator, fixture: []const u8) !struct {
    outcome: StreamOutcome,
    capture: StreamCapture,
} {
    var capture: StreamCapture = .{};
    errdefer capture.deinit();
    var reader: std.Io.Reader = .fixed(fixture);
    var cancelled = std.atomic.Value(bool).init(false);
    const outcome = try consumeSse(alloc, &reader, .{
        .ctx = &capture,
        .on_content_chunk = appendChunk,
        .on_tool_start = recordToolStart,
        .on_reasoning_chunk = appendReasoning,
        .on_tool_input_chunk = recordToolInput,
    }, null, &cancelled);
    return .{ .outcome = outcome, .capture = capture };
}

test "sse fixture folds text thought function call usage and finish reason" {
    const alloc = std.testing.allocator;
    const fixture =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"He\"}],\"role\":\"model\"},\"index\":0}]," ++
        "\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":1,\"totalTokenCount\":6}}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[" ++
        "{\"text\":\"llo\"},{\"text\":\" pondering\",\"thought\":true}," ++
        "{\"functionCall\":{\"name\":\"get_weather\",\"args\":{\"city\":\"Paris\"}}}],\"role\":\"model\"}}]," ++
        "\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":9,\"totalTokenCount\":14}}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"!\"}],\"role\":\"model\"}," ++
        "\"finishReason\":\"STOP\",\"index\":0}]," ++
        "\"usageMetadata\":{\"promptTokenCount\":42,\"candidatesTokenCount\":128," ++
        "\"thoughtsTokenCount\":200,\"cachedContentTokenCount\":10,\"totalTokenCount\":370}," ++
        "\"responseId\":\"abc123\"}\n\n";
    var built = try consumeFixture(alloc, fixture);
    defer {
        if (built.outcome.completion.content) |content| alloc.free(@constCast(content));
        types.freeToolCallSlice(alloc, @constCast(built.outcome.completion.tool_calls));
        if (built.outcome.error_event_body) |body| alloc.free(body);
        built.capture.deinit();
    }
    try std.testing.expect(!built.capture.failed);
    try std.testing.expectEqualStrings("Hello!", built.capture.content.items);
    try std.testing.expectEqualStrings(" pondering", built.capture.reasoning.items);
    try std.testing.expectEqualStrings("call_0", built.capture.tool_id.?);
    try std.testing.expectEqualStrings("get_weather", built.capture.tool_name.?);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", built.capture.tool_input.items);
    const completion = built.outcome.completion;
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_0", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("get_weather", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 32), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 328), completion.usage.output_tokens);
    try std.testing.expect(built.outcome.error_event_body == null);
}

test "mid-stream error objects surface as provider errors with captured bodies" {
    const alloc = std.testing.allocator;
    const fixture =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"par\"}]}}]}\n\n" ++
        "data: {\"error\":{\"code\":429,\"message\":\"Resource exhausted\",\"status\":\"RESOURCE_EXHAUSTED\"}}\n\n";
    var built = try consumeFixture(alloc, fixture);
    defer {
        if (built.outcome.completion.content) |content| alloc.free(@constCast(content));
        types.freeToolCallSlice(alloc, @constCast(built.outcome.completion.tool_calls));
        if (built.outcome.error_event_body) |body| alloc.free(body);
        built.capture.deinit();
    }
    try std.testing.expectEqual(std.http.Status.too_many_requests, built.outcome.error_status);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":429,\"message\":\"Resource exhausted\",\"status\":\"RESOURCE_EXHAUSTED\"}}",
        built.outcome.error_event_body.?,
    );
    try std.testing.expectEqualStrings("par", built.outcome.completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.provider_error, built.outcome.completion.finish_reason.?);
}

test "blocked prompts surface a content filter finish reason" {
    const alloc = std.testing.allocator;
    const fixture =
        "data: {\"promptFeedback\":{\"blockReason\":\"SAFETY\"}," ++
        "\"usageMetadata\":{\"promptTokenCount\":8,\"totalTokenCount\":8}}\n\n";
    var built = try consumeFixture(alloc, fixture);
    defer {
        if (built.outcome.completion.content) |content| alloc.free(@constCast(content));
        types.freeToolCallSlice(alloc, @constCast(built.outcome.completion.tool_calls));
        if (built.outcome.error_event_body) |body| alloc.free(body);
        built.capture.deinit();
    }
    try std.testing.expectEqual(types.ProviderFinishReason.content_filter, built.outcome.completion.finish_reason.?);
    try std.testing.expect(built.outcome.completion.content == null);
}

fn failingCredentialChunk(_: *anyopaque, _: []const u8) void {
    unreachable;
}

test "wrong credentials are rejected before network io" {
    const alloc = std.testing.allocator;
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var capture: StreamCapture = .{};
    defer capture.deinit();
    const provider = providerFor(model_provider.ProviderId.google.descriptor());
    const result = provider.stream(alloc, .{
        .api_key = "unused-key",
        .credential_source = .{ .provider_api_key = .openrouter },
        .team = null,
        .model = "gemini-2.5-flash",
        .retry_count = 0,
        .chat_url = "",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .callback_ctx = &capture,
        .on_content_chunk = failingCredentialChunk,
        .on_tool_start = null,
        .on_reasoning_chunk = null,
        .cancel_flag = &cancelled,
    });

    try std.testing.expectError(error.GoogleGenerativeAiCredentialRequired, result);
    try std.testing.expectEqual(
        stream_provider.DeliveryCertainty.State.definitely_unsent,
        delivery.load(),
    );
}
test "request extra headers outlive the bounded operation call frame" {
    var io_backend: std.Io.Threaded = .init_single_threaded;
    defer io_backend.deinit();
    const zio = io_backend.io();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);

    const endpoint = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/stream",
        .{server.socket.address.getPort()},
    );
    defer std.testing.allocator.free(endpoint);
    const uri = try std.Uri.parse(endpoint);

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = zio };
    defer client.deinit();
    var operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .api_key = "diagnostic-key",
    };
    // In production `run` executes on a spawned thread and the head is only
    // written after it returns, so the request's extra headers must point at
    // storage owned by the operation (the caller's frame), never at run's
    // stack frame.
    var opened = try operation.run();
    defer opened.deinit(std.testing.allocator);
    var request = opened.take();
    defer request.deinit();
    try std.testing.expectEqual(@as(usize, 2), request.extra_headers.len);
    try std.testing.expectEqualStrings("accept", request.extra_headers[0].name);
    try std.testing.expectEqualStrings("text/event-stream", request.extra_headers[0].value);
    try std.testing.expectEqualStrings("x-goog-api-key", request.extra_headers[1].name);
    try std.testing.expectEqualStrings("diagnostic-key", request.extra_headers[1].value);
    const storage_start: usize = @intFromPtr(&operation.extra_headers);
    const storage_end = storage_start + @sizeOf([2]std.http.Header);
    const used: usize = @intFromPtr(request.extra_headers.ptr);
    try std.testing.expect(used >= storage_start and used < storage_end);
}
