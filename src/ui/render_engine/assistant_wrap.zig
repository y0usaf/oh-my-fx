const std = @import("std");
const build_checkpoint = @import("build_checkpoint.zig");
const display_width = @import("../../core/shared/display_width.zig");
const assistant_pacer = @import("../assistant/pacer.zig");

const Allocator = std.mem.Allocator;

/// A pathological combining-mark run gets a physical row boundary at this
/// byte count. The source bytes remain exact while every retained row stays
/// bounded for compact and full-view projection.
pub const literal_command_zero_width_row_byte_limit: usize = 256;

const WordBreak = struct {
    start: usize,
    end: usize,
    sgr: assistant_pacer.SgrState,
    hyperlink: ?[]const u8,
    has_preceding_word: bool,
};

/// The last two space runs on the current row, kept as reflow points for
/// overflow wrapping and orphan avoidance.
const WordBreaks = struct {
    last: ?WordBreak = null,
    previous: ?WordBreak = null,

    /// Extends `last` when adjacent; otherwise demotes it to `previous`.
    fn record(self: *WordBreaks, word_break: WordBreak) void {
        if (self.last) |*last| {
            if (last.end == word_break.start) {
                last.end = word_break.end;
                return;
            }
            self.previous = last.*;
        }
        self.last = word_break;
    }
};

const Osc8Update = union(enum) {
    open: []const u8,
    close,
};

const AssistantContinuation = union(enum) {
    list_indent: usize,
    blockquote: struct {
        indent: usize,
        depth: usize,
    },
};

/// Reflow assistant text to fit within `cols` while preserving inline
/// SGR attributes and OSC 8 links across wrap boundaries. Paragraphs wrap at whitespace
/// and move a preceding word down when that avoids a single-word tail.
/// Pre-existing hard newlines in `text` are honoured. The returned slice is
/// owned by the caller and freed with `alloc`.
pub fn wrapAssistantText(alloc: Allocator, text: []const u8, cols: u16) ![]u8 {
    return wrapAssistantTextWithBaseGutter(alloc, text, cols, 0, false, false, null, null);
}

