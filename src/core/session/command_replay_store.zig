const std = @import("std");
const builtin = @import("builtin");
const command_output_content = @import("../tooling/command_output_content.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const artifact_digest = @import("artifact_digest.zig");
const session_child_store = @import("session_child_store.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Stream = command_output_content.Stream;
const replay_magic = "FXRPLY01";
const frame_header_bytes: usize = 9;
const max_frame_payload_bytes: usize = 1024 * 1024;
const max_agent_line_bytes: usize = max_frame_payload_bytes;
const agent_projection_overlap_bytes: usize = 64;
pub const max_public_handle_bytes: usize = 128;
pub const CapturePolicy = enum {
    best_effort,
    required,
};
const model_handle_prefix = "\n<command_output_handle>";
const model_handle_suffix = "</command_output_handle>\n" ++
    "Full captured command output is available through read_tool_result with this handle.";
pub const model_handle_notice_reserve_bytes = model_handle_prefix.len +
    max_public_handle_bytes +
    model_handle_suffix.len;

pub fn appendModelHandleNotice(
    alloc: Allocator,
    model_output: []const u8,
    handle: []const u8,
) ![]u8 {
    if (handle.len > max_public_handle_bytes) return error.InvalidReplayHandle;
    return std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}{s}",
        .{ model_output, model_handle_prefix, handle, model_handle_suffix },
    );
}

const DecodedFrameHeader = struct {
    stream: Stream,
    payload_len: usize,
};

fn decodeFrameHeader(header: []const u8) !DecodedFrameHeader {
    std.debug.assert(header.len == frame_header_bytes);
    const stream: Stream = switch (header[0]) {
        0 => .stdout,
        1 => .stderr,
        else => return error.InvalidReplayStream,
    };
    const payload_len_u64 = std.mem.readInt(u64, header[1..][0..8], .little);
    const payload_len = std.math.cast(usize, payload_len_u64) orelse
        return error.ReplayFrameTooLarge;
    if (payload_len == 0) return error.EmptyReplayFrame;
    if (payload_len > max_frame_payload_bytes) return error.ReplayFrameTooLarge;
    return .{ .stream = stream, .payload_len = payload_len };
}

const ReplayFile = union(enum) {
    saved: session_child_store.ManagedFile,
    ephemeral: std.Io.File,

    fn deinit(self: *ReplayFile) void {
        switch (self.*) {
            .saved => |*file| file.deinit(),
            .ephemeral => |file| file.close(io_mod.getIo()),
        }
        self.* = undefined;
    }

    fn writeAll(self: *ReplayFile, bytes: []const u8) !void {
        switch (self.*) {
            .saved => |*file| try file.writeAll(bytes),
            .ephemeral => |file| try file.writeStreamingAll(io_mod.getIo(), bytes),
        }
    }

    fn sync(self: *ReplayFile) !void {
        switch (self.*) {
            .saved => |*file| try file.sync(),
            .ephemeral => |file| try file.sync(io_mod.getIo()),
        }
    }

    fn size(self: *ReplayFile) !usize {
        const raw_size = switch (self.*) {
            .saved => |*file| (try file.stat()).size,
            .ephemeral => |file| (try file.stat(io_mod.getIo())).size,
        };
        return std.math.cast(usize, raw_size) orelse error.ReplayTooLarge;
    }

    fn readRange(
        self: *ReplayFile,
        alloc: Allocator,
        start: u64,
        len: usize,
    ) ![]u8 {
        return switch (self.*) {
            .saved => |*file| file.readRange(alloc, start, len),
            .ephemeral => |file| readFileRange(alloc, file, start, len),
        };
    }

    fn readRangeInto(self: *ReplayFile, start: u64, out: []u8) !usize {
        return switch (self.*) {
            .saved => |*file| file.readRangeInto(start, out),
            .ephemeral => |file| readFileRangeInto(file, start, out),
        };
    }
};

fn readFileRange(
    alloc: Allocator,
    file: std.Io.File,
    start: u64,
    len: usize,
) ![]u8 {
    if (len == 0) return alloc.dupe(u8, "");
    const out = try alloc.alloc(u8, len);
    errdefer alloc.free(out);
    const read_len = try readFileRangeInto(file, start, out);
    if (read_len == out.len) return out;
    return alloc.realloc(out, read_len);
}

fn readFileRangeInto(file: std.Io.File, start: u64, out: []u8) !usize {
    if (out.len == 0) return 0;
    return file.readPositionalAll(io_mod.getIo(), out, start);
}

