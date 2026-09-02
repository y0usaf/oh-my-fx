const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const frame_layout = @import("frame_layout.zig");
const frame_retention = @import("frame_retention.zig");
const frame_scroll_plan = @import("frame_scroll_plan.zig");
const frame_surface = @import("frame_surface.zig");
const paint_plan = @import("paint_plan.zig");
const terminal_diff = @import("terminal_diff.zig");
const transcript_blocks = @import("transcript_blocks.zig");
const ui_observer = @import("ui_observer.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;

pub const FrameBody = union(enum) {
    transcript,
    subagent_panel: []const u8,
    none,
};

pub const SurfacePainter = struct {
    ctx: *anyopaque,
    paint: *const fn (ctx: *anyopaque, surface: *frame_surface.FrameSurface) anyerror!void,
};

pub const TraceCounters = struct {
    body_paints: usize = 0,
    footer_paints: usize = 0,
    activity_paints: usize = 0,
    frame_commits: usize = 0,
    retained_transcript_changed_cells: usize = 0,
};

pub const RetainedTranscriptBody = frame_retention.RetainedTranscriptBody;
pub const TranscriptBodyDisposition = frame_retention.TranscriptBodyDisposition;

pub const FramePresentation = enum {
    styled,
    neutral,
};

pub const BuildFrameOptions = struct {
    plan: paint_plan.PaintPlan,
    committed_layout: ?frame_layout.CommittedLayoutSnapshot = null,
    body: FrameBody = .transcript,
    transcript_body: TranscriptBodyDisposition = .paint,
    captured_repaint: bool = false,
    scroll_plan: frame_scroll_plan.FrameScrollPlan,
    document_append: frame_scroll_plan.FrameDocumentAppend = .{},
    terminal_transition: terminal_diff.FrameTerminalTransition = .none,
    body_painter: ?SurfacePainter = null,
    /// Paints a bounded prompt tail after retained transcript rows and before
    /// footer/activity surfaces. It never replaces the transcript body owner.
    transcript_tail_painter: ?SurfacePainter = null,
    footer_painter: ?SurfacePainter = null,
    activity_painter: ?SurfacePainter = null,
    presentation: FramePresentation = .styled,
    trace_counters: ?*TraceCounters = null,
    observation: ?FrameObservation = null,
};

pub const FrameObservation = struct {
    observer: *ui_observer.UiObserver,
    row_provenance: []const transcript_blocks.RowProvenance,
    activity: activity_runtime.ActivityProjection,
    stream_active: bool,
    completed_assistant_presentation_tail: bool,
};

pub fn buildAndFlushFrame(
    alloc: Allocator,
    shell: anytype,
    metrics: *Metrics,
    options: BuildFrameOptions,
) !terminal_diff.FrameCommitResult {
    var plan = options.plan;
    const shadow = shell.shadow_vt orelse return error.ShadowVtDisabled;
    const committed_layout = options.committed_layout orelse shell.committed_frame_layout;
    const terminal_scroll_rows = try prepareFramePlan(
        &plan,
        shadow,
        committed_layout,
        &options,
    );
    const repaint_window = frameRepaintWindow(plan, options.transcript_body);
    logFrameBuildPlan(plan, options);

    var movement = try terminal_diff.prepareTerminalMovementForFrame(
        alloc,
        shadow,
        options.document_append,
        terminal_scroll_rows,
        options.scroll_plan.preserved_release_rows,
        plan.layout.cols,
        plan.layout.rows,
        alignmentClearStartRow(
            committed_layout,
            shadow,
            plan.layout,
        ),
        options.terminal_transition,
    );
    defer movement.deinit(alloc);

    var surface = try frame_surface.FrameSurface.initFromShadow(alloc, plan, movement.post_movement);
    defer surface.deinit();

    try paintFrameSurface(&surface, &movement, &options);
    if (options.presentation == .neutral) surface.neutralizeFxOwnedPresentation();
    traceRetainedTranscriptChanges(&surface, &movement, &options);

    try surface.validate();
    const result = try terminal_diff.flushFrame(.{
        .previous = shadow,
        .surface = &surface,
        .repaint_window = repaint_window,
        .synchronized_update = plan.synchronized_update,
        .history_reset_uses_ris = shell.history_reset_uses_ris,
        .scroll_plan = options.scroll_plan,
        .document_append = options.document_append,
        .terminal_transition = options.terminal_transition,
        .prepared_movement = &movement,
        .sink = shell.frameSink(),
        .metrics = metrics,
    });
    if (options.trace_counters) |counters| counters.frame_commits += 1;

    logFrameCommitResult(plan, result);
    observeCommittedFrame(alloc, &surface, &plan, result, &options);
    try record_retry_invalidation(shell, result);
    return result;
}

fn alignmentClearStartRow(
    committed_layout: frame_layout.CommittedLayoutSnapshot,
    shadow: *const vt_emulator.Grid,
    target: types.Layout,
) u16 {
    if (committed_layout.layout_id == 0 or
        committed_layout.terminal_rows != shadow.rows or
        committed_layout.terminal_cols != shadow.cols or
        target.rows != shadow.rows or
        target.cols != shadow.cols)
    {
        return 0;
    }
    if (committed_layout.transcript_area.isEmpty()) {
        const owned_top = committed_layout.owned_band.top;
        return if (owned_top > 0 and owned_top <= target.rows) owned_top else 0;
    }
    const transcript_bottom = committed_layout.transcript_area.bottom;
    return if (committed_layout.transcript_area.top > 0 and transcript_bottom < target.rows)
        transcript_bottom + 1
    else
        0;
}

fn frameRepaintWindow(
    plan: paint_plan.PaintPlan,
    transcript_body: TranscriptBodyDisposition,
) paint_plan.FrameRepaintWindow {
    return switch (transcript_body) {
        .paint => paint_plan.FrameRepaintWindow.fromPlan(plan, .{ .include_transcript = true }),
        .retain => |retained| paint_plan.FrameRepaintWindow.fromPlan(plan, .{
            .include_transcript = false,
            .retained_transcript_band = retained.source_area.toBand(.transcript),
        }),
    };
}

fn prepareFramePlan(
    plan: *paint_plan.PaintPlan,
    shadow: *const vt_emulator.Grid,
    committed_frame_layout: frame_layout.CommittedLayoutSnapshot,
    options: *const BuildFrameOptions,
) !u16 {
    try plan.validate();

    if (shadow.rows != plan.layout.rows or shadow.cols != plan.layout.cols) {
        invalidateCurrentOwnedBand(plan, .resize);
    }
    try options.scroll_plan.validate(plan.layout.rows);
    const terminal_scroll_rows = options.scroll_plan.terminal_scroll_rows;
    if (terminal_scroll_rows > 0) {
        invalidateCurrentOwnedBand(plan, .terminal_scroll);
    }
    if (committed_frame_layout.layout_id != 0) {
        invalidateOwnedBandChange(
            plan,
            committed_frame_layout.owned_band.toBand(.transcript),
        );
    }
    return terminal_scroll_rows;
}

fn logFrameBuildPlan(plan: paint_plan.PaintPlan, options: BuildFrameOptions) void {
    debug_trace.logf(
        "frame_plan",
        "build layout={d}x{d} transcript={d}..{d} footer={d}..{d} activity={d}..{d} invalidations={d} body={s} transcript_body={s} captured={s}",
        .{
            plan.layout.cols,
            plan.layout.rows,
            plan.transcript_band.top,
            plan.transcript_band.bottom,
            plan.footer_band.top,
            plan.footer_band.bottom,
            plan.activity_band.top,
            plan.activity_band.bottom,
            plan.invalidation.len,
            @tagName(options.body),
            @tagName(options.transcript_body),
            if (options.captured_repaint) "true" else "false",
        },
    );
}

fn paintFrameSurface(
    surface: *frame_surface.FrameSurface,
    movement: *const terminal_diff.PreparedTerminalMovement,
    options: *const BuildFrameOptions,
) !void {
    switch (options.transcript_body) {
        .paint => {
            if (options.body_painter) |painter| {
                try painter.paint(painter.ctx, surface);
                if (options.trace_counters) |counters| counters.body_paints += 1;
            }
        },
        .retain => |retained| {
            try frame_retention.validate(
                surface.plan,
                options.body == .transcript,
                movement.*,
                retained,
            );
            try surface.retainTranscriptBandFromGrid(
                movement.post_movement,
                retained.source_area,
            );
        },
    }
    if (options.transcript_tail_painter) |painter| {
        try painter.paint(painter.ctx, surface);
    }
    if (options.footer_painter) |painter| {
        try painter.paint(painter.ctx, surface);
        if (options.trace_counters) |counters| counters.footer_paints += 1;
    }
    if (options.activity_painter) |painter| {
        try painter.paint(painter.ctx, surface);
        if (options.trace_counters) |counters| counters.activity_paints += 1;
    }
}

fn traceRetainedTranscriptChanges(
    surface: *const frame_surface.FrameSurface,
    movement: *const terminal_diff.PreparedTerminalMovement,
    options: *const BuildFrameOptions,
) void {
    switch (options.transcript_body) {
        .paint => return,
        .retain => |retained| {
            const changed = frame_retention.countSurfaceChanges(
                movement.post_movement,
                surface.*,
                retained.source_area,
            );
            if (options.trace_counters) |counters| {
                counters.retained_transcript_changed_cells = changed;
            }
            debug_trace.logf(
                "frame_diff",
                "retained_transcript source={d}..{d} occupied_last_row={d} changed_cells={d}",
                .{
                    retained.source_area.top,
                    retained.source_area.bottom,
                    retained.occupied_last_row,
                    changed,
                },
            );
        },
    }
}

fn logFrameCommitResult(plan: paint_plan.PaintPlan, result: terminal_diff.FrameCommitResult) void {
    const retry_invalidation_count: u8 = if (result.retry_invalidation() != null) 1 else 0;
    debug_trace.logf(
        "frame_diff",
        "result state={s} bytes={d} changed_cells={d} full_repaint={s} invalidation={s} next_invalidations={d}",
        .{
            @tagName(result.state()),
            result.bytes_written,
            result.changed_cells,
            if (result.full_repaint) "true" else "false",
            firstInvalidationName(plan.invalidation),
            retry_invalidation_count,
        },
    );
}

fn observeCommittedFrame(
    alloc: Allocator,
    surface: *frame_surface.FrameSurface,
    plan: *const paint_plan.PaintPlan,
    result: terminal_diff.FrameCommitResult,
    options: *const BuildFrameOptions,
) void {
    if (!result.is_committed()) return;
    if (options.observation) |observation| {
        observation.observer.observeNormalFrame(alloc, .{
            .surface = surface,
            .plan = plan,
            .row_provenance = observation.row_provenance,
            .activity = observation.activity,
            .stream_active = observation.stream_active,
            .completed_assistant_presentation_tail = observation.completed_assistant_presentation_tail,
        });
    }
}

fn record_retry_invalidation(shell: anytype, result: terminal_diff.FrameCommitResult) !void {
    const range = result.retry_invalidation() orelse return;
    try shell.recordFrameInvalidation(range);
}

fn firstInvalidationName(set: paint_plan.FrameInvalidationSet) []const u8 {
    if (set.len == 0) return "none";
    return @tagName(set.ranges()[0].reason);
}

fn invalidateCurrentOwnedBand(
    plan: *paint_plan.PaintPlan,
    reason: paint_plan.FrameInvalidationReason,
) void {
    invalidateBand(plan, reason, paint_plan.paintedContentBand(plan.*));
}

fn invalidateOwnedBandChange(
    plan: *paint_plan.PaintPlan,
    previous: paint_plan.FrameBand,
) void {
    if (paint_plan.paintedBandChange(plan.*, previous)) |band| {
        invalidateBand(plan, .owned_band_change, band);
    }
}

fn invalidateBand(
    plan: *paint_plan.PaintPlan,
    reason: paint_plan.FrameInvalidationReason,
    band: paint_plan.FrameBand,
) void {
    if (band.isEmpty()) return;
    appendFrameInvalidation(plan, .{
        .reason = reason,
        .top = band.top,
        .bottom = band.bottom,
    });
    plan.footer_clean_allowed = false;
}

fn appendFrameInvalidation(plan: *paint_plan.PaintPlan, range: paint_plan.FrameInvalidationRange) void {
    if (plan.invalidation.appendOrCollapse(range)) |collapsed| {
        debug_trace.logf(
            "frame_plan",
            "build_invalidation_collapse incoming_reason={s} collapsed_reason={s} top={d} bottom={d}",
            .{ @tagName(range.reason), @tagName(collapsed.reason), collapsed.top, collapsed.bottom },
        );
    }
}

const TestShell = struct {
    shadow: vt_emulator.Grid,
    shadow_vt: ?*vt_emulator.Grid,
    history_reset_uses_ris: bool = false,
    recorded_invalidations: paint_plan.FrameInvalidationSet = paint_plan.FrameInvalidationSet.empty(),
    has_committed_frame: bool = false,
    committed_frame_layout: frame_layout.CommittedLayoutSnapshot = .{},
    sink: terminal_diff.FrameSink,

    fn init(alloc: Allocator, sink: terminal_diff.FrameSink) !TestShell {
        var shadow = try vt_emulator.Grid.init(alloc, 8, 4);
        errdefer shadow.deinit();
        return .{
            .shadow = shadow,
            .shadow_vt = undefined,
            .sink = sink,
        };
    }

    fn bind(self: *TestShell) void {
        self.shadow_vt = &self.shadow;
    }

    fn deinit(self: *TestShell) void {
        self.shadow.deinit();
    }

    fn frameSink(self: *TestShell) terminal_diff.FrameSink {
        return self.sink;
    }

    fn recordFrameInvalidation(self: *TestShell, range: paint_plan.FrameInvalidationRange) !void {
        try self.recorded_invalidations.append(range);
    }

    fn takeRecordedInvalidations(self: *TestShell) paint_plan.FrameInvalidationSet {
        const recorded = self.recorded_invalidations;
        self.recorded_invalidations = paint_plan.FrameInvalidationSet.empty();
        return recorded;
    }
};

fn testScrollPlan(rows: u16) frame_scroll_plan.FrameScrollPlan {
    return frame_scroll_plan.merge(4, 1, 0, rows);
}

fn testPlan() paint_plan.PaintPlan {
    return .{
        .layout = .{
            .rows = 4,
            .cols = 8,
            .content_bottom = 2,
            .divider_top_row = 3,
            .input_row = 3,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 2,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 2,
        },
        .footer = .{
            .top = 3,
            .top_divider = 3,
            .banner = 3,
            .banner_active = false,
            .input_base = 3,
            .picker_divider = 3,
            .picker_start = 4,
            .bottom_divider = 3,
            .hint = 4,
            .total_rows = 2,
        },
        .activity = .{ .transient_row = .{ .row = 1, .gap_above_rows = 0 } },
        .preserved_band = paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{ .top = 2, .bottom = 2, .owner = .transcript },
        .activity_band = .{ .top = 1, .bottom = 1, .owner = .activity },
        .footer_band = .{ .top = 3, .bottom = 4, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = false,
        .cursor_target = .{ .row = 3, .col = 1, .visible = true },
        .footer_reservation_source = .footer_layout,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

const PaintCtx = struct {
    text: []const u8,
    owner: paint_plan.CellOwner,
    row: u16,

    fn painter(ctx: *anyopaque, surface: *frame_surface.FrameSurface) anyerror!void {
        const self: *PaintCtx = @ptrCast(@alignCast(ctx));
        _ = try surface.writeAnsiBand(self.row, 1, self.text, self.owner, .same_owner);
    }
};
