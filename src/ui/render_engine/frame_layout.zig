const std = @import("std");
const types = @import("../../core/shared/types.zig");
const activity_overlay = @import("activity_overlay.zig");
const footer_layout = @import("footer_layout.zig");
const paint_plan = @import("paint_plan.zig");
const transcript_blocks = @import("transcript_blocks.zig");
const viewport_selection = @import("viewport_selection.zig");

const Layout = types.Layout;

pub const FramePlacementPolicy = enum {
    compact_until_full,
};

pub const FrameRect = struct {
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn empty() FrameRect {
        return .{};
    }

    pub fn isEmpty(self: FrameRect) bool {
        return self.top == 0 and self.bottom == 0;
    }

    pub fn height(self: FrameRect) u16 {
        if (self.isEmpty()) return 0;
        return self.bottom - self.top + 1;
    }

    pub fn containsRow(self: FrameRect, row: u16) bool {
        return !self.isEmpty() and row >= self.top and row <= self.bottom;
    }

    pub fn toBand(self: FrameRect, owner: paint_plan.CellOwner) paint_plan.FrameBand {
        if (self.isEmpty()) return paint_plan.FrameBand.empty(owner);
        return .{ .top = self.top, .bottom = self.bottom, .owner = owner };
    }
};

pub const FooterMeasurement = struct {
    natural_rows: u16,
    min_rows: u16,
    max_rows: u16,
    top_gap_rows: u16 = 0,
    input_rows: u16 = 1,
    picker_rows: u16 = 0,
    banner_rows: u16 = 0,
};

pub const TranscriptFlowPreview = struct {
    natural_visual_rows: u16,
    trailing_boundary_blank_rows: u16 = 0,
    footer_boundary_gap_rows: u16 = 0,
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
    replaceable_row: u16 = 1,
    tail_kind: ?transcript_blocks.TranscriptBlockKind = null,
    replaceable_active: bool = false,
    welcome_split_active: bool = false,
    split_prefix_lines: usize = 0,
    split_suffix_start_line: usize = 0,
};

pub const ActivityState = union(enum) {
    none,
    thinking: Thinking,
    overlay_entry: u16,

    pub const Thinking = struct {
        gap_above_activity: u16,
        activity_rows: u16 = 1,
        footer_gap_after_activity: u16 = 0,
        tool_before_activity: bool = false,
    };
};

pub const BodyMode = enum {
    transcript,
    subagent_panel,
};

pub const CommittedLayoutSnapshot = struct {
    layout_id: u64 = 0,
    owned_top: u16 = 1,
    owned_band: FrameRect = .{},
    body_area: FrameRect = .{},
    transcript_area: FrameRect = .{},
    footer_area: FrameRect = .{},
    activity_row: ?u16 = null,
    activity_rows: u16 = 0,
    tool_activity_row: ?u16 = null,
    solved_frame_height: u16 = 0,
    terminal_rows: u16 = 0,
    terminal_cols: u16 = 0,

    pub fn fromLayout(layout: FrameLayout) CommittedLayoutSnapshot {
        return .{
            .layout_id = layout.layout_id,
            .owned_top = layout.owned_top,
            .owned_band = layout.owned_band,
            .body_area = layout.body_area,
            .transcript_area = layout.transcript_area,
            .footer_area = layout.footer_area,
            .activity_row = layout.activity_row,
            .activity_rows = layout.activity_rows,
            .tool_activity_row = layout.tool_activity_row,
            .solved_frame_height = layout.solved_frame_height,
            .terminal_rows = layout.terminal.rows,
            .terminal_cols = layout.terminal.cols,
        };
    }

    pub fn fromPaintPlan(plan: paint_plan.PaintPlan) CommittedLayoutSnapshot {
        const owned_top = if (!plan.preserved_band.isEmpty())
            plan.preserved_band.bottom + 1
        else
            firstOwnedRow(plan);
        const owned_bottom = lastOwnedRow(plan);
        const owned_band = if (owned_top > 0 and owned_bottom >= owned_top)
            FrameRect{ .top = owned_top, .bottom = owned_bottom }
        else
            FrameRect.empty();
        const footer_area = rectFromBand(plan.footer_band);
        const body_bottom = if (footer_area.isEmpty())
            owned_bottom
        else
            footer_area.top -| 1;
        const body_area = if (!owned_band.isEmpty() and body_bottom >= owned_top)
            FrameRect{ .top = owned_top, .bottom = body_bottom }
        else
            FrameRect.empty();

        var layout = FrameLayout{
            .layout_id = 0,
            .terminal = plan.layout,
            .owned_top = owned_top,
            .owned_band = owned_band,
            .body_area = body_area,
            .transcript_area = rectFromBand(plan.transcript_band),
            .footer_area = footer_area,
            .activity_row = plan.activity.row(),
            .activity_rows = plan.activity.primaryRowCount(),
            .tool_activity_row = plan.activity.toolRow(),
            .blank_area = rectFromBand(plan.blank_band),
            .footer_gap_area = rectFromBand(plan.footer_gap_band),
            .solved_frame_height = owned_band.height(),
            .placement_policy = .compact_until_full,
        };
        layout.layout_id = layoutId(layout);
        return fromLayout(layout);
    }
};

