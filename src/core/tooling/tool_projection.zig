const std = @import("std");
const model_tool_schema = @import("model_tool_schema.zig");
const mcp_runtime = @import("../mcp/mcp_runtime.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_set_contract = @import("tool_set.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    permission_mode: types.PermissionMode = .auto,
    permission_rules: types.PermissionRuleSet = .{},
    mcp_runtime: ?*mcp_runtime.McpRuntime = null,
    subagent_available: bool = false,
};

const BuildKind = enum { full, read_only };

const TestInput = struct {};

fn testInputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    alloc.destroy(@as(*TestInput, @ptrCast(@alignCast(ptr))));
}

fn decodeTestInput(ctx: tool_dispatch.DispatchContext, _: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(TestInput);
    input.* = .{};
    return .{ .input = .{ .ptr = input, .deinit_fn = testInputDeinit } };
}

fn callTestTool(ctx: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, "test tool result") };
}

fn testToolReadsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

fn testToolIsIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const test_tool_seed = tool_dispatch.Tool{
    .name = "test_tool",
    .description = "Test registered tool.",
    .model_schema = .{
        .name = "test_tool",
        .description = "Test registered tool.",
    },
    .decode = decodeTestInput,
    .call = callTestTool,
    .reads_only_fn = testToolReadsOnly,
    .irreversible_fn = testToolIsIrreversible,
};

const test_read_file = blk: {
    var spec = test_tool_seed;
    spec.name = "read_file";
    spec.description = "Test file read. When to use: exercise registered read projection. When NOT to use: assert product-specific filesystem behavior.";
    spec.model_schema = .{
        .name = "read_file",
        .description = spec.description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "path", .json_type = .string },
            },
            .required = &.{"path"},
        },
    };
    spec.executor_kind = .read_file;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Reading";
    spec.completed_action_label = "Read";
    spec.label_arg_kind = .path;
    spec.label_arg_default = "file";
    spec.permission_target_kind = .path_existing;
    break :blk spec;
};

fn writeTestWebSearchProviderAdvertisement(
    _: Allocator,
    writer: *std.Io.Writer,
) tool_dispatch.ProviderAdvertisementError!void {
    try writer.writeAll("{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"args\":{}}");
}

