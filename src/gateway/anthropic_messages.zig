//! Anthropic Messages streaming transport (`POST {base}/v1/messages`).
//!
//! Serves every descriptor whose protocol is `.anthropic_messages` (anthropic,
//! minimax pair, kimi-coding, fireworks, cloudflare gateway) and exposes a
//! low-level entry point so wrapped providers (GitHub Copilot device-flow
//! OAuth) reuse the same HTTP + SSE machinery without duplicating protocol
//! logic. See `streamWithCallOptions` and `buildRequestBody`.
//!
//! Wire reference: oh-my-pi `providers/anthropic.ts` against
//! `@anthropic-ai/sdk` 0.91.1 behavior.
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
const max_content_blocks: usize = 512;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;

/// Pinned Anthropic wire version (SDK constant).
pub const anthropic_version = "2023-06-01";
/// OAuth access tokens ride `Authorization: Bearer`; plain API keys ride
/// `x-api-key`. The prefix decides, matching SDK/pi behavior.
pub const oauth_token_prefix = "sk-ant-oat";
/// Anthropic requires `max_tokens`. Used when the caller did not set one.
pub const default_max_tokens: u32 = 8192;

/// Extra presentation data for callers that reach the transport through
/// something other than a bare descriptor (currently GitHub Copilot).
pub const CallOptions = struct {
    /// Absolute URL for `POST /v1/messages`.
    endpoint_url: []const u8,
    /// Appended after the transport's own headers.
    extra_headers: []const std.http.Header = &.{},
    /// Force `Authorization: Bearer` even for keys without the OAuth prefix
    /// (Copilot's short-lived tokens are opaque bearer blobs).
    force_bearer: bool = false,
};

/// Builds the transport for one descriptor-driven Anthropic-compatible
/// provider. The descriptor is comptime-lifetime data, so borrowing it as the
/// opaque provider context is safe for the process lifetime.
pub fn providerFor(descriptor: *const model_provider.Descriptor) stream_provider.Provider {
    return .{
        .context = @constCast(descriptor),
        .observes_gateway_usage = descriptor.observes_gateway_usage,
        .build_fn = buildViaDescriptor,
        .stream_fn = streamViaDescriptor,
    };
}

pub fn expectedCredentialSource(descriptor: *const model_provider.Descriptor) types.CredentialSource {
    return .{ .provider_api_key = descriptor.id };
}

fn buildViaDescriptor(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));
    return buildRequestBody(descriptor, alloc, request);
}

fn streamViaDescriptor(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));
    try validateModel(request.model);
    const endpoint_url = try resolveDescriptorChatUrl(alloc, descriptor);
    defer alloc.free(endpoint_url);
    return streamWithCallOptions(descriptor, alloc, request, .{
        .endpoint_url = endpoint_url,
    });
}

/// Low-level entry for wrapped providers: explicit endpoint plus extra
/// headers, sharing the descriptor-driven HTTP/SSE path verbatim.
pub fn streamWithCallOptions(
    descriptor: *const model_provider.Descriptor,
    alloc: Allocator,
    request: stream_provider.Request,
    options: CallOptions,
) !stream_provider.Result {
    var result = executeStream(descriptor, alloc, request, options) catch |err| {
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

pub fn buildRequestBody(
    descriptor: *const model_provider.Descriptor,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) ![]u8 {
    _ = descriptor;
    try validateModel(request.model);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);

    const tool_choice: types.ToolChoice = if (request.vision_mode == .required)
        .required
    else
        request.tool_choice;
    const include_tools = tool_choice != .none;

    const max_tokens: u32 = request.max_output_tokens orelse default_max_tokens;
    try writer.print(",\"max_tokens\":{d},\"stream\":true", .{max_tokens});

    try writeSystem(writer, alloc, request.messages);
    try writer.writeAll(",\"messages\":[");
    try writeMessages(writer, alloc, request.messages, request.verified_images);
    try writer.writeByte(']');

    if (request.provider_options.reasoning) |effort| {
        try writeThinking(writer, effort.label());
    }

    var tool_count: usize = 0;
    if (include_tools) {
        tool_count = try writeTools(
            writer,
            alloc,
            request.serialized_tools,
            request.selected_dynamic_tool_schemas,
            request.tool_registry,
            request.vision_mode,
        );
    }
    if (tool_count > 0) {
        try writer.writeAll(",\"tool_choice\":{\"type\":");
        try std.json.Stringify.value(toolChoiceTag(tool_choice), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn toolChoiceTag(choice: types.ToolChoice) []const u8 {
    return switch (choice) {
        .auto => "auto",
        // Anthropic spells forced-tool use `any`.
        .required => "any",
        .none => "none",
    };
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > 256) return error.AnthropicInvalidModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.AnthropicInvalidModel;
    }
}

/// Substitutes `{ENV}` segments from the environment and appends `suffix`.
pub fn resolveEndpointUrl(
    alloc: Allocator,
    base_template: []const u8,
    suffix: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = base_template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return error.AnthropicMalformedBaseUrl;
        try out.appendSlice(alloc, rest[0..open]);
        const name = rest[open + 1 .. close];
        const value = io_mod.getenv(name) orelse return error.AnthropicEndpointVariableUnset;
        try out.appendSlice(alloc, value);
        rest = rest[close + 1 ..];
    }
    try out.appendSlice(alloc, rest);
    try out.appendSlice(alloc, suffix);
    return out.toOwnedSlice(alloc);
}

fn resolveDescriptorChatUrl(alloc: Allocator, descriptor: *const model_provider.Descriptor) ![]u8 {
    if (e2eChatUrlEnvValue(descriptor)) |override| {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.AnthropicInvalidE2EEndpoint;
        return alloc.dupe(u8, override);
    }
    return resolveEndpointUrl(alloc, descriptor.base_url, "/v1/messages");
}

fn e2eChatUrlEnvValue(descriptor: *const model_provider.Descriptor) ?[]const u8 {
    var name_buf: [64]u8 = undefined;
    const name = e2eEnvName(&name_buf, model_provider.providerSlug(descriptor.id), "_CHAT_URL") orelse return null;
    return io_mod.getenv(name);
}

pub fn e2eEnvName(buf: []u8, slug: []const u8, kind: []const u8) ?[]const u8 {
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

fn writeSystem(writer: *std.Io.Writer, alloc: Allocator, messages: []const types.ChatMessage) !void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (messages) |message| {
        if (message.role != .system) continue;
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (joined.items.len > 0) try joined.appendSlice(alloc, "\n\n");
        try joined.appendSlice(alloc, text);
    }
    if (joined.items.len == 0) return;
    // System prompt travels as ONE top-level string field on the request.
    try writer.writeAll(",\"system\":");
    try std.json.Stringify.value(joined.items, .{}, writer);
}

fn writeThinking(writer: *std.Io.Writer, effort_label: []const u8) !void {
    // Anthropic extended thinking: effort maps onto an explicit token budget.
    try writer.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{thinkingBudgetFor(effort_label)});
}

