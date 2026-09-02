const std = @import("std");

const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const skill_commands = @import("../core/skills/skill_commands.zig");
const skill_contract = @import("../core/skills/skill_contract.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");

const Allocator = std.mem.Allocator;

const RootSpec = skill_contract.RootSpec;

/// Roots scanned at the workspace root and each ancestor directory below
/// home, in precedence order. `.fx/skills` and `skills/` belong to the product;
/// the rest are compatibility roots for other agent installs.
const workspace_roots = [_]RootSpec{
    .{ .source = .workspace_fx, .path = ".fx/skills" },
    .{ .source = .workspace_shared, .path = "skills" },
    .{ .source = .workspace_opencode, .path = ".opencode/skills" },
    .{ .source = .workspace_codex, .path = ".codex/skills" },
    .{ .source = .workspace_claude, .path = ".claude/skills" },
    .{ .source = .workspace_agents, .path = ".agents/skills" },
    .{ .source = .workspace_claw, .path = ".claw/skills" },
};

/// Home-relative compatibility roots scanned after the managed install root.
const global_roots = [_]RootSpec{
    .{ .source = .global_opencode, .path = ".config/opencode/skills" },
    .{ .source = .global_codex, .path = ".codex/skills" },
    .{ .source = .global_claude, .path = ".claude/skills" },
    .{ .source = .global_agents, .path = ".agents/skills" },
    .{ .source = .global_claw, .path = ".claw/skills" },
};

pub const root_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &workspace_roots,
    .managed_root_source = .global_fx,
    .global_roots = &global_roots,
};

pub fn loadVisibleSkillsForTool(
    alloc: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
) !skill_runtime.SkillDiscovery {
    const home = io_mod.getenv("HOME") orelse homeFromSkillsDir(skills_dir);
    return skill_runtime.loadVisibleSkills(
        alloc,
        workspace_root,
        home,
        skills_dir,
        root_policy,
    );
}

fn homeFromSkillsDir(skills_dir: []const u8) ?[]const u8 {
    const suffix = "/.fx/skills";
    if (!std.mem.endsWith(u8, skills_dir, suffix)) return null;
    return skills_dir[0 .. skills_dir.len - suffix.len];
}

pub const InstallResult = skill_commands.InstallResult;

const InstallRequest = struct {
    source: []u8,
    filter: ?[]u8,

    pub fn deinit(self: *InstallRequest, alloc: Allocator) void {
        alloc.free(self.source);
        if (self.filter) |value| alloc.free(value);
        self.* = undefined;
    }
};

const ParsedSource = struct {
    source: []const u8,
    filter: ?[]const u8 = null,
};

const clone_output_capture_limit: usize = 64 * 1024;

const SkillInfo = skill_commands.SkillInfo;
const CommandRequest = skill_commands.CommandRequest;
const InstallCommand = skill_commands.InstallCommand;
const Command = skill_commands.Command;
const CommandResult = skill_commands.CommandResult;

pub const command_provider = skill_commands.Provider{
    .parse_command_fn = parseCommand,
    .execute_command_fn = executeCommand,
};

fn parseCommand(rest: []const u8) Command {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "list")) return .list;
    if (std.mem.startsWith(u8, trimmed, "show ")) return .{ .show = std.mem.trim(u8, trimmed[5..], " \t") };
    if (std.mem.startsWith(u8, trimmed, "add ") or std.mem.startsWith(u8, trimmed, "install ")) {
        return .{ .install = parseInstallCommand(trimmed) };
    }
    if (std.mem.startsWith(u8, trimmed, "create ")) return .{ .create = std.mem.trim(u8, trimmed[7..], " \t") };
    if (std.mem.startsWith(u8, trimmed, "remove ")) return .{ .remove = std.mem.trim(u8, trimmed[7..], " \t") };
    if (std.mem.eql(u8, trimmed, "path")) return .path;
    return .usage;
}

