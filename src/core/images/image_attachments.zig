const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const display_width = @import("../shared/display_width.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const pathing = @import("../workspace/pathing.zig");

pub const max_image_bytes: usize = 20 * 1024 * 1024;
const max_encoded_image_bytes: usize = 5 * 1024 * 1024;
pub const image_too_large_notice = "image exceeds the 20 MiB limit";
pub const image_preparation_failed_notice = "Unable to prepare this image for upload. Use a smaller image.";
const Sha256 = std.crypto.hash.sha2.Sha256;
const snapshot_digest_hex_len = Sha256.digest_length * 2;
const transfer_buffer_bytes = 64 * 1024;
const image_normalization_timeout = std.Io.Clock.Duration{
    .clock = .awake,
    .raw = .fromSeconds(5),
};

pub fn findById(
    attachments: []const types.ImageAttachment,
    id: usize,
) ?types.ImageAttachment {
    for (attachments) |attachment| {
        if (attachment.id == id) return attachment;
    }
    return null;
}

pub fn projectOffsetThroughPlaceholderRewrite(
    source_tokens: []const entity_spans.ImageTokenSpan,
    target_tokens: []const entity_spans.ImageTokenSpan,
    source_len: usize,
    raw_offset: usize,
) ?usize {
    if (source_tokens.len != target_tokens.len or raw_offset > source_len) return null;

    var source_cursor: usize = 0;
    var target_cursor: usize = 0;
    for (source_tokens, target_tokens) |source, target| {
        if (!source.span.isValid(source_len) or
            source.span.raw_start < source_cursor or
            target.span.raw_start < target_cursor or
            target.span.raw_start >= target.span.raw_end)
        {
            return null;
        }
        if (raw_offset <= source.span.raw_start) {
            return std.math.add(
                usize,
                target_cursor,
                raw_offset - source_cursor,
            ) catch null;
        }
        if (raw_offset < source.span.raw_end) return null;

        target_cursor = std.math.add(
            usize,
            target_cursor,
            source.span.raw_start - source_cursor,
        ) catch return null;
        target_cursor = std.math.add(
            usize,
            target_cursor,
            target.span.raw_end - target.span.raw_start,
        ) catch return null;
        source_cursor = source.span.raw_end;
    }
    return std.math.add(
        usize,
        target_cursor,
        raw_offset - source_cursor,
    ) catch null;
}


pub const ExtractedInlineImages = struct {
    text: []u8,
    images: []types.ImageAttachment,
    image_spans: []ImagePlaceholderSpan,

    pub fn deinit(self: ExtractedInlineImages, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        types.freeImageAttachmentSlice(alloc, self.images);
        alloc.free(self.image_spans);
    }

    pub fn discard(self: ExtractedInlineImages, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        discardImageAttachmentSlice(alloc, self.images);
        alloc.free(self.image_spans);
    }
};

pub fn loadImageAttachment(alloc: std.mem.Allocator, path_input: []const u8) !types.ImageAttachment {
    const normalized_path = try normalizePathInput(alloc, path_input);
    defer alloc.free(normalized_path);

    const resolved_path = try io_mod.realpathAlloc(alloc, normalized_path);
    return loadResolvedImageAttachment(alloc, resolved_path);
}

pub fn loadUserImageAttachment(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    path_input: []const u8,
) !types.ImageAttachment {
    const normalized_path = try normalizePathInput(alloc, path_input);
    defer alloc.free(normalized_path);

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const resolved_path = try pathing.resolveWorkspaceOrExternalPath(
        scratch_state.allocator(),
        workspace_root,
        normalized_path,
    );
    const owned_path = try alloc.dupe(u8, resolved_path);
    return loadResolvedImageAttachment(alloc, owned_path);
}

fn loadResolvedImageAttachment(
    alloc: std.mem.Allocator,
    resolved_path: []u8,
) !types.ImageAttachment {
    errdefer alloc.free(resolved_path);

    var header: [64]u8 = undefined;
    const bytes = try readImageHeaderBytes(resolved_path, &header);

    const media_type = try alloc.dupe(u8, detectMediaTypeFromBytes(bytes) orelse return error.UnsupportedImageType);
    errdefer alloc.free(media_type);

    return .{
        .path = resolved_path,
        .media_type = media_type,
    };
}

pub fn createTempSnapshotDir(alloc: std.mem.Allocator) ![]u8 {
    const temp_root = try io_mod.realpathAlloc(alloc, "/tmp");
    defer alloc.free(temp_root);
    for (0..16) |_| {
        var suffix: u64 = undefined;
        io_mod.getIo().random(std.mem.asBytes(&suffix));
        const path = try std.fmt.allocPrint(
            alloc,
            "{s}/fx-image-snapshots-{x}",
            .{ temp_root, suffix },
        );
        errdefer alloc.free(path);
        std.Io.Dir.createDirAbsolute(
            io_mod.getIo(),
            path,
            std.Io.File.Permissions.fromMode(0o700),
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(path);
                continue;
            },
            else => return err,
        };
        return path;
    }
    return error.PathAlreadyExists;
}

pub fn cleanupSnapshotDir(path: []const u8) void {
    if (path.len == 0) return;
    const parent_path = std.fs.path.dirname(path) orelse return;
    const name = std.fs.path.basename(path);
    var parent = openDirectoryNoFollow(parent_path) catch |err| {
        debug_trace.logf(
            "images",
            "event=snapshot_directory_cleanup_failed err={s}",
            .{@errorName(err)},
        );
        return;
    };
    defer parent.close(io_mod.getIo());
    parent.deleteTree(io_mod.getIo(), name) catch |err| {
        debug_trace.logf(
            "images",
            "event=snapshot_directory_cleanup_failed err={s}",
            .{@errorName(err)},
        );
    };
}

pub const CaptureBudget = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,
    test_hook: if (builtin.is_test) ?TestBudgetHook else void = if (builtin.is_test) null else {},

    pub fn check(self: CaptureBudget) !void {
        if (comptime builtin.is_test) {
            if (self.test_hook) |hook| try hook.check(hook.ctx);
        }
        if (self.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
        if (self.deadline) |deadline| {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            if (now.raw.nanoseconds >= deadline.raw.nanoseconds) return error.TimedOut;
        }
    }
};

pub const CaptureAdmissionResult = enum {
    captured,
    rejected,
};

fn captureRejectionNotice(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ImageTooLarge => image_too_large_notice,
        error.ImagePreparationFailed => image_preparation_failed_notice,
        else => null,
    };
}

pub fn captureImageAttachmentForAdmission(
    comptime App: type,
    app: *App,
    attachment: *types.ImageAttachment,
) !CaptureAdmissionResult {
    App.captureImageAttachment(app, attachment) catch |err| {
        const notice = captureRejectionNotice(err) orelse return err;
        if (comptime !@hasDecl(App, "writeDomainNotice")) return err;
        try app.writeDomainNotice(.{
            .topic = "images",
            .tone = .@"error",
            .body = notice,
        }, true);
        return .rejected;
    };
    return .captured;
}

pub fn captureImageAttachmentsForAdmission(
    comptime App: type,
    app: *App,
    attachments: []types.ImageAttachment,
) !CaptureAdmissionResult {
    var captured: usize = 0;
    errdefer {
        discardImageSnapshots(app.alloc, attachments[0..captured]);
    }
    for (attachments) |*attachment| {
        switch (try captureImageAttachmentForAdmission(App, app, attachment)) {
            .captured => captured += 1,
            .rejected => {
                discardImageSnapshots(app.alloc, attachments[0..captured]);
                captured = 0;
                return .rejected;
            },
        }
    }
    return .captured;
}

