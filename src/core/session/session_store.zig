const std = @import("std");
const builtin = @import("builtin");
const config_runtime = @import("../config/config_runtime.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const core_types = @import("../shared/types.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const artifact_digest = @import("artifact_digest.zig");
const command_replay_store = @import("command_replay_store.zig");
const result_store = @import("result_store.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_child_store = @import("session_child_store.zig");
const relationship_index_codec = @import("session_relationship_index_codec.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
const session_layout = @import("session_layout.zig");
const session_log = @import("session_log.zig");
const session_projection = @import("session_projection.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_usage = @import("session_usage.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const discovery = @import("session_discovery.zig");
const latest_pointer = @import("session_latest_pointer.zig");
const migration = @import("session_migration.zig");
const paths = @import("session_store_paths.zig");
const store_types = @import("session_store_types.zig");
const summary_codec = @import("session_summary_codec.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const authorityTransitionsEqual = authority_module.authorityTransitionsEqual;
const classifyAuthority = authority_module.classifyAuthority;
const classifyAuthorityAllowingLargeLegacy = authority_module.classifyAuthorityAllowingLargeLegacy;
const deleteSessionEntry = authority_module.deleteSessionEntry;
const loadAuthorityTransitionOptional = authority_module.loadAuthorityTransitionOptional;
const mapReplayError = authority_module.mapReplayError;
const openSessionFile = authority_module.openSessionFile;
const readExactLegacyFile = authority_module.readExactLegacyFile;
const requireAuthorityFenceAbsent = authority_module.requireAuthorityFenceAbsent;
const requireAuthorityTransitionSession = authority_module.requireAuthorityTransitionSession;
const restoreLegacyAuthority = authority_module.restoreLegacyAuthority;
const DiscoveryCandidateMetadata = discovery.DiscoveryCandidateMetadata;
const DiscoveryMode = discovery.DiscoveryMode;
const ReadOnlyCandidate = discovery.ReadOnlyCandidate;
const WritableCandidate = discovery.WritableCandidate;
const appendDoctorDiagnostic = discovery.appendDoctorDiagnostic;
const classifyLegacyCandidate = discovery.classifyLegacyCandidate;
const classifyReadOnlyCandidate = discovery.classifyReadOnlyCandidate;
const classifySchemaV3Candidate = discovery.classifySchemaV3Candidate;
const dupeWritableCandidate = discovery.dupeWritableCandidate;
const freeDoctorDiagnostics = discovery.freeDoctorDiagnostics;
const inspectDoctorSession = discovery.inspectDoctorSession;
const logDiscovery = discovery.logDiscovery;
const logDiscoveryError = discovery.logDiscoveryError;
const storageFormatForLegacy = discovery.storageFormatForLegacy;
const summaryFromState = discovery.summaryFromState;
const writableCandidateNewer = discovery.writableCandidateNewer;
const InitialIndexEffect = latest_pointer.InitialIndexEffect;
const LatestCache = latest_pointer.LatestCache;
const LatestPointer = latest_pointer.LatestPointer;
const latestCacheAbort = latest_pointer.latestCacheAbort;
const latestCacheDeinit = latest_pointer.latestCacheDeinit;
const latestCachePrepare = latest_pointer.latestCachePrepare;
const latestCachePublish = latest_pointer.latestCachePublish;
const latestCacheWriteDeferred = latest_pointer.latestCacheWriteDeferred;
const latest_sessions_lock_file = latest_pointer.latest_sessions_lock_file;
const latest_sessions_dir = latest_pointer.latest_sessions_dir;
const recovery_staging_dir = "recovery+staging";
const recovery_staging_lock_file = "recovery-staging.lock";
const usage_recovery_dir = profile_paths.usage_recovery_dir_name;
const usage_recovery_marker_prefix = "v1 ";
const max_usage_recovery_marker_bytes =
    usage_recovery_marker_prefix.len + 20 + 1;
const max_usage_recovery_sessions: usize = 512;
const synchronous_display_metadata_replay_max_bytes: u64 = 1024 * 1024;
const readLatestPointerFromSessions = latest_pointer.readLatestPointerFromSessions;
const readPendingLatestSessionIdFromSessions = latest_pointer.readPendingLatestSessionIdFromSessions;
const LegacyStoredSession = migration.LegacyStoredSession;
const MigrationPreferenceSource = migration.MigrationPreferenceSource;
const legacyToDurableState = migration.legacyToDurableState;
const loadedMigrationTarget = migration.loadedMigrationTarget;
const migrateLegacyLocked = migration.migrateLegacyLocked;
const migratedSourceBytes = migration.migratedSourceBytes;
const migratedSourceSchemaVersion = migration.migratedSourceSchemaVersion;
const validateMigrationTarget = migration.validateMigrationTarget;
const normalizeWorkspaceRoot = paths.normalizeWorkspaceRoot;
pub const sessionDirPath = paths.sessionDirPath;
const sessionJsonPath = paths.sessionJsonPath;
const session_list_json_file = paths.session_list_json_file;
const session_summary_file = paths.session_summary_file;
const summaryPath = paths.summaryPath;
pub const validateSessionId = paths.validateSessionId;
const validateWorkspaceRoot = paths.validateWorkspaceRoot;
pub const generateSessionId = paths.generateSessionId;
pub const CandidateStorage = store_types.CandidateStorage;
pub const DiscoveryCause = store_types.DiscoveryCause;
pub const DoctorDiagnostic = store_types.DoctorDiagnostic;
pub const DoctorInspectionResult = store_types.DoctorInspectionResult;
const DoctorInspectionOptions = store_types.DoctorInspectionOptions;
pub const DoctorIssueKind = store_types.DoctorIssueKind;
pub const LoadedWritableSession = store_types.LoadedWritableSession;
pub const MigrationOptions = store_types.MigrationOptions;
pub const ProjectionState = store_types.ProjectionState;

pub const UsageRecoverySession = struct {
    id: []u8,
    protected_updated_at_ms: ?i64,

    pub fn deinit(self: *UsageRecoverySession, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }
};

pub const UsageRecoveryCheckpoint = struct {
    recovery_pending: bool,
    timestamp_ms: i64,
};

pub fn imageSnapshotStorageDir(
    alloc: Allocator,
    sessions_dir: ?[]const u8,
    session_id: ?[]const u8,
    temp_dir: *?[]u8,
) ![]u8 {
    if ((sessions_dir == null) != (session_id == null)) return error.InvalidSessionSnapshotOwner;
    if (sessions_dir) |root| {
        const durable_dir = try sessionDirPath(alloc, root, session_id.?);
        defer alloc.free(durable_dir);
        return std.fs.path.join(alloc, &.{ durable_dir, "images" });
    }
    if (temp_dir.* == null) {
        temp_dir.* = try image_attachments.createTempSnapshotDir(alloc);
    }
    return alloc.dupe(u8, temp_dir.*.?);
}
pub const ReadOnlyDetail = store_types.ReadOnlyDetail;
pub const ResumeOptions = store_types.ResumeOptions;
pub const ResumeTarget = store_types.ResumeTarget;
pub const ResumeViewAdmission = session_log.ResumeViewAdmission;
pub const SessionMigrationResult = store_types.SessionMigrationResult;
pub const SessionMigrationStatus = store_types.SessionMigrationStatus;
pub const SessionRecoveryResult = store_types.SessionRecoveryResult;
pub const SessionRecoveryStatus = store_types.SessionRecoveryStatus;
pub const SessionSummary = store_types.SessionSummary;
pub const HistoryPage = store_types.HistoryPage;

pub const LoadHistoryPageError = error{
    OutOfMemory,
    InvalidSessionId,
    InvalidHistoryPageLimit,
    InvalidHistoryPageCursor,
    StaleHistoryPageCursor,
    SessionNotFound,
    SessionPathUnsafe,
    SessionStoreUnavailable,
    UnsupportedSessionFormat,
    CorruptSession,
};

const HistoryPageCursor = struct {
    session_id: []const u8,
    history_len: usize,
    revision_ms: i64,
    prefix_digest: [32]u8,
    start: usize,
};

fn parseHistoryPageCursor(raw: []const u8) LoadHistoryPageError!HistoryPageCursor {
    if (raw.len == 0 or raw.len > 512) return error.InvalidHistoryPageCursor;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidHistoryPageCursor, "v2")) return error.InvalidHistoryPageCursor;
    const session_id = fields.next() orelse return error.InvalidHistoryPageCursor;
    const history_len = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    const revision_ms = std.fmt.parseInt(i64, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    const digest_hex = fields.next() orelse return error.InvalidHistoryPageCursor;
    const start = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidHistoryPageCursor, 10) catch return error.InvalidHistoryPageCursor;
    if (fields.next() != null) return error.InvalidHistoryPageCursor;
    if (digest_hex.len != 64 or revision_ms < 0 or start > history_len) return error.InvalidHistoryPageCursor;
    validateSessionId(session_id) catch return error.InvalidHistoryPageCursor;
    var prefix_digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&prefix_digest, digest_hex) catch return error.InvalidHistoryPageCursor;
    const cursor: HistoryPageCursor = .{ .session_id = session_id, .history_len = history_len, .revision_ms = revision_ms, .prefix_digest = prefix_digest, .start = start };
    var canonical: [512]u8 = undefined;
    const encoded = formatHistoryPageCursor(&canonical, cursor) catch return error.InvalidHistoryPageCursor;
    if (!std.mem.eql(u8, raw, encoded)) return error.InvalidHistoryPageCursor;
    return cursor;
}

fn formatHistoryPageCursor(buffer: []u8, cursor: HistoryPageCursor) ![]u8 {
    return std.fmt.bufPrint(buffer, "v2:{s}:{d}:{d}:{x}:{d}", .{ cursor.session_id, cursor.history_len, cursor.revision_ms, cursor.prefix_digest, cursor.start });
}

fn duplicateHistoryPage(alloc: Allocator, turns: []const session.HistoryTurn) ![]session.HistoryTurn {
    const copy = try alloc.alloc(session.HistoryTurn, turns.len);
    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(copy);
    }
    for (turns) |turn| {
        copy[copied] = try session.dupeHistoryTurn(alloc, turn);
        copied += 1;
    }
    return copy;
}

fn historyPrefixDigest(turns: []const session.HistoryTurn) error{ WriteFailed, NoSpaceLeft }![32]u8 {
    var buffer: [256]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buffer);
    try hashing.writer.writeAll("fx.history-page-prefix.v2\x00");
    for (turns) |turn| {
        try session_codec.writeHistoryTurn(&hashing.writer, turn);
        // Canonical JSON never contains a literal NUL, so this makes the
        // concatenation unambiguous without introducing another serializer.
        try hashing.writer.writeByte(0);
    }
    try hashing.writer.flush();
    return hashing.hasher.finalResult();
}

fn mapHistoryPageLoadError(err: anyerror) LoadHistoryPageError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId => error.InvalidSessionId,
        error.SessionNotFound => error.SessionNotFound,
        error.SessionPathUnsafe => error.SessionPathUnsafe,
        error.UnsupportedSessionFormat, error.UnsupportedSessionSchema => error.UnsupportedSessionFormat,
        error.InvalidSessionFormat,
        error.InvalidDurableField,
        error.InvalidDurableBytes,
        error.InvalidSessionIndex,
        => error.CorruptSession,
        // `loadReadOnly` intentionally has an inferred upstream error set.
        // Its uncategorized I/O and replay failures are unavailable storage,
        // never evidence that the committed session itself is corrupt.
        else => error.SessionStoreUnavailable,
    };
}

const HistoryPageWindow = struct {
    start: usize,
    end: usize,
};

fn selectHistoryPageWindow(history_len: usize, exclusive_end: usize, limit: usize) HistoryPageWindow {
    std.debug.assert(exclusive_end <= history_len);
    return .{ .start = exclusive_end -| limit, .end = exclusive_end };
}
pub const OpenSubagentControlError = error{
    OutOfMemory,
    InvalidSessionId,
    SessionNotFound,
    SessionPathUnsafe,
    SessionStoreUnavailable,
    PrivateStatePermissionsUnsupported,
    SessionChildStoreFailed,
};
pub const LoadSubagentBootstrapError = error{
    OutOfMemory,
    InvalidSessionId,
    SessionNotFound,
    SessionPathUnsafe,
    SessionMetadataUnavailable,
};
pub const ListSubagentControlIdsError = error{
    OutOfMemory,
    SessionStoreUnavailable,
};
pub const SubagentBootstrapMetadata = struct {
    name: []u8,
    preferences: session_codec.DurableSessionPreferences,

    pub fn deinit(self: *SubagentBootstrapMetadata, alloc: Allocator) void {
        alloc.free(self.name);
        self.preferences.deinit(alloc);
        self.* = undefined;
    }
};
pub const ResumableSessionContinuation = store_types.ResumableSessionContinuation;
pub const ResumableSessionPage = store_types.ResumableSessionPage;
pub const SessionListScope = store_types.SessionListScope;
pub const SessionListPage = store_types.SessionListPage;
pub const session_list_default_limit: usize = 100;
pub const session_list_max_limit: usize = 100;
pub const ListWorkspacePageError = error{
    OutOfMemory,
    InvalidSessionListLimit,
    SessionStoreUnavailable,
};
pub const RelationshipMigrationCursor = summary_codec.RelationshipMigrationCursor;
pub const RelationshipMigrationCandidatePage =
    summary_codec.RelationshipMigrationCandidatePage;
pub const relationship_migration_candidate_limit =
    summary_codec.relationship_migration_candidate_limit;
const ResumableSessionScope = enum {
    all_workspaces,
    current_workspace,
};
pub const StateSummary = store_types.StateSummary;
pub const StorageFormat = store_types.StorageFormat;
const automatic_legacy_max_bytes = store_types.automatic_legacy_max_bytes;
const max_session_bytes = store_types.max_session_bytes;
const StoreContext = store_types.StoreContext;
const freeSummaries = summary_codec.freeSummaries;
const readSessionStateSummary = summary_codec.readSessionStateSummary;
const readSessionIndex = summary_codec.readSessionIndex;
const readSessionIndexWorkspaceCandidates = summary_codec.readSessionIndexWorkspaceCandidates;
const removeSessionIndexMarker = summary_codec.removeSessionIndexMarker;
const resumablePageFromSummaries = summary_codec.resumablePageFromSummaries;
const sessionListPageFromSummaries = summary_codec.sessionListPageFromSummaries;
const sortSummariesNewestFirst = summary_codec.sortSummariesNewestFirst;
const writeSessionIndex = summary_codec.writeSessionIndex;

const SessionSummaryScan = struct {
    summaries: std.ArrayList(SessionSummary) = .empty,
    skipped_invalid: usize = 0,

    fn deinit(self: *SessionSummaryScan, alloc: Allocator) void {
        freeSummaries(alloc, &self.summaries);
        self.* = undefined;
    }
};

const DeferredReplayScope = union(enum) {
    tokens: std.ArrayList(summary_codec.DeferredCacheToken),
    all,

    fn deinit(self: *DeferredReplayScope, alloc: Allocator) void {
        switch (self.*) {
            .tokens => |*tokens| summary_codec.freeDeferredCacheTokens(alloc, tokens),
            .all => {},
        }
        self.* = undefined;
    }
};

fn tokenScopeRequiresCanonicalReplay(
    scope: DeferredReplayScope,
    session_id: []const u8,
) bool {
    return switch (scope) {
        .all => true,
        .tokens => |tokens| for (tokens.items) |token| {
            if (std.mem.eql(u8, token.session_id, session_id)) break true;
        } else false,
    };
}

fn readOnlyScopeRequiresCanonicalReplay(
    scope: DeferredReplayScope,
    session_id: []const u8,
    projection_state: ProjectionState,
) bool {
    return switch (scope) {
        .all => true,
        .tokens => |tokens| tokens.items.len > 0 and
            (projection_state == .stale or
                tokenScopeRequiresCanonicalReplay(scope, session_id)),
    };
}

fn testDeferredCacheToken(session_id: []const u8) summary_codec.DeferredCacheToken {
    return .{
        .session_id = @constCast(session_id),
        .workspace_root = @constCast("/tmp/workspace"),
        .position = .{
            .log_generation = [_]u8{0x11} ** 16,
            .through_seq = 2,
            .through_event_id = [_]u8{0x22} ** 16,
            .through_event_log_bytes = 100,
        },
    };
}

fn retainWorkspaceSummaries(alloc: Allocator, summaries: *std.ArrayList(SessionSummary), workspace_root: []const u8) void {
    var write_index: usize = 0;
    for (summaries.items, 0..) |*summary, read_index| {
        const summary_workspace = summary.workspace_root orelse {
            summary.deinit(alloc);
            continue;
        };
        if (!std.mem.eql(u8, summary_workspace, workspace_root)) {
            summary.deinit(alloc);
            continue;
        }
        if (write_index != read_index) summaries.items[write_index] = summary.*;
        write_index += 1;
    }
    summaries.items.len = write_index;
}

fn summariesMissingDisplayMetadata(summaries: []const SessionSummary) bool {
    for (summaries) |summary| {
        if (summaryNeedsDisplayMetadata(summary)) return true;
    }
    return false;
}

fn summaryNeedsDisplayMetadata(summary: SessionSummary) bool {
    if (summary.history_len == 0) return false;
    if (!summary.display_metadata_present) return true;
    return summary.title == null;
}

fn initialIndexEffect(state: session_codec.DurableSessionState) InitialIndexEffect {
    return if (state.history.len == 0) .preserve else .maintain;
}

pub const default_resume_page_limit: usize = 10;

fn openUsageRecoveryProfileRoot(
    home_path: []const u8,
) !?io_mod.VerifiedDir {
    const zio = io_mod.getIo();
    var home = try std.Io.Dir.openDirAbsolute(zio, home_path, .{
        .iterate = true,
    });
    defer home.close(zio);
    var profile = home.openDir(zio, profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
        else => return err,
    };
    errdefer profile.close(zio);
    const stat = try profile.stat(zio);
    if (stat.kind != .directory or
        stat.permissions.toMode() & 0o777 != 0o700)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    return .{ .dir = profile };
}

fn openUsageRecoveryDir(
    home_path: []const u8,
) !?io_mod.VerifiedDir {
    var profile = try openUsageRecoveryProfileRoot(home_path) orelse return null;
    defer profile.close();
    var dir = profile.dir.openDir(io_mod.getIo(), usage_recovery_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
        else => return err,
    };
    errdefer dir.close(io_mod.getIo());
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or
        stat.permissions.toMode() & 0o777 != 0o700)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    return .{ .dir = dir };
}

fn validateUsageRecoveryMarker(
    recovery: *const io_mod.VerifiedDir,
    session_id: []const u8,
) !?i64 {
    var marker = recovery.dir.openFile(io_mod.getIo(), session_id, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.UsageRecoveryMarkerNotFound,
        else => return error.InvalidUsageRecoveryIndex,
    };
    defer marker.close(io_mod.getIo());
    const stat = try marker.stat(io_mod.getIo());
    if (stat.kind != .file or
        stat.nlink != 1 or
        stat.size == 0 or
        stat.size > max_usage_recovery_marker_bytes or
        stat.permissions.toMode() & 0o777 != 0o600)
    {
        return error.InvalidUsageRecoveryIndex;
    }
    var bytes: [max_usage_recovery_marker_bytes]u8 = undefined;
    const marker_len: usize = @intCast(stat.size);
    const read = marker.readPositionalAll(
        io_mod.getIo(),
        bytes[0..marker_len],
        0,
    ) catch return error.InvalidUsageRecoveryIndex;
    if (read != marker_len) {
        return error.InvalidUsageRecoveryIndex;
    }
    const marker_bytes = bytes[0..marker_len];
    if (!std.mem.startsWith(
        u8,
        marker_bytes,
        usage_recovery_marker_prefix,
    ) or !std.mem.endsWith(u8, marker_bytes, "\n")) {
        return error.InvalidUsageRecoveryIndex;
    }
    const timestamp_bytes = marker_bytes[usage_recovery_marker_prefix.len .. marker_bytes.len - 1];
    if (timestamp_bytes.len == 0) return error.InvalidUsageRecoveryIndex;
    const timestamp_ms = std.fmt.parseInt(
        i64,
        timestamp_bytes,
        10,
    ) catch return error.InvalidUsageRecoveryIndex;
    if (timestamp_ms < 0) return error.InvalidUsageRecoveryIndex;
    return timestamp_ms;
}

