const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const list_window = @import("../shared/list_window.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const pathing = @import("../workspace/pathing.zig");
const skill_contract = @import("skill_contract.zig");
const context_limits = @import("../config/context_limits.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;
const catalog_notice_name_count: usize = 8;
const diagnostic_notice_item_count: usize = 4;

pub const skill_menu_max_visible_rows: u16 = 4;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
    source: SkillSource,
    /// Owned with discovered catalog entries. Null keeps managed skills strict.
    read_authority: ?[]const u8 = null,
};

pub const BoundedPromptSection = struct {
    text: []u8,
    notice: ?[]u8 = null,
    diagnostic_notice: ?[]u8 = null,

    pub fn deinit(self: *BoundedPromptSection, alloc: Allocator) void {
        alloc.free(self.text);
        if (self.notice) |notice| alloc.free(notice);
        if (self.diagnostic_notice) |notice| alloc.free(notice);
        self.* = undefined;
    }
};

pub const SkillDiagnosticCause = union(enum) {
    invalid_metadata: skill_contract.InvalidMetadataCause,
    linked_candidate_unavailable,
    unreadable,
    oversized,
};

pub const SkillDiagnosticScope = enum {
    root,
    candidate,
};

pub const SkillDiagnostic = struct {
    path: []const u8,
    source: SkillSource,
    scope: SkillDiagnosticScope,
    cause: SkillDiagnosticCause,
};

/// Owns the validated candidate directory and metadata file handles.
pub const OpenedSkillCandidate = struct {
    dir: std.Io.Dir,
    skill_file: std.Io.File,

    pub fn deinit(self: *OpenedSkillCandidate) void {
        self.skill_file.close(io_mod.getIo());
        self.dir.close(io_mod.getIo());
        self.* = undefined;
    }

    pub fn skillFile(self: *OpenedSkillCandidate) *std.Io.File {
        return &self.skill_file;
    }

    pub fn openResource(self: *OpenedSkillCandidate, resource: []const u8) !std.Io.File {
        const trimmed = std.mem.trim(u8, resource, " \t\r\n");
        if (trimmed.len == 0 or std.fs.path.isAbsolute(trimmed)) return error.InvalidSkillResourcePath;
        var segments = std.mem.tokenizeAny(u8, trimmed, "/\\");
        var segment = segments.next() orelse return error.InvalidSkillResourcePath;
        if (invalidResourceSegment(segment)) return error.InvalidSkillResourcePath;

        const child_segment = segments.next() orelse {
            return self.dir.openFile(io_mod.getIo(), segment, .{
                .allow_directory = false,
                .follow_symlinks = false,
            });
        };
        if (invalidResourceSegment(child_segment)) return error.InvalidSkillResourcePath;

        var current_dir = try self.dir.openDir(io_mod.getIo(), segment, .{
            .follow_symlinks = false,
        });
        defer current_dir.close(io_mod.getIo());
        segment = child_segment;

        while (segments.next()) |next_segment| {
            if (invalidResourceSegment(next_segment)) return error.InvalidSkillResourcePath;
            const next_dir = try current_dir.openDir(io_mod.getIo(), segment, .{
                .follow_symlinks = false,
            });
            current_dir.close(io_mod.getIo());
            current_dir = next_dir;
            segment = next_segment;
        }
        return current_dir.openFile(io_mod.getIo(), segment, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
    }
};

pub const SkillCandidateOpenResult = union(enum) {
    current: OpenedSkillCandidate,
    missing,
    name_mismatch,
    skipped: SkillDiagnosticCause,
};

pub fn resourceIsSkillFile(resource: []const u8) bool {
    const trimmed = std.mem.trim(u8, resource, " \t\r\n");
    if (trimmed.len == 0 or std.fs.path.isAbsolute(trimmed)) return false;
    var segments = std.mem.tokenizeAny(u8, trimmed, "/\\");
    const segment = segments.next() orelse return false;
    return std.mem.eql(u8, segment, "SKILL.md") and segments.next() == null;
}

fn invalidResourceSegment(segment: []const u8) bool {
    return std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..");
}

pub fn writeDiagnosticSummary(alloc: Allocator, writer: *std.Io.Writer, diagnostics: []const SkillDiagnostic) !void {
    if (diagnostics.len == 0) return;
    try writer.writeAll("skill discovery warning: ");
    const shown_count = @min(diagnostics.len, diagnostic_notice_item_count);
    for (diagnostics[0..shown_count], 0..) |diagnostic, index| {
        if (index > 0) try writer.writeAll("; ");
        switch (diagnostic.scope) {
            .root => {
                try writer.writeAll("inventory incomplete because root \"");
                try writeBoundedDiagnosticPath(alloc, writer, diagnostic.path);
                try writer.writeAll("\" could not be read, so an unknown number of skills may be missing; fix access to the root and reload skills");
            },
            .candidate => {
                try writer.writeAll("candidate \"");
                try writeBoundedDiagnosticPath(alloc, writer, diagnostic.path);
                try writer.writeAll("\" was skipped because ");
                switch (diagnostic.cause) {
                    .invalid_metadata => |cause| try writer.print(
                        "its metadata is invalid ({s}); use one safe name and an optional inline description or a >, >-, or | block, then reload skills",
                        .{@tagName(cause)},
                    ),
                    .linked_candidate_unavailable => try writer.writeAll("its linked skill directory could not be resolved to an authorized readable directory; repair or remove the link, or authorize its external location, then reload skills"),
                    .unreadable => try writer.writeAll("SKILL.md is unreadable or not a regular file; fix the file type or access, then reload skills"),
                    .oversized => try writer.print(
                        "its frontmatter exceeds the supported {d}-byte metadata header; shorten the name/description header, then reload skills",
                        .{skill_contract.max_frontmatter_bytes},
                    ),
                }
            },
        }
    }
    if (diagnostics.len > shown_count) {
        try writer.print("; {d} additional diagnostic{s} omitted", .{
            diagnostics.len - shown_count,
            if (diagnostics.len - shown_count == 1) "" else "s",
        });
    }
    if (debug_trace.activeLogPath()) |trace_path| {
        try writer.print("; see \"{f}\" for details", .{std.zig.fmtString(trace_path)});
    } else {
        try writer.writeAll("; relaunch with FX_TRACE=1 to write a trace log");
    }
}

fn writeBoundedDiagnosticPath(alloc: Allocator, writer: *std.Io.Writer, path: []const u8) !void {
    const observed = try writeBoundedEncodedScalar(
        alloc,
        writer,
        path,
        skill_contract.max_description_bytes,
    );
    if (observed > skill_contract.max_description_bytes) try writer.writeAll("...");
}

pub fn traceDiagnostics(surface: []const u8, diagnostics: []const SkillDiagnostic) void {
    for (diagnostics) |diagnostic| {
        const path = std.zig.fmtString(diagnostic.path);
        switch (diagnostic.cause) {
            .invalid_metadata => |cause| debug_trace.logf(
                "skills",
                "discovery_diagnostic surface={s} source={s} scope={s} kind=invalid_metadata cause={s} path=\"{f}\" path_bytes={d}",
                .{ surface, @tagName(diagnostic.source), @tagName(diagnostic.scope), @tagName(cause), path, diagnostic.path.len },
            ),
            .linked_candidate_unavailable => debug_trace.logf(
                "skills",
                "discovery_diagnostic surface={s} source={s} scope={s} kind=io cause=linked_candidate_unavailable path=\"{f}\" path_bytes={d}",
                .{ surface, @tagName(diagnostic.source), @tagName(diagnostic.scope), path, diagnostic.path.len },
            ),
            .unreadable => debug_trace.logf(
                "skills",
                "discovery_diagnostic surface={s} source={s} scope={s} kind=io cause=unreadable path=\"{f}\" path_bytes={d}",
                .{ surface, @tagName(diagnostic.source), @tagName(diagnostic.scope), path, diagnostic.path.len },
            ),
            .oversized => debug_trace.logf(
                "skills",
                "discovery_diagnostic surface={s} source={s} scope={s} kind=io cause=oversized path=\"{f}\" path_bytes={d}",
                .{ surface, @tagName(diagnostic.source), @tagName(diagnostic.scope), path, diagnostic.path.len },
            ),
        }
    }
}

pub const SkillDiscovery = struct {
    skills: []Skill = &.{},
    diagnostics: []SkillDiagnostic = &.{},

    pub fn deinit(self: *SkillDiscovery, alloc: Allocator) void {
        freeSkills(alloc, self.skills);
        freeSkillDiagnostics(alloc, self.diagnostics);
        self.* = .{};
    }
};

pub const SkillResolution = union(enum) {
    found: *const Skill,
    not_found,
    ambiguous_name,
    name_location_mismatch,
};

pub const SkillSummaryStyles = struct {
    source_label_style: []const u8 = "",
    reset_style: []const u8 = "",
};

pub const SkillSource = skill_contract.SkillSource;

pub const SkillMenuSourceFilter = enum {
    all,
    fx,
    workspace,
    opencode,
    codex,
    claude,
    agents,
    claw,
};

pub const skill_menu_source_filters = [_]SkillMenuSourceFilter{
    .all,
    .fx,
    .workspace,
    .claude,
    .codex,
    .agents,
    .opencode,
    .claw,
};

pub const SkillMenuOrigin = enum {
    command,
    dollar,
    slash,
    paste,

    pub fn isMention(self: SkillMenuOrigin) bool {
        return switch (self) {
            .dollar, .paste => true,
            .command, .slash => false,
        };
    }
};


pub const SkillMenuTarget = struct {
    start: usize = 0,
    end: usize = 0,
};

const SkillRoot = struct {
    path: []const u8,
    source: SkillSource,
    read_authority: ?[]const u8,
};

const SkillEntry = struct {
    name: []u8,
    linked: bool,
};

/// Deduplicates filesystem aliases without collapsing distinct skills that
/// share metadata names. Ordered discovery makes the first logical root the
/// stable source and display path for each canonical candidate directory.
const CanonicalSkillPaths = struct {
    paths: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *CanonicalSkillPaths, alloc: Allocator) void {
        var keys = self.paths.keyIterator();
        while (keys.next()) |path| alloc.free(@constCast(path.*));
        self.paths.deinit(alloc);
        self.* = .{};
    }

    fn remember(self: *CanonicalSkillPaths, alloc: Allocator, logical_path: []const u8) !bool {
        const canonical_path = io_mod.realpathAlloc(alloc, logical_path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return true;
        };
        if (self.paths.contains(canonical_path)) {
            alloc.free(canonical_path);
            return false;
        }
        errdefer alloc.free(canonical_path);
        try self.paths.put(alloc, canonical_path, {});
        return true;
    }
};

pub fn loadVisibleSkills(
    alloc: Allocator,
    workspace_root: ?[]const u8,
    home: ?[]const u8,
    skills_dir: []const u8,
    root_policy: skill_contract.RootPolicy,
) !SkillDiscovery {
    var skills: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills.items) |skill| freeSkill(alloc, skill);
        skills.deinit(alloc);
    }
    var diagnostics: std.ArrayList(SkillDiagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diagnostic| alloc.free(diagnostic.path);
        diagnostics.deinit(alloc);
    }
    var canonical_skill_paths: CanonicalSkillPaths = .{};
    defer canonical_skill_paths.deinit(alloc);

    var roots: std.ArrayList(SkillRoot) = .empty;
    defer {
        for (roots.items) |root| alloc.free(root.path);
        roots.deinit(alloc);
    }

    if (workspace_root) |root| {
        try appendWorkspaceRoots(alloc, &roots, root, home, root_policy.workspace_roots);
    }

    if (root_policy.managed_root_source) |source| {
        try appendDupeRoot(alloc, &roots, source, skills_dir);
    }

    if (home) |home_root| {
        for (root_policy.global_roots) |spec| {
            try appendSpecRoot(alloc, &roots, home_root, spec);
        }
    }

    for (roots.items) |root| {
        try appendSkillsFromDir(alloc, &skills, &diagnostics, &canonical_skill_paths, root);
    }

    const owned_skills = try skills.toOwnedSlice(alloc);
    errdefer freeSkills(alloc, owned_skills);
    const owned_diagnostics = try diagnostics.toOwnedSlice(alloc);
    return .{
        .skills = owned_skills,
        .diagnostics = owned_diagnostics,
    };
}

