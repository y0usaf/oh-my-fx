const std = @import("std");
const json_number = @import("json_number.zig");
const json_schema_pattern = @import("json_schema_pattern.zig");
const schema_resolver = @import("json_schema_resolver.zig");

const Allocator = std.mem.Allocator;

pub const Limits = struct {
    max_schema_bytes: usize = 256 * 1024,
    max_instance_bytes: usize = 1024 * 1024,
    max_depth: usize = 64,
    max_nodes: usize = 4096,
    max_steps: usize = 100_000,
    max_ref_hops: usize = 256,
    max_container_entries: usize = 4096,
    max_number_bytes: usize = 4096,
    max_number_exponent_abs: i64 = 1_000_000,
    max_number_expanded_digits: usize = 8192,
    max_pattern_states: usize = 2048,
    max_pattern_repeat: usize = 1024,
    max_pattern_steps: usize = 200_000,
};

pub const Dialect = schema_resolver.Dialect;

pub const Error = error{
    InvalidSchema,
    UnsupportedDialect,
    ExternalReference,
    UnresolvedReference,
    SchemaLimitExceeded,
    InstanceLimitExceeded,
    InvalidJson,
} || schema_resolver.Error || Allocator.Error;

pub const SchemaAssessment = enum {
    locally_evaluable,
    server_authoritative,
};

pub const Violation = enum {
    type,
    constant,
    enumeration,
    multiple_of,
    maximum,
    exclusive_maximum,
    minimum,
    exclusive_minimum,
    min_length,
    max_length,
    pattern,
    min_items,
    max_items,
    unique_items,
    additional_items,
    contains,
    unevaluated_items,
    min_properties,
    max_properties,
    required,
    dependent_required,
    properties,
    pattern_properties,
    additional_properties,
    property_names,
    dependent_schemas,
    dependencies,
    unevaluated_properties,
    all_of,
    any_of,
    one_of,
    not,
    conditional,
    reference,

    pub fn label(self: Violation) []const u8 {
        return switch (self) {
            .type => "type",
            .constant => "const",
            .enumeration => "enum",
            .multiple_of => "multipleOf",
            .maximum => "maximum",
            .exclusive_maximum => "exclusiveMaximum",
            .minimum => "minimum",
            .exclusive_minimum => "exclusiveMinimum",
            .min_length => "minLength",
            .max_length => "maxLength",
            .pattern => "pattern",
            .min_items => "minItems",
            .max_items => "maxItems",
            .unique_items => "uniqueItems",
            .additional_items => "additionalItems",
            .contains => "contains",
            .unevaluated_items => "unevaluatedItems",
            .min_properties => "minProperties",
            .max_properties => "maxProperties",
            .required => "required",
            .dependent_required => "dependentRequired",
            .properties => "properties",
            .pattern_properties => "patternProperties",
            .additional_properties => "additionalProperties",
            .property_names => "propertyNames",
            .dependent_schemas => "dependentSchemas",
            .dependencies => "dependencies",
            .unevaluated_properties => "unevaluatedProperties",
            .all_of => "allOf",
            .any_of => "anyOf",
            .one_of => "oneOf",
            .not => "not",
            .conditional => "if/then/else",
            .reference => "$ref",
        };
    }
};

pub const Result = union(enum) {
    valid,
    invalid: Violation,
    server_authoritative,
};

const dialect_2020_12 = "https://json-schema.org/draft/2020-12/schema";
const dialect_draft_7 = "http://json-schema.org/draft-07/schema";

fn detectDialect(schema: std.json.Value) Error!Dialect {
    if (schema != .object) return .draft_2020_12;
    const declaration = schema.object.get("$schema") orelse return .draft_2020_12;
    const uri = stringValue(declaration) orelse return error.InvalidSchema;
    return dialectFromUri(uri);
}

fn dialectFromUri(uri: []const u8) Error!Dialect {
    if (std.mem.eql(u8, uri, dialect_2020_12) or
        std.mem.eql(u8, uri, dialect_2020_12 ++ "#"))
    {
        return .draft_2020_12;
    }
    if (std.mem.eql(u8, uri, dialect_draft_7) or
        std.mem.eql(u8, uri, dialect_draft_7 ++ "#"))
    {
        return .draft_7;
    }
    return error.UnsupportedDialect;
}

fn validateSchemaText(
    alloc: Allocator,
    schema_json: []const u8,
    limits: Limits,
) Error!SchemaAssessment {
    if (schema_json.len > limits.max_schema_bytes) return error.SchemaLimitExceeded;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    return validateSchemaValue(alloc, parsed.value, limits);
}

pub fn validateSchemaValue(
    alloc: Allocator,
    schema: std.json.Value,
    limits: Limits,
) Error!SchemaAssessment {
    var remaining = limits.max_nodes;
    try checkJsonBounds(schema, 0, &remaining, limits, .schema);
    const dialect = try detectDialect(schema);
    var resolver = try schema_resolver.Resolver.init(alloc, schema, dialect, resolverLimits(limits));
    defer resolver.deinit();
    return validateSchemaWithResolver(schema, dialect, limits, &resolver);
}

fn validateSchemaWithResolver(
    schema: std.json.Value,
    dialect: Dialect,
    limits: Limits,
    resolver: *const schema_resolver.Resolver,
) Error!SchemaAssessment {
    var ctx = SchemaContext{
        .alloc = resolver.alloc,
        .dialect = dialect,
        .resolver = resolver,
        .limits = limits,
    };
    defer ctx.deinit();
    try ctx.scan(schema, 0);
    ctx.nodes = 0;
    _ = try ctx.markReferenceObject(schema);
    try ctx.checkReferences(schema, resolver.rootResource(), 0);
    return ctx.assessment;
}

