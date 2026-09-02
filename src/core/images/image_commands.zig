const std = @import("std");
const image_attachments = @import("image_attachments.zig");
const types = @import("../shared/types.zig");
const entity_spans = @import("../shared/entity_spans.zig");
const render_request = @import("../../ui/render_request.zig");
const edit_contract = @import("../input/editor_state.zig");
const registered_entities = @import("../input/registered_entities.zig");

const InsertImageResult = enum { inserted, rejected, input_full };
const ImageSourceLifetime = enum { retained, temporary };

fn writeInputFullNotice(app: anytype) !void {
    try app.writeDomainNotice(.{
        .topic = "images",
        .tone = .neutral,
        .body = "input is full; image not attached",
    }, true);
}

pub fn Commands(comptime App: type) type {
    return struct {
        pub fn attachPath(app: *App, path: []const u8) !void {
            const trimmed = std.mem.trim(u8, path, " \t");
            if (trimmed.len == 0) {
                try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = "usage: /image <path>" }, true);
                return;
            }

            const image = image_attachments.loadUserImageAttachment(
                app.alloc,
                app.workspace_root,
                trimmed,
            ) catch |err| {
                const line = switch (err) {
                    error.UnsupportedImageType => try app.alloc.dupe(u8, "unsupported image type"),
                    error.FileNotFound => try app.alloc.dupe(u8, "image file not found"),
                    error.ImageTooLarge => try app.alloc.dupe(u8, image_attachments.image_too_large_notice),
                    else => try std.fmt.allocPrint(app.alloc, "failed to attach image: {s}", .{@errorName(err)}),
                };
                defer app.alloc.free(line);
                try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = line }, true);
                return;
            };
            switch (try insertImageAtCursor(App, app, image, .retained)) {
                .inserted => {},
                .rejected => return,
                .input_full => {
                    try writeInputFullNotice(app);
                    return;
                },
            }

            const line = try std.fmt.allocPrint(app.alloc, "attached image: {s}", .{std.fs.path.basename(image.path)});
            defer app.alloc.free(line);
            try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = line }, true);
        }

        pub fn managePending(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (std.mem.eql(u8, trimmed, "clear")) {
                app.clearPendingImages();
                try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = "cleared pending images" }, true);
                return;
            }

            if (app.pending_images.items.len == 0) {
                try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = "no pending images" }, true);
                return;
            }

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try out.writer.print("{d} pending\n", .{app.pending_images.items.len});
            for (app.pending_images.items) |image| {
                try out.writer.print(" - {s} ({s})\n", .{ std.fs.path.basename(image.path), image.media_type });
            }
            const text = try out.toOwnedSlice();
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{
                .topic = "images",
                .tone = .neutral,
                .body = std.mem.trimEnd(u8, text, "\n"),
            }, true);
        }

        pub fn attachClipboard(app: *App) !void {
            var loaded = image_attachments.loadClipboardImageAttachment(app.alloc) catch |err| {
                if (err == error.NoClipboardImage) {
                    try app.writeDomainNotice(.{ .topic = "images", .tone = .neutral, .body = "no image found on clipboard" }, true);
                } else if (err != error.Unsupported) {
                    const line = try std.fmt.allocPrint(app.alloc, "failed to paste clipboard image: {s}", .{@errorName(err)});
                    defer app.alloc.free(line);
                    try app.writeDomainNotice(.{ .topic = "images", .tone = .@"error", .body = line }, true);
                }
                return;
            };
            defer loaded.deinit(app.alloc);
            switch (try insertImageAtCursor(App, app, loaded.takeAttachment(), .temporary)) {
                .inserted => app.shell.render_requests.request(.footer),
                .rejected => {},
                .input_full => try writeInputFullNotice(app),
            }
        }

        fn insertImageAtCursor(
            comptime A: type,
            app: *A,
            image: types.ImageAttachment,
            source_lifetime: ImageSourceLifetime,
        ) !InsertImageResult {
            var attached = image;
            var owns_attached = true;
            defer if (owns_attached) image_attachments.discardImageAttachment(app.alloc, attached);

            const id = app.peekNextImageId();
            _ = try std.math.add(usize, id, 1);
            attached.id = id;

            var buf: [32]u8 = undefined;
            const placeholder = image_attachments.formatImagePlaceholder(&buf, id) catch unreachable;
            const max_input_len = if (comptime @hasDecl(A, "input_limits"))
                A.input_limits.composer_bytes
            else if (comptime @hasDecl(A, "input_byte_limit"))
                A.input_byte_limit
            else
                std.math.maxInt(usize);
            if (!app.input_runtime.insertionState().canInsert(placeholder.len, max_input_len)) {
                return .input_full;
            }

            try app.input_runtime.edit_state.input.ensureUnusedCapacity(
                app.alloc,
                placeholder.len,
            );
            try app.pending_images.ensureUnusedCapacity(app.alloc, 1);
            if (comptime @hasField(@TypeOf(app.input_runtime), "entities")) {
                try app.input_runtime.entities.image_tokens.ensureUnusedCapacity(app.alloc, 1);
            }
            switch (try image_attachments.captureImageAttachmentForAdmission(A, app, &attached)) {
                .captured => {},
                .rejected => return .rejected,
            }
            if (source_lifetime == .temporary) {
                const snapshot_path = attached.snapshot_path orelse return error.MissingImageSnapshot;
                const display_path = try app.alloc.dupe(u8, snapshot_path);
                app.alloc.free(attached.path);
                attached.path = display_path;
            }

            const raw_start = app.input_runtime.edit_state.cursor;
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.insertionState().insertSliceAssumeCapacity(
                app.alloc,
                placeholder,
            );
            if (comptime @hasField(@TypeOf(app.input_runtime), "entities")) {
                app.input_runtime.entities.registerImageTokenAssumeCapacity(.{
                    .id = id,
                    .span = .{
                        .raw_start = raw_start,
                        .raw_end = raw_start + placeholder.len,
                    },
                });
            }
            if (app.pending_images.items.len > 0) {
                std.debug.assert(app.pending_images.items[app.pending_images.items.len - 1].id < attached.id);
            }
            app.pending_images.appendAssumeCapacity(attached);
            const committed_id = app.nextImageId();
            std.debug.assert(committed_id == id);
            if (comptime @hasDecl(@TypeOf(app.input_runtime), "historyBoundary")) {
                app.input_runtime.historyBoundary(app.alloc);
            }
            owns_attached = false;
            return .inserted;
        }
    };
}