pub const Store = struct {
    sessions_dir: []u8,
    home_dir: []u8,
    workspace_root: []u8,
    canonical_root: session_log.Root,
    // How many sessions one resume page yields before flagging `has_more`.
    // Carried on the value so it propagates through the by-value page chain;
    // the UI sets it from the visible screen height.
    resume_page_limit: usize = default_resume_page_limit,

    /// Narrow, copyable view of this store for the discovery/migration helpers,
    /// so they depend on `StoreContext` instead of the full facade.
    fn ctx(self: Store) StoreContext {
        return .{
            .sessions_dir = self.sessions_dir,
            .home_dir = self.home_dir,
            .workspace_root = self.workspace_root,
            .canonical_root = self.canonical_root,
        };
    }

    /// Opens a writable store rooted at `$HOME`, creating the layout if needed.
    pub fn init(alloc: Allocator, workspace_root: []const u8) !Store {
        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        return initWithHome(alloc, home, workspace_root, true);
    }

    /// Opens a read-only store rooted at `$HOME`; never creates layout.
    pub fn initReadOnly(alloc: Allocator, workspace_root: []const u8) !Store {
        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        return initWithHome(alloc, home, workspace_root, false);
    }

    /// Read-only store with an injected home directory (tests / non-HOME callers).
    pub fn initReadOnlyFromHome(
        alloc: Allocator,
        home_dir: []const u8,
        workspace_root: []const u8,
    ) !Store {
        return initWithHome(alloc, home_dir, workspace_root, false);
    }

    /// Opens the store using an injected home directory for tests.
    /// Writable store with an injected home directory (tests).
    pub fn initFromHome(alloc: Allocator, home_dir: []const u8, workspace_root: []const u8) !Store {
        return initWithHome(alloc, home_dir, workspace_root, true);
    }

    /// Frees store path strings.
    /// Frees the store path strings and the canonical root.
    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.canonical_root.deinit(alloc);
        alloc.free(self.sessions_dir);
        alloc.free(self.home_dir);
        alloc.free(self.workspace_root);
        self.* = undefined;
    }

    /// Starts a brand-new writable session from `state`, with default log options.
    pub fn startWritableSession(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
    ) !LoadedWritableSession {
        return self.startWritableSessionWithOptions(alloc, state, .{});
    }

    /// Starts a new writable session, attaching the latest-pointer lifecycle and
    /// the writable managed-child capability. Caller owns the returned session.
    pub fn startWritableSessionWithOptions(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        options: session_log.Options,
    ) !LoadedWritableSession {
        var root = self.canonical_root;
        const lifecycle = try self.makeLatestCacheLifecycle(
            alloc,
            initialIndexEffect(state),
            options.test_controls,
        );
        var loaded = try root.startWritableSessionWithLifecycle(
            alloc,
            state,
            options,
            lifecycle,
        );
        errdefer loaded.deinit(alloc);
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn startRecoveryStagedSession(
        self: Store,
        alloc: Allocator,
        staging_root: *session_log.Root,
        state: session_codec.DurableSessionState,
        options: session_log.Options,
    ) !LoadedWritableSession {
        var loaded = try staging_root.startWritableSessionWithLifecycle(
            alloc,
            state,
            options,
            null,
        );
        errdefer loaded.deinit(alloc);
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn initRecoveryStagingRoot(
        self: Store,
        alloc: Allocator,
    ) !session_log.Root {
        var root = self.canonical_root;
        const sessions = &(root.sessions orelse
            return error.SessionStoreUnavailable);
        var staging = try io_mod.openOrCreateVerifiedPrivateDir(
            sessions,
            recovery_staging_dir,
        );
        errdefer staging.close();
        return .{
            .sessions = staging,
            .display_root = try std.fs.path.join(
                alloc,
                &.{ self.sessions_dir, recovery_staging_dir },
            ),
            .mode = .writable,
        };
    }

    fn deinitRecoveryStagingRoot(
        self: Store,
        alloc: Allocator,
        staging_root: *session_log.Root,
    ) void {
        staging_root.deinit(alloc);
        const sessions = &(self.canonical_root.sessions orelse return);
        sessions.dir.deleteDir(
            io_mod.getIo(),
            recovery_staging_dir,
        ) catch return;
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_cleanup disposition=indeterminate err={s}",
                .{@errorName(err)},
            );
        };
    }

    fn acquireRecoveryStagingLock(
        self: Store,
        deadline_ms: u64,
    ) !io_mod.TimedAdvisoryLock {
        var root = self.canonical_root;
        const sessions = &(root.sessions orelse
            return error.SessionStoreUnavailable);
        return io_mod.acquireTimedAdvisoryLock(
            sessions,
            recovery_staging_lock_file,
            deadline_ms,
        ) catch |err| switch (err) {
            error.LockBusy => error.SessionBusy,
            error.LockUnsupported => error.SessionLockUnsupported,
            else => return err,
        };
    }

    fn cleanupAbandonedRecoveryStages(
        staging_root: *session_log.Root,
    ) !void {
        const staging = &(staging_root.sessions orelse
            return error.SessionStoreUnavailable);
        var entries = staging.dir.iterate();
        var changed = false;
        while (try entries.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            validateSessionId(entry.name) catch continue;
            try staging.dir.deleteTree(io_mod.getIo(), entry.name);
            changed = true;
            debug_trace.logf(
                "session",
                "event=recovery_staging_abandoned_target_removed",
                .{},
            );
        }
        if (changed) try io_mod.syncVerifiedDir(staging.dir);
    }

    fn promoteRecoveryStagedSession(
        self: Store,
        staging_root: *session_log.Root,
        session_id: []const u8,
    ) !RecoveryPromotionStatus {
        const staging = &(staging_root.sessions orelse
            return error.SessionStoreUnavailable);
        const sessions = &(self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable);
        try staging.dir.rename(
            session_id,
            sessions.dir,
            session_id,
            io_mod.getIo(),
        );
        io_mod.syncVerifiedDir(sessions.dir) catch
            return .indeterminate;
        io_mod.syncVerifiedDir(staging.dir) catch
            return .indeterminate;
        return .promoted;
    }

    /// Consumes `loaded` on every return.
    fn discardRecoveryStagedSession(
        staging_root: *session_log.Root,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        defer loaded.deinit(alloc);
        if (staging_root.mode != .writable or
            loaded.commit_lifecycle != null)
        {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=guard_failed",
                .{},
            );
            return .retained;
        }
        const writer_belongs_to_store = loadedWriterBelongsToRoot(
            alloc,
            loaded,
            staging_root.display_root,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=store_root_unverified err={s}",
                .{@errorName(err)},
            );
            return .retained;
        };
        if (!writer_belongs_to_store) {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=retained reason=store_root_mismatch",
                .{},
            );
            return .retained;
        }
        const sessions = &(staging_root.sessions orelse {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=sessions_root",
                .{},
            );
            return .indeterminate;
        });
        sessions.dir.deleteTree(io_mod.getIo(), loaded.active_id) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=delete err={s}",
                .{@errorName(err)},
            );
            return .indeterminate;
        };
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event=recovery_staging_discard disposition=indeterminate stage=sync err={s}",
                .{@errorName(err)},
            );
            return .indeterminate;
        };
        debug_trace.logf(
            "session",
            "event=recovery_staging_discard disposition=discarded",
            .{},
        );
        return .discarded;
    }

    /// Consumes `loaded` on every return. A confirmed result means the canonical
    /// session directory was removed and the sessions parent was synced.
    pub fn discardPristineStartedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        if (!isPristineStartedSession(loaded)) {
            loaded.deinit(alloc);
            debug_trace.logf(
                "session",
                "event=pristine_session_discard disposition=retained reason=guard_failed",
                .{},
            );
            return .retained;
        }
        return self.deleteWriterOwnedSession(
            alloc,
            loaded,
            "pristine_session_discard",
        );
    }

    /// Consumes an exact writable session on every return. Policy checks such
    /// as terminal one-off admission remain with the caller that owns them.
    pub fn deleteCommittedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) PristineDiscardDisposition {
        return self.deleteWriterOwnedSession(
            alloc,
            loaded,
            "committed_session_delete",
        );
    }

    fn deleteWriterOwnedSession(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
        event_name: []const u8,
    ) PristineDiscardDisposition {
        defer loaded.deinit(alloc);
        if (self.canonical_root.mode != .writable or
            !std.mem.eql(u8, self.workspace_root, loaded.state.workspace_root))
        {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=guard_failed",
                .{event_name},
            );
            return .retained;
        }
        const writer_belongs_to_store = loadedWriterBelongsToStore(
            self,
            alloc,
            loaded,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=store_root_unverified err={s}",
                .{ event_name, @errorName(err) },
            );
            return .retained;
        };
        if (!writer_belongs_to_store) {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=store_root_mismatch",
                .{event_name},
            );
            return .retained;
        }
        const lifecycle = if (loaded.commit_lifecycle) |*value| value else {
            debug_trace.logf(
                "session",
                "event={s} disposition=retained reason=cache_lifecycle_unavailable",
                .{event_name},
            );
            return .retained;
        };
        const sessions = &(self.canonical_root.sessions orelse {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=sessions_root",
                .{event_name},
            );
            return .indeterminate;
        });
        const log_options: session_log.Options = .{};
        lifecycle.prepare(
            alloc,
            loaded.active_id,
            loaded.state.workspace_root,
            loaded.state.workspace_root,
            log_options.commit_lock_deadline_ms,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=cache_pending err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        sessions.dir.deleteTree(io_mod.getIo(), loaded.active_id) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=delete err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        io_mod.syncVerifiedDir(sessions.dir) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=sync err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        latest_pointer.removeDeferredToken(
            sessions,
            loaded.active_id,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event={s} disposition=indeterminate stage=deferred_token_cleanup err={s}",
                .{ event_name, @errorName(err) },
            );
            return .indeterminate;
        };
        debug_trace.logf(
            "session",
            "event={s} disposition=discarded",
            .{event_name},
        );
        return .discarded;
    }

    /// Resumes a specific session by id for writing, rebinding it to this store's
    /// workspace if needed.
    pub fn resumeForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !LoadedWritableSession {
        return self.resumeTargetForWrite(
            alloc,
            .{ .id = session_id },
            self.workspace_root,
            .{},
        );
    }

    pub fn admitResumeView(
        self: Store,
        alloc: Allocator,
        target: ResumeTarget,
    ) !?ResumeViewAdmission {
        var root = self.canonical_root;
        return switch (target) {
            .id => |id| try root.admitResumeView(alloc, id),
            .last => blk: {
                if (self.deferredCacheInvalidatesReads()) {
                    var latest = try self.latestReadOnlyWorkspaceSummary(alloc);
                    defer latest.deinit(alloc);
                    break :blk try root.admitResumeView(
                        alloc,
                        latest.id,
                    );
                }
                var latest = (try readLatestPointer(self, alloc, self.workspace_root)) orelse
                    return null;
                defer latest.deinit(alloc);
                break :blk try root.admitResumeView(
                    alloc,
                    latest.session_id,
                );
            },
        };
    }

    /// Resumes a target (a specific id, or the latest) for writing under
    /// `workspace_root`, migrating legacy storage and recovering interrupted
    /// authority transitions as needed. Caller owns the returned session.
    pub fn resumeTargetForWrite(
        self: Store,
        alloc: Allocator,
        target: ResumeTarget,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try validateWorkspaceRoot(workspace_root);
        const loaded = switch (target) {
            .id => |session_id| try self.resumeExactForWrite(
                alloc,
                session_id,
                workspace_root,
                true,
                options,
            ),
            .last => try self.resumeLatestForWrite(alloc, workspace_root, options),
        };
        return self.finishResumedForWrite(alloc, loaded, options);
    }

    pub fn resumeAdmittedForWrite(
        self: Store,
        alloc: Allocator,
        admission: *ResumeViewAdmission,
        expected_session_id: []const u8,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try validateWorkspaceRoot(workspace_root);
        if (!std.mem.eql(u8, admission.sessionId(), expected_session_id)) {
            return error.SessionTargetChanged;
        }
        const loaded = try admission.resumeForWrite(alloc, options.log);
        const rebound = try self.finishWorkspaceResume(
            alloc,
            loaded,
            workspace_root,
            true,
            options,
        );
        return self.finishResumedForWrite(alloc, rebound, options);
    }

    fn finishResumedForWrite(
        self: Store,
        alloc: Allocator,
        loaded_value: LoadedWritableSession,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded = loaded_value;
        errdefer loaded.deinit(alloc);
        const needs_permission_migration =
            loaded.state.permission_state.version !=
            session_permission_state.schema_version;
        if (needs_permission_migration) {
            const migrated_permission_state = try session_permission_state.migrateV1ToV2(
                alloc,
                loaded.state.permission_state,
            );
            loaded.state.permission_state.deinit(alloc);
            loaded.state.permission_state = migrated_permission_state;
        }
        var migration_state = try loaded.state.dupe(alloc);
        defer migration_state.deinit(alloc);
        const session_dir = try sessionDirPath(
            alloc,
            self.sessions_dir,
            loaded.active_id,
        );
        defer alloc.free(session_dir);
        const snapshot_dir = try std.fs.path.join(alloc, &.{ session_dir, "images" });
        defer alloc.free(snapshot_dir);
        const needs_image_migration = try session.repair_legacy_images_transactionally(
            alloc,
            migration_state.history,
            snapshot_dir,
        );
        const needs_migration_commit = needs_permission_migration or
            needs_image_migration;
        if (needs_migration_commit) {
            var migration_committed = false;
            errdefer if (!migration_committed) {
                deleteSnapshotFilesAddedByMigration(
                    migration_state.history,
                    loaded.state.history,
                );
            };
            _ = try loaded.commitStateReplacement(
                alloc,
                migration_state,
                .migration,
                .rollback_before_adapter_continue,
                options.log,
            );
            migration_committed = true;
            std.mem.swap(
                session_codec.DurableSessionState,
                &loaded.state,
                &migration_state,
            );
        }
        try self.attachWritableChildCapability(alloc, &loaded);
        return loaded;
    }

    fn resumeLatestForWrite(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        if (self.deferredCacheInvalidatesReads()) {
            return self.resumeLatestDiscoveryAfterBarrier(
                alloc,
                workspace_root,
                options,
            );
        }
        const cached = readLatestPointer(self, alloc, workspace_root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (cached) |pointer_value| {
            var pointer = pointer_value;
            defer pointer.deinit(alloc);
            var loaded = self.resumeExactForWrite(
                alloc,
                pointer.session_id,
                workspace_root,
                false,
                options,
            ) catch |cached_error| {
                if (!try latestPointerStillMatches(self, alloc, workspace_root, pointer)) {
                    return self.resumeLatestByDiscovery(alloc, workspace_root, options);
                }
                return switch (cached_error) {
                    error.SessionNotFound,
                    error.SessionTargetChanged,
                    error.InvalidSessionFormat,
                    error.SessionPathUnsafe,
                    => self.resumeLatestByDiscovery(alloc, workspace_root, options),
                    else => cached_error,
                };
            };
            if (std.mem.eql(u8, loaded.state.id, pointer.session_id) and
                std.mem.eql(u8, loaded.state.workspace_root, workspace_root) and
                loaded.state.updated_at_ms == pointer.updated_at_ms)
            {
                const still_matches = latestPointerStillMatches(
                    self,
                    alloc,
                    workspace_root,
                    pointer,
                ) catch |err| {
                    loaded.deinit(alloc);
                    return err;
                };
                if (still_matches) return loaded;
            }
            loaded.deinit(alloc);
        }
        const pending_id = readPendingLatestSessionId(
            self,
            alloc,
            workspace_root,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (pending_id) |observed_id| {
            defer alloc.free(observed_id);
            const barrier_contended = try self.crossLatestBarrier(options.log.test_controls);
            const current_pending = readPendingLatestSessionId(
                self,
                alloc,
                workspace_root,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (current_pending) |session_id| {
                defer alloc.free(session_id);
                try options.log.test_controls.boundary(.latest_barrier_completed);
                var recovered = self.resumeExactForWrite(
                    alloc,
                    session_id,
                    workspace_root,
                    false,
                    options,
                ) catch |err| {
                    return switch (err) {
                        error.SessionNotFound,
                        error.SessionTargetChanged,
                        error.FileNotFound,
                        => if (barrier_contended)
                            self.resumeLatestDiscoveryAfterBarrier(
                                alloc,
                                workspace_root,
                                options,
                            )
                        else
                            self.resumeLatestByDiscovery(alloc, workspace_root, options),
                        else => err,
                    };
                };
                recovered.deinit(alloc);
                return self.resumeLatestByDiscovery(alloc, workspace_root, options);
            }
            return self.resumeLatestDiscoveryAttempt(
                alloc,
                workspace_root,
                options,
            ) catch |err| switch (err) {
                error.SessionNotFound,
                error.FileNotFound,
                => self.resumeLatestByDiscovery(alloc, workspace_root, options),
                else => err,
            };
        }
        return self.resumeLatestByDiscovery(alloc, workspace_root, options);
    }

    fn resumeLatestByDiscovery(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        for (0..2) |attempt| {
            _ = try self.crossLatestBarrier(options.log.test_controls);
            const loaded = self.resumeLatestDiscoveryAttempt(
                alloc,
                workspace_root,
                options,
            ) catch |err| {
                if (attempt == 0 and
                    (err == error.SessionNotFound or err == error.FileNotFound))
                {
                    continue;
                }
                return err;
            };
            return loaded;
        }
        unreachable;
    }

    fn resumeLatestDiscoveryAttempt(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try options.log.test_controls.boundary(.latest_barrier_completed);
        return self.resumeLatestDiscoveryAfterBarrier(alloc, workspace_root, options);
    }

    fn resumeLatestDiscoveryAfterBarrier(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        const selected = try self.selectWritableLastId(
            alloc,
            workspace_root,
            options,
        ) orelse return session_log.failLoadedWritableSession(error.NoSavedSessions);
        defer alloc.free(selected);
        var loaded = try self.resumeExactForWrite(
            alloc,
            selected,
            workspace_root,
            false,
            options,
        );
        errdefer loaded.deinit(alloc);
        self.repairLatestPointer(
            alloc,
            loaded.state,
            loaded.position,
            options.log,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=latest_cache_repair_failed err={s}",
                .{@errorName(err)},
            );
        };
        return loaded;
    }

    fn crossLatestBarrier(
        self: Store,
        test_controls: session_log.TestControls,
    ) !bool {
        var sessions = self.canonical_root.sessions orelse return error.SessionNotFound;
        var context = LatestBarrierLockContext{ .test_controls = test_controls };
        var barrier = io_mod.acquireTimedAdvisoryLockWithOps(
            &sessions,
            latest_sessions_lock_file,
            2000,
            .{
                .ctx = &context,
                .try_lock = LatestBarrierLockContext.tryLock,
            },
        ) catch |err| switch (err) {
            error.LockBusy => return error.SessionBusy,
            error.LockUnsupported => return error.SessionLockUnsupported,
            else => return err,
        };
        barrier.release();
        return context.contention_reported;
    }

    /// Loads a session's full durable state read-only. Caller owns the state.
    pub fn loadReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_codec.DurableSessionState {
        var detail = try self.loadReadOnlyDetail(alloc, session_id, .{});
        detail.summary.deinit(alloc);
        const state = detail.state;
        detail.state = undefined;
        return state;
    }

    /// Reads one bounded chronological history page without acquiring the
    /// session writer lock. The cursor is opaque and anchored to the history
    /// length that produced it, so later appends cannot duplicate older pages.
    pub fn loadHistoryPage(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        cursor: ?[]const u8,
        limit: usize,
    ) LoadHistoryPageError!store_types.HistoryPage {
        validateSessionId(session_id) catch return error.InvalidSessionId;
        if (limit == 0 or limit > 100) return error.InvalidHistoryPageLimit;
        const position = if (cursor) |raw| try parseHistoryPageCursor(raw) else null;
        if (position) |value| {
            if (!std.mem.eql(u8, value.session_id, session_id)) return error.InvalidHistoryPageCursor;
        }

        var state = self.loadReadOnly(alloc, session_id) catch |err| return mapHistoryPageLoadError(err);
        defer state.deinit(alloc);

        const snapshot: HistoryPageCursor = if (position) |value| blk: {
            if (value.history_len > state.history.len)
                return error.StaleHistoryPageCursor;
            const digest = historyPrefixDigest(state.history[0..value.history_len]) catch return error.SessionStoreUnavailable;
            if (!std.mem.eql(u8, &value.prefix_digest, &digest)) return error.StaleHistoryPageCursor;
            break :blk value;
        } else .{
            .session_id = state.id,
            .history_len = state.history.len,
            .revision_ms = state.updated_at_ms,
            .prefix_digest = historyPrefixDigest(state.history) catch return error.SessionStoreUnavailable,
            .start = state.history.len,
        };
        const window = selectHistoryPageWindow(state.history.len, snapshot.start, limit);
        const turns = try duplicateHistoryPage(alloc, state.history[window.start..window.end]);
        errdefer session.freeHistoryTurnSlice(alloc, turns);
        const next_cursor = if (window.start > 0) blk: {
            var encoded: [512]u8 = undefined;
            const raw = formatHistoryPageCursor(&encoded, .{
                .session_id = snapshot.session_id,
                .history_len = snapshot.history_len,
                .revision_ms = snapshot.revision_ms,
                .prefix_digest = snapshot.prefix_digest,
                .start = window.start,
            }) catch return error.SessionStoreUnavailable;
            break :blk try alloc.dupe(u8, raw);
        } else null;
        errdefer if (next_cursor) |value| alloc.free(value);
        return .{
            .session_id = try alloc.dupe(u8, state.id),
            .revision_ms = snapshot.revision_ms,
            .history_len = snapshot.history_len,
            .turns = turns,
            .next_cursor = next_cursor,
        };
    }

    /// Opens read-only managed-child storage for a session, validating it loads.
    pub fn openChildCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_child_store.SessionChildCapability {
        var detail = try self.loadReadOnlyDetail(alloc, session_id, .{});
        detail.deinit(alloc);

        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.init(
            alloc,
            session_dir.dir,
            display_path,
            .read_only,
        );
    }

    /// Opens child storage for a session id that was already accepted by list
    /// or another caller-owned read-only selection. This avoids replaying the
    /// canonical event log when only managed child routes are needed.
    pub fn openListedChildCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_child_store.SessionChildCapability {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.init(
            alloc,
            session_dir.dir,
            display_path,
            .read_only,
        );
    }

    /// Opens verified read-only storage restricted to subagent control files.
    pub fn openSubagentControlCapabilityReadOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        return self.openSubagentControlCapabilityMode(
            alloc,
            session_id,
            .read_only,
            options,
        );
    }

    /// Opens verified writable storage restricted to subagent control files.
    /// The returned capability never owns `session.lock` and cannot mutate the
    /// transcript or any other managed-child route.
    pub fn openSubagentControlCapabilityWritable(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        if (self.canonical_root.mode != .writable) return error.SessionStoreUnavailable;
        return self.openSubagentControlCapabilityMode(
            alloc,
            session_id,
            .writable,
            options,
        );
    }

    fn openSubagentControlCapabilityMode(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        mode: session_child_store.Mode,
        options: session_child_store.Options,
    ) OpenSubagentControlError!session_child_store.SessionChildCapability {
        validateSessionId(session_id) catch return error.InvalidSessionId;

        var session_dir = self.openSessionDir(session_id) catch |err| return switch (err) {
            error.InvalidSessionId => error.InvalidSessionId,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionStoreUnavailable,
        };
        defer session_dir.close();
        var candidate = classifyReadOnlyCandidate(
            alloc,
            &session_dir,
            session_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionStoreUnavailable,
        };
        candidate.deinit(alloc);
        const display_path = sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidSessionId => error.InvalidSessionId,
        };
        defer alloc.free(display_path);
        return session_child_store.SessionChildCapability.initSubagentControl(
            alloc,
            session_dir.dir,
            display_path,
            mode,
            options,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            error.SessionChildStoreFailed => error.SessionChildStoreFailed,
        };
    }

    /// Returns owned session metadata needed to initialize a control record.
    /// This validates ordinary-session visibility without replaying transcript history.
    pub fn loadSubagentBootstrapMetadata(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) LoadSubagentBootstrapError!SubagentBootstrapMetadata {
        validateSessionId(session_id) catch return error.InvalidSessionId;
        var session_dir = self.openSessionDir(session_id) catch |err| return switch (err) {
            error.InvalidSessionId => error.InvalidSessionId,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionMetadataUnavailable,
        };
        defer session_dir.close();
        var candidate = classifyReadOnlyCandidate(
            alloc,
            &session_dir,
            session_id,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionNotFound => error.SessionNotFound,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            else => error.SessionMetadataUnavailable,
        };
        defer candidate.deinit(alloc);

        const name_source = candidate.summary.title orelse session_id;
        const name = try alloc.dupe(u8, name_source);
        errdefer alloc.free(name);
        return .{
            .name = name,
            .preferences = switch (candidate.storage) {
                .schema_v3 => self.loadSubagentManifestPreferences(
                    alloc,
                    &session_dir,
                    session_id,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.SessionNotFound => error.SessionNotFound,
                    error.SessionPathUnsafe => error.SessionPathUnsafe,
                    else => error.SessionMetadataUnavailable,
                },
                .legacy_v1, .legacy_v2 => self.loadSubagentLegacyPreferences(
                    alloc,
                    candidate.summary.workspace_root orelse self.workspace_root,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SessionMetadataUnavailable,
                },
            },
        };
    }

    fn loadSubagentManifestPreferences(
        self: Store,
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
    ) !session_codec.DurableSessionPreferences {
        _ = self;
        var file = openSessionFile(session_dir, "session.json", .read_only) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(
            alloc,
            &file,
            session_projection.manifest_max_bytes,
        );
        defer alloc.free(bytes);
        var manifest = try session_projection.decodeManifest(alloc, bytes);
        defer manifest.deinit(alloc);
        if (!std.mem.eql(u8, manifest.id, session_id)) return error.InvalidSessionFormat;
        return manifest.preferences.dupe(alloc);
    }

    fn loadSubagentLegacyPreferences(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !session_codec.DurableSessionPreferences {
        var detailed = try config_runtime.loadMergedSettingsDetailedFromHome(
            alloc,
            self.home_dir,
            workspace_root,
        );
        defer detailed.deinit(alloc);
        return .{
            .model = try alloc.dupe(
                u8,
                detailed.settings.models.get(.gateway) orelse "anthropic/claude-opus-4.7",
            ),
            .effort = detailed.settings.effort orelse .auto,
            .fast_mode = detailed.settings.fast_mode orelse false,
        };
    }

    fn attachWritableChildCapability(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
    ) !void {
        const display_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            loaded.active_id,
        );
        defer alloc.free(display_path);
        const capability = try alloc.create(
            session_child_store.SessionChildCapability,
        );
        errdefer alloc.destroy(capability);
        capability.* = try session_child_store.SessionChildCapability.init(
            alloc,
            loaded.log.dir.dir,
            display_path,
            .writable,
        );
        loaded.child_capability = capability;
    }

    fn makeLatestCacheLifecycle(
        self: Store,
        alloc: Allocator,
        initial_index_effect: InitialIndexEffect,
        test_controls: session_log.TestControls,
    ) !session_log.CommitLifecycle {
        const sessions = &(self.canonical_root.sessions orelse return error.SessionStoreUnavailable);
        const cache = try LatestCache.init(
            alloc,
            sessions,
            test_controls,
            initial_index_effect,
        );
        return .{
            .context = cache,
            .prepare_fn = latestCachePrepare,
            .publish_fn = latestCachePublish,
            .write_deferred_fn = latestCacheWriteDeferred,
            .abort_fn = latestCacheAbort,
            .deinit_fn = latestCacheDeinit,
        };
    }

    fn installLatestCacheLifecycle(
        self: Store,
        alloc: Allocator,
        loaded: *LoadedWritableSession,
        test_controls: session_log.TestControls,
    ) !void {
        var lifecycle = try self.makeLatestCacheLifecycle(
            alloc,
            .maintain,
            test_controls,
        );
        errdefer lifecycle.deinit(alloc);
        try loaded.installCommitLifecycle(lifecycle);
    }

    fn repairLatestPointer(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: session_log.CommitPosition,
        options: session_log.Options,
    ) !void {
        try self.publishLatestPointer(
            alloc,
            state,
            position,
            options,
            .maintain,
        );
    }

    fn publishRecoveredLatestPointer(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: session_log.CommitPosition,
        source_session_id: []const u8,
        options: session_log.Options,
    ) !void {
        const sessions = &(self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable);
        for (0..4) |_| {
            const observed_snapshot = try latest_pointer.readLatestSnapshotToken(
                sessions,
                state.workspace_root,
            );
            try options.test_controls.boundary(
                .after_recovery_latest_snapshot,
            );
            var discovered_latest: ?SessionSummary =
                self.latestReadOnlyWorkspaceSummaryFor(
                    alloc,
                    state.workspace_root,
                ) catch |err| switch (err) {
                    error.NoSavedSessions => null,
                    else => return err,
                };
            defer if (discovered_latest) |*summary| summary.deinit(alloc);
            self.publishLatestPointer(
                alloc,
                state,
                position,
                options,
                .{ .replace_latest_if_current = .{
                    .expected_current_id = source_session_id,
                    .discovered_latest = if (discovered_latest) |summary| .{
                        .session_id = summary.id,
                        .updated_at_ms = summary.updated_at_ms,
                    } else null,
                    .observed_snapshot = observed_snapshot,
                } },
            ) catch |err| switch (err) {
                error.SessionLatestBaselineChanged => continue,
                else => return err,
            };
            return;
        }
        return error.SessionLatestBaselineChanged;
    }

    fn publishLatestPointer(
        self: Store,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: session_log.CommitPosition,
        options: session_log.Options,
        effect: InitialIndexEffect,
    ) !void {
        const sessions = &(self.canonical_root.sessions orelse return error.SessionStoreUnavailable);
        const cache = try LatestCache.init(
            alloc,
            sessions,
            options.test_controls,
            effect,
        );
        defer cache.deinit(alloc);
        try cache.begin(
            alloc,
            state.id,
            state.workspace_root,
            state.workspace_root,
            options.commit_lock_deadline_ms,
        );
        try cache.publish(alloc, state, position);
    }

    /// Loads a session's summary, state, and storage format read-only, handling
    /// both schema-v3 and legacy snapshots. Caller owns the returned detail.
    pub fn loadReadOnlyDetail(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: ResumeOptions,
    ) !ReadOnlyDetail {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const authority = try classifyAuthority(alloc, &session_dir, session_id);
        return switch (authority) {
            .schema_v3 => {
                var root = self.canonical_root;
                var state = root.loadReadOnly(alloc, session_id, options.log) catch |err| {
                    return mapReplayError(err);
                };
                errdefer state.deinit(alloc);
                try resolveSessionSnapshotLocators(
                    alloc,
                    state.history,
                    self.sessions_dir,
                    session_id,
                );
                return .{
                    .summary = try summaryFromState(alloc, state),
                    .state = state,
                    .storage_format = .schema_v3,
                };
            },
            .legacy => try self.loadLegacyReadOnlyDetail(
                alloc,
                &session_dir,
                session_id,
                options,
            ),
        };
    }

    /// Lists supported readable sessions newest-first; caller frees each item and the list.
    /// Lists all readable sessions newest-first. Caller frees each item and the list.
    pub fn list(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false);
        return scan.summaries;
    }

    fn deferredCacheInvalidatesReads(self: Store) bool {
        const sessions = &(self.canonical_root.sessions orelse return false);
        return summary_codec.deferredCachePresent(sessions) catch true;
    }

    fn loadDeferredReplayScope(self: Store, alloc: Allocator) DeferredReplayScope {
        const sessions = &(self.canonical_root.sessions orelse return .{ .tokens = .empty });
        const tokens = summary_codec.readDeferredCacheTokens(
            alloc,
            sessions,
        ) catch return .all;
        return .{ .tokens = tokens };
    }

    /// Invalidates the derived resume catalog after managed child ownership
    /// changes. The relationship index remains the canonical authority.
    pub fn invalidateResumableIndex(self: Store, alloc: Allocator) !void {
        if (self.canonical_root.mode != .writable) return error.SessionStoreReadOnly;
        var sessions = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var cache_lock = try io_mod.acquireTimedAdvisoryLock(
            &sessions,
            latest_sessions_lock_file,
            2000,
        );
        defer cache_lock.release();
        try summary_codec.writeSessionIndexMarker(alloc, &sessions);
    }

    /// Returns owned IDs for every readable ordinary session. Caller frees each
    /// ID and the list with the allocator passed here.
    pub fn listSubagentControlSessionIds(
        self: Store,
        alloc: Allocator,
    ) ListSubagentControlIdsError!std.ArrayList([]u8) {
        const scan = self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionStoreUnavailable,
            };
        };
        var summaries = scan.summaries;
        defer freeSummaries(alloc, &summaries);
        var ids: std.ArrayList([]u8) = .empty;
        errdefer {
            for (ids.items) |id| alloc.free(id);
            ids.deinit(alloc);
        }
        for (summaries.items) |summary| {
            const id = try alloc.dupe(u8, summary.id);
            errdefer alloc.free(id);
            try ids.append(alloc, id);
        }
        return ids;
    }

    /// Returns a bounded page of ordinary-session IDs for derived relationship
    /// migration only. These candidates never establish relationship truth.
    pub fn listRelationshipMigrationCandidates(
        self: Store,
        alloc: Allocator,
        continuation: RelationshipMigrationCursor,
    ) ListSubagentControlIdsError!RelationshipMigrationCandidatePage {
        if (self.deferredCacheInvalidatesReads()) {
            return self.listRelationshipMigrationCandidatesFromCanonical(
                alloc,
                continuation,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionStoreUnavailable,
            };
        }
        var sessions = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        if (self.canonical_root.mode == .read_only) {
            return summary_codec.readRelationshipMigrationCandidatePage(
                alloc,
                &sessions,
                continuation,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionStoreUnavailable,
            };
        }
        var lock = io_mod.acquireTimedAdvisoryLock(
            &sessions,
            latest_sessions_lock_file,
            2000,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SessionStoreUnavailable,
        };
        defer lock.release();
        return summary_codec.readRelationshipMigrationCandidatePage(
            alloc,
            &sessions,
            continuation,
        ) catch |read_err| switch (read_err) {
            error.OutOfMemory => error.OutOfMemory,
            else => {
                summary_codec.refreshRelationshipMigrationSnapshot(
                    alloc,
                    &sessions,
                ) catch |refresh_err| return switch (refresh_err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SessionStoreUnavailable,
                };
                return summary_codec.readRelationshipMigrationCandidatePage(
                    alloc,
                    &sessions,
                    .{},
                ) catch |retry_err| switch (retry_err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.SessionStoreUnavailable,
                };
            },
        };
    }

    fn listRelationshipMigrationCandidatesFromCanonical(
        self: Store,
        alloc: Allocator,
        continuation: RelationshipMigrationCursor,
    ) !RelationshipMigrationCandidatePage {
        var summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &summaries);
        const total = std.math.cast(u64, summaries.items.len) orelse
            return error.SessionStoreUnavailable;
        const same_snapshot = continuation.inode == 0 and
            continuation.mtime_ns == 0 and
            continuation.size == total and
            continuation.offset <= total;
        const start = if (same_snapshot) continuation.offset else 0;
        const remaining = total - start;
        const count = @min(
            remaining,
            summary_codec.relationship_migration_candidate_limit,
        );
        const end = start + count;
        var page = RelationshipMigrationCandidatePage{
            .cursor = .{
                .size = total,
                .offset = end,
            },
            .has_more = end < total,
        };
        errdefer page.deinit(alloc);
        for (summaries.items[@intCast(start)..@intCast(end)]) |summary| {
            try page.ids.append(alloc, try alloc.dupe(u8, summary.id));
        }
        return page;
    }

    /// Persists the unresolved marker before its matching session checkpoint.
    /// The caller must persist the returned timestamp with that checkpoint.
    pub fn prepareUsageRecoveryCheckpoint(
        self: Store,
        alloc: Allocator,
        writable: *const LoadedWritableSession,
        snapshot: session_usage.Snapshot,
    ) !UsageRecoveryCheckpoint {
        const now_ms = @max(io_mod.milliTimestamp(), 0);
        const timestamp_ms = if (now_ms > writable.state.updated_at_ms)
            now_ms
        else
            std.math.add(
                i64,
                writable.state.updated_at_ms,
                1,
            ) catch return error.InvalidSessionFormat;
        const recovery_pending = session_usage.needsProfileRecovery(snapshot);
        if (recovery_pending) {
            const durable_recovery_pending = if (writable.state.usage) |usage|
                session_usage.needsProfileRecovery(usage)
            else
                false;
            const protected_updated_at_ms = if (durable_recovery_pending)
                writable.state.updated_at_ms
            else
                timestamp_ms;
            try self.writeUsageRecoveryPending(
                alloc,
                writable.active_id,
                protected_updated_at_ms,
                !durable_recovery_pending,
            );
        }
        return .{
            .recovery_pending = recovery_pending,
            .timestamp_ms = timestamp_ms,
        };
    }

    /// Completes the marker transition after the matching session checkpoint
    /// is durable.
    pub fn finishUsageRecoveryCheckpoint(
        self: Store,
        session_id: []const u8,
        checkpoint: UsageRecoveryCheckpoint,
    ) !void {
        if (!checkpoint.recovery_pending) {
            try self.clearUsageRecoveryPending(session_id);
        }
    }

    /// Records that this session has profile usage which is not yet proven
    /// durable in the profile ledger.
    pub fn markUsageRecoveryPending(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        protected_updated_at_ms: i64,
    ) !void {
        try self.writeUsageRecoveryPending(
            alloc,
            session_id,
            protected_updated_at_ms,
            true,
        );
    }

    fn writeUsageRecoveryPending(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        protected_updated_at_ms: i64,
        replace_existing: bool,
    ) !void {
        try validateSessionId(session_id);
        if (protected_updated_at_ms < 0) return error.InvalidSessionFormat;
        if (self.canonical_root.mode != .writable) {
            return error.SessionStoreReadOnly;
        }
        _ = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var profile = try openUsageRecoveryProfileRoot(self.home_dir) orelse
            return error.SessionStoreUnavailable;
        defer profile.close();
        var recovery = try io_mod.openOrCreateVerifiedPrivateDir(
            &profile,
            usage_recovery_dir,
        );
        defer recovery.close();
        const existing = validateUsageRecoveryMarker(
            &recovery,
            session_id,
        ) catch |err| switch (err) {
            error.UsageRecoveryMarkerNotFound => null,
            else => return err,
        };
        if (!replace_existing and existing != null) return;
        if (existing) |timestamp_ms| {
            if (timestamp_ms == protected_updated_at_ms) return;
        }
        const marker_bytes = try std.fmt.allocPrint(
            alloc,
            "{s}{d}\n",
            .{ usage_recovery_marker_prefix, protected_updated_at_ms },
        );
        defer alloc.free(marker_bytes);
        try io_mod.durableReplaceVerified(
            alloc,
            &recovery,
            session_id,
            marker_bytes,
        );
    }

    /// Clears a session's recovery marker only after its settled checkpoint is
    /// durable. Missing markers are already clear.
    pub fn clearUsageRecoveryPending(
        self: Store,
        session_id: []const u8,
    ) !void {
        try validateSessionId(session_id);
        if (self.canonical_root.mode != .writable) {
            return error.SessionStoreReadOnly;
        }
        _ = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var recovery = try openUsageRecoveryDir(self.home_dir) orelse return;
        defer recovery.close();
        _ = validateUsageRecoveryMarker(&recovery, session_id) catch |err| switch (err) {
            error.UsageRecoveryMarkerNotFound => return,
            else => return err,
        };
        recovery.dir.deleteFile(io_mod.getIo(), session_id) catch |err| switch (err) {
            error.FileNotFound => return,
            error.NotDir, error.SymLinkLoop => return error.InvalidUsageRecoveryIndex,
            else => return err,
        };
        try io_mod.syncVerifiedDir(recovery.dir);
    }

    /// Returns the bounded durable recovery marker set. The caller owns every
    /// entry and the list.
    pub fn listUsageRecoverySessions(
        self: Store,
        alloc: Allocator,
    ) !std.ArrayList(UsageRecoverySession) {
        var recovery = try openUsageRecoveryDir(self.home_dir) orelse
            return std.ArrayList(UsageRecoverySession).empty;
        defer recovery.close();

        var marked: std.ArrayList(UsageRecoverySession) = .empty;
        errdefer {
            for (marked.items) |*entry| entry.deinit(alloc);
            marked.deinit(alloc);
        }
        var iter = recovery.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (entry.kind != .file or
                marked.items.len == max_usage_recovery_sessions)
            {
                return error.InvalidUsageRecoveryIndex;
            }
            validateSessionId(entry.name) catch
                return error.InvalidUsageRecoveryIndex;
            const protected_updated_at_ms = validateUsageRecoveryMarker(
                &recovery,
                entry.name,
            ) catch return error.InvalidUsageRecoveryIndex;
            try marked.append(alloc, .{
                .id = try alloc.dupe(u8, entry.name),
                .protected_updated_at_ms = protected_updated_at_ms,
            });
        }
        sort_utils.sort(UsageRecoverySession, marked.items, {}, struct {
            fn lessThan(
                _: void,
                left: UsageRecoverySession,
                right: UsageRecoverySession,
            ) bool {
                return std.mem.order(u8, left.id, right.id) == .lt;
            }
        }.lessThan);
        return marked;
    }

    /// Lists readable sessions for this store's workspace newest-first. Caller frees each item and the list.
    pub fn listForWorkspace(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false);
        var summaries = scan.summaries;
        errdefer freeSummaries(alloc, &summaries);
        retainWorkspaceSummaries(alloc, &summaries, self.workspace_root);
        return summaries;
    }

    /// Lists session candidates for workspace-owned managed children. Child
    /// payloads remain the authority when the global index update is pending.
    pub fn listManagedChildCandidatesForWorkspace(self: Store, alloc: Allocator) anyerror!std.ArrayList(SessionSummary) {
        if (self.canonical_root.sessions) |*sessions| {
            const summaries = readSessionIndexWorkspaceCandidates(
                alloc,
                sessions,
                self.workspace_root,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (summaries) |index| {
                return index;
            }
        }
        return self.listForWorkspace(alloc);
    }

    /// Lists one bounded workspace page newest-first. The canonical summary
    /// index is preferred; discovery remains a read-only fallback for legacy
    /// or damaged indexes.
    pub fn listWorkspacePage(
        self: Store,
        alloc: Allocator,
        continuation: ?ResumableSessionContinuation,
        limit: usize,
    ) ListWorkspacePageError!SessionListPage {
        return self.listSessionPage(
            alloc,
            .current_workspace,
            continuation,
            limit,
        );
    }

    pub fn listSessionPage(
        self: Store,
        alloc: Allocator,
        scope: SessionListScope,
        continuation: ?ResumableSessionContinuation,
        limit: usize,
    ) ListWorkspacePageError!SessionListPage {
        if (limit == 0 or limit > session_list_max_limit) {
            return error.InvalidSessionListLimit;
        }
        const workspace_root: ?[]const u8 = switch (scope) {
            .current_workspace => self.workspace_root,
            .all_workspaces => null,
        };
        if (self.canonical_root.sessions) |*sessions| {
            var indexed_page = summary_codec.readSessionIndexPage(alloc, sessions, .{
                .workspace_root = workspace_root,
                .continuation = continuation,
                .limit = limit,
                .resumable_only = false,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            if (indexed_page) |*bounded| {
                defer bounded.deinit(alloc);
                var page: SessionListPage = .{
                    .summaries = bounded.summaries,
                    .has_more = bounded.has_more,
                };
                bounded.summaries = .empty;
                if (!summariesMissingDisplayMetadata(page.summaries.items)) {
                    return page;
                }
                page.deinit(alloc);
            }
        }

        var scan = self.scanSessionSummariesWithDiagnostics(alloc, .read_only_list, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionStoreUnavailable,
        };
        defer scan.deinit(alloc);
        var page = sessionListPageFromSummaries(
            alloc,
            scan.summaries.items,
            workspace_root,
            continuation,
            limit,
        ) catch return error.OutOfMemory;
        page.skipped_invalid = scan.skipped_invalid;
        return page;
    }

    /// Lists up to ten resumable sessions after filtering the current and empty sessions.
    pub fn listResumablePage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        return self.listResumablePageForScope(
            alloc,
            .all_workspaces,
            active_id,
            continuation,
        );
    }

    pub fn tryListResumableIndexPage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !?ResumableSessionPage {
        return self.tryListResumableIndexPageForScope(
            alloc,
            .all_workspaces,
            active_id,
            continuation,
        );
    }

    pub fn listResumableWorkspacePage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        return self.listResumablePageForScope(
            alloc,
            .current_workspace,
            active_id,
            continuation,
        );
    }

    pub fn tryListResumableWorkspaceIndexPage(
        self: Store,
        alloc: Allocator,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !?ResumableSessionPage {
        return self.tryListResumableIndexPageForScope(
            alloc,
            .current_workspace,
            active_id,
            continuation,
        );
    }

    fn listResumablePageForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        if (try self.tryListResumableIndexPageForScope(alloc, scope, active_id, continuation)) |page| {
            return page;
        }
        if (self.canonical_root.mode == .writable) {
            return self.backfillResumablePageForScope(alloc, scope, active_id, continuation);
        }
        return self.listResumablePageFromDiscoveryForScope(alloc, scope, active_id, continuation);
    }

    /// Rewrites the cached title for one indexed session. The index freezes
    /// display metadata once present, so a rename must update it here or the
    /// resume picker keeps serving the previously derived title.
    pub fn updateIndexedTitle(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        title: []const u8,
    ) !void {
        var sessions = self.canonical_root.sessions orelse return error.SessionStoreUnavailable;
        if (self.canonical_root.mode != .writable) return error.SessionStoreReadOnly;
        var summaries = try readSessionIndex(alloc, &sessions);
        defer freeSummaries(alloc, &summaries);

        var found = false;
        for (summaries.items) |*summary| {
            if (!std.mem.eql(u8, summary.id, session_id)) continue;
            const owned = try alloc.dupe(u8, title);
            if (summary.title) |value| alloc.free(value);
            summary.title = owned;
            summary.display_metadata_present = true;
            found = true;
            break;
        }
        if (!found) return;
        try summary_codec.writeSessionIndex(alloc, &sessions, summaries.items);
    }

    fn tryListResumableIndexPageForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !?ResumableSessionPage {
        const sessions = &(self.canonical_root.sessions orelse return null);
        const workspace_root = switch (scope) {
            .all_workspaces => null,
            .current_workspace => self.workspace_root,
        };
        const page = summary_codec.readSessionIndexPage(alloc, sessions, .{
            .workspace_root = workspace_root,
            .active_id = active_id,
            .continuation = continuation,
            .limit = self.resume_page_limit,
            .resumable_only = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        return try self.hydrateResumablePage(alloc, page);
    }

    fn backfillResumablePageForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        var sessions = self.canonical_root.sessions orelse return error.SessionStoreUnavailable;
        var summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &summaries);
        try self.refreshMissingDisplayMetadata(alloc, &summaries);
        var page = try self.resumablePageFromSummariesForScope(
            alloc,
            scope,
            summaries.items,
            active_id,
            continuation,
        );
        errdefer page.deinit(alloc);

        var cache_lock = io_mod.acquireTimedAdvisoryLock(
            &sessions,
            latest_sessions_lock_file,
            0,
        ) catch return page;
        var cache_lock_held = true;
        defer if (cache_lock_held) cache_lock.release();

        if (try self.tryListResumableIndexPageForScope(alloc, scope, active_id, continuation)) |indexed| {
            page.deinit(alloc);
            return indexed;
        }
        var observed = summary_codec.readDeferredCacheTokens(
            alloc,
            &sessions,
        ) catch return page;
        defer summary_codec.freeDeferredCacheTokens(alloc, &observed);
        var repair_summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &repair_summaries);
        try self.refreshMissingDisplayMetadata(alloc, &repair_summaries);
        try writeSessionIndex(alloc, &sessions, repair_summaries.items);
        try removeSessionIndexMarker(&sessions);
        cache_lock.release();
        cache_lock_held = false;
        for (observed.items) |token| {
            var root = self.canonical_root;
            var boundary = root.captureReadBoundary(
                alloc,
                token.session_id,
                .{ .commit_lock_deadline_ms = 0 },
            ) catch |err| switch (err) {
                error.SessionNotFound => {
                    latest_pointer.clearObservedDeferredToken(
                        alloc,
                        &sessions,
                        token,
                    ) catch |clear_err| {
                        debug_trace.logf(
                            "session",
                            "event=deferred_cache_orphan_clear_failed err={s}",
                            .{@errorName(clear_err)},
                        );
                    };
                    continue;
                },
                else => continue,
            };
            defer boundary.deinit();
            if (!latest_pointer.commitPositionCovers(
                boundary.position,
                token.position,
            )) continue;
            latest_pointer.clearObservedDeferredToken(
                alloc,
                &sessions,
                token,
            ) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=deferred_cache_token_clear_failed err={s}",
                    .{@errorName(err)},
                );
            };
        }
        return page;
    }

    fn listResumablePageFromDiscoveryForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        var summaries = try self.scanSessionSummaries(alloc, .read_only_list);
        defer freeSummaries(alloc, &summaries);
        return try self.resumablePageFromSummariesForScope(
            alloc,
            scope,
            summaries.items,
            active_id,
            continuation,
        );
    }

    fn resumablePageFromSummariesForScope(
        self: Store,
        alloc: Allocator,
        scope: ResumableSessionScope,
        summaries: []const SessionSummary,
        active_id: ?[]const u8,
        continuation: ?ResumableSessionContinuation,
    ) !ResumableSessionPage {
        const workspace_root = switch (scope) {
            .all_workspaces => null,
            .current_workspace => self.workspace_root,
        };
        return try resumablePageFromSummaries(
            alloc,
            summaries,
            workspace_root,
            active_id,
            continuation,
            self.resume_page_limit,
        );
    }

    /// Takes ownership of `page` and refreshes stale display rows when the
    /// source is small enough for bounded first-paint work. Large histories
    /// keep their honest fallback title instead of blocking the whole page.
    fn hydrateResumablePage(
        self: Store,
        alloc: Allocator,
        page: ResumableSessionPage,
    ) !?ResumableSessionPage {
        var owned = page;
        errdefer owned.deinit(alloc);
        if (summariesMissingDisplayMetadata(owned.summaries.items)) {
            try self.refreshMissingDisplayMetadata(alloc, &owned.summaries);
        }
        return owned;
    }

    fn refreshMissingDisplayMetadata(
        self: Store,
        alloc: Allocator,
        summaries: *std.ArrayList(SessionSummary),
    ) !void {
        for (summaries.items) |*summary| {
            if (!summaryNeedsDisplayMetadata(summary.*)) continue;
            if (try self.adoptFrozenSidecar(alloc, summary)) continue;
            const source_bytes = self.displayMetadataReplaySourceBytes(summary.id) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=display_metadata_refresh_deferred id={s} reason=source_unavailable err={s}",
                    .{ summary.id, @errorName(err) },
                );
                continue;
            };
            if (source_bytes > synchronous_display_metadata_replay_max_bytes) {
                debug_trace.logf(
                    "session",
                    "event=display_metadata_refresh_deferred id={s} reason=source_large bytes={d} limit={d}",
                    .{ summary.id, source_bytes, synchronous_display_metadata_replay_max_bytes },
                );
                continue;
            }
            var detail = self.loadReadOnlyDetail(alloc, summary.id, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf(
                        "session",
                        "event=display_metadata_refresh_load_failed id={s} err={s}",
                        .{ summary.id, @errorName(err) },
                    );
                    continue;
                },
            };
            const replacement = detail.summary;
            detail.summary = undefined;
            detail.state.deinit(alloc);

            summary.deinit(alloc);
            summary.* = replacement;
            if (!summary.display_metadata_present) continue;
            if (self.canonical_root.mode == .writable) {
                self.writeDisplaySidecarFromSummary(alloc, summary.*) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => debug_trace.logf(
                        "session",
                        "event=display_sidecar_write_failed id={s} err={s}",
                        .{ summary.id, @errorName(err) },
                    ),
                };
            }
        }
    }

    fn displayMetadataReplaySourceBytes(self: Store, session_id: []const u8) !u64 {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        var events = openSessionFile(&session_dir, "events.jsonl", .read_only) catch |err| switch (err) {
            error.FileNotFound => {
                var legacy = try openSessionFile(&session_dir, "session.json", .read_only);
                defer legacy.close(io_mod.getIo());
                return (try legacy.stat(io_mod.getIo())).size;
            },
            else => return err,
        };
        defer events.close(io_mod.getIo());
        return (try events.stat(io_mod.getIo())).size;
    }

    /// Fills display metadata from an existing frozen sidecar so hydration
    /// replays the event log only when no sidecar is readable.
    fn adoptFrozenSidecar(
        self: Store,
        alloc: Allocator,
        summary: *SessionSummary,
    ) !bool {
        var session_dir = self.openSessionDir(summary.id) catch return false;
        defer session_dir.close();
        var display = session_display_metadata.readSidecarOrFallback(alloc, &session_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf(
                    "session",
                    "event=display_sidecar_adopt_failed id={s} err={s}",
                    .{ summary.id, @errorName(err) },
                );
                return false;
            },
        };
        if (!display.present) {
            display.deinit(alloc);
            return false;
        }
        if (display.origin_workspace_root) |root| alloc.free(root);
        if (summary.title) |value| alloc.free(value);
        if (summary.preview) |value| alloc.free(value);
        summary.title = display.title;
        summary.preview = display.preview;
        summary.display_metadata_present = true;
        return true;
    }

    fn writeDisplaySidecarFromSummary(
        self: Store,
        alloc: Allocator,
        summary: SessionSummary,
    ) !void {
        const title = summary.title orelse return;
        var session_dir = try self.openSessionDir(summary.id);
        defer session_dir.close();
        try session_display_metadata.writeSidecar(
            alloc,
            &session_dir,
            .{
                .present = true,
                .title = title,
                .preview = summary.preview,
                .origin_workspace_root = summary.origin_workspace_root,
            },
        );
    }

    /// Returns the single newest readable session summary, or
    /// `error.NoSavedSessions`. Caller owns it.
    pub fn latestReadOnlySummary(
        self: Store,
        alloc: Allocator,
    ) !SessionSummary {
        var summaries = try self.scanSessionSummaries(
            alloc,
            .global_read_only_last,
        );
        defer summaries.deinit(alloc);
        if (summaries.items.len == 0) return error.NoSavedSessions;
        const latest = summaries.orderedRemove(0);
        for (summaries.items) |*summary| summary.deinit(alloc);
        return latest;
    }

    /// Returns the newest readable session summary for this store's workspace, or
    /// `error.NoSavedSessions`. Caller owns it.
    pub fn latestReadOnlyWorkspaceSummary(
        self: Store,
        alloc: Allocator,
    ) !SessionSummary {
        return self.latestReadOnlyWorkspaceSummaryFor(
            alloc,
            self.workspace_root,
        );
    }

    fn latestReadOnlyWorkspaceSummaryFor(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
    ) !SessionSummary {
        var scan = try self.scanSessionSummariesWithDiagnostics(
            alloc,
            .global_read_only_last,
            true,
        );
        defer scan.summaries.deinit(alloc);
        retainWorkspaceSummaries(alloc, &scan.summaries, workspace_root);
        if (scan.summaries.items.len == 0) {
            if (scan.skipped_invalid > 0) return error.NoReadableSessions;
            return error.NoSavedSessions;
        }
        const latest = scan.summaries.orderedRemove(0);
        for (scan.summaries.items) |*summary| summary.deinit(alloc);
        return latest;
    }

    fn scanSessionSummaries(
        self: Store,
        alloc: Allocator,
        mode: DiscoveryMode,
    ) !std.ArrayList(SessionSummary) {
        const scan = try self.scanSessionSummariesWithDiagnostics(alloc, mode, true);
        return scan.summaries;
    }

    /// Scans session directories into summaries. `probe_managed_children`
    /// controls whether each session's subagent relationship index is opened to
    /// resolve `has_managed_children`. Callers that persist summaries via
    /// `writeSessionIndex` or filter with `resumable_only` must pass true;
    /// list-only consumers that never read the field should pass false.
    fn scanSessionSummariesWithDiagnostics(
        self: Store,
        alloc: Allocator,
        mode: DiscoveryMode,
        probe_managed_children: bool,
    ) !SessionSummaryScan {
        var scan = SessionSummaryScan{};
        errdefer scan.deinit(alloc);
        var replay_scope = self.loadDeferredReplayScope(alloc);
        defer replay_scope.deinit(alloc);
        var metadata: std.ArrayList(DiscoveryCandidateMetadata) = .empty;
        defer metadata.deinit(alloc);
        if (self.canonical_root.sessions == null) return scan;
        var iter = self.canonical_root.sessions.?.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, latest_sessions_dir)) {
                continue;
            }
            validateSessionId(entry.name) catch continue;
            var session_dir = self.openSessionDir(entry.name) catch |err| switch (err) {
                else => {
                    logDiscoveryError(mode, entry.name, null, null, err);
                    scan.skipped_invalid += 1;
                    continue;
                },
            };
            var candidate = classifyReadOnlyCandidate(
                alloc,
                &session_dir,
                entry.name,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    session_dir.close();
                    return error.OutOfMemory;
                },
                else => {
                    session_dir.close();
                    logDiscoveryError(mode, entry.name, null, null, err);
                    scan.skipped_invalid += 1;
                    continue;
                },
            };
            session_dir.close();
            if (candidate.storage == .schema_v3 and
                readOnlyScopeRequiresCanonicalReplay(
                    replay_scope,
                    entry.name,
                    candidate.projection_state,
                ))
            {
                var detail = self.loadReadOnlyDetail(
                    alloc,
                    entry.name,
                    .{},
                ) catch |err| {
                    candidate.deinit(alloc);
                    switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            logDiscoveryError(mode, entry.name, null, null, err);
                            scan.skipped_invalid += 1;
                            continue;
                        },
                    }
                };
                candidate.deinit(alloc);
                candidate = .{
                    .summary = detail.summary,
                    .storage = .schema_v3,
                    .projection_state = .current,
                };
                detail.summary = undefined;
                detail.state.deinit(alloc);
                detail = undefined;
            }
            if (probe_managed_children) {
                candidate.summary.has_managed_children =
                    self.sessionHasManagedChildren(alloc, entry.name) catch |err| switch (err) {
                        error.OutOfMemory => {
                            candidate.deinit(alloc);
                            return error.OutOfMemory;
                        },
                        else => false,
                    };
            }
            logDiscovery(
                mode,
                entry.name,
                candidate.storage,
                candidate.projection_state,
                .listable,
                .retained,
                null,
            );
            metadata.append(alloc, .{
                .id = candidate.summary.id,
                .storage = candidate.storage,
                .projection_state = candidate.projection_state,
            }) catch |err| {
                candidate.deinit(alloc);
                return err;
            };
            scan.summaries.append(alloc, candidate.summary) catch |err| {
                candidate.deinit(alloc);
                return err;
            };
            candidate.summary = undefined;
        }
        sortSummariesNewestFirst(scan.summaries.items);
        if (mode == .global_read_only_last and scan.summaries.items.len > 0) {
            for (metadata.items) |candidate| {
                if (!std.mem.eql(u8, candidate.id, scan.summaries.items[0].id)) {
                    continue;
                }
                logDiscovery(
                    mode,
                    candidate.id,
                    candidate.storage,
                    candidate.projection_state,
                    .listable,
                    .selected,
                    null,
                );
                break;
            }
        }
        return scan;
    }

    fn sessionHasManagedChildren(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !bool {
        var capability = try self.openListedChildCapabilityReadOnly(
            alloc,
            session_id,
        );
        defer capability.deinit();
        var header_file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            session_child_store.subagent_relationship_index_file,
        ) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer header_file.deinit();
        const header_bytes = try header_file.readToEnd(
            alloc,
            relationship_index_codec.max_header_bytes,
        );
        defer alloc.free(header_bytes);
        const header = try relationship_index_codec.decodeHeader(header_bytes);
        if (header.active_count_known) return header.active_count != 0;

        var page_number: u64 = 0;
        var offset: u64 = 0;
        while (offset < header.high_watermark) : (page_number += 1) {
            const page_name = relationship_index_codec.pageFileName(page_number);
            var page_file = try capability.openFileReadOnly(
                alloc,
                .subagent_control,
                &page_name,
            );
            defer page_file.deinit();
            const page_bytes = try page_file.readToEnd(
                alloc,
                relationship_index_codec.max_page_bytes,
            );
            defer alloc.free(page_bytes);
            const page = try relationship_index_codec.decodePage(
                page_bytes,
                page_number,
                header.storage_epoch,
            );
            const remaining = header.high_watermark - offset;
            const slots_to_read: usize = @intCast(@min(
                remaining,
                relationship_index_codec.page_slots,
            ));
            for (page.slots[0..slots_to_read]) |slot| {
                if (slot.occupied) return true;
            }
            offset += @intCast(slots_to_read);
        }
        return false;
    }

    /// Reads the aggregate summary cache, or null when absent/unreadable.
    pub fn readStateSummary(self: Store, alloc: Allocator) !?StateSummary {
        const path = try summaryPath(alloc, self.sessions_dir);
        defer alloc.free(path);
        return readSessionStateSummary(alloc, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionIndexNotFound, error.InvalidSessionIndex => return null,
            else => return null,
        };
    }

    /// Runs `doctor` over every session and returns one diagnostic per problem
    /// found. Caller frees the list.
    pub fn inspectForDoctor(
        self: Store,
        alloc: Allocator,
    ) !std.ArrayList(DoctorDiagnostic) {
        var result = try self.inspectForDoctorReportWithOptions(alloc, .{}, null);
        return result.takeDiagnostics();
    }

    fn inspectForDoctorWithOptions(
        self: Store,
        alloc: Allocator,
        options: DoctorInspectionOptions,
    ) !std.ArrayList(DoctorDiagnostic) {
        var result = try self.inspectForDoctorReportWithOptions(alloc, options, null);
        return result.takeDiagnostics();
    }

    /// Runs `doctor` over up to `max_valid_sessions` valid session directories.
    /// Caller frees the returned result.
    pub fn inspectForDoctorBounded(
        self: Store,
        alloc: Allocator,
        max_valid_sessions: usize,
    ) !DoctorInspectionResult {
        return self.inspectForDoctorReportWithOptions(alloc, .{}, max_valid_sessions);
    }

    fn inspectForDoctorReportWithOptions(
        self: Store,
        alloc: Allocator,
        options: DoctorInspectionOptions,
        max_valid_sessions: ?usize,
    ) !DoctorInspectionResult {
        var result: DoctorInspectionResult = .{};
        errdefer result.deinit(alloc);
        if (self.canonical_root.sessions == null) return result;

        var iterator = self.canonical_root.sessions.?.dir.iterate();
        while (try iterator.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, latest_sessions_dir)) {
                continue;
            }
            validateSessionId(entry.name) catch continue;
            if (max_valid_sessions) |limit| {
                if (result.inspected_count >= limit) {
                    result.truncated = true;
                    break;
                }
            }
            result.inspected_count += 1;
            var session_dir = self.openSessionDir(entry.name) catch |err| {
                try appendDoctorDiagnostic(
                    &result.diagnostics,
                    alloc,
                    entry.name,
                    if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
                    null,
                );
                continue;
            };
            inspectDoctorSession(
                self.ctx(),
                alloc,
                &result.diagnostics,
                &session_dir,
                entry.name,
                options,
            ) catch |err| {
                session_dir.close();
                if (err == error.OutOfMemory) return err;
                try appendDoctorDiagnostic(
                    &result.diagnostics,
                    alloc,
                    entry.name,
                    if (err == error.SessionPathUnsafe) .unsafe_path else .canonical_state_invalid,
                    null,
                );
                continue;
            };
            session_dir.close();
        }
        return result;
    }

    /// Opens the named session writable and deletes its orphaned artifacts,
    /// returning a report of what was removed.
    pub fn cleanupForDoctor(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
    ) !session_log.CleanupReport {
        var writable_store = try Store.initFromHome(
            alloc,
            self.home_dir,
            self.workspace_root,
        );
        defer writable_store.deinit(alloc);
        var loaded = try writable_store.canonical_root.resumeForWrite(
            alloc,
            session_id,
            .{ .resolve_authority_intent = false },
        );
        defer loaded.deinit(alloc);
        return loaded.cleanupOrphans(alloc, .delete);
    }

    fn openSessionDir(
        self: Store,
        session_id: []const u8,
    ) !io_mod.VerifiedDir {
        try validateSessionId(session_id);
        const sessions = self.canonical_root.sessions orelse
            return error.SessionNotFound;
        var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer dir.close(io_mod.getIo());
        const stat = try dir.stat(io_mod.getIo());
        if (stat.kind != .directory) return error.SessionPathUnsafe;
        return .{ .dir = dir };
    }

    fn loadLegacyReadOnlyDetail(
        self: Store,
        alloc: Allocator,
        session_dir: *io_mod.VerifiedDir,
        session_id: []const u8,
        options: ResumeOptions,
    ) !ReadOnlyDetail {
        try requireAuthorityFenceAbsent(alloc, session_dir, session_id);
        var file = openSessionFile(
            session_dir,
            "session.json",
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer file.close(io_mod.getIo());
        const stat = try file.stat(io_mod.getIo());
        const max_bytes = if (options.allow_large_legacy)
            stat.size
        else
            automatic_legacy_max_bytes;
        if (stat.size > max_bytes) return error.LegacySessionTooLarge;
        const bytes = readExactLegacyFile(alloc, &file, stat.size) catch |err| switch (err) {
            error.OutOfMemory => return error.LegacySessionReadResourceExhausted,
            else => return err,
        };
        defer alloc.free(bytes);
        var legacy = session_json.parseLegacyExact(
            LegacyStoredSession,
            alloc,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.LegacySessionReadResourceExhausted,
            else => return err,
        };
        errdefer legacy.deinit(alloc);
        if (!std.mem.eql(u8, legacy.id, session_id)) return error.InvalidSessionFormat;
        try requireAuthorityFenceAbsent(alloc, session_dir, session_id);

        const schema = try session_json.parseLegacySchemaVersion(alloc, bytes);
        var state = try legacyToDurableState(
            self.ctx(),
            alloc,
            &legacy,
            self.workspace_root,
            .preserved_workspace,
            options.seed_preferences,
        );
        errdefer state.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            state.history,
            self.sessions_dir,
            session_id,
        );
        return .{
            .summary = try summaryFromState(alloc, state),
            .state = state,
            .storage_format = storageFormatForLegacy(schema),
        };
    }

    fn resumeExactForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        allow_rebind: bool,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        const authority = classifyAuthority(
            alloc,
            &session_dir,
            session_id,
        ) catch |err| switch (err) {
            error.SessionAuthorityBoundaryUnavailable => {
                const recovered = try self.resolveAuthorityTransitionForWrite(
                    alloc,
                    session_id,
                    workspace_root,
                    .requesting_workspace,
                    options,
                );
                return self.finishWorkspaceResume(
                    alloc,
                    recovered,
                    workspace_root,
                    allow_rebind,
                    options,
                );
            },
            else => return err,
        };
        const loaded = switch (authority) {
            .schema_v3 => blk: {
                var root = self.canonical_root;
                break :blk root.resumeForWrite(
                    alloc,
                    session_id,
                    options.log,
                ) catch |err| return mapReplayError(err);
            },
            .legacy => try self.migrateLegacyForWrite(
                alloc,
                session_id,
                workspace_root,
                .requesting_workspace,
                options,
            ),
        };
        return self.finishWorkspaceResume(
            alloc,
            loaded,
            workspace_root,
            allow_rebind,
            options,
        );
    }

    fn finishWorkspaceResume(
        self: Store,
        alloc: Allocator,
        loaded_value: LoadedWritableSession,
        workspace_root: []const u8,
        allow_rebind: bool,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded = loaded_value;
        errdefer loaded.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            loaded.state.history,
            self.sessions_dir,
            loaded.active_id,
        );

        if (loaded.commit_lifecycle == null) {
            try self.installLatestCacheLifecycle(
                alloc,
                &loaded,
                options.log.test_controls,
            );
        }

        if (std.mem.eql(u8, loaded.state.workspace_root, workspace_root)) {
            return loaded;
        }
        if (!allow_rebind) {
            return session_log.failLoadedWritableSession(error.SessionTargetChanged);
        }

        const rebound = session_event.Event{ .workspace_rebound = .{
            .previous_workspace_root = loaded.state.workspace_root,
            .workspace_root = @constCast(workspace_root),
        } };
        _ = loaded.appendEvent(
            alloc,
            rebound,
            io_mod.milliTimestamp(),
            .rollback_before_adapter_continue,
            options.log,
        ) catch |err| switch (err) {
            error.SessionPersistenceDegraded => return session_log.failLoadedWritableSession(error.SessionWorkspaceRebindFailed),
            else => return err,
        };
        return loaded;
    }

    fn selectWritableLastId(
        self: Store,
        alloc: Allocator,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !?[]u8 {
        try validateWorkspaceRoot(workspace_root);
        if (self.canonical_root.sessions == null) return null;
        var replay_scope = self.loadDeferredReplayScope(alloc);
        defer replay_scope.deinit(alloc);

        var selected: ?WritableCandidate = null;
        defer if (selected) |*candidate| candidate.deinit(alloc);
        var iter = self.canonical_root.sessions.?.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, latest_sessions_dir)) {
                continue;
            }
            validateSessionId(entry.name) catch continue;
            var candidate = self.resolveWritableCandidate(
                alloc,
                entry.name,
                workspace_root,
                options,
            ) catch |err| switch (err) {
                error.OutOfMemory,
                error.SessionAuthorityBoundaryUnavailable,
                error.SessionCommitBoundaryUnavailable,
                => return err,
                else => {
                    logDiscoveryError(
                        .workspace_writable_last,
                        entry.name,
                        null,
                        null,
                        err,
                    );
                    return err;
                },
            };
            if (candidate.storage == .schema_v3 and
                candidate.projection_state == .current and
                tokenScopeRequiresCanonicalReplay(replay_scope, entry.name))
            {
                var root = self.canonical_root;
                var state = root.loadReadOnly(
                    alloc,
                    entry.name,
                    options.log,
                ) catch |err| {
                    candidate.deinit(alloc);
                    return mapReplayError(err);
                };
                defer state.deinit(alloc);
                candidate.deinit(alloc);
                candidate = try dupeWritableCandidate(
                    alloc,
                    state.id,
                    state.workspace_root,
                    state.updated_at_ms,
                    .schema_v3,
                    .current,
                );
            }
            if (!std.mem.eql(u8, candidate.workspace_root, workspace_root)) {
                logDiscovery(
                    .workspace_writable_last,
                    candidate.id,
                    candidate.storage,
                    candidate.projection_state,
                    .workspace_mismatch,
                    .skipped,
                    null,
                );
                candidate.deinit(alloc);
                continue;
            }
            logDiscovery(
                .workspace_writable_last,
                candidate.id,
                candidate.storage,
                candidate.projection_state,
                .listable,
                .retained,
                null,
            );
            if (selected == null or writableCandidateNewer(candidate, selected.?)) {
                if (selected) |*old| old.deinit(alloc);
                selected = candidate;
            } else {
                candidate.deinit(alloc);
            }
        }
        if (selected) |candidate| {
            logDiscovery(
                .workspace_writable_last,
                candidate.id,
                candidate.storage,
                candidate.projection_state,
                .listable,
                .selected,
                null,
            );
            return try alloc.dupe(u8, candidate.id);
        }
        return null;
    }

    fn resolveWritableCandidate(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        options: ResumeOptions,
    ) !WritableCandidate {
        var session_dir = try self.openSessionDir(session_id);
        defer session_dir.close();
        return switch (try classifyAuthority(alloc, &session_dir, session_id)) {
            .legacy => {
                var candidate = try classifyLegacyCandidate(
                    alloc,
                    &session_dir,
                    session_id,
                );
                defer candidate.deinit(alloc);
                return dupeWritableCandidate(
                    alloc,
                    candidate.summary.id,
                    candidate.summary.workspace_root orelse self.workspace_root,
                    candidate.summary.updated_at_ms,
                    candidate.storage,
                    .current,
                );
            },
            .schema_v3 => {
                var projected: ?ReadOnlyCandidate = null;
                defer if (projected) |*candidate| candidate.deinit(alloc);
                if (classifySchemaV3Candidate(
                    alloc,
                    &session_dir,
                    session_id,
                )) |candidate_value| {
                    projected = candidate_value;
                    const candidate = projected.?;
                    if (candidate.projection_state == .current) {
                        return dupeWritableCandidate(
                            alloc,
                            candidate.summary.id,
                            candidate.summary.workspace_root.?,
                            candidate.summary.updated_at_ms,
                            .schema_v3,
                            .current,
                        );
                    }
                } else |err| switch (err) {
                    error.OutOfMemory,
                    error.UnsupportedSessionSchema,
                    error.SessionAuthorityBoundaryUnavailable,
                    => return err,
                    else => {},
                }

                var root = self.canonical_root;
                var state = root.loadReadOnly(
                    alloc,
                    session_id,
                    options.log,
                ) catch |err| {
                    const mapped = mapReplayError(err);
                    if (mapped != error.SessionCommitBoundaryUnavailable) return mapped;
                    const candidate = projected orelse return mapped;
                    if (std.mem.eql(
                        u8,
                        candidate.summary.workspace_root.?,
                        workspace_root,
                    )) return mapped;
                    return dupeWritableCandidate(
                        alloc,
                        candidate.summary.id,
                        candidate.summary.workspace_root.?,
                        candidate.summary.updated_at_ms,
                        .schema_v3,
                        .stale,
                    );
                };
                defer state.deinit(alloc);
                return dupeWritableCandidate(
                    alloc,
                    state.id,
                    state.workspace_root,
                    state.updated_at_ms,
                    .schema_v3,
                    .stale,
                );
            },
        };
    }

    fn migrateLegacyForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded: LoadedWritableSession = undefined;
        try self.migrateLegacyForWriteInto(
            &loaded,
            alloc,
            session_id,
            workspace_root,
            preference_source,
            options,
        );
        return loaded;
    }

    // Keep cold fallible constructors behind noinline out-parameter boundaries
    // so error returns do not materialize the full LoadedWritableSession payload.
    noinline fn migrateLegacyForWriteInto(
        self: Store,
        out: *LoadedWritableSession,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !void {
        if (self.canonical_root.mode != .writable or
            self.canonical_root.sessions == null)
        {
            return error.SessionStoreUnavailable;
        }
        var dir = self.canonical_root.sessions.?.dir.openDir(
            io_mod.getIo(),
            session_id,
            .{
                .iterate = true,
                .follow_symlinks = false,
            },
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        prepareWritableSessionDir(dir) catch |err| {
            dir.close(io_mod.getIo());
            return err;
        };
        var verified = io_mod.VerifiedDir{ .dir = dir };
        var writer_lock = io_mod.acquireTimedAdvisoryLock(
            &verified,
            "session.lock",
            options.log.session_lock_deadline_ms,
        ) catch |err| switch (err) {
            error.LockBusy => return error.SessionBusy,
            error.LockUnsupported => return error.SessionLockUnsupported,
            else => return err,
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close(io_mod.getIo());
            return err;
        };
        var writable = session_log.WritableSessionDir{
            .dir = verified,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
        const loaded = self.migrateLegacyWithLatestCache(
            alloc,
            &writable,
            workspace_root,
            preference_source,
            options,
        ) catch |err| {
            writable.deinit(alloc);
            return err;
        };
        out.* = loaded;
    }

    fn migrateLegacyWithLatestCache(
        self: Store,
        alloc: Allocator,
        writable: *session_log.WritableSessionDir,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var lifecycle: ?session_log.CommitLifecycle = try self.makeLatestCacheLifecycle(
            alloc,
            .maintain,
            options.log.test_controls,
        );
        errdefer if (lifecycle) |*value| value.deinit(alloc);
        return migrateLegacyLocked(
            self.ctx(),
            alloc,
            writable,
            workspace_root,
            preference_source,
            options,
            &lifecycle,
        );
    }

    fn resolveAuthorityTransitionForWrite(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !LoadedWritableSession {
        var loaded: LoadedWritableSession = undefined;
        try self.resolveAuthorityTransitionForWriteInto(
            &loaded,
            alloc,
            session_id,
            workspace_root,
            preference_source,
            options,
        );
        return loaded;
    }

    noinline fn resolveAuthorityTransitionForWriteInto(
        self: Store,
        out: *LoadedWritableSession,
        alloc: Allocator,
        session_id: []const u8,
        workspace_root: []const u8,
        preference_source: MigrationPreferenceSource,
        options: ResumeOptions,
    ) !void {
        var read_dir = try self.openSessionDir(session_id);
        var transition = (try loadAuthorityTransitionOptional(
            alloc,
            &read_dir,
        )) orelse {
            read_dir.close();
            return error.SessionAuthorityBoundaryUnavailable;
        };
        read_dir.close();
        defer transition.deinit(alloc);
        try requireAuthorityTransitionSession(transition, session_id);

        if (transition.kind == .session_create) {
            var root = self.canonical_root;
            const loaded = try root.resumeForWrite(
                alloc,
                session_id,
                options.log,
            );
            out.* = loaded;
            return;
        }

        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.log.session_lock_deadline_ms,
        );
        var commit_lock = io_mod.acquireTimedAdvisoryLock(
            &writable.dir,
            "commit.lock",
            options.log.commit_lock_deadline_ms,
        ) catch |err| {
            writable.deinit(alloc);
            return switch (err) {
                error.LockBusy, error.LockUnsupported => error.SessionCommitBoundaryUnavailable,
                else => err,
            };
        };
        var commit_lock_held = true;
        defer if (commit_lock_held) commit_lock.release();
        errdefer writable.deinit(alloc);

        var current = (try loadAuthorityTransitionOptional(
            alloc,
            &writable.dir,
        )) orelse return error.SessionAuthorityBoundaryUnavailable;
        defer current.deinit(alloc);
        try requireAuthorityTransitionSession(current, session_id);
        if (!authorityTransitionsEqual(current, transition)) {
            return error.InvalidSessionFormat;
        }

        const target_state: ?session_codec.DurableSessionState =
            validateMigrationTarget(
                alloc,
                &writable.dir,
                session_id,
                current.authority_id,
                current.proposed,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
                else => null,
            };
        if (target_state) |validated_state| {
            var state = validated_state;
            errdefer state.deinit(alloc);
            var lifecycle = try self.makeLatestCacheLifecycle(
                alloc,
                .maintain,
                options.log.test_controls,
            );
            errdefer lifecycle.deinit(alloc);
            try lifecycle.prepare(
                alloc,
                writable.session_id,
                state.workspace_root,
                state.workspace_root,
                options.log.commit_lock_deadline_ms,
            );
            io_mod.syncVerifiedDir(writable.dir.dir) catch
                return error.LegacySessionMigrationIndeterminate;
            deleteSessionEntry(
                &writable.dir,
                "authority.pending.json",
            ) catch return error.SessionAuthorityIntentCleanupPending;
            commit_lock.release();
            commit_lock_held = false;
            var loaded = try loadedMigrationTarget(
                alloc,
                &writable,
                state,
                current,
            );
            state = undefined;
            errdefer loaded.deinit(alloc);
            try loaded.installCommitLifecycle(lifecycle);
            _ = loaded.publishCommitLifecycle(alloc);
            out.* = loaded;
            return;
        }

        try restoreLegacyAuthority(alloc, &writable, current);
        commit_lock.release();
        commit_lock_held = false;
        const loaded = try self.migrateLegacyWithLatestCache(
            alloc,
            &writable,
            workspace_root,
            preference_source,
            options,
        );
        out.* = loaded;
    }

    fn openWritableSessionDir(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        session_lock_deadline_ms: u64,
    ) !session_log.WritableSessionDir {
        const sessions = self.canonical_root.sessions orelse
            return error.SessionStoreUnavailable;
        var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        prepareWritableSessionDir(dir) catch |err| {
            dir.close(io_mod.getIo());
            return err;
        };
        var verified = io_mod.VerifiedDir{ .dir = dir };
        var writer_lock = io_mod.acquireTimedAdvisoryLock(
            &verified,
            "session.lock",
            session_lock_deadline_ms,
        ) catch |err| {
            dir.close(io_mod.getIo());
            return switch (err) {
                error.LockBusy => error.SessionBusy,
                error.LockUnsupported => error.SessionLockUnsupported,
                else => err,
            };
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close(io_mod.getIo());
            return err;
        };
        return .{
            .dir = verified,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
    }

    /// Migrates a legacy session to schema-v3 in place without returning a live
    /// session, reporting the source schema/bytes. Idempotent on already-current
    /// sessions. Caller owns the returned result.
    pub fn migrateLegacyStorageOnly(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: MigrationOptions,
    ) !SessionMigrationResult {
        try validateSessionId(session_id);
        var session_dir = try self.openSessionDir(session_id);
        const authority = (if (options.allow_large)
            classifyAuthorityAllowingLargeLegacy(alloc, &session_dir, session_id)
        else
            classifyAuthority(alloc, &session_dir, session_id)) catch |err| switch (err) {
            error.SessionAuthorityBoundaryUnavailable => {
                var transition = (try loadAuthorityTransitionOptional(
                    alloc,
                    &session_dir,
                )) orelse {
                    session_dir.close();
                    return error.SessionAuthorityBoundaryUnavailable;
                };
                defer transition.deinit(alloc);
                try requireAuthorityTransitionSession(transition, session_id);
                session_dir.close();
                var resolved = try self.resolveAuthorityTransitionForWrite(
                    alloc,
                    session_id,
                    self.workspace_root,
                    .preserved_workspace,
                    .{
                        .allow_large_legacy = options.allow_large,
                        .seed_preferences = options.seed_preferences,
                        .log = options.log,
                    },
                );
                defer resolved.deinit(alloc);
                if (transition.kind == .session_create) {
                    return .{
                        .session_id = try alloc.dupe(u8, session_id),
                        .source_schema_version = 3,
                        .source_bytes = 0,
                        .status = .already_current,
                    };
                }
                const source_schema_version = resolved.migration_source_schema_version orelse try migratedSourceSchemaVersion(
                    alloc,
                    &resolved.log.dir,
                    options.allow_large,
                );
                const source_bytes = resolved.migration_source_bytes orelse try migratedSourceBytes(&resolved.log.dir);
                return .{
                    .session_id = try alloc.dupe(u8, session_id),
                    .source_schema_version = source_schema_version,
                    .source_bytes = source_bytes,
                    .status = .migrated,
                };
            },
            else => {
                session_dir.close();
                return err;
            },
        };
        session_dir.close();
        if (authority == .schema_v3) {
            return .{
                .session_id = try alloc.dupe(u8, session_id),
                .source_schema_version = 3,
                .source_bytes = 0,
                .status = .already_current,
            };
        }
        var migrated = try self.migrateLegacyForWrite(
            alloc,
            session_id,
            self.workspace_root,
            .preserved_workspace,
            .{
                .allow_large_legacy = options.allow_large,
                .seed_preferences = options.seed_preferences,
                .log = options.log,
            },
        );
        defer migrated.deinit(alloc);
        const source_schema_version = migrated.migration_source_schema_version orelse try migratedSourceSchemaVersion(
            alloc,
            &migrated.log.dir,
            options.allow_large,
        );
        const source_bytes = migrated.migration_source_bytes orelse try migratedSourceBytes(&migrated.log.dir);
        return .{
            .session_id = try alloc.dupe(u8, session_id),
            .source_schema_version = source_schema_version,
            .source_bytes = source_bytes,
            .status = .migrated,
        };
    }

    /// Creates a new schema-v3 session from the exact validated manifest
    /// boundary of a source whose commit watermark is corrupt. The source is
    /// locked for the read and is never modified.
    pub fn recoverSessionCopy(
        self: Store,
        alloc: Allocator,
        session_id: []const u8,
        options: session_log.Options,
    ) !SessionRecoveryResult {
        try validateSessionId(session_id);
        var source = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.session_lock_deadline_ms,
        );
        defer source.deinit(alloc);
        const authority = try classifyAuthority(
            alloc,
            &source.dir,
            session_id,
        );
        if (authority != .schema_v3) {
            return error.SessionRecoveryRequiresCurrentSchema;
        }
        var manifest_file = openSessionFile(
            &source.dir,
            "session.json",
            .read_only,
        ) catch return error.SessionRecoveryBoundaryInvalid;
        defer manifest_file.close(io_mod.getIo());
        const manifest_stat = try manifest_file.stat(io_mod.getIo());
        if (manifest_stat.size > session_projection.manifest_max_bytes) {
            return error.SessionRecoveryBoundaryInvalid;
        }
        const manifest_bytes = readExactLegacyFile(
            alloc,
            &manifest_file,
            manifest_stat.size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionRecoveryBoundaryInvalid,
        };
        defer alloc.free(manifest_bytes);
        const manifest_schema = authority_module.manifestSchemaVersion(
            alloc,
            manifest_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SessionRecoveryBoundaryInvalid,
        };
        if (manifest_schema != 3) {
            return error.SessionRecoveryUnsupportedSchema;
        }

        var recovered = session_log.recoverManifestBoundary(
            alloc,
            &source,
            options,
        ) catch |err| switch (err) {
            error.OutOfMemory,
            error.SessionRecoveryNotNeeded,
            error.SessionAuthorityBoundaryUnavailable,
            error.SessionCommitBoundaryUnavailable,
            error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported,
            => return err,
            error.UnsupportedSessionSchema => return error.SessionRecoveryUnsupportedSchema,
            else => return error.SessionRecoveryBoundaryInvalid,
        };
        defer recovered.deinit(alloc);
        try resolveSessionSnapshotLocators(
            alloc,
            recovered.history,
            self.sessions_dir,
            session_id,
        );
        const source_dir_path = try sessionDirPath(
            alloc,
            self.sessions_dir,
            session_id,
        );
        defer alloc.free(source_dir_path);
        var source_children = try session_child_store.SessionChildCapability.init(
            alloc,
            source.dir.dir,
            source_dir_path,
            .read_only,
        );
        defer source_children.deinit();

        const source_id = try alloc.dupe(u8, recovered.id);
        errdefer alloc.free(source_id);
        const recovered_id = try generateSessionId(alloc);
        errdefer alloc.free(recovered_id);
        const replacement_id = try alloc.dupe(u8, recovered_id);
        alloc.free(recovered.id);
        recovered.id = replacement_id;

        var initial = try recoveryInitialState(alloc, recovered);
        defer initial.deinit(alloc);
        var staging_lock = try self.acquireRecoveryStagingLock(
            options.session_lock_deadline_ms,
        );
        defer staging_lock.release();
        var staging_root = try self.initRecoveryStagingRoot(alloc);
        defer self.deinitRecoveryStagingRoot(alloc, &staging_root);
        try cleanupAbandonedRecoveryStages(&staging_root);
        var target = try self.startRecoveryStagedSession(
            alloc,
            &staging_root,
            initial,
            options,
        );
        var target_owned = true;
        var target_promoted = false;
        errdefer if (target_owned) {
            if (target_promoted) {
                target.deinit(alloc);
            } else {
                const disposition = discardRecoveryStagedSession(
                    &staging_root,
                    alloc,
                    &target,
                );
                if (disposition != .discarded) {
                    debug_trace.logf(
                        "session",
                        "event=session_recovery_unpublished_target_cleanup disposition={s}",
                        .{@tagName(disposition)},
                    );
                }
            }
            target_owned = false;
        };

        const staged_target_dir = try sessionDirPath(
            alloc,
            staging_root.display_root,
            recovered_id,
        );
        defer alloc.free(staged_target_dir);
        const staged_target_images = try std.fs.path.join(
            alloc,
            &.{ staged_target_dir, "images" },
        );
        defer alloc.free(staged_target_images);
        const target_dir = try sessionDirPath(
            alloc,
            self.sessions_dir,
            recovered_id,
        );
        defer alloc.free(target_dir);
        const target_images = try std.fs.path.join(
            alloc,
            &.{ target_dir, "images" },
        );
        defer alloc.free(target_images);
        try copyRecoveredImageSnapshots(
            alloc,
            recovered.history,
            staged_target_images,
        );
        try rebaseRecoveredImageSnapshots(
            alloc,
            recovered.history,
            staged_target_images,
            target_images,
        );
        const contains_unverified_artifacts = try copyRecoveredManagedChildren(
            alloc,
            recovered.history,
            &source_children,
            target.child_capability orelse
                return error.SessionChildStoreFailed,
        );
        _ = target.commitStateReplacement(
            alloc,
            recovered,
            .recovery,
            .rollback_before_adapter_continue,
            options,
        ) catch |commit_err| {
            target.namespace_confirmation_required = true;
            target.validateResumeBoundary(alloc, options) catch |resolve_err| {
                debug_trace.logf(
                    "session",
                    "event=session_recovery_target_indeterminate target={s} commit_err={s} resolve_err={s}",
                    .{
                        recovered_id,
                        @errorName(commit_err),
                        @errorName(resolve_err),
                    },
                );
                const disposition = discardRecoveryStagedSession(
                    &staging_root,
                    alloc,
                    &target,
                );
                target_owned = false;
                if (disposition != .discarded) {
                    debug_trace.logf(
                        "session",
                        "event=session_recovery_staged_target_cleanup disposition={s}",
                        .{@tagName(disposition)},
                    );
                }
                return error.SessionRecoveryIndeterminate;
            };
        };
        if (!try session_log.durableStatesEqual(target.state, recovered)) {
            const disposition = discardRecoveryStagedSession(
                &staging_root,
                alloc,
                &target,
            );
            target_owned = false;
            if (disposition != .discarded) {
                debug_trace.logf(
                    "session",
                    "event=session_recovery_staged_target_cleanup disposition={s}",
                    .{@tagName(disposition)},
                );
            }
            return error.SessionRecoveryIndeterminate;
        }
        target.validateResumeBoundary(alloc, options) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_indeterminate target={s} validation_err={s}",
                .{ recovered_id, @errorName(err) },
            );
            const disposition = discardRecoveryStagedSession(
                &staging_root,
                alloc,
                &target,
            );
            target_owned = false;
            if (disposition != .discarded) {
                debug_trace.logf(
                    "session",
                    "event=session_recovery_staged_target_cleanup disposition={s}",
                    .{@tagName(disposition)},
                );
            }
            return error.SessionRecoveryIndeterminate;
        };
        const promotion = self.promoteRecoveryStagedSession(
            &staging_root,
            recovered_id,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_promotion_failed target={s} err={s}",
                .{ recovered_id, @errorName(err) },
            );
            return error.SessionRecoveryIndeterminate;
        };
        target_promoted = true;
        if (promotion == .indeterminate) {
            target.deinit(alloc);
            target_owned = false;
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .status = .indeterminate,
            };
        }
        try options.test_controls.boundary(
            .before_recovery_latest_publication,
        );
        self.publishRecoveredLatestPointer(
            alloc,
            recovered,
            target.position,
            source_id,
            options,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_indeterminate target={s} latest_err={s}",
                .{ recovered_id, @errorName(err) },
            );
            target.deinit(alloc);
            target_owned = false;
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .status = .indeterminate,
            };
        };
        target.deinit(alloc);
        target_owned = false;

        var verified = self.resumeExactForWrite(
            alloc,
            recovered_id,
            recovered.workspace_root,
            false,
            .{ .log = options },
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=session_recovery_target_indeterminate target={s} verify_err={s}",
                .{ recovered_id, @errorName(err) },
            );
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .status = .indeterminate,
            };
        };
        defer verified.deinit(alloc);
        if (!try session_log.durableStatesEqual(verified.state, recovered)) {
            return .{
                .source_session_id = source_id,
                .recovered_session_id = recovered_id,
                .history_len = recovered.history.len,
                .status = .indeterminate,
            };
        }

        return .{
            .source_session_id = source_id,
            .recovered_session_id = recovered_id,
            .history_len = recovered.history.len,
            .status = if (contains_unverified_artifacts)
                .recovered_with_unverified_artifacts
            else
                .recovered,
        };
    }
};

