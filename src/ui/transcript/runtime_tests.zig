const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const full_transcript_screen = @import("../full_transcript_screen.zig");
const input_visual_layout = @import("../input/visual_layout.zig");
const render_engine = @import("../render_engine.zig");
const command_output_runtime = @import("command_output_runtime.zig");
const transcript_painter = @import("painter.zig");
const transcript_runtime = @import("runtime.zig");
const transcript_store = @import("store.zig");
const transcript_writer = @import("writer.zig");
const ui_render = @import("../render.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const transcript_blocks = render_engine.transcript_blocks;
const viewport_selection = render_engine.viewport_selection;

const RawEntryClass = transcript_blocks.RawEntryClass;
const Styles = transcript_blocks.Styles;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const TranscriptPreparationSource = transcript_runtime.TranscriptPreparationSource;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const HardLineStarts = viewport_selection.HardLineStarts;
const TranscriptBuffer = viewport_selection.TranscriptBuffer;
const VisibleTranscriptLine = viewport_selection.VisibleTranscriptLine;
fn renderEntriesToBytes(alloc: Allocator, entries: []const transcript_blocks.TranscriptEntry, cols: u16) ![]u8 {
    return transcript_runtime.renderEntriesToBytes(alloc, entries, cols, .{});
}
const visualRowsForLine = transcript_blocks.visualRowsForLine;

fn resolveAndSealTranscriptTransitionForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    plan: *render_engine.paint_plan.PaintPlan,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
) !transcript_runtime.TranscriptTransition {
    const scroll_facts = try runtime.prepareTranscriptScrollFactsForFrame(
        alloc,
        source,
        prepared,
        false,
        false,
    );
    const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
        runtime.committed_frame_layout.transcript_area,
        plan.invalidation,
    );
    const resolved = try runtime.resolveTranscriptTransitionTargetForFrame(
        alloc,
        source,
        prepared,
        target_layout,
        scroll_plan,
        scroll_facts,
        destructive_invalidation,
        plan.activity == .overlay_entry,
    );
    resolved.applyToPaintPlan(plan);
    return runtime.sealTranscriptTransition(
        alloc,
        source,
        prepared,
        plan,
        resolved,
    );
}

fn resolveVisibleLineForTest(line: VisibleTranscriptLine, buf: TranscriptBuffer) []const u8 {
    return switch (line) {
        .transcript => |t| t.ref.resolve(buf),
        .folded_line => |f| f.text,
    };
}

fn commandOutputTestRuntime(sink: std.Io.File) TranscriptRuntime {
    return .{
        .stdout_file = sink,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 21,
            .divider_top_row = 22,
            .input_row = 23,
            .divider_bottom_row = 24,
            .hint_row = 22,
        },
    };
}

fn testSelection(start_line: usize) viewport_selection.ViewportSelection {
    return .{
        .top_row = 1,
        .bottom_row = 4,
        .start_line = start_line,
        .partial_skip_rows = 0,
        .line_count = 16,
    };
}

fn transcriptTestLayout(cols: u16, rows: u16, content_bottom: u16) Layout {
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = content_bottom,
        .divider_top_row = content_bottom + 1,
        .input_row = content_bottom + 2,
        .divider_bottom_row = content_bottom + 3,
        .hint_row = rows,
    };
}

fn makeLongPastePrompt(alloc: Allocator, line_count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("LONG_PASTE_FIRST_MARKER\n");
    var index: usize = 0;
    while (index < line_count) : (index += 1) {
        try out.writer.print("long-paste-line-{d}\n", .{index});
    }
    try out.writer.writeAll("LONG_PASTE_LAST_MARKER\n");
    return out.toOwnedSlice();
}

fn installStableAnchorWithOriginForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    selection: viewport_selection.ViewportSelection,
    visual_offset: u32,
    cursor_row: u16,
    cursor_col: u16,
    layout_id: u64,
    measured_history_origin: ?transcript_painter.MeasuredHistoryOrigin,
) !void {
    var target_cache: std.ArrayList(u8) = .empty;
    errdefer target_cache.deinit(alloc);
    try target_cache.appendSlice(alloc, flow);
    var transition = transcript_runtime.TranscriptTransition{
        .scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(
            runtime.layout.rows,
            runtime.owned_top_row,
        ),
        .document_append = .{},
        .materialized_without_append = .{},
        .target_flow = try alloc.dupe(u8, flow),
        .target_cache = target_cache,
        .target_cache_origin_untrimmed = runtime.transcript_cache_origin_untrimmed,
        .folded_summary_indices = &.{},
        .target_layout = .{
            .layout_id = layout_id,
            .owned_top = runtime.owned_top_row,
            .owned_band = .{ .top = runtime.owned_top_row, .bottom = runtime.layout.rows },
            .body_area = .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
            .transcript_area = .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
            .footer_area = .{ .top = runtime.layout.content_bottom + 1, .bottom = runtime.layout.rows },
            .solved_frame_height = runtime.layout.rows - runtime.owned_top_row + 1,
            .terminal_rows = runtime.layout.rows,
            .terminal_cols = runtime.layout.cols,
        },
        .selection = selection,
        .visual_offset = visual_offset,
        .history_visual_offset = visual_offset,
        .total_visual_rows = visual_offset + 64,
        .cursor_row = cursor_row,
        .cursor_col = cursor_col,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = cursor_row,
        .trace_transcript_frame = false,
        .trace_visible_rows = selection.bottom_row - selection.top_row + 1,
        .measured_history_origin = measured_history_origin,
    };
    defer transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 0,
        .changed_cells = 0,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = cursor_row,
        .committed_cursor_col = cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
}

fn installStableAnchorForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    selection: viewport_selection.ViewportSelection,
    visual_offset: u32,
    cursor_row: u16,
    cursor_col: u16,
    layout_id: u64,
) !void {
    return installStableAnchorWithOriginForTest(
        runtime,
        alloc,
        flow,
        selection,
        visual_offset,
        cursor_row,
        cursor_col,
        layout_id,
        null,
    );
}

fn stableHistoryVisualOffsetForTest(runtime: *const TranscriptRuntime) !u32 {
    return switch (runtime.transcript_commit_state) {
        .stable => |anchor| anchor.history_visual_offset,
        .invalid, .recovering => error.TestExpectedStableTranscript,
    };
}

fn expectStableNormalBufferRecoveryForTest(
    runtime: *const TranscriptRuntime,
    expected_history_visual_offset: u32,
) !void {
    switch (runtime.transcript_commit_state) {
        .stable => |anchor| {
            try std.testing.expect(anchor.normal_buffer_recovery_pending);
            try std.testing.expectEqual(
                expected_history_visual_offset,
                anchor.history_visual_offset,
            );
        },
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }
}

fn testPaintPlan(
    runtime: *const TranscriptRuntime,
    selection: viewport_selection.ViewportSelection,
) render_engine.paint_plan.PaintPlan {
    const footer_top = runtime.layout.content_bottom + 1;
    return .{
        .layout = runtime.layout,
        .viewport = selection,
        .footer = .{
            .top = footer_top,
            .top_divider = footer_top,
            .banner = footer_top,
            .banner_active = false,
            .input_base = @min(footer_top + 1, runtime.layout.rows),
            .picker_divider = @min(footer_top + 2, runtime.layout.rows),
            .picker_start = runtime.layout.rows,
            .bottom_divider = @min(footer_top + 2, runtime.layout.rows),
            .hint = runtime.layout.rows,
            .total_rows = runtime.layout.rows - footer_top + 1,
        },
        .activity = .none,
        .preserved_band = if (runtime.owned_top_row > 1)
            .{ .top = 1, .bottom = runtime.owned_top_row - 1, .owner = .preserved_shell }
        else
            render_engine.paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{
            .top = runtime.owned_top_row,
            .bottom = runtime.layout.content_bottom,
            .owner = .transcript,
        },
        .activity_band = render_engine.paint_plan.FrameBand.empty(.activity),
        .footer_band = .{
            .top = footer_top,
            .bottom = runtime.layout.rows,
            .owner = .footer,
        },
        .invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = selection.bottom_row, .col = 1, .visible = true },
        .footer_reservation_source = .none,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

const TestTranscriptFixedPointFrame = struct {
    layout: render_engine.frame_layout.FrameLayout,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
};

fn solveTestTranscriptFixedPointFrame(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    metrics: *Metrics,
    source: *const TranscriptPreparationSource,
    footer_rows: u16,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
) !TestTranscriptFixedPointFrame {
    var release_floor_rows: u16 = 0;
    var previous_candidate_owned_top: ?u16 = null;

    while (true) {
        const release = render_engine.frame_layout.solveWithPreservedRowRelease(.{
            .terminal = runtime.layout,
            .owned_top = runtime.owned_top_row,
            .footer = .{
                .natural_rows = footer_rows,
                .min_rows = footer_rows,
                .max_rows = footer_rows,
            },
            .transcript = source.preview,
            .prior = runtime.committed_frame_layout,
        }, release_floor_rows);
        const candidate = release.layout;
        if (previous_candidate_owned_top) |previous| {
            if (candidate.owned_top >= previous) return error.InvalidFrameScrollPlan;
        }

        if (prepared.*) |*paint| {
            paint.deinit(alloc);
            prepared.* = null;
        }
        var inline_advance_rows: u16 = 0;
        if (!candidate.transcript_area.isEmpty()) {
            prepared.* = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
                alloc,
                metrics,
                source,
                candidate.transcript_area,
            );
            inline_advance_rows = runtime.planTranscriptScroll(&prepared.*.?).planned_rows;
        }
        const scroll_plan = render_engine.frame_scroll_plan.merge(
            runtime.layout.rows,
            runtime.owned_top_row,
            release.released_rows,
            inline_advance_rows,
        );
        if (candidate.owned_top == scroll_plan.post_scroll_owned_top) {
            return .{
                .layout = candidate,
                .scroll_plan = scroll_plan,
            };
        }
        previous_candidate_owned_top = candidate.owned_top;
        release_floor_rows = scroll_plan.preserved_release_rows;
    }
}

fn testPaintPlanForFrame(
    layout: render_engine.frame_layout.FrameLayout,
    selection: viewport_selection.ViewportSelection,
    cursor_row: u16,
    cursor_col: u16,
) render_engine.paint_plan.PaintPlan {
    const footer_rows = render_engine.footer_layout.resolve(.{
        .footer_top_for_extra = layout.footer_area.top,
        .terminal_rows = layout.terminal.rows,
        .activity_offset = 0,
        .extra_input_rows = 0,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = false,
        .allocated_rows = layout.footer_area.height(),
    });
    return layout.toPaintPlan(.{
        .footer_rows = footer_rows,
        .viewport = selection,
        .cursor_target = .{
            .row = cursor_row,
            .col = cursor_col,
            .visible = true,
        },
    });
}

fn testSource(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
) !TranscriptPreparationSource {
    return .{
        .bytes = try alloc.dupe(u8, bytes),
        .folded_summary_indices = &.{},
        .preview = .{ .natural_visual_rows = 4 },
        .tail_kind = null,
        .tracked_entry_id = null,
        .tracked_entry_start_line = null,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 1,
        .welcome_cut_line = null,
        .welcome_boundary = null,
        .cols = cols,
    };
}

