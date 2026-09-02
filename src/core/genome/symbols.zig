//! Genome step 1: symbol extraction via tree-sitter.
//!
//! Port of empryo's intelligence/repo-map symbol layer, minus the indexing
//! machinery: parse a file's bytes with the language grammar, run one query,
//! return named symbols with byte ranges. Queries mirror empryo's QUERIES
//! table (src/core/intelligence/backends/tree-sitter.ts), recast so each
//! capture carries its own kind tag (@<kind>_name).

const std = @import("std");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

// Grammar entry points; not declared in any header, so declare here.
extern fn tree_sitter_typescript() callconv(.c) *const c.TSLanguage;
extern fn tree_sitter_tsx() callconv(.c) *const c.TSLanguage;
extern fn tree_sitter_python() callconv(.c) *const c.TSLanguage;
extern fn tree_sitter_go() callconv(.c) *const c.TSLanguage;
extern fn tree_sitter_rust() callconv(.c) *const c.TSLanguage;
extern fn tree_sitter_nix() callconv(.c) *const c.TSLanguage;
extern fn tree_sitter_zig() callconv(.c) *const c.TSLanguage;

pub const Language = enum { typescript, tsx, python, go, rust, nix, zig };

pub const SymbolKind = enum {
    function,
    method,
    class,
    interface,
    struct_,
    trait,
    type_alias,
    binding,
};

pub const Symbol = struct {
    /// Copied into `alloc`; NUL-free UTF-8 slice of the identifier.
    name: []const u8,
    kind: SymbolKind,
    start_byte: u32,
    end_byte: u32,
    /// 0-based row (line) of the declaration start.
    start_row: u32,
};

/// Detects language from a path extension. Unknown -> null.
pub fn detectLanguage(path: []const u8) ?Language {
    const ext = std.fs.path.extension(path);
    const map = std.StaticStringMap(Language).initComptime(.{
        .{ ".ts", .typescript },
        .{ ".mts", .typescript },
        .{ ".cts", .typescript },
        .{ ".tsx", .tsx },
        .{ ".py", .python },
        .{ ".pyi", .python },
        .{ ".go", .go },
        .{ ".rs", .rust },
        .{ ".nix", .nix },
        .{ ".zig", .zig },
    });
    return map.get(ext);
}

const QuerySpec = struct { query: [:0]const u8 };

const queries = std.enums.EnumMap(Language, QuerySpec).init(.{
    .typescript = .{ .query =
    \\(function_declaration name: (identifier) @function_name)
    \\(method_definition name: (property_identifier) @method_name)
    \\(class_declaration name: (type_identifier) @class_name)
    \\(interface_declaration name: (type_identifier) @interface_name)
    \\(type_alias_declaration name: (type_identifier) @type_alias_name)
    \\
    },
    // tsx reuses the typescript grammar shape; tsx-specific node kinds are
    // additive later. The typescript grammar parses .tsx fine for decls.
    .tsx = .{ .query =
    \\(function_declaration name: (identifier) @function_name)
    \\(method_definition name: (property_identifier) @method_name)
    \\(class_declaration name: (type_identifier) @class_name)
    \\(interface_declaration name: (type_identifier) @interface_name)
    \\(type_alias_declaration name: (type_identifier) @type_alias_name)
    \\
    },
    .python = .{ .query =
    \\(function_definition name: (identifier) @function_name)
    \\(class_definition name: (identifier) @class_name)
    \\(class_definition body: (block (function_definition name: (identifier) @method_name)))
    \\
    },
    .go = .{ .query =
    \\(function_declaration name: (identifier) @function_name)
    \\(method_declaration name: (field_identifier) @method_name)
    \\(type_spec name: (type_identifier) @type_alias_name)
    \\
    },
    .rust = .{ .query =
    \\(function_item name: (identifier) @function_name)
    \\((impl_item (declaration_list (function_item name: (identifier) @method_name))))
    \\(struct_item name: (type_identifier) @struct_name)
    \\(trait_item name: (type_identifier) @trait_name)
    \\(enum_item name: (type_identifier) @struct_name)
    \\(type_item name: (type_identifier) @type_alias_name)
    \\
    },
    .nix = .{ .query =
    \\(binding attrpath: (attrpath) @binding_name)
    \\(binding attrpath: (attrpath) @function_name expression: (function_expression))
    \\
    },
    .zig = .{ .query =
    \\(function_declaration name: (identifier) @function_name)
    \\(variable_declaration (identifier) @binding_name)
    \\
    },
});

