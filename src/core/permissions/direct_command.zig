const std = @import("std");
const builtin = @import("builtin");
const command_effect = @import("../shell_command/command_effect.zig");
const command_contract = @import("../execution/command_contract.zig");
const command_runner = @import("../execution/command_runner.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub const direct_output_limit_bytes: usize = 65_536;
const direct_output_read_chunk_bytes: usize = 4096;

const DirectOutputProjector = struct {
    utf8_pending: [3]u8 = undefined,
    utf8_pending_len: u2 = 0,
    escaped_controls: usize = 0,
    escaped_invalid: usize = 0,

    fn push(
        self: *DirectOutputProjector,
        alloc: std.mem.Allocator,
        raw: []const u8,
        projected: *std.ArrayList(u8),
    ) !void {
        var combined: [direct_output_read_chunk_bytes + 3]u8 = undefined;
        const pending_len: usize = self.utf8_pending_len;
        @memcpy(combined[0..pending_len], self.utf8_pending[0..pending_len]);
        @memcpy(combined[pending_len .. pending_len + raw.len], raw);
        const bytes = combined[0 .. pending_len + raw.len];
        self.utf8_pending_len = 0;

        var index: usize = 0;
        while (index < bytes.len) {
            const byte = bytes[index];
            if (byte < 0x80) {
                if (byte == '\n') {
                    try projected.append(alloc, byte);
                } else if (byte < 0x20 or byte == 0x7f) {
                    self.escaped_controls += 1;
                    try appendByteEscape(alloc, projected, byte);
                } else {
                    try projected.append(alloc, byte);
                }
                index += 1;
                continue;
            }

            const sequence_len: usize = std.unicode.utf8ByteSequenceLength(byte) catch {
                self.escaped_invalid += 1;
                try appendByteEscape(alloc, projected, byte);
                index += 1;
                continue;
            };
            if (bytes.len - index < sequence_len) {
                const remainder = bytes[index..];
                @memcpy(self.utf8_pending[0..remainder.len], remainder);
                self.utf8_pending_len = @intCast(remainder.len);
                break;
            }

            const sequence = bytes[index .. index + sequence_len];
            const scalar = std.unicode.utf8Decode(sequence) catch {
                self.escaped_invalid += 1;
                try appendByteEscape(alloc, projected, byte);
                index += 1;
                continue;
            };
            if (scalar >= 0x80 and scalar <= 0x9f) {
                self.escaped_controls += 1;
                try appendC1Escape(alloc, projected, @intCast(scalar));
            } else {
                try projected.appendSlice(alloc, sequence);
            }
            index += sequence_len;
        }
    }

    fn finish(
        self: *DirectOutputProjector,
        alloc: std.mem.Allocator,
        projected: *std.ArrayList(u8),
    ) !void {
        for (self.utf8_pending[0..self.utf8_pending_len]) |byte| {
            self.escaped_invalid += 1;
            try appendByteEscape(alloc, projected, byte);
        }
        self.utf8_pending_len = 0;
    }
};

fn appendByteEscape(
    alloc: std.mem.Allocator,
    projected: *std.ArrayList(u8),
    byte: u8,
) !void {
    const digits = "0123456789abcdef";
    try projected.appendSlice(alloc, &.{
        '\\',
        'x',
        digits[byte >> 4],
        digits[byte & 0x0f],
    });
}

fn appendC1Escape(
    alloc: std.mem.Allocator,
    projected: *std.ArrayList(u8),
    byte: u8,
) !void {
    const digits = "0123456789abcdef";
    try projected.appendSlice(alloc, &.{
        '\\',
        'u',
        '{',
        '0',
        '0',
        digits[byte >> 4],
        digits[byte & 0x0f],
        '}',
    });
}

const DirectOutputBudget = struct {
    limit: usize,
    admitted: usize = 0,
    tripped: bool = false,
    lock: std.Io.Mutex = .init,

    const Charge = struct {
        admit_chunk: bool,
        trip_owner: bool,
    };

    fn charge(self: *DirectOutputBudget, observed_len: usize) Charge {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        if (self.tripped) {
            return .{ .admit_chunk = false, .trip_owner = false };
        }
        if (observed_len <= self.limit - self.admitted) {
            self.admitted += observed_len;
            return .{ .admit_chunk = true, .trip_owner = false };
        }
        self.tripped = true;
        return .{ .admit_chunk = false, .trip_owner = true };
    }

    fn remaining(self: *DirectOutputBudget) usize {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        return self.limit - self.admitted;
    }
};

pub fn executeDirectReadOnly(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    plan: command_effect.DirectReadOnlyPlan,
) !command_contract.RunCommandResult {
    return executeDirectReadOnlyWithLimit(cfg, alloc, plan, direct_output_limit_bytes);
}

fn executeDirectReadOnlyWithLimit(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    plan: command_effect.DirectReadOnlyPlan,
    output_limit: usize,
) !command_contract.RunCommandResult {
    return executeDirectReadOnlyWithLimitAndTestControls(cfg, alloc, plan, output_limit, .{});
}

const DirectExecutionTestControls = struct {
    context: ?*anyopaque = null,
    after_spawn: ?*const fn (*anyopaque, usize, *const std.process.Child) void = null,
};

fn executeDirectReadOnlyWithLimitAndTestControls(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    plan: command_effect.DirectReadOnlyPlan,
    output_limit: usize,
    test_controls: DirectExecutionTestControls,
) !command_contract.RunCommandResult {
    if (plan.stages.len == 0) return error.InvalidDirectPlan;
    if (plan.stages.len > command_effect.max_direct_pipeline_stages) {
        return error.InvalidDirectPlan;
    }
    var execution_cfg = cfg;
    if (execution_cfg.timeout_ms != null and execution_cfg.timeout_started_ms == null) {
        execution_cfg.timeout_started_ms = io_mod.milliTimestamp();
    }
    try checkControl(execution_cfg);

    if (builtin.os.tag != .macos and builtin.os.tag != .linux) {
        return error.UnsupportedDirectPlatform;
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var children = try scratch.alloc(std.process.Child, plan.stages.len);
    var child_count: usize = 0;
    var group_id: ?std.posix.pid_t = null;
    var pre_worker_cleanup_pending = true;
    errdefer if (pre_worker_cleanup_pending) {
        cleanupChildren(children[0..child_count], group_id);
    };
    const started_ms = io_mod.milliTimestamp();

    while (child_count < plan.stages.len) : (child_count += 1) {
        try checkControl(execution_cfg);
        const stage = plan.stages[child_count];
        var environment = try environmentForProfile(scratch, stage.environment_profile);
        defer environment.deinit();

        const child = std.process.spawn(io_mod.getIo(), .{
            .argv = stage.argv,
            .cwd = .{ .path = plan.cwd },
            .environ_map = &environment,
            .stdin = if (child_count == 0) .ignore else .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi)
                (if (child_count == 0) 0 else group_id)
            else
                null,
        }) catch |err| {
            return switch (err) {
                error.FileNotFound => error.DirectExecutableUnavailable,
                else => err,
            };
        };
        children[child_count] = child;
        if (child_count == 0 and builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            group_id = child.id;
        }
        if (test_controls.after_spawn) |after_spawn| {
            after_spawn(test_controls.context.?, child_count, &children[child_count]);
        }
    }

    var output = DirectOutput.init(alloc, execution_cfg);
    defer output.deinit();
    var shared: SharedExecution = .{
        .cfg = execution_cfg,
        .budget = .{ .limit = output_limit },
        .output = &output,
    };

    const worker_count = plan.stages.len * 2;
    const workers = try scratch.alloc(OutputWorker, worker_count);
    var initialized_workers: usize = 0;

    for (0..plan.stages.len - 1) |index| {
        workers[initialized_workers] = .{
            .shared = &shared,
            .source = children[index].stdout.?,
            .destination = children[index + 1].stdin.?,
            .kind = .relay,
        };
        children[index].stdout = null;
        children[index + 1].stdin = null;
        initialized_workers += 1;
    }

    workers[initialized_workers] = .{
        .shared = &shared,
        .source = children[plan.stages.len - 1].stdout.?,
        .kind = .{ .projected = .stdout },
    };
    children[plan.stages.len - 1].stdout = null;
    initialized_workers += 1;

    for (children[0..child_count]) |*child| {
        workers[initialized_workers] = .{
            .shared = &shared,
            .source = child.stderr.?,
            .kind = .{ .projected = .stderr },
        };
        child.stderr = null;
        initialized_workers += 1;
    }
    std.debug.assert(initialized_workers == worker_count);
    pre_worker_cleanup_pending = false;

    var started_workers: usize = 0;
    while (started_workers < workers.len) : (started_workers += 1) {
        workers[started_workers].thread = std.Thread.spawn(
            .{},
            OutputWorker.run,
            .{&workers[started_workers]},
        ) catch |err| {
            shared.commit(.output_failure, err);
            signalGroup(group_id, true);
            for (workers[started_workers..]) |*worker| worker.closeUnstarted();
            for (workers[0..started_workers]) |*worker| worker.thread.?.join();
            waitChildren(children[0..child_count]);
            const failure = shared.failure() orelse err;
            debug_trace.logf(
                "core",
                "direct command worker start failed route=direct_read_only cause={s} limit={d} admitted_raw_bytes={d} remaining_raw_bytes={d} children_reaped={d} workers_joined={d} artifact=false",
                .{
                    @tagName(shared.cause.?),
                    shared.budget.limit,
                    shared.budget.admitted,
                    shared.budget.remaining(),
                    child_count,
                    started_workers,
                },
            );
            return failure;
        };
    }

    var termination_started_ms: ?i64 = null;
    var force_kill_sent = false;
    while (!allWorkersDone(workers)) {
        if (!shared.isStopping()) {
            if (execution_cfg.cancel_flag) |flag| {
                if (flag.load(.seq_cst)) shared.commit(.cancelled, error.Cancelled);
            }
            if (!shared.isStopping() and deadlineExpired(execution_cfg)) {
                shared.commit(.timed_out, error.TimeoutExpired);
            }
        }
        if (shared.isStopping()) {
            const now = io_mod.milliTimestamp();
            if (termination_started_ms == null) {
                signalGroup(group_id, false);
                termination_started_ms = now;
            } else if (!force_kill_sent and now - termination_started_ms.? >= 800) {
                signalGroup(group_id, true);
                force_kill_sent = true;
            }
        }
        io_mod.sleep(5 * std.time.ns_per_ms);
    }

    for (workers) |*worker| worker.thread.?.join();

    var final_term: std.process.Child.Term = .{ .unknown = 0 };
    for (children[0..child_count], 0..) |*child, index| {
        const term = child.wait(io_mod.getIo()) catch |err| {
            shared.commit(.output_failure, err);
            continue;
        };
        if (index + 1 == child_count) final_term = term;
    }

    if (shared.failure()) |failure| {
        if (shared.cause == .timed_out) {
            output.flushCallbacks() catch |err| debug_trace.logf(
                "core",
                "direct command timeout callback flush failed err={s}",
                .{@errorName(err)},
            );
        }
        debug_trace.logf(
            "core",
            "direct command terminated route=direct_read_only cause={s} limit={d} admitted_raw_bytes={d} remaining_raw_bytes={d} projected_bytes={d} escaped_controls={d} escaped_invalid={d} children_reaped={d} workers_joined={d} artifact=false",
            .{
                @tagName(shared.cause.?),
                shared.budget.limit,
                shared.budget.admitted,
                shared.budget.remaining(),
                output.stdout.items.len + output.stderr.items.len,
                output.escaped_controls,
                output.escaped_invalid,
                child_count,
                workers.len,
            },
        );
        return failure;
    }
    try output.flushCallbacks();

    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());
    debug_trace.logf(
        "core",
        "direct command completed route=direct_read_only limit={d} admitted_raw_bytes={d} remaining_raw_bytes={d} projected_bytes={d} escaped_controls={d} escaped_invalid={d} children_reaped={d} workers_joined={d} artifact=false",
        .{
            shared.budget.limit,
            shared.budget.admitted,
            shared.budget.remaining(),
            output.stdout.items.len + output.stderr.items.len,
            output.escaped_controls,
            output.escaped_invalid,
            child_count,
            workers.len,
        },
    );
    return formatDirectResult(
        alloc,
        plan,
        final_term,
        output.stdout.items,
        output.stderr.items,
        output.stdout_bytes,
        output.stderr_bytes,
        duration_ms,
    );
}

