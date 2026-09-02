const std = @import("std");
const unicode_data = @import("unicode_display_data.zig");

const RgiNode = packed struct(u32) {
    edge_start: u13,
    edge_len: u8,
    terminal: bool,
    padding: u10 = 0,
};

const rgi_codepoint_count: usize = blk: {
    @setEvalBranchQuota(2_000_000);
    var unique: [unicode_data.rgi_trie_edges.len]u21 = undefined;
    var count: usize = 0;
    for (unicode_data.rgi_trie_edges) |edge| {
        var seen = false;
        for (unique[0..count]) |codepoint| {
            if (codepoint == edge.codepoint) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            unique[count] = edge.codepoint;
            count += 1;
        }
    }
    break :blk count;
};

const RgiData = struct {
    nodes: [unicode_data.rgi_trie_nodes.len]RgiNode,
    edge_codepoint_ids: [unicode_data.rgi_trie_edges.len]u8,
    codepoints: [rgi_codepoint_count]u21,
};

const rgi_data: RgiData = blk: {
    @setEvalBranchQuota(2_000_000);
    if (rgi_codepoint_count > std.math.maxInt(u8) + 1) {
        @compileError("RGI trie edge alphabet no longer fits in u8");
    }

    var data: RgiData = undefined;
    var codepoint_count: usize = 0;
    for (unicode_data.rgi_trie_edges, 0..) |edge, edge_index| {
        if (edge.child != edge_index + 1) {
            @compileError("RGI trie child numbering is no longer implicit");
        }

        var codepoint_id: ?u8 = null;
        for (data.codepoints[0..codepoint_count], 0..) |codepoint, index| {
            if (codepoint == edge.codepoint) {
                codepoint_id = @intCast(index);
                break;
            }
        }
        if (codepoint_id == null) {
            codepoint_id = @intCast(codepoint_count);
            data.codepoints[codepoint_count] = edge.codepoint;
            codepoint_count += 1;
        }
        data.edge_codepoint_ids[edge_index] = codepoint_id.?;
    }
    if (codepoint_count != rgi_codepoint_count) {
        @compileError("RGI trie edge alphabet count mismatch");
    }

    for (unicode_data.rgi_trie_nodes, 0..) |node, index| {
        data.nodes[index] = .{
            .edge_start = @intCast(node.edge_start),
            .edge_len = @intCast(node.edge_len),
            .terminal = node.terminal,
        };
    }
    break :blk data;
};

pub const DecodedRune = struct {
    len: usize,
    codepoint: u21,
};

pub const DisplayUnit = struct {
    byte_len: usize,
    cell_width: usize,
};

pub noinline fn visibleWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const unit = displayUnitAt(text, i);
        width +|= unit.cell_width;
        i += unit.byte_len;
    }
    return width;
}

// Same as visibleWidth, but skips over ANSI escape sequences so callers can
// measure the rendered cell width of text that already contains styling.
pub noinline fn visibleWidthIgnoringAnsi(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i = ansiSequenceEnd(text, i);
            continue;
        }
        const unit = displayUnitAt(text, i);
        width +|= unit.cell_width;
        i += unit.byte_len;
    }
    return width;
}

// Returns the first variant whose visible width fits max_width, falling back
// to the last (shortest) variant so callers always get something to clip.
pub noinline fn widestFitting(variants: []const []const u8, max_width: usize) []const u8 {
    std.debug.assert(variants.len > 0);
    for (variants) |variant| {
        if (visibleWidth(variant) <= max_width) return variant;
    }
    return variants[variants.len - 1];
}

pub noinline fn prefixByWidth(text: []const u8, max_width: usize) []const u8 {
    if (max_width == 0) return "";

    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const unit = displayUnitAt(text, i);
        if (unit.cell_width > max_width - width) break;
        width += unit.cell_width;
        i += unit.byte_len;
    }
    return text[0..i];
}

// Same as prefixByWidth, but skips ANSI escape sequences so callers can clip
// text that already carries styling bytes without the escape sequences eating
// into the width budget.
pub noinline fn prefixByWidthIgnoringAnsi(text: []const u8, max_width: usize) []const u8 {
    if (max_width == 0) return "";

    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i = ansiSequenceEnd(text, i);
            continue;
        }
        const unit = displayUnitAt(text, i);
        if (unit.cell_width > max_width - width) break;
        width += unit.cell_width;
        i += unit.byte_len;
    }
    return text[0..i];
}

pub noinline fn suffixByWidth(text: []const u8, max_width: usize) []const u8 {
    if (max_width == 0) return text[text.len..];

    var remaining = visibleWidth(text);
    if (remaining <= max_width) return text;

    var i: usize = 0;
    while (i < text.len and remaining > max_width) {
        const unit = displayUnitAt(text, i);
        remaining -= unit.cell_width;
        i += unit.byte_len;
    }
    return text[i..];
}

