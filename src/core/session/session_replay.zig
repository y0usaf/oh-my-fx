const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");
const session_projection = @import("session_projection.zig");

const Allocator = std.mem.Allocator;
const Identifier = session_event.Identifier;

pub const CommitPosition = struct {
    log_generation: Identifier,
    through_seq: u64,
    through_event_id: Identifier,
    through_event_log_bytes: u64,
};

pub const RecoveryValidation = enum {
    valid,
    invalid,
};

pub const LineRead = struct {
    bytes: []u8,
    next_offset: u64,
};

pub fn readLineAt(
    alloc: Allocator,
    file: std.Io.File,
    offset: u64,
    max_end: u64,
) !?LineRead {
    if (offset >= max_end) return null;
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    var cursor = offset;
    var chunk: [8192]u8 = undefined;
    while (cursor < max_end) {
        const limit = @min(@as(u64, chunk.len), max_end - cursor);
        const count = try file.readPositionalAll(
            io_mod.getIo(),
            chunk[0..@intCast(limit)],
            cursor,
        );
        if (count == 0) {
            if (line.items.len == 0) return null;
            return error.TruncatedEventFrame;
        }
        if (std.mem.findScalar(u8, chunk[0..count], '\n')) |newline| {
            try line.appendSlice(alloc, chunk[0 .. newline + 1]);
            cursor += newline + 1;
            if (line.items.len > session_event.event_frame_max_bytes) {
                return error.EventFrameTooLarge;
            }
            return .{
                .bytes = try line.toOwnedSlice(alloc),
                .next_offset = cursor,
            };
        }
        try line.appendSlice(alloc, chunk[0..count]);
        if (line.items.len > session_event.event_frame_max_bytes) {
            return error.EventFrameTooLarge;
        }
        cursor += count;
    }
    return error.TruncatedEventFrame;
}

pub fn readFirstGeneration(alloc: Allocator, file: std.Io.File) !Identifier {
    const length = try file.length(io_mod.getIo());
    const first = try readLineAt(alloc, file, 0, length) orelse
        return error.InvalidSessionFormat;
    defer alloc.free(first.bytes);
    var envelope = session_event.decodeFrame(alloc, first.bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
    defer envelope.deinit(alloc);
    if (envelope.seq != 1 or envelope.kind() != .session_started) {
        return error.InvalidSessionFormat;
    }
    return envelope.log_generation;
}

pub fn scanCommitPosition(
    alloc: Allocator,
    file: std.Io.File,
    position: CommitPosition,
) !session_projection.EventBoundary {
    var state = try replayBoundary(alloc, file, position);
    state.deinit(alloc);
    return eventBoundary(position);
}

pub fn validateCommitPositionForRecovery(
    alloc: Allocator,
    file: std.Io.File,
    position: CommitPosition,
) !RecoveryValidation {
    var state = replayBoundaryRaw(alloc, file, position) catch |err| switch (err) {
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        error.OutOfMemory, error.ReadFailed => return err,
        else => return .invalid,
    };
    state.deinit(alloc);
    return .valid;
}

pub fn replayBoundary(
    alloc: Allocator,
    file: std.Io.File,
    position: CommitPosition,
) !session_codec.DurableSessionState {
    return replayBoundaryRaw(alloc, file, position) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
}

/// Replays one caller-supplied durable boundary without consulting a commit
/// watermark. It never searches for or selects a different prefix.
pub fn replayExactBoundary(
    alloc: Allocator,
    file: std.Io.File,
    expected_generation: Identifier,
    expected_seq: u64,
    expected_bytes: u64,
) !session_codec.DurableSessionState {
    var replayed = try replayExactPosition(
        alloc,
        file,
        expected_generation,
        expected_seq,
        expected_bytes,
    );
    return replayed.takeState();
}

/// Owns `state`; callers must call `deinit` or transfer it with `takeState`.
pub const ExactReplay = struct {
    state: session_codec.DurableSessionState,
    position: CommitPosition,

    pub fn deinit(self: *ExactReplay, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.* = undefined;
    }

    pub fn takeState(self: *ExactReplay) session_codec.DurableSessionState {
        const state = self.state;
        self.* = undefined;
        return state;
    }
};

inline fn failExactReplay(err: anytype) @TypeOf(err)!ExactReplay {
    return @errorCast(failExactReplayDynamic(err));
}

noinline fn failExactReplayDynamic(err: anyerror) anyerror!ExactReplay {
    return err;
}

pub fn replayExactPosition(
    alloc: Allocator,
    file: std.Io.File,
    expected_generation: Identifier,
    expected_seq: u64,
    expected_bytes: u64,
) !ExactReplay {
    if (expected_bytes == 0 or
        try file.length(io_mod.getIo()) != expected_bytes)
    {
        return failExactReplay(error.InvalidSessionFormat);
    }
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io_mod.getIo(), &file_buffer);
    var limit_buffer: [4096]u8 = undefined;
    var limited = file_reader.interface.limited(
        .limited64(expected_bytes),
        &limit_buffer,
    );
    var reduction = session_event.reduceJsonl(
        alloc,
        &limited.interface,
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        error.UnsupportedEventSchema => return failExactReplay(error.UnsupportedSessionSchema),
        else => return failExactReplay(error.InvalidSessionFormat),
    };
    errdefer reduction.deinit(alloc);
    const through = reduction.through orelse return failExactReplay(error.InvalidSessionFormat);
    if (reduction.truncate_from != null or
        reduction.bytes_consumed != expected_bytes or
        through.byte_offset != expected_bytes or
        through.seq != expected_seq or
        !std.mem.eql(u8, &through.log_generation, &expected_generation))
    {
        return failExactReplay(error.InvalidSessionFormat);
    }
    const state = reduction.state;
    reduction.state = undefined;
    return .{
        .state = state,
        .position = .{
            .log_generation = through.log_generation,
            .through_seq = through.seq,
            .through_event_id = through.event_id,
            .through_event_log_bytes = through.byte_offset,
        },
    };
}

