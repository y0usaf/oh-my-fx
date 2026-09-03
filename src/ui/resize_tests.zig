//! Grid-level resize tests that replay `TranscriptRuntime` output through
//! `vt_emulator.Grid` without a TTY or signals.

const std = @import("std");

const question_prompt = @import("../core/agent/question_prompt.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const display_width = @import("../core/shared/display_width.zig");
const diff_mod = @import("../core/output/diff.zig");
const io_mod = @import("../core/shared/io.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const usage_report = @import("../core/session/usage_report.zig");
const workspace_access = @import("../core/workspace/workspace_access.zig");
const types = @import("../core/shared/types.zig");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const builtin_commands = @import("../builtins/commands.zig");

const surface_frame = @import("footer/surface_frame.zig");
const surface_invalidation = @import("footer/surface_invalidation.zig");
const interaction_state = @import("footer/interaction_state.zig");
const approval_prompt = @import("../core/permissions/approval_prompt.zig");
const render_input = @import("footer/render_input.zig");
const footer_viewport = @import("footer/viewport.zig");
const activity_runtime = @import("../core/output/activity_runtime.zig");
const core_input_runtime = @import("../core/input/runtime.zig");
const ui_render = @import("render.zig");
const render_engine = @import("render_engine.zig");
const render_request = @import("render_request.zig");
const shell_runtime = @import("shell_runtime.zig");
const shimmer_runtime = @import("transcript/shimmer_runtime.zig");
const transcript_painter = @import("transcript/painter.zig");
const transcript_runtime = @import("transcript/runtime.zig");
const full_transcript_screen = @import("full_transcript_screen.zig");
const vt_emulator = @import("../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const TranscriptPreparationSource = transcript_runtime.TranscriptPreparationSource;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const Grid = vt_emulator.Grid;
const InputRuntime = core_input_runtime.Runtime;

const TestBodyDisposition = enum {
    paint,
    retain,
};

const TestFrameObservation = struct {
    shadow_state: render_engine.terminal_diff.ShadowCommitState = .committed,
    body_disposition: TestBodyDisposition = .paint,
    body_paints: usize = 0,
    retained_transcript_changed_cells: usize = 0,
    document_append_bytes: usize = 0,
    document_append_clear_rows: ?u16 = null,
    transcript_history_floor_respected: bool = true,
    planned_scroll_rows: u16 = 0,
    committed_scroll_rows: u16 = 0,
    unplanned_scroll_rows: u16 = 0,
    changed_cells: usize = 0,
};

/// Test harness that captures every byte `TranscriptRuntime` emits and
/// replays it through a virtual terminal.
pub const Harness = struct {
    alloc: Allocator,
    tmp: std.testing.TmpDir,
    file: std.Io.File,
    path: []u8,
    read_offset: u64 = 0,
    vt: Grid,
    shell: TranscriptRuntime,
    metrics: Metrics = .{},
    frame_redraw: bool = false,
    last_frame: TestFrameObservation = .{},

    pub fn init(alloc: Allocator, cols: u16, rows: u16, footer_rows: u16) !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const filename = "ansi.log";
        var file = try tmp.dir.createFile(std.testing.io, filename, .{ .read = true });
        errdefer file.close(io_mod.getIo());

        const path = try alloc.dupe(u8, filename);
        errdefer alloc.free(path);

        const layout = layoutFor(cols, rows, footer_rows);

        var harness: Harness = .{
            .alloc = alloc,
            .tmp = tmp,
            .file = file,
            .path = path,
            .vt = try Grid.init(alloc, cols, rows),
            .shell = .{
                .stdout_file = file,
                .layout = layout,
            },
        };
        harness.vt.cursor_row = layout.content_bottom;
        harness.vt.cursor_col = 1;
        try harness.shell.initBacking(alloc);
        try harness.shell.enableShadowVt(alloc);
        return harness;
    }

    pub fn deinit(self: *Harness) void {
        self.shell.deinit(self.alloc);
        self.file.close(io_mod.getIo());
        self.tmp.cleanup();
        self.alloc.free(self.path);
        self.vt.deinit();
    }

    /// Pull any bytes written since the last flush into the VT grid.
    pub fn flush(self: *Harness) !void {
        const total = try self.file.length(io_mod.getIo());
        if (total <= self.read_offset) return;
        const want: usize = @intCast(total - self.read_offset);
        const buf = try self.alloc.alloc(u8, want);
        defer self.alloc.free(buf);
        const n = try self.file.readPositionalAll(io_mod.getIo(), buf, self.read_offset);
        try self.vt.feed(buf[0..n]);
        self.read_offset += n;
    }

    pub fn driveResize(self: *Harness, cols: u16, rows: u16, footer_rows: u16, settled: bool) !void {
        const new_layout = layoutFor(cols, rows, footer_rows);
        try self.vt.resize(cols, rows);
        try shell_runtime.applyResizeWithLayout(
            &self.shell,
            &self.metrics,
            new_layout,
            settled,
        );
        try self.renderTranscriptFrameIfDirty();
        try self.flush();
    }

    pub fn renderTranscriptFrame(self: *Harness) !void {
        try self.renderTranscriptFrameWithOptions(0, null);
    }

    pub fn renderTranscriptFrameOmittingEntry(self: *Harness, entry_id: u32) !void {
        try self.renderTranscriptFrameWithOptions(0, entry_id);
    }

    pub fn renderTranscriptFrameIfDirty(self: *Harness) !void {
        if (!self.shell.transcript_band_dirty and !self.shell.render_requests.hasPending()) return;
        try self.renderTranscriptFrame();
    }

    pub fn initStartupViewport(self: *Harness, requested_start_row: u16, min_body_rows: u16) !void {
        const reserve_rows = @min(min_body_rows, self.shell.layout.content_bottom);
        const max_start_row = if (reserve_rows > 0)
            self.shell.layout.content_bottom - reserve_rows + 1
        else
            self.shell.layout.content_bottom;
        if (requested_start_row > max_start_row) {
            var cursor_buf: [32]u8 = undefined;
            const cursor = try std.fmt.bufPrint(&cursor_buf, "\x1b[{d};1H", .{self.shell.layout.rows});
            try self.file.writeStreamingAll(io_mod.getIo(), cursor);
            var row: u16 = 0;
            while (row < requested_start_row - max_start_row) : (row += 1) {
                try self.file.writeStreamingAll(io_mod.getIo(), "\n");
            }
        }
        try self.shell.initViewportWithReservedRows(&self.metrics, requested_start_row, min_body_rows);
    }

    pub fn renderTranscriptFrameWithBottomReservation(self: *Harness, bottom_reserved_rows: u16) !void {
        try self.renderTranscriptFrameWithOptions(bottom_reserved_rows, null);
    }

    fn renderTranscriptFrameWithOptions(
        self: *Harness,
        bottom_reserved_rows: u16,
        omitted_entry_id: ?u32,
    ) !void {
        if (!self.shell.render_requests.hasPending()) self.shell.render_requests.request(.transcript);
        var attempt = (try self.shell.render_requests.beginAttempt()).?;
        defer attempt.deinit();
        const snapshot = attempt.snapshot;
        var source = if (self.shell.fullTranscriptActive())
            try self.prepareFullTranscriptSource()
        else if (omitted_entry_id) |entry_id|
            try self.shell.prepareTranscriptSourceOmittingEntry(self.alloc, entry_id)
        else
            try self.shell.prepareTranscriptSource(self.alloc, null);
        defer source.deinit(self.alloc);
        const reserved_rows = @min(bottom_reserved_rows, self.shell.layout.content_bottom -| 1);
        const footer_height = self.shell.layout.rows - self.shell.layout.divider_top_row + 1;
        var prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
        defer if (prepared) |*paint| paint.deinit(self.alloc);
        var fixed_point_ctx = ReservedTranscriptSolveContext{
            .h = self,
            .source = &source,
            .prepared = &prepared,
            .reserved_rows = reserved_rows,
        };
        const fixed_point = try render_engine.frame_fixed_point.solve(
            ReservedTranscriptSolveContext,
            &fixed_point_ctx,
            .{
                .terminal = self.shell.layout,
                .owned_top = self.shell.owned_top_row,
                .footer = .{
                    .natural_rows = footer_height +| reserved_rows,
                    .min_rows = footer_height +| reserved_rows,
                    .max_rows = footer_height +| reserved_rows,
                },
                .transcript = source.preview,
                .prior = self.shell.committed_frame_layout,
            },
            ReservedTranscriptSolveContext.prepareCandidate,
            ReservedTranscriptSolveContext.resolveCandidate,
        );

        var invalidations = snapshot.invalidations;
        self.shell.normalizeFrameInvalidations(&invalidations);
        const paint = &prepared.?;
        var plan = transcriptOnlyPlan(&self.shell, paint, fixed_point.layout.owned_top, invalidations);
        var transition = try resolveAndSealTranscriptTransitionForTest(
            &self.shell,
            self.alloc,
            &source,
            paint,
            &plan,
            fixed_point.scroll_plan,
        );
        defer transition.deinit(self.alloc);
        var paint_ctx = TestFramePaintContext{
            .h = self,
            .prepared = paint,
        };
        const result = try commitTestFrame(
            self,
            plan,
            paint,
            null,
            null,
            fixed_point.scroll_plan,
            &transition,
            &paint_ctx,
        );
        if (result == .committed) {
            attempt.commit(0, render_request.animation_interval_ms, false);
        } else {
            attempt.restore();
        }
    }

    pub fn renderFooterFrame(
        self: *Harness,
        approval: *const approval_prompt.ApprovalPrompt,
        force_redraw: *bool,
        ctx: render_input.RenderContext,
    ) !void {
        if (!self.shell.render_requests.hasPending()) self.shell.render_requests.request(.footer);
        var attempt = (try self.shell.render_requests.beginAttempt()).?;
        defer attempt.deinit();
        const snapshot = attempt.snapshot;
        var invalidations = snapshot.invalidations;
        self.shell.normalizeFrameInvalidations(&invalidations);
        var measurement = try surface_frame.measureSurfaceFooter(self.alloc, &self.shell, approval.projection(), ctx);
        defer measurement.deinit(self.alloc);
        const footer_reservation_changed = measurement.changesFooterReservation(&self.shell);
        const replay_displaced_footer_history =
            measurement.replaysDisplacedTranscriptHistory(&self.shell);
        var prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
        defer if (prepared) |*paint| paint.deinit(self.alloc);
        var resolved_target: ?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget = null;
        const activity = frameActivityState(self, &measurement);
        const tracked_entry_id = switch (measurement.activity_projection) {
            .tool_slot => |slot| slot.entry_id,
            .none, .turn_thinking => null,
        };
        const omitted_entry_id = switch (measurement.activity_projection) {
            .tool_slot => |slot| if (slot.thinking_label != null) slot.entry_id else null,
            .none, .turn_thinking => null,
        };
        var source = if (self.shell.fullTranscriptActive())
            try self.prepareFullTranscriptSource()
        else if (omitted_entry_id) |entry_id|
            try self.shell.prepareTranscriptSourceOmittingEntry(self.alloc, entry_id)
        else
            try self.shell.prepareTranscriptSource(self.alloc, tracked_entry_id);
        defer source.deinit(self.alloc);
        const fixed_point = try solveTestFrame(
            self,
            &measurement,
            activity,
            &source,
            &prepared,
            &resolved_target,
            footer_reservation_changed,
            replay_displaced_footer_history,
            invalidations,
        );

        const footer_rows = measurement.frameLayoutRows(self.shell.layout.rows, fixed_point.layout.footer_area.top);
        const activity_placement = render_engine.activity_placement.resolve(
            measurement.activity_projection,
            activity,
            fixed_point.layout,
        );
        const activity_hides_cursor = switch (activity_placement) {
            .transient_row => true,
            .none, .overlay_entry => false,
        };
        const viewport = if (resolved_target) |target|
            target.selection()
        else if (prepared) |*paint|
            paint.selection
        else
            surface_frame.currentSurfaceFooterTranscriptState(&self.shell).selection;
        const cursor_target = if (resolved_target) |target|
            render_engine.paint_plan.FrameCursorTarget{
                .row = target.cursorRow(),
                .col = target.cursorCol(),
                .visible = !activity_hides_cursor,
            }
        else if (prepared) |*paint|
            render_engine.paint_plan.FrameCursorTarget{
                .row = paint.cursor.cursor_row,
                .col = paint.cursor.cursor_col,
                .visible = !activity_hides_cursor,
            }
        else
            render_engine.paint_plan.FrameCursorTarget{
                .row = footer_rows.input_base,
                .col = 1,
                .visible = !activity_hides_cursor,
            };
        const plan = fixed_point.layout.toPaintPlan(.{
            .footer_rows = footer_rows,
            .viewport = viewport,
            .activity = activity_placement,
            .cursor_target = cursor_target,
            .reset_terminal = self.shell.terminal_reset_pending,
            .preserve_scrollback = !self.shell.pending_scroll_compact,
        });
        var footer_frame = try surface_frame.prepareMeasuredSurfaceFooterFrameForPlan(
            self.alloc,
            &self.shell,
            force_redraw,
            approval.projection(),
            ctx,
            &measurement,
            plan,
            invalidations,
        );
        defer footer_frame.deinit(self.alloc);
        var transition: ?transcript_runtime.TranscriptTransition = null;
        defer if (transition) |*value| value.deinit(self.alloc);
        if (prepared) |*paint| {
            const target = resolved_target orelse return error.MissingResolvedTranscriptTarget;
            transition = try self.shell.sealTranscriptTransition(
                self.alloc,
                &source,
                paint,
                &footer_frame.paint,
                target,
            );
        }

        var paint_ctx = TestFramePaintContext{
            .h = self,
            .prepared = if (prepared) |*paint| paint else null,
            .footer_frame = &footer_frame,
        };
        const result = try commitTestFrame(
            self,
            footer_frame.paint,
            if (prepared) |*paint| paint else null,
            &footer_frame,
            &measurement,
            fixed_point.scroll_plan,
            if (transition) |*value| value else null,
            &paint_ctx,
        );
        if (result == .committed) {
            attempt.commit(0, render_request.animation_interval_ms, paint_ctx.activity_result.painted);
            force_redraw.* = false;
        } else {
            attempt.restore();
        }
    }

    fn prepareFullTranscriptSource(self: *Harness) !TranscriptPreparationSource {
        var projection = try full_transcript_screen.buildProjection(
            self.alloc,
            self.shell.entries.items,
            self.shell.tool_details.items,
            self.shell.command_output_blocks.items,
            self.shell.command_output_render.styles,
            self.shell.layout.cols,
            self.shell.fullTranscriptAnchorEntryId(),
        );
        defer projection.deinit(self.alloc);
        const measurement = try full_transcript_screen.measureProjectionInterruptible(
            self.alloc,
            &projection,
            null,
            self.shell.layout.cols,
            null,
        );
        const visible_rows: u16 = @intCast(@max(@min(measurement.total_rows, std.math.maxInt(u16)), 1));
        const bytes = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
            self.alloc,
            &projection,
            null,
            self.shell.layout.cols,
            visible_rows,
            0,
            null,
        );
        return self.shell.prepareFullTranscriptViewportSource(self.alloc, bytes);
    }
};

const ReservedTranscriptSolveContext = struct {
    h: *Harness,
    source: *const TranscriptPreparationSource,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
    reserved_rows: u16,

    fn prepareCandidate(
        self: *ReservedTranscriptSolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
    ) !render_engine.frame_fixed_point.CandidatePreparation {
        if (self.prepared.*) |*paint| {
            paint.deinit(self.h.alloc);
            self.prepared.* = null;
        }
        const target_bottom = self.h.shell.layout.content_bottom - self.reserved_rows;
        if (target_bottom < candidate.owned_top) return error.InvalidFrameScrollPlan;
        self.prepared.* = try self.h.shell.prepareTranscriptSurfacePaintFromSourceForArea(
            self.h.alloc,
            &self.h.metrics,
            self.source,
            .{ .top = candidate.owned_top, .bottom = target_bottom },
        );
        self.prepared.*.?.bottom_reserved_rows = self.reserved_rows;
        return .{
            .inline_advance_rows = self.h.shell.planTranscriptScroll(&self.prepared.*.?).planned_rows,
            .occupied_transcript_rows = candidate.transcript_area.height(),
        };
    }

    fn resolveCandidate(
        self: *ReservedTranscriptSolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    ) !render_engine.frame_fixed_point.CandidateResolution {
        _ = self;
        _ = scroll_plan;
        return .{ .occupied_transcript_rows = candidate.transcript_area.height() };
    }
};

fn solveTestFrame(
    h: *Harness,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
    activity: render_engine.frame_layout.ActivityState,
    source: *const TranscriptPreparationSource,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
    resolved_target: *?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget,
    footer_reservation_changed: bool,
    replay_displaced_footer_history: bool,
    attempt_invalidations: render_engine.paint_plan.FrameInvalidationSet,
) !render_engine.frame_fixed_point.FramePlan {
    var ctx = TestFrameSolveContext{
        .h = h,
        .source = source,
        .prepared = prepared,
        .resolved_target = resolved_target,
        .measurement = measurement,
        .activity = activity,
        .footer_reservation_changed = footer_reservation_changed,
        .replay_displaced_footer_history = replay_displaced_footer_history,
        .attempt_invalidations = attempt_invalidations,
    };
    return render_engine.frame_fixed_point.solve(
        TestFrameSolveContext,
        &ctx,
        .{
            .terminal = h.shell.layout,
            .owned_top = h.shell.owned_top_row,
            .footer = measurement.frameLayoutMeasurement(),
            .transcript = source.preview,
            .activity = activity,
            .prior = h.shell.committed_frame_layout,
        },
        TestFrameSolveContext.prepareCandidate,
        TestFrameSolveContext.resolveCandidate,
    );
}

const TestFrameSolveContext = struct {
    h: *Harness,
    source: *const TranscriptPreparationSource,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
    resolved_target: *?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
    activity: render_engine.frame_layout.ActivityState,
    footer_reservation_changed: bool,
    replay_displaced_footer_history: bool,
    attempt_invalidations: render_engine.paint_plan.FrameInvalidationSet,
    scroll_facts: ?transcript_runtime.TranscriptScrollFacts = null,

    fn prepareCandidate(
        self: *TestFrameSolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
    ) !render_engine.frame_fixed_point.CandidatePreparation {
        if (self.prepared.*) |*paint| {
            paint.deinit(self.h.alloc);
            self.prepared.* = null;
        }
        self.resolved_target.* = null;
        self.scroll_facts = null;
        var inline_advance_rows: u16 = 0;
        var occupied_transcript_rows = candidate.transcript_area.height();
        if (!candidate.transcript_area.isEmpty()) {
            self.prepared.* = try self.h.shell.prepareTranscriptSurfacePaintFromSourceForFrame(
                self.h.alloc,
                &self.h.metrics,
                self.source,
                candidate.transcript_area,
                self.footer_reservation_changed,
            );
            const scroll_facts = try self.h.shell.prepareTranscriptScrollFactsForFrame(
                self.h.alloc,
                self.source,
                &self.prepared.*.?,
                self.footer_reservation_changed,
                self.replay_displaced_footer_history,
            );
            self.scroll_facts = scroll_facts;
            inline_advance_rows = scroll_facts.planned_rows;
            if (self.prepared.*.?.selection.last_visible_row >= candidate.transcript_area.top) {
                occupied_transcript_rows = self.prepared.*.?.selection.last_visible_row - candidate.transcript_area.top + 1;
            } else {
                occupied_transcript_rows = 0;
            }
        }
        return .{
            .inline_advance_rows = inline_advance_rows,
            .occupied_transcript_rows = occupied_transcript_rows,
        };
    }

    fn resolveCandidate(
        self: *TestFrameSolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    ) !render_engine.frame_fixed_point.CandidateResolution {
        if (candidate.transcript_area.isEmpty()) {
            return .{ .occupied_transcript_rows = 0 };
        }
        const prepared = if (self.prepared.*) |*value| value else return error.MissingTranscriptPaint;
        const scroll_facts = self.scroll_facts orelse return error.MissingTranscriptScrollFacts;
        const activity = render_engine.activity_placement.resolve(
            self.measurement.activity_projection,
            self.activity,
            candidate,
        );
        var candidate_plan = candidate.toPaintPlan(.{
            .footer_rows = self.measurement.frameLayoutRows(
                self.h.shell.layout.rows,
                candidate.footer_area.top,
            ),
            .viewport = prepared.selection,
            .activity = activity,
            .cursor_target = .{
                .row = prepared.cursor.cursor_row,
                .col = prepared.cursor.cursor_col,
                .visible = true,
            },
        });
        candidate_plan.invalidation = try surface_invalidation.resolveCandidateFrameInvalidations(
            &self.h.shell,
            candidate_plan,
            self.measurement.frameInvalidationUpdate(),
            self.attempt_invalidations,
        );
        const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
            self.h.shell.committed_frame_layout.transcript_area,
            candidate_plan.invalidation,
        );
        const target = try self.h.shell.resolveTranscriptTransitionTargetForFrame(
            self.h.alloc,
            self.source,
            prepared,
            render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(candidate),
            scroll_plan,
            scroll_facts,
            destructive_invalidation,
            activity == .overlay_entry,
        );
        self.resolved_target.* = target;
        return .{ .occupied_transcript_rows = target.occupiedTranscriptRows() };
    }
};

