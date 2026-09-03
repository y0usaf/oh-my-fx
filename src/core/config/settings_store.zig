const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const types = @import("../shared/types.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const context_limits = @import("context_limits.zig");
const project_config = @import("../mcp/project_config.zig");
const model_provider = @import("model_provider.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const update_target = @import("../upgrade/update_target.zig");

const Allocator = std.mem.Allocator;
const max_settings_bytes: usize = 64 * 1024;
pub const max_model_bytes: usize = 1024;
const lock_deadline_ms: u64 = 2000;
const backup_keep_count: usize = 5;
const corrupt_keep_count: usize = 3;

pub const OpenMode = enum {
    read_only,
    writable,
};

pub const Availability = union(enum) {
    read_only_absent,
    writable,
    unavailable,
};

pub const StatuslineItem = enum {
    context,
    session,
    workspace,
};

pub const StatuslineItemPatch = struct {
    item: StatuslineItem,
    enabled: bool,
};

pub const AllowlistResetScope = enum {
    all,
    commands,
    tools,
    urls,
    web_fetch_domains,
};

pub const PermissionPatch = union(enum) {
    add: struct {
        category: []const u8,
        pattern: []const u8,
        action: types.PermissionAction,
    },
    remove: struct {
        category: []const u8,
        pattern: []const u8,
    },
    reset: AllowlistResetScope,
};

pub const PermissionScope = enum {
    user,
    local,
};

pub const PermissionMutation = struct {
    scope: PermissionScope,
    workspace_root: ?[]const u8,
    patch: PermissionPatch,
};

pub const WorkspaceDirectoryPatch = union(enum) {
    add: []const u8,
    remove: []const u8,
    clear,
};

pub const WorkspaceDirectoryMutation = struct {
    workspace_root: []const u8,
    patch: WorkspaceDirectoryPatch,
    observed_sources: []const workspace_access.SavedSource = &.{},
    command_line_directories: []const []const u8 = &.{},
};

pub const ProjectMcpMutation = struct {
    workspace_root: []const u8,
    action: project_config.ProjectMcpAction,
};

pub const UserSettingsPatch = struct {
    model_preference: ?ModelPreferencePatch = null,
    provider: ?model_provider.ProviderId = null,
    permission_mode: ?types.PermissionMode = null,
    credential_source: ?types.CredentialSource = null,
    /// Removes the key entirely so resolution returns to plain precedence.
    /// Distinct from a null `credential_source`, which means "leave unchanged".
    clear_credential_source: bool = false,
    yolo_acknowledged: ?bool = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,
    slash_menu_categories: ?bool = null,
    collapse_tool_calls: ?bool = null,
    update_channel: ?update_target.Channel = null,
    startup_scrollback: ?bool = null,
    prompt_history_enabled: ?bool = null,
    statusline_item: ?StatuslineItemPatch = null,
    notification_turn_end: ?bool = null,
    notification_attention_required: ?bool = null,
    notification_max: ?bool = null,

    fn isEmpty(self: UserSettingsPatch) bool {
        return self.model_preference == null and
            self.provider == null and
            self.permission_mode == null and
            self.credential_source == null and
            !self.clear_credential_source and
            self.yolo_acknowledged == null and
            self.effort == null and
            self.fast_mode == null and
            self.slash_menu_categories == null and
            self.collapse_tool_calls == null and
            self.update_channel == null and
            self.startup_scrollback == null and
            self.prompt_history_enabled == null and
            self.statusline_item == null and
            self.notification_turn_end == null and
            self.notification_attention_required == null and
            self.notification_max == null;
    }
};

pub const ModelPreferencePatch = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
};

pub const SettingsScope = enum {
    user,
    local,
};

pub const LegacyCleanup = struct {
    fields_removed: usize = 0,
    workspaces_changed: usize = 0,
    recovery_paths: []const []const u8 = &.{},

    pub fn deinit(self: *LegacyCleanup, alloc: Allocator) void {
        if (self.recovery_paths.len > 0) {
            for (self.recovery_paths) |path| alloc.free(path);
            alloc.free(self.recovery_paths);
        }
        self.* = undefined;
    }
};

pub const CommittedSettings = struct {
    scope: SettingsScope,
    cleanup: LegacyCleanup = .{},
    permission_rules_removed: usize = 0,
    authority_reduced: bool = false,
};

pub const CommitOutcome = union(enum) {
    unchanged,
    committed: CommittedSettings,

    pub fn deinit(self: *CommitOutcome, alloc: Allocator) void {
        switch (self.*) {
            .unchanged => {},
            .committed => |*committed| committed.cleanup.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const PrimaryLoad = union(enum) {
    absent,
    valid: []u8,
    invalid,
    oversized,

    pub fn deinit(self: *PrimaryLoad, alloc: Allocator) void {
        if (self.* == .valid) alloc.free(self.valid);
        self.* = undefined;
    }
};

const RawPrimary = union(enum) {
    absent,
    bytes: []u8,
    oversized,

    fn deinit(self: *RawPrimary, alloc: Allocator) void {
        if (self.* == .bytes) alloc.free(self.bytes);
        self.* = undefined;
    }
};

const PatchApplication = struct {
    changed: bool = false,
    authority_reduced: bool = false,
    permission_rules_removed: usize = 0,
    legacy_fields_removed: usize = 0,
    legacy_workspaces_changed: usize = 0,
    migration_fields: u16 = 0,
};

const UserPreferenceField = enum(u4) {
    model,
    permission_mode,
    effort,
    fast_mode,
    slash_menu_categories,
    collapse_tool_calls,
    update_channel,
    startup_scrollback,
    prompt_history_enabled,
    statusline_context,
    statusline_session,

    fn mask(self: UserPreferenceField) u16 {
        return @as(u16, 1) << @intFromEnum(self);
    }

    fn snapshotName(self: UserPreferenceField) []const u8 {
        return switch (self) {
            .model => "settings.json.preference-migration.model.json",
            .permission_mode => "settings.json.preference-migration.permission_mode.json",
            .effort => "settings.json.preference-migration.effort.json",
            .fast_mode => "settings.json.preference-migration.fast_mode.json",
            .slash_menu_categories => "settings.json.preference-migration.slash_menu_categories.json",
            .collapse_tool_calls => "settings.json.preference-migration.collapse_tool_calls.json",
            .update_channel => "settings.json.preference-migration.update_channel.json",
            .startup_scrollback => "settings.json.preference-migration.startup_scrollback.json",
            .prompt_history_enabled => "settings.json.preference-migration.prompt_history_enabled.json",
            .statusline_context => "settings.json.preference-migration.statusline_context.json",
            .statusline_session => "settings.json.preference-migration.statusline_session.json",
        };
    }
};

const user_preference_fields = [_]UserPreferenceField{
    .model,
    .permission_mode,
    .effort,
    .fast_mode,
    .slash_menu_categories,
    .collapse_tool_calls,
    .update_channel,
    .startup_scrollback,
    .prompt_history_enabled,
    .statusline_context,
    .statusline_session,
};

const SettingsMutation = union(enum) {
    user: UserSettingsPatch,
    workspace_directory: WorkspaceDirectoryMutation,
    permission: PermissionMutation,
    project_mcp: ProjectMcpMutation,

    fn operation(self: SettingsMutation) []const u8 {
        return switch (self) {
            .user => "user_patch",
            .workspace_directory => "workspace_directory_patch",
            .permission => "permission_patch",
            .project_mcp => "project_mcp_patch",
        };
    }

    fn scope(self: SettingsMutation) SettingsScope {
        return switch (self) {
            .user => .user,
            .workspace_directory => .local,
            .permission => |mutation| switch (mutation.scope) {
                .user => .user,
                .local => .local,
            },
            .project_mcp => .local,
        };
    }

    fn mutationMode(self: SettingsMutation) []const u8 {
        return switch (self) {
            .user => |patch| if (patch.prompt_history_enabled != null)
                "commit_first"
            else
                "runtime_first",
            .workspace_directory => "commit_first",
            .permission => "commit_first",
            .project_mcp => "commit_first",
        };
    }

    fn isEmpty(self: SettingsMutation) bool {
        return switch (self) {
            .user => |patch| patch.isEmpty(),
            .workspace_directory => false,
            .permission => false,
            .project_mcp => false,
        };
    }
};

pub const Store = struct {
    durable_home: ?io_mod.VerifiedDir,
    display_root: []u8,
    availability: Availability,
    mode: OpenMode,
    commit_count: usize = 0,
    forced_fingerprint_conflicts: usize = 0,
    fail_parent_sync_after_rename: bool = false,
    fail_migration_snapshot: bool = false,
    last_failure_cleanup: LegacyCleanup = .{},

    fn initReadOnlyAbsent(alloc: Allocator, home_path: []const u8) !Store {
        return .{
            .durable_home = null,
            .display_root = try profile_paths.rootDir(alloc, home_path),
            .availability = .read_only_absent,
            .mode = .read_only,
        };
    }

    pub fn initFromHome(alloc: Allocator, home_path: []const u8, mode: OpenMode) !Store {
        const zio = io_mod.getIo();
        var home = std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                if (mode == .read_only) return initReadOnlyAbsent(alloc, home_path);
                return err;
            },
            else => return err,
        };
        defer home.close(zio);

        var durable_home = home.openDir(zio, profile_paths.root_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) return initReadOnlyAbsent(alloc, home_path);

                var verified_home = io_mod.VerifiedDir{
                    .dir = try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true }),
                };
                defer verified_home.close();
                const created = try io_mod.openOrCreateVerifiedPrivateDir(&verified_home, profile_paths.root_dir_name);
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
            else => return err,
        };
        errdefer durable_home.close(zio);

        if (mode == .writable) {
            durable_home.setPermissions(zio, std.Io.File.Permissions.fromMode(0o700)) catch {
                return error.PrivateStatePermissionsUnsupported;
            };
        }
        const stat = try durable_home.stat(zio);
        if (stat.kind != .directory) return error.DurablePathUnsafe;
        const durable_mode = stat.permissions.toMode() & 0o777;
        if (mode == .writable and durable_mode != 0o700) {
            return error.PrivateStatePermissionsUnsupported;
        }
        if (mode == .read_only and durableModeWritableByGroupOrOther(durable_mode)) {
            return error.PrivateStatePermissionsUnsupported;
        }

        return .{
            .durable_home = .{ .dir = durable_home },
            .display_root = try io_mod.dirRealpathAlloc(alloc, durable_home, "."),
            .availability = .writable,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.last_failure_cleanup.deinit(alloc);
        if (self.durable_home) |*dir| dir.close();
        alloc.free(self.display_root);
        self.* = undefined;
    }

    pub fn loadPrimary(self: *Store, alloc: Allocator) !PrimaryLoad {
        var raw = try self.loadRawPrimary(alloc);
        switch (raw) {
            .absent => return .absent,
            .oversized => return .oversized,
            .bytes => |bytes| {
                raw = .absent;
                errdefer alloc.free(bytes);
                var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
                    alloc.free(bytes);
                    return .invalid;
                };
                defer parsed.deinit();
                if (parsed.value != .object) {
                    alloc.free(bytes);
                    return .invalid;
                }
                return .{ .valid = bytes };
            },
        }
    }

    pub fn applyUserPatch(
        self: *Store,
        alloc: Allocator,
        patch: UserSettingsPatch,
    ) !CommitOutcome {
        return self.applyMutation(alloc, .{ .user = patch });
    }

    pub fn applyPermissionPatch(
        self: *Store,
        alloc: Allocator,
        mutation: PermissionMutation,
    ) !CommitOutcome {
        return self.applyMutation(alloc, .{ .permission = mutation });
    }

    pub fn applyWorkspaceDirectoryPatch(
        self: *Store,
        alloc: Allocator,
        mutation: WorkspaceDirectoryMutation,
    ) !CommitOutcome {
        return self.applyMutation(alloc, .{ .workspace_directory = mutation });
    }

    pub fn applyProjectMcpMutation(
        self: *Store,
        alloc: Allocator,
        mutation: ProjectMcpMutation,
    ) !CommitOutcome {
        return self.applyMutation(alloc, .{ .project_mcp = mutation });
    }

    fn applyMutation(
        self: *Store,
        alloc: Allocator,
        mutation: SettingsMutation,
    ) !CommitOutcome {
        self.last_failure_cleanup.deinit(alloc);
        self.last_failure_cleanup = .{};
        const operation = mutation.operation();
        const mutation_mode = mutation.mutationMode();
        return self.applyMutationImpl(alloc, mutation, operation, mutation_mode) catch |err| {
            debug_trace.logf(
                "config",
                "settings operation={s} path_category=user_settings scope={s} mutation_mode={s} outcome=failed error={s}",
                .{ operation, @tagName(mutation.scope()), mutation_mode, @errorName(err) },
            );
            return err;
        };
    }

    fn applyMutationImpl(
        self: *Store,
        alloc: Allocator,
        mutation: SettingsMutation,
        operation: []const u8,
        mutation_mode: []const u8,
    ) !CommitOutcome {
        if (self.mode != .writable or self.durable_home == null) return error.SettingsStoreUnavailable;
        try validateMutation(mutation);
        if (mutation.isEmpty()) {
            debug_trace.logf(
                "config",
                "settings operation={s} path_category=user_settings scope={s} mutation_mode={s} outcome=unchanged error=none",
                .{ operation, @tagName(mutation.scope()), mutation_mode },
            );
            return .unchanged;
        }

        var lock = io_mod.acquireTimedAdvisoryLock(&self.durable_home.?, "settings.lock", lock_deadline_ms) catch |err| switch (err) {
            error.LockBusy => return error.SettingsLockBusy,
            error.LockUnsupported => return error.SettingsLockUnsupported,
            else => return err,
        };
        defer lock.release();

        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            var primary = try self.loadRawPrimary(alloc);
            defer primary.deinit(alloc);

            const existing = switch (primary) {
                .absent => null,
                .oversized => return error.SettingsPrimaryTooLarge,
                .bytes => |bytes| bytes,
            };

            const original_fingerprint = fingerprintOptional(existing);
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var root = if (existing) |bytes|
                (std.json.parseFromSlice(std.json.Value, arena, bytes, .{}) catch {
                    self.copyCorruptBestEffort(alloc, bytes);
                    return error.InvalidSettingsFormat;
                }).value
            else
                std.json.Value{ .object = .empty };
            if (root != .object) {
                if (existing) |bytes| self.copyCorruptBestEffort(alloc, bytes);
                return error.InvalidSettingsFormat;
            }

            const application = try applyMutationToRoot(arena, &root, mutation);
            if (!application.changed) {
                debug_trace.logf(
                    "config",
                    "settings operation={s} path_category=user_settings scope={s} mutation_mode={s} outcome=unchanged error=none",
                    .{ operation, @tagName(mutation.scope()), mutation_mode },
                );
                return .unchanged;
            }

            const candidate = try serializeJson(alloc, root);
            defer alloc.free(candidate);
            if (candidate.len > max_settings_bytes) return error.SettingsTooLarge;
            try validateCandidate(alloc, candidate, mutation);

            const recovery_paths = self.writeMigrationSnapshots(
                alloc,
                application.migration_fields,
                existing,
            ) catch return error.SettingsMigrationSnapshotFailed;
            var recovery_paths_owned = recovery_paths.len > 0;
            defer if (recovery_paths_owned) freeRecoveryPaths(alloc, recovery_paths);

            if (self.forced_fingerprint_conflicts > 0) {
                self.forced_fingerprint_conflicts -= 1;
                continue;
            }

            var latest = try self.loadRawPrimary(alloc);
            defer latest.deinit(alloc);
            const latest_bytes = switch (latest) {
                .absent => null,
                .oversized => return error.SettingsPrimaryTooLarge,
                .bytes => |bytes| bytes,
            };
            const latest_fingerprint = fingerprintOptional(latest_bytes);
            if (!std.mem.eql(u8, &original_fingerprint, &latest_fingerprint)) continue;

            if (existing) |bytes| self.createBackupBestEffort(alloc, bytes);

            var precommit = try self.loadRawPrimary(alloc);
            defer precommit.deinit(alloc);
            const precommit_bytes = switch (precommit) {
                .absent => null,
                .oversized => return error.SettingsPrimaryTooLarge,
                .bytes => |bytes| bytes,
            };
            const precommit_fingerprint = fingerprintOptional(precommit_bytes);
            if (!std.mem.eql(u8, &original_fingerprint, &precommit_fingerprint)) continue;

            const durable_ops = if (self.fail_parent_sync_after_rename)
                io_mod.DurableOps{ .ctx = self, .sync_dir = failStoreParentSync }
            else
                io_mod.DurableOps{};
            io_mod.durableReplaceVerifiedWithOps(
                alloc,
                &self.durable_home.?,
                "settings.json",
                candidate,
                durable_ops,
            ) catch |err| switch (err) {
                error.DurableReplacePostRenameFailed => {
                    self.last_failure_cleanup = .{
                        .fields_removed = application.legacy_fields_removed,
                        .workspaces_changed = application.legacy_workspaces_changed,
                        .recovery_paths = recovery_paths,
                    };
                    recovery_paths_owned = false;
                    return error.SettingsCommitIndeterminate;
                },
                error.DurableReplacePreRenameFailed => return error.SettingsCommitFailed,
                else => return err,
            };
            self.commit_count += 1;
            debug_trace.logf(
                "config",
                "settings operation={s} path_category=user_settings scope={s} mutation_mode={s} outcome=committed legacy_fields_removed={d} legacy_workspaces_changed={d} migration_snapshots_written={d} permission_rules_removed={d} error=none",
                .{
                    operation,
                    @tagName(mutation.scope()),
                    mutation_mode,
                    application.legacy_fields_removed,
                    application.legacy_workspaces_changed,
                    recovery_paths.len,
                    application.permission_rules_removed,
                },
            );
            recovery_paths_owned = false;
            return .{ .committed = .{
                .scope = mutation.scope(),
                .cleanup = .{
                    .fields_removed = application.legacy_fields_removed,
                    .workspaces_changed = application.legacy_workspaces_changed,
                    .recovery_paths = recovery_paths,
                },
                .permission_rules_removed = application.permission_rules_removed,
                .authority_reduced = application.authority_reduced,
            } };
        }
        return error.SettingsConcurrentModification;
    }

    pub fn takeFailureCleanup(self: *Store) LegacyCleanup {
        const cleanup = self.last_failure_cleanup;
        self.last_failure_cleanup = .{};
        return cleanup;
    }

    pub fn readPrimaryForTest(self: *Store, alloc: Allocator) ![]u8 {
        var raw = try self.loadRawPrimary(alloc);
        defer raw.deinit(alloc);
        return switch (raw) {
            .bytes => |bytes| blk: {
                raw = .absent;
                break :blk bytes;
            },
            .absent => error.FileNotFound,
            .oversized => error.SettingsPrimaryTooLarge,
        };
    }

    pub fn primaryStatForTest(self: *Store) !std.Io.File.Stat {
        const dir = self.durable_home orelse return error.FileNotFound;
        return dir.dir.statFile(io_mod.getIo(), "settings.json", .{ .follow_symlinks = false });
    }

    pub fn commitCountForTest(self: *const Store) usize {
        return self.commit_count;
    }

    pub fn forceFingerprintConflictsForTest(self: *Store, count: usize) void {
        self.forced_fingerprint_conflicts = count;
    }

    pub fn failParentSyncAfterRenameForTest(self: *Store) void {
        self.fail_parent_sync_after_rename = true;
    }

    pub fn failMigrationSnapshotForTest(self: *Store) void {
        self.fail_migration_snapshot = true;
    }

    pub fn newestValidBackupPath(self: *Store, alloc: Allocator) !?[]u8 {
        if (self.durable_home == null) return null;
        var backups = self.durable_home.?.dir.openDir(io_mod.getIo(), profile_paths.backups_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
            else => return err,
        };
        defer backups.close(io_mod.getIo());

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        var iterator = backups.iterate();
        while (try iterator.next(io_mod.getIo())) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "settings.json.backup.")) continue;
            if (parseBackupTimestamp(entry.name) == null) continue;
            try names.append(alloc, try alloc.dupe(u8, entry.name));
        }
        sort_utils.sort([]u8, names.items, {}, struct {
            fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
                return backupNameNewerThan(lhs, rhs);
            }
        }.lessThan);

        for (names.items) |name| {
            const stat = backups.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch continue;
            if (stat.kind != .file or stat.nlink != 1 or stat.size > max_settings_bytes) continue;
            var file = backups.openFile(io_mod.getIo(), name, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch continue;
            defer file.close(io_mod.getIo());
            const bytes = io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1) catch continue;
            defer alloc.free(bytes);
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            return try std.fs.path.join(alloc, &.{ self.display_root, profile_paths.backups_dir_name, name });
        }
        return null;
    }

    fn loadRawPrimary(self: *Store, alloc: Allocator) !RawPrimary {
        if (self.durable_home == null) return .absent;
        const zio = io_mod.getIo();
        const open_mode: std.Io.Dir.OpenFileOptions.Mode =
            if (self.mode == .writable) .read_write else .read_only;
        var file = io_mod.openExistingRegularFile(
            self.durable_home.?.dir,
            "settings.json",
            open_mode,
        ) catch |err| switch (err) {
            error.FileNotFound => return .absent,
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
            else => return err,
        };
        defer file.close(zio);

        const stat = try file.stat(zio);
        try io_mod.verifyOpenedRegularFile(stat, open_mode);
        if (self.mode == .writable) {
            file.setPermissions(zio, std.Io.File.Permissions.fromMode(0o600)) catch {
                return error.PrivateStatePermissionsUnsupported;
            };
        }
        const verified_stat = if (self.mode == .writable) try file.stat(zio) else stat;
        const primary_mode = verified_stat.permissions.toMode() & 0o777;
        if (self.mode == .writable and primary_mode != 0o600) {
            return error.PrivateStatePermissionsUnsupported;
        }
        if (self.mode == .read_only and durableModeWritableByGroupOrOther(primary_mode)) {
            return error.PrivateStatePermissionsUnsupported;
        }
        if (verified_stat.size > max_settings_bytes) return .oversized;
        return .{ .bytes = try io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1) };
    }

    fn createBackupBestEffort(self: *Store, alloc: Allocator, bytes: []const u8) void {
        self.createSequencedCopy(alloc, "backup", bytes, backup_keep_count) catch |err| {
            debug_trace.logf("config", "settings backup skipped err={s}", .{@errorName(err)});
        };
    }

    fn copyCorruptBestEffort(self: *Store, alloc: Allocator, bytes: []const u8) void {
        self.createSequencedCopy(alloc, "corrupt", bytes, corrupt_keep_count) catch |err| {
            debug_trace.logf("config", "settings corrupt copy skipped err={s}", .{@errorName(err)});
        };
    }

    fn durableModeWritableByGroupOrOther(mode: std.posix.mode_t) bool {
        return mode & 0o022 != 0;
    }

    fn createSequencedCopy(
        self: *Store,
        alloc: Allocator,
        kind: []const u8,
        bytes: []const u8,
        keep_count: usize,
    ) !void {
        var backups = try io_mod.openOrCreateVerifiedPrivateDir(&self.durable_home.?, profile_paths.backups_dir_name);
        defer backups.close();
        if (std.mem.eql(u8, kind, "corrupt") and try containsCopyWithFingerprint(alloc, backups.dir, kind, bytes)) return;

        const sequence = try nextBackupSequence(backups.dir);
        var random_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const name = try std.fmt.allocPrint(
            alloc,
            "settings.json.{s}.{d}-{x:0>16}-{s}",
            .{ kind, io_mod.milliTimestamp(), sequence, random_hex },
        );
        defer alloc.free(name);
        try io_mod.durableReplaceVerified(alloc, &backups, name, bytes);
        try pruneSequencedCopies(alloc, backups.dir, kind, keep_count);
    }

    fn writeMigrationSnapshots(
        self: *Store,
        alloc: Allocator,
        migration_fields: u16,
        existing: ?[]const u8,
    ) ![]const []const u8 {
        if (migration_fields == 0) return &.{};
        const bytes = existing orelse return error.InvalidSettingsFormat;
        if (self.fail_migration_snapshot) return error.InjectedMigrationSnapshotFailure;
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (paths.items) |path| alloc.free(path);
            paths.deinit(alloc);
        }

        var backups = try io_mod.openOrCreateVerifiedPrivateDir(&self.durable_home.?, profile_paths.backups_dir_name);
        defer backups.close();
        for (user_preference_fields) |field| {
            if (migration_fields & field.mask() == 0) continue;
            const name = field.snapshotName();
            try io_mod.durableReplaceVerified(alloc, &backups, name, bytes);
            try paths.append(
                alloc,
                try std.fs.path.join(alloc, &.{ self.display_root, profile_paths.backups_dir_name, name }),
            );
        }
        return paths.toOwnedSlice(alloc);
    }
};

