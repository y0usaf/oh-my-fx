const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session_codec = @import("session_codec.zig");

const Allocator = std.mem.Allocator;
const history_file = profile_paths.prompt_history_file_name;
const history_lock_file = "history.lock";
const lock_deadline_ms: u64 = 2000;
const default_scan_block_bytes: usize = 1024 * 1024;
const max_record_bytes: usize = 256 * 1024;
const compaction_threshold_bytes: u64 = 1024 * 1024;
const compaction_record_limit: usize = 1000;
const compaction_byte_limit: usize = 1024 * 1024;
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const LoadedPromptHistoryEntry = struct {
    text: []u8,
};

pub const PromptHistoryRecord = struct {
    schema_version: u8 = 1,
    timestamp_ms: i64,
    workspace_root: []const u8,
    text: []const u8,
};

pub const AppendOutcome = enum {
    appended,
    duplicate,
    record_too_large,
    compaction_stale,
    compaction_indeterminate,
};

const ParsedRecord = struct {
    timestamp_ms: i64,
    workspace_root: []u8,
    text: []u8,

    fn deinit(self: *ParsedRecord, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        alloc.free(self.text);
        self.* = undefined;
    }
};

const LineRead = struct {
    bytes: []u8,
    next_offset: u64,
};

pub const Store = struct {
    home_path: []u8,
    display_path: []u8,
    durable_home: ?io_mod.VerifiedDir = null,
    indeterminate: bool = false,
    scan_block_bytes: usize = default_scan_block_bytes,
    lock_ops: io_mod.LockOps = .{},
    fail_compaction_before_rename: bool = false,
    fail_clear_after_rename: bool = false,
    fail_layout_creation: bool = false,
    fail_private_mode: bool = false,
    fail_history_parent_sync: bool = false,

    pub fn initFromHome(alloc: Allocator, home_path: []const u8) !Store {
        const zio = io_mod.getIo();
        var home = try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true });
        defer home.close(zio);

        var durable_home: ?io_mod.VerifiedDir = null;
        if (home.openDir(zio, profile_paths.root_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        })) |dir| {
            errdefer dir.close(zio);
            const stat = try dir.stat(zio);
            if (stat.kind != .directory) return error.DurablePathUnsafe;
            durable_home = .{ .dir = dir };
        } else |err| switch (err) {
            error.FileNotFound => {},
            error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
            else => return err,
        }

        return .{
            .home_path = try alloc.dupe(u8, home_path),
            .display_path = try profile_paths.promptHistoryPath(alloc, home_path),
            .durable_home = durable_home,
        };
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        if (self.durable_home) |*dir| dir.close();
        alloc.free(self.home_path);
        alloc.free(self.display_path);
        self.* = undefined;
    }

    pub fn append(
        self: *Store,
        alloc: Allocator,
        timestamp_ms: i64,
        workspace_root: []const u8,
        text: []const u8,
    ) !AppendOutcome {
        try validateWorkspaceRoot(workspace_root);
        const line = try serializeRecord(alloc, timestamp_ms, workspace_root, text);
        defer alloc.free(line);
        if (line.len > max_record_bytes) return .record_too_large;

        try self.ensureWritable();
        var lock = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => return error.PromptHistoryLockBusy,
            error.LockUnsupported => return error.PromptHistoryLockUnsupported,
            error.DirectorySyncFailed => return error.DurableLayoutFailed,
            else => return err,
        };
        defer lock.release();
        try self.resolveIndeterminate();

        var file = (try self.openHistory(true, true)).?;
        defer file.close(io_mod.getIo());
        try repairIncompleteTail(file);

        const boundary = try file.length(io_mod.getIo());
        const latest = try self.loadRecentAtBoundary(
            alloc,
            workspace_root,
            1,
            boundary,
        );
        defer freeLoadedEntries(alloc, latest);
        if (latest.len == 1 and std.mem.eql(u8, latest[0].text, text)) {
            return .duplicate;
        }

        try file.writePositionalAll(io_mod.getIo(), line, boundary);
        file.sync(io_mod.getIo()) catch return error.PromptHistoryWriteFailed;
        const committed_length = boundary + line.len;
        if (committed_length <= compaction_threshold_bytes) return .appended;

        self.compact(alloc) catch |err| switch (err) {
            error.PromptHistoryCompactionStale => return .compaction_stale,
            error.PromptHistoryCommitIndeterminate => return .compaction_indeterminate,
            else => return .compaction_stale,
        };
        return .appended;
    }

    pub fn loadRecentForWorkspace(
        self: *Store,
        alloc: Allocator,
        workspace_root: []const u8,
        limit: usize,
    ) ![]LoadedPromptHistoryEntry {
        try validateWorkspaceRoot(workspace_root);
        try self.resolveIndeterminate();
        if (limit == 0) return alloc.alloc(LoadedPromptHistoryEntry, 0);
        var file = (try self.openHistory(false, false)) orelse
            return alloc.alloc(LoadedPromptHistoryEntry, 0);
        defer file.close(io_mod.getIo());
        const boundary = try file.length(io_mod.getIo());
        return self.loadRecentFromFile(alloc, file, workspace_root, limit, boundary);
    }

    pub fn clearWorkspace(
        self: *Store,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !void {
        try validateWorkspaceRoot(workspace_root);
        if (self.durable_home == null) return;
        var probe = (try self.openHistory(false, false)) orelse return;
        probe.close(io_mod.getIo());

        try self.ensureWritable();
        var lock = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => return error.PromptHistoryLockBusy,
            error.LockUnsupported => return error.PromptHistoryLockUnsupported,
            error.DirectorySyncFailed => return error.DurableLayoutFailed,
            else => return err,
        };
        defer lock.release();
        try self.resolveIndeterminate();

        var file = (try self.openHistory(false, false)) orelse return;
        defer file.close(io_mod.getIo());
        const length = try file.length(io_mod.getIo());
        const replacement = try filterOtherWorkspaceRecords(
            alloc,
            file,
            length,
            workspace_root,
        );
        defer alloc.free(replacement);

        const ops = if (self.fail_clear_after_rename)
            io_mod.DurableOps{ .sync_dir = failParentSync }
        else
            io_mod.DurableOps{};
        io_mod.durableReplaceVerifiedWithOps(
            alloc,
            &self.durable_home.?,
            history_file,
            replacement,
            ops,
        ) catch |err| switch (err) {
            error.DurableReplacePostRenameFailed => {
                self.indeterminate = true;
                return error.PromptHistoryCommitIndeterminate;
            },
            error.DurableReplacePreRenameFailed => return error.PromptHistoryWriteFailed,
            else => return err,
        };
    }

    pub fn displayPath(self: *const Store) []const u8 {
        return self.display_path;
    }

    fn ensureWritable(self: *Store) !void {
        if (self.fail_private_mode) return error.PrivateStatePermissionsUnsupported;
        if (self.durable_home == null) {
            if (self.fail_layout_creation) return error.DurableLayoutFailed;
            const zio = io_mod.getIo();
            var home = io_mod.VerifiedDir{
                .dir = std.Io.Dir.openDirAbsolute(zio, self.home_path, .{
                    .iterate = true,
                }) catch return error.DurableLayoutFailed,
            };
            defer home.close();
            self.durable_home = io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.root_dir_name) catch |err| switch (err) {
                error.PrivateStatePermissionsUnsupported, error.DurablePathUnsafe => return err,
                else => return error.DurableLayoutFailed,
            };
        }

        self.durable_home.?.dir.setPermissions(
            io_mod.getIo(),
            private_dir_permissions,
        ) catch return error.PrivateStatePermissionsUnsupported;
        const stat = try self.durable_home.?.dir.stat(io_mod.getIo());
        if (stat.kind != .directory) return error.DurablePathUnsafe;
        if (stat.permissions.toMode() & 0o777 != 0o700) {
            return error.PrivateStatePermissionsUnsupported;
        }
    }

    fn acquireLock(self: *Store) !io_mod.TimedAdvisoryLock {
        return io_mod.acquireTimedAdvisoryLockWithOps(
            &self.durable_home.?,
            history_lock_file,
            lock_deadline_ms,
            self.lock_ops,
        );
    }

    fn openHistory(
        self: *Store,
        writable: bool,
        create: bool,
    ) !?std.Io.File {
        if (self.durable_home == null) return null;
        const zio = io_mod.getIo();
        var created = false;
        var file = self.durable_home.?.dir.openFile(zio, history_file, .{
            .mode = if (writable) .read_write else .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => create: {
                if (!create) return null;
                const new_file = self.durable_home.?.dir.createFile(zio, history_file, .{
                    .read = true,
                    .truncate = false,
                    .exclusive = true,
                    .permissions = private_file_permissions,
                    .resolve_beneath = true,
                }) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => return self.openHistory(writable, false),
                    else => return create_err,
                };
                created = true;
                break :create new_file;
            },
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
            else => return err,
        };
        errdefer file.close(zio);

        const initial = try file.stat(zio);
        if (initial.kind != .file or initial.nlink != 1) return error.DurablePathUnsafe;
        if (writable) {
            file.setPermissions(zio, private_file_permissions) catch {
                return error.PrivateStatePermissionsUnsupported;
            };
        }
        const verified = if (writable) try file.stat(zio) else initial;
        if (verified.permissions.toMode() & 0o777 != 0o600) {
            return error.PrivateStatePermissionsUnsupported;
        }
        if (created) {
            if (self.fail_history_parent_sync) {
                return error.DurableLayoutFailed;
            }
            io_mod.syncVerifiedDir(self.durable_home.?.dir) catch {
                return error.DurableLayoutFailed;
            };
        }
        return file;
    }

    fn resolveIndeterminate(self: *Store) !void {
        if (!self.indeterminate) return;
        var file = (try self.openHistory(true, false)) orelse
            return error.PromptHistoryWriteFailed;
        defer file.close(io_mod.getIo());
        const length = try file.length(io_mod.getIo());
        if (length > 0) {
            var trailing: [1]u8 = undefined;
            const count = try file.readPositionalAll(
                io_mod.getIo(),
                &trailing,
                length - 1,
            );
            if (count != 1 or trailing[0] != '\n') {
                return error.PromptHistoryWriteFailed;
            }
        }
        self.indeterminate = false;
    }

    fn compact(self: *Store, alloc: Allocator) !void {
        if (self.fail_compaction_before_rename) {
            return error.PromptHistoryCompactionStale;
        }
        var file = (try self.openHistory(false, false)) orelse return;
        defer file.close(io_mod.getIo());
        const length = try file.length(io_mod.getIo());
        const replacement = try compactRecords(alloc, file, length);
        defer alloc.free(replacement);

        io_mod.durableReplaceVerified(
            alloc,
            &self.durable_home.?,
            history_file,
            replacement,
        ) catch |err| switch (err) {
            error.DurableReplacePostRenameFailed => {
                self.indeterminate = true;
                return error.PromptHistoryCommitIndeterminate;
            },
            error.DurableReplacePreRenameFailed => return error.PromptHistoryCompactionStale,
            else => return err,
        };
    }

    fn loadRecentAtBoundary(
        self: *Store,
        alloc: Allocator,
        workspace_root: []const u8,
        limit: usize,
        boundary: u64,
    ) ![]LoadedPromptHistoryEntry {
        var file = (try self.openHistory(false, false)) orelse
            return alloc.alloc(LoadedPromptHistoryEntry, 0);
        defer file.close(io_mod.getIo());
        return self.loadRecentFromFile(
            alloc,
            file,
            workspace_root,
            limit,
            boundary,
        );
    }

    fn loadRecentFromFile(
        self: *Store,
        alloc: Allocator,
        file: std.Io.File,
        workspace_root: []const u8,
        limit: usize,
        requested_boundary: u64,
    ) ![]LoadedPromptHistoryEntry {
        const length = try file.length(io_mod.getIo());
        const boundary = @min(length, requested_boundary);
        if (boundary == 0 or limit == 0) {
            return alloc.alloc(LoadedPromptHistoryEntry, 0);
        }

        var last: [1]u8 = undefined;
        const last_count = try file.readPositionalAll(
            io_mod.getIo(),
            &last,
            boundary - 1,
        );
        var ignore_incomplete_tail = last_count != 1 or last[0] != '\n';
        var entries: std.ArrayList(LoadedPromptHistoryEntry) = .empty;
        errdefer {
            for (entries.items) |entry| alloc.free(entry.text);
            entries.deinit(alloc);
        }
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(alloc);
        var pending_oversized = false;
        var cursor = boundary;

        while (cursor > 0 and entries.items.len < limit) {
            const block_len_u64 = @min(
                cursor,
                @as(u64, @intCast(self.scan_block_bytes)),
            );
            const start = cursor - block_len_u64;
            const block_len: usize = @intCast(block_len_u64);
            const block = try alloc.alloc(u8, block_len);
            defer alloc.free(block);
            const count = try file.readPositionalAll(
                io_mod.getIo(),
                block,
                start,
            );
            if (count != block_len) return error.PromptHistoryWriteFailed;

            var segment_end = count;
            var index = count;
            while (index > 0 and entries.items.len < limit) {
                index -= 1;
                if (block[index] != '\n') continue;
                const piece = block[index + 1 .. segment_end];
                if (ignore_incomplete_tail) {
                    ignore_incomplete_tail = false;
                    pending.clearRetainingCapacity();
                    pending_oversized = false;
                } else {
                    try processReverseLine(
                        alloc,
                        piece,
                        &pending,
                        pending_oversized,
                        workspace_root,
                        limit,
                        &entries,
                    );
                    pending.clearRetainingCapacity();
                    pending_oversized = false;
                }
                segment_end = index;
            }

            if (!ignore_incomplete_tail and segment_end > 0) {
                if (pending_oversized or
                    segment_end + pending.items.len + 1 > max_record_bytes)
                {
                    pending.clearRetainingCapacity();
                    pending_oversized = true;
                } else {
                    try pending.insertSlice(alloc, 0, block[0..segment_end]);
                }
            }
            cursor = start;
        }

        if (cursor == 0 and !ignore_incomplete_tail and
            !pending_oversized and pending.items.len > 0 and
            entries.items.len < limit)
        {
            try processCompleteLine(
                alloc,
                pending.items,
                workspace_root,
                &entries,
            );
        }

        std.mem.reverse(LoadedPromptHistoryEntry, entries.items);
        return entries.toOwnedSlice(alloc);
    }

    fn setScanBlockBytesForTest(self: *Store, bytes: usize) void {
        self.scan_block_bytes = @max(bytes, 1);
    }

    fn historyLengthForTest(self: *Store) !u64 {
        var file = (try self.openHistory(false, false)) orelse
            return error.FileNotFound;
        defer file.close(io_mod.getIo());
        return file.length(io_mod.getIo());
    }

    fn loadRecentAtBoundaryForTest(
        self: *Store,
        alloc: Allocator,
        workspace_root: []const u8,
        limit: usize,
        boundary: u64,
    ) ![]LoadedPromptHistoryEntry {
        return self.loadRecentAtBoundary(
            alloc,
            workspace_root,
            limit,
            boundary,
        );
    }

    fn validRecordCountForTest(self: *Store) !usize {
        var file = (try self.openHistory(false, false)) orelse return 0;
        defer file.close(io_mod.getIo());
        const length = try file.length(io_mod.getIo());
        var offset: u64 = 0;
        var count: usize = 0;
        while (try readLineAt(std.testing.allocator, file, offset, length)) |line| {
            defer std.testing.allocator.free(line.bytes);
            offset = line.next_offset;
            var record = parseRecord(std.testing.allocator, line.bytes[0 .. line.bytes.len - 1]) catch continue;
            record.deinit(std.testing.allocator);
            count += 1;
        }
        return count;
    }

    pub fn setLockOpsForTest(self: *Store, ops: io_mod.LockOps) void {
        self.lock_ops = ops;
    }

    pub fn clearTestControls(self: *Store) void {
        self.lock_ops = .{};
        self.fail_compaction_before_rename = false;
        self.fail_clear_after_rename = false;
        self.fail_layout_creation = false;
        self.fail_private_mode = false;
        self.fail_history_parent_sync = false;
    }

    fn failCompactionBeforeRenameForTest(self: *Store) void {
        self.fail_compaction_before_rename = true;
    }

    fn failClearAfterRenameForTest(self: *Store) void {
        self.fail_clear_after_rename = true;
    }

    fn clearFailureControlsForTest(self: *Store) void {
        self.clearTestControls();
    }

    fn failLayoutCreationForTest(self: *Store) void {
        self.fail_layout_creation = true;
        self.fail_private_mode = false;
    }

    fn failPrivateModeForTest(self: *Store) void {
        self.fail_layout_creation = false;
        self.fail_private_mode = true;
    }

    fn failHistoryParentSyncForTest(self: *Store) void {
        self.fail_history_parent_sync = true;
    }
};

