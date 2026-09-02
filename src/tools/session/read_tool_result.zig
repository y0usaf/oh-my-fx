const std = @import("std");
const result_store = @import("../../core/session/result_store.zig");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const HandleNormalization = struct {
    trimmed: []const u8,
    suffix: []const u8,
};

pub const Input = struct {
    handle: []u8,
    start_byte: usize = 1,
    byte_count: usize = result_store.read_default_bytes,
    query: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.handle);
        if (self.query) |query| alloc.free(query);
        self.* = .{ .handle = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result arguments must be an object") };
    }

    const handle_value = parsed.value.object.get("handle") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result requires string field \"handle\"") };
    };
    if (handle_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"handle\" must be a string") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .handle = try ctx.allocator.dupe(u8, handle_value.string) };
    errdefer input.deinit(ctx.allocator);

    if (parsed.value.object.get("start_byte")) |value| {
        const start_byte = parsePositiveInteger(value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"start_byte\" must be a positive integer") };
        };
        input.start_byte = @intCast(start_byte);
    }
    if (parsed.value.object.get("byte_count")) |value| {
        const byte_count = parsePositiveInteger(value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"byte_count\" must be a positive integer") };
        };
        input.byte_count = @intCast(@min(byte_count, result_store.read_max_bytes));
    }
    if (parsed.value.object.get("query")) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"query\" must be a string") };
        }
        input.query = try ctx.allocator.dupe(u8, value.string);
    }

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn parsePositiveInteger(value: std.json.Value) ?i64 {
    if (value != .integer or value.integer < 1) return null;
    return value.integer;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn classifyHandleNormalization(handle: []const u8) HandleNormalization {
    const trimmed = std.mem.trim(u8, handle, " \t\r\n");
    const suffix = if (std.mem.startsWith(u8, trimmed, "result-") and
        std.mem.findScalar(u8, trimmed, '.') == null)
        ".txt"
    else
        "";
    return .{ .trimmed = trimmed, .suffix = suffix };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const normalization = classifyHandleNormalization(input.handle);
    if (normalization.trimmed.len == 0) return try ctx.allocator.dupe(u8, "read_tool_result field \"handle\" must not be empty");
    if (normalization.suffix.len > 0 or !std.mem.eql(u8, input.handle, normalization.trimmed)) {
        const owned = try std.mem.concat(ctx.allocator, u8, &.{ normalization.trimmed, normalization.suffix });
        ctx.allocator.free(input.handle);
        input.handle = owned;
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    if (ctx.session_child_capability == null and
        ctx.ephemeral_command_replay == null and
        ctx.tool_result_dir == null)
    {
        return .{ .failure = try ctx.allocator.dupe(u8, "No active session tool-result store is available.") };
    }

    const output = readOutput(ctx, input) catch |err| {
        return .{ .failure = try formatReadFailure(ctx.allocator, input.handle, err) };
    };
    return .{ .success = output };
}

fn readOutput(ctx: tool_dispatch.DispatchContext, input: *Input) ![]u8 {
    if (ctx.session_child_capability) |capability| {
        const ordinary = if (input.query) |query|
            result_store.searchByQueryManaged(ctx.allocator, capability, input.handle, query)
        else
            result_store.readByRangeManaged(ctx.allocator, capability, input.handle, input.start_byte, input.byte_count);
        return ordinary catch |err| switch (err) {
            error.ResultHandleNotFound => if (input.query) |query|
                command_replay_store.searchAgentQueryManaged(
                    ctx.allocator,
                    capability,
                    input.handle,
                    query,
                    result_store.read_max_bytes,
                )
            else
                command_replay_store.readAgentPageManaged(
                    ctx.allocator,
                    capability,
                    input.handle,
                    input.start_byte,
                    input.byte_count,
                ),
            else => return err,
        };
    }

    if (ctx.ephemeral_command_replay) |store| {
        return if (input.query) |query|
            command_replay_store.searchAgentQueryEphemeral(
                ctx.allocator,
                store,
                input.handle,
                query,
                result_store.read_max_bytes,
            )
        else
            command_replay_store.readAgentPageEphemeral(
                ctx.allocator,
                store,
                input.handle,
                input.start_byte,
                input.byte_count,
            );
    }

    const dir = ctx.tool_result_dir.?;
    return if (input.query) |query|
        result_store.searchByQuery(ctx.allocator, dir, input.handle, query)
    else
        result_store.readByRange(ctx.allocator, dir, input.handle, input.start_byte, input.byte_count);
}

fn formatReadFailure(alloc: Allocator, handle: []const u8, err: anyerror) ![]u8 {
    if (err == error.ResultHandleNotFound) {
        return std.fmt.allocPrint(
            alloc,
            "read_tool_result failed for handle {s}: ResultHandleNotFound. No exact match exists in the active tool-result store; handles are session-scoped and must be copied exactly from the tool result preview.",
            .{handle},
        );
    }
    return std.fmt.allocPrint(alloc, "read_tool_result failed for handle {s}: {s}", .{ handle, @errorName(err) });
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}