fn testFoldedSource(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
    summary_transcript_index: usize,
) !TranscriptPreparationSource {
    var source = try testSource(alloc, bytes, cols);
    errdefer source.deinit(alloc);
    source.folded_summary_indices = try alloc.dupe(
        usize,
        &.{summary_transcript_index},
    );
    return source;
}

fn testSourceWithReplaceableTail(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
    replaceable_start: usize,
) !TranscriptPreparationSource {
    var source = try testSource(alloc, bytes, cols);
    source.replaceable_last_line = true;
    source.replaceable_start = replaceable_start;
    return source;
}

fn appendFoldedLineForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    block_index: usize,
    text: []const u8,
) !void {
    const owned = try alloc.dupe(u8, text);
    errdefer alloc.free(owned);
    try runtime.folded_command_blocks.items[block_index].lines.append(alloc, .{
        .stream = .stdout,
        .text = owned,
    });
}

fn prepareTestSourceForCurrentArea(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *const TranscriptPreparationSource,
) !transcript_painter.PreparedTranscriptSurfacePaint {
    var metrics: Metrics = .{};
    return runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        source,
        .{
            .top = runtime.owned_top_row,
            .bottom = runtime.layout.content_bottom,
        },
    );
}

fn preparedVisualOffsetForTest(
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
) u32 {
    var offset: u32 = 0;
    const end = @min(
        prepared.selection.start_line,
        prepared.sourceVisualRows().len,
    );
    for (prepared.sourceVisualRows()[0..end]) |rows| offset += rows;
    return offset + prepared.selection.partial_skip_rows;
}






fn commitPreparedForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
) !void {
    const facts = runtime.planTranscriptScroll(prepared);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        source,
        prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = scroll_plan.terminal_scroll_rows,
        .document_append_committed = !transition.document_append.isEmpty(),
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
}

fn commitPreparedPartiallyForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
) !void {
    const facts = runtime.planTranscriptScroll(prepared);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        source,
        prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = transition.materialized.cursor_row,
        .committed_cursor_col = transition.materialized.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
}

fn setPreparedVisualOffsetForTest(
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    target: u32,
) !void {
    var remaining = target;
    var line_index: usize = 0;
    while (line_index < prepared.sourceVisualRows().len and
        remaining >= prepared.sourceVisualRows()[line_index]) : (line_index += 1)
    {
        remaining -= prepared.sourceVisualRows()[line_index];
    }
    if (line_index >= prepared.sourceVisualRows().len) {
        return error.TestExpectedRepresentableVisualOffset;
    }
    prepared.selection.start_line = line_index;
    prepared.selection.partial_skip_rows = @intCast(remaining);
    prepared.selection.line_count = prepared.sourceVisualRows().len;
}

const MeasuredEndpointMode = enum {
    seeded_exact,
    natural_null,
    seeded_inexact,
};

fn expectZeroReverseRestoresSourceOrigin(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    wide_source: *TranscriptPreparationSource,
    narrow_source: *TranscriptPreparationSource,
    positive_delta: i32,
    endpoint_mode: MeasuredEndpointMode,
) !void {
    var wide_prepared = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        wide_source,
    );
    defer wide_prepared.deinit(alloc);
    const source_origin = preparedVisualOffsetForTest(&wide_prepared);
    try std.testing.expect(source_origin > 0);
    try installStableAnchorForTest(
        runtime,
        alloc,
        wide_source.bytes,
        wide_prepared.selection,
        source_origin,
        wide_prepared.cursor.cursor_row,
        wide_prepared.cursor.cursor_col,
        700,
    );

    runtime.layout = transcriptTestLayout(narrow_source.cols, 8, 4);
    runtime.resize_history_row_delta = positive_delta;
    var narrow_prepared = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        narrow_source,
    );
    defer narrow_prepared.deinit(alloc);
    const natural_endpoint = if (narrow_prepared.measured_history_origin) |origin|
        origin.endpoint
    else
        null;
    if (endpoint_mode == .seeded_inexact) {
        try std.testing.expect(natural_endpoint == null);
    }
    if (endpoint_mode != .natural_null) {
        narrow_prepared.measured_history_origin = .{
            .source_cols = wide_source.cols,
            .source_visual_offset = source_origin,
            .endpoint = .{
                .span_start_flow_offset = 0,
                .flow_offset = 0,
                .hard_row_cols = wide_source.cols,
            },
        };
    }
    try std.testing.expectEqual(
        endpoint_mode != .natural_null,
        if (narrow_prepared.measured_history_origin) |origin|
            origin.endpoint != null
        else
            false,
    );
    const narrow_origin = preparedVisualOffsetForTest(&narrow_prepared);
    try std.testing.expect(narrow_origin > source_origin);
    try commitPreparedForTest(runtime, alloc, narrow_source, &narrow_prepared);
    const narrowed = runtime.stableTranscriptProjectionForFlow(
        wide_source.bytes,
    ) orelse return error.TestExpectedStableTranscript;
    const retained_origin = narrowed.measured_history_origin orelse
        return error.TestExpectedMeasuredHistoryOrigin;
    try std.testing.expectEqual(source_origin, retained_origin.source_visual_offset);
    try std.testing.expectEqual(wide_source.cols, retained_origin.source_cols);
    try std.testing.expectEqual(
        endpoint_mode != .natural_null,
        retained_origin.endpoint != null,
    );

    runtime.layout = transcriptTestLayout(wide_source.cols, 12, 8);
    runtime.resize_history_row_delta = 0;
    var restored = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        wide_source,
    );
    defer restored.deinit(alloc);
    try std.testing.expectEqual(
        source_origin,
        preparedVisualOffsetForTest(&restored),
    );
}

fn totalVisualRowsForTest(line_rows: []const u16) u32 {
    var total: u32 = 0;
    for (line_rows) |rows| total += rows;
    return total;
}


fn makeSyntheticPreparedRenderable(
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    alloc: Allocator,
) !void {
    const line_count = prepared.line_visual_rows.items.len;
    try prepared.visible_lines.ensureTotalCapacity(alloc, line_count);
    while (prepared.visible_lines.items.len < line_count) {
        prepared.visible_lines.appendAssumeCapacity(.{
            .transcript = .{
                .ref = .{
                    .ref = .{ .start = 0, .len = 0 },
                },
            },
        });
    }
    prepared.selection.line_count = line_count;
    prepared.total_lines = line_count;
}

fn enterRendererDerivedSemanticRecovery(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    attempt_content_bottom: u16,
    accepted_semantic_rows: u16,
    replaceable_start: ?usize,
) !u32 {
    var stable_source = if (replaceable_start) |start|
        try testSourceWithReplaceableTail(alloc, flow, runtime.layout.cols, start)
    else
        try testSource(alloc, flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), stable_prepared.selection.start_line);
    try std.testing.expectEqual(@as(u16, 0), stable_prepared.selection.partial_skip_rows);
    try installStableAnchorForTest(
        runtime,
        alloc,
        flow,
        stable_prepared.selection,
        0,
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        91,
    );

    runtime.layout = transcriptTestLayout(
        runtime.layout.cols,
        runtime.layout.rows,
        attempt_content_bottom,
    );
    var attempt_source = if (replaceable_start) |start|
        try testSourceWithReplaceableTail(alloc, flow, runtime.layout.cols, start)
    else
        try testSource(alloc, flow, runtime.layout.cols);
    defer attempt_source.deinit(alloc);
    var attempt_prepared = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        &attempt_source,
    );
    defer attempt_prepared.deinit(alloc);

    const attempt_facts = runtime.planTranscriptScroll(&attempt_prepared);
    try std.testing.expect(attempt_facts.semantic_rows > accepted_semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        attempt_facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, attempt_prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &attempt_source,
        &attempt_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = if (accepted_semantic_rows > 0) 1 else 0,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = accepted_semantic_rows,
        .document_append_committed = false,
        .committed_cursor_row = attempt_prepared.cursor.cursor_row,
        .committed_cursor_col = attempt_prepared.cursor.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        runtime.transcriptCommitDiagnostic().state,
    );
    return attempt_facts.target_visual_offset;
}

fn expectFinalizedRecoveryProjectionPaintsCoherently(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    plan: render_engine.paint_plan.PaintPlan,
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    transition: *const transcript_runtime.TranscriptTransition,
    expected_first_row_text: ?[]const u8,
) !void {
    var shadow = try vt_emulator.Grid.init(alloc, plan.layout.cols, plan.layout.rows);
    defer shadow.deinit();
    var surface = try render_engine.frame_surface.FrameSurface.initFromShadow(
        alloc,
        plan,
        shadow,
    );
    defer surface.deinit();

    const result = try runtime.paintPreparedTranscriptIntoSurface(
        alloc,
        &surface,
        prepared,
    );
    try std.testing.expectEqualDeep(transition.selection, surface.plan.viewport);
    try std.testing.expectEqual(
        transition.selection.last_visible_row,
        result.last_row,
    );
    try std.testing.expectEqual(
        transition.selection.replaceable_start_row,
        result.replaceable_start_row,
    );
    try std.testing.expectEqual(
        transition.cursor_row,
        surface.cursor_target.?.row,
    );
    try std.testing.expectEqual(
        transition.cursor_col,
        surface.cursor_target.?.col,
    );
    try std.testing.expectEqual(
        transition.replaceable_row,
        prepared.cursor.replaceable_row,
    );

    if (expected_first_row_text) |expected| {
        var target = try surface.copyToTargetGrid(alloc);
        defer target.deinit();
        var row_text: std.ArrayList(u8) = .empty;
        defer row_text.deinit(alloc);
        try target.rowText(plan.viewport.top_row, &row_text);
        try std.testing.expect(std.mem.startsWith(u8, row_text.items, expected));
    }
    if (transition.selection.last_visible_row_blank) {
        var col: u16 = 1;
        while (col <= surface.cols) : (col += 1) {
            const cell = surface.cellAt(
                transition.selection.last_visible_row,
                col,
            ).?;
            try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
        }
    }
}

const OwnedBandInvalidationProbe = struct {
    saw_owned_band_change: bool = false,

    fn paint(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *OwnedBandInvalidationProbe = @ptrCast(@alignCast(ctx));
        for (surface.plan.invalidation.ranges()) |range| {
            if (range.reason == .owned_band_change) {
                self.saw_owned_band_change = true;
            }
        }
    }
};

const PreparedTranscriptFramePainter = struct {
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,

    fn paint(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *PreparedTranscriptFramePainter = @ptrCast(@alignCast(ctx));
        _ = try self.runtime.paintPreparedTranscriptIntoSurface(
            self.alloc,
            surface,
            self.prepared,
        );
    }
};

