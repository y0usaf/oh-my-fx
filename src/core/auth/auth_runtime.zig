const std = @import("std");
const api_key_validator = @import("api_key_validator.zig");
const credentials = @import("credentials.zig");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const grok_oauth = @import("grok_oauth.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_catalog = @import("provider_catalog.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const SourceSet = std.EnumSet(credentials.Source);

pub const CredentialRefreshMode = enum {
    if_needed,
    force,
};

const credential_source_order = [_]credentials.Source{
    .vercel_oidc_token,
    .ai_gateway_api_key,
    .fx_login,
    .stored_key,
    .chatgpt_subscription,
    .grok_subscription,
};

const SourceProbeFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!bool;
const CredentialLoaderFn = *const fn (?*anyopaque, Allocator, credentials.Source) anyerror!?credentials.Credential;
const StoredKeyStoreFn = *const fn (?*anyopaque, Allocator, []const u8) anyerror!void;

const max_api_key_entry_bytes: usize = 8 * 1024;
const max_api_key_mask_glyphs: usize = 32;
const max_manual_code_mask_glyphs: usize = 32;
const max_team_query_bytes: usize = 256;

fn sourceLabelOrMissing(source: ?credentials.Source) []const u8 {
    return credentials.sourceLabel(source orelse return "missing");
}

pub const FailureReason = enum {
    credential_refresh_failed,
    http_unauthorized,
};

pub const FailureSnapshot = struct {
    source: credentials.Source,
    reason: FailureReason,
    http_status: ?std.http.Status = null,

    pub fn fromHttp(status: std.http.Status, source: ?credentials.Source) ?FailureSnapshot {
        if (status != .unauthorized) return null;
        return .{
            .source = source orelse return null,
            .reason = .http_unauthorized,
            .http_status = status,
        };
    }

    /// Returns owned, detail-free text. The caller owns the returned slice.
    pub fn renderText(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} {s}", .{
            credentials.sourceLabel(self.source),
            switch (self.reason) {
                .credential_refresh_failed => "credential refresh failed",
                .http_unauthorized => "authentication failed",
            },
        });
        if (self.http_status) |status| {
            try out.writer.print(" · HTTP {d}", .{@intFromEnum(status)});
        }
        return try out.toOwnedSlice();
    }

    /// Returns owned JSON containing only the shared auth-failure facts.
    pub fn renderJson(self: FailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: FailureSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"source\":");
        try std.json.Stringify.value(credentials.sourceLabel(self.source), .{}, writer);
        try writer.writeAll(",\"reason\":");
        try std.json.Stringify.value(@tagName(self.reason), .{}, writer);
        if (self.http_status) |status| {
            try writer.print(",\"http_status\":{d}", .{@intFromEnum(status)});
        }
        try writer.writeByte('}');
    }
};

/// Returns an owned token when the selected provider credential can refresh.
/// The caller must release it with `secret.zeroAndFree`.
pub fn refreshCredentialToken(
    transport: oauth_transport.Provider,
    alloc: Allocator,
    source: credentials.Source,
    mode: CredentialRefreshMode,
) !?[]u8 {
    return refreshCredentialTokenForAccount(transport, alloc, source, mode, null);
}

pub fn refreshCredentialTokenForAccount(
    transport: oauth_transport.Provider,
    alloc: Allocator,
    source: credentials.Source,
    mode: CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    if (!credentials.sourceRefreshable(source)) return null;

    var credential = switch (source) {
        .fx_login => switch (mode) {
            .if_needed => (try credentials.loadFxLoginCredential(alloc, transport)) orelse return null,
            .force => (try credentials.refreshFxLoginCredential(alloc, transport)) orelse return null,
        },
        .chatgpt_subscription => switch (mode) {
            .if_needed => (try credentials.loadSource(alloc, transport, host.unavailable_secret_store, source)) orelse return null,
            .force => (try credentials.refreshChatGptCredential(alloc, transport)) orelse return null,
        },
        .grok_subscription => switch (mode) {
            .if_needed => (try credentials.loadSource(alloc, transport, host.unavailable_secret_store, source)) orelse return null,
            .force => (try credentials.refreshGrokCredential(alloc, transport)) orelse return null,
        },
        else => unreachable,
    };
    defer credential.deinit(alloc);
    if (expected_account_id) |expected| {
        const actual = credential.accountId() orelse return error.ChatGptAccountChanged;
        if (!std.mem.eql(u8, expected, actual)) return error.ChatGptAccountChanged;
    }

    const token = credential.token;
    credential.token = &.{};
    return token;
}

pub const AcquisitionAction = enum {
    connections,
    login,
    chatgpt_login,
    grok_login,
    setup,
    change_team,
    switch_credential,
    switch_provider,
    /// Clears a remembered choice so resolution returns to plain precedence.
    /// Without it the only way back would be editing settings.json by hand.
    automatic,
};

pub const PickerStage = enum {
    root,
    connections,
    provider,
    sign_in,
    api_key,
    change_team,
    switch_credential,
};

pub const ApiKeySaveStart = enum {
    started,
    /// Nothing typed, so Enter is a no-op the user already understands.
    empty,
    /// A previous save is still in flight. The entered key is discarded rather
    /// than queued, so the caller must say so instead of failing silently.
    busy,
};

pub const ApiKeySaveResult = union(enum) {
    empty,
    saved: bool,
    gateway_refused,
    gateway_unavailable,
    store_failed,
    reload_failed,
};

/// The save does a gateway round trip and a key-store write, either of which can
/// take seconds. It runs on a worker so the event loop keeps drawing; the worker
/// performs I/O only and hands the loaded credential back for the main thread to
/// adopt, keeping `selected_credential` single-threaded.
pub const ApiKeySaveOutcome = union(enum) {
    gateway_refused,
    gateway_unavailable,
    store_failed,
    reload_failed,
    loaded: credentials.Credential,

    pub fn deinit(self: *ApiKeySaveOutcome, alloc: Allocator) void {
        switch (self.*) {
            .loaded => |*credential| credential.deinit(alloc),
            else => {},
        }
        self.* = .reload_failed;
    }
};

const ApiKeySaveDeps = struct {
    ctx: ?*anyopaque = null,
    validator: api_key_validator.Provider = api_key_validator.unavailable_provider,
    store: StoredKeyStoreFn = storeUnavailableSecret,
    loader: CredentialLoaderFn = loadCredentialSource,
};

/// The whole save sequence with no runtime state, so outcome behaviour can be
/// tested synchronously while the worker owns only threading.
fn performApiKeySave(alloc: Allocator, key: []const u8, deps: ApiKeySaveDeps) ApiKeySaveOutcome {
    switch (deps.validator.validate(alloc, key)) {
        .accepted => {},
        .refused => return .gateway_refused,
        .unavailable => return .gateway_unavailable,
    }
    deps.store(deps.ctx, alloc, key) catch |err| {
        debug_trace.logf("auth", "api key save failed step=store err={s}", .{@errorName(err)});
        return .store_failed;
    };
    const loaded = deps.loader(deps.ctx, alloc, .stored_key) catch |err| {
        debug_trace.logf("auth", "api key save failed step=reload err={s}", .{@errorName(err)});
        return .reload_failed;
    };
    const credential = loaded orelse return .reload_failed;
    if (credential.source != .stored_key) {
        var wrong = credential;
        wrong.deinit(alloc);
        return .reload_failed;
    }
    return .{ .loaded = credential };
}

