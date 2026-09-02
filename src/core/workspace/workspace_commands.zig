const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const workspace_access = @import("workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const Action = union(enum) {
    add: []const u8,
    remove: []const u8,
    clear,

    fn label(self: Action) []const u8 {
        return switch (self) {
            .add => "add",
            .remove => "remove",
            .clear => "clear",
        };
    }

    fn path(self: Action) ?[]const u8 {
        return switch (self) {
            .add, .remove => |value| value,
            .clear => null,
        };
    }
};

pub const Mutation = struct {
    action: []const u8,
    path: ?[]const u8 = null,
    saved_changed: bool,
    runtime_changed: bool,
    launch_flag_can_restore: bool = false,
};

pub const FailurePhase = enum {
    stage,
    commit,
    reconcile,
};

pub const Reconciliation = union(enum) {
    intended: workspace_access.WorkspaceAccess,
    previous: workspace_access.WorkspaceAccess,
    unconfirmed,

    pub fn deinit(self: *Reconciliation, alloc: Allocator) void {
        switch (self.*) {
            .intended => |*access| access.deinit(alloc),
            .previous => |*access| access.deinit(alloc),
            .unconfirmed => {},
        }
        self.* = .unconfirmed;
    }
};

pub const Updated = struct {
    access: workspace_access.WorkspaceAccess,
    mutation: Mutation,

    fn deinit(self: *Updated, alloc: Allocator) void {
        self.access.deinit(alloc);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    updated: Updated,
    indeterminate: Reconciliation,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .updated => |*updated| updated.deinit(alloc),
            .indeterminate => |*reconciliation| reconciliation.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub fn execute(
    alloc: Allocator,
    primary_directory: []const u8,
    current: *const workspace_access.WorkspaceAccess,
    action: Action,
    failure_phase: *FailurePhase,
) !Result {
    failure_phase.* = .stage;
    var add_identity: ?[]u8 = null;
    defer if (add_identity) |identity| alloc.free(identity);
    var staged: ?workspace_access.WorkspaceAccess = switch (action) {
        .add => |path| blk: {
            add_identity = try workspace_access.addDirectoryIdentityAlloc(
                alloc,
                primary_directory,
                path,
            );
            break :blk current.stageAddSaved(
                alloc,
                primary_directory,
                add_identity.?,
            ) catch |err| switch (err) {
                error.TooManyDirectories => null,
                else => return err,
            };
        },
        .remove => |path| try current.stageRemove(alloc, primary_directory, path),
        .clear => current.stageClear(),
    };
    defer if (staged) |*access| access.deinit(alloc);

    const runtime_sources = if (staged) |*access| access else current;
    var command_line: ?[][]u8 = null;
    defer if (command_line) |paths| freeStringSlice(alloc, paths);
    switch (action) {
        .add => command_line = try runtime_sources.commandLineDirectoriesAlloc(alloc),
        .remove, .clear => {},
    }

    const durable_patch: config_runtime.WorkspaceDirectoryMutation = .{
        .workspace_root = primary_directory,
        .observed_sources = current.saved_sources,
        .patch = switch (action) {
            .add => .{ .add = add_identity.? },
            .remove => .{ .remove = removedPath(current, &staged.?) orelse return error.UnknownAdditionalDirectory },
            .clear => .clear,
        },
        .command_line_directories = command_line orelse &.{},
    };

    failure_phase.* = .commit;
    var outcome = config_runtime.mutateWorkspaceDirectory(
        alloc,
        durable_patch,
    ) catch |err| {
        if (err != error.SettingsCommitIndeterminate) return err;
        failure_phase.* = .reconcile;
        const intended = if (staged) |*access| access else return .{ .indeterminate = .unconfirmed };
        return .{ .indeterminate = try reconcileWorkspaceAccess(
            alloc,
            primary_directory,
            current,
            intended,
        ) };
    };
    defer outcome.deinit(alloc);

    failure_phase.* = .reconcile;
    var committed = try loadCommittedWorkspaceAccess(
        alloc,
        primary_directory,
        runtime_sources,
    );
    errdefer committed.deinit(alloc);

    const updated = Updated{
        .access = committed,
        .mutation = .{
            .action = action.label(),
            .path = action.path(),
            .saved_changed = switch (outcome) {
                .committed => true,
                .unchanged => false,
            },
            .runtime_changed = !current.eql(&committed),
            .launch_flag_can_restore = current.commandLineSourceRemoved(&committed),
        },
    };
    committed = .{};
    return .{ .updated = updated };
}

fn removedPath(
    current: *const workspace_access.WorkspaceAccess,
    staged: *const workspace_access.WorkspaceAccess,
) ?[]const u8 {
    for (current.entries) |entry| {
        var retained = false;
        for (staged.entries) |candidate| {
            if (std.mem.eql(u8, entry.path, candidate.path)) {
                retained = true;
                break;
            }
        }
        if (!retained) return entry.path;
    }
    return null;
}

fn loadCommittedWorkspaceAccess(
    alloc: Allocator,
    primary_directory: []const u8,
    staged: *const workspace_access.WorkspaceAccess,
) !workspace_access.WorkspaceAccess {
    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, primary_directory);
    defer detailed.deinit(alloc);
    for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.cause == .invalid_additional_directories) return error.InvalidSettingsFormat;
    }

    const command_line = try staged.commandLineDirectoriesAlloc(alloc);
    defer freeStringSlice(alloc, command_line);
    return workspace_access.WorkspaceAccess.init(
        alloc,
        primary_directory,
        detailed.additional_directory_sources orelse &.{},
        command_line,
        staged.saved_suppressed,
    );
}

