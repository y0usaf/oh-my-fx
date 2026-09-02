const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const render_engine = @import("../render_engine.zig");
const transcript_runtime = @import("../transcript/runtime.zig");
const footer_paint_plan = @import("paint_plan.zig");

const paint_plan = render_engine.paint_plan;
const FrameInvalidationSet = paint_plan.FrameInvalidationSet;
const PaintPlan = paint_plan.PaintPlan;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

pub const FooterExtraUpdate = struct {
    footer_extra: u16,
    footer_reserved_base_rows: u16,
    input_extra: u16,
    banner_active: bool,
    picker_rows: u16,
    show_picker: bool,

    fn changesFooterExtra(self: FooterExtraUpdate, shell: *const TranscriptRuntime) bool {
        return self.footer_extra != shell.extra_input_rows or
            self.footer_reserved_base_rows != shell.footer_reserved_base_rows;
    }
};

const GeometryError = error{
    InvalidFooterInvalidationGeometry,
};

const RecordError = GeometryError || error{
    InvalidFrameInvalidationRange,
};

const FooterExtraChange = struct {
    update: FooterExtraUpdate,
    top: u16,
};

fn detectFooterExtraChange(shell: *const TranscriptRuntime, update: FooterExtraUpdate) ?FooterExtraChange {
    if (!update.changesFooterExtra(shell)) return null;
    return .{
        .update = update,
        .top = footerExtraInvalidationTop(shell),
    };
}

fn logFooterExtraChange(shell: *const TranscriptRuntime, change: FooterExtraChange) void {
    debug_trace.logf(
        "frame_plan",
        "footer_extra_update old={d} new={d} old_base={d} new_base={d} input_extra={d} banner={s} picker_rows={d} show_picker={s}",
        .{
            shell.extra_input_rows,
            change.update.footer_extra,
            shell.footer_reserved_base_rows,
            change.update.footer_reserved_base_rows,
            change.update.input_extra,
            if (change.update.banner_active) "true" else "false",
            change.update.picker_rows,
            if (change.update.show_picker) "true" else "false",
        },
    );
}

fn applyFooterExtraChange(shell: *TranscriptRuntime, force_redraw: *bool, change: FooterExtraChange) void {
    shell.extra_input_rows = change.update.footer_extra;
    shell.footer_reserved_base_rows = change.update.footer_reserved_base_rows;
    shell.footer_viewport.invalidateAfterExternalClear();
    force_redraw.* = true;
}

fn footerExtraInvalidationTop(shell: *const TranscriptRuntime) u16 {
    return if (shell.footer_viewport.has_frame)
        shell.footer_viewport.geometry.top
    else
        shell.footerTopRowForExtra(shell.extra_input_rows);
}

fn visibleFooterInvalidation(
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    rows: u16,
) GeometryError!?paint_plan.FrameInvalidationRange {
    if (top == 0 or rows == 0) return error.InvalidFooterInvalidationGeometry;
    if (top > rows) return null;
    return .{ .reason = reason, .top = top, .bottom = rows };
}

fn logSkippedFooterInvalidation(
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    rows: u16,
) void {
    debug_trace.logf(
        "frame_plan",
        "footer_extra_invalidation_skip reason={s} top={d} rows={d} skip=off_screen_stale_footer",
        .{ @tagName(reason), top, rows },
    );
}

fn footerExtraInvalidationReason(
    shell: *const TranscriptRuntime,
    update: FooterExtraUpdate,
) paint_plan.FrameInvalidationReason {
    return if (update.footer_extra < shell.extra_input_rows)
        .external_clear
    else
        .reserved_gap_clear;
}

fn appendVisibleFooterInvalidation(
    plan: *PaintPlan,
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    rows: u16,
    trace_skips: bool,
) GeometryError!void {
    const range = try visibleFooterInvalidation(reason, top, rows) orelse {
        if (trace_skips) logSkippedFooterInvalidation(reason, top, rows);
        return;
    };
    if (reason == .external_clear and !paint_plan.invalidationIntersectsOwnedBand(plan.*, range)) {
        if (trace_skips) {
            debug_trace.logf(
                "frame_plan",
                "footer_extra_invalidation_skip reason={s} top={d} rows={d} skip=outside_current_owned_bands",
                .{ @tagName(reason), top, rows },
            );
        }
        return;
    }
    footer_paint_plan.appendFooterFrameInvalidation(&plan.invalidation, range);
}

fn recordVisibleExternalClearInvalidation(
    shell: *TranscriptRuntime,
    top: u16,
    rows: u16,
) RecordError!void {
    const range = try visibleFooterInvalidation(.external_clear, top, rows) orelse {
        logSkippedFooterInvalidation(.external_clear, top, rows);
        return;
    };
    try shell.recordFrameInvalidation(range);
}

