const std = @import("std");
const builtin_tools = @import("../../../../builtins/tools.zig");
const model_tool_schema = @import("../../../tooling/model_tool_schema.zig");
const types = @import("../../../shared/types.zig");
const session_runtime = @import("../../../session/session.zig");
const session_child_store = @import("../../../session/session_child_store.zig");
const command_replay_store = @import("../../../session/command_replay_store.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const io_mod = @import("../../../shared/io.zig");

const test_support = @import("support.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;
const ToolCall = types.ToolCall;

const removed_direct_question_guidance = "Treat it as interrupting any previous tool plan.";
const removed_resume_guidance = "Continue from the latest meaningful state";
const read_file_advertised_names = [_][]const u8{"read_file"};
const read_file_advertised_functions = [_]model_tool_schema.FunctionSchema{builtin_tools.read_file.model_schema};

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const PromptFixture = test_support.PromptFixture;

const runFakePrompt = test_support.runFakePrompt;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyNotContains = test_support.expectBodyNotContains;
const expectBodyContainsInOrder = test_support.expectBodyContainsInOrder;
const expectGatewayPromptFinalUserText = test_support.expectGatewayPromptFinalUserText;
const readTraceFile = test_support.readTraceFile;
const logIndex = test_support.logIndex;
const toolCall = test_support.toolCall;

const ExpectedToolTerminal = struct {
    call_id: []const u8,
    kind: types.ToolOutcomeKind,
};

fn expectToolTerminalsBeforeTurnFinished(
    hooks: *const FakeAgentRuntimeDeps,
    expected: []const ExpectedToolTerminal,
) !void {
    const turn_finished_index = logIndex(hooks, "event:turn_finished") orelse
        return error.TestMissingTurnFinalization;
    var terminal_log_count: usize = 0;
    for (hooks.log.items, 0..) |entry, entry_index| {
        if (!std.mem.startsWith(u8, entry, "status:finished:")) continue;
        terminal_log_count += 1;
        try std.testing.expect(entry_index < turn_finished_index);
    }
    try std.testing.expectEqual(expected.len, terminal_log_count);

    for (expected) |wanted| {
        var terminal_count: usize = 0;
        for (hooks.lifecycle_events.items) |event| {
            if (event != .terminal) continue;
            try std.testing.expect(!std.mem.eql(
                u8,
                event.terminal.outcome.summary,
                "Tool cancelled",
            ));
            if (!std.mem.eql(u8, event.terminal.id.call_id, wanted.call_id)) continue;
            terminal_count += 1;
            try std.testing.expectEqual(wanted.kind, event.terminal.outcome.kind);
        }
        try std.testing.expectEqual(@as(usize, 1), terminal_count);
    }
}

fn expectGatewayPromptRoleContentKinds(gateway: *const FakeGateway, index: usize) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    for (prompt) |entry| {
        try std.testing.expect(entry == .object);
        const role = entry.object.get("role") orelse return error.TestExpectedPromptRoleMissing;
        try std.testing.expect(role == .string);
        const content = entry.object.get("content") orelse return error.TestExpectedPromptMessageMissing;
        if (std.mem.eql(u8, role.string, "system")) {
            try std.testing.expect(content == .string);
        } else if (std.mem.eql(u8, role.string, "user") or
            std.mem.eql(u8, role.string, "assistant") or
            std.mem.eql(u8, role.string, "tool"))
        {
            try std.testing.expect(content == .array);
        } else {
            return error.TestUnexpectedPromptRole;
        }
    }
}
