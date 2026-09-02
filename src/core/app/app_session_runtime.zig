const std = @import("std");
const builtin = @import("builtin");
const question_answer = @import("../agent/question_answer.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const tool_admission = @import("../agent/runtime/tool_admission.zig");
const tool_presentation = @import("../agent/runtime/tool_presentation.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const host_capability = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const diff = @import("../output/diff.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const provider_runtime = @import("provider_runtime.zig");
const input_completion_runtime = @import("input_completion_runtime.zig");
const input_queue_runtime = @import("input_queue_runtime.zig");
const image_attachments = @import("../images/image_attachments.zig");
const core_input_runtime = @import("../input/runtime.zig");
const io_mod = @import("../shared/io.zig");
const list_window = @import("../shared/list_window.zig");
const text_utils = @import("../shared/text_utils.zig");
const session_runtime = @import("../session/session.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_codec = @import("../session/session_codec.zig");
const js_host_session_store = @import("../session/js_host_session_store.zig");
const session_event = @import("../session/session_event.zig");
const session_usage = @import("../session/session_usage.zig");
const session_child_store = @import("../session/session_child_store.zig");
const result_store = @import("../session/result_store.zig");
const command_replay_store = @import("../session/command_replay_store.zig");
const command_output_content = @import("../tooling/command_output_content.zig");
const captured_command = @import("../tooling/captured_command.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const session_log = @import("../session/session_log.zig");
const session_resume_view = @import("../session/session_resume_view.zig");
const session_store = @import("../session/session_store.zig");
const session_summary_codec = @import("../session/session_summary_codec.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_resume_admission = @import("../subagent/resume_admission.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const builtin_tools = @import("../../builtins/tools.zig");
const types = @import("../shared/types.zig");
const permissions = @import("../permissions/permissions.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const ui_input = @import("../../ui/input/runtime.zig");
const ui_render = @import("../../ui/render.zig");

const Allocator = std.mem.Allocator;

const BackgroundSessionPolicy = enum {
    carry_forward,
    stop_forget,
};

const LiveSessionTransitionEvent = union(enum) {
    request: BackgroundSessionPolicy,
    settle,
};

const LiveSessionTransitionAction = union(enum) {
    apply_now: BackgroundSessionPolicy,
    cancel_and_defer,
    apply_pending: BackgroundSessionPolicy,
    none,
};

const LiveSessionTransitionDecision = struct {
    pending_policy: ?BackgroundSessionPolicy,
    action: LiveSessionTransitionAction,
};

fn decideLiveSessionTransition(
    cooperative: bool,
    processing: bool,
    pending_policy: ?BackgroundSessionPolicy,
    event: LiveSessionTransitionEvent,
) LiveSessionTransitionDecision {
    return switch (event) {
        .request => |policy| if (!cooperative or !processing)
            .{
                .pending_policy = null,
                .action = .{ .apply_now = policy },
            }
        else if (pending_policy == null)
            .{
                .pending_policy = policy,
                .action = .cancel_and_defer,
            }
        else
            .{
                .pending_policy = policy,
                .action = .none,
            },
        .settle => if (processing)
            .{
                .pending_policy = pending_policy,
                .action = .none,
            }
        else if (pending_policy) |policy|
            .{
                .pending_policy = null,
                .action = .{ .apply_pending = policy },
            }
        else
            .{
                .pending_policy = null,
                .action = .none,
            },
    };
}


fn nextImageIdForResumedHistory(
    alloc: Allocator,
    history: []const types.HistoryTurn,
) !usize {
    const restored_catalog = try session_runtime.collect_image_catalog(
        alloc,
        history,
        &.{},
    );
    defer types.freeImageAttachmentSlice(alloc, restored_catalog);
    const bounds = try image_attachments.calculate_next_image_id(restored_catalog);
    return bounds.next_id;
}

pub const SessionPickerScope = session_catalog.Scope;

pub const HistoryAppendOutcome = enum {
    uncommitted,
    committed,
    committed_degraded,
};

pub const ResumeHandoffIntent = enum {
    none,
    requested,
    upgrade_requested,
};

const ResumeNotice = union(enum) {
    session,
    upgrade: []const u8,
};

pub const ResumeViewStage = union(enum) {
    none,
    ready: u32,
};

pub const ResumeHandoffState = struct {
    intent: ResumeHandoffIntent,
    has_writable_session: bool,
    is_pristine: bool,
    has_unresolved_degraded_tail: bool,
};

pub fn shouldCreateResumeHandoff(state: ResumeHandoffState) bool {
    return state.intent != .none and
        state.has_writable_session and
        (!state.is_pristine or state.intent == .upgrade_requested) and
        !state.has_unresolved_degraded_tail;
}


/// Owns `session_id`; callers must release it with `deinit`.
pub const ResumeHandoff = struct {
    session_id: []u8,

    pub fn deinit(self: *ResumeHandoff, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const SessionPreferencePatch = struct {
    provider: ?model_provider.ProviderId = null,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,

    pub fn userSettingsPatch(self: SessionPreferencePatch) config_runtime.UserSettingsPatch {
        var patch = config_runtime.UserSettingsPatch{
            .provider = self.provider,
            .effort = self.effort,
            .fast_mode = self.fast_mode,
        };
        if (self.model) |model| patch.model_preference = .{
            .provider = self.provider orelse .gateway,
            .model = model,
        };
        return patch;
    }
};

pub const PreferenceCommitResult = struct {
    settings_outcome: ?config_runtime.CommitOutcome = null,
    settings_error: ?anyerror = null,
    settings_failure_cleanup: config_runtime.LegacyCleanup = .{},
    session_error: ?anyerror = null,

    pub fn deinit(self: *PreferenceCommitResult, alloc: Allocator) void {
        if (self.settings_outcome) |*outcome| outcome.deinit(alloc);
        self.settings_failure_cleanup.deinit(alloc);
        self.* = undefined;
    }
};

pub const SessionPicker = struct {
    active: bool = false,
    load_state: session_catalog.LoadState = .loading,
    generation: u64 = 0,
    has_more: bool = false,
    loading_more: bool = false,
    summaries: std.ArrayList(session_store.SessionSummary) = .empty,
    continuation: ?subagent_resume_admission.ActionableContinuation = null,
    selected: usize = 0,
    window_start: usize = 0,
    scope: SessionPickerScope = .current_workspace,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,
    selection_failure: ?session_catalog.ResumeFailure = null,

    pub fn deinit(self: *SessionPicker, alloc: Allocator) void {
        for (self.summaries.items) |*summary| summary.deinit(alloc);
        self.summaries.deinit(alloc);
        if (self.continuation) |*continuation| continuation.deinit(alloc);
        self.* = .{};
    }

    fn appendSummary(
        self: *SessionPicker,
        alloc: Allocator,
        source: *const session_store.SessionSummary,
    ) !void {
        if (source.history_len == 0 and !source.has_managed_children) return;

        var summary = try session_summary_codec.cloneSessionSummary(alloc, source.*);
        errdefer summary.deinit(alloc);
        try self.summaries.append(alloc, summary);
    }

    pub fn selectedId(self: *const SessionPicker) ?[]const u8 {
        if (!self.active or self.load_state != .ready) return null;
        if (self.selected >= self.filteredItemCount()) return null;
        const summary = session_catalog.summaryAt(self.summaries.items, self.query(), self.selected) orelse return null;
        return summary.id;
    }

    fn isLoading(self: *const SessionPicker) bool {
        return self.active and self.load_state == .loading;
    }

    pub fn query(self: *const SessionPicker) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *SessionPicker, query_text: []const u8) void {
        const len = @min(query_text.len, self.query_buf.len);
        if (len > 0) std.mem.copyForwards(u8, self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
        self.selected = 0;
        self.window_start = 0;
        self.selection_failure = null;
    }

    pub fn filteredItemCount(self: *const SessionPicker) usize {
        return session_catalog.filteredCount(self.summaries.items, self.query());
    }

    pub fn navigationItemCount(self: *const SessionPicker) usize {
        return self.filteredItemCount() + @intFromBool(self.has_more);
    }

    fn isLoadMoreSelected(self: *const SessionPicker) bool {
        return self.active and self.load_state == .ready and self.has_more and
            self.selected == self.filteredItemCount();
    }

    fn moveVisibleItems(self: *SessionPicker, delta: i32, visible_items: u16) bool {
        if (!self.active or self.load_state != .ready) return false;
        self.selection_failure = null;
        const count = self.navigationItemCount();
        if (count == 0) return true;
        // Clamp at both ends instead of wrapping: at the top the selection
        // stays on the first session, at the bottom on the last row.
        const current: i32 = @intCast(self.selected % count);
        var next = current + delta;
        if (next < 0) next = 0;
        if (next >= @as(i32, @intCast(count))) next = @as(i32, @intCast(count)) - 1;
        self.selected = @intCast(next);
        self.syncWindowStart(visible_items);
        return true;
    }

    pub fn syncWindowStart(self: *SessionPicker, visible_items: u16) void {
        const session_count = self.filteredItemCount();
        const action_items: u16 = @intFromBool(self.has_more and visible_items > 0);
        const visible_sessions = visible_items -| action_items;
        if (session_count == 0 or visible_sessions == 0) {
            self.window_start = 0;
            return;
        }
        if (self.selected >= session_count) {
            self.window_start = session_count -| visible_sessions;
            return;
        }
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            session_count,
            self.selected,
            visible_sessions,
        );
    }

    fn appendPage(
        self: *SessionPicker,
        alloc: Allocator,
        summaries: []const session_store.SessionSummary,
    ) !void {
        const summary_len = self.summaries.items.len;
        errdefer {
            while (self.summaries.items.len > summary_len) {
                if (self.summaries.pop()) |summary_value| {
                    var summary = summary_value;
                    summary.deinit(alloc);
                }
            }
        }
        for (summaries) |*summary| try self.appendSummary(alloc, summary);
    }
};

const session_picker_cache_ttl_ns: i128 = 5 * std.time.ns_per_s;

const SessionPickerPageCache = struct {
    ready: bool = false,
    active_id: ?[]u8 = null,
    limit: usize = 0,
    loaded_at_ns: i128 = 0,
    page: subagent_resume_admission.ActionableSessionPage = .{},

    fn deinit(self: *SessionPickerPageCache) void {
        const alloc = std.heap.c_allocator;
        if (self.active_id) |id| alloc.free(id);
        self.page.deinit(alloc);
        self.* = .{};
    }

    fn matches(
        self: *const SessionPickerPageCache,
        active_id: ?[]const u8,
        limit: usize,
    ) bool {
        return self.ready and self.limit >= limit and optionalStringEql(self.active_id, active_id);
    }

    fn isFresh(self: *const SessionPickerPageCache, now_ns: i128) bool {
        return self.ready and now_ns >= self.loaded_at_ns and
            now_ns - self.loaded_at_ns <= session_picker_cache_ttl_ns;
    }

    fn install(
        self: *SessionPickerPageCache,
        source: *const subagent_resume_admission.ActionableSessionPage,
        active_id: ?[]const u8,
        limit: usize,
        loaded_at_ns: i128,
    ) !void {
        const alloc = std.heap.c_allocator;
        var owned_active_id = if (active_id) |id| try alloc.dupe(u8, id) else null;
        errdefer if (owned_active_id) |id| alloc.free(id);
        var owned_continuation: ?subagent_resume_admission.ActionableContinuation =
            if (source.continuation) |continuation| .{
                .updated_at_ms = continuation.updated_at_ms,
                .id = try alloc.dupe(u8, continuation.id),
            } else null;
        errdefer if (owned_continuation) |*continuation| continuation.deinit(alloc);
        var replacement: SessionPickerPageCache = .{
            .ready = true,
            .active_id = owned_active_id,
            .limit = limit,
            .loaded_at_ns = loaded_at_ns,
            .page = .{
                .has_more = source.has_more,
                .continuation = owned_continuation,
            },
        };
        owned_active_id = null;
        owned_continuation = null;
        errdefer replacement.deinit();
        for (source.summaries.items) |summary| {
            var copied = try session_summary_codec.cloneSessionSummary(alloc, summary);
            replacement.page.summaries.append(alloc, copied) catch |err| {
                copied.deinit(alloc);
                return err;
            };
        }
        self.deinit();
        self.* = replacement;
    }
};

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn sessionPickerCacheForScope(
    persistence: *Persistence,
    scope: SessionPickerScope,
) *SessionPickerPageCache {
    return switch (scope) {
        .current_workspace => &persistence.session_picker_current_cache,
        .all_workspaces => &persistence.session_picker_all_cache,
    };
}

fn replaceSessionPickerPage(
    picker: *SessionPicker,
    alloc: Allocator,
    source: *const subagent_resume_admission.ActionableSessionPage,
) !void {
    var replacement: std.ArrayList(session_store.SessionSummary) = .empty;
    errdefer {
        for (replacement.items) |*summary| summary.deinit(alloc);
        replacement.deinit(alloc);
    }
    for (source.summaries.items) |*summary| {
        if (summary.history_len == 0 and !summary.has_managed_children) continue;
        var copied = try session_summary_codec.cloneSessionSummary(alloc, summary.*);
        replacement.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    for (picker.summaries.items) |*summary| summary.deinit(alloc);
    picker.summaries.deinit(alloc);
    picker.summaries = replacement;
}

fn selectionAfterLoadedPage(
    previous_filtered_count: usize,
    filtered_count: usize,
    has_more: bool,
) usize {
    if (filtered_count > previous_filtered_count) return previous_filtered_count;
    if (has_more) return filtered_count;
    return filtered_count -| 1;
}

const SessionPickerLoad = struct {
    const Continuation = struct {
        updated_at_ms: i64,
        id: []u8,

        fn deinit(self: *Continuation) void {
            std.heap.c_allocator.free(self.id);
            self.* = undefined;
        }
    };

    const PageRequest = struct {
        generation: u64,
        scope: SessionPickerScope,
        active_id: ?[]u8 = null,
        continuation: ?Continuation = null,
        limit: usize = session_store.default_resume_page_limit,

        fn init(
            generation: u64,
            scope: SessionPickerScope,
            active_id: ?[]const u8,
            continuation: ?session_store.ResumableSessionContinuation,
            limit: usize,
        ) !PageRequest {
            const alloc = std.heap.c_allocator;
            var request: PageRequest = .{ .generation = generation, .scope = scope, .limit = limit };
            errdefer request.deinit();
            if (active_id) |id| request.active_id = try alloc.dupe(u8, id);
            if (continuation) |position| {
                request.continuation = .{
                    .updated_at_ms = position.updated_at_ms,
                    .id = try alloc.dupe(u8, position.id),
                };
            }
            return request;
        }

        fn deinit(self: *PageRequest) void {
            if (self.active_id) |id| std.heap.c_allocator.free(id);
            if (self.continuation) |*position| position.deinit();
            self.* = undefined;
        }

        fn continuationValue(self: *const PageRequest) ?session_store.ResumableSessionContinuation {
            const continuation = self.continuation orelse return null;
            return .{
                .updated_at_ms = continuation.updated_at_ms,
                .id = continuation.id,
            };
        }
    };

    const Task = struct {
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        home_dir: []u8,
        workspace_root: []u8,
        request: PageRequest,
        page: ?subagent_resume_admission.ActionableSessionPage = null,
        failure: ?anyerror = null,

        fn deinit(self: *Task) void {
            if (self.thread) |thread| thread.join();
            if (self.page) |*page| page.deinit(std.heap.c_allocator);
            self.request.deinit();
            std.heap.c_allocator.free(self.home_dir);
            std.heap.c_allocator.free(self.workspace_root);
            std.heap.c_allocator.destroy(self);
        }
    };

    task: ?*Task = null,
    pending: ?PageRequest = null,
    abandoned_generation: ?u64 = null,
    next_generation: u64 = 1,

    fn deinit(self: *SessionPickerLoad) void {
        if (self.task) |task| task.deinit();
        if (self.pending) |*pending| pending.deinit();
        self.* = .{};
    }

    fn allocateGeneration(self: *SessionPickerLoad) u64 {
        const generation = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return generation;
    }

    fn schedule(
        self: *SessionPickerLoad,
        store: *const session_store.Store,
        request: PageRequest,
    ) !void {
        if (self.task != null) {
            self.replacePending(request);
            return;
        }
        try self.start(store, request);
    }

    fn replacePending(self: *SessionPickerLoad, request: PageRequest) void {
        if (self.pending) |*pending| {
            debug_trace.logf(
                "core",
                "session picker request dropped reason=superseded generation={d}",
                .{pending.generation},
            );
            pending.deinit();
        }
        self.pending = request;
    }

    fn cancelGeneration(self: *SessionPickerLoad, generation: u64) void {
        if (self.task) |task| {
            if (task.request.generation == generation) {
                self.abandoned_generation = generation;
                debug_trace.logf(
                    "core",
                    "session picker request abandoned reason=cancelled generation={d}",
                    .{generation},
                );
            }
        }
        if (self.pending) |pending| {
            if (pending.generation == generation) {
                debug_trace.logf(
                    "core",
                    "session picker request dropped reason=cancelled generation={d}",
                    .{generation},
                );
                var owned = self.pending.?;
                self.pending = null;
                owned.deinit();
            }
        }
    }

    fn pendingGeneration(self: *const SessionPickerLoad) ?u64 {
        return if (self.pending) |request| request.generation else null;
    }

    fn matchingInitialGeneration(
        self: *const SessionPickerLoad,
        scope: SessionPickerScope,
        active_id: ?[]const u8,
        limit: usize,
    ) ?u64 {
        if (self.task) |task| {
            if (self.abandoned_generation != task.request.generation and
                initialRequestMatches(task.request, scope, active_id, limit))
            {
                return task.request.generation;
            }
        }
        if (self.pending) |request| {
            if (initialRequestMatches(request, scope, active_id, limit)) {
                return request.generation;
            }
        }
        return null;
    }

    fn initialRequestMatches(
        request: PageRequest,
        scope: SessionPickerScope,
        active_id: ?[]const u8,
        limit: usize,
    ) bool {
        return request.continuation == null and request.scope == scope and
            request.limit >= limit and optionalStringEql(request.active_id, active_id);
    }

    fn startPending(self: *SessionPickerLoad, store: *const session_store.Store) !?u64 {
        const request = self.pending orelse return null;
        self.pending = null;
        const generation = request.generation;
        try self.start(store, request);
        return generation;
    }

    fn start(
        self: *SessionPickerLoad,
        store: *const session_store.Store,
        request: PageRequest,
    ) !void {
        std.debug.assert(self.task == null);

        const alloc = std.heap.c_allocator;
        var owned_request = request;
        const home_dir = alloc.dupe(u8, store.home_dir) catch |err| {
            owned_request.deinit();
            return err;
        };
        const workspace_root = alloc.dupe(u8, store.workspace_root) catch |err| {
            alloc.free(home_dir);
            owned_request.deinit();
            return err;
        };
        const task = alloc.create(Task) catch |err| {
            alloc.free(workspace_root);
            alloc.free(home_dir);
            owned_request.deinit();
            return err;
        };
        task.* = .{
            .home_dir = home_dir,
            .workspace_root = workspace_root,
            .request = owned_request,
        };
        task.thread = std.Thread.spawn(.{}, threadMain, .{task}) catch |err| {
            task.request.deinit();
            alloc.free(task.workspace_root);
            alloc.free(task.home_dir);
            alloc.destroy(task);
            return err;
        };
        self.task = task;
    }

    fn takeCompleted(self: *SessionPickerLoad) ?*Task {
        const task = self.task orelse return null;
        if (!task.done.load(.acquire)) return null;
        self.task = null;
        if (self.abandoned_generation == task.request.generation) {
            self.abandoned_generation = null;
        }
        return task;
    }

    fn threadMain(task: *Task) void {
        var read_only = session_store.Store.initReadOnlyFromHome(
            std.heap.c_allocator,
            task.home_dir,
            task.workspace_root,
        ) catch |err| {
            task.failure = err;
            task.done.store(true, .release);
            return;
        };
        defer read_only.deinit(std.heap.c_allocator);

        if (tryListResumableIndexPageForScope(
            read_only,
            std.heap.c_allocator,
            task.request.scope,
            task.request.active_id,
            task.request.continuationValue(),
            task.request.limit,
        ) catch |err| {
            task.failure = err;
            task.done.store(true, .release);
            return;
        }) |page| {
            task.page = page;
            task.done.store(true, .release);
            return;
        }

        debug_trace.logf("core", "session picker cache outcome=miss action=backfill", .{});
        var writable = session_store.Store.initFromHome(
            std.heap.c_allocator,
            task.home_dir,
            task.workspace_root,
        ) catch |err| {
            debug_trace.logf(
                "core",
                "session picker cache backfill outcome=unavailable err={s}",
                .{@errorName(err)},
            );
            task.page = listResumablePageForScope(
                read_only,
                std.heap.c_allocator,
                task.request.scope,
                task.request.active_id,
                task.request.continuationValue(),
                task.request.limit,
            ) catch |fallback_err| {
                task.failure = fallback_err;
                task.done.store(true, .release);
                return;
            };
            task.done.store(true, .release);
            return;
        };
        defer writable.deinit(std.heap.c_allocator);

        task.page = listResumablePageForScope(
            writable,
            std.heap.c_allocator,
            task.request.scope,
            task.request.active_id,
            task.request.continuationValue(),
            task.request.limit,
        ) catch |err| {
            debug_trace.logf(
                "core",
                "session picker cache backfill outcome=failed err={s}",
                .{@errorName(err)},
            );
            task.page = listResumablePageForScope(
                read_only,
                std.heap.c_allocator,
                task.request.scope,
                task.request.active_id,
                task.request.continuationValue(),
                task.request.limit,
            ) catch |fallback_err| {
                task.failure = fallback_err;
                task.done.store(true, .release);
                return;
            };
            task.done.store(true, .release);
            return;
        };
        task.done.store(true, .release);
    }
};

fn resumePageLimitForRows(rows: u16) usize {
    // Fill the resume screen: terminal rows minus the composer/divider/hint
    // chrome (4), the menu header (1), the top gap (1), and a trailing
    // "Load more" row (1). Floored so short terminals still page usefully.
    return @max(@as(usize, rows -| 7), session_store.default_resume_page_limit);
}

fn tryListResumableIndexPageForScope(
    store: session_store.Store,
    alloc: Allocator,
    scope: SessionPickerScope,
    active_id: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !?subagent_resume_admission.ActionableSessionPage {
    return subagent_resume_admission.tryListActionableIndexPage(
        store,
        alloc,
        switch (scope) {
            .current_workspace => .current_workspace,
            .all_workspaces => .all_workspaces,
        },
        active_id,
        continuation,
        limit,
    );
}

fn listResumablePageForScope(
    store: session_store.Store,
    alloc: Allocator,
    scope: SessionPickerScope,
    active_id: ?[]const u8,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !subagent_resume_admission.ActionableSessionPage {
    return subagent_resume_admission.listActionablePage(
        store,
        alloc,
        switch (scope) {
            .current_workspace => .current_workspace,
            .all_workspaces => .all_workspaces,
        },
        active_id,
        continuation,
        limit,
    );
}

const JsHostSessionStore = struct {
    ctx: ?*anyopaque = null,
    load_fn: *const fn (?*anyopaque, Allocator, []const u8) anyerror!?js_host_session_store.Loaded = if (host_target.is_wasm) loadDefault else loadUnavailable,
    commit_fn: *const fn (?*anyopaque, Allocator, session_codec.DurableSessionState, ?[]const u8) anyerror![]u8 = if (host_target.is_wasm) commitDefault else commitUnavailable,
    list_fn: *const fn (?*anyopaque, Allocator) anyerror![]js_host_session_store.Metadata = if (host_target.is_wasm) listDefault else listUnavailable,

    fn load(self: JsHostSessionStore, alloc: Allocator, id: []const u8) !?js_host_session_store.Loaded {
        return self.load_fn(self.ctx, alloc, id);
    }

    fn commit(
        self: JsHostSessionStore,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        return self.commit_fn(self.ctx, alloc, state, expected_revision);
    }

    fn list(self: JsHostSessionStore, alloc: Allocator) ![]js_host_session_store.Metadata {
        return self.list_fn(self.ctx, alloc);
    }

    fn loadDefault(_: ?*anyopaque, alloc: Allocator, id: []const u8) !?js_host_session_store.Loaded {
        return js_host_session_store.load(alloc, id);
    }

    fn commitDefault(
        _: ?*anyopaque,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        return js_host_session_store.commit(alloc, state, expected_revision);
    }

    fn listDefault(_: ?*anyopaque, alloc: Allocator) ![]js_host_session_store.Metadata {
        return js_host_session_store.list(alloc);
    }

    fn loadUnavailable(_: ?*anyopaque, _: Allocator, _: []const u8) !?js_host_session_store.Loaded {
        return error.SessionStoreUnavailable;
    }

    fn commitUnavailable(
        _: ?*anyopaque,
        _: Allocator,
        _: session_codec.DurableSessionState,
        _: ?[]const u8,
    ) ![]u8 {
        return error.SessionStoreUnavailable;
    }

    fn listUnavailable(_: ?*anyopaque, _: Allocator) ![]js_host_session_store.Metadata {
        return error.SessionStoreUnavailable;
    }
};

const JsHostSessionOwner = struct {
    state: session_codec.DurableSessionState,
    revision: ?[]u8,

    fn deinit(self: *JsHostSessionOwner, alloc: Allocator) void {
        self.state.deinit(alloc);
        if (self.revision) |revision| alloc.free(revision);
        self.* = undefined;
    }
};

const PendingCancelledCommand = struct {
    lifecycle_id: types.ToolLifecycleId,
    command_artifact_handle: ?[]u8 = null,

    fn matches(self: PendingCancelledCommand, id: types.ToolLifecycleId) bool {
        return self.lifecycle_id.turn_id == id.turn_id and
            std.mem.eql(u8, self.lifecycle_id.call_id, id.call_id);
    }

    fn discard(self: *PendingCancelledCommand, alloc: Allocator) void {
        alloc.free(@constCast(self.lifecycle_id.call_id));
        if (self.command_artifact_handle) |handle| alloc.free(handle);
        self.* = undefined;
    }
};

pub const Persistence = struct {
    // Serializes event-log mutations with worker usage callbacks. Usage takes
    // its checkpoint mutex first, so callers must not checkpoint while held.
    write_mutex: std.Io.Mutex = .init,
    store: ?session_store.Store = null,
    writable: ?session_store.LoadedWritableSession = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    workspace_preferences: ?session_codec.DurableSessionPreferences = null,
    session_preferences: ?session_codec.DurableSessionPreferences = null,
    js_host_store: JsHostSessionStore = .{},
    js_host_session: ?JsHostSessionOwner = null,
    process_model_override: ?[]u8 = null,
    session_picker: SessionPicker = .{},
    session_picker_load: SessionPickerLoad = .{},
    session_picker_current_cache: SessionPickerPageCache = .{},
    session_picker_all_cache: SessionPickerPageCache = .{},
    degraded_warning_emitted: bool = false,
    pending_cancelled_command: ?PendingCancelledCommand = null,
    image_snapshot_temp_dir: ?[]u8 = null,
    resume_view_admission: ?session_store.ResumeViewAdmission = null,
    resume_handoff_intent: ResumeHandoffIntent = .none,
    pending_live_session_policy: ?BackgroundSessionPolicy = null,

    /// Fieldwise initialization avoids retaining undefined optional payloads
    /// in a static release-binary template.
    pub fn initInto(storage: *Persistence) void {
        comptime {
            if (std.meta.fields(Persistence).len != 19) {
                @compileError("update Persistence.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.write_mutex = .init;
        storage.store = null;
        storage.writable = null;
        storage.subagent_host = null;
        storage.workspace_preferences = null;
        storage.session_preferences = null;
        storage.js_host_store = .{};
        storage.js_host_session = null;
        storage.process_model_override = null;
        storage.session_picker = .{};
        storage.session_picker_load = .{};
        storage.session_picker_current_cache = .{};
        storage.session_picker_all_cache = .{};
        storage.degraded_warning_emitted = false;
        storage.pending_cancelled_command = null;
        storage.image_snapshot_temp_dir = null;
        storage.resume_view_admission = null;
        storage.resume_handoff_intent = .none;
        storage.pending_live_session_policy = null;
    }

    pub fn deinit(self: *Persistence, alloc: Allocator) void {
        if (self.pending_live_session_policy) |policy| {
            debug_trace.logf(
                "session",
                "event=live_session_transition_discard reason=deinit policy={s}",
                .{@tagName(policy)},
            );
        }
        if (self.pending_cancelled_command) |*pending| pending.discard(alloc);
        if (self.resume_view_admission) |*admission| admission.deinit(alloc);
        if (self.image_snapshot_temp_dir) |path| {
            image_attachments.cleanupSnapshotDir(path);
            alloc.free(path);
        }
        if (self.subagent_host) |host| host.deinit();
        if (self.writable) |*loaded| loaded.deinit(alloc);
        if (self.store) |*store| store.deinit(alloc);
        if (self.workspace_preferences) |*preferences| preferences.deinit(alloc);
        if (self.session_preferences) |*preferences| preferences.deinit(alloc);
        if (self.js_host_session) |*owner| owner.deinit(alloc);
        if (self.process_model_override) |model| alloc.free(model);
        self.session_picker.deinit(alloc);
        self.session_picker_load.deinit();
        self.session_picker_current_cache.deinit();
        self.session_picker_all_cache.deinit();
        self.* = undefined;
    }
};


pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn stageRequestedResumeView(app: *App) ResumeViewStage {
            const requested = app.requested_resume orelse return .none;
            const store = app.session_persistence.store orelse return .none;
            const target: session_store.ResumeTarget = switch (requested) {
                .pick => return .none,
                .last => .last,
                .id => |session_id| .{ .id = session_id },
            };
            var admission = (subagent_resume_admission.admitResumeViewForExternalPrompt(
                store,
                app.alloc,
                target,
            ) catch |err| {
                traceResumeViewUnavailable(err);
                return .none;
            }) orelse {
                debug_trace.logf("session", "event=resume_view_cache outcome=missing", .{});
                return .none;
            };
            var admission_owned = true;
            defer if (admission_owned) admission.deinit(app.alloc);
            var stage: ResumeViewStage = .none;
            switch (admission.view) {
                .missing, .invalid, .stale => debug_trace.logf(
                    "session",
                    "event=resume_view_cache outcome={s}",
                    .{@tagName(admission.view)},
                ),
                .exact, .older => |view| {
                    switch (requested) {
                        .last => app.requested_resume = .{ .id = app.alloc.dupe(u8, view.session_id) catch |err| {
                            traceResumeViewUnavailable(err);
                            return .none;
                        } },
                        .pick, .id => {},
                    }
                    const freshness = std.meta.activeTag(admission.view);
                    const paint_safe = freshness == .exact and view.capture.canPaintAt(
                        app.shell.layout.rows,
                        app.shell.layout.cols,
                    );
                    if (paint_safe) {
                        const entry_id = app.shell.appendRawTranscriptEntryClassified(
                            app.alloc,
                            view.text,
                            .unknown_raw,
                        ) catch |err| {
                            traceResumeViewUnavailable(err);
                            return .none;
                        };
                        stage = .{ .ready = entry_id };
                    }
                    app.session_persistence.resume_view_admission = admission;
                    admission_owned = false;
                    debug_trace.logf(
                        "session",
                        "event=resume_view_cache outcome={s} freshness={s} complete={} cached={d}x{d} terminal={d}x{d} bytes={d}",
                        .{
                            if (paint_safe) "painted" else "skipped",
                            @tagName(freshness),
                            view.capture.complete,
                            view.capture.terminal_cols,
                            view.capture.terminal_rows,
                            app.shell.layout.cols,
                            app.shell.layout.rows,
                            view.text.len,
                        },
                    );
                },
            }
            return stage;
        }

        pub fn publishStagedResumeView(app: *App, entry_id: u32) !void {
            app.commitStartupResumeReplayAnchor() catch |err| {
                traceResumeViewUnavailable(err);
            };
            _ = try app.shell.releaseStartupResumeViewEntry(
                app.alloc,
                entry_id,
            );
        }

        fn traceResumeViewUnavailable(err: anyerror) void {
            debug_trace.logf(
                "session",
                "event=resume_view_cache outcome=unavailable err={s}",
                .{@errorName(err)},
            );
        }

        pub fn persistResumeViewAfterFrame(app: *App) void {
            if (app.stream.active) return;
            if (comptime @hasField(App, "terminal")) {
                if (app.terminal.alternate_screen_owner != .none) return;
            }
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value| value else return;
            if (!loaded.resume_view_stale) return;
            var snapshot = app.shell.snapshotVisibleTranscriptText(
                app.alloc,
                session_resume_view.max_text_bytes,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=resume_view_cache outcome=capture_failed err={s}",
                    .{@errorName(err)},
                );
                return;
            } orelse return;
            defer snapshot.deinit(app.alloc);
            loaded.writeResumeView(app.alloc, .{
                .terminal_rows = snapshot.terminal_rows,
                .terminal_cols = snapshot.terminal_cols,
                .complete = snapshot.complete,
            }, snapshot.text) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=resume_view_cache outcome=write_failed err={s}",
                    .{@errorName(err)},
                );
                return;
            };
            loaded.resume_view_stale = false;
            debug_trace.logf(
                "session",
                "event=resume_view_cache outcome=stored complete={} terminal={d}x{d} bytes={d}",
                .{ snapshot.complete, snapshot.terminal_cols, snapshot.terminal_rows, snapshot.text.len },
            );
        }

        pub fn captureImageAttachment(
            app: *App,
            attachment: *types.ImageAttachment,
        ) !void {
            const snapshot_dir = try imageSnapshotStorageDir(app);
            defer app.alloc.free(snapshot_dir);
            try image_attachments.captureImageSnapshot(
                app.alloc,
                attachment,
                snapshot_dir,
            );
        }

        fn imageSnapshotStorageDir(app: *App) ![]u8 {
            const sessions_dir = if (app.session_persistence.store) |*store|
                store.sessions_dir
            else
                null;
            const session_id = if (app.session_persistence.writable) |*writable|
                writable.active_id
            else
                null;
            return session_store.imageSnapshotStorageDir(
                app.alloc,
                sessions_dir,
                session_id,
                &app.session_persistence.image_snapshot_temp_dir,
            );
        }

        pub fn configureStartupPreferences(
            app: *App,
            provider: model_provider.ProviderId,
            configured_model: []const u8,
            model_source: config_runtime.ModelSource,
            selected_model: []const u8,
            effort: types.ReasoningEffort,
            fast_mode: bool,
        ) !void {
            try replacePreferences(
                app.alloc,
                &app.session_persistence.workspace_preferences,
                .{
                    .provider = provider,
                    .model = @constCast(configured_model),
                    .effort = effort,
                    .fast_mode = fast_mode,
                },
            );
            try replacePreferences(
                app.alloc,
                &app.session_persistence.session_preferences,
                app.session_persistence.workspace_preferences.?,
            );
            if (app.session_persistence.process_model_override) |model| {
                app.alloc.free(model);
                app.session_persistence.process_model_override = null;
            }
            if (model_source == .process_override) {
                app.session_persistence.process_model_override =
                    try app.alloc.dupe(u8, selected_model);
            }
        }

        pub fn initializePersistence(
            app: *App,
            required: bool,
        ) !void {
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return;
            var store = session_store.Store.init(
                app.alloc,
                app.workspace_root,
            ) catch |err| {
                if (required) return err;
                return;
            };
            errdefer store.deinit(app.alloc);

            app.session_persistence.store = store;
        }

        pub fn enableSessionStores(app: *App) void {
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return;
            const loaded = if (app.session_persistence.writable) |*value| value else return;
            const capability = loaded.childCapability() catch |err| {
                debug_trace.logf(
                    "session",
                    "interactive child capability unavailable session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
                return;
            };

            configureWebFetchArtifacts(app, loaded);
            enableSubagentHost(app, loaded);
            restoreManagedBackground(app, loaded, capability);
        }

        fn restoreManagedBackground(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            capability: *session_child_store.SessionChildCapability,
        ) void {
            if (comptime @hasDecl(
                @TypeOf(app.background),
                "restoreFromManagedPersistence",
            )) {
                app.background.restoreFromManagedPersistence(
                    std.heap.c_allocator,
                    capability,
                    loaded.active_id,
                    app.workspace_root,
                ) catch |err| {
                    debug_trace.logf(
                        "background",
                        "interactive managed background restore failed session={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    );
                };
            }
        }

        pub fn beginFreshPersistedSession(app: *App) !void {
            closeWritableSession(app, .{});
            if (comptime runtime_profile.allows(App, .js_host_sessions)) {
                try beginFreshJsHostSession(app);
            }
            if (comptime !runtime_profile.allows(App, .durable_sessions)) return;
            const store = app.session_persistence.store orelse return;
            const preferences = app.session_persistence.workspace_preferences orelse
                return error.SessionPreferencesUnavailable;
            try replacePreferences(
                app.alloc,
                &app.session_persistence.session_preferences,
                preferences,
            );

            var state = try freshState(app, preferences);
            defer state.deinit(app.alloc);
            app.session_persistence.writable = store.startWritableSession(
                app.alloc,
                state,
            ) catch |err| {
                try warnNonDurable(app, "session creation failed", err);
                return;
            };
            app.session_persistence.degraded_warning_emitted = false;
            app.total_input_tokens = 0;
            app.total_output_tokens = 0;
            app.total_web_search_requests = 0;
        }

        fn beginFreshJsHostSession(app: *App) !void {
            const preferences = app.session_persistence.workspace_preferences orelse
                return error.SessionPreferencesUnavailable;
            try replacePreferences(
                app.alloc,
                &app.session_persistence.session_preferences,
                preferences,
            );
            var state = try freshState(app, preferences);
            errdefer state.deinit(app.alloc);
            if (app.session_persistence.js_host_session) |*owner| owner.deinit(app.alloc);
            app.session_persistence.js_host_session = .{
                .state = state,
                .revision = null,
            };
            state = undefined;
            app.total_input_tokens = 0;
            app.total_output_tokens = 0;
            app.total_web_search_requests = 0;
        }

        pub fn clearSession(app: *App) !void {
            try resetSessionWithBackgroundPolicy(app, .carry_forward);
        }

        pub fn newSession(app: *App) !void {
            try resetSessionWithBackgroundPolicy(app, .carry_forward);
        }

        pub fn resetSession(app: *App) !void {
            try resetSessionWithBackgroundPolicy(app, .stop_forget);
        }

        fn resetSessionWithBackgroundPolicy(
            app: *App,
            background_policy: BackgroundSessionPolicy,
        ) !void {
            const previous_policy = app.session_persistence.pending_live_session_policy;
            const decision = decideLiveSessionTransition(
                runtime_profile.allows(App, .cooperative_agent),
                app.worker.isProcessing(),
                previous_policy,
                .{ .request = background_policy },
            );
            if (previous_policy) |previous| {
                if (decision.pending_policy) |next| {
                    if (previous != next) {
                        debug_trace.logf(
                            "session",
                            "event=live_session_transition_coalesced previous={s} next={s}",
                            .{ @tagName(previous), @tagName(next) },
                        );
                    }
                }
            }
            app.session_persistence.pending_live_session_policy = decision.pending_policy;
            switch (decision.action) {
                .apply_now => |policy| try applyLiveSessionTransition(app, policy),
                .cancel_and_defer => beginLiveSessionCancellation(app),
                .none => {},
                .apply_pending => unreachable,
            }
        }

        pub fn settlePendingLiveSessionTransition(app: *App) !void {
            const decision = decideLiveSessionTransition(
                runtime_profile.allows(App, .cooperative_agent),
                app.worker.isProcessing(),
                app.session_persistence.pending_live_session_policy,
                .settle,
            );
            app.session_persistence.pending_live_session_policy = decision.pending_policy;
            switch (decision.action) {
                .apply_pending => |policy| {
                    applyIdleLiveSessionTransition(app, policy, .{});
                    try installFreshLiveSession(app);
                },
                .none => {},
                .apply_now, .cancel_and_defer => unreachable,
            }
        }

        fn applyLiveSessionTransition(
            app: *App,
            background_policy: BackgroundSessionPolicy,
        ) !void {
            try prepareLiveSessionTransition(app, background_policy, .{});
            try installFreshLiveSession(app);
        }

        fn installFreshLiveSession(app: *App) !void {
            try beginFreshPersistedSession(app);
            enableSessionStores(app);
            refreshSubagentProjectionAfterSessionInstall(app);
            try finishLiveSessionTransition(app);
        }

        pub fn prepareLiveSessionResume(
            app: *App,
            log_options: session_log.Options,
        ) !void {
            try prepareLiveSessionTransition(app, .stop_forget, log_options);
        }

        pub fn finishLiveSessionResume(app: *App) !void {
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.footer);
        }

        fn prepareLiveSessionTransition(
            app: *App,
            background_policy: BackgroundSessionPolicy,
            log_options: session_log.Options,
        ) !void {
            beginLiveSessionCancellation(app);
            app.worker.waitUntilIdle();
            applyIdleLiveSessionTransition(app, background_policy, log_options);
        }

        fn beginLiveSessionCancellation(app: *App) void {
            app.worker.requestCancel();
            app.pacer.clear(app.alloc);
            if (comptime @hasField(App, "queued_prompt_review")) {
                input_queue_runtime.Runtime(App).reset(app);
            }
            if (comptime @hasDecl(App, "clearPendingSubmissionForSessionTransition")) {
                App.clearPendingSubmissionForSessionTransition(app);
            } else {
                if (comptime @hasDecl(App, "clearPendingSubmission")) {
                    App.clearPendingSubmission(app, "session_transition");
                }
                app.worker.clearQueuedPrompts(std.heap.c_allocator, &.{});
            }
        }

        fn applyIdleLiveSessionTransition(
            app: *App,
            background_policy: BackgroundSessionPolicy,
            log_options: session_log.Options,
        ) void {
            clearCachedSessionTitle(app);
            app.worker.discardEvents(std.heap.c_allocator);

            if (comptime @hasField(App, "subagents") and
                @hasDecl(@TypeOf(app.subagents), "clearProjection"))
            {
                app.subagents.clearProjection(app.alloc);
            }

            closeWritableSession(app, log_options);
            app.stopStream();
            app.shell.clearTranscript(app.alloc);
            app.session.reset(app.alloc);
            app.input_runtime.inputResetState().resetForSession(app.alloc);
            app.terminal_input_runtime.resetEscapeDecoder();
            app.permission_engine.clear(app.alloc);
            app.clearPendingImages();
            app.change_tracker.clear(std.heap.c_allocator);
            diagnostics.resetSession();
            switch (background_policy) {
                .carry_forward => app.background.carryForwardWorkspaceState(
                    std.heap.c_allocator,
                    app.workspace_root,
                ),
                .stop_forget => app.background.stopAndForgetWorkspace(
                    std.heap.c_allocator,
                    app.workspace_root,
                ),
            }
            app.context_snapshot.deinit(app.alloc);
            app.approval_prompt.clear(app.alloc);
            if (comptime @hasField(App, "approval_screen")) {
                app.approval_screen.clear();
            }
            app.question_prompt.discard(app.alloc, "session_reset");
            cancelSessionPicker(app);
            invalidateSessionPickerCaches(app);
        }

        fn finishLiveSessionTransition(app: *App) !void {
            const welcome = try ui_render.welcomeMessage(app.alloc);
            defer app.alloc.free(welcome);
            try app.writeTranscriptClassified(welcome, true, .welcome);
            app.shell.render_requests.request(.footer);
            try shell_runtime.requestRedraw(&app.shell, &app.metrics, .replay_viewport);
        }

        pub fn resumeRequestedSession(app: *App) !void {
            return resumeRequestedSessionWithNotice(app, .session);
        }

        pub fn resumeRequestedSessionAfterUpgrade(
            app: *App,
            version: []const u8,
        ) !void {
            return resumeRequestedSessionWithNotice(app, .{ .upgrade = version });
        }

        fn resumeRequestedSessionWithNotice(
            app: *App,
            notice: ResumeNotice,
        ) !void {
            if (comptime runtime_profile.allows(App, .js_host_sessions) and
                !runtime_profile.allows(App, .durable_sessions))
            {
                return resumeRequestedJsHostSessionWithNotice(app, notice);
            }
            var target = app.requested_resume orelse return;
            app.requested_resume = null;
            defer target.deinit(app.alloc);

            const resume_target: session_store.ResumeTarget = switch (target) {
                // Nothing to load yet: the picker asks which session to open.
                .pick => return openSessionPicker(app),
                .last => .last,
                .id => |session_id| .{ .id = session_id },
            };
            var loaded = if (app.session_persistence.resume_view_admission) |saved| admitted: {
                var admission = saved;
                app.session_persistence.resume_view_admission = null;
                defer admission.deinit(app.alloc);
                const session_id = switch (resume_target) {
                    .id => |id| id,
                    .last => return error.SessionTargetChanged,
                };
                const store = app.session_persistence.store orelse
                    return error.SessionStoreUnavailable;
                break :admitted try subagent_resume_admission.resumeAdmittedForExternalPrompt(
                    store,
                    app.alloc,
                    &admission,
                    session_id,
                    app.workspace_root,
                    .{ .seed_preferences = app.session_persistence.workspace_preferences },
                );
            } else try loadResumeTargetForWrite(app, resume_target, .{});
            var loaded_owned = true;
            errdefer if (loaded_owned) loaded.deinit(app.alloc);

            loaded_owned = false;
            try installResumedSession(app, &loaded, notice);
            errdefer closeWritableSession(app, .{});
            try app.commitStartupResumeReplayAnchor();
        }

        fn resumeRequestedJsHostSession(app: *App) !void {
            return resumeRequestedJsHostSessionWithNotice(app, .session);
        }

        fn resumeRequestedJsHostSessionWithNotice(
            app: *App,
            notice: ResumeNotice,
        ) !void {
            var target = app.requested_resume orelse return;
            app.requested_resume = null;
            defer target.deinit(app.alloc);

            if (target == .pick) {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_restore outcome=dropped reason=picker_unsupported",
                    .{},
                );
                try continueWithFreshJsHostSession(app);
                try app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .neutral,
                    .body = "session picker is unavailable in this host; use --resume last or a session ID",
                }, true);
                return;
            }

            var listed: ?[]js_host_session_store.Metadata = null;
            defer if (listed) |entries| {
                for (entries) |*entry| entry.deinit(app.alloc);
                app.alloc.free(entries);
            };
            const session_id = switch (target) {
                .pick => unreachable,
                .id => |id| id,
                .last => latest: {
                    const entries = app.session_persistence.js_host_store.list(app.alloc) catch |err| {
                        traceJsHostRestoreFailure("list", null, err);
                        try continueWithFreshJsHostSession(app);
                        return;
                    };
                    listed = entries;
                    if (entries.len == 0) {
                        debug_trace.logf(
                            "session",
                            "event=js_host_session_restore outcome=dropped reason=missing_record target=last",
                            .{},
                        );
                        try continueWithFreshJsHostSession(app);
                        return;
                    }
                    var latest_index: usize = 0;
                    for (entries[1..], 1..) |entry, index| {
                        if (entry.updated_at_ms > entries[latest_index].updated_at_ms) {
                            latest_index = index;
                        }
                    }
                    break :latest entries[latest_index].id;
                },
            };

            var loaded = (app.session_persistence.js_host_store.load(app.alloc, session_id) catch |err| {
                traceJsHostRestoreFailure(jsHostLoadFailureStage(err), session_id, err);
                try continueWithFreshJsHostSession(app);
                return;
            }) orelse {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_restore outcome=dropped reason=missing_record id={s}",
                    .{session_id},
                );
                try continueWithFreshJsHostSession(app);
                return;
            };
            var loaded_owned = true;
            defer if (loaded_owned) loaded.deinit(app.alloc);

            var display = session_display_metadata.deriveFromHistory(
                app.alloc,
                loaded.state.history,
            ) catch |err| {
                traceJsHostRestoreFailure("display", session_id, err);
                try continueWithFreshJsHostSession(app);
                return;
            };
            defer display.deinit(app.alloc);
            hydrateResumedSession(app, loaded.state, display.title, notice) catch |err| {
                traceJsHostRestoreFailure("hydrate", session_id, err);
                try continueWithFreshJsHostSession(app);
                return;
            };

            if (app.session_persistence.js_host_session) |*owner| owner.deinit(app.alloc);
            app.session_persistence.js_host_session = .{
                .state = loaded.state,
                .revision = loaded.revision,
            };
            loaded_owned = false;
            loaded = undefined;
            try app.commitStartupResumeReplayAnchor();
        }

        fn continueWithFreshJsHostSession(app: *App) !void {
            app.session.reset(app.alloc);
            app.shell.clearTranscript(app.alloc);
            clearCachedSessionTitle(app);
            try beginFreshJsHostSession(app);
            try finishLiveSessionTransition(app);
        }

        fn jsHostLoadFailureStage(err: anyerror) []const u8 {
            return switch (err) {
                error.InvalidDurableField,
                error.InvalidDurableBytes,
                error.InvalidSessionFormat,
                error.InvalidSessionId,
                => "decode",
                else => "load",
            };
        }

        fn traceJsHostRestoreFailure(stage: []const u8, id: ?[]const u8, err: anyerror) void {
            if (id) |session_id| {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_restore outcome=dropped stage={s} id={s} err={s}",
                    .{ stage, session_id, @errorName(err) },
                );
            } else {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_restore outcome=dropped stage={s} err={s}",
                    .{ stage, @errorName(err) },
                );
            }
        }

        pub fn startResumedSessionReconciliation(app: *App) void {
            if (comptime !@hasField(App, "auth") or !provider_runtime.supported(App)) return;
            if (comptime !@hasDecl(@TypeOf(app.auth), "credentialSource") or
                !@hasDecl(@TypeOf(app.auth), "accountId") or
                !@hasDecl(@TypeOf(app.session.usage), "replaceProviderReconciliationCredential")) return;

            const source = app.auth.credentialSource() orelse return;
            const credential = app.auth.apiKey() orelse return;
            app.session.usage.replaceProviderReconciliationCredential(
                app.alloc,
                provider_runtime.provider(app),
                source,
                app.auth.accountId(),
                credential,
            );
        }

        pub fn resumeSelectedSession(app: *App) !bool {
            const selected_id = app.session_persistence.session_picker.selectedId() orelse return false;
            const log_options = session_log.Options{
                .session_lock_deadline_ms = 0,
                .commit_lock_deadline_ms = 0,
            };
            var loaded = try loadResumeTargetForWrite(
                app,
                .{ .id = selected_id },
                log_options,
            );
            var loaded_owned = true;
            errdefer if (loaded_owned) loaded.deinit(app.alloc);

            try app.prepareLiveSessionResume(log_options);
            loaded_owned = false;
            try installResumedSession(app, &loaded, .session);
            requestSubagentBackgroundRecovery(app);
            startResumedSessionReconciliation(app);
            try app.finishLiveSessionResume();
            return true;
        }

        fn loadResumeTargetForWrite(
            app: *App,
            target: session_store.ResumeTarget,
            log_options: session_log.Options,
        ) !session_store.LoadedWritableSession {
            const store = app.session_persistence.store orelse
                return session_log.failLoadedWritableSession(error.SessionStoreUnavailable);
            return subagent_resume_admission.resumeForExternalPrompt(
                store,
                app.alloc,
                target,
                app.workspace_root,
                .{
                    .seed_preferences = app.session_persistence.workspace_preferences,
                    .log = log_options,
                },
            );
        }

        fn installResumedSession(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            notice: ResumeNotice,
        ) !void {
            var loaded_owned = true;
            errdefer if (loaded_owned) loaded.deinit(app.alloc);

            var display = try readNativeResumeDisplay(app, loaded);
            defer display.deinit(app.alloc);

            closeWritableSession(app, .{});
            app.session_persistence.writable = loaded.*;
            loaded_owned = false;
            loaded.* = undefined;
            errdefer {
                app.session_persistence.writable.?.deinit(app.alloc);
                app.session_persistence.writable = null;
            }
            const active = &app.session_persistence.writable.?;
            try hydrateResumedSession(app, active.state, display.title, notice);
            active.resume_view_stale = true;
            enableSessionStores(app);
            refreshSubagentProjectionAfterSessionInstall(app);
        }

        fn hydrateResumedSession(
            app: *App,
            state: session_codec.DurableSessionState,
            display_title: []const u8,
            notice: ResumeNotice,
        ) !void {
            if (comptime @hasField(App, "next_image_id")) {
                app.next_image_id = try nextImageIdForResumedHistory(
                    app.alloc,
                    state.history,
                );
            }
            try app.session.restoreWithPermissionState(
                app.alloc,
                state.conversation_language,
                state.history,
                state.context_history_start,
                state.permission_state,
            );
            if (state.usage) |usage| {
                try app.session.usage.restore(
                    app.alloc,
                    usage,
                    state.created_at_ms,
                );
            } else {
                app.session.usage.restoreLegacyWallDuration(state.created_at_ms);
            }
            try replacePreferences(
                app.alloc,
                &app.session_persistence.session_preferences,
                state.preferences,
            );
            try restoreRuntimePreferences(app, state.preferences);

            app.total_input_tokens = state.total_input_tokens;
            app.total_output_tokens = state.total_output_tokens;
            app.total_web_search_requests = 0;

            if (comptime @hasDecl(App, "beginResumeProjection")) {
                const projection_started_ns = io_mod.nanoTimestamp();
                var projection = try app.beginResumeProjection();
                defer projection.deinit();
                var sink = DetachedHistorySink(@TypeOf(projection)){
                    .app = app,
                    .projection = &projection,
                };
                try writeResumeNotice(app, &sink, display_title, notice);
                try replayHistoryToSink(app, &sink, state.history);
                try writeRecoveryCheckpointToSink(app, &sink, state);
                const projection_finished_ns = io_mod.nanoTimestamp();
                try projection.finalize();
                const finalization_finished_ns = io_mod.nanoTimestamp();
                try app.installResumeProjection(&projection);
                const install_finished_ns = io_mod.nanoTimestamp();
                debug_trace.logf(
                    "session",
                    "event=resume_projection turns={d} project_us={d} finalize_us={d} install_us={d}",
                    .{
                        state.history.len,
                        @divTrunc(projection_finished_ns - projection_started_ns, std.time.ns_per_us),
                        @divTrunc(finalization_finished_ns - projection_finished_ns, std.time.ns_per_us),
                        @divTrunc(install_finished_ns - finalization_finished_ns, std.time.ns_per_us),
                    },
                );
            } else {
                var sink = LiveHistorySink(App){ .app = app };
                try writeResumeNotice(app, &sink, display_title, notice);
                try replayHistoryToSink(app, &sink, state.history);
                try writeRecoveryCheckpointToSink(app, &sink, state);
            }
        }

        fn refreshSubagentProjectionAfterSessionInstall(app: *App) void {
            if (comptime !@hasDecl(App, "refreshSubagentManagerProjectionNow")) return;
            app.refreshSubagentManagerProjectionNow() catch |err| {
                debug_trace.logf(
                    "subagent",
                    "session projection refresh unavailable err={s}",
                    .{@errorName(err)},
                );
            };
        }

        pub fn openSessionPicker(app: *App) !void {
            return openSessionPickerWithScope(app, .current_workspace);
        }

        pub fn openAllSessionPicker(app: *App) !void {
            return openSessionPickerWithScope(app, .all_workspaces);
        }

        fn openSessionPickerWithScope(app: *App, scope: SessionPickerScope) !void {
            if (app.stream.active) {
                try app.writeDomainNotice(.{
                    .topic = "session",
                    .tone = .neutral,
                    .body = "resume is unavailable until the response finishes",
                }, true);
                return;
            }

            var picker = &app.session_persistence.session_picker;
            if (picker.load_state != .ready) {
                app.session_persistence.session_picker_load.cancelGeneration(picker.generation);
            }
            picker.deinit(app.alloc);
            picker.active = true;
            picker.load_state = .loading;
            picker.scope = scope;
            picker.setQuery(app.input_runtime.edit_state.input.items);
            const store = if (app.session_persistence.store) |*value|
                value
            else {
                picker.load_state = .failed;
                try writeSessionPickerError(app, error.SessionStoreUnavailable);
                app.shell.render_requests.request(.footer);
                return;
            };
            const active_id = if (app.session_persistence.writable) |*loaded|
                loaded.active_id
            else
                null;
            const limit = if (comptime @hasField(App, "shell"))
                resumePageLimitForRows(app.shell.layout.rows)
            else
                session_store.default_resume_page_limit;
            const cache = sessionPickerCacheForScope(&app.session_persistence, scope);
            var cache_visible = false;
            const now_ns = io_mod.nanoTimestamp();
            if (cache.matches(active_id, limit)) {
                try replaceSessionPickerPage(picker, app.alloc, &cache.page);
                const continuation: ?subagent_resume_admission.ActionableContinuation =
                    if (cache.page.continuation) |value| .{
                        .updated_at_ms = value.updated_at_ms,
                        .id = try app.alloc.dupe(u8, value.id),
                    } else null;
                if (picker.continuation) |*prior| prior.deinit(app.alloc);
                picker.continuation = continuation;
                picker.has_more = cache.page.has_more;
                picker.load_state = .ready;
                cache_visible = true;
                if (cache.isFresh(now_ns)) {
                    picker.generation = app.session_persistence.session_picker_load.allocateGeneration();
                    return;
                }
            }

            const loader = &app.session_persistence.session_picker_load;
            if (loader.matchingInitialGeneration(scope, active_id, limit)) |generation| {
                picker.generation = generation;
                return;
            }
            const request = SessionPickerLoad.PageRequest.init(
                loader.allocateGeneration(),
                picker.scope,
                active_id,
                null,
                limit,
            ) catch |err| {
                if (!cache_visible) picker.load_state = .failed;
                try writeSessionPickerError(app, err);
                return;
            };
            picker.generation = request.generation;
            loader.schedule(store, request) catch |err| {
                if (!cache_visible) picker.load_state = .failed;
                try writeSessionPickerError(app, err);
                return;
            };
        }

        pub fn primeSessionPicker(app: *App) void {
            const store = if (app.session_persistence.store) |*value| value else return;
            const active_id = if (app.session_persistence.writable) |*loaded|
                loaded.active_id
            else
                null;
            const limit = if (comptime @hasField(App, "shell"))
                resumePageLimitForRows(app.shell.layout.rows)
            else
                session_store.default_resume_page_limit;
            const loader = &app.session_persistence.session_picker_load;
            for ([_]SessionPickerScope{ .current_workspace, .all_workspaces }) |scope| {
                const cache = sessionPickerCacheForScope(&app.session_persistence, scope);
                if (cache.matches(active_id, limit) and cache.isFresh(io_mod.nanoTimestamp())) continue;
                if (loader.matchingInitialGeneration(scope, active_id, limit) != null) continue;
                const request = SessionPickerLoad.PageRequest.init(
                    loader.allocateGeneration(),
                    scope,
                    active_id,
                    null,
                    limit,
                ) catch |err| {
                    debug_trace.logf(
                        "core",
                        "session picker prewarm unavailable scope={s} err={s}",
                        .{ @tagName(scope), @errorName(err) },
                    );
                    continue;
                };
                loader.schedule(store, request) catch |err| {
                    debug_trace.logf(
                        "core",
                        "session picker prewarm unavailable scope={s} err={s}",
                        .{ @tagName(scope), @errorName(err) },
                    );
                };
            }
        }

        pub fn toggleSessionPickerScope(app: *App) !bool {
            const picker = &app.session_persistence.session_picker;
            if (!picker.active) return false;
            const next: SessionPickerScope = switch (picker.scope) {
                .current_workspace => .all_workspaces,
                .all_workspaces => .current_workspace,
            };
            try openSessionPickerWithScope(app, next);
            return true;
        }

        pub fn pollSessionPicker(app: *App) !void {
            const loader = &app.session_persistence.session_picker_load;
            const task = loader.takeCompleted() orelse return;
            var task_owned = true;
            defer if (task_owned) task.deinit();

            if (task.failure == null and task.page != null and task.request.continuation == null) {
                const cache = sessionPickerCacheForScope(
                    &app.session_persistence,
                    task.request.scope,
                );
                cache.install(
                    &task.page.?,
                    task.request.active_id,
                    task.request.limit,
                    io_mod.nanoTimestamp(),
                ) catch |err| {
                    debug_trace.logf(
                        "core",
                        "session picker cache install failed scope={s} err={s}",
                        .{ @tagName(task.request.scope), @errorName(err) },
                    );
                };
            }

            const picker = &app.session_persistence.session_picker;
            const current = picker.active and picker.generation == task.request.generation;
            if (!current) {
                if (task.failure == null and task.page != null and task.request.continuation == null) {
                    debug_trace.logf(
                        "core",
                        "session picker completion cached scope={s} generation={d}",
                        .{ @tagName(task.request.scope), task.request.generation },
                    );
                } else {
                    debug_trace.logf(
                        "core",
                        "session picker completion dropped reason=stale generation={d}",
                        .{task.request.generation},
                    );
                }
            } else {
                if (task.failure) |err| {
                    if (task.request.continuation != null) {
                        picker.loading_more = false;
                    } else if (picker.load_state != .ready) {
                        picker.load_state = .failed;
                    }
                    try writeSessionPickerError(app, err);
                } else if (task.page) |*page| {
                    applySessionPickerPage(app, picker, task, page) catch |err| {
                        if (task.request.continuation != null) {
                            picker.loading_more = false;
                        } else if (picker.load_state != .ready) {
                            picker.load_state = .failed;
                        }
                        try writeSessionPickerError(app, err);
                    };
                }
            }

            task.deinit();
            task_owned = false;

            const store = if (app.session_persistence.store) |*value|
                value
            else
                return;
            const pending_generation = loader.pendingGeneration();
            _ = loader.startPending(store) catch |err| {
                if (pending_generation) |generation| {
                    if (picker.active and picker.generation == generation) {
                        if (picker.loading_more) {
                            picker.loading_more = false;
                        } else {
                            picker.load_state = .failed;
                        }
                        try writeSessionPickerError(app, err);
                    }
                }
                return;
            };
            if (comptime @hasField(App, "shell")) {
                if (picker.active) app.shell.render_requests.request(.footer);
            }
        }

        fn writeSessionPickerError(app: *App, err: anyerror) !void {
            const notice = try std.fmt.allocPrint(
                app.alloc,
                "unable to list saved sessions: {s}",
                .{@errorName(err)},
            );
            defer app.alloc.free(notice);
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .@"error",
                .body = notice,
            }, true);
        }

        fn applySessionPickerPage(
            app: *App,
            picker: *SessionPicker,
            task: *const SessionPickerLoad.Task,
            page: *const subagent_resume_admission.ActionableSessionPage,
        ) !void {
            var continuation: ?subagent_resume_admission.ActionableContinuation =
                if (page.continuation) |value| .{
                    .updated_at_ms = value.updated_at_ms,
                    .id = try app.alloc.dupe(u8, value.id),
                } else null;
            errdefer if (continuation) |value| {
                var owned = value;
                owned.deinit(app.alloc);
            };
            const selected_load_more = task.request.continuation != null and
                picker.selected == picker.filteredItemCount();
            const previous_filtered_count = picker.filteredItemCount();
            if (task.request.continuation == null) {
                try replaceSessionPickerPage(picker, app.alloc, page);
            } else {
                try picker.appendPage(app.alloc, page.summaries.items);
            }
            if (picker.continuation) |*prior| prior.deinit(app.alloc);
            picker.continuation = continuation;
            continuation = null;
            picker.has_more = page.has_more;
            picker.loading_more = false;
            picker.load_state = .ready;
            if (selected_load_more) {
                picker.selected = selectionAfterLoadedPage(
                    previous_filtered_count,
                    picker.filteredItemCount(),
                    picker.has_more,
                );
            }
            try input_completion_runtime.CompletionRuntime(App).syncSessionPickerWindowStart(app);
        }

        pub fn loadMoreSessionPicker(app: *App) !bool {
            const picker = &app.session_persistence.session_picker;
            if (!picker.isLoadMoreSelected()) return false;
            if (picker.loading_more) return true;
            try scheduleMoreSessions(app);
            return true;
        }

        fn scheduleMoreSessions(app: *App) !void {
            const picker = &app.session_persistence.session_picker;
            const store = if (app.session_persistence.store) |*value|
                value
            else
                return error.SessionStoreUnavailable;
            const continuation = picker.continuation orelse
                return error.SessionStoreUnavailable;
            const active_id = if (app.session_persistence.writable) |*loaded|
                loaded.active_id
            else
                null;
            const limit = if (comptime @hasField(App, "shell"))
                resumePageLimitForRows(app.shell.layout.rows)
            else
                session_store.default_resume_page_limit;
            const request = try SessionPickerLoad.PageRequest.init(
                picker.generation,
                picker.scope,
                active_id,
                continuation.view(),
                limit,
            );

            picker.loading_more = true;
            app.session_persistence.session_picker_load.schedule(store, request) catch |err| {
                picker.loading_more = false;
                return err;
            };
            if (comptime @hasField(App, "shell")) {
                app.shell.render_requests.request(.footer);
            }
        }

        // Prefetch the next page as the selection reaches the last loaded
        // session (or the load-more slot), so scrolling down fills the list in
        // without stopping to activate "Load more".
        fn maybePrefetchMoreSessions(app: *App) void {
            const picker = &app.session_persistence.session_picker;
            if (!picker.active or picker.load_state != .ready) return;
            if (!picker.has_more or picker.loading_more) return;
            if (picker.summaries.items.len == 0) return;
            if (picker.selected + 1 < picker.filteredItemCount()) return;
            scheduleMoreSessions(app) catch |err| {
                debug_trace.logf(
                    "core",
                    "session picker prefetch failed err={s}",
                    .{@errorName(err)},
                );
            };
        }

        pub fn cancelSessionPicker(app: *App) void {
            const picker = &app.session_persistence.session_picker;
            if (picker.load_state != .ready) {
                app.session_persistence.session_picker_load.cancelGeneration(picker.generation);
            }
            picker.deinit(app.alloc);
        }

        pub fn cancelSessionPickerToComposer(app: *App) void {
            cancelSessionPicker(app);
            if (comptime !@hasField(App, "session")) return;
            if (app.session_persistence.writable != null) return;
            beginFreshPersistedSession(app) catch |err| {
                debug_trace.logf(
                    "session",
                    "fresh session after picker cancel unavailable err={s}",
                    .{@errorName(err)},
                );
                return;
            };
            enableSessionStores(app);
        }

        fn invalidateSessionPickerCaches(app: *App) void {
            app.session_persistence.session_picker_current_cache.deinit();
            app.session_persistence.session_picker_all_cache.deinit();
        }

        pub fn moveSessionPicker(app: *App, delta: i32, visible_items: u16) bool {
            const moved = app.session_persistence.session_picker.moveVisibleItems(delta, visible_items);
            maybePrefetchMoreSessions(app);
            return moved;
        }

        pub fn recordToolTerminal(
            app: *App,
            event: types.ToolLifecycleEvent,
            captured_command_call: bool,
        ) void {
            const terminal = switch (event) {
                .terminal => |value| value,
                .provisional, .authoritative_started, .progress, .turn_finished => return,
            };
            if (!captured_command_call) {
                discardPendingCancelledCommand(app, terminal.id, "non_command_terminal");
                return;
            }
            if (terminal.outcome.kind != .cancelled) {
                discardPendingCancelledCommand(app, terminal.id, "ordinary_command_terminal");
                return;
            }
            const pending = ensurePendingCancelledCommand(app, terminal.id) orelse return;
            if (pending.command_artifact_handle) |handle| {
                app.alloc.free(handle);
                pending.command_artifact_handle = null;
            }
            if (terminal.command_artifact_handle) |handle| {
                pending.command_artifact_handle = app.alloc.dupe(u8, handle) catch |err| {
                    debug_trace.logf(
                        "session",
                        "cancelled command artifact capture unavailable call_id={s} err={s}",
                        .{ terminal.id.call_id, @errorName(err) },
                    );
                    return;
                };
            }
        }

        pub fn appendHistoryTurn(app: *App, turn: types.HistoryTurn) !void {
            _ = try appendHistoryTurnWithPendingPresentation(app, turn, .strict, null);
        }

        pub fn appendFinishedPrompt(
            app: *App,
            finished: types.FinishedPrompt,
        ) !void {
            var turn = finished.turn;
            if (finished.summary) |summary| {
                types.setHistoryTurnSummary(&turn, summary);
            }
            _ = try appendHistoryTurnWithPendingPresentation(
                app,
                turn,
                .strict,
                finished.snapshot_file_ownership,
            );
        }

        pub fn persistUsageCheckpoint(
            app: *App,
            snapshot: session_usage.Snapshot,
        ) !void {
            if (comptime !@hasField(App, "session_persistence")) {
                return error.SessionPersistenceUnavailable;
            }
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const store = if (app.session_persistence.store) |value|
                value
            else
                return error.SessionPersistenceUnavailable;
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return error.SessionPersistenceUnavailable;
            const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
                app.alloc,
                loaded,
                snapshot,
            );
            try convergeDegradedAt(
                app,
                loaded,
                .{},
                recovery_checkpoint.timestamp_ms,
            );
            _ = try loaded.appendEvent(
                app.alloc,
                .{ .usage_checkpointed = .{ .usage = snapshot } },
                recovery_checkpoint.timestamp_ms,
                .retry_expected_tail,
                .{ .checkpoint_interval = 0 },
            );
            try store.finishUsageRecoveryCheckpoint(
                loaded.active_id,
                recovery_checkpoint,
            );
        }

        pub fn setRecoveryCheckpoint(
            app: *App,
            checkpoint: session_codec.RecoveryCheckpoint,
        ) !void {
            if (comptime !@hasField(App, "session_persistence")) {
                return error.SessionPersistenceUnavailable;
            }
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return error.SessionPersistenceUnavailable;
            try convergeDegraded(app, loaded, .{});
            const now_ms = io_mod.milliTimestamp();
            _ = loaded.appendEvent(
                app.alloc,
                .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
                now_ms,
                .retry_expected_tail,
                .{},
            ) catch |err| switch (err) {
                error.EventFrameTooLarge => {
                    var current = try snapshotCurrentState(app, loaded.state, now_ms);
                    defer current.deinit(app.alloc);
                    if (current.recovery_checkpoint) |*old| old.deinit(app.alloc);
                    current.recovery_checkpoint = try checkpoint.dupe(app.alloc);
                    _ = try loaded.commitStateReplacement(
                        app.alloc,
                        current,
                        .compaction,
                        .retry_expected_tail,
                        .{},
                    );
                },
                else => return err,
            };
        }

        pub fn snapshotRecoveryCheckpoint(
            app: *App,
            alloc: Allocator,
        ) !?session_codec.RecoveryCheckpoint {
            if (comptime !@hasField(App, "session_persistence")) return null;
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value| value else return null;
            const checkpoint = loaded.state.recovery_checkpoint orelse return null;
            return try checkpoint.dupe(alloc);
        }

        pub fn continuePausedRecovery(app: *App) !bool {
            var checkpoint = (try snapshotRecoveryCheckpoint(
                app,
                std.heap.c_allocator,
            )) orelse return false;
            defer checkpoint.deinit(std.heap.c_allocator);

            app.session.setConversationLanguageFromUserMessage(checkpoint.user.text);
            return app.queueRecoveryCheckpoint(&checkpoint);
        }

        pub fn appendHistoryTurnForVisualEpoch(
            app: *App,
            turn: types.HistoryTurn,
        ) !HistoryAppendOutcome {
            return appendHistoryTurnWithPendingPresentation(
                app,
                turn,
                .visual_epoch,
                null,
            );
        }

        pub fn appendFinishedPromptForVisualEpoch(
            app: *App,
            finished: types.FinishedPrompt,
        ) !HistoryAppendOutcome {
            return appendHistoryTurnWithPendingPresentation(
                app,
                finished.turn,
                .visual_epoch,
                finished.snapshot_file_ownership,
            );
        }

        const AppendHistoryMode = enum {
            strict,
            visual_epoch,
        };

        fn appendHistoryTurnWithPendingPresentation(
            app: *App,
            turn: types.HistoryTurn,
            mode: AppendHistoryMode,
            snapshot_file_ownership: ?types.SnapshotFileOwnership,
        ) !HistoryAppendOutcome {
            if (comptime !@hasField(App, "session_persistence")) {
                return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership);
            }
            const interrupted = switch (turn) {
                .interrupted => |entry| entry,
                else => return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership),
            };
            var pending = app.session_persistence.pending_cancelled_command orelse {
                return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership);
            };
            app.session_persistence.pending_cancelled_command = null;
            const call = interrupted.tool_call orelse {
                pending.discard(app.alloc);
                return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership);
            };
            const is_command = try captured_command.isToolCall(
                app.alloc,
                call.name,
                call.arguments_json,
            );
            if (!is_command or
                !std.mem.eql(u8, call.id, pending.lifecycle_id.call_id))
            {
                pending.discard(app.alloc);
                return appendHistoryTurnWithOutcome(app, turn, mode, snapshot_file_ownership);
            }
            defer pending.discard(app.alloc);

            if (interrupted.cancelled_command) |authoritative| {
                var enriched_presentation = authoritative;
                if (enriched_presentation.command_artifact_handle == null) {
                    enriched_presentation.command_artifact_handle =
                        pending.command_artifact_handle;
                }
                var enriched_interrupted = interrupted;
                enriched_interrupted.cancelled_command = enriched_presentation;
                return appendHistoryTurnWithOutcome(
                    app,
                    .{ .interrupted = enriched_interrupted },
                    mode,
                    snapshot_file_ownership,
                );
            }

            var enriched_interrupted = interrupted;
            enriched_interrupted.cancelled_command = .{
                .command_artifact_handle = pending.command_artifact_handle,
            };
            const enriched: types.HistoryTurn = .{ .interrupted = enriched_interrupted };
            return appendHistoryTurnWithOutcome(app, enriched, mode, snapshot_file_ownership);
        }

        fn ensurePendingCancelledCommand(
            app: *App,
            id: types.ToolLifecycleId,
        ) ?*PendingCancelledCommand {
            if (app.session_persistence.pending_cancelled_command) |*pending| {
                if (pending.matches(id)) return pending;
                discardAnyPendingCancelledCommand(app, "lifecycle_replaced");
            }

            const call_id = app.alloc.dupe(u8, id.call_id) catch |err| {
                debug_trace.logf(
                    "session",
                    "cancelled command metadata identity unavailable call_id={s} err={s}",
                    .{ id.call_id, @errorName(err) },
                );
                return null;
            };
            app.session_persistence.pending_cancelled_command = .{
                .lifecycle_id = .{
                    .turn_id = id.turn_id,
                    .call_id = call_id,
                },
            };
            return &app.session_persistence.pending_cancelled_command.?;
        }

        fn discardPendingCancelledCommand(
            app: *App,
            id: types.ToolLifecycleId,
            reason: []const u8,
        ) void {
            const pending = if (app.session_persistence.pending_cancelled_command) |*value|
                value
            else
                return;
            if (!pending.matches(id)) return;
            discardAnyPendingCancelledCommand(app, reason);
        }

        fn discardAnyPendingCancelledCommand(app: *App, reason: []const u8) void {
            const pending = if (app.session_persistence.pending_cancelled_command) |*value|
                value
            else
                return;
            debug_trace.logf(
                "session",
                "cancelled command metadata discarded call_id={s} reason={s}",
                .{ pending.lifecycle_id.call_id, reason },
            );
            pending.discard(app.alloc);
            app.session_persistence.pending_cancelled_command = null;
        }

        fn appendHistoryTurnWithOutcome(
            app: *App,
            turn: types.HistoryTurn,
            mode: AppendHistoryMode,
            snapshot_file_ownership: ?types.SnapshotFileOwnership,
        ) !HistoryAppendOutcome {
            app.session.appendHistoryEntry(app.alloc, turn) catch |err| {
                return switch (mode) {
                    .strict => err,
                    .visual_epoch => .uncommitted,
                };
            };
            if (snapshot_file_ownership) |ownership| ownership.transfer();
            // The footer title freezes at the first usable prompt, matching the
            // sidecar derivation the resume picker shows.
            ensureCachedSessionTitle(app) catch {};
            commitJsHostSnapshot(app, "history_turn");
            if (comptime !@hasField(App, "session_persistence")) return .committed;
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return .committed;
            try subagent_resume_admission.retainExternalRootUserTurn(
                app.alloc,
                loaded,
                turn,
            );
            convergeDegraded(app, loaded, .{}) catch |err| {
                return switch (mode) {
                    .strict => err,
                    .visual_epoch => blk: {
                        debug_trace.logf(
                            "session",
                            "visual epoch history committed with degraded persistence err={s}",
                            .{@errorName(err)},
                        );
                        break :blk .committed_degraded;
                    },
                };
            };

            _ = loaded.appendEvent(
                app.alloc,
                .{ .history_turn_committed = .{
                    .conversation_language = app.session.languageSnapshot(),
                    .total_input_tokens = app.total_input_tokens,
                    .total_output_tokens = app.total_output_tokens,
                    .turn = turn,
                } },
                io_mod.milliTimestamp(),
                .retry_expected_tail,
                .{},
            ) catch |err| switch (err) {
                error.EventFrameTooLarge => {
                    commitCurrentStateReplacement(
                        app,
                        loaded,
                        .compaction,
                        .{},
                        true,
                    ) catch |replacement_err| {
                        return switch (mode) {
                            .strict => replacement_err,
                            .visual_epoch => .committed_degraded,
                        };
                    };
                    return .committed;
                },
                else => {
                    switch (mode) {
                        .strict => try warnDegraded(app, err),
                        .visual_epoch => debug_trace.logf(
                            "session",
                            "visual epoch history committed with degraded persistence err={s}",
                            .{@errorName(err)},
                        ),
                    }
                    return .committed_degraded;
                },
            };
            return .committed;
        }

        pub fn compactHistory(app: *App) !void {
            const previous_start = app.session.contextHistoryStart();
            app.session.forceCompaction();
            if (app.session.contextHistoryStart() == previous_start) return;

            commitJsHostSnapshot(app, "compaction");

            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return;
            try convergeDegraded(app, loaded, .{});
            try commitCurrentStateReplacement(app, loaded, .compaction, .{}, false);
        }

        pub fn commitRuntimePreferences(
            app: *App,
            patch: SessionPreferencePatch,
        ) PreferenceCommitResult {
            var result = PreferenceCommitResult{};
            applySessionPreferencePatch(app, patch) catch |err| {
                result.session_error = err;
            };

            var settings_attempt = config_runtime.attemptUserPreferences(
                app.alloc,
                patch.userSettingsPatch(),
            );
            switch (settings_attempt) {
                .outcome => |outcome| {
                    result.settings_outcome = outcome;
                    settings_attempt = undefined;
                },
                .failure => |failure| {
                    result.settings_error = failure.err;
                    result.settings_failure_cleanup = failure.cleanup;
                    settings_attempt = undefined;
                },
            }
            if (result.settings_error == null) {
                applyPreferencePatch(
                    app.alloc,
                    &app.session_persistence.workspace_preferences,
                    patch,
                ) catch |err| {
                    result.session_error = err;
                };
            }

            if (result.session_error == null) {
                commitJsHostSnapshot(app, "preferences");
            }

            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return result;
            if (result.session_error != null) return result;
            convergeDegraded(app, loaded, .{}) catch |err| {
                result.session_error = err;
                return result;
            };
            _ = loaded.appendEvent(
                app.alloc,
                .{ .preferences_changed = .{
                    .model = if (patch.model) |model|
                        @constCast(model)
                    else
                        null,
                    .provider = patch.provider,
                    .effort = patch.effort,
                    .fast_mode = patch.fast_mode,
                } },
                io_mod.milliTimestamp(),
                .retry_expected_tail,
                .{},
            ) catch |err| {
                result.session_error = err;
                warnDegraded(app, err) catch {};
            };
            return result;
        }

        pub fn activeSessionId(app: *App) ?[]const u8 {
            if (app.session_persistence.writable) |*loaded| return loaded.active_id;
            if (app.session_persistence.js_host_session) |*owner| return owner.state.id;
            return null;
        }

        /// Replaces the cached footer title. App owns the copy. Keeps the
        /// terminal title in step because both surfaces read this cache.
        pub fn setCachedSessionTitle(app: *App, title: []const u8) !void {
            if (comptime !@hasField(App, "session_title")) return;
            app.session_title.clearRetainingCapacity();
            try appendTitleWithoutControlBytes(app, title);
            syncTerminalTitle(app);
        }

        pub fn clearCachedSessionTitle(app: *App) void {
            if (comptime !@hasField(App, "session_title")) return;
            app.session_title.clearRetainingCapacity();
            syncTerminalTitle(app);
        }

        /// Drops C0 and DEL bytes. The cached title feeds the statusline and
        /// the OSC 2 terminal title, where a stray BEL or ESC would close the
        /// escape sequence early and hand the remaining bytes to the terminal
        /// as commands. Derived titles come from prompt text and from the
        /// display sidecar, so neither source is trusted here; `/rename` input
        /// is already rejected by `validateSessionTitle`.
        fn appendTitleWithoutControlBytes(app: *App, title: []const u8) !void {
            var start: usize = 0;
            for (title, 0..) |byte, index| {
                if (byte >= 0x20 and byte != 0x7f) continue;
                try app.session_title.appendSlice(app.alloc, title[start..index]);
                start = index + 1;
            }
            try app.session_title.appendSlice(app.alloc, title[start..]);
        }

        fn terminalTitle(app: *App) host_capability.TerminalTitle {
            if (comptime @hasDecl(App, "terminalTitle")) {
                return app.terminalTitle();
            }
            if (comptime builtin.is_test) return host_capability.unavailable_terminal_title;
            @compileError("interactive session runtime requires a terminal title host capability");
        }

        const terminal_title_primary_max_bytes: usize = 64;
        const terminal_title_model_max_bytes: usize = 48;
        const terminal_title_separator = " · ";
        const terminal_title_label_max_bytes = terminal_title_primary_max_bytes +
            terminal_title_separator.len + terminal_title_model_max_bytes;

        fn workspaceTerminalTitle(app: *App) []const u8 {
            if (comptime !@hasField(App, "workspace_root")) return "workspace";
            const basename = std.fs.path.basename(app.workspace_root);
            return if (basename.len == 0) "workspace" else basename;
        }

        fn writeBoundedTerminalTitleComponent(
            writer: *std.Io.Writer,
            value: []const u8,
            max_bytes: usize,
        ) !void {
            if (value.len <= max_bytes) return writer.writeAll(value);
            const marker = "...";
            const prefix_budget = max_bytes - marker.len;
            const prefix = if (std.unicode.utf8ValidateSlice(value))
                text_utils.utf8PrefixByBytes(value, prefix_budget)
            else
                value[0..prefix_budget];
            try writer.writeAll(prefix);
            try writer.writeAll(marker);
        }

        /// Terminal tabs prefer the session name and otherwise use the
        /// workspace basename. The active model remains visible as secondary
        /// context, including after a model switch.
        pub fn syncTerminalTitle(app: *App) void {
            if (comptime !provider_runtime.supported(App)) return;
            syncTerminalTitleWith(app, terminalTitle(app));
        }

        pub fn syncTerminalTitleWith(
            app: *App,
            provider: host_capability.TerminalTitle,
        ) void {
            if (comptime !provider_runtime.supported(App)) return;
            var label_buffer: [terminal_title_label_max_bytes]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&label_buffer);
            const primary = cachedSessionTitle(app) orelse workspaceTerminalTitle(app);
            writeBoundedTerminalTitleComponent(
                &writer,
                primary,
                terminal_title_primary_max_bytes,
            ) catch return;
            const selected_model = provider_runtime.model(app);
            if (selected_model.len > 0) {
                writer.writeAll(terminal_title_separator) catch return;
                writeBoundedTerminalTitleComponent(
                    &writer,
                    selected_model,
                    terminal_title_model_max_bytes,
                ) catch return;
            }
            provider.set(writer.buffered());
        }

        pub fn cachedSessionTitle(app: *App) ?[]const u8 {
            if (comptime !@hasField(App, "session_title")) return null;
            return if (app.session_title.items.len == 0) null else app.session_title.items;
        }

        /// Derives and caches the title on the first turn of a fresh session.
        /// Derivation freezes at the first usable prompt, so this is a no-op
        /// once a title is cached.
        pub fn ensureCachedSessionTitle(app: *App) !void {
            if (comptime !@hasField(App, "session_title")) return;
            if (app.session_title.items.len > 0) return;
            var display = session_display_metadata.deriveFromHistory(
                app.alloc,
                app.session.history.items,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            defer display.deinit(app.alloc);
            if (!display.present) return;
            try setCachedSessionTitle(app, display.title);
        }

        pub const RenameError = error{
            EmptyTitle,
            TitleTooLong,
            InvalidTitle,
            NoActiveSession,
        };

        /// Validates a user-supplied session title. Returns the trimmed slice,
        /// which borrows from `raw`.
        pub fn validateSessionTitle(raw: []const u8) RenameError![]const u8 {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) return error.EmptyTitle;
            if (trimmed.len > session_display_metadata.max_title_bytes) return error.TitleTooLong;
            if (!std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidTitle;
            for (trimmed) |byte| {
                if (byte < 0x20 or byte == 0x7f) return error.InvalidTitle;
            }
            return trimmed;
        }

        /// Renames the active session: caches the title for the footer and
        /// persists it to the display sidecar and the session index so the
        /// resume picker does not keep serving the derived title.
        pub fn renameActiveSession(app: *App, raw: []const u8) !void {
            const title = try validateSessionTitle(raw);
            if (comptime !@hasField(App, "session_persistence")) return error.NoActiveSession;
            if (app.session_persistence.writable == null) return error.NoActiveSession;

            try setCachedSessionTitle(app, title);

            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());

            const loaded = &app.session_persistence.writable.?;
            var display = session_display_metadata.readSidecarOrFallback(
                app.alloc,
                &loaded.log.dir,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => try session_display_metadata.missingFallback(app.alloc),
            };
            defer display.deinit(app.alloc);

            const owned_title = try app.alloc.dupe(u8, title);
            app.alloc.free(display.title);
            display.title = owned_title;
            display.present = true;
            if (display.origin_workspace_root == null) {
                display.origin_workspace_root = try app.alloc.dupe(u8, loaded.state.origin_workspace_root);
            }
            try session_display_metadata.writeSidecar(app.alloc, &loaded.log.dir, display);

            if (app.session_persistence.store) |*store| {
                store.updateIndexedTitle(app.alloc, loaded.active_id, title) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => debug_trace.logf(
                        "session",
                        "event=rename_index_update_failed id={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    ),
                };
            }
        }

        pub fn activeSessionDisplayPath(
            app: *App,
            alloc: Allocator,
        ) !?[]u8 {
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return null;
            const store = app.session_persistence.store orelse return null;
            return try session_store.sessionDirPath(
                alloc,
                store.sessions_dir,
                loaded.active_id,
            );
        }

        pub fn childCapability(app: *App) ?*session_child_store.SessionChildCapability {
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return null;
            return loaded.childCapability() catch null;
        }

        pub fn subagentHost(app: *App) ?*subagent_tool_host.Runtime {
            return app.session_persistence.subagent_host;
        }

        pub fn rebindSubagentHost(app: *App) void {
            const host = app.session_persistence.subagent_host orelse return;
            const store = if (app.session_persistence.store) |*value| value else return;
            host.rebind(store, app, subagentAuthorityResolver(app));
            requestSubagentBackgroundRecovery(app);
        }

        fn requestSubagentBackgroundRecovery(app: *App) void {
            const host = app.session_persistence.subagent_host orelse return;
            host.requestBackgroundRecovery(io_mod.milliTimestamp()) catch |err| {
                debug_trace.logf(
                    "subagent",
                    "interactive background recovery unavailable root_id={s} outcome={s}",
                    .{ host.root_id, @errorName(err) },
                );
            };
        }

        pub fn disableSubagentHost(app: *App) void {
            if (app.session_persistence.subagent_host) |host| {
                host.deinit();
                app.session_persistence.subagent_host = null;
            }
        }

        pub fn finalizePersistence(app: *App) void {
            if (app.session_persistence.writable) |*loaded| {
                if (loaded.log.isParked()) {
                    app.session_persistence.resume_handoff_intent = .none;
                    abandonParkedWritableSession(app);
                    return;
                }
            }
            closeWritableSession(app, .{});
        }

        pub fn finalizePersistenceWithResumeHandoff(app: *App) ?ResumeHandoff {
            if (app.session_persistence.writable) |*loaded| {
                if (loaded.log.isParked()) {
                    app.session_persistence.resume_handoff_intent = .none;
                    abandonParkedWritableSession(app);
                    return null;
                }
            }
            return closeWritableSessionWithResumeHandoff(app, .{});
        }

        pub fn requestResumeHandoff(app: *App) void {
            app.session_persistence.resume_handoff_intent = .requested;
        }

        pub fn requestUpgradeResumeHandoff(app: *App) void {
            app.session_persistence.resume_handoff_intent = .upgrade_requested;
        }

        pub fn prepareResumeHandoff(app: *App) !void {
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return error.SessionPersistenceUnavailable;
            loaded.validateResumeBoundary(app.alloc, .{}) catch |err| {
                if (err != error.InvalidSessionFormat and
                    err != error.FileNotFound)
                {
                    return err;
                }
                try loaded.repairResumeBoundary(app.alloc, .{});
                debug_trace.logf(
                    "session",
                    "event=resume_boundary_repaired session={s}",
                    .{loaded.active_id},
                );
            };
            try settleResumeBoundary(app, loaded, .{});
        }

        pub fn suspendToJobControl(app: *App, footer_rows: u16) !void {
            if (!shell_runtime.supports_resize_signal) return;
            if (!tryBeginIdleSessionPark(app)) {
                return app_lifecycle.suspendToJobControl(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                    footer_rows,
                );
            }
            defer app.worker.releaseTurnStartHold();

            const loaded = &app.session_persistence.writable.?;
            detachManagedBackground(app, loaded);
            loaded.log.park();
            debug_trace.logf(
                "session",
                "parked writer lock for suspend session={s}",
                .{loaded.active_id},
            );

            const lifecycle_result = app_lifecycle.suspendToJobControl(
                &app.terminal,
                &app.shell,
                &app.metrics,
                footer_rows,
            );
            loaded.log.unpark() catch |err| {
                debug_trace.logf(
                    "session",
                    "unpark after suspend failed session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
                abandonParkedWritableSession(app);
                app.worker.requestStop();
                app.should_exit = true;
                try lifecycle_result;
                return;
            };

            debug_trace.logf(
                "session",
                "unparked writer lock after suspend session={s}",
                .{loaded.active_id},
            );
            const capability = loaded.childCapability() catch |err| {
                debug_trace.logf(
                    "session",
                    "interactive child capability unavailable session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
                try lifecycle_result;
                return;
            };
            restoreManagedBackground(app, loaded, capability);
            try lifecycle_result;
        }

        fn tryBeginIdleSessionPark(app: *App) bool {
            if (app.session_persistence.writable == null or app.stream.active) {
                return false;
            }
            return app.worker.tryHoldTurnStart();
        }

        /// Tear down a parked writable without converging or checkpointing.
        /// Background authority must already be detached (or is detached here).
        fn abandonParkedWritableSession(app: *App) void {
            discardAnyPendingCancelledCommand(app, "writable_session_abandon");
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return;
            detachManagedBackground(app, loaded);
            if (comptime @hasDecl(
                @TypeOf(app.session),
                "clearWebFetchArtifacts",
            )) {
                app.session.clearWebFetchArtifacts();
            }
            disableSubagentHost(app);
            debug_trace.logf(
                "session",
                "abandon parked writable session={s}",
                .{loaded.active_id},
            );
            loaded.deinit(app.alloc);
            app.session_persistence.writable = null;
        }

        fn detachManagedBackground(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
        ) void {
            if (comptime @hasField(App, "background") and
                @hasDecl(@TypeOf(app.background), "detachManagedPersistence"))
            {
                app.background.detachManagedPersistence(
                    std.heap.c_allocator,
                    loaded.active_id,
                );
            }
        }

        pub fn deinitPersistence(app: *App) void {
            closeWritableSession(app, .{});
            app.session_persistence.deinit(app.alloc);
        }

        fn LiveHistorySink(comptime SinkApp: type) type {
            return struct {
                app: *SinkApp,

                const Self = @This();

                fn appendNotice(self: *Self, notice: types.SemanticNotice) !void {
                    try self.app.writeDomainNotice(notice, true);
                }

                fn setCreatedAtMs(_: *Self, _: i64) void {}

                fn materializeCommandReplay(_: *const Self) bool {
                    return true;
                }

                fn appendTurnSummary(self: *Self, summary: types.TurnSummary) !void {
                    if (comptime @hasField(SinkApp, "shell")) {
                        if (comptime @hasDecl(@TypeOf(self.app.shell), "appendTurnSummaryEntry")) {
                            _ = try self.app.shell.appendTurnSummaryEntry(self.app.alloc, summary);
                        }
                    }
                }

                fn appendUserTurn(self: *Self, user: types.UserTurn, has_prior_turns: bool) !void {
                    try self.app.writeUserPromptCardWithSpacing(user, has_prior_turns);
                }

                fn appendRaw(self: *Self, text: []const u8) !void {
                    try self.app.writeTranscript(text, true);
                }

                fn appendToolStatus(
                    self: *Self,
                    kind: types.ToolOutcomeKind,
                    status: []const u8,
                ) !u32 {
                    if (comptime @hasDecl(SinkApp, "writeCompletedToolStatusReturningEntryId")) {
                        return self.app.writeCompletedToolStatusReturningEntryId(kind, status, true);
                    }
                    try self.app.writeCompletedToolStatus(kind, status, true);
                    return 0;
                }

                fn appendCommandOutput(
                    self: *Self,
                    stream: command_output_content.Stream,
                    text: []const u8,
                ) !void {
                    try self.app.writeCommandOutputChunk(stream, text, true);
                }

                fn finishCommandOutput(self: *Self) !void {
                    try self.app.flushCommandOutputSummary(true);
                }

                fn attachHistoricalToolDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetail")) {
                        try self.app.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolDetailWithLifecycle(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                    lifecycle_id: types.ToolLifecycleId,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetailWithLifecycle")) {
                        try self.app.attachHistoricalToolDetailWithLifecycle(
                            entry_id,
                            call,
                            result,
                            lifecycle_id,
                        );
                    } else {
                        try self.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolDetailAfterCommandOutput(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolDetailAfterCommandOutput")) {
                        try self.app.attachHistoricalToolDetailAfterCommandOutput(
                            entry_id,
                            call,
                            result,
                        );
                    } else {
                        try self.attachHistoricalToolDetail(entry_id, call, result);
                    }
                }

                fn attachHistoricalToolCallWithoutResult(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalToolCallWithoutResult")) {
                        try self.app.attachHistoricalToolCallWithoutResult(entry_id, call);
                    }
                }

                fn attachHistoricalCommandOutput(self: *Self, entry_id: u32) void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalCommandOutput")) {
                        self.app.attachHistoricalCommandOutput(entry_id);
                    }
                }

                fn attachHistoricalCancelledCommandDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    command_artifact_handle: ?[]const u8,
                    replayed_output: bool,
                ) !void {
                    if (comptime @hasDecl(SinkApp, "attachHistoricalCancelledCommandDetail")) {
                        try self.app.attachHistoricalCancelledCommandDetail(
                            entry_id,
                            call,
                            command_artifact_handle,
                            replayed_output,
                        );
                    }
                }

                fn appendQuestionResolution(
                    self: *Self,
                    answers: []const types.QuestionAnswer,
                ) !u32 {
                    return self.app.writeHistoricalQuestionResolution(answers);
                }

                fn appendDiff(self: *Self, payload: diff.DiffEntryPayload) !void {
                    try self.app.registerAndEmitDiffBlock(payload);
                }

                fn appendAssistantText(self: *Self, text: []const u8) !void {
                    try SinkApp.pacerEmit(self.app, text);
                }

                fn appendAssistantTable(
                    self: *Self,
                    table: assistant_presentation.TablePayload,
                ) !void {
                    try self.app.appendAssistantTable(table);
                }

                fn appendAssistantCodeBlock(
                    self: *Self,
                    block: assistant_presentation.CodeBlockPayload,
                ) !void {
                    try self.app.appendAssistantCodeBlock(block);
                }

                fn appendAssistantThematicRule(self: *Self) !void {
                    try self.app.appendAssistantThematicRule();
                }
            };
        }

        fn DetachedHistorySink(comptime Projection: type) type {
            return struct {
                app: *App,
                projection: *Projection,

                const Self = @This();

                fn activityKind(self: *Self, call: types.ToolCall) types.ToolActivityKind {
                    return self.app.historicalToolActivityKind(call);
                }

                fn appendNotice(self: *Self, notice: types.SemanticNotice) !void {
                    _ = try self.projection.appendNotice(notice);
                }

                fn setCreatedAtMs(self: *Self, created_at_ms: i64) void {
                    self.projection.setCreatedAtMs(created_at_ms);
                }

                fn materializeCommandReplay(_: *const Self) bool {
                    return false;
                }

                fn appendTurnSummary(self: *Self, summary: types.TurnSummary) !void {
                    try self.projection.appendTurnSummary(summary);
                }

                fn appendUserTurn(self: *Self, user: types.UserTurn, _: bool) !void {
                    _ = try self.projection.appendUserTurn(user);
                }

                fn appendRaw(self: *Self, text: []const u8) !void {
                    _ = try self.projection.appendRawClassified(text, .unknown_raw);
                }

                fn appendToolStatus(
                    self: *Self,
                    kind: types.ToolOutcomeKind,
                    status: []const u8,
                ) !u32 {
                    return self.projection.appendToolStatus(kind, status);
                }

                fn appendCommandOutput(
                    self: *Self,
                    stream: command_output_content.Stream,
                    text: []const u8,
                ) !void {
                    try self.projection.appendCommandOutput(null, stream, text);
                }

                fn finishCommandOutput(self: *Self) !void {
                    try self.projection.finishCommandOutput(null);
                }

                fn attachHistoricalToolDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    try self.projection.attachHistoricalToolDetail(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                    );
                }

                fn attachHistoricalToolDetailWithLifecycle(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                    lifecycle_id: types.ToolLifecycleId,
                ) !void {
                    try self.projection.attachHistoricalToolDetailWithLifecycle(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                        lifecycle_id,
                    );
                }

                fn attachHistoricalToolDetailAfterCommandOutput(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    result: types.PersistedToolResult,
                ) !void {
                    try self.projection.attachHistoricalToolDetailAfterCommandOutput(
                        entry_id,
                        call,
                        self.activityKind(call),
                        result,
                    );
                }

                fn attachHistoricalToolCallWithoutResult(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                ) !void {
                    try self.projection.attachHistoricalToolCallWithoutResult(entry_id, call);
                }

                fn attachHistoricalCommandOutput(self: *Self, entry_id: u32) void {
                    self.projection.attachHistoricalCommandOutput(entry_id);
                }

                fn attachHistoricalCancelledCommandDetail(
                    self: *Self,
                    entry_id: u32,
                    call: types.ToolCall,
                    command_artifact_handle: ?[]const u8,
                    replayed_output: bool,
                ) !void {
                    try self.projection.attachHistoricalCancelledCommandDetail(
                        entry_id,
                        call,
                        command_artifact_handle,
                        replayed_output,
                    );
                }

                fn appendQuestionResolution(
                    self: *Self,
                    answers: []const types.QuestionAnswer,
                ) !u32 {
                    const text = try self.app.prepareHistoricalQuestionResolution(answers);
                    defer self.app.alloc.free(text);
                    return self.projection.appendReplaceableLine(text);
                }

                fn appendDiff(self: *Self, payload: diff.DiffEntryPayload) !void {
                    try self.projection.appendDiff(payload);
                }

                fn appendAssistantText(self: *Self, text: []const u8) !void {
                    try self.projection.appendAssistantText(text);
                }

                fn appendAssistantTable(
                    self: *Self,
                    table: assistant_presentation.TablePayload,
                ) !void {
                    try self.projection.appendAssistantTable(table);
                }

                fn appendAssistantCodeBlock(
                    self: *Self,
                    block: assistant_presentation.CodeBlockPayload,
                ) !void {
                    try self.projection.appendAssistantCodeBlock(block);
                }

                fn appendAssistantThematicRule(self: *Self) !void {
                    try self.projection.appendAssistantThematicRule();
                }
            };
        }

        fn readNativeResumeDisplay(
            app: *App,
            session: *session_store.LoadedWritableSession,
        ) !session_display_metadata.DisplayMetadata {
            // The sidecar title is frozen at first derivation; prefer it so the
            // notice matches the picker row the user selected. The notice is
            // cosmetic, so read failures fall back instead of failing the resume.
            var display = session_display_metadata.readSidecarOrFallback(app.alloc, &session.log.dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => blk: {
                    debug_trace.logf(
                        "session",
                        "event=resume_notice_sidecar_read_failed id={s} err={s}",
                        .{ session.log.session_id, @errorName(err) },
                    );
                    break :blk try session_display_metadata.deriveFromHistory(app.alloc, session.state.history);
                },
            };
            if (!display.present) {
                display.deinit(app.alloc);
                display = try session_display_metadata.deriveFromHistory(app.alloc, session.state.history);
            }
            return display;
        }

        fn writeResumeNotice(
            app: *App,
            sink: anytype,
            display_title: []const u8,
            notice: ResumeNotice,
        ) !void {
            try setCachedSessionTitle(app, display_title);
            switch (notice) {
                .session => try sink.appendNotice(.{
                    .topic = "session resumed",
                    .tone = .neutral,
                    .body = display_title,
                }),
                .upgrade => |version| {
                    const body = try std.fmt.allocPrint(
                        app.alloc,
                        "fx has been updated to v{s}",
                        .{version},
                    );
                    defer app.alloc.free(body);
                    try sink.appendNotice(.{
                        .topic = "",
                        .tone = .success,
                        .body = body,
                    });
                },
            }
        }

        fn writeRecoveryCheckpointToSink(
            app: *App,
            sink: anytype,
            state: session_codec.DurableSessionState,
        ) !void {
            const checkpoint = state.recovery_checkpoint orelse return;
            var has_prior_turns = false;
            for (state.history) |turn| switch (turn) {
                .compacted_summary => {},
                .assistant, .background_command, .interrupted => {
                    has_prior_turns = true;
                    break;
                },
            };
            try sink.appendUserTurn(checkpoint.user, has_prior_turns);
            try writeExecutionHistoryToSink(app, sink, checkpoint.execution);
            if (checkpoint.assistant_source.len > 0) {
                try writeAssistantHistoryMarkdownToSink(
                    app,
                    sink,
                    checkpoint.assistant_source,
                );
            }
            const recovery_notice = if (checkpoint.tool_state == .uncertain)
                try std.fmt.allocPrint(
                    app.alloc,
                    "model response recovery is paused at attempt {d}/{d}; inspect the uncertain tool state before /continue",
                    .{
                        checkpoint.consumed_provider_attempts +| @intFromBool(checkpoint.outstanding_reservation),
                        checkpoint.max_provider_attempts,
                    },
                )
            else
                try std.fmt.allocPrint(
                    app.alloc,
                    "model response recovery is paused at attempt {d}/{d}; run /continue to resume the preserved turn",
                    .{
                        checkpoint.consumed_provider_attempts +| @intFromBool(checkpoint.outstanding_reservation),
                        checkpoint.max_provider_attempts,
                    },
                );
            defer app.alloc.free(recovery_notice);
            try sink.appendNotice(.{
                .topic = "recovery",
                .tone = .warning,
                .body = recovery_notice,
            });
        }

        fn replayHistory(app: *App, history: []const types.HistoryTurn) !void {
            var sink = LiveHistorySink(App){ .app = app };
            return replayHistoryToSink(app, &sink, history);
        }

        fn replayHistoryToSink(app: *App, sink: anytype, history: []const types.HistoryTurn) !void {
            var has_prior_turns = false;
            return replayHistoryToSinkIncremental(app, sink, history, &has_prior_turns);
        }

        fn replayHistoryToSinkIncremental(
            app: *App,
            sink: anytype,
            history: []const types.HistoryTurn,
            has_prior_turns: *bool,
        ) !void {
            for (history) |turn| {
                switch (turn) {
                    .compacted_summary => |entry| {
                        const text = try session_runtime.formatCompactedContinuationMessage(app.alloc, entry.summary);
                        defer app.alloc.free(text);
                        try sink.appendNotice(.{
                            .topic = "session",
                            .tone = .neutral,
                            .body = text,
                        });
                    },
                    .assistant => |entry| {
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.started_at_ms);
                        }
                        try sink.appendUserTurn(entry.user, has_prior_turns.*);
                        has_prior_turns.* = true;
                        try writeExecutionHistoryToSink(app, sink, entry.execution);
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.completed_at_ms);
                        }
                        if (entry.assistant.len > 0) {
                            try writeAssistantHistoryMarkdownToSink(app, sink, entry.assistant);
                        }
                        if (entry.execution.turn_summary) |summary| {
                            try sink.appendTurnSummary(summary);
                        }
                    },
                    .background_command => |entry| {
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.started_at_ms);
                        }
                        try sink.appendUserTurn(entry.user, has_prior_turns.*);
                        has_prior_turns.* = true;

                        try writeExecutionHistoryToSink(app, sink, entry.execution);
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.completed_at_ms);
                        }
                        if (entry.assistant) |assistant| {
                            if (assistant.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, assistant);
                        }
                        if (entry.execution.turn_summary) |summary| {
                            try sink.appendTurnSummary(summary);
                        }
                        const text = try formatBackgroundReplayContext(app, entry);
                        defer app.alloc.free(text);
                        try sink.appendNotice(.{
                            .topic = "session",
                            .tone = .neutral,
                            .body = text,
                        });
                    },
                    .interrupted => |entry| {
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.started_at_ms);
                        }
                        try sink.appendUserTurn(entry.user, has_prior_turns.*);
                        has_prior_turns.* = true;
                        try writeExecutionHistoryToSink(app, sink, entry.execution);
                        if (entry.execution.turn_summary) |summary| {
                            sink.setCreatedAtMs(summary.completed_at_ms);
                        }
                        if (entry.assistant) |assistant| {
                            if (assistant.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, assistant);
                        }
                        if (entry.cancelled_command) |presentation| {
                            try writeCancelledCommandPresentation(app, sink, entry.tool_call.?, presentation);
                        }
                        try sink.appendNotice(session_runtime.interruptedTurnNotice(entry));
                        if (entry.execution.turn_summary) |summary| {
                            try sink.appendTurnSummary(summary);
                        }
                    },
                }
            }
        }

        /// Replay canonical session turns into a detached presentation using
        /// the exact same tool, message, markdown, diff, and command-output
        /// adapters as ordinary session resume.
        pub fn appendHistoryToDetachedProjection(
            app: *App,
            projection: anytype,
            history: []const types.HistoryTurn,
            has_prior_turns: *bool,
        ) !void {
            var sink = DetachedHistorySink(@TypeOf(projection.*)){
                .app = app,
                .projection = projection,
            };
            return replayHistoryToSinkIncremental(
                app,
                &sink,
                history,
                has_prior_turns,
            );
        }

        fn writeCancelledCommandPresentation(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            presentation: types.CancelledCommandPresentation,
        ) !void {
            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer action_arena.deinit();
            const action = try app.describeToolActionDeniedWithAdvertised(
                action_arena.allocator(),
                call,
                null,
                "Cancelled",
                &.{},
            );
            const entry_id = try writeCompletedToolStatus(sink, .cancelled, action);
            const replayed_output = try writeCommandReplay(
                app,
                sink,
                presentation.output_replay,
                call.id,
            );
            try sink.attachHistoricalCancelledCommandDetail(
                entry_id,
                call,
                presentation.command_artifact_handle,
                replayed_output,
            );
        }

        fn writeExecutionHistory(app: *App, execution: types.ExecutionMemory) !void {
            var sink = LiveHistorySink(App){ .app = app };
            return writeExecutionHistoryToSink(app, &sink, execution);
        }

        fn writeExecutionHistoryToSink(
            app: *App,
            sink: anytype,
            execution: types.ExecutionMemory,
        ) !void {
            for (execution.tool_steps) |step| {
                if (step.assistant) |assistant| {
                    if (assistant.len > 0) try writeAssistantHistoryMarkdownToSink(app, sink, assistant);
                }

                for (step.tool_calls) |call| {
                    if (findPersistedToolResult(step.tool_results, call.id)) |result| {
                        try writeCompletedToolResult(app, sink, call, result);
                        try writePermissionFeedback(sink, result.permission_feedback);
                    } else {
                        try writeUnreportedToolStatus(app, sink, call);
                    }
                }

                for (step.tool_results) |result| {
                    if (!hasPersistedToolCall(step.tool_calls, result.tool_call_id)) {
                        try writeUnpairedToolResult(app, sink, result);
                        try writePermissionFeedback(sink, result.permission_feedback);
                    }
                }
            }
            try writePermissionFeedback(sink, execution.steering);
        }

        fn writePermissionFeedback(sink: anytype, feedback: []const []const u8) !void {
            for (feedback) |text| {
                if (text.len == 0) continue;
                try sink.appendUserTurn(.{
                    .text = @constCast(text),
                }, true);
            }
        }

        fn findPersistedToolResult(
            results: []const types.PersistedToolResult,
            tool_call_id: []const u8,
        ) ?types.PersistedToolResult {
            for (results) |result| {
                if (std.mem.eql(u8, result.tool_call_id, tool_call_id)) return result;
            }
            return null;
        }

        fn hasPersistedToolCall(
            calls: []const types.ToolCall,
            tool_call_id: []const u8,
        ) bool {
            for (calls) |call| {
                if (std.mem.eql(u8, call.id, tool_call_id)) return true;
            }
            return false;
        }

        fn writeCompletedToolResult(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) !void {
            if (try writeAnsweredQuestionResult(app, sink, call, result)) return;
            if (try writeCommittedFilePresentation(app, sink, call, result)) return;

            const is_command = try captured_command.isToolCall(
                app.alloc,
                call.name,
                call.arguments_json,
            );
            const context_deferred = types.isContextDeferredToolResult(result);
            const deferred = types.isDeferredToolResult(result);
            const permission_denial_reason = tool_result_errors.toolPermissionDenialReason(result.output);

            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer action_arena.deinit();
            const command_decision = if (is_command)
                try tool_presentation.commandOutcomeDecision(
                    action_arena.allocator(),
                    result.command_process_presentation,
                )
            else
                null;
            const terminal_action_decision = if (std.mem.eql(u8, call.name, "terminal"))
                try tool_presentation.terminalActionOutcomeDecision(
                    action_arena.allocator(),
                    result.terminal_action_presentation,
                )
            else
                null;
            const outcome_decision = command_decision orelse terminal_action_decision;
            const formatted_action_base = if (deferred)
                try app.describeToolActionDeniedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    null,
                    if (context_deferred)
                        types.context_deferred_tool_status_label
                    else
                        types.deferred_tool_result_output,
                    &.{},
                )
            else if (permission_denial_reason) |reason|
                try app.describeToolActionDeniedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    null,
                    tool_admission.permissionDeniedStatusLabel(reason),
                    &.{},
                )
            else if (outcome_decision) |decision|
                try app.describeToolActionDeniedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    null,
                    decision.label,
                    &.{},
                )
            else if (result.status == .success)
                try app.describeToolActionCompletedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    null,
                    &.{},
                )
            else
                try app.describeToolActionDeniedWithAdvertised(
                    action_arena.allocator(),
                    call,
                    null,
                    "Failed",
                    &.{},
                );
            const formatted_action = if (outcome_decision) |decision|
                if (decision.detail) |detail|
                    try std.fmt.allocPrint(
                        action_arena.allocator(),
                        "{s}: {s}",
                        .{ formatted_action_base, detail },
                    )
                else
                    formatted_action_base
            else
                formatted_action_base;
            const action = try app.alloc.dupe(u8, formatted_action);
            defer app.alloc.free(action);

            const outcome: types.ToolOutcomeKind = if (context_deferred)
                .deferred
            else if (deferred or permission_denial_reason != null)
                .denied
            else if (outcome_decision) |decision|
                decision.outcome
            else if (result.status == .success)
                .completed
            else
                .failed;
            const entry_id = try writeCompletedToolStatus(
                sink,
                outcome,
                action,
            );
            if (!is_command or deferred or permission_denial_reason != null) {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
                return;
            }
            if (!sink.materializeCommandReplay()) {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
                return;
            }
            const wrote_command_output =
                try writeCommandReplay(
                    app,
                    sink,
                    result.command_output_replay,
                    result.tool_call_id,
                ) or
                try writeStoredCommandOutput(app, sink, result) or
                try writeSavedCommandOutput(sink, result.output);
            // Attach terminal detail after historical command chunks so typed
            // process presentation joins the existing block instead of
            // synthesizing a second, empty command-output block.
            if (wrote_command_output) {
                try sink.attachHistoricalToolDetailAfterCommandOutput(
                    entry_id,
                    call,
                    result,
                );
            } else {
                try sink.attachHistoricalToolDetail(entry_id, call, result);
            }
            if (wrote_command_output) {
                sink.attachHistoricalCommandOutput(entry_id);
                return;
            }

            debug_trace.logf(
                "session",
                "resume command replay fell back to raw result call_id={s}",
                .{result.tool_call_id},
            );
            try writeReplayResultFallback(sink, result.output);
        }

        fn writeCommandReplay(
            app: *App,
            sink: anytype,
            replay_value: ?types.CommandOutputReplay,
            call_id: []const u8,
        ) !bool {
            const replay = replay_value orelse return false;
            const descriptor = switch (replay) {
                .available => |value| value,
                .unavailable => {
                    debug_trace.logf(
                        "session",
                        "resume command replay unavailable call_id={s}",
                        .{call_id},
                    );
                    return false;
                },
            };
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return false;
            const capability = loaded.childCapability() catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay capability unavailable handle_bytes={d} err={s}",
                    .{ descriptor.handle.len, @errorName(err) },
                );
                return false;
            };
            if (!validateCommandReplay(app.alloc, capability, descriptor)) {
                debug_trace.logf(
                    "session",
                    "resume command replay invalid handle_bytes={d}",
                    .{descriptor.handle.len},
                );
                return false;
            }

            var reader = command_replay_store.Reader.open(
                app.alloc,
                capability,
                descriptor,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay reopen failed handle_bytes={d} err={s}",
                    .{ descriptor.handle.len, @errorName(err) },
                );
                return false;
            };
            defer reader.deinit();
            var wrote = false;
            while (try reader.next(app.alloc)) |frame| {
                defer app.alloc.free(frame.payload);
                try sink.appendCommandOutput(frame.stream, frame.payload);
                wrote = true;
            }
            if (wrote) try sink.finishCommandOutput();
            return wrote;
        }

        fn validateCommandReplay(
            alloc: Allocator,
            capability: *session_child_store.SessionChildCapability,
            descriptor: types.CommandOutputReplayDescriptor,
        ) bool {
            var reader = command_replay_store.Reader.open(
                alloc,
                capability,
                descriptor,
            ) catch return false;
            defer reader.deinit();
            while (reader.nextByte() catch return false) |_| {}
            return true;
        }

        fn writeCommittedFilePresentation(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) !bool {
            const presentation = result.committed_file_presentation orelse return false;
            if (result.status != .success or
                (!std.mem.eql(u8, result.tool_name, "write_file") and
                    !std.mem.eql(u8, result.tool_name, "edit_file")) or
                !@hasDecl(App, "preparePersistedFileDiff") or
                !@hasDecl(App, "registerAndEmitDiffBlock")) return false;

            const payload = app.preparePersistedFileDiff(presentation) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume committed file presentation unavailable call_id={s} err={s}",
                    .{ result.tool_call_id, @errorName(err) },
                );
                return false;
            };
            var owns_payload = true;
            errdefer if (owns_payload) diff.freeDiffEntryPayload(std.heap.c_allocator, payload);

            var action_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer action_arena.deinit();
            const base = try app.describeToolActionCompletedWithAdvertised(
                action_arena.allocator(),
                call,
                presentation.path,
                &.{},
            );
            const action = try tool_presentation.formatToolStatusWithStats(
                action_arena.allocator(),
                base,
                presentation.additions,
                presentation.deletions,
                .{
                    .added = ui_render.diff_added_marker_style,
                    .removed = ui_render.diff_removed_marker_style,
                },
            );
            const entry_id = try writeCompletedToolStatus(sink, .completed, action);
            try sink.appendDiff(payload);
            owns_payload = false;

            if (presentation.lifecycle_id) |lifecycle_id| {
                try sink.attachHistoricalToolDetailWithLifecycle(
                    entry_id,
                    call,
                    result,
                    lifecycle_id,
                );
                return true;
            }
            try sink.attachHistoricalToolDetail(entry_id, call, result);
            return true;
        }

        fn writeAnsweredQuestionResult(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
            result: types.PersistedToolResult,
        ) !bool {
            if (result.status != .success or
                !std.mem.eql(u8, result.tool_name, "ask_user_question") or
                !@hasDecl(App, "writeHistoricalQuestionResolution")) return false;

            var answer_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer answer_arena.deinit();
            const answers = (try question_answer.decodeJson(
                answer_arena.allocator(),
                result.output,
            )) orelse return false;

            const entry_id = try sink.appendQuestionResolution(answers);
            try sink.attachHistoricalToolDetail(entry_id, call, result);
            return true;
        }

        fn writeStoredCommandOutput(
            app: *App,
            sink: anytype,
            result: types.PersistedToolResult,
        ) !bool {
            const handle = result.output_handle orelse return false;
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return false;
            const capability = loaded.childCapability() catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay could not open result handle={s} err={s}",
                    .{ handle, @errorName(err) },
                );
                return false;
            };
            const output = result_store.readForReplayManaged(
                app.alloc,
                capability,
                handle,
                result.stored_output_bytes,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "resume command replay could not read result handle={s} err={s}",
                    .{ handle, @errorName(err) },
                );
                return false;
            };
            defer app.alloc.free(output);
            return writeSavedCommandOutput(sink, output);
        }

        fn writeUnreportedToolStatus(
            app: *App,
            sink: anytype,
            call: types.ToolCall,
        ) !void {
            const status = try std.fmt.allocPrint(
                app.alloc,
                "● Tool completion was not reported: {s}",
                .{call.name},
            );
            defer app.alloc.free(status);
            const entry_id = try writeCompletedToolStatus(sink, .failed, status);
            try sink.attachHistoricalToolCallWithoutResult(entry_id, call);
        }

        fn writeUnpairedToolResult(
            app: *App,
            sink: anytype,
            result: types.PersistedToolResult,
        ) !void {
            const status = try std.fmt.allocPrint(
                app.alloc,
                "● {s} tool result: {s}",
                .{ @tagName(result.status), result.tool_name },
            );
            defer app.alloc.free(status);
            _ = try writeCompletedToolStatus(sink, switch (result.status) {
                .success => .completed,
                .failure => .failed,
            }, status);
            try writeReplayResultFallback(sink, result.output);
        }

        fn writeCompletedToolStatus(
            sink: anytype,
            kind: types.ToolOutcomeKind,
            status: []const u8,
        ) !u32 {
            return sink.appendToolStatus(kind, status);
        }

        fn writeSavedCommandOutput(sink: anytype, output: []const u8) !bool {
            var wrote = false;
            wrote = try writeCommandEnvelope(sink, output, "<stdout>\n", "\n</stdout>", .stdout) or wrote;
            wrote = try writeCommandEnvelope(sink, output, "<stderr>\n", "\n</stderr>", .stderr) or wrote;
            if (wrote) try sink.finishCommandOutput();
            return wrote;
        }

        fn writeCommandEnvelope(
            sink: anytype,
            output: []const u8,
            open: []const u8,
            close: []const u8,
            stream: command_output_content.Stream,
        ) !bool {
            const text = envelopeBody(output, open, close) orelse return false;
            if (text.len == 0) return false;
            var remaining = text;
            while (std.mem.findScalar(u8, remaining, '\n')) |newline_index| {
                try sink.appendCommandOutput(stream, remaining[0 .. newline_index + 1]);
                remaining = remaining[newline_index + 1 ..];
            }
            if (remaining.len > 0) try sink.appendCommandOutput(stream, remaining);
            return true;
        }

        fn envelopeBody(output: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
            const start = std.mem.find(u8, output, open) orelse return null;
            const body = output[start + open.len ..];
            const end = std.mem.find(u8, body, close) orelse return null;
            return body[0..end];
        }

        fn writeReplayResultFallback(sink: anytype, output: []const u8) !void {
            if (output.len == 0) return;
            try sink.appendRaw(output);
            if (!std.mem.endsWith(u8, output, "\n")) try sink.appendRaw("\n");
        }

        fn formatBackgroundReplayContext(app: *App, entry: types.BackgroundCommandHistoryTurn) ![]u8 {
            if (!@hasDecl(@TypeOf(app.background), "snapshotTaskByLogPath")) {
                return session_runtime.formatBackgroundHistoryContext(app.alloc, entry);
            }

            const task = try app.background.snapshotTaskByLogPath(app.alloc, entry.log_path);
            if (task) |snapshot| {
                defer snapshot.deinit(app.alloc);
                if (snapshot.state == .running) {
                    if (snapshot.server_url) |url| {
                        return std.fmt.allocPrint(app.alloc, "Session event: the previous background server is still running. Background #{d}; log: {s}; URL: {s}.", .{ snapshot.id, snapshot.log_path, url });
                    }
                    if (snapshot.expect_url) {
                        return std.fmt.allocPrint(app.alloc, "Session event: the previous background server is still running. Background #{d}; log: {s}; URL is still pending.", .{ snapshot.id, snapshot.log_path });
                    }
                    return std.fmt.allocPrint(app.alloc, "Session event: the previous background command is still running. Background #{d}; log: {s}.", .{ snapshot.id, snapshot.log_path });
                }
            }

            return std.fmt.allocPrint(app.alloc, "Session event: a previous background command was recorded at {s}, but it is no longer live in this workspace.", .{entry.log_path});
        }

        fn AssistantHistoryMarkdownReplay(comptime Sink: type) type {
            return struct {
                sink: *Sink,

                const Self = @This();

                fn flushText(self: *Self, out: *std.ArrayList(u8)) !void {
                    if (out.items.len == 0) return;
                    try self.sink.appendAssistantText(out.items);
                    out.clearRetainingCapacity();
                }

                fn deliverTable(
                    raw: *anyopaque,
                    table: assistant_presentation.TablePayload,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantTable(table);
                }

                fn deliverCodeBlock(
                    raw: *anyopaque,
                    block: assistant_presentation.CodeBlockPayload,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantCodeBlock(block);
                }

                fn deliverThematicRule(
                    raw: *anyopaque,
                    out: *std.ArrayList(u8),
                ) anyerror!void {
                    const self: *Self = @ptrCast(@alignCast(raw));
                    try self.flushText(out);
                    try self.sink.appendAssistantThematicRule();
                }
            };
        }

        fn writeAssistantHistoryMarkdown(app: *App, text: []const u8) !void {
            var sink = LiveHistorySink(App){ .app = app };
            return writeAssistantHistoryMarkdownToSink(app, &sink, text);
        }

        fn writeAssistantHistoryMarkdownToSink(
            app: *App,
            sink: anytype,
            text: []const u8,
        ) !void {
            var processor = assistant_presentation.MarkdownProcessor{};
            defer processor.deinit(app.alloc);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(app.alloc);
            const Sink = @TypeOf(sink.*);
            const Replay = AssistantHistoryMarkdownReplay(Sink);
            var replay = Replay{ .sink = sink };
            var table_completion = assistant_presentation.TableCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverTable,
            };
            var code_completion = assistant_presentation.CodeBlockCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverCodeBlock,
            };
            var thematic_rule_completion = assistant_presentation.ThematicRuleCompletion{
                .ctx = &replay,
                .deliver = Replay.deliverThematicRule,
            };
            const completions = assistant_presentation.MarkdownCompletions{
                .table = &table_completion,
                .code = &code_completion,
                .thematic_rule = &thematic_rule_completion,
            };

            try processor.pushWithCompletions(app.alloc, text, &out, completions);
            try processor.flushWithCompletions(app.alloc, &out, completions);
            try replay.flushText(&out);
            try sink.appendAssistantText("\n");
        }

        fn closeWritableSession(
            app: *App,
            log_options: session_log.Options,
        ) void {
            app.session_persistence.resume_handoff_intent = .none;
            _ = closeWritableSessionWithResumeHandoff(app, log_options);
        }

        fn closeWritableSessionWithResumeHandoff(
            app: *App,
            log_options: session_log.Options,
        ) ?ResumeHandoff {
            const handoff_intent = app.session_persistence.resume_handoff_intent;
            app.session_persistence.resume_handoff_intent = .none;
            if (comptime @hasField(@TypeOf(app.session), "usage")) {
                app.session.usage.cancelReconciliation();
                app.session.usage.finishProfilePublicationsBeforeShutdown();
                app.session.usage.configureCheckpointSink(null);
            }
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            discardAnyPendingCancelledCommand(app, "writable_session_close");
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return null;
            var resume_boundary_valid = false;
            if (handoff_intent != .none) {
                var settlement_failed = false;
                settleResumeBoundary(app, loaded, log_options) catch |err| {
                    settlement_failed = true;
                    debug_trace.logf(
                        "session",
                        "resume handoff boundary invalid session={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    );
                };
                resume_boundary_valid = !settlement_failed;
            } else {
                settleDurableState(app, loaded, log_options) catch |err| {
                    debug_trace.logf(
                        "session",
                        "final persistence settlement failed session={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    );
                };
            }
            loaded.writeCheckpointIfDue(app.alloc, true, log_options) catch |err| {
                debug_trace.logf(
                    "session",
                    "final checkpoint failed session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
            };
            const should_create_handoff = resume_boundary_valid and
                shouldCreateResumeHandoff(.{
                    .intent = handoff_intent,
                    .has_writable_session = true,
                    .is_pristine = session_store.isPristineStartedSession(loaded),
                    .has_unresolved_degraded_tail = loaded.degradedTail() != null,
                });
            const handoff: ?ResumeHandoff = if (should_create_handoff) blk: {
                const session_id = app.alloc.dupe(u8, loaded.active_id) catch |err| {
                    debug_trace.logf(
                        "session",
                        "resume handoff unavailable session={s} err={s}",
                        .{ loaded.active_id, @errorName(err) },
                    );
                    break :blk null;
                };
                break :blk .{ .session_id = session_id };
            } else null;
            if (comptime @hasField(App, "background") and
                @hasDecl(@TypeOf(app.background), "detachManagedPersistence"))
            {
                app.background.detachManagedPersistence(
                    std.heap.c_allocator,
                    loaded.active_id,
                );
            }
            if (comptime @hasDecl(
                @TypeOf(app.session),
                "clearWebFetchArtifacts",
            )) {
                app.session.clearWebFetchArtifacts();
            }
            disableSubagentHost(app);
            loaded.deinit(app.alloc);
            app.session_persistence.writable = null;
            return handoff;
        }

        fn configureWebFetchArtifacts(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
        ) void {
            if (comptime !@hasDecl(
                @TypeOf(app.session),
                "configureWebFetchArtifacts",
            )) return;

            const store = app.session_persistence.store orelse return;
            const session_dir = session_store.sessionDirPath(
                app.alloc,
                store.sessions_dir,
                loaded.active_id,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "interactive web fetch artifact setup failed session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
                app.session.clearWebFetchArtifacts();
                return;
            };
            defer app.alloc.free(session_dir);
            app.session.configureWebFetchArtifacts(app.alloc, session_dir);
        }

        fn enableSubagentHost(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
        ) void {
            disableSubagentHost(app);
            const store = if (app.session_persistence.store) |*value| value else return;
            app.session_persistence.subagent_host = subagent_tool_host.Runtime.create(
                app.alloc,
                store,
                loaded.active_id,
                subagentAuthorityResolver(app),
                if (comptime @hasDecl(App, "runSubagentChild"))
                    .{ .context = app, .run_fn = App.runSubagentChild }
                else
                    .{},
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "interactive subagent host unavailable session={s} err={s}",
                    .{ loaded.active_id, @errorName(err) },
                );
                return;
            };
        }

        fn subagentAuthorityResolver(app: *App) subagent_authority.HostResolver {
            return .{ .context = app, .resolve_fn = resolveSubagentAuthority };
        }

        fn resolveSubagentAuthority(
            raw: ?*anyopaque,
            alloc: Allocator,
            root_id: []const u8,
        ) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
            const app: *App = @ptrCast(@alignCast(raw.?));
            if (comptime @hasField(@TypeOf(app.permission_state), "authority_mutex")) {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            }
            defer if (comptime @hasField(@TypeOf(app.permission_state), "authority_mutex")) {
                app.permission_state.authority_mutex.unlock(io_mod.getIo());
            };
            const writable = if (app.session_persistence.writable) |*value| value else return error.HostAuthorityUnavailable;
            if (!std.mem.eql(u8, writable.active_id, root_id)) {
                return error.HostAuthorityUnavailable;
            }
            const integrations = if (comptime @hasDecl(App, "snapshotMcpToolNames"))
                try app.snapshotMcpToolNames(alloc)
            else
                try alloc.alloc([]u8, 0);
            defer {
                for (integrations) |name| alloc.free(name);
                alloc.free(integrations);
            }
            var mcp_view: ?mcp_access.View = if (comptime @hasDecl(App, "snapshotMcpAccessView"))
                try app.snapshotMcpAccessView(
                    alloc,
                    root_id,
                    root_id,
                    app.permission_engine.rules,
                    !permissions.rulesDenyAllTargetsForTool(app.permission_engine.rules, "mcp_features"),
                )
            else
                null;
            defer if (mcp_view) |*view| view.deinit(alloc);
            var permission_state = app.session.snapshotPermissionState(alloc) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.HostAuthorityUnavailable,
            };
            defer permission_state.deinit(alloc);
            return subagent_tool_host.captureHostAuthorityWithMcpView(
                alloc,
                .{
                    .tool_set = app.toolAdvertisementSet(),
                    .mode = .full,
                },
                integrations,
                if (comptime @hasField(App, "permission_engine")) app.permission_engine.rules else .{},
                if (comptime @hasField(App, "permission_engine")) app.permission_engine.grants.items else &.{},
                permission_state,
                if (mcp_view) |*view| view else null,
            );
        }

        fn convergeDegraded(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            log_options: session_log.Options,
        ) !void {
            try convergeDegradedAt(
                app,
                loaded,
                log_options,
                io_mod.milliTimestamp(),
            );
        }

        fn convergeDegradedAt(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            log_options: session_log.Options,
            now_ms: i64,
        ) !void {
            if (loaded.degradedTail() == null) return;
            var current = try snapshotCurrentState(app, loaded.state, now_ms);
            defer current.deinit(app.alloc);
            try loaded.retryDegradedWithStateReplacement(
                app.alloc,
                current,
                log_options,
            );
            app.session_persistence.degraded_warning_emitted = false;
        }

        fn settleResumeBoundary(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            log_options: session_log.Options,
        ) !void {
            try settleDurableState(app, loaded, log_options);
            try loaded.validateResumeBoundary(app.alloc, log_options);
        }

        fn settleDurableState(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            log_options: session_log.Options,
        ) !void {
            try convergeDegraded(app, loaded, log_options);
            const usage_dirty = if (comptime @hasField(@TypeOf(app.session), "usage"))
                app.session.usage.isDirty()
            else
                false;
            if (loaded.needsFinalStateReplacement(usage_dirty)) {
                try commitCurrentStateReplacementStrict(
                    app,
                    loaded,
                    .compaction,
                    log_options,
                    false,
                );
            }
        }

        fn commitCurrentStateReplacement(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            reason: session_event.ReplacementReason,
            log_options: session_log.Options,
            clear_recovery_checkpoint: bool,
        ) !void {
            commitCurrentStateReplacementStrict(
                app,
                loaded,
                reason,
                log_options,
                clear_recovery_checkpoint,
            ) catch |err| {
                try warnDegraded(app, err);
            };
        }

        fn commitCurrentStateReplacementStrict(
            app: *App,
            loaded: *session_store.LoadedWritableSession,
            reason: session_event.ReplacementReason,
            log_options: session_log.Options,
            clear_recovery_checkpoint: bool,
        ) !void {
            const now_ms = io_mod.milliTimestamp();
            var current = try snapshotCurrentState(app, loaded.state, now_ms);
            defer current.deinit(app.alloc);
            if (clear_recovery_checkpoint) {
                if (current.recovery_checkpoint) |*checkpoint| checkpoint.deinit(app.alloc);
                current.recovery_checkpoint = null;
            }
            _ = try loaded.commitStateReplacement(
                app.alloc,
                current,
                reason,
                .retry_expected_tail,
                log_options,
            );
            if (comptime @hasField(@TypeOf(app.session), "usage")) {
                if (current.usage) |usage| {
                    app.session.usage.markClean(usage);
                }
            }
        }

        pub fn commitPermissionState(
            app: *App,
            permission_state: session_permission_state.State,
        ) !void {
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value|
                value
            else
                return error.SessionPersistenceUnavailable;
            const now_ms = io_mod.milliTimestamp();
            var current = try snapshotCurrentState(app, loaded.state, now_ms);
            defer current.deinit(app.alloc);
            current.permission_state.deinit(app.alloc);
            current.permission_state = try session_permission_state.dupe(
                app.alloc,
                permission_state,
            );
            _ = try loaded.commitStateReplacement(
                app.alloc,
                current,
                .compaction,
                .retry_expected_tail,
                .{},
            );
        }

        fn commitJsHostSnapshot(app: *App, boundary: []const u8) void {
            if (comptime !@hasField(App, "session_persistence")) return;
            if (comptime !runtime_profile.allows(App, .js_host_sessions)) return;
            commitJsHostSnapshotEnabled(app, boundary);
        }

        fn commitJsHostSnapshotEnabled(app: *App, boundary: []const u8) void {
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const owner = if (app.session_persistence.js_host_session) |*value|
                value
            else
                return;
            var next = snapshotCurrentState(
                app,
                owner.state,
                io_mod.milliTimestamp(),
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_commit outcome=dropped boundary={s} id={s} err={s}",
                    .{ boundary, owner.state.id, @errorName(err) },
                );
                return;
            };
            var next_owned = true;
            defer if (next_owned) next.deinit(app.alloc);
            const revision = app.session_persistence.js_host_store.commit(
                app.alloc,
                next,
                owner.revision,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=js_host_session_commit outcome=dropped boundary={s} id={s} expected_revision={s} err={s}",
                    .{
                        boundary,
                        owner.state.id,
                        owner.revision orelse "",
                        @errorName(err),
                    },
                );
                return;
            };

            if (owner.revision) |old_revision| app.alloc.free(old_revision);
            owner.state.deinit(app.alloc);
            owner.state = next;
            owner.revision = revision;
            next_owned = false;
            if (comptime @hasField(@TypeOf(app.session), "usage")) {
                if (owner.state.usage) |usage| app.session.usage.markClean(usage);
            }
        }

        fn snapshotCurrentState(
            app: *App,
            base_state: session_codec.DurableSessionState,
            now_ms: i64,
        ) !session_codec.DurableSessionState {
            const preferences = app.session_persistence.session_preferences orelse
                base_state.preferences;
            const id = try app.alloc.dupe(u8, base_state.id);
            errdefer app.alloc.free(id);
            const origin = try app.alloc.dupe(
                u8,
                base_state.origin_workspace_root,
            );
            errdefer app.alloc.free(origin);
            const workspace = try app.alloc.dupe(u8, app.workspace_root);
            errdefer app.alloc.free(workspace);
            const owned_preferences = try preferences.dupe(app.alloc);
            errdefer {
                var value = owned_preferences;
                value.deinit(app.alloc);
            }
            const history = try app.session.snapshotHistory(app.alloc);
            errdefer session_runtime.freeHistoryTurnSlice(app.alloc, history);
            const permission_state = try app.session.snapshotPermissionState(app.alloc);
            errdefer {
                var value = permission_state;
                value.deinit(app.alloc);
            }
            const usage = try app.session.usage.snapshot(app.alloc);
            const recovery_checkpoint = if (base_state.recovery_checkpoint) |checkpoint|
                try checkpoint.dupe(app.alloc)
            else
                null;
            errdefer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(app.alloc);
            return .{
                .id = id,
                .origin_workspace_root = origin,
                .workspace_root = workspace,
                .created_at_ms = base_state.created_at_ms,
                .updated_at_ms = now_ms,
                .conversation_language = app.session.languageSnapshot(),
                .preferences = owned_preferences,
                .history = history,
                .context_history_start = app.session.contextHistoryStart(),
                .total_input_tokens = app.total_input_tokens,
                .total_output_tokens = app.total_output_tokens,
                .permission_state = permission_state,
                .usage = usage,
                .recovery_checkpoint = recovery_checkpoint,
            };
        }

        fn freshState(
            app: *App,
            preferences: session_codec.DurableSessionPreferences,
        ) !session_codec.DurableSessionState {
            const now = io_mod.milliTimestamp();
            const id = try session_store.generateSessionId(app.alloc);
            errdefer app.alloc.free(id);
            const origin = try app.alloc.dupe(u8, app.workspace_root);
            errdefer app.alloc.free(origin);
            const workspace = try app.alloc.dupe(u8, app.workspace_root);
            errdefer app.alloc.free(workspace);
            const owned_preferences = try preferences.dupe(app.alloc);
            errdefer {
                var value = owned_preferences;
                value.deinit(app.alloc);
            }
            const history = try app.alloc.alloc(types.HistoryTurn, 0);
            errdefer app.alloc.free(history);
            const permission_state = try app.session.snapshotPermissionState(app.alloc);
            errdefer {
                var value = permission_state;
                value.deinit(app.alloc);
            }
            const usage = try app.session.usage.snapshot(app.alloc);
            return .{
                .id = id,
                .origin_workspace_root = origin,
                .workspace_root = workspace,
                .created_at_ms = now,
                .updated_at_ms = now,
                .conversation_language = app.session.languageSnapshot(),
                .preferences = owned_preferences,
                .history = history,
                .total_input_tokens = 0,
                .total_output_tokens = 0,
                .permission_state = permission_state,
                .usage = usage,
            };
        }

        fn restoreRuntimePreferences(
            app: *App,
            preferences: session_codec.DurableSessionPreferences,
        ) !void {
            try provider_runtime.replaceSelection(app, preferences.provider, preferences.model);
            if (app.session_persistence.process_model_override) |model| {
                try provider_runtime.replaceModel(app, model);
            }
            try app.worker.syncQueuedPromptModel(
                std.heap.c_allocator,
                provider_runtime.model(app),
            );
            app.effort = preferences.effort;
            app.fast_mode = preferences.fast_mode;
            app.worker.syncQueuedPromptEffort(preferences.effort);
            app.worker.syncQueuedPromptFastMode(preferences.fast_mode);
        }

        fn applySessionPreferencePatch(
            app: *App,
            patch: SessionPreferencePatch,
        ) !void {
            try applyPreferencePatch(
                app.alloc,
                &app.session_persistence.session_preferences,
                patch,
            );
        }

        fn warnDegraded(app: *App, err: anyerror) !void {
            if (app.session_persistence.degraded_warning_emitted) {
                debug_trace.logf(
                    "session",
                    "canonical persistence remains degraded err={s}",
                    .{@errorName(err)},
                );
                return;
            }
            app.session_persistence.degraded_warning_emitted = true;
            try warnNonDurable(app, "session persistence degraded", err);
        }

        fn warnNonDurable(
            app: *App,
            label: []const u8,
            err: anyerror,
        ) !void {
            const notice = try std.fmt.allocPrint(
                app.alloc,
                "{s}: {s}; continuing non-durably",
                .{ label, @errorName(err) },
            );
            defer app.alloc.free(notice);
            try app.writeDomainNotice(.{
                .topic = "session",
                .tone = .warning,
                .body = notice,
            }, true);
        }
    };
}