fn freeRecoveryPaths(alloc: Allocator, paths: []const []const u8) void {
    for (paths) |path| alloc.free(path);
    alloc.free(paths);
}

fn failStoreParentSync(_: ?*anyopaque, _: std.Io.Dir) anyerror!void {
    return error.InjectedParentSyncFailure;
}

fn validateWorkspaceRoot(workspace_root: []const u8) !void {
    if (workspace_root.len == 0 or workspace_root.len > std.fs.max_path_bytes) return error.InvalidDurableField;
    if (!std.fs.path.isAbsolute(workspace_root) or !std.unicode.utf8ValidateSlice(workspace_root)) {
        return error.InvalidDurableField;
    }
}

fn validateMutation(mutation: SettingsMutation) !void {
    switch (mutation) {
        .user => |patch| try validateUserPatch(patch),
        .workspace_directory => |workspace| {
            try validateWorkspaceRoot(workspace.workspace_root);
            if (workspace.observed_sources.len > workspace_access.max_additional_directories) {
                return error.InvalidDurableField;
            }
            for (workspace.observed_sources, 0..) |source, index| {
                if (!validAdditionalDirectoryPath(source.source) or
                    !validAdditionalDirectoryPath(source.identity))
                {
                    return error.InvalidDurableField;
                }
                for (workspace.observed_sources[0..index]) |previous| {
                    if (std.mem.eql(u8, source.source, previous.source)) {
                        return error.InvalidDurableField;
                    }
                }
            }
            if (workspace.command_line_directories.len > workspace_access.max_additional_directories) {
                return error.InvalidDurableField;
            }
            for (workspace.command_line_directories) |path| {
                if (!validAdditionalDirectoryPath(path)) return error.InvalidDurableField;
            }
            switch (workspace.patch) {
                .add, .remove => |path| if (!validAdditionalDirectoryPath(path)) {
                    return error.InvalidDurableField;
                },
                .clear => {},
            }
        },
        .permission => |permission| switch (permission.scope) {
            .user => if (permission.workspace_root != null) return error.InvalidDurableField,
            .local => {
                const workspace_root = permission.workspace_root orelse return error.InvalidDurableField;
                try validateWorkspaceRoot(workspace_root);
            },
        },
        .project_mcp => |project_mcp| {
            try validateWorkspaceRoot(project_mcp.workspace_root);
            switch (project_mcp.action) {
                .approve, .reject => |name| {
                    if (name.len == 0 or name.len > 1024 or
                        !std.unicode.utf8ValidateSlice(name) or
                        std.mem.findScalar(u8, name, 0) != null)
                    {
                        return error.InvalidDurableField;
                    }
                },
                .approve_all, .reset => {},
            }
        },
    }
}