const TestBudgetHook = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque) anyerror!void,
};

pub fn captureImageSnapshot(
    alloc: std.mem.Allocator,
    attachment: *types.ImageAttachment,
    snapshot_dir: []const u8,
) !void {
    return captureImageSnapshotWithBudget(alloc, attachment, snapshot_dir, .{});
}

pub fn captureImageSnapshotWithBudget(
    alloc: std.mem.Allocator,
    attachment: *types.ImageAttachment,
    snapshot_dir: []const u8,
    budget: CaptureBudget,
) !void {
    if (attachment.id == 0) return error.InvalidImageId;
    try budget.check();

    var source = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), attachment.path, .{});
    defer source.close(io_mod.getIo());
    const source_stat = try source.stat(io_mod.getIo());
    return captureImageSnapshotFromOpenFileWithBudget(
        alloc,
        attachment,
        snapshot_dir,
        budget,
        &source,
        source_stat,
    );
}

pub const VisionRegularFile = struct {
    file: std.Io.File,
    identity: file_mutation_contract.FileIdentity,

    pub fn close(self: *VisionRegularFile) void {
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }
};

/// Opens a read-only Vision source without following the final symlink or
/// blocking on a special file. Hard-linked regular files remain valid inputs.
/// The caller owns the returned descriptor and must close it.
pub fn openVisionRegularFile(canonical_path: []const u8) !VisionRegularFile {
    if (!std.fs.path.isAbsolute(canonical_path)) return error.InvalidPath;

    const cwd = std.Io.Dir.cwd();
    const initial = cwd.statFile(io_mod.getIo(), canonical_path, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return error.NotRegularFile,
        else => return err,
    };
    if (initial.kind != .file) return error.NotRegularFile;

    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        var file = cwd.openFile(io_mod.getIo(), canonical_path, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.IsDir, error.SymLinkLoop, error.NotDir => return error.NotRegularFile,
            else => return err,
        };
        errdefer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file) return error.NotRegularFile;
        return .{
            .file = file,
            .identity = pathing.fileIdentity(
                try pathing.descriptorDevice(file.handle),
                stat,
            ),
        };
    }

    var flags: std.posix.O = .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;

    const fd = std.posix.openat(cwd.handle, canonical_path, flags, 0) catch |err| switch (err) {
        error.NoDevice, error.SymLinkLoop, error.NotDir => return error.NotRegularFile,
        else => return err,
    };
    var file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = true },
    };
    errdefer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file) return error.NotRegularFile;
    const identity = pathing.fileIdentity(
        try pathing.descriptorDevice(file.handle),
        stat,
    );
    try makeVisionRegularFileBlocking(&file);
    return .{ .file = file, .identity = identity };
}

fn makeVisionRegularFileBlocking(file: *std.Io.File) !void {
    const current = while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.GETFL,
            @as(usize, 0),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    };
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.SETFL,
            current & ~nonblock,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    }
    file.flags.nonblocking = false;
}

pub fn captureBoundImageAttachment(
    alloc: std.mem.Allocator,
    canonical_path: []const u8,
    expected_identity: file_mutation_contract.FileIdentity,
    image_id: usize,
    snapshot_dir: []const u8,
    budget: CaptureBudget,
) !types.ImageAttachment {
    if (!std.fs.path.isAbsolute(canonical_path)) return error.InvalidPath;
    if (image_id == 0) return error.InvalidImageId;
    try budget.check();

    var source = openVisionRegularFile(canonical_path) catch |err| switch (err) {
        error.NotRegularFile => return error.ImageTargetChanged,
        else => return err,
    };
    defer source.close();
    if (!std.meta.eql(source.identity, expected_identity)) {
        return error.ImageTargetChanged;
    }
    const source_stat = try source.file.stat(io_mod.getIo());

    var attachment: types.ImageAttachment = blk: {
        const owned_path = try alloc.dupe(u8, canonical_path);
        errdefer alloc.free(owned_path);
        break :blk .{
            .id = image_id,
            .path = owned_path,
            .media_type = try alloc.dupe(u8, ""),
        };
    };
    errdefer discardImageAttachment(alloc, attachment);
    try captureImageSnapshotFromOpenFileWithBudget(
        alloc,
        &attachment,
        snapshot_dir,
        budget,
        &source.file,
        source_stat,
    );
    return attachment;
}

fn captureImageSnapshotFromOpenFileWithBudget(
    alloc: std.mem.Allocator,
    attachment: *types.ImageAttachment,
    snapshot_dir: []const u8,
    budget: CaptureBudget,
    source: *std.Io.File,
    source_stat: std.Io.File.Stat,
) !void {
    if (source_stat.kind != .file) return error.NotRegularFile;
    if (source_stat.size > max_image_bytes) return error.ImageTooLarge;

    var snapshot_dir_handle = try openOrCreateSnapshotDirectoryNoFollow(snapshot_dir);
    defer snapshot_dir_handle.close(io_mod.getIo());

    const source_temp_name = try std.fmt.allocPrint(
        alloc,
        "image-{d}.source.{d}",
        .{ attachment.id, io_mod.nanoTimestamp() },
    );
    defer alloc.free(source_temp_name);
    var cleanup_source_temp = true;
    defer if (cleanup_source_temp) {
        deleteSnapshotFile(snapshot_dir_handle, source_temp_name, "capture_source_temp");
    };

    const source_metadata = try streamSourceToFile(
        source,
        snapshot_dir_handle,
        source_temp_name,
        max_image_bytes,
        budget,
    );
    try budget.check();

    var selected_temp_name: []const u8 = source_temp_name;
    var metadata = source_metadata;
    var candidate_temp_name: ?[]u8 = null;
    defer if (candidate_temp_name) |name| alloc.free(name);
    var cleanup_candidate_temp = false;
    defer if (cleanup_candidate_temp) {
        deleteSnapshotFile(
            snapshot_dir_handle,
            candidate_temp_name.?,
            "capture_candidate_temp",
        );
    };

    if (!fitsEncodedLimit(source_metadata.size_bytes)) {
        if (comptime builtin.os.tag != .macos) return error.ImagePreparationFailed;

        var candidate_suffix: u64 = undefined;
        io_mod.getIo().random(std.mem.asBytes(&candidate_suffix));
        candidate_temp_name = try std.fmt.allocPrint(
            alloc,
            "image-{d}.candidate.{x}",
            .{ attachment.id, candidate_suffix },
        );
        cleanup_candidate_temp = true;
        var candidate_placeholder = try snapshot_dir_handle.createFile(
            io_mod.getIo(),
            candidate_temp_name.?,
            .{
                .truncate = false,
                .exclusive = true,
                .permissions = std.Io.File.Permissions.fromMode(0o600),
                .resolve_beneath = true,
            },
        );
        candidate_placeholder.close(io_mod.getIo());

        const source_temp_path = try std.fs.path.join(
            alloc,
            &.{ snapshot_dir, source_temp_name },
        );
        defer alloc.free(source_temp_path);
        const candidate_temp_path = try std.fs.path.join(
            alloc,
            &.{ snapshot_dir, candidate_temp_name.? },
        );
        defer alloc.free(candidate_temp_path);

        prepareImageCandidate(source_temp_path, candidate_temp_path, budget) catch |err| switch (err) {
            error.FileNotFound => return error.ImagePreparationFailed,
            else => return err,
        };
        metadata = try inspectImageCandidate(
            snapshot_dir_handle,
            candidate_temp_name.?,
            budget,
        );
        selected_temp_name = candidate_temp_name.?;
    }

    const media_type = try alloc.dupe(u8, metadata.media_type);
    errdefer alloc.free(media_type);

    const final_name = try std.fmt.allocPrint(
        alloc,
        "image-{d}-{s}.bin",
        .{ attachment.id, metadata.digest_hex[0..16] },
    );
    defer alloc.free(final_name);
    const final_path = try std.fs.path.join(alloc, &.{ snapshot_dir, final_name });
    errdefer alloc.free(final_path);
    try budget.check();
    try snapshot_dir_handle.rename(
        selected_temp_name,
        snapshot_dir_handle,
        final_name,
        io_mod.getIo(),
    );
    if (std.mem.eql(u8, selected_temp_name, source_temp_name)) {
        cleanup_source_temp = false;
    } else {
        cleanup_candidate_temp = false;
    }
    var cleanup_final = true;
    errdefer if (cleanup_final) {
        deleteSnapshotFile(snapshot_dir_handle, final_name, "capture_final");
    };

    try syncSnapshotDirectory(snapshot_dir_handle);
    try budget.check();
    const digest_hex = try alloc.dupe(u8, &metadata.digest_hex);
    errdefer alloc.free(digest_hex);

    const old_snapshot_path = attachment.snapshot_path;
    const old_snapshot_sha256 = attachment.snapshot_sha256;
    const old_media_type = attachment.media_type;
    attachment.media_type = media_type;
    attachment.snapshot_path = final_path;
    attachment.snapshot_sha256 = digest_hex;
    cleanup_final = false;

    alloc.free(old_media_type);
    if (old_snapshot_path) |old| {
        if (!std.mem.eql(u8, old, final_path)) deleteSnapshotPath(old, "replaced_snapshot");
        alloc.free(old);
    }
    if (old_snapshot_sha256) |old| alloc.free(old);
}

