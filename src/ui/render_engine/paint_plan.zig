const std = @import("std");
const types = @import("../../core/shared/types.zig");
const activity_overlay = @import("activity_overlay.zig");
const footer_layout = @import("footer_layout.zig");
const viewport_selection = @import("viewport_selection.zig");

const Layout = types.Layout;

pub const CellOwner = enum {
    preserved_shell,
    transcript,
    gap,
    activity,
    footer,
    diagnostic_clear,
};

pub const FrameBand = struct {
    top: u16,
    bottom: u16,
    owner: CellOwner,

    pub fn empty(owner: CellOwner) FrameBand {
        return .{ .top = 0, .bottom = 0, .owner = owner };
    }

    pub fn isEmpty(self: FrameBand) bool {
        return self.top == 0 and self.bottom == 0;
    }

    pub fn containsRow(self: FrameBand, row: u16) bool {
        return !self.isEmpty() and row >= self.top and row <= self.bottom;
    }
};

pub fn activityBand(activity: activity_overlay.ActivityPlacement) FrameBand {
    return switch (activity) {
        .transient_row => |transient| .{
            .top = transient.tool_row orelse transient.row,
            .bottom = transient.row +| transient.row_count -| 1,
            .owner = .activity,
        },
        .none, .overlay_entry => FrameBand.empty(.activity),
    };
}

pub fn paintedContentBand(plan: PaintPlan) FrameBand {
    var top: u16 = 0;
    var bottom: u16 = 0;
    includeBand(&top, &bottom, plan.transcript_band);
    includeBand(&top, &bottom, plan.activity_band);
    includeBand(&top, &bottom, plan.footer_band);
    if (top == 0) return FrameBand.empty(.transcript);
    return .{ .top = top, .bottom = bottom, .owner = .transcript };
}

pub fn paintedBandChange(plan: PaintPlan, previous: FrameBand) ?FrameBand {
    const current = paintedContentBand(plan);
    const clamped_previous = clampBandToRows(previous, plan.layout.rows);
    if (bandsSameRange(clamped_previous, current)) return null;
    return unionBands(clamped_previous, current, .transcript);
}

pub const FrameInvalidationReason = enum {
    resize,
    owned_band_change,
    viewport_reanchor,
    terminal_scroll,
    external_clear,
    toggle_command_output,
    partial_write,
    shadow_feed_failure,
    diagnostic_wipe,
    reserved_gap_clear,
};

pub fn frameInvalidationSeverity(reason: FrameInvalidationReason) u8 {
    return switch (reason) {
        .reserved_gap_clear => 0,
        .external_clear, .toggle_command_output => 1,
        .owned_band_change => 2,
        .viewport_reanchor => 2,
        .terminal_scroll => 3,
        .resize => 4,
        .partial_write => 5,
        .shadow_feed_failure => 6,
        .diagnostic_wipe => 7,
    };
}

pub fn moreSevereFrameInvalidation(
    a: FrameInvalidationReason,
    b: FrameInvalidationReason,
) FrameInvalidationReason {
    return if (frameInvalidationSeverity(a) >= frameInvalidationSeverity(b)) a else b;
}

pub const FrameInvalidationRange = struct {
    reason: FrameInvalidationReason,
    top: u16,
    bottom: u16,
};

pub const FrameInvalidationError = error{
    TooManyFrameInvalidations,
};

pub const max_frame_invalidation_ranges = 8;

pub const FrameInvalidationSet = struct {
    items: [max_frame_invalidation_ranges]FrameInvalidationRange = undefined,
    len: u8 = 0,

    pub fn empty() FrameInvalidationSet {
        return .{ .items = undefined, .len = 0 };
    }

    pub fn append(self: *FrameInvalidationSet, range: FrameInvalidationRange) FrameInvalidationError!void {
        if (self.len >= max_frame_invalidation_ranges) return error.TooManyFrameInvalidations;
        self.items[self.len] = range;
        self.len += 1;
    }

    pub fn replaceWith(self: *FrameInvalidationSet, range: FrameInvalidationRange) void {
        self.items[0] = range;
        self.len = 1;
    }

    pub fn collapsedWith(self: *const FrameInvalidationSet, incoming: FrameInvalidationRange) FrameInvalidationRange {
        var collapsed = incoming;
        for (self.ranges()) |range| {
            collapsed.reason = moreSevereFrameInvalidation(collapsed.reason, range.reason);
            collapsed.top = @min(collapsed.top, range.top);
            collapsed.bottom = @max(collapsed.bottom, range.bottom);
        }
        return collapsed;
    }

    pub fn appendOrCollapse(self: *FrameInvalidationSet, range: FrameInvalidationRange) ?FrameInvalidationRange {
        self.append(range) catch |err| switch (err) {
            error.TooManyFrameInvalidations => {
                const collapsed = self.collapsedWith(range);
                self.replaceWith(collapsed);
                return collapsed;
            },
        };
        return null;
    }

    pub fn ranges(self: *const FrameInvalidationSet) []const FrameInvalidationRange {
        return self.items[0..@as(usize, self.len)];
    }

    pub fn isEmpty(self: FrameInvalidationSet) bool {
        return self.len == 0;
    }

    pub fn requiresFullBand(self: FrameInvalidationSet, band: FrameBand) bool {
        if (band.isEmpty()) return false;
        for (self.ranges()) |range| {
            if (range.bottom >= band.top and range.top <= band.bottom) return true;
        }
        return false;
    }

    pub fn dominantReason(self: FrameInvalidationSet) ?FrameInvalidationReason {
        if (self.len == 0) return null;
        var reason = self.items[0].reason;
        for (self.ranges()[1..]) |range| {
            reason = moreSevereFrameInvalidation(reason, range.reason);
        }
        return reason;
    }
};

