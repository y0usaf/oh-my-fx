const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const io_mod = @import("../core/shared/io.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const types = @import("../core/shared/types.zig");

pub const ChatRole = types.ChatRole;
pub const ChatMessage = types.ChatMessage;
pub const ToolCall = types.ToolCall;

pub const StructuredResponseFormat = struct {
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
};

const pending_tool_review_result_text = "Tool call has not executed; it is pending permission review.";

pub fn roleName(role: ChatRole) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

pub fn writeChatMessageJson(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
) !void {
    writeChatMessageJsonInner(scratch_alloc, writer, message, false, null, null) catch |err| return err;
}

pub fn writeChatMessageJsonCached(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
) !void {
    writeChatMessageJsonInner(scratch_alloc, writer, message, true, null, null) catch |err| return err;
}

pub fn buildGatewayRequestBody(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
) ![]u8 {
    return buildGatewayRequestBodyWithOptions(alloc, tools_json, messages, .{}, .auto);
}

pub fn buildGatewayRequestBodyWithOptions(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
) ![]u8 {
    return buildGatewayRequestBodyWithOptionsAndOutputLimit(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice,
        null,
    );
}

pub fn buildGatewayRequestBodyWithOptionsAndOutputLimit(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        max_output_tokens,
    );
}

pub fn buildGatewayRequestBodyWithOptionsAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
    budget: BuildBudget,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        max_output_tokens,
        budget,
        null,
        null,
    );
}

