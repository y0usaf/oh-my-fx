//! Amazon Bedrock ConverseStream transport (`bedrock_converse` protocol).
//! POSTs `https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/converse-stream`
//! signed with SigV4 (service `bedrock`) and decodes the binary EventStream
//! reply into the shared stream-provider callbacks.
const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const io_mod = @import("../core/shared/io.zig");
const model_provider = @import("../core/config/model_provider.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const sigv4 = @import("bedrock/sigv4.zig");
const eventstream = @import("bedrock/eventstream.zig");

const Allocator = std.mem.Allocator;
const default_region = "us-east-1";
const max_error_body_bytes: usize = 256 * 1024;
const max_model_id_bytes: usize = 1024;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const frame_transfer_bytes: usize = 16 * 1024;
const connect_timeout_ms: i64 = 30_000;

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

/// Resolves the AWS environment credentials up front so missing configuration
/// fails loudly before any network I/O.
pub const AwsEnvironment = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8,
    region: []const u8,

    pub fn load() error{BedrockCredentialsMissing}!AwsEnvironment {
        const access_key_id = io_mod.getenv("AWS_ACCESS_KEY_ID") orelse return error.BedrockCredentialsMissing;
        if (access_key_id.len == 0) return error.BedrockCredentialsMissing;
        const secret_access_key = io_mod.getenv("AWS_SECRET_ACCESS_KEY") orelse return error.BedrockCredentialsMissing;
        if (secret_access_key.len == 0) return error.BedrockCredentialsMissing;
        const region = io_mod.getenv("AWS_REGION") orelse
            io_mod.getenv("AWS_DEFAULT_REGION") orelse
            default_region;
        return .{
            .access_key_id = access_key_id,
            .secret_access_key = secret_access_key,
            .session_token = io_mod.getenv("AWS_SESSION_TOKEN"),
            .region = region,
        };
    }
};

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_id_bytes) return error.InvalidBedrockModelId;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidBedrockModelId;
    }
}

/// Substitutes `{AWS_REGION}` in the descriptor base URL, falling back to the
/// documented us-east-1 endpoint when neither region variable is set.
pub fn resolveBaseUrl(alloc: Allocator, base_template: []const u8, region: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = base_template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return error.MalformedProviderBaseUrl;
        try out.appendSlice(alloc, rest[0..open]);
        const name = rest[open + 1 .. close];
        if (!std.mem.eql(u8, name, "AWS_REGION")) return error.MalformedProviderBaseUrl;
        try out.appendSlice(alloc, region);
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(alloc, rest);
    return out.toOwnedSlice(alloc);
}

/// Full streaming endpoint with the path-escaped model httpLabel.
pub fn converseStreamUrl(alloc: Allocator, base_template: []const u8, model_id: []const u8, region: []const u8) ![]u8 {
    const base = try resolveBaseUrl(alloc, base_template, region);
    defer alloc.free(base);
    const escaped = try sigv4.escapeModelIdPath(alloc, model_id);
    defer alloc.free(escaped);
    return std.fmt.allocPrint(alloc, "{s}/model/{s}/converse-stream", .{ base, escaped });
}

fn e2eChatUrlEnvValue() ?[]const u8 {
    var name_buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&name_buf);
    writer.writeAll("FX_E2E_") catch return null;
    for (model_provider.providerSlug(.bedrock)) |ch| {
        const mapped: u8 = switch (ch) {
            'a'...'z' => ch - 32,
            '-', '.' => '_',
            else => ch,
        };
        writer.writeByte(mapped) catch return null;
    }
    writer.writeAll("_CHAT_URL") catch return null;
    return io_mod.getenv(writer.buffered());
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
    try writer.writeAll("{\"messages\":");
    try writeMessages(writer, alloc, request.messages, request.verified_images);

    try writeSystemBlocks(writer, request.messages);
    try writeInferenceConfig(writer, request.max_output_tokens);
    _ = try writeToolConfig(writer, alloc, request);
    try writeAdditionalModelRequestFields(writer, request.provider_options.reasoning);
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn writeMessages(
    writer: *std.Io.Writer,
    alloc: Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    try writer.writeByte('[');
    var first = true;
    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        const message = messages[index];
        switch (message.role) {
            .system => {},
            .user => {
                const text = message.content orelse "";
                const attach_images = verified_images != null and
                    index == messages.len - 1 and
                    verified_images.?.len > 0;
                if (text.len == 0 and !attach_images) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_block = true;
                if (text.len > 0) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(text, .{}, writer);
                    try writer.writeByte('}');
                    first_block = false;
                }
                if (attach_images) {
                    for (verified_images.?) |image| {
                        if (!first_block) try writer.writeByte(',');
                        first_block = false;
                        try writeImageBlock(writer, alloc, image);
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                const has_content = message.content != null and message.content.?.len > 0;
                if (!has_content and message.tool_calls.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
                var first_block = true;
                if (has_content) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(message.content.?, .{}, writer);
                    try writer.writeByte('}');
                    first_block = false;
                }
                for (message.tool_calls) |call| {
                    if (!first_block) try writer.writeByte(',');
                    first_block = false;
                    try writeToolUseBlock(writer, alloc, call);
                }
                try writer.writeAll("]}");
            },
            .tool => {
                // All consecutive tool results are batched into one user
                // message, matching Bedrock's toolResult placement rules.
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_block = true;
                while (index < messages.len and messages[index].role == .tool) : (index += 1) {
                    if (!first_block) try writer.writeByte(',');
                    first_block = false;
                    try writeToolResultBlock(writer, alloc, messages[index]);
                }
                try writer.writeAll("]}");
                index -= 1; // the loop increment re-lands on the next non-tool message
            },
        }
    }
    try writer.writeByte(']');
}

