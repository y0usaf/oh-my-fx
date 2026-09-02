const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const ignored_dirs = @import("ignored_dirs.zig");
const io_mod = @import("../shared/io.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;

pub const default_candidate_cap: usize = 100_000;
pub const default_git_stdout_limit: usize = 32 * 1024 * 1024;
pub const max_relative_path_bytes: usize = 2048;

pub const Source = enum {
    git,
    recursive,
};

pub const CapReason = enum {
    candidate_cap,
};

pub const Options = struct {
    candidate_cap: usize = default_candidate_cap,
    git_stdout_limit: usize = default_git_stdout_limit,
    ignored_names: []const []const u8 = ignored_dirs.ignored_directory_names,
    force_fallback: bool = false,
    include_untracked: bool = false,
    only_untracked: bool = false,
    include_hidden: bool = false,
    sort_paths: bool = false,
    git_worktree_is_authoritative: bool = false,
};

pub const Result = struct {
    files: []const []const u8,
    source: Source,
    candidate_cap: usize,
    incomplete: bool = false,
    cap_reason: ?CapReason = null,
    skipped_overlong: usize = 0,
};

pub const DirectoryResult = struct {
    directories: []const []const u8,
    source: Source,
    candidate_cap: usize,
    incomplete: bool = false,
    cap_reason: ?CapReason = null,
    skipped_overlong: usize = 0,
};

pub fn discover(arena: Allocator, workspace_root: []const u8, options: Options) !Result {
    return discoverWithStop(arena, workspace_root, options, null, trustedGitExecutable());
}

pub fn discoverCancellable(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: *std.atomic.Value(bool),
) !Result {
    return discoverWithStop(arena, workspace_root, options, stop_requested, trustedGitExecutable());
}

pub fn discoverDirectoriesCancellable(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: *std.atomic.Value(bool),
) !DirectoryResult {
    return discoverDirectoriesWithStop(arena, workspace_root, options, stop_requested, trustedGitExecutable());
}

fn discoverWithStop(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    git_executable: ?[]const u8,
) !Result {
    try checkCanceled(stop_requested);
    if (workspace_root.len == 0) {
        return .{
            .files = &.{},
            .source = .recursive,
            .candidate_cap = options.candidate_cap,
        };
    }

    if (!options.force_fallback) git: {
        const executable = git_executable orelse {
            debug_trace.logf("core", "workspace file discovery trusted Git unavailable; falling back root={s}", .{workspace_root});
            break :git;
        };
        if (gitRawList(arena, workspace_root, options, stop_requested, executable)) |raw| {
            const parsed = try parseRawList(arena, raw, .git, options);
            if (options.only_untracked or
                options.git_worktree_is_authoritative or
                parsed.files.len > 0 or
                parsed.incomplete or
                parsed.skipped_overlong > 0)
            {
                return parsed;
            }
            debug_trace.logf("core", "workspace file discovery git returned no candidates; falling back root={s}", .{workspace_root});
        } else |err| {
            if (err == error.Canceled) return error.Canceled;
            if (options.git_worktree_is_authoritative and try hasGitMetadata(arena, workspace_root)) {
                return error.GitFileListFailed;
            }
            debug_trace.logf("core", "workspace file discovery falling back root={s} err={s}", .{ workspace_root, @errorName(err) });
        }
    }

    return walkWorkspace(arena, workspace_root, options, stop_requested);
}

fn discoverDirectoriesWithStop(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    git_executable: ?[]const u8,
) !DirectoryResult {
    try checkCanceled(stop_requested);
    if (workspace_root.len == 0) {
        return .{
            .directories = &.{},
            .source = .recursive,
            .candidate_cap = options.candidate_cap,
        };
    }

    if (!options.force_fallback) git: {
        const executable = git_executable orelse {
            debug_trace.logf("core", "workspace directory discovery trusted Git unavailable; falling back root={s}", .{workspace_root});
            break :git;
        };
        if (gitRawIgnoredDirectoryList(arena, workspace_root, options, stop_requested, executable)) |raw| {
            var ignored_paths = try parseRawIgnoredDirectories(arena, raw);
            defer ignored_paths.deinit(arena);
            var git_options = options;
            git_options.ignored_names = &.{".git"};
            return walkWorkspaceDirectories(arena, workspace_root, git_options, stop_requested, &ignored_paths, .git);
        } else |err| {
            if (err == error.Canceled) return error.Canceled;
            if (options.git_worktree_is_authoritative and try hasGitMetadata(arena, workspace_root)) {
                return error.GitFileListFailed;
            }
            debug_trace.logf("core", "workspace directory discovery falling back root={s} err={s}", .{ workspace_root, @errorName(err) });
        }
    }

    return walkWorkspaceDirectories(arena, workspace_root, options, stop_requested, null, .recursive);
}

fn hasGitMetadata(alloc: Allocator, workspace_root: []const u8) !bool {
    var current = workspace_root;
    while (current.len > 0) {
        const found = found: {
            const marker = try std.fs.path.join(alloc, &.{ current, ".git" });
            defer alloc.free(marker);
            _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), marker, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => break :found false,
                else => |e| return e,
            };
            break :found true;
        };
        if (found) return true;

        const parent = std.fs.path.dirname(current) orelse return false;
        if (std.mem.eql(u8, parent, current)) return false;
        current = parent;
    }
    return false;
}

