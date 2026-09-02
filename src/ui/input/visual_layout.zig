const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const entity_spans = @import("../../core/shared/entity_spans.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const types = @import("../../core/shared/types.zig");
const paste_blocks = @import("../../core/input/pasted_blocks.zig");
const registered_entities = @import("../../core/input/registered_entities.zig");

pub const Direction = enum { up, down };
pub const BreakKind = enum { hard_newline, soft_wrap, input_end };
pub const InputPrefix = struct {
    bytes: []const u8,
    cell_width: usize,
};
pub const UnitKind = union(enum) {
    text,
    tab,
    paste_placeholder,
    skill_token: usize,
    image_badge: struct {
        attachment_index: usize,
    },
};

pub const SkillTokenSpan = registered_entities.SkillTokenSpan;

pub const RawRange = struct {
    start: usize,
    end: usize,
};

pub const skill_source_separator = " · ";

pub fn skillTokenSourceLabel(token: SkillTokenSpan) ?[]const u8 {
    const source = token.display_source orelse return null;
    return skill_runtime.skillSourceShortLabel(source);
}

fn skillTokenVisibleWidth(token: SkillTokenSpan) usize {
    var width = display_width.visibleWidth(token.name);
    if (skillTokenSourceLabel(token)) |label| {
        width +|= display_width.visibleWidth(skill_source_separator);
        width +|= display_width.visibleWidth(label);
    }
    return width;
}

pub const ImageTokenSpan = entity_spans.ImageTokenSpan;

pub const Source = struct {
    input: []const u8,
    cursor: usize,
    terminal_cols: u16,
    /// Production invariant: unique positive attachment IDs.
    images: []const types.ImageAttachment = &.{},
    /// Production invariant: sorted by span start and non-overlapping.
    pasted_blocks: []const paste_blocks.PastedBlock = &.{},
    /// Production invariant: sorted by raw_start and non-overlapping.
    image_tokens: []const ImageTokenSpan = &.{},
    /// Production invariant: sorted by raw_start and non-overlapping.
    skill_tokens: []const SkillTokenSpan = &.{},
    selection: ?RawRange = null,
};

pub const CursorPoint = struct {
    raw_offset: usize,
    row_index: usize,
    content_column: usize,
};

pub const Unit = struct {
    raw_start: usize,
    raw_end: usize,
    row_index: usize,
    content_column: usize,
    cell_width: usize,
    kind: UnitKind,
};

pub const Row = struct {
    index: usize,
    raw_start: usize,
    raw_end: usize,
    break_kind: BreakKind,
    prefix_cell_width: usize,
    content_width: usize,
    first_cursor_offset: usize,
    last_cursor_offset: usize,
};

pub const Summary = struct {
    total_rows: usize,
    cursor: CursorPoint,
    anchor: ?CursorPoint,
};

pub const VisibleWindow = struct {
    first_row: usize,
    row_count: usize,
};

pub const Event = union(enum) {
    unit: Unit,
    row_end: Row,
};

const RawUnit = struct {
    raw_start: usize,
    raw_end: usize,
    cell_width: usize,
    kind: UnitKind,
};

pub const Iterator = struct {
    source: Source,
    i: usize = 0,
    row_index: usize = 0,
    row_start: usize = 0,
    content_column: usize = 0,
    last_cursor_offset: usize = 0,
    previous_cursor_offset: usize = 0,
    force_next_positive_wrap: bool = false,
    at_word_start: bool = true,
    done: bool = false,

    pub fn next(self: *Iterator) ?Event {
        if (self.done) return null;

        if (self.i >= self.source.input.len) {
            return self.finishRow(.input_end, self.source.input.len);
        }

        if (self.source.input[self.i] == '\n') {
            return self.finishRow(.hard_newline, self.i);
        }

        const raw = self.peekRawUnit();
        if (self.shouldBreakBefore(raw)) {
            return self.finishRow(.soft_wrap, raw.raw_start);
        }

        return self.consumeRawUnit(raw);
    }

    /// Decides whether the current row soft-wraps before `raw`. Spaces never
    /// wrap; they hang past the right margin (painters clip them) so
    /// continuation rows start at the word itself, never a leading space.
    fn shouldBreakBefore(self: *const Iterator, raw: RawUnit) bool {
        if (raw.kind == .text and self.source.input[raw.raw_start] == ' ') return false;
        if (self.shouldSoftWrapWord(raw)) return true;
        return raw.cell_width > 0 and self.shouldSoftWrap(raw.cell_width);
    }

    fn finishRow(self: *Iterator, break_kind: BreakKind, raw_end: usize) Event {
        const prefix = inputPrefix(self.row_index);
        const last_cursor_offset = switch (break_kind) {
            .soft_wrap => if (self.last_cursor_offset == raw_end) self.previous_cursor_offset else self.last_cursor_offset,
            .hard_newline, .input_end => raw_end,
        };
        const row = Row{
            .index = self.row_index,
            .raw_start = self.row_start,
            .raw_end = raw_end,
            .break_kind = break_kind,
            .prefix_cell_width = prefix.cell_width,
            .content_width = self.content_column,
            .first_cursor_offset = self.row_start,
            .last_cursor_offset = last_cursor_offset,
        };

        switch (break_kind) {
            .input_end => self.done = true,
            .hard_newline => self.startNextRow(raw_end + 1),
            .soft_wrap => self.startNextRow(raw_end),
        }

        return .{ .row_end = row };
    }

    fn startNextRow(self: *Iterator, raw_start: usize) void {
        self.i = raw_start;
        self.row_index += 1;
        self.row_start = raw_start;
        self.content_column = 0;
        self.last_cursor_offset = raw_start;
        self.previous_cursor_offset = raw_start;
        self.force_next_positive_wrap = false;
        self.at_word_start = true;
    }

    fn peekRawUnit(self: *const Iterator) RawUnit {
        const input = self.source.input;
        const start = self.i;
        if (paste_blocks.registeredPlaceholderSpanStartingAt(
            input,
            start,
            self.source.pasted_blocks,
        )) |placeholder| {
            return .{
                .raw_start = placeholder.start,
                .raw_end = placeholder.end,
                .cell_width = display_width.visibleWidth(
                    input[placeholder.start..placeholder.end],
                ),
                .kind = .paste_placeholder,
            };
        }

        if (skillTokenStartingAt(self.source.skill_tokens, start, input.len)) |token_index| {
            const token = self.source.skill_tokens[token_index];
            return .{
                .raw_start = token.raw_start,
                .raw_end = token.raw_end,
                .cell_width = skillTokenVisibleWidth(token),
                .kind = .{ .skill_token = token_index },
            };
        }

        if (input[start] == '\t') {
            return .{
                .raw_start = start,
                .raw_end = start + 1,
                .cell_width = tabAdvance(inputPrefix(self.row_index).cell_width, self.content_column, self.source.terminal_cols),
                .kind = .tab,
            };
        }

        if (imageTokenStartingAt(self.source, start)) |token| {
            const attachment_index = image_attachments.findImageIndexById(
                self.source.images,
                token.id,
            ).?;
            return .{
                .raw_start = token.span.raw_start,
                .raw_end = token.span.raw_end,
                .cell_width = image_attachments.imageBadgeVisibleWidth(token.id),
                .kind = .{ .image_badge = .{ .attachment_index = attachment_index } },
            };
        }

        const display_unit = display_width.displayUnitAt(input, start);
        return .{
            .raw_start = start,
            .raw_end = start + display_unit.byte_len,
            .cell_width = display_unit.cell_width,
            .kind = .text,
        };
    }

    fn consumeRawUnit(self: *Iterator, raw: RawUnit) Event {
        const unit = Unit{
            .raw_start = raw.raw_start,
            .raw_end = raw.raw_end,
            .row_index = self.row_index,
            .content_column = self.content_column,
            .cell_width = raw.cell_width,
            .kind = raw.kind,
        };

        self.i = raw.raw_end;
        self.previous_cursor_offset = self.last_cursor_offset;
        self.last_cursor_offset = raw.raw_end;
        self.at_word_start = switch (raw.kind) {
            .text => isWordBreakByte(self.source.input[raw.raw_start]),
            .tab, .paste_placeholder, .skill_token, .image_badge => true,
        };
        const available = self.availableContentCells();
        const oversized_empty_row = available > 0 and self.content_column == 0 and raw.cell_width > available;
        self.content_column +|= raw.cell_width;
        if (oversized_empty_row) {
            self.force_next_positive_wrap = true;
        }

        return .{ .unit = unit };
    }

    /// Word-aware wrapping: when a word starts near the right margin and
    /// does not fit in the remaining cells of the current row, but would fit
    /// on a fresh continuation row, wrap the whole word instead of splitting
    /// it per character. Words wider than a full row still fall back to the
    /// per-character soft wrap.
    fn shouldSoftWrapWord(self: *const Iterator, raw: RawUnit) bool {
        if (raw.kind != .text) return false;
        if (!self.at_word_start) return false;
        if (self.content_column == 0) return false;
        if (self.force_next_positive_wrap) return false;

        const available = self.availableContentCells();
        if (self.content_column >= available) return false;

        const remaining = available - self.content_column;
        const next_available = nextRowAvailableCells(self.row_index, self.source.terminal_cols);
        if (next_available == 0) return false;

        const word_width = self.measureWordWidth(raw.raw_start, next_available);
        return word_width > remaining and word_width <= next_available;
    }

    /// Measures the cell width of the word starting at `start`, stopping at
    /// word breaks, atomic units, or once the width exceeds `cap`.
    fn measureWordWidth(self: *const Iterator, start: usize, cap: usize) usize {
        const input = self.source.input;
        var width: usize = 0;
        var i = start;
        while (i < input.len and !self.wordEndsAt(i)) {
            const display_unit = display_width.displayUnitAt(input, i);
            width +|= display_unit.cell_width;
            if (width > cap) break;
            i += display_unit.byte_len;
        }
        return width;
    }

    /// A word ends at a break byte or at the start of an atomic unit
    /// (paste, skill, or image), mirroring peekRawUnit's boundaries.
    fn wordEndsAt(self: *const Iterator, i: usize) bool {
        const input = self.source.input;
        if (isWordBreakByte(input[i])) return true;
        if (paste_blocks.registeredPlaceholderSpanStartingAt(
            input,
            i,
            self.source.pasted_blocks,
        ) != null) return true;
        if (skillTokenStartingAt(self.source.skill_tokens, i, input.len) != null) return true;
        if (imageTokenStartingAt(self.source, i) != null) return true;
        return false;
    }

    fn shouldSoftWrap(self: *const Iterator, cell_width: usize) bool {
        const available = self.availableContentCells();
        if (available == 0) return false;
        if (self.force_next_positive_wrap) return true;
        if (self.content_column == 0) return false;
        if (self.content_column >= available) return true;
        if (cell_width > std.math.maxInt(u16)) return true;

        const start_column = inputPrefix(self.row_index).cell_width + self.content_column + 1;
        return display_width.shouldWrapAt(@intCast(start_column), @intCast(cell_width), self.source.terminal_cols);
    }

    fn availableContentCells(self: *const Iterator) usize {
        const cols: usize = self.source.terminal_cols;
        const prefix_width = inputPrefix(self.row_index).cell_width;
        return if (cols > prefix_width) cols - prefix_width else 0;
    }
};

fn isWordBreakByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn nextRowAvailableCells(current_row_index: usize, terminal_cols: u16) usize {
    const cols: usize = terminal_cols;
    const prefix_width = inputPrefix(current_row_index + 1).cell_width;
    return if (cols > prefix_width) cols - prefix_width else 0;
}

fn skillTokenStartingAt(tokens: []const SkillTokenSpan, raw_start: usize, input_len: usize) ?usize {
    for (tokens, 0..) |token, index| {
        if (token.raw_start == raw_start and token.raw_end > token.raw_start and token.raw_end <= input_len) return index;
        if (token.raw_start > raw_start) return null;
    }
    return null;
}

fn imageTokenStartingAt(source: Source, raw_start: usize) ?ImageTokenSpan {
    for (source.image_tokens) |token| {
        if (token.span.raw_start < raw_start) continue;
        if (token.span.raw_start > raw_start) return null;
        if (!token.span.isValid(source.input.len)) return null;
        const match = image_attachments.matchImagePlaceholder(
            source.input,
            token.span.raw_start,
        ) orelse return null;
        if (match.id != token.id or token.span.raw_start + match.length != token.span.raw_end) {
            return null;
        }
        if (image_attachments.findImageIndexById(source.images, token.id) == null) return null;
        return token;
    }
    return null;
}

pub const VerticalScan = struct {
    target: ?CursorPoint,
    preferred_column: usize,
    total_rows: usize,
    cursor_row: usize,
};

pub fn iterator(source: Source) Iterator {
    return .{
        .source = source,
        .last_cursor_offset = 0,
        .previous_cursor_offset = 0,
    };
}

pub fn summarize(source: Source, raw_anchor: ?usize) Summary {
    return .{
        .total_rows = countRows(source),
        .cursor = cursorPointAt(source, source.cursor),
        .anchor = if (raw_anchor) |anchor| cursorPointAt(source, anchor) else null,
    };
}

fn pointAtUnitStart(unit: Unit) CursorPoint {
    return .{ .raw_offset = unit.raw_start, .row_index = unit.row_index, .content_column = unit.content_column };
}

fn pointAfterUnit(unit: Unit) CursorPoint {
    return .{
        .raw_offset = unit.raw_end,
        .row_index = unit.row_index,
        .content_column = unit.content_column +| unit.cell_width,
    };
}

fn pointAtRowEnd(row: Row) CursorPoint {
    return .{ .raw_offset = row.raw_end, .row_index = row.index, .content_column = row.content_width };
}

/// Offsets inside a unit snap to the unit start.
fn pointWithinUnit(unit: Unit, target: usize) ?CursorPoint {
    if (target == unit.raw_start or (target > unit.raw_start and target < unit.raw_end)) {
        return pointAtUnitStart(unit);
    }
    return null;
}

/// Soft-wrap boundary offsets belong to the following row.
fn pendingResolvesAt(point: CursorPoint, row: Row) bool {
    return point.raw_offset < row.raw_end or row.break_kind != .soft_wrap;
}

pub fn cursorPointAt(source: Source, raw_offset: usize) CursorPoint {
    const target = @min(raw_offset, source.input.len);
    var it = iterator(source);
    var pending_after: ?CursorPoint = null;

    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (pointWithinUnit(unit, target)) |point| return point;
            if (target == unit.raw_end) pending_after = pointAfterUnit(unit);
        },
        .row_end => |row| {
            if (target == row.raw_end) {
                switch (row.break_kind) {
                    .soft_wrap => pending_after = null,
                    .hard_newline, .input_end => return pointAtRowEnd(row),
                }
            } else if (pending_after) |point| {
                if (pendingResolvesAt(point, row)) return point;
            }
        },
    };

    return .{ .raw_offset = target, .row_index = 0, .content_column = 0 };
}