fn wrapAssistantTextWithBaseGutter(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    base_gutter: u16,
    replace_wide_runes_at_one_content_col: bool,
    literal_command: bool,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
    finalized_prefix_bytes: ?*usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (finalized_prefix_bytes) |bytes| bytes.* = 0;
    var finalized_source_end: usize = 0;
    if (finalized_prefix_bytes != null) {
        if (std.mem.findScalarLast(u8, text, '\n')) |newline| {
            finalized_source_end = newline + 1;
        }
    }

    if (cols == 0) {
        return out.toOwnedSlice(alloc);
    }
    if (text.len == 0) {
        if (literal_command) {
            try appendAssistantRowStart(
                alloc,
                &out,
                base_gutter,
                .{},
                null,
                true,
            );
        }
        return out.toOwnedSlice(alloc);
    }

    var sgr: assistant_pacer.SgrState = .{};
    var hyperlink: ?[]const u8 = null;
    const content_cols = cols -| base_gutter;
    var col: u16 = base_gutter + 1;
    var continuation = if (literal_command) null else assistantContinuation(text, 0);
    var word_breaks: WordBreaks = .{};
    var has_word_on_row = false;
    var row_has_content = false;
    var zero_width_run_bytes: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        try build_checkpoint.tick(checkpoint);
        if (!row_has_content and !literal_command) {
            if (infeasibleMarkerEnd(text, i, base_gutter, cols)) |marker_end| {
                i = marker_end;
                continue;
            }
        }

        const ch = text[i];

        if (ch == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, i);
            if (end <= i) {
                // Preserve an incomplete trailing escape without stalling the loop.
                try out.appendSlice(alloc, text[i..]);
                break;
            }
            const seq = text[i..end];
            sgr.apply(seq);
            if (osc8Update(seq)) |update| switch (update) {
                .open => |open| hyperlink = open,
                .close => hyperlink = null,
            };
            if (base_gutter == 0 or row_has_content) try out.appendSlice(alloc, seq);
            i = end;
            continue;
        }

        if (ch == '\r' or ch == '\n') {
            if (literal_command and !row_has_content) {
                try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, true);
            }
            if (base_gutter > 0 and row_has_content) try closeAssistantRowStyles(alloc, &out, sgr, hyperlink);
            try out.append(alloc, ch);
            col = base_gutter + 1;
            i += 1;
            if (finalized_prefix_bytes) |bytes| {
                if (i == finalized_source_end) bytes.* = out.items.len;
            }
            continuation = if (literal_command) null else assistantContinuation(text, i);
            word_breaks = .{};
            has_word_on_row = false;
            row_has_content = false;
            zero_width_run_bytes = 0;
            continue;
        }
        if (ch == '\t') {
            if (base_gutter > 0 and !row_has_content) {
                try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, literal_command);
                row_has_content = true;
            }
            const next_col = display_width.nextTabStopColumn(col, cols);
            try out.appendNTimes(alloc, ' ', next_col -| col);
            col = @max(col, next_col);
            i += 1;
            zero_width_run_bytes = 0;
            continue;
        }
        if (ch < 32) {
            if (base_gutter == 0 or row_has_content) try out.append(alloc, ch);
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, i);
        const w_usize = unit.cell_width;
        if (w_usize == 0) {
            if (literal_command and
                zero_width_run_bytes +| unit.byte_len > literal_command_zero_width_row_byte_limit)
            {
                col = try appendAssistantContinuation(
                    alloc,
                    &out,
                    sgr,
                    hyperlink,
                    continuation,
                    cols,
                    base_gutter,
                    1,
                    true,
                );
                word_breaks = .{};
                has_word_on_row = false;
                row_has_content = true;
                zero_width_run_bytes = 0;
            }
            if (base_gutter > 0 and !row_has_content) {
                try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, literal_command);
                row_has_content = true;
            }
            try out.appendSlice(alloc, text[i .. i + unit.byte_len]);
            if (literal_command) zero_width_run_bytes += unit.byte_len;
            i += unit.byte_len;
            continue;
        } else if (literal_command) {
            zero_width_run_bytes = 0;
        }
        const replace_wide_unit = replace_wide_runes_at_one_content_col and content_cols == 1 and w_usize == 2;
        const w: u16 = if (replace_wide_unit) 1 else @intCast(w_usize);

        if (ch == ' ' and display_width.shouldWrapAt(col, w, cols)) {
            var moved_for_orphan = false;
            if (word_breaks.last) |word_break| {
                const next_word_start = i + unit.byte_len;
                if (remainingWordWidth(text, next_word_start) > 0 and
                    isFinalWordOnLine(text, next_word_start) and
                    wordBreakFits(out.items[word_break.end..], text, next_word_start, continuation, cols, base_gutter))
                {
                    const next_width = firstVisibleWidth(text[next_word_start..]) orelse w;
                    if (try reflowAtWordBreak(
                        alloc,
                        &out,
                        word_break,
                        continuation,
                        cols,
                        base_gutter,
                        next_width,
                        literal_command,
                    )) |reflowed_col| {
                        col = reflowed_col;
                        word_breaks = .{};
                        has_word_on_row = true;
                        row_has_content = true;
                        moved_for_orphan = true;
                    }
                }
            }
            if (!moved_for_orphan) {
                col = try appendAssistantContinuation(
                    alloc,
                    &out,
                    sgr,
                    hyperlink,
                    continuation,
                    cols,
                    base_gutter,
                    w,
                    literal_command,
                );
                word_breaks = .{};
                has_word_on_row = false;
                row_has_content = true;
                i += unit.byte_len;
                continue;
            }
        }

        if (display_width.shouldWrapAt(col, w, cols)) {
            if (word_breaks.last) |word_break| {
                var break_to_use = word_break;
                if (word_breaks.previous) |previous| {
                    if (previous.has_preceding_word and
                        isFinalWordOnLine(text, i) and
                        wordBreakFits(out.items[previous.end..], text, i, continuation, cols, base_gutter))
                    {
                        break_to_use = previous;
                    }
                }

                if (try reflowAtWordBreak(
                    alloc,
                    &out,
                    break_to_use,
                    continuation,
                    cols,
                    base_gutter,
                    w,
                    literal_command,
                )) |reflowed_col| {
                    col = reflowed_col;
                    word_breaks = .{};
                    row_has_content = true;
                }
            }
        }

        if (display_width.shouldWrapAt(col, w, cols)) {
            col = try appendAssistantContinuation(
                alloc,
                &out,
                sgr,
                hyperlink,
                continuation,
                cols,
                base_gutter,
                w,
                literal_command,
            );
            word_breaks = .{};
            has_word_on_row = false;
            row_has_content = true;
        }

        if (base_gutter > 0 and !row_has_content) {
            try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, literal_command);
            row_has_content = true;
        }

        const space_start = out.items.len;
        if (replace_wide_unit) {
            try out.append(alloc, '?');
        } else {
            try out.appendSlice(alloc, text[i .. i + unit.byte_len]);
        }
        col += w;
        if (ch == ' ' and has_word_on_row and !isContinuationMarkerSeparator(col - 1, continuation, base_gutter)) {
            word_breaks.record(.{
                .start = space_start,
                .end = out.items.len,
                .sgr = sgr,
                .hyperlink = hyperlink,
                .has_preceding_word = word_breaks.last != null,
            });
        } else if (ch != ' ') {
            has_word_on_row = true;
        }
        i += unit.byte_len;
    }

    if (literal_command and !row_has_content) {
        try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, true);
    }

    return out.toOwnedSlice(alloc);
}

