const std = @import("std");
const builtin_mod = @import("builtin");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const PathScope = enum {
    workspace_only,
    workspace_or_external,
    workspace_or_external_create,
};

const ResolvedInput = struct {
    absolute: []const u8,
    external_intent: bool,
};

const ExternalPathInput = union(enum) {
    absolute: []const u8,
    home_relative: []const u8,
    workspace_relative: []const u8,
};

pub const BoundedFileTargetComponent = struct {
    start: usize,
    end: usize,
};

pub const BoundedFileTargetResolution = struct {
    canonical_target_path: []const u8,
    anchor_path_end: usize,
    anchor_is_external: bool,
    relative_components: []const BoundedFileTargetComponent,
};

const FileTargetResolveError = error{
    PathOutsideWorkspace,
    FileNotFound,
    HomeNotSet,
    InvalidPath,
    WorkspaceUnavailable,
    TooManyPathComponents,
    AccessDenied,
    PermissionDenied,
    NotDir,
    SymLinkLoop,
    NameTooLong,
    BadPathName,
    NotLink,
    IsDir,
    PathAlreadyExists,
    OperationUnsupported,
    UnsupportedReparsePointType,
    NoDevice,
    NetworkNotFound,
    UnrecognizedVolume,
    InputOutput,
    FileSystem,
    FileTooBig,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    DeviceBusy,
    FileBusy,
    PipeBusy,
    FileLocksUnsupported,
    WouldBlock,
    AntivirusInterference,
    Streaming,
    Canceled,
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

const path_entry_whitespace = " \t\r\n";
const max_symbolic_link_expansions: usize = 40;

pub const FileIdentityError = error{
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

pub fn fileIdentity(
    device: u64,
    stat: std.Io.File.Stat,
) file_mutation_contract.FileIdentity {
    return .{
        .device = device,
        .inode = @intCast(stat.inode),
        .kind = stat.kind,
    };
}

pub fn directoryIdentity(
    dir: std.Io.Dir,
) (FileIdentityError || std.Io.Dir.StatFileError)!file_mutation_contract.FileIdentity {
    const stat = try dir.statFile(io_mod.getIo(), ".", .{ .follow_symlinks = false });
    return fileIdentity(try descriptorDevice(dir.handle), stat);
}

pub fn descriptorDevice(handle: std.Io.File.Handle) FileIdentityError!u64 {
    return switch (builtin_mod.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            while (true) {
                var statx = std.mem.zeroes(linux.Statx);
                switch (linux.errno(linux.statx(
                    handle,
                    "",
                    linux.AT.EMPTY_PATH,
                    linux.STATX.BASIC_STATS,
                    &statx,
                ))) {
                    .SUCCESS => break :blk linuxDevice(statx.dev_major, statx.dev_minor),
                    .INTR => {},
                    .NOMEM => return error.SystemResources,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    else => return error.Unexpected,
                }
            }
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => blk: {
            while (true) {
                var native = std.mem.zeroes(std.c.Stat);
                switch (std.c.errno(std.c.fstat(handle, &native))) {
                    .SUCCESS => break :blk @intCast(native.dev),
                    .INTR => {},
                    .NOMEM => return error.SystemResources,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    else => return error.Unexpected,
                }
            }
        },
        else => 0,
    };
}

pub fn directoryEntryDevice(
    dir: std.Io.Dir,
    component: []const u8,
) FileIdentityError!u64 {
    if (component.len > std.Io.Dir.max_path_bytes) return error.Unexpected;
    var component_z_buffer: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    @memcpy(component_z_buffer[0..component.len], component);
    component_z_buffer[component.len] = 0;
    const component_z = component_z_buffer[0..component.len :0];

    return switch (builtin_mod.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            while (true) {
                var statx = std.mem.zeroes(linux.Statx);
                switch (linux.errno(linux.statx(
                    dir.handle,
                    component_z.ptr,
                    linux.AT.SYMLINK_NOFOLLOW,
                    linux.STATX.BASIC_STATS,
                    &statx,
                ))) {
                    .SUCCESS => break :blk linuxDevice(statx.dev_major, statx.dev_minor),
                    .INTR => {},
                    .NOMEM => return error.SystemResources,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    else => return error.Unexpected,
                }
            }
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => blk: {
            while (true) {
                var native = std.mem.zeroes(std.c.Stat);
                switch (std.c.errno(std.c.fstatat(
                    dir.handle,
                    component_z.ptr,
                    &native,
                    std.c.AT.SYMLINK_NOFOLLOW,
                ))) {
                    .SUCCESS => break :blk @intCast(native.dev),
                    .INTR => {},
                    .NOMEM => return error.SystemResources,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    else => return error.Unexpected,
                }
            }
        },
        else => 0,
    };
}

fn linuxDevice(major: u32, minor: u32) u64 {
    return (@as(u64, minor) & 0xff) |
        ((@as(u64, major) & 0xfff) << 8) |
        ((@as(u64, minor) & ~@as(u64, 0xff)) << 12) |
        ((@as(u64, major) & ~@as(u64, 0xfff)) << 32);
}

pub fn resolveWorkspacePath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
    mode: types.ResolveMode,
) ![]const u8 {
    return resolvePath(arena, workspace_root, input_path, null, mode, .workspace_only);
}

pub fn resolveWorkspaceOrExternalPath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
) ![]const u8 {
    return resolveWorkspaceOrExternalPathWithHome(
        arena,
        workspace_root,
        input_path,
        io_mod.getenv("HOME"),
        .existing,
    );
}