fn frameActivityState(
    h: *const Harness,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
) render_engine.frame_layout.ActivityState {
    return switch (measurement.activity_projection) {
        .none => .none,
        .tool_slot => |slot| if (slot.active)
            transientActivityState(h, measurement.activity_projection, slot.thinking_label != null)
        else
            .none,
        .turn_thinking => transientActivityState(h, measurement.activity_projection, false),
    };
}

fn transientActivityState(
    h: *const Harness,
    projection: activity_runtime.ActivityProjection,
    tool_before_activity: bool,
) render_engine.frame_layout.ActivityState {
    return .{ .thinking = .{
        .gap_above_activity = h.shell.transientAssistantGapRows(),
        .activity_rows = render_input.activityProjectionRows(projection, h.shell.layout.cols),
        .footer_gap_after_activity = render_engine.transcript_blocks.footerBoundaryGapRowsForTail(.turn_summary),
        .tool_before_activity = tool_before_activity,
    } };
}

const TestFramePaintContext = struct {
    h: *Harness,
    prepared: ?*const transcript_painter.PreparedTranscriptSurfacePaint,
    footer_frame: ?*const surface_frame.SurfaceFooterFrame = null,
    activity_result: render_engine.paint_plan.ActivityPaintResult = .{
        .painted = false,
        .row = 0,
        .overlay = false,
    },

    fn paintBody(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *TestFramePaintContext = @ptrCast(@alignCast(ctx));
        if (surface.plan.transcript_band.isEmpty()) return;
        const prepared = self.prepared orelse return;
        _ = try self.h.shell.paintPreparedTranscriptIntoSurface(self.h.alloc, surface, prepared);
    }

    fn paintFooter(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *TestFramePaintContext = @ptrCast(@alignCast(ctx));
        const frame = self.footer_frame orelse return;
        _ = try footer_viewport.paintFooterIntoSurface(surface, &frame.composed);
    }

    fn paintActivity(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *TestFramePaintContext = @ptrCast(@alignCast(ctx));
        const frame = self.footer_frame orelse return;
        self.activity_result = try shimmer_runtime.paintActivityIntoSurface(surface, .{
            .label = frame.label(),
            .tool_label = frame.toolLabel(),
            .shimmer_pos = frame.shimmer_pos,
        });
    }
};