// Same as suffixByWidth, but ANSI-aware. Walks forward so escape sequences
// stay attached to the visible rune that follows them; splitting an OSC-8
// open/close pair would leak a dangling hyperlink into the terminal.
pub noinline fn suffixByWidthIgnoringAnsi(text: []const u8, max_width: usize) []const u8 {
    if (max_width == 0) return text[text.len..];

    const total = visibleWidthIgnoringAnsi(text);
    if (total <= max_width) return text;

    var remaining = total;
    var i: usize = 0;
    while (i < text.len and remaining > max_width) {
        if (text[i] == 0x1b) {
            i = ansiSequenceEnd(text, i);
            continue;
        }
        const unit = displayUnitAt(text, i);
        remaining -= unit.cell_width;
        i += unit.byte_len;
    }
    return text[i..];
}

pub noinline fn displayUnitAt(text: []const u8, index: usize) DisplayUnit {
    if (index >= text.len) return .{ .byte_len = 0, .cell_width = 0 };

    const first_byte = text[index];
    const may_start_keycap = (first_byte == '#' or first_byte == '*' or
        (first_byte >= '0' and first_byte <= '9')) and
        hasRgiKeycapSuffix(text, index + 1);
    if (first_byte < 0x80 and !may_start_keycap) {
        const cell_width: usize = if (first_byte == 0 or first_byte < 32 or first_byte == 0x7f) 0 else 1;
        return .{ .byte_len = 1, .cell_width = cell_width };
    }

    const rgi_len = matchRgiSequence(text, index);
    if (rgi_len != 0) return .{ .byte_len = rgi_len, .cell_width = 2 };

    const first = decodeNextRune(text, index);
    const next_index = index + first.len;
    if (next_index < text.len and isInRanges(first.codepoint, unicode_data.variation_bases[0..])) {
        const selector = decodeNextRune(text, next_index);
        if (selector.codepoint == 0xfe0e) {
            const cell_width: usize = if (isInRanges(first.codepoint, unicode_data.wide_ranges[0..])) 2 else 1;
            return .{ .byte_len = first.len + selector.len, .cell_width = cell_width };
        }
        if (selector.codepoint == 0xfe0f) {
            return .{ .byte_len = first.len + selector.len, .cell_width = 2 };
        }
    }

    return .{ .byte_len = first.len, .cell_width = runeWidth(first.codepoint) };
}

fn hasRgiKeycapSuffix(text: []const u8, suffix_start: usize) bool {
    const variation_selector_16 = "\xef\xb8\x8f";
    const combining_keycap = "\xe2\x83\xa3";
    var index = suffix_start;
    if (std.mem.startsWith(u8, text[index..], variation_selector_16)) {
        index += variation_selector_16.len;
    }
    return std.mem.startsWith(u8, text[index..], combining_keycap);
}

noinline fn runeWidth(codepoint: u21) usize {
    if (codepoint == 0) return 0;
    if (codepoint < 32 or (codepoint >= 0x7f and codepoint < 0xa0)) return 0;
    if (isZeroWidthContinuation(codepoint)) return 0;
    if (isInRanges(codepoint, unicode_data.wide_ranges[0..]) or
        isInRanges(codepoint, unicode_data.emoji_presentation_ranges[0..])) return 2;
    return 1;
}

/// Returns whether width `w` at one-based `col` exceeds `cols` under DECAWM-OFF.
/// Requires non-zero inputs and widens arithmetic to avoid `u16` overflow.
pub fn shouldWrapAt(col: u16, w: u16, cols: u16) bool {
    return @as(u32, col) + @as(u32, w) - 1 > @as(u32, cols);
}

/// Returns the next fixed eight-column tab stop, clamped to the right margin.
/// Columns are one-based. Callers must provide non-zero `col` and `cols`.
pub fn nextTabStopColumn(col: u16, cols: u16) u16 {
    std.debug.assert(col > 0);
    std.debug.assert(cols > 0);
    if (col >= cols) return cols;

    const zero_based: u32 = @as(u32, col) - 1;
    const next_stop = ((zero_based / 8) + 1) * 8 + 1;
    return @intCast(@min(next_stop, @as(u32, cols)));
}

pub noinline fn decodeNextRune(text: []const u8, index: usize) DecodedRune {
    if (index >= text.len) return .{ .len = 0, .codepoint = 0 };
    const first = text[index];
    if (first < 0x80) return .{ .len = 1, .codepoint = first };

    const len = std.unicode.utf8ByteSequenceLength(first) catch return .{ .len = 1, .codepoint = 0xfffd };
    if (index + len > text.len) return .{ .len = 1, .codepoint = 0xfffd };

    const codepoint = std.unicode.utf8Decode(text[index .. index + len]) catch return .{ .len = 1, .codepoint = 0xfffd };
    return .{ .len = len, .codepoint = codepoint };
}

pub noinline fn ansiSequenceEnd(text: []const u8, index: usize) usize {
    if (index >= text.len or text[index] != 0x1b) return index;
    if (index + 1 >= text.len) return text.len;

    const kind = text[index + 1];
    if (kind == '[') {
        var i = index + 2;
        while (i < text.len) : (i += 1) {
            const b = text[i];
            if (b >= '@' and b <= '~') return i + 1;
        }
        return text.len;
    }

    if (kind == ']') {
        var i = index + 2;
        while (i < text.len) : (i += 1) {
            if (text[i] == 0x07) return i + 1;
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
        }
        return text.len;
    }

    return @min(index + 2, text.len);
}