fn writeImageBlock(
    writer: *std.Io.Writer,
    alloc: Allocator,
    image: image_attachments.VerifiedSnapshot,
) !void {
    const slash = std.mem.indexOfScalar(u8, image.media_type, '/') orelse return error.InvalidBedrockImageFormat;
    const format = image.media_type[slash + 1 ..];
    if (format.len == 0) return error.InvalidBedrockImageFormat;
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"image\":{\"format\":");
    try std.json.Stringify.value(format, .{}, writer);
    try writer.writeAll(",\"source\":{\"bytes\":\"");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}}");
}

fn writeToolUseBlock(writer: *std.Io.Writer, alloc: Allocator, call: types.ToolCall) !void {
    if (call.id.len == 0 or call.id.len > max_tool_identity_bytes or
        call.name.len == 0 or call.name.len > max_tool_identity_bytes)
    {
        return error.BedrockToolIdentityTooLong;
    }
    try writer.writeAll("{\"toolUse\":{\"toolUseId\":");
    try std.json.Stringify.value(call.id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(call.name, .{}, writer);
    try writer.writeAll(",\"input\":");
    var wrote_input = false;
    if (call.arguments_json.len > 0) {
        if (std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{})) |parsed| {
            defer parsed.deinit();
            try std.json.Stringify.value(parsed.value, .{}, writer);
            wrote_input = true;
        } else |_| {}
    }
    if (!wrote_input) try writer.writeAll("{}");
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn writeToolResultBlock(
    writer: *std.Io.Writer,
    alloc: Allocator,
    message: types.ChatMessage,
) !void {
    try writer.writeAll("{\"toolResult\":{\"toolUseId\":");
    try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
    const status: []const u8 = if (message.tool_result_status == .failure) "error" else "success";
    try writer.print(",\"status\":\"{s}\",\"content\":[", .{status});
    const content = message.content orelse "";
    if (content.len > 0) blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch break :blk;
        defer parsed.deinit();
        switch (parsed.value) {
            .object, .array => {
                try writer.writeAll("{\"json\":");
                try std.json.Stringify.value(parsed.value, .{}, writer);
                try writer.writeByte('}');
                try writer.writeAll("]}}");
                return;
            },
            else => {},
        }
    }
    try writer.writeAll("{\"text\":");
    try std.json.Stringify.value(content, .{}, writer);
    try writer.writeByte('}');
    try writer.writeAll("]}}");
}

fn hasSystemContent(messages: []const types.ChatMessage) bool {
    for (messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len > 0) return true;
    }
    return false;
}