pub fn cursorPointAtPosition(
    source: Source,
    row_index: usize,
    content_column: usize,
) ?CursorPoint {
    var it = iterator(source);
    var target = TargetBuilder.init(content_column);

    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (unit.row_index == row_index) {
                target.consider(pointAtUnitStart(unit));
            } else if (unit.row_index > row_index) {
                return null;
            }
        },
        .row_end => |row| {
            if (row.index < row_index) continue;
            if (row.index > row_index) return null;
            if (row.break_kind != .soft_wrap) {
                target.consider(pointAtRowEnd(row));
            }
            return target.result();
        },
    };

    return null;
}

/// Finding the cursor freezes the preferred column and arms the target:
/// up resolves from the previous row, down collects from the next row.
const ScanState = struct {
    direction: Direction,
    preferred_column: ?usize,
    preferred: usize,
    cursor_found: bool = false,
    cursor_row: usize = 0,
    target: ?CursorPoint = null,
    target_row: ?usize = null,
    target_builder: TargetBuilder = .{ .preferred_column = 0 },

    fn init(direction: Direction, preferred_column: ?usize) ScanState {
        return .{
            .direction = direction,
            .preferred_column = preferred_column,
            .preferred = preferred_column orelse 0,
        };
    }

    fn foundCursor(
        self: *ScanState,
        point: CursorPoint,
        previous_row_checkpoint: ?Iterator,
        previous_row_target: ?CursorPoint,
    ) void {
        self.cursor_found = true;
        self.cursor_row = point.row_index;
        if (self.preferred_column == null) self.preferred = point.content_column;
        switch (self.direction) {
            .up => if (point.row_index > 0) {
                self.target = if (self.preferred_column == null)
                    targetPointInCheckpoint(previous_row_checkpoint.?, point.row_index - 1, self.preferred)
                else
                    previous_row_target;
            },
            .down => {
                self.target_row = point.row_index + 1;
                self.target_builder = TargetBuilder.init(self.preferred);
            },
        }
    }

    fn considerTargetUnit(self: *ScanState, unit: Unit) void {
        const row_index = self.target_row orelse return;
        if (row_index != unit.row_index) return;
        self.target_builder.consider(pointAtUnitStart(unit));
    }

    fn finishTargetRow(self: *ScanState, row: Row) void {
        const row_index = self.target_row orelse return;
        if (row_index != row.index) return;
        if (row.break_kind != .soft_wrap) self.target_builder.consider(pointAtRowEnd(row));
        self.target = self.target_builder.result();
        self.target_row = null;
    }
};

