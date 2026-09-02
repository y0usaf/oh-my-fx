const std = @import("std");
const feature_cache = @import("../feature_cache.zig");
const json_number = @import("../json_number.zig");
const json_schema = @import("../json_schema.zig");
const mcp_contract = @import("../mcp_contract.zig");
const mrtr = @import("../mrtr.zig");
const sort_utils = @import("../../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

pub const Protocol = enum { legacy, modern };

pub const Limits = struct {
    max_pages: usize = 64,
    max_tools: usize = 2048,
    max_cursor_bytes: usize = 4096,
    max_name_bytes: usize = 256,
    max_title_bytes: usize = 4096,
    max_description_bytes: usize = 64 * 1024,
    max_icons: usize = 16,
    max_icon_sizes: usize = 16,
    max_metadata_bytes: usize = 128 * 1024,
    max_content_items: usize = 256,
    max_content_field_bytes: usize = 1024 * 1024,
    max_input_requests: usize = 32,
    max_request_state_bytes: usize = 64 * 1024,
    schema: json_schema.Limits = .{},
};

pub const Error = error{
    InvalidEnvelope,
    ProtocolFailure,
    InvalidListResult,
    InvalidTool,
    DuplicateTool,
    DuplicateCursor,
    InconsistentCacheScope,
    PaginationLimitExceeded,
    ToolLimitExceeded,
    InvalidCallResult,
    UnsupportedResultType,
    InvalidContent,
    InvalidStructuredContent,
    InvalidInputRequired,
    MetadataLimitExceeded,
} || json_schema.Error || mrtr.Error || Allocator.Error || std.Io.Writer.Error;

pub const CacheScope = enum { private, public };

pub const Tool = struct {
    name: []u8,
    title: ?[]u8 = null,
    description: []u8,
    input_schema_json: []u8,
    output_schema_json: ?[]u8 = null,
    icons_json: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,

    pub fn deinit(self: *Tool, alloc: Allocator) void {
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        alloc.free(self.description);
        alloc.free(self.input_schema_json);
        if (self.output_schema_json) |value| alloc.free(value);
        if (self.icons_json) |value| alloc.free(value);
        if (self.annotations_json) |value| alloc.free(value);
        if (self.metadata_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Page = struct {
    tools: []Tool,
    next_cursor: ?[]u8 = null,
    ttl_ms: u64 = 0,
    ttl_present: bool = false,
    cache_scope: CacheScope = .private,

    pub fn deinit(self: *Page, alloc: Allocator) void {
        for (self.tools) |*tool| tool.deinit(alloc);
        alloc.free(self.tools);
        if (self.next_cursor) |cursor| alloc.free(cursor);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    tools: []Tool,
    fetched_at_ms: u64,
    expires_at_ms: u64,
    cache_scope: CacheScope,

    pub fn deinit(self: *Catalog, alloc: Allocator) void {
        for (self.tools) |*tool| tool.deinit(alloc);
        alloc.free(self.tools);
        self.* = undefined;
    }
};

pub const CatalogBuilder = struct {
    tools: std.ArrayList(Tool) = .empty,
    cursors: std.StringHashMap(void),
    protocol: Protocol,
    pages: usize = 0,
    first_received_at_ms: ?u64 = null,
    expires_at_ms: ?u64 = null,
    cache_scope: ?CacheScope = null,

    pub fn init(alloc: Allocator, protocol: Protocol) CatalogBuilder {
        return .{
            .cursors = std.StringHashMap(void).init(alloc),
            .protocol = protocol,
        };
    }

    pub fn deinit(self: *CatalogBuilder, alloc: Allocator) void {
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        var iterator = self.cursors.keyIterator();
        while (iterator.next()) |cursor| alloc.free(cursor.*);
        self.cursors.deinit();
        self.* = undefined;
    }

    pub fn appendPage(
        self: *CatalogBuilder,
        alloc: Allocator,
        page: *Page,
        received_at_ms: u64,
        limits: Limits,
    ) Error!void {
        self.pages = std.math.add(usize, self.pages, 1) catch
            return error.PaginationLimitExceeded;
        if (self.pages > limits.max_pages) return error.PaginationLimitExceeded;
        const total = std.math.add(usize, self.tools.items.len, page.tools.len) catch
            return error.ToolLimitExceeded;
        if (total > limits.max_tools) return error.ToolLimitExceeded;

        if (page.next_cursor) |cursor| {
            if (self.cursors.contains(cursor)) return error.DuplicateCursor;
        }
        if (self.cache_scope) |scope| {
            if (scope != page.cache_scope) return error.InconsistentCacheScope;
        } else {
            self.cache_scope = page.cache_scope;
        }
        if (self.first_received_at_ms == null) {
            self.first_received_at_ms = received_at_ms;
        }
        const page_expiry_ms = feature_cache.pageExpiry(
            switch (self.protocol) {
                .legacy => .legacy,
                .modern => .modern,
            },
            received_at_ms,
            page.ttl_present,
            page.ttl_ms,
        );
        self.expires_at_ms = feature_cache.earliestExpiry(
            self.expires_at_ms,
            page_expiry_ms,
        );
        for (page.tools, 0..) |tool, index| {
            for (self.tools.items) |existing| {
                if (std.mem.eql(u8, existing.name, tool.name)) return error.DuplicateTool;
            }
            for (page.tools[0..index]) |previous| {
                if (std.mem.eql(u8, previous.name, tool.name)) return error.DuplicateTool;
            }
        }

        try self.tools.ensureUnusedCapacity(alloc, page.tools.len);
        for (page.tools) |*tool| {
            self.tools.appendAssumeCapacity(tool.*);
            tool.* = undefined;
        }
        alloc.free(page.tools);
        page.tools = &.{};

        if (page.next_cursor) |cursor| {
            const owned = try alloc.dupe(u8, cursor);
            errdefer alloc.free(owned);
            try self.cursors.put(owned, {});
        }
    }

    /// Returns one complete owned catalog sorted by protocol name. Cache expiry
    /// is the earliest absolute expiry across every validated page.
    pub fn finish(self: *CatalogBuilder, alloc: Allocator) Error!Catalog {
        if (self.pages == 0) return error.InvalidListResult;
        sort_utils.sort(Tool, self.tools.items, {}, lessThanTool);
        return .{
            .tools = try self.tools.toOwnedSlice(alloc),
            .fetched_at_ms = self.first_received_at_ms.?,
            .expires_at_ms = self.expires_at_ms.?,
            .cache_scope = self.cache_scope orelse .private,
        };
    }
};

pub const ProtocolError = struct {
    code: i64,
    message: []u8,
    data_json: ?[]u8 = null,

    pub fn deinit(self: *ProtocolError, alloc: Allocator) void {
        alloc.free(self.message);
        if (self.data_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const InputRequest = mrtr.InputRequest;
pub const InputRequired = mrtr.InputRequired;

pub const CompleteResult = struct {
    result_json: []u8,
    is_error: bool,

    pub fn deinit(self: *CompleteResult, alloc: Allocator) void {
        alloc.free(self.result_json);
        self.* = undefined;
    }
};

pub const CallOutcome = union(enum) {
    complete: CompleteResult,
    input_required: InputRequired,
    protocol_failure: ProtocolError,

    pub fn deinit(self: *CallOutcome, alloc: Allocator) void {
        switch (self.*) {
            .complete => |*value| value.deinit(alloc),
            .input_required => |*value| value.deinit(alloc),
            .protocol_failure => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn parseListPage(
    alloc: Allocator,
    response: []const u8,
    protocol: Protocol,
    limits: Limits,
) Error!Page {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvelope,
    };
    defer parsed.deinit();
    mcp_contract.validateJsonRpcResponseEnvelope(parsed.value) catch
        return error.InvalidEnvelope;
    if (parsed.value.object.get("error") != null) return error.ProtocolFailure;
    const result = parsed.value.object.get("result") orelse return error.InvalidListResult;
    if (result != .object) return error.InvalidListResult;
    try requireCompleteResult(result, protocol);
    const tools_value = result.object.get("tools") orelse return error.InvalidListResult;
    if (tools_value != .array or tools_value.array.items.len > limits.max_tools) {
        return error.InvalidListResult;
    }

    const tools = try alloc.alloc(Tool, tools_value.array.items.len);
    var parsed_count: usize = 0;
    errdefer {
        for (tools[0..parsed_count]) |*tool| tool.deinit(alloc);
        alloc.free(tools);
    }
    for (tools_value.array.items, 0..) |value, index| {
        tools[index] = try parseTool(alloc, value, limits);
        parsed_count += 1;
    }

    var next_cursor: ?[]u8 = null;
    errdefer if (next_cursor) |value| alloc.free(value);
    if (result.object.get("nextCursor")) |cursor| {
        if (cursor != .string or cursor.string.len > limits.max_cursor_bytes) {
            return error.InvalidListResult;
        }
        next_cursor = try alloc.dupe(u8, cursor.string);
    }
    const ttl_value = result.object.get("ttlMs");
    const ttl_ms = if (ttl_value) |value|
        ttlMilliseconds(alloc, value) orelse return error.InvalidListResult
    else
        0;
    const cache_scope: CacheScope = if (result.object.get("cacheScope")) |value| blk: {
        if (value != .string) return error.InvalidListResult;
        if (std.mem.eql(u8, value.string, "public")) break :blk .public;
        if (std.mem.eql(u8, value.string, "private")) break :blk .private;
        return error.InvalidListResult;
    } else .private;
    return .{
        .tools = tools,
        .next_cursor = next_cursor,
        .ttl_ms = ttl_ms,
        .ttl_present = ttl_value != null,
        .cache_scope = cache_scope,
    };
}

pub fn parseCallOutcome(
    alloc: Allocator,
    response: []const u8,
    protocol: Protocol,
    output_schema_json: ?[]const u8,
    max_result_bytes: usize,
    limits: Limits,
) Error!CallOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEnvelope,
    };
    defer parsed.deinit();
    mcp_contract.validateJsonRpcResponseEnvelope(parsed.value) catch
        return error.InvalidEnvelope;
    if (parsed.value.object.get("error")) |protocol_error| {
        return .{ .protocol_failure = try parseProtocolError(alloc, protocol_error, limits) };
    }
    const result = parsed.value.object.get("result") orelse return error.InvalidCallResult;
    if (result != .object) return error.InvalidCallResult;
    const result_type = result.object.get("resultType");
    if (result_type) |value| {
        if (value != .string) return error.InvalidCallResult;
        if (std.mem.eql(u8, value.string, "input_required")) {
            if (protocol != .modern) return error.UnsupportedResultType;
            return .{ .input_required = try mrtr.parseInputRequired(
                alloc,
                result,
                mrtrLimits(limits),
            ) };
        }
        if (!std.mem.eql(u8, value.string, "complete")) return error.UnsupportedResultType;
    }

    const content = result.object.get("content") orelse return error.InvalidCallResult;
    if (content != .array or content.array.items.len > limits.max_content_items) {
        return error.InvalidContent;
    }
    for (content.array.items) |item| try validateContentItem(alloc, item, limits);

    const is_error = if (result.object.get("isError")) |value| blk: {
        if (value != .bool) return error.InvalidCallResult;
        break :blk value.bool;
    } else false;
    const structured_content = result.object.get("structuredContent");
    if (!is_error) {
        if (output_schema_json) |schema_json| {
            const structured = structured_content orelse return error.InvalidStructuredContent;
            var schema = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{
                .parse_numbers = false,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStructuredContent,
            };
            defer schema.deinit();
            const validation = json_schema.validateValue(alloc, schema.value, structured, limits.schema) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidStructuredContent,
            };
            switch (validation) {
                .valid, .server_authoritative => {},
                .invalid => return error.InvalidStructuredContent,
            }
        }
    }
    const serialization_limit = std.math.add(usize, max_result_bytes, 16 * 1024) catch
        return error.MetadataLimitExceeded;
    const result_json = try stringifyValueAlloc(alloc, result, serialization_limit);
    return .{ .complete = .{
        .result_json = result_json,
        .is_error = is_error,
    } };
}

pub fn validateArguments(
    alloc: Allocator,
    input_schema_json: []const u8,
    arguments_json: []const u8,
    limits: Limits,
) Error!json_schema.Result {
    const direct = try json_schema.validateText(alloc, input_schema_json, arguments_json, limits.schema);
    switch (direct) {
        .valid, .server_authoritative => return direct,
        .invalid => {},
    }
    const normalized = try normalizeOptionalHeaderNulls(
        alloc,
        input_schema_json,
        arguments_json,
        limits,
    ) orelse return direct;
    defer alloc.free(normalized);
    return json_schema.validateText(alloc, input_schema_json, normalized, limits.schema);
}

/// SEP-2243 treats null values for optional x-mcp-header properties as omitted.
/// Keep that transport-extension rule outside the general JSON Schema engine.
fn normalizeOptionalHeaderNulls(
    alloc: Allocator,
    input_schema_json: []const u8,
    arguments_json: []const u8,
    limits: Limits,
) Error!?[]u8 {
    var schema = std.json.parseFromSlice(std.json.Value, alloc, input_schema_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer schema.deinit();
    var arguments = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer arguments.deinit();
    if (schema.value != .object or arguments.value != .object) return null;
    const properties = schema.value.object.get("properties") orelse return null;
    if (properties != .object) return null;
    const required = schema.value.object.get("required");

    var omitted = false;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    var wrote = false;
    var iterator = arguments.value.object.iterator();
    while (iterator.next()) |entry| {
        const property_schema = properties.object.get(entry.key_ptr.*);
        const header_null = entry.value_ptr.* == .null and
            property_schema != null and
            property_schema.? == .object and
            property_schema.?.object.get("x-mcp-header") != null and
            !requiredContains(required, entry.key_ptr.*);
        if (header_null) {
            omitted = true;
            continue;
        }
        if (wrote) try out.writer.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, &out.writer);
        try out.writer.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer);
        wrote = true;
    }
    try out.writer.writeByte('}');
    if (!omitted) return null;
    if (out.writer.buffered().len > limits.schema.max_instance_bytes) {
        return error.InstanceLimitExceeded;
    }
    return try out.toOwnedSlice();
}

fn requiredContains(required: ?std.json.Value, name: []const u8) bool {
    const value = required orelse return false;
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, name)) return true;
    }
    return false;
}

pub fn buildListRequest(
    alloc: Allocator,
    request_id: u64,
    protocol: Protocol,
    cursor: ?[]const u8,
    write_modern_metadata: *const fn (*std.Io.Writer) anyerror!void,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try output.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try output.writer.print("{d}", .{request_id});
    try output.writer.writeAll(",\"method\":\"tools/list\",\"params\":{");
    var wrote_param = false;
    if (protocol == .modern) {
        try output.writer.writeAll("\"_meta\":");
        try write_modern_metadata(&output.writer);
        wrote_param = true;
    }
    if (cursor) |value| {
        if (wrote_param) try output.writer.writeByte(',');
        try output.writer.writeAll("\"cursor\":");
        try std.json.Stringify.value(value, .{}, &output.writer);
    }
    try output.writer.writeAll("}}");
    return try output.toOwnedSlice();
}

fn parseTool(alloc: Allocator, value: std.json.Value, limits: Limits) Error!Tool {
    if (value != .object) return error.InvalidTool;
    const name_value = value.object.get("name") orelse return error.InvalidTool;
    if (name_value != .string or name_value.string.len == 0 or name_value.string.len > limits.max_name_bytes) {
        return error.InvalidTool;
    }
    const description_value = value.object.get("description");
    if (description_value) |description| {
        if (description != .string or description.string.len > limits.max_description_bytes) return error.InvalidTool;
    }
    const title_value = value.object.get("title");
    if (title_value) |title| {
        if (title != .string or title.string.len > limits.max_title_bytes) return error.InvalidTool;
    }
    const input_schema = value.object.get("inputSchema") orelse return error.InvalidTool;
    _ = try json_schema.validateSchemaValue(alloc, input_schema, limits.schema);
    try json_schema.requireObjectRoot(input_schema);
    if (value.object.get("outputSchema")) |output_schema| {
        _ = try json_schema.validateSchemaValue(alloc, output_schema, limits.schema);
    }
    if (value.object.get("icons")) |icons| try validateIcons(icons, limits);
    if (value.object.get("annotations")) |annotations| try validateToolAnnotations(annotations, limits);
    if (value.object.get("_meta")) |metadata| if (metadata != .object) return error.InvalidTool;

    const name = try alloc.dupe(u8, name_value.string);
    errdefer alloc.free(name);
    const title = if (title_value) |title| try alloc.dupe(u8, title.string) else null;
    errdefer if (title) |owned| alloc.free(owned);
    const description = try alloc.dupe(u8, if (description_value) |description| description.string else "");
    errdefer alloc.free(description);
    const input_schema_json = try stringifyValueAlloc(alloc, input_schema, limits.schema.max_schema_bytes);
    errdefer alloc.free(input_schema_json);
    const output_schema_json = if (value.object.get("outputSchema")) |output_schema|
        try stringifyValueAlloc(alloc, output_schema, limits.schema.max_schema_bytes)
    else
        null;
    errdefer if (output_schema_json) |owned| alloc.free(owned);
    const icons_json = if (value.object.get("icons")) |icons|
        try stringifyValueAlloc(alloc, icons, limits.max_metadata_bytes)
    else
        null;
    errdefer if (icons_json) |owned| alloc.free(owned);
    const annotations_json = if (value.object.get("annotations")) |annotations|
        try stringifyValueAlloc(alloc, annotations, limits.max_metadata_bytes)
    else
        null;
    errdefer if (annotations_json) |owned| alloc.free(owned);
    const metadata_json = if (value.object.get("_meta")) |metadata|
        try stringifyValueAlloc(alloc, metadata, limits.max_metadata_bytes)
    else
        null;
    errdefer if (metadata_json) |owned| alloc.free(owned);
    return .{
        .name = name,
        .title = title,
        .description = description,
        .input_schema_json = input_schema_json,
        .output_schema_json = output_schema_json,
        .icons_json = icons_json,
        .annotations_json = annotations_json,
        .metadata_json = metadata_json,
    };
}

fn parseProtocolError(alloc: Allocator, value: std.json.Value, limits: Limits) Error!ProtocolError {
    if (value != .object) return error.InvalidEnvelope;
    const code = value.object.get("code") orelse return error.InvalidEnvelope;
    const message = value.object.get("message") orelse return error.InvalidEnvelope;
    const parsed_code: i64 = switch (code) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch
            return error.InvalidEnvelope,
        else => return error.InvalidEnvelope,
    };
    if (message != .string or message.string.len > limits.max_description_bytes) {
        return error.InvalidEnvelope;
    }
    const owned_message = try alloc.dupe(u8, message.string);
    errdefer alloc.free(owned_message);
    const data_json = if (value.object.get("data")) |data|
        try stringifyValueAlloc(alloc, data, limits.max_metadata_bytes)
    else
        null;
    return .{ .code = parsed_code, .message = owned_message, .data_json = data_json };
}

fn validateContentItem(alloc: Allocator, value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidContent;
    const type_value = value.object.get("type") orelse return error.InvalidContent;
    if (type_value != .string) return error.InvalidContent;
    if (value.object.get("annotations")) |annotations| try validateAnnotations(annotations, limits);
    if (value.object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidContent;
        _ = try boundedJsonLength(metadata, limits.max_metadata_bytes);
    }
    if (std.mem.eql(u8, type_value.string, "text")) {
        _ = try requireBoundedString(value.object, "text", limits.max_content_field_bytes);
        return;
    }
    if (std.mem.eql(u8, type_value.string, "image") or std.mem.eql(u8, type_value.string, "audio")) {
        const data = try requireBoundedString(value.object, "data", limits.max_content_field_bytes);
        _ = try requireBoundedString(value.object, "mimeType", limits.max_title_bytes);
        if (!try validBase64(alloc, data)) return error.InvalidContent;
        return;
    }
    if (std.mem.eql(u8, type_value.string, "resource_link")) {
        try validateResourceLink(alloc, value.object, limits);
        return;
    }
    if (std.mem.eql(u8, type_value.string, "resource")) {
        const resource = value.object.get("resource") orelse return error.InvalidContent;
        try validateEmbeddedResource(alloc, resource, limits);
        return;
    }
    return error.InvalidContent;
}

fn mrtrLimits(limits: Limits) mrtr.Limits {
    return .{
        .max_requests = limits.max_input_requests,
        .max_name_bytes = limits.max_name_bytes,
        .max_json_bytes = limits.max_metadata_bytes,
        .max_string_bytes = limits.max_request_state_bytes,
        .max_collection_items = limits.max_content_items,
    };
}

fn validateResourceLink(alloc: Allocator, object: std.json.ObjectMap, limits: Limits) Error!void {
    _ = try requireBoundedString(object, "uri", limits.max_content_field_bytes);
    _ = try requireBoundedString(object, "name", limits.max_title_bytes);
    try optionalBoundedString(object, "title", limits.max_title_bytes);
    try optionalBoundedString(object, "description", limits.max_description_bytes);
    try optionalBoundedString(object, "mimeType", limits.max_title_bytes);
    if (object.get("icons")) |icons| try validateIcons(icons, limits);
    if (object.get("size")) |size| _ = nonNegativeU64(alloc, size) orelse return error.InvalidContent;
}

fn validateEmbeddedResource(alloc: Allocator, value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidContent;
    _ = try requireBoundedString(value.object, "uri", limits.max_content_field_bytes);
    try optionalBoundedString(value.object, "mimeType", limits.max_title_bytes);
    if (value.object.get("_meta")) |metadata| {
        if (metadata != .object) return error.InvalidContent;
        _ = try boundedJsonLength(metadata, limits.max_metadata_bytes);
    }
    const text = value.object.get("text");
    const blob = value.object.get("blob");
    if ((text == null) == (blob == null)) return error.InvalidContent;
    if (text) |content| {
        if (content != .string or content.string.len > limits.max_content_field_bytes) {
            return error.InvalidContent;
        }
    }
    if (blob) |content| {
        if (content != .string or content.string.len > limits.max_content_field_bytes or
            !try validBase64(alloc, content.string))
        {
            return error.InvalidContent;
        }
    }
}

fn validateIcons(value: std.json.Value, limits: Limits) Error!void {
    if (value != .array or value.array.items.len > limits.max_icons) return error.InvalidTool;
    for (value.array.items) |icon| {
        if (icon != .object) return error.InvalidTool;
        _ = requireBoundedString(icon.object, "src", limits.max_content_field_bytes) catch return error.InvalidTool;
        optionalBoundedString(icon.object, "mimeType", limits.max_title_bytes) catch return error.InvalidTool;
        if (icon.object.get("sizes")) |sizes| {
            if (sizes != .array or sizes.array.items.len > limits.max_icon_sizes) return error.InvalidTool;
            for (sizes.array.items) |size| {
                if (size != .string or size.string.len > limits.max_title_bytes) return error.InvalidTool;
            }
        }
        if (icon.object.get("theme")) |theme| {
            if (theme != .string or
                (!std.mem.eql(u8, theme.string, "light") and !std.mem.eql(u8, theme.string, "dark")))
            {
                return error.InvalidTool;
            }
        }
    }
}

fn validateToolAnnotations(value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidTool;
    optionalBoundedString(value.object, "title", limits.max_title_bytes) catch return error.InvalidTool;
    const booleans = [_][]const u8{ "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint" };
    for (booleans) |name| if (value.object.get(name)) |hint| if (hint != .bool) return error.InvalidTool;
    _ = try boundedJsonLength(value, limits.max_metadata_bytes);
}

fn validateAnnotations(value: std.json.Value, limits: Limits) Error!void {
    if (value != .object) return error.InvalidContent;
    if (value.object.get("audience")) |audience| {
        if (audience != .array or audience.array.items.len > 2) return error.InvalidContent;
        for (audience.array.items) |role| {
            if (role != .string or
                (!std.mem.eql(u8, role.string, "user") and !std.mem.eql(u8, role.string, "assistant")))
            {
                return error.InvalidContent;
            }
        }
    }
    if (value.object.get("priority")) |priority| {
        const number = jsonNumber(priority) orelse return error.InvalidContent;
        if (number < 0 or number > 1) return error.InvalidContent;
    }
    try optionalBoundedString(value.object, "lastModified", limits.max_title_bytes);
    _ = try boundedJsonLength(value, limits.max_metadata_bytes);
}

fn requireCompleteResult(result: std.json.Value, protocol: Protocol) Error!void {
    _ = protocol;
    if (result.object.get("resultType")) |value| {
        if (value != .string or !std.mem.eql(u8, value.string, "complete")) {
            return error.UnsupportedResultType;
        }
    }
}

fn requireBoundedString(object: std.json.ObjectMap, name: []const u8, max_bytes: usize) Error![]const u8 {
    const value = object.get(name) orelse return error.InvalidContent;
    if (value != .string or value.string.len > max_bytes) return error.InvalidContent;
    return value.string;
}

fn optionalBoundedString(object: std.json.ObjectMap, name: []const u8, max_bytes: usize) Error!void {
    if (object.get(name)) |value| {
        if (value != .string or value.string.len > max_bytes) return error.InvalidContent;
    }
}

fn boundedJsonLength(value: std.json.Value, max_bytes: usize) Error!usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    std.json.Stringify.value(value, .{}, &counter.writer) catch return error.MetadataLimitExceeded;
    if (counter.fullCount() > max_bytes) return error.MetadataLimitExceeded;
    return @intCast(counter.fullCount());
}

fn stringifyValueAlloc(alloc: Allocator, value: std.json.Value, max_bytes: usize) Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    std.json.Stringify.value(value, .{}, &output.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    if (output.writer.buffered().len > max_bytes) return error.MetadataLimitExceeded;
    return try output.toOwnedSlice();
}

fn validBase64(alloc: Allocator, value: []const u8) Error!bool {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value) catch return false;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, value) catch return false;
    return true;
}