fn appendWorkspaceRoots(
    alloc: Allocator,
    roots: *std.ArrayList(SkillRoot),
    workspace_root: []const u8,
    home: ?[]const u8,
    root_specs: []const skill_contract.RootSpec,
) !void {
    var current: ?[]const u8 = workspace_root;
    while (current) |dir| : (current = std.fs.path.dirname(dir)) {
        if (home) |home_root| {
            if (std.mem.eql(u8, dir, home_root)) break;
        }

        for (root_specs) |spec| {
            try appendSpecRoot(alloc, roots, dir, spec);
        }
    }
}

fn appendSpecRoot(alloc: Allocator, roots: *std.ArrayList(SkillRoot), base: []const u8, spec: skill_contract.RootSpec) !void {
    try appendOwnedRoot(alloc, roots, try std.fs.path.join(alloc, &.{ base, spec.path }), spec.source, base);
}

fn appendDupeRoot(alloc: Allocator, roots: *std.ArrayList(SkillRoot), source: SkillSource, path: []const u8) !void {
    try appendOwnedRoot(alloc, roots, try alloc.dupe(u8, path), source, null);
}

fn appendOwnedRoot(
    alloc: Allocator,
    roots: *std.ArrayList(SkillRoot),
    path: []u8,
    source: SkillSource,
    read_authority: ?[]const u8,
) !void {
    if (containsRootPath(roots.items, path)) {
        alloc.free(path);
        return;
    }

    roots.append(alloc, .{
        .path = path,
        .source = source,
        .read_authority = read_authority,
    }) catch |err| {
        alloc.free(path);
        return err;
    };
}

fn openContainedDir(
    alloc: Allocator,
    logical_path: []const u8,
    read_authority: []const u8,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    const canonical_path = try io_mod.realpathAlloc(alloc, logical_path);
    defer alloc.free(canonical_path);
    if (!try canonicalPathHasReadAuthority(alloc, read_authority, canonical_path)) {
        return error.PathOutsideReadAuthority;
    }
    return io_mod.openDirAbsoluteNoFollow(canonical_path, options);
}

fn pathInsideReadAuthorities(
    read_authority: []const u8,
    extra_authorities: []const []const u8,
    canonical_path: []const u8,
) bool {
    if (pathing.pathInside(read_authority, canonical_path)) return true;
    for (extra_authorities) |authority| {
        if (pathing.pathInside(authority, canonical_path)) return true;
    }
    return false;
}

fn canonicalPathHasReadAuthority(
    alloc: Allocator,
    read_authority: []const u8,
    canonical_path: []const u8,
) error{OutOfMemory}!bool {
    if (pathInsideReadAuthorities(read_authority, &.{}, canonical_path)) return true;
    const extra_authorities = try externalSymlinkAuthorities(alloc);
    defer freeExternalAuthorities(alloc, extra_authorities);
    return pathInsideReadAuthorities(read_authority, extra_authorities, canonical_path);
}

/// Parses FX_SKILL_SYMLINK_AUTHORITIES (colon-separated absolute paths) into
/// owned duplicates. Returns an empty slice when the variable is unset or
/// contains no valid absolute paths. Relative entries and entries containing
/// `..` components are silently skipped. The caller must free each entry and
/// the slice itself via `freeExternalAuthorities`.
fn externalSymlinkAuthorities(alloc: Allocator) ![][]const u8 {
    const raw = io_mod.getenv("FX_SKILL_SYMLINK_AUTHORITIES") orelse return &.{};
    if (raw.len == 0) return &.{};

    var authorities: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (authorities.items) |item| alloc.free(item);
        authorities.deinit(alloc);
    }

    var it = std.mem.tokenizeScalar(u8, raw, ':');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;
        if (!std.fs.path.isAbsolute(trimmed)) continue;
        if (pathContainsDotDot(trimmed)) continue;
        const owned = try alloc.dupe(u8, trimmed);
        errdefer alloc.free(owned);
        authorities.append(alloc, owned) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
    return try authorities.toOwnedSlice(alloc);
}