pub fn resolveWorkspaceOrExternalCreatePath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
) ![]const u8 {
    return resolveWorkspaceOrExternalPathWithHome(
        arena,
        workspace_root,
        input_path,
        io_mod.getenv("HOME"),
        .create,
    );
}

pub fn resolveFileMutationTargetBounded(
    workspace_root: []const u8,
    input_path: []const u8,
    mode: types.ResolveMode,
    primary_path_scratch: []u8,
    secondary_path_scratch: []u8,
    component_scratch: []BoundedFileTargetComponent,
) FileTargetResolveError!BoundedFileTargetResolution {
    const cleaned = std.mem.trim(u8, input_path, path_entry_whitespace);
    if (cleaned.len == 0) return error.InvalidPath;

    const input = try resolveBoundedFileTargetInput(workspace_root, cleaned, secondary_path_scratch);
    return resolveBoundedAbsoluteFileTarget(
        workspace_root,
        input.absolute,
        input.external_intent,
        mode,
        primary_path_scratch,
        secondary_path_scratch,
        component_scratch,
    );
}

fn resolveWorkspaceOrExternalPathWithHome(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
    home_dir: ?[]const u8,
    mode: types.ResolveMode,
) ![]const u8 {
    const scope: PathScope = switch (mode) {
        .existing => .workspace_or_external,
        .create => .workspace_or_external_create,
    };
    return resolvePath(arena, workspace_root, input_path, home_dir, mode, scope);
}

fn resolvePath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
    home_dir: ?[]const u8,
    mode: types.ResolveMode,
    scope: PathScope,
) ![]const u8 {
    const cleaned = std.mem.trim(u8, input_path, path_entry_whitespace);
    if (cleaned.len == 0) return error.InvalidPath;

    const input = try resolveInput(arena, workspace_root, cleaned, home_dir, scope);

    const resolved = switch (mode) {
        .existing => try io_mod.realpathAlloc(arena, input.absolute),
        .create => if (scope == .workspace_or_external_create and input.external_intent)
            try resolveAbsoluteCreateTargetPath(arena, input.absolute, 0)
        else
            try resolveCreateTargetPath(arena, workspace_root, input.absolute),
    };

    if (!input.external_intent) try ensurePathInsideWorkspace(workspace_root, resolved);
    return resolved;
}

fn resolveInput(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    cleaned: []const u8,
    home_dir: ?[]const u8,
    scope: PathScope,
) !ResolvedInput {
    if (scope == .workspace_only) {
        return .{
            .absolute = if (std.fs.path.isAbsolute(cleaned))
                try std.fs.path.resolve(arena, &.{cleaned})
            else
                try std.fs.path.resolve(arena, &.{ workspace_root, cleaned }),
            .external_intent = false,
        };
    }

    return switch (try classifyExternalPathInput(cleaned)) {
        .absolute => |absolute| .{
            .absolute = try std.fs.path.resolve(arena, &.{absolute}),
            .external_intent = true,
        },
        .home_relative => |relative| blk: {
            const home = home_dir orelse return error.HomeNotSet;
            if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.InvalidPath;

            const expanded = if (relative.len == 0)
                home
            else
                try std.mem.concat(arena, u8, &.{ home, relative });
            break :blk .{
                .absolute = try std.fs.path.resolve(arena, &.{expanded}),
                .external_intent = true,
            };
        },
        .workspace_relative => |relative| blk: {
            const absolute = try std.fs.path.resolve(arena, &.{ workspace_root, relative });
            break :blk .{
                .absolute = absolute,
                .external_intent = !pathInside(workspace_root, absolute),
            };
        },
    };
}