fn parseInstallCommand(trimmed: []const u8) InstallCommand {
    const args_raw = if (std.mem.startsWith(u8, trimmed, "add "))
        std.mem.trim(u8, trimmed[4..], " \t")
    else
        std.mem.trim(u8, trimmed[8..], " \t");

    var source: []const u8 = args_raw;
    var filter: ?[]const u8 = null;

    if (std.mem.find(u8, args_raw, "--skill ")) |idx| {
        source = std.mem.trim(u8, args_raw[0..idx], " \t");
        filter = std.mem.trim(u8, args_raw[idx + 8 ..], " \t");
    } else if (std.mem.find(u8, args_raw, "--skill=")) |idx| {
        source = std.mem.trim(u8, args_raw[0..idx], " \t");
        filter = std.mem.trim(u8, args_raw[idx + 8 ..], " \t");
    }

    return .{ .source = source, .filter = filter };
}

fn executeCommand(alloc: Allocator, command: Command, request: CommandRequest) !CommandResult {
    return switch (command) {
        .list => .open_menu,
        .show => |name| focusSkillResult(alloc, name, request),
        .install => |install| installCommandResult(alloc, request.skills_dir, install),
        .create => |name| createCommandResult(alloc, request.skills_dir, name),
        .remove => |name| removeCommandResult(alloc, request, name),
        .path => noticeFmt(
            alloc,
            "fx workspace roots are auto-discovered from .fx/skills and skills/.\n" ++
                "fx managed install root: {s}\n" ++
                "compatibility roots are auto-discovered from workspace and home (.opencode/.codex/.claude/.agents/.claw).",
            .{request.skills_dir},
            false,
        ),
        .usage => noticeLiteral(alloc, "Usage: /skills [list|add|install|show|create|remove|path] [name|url|path]", false),
    };
}

fn focusSkillResult(alloc: Allocator, name: []const u8, request: CommandRequest) !CommandResult {
    if (request.find_skill(request.find_ctx, name) != null) {
        return .{ .focus_menu = try alloc.dupe(u8, name) };
    }
    return noticeFmt(alloc, "Skill '{s}' not found.", .{name}, false);
}

fn installCommandResult(alloc: Allocator, skills_dir: []const u8, install: InstallCommand) !CommandResult {
    var result = installFromSource(alloc, skills_dir, install.source, install.filter) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return noticeLiteral(alloc, "Failed to install. Check the source path or URL and try again.", false),
    };

    if (result.installed.items.len == 0) {
        result.deinit(alloc);
        if (install.filter) |filter| {
            return noticeFmt(alloc, "Skill '{s}' not found in the repository.", .{filter}, false);
        }
        return noticeLiteral(alloc, "No skills found (no SKILL.md files).", false);
    }

    return .{ .installed = result };
}

fn createCommandResult(alloc: Allocator, skills_dir: []const u8, name: []const u8) !CommandResult {
    const path = createSkillTemplate(alloc, skills_dir, name) catch |err| switch (err) {
        error.InvalidSkillName => return noticeLiteral(alloc, "Invalid skill name. Use a single directory name without '/' or '\\'.", false),
        else => return err,
    };
    defer alloc.free(path);
    return noticeFmt(alloc, "Created {s}", .{path}, true);
}

fn removeCommandResult(alloc: Allocator, request: CommandRequest, name: []const u8) !CommandResult {
    const skill = request.find_skill(request.find_ctx, name) orelse {
        return noticeFmt(alloc, "Skill '{s}' not found.", .{name}, false);
    };

    if (!skill.managed_install) {
        return noticeFmt(alloc, "Skill '{s}' comes from {s}, not the fx managed install root. Remove it from {s}.", .{ name, skill.source_label, skill.path }, false);
    }

    removeSkill(request.skills_dir, std.fs.path.basename(skill.path)) catch {
        return noticeFmt(alloc, "Failed to remove skill '{s}'.", .{name}, false);
    };
    return noticeFmt(alloc, "Removed skill '{s}'.", .{name}, true);
}

fn noticeLiteral(alloc: Allocator, text: []const u8, reload: bool) !CommandResult {
    return .{ .notice = .{ .text = try alloc.dupe(u8, text), .reload = reload } };
}

fn noticeFmt(alloc: Allocator, comptime fmt: []const u8, args: anytype, reload: bool) !CommandResult {
    return .{ .notice = .{ .text = try std.fmt.allocPrint(alloc, fmt, args), .reload = reload } };
}

pub fn installFromSource(alloc: Allocator, skills_dir: []const u8, source: []const u8, filter: ?[]const u8) !InstallResult {
    var request = try normalizeInstallRequest(alloc, source, filter);
    defer request.deinit(alloc);

    if (try installFromLocalDirectory(alloc, skills_dir, request.source, request.filter)) |result| {
        return result;
    }

    return installFromGitHub(alloc, skills_dir, request.source, request.filter);
}

