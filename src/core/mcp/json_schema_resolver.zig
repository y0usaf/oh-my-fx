const std = @import("std");

const Allocator = std.mem.Allocator;

const synthetic_root_uri = "fx-schema:/root";

pub const Dialect = enum {
    draft_2020_12,
    draft_7,
};

pub const Limits = struct {
    max_depth: usize,
    max_nodes: usize,
    max_uri_bytes: usize,
};

pub const Error = error{
    InvalidSchema,
    SchemaLimitExceeded,
    ExternalReference,
    UnresolvedReference,
} || Allocator.Error || std.Io.Writer.Error;

pub const AnchorKind = enum {
    static,
    dynamic,
};

pub const Resolved = struct {
    schema: std.json.Value,
    resource_index: usize,
    anchor_kind: ?AnchorKind = null,
    anchor_name: ?[]const u8 = null,
};

const Resource = struct {
    uri: []u8,
    schema: std.json.Value,
};

const Anchor = struct {
    resource_index: usize,
    name: []const u8,
    schema: std.json.Value,
    kind: AnchorKind,
};

pub const Resolver = struct {
    alloc: Allocator,
    dialect: Dialect,
    limits: Limits,
    resources: std.ArrayList(Resource) = .empty,
    anchors: std.ArrayList(Anchor) = .empty,
    indexed_nodes: usize = 0,

    pub fn init(
        alloc: Allocator,
        root: std.json.Value,
        dialect: Dialect,
        limits: Limits,
    ) Error!Resolver {
        var self = Resolver{
            .alloc = alloc,
            .dialect = dialect,
            .limits = limits,
        };
        errdefer self.deinit();

        const root_uri = if (self.schemaId(root)) |id|
            try self.resolveIdentifier(synthetic_root_uri, id)
        else
            try alloc.dupe(u8, synthetic_root_uri);
        self.resources.append(alloc, .{ .uri = root_uri, .schema = root }) catch |err| {
            alloc.free(root_uri);
            return err;
        };
        try self.indexSchema(root, 0, 0, true);
        return self;
    }

    pub fn deinit(self: *Resolver) void {
        for (self.resources.items) |resource| self.alloc.free(resource.uri);
        self.resources.deinit(self.alloc);
        self.anchors.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn rootResource(self: *const Resolver) usize {
        _ = self;
        return 0;
    }

    pub fn enterResource(
        self: *const Resolver,
        schema: std.json.Value,
        inherited_resource: usize,
    ) Error!usize {
        if (schema != .object or self.schemaId(schema) == null or
            (self.dialect == .draft_7 and schema.object.get("$ref") != null))
        {
            return inherited_resource;
        }
        for (self.resources.items, 0..) |resource, index| {
            if (sameObject(schema, resource.schema)) return index;
        }
        if (self.dialect == .draft_7 and hasPlainNameIdentifier(schema)) {
            return inherited_resource;
        }
        return error.InvalidSchema;
    }

    pub fn resolve(
        self: *const Resolver,
        current_resource: usize,
        reference: []const u8,
    ) Error!Resolved {
        if (current_resource >= self.resources.items.len) return error.InvalidSchema;
        const absolute = try resolveUri(
            self.alloc,
            self.resources.items[current_resource].uri,
            reference,
            self.limits.max_uri_bytes,
        );
        defer self.alloc.free(absolute);
        const parts = splitUri(absolute);
        const resource_index = self.findResource(parts.document) orelse
            return error.ExternalReference;
        const resource = self.resources.items[resource_index];
        if (parts.fragment == null or parts.fragment.?.len == 0) {
            return .{ .schema = resource.schema, .resource_index = resource_index };
        }
        const fragment = parts.fragment.?;
        if (fragment[0] == '/') {
            return .{
                .schema = try resolvePointer(self.alloc, resource.schema, fragment, self.limits),
                .resource_index = resource_index,
            };
        }
        const decoded = try percentDecode(self.alloc, fragment);
        defer self.alloc.free(decoded);
        for (self.anchors.items) |anchor| {
            if (anchor.resource_index == resource_index and
                std.mem.eql(u8, anchor.name, decoded))
            {
                return .{
                    .schema = anchor.schema,
                    .resource_index = resource_index,
                    .anchor_kind = anchor.kind,
                    .anchor_name = anchor.name,
                };
            }
        }
        return error.UnresolvedReference;
    }

    pub fn dynamicAnchor(
        self: *const Resolver,
        resource_index: usize,
        name: []const u8,
    ) ?std.json.Value {
        for (self.anchors.items) |anchor| {
            if (anchor.resource_index == resource_index and
                anchor.kind == .dynamic and
                std.mem.eql(u8, anchor.name, name))
            {
                return anchor.schema;
            }
        }
        return null;
    }

    fn indexSchema(
        self: *Resolver,
        schema: std.json.Value,
        inherited_resource: usize,
        depth: usize,
        is_resource_root: bool,
    ) Error!void {
        if (depth > self.limits.max_depth) return error.SchemaLimitExceeded;
        self.indexed_nodes = std.math.add(usize, self.indexed_nodes, 1) catch
            return error.SchemaLimitExceeded;
        if (self.indexed_nodes > self.limits.max_nodes) return error.SchemaLimitExceeded;
        if (schema != .object) return;

        if (self.dialect == .draft_7 and schema.object.get("$ref") != null) {
            return;
        }

        var resource_index = inherited_resource;
        if (!is_resource_root) {
            if (self.schemaId(schema)) |id| {
                const uri = try self.resolveIdentifier(
                    self.resources.items[inherited_resource].uri,
                    id,
                );
                if (std.mem.eql(u8, uri, self.resources.items[inherited_resource].uri) and
                    self.dialect == .draft_7 and hasPlainNameIdentifier(schema))
                {
                    self.alloc.free(uri);
                } else {
                    if (self.findResource(uri) != null) {
                        self.alloc.free(uri);
                        return error.InvalidSchema;
                    }
                    self.resources.append(self.alloc, .{ .uri = uri, .schema = schema }) catch |err| {
                        self.alloc.free(uri);
                        return err;
                    };
                    resource_index = self.resources.items.len - 1;
                }
            }
        }

        switch (self.dialect) {
            .draft_2020_12 => {
                try self.indexAnchor(schema, resource_index, "$anchor", .static);
                try self.indexAnchor(schema, resource_index, "$dynamicAnchor", .dynamic);
            },
            .draft_7 => try self.indexIdentifierAnchor(schema, resource_index),
        }

        var iterator = schema.object.iterator();
        while (iterator.next()) |entry| {
            if (!keywordContainsSchemas(self.dialect, entry.key_ptr.*)) continue;
            switch (entry.value_ptr.*) {
                .object => |object| {
                    if (keywordContainsSchemaMap(self.dialect, entry.key_ptr.*)) {
                        var children = object.iterator();
                        while (children.next()) |child| {
                            if (self.dialect == .draft_7 and
                                std.mem.eql(u8, entry.key_ptr.*, "dependencies") and
                                child.value_ptr.* == .array)
                            {
                                continue;
                            }
                            try self.indexSchema(child.value_ptr.*, resource_index, depth + 1, false);
                        }
                    } else {
                        try self.indexSchema(entry.value_ptr.*, resource_index, depth + 1, false);
                    }
                },
                .array => |array| for (array.items) |child| {
                    try self.indexSchema(child, resource_index, depth + 1, false);
                },
                .bool => try self.indexSchema(entry.value_ptr.*, resource_index, depth + 1, false),
                else => {},
            }
        }
    }

    fn indexAnchor(
        self: *Resolver,
        schema: std.json.Value,
        resource_index: usize,
        keyword: []const u8,
        kind: AnchorKind,
    ) Error!void {
        const value = schema.object.get(keyword) orelse return;
        if (value != .string or !validAnchorName(value.string)) return error.InvalidSchema;
        for (self.anchors.items) |anchor| {
            if (anchor.resource_index == resource_index and
                std.mem.eql(u8, anchor.name, value.string))
            {
                return error.InvalidSchema;
            }
        }
        try self.anchors.append(self.alloc, .{
            .resource_index = resource_index,
            .name = value.string,
            .schema = schema,
            .kind = kind,
        });
    }

    fn indexIdentifierAnchor(
        self: *Resolver,
        schema: std.json.Value,
        resource_index: usize,
    ) Error!void {
        const id = self.schemaId(schema) orelse return;
        const hash = std.mem.findScalar(u8, id, '#') orelse return;
        const name = id[hash + 1 ..];
        if (name.len == 0) return;
        if (!validAnchorName(name)) return error.InvalidSchema;
        for (self.anchors.items) |anchor| {
            if (anchor.resource_index == resource_index and
                std.mem.eql(u8, anchor.name, name))
            {
                return error.InvalidSchema;
            }
        }
        try self.anchors.append(self.alloc, .{
            .resource_index = resource_index,
            .name = name,
            .schema = schema,
            .kind = .static,
        });
    }

    fn resolveIdentifier(
        self: *const Resolver,
        base: []const u8,
        identifier: []const u8,
    ) Error![]u8 {
        const absolute = try resolveUri(self.alloc, base, identifier, self.limits.max_uri_bytes);
        errdefer self.alloc.free(absolute);
        const parts = splitUri(absolute);
        if (parts.fragment) |fragment| if (fragment.len != 0) {
            if (self.dialect != .draft_7 or !validAnchorName(fragment)) {
                return error.InvalidSchema;
            }
        };
        if (parts.document.len == absolute.len) return absolute;
        const document = try self.alloc.dupe(u8, parts.document);
        self.alloc.free(absolute);
        return document;
    }

    fn findResource(self: *const Resolver, uri: []const u8) ?usize {
        for (self.resources.items, 0..) |resource, index| {
            if (std.mem.eql(u8, resource.uri, uri)) return index;
        }
        return null;
    }

    fn schemaId(self: *const Resolver, schema: std.json.Value) ?[]const u8 {
        if (schema != .object) return null;
        if (self.dialect == .draft_7 and schema.object.get("$ref") != null) return null;
        const id = schema.object.get("$id") orelse return null;
        return if (id == .string) id.string else null;
    }
};

const UriParts = struct {
    document: []const u8,
    fragment: ?[]const u8,
};

fn splitUri(uri: []const u8) UriParts {
    const hash = std.mem.findScalar(u8, uri, '#') orelse
        return .{ .document = uri, .fragment = null };
    return .{ .document = uri[0..hash], .fragment = uri[hash + 1 ..] };
}

fn resolveUri(
    alloc: Allocator,
    base_text: []const u8,
    reference: []const u8,
    max_uri_bytes: usize,
) Error![]u8 {
    if (base_text.len > max_uri_bytes or reference.len > max_uri_bytes) {
        return error.SchemaLimitExceeded;
    }
    const base = std.Uri.parse(base_text) catch return error.InvalidSchema;
    const capacity = std.math.add(usize, base_text.len, reference.len) catch
        return error.SchemaLimitExceeded;
    const storage = try alloc.alloc(u8, std.math.add(usize, capacity, 2) catch
        return error.SchemaLimitExceeded);
    defer alloc.free(storage);
    @memcpy(storage[0..reference.len], reference);
    var remaining = storage;
    const resolved = base.resolveInPlace(reference.len, &remaining) catch
        return error.InvalidSchema;
    const rendered = try std.fmt.allocPrint(alloc, "{f}", .{resolved.fmt(.all)});
    errdefer alloc.free(rendered);
    if (rendered.len > max_uri_bytes) return error.SchemaLimitExceeded;
    return rendered;
}

fn resolvePointer(
    alloc: Allocator,
    resource: std.json.Value,
    fragment: []const u8,
    limits: Limits,
) Error!std.json.Value {
    var current = resource;
    var segments = std.mem.splitScalar(u8, fragment[1..], '/');
    var count: usize = 0;
    while (segments.next()) |raw_segment| {
        count = std.math.add(usize, count, 1) catch return error.SchemaLimitExceeded;
        if (count > limits.max_depth) return error.SchemaLimitExceeded;
        const decoded_percent = try percentDecode(alloc, raw_segment);
        defer alloc.free(decoded_percent);
        const segment = try decodePointerSegment(alloc, decoded_percent);
        defer alloc.free(segment);
        current = switch (current) {
            .object => |object| object.get(segment) orelse return error.UnresolvedReference,
            .array => |array| blk: {
                if (segment.len > 1 and segment[0] == '0') return error.UnresolvedReference;
                const index = std.fmt.parseInt(usize, segment, 10) catch
                    return error.UnresolvedReference;
                if (index >= array.items.len) return error.UnresolvedReference;
                break :blk array.items[index];
            },
            else => return error.UnresolvedReference,
        };
    }
    return current;
}

fn percentDecode(alloc: Allocator, raw: []const u8) Error![]u8 {
    const decoded = try alloc.dupe(u8, raw);
    errdefer alloc.free(decoded);
    var read: usize = 0;
    var write: usize = 0;
    while (read < raw.len) {
        if (raw[read] == '%') {
            if (read + 2 >= raw.len) return error.UnresolvedReference;
            decoded[write] = std.fmt.parseInt(u8, raw[read + 1 .. read + 3], 16) catch
                return error.UnresolvedReference;
            read += 3;
        } else {
            decoded[write] = raw[read];
            read += 1;
        }
        write += 1;
    }
    return try alloc.realloc(decoded, write);
}

fn decodePointerSegment(alloc: Allocator, raw: []const u8) Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] != '~') {
            try output.append(alloc, raw[index]);
            index += 1;
            continue;
        }
        if (index + 1 >= raw.len) return error.UnresolvedReference;
        try output.append(alloc, switch (raw[index + 1]) {
            '0' => '~',
            '1' => '/',
            else => return error.UnresolvedReference,
        });
        index += 2;
    }
    return try output.toOwnedSlice(alloc);
}

