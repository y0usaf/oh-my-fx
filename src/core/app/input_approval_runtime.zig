const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const edit_contract = @import("../input/editor_state.zig");
const input_action = @import("../input/input_action.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const io_mod = @import("../shared/io.zig");
const approval_decision = @import("../permissions/approval_decision.zig");
const approval_screen = @import("../../ui/approval_screen.zig");
const approval_ui = @import("../../ui/footer/approval_ui.zig");
const types = @import("../shared/types.zig");
const input_interrupt_runtime = @import("input_interrupt_runtime.zig");
const input_queue_runtime = @import("input_queue_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_commands = @import("app_commands.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const approval_registry = @import("../subagent/approval_registry.zig");
const communication = @import("../subagent/communication.zig");
const communication_store = @import("../subagent/communication_store.zig");
const control_store = @import("../subagent/control_store.zig");
const domain = @import("../subagent/domain.zig");
const execution = @import("../subagent/execution.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_projection = @import("../subagent/ui_projection.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const vertical_navigation = @import("../input/vertical_navigation.zig");
const interaction_state = @import("../../ui/footer/interaction_state.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const render_request = @import("../../ui/render_request.zig");

const ToolPermissionDecision = types.ToolPermissionDecision;

pub fn ApprovalRuntime(comptime App: type) type {
    return struct {
        const interrupt = input_interrupt_runtime.InterruptRuntime(App);
        const queue_rt = input_queue_runtime.Runtime(App);

        fn requestActiveSurfaceFrame(app: *App) void {
            app_render_runtime.Runtime(App).requestActiveSurfaceFrame(app, .modal);
        }

        pub fn handlePermissionAction(
            app: *App,
            action: approval_decision.Action,
        ) !bool {
            return switch (try handlePermissionActionWithLimit(app, action, null)) {
                .consumed => true,
                .ignored => false,
                .limit_exceeded => unreachable,
            };
        }

        pub fn handlePermissionActionBounded(
            app: *App,
            action: approval_decision.Action,
            max_len: usize,
        ) !edit_contract.ByteResult {
            return handlePermissionActionWithLimit(app, action, max_len);
        }

        fn handlePermissionActionWithLimit(
            app: *App,
            action: approval_decision.Action,
            max_len: ?usize,
        ) !edit_contract.ByteResult {
            const event = try applyDecisionAction(app, action, max_len);
            switch (event) {
                .none => return .ignored,
                .redraw => {
                    requestActiveSurfaceFrame(app);
                    return .consumed;
                },
                .decision => |decision| {
                    try submitPermissionChoice(app, decision);
                    return .consumed;
                },
                .limit_exceeded => return .limit_exceeded,
            }
        }

        pub fn routeApprovalEscapeAction(
            app: *App,
            action: input_action.Action,
            focused_edit: ?approval_decision.DraftAction,
        ) !void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
            const amending = app.approval_prompt.isAmending();
            if (amending) {
                if (focused_edit) |edit| {
                    _ = try applyDecisionAction(
                        app,
                        .{ .edit_draft = edit },
                        null,
                    );
                    requestActiveSurfaceFrame(app);
                    return;
                }
            }
            switch (action) {
                .cursor_left, .word_left => {
                    if (!amending) {
                        _ = try applyDecisionAction(
                            app,
                            .{ .move_choice = .previous },
                            null,
                        );
                        requestActiveSurfaceFrame(app);
                    }
                },
                .cursor_right, .word_right => {
                    if (!amending) {
                        _ = try applyDecisionAction(
                            app,
                            .{ .move_choice = .next },
                            null,
                        );
                        requestActiveSurfaceFrame(app);
                    }
                },
                .history_up, .cursor_up => {
                    _ = try applyDecisionAction(
                        app,
                        .{ .move_choice = .previous },
                        null,
                    );
                    requestActiveSurfaceFrame(app);
                },
                .history_down, .cursor_down => {
                    _ = try applyDecisionAction(
                        app,
                        .{ .move_choice = .next },
                        null,
                    );
                    requestActiveSurfaceFrame(app);
                },
                .mouse_wheel => |direction| try handleApprovalWheel(app, direction),
                else => {},
            }
        }

        fn applyDecisionAction(
            app: *App,
            action: approval_decision.Action,
            max_len: ?usize,
        ) !approval_decision.Event {
            const amendment_allowed: ?bool = if (app.approval_prompt.request) |request|
                request.amendment_allowed
            else
                null;
            return app.approval_prompt.decision.apply(
                app.alloc,
                action,
                amendment_allowed,
                max_len,
            );
        }

        fn clearApprovalPrompt(app: *App, reason: []const u8) void {
            app.approval_prompt.clearWithReason(app.alloc, reason);
            app.approval_screen.clear();
        }

        fn clearApprovalPromptAfterSubmission(app: *App) void {
            app.approval_prompt.clearAfterAcceptedSubmission(app.alloc);
            app.approval_screen.clear();
        }

        fn handleApprovalWheel(app: *App, direction: input_action.MouseWheel) !void {
            const request = app.approval_prompt.request orelse return;
            const commit = app.approval_screen.screen_commit orelse return;
            if (!(try approval_screen.needsScreen(
                app.alloc,
                request.view(),
                app.shell.layout,
                app.worker.queuedPromptCount(),
            )) or
                commit.request_id != request.id or
                !commit.document_scrollable)
            {
                return;
            }
            app.approval_screen.scrollDocument(
                approval_screen.documentWheelDelta(direction),
            );
            requestActiveSurfaceFrame(app);
        }

        fn submitPermissionChoice(app: *App, decision: ToolPermissionDecision) !void {
            if (app.approval_prompt.rule_management != null) {
                try submitRuleManagementChoice(app, decision);
                return;
            }
            if (try submitSubagentPermissionChoice(app, decision)) return;
            var affirmative_claimed = false;
            if (decision != .deny and
                app.approval_prompt.request.?.file != null)
            {
                admitPendingApprovalResize(app);
                const approval = app.approval_prompt.projection().?;
                const ready = if (comptime @hasField(App, "terminal"))
                    approval_screen.fileApprovalAffirmativeReady(
                        &app.shell,
                        approval,
                        &app.approval_screen,
                    )
                else
                    approval_ui.fileApprovalAffirmativeReady(
                        &app.shell,
                        approval,
                    );
                if (!ready) {
                    requestActiveSurfaceFrame(app);
                    debug_trace.logf(
                        "permission",
                        "file_approval_confirmation_blocked request_id={d} decision={s}",
                        .{
                            app.approval_prompt.request.?.id,
                            @tagName(decision),
                        },
                    );
                    return;
                }
                if (comptime @hasDecl(App, "beforeApprovalAffirmativeClaim")) {
                    app.beforeApprovalAffirmativeClaim();
                }
                if (!claimApprovalAffirmative(app)) {
                    debug_trace.logf(
                        "permission",
                        "file_approval_confirmation_blocked request_id={d} decision={s} reason=resize_interlock",
                        .{
                            app.approval_prompt.request.?.id,
                            @tagName(decision),
                        },
                    );
                    return;
                }
                affirmative_claimed = true;
            }
            defer if (affirmative_claimed) {
                releaseApprovalAffirmative(app);
            };
            const request_id = app.approval_prompt.request.?.id;
            var response = try app.approval_prompt.decision.materializeResponse(
                app.alloc,
                decision,
            );
            var response_submitted = false;
            errdefer if (!response_submitted) response.deinit();
            const result = app.worker.submitPermissionResponse(request_id, response);
            response_submitted = true;
            switch (result) {
                .accepted => {
                    clearApprovalPromptAfterSubmission(app);
                    app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
                    requestActiveSurfaceFrame(app);
                },
                .stale, .no_pending => {},
            }
        }

        fn submitRuleManagementChoice(
            app: *App,
            decision: ToolPermissionDecision,
        ) !void {
            if (comptime !@hasField(App, "session") or
                !@hasField(App, "session_persistence") or
                !@hasDecl(App, "writeDomainNotice"))
            {
                return error.RuleManagementUnavailable;
            } else {
                if (decision == .deny) {
                    clearApprovalPromptAfterSubmission(app);
                    try app.writeDomainNotice(.{
                        .topic = "permissions",
                        .tone = .neutral,
                        .body = "saved-session permission change cancelled",
                    }, true);
                    requestActiveSurfaceFrame(app);
                    return;
                }
                const managed = app.approval_prompt.rule_management orelse return;
                var current = try app.session.snapshotPermissionState(app.alloc);
                defer current.deinit(app.alloc);
                const result = try session_permission_state.apply(
                    app.alloc,
                    current,
                    managed.event,
                );
                switch (result) {
                    .applied => |next_value| {
                        var next = next_value;
                        defer next.deinit(app.alloc);
                        try app_session_runtime.Runtime(App).commitPermissionState(
                            app,
                            next,
                        );
                        app.session.replacePermissionStateOwned(app.alloc, &next);
                        clearApprovalPromptAfterSubmission(app);
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .neutral,
                            .body = "saved-session permission rule updated",
                        }, true);
                    },
                    .stale => {
                        clearApprovalPrompt(app, "rule_management_stale");
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .warning,
                            .body = "saved-session permission rule changed before confirmation",
                        }, true);
                    },
                    .full => {
                        clearApprovalPrompt(app, "rule_management_full");
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .warning,
                            .body = "saved-session permission rule capacity reached",
                        }, true);
                    },
                    .invalid => {
                        clearApprovalPrompt(app, "rule_management_invalid");
                        try app.writeDomainNotice(.{
                            .topic = "permissions",
                            .tone = .@"error",
                            .body = "saved-session permission rule is invalid",
                        }, true);
                    },
                }
                requestActiveSurfaceFrame(app);
            }
        }

        fn submitSubagentPermissionChoice(
            app: *App,
            decision: ToolPermissionDecision,
        ) !bool {
            if (comptime !@hasField(App, "subagents") or
                !@hasField(App, "session_persistence")) return false;
            if (comptime !@hasDecl(@TypeOf(app.subagents), "mainApprovalBinding")) return false;
            const request_id = app.approval_prompt.request.?.id;
            var maybe_binding = app.subagents.mainApprovalBinding(request_id);
            if (maybe_binding == null) {
                if (comptime @hasField(App, "approval_screen") and
                    @hasDecl(@TypeOf(app.subagents), "mainApprovalCardBinding"))
                {
                    if (app.approval_screen.screen_commit) |commit| {
                        if (commit.request_id == request_id) {
                            maybe_binding = app.subagents.mainApprovalCardBinding(request_id);
                        }
                    }
                }
            }
            const binding = maybe_binding orelse return false;
            const host = app_session_runtime.Runtime(App).subagentHost(app) orelse return true;
            var response = try app.approval_prompt.decision.materializeResponse(
                app.alloc,
                decision,
            );
            defer response.deinit();
            const resolved = host.resolveApproval(.{
                .request_id = binding.approval_id,
                .child_id = binding.child_id,
                .decision = response.decision,
                .feedback = response.feedback,
                .timestamp_ms = io_mod.milliTimestamp(),
            }) catch |err| {
                const stale = err == error.RequestNotFound or
                    err == error.StaleRequest or err == error.WrongChild;
                debug_trace.logf(
                    "subagent",
                    "main approval response failed request_id={s} child_id={s} outcome={s}",
                    .{ binding.approval_id, binding.child_id, @errorName(err) },
                );
                if (stale) {
                    clearApprovalPrompt(app, "subagent_approval_stale");
                    app.subagents.markMainApprovalPresented(false);
                    if (comptime @hasDecl(App, "refreshSubagentManagerProjection")) {
                        try app.refreshSubagentManagerProjection();
                    }
                    requestActiveSurfaceFrame(app);
                }
                return true;
            };
            if (resolved == .accepted) {
                clearApprovalPromptAfterSubmission(app);
                app.subagents.markMainApprovalPresented(false);
                if (comptime @hasDecl(App, "refreshSubagentManagerProjection")) {
                    try app.refreshSubagentManagerProjection();
                }
                requestActiveSurfaceFrame(app);
            } else {
                clearApprovalPrompt(app, "subagent_approval_first_response_won");
                app.subagents.markMainApprovalPresented(false);
                requestActiveSurfaceFrame(app);
            }
            return true;
        }

        pub fn cancelApprovalOperation(app: *App) !void {
            if (comptime @hasField(App, "subagents")) {
                if (comptime @hasDecl(@TypeOf(app.subagents), "mainApprovalBinding")) {
                    if (app.approval_prompt.request) |request| {
                        if (app.subagents.mainApprovalBinding(request.id) != null) {
                            clearApprovalPrompt(app, "subagent_approval_dismissed");
                            app.subagents.dismissMainApproval();
                            requestActiveSurfaceFrame(app);
                            return;
                        }
                    }
                }
            }
            const already_cancelled = app.worker.isCancelRequested();
            if (!already_cancelled) {
                debug_trace.logf("input", "cancel approval operation queued={d}", .{app.worker.queuedPromptCount()});
                interrupt.traceInterruptRequested(app, "input_approval");
            }
            if (comptime @hasField(App, "queued_prompt_review")) {
                _ = queue_rt.pauseAndOpenAfterModalCancel(app);
            }
            app.worker.cancelApprovalTurn();

            clearApprovalPrompt(app, "cancelled");
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();

            if (!already_cancelled and app.stream.active) {
                app.pacer.clear(app.alloc);
                app.stopStream();
            }
            requestActiveSurfaceFrame(app);
        }

        fn claimApprovalAffirmative(app: *App) bool {
            if (comptime @hasDecl(App, "claimApprovalAffirmative")) {
                return app.claimApprovalAffirmative();
            }
            return false;
        }

        fn releaseApprovalAffirmative(app: *App) void {
            if (comptime @hasDecl(App, "releaseApprovalAffirmative")) {
                app.releaseApprovalAffirmative();
            }
        }

        fn admitPendingApprovalResize(app: *App) void {
            if (comptime @hasDecl(App, "admitPendingApprovalResize")) {
                _ = app.admitPendingApprovalResize();
            }
        }
    };
}
