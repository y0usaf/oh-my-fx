const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const frame_layout = @import("frame_layout.zig");
const frame_scroll_plan = @import("frame_scroll_plan.zig");

pub const CandidatePreparation = struct {
    inline_advance_rows: u16,
    occupied_transcript_rows: u16,
};

pub const CandidateResolution = struct {
    occupied_transcript_rows: u16,
};

pub const FramePlan = struct {
    layout: frame_layout.FrameLayout,
    scroll_plan: frame_scroll_plan.FrameScrollPlan,
    iterations: usize,
};

pub fn solve(
    comptime Context: type,
    ctx: *Context,
    input: frame_layout.SolveInput,
    prepare_candidate: *const fn (*Context, frame_layout.FrameLayout) anyerror!CandidatePreparation,
    resolve_candidate: *const fn (*Context, frame_layout.FrameLayout, frame_scroll_plan.FrameScrollPlan) anyerror!CandidateResolution,
) !FramePlan {
    var release_floor_rows: u16 = 0;
    var candidate_input = input;
    var previous_candidate: ?struct {
        owned_top: u16,
        effective_transcript_rows: u16,
    } = null;
    var iteration: usize = 0;

    while (true) {
        iteration += 1;
        const layout_release = frame_layout.solveWithPreservedRowRelease(candidate_input, release_floor_rows);
        const candidate = layout_release.layout;
        if (previous_candidate) |previous| {
            const owner_released = candidate.owned_top < previous.owned_top;
            const extent_reduced = candidate_input.transcript.natural_visual_rows < previous.effective_transcript_rows;
            if (candidate.owned_top > previous.owned_top or
                candidate_input.transcript.natural_visual_rows > previous.effective_transcript_rows or
                (!owner_released and !extent_reduced))
            {
                return error.InvalidFrameScrollPlan;
            }
        }
        const preparation = try prepare_candidate(ctx, candidate);
        const scroll_plan = frame_scroll_plan.merge(
            candidate_input.terminal.rows,
            candidate_input.owned_top,
            layout_release.released_rows,
            preparation.inline_advance_rows,
        );
        const prepared_projection_is_shorter = preparation.occupied_transcript_rows > 0 and
            preparation.occupied_transcript_rows < candidate.transcript_area.height();
        const resolution = if (prepared_projection_is_shorter)
            CandidateResolution{ .occupied_transcript_rows = preparation.occupied_transcript_rows }
        else
            try resolve_candidate(ctx, candidate, scroll_plan);
        debug_trace.logf(
            "frame_layout",
            "fixed_point iteration={d} requested_release={d} requested_inline={d} emitted_scroll={d} remaining_inline={d} prior_owned_top={d} post_scroll_owned_top={d}",
            .{
                iteration,
                scroll_plan.requested_release_rows,
                scroll_plan.requested_inline_advance_rows,
                scroll_plan.terminal_scroll_rows,
                scroll_plan.remaining_inline_advance_rows,
                scroll_plan.prior_owned_top,
                scroll_plan.post_scroll_owned_top,
            },
        );
        const projection_is_shorter = resolution.occupied_transcript_rows > 0 and
            resolution.occupied_transcript_rows < candidate.transcript_area.height();
        if (candidate.owned_top == scroll_plan.post_scroll_owned_top and !projection_is_shorter) {
            return .{
                .layout = candidate,
                .scroll_plan = scroll_plan,
                .iterations = iteration,
            };
        }
        previous_candidate = .{
            .owned_top = candidate.owned_top,
            .effective_transcript_rows = candidate_input.transcript.natural_visual_rows,
        };
        if (projection_is_shorter) {
            candidate_input.transcript.natural_visual_rows = resolution.occupied_transcript_rows;
        }
        release_floor_rows = scroll_plan.preserved_release_rows;
    }
}

const FixedPointTestContext = struct {
    inline_advance_rows: u16 = 0,
    prepared_occupied_rows: ?u16 = null,
    resolved_occupied_rows: ?u16 = null,
    candidate_tops: [8]u16 = [_]u16{0} ** 8,
    candidate_transcript_rows: [8]u16 = [_]u16{0} ** 8,
    resolved_inline_rows: [8]u32 = [_]u32{0} ** 8,
    calls: usize = 0,
    resolution_calls: usize = 0,

    fn prepareCandidate(
        self: *FixedPointTestContext,
        layout: frame_layout.FrameLayout,
    ) !CandidatePreparation {
        self.candidate_tops[self.calls] = layout.owned_top;
        self.candidate_transcript_rows[self.calls] = layout.transcript_area.height();
        self.calls += 1;
        return .{
            .inline_advance_rows = self.inline_advance_rows,
            .occupied_transcript_rows = self.prepared_occupied_rows orelse layout.transcript_area.height(),
        };
    }

    fn resolveCandidate(
        self: *FixedPointTestContext,
        layout: frame_layout.FrameLayout,
        scroll_plan: frame_scroll_plan.FrameScrollPlan,
    ) !CandidateResolution {
        self.resolved_inline_rows[self.resolution_calls] = scroll_plan.requested_inline_advance_rows;
        self.resolution_calls += 1;
        return .{
            .occupied_transcript_rows = self.resolved_occupied_rows orelse layout.transcript_area.height(),
        };
    }
};

fn fixedPointTestInput(
    terminal_rows: u16,
    owned_top: u16,
    transcript_rows: u16,
    footer_rows: u16,
    body_mode: frame_layout.BodyMode,
) frame_layout.SolveInput {
    return .{
        .terminal = .{
            .rows = terminal_rows,
            .cols = 80,
            .content_bottom = terminal_rows -| 4,
            .divider_top_row = terminal_rows -| 3,
            .input_row = terminal_rows -| 2,
            .divider_bottom_row = terminal_rows -| 1,
            .hint_row = terminal_rows,
        },
        .owned_top = owned_top,
        .footer = .{
            .natural_rows = footer_rows,
            .min_rows = footer_rows,
            .max_rows = footer_rows,
        },
        .transcript = .{ .natural_visual_rows = transcript_rows },
        .body_mode = body_mode,
    };
}

fn solveFixedPointForTest(
    ctx: *FixedPointTestContext,
    input: frame_layout.SolveInput,
) !FramePlan {
    return solve(
        FixedPointTestContext,
        ctx,
        input,
        FixedPointTestContext.prepareCandidate,
        FixedPointTestContext.resolveCandidate,
    );
}