fn classifyExternalPathInput(cleaned: []const u8) error{InvalidPath}!ExternalPathInput {
    if (cleaned.len == 0) return error.InvalidPath;
    if (std.fs.path.isAbsolute(cleaned)) return .{ .absolute = cleaned };
    if (std.mem.eql(u8, cleaned, "~")) return .{ .home_relative = "" };
    if (std.mem.startsWith(u8, cleaned, "~/")) {
        return .{ .home_relative = cleaned[1..] };
    }
    if (cleaned[0] == '~') return error.InvalidPath;
    return .{ .workspace_relative = cleaned };
}

fn resolveBoundedFileTargetInput(
    workspace_root: []const u8,
    cleaned: []const u8,
    scratch: []u8,
) FileTargetResolveError!ResolvedInput {
    return switch (try classifyExternalPathInput(cleaned)) {
        .absolute => |absolute| .{
            .absolute = try normalizeAbsolutePathInto(scratch, absolute),
            .external_intent = true,
        },
        .home_relative => |relative| blk: {
            const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
            if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.InvalidPath;
            break :blk .{
                .absolute = try normalizeBaseRelativePathInto(scratch, home, relative),
                .external_intent = true,
            };
        },
        .workspace_relative => |relative| blk: {
            if (workspace_root.len == 0 or !std.fs.path.isAbsolute(workspace_root)) {
                return error.WorkspaceUnavailable;
            }
            const absolute = try normalizeBaseRelativePathInto(scratch, workspace_root, relative);
            break :blk .{
                .absolute = absolute,
                .external_intent = !pathInside(workspace_root, absolute),
            };
        },
    };
}

fn resolveBoundedAbsoluteFileTarget(
    workspace_root: []const u8,
    initial_absolute: []const u8,
    external_intent: bool,
    mode: types.ResolveMode,
    primary_path_scratch: []u8,
    secondary_path_scratch: []u8,
    component_scratch: []BoundedFileTargetComponent,
) FileTargetResolveError!BoundedFileTargetResolution {
    if (primary_path_scratch.len == 0 or secondary_path_scratch.len == 0) return error.InvalidPath;

    var pending_scratch = secondary_path_scratch;
    var output_scratch = primary_path_scratch;
    var pending_path_len = initial_absolute.len;
    var symbolic_link_expansions: usize = 0;

    while (true) {
        const step = try traverseBoundedAbsoluteFileTarget(
            workspace_root,
            pending_scratch,
            pending_path_len,
            mode,
            output_scratch,
            component_scratch,
            &symbolic_link_expansions,
        );

        switch (step) {
            .restart_path_len => |restart_path_len| {
                if (!external_intent and !pathInside(workspace_root, output_scratch[0..restart_path_len])) {
                    return error.PathOutsideWorkspace;
                }

                const previous_pending = pending_scratch;
                pending_scratch = output_scratch;
                output_scratch = previous_pending;
                pending_path_len = restart_path_len;
            },
            .complete => |complete| {
                const canonical_target_path = output_scratch[0..complete.path_len];
                if (!external_intent and !pathInside(workspace_root, canonical_target_path)) {
                    return error.PathOutsideWorkspace;
                }

                if (output_scratch.ptr != primary_path_scratch.ptr) {
                    if (complete.path_len > primary_path_scratch.len) return error.InvalidPath;
                    @memmove(primary_path_scratch[0..complete.path_len], canonical_target_path);
                }

                return boundedResolution(
                    workspace_root,
                    primary_path_scratch[0..complete.path_len],
                    complete.anchor_path_end,
                    component_scratch[0..complete.component_count],
                );
            },
        }
    }
}

const BoundedTraversalStep = union(enum) {
    restart_path_len: usize,
    complete: struct {
        path_len: usize,
        anchor_path_end: usize,
        component_count: usize,
    },
};