fn normalizeInstallRequest(alloc: Allocator, raw_source: []const u8, explicit_filter: ?[]const u8) !InstallRequest {
    const trimmed = std.mem.trim(u8, raw_source, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidSkillInstallSource;

    const command_source = parseNpxInstallSource(trimmed) orelse ParsedSource{ .source = trimmed };
    const inline_source = parseInlineInstallSource(command_source.source);
    const merged_filter = try mergeInstallFilters(command_source.filter, inline_source.filter, explicit_filter);

    const source = try alloc.dupe(u8, inline_source.source);
    errdefer alloc.free(source);
    const filter = if (merged_filter) |value| try alloc.dupe(u8, value) else null;

    return .{
        .source = source,
        .filter = filter,
    };
}

pub fn looksLikeInstallCommand(input: []const u8) bool {
    return looksLikeSkillsInstallCommand(std.mem.trim(u8, input, " \t\r\n"));
}

pub fn removeSkill(skills_dir: []const u8, name: []const u8) !void {
    try skill_contract.validateManagedSkillName(name);

    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), skills_dir, .{});
    defer dir.close(io_mod.getIo());
    try dir.deleteTree(io_mod.getIo(), name);
}

pub fn createSkillTemplate(alloc: Allocator, skills_dir: []const u8, name: []const u8) ![]const u8 {
    try skill_contract.validateManagedSkillName(name);

    try io_mod.makeDirRecursive(skills_dir);

    const skill_dir = try std.fs.path.join(alloc, &.{ skills_dir, name });
    defer alloc.free(skill_dir);

    try io_mod.makeDirRecursive(skill_dir);

    const skill_file_path = try std.fs.path.join(alloc, &.{ skill_dir, "SKILL.md" });
    errdefer alloc.free(skill_file_path);

    const template = try std.fmt.allocPrint(alloc, "---\nname: {s}\ndescription: Describe when this skill should activate\n---\n\n# {s}\n\nInstructions for this skill...\n", .{ name, name });
    defer alloc.free(template);

    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), skill_file_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), template);

    return skill_file_path;
}

fn installFromGitHub(alloc: Allocator, skills_dir: []const u8, url: []const u8, filter: ?[]const u8) !InstallResult {
    try ensureDir(skills_dir);

    const tmp_dir = try std.fmt.allocPrint(alloc, "/tmp/fx-skill-install-{d}", .{io_mod.milliTimestamp()});
    defer alloc.free(tmp_dir);
    defer std.Io.Dir.cwd().deleteTree(io_mod.getIo(), tmp_dir) catch {};

    const git_url = try cloneUrlForSource(alloc, url);
    defer alloc.free(git_url);

    const argv = [_][]const u8{ "git", "clone", "--depth", "1", git_url, tmp_dir };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stderr = .pipe,
        .stdout = .pipe,
    });

    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) child.kill(io_mod.getIo());

    try drainCloneOutput(alloc, &child);
    const term = try child.wait(io_mod.getIo());
    child_needs_cleanup = false;

    switch (term) {
        .exited => |code| if (code != 0) return error.SkillInstallFailed,
        else => return error.SkillInstallFailed,
    }

    return installFromDirectory(alloc, skills_dir, tmp_dir, extractRepoName(url), filter);
}

fn installFromLocalDirectory(alloc: Allocator, skills_dir: []const u8, source: []const u8, filter: ?[]const u8) !?InstallResult {
    const source_dir = try resolveInstallDirectory(alloc, source) orelse return null;
    defer alloc.free(source_dir);
    return try installFromDirectory(alloc, skills_dir, source_dir, std.fs.path.basename(source_dir), filter);
}

fn installFromDirectory(alloc: Allocator, skills_dir: []const u8, source_dir: []const u8, fallback_name: []const u8, filter: ?[]const u8) !InstallResult {
    return installFromDirectoryWithMetadataReader(alloc, skills_dir, source_dir, fallback_name, filter, readInstallMetadataPrefix);
}

const InstallMetadataReadError = error{
    OutOfMemory,
    StreamTooLong,
    UnexpectedEndOfFile,
} || std.Io.File.StatError || std.Io.File.ReadPositionalError;