pub fn validateText(
    alloc: Allocator,
    schema_json: []const u8,
    instance_json: []const u8,
    limits: Limits,
) Error!Result {
    if (schema_json.len > limits.max_schema_bytes) return error.SchemaLimitExceeded;
    if (instance_json.len > limits.max_instance_bytes) return error.InstanceLimitExceeded;
    var schema_parsed = std.json.parseFromSlice(std.json.Value, alloc, schema_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer schema_parsed.deinit();
    var instance_parsed = std.json.parseFromSlice(std.json.Value, alloc, instance_json, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer instance_parsed.deinit();
    return validateValue(alloc, schema_parsed.value, instance_parsed.value, limits);
}

pub fn validateValue(
    alloc: Allocator,
    schema: std.json.Value,
    instance: std.json.Value,
    limits: Limits,
) Error!Result {
    var schema_remaining = limits.max_nodes;
    try checkJsonBounds(schema, 0, &schema_remaining, limits, .schema);
    const dialect = try detectDialect(schema);
    var resolver = try schema_resolver.Resolver.init(alloc, schema, dialect, resolverLimits(limits));
    defer resolver.deinit();
    const schema_assessment = try validateSchemaWithResolver(schema, dialect, limits, &resolver);
    var remaining = limits.max_nodes;
    try checkJsonBounds(instance, 0, &remaining, limits, .instance);
    if (schema_assessment == .server_authoritative) return .server_authoritative;
    var ctx = ValidationContext{
        .alloc = alloc,
        .dialect = dialect,
        .resolver = &resolver,
        .limits = limits,
    };
    defer ctx.dynamic_scope.deinit(alloc);
    return if (try ctx.validateAt(schema, instance, 0, resolver.rootResource())) |violation|
        .{ .invalid = violation }
    else
        .valid;
}

fn resolverLimits(limits: Limits) schema_resolver.Limits {
    return .{
        .max_depth = limits.max_depth,
        .max_nodes = limits.max_nodes,
        .max_uri_bytes = limits.max_schema_bytes,
    };
}

pub fn requireObjectRoot(schema: std.json.Value) Error!void {
    if (schema != .object) return error.InvalidSchema;
    const type_value = schema.object.get("type") orelse return error.InvalidSchema;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "object")) {
        return error.InvalidSchema;
    }
}