fn pathContainsDotDot(path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return true;
    }
    return false;
}

fn freeExternalAuthorities(alloc: Allocator, authorities: [][]const u8) void {
    for (authorities) |authority| alloc.free(authority);
    if (authorities.len > 0) alloc.free(authorities);
}

fn containsRootPath(roots: []const SkillRoot, path: []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, root.path, path)) return true;
    }
    return false;
}

fn appendSkillsFromDir(
    alloc: Allocator,
    skills: *std.ArrayList(Skill),
    diagnostics: ?*std.ArrayList(SkillDiagnostic),
    canonical_skill_paths: *CanonicalSkillPaths,
    root: SkillRoot,
) !void {
    var dir = (if (root.read_authority) |read_authority|
        openContainedDir(alloc, root.path, read_authority, .{ .iterate = true })
    else
        io_mod.openDirAbsoluteNoFollow(root.path, .{ .iterate = true })) catch |err| {
        if ((err == error.FileNotFound or err == error.NotDir) and rootPathIsMissing(root.path)) return;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, root.path, root.source, .root, .unreadable);
        return;
    };
    defer dir.close(io_mod.getIo());

    var entries: std.ArrayList(SkillEntry) = .empty;
    defer {
        for (entries.items) |entry| alloc.free(entry.name);
        entries.deinit(alloc);
    }

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io_mod.getIo()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, root.path, root.source, .root, .unreadable);
            return;
        } orelse break;
        const linked = entry.kind == .sym_link;
        if (entry.kind != .directory and !(linked and root.read_authority != null)) continue;

        const owned_name = try alloc.dupe(u8, entry.name);
        entries.append(alloc, .{ .name = owned_name, .linked = linked }) catch |err| {
            alloc.free(owned_name);
            return err;
        };
    }

    sort_utils.sort(SkillEntry, entries.items, {}, struct {
        fn lessThan(_: void, left: SkillEntry, right: SkillEntry) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.lessThan);

    for (entries.items) |entry| {
        try appendSkillCandidate(alloc, skills, diagnostics, canonical_skill_paths, root, &dir, entry.name, entry.linked);
    }
}

fn rootPathIsMissing(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var components = std.fs.path.componentIterator(path);
    const root = components.root() orelse return false;
    var component = components.next() orelse return false;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{}) catch return false;
    defer dir.close(io_mod.getIo());

    while (true) {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) return false;
        const stat = dir.statFile(io_mod.getIo(), component.name, .{ .follow_symlinks = false }) catch |err| {
            return err == error.FileNotFound;
        };
        if (stat.kind != .directory) return false;
        const next_component = components.next() orelse return false;
        const next_dir = dir.openDir(io_mod.getIo(), component.name, .{ .follow_symlinks = false }) catch return false;
        dir.close(io_mod.getIo());
        dir = next_dir;
        component = next_component;
    }
}

const PrimarySkillFileOpenResult = union(enum) {
    opened: std.Io.File,
    missing,
    rejected,
};

const PrimarySkillFileOpenHook = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

const PrimarySkillFileOpenOptions = struct {
    after_preflight: ?PrimarySkillFileOpenHook = null,
    after_open: ?PrimarySkillFileOpenHook = null,
};

fn openPrimarySkillFile(
    alloc: Allocator,
    candidate_dir: *std.Io.Dir,
    read_authority: ?[]const u8,
) error{OutOfMemory}!PrimarySkillFileOpenResult {
    return openPrimarySkillFileWithOptions(alloc, candidate_dir, read_authority, .{});
}

fn openPrimarySkillFileWithOptions(
    alloc: Allocator,
    candidate_dir: *std.Io.Dir,
    read_authority: ?[]const u8,
    options: PrimarySkillFileOpenOptions,
) error{OutOfMemory}!PrimarySkillFileOpenResult {
    const path_stat = candidate_dir.statFile(io_mod.getIo(), "SKILL.md", .{ .follow_symlinks = false }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return if (err == error.FileNotFound) .missing else .rejected;
    };

    switch (path_stat.kind) {
        .file => {
            const file = io_mod.openExistingReadOnlyRegularFile(candidate_dir.*, "SKILL.md", .no_follow) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return if (err == error.FileNotFound) .missing else .rejected;
            };
            return .{ .opened = file };
        },
        .sym_link => {
            const authority = read_authority orelse return .rejected;

            const preflight_path = io_mod.dirRealpathAlloc(alloc, candidate_dir.*, "SKILL.md") catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .rejected;
            };
            defer alloc.free(preflight_path);
            if (!try canonicalPathHasReadAuthority(alloc, authority, preflight_path)) return .rejected;
            const preflight_stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), preflight_path, .{ .follow_symlinks = false }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .rejected;
            };
            if (preflight_stat.kind != .file) return .rejected;
            if (options.after_preflight) |hook| hook.run(hook.ctx);

            var file = io_mod.openExistingReadOnlyRegularFile(candidate_dir.*, "SKILL.md", .follow) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .rejected;
            };
            errdefer file.close(io_mod.getIo());
            if (options.after_open) |hook| hook.run(hook.ctx);
            const opened_path = io_mod.openedFilePathAlloc(alloc, file) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                file.close(io_mod.getIo());
                return .rejected;
            };
            defer alloc.free(opened_path);
            if (!try canonicalPathHasReadAuthority(alloc, authority, opened_path)) {
                file.close(io_mod.getIo());
                return .rejected;
            }
            return .{ .opened = file };
        },
        else => return .rejected,
    }
}

fn appendSkillCandidate(
    alloc: Allocator,
    skills: *std.ArrayList(Skill),
    diagnostics: ?*std.ArrayList(SkillDiagnostic),
    canonical_skill_paths: *CanonicalSkillPaths,
    root: SkillRoot,
    root_dir: *std.Io.Dir,
    entry_name: []const u8,
    linked: bool,
) !void {
    const candidate_path = try std.fs.path.join(alloc, &.{ root.path, entry_name });
    defer alloc.free(candidate_path);

    var candidate_dir = if (linked) linked_candidate: {
        const read_authority = root.read_authority orelse return;
        break :linked_candidate openContainedDir(alloc, candidate_path, read_authority, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .linked_candidate_unavailable);
            return;
        };
    } else root_dir.openDir(io_mod.getIo(), entry_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .unreadable);
        return;
    };
    defer candidate_dir.close(io_mod.getIo());

    var file = switch (try openPrimarySkillFile(alloc, &candidate_dir, root.read_authority)) {
        .opened => |opened| opened,
        .missing => return,
        .rejected => {
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .unreadable);
            return;
        },
    };
    defer file.close(io_mod.getIo());

    if (!try canonical_skill_paths.remember(alloc, candidate_path)) return;

    const inspection = try inspectSkillCandidateFile(alloc, &file, entry_name);
    const candidate = switch (inspection) {
        .valid => |value| value,
        .invalid => |cause| {
            if (diagnostics) |items| {
                try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .{ .invalid_metadata = cause });
            }
            return;
        },
        .unreadable => {
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .unreadable);
            return;
        },
        .oversized => {
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .oversized);
            return;
        },
    };
    defer candidate.deinit(alloc);

    const skill_name = try alloc.dupe(u8, candidate.metadata.name);
    errdefer alloc.free(skill_name);
    const description = try alloc.alloc(u8, candidate.metadata.description_len());
    errdefer alloc.free(description);
    candidate.metadata.write_description(description);
    const path = try alloc.dupe(u8, candidate_path);
    errdefer alloc.free(path);
    const read_authority = if (root.read_authority) |authority|
        try alloc.dupe(u8, authority)
    else
        null;
    errdefer if (read_authority) |authority| alloc.free(authority);

    try skills.append(alloc, .{
        .name = skill_name,
        .description = description,
        .path = path,
        .source = root.source,
        .read_authority = read_authority,
    });
}