const ApiKeySaveRuntime = struct {
    const Self = @This();

    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    /// Owned for the worker's lifetime and zeroed by it, so the entry stage can
    /// drop its own buffer the moment the save starts.
    key: std.ArrayList(u8) = .empty,
    outcome: ?ApiKeySaveOutcome = null,
    deps: ApiKeySaveDeps = .{},

    fn start(self: *Self, alloc: Allocator, key: std.ArrayList(u8), deps: ApiKeySaveDeps) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running or self.thread != null) {
            self.mutex.unlock(io_mod.getIo());
            var rejected = key;
            secret.zeroAndFree(alloc, rejected.allocatedSlice());
            return false;
        }
        self.running = true;
        self.key = key;
        self.deps = deps;
        self.mutex.unlock(io_mod.getIo());

        self.thread = std.Thread.spawn(.{}, workerMain, .{ self, alloc }) catch {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.running = false;
            var abandoned = self.key;
            self.key = .empty;
            self.mutex.unlock(io_mod.getIo());
            secret.zeroAndFree(alloc, abandoned.allocatedSlice());
            debug_trace.logf("auth", "api key save worker failed to spawn", .{});
            return false;
        };
        return true;
    }

    fn workerMain(self: *Self, alloc: Allocator) void {
        const result = performApiKeySave(alloc, self.key.items, self.deps);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var spent = self.key;
        self.key = .empty;
        secret.zeroAndFree(alloc, spent.allocatedSlice());
        self.outcome = result;
        self.running = false;
    }

    /// Returns the finished outcome once, joining the worker first. Ownership of a
    /// loaded credential passes to the caller.
    fn take(self: *Self, alloc: Allocator) ?ApiKeySaveOutcome {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running) {
            self.mutex.unlock(io_mod.getIo());
            return null;
        }
        const thread = self.thread;
        self.thread = null;
        const outcome = self.outcome;
        self.outcome = null;
        self.mutex.unlock(io_mod.getIo());

        if (thread) |handle| handle.join();
        _ = alloc;
        return outcome;
    }

    fn isSaving(self: *const Self) bool {
        const mutable = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        return self.running;
    }

    fn deinit(self: *Self, alloc: Allocator) void {
        const thread = self.thread;
        self.thread = null;
        if (thread) |handle| handle.join();
        if (self.outcome) |*outcome| outcome.deinit(alloc);
        self.outcome = null;
        var spent = self.key;
        self.key = .empty;
        secret.zeroAndFree(alloc, spent.allocatedSlice());
        self.running = false;
    }
};

const ApiKeyExitReason = enum {
    cancel,
    saved,
    save_failed,
    screen_replacement,
    runtime_deinit,
};

const ManualCodeClearReason = enum {
    cancel,
    submitted,
    screen_replacement,
    runtime_deinit,
};

pub const Choice = union(enum) {
    provider: model_provider.ProviderId,
    source: credentials.Source,
    action: AcquisitionAction,
    team: usize,

    pub fn eql(self: Choice, other: Choice) bool {
        return switch (self) {
            .provider => |provider| switch (other) {
                .provider => |other_provider| provider == other_provider,
                .source, .action, .team => false,
            },
            .source => |source| switch (other) {
                .source => |other_source| source == other_source,
                .provider, .action, .team => false,
            },
            .action => |action| switch (other) {
                .provider, .source, .team => false,
                .action => |other_action| action == other_action,
            },
            .team => |team| switch (other) {
                .provider, .source, .action => false,
                .team => |other_team| team == other_team,
            },
        };
    }
};

pub const PickerView = struct {
    active: bool,
    available_sources: SourceSet,
    selected_choice: ?Choice,
    active_source: ?credentials.Source,
    active_provider: model_provider.ProviderId = .gateway,
    include_skip: bool,
    stage: PickerStage = .root,
    fx_login_session_available: bool = false,
    teams: []const login_flow.Team = &.{},
    current_team: ?[]const u8 = null,
    team_query: []const u8 = &.{},
    sign_in: login_flow.SignInSnapshot = .{},
    sign_in_source: credentials.Source = .fx_login,
    sign_in_code_visible: bool = false,
    sign_in_code_mask_count: usize = 0,
    api_key_mask_count: usize = 0,

    pub fn activeSourceLabel(self: PickerView) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn choiceCount(self: PickerView) usize {
        return switch (self.stage) {
            .root => if (self.include_skip)
                connectionChoiceCount()
            else if (comptime host_target.is_wasm)
                3
            else
                4,
            .connections => connectionChoiceCount(),
            .provider => if (comptime host_target.is_wasm) 2 else 3,
            .sign_in, .api_key => 0,
            .change_team => blk: {
                var count: usize = 0;
                for (self.teams) |team| {
                    if (teamMatchesQuery(team, self.team_query)) count += 1;
                }
                break :blk count;
            },
            .switch_credential => gatewaySourceCount(self.available_sources) + 1,
        };
    }

    pub fn choiceAt(self: PickerView, index: usize) ?Choice {
        return switch (self.stage) {
            .root => if (self.include_skip) connectionChoiceAt(index) else if (comptime host_target.is_wasm)
                switch (index) {
                    0 => .{ .action = .connections },
                    1 => .{ .action = .change_team },
                    2 => .{ .action = .switch_credential },
                    else => null,
                }
            else switch (index) {
                0 => .{ .action = .connections },
                1 => .{ .action = .switch_provider },
                2 => .{ .action = .change_team },
                3 => .{ .action = .switch_credential },
                else => null,
            },
            .connections => connectionChoiceAt(index),
            .provider => switch (index) {
                0 => .{ .provider = .gateway },
                1 => .{ .provider = .codex },
                2 => if (comptime host_target.is_wasm) null else .{ .provider = .grok },
                else => null,
            },
            .sign_in, .api_key => null,
            .change_team => blk: {
                var visible_index: usize = 0;
                for (self.teams, 0..) |team, team_index| {
                    if (!teamMatchesQuery(team, self.team_query)) continue;
                    if (visible_index == index) break :blk .{ .team = team_index };
                    visible_index += 1;
                }
                break :blk null;
            },
            .switch_credential => if (index < gatewaySourceCount(self.available_sources))
                .{ .source = gatewaySourceAtIndex(self.available_sources, index).? }
            else if (index == gatewaySourceCount(self.available_sources))
                .{ .action = .automatic }
            else
                null,
        };
    }

    pub fn choiceIsSelected(self: PickerView, choice: Choice) bool {
        const selected = self.selected_choice orelse return false;
        return selected.eql(choice);
    }

    pub fn selectedIndex(self: PickerView) usize {
        const selected = self.selected_choice orelse return 0;
        var index: usize = 0;
        while (self.choiceAt(index)) |choice| : (index += 1) {
            if (choice.eql(selected)) return index;
        }
        return 0;
    }

    pub fn choiceLabel(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| provider_catalog.label(provider),
            .source => |source| credentials.sourceLabel(source),
            .action => |action| switch (action) {
                .connections => "Connections",
                .login => "Sign in with Vercel",
                .chatgpt_login => "Sign in with Codex",
                .grok_login => "Sign in with Grok",
                .setup => if (self.include_skip) "Add an API key" else "API key",
                .change_team => "Change team",
                .switch_credential => "Switch credential",
                .switch_provider => "Switch provider",
                .automatic => "Automatic",
            },
            .team => |index| if (index < self.teams.len) self.teams[index].name else "",
        };
    }

    pub fn choiceDescription(self: PickerView, choice: Choice) []const u8 {
        return switch (choice) {
            .provider => |provider| if (provider == self.active_provider) "current" else "available",
            .source => |source| if (self.active_source == source) "current" else "available",
            .action => |action| switch (action) {
                .connections => "",
                .login => if (self.fx_login_session_available) "connected" else "",
                .chatgpt_login => if (self.available_sources.contains(.chatgpt_subscription)) "connected" else "",
                .grok_login => if (self.available_sources.contains(.grok_subscription)) "connected" else "",
                .setup, .switch_credential, .switch_provider => "",
                .automatic => "use the first available source",
                .change_team => if (self.fx_login_session_available) "choose a team" else "sign in first",
            },
            .team => |index| if (self.teamIsCurrent(index)) "current" else "",
        };
    }

    pub fn choiceEnabled(self: PickerView, choice: Choice) bool {
        return switch (choice) {
            .action => |action| (action != .change_team or self.fx_login_session_available) and
                (action != .chatgpt_login or !host_target.is_wasm) and
                (action != .grok_login or !host_target.is_wasm),
            .provider, .source, .team => true,
        };
    }

    fn teamIsCurrent(self: PickerView, index: usize) bool {
        if (index >= self.teams.len) return false;
        const current = self.current_team orelse return false;
        const team = self.teams[index];
        return std.mem.eql(u8, current, team.id) or std.mem.eql(u8, current, team.slug);
    }
};

