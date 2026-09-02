const std = @import("std");

pub const default_max_agent_steps: usize = 0;

pub fn resolveMaxAgentSteps(configured: ?usize, default_value: usize) usize {
    return configured orelse default_value;
}

pub fn parseMaxAgentSteps(raw: ?[]const u8) ?usize {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
}

pub fn resolveMaxAgentStepsWithOverride(
    configured: ?usize,
    default_value: usize,
    process_override: ?[]const u8,
) usize {
    return parseMaxAgentSteps(process_override) orelse resolveMaxAgentSteps(configured, default_value);
}

pub fn allowsStep(limit: usize, completed_steps: usize) bool {
    return limit == 0 or completed_steps < limit;
}
