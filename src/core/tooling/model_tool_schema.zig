const std = @import("std");

pub const description_max_bytes: usize = 1024;
pub const truncation_marker = "... [truncated]";

pub const JsonType = enum {
    string,
    integer,
    boolean,
    object,
    array,
};

const no_u32_bound = std.math.maxInt(u32);
const no_u64_bound = std.math.maxInt(u64);

const PropertyShape = union(enum) {
    enum_values: []const []const u8,
    object: *const ObjectSchema,
    array_values: struct {
        json_type: JsonType,
        enum_values: []const []const u8 = &.{},
    },
    array_objects: *const ObjectSchema,
};

const PropertyBounds = struct {
    min_length: u32 = no_u32_bound,
    max_length: u32 = no_u32_bound,
    minimum: u64 = no_u64_bound,
    maximum: u64 = no_u64_bound,
    min_items: u32 = no_u32_bound,
    max_items: u32 = no_u32_bound,
};

const no_property_bounds = PropertyBounds{};

const NullableMetadata = struct {
    description: []const u8 = "",
};

pub const Property = struct {
    name: []const u8,
    description: []const u8 = "",
    shape: ?*const PropertyShape = null,
    bounds: ?*const PropertyBounds = null,
    nullable: ?*const NullableMetadata = null,
    json_type: JsonType,
};

pub const ObjectSchema = struct {
    properties: []const Property = &.{},
    required: []const []const u8 = &.{},
    additional_properties: ?bool = null,
    min_properties: u32 = no_u32_bound,
    max_properties: u32 = no_u32_bound,
    one_of: []const ObjectSchema = &.{},
};

pub const FunctionSchema = struct {
    name: []const u8,
    description: []const u8,
    input_schema: ObjectSchema = .{},
};

pub fn isSingleRequiredObjectUnionField(
    schema: ObjectSchema,
    field_name: []const u8,
) bool {
    if (schema.properties.len != 1 or schema.required.len != 1 or
        schema.additional_properties != false or
        !std.mem.eql(u8, schema.properties[0].name, field_name) or
        !std.mem.eql(u8, schema.required[0], field_name))
    {
        return false;
    }
    const shape = schema.properties[0].shape orelse return false;
    return switch (shape.*) {
        .object => |object| object.one_of.len > 0,
        else => false,
    };
}


fn cappedDescriptionAlloc(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= description_max_bytes) return alloc.dupe(u8, text);

    const prefix_len = description_max_bytes - truncation_marker.len;
    var out = try alloc.alloc(u8, description_max_bytes);
    @memcpy(out[0..prefix_len], text[0..prefix_len]);
    @memcpy(out[prefix_len..], truncation_marker);
    return out;
}

pub fn writeCappedDescriptionJsonString(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
) !void {
    const capped_description = try cappedDescriptionAlloc(alloc, text);
    defer alloc.free(capped_description);
    try std.json.Stringify.value(capped_description, .{}, writer);
}

/// Opens the gateway's flattened function-tool envelope, up to the
/// "inputSchema" value. The caller writes the schema and the closing brace.
fn writeFunctionSchemaOpen(
    writer: *std.Io.Writer,
    name: []const u8,
    description: []const u8,
) !void {
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description, .{}, writer);
    try writer.writeAll(",\"inputSchema\":");
}

pub fn writeBuiltinFunctionSchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    schema: FunctionSchema,
) !void {
    const description = try cappedDescriptionAlloc(alloc, schema.description);
    defer alloc.free(description);
    try writeFunctionSchemaOpen(writer, schema.name, description);
    try writeObjectSchema(alloc, writer, schema.input_schema);
    try writer.writeByte('}');
}

pub fn builtinFunctionSchemaJsonAlloc(alloc: std.mem.Allocator, schema: FunctionSchema) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeBuiltinFunctionSchema(alloc, &out.writer, schema);
    return try out.toOwnedSlice();
}