fn gitTrackedFilesArgv(git_executable: []const u8) [5][]const u8 {
    return .{ git_executable, "--no-optional-locks", "ls-files", "-z", "--cached" };
}

fn gitTrackedAndOtherFilesArgv(git_executable: []const u8) [7][]const u8 {
    return .{ git_executable, "--no-optional-locks", "ls-files", "-z", "--cached", "--others", "--exclude-standard" };
}

fn gitOtherFilesArgv(git_executable: []const u8) [6][]const u8 {
    return .{ git_executable, "--no-optional-locks", "ls-files", "-z", "--others", "--exclude-standard" };
}

fn gitIgnoredDirectoriesArgv(git_executable: []const u8) [8][]const u8 {
    return .{ git_executable, "--no-optional-locks", "ls-files", "-z", "--others", "--ignored", "--directory", "--exclude-standard" };
}

fn gitRawList(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    git_executable: []const u8,
) ![]u8 {
    const tracked_argv = gitTrackedFilesArgv(git_executable);
    const tracked_and_other_argv = gitTrackedAndOtherFilesArgv(git_executable);
    const other_argv = gitOtherFilesArgv(git_executable);
    const argv: []const []const u8 = if (options.only_untracked)
        &other_argv
    else if (options.include_untracked)
        &tracked_and_other_argv
    else
        &tracked_argv;
    return runGitRawList(arena, workspace_root, argv, options.git_stdout_limit, stop_requested);
}

fn gitRawIgnoredDirectoryList(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    git_executable: []const u8,
) ![]u8 {
    const argv = gitIgnoredDirectoriesArgv(git_executable);
    return runGitRawList(arena, workspace_root, &argv, options.git_stdout_limit, stop_requested);
}

fn runGitRawList(
    arena: Allocator,
    workspace_root: []const u8,
    argv: []const []const u8,
    stdout_limit: usize,
    stop_requested: ?*std.atomic.Value(bool),
) ![]u8 {
    const run_options: std.process.RunOptions = .{
        .argv = argv,
        .cwd = .{ .path = workspace_root },
        .stdout_limit = std.Io.Limit.limited(stdout_limit),
        .stderr_limit = std.Io.Limit.limited(1024),
    };
    const result = if (stop_requested) |stop|
        runCancellable(arena, run_options, stop) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.GitFileListFailed,
        }
    else
        std.process.run(arena, io_mod.getIo(), run_options) catch return error.GitFileListFailed;
    defer arena.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return result.stdout;
            arena.free(result.stdout);
            return error.GitFileListFailed;
        },
        else => {
            arena.free(result.stdout);
            return error.GitFileListFailed;
        },
    }
}

fn trustedGitExecutable() ?[]const u8 {
    const candidates = switch (builtin.os.tag) {
        .windows => &[_][]const u8{
            "C:\\Program Files\\Git\\cmd\\git.exe",
            "C:\\Program Files\\Git\\bin\\git.exe",
        },
        else => &[_][]const u8{
            "/usr/bin/git",
            "/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
            "/opt/local/bin/git",
            "/run/current-system/sw/bin/git",
        },
    };
    for (candidates) |candidate| {
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), candidate, .{ .follow_symlinks = true }) catch continue;
        if (stat.kind == .file) return candidate;
    }
    return null;
}

fn runCancellable(
    alloc: Allocator,
    options: std.process.RunOptions,
    stop_requested: *std.atomic.Value(bool),
) !std.process.RunResult {
    try checkCanceled(stop_requested);

    const zio = io_mod.getIo();
    debug_trace.logf("core", "workspace file discovery process spawning thread={d}", .{std.Thread.getCurrentId()});
    var child = try std.process.spawn(zio, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .expand_arg0 = options.expand_arg0,
        .progress_node = options.progress_node,
        .create_no_window = options.create_no_window,
        .disable_aslr = options.disable_aslr,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(zio);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, zio, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const poll_timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .{ .nanoseconds = 8_000_000 }, .clock = .awake },
    };
    while (true) {
        try checkCanceled(stop_requested);
        const keep_reading = if (multi_reader.fill(options.reserve_amount, poll_timeout))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            error.Timeout => true,
            else => |e| return e,
        };
        if (options.stdout_limit.toInt()) |limit| {
            if (stdout_reader.buffered().len > limit) return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (stderr_reader.buffered().len > limit) return error.StreamTooLong;
        }
        if (!keep_reading) break;
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(zio);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer alloc.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    errdefer alloc.free(stderr);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn checkCanceled(stop_requested: ?*std.atomic.Value(bool)) !void {
    if (stop_requested) |stop| {
        if (stop.load(.seq_cst)) return error.Canceled;
    }
}

