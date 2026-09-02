const std = @import("std");
const io_mod = @import("../shared/io.zig");
const pathing = @import("pathing.zig");

const Allocator = std.mem.Allocator;

pub const max_additional_directories: usize = 16;
/// Returns an owned identity for an existing directory. The caller frees it
/// with the allocator passed here.
pub fn addDirectoryIdentityAlloc(
    alloc: Allocator,
    primary_directory: []const u8,
    input_path: []const u8,
) Error![]u8 {
    return canonicalExistingDirectory(alloc, primary_directory, input_path);
}

/// Returns an owned identity for a stored directory. Existing directories use
/// their real path; unavailable directories use their normalized absolute path.
/// The caller frees it with the allocator passed here.
pub fn storedDirectoryIdentityAlloc(
    alloc: Allocator,
    primary_directory: []const u8,
    input_path: []const u8,
) Error![]u8 {
    const resolved = try resolveSavedDirectory(alloc, primary_directory, input_path);
    return resolved.path;
}

pub const Error = Allocator.Error || error{
    InvalidPath,
    PathNotFound,
    NotDirectory,
    UnknownAdditionalDirectory,
    PrimaryDirectory,
    TooManyDirectories,
};

pub const Entry = struct {
    path: []u8,
    saved: bool,
    command_line: bool,
    available: bool,
    active: bool,
};

pub const SavedSource = struct {
    source: []const u8,
    identity: []const u8,
    identity_canonical: bool = true,
};

pub const AccessScope = struct {
    primary_directory: []const u8,
    additional_directories: []const Entry,

    pub fn contains(self: AccessScope, absolute_path: []const u8) bool {
        return self.rootForPath(absolute_path) != null;
    }

    pub fn primaryOnly(primary_directory: []const u8) AccessScope {
        return .{ .primary_directory = primary_directory, .additional_directories = &.{} };
    }

    pub fn additionalRootForPath(self: AccessScope, absolute_path: []const u8) ?[]const u8 {
        for (self.additional_directories) |entry| {
            if (entry.active and pathing.pathInside(entry.path, absolute_path)) return entry.path;
        }
        return null;
    }

    pub fn rootForPath(self: AccessScope, absolute_path: []const u8) ?[]const u8 {
        if (pathing.pathInside(self.primary_directory, absolute_path)) {
            return self.primary_directory;
        }
        return self.additionalRootForPath(absolute_path);
    }

    pub fn resolvePath(
        self: AccessScope,
        arena: Allocator,
        input_path: []const u8,
        mode: @import("../shared/types.zig").ResolveMode,
    ) ![]const u8 {
        const trimmed = std.mem.trim(u8, input_path, " \t\r\n");
        if (!std.fs.path.isAbsolute(trimmed) and !std.mem.startsWith(u8, trimmed, "~")) {
            return pathing.resolveWorkspacePath(arena, self.primary_directory, input_path, mode);
        }
        const resolved = switch (mode) {
            .existing => try pathing.resolveWorkspaceOrExternalPath(arena, self.primary_directory, input_path),
            .create => try pathing.resolveWorkspaceOrExternalCreatePath(arena, self.primary_directory, input_path),
        };
        if (!self.contains(resolved)) return error.PathOutsideWorkspace;
        return resolved;
    }
};