fn streamSourceToFile(
    source: *std.Io.File,
    destination_dir: std.Io.Dir,
    destination_name: []const u8,
    limit: usize,
    budget: CaptureBudget,
) !SnapshotMetadata {
    var destination = try destination_dir.createFile(
        io_mod.getIo(),
        destination_name,
        .{
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .resolve_beneath = true,
        },
    );
    defer destination.close(io_mod.getIo());

    var hasher = Sha256.init(.{});
    var header: [64]u8 = undefined;
    var header_len: usize = 0;
    var read_buffer: [8192]u8 = undefined;
    var reader = source.readerStreaming(io_mod.getIo(), &read_buffer);
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var written: usize = 0;
    while (true) {
        try budget.check();
        const n = try reader.interface.readSliceShort(&transfer_buffer);
        if (n == 0) break;
        if (n > limit - written) return error.ImageTooLarge;
        const header_bytes = @min(n, header.len - header_len);
        @memcpy(header[header_len..][0..header_bytes], transfer_buffer[0..header_bytes]);
        header_len += header_bytes;
        hasher.update(transfer_buffer[0..n]);
        try destination.writeStreamingAll(io_mod.getIo(), transfer_buffer[0..n]);
        written += n;
    }
    try budget.check();
    try destination.sync(io_mod.getIo());

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const media_type = detectMediaTypeFromBytes(header[0..header_len]) orelse
        return error.UnsupportedImageType;
    return .{
        .digest_hex = std.fmt.bytesToHex(digest, .lower),
        .media_type = media_type,
        .size_bytes = written,
    };
}

const SnapshotMetadata = struct {
    digest_hex: [snapshot_digest_hex_len]u8,
    media_type: []const u8,
    size_bytes: usize,
};

fn fitsEncodedLimit(raw_bytes: usize) bool {
    const rounded = std.math.add(usize, raw_bytes, 2) catch return false;
    const groups = @divTrunc(rounded, 3);
    const encoded_bytes = std.math.mul(usize, groups, 4) catch return false;
    return encoded_bytes <= max_encoded_image_bytes;
}

const ImageNormalizerEvent = union(enum) {
    wait: anyerror!std.process.Child.Term,
    timeout: anyerror!void,
    cancelled: anyerror!void,
};

fn waitForImageNormalizerChild(child: *std.process.Child) anyerror!std.process.Child.Term {
    return child.wait(io_mod.getIo());
}

fn waitForImageNormalizerTimeout(deadline: std.Io.Clock.Timestamp) anyerror!void {
    return std.Io.Timeout.sleep(.{ .deadline = deadline }, io_mod.getIo());
}

fn waitForImageNormalizerCancellation(
    cancel_flag: *const std.atomic.Value(bool),
) anyerror!void {
    while (!cancel_flag.load(.acquire)) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForImageNormalizer(
    child: *std.process.Child,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*const std.atomic.Value(bool),
) !std.process.Child.Term {
    var select_buffer: [3]ImageNormalizerEvent = undefined;
    var select: std.Io.Select(ImageNormalizerEvent) = .init(
        io_mod.getIo(),
        &select_buffer,
    );
    select.concurrent(.wait, waitForImageNormalizerChild, .{child}) catch |err|
        return err;
    select.concurrent(
        .timeout,
        waitForImageNormalizerTimeout,
        .{deadline},
    ) catch |err| {
        select.cancelDiscard();
        return err;
    };
    if (cancel_flag) |flag| {
        select.concurrent(
            .cancelled,
            waitForImageNormalizerCancellation,
            .{flag},
        ) catch |err| {
            select.cancelDiscard();
            return err;
        };
    }

    const event = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    return switch (event) {
        .wait => |result| blk: {
            select.cancelDiscard();
            break :blk result catch |err| return err;
        },
        .timeout => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            return error.TimedOut;
        },
        .cancelled => |result| {
            result catch |err| {
                select.cancelDiscard();
                return err;
            };
            select.cancelDiscard();
            return error.Cancelled;
        },
    };
}

fn runImageNormalizerProcess(
    argv: []const []const u8,
    budget: CaptureBudget,
) !void {
    try budget.check();
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io_mod.getIo());

    const deadline = budget.deadline orelse
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), image_normalization_timeout);
    const term = try waitForImageNormalizer(&child, deadline, budget.cancel_flag);
    switch (term) {
        .exited => |code| if (code != 0) return error.ImagePreparationFailed,
        .signal, .stopped, .unknown => return error.ImagePreparationFailed,
    }
}

fn prepareImageCandidate(
    source_path: []const u8,
    candidate_path: []const u8,
    budget: CaptureBudget,
) !void {
    const argv = [_][]const u8{
        "/usr/bin/sips",
        "-s",
        "format",
        "jpeg",
        "-s",
        "formatOptions",
        "85",
        "-Z",
        "2000",
        source_path,
        "--out",
        candidate_path,
    };
    try runImageNormalizerProcess(&argv, budget);
}

