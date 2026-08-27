const std = @import("std");
const languages = @import("code_highlight_languages.zig");
const syntax_theme = @import("../../core/config/syntax_theme.zig");

const Allocator = std.mem.Allocator;

const reset_style = "\x1b[39m";

pub const Theme = enum {
    dark,
    light,
};

/// Token roles the scanner can emit. Order is the palette-table index order;
/// keep the two in sync.
pub const role_count = 10;
pub const Role = enum {
    keyword,
    type,
    function,
    string,
    number,
    comment,
    operator,
    constant,
    attribute,
    regex,

    fn index(self: Role) usize {
        return @intFromEnum(self);
    }
};

pub const Palette = struct {
    styles: [role_count][]const u8,

    pub fn style(self: Palette, role: Role) []const u8 {
        return self.styles[role.index()];
    }
};

// Palette table, one `styles` row per Theme in Role order. Every value is an
// indexed 256-color escape so terminals without truecolor still match; the
// syntax layer follows the existing theme styles by holding the active name
// as module state rather than threading it through every render call.
//
// default: warm amber keywords with cool blue types, green strings, violet
// numbers — the oh-my-fx brand family, tuned for contrast on both themes.
// mono: the historical grayscale look.
// ocean: blues, cyans, and teals.
// ember: oranges, ambers, and warm reds.
const default_dark = Palette{
    .styles = .{
        "\x1b[38;5;214m", // keyword   amber
        "\x1b[38;5;74m", // type      blue
        "\x1b[38;5;252m", // function  bright neutral
        "\x1b[38;5;114m", // string    green
        "\x1b[38;5;140m", // number    violet
        "\x1b[38;5;241m", // comment   dim gray
        "\x1b[38;5;245m", // operator  gray
        "\x1b[38;5;209m", // constant  orange
        "\x1b[38;5;141m", // attribute purple
        "\x1b[38;5;173m", // regex     rose
    },
};

const default_light = Palette{
    .styles = .{
        "\x1b[38;5;130m", // keyword   dark amber
        "\x1b[38;5;25m", // type      deep blue
        "\x1b[38;5;240m", // function  dark neutral
        "\x1b[38;5;71m", // string    brand green
        "\x1b[38;5;98m", // number    violet
        "\x1b[38;5;244m", // comment   gray
        "\x1b[38;5;246m", // operator  gray
        "\x1b[38;5;166m", // constant  orange
        "\x1b[38;5;134m", // attribute violet
        "\x1b[38;5;131m", // regex     rose
    },
};

const mono_dark = Palette{ .styles = .{
    "\x1b[38;5;252m",
    "\x1b[38;5;250m",
    "\x1b[38;5;255m",
    "\x1b[38;5;250m",
    "\x1b[38;5;250m",
    "\x1b[38;5;241m",
    "\x1b[38;5;245m",
    "\x1b[38;5;252m",
    "\x1b[38;5;250m",
    "\x1b[38;5;250m",
} };

const mono_light = Palette{ .styles = .{
    "\x1b[38;5;238m",
    "\x1b[38;5;241m",
    "\x1b[38;5;235m",
    "\x1b[38;5;241m",
    "\x1b[38;5;241m",
    "\x1b[38;5;243m",
    "\x1b[38;5;246m",
    "\x1b[38;5;238m",
    "\x1b[38;5;241m",
    "\x1b[38;5;241m",
} };

const ocean_dark = Palette{
    .styles = .{
        "\x1b[38;5;39m", // keyword   cyan
        "\x1b[38;5;69m", // type      blue
        "\x1b[38;5;252m", // function  bright neutral
        "\x1b[38;5;115m", // string    teal
        "\x1b[38;5;81m", // number    light blue
        "\x1b[38;5;241m", // comment   dim gray
        "\x1b[38;5;245m", // operator  gray
        "\x1b[38;5;116m", // constant  light cyan
        "\x1b[38;5;111m", // attribute light blue
        "\x1b[38;5;38m", // regex     cyan
    },
};

