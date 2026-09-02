const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_usage_runtime = @import("../session/profile_usage_runtime.zig");
const usage_recovery = @import("../session/usage_recovery.zig");
const usage_report = @import("../session/usage_report.zig");

const Allocator = std.mem.Allocator;

const rolling_scopes = [_]usage_report.Scope{
    .days_30,
    .days_7,
    .hours_24,
};

pub const SnapshotSet = struct {
    snapshots: [rolling_scopes.len]usage_report.Snapshot,

    pub fn deinit(self: *SnapshotSet, alloc: Allocator) void {
        for (&self.snapshots) |*snapshot| snapshot.deinit(alloc);
        self.* = undefined;
    }

    fn get(self: *const SnapshotSet, scope: usage_report.Scope) ?*const usage_report.Snapshot {
        for (rolling_scopes, 0..) |candidate, index| {
            if (candidate == scope) return &self.snapshots[index];
        }
        return null;
    }
};

pub const Provider = struct {
    context: *anyopaque,
    load: *const fn (
        context: *anyopaque,
        alloc: Allocator,
        home_path: []const u8,
        snapshot_time_ms: i64,
        cancel_requested: *const std.atomic.Value(bool),
    ) anyerror!SnapshotSet,
};

pub fn profileProvider(runtime: *profile_usage_runtime.Runtime) Provider {
    return .{
        .context = runtime,
        .load = loadProfileSnapshots,
    };
}

const LoadState = enum {
    idle,
    loading,
    ready,
    failed,
};

pub const Transition = enum {
    none,
    ready,
    failed,
};

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: LoadState = .idle,
    completion_pending: bool = false,
    cache: ?SnapshotSet = null,
    last_error: ?anyerror = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    /// Fieldwise initialization avoids retaining undefined cache payloads in
    /// a static release-binary template.
    pub fn initInto(storage: *Self, alloc: Allocator) void {
        comptime {
            if (std.meta.fields(Self).len != 8) {
                @compileError("update Runtime.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.alloc = alloc;
        storage.mutex = .init;
        storage.thread = null;
        storage.state = .idle;
        storage.completion_pending = false;
        storage.cache = null;
        storage.last_error = null;
        storage.cancel_requested = .init(false);
    }

    pub fn deinit(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
        if (self.cache) |*cache| cache.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn requestRefresh(
        self: *Self,
        provider: Provider,
        home_path: []const u8,
        snapshot_time_ms: i64,
    ) !bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.state == .loading) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        self.state = .loading;
        self.completion_pending = false;
        self.last_error = null;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);

        const owned_home = self.alloc.dupe(u8, home_path) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = if (self.cache != null) .ready else .failed;
            self.last_error = err;
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        errdefer self.alloc.free(owned_home);
        self.thread = std.Thread.spawn(
            .{},
            loadThreadMain,
            .{ self, provider, owned_home, snapshot_time_ms },
        ) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = if (self.cache != null) .ready else .failed;
            self.last_error = err;
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        return true;
    }

    pub fn snapshot(
        self: *Self,
        alloc: Allocator,
        scope: usage_report.Scope,
    ) Allocator.Error!?usage_report.Snapshot {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const cached = if (self.cache) |*cache| cache.get(scope) else null;
        return if (cached) |value| try value.dupe(alloc) else null;
    }

    pub fn pollTransition(self: *Self) Transition {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.completion_pending) return .none;
        self.completion_pending = false;
        return if (self.last_error == null) .ready else .failed;
    }

    fn isLoading(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state == .loading;
    }

    pub fn lastError(self: *Self) ?anyerror {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.last_error;
    }

    fn finishThreadIfDone(self: *Self) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_join = self.state != .loading and self.thread != null;
        const thread = if (should_join) self.thread.? else null;
        if (should_join) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| {
            handle.join();
            self.mutex.lockUncancelable(io_mod.getIo());
            self.completion_pending = true;
            self.mutex.unlock(io_mod.getIo());
        }
    }

    fn loadThreadMain(
        self: *Self,
        provider: Provider,
        owned_home: []u8,
        snapshot_time_ms: i64,
    ) void {
        defer self.alloc.free(owned_home);
        const loaded = provider.load(
            provider.context,
            self.alloc,
            owned_home,
            snapshot_time_ms,
            &self.cancel_requested,
        ) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = if (self.cache != null) .ready else .failed;
            self.last_error = err;
            self.mutex.unlock(io_mod.getIo());
            return;
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.cache) |*cache| cache.deinit(self.alloc);
        self.cache = loaded;
        self.state = .ready;
        self.last_error = null;
        self.mutex.unlock(io_mod.getIo());
    }
};

fn loadProfileSnapshots(
    context: *anyopaque,
    alloc: Allocator,
    home_path: []const u8,
    snapshot_time_ms: i64,
    cancel_requested: *const std.atomic.Value(bool),
) !SnapshotSet {
    const runtime: *profile_usage_runtime.Runtime = @ptrCast(@alignCast(context));
    var recovery = try usage_recovery.collectFromHomeConservativeCancelable(
        alloc,
        home_path,
        cancel_requested,
    );
    defer recovery.deinit(alloc);

    if (cancel_requested.load(.seq_cst)) return error.Cancelled;
    return .{ .snapshots = try runtime.rollingSnapshots(
        alloc,
        snapshot_time_ms,
        .{
            .facts = recovery.facts,
            .incidents = recovery.incidents,
            .pending = recovery.pending,
            .unknown_pending = recovery.unknown_pending,
        },
    ) };
}