fn closeAssistantRowStyles(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    sgr: assistant_pacer.SgrState,
    hyperlink: ?[]const u8,
) !void {
    if (sgr.isActive()) try out.appendSlice(alloc, "\x1b[0m");
    if (hyperlink != null) try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
}

fn appendAssistantRowStart(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    base_gutter: u16,
    sgr: assistant_pacer.SgrState,
    hyperlink: ?[]const u8,
    literal_command: bool,
) !void {
    if (literal_command and base_gutter >= 2) {
        try out.appendSlice(alloc, "│ ");
        try out.appendNTimes(alloc, ' ', base_gutter - 2);
    } else {
        try out.appendNTimes(alloc, ' ', base_gutter);
    }
    if (sgr.isActive()) {
        var reopen: [64]u8 = undefined;
        const n = sgr.writeOpens(reopen[0..]);
        try out.appendSlice(alloc, reopen[0..n]);
    }
    if (hyperlink) |open| try out.appendSlice(alloc, open);
}

pub fn gutterWidth(cols: u16) u16 {
    return if (cols >= 3) 2 else if (cols == 2) 1 else 0;
}

pub fn prefixStructuralRows(alloc: Allocator, bytes: []const u8, gutter: u16) ![]u8 {
    if (gutter == 0 or bytes.len == 0) return alloc.dupe(u8, bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var line_start: usize = 0;
    while (line_start < bytes.len) {
        const newline = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n');
        const line_end = newline orelse bytes.len;
        if (firstVisibleWidth(bytes[line_start..line_end]) != null) {
            try out.appendNTimes(alloc, ' ', gutter);
        }
        try out.appendSlice(alloc, bytes[line_start..line_end]);
        if (newline) |_| try out.append(alloc, '\n');
        line_start = line_end + 1;
    }
    return out.toOwnedSlice(alloc);
}

pub fn wrapTranscriptAssistantTextInterruptible(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) ![]u8 {
    return wrapAssistantTextWithBaseGutter(
        alloc,
        text,
        cols,
        gutterWidth(cols),
        true,
        false,
        checkpoint,
        null,
    );
}

/// `bytes` is owned by the caller. `finalized_prefix_bytes` ends after the
/// last source hard newline and excludes soft wraps from the unfinished line.
pub const TranscriptAssistantWrap = struct {
    bytes: []u8,
    finalized_prefix_bytes: usize,
};

pub fn wrapTranscriptAssistantTextWithFinalityInterruptible(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !TranscriptAssistantWrap {
    var finalized_prefix_bytes: usize = 0;
    const bytes = try wrapAssistantTextWithBaseGutter(
        alloc,
        text,
        cols,
        gutterWidth(cols),
        true,
        false,
        checkpoint,
        &finalized_prefix_bytes,
    );
    return .{
        .bytes = bytes,
        .finalized_prefix_bytes = finalized_prefix_bytes,
    };
}

/// Reflow canonical command output as literal terminal text. Every physical
/// row owns its gutter; Markdown continuation markers are deliberately not
/// interpreted, and tabs advance to the terminal's absolute eight-column
/// stops. The returned slice is owned by the caller.
pub fn wrapLiteralCommandOutput(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (cols == 0) return alloc.alloc(u8, 0);
    const gutter = if (cols >= 3) @as(u16, 2) else @as(u16, 0);
    return wrapAssistantTextWithBaseGutter(
        alloc,
        text,
        cols,
        gutter,
        true,
        true,
        null,
        null,
    );
}

/// Reflows literal tool detail with the three-cell rail used by Ctrl-O.
pub fn wrapLiteralToolOutput(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    return wrapLiteralToolOutputInterruptible(alloc, text, cols, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn wrapLiteralToolOutputInterruptible(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) ![]u8 {
    if (cols == 0) return alloc.alloc(u8, 0);
    const gutter = if (cols >= 4) @as(u16, 3) else if (cols >= 3) @as(u16, 2) else @as(u16, 0);
    return wrapAssistantTextWithBaseGutter(
        alloc,
        text,
        cols,
        gutter,
        true,
        true,
        checkpoint,
        null,
    );
}

pub const LiteralCommandOutputPrefix = struct {
    bytes: []u8,
    has_more: bool,

    pub fn deinit(self: *LiteralCommandOutputPrefix, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

/// Bounded compact projection. It retains three rows of lookahead so the
/// assistant wrapper's word/orphan decision for the admitted rows is stable,
/// but never scans or allocates in proportion to an oversized record.
pub fn wrapLiteralCommandOutputPrefix(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    row_limit: usize,
) !LiteralCommandOutputPrefix {
    if (row_limit == 0 or cols == 0) {
        return .{
            .bytes = try alloc.alloc(u8, 0),
            .has_more = text.len > 0,
        };
    }

    const lookahead_rows = row_limit +| 3;
    const source_end = literalLookaheadEnd(text, cols, lookahead_rows);
    const wrapped = try wrapLiteralCommandOutput(alloc, text[0..source_end], cols);
    defer alloc.free(wrapped);
    const prefix = literalPhysicalRowPrefix(wrapped, row_limit);
    return .{
        .bytes = try alloc.dupe(u8, prefix),
        .has_more = source_end < text.len or
            literalHardLineCount(wrapped) > row_limit,
    };
}

fn literalLookaheadEnd(text: []const u8, cols: u16, row_limit: usize) usize {
    const gutter: u16 = if (cols >= 3) 2 else 0;
    var col: u16 = gutter + 1;
    var rows: usize = 1;
    var zero_width_run_bytes: usize = 0;
    var index: usize = 0;
    while (index < text.len and rows <= row_limit) {
        const byte = text[index];
        if (byte == '\r' or byte == '\n') {
            rows += 1;
            col = gutter + 1;
            zero_width_run_bytes = 0;
            index += 1;
            continue;
        }
        if (byte == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            zero_width_run_bytes = 0;
            index += 1;
            continue;
        }
        const unit = display_width.displayUnitAt(text, index);
        const width_usize = unit.cell_width;
        if (width_usize == 0) {
            if (zero_width_run_bytes +| unit.byte_len > literal_command_zero_width_row_byte_limit) {
                rows += 1;
                col = gutter + 1;
                zero_width_run_bytes = 0;
                if (rows > row_limit) break;
            }
            zero_width_run_bytes += unit.byte_len;
            index += unit.byte_len;
            continue;
        }
        zero_width_run_bytes = 0;
        const width: u16 = @intCast(width_usize);
        if (display_width.shouldWrapAt(col, width, cols)) {
            rows += 1;
            col = gutter + 1;
            if (rows > row_limit) break;
        }
        col +|= width;
        index += unit.byte_len;
    }
    return index;
}

fn literalHardLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return std.mem.count(u8, bytes, "\n") + 1;
}

fn literalPhysicalRowPrefix(bytes: []const u8, row_count: usize) []const u8 {
    if (row_count == 0) return bytes[0..0];
    var rows: usize = 1;
    for (bytes, 0..) |byte, index| {
        if (byte != '\n') continue;
        if (rows == row_count) return bytes[0..index];
        rows += 1;
    }
    return bytes;
}

fn appendAssistantContinuation(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    sgr: assistant_pacer.SgrState,
    hyperlink: ?[]const u8,
    continuation: ?AssistantContinuation,
    cols: u16,
    base_gutter: u16,
    next_width: u16,
    literal_command: bool,
) !u16 {
    try closeAssistantRowStyles(alloc, out, sgr, hyperlink);
    try out.append(alloc, '\n');

    if (literal_command and base_gutter >= 2) {
        try out.appendSlice(alloc, "│ ");
        try out.appendNTimes(alloc, ' ', base_gutter - 2);
    } else {
        try out.appendNTimes(alloc, ' ', base_gutter);
    }
    var col: u16 = base_gutter + 1;
    if (continuation) |prefix| {
        const indent = continuationWidth(prefix);
        const width: usize = cols;
        const total_indent = @as(usize, base_gutter) + indent;
        if (total_indent < width and @as(usize, next_width) <= width - total_indent) {
            switch (prefix) {
                .list_indent => try out.appendNTimes(alloc, ' ', indent),
                .blockquote => |blockquote| {
                    try out.appendNTimes(alloc, ' ', blockquote.indent);
                    for (0..blockquote.depth) |_| {
                        try out.appendSlice(alloc, "\x1b[2m\xe2\x94\x82 \x1b[22m");
                    }
                },
            }
            col = @intCast(total_indent + 1);
        }
    }
    if (sgr.isActive()) {
        var reopen: [64]u8 = undefined;
        const n = sgr.writeOpens(reopen[0..]);
        try out.appendSlice(alloc, reopen[0..n]);
    }
    if (hyperlink) |open| try out.appendSlice(alloc, open);
    return col;
}

fn reflowAtWordBreak(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    word_break: WordBreak,
    continuation: ?AssistantContinuation,
    cols: u16,
    base_gutter: u16,
    next_width: u16,
    literal_command: bool,
) !?u16 {
    const suffix = out.items[word_break.end..];
    const suffix_width = display_width.visibleWidthIgnoringAnsi(suffix);
    const first_width = firstVisibleWidth(suffix) orelse next_width;
    const local_indent = if (continuation) |prefix| continuationWidth(prefix) else 0;
    const indent = @as(usize, base_gutter) + local_indent;
    if (indent >= cols or suffix_width + next_width > @as(usize, cols) - indent) return null;

    var replacement: std.ArrayList(u8) = .empty;
    defer replacement.deinit(alloc);
    const col = try appendAssistantContinuation(
        alloc,
        &replacement,
        word_break.sgr,
        word_break.hyperlink,
        continuation,
        cols,
        base_gutter,
        first_width,
        literal_command,
    );
    try out.replaceRange(alloc, word_break.start, word_break.end - word_break.start, replacement.items);
    return col + @as(u16, @intCast(suffix_width));
}

fn osc8Update(seq: []const u8) ?Osc8Update {
    if (!std.mem.startsWith(u8, seq, "\x1b]8;")) return null;
    const terminator_len: usize = if (seq.len > 0 and seq[seq.len - 1] == 0x07)
        1
    else if (seq.len >= 2 and seq[seq.len - 2] == 0x1b and seq[seq.len - 1] == '\\')
        2
    else
        return null;
    const payload = seq[4 .. seq.len - terminator_len];
    const separator = std.mem.indexOfScalar(u8, payload, ';') orelse return null;
    return if (separator + 1 == payload.len) .close else .{ .open = seq };
}

fn firstVisibleWidth(text: []const u8) ?u16 {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, i);
            if (end <= i) return null;
            i = end;
            continue;
        }
        if (text[i] < 32) return null;
        const unit = display_width.displayUnitAt(text, i);
        if (unit.cell_width > 0) return @intCast(unit.cell_width);
        i += unit.byte_len;
    }
    return null;
}

/// Returns the end of a row-leading footnote or definition marker that cannot
/// fit within `cols` together with the next visible rune.
fn infeasibleMarkerEnd(text: []const u8, start: usize, base_gutter: u16, cols: u16) ?usize {
    const marker: MarkerPrefix = if (footnotePrefix(text, start)) |prefix|
        prefix
    else if (definitionPrefixEnd(text, start)) |end|
        .{ .end = end, .indent = 2 }
    else
        return null;
    const next_width = firstVisibleWidth(text[marker.end..]) orelse 1;
    if (@as(usize, base_gutter) + marker.indent + next_width <= cols) return null;
    return marker.end;
}

fn isContinuationMarkerSeparator(
    col_before_space: u16,
    continuation: ?AssistantContinuation,
    base_gutter: u16,
) bool {
    const prefix = continuation orelse return false;
    return col_before_space == base_gutter + continuationWidth(prefix);
}

fn wordBreakFits(
    suffix: []const u8,
    text: []const u8,
    word_start: usize,
    continuation: ?AssistantContinuation,
    cols: u16,
    base_gutter: u16,
) bool {
    const indent = @as(usize, base_gutter) + if (continuation) |prefix| continuationWidth(prefix) else 0;
    if (indent >= cols) return false;
    const available = @as(usize, cols) - indent;
    return display_width.visibleWidthIgnoringAnsi(suffix) + remainingWordWidth(text, word_start) <= available;
}

fn remainingWordWidth(text: []const u8, start: usize) usize {
    var width: usize = 0;
    var i = start;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, i);
            if (end <= i) break;
            i = end;
            continue;
        }
        if (text[i] == ' ' or text[i] == '\r' or text[i] == '\n') break;
        const unit = display_width.displayUnitAt(text, i);
        width += unit.cell_width;
        i += unit.byte_len;
    }
    return width;
}

