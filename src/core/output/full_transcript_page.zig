const std = @import("std");

pub const max_source_entries: usize = 256;
pub const live_refresh_revision_stride: u64 = 8;

pub const Anchor = union(enum) {
    tail,
    entry_index: usize,
};

pub const Request = struct {
    content_revision: u64,
    cols: u16,
    anchor: Anchor,
};

pub const SourceRange = struct {
    start: usize,
    end: usize,

    pub fn len(self: SourceRange) usize {
        return self.end - self.start;
    }
};

pub fn sourceRange(request: Request, total_entries: usize) SourceRange {
    if (total_entries <= max_source_entries) {
        return .{ .start = 0, .end = total_entries };
    }

    const latest_start = total_entries - max_source_entries;
    const start = switch (request.anchor) {
        .tail => latest_start,
        .entry_index => |requested_index| blk: {
            const anchor_index = @min(requested_index, total_entries - 1);
            break :blk @min(anchor_index -| max_source_entries / 2, latest_start);
        },
    };
    return .{ .start = start, .end = start + max_source_entries };
}

pub fn sameRequest(lhs: Request, rhs: Request) bool {
    return lhs.content_revision == rhs.content_revision and
        lhs.cols == rhs.cols and
        std.meta.eql(lhs.anchor, rhs.anchor);
}

pub fn sameSurface(lhs: Request, rhs: Request) bool {
    return lhs.cols == rhs.cols and std.meta.eql(lhs.anchor, rhs.anchor);
}

pub fn liveRefreshDue(installed_revision: u64, current_revision: u64) bool {
    return current_revision -% installed_revision >= live_refresh_revision_stride;
}

pub fn previousAnchor(range: SourceRange) ?Anchor {
    if (range.start == 0) return null;
    return .{ .entry_index = range.start - 1 };
}

pub fn nextAnchor(range: SourceRange, total_entries: usize) ?Anchor {
    if (range.end >= total_entries) return null;
    return .{ .entry_index = range.end };
}






