const std = @import("std");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const bridge_max_result_bytes: usize = 64 * 1024;

extern "fx" fn fx_host_tool_call(
    name_ptr: [*]const u8,
    name_len: usize,
    arguments_ptr: [*]const u8,
    arguments_len: usize,
    output_ptr: [*]u8,
    output_cap: usize,
    status_ptr: *u8,
) i32;

var provider_context: u8 = 0;

pub fn provider() tool_dispatch.HostToolProvider {
    return .{
        .context = @ptrCast(&provider_context),
        .call_fn = call,
    };
}

fn call(
    _: *anyopaque,
    alloc: Allocator,
    name: []const u8,
    arguments_json: []const u8,
    max_result_bytes: usize,
    cancel_flag: ?*std.atomic.Value(bool),
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    const cap = @min(max_result_bytes, bridge_max_result_bytes);
    if (cap == 0) return .{ .failure = try alloc.dupe(u8, "Host tool result limit is zero") };
    const output = try alloc.alloc(u8, cap);
    defer alloc.free(output);
    var status: u8 = 0;
    const raw = fx_host_tool_call(
        name.ptr,
        name.len,
        arguments_json.ptr,
        arguments_json.len,
        output.ptr,
        output.len,
        &status,
    );
    if (raw == -2) {
        if (cancel_flag) |flag| flag.store(true, .seq_cst);
        return error.Cancelled;
    }
    if (raw < 0) {
        return .{ .failure = try alloc.dupe(u8, switch (raw) {
            -3 => "Host tool result exceeded the configured limit",
            else => "Host tool failed",
        }) };
    }
    const len: usize = @intCast(raw);
    if (len > output.len or status > 1) {
        return .{ .failure = try alloc.dupe(u8, "Host tool returned an invalid result") };
    }
    const owned = try alloc.dupe(u8, output[0..len]);
    return if (status == 1) .{ .failure = owned } else .{ .success = owned };
}