/// Maps shared reasoning-effort labels onto Anthropic extended-thinking
/// budgets. Unknown labels fall back to a mid-range budget rather than being
/// dropped, because the caller explicitly asked for reasoning.
fn thinkingBudgetFor(effort_label: []const u8) u32 {
    if (std.ascii.eqlIgnoreCase(effort_label, "minimal")) return 1024;
    if (std.ascii.eqlIgnoreCase(effort_label, "low")) return 2048;
    if (std.ascii.eqlIgnoreCase(effort_label, "medium")) return 8192;
    if (std.ascii.eqlIgnoreCase(effort_label, "high")) return 16384;
    return 8192;
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
    var first = true;
    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        const message = messages[index];
        switch (message.role) {
            .system => {},
            .user => {
                const text = message.content orelse "";
                const attach_images = verified_images != null and index == messages.len - 1;
                try writeComma(writer, &first);
                if (!attach_images) {
                    try writer.writeAll("{\"role\":\"user\",\"content\":");
                    try std.json.Stringify.value(text, .{}, writer);
                    try writer.writeByte('}');
                    continue;
                }
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_block = true;
                if (text.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(text, .{}, writer);
                    try writer.writeByte('}');
                    first_block = false;
                }
                for (verified_images.?) |image| {
                    if (!first_block) try writer.writeByte(',');
                    try writeImageBlock(writer, alloc, image);
                    first_block = false;
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                const has_text = message.content != null and message.content.?.len > 0;
                if (!has_text and message.tool_calls.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
                var first_block = true;
                if (has_text) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(message.content.?, .{}, writer);
                    try writer.writeByte('}');
                    first_block = false;
                }
                for (message.tool_calls) |call| {
                    if (call.id.len == 0 or call.id.len > max_tool_identity_bytes or
                        call.name.len == 0 or call.name.len > max_tool_identity_bytes or
                        call.arguments_json.len > max_tool_arguments_bytes)
                    {
                        return error.AnthropicToolIdentityLimitExceeded;
                    }
                    if (!first_block) try writer.writeByte(',');
                    first_block = false;
                    try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"input\":");
                    try writeParsedJsonOrEmptyObject(writer, alloc, call.arguments_json);
                    try writer.writeByte('}');
                }
                try writer.writeAll("]}");
            },
            .tool => {
                // Consecutive tool results merge into ONE user message whose
                // content array carries tool_result blocks (Anthropic shape).
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_result = true;
                while (index < messages.len and messages[index].role == .tool) : (index += 1) {
                    const result = messages[index];
                    if (!first_result) try writer.writeByte(',');
                    first_result = false;
                    try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
                    try std.json.Stringify.value(result.tool_call_id orelse "", .{}, writer);
                    try writer.writeAll(",\"content\":");
                    try std.json.Stringify.value(result.content orelse "", .{}, writer);
                    if (result.tool_result_status) |status| {
                        if (status == .failure) {
                            try writer.writeAll(",\"is_error\":true");
                        }
                    }
                    try writer.writeByte('}');
                }
                try writer.writeAll("]}");
                // Compensate for the outer loop increment: `index` currently
                // points at the first non-tool message.
                index -= 1;
            },
        }
    }
}

fn writeImageBlock(
    writer: *std.Io.Writer,
    alloc: Allocator,
    image: image_attachments.VerifiedSnapshot,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
    try std.json.Stringify.value(image.media_type, .{}, writer);
    try writer.writeAll(",\"data\":");
    try std.json.Stringify.value(encoded, .{}, writer);
    try writer.writeAll("}}");
}