fn parseRawList(arena: Allocator, raw: []const u8, source: Source, options: Options) !Result {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(arena);

    var incomplete = false;
    var skipped_overlong: usize = 0;
    const sep: u8 = if (std.mem.findScalar(u8, raw, 0) != null) 0 else '\n';
    var iter = std.mem.splitScalar(u8, raw, sep);
    while (iter.next()) |entry| {
        const trimmed = if (sep == '\n') std.mem.trimEnd(u8, entry, "\r") else entry;
        if (trimmed.len == 0) continue;
        if (!options.include_hidden and pathContainsHiddenDirectoryComponent(trimmed)) continue;
        if (source != .git and pathContainsIgnoredDir(options.ignored_names, trimmed)) continue;
        if (trimmed.len > max_relative_path_bytes) {
            skipped_overlong += 1;
            continue;
        }
        if (files.items.len >= options.candidate_cap) {
            incomplete = true;
            break;
        }

        try files.append(arena, try arena.dupe(u8, trimmed));
    }
    if (options.sort_paths) sortPathList(files.items);

    return .{
        .files = try files.toOwnedSlice(arena),
        .source = source,
        .candidate_cap = options.candidate_cap,
        .incomplete = incomplete,
        .cap_reason = if (incomplete) .candidate_cap else null,
        .skipped_overlong = skipped_overlong,
    };
}

const PathSet = std.StringHashMapUnmanaged(void);

fn parseRawIgnoredDirectories(arena: Allocator, raw: []const u8) !PathSet {
    var ignored: PathSet = .empty;
    errdefer ignored.deinit(arena);
    const separator: u8 = if (std.mem.findScalar(u8, raw, 0) != null) 0 else '\n';
    var entries = std.mem.splitScalar(u8, raw, separator);
    while (entries.next()) |entry| {
        const trimmed = if (separator == '\n') std.mem.trimEnd(u8, entry, "\r") else entry;
        if (trimmed.len == 0 or !std.fs.path.isSep(trimmed[trimmed.len - 1])) continue;

        var path_end = trimmed.len;
        while (path_end > 0 and std.fs.path.isSep(trimmed[path_end - 1])) : (path_end -= 1) {}
        if (path_end == 0) continue;
        const path = trimmed[0..path_end];
        if (ignored.contains(path)) continue;
        const owned = try arena.dupe(u8, path);
        errdefer arena.free(owned);
        try ignored.put(arena, owned, {});
    }
    return ignored;
}

fn walkWorkspace(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
) !Result {
    const walked = try walkWorkspacePaths(arena, workspace_root, options, stop_requested, .files, null);
    return .{
        .files = walked.paths,
        .source = .recursive,
        .candidate_cap = options.candidate_cap,
        .incomplete = walked.incomplete,
        .cap_reason = if (walked.incomplete) .candidate_cap else null,
        .skipped_overlong = walked.skipped_overlong,
    };
}

fn walkWorkspaceDirectories(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    ignored_paths: ?*const PathSet,
    source: Source,
) !DirectoryResult {
    const walked = try walkWorkspacePaths(arena, workspace_root, options, stop_requested, .directories, ignored_paths);
    return .{
        .directories = walked.paths,
        .source = source,
        .candidate_cap = options.candidate_cap,
        .incomplete = walked.incomplete,
        .cap_reason = if (walked.incomplete) .candidate_cap else null,
        .skipped_overlong = walked.skipped_overlong,
    };
}

const WalkTarget = enum {
    files,
    directories,
};

const WalkResult = struct {
    paths: []const []const u8,
    incomplete: bool,
    skipped_overlong: usize,
};