fn appendGridRows(
    alloc: Allocator,
    grid: *const vt_emulator.Grid,
    first_row: u16,
    row_count: u16,
    history: *std.ArrayList(u8),
    row_text: *std.ArrayList(u8),
) !void {
    var row_offset: u16 = 0;
    while (row_offset < row_count) : (row_offset += 1) {
        row_text.clearRetainingCapacity();
        try grid.rowTextTrimmed(first_row + row_offset, row_text);
        try std.testing.expect(row_text.items.len > 0);
        if (history.items.len > 0) try history.append(alloc, '\n');
        try history.appendSlice(alloc, row_text.items);
    }
}

fn countExactHistoryLine(history: []const u8, expected: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, history, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, expected)) count += 1;
    }
    return count;
}

fn cloneRecoveryTransitionForTest(
    alloc: Allocator,
    source: *const transcript_runtime.TranscriptTransition,
) !transcript_runtime.TranscriptTransition {
    std.debug.assert(!source.consumed);
    std.debug.assert(source.document_append.isEmpty());
    std.debug.assert(source.document_append_bytes.len == 0);

    var clone = source.*;
    clone.document_append.bytes = &.{};
    clone.document_append_bytes = &.{};
    clone.target_flow = &.{};
    clone.target_cache = .empty;
    clone.folded_summary_indices = &.{};
    errdefer clone.deinit(alloc);

    clone.target_flow = try alloc.dupe(u8, source.target_flow);
    try clone.target_cache.appendSlice(alloc, source.target_cache.items);
    clone.folded_summary_indices = try alloc.dupe(
        usize,
        source.folded_summary_indices,
    );
    return clone;
}

fn createProductionCappedFoldedRecoveryTransition(
    alloc: Allocator,
    cols: u16,
    viewport_rows: u16,
) !transcript_runtime.TranscriptTransition {
    const stable_flow = "summary";
    const initial_owned_top = viewport_rows + 1;
    const content_bottom = initial_owned_top + viewport_rows - 1;
    const raw_line_count: usize = 3;
    const wrapped_rows_per_line: usize =
        (@as(usize, std.math.maxInt(u16)) + 1) / raw_line_count + 1;
    const raw_line_bytes = wrapped_rows_per_line * @as(usize, cols);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(
        std.testing.io,
        "production-folded-capped-attempt.log",
        .{ .read = true },
    );
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = transcriptTestLayout(
            cols,
            content_bottom + 4,
            content_bottom,
        ),
        .owned_top_row = initial_owned_top,
        .max_transcript_bytes = 2 * 1024 * 1024,
        .max_retained_transcript_bytes = 2 * 1024 * 1024,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed("shell0\r\nshell1\r\nshell2\r\nshell3");

    try runtime.transcript.appendSlice(alloc, stable_flow);
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_transcript_index = 1,
    });
    var fold_index: usize = 0;
    while (fold_index < viewport_rows) : (fold_index += 1) {
        var fold_buf: [16]u8 = undefined;
        const fold = try std.fmt.bufPrint(&fold_buf, "fold{d}", .{fold_index});
        try appendFoldedLineForTest(&runtime, alloc, 0, fold);
    }

    var metrics: Metrics = .{};
    var stable_source = try runtime.prepareTranscriptSource(alloc, null);
    defer stable_source.deinit(alloc);
    try std.testing.expectEqualStrings(stable_flow, stable_source.bytes);
    try std.testing.expectEqual(@as(usize, 1), stable_source.folded_summary_indices.len);
    try std.testing.expectEqual(@as(usize, 1), stable_source.folded_summary_indices[0]);
    try std.testing.expectEqual(viewport_rows, stable_source.preview.natural_visual_rows);

    var stable_prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
    defer if (stable_prepared) |*paint| paint.deinit(alloc);
    const stable_frame = try solveTestTranscriptFixedPointFrame(
        &runtime,
        alloc,
        &metrics,
        &stable_source,
        4,
        &stable_prepared,
    );
    const stable_paint = &stable_prepared.?;
    try std.testing.expectEqual(
        stable_frame.layout.owned_top,
        stable_frame.scroll_plan.post_scroll_owned_top,
    );
    var stable_plan = testPaintPlanForFrame(
        stable_frame.layout,
        stable_paint.selection,
        stable_paint.cursor.cursor_row,
        stable_paint.cursor.cursor_col,
    );
    var stable_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &stable_source,
        stable_paint,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(stable_frame.layout),
        &stable_plan,
        stable_frame.scroll_plan,
    );
    defer stable_transition.deinit(alloc);
    try std.testing.expect(stable_transition.document_append.isEmpty());

    var stable_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = stable_paint,
    };
    const stable_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = stable_plan,
            .scroll_plan = stable_frame.scroll_plan,
            .document_append = stable_transition.document_append,
            .body_painter = .{
                .ctx = &stable_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        stable_result.shadow_state,
    );
    runtime.ackPreservedRowReleaseAssumeValid(
        stable_frame.scroll_plan,
        stable_result.terminal_scroll_rows_committed,
    );
    runtime.consumeTranscriptTransition(alloc, &stable_transition, stable_result);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );

    var raw_line: std.ArrayList(u8) = .empty;
    defer raw_line.deinit(alloc);
    var raw_line_index: usize = 0;
    while (raw_line_index < raw_line_count) : (raw_line_index += 1) {
        try runtime.transcript.appendSlice(alloc, "\n");
        raw_line.clearRetainingCapacity();
        try raw_line.appendNTimes(
            alloc,
            'a' + @as(u8, @intCast(raw_line_index)),
            raw_line_bytes,
        );
        try std.testing.expectEqual(
            @as(u16, @intCast(wrapped_rows_per_line)),
            visualRowsForLine(raw_line.items, cols),
        );
        try runtime.transcript.appendSlice(alloc, raw_line.items);
    }

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(
        @as(u16, std.math.maxInt(u16)),
        source.preview.natural_visual_rows,
    );
    try std.testing.expectEqual(@as(usize, 1), source.folded_summary_indices.len);
    try std.testing.expectEqual(@as(usize, 1), source.folded_summary_indices[0]);

    var prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
    defer if (prepared) |*paint| paint.deinit(alloc);
    const frame = try solveTestTranscriptFixedPointFrame(
        &runtime,
        alloc,
        &metrics,
        &source,
        8,
        &prepared,
    );
    const paint = &prepared.?;
    const facts = runtime.planTranscriptScroll(paint);
    try std.testing.expect(facts.semantic_rows > std.math.maxInt(u16));
    try std.testing.expectEqual(viewport_rows, facts.planned_rows);
    try std.testing.expectEqual(
        frame.layout.owned_top,
        frame.scroll_plan.post_scroll_owned_top,
    );
    try std.testing.expectEqual(
        viewport_rows,
        frame.scroll_plan.acceptedInlineRows(
            frame.scroll_plan.terminal_scroll_rows,
        ),
    );

    var plan = testPaintPlanForFrame(
        frame.layout,
        paint.selection,
        paint.cursor.cursor_row,
        paint.cursor.cursor_col,
    );
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        paint,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(frame.layout),
        &plan,
        frame.scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());
    try std.testing.expectEqual(@as(?usize, null), transition.materialized.flow_len);
    try std.testing.expectEqual(viewport_rows, transition.materialized.visual_rows);
    try std.testing.expectEqual(
        @as(u32, viewport_rows),
        transition.materialized.visual_offset,
    );
    var transition_template = try cloneRecoveryTransitionForTest(
        alloc,
        &transition,
    );
    errdefer transition_template.deinit(alloc);

    var painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = paint,
    };
    const result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = plan,
            .scroll_plan = frame.scroll_plan,
            .document_append = transition.document_append,
            .body_painter = .{
                .ctx = &painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        result.shadow_state,
    );
    try std.testing.expectEqual(
        frame.scroll_plan.terminal_scroll_rows,
        result.terminal_scroll_rows_committed,
    );
    try std.testing.expect(!result.document_append_committed);
    runtime.ackPreservedRowReleaseAssumeValid(
        frame.scroll_plan,
        result.terminal_scroll_rows_committed,
    );
    runtime.consumeTranscriptTransition(alloc, &transition, result);

    const diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        diagnostic.state,
    );
    try std.testing.expectEqual(transition.visual_offset, diagnostic.visual_offset);
    try std.testing.expect(diagnostic.remaining_inline_rows > 0);
    try std.testing.expectEqual(
        facts.semantic_rows - facts.planned_rows,
        diagnostic.remaining_inline_rows,
    );

    return transition_template;
}

fn testSelectionInArea(
    start_line: usize,
    top_row: u16,
    bottom_row: u16,
) viewport_selection.ViewportSelection {
    var selection = testSelection(start_line);
    selection.top_row = top_row;
    selection.bottom_row = bottom_row;
    return selection;
}

fn enterSemanticAppendRecovery(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    stable_flow: []const u8,
    attempt_flow: []const u8,
    attempt_visual_rows: []const u16,
) !void {
    const stable_selection = testSelectionInArea(
        0,
        runtime.owned_top_row,
        runtime.layout.content_bottom,
    );
    try installStableAnchorForTest(
        runtime,
        alloc,
        stable_flow,
        stable_selection,
        0,
        runtime.layout.content_bottom,
        1,
        45,
    );

    var source = try testSource(alloc, attempt_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(
            4,
            runtime.owned_top_row,
            runtime.layout.content_bottom,
        ),
        .cursor = .{
            .cursor_row = runtime.layout.content_bottom,
            .cursor_col = 1,
            .replaceable_row = runtime.layout.content_bottom,
        },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, attempt_visual_rows);
    try makeSyntheticPreparedRenderable(&prepared, alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 0), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 4), facts.semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        3,
        facts.planned_rows,
    );
    try std.testing.expectEqual(@as(u16, 1), scroll_plan.remaining_inline_advance_rows);

    var plan = testPaintPlan(runtime, prepared.selection);
    const target_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());

    runtime.ackPreservedRowReleaseAssumeValid(
        scroll_plan,
        scroll_plan.terminal_scroll_rows,
    );
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = runtime.layout.content_bottom,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u32, 3), recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);
}

fn consumeUnacceptedSemanticRecoveryRetry(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    visual_rows: []const u16,
    start_line: usize,
) !void {
    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(
            start_line,
            runtime.owned_top_row,
            runtime.layout.content_bottom,
        ),
        .cursor = .{
            .cursor_row = runtime.layout.content_bottom,
            .cursor_col = 1,
            .replaceable_row = runtime.layout.content_bottom,
        },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, visual_rows);
    try makeSyntheticPreparedRenderable(&prepared, alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 0), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 1), facts.semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = runtime.layout.content_bottom,
        .committed_cursor_col = 1,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u32, 3), recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);
}

fn enterResizeReflowRecovery(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    resize_history_row_delta: ?i32,
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
) !void {
    return enterResizeReflowRecoveryWithAcceptedRows(
        runtime,
        alloc,
        resize_history_row_delta,
        shadow_state,
        1,
    );
}