fn environmentForProfile(
    alloc: std.mem.Allocator,
    profile: command_effect.EnvironmentProfile,
) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(alloc);
    errdefer environment.deinit();
    switch (profile) {
        .basic_read_only, .git_read_only => {
            try environment.put("PATH", "/usr/bin:/bin");
            try environment.put("LC_ALL", "C");
            try environment.put("LANG", "C");
        },
    }
    if (profile == .git_read_only) {
        try environment.put("GIT_CONFIG_NOSYSTEM", "1");
        try environment.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try environment.put("GIT_OPTIONAL_LOCKS", "0");
        try environment.put("GIT_TERMINAL_PROMPT", "0");
        try environment.put("GIT_PAGER", "cat");
        try environment.put("PAGER", "cat");
    }
    return environment;
}

const DirectTerminationCause = enum {
    cancelled,
    timed_out,
    output_limit,
    output_failure,
};

const SharedExecution = struct {
    cfg: command_runner.Config,
    budget: DirectOutputBudget,
    output: *DirectOutput,
    lock: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    cause: ?DirectTerminationCause = null,
    failure_value: ?anyerror = null,

    fn commit(
        self: *SharedExecution,
        reported: DirectTerminationCause,
        failure_value: anyerror,
    ) void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.cause != null) return;

        if (self.cfg.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) {
                self.cause = .cancelled;
                self.failure_value = error.Cancelled;
                self.stopping.store(true, .release);
                return;
            }
        }
        if (deadlineExpired(self.cfg)) {
            self.cause = .timed_out;
            self.failure_value = error.TimeoutExpired;
            self.stopping.store(true, .release);
            return;
        }

        self.cause = reported;
        self.failure_value = failure_value;
        self.stopping.store(true, .release);
    }

    fn isStopping(self: *SharedExecution) bool {
        return self.stopping.load(.acquire);
    }

    fn failure(self: *SharedExecution) ?anyerror {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        return self.failure_value;
    }
};