fn traverseBoundedAbsoluteFileTarget(
    workspace_root: []const u8,
    pending_scratch: []u8,
    pending_path_len: usize,
    mode: types.ResolveMode,
    path_scratch: []u8,
    component_scratch: []BoundedFileTargetComponent,
    symbolic_link_expansions: *usize,
) FileTargetResolveError!BoundedTraversalStep {
    if (pending_path_len == 0 or pending_path_len > pending_scratch.len or path_scratch.len == 0) {
        return error.InvalidPath;
    }

    const absolute = pending_scratch[0..pending_path_len];
    path_scratch[0] = std.fs.path.sep;
    var path_len: usize = 1;
    var component_count: usize = 0;
    const workspace_target = pathInside(workspace_root, absolute);
    var workspace_anchor_end: ?usize = if (workspace_target and std.mem.eql(u8, workspace_root, "/"))
        1
    else
        null;

    const zio = io_mod.getIo();
    var current_dir = std.Io.Dir.openDirAbsolute(zio, "/", .{ .follow_symlinks = false }) catch |err| {
        return mapDirOpenError(err);
    };
    defer current_dir.close(zio);

    var iter = PathComponentIterator.init(absolute);
    if (!iter.hasNext()) {
        return .{ .complete = .{
            .path_len = path_len,
            .anchor_path_end = path_len,
            .component_count = 0,
        } };
    }

    while (iter.next()) |component| {
        const parent_path_end = path_len;
        const span = try appendBoundedPathComponent(path_scratch, &path_len, component);
        const is_final = !iter.hasNext();

        if (is_final) {
            _ = current_dir.statFile(zio, component, .{ .follow_symlinks = false }) catch |err| switch (mapStatFileError(err)) {
                error.FileNotFound => {
                    if (mode == .existing) return error.FileNotFound;
                    try appendBoundedRelativeComponent(component_scratch, &component_count, span);
                    return .{ .complete = .{
                        .path_len = path_len,
                        .anchor_path_end = if (workspace_target)
                            workspace_anchor_end orelse return error.PathOutsideWorkspace
                        else
                            parent_path_end,
                        .component_count = component_count,
                    } };
                },
                else => |mapped| return mapped,
            };

            if (workspace_target and std.mem.eql(u8, path_scratch[0..path_len], workspace_root)) {
                return .{ .complete = .{
                    .path_len = path_len,
                    .anchor_path_end = path_len,
                    .component_count = 0,
                } };
            }

            try appendBoundedRelativeComponent(component_scratch, &component_count, span);
            return .{ .complete = .{
                .path_len = path_len,
                .anchor_path_end = if (workspace_target)
                    workspace_anchor_end orelse return error.PathOutsideWorkspace
                else
                    parent_path_end,
                .component_count = component_count,
            } };
        }

        const next_dir = openBoundedChildDirNoFollow(current_dir, component) catch |err| switch (err) {
            error.FileNotFound => {
                if (mode == .existing) return error.FileNotFound;
                try appendBoundedRelativeComponent(component_scratch, &component_count, span);
                while (iter.next()) |missing_component| {
                    const missing_span = try appendBoundedPathComponent(path_scratch, &path_len, missing_component);
                    try appendBoundedRelativeComponent(component_scratch, &component_count, missing_span);
                }
                return .{ .complete = .{
                    .path_len = path_len,
                    .anchor_path_end = if (workspace_target)
                        workspace_anchor_end orelse return error.PathOutsideWorkspace
                    else
                        parent_path_end,
                    .component_count = component_count,
                } };
            },
            else => |mapped| return mapped,
        };

        if (next_dir == null) {
            const restart_path_len = try resolveBoundedIntermediateSymlink(
                current_dir,
                component,
                parent_path_end,
                iter.index,
                pending_scratch,
                pending_path_len,
                path_scratch,
                symbolic_link_expansions,
            );
            return .{ .restart_path_len = restart_path_len };
        }

        current_dir.close(zio);
        current_dir = next_dir.?;

        if (workspace_target) {
            if (workspace_anchor_end == null) {
                if (std.mem.eql(u8, path_scratch[0..path_len], workspace_root)) {
                    workspace_anchor_end = path_len;
                }
            } else {
                try appendBoundedRelativeComponent(component_scratch, &component_count, span);
            }
        }
    }

    return error.InvalidPath;
}