fn isFinalWordOnLine(text: []const u8, start: usize) bool {
    var i = start;
    var passed_current_word = false;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, i);
            if (end <= i) return true;
            i = end;
            continue;
        }
        if (text[i] == '\r' or text[i] == '\n') return true;
        if (text[i] == ' ') {
            passed_current_word = true;
            i += 1;
            continue;
        }
        if (passed_current_word) return false;
        const rune = display_width.decodeNextRune(text, i);
        i += rune.len;
    }
    return true;
}

fn continuationWidth(continuation: AssistantContinuation) usize {
    return switch (continuation) {
        .list_indent => |indent| indent,
        .blockquote => |blockquote| blockquote.indent + 2 * blockquote.depth,
    };
}

/// Recognizes MarkdownProcessor's list, definition, and blockquote prefixes, including
/// pacer-inserted dim reassertions between visible marker characters.
fn assistantContinuation(text: []const u8, line_start: usize) ?AssistantContinuation {
    if (listContinuationIndentWidth(text, line_start)) |indent| {
        return .{ .list_indent = indent };
    }
    if (definitionPrefixEnd(text, line_start) != null) {
        return .{ .list_indent = 2 };
    }
    if (footnotePrefix(text, line_start)) |prefix| {
        return .{ .list_indent = prefix.indent };
    }
    if (footnoteContinuationIndent(text, line_start)) |indent| {
        return .{ .list_indent = indent };
    }

    var i = line_start;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    const indent = i - line_start;
    var depth: usize = 0;
    while (blockquoteMarkerEnd(text, i)) |end| {
        depth += 1;
        i = end;
    }
    if (depth == 0) return null;
    return .{ .blockquote = .{ .indent = indent, .depth = depth } };
}