/// Envelope for a dynamic (MCP) tool whose input schema is already rendered
/// JSON. Caller owns the returned slice.
pub fn dynamicFunctionSchemaJsonAlloc(
    alloc: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFunctionSchemaOpen(&out.writer, name, description);
    try out.writer.writeAll(input_schema_json);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

pub fn writeObjectSchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    schema: ObjectSchema,
) anyerror!void {
    if (schema.one_of.len > 0) {
        if (schema.properties.len > 0 or
            schema.required.len > 0 or
            schema.additional_properties != null or
            schema.min_properties != no_u32_bound or
            schema.max_properties != no_u32_bound)
        {
            return error.InvalidObjectSchema;
        }
        try writer.writeAll("{\"oneOf\":[");
        for (schema.one_of, 0..) |alternative, index| {
            if (index > 0) try writer.writeByte(',');
            try writeObjectSchema(alloc, writer, alternative);
        }
        try writer.writeAll("]}");
        return;
    }

    try writer.writeAll("{\"type\":\"object\",\"properties\":{");
    for (schema.properties, 0..) |property, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(property.name, .{}, writer);
        try writer.writeByte(':');
        try writePropertySchema(alloc, writer, property);
    }
    try writer.writeByte('}');
    if (schema.additional_properties) |value| {
        try writer.writeAll(",\"additionalProperties\":");
        try writer.writeAll(if (value) "true" else "false");
    }
    if (schema.min_properties != no_u32_bound) try writer.print(",\"minProperties\":{d}", .{schema.min_properties});
    if (schema.max_properties != no_u32_bound) try writer.print(",\"maxProperties\":{d}", .{schema.max_properties});
    if (schema.required.len > 0) {
        try writer.writeAll(",\"required\":[");
        for (schema.required, 0..) |name, index| {
            if (index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(name, .{}, writer);
        }
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

fn writePropertySchema(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    property: Property,
) anyerror!void {
    if (property.nullable) |nullable| {
        var concrete = property;
        concrete.nullable = null;
        try writer.writeAll("{\"anyOf\":[");
        try writePropertySchema(alloc, writer, concrete);
        try writer.writeAll(",{\"type\":\"null\"}]");
        if (nullable.description.len > 0) {
            try writer.writeAll(",\"description\":");
            try writeCappedDescriptionJsonString(
                alloc,
                writer,
                nullable.description,
            );
        }
        try writer.writeByte('}');
        return;
    }
    if (property.shape) |shape| {
        switch (shape.*) {
            .object => |object_schema| {
                try writeObjectSchema(alloc, writer, object_schema.*);
                return;
            },
            else => {},
        }
    }
    try writer.writeAll("{\"type\":");
    try std.json.Stringify.value(@tagName(property.json_type), .{}, writer);
    if (property.shape) |shape| {
        switch (shape.*) {
            .enum_values => |values| {
                try writer.writeAll(",\"enum\":[");
                for (values, 0..) |value, index| {
                    if (index > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(value, .{}, writer);
                }
                try writer.writeByte(']');
            },
            else => {},
        }
    }
    const bounds = property.bounds orelse &no_property_bounds;
    if (bounds.min_length != no_u32_bound) try writer.print(",\"minLength\":{d}", .{bounds.min_length});
    if (bounds.max_length != no_u32_bound) try writer.print(",\"maxLength\":{d}", .{bounds.max_length});
    if (bounds.minimum != no_u64_bound) try writer.print(",\"minimum\":{d}", .{bounds.minimum});
    if (bounds.maximum != no_u64_bound) try writer.print(",\"maximum\":{d}", .{bounds.maximum});
    if (property.description.len > 0) {
        try writer.writeAll(",\"description\":");
        try writeCappedDescriptionJsonString(alloc, writer, property.description);
    }
    if (bounds.min_items != no_u32_bound) try writer.print(",\"minItems\":{d}", .{bounds.min_items});
    if (bounds.max_items != no_u32_bound) try writer.print(",\"maxItems\":{d}", .{bounds.max_items});
    if (property.shape) |shape| {
        switch (shape.*) {
            .array_values => |values| {
                try writer.writeAll(",\"items\":{\"type\":");
                try std.json.Stringify.value(@tagName(values.json_type), .{}, writer);
                if (values.enum_values.len > 0) {
                    try writer.writeAll(",\"enum\":[");
                    for (values.enum_values, 0..) |value, index| {
                        if (index > 0) try writer.writeByte(',');
                        try std.json.Stringify.value(value, .{}, writer);
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .array_objects => |items| {
                try writer.writeAll(",\"items\":");
                try writeObjectSchema(alloc, writer, items.*);
            },
            else => {},
        }
    }
    try writer.writeByte('}');
}