fn connectionChoiceCount() usize {
    return if (comptime host_target.is_wasm) 2 else 4;
}

fn connectionChoiceAt(index: usize) ?Choice {
    if (comptime host_target.is_wasm) {
        return switch (index) {
            0 => .{ .action = .login },
            1 => .{ .action = .setup },
            else => null,
        };
    }
    return switch (index) {
        0 => .{ .action = .login },
        1 => .{ .action = .chatgpt_login },
        2 => .{ .action = .grok_login },
        3 => .{ .action = .setup },
        else => null,
    };
}

fn teamMatchesQuery(team: login_flow.Team, query: []const u8) bool {
    return text_utils.containsIgnoreCase(team.name, query) or
        text_utils.containsIgnoreCase(team.slug, query);
}

pub const GatewayTeamStatus = enum {
    set,
    unset,
    unknown,

    pub fn label(self: GatewayTeamStatus) []const u8 {
        return switch (self) {
            .set => "set",
            .unset => "unset",
            .unknown => "unknown",
        };
    }
};

pub const MissingHelpSurface = enum {
    cli,
    interactive,
};

pub const StatusSnapshot = struct {
    active_source: ?credentials.Source = null,
    required_source: ?credentials.Source = null,
    team: ?[]const u8 = null,
    owned_team: ?[]u8 = null,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    gateway_connected: bool = false,
    chatgpt_connected: bool = false,
    grok_connected: bool = false,
    /// The active credential is past its refresh deadline. Distinct from `refreshable`,
    /// which answers whether this source type can refresh at all.
    expired: bool = false,

    pub fn deinit(self: *StatusSnapshot, alloc: Allocator) void {
        if (self.owned_team) |team| alloc.free(team);
        self.* = .{};
    }

    pub fn activeSourceLabel(self: StatusSnapshot) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn refreshable(self: StatusSnapshot) bool {
        const source = self.active_source orelse return false;
        return credentials.sourceRefreshable(source);
    }

    pub fn missingHelp(self: StatusSnapshot, surface: MissingHelpSurface) ?[]const u8 {
        if (self.active_source != null) return null;
        if (self.stored_key_status == .unavailable) return credentials.unreadable_store_message;
        if (self.required_source == .chatgpt_subscription) {
            return switch (surface) {
                .cli => credentials.missing_chatgpt_credential_message,
                .interactive => credentials.missing_chatgpt_interactive_credential_message,
            };
        }
        if (self.required_source == .grok_subscription) {
            return switch (surface) {
                .cli => credentials.missing_grok_credential_message,
                .interactive => credentials.missing_grok_interactive_credential_message,
            };
        }
        return switch (surface) {
            .cli => credentials.missing_credential_message,
            .interactive => credentials.missing_interactive_credential_message,
        };
    }

    /// Returns owned doctor status text containing no credential bytes.
    pub fn formatDoctorDetail(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        if (self.missingHelp(.cli)) |help| return alloc.dupe(u8, help);

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{s} is configured", .{self.activeSourceLabel()});
        if (self.expired) try out.writer.writeAll("; session expired");
        try out.writer.print("; refreshable={s}", .{if (self.refreshable()) "true" else "false"});
        if (self.team) |team| try out.writer.print("; team={s}", .{team});
        return try out.toOwnedSlice();
    }
};

pub fn loadStatusSnapshot(
    alloc: Allocator,
    secret_store: host.SecretStore,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    return loadStatusSnapshotForProvider(alloc, secret_store, null, preferred);
}