const InstallMetadataReader = *const fn (Allocator, *std.Io.File) InstallMetadataReadError!?[]u8;

fn installFromDirectoryWithMetadataReader(
    alloc: Allocator,
    skills_dir: []const u8,
    source_dir: []const u8,
    fallback_name: []const u8,
    filter: ?[]const u8,
    metadata_reader: InstallMetadataReader,
) !InstallResult {
    try ensureDir(skills_dir);

    var result = InstallResult{ .installed = .empty };
    errdefer result.deinit(alloc);

    var root_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), source_dir, .{ .iterate = true });
    defer root_dir.close(io_mod.getIo());

    var maybe_root_file = root_dir.openFile(io_mod.getIo(), "SKILL.md", .{ .follow_symlinks = false }) catch |err| blk: {
        try propagateInstallOpenError(err);
        break :blk null;
    };
    if (maybe_root_file) |*file| {
        defer file.close(io_mod.getIo());
        const maybe_root_content = metadata_reader(alloc, file) catch |err| blk: {
            try propagateInstallMetadataReadError(err);
            break :blk null;
        };
        if (maybe_root_content) |root_content| {
            defer alloc.free(root_content);
            const parsed = skill_contract.parseSkillFile(root_content);
            switch (skill_contract.resolveMetadata(parsed, fallback_name)) {
                .valid => |metadata| {
                    const destination_safe = blk: {
                        skill_contract.validateManagedSkillName(fallback_name) catch break :blk false;
                        break :blk true;
                    };
                    if (destination_safe and (filter == null or std.mem.eql(u8, filter.?, metadata.name) or std.mem.eql(u8, filter.?, fallback_name))) {
                        try copySkillDir(alloc, source_dir, skills_dir, fallback_name);
                        const installed_name = try alloc.dupe(u8, metadata.name);
                        errdefer alloc.free(installed_name);
                        try result.installed.append(alloc, installed_name);
                    }
                },
                .invalid => {},
            }
        }
    }

    var walker = try root_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "SKILL.md")) continue;

        const parent_path = std.fs.path.dirname(entry.path) orelse continue;
        const dir_name = std.fs.path.basename(parent_path);
        if (std.mem.startsWith(u8, dir_name, ".")) continue;
        skill_contract.validateManagedSkillName(dir_name) catch continue;

        const skill_file = try std.fs.path.join(alloc, &.{ source_dir, entry.path });
        defer alloc.free(skill_file);

        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), skill_file, .{}) catch |err| {
            try propagateInstallOpenError(err);
            continue;
        };
        defer file.close(io_mod.getIo());
        const content = metadata_reader(alloc, &file) catch |err| {
            try propagateInstallMetadataReadError(err);
            continue;
        } orelse continue;
        defer alloc.free(content);

        const parsed = skill_contract.parseSkillFile(content);
        const metadata = switch (skill_contract.resolveMetadata(parsed, dir_name)) {
            .valid => |value| value,
            .invalid => continue,
        };
        if (filter) |requested| {
            if (!std.mem.eql(u8, dir_name, requested) and !std.mem.eql(u8, metadata.name, requested)) continue;
        }

        const src_dir = try std.fs.path.join(alloc, &.{ source_dir, parent_path });
        defer alloc.free(src_dir);

        try copySkillDir(alloc, src_dir, skills_dir, dir_name);
        const installed_name = try alloc.dupe(u8, metadata.name);
        errdefer alloc.free(installed_name);
        try result.installed.append(alloc, installed_name);
    }

    return result;
}

fn readInstallMetadataPrefix(alloc: Allocator, file: *std.Io.File) InstallMetadataReadError!?[]u8 {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file) return null;
    const file_size = std.math.cast(usize, stat.size) orelse return null;
    return try skill_contract.readMetadataPrefix(alloc, file, file_size);
}

fn propagateInstallOpenError(err: std.Io.File.OpenError) std.Io.File.OpenError!void {
    return switch (err) {
        error.Canceled,
        error.Unexpected,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => err,
        else => {},
    };
}

fn propagateInstallMetadataReadError(err: InstallMetadataReadError) InstallMetadataReadError!void {
    return switch (err) {
        error.OutOfMemory,
        error.Canceled,
        error.Unexpected,
        error.SystemResources,
        => err,
        else => {},
    };
}

