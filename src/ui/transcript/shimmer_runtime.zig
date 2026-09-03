// Activity rendering is surface-owned.

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const render_request = @import("../render_request.zig");
const ui_render = @import("../render.zig");
const render_engine = @import("../render_engine.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const frame_surface = render_engine.frame_surface;
const paint_plan = render_engine.paint_plan;

const surface_shimmer_paint_trace_fmt = "shimmer_surface_paint row={d} visible={s} over_footer={s} label_bytes={d} label_hash={x}";

pub const ActivityPaintInput = struct {
    label: []const u8,
    tool_label: ?[]const u8 = null,
    shimmer_pos: i16,
    style: ActivityPaintStyle = .thinking,
    /// Wall-clock blink state synced to the elapsed counter; null falls back
    /// to the frame-phase blink.
    thinking_blink: ?bool = null,
};

pub const ActivityPaintStyle = enum {
    thinking,
    tool_marker,
    neutral,
    warning,
    success,
    danger,
};

fn activityRowLabel(label: []const u8) []const u8 {
    var end = label.len;
    if (std.mem.findScalar(u8, label, '\n')) |idx| end = @min(end, idx);
    if (std.mem.findScalar(u8, label, '\r')) |idx| end = @min(end, idx);
    return label[0..end];
}

fn omissionMarker(cols: u16) []const u8 {
    return switch (cols) {
        0 => "",
        1 => ".",
        2 => "..",
        else => "...",
    };
}

const ActivityLabelPreview = struct {
    bytes: []const u8,
    allocation: ?[]u8 = null,

    fn deinit(self: ActivityLabelPreview, alloc: std.mem.Allocator) void {
        if (self.allocation) |allocation| alloc.free(allocation);
    }
};

fn previewActivityRowLabel(alloc: std.mem.Allocator, label: []const u8, cols: u16) !ActivityLabelPreview {
    const row = activityRowLabel(label);
    if (display_width.visibleWidthIgnoringAnsi(row) <= cols) return .{ .bytes = row };

    const marker = omissionMarker(cols);
    const prefix = display_width.prefixByWidthIgnoringAnsi(row, @as(usize, cols) - marker.len);
    const allocation = try alloc.alloc(u8, prefix.len + marker.len);
    @memcpy(allocation[0..prefix.len], prefix);
    @memcpy(allocation[prefix.len..], marker);
    return .{ .bytes = allocation, .allocation = allocation };
}

fn appendStaticActivityLine(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    prefix: []const u8,
    continuation_indent_width: usize,
    chunk: []const u8,
    first: bool,
) !void {
    if (!first) try out.append(alloc, '\n');
    if (first) {
        try out.appendSlice(alloc, prefix);
    } else {
        try out.appendNTimes(alloc, ' ', continuation_indent_width);
    }
    try out.appendSlice(alloc, chunk);
}

fn wrappedStaticActivityLabel(
    alloc: std.mem.Allocator,
    label: []const u8,
    cols: u16,
    max_rows: u16,
    preserve_trailing_context: bool,
) !ActivityLabelPreview {
    const row = activityRowLabel(label);
    if (max_rows <= 1 or display_width.visibleWidthIgnoringAnsi(row) <= cols) {
        return previewActivityRowLabel(alloc, row, cols);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const safe_cols = @max(@as(usize, cols), 1);
    const prefix_end = display_width.statusPrefixEnd(row);
    const prefix = row[0..prefix_end];
    const prefix_width = display_width.visibleWidthIgnoringAnsi(prefix);
    const continuation_indent_width = @max(prefix_width, 1);
    var remaining = row[prefix_end..];
    var row_count: u16 = 0;
    var first = true;
    while (remaining.len > 0 and row_count < max_rows) {
        const indent_width = if (first) prefix_width else continuation_indent_width;
        const available = if (safe_cols > indent_width) safe_cols - indent_width else 1;
        const last_row = row_count + 1 == max_rows;
        if (last_row and display_width.visibleWidthIgnoringAnsi(remaining) > available) {
            const marker = omissionMarker(@intCast(@min(available, std.math.maxInt(u16))));
            const content_width = available -| marker.len;
            if (preserve_trailing_context) {
                const suffix = display_width.suffixByWidthIgnoringAnsi(remaining, content_width);
                try appendStaticActivityLine(alloc, &out, prefix, continuation_indent_width, marker, first);
                try out.appendSlice(alloc, suffix);
            } else {
                var chunk = display_width.wrapCutIgnoringAnsi(remaining, content_width);
                if (chunk.len == 0 and content_width > 0) {
                    const unit = display_width.displayUnitAt(remaining, 0);
                    chunk = remaining[0..unit.byte_len];
                }
                try appendStaticActivityLine(alloc, &out, prefix, continuation_indent_width, chunk, first);
                try out.appendSlice(alloc, marker);
            }
            remaining = "";
        } else {
            var chunk = display_width.wrapCutIgnoringAnsi(remaining, available);
            if (chunk.len == 0) {
                const unit = display_width.displayUnitAt(remaining, 0);
                chunk = remaining[0..unit.byte_len];
            }
            try appendStaticActivityLine(alloc, &out, prefix, continuation_indent_width, chunk, first);
            remaining = display_width.trimBreakWhitespace(remaining[chunk.len..]);
        }
        row_count += 1;
        first = false;
    }

    if (row.len == 0) try out.appendSlice(alloc, row);
    const allocation = try out.toOwnedSlice(alloc);
    return .{ .bytes = allocation, .allocation = allocation };
}

pub fn paintActivityIntoSurface(
    surface: *frame_surface.FrameSurface,
    input: ActivityPaintInput,
) !paint_plan.ActivityPaintResult {
    return switch (surface.plan.activity) {
        .none => .{ .painted = false, .row = 0, .overlay = false },
        .transient_row => |activity| blk: {
            if (activity.tool_row) |tool_row| {
                const tool_label = input.tool_label orelse return error.MissingToolActivityLabel;
                _ = try paintPlannedActivityRow(surface, .{
                    .label = tool_label,
                    .shimmer_pos = input.shimmer_pos,
                    .style = .tool_marker,
                }, tool_row, false);
            }
            const primary = if (activity.tool_row == null) if (input.tool_label) |tool_label|
                ActivityPaintInput{
                    .label = tool_label,
                    .shimmer_pos = input.shimmer_pos,
                    .style = .tool_marker,
                }
            else
                input else input;
            break :blk try paintPlannedActivityRow(surface, primary, activity.row, false);
        },
        .overlay_entry => |row| try paintPlannedActivityRow(surface, input, row, true),
    };
}

fn paintPlannedActivityRow(
    surface: *frame_surface.FrameSurface,
    input: ActivityPaintInput,
    row: u16,
    overlay: bool,
) !paint_plan.ActivityPaintResult {
    if (overlay) {
        if (!surface.plan.transcript_band.containsRow(row)) return error.WriteOutsideBand;
    } else {
        if (!surface.plan.activity_band.containsRow(row)) return error.WriteOutsideBand;
    }

    traceSurfaceShimmerPaint(surface, row, input.label);

    const max_rows = if (overlay)
        @as(u16, 1)
    else
        surface.plan.activity_band.bottom -| row +| 1;
    const static_status = switch (input.style) {
        .neutral, .warning, .success, .danger => true,
        .thinking, .tool_marker => false,
    };
    const preserve_trailing_context = switch (input.style) {
        .warning, .danger => true,
        .thinking, .tool_marker, .neutral, .success => false,
    };
    const preview = if (static_status)
        try wrappedStaticActivityLabel(
            surface.alloc,
            input.label,
            surface.cols,
            max_rows,
            preserve_trailing_context,
        )
    else
        try previewActivityRowLabel(surface.alloc, input.label, surface.cols);
    defer preview.deinit(surface.alloc);
    var buf: [4096]u8 = undefined;
    const text = switch (input.style) {
        .thinking => writeThinkingBlinkText(
            &buf,
            preview.bytes,
            input.thinking_blink orelse markerBlinkVisible(input.shimmer_pos),
        ),
        .tool_marker => writeToolMarkerBlinkText(&buf, preview.bytes, input.shimmer_pos),
        .neutral => writeStaticStyledText(&buf, preview.bytes, ui_render.dim_style),
        .warning => writeStaticStyledText(&buf, preview.bytes, ui_render.warning_style),
        .success => writeStaticStyledText(&buf, preview.bytes, ui_render.green_style),
        .danger => writeStaticStyledText(&buf, preview.bytes, ui_render.red_style),
    };
    const result = if (static_status and max_rows > 1)
        try surface.writeAnsiBandNoWrap(
            row,
            max_rows,
            text,
            .activity,
            if (overlay) .activity_over_transcript else .same_owner,
        )
    else
        try surface.writeAnsiBandNoWrap(
            row,
            1,
            text,
            .activity,
            if (overlay) .activity_over_transcript else .same_owner,
        );
    std.debug.assert(result.rows_touched <= max_rows);

    return .{
        .painted = true,
        .row = row,
        .overlay = overlay,
    };
}

// A steady on/off blink with no fade. Folding in the padding keeps the phase
// non-negative so the blink wraps seamlessly across the fixed cycle.
fn markerBlinkVisible(shimmer_pos: i16) bool {
    const half = render_request.blink_half_period_frames;
    return @mod(shimmer_pos + render_request.animation_padding, 2 * half) < half;
}

fn writeThinkingBlinkText(out: []u8, label: []const u8, marker_visible: bool) []const u8 {
    const marker = "•";
    if (!std.mem.startsWith(u8, label, marker)) {
        return writeStaticStyledText(out, label, ui_render.dim_style);
    }
    var w: std.Io.Writer = .fixed(out);
    if (marker_visible) {
        w.print("{s}{s}{s}", .{ ui_render.permission_auto_style, marker, ui_render.reset_style }) catch return label;
    } else {
        w.writeAll(" ") catch return label;
    }
    const rest = label[marker.len..];
    // The token suffix recedes into the muted gray; the verb and elapsed
    // counter keep the brighter label gray.
    if (std.mem.find(u8, rest, " (↑")) |token_suffix| {
        w.print("{s}{s}{s}{s}{s}", .{
            ui_render.permission_auto_style,
            rest[0..token_suffix],
            ui_render.dim_style,
            rest[token_suffix..],
            ui_render.reset_style,
        }) catch return label;
    } else {
        w.print("{s}{s}{s}", .{
            ui_render.permission_auto_style,
            rest,
            ui_render.reset_style,
        }) catch return label;
    }
    return w.buffered();
}

fn writeStaticStyledText(out: []u8, label: []const u8, style: []const u8) []const u8 {
    const required = style.len + label.len + ui_render.reset_style.len;
    if (required > out.len) return label;
    var end: usize = 0;
    @memcpy(out[end .. end + style.len], style);
    end += style.len;
    @memcpy(out[end .. end + label.len], label);
    end += label.len;
    @memcpy(out[end .. end + ui_render.reset_style.len], ui_render.reset_style);
    end += ui_render.reset_style.len;
    return out[0..end];
}

fn writeToolMarkerBlinkText(out: []u8, label: []const u8, shimmer_pos: i16) []const u8 {
    var marker_start: usize = 0;
    while (marker_start < label.len and label[marker_start] == 0x1b) {
        const ansi_end = display_width.ansiSequenceEnd(label, marker_start);
        if (ansi_end <= marker_start) break;
        marker_start = ansi_end;
    }
    const marker_unit = display_width.displayUnitAt(label, marker_start);
    if (marker_unit.byte_len == 0) return label;
    const marker_end = @min(marker_start + marker_unit.byte_len, label.len);
    const marker = label[marker_start..marker_end];
    if (!std.mem.eql(u8, marker, "●") and !std.mem.eql(u8, marker, "└")) return label;

    var marker_buf: [64]u8 = undefined;
    var marker_writer: std.Io.Writer = .fixed(&marker_buf);
    if (markerBlinkVisible(shimmer_pos)) {
        marker_writer.print("{s}{s}{s}", .{
            ui_render.permission_auto_style,
            label[marker_start..marker_end],
            ui_render.reset_style,
        }) catch return label;
    } else {
        marker_writer.writeAll(" ") catch return label;
    }
    const animated_marker = marker_writer.buffered();
    const prefix = label[0..marker_start];
    const suffix = label[marker_end..];
    const required = prefix.len * 2 + animated_marker.len + suffix.len + ui_render.reset_style.len;
    if (required > out.len) return label;

    var end: usize = 0;
    @memcpy(out[end .. end + prefix.len], prefix);
    end += prefix.len;
    @memcpy(out[end .. end + animated_marker.len], animated_marker);
    end += animated_marker.len;
    @memcpy(out[end .. end + prefix.len], prefix);
    end += prefix.len;
    @memcpy(out[end .. end + suffix.len], suffix);
    end += suffix.len;
    @memcpy(out[end .. end + ui_render.reset_style.len], ui_render.reset_style);
    end += ui_render.reset_style.len;
    return out[0..end];
}

fn traceSurfaceShimmerPaint(surface: *const frame_surface.FrameSurface, row: u16, label: []const u8) void {
    debug_trace.logf(
        "paint",
        surface_shimmer_paint_trace_fmt,
        .{
            row,
            if (row >= 1 and row <= surface.rows) "true" else "false",
            if (surface.plan.footer_band.containsRow(row)) "true" else "false",
            label.len,
            std.hash.Wyhash.hash(0, label),
        },
    );
}

fn testPlan(
    activity: render_engine.activity_overlay.ActivityPlacement,
    activity_band: paint_plan.FrameBand,
) paint_plan.PaintPlan {
    return .{
        .layout = .{
            .rows = 6,
            .cols = 32,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 5,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 4,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 3,
        },
        .footer = .{
            .top = 5,
            .top_divider = 5,
            .banner = 5,
            .banner_active = false,
            .input_base = 5,
            .picker_divider = 5,
            .picker_start = 6,
            .bottom_divider = 5,
            .hint = 6,
            .total_rows = 2,
        },
        .activity = activity,
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 4, .owner = .transcript },
        .activity_band = activity_band,
        .footer_band = .{ .top = 5, .bottom = 6, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 5, .col = 1, .visible = true },
        .footer_reservation_source = .footer_layout,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

fn testSurface(plan: paint_plan.PaintPlan) !struct {
    shadow: vt_emulator.Grid,
    surface: frame_surface.FrameSurface,
} {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, plan.layout.cols, plan.layout.rows);
    errdefer shadow.deinit();
    try shadow.feed("\x1b[1;1Hshell");

    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    errdefer surface.deinit();
    return .{ .shadow = shadow, .surface = surface };
}