pub fn freeLoadedEntries(
    alloc: Allocator,
    entries: []LoadedPromptHistoryEntry,
) void {
    for (entries) |entry| alloc.free(entry.text);
    alloc.free(entries);
}

fn failParentSync(_: ?*anyopaque, _: std.Io.Dir) anyerror!void {
    return error.InjectedParentSyncFailure;
}

fn validateWorkspaceRoot(workspace_root: []const u8) !void {
    if (workspace_root.len == 0 or workspace_root.len > std.fs.max_path_bytes) {
        return error.InvalidDurableField;
    }
    if (!std.fs.path.isAbsolute(workspace_root) or
        !std.unicode.utf8ValidateSlice(workspace_root))
    {
        return error.InvalidDurableField;
    }
}

fn serializeRecord(
    alloc: Allocator,
    timestamp_ms: i64,
    workspace_root: []const u8,
    text: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema_version\":1,\"timestamp_ms\":");
    try out.writer.print("{d}", .{timestamp_ms});
    try out.writer.writeAll(",\"workspace_root\":");
    try std.json.Stringify.value(workspace_root, .{}, &out.writer);
    try out.writer.writeAll(",\"text\":");
    try session_codec.writeDurableBytes(&out.writer, text);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn parseRecord(alloc: Allocator, line: []const u8) !ParsedRecord {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        line,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 4) {
        return error.InvalidPromptHistoryRecord;
    }
    const schema = parsed.value.object.get("schema_version") orelse
        return error.InvalidPromptHistoryRecord;
    const timestamp = parsed.value.object.get("timestamp_ms") orelse
        return error.InvalidPromptHistoryRecord;
    const workspace = parsed.value.object.get("workspace_root") orelse
        return error.InvalidPromptHistoryRecord;
    const text = parsed.value.object.get("text") orelse
        return error.InvalidPromptHistoryRecord;
    if (schema != .integer or schema.integer != 1 or
        timestamp != .integer or workspace != .string)
    {
        return error.InvalidPromptHistoryRecord;
    }
    try validateWorkspaceRoot(workspace.string);
    const owned_workspace = try alloc.dupe(u8, workspace.string);
    errdefer alloc.free(owned_workspace);
    const owned_text = session_codec.parseDurableBytes(alloc, text) catch
        return error.InvalidPromptHistoryRecord;
    return .{
        .timestamp_ms = timestamp.integer,
        .workspace_root = owned_workspace,
        .text = owned_text,
    };
}

