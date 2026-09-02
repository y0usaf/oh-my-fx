const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const registered_entities = @import("../input/registered_entities.zig");
const core_input_runtime = @import("../input/runtime.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const visual_layout = @import("../../ui/input/visual_layout.zig");
const sort_utils = @import("../shared/sort_utils.zig");

pub const ReviewEntry = struct {
    draft: worker_runtime.QueuedPromptDraft,
    pasted_blocks: std.ArrayList(paste_blocks.PastedBlock) = .empty,
    image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty,
    dirty: bool = false,

    fn deinit(self: *ReviewEntry, alloc: std.mem.Allocator) void {
        worker_runtime.freeQueuedPromptDraft(alloc, self.draft);
        paste_blocks.deinitBlocks(alloc, &self.pasted_blocks);
        self.image_tokens.deinit(alloc);
    }
};

pub const State = struct {
    entries: []ReviewEntry = &.{},
    selected_index: ?usize = null,
    reason: ?worker_runtime.QueueReviewReason = null,
    visible: bool = false,
    selected_dirty: bool = false,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        self.clear(alloc);
    }

    pub fn clear(self: *State, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        if (self.entries.len > 0) alloc.free(self.entries);
        self.* = .{};
    }

    pub fn active(self: *const State) bool {
        return self.reason != null;
    }
};

pub const VisibleReviewMeasurement = struct {
    card_rows: u16 = 0,
    editor_active: bool = false,
};

pub fn measureVisibleReviewRows(
    alloc: std.mem.Allocator,
    state: *const State,
    editor_source: visual_layout.Source,
) !VisibleReviewMeasurement {
    if (!state.visible or !state.active() or state.entries.len == 0) return .{};

    var result: VisibleReviewMeasurement = .{};
    for (state.entries, 0..) |entry, entry_index| {
        const editing = state.selected_index != null and state.selected_index.? == entry_index;
        const row_count: u16 = if (editing) blk: {
            result.editor_active = true;
            const summary = visual_layout.summarize(editor_source, null);
            break :blk @intCast(@min(@max(summary.total_rows, 1), std.math.maxInt(u16)));
        } else blk: {
            const draft = entry.draft;
            const display_spans = draft.reviewSkillDisplaySpans();
            var skill_tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty;
            defer skill_tokens.deinit(alloc);
            try skill_tokens.ensureTotalCapacity(alloc, display_spans.len);
            for (display_spans) |span| {
                skill_tokens.appendAssumeCapacity(.{
                    .raw_start = span.raw_start,
                    .raw_end = span.raw_end,
                    .name = span.name,
                    .path = span.path,
                    .display_source = span.display_source,
                    .owns_trailing_separator = span.owns_trailing_separator,
                });
            }
            const summary = visual_layout.summarize(.{
                .input = draft.reviewInput(),
                .cursor = 0,
                .terminal_cols = editor_source.terminal_cols,
                .images = draft.images,
                .pasted_blocks = entry.pasted_blocks.items,
                .image_tokens = entry.image_tokens.items,
                .skill_tokens = skill_tokens.items,
            }, null);
            break :blk @intCast(@min(@max(summary.total_rows, 1), std.math.maxInt(u16)));
        };
        result.card_rows +|= row_count;
    }
    return result;
}