pub const EphemeralStore = struct {
    alloc: Allocator,
    temp_dir: []const u8,
    files: std.StringHashMapUnmanaged(std.Io.File) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn init(alloc: Allocator) EphemeralStore {
        return .{ .alloc = alloc, .temp_dir = "/tmp" };
    }

    pub fn initForTesting(alloc: Allocator, temp_dir: []const u8) EphemeralStore {
        return .{ .alloc = alloc, .temp_dir = temp_dir };
    }

    pub fn deinit(self: *EphemeralStore) void {
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.close(io_mod.getIo());
            self.alloc.free(entry.key_ptr.*);
        }
        self.files.deinit(self.alloc);
        self.* = undefined;
    }

    fn createSpoolWithStem(
        self: *EphemeralStore,
        alloc: Allocator,
        stem: []const u8,
    ) !OpenSpool {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            return error.EphemeralReplayUnavailable;
        }
        const handle = try std.fmt.allocPrint(alloc, "{s}.bin", .{stem});
        errdefer alloc.free(handle);
        const temp_name = try std.fmt.allocPrint(alloc, ".{s}.tmp", .{stem});
        defer alloc.free(temp_name);
        const temp_path = try std.fs.path.join(alloc, &.{ self.temp_dir, temp_name });
        defer alloc.free(temp_path);
        var writer_file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), temp_path, .{
            .read = true,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.ReplayNameCollision,
            else => return error.EphemeralReplayUnavailable,
        };
        errdefer writer_file.close(io_mod.getIo());
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), temp_path) catch
            return error.EphemeralReplayUnavailable;
        const stored_file = try duplicateFile(writer_file);
        errdefer stored_file.close(io_mod.getIo());
        const owned_handle = try self.alloc.dupe(u8, handle);
        errdefer self.alloc.free(owned_handle);

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.files.contains(handle)) return error.ReplayNameCollision;
        try self.files.put(self.alloc, owned_handle, stored_file);
        @import("../shared/debug_trace.zig").logf(
            "session",
            "command replay ephemeral backing opened handle_bytes={d}",
            .{handle.len},
        );
        return .{
            .file = .{ .ephemeral = writer_file },
            .handle = handle,
            .framed_bytes = 0,
        };
    }

    fn open(self: *EphemeralStore, handle: []const u8) !ReplayFile {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const file = self.files.get(handle) orelse return error.ResultHandleNotFound;
        return .{ .ephemeral = try duplicateFile(file) };
    }

    fn delete(self: *EphemeralStore, handle: []const u8) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const removed = self.files.fetchRemove(handle) orelse return;
        removed.value.close(io);
        self.alloc.free(removed.key);
    }
};

fn duplicateFile(file: std.Io.File) !std.Io.File {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.EphemeralReplayUnavailable;
    }
    const duplicated = std.c.fcntl(file.handle, std.c.F.DUPFD_CLOEXEC, @as(std.c.fd_t, 0));
    if (duplicated < 0) return error.EphemeralReplayUnavailable;
    return .{
        .handle = @intCast(duplicated),
        .flags = file.flags,
    };
}

const ReplayBacking = union(enum) {
    saved: *session_child_store.SessionChildCapability,
    ephemeral: *EphemeralStore,
};

const OpenSpool = struct {
    file: ReplayFile,
    handle: []u8,
    framed_bytes: usize,
};

const OwnedDescriptor = struct {
    handle: []u8,
    framed_bytes: usize,

    fn view(self: OwnedDescriptor) types.CommandOutputReplayDescriptor {
        return .{
            .handle = self.handle,
            .framed_bytes = self.framed_bytes,
        };
    }
};

const CaptureState = union(enum) {
    buffered: std.ArrayList(u8),
    streaming: OpenSpool,
    sealed_file: OwnedDescriptor,
    unavailable,
    retained: ?OwnedDescriptor,
    consumed,
};

