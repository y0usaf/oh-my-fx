const std = @import("std");
const hooks = @import("../hooks/hooks.zig");
const notification_contract = @import("../notifications/notification_contract.zig");

pub const Preferences = notification_contract.Preferences;
pub const Notification = notification_contract.Notification;
const Kind = notification_contract.Kind;
const Cue = notification_contract.Cue;
const Provider = notification_contract.Provider;

pub fn Runtime(
    comptime App: type,
    comptime provider: Provider,
) type {
    return struct {
        pub fn configure(app: *App) notification_contract.ConfigureError!void {
            try provider.configure(app);
        }

        pub fn setPreferences(app: *App, next: Preferences) void {
            provider.set_preferences(app, next);
        }

        pub fn preferences(app: *const App) Preferences {
            return provider.preferences(app);
        }

        pub fn maxEnabled(app: *const App) bool {
            return provider.max_enabled(app);
        }

        pub fn queue(app: *App, notification: Notification) void {
            provider.queue(app, notification);
        }

        pub fn presentationFinished(app: *App) void {
            provider.presentation_finished(app);
        }

        pub fn flush(app: *App) void {
            provider.flush(app);
        }

        pub fn playCue(app: *App, cue: Cue) void {
            provider.play_cue(app, cue);
        }

        pub fn playMaxCue(app: *App, cue: Cue) void {
            provider.play_max_cue(app, cue);
        }

        pub fn dispatchAttentionRequired(
            app: *App,
            turn_id: u64,
            kind: hooks.AttentionKind,
        ) void {
            provider.dispatch_attention_required(app, turn_id, kind);
        }
    };
}