const CurrentSkillMetadata = struct {
    content: []u8,
    metadata: skill_contract.SkillMetadata,

    fn deinit(self: CurrentSkillMetadata, alloc: Allocator) void {
        alloc.free(self.content);
    }
};

const SkillCandidateInspection = union(enum) {
    valid: CurrentSkillMetadata,
    invalid: skill_contract.InvalidMetadataCause,
    unreadable,
    oversized,
};

fn inspectSkillCandidateFile(
    alloc: Allocator,
    file: *std.Io.File,
    fallback_name: []const u8,
) error{OutOfMemory}!SkillCandidateInspection {
    const stat = file.stat(io_mod.getIo()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .unreadable;
    };
    if (stat.kind != .file) return .unreadable;
    const file_size = std.math.cast(usize, stat.size) orelse return .oversized;
    const content = skill_contract.readMetadataPrefix(alloc, file, file_size) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return if (err == error.StreamTooLong) .oversized else .unreadable;
    };
    errdefer alloc.free(content);

    const parsed = skill_contract.parseSkillFile(content);
    const metadata = switch (skill_contract.resolveMetadata(parsed, fallback_name)) {
        .valid => |value| value,
        .invalid => |cause| {
            alloc.free(content);
            return .{ .invalid = cause };
        },
    };
    return .{ .valid = .{ .content = content, .metadata = metadata } };
}

/// Opens and validates the exact advertised candidate without rescanning skill roots.
/// The caller must deinitialize a `.current` candidate.
pub fn openValidatedSkillCandidate(alloc: Allocator, skill: Skill) error{OutOfMemory}!SkillCandidateOpenResult {
    const candidate_name = std.fs.path.basename(skill.path);
    if (candidate_name.len == 0) return .{ .skipped = .unreadable };

    var candidate_dir = if (skill.read_authority) |read_authority| authorized: {
        break :authorized openContainedDir(alloc, skill.path, read_authority, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return if (err == error.FileNotFound) .missing else .{ .skipped = .unreadable };
        };
    } else strict: {
        const parent_path = std.fs.path.dirname(skill.path) orelse return .{ .skipped = .unreadable };
        var parent_dir = io_mod.openDirAbsoluteNoFollow(parent_path, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return if (err == error.FileNotFound) .missing else .{ .skipped = .unreadable };
        };
        defer parent_dir.close(io_mod.getIo());
        break :strict parent_dir.openDir(io_mod.getIo(), candidate_name, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return if (err == error.FileNotFound) .missing else .{ .skipped = .unreadable };
        };
    };
    const primary_file = openPrimarySkillFile(alloc, &candidate_dir, skill.read_authority) catch |err| {
        candidate_dir.close(io_mod.getIo());
        return err;
    };
    var file = switch (primary_file) {
        .opened => |opened| opened,
        .missing => {
            candidate_dir.close(io_mod.getIo());
            return .missing;
        },
        .rejected => {
            candidate_dir.close(io_mod.getIo());
            return .{ .skipped = .unreadable };
        },
    };
    var keep_open = false;
    defer if (!keep_open) {
        file.close(io_mod.getIo());
        candidate_dir.close(io_mod.getIo());
    };

    const inspection = try inspectSkillCandidateFile(alloc, &file, candidate_name);
    return switch (inspection) {
        .valid => |candidate| blk: {
            defer candidate.deinit(alloc);
            if (!std.mem.eql(u8, candidate.metadata.name, skill.name)) break :blk .name_mismatch;
            keep_open = true;
            break :blk .{ .current = .{
                .dir = candidate_dir,
                .skill_file = file,
            } };
        },
        .invalid => |cause| .{ .skipped = .{ .invalid_metadata = cause } },
        .unreadable => .{ .skipped = .unreadable },
        .oversized => .{ .skipped = .oversized },
    };
}

fn appendSkillDiagnostic(
    alloc: Allocator,
    diagnostics: *std.ArrayList(SkillDiagnostic),
    path: []const u8,
    source: SkillSource,
    scope: SkillDiagnosticScope,
    cause: SkillDiagnosticCause,
) !void {
    const owned_path = try alloc.dupe(u8, path);
    diagnostics.append(alloc, .{
        .path = owned_path,
        .source = source,
        .scope = scope,
        .cause = cause,
    }) catch |err| {
        alloc.free(owned_path);
        return err;
    };
}