/// Arena-lived single-owner handoff. The pointer may be copied with a tool
/// result, but state transitions consume storage at most once.
pub const Capture = struct {
    inline_limit: usize,
    comparison_limit: usize,
    backing: ?ReplayBacking,
    capture_policy: CapturePolicy = .best_effort,
    state: CaptureState = .{ .buffered = .empty },
    had_output: bool = false,
    sealed: bool = false,
    content_hasher: Sha256 = Sha256.init(.{}),
    digest_started: bool = false,

    pub fn create(
        alloc: Allocator,
        inline_limit: usize,
        capability: ?*session_child_store.SessionChildCapability,
    ) !*Capture {
        const capture = try alloc.create(Capture);
        capture.* = .{
            .inline_limit = inline_limit,
            .comparison_limit = inline_limit,
            .backing = if (capability) |value| .{ .saved = value } else null,
        };
        return capture;
    }

    pub fn createEphemeral(
        alloc: Allocator,
        inline_limit: usize,
        store: *EphemeralStore,
    ) !*Capture {
        const capture = try alloc.create(Capture);
        capture.* = .{
            .inline_limit = inline_limit,
            .comparison_limit = inline_limit,
            .backing = .{ .ephemeral = store },
        };
        return capture;
    }

    pub fn setPolicyBeforeCapture(self: *Capture, replay_policy: CapturePolicy) void {
        std.debug.assert(!self.had_output and !self.sealed);
        self.capture_policy = replay_policy;
    }

    pub fn policy(self: *const Capture) CapturePolicy {
        return self.capture_policy;
    }

    /// Records bytes only after the downstream callback accepted them.
    /// Storage failures degrade replay without changing command execution.
    pub fn appendAccepted(
        self: *Capture,
        alloc: Allocator,
        stream: Stream,
        bytes: []const u8,
    ) void {
        if (bytes.len == 0 or self.sealed) return;
        self.had_output = true;
        self.appendAcceptedFallible(alloc, stream, bytes) catch |err| {
            self.makeUnavailable(alloc, err);
            return;
        };
        self.updateDigest(stream, bytes);
    }

    /// Records required command output. Any storage failure becomes visible so
    /// the execution owner can stop the command instead of losing later bytes.
    pub fn appendAcceptedRequired(
        self: *Capture,
        alloc: Allocator,
        stream: Stream,
        bytes: []const u8,
    ) !void {
        if (bytes.len == 0 or self.sealed) return;
        if (self.state == .unavailable) return error.CommandOutputCaptureFailed;
        self.had_output = true;
        self.appendAcceptedFallible(alloc, stream, bytes) catch |err| {
            self.makeUnavailable(alloc, err);
            return error.CommandOutputCaptureFailed;
        };
        self.updateDigest(stream, bytes);
    }

    fn updateDigest(self: *Capture, stream: Stream, bytes: []const u8) void {
        if (!self.digest_started) {
            self.content_hasher.update(replay_magic);
            self.digest_started = true;
        }
        var header: [frame_header_bytes]u8 = undefined;
        header[0] = @intFromEnum(stream);
        std.mem.writeInt(u64, header[1..], @intCast(bytes.len), .little);
        self.content_hasher.update(&header);
        self.content_hasher.update(bytes);
    }

    fn appendAcceptedFallible(
        self: *Capture,
        alloc: Allocator,
        stream: Stream,
        bytes: []const u8,
    ) !void {
        var header: [frame_header_bytes]u8 = undefined;
        header[0] = @intFromEnum(stream);
        const payload_len = std.math.cast(u64, bytes.len) orelse
            return error.ReplayFrameTooLarge;
        std.mem.writeInt(u64, header[1..], payload_len, .little);

        switch (self.state) {
            .buffered => |*buffered| {
                const base_len = if (buffered.items.len == 0)
                    replay_magic.len
                else
                    buffered.items.len;
                const with_header = try std.math.add(usize, base_len, header.len);
                const required = try std.math.add(usize, with_header, bytes.len);
                if (required <= self.inline_limit) {
                    try buffered.ensureTotalCapacityPrecise(alloc, required);
                    if (buffered.items.len == 0) buffered.appendSliceAssumeCapacity(replay_magic);
                    buffered.appendSliceAssumeCapacity(&header);
                    buffered.appendSliceAssumeCapacity(bytes);
                    return;
                }
                try self.promoteAndAppend(alloc, buffered, &header, bytes);
            },
            .streaming => |*spool| {
                try spool.file.writeAll(&header);
                try spool.file.writeAll(bytes);
                spool.framed_bytes = try std.math.add(
                    usize,
                    spool.framed_bytes,
                    try std.math.add(usize, header.len, bytes.len),
                );
            },
            .unavailable, .retained, .consumed, .sealed_file => {},
        }
    }

    fn promoteAndAppend(
        self: *Capture,
        alloc: Allocator,
        buffered: *std.ArrayList(u8),
        header: []const u8,
        bytes: []const u8,
    ) !void {
        const backing = self.backing orelse return error.ReplayStoreUnavailable;
        var spool = try createSpool(alloc, backing);
        var transferred = false;
        errdefer if (!transferred) {
            spool.file.deinit();
            self.deleteSpool(spool.handle);
            alloc.free(spool.handle);
        };
        if (buffered.items.len > 0) {
            try spool.file.writeAll(buffered.items);
            spool.framed_bytes = buffered.items.len;
        } else {
            try spool.file.writeAll(replay_magic);
            spool.framed_bytes = replay_magic.len;
        }
        try spool.file.writeAll(header);
        try spool.file.writeAll(bytes);
        spool.framed_bytes = try std.math.add(
            usize,
            spool.framed_bytes,
            try std.math.add(usize, header.len, bytes.len),
        );
        buffered.deinit(alloc);
        self.state = .{ .streaming = spool };
        transferred = true;
    }

    fn sealFallible(self: *Capture, alloc: Allocator) !void {
        if (self.sealed) return;
        self.sealed = true;
        switch (self.state) {
            .streaming => |*spool| {
                try spool.file.sync();
                var digest: [Sha256.digest_length]u8 = undefined;
                var hasher = self.content_hasher;
                hasher.final(&digest);
                try self.contentAddressSpool(alloc, spool, digest);
                const descriptor = OwnedDescriptor{
                    .handle = spool.handle,
                    .framed_bytes = spool.framed_bytes,
                };
                spool.file.deinit();
                self.state = .{ .sealed_file = descriptor };
            },
            else => {},
        }
    }

    /// Closes and synchronizes any spool before the capture leaves tool runtime.
    pub fn seal(self: *Capture, alloc: Allocator) void {
        self.sealFallible(alloc) catch |err| self.makeUnavailable(alloc, err);
    }

    pub fn sealRequired(self: *Capture, alloc: Allocator) !void {
        self.sealFallible(alloc) catch |err| {
            self.makeUnavailable(alloc, err);
            return error.CommandOutputCaptureFailed;
        };
        if (self.state == .unavailable) return error.CommandOutputCaptureFailed;
    }

    pub fn hasOutput(self: *const Capture) bool {
        return self.had_output;
    }

    pub fn setComparisonLimit(self: *Capture, limit: usize) void {
        self.comparison_limit = @max(self.inline_limit, limit);
    }

    pub fn comparisonLimit(self: *const Capture) usize {
        return self.comparison_limit;
    }

    /// Returns a canonical comparison view only when accepted payload stays
    /// within the route's bounded ordinary-result limit. Inline capture still
    /// never exceeds `inline_limit`; a route may compare a larger private spool
    /// when its executor can return more bytes in an ordinary exact result.
    pub fn canonicalizeForComparison(
        self: *Capture,
        alloc: Allocator,
    ) !?command_output_content.CanonicalOutput {
        self.seal(alloc);
        if (!self.had_output) {
            var empty: command_output_content.CanonicalOutput = .{};
            try empty.finish(alloc);
            return empty;
        }
        return switch (self.state) {
            .buffered => |*buffered| try canonicalizeFramedBytes(
                alloc,
                buffered.items,
                self.comparison_limit,
            ),
            .sealed_file => |descriptor| try self.canonicalizeSpool(
                alloc,
                descriptor,
                self.comparison_limit,
            ),
            else => null,
        };
    }

    fn canonicalizeSpool(
        self: *Capture,
        alloc: Allocator,
        descriptor: OwnedDescriptor,
        max_payload_bytes: usize,
    ) !command_output_content.CanonicalOutput {
        const backing = self.backing orelse return error.ReplayStoreUnavailable;
        var reader = try Reader.openBacking(alloc, backing, descriptor.view());
        defer reader.deinit();
        var output: command_output_content.CanonicalOutput = .{};
        errdefer output.deinit(alloc);
        var payload_bytes: usize = 0;
        while (try reader.next(alloc)) |frame| {
            defer alloc.free(frame.payload);
            payload_bytes = try std.math.add(usize, payload_bytes, frame.payload.len);
            if (payload_bytes > max_payload_bytes) return error.ReplayComparisonTooLarge;
            try output.append(alloc, frame.stream, frame.payload);
        }
        try output.finish(alloc);
        return output;
    }

    fn canonicalizeFramedBytes(
        alloc: Allocator,
        bytes: []const u8,
        max_payload_bytes: usize,
    ) !command_output_content.CanonicalOutput {
        if (bytes.len < replay_magic.len or
            !std.mem.eql(u8, bytes[0..replay_magic.len], replay_magic))
        {
            return error.InvalidReplayHeader;
        }
        var output: command_output_content.CanonicalOutput = .{};
        errdefer output.deinit(alloc);
        var offset = replay_magic.len;
        var payload_bytes: usize = 0;
        while (offset < bytes.len) {
            if (bytes.len - offset < frame_header_bytes) {
                return error.TruncatedReplayFrame;
            }
            const header = try decodeFrameHeader(
                bytes[offset..][0..frame_header_bytes],
            );
            const payload_start = try std.math.add(usize, offset, frame_header_bytes);
            const next_offset = try std.math.add(
                usize,
                payload_start,
                header.payload_len,
            );
            if (next_offset > bytes.len) return error.TruncatedReplayFrame;
            payload_bytes = try std.math.add(
                usize,
                payload_bytes,
                header.payload_len,
            );
            if (payload_bytes > max_payload_bytes) return error.ReplayComparisonTooLarge;
            try output.append(
                alloc,
                header.stream,
                bytes[payload_start..next_offset],
            );
            offset = next_offset;
        }
        try output.finish(alloc);
        return output;
    }

    /// Stages a durable descriptor in result memory. The capture remains the
    /// cleanup owner until the caller publishes that memory successfully.
    pub fn retain(
        self: *Capture,
        alloc: Allocator,
    ) ?types.CommandOutputReplay {
        self.seal(alloc);
        if (!self.had_output) {
            self.abort(alloc);
            return null;
        }
        return switch (self.state) {
            .buffered => |*buffered| blk: {
                const descriptor = self.materializeInline(alloc, buffered) catch |err| {
                    self.makeUnavailable(alloc, err);
                    self.state = .{ .retained = null };
                    break :blk .unavailable;
                };
                self.state = .{ .retained = descriptor };
                break :blk .{ .available = descriptor.view() };
            },
            .sealed_file => |descriptor| blk: {
                self.state = .{ .retained = descriptor };
                break :blk .{ .available = descriptor.view() };
            },
            .unavailable => blk: {
                self.state = .{ .retained = null };
                break :blk .unavailable;
            },
            .retained => |descriptor| if (descriptor) |value|
                .{ .available = value.view() }
            else
                .unavailable,
            .streaming => unreachable,
            .consumed => null,
        };
    }

    /// Retains required replay as one durable descriptor. The caller receives
    /// a borrowed view and the capture remains the cleanup owner until handoff.
    pub fn retainRequired(
        self: *Capture,
        alloc: Allocator,
    ) !?types.CommandOutputReplayDescriptor {
        try self.sealRequired(alloc);
        if (!self.had_output) {
            self.abort(alloc);
            return null;
        }
        return switch (self.state) {
            .buffered => |*buffered| blk: {
                const descriptor = self.materializeInline(alloc, buffered) catch |err| {
                    self.makeUnavailable(alloc, err);
                    return error.CommandOutputCaptureFailed;
                };
                self.state = .{ .retained = descriptor };
                break :blk descriptor.view();
            },
            .sealed_file => |descriptor| blk: {
                self.state = .{ .retained = descriptor };
                break :blk descriptor.view();
            },
            .retained => |descriptor| if (descriptor) |value|
                value.view()
            else
                return error.CommandOutputCaptureFailed,
            .unavailable => return error.CommandOutputCaptureFailed,
            .streaming => unreachable,
            .consumed => null,
        };
    }

    fn materializeInline(
        self: *Capture,
        alloc: Allocator,
        buffered: *std.ArrayList(u8),
    ) !OwnedDescriptor {
        const backing = self.backing orelse return error.ReplayStoreUnavailable;
        var spool = try createSpool(alloc, backing);
        var transferred = false;
        errdefer if (!transferred) {
            spool.file.deinit();
            self.deleteSpool(spool.handle);
            alloc.free(spool.handle);
        };
        const framed_bytes = buffered.items.len;
        try spool.file.writeAll(buffered.items);
        try spool.file.sync();
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(buffered.items, &digest, .{});
        try self.contentAddressSpool(alloc, &spool, digest);
        spool.file.deinit();
        buffered.deinit(alloc);
        transferred = true;
        return .{
            .handle = spool.handle,
            .framed_bytes = framed_bytes,
        };
    }

    fn contentAddressSpool(
        self: *Capture,
        alloc: Allocator,
        spool: *OpenSpool,
        digest: [Sha256.digest_length]u8,
    ) !void {
        const backing = self.backing orelse return error.ReplayStoreUnavailable;
        if (backing == .ephemeral) return;
        const capability = backing.saved;
        const target_handle = try contentAddressedHandle(
            alloc,
            spool.handle,
            digest,
        );
        capability.rename(
            .command_artifacts,
            spool.handle,
            target_handle,
        ) catch |err| {
            if (capability.hasIndeterminateEntry(
                .command_artifacts,
                target_handle,
            )) {
                alloc.free(spool.handle);
                spool.handle = target_handle;
            } else {
                alloc.free(target_handle);
            }
            return err;
        };
        alloc.free(spool.handle);
        spool.handle = target_handle;
    }

    /// Deletes a capture before result memory is staged. Safe to invoke repeatedly.
    pub fn abort(self: *Capture, alloc: Allocator) void {
        switch (self.state) {
            .buffered => |*buffered| buffered.deinit(alloc),
            .streaming => |*spool| {
                spool.file.deinit();
                self.deleteSpool(spool.handle);
                alloc.free(spool.handle);
            },
            .sealed_file => |descriptor| {
                self.deleteSpool(descriptor.handle);
                alloc.free(descriptor.handle);
            },
            .unavailable => {},
            .retained => {},
            .consumed => return,
        }
        self.state = .consumed;
    }

    /// Deletes a capture even when `retain` already staged its descriptor.
    /// Callers use this to roll back a failed result-memory publication.
    pub fn discard(self: *Capture, alloc: Allocator) void {
        switch (self.state) {
            .retained => |descriptor| {
                if (descriptor) |value| {
                    self.deleteSpool(value.handle);
                    alloc.free(value.handle);
                }
                self.state = .consumed;
            },
            else => self.abort(alloc),
        }
    }

    /// Releases retained descriptor storage after publication or external
    /// rollback without deleting the session-owned sidecar.
    pub fn releaseRetained(self: *Capture, alloc: Allocator) void {
        switch (self.state) {
            .retained => |descriptor| {
                if (descriptor) |value| alloc.free(value.handle);
                self.state = .consumed;
            },
            .consumed => {},
            else => self.abort(alloc),
        }
    }

    fn makeUnavailable(self: *Capture, alloc: Allocator, err: anyerror) void {
        switch (self.state) {
            .buffered => |*buffered| buffered.deinit(alloc),
            .streaming => |*spool| {
                spool.file.deinit();
                self.deleteSpool(spool.handle);
                alloc.free(spool.handle);
            },
            .sealed_file => |descriptor| {
                self.deleteSpool(descriptor.handle);
                alloc.free(descriptor.handle);
            },
            .unavailable, .retained, .consumed => {},
        }
        self.state = .unavailable;
        @import("../shared/debug_trace.zig").logf(
            "session",
            "command replay capture unavailable err={s}",
            .{@errorName(err)},
        );
    }

    fn deleteSpool(self: *Capture, handle: []const u8) void {
        const backing = self.backing orelse return;
        switch (backing) {
            .saved => |capability| capability.delete(.command_artifacts, handle) catch |err| {
                @import("../shared/debug_trace.zig").logf(
                    "session",
                    "command replay orphan cleanup failed handle_bytes={d} err={s}",
                    .{ handle.len, @errorName(err) },
                );
            },
            .ephemeral => |store| store.delete(handle),
        }
    }
};

