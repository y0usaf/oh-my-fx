const std = @import("std");

const Allocator = std.mem.Allocator;

/// Maximum accepted glob pattern length in bytes.
pub const max_pattern_bytes: usize = 4096;

const max_pattern_segments: usize = max_pattern_bytes + 1;

/// Error set for compiling a borrowed glob pattern.
pub const CompileError = error{
    OutOfMemory,
    PatternTooLong,
};

/// Borrowed, pre-split glob pattern for matching workspace paths.
pub const Pattern = struct {
    raw: []const u8,
    segments: []const []const u8,
    has_path_separator: bool,

    /// Compiles a borrowed pattern. Caller owns the segment slice and releases it with deinit.
    pub fn compile(alloc: Allocator, raw: []const u8) CompileError!Pattern {
        if (raw.len > max_pattern_bytes) return error.PatternTooLong;

        const has_path_separator = std.mem.findScalar(u8, raw, '/') != null;
        if (!has_path_separator) {
            return .{
                .raw = raw,
                .segments = &.{},
                .has_path_separator = false,
            };
        }

        var segments: std.ArrayList([]const u8) = .empty;
        errdefer segments.deinit(alloc);
        try appendSegments(alloc, raw, &segments);
        return .{
            .raw = raw,
            .segments = try segments.toOwnedSlice(alloc),
            .has_path_separator = true,
        };
    }

    /// Frees the owned segment slice. The raw pattern bytes are borrowed.
    pub fn deinit(self: *Pattern, alloc: Allocator) void {
        if (self.has_path_separator) alloc.free(self.segments);
        self.* = .{
            .raw = "",
            .segments = &.{},
            .has_path_separator = false,
        };
    }

    /// Returns true when the pattern matches a path. Patterns without slash match the basename.
    pub fn matchesPath(self: Pattern, candidate_path: []const u8) bool {
        if (!self.has_path_separator) {
            return matchSegment(self.raw, std.fs.path.basename(candidate_path));
        }
        return matchSegmented(self.segments, candidate_path);
    }

    /// Returns true when a slash-free pattern matches a single basename.
    pub fn matchesBasename(self: Pattern, basename: []const u8) bool {
        if (self.has_path_separator) return false;
        return matchSegment(self.raw, basename);
    }
};

fn appendSegments(alloc: Allocator, path: []const u8, segments: *std.ArrayList([]const u8)) Allocator.Error!void {
    var rest = path;
    while (rest.len > 0) {
        const slash = std.mem.findScalar(u8, rest, '/') orelse {
            try segments.append(alloc, rest);
            return;
        };
        try segments.append(alloc, rest[0..slash]);
        rest = rest[slash + 1 ..];
    }
}

fn matchSegmented(pattern_segments: []const []const u8, candidate_path: []const u8) bool {
    const segment_count = pattern_segments.len;
    std.debug.assert(segment_count <= max_pattern_segments);

    var previous: [max_pattern_segments + 1]bool = [_]bool{false} ** (max_pattern_segments + 1);
    var current: [max_pattern_segments + 1]bool = [_]bool{false} ** (max_pattern_segments + 1);

    previous[0] = true;
    for (pattern_segments, 0..) |segment, index| {
        previous[index + 1] = previous[index] and isDoubleStar(segment);
    }

    var candidate_it = SegmentIterator.init(candidate_path);
    while (candidate_it.next()) |candidate_segment| {
        @memset(current[0 .. segment_count + 1], false);
        for (pattern_segments, 0..) |pattern_segment, index| {
            current[index + 1] = if (isDoubleStar(pattern_segment))
                current[index] or previous[index + 1]
            else
                previous[index] and matchSegment(pattern_segment, candidate_segment);
        }
        @memcpy(previous[0 .. segment_count + 1], current[0 .. segment_count + 1]);
    }

    return previous[segment_count];
}

const SegmentIterator = struct {
    rest: []const u8,

    fn init(path: []const u8) SegmentIterator {
        return .{ .rest = path };
    }

    fn next(self: *SegmentIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const slash = std.mem.findScalar(u8, self.rest, '/') orelse {
            const segment = self.rest;
            self.rest = "";
            return segment;
        };
        const segment = self.rest[0..slash];
        self.rest = self.rest[slash + 1 ..];
        return segment;
    }
};

fn isDoubleStar(segment: []const u8) bool {
    return std.mem.eql(u8, segment, "**");
}

fn matchSegment(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var star_pattern_index: ?usize = null;
    var star_candidate_index: usize = 0;

    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len) {
            const token = pattern[pattern_index];
            if (token == '*') {
                while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
                    pattern_index += 1;
                }
                if (pattern_index == pattern.len) return true;
                star_pattern_index = pattern_index;
                star_candidate_index = candidate_index;
                continue;
            }
            if (token == '?' or token == candidate[candidate_index]) {
                if (candidate[candidate_index] == '/') return false;
                pattern_index += 1;
                candidate_index += 1;
                continue;
            }
        }

        const retry_pattern_index = star_pattern_index orelse return false;
        star_candidate_index += 1;
        candidate_index = star_candidate_index;
        pattern_index = retry_pattern_index;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

fn expectCompiledMatch(pattern: []const u8, candidate_path: []const u8, expected: bool) !void {
    var compiled = try Pattern.compile(std.testing.allocator, pattern);
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, compiled.matchesPath(candidate_path));
}





