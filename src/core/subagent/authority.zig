const std = @import("std");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const permissions = @import("../permissions/permissions.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const PermissionAdmissionError = error{PermissionEscalation};

fn permissionRank(mode: types.PermissionMode) u2 {
    return switch (mode) {
        .ask => 0,
        .auto => 1,
        .yolo => 2,
    };
}

pub fn admitChildPermission(
    parent: types.PermissionMode,
    requested: ?types.PermissionMode,
) PermissionAdmissionError!types.PermissionMode {
    const child = requested orelse parent;
    if (permissionRank(child) > permissionRank(parent)) {
        return error.PermissionEscalation;
    }
    return child;
}

pub const Error = error{
    OutOfMemory,
    ChildNotAttached,
    InvalidControlRecord,
    StoreUnavailable,
    HostAuthorityUnavailable,
};

pub const HostAuthority = struct {
    generation: u64,
    tools: [][]u8,
    integrations: [][]u8,
    rules: types.PermissionRuleSet,
    grants: []types.PermissionGrant,
    permission_state: session_permission_state.State = .{},
    mcp_view: ?mcp_access.View = null,

    pub fn capture(
        alloc: Allocator,
        tools: []const []const u8,
        integrations: []const []const u8,
        rules: types.PermissionRuleSet,
        grants: []const types.PermissionGrant,
    ) !HostAuthority {
        return captureWithPermissionStateAndMcpView(
            alloc,
            tools,
            integrations,
            rules,
            grants,
            .{},
            null,
        );
    }

    pub fn captureWithPermissionStateAndMcpView(
        alloc: Allocator,
        tools: []const []const u8,
        integrations: []const []const u8,
        rules: types.PermissionRuleSet,
        grants: []const types.PermissionGrant,
        permission_state: session_permission_state.State,
        mcp_view: ?*const mcp_access.View,
    ) !HostAuthority {
        const owned_tools = try cloneStrings(alloc, tools);
        errdefer freeStrings(alloc, owned_tools);
        const owned_integrations = try cloneStrings(alloc, integrations);
        errdefer freeStrings(alloc, owned_integrations);
        var owned_rules = try types.dupePermissionRuleSet(alloc, rules);
        errdefer owned_rules.deinit(alloc);
        const owned_permission_state = try session_permission_state.projectForChild(
            alloc,
            permission_state,
            &.{},
        );
        errdefer {
            var value = owned_permission_state;
            value.deinit(alloc);
        }
        var owned_mcp_view = if (mcp_view) |view| try view.clone(alloc) else null;
        errdefer if (owned_mcp_view) |*view| view.deinit(alloc);
        return .{
            .generation = hostGeneration(
                tools,
                integrations,
                rules,
                grants,
                owned_permission_state,
                mcp_view,
            ),
            .tools = owned_tools,
            .integrations = owned_integrations,
            .rules = owned_rules,
            .grants = try types.dupePermissionGrantSlice(alloc, grants),
            .permission_state = owned_permission_state,
            .mcp_view = owned_mcp_view,
        };
    }

    pub fn deinit(self: *HostAuthority, alloc: Allocator) void {
        freeStrings(alloc, self.tools);
        freeStrings(alloc, self.integrations);
        self.rules.deinit(alloc);
        types.freePermissionGrantSlice(alloc, self.grants);
        self.permission_state.deinit(alloc);
        if (self.mcp_view) |*mcp_view| mcp_view.deinit(alloc);
        self.* = undefined;
    }
};

pub const HostResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) HostResolveError!HostAuthority,

    fn resolve(
        self: HostResolver,
        alloc: Allocator,
        root_id: []const u8,
    ) Error!HostAuthority {
        return self.resolve_fn(self.context, alloc, root_id);
    }
};

pub const HostResolveError = error{
    OutOfMemory,
    HostAuthorityUnavailable,
};

pub const LiveAuthority = struct {
    generation: u64,
    root_id: []const u8,
    tools: []const []const u8,
    integrations: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_mode: types.PermissionMode,
};