pub const PristineDiscardDisposition = enum {
    discarded,
    retained,
    indeterminate,
};

const RecoveryPromotionStatus = enum {
    promoted,
    indeterminate,
};

fn recoveryInitialState(
    alloc: Allocator,
    recovered: session_codec.DurableSessionState,
) !session_codec.DurableSessionState {
    const id = try alloc.dupe(u8, recovered.id);
    errdefer alloc.free(id);
    const origin = try alloc.dupe(u8, recovered.origin_workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, recovered.workspace_root);
    errdefer alloc.free(workspace);
    return .{
        .id = id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = recovered.created_at_ms,
        .updated_at_ms = recovered.updated_at_ms,
        .conversation_language = recovered.conversation_language,
        .preferences = try recovered.preferences.dupe(alloc),
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

fn copyRecoveredImageSnapshots(
    alloc: Allocator,
    history: []session.HistoryTurn,
    target_images: []const u8,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .background_command => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        for (images) |*image| {
            if (image.snapshot_path == null) continue;
            const copied = image_attachments.copyVerifiedImageAttachmentToDir(
                alloc,
                image.*,
                image.id,
                target_images,
            ) catch |err| switch (err) {
                error.FileNotFound,
                error.InvalidImageId,
                error.MissingImageSnapshot,
                error.InvalidImageSnapshotDigest,
                error.NotRegularFile,
                error.ImageTooLarge,
                error.ImageSnapshotCorrupt,
                error.UnsupportedImageType,
                error.ImageSnapshotMediaTypeMismatch,
                => return error.SessionRecoveryBoundaryInvalid,
                else => return err,
            };
            core_types.freeImageAttachment(alloc, image.*);
            image.* = copied;
        }
    }
}

fn rebaseRecoveredImageSnapshots(
    alloc: Allocator,
    history: []session.HistoryTurn,
    staged_images: []const u8,
    target_images: []const u8,
) !void {
    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .background_command => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        for (images) |*image| {
            const staged_path = image.snapshot_path orelse continue;
            const parent = std.fs.path.dirname(staged_path) orelse
                return error.SessionRecoveryBoundaryInvalid;
            if (!std.mem.eql(u8, parent, staged_images)) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            const leaf = std.fs.path.basename(staged_path);
            const target_path = try std.fs.path.join(
                alloc,
                &.{ target_images, leaf },
            );
            alloc.free(staged_path);
            image.snapshot_path = target_path;
        }
    }
}