const SchemaContext = struct {
    alloc: Allocator,
    dialect: Dialect,
    resolver: *const schema_resolver.Resolver,
    limits: Limits,
    nodes: usize = 0,
    assessment: SchemaAssessment = .locally_evaluable,
    reference_objects: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn deinit(self: *SchemaContext) void {
        self.reference_objects.deinit(self.alloc);
    }

    fn scan(self: *SchemaContext, schema: std.json.Value, depth: usize) Error!void {
        try self.consumeNode(depth);
        switch (schema) {
            .bool => return,
            .object => |object| {
                if (object.count() > self.limits.max_container_entries) {
                    return error.SchemaLimitExceeded;
                }
                if (self.dialect == .draft_7) {
                    if (object.get("$ref")) |reference| {
                        _ = stringValue(reference) orelse return error.InvalidSchema;
                        return;
                    }
                }
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    const keyword = entry.key_ptr.*;
                    const value = entry.value_ptr.*;
                    if (!knownKeyword(self.dialect, keyword)) continue;
                    try self.scanKeyword(keyword, value, depth);
                }
            },
            else => return error.InvalidSchema,
        }
    }

    fn scanKeyword(
        self: *SchemaContext,
        keyword: []const u8,
        value: std.json.Value,
        depth: usize,
    ) Error!void {
        if (std.mem.eql(u8, keyword, "$schema")) {
            const dialect = stringValue(value) orelse return error.InvalidSchema;
            if (try dialectFromUri(dialect) != self.dialect) {
                return error.UnsupportedDialect;
            }
            return;
        }
        if (std.mem.eql(u8, keyword, "$id") or
            std.mem.eql(u8, keyword, "$anchor") or
            (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "$dynamicAnchor")) or
            std.mem.eql(u8, keyword, "$ref") or
            (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "$dynamicRef")) or
            std.mem.eql(u8, keyword, "$comment") or
            std.mem.eql(u8, keyword, "title") or
            std.mem.eql(u8, keyword, "description") or
            std.mem.eql(u8, keyword, "format") or
            std.mem.eql(u8, keyword, "contentEncoding") or
            std.mem.eql(u8, keyword, "contentMediaType"))
        {
            _ = stringValue(value) orelse return error.InvalidSchema;
            return;
        }
        if (std.mem.eql(u8, keyword, "type")) {
            try validateTypeKeyword(value);
            return;
        }
        if (std.mem.eql(u8, keyword, "pattern")) {
            const source = stringValue(value) orelse return error.InvalidSchema;
            self.assessment = combineAssessment(
                self.assessment,
                try assessPattern(self.alloc, source, self.limits),
            );
            return;
        }
        if (std.mem.eql(u8, keyword, "enum") or
            std.mem.eql(u8, keyword, "examples") or
            std.mem.eql(u8, keyword, "required"))
        {
            if (value != .array or value.array.items.len > self.limits.max_container_entries) {
                return error.InvalidSchema;
            }
            if (std.mem.eql(u8, keyword, "required")) {
                try validateUniqueStringArray(value);
            }
            return;
        }
        if (std.mem.eql(u8, keyword, "multipleOf") or
            std.mem.eql(u8, keyword, "maximum") or
            std.mem.eql(u8, keyword, "exclusiveMaximum") or
            std.mem.eql(u8, keyword, "minimum") or
            std.mem.eql(u8, keyword, "exclusiveMinimum"))
        {
            var number = try schemaNumber(self.alloc, value, self.limits);
            defer number.deinit(self.alloc);
            if (std.mem.eql(u8, keyword, "multipleOf") and
                (number.negative or number.isZero()))
            {
                return error.InvalidSchema;
            }
            return;
        }
        if (std.mem.eql(u8, keyword, "maxLength") or
            std.mem.eql(u8, keyword, "minLength") or
            std.mem.eql(u8, keyword, "maxItems") or
            std.mem.eql(u8, keyword, "minItems") or
            (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "maxContains")) or
            (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "minContains")) or
            std.mem.eql(u8, keyword, "maxProperties") or
            std.mem.eql(u8, keyword, "minProperties"))
        {
            _ = try nonNegativeUsize(self.alloc, value, self.limits);
            return;
        }
        if (std.mem.eql(u8, keyword, "uniqueItems") or
            std.mem.eql(u8, keyword, "deprecated") or
            std.mem.eql(u8, keyword, "readOnly") or
            std.mem.eql(u8, keyword, "writeOnly"))
        {
            if (value != .bool) return error.InvalidSchema;
            return;
        }
        if (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "$vocabulary")) {
            if (value != .object) return error.InvalidSchema;
            var vocabulary = value.object.iterator();
            while (vocabulary.next()) |entry| {
                if (entry.value_ptr.* != .bool) return error.InvalidSchema;
            }
            return;
        }
        if (std.mem.eql(u8, keyword, "patternProperties")) {
            if (value != .object or value.object.count() > self.limits.max_container_entries) {
                return error.InvalidSchema;
            }
            var children = value.object.iterator();
            while (children.next()) |entry| {
                self.assessment = combineAssessment(
                    self.assessment,
                    try assessPattern(self.alloc, entry.key_ptr.*, self.limits),
                );
                try self.scan(entry.value_ptr.*, depth + 1);
            }
            return;
        }
        if ((self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "$defs")) or
            (self.dialect == .draft_7 and std.mem.eql(u8, keyword, "definitions")) or
            std.mem.eql(u8, keyword, "properties") or
            (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "dependentSchemas")))
        {
            if (value != .object or value.object.count() > self.limits.max_container_entries) {
                return error.InvalidSchema;
            }
            var children = value.object.iterator();
            while (children.next()) |entry| try self.scan(entry.value_ptr.*, depth + 1);
            return;
        }
        if (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "dependentRequired")) {
            if (value != .object or value.object.count() > self.limits.max_container_entries) {
                return error.InvalidSchema;
            }
            var dependencies = value.object.iterator();
            while (dependencies.next()) |entry| {
                const names = entry.value_ptr.*;
                if (names != .array or names.array.items.len > self.limits.max_container_entries) {
                    return error.InvalidSchema;
                }
                try validateUniqueStringArray(names);
            }
            return;
        }
        if (self.dialect == .draft_7 and std.mem.eql(u8, keyword, "dependencies")) {
            if (value != .object or value.object.count() > self.limits.max_container_entries) {
                return error.InvalidSchema;
            }
            var dependencies = value.object.iterator();
            while (dependencies.next()) |entry| {
                const dependency = entry.value_ptr.*;
                if (dependency == .array) {
                    if (dependency.array.items.len > self.limits.max_container_entries) {
                        return error.InvalidSchema;
                    }
                    try validateUniqueStringArray(dependency);
                } else {
                    try self.scan(dependency, depth + 1);
                }
            }
            return;
        }
        if ((self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "prefixItems")) or
            std.mem.eql(u8, keyword, "allOf") or
            std.mem.eql(u8, keyword, "anyOf") or
            std.mem.eql(u8, keyword, "oneOf"))
        {
            if (value != .array or value.array.items.len > self.limits.max_container_entries) {
                return error.InvalidSchema;
            }
            if (!std.mem.eql(u8, keyword, "prefixItems") and value.array.items.len == 0) {
                return error.InvalidSchema;
            }
            for (value.array.items) |child| try self.scan(child, depth + 1);
            return;
        }
        if (self.dialect == .draft_7 and std.mem.eql(u8, keyword, "items") and value == .array) {
            if (value.array.items.len > self.limits.max_container_entries) {
                return error.InvalidSchema;
            }
            for (value.array.items) |child| try self.scan(child, depth + 1);
            return;
        }
        if (std.mem.eql(u8, keyword, "items") or
            std.mem.eql(u8, keyword, "contains") or
            (self.dialect == .draft_7 and std.mem.eql(u8, keyword, "additionalItems")) or
            std.mem.eql(u8, keyword, "additionalProperties") or
            std.mem.eql(u8, keyword, "propertyNames") or
            std.mem.eql(u8, keyword, "if") or
            std.mem.eql(u8, keyword, "then") or
            std.mem.eql(u8, keyword, "else") or
            std.mem.eql(u8, keyword, "not") or
            (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "unevaluatedItems")) or
            (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "unevaluatedProperties")) or
            (self.dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "contentSchema")))
        {
            try self.scan(value, depth + 1);
            return;
        }
        // const, default, and extension annotations accept any JSON value.
    }

    fn checkReferences(
        self: *SchemaContext,
        schema: std.json.Value,
        inherited_resource: usize,
        depth: usize,
    ) Error!void {
        try self.consumeNode(depth);
        if (schema != .object) return;
        const resource = try self.resolver.enterResource(schema, inherited_resource);
        if (schema.object.get("$ref")) |value| {
            const target = try self.resolver.resolve(resource, stringValue(value).?);
            try self.checkReferenceTarget(target.schema, target.resource_index, depth + 1);
        }
        if (self.dialect == .draft_7 and schema.object.get("$ref") != null) return;
        if (schema.object.get("$dynamicRef")) |value| {
            const target = try self.resolver.resolve(resource, stringValue(value).?);
            try self.checkReferenceTarget(target.schema, target.resource_index, depth + 1);
        }
        var iterator = schema.object.iterator();
        while (iterator.next()) |entry| {
            if (!keywordContainsSchemas(self.dialect, entry.key_ptr.*)) continue;
            switch (entry.value_ptr.*) {
                .object => |object| {
                    if (schemaMapKeyword(self.dialect, entry.key_ptr.*)) {
                        var children = object.iterator();
                        while (children.next()) |child| {
                            if (self.dialect == .draft_7 and
                                std.mem.eql(u8, entry.key_ptr.*, "dependencies") and
                                child.value_ptr.* == .array)
                            {
                                continue;
                            }
                            try self.checkReferences(child.value_ptr.*, resource, depth + 1);
                        }
                    } else {
                        try self.checkReferences(entry.value_ptr.*, resource, depth + 1);
                    }
                },
                .array => |array| for (array.items) |child| {
                    try self.checkReferences(child, resource, depth + 1);
                },
                .bool => try self.checkReferences(entry.value_ptr.*, resource, depth + 1),
                else => {},
            }
        }
    }

    fn checkReferenceTarget(
        self: *SchemaContext,
        schema: std.json.Value,
        resource: usize,
        depth: usize,
    ) Error!void {
        if (try self.markReferenceObject(schema)) return;
        try self.scan(schema, depth);
        try self.checkReferences(schema, resource, depth);
    }

    fn markReferenceObject(self: *SchemaContext, schema: std.json.Value) Error!bool {
        if (schema != .object or schema.object.count() == 0) return false;
        const identity = @intFromPtr(schema.object.keys().ptr);
        return (try self.reference_objects.getOrPut(self.alloc, identity)).found_existing;
    }

    fn consumeNode(self: *SchemaContext, depth: usize) Error!void {
        if (depth > self.limits.max_depth) return error.SchemaLimitExceeded;
        self.nodes = std.math.add(usize, self.nodes, 1) catch return error.SchemaLimitExceeded;
        if (self.nodes > self.limits.max_nodes) return error.SchemaLimitExceeded;
    }
};