pub fn replayFromCheckpoint(
    alloc: Allocator,
    file: std.Io.File,
    checkpoint: CommitPosition,
    state: session_codec.DurableSessionState,
    position: CommitPosition,
) !session_codec.DurableSessionState {
    return replayRangeRaw(
        alloc,
        file,
        checkpoint,
        state,
        position,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
}

fn replayBoundaryRaw(
    alloc: Allocator,
    file: std.Io.File,
    position: CommitPosition,
) !session_codec.DurableSessionState {
    return replayRangeRaw(alloc, file, null, null, position);
}

fn replayRangeRaw(
    alloc: Allocator,
    file: std.Io.File,
    checkpoint: ?CommitPosition,
    initial: ?session_codec.DurableSessionState,
    position: CommitPosition,
) !session_codec.DurableSessionState {
    var owned_initial = initial;
    errdefer if (owned_initial) |*state| state.deinit(alloc);
    if ((checkpoint == null) != (owned_initial == null) or
        position.through_event_log_bytes == 0)
    {
        return error.InvalidSessionFormat;
    }
    const start_bytes: u64 = if (checkpoint) |start| start.through_event_log_bytes else 0;
    if (checkpoint) |start| {
        if (!std.mem.eql(u8, &start.log_generation, &position.log_generation) or
            start.through_seq > position.through_seq or
            start.through_event_log_bytes > position.through_event_log_bytes)
        {
            return error.InvalidSessionFormat;
        }
        if (start.through_seq == position.through_seq) {
            if (start.through_event_log_bytes != position.through_event_log_bytes or
                !std.mem.eql(u8, &start.through_event_id, &position.through_event_id))
            {
                return error.InvalidSessionFormat;
            }
            const state = owned_initial.?;
            owned_initial = null;
            return state;
        }
    }
    const length = try file.length(io_mod.getIo());
    if (length < position.through_event_log_bytes) return error.InvalidSessionFormat;

    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io_mod.getIo(), &file_buffer);
    if (start_bytes > 0) try file_reader.seekTo(start_bytes);
    var limit_buffer: [4096]u8 = undefined;
    var limited = file_reader.interface.limited(
        .limited64(position.through_event_log_bytes - start_bytes),
        &limit_buffer,
    );
    const start = if (checkpoint) |boundary|
        session_event.ReductionStart{
            .generation = boundary.log_generation,
            .next_seq = std.math.add(u64, boundary.through_seq, 1) catch
                return error.InvalidSessionFormat,
        }
    else
        session_event.ReductionStart{};
    const moved_initial = owned_initial;
    owned_initial = null;
    var reduction = try session_event.reduceJsonlFrom(
        alloc,
        &limited.interface,
        moved_initial,
        start,
    );
    errdefer reduction.deinit(alloc);
    if (reduction.truncate_from != null or
        reduction.bytes_consumed != position.through_event_log_bytes - start_bytes)
    {
        return error.InvalidSessionFormat;
    }
    const through = if (reduction.through) |boundary|
        session_projection.EventBoundary{
            .log_generation = boundary.log_generation,
            .seq = boundary.seq,
            .event_id = boundary.event_id,
            .event_log_bytes = start_bytes + boundary.byte_offset,
            .semantic = true,
        }
    else if (checkpoint) |boundary|
        eventBoundary(boundary)
    else
        return error.InvalidSessionFormat;
    if (through.seq != position.through_seq or
        through.event_log_bytes != position.through_event_log_bytes or
        !std.mem.eql(u8, &through.log_generation, &position.log_generation) or
        !std.mem.eql(u8, &through.event_id, &position.through_event_id))
    {
        return error.InvalidSessionFormat;
    }
    const state = reduction.state;
    reduction.state = undefined;
    return state;
}

fn reduceBoundaryReader(
    alloc: Allocator,
    source: *std.Io.Reader,
) !session_codec.DurableSessionState {
    var reduction = try session_event.reduceJsonl(alloc, source, null);
    errdefer reduction.deinit(alloc);
    if (reduction.truncate_from != null) return error.InvalidSessionFormat;
    const state = reduction.state;
    reduction.state = undefined;
    return state;
}

fn eventBoundary(position: CommitPosition) session_projection.EventBoundary {
    return .{
        .log_generation = position.log_generation,
        .seq = position.through_seq,
        .event_id = position.through_event_id,
        .event_log_bytes = position.through_event_log_bytes,
        .semantic = true,
    };
}