fn tsLanguage(lang: Language) *const c.TSLanguage {
    return switch (lang) {
        .typescript => tree_sitter_typescript(),
        .tsx => tree_sitter_tsx(),
        .python => tree_sitter_python(),
        .go => tree_sitter_go(),
        .rust => tree_sitter_rust(),
        .nix => tree_sitter_nix(),
        .zig => tree_sitter_zig(),
    };
}

fn kindFromCapture(capture_name: []const u8) ?SymbolKind {
    const pairs = .{
        .{ "function_name", SymbolKind.function },
        .{ "method_name", SymbolKind.method },
        .{ "class_name", SymbolKind.class },
        .{ "interface_name", SymbolKind.interface },
        .{ "struct_name", SymbolKind.struct_ },
        .{ "trait_name", SymbolKind.trait },
        .{ "type_alias_name", SymbolKind.type_alias },
        .{ "binding_name", SymbolKind.binding },
    };
    inline for (pairs) |p| {
        if (std.mem.eql(u8, capture_name, p[0])) return p[1];
    }
    return null;
}

fn kindPriority(kind: SymbolKind) u8 {
    // When one node carries several captures (a rust impl method is both
    // function and method; a nix lambda binding is both binding and
    // function), the more specific kind wins regardless of match order.
    return switch (kind) {
        .binding => 0,
        .function => 1,
        .method, .class, .interface, .struct_, .trait, .type_alias => 2,
    };
}

/// Extracts symbols from `source`. Returned slice and all names live in
/// `alloc`. On query/parse failure returns an error rather than partial data.
pub fn extract(
    alloc: std.mem.Allocator,
    lang: Language,
    source: []const u8,
) ![]Symbol {
    if (source.len > std.math.maxInt(u32)) return error.SourceTooLarge;

    const parser = c.ts_parser_new() orelse return error.OutOfMemory;
    defer c.ts_parser_delete(parser);

    if (!c.ts_parser_set_language(parser, tsLanguage(lang))) {
        return error.LanguageVersionMismatch;
    }

    const tree = c.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse
        return error.ParseFailed;
    defer c.ts_tree_delete(tree);

    const qspec = queries.get(lang).?.query;
    var err_offset: u32 = undefined;
    var err_type: c_uint = undefined;
    const query = c.ts_query_new(
        tsLanguage(lang),
        qspec.ptr,
        @intCast(qspec.len),
        &err_offset,
        &err_type,
    ) orelse return error.QueryInvalid;
    defer c.ts_query_delete(query);

    // Map capture index -> kind once.
    const capture_count = c.ts_query_capture_count(query);
    const capture_kinds = try alloc.alloc(?SymbolKind, capture_count);
    defer alloc.free(capture_kinds);
    var ci: u32 = 0;
    while (ci < capture_count) : (ci += 1) {
        var len: u32 = 0;
        const cname = c.ts_query_capture_name_for_id(query, ci, &len);
        capture_kinds[ci] = kindFromCapture(cname[0..len]);
    }

    var out: std.ArrayListUnmanaged(Symbol) = .empty;
    errdefer {
        for (out.items) |symbol| alloc.free(@constCast(symbol.name));
        out.deinit(alloc);
    }

    const cursor = c.ts_query_cursor_new() orelse return error.OutOfMemory;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, query, c.ts_tree_root_node(tree));

    var match: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &match)) {
        var i: u32 = 0;
        while (i < match.capture_count) : (i += 1) {
            const cap = match.captures[i];
            const kind = capture_kinds[cap.index] orelse continue;
            const node = cap.node;
            const start = c.ts_node_start_byte(node);
            const end = c.ts_node_end_byte(node);
            if (start > end or end > source.len) continue;
            // A node can be captured by several patterns (a rust impl method
            // = function + method; a nix lambda binding = binding + function);
            // retain one entry and prefer the more specific kind.
            var duplicate = false;
            for (out.items) |*existing| {
                if (existing.start_byte == start and existing.end_byte == end) {
                    if (kindPriority(kind) > kindPriority(existing.kind)) existing.kind = kind;
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            const name = try alloc.dupe(u8, source[start..end]);
            errdefer alloc.free(name);
            try out.append(alloc, .{
                .name = name,
                .kind = kind,
                .start_byte = start,
                .end_byte = end,
                .start_row = c.ts_node_start_point(node).row,
            });
        }
    }

    return out.toOwnedSlice(alloc);
}
