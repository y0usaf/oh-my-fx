const std = @import("std");
const child_state = @import("child_state.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const session_summary_codec = @import("../session/session_summary_codec.zig");

const Allocator = std.mem.Allocator;
const max_page_limit: usize = 100;

pub const ActionableContinuation = struct {
    updated_at_ms: i64,
    id: []u8,

    pub fn deinit(self: *ActionableContinuation, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn view(self: ActionableContinuation) session_store.ResumableSessionContinuation {
        return .{ .updated_at_ms = self.updated_at_ms, .id = self.id };
    }
};

pub const ActionableSessionPage = struct {
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,
    has_more: bool = false,
    continuation: ?ActionableContinuation = null,

    pub fn deinit(self: *ActionableSessionPage, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        if (self.continuation) |*continuation| continuation.deinit(alloc);
        self.* = undefined;
    }
};

pub fn listVisiblePage(
    store: session_store.Store,
    alloc: Allocator,
    scope: session_store.SessionListScope,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.SessionListPage {
    if (limit == 0) return error.InvalidSessionListLimit;
    var result = session_store.SessionListPage{};
    errdefer result.deinit(alloc);
    var position: ?ActionableContinuation = if (continuation) |value| .{
        .updated_at_ms = value.updated_at_ms,
        .id = try alloc.dupe(u8, value.id),
    } else null;
    defer if (position) |*value| value.deinit(alloc);

    while (result.summaries.items.len < limit) {
        const next = if (position) |value| value.view() else null;
        var page = try store.listSessionPage(
            alloc,
            scope,
            next,
            limit - result.summaries.items.len,
        );
        defer page.deinit(alloc);
        result.skipped_invalid +|= page.skipped_invalid;
        if (page.summaries.items.len == 0) {
            result.has_more = false;
            break;
        }
        for (page.summaries.items) |summary| {
            if (position) |*value| value.deinit(alloc);
            position = .{
                .updated_at_ms = summary.updated_at_ms,
                .id = try alloc.dupe(u8, summary.id),
            };
            if (try isVisibleSession(store, alloc, summary.id)) {
                var cloned = try session_summary_codec.cloneSessionSummary(
                    alloc,
                    summary,
                );
                result.summaries.append(alloc, cloned) catch |err| {
                    cloned.deinit(alloc);
                    return err;
                };
            }
        }
        result.has_more = page.has_more;
        if (!page.has_more) break;
    }
    return result;
}

pub fn latestVisibleWorkspaceSummary(
    store: session_store.Store,
    alloc: Allocator,
) !session_store.SessionSummary {
    var page = try listVisiblePage(
        store,
        alloc,
        .current_workspace,
        null,
        1,
    );
    defer page.deinit(alloc);
    if (page.summaries.items.len == 0) {
        if (page.skipped_invalid > 0) return error.NoReadableSessions;
        return error.NoSavedSessions;
    }
    return session_summary_codec.cloneSessionSummary(
        alloc,
        page.summaries.items[0],
    );
}

pub fn loadVisibleReadOnlyDetail(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
    options: session_store.ResumeOptions,
) !session_store.ReadOnlyDetail {
    const managed = child_state.hasManagedChildMarker(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.InvalidSessionId => return err,
        else => return error.SessionNotFound,
    };
    if (managed) return error.SessionNotFound;

    var detail = try store.loadReadOnlyDetail(alloc, session_id, options);
    errdefer detail.deinit(alloc);
    if (detail.state.subagent_child) return error.SessionNotFound;
    return detail;
}

pub fn listActionablePage(
    store: session_store.Store,
    alloc: Allocator,
    scope: session_store.SessionListScope,
    active_id: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !ActionableSessionPage {
    return (try listActionablePageInternal(
        store,
        alloc,
        scope,
        active_id,
        continuation,
        limit,
        false,
    )).?;
}

pub fn tryListActionableIndexPage(
    store: session_store.Store,
    alloc: Allocator,
    scope: session_store.SessionListScope,
    active_id: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !?ActionableSessionPage {
    return listActionablePageInternal(
        store,
        alloc,
        scope,
        active_id,
        continuation,
        limit,
        true,
    );
}

fn listActionablePageInternal(
    store: session_store.Store,
    alloc: Allocator,
    scope: session_store.SessionListScope,
    active_id: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
    index_only: bool,
) !?ActionableSessionPage {
    if (limit == 0 or limit > max_page_limit) return error.InvalidSessionListLimit;

    var result: ActionableSessionPage = .{};
    errdefer result.deinit(alloc);
    var position: ?ActionableContinuation = if (continuation) |value| .{
        .updated_at_ms = value.updated_at_ms,
        .id = try alloc.dupe(u8, value.id),
    } else null;
    defer if (position) |*value| value.deinit(alloc);

    var scanned: usize = 0;
    while (result.summaries.items.len < limit and scanned < max_page_limit) {
        var scoped = store;
        scoped.resume_page_limit = @min(
            limit - result.summaries.items.len,
            max_page_limit - scanned,
        );
        const next = if (position) |value| value.view() else null;
        const maybe_page = if (index_only) switch (scope) {
            .current_workspace => try scoped.tryListResumableWorkspaceIndexPage(
                alloc,
                active_id,
                next,
            ),
            .all_workspaces => try scoped.tryListResumableIndexPage(
                alloc,
                active_id,
                next,
            ),
        } else switch (scope) {
            .current_workspace => try scoped.listResumableWorkspacePage(
                alloc,
                active_id,
                next,
            ),
            .all_workspaces => try scoped.listResumablePage(
                alloc,
                active_id,
                next,
            ),
        };
        var page = maybe_page orelse {
            result.deinit(alloc);
            return null;
        };
        defer page.deinit(alloc);
        result.has_more = page.has_more;
        if (page.summaries.items.len == 0) break;

        for (page.summaries.items) |summary| {
            scanned += 1;
            if (position) |*value| value.deinit(alloc);
            position = .{
                .updated_at_ms = summary.updated_at_ms,
                .id = try alloc.dupe(u8, summary.id),
            };
            const managed = child_state.isManagedChildSession(
                store,
                alloc,
                summary.id,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => true,
            };
            if (managed) continue;
            var cloned = try session_summary_codec.cloneSessionSummary(alloc, summary);
            result.summaries.append(alloc, cloned) catch |err| {
                cloned.deinit(alloc);
                return err;
            };
        }
        if (!page.has_more) break;
    }

    if (position) |value| {
        result.continuation = value;
        position = null;
    }
    return result;
}

pub fn resumeForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    target: session_store.ResumeTarget,
    workspace_root: []const u8,
    options: session_store.ResumeOptions,
) !session_store.LoadedWritableSession {
    switch (target) {
        .id => |session_id| try ensureExternalMarkerAllowed(store, alloc, session_id),
        .last => {},
    }
    var loaded = try store.resumeTargetForWrite(
        alloc,
        target,
        workspace_root,
        options,
    );
    errdefer loaded.deinit(alloc);
    try ensureExternalMarkerAllowed(store, alloc, loaded.active_id);
    try ensureLoadedExternalPromptAllowed(&loaded);
    return loaded;
}

pub fn admitResumeViewForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    target: session_store.ResumeTarget,
) !?session_store.ResumeViewAdmission {
    switch (target) {
        .id => |session_id| try ensureExternalMarkerAllowed(store, alloc, session_id),
        .last => {},
    }
    var admission = (try store.admitResumeView(alloc, target)) orelse return null;
    errdefer admission.deinit(alloc);
    try ensureExternalPromptAllowed(store, alloc, admission.sessionId());
    return admission;
}

pub fn resumeAdmittedForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    admission: *session_store.ResumeViewAdmission,
    session_id: []const u8,
    workspace_root: []const u8,
    options: session_store.ResumeOptions,
) !session_store.LoadedWritableSession {
    try ensureExternalMarkerAllowed(store, alloc, session_id);
    var loaded = try store.resumeAdmittedForWrite(
        alloc,
        admission,
        session_id,
        workspace_root,
        options,
    );
    errdefer loaded.deinit(alloc);
    try ensureLoadedExternalPromptAllowed(&loaded);
    return loaded;
}

/// Direct child prompts no longer exist. Parent-owned child execution resumes
/// child history internally, so an externally resumed ordinary session has no
/// subagent root-user evidence to retain.
pub fn retainExternalRootUserTurn(
    _: ?session_store.Store,
    _: Allocator,
    _: *session_store.LoadedWritableSession,
    _: session.HistoryTurn,
    _: bool,
) !void {}

fn ensureExternalPromptAllowed(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !void {
    const managed = child_state.isManagedChildSession(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SessionNotFound,
        error.SessionStoreUnavailable,
        => return,
        else => return err,
    };
    if (managed) return error.OneOffSessionNotResumable;
}

fn isVisibleSession(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !bool {
    return !(child_state.isManagedChildSession(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    });
}

fn ensureExternalMarkerAllowed(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !void {
    const managed = child_state.hasManagedChildMarker(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SessionNotFound, error.SessionStoreUnavailable => return,
        else => return err,
    };
    if (managed) return error.OneOffSessionNotResumable;
}

fn ensureLoadedExternalPromptAllowed(
    loaded: *const session_store.LoadedWritableSession,
) !void {
    if (loaded.state.subagent_child) return error.OneOffSessionNotResumable;
}

test "managed child marker is hidden from external access" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var durable = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "child"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = try alloc.alloc(session.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{
            .model = try alloc.dupe(u8, "test"),
            .effort = .auto,
            .fast_mode = false,
        },
    };
    defer durable.deinit(alloc);
    var writable = try store.startWritableSession(alloc, durable);
    writable.deinit(alloc);

    var visible = try loadVisibleReadOnlyDetail(store, alloc, "child", .{});
    visible.deinit(alloc);

    const state_store = child_state.Store{ .sessions = &store, .parent_id = "parent" };
    try state_store.markChildSession(alloc, "child");
    try std.testing.expectError(
        error.SessionNotFound,
        loadVisibleReadOnlyDetail(store, alloc, "child", .{}),
    );
    try std.testing.expectError(
        error.OneOffSessionNotResumable,
        resumeForExternalPrompt(store, alloc, .{ .id = "child" }, workspace, .{}),
    );
}

test "subagent work identity hides a partial child without owner sidecar" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var durable = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "partial-child"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = try alloc.alloc(session.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{
            .model = try alloc.dupe(u8, "test"),
            .effort = .auto,
            .fast_mode = false,
        },
        .last_subagent_work_id = try alloc.dupe(u8, "work-1"),
        .subagent_child = true,
    };
    defer durable.deinit(alloc);
    var writable = try store.startWritableSession(alloc, durable);
    writable.deinit(alloc);

    try std.testing.expectError(
        error.SessionNotFound,
        loadVisibleReadOnlyDetail(store, alloc, "partial-child", .{}),
    );
    try std.testing.expectError(
        error.OneOffSessionNotResumable,
        resumeForExternalPrompt(
            store,
            alloc,
            .{ .id = "partial-child" },
            workspace,
            .{},
        ),
    );
}