fn processReverseLine(
    alloc: Allocator,
    piece: []const u8,
    pending: *std.ArrayList(u8),
    pending_oversized: bool,
    workspace_root: []const u8,
    limit: usize,
    entries: *std.ArrayList(LoadedPromptHistoryEntry),
) !void {
    if (entries.items.len >= limit or pending_oversized) return;
    if (piece.len + pending.items.len + 1 > max_record_bytes) return;
    if (pending.items.len == 0) {
        if (piece.len == 0) return;
        return processCompleteLine(alloc, piece, workspace_root, entries);
    }
    const line = try alloc.alloc(u8, piece.len + pending.items.len);
    defer alloc.free(line);
    @memcpy(line[0..piece.len], piece);
    @memcpy(line[piece.len..], pending.items);
    try processCompleteLine(alloc, line, workspace_root, entries);
}

fn processCompleteLine(
    alloc: Allocator,
    line: []const u8,
    workspace_root: []const u8,
    entries: *std.ArrayList(LoadedPromptHistoryEntry),
) !void {
    if (line.len + 1 > max_record_bytes) return;
    var record = parseRecord(alloc, line) catch |err| {
        debug_trace.logf(
            "prompt_history",
            "skipped malformed record bytes={d} err={s}",
            .{ line.len + 1, @errorName(err) },
        );
        return;
    };
    if (!std.mem.eql(u8, record.workspace_root, workspace_root)) {
        record.deinit(alloc);
        return;
    }
    const text = record.text;
    alloc.free(record.workspace_root);
    entries.append(alloc, .{ .text = text }) catch |err| {
        alloc.free(text);
        return err;
    };
}

