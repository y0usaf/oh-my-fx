const std = @import("std");
const activity_status = @import("../core/output/activity_status.zig");
const paint_plan = @import("render_engine/paint_plan.zig");

pub const Reason = enum {
    first_frame,
    transcript,
    footer,
    modal,
    subagent_panel,
    animation,
    notification,
    resize,
    external_damage,
};

pub const ReasonSet = std.EnumSet(Reason);

pub const AnimationCandidate = struct {
    generation: u64,
    phase: i16,
};

pub const AttemptSnapshot = struct {
    reasons: ReasonSet = .empty,
    invalidations: paint_plan.FrameInvalidationSet = paint_plan.FrameInvalidationSet.empty(),
    animation_candidate: ?AnimationCandidate = null,
};

pub const BeginAttemptError = error{AttemptInProgress};
/// Owns the captured request until commit. Deinit restores unfinished work.
pub const FrameAttempt = struct {
    state: *RenderRequestState,
    snapshot: AttemptSnapshot,
    active: bool = true,

    pub fn deinit(self: *FrameAttempt) void {
        if (self.active) self.restore();
    }

    pub fn restore(self: *FrameAttempt) void {
        std.debug.assert(self.active);
        self.state.restoreAttemptAssumeActive(self.snapshot);
        self.active = false;
    }

    pub fn commit(
        self: *FrameAttempt,
        committed_at_ms: i64,
        interval_ms: i64,
        animation_visible: bool,
    ) void {
        std.debug.assert(self.active);
        self.state.commitAttemptAssumeActive(
            self.snapshot,
            committed_at_ms,
            interval_ms,
            animation_visible,
        );
        self.active = false;
    }
};

pub const animation_padding: i16 = 8;
// Fixed 40-frame cycle (-8..31): two 20-frame marker pulses per wrap, so the
// pulse phase stays seamless regardless of the animated label's length.
const animation_max_phase: i16 = 31;
pub const animation_interval_ms: i64 = 50;
pub const max_consecutive_input_pending_aborts: u8 = 4;
/// Marker blink half-period: 10 frames on, 10 frames off at the 50ms cadence,
/// matching the 1s period of the wall-clock-synced activity blink.
pub const blink_half_period_frames: i16 = 10;

comptime {
    // The blink must complete whole on/off periods within one phase cycle or
    // the marker visibly stutters at the wrap.
    const cycle = animation_max_phase + animation_padding + 1;
    std.debug.assert(@mod(cycle, 2 * blink_half_period_frames) == 0);
    // Frame-phase blink (tool markers) and the wall-clock activity blink must
    // share one tempo or the two markers drift visibly apart.
    std.debug.assert(
        blink_half_period_frames * animation_interval_ms == activity_status.activity_blink_half_period_ms,
    );
}

fn nextAnimationPhase(phase: i16) i16 {
    const next = phase + 1;
    if (next > animation_max_phase) return -animation_padding;
    return next;
}

