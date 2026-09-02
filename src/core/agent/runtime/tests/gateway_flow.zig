const std = @import("std");
const agent_stream_provider = @import("../../stream_provider.zig");
const builtin_tools = @import("../../../../builtins/tools.zig");
const types = @import("../../../shared/types.zig");
const token_estimate = @import("../../../shared/token_estimate.zig");
const worker_runtime = @import("../../worker_runtime.zig");
const session_runtime = @import("../../../session/session.zig");
const session_codec = @import("../../../session/session_codec.zig");
const session_usage = @import("../../../session/session_usage.zig");
const model_capabilities = @import("../../../config/model_capabilities.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const image_attachments = @import("../../../images/image_attachments.zig");
const io_mod = @import("../../../shared/io.zig");
const runtime_deps = @import("../deps.zig");
const runtime_tool_contracts = @import("../tool_contracts.zig");
const context_limits = @import("../../../config/context_limits.zig");
const vision_executor = @import("../vision_executor.zig");
const diagnostics = @import("../../../workspace/diagnostics.zig");
const lifecycle_hooks = @import("../../../hooks/hooks.zig");
const tool_dispatch = @import("../../../tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../../tooling/model_tool_schema.zig");

const test_support = @import("support.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const ToolCall = types.ToolCall;
const QueuedPrompt = worker_runtime.QueuedPrompt;

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const ModelCapabilityOverride = test_support.ModelCapabilityOverride;
const PromptFixture = test_support.PromptFixture;
const ToolExecutionOverride = test_support.ToolExecutionOverride;
const VisionAgentToolRuntime = test_support.VisionAgentToolRuntime;
const ExecuteDelegate = test_support.ExecuteDelegate;
const ToolExecutionRequest = runtime_tool_contracts.ToolExecutionRequest;
const ToolExecutionResult = runtime_tool_contracts.ToolExecutionResult;

const runFakePrompt = test_support.runFakePrompt;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyNotContains = test_support.expectBodyNotContains;
const expectBodyContainsInOrder = test_support.expectBodyContainsInOrder;
const expectGatewayPromptFinalUserText = test_support.expectGatewayPromptFinalUserText;
const countPromptEntryText = test_support.countPromptEntryText;
const countText = test_support.countText;
const countNeedle = test_support.countNeedle;
const readTraceFile = test_support.readTraceFile;
const logIndex = test_support.logIndex;
const toolCall = test_support.toolCall;

const vision_and_read_file_tools = [_]tool_dispatch.Tool{
    builtin_tools.vision,
    builtin_tools.read_file,
};
const vision_read_and_terminal_tools = [_]tool_dispatch.Tool{
    builtin_tools.vision,
    builtin_tools.read_file,
    builtin_tools.terminal,
};
const terminal_advertised_names = [_][]const u8{"terminal"};
const terminal_advertised_functions = [_]model_tool_schema.FunctionSchema{builtin_tools.terminal.model_schema};

const VisionAndReadExecutor = struct {
    vision: ExecuteDelegate,

    fn delegate(self: *@This()) ExecuteDelegate {
        return .{
            .ctx = self,
            .run = execute,
            .set_agent_stream_provider = setAgentStreamProvider,
        };
    }

    fn setAgentStreamProvider(raw: *anyopaque, provider: agent_stream_provider.Provider) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.vision.set_agent_stream_provider) |set_provider| {
            set_provider(self.vision.ctx, provider);
        }
    }

    fn execute(raw: *anyopaque, request: ToolExecutionRequest) !ToolExecutionResult {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, request.call.name, "vision")) {
            return self.vision.run(self.vision.ctx, request);
        }
        if (std.mem.eql(u8, request.call.name, "read_file")) {
            return .{ .model_output = "ordinary read contents" };
        }
        return error.TestUnexpectedTool;
    }
};

fn lifecycleEventCallId(event: types.ToolLifecycleEvent) ?[]const u8 {
    return switch (event) {
        .provisional => |value| value.id.call_id,
        .authoritative_started => |value| value.id.call_id,
        .progress => |value| value.id.call_id,
        .terminal => |value| value.id.call_id,
        .turn_finished => null,
    };
}