fn copyRecoveredManagedChildren(
    alloc: Allocator,
    history: []session.HistoryTurn,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
) !bool {
    var contains_unverified_artifacts = false;
    for (history) |*turn| {
        const execution = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| &entry.execution,
            .background_command => |*entry| &entry.execution,
            .interrupted => |*entry| &entry.execution,
        };
        for (execution.tool_steps) |*step| {
            for (step.tool_results) |*result| {
                if (result.output_handle) |handle| {
                    try copyRecoveredManagedChild(
                        alloc,
                        source,
                        target,
                        .tool_results,
                        handle,
                        result.stored_output_bytes,
                    );
                }
                if (result.command_output_replay) |replay| {
                    contains_unverified_artifacts =
                        (try copyRecoveredCommandReplay(
                            alloc,
                            source,
                            target,
                            replay,
                        )) or contains_unverified_artifacts;
                }
            }
        }
        if (turn.* == .interrupted) {
            const presentation = if (turn.interrupted.cancelled_command) |*value|
                value
            else
                continue;
            if (presentation.output_replay) |replay| {
                contains_unverified_artifacts =
                    (try copyRecoveredCommandReplay(
                        alloc,
                        source,
                        target,
                        replay,
                    )) or contains_unverified_artifacts;
            }
            if (presentation.command_artifact_handle) |handle| {
                const authenticated = artifact_digest.hasContentDigest(
                    handle,
                    ".log",
                );
                try copyRecoveredManagedChild(
                    alloc,
                    source,
                    target,
                    .command_artifacts,
                    handle,
                    null,
                );
                if (!authenticated) contains_unverified_artifacts = true;
            }
        }
    }
    return contains_unverified_artifacts;
}