fn commitTestFrame(
    h: *Harness,
    plan: render_engine.paint_plan.PaintPlan,
    prepared: ?*const transcript_painter.PreparedTranscriptSurfacePaint,
    footer_frame: ?*surface_frame.SurfaceFooterFrame,
    footer_measurement: ?*const surface_frame.SurfaceFooterMeasurement,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    transition: ?*transcript_runtime.TranscriptTransition,
    paint_ctx: *TestFramePaintContext,
) !render_engine.terminal_diff.ShadowCommitState {
    if (prepared != null and transition == null) return error.MissingTranscriptTransition;
    const document_append = if (transition) |value|
        value.document_append
    else
        render_engine.frame_scroll_plan.FrameDocumentAppend{};
    const transcript_body: render_engine.frame_builder.TranscriptBodyDisposition =
        if (transition) |value| switch (value.body_disposition) {
            .paint => .paint,
            .retain_committed => |retained| .{ .retain = retained },
        } else .paint;
    const body_disposition: TestBodyDisposition = switch (transcript_body) {
        .paint => .paint,
        .retain => .retain,
    };
    const resize_commit =
        shell_runtime.pendingResizeFrameCommit(&h.shell, false);
    var counters: render_engine.frame_builder.TraceCounters = .{};
    const result = try render_engine.frame_builder.buildAndFlushFrame(
        h.alloc,
        &h.shell,
        &h.metrics,
        .{
            .plan = plan,
            .body = .transcript,
            .transcript_body = transcript_body,
            .scroll_plan = scroll_plan,
            .document_append = document_append,
            .body_painter = .{ .ctx = paint_ctx, .paint = TestFramePaintContext.paintBody },
            .footer_painter = if (footer_frame != null)
                .{ .ctx = paint_ctx, .paint = TestFramePaintContext.paintFooter }
            else
                null,
            .activity_painter = if (footer_frame != null)
                .{ .ctx = paint_ctx, .paint = TestFramePaintContext.paintActivity }
            else
                null,
            .trace_counters = &counters,
        },
    );
    h.last_frame = .{
        .shadow_state = result.state(),
        .body_disposition = body_disposition,
        .body_paints = counters.body_paints,
        .retained_transcript_changed_cells = counters.retained_transcript_changed_cells,
        .document_append_bytes = document_append.bytes.len,
        .document_append_clear_rows = switch (document_append.clear) {
            .remainder => null,
            .rows => |rows| rows,
        },
        .transcript_history_floor_respected = if (transition) |value|
            value.visual_offset >= value.history_visual_offset
        else
            true,
        .planned_scroll_rows = scroll_plan.terminal_scroll_rows,
        .committed_scroll_rows = result.terminal_scroll_rows_applied(),
        .unplanned_scroll_rows = result.scrollCommit(scroll_plan).unplanned_terminal_scroll_rows,
        .changed_cells = result.changed_cells,
    };

    h.shell.consumeFrameScrollCommit(h.alloc, scroll_plan, result, transition);
    if (result.is_committed()) {
        h.shell.has_committed_frame = true;
        h.shell.terminal_reset_pending = false;
        shell_runtime.acknowledgeResizeFrameCommit(&h.shell, resize_commit);
        if (transition == null) {
            h.shell.committed_frame_layout =
                render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
            h.shell.invalidateTranscriptAnchor("empty_test_frame_transcript");
        }
        if (footer_frame) |frame| {
            surface_frame.commitSurfaceFooterFrame(h.alloc, &h.shell, frame, footer_measurement);
        }
        h.shell.shimmer_active = paint_ctx.activity_result.painted;
        h.shell.shimmer_row = if (paint_ctx.activity_result.painted) paint_ctx.activity_result.row else 1;
        h.shell.shimmer_is_overlay = paint_ctx.activity_result.overlay;
        if (paint_ctx.activity_result.overlay) {
            h.shell.invalidateTranscriptAnchor("test_transcript_activity_overlay_commit");
        }
        h.shell.transcript_band_dirty = false;
        h.shell.footer_viewport.clearExternalInvalidation();
    }
    return result.state();
}