pub fn loadStatusSnapshotForProvider(
    alloc: Allocator,
    secret_store: host.SecretStore,
    provider: ?model_provider.ProviderId,
    preferred: ?credentials.Source,
) !StatusSnapshot {
    const chatgpt_connected = credentials.sourceExists(
        alloc,
        secret_store,
        .chatgpt_subscription,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    const grok_connected = credentials.sourceExists(
        alloc,
        secret_store,
        .grok_subscription,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    // Resolves in `.stored` mode: a diagnostic must not refresh, because refreshing
    // rewrites the session file and performs network I/O. It reports the expired state
    // instead of repairing it.
    const resolution = (if (provider) |selected_provider|
        credentials.resolveForProvider(
            alloc,
            oauth_transport.unavailable_provider,
            secret_store,
            .stored,
            selected_provider,
            preferred,
        )
    else
        credentials.resolvePreferring(
            alloc,
            oauth_transport.unavailable_provider,
            secret_store,
            .stored,
            preferred,
        )) catch |err| switch (err) {
        error.OutOfMemory => return err,
        // The store could not be interrogated, so its contents are unknown rather than absent.
        else => blk: {
            debug_trace.logf("auth", "status snapshot failed step=resolve err={s}", .{@errorName(err)});
            break :blk credentials.Resolution{ .stored_key_status = .unavailable };
        },
    };
    const resolved_source = if (resolution.credential) |credential| credential.source else null;
    var gateway_connected = resolved_source != null and resolved_source != .chatgpt_subscription and resolved_source != .grok_subscription;
    const gateway_probe_required = provider == .codex or provider == .grok or
        resolved_source == .chatgpt_subscription or resolved_source == .grok_subscription;
    if (gateway_probe_required) {
        for ([_]credentials.Source{ .vercel_oidc_token, .ai_gateway_api_key, .fx_login, .stored_key }) |source| {
            if (credentials.sourceExists(alloc, secret_store, source) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => false,
            }) {
                gateway_connected = true;
                break;
            }
        }
    }
    if (resolution.credential) |loaded| {
        var credential = loaded;
        defer credential.deinit(alloc);
        const expired = credential.needsRefreshAt(io_mod.milliTimestamp());
        const owned_team = takeDisplayTeam(alloc, &credential);
        return .{
            .active_source = credential.source,
            .team = owned_team,
            .owned_team = owned_team,
            .stored_key_status = resolution.stored_key_status,
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = expired,
        };
    }
    return .{
        .required_source = if (provider == .codex)
            .chatgpt_subscription
        else if (provider == .grok)
            .grok_subscription
        else
            null,
        .stored_key_status = resolution.stored_key_status,
        .gateway_connected = gateway_connected,
        .chatgpt_connected = chatgpt_connected,
        .grok_connected = grok_connected,
    };
}

pub const View = struct {
    active_source: ?credentials.Source,
    available_inactive_sources: SourceSet,
    selected_team: ?[]const u8,
    refreshable: bool,
    stored_key_status: credentials.StoredKeyReadStatus,
    onboarding_skipped: bool,

    pub fn activeSourceLabel(self: View) []const u8 {
        return sourceLabelOrMissing(self.active_source);
    }

    pub fn gatewayTeamStatus(self: View) GatewayTeamStatus {
        if (self.active_source == null) return .unknown;
        return if (self.selected_team == null) .unset else .set;
    }
};

pub const GatewayCredential = struct {
    api_key: []const u8,
    gateway_team: ?[]const u8,
    source: credentials.Source,
};

pub const Runtime = struct {
    const Self = @This();

    api_key_validator: api_key_validator.Provider = api_key_validator.unavailable_provider,
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    secret_store: host.SecretStore = host.unavailable_secret_store,
    selected_credential: ?credentials.Credential = null,
    credential_refresh_failure_source: ?credentials.Source = null,
    source_inventory: SourceSet = .empty,
    stored_key_status: credentials.StoredKeyReadStatus = .not_attempted,
    onboarding_skipped: bool = false,
    picker_active: bool = false,
    picker_selection: ?Choice = null,
    picker_include_skip: bool = false,
    picker_stage: PickerStage = .root,
    provider_picker_active: model_provider.ProviderId = .gateway,
    fx_login_session_available: bool = false,
    team_selection: ?login_flow.TeamSelection = null,
    team_query: std.ArrayList(u8) = .empty,
    sign_in_flow: login_flow.SignInRuntime = .{},
    sign_in_source: credentials.Source = .fx_login,
    sign_in_returns_to_root: bool = false,
    sign_in_code_visible: bool = false,
    sign_in_code_input: std.ArrayList(u8) = .empty,
    api_key_input: std.ArrayList(u8) = .empty,
    api_key_returns_to_root: bool = false,
    api_key_save: ApiKeySaveRuntime = .{},

    pub fn init(
        validator: api_key_validator.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) Self {
        return .{
            .api_key_validator = validator,
            .oauth_transport = transport,
            .secret_store = secret_store,
        };
    }

    /// Fieldwise initialization avoids retaining inactive credential and
    /// worker payloads in a static release-binary template.
    pub fn initInto(
        storage: *Self,
        validator: api_key_validator.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) void {
        comptime {
            if (std.meta.fields(Self).len != 24) {
                @compileError("update Runtime.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.api_key_validator = validator;
        storage.oauth_transport = transport;
        storage.secret_store = secret_store;
        storage.selected_credential = null;
        storage.credential_refresh_failure_source = null;
        storage.source_inventory = .empty;
        storage.stored_key_status = .not_attempted;
        storage.onboarding_skipped = false;
        storage.picker_active = false;
        storage.picker_selection = null;
        storage.picker_include_skip = false;
        storage.picker_stage = .root;
        storage.provider_picker_active = .gateway;
        storage.fx_login_session_available = false;
        storage.team_selection = null;
        storage.team_query = .empty;
        storage.sign_in_flow = .{};
        storage.sign_in_source = .fx_login;
        storage.sign_in_returns_to_root = false;
        storage.sign_in_code_visible = false;
        storage.sign_in_code_input = .empty;
        storage.api_key_input = .empty;
        storage.api_key_returns_to_root = false;
        storage.api_key_save = .{};
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.api_key_save.deinit(alloc);
        self.sign_in_flow.deinit(alloc);
        self.clearSignInCodeInput(alloc, .runtime_deinit);
        self.exitApiKeyStage(alloc, .runtime_deinit);
        self.clearTeamSelection(alloc);
        self.team_query.deinit(alloc);
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.* = .{};
    }

    /// Borrows the current credential until this runtime replaces or releases it.
    pub fn gatewayCredential(self: *const Self) ?GatewayCredential {
        return self.gatewayCredentialAt(io_mod.milliTimestamp());
    }

    fn gatewayCredentialAt(self: *const Self, now_ms: i64) ?GatewayCredential {
        const credential = self.selected_credential orelse return null;
        if (credential.needsRefreshAt(now_ms)) return null;
        return .{
            .api_key = credential.token,
            .gateway_team = credential.gatewayTeam(),
            .source = credential.source,
        };
    }

    pub fn apiKey(self: *const Self) ?[]const u8 {
        const credential = self.gatewayCredential() orelse return null;
        return credential.api_key;
    }

    pub fn oauthTransport(self: *const Self) oauth_transport.Provider {
        return self.oauth_transport;
    }

    pub fn secretStore(self: *const Self) host.SecretStore {
        return self.secret_store;
    }

    pub fn modelCatalogAccess(self: *const Self) credentials.CatalogAccess {
        if (self.credential_refresh_failure_source) |source| {
            return credentials.catalogAccessAfterRefreshFailure(source);
        }
        return credentials.catalogAccessAt(self.selected_credential, io_mod.milliTimestamp());
    }

    pub fn recordCredentialRefreshFailure(self: *Self, source: credentials.Source) void {
        std.debug.assert(self.credentialSource() == source);
        self.credential_refresh_failure_source = source;
    }

    pub fn credentialSource(self: *const Self) ?credentials.Source {
        const credential = self.selected_credential orelse return null;
        return credential.source;
    }

    pub fn accountId(self: *const Self) ?[]const u8 {
        const credential = self.selected_credential orelse return null;
        return credential.accountId();
    }

    pub fn gatewayTeam(self: *const Self) ?[]const u8 {
        const credential = self.gatewayCredential() orelse return null;
        return credential.gateway_team;
    }

    pub fn credentialNeedsRefresh(self: *const Self) bool {
        return self.credentialNeedsRefreshAt(io_mod.milliTimestamp());
    }

    fn credentialNeedsRefreshAt(self: *const Self, now_ms: i64) bool {
        const credential = self.selected_credential orelse return false;
        return credential.needsRefreshAt(now_ms);
    }

    pub fn statusSnapshot(self: *const Self) StatusSnapshot {
        return self.statusSnapshotAt(io_mod.milliTimestamp());
    }

    fn statusSnapshotAt(self: *const Self, now_ms: i64) StatusSnapshot {
        const gateway_connected = self.source_inventory.contains(.vercel_oidc_token) or
            self.source_inventory.contains(.ai_gateway_api_key) or
            self.source_inventory.contains(.fx_login) or
            self.source_inventory.contains(.stored_key);
        const chatgpt_connected = self.source_inventory.contains(.chatgpt_subscription);
        const grok_connected = self.source_inventory.contains(.grok_subscription);
        const credential = self.selected_credential orelse return .{
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
        };
        return .{
            .active_source = credential.source,
            .team = displayTeam(credential),
            .gateway_connected = gateway_connected,
            .chatgpt_connected = chatgpt_connected,
            .grok_connected = grok_connected,
            .expired = credential.needsRefreshAt(now_ms),
        };
    }

    pub fn view(self: *const Self) View {
        const active_source = self.credentialSource();
        var available_inactive_sources = self.source_inventory;
        if (active_source) |source| available_inactive_sources.remove(source);

        return .{
            .active_source = active_source,
            .available_inactive_sources = available_inactive_sources,
            .selected_team = if (self.selected_credential) |credential| credential.gatewayTeam() else null,
            .refreshable = if (active_source) |source| credentials.sourceRefreshable(source) else false,
            .stored_key_status = self.stored_key_status,
            .onboarding_skipped = self.onboarding_skipped,
        };
    }

    pub fn recordStartupStatus(
        self: *Self,
        stored_key_status: credentials.StoredKeyReadStatus,
        onboarding_skipped: bool,
    ) void {
        self.stored_key_status = stored_key_status;
        self.onboarding_skipped = onboarding_skipped;
    }

    pub fn skipOnboarding(self: *Self) void {
        self.onboarding_skipped = true;
    }

    pub fn refreshSourceInventory(self: *Self, alloc: Allocator) !void {
        try self.refreshSourceInventoryWithProbe(alloc, self, probeCredentialSource);
    }

    pub fn refreshChatGptSourceInventory(self: *Self, alloc: Allocator) !void {
        if (try credentials.sourceExists(alloc, self.secret_store, .chatgpt_subscription)) {
            self.source_inventory.insert(.chatgpt_subscription);
        } else if (self.credentialSource() != .chatgpt_subscription) {
            self.source_inventory.remove(.chatgpt_subscription);
        }
    }

    pub fn refreshGrokSourceInventory(self: *Self, alloc: Allocator) !void {
        if (try credentials.sourceExists(alloc, self.secret_store, .grok_subscription)) {
            self.source_inventory.insert(.grok_subscription);
        } else if (self.credentialSource() != .grok_subscription) {
            self.source_inventory.remove(.grok_subscription);
        }
    }

    fn refreshSourceInventoryWithProbe(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
    ) !void {
        var detected: SourceSet = .empty;
        for (credential_source_order) |source| {
            if (try probe(ctx, alloc, source)) detected.insert(source);
        }
        self.fx_login_session_available = detected.contains(.fx_login);
        if (self.credentialSource()) |source| detected.insert(source);
        self.source_inventory = detected;
    }

    pub fn openPicker(self: *Self, alloc: Allocator) void {
        self.openPickerForProvider(alloc, .gateway);
    }

    pub fn openPickerForProvider(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.provider_picker_active = active_provider;
        self.openPickerWithSkip(alloc, false);
    }

    pub fn openOnboardingPicker(self: *Self, alloc: Allocator) void {
        self.openPickerWithSkip(alloc, true);
    }

    fn openPickerWithSkip(self: *Self, alloc: Allocator, include_skip: bool) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_include_skip = include_skip;
        self.picker_stage = .root;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn pickerView(self: *const Self) PickerView {
        return .{
            .active = self.picker_active,
            .available_sources = self.source_inventory,
            .selected_choice = self.picker_selection,
            .active_source = self.credentialSource(),
            .active_provider = self.provider_picker_active,
            .include_skip = self.picker_include_skip,
            .stage = self.picker_stage,
            .fx_login_session_available = self.fx_login_session_available,
            .teams = if (self.team_selection) |*selection| selection.teams.items else &.{},
            .current_team = if (self.team_selection) |*selection|
                selection.currentTeam()
            else if (self.selected_credential) |credential|
                credential.gatewayTeam()
            else
                null,
            .team_query = self.team_query.items,
            .sign_in = self.sign_in_flow.snapshot(),
            .sign_in_source = self.sign_in_source,
            .sign_in_code_visible = self.sign_in_code_visible,
            .sign_in_code_mask_count = @min(self.sign_in_code_input.items.len, max_manual_code_mask_glyphs),
            .api_key_mask_count = @min(self.api_key_input.items.len, max_api_key_mask_glyphs),
        };
    }

    pub fn movePicker(self: *Self, delta: i32) bool {
        if (!self.picker_active or delta == 0) return false;
        const picker = self.pickerView();
        const choice_count = picker.choiceCount();
        if (choice_count < 2) return false;
        var next_index = picker.selectedIndex();
        for (0..choice_count) |_| {
            next_index = if (delta < 0)
                if (next_index == 0) choice_count - 1 else next_index - 1
            else if (next_index + 1 == choice_count)
                0
            else
                next_index + 1;
            const choice = picker.choiceAt(next_index) orelse continue;
            if (!picker.choiceEnabled(choice)) continue;
            self.picker_selection = choice;
            return true;
        }
        return false;
    }

    pub fn openTeamPicker(self: *Self, alloc: Allocator, selection: *login_flow.TeamSelection) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.team_selection = selection.take();
        self.picker_include_skip = false;
        self.picker_stage = .change_team;
        self.picker_selection = self.currentTeamChoice() orelse self.pickerView().choiceAt(0);
    }

    fn openConnectionPicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .connections;
        self.picker_selection = self.pickerView().choiceAt(0);
    }

    pub fn openProviderPicker(
        self: *Self,
        alloc: Allocator,
        active_provider: model_provider.ProviderId,
    ) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_include_skip = false;
        self.picker_stage = .provider;
        self.provider_picker_active = active_provider;
        self.picker_selection = .{ .provider = active_provider };
    }

    pub fn teamPickerActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .change_team;
    }

    pub fn appendTeamQueryByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.teamPickerActive()) return false;
        if (byte < 0x20 or byte == 0x7f) return false;
        if (self.team_query.items.len < max_team_query_bytes) {
            try self.team_query.append(alloc, byte);
            self.resetTeamPickerSelection();
        }
        return true;
    }

    pub fn deleteTeamQueryByte(self: *Self) bool {
        if (!self.teamPickerActive()) return false;
        if (self.team_query.items.len > 0) {
            const end = text_utils.utf8BackwardBoundary(
                self.team_query.items,
                self.team_query.items.len - 1,
            );
            self.team_query.shrinkRetainingCapacity(end);
            self.resetTeamPickerSelection();
        }
        return true;
    }

    pub fn openSwitchCredentialPicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.picker_stage = .switch_credential;
        const active_source = self.credentialSource();
        self.picker_selection = if (active_source) |source|
            if (source != .chatgpt_subscription and source != .grok_subscription and self.source_inventory.contains(source))
                .{ .source = source }
            else
                self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    pub fn openApiKeyPicker(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, false);
    }

    pub fn openApiKeyPickerFromRoot(self: *Self, alloc: Allocator) void {
        self.openApiKeyPickerWithParent(alloc, true);
    }

    fn openApiKeyPickerWithParent(self: *Self, alloc: Allocator, returns_to_root: bool) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .api_key;
        self.picker_selection = null;
        self.api_key_returns_to_root = returns_to_root;
    }

    pub fn openSignInPicker(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, false, .fx_login);
    }

    pub fn openSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        return self.openSignInPickerWithParent(alloc, true, .fx_login);
    }

    pub fn openChatGptSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, true, .chatgpt_subscription);
    }

    pub fn openChatGptSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, false, .chatgpt_subscription);
    }

    pub fn openGrokSignInPickerFromRoot(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, true, .grok_subscription);
    }

    pub fn openGrokSignInPickerForProviderSwitch(self: *Self, alloc: Allocator) !bool {
        if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
        return self.openSignInPickerWithParent(alloc, false, .grok_subscription);
    }

    fn openSignInPickerWithParent(
        self: *Self,
        alloc: Allocator,
        returns_to_root: bool,
        source: credentials.Source,
    ) !bool {
        self.exitSignInStage(alloc);
        const started = switch (source) {
            .fx_login => try self.sign_in_flow.start(alloc, self.oauth_transport),
            .chatgpt_subscription => try chatgpt_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            .grok_subscription => try grok_oauth.startSignIn(&self.sign_in_flow, alloc, self.oauth_transport),
            else => return error.InvalidSignInSource,
        };
        if (!started) return false;
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = true;
        self.picker_stage = .sign_in;
        self.picker_selection = null;
        self.sign_in_source = source;
        self.sign_in_returns_to_root = returns_to_root;
        self.sign_in_code_visible = false;
        return true;
    }

    pub fn signInEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .sign_in;
    }

    pub fn signInCodeEntryActive(self: *const Self) bool {
        return self.signInEntryActive() and
            self.sign_in_flow.snapshot().accepts_manual_code and
            self.sign_in_code_visible;
    }

    pub fn toggleSignInCodeEntry(self: *Self) bool {
        if (!self.signInEntryActive() or !self.sign_in_flow.snapshot().accepts_manual_code) {
            return false;
        }
        self.sign_in_code_visible = !self.sign_in_code_visible;
        return true;
    }

    pub fn signInReturnsToRoot(self: *const Self) bool {
        return self.sign_in_returns_to_root;
    }

    pub fn signInBrowserUrlAlloc(self: *Self, alloc: Allocator) !?[]u8 {
        if (!self.signInEntryActive()) return null;
        return self.sign_in_flow.browserUrlAlloc(alloc);
    }

    pub fn pollSignInTransition(self: *Self, alloc: Allocator) login_flow.SignInTransition {
        return self.sign_in_flow.pollTransition(alloc);
    }

    pub fn pulseSignIn(self: *Self, alloc: Allocator) void {
        self.sign_in_flow.pulse(alloc);
    }

    pub fn appendSignInCodeByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.signInCodeEntryActive()) return false;
        if (byte <= 0x20 or byte > 0x7e) return true;
        if (self.sign_in_code_input.items.len >= login_flow.max_manual_code_bytes) return true;
        try self.sign_in_code_input.ensureTotalCapacityPrecise(alloc, login_flow.max_manual_code_bytes);
        self.sign_in_code_input.appendAssumeCapacity(byte);
        return true;
    }

    pub fn deleteSignInCodeByte(self: *Self) bool {
        if (!self.signInCodeEntryActive()) return false;
        if (self.sign_in_code_input.items.len > 0) {
            self.sign_in_code_input.items.len -= 1;
            self.sign_in_code_input.allocatedSlice()[self.sign_in_code_input.items.len] = 0;
        }
        return true;
    }

    pub fn replaceSignInCodeInput(self: *Self, alloc: Allocator, input: []const u8) !bool {
        if (!self.signInCodeEntryActive()) return false;
        const code = std.mem.trim(u8, input, " \t\r\n");
        if (code.len == 0 or code.len > login_flow.max_manual_code_bytes) return false;
        for (code) |byte| {
            if (byte < 0x21 or byte > 0x7e) return false;
        }
        if (self.sign_in_code_input.capacity > 0) {
            self.sign_in_code_input.clearRetainingCapacity();
            @memset(self.sign_in_code_input.allocatedSlice(), 0);
        }
        try self.sign_in_code_input.ensureTotalCapacityPrecise(alloc, login_flow.max_manual_code_bytes);
        self.sign_in_code_input.appendSliceAssumeCapacity(code);
        return true;
    }

    pub fn submitSignInCode(self: *Self, alloc: Allocator) !bool {
        if (!self.signInCodeEntryActive() or self.sign_in_code_input.items.len == 0) return false;
        if (!try self.sign_in_flow.submitManualCode(alloc, self.sign_in_code_input.items)) return false;
        self.clearSignInCodeInput(alloc, .submitted);
        return true;
    }

    pub fn apiKeyEntryActive(self: *const Self) bool {
        return self.picker_active and self.picker_stage == .api_key;
    }

    pub fn appendApiKeyByte(self: *Self, alloc: Allocator, byte: u8) !bool {
        if (!self.apiKeyEntryActive()) return false;
        if (self.api_key_input.items.len >= max_api_key_entry_bytes) return true;
        if (byte < 0x20 or byte == 0x7f) return true;
        // Reserve the entry ceiling up front so growth never abandons an
        // unzeroed buffer holding part of the key.
        try self.api_key_input.ensureTotalCapacityPrecise(alloc, max_api_key_entry_bytes);
        self.api_key_input.appendAssumeCapacity(byte);
        return true;
    }

    pub fn deleteApiKeyByte(self: *Self) bool {
        if (!self.apiKeyEntryActive()) return false;
        if (self.api_key_input.items.len > 0) _ = self.api_key_input.pop();
        return true;
    }

    /// Hands the entered key to a worker and pops the stage immediately. The key
    /// store write can block for seconds on a locked keychain, and the gateway
    /// check is a network round trip; neither may run on the event loop.
    pub fn beginApiKeySave(self: *Self, alloc: Allocator) ApiKeySaveStart {
        return self.beginApiKeySaveWithDeps(alloc, .{
            .ctx = self,
            .validator = self.api_key_validator,
            .store = storeRuntimeSecret,
            .loader = loadRuntimeCredentialSource,
        });
    }

    fn beginApiKeySaveWithDeps(self: *Self, alloc: Allocator, deps: ApiKeySaveDeps) ApiKeySaveStart {
        if (!self.apiKeyEntryActive() or self.api_key_input.items.len == 0) return .empty;

        // Ownership moves to the worker, so the stage exit below has nothing to zero.
        const key = self.api_key_input;
        self.api_key_input = .empty;

        const returns_to_root = self.api_key_returns_to_root;
        self.exitApiKeyStage(alloc, .saved);
        self.picker_active = returns_to_root;
        if (!returns_to_root or self.picker_include_skip) {
            self.picker_stage = .root;
            self.picker_selection = if (returns_to_root) .{ .action = .setup } else null;
        } else {
            self.picker_stage = .connections;
            self.picker_selection = .{ .action = .setup };
        }

        return if (self.api_key_save.start(alloc, key, deps)) .started else .busy;
    }

    pub fn apiKeySaveInFlight(self: *const Self) bool {
        return self.api_key_save.isSaving();
    }

    /// Applies a finished save on the main thread. Adopting the credential here
    /// keeps `selected_credential` off the worker.
    pub fn takeApiKeySaveResult(self: *Self, alloc: Allocator) ?ApiKeySaveResult {
        var outcome = self.api_key_save.take(alloc) orelse return null;
        return switch (outcome) {
            .gateway_refused => .gateway_refused,
            .gateway_unavailable => .gateway_unavailable,
            .store_failed => .store_failed,
            .reload_failed => .reload_failed,
            .loaded => |*credential| blk: {
                var owned = credential.*;
                outcome = .reload_failed;
                defer owned.deinit(alloc);
                break :blk .{ .saved = self.adoptCredential(alloc, &owned) };
            },
        };
    }

    pub fn popPickerStage(self: *Self, alloc: Allocator) bool {
        if (!self.picker_active) return false;
        const stage = self.picker_stage;
        if (stage == .root) {
            self.closePicker(alloc);
            return true;
        }
        if (stage == .provider) {
            self.picker_stage = .root;
            self.picker_selection = .{ .action = .switch_provider };
            return true;
        }
        if (stage == .connections) {
            self.picker_stage = .root;
            self.picker_selection = .{ .action = .connections };
            return true;
        }

        if (stage == .sign_in) {
            const returns_to_root = self.sign_in_returns_to_root;
            _ = self.sign_in_flow.cancel(alloc);
            self.clearSignInCodeInput(alloc, .cancel);
            self.sign_in_returns_to_root = false;
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
            if (!self.picker_include_skip) {
                self.clearTeamSelection(alloc);
                self.picker_stage = .connections;
                self.picker_selection = .{ .action = switch (self.sign_in_source) {
                    .chatgpt_subscription => .chatgpt_login,
                    .grok_subscription => .grok_login,
                    else => .login,
                } };
                return true;
            }
        }

        if (stage == .api_key) {
            const returns_to_root = self.api_key_returns_to_root;
            self.exitApiKeyStage(alloc, .cancel);
            if (!returns_to_root) {
                self.picker_active = false;
                self.picker_stage = .root;
                self.picker_selection = null;
                return true;
            }
            if (!self.picker_include_skip) {
                self.clearTeamSelection(alloc);
                self.picker_stage = .connections;
                self.picker_selection = .{ .action = .setup };
                return true;
            }
        }

        self.clearTeamSelection(alloc);
        self.picker_stage = .root;
        self.picker_selection = .{ .action = switch (stage) {
            .root => unreachable,
            .connections => unreachable,
            .provider => unreachable,
            .sign_in => if (self.sign_in_source == .chatgpt_subscription)
                .chatgpt_login
            else if (self.sign_in_source == .grok_subscription)
                .grok_login
            else
                .login,
            .api_key => .setup,
            .change_team => .change_team,
            .switch_credential => .switch_credential,
        } };
        return true;
    }

    pub fn closePicker(self: *Self, alloc: Allocator) void {
        self.exitSignInStage(alloc);
        self.exitApiKeyStage(alloc, .screen_replacement);
        self.clearTeamSelection(alloc);
        self.picker_active = false;
        self.picker_stage = .root;
    }

    pub fn takePickerChoice(self: *Self, alloc: Allocator) ?Choice {
        if (!self.picker_active) return null;
        if (self.picker_stage == .sign_in or self.picker_stage == .api_key) return null;
        const choice = self.picker_selection;
        const selected = choice orelse return null;
        if (!self.pickerView().choiceEnabled(selected)) return null;

        switch (self.picker_stage) {
            .sign_in, .api_key => unreachable,
            .connections => switch (selected) {
                .action => |action| switch (action) {
                    .login, .chatgpt_login, .grok_login => self.closePicker(alloc),
                    .setup => {},
                    .connections,
                    .change_team,
                    .switch_credential,
                    .switch_provider,
                    .automatic,
                    => unreachable,
                },
                .provider, .source, .team => unreachable,
            },
            .provider => switch (selected) {
                .provider => self.closePicker(alloc),
                .source, .action, .team => unreachable,
            },
            .root => switch (selected) {
                .provider => unreachable,
                .source => self.closePicker(alloc),
                .action => |action| switch (action) {
                    .connections => {
                        self.openConnectionPicker(alloc);
                        return null;
                    },
                    .change_team => {},
                    .switch_provider => {},
                    .switch_credential => {
                        self.openSwitchCredentialPicker(alloc);
                        return null;
                    },
                    .setup => {},
                    // Only reachable from the switch screen, never the root.
                    .automatic => unreachable,
                    .login, .chatgpt_login, .grok_login => self.closePicker(alloc),
                },
                .team => unreachable,
            },
            .change_team => switch (selected) {
                .team => {},
                .provider, .source, .action => unreachable,
            },
            .switch_credential => switch (selected) {
                .source => self.closePicker(alloc),
                // Automatic is the only action this stage offers; the app
                // handler clears the stored choice and closes the picker.
                .action => |action| std.debug.assert(action == .automatic),
                .provider, .team => unreachable,
            },
        }
        return choice;
    }

    fn exitSignInStage(self: *Self, alloc: Allocator) void {
        if (self.picker_stage != .sign_in) return;
        _ = self.sign_in_flow.cancel(alloc);
        self.clearSignInCodeInput(alloc, .screen_replacement);
        self.sign_in_returns_to_root = false;
    }

    fn clearSignInCodeInput(self: *Self, alloc: Allocator, reason: ManualCodeClearReason) void {
        const byte_count = self.sign_in_code_input.items.len;
        self.sign_in_code_visible = false;
        if (self.sign_in_code_input.capacity > 0) {
            secret.zeroAndFree(alloc, self.sign_in_code_input.allocatedSlice());
            self.sign_in_code_input = .empty;
        }
        if (byte_count > 0) {
            debug_trace.logf(
                "auth",
                "authorization code entry cleared reason={s} bytes={d}",
                .{ @tagName(reason), byte_count },
            );
        }
    }

    pub fn teamSelection(self: *Self) ?*login_flow.TeamSelection {
        if (!self.picker_active or self.picker_stage != .change_team) return null;
        return if (self.team_selection) |*selection| selection else null;
    }

    /// Moves the credential into this session and returns whether its source,
    /// token, effective Gateway team, or readiness changed.
    pub fn adoptCredential(self: *Self, alloc: Allocator, credential: *credentials.Credential) bool {
        const changed = if (self.selected_credential) |selected|
            selected.source != credential.source or
                !std.mem.eql(u8, selected.token, credential.token) or
                !optionalBytesEqual(selected.accountId(), credential.accountId()) or
                !optionalBytesEqual(selected.gatewayTeam(), credential.gatewayTeam()) or
                selected.refresh_after_ms != credential.refresh_after_ms
        else
            true;
        const source = credential.source;
        if (self.selected_credential) |*selected| selected.deinit(alloc);

        self.selected_credential = credential.*;
        self.credential_refresh_failure_source = null;
        credential.token = &.{};
        credential.account_id = null;
        credential.team_id = null;
        credential.team_slug = null;
        self.source_inventory.insert(source);
        if (source == .fx_login) self.fx_login_session_available = true;
        if (source == .stored_key) self.stored_key_status = .not_attempted;
        return changed;
    }

    pub fn adoptSelectedTeam(self: *Self, alloc: Allocator, selected_team: *login_flow.SelectedTeam) bool {
        const credential = if (self.selected_credential) |*selected| selected else return false;
        if (credential.source != .fx_login) return false;

        const changed = !optionalBytesEqual(credential.team_id, selected_team.id) or
            !optionalBytesEqual(credential.team_slug, selected_team.slug);
        if (credential.team_id) |team| alloc.free(team);
        if (credential.team_slug) |team| alloc.free(team);
        credential.team_id = selected_team.id;
        credential.team_slug = selected_team.slug;
        selected_team.id = &.{};
        selected_team.slug = &.{};
        return changed;
    }

    fn selectSourceWithLoader(
        self: *Self,
        alloc: Allocator,
        source: credentials.Source,
        ctx: ?*anyopaque,
        loader: CredentialLoaderFn,
    ) !?bool {
        var credential = (try loader(ctx, alloc, source)) orelse return null;
        defer credential.deinit(alloc);
        if (credential.source != source) return error.CredentialSourceMismatch;
        return self.adoptCredential(alloc, &credential);
    }

    pub fn selectSource(self: *Self, alloc: Allocator, source: credentials.Source) !?bool {
        return self.selectSourceWithLoader(alloc, source, self, loadRuntimeCredentialSource);
    }

    pub fn selectForProvider(
        self: *Self,
        alloc: Allocator,
        provider: model_provider.ProviderId,
    ) !?bool {
        return switch (provider) {
            .codex => if (self.credentialSource() == .chatgpt_subscription)
                false
            else
                self.selectSourceWithLoader(
                    alloc,
                    .chatgpt_subscription,
                    self,
                    loadRuntimeCredentialSource,
                ),
            .grok => if (self.credentialSource() == .grok_subscription)
                false
            else
                self.selectSourceWithLoader(
                    alloc,
                    .grok_subscription,
                    self,
                    loadRuntimeCredentialSource,
                ),
            .gateway => if (self.credentialSource() != .chatgpt_subscription and self.credentialSource() != .grok_subscription)
                false
            else
                @as(?bool, try self.reselectByPrecedenceWithDeps(
                    alloc,
                    self,
                    probeCredentialSource,
                    loadRuntimeCredentialSource,
                )),
        };
    }

    pub fn refreshFxLoginIfNeeded(self: *Self, alloc: Allocator) !bool {
        const source = self.credentialSource() orelse return false;
        if (!credentials.sourceRefreshable(source)) return false;

        const loaded = (try credentials.loadSource(alloc, self.oauth_transport, self.secret_store, source)) orelse {
            if (self.credentialNeedsRefresh()) return error.CredentialRefreshUnavailable;
            return false;
        };
        var credential = loaded;
        defer credential.deinit(alloc);
        return self.adoptCredential(alloc, &credential);
    }

    /// Drops the current selection and re-runs precedence after the user clears
    /// a remembered credential source.
    pub fn reselectByPrecedence(self: *Self, alloc: Allocator) !bool {
        return self.reselectByPrecedenceWithDeps(alloc, self, probeCredentialSource, loadRuntimeCredentialSource);
    }

    fn reselectByPrecedenceWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const previous = self.credentialSource();
        if (self.selected_credential) |*credential| credential.deinit(alloc);
        self.selected_credential = null;
        self.credential_refresh_failure_source = null;

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        for (credential_source_order) |source| {
            if (source == .chatgpt_subscription or source == .grok_subscription) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) {
                return self.credentialSource() != previous;
            }
            self.source_inventory.remove(source);
        }
        self.onboarding_skipped = false;
        return previous != null;
    }

    pub fn reconcileAfterChatGptLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.chatgpt_subscription);
        const was_active = self.credentialSource() == .chatgpt_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }

    pub fn reconcileAfterGrokLogout(self: *Self, alloc: Allocator) !bool {
        const was_available = self.source_inventory.contains(.grok_subscription);
        const was_active = self.credentialSource() == .grok_subscription;
        if (was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }
        try self.refreshSourceInventory(alloc);
        return was_active or was_available;
    }

    pub fn reconcileAfterFxLoginLogout(self: *Self, alloc: Allocator) !bool {
        return self.reconcileAfterFxLoginLogoutWithDeps(
            alloc,
            self,
            probeCredentialSource,
            loadRuntimeCredentialSource,
        );
    }

    fn reconcileAfterFxLoginLogoutWithDeps(
        self: *Self,
        alloc: Allocator,
        ctx: ?*anyopaque,
        probe: SourceProbeFn,
        loader: CredentialLoaderFn,
    ) !bool {
        const login_was_active = self.credentialSource() == .fx_login;
        if (login_was_active) {
            if (self.selected_credential) |*credential| credential.deinit(alloc);
            self.selected_credential = null;
            self.credential_refresh_failure_source = null;
        }

        try self.refreshSourceInventoryWithProbe(alloc, ctx, probe);
        if (!login_was_active) return false;

        for (credential_source_order) |source| {
            if (source == .chatgpt_subscription or source == .grok_subscription) continue;
            if (!self.source_inventory.contains(source)) continue;
            if (try self.selectSourceWithLoader(alloc, source, ctx, loader) != null) return true;
            self.source_inventory.remove(source);
        }

        self.onboarding_skipped = false;
        return true;
    }

    fn currentTeamChoice(self: *const Self) ?Choice {
        const picker = self.pickerView();
        for (picker.teams, 0..) |_, index| {
            if (picker.teamIsCurrent(index)) return .{ .team = index };
        }
        return null;
    }

    fn clearTeamSelection(self: *Self, alloc: Allocator) void {
        if (self.team_selection) |*selection| selection.deinit(alloc);
        self.team_selection = null;
        self.team_query.clearRetainingCapacity();
    }

    fn resetTeamPickerSelection(self: *Self) void {
        self.picker_selection = if (self.team_query.items.len == 0)
            self.currentTeamChoice() orelse self.pickerView().choiceAt(0)
        else
            self.pickerView().choiceAt(0);
    }

    fn exitApiKeyStage(self: *Self, alloc: Allocator, reason: ApiKeyExitReason) void {
        const byte_count = self.api_key_input.items.len;
        if (self.api_key_input.capacity > 0) {
            const allocated = self.api_key_input.allocatedSlice();
            secret.zeroAndFree(alloc, allocated);
            self.api_key_input = .empty;
        }
        self.api_key_returns_to_root = false;
        if (byte_count > 0) {
            debug_trace.logf(
                "auth",
                "api key entry cleared reason={s} bytes={d}",
                .{ @tagName(reason), byte_count },
            );
        }
    }
};