pub fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_bytes or !std.unicode.utf8ValidateSlice(model)) {
        return error.InvalidDurableField;
    }
    if (!std.mem.eql(u8, model, std.mem.trim(u8, model, " \t\r\n"))) return error.InvalidDurableField;
    for (model) |byte| {
        if (std.ascii.isControl(byte)) return error.InvalidDurableField;
    }
}

fn validateUserPatch(patch: UserSettingsPatch) !void {
    if (patch.model_preference) |preference| try validateModel(preference.model);
}

fn validAdditionalDirectoryPath(path: []const u8) bool {
    return path.len > 0 and path.len <= std.fs.max_path_bytes and
        std.fs.path.isAbsolute(path) and std.unicode.utf8ValidateSlice(path) and
        std.mem.findScalar(u8, path, 0) == null;
}

fn applyMutationToRoot(
    arena: Allocator,
    root: *std.json.Value,
    mutation: SettingsMutation,
) !PatchApplication {
    const retired_settings_removed = removeRetiredPresentationSettings(&root.object);
    var application = try switch (mutation) {
        .user => |patch| applyUserPatchToRoot(arena, root, patch),
        .workspace_directory => |workspace| applyWorkspaceDirectoryMutationToRoot(
            arena,
            root,
            workspace,
        ),
        .permission => |permission| applyPermissionMutationToRoot(arena, root, permission),
        .project_mcp => |project_mcp| applyProjectMcpMutationToRoot(arena, root, project_mcp),
    };
    application.changed = application.changed or retired_settings_removed;
    return application;
}