fn transcriptOnlyPlan(
    shell: *TranscriptRuntime,
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    target_owned_top: u16,
    invalidation: render_engine.paint_plan.FrameInvalidationSet,
) render_engine.paint_plan.PaintPlan {
    const selection = prepared.selection;
    const preserved_band = if (target_owned_top > 1)
        render_engine.paint_plan.FrameBand{
            .top = 1,
            .bottom = target_owned_top - 1,
            .owner = .preserved_shell,
        }
    else
        render_engine.paint_plan.FrameBand.empty(.preserved_shell);
    const blank_band = if (selection.top_row > target_owned_top)
        render_engine.paint_plan.FrameBand{
            .top = target_owned_top,
            .bottom = selection.top_row - 1,
            .owner = .gap,
        }
    else
        render_engine.paint_plan.FrameBand.empty(.gap);
    const footer_gap_band = if (selection.bottom_row + 1 < shell.layout.divider_top_row)
        render_engine.paint_plan.FrameBand{
            .top = selection.bottom_row + 1,
            .bottom = shell.layout.divider_top_row - 1,
            .owner = .gap,
        }
    else
        render_engine.paint_plan.FrameBand.empty(.gap);
    return .{
        .layout = shell.layout,
        .viewport = selection,
        .footer = footerRowsForLayout(shell.layout),
        .activity = .none,
        .preserved_band = preserved_band,
        .transcript_band = .{
            .top = selection.top_row,
            .bottom = selection.bottom_row,
            .owner = .transcript,
        },
        .blank_band = blank_band,
        .activity_band = render_engine.paint_plan.FrameBand.empty(.activity),
        .footer_gap_band = footer_gap_band,
        .footer_band = .{
            .top = shell.layout.divider_top_row,
            .bottom = shell.layout.rows,
            .owner = .footer,
        },
        .invalidation = invalidation,
        .footer_clean_allowed = invalidation.isEmpty(),
        .synchronized_update = true,
        .cursor_target = .{
            .row = prepared.cursor.cursor_row,
            .col = prepared.cursor.cursor_col,
            .visible = true,
        },
        .footer_reservation_source = .none,
        .bottom_reserved_rows = prepared.bottom_reserved_rows,
        .preserve_scrollback = !shell.pending_scroll_compact,
        .reset_terminal = shell.terminal_reset_pending,
    };
}

