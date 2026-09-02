const std = @import("std");
const image_attachments = @import("../../core/images/image_attachments.zig");
const display_width = @import("../../core/shared/display_width.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;

pub const max_top_row_len: usize = 512;

pub fn composeDividerRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    try row.appendSlice(alloc, ui_render.divider_style);
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        try row.appendSlice(alloc, "\xe2\x94\x80"); // ─ (U+2500)
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

pub fn appendClipped(alloc: Allocator, out: *std.ArrayList(u8), bytes: []const u8, width: u16) !void {
    const width_usize: usize = width;
    if (width_usize == 0) return;

    var visible: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            const end = display_width.ansiSequenceEnd(bytes, i);
            try out.appendSlice(alloc, bytes[i..end]);
            i = end;
            continue;
        }
        if (bytes[i] == '\n' or bytes[i] == '\r') {
            if (visible + 1 > width_usize) break;
            try out.append(alloc, ' ');
            visible += 1;
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(bytes, i);
        if (unit.byte_len == 0) break;
        const cell_width = unit.cell_width;
        if (visible + cell_width > width_usize) break;

        try out.appendSlice(alloc, bytes[i .. i + unit.byte_len]);
        visible += cell_width;
        i += unit.byte_len;
    }
}

const EllipsisPlacement = enum {
    trailing,
    middle,
    prefix_biased,
};

pub fn appendSingleLineEllipsized(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    return appendProjectedSingleLine(alloc, out, text, width, .trailing);
}

pub fn appendSingleLineMiddleEllipsized(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    return appendProjectedSingleLine(alloc, out, text, width, .middle);
}

pub fn appendSingleLinePrefixBiasedEllipsized(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8, width: usize) !void {
    return appendProjectedSingleLine(alloc, out, text, width, .prefix_biased);
}

fn appendProjectedSingleLine(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
    placement: EllipsisPlacement,
) !void {
    if (width == 0) return;

    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(alloc);
    for (text) |byte| {
        try normalized.append(alloc, if (byte == '\n' or byte == '\r') ' ' else byte);
    }

    if (display_width.visibleWidth(normalized.items) <= width) {
        try out.appendSlice(alloc, normalized.items);
        return;
    }
    if (width == 1) {
        try out.appendSlice(alloc, "…");
        return;
    }

    const content_width = width - 1;
    switch (placement) {
        .trailing => {
            try out.appendSlice(alloc, display_width.prefixByWidth(normalized.items, content_width));
            try out.appendSlice(alloc, "…");
        },
        .middle => {
            const prefix_width = (content_width + 1) / 2;
            const suffix_width = content_width - prefix_width;
            try out.appendSlice(alloc, display_width.prefixByWidth(normalized.items, prefix_width));
            try out.appendSlice(alloc, "…");
            try out.appendSlice(alloc, display_width.suffixByWidth(normalized.items, suffix_width));
        },
        .prefix_biased => {
            const prefix_width = content_width - content_width / 4;
            const suffix_width = content_width - prefix_width;
            try out.appendSlice(alloc, display_width.prefixByWidth(normalized.items, prefix_width));
            try out.appendSlice(alloc, "…");
            try out.appendSlice(alloc, display_width.suffixByWidth(normalized.items, suffix_width));
        },
    }
}

pub fn appendAbsoluteColumn(alloc: Allocator, out: *std.ArrayList(u8), col: u16) !void {
    var buf: [16]u8 = undefined;
    const seq = try std.fmt.bufPrint(&buf, "\x1b[{d}G", .{col});
    try out.appendSlice(alloc, seq);
}

/// Pads `out` with spaces until its visible width reaches `target_col`.
/// No-op when the row is already at or past the column.
pub fn appendSpacesToColumn(alloc: Allocator, out: *std.ArrayList(u8), target_col: usize) !void {
    const current = display_width.visibleWidthIgnoringAnsi(out.items);
    if (current >= target_col) return;
    try out.appendNTimes(alloc, ' ', target_col - current);
}