fn replacePreferences(
    alloc: Allocator,
    target: *?session_codec.DurableSessionPreferences,
    source: session_codec.DurableSessionPreferences,
) !void {
    const replacement = try source.dupe(alloc);
    if (target.*) |*current| current.deinit(alloc);
    target.* = replacement;
}

fn applyPreferencePatch(
    alloc: Allocator,
    target: *?session_codec.DurableSessionPreferences,
    patch: SessionPreferencePatch,
) !void {
    var current = target.* orelse return error.SessionPreferencesUnavailable;
    if (patch.provider) |provider| current.provider = provider;
    if (patch.model) |model| {
        const replacement = try alloc.dupe(u8, model);
        alloc.free(current.model);
        current.model = replacement;
    }
    if (patch.effort) |effort| current.effort = effort;
    if (patch.fast_mode) |fast_mode| current.fast_mode = fast_mode;
    target.* = current;
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const TestResumeTarget = union(enum) {
    pick,
    last,
    id: []u8,

    fn deinit(self: *TestResumeTarget, alloc: Allocator) void {
        switch (self.*) {
            .pick, .last => {},
            .id => |id| alloc.free(id),
        }
        self.* = .last;
    }
};

const FakeBackground = struct {
    source_session_id: []u8 = &.{},
    detached: bool = false,

    fn deinit(self: *FakeBackground) void {
        if (self.source_session_id.len > 0) {
            std.heap.c_allocator.free(self.source_session_id);
        }
        self.* = .{};
    }

    fn restoreFromManagedPersistence(
        self: *FakeBackground,
        alloc: Allocator,
        _: *session_child_store.SessionChildCapability,
        source_session_id: []const u8,
        _: []const u8,
    ) !void {
        if (self.source_session_id.len > 0) alloc.free(self.source_session_id);
        self.source_session_id = try alloc.dupe(u8, source_session_id);
        self.detached = false;
    }

    fn detachManagedPersistence(
        self: *FakeBackground,
        _: Allocator,
        source_session_id: []const u8,
    ) void {
        if (std.mem.eql(u8, self.source_session_id, source_session_id)) {
            self.detached = true;
        }
    }
};

const FakeWorker = struct {
    model: std.ArrayList(u8) = .empty,
    effort: types.ReasoningEffort = .auto,
    fast_mode: bool = false,

    fn deinit(self: *FakeWorker, alloc: Allocator) void {
        self.model.deinit(alloc);
        self.* = .{};
    }

    pub fn queuedPromptCount(self: *const FakeWorker) usize {
        _ = self;
        return 0;
    }

    fn syncQueuedPromptModel(
        self: *FakeWorker,
        alloc: Allocator,
        model: []const u8,
    ) !void {
        self.model.clearRetainingCapacity();
        try self.model.appendSlice(alloc, model);
    }

    fn syncQueuedPromptEffort(
        self: *FakeWorker,
        effort: types.ReasoningEffort,
    ) void {
        self.effort = effort;
    }

    fn syncQueuedPromptFastMode(self: *FakeWorker, fast_mode: bool) void {
        self.fast_mode = fast_mode;
    }
};

const PromptCard = struct {
    text: []u8,
    has_prior_turns: bool,

    fn deinit(self: *PromptCard, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

const AssistantPresentationEvent = enum {
    text,
    table,
    code_block,
    thematic_rule,
    raw_transcript,
};

const CapturedCommandOutput = struct {
    stream: command_output_content.Stream,
    text: []u8,
};

const ReplayEvent = enum {
    command_output_chunk,
    command_output_summary_flush,
    completed_tool_status,
    raw_transcript,
};

const TestApp = struct {
    alloc: Allocator,
    workspace_root: []u8,
    session: session_runtime.SessionRuntime = .{ .max_history_turns = 8 },
    session_persistence: Persistence = .{},
    session_title: std.ArrayList(u8) = .empty,
    terminal_title_label: [128]u8 = undefined,
    terminal_title_label_len: usize = 0,
    input_runtime: core_input_runtime.Runtime = .{},
    terminal_input_runtime: ui_input.Runtime = .{},
    shell: transcript_runtime.TranscriptRuntime = .{},
    metrics: types.Metrics = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    next_image_id: usize = 1,
    requested_resume: ?TestResumeTarget = null,
    terminal: shell_runtime.TerminalState = .{},
    stream: types.StreamState = .{},
    background: FakeBackground = .{},
    worker: FakeWorker = .{},
    selected_model: std.ArrayList(u8) = .empty,
    effort: types.ReasoningEffort = .auto,
    fast_mode: bool = false,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,
    notices: std.ArrayList([]u8) = .empty,
    cards: std.ArrayList(PromptCard) = .empty,
    transcript: std.ArrayList(u8) = .empty,
    completed_tool_statuses: std.ArrayList([]u8) = .empty,
    completed_tool_outcomes: std.ArrayList(types.ToolOutcomeKind) = .empty,
    next_transcript_entry_id: u32 = 1,
    historical_question_entry_ids: std.ArrayList(u32) = .empty,
    historical_question_answer_count: usize = 0,
    historical_tool_detail_entry_ids: std.ArrayList(u32) = .empty,
    cancelled_command_detail_count: usize = 0,
    cancelled_command_artifact_handle: ?[]u8 = null,
    cancelled_command_replayed_output: bool = false,
    command_stdout: std.ArrayList(u8) = .empty,
    command_stderr: std.ArrayList(u8) = .empty,
    command_output_writes: std.ArrayList(CapturedCommandOutput) = .empty,
    command_output_flush_count: usize = 0,
    replay_events: std.ArrayList(ReplayEvent) = .empty,
    assistant_text: std.ArrayList(u8) = .empty,
    assistant_tables: std.ArrayList(assistant_presentation.TablePayload) = .empty,
    assistant_code_blocks: std.ArrayList(assistant_presentation.CodeBlockPayload) = .empty,
    assistant_thematic_rule_count: usize = 0,
    assistant_presentation_events: std.ArrayList(AssistantPresentationEvent) = .empty,
    fail_system_notice: bool = false,
    fail_assistant_table_append: bool = false,
    fail_assistant_code_block_append: bool = false,
    writable_seen_during_notice_failure: bool = false,
    fail_startup_resume_anchor: bool = false,
    startup_resume_anchor_count: usize = 0,
    startup_resume_anchor_saw_writable: bool = false,
    startup_resume_anchor_history_len: usize = 0,
    startup_resume_anchor_notice_count: usize = 0,
    action_description_allocates_scratch: bool = false,
    live_resume_prepare_count: usize = 0,
    live_resume_finish_count: usize = 0,
    live_resume_session_lock_deadline_ms: ?u64 = null,
    live_resume_commit_lock_deadline_ms: ?u64 = null,
    permission_engine: permissions.PermissionEngine = .{},
    permission_state: struct {
        authority_mutex: std.Io.Mutex = .init,
    } = .{},
    mcp_tool_names: std.ArrayList([]u8) = .empty,

    fn init(alloc: Allocator, workspace_root: []const u8) !TestApp {
        return .{
            .alloc = alloc,
            .workspace_root = try alloc.dupe(u8, workspace_root),
        };
    }

    fn toolAdvertisementSet(_: *const TestApp) tool_set_contract.ToolSet {
        return builtin_tools.advertisement_set;
    }

    fn snapshotMcpToolNames(self: *TestApp, alloc: Allocator) ![][]u8 {
        const names = try alloc.alloc([]u8, self.mcp_tool_names.items.len);
        var initialized: usize = 0;
        errdefer {
            for (names[0..initialized]) |name| alloc.free(name);
            alloc.free(names);
        }
        for (self.mcp_tool_names.items, names) |name, *owned| {
            owned.* = try alloc.dupe(u8, name);
            initialized += 1;
        }
        return names;
    }

    fn terminalTitle(self: *TestApp) host_capability.TerminalTitle {
        return .{
            .context = self,
            .set_fn = setTerminalTitleLabelForTest,
            .clear_fn = clearTerminalTitleForTest,
        };
    }

    fn setTerminalTitleLabelForTest(raw: ?*anyopaque, label: []const u8) void {
        const self: *TestApp = @ptrCast(@alignCast(raw.?));
        self.terminal_title_label_len = @min(label.len, self.terminal_title_label.len);
        @memcpy(
            self.terminal_title_label[0..self.terminal_title_label_len],
            label[0..self.terminal_title_label_len],
        );
    }

    fn clearTerminalTitleForTest(raw: ?*anyopaque) void {
        const self: *TestApp = @ptrCast(@alignCast(raw.?));
        self.terminal_title_label_len = 0;
    }

    fn terminalTitleLabelText(self: *const TestApp) []const u8 {
        return self.terminal_title_label[0..self.terminal_title_label_len];
    }

    fn deinit(self: *TestApp) void {
        self.input_runtime.deinit(self.alloc);
        self.terminal_input_runtime.deinit(self.alloc);
        self.session_title.deinit(self.alloc);
        self.shell.deinit(self.alloc);
        self.pending_images.deinit(self.alloc);
        for (self.notices.items) |notice| self.alloc.free(notice);
        self.notices.deinit(self.alloc);
        for (self.cards.items) |*card| card.deinit(self.alloc);
        self.cards.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        for (self.completed_tool_statuses.items) |status| self.alloc.free(status);
        self.completed_tool_statuses.deinit(self.alloc);
        self.completed_tool_outcomes.deinit(self.alloc);
        self.historical_question_entry_ids.deinit(self.alloc);
        self.historical_tool_detail_entry_ids.deinit(self.alloc);
        if (self.cancelled_command_artifact_handle) |handle| self.alloc.free(handle);
        self.command_stdout.deinit(self.alloc);
        self.command_stderr.deinit(self.alloc);
        for (self.command_output_writes.items) |write| self.alloc.free(write.text);
        self.command_output_writes.deinit(self.alloc);
        self.replay_events.deinit(self.alloc);
        self.assistant_text.deinit(self.alloc);
        for (self.assistant_tables.items) |*table| table.deinit(self.alloc);
        self.assistant_tables.deinit(self.alloc);
        for (self.assistant_code_blocks.items) |*block| block.deinit(self.alloc);
        self.assistant_code_blocks.deinit(self.alloc);
        self.assistant_presentation_events.deinit(self.alloc);
        Runtime(TestApp).deinitPersistence(self);
        if (self.requested_resume) |*target| target.deinit(self.alloc);
        self.session.deinit(self.alloc);
        self.background.deinit();
        self.worker.deinit(std.heap.c_allocator);
        self.selected_model.deinit(self.alloc);
        self.permission_engine.deinit(self.alloc);
        for (self.mcp_tool_names.items) |name| self.alloc.free(name);
        self.mcp_tool_names.deinit(self.alloc);
        self.alloc.free(self.workspace_root);
        self.* = undefined;
    }

    fn writeDomainNotice(self: *TestApp, notice: types.SemanticNotice, _: bool) !void {
        if (self.fail_system_notice) {
            self.writable_seen_during_notice_failure =
                self.session_persistence.writable != null;
            return error.TestSystemNoticeFailure;
        }
        try self.notices.append(self.alloc, if (notice.topic.len > 0)
            try std.fmt.allocPrint(
                self.alloc,
                "● {c}{s}: {s}",
                .{ std.ascii.toUpper(notice.topic[0]), notice.topic[1..], notice.body },
            )
        else
            try std.fmt.allocPrint(self.alloc, "● {s}", .{notice.body}));
    }

    fn commitStartupResumeReplayAnchor(self: *TestApp) !void {
        self.startup_resume_anchor_count += 1;
        self.startup_resume_anchor_saw_writable = self.session_persistence.writable != null;
        self.startup_resume_anchor_history_len = self.session.historyLen();
        self.startup_resume_anchor_notice_count = self.notices.items.len;
        if (self.fail_startup_resume_anchor) return error.TestStartupResumeAnchorFailure;
    }

    fn prepareLiveSessionResume(
        self: *TestApp,
        options: session_log.Options,
    ) !void {
        self.live_resume_prepare_count += 1;
        self.live_resume_session_lock_deadline_ms = options.session_lock_deadline_ms;
        self.live_resume_commit_lock_deadline_ms = options.commit_lock_deadline_ms;
        Runtime(TestApp).cancelSessionPicker(self);
        self.session.reset(self.alloc);
    }

    fn finishLiveSessionResume(self: *TestApp) !void {
        self.live_resume_finish_count += 1;
    }

    fn writeUserPromptCardWithSpacing(self: *TestApp, user: types.UserTurn, has_prior_turns: bool) !void {
        try self.cards.append(self.alloc, .{
            .text = try self.alloc.dupe(u8, user.text),
            .has_prior_turns = has_prior_turns,
        });
    }

    fn writeTranscript(self: *TestApp, text: []const u8, record: bool) !void {
        _ = record;
        try self.transcript.appendSlice(self.alloc, text);
        try self.replay_events.append(self.alloc, .raw_transcript);
        try self.assistant_presentation_events.append(self.alloc, .raw_transcript);
    }

    fn writeTranscriptClassified(self: *TestApp, text: []const u8, record: bool, _: anytype) !void {
        try self.writeTranscript(text, record);
    }

    fn writeCompletedToolStatus(
        self: *TestApp,
        kind: types.ToolOutcomeKind,
        text: []const u8,
        record: bool,
    ) !void {
        _ = record;
        const line = if (std.mem.endsWith(u8, text, "\n"))
            try self.alloc.dupe(u8, text)
        else
            try std.fmt.allocPrint(self.alloc, "{s}\n", .{text});
        try self.completed_tool_statuses.append(self.alloc, line);
        try self.completed_tool_outcomes.append(self.alloc, kind);
        try self.replay_events.append(self.alloc, .completed_tool_status);
    }

    fn writeCompletedToolStatusReturningEntryId(
        self: *TestApp,
        kind: types.ToolOutcomeKind,
        text: []const u8,
        record: bool,
    ) !u32 {
        try self.writeCompletedToolStatus(kind, text, record);
        return self.allocateTranscriptEntryId();
    }

    fn writeHistoricalQuestionResolution(
        self: *TestApp,
        answers: []const types.QuestionAnswer,
    ) !u32 {
        const entry_id = self.allocateTranscriptEntryId();
        try self.historical_question_entry_ids.append(self.alloc, entry_id);
        self.historical_question_answer_count += answers.len;
        return entry_id;
    }

    fn attachHistoricalToolDetail(
        self: *TestApp,
        entry_id: u32,
        _: types.ToolCall,
        _: types.PersistedToolResult,
    ) !void {
        try self.historical_tool_detail_entry_ids.append(self.alloc, entry_id);
    }

    fn attachHistoricalCancelledCommandDetail(
        self: *TestApp,
        entry_id: u32,
        _: types.ToolCall,
        command_artifact_handle: ?[]const u8,
        replayed_output: bool,
    ) !void {
        try self.historical_tool_detail_entry_ids.append(self.alloc, entry_id);
        self.cancelled_command_detail_count += 1;
        self.cancelled_command_replayed_output = replayed_output;
        if (command_artifact_handle) |handle| {
            self.cancelled_command_artifact_handle = try self.alloc.dupe(u8, handle);
        }
    }

    fn allocateTranscriptEntryId(self: *TestApp) u32 {
        const entry_id = self.next_transcript_entry_id;
        self.next_transcript_entry_id +%= 1;
        return entry_id;
    }

    fn writeCommandOutputChunk(self: *TestApp, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        _ = record;
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        try self.command_output_writes.append(self.alloc, .{
            .stream = stream,
            .text = owned,
        });
        try self.replay_events.append(self.alloc, .command_output_chunk);
        switch (stream) {
            .stdout => try self.command_stdout.appendSlice(self.alloc, text),
            .stderr => try self.command_stderr.appendSlice(self.alloc, text),
        }
    }

    fn flushCommandOutputSummary(self: *TestApp, record: bool) !void {
        _ = record;
        self.command_output_flush_count += 1;
        try self.replay_events.append(self.alloc, .command_output_summary_flush);
    }

    fn describeToolActionCompletedWithAdvertised(self: *TestApp, arena: Allocator, call: types.ToolCall, _: ?[]const u8, _: []const []const u8) ![]const u8 {
        if (self.action_description_allocates_scratch) {
            _ = try arena.dupe(u8, "temporary parsed arguments");
        }
        if (std.mem.eql(u8, call.name, "run_command")) {
            return arena.dupe(u8, "● Ran pwd");
        }
        return std.fmt.allocPrint(arena, "● Completed {s}", .{call.name});
    }

    fn describeToolActionDeniedWithAdvertised(self: *TestApp, arena: Allocator, call: types.ToolCall, _: ?[]const u8, label: []const u8, _: []const []const u8) ![]const u8 {
        if (self.action_description_allocates_scratch) {
            _ = try arena.dupe(u8, "temporary parsed arguments");
        }
        return std.fmt.allocPrint(arena, "● {s} {s}", .{ label, call.name });
    }

    fn pacerEmit(ctx: *anyopaque, text: []const u8) anyerror!void {
        const self: *TestApp = @ptrCast(@alignCast(ctx));
        try self.assistant_text.appendSlice(self.alloc, text);
        try self.assistant_presentation_events.append(self.alloc, .text);
    }

    fn appendAssistantTable(
        self: *TestApp,
        table: assistant_presentation.TablePayload,
    ) !void {
        if (self.fail_assistant_table_append) {
            return error.TestAssistantTableAppendFailure;
        }
        try self.assistant_presentation_events.append(self.alloc, .table);
        try self.assistant_tables.append(self.alloc, table);
    }

    fn appendAssistantCodeBlock(
        self: *TestApp,
        block: assistant_presentation.CodeBlockPayload,
    ) !void {
        if (self.fail_assistant_code_block_append) {
            return error.TestAssistantCodeBlockAppendFailure;
        }
        try self.assistant_presentation_events.append(self.alloc, .code_block);
        try self.assistant_code_blocks.append(self.alloc, block);
    }

    fn appendAssistantThematicRule(self: *TestApp) !void {
        self.assistant_thematic_rule_count += 1;
        try self.assistant_presentation_events.append(self.alloc, .thematic_rule);
    }
};

const FakeJsHostSessionStore = struct {
    state: ?session_codec.DurableSessionState = null,
    revision: []const u8 = "revision-1",
    updated_at_ms: i64 = 1,
    list_error: ?anyerror = null,
    load_error: ?anyerror = null,
    commit_error: ?anyerror = null,
    load_missing: bool = false,
    commit_count: usize = 0,
    committed_state: ?session_codec.DurableSessionState = null,
    expected_revision: ?[]u8 = null,

    fn deinit(self: *FakeJsHostSessionStore, alloc: Allocator) void {
        if (self.state) |*state| state.deinit(alloc);
        if (self.committed_state) |*state| state.deinit(alloc);
        if (self.expected_revision) |revision| alloc.free(revision);
        self.* = .{};
    }

    fn store(self: *FakeJsHostSessionStore) JsHostSessionStore {
        return .{
            .ctx = self,
            .load_fn = load,
            .commit_fn = commit,
            .list_fn = list,
        };
    }

    fn load(raw: ?*anyopaque, alloc: Allocator, id: []const u8) !?js_host_session_store.Loaded {
        const self: *FakeJsHostSessionStore = @ptrCast(@alignCast(raw.?));
        if (self.load_error) |err| return err;
        if (self.load_missing) return null;
        const state = self.state orelse return null;
        if (!std.mem.eql(u8, state.id, id)) return null;
        var owned_state = try state.dupe(alloc);
        errdefer owned_state.deinit(alloc);
        return .{
            .state = owned_state,
            .revision = try alloc.dupe(u8, self.revision),
        };
    }

    fn commit(
        raw: ?*anyopaque,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        const self: *FakeJsHostSessionStore = @ptrCast(@alignCast(raw.?));
        self.commit_count += 1;
        if (self.commit_error) |err| return err;
        if (self.expected_revision) |revision| alloc.free(revision);
        self.expected_revision = if (expected_revision) |revision|
            try alloc.dupe(u8, revision)
        else
            null;
        if (self.committed_state) |*committed| committed.deinit(alloc);
        self.committed_state = try state.dupe(alloc);
        return alloc.dupe(u8, "revision-next");
    }

    fn list(raw: ?*anyopaque, alloc: Allocator) ![]js_host_session_store.Metadata {
        const self: *FakeJsHostSessionStore = @ptrCast(@alignCast(raw.?));
        if (self.list_error) |err| return err;
        const state = self.state orelse return alloc.alloc(js_host_session_store.Metadata, 0);
        const entries = try alloc.alloc(js_host_session_store.Metadata, 1);
        errdefer alloc.free(entries);
        entries[0] = .{
            .id = try alloc.dupe(u8, state.id),
            .updated_at_ms = self.updated_at_ms,
        };
        return entries;
    }
};

fn makeJsHostTestState(
    alloc: Allocator,
    id: []const u8,
    user: []const u8,
    assistant: []const u8,
) !session_codec.DurableSessionState {
    const history = try alloc.alloc(types.HistoryTurn, 1);
    errdefer alloc.free(history);
    history[0] = try session_runtime.makeAssistantTurn(alloc, user, assistant);
    errdefer session_runtime.freeHistoryTurn(alloc, history[0]);
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, "/origin");
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, "/workspace");
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, "restored/model");
    errdefer alloc.free(model);
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    usage.finishInvocation(sequence, 41, .unbilled);
    var usage_snapshot = try usage.snapshot(alloc);
    errdefer usage_snapshot.deinit(alloc);
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = 10,
        .updated_at_ms = 20,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = model,
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = true,
        },
        .history = history,
        .context_history_start = 1,
        .usage = usage_snapshot,
        .total_input_tokens = 17,
        .total_output_tokens = 23,
    };
}