/// Emits parsed-or-empty JSON: valid input renders verbatim (already compact
/// enough for the wire), anything unparsable degrades to `{}` so replay never
/// hard-fails on legacy tool output.
fn writeParsedJsonOrEmptyObject(writer: *std.Io.Writer, alloc: Allocator, json_text: []const u8) !void {
    if (json_text.len == 0) {
        try writer.writeAll("{}");
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch {
        try writer.writeAll("{}");
        return;
    };
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

/// Emits `"tools":[...]` in Anthropic shape. Inputs arrive as the shared
/// gateway function envelope (`{type,name,description,inputSchema}`); each
/// entry is converted, not rebuilt, so one schema source feeds every provider.
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
        const vision_tool = registry.lookup("vision") orelse return error.AnthropicVisionToolNotRegistered;
        const vision_json = try gateway_schema.builtinFunctionSchemaJsonAlloc(alloc, vision_tool.gateway_schema);
        defer alloc.free(vision_json);
        try combined.appendSlice(alloc, vision_json);
    } else {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.AnthropicToolSchemaInvalid,
        };
        defer parsed.deinit();
        if (parsed.value != .array) return error.AnthropicToolSchemaInvalid;
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
        else => return error.AnthropicToolSchemaInvalid,
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
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"input_schema\":");
    try std.json.Stringify.value(parameters, .{}, writer);
    try writer.writeByte('}');
    return true;
}

// ---------------------------------------------------------------------------
// HTTP execution
// ---------------------------------------------------------------------------

fn authPresentation(force_bearer: bool, api_key: []const u8) enum { x_api_key, bearer } {
    if (force_bearer) return .bearer;
    // OAuth access tokens (Claude Code style `sk-ant-oat...`) ride Bearer per
    // Anthropic convention; everything else uses the family-default x-api-key.
    // Descriptor rows cannot distinguish an explicit `.bearer` HeaderStyle
    // from the struct default, so credential shape decides instead.
    if (std.mem.startsWith(u8, api_key, oauth_token_prefix)) return .bearer;
    return .x_api_key;
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
    authorization: ?[]const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = if (self.authorization) |value|
                    .{ .override = value }
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

fn executeStream(
    descriptor: *const model_provider.Descriptor,
    alloc: Allocator,
    request: stream_provider.Request,
    options: CallOptions,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source) |source| {
        const expected: types.CredentialSource = .{ .provider_api_key = descriptor.id };
        if (!source.eql(expected)) return error.AnthropicCredentialRequired;
    }
    try validateModel(request.model);

    // Arena keeps merged header strings alive for the whole request lifetime
    // (the bounded operation runs on another thread and std.http stores
    // override slices by reference until the request is deinitialized).
    var header_arena = std.heap.ArenaAllocator.init(alloc);
    defer header_arena.deinit();

    const presentation = authPresentation(options.force_bearer, request.api_key);
    var authorization: ?[]const u8 = null;
    if (presentation == .bearer) {
        const value = try std.fmt.allocPrint(header_arena.allocator(), "Bearer {s}", .{request.api_key});
        authorization = value;
    }

    var extra_headers: std.ArrayList(std.http.Header) = .empty;
    try extra_headers.appendSlice(header_arena.allocator(), &.{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "anthropic-version", .value = anthropic_version },
    });
    if (presentation == .x_api_key) {
        try extra_headers.append(header_arena.allocator(), .{
            .name = "x-api-key",
            .value = request.api_key,
        });
    }
    try extra_headers.appendSlice(header_arena.allocator(), options.extra_headers);

    const uri = try std.Uri.parse(options.endpoint_url);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = extra_headers.items,
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

// ---------------------------------------------------------------------------
// SSE consumption
// ---------------------------------------------------------------------------

fn checkedAccumulatedSize(current: usize, added: usize, limit: usize) !usize {
    const sum = std.math.add(usize, current, added) catch return error.AnthropicSseEventTooLarge;
    if (sum > limit) return error.AnthropicSseEventTooLarge;
    return sum;
}

/// Event-oriented SSE reader: splits lines on LF (tolerating CRLF via trailing
/// CR trim), ignores colon comment lines, joins multiple `data:` lines with
/// LF, and flushes events at blank-line boundaries plus once at EOF.
const AnthropicSseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,
    event_name: std.ArrayList(u8) = .empty,
    data_buf: std.ArrayList(u8) = .empty,
    saw_field: bool = false,
    flushed_trailing: bool = false,
    needs_reset: bool = false,

    const Event = struct {
        /// Empty slice when the event carried no `event:` field.
        name: []const u8,
        data: []const u8,
    };

    fn deinit(self: *AnthropicSseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
        self.event_name.deinit(alloc);
        self.data_buf.deinit(alloc);
    }

    fn resetEvent(self: *AnthropicSseReader) void {
        // Buffers are NOT cleared here: the just-returned Event slices still
        // reference this memory and stay valid until the caller asks for the
        // next event. Clearing happens lazily before the following event.
        self.saw_field = false;
        self.needs_reset = true;
    }

    fn next(self: *AnthropicSseReader, alloc: Allocator, reader: anytype) !?Event {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse {
                // EOF: flush a trailing partial event exactly once.
                if (self.saw_field and !self.flushed_trailing) {
                    self.flushed_trailing = true;
                    return Event{
                        .name = self.event_name.items,
                        .data = self.data_buf.items,
                    };
                }
                return null;
            };
            self.aggregate_bytes = try checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            );
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (trimmed.len == 0) {
                if (self.saw_field) {
                    const event = Event{
                        .name = self.event_name.items,
                        .data = self.data_buf.items,
                    };
                    self.resetEvent();
                    return event;
                }
                continue;
            }
            if (trimmed[0] == ':') continue;
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const field = trimmed[0..colon];
            var value = trimmed[colon + 1 ..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (self.needs_reset) {
                self.event_name.clearRetainingCapacity();
                self.data_buf.clearRetainingCapacity();
                self.needs_reset = false;
            }
            if (std.mem.eql(u8, field, "event")) {
                try self.replaceBuffer(alloc, &self.event_name, value);
                self.saw_field = true;
            } else if (std.mem.eql(u8, field, "data")) {
                if (self.data_buf.items.len > 0) {
                    try self.data_buf.append(alloc, '\n');
                }
                _ = try checkedAccumulatedSize(
                    self.data_buf.items.len,
                    value.len,
                    max_sse_aggregate_bytes,
                );
                try self.data_buf.appendSlice(alloc, value);
                self.saw_field = true;
            }
            // id:/retry:/other fields are ignored per the SSE framing rules.
        }
    }

    fn replaceBuffer(_: *AnthropicSseReader, alloc: Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
        buffer.clearRetainingCapacity();
        try buffer.appendSlice(alloc, value);
    }

    const Line = struct {
        bytes: []const u8,
        wire_bytes: usize,
    };

    fn readLine(self: *AnthropicSseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.AnthropicSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.AnthropicSseEventTooLarge;
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
                return error.AnthropicSseEventTooLarge;
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

const BlockKind = enum { text, thinking, redacted_thinking, tool_use };

const BlockAccumulator = struct {
    index: i64,
    kind: BlockKind,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    partial_json: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *BlockAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.text.deinit(alloc);
        self.signature.deinit(alloc);
        self.partial_json.deinit(alloc);
        self.* = undefined;
    }
};