pub fn findSkillByName(skills: []const Skill, name: []const u8) ?Skill {
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

pub fn resolveSkill(skills: []const Skill, name: []const u8, location: ?[]const u8) SkillResolution {
    if (location) |exact_location| {
        for (skills, 0..) |skill, index| {
            if (!std.mem.eql(u8, skill.path, exact_location)) continue;
            if (!std.mem.eql(u8, skill.name, name)) return .name_location_mismatch;
            return .{ .found = &skills[index] };
        }
        return .not_found;
    }

    var found_index: ?usize = null;
    for (skills, 0..) |skill, index| {
        if (!std.mem.eql(u8, skill.name, name)) continue;
        if (found_index != null) return .ambiguous_name;
        found_index = index;
    }
    return if (found_index) |index| .{ .found = &skills[index] } else .not_found;
}

pub fn isManagedInstallSkill(skill: Skill) bool {
    return skill.source == .global_fx;
}

pub fn skillGroupLabel(source: SkillSource) []const u8 {
    return switch (source) {
        .global_fx => "Managed installs",
        .workspace_fx => "Workspace skills",
        .workspace_shared => "Workspace skills",
        .workspace_opencode,
        .workspace_codex,
        .workspace_claude,
        .workspace_agents,
        .workspace_claw,
        .global_opencode,
        .global_codex,
        .global_claude,
        .global_agents,
        .global_claw,
        => "Compatibility roots",
    };
}

pub fn skillGroupRank(source: SkillSource) usize {
    return switch (source) {
        .global_fx => 0,
        .workspace_fx => 1,
        .workspace_shared => 1,
        .workspace_opencode,
        .workspace_codex,
        .workspace_claude,
        .workspace_agents,
        .workspace_claw,
        .global_opencode,
        .global_codex,
        .global_claude,
        .global_agents,
        .global_claw,
        => 2,
    };
}

const skill_group_count: usize = 3;

pub fn skillSourceLabel(source: SkillSource) []const u8 {
    return switch (source) {
        .workspace_fx => "workspace .fx/skills",
        .workspace_shared => "workspace skills/",
        .workspace_opencode => "workspace .opencode/skills",
        .workspace_codex => "workspace .codex/skills",
        .workspace_claude => "workspace .claude/skills",
        .workspace_agents => "workspace .agents/skills",
        .workspace_claw => "workspace .claw/skills",
        .global_fx => "global ~/.fx/skills",
        .global_opencode => "global ~/.config/opencode/skills",
        .global_codex => "global ~/.codex/skills",
        .global_claude => "global ~/.claude/skills",
        .global_agents => "global ~/.agents/skills",
        .global_claw => "global ~/.claw/skills",
    };
}

pub fn skillSourceShortLabel(source: SkillSource) []const u8 {
    return switch (source) {
        .workspace_fx => "workspace .fx",
        .workspace_shared => "workspace skills/",
        .workspace_opencode => "workspace .opencode",
        .workspace_codex => "workspace .codex",
        .workspace_claude => "workspace .claude",
        .workspace_agents => "workspace .agents",
        .workspace_claw => "workspace .claw",
        .global_fx => "global .fx",
        .global_opencode => "global opencode",
        .global_codex => "global .codex",
        .global_claude => "global .claude",
        .global_agents => "global .agents",
        .global_claw => "global .claw",
    };
}

pub fn skillMenuFilterLabel(filter: SkillMenuSourceFilter) []const u8 {
    return switch (filter) {
        .all => "All",
        .fx => "fx",
        .workspace => "Workspace",
        .opencode => "OpenCode",
        .codex => "Codex",
        .claude => "Claude",
        .agents => "Agents",
        .claw => "Claw",
    };
}

pub fn skillMenuFilterForSource(source: SkillSource) SkillMenuSourceFilter {
    return switch (source) {
        .global_fx => .fx,
        .workspace_fx => .fx,
        .workspace_shared => .workspace,
        .workspace_opencode, .global_opencode => .opencode,
        .workspace_codex, .global_codex => .codex,
        .workspace_claude, .global_claude => .claude,
        .workspace_agents, .global_agents => .agents,
        .workspace_claw, .global_claw => .claw,
    };
}

pub fn skillSourceMatchesFilter(source: SkillSource, filter: SkillMenuSourceFilter) bool {
    return filter == .all or skillMenuFilterForSource(source) == filter;
}

pub fn skill_matches_menu_query(skill: Skill, query: []const u8) bool {
    return skillMatchRank(skill, query) != null;
}

pub fn skillDisplaySource(skills: []const Skill, selected: Skill) ?SkillSource {
    var matching_names: usize = 0;
    for (skills) |skill| {
        if (!std.mem.eql(u8, skill.name, selected.name)) continue;
        matching_names += 1;
        if (matching_names > 1) return selected.source;
    }
    return null;
}

pub fn skillMenuFilterCount(skills: []const Skill, filter: SkillMenuSourceFilter) usize {
    return skillMenuFilterQueryCount(skills, filter, "");
}

pub fn skillMenuFilterQueryCount(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8) usize {
    var count: usize = 0;
    var it = SkillMenuView.init(skills, filter, query);
    while (it.next()) |_| {
        count += 1;
    }
    return count;
}

pub fn skillMenuActualIndexAt(skills: []const Skill, filter: SkillMenuSourceFilter, display_index: usize) ?usize {
    return skillMenuActualIndexAtQuery(skills, filter, "", display_index);
}

pub fn skillMenuActualIndexAtQuery(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8, display_index: usize) ?usize {
    var it = SkillMenuView.init(skills, filter, query);
    while (it.next()) |entry| {
        if (entry.display_index == display_index) return entry.actual_index;
    }
    return null;
}

pub fn skillMenuDisplayIndexForActual(skills: []const Skill, filter: SkillMenuSourceFilter, wanted_actual_index: usize) ?usize {
    return skillMenuDisplayIndexForActualQuery(skills, filter, "", wanted_actual_index);
}

pub fn skillMenuDisplayIndexForActualQuery(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8, wanted_actual_index: usize) ?usize {
    var it = SkillMenuView.init(skills, filter, query);
    while (it.next()) |entry| {
        if (entry.actual_index == wanted_actual_index) return entry.display_index;
    }
    return null;
}

pub fn skillMenuSkillAt(skills: []const Skill, filter: SkillMenuSourceFilter, display_index: usize) ?Skill {
    return skillMenuSkillAtQuery(skills, filter, "", display_index);
}

pub fn skillMenuSkillAtQuery(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8, display_index: usize) ?Skill {
    const actual_index = skillMenuActualIndexAtQuery(skills, filter, query, display_index) orelse return null;
    return skills[actual_index];
}

pub fn fillSkillMenuRangeAtQuery(
    skills: []const Skill,
    filter: SkillMenuSourceFilter,
    query: []const u8,
    first_display_index: usize,
    out: []*const Skill,
) usize {
    var written: usize = 0;
    var it = SkillMenuView.init(skills, filter, query);
    while (it.next()) |entry| {
        if (entry.display_index < first_display_index) continue;
        if (written == out.len) break;
        out[written] = &skills[entry.actual_index];
        written += 1;
    }
    return written;
}

const SkillMenuViewEntry = struct {
    display_index: usize,
    actual_index: usize,
};

const SkillMenuView = struct {
    skills: []const Skill,
    filter: SkillMenuSourceFilter,
    query: []const u8,
    match_rank: usize = 0,
    source_rank: usize = 0,
    next_actual_index: usize = 0,
    next_display_index: usize = 0,

    fn init(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8) SkillMenuView {
        return .{
            .skills = skills,
            .filter = filter,
            .query = query,
        };
    }

    fn next(self: *SkillMenuView) ?SkillMenuViewEntry {
        while (self.match_rank < skill_match_rank_count) {
            while (self.next_actual_index < self.skills.len) {
                const actual_index = self.next_actual_index;
                self.next_actual_index += 1;

                const skill = self.skills[actual_index];
                if (skillMatchRank(skill, self.query) != self.match_rank) continue;
                if (skillGroupRank(skill.source) != self.source_rank) continue;
                if (!skillSourceMatchesFilter(skill.source, self.filter)) continue;

                const display_index = self.next_display_index;
                self.next_display_index += 1;
                return .{
                    .display_index = display_index,
                    .actual_index = actual_index,
                };
            }

            self.source_rank += 1;
            if (self.source_rank == skill_group_count) {
                self.source_rank = 0;
                self.match_rank += 1;
            }
            self.next_actual_index = 0;
        }

        return null;
    }
};

const skill_match_rank_count: usize = 3;

fn skillMatchRank(skill: Skill, query: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, query, " \t\r\n/");
    if (trimmed.len == 0) return 0;
    if (std.ascii.startsWithIgnoreCase(skill.name, trimmed)) return 0;
    if (asciiContainsIgnoreCase(skill.name, trimmed)) return 1;
    if (asciiContainsIgnoreCase(skill.description, trimmed) or
        asciiContainsIgnoreCase(skillSourceShortLabel(skill.source), trimmed) or
        asciiContainsIgnoreCase(skill.path, trimmed))
    {
        return 2;
    }
    return null;
}

pub const SkillNameCompletion = struct {
    skill: Skill,
    suffix: []const u8,
};

pub fn firstSkillNameCompletion(skills: []const Skill, query: []const u8) ?SkillNameCompletion {
    if (query.len == 0) return null;
    for (skills) |skill| {
        if (skill.name.len <= query.len) continue;
        if (!std.ascii.startsWithIgnoreCase(skill.name, query)) continue;
        return .{
            .skill = skill,
            .suffix = skill.name[query.len..],
        };
    }
    return null;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) break;
        }
        if (i == needle.len) return true;
    }
    return false;
}

pub const SkillMenu = struct {
    active: bool = false,
    source_filter: SkillMenuSourceFilter = .all,
    selected_index: usize = 0,
    window_start: usize = 0,
    origin: SkillMenuOrigin = .command,
    target: ?SkillMenuTarget = null,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    pub fn open(self: *SkillMenu, items: []const Skill) void {
        self.openWithQuery(items, .command, null, "");
    }

    pub fn openWithQuery(self: *SkillMenu, items: []const Skill, origin: SkillMenuOrigin, target: ?SkillMenuTarget, query_text: []const u8) void {
        self.active = true;
        self.source_filter = .all;
        self.origin = origin;
        self.target = target;
        self.setQuery(query_text);
        self.clamp(items);
    }

    pub fn openFocused(self: *SkillMenu, items: []const Skill, filter: SkillMenuSourceFilter, index: usize) void {
        self.active = true;
        self.source_filter = filter;
        self.origin = .command;
        self.target = null;
        self.setQuery("");
        const item_count = self.filteredItemCount(items);
        self.selected_index = if (item_count == 0) 0 else @min(index, item_count - 1);
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            skill_menu_max_visible_rows,
        );
    }

    pub fn close(self: *SkillMenu) void {
        self.* = .{};
    }

    pub fn query(self: *const SkillMenu) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *SkillMenu, query_text: []const u8) void {
        const len = @min(query_text.len, self.query_buf.len);
        if (len > 0) std.mem.copyForwards(u8, self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
    }

    pub fn move(self: *SkillMenu, items: []const Skill, delta: i32) bool {
        return self.moveVisibleRows(items, delta, skill_menu_max_visible_rows);
    }

    pub fn moveVisibleRows(self: *SkillMenu, items: []const Skill, delta: i32, visible_rows: u16) bool {
        const item_count = self.filteredItemCount(items);
        if (!self.active or item_count == 0) return false;
        const max_rows: u16 = @max(visible_rows, 1);
        // Clamp at both ends instead of wrapping: at the top the selection
        // stays on the first skill, at the bottom on the last.
        const current: i32 = @intCast(self.selected_index % item_count);
        var next = current + delta;
        if (next < 0) next = 0;
        if (next >= @as(i32, @intCast(item_count))) next = @as(i32, @intCast(item_count)) - 1;
        self.selected_index = @intCast(next);
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            max_rows,
        );
        return true;
    }

    pub fn moveSourceFilter(self: *SkillMenu, items: []const Skill, delta: i32) bool {
        if (!self.active) return false;
        const count = skill_menu_source_filters.len;
        const current = skillMenuSourceFilterIndex(self.source_filter);
        var next = @as(i32, @intCast(current)) + delta;
        if (next < 0) next = @as(i32, @intCast(count)) - 1;
        if (next >= @as(i32, @intCast(count))) next = 0;
        self.source_filter = skill_menu_source_filters[@intCast(next)];
        self.selected_index = 0;
        self.window_start = 0;
        self.clamp(items);
        return true;
    }

    pub fn clamp(self: *SkillMenu, items: []const Skill) void {
        const item_count = self.filteredItemCount(items);
        if (item_count == 0) {
            self.selected_index = 0;
            self.window_start = 0;
            return;
        }
        if (self.selected_index >= item_count) self.selected_index = item_count - 1;
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            skill_menu_max_visible_rows,
        );
    }

    pub fn filteredItemCount(self: SkillMenu, items: []const Skill) usize {
        return skillMenuFilterQueryCount(items, self.source_filter, self.query());
    }
};

