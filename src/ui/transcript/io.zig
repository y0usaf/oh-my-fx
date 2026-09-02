// Host contract:
// - fields: stdout_file, shadow_vt, shadow_vt_alloc, layout,
//   viewport_top_row, installed pre-fx document state
// This module owns the normal frame sink. Exact probes, lifecycle controls,
// titles, crash recovery, and noninteractive output stay with their domain
// owners.

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const record_tape = @import("../../core/workspace/record_tape.zig");
const types = @import("../../core/shared/types.zig");
const terminal_diff = @import("../render_engine/terminal_diff.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;

pub fn enableShadowVt(shell: anytype, alloc: Allocator) !void {
    if (shell.shadow_vt != null) return;
    const cols: u16 = if (shell.layout.cols > 0) shell.layout.cols else 80;
    const rows: u16 = if (shell.layout.rows > 0) shell.layout.rows else 24;
    const grid = try alloc.create(vt_emulator.Grid);
    errdefer alloc.destroy(grid);
    grid.* = try vt_emulator.Grid.init(alloc, cols, rows);
    // The render oracle needs committed cells, not deferred sync state.
    grid.defer_sync_updates = false;
    grid.autowrap = false;
    shell.shadow_vt = grid;
    shell.shadow_vt_alloc = alloc;
}

pub fn disableShadowVt(shell: anytype) void {
    if (shell.shadow_vt) |grid| {
        grid.deinit();
        if (shell.shadow_vt_alloc) |alloc| alloc.destroy(grid);
        shell.shadow_vt = null;
        shell.shadow_vt_alloc = null;
    }
}

pub fn writeFrameBytes(shell: anytype, metrics: *Metrics, bytes: []const u8) terminal_diff.FrameSinkWriteResult {
    var accepted_bytes: usize = 0;
    while (accepted_bytes < bytes.len) {
        const written = shell.stdout_file.writeStreaming(
            io_mod.getIo(),
            &.{},
            &.{bytes[accepted_bytes..]},
            1,
        ) catch |err| return recordPartialFrame(metrics, bytes[0..accepted_bytes], err);
        if (written == 0) return recordPartialFrame(metrics, bytes[0..accepted_bytes], error.NoProgress);
        accepted_bytes += written;
    }
    return recordCompleteFrame(metrics, bytes);
}

fn recordPartialFrame(metrics: *Metrics, accepted: []const u8, err: anyerror) terminal_diff.FrameSinkWriteResult {
    record_tape.recordStdout(accepted);
    metrics.ansi_bytes += accepted.len;
    return .{ .partial = .{
        .accepted_bytes = accepted.len,
        .err = err,
    } };
}

fn recordCompleteFrame(metrics: *Metrics, bytes: []const u8) terminal_diff.FrameSinkWriteResult {
    record_tape.recordStdout(bytes);
    metrics.ansi_bytes += bytes.len;
    return .complete;
}

pub fn frameSinkFrom(ctx: *anyopaque, write_frame: *const fn (*anyopaque, *Metrics, []const u8) terminal_diff.FrameSinkWriteResult) terminal_diff.FrameSink {
    return .{ .ctx = ctx, .write_frame = write_frame };
}