fn hasPlainNameIdentifier(schema: std.json.Value) bool {
    if (schema != .object) return false;
    const id = schema.object.get("$id") orelse return false;
    if (id != .string) return false;
    const hash = std.mem.findScalar(u8, id.string, '#') orelse return false;
    return id.string[hash + 1 ..].len != 0;
}

fn sameObject(left: std.json.Value, right: std.json.Value) bool {
    if (left != .object or right != .object) return false;
    if (left.object.count() == 0 or right.object.count() == 0) return false;
    return left.object.keys().ptr == right.object.keys().ptr;
}

fn validAnchorName(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.' and byte != ':') {
            return false;
        }
    }
    return true;
}

fn keywordContainsSchemaMap(dialect: Dialect, keyword: []const u8) bool {
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
    if (keywordContainsSchemaMap(dialect, keyword)) return true;
    if (dialect == .draft_2020_12 and
        (std.mem.eql(u8, keyword, "prefixItems") or
            std.mem.eql(u8, keyword, "unevaluatedItems") or
            std.mem.eql(u8, keyword, "unevaluatedProperties")))
    {
        return true;
    }
    if (dialect == .draft_7 and std.mem.eql(u8, keyword, "additionalItems")) return true;
    return std.mem.eql(u8, keyword, "items") or
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

test "resolver scopes anchors to resources and resolves RFC 3986 relative identifiers" {
    const schema_json =
        \\{
        \\  "$id":"https://example.test/schemas/root.json",
        \\  "$anchor":"value",
        \\  "$defs":{
        \\    "inner":{"$id":"nested/inner.json","$anchor":"value","type":"integer"},
        \\    "other":{"$id":"nested/dir/other.json","$ref":"../inner.json#value"}
        \\  }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema_json, .{});
    defer parsed.deinit();
    var resolver = try Resolver.init(std.testing.allocator, parsed.value, .draft_2020_12, .{
        .max_depth = 64,
        .max_nodes = 1024,
        .max_uri_bytes = 64 * 1024,
    });
    defer resolver.deinit();

    const other = try resolver.resolve(0, "nested/dir/other.json");
    const inner = try resolver.resolve(other.resource_index, "../inner.json#value");
    try std.testing.expectEqual(AnchorKind.static, inner.anchor_kind.?);
    try std.testing.expect(inner.schema.object.get("type") != null);
    const root_anchor = try resolver.resolve(0, "#value");
    try std.testing.expect(!sameObject(root_anchor.schema, inner.schema));
}

test "resolver rejects unregistered external documents without I/O" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"$id\":\"https://example.test/root\"}",
        .{},
    );
    defer parsed.deinit();
    var resolver = try Resolver.init(std.testing.allocator, parsed.value, .draft_2020_12, .{
        .max_depth = 64,
        .max_nodes = 1024,
        .max_uri_bytes = 64 * 1024,
    });
    defer resolver.deinit();
    try std.testing.expectError(
        error.ExternalReference,
        resolver.resolve(0, "https://example.test/external"),
    );
}
