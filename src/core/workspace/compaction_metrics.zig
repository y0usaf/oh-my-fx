//! Bounded, always-on context-compaction breadcrumbs for the user-initiated
//! /trace report. Records the same events that the `context_compaction`
//! debug-trace scope emits so compaction decisions and failure reasons stay
//! visible even when FX_TRACE is off. Callers supply internal counters, stage
//! and enum names only, never user prompts or tool payloads; the one bounded
//! provider error detail is secret-masked and control-byte neutralized at the
//! capture site before it reaches the ring.
const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const ring_capacity = 64;
const max_detail_bytes = 512;

pub const Kind = enum {
    log,
    failed,
    policy_selected,
    provider_start,
    summary_skipped,
    user_capacity_retry,
    provider_completed,
    summary_cancelled,
    summary_transport_failed,
    summary_incomplete,
    summary_tool_call_rejected,
    summary_truncated,
    summary_invalid_utf8,
    empty_summary_retry,
    summary_empty_exhausted,
    source_checkpointed,
    transaction_failed,
    skipped_no_op,
    capacity_exceeded_at_plan,
    credential_unauthorized,
    candidate_over_capacity,
    committed,
    decision,
    overflow_without_compaction,
    no_compactable_context,
    retention_exhausted,
    retention_forced_zero,
    installed,
    overflow_recovery_incomplete,
    provider_overflow_recovery,
};

pub const Event = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    turn_id: u64 = 0,
    step_id: u64 = 0,
    subagent_id: u64 = 0,
    failed: bool = false,
    kind: Kind = .log,
    detail_len: u16 = 0,
    truncated: bool = false,
    detail_buf: [max_detail_bytes]u8 = [_]u8{0} ** max_detail_bytes,

    pub fn name(self: *const Event) []const u8 {
        return @tagName(self.kind);
    }

    pub fn detail(self: *const Event) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }
};

const Ring = struct {
    events: [ring_capacity]Event = std.mem.zeroes([ring_capacity]Event),
    head: usize = 0,
    stored: usize = 0,
    total: u64 = 0,

    fn append(self: *Ring, event: *const Event) void {
        self.total +|= 1;
        self.events[self.head] = event.*;
        self.events[self.head].sequence = self.total;
        self.head = (self.head + 1) % ring_capacity;
        self.stored = @min(self.stored + 1, ring_capacity);
    }

    fn snapshot(self: *const Ring, out: []Event) usize {
        const count = @min(self.stored, out.len);
        for (out[0..count], 0..) |*event, index| {
            event.* = self.events[(self.head + ring_capacity - count + index) % ring_capacity];
        }
        return count;
    }
};

var mutex: std.Io.Mutex = .init;
// Zero-initialized storage stays in .bss; unused slots are never read.
var ring: Ring = std.mem.zeroes(Ring);

// Keep format specialization at the caller while sharing ring mutation without
// adding another Event-sized stack copy.
pub inline fn record(kind: Kind, turn_id: u64, step_id: u64, subagent_id: u64, failed: bool, comptime fmt: []const u8, args: anytype) void {
    var event: Event = .{
        .timestamp_ms = io_mod.milliTimestamp(),
        .turn_id = turn_id,
        .step_id = step_id,
        .subagent_id = subagent_id,
        .failed = failed,
        .kind = kind,
    };
    var writer: std.Io.Writer = .fixed(&event.detail_buf);
    writer.print(fmt, args) catch {
        event.truncated = true;
    };
    event.detail_len = @intCast(writer.buffered().len);
    append_recorded_event(&event);
}

noinline fn append_recorded_event(event: *const Event) void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.append(event);
}

pub fn snapshot(out: []Event) usize {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return ring.snapshot(out);
}

pub fn reset() void {
    const io = io_mod.getIo();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ring.head = 0;
    ring.stored = 0;
    ring.total = 0;
}

test "compaction diagnostic ring retains the newest events in order" {
    var local: Ring = .{};
    for (0..ring_capacity + 3) |index| {
        local.append(&.{ .timestamp_ms = @intCast(index) });
    }
    var events: [ring_capacity]Event = undefined;
    try std.testing.expectEqual(ring_capacity, local.snapshot(&events));
    try std.testing.expectEqual(@as(u64, 4), events[0].sequence);
    try std.testing.expectEqual(@as(i64, 3), events[0].timestamp_ms);
    try std.testing.expectEqual(@as(u64, ring_capacity + 3), events[ring_capacity - 1].sequence);
    var tail: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), local.snapshot(&tail));
    try std.testing.expectEqual(@as(u64, ring_capacity + 2), tail[0].sequence);
    try std.testing.expectEqual(@as(usize, 0), local.snapshot(&.{}));
}

test "compaction diagnostics stay bounded and reset without file tracing" {
    reset();
    defer reset();
    record(.decision, 7, 3, 0, false, "automatic_threshold tokens={d}/{d}", .{ 279466, 280000 });
    const oversized = [_]u8{'x'} ** (max_detail_bytes + 10);
    record(.retention_exhausted, 7, 4, 0, true, "{s}", .{oversized});
    var events: [2]Event = undefined;
    try std.testing.expectEqual(@as(usize, 2), snapshot(&events));
    try std.testing.expectEqualStrings("decision", events[0].name());
    try std.testing.expectEqualStrings("automatic_threshold tokens=279466/280000", events[0].detail());
    try std.testing.expect(!events[0].failed);
    try std.testing.expectEqual(@as(u64, 7), events[0].turn_id);
    try std.testing.expectEqual(@as(u64, 3), events[0].step_id);
    try std.testing.expectEqualStrings("retention_exhausted", events[1].name());
    try std.testing.expect(events[1].failed);
    try std.testing.expect(events[1].truncated);
    try std.testing.expect(events[1].detail_len <= max_detail_bytes);
    reset();
    try std.testing.expectEqual(@as(usize, 0), snapshot(&events));
    record(.installed, 8, 0, 0, false, "kept_users={d}", .{3});
    try std.testing.expectEqual(@as(usize, 1), snapshot(&events));
    try std.testing.expectEqual(@as(u64, 1), events[0].sequence);
}
