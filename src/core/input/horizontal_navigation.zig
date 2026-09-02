const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const editor_state = @import("editor_state.zig");
const input_action = @import("input_action.zig");
const registered_entities = @import("registered_entities.zig");
const text_boundaries = @import("text_boundaries.zig");
const vertical_navigation = @import("vertical_navigation.zig");

pub fn move(
    motion: input_action.MoveKind,
    edit: *editor_state.State,
    entities: *const registered_entities.State,
    vertical: *vertical_navigation.State,
) bool {
    return moveIntent(.{ .kind = motion }, edit, entities, vertical);
}

/// Applies one layout-independent motion intent to Core-owned input state.
pub fn moveIntent(
    intent: input_action.MoveIntent,
    edit: *editor_state.State,
    entities: *const registered_entities.State,
    vertical: *vertical_navigation.State,
) bool {
    vertical.reset();
    return switch (intent.kind) {
        .character_left => moveCharacterLeft(edit, entities, intent.extend_selection),
        .character_right => moveCharacterRight(edit, entities, intent.extend_selection),
        .draft_start => edit.moveCursorTo(0, intent.extend_selection),
        .draft_end => edit.moveCursorTo(edit.input.items.len, intent.extend_selection),
        .line_start => edit.moveCursorTo(
            text_boundaries.logicalLineStart(edit.input.items, edit.cursor),
            intent.extend_selection,
        ),
        .line_end => edit.moveCursorTo(
            text_boundaries.logicalLineEnd(edit.input.items, edit.cursor),
            intent.extend_selection,
        ),
        .paragraph_up => edit.moveCursorTo(
            text_boundaries.previousParagraphStart(edit.input.items, edit.cursor),
            intent.extend_selection,
        ),
        .paragraph_down => edit.moveCursorTo(
            text_boundaries.nextParagraphStart(edit.input.items, edit.cursor),
            intent.extend_selection,
        ),
        .word_left => moveWordLeft(edit, entities, intent.extend_selection),
        .word_right => moveWordRight(edit, entities, intent.extend_selection),
        .visual_up, .visual_down, .page_up, .page_down => false,
    };
}

fn moveCharacterLeft(
    edit: *editor_state.State,
    entities: *const registered_entities.State,
    extend_selection: bool,
) bool {
    if (!extend_selection and edit.collapseSelection(.start)) return true;
    if (edit.cursor == 0) return false;
    if (entities.entityEndingAt(edit.input.items, edit.cursor)) |entity| {
        return edit.moveCursorTo(entity.span.raw_start, extend_selection);
    }
    return edit.moveCursorTo(
        text_boundaries.previousCharacterStart(edit.input.items, edit.cursor),
        extend_selection,
    );
}

fn moveCharacterRight(
    edit: *editor_state.State,
    entities: *const registered_entities.State,
    extend_selection: bool,
) bool {
    if (!extend_selection and edit.collapseSelection(.end)) return true;
    if (edit.cursor >= edit.input.items.len) return false;
    if (entities.entityStartingAt(edit.input.items, edit.cursor)) |entity| {
        return edit.moveCursorTo(entity.span.raw_end, extend_selection);
    }
    return edit.moveCursorTo(
        text_boundaries.nextCharacterEnd(edit.input.items, edit.cursor),
        extend_selection,
    );
}

fn moveWordLeft(
    edit: *editor_state.State,
    entities: *const registered_entities.State,
    extend_selection: bool,
) bool {
    if (!extend_selection and edit.collapseSelection(.start)) return true;
    if (edit.cursor == 0) return false;

    const input = edit.input.items;
    var raw_offset = edit.cursor;
    while (raw_offset > 0) {
        if (entities.entityEndingAt(input, raw_offset)) |entity| {
            return edit.moveCursorTo(entity.span.raw_start, extend_selection);
        }
        const previous = text_boundaries.previousCharacterStart(input, raw_offset);
        const rune = display_width.decodeNextRune(input, previous);
        if (text_boundaries.isWordCharacter(rune.codepoint)) break;
        raw_offset = previous;
    }
    while (raw_offset > 0) {
        if (entities.entityEndingAt(input, raw_offset)) |entity| {
            return edit.moveCursorTo(entity.span.raw_start, extend_selection);
        }
        const previous = text_boundaries.previousCharacterStart(input, raw_offset);
        const rune = display_width.decodeNextRune(input, previous);
        if (!text_boundaries.isWordCharacter(rune.codepoint)) break;
        raw_offset = previous;
    }
    return edit.moveCursorTo(raw_offset, extend_selection);
}

fn moveWordRight(
    edit: *editor_state.State,
    entities: *const registered_entities.State,
    extend_selection: bool,
) bool {
    if (!extend_selection and edit.collapseSelection(.end)) return true;
    const input = edit.input.items;
    if (edit.cursor >= input.len) return false;

    var raw_offset = edit.cursor;
    while (raw_offset < input.len) {
        if (entities.entityStartingAt(input, raw_offset)) |entity| {
            return edit.moveCursorTo(entity.span.raw_end, extend_selection);
        }
        const rune = display_width.decodeNextRune(input, raw_offset);
        if (text_boundaries.isWordCharacter(rune.codepoint)) break;
        raw_offset = text_boundaries.nextCharacterEnd(input, raw_offset);
    }
    while (raw_offset < input.len) {
        if (entities.entityStartingAt(input, raw_offset) != null) break;
        const rune = display_width.decodeNextRune(input, raw_offset);
        if (!text_boundaries.isWordCharacter(rune.codepoint)) break;
        raw_offset = text_boundaries.nextCharacterEnd(input, raw_offset);
    }
    return edit.moveCursorTo(raw_offset, extend_selection);
}