fn createSpool(
    alloc: Allocator,
    backing: ReplayBacking,
) !OpenSpool {
    for (0..8) |_| {
        const stem = try randomReplayStem(alloc);
        defer alloc.free(stem);
        return createSpoolWithStem(alloc, backing, stem) catch |err| switch (err) {
            error.ReplayNameCollision => continue,
            else => return err,
        };
    }
    return error.ReplayNameCollision;
}

fn randomReplayStem(alloc: Allocator) ![]u8 {
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io_mod.getIo(), &random);
    const random_hex = std.fmt.bytesToHex(random, .lower);
    return std.fmt.allocPrint(
        alloc,
        "fx-command-replay-{s}",
        .{&random_hex},
    );
}

fn createSpoolWithStem(
    alloc: Allocator,
    backing: ReplayBacking,
    stem: []const u8,
) !OpenSpool {
    return switch (backing) {
        .ephemeral => |store| store.createSpoolWithStem(alloc, stem),
        .saved => |capability| blk: {
            const handle = try std.fmt.allocPrint(alloc, "{s}.bin", .{stem});
            errdefer alloc.free(handle);
            const file = capability.createExclusiveFile(
                alloc,
                .command_artifacts,
                handle,
            ) catch |err| switch (err) {
                error.PathAlreadyExists => return error.ReplayNameCollision,
                else => return err,
            };
            break :blk .{
                .file = .{ .saved = file },
                .handle = handle,
                .framed_bytes = 0,
            };
        },
    };
}