pub const SolveInput = struct {
    terminal: Layout,
    owned_top: u16,
    footer: FooterMeasurement,
    transcript: TranscriptFlowPreview,
    activity: ActivityState = .none,
    body_mode: BodyMode = .transcript,
    prior: CommittedLayoutSnapshot = .{},
    placement_policy: FramePlacementPolicy = .compact_until_full,
};

pub const PreservedRowReleasePlan = struct {
    layout: FrameLayout,
    released_rows: u16,
};

pub const FrameLayout = struct {
    layout_id: u64,
    terminal: Layout,
    owned_top: u16,
    owned_band: FrameRect,
    body_area: FrameRect,
    transcript_area: FrameRect,
    footer_area: FrameRect,
    activity_row: ?u16,
    activity_rows: u16 = 0,
    tool_activity_row: ?u16 = null,
    blank_area: FrameRect,
    footer_gap_area: FrameRect,
    solved_frame_height: u16,
    placement_policy: FramePlacementPolicy,

    pub fn toPaintPlan(self: FrameLayout, options: PaintPlanOptions) paint_plan.PaintPlan {
        const footer_rows = shiftFooterRows(options.footer_rows, self.footer_area.top);
        const activity = shiftActivity(options.activity, self.activity_row, self.activity_rows, self.tool_activity_row, self.transcript_area);
        const preserved_band = if (self.owned_top > 1)
            paint_plan.FrameBand{ .top = 1, .bottom = self.owned_top - 1, .owner = .preserved_shell }
        else
            paint_plan.FrameBand.empty(.preserved_shell);
        const layout = Layout{
            .rows = self.terminal.rows,
            .cols = self.terminal.cols,
            .content_bottom = if (self.body_area.isEmpty()) self.owned_top else self.body_area.bottom,
            .divider_top_row = footer_rows.top_divider,
            .input_row = footer_rows.input_base,
            .divider_bottom_row = footer_rows.bottom_divider,
            .hint_row = footer_rows.hint,
        };

        return .{
            .layout = layout,
            .viewport = options.viewport,
            .footer = footer_rows,
            .activity = activity,
            .preserved_band = preserved_band,
            .transcript_band = self.transcript_area.toBand(.transcript),
            .blank_band = self.blank_area.toBand(.gap),
            .activity_band = paint_plan.activityBand(activity),
            .footer_gap_band = self.footer_gap_area.toBand(.gap),
            .footer_band = self.footer_area.toBand(.footer),
            .invalidation = options.invalidation,
            .footer_clean_allowed = options.invalidation.isEmpty(),
            .synchronized_update = options.synchronized_update,
            .cursor_target = options.cursor_target,
            .footer_reservation_source = .none,
            .bottom_reserved_rows = 0,
            .preserve_scrollback = options.preserve_scrollback,
            .reset_terminal = options.reset_terminal,
        };
    }
};

