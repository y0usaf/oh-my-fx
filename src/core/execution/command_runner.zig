const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const command_contract = @import("command_contract.zig");
const command_environment = @import("command_environment.zig");
const process_tree = @import("process_tree.zig");
const background_process_provider = @import(
    "background_process_provider.zig",
);
const io_mod = @import("../shared/io.zig");
const self_exe = @import("../shared/self_exe.zig");
const background_launch_output = @import("../background/background_launch_output.zig");
const config_runtime = @import("../config/config_runtime.zig");
const session_child_store = @import("../session/session_child_store.zig");
const artifact_digest = @import("../session/artifact_digest.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const darwin_process_spawn = @import("../shared/darwin_process_spawn.zig");

const Allocator = std.mem.Allocator;
pub const CommandOutputStream = command_contract.CommandOutputStream;
pub const CommandOutputCallback = command_contract.CommandOutputCallback;
pub const CommandExecutionResult = command_contract.RunCommandResult;

/// Foreground command execution configuration. Borrowed slices and callbacks
/// must remain valid for the duration of executeCommand.
pub const Config = struct {
    max_command_output_bytes: usize,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: ?*anyopaque = null,
    on_output_chunk: ?CommandOutputCallback = null,
    accepted_output_chunk_ctx: ?*anyopaque = null,
    on_accepted_output_chunk: ?CommandOutputCallback = null,
    callback_projection: CallbackProjection = .model_safe,
    timeout_ms: ?usize = null,
    timeout_started_ms: ?i64 = null,
    command_artifact_capability: ?*session_child_store.SessionChildCapability = null,
    command_artifact_dir: ?[]const u8 = null,
    background_process_provider: background_process_provider.Provider =
        background_process_provider.unavailable_provider,
};

pub const CallbackProjection = enum {
    model_safe,
    raw,
};

const command_artifact_file_prefix = "fx-command-";
const command_artifact_fallback_dir_name = "fx-command-output";
const command_artifact_log_suffix = ".log";
const command_artifact_stdout_suffix = ".stdout.log";
const command_artifact_stderr_suffix = ".stderr.log";
const pending_output_flush_bytes: usize = 4096;
const command_output_poll_ms: i64 = 100;
const supports_foreground_session = builtin.link_libc and
    std.process.can_spawn and
    std.process.can_replace and
    builtin.os.tag != .windows and
    builtin.os.tag != .wasi;
const foreground_session_token = "__fx_foreground_session__";
const foreground_session_ready_byte: u8 = 0x1e;
const foreground_session_release_byte: u8 = 0x06;
const foreground_session_setup_timeout_ms: i64 = 5000;
const foreground_target_termination_grace_ms: i64 = 700;
const foreground_target_cleanup_wait_ms: i64 = 250;
const foreground_supervisor_handoff_ms: i64 = command_output_poll_ms * 2;
const foreground_session_replace_failure_exit_code: u8 = 125;
const foreground_session_failure_nonce_bytes: usize = 16;
const foreground_session_failure_nonce_hex_bytes: usize = foreground_session_failure_nonce_bytes * 2;
const foreground_session_control_bytes = foreground_session_failure_nonce_hex_bytes + 1;
const foreground_session_replace_failure_prefix = "\x00FX_FOREGROUND_EXEC_FAILED:";
const foreground_session_replace_failure_marker_bytes =
    foreground_session_replace_failure_prefix.len +
    foreground_session_failure_nonce_hex_bytes + 1;
const foreground_session_force_signal = std.posix.SIG.USR1;
const ForegroundSessionTerminationRequest = enum(std.c.sig_atomic_t) {
    none,
    graceful,
    force,
};
var foreground_session_termination_request: std.c.sig_atomic_t =
    @intFromEnum(ForegroundSessionTerminationRequest.none);
const foreground_session_replace_error_name_bytes = blk: {
    var max_len: usize = 0;
    for (std.meta.fields(std.process.ReplaceError)) |field| {
        max_len = @max(max_len, field.name.len);
    }
    break :blk max_len;
};
const script_from_stdin_launcher =
    "script=$(command cat; command printf .)\n" ++
    "script=${script%.}\n" ++
    "eval \"$script\" </dev/null";

pub fn isForegroundSessionInvocation(args: []const [:0]const u8) bool {
    if (comptime !supports_foreground_session) return false;
    return args.len > 0 and std.mem.eql(u8, args[0], foreground_session_token);
}

pub fn runForegroundSessionBootstrap(args: []const [:0]const u8) !void {
    if (comptime !supports_foreground_session) {
        return error.OperationUnsupported;
    }
    if (!isForegroundSessionInvocation(args) or args.len < 3) {
        return error.InvalidForegroundSessionInvocation;
    }
    const deadline_ms = if (std.mem.eql(u8, args[1], "none"))
        null
    else
        std.fmt.parseInt(i64, args[1], 10) catch
            return error.InvalidForegroundSessionInvocation;
    if (std.c.setsid() == -1) return error.ForegroundSessionSetupFailed;

    const zio = io_mod.getIo();
    try std.Io.File.stderr().writeStreamingAll(
        zio,
        &.{foreground_session_ready_byte},
    );

    var control: [foreground_session_control_bytes]u8 = undefined;
    var control_len: usize = 0;
    while (control_len < control.len) {
        const read_len = std.Io.File.stdin().readStreaming(
            zio,
            &.{control[control_len..]},
        ) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidForegroundSessionRelease,
            else => |read_err| return read_err,
        };
        if (read_len == 0) return error.InvalidForegroundSessionRelease;
        control_len += read_len;
    }
    const failure_nonce = control[0..foreground_session_failure_nonce_hex_bytes];
    if (control[control.len - 1] != foreground_session_release_byte) {
        return error.InvalidForegroundSessionRelease;
    }

    @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_request).* =
        @intFromEnum(ForegroundSessionTerminationRequest.none);
    const supervisor_action: std.posix.Sigaction = .{
        .handler = .{ .handler = recordForegroundSessionTermination },
        .mask = foregroundSupervisorSignalMask(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &supervisor_action, null);
    std.posix.sigaction(foreground_session_force_signal, &supervisor_action, null);
    if (comptime builtin.os.tag == .linux) {
        _ = try std.posix.prctl(.SET_CHILD_SUBREAPER, .{@as(usize, 1)});
    }
    var process_witness: ?process_tree.DarwinProcessWitness =
        if (comptime builtin.os.tag == .macos)
            try .init()
        else
            null;
    defer if (process_witness) |*witness| witness.deinit();
    const spawn_options: std.process.SpawnOptions = .{
        .argv = args[2..],
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .start_suspended = builtin.os.tag == .macos,
    };
    var target = (if (comptime builtin.os.tag == .macos)
        darwin_process_spawn.spawn_inheriting_fd(
            zio,
            spawn_options,
            process_witness.?.childFd(),
        )
    else
        std.process.spawn(zio, spawn_options)) catch |err| {
        writeForegroundSessionReplaceFailure(failure_nonce, err);
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    if (process_witness) |*witness| witness.closeChildCopy();
    const term = waitForForegroundTarget(
        &target,
        if (process_witness) |*witness| witness else null,
        deadline_ms,
    ) catch |err| {
        target.kill(zio);
        writeForegroundSessionReplaceFailure(failure_nonce, err);
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    exitForegroundSessionSupervisor(term);
}

fn recordForegroundSessionTermination(signal: std.posix.SIG) callconv(.c) void {
    const request = @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_request);
    request.* = @intFromEnum(mergeForegroundSessionTerminationRequest(
        @enumFromInt(request.*),
        signal,
    ));
}

fn foregroundSupervisorSignalMask() std.posix.sigset_t {
    var mask = std.posix.sigemptyset();
    std.posix.sigaddset(&mask, std.posix.SIG.TERM);
    std.posix.sigaddset(&mask, foreground_session_force_signal);
    return mask;
}

fn mergeForegroundSessionTerminationRequest(
    current: ForegroundSessionTerminationRequest,
    signal: std.posix.SIG,
) ForegroundSessionTerminationRequest {
    if (current == .force or signal == foreground_session_force_signal) return .force;
    if (current == .none and signal == std.posix.SIG.TERM) return .graceful;
    return current;
}

fn foregroundSessionTerminationRequest() ForegroundSessionTerminationRequest {
    return @enumFromInt(
        @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_request).*,
    );
}

const ForegroundTerminationAction = enum {
    none,
    begin_graceful,
    force,
};

fn decideForegroundTerminationAction(
    request: ForegroundSessionTerminationRequest,
    termination_started_ms: ?i64,
    forced: bool,
    now_ms: i64,
) ForegroundTerminationAction {
    if (forced or request == .none) return .none;
    if (request == .force) return .force;
    const started_ms = termination_started_ms orelse return .begin_graceful;
    if (now_ms >= started_ms and
        now_ms - started_ms >= foreground_target_termination_grace_ms)
    {
        return .force;
    }
    return .none;
}

fn foregroundRequestAtDeadline(
    observed: ForegroundSessionTerminationRequest,
    deadline_ms: ?i64,
    now_ms: i64,
) ForegroundSessionTerminationRequest {
    if (observed != .none) return observed;
    const deadline = deadline_ms orelse return .none;
    return if (now_ms >= deadline) .force else .none;
}