fn writeSystemBlocks(writer: *std.Io.Writer, messages: []const types.ChatMessage) !void {
    if (!hasSystemContent(messages)) return;
    try writer.writeAll(",\"system\":[");
    var first = true;
    for (messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"text\":");
        try std.json.Stringify.value(text, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeInferenceConfig(writer: *std.Io.Writer, max_output_tokens: ?u32) !void {
    if (max_output_tokens) |limit| {
        try writer.print(",\"inferenceConfig\":{{\"maxTokens\":{d}}}", .{limit});
    }
}

/// Emits `"toolConfig":{...}` in Bedrock toolSpec shape from the shared
/// gateway function envelope. Returns whether anything was emitted; tool
/// choice `none` suppresses the whole block.
fn writeToolConfig(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) !bool {
    const choice: types.ToolChoice = if (request.vision_mode == .required)
        .required
    else
        request.tool_choice;
    if (choice == .none) return false;
    var rendered: std.Io.Writer.Allocating = .init(alloc);
    defer rendered.deinit();
    const rendered_writer = &rendered.writer;
    try rendered_writer.writeAll(",\"toolConfig\":{\"tools\":[");
    var count: usize = 0;

    if (request.vision_mode == .required) {
        const vision_tool = request.tool_registry.lookup("vision") orelse return error.VisionToolNotRegistered;
        const gateway_schema = @import("../core/tooling/gateway_schema.zig");
        const vision_json = try gateway_schema.builtinFunctionSchemaJsonAlloc(alloc, vision_tool.gateway_schema);
        defer alloc.free(vision_json);
        count += try appendFunctionTools(rendered_writer, alloc, vision_json, count);
    } else {
        // `serialized_tools` is already a JSON array of function envelopes.
        count += try appendFunctionTools(rendered_writer, alloc, request.serialized_tools, count);
    }
    for (request.selected_dynamic_tool_schemas) |schema_json| {
        count += try appendFunctionToolObject(rendered_writer, alloc, schema_json, count);
    }

    try rendered_writer.writeAll("],\"toolChoice\":");
    switch (choice) {
        .auto => try rendered_writer.writeAll("{\"auto\":{}}"),
        .required => try rendered_writer.writeAll("{\"any\":{}}"),
        .none => unreachable,
    }
    try rendered_writer.writeByte('}');
    if (count > 0) try writer.writeAll(rendered.written());
    return count > 0;
}

/// Converts every function envelope of a JSON array into Bedrock toolSpecs,
/// returning how many were appended. `already_emitted` suppresses the leading
/// comma when earlier sources already contributed specs.
fn appendFunctionTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    tools_json: []const u8,
    already_emitted: usize,
) !usize {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidToolSchema;
    var count: usize = 0;
    for (parsed.value.array.items) |value| {
        if (try convertFunctionTool(writer, value, already_emitted + count != 0)) count += 1;
    }
    return count;
}

/// Converts one standalone function-envelope JSON document into a toolSpec.
fn appendFunctionToolObject(
    writer: *std.Io.Writer,
    alloc: Allocator,
    tool_json: []const u8,
    already_emitted: usize,
) !usize {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, tool_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolSchema,
    };
    defer parsed.deinit();
    return if (try convertFunctionTool(writer, parsed.value, already_emitted != 0)) 1 else 0;
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
    try writer.writeAll("{\"toolSpec\":{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"inputSchema\":{\"json\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeAll("}}}");
    return true;
}

/// Claude thinking rides in `additionalModelRequestFields` following pi's
/// amazon-bedrock provider: a fixed budget per effort level plus the
/// interleaved-thinking beta flag.
fn writeAdditionalModelRequestFields(writer: *std.Io.Writer, reasoning: ?types.ReasoningEffort) !void {
    const effort = reasoning orelse return;
    try writer.writeAll(",\"additionalModelRequestFields\":{\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":");
    try writer.print("{d}", .{thinkingBudget(effort)});
    try writer.writeAll("},\"anthropic_beta\":[\"interleaved-thinking-2025-05-14\"]}");
}

fn thinkingBudget(effort: types.ReasoningEffort) u32 {
    const label: []const u8 = effort.label();
    if (std.mem.eql(u8, label, "minimal")) return 1024;
    if (std.mem.eql(u8, label, "low")) return 2048;
    if (std.mem.eql(u8, label, "high") or std.mem.eql(u8, label, "xhigh")) return 16384;
    return 8192; // medium / auto / unknown levels
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

fn streamCompletionCore(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source) |source| {
        const expected: types.CredentialSource = .{ .provider_api_key = descriptor.id };
        if (!source.eql(expected)) return error.BedrockCredentialRequired;
    }
    try validateModel(request.model);
    const env = try AwsEnvironment.load();

    const request_endpoint = blk: {
        if (e2eChatUrlEnvValue()) |override| {
            if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EChatCompletionsEndpoint;
            break :blk try alloc.dupe(u8, override);
        }
        break :blk try converseStreamUrl(alloc, descriptor.base_url, request.model, env.region);
    };
    defer alloc.free(request_endpoint);

    var payload_hash_hex: [sigv4.sha256_hex_len]u8 = undefined;
    sigv4.payloadHashHex(&payload_hash_hex, request.payload);
    var date_buf: [sigv4.long_date_len]u8 = undefined;
    const long_date_value = try sigv4.longDate(&date_buf, io_mod.milliTimestamp());

    var signing_headers_buf: [4]sigv4.Header = undefined;
    var header_count: usize = 3;
    signing_headers_buf[0] = .{ .name = "host", .value = hostFromUrl(request_endpoint) };
    signing_headers_buf[1] = .{ .name = "x-amz-content-sha256", .value = &payload_hash_hex };
    signing_headers_buf[2] = .{ .name = "x-amz-date", .value = long_date_value };
    if (env.session_token) |token| {
        if (token.len > 0) {
            signing_headers_buf[header_count] = .{ .name = "x-amz-security-token", .value = token };
            header_count += 1;
        }
    }

    const auth_header = try sigv4.authorizationHeader(
        alloc,
        .{
            .access_key_id = env.access_key_id,
            .secret_access_key = env.secret_access_key,
            .session_token = env.session_token,
        },
        long_date_value,
        env.region,
        sigv4.service_bedrock,
        .{
            .method = "POST",
            .canonical_path = canonicalPathOf(request_endpoint),
            .headers = signing_headers_buf[0..header_count],
            .payload_hash_hex = &payload_hash_hex,
        },
    );
    defer secret.zeroAndFree(alloc, auth_header);

    const uri = try std.Uri.parse(request_endpoint);
    var extra_headers: [3]std.http.Header = undefined;
    var extra_count: usize = 2;
    extra_headers[0] = .{ .name = "x-amz-content-sha256", .value = &payload_hash_hex };
    extra_headers[1] = .{ .name = "x-amz-date", .value = long_date_value };
    if (header_count == 4) {
        extra_headers[2] = .{ .name = "x-amz-security-token", .value = env.session_token.? };
        extra_count = 3;
    }

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
        .extra_headers = extra_headers[0..extra_count],
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
    const completion = try consumeEventStream(
        alloc,
        reader,
        .{
            .ctx = request.callback_ctx,
            .on_content_chunk = request.on_content_chunk,
            .on_tool_start = request.on_tool_start,
            .on_reasoning_chunk = request.on_reasoning_chunk,
            .on_tool_input_chunk = request.on_tool_input_chunk,
        },
        request.cancel_flag,
        request.content_capture_limit,
    );
    return .{
        .status = .ok,
        .completion = completion,
        .ownership = .owned,
    };
}

/// Authority (host[:port]) of an absolute URL string, used for the signed
/// `host` header.
fn hostFromUrl(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "//") orelse return url;
    const start = scheme_end + 2;
    const end = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
    return url[start..end];
}