pub const PaintPlanOptions = struct {
    footer_rows: footer_layout.FooterRows,
    viewport: viewport_selection.ViewportSelection,
    activity: activity_overlay.ActivityPlacement = .none,
    invalidation: paint_plan.FrameInvalidationSet = paint_plan.FrameInvalidationSet.empty(),
    synchronized_update: bool = true,
    cursor_target: ?paint_plan.FrameCursorTarget = null,
    preserve_scrollback: bool = true,
    reset_terminal: bool = false,
};

pub fn solve(input: SolveInput) FrameLayout {
    const terminal_rows = input.terminal.rows;
    const owned_top = clampOwnedTop(input.owned_top, terminal_rows);
    const available_rows = rowsAvailableBelow(terminal_rows, owned_top);
    const footer_height = solveFooterHeight(input.footer, available_rows);
    const reservation = solveActivityReservation(input, footer_height, available_rows);

    const reserved_activity_rows = reservation.boundary_gap +| reservation.activity_rows +| reservation.footer_gap;
    const body_capacity = available_rows -| footer_height -| reserved_activity_rows;
    const natural_body_rows = switch (input.body_mode) {
        .transcript, .subagent_panel => input.transcript.natural_visual_rows,
    };
    const transcript_height = @min(natural_body_rows, body_capacity);
    const solved_frame_height = @min(available_rows, transcript_height +| reserved_activity_rows +| footer_height);
    const owned_band = rectFromTopHeight(owned_top, solved_frame_height);
    const transcript_area = rectFromTopHeight(owned_top, transcript_height);
    const blank_top = if (transcript_area.isEmpty()) owned_top else transcript_area.bottom + 1;
    const blank_area = rectFromTopHeight(blank_top, reservation.boundary_gap);
    const activity_row: ?u16 = if (reservation.activity_rows > 0)
        if (reservation.tool_before_activity)
            blank_top + reservation.boundary_gap + 2
        else
            blank_top + reservation.boundary_gap
    else
        null;
    const tool_activity_row: ?u16 = if (reservation.tool_before_activity)
        blank_top + reservation.boundary_gap
    else
        null;
    const footer_gap_top = if (activity_row) |row| row + reservation.primary_rows else blank_top + reservation.boundary_gap;
    const footer_gap_area = rectFromTopHeight(footer_gap_top, reservation.footer_gap);
    const footer_top = if (footer_height > 0 and !owned_band.isEmpty())
        owned_band.bottom - footer_height + 1
    else
        0;
    const footer_area = rectFromTopHeight(footer_top, footer_height);
    const body_bottom = if (footer_area.isEmpty()) owned_band.bottom else footer_area.top -| 1;
    const body_area = if (!owned_band.isEmpty() and body_bottom >= owned_band.top)
        FrameRect{ .top = owned_band.top, .bottom = body_bottom }
    else
        FrameRect.empty();

    var result = FrameLayout{
        .layout_id = 0,
        .terminal = input.terminal,
        .owned_top = owned_top,
        .owned_band = owned_band,
        .body_area = body_area,
        .transcript_area = transcript_area,
        .footer_area = footer_area,
        .activity_row = activity_row,
        .activity_rows = if (activity_row != null) reservation.primary_rows else 0,
        .tool_activity_row = tool_activity_row,
        .blank_area = blank_area,
        .footer_gap_area = footer_gap_area,
        .solved_frame_height = solved_frame_height,
        .placement_policy = input.placement_policy,
    };
    result.layout_id = layoutId(result);
    return result;
}

pub fn solveWithPreservedRowRelease(input: SolveInput, release_floor_rows: u16) PreservedRowReleasePlan {
    const initial = solve(input);
    if (input.terminal.rows == 0 or input.terminal.cols == 0) {
        return .{ .layout = initial, .released_rows = 0 };
    }

    var maximum_input = input;
    maximum_input.owned_top = 1;
    const maximum = solve(maximum_input);
    const geometry_top = if (maximum.solved_frame_height == 0)
        initial.owned_top
    else
        @min(initial.owned_top, input.terminal.rows - maximum.solved_frame_height + 1);
    const floor_top = @max(@as(u16, 1), initial.owned_top -| release_floor_rows);

    var final_input = input;
    final_input.owned_top = @min(geometry_top, floor_top);
    const final = solve(final_input);
    return .{
        .layout = final,
        .released_rows = initial.owned_top -| final.owned_top,
    };
}