fn expectNoLifecycleForCall(events: []const types.ToolLifecycleEvent, call_id: []const u8) !void {
    for (events) |event| {
        const event_call_id = lifecycleEventCallId(event) orelse continue;
        try std.testing.expect(!std.mem.eql(u8, event_call_id, call_id));
    }
}

fn expectFailedLifecycleContains(
    events: []const types.ToolLifecycleEvent,
    call_id: []const u8,
    needle: []const u8,
) !void {
    for (events) |event| {
        if (event != .terminal) continue;
        const terminal = event.terminal;
        if (!std.mem.eql(u8, terminal.id.call_id, call_id)) continue;
        try std.testing.expectEqual(types.ToolOutcomeKind.failed, terminal.outcome.kind);
        try std.testing.expect(std.mem.find(u8, terminal.outcome.summary, needle) != null);
        return;
    }
    return error.TestExpectedEqual;
}

fn expectNoticeContains(hooks: *const FakeAgentRuntimeDeps, index: usize, needle: []const u8) !void {
    try std.testing.expect(index < hooks.system_notices.items.len);
    try std.testing.expect(std.mem.find(u8, hooks.system_notices.items[index], needle) != null);
}

fn expectRouteStatus(
    hooks: *const FakeAgentRuntimeDeps,
    index: usize,
    kind: types.RouteRecoveryStatus.Kind,
    expected_label: []const u8,
) !void {
    try std.testing.expect(index < hooks.route_recovery_statuses.items.len);
    const status = hooks.route_recovery_statuses.items[index];
    try std.testing.expectEqual(kind, status.kind);
    var label_buf: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected_label, status.label(&label_buf));
}



fn makeOwnedProviderPrompt(alloc: Allocator, text: []const u8, model: []const u8) !QueuedPrompt {
    const prompt = try alloc.dupe(u8, text);
    errdefer alloc.free(prompt);
    const model_copy = try alloc.dupe(u8, model);
    errdefer alloc.free(model_copy);
    const api_key = try alloc.dupe(u8, "key");
    errdefer alloc.free(api_key);
    const history = try alloc.alloc(HistoryTurn, 0);
    errdefer alloc.free(history);
    const grants = try alloc.alloc(PermissionGrant, 0);
    errdefer alloc.free(grants);

    return .{
        .prompt = prompt,
        .images = &.{},
        .model = model_copy,
        .api_key = api_key,
        .permission_mode = .ask,
        .history = history,
        .grants = grants,
    };
}

fn expectPromptEntryRole(entry: std.json.Value, expected_role: types.ChatRole) !void {
    try std.testing.expect(entry == .object);
    const role = entry.object.get("role") orelse return error.TestExpectedPromptRoleMissing;
    try std.testing.expect(role == .string);
    try std.testing.expectEqualStrings(@tagName(expected_role), role.string);
}

fn expectGatewayPromptRoles(gateway: *const FakeGateway, index: usize, expected_roles: []const types.ChatRole) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expectEqual(expected_roles.len, prompt.len);
    for (expected_roles, 0..) |expected_role, i| {
        try expectPromptEntryRole(prompt[i], expected_role);
    }
}

fn expectGatewayPromptTailText(
    gateway: *const FakeGateway,
    index: usize,
    expected_role: types.ChatRole,
    expected_text: []const u8,
) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        gateway.request_bodies.items[index],
        .{},
    );
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expect(prompt.len > 0);
    const tail = prompt[prompt.len - 1];
    try expectPromptEntryRole(tail, expected_role);
    try std.testing.expectEqual(
        @as(usize, 1),
        countPromptEntryText(tail, expected_text),
    );
}

fn expectRootFieldAbsent(gateway: *const FakeGateway, index: usize, field: []const u8) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get(field) == null);
}