const WorkerKind = union(enum) {
    relay,
    projected: command_contract.CommandOutputStream,
};

const RelayWriteResult = enum {
    forwarded,
    downstream_closed,
};

fn writeRelayChunk(destination: std.Io.File, raw: []const u8) !RelayWriteResult {
    destination.writeStreamingAll(io_mod.getIo(), raw) catch |err| switch (err) {
        error.BrokenPipe => return .downstream_closed,
        else => return err,
    };
    return .forwarded;
}

const OutputWorker = struct {
    shared: *SharedExecution,
    source: std.Io.File,
    destination: ?std.Io.File = null,
    kind: WorkerKind,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn run(self: *OutputWorker) void {
        defer self.done.store(true, .release);
        defer self.source.close(io_mod.getIo());
        defer if (self.destination) |destination| destination.close(io_mod.getIo());

        self.runFallible() catch |err| self.shared.commit(.output_failure, err);
    }

    fn runFallible(self: *OutputWorker) !void {
        var projector: DirectOutputProjector = .{};
        defer self.shared.output.addProjectionStats(projector.escaped_controls, projector.escaped_invalid);
        var projected: std.ArrayList(u8) = .empty;
        defer projected.deinit(self.shared.output.alloc);
        var buffer: [direct_output_read_chunk_bytes]u8 = undefined;

        while (!self.shared.isStopping()) {
            const count = self.source.readStreaming(io_mod.getIo(), &.{buffer[0..]}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (count == 0) break;
            const raw = buffer[0..count];
            const charge = self.shared.budget.charge(raw.len);
            if (!charge.admit_chunk) {
                if (charge.trip_owner) {
                    debug_trace.logf(
                        "core",
                        "direct_output_limit_exceeded route=direct_read_only limit={d} admitted_raw_bytes={d} remaining_raw_bytes={d} stream={s}",
                        .{
                            self.shared.budget.limit,
                            self.shared.budget.admitted,
                            self.shared.budget.remaining(),
                            @tagName(self.kind),
                        },
                    );
                    self.shared.commit(.output_limit, error.DirectOutputLimitExceeded);
                }
                break;
            }

            switch (self.kind) {
                .relay => switch (try writeRelayChunk(self.destination.?, raw)) {
                    .forwarded => {},
                    .downstream_closed => {
                        const remaining = self.shared.budget.remaining();
                        debug_trace.logf(
                            "core",
                            "direct relay route=direct_read_only downstream_closed=true admitted_raw_bytes={d} remaining_raw_bytes={d}",
                            .{ self.shared.budget.limit - remaining, remaining },
                        );
                        break;
                    },
                },
                .projected => |stream| {
                    try projector.push(self.shared.output.alloc, raw, &projected);
                    try self.shared.output.append(stream, raw, projected.items);
                    projected.clearRetainingCapacity();
                },
            }
        }

        if (!self.shared.isStopping()) {
            switch (self.kind) {
                .relay => {},
                .projected => |stream| {
                    try projector.finish(self.shared.output.alloc, &projected);
                    try self.shared.output.append(stream, "", projected.items);
                },
            }
        }
    }

    fn closeUnstarted(self: *OutputWorker) void {
        self.source.close(io_mod.getIo());
        if (self.destination) |destination| destination.close(io_mod.getIo());
        self.done.store(true, .release);
    }
};

const DirectOutput = struct {
    alloc: std.mem.Allocator,
    cfg: command_runner.Config,
    lock: std.Io.Mutex = .init,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_pending: std.ArrayList(u8) = .empty,
    stderr_pending: std.ArrayList(u8) = .empty,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    escaped_controls: usize = 0,
    escaped_invalid: usize = 0,

    fn init(alloc: std.mem.Allocator, cfg: command_runner.Config) DirectOutput {
        return .{ .alloc = alloc, .cfg = cfg };
    }

    fn deinit(self: *DirectOutput) void {
        self.stdout.deinit(self.alloc);
        self.stderr.deinit(self.alloc);
        self.stdout_pending.deinit(self.alloc);
        self.stderr_pending.deinit(self.alloc);
    }

    fn append(
        self: *DirectOutput,
        stream: command_contract.CommandOutputStream,
        raw: []const u8,
        projected: []const u8,
    ) !void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        try self.emitAcceptedCallback(stream, raw);
        switch (stream) {
            .stdout => {
                self.stdout_bytes += raw.len;
                try self.stdout.appendSlice(self.alloc, projected);
                try self.emitCallback(&self.stdout_pending, stream, raw, projected, false);
            },
            .stderr => {
                self.stderr_bytes += raw.len;
                try self.stderr.appendSlice(self.alloc, projected);
                try self.emitCallback(&self.stderr_pending, stream, raw, projected, false);
            },
        }
    }

    fn flushCallbacks(self: *DirectOutput) !void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.emitCallback(&self.stdout_pending, .stdout, "", "", true);
        try self.emitCallback(&self.stderr_pending, .stderr, "", "", true);
    }

    fn addProjectionStats(
        self: *DirectOutput,
        escaped_controls: usize,
        escaped_invalid: usize,
    ) void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.escaped_controls += escaped_controls;
        self.escaped_invalid += escaped_invalid;
    }

    fn emitCallback(
        self: *DirectOutput,
        pending: *std.ArrayList(u8),
        stream: command_contract.CommandOutputStream,
        raw: []const u8,
        projected: []const u8,
        flush: bool,
    ) !void {
        const bytes = switch (self.cfg.callback_projection) {
            .model_safe => projected,
            .raw => raw,
        };
        if (bytes.len > 0) try pending.appendSlice(self.alloc, bytes);
        const ctx = self.cfg.output_chunk_ctx orelse return;
        const callback = self.cfg.on_output_chunk orelse return;

        while (std.mem.findScalar(u8, pending.items, '\n')) |newline| {
            try callback(ctx, self.cfg.output_chunk_lifecycle_id, stream, pending.items[0 .. newline + 1]);
            const remaining = pending.items.len - newline - 1;
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[newline + 1 ..]);
            pending.items.len = remaining;
        }
        if (!flush and pending.items.len >= direct_output_read_chunk_bytes) {
            try callback(ctx, self.cfg.output_chunk_lifecycle_id, stream, pending.items);
            pending.clearRetainingCapacity();
        }
        if (flush and pending.items.len > 0) {
            try callback(ctx, self.cfg.output_chunk_lifecycle_id, stream, pending.items);
            pending.clearRetainingCapacity();
        }
    }

    fn emitAcceptedCallback(
        self: *DirectOutput,
        stream: command_contract.CommandOutputStream,
        raw: []const u8,
    ) !void {
        if (raw.len == 0) return;
        const ctx = self.cfg.accepted_output_chunk_ctx orelse return;
        const callback = self.cfg.on_accepted_output_chunk orelse return;
        try callback(ctx, self.cfg.output_chunk_lifecycle_id, stream, raw);
    }
};