pub fn appendMeasuredFooterExtraInvalidation(
    shell: *TranscriptRuntime,
    plan: *PaintPlan,
    force_redraw: *bool,
    update: FooterExtraUpdate,
) GeometryError!void {
    const change = detectFooterExtraChange(shell, update) orelse return;

    logFooterExtraChange(shell, change);
    try appendVisibleFooterInvalidation(
        plan,
        footerExtraInvalidationReason(shell, change.update),
        change.top,
        shell.layout.rows,
        true,
    );
    plan.footer_clean_allowed = false;
    force_redraw.* = true;
}

pub fn applyReservationFooterExtraUpdate(
    shell: *TranscriptRuntime,
    force_redraw: *bool,
    update: FooterExtraUpdate,
) RecordError!bool {
    const change = detectFooterExtraChange(shell, update) orelse return false;

    logFooterExtraChange(shell, change);
    try recordVisibleExternalClearInvalidation(shell, change.top, shell.layout.rows);
    applyFooterExtraChange(shell, force_redraw, change);
    return true;
}

pub fn frameFooterExtraInvalidation(
    shell: *const TranscriptRuntime,
    update: FooterExtraUpdate,
) GeometryError!?paint_plan.FrameInvalidationRange {
    const change = detectFooterExtraChange(shell, update) orelse return null;
    return try visibleFooterInvalidation(
        footerExtraInvalidationReason(shell, change.update),
        change.top,
        shell.layout.rows,
    );
}

pub fn applyFrameFooterExtraUpdate(
    shell: *TranscriptRuntime,
    force_redraw: *bool,
    update: FooterExtraUpdate,
) bool {
    const change = detectFooterExtraChange(shell, update) orelse return false;

    logFooterExtraChange(shell, change);
    applyFooterExtraChange(shell, force_redraw, change);
    return true;
}

pub fn mergeAttemptInvalidations(invalidations: FrameInvalidationSet, plan: *PaintPlan) void {
    for (invalidations.ranges()) |range| {
        if (mergeAttemptInvalidation(&plan.invalidation, range)) |collapsed| {
            debug_trace.logf(
                "frame_plan",
                "attempt_invalidation_collapse incoming_reason={s} collapsed_reason={s} top={d} bottom={d}",
                .{ @tagName(range.reason), @tagName(collapsed.reason), collapsed.top, collapsed.bottom },
            );
        }
    }
    plan.footer_clean_allowed = plan.invalidation.isEmpty();
}

pub fn resolveCandidateFrameInvalidations(
    shell: *const TranscriptRuntime,
    plan: PaintPlan,
    footer_update: ?FooterExtraUpdate,
    attempt_invalidations: FrameInvalidationSet,
) GeometryError!FrameInvalidationSet {
    var candidate = plan;
    if (footer_update) |update| {
        if (detectFooterExtraChange(shell, update)) |change| {
            try appendVisibleFooterInvalidation(
                &candidate,
                footerExtraInvalidationReason(shell, change.update),
                change.top,
                shell.layout.rows,
                false,
            );
        }
    }
    for (attempt_invalidations.ranges()) |range| {
        _ = mergeAttemptInvalidation(&candidate.invalidation, range);
    }
    return candidate.invalidation;
}

fn mergeAttemptInvalidation(
    invalidations: *FrameInvalidationSet,
    incoming: paint_plan.FrameInvalidationRange,
) ?paint_plan.FrameInvalidationRange {
    var merged = incoming;
    var consumed = [_]bool{false} ** paint_plan.max_frame_invalidation_ranges;
    var overlapped = false;

    var changed = true;
    while (changed) {
        changed = false;
        for (invalidations.ranges(), 0..) |existing, index| {
            if (consumed[index] or existing.bottom < merged.top or merged.bottom < existing.top) continue;
            consumed[index] = true;
            overlapped = true;
            changed = true;
            merged.reason = paint_plan.moreSevereFrameInvalidation(existing.reason, merged.reason);
            merged.top = @min(existing.top, merged.top);
            merged.bottom = @max(existing.bottom, merged.bottom);
        }
    }

    var next = FrameInvalidationSet.empty();
    for (invalidations.ranges(), 0..) |existing, index| {
        if (!consumed[index]) _ = next.appendOrCollapse(existing);
    }
    const collapsed = next.appendOrCollapse(merged);
    invalidations.* = next;
    return collapsed orelse if (overlapped) merged else null;
}

fn surfaceTestPlan() PaintPlan {
    return .{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 4,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 2,
        },
        .footer = .{
            .top = 5,
            .top_divider = 5,
            .banner = 5,
            .banner_active = false,
            .input_base = 6,
            .picker_divider = 7,
            .picker_start = 8,
            .bottom_divider = 7,
            .hint = 8,
            .total_rows = 4,
        },
        .activity = .none,
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 4, .owner = .transcript },
        .activity_band = paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = 5, .bottom = 8, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 6, .col = 1, .visible = true },
        .footer_reservation_source = .footer_layout,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

fn surfaceHasInvalidation(
    set: paint_plan.FrameInvalidationSet,
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    bottom: u16,
) bool {
    for (set.ranges()) |range| {
        if (range.reason == reason and range.top == top and range.bottom == bottom) return true;
    }
    return false;
}