fn resolveAndSealTranscriptTransitionForTest(
    shell: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    plan: *render_engine.paint_plan.PaintPlan,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
) !transcript_runtime.TranscriptTransition {
    const scroll_facts = try shell.prepareTranscriptScrollFactsForFrame(
        alloc,
        source,
        prepared,
        false,
        false,
    );
    const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
        shell.committed_frame_layout.transcript_area,
        plan.invalidation,
    );
    const resolved = try shell.resolveTranscriptTransitionTargetForFrame(
        alloc,
        source,
        prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan.*),
        scroll_plan,
        scroll_facts,
        destructive_invalidation,
        plan.activity == .overlay_entry,
    );
    resolved.applyToPaintPlan(plan);
    return shell.sealTranscriptTransition(
        alloc,
        source,
        prepared,
        plan,
        resolved,
    );
}

fn footerRowsForLayout(layout: Layout) render_engine.footer_layout.FooterRows {
    return .{
        .top = layout.divider_top_row,
        .top_divider = layout.divider_top_row,
        .banner = layout.divider_top_row,
        .banner_active = false,
        .input_base = layout.input_row,
        .picker_divider = layout.divider_bottom_row,
        .picker_start = layout.hint_row,
        .bottom_divider = layout.divider_bottom_row,
        .hint = layout.hint_row,
        .total_rows = layout.rows - layout.divider_top_row + 1,
    };
}

fn layoutFor(cols: u16, rows: u16, footer_rows: u16) Layout {
    std.debug.assert(rows > footer_rows);
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = rows - footer_rows,
        .divider_top_row = rows - 3,
        .input_row = rows - 2,
        .divider_bottom_row = rows - 1,
        .hint_row = rows,
    };
}

fn renderTestFooter(
    h: *Harness,
    input: *const InputRuntime,
    approval: *const approval_prompt.ApprovalPrompt,
    force_redraw: *bool,
) !void {
    var ctx = defaultFooterContext(input);
    ctx.transcript_depth = h.shell.transcriptPresentationDepth();
    try renderTestFooterWithContext(h, approval, force_redraw, ctx);
}

fn defaultFooterContext(input: *const InputRuntime) render_input.RenderContext {
    return .{
        .slash_registry = builtin_commands.slash_registry,
        .stream = .{},
        .has_api_key = true,
        .model = "test-model",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = input,
    };
}

fn setToolActivity(
    ctx: *render_input.RenderContext,
    entry_id: u32,
    label: []const u8,
) void {
    ctx.activity = activity_runtime.ActivityProjection{ .tool_slot = .{
        .entry_id = entry_id,
        .fallback_label = label,
        .active = true,
        .kind = .read,
    } };
}