fn applyUserPatchToRoot(
    arena: Allocator,
    root: *std.json.Value,
    patch: UserSettingsPatch,
) !PatchApplication {
    var application = PatchApplication{};
    if (patch.model_preference) |preference| {
        application.changed = try putModelPreference(arena, &root.object, preference) or application.changed;
    }
    if (patch.provider) |value| application.changed = try putString(arena, &root.object, "provider", @tagName(value)) or application.changed;
    if (patch.permission_mode) |value| application.changed = try putString(arena, &root.object, "permission_mode", @tagName(value)) or application.changed;
    if (patch.credential_source) |value| application.changed = try putString(arena, &root.object, "credential_source", @tagName(value)) or application.changed;
    if (patch.clear_credential_source and root.object.contains("credential_source")) {
        _ = root.object.orderedRemove("credential_source");
        application.changed = true;
    }
    if (patch.yolo_acknowledged) |value| application.changed = try putBool(arena, &root.object, "yolo_acknowledged", value) or application.changed;
    if (patch.effort) |value| application.changed = try putString(arena, &root.object, "effort", value.label()) or application.changed;
    if (patch.fast_mode) |value| application.changed = try putBool(arena, &root.object, "fast_mode", value) or application.changed;
    if (patch.slash_menu_categories) |value| application.changed = try putBool(arena, &root.object, "slash_menu_categories", value) or application.changed;
    if (patch.collapse_tool_calls) |value| application.changed = try putBool(arena, &root.object, "collapse_tool_calls", value) or application.changed;
    if (patch.update_channel) |value| application.changed = try putString(arena, &root.object, "update_channel", value.label()) or application.changed;
    if (patch.startup_scrollback) |value| application.changed = try putBool(arena, &root.object, "startup_scrollback", value) or application.changed;

    if (patch.prompt_history_enabled) |enabled| {
        var prompt_history = if (root.object.getPtr("prompt_history")) |value| blk: {
            if (value.* != .object) return error.InvalidSettingsFormat;
            break :blk value;
        } else blk: {
            try root.object.put(arena, "prompt_history", .{ .object = .empty });
            break :blk root.object.getPtr("prompt_history").?;
        };
        application.changed = try putBool(arena, &prompt_history.object, "enabled", enabled) or application.changed;
    }

    if (patch.statusline_item) |item_patch| {
        var statusline = if (root.object.getPtr("statusLine")) |value| blk: {
            if (value.* != .object) return error.InvalidSettingsFormat;
            break :blk value;
        } else blk: {
            try root.object.put(arena, "statusLine", .{ .object = .empty });
            break :blk root.object.getPtr("statusLine").?;
        };
        application.changed = try putBool(arena, &statusline.object, @tagName(item_patch.item), item_patch.enabled) or application.changed;
    }

    if (patch.notification_turn_end != null or
        patch.notification_attention_required != null or
        patch.notification_max != null)
    {
        var notifications = if (root.object.getPtr("notifications")) |value| blk: {
            if (value.* != .object) return error.InvalidSettingsFormat;
            break :blk value;
        } else blk: {
            try root.object.put(arena, "notifications", .{ .object = .empty });
            break :blk root.object.getPtr("notifications").?;
        };
        if (patch.notification_turn_end) |enabled| {
            application.changed = try putBool(arena, &notifications.object, "turn_end", enabled) or application.changed;
        }
        if (patch.notification_attention_required) |enabled| {
            application.changed = try putBool(arena, &notifications.object, "attention_required", enabled) or application.changed;
        }
        if (patch.notification_max) |enabled| {
            application.changed = try putBool(arena, &notifications.object, "max", enabled) or application.changed;
        }
    }
    try cleanupLegacyWorkspacePreferences(arena, root, patch, &application);
    return application;
}