fn repairIncompleteTail(file: std.Io.File) !void {
    const length = try file.length(io_mod.getIo());
    if (length == 0) return;
    var last: [1]u8 = undefined;
    const count = try file.readPositionalAll(io_mod.getIo(), &last, length - 1);
    if (count == 1 and last[0] == '\n') return;

    var cursor = length;
    var buffer: [8192]u8 = undefined;
    while (cursor > 0) {
        const start = cursor - @min(cursor, buffer.len);
        const read_len: usize = @intCast(cursor - start);
        const read_count = try file.readPositionalAll(
            io_mod.getIo(),
            buffer[0..read_len],
            start,
        );
        if (read_count != read_len) return error.PromptHistoryWriteFailed;
        if (std.mem.lastIndexOfScalar(u8, buffer[0..read_count], '\n')) |newline| {
            try file.setLength(io_mod.getIo(), start + newline + 1);
            try file.sync(io_mod.getIo());
            return;
        }
        cursor = start;
    }
    try file.setLength(io_mod.getIo(), 0);
    try file.sync(io_mod.getIo());
}

fn readLineAt(
    alloc: Allocator,
    file: std.Io.File,
    offset: u64,
    max_end: u64,
) !?LineRead {
    if (offset >= max_end) return null;
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    var cursor = offset;
    var chunk: [8192]u8 = undefined;
    while (cursor < max_end) {
        const limit: usize = @intCast(@min(
            @as(u64, chunk.len),
            max_end - cursor,
        ));
        const count = try file.readPositionalAll(
            io_mod.getIo(),
            chunk[0..limit],
            cursor,
        );
        if (count == 0) return null;
        if (std.mem.findScalar(u8, chunk[0..count], '\n')) |newline| {
            try line.appendSlice(alloc, chunk[0 .. newline + 1]);
            cursor += newline + 1;
            if (line.items.len > max_record_bytes) {
                return .{
                    .bytes = try line.toOwnedSlice(alloc),
                    .next_offset = cursor,
                };
            }
            return .{
                .bytes = try line.toOwnedSlice(alloc),
                .next_offset = cursor,
            };
        }
        try line.appendSlice(alloc, chunk[0..count]);
        cursor += count;
        if (line.items.len > max_record_bytes) {
            while (cursor < max_end) {
                const skip_limit: usize = @intCast(@min(
                    @as(u64, chunk.len),
                    max_end - cursor,
                ));
                const skip_count = try file.readPositionalAll(
                    io_mod.getIo(),
                    chunk[0..skip_limit],
                    cursor,
                );
                if (skip_count == 0) return null;
                if (std.mem.findScalar(u8, chunk[0..skip_count], '\n')) |newline| {
                    cursor += newline + 1;
                    break;
                }
                cursor += skip_count;
            }
            return .{
                .bytes = try line.toOwnedSlice(alloc),
                .next_offset = cursor,
            };
        }
    }
    return null;
}