const BoundKind = enum { schema, instance };

fn checkJsonBounds(
    value: std.json.Value,
    depth: usize,
    remaining: *usize,
    limits: Limits,
    kind: BoundKind,
) Error!void {
    if (depth > limits.max_depth or remaining.* == 0) return switch (kind) {
        .schema => error.SchemaLimitExceeded,
        .instance => error.InstanceLimitExceeded,
    };
    remaining.* -= 1;
    switch (value) {
        .number_string => |number| if (number.len > limits.max_number_bytes) return switch (kind) {
            .schema => error.SchemaLimitExceeded,
            .instance => error.InstanceLimitExceeded,
        },
        .array => |array| {
            if (array.items.len > limits.max_container_entries) return switch (kind) {
                .schema => error.SchemaLimitExceeded,
                .instance => error.InstanceLimitExceeded,
            };
            for (array.items) |child| {
                try checkJsonBounds(child, depth + 1, remaining, limits, kind);
            }
        },
        .object => |object| {
            if (object.count() > limits.max_container_entries) return switch (kind) {
                .schema => error.SchemaLimitExceeded,
                .instance => error.InstanceLimitExceeded,
            };
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try checkJsonBounds(entry.value_ptr.*, depth + 1, remaining, limits, kind);
            }
        },
        else => {},
    }
}

const Evaluation = struct {
    item_count: usize,
    property_count: usize,
    items: std.DynamicBitSetUnmanaged = .{},
    properties: std.DynamicBitSetUnmanaged = .{},

    fn init(instance: std.json.Value) Evaluation {
        return .{
            .item_count = if (instance == .array) instance.array.items.len else 0,
            .property_count = if (instance == .object) instance.object.count() else 0,
        };
    }

    fn deinit(self: *Evaluation, alloc: Allocator) void {
        self.items.deinit(alloc);
        self.properties.deinit(alloc);
    }

    fn markItem(self: *Evaluation, alloc: Allocator, index: usize) Allocator.Error!void {
        if (self.items.capacity() == 0 and self.item_count != 0) {
            try self.items.resize(alloc, self.item_count, false);
        }
        self.items.set(index);
    }

    fn markProperty(self: *Evaluation, alloc: Allocator, index: usize) Allocator.Error!void {
        if (self.properties.capacity() == 0 and self.property_count != 0) {
            try self.properties.resize(alloc, self.property_count, false);
        }
        self.properties.set(index);
    }

    fn itemIsMarked(self: *const Evaluation, index: usize) bool {
        return self.items.capacity() != 0 and self.items.isSet(index);
    }

    fn propertyIsMarked(self: *const Evaluation, index: usize) bool {
        return self.properties.capacity() != 0 and self.properties.isSet(index);
    }

    fn merge(self: *Evaluation, alloc: Allocator, other: *const Evaluation) Allocator.Error!void {
        if (other.items.capacity() != 0) {
            if (self.items.capacity() == 0) try self.items.resize(alloc, self.item_count, false);
            self.items.setUnion(other.items);
        }
        if (other.properties.capacity() != 0) {
            if (self.properties.capacity() == 0) {
                try self.properties.resize(alloc, self.property_count, false);
            }
            self.properties.setUnion(other.properties);
        }
    }
};