fn probeCredentialSource(raw_context: ?*anyopaque, alloc: Allocator, source: credentials.Source) !bool {
    const self: *Runtime = @ptrCast(@alignCast(raw_context.?));
    return credentials.sourceExists(alloc, self.secret_store, source);
}

fn loadCredentialSource(_: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    return credentials.loadSource(
        alloc,
        oauth_transport.unavailable_provider,
        host.unavailable_secret_store,
        source,
    );
}

fn loadRuntimeCredentialSource(raw: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return credentials.loadSource(alloc, self.oauth_transport, self.secret_store, source);
}

fn storeRuntimeSecret(raw: ?*anyopaque, alloc: Allocator, value: []const u8) !void {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.secret_store.store(alloc, value);
}

fn storeUnavailableSecret(_: ?*anyopaque, _: Allocator, _: []const u8) !void {
    return error.StoredKeyWriteFailed;
}

fn displayTeam(credential: credentials.Credential) ?[]const u8 {
    return credential.team_slug orelse credential.team_id;
}

fn takeDisplayTeam(alloc: Allocator, credential: *credentials.Credential) ?[]u8 {
    if (credential.team_slug) |team| {
        credential.team_slug = null;
        if (credential.team_id) |id| alloc.free(id);
        credential.team_id = null;
        return team;
    }
    const team = credential.team_id;
    credential.team_id = null;
    return team;
}