pub fn buildGatewayRequestBodyWithVerifiedImagesAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    verified_images: []const image_attachments.VerifiedSnapshot,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    response_format: StructuredResponseFormat,
    budget: BuildBudget,
) ![]u8 {
    if (messages.len == 0 or messages[messages.len - 1].role != .user) {
        return error.InvalidGatewayHistory;
    }
    if (messages[messages.len - 1].images.len != 0) {
        return error.InvalidGatewayHistory;
    }
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        null,
        budget,
        response_format,
        .{
            .message_index = messages.len - 1,
            .images = verified_images,
        },
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithOptions(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
) ![]u8 {
    return buildGatewayRequiredToolRequestBodyWithOptionsAndOutputLimit(
        alloc,
        tools_json,
        messages,
        options,
        null,
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithOptionsAndOutputLimit(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(
        alloc,
        tools_json,
        messages,
        options,
        "required",
        max_output_tokens,
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithOptionsAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32,
    budget: BuildBudget,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        "required",
        max_output_tokens,
        budget,
        null,
        null,
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithMaxOutputTokens(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    max_output_tokens: u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(alloc, tools_json, messages, .{}, "required", max_output_tokens);
}

pub fn buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: u32,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    const budget = BuildBudget{ .deadline = deadline, .cancel_flag = cancel_flag };
    const expanded = try expandPendingToolReviewMessages(
        alloc,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
    defer alloc.free(expanded);

    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        expanded,
        options,
        "required",
        max_output_tokens,
        budget,
        null,
        null,
    );
}

/// Returns an owned message slice that closes the pending tool call before the
/// reviewer instruction. Message contents remain borrowed from `messages`.
pub fn expandPendingToolReviewMessages(
    alloc: std.mem.Allocator,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]ChatMessage {
    const budget = BuildBudget{ .deadline = deadline, .cancel_flag = cancel_flag };
    try budget.check();
    try validatePendingToolReviewMessages(alloc, messages, target_call_id, budget);
    try budget.check();

    const pending_index = messages.len - 2;
    const pending = messages[pending_index];
    const expanded_len = try std.math.add(usize, messages.len, pending.tool_calls.len);
    const expanded = try alloc.alloc(ChatMessage, expanded_len);
    errdefer alloc.free(expanded);

    @memcpy(expanded[0 .. pending_index + 1], messages[0 .. pending_index + 1]);
    for (pending.tool_calls, 0..) |call, i| {
        try budget.check();
        expanded[pending_index + 1 + i] = .{
            .role = .tool,
            .content = pending_tool_review_result_text,
            .tool_call_id = call.id,
            .tool_name = call.name,
        };
    }
    expanded[expanded.len - 1] = messages[messages.len - 1];
    try budget.check();
    try validateToolMessageHistory(alloc, expanded);
    try budget.check();
    return expanded;
}

fn buildGatewayRequestBodyWithSettings(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: []const u8,
    max_output_tokens: ?u32,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice,
        max_output_tokens,
        null,
        null,
        null,
    );
}

pub const BuildBudget = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,

    pub fn check(self: BuildBudget) error{ Cancelled, TimedOut }!void {
        if (self.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
        if (self.deadline) |deadline| {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            if (now.raw.nanoseconds >= deadline.raw.nanoseconds) return error.TimedOut;
        }
    }
};

fn buildGatewayRequestBodyValidated(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: []const u8,
    max_output_tokens: ?u32,
    budget: ?BuildBudget,
    response_format: ?StructuredResponseFormat,
    verified_image_override: ?VerifiedImageOverride,
) ![]u8 {
    if (budget) |active| try active.check();

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const cache_breakpoint_idx = if (options.prompt_caching) findCacheBreakpoint(messages) else null;
    var prefix_cacheable = true;

    try out.writer.writeAll("{\"prompt\":[");
    for (messages, 0..) |message, i| {
        if (budget) |active| try active.check();
        if (i > 0) try out.writer.writeByte(',');
        const use_cache = prefix_cacheable and shouldCacheMessage(message, i, cache_breakpoint_idx, options.prompt_caching);
        const verified_images = if (verified_image_override) |override|
            if (override.message_index == i) override.images else null
        else
            null;
        if (budget) |active| {
            try writeChatMessageJsonInner(
                std.heap.c_allocator,
                &out.writer,
                message,
                use_cache,
                active,
                verified_images,
            );
        } else if (use_cache) {
            try writeChatMessageJsonCached(std.heap.c_allocator, &out.writer, message);
        } else {
            try writeChatMessageJson(std.heap.c_allocator, &out.writer, message);
        }
        if (message.cache_policy == .no_cache) prefix_cacheable = false;
        if (budget) |active| try active.check();
    }
    try out.writer.writeAll("],\"tools\":");
    try out.writer.writeAll(tools_json);
    try out.writer.writeAll(",\"toolChoice\":{\"type\":");
    try std.json.Stringify.value(tool_choice, .{}, &out.writer);
    try out.writer.writeByte('}');

    if (response_format) |format| {
        try writeStructuredResponseFormat(alloc, &out.writer, format);
    }

    if (max_output_tokens) |value| {
        try out.writer.print(",\"maxOutputTokens\":{d}", .{value});
    }

    if (options.reasoning) |*reasoning| {
        try out.writer.writeAll(",\"reasoning\":");
        try std.json.Stringify.value(reasoning.label(), .{}, &out.writer);
    }
    try writeProviderOptions(&out.writer, options);

    try out.writer.writeByte('}');
    if (budget) |active| try active.check();
    return try out.toOwnedSlice();
}

/// Returns a new request body with the provider-visible user agent added.
/// The caller retains ownership of `body` and owns the returned slice.
pub fn withRequestUserAgent(
    alloc: std.mem.Allocator,
    body: []const u8,
    user_agent: []const u8,
) ![]u8 {
    if (body.len == 0 or body[body.len - 1] != '}') return error.InvalidGatewayRequestBody;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(body[0 .. body.len - 1]);
    try out.writer.writeAll(",\"headers\":{\"user-agent\":");
    try std.json.Stringify.value(user_agent, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeStructuredResponseFormat(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    format: StructuredResponseFormat,
) !void {
    _ = alloc;
    if (format.schema != .object) return error.InvalidStructuredResponseSchema;

    try writer.writeAll(",\"responseFormat\":{\"type\":\"json\",\"name\":");
    try std.json.Stringify.value(format.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(format.description, .{}, writer);
    try writer.writeAll(",\"schema\":");
    try std.json.Stringify.value(format.schema, .{}, writer);
    try writer.writeByte('}');
}

const VerifiedImageOverride = struct {
    message_index: usize,
    images: []const image_attachments.VerifiedSnapshot,
};

fn validatePendingToolReviewMessages(
    alloc: std.mem.Allocator,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    budget: BuildBudget,
) !void {
    try budget.check();
    if (messages.len < 2 or target_call_id.len == 0) return error.InvalidGatewayHistory;
    const pending = messages[messages.len - 2];
    const instruction = messages[messages.len - 1];
    if (pending.role != .assistant or pending.tool_calls.len == 0) return error.InvalidGatewayHistory;
    if (instruction.role != .system or instruction.content == null) return error.InvalidGatewayHistory;
    try validateToolMessageHistory(alloc, messages[0 .. messages.len - 2]);
    try budget.check();
    try validateAssistantToolCalls(alloc, pending.tool_calls);
    try budget.check();

    var target_matches: usize = 0;
    for (pending.tool_calls) |call| {
        try budget.check();
        if (std.mem.eql(u8, call.id, target_call_id)) target_matches += 1;
    }
    if (target_matches != 1) return error.InvalidGatewayHistory;
}

pub fn writeProviderOptions(writer: *std.Io.Writer, options: model_capabilities.ResolvedProviderOptions) !void {
    if (!options.fast and options.parallel_tool_calls == null) return;

    try writer.writeAll(",\"providerOptions\":{");
    if (options.fast) try writer.writeAll("\"gateway\":{\"speed\":\"fast\"}");
    if (options.parallel_tool_calls) |parallel_tool_calls| {
        if (options.fast) try writer.writeByte(',');
        try writer.writeAll("\"xai\":{\"parallelToolCalls\":");
        try writer.writeAll(if (parallel_tool_calls) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

pub fn validateToolMessageHistory(alloc: std.mem.Allocator, messages: []const ChatMessage) !void {
    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        if (msg.role == .tool) return error.InvalidGatewayHistory;
        if (msg.role != .assistant or msg.tool_calls.len == 0) {
            i += 1;
            continue;
        }

        try validateAssistantToolCalls(alloc, msg.tool_calls);
        const seen = try alloc.alloc(bool, msg.tool_calls.len);
        defer alloc.free(seen);

        i = try validateAssistantToolResultBlock(messages, i + 1, msg.tool_calls, seen);
    }
}

fn validateAssistantToolResultBlock(
    messages: []const ChatMessage,
    start_index: usize,
    calls: []const ToolCall,
    seen: []bool,
) !usize {
    @memset(seen, false);

    var result_count: usize = 0;
    var j = start_index;
    while (result_count < calls.len) : (j += 1) {
        if (j >= messages.len) return error.InvalidGatewayHistory;
        const result = messages[j];
        if (result.role != .tool) return error.InvalidGatewayHistory;
        const tool_call_id = result.tool_call_id orelse return error.InvalidGatewayHistory;
        const tool_name = result.tool_name orelse return error.InvalidGatewayHistory;
        if (result.content == null) return error.InvalidGatewayHistory;

        const matched_index = findToolCallIndex(calls, tool_call_id) orelse return error.InvalidGatewayHistory;
        if (seen[matched_index]) return error.InvalidGatewayHistory;
        if (!std.mem.eql(u8, calls[matched_index].name, tool_name)) return error.InvalidGatewayHistory;
        seen[matched_index] = true;
        result_count += 1;
    }
    return j;
}

fn validateAssistantToolCalls(alloc: std.mem.Allocator, calls: []const ToolCall) !void {
    for (calls, 0..) |call, i| {
        if (call.id.len == 0 or call.name.len == 0 or call.arguments_json.len == 0) return error.InvalidGatewayHistory;
        if (try types.ToolArgumentIntegrity.classifySerialized(alloc, call.arguments_json) == .malformed_json) {
            return error.InvalidGatewayHistory;
        }
        var j = i + 1;
        while (j < calls.len) : (j += 1) {
            if (std.mem.eql(u8, call.id, calls[j].id)) return error.InvalidGatewayHistory;
        }
    }
}

fn findToolCallIndex(calls: []const ToolCall, id: []const u8) ?usize {
    for (calls, 0..) |call, i| {
        if (std.mem.eql(u8, call.id, id)) return i;
    }
    return null;
}

pub fn shouldCacheMessage(message: ChatMessage, index: usize, cache_breakpoint_idx: ?usize, prompt_caching: bool) bool {
    if (!prompt_caching) return false;
    if (message.cache_policy == .no_cache) return false;
    return message.role == .system or (cache_breakpoint_idx != null and index == cache_breakpoint_idx.?);
}

const anthropic_cache_meta = ",\"providerOptions\":{\"anthropic\":{\"cacheControl\":{\"type\":\"ephemeral\"}}}";
const max_prompt_shape_entries: usize = 12;

fn writeChatMessageJsonInner(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
    cached: bool,
    budget: ?BuildBudget,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(roleName(message.role), .{}, writer);

    switch (message.role) {
        .system => {
            try writer.writeAll(",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
        },
        .user => {
            try writer.writeAll(",\"content\":[");
            var wrote_part = false;
            if (message.content) |content| {
                if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote_part = true;
                }
            }
            if (verified_images) |snapshots| {
                for (snapshots) |snapshot| {
                    if (wrote_part) try writer.writeByte(',');
                    try image_attachments.writeVerifiedImageFilePartJsonWithBudget(
                        writer,
                        snapshot,
                        .{
                            .deadline = if (budget) |active| active.deadline else null,
                            .cancel_flag = if (budget) |active| active.cancel_flag else null,
                        },
                    );
                    wrote_part = true;
                }
            } else {
                for (message.images) |image| {
                    if (wrote_part) try writer.writeByte(',');
                    if (budget) |active| {
                        try image_attachments.writeImageFilePartJsonWithBudget(
                            scratch_alloc,
                            writer,
                            image,
                            .{
                                .deadline = active.deadline,
                                .cancel_flag = active.cancel_flag,
                            },
                        );
                    } else {
                        try image_attachments.writeImageFilePartJson(scratch_alloc, writer, image);
                    }
                    wrote_part = true;
                }
            }
            try writer.writeByte(']');
        },
        .assistant => {
            try writer.writeAll(",\"content\":[");
            var wrote_part = false;
            if (message.content) |content| {
                if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote_part = true;
                }
            }
            for (message.tool_calls) |tool_call| {
                if (wrote_part) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"tool-call\",\"toolCallId\":");
                try std.json.Stringify.value(tool_call.id, .{}, writer);
                try writer.writeAll(",\"toolName\":");
                try std.json.Stringify.value(tool_call.name, .{}, writer);
                try writer.writeAll(",\"input\":");
                try writer.writeAll(tool_call.arguments_json);
                try writer.writeByte('}');
                wrote_part = true;
            }
            try writer.writeByte(']');
        },
        .tool => {
            try writer.writeAll(",\"content\":[{\"type\":\"tool-result\",\"toolCallId\":");
            if (message.tool_call_id) |tool_call_id| {
                try std.json.Stringify.value(tool_call_id, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
            try writer.writeAll(",\"toolName\":");
            if (message.tool_name) |tool_name| {
                try std.json.Stringify.value(tool_name, .{}, writer);
            } else {
                try writer.writeAll("\"unknown\"");
            }
            const content = message.content orelse "";
            const failed = if (message.tool_result_status) |status|
                status == .failure
            else
                false;
            const denied = failed and tool_result_errors.toolPermissionDenialReason(content) != null;
            if (denied) {
                try writer.writeAll(",\"output\":{\"type\":\"execution-denied\",\"reason\":");
            } else if (failed) {
                try writer.writeAll(",\"output\":{\"type\":\"error-text\",\"value\":");
            } else {
                try writer.writeAll(",\"output\":{\"type\":\"text\",\"value\":");
            }
            try std.json.Stringify.value(content, .{}, writer);
            try writer.writeAll("}}]");
        },
    }

    if (cached) try writer.writeAll(anthropic_cache_meta);
    try writer.writeAll("}");
}

pub fn formatGatewayRequestShapeSummary(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("bytes={d}", .{payload.len});

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| {
        try out.writer.print(" parse_error={s}", .{@errorName(err)});
        return try out.toOwnedSlice();
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try out.writer.print(" root={s}", .{jsonKindName(parsed.value)});
        return try out.toOwnedSlice();
    }

    if (parsed.value.object.get("prompt")) |prompt| {
        if (prompt == .array) {
            try out.writer.print(" prompt_count={d}", .{prompt.array.items.len});
            const limit = @min(prompt.array.items.len, max_prompt_shape_entries);
            for (prompt.array.items[0..limit], 0..) |entry, i| {
                try out.writer.print(" prompt.{d}", .{i});
                if (entry == .object) {
                    if (entry.object.get("role")) |role_value| {
                        try out.writer.writeAll(" role=");
                        if (role_value == .string) {
                            try appendSafeShapeToken(&out.writer, role_value.string);
                        } else {
                            try out.writer.writeAll(jsonKindName(role_value));
                        }
                    } else {
                        try out.writer.writeAll(" role=missing");
                    }
                    if (entry.object.get("content")) |content_value| {
                        try out.writer.print(" content={s}", .{jsonKindName(content_value)});
                        if (content_value == .array) try out.writer.print(" parts={d}", .{content_value.array.items.len});
                    } else {
                        try out.writer.writeAll(" content=missing");
                    }
                } else {
                    try out.writer.print(" entry={s}", .{jsonKindName(entry)});
                }
            }
            if (prompt.array.items.len > limit) {
                try out.writer.print(" prompt_omitted={d}", .{prompt.array.items.len - limit});
            }
        } else {
            try out.writer.print(" prompt={s}", .{jsonKindName(prompt)});
        }
    } else {
        try out.writer.writeAll(" prompt=missing");
    }

    if (parsed.value.object.get("tools")) |tools| {
        try out.writer.print(" tools={s}", .{jsonKindName(tools)});
        if (tools == .array) try out.writer.print(" tools_count={d}", .{tools.array.items.len});
    }

    if (parsed.value.object.get("toolChoice")) |tool_choice| {
        if (tool_choice == .object) {
            if (tool_choice.object.get("type")) |type_value| {
                try out.writer.writeAll(" toolChoice=");
                if (type_value == .string) {
                    try appendSafeShapeToken(&out.writer, type_value.string);
                } else {
                    try out.writer.writeAll(jsonKindName(type_value));
                }
            } else {
                try out.writer.writeAll(" toolChoice=object");
            }
        } else {
            try out.writer.print(" toolChoice={s}", .{jsonKindName(tool_choice)});
        }
    }

    if (parsed.value.object.get("providerOptions")) |provider_options| {
        try out.writer.print(" providerOptions={s}", .{jsonKindName(provider_options)});
        if (provider_options == .object) try out.writer.print(" providerOptions_count={d}", .{provider_options.object.count()});
    }

    return try out.toOwnedSlice();
}

fn appendSafeShapeToken(writer: *std.Io.Writer, raw: []const u8) !void {
    var wrote = false;
    var last_was_underscore = false;
    for (raw) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', '[', ']' => {
                try writer.writeByte(c);
                wrote = true;
                last_was_underscore = c == '_';
            },
            else => {
                if (!last_was_underscore) {
                    try writer.writeByte('_');
                    wrote = true;
                    last_was_underscore = true;
                }
            },
        }
    }
    if (!wrote) try writer.writeAll("unknown");
}

fn jsonKindName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn findCacheBreakpoint(messages: []const ChatMessage) ?usize {
    if (messages.len < 3) return null;
    var i = messages.len - 2;
    while (i > 0) : (i -= 1) {
        const role = messages[i].role;
        if (role == .user or role == .assistant) return i;
    }
    return null;
}
