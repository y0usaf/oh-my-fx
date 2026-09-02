const std = @import("std");
const model_capabilities = @import("../../config/model_capabilities.zig");
const types = @import("../../shared/types.zig");
const session_runtime = @import("../../session/session.zig");

const runtime_config = @import("config.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;

pub fn historyContextBudgetTokensForCapabilities(capabilities: model_capabilities.Capabilities) usize {
    const context_window = capabilities.context_window orelse
        return runtime_config.default_history_context_budget_tokens;
    const context_tokens: usize = @intCast(context_window);
    const available_input_tokens = if (capabilities.max_output_tokens) |max_output_tokens|
        context_tokens -| @as(usize, @intCast(max_output_tokens))
    else
        context_tokens;
    return @max(
        @as(usize, 1),
        available_input_tokens / runtime_config.history_context_budget_window_divisor,
    );
}

pub fn buildGatewayMessages(
    alloc: Allocator,
    stable_prefix: []const ChatMessage,
    ephemeral_overlay: []const ChatMessage,
    durable_history: []const ChatMessage,
    current_user_message: ChatMessage,
    within_turn_suffix: []const ChatMessage,
) !std.ArrayList(ChatMessage) {
    var messages: std.ArrayList(ChatMessage) = .empty;
    errdefer messages.deinit(alloc);

    try messages.appendSlice(alloc, stable_prefix);
    try appendEphemeralOverlayMessages(alloc, &messages, ephemeral_overlay);
    try messages.appendSlice(alloc, durable_history);
    try messages.append(alloc, current_user_message);
    try messages.appendSlice(alloc, within_turn_suffix);
    return messages;
}

fn appendEphemeralOverlayMessages(alloc: Allocator, messages: *std.ArrayList(ChatMessage), ephemeral_overlay: []const ChatMessage) !void {
    for (ephemeral_overlay) |overlay_message| {
        var copy = overlay_message;
        copy.cache_policy = .no_cache;
        try messages.append(alloc, copy);
    }
}
