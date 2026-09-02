const std = @import("std");
const types = @import("types.zig");

/// Role assigned to a request message.
pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

/// Tool call emitted by the gateway and replayed in assistant messages.
pub const ToolCall = types.ToolCall;

/// Content carried by a request message.
pub const Content = union(enum) {
    text: []const u8,

    /// Returns the borrowed text for the active content variant.
    pub fn asText(self: Content) []const u8 {
        return switch (self) {
            .text => |value| value,
        };
    }
};

/// One role-tagged request message. Explicit flags track ownership because
/// `ToolCall` byte slices do not encode it at the type level.
pub const Message = struct {
    role: Role,
    content: ?Content = null,
    images: []const types.ImageAttachment = &.{},
    tool_calls: []const ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_result_status: ?types.PersistedToolStatus = null,
    tool_result_memory: ?types.ToolResultMemory = null,
    permission_feedback: bool = false,
    owns_content: bool = false,
    owns_tool_calls: bool = false,

    /// Builds a borrowed system message.
    pub fn systemText(text: []const u8) Message {
        return .{
            .role = .system,
            .content = .{ .text = text },
        };
    }

    /// Builds an owned system message; caller transfers ownership of text to the Message; Message.deinit will free it.
    pub fn systemOwned(text: []u8) Message {
        return .{
            .role = .system,
            .content = .{ .text = text },
            .owns_content = true,
        };
    }

    /// Builds a borrowed user message.
    pub fn userText(text: []const u8) Message {
        return .{
            .role = .user,
            .content = .{ .text = text },
        };
    }

    /// Builds an owned user message; caller transfers ownership of text to the Message.
    pub fn userOwned(text: []u8) Message {
        return .{
            .role = .user,
            .content = .{ .text = text },
            .owns_content = true,
        };
    }

    /// Builds an assistant message that owns content and tool-call slices.
    pub fn assistantOwned(content: ?[]const u8, tool_calls: []const ToolCall) Message {
        return .{
            .role = .assistant,
            .content = if (content) |text| .{ .text = text } else null,
            .tool_calls = tool_calls,
            .owns_content = content != null,
            .owns_tool_calls = tool_calls.len > 0,
        };
    }

    /// Builds an assistant message that borrows content and tool-call slices.
    pub fn assistantBorrowed(content: ?[]const u8, tool_calls: []const ToolCall) Message {
        return .{
            .role = .assistant,
            .content = if (content) |text| .{ .text = text } else null,
            .tool_calls = tool_calls,
        };
    }

    /// Builds a tool-result message that owns the result text.
    pub fn toolOwned(
        content: []u8,
        tool_call_id: []const u8,
        tool_name: []const u8,
        status: types.PersistedToolStatus,
    ) Message {
        return .{
            .role = .tool,
            .content = .{ .text = content },
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .tool_result_status = status,
            .owns_content = true,
        };
    }

    /// Frees owned message fields and leaves borrowed fields untouched.
    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        if (self.owns_content) {
            if (self.content) |content| alloc.free(content.asText());
        }
        if (self.owns_tool_calls) freeToolCalls(alloc, self.tool_calls);
        self.* = .{ .role = .user };
    }
};

/// Full message list consumed by one streamed gateway request.
pub const Request = struct {
    messages: []const Message,
    tool_choice: types.ToolChoice = .auto,

    /// Wraps a borrowed conversation slice owned by the caller.
    pub fn init(messages: []const Message) Request {
        return .{ .messages = messages };
    }

    pub fn initWithToolChoice(messages: []const Message, tool_choice: types.ToolChoice) Request {
        return .{ .messages = messages, .tool_choice = tool_choice };
    }
};

/// Frees an owned tool-call slice returned by the gateway.
pub fn freeToolCalls(alloc: std.mem.Allocator, tool_calls: []const ToolCall) void {
    for (tool_calls) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
        if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
        if (call.provider_result) |provider_result| alloc.free(provider_result);
    }
    if (tool_calls.len > 0) alloc.free(tool_calls);
}