fn canonicalPathOf(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "//") orelse return url;
    const path_start = std.mem.indexOfScalarPos(u8, url, scheme_end + 2, '/') orelse return "/";
    return url[path_start..];
}

const StreamCallbacks = struct {
    ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
};

const ToolBlockAccumulator = struct {
    index: i64,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *ToolBlockAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const StreamState = struct {
    alloc: Allocator,
    callbacks: StreamCallbacks,
    content: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ToolBlockAccumulator) = .empty,
    content_capture_limit: ?usize,
    finish_reason: ?types.ProviderFinishReason = null,
    usage: types.Usage = .{},
    failure_detail: ?[]u8 = null,
    stopped: bool = false,

    fn deinit(self: *StreamState) void {
        self.content.deinit(self.alloc);
        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.deinit(self.alloc);
        if (self.failure_detail) |detail| self.alloc.free(detail);
        self.* = undefined;
    }

    fn failWithDetail(self: *StreamState, kind: []const u8, detail: []const u8) !void {
        if (self.failure_detail != null) return;
        self.failure_detail = try std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ kind, detail });
        self.finish_reason = .provider_error;
        self.stopped = true;
    }

    fn handleFrame(self: *StreamState, frame: eventstream.Frame) !void {
        const message_type = frame.headerString(":message-type") orelse return;
        if (std.mem.eql(u8, message_type, "exception")) {
            const exception_type = frame.headerString(":exception-type") orelse "BedrockException";
            const detail = try payloadMessage(self.alloc, frame.payload);
            defer if (detail) |owned| self.alloc.free(owned);
            try self.failWithDetail(exception_type, detail orelse "");
            return;
        }
        if (std.mem.eql(u8, message_type, "error")) {
            const code = frame.headerString(":error-code") orelse "BedrockError";
            const message = frame.headerString(":error-message") orelse "";
            try self.failWithDetail(code, message);
            return;
        }
        if (!std.mem.eql(u8, message_type, "event")) return;
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, frame.payload, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BedrockEventstreamMalformedPayload,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.BedrockEventstreamMalformedPayload;
        const object = parsed.value.object;

        const event_type = frame.headerString(":event-type") orelse return;
        if (std.mem.eql(u8, event_type, "messageStart")) {
            return;
        }
        if (std.mem.eql(u8, event_type, "contentBlockStart")) {
            const index = integerField(object, "contentBlockIndex") orelse return;
            const start = object.get("start") orelse return;
            if (start != .object) return;
            const tool_use = start.object.get("toolUse") orelse return;
            if (tool_use != .object) return; // text blocks never emit starts
            const id = optionalString(tool_use.object.get("toolUseId")) orelse "";
            const name = optionalString(tool_use.object.get("name")) orelse "";
            const block = try self.ensureToolBlock(index);
            if (id.len > 0 and id.len <= max_tool_identity_bytes) {
                block.id.clearRetainingCapacity();
                try block.id.appendSlice(self.alloc, id);
            }
            if (name.len > 0 and name.len <= max_tool_identity_bytes) {
                block.name.clearRetainingCapacity();
                try block.name.appendSlice(self.alloc, name);
            }
            self.announce(block);
            return;
        }
        if (std.mem.eql(u8, event_type, "contentBlockDelta")) {
            const index = integerField(object, "contentBlockIndex") orelse return;
            const delta_value = object.get("delta") orelse return;
            if (delta_value != .object) return;
            const delta = delta_value.object;
            try self.consumeDelta(index, delta);
            return;
        }
        if (std.mem.eql(u8, event_type, "contentBlockStop")) {
            return;
        }
        if (std.mem.eql(u8, event_type, "messageStop")) {
            const reason = optionalString(object.get("stopReason")) orelse return;
            if (finishReasonFromStopReason(reason)) |mapped| {
                if (self.finish_reason == null) self.finish_reason = mapped;
            }
            return;
        }
        if (std.mem.eql(u8, event_type, "metadata")) {
            const usage_value = object.get("usage") orelse return;
            if (usage_value != .object) return;
            if (integerField(usage_value.object, "inputTokens")) |tokens| {
                if (tokens >= 0) self.usage.input_tokens = @intCast(tokens);
            }
            if (integerField(usage_value.object, "outputTokens")) |tokens| {
                if (tokens >= 0) self.usage.output_tokens = @intCast(tokens);
            }
            return;
        }
        // Unknown event types are tolerated and skipped.
    }

    fn consumeDelta(self: *StreamState, index: i64, delta: std.json.ObjectMap) !void {
        if (delta.get("text")) |chunk| {
            if (chunk == .string and chunk.string.len > 0) {
                self.callbacks.on_content_chunk(self.callbacks.ctx, chunk.string);
                try self.capture(chunk.string);
            }
            return;
        }
        if (delta.get("toolUse")) |tool_delta| {
            if (tool_delta == .object) {
                if (optionalString(tool_delta.object.get("input"))) |fragment| {
                    if (fragment.len > 0) {
                        const block = try self.ensureToolBlock(index);
                        const projected = block.arguments.items.len + fragment.len;
                        if (projected > max_tool_arguments_bytes) return error.BedrockToolArgumentsTooLarge;
                        try block.arguments.appendSlice(self.alloc, fragment);
                        if (self.callbacks.on_tool_input_chunk) |callback| {
                            callback(self.callbacks.ctx, fragment);
                        }
                    }
                }
            }
            return;
        }
        if (delta.get("reasoningContent")) |reasoning| {
            if (reasoning == .object) {
                if (optionalString(reasoning.object.get("text"))) |chunk| {
                    if (chunk.len > 0) {
                        if (self.callbacks.on_reasoning_chunk) |callback| {
                            callback(self.callbacks.ctx, chunk);
                        }
                    }
                }
            }
            return;
        }
        // citations / image / other newer deltas are ignored.
    }

    fn capture(self: *StreamState, chunk: []const u8) !void {
        const limit = self.content_capture_limit orelse {
            try self.content.appendSlice(self.alloc, chunk);
            return;
        };
        if (self.content.items.len >= limit) return;
        const accepted = chunk[0..@min(chunk.len, limit - self.content.items.len)];
        try self.content.appendSlice(self.alloc, accepted);
    }

    fn ensureToolBlock(self: *StreamState, index: i64) !*ToolBlockAccumulator {
        for (self.tools.items) |*tool| {
            if (tool.index == index) return tool;
        }
        if (self.tools.items.len >= max_tool_calls) return error.BedrockToolCallLimitExceeded;
        try self.tools.append(self.alloc, .{ .index = index });
        return &self.tools.items[self.tools.items.len - 1];
    }

    fn announce(self: *StreamState, block: *ToolBlockAccumulator) void {
        if (block.announced) return;
        if (block.id.items.len == 0 or block.name.items.len == 0) return;
        if (self.callbacks.on_tool_start) |callback| {
            callback(self.callbacks.ctx, block.id.items, block.name.items, null);
        }
        block.announced = true;
    }

    fn finalize(self: *StreamState) !types.GatewayCompletion {
        const captured_content: ?[]const u8 = if (self.content.items.len > 0)
            try self.content.toOwnedSlice(self.alloc)
        else
            null;
        errdefer if (captured_content) |value| self.alloc.free(@constCast(value));

        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| types.freeToolCall(self.alloc, call);
            calls.deinit(self.alloc);
        }
        for (self.tools.items) |*tool| {
            if (tool.id.items.len == 0 or tool.name.items.len == 0) continue;
            const arguments_json: []const u8 = if (tool.arguments.items.len == 0)
                "{}"
            else
                tool.arguments.items;
            try calls.append(self.alloc, .{
                .id = try self.alloc.dupe(u8, tool.id.items),
                .name = try self.alloc.dupe(u8, tool.name.items),
                .arguments_json = arguments_json: {
                    // Keep accumulated fragments only when they form valid
                    // JSON; otherwise fall back to an empty object like pi's
                    // lenient parse strategy.
                    const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, arguments_json, .{});
                    if (parsed) |*owned| {
                        owned.deinit();
                        break :arguments_json try self.alloc.dupe(u8, arguments_json);
                    } else |_| {
                        break :arguments_json "{}";
                    }
                },
            });
        }

        const detail = self.failure_detail;
        self.failure_detail = null;
        return .{
            .content = captured_content,
            .tool_calls = try calls.toOwnedSlice(self.alloc),
            .finish_reason = self.finish_reason,
            .provider_failure_detail = detail,
            .usage = self.usage,
        };
    }
};