fn walkWorkspacePaths(
    arena: Allocator,
    workspace_root: []const u8,
    options: Options,
    stop_requested: ?*std.atomic.Value(bool),
    target: WalkTarget,
    ignored_paths: ?*const PathSet,
) !WalkResult {
    try checkCanceled(stop_requested);
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer paths.deinit(arena);

    var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), workspace_root, .{ .iterate = true }) catch {
        return .{
            .paths = try paths.toOwnedSlice(arena),
            .incomplete = false,
            .skipped_overlong = 0,
        };
    };

    var stack: std.ArrayList(FrameEntry) = .empty;
    defer {
        for (stack.items) |*entry| {
            entry.dir.close(io_mod.getIo());
            if (!entry.retain_prefix) arena.free(entry.prefix);
        }
        stack.deinit(arena);
    }

    {
        errdefer root.close(io_mod.getIo());
        const initial_prefix = try arena.dupe(u8, "");
        errdefer arena.free(initial_prefix);
        try stack.append(arena, .{ .dir = root, .prefix = initial_prefix, .iter = root.iterate() });
    }

    var incomplete = false;
    var skipped_overlong: usize = 0;
    while (stack.items.len > 0) {
        try checkCanceled(stop_requested);
        var top = &stack.items[stack.items.len - 1];
        const maybe_entry = top.iter.next(io_mod.getIo()) catch {
            var popped = stack.pop().?;
            popped.dir.close(io_mod.getIo());
            if (!popped.retain_prefix) arena.free(popped.prefix);
            continue;
        };

        if (maybe_entry) |entry| {
            try checkCanceled(stop_requested);
            switch (entry.kind) {
                .file, .sym_link => {
                    if (target != .files) continue;
                    if (isIgnoredName(options.ignored_names, entry.name)) continue;
                    if (paths.items.len >= options.candidate_cap) {
                        incomplete = true;
                        break;
                    }
                    const rel = try joinRelative(arena, top.prefix, entry.name);
                    if (rel.len > max_relative_path_bytes) {
                        arena.free(rel);
                        skipped_overlong += 1;
                        continue;
                    }
                    try paths.append(arena, rel);
                },
                .directory => {
                    if (!options.include_hidden and isHiddenName(entry.name)) continue;
                    if (isIgnoredName(options.ignored_names, entry.name)) continue;
                    const new_prefix = try joinRelative(arena, top.prefix, entry.name);
                    errdefer arena.free(new_prefix);
                    if (ignored_paths) |ignored| {
                        if (ignored.contains(new_prefix)) {
                            arena.free(new_prefix);
                            continue;
                        }
                    }
                    if (target == .directories and paths.items.len >= options.candidate_cap) {
                        arena.free(new_prefix);
                        incomplete = true;
                        break;
                    }
                    if (target == .directories and new_prefix.len > max_relative_path_bytes) {
                        arena.free(new_prefix);
                        skipped_overlong += 1;
                        continue;
                    }
                    const retain_prefix = target == .directories;
                    if (retain_prefix) try paths.append(arena, new_prefix);
                    var sub = top.dir.openDir(io_mod.getIo(), entry.name, .{ .iterate = true }) catch {
                        if (!retain_prefix) arena.free(new_prefix);
                        continue;
                    };
                    errdefer sub.close(io_mod.getIo());
                    try stack.append(arena, .{
                        .dir = sub,
                        .prefix = new_prefix,
                        .iter = sub.iterate(),
                        .retain_prefix = retain_prefix,
                    });
                },
                else => {},
            }
        } else {
            var popped = stack.pop().?;
            popped.dir.close(io_mod.getIo());
            if (!popped.retain_prefix) arena.free(popped.prefix);
        }
    }

    if (options.sort_paths) sortPathList(paths.items);

    return .{
        .paths = try paths.toOwnedSlice(arena),
        .incomplete = incomplete,
        .skipped_overlong = skipped_overlong,
    };
}

fn sortPathList(paths: [][]const u8) void {
    sort_utils.sort([]const u8, paths, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

const FrameEntry = struct {
    dir: std.Io.Dir,
    prefix: []u8,
    iter: std.Io.Dir.Iterator,
    retain_prefix: bool = false,
};

fn joinRelative(arena: Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) return arena.dupe(u8, name);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
}

pub fn pathContainsIgnoredDir(ignored: []const []const u8, path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (isIgnoredName(ignored, component.name)) return true;
    }
    return false;
}

pub fn pathContainsHiddenDirectoryComponent(path: []const u8) bool {
    var rest = path;
    while (std.mem.findScalar(u8, rest, '/')) |slash| {
        const component = rest[0..slash];
        if (isHiddenName(component)) return true;
        rest = rest[slash + 1 ..];
    }
    return false;
}

pub fn isHiddenName(name: []const u8) bool {
    return name.len > 1 and name[0] == '.';
}

fn isIgnoredName(ignored: []const []const u8, name: []const u8) bool {
    for (ignored) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn containsPath(files: []const []const u8, needle: []const u8) bool {
    for (files) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}






















fn sleepBlocking(milliseconds: u64) void {
    var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
    sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
}

fn runGitForTest(alloc: Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}
