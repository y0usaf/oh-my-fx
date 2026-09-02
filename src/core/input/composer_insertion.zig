const std = @import("std");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const pasted_blocks = @import("pasted_blocks.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const text_scalar = @import("text_scalar.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

pub const InsertResult = editor_state.InsertResult;

pub const PickerPolicy = enum {
    preserve,
    clear,
};

/// Borrows the state changed by one layout-independent composer insertion.
/// The containing runtime retains ownership of every pointer and allocation.
pub const State = struct {
    edit: *editor_state.State,
    history: *edit_history.State,
    picker: *picker_state.State,
    entities: *registered_entities.State,
    vertical_navigation: *vertical_navigation.State,
    input_limit_rejection: *input_limit_rejection.State,

    pub fn expandedInputLen(self: State) ?usize {
        return pasted_blocks.expandedLen(
            self.edit.input.items,
            self.entities.pasted_blocks.items,
        );
    }

    pub fn canInsert(
        self: State,
        inserted_len: usize,
        max_len: usize,
    ) bool {
        const current_len = self.expandedInputLen() orelse return false;
        return editor_state.canInsert(current_len, inserted_len, max_len);
    }

    pub fn canReplaceRange(
        self: State,
        replace_start: usize,
        replace_end: usize,
        inserted_len: usize,
        max_len: usize,
    ) bool {
        const current_len = self.expandedInputLen() orelse return false;
        const replaced_len = pasted_blocks.expandedRangeLen(
            self.edit.input.items,
            self.entities.pasted_blocks.items,
            replace_start,
            replace_end,
        ) orelse return false;
        return editor_state.canReplace(
            current_len,
            replaced_len,
            inserted_len,
            max_len,
        );
    }

    pub fn insertByte(
        self: State,
        alloc: Allocator,
        byte: u8,
        picker_policy: PickerPolicy,
    ) Allocator.Error!void {
        try self.insertSlice(alloc, &.{byte}, picker_policy);
    }

    pub fn insertByteBounded(
        self: State,
        alloc: Allocator,
        byte: u8,
        max_len: usize,
        picker_policy: PickerPolicy,
    ) Allocator.Error!InsertResult {
        return self.insertSliceBounded(alloc, &.{byte}, max_len, picker_policy);
    }

    pub fn insertSlice(
        self: State,
        alloc: Allocator,
        bytes: []const u8,
        picker_policy: PickerPolicy,
    ) Allocator.Error!void {
        if (bytes.len == 0) return;
        if (bytes.len == 1 and self.claimPendingAutoSeparator(bytes[0], picker_policy)) return;

        const insert_start = self.edit.cursor;
        var prepared = if (self.entities.entityContaining(
            self.edit.input.items,
            insert_start,
        ) != null)
            edit_history.Prepared.boundary
        else
            try self.history.prepare(
                alloc,
                insert_start,
                "",
                bytes,
                self.edit.cursor,
                insert_start + bytes.len,
            );
        defer prepared.deinit(alloc);
        self.entities.discardPendingAutoSeparator();
        self.vertical_navigation.reset();
        self.applyPickerPolicy(picker_policy);
        self.entities.convertSkillTokenContaining(alloc, insert_start);
        try self.edit.insertSlice(alloc, bytes);
        self.entities.shiftForInsert(alloc, insert_start, bytes.len);
        self.reconcilePickerAfterEdit();
        self.history.commit(alloc, &prepared);
    }

    pub fn insertSliceBounded(
        self: State,
        alloc: Allocator,
        bytes: []const u8,
        max_len: usize,
        picker_policy: PickerPolicy,
    ) Allocator.Error!InsertResult {
        if (!self.canInsert(bytes.len, max_len)) {
            if (bytes.len == 1) {
                const pending_auto_separator = self.entities.pending_auto_separator;
                if (self.claimPendingAutoSeparator(bytes[0], picker_policy)) {
                    self.input_limit_rejection.* = input_limit_rejection.clear();
                    return .inserted;
                }
                self.entities.pending_auto_separator = pending_auto_separator;
            }
            return .limit_exceeded;
        }

        try self.insertSlice(alloc, bytes, picker_policy);
        self.input_limit_rejection.* = input_limit_rejection.clear();
        return .inserted;
    }

    pub fn insertSliceAssumeCapacity(
        self: State,
        alloc: Allocator,
        bytes: []const u8,
    ) void {
        if (bytes.len == 0) return;

        self.entities.discardPendingAutoSeparator();
        const insert_start = self.edit.cursor;
        self.entities.convertSkillTokenContaining(alloc, insert_start);
        self.edit.insertSliceAssumeCapacity(bytes);
        self.entities.shiftForInsert(alloc, insert_start, bytes.len);
        self.reconcilePickerAfterEdit();
    }

    fn claimPendingAutoSeparator(
        self: State,
        byte: u8,
        picker_policy: PickerPolicy,
    ) bool {
        if (!self.entities.claimPendingAutoSeparator(
            self.edit.input.items,
            self.edit.cursor,
            byte,
        )) return false;

        self.vertical_navigation.reset();
        self.applyPickerPolicy(picker_policy);
        self.reconcilePickerAfterEdit();
        return true;
    }

    fn applyPickerPolicy(self: State, picker_policy: PickerPolicy) void {
        switch (picker_policy) {
            .preserve => {},
            .clear => self.picker.clearModelPickerFlow(),
        }
    }

    fn reconcilePickerAfterEdit(self: State) void {
        self.picker.reconcileInlinePickerAfterEdit(self.edit);
        self.picker.resetActiveModelPickerIndex();
    }
};