fn inspectImageCandidate(
    snapshot_dir: std.Io.Dir,
    candidate_name: []const u8,
    budget: CaptureBudget,
) !SnapshotMetadata {
    try budget.check();
    var candidate = snapshot_dir.openFile(io_mod.getIo(), candidate_name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound, error.IsDir, error.NotDir, error.SymLinkLoop => return error.ImagePreparationFailed,
        else => return err,
    };
    defer candidate.close(io_mod.getIo());
    const stat = try candidate.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.ImagePreparationFailed;
    const size_bytes = std.math.cast(usize, stat.size) orelse
        return error.ImagePreparationFailed;
    if (size_bytes > max_image_bytes or !fitsEncodedLimit(size_bytes)) {
        return error.ImagePreparationFailed;
    }

    var hasher = Sha256.init(.{});
    var header: [64]u8 = undefined;
    var header_len: usize = 0;
    var read_buffer: [8192]u8 = undefined;
    var reader = candidate.readerStreaming(io_mod.getIo(), &read_buffer);
    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    var read_bytes: usize = 0;
    while (true) {
        try budget.check();
        const n = try reader.interface.readSliceShort(&transfer_buffer);
        if (n == 0) break;
        if (n > max_image_bytes - read_bytes) return error.ImagePreparationFailed;
        const header_bytes = @min(n, header.len - header_len);
        @memcpy(header[header_len..][0..header_bytes], transfer_buffer[0..header_bytes]);
        header_len += header_bytes;
        hasher.update(transfer_buffer[0..n]);
        read_bytes += n;
    }
    if (read_bytes != size_bytes or !fitsEncodedLimit(read_bytes)) {
        return error.ImagePreparationFailed;
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const media_type = detectMediaTypeFromBytes(header[0..header_len]) orelse
        return error.ImagePreparationFailed;
    return .{
        .digest_hex = std.fmt.bytesToHex(digest, .lower),
        .media_type = media_type,
        .size_bytes = read_bytes,
    };
}

fn syncSnapshotDirectory(snapshot_dir: std.Io.Dir) !void {
    io_mod.syncVerifiedDir(snapshot_dir) catch |err| switch (err) {
        error.OperationUnsupported => {},
        else => return err,
    };
}

fn deleteSnapshotFile(dir: std.Io.Dir, name: []const u8, reason: []const u8) void {
    dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => debug_trace.logf(
            "images",
            "event=snapshot_cleanup_failed reason={s} err={s}",
            .{ reason, @errorName(err) },
        ),
    };
}

fn deleteSnapshotPath(path: []const u8, reason: []const u8) void {
    const parent_path = std.fs.path.dirname(path) orelse {
        debug_trace.logf(
            "images",
            "event=snapshot_cleanup_failed reason={s} err=ImageSnapshotPathUnsafe",
            .{reason},
        );
        return;
    };
    const name = std.fs.path.basename(path);
    var parent = openDirectoryNoFollow(parent_path) catch |err| {
        debug_trace.logf(
            "images",
            "event=snapshot_cleanup_failed reason={s} err={s}",
            .{ reason, @errorName(err) },
        );
        return;
    };
    defer parent.close(io_mod.getIo());
    deleteSnapshotFile(parent, name, reason);
}

pub const VerifiedSnapshot = struct {
    bytes: []u8,
    media_type: []const u8,

    pub fn deinit(self: *VerifiedSnapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

fn unsafeSnapshotPathError(err: anyerror) anyerror {
    return switch (err) {
        error.SymLinkLoop, error.NotDir, error.IsDir => error.ImageSnapshotPathUnsafe,
        else => err,
    };
}

fn validateSnapshotPathComponent(component: []const u8) !void {
    if (component.len == 0 or
        std.mem.eql(u8, component, ".") or
        std.mem.eql(u8, component, "..") or
        std.mem.indexOfAny(u8, component, "/\\") != null)
    {
        return error.ImageSnapshotPathUnsafe;
    }
}

fn openDirectoryNoFollow(path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.ImageSnapshotPathUnsafe;

    var components = std.fs.path.componentIterator(path);
    const root = components.root() orelse return error.ImageSnapshotPathUnsafe;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{
        .follow_symlinks = false,
    }) catch |err| return unsafeSnapshotPathError(err);
    errdefer dir.close(io_mod.getIo());

    while (components.next()) |component| {
        try validateSnapshotPathComponent(component.name);
        const next = dir.openDir(io_mod.getIo(), component.name, .{
            .follow_symlinks = false,
        }) catch |err| return unsafeSnapshotPathError(err);
        dir.close(io_mod.getIo());
        dir = next;
    }
    return dir;
}

/// Iteration is requested so the handle is a real descriptor. Linux returns an `O_PATH`
/// descriptor otherwise, which serves `openat` and `renameat` but rejects the `fsync`
/// this directory needs after the snapshot rename.
const snapshot_dir_open_options: std.Io.Dir.OpenOptions = .{
    .iterate = true,
    .follow_symlinks = false,
};

fn openOrCreateSnapshotDirectoryNoFollow(path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.ImageSnapshotPathUnsafe;
    const parent_path = std.fs.path.dirname(path) orelse return error.ImageSnapshotPathUnsafe;
    const name = std.fs.path.basename(path);
    try validateSnapshotPathComponent(name);

    var parent = try openDirectoryNoFollow(parent_path);
    defer parent.close(io_mod.getIo());
    return parent.openDir(
        io_mod.getIo(),
        name,
        snapshot_dir_open_options,
    ) catch |err| switch (err) {
        error.FileNotFound => blk: {
            parent.createDir(
                io_mod.getIo(),
                name,
                std.Io.File.Permissions.fromMode(0o700),
            ) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return unsafeSnapshotPathError(create_err),
            };
            break :blk parent.openDir(
                io_mod.getIo(),
                name,
                snapshot_dir_open_options,
            ) catch |open_err| return unsafeSnapshotPathError(open_err);
        },
        else => return unsafeSnapshotPathError(err),
    };
}