fn skillMenuSourceFilterIndex(filter: SkillMenuSourceFilter) usize {
    for (skill_menu_source_filters, 0..) |candidate, index| {
        if (candidate == filter) return index;
    }
    return 0;
}

pub const Runtime = struct {
    dir: []u8 = &.{},
    items: []Skill = &.{},
    diagnostics: []SkillDiagnostic = &.{},
    menu: SkillMenu = .{},

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.freeLoaded(alloc);
        self.menu.close();
    }

    fn freeLoaded(self: *Runtime, alloc: Allocator) void {
        if (self.dir.len > 0) alloc.free(self.dir);
        freeSkills(alloc, self.items);
        freeSkillDiagnostics(alloc, self.diagnostics);
        self.dir = &.{};
        self.items = &.{};
        self.diagnostics = &.{};
    }

    pub fn replaceLoaded(self: *Runtime, alloc: Allocator, dir: []u8, skills: []Skill, diagnostics: []SkillDiagnostic) void {
        self.freeLoaded(alloc);
        self.dir = dir;
        self.items = skills;
        self.diagnostics = diagnostics;
        self.menu.clamp(self.items);
    }

    pub fn openMenu(self: *Runtime) void {
        self.menu.open(self.items);
    }

    pub fn openMenuWithQuery(self: *Runtime, origin: SkillMenuOrigin, target: ?SkillMenuTarget, query: []const u8) void {
        self.menu.openWithQuery(self.items, origin, target, query);
    }

    pub fn openMenuFocusedByName(self: *Runtime, name: []const u8) bool {
        var matched_index: ?usize = null;
        for (self.items, 0..) |skill, actual_index| {
            if (!std.mem.eql(u8, skill.name, name)) continue;
            if (matched_index != null) return false;
            matched_index = actual_index;
        }
        const actual_index = matched_index orelse return false;
        const skill = self.items[actual_index];
        const filter = skillMenuFilterForSource(skill.source);
        const display_index = skillMenuDisplayIndexForActual(self.items, filter, actual_index) orelse return false;
        self.menu.openFocused(self.items, filter, display_index);
        return true;
    }

    pub fn closeMenu(self: *Runtime) void {
        self.menu.close();
    }

    pub fn moveMenuSelection(self: *Runtime, delta: i32) bool {
        return self.menu.move(self.items, delta);
    }

    pub fn moveMenuSelectionVisibleRows(self: *Runtime, delta: i32, visible_rows: u16) bool {
        return self.menu.moveVisibleRows(self.items, delta, visible_rows);
    }

    pub fn moveMenuSourceFilter(self: *Runtime, delta: i32) bool {
        return self.menu.moveSourceFilter(self.items, delta);
    }

    pub fn selectedMenuSkill(self: Runtime) ?Skill {
        if (!self.menu.active) return null;
        const item_count = self.menu.filteredItemCount(self.items);
        if (item_count == 0) return null;
        return skillMenuSkillAtQuery(self.items, self.menu.source_filter, self.menu.query(), self.menu.selected_index % item_count);
    }

    pub fn buildBoundedSystemPromptSection(self: Runtime, alloc: Allocator, limits: context_limits.Values) !BoundedPromptSection {
        var section = try buildSkillsSystemPromptSectionWithLimits(alloc, self.items, limits);
        errdefer section.deinit(alloc);
        if (self.diagnostics.len == 0) return section;

        var candidate_count: usize = 0;
        var root_count: usize = 0;
        for (self.diagnostics) |diagnostic| switch (diagnostic.scope) {
            .candidate => candidate_count += 1,
            .root => root_count += 1,
        };
        const marker = try std.fmt.allocPrint(
            alloc,
            "<skill_discovery_warning skipped_candidate_count=\"{d}\" incomplete_root_count=\"{d}\" missing_from_incomplete_roots=\"{s}\" />\n",
            .{ candidate_count, root_count, if (root_count > 0) "unknown" else "0" },
        );
        defer alloc.free(marker);
        const marked_text = try std.mem.concat(alloc, u8, &.{ marker, section.text });
        alloc.free(section.text);
        section.text = marked_text;

        var diagnostic_notice: std.Io.Writer.Allocating = .init(alloc);
        defer diagnostic_notice.deinit();
        try writeDiagnosticSummary(alloc, &diagnostic_notice.writer, self.diagnostics);
        section.diagnostic_notice = try diagnostic_notice.toOwnedSlice();
        return section;
    }
};

pub fn matchExplicitSkillIndices(alloc: Allocator, prompt: []const u8, skills: []const Skill) ![]usize {
    const trimmed = std.mem.trimStart(u8, prompt, " \t\r\n");
    const leading_sigil: ?u8 = if (trimmed.len > 0 and (trimmed[0] == '/' or trimmed[0] == '$')) trimmed[0] else null;
    var natural_reference = try parseNaturalLanguageSkillReference(alloc, prompt);
    defer if (natural_reference) |*reference| reference.deinit(alloc);

    var name_counts = std.StringHashMap(usize).init(alloc);
    defer name_counts.deinit();
    for (skills) |skill| {
        const entry = try name_counts.getOrPut(skill.name);
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 1;
        }
    }

    var matched: std.ArrayList(usize) = .empty;
    defer matched.deinit(alloc);
    for (skills, 0..) |skill, index| {
        if (name_counts.get(skill.name).? != 1) continue;
        const sigil_referenced = if (leading_sigil) |sigil|
            matchesSigilSkillAt(trimmed, 0, skill.name, sigil)
        else
            false;
        const natural_referenced = if (natural_reference) |reference|
            reference.matchesSkillName(skill.name)
        else
            false;
        if (!sigil_referenced and !natural_referenced) continue;
        try matched.append(alloc, index);
    }
    return try matched.toOwnedSlice(alloc);
}

const NaturalLanguageSkillReference = struct {
    normalized_prompt: []u8,
    name_starts: [2]usize,
    name_start_count: usize,

    fn deinit(self: *NaturalLanguageSkillReference, alloc: Allocator) void {
        alloc.free(self.normalized_prompt);
        self.* = undefined;
    }

    fn matchesSkillName(self: NaturalLanguageSkillReference, skill_name: []const u8) bool {
        for (self.name_starts[0..self.name_start_count]) |name_start| {
            var search_start = name_start;
            while (std.mem.find(u8, self.normalized_prompt[search_start..], " skill")) |relative_marker_start| {
                const marker_start = search_start + relative_marker_start;
                const reference_end = marker_start + " skill".len;
                const has_boundary = reference_end == self.normalized_prompt.len or self.normalized_prompt[reference_end] == ' ';
                if (has_boundary and marker_start > name_start and
                    normalizedReferenceTextEql(skill_name, self.normalized_prompt[name_start..marker_start]))
                {
                    return true;
                }
                search_start = marker_start + 1;
            }
        }
        return false;
    }
};