/// Reloads durable roots after an indeterminate settings commit and accepts
/// only the intended or previous saved state.
fn reconcileWorkspaceAccess(
    alloc: Allocator,
    primary_directory: []const u8,
    current: *const workspace_access.WorkspaceAccess,
    intended: *const workspace_access.WorkspaceAccess,
) !Reconciliation {
    var detailed = try config_runtime.loadMergedSettingsDetailed(alloc, primary_directory);
    defer detailed.deinit(alloc);

    for (detailed.diagnostics) |diagnostic| {
        if (diagnostic.cause == .invalid_additional_directories) return .unconfirmed;
    }
    return classifyDurableState(
        alloc,
        current,
        intended,
        detailed.additional_directories orelse &.{},
    );
}

fn classifyDurableState(
    alloc: Allocator,
    current: *const workspace_access.WorkspaceAccess,
    intended: *const workspace_access.WorkspaceAccess,
    durable: []const []const u8,
) !Reconciliation {
    const current_saved = try current.savedDirectoriesAlloc(alloc);
    defer freeStringSlice(alloc, current_saved);
    const intended_saved = try intended.savedDirectoriesAlloc(alloc);
    defer freeStringSlice(alloc, intended_saved);

    if (stringSlicesEqual(durable, intended_saved)) {
        return .{ .intended = try intended.clone(alloc) };
    }
    if (stringSlicesEqual(durable, current_saved)) {
        return .{ .previous = try current.clone(alloc) };
    }
    return .unconfirmed;
}

fn stringSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_value, right_value| {
        if (!std.mem.eql(u8, left_value, right_value)) return false;
    }
    return true;
}

fn freeStringSlice(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}









var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

fn writeFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn readFixtureFile(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    var file = try dir.openFile(io_mod.getIo(), sub_path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 64 * 1024);
}

fn writeWorkspaceDirectoriesFixture(
    alloc: Allocator,
    dir: std.Io.Dir,
    sub_path: []const u8,
    workspace_root: []const u8,
    directories: []const []const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"workspaces\":{");
    try std.json.Stringify.value(workspace_root, .{}, &out.writer);
    try out.writer.writeAll(":{\"additional_directories\":[");
    for (directories, 0..) |directory, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(directory, .{}, &out.writer);
    }
    try out.writer.writeAll("]}}}\n");
    try writeFixtureFile(dir, sub_path, out.written());
}

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const EnvEntry) !*TestEnv {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        for (entries) |entry| try self.map.put(entry.key, entry.value);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        if (stable_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};