const test_web_fetch = blk: {
    var spec = test_read_file;
    spec.name = "web_fetch";
    spec.model_schema = .{
        .name = "web_fetch",
        .description = spec.description,
    };
    spec.executor_kind = .web_fetch;
    spec.label_arg_kind = .url;
    spec.label_arg_default = "url";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_web_search_base = blk: {
    var spec = test_web_fetch;
    spec.name = "web_search";
    spec.description = "Test web search guidance.";
    spec.model_schema = .{
        .name = "web_search",
        .description = spec.description,
    };
    spec.executor_kind = .web_search;
    spec.label_arg_kind = .query;
    spec.label_arg_default = "web";
    break :blk spec;
};

const test_web_search = blk: {
    var spec = test_web_search_base;
    spec.write_provider_advertisement_fn = writeTestWebSearchProviderAdvertisement;
    spec.provider_executed = true;
    break :blk spec;
};

const test_skill = blk: {
    var spec = test_read_file;
    spec.name = "skill";
    spec.description = "Test skill. When to use: exercise registered skill projection. When NOT to use: assert product-specific skill loading.";
    spec.model_schema = .{
        .name = "skill",
        .description = spec.description,
    };
    spec.executor_kind = .skill;
    spec.activity_kind = .read;
    spec.requires_approval = false;
    spec.action_label = "Loading skill";
    spec.completed_action_label = "Loaded skill";
    spec.label_arg_kind = .name;
    spec.label_arg_default = "skill";
    spec.permission_target_kind = .none;
    break :blk spec;
};

const test_install_skill = blk: {
    var spec = test_skill;
    spec.name = "install_skill";
    spec.description = "Test install skill. When to use: exercise registered write-tool projection. When NOT to use: assert product-specific installation behavior.";
    spec.model_schema = .{
        .name = "install_skill",
        .description = spec.description,
    };
    spec.executor_kind = .install_skill;
    spec.activity_kind = .write;
    spec.requires_approval = true;
    spec.action_label = "Installing skill";
    spec.completed_action_label = "Installed skill";
    spec.label_arg_kind = .source;
    break :blk spec;
};

pub const EffectiveToolProjection = struct {
    /// Borrowed registry names selected for model advertisement. The slice
    /// storage is owned by this projection.
    advertised_names: []const []const u8,
    /// Exact borrowed built-in schemas selected for model advertisement. The
    /// slice storage is owned by this projection.
    advertised_functions: []const model_tool_schema.FunctionSchema,
    custom_guidance: []u8,

    pub fn deinit(self: *EffectiveToolProjection, alloc: Allocator) void {
        alloc.free(self.advertised_names);
        alloc.free(self.advertised_functions);
        alloc.free(self.custom_guidance);
        self.* = undefined;
    }
};

pub fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

pub fn buildModelToolProjectionForSet(alloc: Allocator, tool_set: tool_set_contract.ToolSet, options: Options) !EffectiveToolProjection {
    return buildToolProjection(alloc, tool_set, .full, options);
}

pub fn buildReadOnlyModelToolProjectionForSet(alloc: Allocator, tool_set: tool_set_contract.ToolSet, options: Options) !EffectiveToolProjection {
    return buildToolProjection(alloc, tool_set, .read_only, options);
}

fn buildToolProjection(alloc: Allocator, tool_set: tool_set_contract.ToolSet, kind: BuildKind, options: Options) !EffectiveToolProjection {
    var advertised_names: std.ArrayList([]const u8) = .empty;
    errdefer advertised_names.deinit(alloc);
    var advertised_functions: std.ArrayList(model_tool_schema.FunctionSchema) = .empty;
    errdefer advertised_functions.deinit(alloc);
    var guidance_out: std.Io.Writer.Allocating = .init(alloc);
    errdefer guidance_out.deinit();

    var first_custom_guidance = true;

    for (tool_set.order) |tool_name| {
        const tool = tool_set.registry.lookup(tool_name) orelse continue;
        try appendBuiltinTool(alloc, &advertised_names, &advertised_functions, &guidance_out.writer, &first_custom_guidance, tool.*, kind, tool_set, options);
    }

    if (kind == .full) {
        for (tool_set.registry.tools) |tool| {
            if (isCanonicalToolName(tool_set, tool.name)) continue;
            try appendBuiltinTool(alloc, &advertised_names, &advertised_functions, &guidance_out.writer, &first_custom_guidance, tool, kind, tool_set, options);
        }
    }

    const custom_guidance = try guidance_out.toOwnedSlice();
    errdefer alloc.free(custom_guidance);
    const names = try advertised_names.toOwnedSlice(alloc);
    errdefer alloc.free(names);
    const functions = try advertised_functions.toOwnedSlice(alloc);
    return .{
        .advertised_names = names,
        .advertised_functions = functions,
        .custom_guidance = custom_guidance,
    };
}
fn appendBuiltinTool(
    alloc: Allocator,
    advertised_names: *std.ArrayList([]const u8),
    advertised_functions: *std.ArrayList(model_tool_schema.FunctionSchema),
    guidance_writer: *std.Io.Writer,
    first_custom_guidance: *bool,
    tool: tool_dispatch.Tool,
    kind: BuildKind,
    tool_set: tool_set_contract.ToolSet,
    options: Options,
) !void {
    if (!tool.model_visible) return;
    if (!includeBuiltinForKind(tool.name, kind, tool_set)) return;
    if (std.mem.eql(u8, tool.name, "subagent") and !options.subagent_available) return;
    if (std.mem.eql(u8, tool.name, "vision")) return;
    if (options.permission_mode != .yolo) {
        if (tool.provider_executed and !providerExecutionIsAllowed(tool.name, options.permission_rules)) return;
        if (permissions.rulesDenyAllTargetsForTool(options.permission_rules, tool.name)) return;
    }
    try advertised_names.append(alloc, tool.name);
    if (!tool.provider_executed and tool.write_provider_advertisement_fn == null) {
        try advertised_functions.append(alloc, tool.model_schema);
    }
    if (tool.write_provider_advertisement_fn != null) {
        if (first_custom_guidance.*) {
            first_custom_guidance.* = false;
        } else {
            try guidance_writer.writeAll("\n\n");
        }
        try guidance_writer.writeAll(tool.description);
    }
}

/// A provider-executed tool is never dispatched locally, so an unsettled `ask`
/// hides it exactly like a `deny`. The tool name doubles as the target pattern
/// because the provider owns the call and fx never sees its arguments.
fn providerExecutionIsAllowed(tool_name: []const u8, rules: types.PermissionRuleSet) bool {
    const permission = permissions.permissionNameForTool(tool_name);
    return switch (permissions.ruleDecisionForPermissionPattern(rules, permission, tool_name, .none)) {
        .none, .allow => true,
        .ask, .deny => false,
    };
}

fn includeBuiltinForKind(tool_name: []const u8, kind: BuildKind, tool_set: tool_set_contract.ToolSet) bool {
    const names = builtinNamesForKind(kind, tool_set) orelse return true;
    return toolNameInSet(names, tool_name);
}

fn builtinNamesForKind(kind: BuildKind, tool_set: tool_set_contract.ToolSet) ?[]const []const u8 {
    return switch (kind) {
        .full => null,
        .read_only => tool_set.read_only_tool_names,
    };
}

fn toolNameInSet(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn isCanonicalToolName(tool_set: tool_set_contract.ToolSet, name: []const u8) bool {
    for (tool_set.order) |tool_name| {
        if (std.mem.eql(u8, tool_name, name)) return true;
    }
    return false;
}

fn expectNotContainsName(names: []const []const u8, expected: []const u8) !void {
    for (names) |name| {
        if (std.mem.eql(u8, name, expected)) return error.TestExpectedEqual;
    }
}

fn indexOfName(names: []const []const u8, expected: []const u8) !usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, expected)) return index;
    }
    return error.TestExpectedEqual;
}