fn gatewaySourceCount(sources: SourceSet) usize {
    var count: usize = 0;
    for (credential_source_order) |source| {
        if (source == .chatgpt_subscription or source == .grok_subscription or !sources.contains(source)) continue;
        count += 1;
    }
    return count;
}

fn gatewaySourceAtIndex(sources: SourceSet, wanted_index: usize) ?credentials.Source {
    var index: usize = 0;
    for (credential_source_order) |source| {
        if (source == .chatgpt_subscription or source == .grok_subscription or !sources.contains(source)) continue;
        if (index == wanted_index) return source;
        index += 1;
    }
    return null;
}

fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn makeTestCredential(
    alloc: Allocator,
    token: []const u8,
    source: credentials.Source,
    team_id: ?[]const u8,
    team_slug: ?[]const u8,
) !credentials.Credential {
    const owned_token = try alloc.dupe(u8, token);
    errdefer secret.zeroAndFree(alloc, owned_token);
    const owned_team_id = if (team_id) |team| try alloc.dupe(u8, team) else null;
    errdefer if (owned_team_id) |team| alloc.free(team);
    const owned_team_slug = if (team_slug) |team| try alloc.dupe(u8, team) else null;
    errdefer if (owned_team_slug) |team| alloc.free(team);
    return .{
        .token = owned_token,
        .source = source,
        .team_id = owned_team_id,
        .team_slug = owned_team_slug,
    };
}