pub fn scanAdjacentRow(source: Source, direction: Direction, preferred_column: ?usize) VerticalScan {
    const target_offset = @min(source.cursor, source.input.len);
    var it = iterator(source);
    var current_row_checkpoint = it;
    var previous_row_checkpoint: ?Iterator = null;

    var total_rows: usize = 0;
    var pending_after: ?CursorPoint = null;
    var previous_row_target: ?CursorPoint = null;
    var scan = ScanState.init(direction, preferred_column);
    var row_builder = TargetBuilder.init(scan.preferred);

    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (preferred_column != null) row_builder.consider(pointAtUnitStart(unit));
            scan.considerTargetUnit(unit);
            if (!scan.cursor_found) {
                if (pointWithinUnit(unit, target_offset)) |point| {
                    scan.foundCursor(point, previous_row_checkpoint, previous_row_target);
                } else if (target_offset == unit.raw_end) {
                    pending_after = pointAfterUnit(unit);
                }
            }
        },
        .row_end => |row| {
            total_rows += 1;

            if (preferred_column != null and row.break_kind != .soft_wrap) {
                row_builder.consider(pointAtRowEnd(row));
            }

            scan.finishTargetRow(row);

            if (!scan.cursor_found) {
                if (target_offset == row.raw_end) {
                    switch (row.break_kind) {
                        .soft_wrap => pending_after = null,
                        .hard_newline, .input_end => scan.foundCursor(
                            pointAtRowEnd(row),
                            previous_row_checkpoint,
                            previous_row_target,
                        ),
                    }
                } else if (pending_after) |point| {
                    if (pendingResolvesAt(point, row)) {
                        scan.foundCursor(point, previous_row_checkpoint, previous_row_target);
                    }
                }
            }

            if (preferred_column != null) {
                previous_row_target = row_builder.result();
                row_builder = TargetBuilder.init(scan.preferred);
            }
            previous_row_checkpoint = current_row_checkpoint;
            current_row_checkpoint = it;
        },
    };

    return .{
        .target = scan.target,
        .preferred_column = scan.preferred,
        .total_rows = total_rows,
        .cursor_row = scan.cursor_row,
    };
}

