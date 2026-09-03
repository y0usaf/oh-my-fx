const std = @import("std");
const runtime_profile = @import("../hosts/runtime_profile.zig");
const file_index = @import("../workspace/file_index.zig");
const path_completion = @import("../workspace/path_completion.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

pub const Access = workspace_access.WorkspaceAccess;
pub const AccessScope = workspace_access.AccessScope;
pub const Error = workspace_access.Error;
pub const FileCompletionError = file_index.SearchError || path_completion.Error;

pub const State = struct {
    access: Access = .{},
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn access(app: *App) *Access {
            return &app.workspace.access;
        }

        pub fn scope(app: *const App) AccessScope {
            return app.workspace.access.scope(app.workspace_root);
        }

        pub fn fileCompletions(
            app: *App,
            query: []const u8,
            out: []file_index.SearchResult,
            match_spans: []file_index.MatchSpan,
            path_storage: []u8,
        ) FileCompletionError!usize {
            return switch (path_completion.queryMode(query)) {
                .workspace_index => app.file_index.searchTyped(query, out, match_spans),
                .explicit_path => path_completion.complete(
                    app.workspace_root,
                    query,
                    out,
                    match_spans,
                    path_storage,
                ),
            };
        }

        pub fn fileCompletionsDependOnIndex(_: *const App, query: []const u8) bool {
            return path_completion.queryMode(query) == .workspace_index;
        }

        pub fn isCurrentFileCompletion(
            app: *const App,
            query: []const u8,
            path: []const u8,
            kind: file_index.CandidateKind,
        ) bool {
            return switch (path_completion.queryMode(query)) {
                .workspace_index => app.file_index.isCurrentCandidateKind(path, kind),
                .explicit_path => path_completion.isCurrentCandidateKind(app.workspace_root, path, kind),
            };
        }

        pub fn adopt(app: *App, value: Access) void {
            app.workspace.access.deinit(app.alloc);
            app.workspace.access = value;
        }

        pub fn applyLaunch(
            app: *App,
            command_line_directories: []const []const u8,
            saved_suppressed: bool,
        ) !void {
            try app.workspace.access.applyLaunch(
                app.alloc,
                app.workspace_root,
                command_line_directories,
                saved_suppressed,
            );
        }

        /// Installs `replacement` and clears it after taking ownership.
        pub fn install(app: *App, replacement: *Access) bool {
            if (comptime !runtime_profile.allows(App, .file_index)) {
                app.workspace.access.deinit(app.alloc);
                app.workspace.access = replacement.*;
                replacement.* = .{};
                return true;
            }
            const runtime_changed = !app.workspace.access.eql(replacement);
            app.workspace.access.deinit(app.alloc);
            app.workspace.access = replacement.*;
            replacement.* = .{};
            if (runtime_changed) refreshFileIndex(app);
            return runtime_changed;
        }

        pub fn startFileIndex(app: *App) void {
            if (app.workspace_root.len == 0) return;
            app.file_index.ensureScope(std.heap.c_allocator, scope(app));
        }

        pub fn refreshFileIndex(app: *App) void {
            app.file_index.refreshScope(std.heap.c_allocator, scope(app));
        }

        pub fn refreshAvailability(app: *App) workspace_access.Error!bool {
            if (comptime !runtime_profile.allows(App, .file_index)) return false;
            var replacement = (try app.workspace.access.stageAvailabilityRefresh(
                app.alloc,
                app.workspace_root,
            )) orelse return false;
            defer replacement.deinit(app.alloc);
            return install(app, &replacement);
        }

        pub fn deinit(app: *App) void {
            app.workspace.access.deinit(app.alloc);
            app.workspace = .{};
        }
    };
}

const TestFileIndex = struct {
    ensured_count: usize = 0,
    refreshed_count: usize = 0,
    last_additional_count: usize = 0,

    fn ensureScope(self: *TestFileIndex, _: std.mem.Allocator, scope: workspace_access.AccessScope) void {
        self.ensured_count += 1;
        self.last_additional_count = scope.additional_directories.len;
    }

    fn refreshScope(self: *TestFileIndex, _: std.mem.Allocator, scope: workspace_access.AccessScope) void {
        self.refreshed_count += 1;
        self.last_additional_count = scope.additional_directories.len;
    }
};

test "interactive workspace runtime owns scope and index lifecycle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "primary", .default_dir);
    try tmp.dir.createDir(std.testing.io, "shared", .default_dir);

    const io_mod = @import("../shared/io.zig");
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);

    const TestApp = struct {
        alloc: std.mem.Allocator,
        workspace_root: []const u8,
        workspace: State = .{},
        file_index: TestFileIndex = .{},
    };
    const TestRuntime = Runtime(TestApp);
    var app = TestApp{ .alloc = alloc, .workspace_root = primary };
    defer TestRuntime.deinit(&app);

    try TestRuntime.applyLaunch(&app, &.{shared}, false);
    try std.testing.expectEqual(@as(usize, 1), TestRuntime.scope(&app).additional_directories.len);

    TestRuntime.startFileIndex(&app);
    try std.testing.expectEqual(@as(usize, 1), app.file_index.ensured_count);
    try std.testing.expectEqual(@as(usize, 1), app.file_index.last_additional_count);

    try tmp.dir.deleteTree(std.testing.io, "shared");
    try std.testing.expect(try TestRuntime.refreshAvailability(&app));
    try std.testing.expect(!TestRuntime.scope(&app).additional_directories[0].active);
    try std.testing.expectEqual(@as(usize, 1), app.file_index.refreshed_count);

    try tmp.dir.createDir(std.testing.io, "shared", .default_dir);
    try std.testing.expect(try TestRuntime.refreshAvailability(&app));
    try std.testing.expect(TestRuntime.scope(&app).additional_directories[0].active);
    try std.testing.expectEqual(@as(usize, 2), app.file_index.refreshed_count);

    var replacement = TestRuntime.access(&app).stageClear();
    const changed = TestRuntime.install(&app, &replacement);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 3), app.file_index.refreshed_count);
    try std.testing.expectEqual(@as(usize, 0), app.file_index.last_additional_count);
    try std.testing.expectEqual(@as(usize, 0), replacement.entries.len);
}