const ChildWaiter = struct {
    child: *std.process.Child,
    io: std.Io,
    ready: std.atomic.Value(bool) = .init(false),
    result: std.process.Child.WaitError!std.process.Child.Term = undefined,
    future: ?std.Io.Future(void) = null,

    fn init(child: *std.process.Child) ChildWaiter {
        return .{
            .child = child,
            .io = io_mod.getIo(),
        };
    }

    fn start(self: *ChildWaiter) !void {
        self.future = try std.Io.concurrent(
            self.io,
            ChildWaiter.waitMain,
            .{self},
        );
    }

    fn waitMain(self: *ChildWaiter) void {
        self.result = self.child.wait(self.io);
        self.ready.store(true, .release);
    }

    fn isReady(self: *const ChildWaiter) bool {
        return self.ready.load(.acquire);
    }

    fn awaitReady(self: *ChildWaiter) !std.process.Child.Term {
        std.debug.assert(self.isReady());
        var future = &self.future.?;
        future.await(self.io);
        return try self.result;
    }

    fn awaitDiscard(self: *ChildWaiter) void {
        var future = &self.future.?;
        future.await(self.io);
    }

    fn abort(self: *ChildWaiter, pid: std.posix.pid_t) void {
        if (self.isReady()) {
            self.awaitDiscard();
            return;
        }
        signalProcess(pid, std.posix.SIG.KILL) catch {};
        self.awaitDiscard();
    }
};