fn blockByIndex(blocks: []BlockAccumulator, index: i64) ?*BlockAccumulator {
    for (blocks) |*block| {
        if (block.index == index) return block;
    }
    return null;
}

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
    var blocks: std.ArrayList(BlockAccumulator) = .empty;
    defer {
        for (blocks.items) |*block| block.deinit(alloc);
        blocks.deinit(alloc);
    }
    var sse: AnthropicSseReader = .{};
    defer sse.deinit(alloc);

    var finish_reason: ?types.ProviderFinishReason = null;
    var usage = types.Usage{};
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var saw_message_start = false;
    var saw_message_stop = false;

    while (try sse.next(alloc, reader)) |event| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (std.mem.eql(u8, event.name, "error")) {
            return error.AnthropicStreamErrorEvent;
        }
        const known = std.mem.eql(u8, event.name, "message_start") or
            std.mem.eql(u8, event.name, "content_block_start") or
            std.mem.eql(u8, event.name, "content_block_delta") or
            std.mem.eql(u8, event.name, "content_block_stop") or
            std.mem.eql(u8, event.name, "message_delta") or
            std.mem.eql(u8, event.name, "message_stop");
        if (!known) continue; // ping and unknown names are skipped silently

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, event.data, .{}) catch
            return error.AnthropicStreamEventInvalid;
        defer parsed.deinit();
        if (parsed.value != .object) return error.AnthropicStreamEventInvalid;
        const object = parsed.value.object;

        if (std.mem.eql(u8, event.name, "message_start")) {
            saw_message_start = true;
            if (object.get("message")) |message_value| {
                if (message_value == .object) {
                    if (message_value.object.get("id")) |id_value| {
                        if (optionalString(id_value)) |id| {
                            if (generation_id == null and id.len > 0) {
                                generation_id = try alloc.dupe(u8, id);
                            }
                        }
                    }
                    if (message_value.object.get("usage")) |usage_value| {
                        if (usage_value == .object) usage = usageFromWire(usage_value.object, usage);
                    }
                }
            }
        } else if (std.mem.eql(u8, event.name, "content_block_start")) {
            try consumeBlockStart(
                alloc,
                object,
                &blocks,
                callback_ctx,
                on_tool_start,
            );
        } else if (std.mem.eql(u8, event.name, "content_block_delta")) {
            try consumeBlockDelta(
                alloc,
                object,
                &blocks,
                &content,
                content_capture_limit,
                callback_ctx,
                on_content_chunk,
                on_reasoning_chunk,
                on_tool_input_chunk,
            );
        } else if (std.mem.eql(u8, event.name, "content_block_stop")) {
            try finalizeBlock(alloc, object, &blocks);
        } else if (std.mem.eql(u8, event.name, "message_delta")) {
            if (object.get("delta")) |delta_value| {
                if (delta_value == .object) {
                    if (delta_value.object.get("stop_reason")) |reason_value| {
                        if (optionalString(reason_value)) |raw| {
                            finish_reason = try finishReasonFromWire(raw);
                        }
                    }
                }
            }
            // Usage here is a FLAT sibling of delta; absent fields keep the
            // previously captured values (proxy quirk tolerance).
            if (object.get("usage")) |usage_value| {
                if (usage_value == .object) usage = usageFromWire(usage_value.object, usage);
            }
        } else if (std.mem.eql(u8, event.name, "message_stop")) {
            saw_message_stop = true;
        }
    }

    if (!saw_message_start) return error.AnthropicStreamMissingMessageStart;
    if (!saw_message_stop) return error.AnthropicStreamMissingMessageStop;

    const captured_content: ?[]const u8 = if (content.items.len > 0)
        try content.toOwnedSlice(alloc)
    else
        null;
    errdefer if (captured_content) |value| alloc.free(@constCast(value));
    const tool_calls = try materializeToolCalls(alloc, blocks.items);
    errdefer types.freeToolCallSlice(alloc, tool_calls);
    return .{
        .content = captured_content,
        .tool_calls = tool_calls,
        .generation_id = generation_id,
        .finish_reason = finish_reason,
        .usage = usage,
    };
}

