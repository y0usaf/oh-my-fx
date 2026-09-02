const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

const Transition = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
    cursor_after: usize,

    fn growth(self: Transition) usize {
        return self.replacement.len -| (self.end - self.start);
    }
};

/// Purely validates one recorded delta and describes the mutation to apply.
fn plan(
    input: []const u8,
    entities: *const registered_entities.State,
    entry: *const edit_history.Entry,
    expected: []const u8,
    replacement: []const u8,
    cursor_after: usize,
) ?Transition {
    const end = std.math.add(usize, entry.start, expected.len) catch return null;
    if (end > input.len or !std.mem.eql(u8, input[entry.start..end], expected)) {
        return null;
    }
    if ((entry.start < end and entities.entityOverlapping(entry.start, end) != null) or
        (entry.start == end and entities.entityContaining(input, entry.start) != null))
    {
        return null;
    }
    return .{
        .start = entry.start,
        .end = end,
        .replacement = replacement,
        .cursor_after = cursor_after,
    };
}

/// Borrows the Core state changed by one composer undo or redo transition.
/// The containing runtime retains ownership of every pointer and allocation.
pub const State = struct {
    edit: *editor_state.State,
    history: *edit_history.State,
    picker: *picker_state.State,
    entities: *registered_entities.State,
    vertical_navigation: *vertical_navigation.State,
    input_limit_rejection: *input_limit_rejection.State,

    pub fn undo(self: State, alloc: Allocator) Allocator.Error!bool {
        if (!try self.history.prepareUndo(alloc)) return false;
        const entry = self.history.peekUndo().?;
        if (!try self.apply(
            alloc,
            entry,
            entry.inserted.items,
            entry.removed.items,
            entry.cursor_before,
        )) {
            debug_trace.logf(
                "input",
                "text edit history dropped reason=invalid_transition operation=undo",
                .{},
            );
            self.history.reset(alloc);
            return false;
        }
        self.history.commitUndo();
        return true;
    }

    pub fn redo(self: State, alloc: Allocator) Allocator.Error!bool {
        if (!try self.history.prepareRedo(alloc)) return false;
        const entry = self.history.peekRedo().?;
        if (!try self.apply(
            alloc,
            entry,
            entry.removed.items,
            entry.inserted.items,
            entry.cursor_after,
        )) {
            debug_trace.logf(
                "input",
                "text edit history dropped reason=invalid_transition operation=redo",
                .{},
            );
            self.history.reset(alloc);
            return false;
        }
        self.history.commitRedo();
        return true;
    }

    fn apply(
        self: State,
        alloc: Allocator,
        entry: *const edit_history.Entry,
        expected: []const u8,
        replacement: []const u8,
        cursor_after: usize,
    ) Allocator.Error!bool {
        const transition = plan(
            self.edit.input.items,
            self.entities,
            entry,
            expected,
            replacement,
            cursor_after,
        ) orelse return false;
        const growth = transition.growth();
        if (growth > 0) {
            try self.edit.input.ensureUnusedCapacity(
                alloc,
                growth,
            );
        }

        self.entities.discardPendingAutoSeparator();
        if (transition.start < transition.end) {
            self.entities.adjustForDelete(alloc, transition.start, transition.end);
            std.debug.assert(self.edit.deleteTextRange(transition.start, transition.end));
        }
        _ = self.edit.setCursor(transition.start);
        if (transition.replacement.len > 0) {
            self.edit.insertSliceAssumeCapacity(transition.replacement);
            self.entities.shiftForInsert(alloc, transition.start, transition.replacement.len);
        }
        _ = self.edit.setCursor(transition.cursor_after);
        self.vertical_navigation.reset();
        self.picker.clearModelPickerFlow();
        self.picker.reconcileInlinePickerAfterEdit(self.edit);
        self.picker.resetActiveModelPickerIndex();
        self.picker.resetFilePickerIndex();
        self.input_limit_rejection.* = input_limit_rejection.clear();
        return true;
    }
};

const Fixture = struct {
    edit: editor_state.State = .{},
    history: edit_history.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    vertical_navigation: vertical_navigation.State = .{},
    input_limit_rejection: input_limit_rejection.State = .{},

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.edit.deinit(alloc);
        self.history.deinit(alloc);
        self.picker.deinit(alloc);
        self.entities.deinit(alloc);
    }

    fn state(self: *Fixture) State {
        return .{
            .edit = &self.edit,
            .history = &self.history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
            .input_limit_rejection = &self.input_limit_rejection,
        };
    }

    fn record(
        self: *Fixture,
        alloc: Allocator,
        start: usize,
        removed: []const u8,
        inserted: []const u8,
        cursor_before: usize,
        cursor_after: usize,
    ) !void {
        var prepared = try self.history.prepare(
            alloc,
            start,
            removed,
            inserted,
            cursor_before,
            cursor_after,
        );
        defer prepared.deinit(alloc);
        self.history.commit(alloc, &prepared);
    }
};




