const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const record_tape = @import("../core/workspace/record_tape.zig");
const shell_runtime = @import("shell_runtime.zig");

pub const EventLoopCallbacks = struct {
    ctx: *anyopaque,
    collect_facts: *const fn (*anyopaque) anyerror!void,
    next_collected_byte: *const fn (*anyopaque) ?u8,
    handle_byte: *const fn (*anyopaque, u8) anyerror!void,
    settle_delivery_epoch: *const fn (*anyopaque) anyerror!void,
    commit_frame: *const fn (*anyopaque) anyerror!void,
    poll_timeout_ms: ?*const fn (*anyopaque, i32) i32 = null,
};

const max_input_reads_per_fact_collection = 32;

fn attemptFinalFrameCommit(callbacks: EventLoopCallbacks, reason: []const u8) void {
    callbacks.commit_frame(callbacks.ctx) catch |err| debug_trace.logf(
        "event_loop",
        "final_frame_commit_failed reason={s} err={s}",
        .{ reason, @errorName(err) },
    );
}

pub const ExitCause = enum {
    requested_exit,
    input_closed,
};

pub fn pump_ready_input(terminal: anytype, should_exit: *bool, callbacks: EventLoopCallbacks) !?ExitCause {
    var buf: [128]u8 = undefined;
    var handled_input = false;

    while (callbacks.next_collected_byte(callbacks.ctx)) |byte| {
        handled_input = true;
        try callbacks.handle_byte(callbacks.ctx, byte);
        if (should_exit.*) return .requested_exit;
    }

    var poll_result = try terminal.pollInput(0);
    var input_reads: usize = 0;

    while (poll_result.readable and input_reads < max_input_reads_per_fact_collection) : (input_reads += 1) {
        const read_len = try terminal.read(&buf);
        if (read_len == 0) {
            if (input_reads > 0) attemptFinalFrameCommit(callbacks, "eof");
            return .input_closed;
        }

        handled_input = true;
        record_tape.recordStdin(buf[0..read_len]);
        for (buf[0..read_len]) |byte| {
            try callbacks.handle_byte(callbacks.ctx, byte);
            if (should_exit.*) return .requested_exit;
        }
        poll_result = try terminal.pollInput(0);
    }

    if (poll_result.readable) {
        try callbacks.commit_frame(callbacks.ctx);
        return null;
    }
    if (poll_result.closed()) {
        if (input_reads > 0) attemptFinalFrameCommit(callbacks, "hangup");
        return .input_closed;
    }

    if (handled_input) {
        try callbacks.settle_delivery_epoch(callbacks.ctx);
        try callbacks.commit_frame(callbacks.ctx);
    }
    return null;
}

pub fn run(terminal: anytype, should_exit: *bool, poll_timeout_ms: i32, callbacks: EventLoopCallbacks) !ExitCause {
    var buf: [128]u8 = undefined;

    while (!should_exit.*) {
        try callbacks.collect_facts(callbacks.ctx);
        if (should_exit.*) return .requested_exit;

        while (callbacks.next_collected_byte(callbacks.ctx)) |byte| {
            try callbacks.handle_byte(callbacks.ctx, byte);
            if (should_exit.*) return .requested_exit;
        }

        const timeout_ms = if (callbacks.poll_timeout_ms) |resolve|
            resolve(callbacks.ctx, poll_timeout_ms)
        else
            poll_timeout_ms;
        var poll_result = try terminal.pollInput(timeout_ms);
        var input_reads: usize = 0;
        while (poll_result.readable and input_reads < max_input_reads_per_fact_collection) : (input_reads += 1) {
            const read_len = try terminal.read(&buf);
            if (read_len == 0) {
                if (input_reads > 0) attemptFinalFrameCommit(callbacks, "eof");
                return .input_closed;
            }

            record_tape.recordStdin(buf[0..read_len]);
            for (buf[0..read_len]) |byte| {
                try callbacks.handle_byte(callbacks.ctx, byte);
                if (should_exit.*) return .requested_exit;
            }
            poll_result = try terminal.pollInput(0);
        }

        if (poll_result.readable) {
            try callbacks.commit_frame(callbacks.ctx);
            continue;
        }
        if (poll_result.closed()) {
            if (input_reads > 0) attemptFinalFrameCommit(callbacks, "hangup");
            return .input_closed;
        }

        try callbacks.settle_delivery_epoch(callbacks.ctx);
        try callbacks.commit_frame(callbacks.ctx);
    }
    return .requested_exit;
}

const EventLoopTestTrace = struct {
    bytes: [8]u8 = undefined,
    len: usize = 0,
    collected: [2]u8 = undefined,
    collected_len: usize = 0,
    collected_index: usize = 0,
    should_exit: *bool,

    fn append(self: *EventLoopTestTrace, byte: u8) void {
        self.bytes[self.len] = byte;
        self.len += 1;
    }
};

fn noCollectedEventLoopByte(_: *anyopaque) ?u8 {
    return null;
}

fn nextCollectedEventLoopByte(ctx: *anyopaque) ?u8 {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    if (trace.collected_index >= trace.collected_len) return null;
    const byte = trace.collected[trace.collected_index];
    trace.collected_index += 1;
    return byte;
}

fn rejectUnexpectedEventLoopByte(_: *anyopaque, _: u8) !void {
    return error.UnexpectedByte;
}

fn rejectUnexpectedEventLoopCommit(_: *anyopaque) !void {
    return error.UnexpectedCommit;
}

fn useLongerPollTimeout(_: *anyopaque, default_timeout_ms: i32) i32 {
    return default_timeout_ms * 2;
}

const EventLoopClosedTerminal = struct {
    poll_result: shell_runtime.PollResult,

    fn pollInput(self: EventLoopClosedTerminal, _: i32) !shell_runtime.PollResult {
        return self.poll_result;
    }

    fn read(_: EventLoopClosedTerminal, _: []u8) !usize {
        return 0;
    }
};