fn compactRecords(
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
) ![]u8 {
    var retained: std.ArrayList([]u8) = .empty;
    defer {
        for (retained.items) |line| alloc.free(line);
        retained.deinit(alloc);
    }
    var retained_bytes: usize = 0;
    var offset: u64 = 0;
    while (try readLineAt(alloc, file, offset, length)) |line| {
        defer alloc.free(line.bytes);
        offset = line.next_offset;
        if (line.bytes.len == 0 or line.bytes.len > max_record_bytes or
            line.bytes[line.bytes.len - 1] != '\n')
        {
            continue;
        }
        var record = parseRecord(
            alloc,
            line.bytes[0 .. line.bytes.len - 1],
        ) catch continue;
        defer record.deinit(alloc);
        const canonical = try serializeRecord(
            alloc,
            record.timestamp_ms,
            record.workspace_root,
            record.text,
        );
        if (canonical.len > max_record_bytes) {
            alloc.free(canonical);
            continue;
        }
        try retained.append(alloc, canonical);
        retained_bytes += canonical.len;
        while (retained.items.len > compaction_record_limit or
            retained_bytes > compaction_byte_limit)
        {
            const oldest = retained.orderedRemove(0);
            retained_bytes -= oldest.len;
            alloc.free(oldest);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, retained_bytes);
    for (retained.items) |line| try out.appendSlice(alloc, line);
    return out.toOwnedSlice(alloc);
}

fn filterOtherWorkspaceRecords(
    alloc: Allocator,
    file: std.Io.File,
    length: u64,
    workspace_root: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var offset: u64 = 0;
    while (try readLineAt(alloc, file, offset, length)) |line| {
        defer alloc.free(line.bytes);
        offset = line.next_offset;
        if (line.bytes.len == 0 or line.bytes.len > max_record_bytes or
            line.bytes[line.bytes.len - 1] != '\n')
        {
            continue;
        }
        var record = parseRecord(
            alloc,
            line.bytes[0 .. line.bytes.len - 1],
        ) catch continue;
        defer record.deinit(alloc);
        if (std.mem.eql(u8, record.workspace_root, workspace_root)) continue;
        const canonical = try serializeRecord(
            alloc,
            record.timestamp_ms,
            record.workspace_root,
            record.text,
        );
        defer alloc.free(canonical);
        try out.appendSlice(alloc, canonical);
    }
    return out.toOwnedSlice(alloc);
}

fn historyPath(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.promptHistoryPath(alloc, home);
}

fn ensureFixtureHome(home: []const u8) !void {
    const fx_dir = try profile_paths.rootDir(std.testing.allocator, home);
    defer std.testing.allocator.free(fx_dir);
    std.Io.Dir.createDirAbsolute(
        std.testing.io,
        fx_dir,
        std.Io.File.Permissions.fromMode(0o700),
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeFixture(home: []const u8, bytes: []const u8) !void {
    try ensureFixtureHome(home);
    const path = try historyPath(std.testing.allocator, home);
    defer std.testing.allocator.free(path);
    var file = try std.Io.Dir.createFileAbsolute(std.testing.io, path, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
    try file.sync(std.testing.io);
}

fn fixtureLine(
    alloc: Allocator,
    timestamp_ms: i64,
    workspace_root: []const u8,
    text: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":1,\"timestamp_ms\":{d},\"workspace_root\":\"{s}\",\"text\":\"{s}\"}}\n",
        .{ timestamp_ms, workspace_root, text },
    );
}

fn expectTexts(entries: []const LoadedPromptHistoryEntry, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, entries.len);
    for (entries, expected) |entry, text| {
        try std.testing.expectEqualStrings(text, entry.text);
    }
}










const LockFailureState = struct {
    now_ms: i64 = 0,
};

fn alwaysBusy(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
    return false;
}

fn unsupported(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
    return error.FileLocksUnsupported;
}

fn lockNow(ctx: ?*anyopaque) i64 {
    const state: *LockFailureState = @ptrCast(@alignCast(ctx.?));
    return state.now_ms;
}

fn lockSleep(ctx: ?*anyopaque, millis: u64) void {
    const state: *LockFailureState = @ptrCast(@alignCast(ctx.?));
    state.now_ms += @intCast(millis);
}







