const std = @import("std");

const builtin_tools = @import("tools.zig");
const mode_contract = @import("../core/modes/mode_contract.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const tool_projection = @import("../core/tooling/tool_projection.zig");

pub const ModeSpec = mode_contract.ModeSpec;
pub const ToolPolicy = mode_contract.ToolPolicy;
pub const default_mode_id = "ask";

pub const all = [_]ModeSpec{
    .{ .id = "code", .name = "Code", .description = "Write and modify code with full tool access", .permission_mode = .auto },
    .{ .id = "ask", .name = "Ask", .description = "Request permission before making any changes", .permission_mode = .ask },
};

pub const registry = mode_registry.Registry{
    .default_mode_id = default_mode_id,
    .modes = all[0..],
};

pub fn lookup(id: []const u8) ?*const ModeSpec {
    return registry.lookup(id);
}
