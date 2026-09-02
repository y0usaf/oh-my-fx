const std = @import("std");
const worker_runtime = @import("../agent/worker_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const permission_request = @import("../permissions/permission_request.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const communication = @import("communication.zig");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    RegistryClosed,
    RequestConflict,
    RequestNotFound,
    WrongChild,
    StaleRequest,
    CommitFailed,
    CapacityExceeded,
};

pub const ResolveResult = enum {
    accepted,
    rejected,
    relationship_ready,
};

pub const RelationshipCompletion = enum {
    succeeded,
    retryable_failure,
    terminal_failure,
};

pub const PersistenceError = error{
    OutOfMemory,
    CommitFailed,
    CapacityExceeded,
};

/// Durable shell supplied by the manager. `commit_response_fn` must revalidate
/// attachment/lifecycle state and, for Always, commit root grants and authority
/// generation before returning.
pub const Persistence = struct {
    context: ?*anyopaque = null,
    register_fn: *const fn (
        ?*anyopaque,
        communication.ApprovalInput,
    ) PersistenceError!void,
    commit_response_fn: *const fn (
        ?*anyopaque,
        communication.ApprovalResponse,
        [32]u8,
    ) PersistenceError!void,
    invalidate_fn: *const fn (
        ?*anyopaque,
        []const u8,
        []const u8,
        communication.ApprovalStatus,
        i64,
    ) PersistenceError!void,

    fn register(self: Persistence, input: communication.ApprovalInput) PersistenceError!void {
        return self.register_fn(self.context, input);
    }

    fn commitResponse(
        self: Persistence,
        response: communication.ApprovalResponse,
        identity_fingerprint: [32]u8,
    ) PersistenceError!void {
        return self.commit_response_fn(
            self.context,
            response,
            identity_fingerprint,
        );
    }

    fn invalidate(
        self: Persistence,
        request_id: []const u8,
        child_id: []const u8,
        status: communication.ApprovalStatus,
        timestamp_ms: i64,
    ) PersistenceError!void {
        return self.invalidate_fn(
            self.context,
            request_id,
            child_id,
            status,
            timestamp_ms,
        );
    }
};