fn appendCompletedToolStatus(h: *Harness, label: []const u8) !u32 {
    const id = types.ToolLifecycleId{ .turn_id = 1, .call_id = label };
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "test_tool",
        .activity_kind = .read,
        .arguments_json = "{}",
    } });
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = label },
    } });
    return h.shell.toolActivityRecord(id).?.entry_id;
}

fn renderTestFooterWithContext(
    h: *Harness,
    approval: *const approval_prompt.ApprovalPrompt,
    force_redraw: *bool,
    ctx: render_input.RenderContext,
) !void {
    try h.renderFooterFrame(approval, force_redraw, ctx);
}

fn expectRowPrefix(h: *Harness, row: u16, prefix: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    try h.vt.rowText(row, &buf);
    if (buf.items.len < prefix.len or !std.mem.eql(u8, buf.items[0..prefix.len], prefix)) {
        std.debug.print("row {d} did not start with '{s}': '{s}'\n", .{ row, prefix, buf.items });
        var dump_row: u16 = 1;
        while (dump_row <= h.vt.rows) : (dump_row += 1) {
            buf.clearRetainingCapacity();
            try h.vt.rowTextTrimmed(dump_row, &buf);
            if (buf.items.len > 0) {
                std.debug.print("row {d}: '{s}'\n", .{ dump_row, buf.items });
            }
        }
        return error.TestExpectedPrefix;
    }
}

fn expectGridContains(h: *Harness, needle: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var r: u16 = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(r, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) return;
    }

    std.debug.print("grid did not contain '{s}'\n", .{needle});
    r = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowTextTrimmed(r, &buf);
        if (buf.items.len > 0) {
            std.debug.print("row {d}: '{s}'\n", .{ r, buf.items });
        }
    }
    return error.TestExpectedGridText;
}

fn expectGridNotContains(h: *Harness, needle: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var r: u16 = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(r, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) {
            std.debug.print("grid unexpectedly contained '{s}' on row {d}: '{s}'\n", .{ needle, r, buf.items });
            return error.TestUnexpectedGridText;
        }
    }
}

fn countGridOccurrences(h: *Harness, needle: []const u8) !usize {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var count: usize = 0;
    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(row, &buf);
        count += std.mem.count(u8, buf.items, needle);
    }
    return count;
}

fn expectRowEmpty(h: *Harness, row: u16) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    try h.vt.rowTextTrimmed(row, &buf);
    if (buf.items.len != 0) {
        std.debug.print("expected row {d} empty, got: '{s}'\n", .{ row, buf.items });
        return error.TestExpectedEmptyRow;
    }
}

fn expectRowTrimmedEquals(h: *Harness, row: u16, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    try h.vt.rowTextTrimmed(row, &buf);
    if (!std.mem.eql(u8, buf.items, expected)) {
        std.debug.print("expected row {d} to equal '{s}', got: '{s}'\n", .{ row, expected, buf.items });
        return error.TestExpectedRowText;
    }
}

fn findRowContaining(h: *Harness, needle: []const u8) !u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(row, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) return row;
    }

    std.debug.print("grid did not contain row text '{s}'\n", .{needle});
    row = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowTextTrimmed(row, &buf);
        if (buf.items.len > 0) {
            std.debug.print("row {d}: '{s}'\n", .{ row, buf.items });
        }
    }
    return error.TestExpectedGridText;
}

fn expectMarkerBackground(h: *Harness, marker: u21, expected: vt_emulator.Color) !void {
    var count: usize = 0;
    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        var col: u16 = 1;
        while (col <= h.vt.cols) : (col += 1) {
            const cell = h.vt.cellAt(row, col) orelse continue;
            if (cell.codepoint != marker) continue;
            try std.testing.expect(cell.style.bg.eql(expected));
            count += 1;
        }
    }
    try std.testing.expect(count > 0);
}

fn findFirstDividerRowAfter(h: *Harness, after_row: u16) !u16 {
    const horizontal = "\xe2\x94\x80";
    const composer_rail = "┃";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var committed_footer_row: ?u16 = null;
    for (h.shell.footer_viewport.rows.items) |row| {
        if (row.row <= after_row) continue;
        if (std.mem.find(u8, row.text.items, horizontal) == null and
            std.mem.find(u8, row.text.items, composer_rail) == null) continue;
        committed_footer_row = @min(committed_footer_row orelse row.row, row.row);
    }
    if (committed_footer_row) |row| return row;

    var row: u16 = after_row + 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(row, &buf);
        if (std.mem.find(u8, buf.items, horizontal) != null) return row;
    }

    std.debug.print("grid did not contain footer chrome after row {d}\n", .{after_row});
    return error.TestExpectedGridText;
}

fn firstNonEmptyRows(h: *Harness, alloc: Allocator) ![]u16 {
    var rows: std.ArrayList(u16) = .empty;
    errdefer rows.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowTextTrimmed(row, &buf);
        if (buf.items.len > 0) try rows.append(alloc, row);
    }

    return rows.toOwnedSlice(alloc);
}