fn resolveBoundedIntermediateSymlink(
    parent: std.Io.Dir,
    component: []const u8,
    parent_path_end: usize,
    suffix_offset: usize,
    pending_scratch: []u8,
    pending_path_len: usize,
    output_scratch: []u8,
    symbolic_link_expansions: *usize,
) FileTargetResolveError!usize {
    if (symbolic_link_expansions.* >= max_symbolic_link_expansions) return error.SymLinkLoop;
    symbolic_link_expansions.* += 1;

    if (suffix_offset > pending_path_len) return error.InvalidPath;
    const suffix_len = pending_path_len - suffix_offset;
    if (suffix_len > pending_scratch.len) return error.InvalidPath;
    const suffix_start = pending_scratch.len - suffix_len;
    @memmove(
        pending_scratch[suffix_start .. suffix_start + suffix_len],
        pending_scratch[suffix_offset..pending_path_len],
    );

    const zio = io_mod.getIo();
    const link_len = parent.readLink(zio, component, pending_scratch[0..suffix_start]) catch |err| {
        return mapReadLinkError(err);
    };
    if (link_len == 0) return error.InvalidPath;

    const link_target = pending_scratch[0..link_len];
    var resolved_len: usize = if (std.fs.path.isAbsolute(link_target)) absolute: {
        if (output_scratch.len == 0) return error.InvalidPath;
        output_scratch[0] = std.fs.path.sep;
        break :absolute 1;
    } else parent_path_end;

    if (resolved_len > output_scratch.len) return error.InvalidPath;
    try normalizeRelativePathPartInto(output_scratch, &resolved_len, link_target);
    try normalizeRelativePathPartInto(
        output_scratch,
        &resolved_len,
        pending_scratch[suffix_start .. suffix_start + suffix_len],
    );
    return resolved_len;
}

const PathComponentIterator = struct {
    path: []const u8,
    index: usize,

    fn init(path: []const u8) PathComponentIterator {
        return .{
            .path = path,
            .index = if (path.len > 0 and path[0] == std.fs.path.sep) 1 else 0,
        };
    }

    fn next(self: *PathComponentIterator) ?[]const u8 {
        while (self.index < self.path.len and self.path[self.index] == std.fs.path.sep) {
            self.index += 1;
        }
        if (self.index >= self.path.len) return null;

        const start = self.index;
        while (self.index < self.path.len and self.path[self.index] != std.fs.path.sep) {
            self.index += 1;
        }
        const end = self.index;
        if (self.index < self.path.len) self.index += 1;
        return self.path[start..end];
    }

    fn hasNext(self: *const PathComponentIterator) bool {
        var copy = self.*;
        return copy.next() != null;
    }
};

fn boundedResolution(
    workspace_root: []const u8,
    canonical_target_path: []const u8,
    anchor_path_end: usize,
    relative_components: []const BoundedFileTargetComponent,
) BoundedFileTargetResolution {
    return .{
        .canonical_target_path = canonical_target_path,
        .anchor_path_end = anchor_path_end,
        .anchor_is_external = !pathInside(workspace_root, canonical_target_path[0..anchor_path_end]),
        .relative_components = relative_components,
    };
}

fn normalizeAbsolutePathInto(scratch: []u8, raw_path: []const u8) FileTargetResolveError![]const u8 {
    if (!std.fs.path.isAbsolute(raw_path)) return error.InvalidPath;
    if (scratch.len == 0) return error.InvalidPath;

    scratch[0] = std.fs.path.sep;
    var len: usize = 1;
    try normalizeRelativePathPartInto(scratch, &len, raw_path);
    return scratch[0..len];
}

fn normalizeBaseRelativePathInto(
    scratch: []u8,
    base_abs: []const u8,
    relative_path: []const u8,
) FileTargetResolveError![]const u8 {
    if (!std.fs.path.isAbsolute(base_abs)) return error.InvalidPath;
    if (scratch.len == 0) return error.InvalidPath;

    scratch[0] = std.fs.path.sep;
    var len: usize = 1;
    try normalizeRelativePathPartInto(scratch, &len, base_abs);
    try normalizeRelativePathPartInto(scratch, &len, relative_path);
    return scratch[0..len];
}

fn normalizeRelativePathPartInto(
    scratch: []u8,
    path_len: *usize,
    raw_path: []const u8,
) FileTargetResolveError!void {
    var index: usize = 0;
    while (index < raw_path.len) {
        while (index < raw_path.len and raw_path[index] == std.fs.path.sep) {
            index += 1;
        }
        if (index >= raw_path.len) return;

        const start = index;
        while (index < raw_path.len and raw_path[index] != std.fs.path.sep) : (index += 1) {
            if (raw_path[index] == 0) return error.InvalidPath;
        }
        const component = raw_path[start..index];

        if (component.len == 0 or std.mem.eql(u8, component, ".")) {
            continue;
        } else if (std.mem.eql(u8, component, "..")) {
            popNormalizedPathComponent(scratch, path_len);
        } else {
            _ = try appendBoundedPathComponent(scratch, path_len, component);
        }
    }
}