fn testPaths(alloc: Allocator, tmp: *std.testing.TmpDir) !struct { home: []u8, workspace: []u8 } {
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    return .{
        .home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home"),
        .workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace"),
    };
}

fn configureTestPreferences(app: *TestApp) !void {
    try Runtime(TestApp).configureStartupPreferences(
        app,
        .gateway,
        "configured/model",
        .user_workspace,
        "configured/model",
        types.ReasoningEffort.literal("high"),
        true,
    );
}

fn activeWatermarkPath(
    alloc: Allocator,
    app: *TestApp,
) ![]u8 {
    const session_dir = (try Runtime(TestApp).activeSessionDisplayPath(
        app,
        alloc,
    )) orelse return error.TestExpectedSessionDirectory;
    defer alloc.free(session_dir);
    const generation_hex = std.fmt.bytesToHex(
        app.session_persistence.writable.?.position.log_generation,
        .lower,
    );
    const watermark_path = try std.fmt.allocPrint(
        alloc,
        "{s}/commit.{s}.json",
        .{ session_dir, generation_hex },
    );
    return watermark_path;
}

fn corruptActiveWatermark(
    alloc: Allocator,
    app: *TestApp,
) !void {
    const watermark_path = try activeWatermarkPath(alloc, app);
    defer alloc.free(watermark_path);
    var watermark = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        watermark_path,
        .{ .truncate = true },
    );
    defer watermark.close(io_mod.getIo());
    try watermark.writeStreamingAll(io_mod.getIo(), "{}\n");
    try watermark.sync(io_mod.getIo());
}

