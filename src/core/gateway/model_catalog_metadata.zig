const std = @import("std");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_catalog = @import("model_catalog.zig");
const types = @import("../shared/types.zig");

fn optionalPositiveU32(value: u32) ?u32 {
    return if (value == 0) null else value;
}

pub fn fromCatalogEntry(entry: model_catalog.ModelCatalogEntry) model_capabilities.GatewayMetadata {
    return .{
        .supports_reasoning = entry.has_reasoning,
        .reasoning_efforts = .fromSlice(entry.reasoning_efforts.items),
        .supports_fast_mode = entry.supports_fast_mode,
        .supports_tool_use = entry.has_tool_use,
        .supports_vision = entry.has_vision,
        .supports_file_input = entry.has_file_input,
        .supports_web_search = entry.has_web_search,
        .supports_explicit_caching = entry.has_explicit_caching,
        .supports_implicit_caching = entry.has_implicit_caching,
        .context_window = optionalPositiveU32(entry.context_window),
        .max_output_tokens = optionalPositiveU32(entry.max_tokens),
    };
}
