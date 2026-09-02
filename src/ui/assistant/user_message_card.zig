// Renders submitted user turns and owns their row collection and wrapping.
const std = @import("std");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const visual_layout = @import("../input/visual_layout.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

const reset_style = "\x1b[0m";
const prompt_text_style = "\x1b[1m";
const restore_prompt_text_style = reset_style ++ prompt_text_style;
const user_turn_rail = "┃";
const dark_marker_style = "\x1b[38;5;255m";
const light_marker_style = "\x1b[38;5;235m";
const osc8_prefix = "\x1b]8;;";
const osc8_terminator = "\x1b\\";
const osc8_close = osc8_prefix ++ osc8_terminator;

const accent_dark = "\x1b[38;5;252m";
const accent_light = "\x1b[38;5;238m";
var accent_style: []const u8 = accent_dark;

var marker_style: []const u8 = dark_marker_style;

pub fn setStyle(light: bool, _: ?Rgb) void {
    marker_style = if (light) light_marker_style else dark_marker_style;
    accent_style = if (light) accent_light else accent_dark;
}

pub fn promptMarkerStyle() []const u8 {
    return marker_style;
}

fn emitRow(writer: *std.Io.Writer, content: []const u8) !void {
    try writer.writeAll(content);
    try writer.writeAll(reset_style);
    try writer.writeByte('\n');
}

fn lastSpaceIn(slice: []const u8) ?usize {
    var i: usize = slice.len;
    while (i > 0) {
        i -= 1;
        if (slice[i] == ' ' or slice[i] == '\t') return i;
    }
    return null;
}

// Returns display-safe keep and skip boundaries, preferring whitespace.
const WrapCut = struct { keep_bytes: usize, skip_bytes: usize };

fn wrapCut(text: []const u8, row_budget: usize) WrapCut {
    if (row_budget == 0) return .{ .keep_bytes = 0, .skip_bytes = 0 };
    const prefix = display_width.prefixByWidthIgnoringAnsi(text, row_budget);
    if (prefix.len == text.len) return .{ .keep_bytes = prefix.len, .skip_bytes = prefix.len };

    if (lastSpaceIn(prefix)) |sp| {
        return .{ .keep_bytes = sp, .skip_bytes = sp + 1 };
    }

    // Force one display unit when no break point fits so the loop advances.
    if (prefix.len == 0) {
        var end: usize = 0;
        while (end < text.len and text[end] == 0x1b) {
            end = display_width.ansiSequenceEnd(text, end);
        }
        const unit = display_width.displayUnitAt(text, end);
        if (unit.byte_len == 0) return .{ .keep_bytes = 0, .skip_bytes = text.len };
        return .{ .keep_bytes = end + unit.byte_len, .skip_bytes = end + unit.byte_len };
    }
    return .{ .keep_bytes = prefix.len, .skip_bytes = prefix.len };
}

pub fn buildUserPromptCard(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
) ![]u8 {
    return buildUserPromptCardWithSkillTokens(alloc, text, images, cols, &.{});
}

pub fn buildUserPromptCardWithSkillTokens(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
) ![]u8 {
    return buildUserPromptCardWithSkillTokensAndLinks(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        false,
    );
}

pub fn buildUserPromptCardWithSkillTokensForTerminalPresentation(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
) ![]u8 {
    return buildUserPromptCardWithSkillTokensForTerminalPresentationInterruptible(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn buildUserPromptCardWithSkillTokensForTerminalPresentationInterruptible(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) ![]u8 {
    return buildUserPromptCardWithSkillTokensAndLinksInterruptible(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        true,
        checkpoint,
        null,
    );
}

pub fn buildUserPromptCardTailForTerminalPresentationInterruptible(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
    max_rows: usize,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) ![]u8 {
    // The pending-frame path retains only the newest rows that fit its current
    // transcript band; canonical formatting remains shared with ordinary turns.
    return buildUserPromptCardWithSkillTokensAndLinksInterruptible(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        true,
        checkpoint,
        max_rows,
    );
}

fn buildUserPromptCardWithSkillTokensAndLinks(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
    linked_images: bool,
) ![]u8 {
    return buildUserPromptCardWithSkillTokensAndLinksInterruptible(
        alloc,
        text,
        images,
        cols,
        skill_tokens,
        linked_images,
        null,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

fn buildUserPromptCardWithSkillTokensAndLinksInterruptible(
    alloc: std.mem.Allocator,
    text: []const u8,
    images: []const types.ImageAttachment,
    cols: u16,
    skill_tokens: []const visual_layout.SkillTokenSpan,
    linked_images: bool,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
    max_rows: ?usize,
) ![]u8 {
    const window: usize = if (cols > 2) @as(usize, cols) - 2 else 0;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    if (window == 0) {
        try build_checkpoint.consume(checkpoint, text.len +| images.len);
        return out.toOwnedSlice();
    }
    if (text.len == 0 and images.len == 0) {
        return out.toOwnedSlice();
    }

    const token_text = if (skill_tokens.len > 0)
        try renderSkillTokensForCard(alloc, text, skill_tokens)
    else
        text;
    defer if (skill_tokens.len > 0) alloc.free(token_text);

    var expanded_buf: std.Io.Writer.Allocating = .init(alloc);
    defer expanded_buf.deinit();
    if (images.len > 0) {
        _ = if (linked_images)
            try image_attachments.expandPlaceholdersWithLinkedBadges(
                alloc,
                &expanded_buf.writer,
                token_text,
                images,
                null,
            )
        else
            try image_attachments.expandPlaceholdersWithBadges(
                alloc,
                &expanded_buf.writer,
                token_text,
                images,
                null,
            );
    } else {
        try expanded_buf.writer.writeAll(token_text);
    }
    const display_text = expanded_buf.written();

    var rows: std.ArrayList([]const u8) = .empty;
    defer {
        for (rows.items) |r| alloc.free(r);
        rows.deinit(alloc);
    }

    var row_buf: std.Io.Writer.Allocating = .init(alloc);
    defer row_buf.deinit();

    try collectLogicalLinesWithFirstPrefix(
        alloc,
        &rows,
        &row_buf,
        display_text,
        window,
        checkpoint,
        max_rows,
    );

    for (rows.items) |content| {
        try emitRow(&out.writer, content);
    }

    return out.toOwnedSlice();
}

fn renderSkillTokensForCard(
    alloc: std.mem.Allocator,
    text: []const u8,
    skill_tokens: []const visual_layout.SkillTokenSpan,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var pos: usize = 0;
    for (skill_tokens) |token| {
        if (token.raw_start < pos or token.raw_end > text.len or token.raw_start >= token.raw_end) continue;
        if (token.name.len == 0) continue;

        try out.writer.writeAll(text[pos..token.raw_start]);
        try out.writer.writeAll(accent_style);
        try out.writer.writeAll(token.name);
        if (visual_layout.skillTokenSourceLabel(token)) |source_label| {
            try out.writer.writeAll(visual_layout.skill_source_separator);
            try out.writer.writeAll(source_label);
        }
        try out.writer.writeAll(restore_prompt_text_style);
        pos = token.raw_end;
    }
    try out.writer.writeAll(text[pos..]);
    return try out.toOwnedSlice();
}

// Dupes `content` into the row list.
fn appendRow(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList([]const u8),
    content: []const u8,
) !void {
    const dup = try alloc.dupe(u8, content);
    errdefer alloc.free(dup);
    try rows.append(alloc, dup);
}

fn appendVisibleRow(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList([]const u8),
    content: []const u8,
    max_rows: ?usize,
) !void {
    if (max_rows) |limit| {
        if (limit == 0) return;
        if (rows.items.len == limit) {
            alloc.free(rows.orderedRemove(0));
        }
    }
    try appendRow(alloc, rows, content);
}

fn writeRowPrefix(writer: *std.Io.Writer) !void {
    try writer.writeAll(marker_style);
    try writer.writeAll(user_turn_rail);
    try writer.writeAll(reset_style);
    try writer.writeByte(' ');
    try writer.writeAll(prompt_text_style);
}

fn hyperlinkStateAfter(fragment: []const u8, initial: ?[]const u8) ?[]const u8 {
    var active = initial;
    var offset: usize = 0;
    while (std.mem.findPos(u8, fragment, offset, osc8_prefix)) |start| {
        const target_start = start + osc8_prefix.len;
        const target_end = std.mem.findPos(
            u8,
            fragment,
            target_start,
            osc8_terminator,
        ) orelse break;
        const sequence_end = target_end + osc8_terminator.len;
        active = if (target_end == target_start)
            null
        else
            fragment[start..sequence_end];
        offset = sequence_end;
    }
    return active;
}

// Wraps `text` onto rows and repeats the rail so adjacent rows stay connected.
fn collectLogicalLinesWithFirstPrefix(
    alloc: std.mem.Allocator,
    rows: *std.ArrayList([]const u8),
    row_buf: *std.Io.Writer.Allocating,
    text: []const u8,
    window: usize,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
    max_rows: ?usize,
) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try build_checkpoint.tick(checkpoint);
        var active_hyperlink: ?[]const u8 = null;
        var remaining = line;
        if (remaining.len == 0) {
            row_buf.clearRetainingCapacity();
            try writeRowPrefix(&row_buf.writer);
            try appendVisibleRow(alloc, rows, row_buf.written(), max_rows);
            continue;
        }
        while (remaining.len > 0) {
            const c = wrapCut(remaining, window);
            try build_checkpoint.consume(checkpoint, @max(c.keep_bytes, c.skip_bytes));
            const fragment = remaining[0..c.keep_bytes];
            row_buf.clearRetainingCapacity();
            try writeRowPrefix(&row_buf.writer);
            if (active_hyperlink) |opener| try row_buf.writer.writeAll(opener);
            try row_buf.writer.writeAll(fragment);
            active_hyperlink = hyperlinkStateAfter(fragment, active_hyperlink);
            if (active_hyperlink != null) try row_buf.writer.writeAll(osc8_close);
            try appendVisibleRow(alloc, rows, row_buf.written(), max_rows);
            remaining = remaining[c.skip_bytes..];
        }
    }
}


fn assertRowStructure(card: []const u8) !void {
    var it = std.mem.splitScalar(u8, card, '\n');
    while (it.next()) |row| {
        if (row.len == 0) continue;
        try std.testing.expect(std.mem.find(u8, row, user_turn_rail) != null);
        try std.testing.expect(std.mem.find(u8, row, "❯") == null);
        try std.testing.expect(std.mem.find(u8, row, "\x1b[48;") == null);
        try std.testing.expect(std.mem.find(u8, row, "\x1b[K") == null);
        try std.testing.expect(std.mem.endsWith(u8, row, reset_style));
    }
}

fn countRows(card: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, card, '\n');
    while (it.next()) |row| {
        if (row.len > 0) count += 1;
    }
    return count;
}






