fn consumeBlockStart(
    alloc: Allocator,
    object: std.json.ObjectMap,
    blocks: *std.ArrayList(BlockAccumulator),
    callback_ctx: *anyopaque,
    on_tool_start: ?stream_provider.ToolStartCallback,
) !void {
    const index = integerField(object.get("index")) orelse return error.AnthropicStreamEventInvalid;
    const block_value = object.get("content_block") orelse return error.AnthropicStreamEventInvalid;
    if (block_value != .object) return error.AnthropicStreamEventInvalid;
    const block_object = block_value.object;
    const kind_string = optionalString(block_object.get("type")) orelse return error.AnthropicStreamEventInvalid;
    const kind: BlockKind = blk: {
        if (std.mem.eql(u8, kind_string, "text")) break :blk .text;
        if (std.mem.eql(u8, kind_string, "thinking")) break :blk .thinking;
        if (std.mem.eql(u8, kind_string, "redacted_thinking")) break :blk .redacted_thinking;
        if (std.mem.eql(u8, kind_string, "tool_use")) break :blk .tool_use;
        return; // unknown block types are skipped silently
    };

    if (blockByIndex(blocks.items, index) != null) return error.AnthropicStreamIndexConflict;
    if (blocks.items.len >= max_content_blocks) return error.AnthropicContentBlockLimitExceeded;
    var accumulator: BlockAccumulator = .{ .index = index, .kind = kind };
    errdefer accumulator.deinit(alloc);
    switch (kind) {
        .text => {
            if (optionalString(block_object.get("text"))) |text| {
                try accumulator.text.appendSlice(alloc, text);
            }
        },
        .thinking => {
            if (optionalString(block_object.get("thinking"))) |text| {
                try accumulator.text.appendSlice(alloc, text);
            }
            if (optionalString(block_object.get("signature"))) |signature| {
                try accumulator.signature.appendSlice(alloc, signature);
            }
        },
        .redacted_thinking => {
            if (optionalString(block_object.get("data"))) |blob| {
                // pi stores the blob as the signature with redacted=true.
                try accumulator.signature.appendSlice(alloc, blob);
            }
        },
        .tool_use => {
            const id = optionalString(block_object.get("id")) orelse return error.AnthropicStreamEventInvalid;
            const name = optionalString(block_object.get("name")) orelse return error.AnthropicStreamEventInvalid;
            if (id.len == 0 or id.len > max_tool_identity_bytes) return error.AnthropicToolIdentityLimitExceeded;
            if (name.len == 0 or name.len > max_tool_identity_bytes) return error.AnthropicToolIdentityLimitExceeded;
            try accumulator.id.appendSlice(alloc, id);
            try accumulator.name.appendSlice(alloc, name);
            // id/name arrive complete at start; announce immediately.
            if (on_tool_start) |callback| callback(callback_ctx, accumulator.id.items, accumulator.name.items, null);
            accumulator.announced = true;
            // Seed input (almost always {}) becomes the partial-json base and
            // is overwritten by the authoritative parse at block stop.
            if (block_object.get("input")) |input_value| {
                if (input_value == .object and input_value.object.count() > 0) {
                    var rendered: std.Io.Writer.Allocating = .init(alloc);
                    defer rendered.deinit();
                    try std.json.Stringify.value(input_value, .{}, &rendered.writer);
                    try accumulator.partial_json.appendSlice(alloc, rendered.written());
                }
            }
        },
    }
    try blocks.append(alloc, accumulator);
}

fn consumeBlockDelta(
    alloc: Allocator,
    object: std.json.ObjectMap,
    blocks: *std.ArrayList(BlockAccumulator),
    content: *std.ArrayList(u8),
    content_capture_limit: ?usize,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
) !void {
    const index = integerField(object.get("index")) orelse return error.AnthropicStreamEventInvalid;
    const delta_value = object.get("delta") orelse return error.AnthropicStreamEventInvalid;
    if (delta_value != .object) return error.AnthropicStreamEventInvalid;
    const delta = delta_value.object;
    const target = blockByIndex(blocks.items, index) orelse
        return error.AnthropicStreamOrphanDelta;
    const delta_type = optionalString(delta.get("type")) orelse return error.AnthropicStreamEventInvalid;

    if (std.mem.eql(u8, delta_type, "text_delta")) {
        const chunk = optionalString(delta.get("text")) orelse return error.AnthropicStreamEventInvalid;
        if (chunk.len > 0) {
            try appendTextChunk(alloc, &target.text, chunk);
            on_content_chunk(callback_ctx, chunk);
            if (content_capture_limit == null or content.items.len < content_capture_limit.?) {
                const accepted = if (content_capture_limit) |limit|
                    chunk[0..@min(chunk.len, limit -| content.items.len)]
                else
                    chunk;
                try content.appendSlice(alloc, accepted);
            }
        }
    } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
        const chunk = optionalString(delta.get("thinking")) orelse return error.AnthropicStreamEventInvalid;
        if (chunk.len > 0) {
            try appendTextChunk(alloc, &target.text, chunk);
            if (on_reasoning_chunk) |callback| callback(callback_ctx, chunk);
        }
    } else if (std.mem.eql(u8, delta_type, "signature_delta")) {
        const signature = optionalString(delta.get("signature")) orelse return error.AnthropicStreamEventInvalid;
        try appendTextChunk(alloc, &target.signature, signature);
    } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
        const fragment = optionalString(delta.get("partial_json")) orelse return error.AnthropicStreamEventInvalid;
        if (fragment.len > 0) {
            // Append VERBATIM: chunks may split anywhere, including inside
            // escape sequences. Only the stop-event parse is authoritative.
            const projected = target.partial_json.items.len + fragment.len;
            if (projected > max_tool_arguments_bytes) return error.AnthropicToolArgumentsTooLarge;
            try target.partial_json.appendSlice(alloc, fragment);
            if (on_tool_input_chunk) |callback| callback(callback_ctx, fragment);
        }
    }
    // citations_delta and other exotic delta types drop silently.
}

