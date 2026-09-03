const std = @import("std");
const builtin = @import("builtin");
const file_picker_path = @import("../input/file_picker_path.zig");
const file_index = @import("file_index.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("pathing.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const QueryMode = enum {
    workspace_index,
    explicit_path,
};

pub const Error = error{
    NoSpaceLeft,
    PathUnavailable,
};

const ParsedQuery = struct {
    parent: []const u8,
    display_prefix: []const u8,
    basename_prefix: []const u8,
};

pub fn queryMode(query: []const u8) QueryMode {
    for (query) |byte| {
        if (std.fs.path.isSep(byte)) return .explicit_path;
    }
    return .workspace_index;
}

pub fn complete(
    workspace_root: []const u8,
    query: []const u8,
    out: []file_index.SearchResult,
    match_spans: []file_index.MatchSpan,
    path_storage: []u8,
) Error!usize {
    if (out.len == 0) return 0;
    const parsed = parseExplicitQuery(query) orelse return 0;
    const slot_len: usize = file_index.max_path_len;
    if (out.len > path_storage.len / slot_len) return error.NoSpaceLeft;

    var resolve_storage: [file_index.max_path_len * 4]u8 = undefined;
    var resolve_fba = std.heap.FixedBufferAllocator.init(&resolve_storage);
    const resolved = pathing.resolveWorkspaceOrExternalPath(
        resolve_fba.allocator(),
        workspace_root,
        parsed.parent,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.NoSpaceLeft,
        else => return error.PathUnavailable,
    };

    const io = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(io, resolved, .{ .iterate = true }) catch return error.PathUnavailable;
    defer dir.close(io);

    var count: usize = 0;
    var iterator = dir.iterate();
    while (iterator.next(io) catch return error.PathUnavailable) |entry| {
        if (!std.ascii.startsWithIgnoreCase(entry.name, parsed.basename_prefix)) continue;
        if (!text_utils.isTerminalSafe(entry.name)) continue;
        const kind = candidateKind(&dir, entry.name, entry.kind) orelse continue;

        var candidate_storage: [file_index.max_path_len]u8 = undefined;
        const candidate_len = parsed.display_prefix.len + entry.name.len;
        if (candidate_len > candidate_storage.len) continue;
        @memcpy(candidate_storage[0..parsed.display_prefix.len], parsed.display_prefix);
        @memcpy(candidate_storage[parsed.display_prefix.len..candidate_len], entry.name);
        const candidate = candidate_storage[0..candidate_len];
        if (!text_utils.isTerminalSafe(candidate)) continue;
        if (!file_picker_path.isRepresentable(candidate)) continue;
        count = insertCandidate(out, path_storage, count, candidate, kind);
    }

    var spans_used: usize = 0;
    for (out[0..count]) |*result| {
        if (parsed.basename_prefix.len == 0) {
            result.matched_spans = match_spans[0..0];
            continue;
        }
        if (spans_used >= match_spans.len) return error.NoSpaceLeft;
        match_spans[spans_used] = .{
            .byte_start = @intCast(parsed.display_prefix.len),
            .byte_end = @intCast(parsed.display_prefix.len + parsed.basename_prefix.len),
        };
        result.matched_spans = match_spans[spans_used .. spans_used + 1];
        spans_used += 1;
    }
    return count;
}

pub fn isCurrentCandidateKind(
    workspace_root: []const u8,
    path: []const u8,
    expected_kind: file_index.CandidateKind,
) bool {
    if (!text_utils.isTerminalSafe(path)) return false;

    var resolve_storage: [file_index.max_path_len * 4]u8 = undefined;
    var resolve_fba = std.heap.FixedBufferAllocator.init(&resolve_storage);
    const resolved = pathing.resolveWorkspaceOrExternalPath(
        resolve_fba.allocator(),
        workspace_root,
        path,
    ) catch return false;
    const stat = std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        resolved,
        .{ .follow_symlinks = true },
    ) catch return false;
    return kindMatchesStat(expected_kind, stat.kind);
}