fn parseNaturalLanguageSkillReference(alloc: Allocator, prompt: []const u8) !?NaturalLanguageSkillReference {
    const reference_start = naturalLanguageReferenceStart(prompt) orelse return null;
    const normalized_prompt = try normalizeReferenceText(alloc, reference_start);
    const name_start = naturalLanguageSkillNameStart(normalized_prompt) orelse {
        alloc.free(normalized_prompt);
        return null;
    };

    var reference: NaturalLanguageSkillReference = .{
        .normalized_prompt = normalized_prompt,
        .name_starts = .{ name_start, undefined },
        .name_start_count = 1,
    };
    if (std.mem.startsWith(u8, normalized_prompt[name_start..], "the ")) {
        reference.name_starts[1] = name_start + "the ".len;
        reference.name_start_count = 2;
    }
    return reference;
}

fn naturalLanguageSkillNameStart(normalized_prompt: []const u8) ?usize {
    for ([_][]const u8{ "use", "apply", "activate", "invoke", "run" }) |verb| {
        if (!std.mem.startsWith(u8, normalized_prompt, verb)) continue;
        if (normalized_prompt.len <= verb.len or normalized_prompt[verb.len] != ' ') continue;
        return verb.len + 1;
    }
    return null;
}

fn naturalLanguageReferenceStart(prompt: []const u8) ?[]const u8 {
    var text = std.mem.trimStart(u8, prompt, " \t\r\n");
    if (text.len >= "please".len and
        asciiEqlIgnoreCase(text[0.."please".len], "please") and
        (text.len == "please".len or !std.ascii.isAlphanumeric(text["please".len])))
    {
        text = std.mem.trimStart(u8, text["please".len..], " \t\r\n,:");
    }
    if (text.len == 0 or text[0] == '"' or text[0] == '\'' or text[0] == '`') return null;
    if (std.mem.startsWith(u8, text, "“") or std.mem.startsWith(u8, text, "‘")) return null;
    return text;
}

fn matchesSigilSkillAt(text: []const u8, index: usize, skill_name: []const u8, sigil: u8) bool {
    if (index >= text.len or text[index] != sigil) return false;
    const name_start = index + 1;
    if (text.len - name_start < skill_name.len) return false;
    if (!asciiEqlIgnoreCase(text[name_start .. name_start + skill_name.len], skill_name)) return false;
    const end = name_start + skill_name.len;
    return end == text.len or !isSkillNameContinuation(text[end]);
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        if (std.ascii.toLower(a_byte) != std.ascii.toLower(b_byte)) return false;
    }
    return true;
}

fn isSkillNameContinuation(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn normalizedReferenceTextEql(text: []const u8, normalized: []const u8) bool {
    var normalized_index: usize = 0;
    var pending_space = false;
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            if (pending_space and normalized_index > 0) {
                if (normalized_index >= normalized.len or normalized[normalized_index] != ' ') return false;
                normalized_index += 1;
            }
            if (normalized_index >= normalized.len or normalized[normalized_index] != std.ascii.toLower(char)) return false;
            normalized_index += 1;
            pending_space = false;
        } else if (normalized_index > 0) {
            pending_space = true;
        }
    }
    return normalized_index == normalized.len;
}

fn normalizeReferenceText(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var previous_was_space = true;
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try out.append(alloc, std.ascii.toLower(char));
            previous_was_space = false;
        } else if (!previous_was_space) {
            try out.append(alloc, ' ');
            previous_was_space = true;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return try out.toOwnedSlice(alloc);
}

pub fn listSkillsSummary(alloc: Allocator, skills: []const Skill) ![]u8 {
    return listSkillsSummaryStyled(alloc, skills, .{});
}

