const std = @import("std");
const definitions = @import("definitions.zig");

const continuation_prefix = "Continue the turn. fx hook context:\n";

pub const StopInput = definitions.StopInput;
pub const StopAction = definitions.StopAction;
pub const StopOutcome = definitions.StopOutcome;
pub const StopHandler = definitions.StopHandler;

pub fn buildContinuationMessage(
    alloc: std.mem.Allocator,
    context: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}{s}",
        .{ continuation_prefix, context },
    );
}

pub fn joinVisibleSegments(
    alloc: std.mem.Allocator,
    first: ?[]const u8,
    second: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    const earlier = first orelse "";
    const later = second orelse "";
    if (earlier.len == 0) return alloc.dupe(u8, later);
    if (later.len == 0) return alloc.dupe(u8, earlier);
    return std.fmt.allocPrint(alloc, "{s}\n{s}", .{ earlier, later });
}