fn resolveInstallDirectory(alloc: Allocator, source: []const u8) !?[]u8 {
    const resolved = if (std.fs.path.isAbsolute(source))
        try alloc.dupe(u8, source)
    else
        io_mod.realpathAlloc(alloc, source) catch return null;

    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), resolved, .{}) catch {
        alloc.free(resolved);
        return null;
    };
    dir.close(io_mod.getIo());
    return resolved;
}

fn parseNpxInstallSource(input: []const u8) ?ParsedSource {
    if (!looksLikeSkillsInstallCommand(input)) return null;

    var source: ?[]const u8 = null;
    var filter: ?[]const u8 = null;

    var tokens = std.mem.tokenizeAny(u8, input, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "npx") or std.mem.eql(u8, token, "bunx") or std.mem.eql(u8, token, "skills") or std.mem.eql(u8, token, "add") or std.mem.eql(u8, token, "-g") or std.mem.eql(u8, token, "-y")) {
            continue;
        }
        if (std.mem.eql(u8, token, "--skill")) {
            filter = tokens.next() orelse return null;
            continue;
        }
        if (std.mem.startsWith(u8, token, "--skill=")) {
            filter = token[8..];
            continue;
        }
        if (std.mem.eql(u8, token, "--yes")) continue;
        if (std.mem.startsWith(u8, token, "-")) continue;
        if (source == null) {
            source = token;
            continue;
        }
    }

    return if (source) |value| .{ .source = value, .filter = filter } else null;
}

fn looksLikeSkillsInstallCommand(input: []const u8) bool {
    return (std.mem.startsWith(u8, input, "npx ") or std.mem.startsWith(u8, input, "bunx ")) and std.mem.find(u8, input, "skills add") != null;
}

fn parseInlineInstallSource(input: []const u8) ParsedSource {
    if (parseSkillsDotShSource(input)) |parsed| return parsed;
    if (parseRepoSkillSource(input)) |parsed| return parsed;
    return .{ .source = input };
}

fn parseSkillsDotShSource(input: []const u8) ?ParsedSource {
    const marker = std.mem.find(u8, input, "skills.sh/") orelse return null;
    const rest = input[marker + "skills.sh/".len ..];

    var parts = std.mem.tokenizeScalar(u8, rest, '/');
    const owner = parts.next() orelse return null;
    const repo = parts.next() orelse return null;
    const skill = parts.next();

    return .{
        .source = input[marker + "skills.sh/".len ..][0 .. owner.len + 1 + repo.len],
        .filter = skill,
    };
}

fn parseRepoSkillSource(input: []const u8) ?ParsedSource {
    if (!isLikelyRepoSkillSource(input)) return null;
    const at = std.mem.findScalarLast(u8, input, '@') orelse return null;
    return .{
        .source = input[0..at],
        .filter = input[at + 1 ..],
    };
}

fn isLikelyRepoSkillSource(input: []const u8) bool {
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://") or std.mem.startsWith(u8, input, "git@")) return false;
    if (std.fs.path.isAbsolute(input)) return false;
    if (std.mem.startsWith(u8, input, "./") or std.mem.startsWith(u8, input, "../") or std.mem.startsWith(u8, input, "~/")) return false;

    const at = std.mem.findScalarLast(u8, input, '@') orelse return false;
    const slash = std.mem.findScalarLast(u8, input[0..at], '/') orelse return false;
    return slash > 0 and at + 1 < input.len;
}

fn mergeInstallFilters(a: ?[]const u8, b: ?[]const u8, c: ?[]const u8) !?[]const u8 {
    var merged: ?[]const u8 = null;
    const filters = [_]?[]const u8{ a, b, c };
    for (filters) |value| {
        const filter = value orelse continue;
        if (filter.len == 0) continue;
        if (merged == null) {
            merged = filter;
            continue;
        }
        if (!std.mem.eql(u8, merged.?, filter)) return error.ConflictingSkillInstallFilter;
    }
    return merged;
}

fn cloneUrlForSource(alloc: Allocator, url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, url, "http") or std.mem.startsWith(u8, url, "git@")) {
        return alloc.dupe(u8, url);
    }
    return std.fmt.allocPrint(alloc, "https://github.com/{s}.git", .{url});
}