fn captureTrimmedGrid(h: *Harness, alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var row_buf: std.ArrayList(u8) = .empty;
    defer row_buf.deinit(alloc);

    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        row_buf.clearRetainingCapacity();
        try h.vt.rowTextTrimmed(row, &row_buf);
        try out.appendSlice(alloc, row_buf.items);
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

fn buildLargeSkillListFixture(alloc: Allocator, count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.print("Visible skills ({d}):\n", .{count});
    for (0..count) |index| {
        try out.writer.print(
            "- skill-{d:0>3}: deterministic fixed width description segment " ++
                "for transcript resize and append validation repeated three times " ++
                "without credentials or network access.\n",
            .{index},
        );
    }
    try out.writer.print("Managed installs ({d}):\n", .{count});
    for (0..count) |index| {
        try out.writer.print(
            "- managed-{d:0>3}: deterministic fixed width installation description " ++
                "for transcript resize and append validation repeated three times " ++
                "without credentials or network access.\n",
            .{index},
        );
    }
    return out.toOwnedSlice();
}

fn expectExactlyOneBlankRowBetween(h: *Harness, content_row: u16, footer_row: u16) !void {
    try std.testing.expectEqual(content_row + 2, footer_row);
    try expectRowEmpty(h, content_row + 1);
}

fn expectAtLeastOneBlankRowBetween(h: *Harness, content_row: u16, footer_row: u16) !void {
    try std.testing.expect(footer_row >= content_row + 2);
    try expectRowEmpty(h, content_row + 1);
}

fn expectOnlyBlankRowsBetween(h: *Harness, content_row: u16, next_row: u16) !void {
    try std.testing.expect(next_row >= content_row + 2);
    var row = content_row + 1;
    while (row < next_row) : (row += 1) {
        try expectRowEmpty(h, row);
    }
}

fn expectCommittedFooterContains(
    h: *const Harness,
    needle: []const u8,
) !void {
    for (h.shell.footer_viewport.rows.items) |row| {
        var plain: [8192]u8 = undefined;
        var plain_len: usize = 0;
        var index: usize = 0;
        while (index < row.text.items.len) {
            if (row.text.items[index] == 0x1b) {
                index = display_width.ansiSequenceEnd(
                    row.text.items,
                    index,
                );
                continue;
            }
            if (plain_len == plain.len) break;
            plain[plain_len] = row.text.items[index];
            plain_len += 1;
            index += 1;
        }
        if (std.mem.find(u8, plain[0..plain_len], needle) != null) {
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn expectActiveInputSurvivesResize(
    input_text: []const u8,
    target_height: u16,
    expected_pre_resize_extra: u16,
) !void {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, input_text);
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 15);
    // Tiny targets require the committed frame to own the full terminal.
    h.shell.owned_top_row = 1;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(expected_pre_resize_extra, h.shell.extra_input_rows);
    try std.testing.expect(h.shell.footer_viewport.has_frame);

    try h.vt.resize(8, target_height);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(8, target_height, 4),
        true,
    );

    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try expectGridContains(&h, "test-mod");
}

fn appendImageTurn(h: *Harness, id: usize, path: []const u8, label: []const u8) !void {
    const text = try std.fmt.allocPrint(h.alloc, "[Image #{d}] {s}", .{ id, label });
    errdefer h.alloc.free(text);
    const images = try h.alloc.alloc(types.ImageAttachment, 1);
    errdefer h.alloc.free(images);
    const image_path = try h.alloc.dupe(u8, path);
    errdefer h.alloc.free(image_path);
    const media_type = try h.alloc.dupe(u8, "image/png");
    errdefer h.alloc.free(media_type);
    images[0] = .{ .id = id, .path = image_path, .media_type = media_type };
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = text, .images = images });
}

fn applyCompletedReadForGroupFinalityResizeTest(
    h: *Harness,
    turn_id: u64,
    call_id: []const u8,
    group_id: types.ToolPresentationGroupId,
) !void {
    const id = types.ToolLifecycleId{ .turn_id = turn_id, .call_id = call_id };
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .authoritative_started = .{
        .id = id,
        .presentation_group_id = group_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Read fixed-point fixture" },
    } });
}

fn checkQueuedPromptAdmissionPreservesCommittedHistory(resize_before_cancel: bool) !void {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 124, 36, 4);
    defer h.deinit();
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(alloc);

    const response =
        "SCROLLBACK_LINE_01\nSCROLLBACK_LINE_02\nSCROLLBACK_LINE_03\n" ++
        "SCROLLBACK_LINE_04\nSCROLLBACK_LINE_05\nSCROLLBACK_LINE_06\n" ++
        "SCROLLBACK_LINE_07\nSCROLLBACK_LINE_08\nSCROLLBACK_LINE_09\n" ++
        "SCROLLBACK_LINE_10\nSCROLLBACK_LINE_11\nSCROLLBACK_LINE_12\n" ++
        "SCROLLBACK_LINE_13\nSCROLLBACK_LINE_14\nSCROLLBACK_LINE_15\n" ++
        "SCROLLBACK_LINE_16\nSCROLLBACK_LINE_17\nSCROLLBACK_LINE_18\n" ++
        "SCROLLBACK_LINE_19\nSCROLLBACK_LINE_20\nSCROLLBACK_LINE_21\n" ++
        "SCROLLBACK_LINE_22\nSCROLLBACK_LINE_23\n" ++
        "\x1b[1mSCROLLBACK_LINE_24";
    const draft = "unsent composer draft " ** 8;

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.streamAssistantChunk(alloc, &h.metrics, response);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try input.edit_state.input.appendSlice(alloc, draft);
    input.edit_state.cursor = input.edit_state.input.items.len;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(alloc, .full));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(alloc, .inline_mode));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    if (resize_before_cancel) {
        try h.driveResize(68, 18, 4, true);
        h.frame_redraw = true;
        try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
        try h.flush();
    }

    _ = try h.shell.streamAssistantChunk(
        alloc,
        &h.metrics,
        " CONTINUED\x1b[0m\n",
    );
    _ = try h.shell.appendSemanticNotice(alloc, .{
        .topic = "response",
        .tone = .cancelled,
        .body = "Interrupted by user",
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );

    _ = try h.shell.writeUserPromptCard(
        alloc,
        &h.metrics,
        .{ .text = @constCast("QUEUE_SCROLL_FIRST"), .images = &.{} },
        true,
        &.{},
    );
    if (h.shell.transcriptCommitDiagnostic().state != .stable) {
        std.debug.print(
            "queued prompt invalidated committed history resize={} diagnostic={any}\n",
            .{ resize_before_cancel, h.shell.transcriptCommitDiagnostic() },
        );
        return error.TestExpectedStableTranscript;
    }
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.last_frame.transcript_history_floor_respected);
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );
    try expectGridContains(&h, "SCROLLBACK_LINE_24");
    try expectGridContains(&h, "QUEUE_SCROLL_FIRST");
}

const approval_scrollback_transcript =
    "APPROVAL_SCROLLBACK_01\nAPPROVAL_SCROLLBACK_02\nAPPROVAL_SCROLLBACK_03\n" ++
    "APPROVAL_SCROLLBACK_04\nAPPROVAL_SCROLLBACK_05\nAPPROVAL_SCROLLBACK_06\n" ++
    "APPROVAL_SCROLLBACK_07\nAPPROVAL_SCROLLBACK_08\nAPPROVAL_SCROLLBACK_09\n" ++
    "APPROVAL_SCROLLBACK_10\nAPPROVAL_SCROLLBACK_11\nAPPROVAL_SCROLLBACK_12\n" ++
    "APPROVAL_SCROLLBACK_13\nAPPROVAL_SCROLLBACK_14\nAPPROVAL_SCROLLBACK_15\n" ++
    "APPROVAL_SCROLLBACK_16\nAPPROVAL_SCROLLBACK_17\nAPPROVAL_SCROLLBACK_18\n" ++
    "APPROVAL_SCROLLBACK_19\nAPPROVAL_SCROLLBACK_20\nAPPROVAL_SCROLLBACK_21\n" ++
    "APPROVAL_SCROLLBACK_22\nAPPROVAL_SCROLLBACK_23\nAPPROVAL_SCROLLBACK_24\n" ++
    "APPROVAL_SCROLLBACK_25\nAPPROVAL_SCROLLBACK_26\nAPPROVAL_SCROLLBACK_27\n" ++
    "APPROVAL_SCROLLBACK_28\nAPPROVAL_SCROLLBACK_29\nAPPROVAL_SCROLLBACK_30\n" ++
    "APPROVAL_SCROLLBACK_31\nAPPROVAL_SCROLLBACK_32\nAPPROVAL_SCROLLBACK_33\n" ++
    "APPROVAL_SCROLLBACK_34\nAPPROVAL_SCROLLBACK_35\nAPPROVAL_SCROLLBACK_36\n" ++
    "APPROVAL_SCROLLBACK_37\nAPPROVAL_SCROLLBACK_38\nAPPROVAL_SCROLLBACK_39\n" ++
    "APPROVAL_SCROLLBACK_40\n";

