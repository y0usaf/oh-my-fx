const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const background_launch_identity = @import("background_launch_identity.zig");
const background_launch_output = @import("background_launch_output.zig");
const background_record_liveness = @import("background_record_liveness.zig");
const background_record_restore = @import("background_record_restore.zig");
const background_store = @import("background_store.zig");
const process_supervisor = @import("process_supervisor.zig");
const server_detection = @import("server_detection.zig");
const command_contract = @import("../execution/command_contract.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const session_child_store = @import("../session/session_child_store.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const types = @import("../shared/types.zig");
const session_store = @import("../session/session_store.zig");
const task_helpers = @import("../tasks/task_helpers.zig");

const Allocator = std.mem.Allocator;


pub const RuntimeContextSnapshot = process_supervisor.RuntimeContextSnapshot;
pub const TaskSnapshot = process_supervisor.TaskSnapshot;
pub const TaskListSnapshot = process_supervisor.TaskListSnapshot;
pub const TaskState = process_supervisor.TaskState;
pub const TaskSelection = process_supervisor.TaskSelection;
pub const StopSelection = process_supervisor.StopSelection;
pub const TaskCompletion = process_supervisor.TaskCompletion;
pub const BackgroundLaunchPolicy =
    process_supervisor.BackgroundLaunchPolicy;
pub const StableBackgroundRecordId =
    process_supervisor.StableBackgroundRecordId;

pub const PreparedBackgroundLaunch = struct {
    identity: background_launch_identity.Identity,
    output: background_launch_output.Output,
    consumed: bool = false,
};

pub const BackgroundLaunchOutcome = enum {
    process_local_started,
    durable_started,
    durable_started_degraded,
};

pub const RegisteredBackground = struct {
    process_id: u64,
    outcome: BackgroundLaunchOutcome,
    command: command_contract.BackgroundCommand,

    pub fn deinit(self: *RegisteredBackground, alloc: Allocator) void {
        alloc.free(@constCast(self.command.pid));
        alloc.free(@constCast(self.command.command));
        alloc.free(@constCast(self.command.cwd));
        alloc.free(@constCast(self.command.log_path));
        if (self.command.url) |url| alloc.free(@constCast(url));
        self.* = undefined;
    }
};

pub const UrlReadyCallback = *const fn (ctx: *anyopaque, task_id: u64, url: []const u8) void;
pub const WatcherContextDeinit = *const fn (alloc: Allocator, ctx: *anyopaque) void;
pub const TaskCompletionCallback = *const fn (ctx: *anyopaque, completion: TaskCompletion) void;

const BackgroundUrlWatchJob = struct {
    alloc: Allocator,
    runtime: *BackgroundRuntime,
    process_id: u64,
    callback_ctx: *anyopaque,
    on_url_ready: UrlReadyCallback,
    on_context_deinit: ?WatcherContextDeinit,
    done: *std.atomic.Value(bool),
};

const BackgroundWatcherHandle = struct {
    thread: std.Thread,
    done: *std.atomic.Value(bool),
};

const RetainedSourceCapability = struct {
    source_session_id: []u8,
    capability: *session_child_store.SessionChildCapability,

    fn deinit(self: *RetainedSourceCapability, alloc: Allocator) void {
        self.capability.deinit();
        alloc.destroy(self.capability);
        alloc.free(self.source_session_id);
        self.* = undefined;
    }
};

const OwnedBackgroundChild = struct {
    process_id: u64,
    process: background_process_provider.OwnedProcess,
};

const watcher_retry_interval_ns = 200 * std.time.ns_per_ms;
const process_identity_capture_attempts: usize = 3;
const process_identity_capture_retry_delay_ns = 20 * std.time.ns_per_ms;
const blocked_wrapper_cleanup_timeout_ms: i64 = 2000;
var blocked_wrapper_cleanup_timeout_ms_for_test: ?i64 = null;

const StableRecordIdFn =
    *const fn () anyerror!StableBackgroundRecordId;
var stable_record_id_for_test: ?StableRecordIdFn = null;

pub const BackgroundRuntime = struct {
    process_provider: background_process_provider.Provider =
        background_process_provider.unavailable_provider,
    mutex: std.Io.Mutex = .init,
    supervisor: process_supervisor.ProcessSupervisor = .{},
    persisted_store: ?background_store.Store = null,
    owned_session_capability: ?*session_child_store.SessionChildCapability = null,
    borrowed_session_capability: ?*session_child_store.SessionChildCapability = null,
    source_session_id: ?[]u8 = null,
    retained_source_capabilities: std.ArrayList(RetainedSourceCapability) = .empty,
    retained_indeterminate_identities: std.ArrayList(background_launch_identity.Identity) = .empty,
    prepared_launch_reservations: usize = 0,
    owned_children: std.ArrayList(OwnedBackgroundChild) = .empty,
    watchers: std.ArrayList(BackgroundWatcherHandle) = .empty,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_refresh_ms: i64 = 0,

    pub fn init(
        process_provider: background_process_provider.Provider,
    ) BackgroundRuntime {
        return .{ .process_provider = process_provider };
    }

    pub fn processProvider(
        self: *const BackgroundRuntime,
    ) background_process_provider.Provider {
        return self.process_provider;
    }

    pub fn deinit(self: *BackgroundRuntime, alloc: Allocator) void {
        if (self.source_session_id) |source_session_id| {
            self.retryDegradedRecordsForSource(
                alloc,
                source_session_id,
            );
        }
        self.requestStop();
        self.pruneWatchers(alloc, true);
        self.terminateOwnedUnrecordedProcesses(alloc);
        self.watchers.deinit(alloc);
        for (self.owned_children.items) |*owned| {
            owned.process.forget();
        }
        self.owned_children.deinit(alloc);
        if (self.persisted_store) |*store| store.deinit(alloc);
        for (self.retained_source_capabilities.items) |*retained| {
            retained.deinit(alloc);
        }
        self.retained_source_capabilities.deinit(alloc);
        for (self.retained_indeterminate_identities.items) |*identity| {
            identity.deinit(alloc);
        }
        self.retained_indeterminate_identities.deinit(alloc);
        if (self.owned_session_capability) |capability| {
            capability.deinit();
            alloc.destroy(capability);
        }
        if (self.source_session_id) |source_session_id| {
            alloc.free(source_session_id);
        }
        self.supervisor.deinit(alloc);
        self.* = .{};
    }

    pub fn enablePersistence(self: *BackgroundRuntime, alloc: Allocator, background_dir: []const u8) !void {
        const session_dir_path = std.fs.path.dirname(background_dir) orelse
            return error.SessionChildStoreFailed;
        const source_session_id = std.fs.path.basename(session_dir_path);
        const capability = try alloc.create(
            session_child_store.SessionChildCapability,
        );
        var capability_owned = true;
        errdefer if (capability_owned) alloc.destroy(capability);
        capability.* = try session_child_store.SessionChildCapability.initLegacyBackgroundRoutes(
            alloc,
            background_dir,
            .writable,
        );
        errdefer if (capability_owned) capability.deinit();
        self.installPersistence(
            alloc,
            capability,
            source_session_id,
            true,
        ) catch |err| {
            if (self.activeSessionCapability() == capability) {
                capability_owned = false;
            }
            return err;
        };
        capability_owned = false;
    }

    pub fn enableManagedPersistence(
        self: *BackgroundRuntime,
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        source_session_id: []const u8,
    ) !void {
        try self.installPersistence(
            alloc,
            capability,
            source_session_id,
            false,
        );
    }

    fn installPersistence(
        self: *BackgroundRuntime,
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        source_session_id: []const u8,
        owns_capability: bool,
    ) !void {
        var store = background_store.Store.initManaged(capability);
        const owned_source_session_id = try alloc.dupe(
            u8,
            source_session_id,
        );
        errdefer alloc.free(owned_source_session_id);

        if (self.source_session_id) |existing_source_session_id| {
            if (std.mem.eql(
                u8,
                existing_source_session_id,
                owned_source_session_id,
            ) and self.activeSessionCapability() == capability) {
                alloc.free(owned_source_session_id);
                return;
            }
            self.invalidateSourceAuthority(
                alloc,
                existing_source_session_id,
            );
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        errdefer self.mutex.unlock(io_mod.getIo());

        const next_id = try store.nextId();
        if (self.persisted_store) |*existing| existing.deinit(alloc);
        if (self.source_session_id) |closing_source_session_id| {
            for (self.supervisor.tasks.items) |*task| {
                const task_source = task.source_session_id orelse continue;
                if (!std.mem.eql(
                    u8,
                    task_source,
                    closing_source_session_id,
                )) continue;
                task.record_authority = .none;
            }
        }
        if (self.owned_session_capability) |existing| {
            existing.deinit();
            alloc.destroy(existing);
        }
        self.borrowed_session_capability = null;
        if (self.source_session_id) |existing| alloc.free(existing);
        self.persisted_store = store;
        if (owns_capability) {
            self.owned_session_capability = capability;
        } else {
            self.owned_session_capability = null;
            self.borrowed_session_capability = capability;
        }
        self.source_session_id = owned_source_session_id;
        self.supervisor.next_background_process_id = @max(self.supervisor.next_background_process_id, next_id);

        for (self.supervisor.tasks.items) |*task| {
            const task_source = task.source_session_id orelse continue;
            const stable_id = task.background_record_id orelse continue;
            if (!std.mem.eql(
                u8,
                task_source,
                owned_source_session_id,
            )) continue;
            if (store.loadByStableId(alloc, stable_id)) |record| {
                var current = record;
                defer current.deinit(alloc);
                const token = current.process_token orelse continue;
                const expected = process_supervisor.ProcessInstanceToken.parse(
                    token,
                ) catch continue;
                const token_match = self.process_provider.matchToken(
                    alloc,
                    current.pid,
                    expected,
                );
                switch (token_match) {
                    .matched => {
                        task.record_authority = .{
                            .writable = capability,
                        };
                    },
                    .missing, .mismatched => {
                        task.record_authority = .{
                            .writable = capability,
                        };
                        if (task.state == .running) {
                            task.state = .stale;
                            task.expect_url = false;
                            task.exit_code = null;
                        }
                    },
                    .unavailable => {},
                }
            } else |_| {}
        }

        const snapshots = self.supervisor.snapshotTasks(alloc) catch |err| {
            if (self.persisted_store) |*existing| existing.deinit(alloc);
            self.persisted_store = null;
            return err;
        };
        self.mutex.unlock(io_mod.getIo());

        defer snapshots.deinit(alloc);
        self.saveSnapshotsOrDisablePersistence(alloc, "enable background persistence", snapshots.items);
    }

    pub fn invalidateSourceAuthority(
        self: *BackgroundRuntime,
        alloc: Allocator,
        source_session_id: []const u8,
    ) void {
        self.retryDegradedRecordsForSource(
            alloc,
            source_session_id,
        );
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.supervisor.tasks.items) |*task| {
            const task_source = task.source_session_id orelse continue;
            if (!std.mem.eql(
                u8,
                task_source,
                source_session_id,
            )) continue;
            task.record_authority = .none;
        }
    }

    pub fn detachManagedPersistence(
        self: *BackgroundRuntime,
        alloc: Allocator,
        source_session_id: []const u8,
    ) void {
        const current = self.source_session_id orelse return;
        if (!std.mem.eql(u8, current, source_session_id)) return;
        self.invalidateSourceAuthority(alloc, source_session_id);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.persisted_store) |*store| store.deinit(alloc);
        self.persisted_store = null;
        if (self.owned_session_capability) |capability| {
            capability.deinit();
            alloc.destroy(capability);
        }
        self.owned_session_capability = null;
        self.borrowed_session_capability = null;
        if (self.source_session_id) |owned| alloc.free(owned);
        self.source_session_id = null;
    }

    fn activeSessionCapability(
        self: *BackgroundRuntime,
    ) ?*session_child_store.SessionChildCapability {
        return self.borrowed_session_capability orelse
            self.owned_session_capability;
    }

    fn retryDegradedRecordsForSource(
        self: *BackgroundRuntime,
        alloc: Allocator,
        source_session_id: []const u8,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const snapshots = self.supervisor.snapshotTasks(alloc) catch {
            self.mutex.unlock(io_mod.getIo());
            return;
        };
        self.mutex.unlock(io_mod.getIo());
        defer snapshots.deinit(alloc);

        for (snapshots.items) |task_snapshot| {
            const task_source = task_snapshot.source_session_id orelse
                continue;
            if (!std.mem.eql(
                u8,
                task_source,
                source_session_id,
            )) continue;
            if (task_snapshot.record_persistence !=
                .initial_record_degraded and
                task_snapshot.record_persistence !=
                    .record_update_degraded)
            {
                continue;
            }
            self.saveDurableSnapshotIfAuthorized(
                alloc,
                "final source authority retry",
                task_snapshot,
            );
        }
    }

    pub fn prepareBackgroundLaunch(
        self: *BackgroundRuntime,
        alloc: Allocator,
        policy: BackgroundLaunchPolicy,
    ) !PreparedBackgroundLaunch {
        self.mutex.lockUncancelable(io_mod.getIo());
        var locked = true;
        errdefer if (locked) self.mutex.unlock(io_mod.getIo());
        const reserved_retention_slots =
            std.math.add(
                usize,
                self.prepared_launch_reservations,
                1,
            ) catch return error.BackgroundIdentityUnavailable;
        try self.owned_children.ensureUnusedCapacity(
            alloc,
            reserved_retention_slots,
        );
        try self.retained_indeterminate_identities.ensureUnusedCapacity(
            alloc,
            reserved_retention_slots,
        );
        const display_id = try self.supervisor.reserveDisplayId();
        errdefer self.supervisor.releaseDisplayId(display_id);

        var identity: background_launch_identity.Identity = undefined;
        switch (policy) {
            .process_local_long_lived => {
                identity = .{ .process_local_long_lived = .{
                    .display_id = display_id,
                } };
            },
            .durable_long_lived, .saved_headless => {
                const source_session_id = self.source_session_id orelse
                    return error.BackgroundPersistenceUnavailable;
                const store = self.persisted_store orelse
                    return error.BackgroundPersistenceUnavailable;
                const stable_id = try self.generateStableRecordIdLocked(
                    alloc,
                    store,
                    source_session_id,
                );
                const owned_source_session_id = try alloc.dupe(
                    u8,
                    source_session_id,
                );
                identity = switch (policy) {
                    .durable_long_lived => .{
                        .durable_long_lived = .{
                            .display_id = display_id,
                            .source_session_id = owned_source_session_id,
                            .background_record_id = stable_id,
                        },
                    },
                    .saved_headless => .{
                        .saved_headless = .{
                            .display_id = display_id,
                            .source_session_id = owned_source_session_id,
                            .background_record_id = stable_id,
                        },
                    },
                    .process_local_long_lived => unreachable,
                };
            },
        }
        self.prepared_launch_reservations += 1;
        self.mutex.unlock(io_mod.getIo());
        locked = false;
        errdefer self.releasePreparedLaunchReservation();
        errdefer identity.deinit(alloc);

        const output = switch (policy) {
            .process_local_long_lived => try background_launch_output.prepareExternal(alloc),
            .durable_long_lived, .saved_headless => blk: {
                const capability = self.activeSessionCapability() orelse
                    return error.BackgroundPersistenceUnavailable;
                break :blk try background_launch_output.prepareManaged(alloc, capability);
            },
        };
        return .{ .identity = identity, .output = output };
    }

    pub fn cancelPreparedBackgroundLaunch(
        self: *BackgroundRuntime,
        alloc: Allocator,
        prepared: *PreparedBackgroundLaunch,
    ) void {
        if (prepared.consumed) return;
        prepared.consumed = true;
        prepared.output.deinit(alloc, true);
        self.mutex.lockUncancelable(io_mod.getIo());
        self.supervisor.releaseDisplayId(prepared.identity.displayId());
        self.prepared_launch_reservations -= 1;
        self.mutex.unlock(io_mod.getIo());
        prepared.identity.deinit(alloc);
    }

    fn failBlockedBackgroundLaunch(
        self: *BackgroundRuntime,
        alloc: Allocator,
        prepared: *PreparedBackgroundLaunch,
        spawned: *background_process_provider.PreparedProcess,
        process_token: ?process_supervisor.ProcessInstanceToken,
        cause: anyerror,
    ) anyerror {
        const cleanup_timeout_ms = blockedWrapperCleanupTimeoutMs();
        var cleanup_confirmed =
            spawned.closeAndWaitUnreleased(
                process_token,
                cleanup_timeout_ms,
            ) == .confirmed;
        if (!cleanup_confirmed) {
            if (process_token) |token| {
                self.process_provider.signalProcess(
                    alloc,
                    spawned.pid,
                    token,
                ) catch {};
                cleanup_confirmed = spawned.waitForUnreleasedExit(
                    token,
                    cleanup_timeout_ms,
                );
            }
        }
        if (!cleanup_confirmed) {
            if (!spawned.detachUnreleasedReaper()) {
                debug_trace.logf(
                    "background",
                    "blocked wrapper cleanup could not retain reaper pid={s}",
                    .{spawned.pid},
                );
            }
        }
        if (cleanup_confirmed) {
            self.cancelPreparedBackgroundLaunch(alloc, prepared);
            return cause;
        }
        self.retainIndeterminatePreparedLaunch(alloc, prepared);
        return error.BackgroundProcessIdentityIndeterminate;
    }

    pub fn retainIndeterminatePreparedLaunch(
        self: *BackgroundRuntime,
        alloc: Allocator,
        prepared: *PreparedBackgroundLaunch,
    ) void {
        prepared.output.deinit(alloc, true);
        prepared.consumed = true;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.supervisor.retainDisplayIdReservation(
            prepared.identity.displayId(),
        );
        self.retained_indeterminate_identities.appendAssumeCapacity(
            prepared.identity,
        );
        self.prepared_launch_reservations -= 1;
        self.mutex.unlock(io_mod.getIo());
        prepared.identity = undefined;
    }

    fn releasePreparedLaunchReservation(
        self: *BackgroundRuntime,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.prepared_launch_reservations -= 1;
        self.mutex.unlock(io_mod.getIo());
    }

    fn hasRetainedIndeterminateIdentity(
        self: *BackgroundRuntime,
        expected: background_launch_identity.Identity,
    ) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.retained_indeterminate_identities.items) |identity| {
            if (identity.eql(expected)) return true;
        }
        return false;
    }

    fn generateStableRecordIdLocked(
        self: *BackgroundRuntime,
        alloc: Allocator,
        store: background_store.Store,
        source_session_id: []const u8,
    ) !StableBackgroundRecordId {
        var attempt: usize = 0;
        while (attempt < 16) : (attempt += 1) {
            const candidate = try nextStableRecordId();
            var collision = false;
            for (self.supervisor.tasks.items) |task| {
                const task_id = task.background_record_id orelse continue;
                const task_source = task.source_session_id orelse continue;
                if (std.mem.eql(u8, task_source, source_session_id) and
                    std.mem.eql(u8, &task_id, &candidate))
                {
                    collision = true;
                    break;
                }
            }
            if (!collision) {
                for (self.retained_indeterminate_identities.items) |identity| {
                    const durable = switch (identity) {
                        .process_local_long_lived => continue,
                        .durable_long_lived, .saved_headless => |value| value,
                    };
                    if (std.mem.eql(
                        u8,
                        durable.source_session_id,
                        source_session_id,
                    ) and std.mem.eql(
                        u8,
                        &durable.background_record_id,
                        &candidate,
                    )) {
                        collision = true;
                        break;
                    }
                }
            }
            if (collision) continue;
            if (store.loadByStableId(alloc, candidate)) |record| {
                var owned = record;
                owned.deinit(alloc);
                continue;
            } else |err| switch (err) {
                error.BackgroundRecordNotFound => return candidate,
                error.DuplicateBackgroundRecordIdentity => continue,
                else => return err,
            }
        }
        return error.BackgroundIdentityUnavailable;
    }

    pub fn registerSpawnedBackground(
        self: *BackgroundRuntime,
        alloc: Allocator,
        prepared: *PreparedBackgroundLaunch,
        spawned: *background_process_provider.PreparedProcess,
        original_command: []const u8,
        cwd: []const u8,
        expect_url: bool,
    ) !RegisteredBackground {
        if (prepared.consumed) return error.BackgroundLaunchAlreadyConsumed;

        const process_token = captureSpawnedProcessToken(
            self,
            alloc,
            spawned.pid,
        ) catch |err|
            return self.failBlockedBackgroundLaunch(
                alloc,
                prepared,
                spawned,
                null,
                err,
            );

        const pid = alloc.dupe(u8, spawned.pid) catch |err|
            return self.failBlockedBackgroundLaunch(
                alloc,
                prepared,
                spawned,
                process_token,
                err,
            );
        errdefer alloc.free(pid);
        const command = alloc.dupe(u8, original_command) catch |err|
            return self.failBlockedBackgroundLaunch(
                alloc,
                prepared,
                spawned,
                process_token,
                err,
            );
        errdefer alloc.free(command);
        const owned_cwd = alloc.dupe(u8, cwd) catch |err|
            return self.failBlockedBackgroundLaunch(
                alloc,
                prepared,
                spawned,
                process_token,
                err,
            );
        errdefer alloc.free(owned_cwd);
        const log_path =
            alloc.dupe(u8, prepared.output.displayPath()) catch |err|
                return self.failBlockedBackgroundLaunch(
                    alloc,
                    prepared,
                    spawned,
                    process_token,
                    err,
                );
        errdefer alloc.free(log_path);
        const managed_log_name = prepared.output.managedLogName();

        const display_id = prepared.identity.displayId();
        const policy = std.meta.activeTag(prepared.identity);
        var source_session_id: ?[]const u8 = null;
        var background_record_id: ?StableBackgroundRecordId = null;
        switch (prepared.identity) {
            .process_local_long_lived => {},
            .durable_long_lived, .saved_headless => |identity| {
                source_session_id = identity.source_session_id;
                background_record_id = identity.background_record_id;
            },
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        var locked = true;
        errdefer if (locked) self.mutex.unlock(io_mod.getIo());
        const process_id = self.supervisor.registerBackground(alloc, .{
            .display_id = display_id,
            .pid = pid,
            .process_token = process_token,
            .policy = policy,
            .source_session_id = source_session_id,
            .background_record_id = background_record_id,
            .durable_record_id = if (background_record_id != null)
                display_id
            else
                null,
            .record_authority = if (background_record_id != null)
                .{ .writable = self.activeSessionCapability().? }
            else
                .none,
            .managed_log_name = managed_log_name,
            .command = command,
            .cwd = owned_cwd,
            .log_path = log_path,
            .expect_url = expect_url,
        }) catch |err| {
            self.mutex.unlock(io_mod.getIo());
            locked = false;
            return self.failBlockedBackgroundLaunch(
                alloc,
                prepared,
                spawned,
                process_token,
                err,
            );
        };
        const task_snapshot = self.supervisor.snapshotTask(
            alloc,
            .{ .id = process_id },
        ) catch null;
        self.mutex.unlock(io_mod.getIo());
        locked = false;
        defer if (task_snapshot) |value| value.deinit(alloc);

        var saved_initial_record_confirmed = false;
        if (policy == .saved_headless) {
            self.persistInitialRecord(
                alloc,
                task_snapshot,
                background_record_id.?,
            ) catch {
                self.mutex.lockUncancelable(io_mod.getIo());
                _ = self.supervisor.removeTask(alloc, process_id);
                self.mutex.unlock(io_mod.getIo());
                return self.failBlockedBackgroundLaunch(
                    alloc,
                    prepared,
                    spawned,
                    process_token,
                    error.BackgroundPersistenceRequired,
                );
            };
            self.mutex.lockUncancelable(io_mod.getIo());
            _ = self.supervisor.setRecordPersistence(
                process_id,
                .confirmed,
                false,
            );
            self.mutex.unlock(io_mod.getIo());
            saved_initial_record_confirmed = true;
        }

        const owned_process = spawned.release(original_command) catch |err| {
            if (saved_initial_record_confirmed) {
                self.deleteInitialRecordBestEffort(alloc, process_id);
            }
            self.mutex.lockUncancelable(io_mod.getIo());
            _ = self.supervisor.removeTask(alloc, process_id);
            self.mutex.unlock(io_mod.getIo());
            return self.failBlockedBackgroundLaunch(
                alloc,
                prepared,
                spawned,
                process_token,
                err,
            );
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        self.owned_children.appendAssumeCapacity(.{
            .process_id = process_id,
            .process = owned_process,
        });
        self.prepared_launch_reservations -= 1;
        self.mutex.unlock(io_mod.getIo());

        prepared.output.deinit(alloc, false);
        prepared.consumed = true;
        prepared.identity.deinit(alloc);

        var outcome: BackgroundLaunchOutcome =
            if (policy == .process_local_long_lived)
                .process_local_started
            else
                .durable_started;
        if (policy == .durable_long_lived) {
            self.persistInitialRecord(
                alloc,
                task_snapshot,
                background_record_id.?,
            ) catch |err| {
                outcome = try self.handleInitialRecordFailure(
                    alloc,
                    process_id,
                    policy,
                    pid,
                    process_token,
                    err,
                );
                return .{
                    .process_id = process_id,
                    .outcome = outcome,
                    .command = .{
                        .pid = pid,
                        .process_token = process_token,
                        .background_record_id = background_record_id,
                        .command = command,
                        .cwd = owned_cwd,
                        .log_path = log_path,
                        .expect_url = expect_url,
                    },
                };
            };
            if (outcome == .durable_started) {
                self.mutex.lockUncancelable(io_mod.getIo());
                _ = self.supervisor.setRecordPersistence(
                    process_id,
                    .confirmed,
                    false,
                );
                self.mutex.unlock(io_mod.getIo());
            }
        }

        return .{
            .process_id = process_id,
            .outcome = outcome,
            .command = .{
                .pid = pid,
                .process_token = process_token,
                .background_record_id = background_record_id,
                .command = command,
                .cwd = owned_cwd,
                .log_path = log_path,
                .expect_url = expect_url,
            },
        };
    }

    fn persistInitialRecord(
        self: *BackgroundRuntime,
        alloc: Allocator,
        task_snapshot: ?TaskSnapshot,
        background_record_id: StableBackgroundRecordId,
    ) !void {
        const store = self.persisted_store orelse
            return error.BackgroundPersistenceUnavailable;
        const task = task_snapshot orelse return error.OutOfMemory;
        var record = try background_store.Record.fromTaskSnapshot(
            alloc,
            task,
            io_mod.milliTimestamp(),
        );
        defer record.deinit(alloc);
        store.saveRecord(alloc, record) catch |err| {
            if (err != error.SessionChildCommitIndeterminate) return err;
            if (store.loadByStableId(alloc, background_record_id)) |confirmed| {
                var current = confirmed;
                current.deinit(alloc);
                return;
            } else |_| return err;
        };
    }

    fn deleteInitialRecordBestEffort(
        self: *BackgroundRuntime,
        alloc: Allocator,
        process_id: u64,
    ) void {
        const store = self.persisted_store orelse return;
        store.delete(alloc, process_id) catch |err| {
            debug_trace.logf(
                "background",
                "initial record cleanup failed display_id={d} err={s}",
                .{ process_id, @errorName(err) },
            );
        };
    }

    fn handleInitialRecordFailure(
        self: *BackgroundRuntime,
        alloc: Allocator,
        process_id: u64,
        policy: BackgroundLaunchPolicy,
        pid: []const u8,
        process_token: process_supervisor.ProcessInstanceToken,
        failure: anyerror,
    ) !BackgroundLaunchOutcome {
        if (policy == .durable_long_lived) {
            self.mutex.lockUncancelable(io_mod.getIo());
            _ = self.supervisor.setRecordPersistence(
                process_id,
                .initial_record_degraded,
                true,
            );
            self.mutex.unlock(io_mod.getIo());
            debug_trace.logf(
                "background",
                "record persistence degraded policy={s} display_id={d} outcome=initial_record_degraded err={s}",
                .{ @tagName(policy), process_id, @errorName(failure) },
            );
            return .durable_started_degraded;
        }

        const match = self.process_provider.matchToken(
            alloc,
            pid,
            process_token,
        );
        if (match != .matched) {
            return error.BackgroundTerminationIndeterminate;
        }
        try self.process_provider.signalProcess(alloc, pid, process_token);
        self.reapOwnedChild(process_id);
        if (!waitForTokenToDisappear(
            self,
            alloc,
            pid,
            process_token,
            2000,
        )) {
            return error.BackgroundTerminationIndeterminate;
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        _ = self.supervisor.markStopped(process_id);
        self.mutex.unlock(io_mod.getIo());
        return error.BackgroundPersistenceRequired;
    }

    pub fn hasPersistence(self: *BackgroundRuntime) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.persisted_store != null;
    }

    pub fn requestStop(self: *BackgroundRuntime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.stop_requested.store(true, .seq_cst);
        self.mutex.unlock(io_mod.getIo());
    }

    pub fn clearSessionState(self: *BackgroundRuntime, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        const dropped_count = self.supervisor.tasks.items.len;
        if (dropped_count > 0) {
            debug_trace.logf("background", "dropping {d} background task(s) from session state", .{dropped_count});
        }

        const next_id = self.supervisor.next_background_process_id;
        self.supervisor.deinit(alloc);
        self.supervisor.next_background_process_id = next_id;
    }

    pub fn carryForwardWorkspaceState(self: *BackgroundRuntime, alloc: Allocator, workspace_root: []const u8) void {
        self.refreshTasksQuiet(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        const carried_count = self.supervisor.tasks.items.len;
        self.mutex.unlock(io_mod.getIo());

        _ = workspace_root;
        debug_trace.logf(
            "background",
            "carrying forward background tasks count={d} scope=current_workspace",
            .{carried_count},
        );
    }

    pub fn registerBackground(self: *BackgroundRuntime, alloc: Allocator, background: command_contract.BackgroundCommand) !u64 {
        return self.registerBackgroundInternal(alloc, background, false);
    }

    pub fn registerBackgroundDurably(self: *BackgroundRuntime, alloc: Allocator, background: command_contract.BackgroundCommand) !u64 {
        return self.registerBackgroundInternal(alloc, background, true);
    }

    fn registerBackgroundInternal(self: *BackgroundRuntime, alloc: Allocator, background: command_contract.BackgroundCommand, require_persistence: bool) !u64 {
        const process_token = background.process_token orelse
            self.process_provider.captureToken(
                alloc,
                background.pid,
            ) catch null;
        self.mutex.lockUncancelable(io_mod.getIo());
        var locked = true;
        errdefer if (locked) self.mutex.unlock(io_mod.getIo());
        if (require_persistence and self.persisted_store == null) return error.BackgroundPersistenceUnavailable;
        const process_id = try self.supervisor.registerBackground(alloc, .{
            .pid = background.pid,
            .process_token = process_token,
            .background_record_id = background.background_record_id,
            .command = background.command,
            .cwd = background.cwd,
            .log_path = background.log_path,
            .expect_url = background.expect_url,
            .url = background.url,
        });
        const task_snapshot = if (self.persisted_store != null)
            self.supervisor.snapshotTask(alloc, .{ .id = process_id }) catch |err| {
                if (require_persistence) _ = self.supervisor.markStopped(process_id);
                return err;
            }
        else
            null;
        self.mutex.unlock(io_mod.getIo());
        locked = false;

        defer if (task_snapshot) |value| value.deinit(alloc);
        if (task_snapshot) |value| {
            if (require_persistence) {
                const store = self.persisted_store orelse {
                    self.stopRegisteredTaskAfterDurableFailure(
                        alloc,
                        process_id,
                        background.pid,
                        process_token,
                    );
                    return error.BackgroundPersistenceUnavailable;
                };
                store.saveTaskSnapshot(alloc, value) catch |err| {
                    self.disablePersistenceAfterSaveError(alloc, "register background task durably", err);
                    self.stopRegisteredTaskAfterDurableFailure(
                        alloc,
                        process_id,
                        background.pid,
                        process_token,
                    );
                    return err;
                };
            } else {
                self.saveSnapshotOrDisablePersistence(alloc, "register background task", value);
            }
        } else if (require_persistence) {
            self.stopRegisteredTaskAfterDurableFailure(
                alloc,
                process_id,
                background.pid,
                process_token,
            );
            return error.BackgroundPersistenceUnavailable;
        }

        return process_id;
    }

    pub fn findReusableBackground(self: *BackgroundRuntime, alloc: Allocator, cwd: []const u8, command: []const u8, expect_url: bool) !?TaskSnapshot {
        self.refreshTasksQuiet(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.supervisor.findReusableRunningTask(alloc, cwd, command, expect_url);
    }

    pub fn snapshot(self: *BackgroundRuntime, alloc: Allocator) !RuntimeContextSnapshot {
        self.refreshTasksReadOnly(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.supervisor.snapshot(alloc);
    }

    pub fn snapshotTasks(self: *BackgroundRuntime, alloc: Allocator) !TaskListSnapshot {
        self.refreshTasksReadOnly(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.supervisor.snapshotTasks(alloc);
    }

    pub fn snapshotTask(self: *BackgroundRuntime, alloc: Allocator, selection: TaskSelection) !?TaskSnapshot {
        self.refreshTasksReadOnly(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.supervisor.snapshotTask(alloc, selection);
    }

    pub fn snapshotTaskByLogPath(self: *BackgroundRuntime, alloc: Allocator, log_path: []const u8) !?TaskSnapshot {
        self.refreshTasksReadOnly(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.supervisor.snapshotTaskByLogPath(alloc, log_path);
    }

    pub fn readTaskLogSummaryBody(
        self: *BackgroundRuntime,
        alloc: Allocator,
        selection: TaskSelection,
        max_head_bytes: usize,
        max_tail_bytes: usize,
        max_lines: usize,
    ) ![]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        const task = try self.supervisor.snapshotTask(alloc, selection);
        self.mutex.unlock(io_mod.getIo());
        const task_snapshot = task orelse
            return error.BackgroundTaskNotFound;
        defer task_snapshot.deinit(alloc);

        if (task_snapshot.managed_log_name) |name| {
            const capability = authorityCapability(
                task_snapshot.record_authority,
            ) orelse return error.BackgroundLogAuthorityUnavailable;
            var file = try capability.openFileReadOnly(
                alloc,
                .background_logs,
                name,
            );
            defer file.deinit();
            return task_helpers.readManagedTaskLogSummaryBody(
                alloc,
                &file,
                task_snapshot.log_path,
                max_head_bytes,
                max_tail_bytes,
                max_lines,
            );
        }
        return task_helpers.readExternalTaskLogSummaryBody(
            alloc,
            task_snapshot.log_path,
            max_head_bytes,
            max_tail_bytes,
            max_lines,
        );
    }

    fn detectServerUrlForTask(
        self: *BackgroundRuntime,
        alloc: Allocator,
        process_id: u64,
    ) !?[]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        const task = try self.supervisor.snapshotTask(
            alloc,
            .{ .id = process_id },
        );
        self.mutex.unlock(io_mod.getIo());
        const task_snapshot = task orelse return null;
        defer task_snapshot.deinit(alloc);
        if (task_snapshot.state != .running) return null;

        if (task_snapshot.managed_log_name) |name| {
            const capability = authorityCapability(
                task_snapshot.record_authority,
            ) orelse return error.BackgroundLogAuthorityUnavailable;
            var file = try capability.openFileReadOnly(
                alloc,
                .background_logs,
                name,
            );
            defer file.deinit();
            const stat = try file.stat();
            if (stat.size > 64 * 1024) return error.StreamTooLong;
            const content = try file.readRange(
                alloc,
                0,
                @intCast(stat.size),
            );
            defer alloc.free(content);
            return server_detection.detectServerUrlFromContent(
                alloc,
                content,
            );
        }
        return server_detection.detectServerUrl(
            alloc,
            task_snapshot.log_path,
        );
    }

    pub fn publishServerUrl(self: *BackgroundRuntime, alloc: Allocator, process_id: u64, url: []u8) ?[]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.stop_requested.load(.seq_cst)) {
            self.mutex.unlock(io_mod.getIo());
            alloc.free(url);
            return null;
        }

        const result = self.supervisor.publishServerUrl(alloc, process_id, url);
        const task_snapshot = if (result == .updated and self.persisted_store != null)
            self.supervisor.snapshotTask(alloc, .{ .id = process_id }) catch null
        else
            null;
        const resolved = if (result == .updated)
            self.supervisor.snapshotServerUrl(alloc, process_id) catch null
        else
            null;
        self.mutex.unlock(io_mod.getIo());

        defer if (task_snapshot) |value| value.deinit(alloc);
        if (task_snapshot) |value| {
            self.saveSnapshotOrDisablePersistence(alloc, "publish server URL", value);
        }

        return resolved;
    }

    pub fn startUrlWatcher(
        self: *BackgroundRuntime,
        alloc: Allocator,
        process_id: u64,
        background: command_contract.BackgroundCommand,
        callback_ctx: *anyopaque,
        on_url_ready: UrlReadyCallback,
    ) !bool {
        return self.startUrlWatcherWithCleanup(alloc, process_id, background, callback_ctx, on_url_ready, null);
    }

    pub fn startUrlWatcherWithCleanup(
        self: *BackgroundRuntime,
        alloc: Allocator,
        process_id: u64,
        background: command_contract.BackgroundCommand,
        callback_ctx: *anyopaque,
        on_url_ready: UrlReadyCallback,
        on_context_deinit: ?WatcherContextDeinit,
    ) !bool {
        if (!background.expect_url or background.url != null) return false;

        const job = try alloc.create(BackgroundUrlWatchJob);
        errdefer alloc.destroy(job);

        const done = try alloc.create(std.atomic.Value(bool));
        errdefer alloc.destroy(done);
        done.* = std.atomic.Value(bool).init(false);

        job.* = .{
            .alloc = alloc,
            .runtime = self,
            .process_id = process_id,
            .callback_ctx = callback_ctx,
            .on_url_ready = on_url_ready,
            .on_context_deinit = on_context_deinit,
            .done = done,
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.reserveWatcherAppendCapacityLocked(alloc);
        const thread = try std.Thread.spawn(.{}, watcherMain, .{job});
        self.watchers.appendAssumeCapacity(.{ .thread = thread, .done = done });
        return true;
    }

    pub fn pruneWatchers(self: *BackgroundRuntime, alloc: Allocator, join_all: bool) void {
        while (true) {
            self.mutex.lockUncancelable(io_mod.getIo());

            var ready_index: ?usize = null;
            for (self.watchers.items, 0..) |handle, i| {
                if (join_all or handle.done.load(.seq_cst)) {
                    ready_index = i;
                    break;
                }
            }

            if (ready_index == null) {
                self.mutex.unlock(io_mod.getIo());
                return;
            }

            const handle = self.watchers.orderedRemove(ready_index.?);
            self.mutex.unlock(io_mod.getIo());

            handle.thread.join();
            alloc.destroy(handle.done);
        }
    }

    pub fn stopTask(self: *BackgroundRuntime, alloc: Allocator, selection: StopSelection) !?u64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        const candidate = self.supervisor.stopCandidate(
            alloc,
            selection,
        ) catch |err| {
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        self.mutex.unlock(io_mod.getIo());

        const stop_target = candidate orelse return null;
        defer alloc.free(stop_target.pid);
        const process_token = stop_target.process_token orelse
            return error.BackgroundProcessIdentityUnavailable;
        switch (self.process_provider.matchToken(
            alloc,
            stop_target.pid,
            process_token,
        )) {
            .matched => {},
            .missing, .mismatched => {
                self.mutex.lockUncancelable(io_mod.getIo());
                _ = self.supervisor.markStale(stop_target.id);
                self.mutex.unlock(io_mod.getIo());
                return stop_target.id;
            },
            .unavailable => {
                return error.BackgroundProcessIdentityIndeterminate;
            },
        }

        try self.process_provider.signalProcess(
            alloc,
            stop_target.pid,
            process_token,
        );
        self.reapOwnedChild(stop_target.id);
        if (!waitForTokenToDisappear(
            self,
            alloc,
            stop_target.pid,
            process_token,
            2000,
        )) {
            return error.BackgroundTerminationIndeterminate;
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        errdefer self.mutex.unlock(io_mod.getIo());
        _ = self.supervisor.markStopped(stop_target.id);
        const task_snapshot = if (self.persisted_store != null)
            try self.supervisor.snapshotTask(alloc, .{ .id = stop_target.id })
        else
            null;
        self.mutex.unlock(io_mod.getIo());

        defer if (task_snapshot) |value| value.deinit(alloc);
        if (task_snapshot) |value| {
            self.saveSnapshotOrDisablePersistence(alloc, "stop background task", value);
        }
        return stop_target.id;
    }

    pub fn stopAndForgetWorkspace(self: *BackgroundRuntime, alloc: Allocator, workspace_root: []const u8) void {
        const StopProbe = struct {
            id: u64,
            pid: []u8,
            process_token: process_supervisor.ProcessInstanceToken,
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        var probes: std.ArrayList(StopProbe) = .empty;
        for (self.supervisor.tasks.items) |task| {
            if (task.state != .running) continue;
            if (!process_supervisor.pathBelongsToWorkspace(task.cwd, workspace_root)) continue;
            const process_token = task.process_token orelse continue;
            const pid = alloc.dupe(u8, task.pid) catch continue;
            probes.append(alloc, .{
                .id = task.id,
                .pid = pid,
                .process_token = process_token,
            }) catch {
                alloc.free(pid);
                continue;
            };
        }
        self.mutex.unlock(io_mod.getIo());
        defer {
            for (probes.items) |probe| alloc.free(probe.pid);
            probes.deinit(alloc);
        }

        var signaled: usize = 0;
        var removable_ids: std.ArrayList(u64) = .empty;
        defer removable_ids.deinit(alloc);
        for (probes.items) |probe| {
            switch (self.process_provider.matchToken(
                alloc,
                probe.pid,
                probe.process_token,
            )) {
                .matched => {
                    var did_signal = true;
                    self.process_provider.signalProcess(
                        alloc,
                        probe.pid,
                        probe.process_token,
                    ) catch |err| switch (err) {
                        error.BackgroundProcessIdentityIndeterminate => {
                            continue;
                        },
                        else => did_signal = false,
                    };
                    self.reapOwnedChild(probe.id);
                    if (did_signal) signaled += 1;
                },
                .missing, .mismatched => {
                    self.reapOwnedChild(probe.id);
                },
                .unavailable => continue,
            }
            removable_ids.append(alloc, probe.id) catch continue;
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        var removed: usize = 0;
        for (removable_ids.items) |process_id| {
            if (self.supervisor.removeTask(alloc, process_id)) {
                removed += 1;
            }
        }
        self.mutex.unlock(io_mod.getIo());

        debug_trace.logf(
            "background",
            "reset stop/forget scope=current_workspace signaled={d} removed={d}",
            .{ signaled, removed },
        );
    }

    pub fn restoreFromPersistence(self: *BackgroundRuntime, alloc: Allocator, background_dir: []const u8, workspace_root: []const u8) !void {
        try self.enablePersistence(alloc, background_dir);
        try self.restoreCurrentPersistence(alloc, workspace_root);
    }

    pub fn restoreFromManagedPersistence(
        self: *BackgroundRuntime,
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        source_session_id: []const u8,
        workspace_root: []const u8,
    ) !void {
        try self.enableManagedPersistence(
            alloc,
            capability,
            source_session_id,
        );
        try self.restoreCurrentPersistence(alloc, workspace_root);
    }

    fn restoreCurrentPersistence(
        self: *BackgroundRuntime,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !void {
        const store = self.persisted_store orelse return;
        var records = try store.list(alloc);
        defer {
            for (records.items) |*record| record.deinit(alloc);
            records.deinit(alloc);
        }

        var restored: usize = 0;
        var stale: usize = 0;
        for (records.items) |*record| {
            if (!background_store.recordBelongsToWorkspace(record.*, workspace_root)) continue;
            const prepared = background_record_restore.prepare(alloc, .{
                .process_provider = self.process_provider,
                .store = store,
                .record = record,
                .source_session_id = self.source_session_id,
                .authority = if (self.activeSessionCapability()) |capability|
                    .{ .writable = capability }
                else
                    null,
            });
            const task_snapshot = switch (prepared) {
                .not_attachable => {
                    stale += 1;
                    continue;
                },
                .skipped => continue,
                .task => |task| task,
            };
            defer task_snapshot.deinit(alloc);

            self.mutex.lockUncancelable(io_mod.getIo());
            _ = self.supervisor.restoreBackground(
                alloc,
                task_snapshot,
            ) catch |err| {
                if (err == error.BackgroundIdentityUnavailable) {
                    debug_trace.logf(
                        "background",
                        "restore identity unavailable source_session={s}",
                        .{task_snapshot.source_session_id.?},
                    );
                }
            };
            self.mutex.unlock(io_mod.getIo());
            restored += 1;
        }

        debug_trace.logf(
            "background",
            "resume restored background scope=current_workspace live={d} stale={d}",
            .{ restored, stale },
        );
    }

    pub fn restoreWorkspaceFromStore(
        self: *BackgroundRuntime,
        alloc: Allocator,
        store: session_store.Store,
        workspace_root: []const u8,
        exclude_session_id: ?[]const u8,
    ) !void {
        var sessions = try store.list(alloc);
        defer {
            for (sessions.items) |*summary| summary.deinit(alloc);
            sessions.deinit(alloc);
        }
        var restored: usize = 0;
        var stale: usize = 0;
        for (sessions.items) |summary| {
            const session_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, session_workspace, workspace_root)) continue;
            if (exclude_session_id) |excluded| {
                if (std.mem.eql(u8, summary.id, excluded)) continue;
            }
            const capability = try alloc.create(
                session_child_store.SessionChildCapability,
            );
            var capability_owned = true;
            errdefer if (capability_owned) alloc.destroy(capability);
            capability.* = store.openChildCapabilityReadOnly(
                alloc,
                summary.id,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    alloc.destroy(capability);
                    capability_owned = false;
                    continue;
                },
            };
            var capability_initialized = true;
            defer if (capability_initialized) capability.deinit();
            var child_store = background_store.Store.initManaged(capability);

            var records = child_store.list(alloc) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            defer {
                for (records.items) |*record| record.deinit(alloc);
                records.deinit(alloc);
            }

            for (records.items) |*record| {
                if (!background_store.recordBelongsToWorkspace(record.*, workspace_root)) continue;
                const prepared = background_record_restore.prepare(alloc, .{
                    .process_provider = self.process_provider,
                    .store = child_store,
                    .record = record,
                    .source_session_id = summary.id,
                    .authority = .{ .read_only = capability },
                });
                const task_snapshot = switch (prepared) {
                    .not_attachable => {
                        stale += 1;
                        continue;
                    },
                    .skipped => continue,
                    .task => |task| task,
                };
                defer task_snapshot.deinit(alloc);
                if (self.hasRunningRecordIdentity(
                    summary.id,
                    record.*,
                )) continue;
                self.mutex.lockUncancelable(io_mod.getIo());
                _ = self.supervisor.restoreBackground(
                    alloc,
                    task_snapshot,
                ) catch |err| {
                    if (err == error.BackgroundIdentityUnavailable) {
                        debug_trace.logf(
                            "background",
                            "restore identity unavailable source_session={s}",
                            .{summary.id},
                        );
                    }
                };
                self.mutex.unlock(io_mod.getIo());
                restored += 1;
            }
            const retained_source_session_id = try alloc.dupe(
                u8,
                summary.id,
            );
            var retained_source_owned = true;
            errdefer if (retained_source_owned) {
                alloc.free(retained_source_session_id);
            };
            try self.retained_source_capabilities.append(alloc, .{
                .source_session_id = retained_source_session_id,
                .capability = capability,
            });
            retained_source_owned = false;
            capability_initialized = false;
            capability_owned = false;
        }

        debug_trace.logf(
            "background",
            "restored background sessions scope=current_workspace live={d} stale={d}",
            .{ restored, stale },
        );
    }

    pub fn refreshTasksQuiet(self: *BackgroundRuntime, alloc: Allocator) void {
        if (self.source_session_id) |source_session_id| {
            self.retryDegradedRecordsForSource(
                alloc,
                source_session_id,
            );
        }
        const Callback = struct {
            fn onComplete(_: *anyopaque, _: TaskCompletion) void {}
        };
        self.refreshTasksInternal(
            alloc,
            @ptrCast(self),
            Callback.onComplete,
            true,
        );
    }

    fn refreshTasksReadOnly(
        self: *BackgroundRuntime,
        alloc: Allocator,
    ) void {
        const Callback = struct {
            fn onComplete(_: *anyopaque, _: TaskCompletion) void {}
        };
        self.refreshTasksInternal(
            alloc,
            @ptrCast(self),
            Callback.onComplete,
            false,
        );
    }

    pub fn refreshTasks(self: *BackgroundRuntime, alloc: Allocator, callback_ctx: *anyopaque, on_completion: TaskCompletionCallback) void {
        self.refreshTasksInternal(
            alloc,
            callback_ctx,
            on_completion,
            true,
        );
    }

    fn refreshTasksInternal(
        self: *BackgroundRuntime,
        alloc: Allocator,
        callback_ctx: *anyopaque,
        on_completion: TaskCompletionCallback,
        persist_updates: bool,
    ) void {
        if (self.stop_requested.load(.seq_cst)) return;

        const now = io_mod.milliTimestamp();
        if (persist_updates) {
            if (self.last_refresh_ms != 0 and
                now - self.last_refresh_ms < 500)
            {
                return;
            }
            self.last_refresh_ms = now;
        }

        const Probe = struct {
            id: u64,
            pid: []u8,
            process_token: ?process_supervisor.ProcessInstanceToken,
            log_path: []u8,
            managed_log_name: ?[]u8,
            record_authority: process_supervisor.RecordAuthority,
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        var probes: std.ArrayList(Probe) = .empty;
        for (self.supervisor.tasks.items) |task| {
            if (task.state != .running) continue;

            const pid = alloc.dupe(u8, task.pid) catch continue;
            errdefer alloc.free(pid);
            const log_path = alloc.dupe(u8, task.log_path) catch {
                alloc.free(pid);
                continue;
            };
            errdefer alloc.free(log_path);
            const managed_log_name = if (task.managed_log_name) |name|
                alloc.dupe(u8, name) catch {
                    alloc.free(pid);
                    alloc.free(log_path);
                    continue;
                }
            else
                null;
            errdefer if (managed_log_name) |name| alloc.free(name);
            probes.append(alloc, .{
                .id = task.id,
                .pid = pid,
                .process_token = task.process_token,
                .log_path = log_path,
                .managed_log_name = managed_log_name,
                .record_authority = task.record_authority,
            }) catch {
                alloc.free(pid);
                alloc.free(log_path);
                if (managed_log_name) |name| alloc.free(name);
                continue;
            };
        }
        self.mutex.unlock(io_mod.getIo());
        defer {
            for (probes.items) |probe| {
                alloc.free(probe.pid);
                alloc.free(probe.log_path);
                if (probe.managed_log_name) |name| alloc.free(name);
            }
            probes.deinit(alloc);
        }

        for (probes.items) |probe| {
            const exit_code = detectExitCodeForProbe(
                alloc,
                probe,
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    self.mutex.lockUncancelable(io_mod.getIo());
                    const completion = self.supervisor.markStale(probe.id);
                    if (!persist_updates and completion != null) {
                        _ = self.supervisor.markRecordProjectionDegraded(
                            probe.id,
                        );
                    }
                    const task_snapshot = if (persist_updates and
                        completion != null and
                        self.persisted_store != null)
                        self.supervisor.snapshotTask(alloc, .{ .id = probe.id }) catch null
                    else
                        null;
                    self.mutex.unlock(io_mod.getIo());

                    defer if (task_snapshot) |value| value.deinit(alloc);
                    if (task_snapshot) |value| {
                        self.saveSnapshotOrDisablePersistence(alloc, "refresh stale background task", value);
                    }
                    if (completion) |event| {
                        debug_trace.logf(
                            "background",
                            "background task lifecycle display_id={d} outcome=stale",
                            .{event.id},
                        );
                        on_completion(callback_ctx, event);
                    }
                    continue;
                },
                else => null,
            };
            if (exit_code == null) {
                const process_token = probe.process_token orelse {
                    self.mutex.lockUncancelable(io_mod.getIo());
                    const completion = self.supervisor.markStale(probe.id);
                    self.mutex.unlock(io_mod.getIo());
                    if (completion) |event| {
                        on_completion(callback_ctx, event);
                    }
                    continue;
                };
                switch (self.process_provider.matchToken(
                    alloc,
                    probe.pid,
                    process_token,
                )) {
                    .matched => continue,
                    .unavailable => continue,
                    .missing, .mismatched => {},
                }
            }

            self.mutex.lockUncancelable(io_mod.getIo());
            const completion = self.supervisor.markCompleted(probe.id, exit_code);
            if (!persist_updates and completion != null) {
                _ = self.supervisor.markRecordProjectionDegraded(
                    probe.id,
                );
            }
            const task_snapshot = if (persist_updates and
                completion != null and
                self.persisted_store != null)
                self.supervisor.snapshotTask(alloc, .{ .id = probe.id }) catch null
            else
                null;
            self.mutex.unlock(io_mod.getIo());

            defer if (task_snapshot) |value| value.deinit(alloc);
            if (task_snapshot) |value| {
                self.saveSnapshotOrDisablePersistence(alloc, "refresh background task", value);
            }
            if (completion) |event| {
                self.reapOwnedChild(event.id);
                var exit_buf: [32]u8 = undefined;
                const exit_text = if (event.exit_code) |code|
                    std.fmt.bufPrint(&exit_buf, "{d}", .{code}) catch "?"
                else
                    "null";
                debug_trace.logf("background", "background task completed id={d} state={s} exit_code={s}", .{
                    event.id,
                    @tagName(event.state),
                    exit_text,
                });
                on_completion(callback_ctx, event);
            }
        }
    }

    fn reserveWatcherAppendCapacityLocked(self: *BackgroundRuntime, alloc: Allocator) !void {
        try self.watchers.ensureUnusedCapacity(alloc, 1);
    }

    fn reapOwnedChild(
        self: *BackgroundRuntime,
        process_id: u64,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        var owned: ?OwnedBackgroundChild = null;
        for (self.owned_children.items, 0..) |candidate, index| {
            if (candidate.process_id != process_id) continue;
            owned = self.owned_children.orderedRemove(index);
            break;
        }
        self.mutex.unlock(io_mod.getIo());
        if (owned) |*entry| {
            entry.process.wait();
        }
    }

    fn forgetOwnedChild(
        self: *BackgroundRuntime,
        process_id: u64,
    ) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        for (self.owned_children.items, 0..) |candidate, index| {
            if (candidate.process_id != process_id) continue;
            var owned = self.owned_children.orderedRemove(index);
            owned.process.forget();
            break;
        }
        self.mutex.unlock(io_mod.getIo());
    }

    fn terminateOwnedUnrecordedProcesses(
        self: *BackgroundRuntime,
        alloc: Allocator,
    ) void {
        while (true) {
            self.mutex.lockUncancelable(io_mod.getIo());
            var target: ?struct {
                id: u64,
                pid: []u8,
                token: process_supervisor.ProcessInstanceToken,
            } = null;
            for (self.owned_children.items) |owned| {
                for (self.supervisor.tasks.items) |candidate| {
                    if (candidate.id != owned.process_id) continue;
                    if (candidate.policy !=
                        .process_local_long_lived and
                        candidate.record_persistence !=
                            .initial_record_degraded)
                    {
                        break;
                    }
                    const token = candidate.process_token orelse break;
                    const pid = alloc.dupe(
                        u8,
                        candidate.pid,
                    ) catch break;
                    target = .{
                        .id = candidate.id,
                        .pid = pid,
                        .token = token,
                    };
                    break;
                }
                if (target != null) break;
            }
            self.mutex.unlock(io_mod.getIo());

            const current = target orelse return;
            defer alloc.free(current.pid);
            const token_match = self.process_provider.matchToken(
                alloc,
                current.pid,
                current.token,
            );
            switch (token_match) {
                .matched => {
                    var safe_to_reap = true;
                    self.process_provider.signalProcess(
                        alloc,
                        current.pid,
                        current.token,
                    ) catch |err| switch (err) {
                        error.BackgroundProcessIdentityIndeterminate => {
                            safe_to_reap = false;
                        },
                        else => {},
                    };
                    if (safe_to_reap) {
                        self.reapOwnedChild(current.id);
                    } else {
                        self.forgetOwnedChild(current.id);
                        continue;
                    }
                },
                .missing, .mismatched => {
                    self.reapOwnedChild(current.id);
                },
                .unavailable => {
                    self.forgetOwnedChild(current.id);
                    debug_trace.logf(
                        "background",
                        "shutdown process identity indeterminate display_id={d}",
                        .{current.id},
                    );
                    continue;
                },
            }
            self.mutex.lockUncancelable(io_mod.getIo());
            _ = self.supervisor.markStopped(current.id);
            self.mutex.unlock(io_mod.getIo());
        }
    }

    fn saveSnapshotOrDisablePersistence(self: *BackgroundRuntime, alloc: Allocator, operation: []const u8, task_snapshot: TaskSnapshot) void {
        if (task_snapshot.background_record_id != null) {
            self.saveDurableSnapshotIfAuthorized(
                alloc,
                operation,
                task_snapshot,
            );
            return;
        }
        self.persisted_store.?.saveTaskSnapshot(alloc, task_snapshot) catch |err| {
            self.disablePersistenceAfterSaveError(alloc, operation, err);
        };
    }

    fn saveDurableSnapshotIfAuthorized(
        self: *BackgroundRuntime,
        alloc: Allocator,
        operation: []const u8,
        task_snapshot: TaskSnapshot,
    ) void {
        const capability = switch (task_snapshot.record_authority) {
            .writable => |value| value,
            .none, .read_only => {
                self.markDurableTaskDegraded(
                    task_snapshot,
                    operation,
                    "BackgroundRecordAuthorityUnavailable",
                );
                return;
            },
        };
        const source_session_id = task_snapshot.source_session_id orelse return;
        const current_source_session_id = self.source_session_id orelse return;
        if (!std.mem.eql(
            u8,
            source_session_id,
            current_source_session_id,
        )) return;
        const store = self.persisted_store orelse return;
        const active_capability =
            self.activeSessionCapability() orelse return;
        if (active_capability != capability) return;
        const stable_id = task_snapshot.background_record_id orelse
            return;
        const durable_record_id = task_snapshot.durable_record_id orelse
            return;
        const exact_record_exists = blk: {
            if (store.loadByStableId(alloc, stable_id)) |loaded_record| {
                var current = loaded_record;
                defer current.deinit(alloc);
                if (current.id != durable_record_id) {
                    self.markDurableTaskDegraded(
                        task_snapshot,
                        operation,
                        "BackgroundRecordIdentityMismatch",
                    );
                    return;
                }
                break :blk true;
            } else |err| switch (err) {
                error.BackgroundRecordNotFound => {},
                else => {
                    self.markDurableTaskDegraded(
                        task_snapshot,
                        operation,
                        @errorName(err),
                    );
                    return;
                },
            }
            if (store.load(alloc, durable_record_id)) |loaded_record| {
                var current = loaded_record;
                current.deinit(alloc);
                self.markDurableTaskDegraded(
                    task_snapshot,
                    operation,
                    "BackgroundRecordIdentityMismatch",
                );
                return;
            } else |err| switch (err) {
                error.BackgroundRecordNotFound => {},
                else => {
                    self.markDurableTaskDegraded(
                        task_snapshot,
                        operation,
                        @errorName(err),
                    );
                    return;
                },
            }
            break :blk false;
        };
        if (!exact_record_exists) {
            const process_token = task_snapshot.process_token orelse {
                self.markDurableTaskDegraded(
                    task_snapshot,
                    operation,
                    "BackgroundProcessIdentityUnavailable",
                );
                return;
            };
            if (task_snapshot.state == .running and
                self.process_provider.matchToken(
                    alloc,
                    task_snapshot.pid,
                    process_token,
                ) != .matched)
            {
                self.markDurableTaskDegraded(
                    task_snapshot,
                    operation,
                    "BackgroundProcessIdentityIndeterminate",
                );
                return;
            }
        }

        var record = background_store.Record.fromTaskSnapshot(
            alloc,
            task_snapshot,
            io_mod.milliTimestamp(),
        ) catch return;
        defer record.deinit(alloc);
        store.saveRecord(alloc, record) catch |err| {
            var confirmed = false;
            if (err == error.SessionChildCommitIndeterminate) {
                if (store.loadByStableId(
                    alloc,
                    task_snapshot.background_record_id.?,
                )) |current| {
                    var loaded = current;
                    loaded.deinit(alloc);
                    confirmed = true;
                } else |_| {}
            }
            self.mutex.lockUncancelable(io_mod.getIo());
            const should_warn = self.supervisor.markRecordDegraded(
                task_snapshot.id,
                .record_update_degraded,
            );
            if (confirmed) {
                _ = self.supervisor.setRecordPersistence(
                    task_snapshot.id,
                    .confirmed,
                    false,
                );
            }
            self.mutex.unlock(io_mod.getIo());
            if (!confirmed and should_warn) {
                debug_trace.logf(
                    "background",
                    "record update degraded policy={s} display_id={d} outcome=record_update_degraded operation={s} err={s}",
                    .{
                        @tagName(task_snapshot.policy),
                        task_snapshot.id,
                        operation,
                        @errorName(err),
                    },
                );
            }
            return;
        };
        self.mutex.lockUncancelable(io_mod.getIo());
        _ = self.supervisor.setRecordPersistence(
            task_snapshot.id,
            .confirmed,
            false,
        );
        self.mutex.unlock(io_mod.getIo());
    }

    fn markDurableTaskDegraded(
        self: *BackgroundRuntime,
        task_snapshot: TaskSnapshot,
        operation: []const u8,
        reason: []const u8,
    ) void {
        const degraded_state: process_supervisor.RecordPersistenceState =
            if (task_snapshot.record_persistence ==
            .initial_record_degraded)
                .initial_record_degraded
            else
                .record_update_degraded;
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_warn = self.supervisor.markRecordDegraded(
            task_snapshot.id,
            degraded_state,
        );
        self.mutex.unlock(io_mod.getIo());
        if (!should_warn) return;
        debug_trace.logf(
            "background",
            "record update degraded policy={s} display_id={d} outcome={s} operation={s} err={s}",
            .{
                @tagName(task_snapshot.policy),
                task_snapshot.id,
                @tagName(degraded_state),
                operation,
                reason,
            },
        );
    }

    fn saveSnapshotsOrDisablePersistence(self: *BackgroundRuntime, alloc: Allocator, operation: []const u8, task_snapshots: []const TaskSnapshot) void {
        for (task_snapshots) |task_snapshot| {
            if (self.persisted_store == null) return;
            self.saveSnapshotOrDisablePersistence(alloc, operation, task_snapshot);
        }
    }

    fn disablePersistenceAfterSaveError(self: *BackgroundRuntime, alloc: Allocator, operation: []const u8, err: anyerror) void {
        debug_trace.logf("background", "{s} failed with {}; disabling background persistence", .{ operation, err });
        self.disablePersistence(alloc);
    }

    fn disablePersistence(self: *BackgroundRuntime, alloc: Allocator) void {
        if (self.persisted_store) |*store| {
            store.deinit(alloc);
            self.persisted_store = null;
        }
    }

    fn stopRegisteredTaskAfterDurableFailure(
        self: *BackgroundRuntime,
        alloc: Allocator,
        process_id: u64,
        pid: []const u8,
        process_token: ?process_supervisor.ProcessInstanceToken,
    ) void {
        if (process_token) |token| {
            if (self.process_provider.matchToken(
                alloc,
                pid,
                token,
            ) == .matched) {
                self.process_provider.signalProcess(
                    alloc,
                    pid,
                    token,
                ) catch {};
            }
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        _ = self.supervisor.markStopped(process_id);
        self.mutex.unlock(io_mod.getIo());
    }

    fn hasRunningRecordIdentity(
        self: *BackgroundRuntime,
        source_session_id: []const u8,
        record: background_store.Record,
    ) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());

        const stable_id = record.background_record_id orelse return false;
        for (self.supervisor.tasks.items) |task| {
            if (task.state != .running) continue;
            const task_source = task.source_session_id orelse continue;
            const task_stable_id = task.background_record_id orelse continue;
            if (!std.mem.eql(
                u8,
                task_source,
                source_session_id,
            )) continue;
            if (!std.mem.eql(
                u8,
                &task_stable_id,
                &stable_id,
            )) continue;
            return true;
        }
        return false;
    }
};

fn captureSpawnedProcessToken(
    self: *BackgroundRuntime,
    alloc: Allocator,
    pid: []const u8,
) !process_supervisor.ProcessInstanceToken {
    var attempt: usize = 1;
    while (true) : (attempt += 1) {
        return self.process_provider.captureToken(
            alloc,
            pid,
        ) catch |err| switch (err) {
            error.ProcessIdentityUnavailable => {
                if (attempt >= process_identity_capture_attempts) {
                    debug_trace.logf(
                        "background",
                        "process identity capture exhausted pid={s} attempt={d}/{d} err={s}",
                        .{
                            pid,
                            attempt,
                            process_identity_capture_attempts,
                            @errorName(err),
                        },
                    );
                    return err;
                }
                debug_trace.logf(
                    "background",
                    "process identity capture retry pid={s} attempt={d}/{d} err={s}",
                    .{
                        pid,
                        attempt,
                        process_identity_capture_attempts,
                        @errorName(err),
                    },
                );
                io_mod.sleep(process_identity_capture_retry_delay_ns);
                continue;
            },
            else => return err,
        };
    }
}

fn waitForTokenToDisappear(
    self: *BackgroundRuntime,
    alloc: Allocator,
    pid: []const u8,
    token: process_supervisor.ProcessInstanceToken,
    timeout_ms: i64,
) bool {
    const start = io_mod.milliTimestamp();
    while (io_mod.milliTimestamp() - start <= timeout_ms) {
        const match = self.process_provider.matchToken(
            alloc,
            pid,
            token,
        );
        if (match == .missing or match == .mismatched) return true;
        if (match == .unavailable) return false;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

fn authorityCapability(
    authority: process_supervisor.RecordAuthority,
) ?*session_child_store.SessionChildCapability {
    return switch (authority) {
        .none => null,
        .read_only, .writable => |capability| capability,
    };
}

fn detectExitCodeForProbe(alloc: Allocator, probe: anytype) !?i32 {
    if (probe.managed_log_name) |name| {
        const capability = authorityCapability(
            probe.record_authority,
        ) orelse return error.BackgroundLogAuthorityUnavailable;
        var file = try capability.openFileReadOnly(
            alloc,
            .background_logs,
            name,
        );
        defer file.deinit();
        const stat = try file.stat();
        const size: usize = @intCast(stat.size);
        const tail_size: usize = @min(size, 4096);
        const content = try file.readRange(
            alloc,
            size - tail_size,
            tail_size,
        );
        defer alloc.free(content);
        return background_record_liveness.detectExitCodeFromContent(
            content,
        );
    }
    return background_record_liveness.detectExitCodeFromExternalPath(
        alloc,
        probe.log_path,
    );
}

fn watcherMain(job: *BackgroundUrlWatchJob) void {
    defer {
        if (job.on_context_deinit) |deinit| deinit(job.alloc, job.callback_ctx);
        job.done.store(true, .seq_cst);
        const alloc = job.alloc;
        alloc.destroy(job);
    }

    var attempts: usize = 0;
    while (attempts < 75) : (attempts += 1) {
        if (job.runtime.stop_requested.load(.seq_cst)) return;

        const url = job.runtime.detectServerUrlForTask(
            job.alloc,
            job.process_id,
        ) catch {
            if (!waitForWatcherRetry(job.runtime)) return;
            continue;
        };

        if (url) |detected| {
            const resolved = job.runtime.publishServerUrl(job.alloc, job.process_id, detected) orelse return;
            defer job.alloc.free(resolved);
            job.on_url_ready(job.callback_ctx, job.process_id, resolved);
            return;
        }

        if (!waitForWatcherRetry(job.runtime)) return;
    }
}

fn waitForWatcherRetry(runtime: *BackgroundRuntime) bool {
    const sleep_chunk_ns: u64 = 20 * std.time.ns_per_ms;
    var remaining: u64 = watcher_retry_interval_ns;
    while (remaining > 0) {
        if (runtime.stop_requested.load(.seq_cst)) return false;
        const chunk = @min(remaining, sleep_chunk_ns);
        io_mod.sleep(chunk);
        remaining -|= chunk;
    }
    return !runtime.stop_requested.load(.seq_cst);
}

fn blockedWrapperCleanupTimeoutMs() i64 {
    if (comptime builtin.is_test) {
        if (blocked_wrapper_cleanup_timeout_ms_for_test) |timeout_ms| {
            return timeout_ms;
        }
    }
    return blocked_wrapper_cleanup_timeout_ms;
}

fn nextStableRecordId() !StableBackgroundRecordId {
    if (comptime builtin.is_test) {
        if (stable_record_id_for_test) |next| return next();
    }
    var candidate: StableBackgroundRecordId = undefined;
    try std.Io.randomSecure(io_mod.getIo(), &candidate);
    return candidate;
}

fn initBackgroundDir(alloc: Allocator, root_dir: std.Io.Dir) ![]u8 {
    try root_dir.createDirPath(io_mod.getIo(), "background");
    return io_mod.dirRealpathAlloc(alloc, root_dir, "background");
}

fn tmpRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn tmpPath(alloc: Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, name });
}

fn writeAbsoluteFile(path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 8192);
}

fn seedRecord(alloc: Allocator, id: u64) !background_store.Record {
    return .{
        .id = id,
        .pid = try alloc.dupe(u8, "100"),
        .command = try alloc.dupe(u8, "npm run dev"),
        .cwd = try alloc.dupe(u8, "/tmp/fx"),
        .log_path = try alloc.dupe(u8, "/tmp/fx.log"),
        .expect_url = true,
        .server_url = null,
        .started_at_ms = 1,
        .updated_at_ms = 2,
        .exit_code = null,
        .state = .running,
    };
}

fn seedRestorableRecord(
    alloc: Allocator,
    id: u64,
    workspace_root: []const u8,
    log_path: []const u8,
) !background_store.Record {
    const pid = try alloc.dupe(u8, "12345");
    errdefer alloc.free(pid);
    const process_token = try alloc.dupe(
        u8,
        "linux:00112233445566778899aabbccddeeff:12345",
    );
    errdefer alloc.free(process_token);
    const command = try alloc.dupe(u8, "npm run dev");
    errdefer alloc.free(command);
    const cwd = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(cwd);
    const owned_log_path = try alloc.dupe(u8, log_path);
    errdefer alloc.free(owned_log_path);
    const external_path = try alloc.dupe(u8, log_path);
    errdefer alloc.free(external_path);

    return .{
        .id = id,
        .background_record_id = [_]u8{@intCast(id)} ** 16,
        .process_token = process_token,
        .pid = pid,
        .command = command,
        .cwd = cwd,
        .log_path = owned_log_path,
        .log_storage = .{ .external = .{ .path = external_path } },
        .expect_url = true,
        .started_at_ms = 1,
        .updated_at_ms = 2,
        .state = .running,
    };
}

fn testDurableSessionState(
    alloc: Allocator,
    id: []const u8,
    workspace_root: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin_workspace_root = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin_workspace_root);
    const owned_workspace_root = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(owned_workspace_root);
    const model = try alloc.dupe(u8, "test/model");
    errdefer alloc.free(model);
    return .{
        .id = owned_id,
        .origin_workspace_root = origin_workspace_root,
        .workspace_root = owned_workspace_root,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = model,
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

const test_background_release_byte: u8 = 0x06;
const test_background_ready_byte: u8 = 'R';
const test_blocked_background_wrapper_command = std.fmt.comptimePrint(
    "printf '{c}' >&2\n" ++
        "release=\n" ++
        "IFS= read -r release || exit 125\n" ++
        "expected=$(printf '\\006')\n" ++
        "[ \"$release\" = \"$expected\" ] || exit 125\n" ++
        "script=$(command cat; command printf .)\n" ++
        "script=${{script%.}}\n" ++
        "exec 0</dev/null\n" ++
        "exec 2>&1\n" ++
        "trap '' HUP\n" ++
        "eval \"$script\"\n" ++
        "status=$?\n" ++
        "printf '\\n{s}%s\\n' \"$status\"\n" ++
        "exit \"$status\"",
    .{ test_background_ready_byte, background_process_provider.exit_marker },
);

fn testBackgroundRuntime() BackgroundRuntime {
    return BackgroundRuntime.init(
        background_process_provider.process_supervisor_test_provider,
    );
}

const TestPreparedProcess = struct {
    alloc: Allocator,
    child: std.process.Child,
    ready_read: std.Io.File,
    release_write: std.Io.File,
    pid: []u8,
    controls_closed: bool = false,

    fn handle(self: *TestPreparedProcess) background_process_provider.PreparedProcess {
        return .{
            .context = self,
            .pid = self.pid,
            .close_and_wait_fn = closeAndWait,
            .wait_for_exit_fn = waitForExit,
            .detach_reaper_fn = detachReaper,
            .release_fn = release,
        };
    }

    fn closeControls(self: *TestPreparedProcess) void {
        if (self.controls_closed) return;
        self.release_write.close(io_mod.getIo());
        self.ready_read.close(io_mod.getIo());
        self.child.stdin = null;
        self.child.stderr = null;
        self.controls_closed = true;
    }

    fn closeAndWait(
        raw: *anyopaque,
        _: ?process_supervisor.ProcessInstanceToken,
        timeout_ms: i64,
    ) background_process_provider.CleanupStatus {
        const self: *TestPreparedProcess = @ptrCast(@alignCast(raw));
        self.closeControls();
        return if (waitForOwnedChild(self, timeout_ms)) .confirmed else .timed_out;
    }

    fn waitForExit(
        raw: *anyopaque,
        _: ?process_supervisor.ProcessInstanceToken,
        timeout_ms: i64,
    ) bool {
        const self: *TestPreparedProcess = @ptrCast(@alignCast(raw));
        return waitForOwnedChild(self, timeout_ms);
    }

    fn waitForOwnedChild(self: *TestPreparedProcess, timeout_ms: i64) bool {
        const started_ms = io_mod.milliTimestamp();
        while (true) {
            const pid = self.child.id orelse return true;
            if (std.c.waitpid(pid, null, std.c.W.NOHANG) == pid) {
                self.child.id = null;
                self.alloc.free(self.pid);
                self.alloc.destroy(self);
                return true;
            }
            if (io_mod.milliTimestamp() - started_ms >= timeout_ms) {
                return false;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn detachReaper(raw: *anyopaque) bool {
        const self: *TestPreparedProcess = @ptrCast(@alignCast(raw));
        self.closeControls();
        const thread = std.Thread.spawn(
            .{},
            reapDetachedTestChild,
            .{self.child},
        ) catch return false;
        self.alloc.free(self.pid);
        self.alloc.destroy(self);
        thread.detach();
        return true;
    }

    fn release(
        raw: *anyopaque,
        command: []const u8,
    ) background_process_provider.ProviderError!background_process_provider.OwnedProcess {
        const self: *TestPreparedProcess = @ptrCast(@alignCast(raw));
        const owned = try self.alloc.create(TestOwnedProcess);
        errdefer self.alloc.destroy(owned);
        self.release_write.writeStreamingAll(
            io_mod.getIo(),
            &.{ test_background_release_byte, '\n' },
        ) catch return error.BackgroundReleaseFailed;
        self.release_write.writeStreamingAll(
            io_mod.getIo(),
            command,
        ) catch return error.BackgroundReleaseFailed;
        self.release_write.close(io_mod.getIo());
        self.ready_read.close(io_mod.getIo());
        self.child.stdin = null;
        self.child.stderr = null;
        owned.* = .{ .alloc = self.alloc, .child = self.child };
        self.alloc.free(self.pid);
        self.alloc.destroy(self);
        return .{
            .context = owned,
            .wait_fn = TestOwnedProcess.wait,
            .forget_fn = TestOwnedProcess.forget,
        };
    }
};

const TestOwnedProcess = struct {
    alloc: Allocator,
    child: std.process.Child,

    fn wait(raw: *anyopaque) void {
        const self: *TestOwnedProcess = @ptrCast(@alignCast(raw));
        _ = self.child.wait(io_mod.getIo()) catch {};
        self.alloc.destroy(self);
    }

    fn forget(raw: *anyopaque) void {
        const self: *TestOwnedProcess = @ptrCast(@alignCast(raw));
        self.alloc.destroy(self);
    }
};

fn reapDetachedTestChild(child: std.process.Child) void {
    var owned_child = child;
    _ = owned_child.wait(io_mod.getIo()) catch {};
}

fn wrapTestPreparedProcess(
    alloc: Allocator,
    child: std.process.Child,
) !background_process_provider.PreparedProcess {
    const state = try alloc.create(TestPreparedProcess);
    errdefer alloc.destroy(state);
    const pid = try std.fmt.allocPrint(alloc, "{d}", .{child.id.?});
    state.* = .{
        .alloc = alloc,
        .child = child,
        .ready_read = child.stderr.?,
        .release_write = child.stdin.?,
        .pid = pid,
    };
    return state.handle();
}

fn spawnDelayedUnreleasedHandshakeForTest(
    alloc: Allocator,
) !background_process_provider.PreparedProcess {
    const argv = [_][]const u8{
        "sh",
        "-lc",
        "printf R >&2; sleep 0.2",
    };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    errdefer child.kill(io_mod.getIo());

    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try child.stderr.?.readStreaming(
            io_mod.getIo(),
            &.{&ready},
        ),
    );
    try std.testing.expectEqual(test_background_ready_byte, ready[0]);
    const spawned = try wrapTestPreparedProcess(alloc, child);
    child.stdin = null;
    child.stderr = null;
    return spawned;
}

fn spawnBlockedBackgroundHandshakeForTest(
    alloc: Allocator,
    cwd: []const u8,
    output: *const background_launch_output.Output,
) !background_process_provider.PreparedProcess {
    const argv = [_][]const u8{
        "sh",
        "-lc",
        test_blocked_background_wrapper_command,
        "fx-background",
    };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .{ .file = output.childStdioFile() },
        .stderr = .pipe,
    });
    errdefer {
        if (child.stdin) |stdin| stdin.close(io_mod.getIo());
        if (child.stderr) |stderr| stderr.close(io_mod.getIo());
        child.stdin = null;
        child.stderr = null;
        child.kill(io_mod.getIo());
    }

    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try child.stderr.?.readStreaming(io_mod.getIo(), &.{&ready}),
    );
    try std.testing.expectEqual(test_background_ready_byte, ready[0]);
    const spawned = try wrapTestPreparedProcess(alloc, child);
    child.stdin = null;
    child.stderr = null;
    return spawned;
}

fn waitForFileForTest(path: []const u8) !void {
    const started_ms = io_mod.milliTimestamp();
    while (true) {
        if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |file| {
            var opened = file;
            opened.close(io_mod.getIo());
            return;
        } else |_| {}
        if (io_mod.milliTimestamp() - started_ms > 1000) {
            return error.TestTimedOut;
        }
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

fn fileExistsForTest(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

fn disablePersistenceForPreparedLaunch(
    runtime: *BackgroundRuntime,
    alloc: Allocator,
) void {
    var store = runtime.persisted_store orelse return;
    runtime.persisted_store = null;
    store.deinit(alloc);
}

fn captureProcessTokenForTest(
    _: Allocator,
    _: []const u8,
) !process_supervisor.ProcessInstanceToken {
    return process_supervisor.ProcessInstanceToken.parse(
        "linux:00112233445566778899aabbccddeeff:12345",
    );
}








fn expectNoBackgroundLifecycleTracePathLeak(source: []const u8) !void {
    const marker = "debug_trace." ++ "logf(";
    var remaining = source;
    while (std.mem.find(u8, remaining, marker)) |start| {
        const call_start = start + marker.len;
        const call_end = std.mem.find(
            u8,
            remaining[call_start..],
            ");",
        ) orelse return error.TestExpectedEqual;
        const call = remaining[start .. call_start + call_end + 2];
        remaining = remaining[call_start + call_end + 2 ..];
        if (std.mem.find(u8, call, "background") == null) continue;

        const forbidden = [_][]const u8{
            "log_" ++ "path",
            "display_" ++ "path",
            "external_" ++ "path",
            "workspace_" ++ "root",
            "workspace=" ++ "{s}",
            " log=" ++ "{s}",
            " path=" ++ "{s}",
        };
        for (forbidden) |needle| {
            try std.testing.expect(std.mem.find(u8, call, needle) == null);
        }
    }
}





















fn waitForAtomicTrue(flag: *std.atomic.Value(bool), timeout_ms: i64) !void {
    const start = io_mod.milliTimestamp();
    while (!flag.load(.seq_cst)) {
        if (io_mod.milliTimestamp() - start > timeout_ms) return error.TestTimedOut;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}
