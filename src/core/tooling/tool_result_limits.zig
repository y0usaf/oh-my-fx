const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

pub const default_max_tool_result_bytes: usize = 64 * 1024;
pub const min_configured_tool_result_bytes: usize = 1024;

pub fn resolveMaxToolResultBytes(setting: ?usize, default_value: usize) usize {
    return setting orelse default_value;
}

pub fn prepareModelOutput(
    alloc: Allocator,
    tool_name: []const u8,
    raw: []const u8,
    max_bytes: usize,
) error{OutOfMemory}![]const u8 {
    var scratch_impl = std.heap.ArenaAllocator.init(alloc);
    defer scratch_impl.deinit();
    const scratch = scratch_impl.allocator();

    const sanitized = try text_utils.sanitizeModelText(scratch, raw);
    const masked = text_utils.maskSecrets(scratch, sanitized) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    const capped = try truncateText(scratch, .{
        .text = masked,
        .max_bytes = max_bytes,
        .marker = try std.fmt.allocPrint(
            scratch,
            "\n... [tool result truncated for {s}: original {d} bytes; cap is {d} bytes]\n",
            .{ tool_name, masked.len, max_bytes },
        ),
        .trace_scope = "tool",
        .trace_label = tool_name,
    });
    return try alloc.dupe(u8, capped);
}

pub const PreparedInlineResult = struct {
    model_output: []u8,
    memory: types.ToolResultMemory,
};

pub fn prepareInlineResult(
    alloc: Allocator,
    tool_name: []const u8,
    raw_output: []const u8,
    max_bytes: usize,
) error{OutOfMemory}!PreparedInlineResult {
    const model_output = @constCast(try prepareModelOutput(
        alloc,
        tool_name,
        raw_output,
        max_bytes,
    ));
    return .{
        .model_output = model_output,
        .memory = .{
            .output_handle = null,
            .preview = null,
            .output_bytes = raw_output.len,
            .stored_output_bytes = model_output.len,
            .truncated = model_output.len < raw_output.len,
        },
    };
}

pub const TruncateOptions = struct {
    text: []const u8,
    max_bytes: usize,
    marker: []const u8,
    trace_scope: []const u8 = "tool",
    trace_label: []const u8 = "result",
};

pub fn truncateText(arena: std.mem.Allocator, opts: TruncateOptions) ![]const u8 {
    if (opts.text.len <= opts.max_bytes) return opts.text;

    const prefix_cap = if (opts.max_bytes > opts.marker.len)
        opts.max_bytes - opts.marker.len
    else
        0;
    const prefix_len = text_utils.utf8BackwardBoundary(opts.text, prefix_cap);

    debug_trace.logf(
        opts.trace_scope,
        "model-facing tool result truncated label={s} original_bytes={d} cap_bytes={d}",
        .{ opts.trace_label, opts.text.len, opts.max_bytes },
    );

    if (prefix_len == 0) return try arena.dupe(u8, opts.marker);
    return try std.mem.concat(arena, u8, &.{ opts.text[0..prefix_len], opts.marker });
}




