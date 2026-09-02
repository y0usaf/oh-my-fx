const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const edit_contract = @import("../input/editor_state.zig");
const text_boundaries = @import("../input/text_boundaries.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    active_choice: ?u8 = null,
    yes_draft: std.ArrayList(u8) = .empty,
    yes_cursor: usize = 0,
    no_draft: std.ArrayList(u8) = .empty,
    no_cursor: usize = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.discard(alloc, "deinit");
    }

    pub fn begin(self: *State, choice: u8) void {
        if (self.slotForChoice(choice) != null) self.active_choice = choice;
    }

    pub fn isActive(self: State) bool {
        return self.active_choice != null;
    }

    pub fn activeChoice(self: State) ?u8 {
        return self.active_choice;
    }

    pub fn draftForChoice(self: State, choice: u8) []const u8 {
        return switch (choice) {
            0 => self.yes_draft.items,
            2 => self.no_draft.items,
            else => "",
        };
    }

    pub fn cursorForChoice(self: State, choice: u8) usize {
        return switch (choice) {
            0 => self.yes_cursor,
            2 => self.no_cursor,
            else => 0,
        };
    }

    pub fn insert(self: *State, alloc: Allocator, byte: u8) !void {
        if (byte >= 0x80) return;
        try self.insertSlice(alloc, &.{byte});
    }

    pub fn insertSlice(self: *State, alloc: Allocator, bytes: []const u8) !void {
        const slot = self.activeSlot() orelse return;
        std.debug.assert(std.unicode.utf8ValidateSlice(bytes));
        try slot.draft.insertSlice(alloc, slot.cursor.*, bytes);
        slot.cursor.* += bytes.len;
    }

    pub fn backspace(self: *State) void {
        const slot = self.activeSlot() orelse return;
        if (slot.cursor.* == 0) return;
        const start = text_boundaries.previousCharacterStart(slot.draft.items, slot.cursor.*);
        const count = slot.cursor.* - start;
        std.mem.copyForwards(u8, slot.draft.items[start..], slot.draft.items[slot.cursor.*..]);
        slot.draft.items.len -= count;
        slot.cursor.* = start;
    }

    pub fn cursorLeft(self: *State) void {
        const slot = self.activeSlot() orelse return;
        if (slot.cursor.* > 0) {
            slot.cursor.* = text_boundaries.previousCharacterStart(slot.draft.items, slot.cursor.*);
        }
    }

    pub fn cursorRight(self: *State) void {
        const slot = self.activeSlot() orelse return;
        if (slot.cursor.* < slot.draft.items.len) {
            slot.cursor.* = text_boundaries.nextCharacterEnd(slot.draft.items, slot.cursor.*);
        }
    }

    pub fn cursorHome(self: *State) void {
        const slot = self.activeSlot() orelse return;
        slot.cursor.* = 0;
    }

    pub fn cursorEnd(self: *State) void {
        const slot = self.activeSlot() orelse return;
        slot.cursor.* = slot.draft.items.len;
    }

    pub fn cursorWordLeft(self: *State) void {
        const slot = self.activeSlot() orelse return;
        slot.cursor.* = text_boundaries.previousWordStart(slot.draft.items, slot.cursor.*);
    }

    pub fn cursorWordRight(self: *State) void {
        const slot = self.activeSlot() orelse return;
        slot.cursor.* = text_boundaries.nextWordEnd(slot.draft.items, slot.cursor.*);
    }

    pub fn deleteNext(self: *State) void {
        const slot = self.activeSlot() orelse return;
        if (slot.cursor.* >= slot.draft.items.len) return;
        const end = text_boundaries.nextCharacterEnd(slot.draft.items, slot.cursor.*);
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, slot.cursor.*, end);
    }

    pub fn deleteWordLeft(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const start = text_boundaries.previousWordStart(slot.draft.items, slot.cursor.*);
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, start, slot.cursor.*);
    }

    pub fn deleteWhitespaceDelimitedWordLeft(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const line_start = text_boundaries.logicalLineStart(slot.draft.items, slot.cursor.*);
        const start = text_boundaries.previousWhitespaceDelimitedTokenStart(
            slot.draft.items,
            slot.cursor.*,
            line_start,
        );
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, start, slot.cursor.*);
    }

    pub fn deleteWordRight(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const end = text_boundaries.nextWordDeleteEnd(slot.draft.items, slot.cursor.*);
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, slot.cursor.*, end);
    }

    pub fn deleteToLineStart(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const start = text_boundaries.logicalLineStart(slot.draft.items, slot.cursor.*);
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, start, slot.cursor.*);
    }

    pub fn deleteToLineEnd(self: *State) void {
        const slot = self.activeSlot() orelse return;
        const line_end = text_boundaries.logicalLineEnd(slot.draft.items, slot.cursor.*);
        const end = if (slot.cursor.* == line_end and line_end < slot.draft.items.len)
            line_end + 1
        else
            line_end;
        _ = edit_contract.deleteRange(slot.draft, slot.cursor, slot.cursor.*, end);
    }

    const Slot = struct {
        draft: *std.ArrayList(u8),
        cursor: *usize,
    };

    /// Single mapping from an amendable choice (0 = allow, 2 = deny) to the
    /// draft and cursor it owns. Every edit path dispatches through here so
    /// the two choices cannot drift.
    fn slotForChoice(self: *State, choice: u8) ?Slot {
        return switch (choice) {
            0 => .{ .draft = &self.yes_draft, .cursor = &self.yes_cursor },
            2 => .{ .draft = &self.no_draft, .cursor = &self.no_cursor },
            else => null,
        };
    }

    fn activeSlot(self: *State) ?Slot {
        return self.slotForChoice(self.active_choice orelse return null);
    }

    pub fn clearActive(self: *State) void {
        self.active_choice = null;
    }

    pub fn discard(self: *State, alloc: Allocator, reason: []const u8) void {
        self.discardDraft(alloc, &self.yes_draft, "yes", reason);
        self.discardDraft(alloc, &self.no_draft, "no", reason);
        self.active_choice = null;
        self.yes_cursor = 0;
        self.no_cursor = 0;
    }

    pub fn discardAfterSubmission(self: *State, alloc: Allocator, selected_choice: u8) void {
        if (selected_choice == 0) {
            self.yes_draft.deinit(alloc);
            self.yes_draft = .empty;
        } else {
            self.discardDraft(alloc, &self.yes_draft, "yes", "accepted_submission_unselected");
        }
        if (selected_choice == 2) {
            self.no_draft.deinit(alloc);
            self.no_draft = .empty;
        } else {
            self.discardDraft(alloc, &self.no_draft, "no", "accepted_submission_unselected");
        }
        self.active_choice = null;
        self.yes_cursor = 0;
        self.no_cursor = 0;
    }

    fn discardDraft(
        _: *State,
        alloc: Allocator,
        draft: *std.ArrayList(u8),
        choice: []const u8,
        reason: []const u8,
    ) void {
        if (draft.items.len > 0) {
            debug_trace.logf(
                "permission",
                "approval feedback discarded reason={s} choice={s} bytes={d}",
                .{ reason, choice, draft.items.len },
            );
        }
        draft.deinit(alloc);
        draft.* = .empty;
    }
};