fn removeActiveWatermark(
    alloc: Allocator,
    app: *TestApp,
) !void {
    const watermark_path = try activeWatermarkPath(alloc, app);
    defer alloc.free(watermark_path);
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), watermark_path);
}

const FailingCommitLifecycle = struct {
    fn prepare(
        _: ?*anyopaque,
        _: Allocator,
        _: []const u8,
        _: []const u8,
        _: []const u8,
        _: u64,
    ) !void {
        return error.TestCommitPrepareFailure;
    }
};

fn writeSessionFixture(
    alloc: Allocator,
    store: session_store.Store,
    id: []const u8,
    history: []const types.HistoryTurn,
    context_history_start: usize,
) !void {
    const owned_history = try alloc.alloc(types.HistoryTurn, history.len);
    var copied: usize = 0;
    errdefer {
        for (owned_history[0..copied]) |turn| {
            session_runtime.freeHistoryTurn(alloc, turn);
        }
        alloc.free(owned_history);
    }
    for (history, 0..) |turn, index| {
        owned_history[index] = try session_runtime.dupeHistoryTurn(alloc, turn);
        copied += 1;
    }
    var state = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, store.workspace_root),
        .workspace_root = try alloc.dupe(u8, store.workspace_root),
        .created_at_ms = 123,
        .updated_at_ms = 456,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "saved/model"),
            .effort = types.ReasoningEffort.literal("medium"),
            .fast_mode = false,
        },
        .history = owned_history,
        .context_history_start = context_history_start,
        .total_input_tokens = 17,
        .total_output_tokens = 23,
    };
    defer state.deinit(alloc);
    var loaded = try store.startWritableSession(alloc, state);
    defer loaded.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        state,
        .migration,
        .rollback_before_adapter_continue,
        .{},
    );
}