pub fn listSkillsSummaryStyled(alloc: Allocator, skills: []const Skill, styles: SkillSummaryStyles) ![]u8 {
    if (skills.len == 0) {
        return alloc.dupe(u8, "No skills available.\n");
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const group_order = [_][]const u8{
        "Managed installs",
        "Workspace skills",
        "Compatibility roots",
    };

    try out.writer.print("Visible skills ({d}):\n", .{skills.len});
    for (group_order) |group| {
        var count: usize = 0;
        for (skills) |skill| {
            if (std.mem.eql(u8, skillGroupLabel(skill.source), group)) count += 1;
        }
        if (count == 0) continue;

        try out.writer.print("\n{s} ({d}):\n", .{ group, count });
        for (skills) |skill| {
            if (!std.mem.eql(u8, skillGroupLabel(skill.source), group)) continue;
            if (skill.description.len > 0) {
                try out.writer.print("  - {s}: {s} ", .{ skill.name, skill.description });
            } else {
                try out.writer.print("  - {s} ", .{skill.name});
            }
            try writeStyledSourceLabel(&out.writer, styles, skillSourceLabel(skill.source));
            try out.writer.writeByte('\n');
        }
    }

    return try out.toOwnedSlice();
}

fn writeStyledSourceLabel(writer: *std.Io.Writer, styles: SkillSummaryStyles, label: []const u8) !void {
    if (styles.source_label_style.len == 0) {
        try writer.print("[{s}]", .{label});
        return;
    }
    try writer.print("{s}[{s}]{s}", .{ styles.source_label_style, label, styles.reset_style });
}

pub fn buildSkillsSystemPromptSectionWithLimits(
    alloc: Allocator,
    all_skills: []const Skill,
    limits: context_limits.Values,
) !BoundedPromptSection {
    if (all_skills.len == 0) return .{ .text = try alloc.dupe(u8, "") };

    const header =
        "\n\nSkills provide specialized instructions and workflows for specific tasks.\n" ++
        "Use the skill tool to load a skill when a task matches its description.\n" ++
        "Do not assume a skill is loaded just because it is available. Load it first when it seems relevant.\n" ++
        "<available_skills>\n";
    const footer = "</available_skills>\n";
    const Entry = struct {
        text: []u8,
        description_observed: usize,
    };
    const entries = try alloc.alloc(Entry, all_skills.len);
    defer alloc.free(entries);
    var initialized: usize = 0;
    defer for (entries[0..initialized]) |entry| alloc.free(entry.text);

    const description_limit = limits.skill_description_bytes;
    var observed_catalog_bytes = header.len + footer.len;
    for (all_skills, 0..) |skill, index| {
        var entry: std.Io.Writer.Allocating = .init(alloc);
        defer entry.deinit();
        try entry.writer.writeAll("  <skill>\n");
        try entry.writer.writeAll("    <name>");
        try model_context_encoding.writeScalar(&entry.writer, skill.name);
        try entry.writer.writeAll("</name>\n    <description>");
        const description_observed = try writeBoundedEncodedScalar(
            alloc,
            &entry.writer,
            skill.description,
            description_limit.effectiveBytes(),
        );
        if (description_observed > description_limit.effectiveBytes()) {
            try entry.writer.print(
                "<context_limit name=\"skill_description_bytes\" action=\"truncated\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" override=\"--context-limit skill_description_bytes=BYTES|off\" />",
                .{ description_observed, description_limit.effectiveBytes(), description_limit.source.label() },
            );
        }
        try entry.writer.writeAll("</description>\n    <location>");
        try model_context_encoding.writeScalar(&entry.writer, skill.path);
        try entry.writer.writeAll("</location>\n");
        try entry.writer.writeAll("  </skill>\n");
        entries[index] = .{
            .text = try entry.toOwnedSlice(),
            .description_observed = description_observed,
        };
        initialized += 1;
        observed_catalog_bytes += entries[index].text.len;
    }

    const catalog_limit = limits.skill_catalog_bytes;
    const effective_limit = catalog_limit.effectiveBytes();
    var retained_count = all_skills.len;
    var marker: ?[]u8 = null;
    defer if (marker) |value| alloc.free(value);
    if (observed_catalog_bytes > effective_limit) {
        retained_count = 0;
        var retained_entry_bytes: usize = 0;
        for (0..all_skills.len + 1) |candidate_count| {
            if (marker) |value| {
                alloc.free(value);
                marker = null;
            }
            marker = try std.fmt.allocPrint(
                alloc,
                "  <context_limit name=\"skill_catalog_bytes\" action=\"omitted\" omitted_count=\"{d}\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" override=\"--context-limit skill_catalog_bytes=BYTES|off\" />\n",
                .{ all_skills.len - candidate_count, observed_catalog_bytes, effective_limit, catalog_limit.source.label() },
            );
            if (header.len + retained_entry_bytes + marker.?.len + footer.len <= effective_limit) {
                retained_count = candidate_count;
            } else break;
            if (candidate_count < all_skills.len) retained_entry_bytes += entries[candidate_count].text.len;
        }
        if (marker) |value| {
            alloc.free(value);
            marker = null;
        }
        marker = try std.fmt.allocPrint(
            alloc,
            "  <context_limit name=\"skill_catalog_bytes\" action=\"omitted\" omitted_count=\"{d}\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" override=\"--context-limit skill_catalog_bytes=BYTES|off\" />\n",
            .{ all_skills.len - retained_count, observed_catalog_bytes, effective_limit, catalog_limit.source.label() },
        );
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var notices: std.Io.Writer.Allocating = .init(alloc);
    defer notices.deinit();

    var retained_entry_bytes: usize = 0;
    for (entries[0..retained_count]) |entry| retained_entry_bytes += entry.text.len;
    const full_container_fits = marker == null or
        header.len + retained_entry_bytes + marker.?.len + footer.len <= effective_limit;
    if (full_container_fits) {
        try out.writer.writeAll(header);
        for (entries[0..retained_count]) |entry| try out.writer.writeAll(entry.text);
        if (marker) |value| try out.writer.writeAll(value);
        try out.writer.writeAll(footer);
    } else if (marker) |value| {
        try out.writer.writeAll(value);
    }

    for (all_skills[0..retained_count], entries[0..retained_count]) |skill, entry| {
        if (entry.description_observed <= description_limit.effectiveBytes()) continue;
        try notices.writer.writeAll("[context] skill description \"");
        try writeBoundedSkillName(alloc, &notices.writer, skill.name);
        try notices.writer.print(
            "\" truncated: observed={d} bytes effective={d} bytes source={s}; override with --context-limit skill_description_bytes=BYTES|off\n",
            .{ entry.description_observed, description_limit.effectiveBytes(), description_limit.source.label() },
        );
    }
    if (retained_count < all_skills.len) {
        const omitted = all_skills[retained_count..];
        const shown_count = @min(omitted.len, catalog_notice_name_count);
        try notices.writer.print("[context] skill catalog omitted {d} entries (", .{omitted.len});
        for (omitted[0..shown_count], 0..) |skill, relative_index| {
            if (relative_index > 0) try notices.writer.writeAll(", ");
            try writeBoundedSkillName(alloc, &notices.writer, skill.name);
        }
        if (shown_count < omitted.len) {
            if (shown_count > 0) try notices.writer.writeAll(", ");
            try notices.writer.print("+{d} more", .{omitted.len - shown_count});
        }
        try notices.writer.print(
            "): observed={d} bytes effective={d} bytes source={s}; override with --context-limit skill_catalog_bytes=BYTES|off\n",
            .{ observed_catalog_bytes, effective_limit, catalog_limit.source.label() },
        );
    }

    return .{
        .text = try out.toOwnedSlice(),
        .notice = if (notices.written().len > 0) try notices.toOwnedSlice() else null,
    };
}

fn writeBoundedSkillName(alloc: Allocator, writer: *std.Io.Writer, name: []const u8) !void {
    const observed = try writeBoundedEncodedScalar(alloc, writer, name, skill_contract.max_name_bytes);
    if (observed > skill_contract.max_name_bytes) try writer.writeAll("...");
}

fn writeBoundedEncodedScalar(alloc: Allocator, writer: *std.Io.Writer, value: []const u8, max_bytes: usize) !usize {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try model_context_encoding.writeScalar(&encoded.writer, value);
    const observed = encoded.written().len;
    var prefix_len = context_limits.utf8PrefixLength(encoded.written(), max_bytes);
    if (std.mem.lastIndexOfScalar(u8, encoded.written()[0..prefix_len], '&')) |amp_index| {
        if (std.mem.indexOfScalar(u8, encoded.written()[amp_index..prefix_len], ';') == null) {
            prefix_len = amp_index;
        }
    }
    try writer.writeAll(encoded.written()[0..prefix_len]);
    return observed;
}

pub fn freeSkill(alloc: Allocator, skill: Skill) void {
    alloc.free(skill.name);
    alloc.free(skill.description);
    alloc.free(skill.path);
    if (skill.read_authority) |read_authority| alloc.free(read_authority);
}

pub fn freeSkills(alloc: Allocator, skills: []Skill) void {
    for (skills) |skill| freeSkill(alloc, skill);
    if (skills.len == 0) return;
    alloc.free(skills);
}

pub fn freeSkillDiagnostics(alloc: Allocator, diagnostics: []SkillDiagnostic) void {
    for (diagnostics) |diagnostic| alloc.free(diagnostic.path);
    if (diagnostics.len == 0) return;
    alloc.free(diagnostics);
}

fn staticSkill(name: []const u8, description: []const u8, source: SkillSource) Skill {
    return .{
        .name = name,
        .description = description,
        .path = "",
        .source = source,
    };
}



const test_workspace_roots = [_]skill_contract.RootSpec{
    .{ .source = .workspace_shared, .path = "skills" },
    .{ .source = .workspace_codex, .path = ".codex/skills" },
    .{ .source = .workspace_agents, .path = ".agents/skills" },
};

const test_global_roots = [_]skill_contract.RootSpec{
    .{ .source = .global_codex, .path = ".codex/skills" },
    .{ .source = .global_agents, .path = ".agents/skills" },
};

const test_root_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &test_workspace_roots,
    .managed_root_source = .global_fx,
    .global_roots = &test_global_roots,
};

const test_managed_root_policy: skill_contract.RootPolicy = .{
    .managed_root_source = .global_fx,
};












fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn createTempSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    if (std.fs.path.dirname(link_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

fn createTempFifoOrSkip(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) {
        return error.SkipZigTest;
    }
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, sub_path });
    defer alloc.free(path);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    if (mkfifo(path_z, 0o600) != 0) return error.SkipZigTest;
}

fn openFileDescriptorCount() !usize {
    const path = switch (@import("builtin").os.tag) {
        .linux => "/proc/self/fd",
        .macos => "/dev/fd",
        else => return error.SkipZigTest,
    };
    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), path, .{ .iterate = true });
    defer dir.close(io_mod.getIo());
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |_| count += 1;
    return count;
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}


































fn checkContainedLinkedSkillAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    home_root: []const u8,
    managed_root: []const u8,
) !void {
    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expect(discovery.skills[0].read_authority != null);
}












fn checkLoadVisibleSkillsAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    home_root: []const u8,
    managed_root: []const u8,
) !void {
    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_managed_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
}


fn checkLinkedMetadataAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    home_root: []const u8,
    managed_root: []const u8,
) !void {
    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);

    var candidate = switch (try openValidatedSkillCandidate(alloc, discovery.skills[0])) {
        .current => |current| current,
        .missing, .name_mismatch, .skipped => return error.TestExpectedCurrentSkill,
    };
    candidate.deinit();
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

const TestEnviron = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator) !*TestEnviron {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestEnviron);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn put(self: *TestEnviron, key: []const u8, value: []const u8) !void {
        try self.map.put(key, value);
    }

    fn deinit(self: *TestEnviron) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};