fn popNormalizedPathComponent(path: []const u8, path_len: *usize) void {
    if (path_len.* <= 1) return;

    var index = path_len.* - 1;
    while (index > 0 and path[index] != std.fs.path.sep) {
        index -= 1;
    }
    path_len.* = if (index == 0) 1 else index;
}

fn appendBoundedPathComponent(
    scratch: []u8,
    path_len: *usize,
    component: []const u8,
) FileTargetResolveError!BoundedFileTargetComponent {
    if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
        return error.InvalidPath;
    }

    const needs_separator = path_len.* > 1;
    const required_len = path_len.* + component.len + @intFromBool(needs_separator);
    if (required_len > scratch.len) return error.InvalidPath;

    if (needs_separator) {
        scratch[path_len.*] = std.fs.path.sep;
        path_len.* += 1;
    }

    const start = path_len.*;
    @memcpy(scratch[start .. start + component.len], component);
    path_len.* += component.len;
    return .{ .start = start, .end = path_len.* };
}

fn appendBoundedRelativeComponent(
    component_scratch: []BoundedFileTargetComponent,
    component_count: *usize,
    span: BoundedFileTargetComponent,
) FileTargetResolveError!void {
    if (component_count.* >= component_scratch.len) return error.TooManyPathComponents;
    component_scratch[component_count.*] = span;
    component_count.* += 1;
}

fn openBoundedChildDirNoFollow(parent: std.Io.Dir, component: []const u8) FileTargetResolveError!?std.Io.Dir {
    const zio = io_mod.getIo();
    return parent.openDir(zio, component, .{ .follow_symlinks = false }) catch |err| {
        const mapped = mapDirOpenError(err);
        if (mapped == error.NotDir) {
            const stat = parent.statFile(zio, component, .{ .follow_symlinks = false }) catch |stat_err| {
                return mapStatFileError(stat_err);
            };
            if (stat.kind == .sym_link) return null;
        }
        return mapped;
    };
}

fn mapDirOpenError(err: std.Io.Dir.OpenError) FileTargetResolveError {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.NotDir => error.NotDir,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.SymLinkLoop => error.SymLinkLoop,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.NoDevice => error.NoDevice,
        error.SystemResources => error.SystemResources,
        error.NetworkNotFound => error.NetworkNotFound,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
    };
}

fn mapStatFileError(err: std.Io.Dir.StatFileError) FileTargetResolveError {
    return switch (err) {
        error.PipeBusy => error.PipeBusy,
        error.NoDevice => error.NoDevice,
        error.NetworkNotFound => error.NetworkNotFound,
        error.AntivirusInterference => error.AntivirusInterference,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.SymLinkLoop => error.SymLinkLoop,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        error.FileNotFound => error.FileNotFound,
        error.SystemResources => error.SystemResources,
        error.FileTooBig => error.FileTooBig,
        error.IsDir => error.IsDir,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.NotDir => error.NotDir,
        error.PathAlreadyExists => error.PathAlreadyExists,
        error.ReadOnlyFileSystem => error.ReadOnlyFileSystem,
        error.DeviceBusy => error.DeviceBusy,
        error.FileLocksUnsupported => error.FileLocksUnsupported,
        error.FileBusy => error.FileBusy,
        error.WouldBlock => error.WouldBlock,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.Streaming => error.Streaming,
    };
}

fn mapReadLinkError(err: std.Io.Dir.ReadLinkError) FileTargetResolveError {
    return switch (err) {
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.FileSystem => error.FileSystem,
        error.SymLinkLoop => error.SymLinkLoop,
        error.FileNotFound => error.FileNotFound,
        error.SystemResources => error.SystemResources,
        error.NotLink => error.NotLink,
        error.NotDir => error.NotDir,
        error.UnsupportedReparsePointType => error.UnsupportedReparsePointType,
        error.NetworkNotFound => error.NetworkNotFound,
        error.AntivirusInterference => error.AntivirusInterference,
        error.FileBusy => error.FileBusy,
        error.NameTooLong => error.NameTooLong,
        error.BadPathName => error.BadPathName,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
    };
}