const ApiKeySaveFixture = struct {
    validation: api_key_validator.Result = .accepted,
    fail_store: bool = false,
    fail_load: bool = false,
    /// Holds the worker inside `store` so a test can observe the in-flight
    /// window without racing it.
    gate: ?*std.atomic.Value(bool) = null,
    validate_calls: usize = 0,
    store_calls: usize = 0,
    load_calls: usize = 0,

    fn validate(raw_ctx: ?*anyopaque, _: Allocator, _: []const u8) api_key_validator.Result {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.validate_calls += 1;
        return self.validation;
    }

    fn validator(self: *@This()) api_key_validator.Provider {
        return .{
            .context = self,
            .validate_fn = validate,
        };
    }

    fn secretStore(self: *@This()) host.SecretStore {
        return .{
            .context = self,
            .backend_label = "test credential store",
            .is_disabled_fn = secretStoreIsDisabled,
            .load_fn = secretStoreLoad,
            .store_fn = secretStoreWrite,
            .store_interactive_fn = secretStoreInteractiveWrite,
        };
    }

    fn secretStoreIsDisabled(_: ?*anyopaque) bool {
        return false;
    }

    fn secretStoreLoad(
        raw_ctx: ?*anyopaque,
        alloc: Allocator,
    ) host.SecretStoreLoadError!?[]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.load_calls += 1;
        if (self.fail_load) return error.StoredKeyUnreadable;
        return try alloc.dupe(u8, "loaded-key");
    }

    fn secretStoreWrite(
        raw_ctx: ?*anyopaque,
        _: Allocator,
        _: []const u8,
    ) host.SecretStoreWriteError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        if (self.gate) |gate| while (!gate.load(.seq_cst)) {};
        self.store_calls += 1;
        if (self.fail_store) return error.StoredKeyWriteFailed;
    }

    fn secretStoreInteractiveWrite(
        _: ?*anyopaque,
    ) host.SecretStoreWriteError!bool {
        return false;
    }

    fn store(raw_ctx: ?*anyopaque, _: Allocator, _: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        if (self.gate) |gate| while (!gate.load(.seq_cst)) {};
        self.store_calls += 1;
        if (self.fail_store) return error.TestStoreFailed;
    }

    fn load(
        raw_ctx: ?*anyopaque,
        alloc: Allocator,
        source: credentials.Source,
    ) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
        self.load_calls += 1;
        if (self.fail_load) return error.TestLoadFailed;
        return try makeTestCredential(alloc, "loaded-key", source, null, null);
    }
};

const LogoutFixture = struct {
    existing: SourceSet,
    load_count: usize = 0,

    fn probe(ctx: ?*anyopaque, _: Allocator, source: credentials.Source) !bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        return self.existing.contains(source);
    }

    fn load(ctx: ?*anyopaque, alloc: Allocator, source: credentials.Source) !?credentials.Credential {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.load_count += 1;
        if (!self.existing.contains(source)) return null;
        return try makeTestCredential(alloc, @tagName(source), source, null, null);
    }
};