fn definitionPrefixEnd(text: []const u8, start: usize) ?usize {
    const dim_open = "\x1b[2m";
    const dim_close = "\x1b[22m";

    var i = start;
    if (!std.mem.startsWith(u8, text[i..], dim_open)) return null;
    i += dim_open.len;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);
    if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
    return i + dim_close.len;
}

const MarkerPrefix = struct {
    end: usize,
    indent: usize,
};

fn footnotePrefix(text: []const u8, start: usize) ?MarkerPrefix {
    var i = footnoteDimOpenEnd(text, start) orelse return null;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != '[') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);

    var digits: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') {
        digits += 1;
        i += 1;
        i = skipPacerDimReassertions(text, i);
    }
    if (digits == 0 or i >= text.len or text[i] != ']') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;
    const close_end = footnotePrefixBoundaryEnd(text, i) orelse return null;
    return .{ .end = close_end, .indent = digits + 3 };
}

fn footnoteContinuationIndent(text: []const u8, start: usize) ?usize {
    var i = footnoteDimOpenEnd(text, start) orelse return null;

    var indent: usize = 0;
    while (true) {
        i = skipPacerDimReassertions(text, i);
        if (i >= text.len or text[i] != ' ') break;
        indent += 1;
        i += 1;
    }
    if (indent < 4) return null;
    _ = footnotePrefixBoundaryEnd(text, i) orelse return null;
    return indent;
}

