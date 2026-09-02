const std = @import("std");
const display_width = @import("../shared/display_width.zig");

pub fn nextCharacterEnd(text: []const u8, start: usize) usize {
    var end = @min(start, text.len);
    if (end == text.len) return end;

    const first = display_width.displayUnitAt(text, end);
    end += @max(first.byte_len, 1);
    if (isControlBoundary(text, start)) return @min(end, text.len);
    while (end < text.len) {
        const continuation = display_width.displayUnitAt(text, end);
        if (continuation.cell_width != 0 or isControlBoundary(text, end)) break;
        end += @max(continuation.byte_len, 1);
    }
    return @min(end, text.len);
}

pub fn previousCharacterStart(text: []const u8, end: usize) usize {
    const target = @min(end, text.len);
    if (target == 0) return 0;

    var current: usize = 0;
    var previous: usize = 0;
    while (current < target) {
        previous = current;
        const next = nextCharacterEnd(text, current);
        if (next >= target) return previous;
        current = next;
    }
    return previous;
}

pub fn previousWordStart(text: []const u8, cursor: usize) usize {
    var pos = @min(cursor, text.len);
    while (pos > 0) {
        const previous = previousCharacterStart(text, pos);
        if (isWordCharacterAt(text, previous)) break;
        pos = previous;
    }
    while (pos > 0) {
        const previous = previousCharacterStart(text, pos);
        if (!isWordCharacterAt(text, previous)) break;
        pos = previous;
    }
    return pos;
}

pub fn nextWordEnd(text: []const u8, cursor: usize) usize {
    var pos = @min(cursor, text.len);
    while (pos < text.len and !isWordCharacterAt(text, pos)) {
        pos = nextCharacterEnd(text, pos);
    }
    while (pos < text.len and isWordCharacterAt(text, pos)) {
        pos = nextCharacterEnd(text, pos);
    }
    return pos;
}

pub fn nextWordDeleteEnd(text: []const u8, cursor: usize) usize {
    var pos = @min(cursor, text.len);
    while (pos < text.len and isWordCharacterAt(text, pos)) {
        pos = nextCharacterEnd(text, pos);
    }
    while (pos < text.len and !isWordCharacterAt(text, pos)) {
        pos = nextCharacterEnd(text, pos);
    }
    return pos;
}

pub fn isWordCharacter(codepoint: u21) bool {
    if (codepoint == '_') return true;
    if (codepoint >= 'a' and codepoint <= 'z') return true;
    if (codepoint >= 'A' and codepoint <= 'Z') return true;
    if (codepoint >= '0' and codepoint <= '9') return true;
    return codepoint >= 0xC0;
}

pub fn logicalLineStart(text: []const u8, cursor: usize) usize {
    var start = @min(cursor, text.len);
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    return start;
}

pub fn logicalLineEnd(text: []const u8, cursor: usize) usize {
    var end = @min(cursor, text.len);
    while (end < text.len and text[end] != '\n') end += 1;
    return end;
}

fn lineIsBlank(text: []const u8, start: usize, end: usize) bool {
    for (text[start..end]) |byte| switch (byte) {
        ' ', '\t', '\r' => {},
        else => return false,
    };
    return true;
}

fn previousLineStart(text: []const u8, line_start: usize) ?usize {
    if (line_start == 0) return null;
    return logicalLineStart(text, line_start - 1);
}

pub fn previousParagraphStart(text: []const u8, cursor: usize) usize {
    var line_start = logicalLineStart(text, cursor);
    var line_end = logicalLineEnd(text, line_start);

    while (lineIsBlank(text, line_start, line_end)) {
        line_start = previousLineStart(text, line_start) orelse return 0;
        line_end = logicalLineEnd(text, line_start);
    }

    var paragraph_start = line_start;
    while (previousLineStart(text, paragraph_start)) |candidate| {
        if (lineIsBlank(text, candidate, logicalLineEnd(text, candidate))) break;
        paragraph_start = candidate;
    }
    if (cursor > paragraph_start) return paragraph_start;

    var previous = previousLineStart(text, paragraph_start) orelse return 0;
    while (lineIsBlank(text, previous, logicalLineEnd(text, previous))) {
        previous = previousLineStart(text, previous) orelse return 0;
    }
    var previous_start = previous;
    while (previousLineStart(text, previous_start)) |candidate| {
        if (lineIsBlank(text, candidate, logicalLineEnd(text, candidate))) break;
        previous_start = candidate;
    }
    return previous_start;
}

pub fn nextParagraphStart(text: []const u8, cursor: usize) usize {
    var line_start = logicalLineStart(text, cursor);
    var line_end = logicalLineEnd(text, line_start);

    while (!lineIsBlank(text, line_start, line_end)) {
        if (line_end == text.len) return text.len;
        line_start = line_end + 1;
        line_end = logicalLineEnd(text, line_start);
    }
    while (lineIsBlank(text, line_start, line_end)) {
        if (line_end == text.len) return text.len;
        line_start = line_end + 1;
        line_end = logicalLineEnd(text, line_start);
    }
    return line_start;
}

pub fn previousWhitespaceDelimitedTokenStart(
    text: []const u8,
    cursor: usize,
    lower_bound: usize,
) usize {
    var pos = @min(cursor, text.len);
    const lower = @min(lower_bound, pos);
    while (pos > lower) {
        const previous = previousCharacterStart(text, pos);
        if (!isWhitespaceCharacter(text, previous)) break;
        pos = previous;
    }
    while (pos > lower) {
        const previous = previousCharacterStart(text, pos);
        if (isWhitespaceCharacter(text, previous)) break;
        pos = previous;
    }
    return pos;
}

fn isControlBoundary(text: []const u8, start: usize) bool {
    const codepoint = display_width.decodeNextRune(text, start).codepoint;
    return codepoint < 0x20 or codepoint == 0x7F;
}

fn isWhitespaceCharacter(text: []const u8, start: usize) bool {
    const codepoint = display_width.decodeNextRune(text, start).codepoint;
    return codepoint <= 0x7F and std.ascii.isWhitespace(@intCast(codepoint));
}

fn isWordCharacterAt(text: []const u8, start: usize) bool {
    const codepoint = display_width.decodeNextRune(text, start).codepoint;
    return isWordCharacter(codepoint);
}