pub const RenderRequestState = struct {
    pending_reasons: ReasonSet = .empty,
    pending_invalidations: paint_plan.FrameInvalidationSet = paint_plan.FrameInvalidationSet.empty(),
    attempt_active: bool = false,
    attempt_has_invalidations: bool = false,
    attempt_affects_approval: bool = false,
    frame_admission_block_depth: usize = 0,
    resize_dirty: bool = false,
    resize_apply_after_ms: i64 = 0,
    pending_settled_width_reflow: bool = false,
    committed_animation_phase: i16 = -8,
    animation_next_deadline_ms: i64 = 0,
    animation_visible: bool = false,
    animation_candidates: [2]AnimationCandidate = undefined,
    animation_candidate_len: u8 = 0,
    animation_candidate_in_flight: bool = false,
    next_animation_generation: u64 = 1,
    consecutive_input_pending_aborts: u8 = 0,

    pub fn request(self: *RenderRequestState, reason: Reason) void {
        self.pending_reasons.insert(reason);
    }

    pub fn requestInvalidation(
        self: *RenderRequestState,
        range: paint_plan.FrameInvalidationRange,
    ) void {
        _ = self.pending_invalidations.appendOrCollapse(range);
        self.request(switch (range.reason) {
            .resize => .resize,
            else => .external_damage,
        });
    }

    pub fn hasPending(self: RenderRequestState) bool {
        return self.pending_reasons.count() > 0 or
            !self.pending_invalidations.isEmpty() or
            self.animation_candidate_len > 0;
    }

    pub fn hasReason(self: RenderRequestState, reason: Reason) bool {
        return self.pending_reasons.contains(reason);
    }

    pub fn clearReason(self: *RenderRequestState, reason: Reason) void {
        self.pending_reasons.remove(reason);
    }

    pub fn attemptHasInvalidations(self: RenderRequestState) bool {
        return self.attempt_active and self.attempt_has_invalidations;
    }

    pub fn pendingReasonCount(self: RenderRequestState) usize {
        return self.pending_reasons.count();
    }

    pub fn pendingInvalidations(self: RenderRequestState) paint_plan.FrameInvalidationSet {
        return self.pending_invalidations;
    }

    pub fn permitsInputPendingAbort(self: RenderRequestState) bool {
        return self.consecutive_input_pending_aborts < max_consecutive_input_pending_aborts;
    }

    pub fn noteInputPendingAbort(self: *RenderRequestState) void {
        self.consecutive_input_pending_aborts +|= 1;
    }

    pub fn resetInputPendingAbortStreak(self: *RenderRequestState) void {
        self.consecutive_input_pending_aborts = 0;
    }

    pub fn settledForApproval(self: RenderRequestState) bool {
        return !reasonsAffectApproval(self.pending_reasons) and
            self.pending_invalidations.isEmpty() and
            !self.attempt_affects_approval and
            !self.resizeLifecyclePending();
    }

    pub fn replacePendingInvalidation(
        self: *RenderRequestState,
        range: paint_plan.FrameInvalidationRange,
    ) void {
        self.pending_invalidations.replaceWith(range);
        self.request(switch (range.reason) {
            .resize => .resize,
            else => .external_damage,
        });
    }

    /// Drop deferred row ranges without clearing other pending reasons.
    /// Used when a full terminal reset makes prior geometry obsolete.
    pub fn clearPendingInvalidations(self: *RenderRequestState) void {
        self.pending_invalidations = paint_plan.FrameInvalidationSet.empty();
    }

    pub fn observeResizeSignal(self: *RenderRequestState, now_ms: i64, debounce_ms: i64) void {
        self.resize_dirty = true;
        self.resize_apply_after_ms = now_ms + debounce_ms;
        self.request(.resize);
    }

    pub fn completeResizeGeometry(
        self: *RenderRequestState,
        requires_settled_replay: bool,
    ) void {
        self.resize_dirty = false;
        if (requires_settled_replay) {
            self.pending_settled_width_reflow = true;
        }
    }

    pub fn acknowledgeSettledResizeCommit(self: *RenderRequestState) void {
        self.pending_settled_width_reflow = false;
    }

    pub fn resizeLifecyclePending(self: RenderRequestState) bool {
        return self.resize_dirty or self.pending_settled_width_reflow;
    }

    pub fn shouldApplyDeferredResize(self: RenderRequestState, now_ms: i64) bool {
        return self.resize_dirty and now_ms >= self.resize_apply_after_ms;
    }

    pub fn blocksFrameCommit(self: RenderRequestState) bool {
        return self.resize_dirty or self.frame_admission_block_depth > 0;
    }

    pub fn beginFrameAdmissionBlock(self: *RenderRequestState) void {
        self.frame_admission_block_depth += 1;
    }

    pub fn endFrameAdmissionBlock(self: *RenderRequestState) void {
        std.debug.assert(self.frame_admission_block_depth > 0);
        self.frame_admission_block_depth -= 1;
    }

    pub fn requestAnimationDue(self: *RenderRequestState, now_ms: i64) bool {
        if (!self.animation_visible or self.animation_next_deadline_ms == 0) return false;
        if (now_ms < self.animation_next_deadline_ms) return false;
        if (self.animation_candidate_in_flight or self.animation_candidate_len > 0) return false;

        self.animation_candidates[0] = .{
            .generation = self.next_animation_generation,
            .phase = nextAnimationPhase(self.committed_animation_phase),
        };
        self.animation_candidate_len = 1;
        self.next_animation_generation +%= 1;
        self.request(.animation);
        return true;
    }

    pub fn requestAnimationReset(self: *RenderRequestState) void {
        const candidate = AnimationCandidate{
            .generation = self.next_animation_generation,
            .phase = -animation_padding,
        };
        self.next_animation_generation +%= 1;

        if (self.animation_candidate_len > 0) {
            self.animation_candidates[self.animation_candidate_len - 1] = candidate;
        } else {
            self.animation_candidates[0] = candidate;
            self.animation_candidate_len = 1;
        }
        self.request(.animation);
    }

    pub fn visibleAnimationPhase(self: RenderRequestState) i16 {
        return self.committed_animation_phase;
    }

    pub fn beginAttempt(self: *RenderRequestState) BeginAttemptError!?FrameAttempt {
        if (self.attempt_active) return error.AttemptInProgress;
        if (self.blocksFrameCommit() or !self.hasPending()) return null;

        self.attempt_active = true;
        var snapshot = AttemptSnapshot{
            .reasons = self.pending_reasons,
            .invalidations = self.pending_invalidations,
        };
        self.attempt_has_invalidations = !snapshot.invalidations.isEmpty();
        self.attempt_affects_approval =
            reasonsAffectApproval(snapshot.reasons) or
            self.attempt_has_invalidations;
        self.pending_reasons = .empty;
        self.pending_invalidations = paint_plan.FrameInvalidationSet.empty();

        if (self.animation_candidate_len > 0) {
            snapshot.animation_candidate = self.animation_candidates[0];
            self.removeFirstAnimationCandidate();
            snapshot.reasons.insert(.animation);
            self.animation_candidate_in_flight = true;
        }
        if (self.animation_candidate_len > 0) self.pending_reasons.insert(.animation);
        return .{ .state = self, .snapshot = snapshot };
    }

    fn commitAttemptAssumeActive(
        self: *RenderRequestState,
        snapshot: AttemptSnapshot,
        committed_at_ms: i64,
        interval_ms: i64,
        animation_visible: bool,
    ) void {
        std.debug.assert(self.attempt_active);
        const was_visible = self.animation_visible;

        if (snapshot.animation_candidate) |candidate| {
            self.committed_animation_phase = candidate.phase;
        }
        self.animation_visible = animation_visible;
        if (!animation_visible) {
            self.committed_animation_phase = -animation_padding;
            self.animation_next_deadline_ms = 0;
        } else if (snapshot.animation_candidate != null or !was_visible or self.animation_next_deadline_ms == 0) {
            self.animation_next_deadline_ms = committed_at_ms + interval_ms;
        }

        self.animation_candidate_in_flight = false;
        self.attempt_has_invalidations = false;
        self.attempt_affects_approval = false;
        self.attempt_active = false;
        self.resetInputPendingAbortStreak();
    }

    fn restoreAttemptAssumeActive(
        self: *RenderRequestState,
        snapshot: AttemptSnapshot,
    ) void {
        std.debug.assert(self.attempt_active);
        self.pending_reasons.setUnion(snapshot.reasons);
        for (snapshot.invalidations.ranges()) |range| {
            _ = self.pending_invalidations.appendOrCollapse(range);
        }
        if (snapshot.animation_candidate) |candidate| {
            // Capture removes one slot; resets during the attempt only replace the remaining slot.
            std.debug.assert(self.animation_candidate_len < self.animation_candidates.len);
            var i: usize = self.animation_candidate_len;
            while (i > 0) : (i -= 1) {
                self.animation_candidates[i] = self.animation_candidates[i - 1];
            }
            self.animation_candidates[0] = candidate;
            self.animation_candidate_len += 1;
            self.pending_reasons.insert(.animation);
        }

        self.animation_candidate_in_flight = false;
        self.attempt_has_invalidations = false;
        self.attempt_affects_approval = false;
        self.attempt_active = false;
    }

    fn removeFirstAnimationCandidate(self: *RenderRequestState) void {
        if (self.animation_candidate_len == 0) return;
        var i: usize = 1;
        while (i < self.animation_candidate_len) : (i += 1) {
            self.animation_candidates[i - 1] = self.animation_candidates[i];
        }
        self.animation_candidate_len -= 1;
    }
};

fn reasonsAffectApproval(reasons: ReasonSet) bool {
    var relevant = reasons;
    relevant.remove(.animation);
    relevant.remove(.notification);
    return relevant.count() > 0;
}






fn failFramePreparation(
    state: *RenderRequestState,
    alloc: std.mem.Allocator,
) !void {
    var attempt = (try state.beginAttempt()).?;
    defer attempt.deinit();

    state.request(.modal);
    const scratch = try alloc.alloc(u8, 1);
    defer alloc.free(scratch);
}