const ocean_light = Palette{
    .styles = .{
        "\x1b[38;5;24m", // keyword   deep cyan
        "\x1b[38;5;25m", // type      deep blue
        "\x1b[38;5;240m", // function  dark neutral
        "\x1b[38;5;30m", // string    teal
        "\x1b[38;5;27m", // number    blue
        "\x1b[38;5;244m", // comment   gray
        "\x1b[38;5;246m", // operator  gray
        "\x1b[38;5;31m", // constant  deep cyan
        "\x1b[38;5;33m", // attribute blue
        "\x1b[38;5;26m", // regex     deep cyan
    },
};

const ember_dark = Palette{
    .styles = .{
        "\x1b[38;5;209m", // keyword   orange
        "\x1b[38;5;174m", // type      rose
        "\x1b[38;5;252m", // function  bright neutral
        "\x1b[38;5;180m", // string    sand
        "\x1b[38;5;216m", // number    peach
        "\x1b[38;5;241m", // comment   dim gray
        "\x1b[38;5;245m", // operator  gray
        "\x1b[38;5;167m", // constant  rust
        "\x1b[38;5;137m", // attribute tan
        "\x1b[38;5;203m", // regex     red
    },
};

const ember_light = Palette{
    .styles = .{
        "\x1b[38;5;166m", // keyword   orange
        "\x1b[38;5;131m", // type      rose
        "\x1b[38;5;240m", // function  dark neutral
        "\x1b[38;5;94m", // string    olive
        "\x1b[38;5;173m", // number    rose
        "\x1b[38;5;244m", // comment   gray
        "\x1b[38;5;246m", // operator  gray
        "\x1b[38;5;130m", // constant  dark orange
        "\x1b[38;5;138m", // attribute tan
        "\x1b[38;5;124m", // regex     deep red
    },
};

/// The configured palette name, set from app config at startup and whenever
/// the user changes the setting. Mirrors the module-level theme styles in
/// `ui/render.zig`.
var active_syntax_theme: syntax_theme.Name = .default;

pub fn setSyntaxTheme(name: syntax_theme.Name) void {
    active_syntax_theme = name;
}

pub fn activeSyntaxTheme() syntax_theme.Name {
    return active_syntax_theme;
}

fn paletteFor(name: syntax_theme.Name, theme: Theme) Palette {
    const dark = theme == .dark;
    return switch (name) {
        .default => if (dark) default_dark else default_light,
        .mono => if (dark) mono_dark else mono_light,
        .ocean => if (dark) ocean_dark else ocean_light,
        .ember => if (dark) ember_dark else ember_light,
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
    const palette = paletteFor(active_syntax_theme, theme);

    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\n') {
            try styled.append(alloc, '\n');
            index += 1;
            continue;
        }
        if (blockCommentEnd(source, index, profile.block_comment)) |end| {
            try appendStyled(alloc, &styled, palette.style(.comment), source[index..end]);
            index = end;
            continue;
        }
        if (lineCommentEnd(source, index, profile.line_comments)) |end| {
            try appendStyled(alloc, &styled, palette.style(.comment), source[index..end]);
            index = end;
            continue;
        }
        if (attributeEnd(source, index, profile.attribute_prefixes)) |end| {
            try appendStyled(alloc, &styled, palette.style(.attribute), source[index..end]);
            index = end;
            continue;
        }
        if (tripleQuotedEnd(source, index, profile)) |end| {
            try appendStyled(alloc, &styled, palette.style(.string), source[index..end]);
            index = end;
            continue;
        }
        if (profile.template_quote) |quote| {
            if (source[index] == quote) {
                const end = templateEnd(source, index, quote);
                try appendStyled(alloc, &styled, palette.style(.string), source[index..end]);
                index = end;
                continue;
            }
        }
        if (isQuote(source[index], profile.quotes)) {
            const end = quotedEnd(source, index);
            try appendStyled(alloc, &styled, palette.style(.string), source[index..end]);
            index = end;
            continue;
        }
        if (profile.regex_literal) {
            if (regexLiteralEnd(source, index)) |end| {
                try appendStyled(alloc, &styled, palette.style(.regex), source[index..end]);
                index = end;
                continue;
            }
        }
        if (isNumberStart(source, index)) {
            const end = numberEnd(source, index);
            try appendStyled(alloc, &styled, palette.style(.number), source[index..end]);
            index = end;
            continue;
        }
        if (isIdentifierStart(source[index])) {
            const end = identifierEnd(source, index);
            const token = source[index..end];
            const role = identifierRole(source, index, end, token, profile);
            if (role) |styled_role| {
                try appendStyled(alloc, &styled, palette.style(styled_role), token);
            } else {
                try styled.appendSlice(alloc, token);
            }
            index = end;
            continue;
        }
        if (isOperatorByte(source[index])) {
            const end = operatorEnd(source, index);
            try appendStyled(alloc, &styled, palette.style(.operator), source[index..end]);
            index = end;
            continue;
        }
        try styled.append(alloc, source[index]);
        index += 1;
    }

    return styled.toOwnedSlice(alloc);
}