fn finishReasonFromStopReason(raw: []const u8) ?types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "end_turn") or std.mem.eql(u8, raw, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, raw, "max_tokens") or std.mem.eql(u8, raw, "model_context_window_exceeded")) return .length;
    if (std.mem.eql(u8, raw, "tool_use")) return .tool_calls;
    if (std.mem.eql(u8, raw, "content_filtered")) return .content_filter;
    return .other;
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const unwrapped = value orelse return null;
    if (unwrapped != .string) return null;
    return unwrapped.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn payloadMessage(alloc: Allocator, payload: []const u8) !?[]u8 {
    if (payload.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const message = optionalString(parsed.value.object.get("message")) orelse return null;
    return try alloc.dupe(u8, message);
}

fn consumeEventStream(
    alloc: Allocator,
    reader: anytype,
    callbacks: StreamCallbacks,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) anyerror!types.GatewayCompletion {
    var decoder: eventstream.Decoder = .{};
    defer decoder.deinit(alloc);
    var state = StreamState{
        .alloc = alloc,
        .callbacks = callbacks,
        .content_capture_limit = content_capture_limit,
    };
    defer state.deinit();

    var transfer: [frame_transfer_bytes]u8 = undefined;
    while (!state.stopped) {
        while (try decoder.next(alloc)) |frame| {
            defer frame.deinit(alloc);
            try state.handleFrame(frame);
        }
        if (state.stopped) break;
        const read = reader.readSliceShort(&transfer) catch |err| switch (err) {
            error.ReadFailed => return error.BedrockEventstreamReadFailed,
        };
        if (read == 0) {
            // No sentinel frame exists: a clean connection close ends the
            // stream, but a partially buffered frame is truncation.
            if (decoder.bufferedBytes() > 0) return error.BedrockEventstreamTruncatedFrame;
            break;
        }
        try decoder.push(alloc, transfer[0..read]);
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    }

    const completion = try state.finalize();
    errdefer {
        if (completion.content) |content| alloc.free(@constCast(content));
        types.freeToolCallSlice(alloc, completion.tool_calls);
        if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
    }
    return completion;
}

test "converse request body matches restJson1 shape" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "You are terse." },
        .{ .role = .user, .content = "Weather?" },
        .{
            .role = .assistant,
            .tool_calls = &.{.{
                .id = "toolu_01",
                .name = "get_weather",
                .arguments_json = "{\"city\":\"SF\"}",
            }},
        },
        .{
            .role = .tool,
            .tool_call_id = "toolu_01",
            .content = "{\"temp_c\":20}",
            .tool_result_status = .success,
        },
    };
    const payload = try buildRequest(null, alloc, .{
        .model = "us.anthropic.claude-opus-4-6-v1",
        .serialized_tools =
        \\[{"type":"function","name":"get_weather","description":"w",
        \\"inputSchema":{"type":"object","properties":{"city":{"type":"string"}}}}]
        ,
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("medium") },
        .max_output_tokens = 512,
    });
    defer alloc.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // system prompt lifted into its own array
    const system = root.get("system").?.array;
    try std.testing.expectEqualStrings("You are terse.", system.items[0].object.get("text").?.string);

    // three messages: user, assistant toolUse, batched user toolResult
    const sent_messages = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 3), sent_messages.items.len);
    try std.testing.expectEqualStrings("user", sent_messages.items[0].object.get("role").?.string);

    const assistant_blocks = sent_messages.items[1].object.get("content").?.array;
    const tool_use = assistant_blocks.items[0].object.get("toolUse").?.object;
    try std.testing.expectEqualStrings("toolu_01", tool_use.get("toolUseId").?.string);
    try std.testing.expectEqualStrings("get_weather", tool_use.get("name").?.string);
    try std.testing.expectEqualStrings("SF", tool_use.get("input").?.object.get("city").?.string);

    const result_blocks = sent_messages.items[2].object.get("content").?.array;
    const tool_result = result_blocks.items[0].object.get("toolResult").?.object;
    try std.testing.expectEqualStrings("toolu_01", tool_result.get("toolUseId").?.string);
    try std.testing.expectEqualStrings("success", tool_result.get("status").?.string);
    const result_content = tool_result.get("content").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 20), result_content.get("json").?.object.get("temp_c").?.integer);

    const additional = root.get("additionalModelRequestFields").?.object;
    try std.testing.expectEqualStrings("enabled", additional.get("thinking").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 8192), additional.get("thinking").?.object.get("budget_tokens").?.integer);
    try std.testing.expectEqualStrings(
        "interleaved-thinking-2025-05-14",
        additional.get("anthropic_beta").?.array.items[0].string,
    );

    const tool_config = root.get("toolConfig").?.object;
    const spec = tool_config.get("tools").?.array.items[0].object.get("toolSpec").?.object;
    try std.testing.expectEqualStrings("get_weather", spec.get("name").?.string);
    try std.testing.expect(spec.get("inputSchema").?.object.get("json") != null);
    try std.testing.expect(tool_config.get("toolChoice").?.object.get("auto") != null);
    try std.testing.expect(root.get("modelId") == null); // model id travels in the path only
}

