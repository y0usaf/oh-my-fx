const std = @import("std");
const input_action = @import("../../core/input/input_action.zig");

const InputEscapeAction = input_action.Action;
const ShortcutAction = input_action.ShortcutAction;

fn move(kind: input_action.MoveKind) ShortcutAction {
    return .{ .move = .{ .kind = kind } };
}

pub fn fromControlByte(byte: u8) ?ShortcutAction {
    return switch (byte) {
        1 => move(.line_start),
        5 => move(.line_end),
        2 => move(.character_left),
        6 => move(.character_right),
        16 => .history_previous,
        14 => .history_next,
        4 => .delete_forward,
        11 => .delete_to_line_end,
        21 => .delete_to_line_start,
        23 => .delete_whitespace_word_left,
        25 => .yank,
        31 => .undo,
        12 => .redraw,
        127, 8 => .delete_backward,
        '\n' => .insert_newline,
        else => null,
    };
}

pub fn fromFocusedEditorControlByte(byte: u8) ?ShortcutAction {
    const action = fromControlByte(byte) orelse return null;
    return switch (action) {
        .move,
        .delete_whitespace_word_left,
        .delete_to_line_start,
        .delete_to_line_end,
        => action,
        else => null,
    };
}

pub fn fromEscapeAction(action: InputEscapeAction) ?ShortcutAction {
    return switch (action) {
        .cursor_up => move(.visual_up),
        .cursor_down => move(.visual_down),
        .cursor_left => move(.character_left),
        .cursor_right => move(.character_right),
        .word_left => move(.word_left),
        .word_right => move(.word_right),
        .home => move(.line_start),
        .end => move(.line_end),
        .page_up => move(.page_up),
        .page_down => move(.page_down),
        .delete_next => .delete_forward,
        .delete_word_left => .delete_word_left,
        .delete_word_right => .delete_word_right,
        .delete_to_line_start => .delete_to_line_start,
        .delete_to_line_end => .delete_to_line_end,
        .insert_newline => .insert_newline,
        .composer_shortcut => |shortcut| shortcut,
        .remapped_byte => |byte| fromControlByte(byte),
        else => null,
    };
}