fn contentAddressedHandle(
    alloc: Allocator,
    source_handle: []const u8,
    digest: [Sha256.digest_length]u8,
) ![]u8 {
    return artifact_digest.contentAddressedHandle(
        alloc,
        source_handle,
        ".bin",
        digest,
    ) catch |err| switch (err) {
        error.InvalidArtifactHandle => error.InvalidReplayHandle,
        else => return err,
    };
}

pub fn handleMatchesContentDigest(
    handle: []const u8,
    digest: [Sha256.digest_length]u8,
) bool {
    return artifact_digest.handleMatchesContentDigest(
        handle,
        ".bin",
        digest,
    );
}

pub fn hasContentDigest(handle: []const u8) bool {
    return artifact_digest.hasContentDigest(handle, ".bin");
}

pub const Frame = struct {
    stream: Stream,
    payload: []u8,
};

pub const Byte = struct {
    stream: Stream,
    value: u8,
};

pub const Reader = struct {
    file: ReplayFile,
    size: usize,
    offset: usize,
    byte_buffer: [8192]u8 = undefined,
    byte_buffer_index: usize = 0,
    byte_buffer_len: usize = 0,
    byte_stream: Stream = .stdout,
    frame_remaining: usize = 0,

    // Fallible constructors use noinline out-parameter boundaries so errors do
    // not materialize Reader's unused 8 KiB payload.
    pub fn open(
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        descriptor: types.CommandOutputReplayDescriptor,
    ) !Reader {
        var reader: Reader = undefined;
        try openBackingInto(&reader, alloc, .{ .saved = capability }, descriptor);
        return reader;
    }

    fn openBacking(
        alloc: Allocator,
        backing: ReplayBacking,
        descriptor: types.CommandOutputReplayDescriptor,
    ) !Reader {
        var reader: Reader = undefined;
        try openBackingInto(&reader, alloc, backing, descriptor);
        return reader;
    }

    noinline fn openBackingInto(
        out: *Reader,
        alloc: Allocator,
        backing: ReplayBacking,
        descriptor: types.CommandOutputReplayDescriptor,
    ) !void {
        var file = switch (backing) {
            .saved => |capability| ReplayFile{ .saved = try capability.openFileReadOnly(
                alloc,
                .command_artifacts,
                descriptor.handle,
            ) },
            .ephemeral => |store| try store.open(descriptor.handle),
        };
        const size = file.size() catch |err| {
            file.deinit();
            return err;
        };
        if (size != descriptor.framed_bytes) {
            file.deinit();
            return error.ReplaySizeMismatch;
        }
        try initializeInto(out, alloc, file, size);
    }

    pub fn openHandle(
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        handle: []const u8,
    ) !Reader {
        var reader: Reader = undefined;
        try openHandleInto(&reader, alloc, capability, handle);
        return reader;
    }

    noinline fn openHandleInto(
        out: *Reader,
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        handle: []const u8,
    ) !void {
        if (!hasContentDigest(handle)) return error.ResultHandleNotFound;
        var file = ReplayFile{ .saved = capability.openFileReadOnly(
            alloc,
            .command_artifacts,
            handle,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.ResultHandleNotFound,
            else => return err,
        } };
        const size = file.size() catch |err| {
            file.deinit();
            return err;
        };
        try initializeInto(out, alloc, file, size);
    }

    pub fn openEphemeralHandle(
        alloc: Allocator,
        store: *EphemeralStore,
        handle: []const u8,
    ) !Reader {
        var reader: Reader = undefined;
        try openEphemeralHandleInto(&reader, alloc, store, handle);
        return reader;
    }

    noinline fn openEphemeralHandleInto(
        out: *Reader,
        alloc: Allocator,
        store: *EphemeralStore,
        handle: []const u8,
    ) !void {
        var file = try store.open(handle);
        const size = file.size() catch |err| {
            file.deinit();
            return err;
        };
        try initializeInto(out, alloc, file, size);
    }

    noinline fn initializeInto(
        out: *Reader,
        alloc: Allocator,
        file: ReplayFile,
        size: usize,
    ) !void {
        var owned_file = file;
        errdefer owned_file.deinit();
        if (size < replay_magic.len) return error.InvalidReplayHeader;
        const magic = try readExactRange(alloc, &owned_file, 0, replay_magic.len);
        defer alloc.free(magic);
        if (!std.mem.eql(u8, magic, replay_magic)) return error.InvalidReplayHeader;
        out.* = .{
            .file = owned_file,
            .size = size,
            .offset = replay_magic.len,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.file.deinit();
        self.* = undefined;
    }

    /// Returns one owned callback frame; caller frees `payload`.
    pub fn next(self: *Reader, alloc: Allocator) !?Frame {
        if (self.byte_buffer_index != self.byte_buffer_len or self.frame_remaining != 0) {
            return error.ReplayReaderModeConflict;
        }
        if (self.offset == self.size) return null;
        if (self.size - self.offset < frame_header_bytes) {
            return error.TruncatedReplayFrame;
        }
        const header = try readExactRange(
            alloc,
            &self.file,
            self.offset,
            frame_header_bytes,
        );
        defer alloc.free(header);
        const decoded = try decodeFrameHeader(header);
        const payload_start = try std.math.add(usize, self.offset, frame_header_bytes);
        const next_offset = try std.math.add(
            usize,
            payload_start,
            decoded.payload_len,
        );
        if (next_offset > self.size) return error.TruncatedReplayFrame;
        const payload = try readExactRange(
            alloc,
            &self.file,
            payload_start,
            decoded.payload_len,
        );
        self.offset = next_offset;
        return .{ .stream = decoded.stream, .payload = payload };
    }

    /// Returns one validated callback byte without allocating frame payloads.
    /// The fixed internal page keeps full-transcript replay memory independent
    /// of callback count and frame size.
    pub fn nextByte(self: *Reader) !?Byte {
        while (true) {
            if (self.byte_buffer_index < self.byte_buffer_len) {
                const value = self.byte_buffer[self.byte_buffer_index];
                self.byte_buffer_index += 1;
                return .{ .stream = self.byte_stream, .value = value };
            }
            self.byte_buffer_index = 0;
            self.byte_buffer_len = 0;

            if (self.frame_remaining == 0) {
                if (self.offset == self.size) return null;
                if (self.size - self.offset < frame_header_bytes) {
                    return error.TruncatedReplayFrame;
                }
                var header: [frame_header_bytes]u8 = undefined;
                try readExactInto(&self.file, self.offset, &header);
                const decoded = try decodeFrameHeader(&header);
                self.byte_stream = decoded.stream;
                self.offset = try std.math.add(usize, self.offset, frame_header_bytes);
                const payload_end = try std.math.add(
                    usize,
                    self.offset,
                    decoded.payload_len,
                );
                if (payload_end > self.size) return error.TruncatedReplayFrame;
                self.frame_remaining = decoded.payload_len;
            }

            const read_len = @min(self.byte_buffer.len, self.frame_remaining);
            try readExactInto(
                &self.file,
                self.offset,
                self.byte_buffer[0..read_len],
            );
            self.offset = try std.math.add(usize, self.offset, read_len);
            self.frame_remaining -= read_len;
            self.byte_buffer_len = read_len;
        }
    }
};

fn projectedOutput(
    alloc: Allocator,
    stream: Stream,
    payload: []const u8,
) ![]u8 {
    const masked = try text_utils.maskSecrets(alloc, payload);
    defer if (masked.ptr != payload.ptr) alloc.free(@constCast(masked));
    const max_encoded_bytes = std.math.mul(usize, masked.len, 12) catch
        return error.OutOfMemory;
    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        masked,
        max_encoded_bytes,
    );
    defer encoded.deinit(alloc);
    const stream_name = @tagName(stream);
    return std.fmt.allocPrint(
        alloc,
        "[{s}]\n{s}\n[/{s}]\n",
        .{ stream_name, encoded.bytes, stream_name },
    );
}

