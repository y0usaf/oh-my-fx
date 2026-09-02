const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    query: []u8,
    allowed_domains: ?[][]u8 = null,
    blocked_domains: ?[][]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        freeOptionalStrings(alloc, self.allowed_domains);
        freeOptionalStrings(alloc, self.blocked_domains);
        self.* = .{ .query = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search arguments must be an object") };
    }
    if (unknownField(parsed.value.object)) |field| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "web_search field \"{s}\" is not supported", .{field}) };
    }

    const query_value = parsed.value.object.get("query") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search field \"query\" is required") };
    };
    if (query_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search field \"query\" must be a string") };
    }
    const query_len = std.unicode.utf8CountCodepoints(query_value.string) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search field \"query\" must be valid UTF-8") };
    };
    if (query_len < 2) {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search field \"query\" must contain at least two characters") };
    }

    var owned = DecodeOwned{ .alloc = ctx.allocator };
    defer owned.deinit();

    owned.query = try ctx.allocator.dupe(u8, query_value.string);

    const allowed_decoded = try decodeOptionalStrings(ctx, parsed.value.object, "allowed_domains");
    owned.allowed_domains = switch (allowed_decoded) {
        .strings => |strings| strings,
        .failure => |reason| return .{ .failure = reason },
    };

    const blocked_decoded = try decodeOptionalStrings(ctx, parsed.value.object, "blocked_domains");
    owned.blocked_domains = switch (blocked_decoded) {
        .strings => |strings| strings,
        .failure => |reason| return .{ .failure = reason },
    };

    const input = try ctx.allocator.create(Input);
    input.* = owned.take();
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (hasValues(input.allowed_domains) and hasValues(input.blocked_domains)) {
        return try ctx.allocator.dupe(u8, "web_search accepts only one non-empty domain filter");
    }
    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn freeOptionalStrings(alloc: Allocator, strings: ?[][]u8) void {
    const values = strings orelse return;
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

const OptionalStringsDecodeResult = union(enum) {
    strings: ?[][]u8,
    failure: []u8,
};

const DecodeOwned = struct {
    alloc: Allocator,
    query: ?[]u8 = null,
    allowed_domains: ?[][]u8 = null,
    blocked_domains: ?[][]u8 = null,

    fn deinit(self: *DecodeOwned) void {
        if (self.query) |query| self.alloc.free(query);
        freeOptionalStrings(self.alloc, self.allowed_domains);
        freeOptionalStrings(self.alloc, self.blocked_domains);
        self.query = null;
        self.allowed_domains = null;
        self.blocked_domains = null;
    }

    fn take(self: *DecodeOwned) Input {
        const input = Input{
            .query = self.query.?,
            .allowed_domains = self.allowed_domains,
            .blocked_domains = self.blocked_domains,
        };
        self.query = null;
        self.allowed_domains = null;
        self.blocked_domains = null;
        return input;
    }
};

fn decodeOptionalStrings(ctx: tool_dispatch.DispatchContext, object: std.json.ObjectMap, field: []const u8) tool_dispatch.DispatchError!OptionalStringsDecodeResult {
    const value = object.get(field) orelse return .{ .strings = null };
    if (value != .array) {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "web_search field \"{s}\" must be an array of strings", .{field}) };
    }

    const strings = try ctx.allocator.alloc([]u8, value.array.items.len);
    var owned_strings: ?[][]u8 = strings;
    var initialized: usize = 0;
    defer {
        if (owned_strings) |values| {
            for (values[0..initialized]) |string| ctx.allocator.free(string);
            ctx.allocator.free(values);
        }
    }

    for (value.array.items, 0..) |item, index| {
        if (item != .string) {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "web_search field \"{s}\" item {d} must be a string", .{ field, index }) };
        }
        strings[index] = try ctx.allocator.dupe(u8, item.string);
        initialized += 1;
    }
    if (strings.len == 0) {
        return .{ .strings = null };
    }
    owned_strings = null;
    return .{ .strings = strings };
}

fn unknownField(object: std.json.ObjectMap) ?[]const u8 {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "query")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "allowed_domains")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "blocked_domains")) continue;
        return entry.key_ptr.*;
    }
    return null;
}

fn hasValues(strings: ?[][]u8) bool {
    return if (strings) |values| values.len > 0 else false;
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
            return error.TestExpectedEqual;
        },
    }
}

fn expectDecodeInput(args_json: []const u8, expected_query: []const u8) !tool_dispatch.ToolInput {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |input| {
            const decoded_input = input.as(Input);
            try std.testing.expectEqualStrings(expected_query, decoded_input.query);
            return input;
        },
    }
}