test "thinking budget maps effort levels" {
    try std.testing.expectEqual(@as(u32, 1024), thinkingBudget(types.ReasoningEffort.literal("minimal")));
    try std.testing.expectEqual(@as(u32, 2048), thinkingBudget(types.ReasoningEffort.literal("low")));
    try std.testing.expectEqual(@as(u32, 16384), thinkingBudget(types.ReasoningEffort.literal("xhigh")));
    try std.testing.expectEqual(@as(u32, 8192), thinkingBudget(.auto));
}

test "converse stream url escapes the model label" {
    const alloc = std.testing.allocator;
    const simple = try converseStreamUrl(
        alloc,
        "https://bedrock-runtime.{AWS_REGION}.amazonaws.com",
        "us.anthropic.claude-opus-4-6-v1",
        "us-east-1",
    );
    defer alloc.free(simple);
    try std.testing.expectEqualStrings(
        "https://bedrock-runtime.us-east-1.amazonaws.com/model/us.anthropic.claude-opus-4-6-v1/converse-stream",
        simple,
    );
    const arn = try converseStreamUrl(
        alloc,
        "https://bedrock-runtime.{AWS_REGION}.amazonaws.com",
        "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/abc",
        "eu-central-1",
    );
    defer alloc.free(arn);
    try std.testing.expectEqualStrings(
        "https://bedrock-runtime.eu-central-1.amazonaws.com/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A123456789012%3Aapplication-inference-profile/abc/converse-stream",
        arn,
    );
}

