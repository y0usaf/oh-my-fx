const std = @import("std");
const mcp_test_exports = @import("mcp_test_exports");

const json_schema = mcp_test_exports.JsonSchema;

const Allocator = std.mem.Allocator;

const Manifest = struct {
    revision: []const u8,
    groups: []const []const u8,
    proof_groups: []const []const u8,
    unsupported: []const Unsupported,
    draft7_groups: []const []const u8,
    draft7_proof_groups: []const []const u8,
    draft7_unsupported: []const Unsupported,
};

const Unsupported = struct {
    file: []const u8,
    group: []const u8,
    @"test": []const u8,
    reason: []const u8,
};

const Counts = struct {
    passed: usize = 0,
    allowed: usize = 0,
    unexpected: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedSuiteAndManifestPaths;
    const suite_root = std.mem.sliceTo(args[1], 0);
    const manifest_path = std.mem.sliceTo(args[2], 0);

    const manifest_json = try readFile(init.io, alloc, manifest_path, 4 * 1024 * 1024);
    defer alloc.free(manifest_json);
    var manifest = try std.json.parseFromSlice(Manifest, alloc, manifest_json, .{});
    defer manifest.deinit();
    if (manifest.value.revision.len != 40) return error.InvalidCorpusRevision;
    const current = try runSuite(
        init.io,
        alloc,
        suite_root,
        "draft2020-12",
        null,
        manifest.value.groups,
        manifest.value.proof_groups,
        manifest.value.unsupported,
    );
    const draft7 = try runSuite(
        init.io,
        alloc,
        suite_root,
        "draft7",
        "http://json-schema.org/draft-07/schema#",
        manifest.value.draft7_groups,
        manifest.value.draft7_proof_groups,
        manifest.value.draft7_unsupported,
    );
    const counts = Counts{
        .passed = current.passed + draft7.passed,
        .allowed = current.allowed + draft7.allowed,
        .unexpected = current.unexpected + draft7.unexpected,
    };
    try printLine(
        init.io,
        "JSON Schema corpus revision {s}: passed={d} allowed={d} unexpected={d}\n",
        .{
            manifest.value.revision,
            counts.passed,
            counts.allowed,
            counts.unexpected,
        },
    );
    if (counts.unexpected != 0) return error.JsonSchemaCorpusFailed;
}

fn runSuite(
    io: std.Io,
    alloc: Allocator,
    suite_root: []const u8,
    directory: []const u8,
    dialect_uri: ?[]const u8,
    groups: []const []const u8,
    proof_groups: []const []const u8,
    unsupported: []const Unsupported,
) !Counts {
    for (unsupported) |entry| {
        if (entry.file.len == 0 or entry.group.len == 0 or entry.@"test".len == 0 or
            entry.reason.len == 0)
        {
            return error.InvalidUnsupportedEntry;
        }
    }
    const used = try alloc.alloc(bool, unsupported.len);
    defer alloc.free(used);
    @memset(used, false);
    var counts = Counts{};
    for (groups) |relative_path| {
        const proof = containsString(proof_groups, relative_path);
        try runFile(
            io,
            alloc,
            suite_root,
            directory,
            dialect_uri,
            relative_path,
            unsupported,
            used,
            &counts,
            proof,
        );
    }
    for (proof_groups) |proof_group| {
        if (!containsString(groups, proof_group)) return error.MissingProofGroup;
    }
    var stale: usize = 0;
    for (unsupported, used) |entry, was_used| {
        if (was_used) continue;
        stale += 1;
        try printLine(io, "STALE ALLOWLIST {s}/{s} :: {s} :: {s} ({s})\n", .{
            directory,
            entry.file,
            entry.group,
            entry.@"test",
            entry.reason,
        });
    }
    try printLine(io, "SUITE {s}: passed={d} allowed={d} unexpected={d} stale={d}\n", .{
        directory,
        counts.passed,
        counts.allowed,
        counts.unexpected,
        stale,
    });
    if (stale != 0) return error.JsonSchemaCorpusFailed;
    return counts;
}