const HandoffDegradedFailure = struct {
    fn hit(_: ?*anyopaque, point: session_log.Boundary) !void {
        if (point == .after_event_sync or
            point == .before_recovery_proposed_validation or
            point == .before_recovery_prior_validation)
        {
            return error.TestHandoffDegradedFailure;
        }
    }

    fn controls() session_log.TestControls {
        return .{ .boundary_fn = hit };
    }
};






































fn expectAuthoritativeCancelledReplayIsSoleArtifact() !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const paths = try testPaths(alloc, &tmp);
    defer {
        alloc.free(paths.home);
        alloc.free(paths.workspace);
    }
    const home = try TestHome.install(alloc, paths.home);
    defer home.deinit();
    var app = try TestApp.init(alloc, paths.workspace);
    defer app.deinit();
    try configureTestPreferences(&app);
    try Runtime(TestApp).initializePersistence(&app, true);
    try Runtime(TestApp).beginFreshPersistedSession(&app);
    const capability = Runtime(TestApp).childCapability(&app) orelse
        return error.TestExpectedSessionCapability;
    const authoritative = try command_replay_store.Capture.create(
        alloc,
        1,
        capability,
    );
    authoritative.setPolicyBeforeCapture(.required);
    try authoritative.appendAcceptedRequired(
        alloc,
        .stdout,
        "SHARED-CANCELLED-OUTPUT\n",
    );
    const descriptor = (try authoritative.retainRequired(alloc)) orelse
        return error.TestExpectedReplay;
    var published = false;
    defer {
        if (published)
            authoritative.releaseRetained(alloc)
        else
            authoritative.discard(alloc);
        alloc.destroy(authoritative);
    }

    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 9,
        .call_id = "authoritative-cancelled-command",
    };
    Runtime(TestApp).recordToolTerminal(
        &app,
        .{ .terminal = .{
            .id = lifecycle_id,
            .outcome = .{ .kind = .cancelled, .summary = "Cancelled" },
            .command_artifact_handle = "fx-command-cancelled.log",
        } },
        true,
    );

    try Runtime(TestApp).appendHistoryTurn(&app, .{ .interrupted = .{
        .user = .{ .text = @constCast("cancel") },
        .tool_call = .{
            .id = "authoritative-cancelled-command",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"slow\",\"timeout_ms\":600000}",
        },
        .cancelled_command = .{
            .output_replay = .{ .available = descriptor },
        },
    } });
    published = true;

    const history = try app.session.snapshotHistory(alloc);
    defer session_runtime.freeHistoryTurnSlice(alloc, history);
    const stored = switch (history[0].interrupted.cancelled_command.?
        .output_replay orelse return error.TestExpectedReplay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    try std.testing.expectEqualStrings(descriptor.handle, stored.handle);
    try std.testing.expectEqualStrings(
        "fx-command-cancelled.log",
        history[0].interrupted.cancelled_command.?
            .command_artifact_handle orelse return error.TestExpectedArtifactHandle,
    );
    const page = try command_replay_store.readAgentPageManaged(
        alloc,
        capability,
        stored.handle,
        1,
        4096,
    );
    defer alloc.free(page);
    try std.testing.expect(
        std.mem.find(u8, page, "SHARED-CANCELLED-OUTPUT") != null,
    );
    var artifacts = try capability.iterate(alloc, .command_artifacts);
    defer artifacts.deinit();
    try std.testing.expectEqual(@as(usize, 1), artifacts.names.len);
}