const AgentProjectionReader = struct {
    reader: *Reader,
    line: std.ArrayList(u8) = .empty,
    stream: ?Stream = null,
    pending_byte: ?Byte = null,
    discarding_sensitive_line: bool = false,

    fn deinit(self: *AgentProjectionReader, alloc: Allocator) void {
        self.line.deinit(alloc);
        self.* = undefined;
    }

    /// Projects logical lines so masking cannot be bypassed by a secret split
    /// across callback frames. Non-secret oversized lines stream in bounded
    /// chunks; suspicious oversized lines are suppressed conservatively.
    fn next(self: *AgentProjectionReader, alloc: Allocator) !?[]u8 {
        while (true) {
            const next_byte = if (self.pending_byte) |byte| blk: {
                self.pending_byte = null;
                break :blk byte;
            } else (try self.reader.nextByte()) orelse {
                if (self.stream == null) return null;
                return try self.finishLine(alloc);
            };

            if (self.stream) |stream| {
                if (stream != next_byte.stream) {
                    self.pending_byte = next_byte;
                    return try self.finishLine(alloc);
                }
            } else {
                self.stream = next_byte.stream;
            }

            if (self.discarding_sensitive_line) {
                if (next_byte.value == '\n') return try self.finishLine(alloc);
                continue;
            }
            if (self.line.items.len == max_agent_line_bytes) {
                const masked = try text_utils.maskSecrets(alloc, self.line.items);
                defer if (masked.ptr != self.line.items.ptr) alloc.free(@constCast(masked));
                if (masked.ptr != self.line.items.ptr or
                    text_utils.secretMayCrossBoundary(
                        self.line.items,
                        agent_projection_overlap_bytes,
                    ))
                {
                    self.line.clearRetainingCapacity();
                    self.discarding_sensitive_line = true;
                    if (next_byte.value == '\n') return try self.finishLine(alloc);
                    continue;
                }
                self.pending_byte = next_byte;
                return try self.finishChunk(alloc);
            }
            try self.line.append(alloc, next_byte.value);
            if (next_byte.value == '\n') return try self.finishLine(alloc);
        }
    }

    fn finishLine(self: *AgentProjectionReader, alloc: Allocator) ![]u8 {
        const stream = self.stream.?;
        defer {
            self.line.clearRetainingCapacity();
            self.stream = null;
            self.discarding_sensitive_line = false;
        }
        if (self.discarding_sensitive_line) {
            const stream_name = @tagName(stream);
            return std.fmt.allocPrint(
                alloc,
                "[{s}]\n[secret-bearing output line omitted after {d} bytes]\n[/{s}]\n",
                .{ stream_name, max_agent_line_bytes, stream_name },
            );
        }
        return projectedOutput(alloc, stream, self.line.items);
    }

    fn finishChunk(self: *AgentProjectionReader, alloc: Allocator) ![]u8 {
        std.debug.assert(self.line.items.len == max_agent_line_bytes);
        const flush_len = self.line.items.len - agent_projection_overlap_bytes;
        const projected = try projectedOutput(
            alloc,
            self.stream.?,
            self.line.items[0..flush_len],
        );
        std.mem.copyForwards(
            u8,
            self.line.items[0..agent_projection_overlap_bytes],
            self.line.items[flush_len..],
        );
        self.line.shrinkRetainingCapacity(agent_projection_overlap_bytes);
        return projected;
    }
};