fn waitForForegroundTarget(
    target: *std.process.Child,
    process_witness: ?*const process_tree.DarwinProcessWitness,
    deadline_ms: ?i64,
) !std.process.Child.Term {
    const target_pid = target.id orelse return error.ForegroundTargetMissing;
    var descendants = try process_tree.Tracker.init(std.heap.page_allocator);
    defer descendants.deinit();
    if (process_witness) |witness| {
        descendants.bindProcessWitness(witness);
    }
    if (comptime builtin.os.tag == .macos) {
        try descendants.refresh(target_pid);
        try std.posix.kill(target_pid, std.posix.SIG.CONT);
    }
    var waiter = ChildWaiter.init(target);
    try waiter.start();
    var wait_pending = true;
    defer if (wait_pending) waiter.abort(target_pid);
    var termination_started_ms: ?i64 = null;
    var forced = false;

    while (true) {
        const now_ms = io_mod.milliTimestamp();
        const request = foregroundRequestAtDeadline(
            foregroundSessionTerminationRequest(),
            deadline_ms,
            now_ms,
        );
        if (request == .force) {
            @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_request).* =
                @intFromEnum(ForegroundSessionTerminationRequest.force);
        }
        try refreshForegroundTargetTree(&descendants, target_pid);
        advanceForegroundTargetTermination(
            &descendants,
            request,
            now_ms,
            &termination_started_ms,
            &forced,
        );

        if (waiter.isReady()) {
            wait_pending = false;
            const term = try waiter.awaitReady();
            try refreshForegroundTargetTree(&descendants, target_pid);
            advanceForegroundTargetTermination(
                &descendants,
                foregroundSessionTerminationRequest(),
                io_mod.milliTimestamp(),
                &termination_started_ms,
                &forced,
            );
            if (termination_started_ms) |started_ms| {
                try waitForForegroundTargetDescendants(
                    &descendants,
                    target_pid,
                    started_ms,
                    &forced,
                );
                return term;
            }
            const count = try cleanupCompletedForegroundTarget(
                &descendants,
                target_pid,
            );
            if (count > 0) {
                debug_trace.logf(
                    "core",
                    "captured command target completed; tracked descendants terminated count={d}",
                    .{count},
                );
            }
            return term;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn cleanupCompletedForegroundTarget(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
) !usize {
    const started_ms = io_mod.milliTimestamp();
    var signaled: usize = 0;
    var empty_scans: u8 = 0;
    while (io_mod.milliTimestamp() - started_ms <
        foreground_target_cleanup_wait_ms)
    {
        try refreshForegroundTargetTree(descendants, target_pid);
        signaled += descendants.signalAll(std.posix.SIG.KILL);
        if (descendants.anyAlive()) {
            empty_scans = 0;
        } else {
            empty_scans += 1;
            if (empty_scans >= 2) return signaled;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
    try refreshForegroundTargetTree(descendants, target_pid);
    signaled += descendants.signalAll(std.posix.SIG.KILL);
    return signaled;
}

fn refreshForegroundTargetTree(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
) !void {
    try descendants.refresh(target_pid);
    if (comptime builtin.os.tag == .linux) {
        try descendants.refreshAdditionalRoot(std.c.getpid());
    }
    if (comptime builtin.os.tag == .macos) {
        if (foregroundSessionTerminationRequest() != .none) {
            try descendants.refreshLineageProcesses();
        }
    }
}

fn advanceForegroundTargetTermination(
    descendants: *process_tree.Tracker,
    request: ForegroundSessionTerminationRequest,
    now_ms: i64,
    termination_started_ms: *?i64,
    forced: *bool,
) void {
    switch (decideForegroundTerminationAction(
        request,
        termination_started_ms.*,
        forced.*,
        now_ms,
    )) {
        .none => {},
        .begin_graceful => {
            termination_started_ms.* = now_ms;
            const count = descendants.signalOutsideProcessGroup(
                std.posix.SIG.TERM,
                std.c.getpid(),
            );
            debug_trace.logf(
                "core",
                "captured command termination reached tracked descendants count={d}",
                .{count},
            );
        },
        .force => {
            if (termination_started_ms.* == null) termination_started_ms.* = now_ms;
            forced.* = true;
            forceKillForegroundTargetDescendants(descendants);
        },
    }
}

fn waitForForegroundTargetDescendants(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
    termination_started_ms: i64,
    forced: *bool,
) !void {
    var empty_scans: u8 = 0;
    while (true) {
        try refreshForegroundTargetTree(descendants, target_pid);
        const now_ms = io_mod.milliTimestamp();
        if (!forced.* and
            now_ms - termination_started_ms >= foreground_target_termination_grace_ms)
        {
            forced.* = true;
            forceKillForegroundTargetDescendants(descendants);
        }
        if (forced.*) {
            _ = descendants.signalAll(std.posix.SIG.KILL);
        }
        if (descendants.anyAlive()) {
            empty_scans = 0;
        } else {
            empty_scans += 1;
            if (empty_scans >= 2) return;
        }
        if (forced.* and
            now_ms - termination_started_ms >=
                foreground_target_termination_grace_ms + foreground_target_cleanup_wait_ms)
        {
            return;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn forceKillForegroundTargetDescendants(
    descendants: *process_tree.Tracker,
) void {
    const count = descendants.signalAll(std.posix.SIG.KILL);
    debug_trace.logf(
        "core",
        "captured command force-killed tracked descendants count={d}",
        .{count},
    );
}

fn writeForegroundSessionReplaceFailure(
    nonce: []const u8,
    err: anyerror,
) void {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        foreground_session_replace_failure_prefix ++ "{s}:{s}\n",
        .{ nonce, @errorName(err) },
    ) catch foreground_session_replace_failure_prefix ++ "unknown\n";
    std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), message) catch {};
}

fn exitForegroundSessionSupervisor(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |signal| {
            if (signal != std.posix.SIG.KILL and signal != std.posix.SIG.STOP) {
                const default_action: std.posix.Sigaction = .{
                    .handler = .{ .handler = std.posix.SIG.DFL },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                };
                std.posix.sigaction(signal, &default_action, null);
            }
            var signal_mask = std.posix.sigemptyset();
            std.posix.sigaddset(&signal_mask, signal);
            std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &signal_mask, null);
            std.posix.raise(signal) catch {};
            std.process.exit(128 + @as(u8, @truncate(@intFromEnum(signal))));
        },
        .stopped, .unknown => std.process.exit(127),
    }
}

/// Executes one command and returns an owned formatted result.
pub fn executeCommand(
    cfg: Config,
    arena: Allocator,
    command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    var scratch_state = std.heap.ArenaAllocator.init(arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var effective_cfg = cfg;
    if (effective_cfg.timeout_started_ms == null) effective_cfg.timeout_started_ms = io_mod.milliTimestamp();
    try ExecutionControl.init(effective_cfg).check();
    return executeRawBash(arena, scratch, effective_cfg, command, cwd);
}

pub fn executeCommandInEnvironment(
    cfg: Config,
    arena: Allocator,
    command: []const u8,
    cwd: []const u8,
    environment: command_environment.Environment,
) !command_contract.RunCommandResult {
    switch (environment) {
        .legacy => return executeCommand(cfg, arena, command, cwd),
        .workspace_clean => return error.InvalidCommandEnvironment,
        .clean, .user => {},
    }

    var scratch_state = std.heap.ArenaAllocator.init(arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var effective_cfg = cfg;
    if (effective_cfg.timeout_started_ms == null) effective_cfg.timeout_started_ms = io_mod.milliTimestamp();
    try ExecutionControl.init(effective_cfg).check();
    const invocation = try shell_resolver.capturedInvocation(scratch, environment, command);
    debug_trace.logf(
        "core",
        "command runner explicit environment={s} shell={s}",
        .{ @tagName(std.meta.activeTag(environment)), invocation.path },
    );
    return executeRawInvocation(
        arena,
        scratch,
        effective_cfg,
        command,
        cwd,
        &invocation,
    );
}

pub fn spawnPreparedBackground(
    cfg: Config,
    arena: Allocator,
    cwd: []const u8,
    output: *const background_launch_output.Output,
) !background_process_provider.PreparedProcess {
    var effective_cfg = cfg;
    if (effective_cfg.timeout_started_ms == null) {
        effective_cfg.timeout_started_ms = io_mod.milliTimestamp();
    }
    try ExecutionControl.init(effective_cfg).check();
    return effective_cfg.background_process_provider.spawnPrepared(
        arena,
        .{
            .cwd = cwd,
            .output = output.providerCapability(),
            .isolation = .none,
        },
    );
}
const ExecutionControl = struct {
    cancel_flag: ?*std.atomic.Value(bool),
    timeout_ms: ?usize,
    started_ms: i64,

    fn init(cfg: Config) ExecutionControl {
        return .{
            .cancel_flag = cfg.cancel_flag,
            .timeout_ms = cfg.timeout_ms,
            .started_ms = cfg.timeout_started_ms orelse io_mod.milliTimestamp(),
        };
    }

    fn check(self: ExecutionControl) !void {
        if (cancelRequested(self.cancel_flag)) return error.CancelledBeforeExecution;
        if (self.timeout_ms) |timeout_ms| {
            const now_ms = io_mod.milliTimestamp();
            const elapsed_ms: u64 = if (now_ms > self.started_ms) @intCast(now_ms - self.started_ms) else 0;
            if (elapsed_ms >= timeout_ms) return error.TimeoutExpired;
        }
    }

    fn deadlineMs(self: ExecutionControl) ?i64 {
        const timeout_ms = self.timeout_ms orelse return null;
        const timeout_i64 = std.math.cast(i64, timeout_ms) orelse return std.math.maxInt(i64);
        const sum = @addWithOverflow(self.started_ms, timeout_i64);
        return if (sum[1] == 0) sum[0] else std.math.maxInt(i64);
    }
};

fn foreground_supervisor_fallback_deadline_ms(deadline_ms: ?i64) ?i64 {
    const deadline = deadline_ms orelse return null;
    return deadline +| foreground_supervisor_handoff_ms;
}

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

fn emitAcceptedOutputChunk(
    cfg: Config,
    stream: CommandOutputStream,
    bytes: []const u8,
) !void {
    if (bytes.len == 0) return;
    const ctx = cfg.accepted_output_chunk_ctx orelse return;
    const callback = cfg.on_accepted_output_chunk orelse return;
    try callback(ctx, cfg.output_chunk_lifecycle_id, stream, bytes);
}

const CollectedProcess = struct {
    status: command_contract.ForegroundCommandStatus,
    stdout: []const u8,
    stderr: []const u8,
    stdout_bytes: usize,
    stderr_bytes: usize,
    duration_ms: ?u64 = null,
    truncated: bool = false,
    output_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,
    stdout_preview: StreamPreviewSnapshot = .{},
    stderr_preview: StreamPreviewSnapshot = .{},
    cancelled: bool = false,
};

const StreamPreviewSnapshot = struct {
    head: []const u8 = "",
    tail: []const u8 = "",
    total_bytes: usize = 0,
    max_bytes: usize = 0,
};

const StreamPreview = struct {
    max_bytes: usize,
    head_limit: usize,
    tail_limit: usize,
    total_bytes: usize = 0,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,

    fn init(max_bytes: usize) StreamPreview {
        const head_limit = if (max_bytes == 0) 0 else (max_bytes + 1) / 2;
        return .{
            .max_bytes = max_bytes,
            .head_limit = head_limit,
            .tail_limit = if (max_bytes > head_limit) max_bytes - head_limit else 0,
        };
    }

    fn deinit(self: *StreamPreview, alloc: Allocator) void {
        self.head.deinit(alloc);
        self.tail.deinit(alloc);
        self.* = undefined;
    }

    fn append(self: *StreamPreview, alloc: Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.total_bytes += bytes.len;

        if (self.head.items.len < self.head_limit) {
            const take = @min(self.head_limit - self.head.items.len, bytes.len);
            try self.head.appendSlice(alloc, bytes[0..take]);
        }

        if (self.tail_limit == 0) return;
        try self.appendTail(alloc, bytes);
    }

    fn appendTail(self: *StreamPreview, alloc: Allocator, bytes: []const u8) !void {
        if (bytes.len >= self.tail_limit) {
            self.tail.clearRetainingCapacity();
            try self.tail.appendSlice(alloc, bytes[bytes.len - self.tail_limit ..]);
            return;
        }

        if (self.tail.items.len + bytes.len > self.tail_limit) {
            const drop = self.tail.items.len + bytes.len - self.tail_limit;
            const keep = self.tail.items.len - drop;
            std.mem.copyForwards(u8, self.tail.items[0..keep], self.tail.items[drop..]);
            self.tail.items.len = keep;
        }
        try self.tail.appendSlice(alloc, bytes);
    }

    fn snapshot(self: *StreamPreview, alloc: Allocator) !StreamPreviewSnapshot {
        return .{
            .head = try self.head.toOwnedSlice(alloc),
            .tail = try self.tail.toOwnedSlice(alloc),
            .total_bytes = self.total_bytes,
            .max_bytes = self.max_bytes,
        };
    }
};

const ArtifactFile = union(enum) {
    external: std.Io.File,
    managed: session_child_store.ManagedFile,

    fn writeAll(self: *ArtifactFile, bytes: []const u8) !void {
        switch (self.*) {
            .external => |file| try file.writeStreamingAll(io_mod.getIo(), bytes),
            .managed => |*file| try file.writeAll(bytes),
        }
    }

    fn sync(self: *ArtifactFile) !void {
        switch (self.*) {
            .external => |file| try file.sync(io_mod.getIo()),
            .managed => |*file| try file.sync(),
        }
    }

    fn close(self: *ArtifactFile) void {
        switch (self.*) {
            .external => |file| file.close(io_mod.getIo()),
            .managed => |*file| file.deinit(),
        }
    }
};

const CommandArtifact = struct {
    output_file: []const u8,
    stdout_file: []const u8,
    stderr_file: []const u8,
    output: ArtifactFile,
    stdout: ArtifactFile,
    stderr: ArtifactFile,
    managed_capability: ?*session_child_store.SessionChildCapability = null,
    output_hasher: std.crypto.hash.sha2.Sha256 =
        std.crypto.hash.sha2.Sha256.init(.{}),

    fn append(self: *CommandArtifact, stream: CommandOutputStream, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.output.writeAll(bytes);
        switch (stream) {
            .stdout => try self.stdout.writeAll(bytes),
            .stderr => try self.stderr.writeAll(bytes),
        }
        self.output_hasher.update(bytes);
    }

    fn close(self: *CommandArtifact) void {
        self.output.close();
        self.stdout.close();
        self.stderr.close();
    }

    fn sync(self: *CommandArtifact) !void {
        try self.output.sync();
        try self.stdout.sync();
        try self.stderr.sync();
    }

    fn contentAddressManagedOutput(
        self: *CommandArtifact,
        alloc: Allocator,
    ) !void {
        const capability = self.managed_capability orelse return;
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var hasher = self.output_hasher;
        hasher.final(&digest);
        const source_handle = std.fs.path.basename(self.output_file);
        const target_handle = try artifact_digest.contentAddressedHandle(
            alloc,
            source_handle,
            command_artifact_log_suffix,
            digest,
        );
        defer alloc.free(target_handle);
        const parent = std.fs.path.dirname(self.output_file) orelse
            return error.InvalidCommandArtifactPath;
        const target_path = try std.fs.path.join(
            alloc,
            &.{ parent, target_handle },
        );
        errdefer alloc.free(target_path);
        capability.rename(
            .command_artifacts,
            source_handle,
            target_handle,
        ) catch |err| {
            if (err == error.SessionChildCommitIndeterminate and
                try capability.confirmIndeterminateEntry(
                    .command_artifacts,
                    target_handle,
                ))
            {
                self.output_file = target_path;
                debug_trace.logf(
                    "core",
                    "command artifact rename durability confirmed handle={s}",
                    .{target_handle},
                );
                return;
            }
            return err;
        };
        self.output_file = target_path;
    }
};

const OutputCollector = struct {
    alloc: Allocator,
    cfg: Config,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_preview: StreamPreview,
    stderr_preview: StreamPreview,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    artifact: ?CommandArtifact = null,

    fn init(alloc: Allocator, cfg: Config) OutputCollector {
        const preview_limit = streamPreviewLimit(cfg.max_command_output_bytes);
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .stdout_preview = StreamPreview.init(preview_limit),
            .stderr_preview = StreamPreview.init(preview_limit),
        };
    }

    fn deinit(self: *OutputCollector) void {
        if (self.artifact) |*artifact| artifact.close();
        self.stdout.deinit(self.alloc);
        self.stderr.deinit(self.alloc);
        self.stdout_preview.deinit(self.alloc);
        self.stderr_preview.deinit(self.alloc);
        self.* = undefined;
    }

    fn append(self: *OutputCollector, stream: CommandOutputStream, bytes: []const u8) !void {
        if (bytes.len == 0) return;

        switch (stream) {
            .stdout => {
                self.stdout_bytes += bytes.len;
                try self.stdout_preview.append(self.alloc, bytes);
            },
            .stderr => {
                self.stderr_bytes += bytes.len;
                try self.stderr_preview.append(self.alloc, bytes);
            },
        }

        if (self.artifact) |*artifact| {
            try artifact.append(stream, bytes);
            return;
        }

        switch (stream) {
            .stdout => try self.stdout.appendSlice(self.alloc, bytes),
            .stderr => try self.stderr.appendSlice(self.alloc, bytes),
        }

        if (self.totalBytes() > self.cfg.max_command_output_bytes) {
            try self.startArtifact();
        }
    }

    fn finish(
        self: *OutputCollector,
        status: command_contract.ForegroundCommandStatus,
    ) !CollectedProcess {
        if (self.artifact) |*artifact| {
            try artifact.sync();
            try artifact.contentAddressManagedOutput(self.alloc);
            const truncated = self.totalBytes() > self.cfg.max_command_output_bytes;
            return .{
                .status = status,
                .stdout = "",
                .stderr = "",
                .stdout_bytes = self.stdout_bytes,
                .stderr_bytes = self.stderr_bytes,
                .truncated = truncated,
                .output_file = artifact.output_file,
                .stdout_file = artifact.stdout_file,
                .stderr_file = artifact.stderr_file,
                .stdout_preview = if (truncated) try self.stdout_preview.snapshot(self.alloc) else .{},
                .stderr_preview = if (truncated) try self.stderr_preview.snapshot(self.alloc) else .{},
            };
        }

        return .{
            .status = status,
            .stdout = try self.stdout.toOwnedSlice(self.alloc),
            .stderr = try self.stderr.toOwnedSlice(self.alloc),
            .stdout_bytes = self.stdout_bytes,
            .stderr_bytes = self.stderr_bytes,
        };
    }

    fn totalBytes(self: OutputCollector) usize {
        return self.stdout_bytes + self.stderr_bytes;
    }

    fn startArtifact(self: *OutputCollector) !void {
        if (self.artifact != null) return;
        var artifact = try createCommandArtifact(
            self.alloc,
            self.cfg.command_artifact_capability,
            self.cfg.command_artifact_dir,
        );
        errdefer artifact.close();
        try artifact.append(.stdout, self.stdout.items);
        try artifact.append(.stderr, self.stderr.items);
        debug_trace.logf(
            "core",
            "command output artifact created output_file={s} stdout_file={s} stderr_file={s} stdout_bytes={d} stderr_bytes={d}",
            .{ artifact.output_file, artifact.stdout_file, artifact.stderr_file, self.stdout_bytes, self.stderr_bytes },
        );
        self.stdout.clearRetainingCapacity();
        self.stderr.clearRetainingCapacity();
        self.artifact = artifact;
    }
};

fn finishCollectedProcess(
    output: *OutputCollector,
    status: command_contract.ForegroundCommandStatus,
    duration_ms: u64,
    source: TerminationSource,
) !CollectedProcess {
    switch (source) {
        .timed_out => return error.TimeoutExpired,
        .natural => {},
        .cancelled => {
            if (output.totalBytes() == 0) return error.Cancelled;
            if (output.artifact == null) {
                output.startArtifact() catch |err| {
                    debug_trace.logf("core", "cancelled command artifact promotion failed err={s}", .{@errorName(err)});
                    return error.Cancelled;
                };
            }
        },
    }

    var result = output.finish(status) catch |err| {
        if (source != .cancelled) return err;
        debug_trace.logf("core", "cancelled command artifact finalization failed err={s}", .{@errorName(err)});
        return error.Cancelled;
    };
    result.duration_ms = duration_ms;
    result.cancelled = source == .cancelled;
    return result;
}

fn executeProcess(scratch: Allocator, cfg: Config, argv: []const []const u8, cwd: []const u8) !CollectedProcess {
    return executeProcessWithInput(scratch, cfg, argv, cwd, false, true);
}

fn executeProcessWithClosedInput(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
) !CollectedProcess {
    if (comptime supports_foreground_session) {
        return executeProcessWithDetachedSession(
            scratch,
            cfg,
            argv,
            cwd,
            "",
        );
    }
    return executeProcessWithInput(scratch, cfg, argv, cwd, true, true);
}

fn executeProcessWithInput(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    closed_input: bool,
    isolate_process_group: bool,
) !CollectedProcess {
    const started_ms = io_mod.milliTimestamp();
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = if (closed_input) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .pgid = if (isolate_process_group and builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    });
    if (child.stdin) |input| {
        input.close(io_mod.getIo());
        child.stdin = null;
    }

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) cleanupChild(&child);

    const process_group_id = if (isolate_process_group and
        builtin.os.tag != .windows and builtin.os.tag != .wasi)
        child.id
    else
        null;
    child_needs_cleanup = false;
    const collected = try collectSpawnedProcess(
        scratch,
        &child,
        &output,
        cfg,
        null,
        process_group_id,
        .process_group,
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());

    return finishCollectedProcess(
        &output,
        collected.status,
        duration_ms,
        collected.source,
    );
}

fn executeProcessWithScript(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
) !CollectedProcess {
    if (comptime supports_foreground_session) {
        return executeProcessWithDetachedSession(
            scratch,
            cfg,
            argv,
            cwd,
            script,
        );
    }
    return executeProcessWithScriptUnisolated(
        scratch,
        cfg,
        argv,
        cwd,
        script,
    );
}

const ForegroundSessionPhase = enum {
    pre_ready,
    group_ready,
};

fn executeProcessWithDetachedSession(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
) !CollectedProcess {
    const executable = try foregroundSessionExecutable(scratch);
    var nonce_bytes: [foreground_session_failure_nonce_bytes]u8 = undefined;
    io_mod.getIo().random(&nonce_bytes);
    const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
    var failure_marker: [foreground_session_replace_failure_marker_bytes]u8 = undefined;
    @memcpy(
        failure_marker[0..foreground_session_replace_failure_prefix.len],
        foreground_session_replace_failure_prefix,
    );
    @memcpy(
        failure_marker[foreground_session_replace_failure_prefix.len..][0..nonce.len],
        &nonce,
    );
    failure_marker[failure_marker.len - 1] = ':';

    var helper_argv: std.ArrayList([]const u8) = .empty;
    try helper_argv.append(scratch, executable);
    try helper_argv.append(scratch, foreground_session_token);
    const deadline_ms = ExecutionControl.init(cfg).deadlineMs();
    const supervisor_deadline_ms = foreground_supervisor_fallback_deadline_ms(deadline_ms);
    const deadline_text = if (supervisor_deadline_ms) |value|
        try std.fmt.allocPrint(scratch, "{d}", .{value})
    else
        "none";
    try helper_argv.append(scratch, deadline_text);
    try helper_argv.appendSlice(scratch, argv);

    const started_ms = io_mod.milliTimestamp();
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = helper_argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
    });

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var phase: ForegroundSessionPhase = .pre_ready;
    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) {
        cleanupForegroundSessionChild(&child, phase);
    };

    try waitForForegroundSessionReady(&child, cfg);
    phase = .group_ready;
    try ExecutionControl.init(cfg).check();

    var script_write = child.stdin orelse return error.SpawnFailed;
    child.stdin = null;
    var script_write_open = true;
    defer if (script_write_open) script_write.close(io_mod.getIo());

    var script_write_error: ?std.Io.File.Writer.Error = null;
    script_write.writeStreamingAll(
        io_mod.getIo(),
        &nonce,
    ) catch |err| {
        script_write_error = err;
    };
    if (script_write_error == null) {
        script_write.writeStreamingAll(
            io_mod.getIo(),
            &.{foreground_session_release_byte},
        ) catch |err| {
            script_write_error = err;
        };
    }
    if (script_write_error == null) {
        script_write.writeStreamingAll(io_mod.getIo(), script) catch |err| {
            script_write_error = err;
        };
    }
    script_write.close(io_mod.getIo());
    script_write_open = false;

    var launch_failure_probe = ForegroundLaunchFailureProbe.init(&failure_marker);
    const process_group_id = child.id;
    child_needs_cleanup = false;
    var collected = try collectSpawnedProcess(
        scratch,
        &child,
        &output,
        cfg,
        &launch_failure_probe,
        process_group_id,
        .foreground_supervisor,
    );
    collected.source = reconcileForegroundTerminationSource(
        collected.source,
        deadline_ms,
        io_mod.milliTimestamp(),
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());

    if (foregroundSessionReplacementError(
        collected.status,
        launch_failure_probe,
    )) |launch_err| return launch_err;
    if (script_write_error) |write_err| return write_err;
    return finishCollectedProcess(
        &output,
        collected.status,
        duration_ms,
        collected.source,
    );
}