fn enterResizeReflowRecoveryWithAcceptedRows(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    resize_history_row_delta: ?i32,
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
    accepted_rows: u16,
) !void {
    const flow = "stable\nbase\n";
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(
        runtime,
        alloc,
        flow,
        testSelectionInArea(0, 1, 4),
        0,
        4,
        1,
        46,
    );
    const shadow = runtime.shadow_vt.?;
    shadow.cells[19].codepoint = 'x';
    shadow.cursor_row = 8;
    shadow.cursor_col = 1;

    runtime.viewport_clear_pending = true;
    runtime.layout = transcriptTestLayout(10, 8, 2);
    runtime.resize_history_row_delta = resize_history_row_delta;

    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 2), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.semantic_rows);
    try std.testing.expect(accepted_rows < facts.planned_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    const target_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = accepted_rows,
        .document_append_committed = false,
        .committed_cursor_row = 2,
        .committed_cursor_col = 1,
        .shadow_state = shadow_state,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(facts.target_visual_offset, recovery.visual_offset);
    try std.testing.expectEqual(
        facts.planned_rows - accepted_rows,
        recovery.remaining_inline_rows,
    );
}


const RecoveryAttemptOutcome = struct {
    facts: transcript_runtime.TranscriptScrollFacts,
    visual_offset: u32,
};

fn consumeRendererRecoveryAttempt(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    committed_inline_rows: u16,
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
) !RecoveryAttemptOutcome {
    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    try std.testing.expect(committed_inline_rows <= scroll_plan.terminal_scroll_rows);
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    const visual_offset = transition.visual_offset;

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = committed_inline_rows,
        .document_append_committed = !transition.document_append.isEmpty(),
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = shadow_state,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    return .{
        .facts = facts,
        .visual_offset = visual_offset,
    };
}

fn expectDocumentWireEqualsLogical(
    alloc: Allocator,
    logical: []const u8,
    wire: []const u8,
) !void {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(alloc);
    var index: usize = 0;
    while (index < wire.len) {
        if (wire[index] == '\n') return error.TestExpectedCarriageReturn;
        if (wire[index] == '\r' and index + 1 < wire.len and wire[index + 1] == '\n') {
            try decoded.append(alloc, '\n');
            index += 2;
        } else {
            try decoded.append(alloc, wire[index]);
            index += 1;
        }
    }
    try std.testing.expectEqualStrings(logical, decoded.items);
}

fn expectRendererAppendRestored(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    stable_flow: []const u8,
    grown_flow: []const u8,
) !void {
    var source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(!facts.recovery_rebase);
    try std.testing.expect(facts.semantic_rows > 0);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try expectDocumentWireEqualsLogical(
        alloc,
        grown_flow[stable_flow.len..],
        transition.document_append.bytes,
    );
}

fn checkTranscriptTransitionStagingAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(&runtime, alloc, "old\n", testSelection(0), 0, 3, 1, 71);
    const committed_before = runtime.transcriptCommitDiagnostic();

    var source = try testSource(alloc, "old\nnew\n", runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelection(1),
        .cursor = .{ .cursor_row = 4, .cursor_col = 1, .replaceable_row = 4 },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, &.{ 1, 1 });
    const scroll_plan = render_engine.frame_scroll_plan.merge(runtime.layout.rows, 1, 0, 1);
    var plan = testPaintPlan(&runtime, prepared.selection);
    const target_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    ) catch |err| {
        try std.testing.expectEqualDeep(committed_before, runtime.transcriptCommitDiagnostic());
        try std.testing.expect(runtime.stableTranscriptProjectionForFlow("old\n") != null);
        return err;
    };
    defer transition.deinit(alloc);

    try std.testing.expectEqualDeep(committed_before, runtime.transcriptCommitDiagnostic());
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow("old\n") != null);
}

fn commandOutputTestStyles() Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
}

fn commandOutputAnsiTestStyles() Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "\x1b[0m",
        .dim_style = "\x1b[2m",
        .red_style = "\x1b[31m",
    };
}

fn semanticNoticePaletteA() Styles {
    return .{
        .system_notice_text_style = "\x1b[37m",
        .reset_style = "\x1b[0m",
        .notice_information_style = "\x1b[36m",
        .notice_success_style = "\x1b[32m",
        .notice_warning_style = "\x1b[33m",
        .notice_error_style = "\x1b[31m",
        .notice_cancelled_style = "\x1b[90m",
    };
}

fn semanticNoticePaletteB() Styles {
    return .{
        .system_notice_text_style = "\x1b[35m",
        .reset_style = "\x1b[0m",
        .notice_information_style = "\x1b[34m",
        .notice_success_style = "\x1b[92m",
        .notice_warning_style = "\x1b[93m",
        .notice_error_style = "\x1b[91m",
        .notice_cancelled_style = "\x1b[2m",
    };
}


fn checkSemanticNoticeAppendAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(32, 16, 12) };
    defer runtime.deinit(alloc);
    const entry_id = try runtime.appendSemanticNotice(alloc, .{
        .topic = "allocator",
        .tone = .@"error",
        .body = "owned topic and body",
    });
    try std.testing.expectEqual(@as(u32, 1), entry_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqualStrings("allocator", runtime.entries.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings("owned topic and body", runtime.entries.items[0].semantic_notice.body);
}


fn checkSemanticNoticeReplacementAllocationFailures(alloc: Allocator) !void {
    const base = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(32, 16, 12) };
    defer runtime.deinit(base);
    const entry_id = try runtime.appendReplaceableSemanticNotice(base, .{
        .topic = "before",
        .tone = .information,
        .body = "stable body",
    });
    const created_at_ms = runtime.entries.items[0].createdAtMs();
    const next_entry_id = runtime.next_entry_id;

    const replaced = runtime.replaceSemanticNotice(alloc, entry_id, .{
        .topic = "after",
        .tone = .cancelled,
        .body = "replacement body",
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
        try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
        try std.testing.expectEqual(created_at_ms, runtime.entries.items[0].createdAtMs());
        try std.testing.expectEqualStrings("before", runtime.entries.items[0].semantic_notice.topic);
        try std.testing.expectEqualStrings("stable body", runtime.entries.items[0].semantic_notice.body);
        try std.testing.expectEqual(next_entry_id, runtime.next_entry_id);
        return err;
    };
    try std.testing.expect(replaced);
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
    try std.testing.expectEqual(created_at_ms, runtime.entries.items[0].createdAtMs());
    try std.testing.expectEqualStrings("after", runtime.entries.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings("replacement body", runtime.entries.items[0].semantic_notice.body);
    try std.testing.expectEqual(next_entry_id, runtime.next_entry_id);
}























































fn checkPrepareTranscriptSourceAllocationFailures(alloc: Allocator) !void {
    const welcome =
        "fx welcome banner line one\n" ++
        "fx welcome banner line two\n";
    const summary = "● 2 command lines folded\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 10, 6),
        .owned_top_row = 1,
        .max_transcript_bytes = 1024,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, welcome, .welcome);
    const summary_entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        summary,
        .subagent_status,
    );
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_entry_id = summary_entry_id,
    });
    try appendFoldedLineForTest(&runtime, alloc, 0, "command output line");

    var uncapped = try runtime.prepareTranscriptSource(alloc, summary_entry_id);
    defer uncapped.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), uncapped.folded_summary_indices[0]);
    try std.testing.expectEqual(@as(?usize, 3), uncapped.tracked_entry_start_line);
    try std.testing.expectEqual(@as(u16, 6), uncapped.preview.natural_visual_rows);
    try std.testing.expectEqual(
        transcript_blocks.LeadingWelcomeBoundary{
            .full_cut_line = 3,
            .tail_replay_line = 1,
        },
        uncapped.welcome_boundary.?,
    );
    try std.testing.expectEqual(@as(?usize, 3), uncapped.welcome_cut_line);

    runtime.max_transcript_bytes = summary.len;
    var source = try runtime.prepareTranscriptSource(alloc, summary_entry_id);
    defer source.deinit(alloc);

    try std.testing.expect(welcome.len + summary.len > runtime.max_transcript_bytes);
    try std.testing.expectEqualStrings(uncapped.bytes, source.bytes);
    try std.testing.expect(source.bytes.len > runtime.max_transcript_bytes);
    try std.testing.expectEqual(@as(usize, 1), source.folded_summary_indices.len);
    try std.testing.expectEqual(@as(usize, 4), source.folded_summary_indices[0]);
    try std.testing.expectEqual(@as(?usize, 3), source.tracked_entry_start_line);
    try std.testing.expectEqual(@as(u16, 6), source.preview.natural_visual_rows);
    try std.testing.expectEqual(
        transcript_blocks.LeadingWelcomeBoundary{
            .full_cut_line = 3,
            .tail_replay_line = 1,
        },
        source.welcome_boundary.?,
    );
    try std.testing.expectEqual(@as(?usize, 3), source.welcome_cut_line);
}


fn checkPreviewPreparationFailureLeavesRuntimeUnchanged(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 10, 6),
        .owned_top_row = 1,
        .max_transcript_bytes = 128,
        .last_rendered_cols = 17,
    };
    defer runtime.deinit(alloc);
    try runtime.initBacking(alloc);

    const entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "recorded source\n",
        .subagent_status,
    );
    runtime.transcript.clearRetainingCapacity();
    try runtime.transcript.appendSlice(alloc, "poisoned cache\n");
    runtime.transcript_cache_origin_untrimmed = false;
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_entry_id = entry_id,
        .summary_transcript_index = 777,
    });
    runtime.transcript_band_dirty = false;
    runtime.paint_trace.transcript_initialized = true;
    runtime.paint_trace.transcript_start_line = 41;

    const entry_count = runtime.entries.items.len;
    const next_entry_id = runtime.next_entry_id;
    const commit_state = runtime.transcriptCommitDiagnostic();
    const paint_trace = runtime.paint_trace;
    const pending_repaints = runtime.render_requests.pendingReasonCount();

    _ = runtime.previewTranscriptFlow(alloc) catch |err| {
        try std.testing.expectEqualStrings("poisoned cache\n", runtime.transcript.items);
        try std.testing.expectEqual(entry_count, runtime.entries.items.len);
        try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
        try std.testing.expectEqualStrings(
            "recorded source\n",
            runtime.entries.items[0].raw_bytes.bytes,
        );
        try std.testing.expectEqual(next_entry_id, runtime.next_entry_id);
        try std.testing.expectEqual(
            @as(usize, 777),
            runtime.folded_command_blocks.items[0].summary_transcript_index,
        );
        try std.testing.expectEqualDeep(commit_state, runtime.transcriptCommitDiagnostic());
        try std.testing.expectEqualDeep(paint_trace, runtime.paint_trace);
        try std.testing.expectEqual(
            pending_repaints,
            runtime.render_requests.pendingReasonCount(),
        );
        try std.testing.expect(!runtime.transcript_band_dirty);
        return err;
    };
}























fn removeRawEntriesForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    ids: []const u32,
) !void {
    for (ids) |id| {
        var index: usize = 0;
        while (index < runtime.entries.items.len) : (index += 1) {
            const entry = runtime.entries.items[index];
            if (entry == .raw_bytes and entry.raw_bytes.id == id) {
                var removed = runtime.entries.orderedRemove(index);
                removed.deinit(alloc);
                break;
            }
        } else return error.TestExpectedRawEntry;
    }
}













