pub const WorkspaceAccess = struct {
    entries: []Entry = &.{},
    saved_sources: []SavedSource = &.{},
    saved_suppressed: bool = false,

    pub fn init(
        alloc: Allocator,
        primary_directory: []const u8,
        saved_directories: []const []const u8,
        command_line_directories: []const []const u8,
        saved_suppressed: bool,
    ) Error!WorkspaceAccess {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(alloc);
        errdefer freeEntries(alloc, entries.items);
        var saved_sources: std.ArrayList(SavedSource) = .empty;
        errdefer saved_sources.deinit(alloc);
        errdefer freeSavedSources(alloc, saved_sources.items);

        for (saved_directories) |path| {
            const resolved = try resolveSavedDirectory(alloc, primary_directory, path);
            const identity = alloc.dupe(u8, resolved.path) catch |err| {
                alloc.free(resolved.path);
                return err;
            };
            errdefer alloc.free(identity);
            try appendOrMerge(
                alloc,
                &entries,
                resolved.path,
                true,
                false,
                resolved.available,
            );
            const source = try alloc.dupe(u8, path);
            errdefer alloc.free(source);
            try saved_sources.append(alloc, .{
                .source = source,
                .identity = identity,
                .identity_canonical = resolved.available,
            });
        }
        for (command_line_directories) |path| {
            const resolved = try canonicalExistingDirectory(alloc, primary_directory, path);
            try appendOrMerge(alloc, &entries, resolved, false, true, true);
        }

        const owned_entries = try entries.toOwnedSlice(alloc);
        errdefer {
            freeEntries(alloc, owned_entries);
            if (owned_entries.len > 0) alloc.free(owned_entries);
        }
        const owned_sources = try saved_sources.toOwnedSlice(alloc);
        var result = WorkspaceAccess{
            .entries = owned_entries,
            .saved_sources = owned_sources,
            .saved_suppressed = saved_suppressed,
        };
        result.recomputeActive();
        return result;
    }

    pub fn deinit(self: *WorkspaceAccess, alloc: Allocator) void {
        freeEntries(alloc, self.entries);
        if (self.entries.len > 0) alloc.free(self.entries);
        freeSavedSources(alloc, self.saved_sources);
        if (self.saved_sources.len > 0) alloc.free(self.saved_sources);
        self.* = .{};
    }

    pub fn scope(self: *const WorkspaceAccess, primary_directory: []const u8) AccessScope {
        return .{
            .primary_directory = primary_directory,
            .additional_directories = self.entries,
        };
    }

    pub fn eql(self: *const WorkspaceAccess, other: *const WorkspaceAccess) bool {
        if (self.entries.len != other.entries.len) return false;
        for (self.entries, other.entries) |left, right| {
            if (!std.mem.eql(u8, left.path, right.path) or
                left.saved != right.saved or
                left.command_line != right.command_line or
                left.available != right.available or
                left.active != right.active)
            {
                return false;
            }
        }
        return true;
    }

    pub fn commandLineSourceRemoved(
        self: *const WorkspaceAccess,
        replacement: *const WorkspaceAccess,
    ) bool {
        for (self.entries) |entry| {
            if (!entry.command_line) continue;
            var retained = false;
            for (replacement.entries) |candidate| {
                if (candidate.command_line and std.mem.eql(u8, entry.path, candidate.path)) {
                    retained = true;
                    break;
                }
            }
            if (!retained) return true;
        }
        return false;
    }

    pub fn stageAvailabilityRefresh(
        self: *const WorkspaceAccess,
        alloc: Allocator,
        primary_directory: []const u8,
    ) Error!?WorkspaceAccess {
        const refreshed_sources = try alloc.alloc(RefreshedSavedSource, self.saved_sources.len);
        defer alloc.free(refreshed_sources);
        var initialized_sources: usize = 0;
        defer for (refreshed_sources[0..initialized_sources]) |source| alloc.free(source.identity);

        for (self.saved_sources, refreshed_sources) |source, *refreshed| {
            const resolved = if (source.identity_canonical)
                try resolveObservedDirectory(alloc, primary_directory, source.identity)
            else
                try resolveSavedDirectory(alloc, primary_directory, source.source);
            refreshed.* = .{
                .source = source,
                .identity = resolved.path,
                .identity_canonical = source.identity_canonical or resolved.available,
                .available = resolved.available,
            };
            initialized_sources += 1;
        }

        var replacement = WorkspaceAccess{
            .saved_suppressed = self.saved_suppressed,
        };
        errdefer replacement.deinit(alloc);
        for (refreshed_sources) |source| {
            try appendSavedSource(
                alloc,
                &replacement,
                source.source.source,
                source.identity,
                source.identity_canonical,
            );
        }

        const appended_sources = try alloc.alloc(bool, refreshed_sources.len);
        defer alloc.free(appended_sources);
        @memset(appended_sources, false);

        for (self.entries) |entry| {
            for (refreshed_sources, 0..) |source, source_index| {
                if (appended_sources[source_index] or
                    !std.mem.eql(u8, source.source.identity, entry.path))
                {
                    continue;
                }
                try appendOwnedEntryOrMerge(
                    alloc,
                    &replacement,
                    try alloc.dupe(u8, source.identity),
                    true,
                    false,
                    source.available,
                );
                appended_sources[source_index] = true;
            }
            if (!entry.command_line) continue;
            const resolved = try resolveObservedDirectory(alloc, primary_directory, entry.path);
            try appendOwnedEntryOrMerge(
                alloc,
                &replacement,
                resolved.path,
                false,
                true,
                resolved.available,
            );
        }
        for (refreshed_sources, 0..) |source, source_index| {
            if (appended_sources[source_index]) continue;
            try appendOwnedEntryOrMerge(
                alloc,
                &replacement,
                try alloc.dupe(u8, source.identity),
                true,
                false,
                source.available,
            );
        }

        replacement.recomputeActive();
        if (self.refreshStateEql(&replacement)) {
            replacement.deinit(alloc);
            return null;
        }
        return replacement;
    }

    /// Returns an owned slice and owned paths. The caller frees every path and
    /// then the slice with the allocator passed here.
    pub fn savedDirectoriesAlloc(self: *const WorkspaceAccess, alloc: Allocator) Allocator.Error![][]u8 {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| alloc.free(path);
            paths.deinit(alloc);
        }
        for (self.entries) |entry| {
            if (!entry.saved) continue;
            try paths.append(alloc, try alloc.dupe(u8, entry.path));
        }
        return paths.toOwnedSlice(alloc);
    }

    /// Returns owned source spellings in durable order. The caller frees every
    /// path and then the slice with the allocator passed here.
    pub fn savedSourcePathsAlloc(self: *const WorkspaceAccess, alloc: Allocator) Allocator.Error![][]u8 {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| alloc.free(path);
            paths.deinit(alloc);
        }
        for (self.saved_sources) |source| {
            try paths.append(alloc, try alloc.dupe(u8, source.source));
        }
        return paths.toOwnedSlice(alloc);
    }

    pub fn stageAddSaved(
        self: *const WorkspaceAccess,
        alloc: Allocator,
        primary_directory: []const u8,
        input_path: []const u8,
    ) Error!WorkspaceAccess {
        const canonical = try canonicalExistingDirectory(alloc, primary_directory, input_path);
        defer alloc.free(canonical);
        for (self.entries) |entry| {
            if (entry.saved and std.mem.eql(u8, entry.path, canonical)) {
                return self.clone(alloc);
            }
        }

        var replacement = try self.clone(alloc);
        errdefer replacement.deinit(alloc);
        try appendSavedSource(alloc, &replacement, canonical, canonical, true);

        for (replacement.entries) |*entry| {
            if (!std.mem.eql(u8, entry.path, canonical)) continue;
            entry.saved = true;
            replacement.recomputeActive();
            return replacement;
        }
        if (replacement.entries.len >= max_additional_directories) return error.TooManyDirectories;
        try appendEntry(alloc, &replacement, .{
            .path = try alloc.dupe(u8, canonical),
            .saved = true,
            .command_line = false,
            .available = true,
            .active = false,
        });
        replacement.recomputeActive();
        return replacement;
    }

    pub fn stageRemove(
        self: *const WorkspaceAccess,
        alloc: Allocator,
        primary_directory: []const u8,
        input_path: []const u8,
    ) Error!WorkspaceAccess {
        const identity = try self.removalIdentityAlloc(alloc, primary_directory, input_path);
        defer alloc.free(identity);

        var replacement = try self.clone(alloc);
        errdefer replacement.deinit(alloc);
        try removeIdentity(alloc, &replacement, identity);
        replacement.recomputeActive();
        return replacement;
    }

    pub fn stageClear(self: *const WorkspaceAccess) WorkspaceAccess {
        return .{
            .saved_suppressed = self.saved_suppressed,
        };
    }

    pub fn clone(self: *const WorkspaceAccess, alloc: Allocator) Allocator.Error!WorkspaceAccess {
        var replacement = WorkspaceAccess{
            .saved_suppressed = self.saved_suppressed,
        };
        errdefer replacement.deinit(alloc);
        for (self.entries) |entry| {
            try appendEntry(alloc, &replacement, .{
                .path = try alloc.dupe(u8, entry.path),
                .saved = entry.saved,
                .command_line = entry.command_line,
                .available = entry.available,
                .active = entry.active,
            });
        }
        for (self.saved_sources) |source| {
            try appendSavedSource(
                alloc,
                &replacement,
                source.source,
                source.identity,
                source.identity_canonical,
            );
        }
        return replacement;
    }

    pub fn applyLaunch(
        self: *WorkspaceAccess,
        alloc: Allocator,
        primary_directory: []const u8,
        command_line_directories: []const []const u8,
        saved_suppressed: bool,
    ) Error!void {
        var replacement = WorkspaceAccess{
            .saved_suppressed = saved_suppressed,
        };
        errdefer replacement.deinit(alloc);
        for (self.entries) |entry| {
            if (!entry.saved) continue;
            try appendEntry(alloc, &replacement, .{
                .path = try alloc.dupe(u8, entry.path),
                .saved = true,
                .command_line = false,
                .available = entry.available,
                .active = false,
            });
        }
        for (self.saved_sources) |source| {
            try appendSavedSource(
                alloc,
                &replacement,
                source.source,
                source.identity,
                source.identity_canonical,
            );
        }
        for (command_line_directories) |path| {
            const canonical = try canonicalExistingDirectory(alloc, primary_directory, path);
            try appendOwnedEntryOrMerge(alloc, &replacement, canonical, false, true, true);
        }
        replacement.recomputeActive();
        self.deinit(alloc);
        self.* = replacement;
    }

    fn removalIdentityAlloc(
        self: *const WorkspaceAccess,
        alloc: Allocator,
        primary_directory: []const u8,
        input_path: []const u8,
    ) Error![]u8 {
        const normalized_input = try resolveAbsoluteInput(alloc, primary_directory, input_path);
        defer alloc.free(normalized_input);
        for (self.saved_sources) |source| {
            const normalized_source = try resolveAbsoluteInput(alloc, primary_directory, source.source);
            defer alloc.free(normalized_source);
            if (std.mem.eql(u8, normalized_source, normalized_input)) {
                return alloc.dupe(u8, source.identity);
            }
        }

        const resolved = try resolveSavedDirectory(alloc, primary_directory, input_path);
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, resolved.path)) return resolved.path;
        }
        alloc.free(resolved.path);
        return error.UnknownAdditionalDirectory;
    }

    pub fn commandLineDirectoriesAlloc(
        self: *const WorkspaceAccess,
        alloc: Allocator,
    ) Allocator.Error![][]u8 {
        var paths: std.ArrayList([]u8) = .empty;
        errdefer {
            for (paths.items) |path| alloc.free(path);
            paths.deinit(alloc);
        }
        for (self.entries) |entry| {
            if (!entry.command_line) continue;
            try paths.append(alloc, try alloc.dupe(u8, entry.path));
        }
        return paths.toOwnedSlice(alloc);
    }

    fn recomputeActive(self: *WorkspaceAccess) void {
        for (self.entries) |*entry| {
            const source_active = entry.command_line or (entry.saved and !self.saved_suppressed);
            entry.active = entry.available and source_active;
        }
    }

    fn refreshStateEql(self: *const WorkspaceAccess, other: *const WorkspaceAccess) bool {
        if (!self.eql(other) or self.saved_sources.len != other.saved_sources.len) return false;
        for (self.saved_sources, other.saved_sources) |left, right| {
            if (!std.mem.eql(u8, left.source, right.source) or
                !std.mem.eql(u8, left.identity, right.identity) or
                left.identity_canonical != right.identity_canonical)
            {
                return false;
            }
        }
        return true;
    }
};