fn foregroundSessionExecutable(scratch: Allocator) ![]const u8 {
    if (comptime builtin.is_test) {
        const path_z = std.c.getenv("FX_TEST_PRODUCT_EXE") orelse
            return error.TestProductExecutableMissing;
        return std.mem.sliceTo(path_z, 0);
    }
    return self_exe.pathForReexec(scratch);
}

fn waitForForegroundSessionReady(
    child: *std.process.Child,
    cfg: Config,
) !void {
    const ready_read = child.stderr orelse return error.SpawnFailed;
    const setup_started_ms = io_mod.milliTimestamp();
    const control = ExecutionControl.init(cfg);

    while (true) {
        try control.check();
        const now_ms = io_mod.milliTimestamp();
        const setup_elapsed_ms = if (now_ms > setup_started_ms)
            now_ms - setup_started_ms
        else
            0;
        if (setup_elapsed_ms >= foreground_session_setup_timeout_ms) {
            return error.ForegroundSessionSetupTimedOut;
        }

        const remaining_ms = foreground_session_setup_timeout_ms - setup_elapsed_ms;
        const poll_timeout_ms: i32 = @intCast(@min(@as(i64, 50), remaining_ms));
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = ready_read.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, poll_timeout_ms) == 0) continue;

        const revents = poll_fds[0].revents;
        if ((revents & std.posix.POLL.IN) != 0) {
            var marker: [1]u8 = undefined;
            const marker_len = try std.posix.read(ready_read.handle, &marker);
            if (marker_len == 0) return error.ForegroundSessionSetupFailed;
            if (marker[0] != foreground_session_ready_byte) {
                return error.InvalidForegroundSessionReady;
            }
            return;
        }
        if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return error.ForegroundSessionSetupFailed;
        }
    }
}