// --- Frame-to-callback fixture machinery -----------------------------------

const TestHeaderValue = union(enum) {
    string: []const u8,
    integer: i32,
};

const TestHeader = struct {
    name: []const u8,
    value: TestHeaderValue,
};

fn encodeTestFrame(alloc: Allocator, headers: []const TestHeader, payload: []const u8) ![]u8 {
    var headers_length: usize = 0;
    for (headers) |header| {
        headers_length += 1 + header.name.len + 1;
        headers_length += switch (header.value) {
            .string => |str| 2 + str.len,
            .integer => 4,
        };
    }
    const total: usize = 12 + headers_length + payload.len + 4;
    const buf = try alloc.alloc(u8, total);
    errdefer alloc.free(buf);
    std.mem.writeInt(u32, buf[0..4], @intCast(total), .big);
    std.mem.writeInt(u32, buf[4..8], @intCast(headers_length), .big);
    var prelude_crc = eventstream.Crc32.init();
    prelude_crc.update(buf[0..8]);
    std.mem.writeInt(u32, buf[8..12], prelude_crc.final(), .big);

    var offset: usize = 12;
    for (headers) |header| {
        buf[offset] = @intCast(header.name.len);
        offset += 1;
        @memcpy(buf[offset .. offset + header.name.len], header.name);
        offset += header.name.len;
        switch (header.value) {
            .string => |str| {
                buf[offset] = 7;
                offset += 1;
                std.mem.writeInt(u16, buf[offset..][0..2], @intCast(str.len), .big);
                offset += 2;
                @memcpy(buf[offset .. offset + str.len], str);
                offset += str.len;
            },
            .integer => |int| {
                buf[offset] = 4;
                offset += 1;
                std.mem.writeInt(u32, buf[offset..][0..4], @bitCast(int), .big);
                offset += 4;
            },
        }
    }
    @memcpy(buf[offset .. offset + payload.len], payload);
    var message_crc = eventstream.Crc32.init();
    message_crc.update(buf[0 .. total - 4]);
    std.mem.writeInt(u32, buf[total - 4 ..][0..4], message_crc.final(), .big);
    return buf;
}

const Capture = struct {
    chunks: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    inputs: std.ArrayList(u8) = .empty,
    starts: std.ArrayList(u8) = .empty,

    fn deinit(self: *Capture, alloc: Allocator) void {
        self.chunks.deinit(alloc);
        self.reasoning.deinit(alloc);
        self.inputs.deinit(alloc);
        self.starts.deinit(alloc);
    }

    fn onContent(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.chunks.appendSlice(std.testing.allocator, chunk) catch {};
    }

    fn onReasoning(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.reasoning.appendSlice(std.testing.allocator, chunk) catch {};
    }

    fn onToolInput(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.inputs.appendSlice(std.testing.allocator, chunk) catch {};
    }

    fn onToolStart(ctx: *anyopaque, id: []const u8, name: []const u8, label_value: ?[]const u8) void {
        _ = label_value;
        const self: *Capture = @ptrCast(@alignCast(ctx));
        const starts = &self.starts;
        starts.appendSlice(std.testing.allocator, id) catch {};
        starts.append(std.testing.allocator, ':') catch {};
        starts.appendSlice(std.testing.allocator, name) catch {};
        starts.append(std.testing.allocator, ';') catch {};
    }
};