pub fn scanRowDelta(
    source: Source,
    direction: Direction,
    row_count: usize,
    preferred_column: ?usize,
) VerticalScan {
    const summary = summarize(source, null);
    const preferred = preferred_column orelse summary.cursor.content_column;
    const target_row = switch (direction) {
        .up => summary.cursor.row_index -| row_count,
        .down => @min(
            summary.cursor.row_index +| row_count,
            summary.total_rows -| 1,
        ),
    };
    return .{
        .target = if (target_row == summary.cursor.row_index)
            null
        else
            cursorPointAtPosition(source, target_row, preferred),
        .preferred_column = preferred,
        .total_rows = summary.total_rows,
        .cursor_row = summary.cursor.row_index,
    };
}

fn countRows(source: Source) usize {
    var it = iterator(source);
    var rows: usize = 0;
    while (it.next()) |event| switch (event) {
        .row_end => rows += 1,
        else => {},
    };
    return rows;
}

const TargetBuilder = struct {
    preferred_column: usize,
    first: ?CursorPoint = null,
    best: ?CursorPoint = null,

    fn init(preferred_column: usize) TargetBuilder {
        return .{ .preferred_column = preferred_column };
    }

    fn consider(self: *TargetBuilder, point: CursorPoint) void {
        if (self.first == null) self.first = point;
        if (point.content_column > self.preferred_column) return;
        if (self.best) |current| {
            if (point.content_column > current.content_column or
                (point.content_column == current.content_column and point.raw_offset > current.raw_offset))
            {
                self.best = point;
            }
        } else {
            self.best = point;
        }
    }

    fn result(self: TargetBuilder) ?CursorPoint {
        return self.best orelse self.first;
    }
};