pub const FrameRepaintWindowOptions = struct {
    include_transcript: bool = true,
    retained_transcript_band: FrameBand = FrameBand.empty(.transcript),
};

pub const FrameRepaintWindow = struct {
    set: FrameInvalidationSet = FrameInvalidationSet.empty(),

    pub fn fromPlan(plan: PaintPlan, options: FrameRepaintWindowOptions) FrameRepaintWindow {
        var window = FrameRepaintWindow{};
        const transcript_exclusion = transcriptExclusion(options, plan);
        if (transcript_exclusion.isEmpty()) {
            if (options.include_transcript) window.appendBand(plan.transcript_band);
        } else {
            window.appendBandExcluding(plan.transcript_band, transcript_exclusion);
        }
        window.appendBand(plan.blank_band);
        window.appendBand(plan.activity_band);
        window.appendBand(plan.footer_gap_band);
        window.appendBand(plan.footer_band);
        for (plan.invalidation.ranges()) |range| {
            window.appendInvalidationRange(plan, options, range);
        }
        return window;
    }

    pub fn validate(self: FrameRepaintWindow, plan: PaintPlan) PaintPlanError!void {
        for (self.ranges()) |range| {
            if (range.top == 0 or range.bottom == 0 or range.bottom < range.top) return error.InvalidInvalidationRange;
            if (range.bottom > plan.layout.rows) return error.InvalidInvalidationRange;
            if (rangeIntersectsBand(range, plan.preserved_band)) return error.InvalidBand;
        }
    }

    pub fn ranges(self: *const FrameRepaintWindow) []const FrameInvalidationRange {
        return self.set.ranges();
    }

    pub fn isEmpty(self: FrameRepaintWindow) bool {
        return self.set.isEmpty();
    }

    pub fn retryInvalidations(self: *const FrameRepaintWindow, reason: FrameInvalidationReason) FrameInvalidationSet {
        var invalidations = FrameInvalidationSet.empty();
        const repaint_ranges = self.ranges();
        if (repaint_ranges.len == 0) return invalidations;

        var retry = FrameInvalidationRange{
            .reason = reason,
            .top = repaint_ranges[0].top,
            .bottom = repaint_ranges[0].bottom,
        };
        for (repaint_ranges[1..]) |range| {
            retry.top = @min(retry.top, range.top);
            retry.bottom = @max(retry.bottom, range.bottom);
        }
        invalidations.replaceWith(retry);
        return invalidations;
    }

    fn appendBand(self: *FrameRepaintWindow, band: FrameBand) void {
        if (band.isEmpty()) return;
        self.appendRange(.{
            .reason = .owned_band_change,
            .top = band.top,
            .bottom = band.bottom,
        });
    }

    fn appendBandExcluding(self: *FrameRepaintWindow, band: FrameBand, excluded: FrameBand) void {
        if (band.isEmpty()) return;
        var segments: [4]FrameInvalidationRange = undefined;
        segments[0] = .{
            .reason = .owned_band_change,
            .top = band.top,
            .bottom = band.bottom,
        };
        const len = excludeBandFromRanges(&segments, 1, excluded);
        for (segments[0..len]) |segment| {
            self.appendRange(segment);
        }
    }

    fn appendRange(self: *FrameRepaintWindow, range: FrameInvalidationRange) void {
        if (range.top == 0 or range.bottom == 0 or range.bottom < range.top) return;
        var merged = range;
        var i: usize = 0;
        while (i < self.set.len) {
            const existing = self.set.items[i];
            if (!rangesTouchOrOverlap(existing, merged)) {
                i += 1;
                continue;
            }
            merged.reason = moreSevereFrameInvalidation(existing.reason, merged.reason);
            merged.top = @min(existing.top, merged.top);
            merged.bottom = @max(existing.bottom, merged.bottom);
            removeRangeAt(&self.set, i);
        }
        _ = self.set.appendOrCollapse(merged);
    }

    fn appendInvalidationRange(
        self: *FrameRepaintWindow,
        plan: PaintPlan,
        options: FrameRepaintWindowOptions,
        range: FrameInvalidationRange,
    ) void {
        var segments: [4]FrameInvalidationRange = undefined;
        segments[0] = range;
        var len: usize = 1;
        len = excludeBandFromRanges(&segments, len, plan.preserved_band);
        len = excludeBandFromRanges(&segments, len, transcriptExclusion(options, plan));
        for (segments[0..len]) |segment| {
            self.appendRange(segment);
        }
    }
};