fn cleanupForegroundSessionChild(
    child: *std.process.Child,
    phase: ForegroundSessionPhase,
) void {
    if (comptime !supports_foreground_session) {
        cleanupChild(child);
        return;
    }
    const pid = child.id orelse return;
    const target_pid = switch (phase) {
        .pre_ready => pid,
        .group_ready => -pid,
    };
    std.posix.kill(target_pid, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => debug_trace.logf(
            "core",
            "foreground session cleanup kill failed phase={s} err={s}",
            .{ @tagName(phase), @errorName(err) },
        ),
    };
    _ = child.wait(io_mod.getIo()) catch |err| {
        debug_trace.logf(
            "core",
            "foreground session cleanup wait failed phase={s} err={s}",
            .{ @tagName(phase), @errorName(err) },
        );
    };
}

fn foregroundSessionReplacementError(
    status: command_contract.ForegroundCommandStatus,
    probe: ForegroundLaunchFailureProbe,
) ?(std.process.ReplaceError || error{CommandLaunchFailed}) {
    switch (status) {
        .exit_code => |code| if (code != foreground_session_replace_failure_exit_code) return null,
        else => return null,
    }
    if (probe.status != .failed) return null;
    return probe.replacement_error orelse error.CommandLaunchFailed;
}

fn executeProcessWithScriptUnisolated(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
) !CollectedProcess {
    const started_ms = io_mod.milliTimestamp();
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    });

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) cleanupChild(&child);

    var script_write = child.stdin orelse return error.SpawnFailed;
    child.stdin = null;
    var script_write_open = true;
    errdefer if (script_write_open) script_write.close(io_mod.getIo());
    try script_write.writeStreamingAll(io_mod.getIo(), script);
    script_write.close(io_mod.getIo());
    script_write_open = false;

    const process_group_id = child.id;
    child_needs_cleanup = false;
    const collected = try collectSpawnedProcess(
        scratch,
        &child,
        &output,
        cfg,
        null,
        process_group_id,
        .process_group,
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());

    return finishCollectedProcess(
        &output,
        collected.status,
        duration_ms,
        collected.source,
    );
}

fn streamPreviewLimit(max_command_output_bytes: usize) usize {
    if (max_command_output_bytes == 0) return 0;
    return @max(@as(usize, 1), max_command_output_bytes / 2);
}

fn createCommandArtifact(
    alloc: Allocator,
    capability: ?*session_child_store.SessionChildCapability,
    preferred_dir: ?[]const u8,
) !CommandArtifact {
    if (capability) |managed| {
        return createManagedCommandArtifact(alloc, managed);
    }
    if (preferred_dir) |dir| {
        if (createCommandArtifactInDir(alloc, dir)) |artifact| {
            return artifact;
        } else |err| {
            debug_trace.logf("core", "command artifact preferred dir failed dir={s} err={s}", .{ dir, @errorName(err) });
        }
    }

    const fallback_dir = try fallbackCommandArtifactDir(alloc);
    defer alloc.free(fallback_dir);
    return createCommandArtifactInDir(alloc, fallback_dir);
}

fn createManagedCommandArtifact(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !CommandArtifact {
    const stem = try std.fmt.allocPrint(
        alloc,
        "{s}{d}-{d}",
        .{
            command_artifact_file_prefix,
            io_mod.milliTimestamp(),
            io_mod.nanoTimestamp(),
        },
    );
    defer alloc.free(stem);
    const output_name = try artifactName(
        alloc,
        stem,
        command_artifact_log_suffix,
    );
    defer alloc.free(output_name);
    const stdout_name = try artifactName(
        alloc,
        stem,
        command_artifact_stdout_suffix,
    );
    defer alloc.free(stdout_name);
    const stderr_name = try artifactName(
        alloc,
        stem,
        command_artifact_stderr_suffix,
    );
    defer alloc.free(stderr_name);

    var output = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        output_name,
    );
    errdefer {
        output.deinit();
        capability.delete(.command_artifacts, output_name) catch {};
    }
    var stdout = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        stdout_name,
    );
    errdefer {
        stdout.deinit();
        capability.delete(.command_artifacts, stdout_name) catch {};
    }
    var stderr = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        stderr_name,
    );
    errdefer {
        stderr.deinit();
        capability.delete(.command_artifacts, stderr_name) catch {};
    }
    const output_file = try alloc.dupe(u8, output.displayPath().?);
    errdefer alloc.free(output_file);
    const stdout_file = try alloc.dupe(u8, stdout.displayPath().?);
    errdefer alloc.free(stdout_file);
    const stderr_file = try alloc.dupe(u8, stderr.displayPath().?);
    errdefer alloc.free(stderr_file);

    return .{
        .output_file = output_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .output = .{ .managed = output },
        .stdout = .{ .managed = stdout },
        .stderr = .{ .managed = stderr },
        .managed_capability = capability,
    };
}

fn createCommandArtifactInDir(alloc: Allocator, dir: []const u8) !CommandArtifact {
    try config_runtime.makeAbsolutePath(dir);

    const stem = try std.fmt.allocPrint(
        alloc,
        "{s}{d}-{d}",
        .{ command_artifact_file_prefix, io_mod.milliTimestamp(), io_mod.nanoTimestamp() },
    );
    defer alloc.free(stem);

    const output_file = try artifactPath(alloc, dir, stem, command_artifact_log_suffix);
    errdefer alloc.free(output_file);
    const stdout_file = try artifactPath(alloc, dir, stem, command_artifact_stdout_suffix);
    errdefer alloc.free(stdout_file);
    const stderr_file = try artifactPath(alloc, dir, stem, command_artifact_stderr_suffix);
    errdefer alloc.free(stderr_file);

    const zio = io_mod.getIo();
    var output = try std.Io.Dir.createFileAbsolute(zio, output_file, .{ .truncate = true });
    errdefer output.close(zio);
    var stdout = try std.Io.Dir.createFileAbsolute(zio, stdout_file, .{ .truncate = true });
    errdefer stdout.close(zio);
    var stderr = try std.Io.Dir.createFileAbsolute(zio, stderr_file, .{ .truncate = true });
    errdefer stderr.close(zio);

    return .{
        .output_file = output_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .output = .{ .external = output },
        .stdout = .{ .external = stdout },
        .stderr = .{ .external = stderr },
    };
}

fn artifactName(
    alloc: Allocator,
    stem: []const u8,
    suffix: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
}

fn artifactPath(alloc: Allocator, dir: []const u8, stem: []const u8, suffix: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
    defer alloc.free(name);
    return std.fs.path.join(alloc, &.{ dir, name });
}

fn fallbackCommandArtifactDir(alloc: Allocator) ![]u8 {
    const temp_root = io_mod.getenv("TMPDIR") orelse "/tmp";
    const pid_text = try std.fmt.allocPrint(alloc, "{d}", .{currentProcessId()});
    defer alloc.free(pid_text);
    return std.fs.path.join(alloc, &.{ temp_root, command_artifact_fallback_dir_name, pid_text });
}

fn currentProcessId() u64 {
    return @intCast(std.c.getpid());
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    return if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;
}

fn executeRawBash(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    return executeRawBashWithResultCommand(
        alloc,
        scratch,
        cfg,
        command,
        command,
        cwd,
    );
}

fn executeRawBashWithResultCommand(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    execution_command: []const u8,
    result_command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    if (builtin.os.tag == .windows) {
        const argv = [_][]const u8{ "cmd", "/C", execution_command };
        const result = try executeProcess(scratch, cfg, &argv, cwd);
        return formatCollectedOutput(alloc, result_command, cwd, result);
    }

    const argv = [_][]const u8{
        "sh",
        "-lc",
        script_from_stdin_launcher,
    };
    const result = try executeProcessWithScript(
        scratch,
        cfg,
        &argv,
        cwd,
        execution_command,
    );
    return formatCollectedOutput(alloc, result_command, cwd, result);
}

fn executeRawInvocation(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    command: []const u8,
    cwd: []const u8,
    invocation: *const shell_resolver.Invocation,
) !command_contract.RunCommandResult {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.InvalidCommandEnvironment;
    }
    const result = try executeProcessWithScript(
        scratch,
        cfg,
        invocation.argv(),
        cwd,
        "",
    );
    return formatCollectedOutput(alloc, command, cwd, result);
}

fn formatExitOutput(alloc: Allocator, command: []const u8, cwd: []const u8, exit_code: i64, stdout_raw: []const u8, stderr_raw: []const u8, duration_ms: ?u64) !command_contract.RunCommandResult {
    return command_contract.formatForegroundCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = .{ .exit_code = exit_code },
        .stdout_display = stdout_raw,
        .stderr_display = stderr_raw,
        .stdout_bytes = stdout_raw.len,
        .stderr_bytes = stderr_raw.len,
        .duration_ms = duration_ms,
    });
}

fn formatOutput(alloc: Allocator, command: []const u8, cwd: []const u8, term: std.process.Child.Term, stdout_raw: []const u8, stderr_raw: []const u8, duration_ms: ?u64) !command_contract.RunCommandResult {
    return formatOutputWithStatus(
        alloc,
        command,
        cwd,
        foregroundCommandStatusFromTerm(term),
        stdout_raw,
        stderr_raw,
        duration_ms,
    );
}

