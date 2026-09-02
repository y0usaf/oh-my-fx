const std = @import("std");
const image_attachments = @import("../images/image_attachments.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const composer_insertion = @import("composer_insertion.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const pasted_blocks = @import("pasted_blocks.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

pub const ImageBlocks = std.ArrayList(types.ImageAttachment);
pub const InsertResult = composer_insertion.InsertResult;

pub const Range = struct {
    start: usize,
    end: usize,
};

const Plan = struct {
    growth: usize,
    cursor_after: usize,
};

/// Describes a raw composer range replacement without changing editor state.
fn plan(
    input_len: usize,
    range: Range,
    replacement_len: usize,
    requested_cursor_after: usize,
) ?Plan {
    if (range.start > range.end or range.end > input_len) return null;
    const removed_len = range.end - range.start;
    const next_len = (input_len - removed_len) +| replacement_len;
    return .{
        .growth = replacement_len -| removed_len,
        .cursor_after = @min(requested_cursor_after, next_len),
    };
}

/// Borrows the state changed by one bounded composer range replacement.
/// The containing runtime retains ownership of every pointer and allocation.
pub const State = struct {
    insertion: composer_insertion.State,
    images: ?*ImageBlocks = null,

    pub fn availableBytesForSelectionOrInsertion(
        self: State,
        max_len: usize,
    ) usize {
        const current_len = self.insertion.expandedInputLen() orelse return 0;
        const selected_len = if (self.insertion.edit.selectionRange()) |selection|
            pasted_blocks.expandedRangeLen(
                self.insertion.edit.input.items,
                self.insertion.entities.pasted_blocks.items,
                selection.start,
                selection.end,
            ) orelse return 0
        else
            0;
        return max_len -| (current_len -| selected_len);
    }

    pub fn canReplaceSelectionOrInsert(
        self: State,
        inserted_len: usize,
        max_len: usize,
    ) bool {
        if (self.insertion.edit.selectionRange()) |selection| {
            return self.insertion.canReplaceRange(
                selection.start,
                selection.end,
                inserted_len,
                max_len,
            );
        }
        return self.insertion.canInsert(inserted_len, max_len);
    }

    pub fn replaceSelectionOrInsertSliceBounded(
        self: State,
        alloc: Allocator,
        bytes: []const u8,
        max_len: usize,
        picker_policy: composer_insertion.PickerPolicy,
    ) Allocator.Error!InsertResult {
        if (self.insertion.edit.selectionRange() == null) {
            return self.insertion.insertSliceBounded(
                alloc,
                bytes,
                max_len,
                picker_policy,
            );
        }

        const result = try self.replaceSelectionBounded(alloc, bytes, max_len);
        if (result == .inserted and picker_policy == .clear) {
            self.insertion.picker.clearModelPickerFlow();
        }
        return result;
    }

    pub fn replaceRangeBounded(
        self: State,
        alloc: Allocator,
        range: Range,
        replacement: []const u8,
        cursor_after: usize,
        max_len: usize,
    ) Allocator.Error!InsertResult {
        const replacement_plan = plan(
            self.insertion.edit.input.items.len,
            range,
            replacement.len,
            cursor_after,
        ) orelse return .inactive;
        if (!self.insertion.canReplaceRange(
            range.start,
            range.end,
            replacement.len,
            max_len,
        )) return .limit_exceeded;

        if (replacement_plan.growth > 0) {
            try self.insertion.edit.input.ensureUnusedCapacity(
                alloc,
                replacement_plan.growth,
            );
        }

        var prepared = self.prepareHistory(
            alloc,
            range,
            replacement,
            replacement_plan.cursor_after,
            "range_replace",
        );
        defer prepared.deinit(alloc);
        self.applyReplacement(
            alloc,
            range,
            replacement,
            replacement_plan.cursor_after,
        );
        self.insertion.history.commit(alloc, &prepared);
        return .inserted;
    }

    pub fn replaceSelectionBounded(
        self: State,
        alloc: Allocator,
        replacement: []const u8,
        max_len: usize,
    ) Allocator.Error!InsertResult {
        const selection = self.insertion.edit.selectionRange() orelse return .inactive;
        const result = try self.replaceRangeBounded(
            alloc,
            .{ .start = selection.start, .end = selection.end },
            replacement,
            selection.start +| replacement.len,
            max_len,
        );
        if (result == .inserted) _ = self.insertion.edit.clearSelection();
        return result;
    }

    pub fn deleteSelection(self: State, alloc: Allocator) bool {
        const selection = self.insertion.edit.selectionRange() orelse return false;
        const range: Range = .{ .start = selection.start, .end = selection.end };
        if (!self.insertion.canReplaceRange(
            range.start,
            range.end,
            0,
            self.insertion.edit.input.items.len,
        )) return false;
        if (!self.deleteRange(alloc, range, selection.start)) return false;
        _ = self.insertion.edit.clearSelection();
        return true;
    }

    pub fn deleteRange(
        self: State,
        alloc: Allocator,
        range: Range,
        cursor_after: usize,
    ) bool {
        const replacement_plan = plan(
            self.insertion.edit.input.items.len,
            range,
            0,
            cursor_after,
        ) orelse return false;

        var prepared = self.prepareHistory(
            alloc,
            range,
            "",
            replacement_plan.cursor_after,
            "range_delete",
        );
        defer prepared.deinit(alloc);
        self.applyReplacement(
            alloc,
            range,
            "",
            replacement_plan.cursor_after,
        );
        self.insertion.history.commit(alloc, &prepared);
        return true;
    }

    fn prepareHistory(
        self: State,
        alloc: Allocator,
        range: Range,
        replacement: []const u8,
        cursor_after: usize,
        operation: []const u8,
    ) edit_history.Prepared {
        const structured = self.insertion.entities.entityOverlapping(
            range.start,
            range.end,
        ) != null or (range.start == range.end and
            self.insertion.entities.entityContaining(
                self.insertion.edit.input.items,
                range.start,
            ) != null);
        if (structured) return .boundary;

        return self.insertion.history.prepare(
            alloc,
            range.start,
            self.insertion.edit.input.items[range.start..range.end],
            replacement,
            self.insertion.edit.cursor,
            cursor_after,
        ) catch |err| {
            debug_trace.logf(
                "input",
                "text edit history dropped reason=allocation_failure operation={s} error={s}",
                .{ operation, @errorName(err) },
            );
            self.insertion.history.reset(alloc);
            return .boundary;
        };
    }

    fn applyReplacement(
        self: State,
        alloc: Allocator,
        range: Range,
        replacement: []const u8,
        cursor_after: usize,
    ) void {
        self.removeRegisteredEntitiesOverlapping(alloc, range);
        self.deleteInputRange(alloc, range);
        _ = self.insertion.edit.setCursor(range.start);
        self.insertion.insertSliceAssumeCapacity(alloc, replacement);
        _ = self.insertion.edit.setCursor(cursor_after);
        self.insertion.input_limit_rejection.* = input_limit_rejection.clear();
    }

    fn deleteInputRange(self: State, alloc: Allocator, range: Range) void {
        if (range.start >= range.end) return;
        self.insertion.entities.discardPendingAutoSeparator();
        self.insertion.entities.adjustForDelete(alloc, range.start, range.end);
        std.debug.assert(self.insertion.edit.deleteTextRange(range.start, range.end));
    }

    fn removeRegisteredEntitiesOverlapping(
        self: State,
        alloc: Allocator,
        range: Range,
    ) void {
        while (self.insertion.entities.entityOverlapping(range.start, range.end)) |entity| {
            if (self.insertion.entities.remove(alloc, entity)) |image_id| {
                if (self.images) |images| removeImageById(alloc, images, image_id);
            }
        }
    }
};

fn removeImageById(alloc: Allocator, images: *ImageBlocks, id: usize) void {
    for (images.items, 0..) |image, index| {
        if (image.id != id) continue;
        const removed = images.orderedRemove(index);
        image_attachments.discardImageAttachment(alloc, removed);
        return;
    }
}

const Fixture = struct {
    edit: editor_state.State = .{},
    picker: picker_state.State = .{},
    entities: registered_entities.State = .{},
    history: edit_history.State = .{},
    vertical: vertical_navigation.State = .{},
    rejection: input_limit_rejection.State = .{},

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.edit.deinit(alloc);
        self.picker.deinit(alloc);
        self.entities.deinit(alloc);
        self.history.deinit(alloc);
    }

    fn replacement(self: *Fixture, images: ?*ImageBlocks) State {
        return .{
            .insertion = .{
                .edit = &self.edit,
                .history = &self.history,
                .picker = &self.picker,
                .entities = &self.entities,
                .vertical_navigation = &self.vertical,
                .input_limit_rejection = &self.rejection,
            },
            .images = images,
        };
    }
};