fn drainCloneOutput(alloc: Allocator, child: *std.process.Child) !void {
    var stdout_capture: std.ArrayList(u8) = .empty;
    defer stdout_capture.deinit(alloc);
    var stderr_capture: std.ArrayList(u8) = .empty;
    defer stderr_capture.deinit(alloc);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io_mod.getIo(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (true) {
        const keep_reading = if (multi_reader.fill(4096, .none))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            else => |e| return e,
        };

        try appendCappedOutput(alloc, &stdout_capture, stdout_reader);
        try appendCappedOutput(alloc, &stderr_capture, stderr_reader);

        if (!keep_reading) break;
    }

    try multi_reader.checkAnyError();
}

fn appendCappedOutput(alloc: Allocator, capture: *std.ArrayList(u8), reader: *std.Io.Reader) !void {
    const buffered = reader.buffered();
    if (buffered.len == 0) return;

    if (capture.items.len < clone_output_capture_limit) {
        const remaining = clone_output_capture_limit - capture.items.len;
        try capture.appendSlice(alloc, buffered[0..@min(remaining, buffered.len)]);
    }

    reader.tossBuffered();
}

fn extractRepoName(url: []const u8) []const u8 {
    var name = url;
    if (std.mem.findLast(u8, name, "/")) |idx| {
        name = name[idx + 1 ..];
    }
    if (std.mem.endsWith(u8, name, ".git")) {
        name = name[0 .. name.len - 4];
    }
    return name;
}

const InstallTransactionPaths = struct {
    root: []u8,
    staged: []u8,
    backup: []u8,

    fn init(alloc: Allocator, skills_dir: []const u8, token: [16]u8) !InstallTransactionPaths {
        const suffix = std.fmt.bytesToHex(token, .lower);
        const root = try std.fmt.allocPrint(
            alloc,
            "{s}/.skill-install-{s}",
            .{ skills_dir, suffix },
        );
        errdefer alloc.free(root);
        const staged = try std.fs.path.join(alloc, &.{ root, "staged" });
        errdefer alloc.free(staged);
        const backup = try std.fs.path.join(alloc, &.{ root, "backup" });
        return .{ .root = root, .staged = staged, .backup = backup };
    }

    fn deinit(self: *InstallTransactionPaths, alloc: Allocator) void {
        alloc.free(self.backup);
        alloc.free(self.staged);
        alloc.free(self.root);
        self.* = undefined;
    }
};

const install_transaction_attempts: usize = 8;
const install_lock_deadline_ms: u64 = 2_000;
const install_lock_dir_name = ".skill-install-locks";

fn fillInstallTransactionToken(_: ?*anyopaque, token: *[16]u8) void {
    io_mod.getIo().random(token);
}

const InstallTransactionTokenOps = struct {
    ctx: ?*anyopaque = null,
    fill: *const fn (?*anyopaque, *[16]u8) void = fillInstallTransactionToken,
};

fn renameInstallPath(_: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
    try std.Io.Dir.renameAbsolute(old_path, new_path, io_mod.getIo());
}

const InstallMutationOps = struct {
    ctx: ?*anyopaque = null,
    rename: *const fn (?*anyopaque, []const u8, []const u8) anyerror!void = renameInstallPath,
};

const CopySkillDirOptions = struct {
    transaction_tokens: InstallTransactionTokenOps = .{},
    lock_ops: io_mod.LockOps = .{},
    lock_deadline_ms: u64 = install_lock_deadline_ms,
    mutation: InstallMutationOps = .{},
};

fn createInstallTransaction(
    alloc: Allocator,
    skills_dir: []const u8,
    token_ops: InstallTransactionTokenOps,
) !InstallTransactionPaths {
    for (0..install_transaction_attempts) |_| {
        var token: [16]u8 = undefined;
        token_ops.fill(token_ops.ctx, &token);
        var transaction = try InstallTransactionPaths.init(alloc, skills_dir, token);
        std.Io.Dir.createDirAbsolute(io_mod.getIo(), transaction.root, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                transaction.deinit(alloc);
                continue;
            },
            else => {
                transaction.deinit(alloc);
                return err;
            },
        };
        return transaction;
    }
    return error.SkillInstallTransactionCollision;
}