fn resolveAbsoluteInput(alloc: Allocator, primary_directory: []const u8, input_path: []const u8) Error![]u8 {
    if (input_path.len == 0 or input_path.len > std.fs.max_path_bytes or
        !std.unicode.utf8ValidateSlice(input_path) or
        std.mem.findScalar(u8, input_path, 0) != null)
    {
        return error.InvalidPath;
    }
    return if (std.fs.path.isAbsolute(input_path))
        std.fs.path.resolve(alloc, &.{input_path})
    else
        std.fs.path.resolve(alloc, &.{ primary_directory, input_path });
}

const SavedResolution = struct {
    path: []u8,
    available: bool,
};

const RefreshedSavedSource = struct {
    source: SavedSource,
    identity: []u8,
    identity_canonical: bool,
    available: bool,
};

fn resolveSavedDirectory(
    alloc: Allocator,
    primary_directory: []const u8,
    input_path: []const u8,
) Error!SavedResolution {
    try validateStoredPath(input_path);
    const canonical = canonicalExistingDirectory(alloc, primary_directory, input_path) catch |err| switch (err) {
        error.PathNotFound, error.NotDirectory => {
            const normalized = try resolveAbsoluteInput(alloc, primary_directory, input_path);
            defer alloc.free(normalized);
            if (std.mem.eql(u8, normalized, primary_directory)) return error.PrimaryDirectory;
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const identity = pathing.resolveCreateTargetFromNearestExisting(
                arena,
                "/",
                normalized,
            ) catch |resolve_err| switch (resolve_err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidPath,
            };
            return .{ .path = try alloc.dupe(u8, identity), .available = false };
        },
        else => return err,
    };
    return .{ .path = canonical, .available = true };
}