const AssistantStreamFastPathCase = enum {
    opening,
    continuation,
};

const AssistantStreamFastPathFailureWitness = struct {
    target_failures: usize = 0,
};

fn checkOrdinaryAssistantStreamAllocationFailures(
    alloc: Allocator,
    test_case: AssistantStreamFastPathCase,
    witness: *AssistantStreamFastPathFailureWitness,
) !void {
    const continuation = [_]u8{'b'} ** 4096;
    const chunk: []const u8 = switch (test_case) {
        .opening => "first chunk",
        .continuation => &continuation,
    };

    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(24, 12, 8) };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    const existing_entry_id: ?u32 = switch (test_case) {
        .opening => null,
        .continuation => try runtime.streamAssistantChunk(alloc, &metrics, "a"),
    };
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const assistant_before = if (existing_entry_id) |entry_id|
        try std.testing.allocator.dupe(
            u8,
            runtime.lookupAssistantSegments(entry_id).?.text.items,
        )
    else
        null;
    defer if (assistant_before) |text| std.testing.allocator.free(text);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();

    try std.testing.expect(retained_before <= runtime.max_retained_transcript_bytes);
    try std.testing.expect(
        chunk.len <= runtime.max_retained_transcript_bytes - retained_before,
    );
    try std.testing.expect(
        chunk.len > runtime.transcript.capacity - runtime.transcript.items.len,
    );
    if (existing_entry_id) |entry_id| {
        const segments = runtime.lookupAssistantSegments(entry_id).?;
        try std.testing.expect(
            chunk.len > segments.text.capacity - segments.text.items.len,
        );
    } else {
        try std.testing.expectEqual(@as(usize, 0), runtime.entries.capacity);
    }

    const entry_id = runtime.streamAssistantChunk(alloc, &metrics, chunk) catch |err| {
        witness.target_failures += 1;
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        if (existing_entry_id) |prior_entry_id| {
            try std.testing.expectEqualStrings(
                assistant_before.?,
                runtime.lookupAssistantSegments(prior_entry_id).?.text.items,
            );
        }
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(cache_origin_before, runtime.transcript_cache_origin_untrimmed);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    const opened_new_turn = test_case == .opening;
    const expected_entry_id = existing_entry_id orelse next_entry_id_before;
    try std.testing.expectEqual(expected_entry_id, entry_id);
    try std.testing.expectEqual(
        next_entry_id_before +% @intFromBool(opened_new_turn),
        runtime.next_entry_id,
    );
    try std.testing.expectEqual(
        entry_count_before + @intFromBool(opened_new_turn),
        runtime.entries.items.len,
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .assistant_turn);
    try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());

    const assistant_text = runtime.entries.items[0].assistant_turn.segments.text.items;
    switch (test_case) {
        .opening => try std.testing.expectEqualStrings(chunk, assistant_text),
        .continuation => {
            try std.testing.expectEqual(@as(usize, 1) + chunk.len, assistant_text.len);
            try std.testing.expectEqualStrings("a", assistant_text[0..1]);
            try std.testing.expectEqualStrings(chunk, assistant_text[1..]);
        },
    }
    try std.testing.expectEqualStrings(assistant_text, runtime.transcript.items);
    try std.testing.expectEqual(
        assistant_text.len,
        transcript_store.retainedStructuredBytes(&runtime),
    );
    try std.testing.expectEqual(repaint_count_before + 1, runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}


fn checkOpeningAssistantStreamAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(24, 12, 8) };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    try runtime.writeTranscript(alloc, &metrics, "older transcript row\n", true);
    const prompt = try alloc.dupe(u8, "prompt");
    _ = try runtime.appendUserTurnOwned(alloc, .{ .text = prompt, .images = &.{} });
    runtime.max_retained_transcript_bytes = "prompt".len + "first chunk".len;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();

    const entry_id = runtime.streamAssistantChunk(
        alloc,
        &metrics,
        "first chunk",
    ) catch |err| {
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(cache_origin_before, runtime.transcript_cache_origin_untrimmed);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqual(next_entry_id_before, entry_id);
    try std.testing.expectEqual(next_entry_id_before +% 1, runtime.next_entry_id);
    try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .user_turn);
    try std.testing.expect(runtime.entries.items[1] == .assistant_turn);
    try std.testing.expectEqual(entry_id, runtime.entries.items[1].id());
    try std.testing.expectEqualStrings(
        "first chunk",
        runtime.entries.items[1].assistant_turn.segments.text.items,
    );
    try std.testing.expectEqual(
        runtime.max_retained_transcript_bytes,
        transcript_store.retainedStructuredBytes(&runtime),
    );
    const rendered = try renderEntriesToBytes(
        std.testing.allocator,
        runtime.entries.items,
        runtime.layout.cols,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(rendered, runtime.transcript.items);
    try std.testing.expectEqual(repaint_count_before + 1, runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}


fn checkExtendingAssistantStreamAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(24, 12, 8) };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    try runtime.writeTranscript(alloc, &metrics, "older transcript row\n", true);
    const entry_id = try runtime.streamAssistantChunk(alloc, &metrics, "alpha ");
    runtime.max_retained_transcript_bytes = "alpha beta".len;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const assistant_before = try std.testing.allocator.dupe(
        u8,
        runtime.lookupAssistantSegments(entry_id).?.text.items,
    );
    defer std.testing.allocator.free(assistant_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();

    const continued_id = runtime.streamAssistantChunk(
        alloc,
        &metrics,
        "beta",
    ) catch |err| {
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqualStrings(
            assistant_before,
            runtime.lookupAssistantSegments(entry_id).?.text.items,
        );
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(cache_origin_before, runtime.transcript_cache_origin_untrimmed);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqual(entry_id, continued_id);
    try std.testing.expectEqual(entry_count_before - 1, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
    try std.testing.expect(runtime.entries.items[0] == .assistant_turn);
    try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
    try std.testing.expectEqualStrings(
        "alpha beta",
        runtime.entries.items[0].assistant_turn.segments.text.items,
    );
    try std.testing.expectEqual(
        runtime.max_retained_transcript_bytes,
        transcript_store.retainedStructuredBytes(&runtime),
    );
    const rendered = try renderEntriesToBytes(
        std.testing.allocator,
        runtime.entries.items,
        runtime.layout.cols,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(rendered, runtime.transcript.items);
    try std.testing.expectEqual(repaint_count_before + 1, runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}






const UserPromptCardAdmissionCase = enum {
    text_with_separator,
    image_with_skill_token,
};

const prompt_card_skill_tokens = [_]input_visual_layout.SkillTokenSpan{.{
    .raw_start = "inspect ".len,
    .raw_end = "inspect $review".len,
    .name = "review",
    .path = "/tmp/review",
}};

fn setup_user_prompt_card_admission_runtime(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    test_case: UserPromptCardAdmissionCase,
) !u32 {
    const seed_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "seed",
        .subagent_status,
    );
    runtime.cursor_row = 2;
    runtime.cursor_col = switch (test_case) {
        .text_with_separator => 5,
        .image_with_skill_token => 1,
    };
    runtime.replaceable_last_line = true;
    runtime.replaceable_start = 1;
    runtime.replaceable_row = 2;
    runtime.transcript_cache_origin_untrimmed = true;
    runtime.full_transcript.depth = .full;
    runtime.full_transcript.scroll_rows = 3;
    runtime.full_transcript.follow_tail = false;
    runtime.full_transcript.anchor_entry_id = seed_id;
    runtime.full_transcript.anchor_pending = true;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;
    return seed_id;
}

fn user_prompt_card_admission_input(
    test_case: UserPromptCardAdmissionCase,
    images: []types.ImageAttachment,
) struct {
    user: types.UserTurn,
    skill_tokens: []const input_visual_layout.SkillTokenSpan,
    has_prior_turns: bool,
} {
    return switch (test_case) {
        .text_with_separator => .{
            .user = .{ .text = @constCast("plain prompt"), .images = &.{} },
            .skill_tokens = &.{},
            .has_prior_turns = false,
        },
        .image_with_skill_token => .{
            .user = .{ .text = @constCast("inspect $review"), .images = images },
            .skill_tokens = &prompt_card_skill_tokens,
            .has_prior_turns = true,
        },
    };
}

fn check_user_prompt_card_admission_success(
    test_case: UserPromptCardAdmissionCase,
) !void {
    const alloc = std.testing.allocator;
    const layout = transcriptTestLayout(48, 12, 8);
    var actual = TranscriptRuntime{ .layout = layout };
    defer actual.deinit(alloc);
    const seed_id = try setup_user_prompt_card_admission_runtime(&actual, alloc, test_case);

    var images = [_]types.ImageAttachment{.{
        .id = 7,
        .path = @constCast("/tmp/prompt-card.png"),
        .media_type = @constCast("image/png"),
    }};
    const input = user_prompt_card_admission_input(test_case, &images);
    const input_images_ptr = input.user.images.ptr;
    const card = try user_message_card.buildUserPromptCardWithSkillTokens(
        alloc,
        input.user.text,
        input.user.images,
        actual.layout.cols,
        input.skill_tokens,
    );
    defer alloc.free(card);
    const separator = if (input.has_prior_turns) "" else "\n";
    const expected_transcript = try std.fmt.allocPrint(
        alloc,
        "seed{s}{s}",
        .{ separator, card },
    );
    defer alloc.free(expected_transcript);
    const expected_reconstructed = try std.fmt.allocPrint(
        alloc,
        "seed\n\n{s}",
        .{card},
    );
    defer alloc.free(expected_reconstructed);

    var actual_metrics = Metrics{};
    const actual_id = try actual.writeUserPromptCard(
        alloc,
        &actual_metrics,
        input.user,
        input.has_prior_turns,
        input.skill_tokens,
    );

    const expected_id = seed_id + @as(u32, if (input.has_prior_turns) 1 else 2);
    try std.testing.expectEqual(expected_id, actual_id);
    try std.testing.expectEqualStrings(expected_transcript, actual.transcript.items);
    try std.testing.expectEqual(
        @as(usize, if (input.has_prior_turns) 2 else 3),
        actual.entries.items.len,
    );
    try std.testing.expectEqual(expected_id +% 1, actual.next_entry_id);
    var expected_cursor = TranscriptRuntime{
        .layout = layout,
        .cursor_row = 2,
        .cursor_col = switch (test_case) {
            .text_with_separator => 5,
            .image_with_skill_token => 1,
        },
    };
    _ = expected_cursor.advanceCursor(expected_transcript["seed".len..]);
    try std.testing.expectEqual(expected_cursor.cursor_row, actual.cursor_row);
    try std.testing.expectEqual(expected_cursor.cursor_col, actual.cursor_col);
    try std.testing.expect(!actual.replaceable_last_line);
    try std.testing.expectEqual(@as(usize, 0), actual.replaceable_start);
    try std.testing.expectEqual(@as(u16, 2), actual.replaceable_row);
    try std.testing.expect(!actual.transcript_cache_origin_untrimmed);
    try std.testing.expect(actual.render_requests.hasReason(.transcript));
    try std.testing.expectEqual(@as(usize, 1), actual.render_requests.pendingReasonCount());
    try std.testing.expectEqual(@as(u32, 3), actual.full_transcript.scroll_rows);
    try std.testing.expect(!actual.full_transcript.follow_tail);
    try std.testing.expectEqual(@as(?u32, seed_id), actual.full_transcript.anchor_entry_id);
    try std.testing.expect(actual.full_transcript.anchor_pending);

    const actual_reconstructed = try renderEntriesToBytes(
        alloc,
        actual.entries.items,
        actual.layout.cols,
    );
    defer alloc.free(actual_reconstructed);
    try std.testing.expectEqualStrings(expected_reconstructed, actual_reconstructed);
    var expected_retained_bytes = "seed".len + separator.len + input.user.text.len;
    for (input.user.images) |image| {
        expected_retained_bytes += image.path.len + image.media_type.len;
    }
    for (input.skill_tokens) |token| {
        expected_retained_bytes += token.name.len + token.path.len;
    }
    try std.testing.expectEqual(
        expected_retained_bytes,
        transcript_store.retainedStructuredBytes(&actual),
    );
    try std.testing.expectEqualStrings(input.user.text, actual.entries.items[actual.entries.items.len - 1].user_turn.turn.text);
    try std.testing.expectEqual(input_images_ptr, input.user.images.ptr);
}








fn checkThemeRetintAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "ALLOCATION TRANSCRIPT 01\n" ++
            "ALLOCATION TRANSCRIPT 02\n" ++
            "ALLOCATION TRANSCRIPT 03\n" ++
            "\x1b[38;5;252mRETINT ALLOCATION MARKER\x1b[39m\n",
        .subagent_status,
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );

    var source_before = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer source_before.deinit(std.testing.allocator);
    const cache_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(cache_before);
    const diagnostic_before = runtime.transcriptCommitDiagnostic();
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const pending_repaints_before = runtime.render_requests.pendingReasonCount();
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;

    runtime.retintEntriesForTheme(alloc, false, true) catch |err| {
        var source_after = try runtime.prepareTranscriptSource(std.testing.allocator, null);
        defer source_after.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(source_before.bytes, source_after.bytes);
        try std.testing.expectEqualStrings(cache_before, runtime.transcript.items);
        try std.testing.expectEqualDeep(
            diagnostic_before,
            runtime.transcriptCommitDiagnostic(),
        );
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(
            pending_repaints_before,
            runtime.render_requests.pendingReasonCount(),
        );
        try std.testing.expectEqual(
            cache_origin_before,
            runtime.transcript_cache_origin_untrimmed,
        );
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqualDeep(
        diagnostic_before,
        runtime.transcriptCommitDiagnostic(),
    );
    var retinted_source = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer retinted_source.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(
        u8,
        retinted_source.bytes,
        "\x1b[38;5;238mRETINT ALLOCATION MARKER",
    ) != null);
}



fn check_user_prompt_card_admission_allocation_failures(
    alloc: Allocator,
    test_case: UserPromptCardAdmissionCase,
) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(48, 12, 8) };
    defer runtime.deinit(alloc);
    const seed_id = try setup_user_prompt_card_admission_runtime(&runtime, alloc, test_case);

    var images = [_]types.ImageAttachment{.{
        .id = 7,
        .path = @constCast("/tmp/prompt-card.png"),
        .media_type = @constCast("image/png"),
    }};
    const input = user_prompt_card_admission_input(test_case, &images);
    const input_images_ptr = input.user.images.ptr;
    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const reconstructed_before = try renderEntriesToBytes(
        std.testing.allocator,
        runtime.entries.items,
        runtime.layout.cols,
    );
    defer std.testing.allocator.free(reconstructed_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const replaceable_before = runtime.replaceable_last_line;
    const replaceable_start_before = runtime.replaceable_start;
    const replaceable_row_before = runtime.replaceable_row;
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        runtime.cursor_row,
        runtime.cursor_col,
        1,
    );
    const commit_before = runtime.transcriptCommitDiagnostic();
    const projection_before = runtime.stableTranscriptProjectionForFlow(
        committed_source.bytes,
    ) orelse return error.TestUnexpectedResult;
    const full_transcript_before = runtime.full_transcript;
    var metrics = Metrics{};

    _ = runtime.writeUserPromptCard(
        alloc,
        &metrics,
        input.user,
        input.has_prior_turns,
        input.skill_tokens,
    ) catch |err| {
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(seed_id, runtime.entries.items[0].id());
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        const reconstructed_after = try renderEntriesToBytes(
            std.testing.allocator,
            runtime.entries.items,
            runtime.layout.cols,
        );
        defer std.testing.allocator.free(reconstructed_after);
        try std.testing.expectEqualStrings(reconstructed_before, reconstructed_after);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(replaceable_before, runtime.replaceable_last_line);
        try std.testing.expectEqual(replaceable_start_before, runtime.replaceable_start);
        try std.testing.expectEqual(replaceable_row_before, runtime.replaceable_row);
        try std.testing.expectEqual(cache_origin_before, runtime.transcript_cache_origin_untrimmed);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        try std.testing.expectEqualDeep(commit_before, runtime.transcriptCommitDiagnostic());
        const projection_after = runtime.stableTranscriptProjectionForFlow(
            committed_source.bytes,
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualDeep(projection_before, projection_after);
        try std.testing.expectEqual(full_transcript_before.scroll_rows, runtime.full_transcript.scroll_rows);
        try std.testing.expectEqual(full_transcript_before.follow_tail, runtime.full_transcript.follow_tail);
        try std.testing.expectEqual(full_transcript_before.anchor_entry_id, runtime.full_transcript.anchor_entry_id);
        try std.testing.expectEqual(full_transcript_before.anchor_pending, runtime.full_transcript.anchor_pending);
        try std.testing.expectEqualStrings(input.user.text, switch (test_case) {
            .text_with_separator => "plain prompt",
            .image_with_skill_token => "inspect $review",
        });
        try std.testing.expectEqual(input_images_ptr, input.user.images.ptr);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expectEqual(repaint_count_before + 1, runtime.render_requests.pendingReasonCount());
    try std.testing.expectEqualStrings(input.user.text, runtime.entries.items[runtime.entries.items.len - 1].user_turn.turn.text);
    try std.testing.expectEqual(input_images_ptr, input.user.images.ptr);
}







const RecordedWriteToolDetailFixture = struct {
    entry_id: u32,
    tool_name: []const u8,
    arguments_json: []const u8,
    result: []const u8,
    result_handle: []const u8,
    turn_id: u64,
    call_id: []const u8,
    command_output_entry_id: u32,
};

fn appendRecordedWriteToolDetailFixture(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    fixture: RecordedWriteToolDetailFixture,
) !void {
    var detail: ToolDetailRecord = .{
        .entry_id = fixture.entry_id,
        .tool_name = try alloc.dupe(u8, fixture.tool_name),
    };
    errdefer detail.deinit(alloc);
    detail.arguments_json = try alloc.dupe(u8, fixture.arguments_json);
    detail.result = try alloc.dupe(u8, fixture.result);
    detail.result_handle = try alloc.dupe(u8, fixture.result_handle);
    detail.outcome = .completed;
    const lifecycle_call_id = try alloc.dupe(u8, fixture.call_id);
    detail.lifecycle_id = .{
        .turn_id = fixture.turn_id,
        .call_id = lifecycle_call_id,
    };
    detail.command_output_entry_id = fixture.command_output_entry_id;
    try runtime.tool_details.append(alloc, detail);
}

fn expectRecordedWriteToolDetailFixture(
    runtime: *const TranscriptRuntime,
    fixture: RecordedWriteToolDetailFixture,
) !void {
    const detail = runtime.toolDetailForEntry(fixture.entry_id);
    try std.testing.expect(detail != null);
    try std.testing.expectEqualStrings(fixture.tool_name, detail.?.tool_name);
    try std.testing.expectEqualStrings(fixture.arguments_json, detail.?.arguments_json.?);
    try std.testing.expectEqualStrings(fixture.result, detail.?.result.?);
    try std.testing.expectEqualStrings(fixture.result_handle, detail.?.result_handle.?);
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.?.outcome.?);
    try std.testing.expectEqual(fixture.turn_id, detail.?.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings(fixture.call_id, detail.?.lifecycle_id.?.call_id);
    try std.testing.expectEqual(fixture.command_output_entry_id, detail.?.command_output_entry_id.?);
}

fn appendOwnedToolDetail(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    entry_id: u32,
    tool_name: []const u8,
) !void {
    var detail: ToolDetailRecord = .{
        .entry_id = entry_id,
        .tool_name = try alloc.dupe(u8, tool_name),
    };
    errdefer detail.deinit(alloc);
    try runtime.tool_details.append(alloc, detail);
}




const RecordedWriteCommandOutputFixture = struct {
    entry_id: u32,
    turn_id: u64,
    call_id: []const u8,
    line: []const u8,
};

fn appendRecordedWriteCommandOutputFixture(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    fixture: RecordedWriteCommandOutputFixture,
) !void {
    const Block = @TypeOf(runtime.command_output_blocks.items[0]);
    var block: Block = .{
        .entry_id = fixture.entry_id,
        .lifecycle_id = .{
            .turn_id = fixture.turn_id,
            .call_id = try alloc.dupe(u8, fixture.call_id),
        },
    };
    errdefer block.deinit(alloc);
    const line = try alloc.dupe(u8, fixture.line);
    block.lines.append(alloc, .{
        .stream = .stdout,
        .text = line,
    }) catch |err| {
        alloc.free(line);
        return err;
    };
    block.total_lines = 1;
    block.retained_text_bytes = line.len;
    try runtime.command_output_blocks.append(alloc, block);
}

fn expectRecordedWriteCommandOutputFixture(
    runtime: *const TranscriptRuntime,
    fixture: RecordedWriteCommandOutputFixture,
) !void {
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(fixture.entry_id, block.entry_id.?);
    try std.testing.expect(block.lifecycle_id != null);
    try std.testing.expectEqual(fixture.turn_id, block.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings(fixture.call_id, block.lifecycle_id.?.call_id);
    try std.testing.expectEqual(@as(usize, 1), block.lines.items.len);
    try std.testing.expectEqual(command_output_content.Stream.stdout, block.lines.items[0].stream);
    try std.testing.expectEqualStrings(fixture.line, block.lines.items[0].text);
}


fn checkRecordedTranscriptWriteAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 2,
        .cursor_col = 4,
        .max_transcript_bytes = 8,
        .max_retained_transcript_bytes = 19 + @sizeOf(command_output_runtime.CommandOutputLine),
        .command_output_render = .{},
    };
    defer runtime.deinit(alloc);

    const existing_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "old\n",
        .subagent_status,
    );
    const replaceable_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "tail\n",
        .subagent_status,
    );
    const pruned_detail: RecordedWriteToolDetailFixture = .{
        .entry_id = existing_id,
        .tool_name = "read_file",
        .arguments_json = "{\"path\":\"old\"}",
        .result = "old result",
        .result_handle = "old-result.txt",
        .turn_id = 1,
        .call_id = "call-old",
        .command_output_entry_id = existing_id,
    };
    const retained_detail: RecordedWriteToolDetailFixture = .{
        .entry_id = replaceable_id,
        .tool_name = "write_file",
        .arguments_json = "{\"path\":\"tail\"}",
        .result = "tail result",
        .result_handle = "tail-result.txt",
        .turn_id = 2,
        .call_id = "call-tail",
        .command_output_entry_id = replaceable_id,
    };
    const retained_command_output: RecordedWriteCommandOutputFixture = .{
        .entry_id = replaceable_id,
        .turn_id = 3,
        .call_id = "call-command-tail",
        .line = "x",
    };
    try appendRecordedWriteToolDetailFixture(&runtime, alloc, pruned_detail);
    try appendRecordedWriteToolDetailFixture(&runtime, alloc, retained_detail);
    try appendRecordedWriteCommandOutputFixture(&runtime, alloc, retained_command_output);
    runtime.cursor_row = 2;
    runtime.cursor_col = 4;
    runtime.replaceable_last_line = true;
    runtime.replaceable_start = 0;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const replaceable_before = runtime.replaceable_last_line;
    const replaceable_start_before = runtime.replaceable_start;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();
    const transcript_before = "tail\n";
    try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);

    var metrics = Metrics{};
    const entry_id = transcript_writer.writeTranscriptReturningEntryIdClassified(
        &runtime,
        alloc,
        &metrics,
        "first\nsecond\n",
        true,
        .question_resolution,
    ) catch |err| {
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(existing_id, runtime.entries.items[0].id());
        try std.testing.expectEqualStrings("old\n", runtime.entries.items[0].raw_bytes.bytes);
        try std.testing.expectEqual(replaceable_id, runtime.entries.items[1].id());
        try std.testing.expectEqualStrings("tail\n", runtime.entries.items[1].raw_bytes.bytes);
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(replaceable_before, runtime.replaceable_last_line);
        try std.testing.expectEqual(replaceable_start_before, runtime.replaceable_start);
        try std.testing.expectEqual(@as(usize, 2), runtime.tool_details.items.len);
        try expectRecordedWriteToolDetailFixture(&runtime, pruned_detail);
        try expectRecordedWriteToolDetailFixture(&runtime, retained_detail);
        try expectRecordedWriteCommandOutputFixture(&runtime, retained_command_output);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return err;
    };

    try std.testing.expectEqual(@as(u32, 3), entry_id);
    try std.testing.expectEqual(@as(u32, 4), runtime.next_entry_id);
    try std.testing.expectEqual(@as(usize, 2), runtime.entries.items.len);
    try std.testing.expectEqual(replaceable_id, runtime.entries.items[0].id());
    try std.testing.expectEqual(entry_id, runtime.entries.items[1].id());
    try std.testing.expectEqual(RawEntryClass.question_resolution, runtime.entries.items[1].raw_bytes.class);
    try std.testing.expectEqualStrings("first\nsecond\n", runtime.entries.items[1].raw_bytes.bytes);
    try std.testing.expectEqualStrings("second\n", runtime.transcript.items);
    try std.testing.expect(!runtime.replaceable_last_line);
    try std.testing.expectEqual(@as(usize, 0), runtime.replaceable_start);
    try std.testing.expectEqual(@as(usize, 1), runtime.tool_details.items.len);
    try std.testing.expect(runtime.toolDetailForEntry(existing_id) == null);
    try expectRecordedWriteToolDetailFixture(&runtime, retained_detail);
    try expectRecordedWriteCommandOutputFixture(&runtime, retained_command_output);
    try std.testing.expectEqual(@as(usize, 1), runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}



