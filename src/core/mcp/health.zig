const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const max_pending_summary_names: usize = 4;

pub const ConnectionState = enum {
    disconnected,
    disabled,
    connecting,
    ready,
    failed,
};

pub fn observedConnection(
    published: ConnectionState,
    transport_running: ?bool,
) ConnectionState {
    if (published == .ready and transport_running == false) return .failed;
    return published;
}

pub fn retryDelay(retry_at_ms: ?u64, captured_at_ms: u64) ?u64 {
    const retry_at = retry_at_ms orelse return null;
    return retry_at -| captured_at_ms;
}

pub const AuthenticationState = enum {
    none,
    configured,
    authenticated,
    required,
};

pub const CacheFreshness = enum {
    unavailable,
    fresh,
    stale,
    refreshing,
    failed_refresh,
};

pub const SubscriptionState = enum {
    unavailable,
    starting,
    active,
    unsupported,
    stopped,
};

pub const CapabilityCounts = struct {
    tools: ?usize = null,
    resources: ?usize = null,
    resource_templates: ?usize = null,
    prompts: ?usize = null,
};

pub fn capabilityCount(advertised: bool, loaded: bool, count: usize) ?usize {
    if (!advertised) return 0;
    return if (loaded) count else null;
}

pub const SubscriptionObservation = struct {
    present: bool,
    unsupported: bool = false,
    finished: bool = false,
    requires_acknowledgement: bool = false,
    acknowledged: bool = false,
};

pub fn subscriptionStateFor(observation: SubscriptionObservation) SubscriptionState {
    if (!observation.present) return .unavailable;
    if (observation.unsupported) return .unsupported;
    if (observation.finished) return .stopped;
    if (!observation.requires_acknowledgement or observation.acknowledged) return .active;
    return .starting;
}