const SnapshotOwnershipProbe = struct {
    transfers: usize = 0,

    fn retain(_: *anyopaque) void {}

    fn release(_: *anyopaque) void {}

    fn transfer(raw: *anyopaque) void {
        const self: *SnapshotOwnershipProbe = @ptrCast(@alignCast(raw));
        self.transfers += 1;
    }

    fn handle(self: *SnapshotOwnershipProbe) types.SnapshotFileOwnership {
        return .{
            .ctx = self,
            .retain_fn = retain,
            .release_fn = release,
            .transfer_fn = transfer,
        };
    }
};























fn createHeldSessionPickerTask(
    generation: u64,
    active_id: []const u8,
    store: session_store.Store,
) !*SessionPickerLoad.Task {
    const alloc = std.heap.c_allocator;
    var request = try SessionPickerLoad.PageRequest.init(
        generation,
        .current_workspace,
        active_id,
        null,
        session_store.default_resume_page_limit,
    );
    errdefer request.deinit();
    const home_dir = try alloc.dupe(u8, store.home_dir);
    errdefer alloc.free(home_dir);
    const workspace_root = try alloc.dupe(u8, store.workspace_root);
    errdefer alloc.free(workspace_root);
    const task = try alloc.create(SessionPickerLoad.Task);
    errdefer alloc.destroy(task);
    task.* = .{
        .home_dir = home_dir,
        .workspace_root = workspace_root,
        .request = request,
    };
    return task;
}