pub fn readAgentPageManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    start_byte: usize,
    byte_count: usize,
) ![]u8 {
    var reader = try Reader.openHandle(alloc, capability, handle);
    defer reader.deinit();
    return readAgentPage(alloc, &reader, handle, start_byte, byte_count);
}

pub fn readAgentPageEphemeral(
    alloc: Allocator,
    store: *EphemeralStore,
    handle: []const u8,
    start_byte: usize,
    byte_count: usize,
) ![]u8 {
    var reader = try Reader.openEphemeralHandle(alloc, store, handle);
    defer reader.deinit();
    return readAgentPage(alloc, &reader, handle, start_byte, byte_count);
}

fn readAgentPage(
    alloc: Allocator,
    reader: *Reader,
    handle: []const u8,
    start_byte: usize,
    byte_count: usize,
) ![]u8 {
    const requested_start = if (start_byte == 0) 0 else start_byte - 1;
    var projected_offset: usize = 0;
    var page_start: ?usize = null;
    var page_closed = false;
    var page: std.ArrayList(u8) = .empty;
    defer page.deinit(alloc);
    var projector: AgentProjectionReader = .{ .reader = reader };
    defer projector.deinit(alloc);

    while (try projector.next(alloc)) |block| {
        defer alloc.free(block);
        const block_end = try std.math.add(usize, projected_offset, block.len);
        if (!page_closed and block_end > requested_start and page.items.len < byte_count) {
            const local_start = if (requested_start > projected_offset)
                requested_start - projected_offset
            else
                0;
            const safe_start = text_utils.utf8ForwardBoundary(block, local_start);
            if (page_start == null) page_start = projected_offset + safe_start;
            const available = block.len - safe_start;
            const remaining = byte_count - page.items.len;
            const raw_end = safe_start + @min(available, remaining);
            const safe_end = text_utils.utf8BackwardBoundary(block, raw_end);
            if (safe_end > safe_start) {
                try page.appendSlice(alloc, block[safe_start..safe_end]);
            }
            if (safe_end < raw_end or page.items.len == byte_count) {
                page_closed = true;
            }
        }
        projected_offset = block_end;
    }

    const response_start = page_start orelse @min(requested_start, projected_offset);
    const response_end = try std.math.add(usize, response_start, page.items.len);
    return std.fmt.allocPrint(
        alloc,
        "<command_output handle=\"{s}\" start_byte=\"{d}\" end_byte=\"{d}\" total_bytes=\"{d}\">\n{s}</command_output>",
        .{ handle, response_start + 1, response_end, projected_offset, page.items },
    );
}