pub const Snapshot = struct {
    child_id: []u8,
    root_id: []u8,
    generation: u64,
    tools: [][]u8,
    integrations: [][]u8,
    rules: types.PermissionRuleSet,
    grants: []types.PermissionGrant,
    permission_state: session_permission_state.State = .{},
    permission_mode: types.PermissionMode,
    mcp_view: ?mcp_access.View = null,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.child_id);
        alloc.free(self.root_id);
        freeStrings(alloc, self.tools);
        freeStrings(alloc, self.integrations);
        self.rules.deinit(alloc);
        types.freePermissionGrantSlice(alloc, self.grants);
        self.permission_state.deinit(alloc);
        if (self.mcp_view) |*mcp_view| mcp_view.deinit(alloc);
        self.* = undefined;
    }

    pub fn view(self: *const Snapshot) LiveAuthority {
        return .{
            .generation = self.generation,
            .root_id = self.root_id,
            .tools = self.tools,
            .integrations = self.integrations,
            .rules = self.rules,
            .grants = self.grants,
            .permission_mode = self.permission_mode,
        };
    }
};

pub const Resolver = struct {
    sessions: *session_store.Store,
    root_id: []const u8 = "",
    host: HostResolver,
    child_store_options: session_child_store.Options = .{},

    pub fn resolve(
        self: *Resolver,
        alloc: Allocator,
        child_id: []const u8,
    ) Error!Snapshot {
        domain.validateId(child_id) catch return error.ChildNotAttached;
        domain.validateId(self.root_id) catch return error.ChildNotAttached;
        var store = child_state.Store{
            .sessions = self.sessions,
            .parent_id = self.root_id,
            .options = self.child_store_options,
        };
        var lock = store.acquireLock(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StoreUnavailable,
        };
        defer lock.release();
        var registry = store.load(alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StoreUnavailable,
        };
        defer registry.deinit(alloc);
        const child = registry.findById(child_id) orelse return error.ChildNotAttached;
        const permission_mode = if (child.active) |active|
            active.permission_mode
        else
            return error.ChildNotAttached;
        var host = try self.host.resolve(alloc, self.root_id);
        defer host.deinit(alloc);

        const owned_child_id = try alloc.dupe(u8, child_id);
        errdefer alloc.free(owned_child_id);
        const owned_root_id = try alloc.dupe(u8, self.root_id);
        errdefer alloc.free(owned_root_id);
        const tools = try cloneToolsWithoutSubagent(alloc, host.tools);
        errdefer freeStrings(alloc, tools);
        const integrations = try cloneStrings(alloc, host.integrations);
        errdefer freeStrings(alloc, integrations);
        var rules = try types.dupePermissionRuleSet(alloc, host.rules);
        errdefer rules.deinit(alloc);
        const permission_state = session_permission_state.dupe(
            alloc,
            host.permission_state,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidControlRecord,
        };
        errdefer {
            var value = permission_state;
            value.deinit(alloc);
        }
        var mcp_view = if (host.mcp_view) |view| try view.clone(alloc) else null;
        errdefer if (mcp_view) |*view| view.deinit(alloc);
        if (mcp_view) |*view| {
            try rebindMcpViewOwnership(alloc, view, child_id, self.root_id);
        }
        return .{
            .child_id = owned_child_id,
            .root_id = owned_root_id,
            .generation = authorityGeneration(
                child_id,
                self.root_id,
                registry.generation,
                host.generation,
            ),
            .tools = tools,
            .integrations = integrations,
            .rules = rules,
            .grants = try types.dupePermissionGrantSlice(alloc, host.grants),
            .permission_state = permission_state,
            .permission_mode = permission_mode,
            .mcp_view = mcp_view,
        };
    }
};

pub const ToolAuthorityDecision = enum { allow, ask, deny, unavailable };