fn formatOutputWithStatus(
    alloc: Allocator,
    command: []const u8,
    cwd: []const u8,
    status: command_contract.ForegroundCommandStatus,
    stdout_raw: []const u8,
    stderr_raw: []const u8,
    duration_ms: ?u64,
) !command_contract.RunCommandResult {
    return command_contract.formatForegroundCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = status,
        .stdout_display = stdout_raw,
        .stderr_display = stderr_raw,
        .stdout_bytes = stdout_raw.len,
        .stderr_bytes = stderr_raw.len,
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

fn formatCollectedOutput(alloc: Allocator, command: []const u8, cwd: []const u8, result: CollectedProcess) !command_contract.RunCommandResult {
    return formatCollectedOutputValue(alloc, command, cwd, result) catch |err| {
        if (!result.cancelled) return err;
        debug_trace.logf("core", "cancelled command result formatting failed err={s}", .{@errorName(err)});
        return error.Cancelled;
    };
}

fn formatCollectedOutputValue(alloc: Allocator, command: []const u8, cwd: []const u8, result: CollectedProcess) !command_contract.RunCommandResult {
    if (result.output_file == null) return formatOutputWithStatus(
        alloc,
        command,
        cwd,
        result.status,
        result.stdout,
        result.stderr,
        result.duration_ms,
    );

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try command_contract.writeForegroundStatusLine(&out.writer, result.status);
    try out.writer.print("truncated={s}\n", .{if (result.truncated) "true" else "false"});
    try out.writer.print("stdout_bytes={d}\n", .{result.stdout_bytes});
    try out.writer.print("stderr_bytes={d}\n", .{result.stderr_bytes});
    if (result.output_file) |path| try out.writer.print("output_file={s}\n", .{path});
    if (result.stdout_file) |path| try out.writer.print("stdout_file={s}\n", .{path});
    if (result.stderr_file) |path| try out.writer.print("stderr_file={s}\n", .{path});
    if (result.truncated) {
        try writePreviewEnvelope(alloc, &out.writer, "stdout", result.stdout_preview);
        try writePreviewEnvelope(alloc, &out.writer, "stderr", result.stderr_preview);
    }
    const output = try out.toOwnedSlice();
    const status = command_contract.projectForegroundStatus(result.status);
    return .{
        .output = output,
        .cancelled = result.cancelled,
        .command_result = .{ .foreground = .{
            .command = command,
            .cwd = cwd,
            .exit_code = status.exit_code,
            .signal = status.signal,
            .termination_indeterminate = status.termination_indeterminate,
            .duration_ms = result.duration_ms,
            .stdout_bytes = result.stdout_bytes,
            .stderr_bytes = result.stderr_bytes,
            .truncated = result.truncated,
            .output_file = metadataField(output, "output_file="),
            .stdout_file = metadataField(output, "stdout_file="),
            .stderr_file = metadataField(output, "stderr_file="),
        } },
    };
}

fn writePreviewEnvelope(alloc: Allocator, writer: *std.Io.Writer, label: []const u8, preview: StreamPreviewSnapshot) !void {
    if (preview.total_bytes == 0) return;

    try writer.print("<{s}>\n", .{label});
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    if (preview.total_bytes <= preview.max_bytes) {
        var full: std.Io.Writer.Allocating = .init(scratch);
        defer full.deinit();
        try full.writer.writeAll(preview.head);
        const overlap = if (preview.head.len + preview.tail.len > preview.total_bytes)
            preview.head.len + preview.tail.len - preview.total_bytes
        else
            0;
        if (preview.tail.len > overlap) try full.writer.writeAll(preview.tail[overlap..]);
        const safe = try text_utils.sanitizeModelText(scratch, full.writer.buffered());
        try writer.writeAll(safe);
        if (!std.mem.endsWith(u8, safe, "\n")) try writer.writeByte('\n');
        try writer.print("</{s}>\n", .{label});
        return;
    }

    const safe_head = try text_utils.sanitizeModelText(scratch, preview.head);
    const safe_tail = try text_utils.sanitizeModelText(scratch, preview.tail);
    const omitted = preview.total_bytes - preview.max_bytes;
    if (safe_head.len > 0) {
        try writer.writeAll(safe_head);
        if (!std.mem.endsWith(u8, safe_head, "\n")) try writer.writeByte('\n');
    }
    try writer.print("[... {d} bytes truncated ...]\n", .{omitted});
    if (safe_tail.len > 0) {
        try writer.writeAll(safe_tail);
        if (!std.mem.endsWith(u8, safe_tail, "\n")) try writer.writeByte('\n');
    }
    try writer.print("</{s}>\n", .{label});
}

const TerminationSource = enum {
    natural,
    cancelled,
    timed_out,
};

fn reconcileForegroundTerminationSource(
    source: TerminationSource,
    deadline_ms: ?i64,
    now_ms: i64,
) TerminationSource {
    if (source != .natural) return source;
    const deadline = deadline_ms orelse return .natural;
    return if (now_ms >= deadline) .timed_out else .natural;
}

const TerminationProtocol = enum {
    process_group,
    foreground_supervisor,
};

const TerminationIntent = enum {
    cooperative,
    force,
};

fn pending_termination_source(
    protocol: TerminationProtocol,
    cancel_requested: bool,
    deadline_ms: ?i64,
    now_ms: i64,
) TerminationSource {
    if (protocol == .foreground_supervisor) {
        if (foreground_supervisor_fallback_deadline_ms(deadline_ms)) |fallback_deadline_ms| {
            if (now_ms >= fallback_deadline_ms) return .timed_out;
        }
    }
    if (cancel_requested) return .cancelled;
    const deadline = deadline_ms orelse return .natural;
    return if (now_ms >= deadline) .timed_out else .natural;
}

const TerminationSignalPlan = struct {
    scope: enum { process_group, supervisor },
    signal: std.posix.SIG,
};

fn terminationSignalPlan(
    protocol: TerminationProtocol,
    intent: TerminationIntent,
) TerminationSignalPlan {
    return switch (protocol) {
        .process_group => .{
            .scope = .process_group,
            .signal = if (intent == .force) std.posix.SIG.KILL else std.posix.SIG.TERM,
        },
        .foreground_supervisor => switch (intent) {
            .cooperative => .{
                .scope = .process_group,
                .signal = std.posix.SIG.TERM,
            },
            .force => .{
                .scope = .supervisor,
                .signal = foreground_session_force_signal,
            },
        },
    };
}

const OutputChunkEmitter = struct {
    stdout_pending: std.ArrayList(u8) = .empty,
    stderr_pending: std.ArrayList(u8) = .empty,

    fn deinit(self: *@This(), arena: Allocator) void {
        self.stdout_pending.deinit(arena);
        self.stderr_pending.deinit(arena);
    }

    fn append(
        self: *@This(),
        arena: Allocator,
        output: *OutputCollector,
        stream: CommandOutputStream,
        bytes: []const u8,
        cfg: Config,
    ) !void {
        try output.append(stream, bytes);
        try emitAcceptedOutputChunk(cfg, stream, bytes);
        try emitPending(arena, self.pendingFor(stream), stream, bytes, cfg, false);
    }

    fn flush(self: *@This(), arena: Allocator, cfg: Config) !void {
        try emitPending(arena, &self.stdout_pending, .stdout, "", cfg, true);
        try emitPending(arena, &self.stderr_pending, .stderr, "", cfg, true);
    }

    fn pendingFor(self: *@This(), stream: CommandOutputStream) *std.ArrayList(u8) {
        return switch (stream) {
            .stdout => &self.stdout_pending,
            .stderr => &self.stderr_pending,
        };
    }

    fn emitPending(
        arena: Allocator,
        pending: *std.ArrayList(u8),
        stream: CommandOutputStream,
        new_bytes: []const u8,
        cfg: Config,
        flush_remainder: bool,
    ) !void {
        const ctx = cfg.output_chunk_ctx orelse return;
        const callback = cfg.on_output_chunk orelse return;
        if (new_bytes.len > 0) try pending.appendSlice(arena, new_bytes);

        while (std.mem.findScalar(u8, pending.items, '\n')) |newline_index| {
            const line = pending.items[0 .. newline_index + 1];
            try emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, line, cfg.callback_projection);

            const remaining = pending.items.len - (newline_index + 1);
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[newline_index + 1 ..]);
            pending.items.len = remaining;
        }

        if (!flush_remainder and pending.items.len >= pending_output_flush_bytes) {
            try emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, pending.items, cfg.callback_projection);
            pending.clearRetainingCapacity();
        }

        if (flush_remainder and pending.items.len > 0) {
            try emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, pending.items, cfg.callback_projection);
            pending.clearRetainingCapacity();
        }
    }
};