fn openSnapshotFileNoFollow(path: []const u8) !std.Io.File {
    if (!std.fs.path.isAbsolute(path)) return error.ImageSnapshotPathUnsafe;
    const parent_path = std.fs.path.dirname(path) orelse return error.ImageSnapshotPathUnsafe;
    const name = std.fs.path.basename(path);
    try validateSnapshotPathComponent(name);

    var parent = try openDirectoryNoFollow(parent_path);
    defer parent.close(io_mod.getIo());
    return parent.openFile(io_mod.getIo(), name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| return unsafeSnapshotPathError(err);
}

pub fn loadVerifiedSnapshot(
    alloc: std.mem.Allocator,
    attachment: types.ImageAttachment,
    budget: CaptureBudget,
) !VerifiedSnapshot {
    const path = attachment.snapshot_path orelse return error.MissingImageSnapshot;
    const expected = attachment.snapshot_sha256 orelse return error.MissingImageSnapshot;
    if (expected.len != snapshot_digest_hex_len) return error.InvalidImageSnapshotDigest;
    try budget.check();

    var file = try openSnapshotFileNoFollow(path);
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.NotRegularFile;
    const size = std.math.cast(usize, stat.size) orelse return error.ImageTooLarge;
    if (size > max_image_bytes) return error.ImageTooLarge;

    var hasher = Sha256.init(.{});
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    try bytes.ensureTotalCapacity(alloc, size);
    var read_buf: [8192]u8 = undefined;
    var reader = file.readerStreaming(io_mod.getIo(), &read_buf);
    var transfer_buf: [transfer_buffer_bytes]u8 = undefined;
    while (true) {
        try budget.check();
        const n = try reader.interface.readSliceShort(&transfer_buf);
        if (n == 0) break;
        if (n > max_image_bytes - bytes.items.len) return error.ImageTooLarge;
        try bytes.appendSlice(alloc, transfer_buf[0..n]);
        hasher.update(transfer_buf[0..n]);
    }
    var actual: [Sha256.digest_length]u8 = undefined;
    hasher.final(&actual);
    const actual_hex = std.fmt.bytesToHex(actual, .lower);
    if (!std.mem.eql(u8, actual_hex[0..], expected)) return error.ImageSnapshotCorrupt;

    const detected = detectMediaTypeFromBytes(bytes.items) orelse
        return error.UnsupportedImageType;
    if (!std.mem.eql(u8, detected, attachment.media_type)) return error.ImageSnapshotMediaTypeMismatch;
    return .{
        .bytes = try bytes.toOwnedSlice(alloc),
        .media_type = detected,
    };
}

/// Returns a new attachment with independently owned snapshot bytes for `new_id`.
/// The source snapshot remains owned by the caller.
pub fn cloneVerifiedImageAttachment(
    alloc: std.mem.Allocator,
    attachment: types.ImageAttachment,
    new_id: usize,
) !types.ImageAttachment {
    if (new_id == 0) return error.InvalidImageId;
    const source_snapshot_path = attachment.snapshot_path orelse
        return error.MissingImageSnapshot;
    const snapshot_dir = std.fs.path.dirname(source_snapshot_path) orelse
        return error.ImageSnapshotPathUnsafe;
    return copyVerifiedImageAttachmentToDir(
        alloc,
        attachment,
        new_id,
        snapshot_dir,
    );
}

pub fn copyVerifiedImageAttachmentToDir(
    alloc: std.mem.Allocator,
    attachment: types.ImageAttachment,
    new_id: usize,
    snapshot_dir: []const u8,
) !types.ImageAttachment {
    if (new_id == 0) return error.InvalidImageId;
    const source_digest = attachment.snapshot_sha256 orelse
        return error.MissingImageSnapshot;
    var verified = try loadVerifiedSnapshot(alloc, attachment, .{});
    defer verified.deinit(alloc);

    const path = try alloc.dupe(u8, attachment.path);
    errdefer alloc.free(path);
    const media_type = try alloc.dupe(u8, verified.media_type);
    errdefer alloc.free(media_type);
    const digest = try alloc.dupe(u8, source_digest);
    errdefer alloc.free(digest);

    const final_name = try std.fmt.allocPrint(
        alloc,
        "image-{d}-{s}.bin",
        .{ new_id, source_digest[0..16] },
    );
    defer alloc.free(final_name);
    const final_path = try std.fs.path.join(alloc, &.{ snapshot_dir, final_name });
    errdefer alloc.free(final_path);

    const temp_name = try std.fmt.allocPrint(
        alloc,
        "image-{d}.clone.{d}",
        .{ new_id, io_mod.nanoTimestamp() },
    );
    defer alloc.free(temp_name);

    var snapshot_dir_handle = try openOrCreateSnapshotDirectoryNoFollow(snapshot_dir);
    defer snapshot_dir_handle.close(io_mod.getIo());
    var cleanup_temp = true;
    defer if (cleanup_temp) {
        deleteSnapshotFile(snapshot_dir_handle, temp_name, "clone_snapshot_temp");
    };

    var destination = try snapshot_dir_handle.createFile(
        io_mod.getIo(),
        temp_name,
        .{
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .resolve_beneath = true,
        },
    );
    defer destination.close(io_mod.getIo());
    try destination.writeStreamingAll(io_mod.getIo(), verified.bytes);
    try destination.sync(io_mod.getIo());
    try snapshot_dir_handle.rename(
        temp_name,
        snapshot_dir_handle,
        final_name,
        io_mod.getIo(),
    );
    cleanup_temp = false;
    var cleanup_final = true;
    errdefer if (cleanup_final) {
        deleteSnapshotFile(snapshot_dir_handle, final_name, "clone_snapshot_final");
    };
    try syncSnapshotDirectory(snapshot_dir_handle);

    cleanup_final = false;
    return .{
        .id = new_id,
        .path = path,
        .media_type = media_type,
        .snapshot_path = final_path,
        .snapshot_sha256 = digest,
    };
}

pub fn captureImageSnapshots(
    alloc: std.mem.Allocator,
    attachments: []types.ImageAttachment,
    snapshot_dir: []const u8,
    budget: CaptureBudget,
) !void {
    var captured: usize = 0;
    errdefer {
        for (attachments[0..captured]) |*attachment| discardImageSnapshot(alloc, attachment);
    }
    for (attachments) |*attachment| {
        try captureImageSnapshotWithBudget(alloc, attachment, snapshot_dir, budget);
        captured += 1;
    }
}

pub fn discardImageSnapshot(alloc: std.mem.Allocator, attachment: *types.ImageAttachment) void {
    if (attachment.snapshot_path) |path| {
        deleteSnapshotPath(path, "discard_snapshot");
        alloc.free(path);
        attachment.snapshot_path = null;
    }
    if (attachment.snapshot_sha256) |digest| {
        alloc.free(digest);
        attachment.snapshot_sha256 = null;
    }
}

pub fn discardImageSnapshots(alloc: std.mem.Allocator, attachments: []types.ImageAttachment) void {
    for (attachments, 0..) |*attachment, index| {
        if (attachment.snapshot_path) |path| {
            var duplicate = false;
            for (attachments[0..index]) |previous| {
                if (previous.snapshot_path) |previous_path| {
                    if (std.mem.eql(u8, path, previous_path)) {
                        duplicate = true;
                        break;
                    }
                }
            }
            if (!duplicate) deleteSnapshotPath(path, "discard_snapshot_slice");
        }
        if (attachment.snapshot_path) |owned| alloc.free(owned);
        if (attachment.snapshot_sha256) |owned| alloc.free(owned);
        attachment.snapshot_path = null;
        attachment.snapshot_sha256 = null;
    }
}

pub fn deleteUnreferencedImageSnapshots(
    candidates: []const types.ImageAttachment,
    retained: []const types.ImageAttachment,
) void {
    for (candidates, 0..) |candidate, index| {
        const path = candidate.snapshot_path orelse continue;
        var duplicate = false;
        for (candidates[0..index]) |previous| {
            if (previous.snapshot_path) |previous_path| {
                if (std.mem.eql(u8, path, previous_path)) {
                    duplicate = true;
                    break;
                }
            }
        }
        if (duplicate) continue;

        for (retained) |attachment| {
            if (attachment.snapshot_path) |retained_path| {
                if (std.mem.eql(u8, path, retained_path)) break;
            }
        } else {
            deleteSnapshotPath(path, "discard_unreferenced_snapshot");
        }
    }
}

pub fn discardImageAttachment(alloc: std.mem.Allocator, attachment: types.ImageAttachment) void {
    var owned = attachment;
    discardImageSnapshot(alloc, &owned);
    types.freeImageAttachment(alloc, owned);
}

pub fn discardImageAttachmentSlice(alloc: std.mem.Allocator, attachments: []types.ImageAttachment) void {
    discardImageSnapshots(alloc, attachments);
    types.freeImageAttachmentSlice(alloc, attachments);
}

pub fn writeImageBadge(writer: *std.Io.Writer, image_id: usize, abs_path: []const u8) !void {
    try writer.writeAll("\x1b]8;;file://");
    try writePercentEncodedPath(writer, abs_path);
    try writer.print("\x1b\\[Image {d}]\x1b]8;;\x1b\\", .{image_id});
}

pub fn writeImageBadgeClipped(writer: *std.Io.Writer, image_id: usize, abs_path: []const u8, max_cells: usize) !void {
    if (max_cells == 0) return;

    var label_buf: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buf, "[Image {d}]", .{image_id});
    const clipped_label = display_width.prefixByWidth(label, max_cells);

    try writer.writeAll("\x1b]8;;file://");
    try writePercentEncodedPath(writer, abs_path);
    try writer.writeAll("\x1b\\");
    try writer.writeAll(clipped_label);
    try writer.writeAll("\x1b]8;;\x1b\\");
}

pub fn imageBadgeVisibleWidth(image_id: usize) usize {
    var digits: usize = 1;
    var n = image_id;
    while (n >= 10) {
        digits += 1;
        n /= 10;
    }
    return "[Image ".len + digits + "]".len;
}

pub fn allocateImageId(counter: *usize) usize {
    const id = counter.*;
    counter.* += 1;
    return id;
}

pub const ImagePlaceholderSpan = struct { start: usize, end: usize, id: usize };

