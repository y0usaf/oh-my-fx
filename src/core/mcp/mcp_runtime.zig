const std = @import("std");
const atomic_value = @import("atomic_value.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");
const collections = @import("../shared/collections.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const mcp_contract = @import("mcp_contract.zig");
const mcp_auth = @import("mcp_auth.zig");
const mcp_auth_store = @import("mcp_auth_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const model_tool_schema = @import("../tooling/model_tool_schema.zig");
const permissions = @import("../permissions/permissions.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");
const context_limits = @import("../config/context_limits.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const legacy_http_sse = @import("legacy_http_sse.zig");
const legacy_streamable_http = @import("legacy_streamable_http.zig");
const elicitation = @import("elicitation.zig");
const legacy_url_completion = @import("legacy_url_completion.zig");
const mrtr = @import("mrtr.zig");
const operation_control = @import("operation_control.zig");
const controlled_lock = @import("controlled_lock.zig");
const mcp_json = @import("mcp_json.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
const docker_run = @import("docker_run.zig");
const stdio_dispatcher = @import("stdio_dispatcher.zig");
const streamable_http = @import("streamable_http.zig");
const feature_cache = @import("feature_cache.zig");
const access_policy = @import("access_policy.zig");
const health = @import("health.zig");
const model_catalog = @import("model_catalog.zig");
const startup_admission = @import("startup_admission.zig");
const project_config = @import("project_config.zig");
const tool_subscription = @import("tool_subscription.zig");
const completion_feature = @import("features/completion.zig");
const prompts_feature = @import("features/prompts.zig");
const resources_feature = @import("features/resources.zig");
const tools_feature = @import("features/tools.zig");
const tool_result = @import("tool_result.zig");

const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const mcp_response_frame_overhead_bytes: usize = 16 * 1024;
const mcp_discovery_response_frame_cap_bytes: usize = 1024 * 1024;
const mcp_subscription_event_cap_bytes: usize = 64 * 1024;
const mcp_feature_response_frame_cap_bytes: usize = 4 * 1024 * 1024;
const max_resource_read_cache_entries: usize = 64;
const legacy_protocol_version = protocol_negotiation.legacy_protocol_version;
const legacy_2025_06_protocol_version = protocol_negotiation.legacy_2025_06_protocol_version;
const legacy_2025_11_protocol_version = protocol_negotiation.legacy_2025_11_protocol_version;
const modern_protocol_version = protocol_negotiation.modern_protocol_version;
const missing_required_client_capability_code: i64 = -32021;
const unsupported_protocol_version_code = protocol_negotiation.unsupported_protocol_version_code;
const default_mcp_search_limit: usize = 8;
const max_mcp_search_limit: usize = 20;
const max_mcp_tool_tags: usize = 16;
const mcp_server_instruction_search_bytes = context_limits.Name.mcp_server_instructions_bytes.defaultBytes();
const mcp_tool_description_search_bytes: usize = 2 * 1024;
const mcp_tool_schema_search_bytes: usize = 4 * 1024;
const max_pending_legacy_url_waiters: usize = 32;
const max_early_legacy_url_completions_per_window: usize = 64;
const max_legacy_url_completion_candidates: usize = 1024;
const max_legacy_url_completion_windows: usize = 32;
const early_legacy_url_completion_ttl_ms: i64 = 10 * 60 * 1000;
var next_legacy_url_runtime_generation: atomic_value.Value(u64) = .init(1);
var next_runtime_generation: atomic_value.Value(u64) = .init(1);

const lockRwSharedUntil = controlled_lock.rwSharedUntil;
const lockRwUntil = controlled_lock.rwUntil;
const lockMutexUntil = controlled_lock.mutexUntil;
const lockRwSharedWithControl = controlled_lock.rwSharedWithControl;
const lockMutexWithControl = controlled_lock.mutexWithControl;
const checkOperationControl = controlled_lock.checkOperation;
const StdioProtocol = protocol_negotiation.Protocol;
const ResponsePayload = protocol_negotiation.ResponsePayload;
const DiscoveryOutcome = protocol_negotiation.DiscoveryOutcome;
const LegacyStdioVersion = protocol_negotiation.LegacyStdioVersion;
const LegacyInitializeObservation = protocol_negotiation.LegacyInitializeObservation;
const LegacyInitializeTransition = protocol_negotiation.LegacyInitializeTransition;
const decideLegacyInitializeTransition = protocol_negotiation.decideLegacyInitializeTransition;
const classifyResponsePayload = protocol_negotiation.classifyResponsePayload;
const classifyDiscoveryResponse = protocol_negotiation.classifyDiscoveryResponse;
const classifyHttpDiscoveryResponse = protocol_negotiation.classifyHttpDiscoveryResponse;
const classifyLegacyInitializeResponse = protocol_negotiation.classifyLegacyInitializeResponse;

fn allocateRuntimeGeneration() u64 {
    const generation = next_runtime_generation.fetchAdd(1, .monotonic);
    std.debug.assert(generation != 0);
    return generation;
}

pub const LoadRuntimeFn = *const fn (
    Allocator,
    []const u8,
    elicitation.Capabilities,
) anyerror!?*McpRuntime;

pub const PreviewNativeWorkspaceAuthorityFn = *const fn (
    Allocator,
    []const u8,
) anyerror![][]u8;

const ConnectionControl = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,
    use_startup_timeout: bool = false,

    fn cancellation(self: ConnectionControl) operation_control.CancellationSources {
        return .{
            .caller = self.cancel_flag,
            .runtime = self.lifecycle_cancel_flag,
        };
    }
};

const LegacyUrlWaiter = legacy_url_completion.Waiter;
const LegacyUrlWireCompletionIdentity = legacy_url_completion.WireCompletionIdentity;
const EarlyLegacyUrlCompletion = legacy_url_completion.EarlyCompletion;
const LegacyUrlCompletionCandidate = legacy_url_completion.Candidate;
const LegacyUrlCompletionPublication = legacy_url_completion.Publication;
const LegacyUrlCompletionReplayStep = legacy_url_completion.ReplayStep;
const LegacyUrlCompletionWindow = legacy_url_completion.Window;
const legacyUrlCandidateMatchesWire = legacy_url_completion.candidateMatchesWire;
const legacyUrlCandidateMatchesWaiterId = legacy_url_completion.candidateMatchesWaiterId;
const legacyUrlWireCompletionTargetsWaiter = legacy_url_completion.wireCompletionTargetsWaiter;

fn applyLegacyUrlCompletion(
    waiter: *LegacyUrlWaiter,
    completion: elicitation.LegacyUrlCompletionIdentity,
) bool {
    return legacy_url_completion.apply(waiter, completion, awakeMillis());
}

const FeatureCatalogKind = enum {
    resources,
    resource_templates,
    prompts,

    fn capability(self: FeatureCatalogKind) feature_cache.Capability {
        return switch (self) {
            .resources => .resources_list,
            .resource_templates => .resource_templates_list,
            .prompts => .prompts_list,
        };
    }

    fn invalidation(self: FeatureCatalogKind) tool_subscription.FeatureInvalidation {
        return switch (self) {
            .resources => .resources,
            .resource_templates => .resource_templates,
            .prompts => .prompts,
        };
    }
};

const FetchedFeatureCatalog = union(FeatureCatalogKind) {
    resources: FetchedResources,
    resource_templates: FetchedResourceTemplates,
    prompts: FetchedPrompts,

    fn deinit(self: *FetchedFeatureCatalog, alloc: Allocator) void {
        switch (self.*) {
            .resources => |*value| value.catalog.deinit(alloc),
            .resource_templates => |*value| value.catalog.deinit(alloc),
            .prompts => |*value| value.catalog.deinit(alloc),
        }
        self.* = undefined;
    }

    fn scope(self: FetchedFeatureCatalog) feature_cache.CacheScope {
        return switch (self) {
            .resources => |value| switch (value.catalog.cache_scope) {
                .private => .private,
                .public => .public,
            },
            .resource_templates => |value| switch (value.catalog.cache_scope) {
                .private => .private,
                .public => .public,
            },
            .prompts => |value| switch (value.catalog.cache_scope) {
                .private => .private,
                .public => .public,
            },
        };
    }

    fn authIdentity(self: FetchedFeatureCatalog) ?feature_cache.Digest {
        return switch (self) {
            .resources => |value| value.auth_identity,
            .resource_templates => |value| value.auth_identity,
            .prompts => |value| value.auth_identity,
        };
    }

    fn fetchedAt(self: FetchedFeatureCatalog) u64 {
        return switch (self) {
            .resources => |value| value.catalog.fetched_at_ms,
            .resource_templates => |value| value.catalog.fetched_at_ms,
            .prompts => |value| value.catalog.fetched_at_ms,
        };
    }

    fn expiresAt(self: FetchedFeatureCatalog) u64 {
        return switch (self) {
            .resources => |value| value.catalog.expires_at_ms,
            .resource_templates => |value| value.catalog.expires_at_ms,
            .prompts => |value| value.catalog.expires_at_ms,
        };
    }

    fn digest(self: FetchedFeatureCatalog) feature_cache.Digest {
        return switch (self) {
            .resources => |value| digestResources(value.catalog.items),
            .resource_templates => |value| digestResourceTemplates(value.catalog.items),
            .prompts => |value| digestPrompts(value.catalog.prompts),
        };
    }
};

fn ensureResourceCatalog(
    self: *McpRuntime,
    server: *McpServer,
    templates: bool,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !bool {
    return ensureFeatureCatalog(
        self,
        server,
        if (templates) .resource_templates else .resources,
        deadline,
        cancel_flag,
        access,
    );
}

fn ensurePromptCatalog(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !bool {
    return ensureFeatureCatalog(self, server, .prompts, deadline, cancel_flag, access);
}

fn ensureFeatureCatalog(
    self: *McpRuntime,
    server: *McpServer,
    kind: FeatureCatalogKind,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !bool {
    var operation_access = try OperationAccessGuard.init(
        self.alloc,
        access,
        self.generation,
    );
    defer operation_access.deinit();
    const access_target = access_policy.Target{ .feature_server = server.config.name };
    const may_mutate_before_transport = switch (access) {
        .unrestricted => true,
        .disabled, .scoped => false,
    };
    try operation_access.authorize(access_target);
    try lockMutexUntil(&server.feature_refresh_lock, deadline, cancel_flag);
    var refresh_locked = true;
    defer if (refresh_locked) server.feature_refresh_lock.unlock(io_mod.getIo());
    const initial = initial: {
        try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        const state = featureCatalogState(server, kind);
        break :initial .{
            .metadata = state.metadata,
            .available = state.available,
            .invalidated = if (server.tool_subscription) |subscription|
                subscription.hasInvalidationFor(kind.invalidation())
            else
                false,
        };
    };
    const initial_scope = if (initial.metadata) |metadata| metadata.scope else .private;
    try operation_access.refreshAndAuthorize(access_target);
    const requested_key = try currentFeatureCacheKey(
        self.alloc,
        server,
        kind.capability(),
        "{}",
        initial_scope,
        deadline,
        cancel_flag,
        .{ .runtime = self, .access = access, .target = access_target },
    );
    var may_serve_snapshot = false;
    if (initial.metadata) |metadata| {
        const decision = feature_cache.decideRefresh(
            metadata,
            requested_key,
            clockMillis(),
            initial.invalidated,
        );
        may_serve_snapshot = decision.may_serve_snapshot and initial.available;
        if (decision.action != .refresh) {
            try operation_access.refreshAndAuthorize(access_target);
            return may_serve_snapshot;
        }
        if (!may_serve_snapshot and may_mutate_before_transport) {
            try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
            defer self.catalog_mutex.unlock(io_mod.getIo());
            const current = featureCatalogState(server, kind);
            if (current.metadata) |current_metadata| {
                if (current_metadata.connection_generation == metadata.connection_generation and
                    current_metadata.catalog_generation == metadata.catalog_generation and
                    current_metadata.key.eql(metadata.key))
                {
                    setFeatureCatalogAvailable(server, kind, false);
                }
            }
        }
    }

    const recovered = self.ensureFeatureServerRunning(
        server,
        deadline,
        cancel_flag,
        access,
    ) catch |err| {
        if (err == error.McpAccessDenied) return error.McpAccessDenied;
        if (err == error.McpAuthorityChanged) return error.McpAuthorityChanged;
        recordFeatureRefreshFailure(
            self,
            server,
            kind,
            initial.metadata,
            may_serve_snapshot,
            err,
        );
        if (may_serve_snapshot) return true;
        return err;
    };
    if (recovered) {
        server.feature_refresh_lock.unlock(io_mod.getIo());
        refresh_locked = false;
        return ensureFeatureCatalog(
            self,
            server,
            kind,
            deadline,
            cancel_flag,
            access,
        );
    }

    const invalidation_generation = if (server.tool_subscription) |subscription|
        subscription.invalidationGenerationFor(kind.invalidation())
    else
        0;

    const source_connection_generation = server.connection_generation;
    var fetched = fetchFeatureCatalogWithAuthRetry(self, server, kind, deadline, cancel_flag, access) catch |err| {
        if (err == error.McpAccessDenied) return error.McpAccessDenied;
        if (err == error.McpAuthorityChanged) return error.McpAuthorityChanged;
        recordFeatureRefreshFailure(
            self,
            server,
            kind,
            initial.metadata,
            may_serve_snapshot,
            err,
        );
        if (may_serve_snapshot) return true;
        return err;
    };
    defer fetched.deinit(self.alloc);
    try operation_access.refreshAndAuthorize(access_target);
    const scope = fetched.scope();
    const replacement_key = if (fetched.authIdentity()) |identity|
        cacheKeyWithFeatureAuthIdentity(server, kind.capability(), "{}", scope, identity)
    else
        try currentFeatureCacheKey(
            self.alloc,
            server,
            kind.capability(),
            "{}",
            scope,
            deadline,
            cancel_flag,
            .{ .runtime = self, .access = access, .target = access_target },
        );
    const digest = fetched.digest();

    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    if (server.connection_generation != source_connection_generation) return featureCatalogState(server, kind).available;
    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    defer server.catalog_commit_lock.unlock(io_mod.getIo());
    var auth_locked = false;
    defer if (auth_locked) server.auth_lock.unlock(io_mod.getIo());
    const active_key = if (scope == .private and server.config.transport != .stdio) active: {
        try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
        auth_locked = true;
        break :active cacheKeyWithFeatureAuthIdentity(
            server,
            kind.capability(),
            "{}",
            scope,
            try currentAuthIdentity(self.alloc, server),
        );
    } else replacement_key;
    if (!active_key.eql(replacement_key)) return error.McpAuthIdentityChangedDuringPagination;

    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) self.catalog_mutex.unlock(io_mod.getIo());
    const latest = featureCatalogState(server, kind);
    if (server.connection_generation != source_connection_generation) return latest.available;
    const generation = if (latest.metadata) |metadata| generation: {
        const source = initial.metadata orelse {
            debug_trace.logf(
                "mcp",
                "rejected stale feature refresh server={s} feature={s} reason=source_missing",
                .{ server.config.name, @tagName(kind) },
            );
            return latest.available;
        };
        const transition = feature_cache.authorizeReplacement(
            metadata,
            source.connection_generation,
            source.catalog_generation,
            active_key,
            replacement_key,
            digest,
        );
        break :generation switch (transition) {
            .reject_stale_generation => {
                debug_trace.logf(
                    "mcp",
                    "rejected stale feature refresh server={s} feature={s} source_connection_generation={d} source_catalog_generation={d}",
                    .{
                        server.config.name,
                        @tagName(kind),
                        source.connection_generation,
                        source.catalog_generation,
                    },
                );
                return latest.available;
            },
            .reject_cache_key => {
                recordFeatureRefreshFailureLocked(
                    server,
                    kind,
                    source,
                    false,
                    error.McpAuthIdentityChangedDuringPagination,
                );
                return latest.available;
            },
            .metadata_only => metadata.catalog_generation,
            .replace_snapshot => std.math.add(
                u64,
                metadata.catalog_generation,
                1,
            ) catch return error.McpGenerationExhausted,
        };
    } else generation: {
        if (initial.metadata != null or !active_key.eql(replacement_key)) {
            return latest.available;
        }
        break :generation 1;
    };
    const metadata = feature_cache.SnapshotMetadata{
        .key = replacement_key,
        .connection_generation = source_connection_generation,
        .catalog_generation = generation,
        .fetched_at_ms = fetched.fetchedAt(),
        .expires_at_ms = fetched.expiresAt(),
        .scope = scope,
        .content_digest = digest,
        .subscription = if (server.tool_subscription) |subscription| subscription.identity() else null,
    };
    const auth_generation = server.auth_generation.load(.acquire);
    var retired = publishFeatureCatalog(server, kind, &fetched, metadata, auth_generation);
    if (server.tool_subscription) |subscription| {
        subscription.clearInvalidationThroughFor(kind.invalidation(), invalidation_generation);
    }
    self.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    retired.deinit(self.alloc);
    debug_trace.logf(
        "mcp",
        "feature cache snapshot replaced server={s} feature={s} generation={d}",
        .{ server.config.name, @tagName(kind), generation },
    );
    return true;
}

const FeatureCatalogState = struct {
    metadata: ?feature_cache.SnapshotMetadata,
    available: bool,
};

fn featureCatalogState(server: *const McpServer, kind: FeatureCatalogKind) FeatureCatalogState {
    return switch (kind) {
        .resources => .{ .metadata = server.resource_catalog.metadata, .available = featureCatalogAvailable(server, kind) },
        .resource_templates => .{ .metadata = server.resource_template_catalog.metadata, .available = featureCatalogAvailable(server, kind) },
        .prompts => .{ .metadata = server.prompt_catalog.metadata, .available = featureCatalogAvailable(server, kind) },
    };
}

const FeatureCatalogAvailability = struct {
    available: bool,
    metadata: ?feature_cache.SnapshotMetadata,
    auth_generation: u64,
};

fn featureCatalogAvailable(server: *const McpServer, kind: FeatureCatalogKind) bool {
    const state = featureCatalogAvailability(server, kind);
    if (!state.available) return false;
    const metadata = state.metadata orelse return false;
    return metadata.scope == .public or
        state.auth_generation == server.auth_generation.load(.acquire);
}

fn featureCatalogAvailability(server: *const McpServer, kind: FeatureCatalogKind) FeatureCatalogAvailability {
    return switch (kind) {
        .resources => .{
            .available = server.resource_catalog.available,
            .metadata = server.resource_catalog.metadata,
            .auth_generation = server.resource_catalog.auth_generation,
        },
        .resource_templates => .{
            .available = server.resource_template_catalog.available,
            .metadata = server.resource_template_catalog.metadata,
            .auth_generation = server.resource_template_catalog.auth_generation,
        },
        .prompts => .{
            .available = server.prompt_catalog.available,
            .metadata = server.prompt_catalog.metadata,
            .auth_generation = server.prompt_catalog.auth_generation,
        },
    };
}

fn setFeatureCatalogAvailable(server: *McpServer, kind: FeatureCatalogKind, available: bool) void {
    switch (kind) {
        .resources => server.resource_catalog.available = available,
        .resource_templates => server.resource_template_catalog.available = available,
        .prompts => server.prompt_catalog.available = available,
    }
}

fn featureCatalogAuthWitness(server: *const McpServer, kind: FeatureCatalogKind) ?u64 {
    const state = featureCatalogAvailability(server, kind);
    const metadata = state.metadata orelse return null;
    if (metadata.scope == .public) return null;
    return state.auth_generation;
}

fn validateFeatureCatalogAuthWitness(server: *const McpServer, witness: ?u64) !void {
    const generation = witness orelse return;
    if (server.auth_generation.load(.acquire) != generation) {
        return error.McpFeatureCatalogChanged;
    }
}

const RetiredFeatureCatalog = union(FeatureCatalogKind) {
    resources: ResourceCatalogSnapshot,
    resource_templates: ResourceTemplateCatalogSnapshot,
    prompts: PromptCatalogSnapshot,

    fn deinit(self: *RetiredFeatureCatalog, alloc: Allocator) void {
        switch (self.*) {
            .resources => |*value| value.deinit(alloc),
            .resource_templates => |*value| value.deinit(alloc),
            .prompts => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

fn publishFeatureCatalog(
    server: *McpServer,
    kind: FeatureCatalogKind,
    fetched: *FetchedFeatureCatalog,
    metadata: feature_cache.SnapshotMetadata,
    auth_generation: u64,
) RetiredFeatureCatalog {
    return switch (kind) {
        .resources => blk: {
            const retired = RetiredFeatureCatalog{ .resources = server.resource_catalog };
            server.resource_catalog = .{
                .catalog = fetched.resources.catalog,
                .metadata = metadata,
                .auth_generation = auth_generation,
                .available = true,
            };
            fetched.resources.catalog.items = &.{};
            break :blk retired;
        },
        .resource_templates => blk: {
            const retired = RetiredFeatureCatalog{ .resource_templates = server.resource_template_catalog };
            server.resource_template_catalog = .{
                .catalog = fetched.resource_templates.catalog,
                .metadata = metadata,
                .auth_generation = auth_generation,
                .available = true,
            };
            fetched.resource_templates.catalog.items = &.{};
            break :blk retired;
        },
        .prompts => blk: {
            const retired = RetiredFeatureCatalog{ .prompts = server.prompt_catalog };
            server.prompt_catalog = .{
                .catalog = fetched.prompts.catalog,
                .metadata = metadata,
                .auth_generation = auth_generation,
                .available = true,
            };
            fetched.prompts.catalog.prompts = &.{};
            break :blk retired;
        },
    };
}

fn recordFeatureRefreshFailure(
    self: *McpRuntime,
    server: *McpServer,
    kind: FeatureCatalogKind,
    source: ?feature_cache.SnapshotMetadata,
    may_serve_snapshot: bool,
    err: anyerror,
) void {
    self.catalog_mutex.lockUncancelable(io_mod.getIo());
    defer self.catalog_mutex.unlock(io_mod.getIo());
    recordFeatureRefreshFailureLocked(server, kind, source, may_serve_snapshot, err);
}

fn recordFeatureRefreshFailureLocked(
    server: *McpServer,
    kind: FeatureCatalogKind,
    source: ?feature_cache.SnapshotMetadata,
    may_serve_snapshot: bool,
    err: anyerror,
) void {
    const source_metadata = source orelse return;
    const current = featureCatalogState(server, kind).metadata orelse return;
    if (current.connection_generation != source_metadata.connection_generation or
        current.catalog_generation != source_metadata.catalog_generation or
        !current.key.eql(source_metadata.key))
    {
        return;
    }
    const failed = feature_cache.failedRefresh(current, clockMillis());
    switch (kind) {
        .resources => server.resource_catalog.metadata = failed,
        .resource_templates => server.resource_template_catalog.metadata = failed,
        .prompts => server.prompt_catalog.metadata = failed,
    }
    setFeatureCatalogAvailable(server, kind, may_serve_snapshot);
    debug_trace.logf(
        "mcp",
        "feature cache refresh failed server={s} feature={s} preserved_snapshot={any} err={s}",
        .{ server.config.name, @tagName(kind), may_serve_snapshot, @errorName(err) },
    );
}

fn fetchFeatureCatalog(
    self: *McpRuntime,
    server: *McpServer,
    kind: FeatureCatalogKind,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !FetchedFeatureCatalog {
    return switch (kind) {
        .resources => .{ .resources = try fetchResources(self, server, deadline, cancel_flag, access) },
        .resource_templates => .{ .resource_templates = try fetchResourceTemplates(self, server, deadline, cancel_flag, access) },
        .prompts => .{ .prompts = try fetchPrompts(self, server, deadline, cancel_flag, access) },
    };
}

fn fetchFeatureCatalogWithAuthRetry(
    self: *McpRuntime,
    server: *McpServer,
    kind: FeatureCatalogKind,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !FetchedFeatureCatalog {
    var identity_restarts: u8 = 0;
    while (true) {
        return fetchFeatureCatalog(self, server, kind, deadline, cancel_flag, access) catch |err| switch (err) {
            error.McpAuthIdentityChangedDuringPagination => {
                if (identity_restarts >= mcp_auth.max_scope_reauthorizations) {
                    return error.McpAuthenticationRetryLimit;
                }
                identity_restarts += 1;
                debug_trace.logf(
                    "mcp",
                    "restarting paginated feature fetch after auth identity change server={s} feature={s} attempt={d}",
                    .{ server.config.name, @tagName(kind), identity_restarts },
                );
                continue;
            },
            else => |other| return other,
        };
    }
}

const FetchedResources = struct { catalog: resources_feature.ResourceCatalog, auth_identity: ?feature_cache.Digest = null };
const FetchedResourceTemplates = struct { catalog: resources_feature.TemplateCatalog, auth_identity: ?feature_cache.Digest = null };
const FetchedPrompts = struct { catalog: prompts_feature.Catalog, auth_identity: ?feature_cache.Digest = null };

fn fetchResources(self: *McpRuntime, server: *McpServer, deadline: std.Io.Clock.Timestamp, cancel_flag: ?*std.atomic.Value(bool), access: tool_mcp_runtime.Access) !FetchedResources {
    var builder = resources_feature.ResourceCatalogBuilder.init(self.alloc, serverFeatureProtocol(server));
    defer builder.deinit(self.alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| self.alloc.free(value);
    var producing_identity: ?feature_cache.Digest = null;
    while (true) {
        try reauthorizeOperation(
            self,
            access,
            .{ .feature_server = server.config.name },
        );
        const request_id = try nextFeatureRequestId(server);
        const request = try resources_feature.buildListRequest(self.alloc, request_id, serverFeatureProtocol(server), cursor, writeModernRequestMetadata);
        defer self.alloc.free(request);
        var guard = ServerAccessPrecommit{
            .runtime = self,
            .target = .{ .feature_server = server.config.name },
            .access = access,
        };
        var precommit = guard.transport();
        var response = try sendFeatureRequest(self, server, request_id, request, deadline, cancel_flag, access, &precommit, null);
        const received_at_ms = clockMillis();
        defer response.deinit(self.alloc);
        try acceptPageIdentity(&producing_identity, response.auth_identity);
        var page = try resources_feature.parseResourcePage(self.alloc, response.body, serverFeatureProtocol(server), .{});
        defer page.deinit(self.alloc);
        try replaceOwnedCursor(self.alloc, &cursor, page.next_cursor);
        try builder.appendPage(self.alloc, &page, received_at_ms, .{});
        if (cursor == null) return .{ .catalog = try builder.finish(self.alloc), .auth_identity = producing_identity };
    }
}

fn fetchResourceTemplates(self: *McpRuntime, server: *McpServer, deadline: std.Io.Clock.Timestamp, cancel_flag: ?*std.atomic.Value(bool), access: tool_mcp_runtime.Access) !FetchedResourceTemplates {
    var builder = resources_feature.TemplateCatalogBuilder.init(self.alloc, serverFeatureProtocol(server));
    defer builder.deinit(self.alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| self.alloc.free(value);
    var producing_identity: ?feature_cache.Digest = null;
    while (true) {
        try reauthorizeOperation(
            self,
            access,
            .{ .feature_server = server.config.name },
        );
        const request_id = try nextFeatureRequestId(server);
        const request = try resources_feature.buildTemplatesListRequest(self.alloc, request_id, serverFeatureProtocol(server), cursor, writeModernRequestMetadata);
        defer self.alloc.free(request);
        var guard = ServerAccessPrecommit{
            .runtime = self,
            .target = .{ .feature_server = server.config.name },
            .access = access,
        };
        var precommit = guard.transport();
        var response = try sendFeatureRequest(self, server, request_id, request, deadline, cancel_flag, access, &precommit, null);
        const received_at_ms = clockMillis();
        defer response.deinit(self.alloc);
        try acceptPageIdentity(&producing_identity, response.auth_identity);
        var page = try resources_feature.parseTemplatePage(self.alloc, response.body, serverFeatureProtocol(server), .{});
        defer page.deinit(self.alloc);
        try replaceOwnedCursor(self.alloc, &cursor, page.next_cursor);
        try builder.appendPage(self.alloc, &page, received_at_ms, .{});
        if (cursor == null) return .{ .catalog = try builder.finish(self.alloc), .auth_identity = producing_identity };
    }
}

fn fetchPrompts(self: *McpRuntime, server: *McpServer, deadline: std.Io.Clock.Timestamp, cancel_flag: ?*std.atomic.Value(bool), access: tool_mcp_runtime.Access) !FetchedPrompts {
    var builder = prompts_feature.CatalogBuilder.init(self.alloc, serverFeatureProtocol(server));
    defer builder.deinit(self.alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| self.alloc.free(value);
    var producing_identity: ?feature_cache.Digest = null;
    while (true) {
        try reauthorizeOperation(
            self,
            access,
            .{ .feature_server = server.config.name },
        );
        const request_id = try nextFeatureRequestId(server);
        const request = try prompts_feature.buildListRequest(self.alloc, request_id, serverFeatureProtocol(server), cursor, writeModernRequestMetadata);
        defer self.alloc.free(request);
        var guard = ServerAccessPrecommit{
            .runtime = self,
            .target = .{ .feature_server = server.config.name },
            .access = access,
        };
        var precommit = guard.transport();
        var response = try sendFeatureRequest(self, server, request_id, request, deadline, cancel_flag, access, &precommit, null);
        const received_at_ms = clockMillis();
        defer response.deinit(self.alloc);
        try acceptPageIdentity(&producing_identity, response.auth_identity);
        var page = try prompts_feature.parseListPage(self.alloc, response.body, serverFeatureProtocol(server), .{});
        defer page.deinit(self.alloc);
        try replaceOwnedCursor(self.alloc, &cursor, page.next_cursor);
        try builder.appendPage(self.alloc, &page, received_at_ms, .{});
        if (cursor == null) return .{ .catalog = try builder.finish(self.alloc), .auth_identity = producing_identity };
    }
}

fn acceptPageIdentity(producing: *?feature_cache.Digest, incoming: ?feature_cache.Digest) !void {
    const page = incoming orelse return;
    if (producing.*) |identity| {
        if (!std.mem.eql(u8, &identity, &page)) return error.McpAuthIdentityChangedDuringPagination;
    } else producing.* = page;
}

const LegacyDirectTerminal = struct {
    responder: tool_mcp_runtime.InputResponder,
    origin: tool_mcp_runtime.InputOrigin,

    fn finish(self: LegacyDirectTerminal, alloc: Allocator, outcome: tool_mcp_runtime.ContinuationTerminal) void {
        const callback = self.responder.continuation_terminal orelse return;
        callback(self.responder.context, alloc, self.origin, outcome);
    }
};

fn terminalOutcomeForCallStatus(status: tool_mcp_runtime.CallStatus) tool_mcp_runtime.ContinuationTerminal {
    return switch (status) {
        .success, .tool_failure => .completed,
        .protocol_failure, .input_required => .abandoned,
    };
}

const FeatureResponse = struct {
    body: []u8,
    auth_identity: ?feature_cache.Digest = null,
    legacy_terminal: ?LegacyDirectTerminal = null,

    fn finishLegacy(self: *FeatureResponse, alloc: Allocator, outcome: tool_mcp_runtime.ContinuationTerminal) void {
        const terminal = self.legacy_terminal orelse return;
        self.legacy_terminal = null;
        terminal.finish(alloc, outcome);
    }

    fn deinit(self: *FeatureResponse, alloc: Allocator) void {
        self.finishLegacy(alloc, .abandoned);
        alloc.free(self.body);
        self.* = undefined;
    }
};

const LegacyElicitationSpec = struct {
    responder: ?tool_mcp_runtime.InputResponder,
    operation: elicitation.Operation,
};

const StdioServerRequestWait = struct {
    server: *McpServer,
    released: bool = false,

    fn begin(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        std.debug.assert(!self.released);
        self.server.connection_lock.unlockShared(io_mod.getIo());
        self.released = true;
    }
};

fn sendFeatureRequest(
    self: *McpRuntime,
    server: *McpServer,
    request_id: u64,
    request: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
    precommit: ?*mcp_contract.TransportPrecommit,
    legacy_elicitation: ?LegacyElicitationSpec,
) !FeatureResponse {
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    var connection_locked = true;
    defer if (connection_locked) server.connection_lock.unlockShared(io_mod.getIo());
    return switch (server.config.transport) {
        .stdio => stdio: {
            const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
            dispatcher.retainPublished();
            defer dispatcher.releaseUse();
            var legacy_context: ?LegacyElicitationContext = if (legacy_elicitation) |spec|
                if (legacyWireForServer(server)) |wire|
                    LegacyElicitationContext.initStdio(
                        server,
                        dispatcher,
                        wire,
                        spec.responder,
                        spec.operation,
                        deadline,
                        cancel_flag,
                    )
                else
                    null
            else
                null;
            var server_request_wait = StdioServerRequestWait{ .server = server };
            defer {
                if (server_request_wait.released) connection_locked = false;
            }
            const server_request_sink = if (legacy_context) |*context| context.sink() else null;
            var request_finished = false;
            defer if (!request_finished) {
                if (legacy_context) |*context| {
                    if (context.directTerminal()) |terminal| terminal.finish(self.alloc, .abandoned);
                }
            };
            const body = try dispatcher.request(
                self.alloc,
                request_id,
                request,
                mcp_feature_response_frame_cap_bytes,
                .{
                    .timeout_ms = server.config.operation_timeout_ms,
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = &self.retiring,
                    .precommit = precommit,
                    .response_observer = if (legacy_context) |*context| context.responseObserver() else null,
                    .server_requests = server_request_sink,
                    .deadline_gate = if (legacy_context) |*context| &context.deadline_gate else null,
                    .server_request_wait = if (server_request_sink != null)
                        .{ .context = &server_request_wait, .callback = StdioServerRequestWait.begin }
                    else
                        null,
                },
            );
            request_finished = true;
            break :stdio .{
                .body = body,
                .legacy_terminal = if (legacy_context) |*context| context.directTerminal() else null,
            };
        },
        .http => if (server.legacy_http) |client| legacy: {
            if (!client.acquireUse()) return error.McpConnectionClosed;
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            defer client.releaseUse();
            var legacy_context: ?LegacyElicitationContext = if (legacy_elicitation) |spec|
                if (legacyWireForHttpVersion(client.version)) |wire|
                    LegacyElicitationContext.initHttp(
                        server,
                        client,
                        wire,
                        spec.responder,
                        spec.operation,
                        deadline,
                        cancel_flag,
                    )
                else
                    null
            else
                null;
            if (legacy_context) |*context| try context.beginCompletionWindow();
            defer if (legacy_context) |*context| context.endCompletionWindow();
            const auth_identity = try authIdentityForHeaders(self.alloc, client.static_headers);
            var request_finished = false;
            defer if (!request_finished) {
                if (legacy_context) |*context| {
                    if (context.directTerminal()) |terminal| terminal.finish(self.alloc, .abandoned);
                }
            };
            const body = try client.request(self.alloc, .{
                .request_id = request_id,
                .request_body = request,
                .max_response_bytes = mcp_feature_response_frame_cap_bytes,
                .max_event_bytes = mcp_feature_response_frame_cap_bytes,
                .response_observer = if (legacy_context) |*context| context.responseObserver() else null,
                .server_requests = if (legacy_context) |*context| context.sink() else null,
                .notifications = if (legacy_context) |*context| context.completionSink() else null,
                .control = .{
                    .deadline = deadline,
                    .deadline_gate = if (legacy_context) |*context| &context.deadline_gate else null,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = &self.retiring,
                },
                .precommit = precommit,
            });
            request_finished = true;
            break :legacy .{
                .body = body,
                .auth_identity = auth_identity,
                .legacy_terminal = if (legacy_context) |*context| context.directTerminal() else null,
            };
        } else modern: {
            var identity: feature_cache.Digest = undefined;
            var response = try authenticatedPost(self.alloc, self.alloc, server, .{
                .url = try server.config.remoteUrl(),
                .request_body = request,
                .max_response_bytes = mcp_feature_response_frame_cap_bytes,
                .max_event_bytes = mcp_feature_response_frame_cap_bytes,
                .precommit = precommit,
                .control = .{
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = &self.retiring,
                },
            }, .{
                .runtime = self,
                .access = access,
                .target = .{ .feature_server = server.config.name },
            }, .safe, &identity);
            defer response.deinit(self.alloc);
            break :modern .{ .body = try self.alloc.dupe(u8, response.body), .auth_identity = identity };
        },
        .sse => if (server.legacy_sse) |client| legacy: {
            const body = try client.request(
                self.alloc,
                request_id,
                request,
                mcp_feature_response_frame_cap_bytes,
                .{
                    .deadline = deadline,
                    .cancel_flag = cancel_flag,
                    .lifecycle_cancel_flag = &self.retiring,
                    .precommit = precommit,
                },
            );
            break :legacy .{
                .body = body,
                .auth_identity = try authIdentityForHeaders(self.alloc, client.static_headers),
            };
        } else error.McpConnectionClosed,
    };
}

fn nextFeatureRequestId(server: *McpServer) !u64 {
    return switch (server.config.transport) {
        .stdio => try (server.dispatcher orelse return error.McpConnectionClosed).reserveRequestId(),
        .http, .sse => try reserveHttpRequestId(server),
    };
}

fn serverFeatureProtocol(server: *const McpServer) resources_feature.Protocol {
    if (std.mem.eql(u8, server.negotiated_protocol_version, modern_protocol_version)) return .modern;
    return switch (server.stdio_protocol) {
        .modern => .modern,
        .legacy, .unselected => .legacy,
    };
}

fn currentFeatureCacheKey(
    alloc: Allocator,
    server: *McpServer,
    capability: feature_cache.Capability,
    normalized_arguments: []const u8,
    scope: feature_cache.CacheScope,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    auth_access: AuthEffectAccess,
) !feature_cache.CacheKey {
    const identity = if (scope == .private and server.config.transport != .stdio) identity: {
        break :identity try currentAuthIdentityForAccess(
            alloc,
            server,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = lifecycleCancelFlag(server),
            },
            auth_access,
        );
    } else feature_cache.authIdentity(&.{});
    return cacheKeyWithFeatureAuthIdentity(server, capability, normalized_arguments, scope, identity);
}

fn cacheKeyWithFeatureAuthIdentity(
    server: *const McpServer,
    capability: feature_cache.Capability,
    normalized_arguments: []const u8,
    scope: feature_cache.CacheScope,
    auth_identity: feature_cache.Digest,
) feature_cache.CacheKey {
    return feature_cache.buildCacheKey(.{
        .server_identity = server.config.name,
        .protocol_version = if (server.negotiated_protocol_version.len > 0)
            server.negotiated_protocol_version
        else if (server.stdio_protocol == .modern)
            modern_protocol_version
        else
            legacy_protocol_version,
        .capability = capability,
        .normalized_arguments = normalized_arguments,
        .scope = scope,
        .auth_identity = auth_identity,
    });
}

fn digestResources(items: []const resources_feature.Descriptor) feature_cache.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (items) |item| {
        hashToolField(&hasher, item.uri);
        hashToolField(&hasher, item.name);
        hashOptionalToolField(&hasher, item.title);
        hashOptionalToolField(&hasher, item.description);
        hashOptionalToolField(&hasher, item.mime_type);
        hashOptionalU64Field(&hasher, item.size);
        hashOptionalToolField(&hasher, item.icons_json);
        hashOptionalToolField(&hasher, item.annotations_json);
        hashOptionalToolField(&hasher, item.metadata_json);
    }
    var digest: feature_cache.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn digestResourceTemplates(items: []const resources_feature.Template) feature_cache.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (items) |item| {
        hashToolField(&hasher, item.uri_template);
        hashToolField(&hasher, item.name);
        hashOptionalToolField(&hasher, item.title);
        hashOptionalToolField(&hasher, item.description);
        hashOptionalToolField(&hasher, item.mime_type);
        hashOptionalToolField(&hasher, item.icons_json);
        hashOptionalToolField(&hasher, item.annotations_json);
        hashOptionalToolField(&hasher, item.metadata_json);
    }
    var digest: feature_cache.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn digestPrompts(items: []const prompts_feature.Prompt) feature_cache.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (items) |item| {
        hashToolField(&hasher, item.name);
        hashOptionalToolField(&hasher, item.title);
        hashOptionalToolField(&hasher, item.description);
        hashOptionalToolField(&hasher, item.icons_json);
        for (item.arguments) |argument| {
            hashToolField(&hasher, argument.name);
            hashOptionalToolField(&hasher, argument.description);
            hasher.update(&.{@intFromBool(argument.required)});
        }
        hashOptionalToolField(&hasher, item.metadata_json);
    }
    var digest: feature_cache.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn cloneResourceSummary(alloc: Allocator, server_name: []const u8, resource: resources_feature.Descriptor) !ResourceSummary {
    const owned_server = try alloc.dupe(u8, server_name);
    errdefer alloc.free(owned_server);
    const uri = try alloc.dupe(u8, resource.uri);
    errdefer alloc.free(uri);
    const name = try alloc.dupe(u8, resource.name);
    errdefer alloc.free(name);
    const title = if (resource.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const description = if (resource.description) |value| try alloc.dupe(u8, value) else null;
    errdefer if (description) |value| alloc.free(value);
    const mime_type = if (resource.mime_type) |value| try alloc.dupe(u8, value) else null;
    return .{
        .server_name = owned_server,
        .uri = uri,
        .name = name,
        .title = title,
        .description = description,
        .mime_type = mime_type,
    };
}

fn cloneTemplateSummary(alloc: Allocator, server_name: []const u8, template: resources_feature.Template) !ResourceSummary {
    const owned_server = try alloc.dupe(u8, server_name);
    errdefer alloc.free(owned_server);
    const uri = try alloc.dupe(u8, template.uri_template);
    errdefer alloc.free(uri);
    const name = try alloc.dupe(u8, template.name);
    errdefer alloc.free(name);
    const title = if (template.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const description = if (template.description) |value| try alloc.dupe(u8, value) else null;
    errdefer if (description) |value| alloc.free(value);
    const mime_type = if (template.mime_type) |value| try alloc.dupe(u8, value) else null;
    return .{
        .server_name = owned_server,
        .uri = uri,
        .name = name,
        .title = title,
        .description = description,
        .mime_type = mime_type,
        .is_template = true,
    };
}

fn clonePromptSummary(alloc: Allocator, server_name: []const u8, prompt: prompts_feature.Prompt) !PromptSummary {
    const owned_server = try alloc.dupe(u8, server_name);
    errdefer alloc.free(owned_server);
    const name = try alloc.dupe(u8, prompt.name);
    errdefer alloc.free(name);
    const title = if (prompt.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const description = if (prompt.description) |value| try alloc.dupe(u8, value) else null;
    errdefer if (description) |value| alloc.free(value);
    const arguments = try alloc.alloc(prompts_feature.Argument, prompt.arguments.len);
    var count: usize = 0;
    errdefer {
        for (arguments[0..count]) |*argument| argument.deinit(alloc);
        alloc.free(arguments);
    }
    for (prompt.arguments, 0..) |argument, index| {
        const argument_name = try alloc.dupe(u8, argument.name);
        errdefer alloc.free(argument_name);
        const argument_description = if (argument.description) |value| try alloc.dupe(u8, value) else null;
        arguments[index] = .{
            .name = argument_name,
            .description = argument_description,
            .required = argument.required,
        };
        count += 1;
    }
    return .{
        .server_name = owned_server,
        .name = name,
        .title = title,
        .description = description,
        .arguments = arguments,
    };
}

fn snapshotConcreteResourceIdentity(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !?FeatureIdentitySnapshot {
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    defer self.catalog_mutex.unlockShared(io_mod.getIo());
    if (!featureCatalogAvailable(server, .resources)) return error.McpResourceCatalogUnavailable;
    if (server.resource_catalog.catalog) |catalog| {
        if (catalog.containsUri(uri)) {
            const metadata = server.resource_catalog.metadata orelse return error.McpResourceCatalogUnavailable;
            return try cloneFeatureSnapshot(alloc, server, .resource, uri, null, metadata);
        }
    }
    return null;
}

fn snapshotResourceIdentityWithTemplates(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !FeatureIdentitySnapshot {
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    defer self.catalog_mutex.unlockShared(io_mod.getIo());
    if (!featureCatalogAvailable(server, .resources)) return error.McpResourceCatalogUnavailable;
    if (server.resource_catalog.catalog) |catalog| {
        if (catalog.containsUri(uri)) {
            const metadata = server.resource_catalog.metadata orelse return error.McpResourceCatalogUnavailable;
            return cloneFeatureSnapshot(alloc, server, .resource, uri, null, metadata);
        }
    }
    if (!featureCatalogAvailable(server, .resource_templates)) return error.McpResourceCatalogUnavailable;
    var match_budget = resources_feature.TemplateMatchBudget.init(
        resources_feature.default_template_match_steps,
    );
    if (server.resource_template_catalog.catalog) |catalog| {
        for (catalog.items) |template| {
            try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
            switch (resources_feature.matchTemplateWithBudget(
                template.uri_template,
                uri,
                &match_budget,
            )) {
                .matches => {
                    const metadata = server.resource_template_catalog.metadata orelse return error.McpResourceCatalogUnavailable;
                    return cloneFeatureSnapshot(alloc, server, .resource_template, template.uri_template, uri, metadata);
                },
                .no_match => continue,
                .work_limit_exceeded => return error.McpResourceTemplateMatchLimitExceeded,
            }
        }
    }
    try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
    return error.McpResourceNotFound;
}

fn snapshotPromptIdentity(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    name: []const u8,
    arguments_json: ?[]const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !FeatureIdentitySnapshot {
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    defer self.catalog_mutex.unlockShared(io_mod.getIo());
    if (!featureCatalogAvailable(server, .prompts)) return error.McpPromptCatalogUnavailable;
    const catalog = server.prompt_catalog.catalog orelse return error.McpPromptCatalogUnavailable;
    const prompt = catalog.find(name) orelse return error.McpPromptNotFound;
    if (arguments_json) |arguments| try prompts_feature.validateArgumentsJson(alloc, prompt.*, arguments, .{});
    const metadata = server.prompt_catalog.metadata orelse return error.McpPromptCatalogUnavailable;
    return cloneFeatureSnapshot(alloc, server, .prompt, name, null, metadata);
}

fn snapshotResourceTemplateIdentity(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    uri_template: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !FeatureIdentitySnapshot {
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    defer self.catalog_mutex.unlockShared(io_mod.getIo());
    if (!featureCatalogAvailable(server, .resource_templates)) return error.McpResourceCatalogUnavailable;
    const catalog = server.resource_template_catalog.catalog orelse return error.McpResourceCatalogUnavailable;
    for (catalog.items) |template| {
        if (!std.mem.eql(u8, template.uri_template, uri_template)) continue;
        const metadata = server.resource_template_catalog.metadata orelse return error.McpResourceCatalogUnavailable;
        return cloneFeatureSnapshot(alloc, server, .resource_template, uri_template, null, metadata);
    }
    return error.McpResourceTemplateNotFound;
}

fn cloneFeatureSnapshot(
    alloc: Allocator,
    server: *const McpServer,
    kind: FeatureIdentityKind,
    identity: []const u8,
    requested_uri: ?[]const u8,
    metadata: feature_cache.SnapshotMetadata,
) !FeatureIdentitySnapshot {
    const server_name = try alloc.dupe(u8, server.config.name);
    errdefer alloc.free(server_name);
    const owned_identity = try alloc.dupe(u8, identity);
    errdefer alloc.free(owned_identity);
    const owned_uri = if (requested_uri) |value| try alloc.dupe(u8, value) else null;
    return .{
        .server_name = server_name,
        .identity = owned_identity,
        .requested_uri = owned_uri,
        .kind = kind,
        .cache_key = metadata.key,
        .connection_generation = metadata.connection_generation,
        .catalog_generation = metadata.catalog_generation,
    };
}

fn featureSnapshotCurrent(server: *const McpServer, snapshot: *const FeatureIdentitySnapshot) bool {
    if (!std.mem.eql(u8, server.config.name, snapshot.server_name) or
        server.connection_generation != snapshot.connection_generation)
    {
        return false;
    }
    return switch (snapshot.kind) {
        .resource => current: {
            if (!featureCatalogAvailable(server, .resources)) break :current false;
            const metadata = server.resource_catalog.metadata orelse break :current false;
            if (metadata.catalog_generation != snapshot.catalog_generation or !metadata.key.eql(snapshot.cache_key)) break :current false;
            const catalog = server.resource_catalog.catalog orelse break :current false;
            break :current catalog.containsUri(snapshot.identity);
        },
        .resource_template => current: {
            if (!featureCatalogAvailable(server, .resource_templates)) break :current false;
            const metadata = server.resource_template_catalog.metadata orelse break :current false;
            if (metadata.catalog_generation != snapshot.catalog_generation or !metadata.key.eql(snapshot.cache_key)) break :current false;
            const catalog = server.resource_template_catalog.catalog orelse break :current false;
            for (catalog.items) |template| {
                if (!std.mem.eql(u8, template.uri_template, snapshot.identity)) continue;
                if (snapshot.requested_uri) |uri| {
                    break :current resources_feature.templateMayResolve(template.uri_template, uri);
                }
                break :current true;
            }
            break :current false;
        },
        .prompt => current: {
            if (!featureCatalogAvailable(server, .prompts)) break :current false;
            const metadata = server.prompt_catalog.metadata orelse break :current false;
            if (metadata.catalog_generation != snapshot.catalog_generation or !metadata.key.eql(snapshot.cache_key)) break :current false;
            const catalog = server.prompt_catalog.catalog orelse break :current false;
            break :current catalog.find(snapshot.identity) != null;
        },
    };
}

const FetchedResourceRead = struct {
    result: resources_feature.ReadResult,
    auth_identity: ?feature_cache.Digest,
    received_at_ms: u64,
};

fn cachedResourceRead(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    allow_stale: bool,
    access: tool_mcp_runtime.Access,
) !?ResourceReadResult {
    const public_key = cacheKeyWithFeatureAuthIdentity(
        server,
        .resource_read,
        uri,
        .public,
        feature_cache.authIdentity(&.{}),
    );
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) self.catalog_mutex.unlockShared(io_mod.getIo());
    var has_private_candidate = false;
    for (server.resource_read_cache.items) |entry| {
        if (!std.mem.eql(u8, entry.uri, uri)) continue;
        if (entry.metadata.scope == .private) {
            has_private_candidate = true;
            continue;
        }
        if (!entry.metadata.key.eql(public_key)) continue;
        const freshness = feature_cache.effectiveFreshness(entry.metadata, clockMillis(), false);
        if (!allow_stale and freshness != .fresh) continue;
        if (allow_stale and freshness == .fresh) continue;
        return @as(?ResourceReadResult, try cloneCachedResourceRead(
            alloc,
            server.config.name,
            uri,
            entry.result,
        ));
    }
    self.catalog_mutex.unlockShared(io_mod.getIo());
    catalog_locked = false;
    if (!has_private_candidate) return null;

    const private_key = try currentFeatureCacheKey(
        self.alloc,
        server,
        .resource_read,
        uri,
        .private,
        deadline,
        cancel_flag,
        .{
            .runtime = self,
            .access = access,
            .target = .{ .feature_server = server.config.name },
        },
    );
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    defer self.catalog_mutex.unlockShared(io_mod.getIo());
    for (server.resource_read_cache.items) |entry| {
        if (!std.mem.eql(u8, entry.uri, uri) or entry.metadata.scope != .private) continue;
        if (!entry.metadata.key.eql(private_key) or
            entry.auth_generation != server.auth_generation.load(.acquire))
        {
            continue;
        }
        const freshness = feature_cache.effectiveFreshness(entry.metadata, clockMillis(), false);
        if (!allow_stale and freshness != .fresh) continue;
        if (allow_stale and freshness == .fresh) continue;
        return @as(?ResourceReadResult, try cloneCachedResourceRead(
            alloc,
            server.config.name,
            uri,
            entry.result,
        ));
    }
    return null;
}

fn invalidateResourceReadCacheIfNeeded(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    const subscription = server.tool_subscription orelse return;
    const generation = subscription.resourceUpdateGeneration();
    if (!subscription.hasInvalidationFor(.resource_read)) return;
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    var lock_held = true;
    defer if (lock_held) self.catalog_mutex.unlock(io_mod.getIo());
    for (server.resource_read_cache.items) |*entry| entry.deinit(self.alloc);
    server.resource_read_cache.clearRetainingCapacity();
    self.catalog_mutex.unlock(io_mod.getIo());
    lock_held = false;
    subscription.clearResourceUpdatesThrough(generation);
    debug_trace.logf(
        "mcp",
        "resource read cache invalidated server={s} notification_generation={d}",
        .{ server.config.name, generation },
    );
}

fn ensureResourceUpdateSubscription(
    self: *McpRuntime,
    server: *McpServer,
    requested_uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !void {
    var operation_access = try OperationAccessGuard.init(
        self.alloc,
        access,
        self.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server.config.name });
    switch (access) {
        .unrestricted => {},
        .disabled, .scoped => return,
    }
    if (!server.capabilities.resources_subscribe or serverFeatureProtocol(server) != .modern) {
        return;
    }

    var resource_uris: std.ArrayList([]u8) = .empty;
    defer {
        for (resource_uris.items) |uri| self.alloc.free(uri);
        resource_uris.deinit(self.alloc);
    }
    {
        try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        for (server.resource_read_cache.items) |entry| {
            try appendUniqueOwnedUri(self.alloc, &resource_uris, entry.uri);
        }
    }
    try appendUniqueOwnedUri(self.alloc, &resource_uris, requested_uri);

    try lockMutexUntil(&server.subscription_lifecycle_lock, deadline, cancel_flag);
    defer server.subscription_lifecycle_lock.unlock(io_mod.getIo());
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    var candidate: ?*tool_subscription.State = null;
    defer if (candidate) |subscription| subscription.stopAndDestroy();

    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    var commit_locked = true;
    defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) self.catalog_mutex.unlock(io_mod.getIo());
    if (server.tool_subscription) |subscription| {
        if (subscription.subscribesToResource(requested_uri)) return;
        for (subscription.resourceSubscriptions()) |uri| {
            try appendUniqueOwnedUri(self.alloc, &resource_uris, uri);
        }
    }

    if (server.tool_subscription) |subscription| subscription.requestStop();
    const previous = server.detachToolSubscription();
    expireMcpSnapshotsForSubscriptionHandoff(self, server);
    self.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    server.catalog_commit_lock.unlock(io_mod.getIo());
    commit_locked = false;

    if (previous) |subscription| subscription.stopAndDestroy();
    candidate = createToolSubscriptionWithResources(
        self.alloc,
        server,
        resource_uris.items,
        .{
            .deadline = deadline,
            .cancel_flag = cancel_flag,
            .lifecycle_cancel_flag = &self.retiring,
        },
    ) catch |err| {
        debug_trace.logf(
            "mcp",
            "resource update subscription unavailable server={s} uri={s} err={s}",
            .{ server.config.name, requested_uri, @errorName(err) },
        );
        return err;
    };
    if (candidate == null) return;

    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    commit_locked = true;
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    catalog_locked = true;
    if (server.tool_subscription != null) return;
    publishToolSubscription(server, candidate.?);
    candidate = null;
    self.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    server.catalog_commit_lock.unlock(io_mod.getIo());
    commit_locked = false;
    debug_trace.logf(
        "mcp",
        "resource update subscription installed server={s} watched_resources={d}",
        .{ server.config.name, resource_uris.items.len },
    );
}

fn appendUniqueOwnedUri(
    alloc: Allocator,
    uris: *std.ArrayList([]u8),
    uri: []const u8,
) !void {
    for (uris.items) |candidate| {
        if (std.mem.eql(u8, candidate, uri)) return;
    }
    const owned = try alloc.dupe(u8, uri);
    errdefer alloc.free(owned);
    try uris.append(alloc, owned);
}

fn expireMcpSnapshotsForSubscriptionHandoff(self: *McpRuntime, server: *McpServer) void {
    if (server.tool_catalog.metadata) |*metadata| metadata.expires_at_ms = 0;
    if (server.resource_catalog.metadata) |*metadata| metadata.expires_at_ms = 0;
    if (server.resource_template_catalog.metadata) |*metadata| metadata.expires_at_ms = 0;
    if (server.prompt_catalog.metadata) |*metadata| metadata.expires_at_ms = 0;
    for (server.resource_read_cache.items) |*entry| entry.deinit(self.alloc);
    server.resource_read_cache.clearRetainingCapacity();
}

fn cloneCachedResourceRead(
    alloc: Allocator,
    server_name: []const u8,
    uri: []const u8,
    result: resources_feature.ReadResult,
) !ResourceReadResult {
    const owned_server = try alloc.dupe(u8, server_name);
    errdefer alloc.free(owned_server);
    const owned_uri = try alloc.dupe(u8, uri);
    errdefer alloc.free(owned_uri);
    const contents = try cloneResourceContents(alloc, result.contents);
    return .{ .server_name = owned_server, .uri = owned_uri, .contents = contents };
}

fn cloneResourceContents(
    alloc: Allocator,
    source: []const resources_feature.ResourceContent,
) ![]resources_feature.ResourceContent {
    const contents = try alloc.alloc(resources_feature.ResourceContent, source.len);
    var count: usize = 0;
    errdefer {
        for (contents[0..count]) |*content| content.deinit(alloc);
        alloc.free(contents);
    }
    for (source, 0..) |content, index| {
        const uri = try alloc.dupe(u8, content.uri);
        errdefer alloc.free(uri);
        const mime_type = if (content.mime_type) |value| try alloc.dupe(u8, value) else null;
        errdefer if (mime_type) |value| alloc.free(value);
        const annotations_json = if (content.annotations_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (annotations_json) |value| alloc.free(value);
        const metadata_json = if (content.metadata_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (metadata_json) |value| alloc.free(value);
        const data: resources_feature.ResourceData = switch (content.data) {
            .text => |value| .{ .text = try alloc.dupe(u8, value) },
            .blob => |value| .{ .blob = try alloc.dupe(u8, value) },
        };
        contents[index] = .{
            .uri = uri,
            .mime_type = mime_type,
            .annotations_json = annotations_json,
            .metadata_json = metadata_json,
            .data = data,
        };
        count += 1;
    }
    return contents;
}

fn publishResourceReadCache(
    self: *McpRuntime,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    uri: []const u8,
    fetched: FetchedResourceRead,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !void {
    const scope: feature_cache.CacheScope = switch (fetched.result.cache.scope) {
        .private => .private,
        .public => .public,
    };
    const replacement_key = if (fetched.auth_identity) |identity|
        cacheKeyWithFeatureAuthIdentity(server, .resource_read, uri, scope, identity)
    else
        try currentFeatureCacheKey(
            self.alloc,
            server,
            .resource_read,
            uri,
            scope,
            deadline,
            cancel_flag,
            .{
                .runtime = self,
                .access = access,
                .target = .{ .feature_server = server.config.name },
            },
        );
    const active_key = try currentFeatureCacheKey(
        self.alloc,
        server,
        .resource_read,
        uri,
        scope,
        deadline,
        cancel_flag,
        .{
            .runtime = self,
            .access = access,
            .target = .{ .feature_server = server.config.name },
        },
    );
    if (!replacement_key.eql(active_key)) return;
    const contents = try cloneResourceContents(self.alloc, fetched.result.contents);
    var candidate = resources_feature.ReadResult{ .contents = contents, .cache = fetched.result.cache };
    defer candidate.deinit(self.alloc);
    var owned_uri: ?[]u8 = try self.alloc.dupe(u8, uri);
    defer if (owned_uri) |value| self.alloc.free(value);
    const expires_at_ms = feature_cache.pageExpiry(
        if (serverFeatureProtocol(server) == .modern) .modern else .legacy,
        fetched.received_at_ms,
        fetched.result.cache.ttl_present,
        fetched.result.cache.ttl_ms,
    );
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    if (server.connection_generation != snapshot.connection_generation) return;
    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    defer server.catalog_commit_lock.unlock(io_mod.getIo());
    var subscription: ?*tool_subscription.State = null;
    defer if (subscription) |state| state.unlockCommit();
    if (server.tool_subscription) |state| {
        if (!state.lockFeatureCommitIfCurrent(.resource_read)) return;
        subscription = state;
    }
    var auth_locked = false;
    defer if (auth_locked) server.auth_lock.unlock(io_mod.getIo());
    const committed_key = if (scope == .private and server.config.transport != .stdio) key: {
        try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
        auth_locked = true;
        break :key cacheKeyWithFeatureAuthIdentity(
            server,
            .resource_read,
            uri,
            scope,
            try currentAuthIdentity(self.alloc, server),
        );
    } else active_key;
    if (!replacement_key.eql(committed_key)) return;
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    var lock_held = true;
    defer if (lock_held) self.catalog_mutex.unlock(io_mod.getIo());
    if (!featureSnapshotCurrent(server, snapshot)) return;
    var generation: u64 = 1;
    var replacement_index: ?usize = null;
    for (server.resource_read_cache.items, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.uri, uri)) continue;
        generation = std.math.add(u64, entry.metadata.catalog_generation, 1) catch
            return error.McpGenerationExhausted;
        replacement_index = index;
        break;
    }
    if (replacement_index == null and
        server.resource_read_cache.items.len < max_resource_read_cache_entries)
    {
        try server.resource_read_cache.ensureUnusedCapacity(self.alloc, 1);
    }
    var replaced: ?ResourceReadCacheEntry = null;
    defer if (replaced) |*entry| entry.deinit(self.alloc);
    if (replacement_index) |index| {
        replaced = server.resource_read_cache.orderedRemove(index);
    } else if (server.resource_read_cache.items.len >= max_resource_read_cache_entries) {
        var evicted = server.resource_read_cache.orderedRemove(0);
        evicted.deinit(self.alloc);
    }
    server.resource_read_cache.appendAssumeCapacity(.{
        .uri = owned_uri.?,
        .result = candidate,
        .metadata = .{
            .key = replacement_key,
            .connection_generation = server.connection_generation,
            .catalog_generation = generation,
            .fetched_at_ms = fetched.received_at_ms,
            .expires_at_ms = expires_at_ms,
            .scope = scope,
            .content_digest = digestResourceContents(fetched.result.contents),
        },
        .auth_generation = server.auth_generation.load(.acquire),
    });
    owned_uri = null;
    candidate.contents = &.{};
    self.catalog_mutex.unlock(io_mod.getIo());
    lock_held = false;
}

fn digestResourceContents(items: []const resources_feature.ResourceContent) feature_cache.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (items) |item| {
        hashToolField(&hasher, item.uri);
        hashOptionalToolField(&hasher, item.mime_type);
        hashOptionalToolField(&hasher, item.annotations_json);
        hashOptionalToolField(&hasher, item.metadata_json);
        switch (item.data) {
            .text => |value| hashToolField(&hasher, value),
            .blob => |value| hashToolField(&hasher, value),
        }
    }
    var digest: feature_cache.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn requestResourceRead(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    options: FeatureCallOptions,
) !FetchedResourceRead {
    return requestResourceReadRound(self, alloc, server, snapshot, uri, deadline, options, null, null, 0);
}

fn requestResourceReadRound(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    uri: []const u8,
    deadline: std.Io.Clock.Timestamp,
    options: FeatureCallOptions,
    input_responses_json: ?[]const u8,
    request_state_json: ?[]const u8,
    round: u8,
) !FetchedResourceRead {
    if (self.retiring.load(.acquire)) return error.Cancelled;
    try reauthorizeOperation(
        self,
        options.access,
        .{ .feature_server = server.config.name },
    );
    const request_id = try nextFeatureRequestId(server);
    const request = try resources_feature.buildReadRequest(
        alloc,
        request_id,
        serverFeatureProtocol(server),
        uri,
        metadataWriterForResponder(options.input_responder),
        input_responses_json,
        request_state_json,
    );
    defer alloc.free(request);
    var guard = FeaturePrecommit{ .runtime = self, .server = server, .snapshot = snapshot, .deadline = deadline, .cancel_flag = options.cancel_flag, .access = options.access };
    var precommit = guard.transport();
    var response = try sendFeatureRequest(
        self,
        server,
        request_id,
        request,
        deadline,
        options.cancel_flag,
        options.access,
        &precommit,
        .{ .responder = options.input_responder, .operation = .{ .resources_read = uri } },
    );
    const received_at_ms = clockMillis();
    defer response.deinit(self.alloc);
    var outcome = try resources_feature.parseReadOutcomeForRequest(
        alloc,
        response.body,
        serverFeatureProtocol(server),
        .{},
        .{
            .input_responses_present = input_responses_json != null,
            .request_state_present = request_state_json != null,
        },
    );
    defer outcome.deinit(alloc);
    switch (outcome) {
        .complete => |*complete| {
            response.finishLegacy(self.alloc, .completed);
            const result = complete.*;
            complete.contents = &.{};
            return .{
                .result = result,
                .auth_identity = response.auth_identity,
                .received_at_ms = received_at_ms,
            };
        },
        .protocol_failure => |failure| {
            if (round >= 8) return error.McpInputRequiredLimitExceeded;
            if (try respondToLegacyUrlRequired(
                self,
                alloc,
                server,
                snapshot,
                .{ .resources_read = uri },
                failure.code,
                failure.data_json,
                options,
                round,
            )) |handled| {
                if (handled.decision != .retry) {
                    notifyContinuationTerminal(handled.responder, alloc, handled.origin, .abandoned);
                    return error.McpInputRequired;
                }
                const continued = requestResourceReadRound(
                    self,
                    alloc,
                    server,
                    snapshot,
                    uri,
                    operationDeadline(server),
                    options,
                    null,
                    null,
                    round + 1,
                ) catch |err| {
                    notifyContinuationTerminal(handled.responder, alloc, handled.origin, .abandoned);
                    return err;
                };
                notifyContinuationTerminal(handled.responder, alloc, handled.origin, .completed);
                return continued;
            }
            try retainFeatureProtocolDiagnostic(alloc, options, failure);
            return error.McpProtocolError;
        },
        .input_required => |*required| {
            if (round >= 8) return error.McpInputRequiredLimitExceeded;
            const responder = options.input_responder orelse return error.McpInputRequired;
            const requests_json = try mrtr.renderRequests(alloc, required.requests);
            defer alloc.free(requests_json);
            const compatibility = tool_mcp_runtime.InputRequired{
                .input_requests_json = requests_json,
                .request_state_json = required.request_state_json,
            };
            const interaction_deadline = elicitationDeadline();
            const origin = tool_mcp_runtime.InputOrigin{
                .wire = .modern_mcp,
                .server_name = snapshot.server_name,
                .operation = .{ .resources_read = uri },
                .runtime_generation = self.legacy_url_runtime_generation,
                .connection_generation = snapshot.connection_generation,
                .client_generation = snapshot.connection_generation,
                .catalog_generation = snapshot.catalog_generation,
                .request_generation = round + 1,
                .auth_generation = server.auth_generation.load(.acquire),
                .deadline_ms = timestampMillis(interaction_deadline),
                .lifecycle_cancel_flag = &self.retiring,
            };
            const responses = try responder.callback(
                responder.context,
                alloc,
                origin,
                compatibility,
            );
            defer alloc.free(responses);
            try mrtr.validateResponses(alloc, required.requests, responses, .{});
            const continued = requestResourceReadRound(
                self,
                alloc,
                server,
                snapshot,
                uri,
                operationDeadline(server),
                options,
                responses,
                required.request_state_json,
                round + 1,
            ) catch |err| {
                notifyContinuationTerminal(responder, alloc, origin, .abandoned);
                return err;
            };
            notifyContinuationTerminal(responder, alloc, origin, .completed);
            return continued;
        },
    }
}

fn requestPromptGet(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    name: []const u8,
    arguments_json: []const u8,
    deadline: std.Io.Clock.Timestamp,
    options: FeatureCallOptions,
) !prompts_feature.GetResult {
    return requestPromptGetRound(self, alloc, server, snapshot, name, arguments_json, deadline, options, null, null, 0);
}

fn requestPromptGetRound(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    name: []const u8,
    arguments_json: []const u8,
    deadline: std.Io.Clock.Timestamp,
    options: FeatureCallOptions,
    input_responses_json: ?[]const u8,
    request_state_json: ?[]const u8,
    round: u8,
) !prompts_feature.GetResult {
    if (self.retiring.load(.acquire)) return error.Cancelled;
    try reauthorizeOperation(
        self,
        options.access,
        .{ .feature_server = server.config.name },
    );
    const request_id = try nextFeatureRequestId(server);
    const request = try prompts_feature.buildGetRequest(
        alloc,
        request_id,
        serverFeatureProtocol(server),
        name,
        arguments_json,
        metadataWriterForResponder(options.input_responder),
        input_responses_json,
        request_state_json,
    );
    defer alloc.free(request);
    var guard = FeaturePrecommit{ .runtime = self, .server = server, .snapshot = snapshot, .deadline = deadline, .cancel_flag = options.cancel_flag, .access = options.access };
    var precommit = guard.transport();
    var response = try sendFeatureRequest(
        self,
        server,
        request_id,
        request,
        deadline,
        options.cancel_flag,
        options.access,
        &precommit,
        .{ .responder = options.input_responder, .operation = .{ .prompts_get = name } },
    );
    defer response.deinit(self.alloc);
    var outcome = try prompts_feature.parseGetOutcome(alloc, response.body, serverFeatureProtocol(server), .{});
    defer outcome.deinit(alloc);
    switch (outcome) {
        .complete => |*complete| {
            response.finishLegacy(self.alloc, .completed);
            const result = complete.*;
            complete.description = null;
            complete.messages = &.{};
            return result;
        },
        .protocol_failure => |failure| {
            if (round >= 8) return error.McpInputRequiredLimitExceeded;
            if (try respondToLegacyUrlRequired(
                self,
                alloc,
                server,
                snapshot,
                .{ .prompts_get = name },
                failure.code,
                failure.data_json,
                options,
                round,
            )) |handled| {
                if (handled.decision != .retry) {
                    notifyContinuationTerminal(handled.responder, alloc, handled.origin, .abandoned);
                    return error.McpInputRequired;
                }
                const continued = requestPromptGetRound(
                    self,
                    alloc,
                    server,
                    snapshot,
                    name,
                    arguments_json,
                    operationDeadline(server),
                    options,
                    null,
                    null,
                    round + 1,
                ) catch |err| {
                    notifyContinuationTerminal(handled.responder, alloc, handled.origin, .abandoned);
                    return err;
                };
                notifyContinuationTerminal(handled.responder, alloc, handled.origin, .completed);
                return continued;
            }
            try retainFeatureProtocolDiagnostic(alloc, options, failure);
            return error.McpProtocolError;
        },
        .input_required => |*required| {
            if (round >= 8) return error.McpInputRequiredLimitExceeded;
            const responder = options.input_responder orelse return error.McpInputRequired;
            const requests_json = try mrtr.renderRequests(alloc, required.requests);
            defer alloc.free(requests_json);
            const compatibility = tool_mcp_runtime.InputRequired{
                .input_requests_json = requests_json,
                .request_state_json = required.request_state_json,
            };
            const interaction_deadline = elicitationDeadline();
            const origin = tool_mcp_runtime.InputOrigin{
                .wire = .modern_mcp,
                .server_name = snapshot.server_name,
                .operation = .{ .prompts_get = name },
                .runtime_generation = self.legacy_url_runtime_generation,
                .connection_generation = snapshot.connection_generation,
                .client_generation = snapshot.connection_generation,
                .catalog_generation = snapshot.catalog_generation,
                .request_generation = round + 1,
                .auth_generation = server.auth_generation.load(.acquire),
                .deadline_ms = timestampMillis(interaction_deadline),
                .lifecycle_cancel_flag = &self.retiring,
            };
            const responses = try responder.callback(
                responder.context,
                alloc,
                origin,
                compatibility,
            );
            defer alloc.free(responses);
            try mrtr.validateResponses(alloc, required.requests, responses, .{});
            const continued = requestPromptGetRound(
                self,
                alloc,
                server,
                snapshot,
                name,
                arguments_json,
                operationDeadline(server),
                options,
                responses,
                required.request_state_json,
                round + 1,
            ) catch |err| {
                notifyContinuationTerminal(responder, alloc, origin, .abandoned);
                return err;
            };
            notifyContinuationTerminal(responder, alloc, origin, .completed);
            return continued;
        },
    }
}

const HandledLegacyUrlRequired = struct {
    decision: elicitation.LegacyUrlRetryDecision,
    origin: tool_mcp_runtime.InputOrigin,
    responder: tool_mcp_runtime.InputResponder,
};

const LegacyUrlCatalogGuard = union(enum) {
    tool: *const ToolCallSnapshot,
    feature: *const FeatureIdentitySnapshot,
};

fn handleLegacyUrlRequiredInteraction(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    origin: tool_mcp_runtime.InputOrigin,
    requests: []const mrtr.InputRequest,
    requests_json: []const u8,
    responder: tool_mcp_runtime.InputResponder,
    catalog_guard: LegacyUrlCatalogGuard,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !elicitation.LegacyUrlRetryDecision {
    const ids = try alloc.alloc([]const u8, requests.len);
    defer alloc.free(ids);
    for (requests, 0..) |request, index| {
        if (request.payload != .elicitation_create or
            request.payload.elicitation_create.mode != .url)
        {
            return error.McpInvalidInputRequired;
        }
        ids[index] = request.payload.elicitation_create.elicitation_id orelse
            return error.McpInvalidInputRequired;
    }
    const completed = try alloc.alloc(bool, ids.len);
    defer alloc.free(completed);
    @memset(completed, false);
    var waiter = LegacyUrlWaiter{
        .binding = .{
            .server_name = origin.server_name,
            .scope = .{ .operation = origin.operation },
            .runtime_generation = origin.runtime_generation,
            .connection_generation = origin.connection_generation,
            .client_generation = origin.client_generation,
            .catalog_generation = origin.catalog_generation,
            .request_generation = origin.request_generation,
            .auth_generation = origin.auth_generation,
            .deadline_ms = origin.deadline_ms,
        },
        .ids = ids,
        .completed = completed,
    };
    try self.registerCurrentLegacyUrlWaiter(&waiter);
    defer self.unregisterLegacyUrlWaiter(&waiter);

    const consent_responses = try responder.callback(
        responder.context,
        alloc,
        origin,
        .{
            .input_requests_json = requests_json,
            .legacy_retry_without_responses = true,
            .legacy_url_phase = .consent,
        },
    );
    defer alloc.free(consent_responses);
    const consent = mrtr.legacyUrlConsent(alloc, requests, consent_responses, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.McpInvalidInputResponses,
    };
    const consent_decision = elicitation.decideLegacyUrlRetry(consent, .none);
    if (consent_decision != .await_completion) return consent_decision;

    if (waiter.signal.status.load(.acquire) == .completed) {
        if (!try legacyUrlBindingCurrent(self, server, waiter.binding, catalog_guard, deadline, cancel_flag)) {
            return .cancelled;
        }
        return .retry;
    }

    if (responder.legacy_url_manual_completion) {
        const completion_responses = try responder.callback(
            responder.context,
            alloc,
            origin,
            .{
                .input_requests_json = requests_json,
                .legacy_retry_without_responses = true,
                .legacy_url_phase = .await_completion,
                .legacy_url_completion_signal = &waiter.signal,
            },
        );
        defer alloc.free(completion_responses);
        const completion_consent = mrtr.legacyUrlConsent(
            alloc,
            requests,
            completion_responses,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.McpInvalidInputResponses,
        };
        const proof: elicitation.LegacyUrlCompletionProof = if (waiter.signal.status.load(.acquire) == .completed) .notifications else .manual_retry;
        const decision = elicitation.decideLegacyUrlRetry(completion_consent, proof);
        if (decision != .retry) return decision;
    } else {
        while (true) {
            switch (waiter.signal.status.load(.acquire)) {
                .completed => break,
                .cancelled => return .cancelled,
                .pending => {},
            }
            try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
            if (self.retiring.load(.acquire)) return error.Cancelled;
            try io_mod.getIo().sleep(.fromMilliseconds(10), .awake);
        }
    }

    if (!try legacyUrlBindingCurrent(self, server, waiter.binding, catalog_guard, deadline, cancel_flag)) {
        return .cancelled;
    }
    return .retry;
}

fn legacyUrlBindingCurrent(
    self: *McpRuntime,
    server: *McpServer,
    binding: elicitation.Binding,
    catalog_guard: LegacyUrlCatalogGuard,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !bool {
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    defer self.catalog_mutex.unlockShared(io_mod.getIo());
    const current = self.findServer(binding.server_name) orelse return false;
    const client_generation = if (server.dispatcher) |dispatcher|
        dispatcher.connectionGeneration()
    else
        server.connection_generation;
    return current == server and
        self.legacy_url_runtime_generation == binding.runtime_generation and
        server.connection_generation == binding.connection_generation and
        client_generation == binding.client_generation and
        server.auth_generation.load(.acquire) == binding.auth_generation and
        legacyWireForServer(server) == .legacy_mcp_2025_11 and
        switch (catalog_guard) {
            .tool => |snapshot| self.serverForSnapshotLocked(snapshot) == server,
            .feature => |snapshot| featureSnapshotCurrent(server, snapshot),
        };
}

fn respondToLegacyUrlRequired(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    operation: elicitation.Operation,
    code: i64,
    data_json: ?[]const u8,
    options: FeatureCallOptions,
    round: u8,
) !?HandledLegacyUrlRequired {
    const wire = legacyWireForServer(server) orelse return null;
    if (wire != .legacy_mcp_2025_11 or
        code != elicitation.legacy_url_required_error_code or
        data_json == null)
    {
        return null;
    }
    var required = elicitation.parseLegacyUrlRequired(
        alloc,
        wire,
        data_json.?,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.McpProtocolError,
    };
    defer required.deinit(alloc);
    const requests_json = try elicitation.renderLegacyUrlRequiredRequests(alloc, required, .{});
    defer alloc.free(requests_json);
    const requests = mrtr.parseRequestJsonForWire(alloc, requests_json, wire, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.McpProtocolError,
    };
    defer {
        for (requests) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    const responder = options.input_responder orelse return error.McpInputRequired;
    const interaction_deadline = elicitationDeadline();
    const origin = tool_mcp_runtime.InputOrigin{
        .wire = wire,
        .server_name = snapshot.server_name,
        .operation = operation,
        .runtime_generation = self.legacy_url_runtime_generation,
        .connection_generation = snapshot.connection_generation,
        .client_generation = if (server.dispatcher) |dispatcher|
            dispatcher.connectionGeneration()
        else
            snapshot.connection_generation,
        .catalog_generation = snapshot.catalog_generation,
        .request_generation = round + 1,
        .auth_generation = server.auth_generation.load(.acquire),
        .deadline_ms = timestampMillis(interaction_deadline),
        .lifecycle_cancel_flag = &self.retiring,
    };
    return .{
        .decision = try handleLegacyUrlRequiredInteraction(
            self,
            alloc,
            server,
            origin,
            requests,
            requests_json,
            responder,
            .{ .feature = snapshot },
            interaction_deadline,
            options.cancel_flag,
        ),
        .origin = origin,
        .responder = responder,
    };
}

fn requireWorkspaceOperationApproval(server: *const McpServer) !void {
    if (server.config.source == .workspace and
        server.config.workspace_admission != .approved)
    {
        return error.McpWorkspaceApprovalRequired;
    }
}

fn completeFeatureArgument(
    self: *McpRuntime,
    alloc: Allocator,
    server_name: []const u8,
    reference: completion_feature.Reference,
    argument: completion_feature.Argument,
    context_arguments: []const completion_feature.Argument,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !CompletionResult {
    if (self.isDiscovering()) return error.McpDiscoveryInProgress;
    var operation_access = try OperationAccessGuard.init(
        self.alloc,
        access,
        self.generation,
    );
    defer operation_access.deinit();
    try operation_access.authorize(.{ .feature_server = server_name });
    const server = self.findServer(server_name) orelse return error.McpServerNotFound;
    try requireWorkspaceOperationApproval(server);
    if (!server.capabilities.completion) return error.McpCompletionUnsupported;
    switch (reference) {
        .prompt => if (!server.capabilities.prompts) return error.McpPromptsUnsupported,
        .resource_template => if (!server.capabilities.resources) return error.McpResourcesUnsupported,
    }
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(server.config.operation_timeout_ms),
    });
    while (true) {
        var snapshot = switch (reference) {
            .prompt => |name| snapshot: {
                _ = try ensurePromptCatalog(self, server, deadline, cancel_flag, access);
                break :snapshot try snapshotPromptIdentity(self, alloc, server, name, null, deadline, cancel_flag);
            },
            .resource_template => |uri| snapshot: {
                _ = try ensureResourceCatalog(self, server, true, deadline, cancel_flag, access);
                break :snapshot try snapshotResourceTemplateIdentity(self, alloc, server, uri, deadline, cancel_flag);
            },
        };
        defer snapshot.deinit(alloc);
        try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
        if (try self.ensureFeatureServerRunning(server, deadline, cancel_flag, access)) continue;
        const request_id = try nextFeatureRequestId(server);
        const request = try completion_feature.buildRequest(
            alloc,
            request_id,
            serverFeatureProtocol(server),
            reference,
            argument,
            context_arguments,
            .{},
            writeModernRequestMetadata,
        );
        defer alloc.free(request);
        var guard = FeaturePrecommit{ .runtime = self, .server = server, .snapshot = &snapshot, .deadline = deadline, .cancel_flag = cancel_flag, .access = access };
        var precommit = guard.transport();
        var response = try sendFeatureRequest(self, server, request_id, request, deadline, cancel_flag, access, &precommit, null);
        defer response.deinit(self.alloc);
        var result = try completion_feature.parseResult(alloc, response.body, serverFeatureProtocol(server), .{});
        errdefer result.deinit(alloc);
        const owned_server = try alloc.dupe(u8, server.config.name);
        errdefer alloc.free(owned_server);
        try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
        const values = result.values;
        const total = result.total;
        const has_more = result.has_more;
        result.values = &.{};
        result.deinit(alloc);
        return .{ .server_name = owned_server, .values = values, .total = total, .has_more = has_more };
    }
}

pub const ServerState = enum {
    disconnected,
    disabled,
    ready,
    failed,
};

pub const ToolFreshness = feature_cache.Freshness;
const DiscoveryState = enum(u8) {
    idle,
    loading,
    complete,
};

pub const McpServerConfig = mcp_contract.McpServerConfig;
const freeOwnedStrings = mcp_contract.freeOwnedStrings;

pub const McpTool = struct {
    original_name: []const u8,
    prefixed_name: []u8,
    title: ?[]u8 = null,
    description: []u8,
    input_schema_json: []u8,
    output_schema_json: ?[]u8 = null,
    icons_json: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,
    tags: []const []u8,
};

pub const ToolCatalogSnapshot = struct {
    tools: std.ArrayList(McpTool) = .empty,
    metadata: ?feature_cache.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = true,

    fn deinit(self: *ToolCatalogSnapshot, alloc: Allocator) void {
        freeTools(alloc, self.tools.items);
        self.tools.deinit(alloc);
        self.* = .{};
    }
};

pub const ResourceCatalogSnapshot = struct {
    catalog: ?resources_feature.ResourceCatalog = null,
    metadata: ?feature_cache.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    fn deinit(self: *ResourceCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

pub const ResourceTemplateCatalogSnapshot = struct {
    catalog: ?resources_feature.TemplateCatalog = null,
    metadata: ?feature_cache.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    fn deinit(self: *ResourceTemplateCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

pub const PromptCatalogSnapshot = struct {
    catalog: ?prompts_feature.Catalog = null,
    metadata: ?feature_cache.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    fn deinit(self: *PromptCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

const ResourceReadCacheEntry = struct {
    uri: []u8,
    result: resources_feature.ReadResult,
    metadata: feature_cache.SnapshotMetadata,
    auth_generation: u64,

    fn deinit(self: *ResourceReadCacheEntry, alloc: Allocator) void {
        alloc.free(self.uri);
        self.result.deinit(alloc);
        self.* = undefined;
    }
};

pub const ServerCapabilities = struct {
    resources: bool = false,
    resources_list_changed: bool = false,
    resources_subscribe: bool = false,
    prompts: bool = false,
    prompts_list_changed: bool = false,
    completion: bool = false,

    fn exposesFeatures(self: ServerCapabilities) bool {
        return self.resources or self.prompts or self.completion;
    }
};

pub const ResourceSummary = struct {
    server_name: []u8,
    uri: []u8,
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    mime_type: ?[]u8 = null,
    is_template: bool = false,

    pub fn deinit(self: *ResourceSummary, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.uri);
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        if (self.mime_type) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ResourceCatalogResult = struct {
    items: []ResourceSummary,

    pub fn deinit(self: *ResourceCatalogResult, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = undefined;
    }
};

pub const PromptSummary = struct {
    server_name: []u8,
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    arguments: []prompts_feature.Argument,

    pub fn deinit(self: *PromptSummary, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.name);
        if (self.title) |value| alloc.free(value);
        if (self.description) |value| alloc.free(value);
        for (self.arguments) |*argument| argument.deinit(alloc);
        alloc.free(self.arguments);
        self.* = undefined;
    }
};

pub const PromptCatalogResult = struct {
    items: []PromptSummary,

    pub fn deinit(self: *PromptCatalogResult, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = undefined;
    }
};

pub const FeatureCallOptions = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    input_responder: ?tool_mcp_runtime.InputResponder = null,
    access: tool_mcp_runtime.Access = .unrestricted,
    protocol_diagnostic: ?*?[]u8 = null,
};

pub const ResourceReadResult = struct {
    server_name: []u8,
    uri: []u8,
    contents: []resources_feature.ResourceContent,
    untrusted: bool = true,

    pub fn deinit(self: *ResourceReadResult, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.uri);
        for (self.contents) |*content| content.deinit(alloc);
        alloc.free(self.contents);
        self.* = undefined;
    }
};

pub const PromptGetResult = struct {
    server_name: []u8,
    name: []u8,
    description: ?[]u8,
    messages: []prompts_feature.Message,
    untrusted: bool = true,

    pub fn deinit(self: *PromptGetResult, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.name);
        if (self.description) |value| alloc.free(value);
        for (self.messages) |*message| message.deinit(alloc);
        alloc.free(self.messages);
        self.* = undefined;
    }
};

pub const CompletionResult = struct {
    server_name: []u8,
    values: []const []u8,
    total: ?u64,
    has_more: ?bool,

    pub fn deinit(self: *CompletionResult, alloc: Allocator) void {
        alloc.free(self.server_name);
        for (self.values) |value| alloc.free(value);
        alloc.free(self.values);
        self.* = undefined;
    }
};

const ToolCallSnapshot = struct {
    server_name: []u8,
    original_name: []u8,
    prefixed_name: []u8,
    input_schema_json: []u8,
    output_schema_json: ?[]u8,
    cache_key: feature_cache.CacheKey,
    connection_generation: u64,
    catalog_generation: u64,
    stdio_generation: ?u64,

    fn init(
        alloc: Allocator,
        server: *const McpServer,
        tool: *const McpTool,
    ) !ToolCallSnapshot {
        const metadata = server.tool_catalog.metadata orelse
            return error.McpToolCatalogUnavailable;
        const server_name = try alloc.dupe(u8, server.config.name);
        errdefer alloc.free(server_name);
        const original_name = try alloc.dupe(u8, tool.original_name);
        errdefer alloc.free(original_name);
        const prefixed_name = try alloc.dupe(u8, tool.prefixed_name);
        errdefer alloc.free(prefixed_name);
        const input_schema_json = try alloc.dupe(u8, tool.input_schema_json);
        errdefer alloc.free(input_schema_json);
        const output_schema_json = if (tool.output_schema_json) |schema|
            try alloc.dupe(u8, schema)
        else
            null;
        errdefer if (output_schema_json) |schema| alloc.free(schema);
        return .{
            .server_name = server_name,
            .original_name = original_name,
            .prefixed_name = prefixed_name,
            .input_schema_json = input_schema_json,
            .output_schema_json = output_schema_json,
            .cache_key = metadata.key,
            .connection_generation = server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .stdio_generation = if (server.dispatcher) |dispatcher|
                dispatcher.connectionGeneration()
            else
                null,
        };
    }

    fn deinit(self: *ToolCallSnapshot, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.original_name);
        alloc.free(self.prefixed_name);
        alloc.free(self.input_schema_json);
        if (self.output_schema_json) |schema| alloc.free(schema);
        self.* = undefined;
    }
};

const FeatureIdentityKind = enum {
    resource,
    prompt,
    resource_template,

    fn capability(self: FeatureIdentityKind) feature_cache.Capability {
        return switch (self) {
            .resource => .resources_list,
            .prompt => .prompts_list,
            .resource_template => .resource_templates_list,
        };
    }
};

const FeatureIdentitySnapshot = struct {
    server_name: []u8,
    identity: []u8,
    requested_uri: ?[]u8 = null,
    kind: FeatureIdentityKind,
    cache_key: feature_cache.CacheKey,
    connection_generation: u64,
    catalog_generation: u64,

    fn deinit(self: *FeatureIdentitySnapshot, alloc: Allocator) void {
        alloc.free(self.server_name);
        alloc.free(self.identity);
        if (self.requested_uri) |value| alloc.free(value);
        self.* = undefined;
    }
};

const FeaturePrecommit = struct {
    runtime: *McpRuntime,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access = .unrestricted,
    live_view: ?tool_mcp_runtime.ResolvedLiveView = null,
    subscription: ?*tool_subscription.State = null,
    subscription_locked: bool = false,
    catalog_commit_locked: bool = false,
    auth_locked: bool = false,

    fn transport(self: *FeaturePrecommit) mcp_contract.TransportPrecommit {
        return .{ .context = self, .acquire_callback = acquireCallback, .release_callback = releaseCallback };
    }

    fn acquireCallback(raw: *anyopaque) !void {
        const self: *FeaturePrecommit = @ptrCast(@alignCast(raw));
        errdefer self.release();
        try checkOperationControl(io_mod.getIo(), self.deadline, self.cancel_flag);
        if (self.runtime.retiring.load(.acquire)) return error.Cancelled;
        self.live_view = try authorizeLiveAccess(
            self.runtime.alloc,
            self.access,
            self.runtime.generation,
            .{ .feature_server = self.snapshot.server_name },
        );
        try lockMutexUntil(&self.server.catalog_commit_lock, self.deadline, self.cancel_flag);
        self.catalog_commit_locked = true;
        if (self.server.tool_subscription) |subscription| {
            const feature: tool_subscription.FeatureInvalidation = switch (self.snapshot.kind) {
                .resource => .resource_read,
                .resource_template => .resource_templates,
                .prompt => .prompts,
            };
            if (!subscription.lockFeatureCommitIfCurrent(feature)) {
                return error.McpFeatureCatalogChanged;
            }
            self.subscription = subscription;
            self.subscription_locked = true;
        }
        const private_remote = self.snapshot.cache_key.private_auth_identity != null and
            self.server.config.transport != .stdio;
        if (private_remote) {
            try lockMutexUntil(&self.server.auth_lock, self.deadline, self.cancel_flag);
            self.auth_locked = true;
        }
        try lockRwSharedUntil(&self.runtime.catalog_mutex, self.deadline, self.cancel_flag);
        defer self.runtime.catalog_mutex.unlockShared(io_mod.getIo());
        if (!featureSnapshotCurrent(self.server, self.snapshot)) return error.McpFeatureCatalogChanged;
        if (private_remote) {
            const active_key = cacheKeyWithFeatureAuthIdentity(
                self.server,
                self.snapshot.kind.capability(),
                "{}",
                .private,
                try currentAuthIdentity(self.runtime.alloc, self.server),
            );
            if (!self.snapshot.cache_key.eql(active_key)) return error.McpFeatureCatalogChanged;
        }
    }

    fn releaseCallback(raw: *anyopaque) void {
        const self: *FeaturePrecommit = @ptrCast(@alignCast(raw));
        self.release();
    }

    fn release(self: *FeaturePrecommit) void {
        if (self.live_view) |*view| {
            view.deinit(self.runtime.alloc);
            self.live_view = null;
        }
        if (self.auth_locked) {
            self.server.auth_lock.unlock(io_mod.getIo());
            self.auth_locked = false;
        }
        if (self.subscription_locked) {
            self.subscription.?.unlockCommit();
            self.subscription_locked = false;
            self.subscription = null;
        }
        if (self.catalog_commit_locked) {
            self.server.catalog_commit_lock.unlock(io_mod.getIo());
            self.catalog_commit_locked = false;
        }
    }
};

const ServerAccessPrecommit = struct {
    runtime: *McpRuntime,
    target: access_policy.Target,
    access: tool_mcp_runtime.Access,
    live_view: ?tool_mcp_runtime.ResolvedLiveView = null,

    fn transport(self: *ServerAccessPrecommit) mcp_contract.TransportPrecommit {
        return .{
            .context = self,
            .acquire_callback = acquireCallback,
            .release_callback = releaseCallback,
        };
    }

    fn acquireCallback(raw: *anyopaque) !void {
        const self: *ServerAccessPrecommit = @ptrCast(@alignCast(raw));
        errdefer self.release();
        if (self.runtime.retiring.load(.acquire)) return error.Cancelled;
        self.live_view = try authorizeLiveAccess(
            self.runtime.alloc,
            self.access,
            self.runtime.generation,
            self.target,
        );
    }

    fn releaseCallback(raw: *anyopaque) void {
        const self: *ServerAccessPrecommit = @ptrCast(@alignCast(raw));
        self.release();
    }

    fn release(self: *ServerAccessPrecommit) void {
        if (self.live_view) |*view| {
            view.deinit(self.runtime.alloc);
            self.live_view = null;
        }
    }
};

/// Owns one current live-authority snapshot for an MCP operation. It is
/// resolved before catalog or connection locks are acquired and may be
/// refreshed after preliminary effects before returning a result.
const OperationAccessGuard = struct {
    alloc: Allocator,
    access: tool_mcp_runtime.Access,
    runtime_generation: u64,
    live_view: ?tool_mcp_runtime.ResolvedLiveView = null,

    fn init(
        alloc: Allocator,
        access: tool_mcp_runtime.Access,
        runtime_generation: u64,
    ) !OperationAccessGuard {
        var guard = OperationAccessGuard{
            .alloc = alloc,
            .access = access,
            .runtime_generation = runtime_generation,
        };
        errdefer guard.deinit();
        try guard.refresh();
        return guard;
    }

    fn deinit(self: *OperationAccessGuard) void {
        if (self.live_view) |*view| view.deinit(self.alloc);
        self.live_view = null;
    }

    fn refresh(self: *OperationAccessGuard) !void {
        self.deinit();
        self.live_view = try resolveLiveAuthority(
            self.alloc,
            self.access,
            self.runtime_generation,
        );
    }

    fn authorize(self: *const OperationAccessGuard, target: access_policy.Target) !void {
        switch (self.access) {
            .unrestricted => return,
            .disabled => return error.McpAccessDenied,
            .scoped => |scope| {
                const live = self.live_view orelse return error.McpAuthorityChanged;
                if (access_policy.authorize(scope.captured.*, live.view, target) != .allow) {
                    return error.McpAuthorityChanged;
                }
            },
        }
    }

    fn refreshAndAuthorize(
        self: *OperationAccessGuard,
        target: access_policy.Target,
    ) !void {
        try self.refresh();
        try self.authorize(target);
    }

    fn allows(self: *const OperationAccessGuard, target: access_policy.Target) bool {
        self.authorize(target) catch return false;
        return true;
    }
};

fn reauthorizeOperation(
    self: *McpRuntime,
    access: tool_mcp_runtime.Access,
    target: access_policy.Target,
) !void {
    var guard = try OperationAccessGuard.init(self.alloc, access, self.generation);
    defer guard.deinit();
    try guard.authorize(target);
}

const ToolPrecommit = struct {
    runtime: *McpRuntime,
    server: *McpServer,
    snapshot: *const ToolCallSnapshot,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access = .unrestricted,
    live_view: ?tool_mcp_runtime.ResolvedLiveView = null,
    subscription: ?*tool_subscription.State = null,
    subscription_locked: bool = false,
    catalog_commit_locked: bool = false,
    auth_locked: bool = false,

    fn transport(self: *ToolPrecommit) mcp_contract.TransportPrecommit {
        return .{
            .context = self,
            .acquire_callback = acquireCallback,
            .release_callback = releaseCallback,
        };
    }

    fn acquireCallback(raw: *anyopaque) !void {
        const self: *ToolPrecommit = @ptrCast(@alignCast(raw));
        errdefer self.release();
        try checkOperationControl(io_mod.getIo(), self.deadline, self.cancel_flag);
        if (self.runtime.retiring.load(.acquire)) return error.Cancelled;
        self.live_view = try authorizeLiveAccess(
            self.runtime.alloc,
            self.access,
            self.runtime.generation,
            .{ .tool = self.snapshot.prefixed_name },
        );

        try lockMutexUntil(
            &self.server.catalog_commit_lock,
            self.deadline,
            self.cancel_flag,
        );
        self.catalog_commit_locked = true;

        if (self.server.tool_subscription) |subscription| {
            if (!subscription.lockCommitIfCurrent()) {
                return error.McpToolCatalogChanged;
            }
            self.subscription = subscription;
            self.subscription_locked = true;
        }

        const private_remote = self.snapshot.cache_key.private_auth_identity != null and
            self.server.config.transport != .stdio;
        if (private_remote) {
            try lockMutexUntil(
                &self.server.auth_lock,
                self.deadline,
                self.cancel_flag,
            );
            self.auth_locked = true;
        }

        try lockRwSharedUntil(
            &self.runtime.catalog_mutex,
            self.deadline,
            self.cancel_flag,
        );
        defer self.runtime.catalog_mutex.unlockShared(io_mod.getIo());
        if (self.runtime.serverForSnapshotLocked(self.snapshot) != self.server) {
            return error.McpToolCatalogChanged;
        }
        if (private_remote) {
            const active_key = cacheKeyWithAuthIdentity(
                self.server,
                .private,
                try currentAuthIdentity(self.runtime.alloc, self.server),
            );
            if (!self.snapshot.cache_key.eql(active_key)) {
                return error.McpToolCatalogChanged;
            }
        }
    }

    fn releaseCallback(raw: *anyopaque) void {
        const self: *ToolPrecommit = @ptrCast(@alignCast(raw));
        self.release();
    }

    fn release(self: *ToolPrecommit) void {
        if (self.live_view) |*view| {
            view.deinit(self.runtime.alloc);
            self.live_view = null;
        }
        if (self.auth_locked) {
            self.server.auth_lock.unlock(io_mod.getIo());
            self.auth_locked = false;
        }
        if (self.subscription_locked) {
            self.subscription.?.unlockCommit();
            self.subscription_locked = false;
            self.subscription = null;
        }
        if (self.catalog_commit_locked) {
            self.server.catalog_commit_lock.unlock(io_mod.getIo());
            self.catalog_commit_locked = false;
        }
    }
};

fn authorizeLiveAccess(
    alloc: Allocator,
    access: tool_mcp_runtime.Access,
    runtime_generation: u64,
    target: access_policy.Target,
) !?tool_mcp_runtime.ResolvedLiveView {
    var live = try resolveLiveAuthority(alloc, access, runtime_generation);
    errdefer if (live) |*view| view.deinit(alloc);
    switch (access) {
        .unrestricted => {},
        .disabled => unreachable,
        .scoped => |scope| {
            if (access_policy.authorize(scope.captured.*, live.?.view, target) != .allow) {
                return error.McpAuthorityChanged;
            }
        },
    }
    return live;
}

fn resolveLiveAuthority(
    alloc: Allocator,
    access: tool_mcp_runtime.Access,
    runtime_generation: u64,
) !?tool_mcp_runtime.ResolvedLiveView {
    return switch (access) {
        .unrestricted => null,
        .disabled => error.McpAccessDenied,
        .scoped => |scope| scoped: {
            if (scope.admission_authority_generation == 0 or
                scope.captured.runtime_generation != runtime_generation)
            {
                return error.McpAuthorityChanged;
            }
            var live = try scope.live.resolve(alloc);
            errdefer live.deinit(alloc);
            if (live.authority_generation == 0 or
                live.authority_generation != scope.admission_authority_generation)
            {
                return error.McpAuthorityChanged;
            }
            if (scope.action_authority_generation != 0 and
                (live.action_authority_generation == 0 or
                    live.action_authority_generation != scope.action_authority_generation))
            {
                return error.McpAuthorityChanged;
            }
            break :scoped live;
        },
    };
}

fn snapshotServerHealthBeforeDiscoveryPublication(
    alloc: Allocator,
    runtime_generation: u64,
    server: *const McpServer,
    discovering: bool,
) !health.ServerSnapshot {
    const configured_name = try terminalSafeOwned(alloc, server.config.name, 256);
    errdefer alloc.free(configured_name);
    const connection: health.ConnectionState = if (!server.config.enabled)
        .disabled
    else if (discovering)
        .connecting
    else
        .disconnected;
    const authentication = serverAuthenticationState(server);
    const failure = try healthFailureForState(
        alloc,
        server.config.required,
        connection,
        authentication,
    );
    return .{
        .configured_name = configured_name,
        .negotiated_name = null,
        .negotiated_version = null,
        .source = server.config.source,
        .scope = server.config.scope,
        .workspace_admission = server.config.workspace_admission,
        .required = server.config.required,
        .transport = server.config.transport,
        .protocol_version = null,
        .connection = connection,
        .authentication = authentication,
        .counts = .{},
        .cache_freshness = .unavailable,
        .subscription = .unavailable,
        .runtime_generation = runtime_generation,
        .catalog_generation = 0,
        .retry_attempt = 0,
        .retry_in_ms = null,
        .last_successful_discovery_ms = null,
        .failure = failure,
    };
}

fn snapshotServerHealth(
    alloc: Allocator,
    runtime_generation: u64,
    server: *const McpServer,
    captured_at_ms: u64,
) !health.ServerSnapshot {
    const configured_name = try terminalSafeOwned(alloc, server.config.name, 256);
    errdefer alloc.free(configured_name);
    const negotiated_name = if (server.negotiated_server_name) |value|
        try terminalSafeOwned(alloc, value, 256)
    else
        null;
    errdefer if (negotiated_name) |value| alloc.free(value);
    const negotiated_version = if (server.negotiated_server_version) |value|
        try terminalSafeOwned(alloc, value, 128)
    else
        null;
    errdefer if (negotiated_version) |value| alloc.free(value);
    const protocol_version = if (server.negotiated_protocol_version.len > 0)
        try terminalSafeOwned(alloc, server.negotiated_protocol_version, 128)
    else
        null;
    errdefer if (protocol_version) |value| alloc.free(value);
    const published_connection: health.ConnectionState = switch (server.state) {
        .disconnected => .disconnected,
        .disabled => .disabled,
        .ready => .ready,
        .failed => .failed,
    };
    const transport_running: ?bool = if (server.config.transport == .stdio)
        if (server.dispatcher) |dispatcher| dispatcher.isRunning() else false
    else
        null;
    const connection = health.observedConnection(
        published_connection,
        transport_running,
    );
    const authentication = serverAuthenticationState(server);
    const failure = try healthFailureForState(
        alloc,
        server.config.required,
        connection,
        authentication,
    );
    errdefer if (failure) |value| alloc.free(value);
    return .{
        .configured_name = configured_name,
        .negotiated_name = negotiated_name,
        .negotiated_version = negotiated_version,
        .source = server.config.source,
        .scope = server.config.scope,
        .workspace_admission = server.config.workspace_admission,
        .required = server.config.required,
        .transport = server.config.transport,
        .protocol_version = protocol_version,
        .connection = connection,
        .authentication = authentication,
        .counts = .{
            .tools = health.capabilityCount(
                true,
                serverCatalogAvailable(server),
                server.tool_catalog.tools.items.len,
            ),
            .resources = health.capabilityCount(
                server.capabilities.resources,
                server.resource_catalog.available,
                if (server.resource_catalog.catalog) |catalog| catalog.items.len else 0,
            ),
            .resource_templates = health.capabilityCount(
                server.capabilities.resources,
                server.resource_template_catalog.available,
                if (server.resource_template_catalog.catalog) |catalog| catalog.items.len else 0,
            ),
            .prompts = health.capabilityCount(
                server.capabilities.prompts,
                server.prompt_catalog.available,
                if (server.prompt_catalog.catalog) |catalog| catalog.prompts.len else 0,
            ),
        },
        .cache_freshness = aggregateCacheFreshness(server, captured_at_ms),
        .subscription = subscriptionHealth(server),
        .runtime_generation = runtime_generation,
        .catalog_generation = server.catalog_generation,
        .retry_attempt = aggregateRetryAttempt(server),
        .retry_in_ms = health.retryDelay(
            aggregateNextRetry(server),
            captured_at_ms,
        ),
        .last_successful_discovery_ms = server.last_successful_discovery_ms,
        .failure = failure,
    };
}

fn configuredAuthenticationState(server: *const McpServer) health.AuthenticationState {
    return if (server.config.auth != null or
        server.config.bearer_token_env != null or
        server.config.header_env.len > 0)
        .configured
    else
        .none;
}

fn serverAuthenticationState(server: *const McpServer) health.AuthenticationState {
    if (server.auth_challenge_present.load(.acquire)) return .required;
    if (server.auth_credentials_present.load(.acquire)) return .authenticated;
    return configuredAuthenticationState(server);
}

fn snapshotServerModelSummary(
    alloc: Allocator,
    server: *const McpServer,
    permission_rules: types.PermissionRuleSet,
    deferred_pending: bool,
) !model_catalog.ServerSummary {
    const name = try alloc.dupe(u8, server.config.name);
    errdefer alloc.free(name);
    const published_connection: health.ConnectionState = switch (server.state) {
        .disconnected => .disconnected,
        .disabled => .disabled,
        .ready => .ready,
        .failed => .failed,
    };
    const transport_running: ?bool = if (server.config.transport == .stdio)
        if (server.dispatcher) |dispatcher| dispatcher.isRunning() else false
    else
        null;
    const connection = health.observedConnection(published_connection, transport_running);
    const deferred_for_ask = deferred_pending and
        startup_admission.decide(
            server.config.enabled,
            server.config.required,
            server.config.workspace_admission,
            .ask_startup,
        ) == .deferred;
    var tool_count: ?usize = null;
    if (connection == .ready and serverCatalogAvailable(server)) {
        var visible_count: usize = 0;
        for (server.tool_catalog.tools.items) |tool| {
            if (permissions.rulesDenyAllTargetsForPermission(
                permission_rules,
                tool.prefixed_name,
            )) continue;
            visible_count += 1;
        }
        tool_count = visible_count;
    }
    return .{
        .name = name,
        .availability = model_catalog.classifyAvailability(
            connection,
            serverAuthenticationState(server),
            deferred_for_ask,
        ),
        .tool_count = tool_count,
    };
}

fn terminalSafeOwned(alloc: Allocator, value: []const u8, limit: usize) ![]u8 {
    const encoded = try text_utils.encodeTerminalSafe(alloc, value, limit);
    return encoded.bytes;
}

fn healthFailureForState(
    alloc: Allocator,
    required: bool,
    connection: health.ConnectionState,
    authentication: health.AuthenticationState,
) !?[]u8 {
    if (required and connection == .disabled) {
        return @as(?[]u8, try alloc.dupe(u8, "Enable this required server or mark it optional."));
    }
    if (authentication == .required) {
        return @as(?[]u8, try alloc.dupe(
            u8,
            "Authentication is required or the saved credentials lack access; run /mcp auth <name> --open and check server permissions.",
        ));
    }
    if (connection == .failed) {
        return @as(?[]u8, try alloc.dupe(u8, "Connection or discovery failed; check the trusted profile configuration and trace logs."));
    }
    return null;
}

fn aggregateCacheFreshness(server: *const McpServer, now_ms: u64) health.CacheFreshness {
    var result: health.CacheFreshness = .unavailable;
    const invalidated = if (server.tool_subscription) |subscription| subscription.hasInvalidation() else false;
    for ([_]?feature_cache.SnapshotMetadata{
        server.tool_catalog.metadata,
        server.resource_catalog.metadata,
        server.resource_template_catalog.metadata,
        server.prompt_catalog.metadata,
    }) |maybe_metadata| {
        const metadata = maybe_metadata orelse continue;
        const current: health.CacheFreshness = switch (feature_cache.effectiveFreshness(metadata, now_ms, invalidated)) {
            .fresh => .fresh,
            .stale => .stale,
            .refreshing => .refreshing,
            .failed_refresh => .failed_refresh,
        };
        if (cacheFreshnessRank(current) > cacheFreshnessRank(result)) result = current;
    }
    return result;
}

fn cacheFreshnessRank(value: health.CacheFreshness) u3 {
    return switch (value) {
        .unavailable => 0,
        .fresh => 1,
        .stale => 2,
        .refreshing => 3,
        .failed_refresh => 4,
    };
}

fn subscriptionHealth(server: *const McpServer) health.SubscriptionState {
    const subscription = server.tool_subscription orelse return health.subscriptionStateFor(.{
        .present = false,
    });
    return health.subscriptionStateFor(.{
        .present = true,
        .unsupported = subscription.isUnsupported(),
        .finished = subscription.isFinished(),
        .requires_acknowledgement = subscription.requiresAcknowledgement(),
        .acknowledged = subscription.isAcknowledged(),
    });
}

fn aggregateRetryAttempt(server: *const McpServer) u8 {
    var attempt = server.restart_attempts;
    for ([_]?feature_cache.SnapshotMetadata{
        server.tool_catalog.metadata,
        server.resource_catalog.metadata,
        server.resource_template_catalog.metadata,
        server.prompt_catalog.metadata,
    }) |metadata| {
        if (metadata) |value| attempt = @max(attempt, value.refresh_attempt);
    }
    return attempt;
}

fn aggregateNextRetry(server: *const McpServer) ?u64 {
    var retry: ?u64 = null;
    for ([_]?feature_cache.SnapshotMetadata{
        server.tool_catalog.metadata,
        server.resource_catalog.metadata,
        server.resource_template_catalog.metadata,
        server.prompt_catalog.metadata,
    }) |metadata| {
        const retry_at_ms = if (metadata) |value| value.retry_at_ms else 0;
        if (retry_at_ms == 0) continue;
        retry = if (retry) |current| @min(current, retry_at_ms) else retry_at_ms;
    }
    return retry;
}

const DetachedTransport = struct {
    dispatcher: ?*stdio_dispatcher.StdioDispatcher,
    legacy_http: ?*legacy_streamable_http.Client,
    legacy_sse: ?*legacy_http_sse.Client,

    fn deinit(self: *DetachedTransport, force_dispatcher_shutdown: bool) void {
        if (self.dispatcher) |dispatcher| {
            if (force_dispatcher_shutdown) {
                dispatcher.deinitForced();
            } else {
                dispatcher.deinit();
            }
        }
        if (self.legacy_http) |client| client.deinit();
        if (self.legacy_sse) |client| client.deinit();
        self.* = undefined;
    }
};

pub const McpServer = struct {
    config: McpServerConfig,
    runtime: ?*McpRuntime = null,
    owner_alloc: ?Allocator = null,
    dispatcher: ?*stdio_dispatcher.StdioDispatcher = null,
    legacy_http: ?*legacy_streamable_http.Client = null,
    legacy_sse: ?*legacy_http_sse.Client = null,
    resolved_headers: []mcp_contract.McpHttpHeader = &.{},
    resolved_authorization: ?[]u8 = null,
    auth_credentials: ?mcp_auth.Credentials = null,
    pending_auth_challenge: ?mcp_auth.Challenge = null,
    env_map: ?EnvMap = null,
    tool_catalog: ToolCatalogSnapshot = .{},
    resource_catalog: ResourceCatalogSnapshot = .{},
    resource_template_catalog: ResourceTemplateCatalogSnapshot = .{},
    prompt_catalog: PromptCatalogSnapshot = .{},
    resource_read_cache: std.ArrayList(ResourceReadCacheEntry) = .empty,
    next_request_id: u64 = 1,
    http_next_request_id: atomic_value.Value(u64) = .init(1),
    next_generation: u64 = 1,
    connection_generation: u64 = 0,
    catalog_generation: u64 = 0,
    restart_attempts: u8 = 0,
    last_recovery_generation: u64 = 0,
    connection_lock: std.Io.RwLock = .init,
    tool_refresh_lock: std.Io.Mutex = .init,
    feature_refresh_lock: std.Io.Mutex = .init,
    catalog_commit_lock: std.Io.Mutex = .init,
    subscription_lifecycle_lock: std.Io.Mutex = .init,
    auth_lock: std.Io.Mutex = .init,
    status_lock: std.Io.Mutex = .init,
    auth_generation: atomic_value.Value(u64) = .init(0),
    auth_logout_in_progress: std.atomic.Value(bool) = .init(false),
    auth_credentials_present: std.atomic.Value(bool) = .init(false),
    auth_challenge_present: std.atomic.Value(bool) = .init(false),
    state: ServerState = .disconnected,
    last_error: ?[]u8 = null,
    instructions: ?[]u8 = null,
    negotiated_server_name: ?[]u8 = null,
    negotiated_server_version: ?[]u8 = null,
    stdio_protocol: StdioProtocol = .unselected,
    negotiated_protocol_version: []const u8 = "",
    last_successful_discovery_ms: ?u64 = null,
    tools_list_changed: bool = false,
    capabilities: ServerCapabilities = .{},
    tool_subscription: ?*tool_subscription.State = null,
    next_subscription_generation: u64 = 1,

    pub fn deinit(self: *McpServer, alloc: Allocator) void {
        self.disconnect();
        freeResolvedHeaders(alloc, self);
        if (self.auth_credentials) |*credentials| credentials.deinit(alloc);
        if (self.pending_auth_challenge) |*challenge| challenge.deinit(alloc);
        self.config.deinit(alloc);
        self.tool_catalog.deinit(alloc);
        self.resource_catalog.deinit(alloc);
        self.resource_template_catalog.deinit(alloc);
        self.prompt_catalog.deinit(alloc);
        for (self.resource_read_cache.items) |*entry| entry.deinit(alloc);
        self.resource_read_cache.deinit(alloc);
        if (self.last_error) |value| alloc.free(value);
        if (self.instructions) |value| alloc.free(value);
        if (self.negotiated_server_name) |value| alloc.free(value);
        if (self.negotiated_server_version) |value| alloc.free(value);
        if (self.env_map) |*map| map.deinit();
    }

    pub fn disconnect(self: *McpServer) void {
        self.stopToolSubscription();
        var detached = self.detachTransport();
        detached.deinit(false);
    }

    fn disconnectForced(self: *McpServer) void {
        self.stopToolSubscription();
        var detached = self.detachTransport();
        detached.deinit(true);
    }

    fn detachTransport(self: *McpServer) DetachedTransport {
        const detached = DetachedTransport{
            .dispatcher = self.dispatcher,
            .legacy_http = self.legacy_http,
            .legacy_sse = self.legacy_sse,
        };
        self.dispatcher = null;
        self.legacy_http = null;
        self.legacy_sse = null;
        self.stdio_protocol = .unselected;
        self.negotiated_protocol_version = "";
        const alloc = if (self.runtime) |runtime| runtime.alloc else self.owner_alloc;
        if (self.negotiated_server_name) |value| alloc.?.free(value);
        self.negotiated_server_name = null;
        if (self.negotiated_server_version) |value| alloc.?.free(value);
        self.negotiated_server_version = null;
        self.tools_list_changed = false;
        self.capabilities = .{};
        self.state = .disconnected;
        return detached;
    }

    fn setFailed(self: *McpServer, alloc: Allocator, msg: []const u8) void {
        self.status_lock.lockUncancelable(io_mod.getIo());
        defer self.status_lock.unlock(io_mod.getIo());
        if (self.last_error) |old| alloc.free(old);
        self.last_error = alloc.dupe(u8, msg) catch null;
        self.state = .failed;
    }

    fn setReady(self: *McpServer, alloc: Allocator) void {
        self.status_lock.lockUncancelable(io_mod.getIo());
        defer self.status_lock.unlock(io_mod.getIo());
        if (self.last_error) |value| alloc.free(value);
        self.last_error = null;
        self.state = .ready;
        self.last_successful_discovery_ms = clockMillis();
    }

    fn stopToolSubscription(self: *McpServer) void {
        const subscription = self.detachToolSubscription();
        if (subscription) |state| state.stopAndDestroy();
    }

    fn detachToolSubscription(self: *McpServer) ?*tool_subscription.State {
        const subscription = self.tool_subscription;
        self.tool_subscription = null;
        if (self.tool_catalog.metadata) |*metadata| metadata.subscription = null;
        if (self.resource_catalog.metadata) |*metadata| metadata.subscription = null;
        if (self.resource_template_catalog.metadata) |*metadata| metadata.subscription = null;
        if (self.prompt_catalog.metadata) |*metadata| metadata.subscription = null;
        return subscription;
    }

    fn signalToolSubscriptionStop(self: *McpServer) void {
        if (self.tool_subscription) |subscription| subscription.requestStop();
    }
};

fn clearServerTools(alloc: Allocator, server: *McpServer) void {
    server.tool_catalog.deinit(alloc);
}

fn freeTools(alloc: Allocator, tools: []const McpTool) void {
    for (tools) |tool| {
        alloc.free(tool.original_name);
        alloc.free(tool.prefixed_name);
        if (tool.title) |value| alloc.free(value);
        alloc.free(tool.description);
        alloc.free(tool.input_schema_json);
        if (tool.output_schema_json) |value| alloc.free(value);
        if (tool.icons_json) |value| alloc.free(value);
        if (tool.annotations_json) |value| alloc.free(value);
        if (tool.metadata_json) |value| alloc.free(value);
        freeOwnedStrings(alloc, tool.tags);
    }
}

const DetachedConnection = struct {
    dispatcher: ?*stdio_dispatcher.StdioDispatcher,
    legacy_http: ?*legacy_streamable_http.Client,
    legacy_sse: ?*legacy_http_sse.Client,
    resolved_headers: []mcp_contract.McpHttpHeader,
    resolved_authorization: ?[]u8,
    env_map: ?EnvMap,
    tool_catalog: ToolCatalogSnapshot,
    resource_catalog: ResourceCatalogSnapshot,
    resource_template_catalog: ResourceTemplateCatalogSnapshot,
    prompt_catalog: PromptCatalogSnapshot,
    resource_read_cache: std.ArrayList(ResourceReadCacheEntry),
    last_error: ?[]u8,
    instructions: ?[]u8,
    negotiated_protocol_version: []const u8,
    negotiated_server_name: ?[]u8,
    negotiated_server_version: ?[]u8,
    last_successful_discovery_ms: ?u64,
    tools_list_changed: bool,
    capabilities: ServerCapabilities,
    tool_subscription: ?*tool_subscription.State,

    fn deinit(self: *DetachedConnection, alloc: Allocator) void {
        self.deinitWithDispatcherMode(alloc, true);
    }

    fn deinitGracefully(self: *DetachedConnection, alloc: Allocator) void {
        self.deinitWithDispatcherMode(alloc, false);
    }

    fn deinitWithDispatcherMode(
        self: *DetachedConnection,
        alloc: Allocator,
        force_dispatcher_shutdown: bool,
    ) void {
        if (self.tool_subscription) |subscription| subscription.stopAndDestroy();
        if (self.dispatcher) |dispatcher| {
            if (force_dispatcher_shutdown) {
                dispatcher.deinitForced();
            } else {
                dispatcher.deinit();
            }
        }
        if (self.legacy_http) |client| client.deinit();
        if (self.legacy_sse) |client| client.deinit();
        if (self.resolved_headers.len > 0) alloc.free(self.resolved_headers);
        if (self.resolved_authorization) |value| {
            @memset(value, 0);
            alloc.free(value);
        }
        self.tool_catalog.deinit(alloc);
        self.resource_catalog.deinit(alloc);
        self.resource_template_catalog.deinit(alloc);
        self.prompt_catalog.deinit(alloc);
        for (self.resource_read_cache.items) |*entry| entry.deinit(alloc);
        self.resource_read_cache.deinit(alloc);
        if (self.last_error) |value| alloc.free(value);
        if (self.instructions) |value| alloc.free(value);
        if (self.negotiated_server_name) |value| alloc.free(value);
        if (self.negotiated_server_version) |value| alloc.free(value);
        if (self.env_map) |*map| map.deinit();
        self.* = undefined;
    }
};

fn detachConnection(server: *McpServer) DetachedConnection {
    const detached = DetachedConnection{
        .dispatcher = server.dispatcher,
        .legacy_http = server.legacy_http,
        .legacy_sse = server.legacy_sse,
        .resolved_headers = server.resolved_headers,
        .resolved_authorization = server.resolved_authorization,
        .env_map = server.env_map,
        .tool_catalog = server.tool_catalog,
        .resource_catalog = server.resource_catalog,
        .resource_template_catalog = server.resource_template_catalog,
        .prompt_catalog = server.prompt_catalog,
        .resource_read_cache = server.resource_read_cache,
        .last_error = server.last_error,
        .instructions = server.instructions,
        .negotiated_protocol_version = server.negotiated_protocol_version,
        .negotiated_server_name = server.negotiated_server_name,
        .negotiated_server_version = server.negotiated_server_version,
        .last_successful_discovery_ms = server.last_successful_discovery_ms,
        .tools_list_changed = server.tools_list_changed,
        .capabilities = server.capabilities,
        .tool_subscription = server.tool_subscription,
    };
    server.dispatcher = null;
    server.legacy_http = null;
    server.legacy_sse = null;
    server.resolved_headers = &.{};
    server.resolved_authorization = null;
    server.env_map = null;
    server.tool_catalog = .{};
    server.resource_catalog = .{};
    server.resource_template_catalog = .{};
    server.prompt_catalog = .{};
    server.resource_read_cache = .empty;
    server.state = .disconnected;
    server.last_error = null;
    server.instructions = null;
    server.stdio_protocol = .unselected;
    server.negotiated_protocol_version = "";
    server.negotiated_server_name = null;
    server.negotiated_server_version = null;
    server.last_successful_discovery_ms = null;
    server.tools_list_changed = false;
    server.capabilities = .{};
    server.tool_subscription = null;
    return detached;
}

fn detachPublishedConnection(server: *McpServer) DetachedConnection {
    if (server.runtime) |runtime| {
        runtime.cancelLegacyUrlWaitersForServer(
            server.config.name,
            server.connection_generation,
        );
    }
    return detachConnection(server);
}

fn detachFailedConnectionPreservingFeatureCaches(server: *McpServer) DetachedConnection {
    const stdio_protocol = server.stdio_protocol;
    var detached = detachPublishedConnection(server);
    server.resource_catalog = detached.resource_catalog;
    detached.resource_catalog = .{};
    server.resource_template_catalog = detached.resource_template_catalog;
    detached.resource_template_catalog = .{};
    server.prompt_catalog = detached.prompt_catalog;
    detached.prompt_catalog = .{};
    server.resource_read_cache = detached.resource_read_cache;
    detached.resource_read_cache = .empty;
    server.stdio_protocol = stdio_protocol;
    server.negotiated_protocol_version = detached.negotiated_protocol_version;
    detached.negotiated_protocol_version = "";
    server.negotiated_server_name = detached.negotiated_server_name;
    detached.negotiated_server_name = null;
    server.negotiated_server_version = detached.negotiated_server_version;
    detached.negotiated_server_version = null;
    server.last_successful_discovery_ms = detached.last_successful_discovery_ms;
    server.capabilities = detached.capabilities;
    return detached;
}

fn publishConnection(server: *McpServer, connected: *McpServer) void {
    std.debug.assert(server.dispatcher == null);
    std.debug.assert(server.legacy_http == null);
    std.debug.assert(server.legacy_sse == null);
    std.debug.assert(server.resolved_headers.len == 0);
    std.debug.assert(server.resolved_authorization == null);
    std.debug.assert(server.last_error == null);
    std.debug.assert(server.instructions == null);
    std.debug.assert(server.env_map == null);

    server.dispatcher = connected.dispatcher;
    connected.dispatcher = null;
    server.legacy_http = connected.legacy_http;
    connected.legacy_http = null;
    server.legacy_sse = connected.legacy_sse;
    connected.legacy_sse = null;
    server.resolved_headers = connected.resolved_headers;
    connected.resolved_headers = &.{};
    server.resolved_authorization = connected.resolved_authorization;
    connected.resolved_authorization = null;
    server.env_map = connected.env_map;
    connected.env_map = null;
    server.tool_catalog = connected.tool_catalog;
    connected.tool_catalog = .{};
    server.resource_catalog = connected.resource_catalog;
    connected.resource_catalog = .{};
    server.resource_template_catalog = connected.resource_template_catalog;
    connected.resource_template_catalog = .{};
    server.prompt_catalog = connected.prompt_catalog;
    connected.prompt_catalog = .{};
    server.resource_read_cache = connected.resource_read_cache;
    connected.resource_read_cache = .empty;
    server.next_request_id = connected.next_request_id;
    server.http_next_request_id.store(
        connected.http_next_request_id.load(.seq_cst),
        .seq_cst,
    );
    server.next_generation = connected.next_generation;
    server.connection_generation = connected.connection_generation;
    server.catalog_generation = connected.catalog_generation;
    server.state = connected.state;
    server.last_error = connected.last_error;
    connected.last_error = null;
    server.instructions = connected.instructions;
    connected.instructions = null;
    server.stdio_protocol = connected.stdio_protocol;
    connected.stdio_protocol = .unselected;
    server.negotiated_protocol_version = connected.negotiated_protocol_version;
    connected.negotiated_protocol_version = "";
    server.negotiated_server_name = connected.negotiated_server_name;
    connected.negotiated_server_name = null;
    server.negotiated_server_version = connected.negotiated_server_version;
    connected.negotiated_server_version = null;
    server.last_successful_discovery_ms = connected.last_successful_discovery_ms;
    server.tools_list_changed = connected.tools_list_changed;
    connected.tools_list_changed = false;
    server.capabilities = connected.capabilities;
    connected.capabilities = .{};
    server.tool_subscription = connected.tool_subscription;
    connected.tool_subscription = null;
    server.next_subscription_generation = connected.next_subscription_generation;
}

fn removeServerToolNames(
    used_tool_names: *std.StringHashMap(void),
    server: *const McpServer,
) void {
    for (server.tool_catalog.tools.items) |tool| {
        _ = used_tool_names.remove(tool.prefixed_name);
    }
}

pub const McpRuntime = struct {
    alloc: Allocator,
    generation: u64,
    legacy_url_runtime_generation: u64 = 0,
    servers: std.ArrayList(McpServer) = .empty,
    workspace_diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty,
    catalog_mutex: std.Io.RwLock = .init,
    recovery_mutex: std.Io.Mutex = .init,
    catalog_update_mutex: std.Io.Mutex = .init,
    lifecycle_mutex: std.Io.Mutex = .init,
    lifecycle_cond: std.Io.Condition = .init,
    active_users: usize = 0,
    retiring: std.atomic.Value(bool) = .init(false),
    tool_registry: tool_dispatch.Registry = .{},
    legacy_elicitation_capabilities: elicitation.Capabilities = .{},
    legacy_url_completion_sink: ?tool_mcp_runtime.LegacyUrlCompletionSink = null,
    legacy_url_waiter_mutex: std.Io.Mutex = .init,
    legacy_url_waiters: std.ArrayList(*LegacyUrlWaiter) = .empty,
    early_legacy_url_completions: std.ArrayList(EarlyLegacyUrlCompletion) = .empty,
    legacy_url_completion_candidates: std.ArrayList(LegacyUrlCompletionCandidate) = .empty,
    legacy_url_completion_windows: std.ArrayList(LegacyUrlCompletionWindow) = .empty,
    next_legacy_url_completion_window_generation: u64 = 1,
    discovery_state: std.atomic.Value(DiscoveryState) = .init(.idle),
    discovery_cancel_requested: std.atomic.Value(bool) = .init(false),
    discovery_thread: ?std.Thread = null,
    deferred_discovery_state: std.atomic.Value(DiscoveryState) = .init(.idle),
    deferred_discovery_complete: std.Io.Event = .unset,

    pub fn init(alloc: Allocator) McpRuntime {
        return .{ .alloc = alloc, .generation = allocateRuntimeGeneration() };
    }

    pub fn initWithElicitation(
        alloc: Allocator,
        capabilities: elicitation.Capabilities,
    ) McpRuntime {
        return .{
            .alloc = alloc,
            .generation = allocateRuntimeGeneration(),
            .legacy_elicitation_capabilities = capabilities,
        };
    }

    pub fn deinit(self: *McpRuntime) void {
        self.discovery_cancel_requested.store(true, .seq_cst);
        self.deferred_discovery_complete.set(io_mod.getIo());
        if (self.discovery_thread) |thread| {
            self.discovery_thread = null;
            thread.join();
        }
        for (self.servers.items) |*server| {
            server.connection_lock.lockSharedUncancelable(io_mod.getIo());
            server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
            server.signalToolSubscriptionStop();
            server.catalog_commit_lock.unlock(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());

            server.subscription_lifecycle_lock.lockUncancelable(io_mod.getIo());
            server.connection_lock.lockUncancelable(io_mod.getIo());
            server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
            self.catalog_mutex.lockUncancelable(io_mod.getIo());
            var detached = detachPublishedConnection(server);
            self.catalog_mutex.unlock(io_mod.getIo());
            server.catalog_commit_lock.unlock(io_mod.getIo());

            detached.deinitGracefully(self.alloc);
            server.deinit(self.alloc);
            server.connection_lock.unlock(io_mod.getIo());
            server.subscription_lifecycle_lock.unlock(io_mod.getIo());
        }
        self.servers.deinit(self.alloc);
        for (self.workspace_diagnostics.items) |*diagnostic| {
            diagnostic.deinit(self.alloc);
        }
        self.workspace_diagnostics.deinit(self.alloc);
        std.debug.assert(self.legacy_url_waiters.items.len == 0);
        self.legacy_url_waiters.deinit(self.alloc);
        for (self.early_legacy_url_completions.items) |*completion| {
            completion.deinit(self.alloc);
        }
        self.early_legacy_url_completions.deinit(self.alloc);
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            candidate.deinit(self.alloc);
        }
        self.legacy_url_completion_candidates.deinit(self.alloc);
        std.debug.assert(self.legacy_url_completion_windows.items.len == 0);
        self.legacy_url_completion_windows.deinit(self.alloc);
    }

    pub fn setLegacyUrlCompletionSink(
        self: *McpRuntime,
        sink: ?tool_mcp_runtime.LegacyUrlCompletionSink,
    ) void {
        if (sink != null and self.legacy_url_runtime_generation == 0) {
            self.legacy_url_runtime_generation = next_legacy_url_runtime_generation.fetchAdd(
                1,
                .monotonic,
            );
            std.debug.assert(self.legacy_url_runtime_generation != 0);
        }
        self.legacy_url_completion_sink = sink;
    }

    pub fn acquireUse(self: *McpRuntime) bool {
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        if (self.retiring.load(.acquire)) {
            self.lifecycle_mutex.unlock(io_mod.getIo());
            return false;
        }
        self.active_users += 1;
        const active_users = self.active_users;
        self.lifecycle_mutex.unlock(io_mod.getIo());
        debug_trace.logf("mcp", "runtime lease acquired active_users={d}", .{active_users});
        return true;
    }

    pub fn releaseUse(self: *McpRuntime) void {
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        std.debug.assert(self.active_users > 0);
        self.active_users -= 1;
        if (self.active_users == 0) self.lifecycle_cond.broadcast(io_mod.getIo());
        const active_users = self.active_users;
        self.lifecycle_mutex.unlock(io_mod.getIo());
        debug_trace.logf("mcp", "runtime lease released active_users={d}", .{active_users});
    }

    /// Prevents new users, publishes cancellation to active interactions, and
    /// waits without holding an app/catalog lock. The owner may deinit/destroy
    /// the runtime after this returns.
    pub fn retireAndWait(self: *McpRuntime) void {
        self.retiring.store(true, .release);
        self.discovery_cancel_requested.store(true, .release);
        self.deferred_discovery_complete.set(io_mod.getIo());
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        self.cancelAllLegacyUrlWaitersLocked();
        self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        for (self.servers.items) |*server| {
            server.connection_lock.lockSharedUncancelable(io_mod.getIo());
            server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
            server.signalToolSubscriptionStop();
            server.catalog_commit_lock.unlock(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());
        }
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        const active_users = self.active_users;
        self.lifecycle_mutex.unlock(io_mod.getIo());
        debug_trace.logf("mcp", "runtime retirement signalled active_users={d}", .{active_users});
        self.lifecycle_mutex.lockUncancelable(io_mod.getIo());
        defer self.lifecycle_mutex.unlock(io_mod.getIo());
        while (self.active_users > 0) {
            self.lifecycle_cond.waitUncancelable(io_mod.getIo(), &self.lifecycle_mutex);
        }
    }

    fn registerLegacyUrlWaiter(self: *McpRuntime, waiter: *LegacyUrlWaiter) !void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        try self.registerLegacyUrlWaiterLocked(waiter);
        self.replayEarlyLegacyUrlCompletionsLocked(waiter);
    }

    fn registerCurrentLegacyUrlWaiter(
        self: *McpRuntime,
        waiter: *LegacyUrlWaiter,
    ) !void {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        const source_state = self.legacyCompletionSourceStateLocked(
            waiter.binding.server_name,
            waiter.binding.runtime_generation,
            waiter.binding.connection_generation,
            waiter.binding.client_generation,
            waiter.binding.auth_generation,
        );
        switch (source_state) {
            .stale => return error.Cancelled,
            .logout_fenced => if (!self.legacyUrlWaiterAdmittedLocked(waiter)) {
                return error.Cancelled;
            },
            .current => {},
        }
        try self.registerLegacyUrlWaiterLocked(waiter);
        if (source_state == .current) {
            self.replayEarlyLegacyUrlCompletionsLocked(waiter);
        } else {
            self.fenceEarlyLegacyUrlCompletionsLocked(waiter);
        }
    }

    fn legacyUrlWaiterAdmittedLocked(
        self: *McpRuntime,
        waiter: *const LegacyUrlWaiter,
    ) bool {
        if (waiter.ids.len == 0) return false;
        for (waiter.ids) |id| {
            var admitted = false;
            for (self.legacy_url_completion_candidates.items) |candidate| {
                if (candidate.status == .handled or
                    !legacyUrlCandidateMatchesWaiterId(candidate, waiter, id)) continue;
                admitted = true;
                break;
            }
            if (!admitted) return false;
        }
        return true;
    }

    fn fenceEarlyLegacyUrlCompletionsLocked(
        self: *McpRuntime,
        waiter: *const LegacyUrlWaiter,
    ) void {
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (candidate.status != .early) continue;
            for (waiter.ids) |id| {
                if (!legacyUrlCandidateMatchesWaiterId(candidate.*, waiter, id)) continue;
                candidate.status = .logout_fenced;
                break;
            }
        }
    }

    fn registerLegacyUrlWaiterLocked(self: *McpRuntime, waiter: *LegacyUrlWaiter) !void {
        if (self.legacy_url_waiters.items.len >= max_pending_legacy_url_waiters) {
            return error.McpInputRequiredLimitExceeded;
        }
        for (self.legacy_url_waiters.items) |pending| {
            if (!std.mem.eql(u8, pending.binding.server_name, waiter.binding.server_name) or
                pending.binding.connection_generation != waiter.binding.connection_generation)
            {
                continue;
            }
            for (pending.ids) |pending_id| for (waiter.ids) |id| {
                if (std.mem.eql(u8, pending_id, id)) return error.McpDuplicateElicitationId;
            };
        }
        try self.legacy_url_waiters.append(self.alloc, waiter);
    }

    fn unregisterLegacyUrlWaiter(self: *McpRuntime, waiter: *LegacyUrlWaiter) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        for (self.legacy_url_waiters.items, 0..) |pending, index| {
            if (pending != waiter) continue;
            _ = self.legacy_url_waiters.swapRemove(index);
            return;
        }
    }

    fn recordLegacyUrlCompletion(
        self: *McpRuntime,
        completion: elicitation.LegacyUrlCompletionIdentity,
    ) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        _ = self.recordLegacyUrlCompletionLocked(completion);
    }

    fn recordLegacyUrlCompletionLocked(
        self: *McpRuntime,
        completion: elicitation.LegacyUrlCompletionIdentity,
    ) bool {
        for (self.legacy_url_waiters.items) |waiter| {
            if (applyLegacyUrlCompletion(waiter, completion)) return true;
        }
        return false;
    }

    fn recordLegacyUrlCompletionFromWire(
        self: *McpRuntime,
        completion: LegacyUrlWireCompletionIdentity,
    ) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        _ = self.recordLegacyUrlCompletionFromWireLocked(completion);
    }

    fn recordLegacyUrlCompletionFromWireLocked(
        self: *McpRuntime,
        completion: LegacyUrlWireCompletionIdentity,
    ) bool {
        for (self.legacy_url_waiters.items) |waiter| {
            if (!legacyUrlWireCompletionTargetsWaiter(waiter, completion)) continue;
            _ = applyLegacyUrlCompletion(waiter, .{
                .server_name = completion.server_name,
                .elicitation_id = completion.elicitation_id,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                // The notification has no catalog generation. The retained
                // originating snapshot is revalidated before retrying.
                .catalog_generation = waiter.binding.catalog_generation,
                .auth_generation = completion.auth_generation,
            });
            return true;
        }
        return false;
    }

    fn pruneEarlyLegacyUrlCompletionsLocked(self: *McpRuntime, now_ms: i64) void {
        var index: usize = 0;
        while (index < self.early_legacy_url_completions.items.len) {
            if (self.early_legacy_url_completions.items[index].deadline_ms >= now_ms) {
                index += 1;
                continue;
            }
            var expired = self.early_legacy_url_completions.swapRemove(index);
            debug_trace.logf(
                "mcp",
                "dropped early legacy URL completion server={s} elicitation_id={s} reason=expired",
                .{ expired.server_name, expired.elicitation_id },
            );
            expired.deinit(self.alloc);
        }
    }

    fn legacyUrlCompletionWindowMatches(
        window: LegacyUrlCompletionWindow,
        completion: LegacyUrlWireCompletionIdentity,
    ) bool {
        return window.runtime_generation == completion.runtime_generation and
            window.source.connection_generation == completion.connection_generation and
            window.source.client_generation == completion.client_generation and
            window.source.auth_generation == completion.auth_generation and
            std.mem.eql(u8, window.source.server_name, completion.server_name);
    }

    fn beginLegacyUrlCompletionWindow(
        self: *McpRuntime,
        source: tool_subscription.NotificationSource,
        runtime_generation: u64,
    ) !u64 {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        if (!self.legacyCompletionSourceCurrentLocked(
            source.server_name,
            runtime_generation,
            source.connection_generation,
            source.client_generation,
            source.auth_generation,
        )) return error.Cancelled;
        if (self.legacy_url_completion_windows.items.len >= max_legacy_url_completion_windows) {
            return error.McpInputRequiredLimitExceeded;
        }
        const generation = self.next_legacy_url_completion_window_generation;
        self.next_legacy_url_completion_window_generation = std.math.add(
            u64,
            generation,
            1,
        ) catch return error.McpRequestIdExhausted;
        try self.legacy_url_completion_windows.append(self.alloc, .{
            .source = source,
            .runtime_generation = runtime_generation,
            .generation = generation,
        });
        return generation;
    }

    fn endLegacyUrlCompletionWindow(
        self: *McpRuntime,
        source: tool_subscription.NotificationSource,
        runtime_generation: u64,
        window_generation: u64,
    ) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        for (self.legacy_url_completion_windows.items, 0..) |window, index| {
            if (window.generation != window_generation or
                window.runtime_generation != runtime_generation or
                window.source.connection_generation != source.connection_generation or
                window.source.client_generation != source.client_generation or
                window.source.auth_generation != source.auth_generation or
                !std.mem.eql(u8, window.source.server_name, source.server_name)) continue;
            _ = self.legacy_url_completion_windows.swapRemove(index);
            self.dropUnverifiedLegacyUrlCompletionsLocked(window_generation);
            return;
        }
        std.debug.assert(false);
    }

    fn dropUnverifiedLegacyUrlCompletionsLocked(
        self: *McpRuntime,
        window_generation: u64,
    ) void {
        var index: usize = 0;
        while (index < self.early_legacy_url_completions.items.len) {
            const pending = &self.early_legacy_url_completions.items[index];
            if (pending.window_generation != window_generation) {
                index += 1;
                continue;
            }
            var dropped = self.early_legacy_url_completions.swapRemove(index);
            debug_trace.logf(
                "mcp",
                "ignored unmatched legacy URL completion server={s} elicitation_id={s} reason=no_candidate",
                .{ dropped.server_name, dropped.elicitation_id },
            );
            dropped.deinit(self.alloc);
        }
    }

    fn journalEarlyLegacyUrlCompletionLocked(
        self: *McpRuntime,
        completion: LegacyUrlWireCompletionIdentity,
        logout_fenced: bool,
    ) void {
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (!legacyUrlCandidateMatchesWire(candidate.*, completion)) continue;
            if (candidate.status == .issued) {
                candidate.status = if (logout_fenced) .logout_fenced else .early;
            }
            return;
        }
        var matched_window = false;
        const now_ms = awakeMillis();
        self.pruneEarlyLegacyUrlCompletionsLocked(now_ms);
        for (self.legacy_url_completion_windows.items) |window| {
            if (!legacyUrlCompletionWindowMatches(window, completion)) continue;
            matched_window = true;
            var already_recorded = false;
            var window_entries: usize = 0;
            var window_eviction_index: ?usize = null;
            for (self.early_legacy_url_completions.items, 0..) |pending, index| {
                if (pending.window_generation == window.generation) {
                    window_entries += 1;
                    if (window_eviction_index == null) window_eviction_index = index;
                }
                if (pending.window_generation == window.generation and
                    pending.runtime_generation == completion.runtime_generation and
                    pending.connection_generation == completion.connection_generation and
                    pending.client_generation == completion.client_generation and
                    pending.auth_generation == completion.auth_generation and
                    std.mem.eql(u8, pending.server_name, completion.server_name) and
                    std.mem.eql(u8, pending.elicitation_id, completion.elicitation_id))
                {
                    already_recorded = true;
                    break;
                }
            }
            if (already_recorded) continue;
            if (window_entries >= max_early_legacy_url_completions_per_window) {
                var evicted = self.early_legacy_url_completions.swapRemove(
                    window_eviction_index.?,
                );
                debug_trace.logf(
                    "mcp",
                    "dropped early legacy URL completion server={s} elicitation_id={s} reason=capacity",
                    .{ evicted.server_name, evicted.elicitation_id },
                );
                evicted.deinit(self.alloc);
            }
            const server_name = self.alloc.dupe(u8, completion.server_name) catch {
                debug_trace.logf(
                    "mcp",
                    "dropped early legacy URL completion server={s} elicitation_id={s} reason=allocation",
                    .{ completion.server_name, completion.elicitation_id },
                );
                return;
            };
            const elicitation_id = self.alloc.dupe(u8, completion.elicitation_id) catch {
                self.alloc.free(server_name);
                debug_trace.logf(
                    "mcp",
                    "dropped early legacy URL completion server={s} elicitation_id={s} reason=allocation",
                    .{ completion.server_name, completion.elicitation_id },
                );
                return;
            };
            self.early_legacy_url_completions.append(self.alloc, .{
                .server_name = server_name,
                .elicitation_id = elicitation_id,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                .auth_generation = completion.auth_generation,
                .window_generation = window.generation,
                .deadline_ms = std.math.add(
                    i64,
                    now_ms,
                    early_legacy_url_completion_ttl_ms,
                ) catch std.math.maxInt(i64),
                .logout_fenced = logout_fenced,
            }) catch {
                self.alloc.free(server_name);
                self.alloc.free(elicitation_id);
                debug_trace.logf(
                    "mcp",
                    "dropped early legacy URL completion server={s} elicitation_id={s} reason=allocation",
                    .{ completion.server_name, completion.elicitation_id },
                );
                return;
            };
        }
        if (!matched_window) {
            debug_trace.logf(
                "mcp",
                "ignored unknown legacy URL completion server={s} elicitation_id={s}",
                .{ completion.server_name, completion.elicitation_id },
            );
        }
    }

    fn earlyLegacyUrlCompletionRecordedLocked(
        self: *McpRuntime,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
    ) bool {
        for (self.legacy_url_completion_candidates.items) |candidate| {
            if ((candidate.status == .early or candidate.status == .logout_fenced) and
                candidate.runtime_generation == origin.runtime_generation and
                candidate.connection_generation == origin.connection_generation and
                candidate.client_generation == origin.client_generation and
                candidate.auth_generation == origin.auth_generation and
                std.mem.eql(u8, candidate.server_name, origin.server_name) and
                std.mem.eql(u8, candidate.elicitation_id, elicitation_id)) return true;
        }
        return false;
    }

    fn registerLegacyUrlCompletionCandidates(
        self: *McpRuntime,
        source: tool_subscription.NotificationSource,
        runtime_generation: u64,
        window_generation: ?u64,
        ids: []const []const u8,
    ) !void {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        const source_state = self.legacyCompletionSourceStateLocked(
            source.server_name,
            runtime_generation,
            source.connection_generation,
            source.client_generation,
            source.auth_generation,
        );
        if (source_state == .stale or
            (source_state == .logout_fenced and window_generation == null))
        {
            return error.Cancelled;
        }
        if (window_generation) |generation| {
            var window_current = false;
            for (self.legacy_url_completion_windows.items) |window| {
                if (window.generation == generation and
                    window.runtime_generation == runtime_generation and
                    window.source.connection_generation == source.connection_generation and
                    window.source.client_generation == source.client_generation and
                    window.source.auth_generation == source.auth_generation and
                    std.mem.eql(u8, window.source.server_name, source.server_name))
                {
                    window_current = true;
                    break;
                }
            }
            if (!window_current) return error.Cancelled;
        }
        for (ids, 0..) |id, index| {
            for (ids[0..index]) |previous| {
                if (std.mem.eql(u8, id, previous)) return error.McpDuplicateElicitationId;
            }
            for (self.legacy_url_completion_candidates.items) |candidate| {
                if (candidate.runtime_generation == runtime_generation and
                    candidate.connection_generation == source.connection_generation and
                    candidate.client_generation == source.client_generation and
                    candidate.auth_generation == source.auth_generation and
                    std.mem.eql(u8, candidate.server_name, source.server_name) and
                    std.mem.eql(u8, candidate.elicitation_id, id))
                {
                    return error.McpDuplicateElicitationId;
                }
            }
        }
        if (ids.len > max_legacy_url_completion_candidates -|
            self.legacy_url_completion_candidates.items.len)
        {
            return error.McpInputRequiredLimitExceeded;
        }
        const original_len = self.legacy_url_completion_candidates.items.len;
        errdefer while (self.legacy_url_completion_candidates.items.len > original_len) {
            var candidate = self.legacy_url_completion_candidates.pop().?;
            candidate.deinit(self.alloc);
        };
        for (ids) |id| {
            const server_name = try self.alloc.dupe(u8, source.server_name);
            errdefer self.alloc.free(server_name);
            const owned_id = try self.alloc.dupe(u8, id);
            errdefer self.alloc.free(owned_id);
            try self.legacy_url_completion_candidates.append(self.alloc, .{
                .server_name = server_name,
                .elicitation_id = owned_id,
                .runtime_generation = runtime_generation,
                .connection_generation = source.connection_generation,
                .client_generation = source.client_generation,
                .auth_generation = source.auth_generation,
            });
        }
        self.pruneEarlyLegacyUrlCompletionsLocked(awakeMillis());
        var pending_index: usize = 0;
        while (pending_index < self.early_legacy_url_completions.items.len) {
            const pending = &self.early_legacy_url_completions.items[pending_index];
            if (window_generation == null or
                pending.window_generation != window_generation.?)
            {
                pending_index += 1;
                continue;
            }
            var candidate_index: ?usize = null;
            for (self.legacy_url_completion_candidates.items[original_len..], original_len..) |candidate, index| {
                if (legacyUrlCandidateMatchesWire(candidate, .{
                    .server_name = pending.server_name,
                    .elicitation_id = pending.elicitation_id,
                    .runtime_generation = pending.runtime_generation,
                    .connection_generation = pending.connection_generation,
                    .client_generation = pending.client_generation,
                    .auth_generation = pending.auth_generation,
                })) {
                    candidate_index = index;
                    break;
                }
            }
            const matched_index = candidate_index orelse {
                pending_index += 1;
                continue;
            };
            self.legacy_url_completion_candidates.items[matched_index].status =
                if (pending.logout_fenced) .logout_fenced else .early;
            var matched = self.early_legacy_url_completions.swapRemove(pending_index);
            matched.deinit(self.alloc);
        }
    }

    fn markWireLegacyUrlCompletionHandledLocked(
        self: *McpRuntime,
        completion: LegacyUrlWireCompletionIdentity,
    ) void {
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (!legacyUrlCandidateMatchesWire(candidate.*, completion)) continue;
            candidate.status = .handled;
            return;
        }
    }

    fn markLegacyUrlCompletionHandledLocked(
        self: *McpRuntime,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
    ) void {
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (candidate.runtime_generation != origin.runtime_generation or
                candidate.connection_generation != origin.connection_generation or
                candidate.client_generation != origin.client_generation or
                candidate.auth_generation != origin.auth_generation or
                !std.mem.eql(u8, candidate.server_name, origin.server_name) or
                !std.mem.eql(u8, candidate.elicitation_id, elicitation_id)) continue;
            candidate.status = .handled;
            return;
        }
    }

    fn replayEarlyLegacyUrlCompletionsLocked(
        self: *McpRuntime,
        waiter: *LegacyUrlWaiter,
    ) void {
        var index: usize = 0;
        while (index < self.legacy_url_completion_candidates.items.len) {
            const candidate = &self.legacy_url_completion_candidates.items[index];
            if ((candidate.status != .early and candidate.status != .logout_fenced) or
                candidate.runtime_generation != waiter.binding.runtime_generation or
                candidate.connection_generation != waiter.binding.connection_generation or
                candidate.client_generation != waiter.binding.client_generation or
                candidate.auth_generation != waiter.binding.auth_generation or
                !std.mem.eql(u8, candidate.server_name, waiter.binding.server_name))
            {
                index += 1;
                continue;
            }
            var id_matches = false;
            for (waiter.ids) |id| {
                if (std.mem.eql(u8, id, candidate.elicitation_id)) {
                    id_matches = true;
                    break;
                }
            }
            if (!id_matches) {
                index += 1;
                continue;
            }
            _ = applyLegacyUrlCompletion(waiter, .{
                .server_name = candidate.server_name,
                .elicitation_id = candidate.elicitation_id,
                .runtime_generation = candidate.runtime_generation,
                .connection_generation = candidate.connection_generation,
                .client_generation = candidate.client_generation,
                .catalog_generation = waiter.binding.catalog_generation,
                .auth_generation = candidate.auth_generation,
            });
            candidate.status = .handled;
            index += 1;
        }
    }

    pub fn legacyUrlCompletionRecorded(
        self: *McpRuntime,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
    ) bool {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        return self.legacyUrlCompletionRecordedLocked(origin, elicitation_id);
    }

    fn legacyUrlCompletionRecordedLocked(
        self: *McpRuntime,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
    ) bool {
        for (self.legacy_url_waiters.items) |waiter| {
            if (waiter.signal.status.load(.acquire) == .cancelled) continue;
            if (!std.mem.eql(u8, waiter.binding.server_name, origin.server_name) or
                waiter.binding.runtime_generation != origin.runtime_generation or
                waiter.binding.connection_generation != origin.connection_generation or
                waiter.binding.client_generation != origin.client_generation or
                waiter.binding.catalog_generation != origin.catalog_generation or
                waiter.binding.auth_generation != origin.auth_generation)
            {
                continue;
            }
            for (waiter.ids, waiter.completed) |id, completed| {
                if (completed and std.mem.eql(u8, id, elicitation_id)) return true;
            }
        }
        return false;
    }

    fn legacyCompletionSourceCurrentLocked(
        self: *McpRuntime,
        server_name: []const u8,
        runtime_generation: u64,
        connection_generation: u64,
        client_generation: u64,
        auth_generation: u64,
    ) bool {
        return self.legacyCompletionSourceStateLocked(
            server_name,
            runtime_generation,
            connection_generation,
            client_generation,
            auth_generation,
        ) == .current;
    }

    const LegacyCompletionSourceState = enum {
        current,
        logout_fenced,
        stale,
    };

    fn legacyCompletionSourceStateLocked(
        self: *McpRuntime,
        server_name: []const u8,
        runtime_generation: u64,
        connection_generation: u64,
        client_generation: u64,
        auth_generation: u64,
    ) LegacyCompletionSourceState {
        if (self.isDiscovering() or
            self.retiring.load(.acquire) or
            self.legacy_url_runtime_generation != runtime_generation) return .stale;
        const server = self.findServer(server_name) orelse return .stale;
        if (server.state != .ready or
            server.connection_generation != connection_generation or
            server.auth_generation.load(.acquire) != auth_generation)
        {
            return .stale;
        }
        const current_client_generation = if (server.dispatcher) |dispatcher|
            dispatcher.connectionGeneration()
        else
            server.connection_generation;
        if (current_client_generation != client_generation) return .stale;
        return if (server.auth_logout_in_progress.load(.acquire))
            .logout_fenced
        else
            .current;
    }

    fn replayLogoutFencedLegacyUrlCompletions(
        self: *McpRuntime,
        server_name: []const u8,
    ) void {
        while (true) switch (self.replayLogoutFencedLegacyUrlCompletionStep(server_name)) {
            .done => return,
            .progressed => {},
            .publication => |publication| {
                publication.sink.publish(publication.sink.context, publication.id);
            },
        };
    }

    fn replayLogoutFencedLegacyUrlCompletionStep(
        self: *McpRuntime,
        server_name: []const u8,
    ) LegacyUrlCompletionReplayStep {
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            if (candidate.status != .logout_fenced or
                !std.mem.eql(u8, candidate.server_name, server_name) or
                !self.legacyCompletionSourceCurrentLocked(
                    candidate.server_name,
                    candidate.runtime_generation,
                    candidate.connection_generation,
                    candidate.client_generation,
                    candidate.auth_generation,
                ))
            {
                continue;
            }
            const completion = LegacyUrlWireCompletionIdentity{
                .server_name = candidate.server_name,
                .elicitation_id = candidate.elicitation_id,
                .runtime_generation = candidate.runtime_generation,
                .connection_generation = candidate.connection_generation,
                .client_generation = candidate.client_generation,
                .auth_generation = candidate.auth_generation,
            };
            const recorded = self.recordLegacyUrlCompletionFromWireLocked(completion);
            if (recorded) candidate.status = .handled;
            const sink = self.legacy_url_completion_sink orelse {
                if (recorded) return .progressed;
                continue;
            };
            switch (sink.consume(sink.context, .{
                .server_name = completion.server_name,
                .elicitation_id = completion.elicitation_id,
                .runtime_generation = completion.runtime_generation,
                .connection_generation = completion.connection_generation,
                .client_generation = completion.client_generation,
                .auth_generation = completion.auth_generation,
            })) {
                .missing => if (recorded) return .progressed,
                .consumed => |maybe_id| {
                    if (!recorded) candidate.status = .handled;
                    if (maybe_id) |id| {
                        return .{ .publication = .{ .sink = sink, .id = id } };
                    }
                    return .progressed;
                },
            }
        }
        return .done;
    }

    pub fn reconcileLegacyUrlCompletion(
        self: *McpRuntime,
        origin: tool_mcp_runtime.InputOrigin,
        elicitation_id: []const u8,
        sink: tool_mcp_runtime.LegacyUrlCompletionSink,
    ) void {
        const publication = publication: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
            defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
            if (!self.legacyCompletionSourceCurrentLocked(
                origin.server_name,
                origin.runtime_generation,
                origin.connection_generation,
                origin.client_generation,
                origin.auth_generation,
            )) break :publication null;
            if (!self.legacyUrlCompletionRecordedLocked(origin, elicitation_id) and
                !self.earlyLegacyUrlCompletionRecordedLocked(origin, elicitation_id))
            {
                break :publication null;
            }
            const consumed = sink.consume(sink.context, .{
                .server_name = origin.server_name,
                .elicitation_id = elicitation_id,
                .runtime_generation = origin.runtime_generation,
                .connection_generation = origin.connection_generation,
                .client_generation = origin.client_generation,
                .auth_generation = origin.auth_generation,
            });
            break :publication switch (consumed) {
                .missing => null,
                .consumed => |id| consumed: {
                    self.markLegacyUrlCompletionHandledLocked(origin, elicitation_id);
                    break :consumed id;
                },
            };
        };
        if (publication) |id| sink.publish(sink.context, id);
    }

    pub fn acceptLegacyUrlCompletion(
        self: *McpRuntime,
        origin: tool_mcp_runtime.InputOrigin,
        acp_id: []const u8,
        sink: tool_mcp_runtime.LegacyUrlCompletionSink,
    ) ?tool_mcp_runtime.LegacyUrlAcceptStatus {
        const accepted = accepted: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
            defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
            if (!self.legacyCompletionSourceCurrentLocked(
                origin.server_name,
                origin.runtime_generation,
                origin.connection_generation,
                origin.client_generation,
                origin.auth_generation,
            )) break :accepted tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
            const server = self.findServer(origin.server_name) orelse
                break :accepted tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
            if (server.catalog_generation != origin.catalog_generation) {
                break :accepted tool_mcp_runtime.LegacyUrlAcceptTransition.missing;
            }
            break :accepted sink.accept(sink.context, origin, acp_id);
        };
        return switch (accepted) {
            .missing => null,
            .awaiting_completion => .awaiting_completion,
            .completed => |id| completed: {
                sink.publish(sink.context, id);
                break :completed .completed;
            },
        };
    }

    fn cancelLegacyUrlWaitersForServer(
        self: *McpRuntime,
        server_name: []const u8,
        connection_generation: u64,
    ) void {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        self.cancelLegacyUrlWaitersForServerLocked(server_name, connection_generation);
    }

    fn cancelLegacyUrlWaitersForServerLocked(
        self: *McpRuntime,
        server_name: []const u8,
        connection_generation: u64,
    ) void {
        for (self.legacy_url_waiters.items) |waiter| {
            if (!std.mem.eql(u8, waiter.binding.server_name, server_name) or
                waiter.binding.connection_generation != connection_generation)
            {
                continue;
            }
            waiter.signal.status.store(.cancelled, .release);
            waiter.signal.wake.store(true, .release);
        }
        var index: usize = 0;
        while (index < self.early_legacy_url_completions.items.len) {
            const pending = &self.early_legacy_url_completions.items[index];
            if (!std.mem.eql(u8, pending.server_name, server_name) or
                pending.connection_generation != connection_generation)
            {
                index += 1;
                continue;
            }
            var removed = self.early_legacy_url_completions.swapRemove(index);
            debug_trace.logf(
                "mcp",
                "dropped early legacy URL completion server={s} elicitation_id={s} reason=source_invalidated",
                .{ removed.server_name, removed.elicitation_id },
            );
            removed.deinit(self.alloc);
        }
        index = 0;
        while (index < self.legacy_url_completion_candidates.items.len) {
            const candidate = &self.legacy_url_completion_candidates.items[index];
            if (!std.mem.eql(u8, candidate.server_name, server_name) or
                candidate.connection_generation != connection_generation)
            {
                index += 1;
                continue;
            }
            var removed = self.legacy_url_completion_candidates.swapRemove(index);
            debug_trace.logf(
                "mcp",
                "dropped legacy URL completion candidate server={s} elicitation_id={s} reason=source_invalidated",
                .{ removed.server_name, removed.elicitation_id },
            );
            removed.deinit(self.alloc);
        }
    }

    fn cancelAllLegacyUrlWaitersLocked(self: *McpRuntime) void {
        for (self.legacy_url_waiters.items) |waiter| {
            waiter.signal.status.store(.cancelled, .release);
            waiter.signal.wake.store(true, .release);
        }
        for (self.early_legacy_url_completions.items) |*completion| {
            debug_trace.logf(
                "mcp",
                "dropped early legacy URL completion server={s} elicitation_id={s} reason=runtime_retired",
                .{ completion.server_name, completion.elicitation_id },
            );
            completion.deinit(self.alloc);
        }
        self.early_legacy_url_completions.clearRetainingCapacity();
        for (self.legacy_url_completion_candidates.items) |*candidate| {
            debug_trace.logf(
                "mcp",
                "dropped legacy URL completion candidate server={s} elicitation_id={s} reason=runtime_retired",
                .{ candidate.server_name, candidate.elicitation_id },
            );
            candidate.deinit(self.alloc);
        }
        self.legacy_url_completion_candidates.clearRetainingCapacity();
    }

    pub fn addServer(
        self: *McpRuntime,
        config: McpServerConfig,
    ) (Allocator.Error || error{ McpConfigScopeMismatch, McpConfigAdmissionMismatch })!void {
        if (!mcp_contract.sourceAllowsScope(config.source, config.scope)) {
            return error.McpConfigScopeMismatch;
        }
        if (!mcp_contract.sourceAllowsWorkspaceAdmission(
            config.source,
            config.workspace_admission,
        )) {
            return error.McpConfigAdmissionMismatch;
        }
        try self.servers.append(self.alloc, .{ .config = config, .runtime = self, .owner_alloc = self.alloc });
    }

    pub fn workspaceAuthorityReducedAgainst(
        self: *const McpRuntime,
        next: *const McpRuntime,
        phase: startup_admission.Phase,
    ) bool {
        for (self.servers.items) |current| {
            if (current.config.source != .workspace or
                startup_admission.decide(
                    current.config.enabled,
                    current.config.required,
                    current.config.workspace_admission,
                    phase,
                ) != .connect) continue;
            var retained = false;
            for (next.servers.items) |candidate| {
                if (candidate.config.source != .workspace or
                    !std.mem.eql(u8, current.config.name, candidate.config.name)) continue;
                retained = startup_admission.decide(
                    candidate.config.enabled,
                    candidate.config.required,
                    candidate.config.workspace_admission,
                    phase,
                ) == .connect;
                if (retained) break;
            }
            if (!retained) return true;
        }
        return false;
    }

    pub fn workspaceAuthorityReducedAgainstConfigs(
        self: *const McpRuntime,
        next: []const McpServerConfig,
        phase: startup_admission.Phase,
    ) bool {
        for (self.servers.items) |current| {
            if (!project_config.configRetainsWorkspaceAuthority(
                current.config,
                next,
                phase,
            )) return true;
        }
        return false;
    }

    pub fn workspaceAuthorityReducedAgainstNames(
        self: *const McpRuntime,
        next_names: []const []const u8,
        phase: startup_admission.Phase,
    ) bool {
        for (self.servers.items) |current| {
            if (current.config.source != .workspace or
                startup_admission.decide(
                    current.config.enabled,
                    current.config.required,
                    current.config.workspace_admission,
                    phase,
                ) != .connect) continue;
            var retained = false;
            for (next_names) |name| {
                if (std.mem.eql(u8, current.config.name, name)) {
                    retained = true;
                    break;
                }
            }
            if (!retained) return true;
        }
        return false;
    }

    pub fn pendingWorkspaceNames(
        self: *const McpRuntime,
        alloc: Allocator,
    ) ![][]u8 {
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        for (self.servers.items) |server| {
            if (!server.config.enabled or
                server.config.source != .workspace or
                server.config.workspace_admission != .pending) continue;
            const owned_name = try terminalSafeOwned(alloc, server.config.name, 256);
            errdefer alloc.free(owned_name);
            try names.append(alloc, owned_name);
        }
        return names.toOwnedSlice(alloc);
    }

    pub fn firstPendingWorkspaceName(
        self: *const McpRuntime,
        alloc: Allocator,
    ) !?[]u8 {
        for (self.servers.items) |server| {
            if (!server.config.enabled or
                server.config.source != .workspace or
                server.config.workspace_admission != .pending) continue;
            return @as(?[]u8, try alloc.dupe(u8, server.config.name));
        }
        return null;
    }

    pub fn hasPendingWorkspace(self: *const McpRuntime) bool {
        for (self.servers.items) |server| {
            if (server.config.enabled and
                server.config.source == .workspace and
                server.config.workspace_admission == .pending) return true;
        }
        return false;
    }

    pub fn takeWorkspaceDiagnostics(
        self: *McpRuntime,
        diagnostics: *std.ArrayList(project_config.WorkspaceDiagnostic),
    ) !void {
        try self.workspace_diagnostics.ensureUnusedCapacity(
            self.alloc,
            diagnostics.items.len,
        );
        self.workspace_diagnostics.appendSliceAssumeCapacity(diagnostics.items);
        diagnostics.clearRetainingCapacity();
    }

    pub fn waitForDiscovery(
        self: *McpRuntime,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !void {
        while (self.isDiscovering()) {
            if (cancel_flag) |flag| {
                if (flag.load(.acquire)) return error.Cancelled;
            }
            if (self.retiring.load(.acquire)) return error.McpRuntimeUnavailable;
            try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
        }
    }

    pub fn snapshotHealth(
        self: *McpRuntime,
        alloc: Allocator,
        captured_at_ms: u64,
    ) !health.Snapshot {
        const items = try alloc.alloc(health.ServerSnapshot, self.servers.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |*item| item.deinit(alloc);
            alloc.free(items);
        }
        const discovery_state = self.discovery_state.load(.seq_cst);
        for (self.servers.items, 0..) |*server, index| {
            if (discovery_state != .complete) {
                items[index] = try snapshotServerHealthBeforeDiscoveryPublication(
                    alloc,
                    self.generation,
                    server,
                    discovery_state == .loading,
                );
                initialized += 1;
                continue;
            }
            server.connection_lock.lockSharedUncancelable(io_mod.getIo());
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            server.status_lock.lockUncancelable(io_mod.getIo());
            items[index] = snapshotServerHealth(
                alloc,
                self.generation,
                server,
                captured_at_ms,
            ) catch |err| {
                server.status_lock.unlock(io_mod.getIo());
                self.catalog_mutex.unlockShared(io_mod.getIo());
                server.connection_lock.unlockShared(io_mod.getIo());
                return err;
            };
            server.status_lock.unlock(io_mod.getIo());
            self.catalog_mutex.unlockShared(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());
            initialized += 1;
        }
        const configuration_issues = try alloc.alloc(
            health.ConfigurationIssue,
            self.workspace_diagnostics.items.len,
        );
        var issues_initialized: usize = 0;
        errdefer {
            for (configuration_issues[0..issues_initialized]) |*issue| issue.deinit(alloc);
            alloc.free(configuration_issues);
        }
        for (self.workspace_diagnostics.items, 0..) |diagnostic, index| {
            configuration_issues[index] = .{
                .message = try project_config.renderWorkspaceDiagnostic(
                    alloc,
                    diagnostic,
                ),
            };
            issues_initialized += 1;
        }
        return .{
            .captured_at_ms = captured_at_ms,
            .servers = items,
            .configuration_issues = configuration_issues,
        };
    }

    /// Returns an owned model-safe catalog snapshot. The caller releases it with `deinit`.
    pub fn snapshotModelCatalog(
        self: *McpRuntime,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
        include_ask_deferred: bool,
    ) !model_catalog.Snapshot {
        const servers = try alloc.alloc(model_catalog.ServerSummary, self.servers.items.len);
        var initialized: usize = 0;
        errdefer {
            for (servers[0..initialized]) |server| alloc.free(server.name);
            alloc.free(servers);
        }

        const discovery_state = self.discovery_state.load(.acquire);
        const deferred_pending = include_ask_deferred and
            self.deferred_discovery_state.load(.acquire) != .complete;
        for (self.servers.items, 0..) |*server, index| {
            if (discovery_state != .complete) {
                const connection: health.ConnectionState = if (!server.config.enabled)
                    .disabled
                else if (discovery_state == .loading)
                    .connecting
                else
                    .disconnected;
                servers[index] = .{
                    .name = try alloc.dupe(u8, server.config.name),
                    .availability = model_catalog.classifyAvailability(
                        connection,
                        configuredAuthenticationState(server),
                        false,
                    ),
                };
                initialized += 1;
                continue;
            }

            server.connection_lock.lockSharedUncancelable(io_mod.getIo());
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            server.status_lock.lockUncancelable(io_mod.getIo());
            servers[index] = snapshotServerModelSummary(
                alloc,
                server,
                permission_rules,
                deferred_pending,
            ) catch |err| {
                server.status_lock.unlock(io_mod.getIo());
                self.catalog_mutex.unlockShared(io_mod.getIo());
                server.connection_lock.unlockShared(io_mod.getIo());
                return err;
            };
            server.status_lock.unlock(io_mod.getIo());
            self.catalog_mutex.unlockShared(io_mod.getIo());
            server.connection_lock.unlockShared(io_mod.getIo());
            initialized += 1;
        }
        return .{ .servers = servers };
    }

    pub fn requiredStartupFailure(
        self: *McpRuntime,
        alloc: Allocator,
        captured_at_ms: u64,
    ) !?[]u8 {
        var snapshot = try self.snapshotHealth(alloc, captured_at_ms);
        defer snapshot.deinit(alloc);
        if (health.startupDecision(snapshot.servers) != .blocked) return null;
        for (snapshot.servers) |server| {
            if (!server.required or server.connection == .ready) continue;
            const message = try std.fmt.allocPrint(
                alloc,
                "Required MCP server '{s}' failed to start: {s}",
                .{
                    server.configured_name,
                    server.failure orelse "Check the trusted profile configuration and retry.",
                },
            );
            return message;
        }
        const fallback = try alloc.dupe(u8, "A required MCP server is unavailable.");
        return fallback;
    }

    pub fn startupDecision(
        self: *McpRuntime,
        alloc: Allocator,
        captured_at_ms: u64,
    ) !health.StartupDecision {
        var snapshot = try self.snapshotHealth(alloc, captured_at_ms);
        defer snapshot.deinit(alloc);
        return health.startupDecision(snapshot.servers);
    }

    pub const ServerDiagnostic = struct {
        name: []u8,
        command: []u8,
        state: ServerState,
        tool_count: usize,
        last_error: ?[]u8,

        fn deinit(self: *ServerDiagnostic, alloc: Allocator) void {
            alloc.free(self.name);
            alloc.free(self.command);
            if (self.last_error) |value| alloc.free(value);
            self.* = undefined;
        }
    };

    pub const ServerDiagnostics = struct {
        items: []ServerDiagnostic,

        pub fn deinit(self: *ServerDiagnostics, alloc: Allocator) void {
            for (self.items) |*item| item.deinit(alloc);
            alloc.free(self.items);
            self.* = undefined;
        }
    };

    pub fn snapshotServerDiagnostics(
        self: *McpRuntime,
        alloc: Allocator,
    ) !ServerDiagnostics {
        if (self.isDiscovering()) return error.McpDiscoveryInProgress;
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());

        const items = try alloc.alloc(ServerDiagnostic, self.servers.items.len);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |*item| item.deinit(alloc);
            alloc.free(items);
        }
        for (self.servers.items, 0..) |*server, index| {
            const name = try alloc.dupe(u8, server.config.name);
            errdefer alloc.free(name);
            const command = try alloc.dupe(u8, server.config.command orelse "");
            errdefer alloc.free(command);
            server.status_lock.lockUncancelable(io_mod.getIo());
            const state = server.state;
            const last_error = if (server.last_error) |value|
                alloc.dupe(u8, value) catch |err| {
                    server.status_lock.unlock(io_mod.getIo());
                    return err;
                }
            else
                null;
            server.status_lock.unlock(io_mod.getIo());
            items[index] = .{
                .name = name,
                .command = command,
                .state = state,
                .tool_count = if (serverCatalogAvailable(server))
                    server.tool_catalog.tools.items.len
                else
                    0,
                .last_error = last_error,
            };
            initialized += 1;
        }
        return .{ .items = items };
    }

    pub fn connectAll(self: *McpRuntime, tool_registry: tool_dispatch.Registry) void {
        self.discovery_cancel_requested.store(false, .seq_cst);
        self.connectAllCancellable(tool_registry, &self.discovery_cancel_requested);
    }

    pub fn connectAllForAcp(self: *McpRuntime, tool_registry: tool_dispatch.Registry) void {
        if (self.discovery_state.cmpxchgStrong(.idle, .loading, .seq_cst, .seq_cst) != null) return;
        self.discovery_cancel_requested.store(false, .seq_cst);
        self.connectAllControlled(
            tool_registry,
            &self.discovery_cancel_requested,
            null,
            .acp_startup,
        );
        self.finishDeferredDiscovery();
        self.discovery_state.store(.complete, .seq_cst);
    }

    pub fn connectAllCancellable(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        cancel_requested: *std.atomic.Value(bool),
    ) void {
        if (self.discovery_state.cmpxchgStrong(.idle, .loading, .seq_cst, .seq_cst) != null) return;
        self.connectAllControlled(tool_registry, cancel_requested, null, .all);
        self.finishDeferredDiscovery();
        self.discovery_state.store(.complete, .seq_cst);
    }

    /// Connects only required profile servers before a one-shot Ask reaches the
    /// Gateway. Optional servers remain dormant until Ask uses MCP directly or
    /// captures MCP authority for a child.
    pub fn connectRequiredForAsk(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
    ) void {
        if (self.discovery_state.cmpxchgStrong(.idle, .loading, .seq_cst, .seq_cst) != null) return;
        self.discovery_cancel_requested.store(false, .seq_cst);
        self.connectAllControlled(
            tool_registry,
            &self.discovery_cancel_requested,
            null,
            .ask_startup,
        );
        self.discovery_state.store(.complete, .seq_cst);
    }

    /// Activates optional one-shot Ask servers exactly once. Concurrent MCP
    /// operations wait for the active loader instead of launching duplicates.
    pub fn connectDeferredForAsk(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
    ) !void {
        while (true) {
            if (self.retiring.load(.acquire)) return error.McpRuntimeRetired;
            switch (self.deferred_discovery_state.load(.acquire)) {
                .complete => return,
                .idle => {
                    if (self.deferred_discovery_state.cmpxchgStrong(
                        .idle,
                        .loading,
                        .acq_rel,
                        .acquire,
                    ) != null) continue;
                    self.connectAllControlled(
                        tool_registry,
                        &self.discovery_cancel_requested,
                        null,
                        .ask_deferred,
                    );
                    self.finishDeferredDiscovery();
                    return;
                },
                .loading => {
                    self.deferred_discovery_complete.wait(io_mod.getIo()) catch |err| switch (err) {
                        error.Canceled => return error.Cancelled,
                    };
                    if (self.retiring.load(.acquire)) return error.McpRuntimeRetired;
                },
            }
        }
    }

    fn finishDeferredDiscovery(self: *McpRuntime) void {
        self.deferred_discovery_state.store(.complete, .release);
        self.deferred_discovery_complete.set(io_mod.getIo());
    }

    pub fn startDiscovery(self: *McpRuntime, tool_registry: tool_dispatch.Registry) void {
        self.startDiscoveryControlled(tool_registry, null);
    }

    fn startDiscoveryWithServerTimeout(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        server_timeout: std.Io.Duration,
    ) void {
        self.startDiscoveryControlled(tool_registry, server_timeout);
    }

    fn startDiscoveryControlled(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        server_timeout: ?std.Io.Duration,
    ) void {
        if (self.discovery_state.cmpxchgStrong(.idle, .loading, .seq_cst, .seq_cst) != null) return;
        self.discovery_cancel_requested.store(false, .seq_cst);
        self.discovery_thread = std.Thread.spawn(.{}, discoveryThreadMain, .{ self, tool_registry, server_timeout }) catch |err| {
            debug_trace.logf("mcp", "discovery thread failed to start: {s}", .{@errorName(err)});
            self.discovery_state.store(.complete, .seq_cst);
            return;
        };
    }

    pub fn isDiscovering(self: *const McpRuntime) bool {
        return self.discovery_state.load(.seq_cst) == .loading;
    }

    fn discoveryThreadMain(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        server_timeout: ?std.Io.Duration,
    ) void {
        self.connectAllControlled(
            tool_registry,
            &self.discovery_cancel_requested,
            server_timeout,
            .all,
        );
        self.finishDeferredDiscovery();
        self.discovery_state.store(.complete, .seq_cst);
    }

    fn connectAllControlled(
        self: *McpRuntime,
        tool_registry: tool_dispatch.Registry,
        cancel_requested: *std.atomic.Value(bool),
        server_timeout: ?std.Io.Duration,
        phase: startup_admission.Phase,
    ) void {
        self.tool_registry = tool_registry;
        var used_tool_names = std.StringHashMap(void).init(self.alloc);
        defer used_tool_names.deinit();

        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        for (self.servers.items) |*server| {
            const decision = startup_admission.decide(
                server.config.enabled,
                server.config.required,
                server.config.workspace_admission,
                phase,
            );
            if (decision != .deferred) continue;
            for (server.tool_catalog.tools.items) |tool| {
                used_tool_names.put(tool.prefixed_name, {}) catch |err| {
                    self.catalog_mutex.unlockShared(io_mod.getIo());
                    debug_trace.logf(
                        "mcp",
                        "failed to seed MCP tool identities phase={s} err={s}",
                        .{ @tagName(phase), @errorName(err) },
                    );
                    return;
                };
            }
        }
        self.catalog_mutex.unlockShared(io_mod.getIo());

        for (self.servers.items) |*server| {
            if (cancel_requested.load(.acquire)) return;
            switch (startup_admission.decide(
                server.config.enabled,
                server.config.required,
                server.config.workspace_admission,
                phase,
            )) {
                .disabled => {
                    server.state = .disabled;
                    var name_buf: [256]u8 = undefined;
                    debug_trace.logf(
                        "mcp",
                        "skipped disabled server {s}",
                        .{debug_trace.terminalPreview(name_buf[0..], server.config.name)},
                    );
                    continue;
                },
                .deferred => continue,
                .connect => {},
            }
            connectServerCancellable(
                self,
                server,
                &used_tool_names,
                cancel_requested,
                server_timeout,
            ) catch |err| {
                if (cancel_requested.load(.acquire)) return;
                var name_buf: [256]u8 = undefined;
                debug_trace.logf(
                    "mcp",
                    "connection failed for server {s}: {s}",
                    .{
                        debug_trace.terminalPreview(name_buf[0..], server.config.name),
                        @errorName(err),
                    },
                );
                if (server.last_error == null) {
                    server.setFailed(self.alloc, @errorName(err));
                } else {
                    server.state = .failed;
                }
            };
        }
    }

    pub fn authenticateServer(
        self: *McpRuntime,
        name: []const u8,
        open_ctx: ?*anyopaque,
        open_url: mcp_auth.OpenUrlFn,
    ) !mcp_auth.AuthenticationResult {
        return self.authenticateServerControlled(
            name,
            open_ctx,
            open_url,
            null,
        );
    }

    pub fn authenticateServerControlled(
        self: *McpRuntime,
        name: []const u8,
        open_ctx: ?*anyopaque,
        open_url: mcp_auth.OpenUrlFn,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !mcp_auth.AuthenticationResult {
        const cancellation = operation_control.CancellationSources{
            .caller = cancel_flag,
            .runtime = &self.retiring,
        };
        if (cancellation.cancelled()) return error.Cancelled;
        const server = try self.authenticationServer(name);
        try loadStoredCredentials(self.alloc, server, .{
            .lifecycle_cancel_flag = &self.retiring,
        });
        server.connection_lock.lockSharedUncancelable(io_mod.getIo());
        var connection_locked = true;
        defer if (connection_locked) server.connection_lock.unlockShared(io_mod.getIo());
        const auth_config = server.config.auth orelse mcp_contract.McpAuthConfig{};
        const client_secret = if (auth_config.client_secret_env) |env_name|
            io_mod.getenv(env_name) orelse return error.McpClientSecretEnvironmentMissing
        else
            null;
        var source = source: {
            server.auth_lock.lockUncancelable(io_mod.getIo());
            defer server.auth_lock.unlock(io_mod.getIo());
            if (server.auth_logout_in_progress.load(.acquire)) {
                return error.McpAuthorityChanged;
            }
            var challenge = if (server.pending_auth_challenge) |pending|
                try pending.clone(self.alloc)
            else
                mcp_auth.Challenge{};
            errdefer challenge.deinit(self.alloc);
            const previous_scope = if (server.auth_credentials) |credentials|
                try self.alloc.dupe(u8, credentials.scope)
            else
                null;
            break :source .{
                .generation = server.auth_generation.load(.acquire),
                .challenge = challenge,
                .previous_scope = previous_scope,
            };
        };
        defer source.challenge.deinit(self.alloc);
        defer if (source.previous_scope) |value| self.alloc.free(value);
        var credentials = switch (try mcp_auth.authorizeInteractive(self.alloc, .{
            .endpoint = try server.config.remoteUrl(),
            .challenge = source.challenge,
            .config = .{
                .resource = auth_config.resource,
                .issuer = auth_config.issuer,
                .client_id = auth_config.client_id,
                .client_secret = client_secret,
                .client_metadata_url = auth_config.client_metadata_url,
                .scopes = auth_config.scopes,
            },
            .previous_scope = source.previous_scope,
            .open_ctx = open_ctx,
            .open_url = open_url,
            .cancel_flag = cancel_flag,
            .lifecycle_cancel_flag = &self.retiring,
        })) {
            .credentials => |credentials| credentials,
            .issuer_mismatch => |mismatch| return .{ .issuer_mismatch = mismatch },
        };
        var transferred = false;
        var repaired_entries: usize = 0;
        defer if (!transferred) credentials.deinit(self.alloc);
        {
            server.auth_lock.lockUncancelable(io_mod.getIo());
            defer server.auth_lock.unlock(io_mod.getIo());
            try validateInteractiveAuthPublication(
                server,
                source.generation,
                cancellation,
            );
            const save_result = try mcp_auth_store.save(
                self.alloc,
                server.config.name,
                credentials,
            );
            repaired_entries = save_result.repaired_entries;
            installAuthCredentials(self.alloc, server, &credentials);
            transferred = true;
            if (server.pending_auth_challenge) |*pending| pending.deinit(self.alloc);
            server.pending_auth_challenge = null;
            server.auth_challenge_present.store(false, .release);
        }
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        self.catalog_mutex.lockUncancelable(io_mod.getIo());
        if (serverCatalogAvailable(server) and
            server.tool_catalog.metadata != null and
            server.tool_catalog.metadata.?.scope == .public)
        {
            server.setReady(self.alloc);
        }
        self.catalog_mutex.unlock(io_mod.getIo());
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;
        try resumeToolSubscriptionAfterAuthentication(self, server, deadline);
        return .{ .authenticated = .{
            .repaired_entries = repaired_entries,
        } };
    }

    pub fn validateAuthenticationServer(self: *McpRuntime, name: []const u8) !void {
        _ = try self.authenticationServer(name);
    }

    fn authenticationServer(self: *McpRuntime, name: []const u8) !*McpServer {
        if (self.isDiscovering()) return error.McpDiscoveryInProgress;
        const server = self.findServer(name) orelse return error.McpServerNotFound;
        if (server.config.transport == .stdio) return error.McpAuthenticationNotRemote;
        if (server.config.source == .workspace and
            server.config.workspace_admission != .approved)
        {
            return error.McpWorkspaceApprovalRequired;
        }
        return server;
    }

    fn validateInteractiveAuthPublication(
        server: *const McpServer,
        generation: u64,
        cancellation: operation_control.CancellationSources,
    ) !void {
        if (cancellation.cancelled()) return error.Cancelled;
        if (server.auth_logout_in_progress.load(.acquire) or
            server.auth_generation.load(.acquire) != generation)
        {
            return error.McpAuthorityChanged;
        }
    }

    pub const LogoutResult = struct {
        removed: bool = false,
        revocation_failed: bool = false,
        repaired_entries: usize = 0,
        local_only: bool = false,
    };

    const DetachedLogoutAuth = struct {
        credentials: ?mcp_auth.Credentials,
        challenge: ?mcp_auth.Challenge,

        fn restore(self: *DetachedLogoutAuth, server: *McpServer) void {
            std.debug.assert(server.auth_logout_in_progress.load(.acquire));
            std.debug.assert(server.auth_credentials == null);
            std.debug.assert(server.pending_auth_challenge == null);
            server.auth_credentials = self.credentials;
            self.credentials = null;
            server.auth_credentials_present.store(
                server.auth_credentials != null,
                .release,
            );
            server.pending_auth_challenge = self.challenge;
            self.challenge = null;
            server.auth_challenge_present.store(
                server.pending_auth_challenge != null,
                .release,
            );
            server.auth_logout_in_progress.store(false, .release);
        }

        fn deinit(self: *DetachedLogoutAuth, alloc: Allocator) void {
            if (self.credentials) |*credentials| credentials.deinit(alloc);
            if (self.challenge) |*challenge| challenge.deinit(alloc);
            self.* = undefined;
        }
    };

    fn detachAuthForLogout(server: *McpServer) DetachedLogoutAuth {
        std.debug.assert(!server.auth_logout_in_progress.load(.acquire));
        server.auth_logout_in_progress.store(true, .release);
        const detached = DetachedLogoutAuth{
            .credentials = server.auth_credentials,
            .challenge = server.pending_auth_challenge,
        };
        server.auth_credentials = null;
        server.auth_credentials_present.store(false, .release);
        server.pending_auth_challenge = null;
        server.auth_challenge_present.store(false, .release);
        return detached;
    }

    fn restoreAuthAfterLogout(
        self: *McpRuntime,
        server: *McpServer,
        auth: *DetachedLogoutAuth,
    ) void {
        server.auth_lock.lockUncancelable(io_mod.getIo());
        auth.restore(server);
        server.auth_lock.unlock(io_mod.getIo());
        self.replayLogoutFencedLegacyUrlCompletions(server.config.name);
    }

    fn detachTransportForLogout(
        self: *McpRuntime,
        server: *McpServer,
    ) DetachedTransport {
        self.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        const detached = server.detachTransport();
        self.cancelLegacyUrlWaitersForServerLocked(
            server.config.name,
            server.connection_generation,
        );
        return detached;
    }

    pub fn logoutServer(self: *McpRuntime, name: []const u8) !LogoutResult {
        if (self.isDiscovering()) return error.McpDiscoveryInProgress;
        const server = self.findServer(name) orelse return error.McpServerNotFound;
        if (server.config.transport == .stdio) return error.McpAuthenticationNotRemote;
        if (server.config.source == .workspace and
            server.config.workspace_admission != .approved)
        {
            const deleted = try mcp_auth_store.delete(
                self.alloc,
                server.config.name,
                try server.config.remoteUrl(),
            );
            return .{
                .removed = deleted.removed > 0,
                .repaired_entries = deleted.repaired_entries,
                .local_only = true,
            };
        }
        loadStoredCredentials(self.alloc, server, .{
            .lifecycle_cancel_flag = &self.retiring,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf(
                "mcp",
                "stored credential load skipped during logout server={s} err={s}",
                .{ server.config.name, @errorName(err) },
            );
        };
        server.auth_lock.lockUncancelable(io_mod.getIo());
        if (server.auth_logout_in_progress.load(.acquire)) {
            server.auth_lock.unlock(io_mod.getIo());
            return error.McpAuthorityChanged;
        }
        var auth = detachAuthForLogout(server);
        server.auth_lock.unlock(io_mod.getIo());
        defer auth.deinit(self.alloc);
        const deleted = mcp_auth_store.delete(
            self.alloc,
            server.config.name,
            try server.config.remoteUrl(),
        ) catch |err| {
            self.restoreAuthAfterLogout(server, &auth);
            return err;
        };
        if (deleted.removed == 0 and
            deleted.repaired_entries == 0 and
            auth.credentials == null)
        {
            self.restoreAuthAfterLogout(server, &auth);
            return .{};
        }

        server.auth_lock.lockUncancelable(io_mod.getIo());
        advanceAuthGeneration(server);
        server.auth_lock.unlock(io_mod.getIo());
        server.connection_lock.lockSharedUncancelable(io_mod.getIo());
        server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
        server.signalToolSubscriptionStop();
        server.catalog_commit_lock.unlock(io_mod.getIo());
        server.connection_lock.unlockShared(io_mod.getIo());
        server.connection_lock.lockUncancelable(io_mod.getIo());
        defer server.connection_lock.unlock(io_mod.getIo());
        server.catalog_commit_lock.lockUncancelable(io_mod.getIo());
        self.catalog_mutex.lockUncancelable(io_mod.getIo());
        const subscription = server.detachToolSubscription();
        self.catalog_mutex.unlock(io_mod.getIo());
        server.catalog_commit_lock.unlock(io_mod.getIo());
        if (subscription) |state| state.stopAndDestroy();
        var detached = self.detachTransportForLogout(server);
        detached.deinit(false);
        server.auth_lock.lockUncancelable(io_mod.getIo());
        server.setFailed(
            self.alloc,
            "Logged out. Run /mcp auth for this server to authenticate again.",
        );
        freeResolvedHeaders(self.alloc, server);
        server.auth_logout_in_progress.store(false, .release);
        server.auth_lock.unlock(io_mod.getIo());
        var revocation_failed = false;
        if (auth.credentials) |credentials| {
            mcp_auth.revokeCredentials(self.alloc, credentials) catch |err| {
                if (err != error.RevocationEndpointMissing) revocation_failed = true;
            };
        }
        return .{
            .removed = true,
            .revocation_failed = revocation_failed,
            .repaired_entries = deleted.repaired_entries,
        };
    }

    fn findServer(self: *McpRuntime, name: []const u8) ?*McpServer {
        for (self.servers.items) |*server| {
            if (std.mem.eql(u8, server.config.name, name)) return server;
        }
        return null;
    }

    fn connectServerBounded(
        self: *McpRuntime,
        server: *McpServer,
        used_tool_names: *std.StringHashMap(void),
        control: ConnectionControl,
    ) !void {
        while (true) {
            connectServer(
                self.alloc,
                server,
                self.tool_registry,
                used_tool_names,
                control,
            ) catch |err| {
                removeServerToolNames(used_tool_names, server);
                clearServerTools(self.alloc, server);
                server.disconnect();
                if (server.restart_attempts >= server.config.restart_limit) return err;
                server.restart_attempts += 1;
                debug_trace.logf(
                    "mcp",
                    "restarting stdio server after startup failure server={s} attempt={d} err={s}",
                    .{ server.config.name, server.restart_attempts, @errorName(err) },
                );
                continue;
            };
            return;
        }
    }

    fn disconnectAll(self: *McpRuntime) void {
        for (self.servers.items) |*server| server.disconnect();
    }

    fn lookupTool(self: *McpRuntime, name: []const u8) ?struct { server: *McpServer, tool: McpTool } {
        if (self.isDiscovering()) return null;
        for (self.servers.items) |*server| {
            if (server.state != .ready) continue;
            if (!serverCatalogAvailable(server)) continue;
            for (server.tool_catalog.tools.items) |tool| {
                if (std.mem.eql(u8, tool.prefixed_name, name)) {
                    return .{ .server = server, .tool = tool };
                }
            }
        }
        return null;
    }

    fn lookupCallableTool(self: *McpRuntime, name: []const u8) ?struct { server: *McpServer, tool: McpTool } {
        if (self.isDiscovering()) return null;
        for (self.servers.items) |*server| {
            if (server.state != .ready and server.state != .failed) continue;
            if (!serverCatalogAvailable(server)) continue;
            for (server.tool_catalog.tools.items) |tool| {
                if (std.mem.eql(u8, tool.prefixed_name, name)) {
                    return .{ .server = server, .tool = tool };
                }
            }
        }
        return null;
    }

    fn refreshAllToolCatalogs(
        self: *McpRuntime,
        cancel_flag: ?*std.atomic.Value(bool),
        access: *const OperationAccessGuard,
    ) void {
        for (0..self.servers.items.len) |index| {
            if (!access.allows(.{ .tool_server = self.servers.items[index].config.name })) {
                continue;
            }
            _ = refreshToolCatalog(
                self,
                index,
                null,
                cancel_flag,
                access.access,
            ) catch |err| {
                debug_trace.logf(
                    "mcp",
                    "tool cache refresh check failed server={s} err={s}",
                    .{ self.servers.items[index].config.name, @errorName(err) },
                );
            };
        }
    }

    fn refreshToolCatalogForName(
        self: *McpRuntime,
        name: []const u8,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !void {
        try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
        var server_index: ?usize = null;
        for (self.servers.items, 0..) |server, index| {
            for (server.tool_catalog.tools.items) |tool| {
                if (std.mem.eql(u8, tool.prefixed_name, name)) {
                    server_index = index;
                    break;
                }
            }
            if (server_index != null) break;
        }
        self.catalog_mutex.unlockShared(io_mod.getIo());
        const index = server_index orelse return;
        _ = try refreshToolCatalog(self, index, deadline, cancel_flag, access);
    }

    pub fn hasTool(self: *McpRuntime, name: []const u8) bool {
        return self.hasToolWithAccess(name, .unrestricted);
    }

    pub fn hasToolWithAccess(
        self: *McpRuntime,
        name: []const u8,
        access: tool_mcp_runtime.Access,
    ) bool {
        if (self.isDiscovering()) return false;
        var operation_access = OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        ) catch return false;
        defer operation_access.deinit();
        operation_access.authorize(.{ .tool = name }) catch return false;
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        const available = self.lookupCallableTool(name) != null;
        self.catalog_mutex.unlockShared(io_mod.getIo());
        if (!available) return false;
        operation_access.refresh() catch return false;
        operation_access.authorize(.{ .tool = name }) catch return false;
        return true;
    }

    pub fn serverToolFreshness(self: *McpRuntime, name: []const u8) ?ToolFreshness {
        if (self.isDiscovering()) return null;
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        const server = self.findServer(name) orelse return null;
        const metadata = server.tool_catalog.metadata orelse return null;
        if (!catalogAuthPartitionMatches(server, metadata)) return .stale;
        return feature_cache.effectiveFreshness(
            metadata,
            clockMillis(),
            if (server.tool_subscription) |subscription|
                subscription.hasInvalidation()
            else
                false,
        );
    }

    /// Returns owned names for every currently ready tool not revoked by policy.
    pub fn snapshotToolNames(
        self: *McpRuntime,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
    ) ![][]u8 {
        if (self.isDiscovering()) return alloc.alloc([]u8, 0);
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        for (self.servers.items) |*server| {
            if (server.state != .ready) continue;
            if (!serverCatalogAvailable(server)) continue;
            for (server.tool_catalog.tools.items) |tool| {
                if (permissions.rulesDenyAllTargetsForPermission(
                    permission_rules,
                    tool.prefixed_name,
                )) continue;
                try names.append(alloc, try alloc.dupe(u8, tool.prefixed_name));
            }
        }
        return names.toOwnedSlice(alloc);
    }

    pub fn snapshotAccessView(
        self: *McpRuntime,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
        features_visible: bool,
    ) !access_policy.View {
        const owned_owner = try alloc.dupe(u8, owner_id);
        errdefer alloc.free(owned_owner);
        const owned_parent = try alloc.dupe(u8, parent_id);
        errdefer alloc.free(owned_parent);
        var servers: std.ArrayList(access_policy.ServerIdentity) = .empty;
        errdefer {
            for (servers.items) |*server| server.deinit(alloc);
            servers.deinit(alloc);
        }
        var tools: std.ArrayList(access_policy.ToolIdentity) = .empty;
        errdefer {
            for (tools.items) |*tool| tool.deinit(alloc);
            tools.deinit(alloc);
        }
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        for (self.servers.items) |*server| {
            if (server.state != .ready) continue;
            const first_tool = tools.items.len;
            if (serverCatalogAvailable(server)) {
                for (server.tool_catalog.tools.items) |tool| {
                    if (permissions.rulesDenyAllTargetsForPermission(
                        permission_rules,
                        tool.prefixed_name,
                    )) continue;
                    const name = try alloc.dupe(u8, tool.prefixed_name);
                    const tool_server_name = alloc.dupe(u8, server.config.name) catch |err| {
                        alloc.free(name);
                        return err;
                    };
                    tools.append(alloc, .{
                        .name = name,
                        .server_name = tool_server_name,
                    }) catch |err| {
                        alloc.free(name);
                        alloc.free(tool_server_name);
                        return err;
                    };
                }
            }
            const admits_tools = tools.items.len != first_tool;
            const admits_features = features_visible and server.capabilities.exposesFeatures();
            if (!admits_tools and !admits_features) continue;
            const server_name = try alloc.dupe(u8, server.config.name);
            servers.append(alloc, .{
                .name = server_name,
                .source = server.config.source,
                .scope = server.config.scope,
                .connection_generation = server.connection_generation,
                .catalog_generation = server.catalog_generation,
                .auth_generation = server.auth_generation.load(.acquire),
            }) catch |err| {
                alloc.free(server_name);
                return err;
            };
        }
        const owned_servers = try servers.toOwnedSlice(alloc);
        errdefer {
            for (owned_servers) |*server| server.deinit(alloc);
            alloc.free(owned_servers);
        }
        const owned_tools = try tools.toOwnedSlice(alloc);
        return .{
            .runtime_generation = self.generation,
            .owner_id = owned_owner,
            .parent_id = owned_parent,
            .features_visible = features_visible,
            .servers = owned_servers,
            .tools = owned_tools,
        };
    }

    pub fn toolSchemaJsonByName(
        self: *McpRuntime,
        alloc: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
    ) !?tool_mcp_runtime.ToolSchemaResult {
        return self.toolSchemaJsonByNameWithAccess(
            alloc,
            name,
            permission_rules,
            limits,
            .unrestricted,
        );
    }

    pub fn toolSchemaJsonByNameWithAccess(
        self: *McpRuntime,
        alloc: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
    ) !?tool_mcp_runtime.ToolSchemaResult {
        if (self.isDiscovering()) return null;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .tool = name });
        const deadline = self.catalogOperationDeadline(
            std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        );
        try self.refreshToolCatalogForName(name, deadline, null, access);
        try operation_access.refresh();
        try operation_access.authorize(.{ .tool = name });
        var result = result: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            if (self.lookupTool(name)) |match| {
                const auth_witness = catalogAuthWitness(match.server);
                if (permissions.rulesDenyAllTargetsForPermission(permission_rules, match.tool.prefixed_name)) break :result null;
                const instruction_limit = limits.mcp_server_instructions_bytes;
                const server_instructions = match.server.instructions;
                const instruction_observed_bytes = if (server_instructions) |value|
                    value.len
                else
                    0;
                const instructions = if (server_instructions) |value|
                    value[0..context_limits.lineSafePrefixLength(value, instruction_limit.effectiveBytes())]
                else
                    null;
                const instructions_truncated = if (server_instructions) |value|
                    instructions.?.len < value.len
                else
                    false;
                const schema = try buildToolSchemaJsonWithLimitMarker(
                    alloc,
                    match.tool,
                    instructions,
                    instructions_truncated,
                    instruction_observed_bytes,
                    instruction_limit,
                );
                var schema_owned = true;
                errdefer if (schema_owned) alloc.free(schema);
                const schema_limit = limits.mcp_selected_schema_bytes;
                if (schema.len > schema_limit.effectiveBytes()) {
                    const observed_schema_bytes = schema.len;
                    alloc.free(schema);
                    schema_owned = false;
                    var rejected: std.Io.Writer.Allocating = .init(alloc);
                    defer rejected.deinit();
                    try rejected.writer.writeAll("{\"context_limit_rejection\":{\"name\":\"mcp_selected_schema_bytes\",\"tool\":");
                    try writeEncodedJsonScalar(alloc, &rejected.writer, match.tool.prefixed_name);
                    try rejected.writer.print(
                        ",\"action\":\"rejected\",\"observed_bytes\":{d},\"effective_bytes\":{d},\"source\":\"{s}\",\"override\":\"--context-limit mcp_selected_schema_bytes=BYTES|off\"}}}}",
                        .{ observed_schema_bytes, schema_limit.effectiveBytes(), schema_limit.source.label() },
                    );
                    const model_output = try rejected.toOwnedSlice();
                    errdefer alloc.free(model_output);
                    const notice = try renderSchemaNotice(
                        alloc,
                        match.tool.prefixed_name,
                        "rejected",
                        observed_schema_bytes,
                        schema_limit,
                        "mcp_selected_schema_bytes",
                    );
                    errdefer alloc.free(notice);
                    try validateCatalogAuthWitness(match.server, auth_witness);
                    break :result @as(?tool_mcp_runtime.ToolSchemaResult, .{
                        .rejected = .{ .model_output = model_output, .notice = notice },
                    });
                }
                const notice = if (instructions_truncated)
                    try renderSchemaNotice(
                        alloc,
                        match.tool.prefixed_name,
                        "instructions truncated",
                        instruction_observed_bytes,
                        instruction_limit,
                        "mcp_server_instructions_bytes",
                    )
                else
                    null;
                errdefer if (notice) |value| alloc.free(value);
                try validateCatalogAuthWitness(match.server, auth_witness);
                break :result @as(?tool_mcp_runtime.ToolSchemaResult, .{
                    .selected = .{ .model_output = schema, .notice = notice },
                });
            }
            break :result null;
        };
        errdefer if (result) |*owned| owned.deinit(alloc);
        try operation_access.refreshAndAuthorize(.{ .tool = name });
        return result;
    }

    pub fn searchTools(
        self: *McpRuntime,
        alloc: Allocator,
        query: []const u8,
        limit: usize,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.SearchResult {
        const prepared_query = try lexical_relevance.prepare(query);
        return self.searchToolsPrepared(
            alloc,
            &prepared_query,
            limit,
            permission_rules,
            limits,
            access,
        );
    }

    pub fn searchToolsPrepared(
        self: *McpRuntime,
        alloc: Allocator,
        query: *const lexical_relevance.PreparedQuery,
        limit: usize,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.SearchResult {
        if (self.isDiscovering()) {
            return .{ .model_output = try alloc.dupe(
                u8,
                "{\"tools\":[],\"count\":0,\"state\":\"discovering\",\"retryable\":true}",
            ) };
        }
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        self.refreshAllToolCatalogs(null, &operation_access);
        try operation_access.refresh();
        var result = result: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            const capped_limit = @min(if (limit == 0) default_mcp_search_limit else limit, max_mcp_search_limit);
            var match_storage: [max_mcp_search_limit]ToolSearchMatch = undefined;
            var match_count: usize = 0;
            var auth_witnesses: std.ArrayList(CatalogAuthWitness) = .empty;
            defer auth_witnesses.deinit(alloc);
            var more_available = false;
            if (try renderAuthenticationRequired(
                alloc,
                self.servers.items,
                &operation_access,
                query.raw,
            )) |output| {
                break :result tool_mcp_runtime.SearchResult{ .model_output = output, .notice = null };
            }
            for (self.servers.items) |*server| {
                if (server.state != .ready) continue;
                if (!serverCatalogAvailable(server)) continue;
                if (!operation_access.allows(.{ .tool_server = server.config.name })) continue;
                const searchable_instructions = if (server.instructions) |instructions|
                    instructions[0..context_limits.utf8PrefixLength(instructions, mcp_server_instruction_search_bytes)]
                else
                    "";
                for (server.tool_catalog.tools.items) |*tool| {
                    if (!operation_access.allows(.{ .tool = tool.prefixed_name })) continue;
                    if (permissions.rulesDenyAllTargetsForPermission(permission_rules, tool.prefixed_name)) continue;
                    const searchable_description = tool.description[0..context_limits.utf8PrefixLength(
                        tool.description,
                        mcp_tool_description_search_bytes,
                    )];
                    const searchable_schema = tool.input_schema_json[0..context_limits.utf8PrefixLength(
                        tool.input_schema_json,
                        mcp_tool_schema_search_bytes,
                    )];
                    const exact_identities = [_][]const u8{
                        tool.original_name,
                        tool.prefixed_name,
                    };
                    const strong_fields = [_][]const u8{
                        server.config.name,
                        tool.original_name,
                        tool.prefixed_name,
                        "mcp",
                    };
                    const weak_fields = [_][]const u8{
                        searchable_description,
                        searchable_schema,
                        searchable_instructions,
                    };
                    const candidate_score = lexical_relevance.score(
                        query,
                        &exact_identities,
                        &strong_fields,
                        &weak_fields,
                    ) orelse continue;
                    const candidate = ToolSearchMatch{
                        .server = server,
                        .tool = tool,
                        .score = candidate_score,
                    };

                    var insertion_index = match_count;
                    while (insertion_index > 0 and
                        lexical_relevance.order(candidate.score, match_storage[insertion_index - 1].score) == .gt)
                    {
                        insertion_index -= 1;
                    }

                    if (match_count < capped_limit) {
                        var move_index = match_count;
                        while (move_index > insertion_index) : (move_index -= 1) {
                            match_storage[move_index] = match_storage[move_index - 1];
                        }
                        match_storage[insertion_index] = candidate;
                        match_count += 1;
                    } else {
                        more_available = true;
                        if (insertion_index < capped_limit) {
                            var move_index = capped_limit - 1;
                            while (move_index > insertion_index) : (move_index -= 1) {
                                match_storage[move_index] = match_storage[move_index - 1];
                            }
                            match_storage[insertion_index] = candidate;
                        }
                    }
                }
            }
            const matches = match_storage[0..match_count];
            for (matches) |match| {
                const generation = catalogAuthWitness(match.server) orelse continue;
                var witnessed = false;
                for (auth_witnesses.items) |witness| {
                    if (witness.server == match.server) {
                        witnessed = true;
                        break;
                    }
                }
                if (!witnessed) try auth_witnesses.append(alloc, .{
                    .server = match.server,
                    .generation = generation,
                });
            }

            const full = try renderSearchResult(
                alloc,
                matches,
                matches.len,
                limits.mcp_description_bytes,
                limits.mcp_search_result_bytes,
                0,
                false,
                more_available,
            );
            const observed_bytes = full.len;
            const effective_bytes = limits.mcp_search_result_bytes.effectiveBytes();
            if (full.len <= effective_bytes) {
                errdefer alloc.free(full);
                const notice = try renderSearchNotice(alloc, matches, matches.len, limits, observed_bytes, false);
                errdefer if (notice) |value| alloc.free(value);
                try validateCatalogAuthWitnesses(auth_witnesses.items);
                break :result tool_mcp_runtime.SearchResult{ .model_output = full, .notice = notice };
            }
            alloc.free(full);

            var selected_count = matches.len;
            var model_output: ?[]u8 = null;
            while (true) {
                const candidate = try renderSearchResult(
                    alloc,
                    matches,
                    selected_count,
                    limits.mcp_description_bytes,
                    limits.mcp_search_result_bytes,
                    observed_bytes,
                    true,
                    more_available,
                );
                if (candidate.len <= effective_bytes) {
                    model_output = candidate;
                    break;
                }
                if (selected_count == 0) {
                    model_output = candidate;
                    break;
                }
                alloc.free(candidate);
                selected_count -= 1;
            }
            const output = model_output.?;
            errdefer alloc.free(output);
            const notice = try renderSearchNotice(alloc, matches, selected_count, limits, observed_bytes, true);
            errdefer if (notice) |value| alloc.free(value);
            try validateCatalogAuthWitnesses(auth_witnesses.items);
            break :result tool_mcp_runtime.SearchResult{ .model_output = output, .notice = notice };
        };
        errdefer result.deinit(alloc);
        try operation_access.refresh();
        return result;
    }

    pub fn callToolByName(self: *McpRuntime, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize) !?tool_mcp_runtime.CallResult {
        return self.callToolByNameWithOptions(
            arena,
            name,
            arguments_json,
            max_tool_result_bytes,
            .{},
        );
    }

    /// Captures only continuation identity while holding the catalog lock.
    /// Callers perform all transport writes and user waiting after this
    /// returns; no runtime-owned pointer escapes the lock.
    pub fn inputIdentityWitness(
        self: *McpRuntime,
        server_name: []const u8,
    ) ?tool_mcp_runtime.InputIdentityWitness {
        if (self.isDiscovering() or self.retiring.load(.acquire)) return null;
        self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        const server = self.findServer(server_name) orelse return null;
        if (server.state != .ready) return null;
        return .{
            .runtime_generation = self.legacy_url_runtime_generation,
            .connection_generation = server.connection_generation,
            .client_generation = if (server.dispatcher) |dispatcher|
                dispatcher.connectionGeneration()
            else
                server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .auth_generation = server.auth_generation.load(.acquire),
        };
    }

    pub fn validateToolArgumentsByName(
        self: *McpRuntime,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
    ) !tool_mcp_runtime.ValidationResult {
        return self.validateToolArgumentsByNameWithAccess(
            arena,
            name,
            arguments_json,
            .unrestricted,
        );
    }

    pub fn validateToolArgumentsByNameWithAccess(
        self: *McpRuntime,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.ValidationResult {
        if (self.isDiscovering()) return .not_available;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .tool = name });
        const deadline = self.catalogOperationDeadline(
            std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        );
        try self.refreshToolCatalogForName(name, deadline, null, access);
        try operation_access.refresh();
        try operation_access.authorize(.{ .tool = name });
        const result = result: {
            self.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            const match = self.lookupCallableTool(name) orelse
                break :result @as(tool_mcp_runtime.ValidationResult, .not_available);
            const validation = tools_feature.validateArguments(
                arena,
                match.tool.input_schema_json,
                arguments_json,
                .{},
            ) catch |err| {
                break :result @as(tool_mcp_runtime.ValidationResult, .{
                    .invalid = try std.fmt.allocPrint(
                        arena,
                        "Invalid arguments for MCP tool {s}: {s}",
                        .{ name, @errorName(err) },
                    ),
                });
            };
            break :result switch (validation) {
                .valid, .server_authoritative => @as(tool_mcp_runtime.ValidationResult, .{
                    .valid = self.generation,
                }),
                .invalid => |violation| @as(tool_mcp_runtime.ValidationResult, .{
                    .invalid = try std.fmt.allocPrint(
                        arena,
                        "Invalid arguments for MCP tool {s}: input violates {s}",
                        .{ name, violation.label() },
                    ),
                }),
            };
        };
        try operation_access.refreshAndAuthorize(.{ .tool = name });
        return result;
    }

    pub fn callToolByNameWithOptions(
        self: *McpRuntime,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        if (options.expected_runtime_generation) |expected| {
            if (expected != self.generation) return error.McpAuthorityChanged;
        }
        if (self.isDiscovering()) return null;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            options.access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .tool = name });
        const deadline = self.catalogOperationDeadline(
            std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        );
        try self.refreshToolCatalogForName(
            name,
            deadline,
            options.cancel_flag,
            options.access,
        );
        try operation_access.refresh();
        try operation_access.authorize(.{ .tool = name });
        try lockRwSharedUntil(&self.catalog_mutex, deadline, options.cancel_flag);
        var catalog_locked = true;
        defer if (catalog_locked) self.catalog_mutex.unlockShared(io_mod.getIo());
        const match = self.lookupCallableTool(name) orelse {
            self.catalog_mutex.unlockShared(io_mod.getIo());
            catalog_locked = false;
            return null;
        };
        var snapshot = try ToolCallSnapshot.init(arena, match.server, &match.tool);
        self.catalog_mutex.unlockShared(io_mod.getIo());
        catalog_locked = false;
        defer snapshot.deinit(arena);

        const validation = tools_feature.validateArguments(
            arena,
            snapshot.input_schema_json,
            arguments_json,
            .{},
        ) catch |err| return err;
        switch (validation) {
            .valid, .server_authoritative => {},
            .invalid => return error.McpInvalidToolArguments,
        }

        return try self.callToolFromSnapshot(
            arena,
            &snapshot,
            arguments_json,
            max_tool_result_bytes,
            options,
            0,
            null,
        );
    }

    fn callToolFromSnapshot(
        self: *McpRuntime,
        arena: Allocator,
        snapshot: *ToolCallSnapshot,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
        continuation_round: u8,
        continuation_deadline: ?std.Io.Clock.Timestamp,
    ) !tool_mcp_runtime.CallResult {
        if (self.retiring.load(.acquire)) return error.Cancelled;
        const operation_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (continuation_deadline) |deadline| {
            try checkOperationControl(io_mod.getIo(), deadline, options.cancel_flag);
        }
        const catalog_deadline = continuation_deadline orelse
            self.catalogOperationDeadline(operation_started);
        try self.refreshToolCatalogForName(
            snapshot.prefixed_name,
            catalog_deadline,
            options.cancel_flag,
            options.access,
        );
        try lockRwSharedUntil(&self.catalog_mutex, catalog_deadline, options.cancel_flag);
        const server = self.serverForSnapshotLocked(snapshot) orelse {
            self.catalog_mutex.unlockShared(io_mod.getIo());
            return error.McpToolCatalogChanged;
        };
        const connection_locked = server.config.transport == .stdio;
        const operation_deadline = continuation_deadline orelse if (connection_locked or
            server.config.transport == .http or
            server.config.transport == .sse)
            operation_started.addDuration(.{
                .clock = .awake,
                .raw = .fromMilliseconds(server.config.operation_timeout_ms),
            })
        else
            null;
        if (operation_deadline) |deadline| {
            checkOperationControl(io_mod.getIo(), deadline, options.cancel_flag) catch |err| {
                self.catalog_mutex.unlockShared(io_mod.getIo());
                return err;
            };
        }
        self.catalog_mutex.unlockShared(io_mod.getIo());
        try reauthorizeOperation(
            self,
            options.access,
            .{ .tool = snapshot.prefixed_name },
        );
        if (connection_locked) {
            lockRwSharedUntil(
                &server.connection_lock,
                operation_deadline.?,
                options.cancel_flag,
            ) catch |err| {
                return err;
            };
            const dispatcher = server.dispatcher orelse {
                server.connection_lock.unlockShared(io_mod.getIo());
                return error.McpToolCatalogChanged;
            };
            if (snapshot.stdio_generation == null or
                dispatcher.connectionGeneration() != snapshot.stdio_generation.?)
            {
                server.connection_lock.unlockShared(io_mod.getIo());
                return error.McpToolCatalogChanged;
            }
        }

        const result = try self.callTool(
            arena,
            server,
            snapshot,
            arguments_json,
            max_tool_result_bytes,
            options,
            connection_locked,
            operation_deadline,
        );
        if (result.status != .input_required or options.input_responder == null) return result;
        var owned_result = result;
        var result_owned = true;
        defer if (result_owned) owned_result.deinit(arena);
        const required = owned_result.input_required orelse
            return error.McpInvalidInputRequired;
        if (continuation_round >= 8) {
            return .{
                .model_output = try tool_result_limits.prepareModelOutput(
                    arena,
                    snapshot.prefixed_name,
                    "MCP protocol failure: input-required continuation limit exceeded",
                    max_tool_result_bytes,
                ),
                .status = .protocol_failure,
            };
        }
        const input_wire: elicitation.Wire = if (required.legacy_retry_without_responses)
            legacyWireForServer(server) orelse return error.McpInvalidInputRequired
        else
            .modern_mcp;
        const requests = mrtr.parseRequestJsonForWire(
            arena,
            required.input_requests_json,
            input_wire,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.McpInvalidInputRequired,
        };
        defer {
            for (requests) |*request| request.deinit(arena);
            arena.free(requests);
        }
        const responder = options.input_responder.?;
        const interaction_deadline = elicitationDeadline();
        const origin = tool_mcp_runtime.InputOrigin{
            .wire = input_wire,
            .server_name = snapshot.server_name,
            .operation = .{ .tools_call = snapshot.original_name },
            .runtime_generation = self.legacy_url_runtime_generation,
            .connection_generation = snapshot.connection_generation,
            .client_generation = snapshot.stdio_generation orelse snapshot.connection_generation,
            .catalog_generation = snapshot.catalog_generation,
            .request_generation = continuation_round + 1,
            .auth_generation = server.auth_generation.load(.acquire),
            .deadline_ms = timestampMillis(interaction_deadline),
            .lifecycle_cancel_flag = &self.retiring,
        };
        var next_options = options;
        var owned_input_responses: ?[]const u8 = null;
        defer if (owned_input_responses) |responses| arena.free(responses);
        if (required.legacy_retry_without_responses) {
            const decision = handleLegacyUrlRequiredInteraction(
                self,
                arena,
                server,
                origin,
                requests,
                required.input_requests_json,
                responder,
                .{ .tool = snapshot },
                interaction_deadline,
                options.cancel_flag,
            ) catch |err| switch (err) {
                error.McpInputRequired, error.UnsupportedMode, error.UnsupportedInputRequest => {
                    result_owned = false;
                    return owned_result;
                },
                else => |other| return other,
            };
            if (decision != .retry) {
                const message = if (decision == .declined)
                    "MCP URL elicitation was declined"
                else
                    "MCP URL elicitation was cancelled";
                notifyContinuationTerminal(responder, arena, origin, .abandoned);
                return .{
                    .model_output = try tool_result_limits.prepareModelOutput(
                        arena,
                        snapshot.prefixed_name,
                        message,
                        max_tool_result_bytes,
                    ),
                    .status = .tool_failure,
                };
            }
            next_options.continuation = null;
        } else {
            const input_responses_json = responder.callback(
                responder.context,
                arena,
                origin,
                required,
            ) catch |err| switch (err) {
                error.McpInputRequired, error.UnsupportedMode, error.UnsupportedInputRequest => {
                    result_owned = false;
                    return owned_result;
                },
                else => |other| return other,
            };
            owned_input_responses = input_responses_json;
            mrtr.validateResponses(
                arena,
                requests,
                input_responses_json,
                .{},
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.McpInvalidInputResponses,
            };
            next_options.continuation = .{
                .input_responses_json = input_responses_json,
                .request_state_json = required.request_state_json,
            };
        }
        const continued = self.callToolFromSnapshot(
            arena,
            snapshot,
            arguments_json,
            max_tool_result_bytes,
            next_options,
            continuation_round + 1,
            null,
        ) catch |err| {
            notifyContinuationTerminal(responder, arena, origin, .abandoned);
            return err;
        };
        notifyContinuationTerminal(
            responder,
            arena,
            origin,
            if (continued.status == .success or continued.status == .tool_failure)
                .completed
            else
                .abandoned,
        );
        return continued;
    }

    fn serverForSnapshotLocked(
        self: *McpRuntime,
        snapshot: *const ToolCallSnapshot,
    ) ?*McpServer {
        const server = self.findServer(snapshot.server_name) orelse return null;
        const metadata = server.tool_catalog.metadata orelse return null;
        if (!serverCatalogAvailable(server) or !metadata.key.eql(snapshot.cache_key)) {
            return null;
        }
        if (server.connection_generation != snapshot.connection_generation or
            server.catalog_generation != snapshot.catalog_generation)
        {
            return null;
        }
        if (server.tool_subscription) |subscription| {
            if (subscription.hasInvalidation()) return null;
        }
        if (!serverHasSnapshotTool(server, snapshot)) return null;
        return server;
    }

    fn catalogOperationDeadline(
        self: *const McpRuntime,
        operation_started: std.Io.Clock.Timestamp,
    ) std.Io.Clock.Timestamp {
        var timeout_ms = mcp_contract.default_operation_timeout_ms;
        var found_bounded_transport = false;
        for (self.servers.items) |*server| {
            if (!server.config.enabled or
                (server.config.transport != .stdio and
                    server.config.transport != .http and
                    server.config.transport != .sse))
            {
                continue;
            }
            timeout_ms = if (found_bounded_transport)
                @min(timeout_ms, server.config.operation_timeout_ms)
            else
                server.config.operation_timeout_ms;
            found_bounded_transport = true;
        }
        return operation_started.addDuration(.{
            .clock = .awake,
            .raw = .fromMilliseconds(timeout_ms),
        });
    }

    fn callTool(
        self: *McpRuntime,
        arena: Allocator,
        server: *McpServer,
        snapshot: *ToolCallSnapshot,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
        connection_locked: bool,
        operation_deadline: ?std.Io.Clock.Timestamp,
    ) !tool_mcp_runtime.CallResult {
        if (server.config.transport == .sse) {
            std.debug.assert(!connection_locked);
            return try callToolSse(
                self,
                arena,
                server,
                snapshot,
                arguments_json,
                max_tool_result_bytes,
                options,
                operation_deadline.?,
            );
        }
        if (server.config.transport == .http) {
            std.debug.assert(!connection_locked);
            return try callToolHttp(
                self,
                arena,
                server,
                snapshot,
                arguments_json,
                max_tool_result_bytes,
                options,
                operation_deadline.?,
            );
        }
        std.debug.assert(connection_locked);

        const raw_frame_cap = mcpResponseFrameCap(max_tool_result_bytes);
        var lease_active = true;
        var retried_unsent_call = false;
        errdefer if (lease_active) {
            server.connection_lock.unlockShared(io_mod.getIo());
        };
        while (true) {
            const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
            dispatcher.retainPublished();
            var outcome = outcome: {
                defer dispatcher.releaseUse();
                break :outcome try callStdioToolOnce(
                    self,
                    arena,
                    server,
                    dispatcher,
                    snapshot,
                    arguments_json,
                    raw_frame_cap,
                    options,
                    operation_deadline.?,
                );
            };
            if (!outcome.connection_lease_released) {
                server.connection_lock.unlockShared(io_mod.getIo());
            }
            lease_active = false;
            const response = outcome.response orelse {
                outcome.finishLegacy(arena, .abandoned);
                const err = outcome.failure.?;
                if (err == error.Cancelled or self.retiring.load(.acquire)) {
                    return error.Cancelled;
                }
                if (!outcome.connection_running and !outcome.request_started and !retried_unsent_call) {
                    try self.recoverServerForToolCall(
                        server,
                        snapshot,
                        outcome.generation,
                        operation_deadline.?,
                        options,
                    );
                    try lockRwSharedUntil(
                        &server.connection_lock,
                        operation_deadline.?,
                        options.cancel_flag,
                    );
                    lease_active = true;
                    const recovered_dispatcher = server.dispatcher orelse {
                        server.connection_lock.unlockShared(io_mod.getIo());
                        lease_active = false;
                        return error.McpToolCatalogChanged;
                    };
                    const snapshot_current = if (options.continuation == null)
                        try self.refreshSnapshotAfterUnsentRecovery(
                            server,
                            snapshot,
                            recovered_dispatcher.connectionGeneration(),
                            operation_deadline.?,
                            options.cancel_flag,
                        )
                    else
                        try self.toolSnapshotMatchesCurrent(
                            server,
                            snapshot,
                            recovered_dispatcher.connectionGeneration(),
                            operation_deadline.?,
                            options.cancel_flag,
                        );
                    if (!snapshot_current) {
                        server.connection_lock.unlockShared(io_mod.getIo());
                        lease_active = false;
                        return error.McpToolCatalogChanged;
                    }
                    retried_unsent_call = true;
                    continue;
                }

                switch (err) {
                    error.McpResponseFrameTooLarge => {
                        const result = try handleMcpResponseFrameTooLarge(
                            arena,
                            server,
                            snapshot.prefixed_name,
                            raw_frame_cap,
                        );
                        self.recoverServerForToolCall(
                            server,
                            snapshot,
                            outcome.generation,
                            operation_deadline.?,
                            options,
                        ) catch |recovery_err| {
                            debug_trace.logf(
                                "mcp",
                                "stdio server recovery failed server={s} generation={d} err={s}",
                                .{ server.config.name, outcome.generation, @errorName(recovery_err) },
                            );
                            if (recovery_err == error.McpAccessDenied or
                                recovery_err == error.McpAuthorityChanged)
                            {
                                return recovery_err;
                            }
                        };
                        return result;
                    },
                    error.Cancelled, error.McpRequestTimedOut => return err,
                    else => {
                        if (!outcome.connection_running) {
                            self.recoverServerForToolCall(
                                server,
                                snapshot,
                                outcome.generation,
                                operation_deadline.?,
                                options,
                            ) catch |recovery_err| {
                                debug_trace.logf(
                                    "mcp",
                                    "stdio server recovery failed server={s} generation={d} err={s}",
                                    .{ server.config.name, outcome.generation, @errorName(recovery_err) },
                                );
                                if (recovery_err == error.McpAccessDenied or
                                    recovery_err == error.McpAuthorityChanged)
                                {
                                    return recovery_err;
                                }
                            };
                        }
                        return err;
                    },
                }
            };
            defer arena.free(response);

            const result = tool_result.extract(arena, .{
                .server_name = server.config.name,
                .tool_name = snapshot.prefixed_name,
                .response = response,
                .max_tool_result_bytes = max_tool_result_bytes,
                .protocol = featureProtocol(outcome.protocol),
                .output_schema_json = snapshot.output_schema_json,
                .legacy_wire = legacyWireForServer(server),
            }) catch |err| {
                outcome.finishLegacy(arena, .abandoned);
                return err;
            };
            outcome.finishLegacy(arena, terminalOutcomeForCallStatus(result.status));
            return result;
        }
    }

    fn recoverServerForToolCall(
        self: *McpRuntime,
        server: *McpServer,
        snapshot: *const ToolCallSnapshot,
        failed_generation: u64,
        deadline: std.Io.Clock.Timestamp,
        options: tool_mcp_runtime.CallOptions,
    ) !void {
        var guard = ServerAccessPrecommit{
            .runtime = self,
            .target = .{ .tool = snapshot.prefixed_name },
            .access = options.access,
        };
        var precommit = guard.transport();
        return self.recoverServer(
            server,
            failed_generation,
            deadline,
            options.cancel_flag,
            &precommit,
        );
    }

    fn ensureFeatureServerRunning(
        self: *McpRuntime,
        server: *McpServer,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !bool {
        if (server.config.transport != .stdio) return false;

        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        const dispatcher = server.dispatcher orelse {
            server.connection_lock.unlockShared(io_mod.getIo());
            return error.McpConnectionClosed;
        };
        const generation = dispatcher.connectionGeneration();
        const running = dispatcher.isRunning();
        server.connection_lock.unlockShared(io_mod.getIo());
        if (running) return false;

        var guard = ServerAccessPrecommit{
            .runtime = self,
            .target = .{ .feature_server = server.config.name },
            .access = access,
        };
        var precommit = guard.transport();
        try self.recoverServer(
            server,
            generation,
            deadline,
            cancel_flag,
            &precommit,
        );
        return true;
    }

    fn toolSnapshotMatchesCurrent(
        self: *McpRuntime,
        server: *McpServer,
        snapshot: *const ToolCallSnapshot,
        generation: u64,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !bool {
        try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());

        const dispatcher = server.dispatcher orelse return false;
        if (dispatcher.connectionGeneration() != generation or
            snapshot.stdio_generation == null or
            generation != snapshot.stdio_generation.?) return false;
        return self.serverForSnapshotLocked(snapshot) == server;
    }

    fn refreshSnapshotAfterUnsentRecovery(
        self: *McpRuntime,
        server: *McpServer,
        snapshot: *ToolCallSnapshot,
        generation: u64,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !bool {
        try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());

        const dispatcher = server.dispatcher orelse return false;
        if (self.findServer(snapshot.server_name) != server or
            dispatcher.connectionGeneration() != generation)
        {
            return false;
        }
        return refreshSnapshotGenerationsIfIdentityMatches(
            server,
            snapshot,
            generation,
        );
    }

    fn recoverServer(
        self: *McpRuntime,
        server: *McpServer,
        failed_generation: u64,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
        precommit: ?*mcp_contract.TransportPrecommit,
    ) !void {
        try lockMutexUntil(&self.recovery_mutex, deadline, cancel_flag);
        defer self.recovery_mutex.unlock(io_mod.getIo());

        if (precommit) |guard| {
            try guard.acquire();
            defer guard.release();
        }

        if (failed_generation <= server.last_recovery_generation) return;

        try lockRwUntil(&server.connection_lock, deadline, cancel_flag);
        defer server.connection_lock.unlock(io_mod.getIo());

        try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);

        if (server.dispatcher) |dispatcher| {
            if (dispatcher.connectionGeneration() != failed_generation and
                dispatcher.isRunning())
            {
                server.last_recovery_generation = failed_generation;
                self.catalog_mutex.unlock(io_mod.getIo());
                return;
            }
        }
        if (server.restart_attempts >= server.config.restart_limit) {
            server.last_recovery_generation = failed_generation;
            var retired = detachFailedConnectionPreservingFeatureCaches(server);
            server.setFailed(self.alloc, "MCP restart limit reached");
            self.catalog_mutex.unlock(io_mod.getIo());
            retired.deinit(self.alloc);
            return error.McpRestartLimitReached;
        }

        var used_tool_names = std.StringHashMap(void).init(self.alloc);
        defer used_tool_names.deinit();
        for (self.servers.items) |*candidate| {
            if (candidate == server) continue;
            for (candidate.tool_catalog.tools.items) |tool| {
                used_tool_names.put(tool.prefixed_name, {}) catch |err| {
                    self.catalog_mutex.unlock(io_mod.getIo());
                    return err;
                };
            }
        }

        server.restart_attempts += 1;
        const next_generation = server.next_generation;
        const next_request_id = server.next_request_id;
        self.catalog_mutex.unlock(io_mod.getIo());

        try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
        debug_trace.logf(
            "mcp",
            "restarting stdio server server={s} generation={d} attempt={d}",
            .{ server.config.name, failed_generation, server.restart_attempts },
        );

        var connected = McpServer{
            .config = server.config,
            .runtime = self,
            .auth_generation = .init(server.auth_generation.load(.acquire)),
            .next_request_id = next_request_id,
            .next_generation = next_generation,
            .connection_generation = server.connection_generation,
            .catalog_generation = server.catalog_generation,
            .next_subscription_generation = server.next_subscription_generation,
        };
        var connected_published = false;
        defer if (!connected_published) {
            var detached = detachConnection(&connected);
            detached.deinit(self.alloc);
        };
        connectServer(
            self.alloc,
            &connected,
            self.tool_registry,
            &used_tool_names,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = &self.retiring,
            },
        ) catch |err| {
            try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
            server.setFailed(self.alloc, @errorName(err));
            self.catalog_mutex.unlock(io_mod.getIo());
            return err;
        };

        try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
        try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
        var retired = detachPublishedConnection(server);
        publishConnection(server, &connected);
        server.last_recovery_generation = failed_generation;
        connected_published = true;
        self.catalog_mutex.unlock(io_mod.getIo());
        retired.deinit(self.alloc);
    }

    pub fn loadStoredCredentialsForHealthSnapshot(self: *McpRuntime) !void {
        if (self.discovery_state.load(.acquire) != .idle) {
            return error.McpDiscoveryInProgress;
        }
        for (self.servers.items) |*server| {
            try loadStoredCredentials(self.alloc, server, .{
                .lifecycle_cancel_flag = &self.retiring,
            });
        }
    }

    pub fn listServersAndTools(self: *McpRuntime, alloc: Allocator) ![]u8 {
        var snapshot = try self.snapshotHealth(alloc, clockMillis());
        defer snapshot.deinit(alloc);
        return health.render(alloc, snapshot);
    }

    pub fn listResources(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        include_templates: bool,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !ResourceCatalogResult {
        if (self.isDiscovering()) return error.McpDiscoveryInProgress;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = server_name });
        const server = self.findServer(server_name) orelse return error.McpServerNotFound;
        try requireWorkspaceOperationApproval(server);
        if (!server.capabilities.resources) return error.McpResourcesUnsupported;
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        if (!try ensureResourceCatalog(self, server, false, deadline, cancel_flag, access)) {
            return error.McpResourceCatalogUnavailable;
        }
        if (include_templates and
            !try ensureResourceCatalog(self, server, true, deadline, cancel_flag, access))
        {
            return error.McpResourceCatalogUnavailable;
        }

        var result = result: {
            try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            if (!featureCatalogAvailable(server, .resources) or
                (include_templates and !featureCatalogAvailable(server, .resource_templates)))
            {
                return error.McpResourceCatalogUnavailable;
            }
            const auth_witness = featureCatalogAuthWitness(
                server,
                if (include_templates) .resource_templates else .resources,
            );
            const resources = server.resource_catalog.catalog orelse return error.McpResourceCatalogUnavailable;
            const template_count = if (include_templates)
                if (server.resource_template_catalog.catalog) |catalog| catalog.items.len else 0
            else
                0;
            const resource_count = if (include_templates) 0 else resources.items.len;
            const total = std.math.add(usize, resource_count, template_count) catch
                return error.McpResourceLimitExceeded;
            const items = try alloc.alloc(ResourceSummary, total);
            var count: usize = 0;
            errdefer {
                for (items[0..count]) |*item| item.deinit(alloc);
                alloc.free(items);
            }
            if (!include_templates) for (resources.items) |resource| {
                items[count] = try cloneResourceSummary(alloc, server.config.name, resource);
                count += 1;
            };
            if (include_templates) if (server.resource_template_catalog.catalog) |templates| {
                for (templates.items) |template| {
                    items[count] = try cloneTemplateSummary(alloc, server.config.name, template);
                    count += 1;
                }
            };
            try validateFeatureCatalogAuthWitness(server, auth_witness);
            break :result ResourceCatalogResult{ .items = items };
        };
        errdefer result.deinit(alloc);
        try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
        return result;
    }

    pub fn listPrompts(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !PromptCatalogResult {
        if (self.isDiscovering()) return error.McpDiscoveryInProgress;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = server_name });
        const server = self.findServer(server_name) orelse return error.McpServerNotFound;
        try requireWorkspaceOperationApproval(server);
        if (!server.capabilities.prompts) return error.McpPromptsUnsupported;
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        if (!try ensurePromptCatalog(self, server, deadline, cancel_flag, access)) {
            return error.McpPromptCatalogUnavailable;
        }
        var result = result: {
            try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
            defer self.catalog_mutex.unlockShared(io_mod.getIo());
            if (!featureCatalogAvailable(server, .prompts)) return error.McpPromptCatalogUnavailable;
            const auth_witness = featureCatalogAuthWitness(server, .prompts);
            const catalog = server.prompt_catalog.catalog orelse return error.McpPromptCatalogUnavailable;
            const items = try alloc.alloc(PromptSummary, catalog.prompts.len);
            var count: usize = 0;
            errdefer {
                for (items[0..count]) |*item| item.deinit(alloc);
                alloc.free(items);
            }
            for (catalog.prompts, 0..) |prompt, index| {
                items[index] = try clonePromptSummary(alloc, server.config.name, prompt);
                count += 1;
            }
            try validateFeatureCatalogAuthWitness(server, auth_witness);
            break :result PromptCatalogResult{ .items = items };
        };
        errdefer result.deinit(alloc);
        try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
        return result;
    }

    pub fn readResource(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        uri: []const u8,
        options: FeatureCallOptions,
    ) !ResourceReadResult {
        if (self.isDiscovering()) return error.McpDiscoveryInProgress;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            options.access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = server_name });
        const server = self.findServer(server_name) orelse return error.McpServerNotFound;
        try requireWorkspaceOperationApproval(server);
        if (!server.capabilities.resources) return error.McpResourcesUnsupported;
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        while (true) {
            if (!try ensureResourceCatalog(self, server, false, deadline, options.cancel_flag, options.access)) {
                return error.McpResourceCatalogUnavailable;
            }
            var snapshot = if (try snapshotConcreteResourceIdentity(
                self,
                alloc,
                server,
                uri,
                deadline,
                options.cancel_flag,
            )) |concrete|
                concrete
            else snapshot: {
                if (!try ensureResourceCatalog(self, server, true, deadline, options.cancel_flag, options.access)) {
                    return error.McpResourceCatalogUnavailable;
                }
                break :snapshot try snapshotResourceIdentityWithTemplates(
                    self,
                    alloc,
                    server,
                    uri,
                    deadline,
                    options.cancel_flag,
                );
            };
            defer snapshot.deinit(alloc);
            try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
            try invalidateResourceReadCacheIfNeeded(self, server, deadline, options.cancel_flag);
            ensureResourceUpdateSubscription(
                self,
                server,
                uri,
                deadline,
                options.cancel_flag,
                options.access,
            ) catch |err| {
                if (err == error.McpAccessDenied or err == error.McpAuthorityChanged) return err;
                debug_trace.logf(
                    "mcp",
                    "resource update subscription skipped server={s} uri={s} err={s}",
                    .{ server.config.name, uri, @errorName(err) },
                );
            };
            if (try cachedResourceRead(self, alloc, server, uri, deadline, options.cancel_flag, false, options.access)) |cached_value| {
                var cached = cached_value;
                errdefer cached.deinit(alloc);
                try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
                return cached;
            }
            var stale = try cachedResourceRead(self, alloc, server, uri, deadline, options.cancel_flag, true, options.access);
            defer if (stale) |*cached| cached.deinit(alloc);
            const recovered = self.ensureFeatureServerRunning(
                server,
                deadline,
                options.cancel_flag,
                options.access,
            ) catch |err| {
                if (stale) |cached_value| if (resources_feature.staleFallbackEligible(err) or
                    err == error.McpRestartLimitReached)
                {
                    var cached = cached_value;
                    stale = null;
                    errdefer cached.deinit(alloc);
                    try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
                    return cached;
                };
                return err;
            };
            if (recovered) continue;
            const fetched = requestResourceRead(self, alloc, server, &snapshot, uri, deadline, options) catch |err| {
                if (stale) |cached_value| if (resources_feature.staleFallbackEligible(err)) {
                    var cached = cached_value;
                    stale = null;
                    errdefer cached.deinit(alloc);
                    try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
                    return cached;
                };
                return err;
            };
            return finishFetchedResourceRead(
                self,
                alloc,
                server,
                &snapshot,
                uri,
                fetched,
                deadline,
                options.cancel_flag,
                options.access,
            );
        }
    }

    pub fn getPrompt(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        name: []const u8,
        arguments_json: []const u8,
        options: FeatureCallOptions,
    ) !PromptGetResult {
        if (self.isDiscovering()) return error.McpDiscoveryInProgress;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            options.access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = server_name });
        const server = self.findServer(server_name) orelse return error.McpServerNotFound;
        try requireWorkspaceOperationApproval(server);
        if (!server.capabilities.prompts) return error.McpPromptsUnsupported;
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(server.config.operation_timeout_ms),
        });
        while (true) {
            _ = try ensurePromptCatalog(self, server, deadline, options.cancel_flag, options.access);
            var snapshot = try snapshotPromptIdentity(
                self,
                alloc,
                server,
                name,
                arguments_json,
                deadline,
                options.cancel_flag,
            );
            defer snapshot.deinit(alloc);
            if (try self.ensureFeatureServerRunning(server, deadline, options.cancel_flag, options.access)) continue;
            var result = try requestPromptGet(
                self,
                alloc,
                server,
                &snapshot,
                name,
                arguments_json,
                deadline,
                options,
            );
            errdefer result.deinit(alloc);
            const server_copy = try alloc.dupe(u8, server.config.name);
            errdefer alloc.free(server_copy);
            const name_copy = try alloc.dupe(u8, name);
            errdefer alloc.free(name_copy);
            try operation_access.refreshAndAuthorize(.{ .feature_server = server_name });
            const description = result.description;
            const messages = result.messages;
            result.description = null;
            result.messages = &.{};
            result.deinit(alloc);
            return .{
                .server_name = server_copy,
                .name = name_copy,
                .description = description,
                .messages = messages,
            };
        }
    }

    pub fn completePromptArgument(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        prompt_name: []const u8,
        argument: completion_feature.Argument,
        context_arguments: []const completion_feature.Argument,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !CompletionResult {
        return completeFeatureArgument(
            self,
            alloc,
            server_name,
            .{ .prompt = prompt_name },
            argument,
            context_arguments,
            cancel_flag,
            access,
        );
    }

    pub fn completeResourceTemplateArgument(
        self: *McpRuntime,
        alloc: Allocator,
        server_name: []const u8,
        uri_template: []const u8,
        argument: completion_feature.Argument,
        context_arguments: []const completion_feature.Argument,
        cancel_flag: ?*std.atomic.Value(bool),
        access: tool_mcp_runtime.Access,
    ) !CompletionResult {
        return completeFeatureArgument(
            self,
            alloc,
            server_name,
            .{ .resource_template = uri_template },
            argument,
            context_arguments,
            cancel_flag,
            access,
        );
    }

    pub fn callFeatureForModel(
        self: *McpRuntime,
        alloc: Allocator,
        request: tool_mcp_runtime.FeatureRequest,
        options: tool_mcp_runtime.FeatureCallOptions,
    ) !tool_mcp_runtime.FeatureResult {
        if (self.isDiscovering()) return error.McpDiscoveryInProgress;
        var operation_access = try OperationAccessGuard.init(
            self.alloc,
            options.access,
            self.generation,
        );
        defer operation_access.deinit();
        try operation_access.authorize(.{ .feature_server = request.server_name });
        const model_output = switch (request.action) {
            .resource_list, .resource_templates => output: {
                var result = try self.listResources(
                    alloc,
                    request.server_name,
                    request.action == .resource_templates,
                    options.cancel_flag,
                    options.access,
                );
                defer result.deinit(alloc);
                break :output try renderResourceCatalogForModel(
                    alloc,
                    request.action,
                    request.server_name,
                    result,
                );
            },
            .resource_read => output: {
                var protocol_diagnostic: ?[]u8 = null;
                defer if (protocol_diagnostic) |diagnostic| alloc.free(diagnostic);
                var result = self.readResource(
                    alloc,
                    request.server_name,
                    request.identity,
                    .{
                        .cancel_flag = options.cancel_flag,
                        .input_responder = options.input_responder,
                        .access = options.access,
                        .protocol_diagnostic = &protocol_diagnostic,
                    },
                ) catch |err| {
                    if (err == error.McpProtocolError) {
                        if (protocol_diagnostic) |diagnostic| {
                            protocol_diagnostic = null;
                            break :output diagnostic;
                        }
                    }
                    return err;
                };
                defer result.deinit(alloc);
                break :output try renderResourceReadForModel(alloc, result);
            },
            .prompt_list => output: {
                var result = try self.listPrompts(
                    alloc,
                    request.server_name,
                    options.cancel_flag,
                    options.access,
                );
                defer result.deinit(alloc);
                break :output try renderPromptCatalogForModel(
                    alloc,
                    request.server_name,
                    result,
                );
            },
            .prompt_get => output: {
                var protocol_diagnostic: ?[]u8 = null;
                defer if (protocol_diagnostic) |diagnostic| alloc.free(diagnostic);
                var result = self.getPrompt(
                    alloc,
                    request.server_name,
                    request.identity,
                    request.arguments_json,
                    .{
                        .cancel_flag = options.cancel_flag,
                        .input_responder = options.input_responder,
                        .access = options.access,
                        .protocol_diagnostic = &protocol_diagnostic,
                    },
                ) catch |err| {
                    if (err == error.McpProtocolError) {
                        if (protocol_diagnostic) |diagnostic| {
                            protocol_diagnostic = null;
                            break :output diagnostic;
                        }
                    }
                    return err;
                };
                defer result.deinit(alloc);
                break :output try renderPromptGetForModel(alloc, result);
            },
            .prompt_complete, .resource_complete => output: {
                const context_arguments = try alloc.alloc(
                    completion_feature.Argument,
                    request.context_arguments.len,
                );
                defer alloc.free(context_arguments);
                for (request.context_arguments, 0..) |argument, index| {
                    context_arguments[index] = .{ .name = argument.name, .value = argument.value };
                }
                const argument = completion_feature.Argument{
                    .name = request.argument_name,
                    .value = request.value,
                };
                var result = if (request.action == .prompt_complete)
                    try self.completePromptArgument(
                        alloc,
                        request.server_name,
                        request.identity,
                        argument,
                        context_arguments,
                        options.cancel_flag,
                        options.access,
                    )
                else
                    try self.completeResourceTemplateArgument(
                        alloc,
                        request.server_name,
                        request.identity,
                        argument,
                        context_arguments,
                        options.cancel_flag,
                        options.access,
                    );
                defer result.deinit(alloc);
                break :output try renderCompletionForModel(
                    alloc,
                    request.action,
                    request,
                    result,
                );
            },
        };
        errdefer alloc.free(model_output);
        if (model_output.len > options.output_limit_bytes) {
            return error.McpFeatureOutputLimitExceeded;
        }
        try operation_access.refresh();
        try operation_access.authorize(.{ .feature_server = request.server_name });
        return .{ .model_output = model_output };
    }
};

fn finishFetchedResourceRead(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *const FeatureIdentitySnapshot,
    uri: []const u8,
    fetched_value: FetchedResourceRead,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !ResourceReadResult {
    var fetched = fetched_value;
    var fetched_owned = true;
    errdefer if (fetched_owned) fetched.result.deinit(alloc);
    var operation_access = try OperationAccessGuard.init(
        self.alloc,
        access,
        self.generation,
    );
    defer operation_access.deinit();
    const access_target = access_policy.Target{ .feature_server = server.config.name };
    try operation_access.authorize(access_target);
    if (fetched.result.cache_eligible) {
        try publishResourceReadCache(
            self,
            server,
            snapshot,
            uri,
            fetched,
            deadline,
            cancel_flag,
            access,
        );
    }
    var result = fetched.result;
    fetched.result.contents = &.{};
    fetched.result.deinit(alloc);
    fetched_owned = false;
    errdefer result.deinit(alloc);
    const server_copy = try alloc.dupe(u8, server.config.name);
    errdefer alloc.free(server_copy);
    const uri_copy = try alloc.dupe(u8, uri);
    errdefer alloc.free(uri_copy);
    try operation_access.refreshAndAuthorize(access_target);
    const contents = result.contents;
    result.contents = &.{};
    result.deinit(alloc);
    return .{ .server_name = server_copy, .uri = uri_copy, .contents = contents };
}

fn renderResourceCatalogForModel(
    alloc: Allocator,
    action: tool_mcp_runtime.FeatureAction,
    server_name: []const u8,
    result: ResourceCatalogResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, action, server_name);
    try out.writer.writeAll(",\"items\":[");
    for (result.items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"server\":");
        try std.json.Stringify.value(item.server_name, .{}, &out.writer);
        try out.writer.writeAll(",\"identity\":");
        try std.json.Stringify.value(item.uri, .{}, &out.writer);
        try out.writer.writeAll(",\"name\":");
        try std.json.Stringify.value(item.name, .{}, &out.writer);
        if (item.title) |value| {
            try out.writer.writeAll(",\"title\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        if (item.description) |value| {
            try out.writer.writeAll(",\"description\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        if (item.mime_type) |value| {
            try out.writer.writeAll(",\"mimeType\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        try out.writer.writeAll(",\"template\":");
        try out.writer.writeAll(if (item.is_template) "true" else "false");
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderResourceReadForModel(alloc: Allocator, result: ResourceReadResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, .resource_read, result.server_name);
    try out.writer.writeAll(",\"identity\":");
    try std.json.Stringify.value(result.uri, .{}, &out.writer);
    try out.writer.writeAll(",\"contents\":[");
    for (result.contents, 0..) |content, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"uri\":");
        try std.json.Stringify.value(content.uri, .{}, &out.writer);
        if (content.mime_type) |value| {
            try out.writer.writeAll(",\"mimeType\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        if (content.annotations_json) |value| {
            try out.writer.writeAll(",\"annotations\":");
            try out.writer.writeAll(value);
        }
        if (content.metadata_json) |value| {
            try out.writer.writeAll(",\"_meta\":");
            try out.writer.writeAll(value);
        }
        switch (content.data) {
            .text => |value| {
                try out.writer.writeAll(",\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
            },
            .blob => |value| {
                try out.writer.writeAll(",\"type\":\"blob\",\"blob\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
            },
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderPromptCatalogForModel(
    alloc: Allocator,
    server_name: []const u8,
    result: PromptCatalogResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, .prompt_list, server_name);
    try out.writer.writeAll(",\"items\":[");
    for (result.items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"server\":");
        try std.json.Stringify.value(item.server_name, .{}, &out.writer);
        try out.writer.writeAll(",\"identity\":");
        try std.json.Stringify.value(item.name, .{}, &out.writer);
        if (item.title) |value| {
            try out.writer.writeAll(",\"title\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        if (item.description) |value| {
            try out.writer.writeAll(",\"description\":");
            try std.json.Stringify.value(value, .{}, &out.writer);
        }
        try out.writer.writeAll(",\"arguments\":[");
        for (item.arguments, 0..) |argument, argument_index| {
            if (argument_index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"name\":");
            try std.json.Stringify.value(argument.name, .{}, &out.writer);
            try out.writer.writeAll(",\"required\":");
            try out.writer.writeAll(if (argument.required) "true" else "false");
            if (argument.description) |value| {
                try out.writer.writeAll(",\"description\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderPromptGetForModel(alloc: Allocator, result: PromptGetResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, .prompt_get, result.server_name);
    try out.writer.writeAll(",\"identity\":");
    try std.json.Stringify.value(result.name, .{}, &out.writer);
    if (result.description) |value| {
        try out.writer.writeAll(",\"description\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeAll(",\"messages\":[");
    for (result.messages, 0..) |message, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"role\":");
        try std.json.Stringify.value(@tagName(message.role), .{}, &out.writer);
        try out.writer.writeAll(",\"contentKind\":");
        try std.json.Stringify.value(@tagName(message.content_kind), .{}, &out.writer);
        try out.writer.writeAll(",\"content\":");
        try out.writer.writeAll(message.content_json);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderCompletionForModel(
    alloc: Allocator,
    action: tool_mcp_runtime.FeatureAction,
    request: tool_mcp_runtime.FeatureRequest,
    result: CompletionResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeFeatureEnvelopeStart(&out.writer, action, result.server_name);
    try out.writer.writeAll(",\"identity\":");
    try std.json.Stringify.value(request.identity, .{}, &out.writer);
    try out.writer.writeAll(",\"argument\":");
    try std.json.Stringify.value(request.argument_name, .{}, &out.writer);
    try out.writer.writeAll(",\"values\":[");
    for (result.values, 0..) |value, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    try out.writer.writeByte(']');
    if (result.total) |value| try out.writer.print(",\"total\":{d}", .{value});
    if (result.has_more) |value| {
        try out.writer.writeAll(",\"hasMore\":");
        try out.writer.writeAll(if (value) "true" else "false");
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeFeatureEnvelopeStart(
    writer: *std.Io.Writer,
    action: tool_mcp_runtime.FeatureAction,
    server_name: []const u8,
) !void {
    try writer.writeAll("{\"trust\":\"untrusted_external\",\"authority\":\"none\",\"action\":");
    try std.json.Stringify.value(@tagName(action), .{}, writer);
    try writer.writeAll(",\"server\":");
    try std.json.Stringify.value(server_name, .{}, writer);
}

fn refreshToolCatalog(
    self: *McpRuntime,
    server_index: usize,
    requested_deadline: ?std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !bool {
    if (server_index >= self.servers.items.len) return false;
    const server = &self.servers.items[server_index];
    if (server.state != .ready and server.state != .failed) return true;
    var operation_access = try OperationAccessGuard.init(
        self.alloc,
        access,
        self.generation,
    );
    defer operation_access.deinit();
    const access_target = access_policy.Target{ .tool_server = server.config.name };
    const may_mutate_before_transport = switch (access) {
        .unrestricted => true,
        .disabled, .scoped => false,
    };
    try operation_access.authorize(access_target);
    const deadline = requested_deadline orelse std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(server.config.operation_timeout_ms),
    });
    switch (access) {
        .unrestricted => try recoverFinishedToolSubscription(
            self,
            server,
            deadline,
            cancel_flag,
        ),
        .disabled, .scoped => {},
    }

    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    var initial_connection_locked = true;
    defer if (initial_connection_locked) {
        server.connection_lock.unlockShared(io_mod.getIo());
    };
    const initial = state: {
        try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        break :state .{
            .metadata = server.tool_catalog.metadata orelse return true,
            .invalidated = if (server.tool_subscription) |subscription|
                subscription.hasInvalidation()
            else
                false,
        };
    };
    server.connection_lock.unlockShared(io_mod.getIo());
    initial_connection_locked = false;
    try operation_access.refreshAndAuthorize(access_target);
    const initial_key = try currentCacheKey(
        self.alloc,
        server,
        initial.metadata.scope,
        deadline,
        cancel_flag,
        .{ .runtime = self, .access = access, .target = access_target },
    );
    const initial_decision = feature_cache.decideRefresh(
        initial.metadata,
        initial_key,
        clockMillis(),
        initial.invalidated,
    );
    if (initial_decision.action != .refresh) {
        debug_trace.logf(
            "mcp",
            "tool cache decision server={s} action={s} freshness={s} catalog_generation={d}",
            .{
                server.config.name,
                @tagName(initial_decision.action),
                @tagName(feature_cache.effectiveFreshness(
                    initial.metadata,
                    clockMillis(),
                    initial.invalidated,
                )),
                initial.metadata.catalog_generation,
            },
        );
        try operation_access.refreshAndAuthorize(access_target);
        return initial_decision.may_serve_snapshot;
    }
    if (!initial.metadata.key.eql(initial_key)) {
        try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
        const legacy_remote = server.legacy_http != null or server.legacy_sse != null;
        server.connection_lock.unlockShared(io_mod.getIo());
        if (legacy_remote) {
            try operation_access.refreshAndAuthorize(access_target);
            if (!may_mutate_before_transport) return initial_decision.may_serve_snapshot;
            try reconnectLegacyForCredentials(self, server, deadline, cancel_flag);
            return true;
        }
    }

    try lockMutexUntil(&server.tool_refresh_lock, deadline, cancel_flag);
    defer server.tool_refresh_lock.unlock(io_mod.getIo());

    try operation_access.refreshAndAuthorize(access_target);
    const requested_key = try currentCacheKey(
        self.alloc,
        server,
        initial.metadata.scope,
        deadline,
        cancel_flag,
        .{ .runtime = self, .access = access, .target = access_target },
    );
    try operation_access.refreshAndAuthorize(access_target);
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    var connection_locked = true;
    defer if (connection_locked) server.connection_lock.unlockShared(io_mod.getIo());
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    const current = server.tool_catalog.metadata orelse {
        self.catalog_mutex.unlock(io_mod.getIo());
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;
        return true;
    };
    const invalidated = if (server.tool_subscription) |subscription|
        subscription.hasInvalidation()
    else
        false;
    const decision = feature_cache.decideRefresh(
        current,
        requested_key,
        clockMillis(),
        invalidated,
    );
    if (decision.action != .refresh) {
        self.catalog_mutex.unlock(io_mod.getIo());
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;
        return decision.may_serve_snapshot;
    }
    if (may_mutate_before_transport) {
        server.tool_catalog.metadata = feature_cache.beginRefresh(current);
        if (!decision.may_serve_snapshot) server.tool_catalog.available = false;
    }
    const invalidation_generation = if (server.tool_subscription) |subscription|
        subscription.invalidationGeneration()
    else
        0;
    self.catalog_mutex.unlock(io_mod.getIo());
    var refresh_finished = false;
    errdefer |err| if (!refresh_finished and
        err != error.McpAccessDenied and
        err != error.McpAuthorityChanged)
    {
        recordToolRefreshFailure(self, server, current, decision.may_serve_snapshot, err);
    };
    var fetched = fetchCurrentToolCatalog(
        self,
        server,
        deadline,
        cancel_flag,
        access,
    ) catch |err| {
        const legacy_http = server.legacy_http;
        const legacy_sse = server.legacy_sse;
        if (err == error.McpAuthenticationRequired and
            (legacy_http != null or legacy_sse != null))
        {
            if (!may_mutate_before_transport) {
                server.connection_lock.unlockShared(io_mod.getIo());
                connection_locked = false;
                try operation_access.refreshAndAuthorize(access_target);
                recordToolRefreshFailure(
                    self,
                    server,
                    current,
                    decision.may_serve_snapshot,
                    err,
                );
                refresh_finished = true;
                return decision.may_serve_snapshot;
            }
            const control = streamable_http.Control{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = &self.retiring,
            };
            const captured = if (legacy_http) |client|
                captureLegacyStreamableAuth(self.alloc, server, client, control)
            else
                captureLegacySseAuth(self.alloc, server, legacy_sse.?, control);
            captured catch |capture_err| {
                server.connection_lock.unlockShared(io_mod.getIo());
                connection_locked = false;
                recordToolRefreshFailure(
                    self,
                    server,
                    current,
                    decision.may_serve_snapshot,
                    capture_err,
                );
                refresh_finished = true;
                return decision.may_serve_snapshot;
            };
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            try operation_access.refreshAndAuthorize(access_target);
            if (try authorizePendingChallengeIfAutomated(
                self.alloc,
                server,
                control,
            )) {
                try operation_access.refreshAndAuthorize(access_target);
                try reconnectLegacyForCredentials(self, server, deadline, cancel_flag);
                refresh_finished = true;
                return true;
            }
            recordToolRefreshFailure(
                self,
                server,
                current,
                decision.may_serve_snapshot,
                err,
            );
            refresh_finished = true;
            return decision.may_serve_snapshot;
        }
        if (err == error.McpSessionExpired and legacy_http != null) {
            const client = legacy_http.?;
            const version = client.version;
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            try operation_access.refreshAndAuthorize(access_target);
            if (!may_mutate_before_transport) {
                recordToolRefreshFailure(
                    self,
                    server,
                    current,
                    decision.may_serve_snapshot,
                    err,
                );
                refresh_finished = true;
                return decision.may_serve_snapshot;
            }
            try recoverLegacyHttpSession(
                self,
                server,
                client,
                version,
                deadline,
                cancel_flag,
            );
            refresh_finished = true;
            return true;
        }
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;
        if (err == error.McpAccessDenied) return error.McpAccessDenied;
        if (err == error.McpAuthorityChanged) return error.McpAuthorityChanged;
        recordToolRefreshFailure(self, server, current, decision.may_serve_snapshot, err);
        return decision.may_serve_snapshot;
    };
    defer fetched.deinit(self.alloc);
    const scope: feature_cache.CacheScope = switch (fetched.catalog.cache_scope) {
        .private => .private,
        .public => .public,
    };
    const replacement_key = if (fetched.auth_identity) |auth_identity|
        cacheKeyWithAuthIdentity(server, scope, auth_identity)
    else
        currentCacheKey(
            self.alloc,
            server,
            scope,
            deadline,
            cancel_flag,
            .{ .runtime = self, .access = access, .target = access_target },
        ) catch |err| {
            server.connection_lock.unlockShared(io_mod.getIo());
            connection_locked = false;
            recordToolRefreshFailure(self, server, current, decision.may_serve_snapshot, err);
            return decision.may_serve_snapshot;
        };
    if (fetched.auth_identity == null and
        server.config.transport == .http and
        server.legacy_http == null)
    {
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;
        recordToolRefreshFailure(
            self,
            server,
            current,
            decision.may_serve_snapshot,
            error.McpMissingAuthIdentity,
        );
        return decision.may_serve_snapshot;
    }
    const subscription_identity = if (server.tool_subscription) |subscription|
        subscription.identity()
    else
        null;
    server.connection_lock.unlockShared(io_mod.getIo());
    connection_locked = false;

    try operation_access.refreshAndAuthorize(access_target);

    try lockMutexUntil(&self.catalog_update_mutex, deadline, cancel_flag);
    defer self.catalog_update_mutex.unlock(io_mod.getIo());
    var used_tool_names = std.StringHashMap(void).init(self.alloc);
    defer used_tool_names.deinit();
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    for (self.servers.items, 0..) |candidate_server, candidate_index| {
        if (candidate_index == server_index) continue;
        for (candidate_server.tool_catalog.tools.items) |tool| {
            used_tool_names.put(tool.prefixed_name, {}) catch {
                self.catalog_mutex.unlockShared(io_mod.getIo());
                return error.OutOfMemory;
            };
        }
    }
    self.catalog_mutex.unlockShared(io_mod.getIo());

    const protocol: StdioProtocol = if (std.mem.eql(
        u8,
        server.negotiated_protocol_version,
        modern_protocol_version,
    ))
        .modern
    else
        .legacy;
    var replacement = try buildProtocolTools(
        self.alloc,
        server,
        self.tool_registry,
        fetched.catalog.tools,
        &used_tool_names,
        protocol,
    );
    defer replacement.deinit(self.alloc);
    replacement.metadata = .{
        .key = replacement_key,
        .connection_generation = current.connection_generation,
        .catalog_generation = current.catalog_generation,
        .fetched_at_ms = fetched.catalog.fetched_at_ms,
        .expires_at_ms = fetched.catalog.expires_at_ms,
        .scope = scope,
        .content_digest = digestMcpTools(replacement.tools.items),
        .subscription = subscription_identity,
    };

    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    if (server.connection_generation != current.connection_generation) {
        try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
        defer self.catalog_mutex.unlockShared(io_mod.getIo());
        refresh_finished = true;
        return serverCatalogAvailable(server);
    }

    var catalog_commit_locked = false;
    defer if (catalog_commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    catalog_commit_locked = true;

    var auth_locked = false;
    defer if (auth_locked) server.auth_lock.unlock(io_mod.getIo());
    const active_key = if (scope == .private and server.config.transport != .stdio) active: {
        try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
        auth_locked = true;
        break :active cacheKeyWithAuthIdentity(
            server,
            scope,
            try currentAuthIdentity(self.alloc, server),
        );
    } else replacement_key;

    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    const latest = server.tool_catalog.metadata orelse {
        self.catalog_mutex.unlock(io_mod.getIo());
        return false;
    };
    const transition = feature_cache.authorizeReplacement(
        latest,
        current.connection_generation,
        current.catalog_generation,
        active_key,
        replacement.metadata.?.key,
        replacement.metadata.?.content_digest,
    );
    switch (transition) {
        .reject_stale_generation => {
            const snapshot_available = serverCatalogAvailable(server);
            self.catalog_mutex.unlock(io_mod.getIo());
            if (auth_locked) {
                server.auth_lock.unlock(io_mod.getIo());
                auth_locked = false;
            }
            server.catalog_commit_lock.unlock(io_mod.getIo());
            catalog_commit_locked = false;
            refresh_finished = true;
            debug_trace.logf(
                "mcp",
                "rejected stale tool refresh server={s} source_connection_generation={d} source_catalog_generation={d}",
                .{ server.config.name, current.connection_generation, current.catalog_generation },
            );
            return snapshot_available;
        },
        .reject_cache_key => {
            self.catalog_mutex.unlock(io_mod.getIo());
            if (auth_locked) {
                server.auth_lock.unlock(io_mod.getIo());
                auth_locked = false;
            }
            server.catalog_commit_lock.unlock(io_mod.getIo());
            catalog_commit_locked = false;
            refresh_finished = true;
            recordToolRefreshFailure(
                self,
                server,
                current,
                decision.may_serve_snapshot,
                error.McpAuthIdentityChangedDuringPagination,
            );
            return decision.may_serve_snapshot;
        },
        .metadata_only => {
            replacement.metadata.?.catalog_generation = latest.catalog_generation;
            replacement.metadata.?.connection_generation = latest.connection_generation;
            server.tool_catalog.metadata = replacement.metadata;
            server.tool_catalog.auth_generation = server.auth_generation.load(.acquire);
            server.tool_catalog.available = true;
            server.setReady(self.alloc);
            if (server.tool_subscription) |subscription| {
                subscription.clearInvalidationThrough(invalidation_generation);
            }
            const catalog_generation = replacement.metadata.?.catalog_generation;
            const fetched_at_ms = replacement.metadata.?.fetched_at_ms;
            const expires_at_ms = replacement.metadata.?.expires_at_ms;
            const notification_stats: tool_subscription.State.NotificationStats = if (server.tool_subscription) |subscription|
                subscription.notificationStats()
            else
                .{ .seen = 0, .coalesced = 0 };
            self.catalog_mutex.unlock(io_mod.getIo());
            if (auth_locked) {
                server.auth_lock.unlock(io_mod.getIo());
                auth_locked = false;
            }
            server.catalog_commit_lock.unlock(io_mod.getIo());
            catalog_commit_locked = false;
            refresh_finished = true;
            debug_trace.logf(
                "mcp",
                "tool cache refreshed without schema change server={s} catalog_generation={d} fetched_at_ms={d} expiry_ms={d} notifications_seen={d} notifications_coalesced={d}",
                .{
                    server.config.name,
                    catalog_generation,
                    fetched_at_ms,
                    expires_at_ms,
                    notification_stats.seen,
                    notification_stats.coalesced,
                },
            );
            return true;
        },
        .replace_snapshot => {
            const next_catalog_generation = std.math.add(
                u64,
                latest.catalog_generation,
                1,
            ) catch {
                self.catalog_mutex.unlock(io_mod.getIo());
                return error.McpGenerationExhausted;
            };
            replacement.metadata.?.catalog_generation = next_catalog_generation;
            replacement.metadata.?.connection_generation = latest.connection_generation;
            replacement.auth_generation = server.auth_generation.load(.acquire);
            var retired = server.tool_catalog;
            server.tool_catalog = replacement;
            replacement = .{};
            server.catalog_generation = next_catalog_generation;
            server.setReady(self.alloc);
            if (server.tool_subscription) |subscription| {
                subscription.clearInvalidationThrough(invalidation_generation);
            }
            const tool_count = server.tool_catalog.tools.items.len;
            const notification_stats: tool_subscription.State.NotificationStats = if (server.tool_subscription) |subscription|
                subscription.notificationStats()
            else
                .{ .seen = 0, .coalesced = 0 };
            self.catalog_mutex.unlock(io_mod.getIo());
            if (auth_locked) {
                server.auth_lock.unlock(io_mod.getIo());
                auth_locked = false;
            }
            server.catalog_commit_lock.unlock(io_mod.getIo());
            catalog_commit_locked = false;
            refresh_finished = true;
            retired.deinit(self.alloc);
            debug_trace.logf(
                "mcp",
                "tool cache snapshot replaced server={s} catalog_generation={d} tools={d} notifications_seen={d} notifications_coalesced={d}",
                .{
                    server.config.name,
                    next_catalog_generation,
                    tool_count,
                    notification_stats.seen,
                    notification_stats.coalesced,
                },
            );
            return true;
        },
    }
}

fn recordToolRefreshFailure(
    self: *McpRuntime,
    server: *McpServer,
    source: feature_cache.SnapshotMetadata,
    may_serve_snapshot: bool,
    err: anyerror,
) void {
    self.catalog_mutex.lockUncancelable(io_mod.getIo());
    defer self.catalog_mutex.unlock(io_mod.getIo());
    const current = server.tool_catalog.metadata orelse return;
    if (current.connection_generation != source.connection_generation or
        current.catalog_generation != source.catalog_generation)
    {
        return;
    }
    server.tool_catalog.metadata = feature_cache.failedRefresh(current, clockMillis());
    server.tool_catalog.available = may_serve_snapshot;
    debug_trace.logf(
        "mcp",
        "tool cache refresh failed server={s} freshness=failed_refresh retry_at_ms={d} preserved_tools={d} err={s}",
        .{
            server.config.name,
            server.tool_catalog.metadata.?.retry_at_ms,
            server.tool_catalog.tools.items.len,
            @errorName(err),
        },
    );
}

fn currentCacheKey(
    alloc: Allocator,
    server: *McpServer,
    scope: feature_cache.CacheScope,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    auth_access: AuthEffectAccess,
) !feature_cache.CacheKey {
    const auth_identity = if (scope == .private and server.config.transport != .stdio) identity: {
        break :identity try currentAuthIdentityForAccess(
            alloc,
            server,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = lifecycleCancelFlag(server),
            },
            auth_access,
        );
    } else feature_cache.authIdentity(&.{});
    return cacheKeyWithAuthIdentity(server, scope, auth_identity);
}

fn cacheKeyWithAuthIdentity(
    server: *const McpServer,
    scope: feature_cache.CacheScope,
    auth_identity: feature_cache.Digest,
) feature_cache.CacheKey {
    return feature_cache.buildCacheKey(.{
        .server_identity = server.config.name,
        .protocol_version = if (server.negotiated_protocol_version.len > 0)
            server.negotiated_protocol_version
        else if (server.stdio_protocol == .modern)
            modern_protocol_version
        else
            legacy_protocol_version,
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = scope,
        .auth_identity = auth_identity,
    });
}

const FetchedToolCatalog = struct {
    catalog: tools_feature.Catalog,
    auth_identity: ?feature_cache.Digest = null,

    fn deinit(self: *FetchedToolCatalog, alloc: Allocator) void {
        self.catalog.deinit(alloc);
        self.* = undefined;
    }
};

fn fetchCurrentToolCatalog(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !FetchedToolCatalog {
    return switch (server.config.transport) {
        .stdio => .{
            .catalog = try fetchStdioToolCatalog(
                self,
                server,
                deadline,
                cancel_flag,
                access,
            ),
        },
        .http => if (server.legacy_http) |client| legacy: {
            const auth_identity = try authIdentityForHeaders(self.alloc, client.static_headers);
            break :legacy .{
                .catalog = try fetchLegacyHttpToolCatalog(
                    self.alloc,
                    server,
                    client,
                    deadline,
                    cancel_flag,
                    access,
                ),
                .auth_identity = auth_identity,
            };
        } else fetchModernHttpToolCatalog(self, server, deadline, cancel_flag, access),
        .sse => if (server.legacy_sse) |client| legacy: {
            const auth_identity = try authIdentityForHeaders(self.alloc, client.static_headers);
            break :legacy .{
                .catalog = try fetchLegacySseToolCatalog(
                    self.alloc,
                    server,
                    client,
                    deadline,
                    cancel_flag,
                    access,
                ),
                .auth_identity = auth_identity,
            };
        } else error.McpConnectionClosed,
    };
}

fn replaceOwnedCursor(
    alloc: Allocator,
    cursor: *?[]u8,
    next_cursor: ?[]const u8,
) !void {
    const replacement = if (next_cursor) |value|
        try alloc.dupe(u8, value)
    else
        null;
    if (cursor.*) |value| alloc.free(value);
    cursor.* = replacement;
}

fn fetchStdioToolCatalog(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !tools_feature.Catalog {
    const alloc = self.alloc;
    const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
    var builder = tools_feature.CatalogBuilder.init(
        alloc,
        featureProtocol(server.stdio_protocol),
    );
    defer builder.deinit(alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    while (true) {
        try reauthorizeOperation(
            self,
            access,
            .{ .tool_server = server.config.name },
        );
        const request_id = try dispatcher.reserveRequestId();
        const request = try buildToolsListRequest(alloc, request_id, server.stdio_protocol, cursor);
        defer alloc.free(request);
        var guard = ServerAccessPrecommit{
            .runtime = self,
            .target = .{ .tool_server = server.config.name },
            .access = access,
        };
        var precommit = guard.transport();
        const response = try dispatcher.request(
            alloc,
            request_id,
            request,
            mcp_discovery_response_frame_cap_bytes,
            .{
                .timeout_ms = server.config.operation_timeout_ms,
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = lifecycleCancelFlag(server),
                .precommit = &precommit,
            },
        );
        const received_at_ms = clockMillis();
        defer alloc.free(response);
        var page = try tools_feature.parseListPage(
            alloc,
            response,
            featureProtocol(server.stdio_protocol),
            .{},
        );
        defer page.deinit(alloc);
        try replaceOwnedCursor(alloc, &cursor, page.next_cursor);
        try builder.appendPage(alloc, &page, received_at_ms, .{});
        if (cursor == null) return builder.finish(alloc);
    }
}

const HttpRequestIds = union(enum) {
    server: *McpServer,
    local: *u64,

    fn next(self: *HttpRequestIds) !u64 {
        return switch (self.*) {
            .server => |server| reserveHttpRequestId(server),
            .local => |next_request_id| request_id: {
                const request_id = next_request_id.*;
                next_request_id.* = std.math.add(u64, request_id, 1) catch
                    return error.McpRequestIdExhausted;
                break :request_id request_id;
            },
        };
    }
};

fn fetchModernHttpToolCatalogWithIds(
    alloc: Allocator,
    runtime: *McpRuntime,
    server: *McpServer,
    request_ids: *HttpRequestIds,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !FetchedToolCatalog {
    var identity_restarts: u8 = 0;
    while (true) {
        return fetchModernHttpToolCatalogAttempt(
            alloc,
            runtime,
            server,
            request_ids,
            deadline,
            cancel_flag,
            access,
        ) catch |err| switch (err) {
            error.McpAuthIdentityChangedDuringPagination => {
                if (identity_restarts >= mcp_auth.max_scope_reauthorizations) {
                    return error.McpAuthenticationRetryLimit;
                }
                identity_restarts += 1;
                debug_trace.logf(
                    "mcp",
                    "restarting paginated tool fetch after auth identity change server={s} attempt={d}",
                    .{ server.config.name, identity_restarts },
                );
                continue;
            },
            else => |other| return other,
        };
    }
}

fn fetchModernHttpToolCatalogAttempt(
    alloc: Allocator,
    runtime: *McpRuntime,
    server: *McpServer,
    request_ids: *HttpRequestIds,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !FetchedToolCatalog {
    var builder = tools_feature.CatalogBuilder.init(alloc, .modern);
    defer builder.deinit(alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    var producing_identity: ?feature_cache.Digest = null;
    while (true) {
        try reauthorizeOperation(
            runtime,
            access,
            .{ .tool_server = server.config.name },
        );
        const request_id = try request_ids.next();
        const request = try buildToolsListRequest(alloc, request_id, .modern, cursor);
        defer alloc.free(request);
        var guard = ServerAccessPrecommit{
            .runtime = runtime,
            .target = .{ .tool_server = server.config.name },
            .access = access,
        };
        var precommit = guard.transport();
        var page_identity: feature_cache.Digest = undefined;
        var response = try authenticatedPost(alloc, alloc, server, .{
            .url = try server.config.remoteUrl(),
            .request_body = request,
            .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
            .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
            .precommit = &precommit,
            .control = .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = lifecycleCancelFlag(server),
            },
        }, .{
            .runtime = runtime,
            .access = access,
            .target = .{ .tool_server = server.config.name },
        }, .safe, &page_identity);
        const received_at_ms = clockMillis();
        defer response.deinit(alloc);
        if (producing_identity) |identity| {
            if (!std.mem.eql(u8, &identity, &page_identity)) {
                return error.McpAuthIdentityChangedDuringPagination;
            }
        } else {
            producing_identity = page_identity;
        }
        var page = try tools_feature.parseListPage(alloc, response.body, .modern, .{});
        defer page.deinit(alloc);
        try replaceOwnedCursor(alloc, &cursor, page.next_cursor);
        try builder.appendPage(alloc, &page, received_at_ms, .{});
        if (cursor == null) return .{
            .catalog = try builder.finish(alloc),
            .auth_identity = producing_identity,
        };
    }
}

fn fetchModernHttpToolCatalog(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !FetchedToolCatalog {
    var request_ids = HttpRequestIds{ .server = server };
    return fetchModernHttpToolCatalogWithIds(
        self.alloc,
        self,
        server,
        &request_ids,
        deadline,
        cancel_flag,
        access,
    );
}

fn fetchLegacyHttpToolCatalog(
    alloc: Allocator,
    server: *McpServer,
    client: *legacy_streamable_http.Client,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !tools_feature.Catalog {
    var builder = tools_feature.CatalogBuilder.init(alloc, .legacy);
    defer builder.deinit(alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    while (true) {
        try reauthorizeOperation(
            server.runtime.?,
            access,
            .{ .tool_server = server.config.name },
        );
        const request_id = try reserveHttpRequestId(server);
        const request = try buildToolsListRequest(alloc, request_id, .legacy, cursor);
        defer alloc.free(request);
        var guard = ServerAccessPrecommit{
            .runtime = server.runtime.?,
            .target = .{ .tool_server = server.config.name },
            .access = access,
        };
        var precommit = guard.transport();
        const response = try client.request(alloc, .{
            .request_id = request_id,
            .request_body = request,
            .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
            .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
            .precommit = &precommit,
            .control = .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = lifecycleCancelFlag(server),
            },
        });
        const received_at_ms = clockMillis();
        defer alloc.free(response);
        var page = try tools_feature.parseListPage(alloc, response, .legacy, .{});
        defer page.deinit(alloc);
        try replaceOwnedCursor(alloc, &cursor, page.next_cursor);
        try builder.appendPage(alloc, &page, received_at_ms, .{});
        if (cursor == null) return builder.finish(alloc);
    }
}

fn fetchLegacySseToolCatalog(
    alloc: Allocator,
    server: *McpServer,
    client: *legacy_http_sse.Client,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    access: tool_mcp_runtime.Access,
) !tools_feature.Catalog {
    var builder = tools_feature.CatalogBuilder.init(alloc, .legacy);
    defer builder.deinit(alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    while (true) {
        try reauthorizeOperation(
            server.runtime.?,
            access,
            .{ .tool_server = server.config.name },
        );
        const request_id = try reserveHttpRequestId(server);
        const request = try buildToolsListRequest(alloc, request_id, .legacy, cursor);
        defer alloc.free(request);
        var guard = ServerAccessPrecommit{
            .runtime = server.runtime.?,
            .target = .{ .tool_server = server.config.name },
            .access = access,
        };
        var precommit = guard.transport();
        const response = try client.request(
            alloc,
            request_id,
            request,
            mcp_discovery_response_frame_cap_bytes,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = lifecycleCancelFlag(server),
                .precommit = &precommit,
            },
        );
        const received_at_ms = clockMillis();
        defer alloc.free(response);
        var page = try tools_feature.parseListPage(alloc, response, .legacy, .{});
        defer page.deinit(alloc);
        try replaceOwnedCursor(alloc, &cursor, page.next_cursor);
        try builder.appendPage(alloc, &page, received_at_ms, .{});
        if (cursor == null) return builder.finish(alloc);
    }
}

fn renderAuthenticationRequired(
    alloc: Allocator,
    servers: []McpServer,
    access: *const OperationAccessGuard,
    query: []const u8,
) !?[]u8 {
    for (servers) |*server| {
        if (!access.allows(.{ .tool_server = server.config.name })) continue;
        if (!queryContainsCompleteIdentity(query, server.config.name)) continue;
        server.status_lock.lockUncancelable(io_mod.getIo());
        const failed = server.state == .failed;
        server.status_lock.unlock(io_mod.getIo());
        if (!failed) continue;
        const mode: enum { oauth, bearer_environment } = if (server.config.auth != null or
            server.auth_challenge_present.load(.acquire))
            .oauth
        else if (server.config.bearer_token_env != null)
            .bearer_environment
        else
            continue;

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(
            "{\"tools\":[],\"count\":0,\"authentication_required\":{\"server\":",
        );
        try writeEncodedJsonScalar(alloc, &out.writer, server.config.name);
        switch (mode) {
            .oauth => try out.writer.writeAll(
                ",\"interactive\":true,\"message\":\"Run /mcp auth for this server in an interactive fx session.\"",
            ),
            .bearer_environment => {
                try out.writer.writeAll(
                    ",\"interactive\":false,\"environment\":",
                );
                try writeEncodedJsonScalar(
                    alloc,
                    &out.writer,
                    server.config.bearer_token_env.?,
                );
                try out.writer.writeAll(
                    ",\"message\":\"Set this environment variable before starting fx.\"",
                );
            },
        }
        try out.writer.writeAll("}}");
        return try out.toOwnedSlice();
    }
    return null;
}

fn loadStoredCredentials(
    alloc: Allocator,
    server: *McpServer,
    control: ConnectionControl,
) !void {
    try checkConnectionControl(control);
    if (server.config.transport == .stdio or
        !server.config.allow_stored_credentials or
        server.auth_credentials != null)
    {
        return;
    }
    const auth = server.config.auth orelse mcp_contract.McpAuthConfig{};
    var credentials = if (control.cancel_flag) |cancel_flag|
        try mcp_auth_store.loadCancellable(
            alloc,
            server.config.name,
            try server.config.remoteUrl(),
            auth.resource,
            auth.issuer,
            cancel_flag,
        )
    else
        try mcp_auth_store.load(
            alloc,
            server.config.name,
            try server.config.remoteUrl(),
            auth.resource,
            auth.issuer,
        );
    errdefer if (credentials) |*owned| owned.deinit(alloc);
    try checkConnectionControl(control);
    server.auth_credentials = credentials;
    credentials = null;
    server.auth_credentials_present.store(
        server.auth_credentials != null,
        .release,
    );
}

const StdioCallOutcome = struct {
    generation: u64,
    protocol: StdioProtocol,
    response: ?[]u8 = null,
    failure: ?anyerror = null,
    legacy_terminal: ?LegacyDirectTerminal = null,
    connection_running: bool,
    request_started: bool,
    connection_lease_released: bool = false,

    fn finishLegacy(self: *StdioCallOutcome, alloc: Allocator, outcome: tool_mcp_runtime.ContinuationTerminal) void {
        const terminal = self.legacy_terminal orelse return;
        self.legacy_terminal = null;
        terminal.finish(alloc, outcome);
    }
};

fn callStdioToolOnce(
    runtime: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    dispatcher: *stdio_dispatcher.StdioDispatcher,
    snapshot: *const ToolCallSnapshot,
    arguments_json: []const u8,
    max_frame_bytes: usize,
    options: tool_mcp_runtime.CallOptions,
    deadline: std.Io.Clock.Timestamp,
) !StdioCallOutcome {
    const generation = dispatcher.connectionGeneration();
    const protocol = server.stdio_protocol;
    const request_id = dispatcher.reserveRequestId() catch |err| return .{
        .generation = generation,
        .protocol = protocol,
        .failure = err,
        .connection_running = dispatcher.isRunning(),
        .request_started = false,
    };
    const request_body = try buildToolCallRequestForProtocol(
        alloc,
        request_id,
        snapshot.original_name,
        arguments_json,
        protocol,
        if (options.progress != null)
            request_id
        else
            null,
        options.continuation,
        responderCapabilities(options.input_responder),
    );
    defer alloc.free(request_body);

    var tool_precommit = ToolPrecommit{
        .runtime = runtime,
        .server = server,
        .snapshot = snapshot,
        .deadline = deadline,
        .cancel_flag = options.cancel_flag,
        .access = options.access,
    };
    var transport_precommit = tool_precommit.transport();
    var request_started = false;
    var legacy_context: ?LegacyElicitationContext = if (protocol == .legacy)
        if (legacyWireForServer(server)) |wire|
            LegacyElicitationContext.initStdio(
                server,
                dispatcher,
                wire,
                options.input_responder,
                .{ .tools_call = snapshot.original_name },
                deadline,
                options.cancel_flag,
            )
        else
            null
    else
        null;
    var server_request_wait = StdioServerRequestWait{ .server = server };
    const server_request_sink = if (legacy_context) |*context| context.sink() else null;
    const response = dispatcher.request(
        alloc,
        request_id,
        request_body,
        max_frame_bytes,
        .{
            .timeout_ms = server.config.operation_timeout_ms,
            .deadline = deadline,
            .cancel_flag = options.cancel_flag,
            .lifecycle_cancel_flag = &runtime.retiring,
            .progress = options.progress,
            .response_observer = if (legacy_context) |*context| context.responseObserver() else null,
            .server_requests = server_request_sink,
            .deadline_gate = if (legacy_context) |*context| &context.deadline_gate else null,
            .server_request_wait = if (server_request_sink != null)
                .{ .context = &server_request_wait, .callback = StdioServerRequestWait.begin }
            else
                null,
            .request_started = &request_started,
            .precommit = &transport_precommit,
        },
    ) catch |err| return .{
        .generation = generation,
        .protocol = protocol,
        .failure = err,
        .legacy_terminal = if (legacy_context) |*context| context.directTerminal() else null,
        .connection_running = dispatcher.isRunning(),
        .request_started = request_started,
        .connection_lease_released = server_request_wait.released,
    };
    return .{
        .generation = generation,
        .protocol = protocol,
        .response = response,
        .legacy_terminal = if (legacy_context) |*context| context.directTerminal() else null,
        .connection_running = true,
        .request_started = true,
        .connection_lease_released = server_request_wait.released,
    };
}

fn connectServerCancellable(
    runtime: *McpRuntime,
    server: *McpServer,
    used_tool_names: *std.StringHashMap(void),
    cancel_requested: *std.atomic.Value(bool),
    timeout_override: ?std.Io.Duration,
) !void {
    const override_deadline = if (timeout_override) |timeout|
        startupDeadline(
            std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
            server.config.startup_timeout_ms,
            timeout,
        )
    else
        null;
    return connectServerForDiscovery(
        runtime,
        server,
        used_tool_names,
        .{
            .deadline = override_deadline,
            .cancel_flag = cancel_requested,
            .lifecycle_cancel_flag = &runtime.retiring,
            .use_startup_timeout = timeout_override == null,
        },
    ) catch |err| switch (err) {
        error.McpRequestTimedOut => error.McpConnectionTimedOut,
        else => err,
    };
}

fn startupTimeout(
    configured_timeout_ms: u32,
    test_override: ?std.Io.Duration,
) std.Io.Duration {
    return test_override orelse saturatingDurationFromMilliseconds(configured_timeout_ms);
}

fn saturatingDurationFromMilliseconds(milliseconds: u64) std.Io.Duration {
    const nanoseconds = std.math.mul(
        i96,
        @as(i96, @intCast(milliseconds)),
        std.time.ns_per_ms,
    ) catch std.math.maxInt(i96);
    return .{ .nanoseconds = nanoseconds };
}

fn startupDeadline(
    now: std.Io.Clock.Timestamp,
    configured_timeout_ms: u32,
    test_override: ?std.Io.Duration,
) std.Io.Clock.Timestamp {
    const duration = startupTimeout(configured_timeout_ms, test_override);
    const nanoseconds = std.math.add(
        i96,
        now.raw.nanoseconds,
        duration.nanoseconds,
    ) catch std.math.maxInt(i96);
    return .{
        .clock = now.clock,
        .raw = .{ .nanoseconds = nanoseconds },
    };
}

fn connectionAttemptControl(
    control: ConnectionControl,
    configured_timeout_ms: u32,
) ConnectionControl {
    if (!control.use_startup_timeout) return control;
    var attempt = control;
    attempt.deadline = startupDeadline(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        configured_timeout_ms,
        null,
    );
    attempt.use_startup_timeout = false;
    return attempt;
}

fn connectServerForDiscovery(
    runtime: *McpRuntime,
    server: *McpServer,
    used_tool_names: *std.StringHashMap(void),
    control: ConnectionControl,
) !void {
    loadStoredCredentials(runtime.alloc, server, control) catch |err| {
        if (err == error.Cancelled) return err;
        debug_trace.logf(
            "mcp",
            "credential load failed server={s} err={s}",
            .{ server.config.name, @errorName(err) },
        );
        server.setFailed(
            runtime.alloc,
            "Stored MCP credentials could not be read securely.",
        );
        return err;
    };
    return if (server.config.transport == .stdio)
        runtime.connectServerBounded(server, used_tool_names, control)
    else
        connectServer(
            runtime.alloc,
            server,
            runtime.tool_registry,
            used_tool_names,
            control,
        );
}

fn connectServer(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *std.StringHashMap(void),
    control: ConnectionControl,
) !void {
    server.owner_alloc = alloc;
    try checkConnectionControl(control);
    if (server.last_error) |old| {
        alloc.free(old);
        server.last_error = null;
    }
    if (server.instructions) |old| {
        alloc.free(old);
        server.instructions = null;
    }
    switch (server.config.transport) {
        .sse => {
            const attempt_control = connectionAttemptControl(
                control,
                server.config.startup_timeout_ms,
            );
            try checkConnectionControl(attempt_control);
            _ = refreshSharedCredentials(alloc, server, .{
                .deadline = attempt_control.deadline.?,
                .cancel_flag = attempt_control.cancel_flag,
                .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
            }) catch |err| {
                removeServerToolNames(used_tool_names, server);
                clearServerTools(alloc, server);
                return err;
            };
            return connectServerSse(
                alloc,
                server,
                tool_registry,
                used_tool_names,
                attempt_control,
            );
        },
        .http => return connectServerHttp(alloc, server, tool_registry, used_tool_names, control),
        .stdio => {},
    }
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    try checkConnectionControl(attempt_control);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, try server.config.stdioCommand());
    for (server.config.args) |arg| try argv.append(alloc, arg);

    if (server.env_map) |*existing| {
        existing.deinit();
        server.env_map = null;
    }
    defer {
        if (server.env_map) |*environment| environment.deinit();
        server.env_map = null;
    }
    if (server.config.env.len > 0) {
        server.env_map = try io_mod.cloneEnvironMap(alloc);
        for (server.config.env) |entry| {
            try server.env_map.?.put(entry.key, entry.value);
        }
    }

    try spawnStdioServer(alloc, server, argv.items);
    errdefer server.disconnectForced();

    const dispatcher = server.dispatcher.?;
    const discover_id = try dispatcher.reserveRequestId();
    const discover_request = try buildDiscoverRequest(alloc, discover_id);
    defer alloc.free(discover_request);

    const discover_response = dispatcher.request(
        alloc,
        discover_id,
        discover_request,
        mcp_discovery_response_frame_cap_bytes,
        .{
            .timeout_ms = server.config.startup_timeout_ms,
            .deadline = attempt_control.deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
            .send_cancellation = false,
        },
    ) catch |err| switch (err) {
        error.McpRequestTimedOut,
        error.McpConnectionClosed,
        => {
            try checkConnectionControl(control);
            return connectServerLegacy(
                alloc,
                server,
                argv.items,
                tool_registry,
                used_tool_names,
                control,
                .v2024_11_05,
            );
        },
        else => return err,
    };
    defer alloc.free(discover_response);

    var parsed_discover = std.json.parseFromSlice(std.json.Value, alloc, discover_response, .{}) catch
        return error.McpInvalidJson;
    defer parsed_discover.deinit();

    switch (try classifyDiscoveryResponse(parsed_discover.value)) {
        .legacy_fallback => |version| return connectServerLegacy(
            alloc,
            server,
            argv.items,
            tool_registry,
            used_tool_names,
            control,
            version,
        ),
        .unsupported => {
            server.setFailed(alloc, "MCP server does not support protocol version " ++ modern_protocol_version);
            return error.McpUnsupportedProtocolVersion;
        },
        .modern_protocol_error => |protocol_error| {
            const diagnostic = try tool_result.format_protocol_error(alloc, protocol_error);
            defer alloc.free(diagnostic);
            server.setFailed(alloc, diagnostic);
            return error.McpProtocolError;
        },
        .modern => {},
    }

    server.stdio_protocol = .modern;
    server.negotiated_protocol_version = modern_protocol_version;
    const discovered_capabilities = try parseServerCapabilities(parsed_discover.value);
    server.tools_list_changed = discovered_capabilities.tools_list_changed;
    server.capabilities = discovered_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, discover_response);
    try parseAndStoreServerInstructionsForProtocol(alloc, server, discover_response, .modern);
    try discoverServerTools(
        alloc,
        server,
        tool_registry,
        used_tool_names,
        .modern,
        attempt_control,
    );
}

const ResolvedHeaderSet = struct {
    headers: []mcp_contract.McpHttpHeader = &.{},
    authorization: ?[]u8 = null,

    fn deinit(self: *ResolvedHeaderSet, alloc: Allocator) void {
        if (self.headers.len > 0) alloc.free(self.headers);
        if (self.authorization) |value| {
            @memset(value, 0);
            alloc.free(value);
        }
        self.* = .{};
    }
};

fn buildResolvedHeaders(alloc: Allocator, server: *McpServer) !ResolvedHeaderSet {
    if (server.auth_logout_in_progress.load(.acquire)) {
        return error.McpAuthorityChanged;
    }
    var headers: std.ArrayList(mcp_contract.McpHttpHeader) = .empty;
    defer headers.deinit(alloc);

    for (server.config.headers) |header| {
        try headers.append(alloc, .{
            .name = header.name,
            .value = header.value,
        });
    }
    for (server.config.header_env) |ref| {
        const value = io_mod.getenv(ref.env) orelse
            return error.McpHeaderEnvironmentMissing;
        try headers.append(alloc, .{
            .name = ref.name,
            .value = @constCast(value),
        });
    }

    const bearer = if (server.auth_credentials) |credentials|
        credentials.access_token
    else if (server.config.bearer_token_env) |env_name|
        io_mod.getenv(env_name) orelse return error.McpBearerEnvironmentMissing
    else
        null;
    const authorization = if (bearer) |token|
        try mcp_auth.bearerHeaderAlloc(alloc, token)
    else
        null;
    errdefer if (authorization) |value| {
        @memset(value, 0);
        alloc.free(value);
    };
    if (authorization) |value| {
        try headers.append(alloc, .{
            .name = @constCast("Authorization"),
            .value = value,
        });
    }
    try streamable_http.validateStaticHeaders(headers.items);

    return .{
        .headers = try headers.toOwnedSlice(alloc),
        .authorization = authorization,
    };
}

fn refreshResolvedHeaders(alloc: Allocator, server: *McpServer) !void {
    var resolved = try buildResolvedHeaders(alloc, server);
    errdefer resolved.deinit(alloc);
    freeResolvedHeaders(alloc, server);
    server.resolved_headers = resolved.headers;
    server.resolved_authorization = resolved.authorization;
    resolved = .{};
}

fn freeResolvedHeaders(alloc: Allocator, server: *McpServer) void {
    if (server.resolved_headers.len > 0) alloc.free(server.resolved_headers);
    server.resolved_headers = &.{};
    if (server.resolved_authorization) |value| {
        @memset(value, 0);
        alloc.free(value);
    }
    server.resolved_authorization = null;
}

fn checkConnectionControl(control: ConnectionControl) !void {
    if (control.cancellation().cancelled()) return error.Cancelled;
    if (control.deadline) |deadline| {
        return checkOperationControl(io_mod.getIo(), deadline, control.cancel_flag);
    }
}

fn lifecycleCancelFlag(
    server: *const McpServer,
) ?*const std.atomic.Value(bool) {
    return if (server.runtime) |runtime| &runtime.retiring else null;
}

fn spawnStdioServer(alloc: Allocator, server: *McpServer, argv: []const []const u8) !void {
    const generation = server.next_generation;
    server.next_generation = std.math.add(u64, generation, 1) catch
        return error.McpGenerationExhausted;
    var prepared = try docker_run.prepare(alloc, argv);
    defer prepared.deinit(alloc);
    var docker_cleanup = prepared.takeCleanup();
    defer if (docker_cleanup) |*cleanup| cleanup.deinit(alloc);
    if (docker_cleanup) |*cleanup| {
        if (server.env_map) |*environment| {
            try cleanup.cloneEnvironment(alloc, environment);
        }
    }
    const child = try std.process.spawn(io_mod.getIo(), .{
        .argv = prepared.argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = if (server.env_map != null) &server.env_map.? else null,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });

    server.dispatcher = stdio_dispatcher.StdioDispatcher.create(
        alloc,
        std.heap.c_allocator,
        child,
        generation,
        mcp_discovery_response_frame_cap_bytes,
    ) catch |err| {
        if (docker_cleanup) |*cleanup| cleanup.run(alloc);
        return err;
    };
    if (docker_cleanup) |cleanup| {
        server.dispatcher.?.installDockerCleanup(cleanup);
        docker_cleanup = null;
    }
}

fn connectServerLegacy(
    alloc: Allocator,
    server: *McpServer,
    argv: []const []const u8,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *std.StringHashMap(void),
    control: ConnectionControl,
    initial_version: LegacyStdioVersion,
) !void {
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    var offered_version = initial_version;
    const initialized: LegacyInitializeSuccess = while (true) {
        server.disconnectForced();
        try checkConnectionControl(attempt_control);
        try spawnStdioServer(alloc, server, argv);
        server.stdio_protocol = .legacy;

        const dispatcher = server.dispatcher.?;
        const init_id = try dispatcher.reserveRequestId();
        const init_request = try buildLegacyInitializeRequest(
            alloc,
            init_id,
            offered_version.string(),
            offered_version.wire(),
            if (server.runtime) |runtime| runtime.legacy_elicitation_capabilities else .{},
        );
        defer alloc.free(init_request);

        const init_response = dispatcher.request(
            alloc,
            init_id,
            init_request,
            mcp_discovery_response_frame_cap_bytes,
            .{
                .timeout_ms = server.config.startup_timeout_ms,
                .deadline = attempt_control.deadline,
                .cancel_flag = attempt_control.cancel_flag,
                .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                .send_cancellation = false,
            },
        ) catch |err| switch (err) {
            error.McpConnectionClosed => switch (decideLegacyInitializeTransition(
                offered_version,
                .connection_closed,
            )) {
                .retry => |next_version| {
                    offered_version = next_version;
                    continue;
                },
                .accept => unreachable,
                .fail => {
                    server.state = .failed;
                    return error.McpInitFailed;
                },
            },
            error.Cancelled, error.McpRequestTimedOut => {
                server.state = .failed;
                return err;
            },
            else => {
                server.state = .failed;
                return error.McpInitFailed;
            },
        };

        const observation = observation: {
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, init_response, .{}) catch {
                alloc.free(init_response);
                return error.McpInvalidJson;
            };
            defer parsed.deinit();
            break :observation classifyLegacyInitializeResponse(
                parsed.value,
                offered_version,
            ) catch |err| {
                alloc.free(init_response);
                return err;
            };
        };
        switch (decideLegacyInitializeTransition(offered_version, observation)) {
            .accept => |negotiated_version| break .{
                .owned_response = init_response,
                .version = negotiated_version,
            },
            .retry => |next_version| {
                alloc.free(init_response);
                offered_version = next_version;
                continue;
            },
            .fail => {
                alloc.free(init_response);
                server.state = .failed;
                return error.McpUnsupportedProtocolVersion;
            },
        }
    };
    defer alloc.free(initialized.owned_response);
    server.negotiated_protocol_version = initialized.version.string();
    const initialized_capabilities = try parseServerCapabilitiesFromResponse(
        alloc,
        initialized.owned_response,
    );
    server.tools_list_changed = initialized_capabilities.tools_list_changed;
    server.capabilities = initialized_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, initialized.owned_response);
    try parseAndStoreServerInstructions(alloc, server, initialized.owned_response);

    const dispatcher = server.dispatcher.?;
    const initialized_notification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
    try dispatcher.sendNotificationWithLifecycleControl(
        initialized_notification,
        server.config.startup_timeout_ms,
        attempt_control.deadline,
        attempt_control.cancel_flag,
        attempt_control.lifecycle_cancel_flag,
    );

    try discoverServerTools(
        alloc,
        server,
        tool_registry,
        used_tool_names,
        .legacy,
        attempt_control,
    );
}

fn discoverServerTools(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *std.StringHashMap(void),
    protocol: StdioProtocol,
    control: ConnectionControl,
) !void {
    const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
    var builder = tools_feature.CatalogBuilder.init(alloc, featureProtocol(protocol));
    defer builder.deinit(alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    while (true) {
        const request_id = try dispatcher.reserveRequestId();
        const tools_request = try buildToolsListRequest(alloc, request_id, protocol, cursor);
        defer alloc.free(tools_request);
        const tools_response = dispatcher.request(
            alloc,
            request_id,
            tools_request,
            mcp_discovery_response_frame_cap_bytes,
            .{
                .timeout_ms = server.config.startup_timeout_ms,
                .deadline = control.deadline,
                .cancel_flag = control.cancel_flag,
                .lifecycle_cancel_flag = control.lifecycle_cancel_flag,
                .send_cancellation = false,
            },
        ) catch |err| {
            server.state = .failed;
            return switch (err) {
                error.Cancelled, error.McpRequestTimedOut => err,
                else => error.McpToolDiscoveryFailed,
            };
        };
        const received_at_ms = clockMillis();
        defer alloc.free(tools_response);
        var page = try tools_feature.parseListPage(alloc, tools_response, featureProtocol(protocol), .{});
        defer page.deinit(alloc);
        if (cursor) |value| alloc.free(value);
        cursor = if (page.next_cursor) |value| try alloc.dupe(u8, value) else null;
        try builder.appendPage(alloc, &page, received_at_ms, .{});
        if (cursor == null) break;
    }
    var catalog = try builder.finish(alloc);
    defer catalog.deinit(alloc);
    try storeProtocolTools(alloc, server, tool_registry, catalog, used_tool_names, protocol, null);
    try startToolSubscription(alloc, server, control);
    server.setReady(alloc);
}

fn mcpResponseFrameCap(max_tool_result_bytes: usize) usize {
    // JSON-RPC and MCP content wrappers add bytes around the model-facing result.
    // Keep the transport cap close to the configured result cap while allowing
    // normal envelope overhead before the model-facing truncation pass runs.
    return std.math.add(usize, max_tool_result_bytes, mcp_response_frame_overhead_bytes) catch std.math.maxInt(usize);
}

const LegacyInitializeSuccess = struct {
    owned_response: []u8,
    version: LegacyStdioVersion,
};

fn parseToolsListChangedCapabilityFromResponse(
    alloc: Allocator,
    response: []const u8,
) !bool {
    return (try parseServerCapabilitiesFromResponse(alloc, response)).tools_list_changed;
}

const ParsedServerCapabilities = struct {
    tools_list_changed: bool = false,
    features: ServerCapabilities = .{},
};

fn parseServerCapabilitiesFromResponse(
    alloc: Allocator,
    response: []const u8,
) !ParsedServerCapabilities {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch
        return error.McpInvalidJson;
    defer parsed.deinit();
    return parseServerCapabilities(parsed.value);
}

fn parseAndStoreServerIdentity(
    alloc: Allocator,
    server: *McpServer,
    response: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch
        return error.McpInvalidJson;
    defer parsed.deinit();
    const identity = try parseServerIdentity(parsed.value);
    const name = if (identity.name) |value| try alloc.dupe(u8, value) else null;
    errdefer if (name) |value| alloc.free(value);
    const version = if (identity.version) |value| try alloc.dupe(u8, value) else null;
    if (server.negotiated_server_name) |old| alloc.free(old);
    if (server.negotiated_server_version) |old| alloc.free(old);
    server.negotiated_server_name = name;
    server.negotiated_server_version = version;
}

const ParsedServerIdentity = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

fn parseServerIdentity(value: std.json.Value) !ParsedServerIdentity {
    try mcp_contract.validateJsonRpcResponseEnvelope(value);
    const result = value.object.get("result") orelse return error.McpInvalidResult;
    if (result != .object) return error.McpInvalidResult;
    const info = blk: {
        if (result.object.get("_meta")) |meta| {
            if (meta != .object) return error.McpInvalidResult;
            if (meta.object.get("io.modelcontextprotocol/serverInfo")) |modern| {
                break :blk modern;
            }
        }
        break :blk result.object.get("serverInfo") orelse return .{};
    };
    if (info != .object) return error.McpInvalidResult;
    const name = if (info.object.get("name")) |field| blk: {
        if (field != .string) return error.McpInvalidResult;
        break :blk if (field.string.len > 0) field.string else null;
    } else null;
    const version = if (info.object.get("version")) |field| blk: {
        if (field != .string) return error.McpInvalidResult;
        break :blk if (field.string.len > 0) field.string else null;
    } else null;
    return .{ .name = name, .version = version };
}

fn parseToolsListChangedCapability(value: std.json.Value) !bool {
    return (try parseServerCapabilities(value)).tools_list_changed;
}

fn parseServerCapabilities(value: std.json.Value) !ParsedServerCapabilities {
    try mcp_contract.validateJsonRpcResponseEnvelope(value);
    if (value.object.contains("error")) return .{};
    const result = value.object.get("result") orelse return error.McpInvalidResult;
    if (result != .object) return error.McpInvalidResult;
    const capabilities = result.object.get("capabilities") orelse return .{};
    if (capabilities != .object) return error.McpInvalidResult;
    var parsed: ParsedServerCapabilities = .{};
    if (capabilities.object.get("tools")) |tools| {
        if (tools != .object) return error.McpInvalidResult;
        parsed.tools_list_changed = try optionalCapabilityBool(tools.object, "listChanged");
    }
    if (capabilities.object.get("resources")) |resources| {
        if (resources != .object) return error.McpInvalidResult;
        parsed.features.resources = true;
        parsed.features.resources_list_changed = try optionalCapabilityBool(resources.object, "listChanged");
        parsed.features.resources_subscribe = try optionalCapabilityBool(resources.object, "subscribe");
    }
    if (capabilities.object.get("prompts")) |prompts| {
        if (prompts != .object) return error.McpInvalidResult;
        parsed.features.prompts = true;
        parsed.features.prompts_list_changed = try optionalCapabilityBool(prompts.object, "listChanged");
    }
    if (capabilities.object.get("completions")) |completions| {
        if (completions != .object) return error.McpInvalidResult;
        parsed.features.completion = true;
    }
    return parsed;
}

fn optionalCapabilityBool(object: std.json.ObjectMap, name: []const u8) !bool {
    const value = object.get(name) orelse return false;
    if (value != .bool) return error.McpInvalidResult;
    return value.bool;
}

fn parseAndStoreServerInstructions(alloc: Allocator, server: *McpServer, response: []const u8) !void {
    return parseAndStoreServerInstructionsForProtocol(alloc, server, response, .legacy);
}

fn parseAndStoreServerInstructionsForProtocol(
    alloc: Allocator,
    server: *McpServer,
    response: []const u8,
    protocol: StdioProtocol,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch return error.McpInvalidJson;
    defer parsed.deinit();

    const payload = try classifyResponsePayload(parsed.value, protocol);
    const result = switch (payload) {
        .complete => |value| value,
        .protocol_error => |protocol_error| {
            const diagnostic = try tool_result.format_protocol_error(alloc, protocol_error);
            defer alloc.free(diagnostic);
            server.setFailed(alloc, diagnostic);
            return error.McpProtocolError;
        },
    };
    const instructions_value = result.object.get("instructions") orelse return;
    if (instructions_value != .string) return;

    const owned = try sanitizeServerInstructionsAlloc(alloc, instructions_value.string);
    errdefer alloc.free(owned);
    if (owned.len == 0) {
        alloc.free(owned);
        return;
    }

    if (server.instructions) |old| alloc.free(old);
    server.instructions = owned;
}

fn sanitizeServerInstructionsAlloc(alloc: Allocator, text: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const safe = try text_utils.sanitizeModelText(arena, text);
    const masked = try text_utils.maskSecrets(arena, safe);
    const trimmed = std.mem.trim(u8, masked, " \t\r\n");
    return try alloc.dupe(u8, trimmed);
}

fn parseAndStoreTools(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    response: []const u8,
    used_tool_names: *std.StringHashMap(void),
) !void {
    return parseAndStoreToolsForProtocol(alloc, server, tool_registry, response, used_tool_names, .legacy);
}

fn parseAndStoreToolsForProtocol(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    response: []const u8,
    used_tool_names: *std.StringHashMap(void),
    protocol: StdioProtocol,
) !void {
    const received_at_ms = clockMillis();
    var page = tools_feature.parseListPage(
        alloc,
        response,
        featureProtocol(protocol),
        .{},
    ) catch |err| {
        server.setFailed(alloc, @errorName(err));
        return err;
    };
    defer page.deinit(alloc);
    var builder = tools_feature.CatalogBuilder.init(alloc, featureProtocol(protocol));
    defer builder.deinit(alloc);
    try builder.appendPage(alloc, &page, received_at_ms, .{});
    var catalog = try builder.finish(alloc);
    defer catalog.deinit(alloc);
    try storeProtocolTools(
        alloc,
        server,
        tool_registry,
        catalog,
        used_tool_names,
        protocol,
        null,
    );
}

fn storeProtocolTools(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    protocol_catalog: tools_feature.Catalog,
    used_tool_names: *std.StringHashMap(void),
    protocol: StdioProtocol,
    source_auth_identity: ?feature_cache.Digest,
) !void {
    if (server.tool_catalog.tools.items.len != 0) return error.McpToolCatalogNotEmpty;
    const auth_identity = source_auth_identity orelse try currentAuthIdentity(alloc, server);
    var candidate = try buildProtocolTools(
        alloc,
        server,
        tool_registry,
        protocol_catalog.tools,
        used_tool_names,
        protocol,
    );
    errdefer candidate.deinit(alloc);
    const connection_generation = std.math.add(
        u64,
        server.connection_generation,
        1,
    ) catch return error.McpGenerationExhausted;
    const catalog_generation = std.math.add(
        u64,
        server.catalog_generation,
        1,
    ) catch return error.McpGenerationExhausted;
    const scope: feature_cache.CacheScope = switch (protocol_catalog.cache_scope) {
        .private => .private,
        .public => .public,
    };
    candidate.metadata = .{
        .key = cacheKeyWithAuthIdentity(server, scope, auth_identity),
        .connection_generation = connection_generation,
        .catalog_generation = catalog_generation,
        .fetched_at_ms = protocol_catalog.fetched_at_ms,
        .expires_at_ms = protocol_catalog.expires_at_ms,
        .scope = scope,
        .content_digest = digestMcpTools(candidate.tools.items),
    };
    candidate.auth_generation = server.auth_generation.load(.acquire);
    server.connection_generation = connection_generation;
    server.catalog_generation = catalog_generation;
    server.tool_catalog = candidate;
    candidate = .{};
}

fn buildProtocolTools(
    alloc: Allocator,
    server: *const McpServer,
    tool_registry: tool_dispatch.Registry,
    protocol_tools: []const tools_feature.Tool,
    used_tool_names: *std.StringHashMap(void),
    protocol: StdioProtocol,
) !ToolCatalogSnapshot {
    var result: ToolCatalogSnapshot = .{};
    errdefer {
        for (result.tools.items) |tool| _ = used_tool_names.remove(tool.prefixed_name);
        result.deinit(alloc);
    }
    for (protocol_tools) |protocol_tool| {
        const name = protocol_tool.name;
        const description = if (protocol_tool.description.len > 0)
            protocol_tool.description
        else
            "MCP tool";

        const original_name = try alloc.dupe(u8, name);
        errdefer alloc.free(original_name);

        const prefixed_name = try allocateToolName(alloc, tool_registry, used_tool_names, server.config.name, name);
        errdefer alloc.free(prefixed_name);

        const owned_description = try alloc.dupe(u8, description);
        errdefer alloc.free(owned_description);

        const input_schema_json = try alloc.dupe(u8, protocol_tool.input_schema_json);
        errdefer alloc.free(input_schema_json);
        if (server.config.transport == .http and protocol == .modern) {
            streamable_http.validateToolInputSchemaHeaders(
                alloc,
                input_schema_json,
            ) catch |err| {
                debug_trace.logf(
                    "mcp",
                    "excluded modern HTTP tool server={s} tool={s} reason={s}",
                    .{ server.config.name, name, @errorName(err) },
                );
                alloc.free(input_schema_json);
                alloc.free(owned_description);
                alloc.free(prefixed_name);
                alloc.free(original_name);
                continue;
            };
        }

        const tags = try buildToolTags(alloc, server.config.name, name);
        errdefer freeOwnedStrings(alloc, tags);

        const title = if (protocol_tool.title) |value| try alloc.dupe(u8, value) else null;
        errdefer if (title) |value| alloc.free(value);
        const output_schema_json = if (protocol_tool.output_schema_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (output_schema_json) |value| alloc.free(value);
        const icons_json = if (protocol_tool.icons_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (icons_json) |value| alloc.free(value);
        const annotations_json = if (protocol_tool.annotations_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (annotations_json) |value| alloc.free(value);
        const metadata_json = if (protocol_tool.metadata_json) |value| try alloc.dupe(u8, value) else null;
        errdefer if (metadata_json) |value| alloc.free(value);

        try result.tools.ensureUnusedCapacity(alloc, 1);
        try used_tool_names.put(prefixed_name, {});
        result.tools.appendAssumeCapacity(.{
            .original_name = original_name,
            .prefixed_name = prefixed_name,
            .title = title,
            .description = owned_description,
            .input_schema_json = input_schema_json,
            .output_schema_json = output_schema_json,
            .icons_json = icons_json,
            .annotations_json = annotations_json,
            .metadata_json = metadata_json,
            .tags = tags,
        });
    }
    return result;
}

fn currentAuthIdentity(alloc: Allocator, server: *McpServer) !feature_cache.Digest {
    if (server.config.transport == .stdio) return feature_cache.authIdentity(&.{});
    var resolved = try buildResolvedHeaders(alloc, server);
    defer resolved.deinit(alloc);
    return authIdentityForHeaders(alloc, resolved.headers);
}

fn authIdentityForHeaders(
    alloc: Allocator,
    resolved: []const mcp_contract.McpHttpHeader,
) !feature_cache.Digest {
    const headers = try alloc.alloc(feature_cache.Header, resolved.len);
    defer alloc.free(headers);
    for (resolved, 0..) |header, index| {
        headers[index] = .{ .name = header.name, .value = header.value };
    }
    return feature_cache.authIdentity(headers);
}

fn digestMcpTools(tools: []const McpTool) feature_cache.Digest {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});
    for (tools) |tool| {
        hashToolField(&hasher, tool.original_name);
        hashToolField(&hasher, tool.prefixed_name);
        hashOptionalToolField(&hasher, tool.title);
        hashToolField(&hasher, tool.description);
        hashToolField(&hasher, tool.input_schema_json);
        hashOptionalToolField(&hasher, tool.output_schema_json);
        hashOptionalToolField(&hasher, tool.icons_json);
        hashOptionalToolField(&hasher, tool.annotations_json);
        hashOptionalToolField(&hasher, tool.metadata_json);
        for (tool.tags) |tag| hashToolField(&hasher, tag);
    }
    var result: feature_cache.Digest = undefined;
    hasher.final(&result);
    return result;
}

fn hashOptionalToolField(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: ?[]const u8,
) void {
    const present = [_]u8{@intFromBool(value != null)};
    hasher.update(&present);
    if (value) |bytes| hashToolField(hasher, bytes);
}

fn hashOptionalU64Field(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: ?u64,
) void {
    hasher.update(&.{@intFromBool(value != null)});
    if (value) |number| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, number, .big);
        hasher.update(&bytes);
    }
}

fn hashToolField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hasher.update(&length);
    hasher.update(value);
}

fn clockMillis() u64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    if (now.raw.nanoseconds <= 0) return 0;
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(u64, milliseconds) orelse std.math.maxInt(u64);
}

fn awakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

fn timestampMillis(timestamp: std.Io.Clock.Timestamp) i64 {
    const milliseconds = @divFloor(timestamp.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

fn operationDeadline(server: *const McpServer) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(server.config.operation_timeout_ms),
    });
}

fn elicitationDeadline() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(mcp_contract.default_elicitation_timeout_ms),
    });
}

fn subscriptionStartupDeadline(
    server: *const McpServer,
    operation_deadline: ?std.Io.Clock.Timestamp,
) std.Io.Clock.Timestamp {
    const startup_deadline = startupDeadline(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
        server.config.startup_timeout_ms,
        null,
    );
    const operation = operation_deadline orelse return startup_deadline;
    return if (std.Io.Clock.Timestamp.compare(operation, .lt, startup_deadline))
        operation
    else
        startup_deadline;
}

fn startToolSubscription(
    alloc: Allocator,
    server: *McpServer,
    control: ConnectionControl,
) !void {
    return startToolSubscriptionWithResources(alloc, server, &.{}, control);
}

fn startToolSubscriptionWithResources(
    alloc: Allocator,
    server: *McpServer,
    resource_subscriptions: []const []const u8,
    control: ConnectionControl,
) !void {
    if (server.tool_subscription != null) return;
    const subscription = try createToolSubscriptionWithResources(
        alloc,
        server,
        resource_subscriptions,
        control,
    ) orelse return;
    publishToolSubscription(server, subscription);
}

fn createToolSubscriptionWithResources(
    alloc: Allocator,
    server: *McpServer,
    resource_subscriptions: []const []const u8,
    control: ConnectionControl,
) !?*tool_subscription.State {
    const base_filters = tool_subscription.Filters{
        .tools_list_changed = server.tools_list_changed,
        .resources_list_changed = server.capabilities.resources_list_changed,
        .prompts_list_changed = server.capabilities.prompts_list_changed,
        .resource_subscriptions = if (server.capabilities.resources_subscribe)
            resource_subscriptions
        else
            &.{},
        .elicitation_complete = legacyWireForServer(server) == .legacy_mcp_2025_11 and
            server.runtime.?.legacy_elicitation_capabilities.url,
    };
    if (!base_filters.any()) return null;
    const subscription_generation = server.next_subscription_generation;
    server.next_subscription_generation = std.math.add(
        u64,
        subscription_generation,
        1,
    ) catch return error.McpGenerationExhausted;

    const subscription = switch (server.config.transport) {
        .stdio => subscription: {
            const dispatcher = server.dispatcher orelse return error.McpConnectionClosed;
            const protocol: feature_cache.Protocol = switch (server.stdio_protocol) {
                .modern => .modern,
                .legacy => .legacy,
                .unselected => return error.McpConnectionClosed,
            };
            const request_id = if (protocol == .modern)
                try dispatcher.reserveRequestId()
            else
                0;
            if (protocol == .legacy and base_filters.elicitation_complete) {
                break :subscription try tool_subscription.State.createLegacyStdioWithNotifications(
                    alloc,
                    dispatcher,
                    server.connection_generation,
                    subscription_generation,
                    base_filters,
                    legacyCompletionPassthrough(server, dispatcher.connectionGeneration()),
                );
            }
            break :subscription try tool_subscription.State.createStdio(
                alloc,
                dispatcher,
                protocol,
                server.connection_generation,
                request_id,
                subscription_generation,
                base_filters,
                if (protocol == .modern)
                    subscriptionStartupDeadline(server, control.deadline)
                else
                    null,
                if (protocol == .modern) control.cancel_flag else null,
            );
        },
        .http => subscription: {
            if (std.mem.eql(
                u8,
                server.negotiated_protocol_version,
                modern_protocol_version,
            )) {
                const runtime = server.runtime orelse return null;
                break :subscription try tool_subscription.State.createHttp(
                    alloc,
                    server.config.name,
                    .{
                        .context = runtime,
                        .callback = listenModernHttpToolSubscription,
                    },
                    server.connection_generation,
                    try reserveHttpRequestId(server),
                    subscription_generation,
                    base_filters,
                );
            }
            const client = server.legacy_http orelse return error.McpConnectionClosed;
            break :subscription try tool_subscription.State.createLegacyHttp(
                alloc,
                client,
                server.connection_generation,
                subscription_generation,
                base_filters,
                legacyCompletionPassthrough(server, server.connection_generation),
            );
        },
        .sse => subscription: {
            const client = server.legacy_sse orelse return error.McpConnectionClosed;
            break :subscription try tool_subscription.State.createLegacySse(
                alloc,
                client,
                server.connection_generation,
                subscription_generation,
                base_filters,
            );
        },
    };
    return subscription;
}

fn publishToolSubscription(
    server: *McpServer,
    subscription: *tool_subscription.State,
) void {
    server.tool_subscription = subscription;
    if (server.tool_catalog.metadata) |*metadata| {
        metadata.subscription = subscription.identity();
    }
    if (server.resource_catalog.metadata) |*metadata| {
        metadata.subscription = subscription.identity();
    }
    if (server.resource_template_catalog.metadata) |*metadata| {
        metadata.subscription = subscription.identity();
    }
    if (server.prompt_catalog.metadata) |*metadata| {
        metadata.subscription = subscription.identity();
    }
    debug_trace.logf(
        "mcp",
        "MCP subscription started server={s} connection_generation={d} subscription_generation={d}",
        .{ server.config.name, server.connection_generation, subscription.identity().generation },
    );
}

fn legacyCompletionPassthrough(
    server: *McpServer,
    client_generation: u64,
) tool_subscription.NotificationPassthrough {
    return .{
        .context = @ptrCast(server.runtime.?),
        .source = .{
            .server_name = server.config.name,
            .connection_generation = server.connection_generation,
            .client_generation = client_generation,
            .auth_generation = server.auth_generation.load(.acquire),
        },
        .callback = handleLegacyCompletionNotification,
    };
}

fn handleLegacyCompletionNotification(
    raw_context: *anyopaque,
    source: tool_subscription.NotificationSource,
    value: std.json.Value,
) void {
    const runtime: *McpRuntime = @ptrCast(@alignCast(raw_context));
    routeLegacyCompletionNotification(runtime, source, value);
}

fn routeLegacyCompletionNotification(
    runtime: *McpRuntime,
    source: tool_subscription.NotificationSource,
    value: std.json.Value,
) void {
    const notification = elicitation.classifyLegacyUrlCompletionNotification(value, .{}) orelse return;
    const sink = runtime.legacy_url_completion_sink;
    const publication = publication: {
        runtime.catalog_mutex.lockSharedUncancelable(io_mod.getIo());
        defer runtime.catalog_mutex.unlockShared(io_mod.getIo());
        runtime.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
        defer runtime.legacy_url_waiter_mutex.unlock(io_mod.getIo());
        const completion = LegacyUrlWireCompletionIdentity{
            .server_name = source.server_name,
            .elicitation_id = notification.elicitation_id,
            .runtime_generation = runtime.legacy_url_runtime_generation,
            .connection_generation = source.connection_generation,
            .client_generation = source.client_generation,
            .auth_generation = source.auth_generation,
        };
        switch (runtime.legacyCompletionSourceStateLocked(
            source.server_name,
            runtime.legacy_url_runtime_generation,
            source.connection_generation,
            source.client_generation,
            source.auth_generation,
        )) {
            .stale => break :publication null,
            .logout_fenced => {
                runtime.journalEarlyLegacyUrlCompletionLocked(completion, true);
                break :publication null;
            },
            .current => {},
        }
        const recorded = runtime.recordLegacyUrlCompletionFromWireLocked(completion);
        if (recorded) runtime.markWireLegacyUrlCompletionHandledLocked(completion);
        const consumer = sink orelse {
            if (!recorded) runtime.journalEarlyLegacyUrlCompletionLocked(completion, false);
            break :publication null;
        };
        break :publication switch (consumer.consume(consumer.context, .{
            .server_name = completion.server_name,
            .elicitation_id = completion.elicitation_id,
            .runtime_generation = completion.runtime_generation,
            .connection_generation = completion.connection_generation,
            .client_generation = completion.client_generation,
            .auth_generation = completion.auth_generation,
        })) {
            .missing => missing: {
                if (!recorded) runtime.journalEarlyLegacyUrlCompletionLocked(completion, false);
                break :missing null;
            },
            .consumed => |id| consumed: {
                if (!recorded) runtime.markWireLegacyUrlCompletionHandledLocked(completion);
                break :consumed id;
            },
        };
    };
    if (publication) |id| sink.?.publish(sink.?.context, id);
}

fn recoverFinishedToolSubscription(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    const reason = try takeFinishedToolSubscription(
        server,
        deadline,
        cancel_flag,
        true,
    ) orelse return;
    switch (reason) {
        .unsupported, .cancelled => return,
        .authentication_required => {
            const control = streamable_http.Control{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = &self.retiring,
            };
            try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
            var has_legacy = false;
            var capture_error: ?anyerror = null;
            if (server.legacy_http) |client| {
                has_legacy = true;
                captureLegacyStreamableAuth(
                    self.alloc,
                    server,
                    client,
                    control,
                ) catch |err| {
                    capture_error = err;
                };
            } else if (server.legacy_sse) |client| {
                has_legacy = true;
                captureLegacySseAuth(
                    self.alloc,
                    server,
                    client,
                    control,
                ) catch |err| {
                    capture_error = err;
                };
            }
            server.connection_lock.unlockShared(io_mod.getIo());
            if (capture_error) |err| return err;
            if (!has_legacy) return;
            if (!try authorizePendingChallengeIfAutomated(
                self.alloc,
                server,
                control,
            )) return;
            try reconnectLegacyForCredentials(self, server, deadline, cancel_flag);
        },
        .session_expired => {
            try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
            const client = server.legacy_http orelse {
                server.connection_lock.unlockShared(io_mod.getIo());
                return;
            };
            const version = client.version;
            server.connection_lock.unlockShared(io_mod.getIo());
            try recoverLegacyHttpSession(
                self,
                server,
                client,
                version,
                deadline,
                cancel_flag,
            );
        },
        .running, .closed => {
            var credentials_refreshed = false;
            if (server.config.transport != .stdio) {
                credentials_refreshed = try refreshSharedCredentials(
                    self.alloc,
                    server,
                    .{
                        .deadline = deadline,
                        .cancel_flag = cancel_flag,
                        .lifecycle_cancel_flag = &self.retiring,
                    },
                );
            }
            try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
            const has_legacy_sse = server.legacy_sse != null;
            const has_legacy_http = server.legacy_http != null;
            server.connection_lock.unlockShared(io_mod.getIo());
            if (has_legacy_sse) {
                try reconnectLegacyConnection(self, server, deadline, cancel_flag);
            } else if (credentials_refreshed and has_legacy_http) {
                try reconnectLegacyForCredentials(self, server, deadline, cancel_flag);
            } else {
                try startToolSubscriptionGuarded(
                    self.alloc,
                    server,
                    deadline,
                    cancel_flag,
                );
            }
        },
    }
    debug_trace.logf(
        "mcp",
        "tool subscription restarted after listener completion server={s}",
        .{server.config.name},
    );
}

fn takeFinishedToolSubscription(
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    retain_modern_auth_required: bool,
) !?tool_subscription.State.FinishReason {
    try lockMutexUntil(&server.subscription_lifecycle_lock, deadline, cancel_flag);
    defer server.subscription_lifecycle_lock.unlock(io_mod.getIo());
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    var commit_locked = true;
    defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
    const previous = server.tool_subscription orelse return null;
    if (!previous.isFinished()) return null;
    const observed_reason = previous.finishReason();
    debug_trace.logf(
        "mcp",
        "recovering finished tool subscription server={s} reason={s}",
        .{ server.config.name, @tagName(observed_reason) },
    );
    if (retain_modern_auth_required and
        observed_reason == .authentication_required and
        server.legacy_http == null and
        server.legacy_sse == null)
    {
        return observed_reason;
    }
    previous.requestStop();

    try lockRwUntil(&server.runtime.?.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) server.runtime.?.catalog_mutex.unlock(io_mod.getIo());
    if (server.tool_subscription != previous or !previous.isFinished()) return null;
    const reason = previous.finishReason();
    debug_trace.logf(
        "mcp",
        "detaching finished tool subscription server={s}",
        .{server.config.name},
    );
    const detached = server.detachToolSubscription() orelse return null;
    server.runtime.?.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    server.catalog_commit_lock.unlock(io_mod.getIo());
    commit_locked = false;
    detached.stopAndDestroy();
    return reason;
}

fn startToolSubscriptionGuarded(
    alloc: Allocator,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    try lockMutexUntil(&server.subscription_lifecycle_lock, deadline, cancel_flag);
    defer server.subscription_lifecycle_lock.unlock(io_mod.getIo());
    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    var candidate: ?*tool_subscription.State = null;
    defer if (candidate) |subscription| subscription.stopAndDestroy();

    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    var commit_locked = true;
    defer if (commit_locked) server.catalog_commit_lock.unlock(io_mod.getIo());
    try lockRwUntil(&server.runtime.?.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    defer if (catalog_locked) server.runtime.?.catalog_mutex.unlock(io_mod.getIo());
    if (server.tool_subscription != null) return;
    server.runtime.?.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;
    server.catalog_commit_lock.unlock(io_mod.getIo());
    commit_locked = false;

    candidate = try createToolSubscriptionWithResources(
        alloc,
        server,
        &.{},
        .{
            .deadline = deadline,
            .cancel_flag = cancel_flag,
            .lifecycle_cancel_flag = lifecycleCancelFlag(server),
        },
    );
    if (candidate == null) return;

    try lockMutexUntil(&server.catalog_commit_lock, deadline, cancel_flag);
    commit_locked = true;
    try lockRwUntil(&server.runtime.?.catalog_mutex, deadline, cancel_flag);
    catalog_locked = true;
    if (server.tool_subscription != null) return;
    publishToolSubscription(server, candidate.?);
    candidate = null;
}

fn resumeToolSubscriptionAfterAuthentication(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
) !void {
    const reason = try takeFinishedToolSubscription(server, deadline, null, false) orelse
        return;
    if (reason != .authentication_required) return;
    try lockRwSharedUntil(&server.connection_lock, deadline, null);
    const legacy = server.legacy_http != null or server.legacy_sse != null;
    server.connection_lock.unlockShared(io_mod.getIo());
    if (legacy) {
        try reconnectLegacyForCredentials(self, server, deadline, null);
        return;
    }
    try startToolSubscriptionGuarded(self.alloc, server, deadline, null);
}

fn authorizePendingChallengeIfAutomated(
    alloc: Allocator,
    server: *McpServer,
    control: streamable_http.Control,
) !bool {
    if (!automatedAuthorizationEnabled(try server.config.remoteUrl())) return false;
    var owned_challenge = challenge: {
        try lockMutexWithControl(&server.auth_lock, control);
        defer server.auth_lock.unlock(io_mod.getIo());
        if (server.auth_logout_in_progress.load(.acquire)) return error.McpAuthorityChanged;
        break :challenge if (server.pending_auth_challenge) |pending|
            try pending.clone(alloc)
        else
            mcp_auth.Challenge{};
    };
    defer owned_challenge.deinit(alloc);
    try authorizeForChallenge(alloc, server, owned_challenge, control);
    return true;
}

fn listenModernHttpToolSubscription(
    raw: *anyopaque,
    alloc: Allocator,
    server_name: []const u8,
    connection_generation: u64,
    request_body: []const u8,
    notifications: mcp_contract.NotificationSink,
    control: streamable_http.Control,
) ![]u8 {
    const self: *McpRuntime = @ptrCast(@alignCast(raw));
    const server = self.findServer(server_name) orelse return error.McpConnectionClosed;
    try lockRwSharedWithControl(&server.connection_lock, control);
    defer server.connection_lock.unlockShared(io_mod.getIo());
    if (server.connection_generation != connection_generation or
        server.config.transport != .http or
        !std.mem.eql(u8, server.negotiated_protocol_version, modern_protocol_version))
    {
        return error.McpConnectionClosed;
    }
    const response = try authenticatedPost(alloc, self.alloc, server, .{
        .url = try server.config.remoteUrl(),
        .request_body = request_body,
        .max_response_bytes = mcp_subscription_event_cap_bytes,
        .max_event_bytes = mcp_subscription_event_cap_bytes,
        .notifications = notifications,
        .long_lived = true,
        .control = control,
    }, .{
        .runtime = self,
        .access = .unrestricted,
        .target = .{ .tool_server = server.config.name },
    }, .safe, null);
    if (response.www_authenticate) |value| alloc.free(value);
    return response.body;
}

fn featureProtocol(protocol: StdioProtocol) tools_feature.Protocol {
    return switch (protocol) {
        .legacy => .legacy,
        .modern => .modern,
        .unselected => .legacy,
    };
}

fn serverHasSnapshotTool(
    server: *const McpServer,
    snapshot: *const ToolCallSnapshot,
) bool {
    if (!std.mem.eql(u8, server.config.name, snapshot.server_name)) return false;
    for (server.tool_catalog.tools.items) |tool| {
        if (std.mem.eql(u8, tool.original_name, snapshot.original_name) and
            std.mem.eql(u8, tool.prefixed_name, snapshot.prefixed_name) and
            std.mem.eql(u8, tool.input_schema_json, snapshot.input_schema_json) and
            optionalBytesEqual(tool.output_schema_json, snapshot.output_schema_json))
        {
            return true;
        }
    }
    return false;
}

fn serverCatalogAvailable(server: *const McpServer) bool {
    if (!server.tool_catalog.available) return false;
    const metadata = server.tool_catalog.metadata orelse return true;
    return catalogAuthPartitionMatches(server, metadata);
}

fn catalogAuthPartitionMatches(
    server: *const McpServer,
    metadata: feature_cache.SnapshotMetadata,
) bool {
    return metadata.scope == .public or
        server.tool_catalog.auth_generation ==
            server.auth_generation.load(.acquire);
}

const CatalogAuthWitness = struct {
    server: *McpServer,
    generation: u64,
};

fn catalogAuthWitness(server: *McpServer) ?u64 {
    const metadata = server.tool_catalog.metadata orelse return null;
    if (metadata.scope == .public) return null;
    return server.tool_catalog.auth_generation;
}

fn validateCatalogAuthWitness(server: *McpServer, witness: ?u64) !void {
    const generation = witness orelse return;
    if (server.auth_generation.load(.acquire) != generation) {
        return error.McpToolCatalogChanged;
    }
}

fn validateCatalogAuthWitnesses(witnesses: []const CatalogAuthWitness) !void {
    for (witnesses) |witness| {
        try validateCatalogAuthWitness(witness.server, witness.generation);
    }
}

fn refreshSnapshotGenerationsIfIdentityMatches(
    server: *const McpServer,
    snapshot: *ToolCallSnapshot,
    stdio_generation: ?u64,
) bool {
    const metadata = server.tool_catalog.metadata orelse return false;
    if (!serverCatalogAvailable(server) or
        !metadata.key.eql(snapshot.cache_key) or
        !serverHasSnapshotTool(server, snapshot))
    {
        return false;
    }
    snapshot.connection_generation = server.connection_generation;
    snapshot.catalog_generation = server.catalog_generation;
    snapshot.stdio_generation = stdio_generation;
    return true;
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if ((left == null) != (right == null)) return false;
    if (left) |value| return std.mem.eql(u8, value, right.?);
    return true;
}

fn buildToolSchemaJsonWithLimitMarker(
    alloc: Allocator,
    tool: McpTool,
    instructions: ?[]const u8,
    instructions_truncated: bool,
    instruction_observed_bytes: usize,
    limit: context_limits.Resolved,
) ![]u8 {
    const encoded_description = try encodeScalarAlloc(alloc, tool.description);
    defer alloc.free(encoded_description);
    const encoded_instructions = if (instructions) |text| try encodeScalarAlloc(alloc, text) else null;
    defer if (encoded_instructions) |text| alloc.free(text);
    const merged_description = if (instructions != null)
        if (instructions_truncated)
            try std.fmt.allocPrint(
                alloc,
                "{s}\n\nServer instructions: {s}\n<context_limit name=\"mcp_server_instructions_bytes\" action=\"truncated\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" override=\"--context-limit mcp_server_instructions_bytes=BYTES|off\" />",
                .{ encoded_description, encoded_instructions.?, instruction_observed_bytes, limit.effectiveBytes(), limit.source.label() },
            )
        else
            try std.fmt.allocPrint(alloc, "{s}\n\nServer instructions: {s}", .{ encoded_description, encoded_instructions.? })
    else
        try alloc.dupe(u8, encoded_description);
    defer alloc.free(merged_description);
    return model_tool_schema.dynamicFunctionSchemaJsonAlloc(
        alloc,
        tool.prefixed_name,
        merged_description,
        tool.input_schema_json,
    );
}

const ToolSearchMatch = struct {
    server: *McpServer,
    tool: *const McpTool,
    score: lexical_relevance.Score,
};

fn renderSearchResult(
    alloc: Allocator,
    matches: []const ToolSearchMatch,
    selected_count: usize,
    description_limit: context_limits.Resolved,
    result_limit: context_limits.Resolved,
    observed_bytes: usize,
    limit_triggered: bool,
    more_available: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"tools\":[");
    for (matches[0..selected_count], 0..) |match, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeToolMetadataJson(alloc, &out.writer, match, description_limit);
    }
    try out.writer.print("],\"count\":{d}", .{selected_count});
    if (more_available) try out.writer.writeAll(",\"more_available\":true");
    if (limit_triggered) {
        try out.writer.print(
            ",\"context_limit\":{{\"name\":\"mcp_search_result_bytes\",\"action\":\"omitted\",\"omitted_count\":{d},\"observed_bytes\":{d},\"effective_bytes\":{d},\"source\":",
            .{ matches.len - selected_count, observed_bytes, result_limit.effectiveBytes() },
        );
        try std.json.Stringify.value(result_limit.source.label(), .{}, &out.writer);
        try out.writer.writeAll(",\"override\":\"--context-limit mcp_search_result_bytes=BYTES|off\"}");
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn renderSearchNotice(
    alloc: Allocator,
    matches: []const ToolSearchMatch,
    selected_count: usize,
    limits: context_limits.Values,
    observed_bytes: usize,
    result_limit_triggered: bool,
) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (matches[0..selected_count]) |match| {
        const tool = match.tool;
        const encoded_description = try encodeScalarAlloc(alloc, tool.description);
        defer alloc.free(encoded_description);
        if (encoded_description.len <= limits.mcp_description_bytes.effectiveBytes()) continue;
        try out.writer.writeAll("[context] MCP description for \"");
        try model_context_encoding.writeScalar(&out.writer, tool.prefixed_name);
        try out.writer.print(
            "\" truncated: observed={d} bytes effective={d} bytes source={s}; override with --context-limit mcp_description_bytes=BYTES|off\n",
            .{ encoded_description.len, limits.mcp_description_bytes.effectiveBytes(), limits.mcp_description_bytes.source.label() },
        );
    }
    if (result_limit_triggered) {
        try out.writer.print("[context] MCP search omitted {d} tool(s) (", .{matches.len - selected_count});
        for (matches[selected_count..], 0..) |match, index| {
            if (index > 0) try out.writer.writeAll(", ");
            try model_context_encoding.writeScalar(&out.writer, match.tool.prefixed_name);
        }
        try out.writer.print(
            "): observed={d} bytes effective={d} bytes source={s}; override with --context-limit mcp_search_result_bytes=BYTES|off",
            .{ observed_bytes, limits.mcp_search_result_bytes.effectiveBytes(), limits.mcp_search_result_bytes.source.label() },
        );
    }
    return if (out.written().len > 0) try out.toOwnedSlice() else null;
}

fn renderSchemaNotice(
    alloc: Allocator,
    tool_name: []const u8,
    action: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
    limit_name: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("[context] MCP schema \"");
    try model_context_encoding.writeScalar(&out.writer, tool_name);
    try out.writer.print(
        "\" {s}: observed={d} bytes effective={d} bytes source={s}; override with --context-limit {s}=BYTES|off",
        .{ action, observed_bytes, limit.effectiveBytes(), limit.source.label(), limit_name },
    );
    return try out.toOwnedSlice();
}

fn writeToolMetadataJson(
    alloc: Allocator,
    writer: *std.Io.Writer,
    match: ToolSearchMatch,
    description_limit: context_limits.Resolved,
) !void {
    const tool = match.tool;
    const bounded = try boundedEncodedScalar(
        alloc,
        tool.description,
        description_limit.effectiveBytes(),
    );
    defer alloc.free(bounded.text);
    try writer.writeAll("{\"name\":");
    try writeEncodedJsonScalar(alloc, writer, tool.prefixed_name);
    try writer.writeAll(",\"server\":");
    try writeEncodedJsonScalar(alloc, writer, match.server.config.name);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(bounded.text, .{}, writer);
    try writer.writeAll(",\"purpose\":");
    try std.json.Stringify.value(bounded.text, .{}, writer);
    try writer.writeAll(",\"usage\":[");
    for (tool.tags, 0..) |tag, index| {
        if (index > 0) try writer.writeByte(',');
        try writeEncodedJsonScalar(alloc, writer, tag);
    }
    try writer.writeByte(']');
    if (bounded.observed_bytes > description_limit.effectiveBytes()) {
        try writer.print(
            ",\"context_limit\":{{\"name\":\"mcp_description_bytes\",\"action\":\"truncated\",\"observed_bytes\":{d},\"effective_bytes\":{d},\"source\":",
            .{ bounded.observed_bytes, description_limit.effectiveBytes() },
        );
        try std.json.Stringify.value(description_limit.source.label(), .{}, writer);
        try writer.writeAll(",\"override\":\"--context-limit mcp_description_bytes=BYTES|off\"}");
    }
    try writer.writeByte('}');
}

const BoundedEncodedScalar = struct {
    text: []u8,
    observed_bytes: usize,
};

fn boundedEncodedScalar(alloc: Allocator, value: []const u8, max_bytes: usize) !BoundedEncodedScalar {
    const encoded = try encodeScalarAlloc(alloc, value);
    errdefer alloc.free(encoded);
    const observed = encoded.len;
    if (observed <= max_bytes) return .{ .text = encoded, .observed_bytes = observed };

    var prefix_len = context_limits.utf8PrefixLength(encoded, max_bytes);
    if (std.mem.lastIndexOfScalar(u8, encoded[0..prefix_len], '&')) |amp_index| {
        if (std.mem.indexOfScalar(u8, encoded[amp_index..prefix_len], ';') == null) prefix_len = amp_index;
    }
    return .{ .text = try alloc.realloc(encoded, prefix_len), .observed_bytes = observed };
}

fn encodeScalarAlloc(alloc: Allocator, value: []const u8) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try model_context_encoding.writeScalar(&encoded.writer, value);
    return try encoded.toOwnedSlice();
}

fn writeEncodedJsonScalar(alloc: Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const encoded = try encodeScalarAlloc(alloc, value);
    defer alloc.free(encoded);
    try std.json.Stringify.value(encoded, .{}, writer);
}

fn queryContainsCompleteIdentity(query: []const u8, identity: []const u8) bool {
    if (identity.len == 0 or identity.len > query.len) return false;

    var start: usize = 0;
    while (start <= query.len - identity.len) : (start += 1) {
        const end = start + identity.len;
        if (!std.ascii.eqlIgnoreCase(query[start..end], identity)) continue;
        if (start > 0 and isSearchByte(query[start - 1])) continue;
        if (end < query.len and isSearchByte(query[end])) continue;
        return true;
    }
    return false;
}

fn buildToolTags(alloc: Allocator, server_name: []const u8, tool_name: []const u8) ![]const []u8 {
    var tags: std.ArrayList([]u8) = .empty;
    errdefer collections.freeStringList(alloc, &tags);

    try appendTag(alloc, &tags, "mcp");
    try appendTagTokens(alloc, &tags, server_name);
    try appendTagTokens(alloc, &tags, tool_name);

    return try tags.toOwnedSlice(alloc);
}

fn appendTagTokens(alloc: Allocator, tags: *std.ArrayList([]u8), text: []const u8) !void {
    var start: ?usize = null;
    for (text, 0..) |byte, index| {
        if (isSearchByte(byte)) {
            if (start == null) start = index;
            continue;
        }
        if (start) |s| {
            try appendTag(alloc, tags, text[s..index]);
            start = null;
        }
    }
    if (start) |s| try appendTag(alloc, tags, text[s..]);
}

fn appendTag(alloc: Allocator, tags: *std.ArrayList([]u8), raw: []const u8) !void {
    if (raw.len == 0 or tags.items.len >= max_mcp_tool_tags) return;

    const normalized = try std.ascii.allocLowerString(alloc, raw);
    errdefer alloc.free(normalized);
    for (tags.items) |tag| {
        if (std.mem.eql(u8, tag, normalized)) {
            alloc.free(normalized);
            return;
        }
    }
    try tags.append(alloc, normalized);
}

fn isSearchByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn retainFeatureProtocolDiagnostic(
    alloc: Allocator,
    options: FeatureCallOptions,
    failure: resources_feature.ProtocolError,
) !void {
    const destination = options.protocol_diagnostic orelse return;
    std.debug.assert(destination.* == null);
    destination.* = try tool_result.protocol_diagnostic_alloc(
        alloc,
        failure.code,
        failure.message,
        failure.data_json,
    );
}

fn handleMcpResponseFrameTooLarge(arena: Allocator, server: *McpServer, tool_name: []const u8, cap_bytes: usize) !tool_mcp_runtime.CallResult {
    const server_name = server.config.name;
    debug_trace.logf("mcp", "server {s} exceeded response frame cap_bytes={d}", .{ server_name, cap_bytes });
    return .{
        .model_output = try tool_result.frame_too_large_result(
            arena,
            server_name,
            tool_name,
            cap_bytes,
        ),
        .status = .protocol_failure,
    };
}

fn buildDiscoverRequest(alloc: Allocator, request_id: u64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try out.writer.print("{d}", .{request_id});
    try out.writer.writeAll(",\"method\":\"server/discover\",\"params\":{\"_meta\":");
    try writeModernRequestMetadata(&out.writer);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn buildToolsListRequest(
    alloc: Allocator,
    request_id: u64,
    protocol: StdioProtocol,
    cursor: ?[]const u8,
) ![]u8 {
    return tools_feature.buildListRequest(
        alloc,
        request_id,
        featureProtocol(protocol),
        cursor,
        writeModernRequestMetadata,
    );
}

fn writeModernRequestMetadata(writer: *std.Io.Writer) !void {
    return writeModernRequestMetadataWithProgress(writer, null, .{});
}

fn buildToolCallRequest(alloc: Allocator, request_id: u64, original_name: []const u8, arguments_json: []const u8) ![]u8 {
    return buildToolCallRequestForProtocol(
        alloc,
        request_id,
        original_name,
        arguments_json,
        .legacy,
        null,
        null,
        .{},
    );
}

fn buildToolCallRequestForProtocol(
    alloc: Allocator,
    request_id: u64,
    original_name: []const u8,
    arguments_json: []const u8,
    protocol: StdioProtocol,
    progress_token: ?u64,
    continuation: ?tool_mcp_runtime.Continuation,
    capabilities: elicitation.Capabilities,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try out.writer.print("{d}", .{request_id});
    try out.writer.writeAll(",\"method\":\"tools/call\",\"params\":{");
    if (protocol == .modern) {
        try out.writer.writeAll("\"_meta\":");
        try writeModernRequestMetadataWithProgress(&out.writer, progress_token, capabilities);
        try out.writer.writeAll(",");
    } else if (progress_token) |token| {
        try out.writer.print("\"_meta\":{{\"progressToken\":{d}}},", .{token});
    }
    try out.writer.writeAll("\"name\":");
    try std.json.Stringify.value(original_name, .{}, &out.writer);
    try out.writer.writeAll(",\"arguments\":");
    // Models may pretty-print arguments; a raw newline would split the NDJSON
    // frame, so compact them onto a single line before framing.
    try mcp_json.write_compact(&out.writer, arguments_json);
    if (continuation) |value| {
        try out.writer.writeAll(",\"inputResponses\":");
        try mcp_json.write_compact(&out.writer, value.input_responses_json);
        if (value.request_state_json) |state| {
            try out.writer.writeAll(",\"requestState\":");
            try mcp_json.write_compact(&out.writer, state);
        }
    }
    try out.writer.writeAll("}}");

    return try out.toOwnedSlice();
}

fn writeModernRequestMetadataWithProgress(
    writer: *std.Io.Writer,
    progress_token: ?u64,
    capabilities: elicitation.Capabilities,
) !void {
    try writer.writeAll("{\"io.modelcontextprotocol/protocolVersion\":\"");
    try writer.writeAll(modern_protocol_version);
    try writer.writeAll("\",\"io.modelcontextprotocol/clientInfo\":{\"name\":\"fx\",\"version\":");
    try std.json.Stringify.value(build_options.app_version, .{}, writer);
    try writer.writeAll("},\"io.modelcontextprotocol/clientCapabilities\":{");
    if (capabilities.any()) {
        try writer.writeAll("\"elicitation\":{");
        var wrote_mode = false;
        if (capabilities.form) {
            try writer.writeAll("\"form\":{}");
            wrote_mode = true;
        }
        if (capabilities.url) {
            if (wrote_mode) try writer.writeByte(',');
            try writer.writeAll("\"url\":{}");
        }
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
    if (progress_token) |token| {
        try writer.print(",\"progressToken\":{d}", .{token});
    }
    try writer.writeByte('}');
}

fn responderCapabilities(responder: ?tool_mcp_runtime.InputResponder) elicitation.Capabilities {
    return if (responder) |value| value.capabilities else .{};
}

fn notifyContinuationTerminal(
    responder: tool_mcp_runtime.InputResponder,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    outcome: tool_mcp_runtime.ContinuationTerminal,
) void {
    const callback = responder.continuation_terminal orelse return;
    callback(responder.context, alloc, origin, outcome);
}

fn metadataWriterForResponder(
    responder: ?tool_mcp_runtime.InputResponder,
) *const fn (*std.Io.Writer) anyerror!void {
    const capabilities = responderCapabilities(responder);
    if (capabilities.form and capabilities.url) return writeModernRequestMetadataFormAndUrl;
    if (capabilities.form) return writeModernRequestMetadataForm;
    if (capabilities.url) return writeModernRequestMetadataUrl;
    return writeModernRequestMetadata;
}

fn writeModernRequestMetadataForm(writer: *std.Io.Writer) !void {
    return writeModernRequestMetadataWithProgress(writer, null, .{ .form = true });
}

fn writeModernRequestMetadataUrl(writer: *std.Io.Writer) !void {
    return writeModernRequestMetadataWithProgress(writer, null, .{ .url = true });
}

fn writeModernRequestMetadataFormAndUrl(writer: *std.Io.Writer) !void {
    return writeModernRequestMetadataWithProgress(writer, null, .{ .form = true, .url = true });
}

const AuthRetryPolicy = enum {
    safe,
    never,
};

const AuthEffectAccess = struct {
    runtime: *McpRuntime,
    access: tool_mcp_runtime.Access,
    target: access_policy.Target,

    fn authorize(self: AuthEffectAccess) !void {
        var live = try authorizeLiveAccess(
            self.runtime.alloc,
            self.access,
            self.runtime.generation,
            self.target,
        );
        defer if (live) |*view| view.deinit(self.runtime.alloc);
    }

    fn permitsSharedEffects(self: AuthEffectAccess) bool {
        return switch (self.access) {
            .unrestricted => true,
            .disabled, .scoped => false,
        };
    }
};

const AuthRejectionAction = enum {
    require_interactive,
    authorize_and_retry,
    authorize_without_retry,
    retry_limit,
};

fn authRejectionAction(
    automated: bool,
    retry_policy: AuthRetryPolicy,
    authorization_attempts: u8,
) AuthRejectionAction {
    if (!automated) return .require_interactive;
    if (retry_policy == .never) return .authorize_without_retry;
    if (authorization_attempts >= mcp_auth.max_scope_reauthorizations) {
        return .retry_limit;
    }
    return .authorize_and_retry;
}

fn authenticatedPost(
    request_alloc: Allocator,
    owner_alloc: Allocator,
    server: *McpServer,
    initial_options: streamable_http.PostOptions,
    auth_access: AuthEffectAccess,
    retry_policy: AuthRetryPolicy,
    producing_identity: ?*feature_cache.Digest,
) !streamable_http.PostResponse {
    var options = initial_options;
    var authorization_attempts: u8 = 0;
    while (true) {
        var resolved = try resolvedHeadersForPost(
            request_alloc,
            owner_alloc,
            server,
            options.control,
            auth_access,
        );
        defer resolved.deinit(request_alloc);
        options.static_headers = resolved.headers;
        const attempt_identity = if (producing_identity != null)
            try authIdentityForHeaders(request_alloc, resolved.headers)
        else
            undefined;
        var response = try streamable_http.post(request_alloc, options);
        if (response.auth_rejection == .none) {
            if (producing_identity) |identity| identity.* = attempt_identity;
            return response;
        }

        var challenge = if (response.www_authenticate) |value|
            try mcp_auth.parseChallenge(request_alloc, value)
        else
            mcp_auth.Challenge{};
        defer challenge.deinit(request_alloc);
        if (!auth_access.permitsSharedEffects()) {
            response.deinit(request_alloc);
            try auth_access.authorize();
            return error.McpAuthenticationRequired;
        }
        try storePendingChallenge(
            owner_alloc,
            server,
            challenge,
            options.control,
        );
        response.deinit(request_alloc);
        switch (authRejectionAction(
            automatedAuthorizationEnabled(try server.config.remoteUrl()),
            retry_policy,
            authorization_attempts,
        )) {
            .require_interactive => {
                markAuthenticationRequired(owner_alloc, server);
                return error.McpAuthenticationRequired;
            },
            .retry_limit => return error.McpAuthenticationRetryLimit,
            .authorize_without_retry => {
                try authorizeForChallenge(
                    owner_alloc,
                    server,
                    challenge,
                    options.control,
                );
                return error.McpAuthenticationUpdated;
            },
            .authorize_and_retry => {
                authorization_attempts += 1;
                try authorizeForChallenge(
                    owner_alloc,
                    server,
                    challenge,
                    options.control,
                );
            },
        }
    }
}

fn resolvedHeadersForPost(
    request_alloc: Allocator,
    owner_alloc: Allocator,
    server: *McpServer,
    control: streamable_http.Control,
    auth_access: AuthEffectAccess,
) !ResolvedHeaderSet {
    if (auth_access.permitsSharedEffects()) {
        _ = try refreshSharedCredentials(owner_alloc, server, control);
    } else {
        try auth_access.authorize();
    }

    try lockMutexWithControl(&server.auth_lock, control);
    var auth_locked = true;
    defer if (auth_locked) server.auth_lock.unlock(io_mod.getIo());
    if (!auth_access.permitsSharedEffects()) {
        if (server.auth_credentials) |credentials| {
            if (credentials.needsRefresh(io_mod.milliTimestamp())) {
                server.auth_lock.unlock(io_mod.getIo());
                auth_locked = false;
                try auth_access.authorize();
                return error.McpAuthenticationRequired;
            }
        }
    }
    return buildResolvedHeaders(request_alloc, server);
}

fn currentAuthIdentityForAccess(
    alloc: Allocator,
    server: *McpServer,
    control: streamable_http.Control,
    auth_access: AuthEffectAccess,
) !feature_cache.Digest {
    var resolved = try resolvedHeadersForPost(
        alloc,
        alloc,
        server,
        control,
        auth_access,
    );
    defer resolved.deinit(alloc);
    return authIdentityForHeaders(alloc, resolved.headers);
}

fn refreshSharedCredentials(
    alloc: Allocator,
    server: *McpServer,
    control: streamable_http.Control,
) !bool {
    var source = source: {
        try lockMutexWithControl(&server.auth_lock, control);
        defer server.auth_lock.unlock(io_mod.getIo());
        if (server.auth_logout_in_progress.load(.acquire)) return false;
        const credentials = server.auth_credentials orelse return false;
        if (!credentials.needsRefresh(io_mod.milliTimestamp())) return false;
        break :source .{
            .generation = server.auth_generation.load(.acquire),
            .credentials = try credentials.clone(alloc),
        };
    };
    defer source.credentials.deinit(alloc);
    if (source.credentials.refresh_token == null) {
        setFailedSynchronized(
            server,
            alloc,
            "MCP credentials expired. Run /mcp auth for this server.",
        );
        return error.McpAuthenticationRequired;
    }

    var refreshed = mcp_auth.refreshCredentials(alloc, source.credentials, .{
        .deadline = control.deadline,
        .cancel_flag = control.cancel_flag,
        .lifecycle_cancel_flag = control.lifecycle_cancel_flag,
    }) catch |err| {
        if (err == error.Cancelled or err == error.McpRequestTimedOut) return err;
        setFailedSynchronized(
            server,
            alloc,
            "MCP credential refresh failed. Run /mcp auth for this server.",
        );
        return err;
    };
    var transferred = false;
    defer if (!transferred) refreshed.deinit(alloc);
    try checkOperationControl(io_mod.getIo(), control.deadline, control.cancel_flag);
    try lockMutexWithControl(&server.auth_lock, control);
    defer server.auth_lock.unlock(io_mod.getIo());
    if (server.auth_logout_in_progress.load(.acquire) or
        server.auth_generation.load(.acquire) != source.generation)
    {
        return false;
    }
    const save_result = try mcp_auth_store.save(
        alloc,
        server.config.name,
        refreshed,
    );
    traceCredentialStoreRepair(
        "refresh",
        server.config.name,
        save_result.repaired_entries,
    );
    installAuthCredentials(alloc, server, &refreshed);
    transferred = true;
    return true;
}

fn markAuthenticationRequired(alloc: Allocator, server: *McpServer) void {
    const message = std.fmt.allocPrint(
        alloc,
        "Authentication required. Run /mcp auth {s}, or configure bearer_token_env.",
        .{server.config.name},
    ) catch {
        setFailedSynchronized(server, alloc, "Authentication required.");
        return;
    };
    defer alloc.free(message);
    setFailedSynchronized(server, alloc, message);
}

fn setFailedSynchronized(
    server: *McpServer,
    alloc: Allocator,
    message: []const u8,
) void {
    const runtime = server.runtime orelse {
        server.setFailed(alloc, message);
        return;
    };
    runtime.catalog_mutex.lockUncancelable(io_mod.getIo());
    defer runtime.catalog_mutex.unlock(io_mod.getIo());
    server.setFailed(alloc, message);
}

fn storePendingChallenge(
    alloc: Allocator,
    server: *McpServer,
    challenge: mcp_auth.Challenge,
    control: streamable_http.Control,
) !void {
    var owned = try challenge.clone(alloc);
    var transferred = false;
    errdefer if (!transferred) owned.deinit(alloc);
    try lockMutexWithControl(&server.auth_lock, control);
    defer server.auth_lock.unlock(io_mod.getIo());
    if (server.auth_logout_in_progress.load(.acquire)) return error.McpAuthorityChanged;
    advanceAuthGeneration(server);
    if (server.pending_auth_challenge) |*previous| previous.deinit(alloc);
    server.pending_auth_challenge = owned;
    server.auth_challenge_present.store(true, .release);
    transferred = true;
    owned = undefined;
}

fn authorizeForChallenge(
    alloc: Allocator,
    server: *McpServer,
    challenge: mcp_auth.Challenge,
    control: streamable_http.Control,
) !void {
    const auth_config = server.config.auth orelse mcp_contract.McpAuthConfig{};
    const client_secret = if (auth_config.client_secret_env) |env_name|
        io_mod.getenv(env_name) orelse return error.McpClientSecretEnvironmentMissing
    else
        null;
    const source = source: {
        try lockMutexWithControl(&server.auth_lock, control);
        defer server.auth_lock.unlock(io_mod.getIo());
        if (server.auth_logout_in_progress.load(.acquire)) return error.McpAuthorityChanged;
        break :source .{
            .generation = server.auth_generation.load(.acquire),
            .previous_scope = if (server.auth_credentials) |credentials|
                try alloc.dupe(u8, credentials.scope)
            else
                null,
        };
    };
    defer if (source.previous_scope) |value| alloc.free(value);
    var credentials = switch (try mcp_auth.authorizeAutomated(alloc, .{
        .endpoint = try server.config.remoteUrl(),
        .challenge = challenge,
        .config = .{
            .resource = auth_config.resource,
            .issuer = auth_config.issuer,
            .client_id = auth_config.client_id,
            .client_secret = client_secret,
            .client_metadata_url = auth_config.client_metadata_url,
            .scopes = auth_config.scopes,
        },
        .previous_scope = source.previous_scope,
    })) {
        .credentials => |credentials| credentials,
        .issuer_mismatch => |owned_mismatch| {
            var mismatch = owned_mismatch;
            const err = switch (mismatch.source) {
                .authorization_metadata => error.AuthorizationMetadataIssuerMismatch,
                .authorization_response => error.AuthorizationResponseIssuerMismatch,
            };
            mismatch.deinit();
            return err;
        },
    };
    var credentials_transferred = false;
    errdefer if (!credentials_transferred) credentials.deinit(alloc);
    try lockMutexWithControl(&server.auth_lock, control);
    defer server.auth_lock.unlock(io_mod.getIo());
    if (server.auth_logout_in_progress.load(.acquire) or
        server.auth_generation.load(.acquire) != source.generation)
    {
        credentials.deinit(alloc);
        return;
    }
    const save_result = try mcp_auth_store.save(
        alloc,
        server.config.name,
        credentials,
    );
    traceCredentialStoreRepair(
        "automated_auth",
        server.config.name,
        save_result.repaired_entries,
    );
    installAuthCredentials(alloc, server, &credentials);
    if (server.pending_auth_challenge) |*pending| pending.deinit(alloc);
    server.pending_auth_challenge = null;
    server.auth_challenge_present.store(false, .release);
    credentials_transferred = true;
}

fn traceCredentialStoreRepair(
    actor: []const u8,
    server_name: []const u8,
    repaired_entries: usize,
) void {
    if (repaired_entries == 0) return;
    debug_trace.logf(
        "mcp",
        "removed unreadable MCP credential entries actor={s} server={s} count={d}",
        .{ actor, server_name, repaired_entries },
    );
}

fn installAuthCredentials(
    alloc: Allocator,
    server: *McpServer,
    credentials: *mcp_auth.Credentials,
) void {
    advanceAuthGeneration(server);
    if (server.auth_credentials) |*old| old.deinit(alloc);
    server.auth_credentials = credentials.*;
    server.auth_credentials_present.store(true, .release);
    credentials.* = undefined;
}

fn advanceAuthGeneration(server: *McpServer) void {
    const runtime = server.runtime;
    const published = if (runtime) |owner|
        owner.findServer(server.config.name) == server
    else
        false;
    if (published) runtime.?.legacy_url_waiter_mutex.lockUncancelable(io_mod.getIo());
    defer if (published) runtime.?.legacy_url_waiter_mutex.unlock(io_mod.getIo());
    advanceAuthGenerationLocked(server);
    if (published) {
        runtime.?.cancelLegacyUrlWaitersForServerLocked(
            server.config.name,
            server.connection_generation,
        );
    }
}

fn advanceAuthGenerationLocked(server: *McpServer) void {
    var current = server.auth_generation.load(.acquire);
    while (current != std.math.maxInt(u64)) {
        const result = server.auth_generation.cmpxchgWeak(
            current,
            current + 1,
            .release,
            .acquire,
        );
        if (result == null) return;
        current = result.?;
    }
}

fn automatedAuthorizationEnabled(endpoint: []const u8) bool {
    if (!mcp_auth.isLoopbackEndpoint(endpoint)) return false;
    const value = io_mod.getenv("FX_E2E_MCP_AUTH_AUTOMATE") orelse return false;
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true");
}

fn connectServerHttp(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *std.StringHashMap(void),
    control: ConnectionControl,
) !void {
    errdefer {
        removeServerToolNames(used_tool_names, server);
        clearServerTools(alloc, server);
    }
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    try checkConnectionControl(attempt_control);
    const deadline = attempt_control.deadline.?;
    const post_control = streamable_http.Control{
        .deadline = deadline,
        .cancel_flag = attempt_control.cancel_flag,
        .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
    };

    var next_request_id: u64 = 1;
    var discover_request = try buildDiscoverRequest(alloc, next_request_id);
    defer alloc.free(discover_request);
    next_request_id += 1;

    var discover_response = try authenticatedPost(alloc, alloc, server, .{
        .url = try server.config.remoteUrl(),
        .static_headers = server.resolved_headers,
        .request_body = discover_request,
        .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
        .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
        .allow_version_error = true,
        .allow_discovery_mismatch_status = true,
        .control = post_control,
    }, .{
        .runtime = server.runtime.?,
        .access = .unrestricted,
        .target = .{ .tool_server = server.config.name },
    }, .safe, null);
    defer discover_response.deinit(alloc);

    if (discover_response.discovery_mismatch_status) {
        return connectServerLegacyHttp(
            alloc,
            server,
            tool_registry,
            used_tool_names,
            control,
            &next_request_id,
            legacy_streamable_http.preferred_version,
        );
    }

    if (discover_response.version_error) {
        const selection = selection: {
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                alloc,
                discover_response.body,
                .{},
            ) catch return error.McpInvalidJson;
            defer parsed.deinit();
            break :selection try classifyHttpDiscoveryResponse(parsed.value);
        };
        switch (selection) {
            .legacy_fallback => return connectServerLegacyHttp(
                alloc,
                server,
                tool_registry,
                used_tool_names,
                control,
                &next_request_id,
                legacy_streamable_http.preferred_version,
            ),
            .retry_modern => {
                const replacement = replacement: {
                    const request = try buildDiscoverRequest(alloc, next_request_id);
                    errdefer alloc.free(request);
                    const response = try authenticatedPost(alloc, alloc, server, .{
                        .url = try server.config.remoteUrl(),
                        .static_headers = server.resolved_headers,
                        .request_body = request,
                        .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
                        .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
                        .control = post_control,
                    }, .{
                        .runtime = server.runtime.?,
                        .access = .unrestricted,
                        .target = .{ .tool_server = server.config.name },
                    }, .safe, null);
                    break :replacement .{
                        .request = request,
                        .response = response,
                    };
                };
                next_request_id += 1;
                discover_response.deinit(alloc);
                alloc.free(discover_request);
                discover_request = replacement.request;
                discover_response = replacement.response;
            },
            .modern, .unsupported => return error.UnexpectedHttpStatus,
        }
    }

    var parsed_discover = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        discover_response.body,
        .{},
    ) catch return error.McpInvalidJson;
    defer parsed_discover.deinit();
    switch (try classifyHttpDiscoveryResponse(parsed_discover.value)) {
        .modern => {},
        .legacy_fallback => return connectServerLegacyHttp(
            alloc,
            server,
            tool_registry,
            used_tool_names,
            control,
            &next_request_id,
            legacy_streamable_http.preferred_version,
        ),
        .retry_modern, .unsupported => {
            server.setFailed(
                alloc,
                "MCP server does not support protocol version " ++ modern_protocol_version,
            );
            return error.McpUnsupportedProtocolVersion;
        },
    }

    server.negotiated_protocol_version = modern_protocol_version;
    const discovered_capabilities = try parseServerCapabilities(parsed_discover.value);
    server.tools_list_changed = discovered_capabilities.tools_list_changed;
    server.capabilities = discovered_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, discover_response.body);

    try parseAndStoreServerInstructionsForProtocol(
        alloc,
        server,
        discover_response.body,
        .modern,
    );

    var request_ids = HttpRequestIds{ .local = &next_request_id };
    var fetched = try fetchModernHttpToolCatalogWithIds(
        alloc,
        server.runtime.?,
        server,
        &request_ids,
        deadline,
        attempt_control.cancel_flag,
        .unrestricted,
    );
    defer fetched.deinit(alloc);
    try storeProtocolTools(
        alloc,
        server,
        tool_registry,
        fetched.catalog,
        used_tool_names,
        .modern,
        fetched.auth_identity,
    );
    server.http_next_request_id.store(next_request_id, .seq_cst);
    try startToolSubscription(alloc, server, attempt_control);
    server.setReady(alloc);
}

fn connectServerLegacyHttp(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *std.StringHashMap(void),
    control: ConnectionControl,
    next_request_id: *u64,
    requested_version: legacy_streamable_http.Version,
) !void {
    try refreshResolvedHeaders(alloc, server);
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    try checkConnectionControl(attempt_control);
    const deadline = attempt_control.deadline.?;
    const init_id = next_request_id.*;
    next_request_id.* = std.math.add(u64, init_id, 1) catch
        return error.McpRequestIdExhausted;
    const init_request = try buildLegacyInitializeRequest(
        alloc,
        init_id,
        requested_version.string(),
        legacyWireForHttpVersion(requested_version),
        if (server.runtime) |runtime| runtime.legacy_elicitation_capabilities else .{},
    );
    defer alloc.free(init_request);

    var startup_auth_challenge: ?[]u8 = null;
    defer if (startup_auth_challenge) |value| alloc.free(value);
    var initialized = legacy_streamable_http.initialize(alloc, .{
        .url = try server.config.remoteUrl(),
        .static_headers = server.resolved_headers,
        .request_body = init_request,
        .request_id = init_id,
        .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
        .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
        .control = .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
        .auth_challenge = &startup_auth_challenge,
    }) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try captureAuthHeader(
                alloc,
                server,
                startup_auth_challenge,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };
    var client_owned = true;
    defer if (client_owned) initialized.client.deinit();
    defer initialized.deinitResponse(alloc);

    server.negotiated_protocol_version = initialized.client.version.string();
    const initialized_capabilities = try parseServerCapabilitiesFromResponse(
        alloc,
        initialized.response_body,
    );
    server.tools_list_changed = initialized_capabilities.tools_list_changed;
    server.capabilities = initialized_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, initialized.response_body);

    try parseAndStoreServerInstructionsForProtocol(
        alloc,
        server,
        initialized.response_body,
        .legacy,
    );
    initialized.client.sendNotification(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}",
        .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
    ) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try captureLegacyStreamableAuth(
                alloc,
                server,
                initialized.client,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };

    var builder = tools_feature.CatalogBuilder.init(alloc, .legacy);
    defer builder.deinit(alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    while (true) {
        const tools_id = next_request_id.*;
        next_request_id.* = std.math.add(u64, tools_id, 1) catch
            return error.McpRequestIdExhausted;
        const tools_request = try buildToolsListRequest(alloc, tools_id, .legacy, cursor);
        defer alloc.free(tools_request);
        const tools_response = initialized.client.request(alloc, .{
            .request_id = tools_id,
            .request_body = tools_request,
            .max_response_bytes = mcp_discovery_response_frame_cap_bytes,
            .max_event_bytes = mcp_discovery_response_frame_cap_bytes,
            .control = .{
                .deadline = deadline,
                .cancel_flag = attempt_control.cancel_flag,
                .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
            },
        }) catch |err| {
            if (err == error.McpAuthenticationRequired) {
                try captureLegacyStreamableAuth(
                    alloc,
                    server,
                    initialized.client,
                    .{
                        .deadline = deadline,
                        .cancel_flag = attempt_control.cancel_flag,
                        .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                    },
                );
            }
            return err;
        };
        const received_at_ms = clockMillis();
        defer alloc.free(tools_response);
        var page = try tools_feature.parseListPage(alloc, tools_response, .legacy, .{});
        defer page.deinit(alloc);
        if (cursor) |value| alloc.free(value);
        cursor = if (page.next_cursor) |value| try alloc.dupe(u8, value) else null;
        try builder.appendPage(alloc, &page, received_at_ms, .{});
        if (cursor == null) break;
    }
    var catalog = try builder.finish(alloc);
    defer catalog.deinit(alloc);
    try storeProtocolTools(alloc, server, tool_registry, catalog, used_tool_names, .legacy, null);

    server.legacy_http = initialized.client;
    client_owned = false;
    server.http_next_request_id.store(next_request_id.*, .seq_cst);
    try startToolSubscription(alloc, server, attempt_control);
    server.setReady(alloc);
}

fn buildLegacyInitializeRequest(
    alloc: Allocator,
    request_id: u64,
    protocol_version: []const u8,
    negotiated_wire: ?elicitation.Wire,
    elicitation_capabilities: elicitation.Capabilities,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":",
        .{request_id},
    );
    try std.json.Stringify.value(protocol_version, .{}, &out.writer);
    try out.writer.writeAll(",\"capabilities\":{");
    if (negotiated_wire != null and elicitation_capabilities.form) {
        try out.writer.writeAll("\"elicitation\":");
        if (negotiated_wire.? == .legacy_mcp_2025_06) {
            try out.writer.writeAll("{}");
        } else {
            try out.writer.writeAll("{\"form\":{}");
            if (elicitation_capabilities.url) try out.writer.writeAll(",\"url\":{}");
            try out.writer.writeByte('}');
        }
    } else if (negotiated_wire == .legacy_mcp_2025_11 and elicitation_capabilities.url) {
        try out.writer.writeAll("\"elicitation\":{\"url\":{}}");
    }
    try out.writer.writeAll("},\"clientInfo\":{\"name\":\"fx\",\"version\":");
    try std.json.Stringify.value(build_options.app_version, .{}, &out.writer);
    try out.writer.writeAll("}}}");
    return out.toOwnedSlice();
}

fn reserveHttpRequestId(server: *McpServer) !u64 {
    var current = server.http_next_request_id.load(.seq_cst);
    while (true) {
        if (current > std.math.maxInt(i64)) return error.McpRequestIdExhausted;
        const next = current + 1;
        const result = server.http_next_request_id.cmpxchgWeak(
            current,
            next,
            .seq_cst,
            .seq_cst,
        );
        if (result == null) return current;
        current = result.?;
    }
}

fn callToolHttp(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *ToolCallSnapshot,
    arguments_json: []const u8,
    max_tool_result_bytes: usize,
    options: tool_mcp_runtime.CallOptions,
    deadline: std.Io.Clock.Timestamp,
) !tool_mcp_runtime.CallResult {
    try lockRwSharedUntil(
        &server.connection_lock,
        deadline,
        options.cancel_flag,
    );
    var connection_locked = true;
    var reconnected_for_credentials = false;
    defer if (connection_locked) {
        server.connection_lock.unlockShared(io_mod.getIo());
    };
    if (server.legacy_http != null and try legacyConnectionNeedsCredentialUpdate(
        server,
        deadline,
        options.cancel_flag,
    )) {
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;
        try reauthorizeOperation(
            self,
            options.access,
            .{ .tool = snapshot.prefixed_name },
        );
        switch (options.access) {
            .unrestricted => {},
            .disabled, .scoped => return error.McpAuthenticationRequired,
        }
        try reconnectLegacyForCredentials(
            self,
            server,
            deadline,
            options.cancel_flag,
        );
        try lockRwSharedUntil(
            &server.connection_lock,
            deadline,
            options.cancel_flag,
        );
        connection_locked = true;
        reconnected_for_credentials = true;
    }
    const snapshot_current = if (reconnected_for_credentials and options.continuation == null)
        try refreshRemoteSnapshotAfterReconnect(
            self,
            server,
            snapshot,
            deadline,
            options.cancel_flag,
        )
    else
        try httpToolSnapshotMatchesCurrent(
            self,
            server,
            snapshot,
            deadline,
            options.cancel_flag,
        );
    if (!snapshot_current) return error.McpToolCatalogChanged;

    var tool_precommit = ToolPrecommit{
        .runtime = self,
        .server = server,
        .snapshot = snapshot,
        .deadline = deadline,
        .cancel_flag = options.cancel_flag,
        .access = options.access,
    };
    var transport_precommit = tool_precommit.transport();
    const request_id = try reserveHttpRequestId(server);
    if (server.legacy_http) |client| {
        if (!client.acquireUse()) return error.McpConnectionClosed;
        const client_version = client.version;
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;
        const result = callToolLegacyHttp(
            self.alloc,
            alloc,
            server,
            client,
            request_id,
            snapshot.original_name,
            snapshot.prefixed_name,
            snapshot.output_schema_json,
            arguments_json,
            max_tool_result_bytes,
            options,
            deadline,
            &transport_precommit,
        ) catch |err| {
            client.releaseUse();
            if (err == error.McpSessionExpired) {
                switch (options.access) {
                    .unrestricted => {},
                    .disabled, .scoped => return err,
                }
                reauthorizeOperation(
                    self,
                    options.access,
                    .{ .tool = snapshot.prefixed_name },
                ) catch |access_err| {
                    debug_trace.logf(
                        "mcp",
                        "legacy HTTP session recovery denied server={s} err={s}",
                        .{ server.config.name, @errorName(access_err) },
                    );
                    return err;
                };
                recoverLegacyHttpSession(
                    self,
                    server,
                    client,
                    client_version,
                    deadline,
                    options.cancel_flag,
                ) catch |recovery_err| {
                    debug_trace.logf(
                        "mcp",
                        "legacy HTTP session recovery failed server={s} version={s} err={s}",
                        .{
                            server.config.name,
                            client_version.string(),
                            @errorName(recovery_err),
                        },
                    );
                };
            }
            return err;
        };
        client.releaseUse();
        return result;
    }
    const request_body = try buildToolCallRequestForProtocol(
        alloc,
        request_id,
        snapshot.original_name,
        arguments_json,
        .modern,
        if (options.progress != null) request_id else null,
        options.continuation,
        responderCapabilities(options.input_responder),
    );
    defer alloc.free(request_body);

    const raw_frame_cap = mcpResponseFrameCap(max_tool_result_bytes);
    var response = authenticatedPost(alloc, self.alloc, server, .{
        .url = try server.config.remoteUrl(),
        .static_headers = server.resolved_headers,
        .request_body = request_body,
        .input_schema_json = snapshot.input_schema_json,
        .max_response_bytes = raw_frame_cap,
        .max_event_bytes = raw_frame_cap,
        .progress = options.progress,
        .precommit = &transport_precommit,
        .control = .{
            .deadline = deadline,
            .cancel_flag = options.cancel_flag,
            .lifecycle_cancel_flag = &self.retiring,
        },
    }, .{
        .runtime = self,
        .access = options.access,
        .target = .{ .tool = snapshot.prefixed_name },
    }, .never, null) catch |err| switch (err) {
        error.ResponseTooLarge, error.SseEventTooLarge => {
            return handleMcpResponseFrameTooLarge(
                alloc,
                server,
                snapshot.prefixed_name,
                raw_frame_cap,
            );
        },
        else => |e| return e,
    };
    errdefer response.deinit(alloc);
    const result = try tool_result.extract(alloc, .{
        .server_name = server.config.name,
        .tool_name = snapshot.prefixed_name,
        .response = response.body,
        .max_tool_result_bytes = max_tool_result_bytes,
        .protocol = .modern,
        .output_schema_json = snapshot.output_schema_json,
    });
    response.deinit(alloc);
    return result;
}

fn legacyConnectionNeedsCredentialUpdate(
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !bool {
    try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
    defer server.auth_lock.unlock(io_mod.getIo());
    if (server.auth_credentials) |credentials| {
        if (credentials.needsRefresh(io_mod.milliTimestamp())) return true;
    }
    const current_identity = try currentAuthIdentity(server.runtime.?.alloc, server);
    const connected_identity = try authIdentityForHeaders(
        server.runtime.?.alloc,
        server.resolved_headers,
    );
    return authIdentitiesDiffer(current_identity, connected_identity);
}

fn authIdentitiesDiffer(
    current: feature_cache.Digest,
    connected: feature_cache.Digest,
) bool {
    return !std.mem.eql(u8, &current, &connected);
}

const LegacyRemoteTransport = union(enum) {
    http: legacy_streamable_http.Version,
    sse,
};

fn reconnectLegacyForCredentials(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    return reconnectLegacy(self, server, deadline, cancel_flag, false);
}

fn reconnectLegacyConnection(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    return reconnectLegacy(self, server, deadline, cancel_flag, true);
}

fn reconnectLegacy(
    self: *McpRuntime,
    server: *McpServer,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
    force: bool,
) !void {
    try lockMutexUntil(&self.recovery_mutex, deadline, cancel_flag);
    defer self.recovery_mutex.unlock(io_mod.getIo());

    try lockRwSharedUntil(&server.connection_lock, deadline, cancel_flag);
    const has_legacy_transport = server.legacy_http != null or server.legacy_sse != null;
    server.connection_lock.unlockShared(io_mod.getIo());
    if (!has_legacy_transport) return;

    _ = try refreshSharedCredentials(self.alloc, server, .{
        .deadline = deadline,
        .cancel_flag = cancel_flag,
        .lifecycle_cancel_flag = &self.retiring,
    });

    try lockRwUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlock(io_mod.getIo());
    const transport: LegacyRemoteTransport = if (server.legacy_http) |client|
        .{ .http = client.version }
    else if (server.legacy_sse != null)
        .sse
    else
        return;

    const connection_credentials = credentials: {
        try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
        defer server.auth_lock.unlock(io_mod.getIo());
        const current_identity = try currentAuthIdentity(self.alloc, server);
        const connected_identity = try authIdentityForHeaders(
            self.alloc,
            server.resolved_headers,
        );
        if (!force and std.mem.eql(u8, &current_identity, &connected_identity)) return;
        break :credentials if (server.auth_credentials) |credentials|
            try credentials.clone(self.alloc)
        else
            null;
    };

    var used_tool_names = std.StringHashMap(void).init(self.alloc);
    defer used_tool_names.deinit();
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    errdefer if (catalog_locked) self.catalog_mutex.unlock(io_mod.getIo());
    for (self.servers.items) |*candidate| {
        if (candidate == server) continue;
        for (candidate.tool_catalog.tools.items) |tool| {
            try used_tool_names.put(tool.prefixed_name, {});
        }
    }
    self.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;

    var next_request_id = server.http_next_request_id.load(.seq_cst);
    var connected = McpServer{
        .config = server.config,
        .runtime = self,
        .auth_credentials = connection_credentials,
        .auth_generation = .init(server.auth_generation.load(.acquire)),
        .http_next_request_id = .init(next_request_id),
        .connection_generation = server.connection_generation,
        .catalog_generation = server.catalog_generation,
        .next_subscription_generation = server.next_subscription_generation,
    };
    defer if (connected.auth_credentials) |*credentials| {
        credentials.deinit(self.alloc);
    };
    defer if (connected.pending_auth_challenge) |*challenge| {
        challenge.deinit(self.alloc);
    };
    var connected_published = false;
    defer if (!connected_published) {
        var detached = detachConnection(&connected);
        detached.deinit(self.alloc);
    };
    switch (transport) {
        .http => |version| try connectServerLegacyHttp(
            self.alloc,
            &connected,
            self.tool_registry,
            &used_tool_names,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = &self.retiring,
            },
            &next_request_id,
            version,
        ),
        .sse => try connectServerSse(
            self.alloc,
            &connected,
            self.tool_registry,
            &used_tool_names,
            .{
                .deadline = deadline,
                .cancel_flag = cancel_flag,
                .lifecycle_cancel_flag = &self.retiring,
            },
        ),
    }

    try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    var retired = detachPublishedConnection(server);
    publishConnection(server, &connected);
    connected_published = true;
    self.catalog_mutex.unlock(io_mod.getIo());
    retired.deinit(self.alloc);
    debug_trace.logf(
        "mcp",
        "reconnected legacy transport with refreshed credentials server={s} transport={s}",
        .{
            server.config.name,
            switch (transport) {
                .http => "http",
                .sse => "sse",
            },
        },
    );
}

fn httpToolSnapshotMatchesCurrent(
    self: *McpRuntime,
    server: *McpServer,
    snapshot: *const ToolCallSnapshot,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !bool {
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    defer self.catalog_mutex.unlockShared(io_mod.getIo());

    return self.serverForSnapshotLocked(snapshot) == server;
}

fn refreshRemoteSnapshotAfterReconnect(
    self: *McpRuntime,
    server: *McpServer,
    snapshot: *ToolCallSnapshot,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !bool {
    try lockRwSharedUntil(&self.catalog_mutex, deadline, cancel_flag);
    defer self.catalog_mutex.unlockShared(io_mod.getIo());
    if (self.findServer(snapshot.server_name) != server) return false;
    return refreshSnapshotGenerationsIfIdentityMatches(server, snapshot, null);
}

fn recoverLegacyHttpSession(
    self: *McpRuntime,
    server: *McpServer,
    expired_client: *legacy_streamable_http.Client,
    version: legacy_streamable_http.Version,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    try lockMutexUntil(&self.recovery_mutex, deadline, cancel_flag);
    defer self.recovery_mutex.unlock(io_mod.getIo());

    try lockRwUntil(&server.connection_lock, deadline, cancel_flag);
    defer server.connection_lock.unlock(io_mod.getIo());
    if (server.legacy_http != expired_client) return;

    var used_tool_names = std.StringHashMap(void).init(self.alloc);
    defer used_tool_names.deinit();
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    var catalog_locked = true;
    errdefer if (catalog_locked) self.catalog_mutex.unlock(io_mod.getIo());
    for (self.servers.items) |*candidate| {
        if (candidate == server) continue;
        for (candidate.tool_catalog.tools.items) |tool| {
            try used_tool_names.put(tool.prefixed_name, {});
        }
    }
    self.catalog_mutex.unlock(io_mod.getIo());
    catalog_locked = false;

    var next_request_id = server.http_next_request_id.load(.seq_cst);
    const recovery_credentials = credentials: {
        try lockMutexUntil(&server.auth_lock, deadline, cancel_flag);
        defer server.auth_lock.unlock(io_mod.getIo());
        break :credentials if (server.auth_credentials) |credentials|
            try credentials.clone(self.alloc)
        else
            null;
    };
    var connected = McpServer{
        .config = server.config,
        .runtime = self,
        .auth_credentials = recovery_credentials,
        .auth_generation = .init(server.auth_generation.load(.acquire)),
        .http_next_request_id = .init(next_request_id),
        .connection_generation = server.connection_generation,
        .catalog_generation = server.catalog_generation,
        .next_subscription_generation = server.next_subscription_generation,
    };
    defer if (connected.auth_credentials) |*credentials| {
        credentials.deinit(self.alloc);
    };
    var connected_published = false;
    defer if (!connected_published) {
        var detached = detachConnection(&connected);
        detached.deinit(self.alloc);
    };
    try connectServerLegacyHttp(
        self.alloc,
        &connected,
        self.tool_registry,
        &used_tool_names,
        .{
            .deadline = deadline,
            .cancel_flag = cancel_flag,
            .lifecycle_cancel_flag = &self.retiring,
        },
        &next_request_id,
        version,
    );

    try checkOperationControl(io_mod.getIo(), deadline, cancel_flag);
    try lockRwUntil(&self.catalog_mutex, deadline, cancel_flag);
    if (server.legacy_http != expired_client) {
        self.catalog_mutex.unlock(io_mod.getIo());
        return;
    }
    expired_client.retireExpiredSession();
    var retired = detachPublishedConnection(server);
    publishConnection(server, &connected);
    connected_published = true;
    self.catalog_mutex.unlock(io_mod.getIo());
    retired.deinit(self.alloc);
    debug_trace.logf(
        "mcp",
        "reinitialized expired legacy HTTP session server={s} version={s}",
        .{ server.config.name, version.string() },
    );
}

fn callToolLegacyHttp(
    owner_alloc: Allocator,
    alloc: Allocator,
    server: *McpServer,
    client: *legacy_streamable_http.Client,
    request_id: u64,
    original_name: []const u8,
    prefixed_name: []const u8,
    output_schema_json: ?[]const u8,
    arguments_json: []const u8,
    max_tool_result_bytes: usize,
    options: tool_mcp_runtime.CallOptions,
    deadline: std.Io.Clock.Timestamp,
    precommit: *mcp_contract.TransportPrecommit,
) !tool_mcp_runtime.CallResult {
    const request_body = try buildToolCallRequestForProtocol(
        alloc,
        request_id,
        original_name,
        arguments_json,
        .legacy,
        if (options.progress != null) request_id else null,
        options.continuation,
        .{},
    );
    defer alloc.free(request_body);

    const raw_frame_cap = mcpResponseFrameCap(max_tool_result_bytes);
    var committed = std.atomic.Value(bool).init(false);
    var elicitation_context: ?LegacyElicitationContext = if (legacyWireForHttpVersion(client.version)) |wire|
        LegacyElicitationContext.initHttp(
            server,
            client,
            wire,
            options.input_responder,
            .{ .tools_call = original_name },
            deadline,
            options.cancel_flag,
        )
    else
        null;
    if (elicitation_context) |*context| try context.beginCompletionWindow();
    defer if (elicitation_context) |*context| context.endCompletionWindow();
    var direct_request_completed = false;
    defer if (!direct_request_completed) {
        if (elicitation_context) |*context| {
            if (context.directTerminal()) |terminal| terminal.finish(alloc, .abandoned);
        }
    };
    const response = client.request(alloc, .{
        .request_id = request_id,
        .request_body = request_body,
        .max_response_bytes = raw_frame_cap,
        .max_event_bytes = raw_frame_cap,
        .progress = options.progress,
        .response_observer = if (elicitation_context) |*context| context.responseObserver() else null,
        .server_requests = if (elicitation_context) |*context| context.sink() else null,
        .notifications = if (elicitation_context) |*context| context.completionSink() else null,
        .control = .{
            .deadline = deadline,
            .deadline_gate = if (elicitation_context) |*context| &context.deadline_gate else null,
            .cancel_flag = options.cancel_flag,
            .lifecycle_cancel_flag = lifecycleCancelFlag(server),
        },
        .committed = &committed,
        .precommit = precommit,
    }) catch |err| switch (err) {
        error.Cancelled, error.McpRequestTimedOut => {
            if (committed.load(.acquire)) {
                sendLegacyHttpCancellation(
                    alloc,
                    server,
                    client,
                    request_id,
                    @errorName(err),
                );
            }
            return err;
        },
        error.ResponseTooLarge, error.SseEventTooLarge => {
            return handleMcpResponseFrameTooLarge(
                alloc,
                server,
                prefixed_name,
                raw_frame_cap,
            );
        },
        error.McpAuthenticationRequired => {
            try captureLegacyStreamableAuth(
                owner_alloc,
                server,
                client,
                .{
                    .deadline = deadline,
                    .cancel_flag = options.cancel_flag,
                },
            );
            return error.McpAuthenticationRequired;
        },
        else => |request_err| return request_err,
    };
    defer alloc.free(response);

    const result = try tool_result.extract(alloc, .{
        .server_name = server.config.name,
        .tool_name = prefixed_name,
        .response = response,
        .max_tool_result_bytes = max_tool_result_bytes,
        .protocol = .legacy,
        .output_schema_json = output_schema_json,
        .legacy_wire = legacyWireForHttpVersion(client.version),
    });
    direct_request_completed = true;
    if (elicitation_context) |*context| {
        if (context.directTerminal()) |terminal| {
            terminal.finish(alloc, terminalOutcomeForCallStatus(result.status));
        }
    }
    return result;
}

const LegacyElicitationContext = struct {
    server: *McpServer,
    transport: union(enum) {
        stdio: *stdio_dispatcher.StdioDispatcher,
        http: *legacy_streamable_http.Client,
    },
    wire: elicitation.Wire,
    responder: ?tool_mcp_runtime.InputResponder,
    capabilities: elicitation.Capabilities,
    operation: elicitation.Operation,
    deadline: std.Io.Clock.Timestamp,
    deadline_gate: operation_control.DeadlineGate = .init(0),
    cancel_flag: ?*std.atomic.Value(bool),
    runtime_generation: u64 = 0,
    connection_generation: u64,
    client_generation: u64,
    catalog_generation: u64,
    auth_generation: u64,
    requests_seen: std.atomic.Value(usize) = .init(0),
    completion_window_generation: ?u64 = null,

    fn initHttp(
        server: *McpServer,
        client: *legacy_streamable_http.Client,
        wire: elicitation.Wire,
        responder: ?tool_mcp_runtime.InputResponder,
        operation: elicitation.Operation,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) LegacyElicitationContext {
        return initCommon(
            server,
            .{ .http = client },
            wire,
            responder,
            operation,
            deadline,
            cancel_flag,
        );
    }

    fn initStdio(
        server: *McpServer,
        dispatcher: *stdio_dispatcher.StdioDispatcher,
        wire: elicitation.Wire,
        responder: ?tool_mcp_runtime.InputResponder,
        operation: elicitation.Operation,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) LegacyElicitationContext {
        return initCommon(
            server,
            .{ .stdio = dispatcher },
            wire,
            responder,
            operation,
            deadline,
            cancel_flag,
        );
    }

    fn initCommon(
        server: *McpServer,
        transport: @FieldType(LegacyElicitationContext, "transport"),
        wire: elicitation.Wire,
        responder: ?tool_mcp_runtime.InputResponder,
        operation: elicitation.Operation,
        deadline: std.Io.Clock.Timestamp,
        cancel_flag: ?*std.atomic.Value(bool),
    ) LegacyElicitationContext {
        const runtime_capabilities = if (server.runtime) |runtime|
            runtime.legacy_elicitation_capabilities
        else
            elicitation.Capabilities{};
        return .{
            .server = server,
            .transport = transport,
            .wire = wire,
            .responder = responder,
            .capabilities = elicitation.Capabilities.intersect(
                runtime_capabilities,
                responderCapabilities(responder),
            ),
            .operation = operation,
            .deadline = deadline,
            .deadline_gate = .init(timestampMillis(deadline)),
            .cancel_flag = cancel_flag,
            .runtime_generation = if (server.runtime) |runtime|
                runtime.legacy_url_runtime_generation
            else
                0,
            .connection_generation = server.connection_generation,
            .client_generation = switch (transport) {
                .stdio => |dispatcher| dispatcher.connectionGeneration(),
                .http => server.connection_generation,
            },
            .catalog_generation = server.catalog_generation,
            .auth_generation = server.auth_generation.load(.acquire),
        };
    }

    fn sink(self: *LegacyElicitationContext) ?mcp_contract.ServerRequestSink {
        if (!self.wire.isLegacy() or !self.capabilities.any()) return null;
        return .{
            .context = @ptrCast(self),
            .prepare_callback = prepareLegacyServerRequest,
            .callback = handleLegacyServerRequest,
        };
    }

    fn responseObserver(self: *LegacyElicitationContext) ?mcp_contract.ResponseObserver {
        if (self.wire != .legacy_mcp_2025_11 or self.server.runtime == null or
            !self.capabilities.url)
        {
            return null;
        }
        return .{ .context = @ptrCast(self), .callback = observeLegacyResponse };
    }

    fn completionSink(self: *LegacyElicitationContext) ?mcp_contract.NotificationSink {
        if (self.wire != .legacy_mcp_2025_11 or self.transport != .http or
            self.server.runtime == null or !self.capabilities.url)
        {
            return null;
        }
        return .{
            .context = @ptrCast(self),
            .callback = handleLegacyOperationCompletionNotification,
        };
    }

    fn source(self: *const LegacyElicitationContext) tool_subscription.NotificationSource {
        return .{
            .server_name = self.server.config.name,
            .connection_generation = self.connection_generation,
            .client_generation = self.client_generation,
            .auth_generation = self.auth_generation,
        };
    }

    fn beginCompletionWindow(self: *LegacyElicitationContext) !void {
        if (self.transport != .http or self.responseObserver() == null) return;
        const runtime = self.server.runtime orelse return;
        self.completion_window_generation = try runtime.beginLegacyUrlCompletionWindow(
            self.source(),
            self.runtime_generation,
        );
    }

    fn endCompletionWindow(self: *LegacyElicitationContext) void {
        const generation = self.completion_window_generation orelse return;
        self.completion_window_generation = null;
        const runtime = self.server.runtime orelse return;
        runtime.endLegacyUrlCompletionWindow(
            self.source(),
            self.runtime_generation,
            generation,
        );
    }

    fn sendFrame(self: *LegacyElicitationContext, alloc: Allocator, frame: []const u8) !void {
        const deadline = self.deadlineTimestamp();
        return switch (self.transport) {
            .stdio => |dispatcher| dispatcher.sendNotificationWithLifecycleControl(
                frame,
                self.server.config.operation_timeout_ms,
                deadline,
                self.cancel_flag,
                lifecycleCancelFlag(self.server),
            ),
            .http => |client| client.sendNotification(
                alloc,
                frame,
                .{
                    .deadline = deadline,
                    .cancel_flag = self.cancel_flag,
                    .lifecycle_cancel_flag = lifecycleCancelFlag(self.server),
                },
            ),
        };
    }

    fn bindingCurrent(self: *const LegacyElicitationContext) !bool {
        const deadline = self.deadlineTimestamp();
        try lockRwSharedUntil(
            &self.server.connection_lock,
            deadline,
            self.cancel_flag,
        );
        defer self.server.connection_lock.unlockShared(io_mod.getIo());
        if (self.server.runtime) |runtime| {
            if (runtime.retiring.load(.acquire) or
                runtime.legacy_url_runtime_generation != self.runtime_generation) return false;
            try lockRwSharedUntil(
                &runtime.catalog_mutex,
                deadline,
                self.cancel_flag,
            );
            defer runtime.catalog_mutex.unlockShared(io_mod.getIo());
        }
        return self.server.connection_generation == self.connection_generation and
            self.server.catalog_generation == self.catalog_generation and
            self.server.auth_generation.load(.acquire) == self.auth_generation and
            legacyWireForServer(self.server) == self.wire;
    }

    fn inputOrigin(self: *const LegacyElicitationContext) tool_mcp_runtime.InputOrigin {
        return .{
            .wire = self.wire,
            .server_name = self.server.config.name,
            .operation = self.operation,
            .runtime_generation = self.runtime_generation,
            .connection_generation = self.connection_generation,
            .client_generation = self.client_generation,
            .catalog_generation = self.catalog_generation,
            .request_generation = 1,
            .auth_generation = self.auth_generation,
            .deadline_ms = self.deadline_gate.currentDeadlineMs(),
            .lifecycle_cancel_flag = if (self.server.runtime) |runtime| &runtime.retiring else null,
        };
    }

    fn beginInputWait(self: *LegacyElicitationContext) void {
        self.deadline_gate.pauseUntil(timestampMillis(elicitationDeadline()));
    }

    fn endInputWait(self: *LegacyElicitationContext) void {
        self.deadline_gate.resumeAt(awakeMillis(), self.server.config.operation_timeout_ms);
    }

    fn deadlineTimestamp(self: *const LegacyElicitationContext) std.Io.Clock.Timestamp {
        return .{
            .clock = .awake,
            .raw = std.Io.Timestamp.fromNanoseconds(
                @as(i96, self.deadline_gate.currentDeadlineMs()) * std.time.ns_per_ms,
            ),
        };
    }

    fn directTerminal(self: *const LegacyElicitationContext) ?LegacyDirectTerminal {
        if (self.requests_seen.load(.acquire) == 0) return null;
        const responder = self.responder orelse return null;
        if (responder.continuation_terminal == null) return null;
        return .{ .responder = responder, .origin = self.inputOrigin() };
    }
};

fn prepareLegacyServerRequest(
    raw_context: *anyopaque,
    alloc: Allocator,
    request_json: []const u8,
) anyerror!void {
    const context: *LegacyElicitationContext = @ptrCast(@alignCast(raw_context));
    if (context.wire != .legacy_mcp_2025_11 or !context.capabilities.url) return;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{
        .parse_numbers = false,
    }) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const jsonrpc = parsed.value.object.get("jsonrpc") orelse return;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) return;
    const request_id = parsed.value.object.get("id") orelse return;
    if (!validLegacyServerRequestId(request_id)) return;
    const method = parsed.value.object.get("method") orelse return;
    if (method != .string or !std.mem.eql(u8, method.string, "elicitation/create")) return;
    const params = parsed.value.object.get("params") orelse return;
    const params_json = stringifyMcpValue(alloc, params) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer alloc.free(params_json);
    var request = elicitation.parseRequest(alloc, context.wire, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer request.deinit(alloc);
    if (request.mode != .url) return;
    const runtime = context.server.runtime orelse return;
    const ids = [_][]const u8{request.elicitation_id.?};
    try runtime.registerLegacyUrlCompletionCandidates(
        context.source(),
        context.runtime_generation,
        context.completion_window_generation,
        &ids,
    );
}

fn observeLegacyResponse(
    raw_context: *anyopaque,
    alloc: Allocator,
    value: std.json.Value,
) anyerror!void {
    const context: *LegacyElicitationContext = @ptrCast(@alignCast(raw_context));
    if (value != .object) return;
    const error_value = value.object.get("error") orelse return;
    if (error_value != .object) return;
    const code = error_value.object.get("code") orelse return;
    const code_value = switch (code) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return,
        else => return,
    };
    if (code_value != elicitation.legacy_url_required_error_code) return;
    const data = error_value.object.get("data") orelse return;
    const data_json = stringifyMcpValue(alloc, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer alloc.free(data_json);
    var required = elicitation.parseLegacyUrlRequired(
        alloc,
        context.wire,
        data_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer required.deinit(alloc);
    const ids = try alloc.alloc([]const u8, required.requests.len);
    defer alloc.free(ids);
    for (required.requests, ids) |request, *id| id.* = request.elicitation_id.?;
    const runtime = context.server.runtime orelse return;
    try runtime.registerLegacyUrlCompletionCandidates(
        context.source(),
        context.runtime_generation,
        context.completion_window_generation,
        ids,
    );
}

fn handleLegacyOperationCompletionNotification(
    raw_context: *anyopaque,
    value: std.json.Value,
) void {
    const context: *LegacyElicitationContext = @ptrCast(@alignCast(raw_context));
    const runtime = context.server.runtime orelse return;
    routeLegacyCompletionNotification(runtime, .{
        .server_name = context.server.config.name,
        .connection_generation = context.connection_generation,
        .client_generation = context.client_generation,
        .auth_generation = context.auth_generation,
    }, value);
}

fn handleLegacyServerRequest(
    raw_context: *anyopaque,
    alloc: Allocator,
    request_json: []const u8,
) anyerror!void {
    const context: *LegacyElicitationContext = @ptrCast(@alignCast(raw_context));
    if (request_json.len > 128 * 1024) return error.McpResponseFrameTooLarge;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, request_json, .{
        .parse_numbers = false,
    }) catch return error.McpInvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidJson;
    const id = parsed.value.object.get("id") orelse return error.McpInvalidJson;
    if (!validLegacyServerRequestId(id)) {
        return sendLegacyServerRequestError(context, alloc, .null, -32600, "Invalid request id");
    }
    if (context.requests_seen.fetchAdd(1, .monotonic) >= 32) {
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Elicitation request limit exceeded");
    }
    const method = parsed.value.object.get("method") orelse return error.McpInvalidJson;
    if (method != .string or !std.mem.eql(u8, method.string, "elicitation/create")) {
        return sendLegacyServerRequestError(context, alloc, id, -32601, "Method not found");
    }
    const params = parsed.value.object.get("params") orelse
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Invalid params");
    const params_json = stringifyMcpValue(alloc, params) catch
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Invalid params");
    defer alloc.free(params_json);
    var request = elicitation.parseRequest(alloc, context.wire, params_json, .{}) catch
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Invalid params");
    defer request.deinit(alloc);
    if (!context.capabilities.supports(request.mode)) {
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Unsupported elicitation mode");
    }
    const responder = context.responder orelse
        return sendLegacyServerRequestError(context, alloc, id, -32602, "Elicitation unavailable");
    context.beginInputWait();
    defer context.endInputWait();
    const binding_current = context.bindingCurrent() catch |err| {
        return sendLegacyServerRequestError(context, alloc, id, -32603, @errorName(err));
    };
    if (!binding_current) {
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Elicitation owner changed");
    }

    var input_requests: std.Io.Writer.Allocating = .init(alloc);
    defer input_requests.deinit();
    try input_requests.writer.writeAll("{\"legacy\":{\"method\":\"elicitation/create\",\"params\":");
    try input_requests.writer.writeAll(params_json);
    try input_requests.writer.writeAll("}}");
    const origin = context.inputOrigin();
    const responses_json = responder.callback(
        responder.context,
        alloc,
        origin,
        .{ .input_requests_json = input_requests.writer.buffered() },
    ) catch |err| {
        return sendLegacyServerRequestError(context, alloc, id, -32603, @errorName(err));
    };
    defer alloc.free(responses_json);
    const response_binding_current = context.bindingCurrent() catch |err| {
        return sendLegacyServerRequestError(context, alloc, id, -32603, @errorName(err));
    };
    if (!response_binding_current) {
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Elicitation owner changed");
    }
    var responses = std.json.parseFromSlice(std.json.Value, alloc, responses_json, .{
        .parse_numbers = false,
    }) catch return sendLegacyServerRequestError(context, alloc, id, -32603, "Invalid elicitation response");
    defer responses.deinit();
    if (responses.value != .object or responses.value.object.count() != 1) {
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Invalid elicitation response");
    }
    const response = responses.value.object.get("legacy") orelse
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Invalid elicitation response");
    const response_json = try stringifyMcpValue(alloc, response);
    defer alloc.free(response_json);
    _ = elicitation.validateResponse(alloc, request, response_json, .{}) catch
        return sendLegacyServerRequestError(context, alloc, id, -32603, "Invalid elicitation response");

    var frame: std.Io.Writer.Allocating = .init(alloc);
    defer frame.deinit();
    try frame.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &frame.writer);
    try frame.writer.writeAll(",\"result\":");
    try frame.writer.writeAll(response_json);
    try frame.writer.writeByte('}');
    try context.sendFrame(alloc, frame.writer.buffered());
}

fn validLegacyServerRequestId(value: std.json.Value) bool {
    return switch (value) {
        .integer => true,
        .number_string => |text| blk: {
            _ = std.fmt.parseInt(i64, text, 10) catch break :blk false;
            break :blk true;
        },
        .string => |text| text.len <= 256,
        else => false,
    };
}

fn legacyWireForHttpVersion(version: legacy_streamable_http.Version) ?elicitation.Wire {
    return switch (version) {
        .v2025_11_25 => .legacy_mcp_2025_11,
        .v2025_06_18 => .legacy_mcp_2025_06,
        .v2025_03_26 => null,
    };
}

fn legacyWireForServer(server: *const McpServer) ?elicitation.Wire {
    if (std.mem.eql(
        u8,
        server.negotiated_protocol_version,
        legacy_2025_11_protocol_version,
    )) return .legacy_mcp_2025_11;
    if (std.mem.eql(
        u8,
        server.negotiated_protocol_version,
        legacy_2025_06_protocol_version,
    )) return .legacy_mcp_2025_06;
    return null;
}

fn sendLegacyServerRequestError(
    context: *LegacyElicitationContext,
    alloc: Allocator,
    id: std.json.Value,
    code: i64,
    message: []const u8,
) !void {
    var frame: std.Io.Writer.Allocating = .init(alloc);
    defer frame.deinit();
    try frame.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, &frame.writer);
    try frame.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.value(message, .{}, &frame.writer);
    try frame.writer.writeAll("}}");
    try context.sendFrame(alloc, frame.writer.buffered());
}

fn stringifyMcpValue(alloc: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn captureLegacyStreamableAuth(
    alloc: Allocator,
    server: *McpServer,
    client: *legacy_streamable_http.Client,
    control: streamable_http.Control,
) !void {
    const header = try client.copyAuthChallenge(alloc);
    defer if (header) |value| alloc.free(value);
    try captureAuthHeader(alloc, server, header, control);
}

fn captureAuthHeader(
    alloc: Allocator,
    server: *McpServer,
    header: ?[]const u8,
    control: streamable_http.Control,
) !void {
    var challenge = if (header) |value|
        mcp_auth.parseChallenge(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => mcp_auth.Challenge{},
        }
    else
        mcp_auth.Challenge{};
    defer challenge.deinit(alloc);
    try storePendingChallenge(alloc, server, challenge, control);
    markAuthenticationRequired(alloc, server);
}

fn sendLegacyHttpCancellation(
    alloc: Allocator,
    server: *McpServer,
    client: *legacy_streamable_http.Client,
    request_id: u64,
    reason: []const u8,
) void {
    const body = buildCancellationNotification(
        alloc,
        request_id,
        reason,
    ) catch |err| {
        debug_trace.logf(
            "mcp",
            "failed to build legacy HTTP cancellation server={s} request_id={d} err={s}",
            .{ server.config.name, request_id, @errorName(err) },
        );
        return;
    };
    defer alloc.free(body);
    const deadline = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)
        .addDuration(.{
        .clock = .awake,
        .raw = .fromMilliseconds(100),
    });
    client.sendNotification(alloc, body, .{ .deadline = deadline }) catch |err| {
        debug_trace.logf(
            "mcp",
            "failed to send legacy HTTP cancellation server={s} request_id={d} err={s}",
            .{ server.config.name, request_id, @errorName(err) },
        );
    };
}

fn buildCancellationNotification(
    alloc: Allocator,
    request_id: u64,
    reason: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":",
    );
    try out.writer.print("{d}", .{request_id});
    try out.writer.writeAll(",\"reason\":");
    try std.json.Stringify.value(reason, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn connectServerSse(
    alloc: Allocator,
    server: *McpServer,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *std.StringHashMap(void),
    control: ConnectionControl,
) !void {
    errdefer {
        removeServerToolNames(used_tool_names, server);
        clearServerTools(alloc, server);
    }
    const attempt_control = connectionAttemptControl(
        control,
        server.config.startup_timeout_ms,
    );
    try checkConnectionControl(attempt_control);
    const deadline = attempt_control.deadline.?;
    {
        try lockMutexUntil(&server.auth_lock, deadline, attempt_control.cancel_flag);
        defer server.auth_lock.unlock(io_mod.getIo());
        try refreshResolvedHeaders(alloc, server);
    }
    var startup_auth_challenge: ?[]u8 = null;
    defer if (startup_auth_challenge) |value| alloc.free(value);
    const client = legacy_http_sse.Client.create(
        alloc,
        std.heap.c_allocator,
        try server.config.remoteUrl(),
        server.resolved_headers,
        mcp_discovery_response_frame_cap_bytes,
        .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
        &startup_auth_challenge,
    ) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try captureAuthHeader(
                alloc,
                server,
                startup_auth_challenge,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };
    var client_owned = true;
    defer if (client_owned) client.deinit();

    var next_request_id: u64 = 1;
    const init_id = next_request_id;
    next_request_id += 1;
    const init_request = try buildLegacyInitializeRequest(
        alloc,
        init_id,
        legacy_http_sse.protocol_version,
        null,
        .{},
    );
    defer alloc.free(init_request);
    const init_response = client.request(
        alloc,
        init_id,
        init_request,
        mcp_discovery_response_frame_cap_bytes,
        .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
    ) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try captureLegacySseAuth(
                alloc,
                server,
                client,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };
    defer alloc.free(init_response);
    try legacy_http_sse.validateInitializeResponse(alloc, init_response);
    server.negotiated_protocol_version = legacy_http_sse.protocol_version;
    const initialized_capabilities = try parseServerCapabilitiesFromResponse(
        alloc,
        init_response,
    );
    server.tools_list_changed = initialized_capabilities.tools_list_changed;
    server.capabilities = initialized_capabilities.features;
    try parseAndStoreServerIdentity(alloc, server, init_response);
    try parseAndStoreServerInstructionsForProtocol(
        alloc,
        server,
        init_response,
        .legacy,
    );
    client.sendNotification(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}",
        .{
            .deadline = deadline,
            .cancel_flag = attempt_control.cancel_flag,
            .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
        },
    ) catch |err| {
        if (err == error.McpAuthenticationRequired) {
            try captureLegacySseAuth(
                alloc,
                server,
                client,
                .{
                    .deadline = deadline,
                    .cancel_flag = attempt_control.cancel_flag,
                    .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                },
            );
        }
        return err;
    };

    var builder = tools_feature.CatalogBuilder.init(alloc, .legacy);
    defer builder.deinit(alloc);
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    while (true) {
        const tools_id = next_request_id;
        next_request_id = std.math.add(u64, tools_id, 1) catch
            return error.McpRequestIdExhausted;
        const tools_request = try buildToolsListRequest(alloc, tools_id, .legacy, cursor);
        defer alloc.free(tools_request);
        const tools_response = client.request(
            alloc,
            tools_id,
            tools_request,
            mcp_discovery_response_frame_cap_bytes,
            .{
                .deadline = deadline,
                .cancel_flag = attempt_control.cancel_flag,
                .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
            },
        ) catch |err| {
            if (err == error.McpAuthenticationRequired) {
                try captureLegacySseAuth(
                    alloc,
                    server,
                    client,
                    .{
                        .deadline = deadline,
                        .cancel_flag = attempt_control.cancel_flag,
                        .lifecycle_cancel_flag = attempt_control.lifecycle_cancel_flag,
                    },
                );
            }
            return err;
        };
        const received_at_ms = clockMillis();
        defer alloc.free(tools_response);
        var page = try tools_feature.parseListPage(alloc, tools_response, .legacy, .{});
        defer page.deinit(alloc);
        if (cursor) |value| alloc.free(value);
        cursor = if (page.next_cursor) |value| try alloc.dupe(u8, value) else null;
        try builder.appendPage(alloc, &page, received_at_ms, .{});
        if (cursor == null) break;
    }
    var catalog = try builder.finish(alloc);
    defer catalog.deinit(alloc);
    try storeProtocolTools(alloc, server, tool_registry, catalog, used_tool_names, .legacy, null);

    server.legacy_sse = client;
    client_owned = false;
    server.http_next_request_id.store(next_request_id, .seq_cst);
    try startToolSubscription(alloc, server, attempt_control);
    server.setReady(alloc);
}

fn callToolSse(
    self: *McpRuntime,
    alloc: Allocator,
    server: *McpServer,
    snapshot: *ToolCallSnapshot,
    arguments_json: []const u8,
    max_tool_result_bytes: usize,
    options: tool_mcp_runtime.CallOptions,
    deadline: std.Io.Clock.Timestamp,
) !tool_mcp_runtime.CallResult {
    try lockRwSharedUntil(
        &server.connection_lock,
        deadline,
        options.cancel_flag,
    );
    var connection_locked = true;
    var reconnected_for_credentials = false;
    defer if (connection_locked) {
        server.connection_lock.unlockShared(io_mod.getIo());
    };
    if (server.legacy_sse != null and try legacyConnectionNeedsCredentialUpdate(
        server,
        deadline,
        options.cancel_flag,
    )) {
        server.connection_lock.unlockShared(io_mod.getIo());
        connection_locked = false;
        try reauthorizeOperation(
            self,
            options.access,
            .{ .tool = snapshot.prefixed_name },
        );
        switch (options.access) {
            .unrestricted => {},
            .disabled, .scoped => return error.McpAuthenticationRequired,
        }
        try reconnectLegacyForCredentials(
            self,
            server,
            deadline,
            options.cancel_flag,
        );
        try lockRwSharedUntil(
            &server.connection_lock,
            deadline,
            options.cancel_flag,
        );
        connection_locked = true;
        reconnected_for_credentials = true;
    }
    const snapshot_current = if (reconnected_for_credentials and options.continuation == null)
        try refreshRemoteSnapshotAfterReconnect(
            self,
            server,
            snapshot,
            deadline,
            options.cancel_flag,
        )
    else
        try httpToolSnapshotMatchesCurrent(
            self,
            server,
            snapshot,
            deadline,
            options.cancel_flag,
        );
    if (!snapshot_current) return error.McpToolCatalogChanged;

    const client = server.legacy_sse orelse return error.McpConnectionClosed;
    const request_id = try reserveHttpRequestId(server);
    const request_body = try buildToolCallRequestForProtocol(
        alloc,
        request_id,
        snapshot.original_name,
        arguments_json,
        .legacy,
        null,
        options.continuation,
        .{},
    );
    defer alloc.free(request_body);
    const raw_frame_cap = mcpResponseFrameCap(max_tool_result_bytes);
    var tool_precommit = ToolPrecommit{
        .runtime = self,
        .server = server,
        .snapshot = snapshot,
        .deadline = deadline,
        .cancel_flag = options.cancel_flag,
        .access = options.access,
    };
    var transport_precommit = tool_precommit.transport();
    const response = client.request(
        alloc,
        request_id,
        request_body,
        raw_frame_cap,
        .{
            .deadline = deadline,
            .cancel_flag = options.cancel_flag,
            .lifecycle_cancel_flag = &self.retiring,
            .precommit = &transport_precommit,
        },
    ) catch |err| switch (err) {
        error.McpResponseFrameTooLarge, error.SseEventTooLarge => {
            return handleMcpResponseFrameTooLarge(
                alloc,
                server,
                snapshot.prefixed_name,
                raw_frame_cap,
            );
        },
        error.McpAuthenticationRequired => {
            try captureLegacySseAuth(
                self.alloc,
                server,
                client,
                .{
                    .deadline = deadline,
                    .cancel_flag = options.cancel_flag,
                    .lifecycle_cancel_flag = &self.retiring,
                },
            );
            return error.McpAuthenticationRequired;
        },
        else => |request_err| return request_err,
    };
    defer alloc.free(response);
    return tool_result.extract(alloc, .{
        .server_name = server.config.name,
        .tool_name = snapshot.prefixed_name,
        .response = response,
        .max_tool_result_bytes = max_tool_result_bytes,
        .protocol = .legacy,
        .output_schema_json = snapshot.output_schema_json,
    });
}

fn captureLegacySseAuth(
    alloc: Allocator,
    server: *McpServer,
    client: *legacy_http_sse.Client,
    control: streamable_http.Control,
) !void {
    const header = try client.copyAuthChallenge(alloc);
    defer if (header) |value| alloc.free(value);
    try captureAuthHeader(alloc, server, header, control);
}

fn allocateToolName(
    alloc: Allocator,
    tool_registry: tool_dispatch.Registry,
    used_tool_names: *std.StringHashMap(void),
    server_name: []const u8,
    tool_name: []const u8,
) ![]u8 {
    const base = try buildBaseToolName(alloc, server_name, tool_name);
    defer alloc.free(base);

    var suffix_index: ?usize = null;
    while (true) {
        const candidate = try candidateWithSuffix(alloc, base, suffix_index);
        if (tool_registry.lookup(candidate) == null and !used_tool_names.contains(candidate)) {
            return candidate;
        }

        alloc.free(candidate);
        suffix_index = if (suffix_index) |index| index + 1 else 2;
    }
}

fn buildBaseToolName(alloc: Allocator, server_name: []const u8, tool_name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("mcp_");
    if (server_name.len == 0) {
        try out.writer.writeAll("server");
    } else {
        try writeSanitizedSegment(&out.writer, server_name);
    }
    try out.writer.writeByte('_');
    if (tool_name.len == 0) {
        try out.writer.writeAll("tool");
    } else {
        try writeSanitizedSegment(&out.writer, tool_name);
    }

    return try out.toOwnedSlice();
}

fn writeSanitizedSegment(writer: *std.Io.Writer, segment: []const u8) !void {
    for (segment) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('_');
        }
    }
}

fn candidateWithSuffix(alloc: Allocator, base: []const u8, suffix_index: ?usize) ![]u8 {
    const max_name_len = 64;
    if (suffix_index) |index| {
        const suffix = try std.fmt.allocPrint(alloc, "_{d}", .{index});
        defer alloc.free(suffix);

        const prefix_len = @min(base.len, max_name_len - suffix.len);
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ base[0..prefix_len], suffix });
    }

    return alloc.dupe(u8, base[0..@min(base.len, max_name_len)]);
}

fn checkAllocateToolNameCollisionAllocFailures(alloc: Allocator) !void {
    var used = std.StringHashMap(void).init(alloc);
    defer used.deinit();

    try used.put("mcp_a_b_c", {});

    const name = allocateToolName(alloc, .{}, &used, "a b", "c") catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer alloc.free(name);

    try std.testing.expectEqualStrings("mcp_a_b_c_2", name);
}

fn shellMcpConfigForTest(alloc: Allocator, name: []const u8, script: []const u8) !McpServerConfig {
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const command = try alloc.dupe(u8, "sh");
    errdefer alloc.free(command);
    const args = try alloc.alloc([]const u8, 2);
    errdefer alloc.free(args);
    args[0] = try alloc.dupe(u8, "-c");
    errdefer alloc.free(args[0]);
    args[1] = try alloc.dupe(u8, script);
    errdefer alloc.free(args[1]);
    return .{
        .name = owned_name,
        .command = command,
        .args = args,
    };
}

fn shellMcpConfigWithModeForTest(
    alloc: Allocator,
    name: []const u8,
    script: []const u8,
    mode: []const u8,
) !McpServerConfig {
    var config = try shellMcpConfigForTest(alloc, name, script);
    errdefer config.deinit(alloc);
    const args = try alloc.alloc([]const u8, 3);
    errdefer alloc.free(args);
    args[0] = config.args[0];
    args[1] = config.args[1];
    args[2] = try alloc.dupe(u8, mode);
    errdefer alloc.free(args[2]);
    alloc.free(config.args);
    config.args = args;
    return config;
}

const resource_resolution_shell_server =
    \\mode=$0
    \\while IFS= read -r line; do
    \\  id=${line#*'"id":'}
    \\  id=${id%%,*}
    \\  case "$line" in
    \\    *'"method":"server/discover"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","id":0,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{}}}}'
    \\      ;;
    \\    *'"method":"tools/list"'*)
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"tools":[]}}\n' "$id"
    \\      ;;
    \\    *'"method":"resources/list"'*)
    \\      if [ "$mode" = exact ]; then
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resources":[{"uri":"memory://exact","name":"exact"}]}}\n' "$id"
    \\      else
    \\        printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resources":[]}}\n' "$id"
    \\      fi
    \\      ;;
    \\    *'"method":"resources/templates/list"'*)
    \\      case "$mode" in
    \\        exact) exit 7 ;;
    \\        invalid) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","nextCursor":"","resourceTemplates":[]}}\n' "$id" ;;
    \\        cancel) sleep 1; printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","resourceTemplates":[]}}\n' "$id" ;;
    \\        missing) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","ttlMs":60000,"resourceTemplates":[]}}\n' "$id" ;;
    \\        *) exit 9 ;;
    \\      esac
    \\      ;;
    \\    *'"method":"notifications/cancelled"'*)
    \\      ;;
    \\    *'"method":"resources/read"'*'memory://exact'*)
    \\      if [ "$mode" != exact ]; then exit 8; fi
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","contents":[{"uri":"memory://exact","text":"exact-resource"}]}}\n' "$id"
    \\      ;;
    \\    *'"method":"resources/read"'*)
    \\      exit 8
    \\      ;;
    \\    *)
    \\      exit 3
    \\      ;;
    \\  esac
    \\done
;

fn acceptResourceInputForTest(
    context: *anyopaque,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    required: tool_mcp_runtime.InputRequired,
) anyerror![]const u8 {
    const calls: *usize = @ptrCast(@alignCast(context));
    calls.* += 1;
    if (std.mem.find(u8, required.input_requests_json, "confirm") == null or
        required.request_state_json == null)
    {
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, origin.server_name, "mrtr-cache") or
        origin.operation != .resources_read)
    {
        return error.TestUnexpectedResult;
    }
    return alloc.dupe(u8, "{\"confirm\":{\"action\":\"accept\",\"content\":{\"confirmed\":true}}}");
}

fn expectResourceText(result: ResourceReadResult, expected: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), result.contents.len);
    switch (result.contents[0].data) {
        .text => |text| try std.testing.expectEqualStrings(expected, text),
        .blob => return error.TestUnexpectedResult,
    }
}

fn expectTestProcessExited(pid: std.posix.pid_t) !void {
    for (0..200) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => {},
        };
        if (builtin.os.tag == .linux and testProcessIsZombie(pid)) return;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return error.TestProcessStillRunning;
}

fn testProcessIsZombie(pid: std.posix.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return false;
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return false;
    defer file.close(io_mod.getIo());

    var reader_buf: [512]u8 = undefined;
    var status_buf: [512]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &reader_buf);
    const read_len = reader.interface.readSliceShort(&status_buf) catch return false;
    return std.mem.find(u8, status_buf[0..read_len], "\nState:\tZ") != null;
}

fn resourceTemplateSnapshotServerForTest(
    templates: []resources_feature.Template,
) McpServer {
    const digest = feature_cache.authIdentity(&.{});
    const template_metadata = feature_cache.SnapshotMetadata{
        .key = feature_cache.buildCacheKey(.{
            .server_identity = "allocation-fixture",
            .protocol_version = modern_protocol_version,
            .capability = .resource_templates_list,
            .normalized_arguments = "{}",
            .scope = .public,
            .auth_identity = digest,
        }),
        .connection_generation = 0,
        .catalog_generation = 1,
        .fetched_at_ms = 1,
        .expires_at_ms = std.math.maxInt(u64),
        .scope = .public,
        .content_digest = digest,
    };
    return .{
        .config = .{ .name = "allocation-fixture" },
        .resource_catalog = .{
            .catalog = .{
                .items = &.{},
                .fetched_at_ms = 1,
                .expires_at_ms = std.math.maxInt(u64),
                .cache_scope = .public,
            },
            .metadata = feature_cache.SnapshotMetadata{
                .key = feature_cache.buildCacheKey(.{
                    .server_identity = "allocation-fixture",
                    .protocol_version = modern_protocol_version,
                    .capability = .resources_list,
                    .normalized_arguments = "{}",
                    .scope = .public,
                    .auth_identity = digest,
                }),
                .connection_generation = 0,
                .catalog_generation = 1,
                .fetched_at_ms = 1,
                .expires_at_ms = std.math.maxInt(u64),
                .scope = .public,
                .content_digest = digest,
            },
            .available = true,
        },
        .resource_template_catalog = .{
            .catalog = .{
                .items = templates,
                .fetched_at_ms = 1,
                .expires_at_ms = std.math.maxInt(u64),
                .cache_scope = .public,
            },
            .metadata = template_metadata,
            .available = true,
        },
    };
}

fn resourceReadPublicationServerForTest(
    descriptors: []resources_feature.Descriptor,
) McpServer {
    const digest = feature_cache.authIdentity(&.{});
    const metadata = feature_cache.SnapshotMetadata{
        .key = feature_cache.buildCacheKey(.{
            .server_identity = "resource-read-publication",
            .protocol_version = modern_protocol_version,
            .capability = .resources_list,
            .normalized_arguments = "{}",
            .scope = .public,
            .auth_identity = digest,
        }),
        .connection_generation = 1,
        .catalog_generation = 1,
        .fetched_at_ms = 1,
        .expires_at_ms = std.math.maxInt(u64),
        .scope = .public,
        .content_digest = digest,
    };
    return .{
        .config = .{ .name = "resource-read-publication" },
        .connection_generation = 1,
        .stdio_protocol = .modern,
        .negotiated_protocol_version = modern_protocol_version,
        .resource_catalog = .{
            .catalog = .{
                .items = descriptors,
                .fetched_at_ms = 1,
                .expires_at_ms = std.math.maxInt(u64),
                .cache_scope = .public,
            },
            .metadata = metadata,
            .available = true,
        },
    };
}

fn resourceReadPublicationSnapshotForTest(
    server: *const McpServer,
) FeatureIdentitySnapshot {
    return .{
        .server_name = @constCast(server.config.name),
        .identity = @constCast("memory://owned"),
        .kind = .resource,
        .cache_key = server.resource_catalog.metadata.?.key,
        .connection_generation = server.connection_generation,
        .catalog_generation = server.resource_catalog.metadata.?.catalog_generation,
    };
}

fn fetchedResourceReadForTest(
    alloc: Allocator,
    cache_eligible: bool,
) !FetchedResourceRead {
    const contents = try alloc.alloc(resources_feature.ResourceContent, 1);
    errdefer alloc.free(contents);
    const uri = try alloc.dupe(u8, "memory://owned");
    errdefer alloc.free(uri);
    const text = try alloc.dupe(u8, "owned contents");
    contents[0] = .{ .uri = uri, .data = .{ .text = text } };
    return .{
        .result = .{
            .contents = contents,
            .cache = .{ .ttl_ms = 60_000, .ttl_present = true, .scope = .public },
            .cache_eligible = cache_eligible,
        },
        .auth_identity = null,
        .received_at_ms = 1,
    };
}

fn deinitResourceReadCacheForTest(server: *McpServer, alloc: Allocator) void {
    for (server.resource_read_cache.items) |*entry| entry.deinit(alloc);
    server.resource_read_cache.deinit(alloc);
    server.resource_read_cache = .empty;
}

fn checkResourceReadFinishAllocationFailures(
    alloc: Allocator,
    cache_eligible: bool,
) !void {
    var descriptors = [_]resources_feature.Descriptor{.{
        .uri = @constCast("memory://owned"),
        .name = @constCast("owned"),
    }};
    var server = resourceReadPublicationServerForTest(&descriptors);
    defer deinitResourceReadCacheForTest(&server, alloc);
    var runtime = McpRuntime.init(alloc);
    defer runtime.deinit();
    const snapshot = resourceReadPublicationSnapshotForTest(&server);
    const fetched = try fetchedResourceReadForTest(alloc, cache_eligible);
    var result = try finishFetchedResourceRead(
        &runtime,
        alloc,
        &server,
        &snapshot,
        "memory://owned",
        fetched,
        std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
            .clock = .awake,
            .raw = .fromSeconds(1),
        }),
        null,
        .unrestricted,
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, @intFromBool(cache_eligible)),
        server.resource_read_cache.items.len,
    );
    try expectResourceText(result, "owned contents");
}

fn checkResourceSnapshotWithTemplatesAllocationFailures(alloc: Allocator) !void {
    var templates = [_]resources_feature.Template{.{
        .uri_template = @constCast("memory://{value}"),
        .name = @constCast("value"),
    }};
    var server = resourceTemplateSnapshotServerForTest(&templates);
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromSeconds(1),
    });
    var snapshot = try snapshotResourceIdentityWithTemplates(
        &runtime,
        alloc,
        &server,
        "memory://accepted",
        deadline,
        null,
    );
    defer snapshot.deinit(alloc);
    try std.testing.expectEqualStrings("memory://accepted", snapshot.requested_uri.?);
}

fn checkModelCatalogSnapshotAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try std.testing.allocator.dupe(u8, "one"),
        .command = try std.testing.allocator.dupe(u8, "fixture"),
        .enabled = false,
    });
    try runtime.addServer(.{
        .name = try std.testing.allocator.dupe(u8, "two"),
        .command = try std.testing.allocator.dupe(u8, "fixture"),
        .enabled = false,
    });
    runtime.discovery_state.store(.complete, .release);
    for (runtime.servers.items) |*server| server.state = .disabled;

    var snapshot = try runtime.snapshotModelCatalog(alloc, .{}, false);
    snapshot.deinit(alloc);
}

fn checkHealthSnapshotAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try std.testing.allocator.dupe(u8, "server"),
        .command = try std.testing.allocator.dupe(u8, "fixture"),
        .enabled = false,
    });
    var snapshot = try runtime.snapshotHealth(alloc, 42);
    defer snapshot.deinit(alloc);
}

fn checkToolSnapshotBuildAllocationFailures(alloc: Allocator) !void {
    var used = std.StringHashMap(void).init(alloc);
    defer used.deinit();
    const server = McpServer{
        .config = .{ .name = "snapshot", .transport = .stdio },
    };
    const protocol_tools = [_]tools_feature.Tool{.{
        .name = @constCast("echo"),
        .title = @constCast("Echo"),
        .description = @constCast("Echo input"),
        .input_schema_json = @constCast("{\"type\":\"object\"}"),
        .output_schema_json = @constCast("{\"type\":\"object\"}"),
        .icons_json = @constCast("[]"),
        .annotations_json = @constCast("{}"),
        .metadata_json = @constCast("{}"),
    }};
    var snapshot = buildProtocolTools(
        alloc,
        &server,
        .{},
        &protocol_tools,
        &used,
        .modern,
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer snapshot.deinit(alloc);
}

fn checkCursorReplacementAllocationFailures(alloc: Allocator) !void {
    var cursor: ?[]u8 = null;
    defer if (cursor) |value| alloc.free(value);
    cursor = try alloc.dupe(u8, "first");
    try replaceOwnedCursor(alloc, &cursor, "second");
    try std.testing.expectEqualStrings("second", cursor.?);
}

fn checkServerDiagnosticSnapshotAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(alloc);
    defer runtime.servers.deinit(alloc);
    var server = McpServer{
        .config = .{ .name = "fixture", .command = "fixture-command" },
        .state = .failed,
    };
    server.last_error = try alloc.dupe(u8, "fixture-error");
    defer alloc.free(server.last_error.?);
    try runtime.servers.append(alloc, server);

    var snapshot = try runtime.snapshotServerDiagnostics(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try std.testing.expectEqualStrings("fixture", snapshot.items[0].name);
    try std.testing.expectEqualStrings("fixture-error", snapshot.items[0].last_error.?);
}

fn checkAccessSnapshotAllocationFailures(alloc: Allocator) !void {
    var runtime = McpRuntime.init(std.testing.allocator);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try std.testing.allocator.dupe(u8, "fixture"),
        .command = try std.testing.allocator.dupe(u8, "cmd"),
    });
    runtime.servers.items[0].state = .ready;
    var used = std.StringHashMap(void).init(std.testing.allocator);
    defer used.deinit();
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}
    ;
    try parseAndStoreTools(
        std.testing.allocator,
        &runtime.servers.items[0],
        .{},
        response,
        &used,
    );
    var view = try runtime.snapshotAccessView(alloc, "child", "parent", .{}, true);
    defer view.deinit(alloc);
}