fn targetPointInCheckpoint(checkpoint: Iterator, row_index: usize, preferred_column: usize) ?CursorPoint {
    var it = checkpoint;
    var builder = TargetBuilder.init(preferred_column);

    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (unit.row_index != row_index) continue;
            builder.consider(pointAtUnitStart(unit));
        },
        .row_end => |row| {
            if (row.index != row_index) continue;
            if (row.break_kind != .soft_wrap) builder.consider(pointAtRowEnd(row));
            return builder.result();
        },
    };

    return builder.result();
}

pub fn visibleWindow(cursor_row: usize, total_rows: usize, row_limit: usize) VisibleWindow {
    if (total_rows == 0) return .{ .first_row = 0, .row_count = 0 };
    const count = @max(row_limit, 1);
    const clamped_cursor = @min(cursor_row, total_rows - 1);
    const first = (clamped_cursor + 1) -| count;
    return .{ .first_row = first, .row_count = @min(count, total_rows - first) };
}

pub fn inputPrefix(row_index: usize) InputPrefix {
    return if (row_index == 0)
        .{ .bytes = "❯ ", .cell_width = 2 }
    else
        .{ .bytes = "  ", .cell_width = 2 };
}

pub fn terminalColumn(point: CursorPoint, terminal_cols: u16) u16 {
    if (terminal_cols == 0) return 1;
    return @intCast(@min(
        @as(usize, terminal_cols),
        inputPrefix(point.row_index).cell_width +| point.content_column +| 1,
    ));
}