fn appendTextChunk(alloc: Allocator, buffer: *std.ArrayList(u8), chunk: []const u8) !void {
    _ = try checkedAccumulatedSize(buffer.items.len, chunk.len, max_sse_aggregate_bytes);
    try buffer.appendSlice(alloc, chunk);
}

fn finalizeBlock(
    alloc: Allocator,
    object: std.json.ObjectMap,
    blocks: *std.ArrayList(BlockAccumulator),
) !void {
    const index = integerField(object.get("index")) orelse return error.AnthropicStreamEventInvalid;
    const target = blockByIndex(blocks.items, index) orelse
        return error.AnthropicStreamOrphanDelta;
    if (target.kind != .tool_use) return;
    // Authoritative parse of the accumulated fragments replaces the seed.
    const accumulated = target.partial_json.items;
    if (accumulated.len == 0) {
        target.partial_json.clearRetainingCapacity();
        try target.partial_json.appendSlice(alloc, "{}");
        return;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, accumulated, .{}) catch {
        // Repair-less fallback: proxies occasionally truncate arguments.
        target.partial_json.clearRetainingCapacity();
        try target.partial_json.appendSlice(alloc, "{}");
        return;
    };
    defer parsed.deinit();
    // Re-render through the parser so the stored arguments are canonical JSON.
    var rendered: std.Io.Writer.Allocating = .init(alloc);
    defer rendered.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &rendered.writer);
    target.partial_json.clearRetainingCapacity();
    try target.partial_json.appendSlice(alloc, rendered.written());
}

fn finishReasonFromWire(raw: []const u8) !types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "end_turn") or
        std.mem.eql(u8, raw, "stop_sequence") or
        std.mem.eql(u8, raw, "pause_turn"))
    {
        return .stop;
    }
    if (std.mem.eql(u8, raw, "max_tokens")) return .length;
    if (std.mem.eql(u8, raw, "tool_use")) return .tool_calls;
    if (std.mem.eql(u8, raw, "refusal") or std.mem.eql(u8, raw, "sensitive")) return .provider_error;
    return error.AnthropicUnknownStopReason;
}

fn usageFromWire(object: std.json.ObjectMap, base: types.Usage) types.Usage {
    var result = base;
    if (integerField(object.get("input_tokens"))) |value| {
        if (value >= 0) result.input_tokens = @intCast(value);
    }
    if (integerField(object.get("output_tokens"))) |value| {
        if (value >= 0) result.output_tokens = @intCast(value);
    }
    // cache_read_input_tokens / cache_creation_input_tokens have no slot on
    // `types.Usage` (it carries exactly input/output), so they are dropped.
    return result;
}

fn integerField(value: ?std.json.Value) ?i64 {
    const unwrapped = value orelse return null;
    if (unwrapped != .integer) return null;
    return unwrapped.integer;
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const unwrapped = value orelse return null;
    if (unwrapped != .string) return null;
    return unwrapped.string;
}

fn materializeToolCalls(
    alloc: Allocator,
    accumulators: []const BlockAccumulator,
) ![]const types.ToolCall {
    var calls: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (calls.items) |call| types.freeToolCall(alloc, call);
        calls.deinit(alloc);
    }
    for (accumulators) |*accumulator| {
        if (accumulator.kind != .tool_use) continue;
        if (accumulator.id.items.len == 0 or accumulator.name.items.len == 0) continue;
        try calls.append(alloc, .{
            .id = try alloc.dupe(u8, accumulator.id.items),
            .name = try alloc.dupe(u8, accumulator.name.items),
            .arguments_json = try alloc.dupe(u8, accumulator.partial_json.items),
        });
    }
    return calls.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "endpoint resolution substitutes environment templates" {
    const alloc = std.testing.allocator;
    const direct = try resolveEndpointUrl(alloc, "https://api.example.com", "/v1/messages");
    defer alloc.free(direct);
    try std.testing.expectEqualStrings("https://api.example.com/v1/messages", direct);
    try std.testing.expectError(
        error.AnthropicEndpointVariableUnset,
        resolveEndpointUrl(alloc, "https://x/{MISSING_VAR_ANTHROPIC_TEST}/y", ""),
    );
}

test "e2e env names derive uppercase slugs" {
    var buf: [64]u8 = undefined;
    const name = e2eEnvName(&buf, "kimi-coding", "_CHAT_URL").?;
    try std.testing.expectEqualStrings("FX_E2E_KIMI_CODING_CHAT_URL", name);
}

test "auth presentation follows credential shape and wrapper override" {
    try std.testing.expectEqual(
        @as(@TypeOf(authPresentation(false, "")), .x_api_key),
        authPresentation(false, "sk-ant-api03-plain-key"),
    );
    try std.testing.expectEqual(
        @as(@TypeOf(authPresentation(false, "")), .bearer),
        authPresentation(false, "sk-ant-oat01-example"),
    );
    try std.testing.expectEqual(
        @as(@TypeOf(authPresentation(true, "")), .bearer),
        authPresentation(true, "tid=abc;exp=123"),
    );
}

