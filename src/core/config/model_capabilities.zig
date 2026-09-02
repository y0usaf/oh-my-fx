const std = @import("std");
const types = @import("../shared/types.zig");

pub const ResolvedProviderOptions = struct {
    reasoning: ?types.ReasoningEffort = null,
    fast: bool = false,
    parallel_tool_calls: ?bool = null,
    prompt_caching: bool = false,
};

pub const ReasoningEffortOptions = struct {
    values: [types.ReasoningEffort.max_options]types.ReasoningEffort = undefined,
    len: usize = 0,

    pub fn fromSlice(source: []const types.ReasoningEffort) ReasoningEffortOptions {
        var result: ReasoningEffortOptions = .{};
        result.len = @min(source.len, result.values.len);
        for (source[0..result.len], 0..) |value, index| result.values[index] = value;
        return result;
    }

    pub fn slice(self: *const ReasoningEffortOptions) []const types.ReasoningEffort {
        return self.values[0..self.len];
    }
};

pub const GatewayMetadata = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    supports_fast_mode: bool = false,
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const Capabilities = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    supports_fast_mode: bool = false,
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    prompt_caching: bool = false,
    parallel_tool_calls: ?bool = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const ResolveError = error{Cancelled};

pub const Resolver = struct {
    ctx: *anyopaque,
    resolve_fn: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        model: []const u8,
    ) ResolveError!Capabilities,

    pub fn resolve(self: Resolver, arena: std.mem.Allocator, model: []const u8) ResolveError!Capabilities {
        return self.resolve_fn(self.ctx, arena, model);
    }
};

pub fn mergeCapabilities(capabilities_value: Capabilities, gateway_metadata: ?GatewayMetadata) Capabilities {
    var capabilities = capabilities_value;
    if (gateway_metadata) |metadata| {
        capabilities.supports_reasoning = metadata.supports_reasoning or metadata.reasoning_efforts.len > 0;
        capabilities.reasoning_efforts = metadata.reasoning_efforts;
        capabilities.supports_fast_mode = metadata.supports_fast_mode;
        capabilities.supports_tool_use = metadata.supports_tool_use;
        capabilities.supports_vision = metadata.supports_vision;
        capabilities.supports_file_input = metadata.supports_file_input;
        capabilities.supports_web_search = metadata.supports_web_search;
        capabilities.supports_explicit_caching = metadata.supports_explicit_caching;
        capabilities.supports_implicit_caching = metadata.supports_implicit_caching;
        if (metadata.context_window) |window| capabilities.context_window = window;
        if (metadata.max_output_tokens) |tokens| capabilities.max_output_tokens = tokens;
    }
    return capabilities;
}

pub fn resolveCapabilities(_: []const u8, gateway_metadata: ?GatewayMetadata) Capabilities {
    return mergeCapabilities(.{}, gateway_metadata);
}

pub fn capabilitiesForModel(model: []const u8) Capabilities {
    return resolveCapabilities(model, null);
}

pub fn resolveForApp(comptime App: type, app: *App, model: []const u8) Capabilities {
    if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
        return app.resolvedModelCapabilities(model);
    }
    return capabilitiesForModel(model);
}

pub fn reasoningEffortSupported(capabilities: Capabilities, effort: types.ReasoningEffort) bool {
    if (effort.isDefault()) return true;
    for (capabilities.reasoning_efforts.slice()) |option| {
        if (option.eql(effort)) return true;
    }
    return false;
}

pub fn reasoningEffortIndex(capabilities: Capabilities, effort: types.ReasoningEffort) usize {
    if (effort.isDefault()) return 0;
    for (capabilities.reasoning_efforts.slice(), 0..) |option, i| {
        if (option.eql(effort)) return i + 1;
    }
    return 0;
}

pub fn reasoningEffortAtIndex(capabilities: Capabilities, index: usize) types.ReasoningEffort {
    if (index == 0 or capabilities.reasoning_efforts.len == 0) return .auto;
    return capabilities.reasoning_efforts.values[(index - 1) % capabilities.reasoning_efforts.len];
}

pub fn reasoningEffortLabelAtIndex(capabilities: *const Capabilities, index: usize) []const u8 {
    if (index == 0 or capabilities.reasoning_efforts.len == 0) return "default";
    return capabilities.reasoning_efforts.values[(index - 1) % capabilities.reasoning_efforts.len].displayLabel();
}

pub fn reasoningEffortOptionCount(capabilities: Capabilities) usize {
    return if (capabilities.reasoning_efforts.len == 0) 0 else capabilities.reasoning_efforts.len + 1;
}

pub fn resolveProviderOptionsForCapabilities(
    capabilities: Capabilities,
    effort: types.ReasoningEffort,
    fast_mode: bool,
) ResolvedProviderOptions {
    var resolved: ResolvedProviderOptions = .{
        .parallel_tool_calls = capabilities.parallel_tool_calls,
        .prompt_caching = capabilities.prompt_caching,
    };
    if (!effort.isDefault() and reasoningEffortSupported(capabilities, effort)) {
        resolved.reasoning = effort;
    }
    resolved.fast = fast_mode and capabilities.supports_fast_mode;
    return resolved;
}
