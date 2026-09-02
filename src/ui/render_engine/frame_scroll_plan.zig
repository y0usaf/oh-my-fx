const std = @import("std");

pub const FrameDocumentAppendClear = union(enum) {
    remainder,
    rows: u16,
};

pub const FrameDocumentAppend = struct {
    /// Terminal-wire bytes; every LF must be preceded by CR.
    bytes: []const u8 = &.{},
    start_row: u16 = 1,
    start_col: u16 = 1,
    clear: FrameDocumentAppendClear = .remainder,
    reset_replay: bool = false,

    pub fn isEmpty(self: FrameDocumentAppend) bool {
        return self.bytes.len == 0;
    }

    pub fn validatedStartCol(self: FrameDocumentAppend, target_cols: u16, target_rows: u16) !u16 {
        if (target_cols == 0 or target_rows == 0 or
            self.start_row == 0 or self.start_row > target_rows)
        {
            return error.InvalidFrameScrollPlan;
        }
        return @min(@max(self.start_col, 1), target_cols);
    }

    pub fn validatedClearBottom(self: FrameDocumentAppend, target_rows: u16) !?u16 {
        if (target_rows == 0 or self.start_row == 0 or self.start_row > target_rows) {
            return error.InvalidFrameScrollPlan;
        }
        return switch (self.clear) {
            .remainder => null,
            .rows => |rows| if (rows == 0)
                error.InvalidFrameScrollPlan
            else
                self.start_row + @min(rows, target_rows - self.start_row + 1) - 1,
        };
    }
};

pub const AcceptedScrollRows = struct {
    preserved_release_rows: u16,
    inline_advance_rows: u32,
};

pub const FrameScrollCommit = struct {
    physical_terminal_scroll_rows: u16,
    planned_terminal_scroll_rows: u16,
    expected_terminal_scroll_rows: u16,
    accepted_terminal_scroll_rows: u16,
    unplanned_terminal_scroll_rows: u16,
    accepted_rows: AcceptedScrollRows,

    pub fn complete(self: FrameScrollCommit) bool {
        return self.physical_terminal_scroll_rows >= self.expected_terminal_scroll_rows and
            self.unplanned_terminal_scroll_rows == 0;
    }

    pub fn matchesPlan(self: FrameScrollCommit, plan: FrameScrollPlan) bool {
        return std.meta.eql(
            self,
            plan.commitWithExpectedRows(
                self.physical_terminal_scroll_rows,
                self.expected_terminal_scroll_rows,
            ),
        );
    }
};

pub const TerminalMovementRows = struct {
    planned_scroll_rows: u16,
    materialized_scroll_rows: u16,
    alignment_scroll_rows: u16,
    expected_scroll_rows: u16,

    pub fn emittedScrollRows(self: TerminalMovementRows) u16 {
        return self.materialized_scroll_rows + self.alignment_scroll_rows;
    }

    pub fn resolve(
        planned_scroll_rows: u16,
        materialized_scroll_rows: u16,
        reset_replay: bool,
    ) !TerminalMovementRows {
        if (reset_replay) {
            return .{
                .planned_scroll_rows = planned_scroll_rows,
                .materialized_scroll_rows = materialized_scroll_rows,
                .alignment_scroll_rows = 0,
                .expected_scroll_rows = materialized_scroll_rows,
            };
        }
        if (materialized_scroll_rows > planned_scroll_rows) {
            return error.InvalidFrameScrollPlan;
        }
        return .{
            .planned_scroll_rows = planned_scroll_rows,
            .materialized_scroll_rows = materialized_scroll_rows,
            .alignment_scroll_rows = planned_scroll_rows - materialized_scroll_rows,
            .expected_scroll_rows = planned_scroll_rows,
        };
    }
};

