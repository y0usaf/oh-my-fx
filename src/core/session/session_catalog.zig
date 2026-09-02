const std = @import("std");
const session_display_metadata = @import("session_display_metadata.zig");
const session_store = @import("session_store.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const Scope = enum {
    current_workspace,
    all_workspaces,
};

pub const LoadState = enum {
    loading,
    ready,
    failed,
};

pub const ResumeFailure = enum {
    open_elsewhere,
    being_updated,
    unavailable,
};

pub fn filteredCount(summaries: []const session_store.SessionSummary, query: []const u8) usize {
    var count: usize = 0;
    for (summaries) |summary| {
        if (matchesQuery(summary, query)) count += 1;
    }
    return count;
}

pub fn summaryAt(
    summaries: []const session_store.SessionSummary,
    query: []const u8,
    display_index: usize,
) ?*const session_store.SessionSummary {
    var current: usize = 0;
    for (summaries) |*summary| {
        if (!matchesQuery(summary.*, query)) continue;
        if (current == display_index) return summary;
        current += 1;
    }
    return null;
}

pub fn displayTitle(summary: session_store.SessionSummary) []const u8 {
    return summary.title orelse session_display_metadata.fallback_title;
}

pub fn workspacePath(summary: session_store.SessionSummary) []const u8 {
    return summary.workspace_root orelse summary.origin_workspace_root orelse "(unknown workspace)";
}

pub fn relativeActivityAge(buf: []u8, updated_at_ms: i64, now_ms: i64) []const u8 {
    const delta_ms: i64 = @max(0, now_ms - updated_at_ms);
    if (delta_ms < std.time.ms_per_min) return "just now";
    if (delta_ms < std.time.ms_per_hour) {
        return std.fmt.bufPrint(buf, "{d}m ago", .{@divFloor(delta_ms, std.time.ms_per_min)}) catch "recently";
    }
    if (delta_ms < std.time.ms_per_day) {
        return std.fmt.bufPrint(buf, "{d}h ago", .{@divFloor(delta_ms, std.time.ms_per_hour)}) catch "recently";
    }
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divFloor(delta_ms, std.time.ms_per_day)}) catch "recently";
}

// Same buckets as relativeActivityAge without the " ago" suffix, for tight
// single-line layouts: "now", "5m", "2h", "1d".
pub fn relativeActivityAgeCompact(buf: []u8, updated_at_ms: i64, now_ms: i64) []const u8 {
    const delta_ms: i64 = @max(0, now_ms - updated_at_ms);
    if (delta_ms < std.time.ms_per_min) return "now";
    if (delta_ms < std.time.ms_per_hour) {
        return std.fmt.bufPrint(buf, "{d}m", .{@divFloor(delta_ms, std.time.ms_per_min)}) catch "recently";
    }
    if (delta_ms < std.time.ms_per_day) {
        return std.fmt.bufPrint(buf, "{d}h", .{@divFloor(delta_ms, std.time.ms_per_hour)}) catch "recently";
    }
    return std.fmt.bufPrint(buf, "{d}d", .{@divFloor(delta_ms, std.time.ms_per_day)}) catch "recently";
}

fn matchesQuery(summary: session_store.SessionSummary, query: []const u8) bool {
    const query_text = std.mem.trim(u8, query, " \t\r\n");
    if (query_text.len == 0) return true;
    if (text_utils.containsIgnoreCase(displayTitle(summary), query_text)) return true;
    if (text_utils.containsIgnoreCase(workspacePath(summary), query_text)) return true;
    if (summary.preview) |preview| {
        if (text_utils.containsIgnoreCase(preview, query_text)) return true;
    }
    return false;
}



