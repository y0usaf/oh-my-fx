const std = @import("std");
const languages = @import("code_highlight_languages.zig");

const Allocator = std.mem.Allocator;

const reset_style = "\x1b[39m";

pub const Theme = enum {
    dark,
    light,
};

const Palette = struct {
    keyword_style: []const u8,
    string_style: []const u8,
    number_style: []const u8,
    comment_style: []const u8,
};

const dark_palette: Palette = .{
    .keyword_style = "\x1b[38;5;252m",
    .string_style = "\x1b[38;5;250m",
    .number_style = "\x1b[38;5;250m",
    .comment_style = "\x1b[38;5;245m",
};

const light_palette: Palette = .{
    .keyword_style = "\x1b[38;5;238m",
    .string_style = "\x1b[38;5;241m",
    .number_style = "\x1b[38;5;241m",
    .comment_style = "\x1b[38;5;243m",
};

fn paletteForTheme(theme: Theme) Palette {
    return switch (theme) {
        .dark => dark_palette,
        .light => light_palette,
    };
}

pub fn highlight(
    alloc: Allocator,
    source: []const u8,
    profile: *const languages.Profile,
    theme: Theme,
) ![]u8 {
    var styled: std.ArrayList(u8) = .empty;
    errdefer styled.deinit(alloc);
    const palette = paletteForTheme(theme);

    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\n') {
            try styled.append(alloc, '\n');
            index += 1;
            continue;
        }
        if (blockCommentEnd(source, index, profile.block_comment)) |end| {
            try appendStyled(alloc, &styled, palette.comment_style, source[index..end]);
            index = end;
            continue;
        }
        if (lineCommentEnd(source, index, profile.line_comments)) |end| {
            try appendStyled(alloc, &styled, palette.comment_style, source[index..end]);
            index = end;
            continue;
        }
        if (isQuote(source[index], profile.quotes)) {
            const end = quotedEnd(source, index);
            try appendStyled(alloc, &styled, palette.string_style, source[index..end]);
            index = end;
            continue;
        }
        if (isNumberStart(source, index)) {
            const end = numberEnd(source, index);
            try appendStyled(alloc, &styled, palette.number_style, source[index..end]);
            index = end;
            continue;
        }
        if (isIdentifierStart(source[index])) {
            const end = identifierEnd(source, index);
            const token = source[index..end];
            if (inList(token, profile.keywords, profile.keyword_case)) {
                try appendStyled(alloc, &styled, palette.keyword_style, token);
            } else if (inList(token, profile.literals, profile.keyword_case)) {
                try appendStyled(alloc, &styled, palette.number_style, token);
            } else {
                try styled.appendSlice(alloc, token);
            }
            index = end;
            continue;
        }
        try styled.append(alloc, source[index]);
        index += 1;
    }

    return styled.toOwnedSlice(alloc);
}

fn appendStyled(alloc: Allocator, out: *std.ArrayList(u8), style: []const u8, text: []const u8) !void {
    try out.appendSlice(alloc, style);
    try out.appendSlice(alloc, text);
    try out.appendSlice(alloc, reset_style);
}

fn blockCommentEnd(source: []const u8, index: usize, block_comment: ?languages.BlockComment) ?usize {
    const comment = block_comment orelse return null;
    if (!std.mem.startsWith(u8, source[index..], comment.start)) return null;
    const content_start = index + comment.start.len;
    const close_start = std.mem.indexOfPos(u8, source, content_start, comment.end) orelse return source.len;
    return close_start + comment.end.len;
}

fn lineCommentEnd(source: []const u8, index: usize, prefixes: []const []const u8) ?usize {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, source[index..], prefix)) return lineEnd(source, index);
    }
    return null;
}

fn lineEnd(source: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
}

fn isQuote(byte: u8, quotes: []const u8) bool {
    return std.mem.indexOfScalar(u8, quotes, byte) != null;
}

fn quotedEnd(source: []const u8, start: usize) usize {
    const quote = source[start];
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\n') return index;
        if (source[index] == '\\' and index + 1 < source.len) {
            index += 1;
            continue;
        }
        if (source[index] == quote) return index + 1;
    }
    return source.len;
}

fn isNumberStart(source: []const u8, index: usize) bool {
    return std.ascii.isDigit(source[index]) and (index == 0 or !isIdentifierContinue(source[index - 1]));
}

fn numberEnd(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '.' or source[index] == '_')) : (index += 1) {}
    return index;
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or std.ascii.isDigit(byte);
}

fn identifierEnd(source: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < source.len and isIdentifierContinue(source[index])) : (index += 1) {}
    return index;
}

fn inList(token: []const u8, options: []const []const u8, keyword_case: languages.KeywordCase) bool {
    for (options) |option| {
        const matches = switch (keyword_case) {
            .sensitive => std.mem.eql(u8, token, option),
            .ascii_insensitive => std.ascii.eqlIgnoreCase(token, option),
        };
        if (matches) return true;
    }
    return false;
}

fn ansiSequenceEnd(text: []const u8, start: usize) usize {
    if (start + 2 > text.len or text[start] != 0x1b or text[start + 1] != '[') return start;
    var index = start + 2;
    while (index < text.len) : (index += 1) {
        if (text[index] >= '@' and text[index] <= '~') return index + 1;
    }
    return start;
}

fn stripAnsi(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var plain: std.ArrayList(u8) = .empty;
    errdefer plain.deinit(alloc);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            const end = ansiSequenceEnd(text, index);
            if (end > index) {
                index = end;
                continue;
            }
        }
        try plain.append(alloc, text[index]);
        index += 1;
    }
    return plain.toOwnedSlice(alloc);
}

fn count(text: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, needle)) |index| {
        result += 1;
        start = index + needle.len;
    }
    return result;
}