fn canonicalExistingDirectory(
    alloc: Allocator,
    primary_directory: []const u8,
    input_path: []const u8,
) Error![]u8 {
    if (input_path.len == 0 or input_path.len > std.fs.max_path_bytes or
        !std.unicode.utf8ValidateSlice(input_path) or
        std.mem.findScalar(u8, input_path, 0) != null)
    {
        return error.InvalidPath;
    }

    const absolute = if (std.fs.path.isAbsolute(input_path))
        try alloc.dupe(u8, input_path)
    else
        try std.fs.path.resolve(alloc, &.{ primary_directory, input_path });
    defer alloc.free(absolute);

    const canonical = io_mod.realpathAlloc(alloc, absolute) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.PathNotFound,
        else => return error.InvalidPath,
    };
    errdefer alloc.free(canonical);

    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), canonical, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.PathNotFound,
        error.NotDir => return error.NotDirectory,
        else => return error.InvalidPath,
    };
    if (stat.kind != .directory) return error.NotDirectory;
    if (std.mem.eql(u8, canonical, primary_directory)) return error.PrimaryDirectory;
    return canonical;
}

fn resolveObservedDirectory(
    alloc: Allocator,
    primary_directory: []const u8,
    identity: []const u8,
) Error!SavedResolution {
    const canonical = canonicalExistingDirectory(alloc, primary_directory, identity) catch |err| switch (err) {
        error.PathNotFound, error.NotDirectory => return .{
            .path = try alloc.dupe(u8, identity),
            .available = false,
        },
        else => return err,
    };
    if (std.mem.eql(u8, canonical, identity)) return .{ .path = canonical, .available = true };
    alloc.free(canonical);
    return .{
        .path = try alloc.dupe(u8, identity),
        .available = false,
    };
}

