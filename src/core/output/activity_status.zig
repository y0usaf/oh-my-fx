const std = @import("std");
const types = @import("../shared/types.zig");

pub const StreamState = types.StreamState;

const ActivityPart = struct {
    count: usize,
    singular: []const u8,
    plural: []const u8,
    verb: []const u8,
};

fn streamStatusVerb(stream: StreamState) []const u8 {
    return switch (stream.last_activity_kind orelse return "thinking") {
        .list => "listing",
        .read => "reading",
        .write => "writing",
        .edit => "editing",
        .command => "running",
        .subagent => "delegating",
        .open => "opening",
        .ask => "asking",
    };
}

fn markedTurnPhaseLabel(phase: types.TurnPhase) []const u8 {
    return switch (phase) {
        .thinking => "• Thinking",
        .generating => "• Generating",
        .running => "• Running",
    };
}

pub fn buildTurnLabel(buf: []u8, stream: StreamState, now_ms: i64) ?[]const u8 {
    if (stream.last_activity_kind != null) return null;
    var out: std.Io.Writer = .fixed(buf);
    const marked_phase = markedTurnPhaseLabel(stream.phase);
    out.writeAll(marked_phase) catch return marked_phase;
    appendTurnElapsedSuffix(&out, stream, now_ms) catch return out.buffered();
    appendTurnTokenSuffix(&out, stream) catch return out.buffered();
    return out.buffered();
}

pub const activity_blink_half_period_ms: i64 = 500;

/// The instant the turn clock reads. While fx waits on user input the
/// clock is frozen at the moment the wait began, so time spent on an approval
/// or question never counts toward active work.
fn turnClockNow(stream: StreamState, now_ms: i64) i64 {
    if (stream.waiting_since_ms > 0 and stream.waiting_since_ms < now_ms) {
        return stream.waiting_since_ms;
    }
    return now_ms;
}

/// Marker visibility locked to the elapsed counter's clock: on for the first
/// half of every elapsed second, so the marker relights exactly when the
/// seconds digit advances. Steady on while waiting on user input (a frozen
/// clock would otherwise strand the marker dark). Null when no turn is being
/// timed.
pub fn activityBlinkVisible(stream: StreamState, now_ms: i64) ?bool {
    if (stream.turn_started_ms <= 0 or now_ms < stream.turn_started_ms) return null;
    if (stream.waiting_since_ms > 0) return true;
    const half_periods = @divTrunc(now_ms - stream.turn_started_ms, activity_blink_half_period_ms);
    return @mod(half_periods, 2) == 0;
}

fn appendTurnElapsedSuffix(writer: *std.Io.Writer, stream: StreamState, now_ms: i64) !void {
    if (stream.turn_started_ms <= 0 or now_ms < stream.turn_started_ms) return;
    // One displayed second spans exactly one on/off blink period.
    const ms_per_second = 2 * activity_blink_half_period_ms;
    const seconds = @divTrunc(turnClockNow(stream, now_ms) - stream.turn_started_ms, ms_per_second);
    try writer.writeAll(" (");
    try writeElapsed(writer, seconds);
    try writer.writeByte(')');
}

/// Formats an elapsed duration as `1h2m3s`, dropping leading units that are
/// zero so short turns stay `5s` while long ones read `18m0s` instead of a
/// wall of seconds.
fn writeElapsed(writer: *std.Io.Writer, seconds: i64) !void {
    const secs = @mod(seconds, 60);
    const total_minutes = @divTrunc(seconds, 60);
    const mins = @mod(total_minutes, 60);
    const hours = @divTrunc(total_minutes, 60);
    if (hours > 0) {
        try writer.print("{d}h{d}m{d}s", .{ hours, mins, secs });
    } else if (mins > 0) {
        try writer.print("{d}m{d}s", .{ mins, secs });
    } else {
        try writer.print("{d}s", .{secs});
    }
}

/// Tracks whether fx is waiting on user input (approval prompt or question)
/// and keeps the turn clock honest: the clock freezes when the wait
/// begins, and on resume the whole wait is excluded by shifting
/// turn_started_ms forward. Call whenever the waiting state may have changed.
pub fn syncWaitingClock(stream: *StreamState, waiting: bool, now_ms: i64) void {
    if (waiting) {
        if (stream.active and stream.waiting_since_ms == 0) {
            stream.waiting_since_ms = now_ms;
        }
        return;
    }
    if (stream.waiting_since_ms == 0) return;
    const waited = now_ms - stream.waiting_since_ms;
    if (waited > 0 and stream.turn_started_ms > 0) {
        stream.turn_started_ms += waited;
    }
    stream.waiting_since_ms = 0;
}

