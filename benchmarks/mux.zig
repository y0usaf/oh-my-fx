//! Deterministic benchmark for mux terminal ingestion, session switching, and frame building.
//!
//!     zig build run-bench-mux -Doptimize=ReleaseSafe -- 8 1000

const std = @import("std");
const benchmark_exports = @import("benchmark_exports");
const MuxBenchmarkHarness = benchmark_exports.MuxBenchmarkHarness;
const terminal_engine = benchmark_exports.terminal_engine;

const default_sessions: usize = 8;
const default_iterations: usize = 1_000;
const max_iterations: usize = 100_000;
const terminal_cols: u16 = 160;
const terminal_rows: u16 = 48;
const warmup_iterations: usize = 32;
const payload =
    "\x1b[2J\x1b[H" ++
    "fx mux benchmark\r\n" ++
    "\x1b[32mtool output\x1b[0m: indexed workspace and rendered transcript\r\n" ++
    "status: active  tokens: 12345  elapsed: 1.2s\r\n" ++
    "prompt> ";

const Stats = struct {
    p50: u64,
    p95: u64,
    p99: u64,
    maximum: u64,
};

fn nowNs(io: std.Io) i128 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

fn lessThan(_: void, left: u64, right: u64) bool {
    return left < right;
}

fn percentile(sorted: []const u64, numerator: usize, denominator: usize) u64 {
    const index = ((sorted.len - 1) * numerator) / denominator;
    return sorted[index];
}

fn summarize(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, lessThan);
    return .{
        .p50 = percentile(samples, 50, 100),
        .p95 = percentile(samples, 95, 100),
        .p99 = percentile(samples, 99, 100),
        .maximum = samples[samples.len - 1],
    };
}

fn formatNs(nanoseconds: u64, buf: []u8) []const u8 {
    const microseconds = @as(f64, @floatFromInt(nanoseconds)) / 1_000.0;
    const milliseconds = microseconds / 1_000.0;
    if (nanoseconds < 1_000) return std.fmt.bufPrint(buf, "{d}ns", .{nanoseconds}) catch "?";
    if (nanoseconds < 1_000_000) return std.fmt.bufPrint(buf, "{d:.2}us", .{microseconds}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.2}ms", .{milliseconds}) catch "?";
}

fn printStats(out: *std.Io.Writer, name: []const u8, stats: Stats) !void {
    var p50_buf: [32]u8 = undefined;
    var p95_buf: [32]u8 = undefined;
    var p99_buf: [32]u8 = undefined;
    var max_buf: [32]u8 = undefined;
    try out.print("  {s:<18} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
        name,
        formatNs(stats.p50, &p50_buf),
        formatNs(stats.p95, &p95_buf),
        formatNs(stats.p99, &p99_buf),
        formatNs(stats.maximum, &max_buf),
    });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const session_count = if (args.len >= 2)
        try std.fmt.parseInt(usize, std.mem.sliceTo(args[1], 0), 10)
    else
        default_sessions;
    const iterations = if (args.len >= 3)
        try std.fmt.parseInt(usize, std.mem.sliceTo(args[2], 0), 10)
    else
        default_iterations;
    if (session_count == 0 or session_count > 64) return error.InvalidSessionCount;
    if (iterations == 0 or iterations > max_iterations) return error.InvalidIterationCount;

    const alloc = std.heap.c_allocator;
    var harness = try MuxBenchmarkHarness.init(
        alloc,
        session_count,
        terminal_cols,
        terminal_rows,
    );
    defer harness.deinit(alloc);
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(alloc);

    for (0..warmup_iterations) |_| {
        try harness.feedSelected(alloc, payload);
        harness.selectNext();
        try harness.buildSelectedFrame(alloc, &frame);
    }

    var source_grid = try terminal_engine.Grid.init(
        alloc,
        terminal_cols - 27,
        terminal_rows,
    );
    defer source_grid.deinit();
    try source_grid.feed(payload);
    const checkpoint = try source_grid.checkpointPayload(alloc);
    defer alloc.free(checkpoint);

    const direct_samples = try alloc.alloc(u64, iterations);
    defer alloc.free(direct_samples);
    const ingest_samples = try alloc.alloc(u64, iterations);
    defer alloc.free(ingest_samples);
    const switch_samples = try alloc.alloc(u64, iterations);
    defer alloc.free(switch_samples);
    const frame_samples = try alloc.alloc(u64, iterations);
    defer alloc.free(frame_samples);

    var checksum: usize = 0;
    for (0..iterations) |index| {
        var started = nowNs(init.io);
        const restored = try terminal_engine.Grid.restoreCheckpoint(alloc, checkpoint);
        harness.adoptSelectedGrid(restored);
        direct_samples[index] = @intCast(nowNs(init.io) - started);

        started = nowNs(init.io);
        try harness.feedSelected(alloc, payload);
        ingest_samples[index] = @intCast(nowNs(init.io) - started);

        started = nowNs(init.io);
        harness.selectNext();
        switch_samples[index] = @intCast(nowNs(init.io) - started);

        started = nowNs(init.io);
        try harness.buildSelectedFrame(alloc, &frame);
        frame_samples[index] = @intCast(nowNs(init.io) - started);
        checksum +%= frame.items.len;
        std.mem.doNotOptimizeAway(frame.items.ptr);
    }

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(init.io, &stdout_buf);
    const out = &stdout_writer.interface;
    try out.print("=== fx mux benchmark ===\n", .{});
    try out.print("sessions:    {d}\n", .{session_count});
    try out.print("terminal:    {d}x{d}\n", .{ terminal_cols, terminal_rows });
    try out.print("iterations:  {d}\n", .{iterations});
    try out.print("payload:     {d} bytes\n", .{payload.len});
    try out.print("checkpoint:  {d} bytes\n", .{checkpoint.len});
    try out.print("checksum:    {d}\n\n", .{checksum});
    try out.print("  {s:<18} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
        "operation", "p50", "p95", "p99", "max",
    });
    try printStats(out, "direct checkpoint", summarize(direct_samples));
    try printStats(out, "fallback ANSI", summarize(ingest_samples));
    try printStats(out, "session switch", summarize(switch_samples));
    try printStats(out, "frame build", summarize(frame_samples));
    try out.flush();
}