test "event frames drive ordered callbacks and completion" {
    const alloc = std.testing.allocator;
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(alloc);
    const parts = [_][]const u8{
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "messageStart" } },
        }, "{\"role\":\"assistant\"}"),
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "contentBlockDelta" } },
        }, "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"Hel\"}}"),
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "contentBlockDelta" } },
        }, "{\"contentBlockIndex\":1,\"delta\":{\"toolUse\":{\"input\":\"{\\\"a\\\":\"}}}"),
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "contentBlockDelta" } },
        }, "{\"contentBlockIndex\":1,\"delta\":{\"toolUse\":{\"input\":\"1}\"}}}"),
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "contentBlockStart" } },
        }, "{\"contentBlockIndex\":1,\"start\":{\"toolUse\":{\"toolUseId\":\"toolu_9\",\"name\":\"lookup\"}}}"),
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "contentBlockStop" } },
        }, "{\"contentBlockIndex\":1}"),
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "contentBlockDelta" } },
        }, "{\"contentBlockIndex\":2,\"delta\":{\"reasoningContent\":{\"text\":\"hmm\"}}}"),
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "messageStop" } },
        }, "{\"stopReason\":\"tool_use\"}"),
        try encodeTestFrame(alloc, &.{
            .{ .name = ":message-type", .value = .{ .string = "event" } },
            .{ .name = ":event-type", .value = .{ .string = "metadata" } },
        }, "{\"usage\":{\"inputTokens\":11,\"outputTokens\":7,\"totalTokens\":18}}"),
    };
    defer for (parts) |part| alloc.free(part);
    for (parts) |part| try frames.appendSlice(alloc, part);

    var capture: Capture = .{};
    defer capture.deinit(alloc);
    var cancelled = std.atomic.Value(bool).init(false);
    var source: std.Io.Reader = .fixed(frames.items);
    const completion = try consumeEventStream(
        alloc,
        &source,
        .{
            .ctx = &capture,
            .on_content_chunk = Capture.onContent,
            .on_tool_start = Capture.onToolStart,
            .on_reasoning_chunk = Capture.onReasoning,
            .on_tool_input_chunk = Capture.onToolInput,
        },
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |content| alloc.free(@constCast(content));
        types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
        if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
    }

    try std.testing.expectEqualStrings("Hel", completion.content.?);
    try std.testing.expectEqualStrings("hmm", capture.reasoning.items);
    try std.testing.expectEqualStrings("{\"a\":1}", capture.inputs.items);
    try std.testing.expectEqualStrings("toolu_9:lookup;", capture.starts.items);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_9", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("lookup", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"a\":1}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(u64, 11), completion.usage.input_tokens.?);
    try std.testing.expectEqual(@as(u64, 7), completion.usage.output_tokens.?);
    try std.testing.expect(completion.provider_failure_detail == null);
}

test "mid-stream exception frame becomes a provider failure" {
    const alloc = std.testing.allocator;
    const exception_frame = try encodeTestFrame(alloc, &.{
        .{ .name = ":message-type", .value = .{ .string = "exception" } },
        .{ .name = ":exception-type", .value = .{ .string = "throttlingException" } },
        .{ .name = ":content-type", .value = .{ .string = "application/json" } },
    }, "{\"message\":\"Rate limited\"}");
    defer alloc.free(exception_frame);

    var capture: Capture = .{};
    defer capture.deinit(alloc);
    var cancelled = std.atomic.Value(bool).init(false);
    var source: std.Io.Reader = .fixed(exception_frame);
    const completion = try consumeEventStream(
        alloc,
        &source,
        .{
            .ctx = &capture,
            .on_content_chunk = Capture.onContent,
            .on_tool_start = null,
            .on_reasoning_chunk = null,
            .on_tool_input_chunk = null,
        },
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |content| alloc.free(@constCast(content));
        types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
        if (completion.provider_failure_detail) |detail| alloc.free(@constCast(detail));
    }
    try std.testing.expectEqual(types.ProviderFinishReason.provider_error, completion.finish_reason.?);
    try std.testing.expectEqualStrings("throttlingException: Rate limited", completion.provider_failure_detail.?);
}

test "wrong credential source is rejected before network I/O" {
    const alloc = std.testing.allocator;
    const descriptor = model_provider.ProviderId.bedrock.descriptor();
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var capture: Capture = .{};
    defer capture.deinit(alloc);
    const result = streamCompletion(
        @ptrCast(@constCast(descriptor)),
        alloc,
        .{
            .api_key = "",
            .credential_source = .{ .provider_api_key = .openrouter },
            .model = "us.anthropic.claude-opus-4-6-v1",
            .team = null,
            .chat_url = "",
            .payload = "{}",
            .trace_ctx = .{},
            .content_capture_limit = null,
            .retry_count = 0,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .callback_ctx = &capture,
            .on_content_chunk = Capture.onContent,
            .on_tool_start = null,
            .on_reasoning_chunk = null,
            .cancel_flag = &cancelled,
        },
    );
    try std.testing.expectError(error.BedrockCredentialRequired, result);
}