fn waitForSessionPickerLoad(app: *TestApp) !void {
    const deadline_ms = io_mod.milliTimestamp() + 5_000;
    while (io_mod.milliTimestamp() < deadline_ms) {
        try Runtime(TestApp).pollSessionPicker(app);
        const picker = &app.session_persistence.session_picker;
        if (!picker.isLoading() and !picker.loading_more) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}

fn waitForSessionPickerPrewarm(app: *TestApp) !void {
    const deadline_ms = io_mod.milliTimestamp() + 5_000;
    while (io_mod.milliTimestamp() < deadline_ms) {
        try Runtime(TestApp).pollSessionPicker(app);
        const loader = &app.session_persistence.session_picker_load;
        if (loader.task == null and loader.pending == null) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.TestExpectedEqual;
}





const ReconciliationOriginUsage = struct {
    replaced_provider: ?model_provider.ProviderId = null,
    replaced_source: ?types.CredentialSource = null,

    fn replaceProviderReconciliationCredential(
        self: *@This(),
        _: Allocator,
        provider: model_provider.ProviderId,
        source: types.CredentialSource,
        _: ?[]const u8,
        _: []const u8,
    ) void {
        self.replaced_provider = provider;
        self.replaced_source = source;
    }
};

const ReconciliationOriginAuth = struct {
    source: types.CredentialSource,

    fn credentialSource(self: *const @This()) ?types.CredentialSource {
        return self.source;
    }

    fn apiKey(_: *const @This()) ?[]const u8 {
        return "origin-bound-token";
    }

    fn accountId(_: *const @This()) ?[]const u8 {
        return null;
    }

    fn gatewayTeam(_: *const @This()) ?[]const u8 {
        return null;
    }
};

const ReconciliationOriginApp = struct {
    alloc: Allocator = std.testing.allocator,
    auth: ReconciliationOriginAuth,
    session: struct { usage: ReconciliationOriginUsage = .{} } = .{},
    selected_provider: model_provider.ProviderId,
    selected_model: std.ArrayList(u8) = .empty,
};





