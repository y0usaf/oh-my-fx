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
