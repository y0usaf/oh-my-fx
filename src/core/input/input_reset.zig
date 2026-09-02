const std = @import("std");
const composer_history = @import("composer_history.zig");
const editor_state = @import("editor_state.zig");
const edit_history = @import("edit_history.zig");
const gesture_state = @import("gesture_state.zig");
const input_limit_rejection = @import("input_limit_rejection.zig");
const kill_ring = @import("kill_ring.zig");
const paste_framing = @import("paste_framing.zig");
const picker_state = @import("picker_state.zig");
const registered_entities = @import("registered_entities.zig");
const text_scalar = @import("text_scalar.zig");
const vertical_navigation = @import("vertical_navigation.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

/// Non-owning view of the Core state affected by current-input and session
/// resets. Callers retain ownership of every referenced state value.
pub const State = struct {
    edit: *editor_state.State,
    picker: *picker_state.State,
    composer_history: *composer_history.State,
    paste: *paste_framing.State,
    entities: *registered_entities.State,
    text_scalar: *text_scalar.State,
    gestures: *gesture_state.State,
    input_limit_rejection: *input_limit_rejection.State,
    kill_ring: *kill_ring.State,
    edit_history: *edit_history.State,
    vertical_navigation: *vertical_navigation.State,

    pub fn clearCurrent(self: State, alloc: Allocator) void {
        self.vertical_navigation.reset();
        resetPendingTextScalarWithTrace(self.text_scalar, "input_cleared");
        discardSelectionWithTrace(self.edit, "input_cleared");
        self.input_limit_rejection.* = input_limit_rejection.clear();
        self.edit.clearRetainingCapacity();
        self.entities.clearImageAndSkillTokens(alloc);
        self.picker.resetInlinePickerEpisode();
        self.picker.model_completion_index = 0;
        self.picker.model_completion_window_start = 0;
        self.picker.resetFilePickerIndex();
        self.picker.clearModelPickerFlow();
        self.composer_history.resetNavigation(alloc);
        self.edit_history.reset(alloc);
    }

    pub fn resetForSession(self: State, alloc: Allocator) void {
        self.paste.resetWithTrace(.session_reset);
        self.clearCurrent(alloc);
        self.entities.resetForSession(alloc);
        self.kill_ring.resetForSession(alloc);

        const gesture_reset = gesture_state.reset(self.gestures.*);
        self.gestures.* = gesture_reset.next;
        if (gesture_reset.cleared_ctrl_c_exit) {
            debug_trace.logf(
                "input",
                "event=ctrl_c_exit_disarmed reason=pending_gesture_reset",
                .{},
            );
        }
        if (gesture_reset.cleared_escape_clear) {
            debug_trace.logf(
                "input",
                "event=esc_clear_disarmed reason=pending_gesture_reset",
                .{},
            );
        }
    }
};

pub fn resetPendingTextScalarWithTrace(
    state: *text_scalar.State,
    reason: []const u8,
) void {
    const transition = text_scalar.reset(state.*);
    state.* = transition.next;
    if (transition.dropped) |drop| {
        debug_trace.logf(
            "input",
            "text scalar dropped owner={s} bytes={d} reason={s}",
            .{ @tagName(drop.owner), drop.bytes, reason },
        );
    }
}

pub fn discardSelectionWithTrace(
    edit: *editor_state.State,
    reason: []const u8,
) void {
    if (edit.discardSelection()) |dropped_bytes| {
        debug_trace.logf(
            "input",
            "selection dropped bytes={d} reason={s}",
            .{ dropped_bytes, reason },
        );
    }
}