fn transcriptExclusion(options: FrameRepaintWindowOptions, plan: PaintPlan) FrameBand {
    if (!options.retained_transcript_band.isEmpty()) return options.retained_transcript_band;
    if (!options.include_transcript) return plan.transcript_band;
    return FrameBand.empty(.transcript);
}

pub const FrameCursorTarget = struct {
    row: u16,
    col: u16,
    visible: bool,
};

pub const TranscriptPaintResult = struct {
    painted_rows: u16,
    first_row: u16,
    last_row: u16,
    replaceable_start_row: u16,
};

pub const ActivityPaintResult = struct {
    painted: bool,
    row: u16,
    overlay: bool,
};

pub const FooterReservationSource = enum {
    none,
    footer_layout,
    transient_activity,
    idle_footer_gap,
    resize_reflow,
};

pub const FooterPaintResult = struct {
    painted_rows: u16,
    top_row: u16,
    cursor_row: u16,
    cursor_col: u16,
};

pub const PaintPlanError = error{
    InvalidPaintPlan,
    InvalidTerminalDimensions,
    TerminalTooSmall,
    InvalidBand,
    BandOverlap,
    InvalidActivityPlacement,
    InvalidInvalidationRange,
    CursorOutOfBounds,
};

pub const PaintPlan = struct {
    layout: Layout,
    viewport: viewport_selection.ViewportSelection,
    footer: footer_layout.FooterRows,
    activity: activity_overlay.ActivityPlacement,
    preserved_band: FrameBand,
    transcript_band: FrameBand,
    blank_band: FrameBand = .{ .top = 0, .bottom = 0, .owner = .gap },
    activity_band: FrameBand,
    footer_gap_band: FrameBand = .{ .top = 0, .bottom = 0, .owner = .gap },
    footer_band: FrameBand,
    invalidation: FrameInvalidationSet,
    footer_clean_allowed: bool,
    synchronized_update: bool,
    cursor_target: ?FrameCursorTarget,
    footer_reservation_source: FooterReservationSource,
    bottom_reserved_rows: u16,
    preserve_scrollback: bool,
    reset_terminal: bool = false,

    pub fn validate(self: PaintPlan) PaintPlanError!void {
        if (self.layout.rows == 0 or self.layout.cols == 0) return error.InvalidTerminalDimensions;
        if (self.viewport.top_row == 0) return error.InvalidPaintPlan;
        if (self.viewport.bottom_row < self.viewport.top_row) return error.InvalidPaintPlan;
        if (self.viewport.bottom_row > self.layout.rows) return error.InvalidPaintPlan;
        if (self.viewport.last_visible_row > self.layout.rows) return error.InvalidPaintPlan;
        if (self.footer.top == 0 or self.footer.top > self.layout.rows) return error.InvalidPaintPlan;
        if (self.footer.hint < self.footer.top) return error.InvalidPaintPlan;

        try validateBandInLayout(self.layout, self.preserved_band, .preserved_shell, true);
        try validateBandInLayout(self.layout, self.transcript_band, .transcript, true);
        try validateBandInLayout(self.layout, self.blank_band, .gap, true);
        try validateBandInLayout(self.layout, self.activity_band, .activity, true);
        try validateBandInLayout(self.layout, self.footer_gap_band, .gap, true);
        try validateFooterBand(self.layout, self.footer, self.footer_band);

        try rejectBandOverlap(self.preserved_band, self.transcript_band);
        try rejectBandOverlap(self.preserved_band, self.blank_band);
        try rejectBandOverlap(self.preserved_band, self.activity_band);
        try rejectBandOverlap(self.preserved_band, self.footer_gap_band);
        try rejectBandOverlap(self.preserved_band, self.footer_band);
        try rejectBandOverlap(self.transcript_band, self.blank_band);
        try rejectBandOverlap(self.transcript_band, self.activity_band);
        try rejectBandOverlap(self.transcript_band, self.footer_gap_band);
        try rejectBandOverlap(self.transcript_band, self.footer_band);
        try rejectBandOverlap(self.blank_band, self.activity_band);
        try rejectBandOverlap(self.blank_band, self.footer_gap_band);
        try rejectBandOverlap(self.blank_band, self.footer_band);
        try rejectBandOverlap(self.activity_band, self.footer_gap_band);
        try rejectBandOverlap(self.footer_band, self.activity_band);
        try rejectBandOverlap(self.footer_gap_band, self.footer_band);

        try self.validateActivityPlacement();
        try validateInvalidationRanges(self);
        if (self.cursor_target) |cursor| try validateCursor(self.layout, cursor);
    }

    fn validateActivityPlacement(self: PaintPlan) PaintPlanError!void {
        switch (self.activity) {
            .none => {
                if (!self.activity_band.isEmpty()) return error.InvalidActivityPlacement;
            },
            .transient_row => |activity| {
                if (activity.row == 0 or activity.row > self.layout.rows) return error.InvalidActivityPlacement;
                if (!self.activity_band.containsRow(activity.row)) return error.InvalidActivityPlacement;
                if (activity.tool_row) |tool_row| {
                    if (tool_row == 0 or tool_row +| 2 != activity.row) return error.InvalidActivityPlacement;
                    if (!self.activity_band.containsRow(tool_row)) return error.InvalidActivityPlacement;
                }
                if (self.activity.transcriptReservationRows() == 0) return error.InvalidActivityPlacement;
            },
            .overlay_entry => |row| {
                if (row == 0 or row > self.layout.rows) return error.InvalidActivityPlacement;
                if (!self.transcript_band.containsRow(row)) return error.InvalidActivityPlacement;
                if (!self.activity_band.isEmpty()) return error.InvalidActivityPlacement;
            },
        }
    }
};

