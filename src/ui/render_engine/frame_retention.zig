const std = @import("std");
const frame_cell_match = @import("frame_cell_match.zig");
const frame_layout = @import("frame_layout.zig");
const frame_scroll_plan = @import("frame_scroll_plan.zig");
const frame_surface = @import("frame_surface.zig");
const paint_plan = @import("paint_plan.zig");
const terminal_diff = @import("terminal_diff.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;

pub const RetainedTranscriptBody = struct {
    source_area: frame_layout.FrameRect,
    occupied_last_row: u16,
};

pub const TranscriptBodyDisposition = union(enum) {
    paint,
    retain: RetainedTranscriptBody,
};

pub const StableRetainCandidate = struct {
    full_transcript_active: bool = false,
    committed_layout_id: u64,
    committed_flow: []const u8,
    committed_occupied_last_row: u16,
    source_layout: frame_layout.CommittedLayoutSnapshot,
    source_bytes: []const u8,
    target_layout: frame_layout.CommittedLayoutSnapshot,
    scroll_plan: frame_scroll_plan.FrameScrollPlan,
    destructive_invalidation: bool = false,
    activity_overlay_active: bool = false,
};

pub fn stableRetainedTranscriptBody(candidate: StableRetainCandidate) ?RetainedTranscriptBody {
    if (!candidateHasStableSource(candidate)) return null;
    return retainedCandidateBody(candidate);
}

fn candidateHasStableSource(candidate: StableRetainCandidate) bool {
    if (candidate.full_transcript_active) return false;
    if (candidate.committed_layout_id != candidate.source_layout.layout_id) return false;
    return std.mem.eql(u8, candidate.source_bytes, candidate.committed_flow);
}

fn retainedCandidateBody(candidate: StableRetainCandidate) ?RetainedTranscriptBody {
    if (candidate.scroll_plan.terminal_scroll_rows != 0) return null;
    if (!sameTerminalGeometry(candidate.source_layout, candidate.target_layout)) return null;
    const retained = retainedBodyForTarget(
        candidate.source_layout.transcript_area,
        candidate.target_layout.transcript_area,
        candidate.committed_occupied_last_row,
    ) orelse return null;
    if (candidate.destructive_invalidation or candidate.activity_overlay_active) return null;
    return retained;
}

fn sameTerminalGeometry(
    source: frame_layout.CommittedLayoutSnapshot,
    target: frame_layout.CommittedLayoutSnapshot,
) bool {
    return source.terminal_rows == target.terminal_rows and
        source.terminal_cols == target.terminal_cols;
}

pub fn transcriptAreaHasDestructiveInvalidation(
    area: frame_layout.FrameRect,
    invalidation: paint_plan.FrameInvalidationSet,
) bool {
    if (area.isEmpty()) return false;
    for (invalidation.ranges()) |range| {
        if (range.reason == .owned_band_change) continue;
        if (range.top <= area.bottom and range.bottom >= area.top) return true;
    }
    return false;
}

pub fn validate(
    plan: paint_plan.PaintPlan,
    body_is_transcript: bool,
    movement: terminal_diff.PreparedTerminalMovement,
    retained: RetainedTranscriptBody,
) !void {
    if (!retainedBodyMatchesPlan(plan, body_is_transcript, retained))
        return error.InvalidRetainedTranscriptBody;
    if (!movementKeepsRetainedGrid(movement))
        return error.InvalidRetainedTranscriptBody;
    if (planBlocksRetainedTranscript(plan, retained.source_area))
        return error.InvalidRetainedTranscriptBody;
}

fn retainedBodyMatchesPlan(
    plan: paint_plan.PaintPlan,
    body_is_transcript: bool,
    retained: RetainedTranscriptBody,
) bool {
    if (!body_is_transcript) return false;
    if (!sourceAreaFitsTarget(retained.source_area, rectFromBand(plan.transcript_band))) return false;
    return occupiedRowInsideSourceArea(retained.source_area, retained.occupied_last_row);
}

fn retainedBodyForTarget(
    source_area: frame_layout.FrameRect,
    target_area: frame_layout.FrameRect,
    occupied_last_row: u16,
) ?RetainedTranscriptBody {
    if (!sourceAreaFitsTarget(source_area, target_area)) return null;
    if (!occupiedRowDoesNotOverrunRetainedGrid(source_area, target_area, occupied_last_row)) return null;
    return .{
        .source_area = source_area,
        .occupied_last_row = occupied_last_row,
    };
}

fn sourceAreaFitsTarget(
    source_area: frame_layout.FrameRect,
    target_area: frame_layout.FrameRect,
) bool {
    if (source_area.isEmpty()) return false;
    if (target_area.top != source_area.top) return false;
    return target_area.bottom >= source_area.bottom;
}

fn occupiedRowDoesNotOverrunRetainedGrid(
    source_area: frame_layout.FrameRect,
    target_area: frame_layout.FrameRect,
    occupied_last_row: u16,
) bool {
    if (occupied_last_row > source_area.bottom) return false;
    if (occupied_last_row > target_area.bottom) return false;
    return true;
}

fn occupiedRowInsideSourceArea(
    source_area: frame_layout.FrameRect,
    occupied_last_row: u16,
) bool {
    if (occupied_last_row == 0) return true;
    return source_area.containsRow(occupied_last_row);
}

fn movementKeepsRetainedGrid(movement: terminal_diff.PreparedTerminalMovement) bool {
    return movement.source_rows == movement.target_rows and
        movement.source_cols == movement.target_cols and
        !movement.segments.document_append.hasBytes() and
        !movement.segments.alignment_scroll.hasBytes() and
        movement.segments.terminal_transition.start == 0 and
        movement.segments.terminal_transition.end == movement.bytes.len and
        movement.scroll_rows.planned_scroll_rows == 0;
}

fn planBlocksRetainedTranscript(
    plan: paint_plan.PaintPlan,
    area: frame_layout.FrameRect,
) bool {
    return plan.activity == .overlay_entry or
        transcriptAreaHasDestructiveInvalidation(area, plan.invalidation);
}

fn rectFromBand(band: paint_plan.FrameBand) frame_layout.FrameRect {
    return .{ .top = band.top, .bottom = band.bottom };
}

pub fn countSurfaceChanges(
    baseline: vt_emulator.Grid,
    surface: frame_surface.FrameSurface,
    area: frame_layout.FrameRect,
) usize {
    if (area.isEmpty()) return 0;
    var changed: usize = 0;
    var row = area.top;
    while (row <= area.bottom) : (row += 1) {
        var col: u16 = 1;
        while (col <= surface.cols) : (col += 1) {
            const previous = baseline.cellAt(row, col) orelse continue;
            const next = surface.cellAt(row, col) orelse continue;
            if (!frame_cell_match.gridSurfaceCellsEqual(baseline, previous, surface, next)) changed += 1;
        }
    }
    return changed;
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

fn testMovement(alloc: Allocator, previous: *const vt_emulator.Grid) !terminal_diff.PreparedTerminalMovement {
    return try terminal_diff.prepareTerminalMovement(
        alloc,
        previous,
        .{},
        0,
        previous.cols,
        previous.rows,
    );
}