fn removeRetiredPresentationSettings(root: *std.json.ObjectMap) bool {
    var changed = false;
    inline for (&.{ "input_appearance", "maxxing_mode" }) |key| {
        if (root.contains(key)) {
            _ = root.orderedRemove(key);
            changed = true;
        }
    }

    const workspaces = root.getPtr("workspaces") orelse return changed;
    if (workspaces.* != .object) return changed;
    var iterator = workspaces.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        inline for (&.{ "input_appearance", "maxxing_mode" }) |key| {
            if (entry.value_ptr.object.contains(key)) {
                _ = entry.value_ptr.object.orderedRemove(key);
                changed = true;
            }
        }
    }
    return changed;
}

fn cleanupLegacyWorkspacePreferences(
    arena: Allocator,
    root: *std.json.Value,
    patch: UserSettingsPatch,
    application: *PatchApplication,
) !void {
    const workspaces = root.object.getPtr("workspaces") orelse return;
    if (workspaces.* != .object) return error.InvalidSettingsFormat;

    var empty_workspaces: std.ArrayList([]const u8) = .empty;
    defer empty_workspaces.deinit(arena);
    var iterator = workspaces.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const removed_before = application.legacy_fields_removed;

        removeLegacyLeaf(
            &entry.value_ptr.object,
            "model",
            .model,
            patch.model_preference != null and patch.model_preference.?.provider == .gateway,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "permission_mode",
            .permission_mode,
            patch.permission_mode != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "effort",
            .effort,
            patch.effort != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "fast_mode",
            .fast_mode,
            patch.fast_mode != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "slash_menu_categories",
            .slash_menu_categories,
            patch.slash_menu_categories != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "collapse_tool_calls",
            .collapse_tool_calls,
            patch.collapse_tool_calls != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "update_channel",
            .update_channel,
            patch.update_channel != null,
            application,
        );
        removeLegacyLeaf(
            &entry.value_ptr.object,
            "startup_scrollback",
            .startup_scrollback,
            patch.startup_scrollback != null,
            application,
        );
        removeLegacyNestedLeaf(
            &entry.value_ptr.object,
            "prompt_history",
            "enabled",
            .prompt_history_enabled,
            patch.prompt_history_enabled != null,
            application,
        );
        if (patch.statusline_item) |item_patch| {
            const legacy_field: ?UserPreferenceField = switch (item_patch.item) {
                .context => .statusline_context,
                .session => .statusline_session,
                .workspace => null,
            };
            if (legacy_field) |field| {
                removeLegacyNestedLeaf(
                    &entry.value_ptr.object,
                    "statusLine",
                    @tagName(item_patch.item),
                    field,
                    true,
                    application,
                );
            }
        }
        if (application.legacy_fields_removed != removed_before) {
            application.legacy_workspaces_changed += 1;
            if (entry.value_ptr.object.count() == 0) {
                try empty_workspaces.append(arena, entry.key_ptr.*);
            }
        }
    }
    for (empty_workspaces.items) |workspace_root| {
        _ = workspaces.object.orderedRemove(workspace_root);
    }
}

fn removeLegacyLeaf(
    object: *std.json.ObjectMap,
    key: []const u8,
    field: UserPreferenceField,
    enabled: bool,
    application: *PatchApplication,
) void {
    if (!enabled or !object.contains(key)) return;
    _ = object.orderedRemove(key);
    application.changed = true;
    application.legacy_fields_removed += 1;
    application.migration_fields |= field.mask();
}

fn removeLegacyNestedLeaf(
    object: *std.json.ObjectMap,
    container_key: []const u8,
    leaf_key: []const u8,
    field: UserPreferenceField,
    enabled: bool,
    application: *PatchApplication,
) void {
    if (!enabled) return;
    const container = object.getPtr(container_key) orelse return;
    if (container.* != .object or !container.object.contains(leaf_key)) return;
    _ = container.object.orderedRemove(leaf_key);
    if (container.object.count() == 0) _ = object.orderedRemove(container_key);
    application.changed = true;
    application.legacy_fields_removed += 1;
    application.migration_fields |= field.mask();
}

fn applyWorkspaceDirectoryMutationToRoot(
    arena: Allocator,
    root: *std.json.Value,
    mutation: WorkspaceDirectoryMutation,
) !PatchApplication {
    const workspace = try workspaceObject(arena, root, mutation.workspace_root);
    const existing = workspace.getPtr("additional_directories");
    var changed = false;
    var unseen_sources = switch (mutation.patch) {
        .add, .remove => try unseenWorkspaceSourceStrings(
            arena,
            existing,
            mutation.observed_sources,
        ),
        .clear => std.ArrayList([]const u8).empty,
    };
    defer unseen_sources.deinit(arena);

    switch (mutation.patch) {
        .add => |path| {
            var identities: std.ArrayList([]const u8) = .empty;
            defer identities.deinit(arena);
            var saved_contains_path = containsWorkspaceIdentity(unseen_sources.items, path);

            if (existing) |directories| {
                var index: usize = 0;
                while (index < directories.array.items.len) {
                    const entry = directories.array.items[index];
                    const observed = observedWorkspaceSource(mutation.observed_sources, entry.string) orelse {
                        index += 1;
                        continue;
                    };
                    saved_contains_path = saved_contains_path or std.mem.eql(u8, observed.identity, path);
                    if (containsWorkspaceIdentity(unseen_sources.items, observed.identity)) {
                        _ = directories.array.orderedRemove(index);
                        changed = true;
                        continue;
                    }
                    if (!try appendUniqueWorkspaceIdentity(arena, &identities, observed.identity)) {
                        _ = directories.array.orderedRemove(index);
                        changed = true;
                        continue;
                    }
                    if (!std.mem.eql(u8, entry.string, observed.identity)) {
                        directories.array.items[index] = .{
                            .string = try arena.dupe(u8, observed.identity),
                        };
                        changed = true;
                    }
                    index += 1;
                }
            }
            for (mutation.command_line_directories) |command_line_path| {
                if (containsWorkspaceIdentity(unseen_sources.items, command_line_path)) continue;
                _ = try appendUniqueWorkspaceIdentity(arena, &identities, command_line_path);
            }
            if (!saved_contains_path) {
                _ = try appendUniqueWorkspaceIdentity(arena, &identities, path);
            }
            const effective_count = std.math.add(usize, identities.items.len, unseen_sources.items.len) catch {
                return error.TooManyDirectories;
            };
            if (effective_count > workspace_access.max_additional_directories) {
                return error.TooManyDirectories;
            }

            if (saved_contains_path) {
                removeWorkspaceIfEmpty(root, mutation.workspace_root);
                return .{ .changed = changed };
            }
            if (existing) |directories| {
                try directories.array.append(.{ .string = try arena.dupe(u8, path) });
            } else {
                var directories = std.json.Array.init(arena);
                try directories.append(.{ .string = try arena.dupe(u8, path) });
                try workspace.put(arena, "additional_directories", .{ .array = directories });
            }
            changed = true;
        },
        .remove => |path| {
            var target_was_saved = false;
            for (mutation.observed_sources) |source| {
                if (std.mem.eql(u8, source.identity, path)) {
                    target_was_saved = true;
                    break;
                }
            }
            if (!target_was_saved) {
                removeWorkspaceIfEmpty(root, mutation.workspace_root);
                return .{};
            }
            const directories = existing orelse {
                removeWorkspaceIfEmpty(root, mutation.workspace_root);
                return .{};
            };
            if (directories.* != .array) return error.InvalidSettingsFormat;
            var survivor_identities: std.ArrayList([]const u8) = .empty;
            defer survivor_identities.deinit(arena);
            var index: usize = 0;
            while (index < directories.array.items.len) {
                const entry = directories.array.items[index];
                if (entry != .string) return error.InvalidSettingsFormat;
                const observed = observedWorkspaceSource(mutation.observed_sources, entry.string) orelse {
                    if (std.mem.eql(u8, entry.string, path)) {
                        _ = directories.array.orderedRemove(index);
                        changed = true;
                        continue;
                    }
                    index += 1;
                    continue;
                };
                if (std.mem.eql(u8, observed.identity, path)) {
                    _ = directories.array.orderedRemove(index);
                    changed = true;
                    continue;
                }
                if (containsWorkspaceIdentity(unseen_sources.items, observed.identity)) {
                    _ = directories.array.orderedRemove(index);
                    changed = true;
                    continue;
                }
                if (!try appendUniqueWorkspaceIdentity(arena, &survivor_identities, observed.identity)) {
                    _ = directories.array.orderedRemove(index);
                    changed = true;
                    continue;
                }
                if (!std.mem.eql(u8, entry.string, observed.identity)) {
                    directories.array.items[index] = .{
                        .string = try arena.dupe(u8, observed.identity),
                    };
                    changed = true;
                }
                index += 1;
            }
            if (directories.array.items.len == 0) _ = workspace.orderedRemove("additional_directories");
        },
        .clear => {
            changed = workspace.orderedRemove("additional_directories");
        },
    }

    removeWorkspaceIfEmpty(root, mutation.workspace_root);
    return .{ .changed = changed };
}