fn checkContextNoticeAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(40, 12, 8) };
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "visible-before\n",
        .subagent_status,
    );
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    _ = transcript_store.appendSemanticNoticeAtomic(
        &runtime,
        alloc,
        .{
            .topic = "context",
            .tone = .warning,
            .body = "hidden-context",
            .visibility = .full_only,
        },
    ) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
        try std.testing.expectEqual(RawEntryClass.subagent_status, runtime.entries.items[0].raw_bytes.class);
        try std.testing.expectEqualStrings("visible-before\n", runtime.entries.items[0].raw_bytes.bytes);
        try std.testing.expectEqualStrings("visible-before\n", runtime.transcript.items);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return err;
    };

    try std.testing.expectEqual(@as(usize, 2), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[1] == .semantic_notice);
    try std.testing.expectEqualStrings("context", runtime.entries.items[1].semantic_notice.topic);
    try std.testing.expectEqualStrings("hidden-context", runtime.entries.items[1].semantic_notice.body);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, runtime.entries.items[1].semantic_notice.visibility);
    try std.testing.expectEqualStrings("visible-before\n", runtime.transcript.items);
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}



const RecordedCommandOutputAtomicFixture = struct {
    lifecycle_id: types.ToolLifecycleId,
    status_entry_id: u32,
};

fn setupRecordedCommandOutputAtomicFixture(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
) !RecordedCommandOutputAtomicFixture {
    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 71,
        .call_id = "atomic-command-output",
    };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = lifecycle_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf atomic\"}",
    } });
    const status_entry_id = runtime.toolActivityRecord(lifecycle_id).?.entry_id;
    runtime.full_transcript.depth = .full;
    runtime.full_transcript.scroll_rows = 3;
    runtime.full_transcript.follow_tail = false;
    runtime.full_transcript.anchor_entry_id = status_entry_id;
    runtime.full_transcript.anchor_pending = true;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;
    return .{
        .lifecycle_id = lifecycle_id,
        .status_entry_id = status_entry_id,
    };
}

fn expectRecordedCommandOutputAnchor(
    runtime: *const TranscriptRuntime,
    entry_id: u32,
) !void {
    try std.testing.expect(runtime.full_transcript.depth.active());
    try std.testing.expectEqual(@as(u32, 3), runtime.full_transcript.scroll_rows);
    try std.testing.expect(!runtime.full_transcript.follow_tail);
    try std.testing.expectEqual(entry_id, runtime.full_transcript.anchor_entry_id.?);
    try std.testing.expect(runtime.full_transcript.anchor_pending);
}




fn checkVisibleRecordedCommandOutputAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
    };
    defer runtime.deinit(alloc);
    const fixture = try setupRecordedCommandOutputAtomicFixture(&runtime, alloc);

    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const repaint_count_before = runtime.render_requests.pendingReasonCount();
    var metrics = Metrics{};
    const styles = commandOutputAnsiTestStyles();

    runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stdout,
        "visible\n",
        true,
    ) catch |err| {
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(@as(usize, 0), runtime.command_output_blocks.items.len);
        try std.testing.expect(runtime.command_output_display.open_command_block == null);
        try std.testing.expectEqualDeep(command_output_runtime.CommandOutputRenderPolicy{}, runtime.command_output_render);
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expect(runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id == null);
        try expectRecordedCommandOutputAnchor(&runtime, fixture.status_entry_id);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqual(entry_count_before + 1, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before +% 1, runtime.next_entry_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expect(command_output_runtime.sameLifecycleId(block.lifecycle_id, fixture.lifecycle_id));
    try std.testing.expectEqual(@as(usize, 1), block.lines.items.len);
    try std.testing.expectEqual(command_output_content.Stream.stdout, block.lines.items[0].stream);
    try std.testing.expectEqualStrings("visible", block.lines.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), block.live_entry_ids.items.len);
    try std.testing.expectEqual(runtime.entries.items[entry_count_before].id(), block.live_entry_ids.items[0]);
    try std.testing.expectEqual(RawEntryClass.command_output, runtime.entries.items[entry_count_before].raw_bytes.class);
    try std.testing.expectEqualStrings("\x1b[2m│ visible\x1b[0m", runtime.entries.items[entry_count_before].raw_bytes.bytes);
    try std.testing.expectEqualDeep(styles, runtime.command_output_render.styles);
    try std.testing.expectEqual(@as(?usize, 0), runtime.command_output_display.open_command_block);
    try std.testing.expect(runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id == null);
    try expectRecordedCommandOutputAnchor(&runtime, fixture.status_entry_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

fn checkVisibleRecordedCommandOutputAllocationFailures(alloc: Allocator) !void {
    return checkVisibleRecordedCommandOutputAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}


fn checkRecordedCommandOutputConsolidationAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
    };
    defer runtime.deinit(alloc);
    const fixture = try setupRecordedCommandOutputAtomicFixture(&runtime, alloc);
    var metrics = Metrics{};
    const styles = commandOutputAnsiTestStyles();

    runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stdout,
        "one\n",
        true,
    ) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
    runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stderr,
        "two\n",
        true,
    ) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };

    const first_live_entry_id = runtime.command_output_blocks.items[0].live_entry_ids.items[0];
    runtime.full_transcript.anchor_entry_id = first_live_entry_id;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;
    const rendered_before = try renderEntriesToBytes(std.testing.allocator, runtime.entries.items, 80);
    defer std.testing.allocator.free(rendered_before);
    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const repaint_count_before = runtime.render_requests.pendingReasonCount();

    runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        true,
    ) catch |err| {
        const rendered_after_failure = try renderEntriesToBytes(
            std.testing.allocator,
            runtime.entries.items,
            80,
        );
        defer std.testing.allocator.free(rendered_after_failure);
        try std.testing.expectEqualStrings(rendered_before, rendered_after_failure);
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
        const block = runtime.command_output_blocks.items[0];
        try std.testing.expect(block.entry_id == null);
        try std.testing.expectEqual(@as(usize, 2), block.live_entry_ids.items.len);
        try std.testing.expectEqual(@as(usize, 0), block.source_entry_ids.items.len);
        try std.testing.expectEqual(@as(?usize, 0), runtime.command_output_display.open_command_block);
        try std.testing.expect(runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id == null);
        try expectRecordedCommandOutputAnchor(&runtime, first_live_entry_id);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    const rendered_after = try renderEntriesToBytes(std.testing.allocator, runtime.entries.items, 80);
    defer std.testing.allocator.free(rendered_after);
    try std.testing.expectEqualStrings(rendered_before, rendered_after);
    try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
    try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expect(block.entry_id != null);
    try std.testing.expectEqual(@as(usize, 0), block.live_entry_ids.items.len);
    try std.testing.expectEqual(@as(usize, 2), block.source_entry_ids.items.len);
    try std.testing.expectEqualStrings("one", block.lines.items[0].text);
    try std.testing.expectEqualStrings("two", block.lines.items[1].text);
    try std.testing.expect(runtime.command_output_display.open_command_block == null);
    try std.testing.expectEqual(block.entry_id, runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id);
    try expectRecordedCommandOutputAnchor(&runtime, first_live_entry_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

fn checkRecordedCommandOutputConsolidationAllocationFailures(alloc: Allocator) !void {
    return checkRecordedCommandOutputConsolidationAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}




















fn lifecycleTestRuntime(max_retained_bytes: ?usize) TranscriptRuntime {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 24, 20),
    };
    if (max_retained_bytes) |value| runtime.max_retained_transcript_bytes = value;
    return runtime;
}