fn testBuildRequest() stream_provider.BuildRequest {
    return .{
        .model = "claude-haiku-4-5",
        .serialized_tools =
        \\[{"type":"function","name":"get_weather","description":"Weather lookup","inputSchema":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]}}]
        ,
        .messages = &.{
            .{ .role = .system, .content = "You are terse." },
            .{ .role = .user, .content = "Weather in San Francisco?" },
        },
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

test "request shape places system top-level and converts tools" {
    const alloc = std.testing.allocator;
    const descriptor = model_provider.descriptors[@intFromEnum(model_provider.ProviderId.anthropic)];
    const body = try buildRequestBody(&descriptor, alloc, testBuildRequest());
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("claude-haiku-4-5", root.get("model").?.string);
    try std.testing.expect(root.get("stream").?.bool);
    // system is a TOP-LEVEL STRING field, not an array and not a message.
    try std.testing.expectEqualStrings("You are terse.", root.get("system").?.string);
    try std.testing.expectEqual(@as(u32, default_max_tokens), root.get("max_tokens").?.integer);

    const messages = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("Weather in San Francisco?", messages[0].object.get("content").?.string);

    const tools = root.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    const tool = tools[0].object;
    try std.testing.expectEqualStrings("get_weather", tool.get("name").?.string);
    try std.testing.expect(tool.get("input_schema").? == .object);
    try std.testing.expectEqualStrings("auto", root.get("tool_choice").?.object.get("type").?.string);
    try std.testing.expect(root.get("thinking") == null);
}

test "request shape replays assistant tool_use and merged tool results" {
    const alloc = std.testing.allocator;
    const descriptor = model_provider.descriptors[@intFromEnum(model_provider.ProviderId.anthropic)];
    var request = testBuildRequest();
    request.messages = &.{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "weather?" },
        .{ .role = .assistant, .content = "Checking.", .tool_calls = &.{.{
            .id = "toolu_01",
            .name = "get_weather",
            .arguments_json = "{\"location\":\"San Francisco\"}",
        }} },
        .{ .role = .tool, .tool_call_id = "toolu_01", .content = "21C" },
        .{ .role = .tool, .tool_call_id = "toolu_02", .content = "humidity 60%", .tool_result_status = .failure },
        .{ .role = .user, .content = "thanks" },
    };
    const body = try buildRequestBody(&descriptor, alloc, request);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), messages.len);

    const assistant_blocks = messages[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), assistant_blocks.len);
    try std.testing.expectEqualStrings("text", assistant_blocks[0].object.get("type").?.string);
    const tool_use = assistant_blocks[1].object;
    try std.testing.expectEqualStrings("tool_use", tool_use.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_01", tool_use.get("id").?.string);
    try std.testing.expectEqualStrings("San Francisco", tool_use.get("input").?.object.get("location").?.string);

    // Two consecutive tool results merge into one user message.
    const result_blocks = messages[2].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("user", messages[2].object.get("role").?.string);
    try std.testing.expectEqual(@as(usize, 2), result_blocks.len);
    try std.testing.expectEqualStrings("tool_result", result_blocks[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_01", result_blocks[0].object.get("tool_use_id").?.string);
    try std.testing.expectEqual(result_blocks[1].object.get("is_error").?.bool, true);
}

test "request shape maps tool_choice none to omitted tools" {
    const alloc = std.testing.allocator;
    const descriptor = model_provider.descriptors[@intFromEnum(model_provider.ProviderId.anthropic)];
    var request = testBuildRequest();
    request.tool_choice = .none;
    const body = try buildRequestBody(&descriptor, alloc, request);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\"") == null);

    request.tool_choice = .required;
    const forced = try buildRequestBody(&descriptor, alloc, request);
    defer alloc.free(forced);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, forced, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "any",
        parsed.value.object.get("tool_choice").?.object.get("type").?.string,
    );
}

test "request shape maps reasoning effort onto thinking budget" {
    const alloc = std.testing.allocator;
    const descriptor = model_provider.descriptors[@intFromEnum(model_provider.ProviderId.anthropic)];
    var request = testBuildRequest();
    request.provider_options = .{ .reasoning = types.ReasoningEffort.literal("low") };
    const body = try buildRequestBody(&descriptor, alloc, request);
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048}") != null);
}

/// Drives `consumeSse` over an in-memory SSE byte fixture.
const TestReader = struct {
    interface: std.Io.Reader,

    fn init(bytes: []const u8) TestReader {
        return .{ .interface = std.Io.Reader.fixed(bytes) };
    }
};

const Capture = struct {
    chunks: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_input: std.ArrayList(u8) = .empty,
    tool_starts: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn deinit(self: *Capture, alloc: Allocator) void {
        self.chunks.deinit(alloc);
        self.reasoning.deinit(alloc);
        self.tool_input.deinit(alloc);
        self.tool_starts.deinit(alloc);
    }

    fn append(raw: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        self.chunks.appendSlice(std.testing.allocator, chunk) catch {
            self.failed = true;
        };
    }

    fn appendReasoning(raw: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        self.reasoning.appendSlice(std.testing.allocator, chunk) catch {
            self.failed = true;
        };
    }

    fn appendToolInput(raw: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        self.tool_input.appendSlice(std.testing.allocator, chunk) catch {
            self.failed = true;
        };
    }

    fn recordToolStart(
        raw: *anyopaque,
        tool_id: []const u8,
        tool_name: []const u8,
        label_value: ?[]const u8,
    ) void {
        _ = label_value;
        const self: *Capture = @ptrCast(@alignCast(raw));
        const alloc = std.testing.allocator;
        const line = std.fmt.allocPrint(alloc, "{s}|{s}\n", .{ tool_id, tool_name }) catch {
            self.failed = true;
            return;
        };
        defer alloc.free(line);
        self.tool_starts.appendSlice(alloc, line) catch {
            self.failed = true;
        };
    }
};