fn acquireSkillInstallLock(
    skills_dir: []const u8,
    skill_name: []const u8,
    deadline_ms: u64,
    lock_ops: io_mod.LockOps,
) !io_mod.TimedAdvisoryLock {
    const parent_path = std.fs.path.dirname(skills_dir) orelse return error.InvalidSkillsDirectory;
    var parent = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer parent.close(io_mod.getIo());

    var lock_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, install_lock_dir_name);
    defer lock_dir.close();
    return io_mod.acquireTimedAdvisoryLockWithOps(&lock_dir, skill_name, deadline_ms, lock_ops) catch |err| switch (err) {
        error.LockBusy => return error.SkillInstallLockBusy,
        error.LockUnsupported => return error.SkillInstallLockUnsupported,
        else => return err,
    };
}

fn copySkillDir(alloc: Allocator, src_dir: []const u8, skills_dir: []const u8, skill_name: []const u8) !void {
    return copySkillDirWithOptions(alloc, src_dir, skills_dir, skill_name, .{});
}

fn copySkillDirWithOptions(
    alloc: Allocator,
    src_dir: []const u8,
    skills_dir: []const u8,
    skill_name: []const u8,
    options: CopySkillDirOptions,
) !void {
    try skill_contract.validateManagedSkillName(skill_name);
    try ensureDir(skills_dir);

    const dest_dir = try std.fs.path.join(alloc, &.{ skills_dir, skill_name });
    defer alloc.free(dest_dir);
    var transaction = try createInstallTransaction(alloc, skills_dir, options.transaction_tokens);
    defer transaction.deinit(alloc);

    var preserve_transaction = false;
    defer if (!preserve_transaction) {
        std.Io.Dir.cwd().deleteTree(io_mod.getIo(), transaction.root) catch |err| {
            debug_trace.logf("skills", "install transaction cleanup failed path={s} err={s}", .{ transaction.root, @errorName(err) });
        };
    };

    try copyDirRecursive(alloc, src_dir, transaction.staged);

    var install_lock = try acquireSkillInstallLock(skills_dir, skill_name, options.lock_deadline_ms, options.lock_ops);
    defer install_lock.release();

    var moved_existing = true;
    options.mutation.rename(options.mutation.ctx, dest_dir, transaction.backup) catch |err| switch (err) {
        error.FileNotFound => moved_existing = false,
        else => return err,
    };
    options.mutation.rename(options.mutation.ctx, transaction.staged, dest_dir) catch |commit_err| {
        if (moved_existing) {
            options.mutation.rename(options.mutation.ctx, transaction.backup, dest_dir) catch |rollback_err| {
                preserve_transaction = true;
                debug_trace.logf(
                    "skills",
                    "install rollback failed destination={s} transaction={s} backup={s} commit_err={s} rollback_err={s}",
                    .{ dest_dir, transaction.root, transaction.backup, @errorName(commit_err), @errorName(rollback_err) },
                );
                return error.SkillInstallRollbackFailed;
            };
        }
        return commit_err;
    };
}

fn copyDirRecursive(alloc: Allocator, src_dir: []const u8, dest_dir: []const u8) !void {
    try ensureDir(dest_dir);

    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), src_dir, .{ .iterate = true });
    defer dir.close(io_mod.getIo());

    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".git")) continue;

        const src_path = try std.fs.path.join(alloc, &.{ src_dir, entry.name });
        defer alloc.free(src_path);
        const dst_path = try std.fs.path.join(alloc, &.{ dest_dir, entry.name });
        defer alloc.free(dst_path);

        switch (entry.kind) {
            .directory => try copyDirRecursive(alloc, src_path, dst_path),
            .file => try copyFile(alloc, src_path, dst_path),
            else => {},
        }
    }
}

fn copyFile(alloc: Allocator, src_path: []const u8, dst_path: []const u8) !void {
    if (std.fs.path.dirname(dst_path)) |parent| try ensureDir(parent);
    try io_mod.copyFileAtomic(alloc, src_path, dst_path);
}

fn ensureDir(path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io_mod.getIo(), path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            if (std.fs.path.dirname(path)) |parent| {
                try ensureDir(parent);
                try std.Io.Dir.createDirAbsolute(io_mod.getIo(), path, .default_dir);
            } else {
                return err;
            }
        },
    };
}