fn lifecycleId(turn_id: u64, call_id: []const u8) types.ToolLifecycleId {
    return .{ .turn_id = turn_id, .call_id = call_id };
}

fn startLifecycle(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    turn_id: u64,
    call_id: []const u8,
) !u32 {
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = lifecycleId(turn_id, call_id),
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    return runtime.toolActivityRecord(lifecycleId(turn_id, call_id)).?.entry_id;
}



fn checkCompactParallelFallbackAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    const ids = [_]types.ToolLifecycleId{
        lifecycleId(1, "provisional-a"),
        lifecycleId(1, "provisional-b"),
    };
    var entry_ids: [ids.len]u32 = undefined;
    for (ids, 0..) |id, index| {
        _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
            .id = id,
            .tool_name = "read_file",
            .activity_kind = .read,
        } });
        entry_ids[index] = runtime.toolActivityRecord(id).?.entry_id;
    }

    var source_before = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer source_before.deinit(std.testing.allocator);
    _ = runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 1,
        .outcome = .completed,
    } }) catch |err| {
        var source_after = try runtime.prepareTranscriptSource(std.testing.allocator, null);
        defer source_after.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(source_before.bytes, source_after.bytes);
        for (ids) |id| {
            try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .provisional);
        }
        return err;
    };

    var rendered = try runtime.prepareTranscriptSource(alloc, null);
    defer rendered.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        rendered.bytes,
        "2 tool calls · 2 read · 2 not executed",
    ) != null);
    try std.testing.expect(std.mem.find(u8, rendered.bytes, "running") == null);
    for (entry_ids) |entry_id| {
        try std.testing.expectEqual(
            types.ToolOutcomeKind.completed,
            runtime.toolDetailForEntry(entry_id).?.outcome.?,
        );
        try std.testing.expectEqual(
            transcript_blocks.ToolFallbackDisposition.not_executed,
            runtime.toolDetailForEntry(entry_id).?.fallback_disposition.?,
        );
    }
}

fn checkCompactParallelFallbackAllocationFailures(alloc: Allocator) !void {
    return checkCompactParallelFallbackAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}


fn prepareTurnFinishedAnchor(runtime: *TranscriptRuntime, alloc: Allocator) !void {
    try runtime.enableShadowVt(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "pre 0\npre 1\npre 2\npre 3\npre 4\npre 5\n",
        .subagent_status,
    );
    _ = try startLifecycle(runtime, alloc, 1, "unfinished");
    try installStableAnchorForTest(
        runtime,
        alloc,
        runtime.transcript.items,
        testSelection(0),
        0,
        4,
        1,
        1,
    );
}



















fn expectRawEntryBytes(
    runtime: *const TranscriptRuntime,
    entry_id: u32,
    expected: []const u8,
) !void {
    for (runtime.entries.items) |entry| {
        if (entry == .raw_bytes and entry.raw_bytes.id == entry_id) {
            try std.testing.expectEqualStrings(expected, entry.raw_bytes.bytes);
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn transcriptContainsEntry(runtime: *const TranscriptRuntime, entry_id: u32) bool {
    for (runtime.entries.items) |entry| {
        if (entry.id() == entry_id) return true;
    }
    return false;
}

fn checkLifecycleRepositionAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "ALLOCATION TRANSCRIPT 01\n" ++
            "ALLOCATION TRANSCRIPT 02\n" ++
            "ALLOCATION TRANSCRIPT 03\n" ++
            "ALLOCATION TRANSCRIPT 04\n" ++
            "ALLOCATION TRANSCRIPT 05\n" ++
            "ALLOCATION TRANSCRIPT 06\n",
        .subagent_status,
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );

    const id = lifecycleId(93, "allocation-command");
    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "permissions",
        .tone = .success,
        .body = "Auto agent approved this request: Running command.",
        .visibility = .full_only,
    });

    var source_before = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer source_before.deinit(std.testing.allocator);
    const diagnostic_before = runtime.transcriptCommitDiagnostic();
    _ = runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"seq 1 1\"}",
        .place_after_current_transcript = true,
    } }) catch |err| {
        var source_after = try runtime.prepareTranscriptSource(std.testing.allocator, null);
        defer source_after.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(source_before.bytes, source_after.bytes);
        try std.testing.expectEqualDeep(
            diagnostic_before,
            runtime.transcriptCommitDiagnostic(),
        );
        try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .provisional);
        return err;
    };

    try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .authoritative);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
}

fn checkLifecycleRepositionAllocationFailures(alloc: Allocator) !void {
    return checkLifecycleRepositionAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}




fn checkLifecycleAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(64);
    defer runtime.deinit(alloc);
    const existing = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "existing transcript state\n",
        .subagent_status,
    );
    const entry_id = startLifecycle(&runtime, alloc, 1, "transaction") catch |err| {
        try std.testing.expectEqual(@as(usize, 0), runtime.toolActivityRecordCount());
        try std.testing.expectEqual(@as(usize, 0), runtime.lifecyclePinCount());
        try expectRawEntryBytes(&runtime, existing, "existing transcript state\n");
        return err;
    };
    _ = runtime.applyToolLifecycle(alloc, .{ .progress = .{
        .id = lifecycleId(1, "transaction"),
        .text = "● Reading updated",
    } }) catch |err| {
        try std.testing.expect(runtime.isLifecyclePinned(entry_id));
        try std.testing.expect(std.mem.find(
            u8,
            runtime.toolStatusEntryLabel(entry_id).?,
            "updated",
        ) == null);
        return err;
    };
    _ = runtime.applyToolLifecycle(alloc, .{
        .turn_finished = .{ .turn_id = 1, .outcome = .completed },
    }) catch |err| {
        try expectRawEntryBytes(&runtime, entry_id, "● Reading updated\n");
        try std.testing.expect(runtime.isLifecyclePinned(entry_id));
        return err;
    };
    runtime.finishLifecycleBatch(alloc) catch |err| {
        try std.testing.expect(runtime.toolActivityRecord(lifecycleId(1, "transaction")) != null);
        try std.testing.expect(runtime.isLifecyclePinned(entry_id));
        return err;
    };
    try std.testing.expect(runtime.toolActivityRecord(lifecycleId(1, "transaction")) == null);
    try std.testing.expect(!runtime.isLifecyclePinned(entry_id));
}

fn checkLifecycleAllocationFailures(alloc: Allocator) !void {
    return checkLifecycleAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}


fn checkLateTerminalFallbackAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    const id = lifecycleId(1, "late-terminal");

    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 1,
        .outcome = .completed,
    } });

    _ = runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Late completion" },
        .result = "late result",
    } }) catch |err| {
        try expectRawEntryBytes(&runtime, entry_id, "● Tool was not executed\n");
        const detail = runtime.toolDetailForEntry(entry_id).?;
        try std.testing.expect(detail.result == null);
        try std.testing.expectEqual(
            transcript_blocks.ToolFallbackDisposition.not_executed,
            detail.fallback_disposition.?,
        );
        var compact = try runtime.prepareTranscriptSource(std.testing.allocator, null);
        defer compact.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.find(u8, compact.bytes, "1 not executed") != null);
        return err;
    };

    var expected: [128]u8 = undefined;
    try expectRawEntryBytes(&runtime, entry_id, try std.fmt.bufPrint(
        &expected,
        "{s}●{s} Late completion\n",
        .{ ui_render.system_notice_text_style, ui_render.reset_style },
    ));
    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqualStrings("late result", detail.result.?);
    try std.testing.expect(detail.fallback_disposition == null);
    var compact = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer compact.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "1 not executed") == null);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "Late completion") != null);
}

fn checkLateTerminalFallbackAllocationFailures(alloc: Allocator) !void {
    return checkLateTerminalFallbackAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}


fn checkProvisionalTerminalAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    const id = lifecycleId(1, "provisional-terminal");

    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const entries_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;

    _ = runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Read provisional file" },
        .result = "provisional result",
    } }) catch |err| {
        try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .provisional);
        try std.testing.expectEqual(entries_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        const detail = runtime.toolDetailForEntry(entry_id).?;
        try std.testing.expectEqualStrings("read_file", detail.tool_name);
        try std.testing.expectEqual(types.ToolActivityKind.read, detail.activity_kind.?);
        try std.testing.expect(detail.result == null);
        try std.testing.expect(detail.outcome == null);
        const status = runtime.toolStatusEntryLabel(entry_id).?;
        try std.testing.expect(std.mem.find(u8, status, "read_file") != null);
        try std.testing.expect(std.mem.find(u8, status, "Read provisional file") == null);
        return err;
    };

    try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .terminal);
    try std.testing.expectEqual(entries_before, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqualStrings("read_file", detail.tool_name);
    try std.testing.expectEqualStrings("provisional result", detail.result.?);
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.outcome.?);
}

fn checkProvisionalTerminalAllocationFailures(alloc: Allocator) !void {
    return checkProvisionalTerminalAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}


fn checkCommandProcessTerminalAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    const id = lifecycleId(1, "command-process-terminal");

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"true\"}",
    } });
    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const entries_before = runtime.entries.items.len;
    const blocks_before = runtime.command_output_blocks.items.len;
    const next_entry_id_before = runtime.next_entry_id;

    _ = runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran true" },
        .result_memory = .{ .command_process_presentation = .{ .exit_code = 0 } },
    } }) catch |err| {
        try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .authoritative);
        try std.testing.expectEqual(entries_before, runtime.entries.items.len);
        try std.testing.expectEqual(blocks_before, runtime.command_output_blocks.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        const detail = runtime.toolDetailForEntry(entry_id).?;
        try std.testing.expect(detail.command_process_presentation == null);
        try std.testing.expect(detail.command_output_entry_id == null);
        const status = runtime.toolStatusEntryLabel(entry_id).?;
        try std.testing.expect(std.mem.find(u8, status, "run_command") != null);
        try std.testing.expect(std.mem.find(u8, status, "Ran true") == null);
        return err;
    };

    try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .terminal);
    try std.testing.expectEqual(entries_before + 1, runtime.entries.items.len);
    try std.testing.expectEqual(blocks_before + 1, runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(next_entry_id_before + 1, runtime.next_entry_id);
    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .exit_code = 0 },
        detail.command_process_presentation.?,
    );
    try std.testing.expectEqual(next_entry_id_before, detail.command_output_entry_id.?);
    try std.testing.expectEqual(next_entry_id_before, runtime.command_output_blocks.items[0].entry_id.?);
}

fn checkCommandProcessTerminalAllocationFailures(alloc: Allocator) !void {
    return checkCommandProcessTerminalAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}



const call_ids = [_][]const u8{ "first", "second" };













fn applyCompletedReadForFinalityTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    turn_id: u64,
    call_id: []const u8,
    presentation_group_id: ?types.ToolPresentationGroupId,
) !void {
    const id = types.ToolLifecycleId{ .turn_id = turn_id, .call_id = call_id };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .presentation_group_id = presentation_group_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Read finality fixture" },
    } });
}



