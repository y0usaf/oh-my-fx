const std = @import("std");
const composer_insertion = @import("composer_insertion.zig");
const edit_history = @import("edit_history.zig");
const editor_state = @import("editor_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const vertical_navigation = @import("vertical_navigation.zig");

const Allocator = std.mem.Allocator;

/// Borrows the Core state changed by one composer skill-token binding.
/// The containing input runtime retains ownership of every pointer and allocation.
pub const State = struct {
    insertion: composer_insertion.State,

    pub fn bindSkillToken(
        self: State,
        alloc: Allocator,
        replace_start: usize,
        replace_end: usize,
        name: []const u8,
        path: []const u8,
        display_source: ?skill_contract.SkillSource,
    ) registered_entities.BindError!void {
        try self.insertion.entities.bindSkillToken(
            alloc,
            self.insertion.edit,
            replace_start,
            replace_end,
            name,
            path,
            display_source,
        );
        self.insertion.history.reset(alloc);
        self.insertion.vertical_navigation.reset();
        self.insertion.picker.reconcileInlinePickerAfterEdit(self.insertion.edit);
        self.insertion.picker.resetActiveModelPickerIndex();
        self.insertion.input_limit_rejection.* = input_limit_rejection.clear();
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
        return .{ .insertion = .{
            .edit = &self.edit,
            .history = &self.history,
            .picker = &self.picker,
            .entities = &self.entities,
            .vertical_navigation = &self.vertical_navigation,
            .input_limit_rejection = &self.input_limit_rejection,
        } };
    }

    fn seedHistoryBothDirections(self: *Fixture, alloc: Allocator) !void {
        var first = try self.history.prepare(alloc, 0, "", "a", 0, 1);
        defer first.deinit(alloc);
        self.history.commit(alloc, &first);

        var second = try self.history.prepare(alloc, 1, "", "b", 1, 2);
        defer second.deinit(alloc);
        self.history.commit(alloc, &second);
        try std.testing.expect(try self.history.prepareUndo(alloc));
        self.history.commitUndo();
    }
};

fn checkAllocationFailureIsAtomic(
    failing: *std.testing.FailingAllocator,
    fail_offset: ?usize,
    allocation_count: *usize,
) !void {
    const alloc = failing.allocator();
    var fixture: Fixture = .{};
    defer fixture.deinit(alloc);
    try fixture.edit.setText(alloc, "review tail");
    _ = fixture.edit.setCursor("review".len);
    try fixture.seedHistoryBothDirections(alloc);
    fixture.picker.slash_completion_index = 4;
    fixture.picker.model_completion_index = 5;
    fixture.vertical_navigation.preferred_column = 6;
    fixture.input_limit_rejection = input_limit_rejection.begin(
        .{},
        .composer,
    ).next;

    const start_alloc_index = failing.alloc_index;
    if (fail_offset) |offset| {
        failing.fail_index = try std.math.add(usize, start_alloc_index, offset);
    }

    fixture.state().bindSkillToken(
        alloc,
        0,
        "review".len,
        "review",
        "/tmp/review/SKILL.md",
        null,
    ) catch |err| {
        try std.testing.expectEqualStrings("review tail", fixture.edit.input.items);
        try std.testing.expectEqual(@as(usize, "review".len), fixture.edit.cursor);
        try std.testing.expectEqual(@as(usize, 0), fixture.entities.skill_tokens.items.len);
        try std.testing.expect(fixture.history.peekUndo() != null);
        try std.testing.expect(fixture.history.peekRedo() != null);
        try std.testing.expectEqual(@as(usize, 4), fixture.picker.slash_completion_index);
        try std.testing.expectEqual(@as(usize, 5), fixture.picker.model_completion_index);
        try std.testing.expectEqual(@as(?usize, 6), fixture.vertical_navigation.preferredColumn());
        try std.testing.expectEqual(.composer, fixture.input_limit_rejection.owner.?);
        return err;
    };

    allocation_count.* = failing.alloc_index - start_alloc_index;
    try std.testing.expectEqualStrings("$review tail", fixture.edit.input.items);
    try std.testing.expectEqual(@as(usize, "$review".len), fixture.edit.cursor);
    try std.testing.expectEqual(@as(usize, 1), fixture.entities.skill_tokens.items.len);
    try std.testing.expect(fixture.history.peekUndo() == null);
    try std.testing.expect(fixture.history.peekRedo() == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.slash_completion_index);
    try std.testing.expectEqual(@as(usize, 0), fixture.picker.model_completion_index);
    try std.testing.expectEqual(@as(?usize, null), fixture.vertical_navigation.preferredColumn());
    try std.testing.expect(fixture.input_limit_rejection.owner == null);
}