fn expectGatewayPromptStringEntry(gateway: *const FakeGateway, index: usize, entry_index: usize, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expect(entry_index < prompt.len);
    const entry = prompt[entry_index];
    try std.testing.expect(entry == .object);
    const content = entry.object.get("content") orelse return error.TestExpectedPromptMessageMissing;
    try std.testing.expect(content == .string);
    try std.testing.expectEqualStrings(expected, content.string);
}

fn expectGatewayToolResultOutput(
    gateway: *const FakeGateway,
    index: usize,
    tool_call_id: []const u8,
    expected: []const u8,
) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    for (prompt) |entry| {
        if (entry != .object) continue;
        const content = entry.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (part != .object) continue;
            const part_call_id = part.object.get("toolCallId") orelse continue;
            if (part_call_id != .string or !std.mem.eql(u8, part_call_id.string, tool_call_id)) continue;
            const output = part.object.get("output") orelse continue;
            if (output != .object) continue;
            const value = output.object.get("value") orelse continue;
            if (value != .string) continue;
            try std.testing.expectEqualStrings(expected, value.string);
            return;
        }
    }
    return error.TestExpectedPromptMessageMissing;
}

fn expectGatewayPromptTextCount(gateway: *const FakeGateway, index: usize, needle: []const u8, expected_count: usize) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    var count: usize = 0;
    for (prompt) |entry| count += countPromptEntryText(entry, needle);
    try std.testing.expectEqual(expected_count, count);
}

fn writeTestImagePath(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    {
        var file = try tmp.dir.createFile(std.testing.io, "fixture-image.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nfixture image bytes");
    }
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, "fixture-image.png");
}

fn testSnapshotDir(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "snapshots" });
}

fn testCapturedImage(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    image_path: []const u8,
    id: usize,
) !types.ImageAttachment {
    const source = [_]types.ImageAttachment{.{
        .id = id,
        .path = @constCast(image_path),
        .media_type = @constCast("image/png"),
    }};
    const owned = try types.dupeImageAttachmentSlice(alloc, &source);
    defer alloc.free(owned);

    var image = owned[0];
    errdefer types.freeImageAttachment(alloc, image);
    const snapshot_dir = try testSnapshotDir(alloc, tmp);
    defer alloc.free(snapshot_dir);
    try image_attachments.captureImageSnapshot(alloc, &image, snapshot_dir);
    return image;
}

fn freeImageSlice(alloc: Allocator, images: []types.ImageAttachment) void {
    for (images) |image| types.freeImageAttachment(alloc, image);
}

fn visionArgumentsForIds(alloc: Allocator, image_ids: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"image_ids\":[");
    for (image_ids, 0..) |image_id, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("{d}", .{image_id});
    }
    try out.writer.writeAll("],\"focus\":\"inspect all images\"}");
    return out.toOwnedSlice();
}

fn visionProviderResultForIds(alloc: Allocator, image_ids: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"images\":[");
    for (image_ids, 0..) |image_id, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print(
            "{{\"image_id\":{d},\"status\":\"ok\",\"summary\":\"image {d}\",\"visible_text\":[],\"details\":[]}}",
            .{ image_id, image_id },
        );
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn denseVisionProviderResult(alloc: Allocator) ![]u8 {
    const long_summary = try alloc.alloc(u8, 5000);
    defer alloc.free(long_summary);
    @memset(long_summary, 'x');

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(
        "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"dense evidence\",\"visible_text\":[",
    );
    for (0..40) |index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("\"visible item {d}\"", .{index});
    }
    try out.writer.writeAll("],\"details\":[]},{\"image_id\":2,\"status\":\"ok\",\"summary\":");
    try std.json.Stringify.value(long_summary, .{}, &out.writer);
    try out.writer.writeAll(",\"visible_text\":[],\"details\":[]}]}");
    return out.toOwnedSlice();
}

fn countVisionProviderCalls(gateway: *const FakeGateway) usize {
    var count: usize = 0;
    for (gateway.request_models.items) |request_model| {
        if (std.mem.eql(u8, request_model, "google/gemini-2.5-flash")) count += 1;
    }
    return count;
}