const Binding = struct {
    request_id: []u8,
    child_id: []u8,
    tool_arguments_preview: ?[]u8 = null,
    prepared_fingerprint: [32]u8,
    identity_fingerprint: [32]u8 = [_]u8{0} ** 32,
    worker: ?*worker_runtime.WorkerRuntime,
    worker_request_id: ?u64,
    worker_route_detached: bool = false,
    relationship_resolution_in_flight: bool = false,

    fn deinit(self: *Binding, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        if (self.tool_arguments_preview) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const PendingRoute = struct {
    request_id: []u8,
    child_id: []u8,
    tool_arguments_preview: ?[]u8 = null,

    pub fn deinit(self: *PendingRoute, alloc: Allocator) void {
        alloc.free(self.request_id);
        alloc.free(self.child_id);
        if (self.tool_arguments_preview) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const PendingRouteSnapshot = struct {
    revision: u64,
    total: usize,
    offset: usize,
    previous_offset: ?usize,
    next_offset: ?usize,
    routes: []PendingRoute,

    pub fn deinit(self: *PendingRouteSnapshot, alloc: Allocator) void {
        for (self.routes) |*route| route.deinit(alloc);
        alloc.free(self.routes);
        self.* = undefined;
    }
};

pub const Registry = struct {
    alloc: Allocator,
    persistence: Persistence,
    mutex: std.Io.Mutex = .init,
    bindings: std.ArrayList(Binding) = .empty,
    closed: bool = false,
    worker_routes_closed: bool = false,
    pending_revision: u64 = 0,

    pub fn pendingRevision(self: *Registry) u64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.pending_revision;
    }

    /// Returns a bounded, allocator-owned routing projection. Durable approval
    /// content remains owned by the communication ledger.
    pub fn snapshotPendingRoutes(
        self: *Registry,
        alloc: Allocator,
        offset: usize,
        limit: usize,
    ) Error!PendingRouteSnapshot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;

        const total = self.bindings.items.len;
        const page_offset = pendingRoutePageOffset(total, offset, limit);
        const count = @min(limit, total - page_offset);
        const routes = try alloc.alloc(PendingRoute, count);
        var built: usize = 0;
        errdefer {
            for (routes[0..built]) |*route| route.deinit(alloc);
            alloc.free(routes);
        }
        for (self.bindings.items[page_offset..][0..count]) |binding| {
            const request_id = try alloc.dupe(u8, binding.request_id);
            errdefer alloc.free(request_id);
            const child_id = try alloc.dupe(u8, binding.child_id);
            errdefer alloc.free(child_id);
            const tool_arguments_preview = if (binding.tool_arguments_preview) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (tool_arguments_preview) |value| alloc.free(value);
            routes[built] = .{
                .request_id = request_id,
                .child_id = child_id,
                .tool_arguments_preview = tool_arguments_preview,
            };
            built += 1;
        }
        return .{
            .revision = self.pending_revision,
            .total = total,
            .offset = page_offset,
            .previous_offset = if (page_offset == 0 or limit == 0)
                null
            else
                page_offset - @min(page_offset, limit),
            .next_offset = if (limit > 0 and page_offset + count < total)
                page_offset + count
            else
                null,
            .routes = routes,
        };
    }

    /// Registers the exact canonical prepared request currently owned by the
    /// worker waiter. The registry stores only routing identity; persistence
    /// owns the bounded projection and prepared fingerprint.
    pub fn registerTool(
        self: *Registry,
        stable_request_id: []const u8,
        child_id: []const u8,
        root_id: []const u8,
        work_id: []const u8,
        request: permission_request.PermissionRequest,
        grants: []const types.PermissionGrant,
        worker: *worker_runtime.WorkerRuntime,
        timestamp_ms: i64,
    ) Error!void {
        const fingerprint = communication.preparedRequestFingerprint(request);
        try self.persistAndAdd(.{
            .id = stable_request_id,
            .kind = .tool,
            .child_id = child_id,
            .root_id = root_id,
            .work_id = work_id,
            .prepared_fingerprint = fingerprint,
            .label = request.label,
            .explanation = request.explanation,
            .command = request.command,
            .file = request.file,
            .grants = grants,
            .created_at_ms = timestamp_ms,
        }, .{
            .request_id = @constCast(stable_request_id),
            .child_id = @constCast(child_id),
            .tool_arguments_preview = if (request.tool_arguments_preview) |value|
                @constCast(value)
            else
                null,
            .prepared_fingerprint = fingerprint,
            .worker = worker,
            .worker_request_id = request.id,
        });
    }

    pub fn registerRelationship(
        self: *Registry,
        stable_request_id: []const u8,
        child_id: []const u8,
        root_id: []const u8,
        action: domain.RelationshipAction,
        prospective_parent_id: []const u8,
        operation_id: []const u8,
        label: []const u8,
        operation_identity_admitted: bool,
        timestamp_ms: i64,
    ) Error!void {
        const prepared_fingerprint = communication.relationshipPreparedFingerprint(
            action,
            child_id,
            prospective_parent_id,
            operation_id,
        );
        try self.persistAndAdd(.{
            .id = stable_request_id,
            .kind = .relationship,
            .child_id = child_id,
            .root_id = root_id,
            .work_id = null,
            .relationship = .{
                .action = action,
                .prospective_parent_id = prospective_parent_id,
                .operation_id = operation_id,
            },
            .prepared_fingerprint = prepared_fingerprint,
            .label = label,
            .explanation = null,
            .grants = &.{},
            .created_at_ms = timestamp_ms,
            .operation_identity_admitted = operation_identity_admitted,
        }, .{
            .request_id = @constCast(stable_request_id),
            .child_id = @constCast(child_id),
            .prepared_fingerprint = prepared_fingerprint,
            .worker = null,
            .worker_request_id = null,
        });
    }

    pub fn resolve(
        self: *Registry,
        request_id: []const u8,
        child_id: []const u8,
        decision: types.ToolPermissionDecision,
        feedback: ?[]const u8,
        timestamp_ms: i64,
    ) Error!ResolveResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=registry_closed", .{ traceId(request_id), traceId(child_id) });
            return error.RegistryClosed;
        }
        const index = self.findBinding(request_id) orelse {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=request_not_found", .{ traceId(request_id), traceId(child_id) });
            return error.RequestNotFound;
        };
        const binding = &self.bindings.items[index];
        if (!std.mem.eql(u8, binding.child_id, child_id)) {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=wrong_child", .{ traceId(request_id), traceId(child_id) });
            return error.WrongChild;
        }
        const response: communication.ApprovalResponse = .{
            .request_id = request_id,
            .child_id = child_id,
            .decision = decision,
            .timestamp_ms = timestamp_ms,
        };
        if (binding.worker_route_detached) {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=stale_waiter", .{ traceId(request_id), traceId(child_id) });
            return error.StaleRequest;
        }
        if (binding.worker == null and binding.relationship_resolution_in_flight) {
            debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=relationship_resolution_in_flight", .{ traceId(request_id), traceId(child_id) });
            return .rejected;
        }
        if (binding.worker) |worker| {
            const worker_request_id = binding.worker_request_id orelse {
                debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=stale_waiter", .{ traceId(request_id), traceId(child_id) });
                return error.StaleRequest;
            };
            const owned_feedback = if (feedback) |value|
                try self.alloc.dupe(u8, value)
            else
                null;
            var commit_context = CommitContext{
                .persistence = self.persistence,
                .response = response,
                .identity_fingerprint = binding.identity_fingerprint,
            };
            const submission = worker.submitPermissionResponseAfterCommit(
                worker_request_id,
                permission_request.OwnedPermissionResponse.init(
                    self.alloc,
                    decision,
                    owned_feedback,
                ),
                .{
                    .context = &commit_context,
                    .commit_fn = CommitContext.run,
                },
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PermissionCapacityExceeded => error.CapacityExceeded,
                error.PermissionCommitFailed => error.CommitFailed,
            };
            if (submission != .accepted) {
                debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=stale_waiter", .{ traceId(request_id), traceId(child_id) });
                return .rejected;
            }
        } else {
            self.persistence.commitResponse(
                response,
                binding.identity_fingerprint,
            ) catch |err| {
                debug_trace.logf("subagent", "approval response commit failed request_id={s} child_id={s} outcome={s}", .{ traceId(request_id), traceId(child_id), @errorName(err) });
                return err;
            };
            if (decision == .once) {
                binding.relationship_resolution_in_flight = true;
                debug_trace.logf("subagent", "relationship approval authorized request_id={s} child_id={s} outcome=ready", .{ traceId(request_id), traceId(child_id) });
                return .relationship_ready;
            }
        }
        self.removeBinding(index);
        self.advancePendingRevision();
        debug_trace.logf("subagent", "approval resolved request_id={s} child_id={s} outcome={s}", .{ traceId(request_id), traceId(child_id), @tagName(decision) });
        return .accepted;
    }

    pub fn completeRelationship(
        self: *Registry,
        request_id: []const u8,
        child_id: []const u8,
        completion: RelationshipCompletion,
        timestamp_ms: i64,
    ) Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.RegistryClosed;
        const index = self.findBinding(request_id) orelse
            return error.RequestNotFound;
        const binding = &self.bindings.items[index];
        if (!std.mem.eql(u8, binding.child_id, child_id)) return error.WrongChild;
        if (binding.worker != null or !binding.relationship_resolution_in_flight) {
            return error.StaleRequest;
        }
        switch (completion) {
            .retryable_failure => {
                binding.relationship_resolution_in_flight = false;
                debug_trace.logf("subagent", "relationship approval continuation released request_id={s} child_id={s} outcome=retryable", .{ traceId(request_id), traceId(child_id) });
                return;
            },
            .terminal_failure => self.persistence.invalidate(
                request_id,
                child_id,
                .stale,
                timestamp_ms,
            ) catch |err| {
                binding.relationship_resolution_in_flight = false;
                debug_trace.logf("subagent", "relationship approval terminalization failed request_id={s} child_id={s} outcome={s}", .{ traceId(request_id), traceId(child_id), @errorName(err) });
                return err;
            },
            .succeeded => {},
        }
        self.removeBinding(index);
        self.advancePendingRevision();
        debug_trace.logf("subagent", "relationship approval continuation completed request_id={s} child_id={s} outcome={s}", .{ traceId(request_id), traceId(child_id), @tagName(completion) });
    }

    /// Retires persisted routes while the registry lock still pins every
    /// stack-owned worker. Failed persistence leaves only a detached, stale
    /// route for a later invalidation retry; every waiter is still denied.
    pub fn invalidateChild(
        self: *Registry,
        child_id: []const u8,
        status: communication.ApprovalStatus,
        timestamp_ms: i64,
    ) Error!usize {
        if (status != .cancelled and status != .stale) return error.CommitFailed;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var first_error: ?PersistenceError = null;
        var changed: usize = 0;
        var index: usize = self.bindings.items.len;
        while (index > 0) {
            index -= 1;
            const binding = &self.bindings.items[index];
            if (!std.mem.eql(u8, binding.child_id, child_id)) continue;
            var persisted = true;
            self.persistence.invalidate(
                binding.request_id,
                child_id,
                status,
                timestamp_ms,
            ) catch |err| {
                persisted = false;
                debug_trace.logf("subagent", "approval invalidation failed request_id={s} child_id={s} outcome={s}", .{ traceId(binding.request_id), traceId(child_id), @errorName(err) });
                if (first_error == null) first_error = err;
            };
            const worker = binding.worker;
            if (persisted) {
                debug_trace.logf("subagent", "approval invalidated request_id={s} child_id={s} outcome={s}", .{ traceId(binding.request_id), traceId(child_id), @tagName(status) });
            } else {
                debug_trace.logf("subagent", "approval worker detached request_id={s} child_id={s} reason=persistence_failed", .{ traceId(binding.request_id), traceId(child_id) });
                binding.worker = null;
                binding.worker_request_id = null;
                binding.worker_route_detached = true;
                if (worker) |value| value.cancelApprovalTurn();
                continue;
            }
            self.removeBinding(index);
            self.advancePendingRevision();
            if (worker) |value| value.cancelApprovalTurn();
            changed += 1;
        }
        if (first_error) |err| return err;
        return changed;
    }

    /// Retires every in-memory worker route before its stack-owned worker can
    /// exit. Durable pending approvals are reconciled by host-exit recovery.
    pub fn detachWorkerRoutes(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.worker_routes_closed = true;

        var index: usize = self.bindings.items.len;
        while (index > 0) {
            index -= 1;
            if (self.bindings.items[index].worker == null) continue;
            debug_trace.logf("subagent", "approval route retired request_id={s} child_id={s} reason=owner_shutdown", .{
                traceId(self.bindings.items[index].request_id),
                traceId(self.bindings.items[index].child_id),
            });
            self.removeBinding(index);
            self.advancePendingRevision();
        }
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.closed = true;
        for (self.bindings.items) |*binding| binding.deinit(self.alloc);
        self.bindings.deinit(self.alloc);
    }

    fn persistAndAdd(
        self: *Registry,
        approval: communication.ApprovalInput,
        input: Binding,
    ) Error!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) {
            debug_trace.logf("subagent", "approval registration failed request_id={s} child_id={s} outcome=registry_closed", .{ traceId(input.request_id), traceId(input.child_id) });
            return error.RegistryClosed;
        }
        if (input.worker != null and self.worker_routes_closed) {
            debug_trace.logf("subagent", "approval registration failed request_id={s} child_id={s} outcome=worker_routes_closed", .{ traceId(input.request_id), traceId(input.child_id) });
            return error.RegistryClosed;
        }
        const identity_fingerprint = communication.approvalIdentityFingerprint(approval);
        if (self.findBinding(input.request_id)) |index| {
            const existing = self.bindings.items[index];
            if (!std.mem.eql(u8, existing.child_id, input.child_id) or
                !std.mem.eql(
                    u8,
                    &existing.identity_fingerprint,
                    &identity_fingerprint,
                ) or existing.worker != input.worker or
                existing.worker_request_id != input.worker_request_id)
            {
                debug_trace.logf("subagent", "approval rejected request_id={s} child_id={s} outcome=request_conflict", .{ traceId(input.request_id), traceId(input.child_id) });
                return error.RequestConflict;
            }
            return;
        }
        var request_id: ?[]u8 = try self.alloc.dupe(u8, input.request_id);
        errdefer if (request_id) |value| self.alloc.free(value);
        var child_id: ?[]u8 = try self.alloc.dupe(u8, input.child_id);
        errdefer if (child_id) |value| self.alloc.free(value);
        var tool_arguments_preview: ?[]u8 = if (input.tool_arguments_preview) |value|
            try self.alloc.dupe(u8, value)
        else
            null;
        errdefer if (tool_arguments_preview) |value| self.alloc.free(value);
        try self.bindings.append(self.alloc, .{
            .request_id = request_id.?,
            .child_id = child_id.?,
            .tool_arguments_preview = tool_arguments_preview,
            .prepared_fingerprint = input.prepared_fingerprint,
            .identity_fingerprint = identity_fingerprint,
            .worker = input.worker,
            .worker_request_id = input.worker_request_id,
        });
        request_id = null;
        child_id = null;
        tool_arguments_preview = null;
        errdefer {
            var removed = self.bindings.pop().?;
            removed.deinit(self.alloc);
        }
        self.persistence.register(approval) catch |err| {
            debug_trace.logf("subagent", "approval registration failed request_id={s} child_id={s} outcome={s}", .{ traceId(input.request_id), traceId(input.child_id), @errorName(err) });
            return err;
        };
        self.advancePendingRevision();
        debug_trace.logf("subagent", "approval registered request_id={s} child_id={s} outcome=pending", .{ traceId(input.request_id), traceId(input.child_id) });
    }

    fn findBinding(self: *Registry, request_id: []const u8) ?usize {
        for (self.bindings.items, 0..) |binding, index| {
            if (std.mem.eql(u8, binding.request_id, request_id)) return index;
        }
        return null;
    }

    fn removeBinding(self: *Registry, index: usize) void {
        var removed = self.bindings.orderedRemove(index);
        removed.deinit(self.alloc);
    }

    fn advancePendingRevision(self: *Registry) void {
        self.pending_revision = self.pending_revision +| 1;
    }
};

