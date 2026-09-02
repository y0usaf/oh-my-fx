const std = @import("std");

pub const Policy = enum {
    finality_gated,
    append_only,
};

pub const ToolTurnFloor = struct {
    turn_id: u64,
    start_byte: usize,
};

/// Activity-independent finality boundaries for one prepared transcript flow.
/// `tool_turn_floors` is owned when populated and must be released with the
/// allocator that created or cloned it.
pub const Candidates = struct {
    mutation_pin_start: ?usize = null,
    assistant_tail_start: ?usize = null,
    tool_turn_floors: []const ToolTurnFloor = &.{},

    pub fn deinit(self: *Candidates, alloc: std.mem.Allocator) void {
        if (self.tool_turn_floors.len > 0) alloc.free(self.tool_turn_floors);
        self.* = .{};
    }

    pub fn clone(self: *const Candidates, alloc: std.mem.Allocator) !Candidates {
        return .{
            .mutation_pin_start = self.mutation_pin_start,
            .assistant_tail_start = self.assistant_tail_start,
            .tool_turn_floors = if (self.tool_turn_floors.len == 0)
                &.{}
            else
                try alloc.dupe(ToolTurnFloor, self.tool_turn_floors),
        };
    }
};

pub const State = struct {
    policy: Policy = .finality_gated,
    assistant_tail_writable: bool = true,

    pub fn with_assistant_tail_writable(self: State, writable: bool) State {
        var next = self;
        next.assistant_tail_writable = writable;
        return next;
    }

    /// Returns the earliest byte that is not final, or null when the entire
    /// prepared flow may enter native terminal history.
    pub fn finality_floor(
        self: State,
        candidates: Candidates,
        finalized_tool_turn_watermark: u64,
        replaceable_start: ?usize,
    ) ?usize {
        if (self.policy == .append_only) return null;

        var floor = candidates.mutation_pin_start;
        for (candidates.tool_turn_floors) |turn_floor| {
            if (turn_floor.turn_id <= finalized_tool_turn_watermark) continue;
            floor = earlier(floor, turn_floor.start_byte);
        }
        if (replaceable_start) |start| floor = earlier(floor, start);
        if (self.assistant_tail_writable) {
            if (candidates.assistant_tail_start) |start| {
                floor = earlier(floor, start);
            }
        }
        return floor;
    }
};

fn earlier(current: ?usize, candidate: usize) usize {
    return if (current) |value| @min(value, candidate) else candidate;
}