const ActivityReservation = struct {
    boundary_gap: u16 = 0,
    activity_rows: u16 = 0,
    primary_rows: u16 = 1,
    footer_gap: u16 = 0,
    tool_before_activity: bool = false,
};

fn solveActivityReservation(input: SolveInput, footer_height: u16, available_rows: u16) ActivityReservation {
    const min_body_rows: u16 = if (input.transcript.natural_visual_rows > 0) 1 else 0;
    switch (input.activity) {
        .thinking => |thinking| {
            const primary_rows = @max(thinking.activity_rows, 1);
            const full_rows: u16 = if (thinking.tool_before_activity) primary_rows +| 2 else primary_rows;
            const fixed_rows = footer_height +| min_body_rows +| thinking.gap_above_activity +| thinking.footer_gap_after_activity;
            if (available_rows >= fixed_rows +| full_rows) return .{
                .boundary_gap = thinking.gap_above_activity,
                .activity_rows = full_rows,
                .primary_rows = primary_rows,
                .footer_gap = thinking.footer_gap_after_activity,
                .tool_before_activity = thinking.tool_before_activity,
            };
            if (available_rows >= fixed_rows +| 1) return .{
                .boundary_gap = thinking.gap_above_activity,
                .activity_rows = 1,
                .footer_gap = thinking.footer_gap_after_activity,
            };
        },
        .overlay_entry, .none => {},
    }
    const transcript_gap = @max(
        input.transcript.trailing_boundary_blank_rows,
        input.transcript.footer_boundary_gap_rows,
    );
    const idle_gap = @max(transcript_gap, input.footer.top_gap_rows);
    if (idle_gap > 0 and footer_height > 0 and available_rows >= footer_height +| min_body_rows +| idle_gap) {
        return .{ .boundary_gap = idle_gap };
    }
    return .{};
}

fn clampOwnedTop(owned_top: u16, terminal_rows: u16) u16 {
    if (terminal_rows == 0) return 0;
    if (owned_top == 0) return 1;
    return @min(owned_top, terminal_rows);
}

fn rowsAvailableBelow(terminal_rows: u16, owned_top: u16) u16 {
    if (terminal_rows == 0 or owned_top == 0 or owned_top > terminal_rows) return 0;
    return terminal_rows - owned_top + 1;
}

fn rectFromBand(band: paint_plan.FrameBand) FrameRect {
    if (band.isEmpty()) return .empty();
    return .{ .top = band.top, .bottom = band.bottom };
}

fn firstOwnedRow(plan: paint_plan.PaintPlan) u16 {
    const bands = [_]paint_plan.FrameBand{
        plan.transcript_band,
        plan.blank_band,
        plan.activity_band,
        plan.footer_gap_band,
        plan.footer_band,
    };
    var first: u16 = 0;
    for (bands) |band| {
        if (band.isEmpty()) continue;
        if (first == 0 or band.top < first) first = band.top;
    }
    return first;
}

fn lastOwnedRow(plan: paint_plan.PaintPlan) u16 {
    const bands = [_]paint_plan.FrameBand{
        plan.transcript_band,
        plan.blank_band,
        plan.activity_band,
        plan.footer_gap_band,
        plan.footer_band,
    };
    var last: u16 = 0;
    for (bands) |band| {
        if (!band.isEmpty()) last = @max(last, band.bottom);
    }
    return last;
}

fn solveFooterHeight(measurement: FooterMeasurement, available_rows: u16) u16 {
    if (available_rows == 0) return 0;
    const max_rows = if (measurement.max_rows == 0) measurement.natural_rows else measurement.max_rows;
    const min_rows = @min(measurement.min_rows, max_rows);
    const natural = @min(@max(measurement.natural_rows, min_rows), max_rows);
    return @min(natural, available_rows);
}