pub const FrameScrollPlan = struct {
    prior_owned_top: u16,
    requested_release_rows: u16,
    requested_inline_advance_rows: u32,
    preserved_release_rows: u16,
    terminal_scroll_rows: u16,
    remaining_inline_advance_rows: u32,
    post_scroll_owned_top: u16,

    pub fn none(terminal_rows: u16, current_owned_top: u16) FrameScrollPlan {
        return merge(terminal_rows, current_owned_top, 0, 0);
    }

    pub fn validate(self: FrameScrollPlan, terminal_rows: u16) !void {
        const expected = merge(
            terminal_rows,
            self.prior_owned_top,
            self.requested_release_rows,
            self.requested_inline_advance_rows,
        );
        if (!std.meta.eql(self, expected)) return error.InvalidFrameScrollPlan;
    }

    pub fn acceptedPreservedRows(self: FrameScrollPlan, committed_terminal_scroll_rows: u16) u16 {
        return self.acceptedRows(committed_terminal_scroll_rows).preserved_release_rows;
    }

    pub fn acceptedInlineRows(self: FrameScrollPlan, committed_terminal_scroll_rows: u16) u32 {
        return self.acceptedRows(committed_terminal_scroll_rows).inline_advance_rows;
    }

    pub fn acceptedRows(self: FrameScrollPlan, committed_terminal_scroll_rows: u16) AcceptedScrollRows {
        return self.commit(committed_terminal_scroll_rows).accepted_rows;
    }

    pub fn commit(self: FrameScrollPlan, committed_terminal_scroll_rows: u16) FrameScrollCommit {
        return self.commitWithExpectedRows(
            committed_terminal_scroll_rows,
            self.terminal_scroll_rows,
        );
    }

    pub fn commitWithExpectedRows(
        self: FrameScrollPlan,
        committed_terminal_scroll_rows: u16,
        expected_terminal_scroll_rows: u16,
    ) FrameScrollCommit {
        std.debug.assert(expected_terminal_scroll_rows >= self.terminal_scroll_rows);
        const accepted_terminal_scroll_rows = @min(
            committed_terminal_scroll_rows,
            self.terminal_scroll_rows,
        );
        const accepted_rows = splitTerminalScrollRows(
            self.preserved_release_rows,
            self.requested_inline_advance_rows,
            accepted_terminal_scroll_rows,
        );
        return .{
            .physical_terminal_scroll_rows = committed_terminal_scroll_rows,
            .planned_terminal_scroll_rows = self.terminal_scroll_rows,
            .expected_terminal_scroll_rows = expected_terminal_scroll_rows,
            .accepted_terminal_scroll_rows = accepted_terminal_scroll_rows,
            .unplanned_terminal_scroll_rows = committed_terminal_scroll_rows -| expected_terminal_scroll_rows,
            .accepted_rows = accepted_rows,
        };
    }
};

pub fn merge(
    terminal_rows: u16,
    current_owned_top: u16,
    requested_release_rows: u16,
    inline_advance_rows: u32,
) FrameScrollPlan {
    const prior_owned_top = normalizeOwnedTop(current_owned_top, terminal_rows);
    const preserved_release_capacity = preservedReleaseCapacity(prior_owned_top);
    const release_floor_rows = @min(requested_release_rows, preserved_release_capacity);
    const terminal_scroll_rows = plannedTerminalScrollRows(
        terminal_rows,
        release_floor_rows,
        inline_advance_rows,
    );
    const row_split = splitTerminalScrollRows(
        preserved_release_capacity,
        inline_advance_rows,
        terminal_scroll_rows,
    );
    return .{
        .prior_owned_top = prior_owned_top,
        .requested_release_rows = release_floor_rows,
        .requested_inline_advance_rows = inline_advance_rows,
        .preserved_release_rows = row_split.preserved_release_rows,
        .terminal_scroll_rows = terminal_scroll_rows,
        .remaining_inline_advance_rows = inline_advance_rows -| row_split.inline_advance_rows,
        .post_scroll_owned_top = prior_owned_top -| row_split.preserved_release_rows,
    };
}

pub fn normalizeOwnedTop(owned_top: u16, terminal_rows: u16) u16 {
    if (terminal_rows == 0) return 0;
    if (owned_top == 0) return 1;
    return @min(owned_top, terminal_rows);
}

fn preservedReleaseCapacity(prior_owned_top: u16) u16 {
    return prior_owned_top -| 1;
}

fn plannedTerminalScrollRows(
    terminal_rows: u16,
    release_floor_rows: u16,
    inline_advance_rows: u32,
) u16 {
    if (terminal_rows == 0) return 0;
    return @intCast(@min(
        @as(u32, release_floor_rows) + inline_advance_rows,
        @as(u32, std.math.maxInt(u16)),
    ));
}

fn splitTerminalScrollRows(
    preserved_release_capacity: u16,
    requested_inline_advance_rows: u32,
    terminal_scroll_rows: u16,
) AcceptedScrollRows {
    const preserved_release_rows = @min(preserved_release_capacity, terminal_scroll_rows);
    const inline_advance_rows = @min(
        requested_inline_advance_rows,
        @as(u32, terminal_scroll_rows -| preserved_release_rows),
    );
    return .{
        .preserved_release_rows = preserved_release_rows,
        .inline_advance_rows = inline_advance_rows,
    };
}
