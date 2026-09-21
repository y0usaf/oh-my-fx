//! Local diagnostic collection used by `/trace`.
//!
//! This is intentionally separate from `debug_trace.zig`: trace is an opt-in,
//! low-level event log, while diagnostics are small in-memory summaries that
//! make the user-initiated trace report useful without requiring tracing.

const network_metrics = @import("network_metrics.zig");
const tool_call_metrics = @import("tool_call_metrics.zig");
const render_metrics = @import("render_metrics.zig");
const compaction_metrics = @import("compaction_metrics.zig");
const model_catalog_metrics = @import("model_catalog_metrics.zig");
const debug_trace = @import("../shared/debug_trace.zig");

pub const NetworkCall = network_metrics.NetworkCall;
pub const NetworkCallKind = network_metrics.NetworkCallKind;
pub const NetworkLifetimeStats = network_metrics.LifetimeStats;
pub const NetworkTurnRollup = network_metrics.TurnRollup;
pub const network_turn_rollup_capacity = network_metrics.turn_rollup_capacity;
pub const ToolCallMetric = tool_call_metrics.ToolCallMetric;
pub const ToolCallRecord = tool_call_metrics.ToolCallRecord;
pub const ToolCallOutcome = tool_call_metrics.ToolCallOutcome;
pub const ToolCallLifetimeStats = tool_call_metrics.LifetimeStats;
pub const network_ring_capacity = network_metrics.ring_capacity;
pub const tool_call_ring_capacity = tool_call_metrics.ring_capacity;
pub const RenderEvent = render_metrics.Event;
pub const render_ring_capacity = render_metrics.ring_capacity;
pub const CompactionEvent = compaction_metrics.Event;
pub const compaction_ring_capacity = compaction_metrics.ring_capacity;
pub const ModelCatalogEvent = model_catalog_metrics.Event;
pub const model_catalog_ring_capacity = model_catalog_metrics.ring_capacity;

const compaction_trace_scope = "context_compaction";

/// Records an informational compaction decision in the always-on ring and
/// forwards the same event to the opt-in debug-trace log unchanged.
pub fn traceCompactionEvent(ctx: debug_trace.TraceContext, comptime kind: compaction_metrics.Kind, comptime fmt: []const u8, args: anytype) void {
    compaction_metrics.record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, false, fmt, args);
    debug_trace.eventf(compaction_trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Same as traceCompactionEvent but marks the event as a failure so the
/// trace report can surface it under Problems.
pub fn traceCompactionFailure(ctx: debug_trace.TraceContext, comptime kind: compaction_metrics.Kind, comptime fmt: []const u8, args: anytype) void {
    compaction_metrics.record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, true, fmt, args);
    debug_trace.eventf(compaction_trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Records a high-cadence compaction evaluation only when it changed the
/// outcome; routine no-op evaluations still reach the debug-trace log but do
/// not evict rarer events from the bounded ring.
pub fn traceCompactionEventIf(record: bool, ctx: debug_trace.TraceContext, comptime kind: compaction_metrics.Kind, comptime fmt: []const u8, args: anytype) void {
    if (record) compaction_metrics.record(kind, ctx.turn_id, ctx.step_id, ctx.subagent_id, false, fmt, args);
    debug_trace.eventf(compaction_trace_scope, @tagName(kind), ctx, fmt, args);
}

/// Records a free-form compaction note (no turn context available at the
/// call site) and forwards it to the debug-trace log unchanged.
pub fn traceCompactionLog(failed: bool, comptime fmt: []const u8, args: anytype) void {
    compaction_metrics.record(.log, 0, 0, 0, failed, fmt, args);
    debug_trace.logf(compaction_trace_scope, fmt, args);
}

pub fn snapshotCompactionEvents(out: []CompactionEvent) usize {
    return compaction_metrics.snapshot(out);
}

pub fn recordRenderEvent(kind: render_metrics.Kind, comptime fmt: []const u8, args: anytype) void {
    render_metrics.record(kind, fmt, args);
}

pub fn snapshotRenderEvents(out: []RenderEvent) usize {
    return render_metrics.snapshot(out);
}

pub fn recordNetworkCall(call: NetworkCall) void {
    network_metrics.record(call);
}

pub fn snapshotNetworkCalls(out: []NetworkCall) usize {
    return network_metrics.snapshot(out);
}

pub fn networkLifetimeStats() NetworkLifetimeStats {
    return network_metrics.lifetimeStats();
}

pub fn snapshotNetworkTurnRollups(out: []NetworkTurnRollup) usize {
    return network_metrics.snapshotTurnRollups(out);
}

pub fn recordToolCall(call: ToolCallMetric) void {
    tool_call_metrics.record(call);
}

/// Records a model-catalog load, capability lookup, or image gate outcome so
/// the /trace report can explain capability rejections without FX_TRACE.
pub fn recordModelCatalogEvent(failed: bool, kind: model_catalog_metrics.Kind, comptime fmt: []const u8, args: anytype) void {
    model_catalog_metrics.record(kind, failed, fmt, args);
}

pub fn snapshotModelCatalogEvents(out: []ModelCatalogEvent) usize {
    return model_catalog_metrics.snapshot(out);
}

pub fn recordToolCallResult(input: ToolCallRecord) void {
    tool_call_metrics.recordResult(input);
}

pub fn snapshotToolCalls(out: []ToolCallMetric) usize {
    return tool_call_metrics.snapshot(out);
}

pub fn toolCallLifetimeStats() ToolCallLifetimeStats {
    return tool_call_metrics.lifetimeStats();
}

pub fn resetSession() void {
    network_metrics.reset();
    tool_call_metrics.reset();
    render_metrics.reset();
    compaction_metrics.reset();
    model_catalog_metrics.reset();
}

pub fn resetForTest() void {
    resetSession();
}
