const std = @import("std");
const file_mutation_contract = @import("../../core/tooling/file_mutation_contract.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_content_bytes: usize = 4 * 1024 * 1024;

/// Typed input for the core edit_file tool.
pub const Input = struct {
    path: []u8,
    old_string: []u8,
    new_string: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.old_string);
        alloc.free(self.new_string);
        self.* = .{ .path = &.{}, .old_string = &.{}, .new_string = &.{} };
    }
};

/// Decodes edit_file JSON into an owned Input released by ToolInput.deinit.
pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        ctx.allocator,
        args_json,
        .{},
    ) catch {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "edit_file arguments must be valid JSON",
        ) };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "edit_file arguments must be an object",
        ) };
    }

    const path_value = parsed.value.object.get("path") orelse {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "edit_file requires string field \"path\"",
        ) };
    };
    if (path_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "edit_file field \"path\" must be a string",
        ) };
    }

    const old_value = parsed.value.object.get("old_string") orelse {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "edit_file requires string field \"old_string\"",
        ) };
    };
    if (old_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "edit_file field \"old_string\" must be a string",
        ) };
    }

    const new_value = parsed.value.object.get("new_string") orelse {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "edit_file requires string field \"new_string\"",
        ) };
    };
    if (new_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "edit_file field \"new_string\" must be a string",
        ) };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    const owned_path = try ctx.allocator.dupe(u8, path_value.string);
    errdefer ctx.allocator.free(owned_path);
    const owned_old = try ctx.allocator.dupe(u8, old_value.string);
    errdefer ctx.allocator.free(owned_old);
    const owned_new = try ctx.allocator.dupe(u8, new_value.string);
    errdefer ctx.allocator.free(owned_new);
    input.* = .{
        .path = owned_path,
        .old_string = owned_old,
        .new_string = owned_new,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn takeFileMutationInput(
    tool_input: tool_dispatch.ToolInput,
    alloc: Allocator,
) file_mutation_contract.FileMutationInput {
    const input = tool_input.as(Input);
    const moved = file_mutation_contract.EditInput{
        .path = input.path,
        .old_string = input.old_string,
        .new_string = input.new_string,
    };
    alloc.destroy(input);
    return .{ .edit = moved };
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    tool_input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = tool_input.as(Input);
    if (input.path.len > std.Io.Dir.max_path_bytes) {
        return try ctx.allocator.dupe(
            u8,
            "file mutation preparation failed: path exceeds the preparation limit",
        );
    }
    if (input.old_string.len > max_content_bytes) {
        return try ctx.allocator.dupe(
            u8,
            "edit_file failed: old_string exceeds the 4 MiB preparation limit",
        );
    }
    if (input.new_string.len > max_content_bytes) {
        return try ctx.allocator.dupe(
            u8,
            "edit_file failed: new_string exceeds the 4 MiB preparation limit",
        );
    }
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .failure = try ctx.allocator.dupe(
        u8,
        "edit_file execution requires canonical tool runtime authorization",
    ) };
}

/// Reports that edit_file mutates filesystem state.
pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Reports that edit_file can destroy prior file content.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}
