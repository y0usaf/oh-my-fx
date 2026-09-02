const std = @import("std");
const text_boundaries = @import("text_boundaries.zig");

const Allocator = std.mem.Allocator;

pub const InsertResult = enum {
    inserted,
    inactive,
    limit_exceeded,
};

pub const ByteResult = enum {
    consumed,
    ignored,
    limit_exceeded,
};

pub const SelectionRange = struct {
    start: usize,
    end: usize,
};

pub const SelectionEdge = enum {
    start,
    end,
};

/// Owns the composer text allocation and its layout-independent edit state.
/// Call `deinit` with the allocator used by fallible edit methods.
pub const State = struct {
    input: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    selection_anchor: ?usize = null,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.input.deinit(alloc);
        self.* = .{};
    }

    pub fn setText(self: *State, alloc: Allocator, text: []const u8) Allocator.Error!void {
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.selection_anchor = null;
        try self.input.appendSlice(alloc, text);
        self.cursor = self.input.items.len;
    }

    pub fn clearRetainingCapacity(self: *State) void {
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.selection_anchor = null;
    }

    /// Exchanges owned text storage with `other` and resets transient edit state.
    pub fn swapInput(self: *State, other: *std.ArrayList(u8)) void {
        std.mem.swap(std.ArrayList(u8), &self.input, other);
        self.cursor = self.input.items.len;
        self.selection_anchor = null;
    }

    pub fn beginSelection(self: *State, raw_offset: usize) bool {
        const offset = @min(raw_offset, self.input.items.len);
        const changed = self.selection_anchor != offset or self.cursor != offset;
        self.selection_anchor = offset;
        self.cursor = offset;
        return changed;
    }

    pub fn extendSelection(self: *State, raw_offset: usize) bool {
        if (self.selection_anchor == null) return false;
        const offset = @min(raw_offset, self.input.items.len);
        if (self.cursor == offset) return false;
        self.cursor = offset;
        return true;
    }

    pub fn finishSelection(self: *State) void {
        if (self.selection_anchor == self.cursor) self.selection_anchor = null;
    }

    pub fn clearSelection(self: *State) bool {
        if (self.selection_anchor == null) return false;
        self.selection_anchor = null;
        return true;
    }

    pub fn selectionRange(self: *const State) ?SelectionRange {
        const anchor = self.selection_anchor orelse return null;
        if (anchor == self.cursor) return null;
        return .{
            .start = @min(anchor, self.cursor),
            .end = @max(anchor, self.cursor),
        };
    }

    pub fn selectedText(self: *const State) ?[]const u8 {
        const selection = self.selectionRange() orelse return null;
        return self.input.items[selection.start..selection.end];
    }

    pub fn discardSelection(self: *State) ?usize {
        const dropped_bytes = if (self.selectionRange()) |selection|
            selection.end - selection.start
        else
            null;
        self.selection_anchor = null;
        return dropped_bytes;
    }

    pub fn collapseSelection(self: *State, edge: SelectionEdge) bool {
        const selection = self.selectionRange() orelse {
            self.selection_anchor = null;
            return false;
        };
        self.cursor = switch (edge) {
            .start => selection.start,
            .end => selection.end,
        };
        self.selection_anchor = null;
        return true;
    }

    pub fn setCursor(self: *State, raw_offset: usize) bool {
        const offset = @min(raw_offset, self.input.items.len);
        const changed = self.cursor != offset or self.selection_anchor != null;
        self.cursor = offset;
        self.selection_anchor = null;
        return changed;
    }

    pub fn moveCursorTo(self: *State, raw_offset: usize, extend_selection: bool) bool {
        if (!extend_selection) return self.setCursor(raw_offset);
        const offset = @min(raw_offset, self.input.items.len);
        if (self.selection_anchor == null) self.selection_anchor = self.cursor;
        if (self.cursor == offset) return false;
        self.cursor = offset;
        return true;
    }

    pub fn selectAll(self: *State) bool {
        if (self.input.items.len == 0) return self.clearSelection();
        const changed = self.selection_anchor != 0 or self.cursor != self.input.items.len;
        self.selection_anchor = 0;
        self.cursor = self.input.items.len;
        return changed;
    }

    pub fn moveCharacterLeft(self: *State) bool {
        if (self.collapseSelection(.start)) return true;
        if (self.cursor == 0) return false;
        return self.setCursor(text_boundaries.previousCharacterStart(self.input.items, self.cursor));
    }

    pub fn moveCharacterRight(self: *State) bool {
        if (self.collapseSelection(.end)) return true;
        if (self.cursor >= self.input.items.len) return false;
        return self.setCursor(text_boundaries.nextCharacterEnd(self.input.items, self.cursor));
    }

    pub fn moveHome(self: *State) bool {
        return self.setCursor(0);
    }

    pub fn moveEnd(self: *State) bool {
        return self.setCursor(self.input.items.len);
    }

    pub fn moveLineStart(self: *State) bool {
        return self.setCursor(text_boundaries.logicalLineStart(self.input.items, self.cursor));
    }

    pub fn moveLineEnd(self: *State) bool {
        return self.setCursor(text_boundaries.logicalLineEnd(self.input.items, self.cursor));
    }

    pub fn insertSliceAssumeCapacity(self: *State, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.input.insertSliceAssumeCapacity(self.cursor, bytes);
        self.cursor += bytes.len;
        self.selection_anchor = null;
    }

    pub fn insertSlice(self: *State, alloc: Allocator, bytes: []const u8) Allocator.Error!void {
        if (bytes.len == 0) return;
        try self.input.insertSlice(alloc, self.cursor, bytes);
        self.cursor += bytes.len;
        self.selection_anchor = null;
    }

    pub fn deleteTextRange(self: *State, start: usize, end: usize) bool {
        const clamped_start = @min(start, self.input.items.len);
        const clamped_end = @min(@max(end, clamped_start), self.input.items.len);
        if (clamped_start == clamped_end) return false;

        if (self.selection_anchor) |anchor| {
            self.selection_anchor = offsetAfterDelete(anchor, clamped_start, clamped_end);
        }
        return deleteRange(&self.input, &self.cursor, clamped_start, clamped_end);
    }

    pub fn replaceByteBeforeCursor(self: *State, expected: u8, replacement: u8) bool {
        if (self.cursor == 0) return false;
        const index = self.cursor - 1;
        if (self.input.items[index] != expected) return false;
        self.input.items[index] = replacement;
        self.selection_anchor = null;
        return true;
    }
};