fn nonNegativeU64(alloc: Allocator, value: std.json.Value) ?u64 {
    const parsed = json_number.fromValue(alloc, value, .{}) catch return null;
    if (parsed == null) return null;
    var number = parsed.?;
    defer number.deinit(alloc);
    const result = number.toNonNegativeUsize() orelse return null;
    return std.math.cast(u64, result);
}

fn ttlMilliseconds(alloc: Allocator, value: std.json.Value) ?u64 {
    const parsed = json_number.fromValue(alloc, value, .{}) catch return null;
    if (parsed == null) return null;
    var number = parsed.?;
    defer number.deinit(alloc);
    if (number.negative) return 0;
    const result = number.toNonNegativeUsize() orelse return null;
    return std.math.cast(u64, result);
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| if (std.math.isFinite(number)) number else null,
        .number_string => |number| std.fmt.parseFloat(f64, number) catch null,
        else => null,
    };
}

fn lessThanTool(_: void, left: Tool, right: Tool) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn noopMetadata(_: *std.Io.Writer) anyerror!void {}

fn checkToolParsingAllocationFailures(alloc: Allocator) !void {
    var page = try parseListPage(
        alloc,
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","title":"Echo","description":"Echo input","icons":[{"src":"data:image/png;base64,AA=="}],"annotations":{"readOnlyHint":true},"inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]},"outputSchema":{"type":"object"},"_meta":{"vendor":"test"}}]}}
    ,
        .modern,
        .{},
    );
    defer page.deinit(alloc);
    var outcome = try parseCallOutcome(
        alloc,
        \\{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"image","data":"AA==","mimeType":"image/png"}],"structuredContent":{}}}
    ,
        .modern,
        page.tools[0].output_schema_json,
        64 * 1024,
        .{},
    );
    defer outcome.deinit(alloc);
}

fn fuzzListPageParser(_: void, smith: *std.testing.Smith) !void {
    var input_buffer: [4096]u8 = undefined;
    const input_len = std.math.cast(usize, smith.slice(&input_buffer)) orelse return;
    if (parseListPage(
        std.testing.allocator,
        input_buffer[0..input_len],
        .modern,
        .{},
    )) |page_value| {
        var page = page_value;
        page.deinit(std.testing.allocator);
    } else |_| {}
}