fn copyRecoveredCommandReplay(
    alloc: Allocator,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
    replay: core_types.CommandOutputReplay,
) !bool {
    switch (replay) {
        .available => |descriptor| {
            const authenticated = command_replay_store.hasContentDigest(
                descriptor.handle,
            );
            try copyRecoveredManagedChild(
                alloc,
                source,
                target,
                .command_artifacts,
                descriptor.handle,
                descriptor.framed_bytes,
            );
            var reader = command_replay_store.Reader.open(
                alloc,
                target,
                descriptor,
            ) catch return error.SessionRecoveryBoundaryInvalid;
            defer reader.deinit();
            while (reader.nextByte() catch
                return error.SessionRecoveryBoundaryInvalid) |_|
            {}
            return !authenticated;
        },
        .unavailable => return false,
    }
}

fn copyRecoveredManagedChild(
    alloc: Allocator,
    source: *session_child_store.SessionChildCapability,
    target: *session_child_store.SessionChildCapability,
    kind: session_child_store.ManagedChildKind,
    handle: []const u8,
    expected_bytes: ?usize,
) !void {
    var source_file = source.openFileReadOnly(
        alloc,
        kind,
        handle,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SessionRecoveryBoundaryInvalid,
        else => return err,
    };
    defer source_file.deinit();
    const source_stat = try source_file.stat();
    if (expected_bytes) |expected| {
        const expected_u64 = std.math.cast(u64, expected) orelse
            return error.SessionRecoveryBoundaryInvalid;
        if (source_stat.size != expected_u64) {
            return error.SessionRecoveryBoundaryInvalid;
        }
    }
    var target_file = target.createExclusiveFile(
        alloc,
        kind,
        handle,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var existing = try target.openFileReadOnly(alloc, kind, handle);
            defer existing.deinit();
            const existing_stat = try existing.stat();
            if (existing_stat.size != source_stat.size) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            const source_digest = try managedFileDigest(
                &source_file,
                source_stat.size,
            );
            const existing_digest = try managedFileDigest(
                &existing,
                existing_stat.size,
            );
            if (!std.mem.eql(u8, &source_digest, &existing_digest)) {
                return error.SessionRecoveryBoundaryInvalid;
            }
            try validateRecoveredManagedChildDigest(
                kind,
                handle,
                expected_bytes,
                source_digest,
            );
            return;
        },
        else => return err,
    };
    var copied = false;
    defer {
        target_file.deinit();
        if (!copied) target.delete(kind, handle) catch {};
    }

    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    var source_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (offset < source_stat.size) {
        const remaining = source_stat.size - offset;
        const chunk_len = std.math.cast(
            usize,
            @min(remaining, buffer.len),
        ) orelse return error.SessionChildStoreFailed;
        const read_len = source_file.readRangeInto(
            offset,
            buffer[0..chunk_len],
        ) catch return error.SessionRecoveryBoundaryInvalid;
        if (read_len == 0) return error.SessionRecoveryBoundaryInvalid;
        source_hasher.update(buffer[0..read_len]);
        try target_file.writeAll(buffer[0..read_len]);
        offset = std.math.add(u64, offset, read_len) catch
            return error.SessionChildStoreFailed;
    }
    try target_file.sync();
    var source_digest: [32]u8 = undefined;
    source_hasher.final(&source_digest);
    try validateRecoveredManagedChildDigest(
        kind,
        handle,
        expected_bytes,
        source_digest,
    );
    var target_reader = try target.openFileReadOnly(alloc, kind, handle);
    defer target_reader.deinit();
    const target_digest = try managedFileDigest(
        &target_reader,
        source_stat.size,
    );
    if (!std.mem.eql(u8, &source_digest, &target_digest)) {
        return error.SessionChildStoreFailed;
    }
    copied = true;
}