/// Keyword, literal, type, or call target — or null when the identifier
/// stays unstyled.
fn identifierRole(
    source: []const u8,
    start: usize,
    end: usize,
    token: []const u8,
    profile: *const languages.Profile,
) ?Role {
    if (inList(token, profile.keywords, profile.keyword_case)) return .keyword;
    if (inList(token, profile.literals, profile.keyword_case)) return .constant;
    if (inList(token, profile.types, profile.keyword_case)) return .type;
    if (profile.capitalized_types and token.len > 0 and std.ascii.isUpper(token[0])) return .type;
    if (isCallTarget(source, start, end, profile)) return .function;
    return null;
}

/// An identifier naming a function: either a call target (`name(`) or the
/// name token that follows a declaration keyword from the profile's
/// `function_keywords` list (`fn name`, `def name`, `func name`).
fn isCallTarget(source: []const u8, start: usize, end: usize, profile: *const languages.Profile) bool {
    if (end < source.len and source[end] == '(') return true;
    if (profile.function_keywords.len == 0 or start == 0) return false;
    var prev = start;
    while (prev > 0 and source[prev - 1] == ' ') prev -= 1;
    if (prev == 0) return false;
    const before = identifierStartBoundary(source, prev);
    if (before < prev) {
        return inList(source[before..prev], profile.function_keywords, .sensitive);
    }
    return false;
}

fn identifierStartBoundary(source: []const u8, index: usize) usize {
    var start = index;
    while (start > 0 and isIdentifierContinue(source[start - 1])) start -= 1;
    return start;
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

/// `"""..."""` / `'''...'''` spans, multiline allowed. Requires the byte at
/// `index` to be a configured quote repeated three times.
fn tripleQuotedEnd(source: []const u8, index: usize, profile: *const languages.Profile) ?usize {
    if (!profile.triple_quotes) return null;
    const quote = source[index];
    if (!isQuote(quote, profile.quotes)) return null;
    if (index + 2 >= source.len) return null;
    if (source[index + 1] != quote or source[index + 2] != quote) return null;
    var search = index + 3;
    while (search < source.len) : (search += 1) {
        if (source[search] == quote and search + 2 < source.len and
            source[search + 1] == quote and source[search + 2] == quote)
        {
            return search + 3;
        }
    }
    return source.len;
}

/// A multiline span to the same unescaped quote (template literals).
fn templateEnd(source: []const u8, start: usize, quote: u8) usize {
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\' and index + 1 < source.len) {
            index += 1;
            continue;
        }
        if (source[index] == quote) return index + 1;
    }
    return source.len;
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

/// `@name` / `#name` attributes and decorators. The prefix byte must be
/// followed by an identifier character.
fn attributeEnd(source: []const u8, index: usize, prefixes: []const u8) ?usize {
    if (prefixes.len == 0) return null;
    if (index + 1 >= source.len) return null;
    if (std.mem.indexOfScalar(u8, prefixes, source[index]) == null) return null;
    if (!isIdentifierStart(source[index + 1])) return null;
    // `identifierEnd` already returns one past the identifier starting at
    // index + 1, which covers the prefix byte at `index` too.
    return identifierEnd(source, index + 1);
}