fn allWorkersDone(workers: []const OutputWorker) bool {
    for (workers) |*worker| {
        if (!worker.done.load(.acquire)) return false;
    }
    return true;
}

fn checkControl(cfg: command_runner.Config) !void {
    if (cfg.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }
    if (deadlineExpired(cfg)) return error.TimeoutExpired;
}

fn deadlineExpired(cfg: command_runner.Config) bool {
    const timeout_ms = cfg.timeout_ms orelse return false;
    const started_ms = cfg.timeout_started_ms orelse return false;
    return io_mod.milliTimestamp() - started_ms >= @as(i64, @intCast(timeout_ms));
}

fn signalGroup(group_id: ?std.posix.pid_t, force: bool) void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    const pid = group_id orelse return;
    std.posix.kill(-pid, if (force) std.posix.SIG.KILL else std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => debug_trace.logf("core", "direct command signal failed err={s}", .{@errorName(err)}),
    };
}

fn closeChildPipes(child: *std.process.Child) void {
    if (child.stdin) |file| file.close(io_mod.getIo());
    if (child.stdout) |file| file.close(io_mod.getIo());
    if (child.stderr) |file| file.close(io_mod.getIo());
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}

fn cleanupChildren(children: []std.process.Child, group_id: ?std.posix.pid_t) void {
    signalGroup(group_id, true);
    for (children) |*child| closeChildPipes(child);
    waitChildren(children);
}