fn parseExplicitQuery(query: []const u8) ?ParsedQuery {
    var separator_index: ?usize = null;
    for (query, 0..) |byte, index| {
        if (std.fs.path.isSep(byte)) separator_index = index;
    }
    const separator = separator_index orelse return null;
    const parent = if (separator == 0) query[0..1] else query[0..separator];
    return .{
        .parent = parent,
        .display_prefix = query[0 .. separator + 1],
        .basename_prefix = query[separator + 1 ..],
    };
}

fn candidateKind(
    dir: *std.Io.Dir,
    name: []const u8,
    observed_kind: std.Io.File.Kind,
) ?file_index.CandidateKind {
    return switch (observed_kind) {
        .file => .file,
        .directory => .directory,
        .sym_link, .unknown => {
            const stat = dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = true }) catch return null;
            return kindFromStat(stat.kind);
        },
        else => null,
    };
}

fn kindFromStat(kind: std.Io.File.Kind) ?file_index.CandidateKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        else => null,
    };
}

fn kindMatchesStat(expected: file_index.CandidateKind, actual: std.Io.File.Kind) bool {
    return switch (expected) {
        .file => actual == .file,
        .directory => actual == .directory,
    };
}

fn insertCandidate(
    out: []file_index.SearchResult,
    path_storage: []u8,
    count: usize,
    path: []const u8,
    kind: file_index.CandidateKind,
) usize {
    var insertion_index: usize = 0;
    while (insertion_index < count and std.mem.order(u8, path, out[insertion_index].path) != .lt) : (insertion_index += 1) {}
    if (insertion_index >= out.len) return count;

    const next_count = @min(count + 1, out.len);
    var index = next_count - 1;
    while (index > insertion_index) : (index -= 1) {
        const previous = out[index - 1];
        const slot = pathSlot(path_storage, index);
        @memcpy(slot[0..previous.path.len], previous.path);
        out[index] = .{
            .path = slot[0..previous.path.len],
            .kind = previous.kind,
            .matched_spans = &.{},
        };
    }

    const slot = pathSlot(path_storage, insertion_index);
    @memcpy(slot[0..path.len], path);
    out[insertion_index] = .{
        .path = slot[0..path.len],
        .kind = kind,
        .matched_spans = &.{},
    };
    return next_count;
}

fn pathSlot(storage: []u8, index: usize) []u8 {
    const slot_len: usize = file_index.max_path_len;
    const start = index * slot_len;
    return storage[start .. start + slot_len];
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    var file = try dir.createFile(std.testing.io, path, .{ .truncate = true });
    file.close(std.testing.io);
}