fn validateStoredPath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > std.fs.max_path_bytes or
        !std.fs.path.isAbsolute(path) or
        !std.unicode.utf8ValidateSlice(path) or
        std.mem.findScalar(u8, path, 0) != null)
    {
        return error.InvalidPath;
    }
}

fn appendEntry(alloc: Allocator, access: *WorkspaceAccess, entry: Entry) Allocator.Error!void {
    errdefer alloc.free(entry.path);
    const expanded = try alloc.alloc(Entry, access.entries.len + 1);
    @memcpy(expanded[0..access.entries.len], access.entries);
    expanded[access.entries.len] = entry;
    if (access.entries.len > 0) alloc.free(access.entries);
    access.entries = expanded;
}

fn appendSavedSource(
    alloc: Allocator,
    access: *WorkspaceAccess,
    source: []const u8,
    identity: []const u8,
    identity_canonical: bool,
) Allocator.Error!void {
    const expanded = try alloc.alloc(SavedSource, access.saved_sources.len + 1);
    errdefer alloc.free(expanded);
    const owned_source = try alloc.dupe(u8, source);
    errdefer alloc.free(owned_source);
    const owned_identity = try alloc.dupe(u8, identity);
    errdefer alloc.free(owned_identity);
    @memcpy(expanded[0..access.saved_sources.len], access.saved_sources);
    expanded[access.saved_sources.len] = .{
        .source = owned_source,
        .identity = owned_identity,
        .identity_canonical = identity_canonical,
    };
    if (access.saved_sources.len > 0) alloc.free(access.saved_sources);
    access.saved_sources = expanded;
}