fn footnotePrefixBoundaryEnd(text: []const u8, start: usize) ?usize {
    if (dimCloseEnd(text, start)) |end| return end;
    const reassert = "\x1b[0m\x1b[2m";
    if (std.mem.startsWith(u8, text[start..], reassert)) return start + reassert.len;
    return null;
}

fn footnoteDimOpenEnd(text: []const u8, start: usize) ?usize {
    const reset = "\x1b[0m";
    const dim_open = "\x1b[2m";

    var i = start;
    if (std.mem.startsWith(u8, text[i..], reset)) i += reset.len;
    if (!std.mem.startsWith(u8, text[i..], dim_open)) return null;
    while (std.mem.startsWith(u8, text[i..], dim_open)) : (i += dim_open.len) {}
    return i;
}

fn dimCloseEnd(text: []const u8, start: usize) ?usize {
    if (std.mem.startsWith(u8, text[start..], "\x1b[22m")) return start + "\x1b[22m".len;
    if (std.mem.startsWith(u8, text[start..], "\x1b[0m")) return start + "\x1b[0m".len;
    return null;
}

fn blockquoteMarkerEnd(text: []const u8, start: usize) ?usize {
    const dim_open = "\x1b[2m";
    const dim_close = "\x1b[22m";
    const vertical_rule = "\xe2\x94\x82";

    var i = start;
    if (!std.mem.startsWith(u8, text[i..], dim_open)) return null;
    i += dim_open.len;
    i = skipPacerDimReassertions(text, i);
    if (!std.mem.startsWith(u8, text[i..], vertical_rule)) return null;
    i += vertical_rule.len;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);
    if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
    return i + dim_close.len;
}