pub fn searchAgentQueryManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    handle: []const u8,
    query: []const u8,
    max_response_bytes: usize,
) ![]u8 {
    const trimmed_query = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed_query.len == 0) return error.InvalidQuery;
    var reader = try Reader.openHandle(alloc, capability, handle);
    defer reader.deinit();
    return searchAgentQuery(alloc, &reader, handle, trimmed_query, max_response_bytes);
}

pub fn searchAgentQueryEphemeral(
    alloc: Allocator,
    store: *EphemeralStore,
    handle: []const u8,
    query: []const u8,
    max_response_bytes: usize,
) ![]u8 {
    const trimmed_query = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed_query.len == 0) return error.InvalidQuery;
    var reader = try Reader.openEphemeralHandle(alloc, store, handle);
    defer reader.deinit();
    return searchAgentQuery(alloc, &reader, handle, trimmed_query, max_response_bytes);
}

fn searchAgentQuery(
    alloc: Allocator,
    reader: *Reader,
    handle: []const u8,
    trimmed_query: []const u8,
    max_response_bytes: usize,
) ![]u8 {
    var matches: std.ArrayList(u8) = .empty;
    defer matches.deinit(alloc);
    var match_count: usize = 0;
    var projector: AgentProjectionReader = .{ .reader = reader };
    defer projector.deinit(alloc);

    while (try projector.next(alloc)) |block| {
        defer alloc.free(block);
        if (std.mem.find(u8, block, trimmed_query) == null) continue;
        const remaining = max_response_bytes -| matches.items.len;
        if (remaining == 0) break;
        const end = text_utils.utf8BackwardBoundary(block, @min(block.len, remaining));
        if (end > 0) try matches.appendSlice(alloc, block[0..end]);
        match_count += 1;
        if (match_count >= 50 or matches.items.len >= max_response_bytes) break;
    }
    if (match_count == 0) try matches.appendSlice(alloc, "(no matches)\n");
    return std.fmt.allocPrint(
        alloc,
        "<command_output_query handle=\"{s}\">\nquery: {f}\n{s}</command_output_query>",
        .{ handle, std.json.fmt(trimmed_query, .{}), matches.items },
    );
}

fn readExactInto(
    file: *ReplayFile,
    start: usize,
    out: []u8,
) !void {
    const start_u64 = std.math.cast(u64, start) orelse
        return error.ReplayOffsetTooLarge;
    const read_len = try file.readRangeInto(start_u64, out);
    if (read_len != out.len) return error.UnexpectedEndOfReplay;
}

fn readExactRange(
    alloc: Allocator,
    file: *ReplayFile,
    start: usize,
    len: usize,
) ![]u8 {
    const start_u64 = std.math.cast(u64, start) orelse
        return error.ReplayOffsetTooLarge;
    const bytes = try file.readRange(alloc, start_u64, len);
    if (bytes.len != len) {
        alloc.free(bytes);
        return error.UnexpectedEndOfReplay;
    }
    return bytes;
}