fn offsetAfterDelete(offset: usize, start: usize, end: usize) usize {
    if (offset >= end) return offset - (end - start);
    if (offset > start) return start;
    return offset;
}

pub fn canInsert(current_len: usize, inserted_len: usize, max_len: usize) bool {
    if (current_len > max_len) return false;
    return inserted_len <= max_len -| current_len;
}

pub fn canReplace(current_len: usize, replaced_len: usize, inserted_len: usize, max_len: usize) bool {
    std.debug.assert(replaced_len <= current_len);
    return canInsert(current_len - replaced_len, inserted_len, max_len);
}

pub fn deleteRange(
    buffer: *std.ArrayList(u8),
    cursor: *usize,
    start: usize,
    end: usize,
) bool {
    const clamped_start = @min(start, buffer.items.len);
    const clamped_end = @min(@max(end, clamped_start), buffer.items.len);
    if (clamped_start == clamped_end) return false;
    const count = clamped_end - clamped_start;
    std.mem.copyForwards(u8, buffer.items[clamped_start..], buffer.items[clamped_end..]);
    buffer.items.len -= count;
    if (cursor.* >= clamped_end) {
        cursor.* -= count;
    } else if (cursor.* > clamped_start) {
        cursor.* = clamped_start;
    }
    return true;
}