/// Heuristic `/.../` literal for the JS/TS family: a slash following one of
/// `= ( , : ; ! & | ? { [ < + - * % ^ ~` or line start opens a regex; a
/// slash after an identifier, close bracket, or quote is division.
fn regexLiteralEnd(source: []const u8, start: usize) ?usize {
    if (source[start] != '/') return null;
    if (start + 1 >= source.len or source[start + 1] == '/' or source[start + 1] == '*') return null;
    var prev = start;
    while (prev > 0 and (source[prev - 1] == ' ' or source[prev - 1] == '\t')) prev -= 1;
    if (prev > 0) {
        const before = source[prev - 1];
        switch (before) {
            '=', '(', ',', ':', ';', '!', '&', '|', '?', '{', '[', '<', '+', '-', '*', '%', '^', '~' => {},
            else => return null,
        }
    }
    var index = start + 1;
    var in_class = false;
    while (index < source.len) : (index += 1) {
        const byte = source[index];
        if (byte == '\n') return null;
        if (byte == '\\' and index + 1 < source.len) {
            index += 1;
            continue;
        }
        if (byte == '[') {
            in_class = true;
            continue;
        }
        if (byte == ']') {
            in_class = false;
            continue;
        }
        if (byte == '/' and !in_class) {
            // Flags (`gimsu`) belong to the literal.
            var end = index + 1;
            while (end < source.len and isIdentifierContinue(source[end])) : (end += 1) {}
            return end;
        }
    }
    return null;
}

fn isNumberStart(source: []const u8, index: usize) bool {
    return std.ascii.isDigit(source[index]) and (index == 0 or !isIdentifierContinue(source[index - 1]));
}

fn numberEnd(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '.' or source[index] == '_')) : (index += 1) {}
    // Scientific notation exponent sign: `1e-9` keeps the sign inside the
    // number token.
    if (index > start and index + 1 < source.len) {
        const last = source[index - 1];
        if ((last == 'e' or last == 'E') and (source[index] == '+' or source[index] == '-')) {
            index += 1;
            while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '.' or source[index] == '_')) : (index += 1) {}
        }
    }
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

fn isOperatorByte(byte: u8) bool {
    return switch (byte) {
        '=', '+', '-', '*', '/', '%', '<', '>', '!', '&', '|', '^', '~', '?', ':', '.', '@' => true,
        else => false,
    };
}

fn operatorEnd(source: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < source.len and isOperatorByte(source[index])) : (index += 1) {}
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

test "supported source gains balanced colors without changing code bytes" {
    setSyntaxTheme(.default);
    const alloc = std.testing.allocator;
    const source = "const value = \"const\"; // return\n";
    const styled = try highlight(alloc, source, languages.resolve("zig").?, .dark);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;") != null);
    try std.testing.expectEqual(count(styled, "\x1b[38;5;"), count(styled, "\x1b[39m"));
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;214mconst") != null);
    try std.testing.expectEqual(@as(usize, 1), count(styled, "\x1b[38;5;214mconst"));
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;114m\"const\"\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;214mreturn") == null);
}

test "light theme uses a readable syntax palette without changing code bytes" {
    setSyntaxTheme(.default);
    const alloc = std.testing.allocator;
    const source = "const value = \"ready\"; // comment\n";
    const styled = try highlight(alloc, source, languages.resolve("zig").?, .light);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;130mconst\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;71m\"ready\"\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;244m// comment\x1b[39m") != null);
    try std.testing.expectEqual(count(styled, "\x1b[38;5;"), count(styled, "\x1b[39m"));
}

test "types, functions, operators, and constants render distinctly" {
    setSyntaxTheme(.default);
    const alloc = std.testing.allocator;
    const source = "function render(rows: number): string { return rows.map(fmt).join(\" \"); }\n";
    const styled = try highlight(alloc, source, languages.resolve("ts").?, .dark);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;214mfunction\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;252mrender\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;74mnumber\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;74mstring\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;252mmap\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;245m.\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;114m\" \"\x1b[39m") != null);
}

