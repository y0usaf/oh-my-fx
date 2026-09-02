const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const io_mod = @import("../../core/shared/io.zig");
const model_context_encoding = @import("../../core/shared/model_context_encoding.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    source: []u8,
    skill: ?[]u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.source);
        if (self.skill) |skill| alloc.free(skill);
        self.* = .{ .source = &.{}, .skill = null };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "install_skill arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "install_skill arguments must be an object") };
    }

    const source_value = parsed.value.object.get("source") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "install_skill field \"source\" is required") };
    };
    if (source_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "install_skill field \"source\" must be a string") };
    }

    const skill_value = parsed.value.object.get("skill");
    const skill: ?[]u8 = if (skill_value) |value| blk: {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "install_skill field \"skill\" must be a string") };
        }
        break :blk try ctx.allocator.dupe(u8, value.string);
    } else null;
    errdefer if (skill) |owned| ctx.allocator.free(owned);

    const source = try ctx.allocator.dupe(u8, source_value.string);
    errdefer ctx.allocator.free(source);

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .source = source, .skill = skill };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const output = executeFromSource(ctx.allocator, ctx.skills_dir, input.source, input.skill) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "install_skill failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

pub fn matchesRunCommand(command: []const u8) bool {
    return builtin_skills.looksLikeInstallCommand(command);
}

pub fn executeRunCommand(
    ctx: tool_dispatch.DispatchContext,
    command: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const output = executeFromSource(ctx.allocator, ctx.skills_dir, command, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try tool_result_errors.formatToolExecutionErrorJson(
            ctx.allocator,
            "terminal",
            err,
        ) },
    };
    return .{ .success = output };
}

pub fn execute(arena: Allocator, skills_dir: []const u8, args_json: []const u8) ![]u8 {
    if (skills_dir.len == 0) return std.fmt.allocPrint(arena, "Skill installation is unavailable in this runtime.", .{});

    const args = try tool_args.parseToolArgsObject(arena, args_json);
    const source = try tool_args.requiredStringArg(args, "source");
    const filter = tool_args.optionalStringArg(args, "skill");
    return executeFromSource(arena, skills_dir, source, filter);
}

pub fn executeFromSource(alloc: Allocator, skills_dir: []const u8, source: []const u8, filter: ?[]const u8) ![]u8 {
    if (skills_dir.len == 0) return std.fmt.allocPrint(alloc, "Skill installation is unavailable in this runtime.", .{});

    var result = try builtin_skills.installFromSource(alloc, skills_dir, source, filter);
    defer result.deinit(alloc);

    if (result.installed.items.len == 0) return formatNoMatchOutput(alloc, source);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.print("Installed {d} skill(s) into fx.\n", .{result.installed.items.len});
    for (result.installed.items) |name| {
        try out.writer.writeAll("- ");
        try model_context_encoding.writeScalar(&out.writer, name);
        try out.writer.writeByte('\n');
    }

    return try out.toOwnedSlice();
}

fn formatNoMatchOutput(alloc: Allocator, source: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.writeAll("No matching skills were installed into fx from ") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, source) catch return error.OutOfMemory;
    out.writer.writeByte('.') catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(expected, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

fn checkNoMatchAllocationFailures(alloc: Allocator, source: []const u8) !void {
    const output = try formatNoMatchOutput(alloc, source);
    alloc.free(output);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8, limit: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, limit);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}