fn unseenWorkspaceSourceStrings(
    arena: Allocator,
    existing: ?*std.json.Value,
    observed_sources: []const workspace_access.SavedSource,
) !std.ArrayList([]const u8) {
    var unseen_sources: std.ArrayList([]const u8) = .empty;
    errdefer unseen_sources.deinit(arena);
    const directories = existing orelse return unseen_sources;
    if (directories.* != .array) return error.InvalidSettingsFormat;
    for (directories.array.items) |entry| {
        if (entry != .string) return error.InvalidSettingsFormat;
        if (observedWorkspaceSource(observed_sources, entry.string) == null) {
            try unseen_sources.append(arena, entry.string);
        }
    }
    return unseen_sources;
}

fn observedWorkspaceSource(
    observed_sources: []const workspace_access.SavedSource,
    source_path: []const u8,
) ?workspace_access.SavedSource {
    for (observed_sources) |source| {
        if (std.mem.eql(u8, source.source, source_path)) return source;
    }
    return null;
}

fn containsWorkspaceIdentity(identities: []const []const u8, identity: []const u8) bool {
    for (identities) |existing| {
        if (std.mem.eql(u8, existing, identity)) return true;
    }
    return false;
}

fn appendUniqueWorkspaceIdentity(
    arena: Allocator,
    identities: *std.ArrayList([]const u8),
    identity: []const u8,
) !bool {
    if (containsWorkspaceIdentity(identities.items, identity)) return false;
    try identities.append(arena, identity);
    return true;
}

fn removeWorkspaceIfEmpty(root: *std.json.Value, workspace_root: []const u8) void {
    const workspaces = root.object.getPtr("workspaces") orelse return;
    if (workspaces.* != .object) return;
    const workspace = workspaces.object.get(workspace_root) orelse return;
    if (workspace != .object or workspace.object.count() != 0) return;
    _ = workspaces.object.orderedRemove(workspace_root);
    if (workspaces.object.count() == 0) _ = root.object.orderedRemove("workspaces");
}

fn applyPermissionMutationToRoot(
    arena: Allocator,
    root: *std.json.Value,
    mutation: PermissionMutation,
) !PatchApplication {
    const target = switch (mutation.scope) {
        .user => &root.object,
        .local => try workspaceObject(arena, root, mutation.workspace_root.?),
    };
    return applyPermissionPatch(arena, target, mutation.patch);
}

fn applyProjectMcpMutationToRoot(
    arena: Allocator,
    root: *std.json.Value,
    mutation: ProjectMcpMutation,
) !PatchApplication {
    const existing_workspace = if (root.object.get("workspaces")) |workspaces|
        if (workspaces == .object) workspaces.object.get(mutation.workspace_root) else null
    else
        null;
    var diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(arena);
        diagnostics.deinit(arena);
    }
    var current = try project_config.parseChoices(arena, existing_workspace, &diagnostics);
    defer current.deinit(arena);
    var transition = try project_config.applyAction(arena, current, mutation.action);
    defer transition.choices.deinit(arena);

    const workspace = try workspaceObject(arena, root, mutation.workspace_root);
    var changed = false;
    if (transition.choices.approved.len == 0) {
        changed = workspace.orderedRemove(project_config.enabled_servers_key) or changed;
    } else {
        changed = try putStringArray(
            arena,
            workspace,
            project_config.enabled_servers_key,
            transition.choices.approved,
        ) or changed;
    }
    if (transition.choices.rejected.len == 0) {
        changed = workspace.orderedRemove(project_config.disabled_servers_key) or changed;
    } else {
        changed = try putStringArray(
            arena,
            workspace,
            project_config.disabled_servers_key,
            transition.choices.rejected,
        ) or changed;
    }
    if (transition.choices.enable_all) {
        changed = try putBool(arena, workspace, project_config.enable_all_key, true) or changed;
    } else {
        changed = workspace.orderedRemove(project_config.enable_all_key) or changed;
    }
    removeWorkspaceIfEmpty(root, mutation.workspace_root);
    return .{
        .changed = changed,
        .authority_reduced = transition.authority_reduced,
    };
}

fn workspaceObject(
    arena: Allocator,
    root: *std.json.Value,
    workspace_root: []const u8,
) !*std.json.ObjectMap {
    var workspaces = if (root.object.getPtr("workspaces")) |value| blk: {
        if (value.* != .object) return error.InvalidSettingsFormat;
        break :blk value;
    } else blk: {
        try root.object.put(arena, "workspaces", .{ .object = .empty });
        break :blk root.object.getPtr("workspaces").?;
    };
    const workspace = if (workspaces.object.getPtr(workspace_root)) |value| blk: {
        if (value.* != .object) return error.InvalidSettingsFormat;
        break :blk value;
    } else blk: {
        const owned_root = try arena.dupe(u8, workspace_root);
        try workspaces.object.put(arena, owned_root, .{ .object = .empty });
        break :blk workspaces.object.getPtr(owned_root).?;
    };
    return &workspace.object;
}