const ImagePlaceholderMatch = struct { id: usize, length: usize };

const image_placeholder_prefix = "[Image #";

pub fn writeImagePlaceholder(writer: *std.Io.Writer, id: usize) std.Io.Writer.Error!void {
    return writer.print("{s}{d}]", .{ image_placeholder_prefix, id });
}

pub fn formatImagePlaceholder(buf: []u8, id: usize) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writeImagePlaceholder(&writer, id) catch return error.NoSpaceLeft;
    return writer.buffered();
}

pub fn matchImagePlaceholder(text: []const u8, start: usize) ?ImagePlaceholderMatch {
    if (start > text.len or text.len - start < image_placeholder_prefix.len) return null;
    if (!std.mem.eql(u8, text[start .. start + image_placeholder_prefix.len], image_placeholder_prefix)) return null;

    var i = start + image_placeholder_prefix.len;
    var id: usize = 0;
    var digits: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        id = std.math.mul(usize, id, 10) catch return null;
        id = std.math.add(usize, id, text[i] - '0') catch return null;
        digits += 1;
    }
    if (digits == 0) return null;
    if (i >= text.len or text[i] != ']') return null;
    return .{ .id = id, .length = i + 1 - start };
}

pub fn imageAttachmentsSortedById(images: []const types.ImageAttachment) bool {
    var previous: ?usize = null;
    for (images) |image| {
        if (previous) |id| {
            if (image.id <= id) return false;
        }
        previous = image.id;
    }
    return true;
}