// Width of the "• " marker every other activity row carries.
const marker_indent = "  ";

// The completed turn summary occupies the same marker column without retaining
// the active phase label or blink.
pub fn buildCompletedTurnLabel(buf: []u8, stream: StreamState) []const u8 {
    const progress = stream.token_progress;
    if (progress.input_tokens == 0 and progress.output_tokens == 0) return marker_indent;
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(marker_indent) catch return marker_indent;
    writeTokenProgress(&out, progress) catch return out.buffered();
    return out.buffered();
}

pub fn buildProgressLabel(buf: []u8, stream: StreamState) ?[]const u8 {
    if (!stream.active) return null;
    return buildThinkingLabelFull(buf, stream);
}

fn buildThinkingLabelFull(buf: []u8, stream: StreamState) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(streamStatusVerb(stream)) catch return streamStatusVerb(stream);

    const parts = activityParts(stream);
    if (!hasActivityParts(&parts)) {
        appendTurnTokenSuffix(&out, stream) catch return out.buffered();
        return out.buffered();
    }

    out.writeAll(" | ") catch return out.buffered();

    var first = true;
    for (parts) |part| {
        if (part.count == 0) continue;
        writeActivityPart(&out, &first, part) catch return out.buffered();
    }

    appendTurnTokenSuffix(&out, stream) catch return out.buffered();
    return out.buffered();
}

fn activityParts(stream: StreamState) [7]ActivityPart {
    return .{
        .{ .count = stream.read_count, .singular = "file", .plural = "files", .verb = "read" },
        .{ .count = stream.list_count, .singular = "directory", .plural = "directories", .verb = "listed" },
        .{ .count = stream.write_count, .singular = "file", .plural = "files", .verb = "wrote" },
        .{ .count = stream.edit_count, .singular = "file", .plural = "files", .verb = "edited" },
        .{ .count = stream.command_count, .singular = "command", .plural = "commands", .verb = "started" },
        .{ .count = stream.subagent_count, .singular = "subagent", .plural = "subagents", .verb = "created" },
        .{ .count = stream.open_count, .singular = "file", .plural = "files", .verb = "opened" },
    };
}

fn hasActivityParts(parts: []const ActivityPart) bool {
    for (parts) |part| {
        if (part.count > 0) return true;
    }
    return false;
}

fn writeActivityPart(writer: *std.Io.Writer, first: *bool, part: ActivityPart) !void {
    if (!first.*) try writer.writeAll(", ");
    first.* = false;
    try writer.print("{d} {s} {s}", .{ part.count, if (part.count == 1) part.singular else part.plural, part.verb });
}

pub fn formatTokenCountCompact(buf: []u8, tokens: u64) []const u8 {
    if (tokens < 1000) return std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "0";

    const whole = tokens / 1000;
    const tenths = (tokens % 1000) / 100;
    if (whole < 10 and tenths > 0) {
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ whole, tenths }) catch "1k";
    }
    return std.fmt.bufPrint(buf, "{d}k", .{whole}) catch "1k";
}

fn writeTokenProgress(writer: *std.Io.Writer, progress: types.TurnTokenProgress) !void {
    var input_buf: [24]u8 = undefined;
    var output_buf: [24]u8 = undefined;
    try writer.print("(↑{s} ↓{s})", .{
        formatTokenCountCompact(&input_buf, progress.input_tokens),
        formatTokenCountCompact(&output_buf, progress.output_tokens),
    });
}

pub fn appendTokenProgressSuffix(writer: *std.Io.Writer, progress: types.TurnTokenProgress) !void {
    if (progress.input_tokens == 0 and progress.output_tokens == 0) return;
    try writer.writeByte(' ');
    try writeTokenProgress(writer, progress);
}

pub fn appendTurnTokenSuffix(writer: *std.Io.Writer, stream: StreamState) !void {
    try appendTokenProgressSuffix(writer, stream.token_progress);
}






















