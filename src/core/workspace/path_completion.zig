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
