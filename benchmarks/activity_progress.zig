const std = @import("std");
const TranscriptRuntime = @import("benchmark_exports").TranscriptRuntime;

const Kind = enum { baseline, candidate };
const call_ids = [_][]const u8{ "first", "second" };
const samples_per_batch = 100;
const comparison_batches = 9;
const growth_batches = 5;
const ratio_scale = 1_000;
const max_ratio = 2 * ratio_scale;
const Harness = struct {
    transcript: TranscriptRuntime = .{ .max_retained_transcript_bytes = 256 },
    kind: Kind,
    entry_ids: [call_ids.len]u32 = undefined,

    fn init(alloc: std.mem.Allocator, kind: Kind) !Harness {
        var self = Harness{ .kind = kind };
        errdefer self.transcript.deinit(alloc);
        _ = try self.transcript.appendSemanticNotice(alloc, .{
            .topic = "system",
            .tone = .information,
            .body = "unrelated output retained near the configured transcript cap",
        });
        for (call_ids, 0..) |call_id, index| switch (kind) {
            .baseline => self.entry_ids[index] =
                try self.transcript.appendRawTranscriptEntryClassified(
                    alloc,
                    "● read_file\n",
                    .tool_status,
                ),
            .candidate => _ = try self.transcript.applyToolLifecycle(
                alloc,
                .{ .authoritative_started = .{
                    .id = .{ .turn_id = 1, .call_id = call_id },
                    .reconciles_provisional_call_id = null,
                    .tool_name = "read_file",
                    .activity_kind = .read,
                } },
            ),
        };
        return self;
    }

    fn update(self: *Harness, alloc: std.mem.Allocator, index: usize) !void {
        const slot = index % call_ids.len;
        switch (self.kind) {
            .baseline => {
                if (!try self.transcript.updateRawBytesEntry(
                    alloc,
                    self.entry_ids[slot],
                    "● Reading progress\n",
                )) return error.MissingBaselineTranscriptEntry;
            },
            .candidate => _ = try self.transcript.applyToolLifecycle(
                alloc,
                .{ .progress = .{
                    .id = .{ .turn_id = 1, .call_id = call_ids[slot] },
                    .text = "● Reading progress",
                } },
            ),
        }
    }
};
fn runUpdates(harness: *Harness, alloc: std.mem.Allocator, count: usize) !void {
    for (0..count) |index| try harness.update(alloc, index);
}

fn measureP95(io: std.Io, harness: *Harness, alloc: std.mem.Allocator) !u64 {
    var samples: [samples_per_batch]u64 = undefined;
    for (&samples, 0..) |*sample, index| {
        const started = std.Io.Timestamp.now(io, .awake).nanoseconds;
        try harness.update(alloc, index);
        sample.* = @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - started);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return samples[94];
}

fn ratio(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return std.math.maxInt(u64);
    return @intCast(@min(
        @as(u128, numerator) * ratio_scale / denominator,
        std.math.maxInt(u64),
    ));
}
fn comparisonRatio(io: std.Io, alloc: std.mem.Allocator, reverse: bool) !u64 {
    var baseline = try Harness.init(alloc, .baseline);
    defer baseline.transcript.deinit(alloc);
    var candidate = try Harness.init(alloc, .candidate);
    defer candidate.transcript.deinit(alloc);
    try runUpdates(&baseline, alloc, 200);
    try runUpdates(&candidate, alloc, 200);

    var baseline_p95: u64 = undefined;
    var candidate_p95: u64 = undefined;
    if (reverse) {
        candidate_p95 = try measureP95(io, &candidate, alloc);
        baseline_p95 = try measureP95(io, &baseline, alloc);
    } else {
        baseline_p95 = try measureP95(io, &baseline, alloc);
        candidate_p95 = try measureP95(io, &candidate, alloc);
    }
    return ratio(candidate_p95, baseline_p95);
}
fn growthRatio(io: std.Io, alloc: std.mem.Allocator) !u64 {
    var candidate = try Harness.init(alloc, .candidate);
    defer candidate.transcript.deinit(alloc);
    try runUpdates(&candidate, alloc, 200);
    const initial = try measureP95(io, &candidate, alloc);
    try runUpdates(&candidate, alloc, 5_000);
    return ratio(try measureP95(io, &candidate, alloc), initial);
}

const Gate = struct {
    median: u64,
    breaches: usize,
    passed: bool,
};
fn evaluate(ratios: []u64, breach_quorum: usize) Gate {
    var breaches: usize = 0;
    for (ratios) |value| if (value > max_ratio) {
        breaches += 1;
    };
    std.mem.sort(u64, ratios, {}, std.sort.asc(u64));
    const midpoint = ratios[ratios.len / 2];
    return .{
        .median = midpoint,
        .breaches = breaches,
        .passed = midpoint <= max_ratio or breaches < breach_quorum,
    };
}
pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    var comparison_ratios: [comparison_batches]u64 = undefined;
    for (&comparison_ratios, 0..) |*value, index| {
        value.* = try comparisonRatio(init.io, alloc, index % 2 == 1);
    }
    var growth_ratios: [growth_batches]u64 = undefined;
    for (&growth_ratios) |*value| value.* = try growthRatio(init.io, alloc);
    const comparison = evaluate(&comparison_ratios, 5);
    const growth = evaluate(&growth_ratios, 3);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print(
        "comparison_median_ratio={d}.{d:0>3}x breaches={d}/{d} passed={any}\n" ++
            "growth_median_ratio={d}.{d:0>3}x breaches={d}/{d} passed={any}\n",
        .{
            comparison.median / ratio_scale,
            comparison.median % ratio_scale,
            comparison.breaches,
            comparison_batches,
            comparison.passed,
            growth.median / ratio_scale,
            growth.median % ratio_scale,
            growth.breaches,
            growth_batches,
            growth.passed,
        },
    );
    try writer.interface.flush();
    if (!comparison.passed or !growth.passed) return error.UiActivityProgressRegression;
}

test "benchmark gate handles isolated and repeated timing breaches" {
    var isolated = [_]u64{ 1_000, 1_100, 2_500, 1_050, 1_000 };
    var repeated = [_]u64{ 2_100, 2_200, 1_900, 2_300, 2_400 };
    try std.testing.expect(evaluate(&isolated, 3).passed);
    try std.testing.expect(!evaluate(&repeated, 3).passed);
}