const ValidationContext = struct {
    alloc: Allocator,
    dialect: Dialect,
    resolver: *const schema_resolver.Resolver,
    limits: Limits,
    steps: usize = 0,
    pattern_steps: usize = 0,
    ref_hops: usize = 0,
    dynamic_scope: std.ArrayList(usize) = .empty,

    fn validate(
        self: *ValidationContext,
        schema: std.json.Value,
        instance: std.json.Value,
        depth: usize,
    ) Error!?Violation {
        const inherited_resource = if (self.dynamic_scope.items.len == 0)
            self.resolver.rootResource()
        else
            self.dynamic_scope.items[self.dynamic_scope.items.len - 1];
        return self.validateAt(schema, instance, depth, inherited_resource);
    }

    fn validateCollect(
        self: *ValidationContext,
        schema: std.json.Value,
        instance: std.json.Value,
        depth: usize,
        evaluated: *Evaluation,
    ) Error!?Violation {
        const inherited_resource = if (self.dynamic_scope.items.len == 0)
            self.resolver.rootResource()
        else
            self.dynamic_scope.items[self.dynamic_scope.items.len - 1];
        return self.validateCollectAt(schema, instance, depth, inherited_resource, evaluated);
    }

    fn validateCollectAt(
        self: *ValidationContext,
        schema: std.json.Value,
        instance: std.json.Value,
        depth: usize,
        inherited_resource: usize,
        evaluated: *Evaluation,
    ) Error!?Violation {
        var nested = Evaluation.init(instance);
        defer nested.deinit(self.alloc);
        const violation = try self.validateAtCollect(
            schema,
            instance,
            depth,
            inherited_resource,
            &nested,
        );
        if (violation == null) try evaluated.merge(self.alloc, &nested);
        return violation;
    }

    fn validateAt(
        self: *ValidationContext,
        schema: std.json.Value,
        instance: std.json.Value,
        depth: usize,
        inherited_resource: usize,
    ) Error!?Violation {
        var evaluated = Evaluation.init(instance);
        defer evaluated.deinit(self.alloc);
        return self.validateAtCollect(schema, instance, depth, inherited_resource, &evaluated);
    }

    fn validateAtCollect(
        self: *ValidationContext,
        schema: std.json.Value,
        instance: std.json.Value,
        depth: usize,
        inherited_resource: usize,
        evaluated: *Evaluation,
    ) Error!?Violation {
        try self.consumeStep(depth);
        if (schema == .bool) return if (schema.bool) null else .not;
        const object = schema.object;
        const resource = try self.resolver.enterResource(schema, inherited_resource);
        const pushed_resource = self.dynamic_scope.items.len == 0 or
            self.dynamic_scope.items[self.dynamic_scope.items.len - 1] != resource;
        if (pushed_resource) try self.dynamic_scope.append(self.alloc, resource);
        defer if (pushed_resource) {
            _ = self.dynamic_scope.pop();
        };

        if (object.get("$ref")) |reference| {
            try self.consumeReference();
            defer self.ref_hops -= 1;
            const target = try self.resolver.resolve(resource, reference.string);
            const violation = try self.validateCollectAt(
                target.schema,
                instance,
                depth + 1,
                target.resource_index,
                evaluated,
            );
            if (violation != null) return .reference;
            if (self.dialect == .draft_7) return null;
        }
        if (object.get("$dynamicRef")) |reference| {
            try self.consumeReference();
            defer self.ref_hops -= 1;
            const static_target = try self.resolver.resolve(resource, reference.string);
            var target_schema = static_target.schema;
            var target_resource = static_target.resource_index;
            if (static_target.anchor_kind == .dynamic) {
                const name = static_target.anchor_name.?;
                for (self.dynamic_scope.items) |scope_resource| {
                    if (self.resolver.dynamicAnchor(scope_resource, name)) |dynamic_target| {
                        target_schema = dynamic_target;
                        target_resource = scope_resource;
                        break;
                    }
                }
            }
            if (try self.validateCollectAt(
                target_schema,
                instance,
                depth + 1,
                target_resource,
                evaluated,
            )) |_| return .reference;
        }

        if (object.get("type")) |types| {
            if (!try matchesType(self.alloc, instance, types, self.limits)) return .type;
        }
        if (object.get("const")) |constant| {
            try self.consumeStep(depth + 1);
            if (!try jsonEqual(self.alloc, instance, constant, self.limits)) return .constant;
        }
        if (object.get("enum")) |enumeration| {
            var matched = false;
            for (enumeration.array.items) |candidate| {
                try self.consumeStep(depth + 1);
                if (try jsonEqual(self.alloc, instance, candidate, self.limits)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return .enumeration;
        }

        if (try instanceNumber(self.alloc, instance, self.limits)) |parsed_number| {
            var number = parsed_number;
            defer number.deinit(self.alloc);
            if (object.get("multipleOf")) |value| {
                var divisor = try schemaNumber(self.alloc, value, self.limits);
                defer divisor.deinit(self.alloc);
                if (!(number.isMultipleOf(
                    self.alloc,
                    divisor,
                    numberLimits(self.limits),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NumberLimitExceeded => return error.InstanceLimitExceeded,
                    error.InvalidNumber => return error.InvalidSchema,
                })) return .multiple_of;
            }
            if (object.get("maximum")) |value| {
                var bound = try schemaNumber(self.alloc, value, self.limits);
                defer bound.deinit(self.alloc);
                if (number.order(bound) == .gt) return .maximum;
            }
            if (object.get("exclusiveMaximum")) |value| {
                var bound = try schemaNumber(self.alloc, value, self.limits);
                defer bound.deinit(self.alloc);
                if (number.order(bound) != .lt) return .exclusive_maximum;
            }
            if (object.get("minimum")) |value| {
                var bound = try schemaNumber(self.alloc, value, self.limits);
                defer bound.deinit(self.alloc);
                if (number.order(bound) == .lt) return .minimum;
            }
            if (object.get("exclusiveMinimum")) |value| {
                var bound = try schemaNumber(self.alloc, value, self.limits);
                defer bound.deinit(self.alloc);
                if (number.order(bound) != .gt) return .exclusive_minimum;
            }
        }

        if (instance == .string) {
            const length = std.unicode.utf8CountCodepoints(instance.string) catch
                return error.InvalidJson;
            if (object.get("minLength")) |value| {
                if (length < try nonNegativeUsize(self.alloc, value, self.limits)) return .min_length;
            }
            if (object.get("maxLength")) |value| {
                if (length > try nonNegativeUsize(self.alloc, value, self.limits)) return .max_length;
            }
            if (object.get("pattern")) |value| {
                if (!try self.matchesPattern(value.string, instance.string)) return .pattern;
            }
        }
        if (instance == .array) if (try self.validateArray(object, instance.array, depth, evaluated)) |violation| return violation;
        if (instance == .object) if (try self.validateObject(object, instance.object, depth, evaluated)) |violation| return violation;

        if (object.get("allOf")) |all_of| {
            for (all_of.array.items) |child| if (try self.validateCollect(
                child,
                instance,
                depth + 1,
                evaluated,
            )) |_| return .all_of;
        }
        if (object.get("anyOf")) |any_of| {
            var matched = false;
            for (any_of.array.items) |child| {
                if ((try self.validateCollect(child, instance, depth + 1, evaluated)) == null) {
                    matched = true;
                }
            }
            if (!matched) return .any_of;
        }
        if (object.get("oneOf")) |one_of| {
            var matches: usize = 0;
            for (one_of.array.items) |child| {
                if ((try self.validateCollect(child, instance, depth + 1, evaluated)) == null) {
                    matches = std.math.add(usize, matches, 1) catch return error.InstanceLimitExceeded;
                }
            }
            if (matches != 1) return .one_of;
        }
        if (object.get("not")) |not_schema| {
            if ((try self.validate(not_schema, instance, depth + 1)) == null) return .not;
        }
        if (object.get("if")) |if_schema| {
            const condition_matches = (try self.validateCollect(
                if_schema,
                instance,
                depth + 1,
                evaluated,
            )) == null;
            const selected = if (condition_matches) object.get("then") else object.get("else");
            if (selected) |branch| if (try self.validateCollect(
                branch,
                instance,
                depth + 1,
                evaluated,
            )) |_| return .conditional;
        }
        if (self.dialect == .draft_2020_12 and instance == .array) {
            if (object.get("unevaluatedItems")) |unevaluated| {
                for (instance.array.items, 0..) |item, index| {
                    if (evaluated.itemIsMarked(index)) continue;
                    if (try self.validate(unevaluated, item, depth + 1)) |_| return .unevaluated_items;
                    try evaluated.markItem(self.alloc, index);
                }
            }
        }
        if (self.dialect == .draft_2020_12 and instance == .object) {
            if (object.get("unevaluatedProperties")) |unevaluated| {
                var properties = instance.object.iterator();
                var index: usize = 0;
                while (properties.next()) |entry| : (index += 1) {
                    if (evaluated.propertyIsMarked(index)) continue;
                    if (try self.validate(unevaluated, entry.value_ptr.*, depth + 1)) |_| {
                        return .unevaluated_properties;
                    }
                    try evaluated.markProperty(self.alloc, index);
                }
            }
        }
        return null;
    }

    fn validateArray(
        self: *ValidationContext,
        schema: std.json.ObjectMap,
        instance: std.json.Array,
        depth: usize,
        evaluated: *Evaluation,
    ) Error!?Violation {
        if (instance.items.len > self.limits.max_container_entries) return error.InstanceLimitExceeded;
        if (schema.get("minItems")) |value| {
            if (instance.items.len < try nonNegativeUsize(self.alloc, value, self.limits)) return .min_items;
        }
        if (schema.get("maxItems")) |value| {
            if (instance.items.len > try nonNegativeUsize(self.alloc, value, self.limits)) return .max_items;
        }
        if (schema.get("uniqueItems")) |value| if (value.bool) {
            for (instance.items, 0..) |left, left_index| {
                for (instance.items[left_index + 1 ..]) |right| {
                    try self.consumeStep(depth + 1);
                    if (try jsonEqual(self.alloc, left, right, self.limits)) return .unique_items;
                }
            }
        };

        if (self.dialect == .draft_7) {
            if (schema.get("items")) |items| {
                if (items == .array) {
                    const tuple_count = @min(items.array.items.len, instance.items.len);
                    for (items.array.items[0..tuple_count], instance.items[0..tuple_count]) |child, item| {
                        if (try self.validate(child, item, depth + 1)) |_| return .type;
                    }
                    for (0..tuple_count) |index| try evaluated.markItem(self.alloc, index);
                    if (schema.get("additionalItems")) |additional| {
                        for (instance.items[tuple_count..], tuple_count..) |item, index| {
                            if (try self.validate(additional, item, depth + 1)) |_| return .additional_items;
                            try evaluated.markItem(self.alloc, index);
                        }
                    }
                } else {
                    for (instance.items, 0..) |item, index| {
                        if (try self.validate(items, item, depth + 1)) |_| return .type;
                        try evaluated.markItem(self.alloc, index);
                    }
                }
            }
        } else {
            var prefix_count: usize = 0;
            if (schema.get("prefixItems")) |prefix| {
                prefix_count = @min(prefix.array.items.len, instance.items.len);
                for (prefix.array.items[0..prefix_count], instance.items[0..prefix_count]) |child, item| {
                    if (try self.validate(child, item, depth + 1)) |_| return .type;
                }
                for (0..prefix_count) |index| try evaluated.markItem(self.alloc, index);
            }
            if (schema.get("items")) |items_schema| {
                for (instance.items[prefix_count..], prefix_count..) |item, index| {
                    if (try self.validate(items_schema, item, depth + 1)) |_| return .type;
                    try evaluated.markItem(self.alloc, index);
                }
            }
        }
        if (schema.get("contains")) |contains_schema| {
            var matches: usize = 0;
            for (instance.items, 0..) |item, index| {
                if ((try self.validate(contains_schema, item, depth + 1)) == null) {
                    matches = std.math.add(usize, matches, 1) catch return error.InstanceLimitExceeded;
                    try evaluated.markItem(self.alloc, index);
                }
            }
            const minimum = if (self.dialect == .draft_2020_12)
                if (schema.get("minContains")) |value|
                    try nonNegativeUsize(self.alloc, value, self.limits)
                else
                    1
            else
                1;
            const maximum = if (self.dialect == .draft_2020_12)
                if (schema.get("maxContains")) |value|
                    try nonNegativeUsize(self.alloc, value, self.limits)
                else
                    std.math.maxInt(usize)
            else
                std.math.maxInt(usize);
            if (matches < minimum or matches > maximum) return .contains;
        }
        return null;
    }

    fn validateObject(
        self: *ValidationContext,
        schema: std.json.ObjectMap,
        instance: std.json.ObjectMap,
        depth: usize,
        evaluated: *Evaluation,
    ) Error!?Violation {
        if (instance.count() > self.limits.max_container_entries) return error.InstanceLimitExceeded;
        if (schema.get("minProperties")) |value| {
            if (instance.count() < try nonNegativeUsize(self.alloc, value, self.limits)) return .min_properties;
        }
        if (schema.get("maxProperties")) |value| {
            if (instance.count() > try nonNegativeUsize(self.alloc, value, self.limits)) return .max_properties;
        }
        if (schema.get("required")) |required| {
            for (required.array.items) |name| if (!instance.contains(name.string)) return .required;
        }

        const properties = schema.get("properties");
        const pattern_properties = schema.get("patternProperties");
        var covered = try self.alloc.alloc(bool, instance.count());
        defer self.alloc.free(covered);
        @memset(covered, false);
        var instance_iterator = instance.iterator();
        var property_index: usize = 0;
        while (instance_iterator.next()) |entry| : (property_index += 1) {
            if (properties) |property_schemas| {
                if (property_schemas.object.get(entry.key_ptr.*)) |property_schema| {
                    if (try self.validate(property_schema, entry.value_ptr.*, depth + 1)) |_| return .properties;
                    covered[property_index] = true;
                    try evaluated.markProperty(self.alloc, property_index);
                }
            }
            if (pattern_properties) |patterns| {
                var pattern_iterator = patterns.object.iterator();
                while (pattern_iterator.next()) |pattern| {
                    if (!try self.matchesPattern(pattern.key_ptr.*, entry.key_ptr.*)) continue;
                    if (try self.validate(pattern.value_ptr.*, entry.value_ptr.*, depth + 1)) |_| {
                        return .pattern_properties;
                    }
                    covered[property_index] = true;
                    try evaluated.markProperty(self.alloc, property_index);
                }
            }
        }
        if (schema.get("additionalProperties")) |additional| {
            instance_iterator = instance.iterator();
            property_index = 0;
            while (instance_iterator.next()) |entry| : (property_index += 1) {
                if (covered[property_index]) continue;
                if (try self.validate(additional, entry.value_ptr.*, depth + 1)) |_| return .additional_properties;
                try evaluated.markProperty(self.alloc, property_index);
            }
        }
        if (schema.get("propertyNames")) |property_names| {
            var names = instance.iterator();
            while (names.next()) |entry| {
                if (try self.validate(property_names, .{ .string = entry.key_ptr.* }, depth + 1)) |_| return .property_names;
            }
        }
        if (schema.get("dependentRequired")) |dependencies| {
            var dependency_iterator = dependencies.object.iterator();
            while (dependency_iterator.next()) |entry| {
                if (!instance.contains(entry.key_ptr.*)) continue;
                for (entry.value_ptr.array.items) |name| if (!instance.contains(name.string)) return .dependent_required;
            }
        }
        if (schema.get("dependentSchemas")) |dependencies| {
            var dependency_iterator = dependencies.object.iterator();
            while (dependency_iterator.next()) |entry| {
                if (!instance.contains(entry.key_ptr.*)) continue;
                if (try self.validateCollect(
                    entry.value_ptr.*,
                    .{ .object = instance },
                    depth + 1,
                    evaluated,
                )) |_| return .dependent_schemas;
            }
        }
        if (self.dialect == .draft_7) if (schema.get("dependencies")) |dependencies| {
            var dependency_iterator = dependencies.object.iterator();
            while (dependency_iterator.next()) |entry| {
                if (!instance.contains(entry.key_ptr.*)) continue;
                const dependency = entry.value_ptr.*;
                if (dependency == .array) {
                    for (dependency.array.items) |name| {
                        if (!instance.contains(name.string)) return .dependencies;
                    }
                } else if (try self.validateCollect(
                    dependency,
                    .{ .object = instance },
                    depth + 1,
                    evaluated,
                )) |_| {
                    return .dependencies;
                }
            }
        };
        return null;
    }

    fn consumeStep(self: *ValidationContext, depth: usize) Error!void {
        if (depth > self.limits.max_depth) return error.InstanceLimitExceeded;
        self.steps = std.math.add(usize, self.steps, 1) catch return error.InstanceLimitExceeded;
        if (self.steps > self.limits.max_steps) return error.InstanceLimitExceeded;
    }

    fn consumeReference(self: *ValidationContext) Error!void {
        self.ref_hops = std.math.add(usize, self.ref_hops, 1) catch return error.InstanceLimitExceeded;
        if (self.ref_hops > self.limits.max_ref_hops) return error.InstanceLimitExceeded;
    }

    fn matchesPattern(self: *ValidationContext, source: []const u8, text: []const u8) Error!bool {
        return json_schema_pattern.matches(
            self.alloc,
            source,
            text,
            patternLimits(self.limits),
            &self.pattern_steps,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidPattern, error.InvalidUtf8 => error.InvalidSchema,
            error.PatternLimitExceeded => error.InstanceLimitExceeded,
        };
    }
};

fn validateTypeKeyword(value: std.json.Value) Error!void {
    if (value == .string) {
        if (!validTypeName(value.string)) return error.InvalidSchema;
        return;
    }
    if (value != .array or value.array.items.len == 0) return error.InvalidSchema;
    for (value.array.items, 0..) |item, index| {
        const name = stringValue(item) orelse return error.InvalidSchema;
        if (!validTypeName(name)) return error.InvalidSchema;
        for (value.array.items[0..index]) |previous| {
            if (std.mem.eql(u8, previous.string, name)) return error.InvalidSchema;
        }
    }
}

fn validateUniqueStringArray(value: std.json.Value) Error!void {
    for (value.array.items, 0..) |item, index| {
        const name = stringValue(item) orelse return error.InvalidSchema;
        for (value.array.items[0..index]) |previous| {
            if (std.mem.eql(u8, previous.string, name)) return error.InvalidSchema;
        }
    }
}

fn numberLimits(limits: Limits) json_number.Limits {
    return .{
        .max_lexeme_bytes = limits.max_number_bytes,
        .max_exponent_abs = limits.max_number_exponent_abs,
        .max_expanded_digits = limits.max_number_expanded_digits,
    };
}

fn patternLimits(limits: Limits) json_schema_pattern.Limits {
    return .{
        .max_depth = limits.max_depth,
        .max_states = limits.max_pattern_states,
        .max_repeat = limits.max_pattern_repeat,
        .max_steps = limits.max_pattern_steps,
    };
}

fn assessPattern(alloc: Allocator, source: []const u8, limits: Limits) Error!SchemaAssessment {
    json_schema_pattern.validate(alloc, source, patternLimits(limits)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern => return .server_authoritative,
        error.InvalidUtf8 => return error.InvalidSchema,
        error.PatternLimitExceeded => return error.SchemaLimitExceeded,
    };
    return .locally_evaluable;
}

fn combineAssessment(left: SchemaAssessment, right: SchemaAssessment) SchemaAssessment {
    return if (left == .server_authoritative or right == .server_authoritative)
        .server_authoritative
    else
        .locally_evaluable;
}

fn schemaNumber(
    alloc: Allocator,
    value: std.json.Value,
    limits: Limits,
) Error!json_number.Number {
    return (json_number.fromValue(alloc, value, numberLimits(limits)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NumberLimitExceeded => return error.SchemaLimitExceeded,
        error.InvalidNumber => return error.InvalidSchema,
    }) orelse error.InvalidSchema;
}

fn instanceNumber(
    alloc: Allocator,
    value: std.json.Value,
    limits: Limits,
) Error!?json_number.Number {
    return json_number.fromValue(alloc, value, numberLimits(limits)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NumberLimitExceeded => return error.InstanceLimitExceeded,
        error.InvalidNumber => return error.InvalidJson,
    };
}

fn nonNegativeUsize(
    alloc: Allocator,
    value: std.json.Value,
    limits: Limits,
) Error!usize {
    var number = try schemaNumber(alloc, value, limits);
    defer number.deinit(alloc);
    return number.toNonNegativeUsize() orelse error.InvalidSchema;
}

fn matchesType(
    alloc: Allocator,
    instance: std.json.Value,
    type_value: std.json.Value,
    limits: Limits,
) Error!bool {
    if (type_value == .string) return matchesTypeName(alloc, instance, type_value.string, limits);
    for (type_value.array.items) |item| {
        if (try matchesTypeName(alloc, instance, item.string, limits)) return true;
    }
    return false;
}

fn matchesTypeName(
    alloc: Allocator,
    instance: std.json.Value,
    name: []const u8,
    limits: Limits,
) Error!bool {
    if (std.mem.eql(u8, name, "null")) return instance == .null;
    if (std.mem.eql(u8, name, "boolean")) return instance == .bool;
    if (std.mem.eql(u8, name, "object")) return instance == .object;
    if (std.mem.eql(u8, name, "array")) return instance == .array;
    if (std.mem.eql(u8, name, "string")) return instance == .string;
    if (!std.mem.eql(u8, name, "number") and !std.mem.eql(u8, name, "integer")) return false;
    const parsed = try instanceNumber(alloc, instance, limits);
    if (parsed == null) return false;
    var number = parsed.?;
    defer number.deinit(alloc);
    if (std.mem.eql(u8, name, "number")) return true;
    return number.isInteger();
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn jsonEqual(
    alloc: Allocator,
    left: std.json.Value,
    right: std.json.Value,
    limits: Limits,
) Error!bool {
    if (try instanceNumber(alloc, left, limits)) |parsed_left| {
        var left_number = parsed_left;
        defer left_number.deinit(alloc);
        const parsed_right = try instanceNumber(alloc, right, limits);
        if (parsed_right == null) return false;
        var right_number = parsed_right.?;
        defer right_number.deinit(alloc);
        return left_number.eql(right_number);
    }
    if (try instanceNumber(alloc, right, limits)) |parsed_right| {
        var right_number = parsed_right;
        defer right_number.deinit(alloc);
        return false;
    }
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |value| value == right.bool,
        .integer, .float, .number_string => unreachable,
        .string => |value| std.mem.eql(u8, value, right.string),
        .array => |array| blk: {
            if (array.items.len != right.array.items.len) break :blk false;
            for (array.items, right.array.items) |left_item, right_item| {
                if (!try jsonEqual(alloc, left_item, right_item, limits)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != right.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const right_value = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!try jsonEqual(alloc, entry.value_ptr.*, right_value, limits)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn validTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "null") or
        std.mem.eql(u8, name, "boolean") or
        std.mem.eql(u8, name, "object") or
        std.mem.eql(u8, name, "array") or
        std.mem.eql(u8, name, "number") or
        std.mem.eql(u8, name, "string") or
        std.mem.eql(u8, name, "integer");
}

fn knownKeyword(dialect: Dialect, keyword: []const u8) bool {
    const shared = [_][]const u8{
        "$schema",          "$id",               "$ref",
        "$comment",         "type",              "enum",
        "const",            "multipleOf",        "maximum",
        "exclusiveMaximum", "minimum",           "exclusiveMinimum",
        "maxLength",        "minLength",         "pattern",
        "maxItems",         "minItems",          "uniqueItems",
        "maxProperties",    "minProperties",     "required",
        "items",            "contains",          "additionalProperties",
        "properties",       "patternProperties", "propertyNames",
        "if",               "then",              "else",
        "allOf",            "anyOf",             "oneOf",
        "not",              "title",             "description",
        "default",          "readOnly",          "writeOnly",
        "examples",         "format",            "contentEncoding",
        "contentMediaType",
    };
    for (shared) |candidate| if (std.mem.eql(u8, keyword, candidate)) return true;
    const draft_2020_keywords = [_][]const u8{
        "$schema",           "$id",                  "$vocabulary",
        "$ref",              "$dynamicRef",          "$anchor",
        "$dynamicAnchor",    "$defs",                "$comment",
        "type",              "enum",                 "const",
        "multipleOf",        "maximum",              "exclusiveMaximum",
        "minimum",           "exclusiveMinimum",     "maxLength",
        "minLength",         "maxItems",             "minItems",
        "uniqueItems",       "maxContains",          "minContains",
        "maxProperties",     "minProperties",        "required",
        "dependentRequired", "prefixItems",          "items",
        "contains",          "additionalProperties", "properties",
        "dependentSchemas",  "unevaluatedItems",     "unevaluatedProperties",
        "propertyNames",     "if",                   "then",
        "else",              "allOf",                "anyOf",
        "oneOf",             "not",                  "title",
        "description",       "default",              "deprecated",
        "readOnly",          "writeOnly",            "examples",
        "format",            "contentEncoding",      "contentMediaType",
        "contentSchema",
    };
    const draft_7_keywords = [_][]const u8{
        "definitions",
        "additionalItems",
        "dependencies",
    };
    const keywords = switch (dialect) {
        .draft_2020_12 => &draft_2020_keywords,
        .draft_7 => &draft_7_keywords,
    };
    for (keywords) |candidate| if (std.mem.eql(u8, keyword, candidate)) return true;
    return false;
}

fn schemaMapKeyword(dialect: Dialect, keyword: []const u8) bool {
    return switch (dialect) {
        .draft_2020_12 => std.mem.eql(u8, keyword, "$defs") or
            std.mem.eql(u8, keyword, "properties") or
            std.mem.eql(u8, keyword, "patternProperties") or
            std.mem.eql(u8, keyword, "dependentSchemas"),
        .draft_7 => std.mem.eql(u8, keyword, "definitions") or
            std.mem.eql(u8, keyword, "properties") or
            std.mem.eql(u8, keyword, "patternProperties") or
            std.mem.eql(u8, keyword, "dependencies"),
    };
}

fn keywordContainsSchemas(dialect: Dialect, keyword: []const u8) bool {
    return schemaMapKeyword(dialect, keyword) or
        (dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "prefixItems")) or
        (dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "unevaluatedItems")) or
        (dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "unevaluatedProperties")) or
        (dialect == .draft_7 and std.mem.eql(u8, keyword, "additionalItems")) or
        std.mem.eql(u8, keyword, "items") or
        std.mem.eql(u8, keyword, "contains") or
        std.mem.eql(u8, keyword, "additionalProperties") or
        std.mem.eql(u8, keyword, "propertyNames") or
        std.mem.eql(u8, keyword, "if") or
        std.mem.eql(u8, keyword, "then") or
        std.mem.eql(u8, keyword, "else") or
        std.mem.eql(u8, keyword, "allOf") or
        std.mem.eql(u8, keyword, "anyOf") or
        std.mem.eql(u8, keyword, "oneOf") or
        std.mem.eql(u8, keyword, "not") or
        (dialect == .draft_2020_12 and std.mem.eql(u8, keyword, "contentSchema"));
}