fn managedFileDigest(
    file: *session_child_store.ManagedFile,
    size: u64,
) ![32]u8 {
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (offset < size) {
        const remaining = size - offset;
        const chunk_len = std.math.cast(
            usize,
            @min(remaining, buffer.len),
        ) orelse return error.SessionRecoveryBoundaryInvalid;
        const read_len = file.readRangeInto(
            offset,
            buffer[0..chunk_len],
        ) catch return error.SessionRecoveryBoundaryInvalid;
        if (read_len == 0) return error.SessionRecoveryBoundaryInvalid;
        hasher.update(buffer[0..read_len]);
        offset = std.math.add(u64, offset, read_len) catch
            return error.SessionRecoveryBoundaryInvalid;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn validateRecoveredManagedChildDigest(
    kind: session_child_store.ManagedChildKind,
    handle: []const u8,
    expected_bytes: ?usize,
    digest: [32]u8,
) !void {
    switch (kind) {
        .tool_results => if (!result_store.handleMatchesContentDigest(
            handle,
            digest,
        )) return error.SessionRecoveryBoundaryInvalid,
        .command_artifacts => {
            if (expected_bytes != null and
                command_replay_store.hasContentDigest(handle) and
                !command_replay_store.handleMatchesContentDigest(
                    handle,
                    digest,
                ))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
            if (expected_bytes == null and
                artifact_digest.hasContentDigest(handle, ".log") and
                !artifact_digest.handleMatchesContentDigest(
                    handle,
                    ".log",
                    digest,
                ))
            {
                return error.SessionRecoveryBoundaryInvalid;
            }
        },
        else => return error.SessionRecoveryBoundaryInvalid,
    }
}

fn canonicalSnapshotLeaf(image: session.ImageAttachment, stored: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(stored)) return error.InvalidSessionFormat;
    const prefix = "images/";
    if (!std.mem.startsWith(u8, stored, prefix)) return error.InvalidSessionFormat;
    const leaf = stored[prefix.len..];
    if (leaf.len == 0 or
        std.mem.indexOfAny(u8, leaf, "/\\") != null or
        std.mem.eql(u8, leaf, ".") or
        std.mem.eql(u8, leaf, ".."))
    {
        return error.InvalidSessionFormat;
    }

    const digest = image.snapshot_sha256 orelse return error.InvalidSessionFormat;
    if (image.id == 0 or digest.len != 64) return error.InvalidSessionFormat;
    for (digest) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return error.InvalidSessionFormat;
        }
    }
    var expected_buffer: [128]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &expected_buffer,
        "image-{d}-{s}.bin",
        .{ image.id, digest[0..16] },
    ) catch return error.InvalidSessionFormat;
    if (!std.mem.eql(u8, leaf, expected)) return error.InvalidSessionFormat;
    return leaf;
}