const ForegroundLaunchFailureProbe = struct {
    const Status = enum {
        matching,
        passthrough,
        failed,
    };

    expected: []const u8,
    status: Status = .matching,
    pending: [foreground_session_replace_failure_marker_bytes]u8 = undefined,
    pending_len: usize = 0,
    error_name: [foreground_session_replace_error_name_bytes]u8 = undefined,
    error_name_len: usize = 0,
    error_name_done: bool = false,
    error_name_invalid: bool = false,
    replacement_error: ?std.process.ReplaceError = null,

    fn init(expected: []const u8) @This() {
        std.debug.assert(expected.len <= foreground_session_replace_failure_marker_bytes);
        return .{ .expected = expected };
    }

    fn append(
        self: *@This(),
        arena: Allocator,
        emitter: *OutputChunkEmitter,
        output: *OutputCollector,
        bytes: []const u8,
        cfg: Config,
    ) !void {
        switch (self.status) {
            .passthrough => return emitter.append(
                arena,
                output,
                .stderr,
                bytes,
                cfg,
            ),
            .failed => return self.appendErrorName(bytes),
            .matching => {},
        }

        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            self.pending[self.pending_len] = bytes[index];
            self.pending_len += 1;

            if (!std.mem.eql(
                u8,
                self.pending[0..self.pending_len],
                self.expected[0..self.pending_len],
            )) {
                self.status = .passthrough;
                try emitter.append(
                    arena,
                    output,
                    .stderr,
                    self.pending[0..self.pending_len],
                    cfg,
                );
                if (index + 1 < bytes.len) {
                    try emitter.append(
                        arena,
                        output,
                        .stderr,
                        bytes[index + 1 ..],
                        cfg,
                    );
                }
                return;
            }
            if (self.pending_len == self.expected.len) {
                self.status = .failed;
                if (index + 1 < bytes.len) {
                    self.appendErrorName(bytes[index + 1 ..]);
                }
                return;
            }
        }
    }

    fn appendErrorName(self: *@This(), bytes: []const u8) void {
        if (self.error_name_done) return;
        for (bytes) |byte| {
            if (byte == '\n') {
                self.error_name_done = true;
                if (!self.error_name_invalid) {
                    self.replacement_error = parseReplaceError(self.error_name[0..self.error_name_len]);
                }
                return;
            }
            if (self.error_name_len == self.error_name.len) {
                self.error_name_invalid = true;
                continue;
            }
            self.error_name[self.error_name_len] = byte;
            self.error_name_len += 1;
        }
    }

    fn flush(
        self: *@This(),
        arena: Allocator,
        emitter: *OutputChunkEmitter,
        output: *OutputCollector,
        cfg: Config,
    ) !void {
        if (self.status != .matching or self.pending_len == 0) return;
        self.status = .passthrough;
        try emitter.append(
            arena,
            output,
            .stderr,
            self.pending[0..self.pending_len],
            cfg,
        );
    }
};

fn parseReplaceError(name: []const u8) ?std.process.ReplaceError {
    inline for (std.meta.fields(std.process.ReplaceError)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @field(std.process.ReplaceError, field.name);
        }
    }
    return null;
}

const ProcessObserver = struct {
    waiter: ChildWaiter,
    process_id: std.process.Child.Id,
    stdout: std.Io.File,
    stderr: std.Io.File,
    detached_pipes: bool = false,

    fn init(child: *std.process.Child) !ProcessObserver {
        const process_id = child.id orelse return error.SpawnFailed;
        const stdout = child.stdout orelse return error.SpawnFailed;
        const stderr = child.stderr orelse return error.SpawnFailed;
        const detached_pipes = comptime builtin.os.tag != .windows and
            builtin.os.tag != .wasi;
        if (detached_pipes) {
            child.stdout = null;
            child.stderr = null;
        }
        return .{
            .waiter = ChildWaiter.init(child),
            .process_id = process_id,
            .stdout = stdout,
            .stderr = stderr,
            .detached_pipes = detached_pipes,
        };
    }

    fn deinit(self: *ProcessObserver) void {
        if (self.detached_pipes) {
            self.stdout.close(self.waiter.io);
            self.stderr.close(self.waiter.io);
        }
        self.* = undefined;
    }

    fn start(self: *ProcessObserver) !void {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        try self.waiter.start();
    }

    fn observe(self: *ProcessObserver) ?command_contract.ForegroundCommandStatus {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
        if (!self.waiter.isReady()) return null;
        const term = self.waiter.awaitReady() catch |err| {
            return indeterminateStatus(err);
        };
        return statusFromTerm(term);
    }

    fn awaitTermination(
        self: *ProcessObserver,
        source: TerminationSource,
    ) !command_contract.ForegroundCommandStatus {
        if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            self.waiter.awaitDiscard();
            return self.observe().?;
        }
        const term = self.waiter.child.wait(self.waiter.io) catch |err| {
            return switch (source) {
                .natural => blk: {
                    break :blk indeterminateStatus(err);
                },
                .cancelled, .timed_out => mapTerminationError(
                    source,
                    null,
                    "process wait",
                    err,
                ),
            };
        };
        return statusFromTerm(term);
    }

    fn statusFromTerm(
        term: std.process.Child.Term,
    ) command_contract.ForegroundCommandStatus {
        if (io_mod.getenv("FX_COMMAND_TEST_INDETERMINATE_AFTER_EXIT") != null) {
            debug_trace.logf(
                "core",
                "command termination became indeterminate reason=injected_after_exit",
                .{},
            );
            return .indeterminate;
        }
        return foregroundCommandStatusFromTerm(term);
    }

    fn indeterminateStatus(
        err: anyerror,
    ) command_contract.ForegroundCommandStatus {
        debug_trace.logf(
            "core",
            "command termination became indeterminate err={s}",
            .{@errorName(err)},
        );
        return .indeterminate;
    }

    fn signal(
        self: *ProcessObserver,
        process_group_id: ?std.posix.pid_t,
        protocol: TerminationProtocol,
        intent: TerminationIntent,
    ) !void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            self.waiter.child.kill(self.waiter.io);
            return;
        }
        const target_pid = process_group_id orelse self.process_id;
        const plan = terminationSignalPlan(protocol, intent);
        return switch (plan.scope) {
            .process_group => signalProcessGroup(target_pid, plan.signal),
            .supervisor => signalProcess(target_pid, plan.signal),
        };
    }

    fn abort(self: *ProcessObserver, process_group_id: ?std.posix.pid_t) void {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            cleanupChild(self.waiter.child);
            return;
        }
        if (self.waiter.isReady()) {
            self.waiter.awaitDiscard();
            return;
        }
        const pid = process_group_id orelse self.process_id;
        signalProcessGroup(pid, std.posix.SIG.KILL) catch |err| {
            debug_trace.logf(
                "core",
                "command observer cleanup kill failed err={s}",
                .{@errorName(err)},
            );
        };
        self.waiter.awaitDiscard();
    }
};

fn collectOutput(
    arena: Allocator,
    observer: *ProcessObserver,
    output: *OutputCollector,
    cfg: Config,
    source: *TerminationSource,
    launch_failure_probe: ?*ForegroundLaunchFailureProbe,
    process_group_id: ?std.posix.pid_t,
    termination_protocol: TerminationProtocol,
    leader_status: *?command_contract.ForegroundCommandStatus,
) !TerminationSource {
    const zio = io_mod.getIo();
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(arena, zio, multi_reader_buffer.toStreams(), &.{ observer.stdout, observer.stderr });
    defer multi_reader.deinit();

    const stdout_r = multi_reader.reader(0);
    const stderr_r = multi_reader.reader(1);

    var emitter: OutputChunkEmitter = .{};
    defer emitter.deinit(arena);

    const started_ms = ExecutionControl.init(cfg).started_ms;
    var signal_started_ms: ?i64 = null;
    var force_kill_sent = false;
    var streams_finished = false;

    while (true) {
        try updateTerminationSignal(
            observer,
            process_group_id,
            termination_protocol,
            cfg,
            started_ms,
            source,
            &signal_started_ms,
            &force_kill_sent,
        );
        if (leader_status.* == null) {
            if (observer.observe()) |status| {
                leader_status.* = status;
                if (process_group_id) |pid| {
                    if (source.* == .natural) {
                        terminateRemainingProcessGroup(pid);
                        debug_trace.logf(
                            "core",
                            "captured command leader completed; remaining process group terminated",
                            .{},
                        );
                    } else {
                        debug_trace.logf(
                            "core",
                            "captured command leader completed during {s}; termination cleanup continuing",
                            .{@tagName(source.*)},
                        );
                    }
                }
            }
        }

        if (streams_finished) {
            if (source.* == .natural or
                signal_started_ms == null or
                force_kill_sent or
                !remainingProcessGroupAlive(process_group_id))
            {
                break;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        const keep_reading = if (multi_reader.fill(4096, .{ .duration = .{ .raw = .{ .nanoseconds = command_output_poll_ms * std.time.ns_per_ms }, .clock = .awake } }))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            error.Timeout => true,
            else => |e| return e,
        };

        const stdout_buf = stdout_r.buffered();
        const stderr_buf = stderr_r.buffered();
        if (stdout_buf.len > 0) {
            try emitter.append(arena, output, .stdout, stdout_buf, cfg);
            stdout_r.tossBuffered();
        }
        if (stderr_buf.len > 0) {
            if (launch_failure_probe) |probe| {
                try probe.append(arena, &emitter, output, stderr_buf, cfg);
            } else {
                try emitter.append(arena, output, .stderr, stderr_buf, cfg);
            }
            stderr_r.tossBuffered();
        }

        if (!keep_reading) {
            streams_finished = true;
            if (source.* == .natural or
                signal_started_ms == null or
                force_kill_sent or
                !remainingProcessGroupAlive(process_group_id))
            {
                break;
            }
        }
    }

    if (launch_failure_probe) |probe| {
        try probe.flush(arena, &emitter, output, cfg);
    }
    try emitter.flush(arena, cfg);
    return source.*;
}

fn collectOutputForProcess(
    arena: Allocator,
    observer: *ProcessObserver,
    output: *OutputCollector,
    cfg: Config,
    launch_failure_probe: ?*ForegroundLaunchFailureProbe,
    process_group_id: ?std.posix.pid_t,
    termination_protocol: TerminationProtocol,
    leader_status: *?command_contract.ForegroundCommandStatus,
) !TerminationSource {
    var source: TerminationSource = .natural;
    return collectOutput(
        arena,
        observer,
        output,
        cfg,
        &source,
        launch_failure_probe,
        process_group_id,
        termination_protocol,
        leader_status,
    ) catch |err|
        return mapTerminationError(source, cfg.cancel_flag, "output collection", err);
}

fn waitForCollectedProcess(
    observer: *ProcessObserver,
    source: TerminationSource,
    process_group_id: ?std.posix.pid_t,
    leader_status: ?command_contract.ForegroundCommandStatus,
) !command_contract.ForegroundCommandStatus {
    if (leader_status) |status| {
        if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
            observer.waiter.awaitDiscard();
        }
        return status;
    }
    const status = try observer.awaitTermination(source);
    if (process_group_id) |pid| {
        terminateRemainingProcessGroup(pid);
    }
    return status;
}