pub fn validateBandInLayout(layout: Layout, band: FrameBand, expected_owner: CellOwner, allow_empty: bool) PaintPlanError!void {
    if (band.owner != expected_owner) return error.InvalidBand;
    if (band.isEmpty()) {
        if (allow_empty) return;
        return error.InvalidBand;
    }
    if (band.top == 0 or band.bottom == 0 or band.bottom < band.top) return error.InvalidBand;
    if (band.bottom > layout.rows) return error.InvalidBand;
}

pub fn bandsOverlap(a: FrameBand, b: FrameBand) bool {
    if (a.isEmpty() or b.isEmpty()) return false;
    return a.bottom >= b.top and b.bottom >= a.top;
}

fn rejectBandOverlap(a: FrameBand, b: FrameBand) PaintPlanError!void {
    if (bandsOverlap(a, b)) return error.BandOverlap;
}

pub fn validateFooterBand(layout: Layout, footer: footer_layout.FooterRows, band: FrameBand) PaintPlanError!void {
    if (band.isEmpty()) {
        if (footer.total_rows != 0) return error.InvalidBand;
        return;
    }
    try validateBandInLayout(layout, band, .footer, false);
    if (band.top != footer.top or band.bottom != @min(footer.hint, layout.rows)) return error.InvalidBand;
}

pub fn validateInvalidationRange(plan: PaintPlan, range: FrameInvalidationRange) PaintPlanError!void {
    if (range.top == 0 or range.bottom == 0 or range.bottom < range.top) return error.InvalidInvalidationRange;
    if (range.bottom > plan.layout.rows) return error.InvalidInvalidationRange;
    switch (range.reason) {
        .diagnostic_wipe, .reserved_gap_clear, .terminal_scroll, .viewport_reanchor => return,
        .resize, .owned_band_change, .external_clear, .toggle_command_output, .partial_write, .shadow_feed_failure => {},
    }
    if (invalidationIntersectsOwnedBand(plan, range)) return;
    return error.InvalidInvalidationRange;
}

pub fn invalidationIntersectsOwnedBand(plan: PaintPlan, range: FrameInvalidationRange) bool {
    return rangeIntersectsBand(range, plan.transcript_band) or
        rangeIntersectsBand(range, plan.blank_band) or
        rangeIntersectsBand(range, plan.footer_band) or
        rangeIntersectsBand(range, plan.activity_band) or
        rangeIntersectsBand(range, plan.footer_gap_band);
}

