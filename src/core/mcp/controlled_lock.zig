const std = @import("std");
const io_mod = @import("../shared/io.zig");
const streamable_http = @import("streamable_http.zig");

const operation_poll_ns: u64 = std.time.ns_per_ms;

pub fn rwSharedUntil(
    lock: *std.Io.RwLock,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    return lockControlled(.rw_shared, lock, OperationControl.init(deadline, cancel_flag));
}

pub fn rwUntil(
    lock: *std.Io.RwLock,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    return lockControlled(.rw_exclusive, lock, OperationControl.init(deadline, cancel_flag));
}

pub fn mutexUntil(
    mutex: *std.Io.Mutex,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    return lockControlled(.mutex, mutex, OperationControl.init(deadline, cancel_flag));
}

pub fn rwSharedWithControl(lock: *std.Io.RwLock, control: streamable_http.Control) !void {
    return lockControlled(.rw_shared, lock, TransportControl{ .value = control });
}

pub fn mutexWithControl(mutex: *std.Io.Mutex, control: streamable_http.Control) !void {
    return lockControlled(.mutex, mutex, TransportControl{ .value = control });
}

pub fn checkOperation(
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    return (OperationControl{ .io = io, .deadline = deadline, .cancel_flag = cancel_flag }).check();
}

const LockKind = enum { rw_shared, rw_exclusive, mutex };

const OperationControl = struct {
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),

    fn init(
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) OperationControl {
        return .{ .io = io_mod.getIo(), .deadline = deadline, .cancel_flag = cancel_flag };
    }

    fn check(self: OperationControl) !void {
        if (self.cancel_flag) |flag| {
            if (flag.load(.acquire)) return error.Cancelled;
        }
        const now = std.Io.Clock.Timestamp.now(self.io, .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, self.deadline)) {
            return error.McpRequestTimedOut;
        }
    }
};

const TransportControl = struct {
    value: streamable_http.Control,

    fn check(self: TransportControl) !void {
        if (self.value.cancellation().cancelled()) return error.Cancelled;
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, self.value.deadline)) {
            return error.McpRequestTimedOut;
        }
    }
};

fn lockControlled(comptime kind: LockKind, lock: anytype, control: anytype) !void {
    const io = io_mod.getIo();
    while (!tryLock(kind, lock, io)) {
        try control.check();
        io_mod.sleep(operation_poll_ns);
    }
    control.check() catch |err| {
        unlock(kind, lock, io);
        return err;
    };
}

fn tryLock(comptime kind: LockKind, lock: anytype, io: std.Io) bool {
    if (kind == .rw_shared) return lock.tryLockShared(io);
    if (kind == .rw_exclusive) return lock.tryLock(io);
    return lock.tryLock();
}

fn unlock(comptime kind: LockKind, lock: anytype, io: std.Io) void {
    if (kind == .rw_shared) return lock.unlockShared(io);
    return lock.unlock(io);
}

test "controlled locks acquire available mutex and shared rw locks" {
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(100),
    });

    var mutex: std.Io.Mutex = .init;
    try mutexUntil(&mutex, deadline, null);
    mutex.unlock(std.testing.io);

    var rw_lock: std.Io.RwLock = .init;
    try rwSharedUntil(&rw_lock, deadline, null);
    rw_lock.unlockShared(std.testing.io);
}

test "controlled mutex stops on cancellation while contended" {
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);

    var cancelled = std.atomic.Value(bool).init(true);
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(100),
    });
    try std.testing.expectError(
        error.Cancelled,
        mutexUntil(&mutex, deadline, &cancelled),
    );
}

test "controlled mutex stops at its deadline while contended" {
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);

    const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(
        error.McpRequestTimedOut,
        mutexUntil(&mutex, deadline, null),
    );
}