const CollectedTermination = struct {
    source: TerminationSource,
    status: command_contract.ForegroundCommandStatus,
};

fn collectSpawnedProcess(
    arena: Allocator,
    child: *std.process.Child,
    output: *OutputCollector,
    cfg: Config,
    launch_failure_probe: ?*ForegroundLaunchFailureProbe,
    process_group_id: ?std.posix.pid_t,
    termination_protocol: TerminationProtocol,
) !CollectedTermination {
    var observer = ProcessObserver.init(child) catch |err| {
        cleanupChild(child);
        return err;
    };
    defer observer.deinit();
    observer.start() catch |err| {
        debug_trace.logf(
            "core",
            "command wait authority unavailable after spawn err={s}",
            .{@errorName(err)},
        );
        cleanupChild(child);
        return .{
            .source = .natural,
            .status = .indeterminate,
        };
    };

    var wait_pending = true;
    defer if (wait_pending) observer.abort(process_group_id);

    var leader_status: ?command_contract.ForegroundCommandStatus = null;
    const source = try collectOutputForProcess(
        arena,
        &observer,
        output,
        cfg,
        launch_failure_probe,
        process_group_id,
        termination_protocol,
        &leader_status,
    );
    const status = try waitForCollectedProcess(
        &observer,
        source,
        process_group_id,
        leader_status,
    );
    wait_pending = false;
    return .{ .source = source, .status = status };
}

fn mapTerminationError(
    source: TerminationSource,
    cancel_flag: ?*std.atomic.Value(bool),
    phase: []const u8,
    err: anyerror,
) anyerror {
    const effective_source: TerminationSource = if (source == .natural and cancelRequested(cancel_flag))
        .cancelled
    else
        source;
    return switch (effective_source) {
        .natural => err,
        .cancelled => blk: {
            debug_trace.logf("core", "cancelled command {s} failed err={s}", .{ phase, @errorName(err) });
            break :blk error.Cancelled;
        },
        .timed_out => blk: {
            debug_trace.logf("core", "timed out command {s} failed err={s}", .{ phase, @errorName(err) });
            break :blk error.TimeoutExpired;
        },
    };
}

fn updateTerminationSignal(
    observer: *ProcessObserver,
    process_group_id: ?std.posix.pid_t,
    termination_protocol: TerminationProtocol,
    cfg: Config,
    started_ms: i64,
    source: *TerminationSource,
    signal_started_ms: *?i64,
    force_kill_sent: *bool,
) !void {
    const now_ms = io_mod.milliTimestamp();
    if (signal_started_ms.* == null) {
        const control = ExecutionControl{
            .cancel_flag = cfg.cancel_flag,
            .timeout_ms = cfg.timeout_ms,
            .started_ms = started_ms,
        };
        source.* = pending_termination_source(
            termination_protocol,
            cancelRequested(cfg.cancel_flag),
            control.deadlineMs(),
            now_ms,
        );
        switch (source.*) {
            .natural => {},
            .cancelled => {
                try observer.signal(process_group_id, termination_protocol, .cooperative);
                debug_trace.logf("core", "command termination requested source=cancelled", .{});
                signal_started_ms.* = now_ms;
            },
            .timed_out => {
                try observer.signal(process_group_id, termination_protocol, .force);
                force_kill_sent.* = true;
                debug_trace.logf("core", "command termination requested source=timeout", .{});
                signal_started_ms.* = now_ms;
            },
        }
    }

    if (signal_started_ms.*) |sent_ms| {
        if (!force_kill_sent.* and now_ms - sent_ms >= 800) {
            try observer.signal(process_group_id, termination_protocol, .force);
            debug_trace.logf("core", "command force-killed after termination grace expired", .{});
            force_kill_sent.* = true;
        }
    }
}

fn emitOutputChunk(
    ctx: *anyopaque,
    callback: CommandOutputCallback,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: CommandOutputStream,
    chunk: []const u8,
    projection: CallbackProjection,
) !void {
    if (chunk.len == 0) return;
    if (projection == .model_safe and !text_utils.isModelSafeText(chunk)) return;
    try callback(ctx, lifecycle_id, stream, chunk);
}

fn signalProcess(pid: std.posix.pid_t, signal: std.posix.SIG) !void {
    std.posix.kill(pid, signal) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
}

fn signalProcessGroup(pid: std.posix.pid_t, signal: std.posix.SIG) !void {
    return signalProcess(-pid, signal);
}

fn terminateRemainingProcessGroup(pid: std.posix.pid_t) void {
    signalProcessGroup(pid, std.posix.SIG.KILL) catch |err| {
        debug_trace.logf(
            "core",
            "remaining captured process group cleanup failed err={s}",
            .{@errorName(err)},
        );
    };
}

fn remainingProcessGroupAlive(process_group_id: ?std.posix.pid_t) bool {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;
    const pid = process_group_id orelse return false;
    std.posix.kill(-pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}

fn cleanupChild(child: *std.process.Child) void {
    if (child.id == null) {
        closeChildPipes(child);
        return;
    }
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        child.kill(io_mod.getIo());
        return;
    }
    const pid = child.id orelse return;
    std.posix.kill(-pid, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => debug_trace.logf("core", "command cleanup kill failed err={s}", .{@errorName(err)}),
    };
    _ = child.wait(io_mod.getIo()) catch |err| {
        debug_trace.logf("core", "command cleanup wait failed err={s}", .{@errorName(err)});
    };
}

fn closeChildPipes(child: *std.process.Child) void {
    if (child.stdin) |input| {
        input.close(io_mod.getIo());
        child.stdin = null;
    }
    if (child.stdout) |output| {
        output.close(io_mod.getIo());
        child.stdout = null;
    }
    if (child.stderr) |output| {
        output.close(io_mod.getIo());
        child.stderr = null;
    }
}

const FailFirstCommandArtifactSync = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *FailFirstCommandArtifactSync =
            @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == 1) return error.InjectedParentSyncFailure;
    }
};

const FailCommandArtifactSync = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *FailCommandArtifactSync =
            @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return error.InjectedParentSyncFailure;
    }
};

fn metadataField(output: []const u8, prefix: []const u8) ?[]const u8 {
    var remaining = output;
    while (remaining.len > 0) {
        const line_end = std.mem.findScalar(u8, remaining, '\n') orelse remaining.len;
        const line = remaining[0..line_end];
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
        if (line_end == remaining.len) break;
        remaining = remaining[line_end + 1 ..];
    }
    return null;
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn absoluteFileExists(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

const StreamCapture = struct {
    alloc: Allocator,
    chunks: std.ArrayList([]u8) = .empty,
    streams: std.ArrayList(CommandOutputStream) = .empty,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, stream: CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const owned = try self.alloc.dupe(u8, chunk);
        errdefer self.alloc.free(owned);
        try self.chunks.append(self.alloc, owned);
        errdefer self.chunks.items.len -= 1;
        try self.streams.append(self.alloc, stream);
    }

    fn deinit(self: *@This()) void {
        for (self.chunks.items) |chunk| self.alloc.free(chunk);
        self.chunks.deinit(self.alloc);
        self.streams.deinit(self.alloc);
    }

    fn contains(self: *const @This(), stream: CommandOutputStream, text: []const u8) bool {
        for (self.streams.items, self.chunks.items) |seen_stream, chunk| {
            if (seen_stream == stream and std.mem.eql(u8, chunk, text)) return true;
        }
        return false;
    }
};

const CancelAfterOutput = struct {
    flag: *std.atomic.Value(bool),
    needle: []const u8,
    seen: bool = false,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, _: CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.find(u8, chunk, self.needle) == null) return;
        self.seen = true;
        self.flag.store(true, .seq_cst);
    }
};

const FailOutput = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    needle: ?[]const u8 = null,
    seen: bool = false,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, _: CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.needle) |needle| {
            if (std.mem.find(u8, chunk, needle) == null) return;
        }
        self.seen = true;
        if (self.cancel_flag) |flag| flag.store(true, .seq_cst);
        return error.TestOutputCallbackFailure;
    }
};

const DelayAfterOutput = struct {
    needle: []const u8,
    delay_ns: u64,
    seen: bool = false,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, _: CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.find(u8, chunk, self.needle) == null) return;
        self.seen = true;
        io_mod.sleep(self.delay_ns);
    }
};

fn expectProcessGone(pid: std.posix.pid_t) !void {
    const started_ms = io_mod.milliTimestamp();
    while (true) {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        if (io_mod.milliTimestamp() - started_ms > 1000) {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            return error.TestUnexpectedResult;
        }
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}