test "path completion classifies and splits only path-shaped queries" {
    try std.testing.expectEqual(QueryMode.workspace_index, queryMode("main"));
    try std.testing.expectEqual(QueryMode.workspace_index, queryMode("~"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("~/Dow"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("/tmp/fi"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("./src/"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("../shared/"));
    try std.testing.expectEqual(QueryMode.explicit_path, queryMode("src/core/"));

    const parsed = parseExplicitQuery("../shared/na").?;
    try std.testing.expectEqualStrings("../shared", parsed.parent);
    try std.testing.expectEqualStrings("../shared/", parsed.display_prefix);
    try std.testing.expectEqualStrings("na", parsed.basename_prefix);
}

test "path completion enumerates immediate entries with deterministic bounded order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/src/empty");
    try tmp.dir.createDirPath(std.testing.io, "workspace/src/nested/deeper");
    try writeTestFile(tmp.dir, "workspace/src/zeta.txt");
    try writeTestFile(tmp.dir, "workspace/src/Alpha.txt");
    try writeTestFile(tmp.dir, "workspace/src/beta.txt");
    try writeTestFile(tmp.dir, "workspace/src/.hidden.txt");
    try writeTestFile(tmp.dir, "workspace/src/space \" file.txt");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    var results: [3]file_index.SearchResult = undefined;
    var spans: [3]file_index.MatchSpan = undefined;
    var paths: [3 * file_index.max_path_len]u8 = undefined;

    const count = try complete(root, "./src/", &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("./src/.hidden.txt", results[0].path);
    try std.testing.expectEqualStrings("./src/Alpha.txt", results[1].path);
    try std.testing.expectEqualStrings("./src/beta.txt", results[2].path);

    const filtered_count = try complete(root, "src/al", &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 1), filtered_count);
    try std.testing.expectEqualStrings("src/Alpha.txt", results[0].path);
    try std.testing.expectEqual(file_index.CandidateKind.file, results[0].kind);
    try std.testing.expectEqual(@as(usize, 1), results[0].matched_spans.len);
    try std.testing.expectEqual(@as(u16, "src/".len), results[0].matched_spans[0].byte_start);
    try std.testing.expectEqual(@as(u16, "src/al".len), results[0].matched_spans[0].byte_end);
    try std.testing.expectEqual(@as(usize, 0), try complete(root, "src/space", &results, &spans, &paths));
}

test "path completion resolves parent and absolute forms without recursive traversal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    try tmp.dir.createDirPath(std.testing.io, "outside/empty");
    try writeTestFile(tmp.dir, "outside/external.txt");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside");
    defer alloc.free(outside);

    var results: [8]file_index.SearchResult = undefined;
    var spans: [8]file_index.MatchSpan = undefined;
    var paths: [8 * file_index.max_path_len]u8 = undefined;
    const parent_count = try complete(root, "../outside/", &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 2), parent_count);
    try std.testing.expectEqualStrings("../outside/empty", results[0].path);
    try std.testing.expectEqual(file_index.CandidateKind.directory, results[0].kind);
    try std.testing.expectEqualStrings("../outside/external.txt", results[1].path);

    var absolute_query_storage: [file_index.max_path_len]u8 = undefined;
    const absolute_query = try std.fmt.bufPrint(&absolute_query_storage, "{s}/ex", .{outside});
    const absolute_count = try complete(root, absolute_query, &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 1), absolute_count);
    var expected_storage: [file_index.max_path_len]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_storage, "{s}/external.txt", .{outside});
    try std.testing.expectEqualStrings(expected, results[0].path);
}

test "path completion follows listed symlinks and filters unsafe names" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/target-dir");
    try writeTestFile(tmp.dir, "workspace/target.txt");
    try writeTestFile(tmp.dir, "workspace/unsafe-\x1b.txt");
    try tmp.dir.symLink(std.testing.io, "target-dir", "workspace/linked-dir", .{ .is_directory = true });
    try tmp.dir.symLink(std.testing.io, "target.txt", "workspace/linked-file", .{ .is_directory = false });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var results: [4]file_index.SearchResult = undefined;
    var spans: [4]file_index.MatchSpan = undefined;
    var paths: [4 * file_index.max_path_len]u8 = undefined;
    const count = try complete(root, "./linked", &results, &spans, &paths);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(file_index.CandidateKind.directory, results[0].kind);
    try std.testing.expectEqual(file_index.CandidateKind.file, results[1].kind);
    try std.testing.expectEqual(@as(usize, 0), try complete(root, "./unsafe", &results, &spans, &paths));
}

test "path completion reports bounded storage and unavailable parents" {
    var results: [1]file_index.SearchResult = undefined;
    var spans: [1]file_index.MatchSpan = undefined;
    var too_small: [file_index.max_path_len - 1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, complete("/", "./", &results, &spans, &too_small));

    var paths: [file_index.max_path_len]u8 = undefined;
    try std.testing.expectError(error.PathUnavailable, complete("/", "/definitely/missing/fx-path/", &results, &spans, &paths));
}

test "path completion validates the current explicit candidate kind" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/folder");
    try writeTestFile(tmp.dir, "workspace/file.txt");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    try std.testing.expect(isCurrentCandidateKind(root, "./folder", .directory));
    try std.testing.expect(!isCurrentCandidateKind(root, "./folder", .file));
    try std.testing.expect(isCurrentCandidateKind(root, "./file.txt", .file));
    try std.testing.expect(!isCurrentCandidateKind(root, "./missing", .file));
}