pub const ServerSnapshot = struct {
    configured_name: []u8,
    negotiated_name: ?[]u8,
    negotiated_version: ?[]u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    workspace_admission: ?mcp_contract.WorkspaceAdmission = null,
    required: bool,
    transport: mcp_contract.McpTransport,
    protocol_version: ?[]u8,
    connection: ConnectionState,
    authentication: AuthenticationState,
    counts: CapabilityCounts,
    cache_freshness: CacheFreshness,
    subscription: SubscriptionState,
    runtime_generation: u64,
    catalog_generation: u64,
    retry_attempt: u8,
    retry_in_ms: ?u64,
    last_successful_discovery_ms: ?u64,
    failure: ?[]u8,

    pub fn deinit(self: *ServerSnapshot, alloc: Allocator) void {
        alloc.free(self.configured_name);
        if (self.negotiated_name) |value| alloc.free(value);
        if (self.negotiated_version) |value| alloc.free(value);
        if (self.protocol_version) |value| alloc.free(value);
        if (self.failure) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ConfigurationIssue = struct {
    message: []u8,

    pub fn deinit(self: *ConfigurationIssue, alloc: Allocator) void {
        alloc.free(self.message);
        self.* = undefined;
    }
};

pub const ConfiguredServerSnapshot = struct {
    configured_name: []u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    workspace_admission: ?mcp_contract.WorkspaceAdmission = null,
    required: bool,
    transport: mcp_contract.McpTransport,

    pub fn deinit(self: *ConfiguredServerSnapshot, alloc: Allocator) void {
        alloc.free(self.configured_name);
        self.* = undefined;
    }
};

pub const LocalConfigSnapshot = struct {
    servers: []ConfiguredServerSnapshot,
    configuration_issues: []ConfigurationIssue,

    pub fn deinit(self: *LocalConfigSnapshot, alloc: Allocator) void {
        for (self.servers) |*server| server.deinit(alloc);
        alloc.free(self.servers);
        for (self.configuration_issues) |*issue| issue.deinit(alloc);
        alloc.free(self.configuration_issues);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    captured_at_ms: u64,
    servers: []ServerSnapshot,
    configuration_issues: []ConfigurationIssue = &.{},

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.servers) |*server| server.deinit(alloc);
        alloc.free(self.servers);
        for (self.configuration_issues) |*issue| issue.deinit(alloc);
        alloc.free(self.configuration_issues);
        self.* = undefined;
    }
};

pub const LocalConfigInspection = struct {
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic = .clear,
    snapshot: LocalConfigSnapshot,
    inspection_error: ?[]const u8 = null,

    pub fn deinit(self: *LocalConfigInspection, alloc: Allocator) void {
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

pub const InspectLocalConfigFn = *const fn (
    Allocator,
    []const u8,
) error{OutOfMemory}!LocalConfigInspection;

pub fn inspectLocalConfigUnavailable(
    alloc: Allocator,
    _: []const u8,
) error{OutOfMemory}!LocalConfigInspection {
    const servers = try alloc.alloc(ConfiguredServerSnapshot, 0);
    errdefer alloc.free(servers);
    return .{ .snapshot = .{
        .servers = servers,
        .configuration_issues = try alloc.alloc(ConfigurationIssue, 0),
    } };
}

pub const StartupDecision = enum {
    ready,
    degraded,
    blocked,
};

pub fn startupDecision(servers: []const ServerSnapshot) StartupDecision {
    var degraded = false;
    for (servers) |server| {
        if (server.connection == .ready or server.connection == .disabled and !server.required) continue;
        if (server.required) return .blocked;
        degraded = true;
    }
    return if (degraded) .degraded else .ready;
}

fn publishCandidate(servers: []const ServerSnapshot) bool {
    return startupDecision(servers) != .blocked;
}

pub fn publishCandidateForDecision(decision: StartupDecision) bool {
    return decision != .blocked;
}

pub fn render(alloc: Allocator, snapshot: Snapshot) ![]u8 {
    if (snapshot.servers.len == 0 and snapshot.configuration_issues.len == 0) {
        return alloc.dupe(u8, "No MCP servers configured.\n");
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (snapshot.servers.len > 0) {
        try out.writer.print("MCP health ({d} {s}):\n", .{
            snapshot.servers.len,
            if (snapshot.servers.len == 1) "server" else "servers",
        });
    }
    for (snapshot.servers) |server| {
        try out.writer.print(
            "  {s} source={s} scope={s} policy={s} transport={s} state={s} auth={s}\n",
            .{
                server.configured_name,
                @tagName(server.source),
                @tagName(server.scope),
                if (server.required) "required" else "optional",
                @tagName(server.transport),
                @tagName(server.connection),
                @tagName(server.authentication),
            },
        );
        if (server.workspace_admission) |admission| {
            try out.writer.print("    admission={s}\n", .{@tagName(admission)});
        }
        try out.writer.print(
            "    negotiated_name={s} negotiated_version={s} protocol={s}\n",
            .{
                server.negotiated_name orelse "unavailable",
                server.negotiated_version orelse "unavailable",
                server.protocol_version orelse "unavailable",
            },
        );
        try out.writer.writeAll("    tools=");
        try writeOptionalCount(&out.writer, server.counts.tools);
        try out.writer.writeAll(" resources=");
        try writeOptionalCount(&out.writer, server.counts.resources);
        try out.writer.writeAll(" templates=");
        try writeOptionalCount(&out.writer, server.counts.resource_templates);
        try out.writer.writeAll(" prompts=");
        try writeOptionalCount(&out.writer, server.counts.prompts);
        try out.writer.print(
            " cache={s} subscription={s}\n",
            .{ @tagName(server.cache_freshness), @tagName(server.subscription) },
        );
        try out.writer.print("    retry_attempt={d} retry_in_ms=", .{server.retry_attempt});
        if (server.retry_in_ms) |value| try out.writer.print("{d}", .{value}) else try out.writer.writeAll("none");
        try out.writer.print(
            " discovery={s}",
            .{if (server.last_successful_discovery_ms == null) "pending" else "completed"},
        );
        try out.writer.writeByte('\n');
        if (server.failure) |failure| try out.writer.print("    failure={s}\n", .{failure});
    }
    if (snapshot.configuration_issues.len > 0) {
        try out.writer.writeAll("Project MCP configuration errors:\n");
        for (snapshot.configuration_issues) |issue| {
            try out.writer.print("  {s}\n", .{issue.message});
        }
    }
    return out.toOwnedSlice();
}

pub fn renderSummary(alloc: Allocator, snapshot: Snapshot) ![]u8 {
    if (snapshot.servers.len == 0 and snapshot.configuration_issues.len == 0) {
        return alloc.dupe(
            u8,
            "MCP: no servers configured. Use /mcp add <name> <command> [args...].",
        );
    }
    if (snapshot.servers.len == 0) {
        return std.fmt.allocPrint(
            alloc,
            "MCP: {d} project .mcp.json {s}. Use /mcp list for details.",
            .{
                snapshot.configuration_issues.len,
                if (snapshot.configuration_issues.len == 1) "error" else "errors",
            },
        );
    }
    var ready: usize = 0;
    var connecting: usize = 0;
    var auth_required: usize = 0;
    var failed: usize = 0;
    var first_auth_server: ?[]const u8 = null;
    var pending_names: [max_pending_summary_names][]const u8 = undefined;
    var pending_count: usize = 0;
    for (snapshot.servers) |server| {
        if (server.source == .workspace and
            server.workspace_admission == .pending)
        {
            if (pending_count < pending_names.len) {
                pending_names[pending_count] = server.configured_name;
            }
            pending_count += 1;
        }
        if (server.authentication == .required) {
            auth_required += 1;
            if (first_auth_server == null) first_auth_server = server.configured_name;
            continue;
        }
        switch (server.connection) {
            .ready => ready += 1,
            .connecting => connecting += 1,
            .failed => failed += 1,
            .disconnected, .disabled => {},
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print(
        "MCP: {d} {s} — {d} ready, {d} connecting, {d} needs auth, {d} failed.",
        .{
            snapshot.servers.len,
            if (snapshot.servers.len == 1) "server" else "servers",
            ready,
            connecting,
            auth_required,
            failed,
        },
    );
    if (first_auth_server) |name| {
        try out.writer.print(" Run /mcp auth {s} --open.", .{name});
    }
    if (pending_count > 0) {
        try out.writer.writeAll(" Pending approval: ");
        const rendered_count = @min(pending_count, pending_names.len);
        for (pending_names[0..rendered_count], 0..) |name, index| {
            if (index > 0) try out.writer.writeAll(", ");
            var encoded = try text_utils.encodeTerminalSafe(alloc, name, 128);
            defer encoded.deinit(alloc);
            try out.writer.writeAll(encoded.bytes);
        }
        if (pending_count > rendered_count) {
            try out.writer.print(", +{d} more", .{pending_count - rendered_count});
        }
        try out.writer.writeByte('.');
    }
    if (snapshot.configuration_issues.len > 0) {
        try out.writer.print(
            " Project .mcp.json errors: {d}.",
            .{snapshot.configuration_issues.len},
        );
    }
    try out.writer.writeAll(" Use /mcp list for details.");
    return out.toOwnedSlice();
}

fn writeOptionalCount(writer: *std.Io.Writer, count: ?usize) !void {
    if (count) |value| try writer.print("{d}", .{value}) else try writer.writeAll("unknown");
}







fn emptyServerSnapshot() ServerSnapshot {
    return .{
        .configured_name = &.{},
        .negotiated_name = null,
        .negotiated_version = null,
        .source = .profile,
        .scope = .profile,
        .required = false,
        .transport = .stdio,
        .protocol_version = null,
        .connection = .disconnected,
        .authentication = .none,
        .counts = .{},
        .cache_freshness = .unavailable,
        .subscription = .unavailable,
        .runtime_generation = 0,
        .catalog_generation = 0,
        .retry_attempt = 0,
        .retry_in_ms = null,
        .last_successful_discovery_ms = null,
        .failure = null,
    };
}