fn waitChildren(children: []std.process.Child) void {
    for (children) |*child| {
        _ = child.wait(io_mod.getIo()) catch |err| {
            debug_trace.logf("core", "direct command cleanup wait failed err={s}", .{@errorName(err)});
        };
    }
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    if (finished_ms <= started_ms) return 0;
    return @intCast(finished_ms - started_ms);
}

fn formatDirectResult(
    alloc: std.mem.Allocator,
    plan: command_effect.DirectReadOnlyPlan,
    term: std.process.Child.Term,
    stdout_projected: []const u8,
    stderr_projected: []const u8,
    stdout_bytes: usize,
    stderr_bytes: usize,
    duration_ms: u64,
) !command_contract.RunCommandResult {
    return command_contract.formatForegroundCommandResult(alloc, .{
        .command = plan.command,
        .cwd = plan.cwd,
        .status = foregroundCommandStatusFromTerm(term),
        .stdout_display = stdout_projected,
        .stderr_display = stderr_projected,
        .stdout_bytes = stdout_bytes,
        .stderr_bytes = stderr_bytes,
        .duration_ms = duration_ms,
    });
}

fn foregroundCommandStatusFromTerm(term: std.process.Child.Term) command_contract.ForegroundCommandStatus {
    return switch (term) {
        .exited => |code| .{ .exit_code = @intCast(code) },
        .signal => |sig| .{ .signal = @intFromEnum(sig) },
        else => .finished,
    };
}