test "capitalized identifiers read as types and attributes carry their own role" {
    setSyntaxTheme(.default);
    const alloc = std.testing.allocator;
    const source = "@deprecated\nfunction Ready(): Promise<void> { return Promise.resolve(true); }\n";
    const styled = try highlight(alloc, source, languages.resolve("ts").?, .dark);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;141m@deprecated\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;74mPromise\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;209mtrue\x1b[39m") != null);
}

test "regex literals highlight only after regex-opening context" {
    setSyntaxTheme(.default);
    const alloc = std.testing.allocator;
    const source = "const re = /ab+c/gi;\nconst ratio = value / total;\n";
    const styled = try highlight(alloc, source, languages.resolve("ts").?, .dark);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;173m/ab+c/gi\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;173mvalue") == null);
    // The division slash stays an operator.
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;245m/\x1b[39m") != null);
}

test "python triple-quoted strings and decorators receive their roles" {
    setSyntaxTheme(.default);
    const alloc = std.testing.allocator;
    const source = "@staticmethod\ndef ready() -> bool:\n    \"\"\"docs\n    continue\"\"\"\n    return True\n";
    const styled = try highlight(alloc, source, languages.resolve("python").?, .dark);
    defer alloc.free(styled);

    const plain = try stripAnsi(alloc, styled);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings(source, plain);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;141m@staticmethod\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;252mready\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;74mbool\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;114m\"\"\"docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "continue\"\"\"\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;209mTrue\x1b[39m") != null);
}

test "mono palette restores the grayscale hierarchy" {
    setSyntaxTheme(.mono);
    defer setSyntaxTheme(.default);
    const alloc = std.testing.allocator;
    const source = "fn ready() void { return; }\n";
    const styled = try highlight(alloc, source, languages.resolve("zig").?, .dark);
    defer alloc.free(styled);

    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;252mfn\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;255mready\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;214m") == null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;74m") == null);
}

test "every registered profile highlights representative source" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        label: []const u8,
        source: []const u8,
    }{
        .{ .label = "zig", .source = "pub fn main() void { return; }" },
        .{ .label = "ts", .source = "const ready = true;" },
        .{ .label = "json", .source = "{\"ready\": true}" },
        .{ .label = "sh", .source = "if true; then echo \"ready\"; fi" },
        .{ .label = "python", .source = "def ready(): return True" },
        .{ .label = "yaml", .source = "ready: true # comment" },
        .{ .label = "toml", .source = "ready = true # comment" },
        .{ .label = "sql", .source = "SELECT id FROM users" },
        .{ .label = "dockerfile", .source = "FROM alpine:3.20" },
        .{ .label = "rust", .source = "fn main() { let ready = true; }" },
        .{ .label = "go", .source = "package main\nfunc main() {}" },
        .{ .label = "c", .source = "int main(void) { return 0; }" },
        .{ .label = "cpp", .source = "class Ready { public: bool value = true; };" },
        .{ .label = "csharp", .source = "public class Ready { }" },
        .{ .label = "java", .source = "public class Ready { }" },
        .{ .label = "kotlin", .source = "fun ready(): Boolean = true" },
        .{ .label = "php", .source = "<?php function ready() { return true; }" },
        .{ .label = "ruby", .source = "def ready\n  true\nend" },
        .{ .label = "swift", .source = "func ready() -> Bool { true }" },
        .{ .label = "powershell", .source = "Function Ready { return $true }" },
        .{ .label = "lua", .source = "local ready = true" },
        .{ .label = "html", .source = "<main class=\"ready\"></main>" },
        .{ .label = "xml", .source = "<?xml version=\"1.0\"?>" },
        .{ .label = "css", .source = ".ready { color: red; }" },
        .{ .label = "hcl", .source = "resource \"ready\" \"main\" {}" },
    };

    for (cases) |case| {
        const styled = try highlight(alloc, case.source, languages.resolve(case.label).?, .dark);
        defer alloc.free(styled);
        const plain = try stripAnsi(alloc, styled);
        defer alloc.free(plain);
        try std.testing.expectEqualStrings(case.source, plain);
        try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[38;5;") != null);
    }
}

test "profiles use configured block comments and case-insensitive keywords" {
    setSyntaxTheme(.default);
    const alloc = std.testing.allocator;
    const source = "/* comment */\nSELECT id FROM users\n<!-- note -->";
    const css = try highlight(alloc, source[0..13], languages.resolve("css").?, .dark);
    defer alloc.free(css);
    const sql = try highlight(alloc, source[14..34], languages.resolve("sql").?, .dark);
    defer alloc.free(sql);
    const html = try highlight(alloc, source[35..], languages.resolve("html").?, .dark);
    defer alloc.free(html);

    try std.testing.expect(std.mem.indexOf(u8, css, "\x1b[38;5;241m/* comment */\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\x1b[38;5;214mSELECT\x1b[39m") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\x1b[38;5;241m<!-- note -->\x1b[39m") != null);
}