const sse_fixture =
    \\event: message_start
    \\data: {"type":"message_start","message":{"id":"msg_01XFDUDYJgAACzvnptvVoYEL","role":"assistant","content":[],"model":"claude-haiku-4-5","stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    \\
    \\event: ping
    \\data: {"type":"ping"}
    \\
    \\: proxy keep-alive comment
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":0}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":""}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"Checking weather"}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"EqQBCkgIBRAB"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":1}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_01A09q90qw90lq917835lq9","name":"get_weather","input":{}}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"location\": \"San Fran"}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"cisco\", \"unit\": \"celsius\"}"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":3}
    \\
    \\event: message_delta
    \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":209}}
    \\
    \\event: message_stop
    \\data: {"type":"message_stop"}
    \\
;

test "sse fixture covers deltas, tool accumulation, and usage" {
    const alloc = std.testing.allocator;
    var fixture_reader = TestReader.init(sse_fixture);
    var capture: Capture = .{};
    defer capture.deinit(alloc);
    var cancelled = std.atomic.Value(bool).init(false);

    const completion = try consumeSse(
        alloc,
        &fixture_reader.interface,
        &capture,
        Capture.append,
        Capture.recordToolStart,
        Capture.appendReasoning,
        Capture.appendToolInput,
        &cancelled,
        null,
    );
    defer {
        if (completion.content) |value| alloc.free(@constCast(value));
        if (completion.generation_id) |value| alloc.free(@constCast(value));
        types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    }

    try std.testing.expect(!capture.failed);
    try std.testing.expectEqualStrings("Hello world", capture.chunks.items);
    try std.testing.expectEqualStrings("Checking weather", capture.reasoning.items);
    try std.testing.expectEqualStrings("{\"location\": \"San Francisco\", \"unit\": \"celsius\"}", capture.tool_input.items);
    try std.testing.expectEqualStrings(
        "toolu_01A09q90qw90lq917835lq9|get_weather\n",
        capture.tool_starts.items,
    );

    try std.testing.expectEqualStrings("Hello world", completion.content.?);
    try std.testing.expectEqualStrings("msg_01XFDUDYJgAACzvnptvVoYEL", completion.generation_id.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 25), completion.usage.input_tokens);
    // message_delta.usage is flat and cumulative; its output_tokens wins.
    try std.testing.expectEqual(@as(?u64, 209), completion.usage.output_tokens);

    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    const call = completion.tool_calls[0];
    try std.testing.expectEqualStrings("toolu_01A09q90qw90lq917835lq9", call.id);
    try std.testing.expectEqualStrings("get_weather", call.name);
    var args = try std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{});
    defer args.deinit();
    try std.testing.expectEqualStrings(
        "San Francisco",
        args.value.object.get("location").?.string,
    );
    try std.testing.expectEqualStrings("celsius", args.value.object.get("unit").?.string);
}

test "sse stream missing message_stop is rejected" {
    const alloc = std.testing.allocator;
    var fixture_reader = TestReader.init(
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n\n",
    );
    var capture: Capture = .{};
    defer capture.deinit(alloc);
    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.AnthropicStreamMissingMessageStop,
        consumeSse(
            alloc,
            &fixture_reader.interface,
            &capture,
            Capture.append,
            null,
            null,
            null,
            &cancelled,
            null,
        ),
    );
}

test "sse error event aborts consumption" {
    const alloc = std.testing.allocator;
    var fixture_reader = TestReader.init(
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n",
    );
    var capture: Capture = .{};
    defer capture.deinit(alloc);
    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.AnthropicStreamErrorEvent,
        consumeSse(
            alloc,
            &fixture_reader.interface,
            &capture,
            Capture.append,
            null,
            null,
            null,
            &cancelled,
            null,
        ),
    );
}

test "unknown stop reason is rejected" {
    try std.testing.expectError(error.AnthropicUnknownStopReason, finishReasonFromWire("banana"));
    try std.testing.expectEqual(
        types.ProviderFinishReason.stop,
        try finishReasonFromWire("pause_turn"),
    );
    try std.testing.expectEqual(
        types.ProviderFinishReason.length,
        try finishReasonFromWire("max_tokens"),
    );
}

test "wrong credential source is rejected before network I/O" {
    const alloc = std.testing.allocator;
    const descriptor = model_provider.descriptors[@intFromEnum(model_provider.ProviderId.anthropic)];
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var capture: Capture = .{};
    defer capture.deinit(alloc);

    const provider = providerFor(&descriptor);
    const result = provider.stream(alloc, .{
        .api_key = "sk-ant-api03-test",
        .credential_source = .{ .provider_api_key = .deepseek },
        .team = null,
        .model = "claude-haiku-4-5",
        .retry_count = 0,
        .chat_url = "https://api.anthropic.com/v1/messages",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .callback_ctx = &capture,
        .on_content_chunk = Capture.append,
        .on_tool_start = null,
        .on_reasoning_chunk = null,
        .cancel_flag = &cancelled,
    });
    try std.testing.expectError(error.AnthropicCredentialRequired, result);
    // Rejection happened during admission: nothing was marked possibly sent
    // and no network failure evidence was recorded.
    try std.testing.expectEqual(
        stream_provider.DeliveryCertainty.State.definitely_unsent,
        delivery.load(),
    );
    try std.testing.expect(attempt_evidence.network_failure == null);
}
