//! First-party lifecycle hook providers.
//!
//! The Herdr provider reports semantic foreground state for interactive work.
//! Notification hooks live in `notifications` and keep sound policy outside
//! the Core hook harness.

const std = @import("std");
const hooks = @import("../core/hooks/hooks.zig");
const herdr = @import("hooks/herdr.zig");

pub const notifications = @import("hooks/notifications.zig");
pub const Client = herdr.Client;

pub fn Runtime(comptime App: type) type {
    return struct {
        /// Must run before the lifecycle runtime is frozen (currently the
        /// notification runtime performs the sole freeze right after this).
        pub fn configure(app: *App, active_session_id: ?[]const u8) !void {
            app.herdr.initFromEnv(app.alloc);
            if (!app.herdr.enabled) return;

            if (active_session_id) |session_id| {
                app.herdr.reportSession(session_id);
            }
            app.herdr.reportState(.idle, null);
            app.herdr.announce();

            try register(app);
        }

        fn register(app: *App) !void {
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.herdr.turn_end",
                .ctx = app,
                .run = postTurnEndHandler,
            });
            try app.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.herdr.attention_required",
                .ctx = app,
                .run = attentionRequiredHandler,
            });
        }

        pub fn reportWorking(app: *App) void {
            app.herdr.reportState(.working, null);
        }

        fn postTurnEndHandler(
            raw: *anyopaque,
            input: hooks.PostTurnEndInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (input.invocation.scope.kind != .interactive) return;
            app.herdr.reportState(.idle, null);
        }

        fn attentionRequiredHandler(
            raw: *anyopaque,
            input: hooks.AttentionRequiredInput,
        ) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (input.invocation.scope.kind != .interactive) return;
            app.herdr.reportState(.blocked, attentionStatus(input.kind));
        }

        fn attentionStatus(kind: hooks.AttentionKind) []const u8 {
            return switch (kind) {
                .permission => "permission",
                .question => "question",
                .route_recovery => "recovery",
            };
        }
    };
}

fn testInvocation(kind: hooks.ScopeKind) hooks.Invocation {
    return .{
        .scope = .{
            .kind = kind,
            .workspace_root = "/tmp/workspace",
            .session_id = "session",
        },
        .turn_id = 42,
    };
}