pub fn findImageIndexByIdSorted(images: []const types.ImageAttachment, id: usize) ?usize {
    var left: usize = 0;
    var right: usize = images.len;
    while (left < right) {
        const mid = left + (right - left) / 2;
        const mid_id = images[mid].id;
        if (mid_id == id) return mid;
        if (mid_id < id) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    return null;
}

pub fn findImageIndexById(images: []const types.ImageAttachment, id: usize) ?usize {
    for (images, 0..) |image, index| {
        if (image.id == id) return index;
    }
    return null;
}

pub const ImageIdBounds = struct {
    maximum_id: ?usize,
    next_id: usize,
};

pub fn validate_image_ids(image_ids: []const usize) error{ EmptyImageIds, InvalidImageId, DuplicateImageId }!void {
    if (image_ids.len == 0) return error.EmptyImageIds;
    for (image_ids, 0..) |image_id, index| {
        if (image_id == 0) return error.InvalidImageId;
        for (image_ids[0..index]) |previous_id| {
            if (image_id == previous_id) return error.DuplicateImageId;
        }
    }
}

/// Returns a caller-owned slice of pointers borrowed from `catalog`. The
/// caller frees only the returned slice with `alloc`.
pub fn resolve_authorized_images(
    alloc: std.mem.Allocator,
    catalog: []const types.ImageAttachment,
    requested_ids: []const usize,
) (std.mem.Allocator.Error || error{
    EmptyImageIds,
    InvalidImageId,
    DuplicateImageId,
    InvalidImageCatalog,
    UnauthorizedImageId,
})![]const *const types.ImageAttachment {
    try validate_image_ids(requested_ids);
    if (!imageAttachmentsSortedById(catalog)) return error.InvalidImageCatalog;

    const resolved = try alloc.alloc(*const types.ImageAttachment, requested_ids.len);
    errdefer alloc.free(resolved);
    for (requested_ids, 0..) |image_id, index| {
        const catalog_index = findImageIndexByIdSorted(catalog, image_id) orelse
            return error.UnauthorizedImageId;
        resolved[index] = &catalog[catalog_index];
    }
    return resolved;
}

pub fn calculate_next_image_id(
    images: []const types.ImageAttachment,
) error{ InvalidImageId, ImageIdOverflow }!ImageIdBounds {
    var maximum_id: ?usize = null;
    for (images) |image| {
        if (image.id == 0) return error.InvalidImageId;
        if (maximum_id == null or image.id > maximum_id.?) maximum_id = image.id;
    }
    if (maximum_id) |value| {
        return .{
            .maximum_id = value,
            .next_id = std.math.add(usize, value, 1) catch return error.ImageIdOverflow,
        };
    }
    return .{ .maximum_id = null, .next_id = 1 };
}

/// Returns the placeholder span at `cursor` — either enclosing the cursor or
/// with its closing `]` at `cursor - 1`. Used by backspace to delete the whole
/// `[Image #N]` token atomically.
pub fn findEnclosingImagePlaceholder(text: []const u8, cursor: usize) ?ImagePlaceholderSpan {
    var scan = cursor;
    while (scan > 0) {
        scan -= 1;
        if (text[scan] != '[') continue;
        const match = matchImagePlaceholder(text, scan) orelse continue;
        const end = scan + match.length;
        if (cursor > end) return null;
        return .{ .start = scan, .end = end, .id = match.id };
    }
    return null;
}

/// Returns the placeholder span starting at `byte_offset`, or null if no
/// placeholder begins there. Used by cursor-right to skip the whole token.
pub fn imagePlaceholderSpanStartingAt(text: []const u8, byte_offset: usize) ?ImagePlaceholderSpan {
    if (byte_offset >= text.len or text[byte_offset] != '[') return null;
    const match = matchImagePlaceholder(text, byte_offset) orelse return null;
    return .{ .start = byte_offset, .end = byte_offset + match.length, .id = match.id };
}

/// Returns the placeholder span ending exactly at `byte_offset`, or null if no
/// placeholder ends there. Used by cursor-left to skip the whole token.
pub fn imagePlaceholderSpanEndingAt(text: []const u8, byte_offset: usize) ?ImagePlaceholderSpan {
    if (byte_offset == 0 or byte_offset > text.len) return null;
    if (text[byte_offset - 1] != ']') return null;
    var scan = byte_offset;
    while (scan > 0) {
        scan -= 1;
        if (text[scan] != '[') continue;
        const match = matchImagePlaceholder(text, scan) orelse continue;
        if (scan + match.length == byte_offset) {
            return .{ .start = scan, .end = byte_offset, .id = match.id };
        }
        return null;
    }
    return null;
}

pub const ExpandWithBadgesResult = struct { cursor_out: ?usize, expanded_any: bool };

/// Replaces known image placeholders with path-free badges keyed by attachment ID.
/// Unknown placeholders pass through; `cursor_out` maps `cursor_in` to output bytes.
pub fn expandPlaceholdersWithBadges(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
    images: []const types.ImageAttachment,
    cursor_in: ?usize,
) !ExpandWithBadgesResult {
    return expandPlaceholdersWithBadgeMode(
        alloc,
        writer,
        text,
        images,
        cursor_in,
        false,
    );
}

pub fn expandPlaceholdersWithLinkedBadges(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
    images: []const types.ImageAttachment,
    cursor_in: ?usize,
) !ExpandWithBadgesResult {
    return expandPlaceholdersWithBadgeMode(
        alloc,
        writer,
        text,
        images,
        cursor_in,
        true,
    );
}

fn expandPlaceholdersWithBadgeMode(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
    images: []const types.ImageAttachment,
    cursor_in: ?usize,
    linked: bool,
) !ExpandWithBadgesResult {
    var cursor_out: ?usize = null;
    var written: usize = 0;
    var expanded_any = false;
    var i: usize = 0;
    while (i < text.len) {
        if (cursor_in) |c| {
            if (cursor_out == null and i >= c) cursor_out = written;
        }
        if (text[i] == '[') {
            if (matchImagePlaceholder(text, i)) |match| {
                if (findImageById(images, match.id)) |img| {
                    expanded_any = true;
                    var badge_buf: std.Io.Writer.Allocating = .init(alloc);
                    defer badge_buf.deinit();
                    if (linked) {
                        try writeImageBadge(&badge_buf.writer, img.id, img.path);
                    } else {
                        try badge_buf.writer.print("[Image {d}]", .{img.id});
                    }
                    const badge_bytes = badge_buf.written();
                    try writer.writeAll(badge_bytes);
                    written += badge_bytes.len;
                } else {
                    try writer.writeAll(text[i .. i + match.length]);
                    written += match.length;
                }
                i += match.length;
                continue;
            }
        }
        try writer.writeByte(text[i]);
        written += 1;
        i += 1;
    }
    if (cursor_in) |c| {
        if (cursor_out == null and c >= text.len) cursor_out = written;
    }
    return .{ .cursor_out = cursor_out, .expanded_any = expanded_any };
}

fn findImageById(images: []const types.ImageAttachment, id: usize) ?types.ImageAttachment {
    for (images) |img| {
        if (img.id == id) return img;
    }
    return null;
}

fn writePercentEncodedPath(writer: *std.Io.Writer, path: []const u8) !void {
    for (path) |byte| {
        if (isUriPathSafe(byte)) {
            try writer.writeByte(byte);
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
}

fn isUriPathSafe(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or
        byte == '.' or
        byte == '_' or
        byte == '~' or
        byte == '/';
}

pub fn writeImageFilePartJson(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    attachment: types.ImageAttachment,
) !void {
    return writeImageFilePartJsonWithBudget(alloc, writer, attachment, .{});
}

pub fn writeImageFilePartJsonWithBudget(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    attachment: types.ImageAttachment,
    budget: CaptureBudget,
) !void {
    var snapshot = try loadVerifiedSnapshot(alloc, attachment, budget);
    defer snapshot.deinit(alloc);
    try writeVerifiedImageFilePartJsonWithBudget(writer, snapshot, budget);
}

pub fn writeReviewImageFilePartJson(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    attachment: types.ImageAttachment,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) !void {
    return writeImageFilePartJsonWithBudget(alloc, writer, attachment, .{
        .deadline = deadline,
        .cancel_flag = cancel_flag,
    });
}

pub fn writeVerifiedImageFilePartJsonWithBudget(
    writer: *std.Io.Writer,
    snapshot: VerifiedSnapshot,
    budget: CaptureBudget,
) !void {
    try budget.check();

    try writer.writeAll("{\"type\":\"file\",\"mediaType\":\"");
    try writer.writeAll(snapshot.media_type);
    try writer.writeAll("\",\"data\":\"");

    var offset: usize = 0;
    while (offset < snapshot.bytes.len) {
        try budget.check();
        const end = @min(offset + 3 * 1024, snapshot.bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, snapshot.bytes[offset..end]);
        offset = end;
    }

    try writer.writeAll("\"}");
    try budget.check();
}

pub fn extractInlineImageAttachments(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    text: []const u8,
    first_image_id: usize,
) !ExtractedInlineImages {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();

    var images: std.ArrayList(types.ImageAttachment) = .empty;
    errdefer {
        for (images.items) |image| types.freeImageAttachment(alloc, image);
        images.deinit(alloc);
    }
    var image_spans: std.ArrayList(ImagePlaceholderSpan) = .empty;
    errdefer image_spans.deinit(alloc);

    var i: usize = 0;
    while (true) {
        while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
        if (i >= text.len) break;

        const start = i;
        const end = nextShellTokenEnd(text, start);
        const raw = text[start..end];
        i = end;

        if (splitImagePathToken(raw)) |token| {
            const attachment = loadUserImageAttachment(alloc, workspace_root, token.path) catch |err| switch (err) {
                error.FileNotFound,
                error.HomeNotSet,
                error.InvalidPath,
                error.NotRegularFile,
                error.UnsupportedImageType,
                => blk: {
                    debug_trace.logf(
                        "images",
                        "event=inline_image_promotion_skipped reason={s}",
                        .{@errorName(err)},
                    );
                    try appendToken(&output.writer, raw);
                    break :blk null;
                },
                else => return err,
            };
            if (attachment) |loaded_image| {
                var image = loaded_image;
                var owns_image = true;
                errdefer if (owns_image) types.freeImageAttachment(alloc, image);
                image.id = try std.math.add(usize, first_image_id, images.items.len);
                try images.append(alloc, image);
                owns_image = false;
                var placeholder_buf: [64]u8 = undefined;
                const placeholder = try formatImagePlaceholder(&placeholder_buf, image.id);
                const placeholder_start = output.written().len + @intFromBool(output.written().len > 0);
                try appendToken(&output.writer, placeholder);
                try image_spans.append(alloc, .{
                    .start = placeholder_start,
                    .end = placeholder_start + placeholder.len,
                    .id = image.id,
                });
                try output.writer.writeAll(token.suffix);
                continue;
            }
        } else {
            try appendToken(&output.writer, raw);
        }
    }

    const owned_images = try images.toOwnedSlice(alloc);
    errdefer types.freeImageAttachmentSlice(alloc, owned_images);
    const owned_spans = try image_spans.toOwnedSlice(alloc);
    errdefer alloc.free(owned_spans);
    const compact = std.mem.trim(u8, output.written(), " \t\r\n");
    const owned = try output.toOwnedSlice();
    errdefer alloc.free(owned);
    if (compact.len != owned.len) {
        const trimmed = try alloc.dupe(u8, compact);
        alloc.free(owned);
        return .{
            .text = trimmed,
            .images = owned_images,
            .image_spans = owned_spans,
        };
    }

    return .{
        .text = owned,
        .images = owned_images,
        .image_spans = owned_spans,
    };
}

pub const ClipboardImageAttachment = struct {
    attachment: ?types.ImageAttachment,
    source_dir: []u8,

    pub fn takeAttachment(self: *ClipboardImageAttachment) types.ImageAttachment {
        const attachment = self.attachment orelse unreachable;
        self.attachment = null;
        return attachment;
    }

    pub fn deinit(self: *ClipboardImageAttachment, alloc: std.mem.Allocator) void {
        if (self.attachment) |attachment| types.freeImageAttachment(alloc, attachment);
        cleanupSnapshotDir(self.source_dir);
        alloc.free(self.source_dir);
        self.* = undefined;
    }
};

pub fn loadClipboardImageAttachment(alloc: std.mem.Allocator) !ClipboardImageAttachment {
    if (builtin.os.tag != .macos) return error.Unsupported;

    const source_dir = try createTempSnapshotDir(alloc);
    errdefer {
        cleanupSnapshotDir(source_dir);
        alloc.free(source_dir);
    }
    const temp_path = try std.fs.path.join(alloc, &.{ source_dir, "clipboard.png" });
    defer alloc.free(temp_path);

    const write_script = try std.fmt.allocPrint(
        alloc,
        "set outFile to POSIX file \"{s}\"\n" ++
            "set pngData to the clipboard as «class PNGf»\n" ++
            "set fileRef to open for access outFile with write permission\n" ++
            "set eof fileRef to 0\n" ++
            "write pngData to fileRef\n" ++
            "close access fileRef\n",
        .{temp_path},
    );
    defer alloc.free(write_script);

    const argv = [_][]const u8{ "osascript", "-e", write_script };
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &argv,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            const attachment = try loadImageAttachment(alloc, temp_path);
            return .{
                .attachment = attachment,
                .source_dir = source_dir,
            };
        },
        else => {},
    }

    return error.NoClipboardImage;
}

fn readImageHeaderBytes(path: []const u8, out: []u8) ![]const u8 {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);

    const stat = try file.stat(zio);
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > max_image_bytes) return error.ImageTooLarge;
    return readImageHeaderFromFile(&file, @intCast(stat.size), out);
}