fn oversizedVisionProviderResult(alloc: Allocator, summary_bytes: usize) ![]u8 {
    const summary = try alloc.alloc(u8, summary_bytes);
    defer alloc.free(summary);
    @memset(summary, 'a');
    return std.fmt.allocPrint(
        alloc,
        "{{\"images\":[{{\"image_id\":1,\"status\":\"ok\",\"summary\":\"{s}\",\"visible_text\":[],\"details\":[]}}]}}",
        .{summary},
    );
}

/// Drives `vision_executor.execute` against a scripted provider so a single batch's
/// retry classification can be observed without the surrounding prompt pipeline.
const VisionProviderScript = struct {
    responses: []const Response,
    calls: usize = 0,

    const Response = union(enum) {
        content: []const u8,
        http_status: std.http.Status,
        cancel,
    };

    fn stream(
        context: ?*anyopaque,
        _: Allocator,
        request: agent_stream_provider.ModelRequest,
    ) anyerror!agent_stream_provider.Result {
        const self: *VisionProviderScript = @ptrCast(@alignCast(context.?));
        if (self.calls >= self.responses.len) return error.TestVisionScriptExhausted;
        const response = self.responses[self.calls];
        self.calls += 1;
        try request.admission.admit();
        return switch (response) {
            .content => |text| .{ .completed = .{ .completion = .{ .content = text } } },
            .http_status => |status| .{ .failed = .{ .kind = switch (status) {
                .unauthorized => .unauthorized,
                .too_many_requests => .rate_limited,
                .service_unavailable => .unavailable,
                else => .provider_error,
            } } },
            .cancel => blk: {
                request.cancel_flag.store(true, .seq_cst);
                break :blk .{ .completed = .{} };
            },
        };
    }
};

fn runScriptedVision(
    alloc: Allocator,
    script: *VisionProviderScript,
    catalog: []const types.ImageAttachment,
    args_json: []const u8,
    output_limit_bytes: usize,
) !runtime_tool_contracts.ToolExecutionResult {
    var provider = @import("../../../../builtins/gateway.zig").agent_stream_provider;
    provider.context = script;
    provider.stream_fn = VisionProviderScript.stream;
    return vision_executor.execute(alloc, args_json, catalog, .{
        .stream_provider = provider,
        .api_key = "key",
        .gateway_team = null,
        .retry_count = 1,
        .cancel_flag = null,
        .usage = null,
        .usage_allocator = alloc,
        .trace_ctx = .{},
        .output_limit = .{
            .value = .{ .bytes = output_limit_bytes },
            .source = .command_line,
        },
    });
}

fn expectGatewayPromptEntryCacheControl(gateway: *const FakeGateway, index: usize, needle: []const u8, expected: bool) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    for (prompt) |entry| {
        if (countPromptEntryText(entry, needle) == 0) continue;
        try std.testing.expectEqual(expected, entry.object.get("providerOptions") != null);
        return;
    }
    return error.TestExpectedPromptMessageMissing;
}

fn expectNoPromptCacheControlAfter(gateway: *const FakeGateway, index: usize, needle: []const u8) !void {
    try std.testing.expect(index < gateway.request_bodies.items.len);
    const body = gateway.request_bodies.items[index];
    const start = std.mem.indexOf(u8, body, needle) orelse return error.TestExpectedBodyNeedleMissing;
    try std.testing.expect(std.mem.find(u8, body[start..], "cacheControl") == null);
}







fn deleteLocallyFilteredSnapshots(images: []const types.ImageAttachment) !void {
    for (images) |image| {
        try std.Io.Dir.deleteFileAbsolute(std.testing.io, image.snapshot_path.?);
    }
}

















const scripted_vision_args = "{\"image_ids\":[1],\"focus\":\"inspect\"}";
const scripted_vision_ok =
    "{\"images\":[{\"image_id\":1,\"status\":\"ok\",\"summary\":\"retried evidence\"," ++
    "\"visible_text\":[],\"details\":[]}]}";

fn scriptedVisionCatalog(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    image_path: []const u8,
) !types.ImageAttachment {
    return testCapturedImage(alloc, tmp, image_path, 1);
}




























































































