fn putString(arena: Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !bool {
    if (object.get(key)) |existing| {
        if (existing == .string and std.mem.eql(u8, existing.string, value)) return false;
    }
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
    return true;
}

fn putStringArray(
    arena: Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    values: []const []const u8,
) !bool {
    if (object.get(key)) |existing| {
        if (existing == .array and existing.array.items.len == values.len) {
            var equal = true;
            for (existing.array.items, values) |field, value| {
                if (field != .string or !std.mem.eql(u8, field.string, value)) {
                    equal = false;
                    break;
                }
            }
            if (equal) return false;
        }
    }
    var array = std.json.Array.init(arena);
    try array.ensureTotalCapacity(values.len);
    for (values) |value| array.appendAssumeCapacity(.{ .string = try arena.dupe(u8, value) });
    try object.put(arena, key, .{ .array = array });
    return true;
}

fn putModelPreference(
    arena: Allocator,
    root: *std.json.ObjectMap,
    preference: ModelPreferencePatch,
) !bool {
    try validateModel(preference.model);
    var changed = false;
    const models = if (root.getPtr("models")) |value| blk: {
        if (value.* != .object) return error.InvalidSettingsFormat;
        break :blk &value.object;
    } else blk: {
        try root.put(arena, "models", .{ .object = .empty });
        changed = true;
        break :blk &root.getPtr("models").?.object;
    };
    changed = try putString(arena, models, @tagName(preference.provider), preference.model) or changed;
    const legacy_key = switch (preference.provider) {
        .gateway => "model",
        .codex => "codex_model",
        .grok => "grok_model",
    };
    if (root.contains(legacy_key)) {
        _ = root.orderedRemove(legacy_key);
        changed = true;
    }
    return changed;
}

fn putBool(arena: Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !bool {
    if (object.get(key)) |existing| {
        if (existing == .bool and existing.bool == value) return false;
    }
    try object.put(arena, key, .{ .bool = value });
    return true;
}

fn applyPermissionPatch(
    arena: Allocator,
    workspace: *std.json.ObjectMap,
    patch: PermissionPatch,
) !PatchApplication {
    return switch (patch) {
        .add => |add| blk: {
            var permission = try permissionObject(arena, workspace, true) orelse {
                return error.InvalidSettingsFormat;
            };
            var category = if (permission.object.getPtr(add.category)) |value| category_blk: {
                if (value.* == .object) break :category_blk value;
                var replacement = std.json.Value{ .object = .empty };
                try replacement.object.put(arena, "*", value.*);
                try permission.object.put(arena, try arena.dupe(u8, add.category), replacement);
                break :category_blk permission.object.getPtr(add.category).?;
            } else category_blk: {
                try permission.object.put(arena, try arena.dupe(u8, add.category), .{ .object = .empty });
                break :category_blk permission.object.getPtr(add.category).?;
            };
            const action = @tagName(add.action);
            if (category.object.get(add.pattern)) |existing| {
                if (existing == .string and std.mem.eql(u8, existing.string, action)) break :blk .{};
            }
            try category.object.put(arena, try arena.dupe(u8, add.pattern), .{ .string = action });
            break :blk .{ .changed = true };
        },
        .remove => |remove| blk: {
            const permission = try permissionObject(arena, workspace, false) orelse break :blk .{};
            const category_key = canonicalPermissionKey(&permission.object, remove.category) orelse break :blk .{};
            const category = permission.object.getPtr(category_key) orelse break :blk .{};
            if (category.* != .object) break :blk .{};
            const pattern_key = canonicalPermissionKey(&category.object, remove.pattern) orelse break :blk .{};
            _ = category.object.orderedRemove(pattern_key);
            if (category.object.count() == 0) _ = permission.object.orderedRemove(category_key);
            break :blk .{ .changed = true, .permission_rules_removed = 1 };
        },
        .reset => |scope| blk: {
            const permission = try permissionObject(arena, workspace, false) orelse break :blk .{};
            var removed: usize = 0;
            while (removeOneAllowlistRule(&permission.object, scope)) removed += 1;
            if (permission.object.count() == 0) _ = workspace.orderedRemove("permission");
            break :blk .{
                .changed = removed > 0,
                .permission_rules_removed = removed,
            };
        },
    };
}

fn permissionObject(
    arena: Allocator,
    workspace: *std.json.ObjectMap,
    create: bool,
) !?*std.json.Value {
    if (workspace.getPtr("permission")) |value| {
        if (value.* != .object) return error.InvalidSettingsFormat;
        return value;
    }
    if (!create) return null;
    try workspace.put(arena, "permission", .{ .object = .empty });
    return workspace.getPtr("permission").?;
}

fn removeOneAllowlistRule(permission: *std.json.ObjectMap, scope: AllowlistResetScope) bool {
    var it = permission.iterator();
    while (it.next()) |entry| {
        if (!scopeMatchesCategory(scope, entry.key_ptr.*)) continue;
        switch (entry.value_ptr.*) {
            .string => |action| {
                if (!std.ascii.eqlIgnoreCase(action, "allow")) continue;
                _ = permission.orderedRemove(entry.key_ptr.*);
                return true;
            },
            .object => |*category| {
                var category_it = category.iterator();
                while (category_it.next()) |rule| {
                    if (rule.value_ptr.* != .string or
                        !std.ascii.eqlIgnoreCase(rule.value_ptr.string, "allow"))
                    {
                        continue;
                    }
                    _ = category.orderedRemove(rule.key_ptr.*);
                    if (category.count() == 0) _ = permission.orderedRemove(entry.key_ptr.*);
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn scopeMatchesCategory(scope: AllowlistResetScope, category: []const u8) bool {
    const canonical = std.mem.trim(u8, category, " \t\r\n");
    const is_url = std.mem.eql(u8, canonical, "url") or
        std.mem.eql(u8, canonical, "open_url") or
        std.mem.eql(u8, canonical, "browser_navigate");
    const is_fetch = std.mem.eql(u8, canonical, "web_fetch");
    return switch (scope) {
        .all => true,
        .commands => std.mem.eql(u8, canonical, "bash"),
        .urls => is_url,
        .web_fetch_domains => is_fetch,
        .tools => !std.mem.eql(u8, canonical, "bash") and !is_url and !is_fetch and
            !std.mem.eql(u8, canonical, "*"),
    };
}

fn canonicalPermissionKey(object: *const std.json.ObjectMap, expected: []const u8) ?[]const u8 {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(
            u8,
            std.mem.trim(u8, entry.key_ptr.*, " \t\r\n"),
            expected,
        )) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

fn serializeJson(alloc: Allocator, root: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeJsonValue(&out.writer, root);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .string => |string| try std.json.Stringify.value(string, .{}, writer),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            try writer.writeByte('{');
            var first = true;
            var it = object.iterator();
            while (it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .number_string => |number| try writer.writeAll(number),
    }
}

fn validateCandidate(
    alloc: Allocator,
    bytes: []const u8,
    mutation: SettingsMutation,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
        return error.InvalidSettingsFormat;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettingsFormat;
    try validateKnownSettingsObject(parsed.value.object, false);
    const workspace_root = switch (mutation) {
        .user => return,
        .workspace_directory => |workspace| workspace.workspace_root,
        .permission => |permission| switch (permission.scope) {
            .user => return,
            .local => permission.workspace_root.?,
        },
        .project_mcp => |project_mcp| project_mcp.workspace_root,
    };
    const workspace_may_be_absent = switch (mutation) {
        .workspace_directory => |workspace| workspace.patch != .add,
        .project_mcp => |project_mcp| project_mcp.action == .reset,
        else => false,
    };
    const workspaces = parsed.value.object.get("workspaces") orelse {
        if (workspace_may_be_absent) return;
        return error.InvalidSettingsFormat;
    };
    if (workspaces != .object) return error.InvalidSettingsFormat;
    const workspace = workspaces.object.get(workspace_root) orelse {
        if (workspace_may_be_absent) return;
        return error.InvalidSettingsFormat;
    };
    if (workspace != .object) return error.InvalidSettingsFormat;
    try validateKnownSettingsObject(workspace.object, true);
    if (mutation == .project_mcp) {
        var diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty;
        defer {
            for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
            diagnostics.deinit(alloc);
        }
        var choices = project_config.parseChoices(alloc, workspace, &diagnostics) catch
            return error.InvalidSettingsFormat;
        choices.deinit(alloc);
    }
}

fn validateKnownSettingsObject(
    object: std.json.ObjectMap,
    tolerate_non_object_user_containers: bool,
) !void {
    if (object.get("model")) |value| {
        if (value != .string) return error.InvalidSettingsFormat;
        try validateModel(value.string);
    }
    if (object.get("provider")) |value| {
        if (value != .string or model_provider.parse(value.string) == null) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("codex_model")) |value| {
        if (value != .string) return error.InvalidSettingsFormat;
        try validateModel(value.string);
    }
    if (object.get("grok_model")) |value| {
        if (value != .string) return error.InvalidSettingsFormat;
        try validateModel(value.string);
    }
    if (object.get("models")) |value| {
        if (value != .object) return error.InvalidSettingsFormat;
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            const provider = model_provider.parse(entry.key_ptr.*) orelse
                return error.InvalidSettingsFormat;
            if (!std.mem.eql(u8, entry.key_ptr.*, @tagName(provider)) or
                entry.value_ptr.* != .string)
            {
                return error.InvalidSettingsFormat;
            }
            try validateModel(entry.value_ptr.string);
        }
    }
    if (object.get("permission_mode")) |value| {
        if (value != .string or
            (!std.ascii.eqlIgnoreCase(value.string, "ask") and
                !std.ascii.eqlIgnoreCase(value.string, "auto") and
                !std.ascii.eqlIgnoreCase(value.string, "yolo")))
        {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("credential_source")) |value| {
        if (value != .string or types.parseCredentialSource(value.string) == null) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("max_agent_steps")) |value| {
        if (value != .integer or value.integer < 0) return error.InvalidSettingsFormat;
    }
    if (object.get("max_tool_result_bytes")) |value| {
        if (value != .integer or value.integer < tool_result_limits.min_configured_tool_result_bytes) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("skill_match_fuzzy")) |value| {
        if (value != .bool) return error.InvalidSettingsFormat;
    }
    if (object.get("context_limits")) |value| {
        _ = context_limits.parseJsonObject(value) catch return error.InvalidSettingsFormat;
    }
    inline for (&.{ "context", "fast_mode", "auto_upgrade", "slash_menu_categories", "startup_scrollback", "yolo_acknowledged" }) |key| {
        if (object.get(key)) |value| {
            if (value != .bool) return error.InvalidSettingsFormat;
        }
    }
    if (object.get("update_channel")) |value| {
        if (value != .string or update_target.Channel.parse(value.string) == null) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("effort")) |value| {
        switch (value) {
            .null => {},
            .string => |raw| if (types.ReasoningEffort.parse(raw) == null) return error.InvalidSettingsFormat,
            else => return error.InvalidSettingsFormat,
        }
    }
    if (object.get("additional_directories")) |value| {
        if (value != .array or value.array.items.len > workspace_access.max_additional_directories) {
            return error.InvalidSettingsFormat;
        }
        for (value.array.items, 0..) |item, index| {
            if (item != .string) return error.InvalidSettingsFormat;
            const path = item.string;
            if (!validAdditionalDirectoryPath(path)) return error.InvalidSettingsFormat;
            for (value.array.items[0..index]) |previous| {
                if (previous == .string and std.mem.eql(u8, path, previous.string)) {
                    return error.InvalidSettingsFormat;
                }
            }
        }
    }
    if (object.get("prompt_history")) |value| {
        if (value == .object) {
            if (value.object.get("enabled")) |enabled| {
                if (enabled != .bool) return error.InvalidSettingsFormat;
            }
        } else if (!tolerate_non_object_user_containers) {
            return error.InvalidSettingsFormat;
        }
    }
    if (object.get("statusLine")) |value| {
        if (value == .object) {
            inline for (&.{"context"}) |key| {
                if (value.object.get(key)) |enabled| {
                    if (enabled != .bool) return error.InvalidSettingsFormat;
                }
            }
            if (!tolerate_non_object_user_containers) {
                if (value.object.get("workspace")) |enabled| {
                    if (enabled != .bool) return error.InvalidSettingsFormat;
                }
            }
        } else if (!tolerate_non_object_user_containers) {
            return error.InvalidSettingsFormat;
        }
    }
}

fn fingerprintOptional(bytes: ?[]const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    if (bytes) |value| {
        std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    } else {
        std.crypto.hash.sha2.Sha256.hash("absent settings primary", &digest, .{});
    }
    return digest;
}

fn parseSequence(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "settings.json.backup.") and
        !std.mem.startsWith(u8, name, "settings.json.corrupt."))
    {
        return null;
    }
    const first_dash = std.mem.indexOfScalar(u8, name, '-') orelse return null;
    const sequence_start = first_dash + 1;
    if (sequence_start + 16 >= name.len or name[sequence_start + 16] != '-') return null;
    return std.fmt.parseInt(u64, name[sequence_start .. sequence_start + 16], 16) catch null;
}

fn parseBackupTimestamp(name: []const u8) ?i64 {
    const prefixes = [_][]const u8{
        "settings.json.backup.",
        "settings.json.corrupt.",
    };
    var suffix: ?[]const u8 = null;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            suffix = name[prefix.len..];
            break;
        }
    }
    const text = suffix orelse return null;
    const end = std.mem.indexOfScalar(u8, text, '-') orelse text.len;
    if (end == 0) return null;
    return std.fmt.parseInt(i64, text[0..end], 10) catch null;
}

pub fn backupNameNewerThan(lhs: []const u8, rhs: []const u8) bool {
    const lhs_sequence = parseSequence(lhs);
    const rhs_sequence = parseSequence(rhs);
    if (lhs_sequence != null and rhs_sequence != null and lhs_sequence.? != rhs_sequence.?) {
        return lhs_sequence.? > rhs_sequence.?;
    }
    if (lhs_sequence != null and rhs_sequence == null) return true;
    if (lhs_sequence == null and rhs_sequence != null) return false;
    const lhs_timestamp = parseBackupTimestamp(lhs);
    const rhs_timestamp = parseBackupTimestamp(rhs);
    if (lhs_timestamp != null and rhs_timestamp != null and lhs_timestamp.? != rhs_timestamp.?) {
        return lhs_timestamp.? > rhs_timestamp.?;
    }
    return std.mem.order(u8, lhs, rhs) == .gt;
}

fn nextBackupSequence(dir: std.Io.Dir) !u64 {
    var iterator = dir.iterate();
    var maximum: u64 = 0;
    while (try iterator.next(io_mod.getIo())) |entry| {
        const sequence = parseSequence(entry.name) orelse continue;
        maximum = @max(maximum, sequence);
    }
    return std.math.add(u64, maximum, 1) catch error.BackupSequenceExhausted;
}

fn containsCopyWithFingerprint(
    alloc: Allocator,
    dir: std.Io.Dir,
    kind: []const u8,
    bytes: []const u8,
) !bool {
    const expected = fingerprintOptional(bytes);
    const prefix = try std.fmt.allocPrint(alloc, "settings.json.{s}.", .{kind});
    defer alloc.free(prefix);
    var iterator = dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const stat = dir.statFile(io_mod.getIo(), entry.name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file or stat.nlink != 1 or stat.size > max_settings_bytes) continue;
        var file = dir.openFile(io_mod.getIo(), entry.name, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch continue;
        defer file.close(io_mod.getIo());
        const copy = io_mod.readFileToEnd(alloc, &file, max_settings_bytes + 1) catch continue;
        defer alloc.free(copy);
        const copy_fingerprint = fingerprintOptional(copy);
        if (std.mem.eql(u8, &expected, &copy_fingerprint)) return true;
    }
    return false;
}

fn pruneSequencedCopies(
    alloc: Allocator,
    dir: std.Io.Dir,
    kind: []const u8,
    keep_count: usize,
) !void {
    const prefix = try std.fmt.allocPrint(alloc, "settings.json.{s}.", .{kind});
    defer alloc.free(prefix);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix) or parseBackupTimestamp(entry.name) == null) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    sort_utils.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return backupNameNewerThan(lhs, rhs);
        }
    }.lessThan);
    if (names.items.len <= keep_count) return;
    var deleted = false;
    for (names.items[keep_count..]) |name| {
        const stat = dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch continue;
        if (stat.kind != .file or stat.nlink != 1) continue;
        dir.deleteFile(io_mod.getIo(), name) catch |err| {
            debug_trace.logf("config", "settings backup prune skipped err={s}", .{@errorName(err)});
            continue;
        };
        deleted = true;
    }
    if (deleted) try io_mod.syncVerifiedDir(dir);
}

fn writeStoreFixture(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}