const FakeApp = struct {
    pub const input_byte_limit: usize = 4096;

    alloc: std.mem.Allocator,
    workspace_root: []const u8 = "/",
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    transcript: std.ArrayList(u8) = .empty,
    next_image_id_counter: usize = 1,
    input_runtime: FakeInput = .{},
    shell: struct {
        render_requests: render_request.RenderRequestState = .{},
    } = .{},
    last_tone: ?types.NoticeTone = null,
    notice_count: usize = 0,
    capture_error: ?anyerror = null,
    snapshot_dir: ?[]const u8 = null,

    fn deinit(self: *FakeApp) void {
        self.clearPendingImages();
        self.pending_images.deinit(self.alloc);
        self.transcript.deinit(self.alloc);
        self.input_runtime.edit_state.deinit(self.alloc);
        self.input_runtime.entities.deinit(self.alloc);
    }

    fn clearPendingImages(self: *FakeApp) void {
        self.input_runtime.entities.image_tokens.clearRetainingCapacity();
        image_attachments.discardImageSnapshots(self.alloc, self.pending_images.items);
        for (self.pending_images.items) |image| types.freeImageAttachment(self.alloc, image);
        self.pending_images.clearRetainingCapacity();
    }

    pub fn writeDomainNotice(self: *FakeApp, notice: types.SemanticNotice, _: bool) !void {
        self.notice_count += 1;
        self.last_tone = notice.tone;
        try self.transcript.appendSlice(self.alloc, notice.body);
        try self.transcript.append(self.alloc, '\n');
    }

    fn text(self: *const FakeApp) []const u8 {
        return self.transcript.items;
    }

    fn nextImageId(self: *FakeApp) usize {
        return image_attachments.allocateImageId(&self.next_image_id_counter);
    }

    fn peekNextImageId(self: *const FakeApp) usize {
        return self.next_image_id_counter;
    }

    pub fn captureImageAttachment(self: *FakeApp, attachment: *types.ImageAttachment) !void {
        if (self.capture_error) |err| return err;
        const snapshot_dir = self.snapshot_dir orelse return;
        try image_attachments.captureImageSnapshot(self.alloc, attachment, snapshot_dir);
    }
};