fn runFile(
    io: std.Io,
    alloc: Allocator,
    suite_root: []const u8,
    directory: []const u8,
    dialect_uri: ?[]const u8,
    relative_path: []const u8,
    unsupported: []const Unsupported,
    used: []bool,
    counts: *Counts,
    proof: bool,
) !void {
    var file_counts = Counts{};
    const path = try std.fs.path.join(alloc, &.{ suite_root, "tests", directory, relative_path });
    defer alloc.free(path);
    const contents = try readFile(io, alloc, path, 16 * 1024 * 1024);
    defer alloc.free(contents);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, contents, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidCorpusFile;

    for (parsed.value.array.items) |group_value| {
        if (group_value != .object) return error.InvalidCorpusFile;
        const group_description = requiredString(group_value.object, "description") orelse
            return error.InvalidCorpusFile;
        const schema = group_value.object.get("schema") orelse return error.InvalidCorpusFile;
        const tests = group_value.object.get("tests") orelse return error.InvalidCorpusFile;
        if (tests != .array) return error.InvalidCorpusFile;
        const schema_json = try stringifySchema(alloc, schema, dialect_uri);
        defer alloc.free(schema_json);

        for (tests.array.items) |test_value| {
            if (test_value != .object) return error.InvalidCorpusFile;
            const test_description = requiredString(test_value.object, "description") orelse
                return error.InvalidCorpusFile;
            const data = test_value.object.get("data") orelse return error.InvalidCorpusFile;
            const expected = test_value.object.get("valid") orelse return error.InvalidCorpusFile;
            if (expected != .bool) return error.InvalidCorpusFile;
            const data_json = try stringify(alloc, data);
            defer alloc.free(data_json);

            const actual = json_schema.validateText(
                alloc,
                schema_json,
                data_json,
                .{},
            );
            const matched = if (actual) |result|
                (result == .valid) == expected.bool
            else |_|
                false;
            if (matched) {
                counts.passed += 1;
                file_counts.passed += 1;
                continue;
            }
            if (findUnsupported(
                relative_path,
                group_description,
                test_description,
                unsupported,
            )) |index| {
                used[index] = true;
                counts.allowed += 1;
                file_counts.allowed += 1;
                continue;
            }

            counts.unexpected += 1;
            file_counts.unexpected += 1;
            if (actual) |result| {
                const actual_valid = result == .valid;
                try printLine(io, "UNEXPECTED {s} :: {s} :: {s} expected={any} actual={any}\n", .{
                    relative_path,
                    group_description,
                    test_description,
                    expected.bool,
                    actual_valid,
                });
            } else |err| {
                try printLine(io, "UNEXPECTED {s} :: {s} :: {s} expected={any} error={s}\n", .{
                    relative_path,
                    group_description,
                    test_description,
                    expected.bool,
                    @errorName(err),
                });
            }
        }
    }
    if (proof) {
        try printLine(io, "PROOF {s}: passed={d} allowed={d} unexpected={d}\n", .{
            relative_path,
            file_counts.passed,
            file_counts.allowed,
            file_counts.unexpected,
        });
    }
}

fn stringifySchema(
    alloc: Allocator,
    schema: std.json.Value,
    dialect_uri: ?[]const u8,
) ![]u8 {
    const uri = dialect_uri orelse return stringify(alloc, schema);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"$schema\":");
    try std.json.Stringify.value(uri, .{}, &out.writer);
    if (schema == .object) {
        var iterator = schema.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "$schema")) continue;
            try out.writer.writeByte(',');
            try std.json.Stringify.value(entry.key_ptr.*, .{}, &out.writer);
            try out.writer.writeByte(':');
            try std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer);
        }
    } else {
        try out.writer.writeAll(",\"allOf\":[");
        try std.json.Stringify.value(schema, .{}, &out.writer);
        try out.writer.writeByte(']');
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn findUnsupported(
    file: []const u8,
    group: []const u8,
    test_name: []const u8,
    unsupported: []const Unsupported,
) ?usize {
    for (unsupported, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.file, file)) continue;
        if (!std.mem.eql(u8, entry.group, "*") and !std.mem.eql(u8, entry.group, group)) continue;
        if (!std.mem.eql(u8, entry.@"test", "*") and
            !std.mem.eql(u8, entry.@"test", test_name)) continue;
        return index;
    }
    return null;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn stringify(alloc: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

fn readFile(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        path,
        alloc,
        .limited(max_bytes),
    );
}

fn printLine(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print(format, args);
    try stdout.interface.flush();
}