fn readImageHeaderFromFile(
    file: *std.Io.File,
    expected_size: usize,
    out: []u8,
) ![]const u8 {
    const zio = io_mod.getIo();
    const header_len = @min(expected_size, out.len);

    var read_buf: [4096]u8 = undefined;
    var r = file.reader(zio, &read_buf);
    const n = try r.interface.readSliceShort(out[0..header_len]);
    return out[0..n];
}

fn normalizePathInput(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const slice = stripBalancedOuterQuotes(trimmed);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        if (slice[i] == '\\' and i + 1 < slice.len) {
            i += 1;
            try out.writer.writeByte(slice[i]);
            continue;
        }
        try out.writer.writeByte(slice[i]);
    }

    return out.toOwnedSlice();
}

fn detectMediaTypeFromBytes(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

pub const ImagePathToken = struct {
    path: []const u8,
    suffix: []const u8,
};

pub fn splitImagePathToken(raw: []const u8) ?ImagePathToken {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const path_start: usize = if (std.mem.startsWith(u8, trimmed, "@")) 1 else 0;
    if (path_start == 1 and std.mem.startsWith(u8, trimmed[path_start..], "@")) return null;
    const suffix_start = trailingSentencePunctuationStart(trimmed);
    if (path_start >= suffix_start) return null;
    const path = trimmed[path_start..suffix_start];
    const ext = extensionIgnoringEscapes(stripBalancedOuterQuotes(path));
    if (!(std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".gif") or
        std.ascii.eqlIgnoreCase(ext, ".webp")))
    {
        return null;
    }
    return .{ .path = path, .suffix = trimmed[suffix_start..] };
}

pub fn looksLikeImagePathToken(raw: []const u8) bool {
    return splitImagePathToken(raw) != null;
}

fn trailingSentencePunctuationStart(bytes: []const u8) usize {
    var suffix_start = bytes.len;
    var quote: ?u8 = null;
    var escaped = false;
    for (bytes, 0..) |byte, index| {
        if (escaped) {
            suffix_start = index + 1;
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            suffix_start = index + 1;
            escaped = true;
            continue;
        }
        if (quote) |active| {
            suffix_start = index + 1;
            if (byte == active) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            suffix_start = index + 1;
            quote = byte;
            continue;
        }
        if (!isSentencePunctuation(byte)) suffix_start = index + 1;
    }
    return suffix_start;
}

fn isSentencePunctuation(byte: u8) bool {
    return byte == ',' or byte == '.' or byte == ';' or
        byte == ':' or byte == '!' or byte == '?';
}

fn stripBalancedOuterQuotes(bytes: []const u8) []const u8 {
    if (bytes.len < 2) return bytes;
    if ((bytes[0] == '"' and bytes[bytes.len - 1] == '"') or
        (bytes[0] == '\'' and bytes[bytes.len - 1] == '\''))
    {
        return bytes[1 .. bytes.len - 1];
    }
    return bytes;
}

pub fn hasImagePathToken(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        while (i < bytes.len and isWhitespace(bytes[i])) : (i += 1) {}
        if (i >= bytes.len) break;
        const start = i;
        i = nextShellTokenEnd(bytes, start);
        if (looksLikeImagePathToken(bytes[start..i])) return true;
    }
    return false;
}

fn extensionIgnoringEscapes(raw: []const u8) []const u8 {
    var dot_index: ?usize = null;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            continue;
        }
        if (raw[i] == '.') dot_index = i;
    }
    return if (dot_index) |idx| raw[idx..] else "";
}

pub fn nextShellTokenEnd(text: []const u8, start: usize) usize {
    var i = start;
    var quote: ?u8 = null;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (quote) |q| {
            if (ch == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (ch == q) quote = null;
            continue;
        }

        if (ch == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (isWhitespace(ch)) break;
    }
    return i;
}

pub fn isWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn appendToken(writer: *std.Io.Writer, raw: []const u8) !void {
    if (raw.len == 0) return;
    if (writer.buffered().len > 0) try writer.writeByte(' ');
    try writer.writeAll(raw);
}








































fn testSnapshotDir(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "snapshots" });
}

fn testCapturedAttachment(
    alloc: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    image_path: []const u8,
    id: usize,
    media_type: []const u8,
) !types.ImageAttachment {
    const source = [_]types.ImageAttachment{.{
        .id = id,
        .path = @constCast(image_path),
        .media_type = @constCast(media_type),
    }};
    const owned = try types.dupeImageAttachmentSlice(alloc, &source);
    defer alloc.free(owned);

    var attachment = owned[0];
    errdefer types.freeImageAttachment(alloc, attachment);
    const snapshot_dir = try testSnapshotDir(alloc, tmp);
    defer alloc.free(snapshot_dir);
    try captureImageSnapshot(alloc, &attachment, snapshot_dir);
    return attachment;
}

const SnapshotMutatingWriter = struct {
    snapshot_path: []const u8,
    replacement: []const u8,
    output: [4096]u8 = undefined,
    output_len: usize = 0,
    buffer: [1]u8 = undefined,
    interface: std.Io.Writer = undefined,
    mutated: bool = false,
    mutation_failed: bool = false,

    fn init(self: *SnapshotMutatingWriter, snapshot_path: []const u8, replacement: []const u8) void {
        self.* = .{
            .snapshot_path = snapshot_path,
            .replacement = replacement,
        };
        self.interface = .{
            .vtable = &.{ .drain = drain },
            .buffer = &self.buffer,
            .end = 0,
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *SnapshotMutatingWriter = @alignCast(@fieldParentPtr("interface", writer));
        if (!self.mutated) {
            self.mutated = true;
            var file = std.Io.Dir.createFileAbsolute(
                std.testing.io,
                self.snapshot_path,
                .{ .truncate = true },
            ) catch {
                self.mutation_failed = true;
                return error.WriteFailed;
            };
            defer file.close(std.testing.io);
            file.writeStreamingAll(std.testing.io, self.replacement) catch {
                self.mutation_failed = true;
                return error.WriteFailed;
            };
        }

        const buffered = writer.buffered();
        if (self.output.len - self.output_len < buffered.len) return error.WriteFailed;
        @memcpy(self.output[self.output_len..][0..buffered.len], buffered);
        self.output_len += buffered.len;
        writer.end = 0;

        var consumed: usize = 0;
        for (data, 0..) |part, index| {
            const repeat = if (index == data.len - 1) splat else 1;
            for (0..repeat) |_| {
                if (self.output.len - self.output_len < part.len) return error.WriteFailed;
                @memcpy(self.output[self.output_len..][0..part.len], part);
                self.output_len += part.len;
                consumed += part.len;
            }
        }
        return consumed;
    }

    fn written(self: *const SnapshotMutatingWriter) []const u8 {
        return self.output[0..self.output_len];
    }
};

const SnapshotReplacementHook = struct {
    snapshot_path: []const u8,
    replacement_path: []const u8,
    checks: usize = 0,

    fn check(raw: *anyopaque) !void {
        const self: *SnapshotReplacementHook = @ptrCast(@alignCast(raw));
        self.checks += 1;
        if (self.checks != 2) return;
        try std.Io.Dir.renameAbsolute(
            self.replacement_path,
            self.snapshot_path,
            std.testing.io,
        );
    }
};

fn countSnapshotFiles(snapshot_dir: []const u8) !usize {
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, snapshot_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file or entry.kind == .sym_link) count += 1;
    }
    return count;
}

fn testSha256Hex(bytes: []const u8) [snapshot_digest_hex_len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
