fn resetInstalledSkillFixture(tmp: *std.testing.TmpDir) !void {
    tmp.dir.deleteTree(io_mod.getIo(), "dest/review") catch {};
    try writeTempFile(tmp, "dest/review/SKILL.md", "old skill\n");
}

fn expectNoInstallTransactionEntries(tmp: *std.testing.TmpDir) !void {
    var dest = try tmp.dir.openDir(io_mod.getIo(), "dest", .{ .iterate = true });
    defer dest.close(io_mod.getIo());
    var entries = dest.iterate();
    while (try entries.next(io_mod.getIo())) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".skill-install-"));
    }
}

fn countImmediateSkillDirectories(root: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{ .iterate = true });
    defer dir.close(io_mod.getIo());

    var count: usize = 0;
    var entries = dir.iterate();
    while (try entries.next(io_mod.getIo())) |entry| {
        if (entry.kind != .directory) continue;
        var candidate = try dir.openDir(io_mod.getIo(), entry.name, .{ .follow_symlinks = false });
        defer candidate.close(io_mod.getIo());
        const stat = candidate.statFile(io_mod.getIo(), "SKILL.md", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind == .file) count += 1;
    }
    return count;
}

const TestTransactionTokenState = struct {
    collision_token: [16]u8,
    fresh_token: [16]u8,
    collision_count: usize,
    calls: usize = 0,
};

fn fillTestTransactionToken(ctx: ?*anyopaque, token: *[16]u8) void {
    const state: *TestTransactionTokenState = @ptrCast(@alignCast(ctx.?));
    token.* = if (state.calls < state.collision_count) state.collision_token else state.fresh_token;
    state.calls += 1;
}

fn testTransactionTokenOps(state: *TestTransactionTokenState) InstallTransactionTokenOps {
    return .{ .ctx = state, .fill = fillTestTransactionToken };
}

fn testInstallLockUnsupported(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
    return error.FileLocksUnsupported;
}

const RollbackLockTestState = struct {
    skills_dir: []const u8,
    skill_name: []const u8,
    rename_calls: usize = 0,
    observed_busy: bool = false,
};

fn renameWithCommitFailure(ctx: ?*anyopaque, old_path: []const u8, new_path: []const u8) anyerror!void {
    const state: *RollbackLockTestState = @ptrCast(@alignCast(ctx.?));
    state.rename_calls += 1;
    if (state.rename_calls == 2) {
        var competing = acquireSkillInstallLock(state.skills_dir, state.skill_name, 0, .{}) catch |err| switch (err) {
            error.SkillInstallLockBusy => {
                state.observed_busy = true;
                return error.InjectedSkillInstallCommitFailure;
            },
            else => return err,
        };
        competing.release();
        return error.SkillInstallLockNotHeld;
    }
    try renameInstallPath(null, old_path, new_path);
}













fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn writeLargeTempSkill(tmp: *std.testing.TmpDir, sub_path: []const u8, name: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "---\nname: ");
    try file.writeStreamingAll(io_mod.getIo(), name);
    try file.writeStreamingAll(io_mod.getIo(), "\ndescription: valid large skill\n---\n\n");
    const body_chunk = [_]u8{'x'} ** (16 * 1024);
    for (0..257) |_| try file.writeStreamingAll(io_mod.getIo(), &body_chunk);
    try file.writeStreamingAll(io_mod.getIo(), "\nLARGE_SKILL_TAIL\n");
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn expectNoAbsoluteFile(path: []const u8) !void {
    if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |opened| {
        var file = opened;
        defer file.close(io_mod.getIo());
        try std.testing.expect(false);
    } else |_| {}
}


































const StaticSkill = struct {
    name: []const u8,
    info: SkillInfo,
};

const StaticSkillCtx = struct {
    skills: []const StaticSkill,
};

fn findStaticSkill(ctx: *anyopaque, name: []const u8) ?SkillInfo {
    const static_ctx: *StaticSkillCtx = @ptrCast(@alignCast(ctx));
    for (static_ctx.skills) |skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill.info;
    }
    return null;
}

fn staticCommandRequest(skills_dir: []const u8, static_ctx: *StaticSkillCtx) CommandRequest {
    return .{
        .skills_dir = skills_dir,
        .find_ctx = @ptrCast(static_ctx),
        .find_skill = findStaticSkill,
    };
}