fn traceId(value: []const u8) []const u8 {
    return value[0..@min(value.len, 64)];
}

fn pendingRoutePageOffset(total: usize, requested: usize, limit: usize) usize {
    if (total == 0 or limit == 0) return 0;
    const last_page = ((total - 1) / limit) * limit;
    return @min(requested - (requested % limit), last_page);
}

fn checkPendingRouteSnapshotAllocation(
    alloc: Allocator,
    registry: *Registry,
) !void {
    var snapshot = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 1), snapshot.revision);
    try std.testing.expectEqual(@as(usize, 1), snapshot.routes.len);
    try std.testing.expectEqualStrings("approval-race", snapshot.routes[0].request_id);
    try std.testing.expectEqualStrings("child", snapshot.routes[0].child_id);
}

fn checkLivePreviewRegistryAllocation(alloc: Allocator) !void {
    const FakePersistence = struct {
        fn register(
            _: ?*anyopaque,
            _: communication.ApprovalInput,
        ) PersistenceError!void {}

        fn commit(
            _: ?*anyopaque,
            _: communication.ApprovalResponse,
            _: [32]u8,
        ) PersistenceError!void {}

        fn invalidate(
            _: ?*anyopaque,
            _: []const u8,
            _: []const u8,
            _: communication.ApprovalStatus,
            _: i64,
        ) PersistenceError!void {}
    };

    var worker: worker_runtime.WorkerRuntime = .{};
    defer worker.deinit(std.testing.allocator);
    var registry = Registry{
        .alloc = alloc,
        .persistence = .{
            .register_fn = FakePersistence.register,
            .commit_response_fn = FakePersistence.commit,
            .invalidate_fn = FakePersistence.invalidate,
        },
    };
    defer registry.deinit();
    try registry.registerTool(
        "preview-approval",
        "child",
        "root",
        "work",
        .{
            .id = 17,
            .label = "mcp_fixture_echo",
            .tool_arguments_preview = "{\"text\":\"sentinel\"}",
        },
        &.{},
        &worker,
        1,
    );
    var snapshot = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"text\":\"sentinel\"}",
        snapshot.routes[0].tool_arguments_preview.?,
    );
}


const CommitContext = struct {
    persistence: Persistence,
    response: communication.ApprovalResponse,
    identity_fingerprint: [32]u8,

    fn run(raw: *anyopaque) worker_runtime.WorkerRuntime.PermissionCommitError!void {
        const self: *CommitContext = @ptrCast(@alignCast(raw));
        self.persistence.commitResponse(
            self.response,
            self.identity_fingerprint,
        ) catch |err| {
            debug_trace.logf("subagent", "approval response commit failed request_id={s} child_id={s} outcome={s}", .{ traceId(self.response.request_id), traceId(self.response.child_id), @errorName(err) });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CommitFailed => error.PermissionCommitFailed,
                error.CapacityExceeded => error.PermissionCapacityExceeded,
            };
        };
    }
};






fn checkPendingRoutePageAllocation(alloc: Allocator, registry: *Registry) !void {
    var first = try registry.snapshotPendingRoutes(alloc, 0, 8);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 10), first.total);
    try std.testing.expectEqual(@as(?usize, 8), first.next_offset);

    var second = try registry.snapshotPendingRoutes(alloc, first.next_offset.?, 8);
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), second.routes.len);
}