pub fn resolveWorkspacePathEntry(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
) ![]const u8 {
    const parts = try resolveWorkspacePathEntryParts(arena, workspace_root, input_path);
    const resolved_parent = try resolveWorkspacePath(arena, workspace_root, parts.parent, .existing);
    return std.fs.path.join(arena, &.{ resolved_parent, parts.basename });
}

pub fn resolveWorkspacePathEntryExisting(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
) ![]const u8 {
    const target = try resolveWorkspacePathEntry(arena, workspace_root, input_path);
    _ = try std.Io.Dir.cwd().statFile(io_mod.getIo(), target, .{ .follow_symlinks = false });
    return target;
}

pub fn resolveWorkspacePathEntryCreate(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
) ![]const u8 {
    const parts = try resolveWorkspacePathEntryParts(arena, workspace_root, input_path);
    const resolved_parent = try resolveWorkspacePathEntryCreateParent(arena, workspace_root, parts.parent);
    return std.fs.path.join(arena, &.{ resolved_parent, parts.basename });
}

pub fn resolveCreateTargetPath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    absolute: []const u8,
) ![]const u8 {
    return io_mod.realpathAlloc(arena, absolute) catch |err| switch (err) {
        error.FileNotFound => try resolveCreateTargetFromNearestExisting(arena, workspace_root, absolute),
        else => return err,
    };
}

pub fn resolveCreateTargetFromNearestExisting(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    absolute: []const u8,
) ![]const u8 {
    try ensureCreateTargetSymlinksInsideWorkspace(arena, workspace_root, absolute, 0);

    var missing_components: std.ArrayList([]const u8) = .empty;
    defer missing_components.deinit(arena);

    var current = absolute;
    while (true) {
        if (io_mod.realpathAlloc(arena, current)) |existing| {
            try ensurePathInsideWorkspace(workspace_root, existing);

            if (missing_components.items.len > 0) {
                var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), existing, .{});
                dir.close(io_mod.getIo());
            }

            var resolved = existing;
            var i = missing_components.items.len;
            while (i > 0) {
                i -= 1;
                resolved = try std.fs.path.join(arena, &.{ resolved, missing_components.items[i] });
            }
            return resolved;
        } else |err| switch (err) {
            error.FileNotFound => {
                const basename = std.fs.path.basename(current);
                if (basename.len == 0) return err;
                try missing_components.append(arena, basename);

                const parent = std.fs.path.dirname(current) orelse return err;
                if (std.mem.eql(u8, parent, current)) return err;
                current = parent;
            },
            else => return err,
        }
    }
}

fn resolveAbsoluteCreateTargetPath(
    arena: std.mem.Allocator,
    absolute: []const u8,
    depth: usize,
) anyerror![]const u8 {
    if (depth > 16) return error.PathOutsideWorkspace;

    return io_mod.realpathAlloc(arena, absolute) catch |err| switch (err) {
        error.FileNotFound => try resolveAbsoluteCreateTargetFromNearestExisting(arena, absolute, depth),
        else => return err,
    };
}

fn resolveAbsoluteCreateTargetFromNearestExisting(
    arena: std.mem.Allocator,
    absolute: []const u8,
    depth: usize,
) anyerror![]const u8 {
    var missing_components: std.ArrayList([]const u8) = .empty;
    defer missing_components.deinit(arena);

    var current = absolute;
    while (true) {
        if (io_mod.realpathAlloc(arena, current)) |existing| {
            if (missing_components.items.len > 0) {
                var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), existing, .{});
                dir.close(io_mod.getIo());
            }

            var resolved = existing;
            var i = missing_components.items.len;
            while (i > 0) {
                i -= 1;
                resolved = try std.fs.path.join(arena, &.{ resolved, missing_components.items[i] });
            }
            return resolved;
        } else |err| switch (err) {
            error.FileNotFound => {
                if (try symlinkTargetAbsolute(arena, current)) |target| {
                    var resolved_target = target;
                    var i = missing_components.items.len;
                    while (i > 0) {
                        i -= 1;
                        resolved_target = try std.fs.path.join(arena, &.{ resolved_target, missing_components.items[i] });
                    }
                    return resolveAbsoluteCreateTargetPath(arena, resolved_target, depth + 1);
                }

                const basename = std.fs.path.basename(current);
                if (basename.len == 0) return err;
                try missing_components.append(arena, basename);

                const parent = std.fs.path.dirname(current) orelse return err;
                if (std.mem.eql(u8, parent, current)) return err;
                current = parent;
            },
            else => return err,
        }
    }
}