pub fn projectedAnchorColumn(summary: Summary, terminal_cols: u16) u16 {
    const anchor = summary.anchor orelse return 1;
    if (anchor.row_index == summary.cursor.row_index) return terminalColumn(anchor, terminal_cols);
    return terminalColumn(.{
        .raw_offset = summary.cursor.raw_offset,
        .row_index = summary.cursor.row_index,
        .content_column = 0,
    }, terminal_cols);
}

pub fn tabAdvance(prefix_cell_width: usize, content_column: usize, terminal_cols: u16) usize {
    if (terminal_cols == 0) return 0;
    const cols: usize = terminal_cols;
    const absolute_zero_based = prefix_cell_width +| content_column;
    const right_margin = cols - 1;
    const current_zero_based = @min(absolute_zero_based, right_margin);
    const current_col: u16 = @intCast(current_zero_based + 1);
    return display_width.nextTabStopColumn(current_col, terminal_cols) - current_col;
}

fn testSource(input: []const u8, cursor: usize, cols: u16) Source {
    return .{ .input = input, .cursor = cursor, .terminal_cols = cols };
}

fn expectPoint(point: CursorPoint, raw_offset: usize, row_index: usize, content_column: usize) !void {
    try std.testing.expectEqual(raw_offset, point.raw_offset);
    try std.testing.expectEqual(row_index, point.row_index);
    try std.testing.expectEqual(content_column, point.content_column);
}

fn expectCursor(input: []const u8, raw_offset: usize, cols: u16, row_index: usize, content_column: usize) !void {
    try expectPoint(cursorPointAt(testSource(input, raw_offset, cols), raw_offset), raw_offset, row_index, content_column);
}

fn rowAt(source: Source, index: usize) ?Row {
    var it = iterator(source);
    while (it.next()) |event| switch (event) {
        .row_end => |row| if (row.index == index) return row,
        else => {},
    };
    return null;
}






