fn resolveSessionSnapshotLocators(
    alloc: Allocator,
    history: []session.HistoryTurn,
    sessions_dir: []const u8,
    session_id: []const u8,
) !void {
    const session_dir = try sessionDirPath(alloc, sessions_dir, session_id);
    defer alloc.free(session_dir);
    const image_dir = try std.fs.path.join(alloc, &.{ session_dir, "images" });
    defer alloc.free(image_dir);

    for (history) |*turn| {
        const images = switch (turn.*) {
            .compacted_summary => continue,
            .assistant => |*entry| entry.user.images,
            .background_command => |*entry| entry.user.images,
            .interrupted => |*entry| entry.user.images,
        };
        for (images) |*image| {
            const stored = image.snapshot_path orelse continue;
            const leaf = try canonicalSnapshotLeaf(image.*, stored);
            const resolved = try std.fs.path.join(alloc, &.{ image_dir, leaf });
            alloc.free(stored);
            image.snapshot_path = resolved;
        }
    }
}

fn deleteSnapshotFilesAddedByMigration(
    candidate: []const session.HistoryTurn,
    original: []const session.HistoryTurn,
) void {
    for (candidate, original) |candidate_turn, original_turn| {
        const candidate_images = switch (candidate_turn) {
            .compacted_summary => &.{},
            .assistant => |entry| entry.user.images,
            .background_command => |entry| entry.user.images,
            .interrupted => |entry| entry.user.images,
        };
        const original_images = switch (original_turn) {
            .compacted_summary => &.{},
            .assistant => |entry| entry.user.images,
            .background_command => |entry| entry.user.images,
            .interrupted => |entry| entry.user.images,
        };
        image_attachments.deleteUnreferencedImageSnapshots(
            candidate_images,
            original_images,
        );
    }
}

pub fn isPristineStartedSession(loaded: *const LoadedWritableSession) bool {
    return loaded.freshly_started and
        std.mem.eql(u8, loaded.active_id, loaded.state.id) and
        std.mem.eql(u8, loaded.log.session_id, loaded.state.id) and
        loaded.state.history.len == 0 and
        loaded.state.context_history_start == 0 and
        loaded.state.total_input_tokens == 0 and
        loaded.state.total_output_tokens == 0 and
        loaded.state.recovery_checkpoint == null and
        !loaded.namespace_confirmation_required and
        loaded.degraded_tail == null and
        loaded.migration_source_schema_version == null and
        loaded.migration_source_bytes == null;
}

fn loadedWriterBelongsToStore(
    store: Store,
    alloc: Allocator,
    loaded: *const LoadedWritableSession,
) !bool {
    return loadedWriterBelongsToRoot(
        alloc,
        loaded,
        store.sessions_dir,
    );
}

fn loadedWriterBelongsToRoot(
    alloc: Allocator,
    loaded: *const LoadedWritableSession,
    root_path: []const u8,
) !bool {
    const actual_path = try io_mod.dirRealpathAlloc(
        alloc,
        loaded.log.dir.dir,
        "",
    );
    defer alloc.free(actual_path);
    const expected_path = try sessionDirPath(
        alloc,
        root_path,
        loaded.active_id,
    );
    defer alloc.free(expected_path);
    return std.mem.eql(u8, expected_path, actual_path);
}

fn prepareWritableSessionDir(dir: std.Io.Dir) !void {
    const permissions = std.Io.File.Permissions.fromMode(0o700);
    dir.setPermissions(io_mod.getIo(), permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.SessionPathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn initWithHome(alloc: Allocator, home: []const u8, workspace_root: []const u8, ensure_layout: bool) !Store {
    const trimmed_workspace = normalizeWorkspaceRoot(workspace_root);
    if (trimmed_workspace.len == 0) return error.InvalidWorkspaceRoot;

    var canonical_root = session_log.Root.initFromHome(
        alloc,
        home,
        if (ensure_layout) .writable else .read_only,
    ) catch |err| switch (err) {
        error.OutOfMemory,
        error.PrivateStatePermissionsUnsupported,
        error.SessionPathUnsafe,
        => return err,
        else => {
            if (!ensure_layout) return err;
            debug_trace.logf(
                "session",
                "event=writable_layout_failed source_error={s} mapped_error=DurableLayoutFailed",
                .{@errorName(err)},
            );
            return error.DurableLayoutFailed;
        },
    };
    errdefer canonical_root.deinit(alloc);
    const sessions_dir = try alloc.dupe(u8, canonical_root.display_root);
    errdefer alloc.free(sessions_dir);
    const home_dir = try alloc.dupe(u8, home);
    errdefer alloc.free(home_dir);
    const owned_workspace = try alloc.dupe(u8, trimmed_workspace);
    errdefer alloc.free(owned_workspace);
    return .{
        .sessions_dir = sessions_dir,
        .home_dir = home_dir,
        .workspace_root = owned_workspace,
        .canonical_root = canonical_root,
    };
}

fn readLatestPointer(
    self: Store,
    alloc: Allocator,
    workspace_root: []const u8,
) !?LatestPointer {
    const sessions = self.canonical_root.sessions orelse return null;
    if (try summary_codec.deferredCachePresent(&sessions)) {
        return error.InvalidSessionIndex;
    }
    return readLatestPointerFromSessions(&sessions, alloc, workspace_root);
}

fn readPendingLatestSessionId(
    self: Store,
    alloc: Allocator,
    workspace_root: []const u8,
) !?[]u8 {
    const sessions = self.canonical_root.sessions orelse return null;
    return readPendingLatestSessionIdFromSessions(&sessions, alloc, workspace_root);
}

fn latestPointerStillMatches(
    self: Store,
    alloc: Allocator,
    workspace_root: []const u8,
    expected: LatestPointer,
) !bool {
    const revalidated = readLatestPointer(self, alloc, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (revalidated) |latest_value| {
        var latest = latest_value;
        defer latest.deinit(alloc);
        return latest.updated_at_ms == expected.updated_at_ms and
            std.mem.eql(u8, latest.session_id, expected.session_id);
    }
    return false;
}

const LatestBarrierLockContext = struct {
    test_controls: session_log.TestControls,
    contention_reported: bool = false,

    fn tryLock(context: ?*anyopaque, file: std.Io.File) !bool {
        const self: *LatestBarrierLockContext = @ptrCast(@alignCast(context.?));
        const locked = try file.tryLock(io_mod.getIo(), .exclusive);
        if (!locked and !self.contention_reported) {
            self.contention_reported = true;
            try self.test_controls.boundary(.latest_barrier_contended);
        }
        return locked;
    }
};

const TempStore = struct {
    home: []u8,
    workspace: []u8,
    store: Store,

    fn deinit(self: *TempStore, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.workspace);
        alloc.free(self.home);
    }
};

fn initTempStore(alloc: Allocator, tmp: *std.testing.TmpDir) !TempStore {
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    errdefer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    errdefer alloc.free(workspace);
    var store = try Store.initFromHome(alloc, home, workspace);
    errdefer store.deinit(alloc);
    return .{ .home = home, .workspace = workspace, .store = store };
}

fn testDurableState(
    alloc: Allocator,
    id: []const u8,
    workspace_root: []const u8,
) !session_codec.DurableSessionState {
    return .{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, workspace_root),
        .workspace_root = try alloc.dupe(u8, workspace_root),
        .created_at_ms = 10,
        .updated_at_ms = 10,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "test/model"),
            .effort = core_types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

fn expectDeferredCacheTokenMissing(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    session_id: []const u8,
) !void {
    if (try summary_codec.readDeferredCacheToken(
        alloc,
        sessions,
        session_id,
    )) |token_value| {
        var token = token_value;
        defer token.deinit(alloc);
        return error.TestExpectedEqual;
    }
}

fn testIndexedSessionSummary(
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) SessionSummary {
    return .{
        .id = @constCast(id),
        .workspace_root = @constCast(workspace_root),
        .origin_workspace_root = @constCast(workspace_root),
        .title = @constCast(id),
        .preview = @constCast(id),
        .display_metadata_present = true,
        .created_at_ms = updated_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history_len = 0,
    };
}

fn makeSessionDir(alloc: Allocator, store: Store, id: []const u8) !void {
    const dir = try sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(dir);
    try config_runtime.makeAbsolutePath(dir);
}

fn makeRawSessionsEntry(store: Store, name: []const u8) !void {
    const sessions = store.canonical_root.sessions orelse return error.TestExpectedEqual;
    sessions.dir.createDir(
        io_mod.getIo(),
        name,
        std.Io.File.Permissions.fromMode(0o700),
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeRawFile(path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

fn writeSessionFixture(alloc: Allocator, store: Store, id: []const u8, text: []const u8) ![]u8 {
    try makeSessionDir(alloc, store, id);
    const path = try sessionJsonPath(alloc, store.sessions_dir, id);
    try writeRawFile(path, text);
    return path;
}

fn chmodPath(alloc: Allocator, path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ChmodFailed;
}

fn writeLegacyFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: ?[]const u8,
    updated_at_ms: i64,
) !void {
    const text = try session_json.renderSessionJson(
        alloc,
        id,
        10,
        updated_at_ms,
        session.ConversationLanguage.literal("en"),
        workspace_root orelse "",
        &.{},
        .{},
    );
    defer alloc.free(text);
    if (workspace_root == null) {
        const needle = ",\"workspace_root\":\"\"";
        const start = std.mem.find(u8, text, needle) orelse return error.InvalidSessionFormat;
        const without_root = try std.mem.concat(alloc, u8, &.{
            text[0..start],
            text[start + needle.len ..],
        });
        defer alloc.free(without_root);
        const path = try writeSessionFixture(alloc, store, id, without_root);
        alloc.free(path);
        return;
    }
    const path = try writeSessionFixture(alloc, store, id, text);
    alloc.free(path);
}

fn writeLegacyIncompleteAuthorityFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    const history = [_]session.HistoryTurn{.{ .compacted_summary = .{
        .summary = @constCast("legacy summary"),
        .removed_turn_count = 2,
        .compaction_count = 1,
        .root_user_messages_complete = false,
        .permission_feedback_complete = false,
    } }};
    const rendered = try session_json.renderSessionJson(
        alloc,
        id,
        10,
        updated_at_ms,
        session.ConversationLanguage.literal("en"),
        workspace_root,
        &history,
        .{},
    );
    defer alloc.free(rendered);
    const path = try writeSessionFixture(alloc, store, id, rendered);
    alloc.free(path);
}

fn writeSummaryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: ?[]const u8,
    updated_at_ms: i64,
    history_len: usize,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "{{\"schema_version\":1,\"id\":\"{s}\",\"created_at_ms\":1,\"updated_at_ms\":{d}",
        .{ id, updated_at_ms },
    );
    if (workspace_root) |root| {
        try out.writer.writeAll(",\"workspace_root\":");
        try std.json.Stringify.value(root, .{}, &out.writer);
    }
    try out.writer.print(
        ",\"conversation_language\":\"en\",\"history_len\":{d},\"history\":",
        .{history_len},
    );
    if (history_len == 0) {
        try out.writer.writeAll("[]}");
    } else {
        try out.writer.writeAll("[{\"role\":\"user\",\"content\":\"saved\"}]}");
    }
    const text = try out.toOwnedSlice();
    defer alloc.free(text);
    const path = try writeSessionFixture(alloc, store, id, text);
    alloc.free(path);
}

fn writeWritableHistoryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
    prompt: []const u8,
) !void {
    return writeWritableHistoryResponseFixture(
        alloc,
        store,
        id,
        workspace_root,
        updated_at_ms,
        prompt,
        "saved response",
    );
}

fn writeWritableHistoryResponseFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
    prompt: []const u8,
    response: []const u8,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    errdefer writable.deinit(alloc);

    var history = try alloc.alloc(session.HistoryTurn, 1);
    history[0] = try session.makeAssistantTurn(alloc, prompt, response);
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    writable.deinit(alloc);
}

fn writeLargeWritableHistoryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
    response_bytes: usize,
) !void {
    const response = try alloc.alloc(u8, response_bytes);
    defer alloc.free(response);
    @memset(response, 'x');
    return writeWritableHistoryResponseFixture(
        alloc,
        store,
        id,
        workspace_root,
        updated_at_ms,
        "unrelated prompt",
        response,
    );
}

fn writeStaleWritableHistoryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    var session_dir = try store.openSessionDir(id);
    defer session_dir.close();
    var manifest_file = try session_dir.dir.openFile(io_mod.getIo(), "session.json", .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    const stale_manifest = try io_mod.readFileToEnd(
        alloc,
        &manifest_file,
        session_projection.manifest_max_bytes + 1,
    );
    manifest_file.close(io_mod.getIo());
    defer alloc.free(stale_manifest);
    const turn = try session.makeAssistantTurn(
        alloc,
        "new canonical prompt",
        "new canonical response",
    );
    defer session.freeHistoryTurn(alloc, turn);
    _ = try writable.appendEvent(
        alloc,
        .{ .history_turn_committed = .{
            .conversation_language = session.ConversationLanguage.literal("en"),
            .total_input_tokens = 3,
            .total_output_tokens = 4,
            .turn = turn,
        } },
        updated_at_ms,
        .retry_expected_tail,
        .{},
    );
    try io_mod.durableReplaceVerified(
        alloc,
        &session_dir,
        "session.json",
        stale_manifest,
    );
}

fn writeDeferredTokenForTest(
    alloc: Allocator,
    store: Store,
    session_id: []const u8,
    workspace_root: []const u8,
) !void {
    var target = try store.resumeTargetForWrite(
        alloc,
        .{ .id = session_id },
        workspace_root,
        .{},
    );
    const position = target.position;
    target.deinit(alloc);
    var sessions = store.canonical_root.sessions orelse return error.TestExpectedEqual;
    const cache = try LatestCache.init(alloc, &sessions, .{}, .maintain);
    defer cache.deinit(alloc);
    try cache.writeDeferredToken(
        alloc,
        session_id,
        workspace_root,
        position,
    );
}

fn writeWritableIncompleteAuthorityFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    errdefer writable.deinit(alloc);

    const history = blk: {
        const owned = try alloc.alloc(session.HistoryTurn, 1);
        errdefer alloc.free(owned);
        const summary = try alloc.dupe(u8, "legacy summary");
        errdefer alloc.free(summary);
        const permission_feedback = try alloc.alloc([]u8, 1);
        errdefer alloc.free(permission_feedback);
        permission_feedback[0] = try alloc.dupe(
            u8,
            "Never mutate the production remote.",
        );
        owned[0] = .{ .compacted_summary = .{
            .summary = summary,
            .removed_turn_count = 2,
            .compaction_count = 1,
            .root_user_messages_complete = false,
            .permission_feedback = permission_feedback,
            .permission_feedback_complete = false,
        } };
        break :blk owned;
    };
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    writable.deinit(alloc);
}

const ManagedHistoryFixtureArtifacts = struct {
    legacy_replay: bool = false,
    legacy_command_artifact: bool = false,
};

fn writeWritableManagedHistoryFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    write_sidecars: bool,
    artifacts: ManagedHistoryFixtureArtifacts,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    const capability = writable.child_capability orelse
        return error.SessionChildStoreFailed;
    const output_text = "complete recovered tool result";
    var output_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output_text, &output_digest, .{});
    const output_digest_hex = std.fmt.bytesToHex(
        output_digest[0..8].*,
        .lower,
    );
    const output_handle = try std.fmt.allocPrint(
        alloc,
        "result-run_command-0000000000000000-{s}.txt",
        .{&output_digest_hex},
    );
    defer alloc.free(output_handle);
    const replay_payload = "recovered command replay";
    var replay_bytes: [8 + 9 + replay_payload.len]u8 = undefined;
    @memcpy(replay_bytes[0..8], "FXRPLY01");
    replay_bytes[8] = 0;
    std.mem.writeInt(
        u64,
        replay_bytes[9..17],
        replay_payload.len,
        .little,
    );
    @memcpy(replay_bytes[17..], replay_payload);
    var replay_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&replay_bytes, &replay_digest, .{});
    const replay_digest_hex = std.fmt.bytesToHex(
        replay_digest[0..8].*,
        .lower,
    );
    const replay_handle = if (artifacts.legacy_replay)
        try alloc.dupe(u8, "fx-command-replay-legacy.bin")
    else
        try std.fmt.allocPrint(
            alloc,
            "fx-command-replay-test-{s}.bin",
            .{&replay_digest_hex},
        );
    defer alloc.free(replay_handle);
    const interrupted_artifact_handle = "fx-command-cancelled.log";
    const interrupted_artifact = "interrupted command artifact";
    if (write_sidecars) {
        var output_file = try capability.createExclusiveFile(
            alloc,
            .tool_results,
            output_handle,
        );
        defer output_file.deinit();
        try output_file.writeAll(output_text);
        try output_file.sync();
        var replay_file = try capability.createExclusiveFile(
            alloc,
            .command_artifacts,
            replay_handle,
        );
        defer replay_file.deinit();
        try replay_file.writeAll(&replay_bytes);
        try replay_file.sync();
        if (artifacts.legacy_command_artifact) {
            var interrupted_file = try capability.createExclusiveFile(
                alloc,
                .command_artifacts,
                interrupted_artifact_handle,
            );
            defer interrupted_file.deinit();
            try interrupted_file.writeAll(interrupted_artifact);
            try interrupted_file.sync();
        }
    }

    const history_len: usize = if (artifacts.legacy_command_artifact) 2 else 1;
    var history = try alloc.alloc(session.HistoryTurn, history_len);
    var initialized_history_len: usize = 0;
    var history_complete = false;
    errdefer if (!history_complete) {
        for (history[0..initialized_history_len]) |turn| {
            session.freeHistoryTurn(alloc, turn);
        }
        alloc.free(history);
    };
    history[0] = try session.makeAssistantTurn(
        alloc,
        "run a command",
        "command complete",
    );
    initialized_history_len += 1;
    if (artifacts.legacy_command_artifact) {
        history[1] = try session.dupeHistoryTurn(alloc, .{ .interrupted = .{
            .user = .{ .text = @constCast("cancel a command") },
            .tool_call = .{
                .id = "call-cancelled",
                .name = "run_command",
                .arguments_json = "{\"command\":\"sleep 30\"}",
            },
            .cancelled_command = .{
                .output_replay = .{ .available = .{
                    .handle = replay_handle,
                    .framed_bytes = replay_bytes.len,
                } },
                .command_artifact_handle = interrupted_artifact_handle,
            },
        } });
        initialized_history_len += 1;
    }
    history_complete = true;
    defer session.freeHistoryTurnSlice(alloc, history);
    const steps = try alloc.alloc(core_types.ToolExecutionStep, 1);
    history[0].assistant.execution.tool_steps = steps;
    steps[0] = .{};
    const results = try alloc.alloc(core_types.PersistedToolResult, 1);
    steps[0].tool_results = results;
    results[0] = try makeManagedRecoveryResult(
        alloc,
        output_handle,
        replay_handle,
    );
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = 20,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
}

fn makeManagedRecoveryResult(
    alloc: Allocator,
    output_handle: []const u8,
    replay_handle: []const u8,
) !core_types.PersistedToolResult {
    const tool_call_id = try alloc.dupe(u8, "call-recovery");
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, "run_command");
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, "preview");
    errdefer alloc.free(output);
    const owned_output_handle = try alloc.dupe(u8, output_handle);
    errdefer alloc.free(owned_output_handle);
    const preview = try alloc.dupe(u8, "preview");
    errdefer alloc.free(preview);
    const owned_replay_handle = try alloc.dupe(u8, replay_handle);
    errdefer alloc.free(owned_replay_handle);
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = .success,
        .output = output,
        .output_handle = owned_output_handle,
        .preview = preview,
        .output_bytes = "complete recovered tool result".len,
        .stored_output_bytes = "complete recovered tool result".len,
        .truncated = true,
        .command_output_replay = .{ .available = .{
            .handle = owned_replay_handle,
            .framed_bytes = 8 + 9 + "recovered command replay".len,
        } },
    };
}

fn corruptFixtureWatermark(
    alloc: Allocator,
    store: Store,
    session_id: []const u8,
) !void {
    var source = try store.resumeForWrite(alloc, session_id);
    const generation = source.position.log_generation;
    source.deinit(alloc);
    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    const watermark_name = try std.fmt.allocPrint(
        alloc,
        "commit.{s}.json",
        .{generation_hex},
    );
    defer alloc.free(watermark_name);
    try writeFixtureEntry(
        alloc,
        store,
        session_id,
        watermark_name,
        "{}\n",
    );
}

fn replaceHistoryPageFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    updated_at_ms: i64,
    count: usize,
    label: []const u8,
) !void {
    var writable = try store.resumeForWrite(alloc, id);
    defer writable.deinit(alloc);
    var history = try alloc.alloc(session.HistoryTurn, count);
    var initialized: usize = 0;
    errdefer {
        for (history[0..initialized]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(history);
    }
    for (history, 0..) |*turn, index| {
        const prompt = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ label, index });
        defer alloc.free(prompt);
        turn.* = try session.makeAssistantTurn(alloc, prompt, "saved response");
        initialized += 1;
    }
    defer session.freeHistoryTurnSlice(alloc, history);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
}

fn makeTaggedHistoryPageTurns(
    alloc: Allocator,
    count: usize,
    label: []const u8,
) ![]session.HistoryTurn {
    const history = try alloc.alloc(session.HistoryTurn, count);
    var initialized: usize = 0;
    errdefer {
        for (history[0..initialized]) |turn| session.freeHistoryTurn(alloc, turn);
        alloc.free(history);
    }
    for (history, 0..) |*turn, index| {
        const prompt = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ label, index });
        defer alloc.free(prompt);
        turn.* = try session.makeAssistantTurn(alloc, prompt, "saved response");
        initialized += 1;
        try session.copyWorkIdToTurn(alloc, turn, prompt);
    }
    return history;
}

fn replaceHistoryPageTurnsFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    updated_at_ms: i64,
    history: []const session.HistoryTurn,
) !void {
    var writable = try store.resumeForWrite(alloc, id);
    defer writable.deinit(alloc);
    const desired = session_codec.DurableSessionState{
        .id = writable.state.id,
        .origin_workspace_root = writable.state.origin_workspace_root,
        .workspace_root = writable.state.workspace_root,
        .created_at_ms = writable.state.created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = writable.state.conversation_language,
        .preferences = writable.state.preferences,
        .history = @constCast(history),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    _ = try writable.commitStateReplacement(
        alloc,
        desired,
        .recovery,
        .retry_expected_tail,
        .{},
    );
}

fn createHistoryPageFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    count: usize,
    label: []const u8,
) !void {
    var state = try testDurableState(alloc, id, workspace_root);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    writable.deinit(alloc);
    try replaceHistoryPageFixture(alloc, store, id, 20, count, label);
}

fn expectHistoryPagePrompts(page: HistoryPage, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, page.turns.len);
    for (page.turns, expected) |turn, prompt| {
        switch (turn) {
            .assistant => |assistant| try std.testing.expectEqualStrings(prompt, assistant.user.text),
            else => return error.TestExpectedEqual,
        }
    }
}

fn writeLegacyV2Fixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    const text = try session_json.renderSessionJson(
        alloc,
        id,
        10,
        updated_at_ms,
        session.ConversationLanguage.literal("en"),
        workspace_root,
        &.{},
        .{},
    );
    defer alloc.free(text);
    const schema = "\"schema_version\":1";
    const schema_start = std.mem.find(u8, text, schema) orelse
        return error.InvalidSessionFormat;
    text[schema_start + schema.len - 1] = '2';
    const path = try writeSessionFixture(alloc, store, id, text);
    alloc.free(path);
}

fn writeLargeLegacyFixture(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
) !void {
    const base = try session_json.renderSessionJson(
        alloc,
        id,
        10,
        updated_at_ms,
        session.ConversationLanguage.literal("en"),
        workspace_root,
        &.{},
        .{},
    );
    defer alloc.free(base);
    if (base.len == 0 or base[0] != '{') return error.InvalidSessionFormat;
    const filler = try alloc.alloc(u8, session_projection.manifest_max_bytes + 1024);
    defer alloc.free(filler);
    @memset(filler, 'x');

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ignored_large_field\":\"");
    try out.writer.writeAll(filler);
    try out.writer.writeAll("\",");
    try out.writer.writeAll(base[1..]);
    const text = try out.toOwnedSlice();
    defer alloc.free(text);
    try std.testing.expect(text.len > session_projection.manifest_max_bytes);
    const path = try writeSessionFixture(alloc, store, id, text);
    alloc.free(path);
}

fn readFixtureFile(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    name: []const u8,
    max_bytes: usize,
) ![]u8 {
    const session_dir = try sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(session_dir);
    const path = try std.fs.path.join(alloc, &.{ session_dir, name });
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn writeFixtureEntry(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    name: []const u8,
    bytes: []const u8,
) !void {
    const session_dir = try sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(session_dir);
    const path = try std.fs.path.join(alloc, &.{ session_dir, name });
    defer alloc.free(path);
    try writeRawFile(path, bytes);
}

fn corruptPendingReplacementTimestampForTest(
    alloc: Allocator,
    store: Store,
    id: []const u8,
    prior_bytes: u64,
) !void {
    const session_dir = try sessionDirPath(alloc, store.sessions_dir, id);
    defer alloc.free(session_dir);
    const path = try std.fs.path.join(alloc, &.{ session_dir, "events.jsonl" });
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{ .mode = .read_write });
    defer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    if (length <= prior_bytes) return error.TestUnexpectedResult;
    const tail_len = std.math.cast(usize, length - prior_bytes) orelse
        return error.TestUnexpectedResult;
    const tail = try alloc.alloc(u8, tail_len);
    defer alloc.free(tail);
    const count = try file.readPositionalAll(io_mod.getIo(), tail, prior_bytes);
    if (count != tail.len) return error.TestUnexpectedResult;
    const needle = "\"timestamp_ms\":20";
    const match = std.mem.lastIndexOf(u8, tail, needle) orelse
        return error.TestUnexpectedResult;
    tail[match + needle.len - 1] = '1';
    try file.writePositionalAll(io_mod.getIo(), tail, prior_bytes);
    try file.sync(io_mod.getIo());
}

const MigrationBoundaryFailure = struct {
    target: session_log.Boundary,
    remaining_matches: usize = 0,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *MigrationBoundaryFailure = @ptrCast(@alignCast(context.?));
        if (boundary != self.target) return;
        if (self.remaining_matches > 0) {
            self.remaining_matches -= 1;
            return;
        }
        return error.InjectedBoundaryFailure;
    }

    fn options(self: *MigrationBoundaryFailure) ResumeOptions {
        return .{
            .log = .{
                .test_controls = .{
                    .context = self,
                    .boundary_fn = callback,
                },
            },
        };
    }
};

const ArmedBoundaryFailure = struct {
    target: session_log.Boundary,
    armed: bool = false,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *ArmedBoundaryFailure = @ptrCast(@alignCast(context.?));
        if (self.armed and boundary == self.target) return error.InjectedBoundaryFailure;
    }

    fn logOptions(self: *ArmedBoundaryFailure) session_log.Options {
        return .{
            .test_controls = .{
                .context = self,
                .boundary_fn = callback,
            },
        };
    }
};

const RecoveryResolutionFailure = struct {
    fn callback(_: ?*anyopaque, boundary: session_log.Boundary) !void {
        if (boundary == .after_target_namespace_sync or
            boundary == .before_recovery_proposed_validation)
        {
            return error.InjectedBoundaryFailure;
        }
    }

    fn options() session_log.Options {
        return .{
            .test_controls = .{ .boundary_fn = callback },
        };
    }
};

const LatestBarrierFailure = struct {
    injected_error: anyerror,
    completed_count: usize = 0,
    contended_count: usize = 0,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *LatestBarrierFailure = @ptrCast(@alignCast(context.?));
        switch (boundary) {
            .latest_barrier_contended => self.contended_count += 1,
            .latest_barrier_completed => {
                self.completed_count += 1;
                return self.injected_error;
            },
            else => {},
        }
    }

    fn options(self: *LatestBarrierFailure) ResumeOptions {
        return .{
            .log = .{
                .test_controls = .{
                    .context = self,
                    .boundary_fn = callback,
                },
            },
        };
    }
};

fn waitForTestFlag(flag: *const std.atomic.Value(bool)) !void {
    const deadline_ms = io_mod.milliTimestamp() + 5000;
    while (!flag.load(.seq_cst)) {
        if (io_mod.milliTimestamp() >= deadline_ms) return error.TestTimedOut;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
}

fn waitForTestFlagInCallback(flag: *const std.atomic.Value(bool)) bool {
    waitForTestFlag(flag) catch return false;
    return true;
}

const DiscardPauseControl = struct {
    armed: std.atomic.Value(bool) = .init(false),
    pending: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        const self: *DiscardPauseControl = @ptrCast(@alignCast(context.?));
        if (boundary != .after_latest_cache_pending or !self.armed.load(.seq_cst)) return;
        self.pending.store(true, .seq_cst);
        if (!waitForTestFlagInCallback(&self.release)) {
            self.timed_out.store(true, .seq_cst);
            return error.TestTimedOut;
        }
    }

    fn logOptions(self: *DiscardPauseControl) session_log.Options {
        return .{
            .test_controls = .{
                .context = self,
                .boundary_fn = callback,
            },
        };
    }
};

const ResumeInterleavingControl = struct {
    pause_on_session: bool = false,
    barrier_contended: std.atomic.Value(bool) = .init(false),
    barrier_completed_count: std.atomic.Value(usize) = .init(0),
    session_opened: std.atomic.Value(bool) = .init(false),
    release_session: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn boundary(context: ?*anyopaque, point: session_log.Boundary) !void {
        const self: *ResumeInterleavingControl = @ptrCast(@alignCast(context.?));
        switch (point) {
            .latest_barrier_contended => self.barrier_contended.store(true, .seq_cst),
            .latest_barrier_completed => _ = self.barrier_completed_count.fetchAdd(1, .seq_cst),
            else => {},
        }
    }

    fn lock(context: ?*anyopaque, kind: session_log.LockKind) void {
        const self: *ResumeInterleavingControl = @ptrCast(@alignCast(context.?));
        if (kind != .session or !self.pause_on_session) return;
        if (self.session_opened.swap(true, .seq_cst)) return;
        if (!waitForTestFlagInCallback(&self.release_session)) {
            self.timed_out.store(true, .seq_cst);
        }
    }

    fn options(self: *ResumeInterleavingControl) ResumeOptions {
        return .{
            .log = .{
                .test_controls = .{
                    .context = self,
                    .boundary_fn = boundary,
                    .lock_fn = lock,
                },
            },
        };
    }
};

const DiscardWorker = struct {
    store: *Store,
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    disposition: ?PristineDiscardDisposition = null,

    fn run(self: *DiscardWorker) void {
        self.disposition = self.store.discardPristineStartedSession(
            self.alloc,
            self.loaded,
        );
    }
};

const ResumeWorker = struct {
    const Result = union(enum) {
        pending,
        loaded: LoadedWritableSession,
        failed: anyerror,
    };

    store: *Store,
    alloc: Allocator,
    workspace_root: []const u8,
    options: ResumeOptions,
    result: Result = .pending,

    fn run(self: *ResumeWorker) void {
        const loaded = self.store.resumeTargetForWrite(
            self.alloc,
            .last,
            self.workspace_root,
            self.options,
        ) catch |err| {
            self.result = .{ .failed = err };
            return;
        };
        self.result = .{ .loaded = loaded };
    }

    fn takeLoaded(self: *ResumeWorker) !LoadedWritableSession {
        return switch (self.result) {
            .pending => error.TestExpectedEqual,
            .failed => |err| err,
            .loaded => |loaded| blk: {
                self.result = .pending;
                break :blk loaded;
            },
        };
    }

    fn deinitResult(self: *ResumeWorker) void {
        switch (self.result) {
            .loaded => |*loaded| loaded.deinit(self.alloc),
            else => {},
        }
        self.result = .pending;
    }
};

const MigrationStableCopyCorruption = struct {
    legacy_copy_path: []const u8,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        if (boundary != .after_authority_namespace_sync) return;
        const self: *MigrationStableCopyCorruption = @ptrCast(@alignCast(context.?));
        try writeRawFile(self.legacy_copy_path, "{broken");
    }

    fn options(self: *MigrationStableCopyCorruption) session_log.Options {
        return .{
            .test_controls = .{
                .context = self,
                .boundary_fn = callback,
            },
        };
    }
};

const MigrationInterruptedStableCopyCorruption = struct {
    legacy_copy_path: []const u8,

    fn callback(context: ?*anyopaque, boundary: session_log.Boundary) !void {
        if (boundary != .after_authority_namespace_sync) return;
        const self: *MigrationInterruptedStableCopyCorruption = @ptrCast(@alignCast(context.?));
        try writeRawFile(self.legacy_copy_path, "{broken");
        return error.InjectedBoundaryFailure;
    }

    fn options(self: *MigrationInterruptedStableCopyCorruption) ResumeOptions {
        return .{
            .log = .{
                .test_controls = .{
                    .context = self,
                    .boundary_fn = callback,
                },
            },
        };
    }
};

fn expectWorkspaceRebindPublicationFailureRepair(
    session_id: []const u8,
    force_compaction: bool,
) !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-a");
    defer alloc.free(workspace_a);
    const workspace_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace-b");
    defer alloc.free(workspace_b);

    var store_a = try Store.initFromHome(alloc, home, workspace_a);
    defer store_a.deinit(alloc);
    var state = try testDurableState(alloc, session_id, workspace_a);
    defer state.deinit(alloc);
    var initial = try store_a.startWritableSession(alloc, state);
    const initial_generation = initial.position.log_generation;
    initial.deinit(alloc);

    var failure = ArmedBoundaryFailure{
        .target = .before_latest_cache_ready,
        .armed = true,
    };
    var store_b = try Store.initFromHome(alloc, home, workspace_b);
    defer store_b.deinit(alloc);
    var rebind_options = failure.logOptions();
    if (force_compaction) {
        rebind_options.compaction_frame_threshold = 1;
        rebind_options.compaction_byte_threshold = 1;
    }
    var rebound = try store_b.resumeTargetForWrite(
        alloc,
        .{ .id = state.id },
        workspace_b,
        .{ .log = rebind_options },
    );
    defer rebound.deinit(alloc);

    try std.testing.expectEqualStrings(workspace_b, rebound.state.workspace_root);
    try std.testing.expectEqual(
        force_compaction,
        !std.mem.eql(
            u8,
            &initial_generation,
            &rebound.position.log_generation,
        ),
    );
    try std.testing.expectError(
        error.InvalidSessionIndex,
        readLatestPointer(store_b, alloc, workspace_b),
    );
    try std.testing.expect(rebound.needsFinalStateReplacement(false));

    failure.armed = false;
    var current = try rebound.state.dupe(alloc);
    defer current.deinit(alloc);
    _ = try rebound.commitStateReplacement(
        alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!rebound.needsFinalStateReplacement(false));

    const pointer_value = try readLatestPointer(store_b, alloc, workspace_b) orelse
        return error.TestExpectedEqual;
    var pointer = pointer_value;
    defer pointer.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, pointer.session_id);
}