pub fn decideToolAuthority(
    alloc: Allocator,
    live: LiveAuthority,
    workspace_root: []const u8,
    tool_name: []const u8,
    target: []const u8,
    target_kind: permissions.PermissionTargetKind,
) !ToolAuthorityDecision {
    if (!contains(live.tools, tool_name) and
        !contains(live.integrations, tool_name))
    {
        return .unavailable;
    }
    if (live.permission_mode == .yolo) return .allow;
    const permission_name = if (target_kind == .command_cwd and
        std.mem.eql(u8, tool_name, "shell"))
        "terminal"
    else
        tool_name;
    return switch (try permissions.ruleDecisionFor(
        alloc,
        live.rules,
        workspace_root,
        permission_name,
        target,
        target_kind,
    )) {
        .allow => .allow,
        .deny => .deny,
        .ask, .none => if (permissions.sessionGrantAllowed(
            live.grants,
            permission_name,
            target,
        )) .allow else .ask,
    };
}

fn rebindMcpViewOwnership(
    alloc: Allocator,
    view: *mcp_access.View,
    child_id: []const u8,
    parent_id: []const u8,
) !void {
    const owner = try alloc.dupe(u8, child_id);
    errdefer alloc.free(owner);
    const parent = try alloc.dupe(u8, parent_id);
    alloc.free(view.owner_id);
    alloc.free(view.parent_id);
    view.owner_id = owner;
    view.parent_id = parent;
}

fn hostGeneration(
    tools: []const []const u8,
    integrations: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
    mcp_view: ?*const mcp_access.View,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.host-authority.v3\x00");
    for (tools) |tool| hashString(&hash, tool);
    for (integrations) |integration| hashString(&hash, integration);
    for (rules.rules) |rule| {
        hashString(&hash, rule.permission);
        hashString(&hash, rule.pattern);
        hashString(&hash, @tagName(rule.action));
    }
    for (grants) |grant| {
        hashString(&hash, grant.tool_name);
        hashString(&hash, grant.target_path);
    }
    hashU64(&hash, permission_state.version);
    hashU64(&hash, permission_state.next_generation);
    if (mcp_view) |view| {
        hashU64(&hash, view.runtime_generation);
        hashString(&hash, view.owner_id);
        hashString(&hash, view.parent_id);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn authorityGeneration(
    child_id: []const u8,
    root_id: []const u8,
    child_generation: u64,
    host_generation: u64,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.live-authority.v2\x00");
    hashString(&hash, child_id);
    hashString(&hash, root_id);
    hashU64(&hash, child_generation);
    hashU64(&hash, host_generation);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const value = std.mem.readInt(u64, digest[0..8], .little);
    return if (value == 0) 1 else value;
}

fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, values.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values) |value| {
        out[copied] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

fn cloneToolsWithoutSubagent(
    alloc: Allocator,
    values: []const []const u8,
) ![][]u8 {
    var count: usize = 0;
    for (values) |value| {
        if (!std.mem.eql(u8, value, "subagent")) count += 1;
    }
    const out = try alloc.alloc([]u8, count);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |value| alloc.free(value);
        alloc.free(out);
    }
    for (values) |value| {
        if (std.mem.eql(u8, value, "subagent")) continue;
        out[copied] = try alloc.dupe(u8, value);
        copied += 1;
    }
    return out;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn hashString(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashU64(hash, value.len);
    hash.update(value);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

test "child permission admission inherits without elevation" {
    try std.testing.expectEqual(
        types.PermissionMode.auto,
        try admitChildPermission(.auto, null),
    );
    try std.testing.expectError(
        error.PermissionEscalation,
        admitChildPermission(.ask, .auto),
    );
}

test "tool authority excludes nested subagents and preserves rules" {
    const alloc = std.testing.allocator;
    const decision = try decideToolAuthority(alloc, .{
        .generation = 1,
        .root_id = "root",
        .tools = &.{"read_file"},
        .integrations = &.{},
        .rules = .{},
        .grants = &.{},
        .permission_mode = .yolo,
    }, "/tmp", "subagent", "subagent", .none);
    try std.testing.expectEqual(ToolAuthorityDecision.unavailable, decision);
}