fn readEmittedSince(h: *Harness, since_offset: u64) ![]u8 {
    const total = try h.file.length(io_mod.getIo());
    const want: usize = @intCast(total - since_offset);
    const buf = try h.alloc.alloc(u8, want);
    _ = try h.file.readPositionalAll(io_mod.getIo(), buf, since_offset);
    return buf;
}

fn gridContains(grid: Grid, needle: []const u8) !void {
    var row: u16 = 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(grid.alloc);

    while (row <= grid.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) return;
    }
    return error.TestMissingMarker;
}

pub fn testReconstructiveFullTranscriptReplay() !void {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(alloc);
    for (0..60) |index| {
        try transcript.print(
            alloc,
            "REPLAY-MARKER-{d:0>3} stretches beyond the terminal viewport\n",
            .{index},
        );
    }
    try h.shell.writeTranscript(alloc, &h.metrics, transcript.items, true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expect(h.shell.last_viewport_selection.?.start_line > 0);

    const before = try h.file.length(io_mod.getIo());
    try h.vt.resize(40, 24);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(40, 24, 4),
        true,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const emitted = try readEmittedSince(&h, before);
    defer alloc.free(emitted);

    const first_marker = "REPLAY-MARKER-000";
    const middle_marker = "REPLAY-MARKER-030";
    const final_marker = "REPLAY-MARKER-059";
    const reset_idx = std.mem.find(u8, emitted, "\x1b[3J") orelse return error.TestMissingTerminalReset;
    const replay_origin_idx = std.mem.indexOfPos(
        u8,
        emitted,
        reset_idx,
        "\x1b[1;1H",
    ) orelse return error.TestMissingTopOriginReplay;
    const first_idx = std.mem.find(u8, emitted, first_marker) orelse return error.TestMissingFirstEntry;
    const middle_idx = std.mem.find(u8, emitted, middle_marker) orelse return error.TestMissingMiddleEntry;
    const final_idx = std.mem.find(u8, emitted, final_marker) orelse return error.TestMissingFinalEntry;

    // Limit uniqueness checks to the reconstructive replay, before the final-tail paint.
    const replay = emitted[first_idx .. final_idx + final_marker.len];
    try std.testing.expect(reset_idx < first_idx);
    try std.testing.expect(reset_idx < replay_origin_idx);
    try std.testing.expect(replay_origin_idx < first_idx);
    try std.testing.expect(first_idx < middle_idx);
    try std.testing.expect(middle_idx < final_idx);
    var replay_index: usize = 0;
    while (replay_index < replay.len) : (replay_index += 1) {
        if (replay[replay_index] == '\n') {
            try std.testing.expect(replay_index > 0 and replay[replay_index - 1] == '\r');
        }
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replay, first_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replay, middle_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replay, final_marker));
    try std.testing.expect(h.shell.last_viewport_selection.?.start_line > 0);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, emitted, first_marker));
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expect(h.last_frame.committed_scroll_rows > 0);
}

const CapacityWritePath = enum {
    write_transcript,
    append_replaceable,
    replace_trailing,
    entries_rebuild,
    reconstructive_paint,
};

fn prepareCapacityHarness() !Harness {
    var h = try Harness.init(std.testing.allocator, 40, 12, 4);
    h.shell.transcript.clearAndFree(h.alloc);
    h.shell.max_transcript_bytes = 8 * 1024;
    try h.shell.initBacking(h.alloc);
    return h;
}

fn assertCapacityInvariantUnderWrites(path: CapacityWritePath) !void {
    var h = try prepareCapacityHarness();
    defer h.deinit();

    const cap = h.shell.max_transcript_bytes;
    try h.shell.initViewport(&h.metrics, 5);
    try std.testing.expect(h.shell.transcript.capacity >= cap);
    const initial_capacity = h.shell.transcript.capacity;

    const chunk = "x" ** 512 ++ "\n";
    var i: usize = 0;
    while (i < cap * 10 / chunk.len) : (i += 1) {
        switch (path) {
            .write_transcript => try h.shell.writeTranscript(h.alloc, &h.metrics, chunk, true),
            .append_replaceable => _ = try h.shell.appendReplaceableTranscriptLineSilent(h.alloc, chunk),
            .replace_trailing => {
                if (i == 0) _ = try h.shell.appendReplaceableTranscriptLineSilent(h.alloc, chunk);
                _ = try h.shell.replaceTrailingTranscriptLineSilent(h.alloc, chunk);
            },
            .entries_rebuild => {
                try h.shell.writeTranscript(h.alloc, &h.metrics, chunk, true);
                try h.renderTranscriptFrameIfDirty();
            },
            .reconstructive_paint => {
                try h.shell.writeTranscript(h.alloc, &h.metrics, chunk, true);
                try h.shell.reconstructivePaint(h.alloc, &h.metrics);
                try h.flush();
            },
        }
        try std.testing.expectEqual(initial_capacity, h.shell.transcript.capacity);
        try std.testing.expect(h.shell.transcript.items.len <= cap);
    }
}

fn commandOutputStyles() transcript_runtime.Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
}

fn commandOutputAnsiStyles() transcript_runtime.Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "\x1b[0m",
        .dim_style = "\x1b[2m",
        .red_style = "\x1b[31m",
    };
}

fn expectGridOccurrenceCount(h: *Harness, needle: []const u8, expected: usize) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var count: usize = 0;
    var r: u16 = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(r, &buf);

        var offset: usize = 0;
        while (offset < buf.items.len) {
            const rel = std.mem.find(u8, buf.items[offset..], needle) orelse break;
            count += 1;
            offset += rel + needle.len;
        }
    }

    if (count != expected) {
        std.debug.print("expected '{s}' {d} time(s), found {d}\n", .{ needle, expected, count });
        return error.TestUnexpectedGridText;
    }
}
