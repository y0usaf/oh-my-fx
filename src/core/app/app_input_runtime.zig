const std = @import("std");
const question_prompt = @import("../agent/question_prompt.zig");
const app_auth_runtime = @import("app_auth_runtime.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_workspace_runtime = @import("app_workspace_runtime.zig");
const app_commands = @import("app_commands.zig");
const project_config = @import("../mcp/project_config.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const host = @import("../hosts/host.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const composer_insertion = @import("../input/composer_insertion.zig");
const gesture_state = @import("../input/gesture_state.zig");
const horizontal_navigation = @import("../input/horizontal_navigation.zig");
const input_action = @import("../input/input_action.zig");
const transcript_presentation = @import("../output/transcript_presentation.zig");
const core_input_runtime = @import("../input/runtime.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const input_reset = @import("../input/input_reset.zig");
const picker_state = @import("../input/picker_state.zig");
const paste_framing = @import("../input/paste_framing.zig");
const text_scalar = @import("../input/text_scalar.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const image_attachments = @import("../images/image_attachments.zig");
const image_commands = @import("../images/image_commands.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const permission_request = @import("../permissions/permission_request.zig");
const approval_decision = @import("../permissions/approval_decision.zig");
const permissions = @import("../permissions/permissions.zig");
const session_commands = @import("../session/session_commands.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_runtime = @import("../session/session.zig");
const session_store = @import("../session/session_store.zig");
const usage_report = @import("../session/usage_report.zig");
const skill_runtime = @import("../skills/skill_runtime.zig");
const file_index = @import("../workspace/file_index.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const types = @import("../shared/types.zig");
const subagent_input = @import("../subagent/input_action.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const auto_upgrade = @import("../upgrade/auto_upgrade.zig");
const upgrade_helpers = @import("../upgrade/upgrade_helpers.zig");
const test_ui_input = @import("../../ui/input/runtime.zig");
const visual_layout = @import("../../ui/input/visual_layout.zig");
const approval_ui = @import("../../ui/footer/approval_ui.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const picker_presentation = @import("../../ui/footer/picker_presentation.zig");
const compact_command_menu_presentation = @import("../../ui/footer/compact_command_menu_presentation.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const paste_blocks = @import("../input/pasted_blocks.zig");
const registered_entities = @import("../input/registered_entities.zig");
const prompt_history_runtime = @import("prompt_history_runtime.zig");
const prompt_history_store = @import("../session/prompt_history_store.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const render_request = @import("../../ui/render_request.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const input_interrupt_runtime = @import("input_interrupt_runtime.zig");
const input_queue_runtime = @import("input_queue_runtime.zig");
const input_history_runtime = @import("input_history_runtime.zig");
const input_subagent_runtime = @import("input_subagent_runtime.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const input_paste_runtime = @import("input_paste_runtime.zig");
const input_submit_runtime = @import("input_submit_runtime.zig");
const input_approval_runtime = @import("input_approval_runtime.zig");
const input_question_runtime = @import("input_question_runtime.zig");
const input_full_transcript_runtime = @import("input_full_transcript_runtime.zig");
const input_selection_runtime = @import("input_selection_runtime.zig");
const input_limit_feedback = @import("input_limit_feedback.zig");
const app_upgrade_runtime = @import("app_upgrade_runtime.zig");

const ModelPickerStage = picker_state.ModelPickerStage;
const ToolPermissionDecision = types.ToolPermissionDecision;

pub const file_picker_completion_cap = input_completion_runtime.file_picker_completion_cap;
const ctrl_g_upgrade_byte: u8 = 7;
const ctrl_x_manager_byte: u8 = 24;

fn classifyResumeFailure(err: anyerror) session_catalog.ResumeFailure {
    return switch (err) {
        error.SessionBusy => .open_elsewhere,
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => .being_updated,
        else => .unavailable,
    };
}

const ExplicitModelSelection = struct {
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,
    has_fast_mode_token: bool = false,
};

const ExplicitModelSelectionParse = union(enum) {
    none,
    invalid,
    selection: ExplicitModelSelection,
};

const ProjectMcpPromptInputState = struct {
    active: bool,
    question_active: bool,
    approval_active: bool,
    subagent_active: bool,
    menu_active: bool,
    authentication_active: bool,
};

fn projectMcpPromptMayOwnInput(state: ProjectMcpPromptInputState) bool {
    return state.active and
        !state.question_active and
        !state.approval_active and
        !state.subagent_active and
        !state.menu_active and
        !state.authentication_active;
}

fn shortcutMayMutateQueuedDraft(action: input_action.ShortcutAction) bool {
    return switch (action) {
        .move,
        .select_all,
        .copy_selection,
        .redraw,
        => false,
        .cut_selection,
        .undo,
        .redo,
        .history_previous,
        .history_next,
        .delete_backward,
        .delete_forward,
        .delete_word_left,
        .delete_whitespace_word_left,
        .delete_word_right,
        .delete_to_line_start,
        .delete_to_line_end,
        .yank,
        .insert_newline,
        => true,
    };
}

fn shortcutDeletesQueuedDraft(action: input_action.ShortcutAction) bool {
    return switch (action) {
        .delete_backward,
        .delete_forward,
        .delete_word_left,
        .delete_whitespace_word_left,
        .delete_word_right,
        .delete_to_line_start,
        .delete_to_line_end,
        => true,
        else => false,
    };
}

fn parseExplicitModelSelection(input: []const u8) ExplicitModelSelectionParse {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.ascii.startsWithIgnoreCase(trimmed, "/model")) return .none;
    if (trimmed.len == "/model".len) return .none;
    if (trimmed["/model".len] != ' ' and trimmed["/model".len] != '\t') return .none;

    var tokens: [4][]const u8 = undefined;
    var token_count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, trimmed["/model".len..], " \t\r\n");
    while (iterator.next()) |token| {
        if (token_count == tokens.len) return .invalid;
        tokens[token_count] = token;
        token_count += 1;
    }
    if (token_count < 2) return .none;

    const effort = types.ReasoningEffort.parse(tokens[1]) orelse return .none;

    if (token_count == 2) {
        return .{ .selection = .{
            .model = tokens[0],
            .effort = effort,
            .fast_mode = false,
            .has_fast_mode_token = false,
        } };
    }

    if (token_count != 3) return .invalid;
    const fast_mode = if (std.ascii.eqlIgnoreCase(tokens[2], "fast"))
        true
    else if (std.ascii.eqlIgnoreCase(tokens[2], "normal"))
        false
    else
        return .invalid;
    return .{ .selection = .{
        .model = tokens[0],
        .effort = effort,
        .fast_mode = fast_mode,
        .has_fast_mode_token = true,
    } };
}

fn validateExplicitModelSelection(selection: ExplicitModelSelection, capabilities: model_capabilities.Capabilities) ExplicitModelSelectionParse {
    if (!model_capabilities.reasoningEffortSupported(capabilities, selection.effort)) return .invalid;
    if (capabilities.supports_fast_mode != selection.has_fast_mode_token) return .invalid;
    return .{ .selection = selection };
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const history_rt = input_history_runtime.HistoryRuntime(App);
        const subagent_rt = input_subagent_runtime.SubagentRuntime(App);
        const completion_rt = input_completion_runtime.CompletionRuntime(App);
        const paste_rt = input_paste_runtime.PasteEditRuntime(App);
        const submit_rt = input_submit_runtime.SubmitRuntime(App);
        const approval_rt = input_approval_runtime.ApprovalRuntime(App);
        const question_rt = input_question_runtime.QuestionRuntime(App);
        const interrupt_rt = input_interrupt_runtime.InterruptRuntime(App);
        const queue_rt = input_queue_runtime.Runtime(App);
        const full_transcript_rt = input_full_transcript_runtime.Runtime(App);

        const ctrl_c_exit_window_ms = gesture_state.ctrl_c_exit_window_ms;
        const ResolvedEscapeRoute = union(enum) {
            done,
            remapped_byte: u8,
        };

        const routeSlashCompletionMove = completion_rt.routeSlashCompletionMove;
        const advanceModelPickerOnSpace = completion_rt.advanceModelPickerOnSpace;
        const routeModifiedHistory = completion_rt.routeModifiedHistory;
        const routePlainVertical = completion_rt.routePlainVertical;
        const routeVisiblePickerMove = completion_rt.routeVisiblePickerMove;
        const navigateModelPicker = completion_rt.navigateModelPicker;
        const cancelApprovalOperation = approval_rt.cancelApprovalOperation;

        fn selectedChildRouteActive(app: *const App) bool {
            if (comptime @hasDecl(@TypeOf(app.subagents), "childRouteId")) {
                return app.subagents.childRouteId() != null;
            }
            return false;
        }
        const routeApprovalEscapeAction = approval_rt.routeApprovalEscapeAction;
        const routeQuestionEscapeAction = question_rt.routeQuestionEscapeAction;
        const submitQuestionBatch = question_rt.submitQuestionBatch;
        pub const rerenderQuestionBlock = question_rt.rerenderQuestionBlock;
        const finishPaste = paste_rt.finishPaste;
        const finalizePastedBlock = paste_rt.finalizePastedBlock;
        const handlePastedBytes = paste_rt.handlePastedBytes;
        const submit = submit_rt.submit;
        pub const installPromptHistory = history_rt.installPromptHistory;
        pub const loadAndInstallPromptHistory = history_rt.loadAndInstallPromptHistory;

        fn insertComposerSliceBounded(
            app: *App,
            bytes: []const u8,
            max_input_len: usize,
            preserve_model_picker: bool,
        ) !composer_insertion.InsertResult {
            const picker_policy: composer_insertion.PickerPolicy = if (preserve_model_picker)
                .preserve
            else
                .clear;
            return app.input_runtime.replacementState(&app.pending_images).replaceSelectionOrInsertSliceBounded(
                app.alloc,
                bytes,
                max_input_len,
                picker_policy,
            );
        }

        pub fn clearPendingImages(app: *App) void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.entities.image_tokens.clearRetainingCapacity();
            image_attachments.discardImageSnapshots(app.alloc, app.pending_images.items);
            for (app.pending_images.items) |image| {
                types.freeImageAttachment(app.alloc, image);
            }
            app.pending_images.clearRetainingCapacity();
        }

        pub fn releasePendingImages(app: *App) void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.entities.image_tokens.clearRetainingCapacity();
            for (app.pending_images.items) |image| {
                types.freeImageAttachment(app.alloc, image);
            }
            app.pending_images.clearRetainingCapacity();
        }

        fn routeComposerShortcutAction(app: *App, action: input_action.ShortcutAction, max_input_len: usize) !void {
            if (comptime @hasField(App, "queued_prompt_review")) {
                if (shortcutDeletesQueuedDraft(action) and try queue_rt.deleteEmptyVisibleDraft(app)) return;
                if (shortcutMayMutateQueuedDraft(action)) queue_rt.markVisibleSelectionDirty(app);
            }
            switch (action) {
                .move => |intent| {
                    switch (intent.kind) {
                        .character_left => {
                            app.input_runtime.vertical_navigation.reset();
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null and
                                !app.stream.active and
                                try completion_rt.stepBackModelPicker(app))
                            {
                                app.shell.render_requests.request(.footer);
                                return;
                            }
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .character_right => {
                            app.input_runtime.vertical_navigation.reset();
                            if (!intent.extend_selection and
                                app.input_runtime.edit_state.selectionRange() == null)
                            {
                                switch (try completion_rt.autocompleteInlineCompletion(app, max_input_len)) {
                                    .inserted => {
                                        app.shell.render_requests.request(.footer);
                                        return;
                                    },
                                    .inactive => {},
                                    .limit_exceeded => {
                                        try input_limit_feedback.report(App, app, .composer, 1);
                                        app.shell.render_requests.request(.footer);
                                        return;
                                    },
                                }
                            }
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .word_left,
                        .word_right,
                        .line_start,
                        .line_end,
                        .draft_start,
                        .draft_end,
                        .paragraph_up,
                        .paragraph_down,
                        => {
                            completion_rt.abandonModelPickerOptions(app);
                            _ = app.input_runtime.moveInputCursor(intent);
                        },
                        .visual_up,
                        .visual_down,
                        .page_up,
                        .page_down,
                        => {
                            const direction: visual_layout.Direction = switch (intent.kind) {
                                .visual_up, .page_up => .up,
                                .visual_down, .page_down => .down,
                                else => unreachable,
                            };
                            const delta: i32 = if (direction == .up) -1 else 1;
                            try completion_rt.routeComposerVertical(
                                app,
                                direction,
                                delta,
                                intent.extend_selection,
                                intent.kind == .page_up or intent.kind == .page_down,
                            );
                        },
                    }
                    app.shell.render_requests.request(.footer);
                },
                .select_all => {
                    dismissActiveMenusThenRedraw(app);
                    if (app.input_runtime.selectionState().selectAll()) {
                        app.shell.render_requests.request(.footer);
                    }
                },
                .copy_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        if (input_selection_runtime.copySelection(
                            &app.input_runtime.edit_state,
                            app.clipboard(),
                        ) == .copy_failed) {
                            debug_trace.logf(
                                "input",
                                "composer selection copy preserved reason=clipboard_copy_failed",
                                .{},
                            );
                        }
                    }
                },
                .cut_selection => {
                    if (comptime @hasDecl(App, "clipboard")) {
                        switch (input_selection_runtime.cutSelection(
                            app.alloc,
                            app.input_runtime.selectionState(),
                            &app.pending_images,
                            app.clipboard(),
                        )) {
                            .cut => {
                                dismissActiveMenusThenRedraw(app);
                                syncCatalogMenus(app);
                                app.shell.render_requests.request(.footer);
                            },
                            .copy_failed => debug_trace.logf(
                                "input",
                                "composer selection cut preserved reason=clipboard_copy_failed",
                                .{},
                            ),
                            .delete_failed => debug_trace.logf(
                                "input",
                                "composer selection cut delete skipped reason=delete_failed",
                                .{},
                            ),
                            .inactive, .copied => {},
                        }
                    }
                },
                .undo => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.undoState().undo(app.alloc)) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .redo => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.undoState().redo(app.alloc)) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .redraw => {
                    if (!composerPickerSurfaceVisible(app) or
                        activeCatalogMenuOwnsByte(app, 12)) return;
                    if (comptime @hasField(App, "pacer") and
                        @hasField(App, "metrics") and
                        @hasDecl(@TypeOf(app.pacer), "discardDeferredPresentationForVisualEpoch"))
                    {
                        _ = try app_render_runtime.Runtime(App).resetVisualEpoch(app, .ctrl_l);
                    }
                },
                .history_previous => {
                    try completion_rt.navigatePromptHistory(app, -1);
                    syncCatalogMenus(app);
                    app.shell.render_requests.request(.footer);
                },
                .history_next => {
                    try completion_rt.navigatePromptHistory(app, 1);
                    syncCatalogMenus(app);
                    app.shell.render_requests.request(.footer);
                },
                .delete_backward => {
                    if (app.input_runtime.edit_state.input.items.len > 0) {
                        const picker_policy: composer_insertion.PickerPolicy =
                            if (completion_rt.shouldPreserveModelPickerBackspace(app))
                                .preserve
                            else
                                .clear;
                        const changed = app.input_runtime.deletionState(
                            &app.pending_images,
                        ).delete(app.alloc, .character_left, picker_policy);
                        if (changed) {
                            app.input_runtime.picker.resetFilePickerIndex();
                            syncCatalogMenus(app);
                            app.shell.render_requests.request(.footer);
                        }
                    }
                },
                .delete_forward => {
                    dismissActiveMenusThenRedraw(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .character_right,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_word_left => {
                    dismissActiveMenusThenRedraw(app);
                    completion_rt.abandonModelPickerOptions(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .word_left,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_whitespace_word_left => {
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .whitespace_word_left,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_word_right => {
                    dismissActiveMenusThenRedraw(app);
                    completion_rt.abandonModelPickerOptions(app);
                    if (app.input_runtime.deletionState(&app.pending_images).delete(
                        app.alloc,
                        .word_right,
                        .clear,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_to_line_start => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .line_start,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .delete_to_line_end => {
                    dismissActiveMenusThenRedraw(app);
                    if (try app.input_runtime.killRingState(&app.pending_images).delete(
                        app.alloc,
                        .line_end,
                    )) {
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .yank => {
                    const first_image_id = app.peekNextImageId();
                    switch (try app.input_runtime.killRingState(&app.pending_images).yank(
                        app.alloc,
                        first_image_id,
                        max_input_len,
                    )) {
                        .inserted => |image_count| {
                            for (0..image_count) |offset| {
                                const committed_id = app.nextImageId();
                                std.debug.assert(committed_id == first_image_id + offset);
                            }
                            syncCatalogMenus(app);
                            app.shell.render_requests.request(.footer);
                        },
                        .inactive => {},
                        .limit_exceeded => |attempted_bytes| try input_limit_feedback.report(
                            App,
                            app,
                            .composer,
                            attempted_bytes,
                        ),
                    }
                },
                .insert_newline => {
                    if (commandSkillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(app)) return;
                    dismissActiveMenusThenRedraw(app);
                    switch (try insertComposerSliceBounded(app, "\n", max_input_len, false)) {
                        .inserted => app.shell.render_requests.request(.footer),
                        .inactive => unreachable,
                        .limit_exceeded => try input_limit_feedback.report(App, app, .composer, 1),
                    }
                },
            }
        }

        pub fn expireTerminalInputGestures(app: *App, now: i64) void {
            expireCtrlCExitArm(app, now);
            expireEscClearArm(app, now);
        }

        fn terminalDecodeContext(
            app: *const App,
            paste_active: bool,
        ) input_action.TerminalDecodeContext {
            if (paste_active) {
                return .{
                    .now_ms = 0,
                    .paste_active = true,
                    .cancel_pending = false,
                    .child_route_active = false,
                    .question_freeform_selected = false,
                };
            }
            return .{
                .now_ms = io_mod.milliTimestamp(),
                .paste_active = false,
                .cancel_pending = app.stream.active,
                .child_route_active = selectedChildRouteActive(app),
                .question_freeform_selected = app.question_prompt.isFreeformSelected(),
            };
        }

        pub fn prepareTerminalDecode(app: *App) !?input_action.TerminalDecodeContext {
            if (!try app_worker_runtime.Runtime(App).authorizeInteractiveAdmission(app)) return null;
            const paste_active = terminalPasteActive(app);
            return terminalDecodeContext(app, paste_active);
        }

        pub fn handleTerminalInputIngressWithLimits(
            app: *App,
            ingress: input_action.TerminalInputIngress,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !?u8 {
            if (!ingress.has_routing_work()) return null;

            const file_picker_was_active = app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) != null;
            defer if (comptime runtime_profile.allows(App, .file_index))
                updateFilePickerEpisode(app, file_picker_was_active);

            const paste_was_active = terminalPasteActive(app);
            defer {
                const paste_is_active = terminalPasteActive(app);
                if (!paste_was_active and paste_is_active) {
                    shell_runtime.suspendResizeCursorProbeForPaste(&app.terminal_input_runtime.terminal_cursor_probe);
                } else if (paste_was_active and !paste_is_active) {
                    shell_runtime.resumeResizeCursorProbeAfterPaste(
                        &app.terminal_input_runtime.terminal_cursor_probe,
                        io_mod.milliTimestamp(),
                    );
                }
            }

            if (ingress.interrupts_pending_text and
                text_scalar.hasPending(app.input_runtime.text_scalar))
            {
                input_reset.resetPendingTextScalarWithTrace(
                    &app.input_runtime.text_scalar,
                    "interrupted_by_non_text_input",
                );
            }

            var replay_byte = ingress.replay_byte_after_routing;
            if (replay_byte) |byte| {
                if (byte != 0x1b and try routeProjectMcpPromptByte(app, byte)) {
                    replay_byte = null;
                }
            }
            if (ingress.event) |event| {
                switch (event) {
                    .paste_byte => |byte| {
                        const routed = try routeActivePasteByte(app, byte);
                        std.debug.assert(routed);
                    },
                    .raw => |raw| try handleRawTerminalInputWithLimits(
                        app,
                        raw,
                        input_limits,
                        max_prompt_history,
                    ),
                    .action => |decoded| {
                        switch (try routeResolvedEscapeAction(
                            app,
                            decoded.action,
                            decoded.composer_shortcut,
                            decoded.approval_focused_edit,
                            decoded.question_action,
                            decoded.subagent_action,
                            decoded.cancel_pending,
                            input_limits.composer_bytes,
                            max_prompt_history,
                        )) {
                            .done => {},
                            .remapped_byte => |byte| {
                                std.debug.assert(replay_byte == null);
                                replay_byte = byte;
                            },
                        }
                    },
                }
            }
            return replay_byte;
        }

        pub fn flushPendingEscape(app: *App, input_escape_timeout_ms: i64) !void {
            const now = io_mod.milliTimestamp();
            expireTerminalInputGestures(app, now);
            const ingress = app.terminal_input_runtime.flushTerminalAction(
                now,
                input_escape_timeout_ms,
                terminalPasteActive(app),
            );
            if (ingress.event) |event| {
                switch (event) {
                    .action => |decoded| {
                        std.debug.assert(decoded.action == .escape);
                        disarmCtrlCExit(app, "semantic_action");
                        try resolveEscape(app, decoded.cancel_pending, now);
                    },
                    .paste_byte, .raw => unreachable,
                }
            }
        }

        pub fn handleTerminalByte(app: *App, byte: u8, max_input_len: usize, max_prompt_history: usize) !void {
            return handleTerminalByteWithLimits(
                app,
                byte,
                paste_framing.InputLimits.single(max_input_len),
                max_prompt_history,
            );
        }

        pub fn handleTerminalByteWithLimits(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            var context = try prepareTerminalDecode(app) orelse return;
            var ingress = app.terminal_input_runtime.decodeTerminalByte(
                byte,
                context,
            );
            while (true) {
                const replay_byte = try handleTerminalInputIngressWithLimits(
                    app,
                    ingress,
                    input_limits,
                    max_prompt_history,
                );
                const replay = replay_byte orelse return;
                context = try prepareTerminalDecode(app) orelse return;
                ingress = app.terminal_input_runtime.decodeTerminalByte(replay, context);
            }
        }

        pub fn terminalPasteActive(app: *const App) bool {
            if (app.input_runtime.paste.active()) return true;
            if (comptime @hasDecl(@TypeOf(app.subagents), "managerPasteActive")) {
                return app.subagents.managerPasteActive();
            }
            return false;
        }

        pub fn routeActivePasteIngressByteWithLimits(
            app: *App,
            byte: u8,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !bool {
            if (!terminalPasteActive(app)) return false;
            const replay_byte = try handleTerminalInputIngressWithLimits(
                app,
                .{ .event = .{ .paste_byte = byte } },
                input_limits,
                max_prompt_history,
            );
            std.debug.assert(replay_byte == null);
            return true;
        }

        pub fn settleTerminalPasteDeliveryEpochWithLimits(
            app: *App,
            input_limits: paste_framing.InputLimits,
        ) !void {
            const paste_was_active = terminalPasteActive(app);
            if (!paste_was_active) return;
            defer if (!terminalPasteActive(app)) {
                shell_runtime.resumeResizeCursorProbeAfterPaste(
                    &app.terminal_input_runtime.terminal_cursor_probe,
                    io_mod.milliTimestamp(),
                );
            };

            if (comptime @hasDecl(@TypeOf(app.subagents), "settleManagerPasteDeliveryEpoch")) {
                if (app.subagents.managerPasteActive()) {
                    const failure_before = if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "childPresentationView",
                    ))
                        if (app.subagents.childPresentationView()) |view|
                            view.input_failure
                        else
                            null
                    else
                        null;
                    const settled = app.subagents.settleManagerPasteDeliveryEpoch(app.alloc);
                    if (!settled) return;
                    if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "invalidateChildConversationProjection",
                    )) {
                        const failure_after = if (app.subagents.childPresentationView()) |view|
                            view.input_failure
                        else
                            null;
                        if (!std.meta.eql(failure_before, failure_after)) {
                            app.subagents.invalidateChildConversationProjection(app.alloc);
                        }
                    }
                    app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                        app,
                        .subagent_panel,
                    );
                    return;
                }
            }

            if (app.input_runtime.paste.active()) {
                const settled = try paste_rt.settlePasteDeliveryEpoch(
                    app,
                    input_limits.forOwner(app.input_runtime.paste.owner),
                );
                if (settled and !app.input_runtime.paste.active()) syncCatalogMenus(app);
            }
        }

        fn updateFilePickerEpisode(app: *App, was_active: bool) void {
            const query = app.input_runtime.picker.activeFilePickerQuery(&app.input_runtime.edit_state) orelse return;
            if (was_active) return;

            app.input_runtime.picker.resetFilePickerIndex();
            if (comptime @hasDecl(App, "fileCompletionsDependOnIndex")) {
                if (!app.fileCompletionsDependOnIndex(query.query)) return;
            }
            if (!app.input_runtime.picker.file_picker_episode_seen) {
                app.input_runtime.picker.file_picker_episode_seen = true;
                if (comptime @hasDecl(App, "isFileIndexLoading")) {
                    if (app.isFileIndexLoading()) return;
                }
            }
            if (comptime @hasDecl(App, "refreshFileIndex")) {
                app.refreshFileIndex();
            }
        }

        pub fn handleByte(app: *App, byte: u8, max_input_len: usize, max_prompt_history: usize) !void {
            return handleTerminalByteWithLimits(
                app,
                byte,
                paste_framing.InputLimits.single(max_input_len),
                max_prompt_history,
            );
        }

        fn routeActivePasteByte(
            app: *App,
            byte: u8,
        ) !bool {
            if (comptime @hasDecl(@TypeOf(app.subagents), "managerPasteActive")) {
                if (app.subagents.managerPasteActive()) {
                    const failure_before = if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "childPresentationView",
                    ))
                        if (app.subagents.childPresentationView()) |view|
                            view.input_failure
                        else
                            null
                    else
                        null;
                    _ = try app.subagents.consumeManagerPasteByte(app.alloc, byte);
                    if (comptime @hasDecl(
                        @TypeOf(app.subagents),
                        "invalidateChildConversationProjection",
                    )) {
                        const failure_after = if (app.subagents.childPresentationView()) |view|
                            view.input_failure
                        else
                            null;
                        if (!std.meta.eql(failure_before, failure_after)) {
                            app.subagents.invalidateChildConversationProjection(app.alloc);
                        }
                    }
                    app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                        app,
                        .subagent_panel,
                    );
                    return true;
                }
            }
            if (app.input_runtime.paste.active()) {
                try paste_rt.handleActivePasteByte(app, byte);
                return true;
            }
            return false;
        }

        fn projectMcpPromptOwnsInput(app: *App) bool {
            if (comptime !@hasDecl(App, "projectMcpPromptActive")) return false;
            var subagent_active = false;
            if (comptime runtime_profile.allows(App, .subagents)) {
                subagent_active = app.subagents.isViewActive();
            }
            const menu_active = activeCompactCommandMenu(app) != null or
                settingsMenuActive(app) or
                skillsMenuActive(app) or
                modelMenuActive(app) or
                sessionMenuActive(app) or
                helpMenuActive(app);
            var authentication_active = false;
            if (comptime runtime_profile.allows(App, .native_auth)) {
                authentication_active = app.auth.apiKeyEntryActive();
            }
            return projectMcpPromptMayOwnInput(.{
                .active = app.projectMcpPromptActive(),
                .question_active = app.question_prompt.isActive(),
                .approval_active = app.approval_prompt.isActive(),
                .subagent_active = subagent_active,
                .menu_active = menu_active,
                .authentication_active = authentication_active,
            });
        }

        fn routeProjectMcpPromptByte(app: *App, byte: u8) !bool {
            if (comptime !@hasDecl(App, "projectMcpPromptName")) return false;
            const owns_input = projectMcpPromptOwnsInput(app);
            debug_trace.logf(
                "mcp",
                "project prompt input byte={d} owns_input={s}",
                .{ byte, if (owns_input) "true" else "false" },
            );
            if (!owns_input) return false;
            const action: project_config.ProjectMcpAction = switch (byte) {
                '1' => {
                    const name = (try app.projectMcpPromptName(app.alloc)) orelse return true;
                    defer app.alloc.free(name);
                    const display = try text_utils.encodeTerminalSafe(app.alloc, name, 256);
                    defer app.alloc.free(display.bytes);
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Approving project MCP server '{s}'.",
                        .{display.bytes},
                    );
                    defer app.alloc.free(body);
                    try app_commands.Handlers(App).applyProjectMcpAction(
                        app,
                        .{ .approve = name },
                        body,
                    );
                    return true;
                },
                '2' => .approve_all,
                '3' => {
                    const name = (try app.projectMcpPromptName(app.alloc)) orelse return true;
                    defer app.alloc.free(name);
                    const display = try text_utils.encodeTerminalSafe(app.alloc, name, 256);
                    defer app.alloc.free(display.bytes);
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "Rejecting project MCP server '{s}'.",
                        .{display.bytes},
                    );
                    defer app.alloc.free(body);
                    try app_commands.Handlers(App).applyProjectMcpAction(
                        app,
                        .{ .reject = name },
                        body,
                    );
                    return true;
                },
                else => return true,
            };
            try app_commands.Handlers(App).applyProjectMcpAction(
                app,
                action,
                "Approving all project MCP servers for this workspace.",
            );
            return true;
        }

        fn handleRawTerminalInputWithLimits(
            app: *App,
            raw: input_action.RawTerminalInput,
            input_limits: paste_framing.InputLimits,
            max_prompt_history: usize,
        ) !void {
            const byte = raw.byte;
            const max_input_len = input_limits.composer_bytes;
            // Fire the max-level cue only when the slash menu becomes visible.
            const slash_menu_was_visible = slashMenuVisibleForCue(app);
            defer announceSlashMenuOpened(app, slash_menu_was_visible);
            if (try routeActivePasteByte(app, byte)) return;

            if (byte != 3 and byte != 0x1b) disarmCtrlCExit(app, "raw_input");

            // Non-escape input disarms the pending double-Escape clear.
            if (byte != 0x1b) {
                if (disarmEscapeClear(app)) {
                    app.shell.render_requests.request(.footer);
                }
            }

            // Ctrl-Z arrives as raw byte 26 (ISIG disabled); kitty remaps here too.
            if (byte == 26) {
                try app.suspendToJobControl();
                return;
            }

            if (comptime runtime_profile.allows(App, .native_auth)) {
                if (try app_auth_runtime.Runtime(App).routeAuthPickerByte(app, byte)) return;
            }
            if (try full_transcript_rt.routeByte(app, byte)) return;
            if (try routeProjectMcpPromptByte(app, byte)) return;
            if (try routeActiveModalInput(app, raw, input_limits.decision_bytes)) return;
            if (byte >= 0x80) {
                try handleTextByte(app, .composer, byte, max_input_len);
                return;
            }
            if (try routeUpgradeShortcut(app, byte)) return;
            if (try routePickerControlByte(app, byte)) return;

            if (isComposerEditingByte(byte, raw.composer_shortcut) and
                !activeCatalogMenuOwnsByte(app, byte) and
                dismissActiveMenusForComposerEdit(app))
            {
                app.shell.render_requests.request(.footer);
            }
            if (isComposerEditingByte(byte, raw.composer_shortcut) and
                !activeCatalogMenuOwnsByte(app, byte))
            {
                if (comptime @hasField(App, "queued_prompt_review")) {
                    queue_rt.markVisibleSelectionDirty(app);
                }
            }

            try handleComposerByte(
                app,
                byte,
                raw.composer_shortcut,
                max_input_len,
                max_prompt_history,
            );
        }

        fn routeResolvedEscapeAction(
            app: *App,
            resolved: input_action.Action,
            composer_shortcut: ?input_action.ShortcutAction,
            approval_focused_edit: ?approval_decision.DraftAction,
            question_action: ?question_prompt.Action,
            subagent_action: ?subagent_input.Action,
            was_cancel_pending: bool,
            max_input_len: usize,
            max_prompt_history: usize,
        ) !ResolvedEscapeRoute {
            switch (resolved) {
                .remapped_byte, .paste_start, .paste_end, .ignore => {},
                else => disarmCtrlCExit(app, "semantic_action"),
            }

            if (resolved == .escape) {
                if (try full_transcript_rt.routeAction(app, resolved)) return .done;
                if (comptime @hasDecl(App, "suppressProjectMcpPrompts")) {
                    if (projectMcpPromptOwnsInput(app)) {
                        app.suppressProjectMcpPrompts();
                        try app.writeDomainNotice(.{
                            .topic = "mcp",
                            .tone = .neutral,
                            .body = "Project MCP approval prompts dismissed for this process.",
                        }, true);
                        return .done;
                    }
                }
                const now = io_mod.milliTimestamp();
                expireEscClearArm(app, now);
                try resolveEscape(app, was_cancel_pending, now);
                return .done;
            }

            if (app_auth_runtime.Runtime(App).routeAuthPickerEscapeAction(app, resolved)) {
                return .done;
            }

            if (try full_transcript_rt.routeAction(app, resolved)) return .done;

            if (resolved == .paste_start) {
                if (comptime runtime_profile.allows(App, .native_auth) and
                    @hasDecl(@TypeOf(app.auth), "signInCodeEntryActive"))
                {
                    if (app.auth.signInCodeEntryActive()) {
                        paste_rt.beginPaste(app, max_input_len);
                        return .done;
                    }
                }
                if (comptime @hasDecl(@TypeOf(app.subagents), "beginManagerPaste")) {
                    if (app.subagents.isViewActive()) {
                        app.subagents.beginManagerPaste();
                        app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                            app,
                            .subagent_panel,
                        );
                        return .done;
                    }
                } else if (comptime @hasDecl(@TypeOf(app.subagents), "beginChildPaste")) {
                    if (app.subagents.childRouteId() != null) {
                        app.subagents.beginChildPaste();
                        app_render_runtime.Runtime(App).requestSubagentSurfaceFrame(
                            app,
                            .subagent_panel,
                        );
                        return .done;
                    }
                }
                dismissActiveMenusThenRedraw(app);
                if (comptime @hasField(App, "queued_prompt_review")) {
                    queue_rt.markVisibleSelectionDirty(app);
                }
                paste_rt.beginPaste(app, max_input_len);
                return .done;
            }

            if (resolved == .paste_end) {
                return .done;
            }

            switch (resolved) {
                .remapped_byte => |byte| return .{ .remapped_byte = byte },
                else => {},
            }

            if (comptime runtime_profile.allows(App, .subagents)) {
                if (app.subagents.isViewActive()) {
                    if (approvalOwnsCurrentSurface(app)) {
                        try approval_rt.routeApprovalEscapeAction(
                            app,
                            resolved,
                            approval_focused_edit,
                        );
                    } else {
                        try subagent_rt.routeSubagentEscapeAction(
                            app,
                            resolved,
                            composer_shortcut,
                            subagent_action,
                        );
                    }
                    return .done;
                }
            }

            if (app.question_prompt.isActive()) {
                try question_rt.routeQuestionEscapeAction(
                    app,
                    resolved,
                    question_action,
                );
                return .done;
            }

            if (app.approval_prompt.isActive()) {
                try approval_rt.routeApprovalEscapeAction(
                    app,
                    resolved,
                    approval_focused_edit,
                );
                return .done;
            }

            if (activeCompactCommandMenu(app)) |menu| {
                try routeCompactCommandMenuEscapeAction(app, menu, resolved);
                return .done;
            }

            if (settingsMenuActive(app) and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                try changeSettingsMenuSelection(
                    app,
                    if (resolved == .cursor_left) -1 else 1,
                );
                return .done;
            }

            if (try full_transcript_rt.routeComposerAction(app, resolved)) return .done;

            if (composer_shortcut) |action| {
                try routeComposerShortcutAction(app, action, max_input_len);
                return .done;
            }

            switch (resolved) {
                .history_up => {
                    try completion_rt.routeModifiedHistory(app, .up, -1);
                    app.shell.render_requests.request(.footer);
                },
                .history_down => {
                    try completion_rt.routeModifiedHistory(app, .down, 1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_up => {
                    try completion_rt.routePlainVertical(app, .up, -1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_down => {
                    try completion_rt.routePlainVertical(app, .down, 1);
                    app.shell.render_requests.request(.footer);
                },
                .cursor_left,
                .cursor_right,
                .word_left,
                .word_right,
                .home,
                .end,
                .delete_next,
                .delete_word_left,
                .delete_word_right,
                .delete_to_line_start,
                .delete_to_line_end,
                .insert_newline,
                .composer_shortcut,
                .toggle_full_transcript,
                => unreachable,
                .steer_submit => try submit_rt.submitSteering(app, max_prompt_history),
                .page_up,
                .page_down,
                .mouse_wheel,
                .mouse_pointer,
                => {},
                .clear_line => {
                    dismissActiveMenusThenRedraw(app);
                    if (comptime @hasField(App, "queued_prompt_review")) {
                        if (try queue_rt.deleteEmptyVisibleDraft(app)) return .done;
                        queue_rt.markVisibleSelectionDirty(app);
                    }
                    if (draftHasState(app)) {
                        clearDraftState(app, "clear_line");
                        app.shell.render_requests.request(.footer);
                    }
                },
                .toggle_permission_mode => {
                    if (cycleHelpMenuCategory(app, -1) or cycleSettingsMenuCategory(app, -1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (try toggleSessionPickerScopeIfActive(app)) {
                        app.shell.render_requests.request(.footer);
                    } else if (cycleModelMenuProvider(app, -1) or cycleSkillsMenuSource(app, -1)) {
                        app.shell.render_requests.request(.footer);
                    } else {
                        try app_permission_runtime.Runtime(App).toggleMode(app);
                    }
                },
                .open_all_sessions => {
                    if (comptime @hasField(App, "session_persistence") and
                        runtime_profile.allows(App, .durable_sessions))
                    {
                        if (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app)) return .done;
                        if (try refuseSessionActionWithDraft(app, "submit or clear the draft before switching sessions")) return .done;
                        dismissActiveMenusThenRedraw(app);
                        try app_session_runtime.Runtime(App).openAllSessionPicker(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
                .paste_start => dismissActiveMenusThenRedraw(app),
                .paste_end => {},
                .remapped_byte => unreachable,
                .escape => unreachable,
                .ignore => {},
            }
            return .done;
        }

        fn routePickerControlByte(app: *App, byte: u8) !bool {
            if (!composerPickerSurfaceVisible(app)) return false;
            const delta = pickerControlDelta(byte) orelse return false;
            if (!try routeVisiblePickerMove(app, delta)) return false;
            app.input_runtime.vertical_navigation.reset();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn pickerControlDelta(byte: u8) ?i32 {
            return switch (byte) {
                10 => 1,
                11 => -1,
                else => null,
            };
        }

        fn composerPickerSurfaceVisible(app: *App) bool {
            if (app.question_prompt.isActive() or approvalOwnsCurrentSurface(app)) return false;
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.fullTranscriptScreenActive()) return false;
            }
            return true;
        }

        fn routeUpgradeShortcut(app: *App, byte: u8) !bool {
            if (byte != ctrl_g_upgrade_byte) return false;
            if (comptime @hasDecl(App, "applyReadyUpgradeShortcut")) {
                try app.applyReadyUpgradeShortcut();
            }
            return true;
        }

        fn routeActiveModalInput(
            app: *App,
            raw: input_action.RawTerminalInput,
            max_input_len: usize,
        ) !bool {
            const byte = raw.byte;
            if ((app.question_prompt.isActive() or approvalOwnsCurrentSurface(app)) and byte == ctrl_g_upgrade_byte) {
                _ = try routeUpgradeShortcut(app, byte);
                return true;
            }
            // A presented child approval is resolvable from the main chat or
            // the manager, so only that exact modal may delegate Ctrl-X.
            if ((comptime runtime_profile.allows(App, .subagents)) and
                app.approval_prompt.isActive() and
                byte == ctrl_x_manager_byte and
                presentedSubagentApproval(app))
            {
                try subagent_rt.toggleSubagentView(app);
                return true;
            }
            if (app.question_prompt.isActive()) {
                if (byte >= 0x80) {
                    if (app.question_prompt.isFreeformSelected()) {
                        try handleTextByte(app, .question_freeform, byte, max_input_len);
                    } else {
                        input_reset.resetPendingTextScalarWithTrace(
                            &app.input_runtime.text_scalar,
                            "question_decision_active",
                        );
                    }
                    return true;
                }
                if (raw.question_action) |action| {
                    switch (try question_rt.handleQuestionActionBounded(
                        app,
                        action,
                        max_input_len,
                    )) {
                        .consumed => app.input_runtime.input_limit_rejection = input_limit_rejection.clear(),
                        .ignored => {},
                        .limit_exceeded => try input_limit_feedback.report(App, app, .question_freeform, 1),
                    }
                }
                return true;
            }
            if (approvalOwnsCurrentSurface(app)) {
                if (byte >= 0x80) {
                    if (app.approval_prompt.isAmending()) {
                        try handleTextByte(app, .approval_amendment, byte, max_input_len);
                    } else {
                        input_reset.resetPendingTextScalarWithTrace(
                            &app.input_runtime.text_scalar,
                            "approval_decision_active",
                        );
                    }
                    return true;
                }
                if (raw.approval_action) |action| {
                    switch (try approval_rt.handlePermissionActionBounded(
                        app,
                        action,
                        max_input_len,
                    )) {
                        .consumed => app.input_runtime.input_limit_rejection = input_limit_rejection.clear(),
                        .ignored => {},
                        .limit_exceeded => try input_limit_feedback.report(App, app, .approval_amendment, 1),
                    }
                }
                return true;
            }
            if (activeCompactCommandMenu(app)) |menu| {
                if (byte >= 0x80) {
                    input_reset.resetPendingTextScalarWithTrace(
                        &app.input_runtime.text_scalar,
                        "compact_command_menu_active",
                    );
                    return true;
                }
                switch (byte) {
                    '\t' => if (menu == .usage) {
                        try cycleUsageMenuScope(app, 1);
                    },
                    '\r' => try submitCompactCommandMenuSelection(app, menu, max_input_len),
                    'r', 'R' => if (menu == .usage) {
                        if (comptime runtime_profile.allows(App, .profile_usage)) {
                            try reloadUsageMenu(
                                app,
                                app.input_runtime.usage_menu.navigationScope(),
                            );
                        }
                    },
                    10 => {
                        _ = moveCompactCommandMenu(app, menu, 1);
                        app.shell.render_requests.request(.footer);
                    },
                    11 => {
                        _ = moveCompactCommandMenu(app, menu, -1);
                        app.shell.render_requests.request(.footer);
                    },
                    else => {},
                }
                return true;
            }
            if (comptime runtime_profile.allows(App, .subagents)) {
                if (app.subagents.isViewActive()) {
                    try subagent_rt.handleSubagentRawInput(app, raw);
                    return true;
                }
            }
            return false;
        }

        fn presentedSubagentApproval(app: *const App) bool {
            if (comptime !@hasField(App, "subagents")) return false;
            if (comptime !@hasDecl(@TypeOf(app.subagents), "mainApprovalPresented")) {
                return false;
            }
            return app.subagents.mainApprovalPresented();
        }

        fn approvalOwnsCurrentSurface(app: *const App) bool {
            if (!app.approval_prompt.isActive()) return false;
            if (!app.subagents.isViewActive()) return true;
            const request = app.approval_prompt.request orelse return false;
            if (comptime !@hasDecl(@TypeOf(app.subagents), "childRouteId") or
                !@hasDecl(@TypeOf(app.subagents), "mainApprovalBinding"))
            {
                return true;
            }
            const committed = if (comptime @hasField(App, "approval_screen"))
                if (app.approval_screen.screen_commit) |commit|
                    commit.request_id == request.id
                else
                    false
            else
                false;
            var maybe_binding = app.subagents.mainApprovalBinding(request.id);
            if (maybe_binding == null and committed) {
                if (comptime @hasDecl(@TypeOf(app.subagents), "mainApprovalCardBinding")) {
                    maybe_binding = app.subagents.mainApprovalCardBinding(request.id);
                }
            }
            const binding = maybe_binding orelse return false;
            // The current card remains resolvable while its presented flag and
            // selected child route catch up with the committed approval screen.
            if (committed) return true;
            const child_id = app.subagents.childRouteId() orelse return false;
            return std.mem.eql(u8, binding.child_id, child_id);
        }

        fn handleTextByte(app: *App, owner: text_scalar.Owner, byte: u8, max_input_len: usize) !void {
            const transition = text_scalar.advance(app.input_runtime.text_scalar, owner, byte);
            app.input_runtime.text_scalar = transition.next;
            const step = transition.step;
            if (step.dropped) |drop| {
                debug_trace.logf(
                    "input",
                    "text scalar dropped owner={s} bytes={d} reason={s}",
                    .{ @tagName(drop.owner), drop.bytes, @tagName(drop.reason) },
                );
            }
            const scalar = step.scalar orelse return;
            const bytes = scalar.slice();
            switch (scalar.owner) {
                .question_freeform => switch (try app.question_prompt.insertFreeformSlice(app.alloc, bytes, max_input_len)) {
                    .inserted => {
                        app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                        app.shell.render_requests.request(.modal);
                    },
                    .inactive => {},
                    .limit_exceeded => try input_limit_feedback.report(App, app, .question_freeform, bytes.len),
                },
                .approval_amendment => switch (try app.approval_prompt.decision.insertAmendmentSlice(app.alloc, bytes, max_input_len)) {
                    .inserted => {
                        app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                        app.shell.render_requests.request(.modal);
                    },
                    .inactive => {},
                    .limit_exceeded => try input_limit_feedback.report(App, app, .approval_amendment, bytes.len),
                },
                .composer => {
                    if (!app.input_runtime.replacementState(&app.pending_images).canReplaceSelectionOrInsert(
                        bytes.len,
                        max_input_len,
                    )) {
                        try input_limit_feedback.report(App, app, .composer, bytes.len);
                        return;
                    }
                    if (dismissActiveMenusForComposerEdit(app)) {
                        app.shell.render_requests.request(.footer);
                    }
                    if (comptime @hasField(App, "queued_prompt_review")) {
                        queue_rt.markVisibleSelectionDirty(app);
                    }
                    switch (try insertComposerSliceBounded(
                        app,
                        bytes,
                        max_input_len,
                        completion_rt.shouldPreserveModelPickerInsert(app),
                    )) {
                        .inserted => {},
                        .inactive => unreachable,
                        .limit_exceeded => {
                            try input_limit_feedback.report(App, app, .composer, bytes.len);
                            return;
                        },
                    }
                    app.input_runtime.picker.resetFilePickerIndex();
                    syncCatalogMenus(app);
                    app.shell.render_requests.request(.footer);
                },
            }
        }

        fn handleComposerByte(
            app: *App,
            byte: u8,
            composer_shortcut: ?input_action.ShortcutAction,
            max_input_len: usize,
            max_prompt_history: usize,
        ) !void {
            switch (byte) {
                3 => {
                    try handleSemanticCtrlC(app);
                },
                4 => {
                    try handleSemanticCtrlD(app, max_input_len);
                },
                '\t' => {
                    if (comptime @hasField(App, "queued_prompt_review")) {
                        queue_rt.markVisibleSelectionDirty(app);
                    }
                    if (cycleHelpMenuCategory(app, 1) or cycleSettingsMenuCategory(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (moveAuthPickerIfActive(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (try toggleSessionPickerScopeIfActive(app)) {
                        app.shell.render_requests.request(.footer);
                    } else if (cycleModelMenuProvider(app, 1) or cycleSkillsMenuSource(app, 1)) {
                        app.shell.render_requests.request(.footer);
                    } else if (!app.stream.active and picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) {
                        try completion_rt.openCurrentModelPicker(app);
                    } else if (completion_rt.hasFileQuery(app)) {
                        if ((try completion_rt.autocompleteFilePickerSelection(app, max_input_len)) == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                    } else if (!commandSkillsMenuActive(app) and completion_rt.hasModelQuery(app)) {
                        // Mid-turn: list is hidden — do not autocomplete a hidden index.
                        if (!app.stream.active) {
                            try completion_rt.autocompleteModelPickerSelection(app);
                        }
                    } else if (completion_rt.visibleInlineCompletion(app) != null) {
                        if ((try completion_rt.autocompleteInlineCompletion(app, max_input_len)) == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                    } else if (!(app.stream.active and app.input_runtime.picker.isModelShapedInput(&app.input_runtime.edit_state))) {
                        const count = completion_rt.visibleSlashCompletionCount(app);
                        if (count > 0) {
                            const items = app.input_runtime.edit_state.input.items;
                            const prefix = command_specs.slashCompletionPrefix(
                                app.slashRegistry(),
                                items,
                            ) orelse return;
                            const idx = app.input_runtime.picker.slash_completion_index % count;
                            if (try bindSelectedSlashSkill(app, idx)) {
                                app.shell.render_requests.request(.footer);
                            } else if (command_specs.nthSlashCompletion(app.slashRegistry(), prefix, idx)) |completion| {
                                if (command_specs.slashCompletionHasArgs(app.slashRegistry(), completion)) {
                                    var buf: [128]u8 = undefined;
                                    const with_space = std.fmt.bufPrint(&buf, "{s} ", .{completion}) catch completion;
                                    try app.input_runtime.textReplacementState().replace(app.alloc, with_space);
                                } else {
                                    try app.input_runtime.textReplacementState().replace(app.alloc, completion);
                                }
                                app.shell.render_requests.request(.footer);
                            }
                        }
                    }
                },
                ' ' => {
                    dismissMentionSkillsMenuForSpace(app);
                    if (app.input_runtime.edit_state.selectionRange() == null and
                        !commandSkillsMenuActive(app) and
                        completion_rt.hasModelQuery(app))
                    {
                        if (try completion_rt.advanceModelPickerOnSpace(app)) {
                            app.shell.render_requests.request(.footer);
                        }
                    } else {
                        switch (try insertComposerSliceBounded(app, " ", max_input_len, false)) {
                            .inserted => {
                                syncCatalogMenus(app);
                                app.shell.render_requests.request(.footer);
                            },
                            .inactive => unreachable,
                            .limit_exceeded => try input_limit_feedback.report(App, app, .composer, 1),
                        }
                    }
                },
                22 => {
                    try image_commands.Commands(App).attachClipboard(app);
                },
                24 => {
                    if (settingsMenuActive(app) or helpMenuActive(app) or skillsMenuActive(app) or modelMenuActive(app) or sessionMenuActive(app)) return;
                    if (comptime runtime_profile.allows(App, .subagents)) {
                        try subagent_rt.toggleSubagentView(app);
                    }
                },
                '\r' => {
                    if (try submitSettingsMenuSelection(app)) return;
                    if (try submitHelpMenuSelection(app, max_input_len, max_prompt_history)) return;
                    if (try submitAuthPickerSelection(app)) return;
                    if (try submitModelMenuSelection(app)) return;
                    if (try submitSkillsMenuSelection(app, max_input_len)) return;
                    if (try submitSlashPickerSelection(app)) return;
                    if (comptime runtime_profile.allows(App, .durable_sessions)) {
                        if (try submitSessionPickerSelection(app)) return;
                    }
                    if (try completion_rt.submitFilePickerOnEnter(app, max_input_len)) |result| {
                        if (result == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                        }
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    if (picker_state.isBareModelCommandAtCursor(&app.input_runtime.edit_state)) {
                        try openModelBrowseCatalog(app);
                        return;
                    }
                    if (completion_rt.hasModelQuery(app)) {
                        if (app.stream.active) {
                            if (try submitExplicitModelSelection(
                                app,
                                resolveExplicitModelSelection(app, app.input_runtime.edit_state.input.items),
                            )) return;
                            try app.writeDomainNotice(.{
                                .topic = "model",
                                .tone = .neutral,
                                .body = "Complete the model selection for the next turn: /model <id> <effort> [normal|fast].",
                            }, true);
                            app.shell.render_requests.request(.footer);
                            return;
                        }
                        if (try completion_rt.submitModelPicker(app)) return;
                    }
                    if (try submitExplicitModelSelection(
                        app,
                        resolveExplicitModelSelection(app, app.input_runtime.edit_state.input.items),
                    )) return;
                    if (app.input_runtime.lineContinuationState().replaceBackslashBeforeCursorWithNewline(app.alloc)) {
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    debug_trace.logf("input", "submit requested stream_active={s} queued={d} input_bytes={d}", .{ if (app.stream.active) "true" else "false", app.worker.queuedPromptCount(), app.input_runtime.edit_state.input.items.len });
                    try submit_rt.submit(app, max_prompt_history);
                },
                else => {
                    if (composer_shortcut) |action| {
                        try routeComposerShortcutAction(app, action, max_input_len);
                        return;
                    }
                    if (byte >= 32 and byte != 127) {
                        const insertion_start = if (app.input_runtime.edit_state.selectionRange()) |selection|
                            selection.start
                        else
                            app.input_runtime.edit_state.cursor;
                        if (byte == '$' and insertion_start == 0 and !helpMenuActive(app) and !commandSkillsMenuActive(app) and !modelMenuActive(app)) {
                            if ((try insertComposerSliceBounded(app, &.{byte}, max_input_len, false)) == .limit_exceeded) {
                                try input_limit_feedback.report(App, app, .composer, 1);
                                return;
                            }
                            if (comptime @hasField(App, "skills")) {
                                app.skills.openMenuWithQuery(.dollar, .{ .start = insertion_start, .end = insertion_start + 1 }, "");
                            }
                            app.input_runtime.picker.resetFilePickerIndex();
                            app.shell.render_requests.request(.footer);
                            return;
                        }
                        const result = try insertComposerSliceBounded(
                            app,
                            &.{byte},
                            max_input_len,
                            completion_rt.shouldPreserveModelPickerInsert(app),
                        );
                        if (result == .limit_exceeded) {
                            try input_limit_feedback.report(App, app, .composer, 1);
                            return;
                        }
                        app.input_runtime.picker.resetFilePickerIndex();
                        syncCatalogMenus(app);
                        app.shell.render_requests.request(.footer);
                    }
                },
            }
        }

        fn handleSemanticCtrlC(app: *App) !void {
            const now = io_mod.milliTimestamp();
            const transition = gesture_state.pressCtrlCExit(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.result == .activated) {
                app_session_runtime.Runtime(App).requestResumeHandoff(app);
                app.should_exit = true;
                return;
            }

            debug_trace.logf("input", "ctrl_c_exit_hint_armed", .{});

            if (app.stream.active) {
                try interrupt_rt.cancelActiveOperation(app);
                app.shell.render_requests.request(.footer);
                return;
            }

            if (comptime @hasDecl(App, "cancelPendingSubmission")) {
                if (App.cancelPendingSubmission(app)) return;
            }

            if (draftHasState(app)) clearDraftState(app, "ctrl_c");
            app.shell.render_requests.request(.footer);
        }

        fn draftHasState(app: *App) bool {
            return app.input_runtime.edit_state.input.items.len > 0 or
                app.input_runtime.entities.pasted_blocks.items.len > 0 or
                app.pending_images.items.len > 0;
        }

        fn refuseSessionActionWithDraft(app: *App, body: []const u8) !bool {
            if (!draftHasState(app)) return false;
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .neutral,
                .body = body,
            }, true);
            return true;
        }

        fn clearDraftState(app: *App, reason: []const u8) void {
            debug_trace.logf(
                "input",
                "draft cleared reason={s} input_bytes={d} pasted_blocks={d} images={d}",
                .{
                    reason,
                    app.input_runtime.edit_state.input.items.len,
                    app.input_runtime.entities.pasted_blocks.items.len,
                    app.pending_images.items.len,
                },
            );
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.clearPendingImages();
            syncCatalogMenus(app);
        }

        fn handleSemanticCtrlD(app: *App, max_input_len: usize) !void {
            if (app.input_runtime.edit_state.input.items.len > 0) {
                try routeComposerShortcutAction(app, .delete_forward, max_input_len);
                return;
            }
            if (app.stream.active) return;
            app_session_runtime.Runtime(App).requestResumeHandoff(app);
            app.should_exit = true;
        }

        fn isComposerEditingByte(
            byte: u8,
            composer_shortcut: ?input_action.ShortcutAction,
        ) bool {
            if (composer_shortcut) |shortcut| {
                return switch (shortcut) {
                    .redraw => false,
                    else => true,
                };
            }
            return switch (byte) {
                ' ', 22 => true,
                else => byte >= 32 and byte != 127,
            };
        }

        fn activeCatalogMenuOwnsByte(app: *App, byte: u8) bool {
            if (settingsMenuActive(app)) return true;
            if (helpMenuActive(app)) return true;
            if (modelMenuActive(app)) return true;
            if (sessionMenuActive(app)) return true;
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            return byte == ' ' or commandSkillsMenuActive(app);
        }

        fn moveAuthPickerIfActive(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (app.stream.active) return false;
            return app.auth.movePicker(delta);
        }

        fn submitSessionPickerSelection(app: *App) !bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;

            if (app.loadMoreSessionPicker() catch |err| {
                const notice = try std.fmt.allocPrint(
                    app.alloc,
                    "unable to load more saved sessions: {s}",
                    .{@errorName(err)},
                );
                defer app.alloc.free(notice);
                try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = notice }, true);
                app.shell.render_requests.request(.footer);
                return true;
            }) return true;

            if (app.session_persistence.session_picker.selectedId() == null) return true;

            _ = app.resumeSelectedSession() catch |err| {
                const picker = &app.session_persistence.session_picker;
                debug_trace.logf(
                    "session",
                    "picker resume failed err={s} picker_active={s}",
                    .{ @errorName(err), if (picker.active) "true" else "false" },
                );
                if (picker.active) {
                    picker.selection_failure = classifyResumeFailure(err);
                } else {
                    try app.writeDomainNotice(.{
                        .topic = "session",
                        .tone = .@"error",
                        .body = "Unable to resume selected session.",
                    }, true);
                }
                app.shell.render_requests.request(.footer);
                return true;
            };
            return true;
        }

        fn dismissAuthPickerForComposerEdit(app: *App) bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (!app.auth.pickerView().active) return false;
            app.auth.closePicker(app.alloc);
            return true;
        }

        fn popOrCloseAuthPicker(app: *App) bool {
            if (comptime !@hasField(App, "auth")) return false;
            const picker = app.auth.pickerView();
            if (!picker.active) return false;
            if (picker.stage == .root and picker.include_skip) app.auth.skipOnboarding();
            return app.auth.popPickerStage(app.alloc);
        }

        fn commandSkillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.menu.active and !app.skills.menu.origin.isMention();
        }

        fn skillsMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            return app.skills.menu.active;
        }

        fn modelMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            return app.model_cache.menu.active;
        }

        fn sessionMenuActive(app: *App) bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            return app.session_persistence.session_picker.active;
        }

        fn helpMenuActive(app: *App) bool {
            return app.input_runtime.help_menu.active;
        }

        fn settingsMenuActive(app: *App) bool {
            return app.input_runtime.settings_menu.active;
        }

        const CompactCommandMenuKind = enum {
            statusline,
            usage,
            workspace,
        };

        fn activeCompactCommandMenu(app: *App) ?CompactCommandMenuKind {
            if (app.input_runtime.statusline_menu.active) return .statusline;
            if (app.input_runtime.usage_menu.active) return .usage;
            if (app.input_runtime.workspace_menu.active) return .workspace;
            return null;
        }

        // A space never extends a mention token, so it ends the mention and
        // inserts through the normal composer path.
        fn dismissMentionSkillsMenuForSpace(app: *App) void {
            if (comptime !@hasField(App, "skills")) return;
            if (!app.skills.menu.active) return;
            if (!app.skills.menu.origin.isMention()) return;
            app.skills.closeMenu();
            app.shell.render_requests.request(.footer);
        }

        fn closeSkillsMenu(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            app.skills.closeMenu();
            return true;
        }

        fn closeHelpMenu(app: *App, clear_query: bool) bool {
            if (!app.input_runtime.help_menu.active) return false;
            app.input_runtime.help_menu.close();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn closeSettingsMenu(app: *App, clear_query: bool) bool {
            if (!app.input_runtime.settings_menu.active) return false;
            app.input_runtime.settings_menu.close();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn closeModelMenu(app: *App, clear_query: bool) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            app.model_cache.closeMenu();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn openModelBrowseCatalog(app: *App) !void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (comptime @hasDecl(App, "ensureModelCache")) app.ensureModelCache();
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            try app.model_cache.openMenu();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.shell.render_requests.request(.footer);
        }

        fn toggleSessionPickerScopeIfActive(app: *App) !bool {
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return false;
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;
            return try app_session_runtime.Runtime(App).toggleSessionPickerScope(app);
        }

        fn dismissActiveMenusForComposerEdit(app: *App) bool {
            return dismissAuthPickerForComposerEdit(app);
        }

        fn dismissActiveMenusThenRedraw(app: *App) void {
            if (dismissActiveMenusForComposerEdit(app)) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn submitSkillsMenuSelection(app: *App, max_input_len: usize) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            // Captured before the sync: a stale $ anchor makes the sync close
            // the menu, and close() resets origin to .command.
            const origin = app.skills.menu.origin;
            syncSkillsMenu(app);
            const skill = app.skills.selectedMenuSkill() orelse {
                if (origin.isMention()) {
                    app.skills.closeMenu();
                    app.shell.render_requests.request(.footer);
                    return false;
                }
                return true;
            };
            const target = if (!origin.isMention())
                skill_runtime.SkillMenuTarget{ .start = 0, .end = app.input_runtime.edit_state.input.items.len }
            else
                app.skills.menu.target orelse skill_runtime.SkillMenuTarget{
                    .start = app.input_runtime.edit_state.cursor,
                    .end = app.input_runtime.edit_state.cursor,
                };
            const raw_len = app.input_runtime.entities.skillTokenInsertedLen(
                app.input_runtime.edit_state.input.items,
                target.end,
                skill.name,
            );
            if (!app.input_runtime.insertionState().canReplaceRange(
                target.start,
                target.end,
                raw_len,
                max_input_len,
            )) {
                app.skills.closeMenu();
                app.shell.render_requests.request(.footer);
                try input_limit_feedback.report(App, app, .composer, raw_len);
                return true;
            }

            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                target.start,
                target.end,
                skill.name,
                skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, skill),
            );
            app.skills.closeMenu();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn changeSettingsMenuSelection(app: *App, delta: i32) !void {
            const menu = &app.input_runtime.settings_menu;
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    if (delta < 0) try applyInlineSettingsModelSelection(app);
                    return;
                }
            }

            const snapshot = app_commands.settingsCatalogSnapshot(app);
            const query = app.input_runtime.edit_state.input.items;
            const item = menu.selectedItem(&snapshot, query) orelse return;
            if (item.id == .model) {
                if (delta > 0 and comptime @hasField(App, "model_cache")) {
                    if (comptime @hasDecl(App, "ensureModelCache")) app.ensureModelCache();
                    try app.model_cache.openMenu();
                    app.shell.render_requests.request(.footer);
                }
                return;
            }

            const change = menu.changeSelectedOption(&snapshot, query, delta) orelse return;
            if (comptime @hasDecl(App, "notificationPreferences")) {
                try app_commands.applySettingsCatalogChange(app, change);
            }
            app.shell.render_requests.request(.footer);
        }

        fn applyInlineSettingsModelSelection(app: *App) !void {
            const selected = (try app.model_cache.menu.selectedModelAlloc(app.alloc)) orelse return;
            defer app.alloc.free(selected);
            try session_commands.Commands(App).selectModelFromPicker(
                app,
                selected,
                app.effort,
                app.fast_mode,
            );
            app.model_cache.closeMenu();
            app.shell.render_requests.request(.footer);
        }

        fn submitSettingsMenuSelection(app: *App) !bool {
            if (!settingsMenuActive(app)) return false;
            if (comptime @hasField(App, "model_cache")) {
                if (app.model_cache.menu.active) {
                    try applyInlineSettingsModelSelection(app);
                    return true;
                }

                const snapshot = app_commands.settingsCatalogSnapshot(app);
                const selected = app.input_runtime.settings_menu.selectedItem(
                    &snapshot,
                    app.input_runtime.edit_state.input.items,
                ) orelse return true;
                if (selected.id == .model) {
                    if (comptime @hasDecl(App, "ensureModelCache")) app.ensureModelCache();
                    try app.model_cache.openMenu();
                    app.shell.render_requests.request(.footer);
                }
            }
            return true;
        }

        fn submitCompactCommandMenuSelection(
            app: *App,
            menu: CompactCommandMenuKind,
            max_input_len: usize,
        ) !void {
            if (menu == .workspace) {
                try prepareWorkspaceMenuCommand(app, max_input_len);
                return;
            }
            if (menu == .usage) {
                _ = app.input_runtime.usage_menu.toggleExpanded(
                    usageMenuVisibleModelItems(app),
                );
                app.shell.render_requests.request(.footer);
                return;
            }
            const snapshot = app_commands.settingsCatalogSnapshot(app);
            const change = switch (menu) {
                .statusline => app.input_runtime.statusline_menu.selectedChange(snapshot),
                .usage, .workspace => unreachable,
            } orelse return;
            if (comptime @hasDecl(App, "notificationPreferences")) {
                try app_commands.applySettingsCatalogMenuChange(app, change);
            }
            app.shell.render_requests.request(.footer);
        }

        fn prepareWorkspaceMenuCommand(app: *App, max_input_len: usize) !void {
            if (comptime !@hasDecl(App, "workspaceAccess")) return;
            const entries = app.workspaceAccess().entries;
            const action = app.input_runtime.workspace_menu.selectedAction(entries) orelse return;

            var command: std.Io.Writer.Allocating = .init(app.alloc);
            defer command.deinit();
            switch (action) {
                .add => try command.writer.writeAll("/workspace add "),
                .remove => |index| {
                    if (index >= entries.len) return;
                    try command.writer.print("/workspace remove {s}", .{entries[index].path});
                },
                .clear => try command.writer.writeAll("/workspace clear"),
            }
            const text = command.written();
            if (text.len > max_input_len) return;
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                text,
            );
            defer prepared_input.deinit(app.alloc);

            app.input_runtime.workspace_menu.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            app.input_runtime.picker.dismissInlinePicker(.slash);
            app.shell.render_requests.request(.footer);
        }

        fn moveCompactCommandMenu(app: *App, menu: CompactCommandMenuKind, delta: i32) bool {
            return switch (menu) {
                .statusline => app.input_runtime.statusline_menu.move(delta),
                .usage => app.input_runtime.usage_menu.moveModel(
                    delta,
                    usageMenuVisibleModelItems(app),
                ),
                .workspace => if (comptime @hasDecl(App, "workspaceAccess"))
                    app.input_runtime.workspace_menu.move(
                        delta,
                        app.workspaceAccess().entries,
                    )
                else
                    false,
            };
        }

        fn usageMenuVisibleModelItems(app: *App) u16 {
            const projection = render_input.usageMenuProjection(
                &app.input_runtime.usage_menu,
            );
            const menu: render_input.CompactCommandMenuProjection = .{
                .usage = projection,
            };
            const visible_rows = @min(
                compact_command_menu_presentation.desiredRowCount(
                    menu,
                    app.shell.layout.cols,
                ),
                app.shell.layout.rows -| 3,
            );
            return compact_command_menu_presentation.usageVisibleModelItems(
                projection,
                visible_rows,
                app.shell.layout.cols,
            );
        }

        fn routeCompactCommandMenuEscapeAction(
            app: *App,
            menu: CompactCommandMenuKind,
            resolved: input_action.Action,
        ) !void {
            if (menu == .usage and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                const current = app.input_runtime.usage_menu.navigationScope();
                const next = if (resolved == .cursor_left)
                    current.previous()
                else
                    current.next();
                if (next != current) {
                    try refreshUsageMenu(app, next);
                }
                return;
            }
            if (menu == .usage and resolved == .toggle_permission_mode) {
                try cycleUsageMenuScope(app, -1);
                return;
            }
            if (menu == .statusline and
                (resolved == .cursor_left or resolved == .cursor_right))
            {
                const snapshot = app_commands.settingsCatalogSnapshot(app);
                const delta: i32 = if (resolved == .cursor_left) -1 else 1;
                const change = switch (menu) {
                    .statusline => app.input_runtime.statusline_menu.changeSelectedOption(&snapshot, delta),
                    .usage, .workspace => unreachable,
                } orelse return;
                if (comptime @hasDecl(App, "notificationPreferences")) {
                    try app_commands.applySettingsCatalogMenuChange(app, change);
                }
                return;
            }
            const delta: i32 = switch (resolved) {
                .cursor_up => -1,
                .cursor_down => 1,
                else => return,
            };
            _ = moveCompactCommandMenu(app, menu, delta);
            app.shell.render_requests.request(.footer);
        }

        fn refreshUsageMenu(app: *App, scope: usage_report.Scope) !void {
            if (comptime !runtime_profile.allows(App, .profile_usage)) return;
            if (comptime @hasDecl(App, "refreshUsageMenu")) {
                try app.refreshUsageMenu(scope);
            } else {
                try app_commands.Handlers(App).refreshUsageMenu(app, scope);
            }
        }

        fn reloadUsageMenu(app: *App, scope: usage_report.Scope) !void {
            if (comptime !runtime_profile.allows(App, .profile_usage)) return;
            if (comptime @hasDecl(App, "reloadUsageMenu")) {
                try app.reloadUsageMenu(scope);
            } else if (comptime @hasDecl(App, "refreshUsageMenu")) {
                try app.refreshUsageMenu(scope);
            } else {
                try app_commands.Handlers(App).reloadUsageMenu(app, scope);
            }
        }

        fn cycleUsageMenuScope(app: *App, delta: i32) !void {
            const current = app.input_runtime.usage_menu.navigationScope();
            const next: usage_report.Scope = if (delta < 0)
                switch (current) {
                    .days_30 => .session,
                    .days_7 => .days_30,
                    .hours_24 => .days_7,
                    .session => .hours_24,
                }
            else switch (current) {
                .days_30 => .days_7,
                .days_7 => .hours_24,
                .hours_24 => .session,
                .session => .days_30,
            };
            try refreshUsageMenu(app, next);
        }

        fn submitHelpMenuSelection(app: *App, max_input_len: usize, max_prompt_history: usize) !bool {
            if (!app.input_runtime.help_menu.active) return false;
            if (app.slashRegistry().matchExact(app.input_runtime.edit_state.input.items) != null) {
                app.input_runtime.help_menu.close();
                return false;
            }
            const selected = app.input_runtime.help_menu.selectedSpec(
                app.slashRegistry(),
                app.input_runtime.edit_state.input.items,
            ) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            const inserted_len = selected.command.len + @intFromBool(selected.has_args);
            if (inserted_len > max_input_len) return true;
            var prepared_input = try app.input_runtime.textReplacementState().prepare(
                app.alloc,
                selected.command,
            );
            defer prepared_input.deinit(app.alloc);

            app.input_runtime.help_menu.close();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            app.input_runtime.textReplacementState().commit(app.alloc, &prepared_input);
            if (selected.has_args) {
                try app.input_runtime.insertionState().insertByte(app.alloc, ' ', .clear);
                app.shell.render_requests.request(.footer);
                return true;
            }
            try submit_rt.submit(app, max_prompt_history);
            return true;
        }

        fn submitModelMenuSelection(app: *App) !bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            const selected = (try app.model_cache.menu.selectedModelAlloc(app.alloc)) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            defer app.alloc.free(selected);

            app.model_cache.closeMenu();
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            try completion_rt.beginExactModelSelection(app, selected);
            return true;
        }

        fn submitAuthPickerSelection(app: *App) !bool {
            if (comptime !@hasField(App, "auth")) return false;
            if (app.stream.active) return false;
            if (!app.auth.pickerView().active) return false;
            const choice = app.auth.takePickerChoice(app.alloc) orelse {
                app.shell.render_requests.request(.footer);
                return true;
            };
            app.applyAuthPickerChoice(choice) catch |err| {
                debug_trace.logf("auth", "picker choice failed choice={s} err={s}", .{ @tagName(choice), @errorName(err) });
                app.auth.closePicker(app.alloc);
                try app.writeDomainNotice(.{
                    .topic = "auth",
                    .tone = .@"error",
                    .body = "Could not load that credential. The current source is unchanged.",
                }, true);
                app.shell.render_requests.request(.footer);
                return true;
            };
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn submitSlashPickerSelection(app: *App) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (nonSlashPickerOwnsEnter(app)) return false;
            const items = app.input_runtime.edit_state.input.items;
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                items,
            ) orelse return false;
            if (app.slashRegistry().matchExact(prefix) != null) return false;
            const count = completion_rt.visibleSlashCompletionCount(app);
            if (count == 0) return false;
            const idx = app.input_runtime.picker.slash_completion_index % count;
            if (!picker_presentation.mixedSlashCompletionIsSkill(
                app.slashRegistry(),
                prefix,
                app.skills.items,
                idx,
            )) {
                const selected = picker_presentation.nthMixedSlashCompletionText(
                    app.slashRegistry(),
                    prefix,
                    app.skills.items,
                    idx,
                ) orelse return false;
                const spec = app.slashRegistry().matchExact(selected) orelse return false;
                if (spec.command.kind != .model) return false;
                try openModelBrowseCatalog(app);
                return true;
            }
            return try bindSelectedSlashSkill(app, idx);
        }

        fn nonSlashPickerOwnsEnter(app: *App) bool {
            if (completion_rt.filePickerOwnsSurface(app)) return true;
            // Bare `/model` and `/model …` own Enter over slash/skill bind. Mid-turn
            // commit is gated separately when the model list stays hidden.
            if (app.input_runtime.picker.isModelShapedInput(&app.input_runtime.edit_state)) return true;
            if (comptime @hasField(App, "stream")) {
                if (app.stream.active) return false;
            }
            if (comptime @hasField(App, "session_persistence")) {
                if (app.session_persistence.session_picker.active) return true;
            }
            if (comptime @hasField(App, "auth")) {
                if (app.auth.pickerView().active) return true;
            }
            return false;
        }

        fn resolveExplicitModelSelection(app: *App, input: []const u8) ExplicitModelSelectionParse {
            return switch (parseExplicitModelSelection(input)) {
                .selection => |selection| validateExplicitModelSelection(selection, model_capabilities.resolveForApp(App, app, selection.model)),
                .none => .none,
                .invalid => .invalid,
            };
        }

        fn submitExplicitModelSelection(
            app: *App,
            parsed: ExplicitModelSelectionParse,
        ) !bool {
            switch (parsed) {
                .none => return false,
                .invalid => {
                    try app.writeDomainNotice(.{
                        .topic = "model",
                        .tone = .@"error",
                        .body = "Invalid /model selection. Use /model <id> <effort> [normal|fast].",
                    }, true);
                },
                .selection => |selection| {
                    try session_commands.Commands(App).selectModelFromPicker(
                        app,
                        selection.model,
                        selection.effort,
                        selection.fast_mode,
                    );
                    app.input_runtime.inputResetState().clearCurrent(app.alloc);
                },
            }
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn bindSelectedSlashSkill(app: *App, selected_index: usize) !bool {
            if (comptime !@hasField(App, "skills")) return false;
            const items = app.input_runtime.edit_state.input.items;
            const prefix = command_specs.slashCompletionPrefix(
                app.slashRegistry(),
                items,
            ) orelse return false;
            const skill = picker_presentation.nthMixedSlashCompletionSkill(
                app.slashRegistry(),
                prefix,
                app.skills.items,
                selected_index,
            ) orelse return false;
            const leading_ws = items.len - prefix.len;
            try app.input_runtime.skillBindingState().bindSkillToken(
                app.alloc,
                leading_ws,
                leading_ws + prefix.len,
                skill.name,
                skill.path,
                skill_runtime.skillDisplaySource(app.skills.items, skill),
            );
            app.input_runtime.picker.resetInlinePickerEpisode();
            app.shell.render_requests.request(.footer);
            return true;
        }

        fn syncCatalogMenus(app: *App) void {
            syncSettingsMenu(app);
            syncHelpMenu(app);
            syncSkillsMenu(app);
            syncModelMenu(app);
            syncSessionMenu(app);
        }

        fn syncSettingsMenu(app: *App) void {
            if (!app.input_runtime.settings_menu.active) return;
            app.input_runtime.settings_menu.resetForQuery();
        }

        fn syncHelpMenu(app: *App) void {
            if (!app.input_runtime.help_menu.active) return;
            app.input_runtime.help_menu.resetForQuery();
        }

        fn syncSkillsMenu(app: *App) void {
            if (comptime !@hasField(App, "skills")) return;
            if (!app.skills.menu.active) return;
            if (!app.skills.menu.origin.isMention()) {
                app.skills.menu.setQuery(app.input_runtime.edit_state.input.items);
                app.skills.menu.clamp(app.skills.items);
                return;
            }
            const target = app.skills.menu.target orelse return;
            const items = app.input_runtime.edit_state.input.items;
            if (target.start >= items.len or items[target.start] != '$') {
                app.skills.closeMenu();
                return;
            }
            const end = skillTokenEnd(items, target.start + 1);
            app.skills.menu.target = .{ .start = target.start, .end = end };
            app.skills.menu.setQuery(items[target.start + 1 .. end]);
            app.skills.menu.clamp(app.skills.items);
        }

        fn syncModelMenu(app: *App) void {
            if (comptime !@hasField(App, "model_cache")) return;
            if (!app.model_cache.menu.active) return;
            app.model_cache.setMenuQuery(app.input_runtime.edit_state.input.items);
        }

        fn syncSessionMenu(app: *App) void {
            if (comptime !@hasField(App, "session_persistence")) return;
            const picker = &app.session_persistence.session_picker;
            if (!picker.active) return;
            picker.setQuery(app.input_runtime.edit_state.input.items);
        }

        fn skillTokenEnd(items: []const u8, start: usize) usize {
            var end = start;
            while (end < items.len) : (end += 1) {
                const byte = items[end];
                if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':')) break;
            }
            return end;
        }

        fn cycleSkillsMenuSource(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            return app.skills.moveMenuSourceFilter(delta);
        }

        fn slashMenuVisibleForCue(app: *App) bool {
            if (comptime !@hasDecl(App, "playSlashMenuSound")) return false;
            if (comptime @hasDecl(App, "soundMaxEnabled")) {
                if (!app.soundMaxEnabled()) return false;
            }
            return completion_rt.slashCompletionCount(app) > 0;
        }

        fn announceSlashMenuOpened(app: *App, was_visible: bool) void {
            if (comptime !@hasDecl(App, "playSlashMenuSound")) return;
            if (comptime @hasDecl(App, "soundMaxEnabled")) {
                if (!app.soundMaxEnabled()) return;
            }
            if (was_visible) return;
            if (completion_rt.slashCompletionCount(app) == 0) return;
            app.playSlashMenuSound();
        }

        fn cycleModelMenuProvider(app: *App, delta: i32) bool {
            if (comptime !@hasField(App, "model_cache")) return false;
            if (!app.model_cache.menu.active) return false;
            _ = app.model_cache.menu.moveProvider(delta);
            return true;
        }

        fn cycleSettingsMenuCategory(app: *App, delta: i32) bool {
            if (!app.input_runtime.settings_menu.cycleCategory(delta)) return false;
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            return true;
        }

        fn cycleHelpMenuCategory(app: *App, delta: i32) bool {
            return app.input_runtime.help_menu.cycleCategory(delta);
        }

        fn expireEscClearArm(app: *App, now: i64) void {
            const transition = gesture_state.expireEscapeClear(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                app.shell.render_requests.request(.footer);
            }
        }

        fn expireCtrlCExitArm(app: *App, now: i64) void {
            const transition = gesture_state.expireCtrlCExit(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason=timeout",
                    .{},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn disarmCtrlCExit(app: *App, reason: []const u8) void {
            const transition = gesture_state.disarmCtrlCExit(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.cleared) {
                debug_trace.logf(
                    "input",
                    "event=ctrl_c_exit_disarmed reason={s}",
                    .{reason},
                );
                app.shell.render_requests.request(.footer);
            }
        }

        fn disarmEscapeClear(app: *App) bool {
            const transition = gesture_state.disarmEscapeClear(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = transition.next;
            return transition.cleared;
        }

        fn resolveEscape(app: *App, was_cancel_pending: bool, now: i64) !void {
            if (try full_transcript_rt.routeAction(app, .escape)) return;
            if (comptime runtime_profile.allows(App, .subagents)) {
                if (app.subagents.isViewActive()) {
                    _ = disarmEscapeClear(app);
                    if (approvalOwnsCurrentSurface(app)) {
                        if (was_cancel_pending) {
                            try approval_rt.cancelApprovalOperation(app);
                        }
                        return;
                    }
                    try subagent_rt.routeSubagentEscapeAction(
                        app,
                        .escape,
                        null,
                        .escape,
                    );
                    return;
                }
            }
            if (was_cancel_pending) {
                if (app.question_prompt.isActive()) {
                    // Freeform answers mirror the composer's Esc contract:
                    // Esc on a non-empty draft arms, a second press within
                    // the window clears it, and only an empty field lets
                    // Esc cancel the batch.
                    if (app.question_prompt.freeformDraftLen() > 0) {
                        const transition = gesture_state.pressEscapeClear(
                            app.input_runtime.gestures,
                            now,
                        );
                        app.input_runtime.gestures = transition.next;
                        if (transition.result == .activated) {
                            app.question_prompt.clearFreeformDraft("escape_clear");
                        }
                        app.shell.render_requests.request(.modal);
                        app.shell.render_requests.request(.footer);
                        return;
                    }
                    try question_rt.cancelQuestionPrompt(app);
                    return;
                }
                if (app.approval_prompt.isActive()) {
                    try approval_rt.cancelApprovalOperation(app);
                    _ = disarmEscapeClear(app);
                    return;
                }
                if (cancelCompactCommandMenu(app) or cancelSettingsMenu(app) or cancelHelpMenu(app) or cancelModelMenu(app) or cancelSkillsMenu(app) or cancelSessionMenu(app)) {
                    _ = disarmEscapeClear(app);
                    app.shell.render_requests.request(.footer);
                    return;
                }
                if (completion_rt.dismissVisibleInlinePicker(app)) {
                    _ = disarmEscapeClear(app);
                    app.shell.render_requests.request(.footer);
                    return;
                }
                if (comptime @hasField(App, "queued_prompt_review")) {
                    if (try queue_rt.hideVisibleDraft(app)) {
                        _ = disarmEscapeClear(app);
                        return;
                    }
                }
                if (!interrupt_rt.pauseActiveRecovery(app)) {
                    try interrupt_rt.cancelActiveOperation(app);
                }
                _ = disarmEscapeClear(app);
                return;
            }

            if (app.approval_prompt.isActive()) {
                _ = disarmEscapeClear(app);
                return;
            }
            if (comptime runtime_profile.allows(App, .subagents)) {
                if (app.subagents.isViewActive()) {
                    _ = disarmEscapeClear(app);
                    try subagent_rt.routeSubagentEscapeAction(
                        app,
                        .escape,
                        null,
                        .escape,
                    );
                    return;
                }
            }
            if (cancelCompactCommandMenu(app) or cancelSettingsMenu(app) or cancelHelpMenu(app) or cancelModelMenu(app) or cancelSkillsMenu(app) or cancelSessionMenu(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (popOrCloseAuthPicker(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (completion_rt.dismissVisibleInlinePicker(app)) {
                _ = disarmEscapeClear(app);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (comptime @hasField(App, "queued_prompt_review")) {
                if (try queue_rt.hideVisibleDraft(app)) {
                    _ = disarmEscapeClear(app);
                    return;
                }
                if (queue_rt.cancelAllHiddenPostCancelQueued(app)) {
                    _ = disarmEscapeClear(app);
                    return;
                }
            }
            if (!draftHasState(app)) {
                _ = disarmEscapeClear(app);
                return;
            }
            const transition = gesture_state.pressEscapeClear(
                app.input_runtime.gestures,
                now,
            );
            app.input_runtime.gestures = transition.next;
            if (transition.result == .activated) {
                clearDraftState(app, "double_escape");
                app.shell.render_requests.request(.footer);
                if (comptime @hasDecl(App, "playInputClearedSound")) app.playInputClearedSound();
            } else {
                app.shell.render_requests.request(.footer);
            }
        }

        fn cancelSkillsMenu(app: *App) bool {
            if (comptime !@hasField(App, "skills")) return false;
            if (!app.skills.menu.active) return false;
            const clear_query = !app.skills.menu.origin.isMention();
            app.skills.closeMenu();
            if (clear_query) {
                app.input_runtime.inputResetState().clearCurrent(app.alloc);
                paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            }
            return true;
        }

        fn cancelCompactCommandMenu(app: *App) bool {
            if (app.input_runtime.statusline_menu.active) {
                app.input_runtime.statusline_menu.close();
                return true;
            }
            if (app.input_runtime.usage_menu.active) {
                app.input_runtime.usage_menu.close(app.alloc);
                return true;
            }
            if (app.input_runtime.workspace_menu.active) {
                app.input_runtime.workspace_menu.close();
                return true;
            }
            return false;
        }

        fn cancelHelpMenu(app: *App) bool {
            return closeHelpMenu(app, true);
        }

        fn cancelSettingsMenu(app: *App) bool {
            return closeSettingsMenu(app, true);
        }

        fn cancelModelMenu(app: *App) bool {
            return closeModelMenu(app, true);
        }

        fn cancelSessionMenu(app: *App) bool {
            if (comptime !@hasField(App, "session_persistence")) return false;
            if (!app.session_persistence.session_picker.active) return false;
            app_session_runtime.Runtime(App).cancelSessionPickerToComposer(app);
            app.input_runtime.inputResetState().clearCurrent(app.alloc);
            paste_blocks.clearBlocks(app.alloc, &app.input_runtime.entities.pasted_blocks);
            return true;
        }
    };
}
const ApprovalCancelEvent = enum {
    request_cancel,
};

const FakeApprovalCancelWorker = struct {
    cancel_requested: bool = false,
    order: [1]ApprovalCancelEvent = undefined,
    order_len: usize = 0,

    fn record(self: *FakeApprovalCancelWorker, event: ApprovalCancelEvent) void {
        if (self.order_len < self.order.len) {
            self.order[self.order_len] = event;
            self.order_len += 1;
        }
    }

    pub fn isCancelRequested(self: *const FakeApprovalCancelWorker) bool {
        return self.cancel_requested;
    }

    pub fn queuedPromptCount(_: *const FakeApprovalCancelWorker) usize {
        return 0;
    }

    pub fn requestCancel(self: *FakeApprovalCancelWorker) void {
        self.cancel_requested = true;
        self.record(.request_cancel);
    }

    pub fn cancelApprovalTurn(self: *FakeApprovalCancelWorker) void {
        self.requestCancel();
    }

    fn submitPermissionResponse(
        _: *FakeApprovalCancelWorker,
        _: u64,
        response: permission_request.OwnedPermissionResponse,
    ) worker_runtime.PermissionSubmissionResult {
        var owned = response;
        owned.deinit();
        return .accepted;
    }

    pub fn submitQuestionBatchAnswer(_: *FakeApprovalCancelWorker, _: std.mem.Allocator, _: ?[]const []const u8) !void {}
};

const FakeApprovalPacer = struct {
    cleared: bool = false,

    pub fn clear(self: *FakeApprovalPacer, alloc: std.mem.Allocator) void {
        _ = alloc;
        self.cleared = true;
    }
};

const FakeInactiveSubagents = struct {
    fn isViewActive(_: *const FakeInactiveSubagents) bool {
        return false;
    }
};

const FakeApprovalShell = struct {
    render_requests: render_request.RenderRequestState = .{},
    layout: types.Layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    },
    transcript: std.ArrayList(u8) = .empty,

    fn deinit(self: *FakeApprovalShell, alloc: std.mem.Allocator) void {
        self.transcript.deinit(alloc);
    }

    fn updateRawBytesEntry(_: *FakeApprovalShell, _: std.mem.Allocator, _: u32, _: []const u8) !bool {
        return false;
    }

    fn appendRawTranscriptEntry(_: *FakeApprovalShell, _: std.mem.Allocator, _: []const u8) !u32 {
        return 1;
    }

    pub fn scrollFullTranscript(
        _: *FakeApprovalShell,
        _: input_action.MouseWheel,
        _: transcript_runtime.TranscriptRuntime.FullTranscriptScrollUnit,
    ) void {}
};

const routing_test_slash_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .clear_screen, .command = "/clear", .help_entry = "/clear", .completion_description = "clear the terminal transcript", .presentation_category = .general },
    .{ .kind = .image, .command = "/image", .aliases = &.{"/img"}, .help_entry = "/image <path> (/img)", .completion_description = "attach an image by path", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .images, .command = "/images", .help_entry = "/images [clear]", .completion_description = "manage pending image attachments", .presentation_category = .media, .has_args = true, .accepts_payload = true },
    .{ .kind = .model, .command = "/model", .help_entry = "/model <id-or-query>", .completion_description = "choose a model", .presentation_category = .model, .has_args = true, .accepts_payload = true, .requires_prompt_credential = true },
    .{ .kind = .skills, .command = "/skills", .help_entry = "/skills", .completion_description = "browse and manage skills", .presentation_category = .extensions, .has_args = true, .accepts_payload = true },
    .{ .kind = .workspace, .command = "/workspace", .help_entry = "/workspace [list|add PATH|remove PATH|clear]", .completion_description = "manage additional workspace directories", .presentation_category = .workspace, .has_args = true, .accepts_payload = true },
};
const routing_test_slash_registry = command_specs.SlashRegistry{ .commands = routing_test_slash_specs[0..] };

const FakeApprovalCancelApp = struct {
    alloc: std.mem.Allocator,
    worker: FakeApprovalCancelWorker = .{},
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    question_prompt: question_prompt.QuestionPrompt = .{},
    subagents: FakeInactiveSubagents = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: test_ui_input.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    shell: FakeApprovalShell = .{},
    stream: types.StreamState = .{ .active = true },
    pacer: FakeApprovalPacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    last_class: transcript_runtime.RawEntryClass = .unknown_raw,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,

    pub fn slashRegistry(_: *const FakeApprovalCancelApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    fn deinit(self: *FakeApprovalCancelApp) void {
        self.approval_prompt.deinit(self.alloc);
        self.question_prompt.deinit(self.alloc);
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
    }

    fn clearPendingImages(self: *FakeApprovalCancelApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    fn ensureTrailingBlankRow(self: *FakeApprovalCancelApp) !void {
        try self.transcript.appendSlice(self.alloc, "\n\n");
    }

    fn writeTranscript(self: *FakeApprovalCancelApp, content: []const u8, redraw: bool) !void {
        _ = redraw;
        try self.transcript.appendSlice(self.alloc, content);
    }

    pub fn writeTranscriptClassified(self: *FakeApprovalCancelApp, content: []const u8, redraw: bool, class: transcript_runtime.RawEntryClass) !void {
        self.last_class = class;
        try self.writeTranscript(content, redraw);
    }

    pub fn writeDomainNotice(self: *FakeApprovalCancelApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
    }

    pub fn stopStream(self: *FakeApprovalCancelApp) void {
        self.stream = .{};
    }

    pub fn appendReplaceableTranscriptLine(self: *FakeApprovalCancelApp, content: []const u8) !u32 {
        try self.shell.transcript.appendSlice(self.alloc, content);
        return 1;
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *FakeApprovalCancelApp, content: []const u8, _: transcript_runtime.RawEntryClass) !u32 {
        return self.appendReplaceableTranscriptLine(content);
    }

    pub fn fileCompletions(
        _: *FakeApprovalCancelApp,
        _: []const u8,
        out: []file_index.SearchResult,
        _: []file_index.MatchSpan,
        _: []u8,
    ) file_index.SearchError!usize {
        if (out.len == 0) return 0;
        out[0] = .{ .path = "file.zig", .kind = .file, .matched_spans = &.{} };
        return 1;
    }

    pub fn modelCompletions(_: *FakeApprovalCancelApp, _: []const u8, out: [][]const u8) usize {
        if (out.len == 0) return 0;
        out[0] = "openai/gpt-5";
        return 1;
    }

    pub fn transitionFullTranscriptProjection(
        _: *FakeApprovalCancelApp,
        event: transcript_presentation.Event,
    ) !transcript_presentation.Depth {
        return transcript_presentation.Depth.inline_mode.transition(
            event,
        );
    }
};

const RoutingSelectedSubagent = struct {
    id: u64,
    label: []const u8,
    status: @import("../../ui/subagent/runtime.zig").Status,
    tool_calls: usize,
    current_activity: ?[]const u8,
};

const RoutingSubagents = struct {
    active: bool = false,
    main_approval_presented: bool = false,
    handled_keys: usize = 0,
    handled_raw_keys: usize = 0,
    handled_actions: usize = 0,
    last_handled_key: ?u8 = null,
    last_main_approval_id: ?u64 = null,
    toggle_view_calls: usize = 0,
    manager_paste: core_input_runtime.Runtime = .{},

    fn deinit(self: *RoutingSubagents, alloc: std.mem.Allocator) void {
        self.manager_paste.deinit(alloc);
    }

    pub fn isViewActive(self: *const RoutingSubagents) bool {
        return self.active;
    }

    pub fn mainApprovalPresented(self: *const RoutingSubagents) bool {
        return self.main_approval_presented;
    }

    pub fn selectedInfo(_: *const RoutingSubagents) ?RoutingSelectedSubagent {
        return null;
    }

    pub fn count(_: *const RoutingSubagents) usize {
        return 0;
    }

    pub fn panelText(_: *RoutingSubagents, alloc: std.mem.Allocator, _: u16, _: u16, _: transcript_runtime.Styles) ![]u8 {
        return alloc.dupe(u8, "");
    }

    pub fn handleKey(self: *RoutingSubagents, _: std.mem.Allocator, byte: u8) !subagent_input.Command {
        self.handled_keys += 1;
        self.handled_raw_keys += 1;
        self.last_handled_key = byte;
        return .none;
    }

    pub fn handleAction(self: *RoutingSubagents, _: std.mem.Allocator, action: subagent_input.Action) !subagent_input.Command {
        self.handled_keys += 1;
        self.handled_actions += 1;
        self.last_handled_key = switch (action) {
            .escape => 0x1b,
            .up, .left => 25,
            .down, .right => 9,
            else => null,
        };
        return .none;
    }

    pub fn handleKeyWithMainApproval(self: *RoutingSubagents, alloc: std.mem.Allocator, byte: u8, main_approval_id: ?u64) !subagent_input.Command {
        self.last_main_approval_id = main_approval_id;
        return self.handleKey(alloc, byte);
    }

    pub fn handleActionWithMainApproval(self: *RoutingSubagents, alloc: std.mem.Allocator, action: subagent_input.Action, main_approval_id: ?u64) !subagent_input.Command {
        self.last_main_approval_id = main_approval_id;
        return self.handleAction(alloc, action);
    }

    pub fn toggleView(self: *RoutingSubagents) @import("../../ui/subagent/controller.zig").ToggleResult {
        self.toggle_view_calls += 1;
        return .changed;
    }

    pub fn managerPasteActive(self: *const RoutingSubagents) bool {
        return self.active and self.manager_paste.paste.active();
    }

    pub fn beginManagerPaste(self: *RoutingSubagents) void {
        self.manager_paste.paste.begin(.decision_prompt, std.math.maxInt(usize));
    }

    pub fn consumeManagerPasteByte(
        self: *RoutingSubagents,
        alloc: std.mem.Allocator,
        byte: u8,
    ) !bool {
        if (!self.managerPasteActive()) return false;
        try self.manager_paste.paste.consumeByte(alloc, byte);
        return true;
    }

    pub fn settleManagerPasteDeliveryEpoch(
        self: *RoutingSubagents,
        _: std.mem.Allocator,
    ) bool {
        switch (self.manager_paste.paste.settleDeliveryEpoch()) {
            .none => return false,
            .finish => self.manager_paste.paste.resetWithTrace(.decision_prompt_active),
            .reject => self.manager_paste.paste.resetWithTrace(.unsafe_suffix),
        }
        return true;
    }
};

const RoutingUpgradeStatus = struct {
    state: auto_upgrade.State = .ready,
    stop_count: usize = 0,

    pub fn getState(self: *const RoutingUpgradeStatus) auto_upgrade.State {
        return self.state;
    }

    pub fn stop(self: *RoutingUpgradeStatus) void {
        self.stop_count += 1;
    }

    pub fn statusLabel(_: *const RoutingUpgradeStatus, _: []u8) []const u8 {
        return "";
    }
};

const RoutingWorker = struct {
    submitted_permission: ?ToolPermissionDecision = null,
    submitted_permission_feedback: [64]u8 = undefined,
    submitted_permission_feedback_len: usize = 0,
    active_permission_request_id: ?u64 = null,
    permission_response: ?ToolPermissionDecision = null,
    resize_signal_on_submit: ?*shell_runtime.ResizeApprovalInterlock = null,
    question_cancelled: bool = false,
    cancel_requested_when_question_cancelled: bool = false,
    submitted_question_answer: [64]u8 = undefined,
    submitted_question_answer_len: usize = 0,
    submitted_question_answers: [2][64]u8 = undefined,
    submitted_question_answer_lens: [2]usize = .{ 0, 0 },
    submitted_question_count: usize = 0,
    cancel_requested: bool = false,
    question_source: worker_runtime.QuestionPromptSource = .agent_question,
    admission_snapshot: worker_runtime.InteractiveAdmissionSnapshot = .open,
    queued_count: usize = 0,
    synced_permission_mode: ?types.PermissionMode = null,
    permission_mode_sync_count: usize = 0,

    pub fn queuePreview(_: *RoutingWorker, _: []u8) @import("../agent/worker_runtime.zig").QueuePreview {
        return .{};
    }

    pub fn queuedPromptCount(self: *const RoutingWorker) usize {
        return self.queued_count;
    }

    pub fn activeTurnId(_: *const RoutingWorker) u64 {
        return 1;
    }

    pub fn isCancelRequested(self: *const RoutingWorker) bool {
        return self.cancel_requested;
    }

    pub fn requestCancel(self: *RoutingWorker) void {
        self.cancel_requested = true;
    }

    pub fn interactiveAdmissionSnapshot(self: *RoutingWorker) worker_runtime.InteractiveAdmissionSnapshot {
        return self.admission_snapshot;
    }

    pub fn cancelApprovalTurn(self: *RoutingWorker) void {
        self.cancel_requested = true;
        if (self.active_permission_request_id != null and
            self.permission_response == null)
        {
            self.permission_response = .deny;
        }
    }

    pub fn submitPermissionResponse(
        self: *RoutingWorker,
        request_id: u64,
        response: permission_request.OwnedPermissionResponse,
    ) worker_runtime.PermissionSubmissionResult {
        var owned = response;
        defer owned.deinit();
        const decision = owned.decision;
        if (owned.feedback) |feedback| {
            self.submitted_permission_feedback_len = @min(
                feedback.len,
                self.submitted_permission_feedback.len,
            );
            @memcpy(
                self.submitted_permission_feedback[0..self.submitted_permission_feedback_len],
                feedback[0..self.submitted_permission_feedback_len],
            );
        }
        if (self.resize_signal_on_submit) |interlock| {
            interlock.noteResizeSignal();
        }
        if (self.active_permission_request_id) |active_id| {
            if (self.permission_response != null) return .no_pending;
            if (request_id != active_id) return .stale;
            self.permission_response = decision;
        }
        self.submitted_permission = decision;
        return .accepted;
    }

    pub fn submitQuestionBatchAnswer(self: *RoutingWorker, _: std.mem.Allocator, answers: ?[]const []const u8) !void {
        if (answers == null) {
            self.cancel_requested_when_question_cancelled = self.cancel_requested;
            self.question_cancelled = true;
            return;
        }
        const submitted = answers.?;
        self.submitted_question_count = submitted.len;
        for (submitted[0..@min(submitted.len, self.submitted_question_answers.len)], 0..) |answer, index| {
            const len = @min(answer.len, self.submitted_question_answers[index].len);
            @memcpy(self.submitted_question_answers[index][0..len], answer[0..len]);
            self.submitted_question_answer_lens[index] = len;
            if (index == 0) {
                self.submitted_question_answer_len = len;
                @memcpy(self.submitted_question_answer[0..len], answer[0..len]);
            }
        }
    }

    pub fn pendingQuestionBatchSource(self: *RoutingWorker) worker_runtime.QuestionPromptSource {
        return self.question_source;
    }

    pub fn syncQueuedPromptModel(_: *RoutingWorker, _: std.mem.Allocator, _: []const u8) !void {}

    pub fn syncQueuedPromptPermissionSnapshot(self: *RoutingWorker, snapshot: worker_runtime.PermissionSnapshot) void {
        self.synced_permission_mode = snapshot.mode;
        self.permission_mode_sync_count += 1;
    }

    pub fn syncQueuedPromptFastMode(_: *RoutingWorker, _: bool) void {}

    pub fn syncQueuedPromptEffort(_: *RoutingWorker, _: types.ReasoningEffort) void {}
};

const RoutingPacer = struct {
    pub fn clear(_: *RoutingPacer, _: std.mem.Allocator) void {}
};

fn routingFullTranscriptStyles() transcript_runtime.Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
}

fn armCtrlCExitForTest(input_runtime: *core_input_runtime.Runtime, armed_ms: i64) void {
    input_runtime.gestures = gesture_state.disarmCtrlCExit(
        input_runtime.gestures,
    ).next;
    input_runtime.gestures = gesture_state.pressCtrlCExit(
        input_runtime.gestures,
        armed_ms,
    ).next;
}

fn armEscapeClearForTest(input_runtime: *core_input_runtime.Runtime, armed_ms: i64) void {
    input_runtime.gestures = gesture_state.disarmEscapeClear(
        input_runtime.gestures,
    ).next;
    input_runtime.gestures = gesture_state.pressEscapeClear(
        input_runtime.gestures,
        armed_ms,
    ).next;
}

const RoutingFakeApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: std.mem.Allocator,
    metrics: types.Metrics = .{},
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    question_prompt: question_prompt.QuestionPrompt = .{},
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: test_ui_input.Runtime = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    terminal: shell_runtime.TerminalState = .{},
    worker: RoutingWorker = .{},
    subagents: RoutingSubagents = .{},
    permission_engine: permissions.PermissionEngine = .{},
    upgrader: RoutingUpgradeStatus = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    next_image_id_counter: usize = 1,
    selected_model: std.ArrayList(u8) = .empty,
    workspace_root: []const u8 = "",
    stream: types.StreamState = .{},
    session_persistence: app_session_runtime.Persistence = .{},
    skills: skill_runtime.Runtime = .{},
    pacer: RoutingPacer = .{},
    transcript: std.ArrayList(u8) = .empty,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,
    notice_visibility: types.NoticeVisibility = .compact_and_full,
    notice_write_count: usize = 0,
    last_replaceable_class: transcript_runtime.RawEntryClass = .unknown_raw,
    auth: auth_runtime.Runtime = .{},
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    should_exit: bool = false,
    statusline_context: bool = false,
    permission_state: app_permission_runtime.State = .{},
    total_input_tokens: u64 = 0,
    last_command: ?[]u8 = null,
    input_len_at_command: usize = 0,
    pasted_block_count_at_command: usize = 0,
    preference_commit_count: usize = 0,
    last_preference_model: std.ArrayList(u8) = .empty,
    last_preference_effort: ?types.ReasoningEffort = null,
    last_preference_fast_mode: ?bool = null,
    permission_mode_preference_commit_count: usize = 0,
    last_preference_permission_mode: ?types.PermissionMode = null,
    model_completion_values: []const []const u8 = &.{},
    gateway_metadata_model: ?[]const u8 = null,
    gateway_metadata: model_capabilities.GatewayMetadata = .{},
    model_cache_loading: bool = false,
    model_cache: model_cache_runtime.Runtime,
    file_completion_values: []const file_index.Candidate = &.{},
    file_completion_current: bool = true,
    expected_file_completion_kind: ?file_index.CandidateKind = null,
    validated_file_completion_kind: ?file_index.CandidateKind = null,
    file_completion_error: ?file_index.SearchError = null,
    file_completions_depend_on_index: bool = true,
    file_index_refresh_count: usize = 0,
    file_index_loading: bool = false,
    file_index_failed: bool = false,
    submitted_prompt_count: usize = 0,
    submitted_prompt: [128]u8 = undefined,
    submitted_prompt_len: usize = 0,
    approval_resize_interlock: shell_runtime.ResizeApprovalInterlock = .{},
    inject_resize_before_affirmative_claim: bool = false,
    affirmative_claim_count: usize = 0,
    affirmative_release_count: usize = 0,
    resume_selected_count: usize = 0,
    resume_selected_error: anyerror = error.SessionStoreUnavailable,
    resume_selected_closes_picker: bool = false,
    load_more_session_count: usize = 0,
    selected_credential_source: ?types.CredentialSource = null,
    selected_auth_action: ?auth_runtime.AcquisitionAction = null,
    selected_auth_team: ?usize = null,
    upgrade_apply_count: usize = 0,
    upgrade_denied_count: usize = 0,
    suspend_count: usize = 0,
    workspace_access: app_workspace_runtime.Access = .{},

    pub fn slashRegistry(_: *const RoutingFakeApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    pub fn urlOpener(_: *const RoutingFakeApp) host.UrlOpener {
        return .{ .open_fn = routingOpenUrl };
    }

    fn init(alloc: std.mem.Allocator) !RoutingFakeApp {
        var app = RoutingFakeApp{
            .alloc = alloc,
            .model_cache = model_cache_runtime.Runtime.init(alloc, "/v1/models"),
        };
        try app.selected_model.appendSlice(alloc, "test/model");
        app.shell.layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        };
        app.shell.owned_top_row = 1;
        app.shell.viewport_top_row = 1;
        app.shell.cursor_row = 10;
        app.shell.cursor_col = 1;
        return app;
    }

    fn deinit(self: *RoutingFakeApp) void {
        self.auth.deinit(self.alloc);
        self.approval_prompt.deinit(self.alloc);
        self.question_prompt.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.subagents.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.pending_images.deinit(self.alloc);
        self.selected_model.deinit(self.alloc);
        self.session_persistence.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
        self.last_preference_model.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        self.model_cache.deinit();
        self.workspace_access.deinit(self.alloc);
        if (self.last_command) |command| self.alloc.free(command);
    }

    pub fn workspaceAccess(self: *RoutingFakeApp) *app_workspace_runtime.Access {
        return &self.workspace_access;
    }

    pub fn flushBeforeBlockingExternalWork(_: *RoutingFakeApp) !void {}

    pub fn suspendToJobControl(self: *RoutingFakeApp) !void {
        self.suspend_count += 1;
    }

    pub fn modelCompletions(self: *RoutingFakeApp, query: []const u8, out: *[32][]const u8) usize {
        if (self.model_cache_loading) return 0;
        var count: usize = 0;
        for (self.model_completion_values) |value| {
            if (count == out.len) break;
            if (query.len > 0 and std.ascii.indexOfIgnoreCase(value, query) == null) continue;
            out[count] = value;
            count += 1;
        }
        return count;
    }

    pub fn catalogModelCompletion(self: *RoutingFakeApp, model: []const u8) ?[]const u8 {
        if (self.model_cache_loading) return null;
        for (self.model_completion_values) |value| {
            if (std.mem.eql(u8, value, model)) return value;
        }
        return null;
    }

    pub fn fileCompletions(
        self: *RoutingFakeApp,
        _: []const u8,
        out: []file_index.SearchResult,
        _: []file_index.MatchSpan,
        _: []u8,
    ) file_index.SearchError!usize {
        if (self.file_completion_error) |err| return err;
        const count = @min(self.file_completion_values.len, out.len);
        for (self.file_completion_values[0..count], 0..) |value, index| {
            out[index] = .{ .path = value.path, .kind = value.kind, .matched_spans = &.{} };
        }
        return count;
    }

    pub fn refreshFileIndex(self: *RoutingFakeApp) void {
        self.file_index_refresh_count += 1;
    }

    pub fn fileCompletionsDependOnIndex(self: *const RoutingFakeApp, _: []const u8) bool {
        return self.file_completions_depend_on_index;
    }

    pub fn refreshUsageMenu(
        self: *RoutingFakeApp,
        scope: usage_report.Scope,
    ) !void {
        self.input_runtime.usage_menu.requested_scope = scope;
    }

    pub fn isCurrentFileCompletion(self: *RoutingFakeApp, _: []const u8, _: []const u8, kind: file_index.CandidateKind) bool {
        self.validated_file_completion_kind = kind;
        return self.file_completion_current and
            (self.expected_file_completion_kind == null or self.expected_file_completion_kind.? == kind);
    }

    pub fn isModelCacheLoading(self: *const RoutingFakeApp) bool {
        return self.model_cache_loading;
    }

    pub fn isModelCacheFailed(_: *const RoutingFakeApp) bool {
        return false;
    }

    pub fn resolvedModelCapabilities(self: *RoutingFakeApp, model: []const u8) model_capabilities.Capabilities {
        if (self.gateway_metadata_model) |metadata_model| {
            if (std.mem.eql(u8, metadata_model, model)) {
                return model_capabilities.resolveCapabilities(model, self.gateway_metadata);
            }
        }
        return model_capabilities.capabilitiesForModel(model);
    }

    fn setGatewayControls(
        self: *RoutingFakeApp,
        model: []const u8,
        efforts: []const types.ReasoningEffort,
        supports_fast_mode: bool,
    ) void {
        self.gateway_metadata_model = model;
        self.gateway_metadata = .{
            .reasoning_efforts = .fromSlice(efforts),
            .supports_fast_mode = supports_fast_mode,
        };
    }

    pub fn isFileIndexLoading(self: *const RoutingFakeApp) bool {
        return self.file_index_loading;
    }

    pub fn isFileIndexFailed(self: *const RoutingFakeApp) bool {
        return self.file_index_failed;
    }

    pub fn appendReplaceableTranscriptLine(self: *RoutingFakeApp, content: []const u8) !u32 {
        try self.transcript.appendSlice(self.alloc, content);
        return 1;
    }

    pub fn appendReplaceableTranscriptLineClassified(self: *RoutingFakeApp, content: []const u8, class: transcript_runtime.RawEntryClass) !u32 {
        self.last_replaceable_class = class;
        return self.appendReplaceableTranscriptLine(content);
    }

    pub fn writeTranscriptClassified(self: *RoutingFakeApp, content: []const u8, _: bool, _: transcript_runtime.RawEntryClass) !void {
        try self.transcript.appendSlice(self.alloc, content);
    }

    pub fn writeDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_write_count += 1;
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
        self.notice_visibility = notice.visibility;
        const rendered = if (notice.topic.len > 0)
            try std.fmt.allocPrint(self.alloc, "● {c}{s}: {s}", .{
                std.ascii.toUpper(notice.topic[0]),
                notice.topic[1..],
                notice.body,
            })
        else
            try std.fmt.allocPrint(self.alloc, "● {s}", .{notice.body});
        defer self.alloc.free(rendered);
        try self.transcript.appendSlice(self.alloc, rendered);
    }

    pub fn appendDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice) !u32 {
        return self.shell.appendSemanticNotice(self.alloc, notice);
    }

    pub fn appendReplaceableDomainNotice(self: *RoutingFakeApp, notice: types.SemanticNotice) !u32 {
        return self.shell.appendReplaceableSemanticNotice(self.alloc, notice);
    }

    pub fn replaceDomainNotice(self: *RoutingFakeApp, entry_id: u32, notice: types.SemanticNotice) !bool {
        return self.shell.replaceSemanticNotice(self.alloc, entry_id, notice);
    }

    pub fn writeUserPromptCard(self: *RoutingFakeApp, user: types.UserTurn) !void {
        try self.transcript.appendSlice(self.alloc, user.text);
    }

    pub fn stopStream(self: *RoutingFakeApp) void {
        self.stream = .{};
    }

    pub fn prepareLiveSessionResume(_: *RoutingFakeApp) !void {}

    pub fn finishLiveSessionResume(_: *RoutingFakeApp) !void {}

    pub fn resumeSelectedSession(self: *RoutingFakeApp) !bool {
        self.resume_selected_count += 1;
        if (self.resume_selected_closes_picker) {
            self.session_persistence.session_picker.active = false;
        }
        return self.resume_selected_error;
    }

    pub fn loadMoreSessionPicker(self: *RoutingFakeApp) !bool {
        const picker = &self.session_persistence.session_picker;
        if (!picker.active or picker.load_state != .ready or !picker.has_more or
            picker.selected != picker.filteredItemCount()) return false;
        self.load_more_session_count += 1;
        return true;
    }

    pub fn applyAuthPickerChoice(self: *RoutingFakeApp, choice: auth_runtime.Choice) !void {
        switch (choice) {
            .provider => {},
            .source => |source| _ = try self.selectCredentialSource(source),
            .action => |action| self.selected_auth_action = action,
            .team => |index| self.selected_auth_team = index,
        }
    }

    pub fn selectCredentialSource(self: *RoutingFakeApp, source: types.CredentialSource) !bool {
        self.selected_credential_source = source;
        return true;
    }

    pub fn prepareResumeHandoffForUpgrade(_: *RoutingFakeApp) !void {}

    pub fn requestUpgradeRelaunch(
        self: *RoutingFakeApp,
        _: []const u8,
    ) !void {
        self.upgrade_apply_count += 1;
    }

    pub fn requestResumeHandoffForUpgrade(_: *RoutingFakeApp) void {}

    pub fn applyReadyUpgradeShortcut(self: *RoutingFakeApp) !void {
        const outcome = try app_upgrade_runtime.Runtime(RoutingFakeApp).applyReadyUpgradeWithDeps(
            self,
            .{
                .ctx = self,
                .current_executable_path = currentExecutablePathForRouting,
            },
        );
        if (outcome != .relaunch_requested) {
            self.upgrade_denied_count += 1;
        }
    }

    pub fn nextImageId(self: *RoutingFakeApp) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn captureImageAttachment(_: *RoutingFakeApp, _: *types.ImageAttachment) !void {
        return error.MissingImageSnapshot;
    }

    pub fn peekNextImageId(self: *const RoutingFakeApp) usize {
        return self.next_image_id_counter;
    }

    pub fn transitionFullTranscriptProjection(
        self: *RoutingFakeApp,
        event: transcript_presentation.Event,
    ) !transcript_presentation.Depth {
        self.shell.setCommandOutputRenderPolicy(
            routingFullTranscriptStyles(),
        );
        const depth = self.shell.transcriptPresentationDepth().transition(event);
        _ = try self.shell.setTranscriptPresentationDepth(self.alloc, depth);
        return depth;
    }

    pub fn writeSubagentSnapshot(self: *RoutingFakeApp) !void {
        self.subagents.toggle_view_calls += 1;
    }

    pub fn admitPendingApprovalResize(self: *RoutingFakeApp) bool {
        if (!self.approval_resize_interlock.takeResizePending()) return false;
        self.shell.render_requests.observeResizeSignal(100, 80);
        return true;
    }

    pub fn beforeApprovalAffirmativeClaim(self: *RoutingFakeApp) void {
        if (!self.inject_resize_before_affirmative_claim) return;
        self.inject_resize_before_affirmative_claim = false;
        self.approval_resize_interlock.noteResizeSignal();
    }

    pub fn claimApprovalAffirmative(self: *RoutingFakeApp) bool {
        self.affirmative_claim_count += 1;
        return self.approval_resize_interlock.claimAffirmative();
    }

    pub fn releaseApprovalAffirmative(self: *RoutingFakeApp) void {
        self.affirmative_release_count += 1;
        self.approval_resize_interlock.releaseAffirmative();
    }

    pub fn enqueuePrompt(self: *RoutingFakeApp, text: []const u8) !bool {
        self.submitted_prompt_len = @min(text.len, self.submitted_prompt.len);
        @memcpy(self.submitted_prompt[0..self.submitted_prompt_len], text[0..self.submitted_prompt_len]);
        self.submitted_prompt_count += 1;
        return true;
    }

    pub fn handleCommand(self: *RoutingFakeApp, command: []const u8) !void {
        if (self.last_command) |previous| self.alloc.free(previous);
        self.last_command = try self.alloc.dupe(u8, command);
        self.input_len_at_command = self.input_runtime.edit_state.input.items.len;
        self.pasted_block_count_at_command = self.input_runtime.entities.pasted_blocks.items.len;
    }

    pub fn persistRuntimePreferences(
        self: *RoutingFakeApp,
        patch: app_session_runtime.SessionPreferencePatch,
    ) app_session_runtime.PreferenceCommitResult {
        self.preference_commit_count += 1;
        self.last_preference_model.clearRetainingCapacity();
        if (patch.model) |model| {
            self.last_preference_model.appendSlice(self.alloc, model) catch
                return .{ .settings_error = error.OutOfMemory };
        }
        self.last_preference_effort = patch.effort;
        self.last_preference_fast_mode = patch.fast_mode;
        return .{};
    }

    pub fn persistPermissionModePreference(
        self: *RoutingFakeApp,
        mode: types.PermissionMode,
    ) !void {
        self.permission_mode_preference_commit_count += 1;
        self.last_preference_permission_mode = mode;
    }

    pub fn clearPendingImages(self: *RoutingFakeApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        image_attachments.discardImageSnapshots(self.alloc, self.pending_images.items);
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }
};

fn routingOpenUrl(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
) host.UrlOpenError!bool {
    return false;
}

fn currentExecutablePathForRouting(
    _: ?*anyopaque,
    executable_buf: []u8,
) upgrade_helpers.ExecutablePathError![]const u8 {
    const executable_path = "/tmp/fx-routing-upgraded";
    if (executable_path.len > executable_buf.len) return error.PathTooLong;
    @memcpy(executable_buf[0..executable_path.len], executable_path);
    return executable_buf[0..executable_path.len];
}

fn readTraceFileForTest(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 8192);
}

fn activateFullTranscriptForRoutingTest(app: *RoutingFakeApp) void {
    app.terminal.alternate_screen_owner = .full_transcript;
    app.terminal.alternate_mouse_tracking_active = false;
    app.shell.full_transcript = .{ .depth = .full, .follow_tail = true };
}

fn appendRoutingSessionPickerSummary(
    alloc: std.mem.Allocator,
    picker: *app_session_runtime.SessionPicker,
    index: usize,
) !void {
    const id = try std.fmt.allocPrint(alloc, "session-{d}", .{index});
    errdefer alloc.free(id);
    const workspace_root = try std.fmt.allocPrint(alloc, "/tmp/workspace-{d}", .{index});
    errdefer alloc.free(workspace_root);
    const title = try std.fmt.allocPrint(alloc, "session {d}", .{index});
    errdefer alloc.free(title);
    const preview = try std.fmt.allocPrint(alloc, "session {d} preview", .{index});
    errdefer alloc.free(preview);
    try picker.summaries.append(alloc, .{
        .id = id,
        .workspace_root = workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = true,
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .history_len = 1,
    });
}

fn currentQuestionChoiceForRoutingTest(prompt: *const question_prompt.QuestionPrompt) u8 {
    return prompt.entries.items[prompt.current_index].choice_index;
}

fn feedRoutingBytes(app: *RoutingFakeApp, bytes: []const u8) !void {
    return feedRoutingBytesWithLimit(app, bytes, RoutingFakeApp.input_byte_limit);
}

fn feedRoutingBytesWithLimit(app: *RoutingFakeApp, bytes: []const u8, max_input_len: usize) !void {
    for (bytes) |byte| {
        try Runtime(RoutingFakeApp).handleByte(app, byte, max_input_len, 100);
    }
    try Runtime(RoutingFakeApp).settleTerminalPasteDeliveryEpochWithLimits(
        app,
        paste_framing.InputLimits.single(max_input_len),
    );
}

fn primeComposerHistoryForTest(comptime App: type, app: *App, draft: []const u8) !void {
    try app.input_runtime.composer_history.installTextEntries(
        app.alloc,
        &.{"history entry"},
    );
    try app.input_runtime.textReplacementState().replace(app.alloc, draft);
    try input_completion_runtime.CompletionRuntime(App).navigatePromptHistory(app, -1);
}

fn openRoutingModelMenu(app: *RoutingFakeApp, model_ids: []const []const u8) !void {
    const menu = &app.model_cache.menu;
    menu.active = true;
    menu.load_state = .ready;
    for (model_ids) |model_id| {
        const owned_id = try app.alloc.dupe(u8, model_id);
        var item_owns_id = false;
        errdefer if (!item_owns_id) app.alloc.free(owned_id);
        const provider_end = std.mem.indexOfScalar(u8, owned_id, '/') orelse owned_id.len;
        const provider = owned_id[0..provider_end];
        try menu.items.append(app.alloc, .{
            .id = owned_id,
            .provider = provider,
            .capabilities = app.resolvedModelCapabilities(owned_id),
        });
        item_owns_id = true;
    }
}

fn openRoutingAuthPicker(app: *RoutingFakeApp) !void {
    app.auth.source_inventory.insert(.vercel_oidc_token);
    app.auth.source_inventory.insert(.ai_gateway_api_key);
    app.auth.openPicker(app.alloc);
    try std.testing.expect(app.auth.movePicker(1));
    try std.testing.expectEqual(@as(usize, 4), app.auth.pickerView().choiceCount());
    try std.testing.expectEqual(@as(usize, 1), app.auth.pickerView().selectedIndex());
}

const RoutingDecisionKind = enum { question, approval };

fn activateRoutingDecision(app: *RoutingFakeApp, kind: RoutingDecisionKind) !void {
    switch (kind) {
        .question => {
            const options = [_]types.QuestionOption{
                .{ .label = "Alpha", .description = null },
                .{ .label = "Beta", .description = null },
            };
            const entries = [_]types.QuestionBatchEntry{
                .{ .question = "Continue?", .options = &options },
            };
            try app.question_prompt.syncFrom(app.alloc, &entries);
        },
        .approval => try std.testing.expect(try app.approval_prompt.syncRequest(app.alloc, .{
            .label = "terminal.exec npm test",
        })),
    }
}

const RoutingDraftKind = enum {
    text,
    paste,
    image,
};

fn seedRoutingDraftForGuard(app: *RoutingFakeApp, kind: RoutingDraftKind) !void {
    switch (kind) {
        .text => try app.input_runtime.textReplacementState().replace(app.alloc, "guarded draft"),
        .paste => try app.input_runtime.entities.pasted_blocks.append(app.alloc, .{
            .id = 1,
            .text = try app.alloc.dupe(u8, "guarded pasted text"),
            .line_count = 1,
        }),
        .image => try app.pending_images.append(app.alloc, .{
            .id = 1,
            .path = try app.alloc.dupe(u8, "/tmp/guarded-image.png"),
            .media_type = try app.alloc.dupe(u8, "image/png"),
        }),
    }
}

fn expectRoutingDraftForGuard(app: *const RoutingFakeApp, kind: RoutingDraftKind) !void {
    switch (kind) {
        .text => try std.testing.expectEqualStrings("guarded draft", app.input_runtime.edit_state.input.items),
        .paste => {
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.pasted_blocks.items.len);
            try std.testing.expectEqualStrings("guarded pasted text", app.input_runtime.entities.pasted_blocks.items[0].text);
        },
        .image => {
            try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
            try std.testing.expectEqualStrings("/tmp/guarded-image.png", app.pending_images.items[0].path);
        },
    }
}

const routing_file_approval_preview_lines =
    [_]@import("../output/diff.zig").PreviewLine{
        .{
            .op = .deletion,
            .old_line = 2,
            .text = "before",
        },
        .{
            .op = .addition,
            .new_line = 2,
            .text = "after",
        },
    };

fn routingFileApprovalRequest(
    id: u64,
) permission_request.PermissionRequest {
    return .{
        .id = id,
        .label = "file_mutation",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &routing_file_approval_preview_lines,
                .additions = 1,
                .deletions = 1,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
}

fn installReadyRoutingFileApproval(app: *RoutingFakeApp) !void {
    try std.testing.expect(try app.approval_prompt.syncRequest(
        app.alloc,
        routingFileApprovalRequest(41),
    ));
    app.worker.active_permission_request_id = 41;
    app.shell.layout.rows = 24;
    app.shell.layout.cols = 96;
    app.shell.footer_viewport.has_frame = true;
    app.shell.footer_viewport.geometry = .{
        .top = 1,
        .top_divider = 1,
        .input_base = 2,
        .bottom_divider = 13,
        .hint = 13,
    };
    app.approval_screen.recordScreenCommit(41, .{
        .request_id = 41,
        .rows = app.shell.layout.rows,
        .cols = app.shell.layout.cols,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = true,
        .document_scrollable = true,
    });
}

const ApprovalOwnershipBinding = struct {
    child_id: []const u8,
};

const ApprovalOwnershipSubagents = struct {
    view_active: bool = true,
    child_id: []const u8 = "selected-child",
    presented_binding: ?ApprovalOwnershipBinding = null,
    card_binding: ?ApprovalOwnershipBinding = null,

    pub fn isViewActive(self: *const ApprovalOwnershipSubagents) bool {
        return self.view_active;
    }

    pub fn childRouteId(self: *const ApprovalOwnershipSubagents) ?[]const u8 {
        return self.child_id;
    }

    pub fn mainApprovalBinding(
        self: *const ApprovalOwnershipSubagents,
        _: u64,
    ) ?ApprovalOwnershipBinding {
        return self.presented_binding;
    }

    pub fn mainApprovalCardBinding(
        self: *const ApprovalOwnershipSubagents,
        _: u64,
    ) ?ApprovalOwnershipBinding {
        return self.card_binding;
    }
};

const ApprovalOwnershipApp = struct {
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    approval_screen: interaction_state.ApprovalScreenState = .{},
    subagents: ApprovalOwnershipSubagents = .{},
};

const FakeSubmitApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: std.mem.Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    input_runtime: core_input_runtime.Runtime = .{},
    prompt_history: prompt_history_runtime.PromptHistoryRuntime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    stream: types.StreamState = .{},
    pacer: struct {
        pending: bool = false,
        completed_assistant_presentation_tail: bool = false,

        pub fn hasPending(self: *const @This()) bool {
            return self.pending;
        }

        pub fn hasCompletedAssistantPresentationTail(self: *const @This()) bool {
            return self.completed_assistant_presentation_tail;
        }
    } = .{},
    worker: struct {
        hold_available: bool = false,
        held: bool = false,
        queued_turn_id: ?u64 = null,
        queued_images: []types.ImageAttachment = &.{},
        queued_images_alloc: ?std.mem.Allocator = null,

        pub fn queuedPromptCount(_: *@This()) usize {
            return 0;
        }

        pub fn tryHoldTurnStart(self: *@This()) bool {
            if (!self.hold_available or self.held) return false;
            self.held = true;
            return true;
        }

        pub fn releaseTurnStartHold(self: *@This()) void {
            self.held = false;
        }

        pub fn deleteQueuedPromptDraft(
            self: *@This(),
            _: std.mem.Allocator,
            turn_id: u64,
            retained_images: []const types.ImageAttachment,
        ) bool {
            if (self.queued_turn_id != turn_id) return false;
            image_attachments.deleteUnreferencedImageSnapshots(
                self.queued_images,
                retained_images,
            );
            self.freeQueuedImageMetadata();
            self.queued_turn_id = null;
            return true;
        }

        pub fn clearQueuedPrompts(
            self: *@This(),
            _: std.mem.Allocator,
            retained_images: []const types.ImageAttachment,
        ) void {
            image_attachments.deleteUnreferencedImageSnapshots(
                self.queued_images,
                retained_images,
            );
            self.freeQueuedImageMetadata();
            self.queued_turn_id = null;
        }

        fn freeQueuedImageMetadata(self: *@This()) void {
            if (self.queued_images_alloc) |alloc| {
                types.freeImageAttachmentSlice(alloc, self.queued_images);
            }
            self.queued_images = &.{};
            self.queued_images_alloc = null;
        }

        pub fn clearQueuedPromptsForSessionTransition(
            self: *@This(),
            alloc: std.mem.Allocator,
            _: u64,
            retained_images: []const types.ImageAttachment,
        ) void {
            self.clearQueuedPrompts(alloc, retained_images);
        }

        pub fn activeTurnId(_: *const @This()) u64 {
            return 0;
        }

        pub fn requestCancel(_: *@This()) void {}
    } = .{},
    submission: input_submit_runtime.State = .{},
    shell: struct {
        render_requests: render_request.RenderRequestState = .{},
        full_transcript_active: bool = false,
        layout: types.Layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },

        pub fn fullTranscriptActive(self: *const @This()) bool {
            return self.full_transcript_active;
        }
    } = .{},
    next_image_id_counter: usize = 1,
    transcript: std.ArrayList(u8) = .empty,
    last_command: ?[]u8 = null,
    last_prompt: ?[]u8 = null,
    last_steering: ?[]u8 = null,
    last_images: []types.ImageAttachment = &.{},
    last_skill_tokens: std.ArrayList(registered_entities.SkillTokenSpan) = .empty,
    notice_topic: std.ArrayList(u8) = .empty,
    notice_body: std.ArrayList(u8) = .empty,
    notice_tone: types.NoticeTone = .information,
    notice_visibility: types.NoticeVisibility = .compact_and_full,
    input_len_at_command: usize = 0,
    command_count: usize = 0,
    fail_notice: bool = false,
    prompt_admitted: bool = true,
    queue_admitted: bool = true,
    queue_accept_count: usize = 0,
    preflight_count: usize = 0,
    notice_count: usize = 0,
    capture_count: usize = 0,
    capture_error_id: ?usize = null,
    capture_error: ?anyerror = null,
    fail_enqueue_after_snapshot: bool = false,
    fail_pending_finalization: bool = false,
    fail_command_after_pending_clear: bool = false,
    snapshot_dir: ?[]const u8 = null,

    pub fn slashRegistry(_: *const FakeSubmitApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    fn deinit(self: *FakeSubmitApp) void {
        if (self.submission.pending) |*pending| pending.deinit(self.alloc);
        self.submission.pending = null;
        self.prompt_history.deinit(self.alloc);
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.notice_topic.deinit(self.alloc);
        self.notice_body.deinit(self.alloc);
        if (self.last_command) |text| self.alloc.free(text);
        if (self.last_prompt) |text| self.alloc.free(text);
        if (self.last_steering) |text| self.alloc.free(text);
        types.freeImageAttachmentSlice(self.alloc, self.last_images);
        self.clearLastSkillTokens();
        self.last_skill_tokens.deinit(self.alloc);
        self.worker.freeQueuedImageMetadata();
    }

    pub fn writeDomainNotice(self: *FakeSubmitApp, notice: types.SemanticNotice, _: bool) !void {
        if (self.fail_notice) return error.InjectedTranscriptFailure;
        self.notice_count += 1;
        self.notice_topic.clearRetainingCapacity();
        self.notice_body.clearRetainingCapacity();
        try self.notice_topic.appendSlice(self.alloc, notice.topic);
        try self.notice_body.appendSlice(self.alloc, notice.body);
        self.notice_tone = notice.tone;
        self.notice_visibility = notice.visibility;
    }

    pub fn clearPendingImages(self: *FakeSubmitApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        image_attachments.discardImageSnapshots(self.alloc, self.pending_images.items);
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    pub fn releasePendingImages(self: *FakeSubmitApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    pub fn captureImageAttachment(self: *FakeSubmitApp, attachment: *types.ImageAttachment) !void {
        self.capture_count += 1;
        if (self.capture_error_id == attachment.id) {
            return self.capture_error orelse error.ImageTooLarge;
        }
        const snapshot_dir = self.snapshot_dir orelse return;
        try image_attachments.captureImageSnapshot(self.alloc, attachment, snapshot_dir);
    }

    pub fn handleCommand(self: *FakeSubmitApp, text: []const u8) !void {
        if (self.last_command) |old| self.alloc.free(old);
        self.last_command = try self.alloc.dupe(u8, text);
        self.command_count += 1;
        self.input_len_at_command = self.input_runtime.edit_state.input.items.len;
        if (std.mem.eql(u8, text, "/images clear")) {
            self.clearPendingImages();
            if (self.fail_command_after_pending_clear) return error.InjectedCommandFailure;
        }
        // Attach through the production handler so routing tests observe real placeholder
        // insertion, id allocation, and snapshot capture rather than a stub.
        const attach_prefix: ?[]const u8 = if (std.mem.startsWith(u8, text, "/image "))
            "/image "
        else if (std.mem.startsWith(u8, text, "/img "))
            "/img "
        else
            null;
        if (attach_prefix) |prefix| {
            try image_commands.Commands(FakeSubmitApp).attachPath(self, text[prefix.len..]);
        }
    }

    pub fn ensurePromptCredential(self: *FakeSubmitApp) !bool {
        self.preflight_count += 1;
        return self.prompt_admitted;
    }

    pub fn adoptPendingUserPrompt(
        _: *FakeSubmitApp,
        _: *const worker_runtime.QueuedPromptDraft,
    ) !void {}

    pub fn finalizePendingSubmission(
        self: *FakeSubmitApp,
        draft: *const worker_runtime.QueuedPromptDraft,
    ) !void {
        if (self.fail_pending_finalization) {
            return error.InjectedPendingFinalizationFailure;
        }
        self.worker.freeQueuedImageMetadata();
        self.worker.queued_images = try types.dupeImageAttachmentSlice(
            self.alloc,
            draft.images,
        );
        self.worker.queued_images_alloc = self.alloc;
        self.worker.queued_turn_id = draft.turn_id;
    }

    pub fn enqueuePrompt(self: *FakeSubmitApp, text: []const u8) !bool {
        return self.enqueuePromptWithSkillBindings(text, &.{});
    }

    pub fn steerPrompt(self: *FakeSubmitApp, text: []const u8) !bool {
        if (!self.queue_admitted) return false;
        const copy = try self.alloc.dupe(u8, text);
        if (self.last_steering) |old| self.alloc.free(old);
        self.last_steering = copy;
        return true;
    }

    pub fn enqueuePromptWithSkillBindings(
        self: *FakeSubmitApp,
        text: []const u8,
        skill_tokens: []const registered_entities.SkillTokenSpan,
    ) !bool {
        if (!self.queue_admitted) return false;
        const prompt_copy = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(prompt_copy);
        const images_copy = try types.dupeImageAttachmentSlice(self.alloc, self.pending_images.items);
        errdefer types.freeImageAttachmentSlice(self.alloc, images_copy);
        if (self.fail_enqueue_after_snapshot) return error.InjectedEnqueueFailure;
        if (self.last_prompt) |old| self.alloc.free(old);
        self.last_prompt = prompt_copy;
        types.freeImageAttachmentSlice(self.alloc, self.last_images);
        self.last_images = images_copy;
        self.clearLastSkillTokens();
        errdefer self.clearLastSkillTokens();
        try self.last_skill_tokens.ensureTotalCapacity(self.alloc, skill_tokens.len);
        for (skill_tokens) |token| {
            const name = try self.alloc.dupe(u8, token.name);
            var appended = false;
            errdefer if (!appended) self.alloc.free(name);
            const path = try self.alloc.dupe(u8, token.path);
            errdefer if (!appended) self.alloc.free(path);
            self.last_skill_tokens.appendAssumeCapacity(.{
                .raw_start = token.raw_start,
                .raw_end = token.raw_end,
                .name = name,
                .path = path,
            });
            appended = true;
        }
        self.queue_accept_count += 1;
        return true;
    }

    pub fn nextImageId(self: *FakeSubmitApp) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn peekNextImageId(self: *const FakeSubmitApp) usize {
        return self.next_image_id_counter;
    }

    fn clearLastSkillTokens(self: *FakeSubmitApp) void {
        for (self.last_skill_tokens.items) |token| {
            self.alloc.free(@constCast(token.name));
            self.alloc.free(@constCast(token.path));
        }
        self.last_skill_tokens.clearRetainingCapacity();
    }
};

const FrameSubmitApp = struct {
    alloc: std.mem.Allocator,
    workspace_root: []const u8 = "/tmp/workspace",
    input_runtime: core_input_runtime.Runtime = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    next_image_id_counter: usize = 1,
    shell: transcript_runtime.TranscriptRuntime,
    metrics: types.Metrics = .{},
    command_seen: bool = false,

    pub fn slashRegistry(_: *const FrameSubmitApp) command_specs.SlashRegistry {
        return routing_test_slash_registry;
    }

    fn deinit(self: *FrameSubmitApp) void {
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.input_runtime.deinit(self.alloc);
        self.shell.deinit(self.alloc);
    }

    pub fn clearPendingImages(self: *FrameSubmitApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    pub fn handleCommand(self: *FrameSubmitApp, _: []const u8) !void {
        self.command_seen = true;
        try self.writeDomainNotice(.{
            .topic = "system",
            .tone = .information,
            .body = "command result",
        }, true);
    }

    pub fn writeDomainNotice(self: *FrameSubmitApp, notice: types.SemanticNotice, record: bool) !void {
        try self.shell.writeNotice(self.alloc, &self.metrics, notice, record);
    }

    pub fn enqueuePrompt(_: *FrameSubmitApp, _: []const u8) !bool {
        return true;
    }

    pub fn nextImageId(self: *FrameSubmitApp) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    pub fn peekNextImageId(self: *const FrameSubmitApp) usize {
        return self.next_image_id_counter;
    }

    pub fn captureImageAttachment(_: *FrameSubmitApp, _: *types.ImageAttachment) !void {
        return error.MissingImageSnapshot;
    }
};

fn writeTestImage(tmp: *std.testing.TmpDir, name: []const u8) !void {
    var file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
}

fn realTmpPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
}

fn countTestSnapshotFiles(path: []const u8) !usize {
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file or entry.kind == .sym_link) count += 1;
    }
    return count;
}

fn appendOwnedPendingImage(app: *FakeSubmitApp, id: usize, path: []const u8) !void {
    const path_copy = try app.alloc.dupe(u8, path);
    errdefer app.alloc.free(path_copy);
    const media_type = try app.alloc.dupe(u8, "image/png");
    errdefer app.alloc.free(media_type);
    try app.pending_images.append(app.alloc, .{
        .id = id,
        .path = path_copy,
        .media_type = media_type,
    });
}

fn appendImageTokenForPlaceholderAt(
    app: *FakeSubmitApp,
    id: usize,
    raw_start: usize,
) !void {
    var placeholder_buf: [32]u8 = undefined;
    const placeholder = try image_attachments.formatImagePlaceholder(
        &placeholder_buf,
        id,
    );
    try app.input_runtime.entities.image_tokens.append(app.alloc, .{
        .id = id,
        .span = .{
            .raw_start = raw_start,
            .raw_end = raw_start + placeholder.len,
        },
    });
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.find(u8, haystack[start..], needle)) |relative| {
        count += 1;
        start += relative + needle.len;
    }
    return count;
}

fn runRepeatedImageCommand(alloc: std.mem.Allocator, input: []const u8) !void {
    var app = FakeSubmitApp{ .alloc = alloc, .prompt_admitted = false, .queue_admitted = false };
    defer app.deinit();
    try appendOwnedPendingImage(&app, 1, "/tmp/first.png");
    app.next_image_id_counter = 2;
    try app.input_runtime.edit_state.input.appendSlice(alloc, input);
    try appendImageTokenForPlaceholderAt(&app, 1, 0);
    app.input_runtime.edit_state.cursor = app.input_runtime.edit_state.input.items.len;
    try Runtime(FakeSubmitApp).submit(&app, 100);
}

fn checkAcceptedPromptCleanupAcrossAllocationFailures(failing: *std.testing.FailingAllocator) !void {
    const alloc = failing.allocator();
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    try app.input_runtime.edit_state.input.appendSlice(alloc, "accepted prompt");
    app.input_runtime.edit_state.cursor = "accepted prompt".len;

    Runtime(FakeSubmitApp).submit(&app, 100) catch |err| {
        if (app.queue_accept_count > 0) return error.AcceptedPromptReturnedError;
        return err;
    };

    if (app.queue_accept_count > 0) {
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
    }
}

const PromptHistoryBusyLockState = struct {
    now_ms: i64 = 0,

    fn tryLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
        return false;
    }

    fn now(ctx: ?*anyopaque) i64 {
        const self: *PromptHistoryBusyLockState =
            @ptrCast(@alignCast(ctx.?));
        return self.now_ms;
    }

    fn sleep(ctx: ?*anyopaque, millis: u64) void {
        const self: *PromptHistoryBusyLockState =
            @ptrCast(@alignCast(ctx.?));
        self.now_ms += @intCast(millis);
    }
};

fn checkImagePathPasteAllocationFailureIsAtomic(
    failing: *std.testing.FailingAllocator,
    path: []const u8,
) !void {
    const alloc = failing.allocator();
    var app = FakeSubmitApp{ .alloc = alloc };
    defer app.deinit();
    app.next_image_id_counter = 7;

    Runtime(FakeSubmitApp).handlePastedBytes(
        &app,
        path,
        FakeSubmitApp.input_byte_limit,
    ) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 7), app.next_image_id_counter);
        return err;
    };

    try std.testing.expectEqualStrings("[Image #7]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 7), app.pending_images.items[0].id);
    try std.testing.expectEqual(@as(usize, 8), app.next_image_id_counter);
}