fn ensureCreateTargetSymlinksInsideWorkspace(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    absolute: []const u8,
    depth: usize,
) !void {
    if (depth > 16) return error.PathOutsideWorkspace;

    var current = absolute;
    while (true) {
        if (io_mod.realpathAlloc(arena, current)) |existing| {
            try ensurePathInsideWorkspace(workspace_root, existing);
            return;
        } else |err| switch (err) {
            error.FileNotFound => {
                if (try symlinkTargetAbsolute(arena, current)) |target| {
                    try ensureCreateTargetSymlinksInsideWorkspace(arena, workspace_root, target, depth + 1);
                }

                const basename = std.fs.path.basename(current);
                if (basename.len == 0) return err;
                const parent = std.fs.path.dirname(current) orelse return err;
                if (std.mem.eql(u8, parent, current)) return err;
                current = parent;
            },
            else => return err,
        }
    }
}

fn symlinkTargetAbsolute(arena: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .sym_link) return null;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.readLinkAbsolute(io_mod.getIo(), path, &buf);
    const target = buf[0..len];
    if (std.fs.path.isAbsolute(target)) {
        return try std.fs.path.resolve(arena, &.{target});
    }

    const parent = std.fs.path.dirname(path) orelse return error.PathOutsideWorkspace;
    return try std.fs.path.resolve(arena, &.{ parent, target });
}

pub fn ensurePathInsideWorkspace(workspace_root: []const u8, absolute: []const u8) !void {
    if (workspace_root.len == 0) return error.WorkspaceUnavailable;
    if (!pathInside(workspace_root, absolute)) return error.PathOutsideWorkspace;
}

pub fn workspaceRelativePath(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    absolute: []const u8,
) ![]const u8 {
    if (!pathInside(workspace_root, absolute)) return arena.dupe(u8, absolute);
    return std.fs.path.relative(arena, "/", null, workspace_root, absolute) catch try arena.dupe(u8, absolute);
}

pub fn ensureParentDirectories(path_abs: []const u8) !void {
    const parent = std.fs.path.dirname(path_abs) orelse return;

    var root = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), "/", .{});
    defer root.close(io_mod.getIo());

    const relative_to_root = std.mem.trimStart(u8, parent, "/");
    if (relative_to_root.len == 0) return;
    try root.createDirPath(io_mod.getIo(), relative_to_root);
}

const PathEntryParts = struct {
    parent: []const u8,
    basename: []const u8,
};

fn resolveWorkspacePathEntryParts(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
) !PathEntryParts {
    const cleaned = std.mem.trim(u8, input_path, path_entry_whitespace);
    if (cleaned.len == 0) return error.InvalidPath;

    if (invalidPathEntryBasename(std.fs.path.basename(cleaned))) return error.InvalidPath;

    const absolute = if (std.fs.path.isAbsolute(cleaned))
        try std.fs.path.resolve(arena, &.{cleaned})
    else
        try std.fs.path.resolve(arena, &.{ workspace_root, cleaned });

    const parent = std.fs.path.dirname(absolute) orelse return error.PathOutsideWorkspace;
    const basename = std.fs.path.basename(absolute);
    if (invalidPathEntryBasename(basename)) return error.InvalidPath;

    return .{ .parent = parent, .basename = basename };
}

fn resolveWorkspacePathEntryCreateParent(
    arena: std.mem.Allocator,
    workspace_root: []const u8,
    parent: []const u8,
) ![]const u8 {
    const resolved_parent = io_mod.realpathAlloc(arena, parent) catch |err| switch (err) {
        error.FileNotFound => return resolveCreateTargetFromNearestExisting(arena, workspace_root, parent),
        else => return err,
    };

    try ensurePathInsideWorkspace(workspace_root, resolved_parent);
    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), resolved_parent, .{});
    dir.close(io_mod.getIo());
    return resolved_parent;
}

fn invalidPathEntryBasename(basename: []const u8) bool {
    return basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..");
}

pub fn pathInside(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (root.len == 0) return false;
    if (root[root.len - 1] == std.fs.path.sep) return true;
    return candidate.len > root.len and candidate[root.len] == std.fs.path.sep;
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn createTestSymlinkOrSkip(dir: std.Io.Dir, target_path: []const u8, link_path: []const u8, is_directory: bool) !void {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    dir.symLink(io_mod.getIo(), target_path, link_path, .{ .is_directory = is_directory }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) {
            return error.SkipZigTest;
        }
        return err;
    };
}