fn validateInvalidationRanges(plan: PaintPlan) PaintPlanError!void {
    for (plan.invalidation.ranges()) |range| {
        try validateInvalidationRange(plan, range);
    }
}

fn rangeIntersectsBand(range: FrameInvalidationRange, band: FrameBand) bool {
    if (band.isEmpty()) return false;
    return range.bottom >= band.top and range.top <= band.bottom;
}

fn rangesTouchOrOverlap(a: FrameInvalidationRange, b: FrameInvalidationRange) bool {
    return a.bottom +| 1 >= b.top and b.bottom +| 1 >= a.top;
}

fn removeRangeAt(set: *FrameInvalidationSet, index: usize) void {
    var i = index;
    while (i + 1 < set.len) : (i += 1) {
        set.items[i] = set.items[i + 1];
    }
    set.len -= 1;
}

fn excludeBandFromRanges(
    ranges: *[4]FrameInvalidationRange,
    len: usize,
    band: FrameBand,
) usize {
    if (band.isEmpty() or len == 0) return len;
    var next: [4]FrameInvalidationRange = undefined;
    var next_len: usize = 0;
    for (ranges[0..len]) |range| {
        if (range.bottom < band.top or range.top > band.bottom) {
            next[next_len] = range;
            next_len += 1;
            continue;
        }
        if (range.top < band.top) {
            next[next_len] = .{
                .reason = range.reason,
                .top = range.top,
                .bottom = band.top - 1,
            };
            next_len += 1;
        }
        if (range.bottom > band.bottom) {
            next[next_len] = .{
                .reason = range.reason,
                .top = band.bottom + 1,
                .bottom = range.bottom,
            };
            next_len += 1;
        }
    }
    for (next[0..next_len], 0..) |range, index| {
        ranges[index] = range;
    }
    return next_len;
}

fn bandsSameRange(a: FrameBand, b: FrameBand) bool {
    return a.top == b.top and a.bottom == b.bottom;
}

fn clampBandToRows(band: FrameBand, rows: u16) FrameBand {
    if (band.isEmpty() or rows == 0 or band.top > rows) return FrameBand.empty(band.owner);
    return .{ .top = band.top, .bottom = @min(band.bottom, rows), .owner = band.owner };
}

fn unionBands(a: FrameBand, b: FrameBand, owner: CellOwner) FrameBand {
    var top: u16 = 0;
    var bottom: u16 = 0;
    includeBand(&top, &bottom, a);
    includeBand(&top, &bottom, b);
    if (top == 0) return FrameBand.empty(owner);
    return .{ .top = top, .bottom = bottom, .owner = owner };
}

fn includeBand(top: *u16, bottom: *u16, band: FrameBand) void {
    if (band.isEmpty()) return;
    if (top.* == 0 or band.top < top.*) top.* = band.top;
    if (band.bottom > bottom.*) bottom.* = band.bottom;
}

pub fn validateCursor(layout: Layout, cursor: FrameCursorTarget) PaintPlanError!void {
    if (!cursor.visible) return;
    if (cursor.row == 0 or cursor.row > layout.rows) return error.CursorOutOfBounds;
    if (cursor.col == 0 or cursor.col > layout.cols) return error.CursorOutOfBounds;
}

pub fn transcriptBottomLimit(
    footer_top: u16,
    activity: activity_overlay.ActivityPlacement,
    bottom_reserved_rows: u16,
) u16 {
    if (footer_top <= 1) return 0;
    var bottom = footer_top - 1;
    if (activity.reservedTopRow()) |reserved_top| {
        if (reserved_top <= 1) return 0;
        bottom = @min(bottom, reserved_top - 1);
    } else if (bottom_reserved_rows > 0) {
        if (bottom_reserved_rows >= bottom) return 0;
        bottom -= bottom_reserved_rows;
    }
    return bottom;
}









fn validPlan() PaintPlan {
    return .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 20,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 3,
            .last_visible_row = 4,
        },
        .footer = .{
            .top = 21,
            .top_divider = 21,
            .banner = 21,
            .banner_active = false,
            .banner_rows = 0,
            .input_base = 22,
            .picker_divider = 23,
            .picker_start = 24,
            .bottom_divider = 23,
            .hint = 24,
            .total_rows = 4,
        },
        .activity = .none,
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 20, .owner = .transcript },
        .activity_band = FrameBand.empty(.activity),
        .footer_band = .{ .top = 21, .bottom = 24, .owner = .footer },
        .invalidation = FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 22, .col = 1, .visible = true },
        .footer_reservation_source = .footer_layout,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}