/// Recognizes MarkdownProcessor's list prefix and pacer dim reassertions.
fn listContinuationIndentWidth(text: []const u8, line_start: usize) ?usize {
    const dim_open = "\x1b[2m";
    const dim_close = "\x1b[22m";
    const bullet = "\xe2\x80\xa2";

    var i = line_start;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    const indent = i - line_start;
    if (taskMarkerWidth(text, i)) |task_width| return indent + task_width;
    if (!std.mem.startsWith(u8, text[i..], dim_open)) return null;
    i += dim_open.len;
    i = skipPacerDimReassertions(text, i);

    if (dimTaskMarkerWidth(text, i)) |task_width| return indent + task_width;

    if (std.mem.startsWith(u8, text[i..], bullet)) {
        i += bullet.len;
        i = skipPacerDimReassertions(text, i);
        if (i >= text.len or text[i] != ' ') return null;
        i += 1;
        i = skipPacerDimReassertions(text, i);
        if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
        return indent + 2;
    }

    var marker_width: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') {
        i += 1;
        marker_width += 1;
        i = skipPacerDimReassertions(text, i);
    }
    if (marker_width == 0 or i >= text.len or text[i] != '.') return null;
    i += 1;
    marker_width += 1;
    i = skipPacerDimReassertions(text, i);
    if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
    i += dim_close.len;
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;

    if (taskMarkerWidth(text, i)) |task_width| return indent + marker_width + 1 + task_width;

    return indent + marker_width + 1;
}

fn dimTaskMarkerWidth(text: []const u8, start: usize) ?usize {
    const dim_close = "\x1b[22m";
    const pending = "\xe2\x98\x90";

    var i = skipPacerDimReassertions(text, start);
    if (!std.mem.startsWith(u8, text[i..], pending)) return null;
    i += pending.len;
    i = skipPacerDimReassertions(text, i);

    var width: usize = 1;
    if (i < text.len and text[i] == ' ') {
        i += 1;
        width += 1;
        i = skipPacerDimReassertions(text, i);
    }
    if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
    return width;
}

fn taskMarkerWidth(text: []const u8, start: usize) ?usize {
    const dim_open = "\x1b[2m";
    const completed_opens = [_][]const u8{ "\x1b[38;5;252m", "\x1b[38;5;238m" };
    const completed_close = "\x1b[39m";
    const completed = "\xe2\x9c\x93";

    if (std.mem.startsWith(u8, text[start..], dim_open)) {
        return dimTaskMarkerWidth(text, start + dim_open.len);
    }

    var i = start;
    const open_len = for (completed_opens) |open| {
        if (std.mem.startsWith(u8, text[i..], open)) break open.len;
    } else return null;
    i += open_len;
    if (!std.mem.startsWith(u8, text[i..], completed)) return null;
    i += completed.len;
    if (!std.mem.startsWith(u8, text[i..], completed_close)) return null;
    i += completed_close.len;

    var width: usize = 1;
    if (i < text.len and text[i] == ' ') {
        i += 1;
        width += 1;
    }
    return width;
}

fn skipPacerDimReassertions(text: []const u8, start: usize) usize {
    const reassert = "\x1b[0m\x1b[2m";
    var i = start;
    while (std.mem.startsWith(u8, text[i..], reassert)) : (i += reassert.len) {}
    return i;
}






































