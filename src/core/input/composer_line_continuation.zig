const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

fn backslashIndexBeforeCursor(input: []const u8, cursor: usize) ?usize {
    if (cursor == 0 or cursor > input.len) return null;
    const index = cursor - 1;
    if (input[index] != '\\') return null;
    return index;
}

/// Borrows the Core state changed by one composer line-continuation edit.
/// The containing input runtime retains ownership of every pointer and allocation.
pub const State = struct {
    edit: *editor_state.State,
    history: *edit_history.State,
    picker: *picker_state.State,
    entities: *registered_entities.State,
    vertical_navigation: *vertical_navigation.State,

    pub fn replaceBackslashBeforeCursorWithNewline(
        self: State,
        alloc: Allocator,
    ) bool {
        self.vertical_navigation.reset();
        const index = backslashIndexBeforeCursor(
            self.edit.input.items,
            self.edit.cursor,
        ) orelse return false;

        var prepared = self.prepareHistory(alloc, index);
        defer prepared.deinit(alloc);

        const replaced = self.edit.replaceByteBeforeCursor('\\', '\n');
        std.debug.assert(replaced);
        if (!replaced) return false;

        self.picker.clearModelPickerFlow();
        self.entities.discardPendingAutoSeparator();
        self.picker.reconcileInlinePickerAfterEdit(self.edit);
        self.picker.resetActiveModelPickerIndex();
        self.picker.resetFilePickerIndex();
        self.history.commit(alloc, &prepared);
        return true;
    }

    fn prepareHistory(
        self: State,
        alloc: Allocator,
        index: usize,
    ) edit_history.Prepared {
        return self.history.prepare(
            alloc,
            index,
            "\\",
            "\n",
            self.edit.cursor,
            self.edit.cursor,
        ) catch |err| {
            debug_trace.logf(
                "input",
                "text edit history dropped reason=allocation_failure operation=backslash_newline error={s}",
                .{@errorName(err)},
            );
            self.history.reset(alloc);
            return .boundary;
        };
    }
};

const Fixture = struct {
    edit: editor_state.State = .{},
    history: edit_history.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    vertical_navigation: vertical_navigation.State = .{},

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
        };
    }
};