fn appendOwnedEntryOrMerge(
    alloc: Allocator,
    access: *WorkspaceAccess,
    owned_path: []u8,
    saved: bool,
    command_line: bool,
    available: bool,
) Error!void {
    for (access.entries) |*entry| {
        if (!std.mem.eql(u8, entry.path, owned_path)) continue;
        alloc.free(owned_path);
        entry.saved = entry.saved or saved;
        entry.command_line = entry.command_line or command_line;
        entry.available = entry.available or available;
        return;
    }
    if (access.entries.len >= max_additional_directories) {
        alloc.free(owned_path);
        return error.TooManyDirectories;
    }
    return appendEntry(alloc, access, .{
        .path = owned_path,
        .saved = saved,
        .command_line = command_line,
        .available = available,
        .active = false,
    });
}

fn removeIdentity(
    alloc: Allocator,
    access: *WorkspaceAccess,
    identity: []const u8,
) Allocator.Error!void {
    var entry_count: usize = 0;
    for (access.entries) |entry| {
        if (!std.mem.eql(u8, entry.path, identity)) entry_count += 1;
    }
    var source_count: usize = 0;
    for (access.saved_sources) |source| {
        if (!std.mem.eql(u8, source.identity, identity)) source_count += 1;
    }

    const entries: []Entry = if (entry_count == 0) &.{} else try alloc.alloc(Entry, entry_count);
    errdefer if (entries.len > 0) alloc.free(entries);
    const sources: []SavedSource = if (source_count == 0) &.{} else try alloc.alloc(SavedSource, source_count);
    errdefer if (sources.len > 0) alloc.free(sources);

    var entry_index: usize = 0;
    for (access.entries) |entry| {
        if (std.mem.eql(u8, entry.path, identity)) {
            alloc.free(entry.path);
        } else {
            entries[entry_index] = entry;
            entry_index += 1;
        }
    }
    var source_index: usize = 0;
    for (access.saved_sources) |source| {
        if (std.mem.eql(u8, source.identity, identity)) {
            alloc.free(source.source);
            alloc.free(source.identity);
        } else {
            sources[source_index] = source;
            source_index += 1;
        }
    }
    if (access.entries.len > 0) alloc.free(access.entries);
    if (access.saved_sources.len > 0) alloc.free(access.saved_sources);
    access.entries = entries;
    access.saved_sources = sources;
}

fn appendOrMerge(
    alloc: Allocator,
    entries: *std.ArrayList(Entry),
    owned_path: []u8,
    saved: bool,
    command_line: bool,
    available: bool,
) Error!void {
    errdefer alloc.free(owned_path);
    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.path, owned_path)) continue;
        alloc.free(owned_path);
        entry.saved = entry.saved or saved;
        entry.command_line = entry.command_line or command_line;
        entry.available = entry.available or available;
        return;
    }
    if (entries.items.len >= max_additional_directories) {
        return error.TooManyDirectories;
    }
    try entries.append(alloc, .{
        .path = owned_path,
        .saved = saved,
        .command_line = command_line,
        .available = available,
        .active = false,
    });
}

fn freeEntries(alloc: Allocator, entries: []Entry) void {
    for (entries) |entry| alloc.free(entry.path);
}

fn freeSavedSources(alloc: Allocator, sources: []const SavedSource) void {
    for (sources) |source| {
        alloc.free(source.source);
        alloc.free(source.identity);
    }
}