pub const PromptAdmission = enum {
    enqueue,
    replaced,
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn requestCancelAndOpen(app: *App) bool {
            return openAfterPause(app, app.worker.requestCancelWithQueueReview());
        }

        pub fn pauseAndOpenAfterModalCancel(app: *App) bool {
            return openAfterPause(app, app.worker.beginQueueReview(.post_cancel));
        }

        pub fn routeVertical(app: *App, direction: visual_layout.Direction) !bool {
            const state = &app.queued_prompt_review;
            if (state.active()) {
                if (state.visible) {
                    const index = state.selected_index orelse return false;
                    switch (direction) {
                        .up => {
                            if (index > 0) {
                                if (state.selected_dirty) try stashSelected(app);
                                state.selected_index = index - 1;
                                loadSelected(app) catch |err| {
                                    state.selected_index = index;
                                    loadSelected(app) catch {};
                                    return err;
                                };
                                traceNavigation(state, "older");
                            }
                        },
                        .down => {
                            if (index + 1 < state.entries.len) {
                                if (state.selected_dirty) try stashSelected(app);
                                state.selected_index = index + 1;
                                loadSelected(app) catch |err| {
                                    state.selected_index = index;
                                    loadSelected(app) catch {};
                                    return err;
                                };
                                traceNavigation(state, "newer");
                            } else {
                                try hideDraft(app);
                            }
                        },
                    }
                    app.shell.render_requests.request(.footer);
                    return true;
                }

                if (direction == .up and composerIsEmpty(app)) {
                    try loadSelected(app);
                    app.shell.render_requests.request(.footer);
                    return true;
                }
                return false;
            }

            if (direction != .up or !composerIsEmpty(app)) return false;
            if (!app.worker.beginQueueReview(.manual)) return false;
            _ = ensureOpen(app, .manual) catch |err| {
                debug_trace.logf("input", "queue review snapshot failed reason=manual err={s}", .{@errorName(err)});
                app.shell.render_requests.request(.footer);
                return true;
            };
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn markVisibleSelectionDirty(app: *App) void {
            if (!app.queued_prompt_review.visible) return;
            app.queued_prompt_review.selected_dirty = true;
        }

        pub fn hideVisibleDraft(app: *App) !bool {
            if (!app.queued_prompt_review.visible) return false;
            try hideDraft(app);
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn cancelAllHiddenPostCancelQueued(app: *App) bool {
            const state = &app.queued_prompt_review;
            if (!postCancelAllAvailable(app)) return false;
            const dropped = state.entries.len;
            app.worker.clearQueuedPrompts(
                app.alloc,
                app.input_runtime.kill_ring.images.items,
            );
            state.clear(app.alloc);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            releasePendingImages(app);
            debug_trace.eventf("input", "queue_review_cancelled_all", .{}, "dropped={d}", .{dropped});
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn postCancelAllAvailable(app: *const App) bool {
            const state = &app.queued_prompt_review;
            return state.active() and
                state.reason.? == .post_cancel and
                !state.visible and
                composerIsEmpty(app);
        }

        pub fn submitPausedQueueUnchanged(app: *App) !bool {
            if (!app.queued_prompt_review.active() and app.worker.queueReviewReason() == null) return false;
            if (!try commitDirtyEntries(app)) return error.QueuedPromptNoLongerAvailable;
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            releasePendingImages(app);
            finishReview(app, "unchanged_queue");
            return true;
        }

        pub fn deleteEmptyVisibleDraft(app: *App) !bool {
            const state = &app.queued_prompt_review;
            if (!state.visible or !composerIsEmpty(app)) return false;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;

            const turn_id = state.entries[index].draft.turn_id;
            if (!app.worker.deleteQueuedPromptDraft(
                app.alloc,
                turn_id,
                app.input_runtime.kill_ring.images.items,
            )) {
                return error.QueuedPromptNoLongerAvailable;
            }

            var removed = state.entries[index];
            const remaining_len = state.entries.len - 1;
            if (remaining_len == 0) {
                app.alloc.free(state.entries);
                state.entries = &.{};
                removed.deinit(app.alloc);
                debug_trace.eventf("input", "queue_review_draft_deleted", .{ .turn_id = turn_id }, "remaining=0", .{});
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
                releasePendingImages(app);
                finishReview(app, "deleted_last_prompt");
                return true;
            }

            const next = try app.alloc.alloc(ReviewEntry, remaining_len);
            var next_index: usize = 0;
            for (state.entries, 0..) |entry, entry_index| {
                if (entry_index == index) continue;
                next[next_index] = entry;
                next_index += 1;
            }
            app.alloc.free(state.entries);
            state.entries = next;
            removed.deinit(app.alloc);
            debug_trace.eventf("input", "queue_review_draft_deleted", .{ .turn_id = turn_id }, "remaining={d}", .{remaining_len});

            state.selected_index = @min(index, remaining_len - 1);
            state.visible = false;
            state.selected_dirty = false;
            try loadSelected(app);
            app.shell.render_requests.request(.footer);
            return true;
        }

        pub fn promptAdmission(
            app: *App,
            review_input: []const u8,
            review_pasted_blocks: []const paste_blocks.PastedBlock,
            review_image_tokens: []const entity_spans.ImageTokenSpan,
            review_skill_tokens: []const registered_entities.SkillTokenSpan,
        ) !PromptAdmission {
            const state = &app.queued_prompt_review;
            if (!state.active() or !state.visible) return .enqueue;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;

            var pasted_blocks = try dupePastedBlocks(
                app.alloc,
                review_pasted_blocks,
            );
            var pasted_blocks_owned = true;
            defer if (pasted_blocks_owned)
                paste_blocks.deinitBlocks(app.alloc, &pasted_blocks);
            var image_tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty;
            defer image_tokens.deinit(app.alloc);
            try image_tokens.appendSlice(app.alloc, review_image_tokens);
            try writeSelectedDraft(
                app,
                review_input,
                app.pending_images.items,
                review_skill_tokens,
            );
            paste_blocks.deinitBlocks(
                app.alloc,
                &state.entries[index].pasted_blocks,
            );
            state.entries[index].pasted_blocks = pasted_blocks;
            pasted_blocks = .empty;
            pasted_blocks_owned = false;
            state.entries[index].image_tokens.deinit(app.alloc);
            state.entries[index].image_tokens = image_tokens;
            image_tokens = .empty;
            if (!try commitDirtyEntries(app)) return error.QueuedPromptNoLongerAvailable;

            finishReview(app, "edited_prompts");
            return .replaced;
        }

        pub fn resumeAfterNewPrompt(app: *App) void {
            if (!app.queued_prompt_review.active() and app.worker.queueReviewReason() == null) return;
            finishReview(app, "new_prompt");
        }

        pub fn reset(app: *App) void {
            app.queued_prompt_review.clear(app.alloc);
        }

        fn openAfterPause(app: *App, paused: bool) bool {
            if (!paused) return false;
            if (app.queued_prompt_review.active()) {
                app.queued_prompt_review.reason = .post_cancel;
                return true;
            }
            _ = ensureOpen(app, .post_cancel) catch |err| {
                debug_trace.logf("input", "queue review snapshot failed reason=post_cancel err={s}", .{@errorName(err)});
                app.shell.render_requests.request(.footer);
                return true;
            };
            return true;
        }

        fn ensureOpen(app: *App, reason: worker_runtime.QueueReviewReason) !bool {
            const drafts = try app.worker.snapshotQueuedPromptDrafts(app.alloc);
            if (drafts.len == 0) {
                worker_runtime.freeQueuedPromptDrafts(app.alloc, drafts);
                return false;
            }
            var drafts_owned = true;
            errdefer if (drafts_owned) worker_runtime.freeQueuedPromptDrafts(app.alloc, drafts);

            const entries = try app.alloc.alloc(ReviewEntry, drafts.len);
            var entries_owned = true;
            errdefer if (entries_owned) app.alloc.free(entries);
            for (entries, drafts) |*entry, draft| {
                entry.* = .{ .draft = draft };
            }
            var tokens_initialized: usize = 0;
            errdefer for (entries[0..tokens_initialized]) |*entry| {
                entry.image_tokens.deinit(app.alloc);
            };
            for (entries) |*entry| {
                const has_review_tokens = if (entry.draft.review_draft) |review|
                    review.image_tokens.len > 0
                else
                    false;
                if (!has_review_tokens) {
                    entry.image_tokens = try imageTokensForQueuedPrompt(
                        app.alloc,
                        entry.draft.reviewInput(),
                        entry.draft.images,
                    );
                }
                tokens_initialized += 1;
            }
            for (entries) |*entry| {
                if (entry.draft.review_draft) |*review| {
                    if (review.pasted_blocks.len > 0) {
                        entry.pasted_blocks = .{
                            .items = review.pasted_blocks,
                            .capacity = review.pasted_blocks.len,
                        };
                        review.pasted_blocks = &.{};
                    }
                    if (review.image_tokens.len > 0) {
                        entry.image_tokens = .{
                            .items = review.image_tokens,
                            .capacity = review.image_tokens.len,
                        };
                        review.image_tokens = &.{};
                    }
                }
            }
            app.alloc.free(drafts);
            drafts_owned = false;

            app.queued_prompt_review.clear(app.alloc);
            const show_draft = composerIsEmpty(app);
            app.queued_prompt_review = .{
                .entries = entries,
                .selected_index = entries.len - 1,
                .reason = reason,
                .visible = false,
            };
            entries_owned = false;
            tokens_initialized = 0;
            if (show_draft) try loadSelected(app);
            return true;
        }

        fn loadSelected(app: *App) !void {
            const state = &app.queued_prompt_review;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;
            const entry = &state.entries[index];
            const draft = entry.draft;
            const review_input = draft.reviewInput();
            const review_skill_spans = draft.reviewSkillDisplaySpans();

            const images = try types.dupeImageAttachmentSlice(app.alloc, draft.images);
            var images_transferred = false;
            errdefer if (!images_transferred) types.freeImageAttachmentSlice(app.alloc, images);
            var skill_tokens = try dupeVisualSkillTokens(
                app.alloc,
                review_skill_spans,
            );
            errdefer deinitVisualSkillTokens(app.alloc, &skill_tokens);
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                review_input,
            );
            defer prepared_input.deinit(app.alloc);
            try app.pending_images.ensureTotalCapacity(app.alloc, images.len);

            releasePendingImages(app);
            if (images.len > 0) {
                app.pending_images.appendSliceAssumeCapacity(images);
                app.alloc.free(images);
            }
            images_transferred = true;
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            app.input_runtime.entities.image_tokens.deinit(app.alloc);
            app.input_runtime.entities.image_tokens = entry.image_tokens;
            entry.image_tokens = .empty;
            app.input_runtime.entities.skill_tokens.deinit(app.alloc);
            app.input_runtime.entities.skill_tokens = skill_tokens;
            skill_tokens = .empty;
            paste_blocks.deinitBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.entities.pasted_blocks = entry.pasted_blocks;
            entry.pasted_blocks = .empty;
            state.visible = true;
            state.selected_dirty = false;
        }

        fn stashSelected(app: *App) !void {
            const state = &app.queued_prompt_review;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;

            try writeSelectedDraft(
                app,
                app.input_runtime.edit_state.input.items,
                app.pending_images.items,
                app.input_runtime.entities.skill_tokens.items,
            );
            paste_blocks.deinitBlocks(app.alloc, &state.entries[index].pasted_blocks);
            state.entries[index].pasted_blocks = app.input_runtime.entities.pasted_blocks;
            app.input_runtime.entities.pasted_blocks = .empty;
            state.entries[index].image_tokens.deinit(app.alloc);
            state.entries[index].image_tokens = app.input_runtime.entities.image_tokens;
            app.input_runtime.entities.image_tokens = .empty;
            debug_trace.eventf(
                "input",
                "queue_review_draft_stashed",
                .{ .turn_id = state.entries[index].draft.turn_id },
                "prompt_bytes={d}",
                .{state.entries[index].draft.prompt.len},
            );
        }

        fn writeSelectedDraft(
            app: *App,
            prompt: []const u8,
            images: []const types.ImageAttachment,
            skill_tokens: []const registered_entities.SkillTokenSpan,
        ) !void {
            const state = &app.queued_prompt_review;
            const index = state.selected_index orelse return error.QueueReviewSelectionMissing;
            if (index >= state.entries.len) return error.QueueReviewSelectionMissing;

            const prompt_copy = try app.alloc.dupe(u8, prompt);
            errdefer app.alloc.free(prompt_copy);
            const images_copy = try types.dupeImageAttachmentSlice(app.alloc, images);
            errdefer types.freeImageAttachmentSlice(app.alloc, images_copy);
            const skill_display_spans = try dupeSkillDisplaySpans(app.alloc, skill_tokens);
            errdefer worker_runtime.freeSkillDisplaySpans(app.alloc, skill_display_spans);

            const draft = &state.entries[index].draft;
            types.freeImageAttachmentSlice(app.alloc, draft.images);
            if (draft.review_draft) |review| {
                worker_runtime.freeQueueReviewDraft(app.alloc, review);
            }
            draft.images = images_copy;
            draft.review_draft = .{
                .input = prompt_copy,
                .skill_display_spans = skill_display_spans,
            };
            state.entries[index].dirty = true;
            state.selected_dirty = false;
        }

        fn commitDirtyEntries(app: *App) !bool {
            const drafts = try buildDirtyDraftsForCommit(app);
            defer worker_runtime.freeQueuedPromptDrafts(app.alloc, drafts);
            if (drafts.len == 0) return true;
            if (!try app.worker.replaceQueuedPromptDrafts(app.alloc, drafts)) return false;
            debug_trace.eventf("input", "queue_review_batch_committed", .{}, "updated={d}", .{drafts.len});
            return true;
        }

        fn buildDirtyDraftsForCommit(app: *App) ![]worker_runtime.QueuedPromptDraft {
            const state = &app.queued_prompt_review;
            var dirty_count: usize = 0;
            for (state.entries) |entry| dirty_count += @intFromBool(entry.dirty);
            if (dirty_count == 0) return &.{};

            const commits = try app.alloc.alloc(worker_runtime.QueuedPromptDraft, dirty_count);
            var filled: usize = 0;
            errdefer {
                for (commits[0..filled]) |draft| worker_runtime.freeQueuedPromptDraft(app.alloc, draft);
                app.alloc.free(commits);
            }
            for (state.entries) |entry| {
                if (!entry.dirty) continue;
                const review_input = entry.draft.reviewInput();
                const review_skill_spans = entry.draft.reviewSkillDisplaySpans();
                const expanded = try paste_blocks.expand(
                    app.alloc,
                    review_input,
                    entry.pasted_blocks.items,
                );
                defer if (expanded.owned) app.alloc.free(expanded.text);
                const trimmed = std.mem.trim(u8, expanded.text, " \t\r\n");
                const prompt_copy = try app.alloc.dupe(u8, trimmed);
                errdefer app.alloc.free(prompt_copy);
                const images_copy = try types.dupeImageAttachmentSlice(app.alloc, entry.draft.images);
                errdefer types.freeImageAttachmentSlice(app.alloc, images_copy);
                const spans_copy = try projectSkillDisplaySpansForCommit(
                    app.alloc,
                    review_input,
                    expanded.text,
                    entry.pasted_blocks.items,
                    review_skill_spans,
                );
                errdefer worker_runtime.freeSkillDisplaySpans(
                    app.alloc,
                    spans_copy,
                );
                const review_draft = try worker_runtime.dupeQueueReviewDraft(
                    app.alloc,
                    .{
                        .input = @constCast(review_input),
                        .pasted_blocks = entry.pasted_blocks.items,
                        .image_tokens = entry.image_tokens.items,
                        .skill_display_spans = @constCast(review_skill_spans),
                    },
                );
                commits[filled] = .{
                    .turn_id = entry.draft.turn_id,
                    .kind = entry.draft.kind,
                    .prompt = prompt_copy,
                    .images = images_copy,
                    .skill_display_spans = spans_copy,
                    .review_draft = review_draft,
                };
                filled += 1;
            }
            return commits;
        }

        fn hideDraft(app: *App) !void {
            if (app.queued_prompt_review.selected_dirty) try stashSelected(app);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            releasePendingImages(app);
            app.queued_prompt_review.visible = false;
            app.queued_prompt_review.selected_dirty = false;
            debug_trace.eventf("input", "queue_review_hidden", .{}, "queued={d}", .{app.queued_prompt_review.entries.len});
        }

        fn finishReview(app: *App, source: []const u8) void {
            const queued = app.queued_prompt_review.entries.len;
            app.queued_prompt_review.clear(app.alloc);
            _ = app.worker.resumeQueueReview();
            debug_trace.eventf("input", "queue_review_finished", .{}, "source={s} queued={d}", .{ source, queued });
            app.shell.render_requests.request(.footer);
        }

        fn releasePendingImages(app: *App) void {
            if (comptime @hasDecl(App, "releasePendingImages")) {
                App.releasePendingImages(app);
            } else {
                app.clearPendingImages();
            }
        }

        fn composerIsEmpty(app: *const App) bool {
            return app.input_runtime.edit_state.input.items.len == 0 and app.pending_images.items.len == 0;
        }

        fn traceNavigation(state: *const State, direction: []const u8) void {
            const index = state.selected_index orelse return;
            debug_trace.eventf("input", "queue_review_navigate", .{}, "direction={s} index={d} count={d}", .{ direction, index, state.entries.len });
        }
    };
}

fn dupePastedBlocks(
    alloc: std.mem.Allocator,
    blocks: []const paste_blocks.PastedBlock,
) !std.ArrayList(paste_blocks.PastedBlock) {
    var copy: std.ArrayList(paste_blocks.PastedBlock) = .empty;
    errdefer paste_blocks.deinitBlocks(alloc, &copy);
    try copy.ensureTotalCapacity(alloc, blocks.len);
    for (blocks) |block| {
        const text = try alloc.dupe(u8, block.text);
        errdefer alloc.free(text);
        copy.appendAssumeCapacity(.{
            .id = block.id,
            .text = text,
            .line_count = block.line_count,
            .span = block.span,
        });
    }
    return copy;
}

fn imageTokensForQueuedPrompt(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    images: []const types.ImageAttachment,
) !std.ArrayList(entity_spans.ImageTokenSpan) {
    var tokens: std.ArrayList(entity_spans.ImageTokenSpan) = .empty;
    errdefer tokens.deinit(alloc);
    try tokens.ensureTotalCapacity(alloc, images.len);

    for (images) |image| {
        var match_start: ?usize = null;
        var match_end: usize = 0;
        var count: usize = 0;
        var raw_start: usize = 0;
        while (raw_start < prompt.len) {
            const match = image_attachments.matchImagePlaceholder(
                prompt,
                raw_start,
            ) orelse {
                raw_start += 1;
                continue;
            };
            if (match.id == image.id) {
                count += 1;
                match_start = raw_start;
                match_end = raw_start + match.length;
            }
            raw_start += match.length;
        }
        if (count != 1) {
            debug_trace.logf(
                "input",
                "queued image span reconstruction skipped id={d} matches={d}",
                .{ image.id, count },
            );
            continue;
        }
        tokens.appendAssumeCapacity(.{
            .id = image.id,
            .span = .{
                .raw_start = match_start.?,
                .raw_end = match_end,
            },
        });
    }
    sort_utils.sort(
        entity_spans.ImageTokenSpan,
        tokens.items,
        {},
        struct {
            fn lessThan(_: void, lhs: entity_spans.ImageTokenSpan, rhs: entity_spans.ImageTokenSpan) bool {
                return lhs.span.raw_start < rhs.span.raw_start;
            }
        }.lessThan,
    );
    return tokens;
}

fn dupeVisualSkillTokens(
    alloc: std.mem.Allocator,
    spans: []const worker_runtime.SkillDisplaySpan,
) !std.ArrayList(registered_entities.SkillTokenSpan) {
    var tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty;
    errdefer deinitVisualSkillTokens(alloc, &tokens);
    try tokens.ensureTotalCapacity(alloc, spans.len);
    for (spans) |span| {
        const name = try alloc.dupe(u8, span.name);
        errdefer alloc.free(name);
        const path = try alloc.dupe(u8, span.path);
        tokens.appendAssumeCapacity(.{
            .raw_start = span.raw_start,
            .raw_end = span.raw_end,
            .name = name,
            .path = path,
            .display_source = span.display_source,
            .owns_trailing_separator = span.owns_trailing_separator,
        });
    }
    return tokens;
}

fn deinitVisualSkillTokens(alloc: std.mem.Allocator, tokens: *std.ArrayList(registered_entities.SkillTokenSpan)) void {
    for (tokens.items) |token| {
        alloc.free(token.name);
        alloc.free(token.path);
    }
    tokens.deinit(alloc);
    tokens.* = .empty;
}

fn dupeSkillDisplaySpans(
    alloc: std.mem.Allocator,
    tokens: []const registered_entities.SkillTokenSpan,
) ![]worker_runtime.SkillDisplaySpan {
    if (tokens.len == 0) return &.{};
    const spans = try alloc.alloc(worker_runtime.SkillDisplaySpan, tokens.len);
    var filled: usize = 0;
    errdefer {
        for (spans[0..filled]) |span| {
            alloc.free(span.name);
            alloc.free(span.path);
        }
        alloc.free(spans);
    }
    while (filled < tokens.len) : (filled += 1) {
        const name = try alloc.dupe(u8, tokens[filled].name);
        errdefer alloc.free(name);
        const path = try alloc.dupe(u8, tokens[filled].path);
        spans[filled] = .{
            .raw_start = tokens[filled].raw_start,
            .raw_end = tokens[filled].raw_end,
            .name = name,
            .path = path,
            .display_source = tokens[filled].display_source,
            .owns_trailing_separator = tokens[filled].owns_trailing_separator,
        };
    }
    return spans;
}

fn projectSkillDisplaySpansForCommit(
    alloc: std.mem.Allocator,
    raw_input: []const u8,
    expanded_text: []const u8,
    pasted_blocks: []const paste_blocks.PastedBlock,
    spans: []const worker_runtime.SkillDisplaySpan,
) ![]worker_runtime.SkillDisplaySpan {
    if (spans.len == 0) return &.{};

    const trimmed = std.mem.trim(u8, expanded_text, " \t\r\n");
    const trim_start = expanded_text.len - std.mem.trimStart(u8, expanded_text, " \t\r\n").len;
    var projected: std.ArrayList(worker_runtime.SkillDisplaySpan) = .empty;
    errdefer {
        for (projected.items) |span| {
            alloc.free(span.name);
            alloc.free(span.path);
        }
        projected.deinit(alloc);
    }

    for (spans) |span| {
        const start = paste_blocks.projectOffsetThroughExpansion(raw_input, pasted_blocks, span.raw_start) orelse continue;
        const end = paste_blocks.projectOffsetThroughExpansion(raw_input, pasted_blocks, span.raw_end) orelse continue;
        if (start < trim_start or end < start or end - trim_start > trimmed.len) continue;
        const name = try alloc.dupe(u8, span.name);
        errdefer alloc.free(name);
        const path = try alloc.dupe(u8, span.path);
        errdefer alloc.free(path);
        try projected.append(alloc, .{
            .raw_start = start - trim_start,
            .raw_end = end - trim_start,
            .name = name,
            .path = path,
            .display_source = span.display_source,
            .owns_trailing_separator = span.owns_trailing_separator,
        });
    }

    if (projected.items.len == 0) {
        projected.deinit(alloc);
        return &.{};
    }
    return projected.toOwnedSlice(alloc);
}

const kill_ring = @import("../input/kill_ring.zig");
const render_request = @import("../../ui/render_request.zig");