const FakeInput = struct {
    edit_state: edit_contract.State = .{},
    entities: registered_entities.State = .{},
    vertical_navigation: FakeVerticalNavigation = .{},
    history_boundary_count: usize = 0,

    fn historyBoundary(self: *FakeInput, _: std.mem.Allocator) void {
        self.history_boundary_count += 1;
    }

    fn insertionState(self: *FakeInput) FakeInsertionState {
        return .{ .input = self };
    }
};

const FakeInsertionState = struct {
    input: *FakeInput,

    fn canInsert(
        self: FakeInsertionState,
        inserted_len: usize,
        max_len: usize,
    ) bool {
        return edit_contract.canInsert(self.input.edit_state.input.items.len, inserted_len, max_len);
    }

    fn insertSliceAssumeCapacity(
        self: FakeInsertionState,
        _: std.mem.Allocator,
        bytes: []const u8,
    ) void {
        if (bytes.len == 0) return;
        const insert_start = self.input.edit_state.cursor;
        self.input.edit_state.insertSliceAssumeCapacity(bytes);
        for (self.input.entities.image_tokens.items) |*token| {
            token.span = entity_spans.afterInsert(
                token.span,
                insert_start,
                bytes.len,
            ).?;
        }
    }
};

const FakeVerticalNavigation = struct {
    reset_count: usize = 0,

    fn reset(self: *FakeVerticalNavigation) void {
        self.reset_count += 1;
    }
};

fn expectTranscriptContains(app: *const FakeApp, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, app.text(), needle) != null);
}

fn writeTestImage(tmp: *std.testing.TmpDir, name: []const u8) !void {
    var file = try tmp.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nrest");
}

fn realTmpPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    return @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, name);
}

fn ownedTestAttachment(alloc: std.mem.Allocator, path: []const u8) !types.ImageAttachment {
    return .{
        .path = try alloc.dupe(u8, path),
        .media_type = try alloc.dupe(u8, "image/png"),
    };
}

fn testClipboardImage(
    alloc: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    source_dir_name: []const u8,
) !image_attachments.ClipboardImageAttachment {
    try tmp.dir.createDir(std.testing.io, source_dir_name, .default_dir);
    const source_sub_path = try std.fs.path.join(alloc, &.{ source_dir_name, "clipboard.png" });
    defer alloc.free(source_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = source_sub_path,
        .data = "\x89PNG\r\n\x1a\nclipboard",
    });
    const source_path = try realTmpPath(alloc, tmp, source_sub_path);
    defer alloc.free(source_path);
    return .{
        .attachment = try image_attachments.loadImageAttachment(alloc, source_path),
        .source_dir = try realTmpPath(alloc, tmp, source_dir_name),
    };
}

fn countSnapshotFiles(snapshot_dir: []const u8) !usize {
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, snapshot_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

fn expectBadgeProjection(alloc: std.mem.Allocator, app: *const FakeApp, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = try image_attachments.expandPlaceholdersWithBadges(
        alloc,
        &out.writer,
        app.input_runtime.edit_state.input.items,
        app.pending_images.items,
        null,
    );
    try std.testing.expectEqualStrings(expected, out.written());
}

fn checkImageInsertionAllocationFailureIsAtomic(
    failing: *std.testing.FailingAllocator,
    fail_offset: ?usize,
    allocation_count: *usize,
) !void {
    const alloc = failing.allocator();
    var app = FakeApp{ .alloc = alloc };
    defer app.deinit();
    app.next_image_id_counter = 7;

    const image = try ownedTestAttachment(alloc, "/tmp/reserved.png");
    const start_alloc_index = failing.alloc_index;
    if (fail_offset) |offset| {
        failing.fail_index = try std.math.add(
            usize,
            start_alloc_index,
            offset,
        );
    }

    _ = Commands(FakeApp).insertImageAtCursor(FakeApp, &app, image, .retained) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.input.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.edit_state.cursor);
        try std.testing.expectEqual(@as(usize, 0), app.pending_images.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.input_runtime.entities.image_tokens.items.len);
        try std.testing.expectEqual(@as(usize, 7), app.next_image_id_counter);
        return err;
    };

    allocation_count.* = failing.alloc_index - start_alloc_index;
    try std.testing.expectEqualStrings("[Image #7]", app.input_runtime.edit_state.input.items);
    try std.testing.expectEqual(@as(usize, 1), app.pending_images.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.input_runtime.entities.image_tokens.items.len);
    try std.testing.expectEqual(@as(usize, 8), app.next_image_id_counter);
}
