const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Content digest recorded for a file read by the current session.
pub const ContentHash = types.ContentHash;

/// Snapshot of a file at the moment an agent-visible read succeeded.
/// Tracks model-visible coverage separately from full-file freshness coverage so
/// tools can enforce the stricter invariant only where whole-file model context matters.
pub const Record = struct {
    mtime_ns: i128,
    content_hash: ContentHash,
    /// True iff the model-visible read returned the entire file content
    /// (no display cap hit, no start_line/line_count narrowing).
    model_view_covers_full_file: bool,
    /// True iff content_hash was computed over the entire file on disk
    /// at read time (independent of what the model saw).
    snapshot_covers_full_file: bool,
};

/// Session-scoped in-memory index of files read by the agent.
pub const ReadTracker = struct {
    alloc: Allocator,
    entries: std.StringHashMap(Record),

    /// Initializes an empty tracker. Call deinit to free owned path keys.
    pub fn init(alloc: Allocator) ReadTracker {
        return .{
            .alloc = alloc,
            .entries = std.StringHashMap(Record).init(alloc),
        };
    }

    /// Records a snapshot for path, replacing any previous record.
    pub fn record(self: *ReadTracker, path: []const u8, value: Record) Allocator.Error!void {
        const owned_path = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned_path);

        const entry = try self.entries.getOrPut(owned_path);
        if (entry.found_existing) {
            self.alloc.free(owned_path);
        }
        entry.value_ptr.* = value;
    }

    /// Returns the snapshot for path, if the session has one.
    pub fn lookup(self: *const ReadTracker, path: []const u8) ?Record {
        return self.entries.get(path);
    }

    /// Frees all owned path keys and map storage.
    pub fn deinit(self: *ReadTracker) void {
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| self.alloc.free(key.*);
        self.entries.deinit();
        self.* = undefined;
    }
};

/// Computes the content hash used by read-before-overwrite checks.
pub fn contentHash(bytes: []const u8) ContentHash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(bytes);
    return hasher.finalResult();
}
