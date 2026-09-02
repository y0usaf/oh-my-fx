const std = @import("std");

const mode_contract = @import("mode_contract.zig");
const tool_projection = @import("../tooling/tool_projection.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");

pub const ModeSpec = mode_contract.ModeSpec;

pub const Registry = struct {
    default_mode_id: []const u8,
    modes: []const ModeSpec = &.{},

    pub fn lookup(self: Registry, id: []const u8) ?*const ModeSpec {
        for (self.modes) |*mode| {
            if (std.mem.eql(u8, mode.id, id)) return mode;
        }
        return null;
    }

    pub fn buildModelToolProjection(
        self: Registry,
        alloc: std.mem.Allocator,
        tool_set: tool_set_contract.ToolSet,
        id: []const u8,
        options: tool_projection.Options,
    ) !tool_projection.EffectiveToolProjection {
        const mode = self.lookup(id) orelse
            return tool_projection.buildModelToolProjectionForSet(alloc, tool_set, options);
        return switch (mode.tool_policy) {
            .full => tool_projection.buildModelToolProjectionForSet(alloc, tool_set, options),
            .read_only => tool_projection.buildReadOnlyModelToolProjectionForSet(alloc, tool_set, options),
        };
    }

    pub fn toolAllowed(
        self: Registry,
        tool_set: tool_set_contract.ToolSet,
        id: []const u8,
        tool_name: []const u8,
    ) bool {
        if (tool_set.registry.lookup(tool_name) == null) return true;
        const mode = self.lookup(id) orelse return true;
        return switch (mode.tool_policy) {
            .full => true,
            .read_only => nameInSet(tool_set.read_only_tool_names, tool_name),
        };
    }

    pub fn toolPolicyDeniedJson(
        self: Registry,
        alloc: std.mem.Allocator,
        tool_set: tool_set_contract.ToolSet,
        id: []const u8,
        tool_name: []const u8,
    ) !?[]u8 {
        if (self.toolAllowed(tool_set, id, tool_name)) return null;
        const mode = self.lookup(id) orelse return null;
        const reason = mode.tool_policy_denial_message orelse
            "Tool blocked by the active mode policy.";
        return try tool_result_errors.preToolUseBlockedJson(alloc, tool_name, reason);
    }
};

fn nameInSet(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}