fn rectFromTopHeight(top: u16, height_rows: u16) FrameRect {
    if (top == 0 or height_rows == 0) return FrameRect.empty();
    return .{ .top = top, .bottom = top + height_rows - 1 };
}

fn layoutId(layout: FrameLayout) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashU16(&hasher, layout.terminal.rows);
    hashU16(&hasher, layout.terminal.cols);
    hashU16(&hasher, layout.owned_top);
    hashRect(&hasher, layout.owned_band);
    hashRect(&hasher, layout.body_area);
    hashRect(&hasher, layout.transcript_area);
    hashRect(&hasher, layout.footer_area);
    hashU16(&hasher, layout.activity_row orelse 0);
    hashU16(&hasher, layout.activity_rows);
    hashU16(&hasher, layout.tool_activity_row orelse 0);
    hashRect(&hasher, layout.blank_area);
    hashRect(&hasher, layout.footer_gap_area);
    hashU16(&hasher, layout.solved_frame_height);
    hashU16(&hasher, @intFromEnum(layout.placement_policy));
    const value = hasher.final();
    return if (value == 0) 1 else value;
}

fn hashRect(hasher: *std.hash.Wyhash, rect: FrameRect) void {
    hashU16(hasher, rect.top);
    hashU16(hasher, rect.bottom);
}

fn hashU16(hasher: *std.hash.Wyhash, value: u16) void {
    hasher.update(std.mem.asBytes(&value));
}

fn shiftFooterRows(rows: footer_layout.FooterRows, top: u16) footer_layout.FooterRows {
    if (top == 0 or rows.top == top) return rows;
    return .{
        .top = top,
        .top_divider = shiftRow(rows.top_divider, rows.top, top),
        .banner = shiftRow(rows.banner, rows.top, top),
        .banner_active = rows.banner_active,
        .input_base = shiftRow(rows.input_base, rows.top, top),
        .picker_divider = shiftRow(rows.picker_divider, rows.top, top),
        .picker_start = shiftRow(rows.picker_start, rows.top, top),
        .bottom_divider = shiftRow(rows.bottom_divider, rows.top, top),
        .hint = shiftRow(rows.hint, rows.top, top),
        .total_rows = rows.total_rows,
    };
}

fn shiftRow(row: u16, old_top: u16, new_top: u16) u16 {
    if (row <= old_top) return new_top;
    return new_top + (row - old_top);
}

fn shiftActivity(
    activity: activity_overlay.ActivityPlacement,
    row: ?u16,
    row_count: u16,
    tool_row: ?u16,
    transcript_area: FrameRect,
) activity_overlay.ActivityPlacement {
    return switch (activity) {
        .transient_row => |transient| if (row) |solved_row|
            .{ .transient_row = .{
                .row = solved_row,
                .row_count = @max(row_count, 1),
                .gap_above_rows = transient.gap_above_rows,
                .footer_clearance_rows = transient.footer_clearance_rows,
                .tool_row = tool_row,
            } }
        else
            .none,
        .overlay_entry => |overlay_row| blk: {
            break :blk if (transcript_area.containsRow(overlay_row))
                .{ .overlay_entry = overlay_row }
            else
                .none;
        },
        .none => .none,
    };
}

fn testLayout(rows: u16, cols: u16) Layout {
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = if (rows > 4) rows - 4 else 1,
        .divider_top_row = if (rows > 3) rows - 3 else 1,
        .input_row = if (rows > 2) rows - 2 else 1,
        .divider_bottom_row = if (rows > 1) rows - 1 else 1,
        .hint_row = rows,
    };
}

fn testFooter(rows: u16) FooterMeasurement {
    return .{
        .natural_rows = rows,
        .min_rows = @min(rows, 1),
        .max_rows = rows,
    };
}

fn testFooterRows(top: u16, rows: u16) footer_layout.FooterRows {
    return .{
        .top = top,
        .top_divider = top,
        .banner = top,
        .banner_active = false,
        .input_base = top + 1,
        .picker_divider = top + 2,
        .picker_start = top + 3,
        .bottom_divider = top + rows - 2,
        .hint = top + rows - 1,
        .total_rows = rows,
    };
}
