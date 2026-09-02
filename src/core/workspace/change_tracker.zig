const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const OperationKind = enum {
    write,
    edit,
};

pub const FileOperation = struct {
    kind: OperationKind,
    path: []u8,
    previous_content: ?[]u8,
    timestamp_ms: i64,
};

pub const UndoResult = union(enum) {
    restored: []const u8,
    deleted: []const u8,
    /// The operation was consumed but could not be reversed, either because its
    /// preimage was never captured or because restoring it failed. Undo must not
    /// guess, and must not report this as a restore.
    unavailable: []const u8,
    empty,
};

pub const ChangeTracker = struct {
    stack: std.ArrayList(FileOperation) = .empty,

    const max_stack_size: usize = 100;

    pub fn deinit(self: *ChangeTracker, alloc: Allocator) void {
        for (self.stack.items) |op| freeOperation(alloc, op);
        self.stack.deinit(alloc);
    }

    pub fn clear(self: *ChangeTracker, alloc: Allocator) void {
        for (self.stack.items) |op| freeOperation(alloc, op);
        self.stack.clearRetainingCapacity();
    }

    pub fn pushOperation(self: *ChangeTracker, alloc: Allocator, op: FileOperation) !void {
        if (self.stack.items.len >= max_stack_size) {
            freeOperation(alloc, self.stack.items[0]);
            _ = self.stack.orderedRemove(0);
        }
        try self.stack.append(alloc, op);
    }

    pub fn undoLast(self: *ChangeTracker, alloc: Allocator) UndoResult {
        if (self.stack.items.len == 0) return .empty;

        const op = self.stack.pop().?;

        switch (op.kind) {
            .write, .edit => {
                if (op.previous_content) |content| {
                    defer alloc.free(content);
                    restoreContent(alloc, op.path, content) catch |err| {
                        traceUnavailable(op, "restore_content", err);
                        return .{ .unavailable = op.path };
                    };
                    return .{ .restored = op.path };
                }

                std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), op.path) catch |err| {
                    // An already-absent file has reached the requested state. Every
                    // other failure leaves the file's state uncertain and must not
                    // be reported as a successful deletion.
                    if (err != error.FileNotFound) {
                        traceUnavailable(op, "delete_created", err);
                        return .{ .unavailable = op.path };
                    }
                };
                return .{ .deleted = op.path };
            },
        }
    }

    /// Restores `content` at `absolute_path` without destroying what is already there
    /// until the replacement is durable. A failed restore leaves the current file
    /// untouched and is reported to the caller rather than swallowed.
    ///
    /// There is no in-place fallback for a file whose directory denies writes. Such a
    /// file cannot be replaced atomically, and writing the preimage over it directly
    /// would leave a half-replaced file behind on any mid-write failure, which is the
    /// damage undo exists to avoid. The caller reports the refusal instead.
    fn restoreContent(alloc: Allocator, absolute_path: []const u8, content: []const u8) !void {
        try io_mod.writeFileAtomic(alloc, absolute_path, content);
    }

    fn freeOperation(alloc: Allocator, op: FileOperation) void {
        alloc.free(op.path);
        if (op.previous_content) |content| alloc.free(content);
    }
};

fn traceUnavailable(
    op: FileOperation,
    stage: []const u8,
    err: anyerror,
) void {
    var path_buf: [256]u8 = undefined;
    const path = debug_trace.terminalPreview(path_buf[0..], op.path);
    debug_trace.eventf(
        "undo",
        "undo_unavailable",
        .{},
        "kind={s} path={s} stage={s} error={s}",
        .{ @tagName(op.kind), path, stage, @errorName(err) },
    );
}

fn tmpPath(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, dir, "");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn writeAbsolute(path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readAbsolute(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn expectMissing(path: []const u8) !void {
    if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |file| {
        file.close(io_mod.getIo());
        return error.FileStillExists;
    } else |_| {}
}
