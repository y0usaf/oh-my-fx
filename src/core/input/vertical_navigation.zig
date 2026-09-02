const std = @import("std");
const editor_state = @import("editor_state.zig");
const registered_entities = @import("registered_entities.zig");

const Decision = union(enum) {
    reset,
    move: struct {
        raw_offset: usize,
        preferred_column: usize,
    },
};

fn decideTarget(
    input: []const u8,
    entities: *const registered_entities.State,
    target_raw_offset: ?usize,
    preferred_column: usize,
) Decision {
    const raw_offset = target_raw_offset orelse return .reset;
    if (entities.entityContaining(input, raw_offset) != null) return .reset;
    return .{ .move = .{
        .raw_offset = raw_offset,
        .preferred_column = preferred_column,
    } };
}

/// Owns the sticky display-column intent for composer vertical navigation.
/// Terminal layout adapters provide target offsets and measured columns.
pub const State = struct {
    preferred_column: ?usize = null,

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    pub fn preferredColumn(self: State) ?usize {
        return self.preferred_column;
    }

    pub fn applyTarget(
        self: *State,
        edit: *editor_state.State,
        entities: *const registered_entities.State,
        target_raw_offset: ?usize,
        preferred_column: usize,
    ) bool {
        return self.applyTargetWithSelection(
            edit,
            entities,
            target_raw_offset,
            preferred_column,
            false,
        );
    }

    pub fn applyTargetWithSelection(
        self: *State,
        edit: *editor_state.State,
        entities: *const registered_entities.State,
        target_raw_offset: ?usize,
        preferred_column: usize,
        extend_selection: bool,
    ) bool {
        switch (decideTarget(
            edit.input.items,
            entities,
            target_raw_offset,
            preferred_column,
        )) {
            .reset => {
                self.reset();
                return false;
            },
            .move => |target| {
                _ = edit.moveCursorTo(target.raw_offset, extend_selection);
                self.preferred_column = target.preferred_column;
                return true;
            },
        }
    }
};