fn projectForTest(alloc: std.mem.Allocator, chunks: []const []const u8) ![]u8 {
    var projector: DirectOutputProjector = .{};
    var projected: std.ArrayList(u8) = .empty;
    errdefer projected.deinit(alloc);
    for (chunks) |chunk| try projector.push(alloc, chunk, &projected);
    try projector.finish(alloc, &projected);
    return projected.toOwnedSlice(alloc);
}











fn createListingFiles(
    dir: std.Io.Dir,
    full_length_count: usize,
    include_254_byte_name: bool,
    include_one_byte_name: bool,
) !void {
    for (0..full_length_count) |index| {
        var name: [255]u8 = undefined;
        @memset(&name, 'x');
        _ = try std.fmt.bufPrint(name[0..4], "{d:0>4}", .{index});
        var file = try dir.createFile(io_mod.getIo(), &name, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    if (include_254_byte_name) {
        var name: [254]u8 = undefined;
        @memset(&name, 'y');
        var file = try dir.createFile(io_mod.getIo(), &name, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    if (include_one_byte_name) {
        var file = try dir.createFile(io_mod.getIo(), "z", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
}


fn injectedPlan(
    cwd: []const u8,
    stages: []const command_effect.DirectStage,
) command_effect.DirectReadOnlyPlan {
    return .{
        .command = stages[0].executable,
        .cwd = cwd,
        .stages = stages,
    };
}








const CallbackCapture = struct {
    stdout: [512]u8 = undefined,
    stdout_len: usize = 0,
    stderr: [512]u8 = undefined,
    stderr_len: usize = 0,
    streams: [16]command_contract.CommandOutputStream = undefined,
    stream_len: usize = 0,

    fn onChunk(
        raw_ctx: *anyopaque,
        _: ?types.ToolLifecycleId,
        stream: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        const self: *CallbackCapture = @ptrCast(@alignCast(raw_ctx));
        std.debug.assert(self.stream_len < self.streams.len);
        self.streams[self.stream_len] = stream;
        self.stream_len += 1;
        switch (stream) {
            .stdout => {
                std.debug.assert(self.stdout_len + chunk.len <= self.stdout.len);
                @memcpy(self.stdout[self.stdout_len .. self.stdout_len + chunk.len], chunk);
                self.stdout_len += chunk.len;
            },
            .stderr => {
                std.debug.assert(self.stderr_len + chunk.len <= self.stderr.len);
                @memcpy(self.stderr[self.stderr_len .. self.stderr_len + chunk.len], chunk);
                self.stderr_len += chunk.len;
            },
        }
    }
};