pub noinline fn previousRuneStart(text: []const u8, end: usize) usize {
    if (end == 0) return 0;
    var i = end - 1;
    while (i > 0 and (text[i] & 0b1100_0000) == 0b1000_0000) : (i -= 1) {}
    return i;
}

pub noinline fn statusPrefixEnd(label: []const u8) usize {
    if (label.len == 0) return 0;
    const first = displayUnitAt(label, 0);
    if (first.byte_len == 0 or first.byte_len >= label.len) return 0;
    return if (label[first.byte_len] == ' ') first.byte_len + 1 else 0;
}

pub noinline fn wrapCutIgnoringAnsi(text: []const u8, max_width: usize) []const u8 {
    const prefix = prefixByWidthIgnoringAnsi(text, max_width);
    if (prefix.len == text.len) return prefix;

    var last_space: ?usize = null;
    var index: usize = 0;
    while (index < prefix.len) {
        const unit = displayUnitAt(prefix, index);
        if (prefix[index] == ' ' or prefix[index] == '\t') last_space = index;
        index += unit.byte_len;
    }
    if (last_space) |space_index| {
        if (space_index > 0) return text[0..space_index];
    }
    return prefix;
}

pub noinline fn trimBreakWhitespace(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
    return text[index..];
}

fn isCombining(codepoint: u21) bool {
    return (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f) or
        (codepoint >= 0xfe00 and codepoint <= 0xfe0f);
}

fn isZeroWidthContinuation(codepoint: u21) bool {
    return isCombining(codepoint) or
        isInRanges(codepoint, unicode_data.emoji_modifier_ranges[0..]) or
        codepoint == 0x200c or
        codepoint == 0x200d or
        (codepoint >= 0x200b and codepoint <= 0x200f) or
        (codepoint >= 0x202a and codepoint <= 0x202e) or
        (codepoint >= 0x2060 and codepoint <= 0x206f) or
        codepoint == 0xfeff or
        (codepoint >= 0xe0001 and codepoint <= 0xe007f) or
        (codepoint >= 0xe0100 and codepoint <= 0xe01ef);
}

fn isInRanges(codepoint: u21, ranges: []const unicode_data.Range) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const range = ranges[middle];
        if (codepoint < range.first) {
            high = middle;
        } else if (codepoint > range.last) {
            low = middle + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn matchRgiSequence(text: []const u8, index: usize) usize {
    var node_index: u32 = 0;
    var cursor = index;
    var longest: usize = 0;
    var depth: usize = 0;

    while (cursor < text.len and depth < unicode_data.max_rgi_sequence_codepoints) : (depth += 1) {
        const rune = decodeNextRune(text, cursor);
        node_index = findTrieChild(node_index, rune.codepoint) orelse break;
        cursor += rune.len;
        const node = rgi_data.nodes[node_index];
        if (node.terminal) longest = cursor - index;
    }

    return longest;
}

fn findTrieChild(node_index: u32, codepoint: u21) ?u32 {
    const node = rgi_data.nodes[node_index];
    const edge_start: usize = node.edge_start;
    var low = edge_start;
    var high = edge_start + node.edge_len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const edge_codepoint = rgi_data.codepoints[rgi_data.edge_codepoint_ids[middle]];
        if (codepoint < edge_codepoint) {
            high = middle;
        } else if (codepoint > edge_codepoint) {
            low = middle + 1;
        } else {
            return @intCast(middle + 1);
        }
    }
    return null;
}






























fn fuzzDisplayUnitBoundaries(_: void, smith: *std.testing.Smith) !void {
    var buffer: [256]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const text = buffer[0..len];

    var expected_width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const unit = displayUnitAt(text, index);
        try std.testing.expect(unit.byte_len > 0);
        try std.testing.expect(unit.byte_len <= text.len - index);
        try std.testing.expect(unit.cell_width <= 2);
        try std.testing.expectEqual(unit, displayUnitAt(text, index));
        expected_width +|= unit.cell_width;
        index += unit.byte_len;
    }
    try std.testing.expectEqual(text.len, index);
    try std.testing.expectEqual(expected_width, visibleWidth(text));

    const budgets = [_]usize{
        0,
        @min(expected_width / 2, 16),
        @min(expected_width +| 2, 16),
    };
    for (budgets) |budget| {
        const prefix = prefixByWidth(text, budget);
        const suffix = suffixByWidth(text, budget);
        try std.testing.expect(isDisplayUnitBoundary(text, prefix.len));
        try std.testing.expect(isDisplayUnitBoundary(text, text.len - suffix.len));
        try std.testing.expect(visibleWidth(prefix) <= budget);
        try std.testing.expect(visibleWidth(suffix) <= budget);
    }
}

fn isDisplayUnitBoundary(text: []const u8, target: usize) bool {
    if (target > text.len) return false;
    var index: usize = 0;
    while (index < target) {
        const unit = displayUnitAt(text, index);
        if (unit.byte_len == 0 or unit.byte_len > target - index) return false;
        index += unit.byte_len;
    }
    return index == target;
}
