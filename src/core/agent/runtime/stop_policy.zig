const std = @import("std");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;

const NonLiveBackgroundContext = struct {
    command: []const u8,
    log_path: []const u8,
    state: []const u8,
};

pub fn blockedNonLiveBackgroundRestart(
    arena: Allocator,
    messages: []const ChatMessage,
    call: ToolCall,
    prompt: []const u8,
) !?[]const u8 {
    const command = terminalStartCommand(arena, call) orelse return null;
    if (promptExplicitlyRequestsBackgroundStart(prompt)) return null;

    const context = findNonLiveBackgroundContextForCommand(messages, command) orelse
        return null;
    debug_trace.logf(
        "background",
        "blocked restart of non-live background command state={s} log={s}",
        .{ context.state, context.log_path },
    );
    const output: []const u8 = try std.fmt.allocPrint(
        arena,
        "Blocked restarting non-live background command from history. Runtime context says command={s}; log={s}; state={s}. Answer from that state unless the user explicitly asks to start it again.",
        .{ context.command, context.log_path, context.state },
    );
    return output;
}

fn terminalStartCommand(arena: Allocator, call: ToolCall) ?[]const u8 {
    if (!std.mem.eql(u8, call.name, "terminal")) return null;

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        arena,
        call.arguments_json,
        .{},
    ) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const action = parsed.value.object.get("action") orelse return null;
    if (action != .string or !std.mem.eql(u8, action.string, "start")) return null;
    const command = parsed.value.object.get("command") orelse return null;
    if (command != .string) return null;
    return command.string;
}

fn findNonLiveBackgroundContextForCommand(
    messages: []const ChatMessage,
    command: []const u8,
) ?NonLiveBackgroundContext {
    for (messages) |message_item| {
        if (message_item.role != .system) continue;
        const content = message_item.content orelse continue;
        if (std.mem.find(
            u8,
            content,
            "previous background command history includes command(s) that are no longer live",
        ) == null) continue;

        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, content, search_start, "- command=")) |prefix_index| {
            const command_start = prefix_index + "- command=".len;
            const log_marker = std.mem.indexOfPos(u8, content, command_start, "; log=") orelse break;
            const log_start = log_marker + "; log=".len;
            const state_marker = std.mem.indexOfPos(u8, content, log_start, "; state=") orelse break;
            const state_start = state_marker + "; state=".len;
            const line_end = std.mem.indexOfScalarPos(u8, content, state_start, '\n') orelse content.len;

            const context_command = std.mem.trim(u8, content[command_start..log_marker], " \t\r\n");
            if (std.mem.eql(u8, context_command, std.mem.trim(u8, command, " \t\r\n"))) {
                return .{
                    .command = context_command,
                    .log_path = std.mem.trim(u8, content[log_start..state_marker], " \t\r\n"),
                    .state = std.mem.trim(u8, content[state_start..line_end], " \t\r\n"),
                };
            }
            search_start = line_end;
        }
    }
    return null;
}

fn promptExplicitlyRequestsBackgroundStart(prompt: []const u8) bool {
    if (containsPhraseIgnoreCase(prompt, "do not run")) return false;
    if (containsPhraseIgnoreCase(prompt, "do not restart")) return false;
    if (containsPhraseIgnoreCase(prompt, "do not start")) return false;
    if (containsPhraseIgnoreCase(prompt, "don't run")) return false;
    if (containsPhraseIgnoreCase(prompt, "don't restart")) return false;
    if (containsPhraseIgnoreCase(prompt, "don't start")) return false;
    if (containsPhraseIgnoreCase(prompt, "without running")) return false;
    if (containsPhraseIgnoreCase(prompt, "without restarting")) return false;
    if (containsPhraseIgnoreCase(prompt, "without starting")) return false;

    return containsWordIgnoreCase(prompt, "restart") or
        containsPhraseIgnoreCase(prompt, "start it") or
        containsPhraseIgnoreCase(prompt, "start the") or
        containsPhraseIgnoreCase(prompt, "start this") or
        containsPhraseIgnoreCase(prompt, "run it") or
        containsPhraseIgnoreCase(prompt, "run the") or
        containsPhraseIgnoreCase(prompt, "run this") or
        containsPhraseIgnoreCase(prompt, "launch it") or
        containsPhraseIgnoreCase(prompt, "launch the") or
        containsPhraseIgnoreCase(prompt, "launch this");
}

fn containsPhraseIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) continue;
        const before_ok = index == 0 or !isAsciiWordByte(haystack[index - 1]);
        const after_index = index + needle.len;
        const after_ok = after_index == haystack.len or
            !isAsciiWordByte(haystack[after_index]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isAsciiWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn toolCall(id: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = "terminal", .arguments_json = args };
}

