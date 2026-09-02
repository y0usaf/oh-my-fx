const std = @import("std");
const builtin = @import("builtin");
const mcp_auth = @import("mcp_auth.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const max_store_bytes: usize = 1024 * 1024;
const lock_file_name = "credentials.lock";
const lock_deadline_ms: u64 = 2_000;

const StorageBackend = enum {
    profile_file,
    macos_keychain,
};

const ReadDecision = enum {
    use_profile_file,
    migrate_profile_file,
    read_keychain,
};

const KeychainError = Allocator.Error || native_keychain.Error;

const KeychainBackend = struct {
    context: ?*anyopaque = null,
    load_fn: *const fn (
        ?*anyopaque,
        Allocator,
        ?*const std.atomic.Value(bool),
    ) KeychainError!?[]u8,
    store_fn: *const fn (
        ?*anyopaque,
        []const u8,
        ?*const std.atomic.Value(bool),
    ) KeychainError!void,
    delete_fn: *const fn (?*anyopaque, Allocator) KeychainError!bool,

    fn load(
        self: KeychainBackend,
        alloc: Allocator,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) KeychainError!?[]u8 {
        return self.load_fn(self.context, alloc, cancel_flag);
    }

    fn store(
        self: KeychainBackend,
        value: []const u8,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) KeychainError!void {
        return self.store_fn(self.context, value, cancel_flag);
    }

    fn delete(self: KeychainBackend, alloc: Allocator) KeychainError!bool {
        return self.delete_fn(self.context, alloc);
    }
};

const native_keychain_backend: KeychainBackend = .{
    .load_fn = nativeKeychainLoad,
    .store_fn = nativeKeychainStore,
    .delete_fn = nativeKeychainDelete,
};

fn nativeKeychainLoad(
    _: ?*anyopaque,
    alloc: Allocator,
    cancel_flag: ?*const std.atomic.Value(bool),
) KeychainError!?[]u8 {
    return if (cancel_flag) |flag|
        native_keychain.loadMcpCredentialsCancellable(alloc, flag)
    else
        native_keychain.loadMcpCredentials(alloc);
}

fn nativeKeychainStore(
    _: ?*anyopaque,
    value: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) KeychainError!void {
    return if (cancel_flag) |flag|
        native_keychain.storeMcpCredentialsCancellable(value, flag)
    else
        native_keychain.storeMcpCredentials(value);
}

fn nativeKeychainDelete(_: ?*anyopaque, alloc: Allocator) KeychainError!bool {
    return native_keychain.deleteMcpCredentials(alloc);
}

fn selectStorageBackend(
    os_tag: std.Target.Os.Tag,
    keychain_disabled: bool,
    keychain_available: bool,
) StorageBackend {
    if (os_tag == .macos and !keychain_disabled and keychain_available) {
        return .macos_keychain;
    }
    return .profile_file;
}

fn storageBackend(
    alloc: Allocator,
    cancel_flag: ?*const std.atomic.Value(bool),
) !StorageBackend {
    const disabled = native_keychain.isDisabled();
    const available = if (builtin.os.tag == .macos and !disabled) blk: {
        break :blk if (cancel_flag) |flag|
            try native_keychain.userDefaultKeychainAvailableCancellable(alloc, flag)
        else
            try native_keychain.userDefaultKeychainAvailable(alloc);
    } else false;
    return selectStorageBackend(builtin.os.tag, disabled, available);
}

fn selectReadDecision(
    backend: StorageBackend,
    profile_file_present: bool,
) ReadDecision {
    return switch (backend) {
        .profile_file => .use_profile_file,
        .macos_keychain => if (profile_file_present)
            .migrate_profile_file
        else
            .read_keychain,
    };
}

pub const Status = enum {
    missing,
    authenticated,
};

pub const SaveResult = struct {
    repaired_entries: usize = 0,
};

pub const DeleteResult = struct {
    removed: usize = 0,
    repaired_entries: usize = 0,
    durable: bool = true,
};

const StoredCredential = struct {
    server_identity: []u8,
    credentials: mcp_auth.Credentials,

    fn deinit(self: *StoredCredential, alloc: Allocator) void {
        alloc.free(self.server_identity);
        self.credentials.deinit(alloc);
        self.* = undefined;
    }
};

const Store = struct {
    credentials: std.ArrayList(StoredCredential) = .empty,
    rejected_entries: usize = 0,

    fn deinit(self: *Store, alloc: Allocator) void {
        for (self.credentials.items) |*entry| entry.deinit(alloc);
        self.credentials.deinit(alloc);
        self.* = .{};
    }
};

const LockedDir = struct {
    dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    fn deinit(self: *LockedDir) void {
        self.lock.release();
        self.dir.close();
        self.* = undefined;
    }
};

pub fn load(
    alloc: Allocator,
    server_identity: []const u8,
    endpoint: []const u8,
    configured_resource: ?[]const u8,
    configured_issuer: ?[]const u8,
) !?mcp_auth.Credentials {
    return loadControlled(
        alloc,
        server_identity,
        endpoint,
        configured_resource,
        configured_issuer,
        null,
    );
}

pub fn loadCancellable(
    alloc: Allocator,
    server_identity: []const u8,
    endpoint: []const u8,
    configured_resource: ?[]const u8,
    configured_issuer: ?[]const u8,
    cancel_flag: *const std.atomic.Value(bool),
) !?mcp_auth.Credentials {
    return loadControlled(
        alloc,
        server_identity,
        endpoint,
        configured_resource,
        configured_issuer,
        cancel_flag,
    );
}

fn loadControlled(
    alloc: Allocator,
    server_identity: []const u8,
    endpoint: []const u8,
    configured_resource: ?[]const u8,
    configured_issuer: ?[]const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) !?mcp_auth.Credentials {
    const backend = try storageBackend(alloc, cancel_flag);
    var locked = (try openLockedDirForReadControlled(
        backend,
        cancel_flag,
    )) orelse return null;
    defer locked.deinit();
    var store = try loadStoreControlled(
        alloc,
        &locked.dir,
        backend,
        native_keychain_backend,
        cancel_flag,
    );
    defer store.deinit(alloc);

    const canonical_endpoint = try mcp_auth.canonicalResource(alloc, endpoint);
    defer alloc.free(canonical_endpoint);
    const canonical_resource = if (configured_resource) |value|
        try mcp_auth.canonicalResource(alloc, value)
    else
        null;
    defer if (canonical_resource) |value| alloc.free(value);

    var matched: ?*const StoredCredential = null;
    for (store.credentials.items) |*entry| {
        if (!std.mem.eql(u8, entry.server_identity, server_identity) or
            !std.mem.eql(u8, entry.credentials.endpoint, canonical_endpoint))
        {
            continue;
        }
        if (canonical_resource) |resource| {
            if (!std.mem.eql(u8, entry.credentials.resource, resource)) continue;
        }
        if (configured_issuer) |issuer| {
            if (!std.mem.eql(u8, entry.credentials.issuer, issuer)) continue;
        }
        if (matched != null) return null;
        matched = entry;
    }
    return if (matched) |entry| try entry.credentials.clone(alloc) else null;
}

pub fn status(
    alloc: Allocator,
    server_identity: []const u8,
    endpoint: []const u8,
    configured_resource: ?[]const u8,
    configured_issuer: ?[]const u8,
) !Status {
    var credentials = (try load(
        alloc,
        server_identity,
        endpoint,
        configured_resource,
        configured_issuer,
    )) orelse return .missing;
    credentials.deinit(alloc);
    return .authenticated;
}

pub fn save(
    alloc: Allocator,
    server_identity: []const u8,
    credentials: mcp_auth.Credentials,
) !SaveResult {
    const backend = try storageBackend(alloc, null);
    var locked = try openOrCreateLockedDir();
    defer locked.deinit();
    var store = try loadStore(alloc, &locked.dir, backend, native_keychain_backend);
    defer store.deinit(alloc);

    var replacement = StoredCredential{
        .server_identity = try alloc.dupe(u8, server_identity),
        .credentials = try credentials.clone(alloc),
    };
    var transferred = false;
    errdefer if (!transferred) replacement.deinit(alloc);

    for (store.credentials.items) |*entry| {
        if (!sameIdentity(entry.*, server_identity, credentials)) continue;
        entry.deinit(alloc);
        entry.* = replacement;
        transferred = true;
        try writeStore(alloc, &locked.dir, store, backend, native_keychain_backend);
        return .{ .repaired_entries = store.rejected_entries };
    }
    try store.credentials.append(alloc, replacement);
    transferred = true;
    try writeStore(alloc, &locked.dir, store, backend, native_keychain_backend);
    return .{ .repaired_entries = store.rejected_entries };
}

pub fn delete(
    alloc: Allocator,
    server_identity: []const u8,
    endpoint: []const u8,
) !DeleteResult {
    const backend = try storageBackend(alloc, null);
    var locked = (try openLockedDirForRead(backend)) orelse return .{};
    defer locked.deinit();
    var store = try loadStore(alloc, &locked.dir, backend, native_keychain_backend);
    defer store.deinit(alloc);
    const canonical_endpoint = try mcp_auth.canonicalResource(alloc, endpoint);
    defer alloc.free(canonical_endpoint);

    var removed: usize = 0;
    var index: usize = store.credentials.items.len;
    while (index > 0) {
        index -= 1;
        const entry = store.credentials.items[index];
        if (!std.mem.eql(u8, entry.server_identity, server_identity) or
            !std.mem.eql(u8, entry.credentials.endpoint, canonical_endpoint))
        {
            continue;
        }
        var deleted = store.credentials.orderedRemove(index);
        deleted.deinit(alloc);
        removed += 1;
    }
    if (removed == 0 and store.rejected_entries == 0) return .{};
    if (store.credentials.items.len == 0) {
        try clearStore(alloc, &locked.dir, backend, native_keychain_backend);
    } else {
        try writeStore(alloc, &locked.dir, store, backend, native_keychain_backend);
    }
    return .{
        .removed = removed,
        .repaired_entries = store.rejected_entries,
    };
}

fn sameIdentity(
    entry: StoredCredential,
    server_identity: []const u8,
    credentials: mcp_auth.Credentials,
) bool {
    return std.mem.eql(u8, entry.server_identity, server_identity) and
        std.mem.eql(u8, entry.credentials.endpoint, credentials.endpoint) and
        std.mem.eql(u8, entry.credentials.resource, credentials.resource) and
        std.mem.eql(u8, entry.credentials.issuer, credentials.issuer);
}

fn openOrCreateLockedDir() !LockedDir {
    return openOrCreateLockedDirControlled(null);
}

fn openOrCreateLockedDirControlled(
    cancel_flag: ?*const std.atomic.Value(bool),
) !LockedDir {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();
    var root = try io_mod.openOrCreateVerifiedPrivateDir(
        &home_dir,
        profile_paths.root_dir_name,
    );
    defer root.close();
    var credentials_dir = try io_mod.openOrCreateVerifiedPrivateDir(
        &root,
        profile_paths.mcp_credentials_dir_name,
    );
    errdefer credentials_dir.close();
    var lock = if (cancel_flag) |flag|
        try io_mod.acquireTimedAdvisoryLockCancellable(
            &credentials_dir,
            lock_file_name,
            lock_deadline_ms,
            flag,
        )
    else
        try io_mod.acquireTimedAdvisoryLock(
            &credentials_dir,
            lock_file_name,
            lock_deadline_ms,
        );
    errdefer lock.release();
    return .{ .dir = credentials_dir, .lock = lock };
}

fn openExistingLockedDir() !?LockedDir {
    return openExistingLockedDirControlled(null);
}

fn openExistingLockedDirControlled(
    cancel_flag: ?*const std.atomic.Value(bool),
) !?LockedDir {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{
            .iterate = true,
        }),
    };
    defer home_dir.close();
    var root = openExistingPrivateChild(
        &home_dir,
        profile_paths.root_dir_name,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer root.close();
    var credentials_dir = openExistingPrivateChild(
        &root,
        profile_paths.mcp_credentials_dir_name,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer credentials_dir.close();
    var lock = if (cancel_flag) |flag|
        try io_mod.acquireTimedAdvisoryLockCancellable(
            &credentials_dir,
            lock_file_name,
            lock_deadline_ms,
            flag,
        )
    else
        try io_mod.acquireTimedAdvisoryLock(
            &credentials_dir,
            lock_file_name,
            lock_deadline_ms,
        );
    errdefer lock.release();
    return .{ .dir = credentials_dir, .lock = lock };
}

fn openLockedDirForRead(backend: StorageBackend) !?LockedDir {
    return openLockedDirForReadControlled(backend, null);
}

fn openLockedDirForReadControlled(
    backend: StorageBackend,
    cancel_flag: ?*const std.atomic.Value(bool),
) !?LockedDir {
    return switch (backend) {
        .profile_file => openExistingLockedDirControlled(cancel_flag),
        .macos_keychain => try openOrCreateLockedDirControlled(cancel_flag),
    };
}

fn openExistingPrivateChild(
    parent: *io_mod.VerifiedDir,
    name: []const u8,
) !io_mod.VerifiedDir {
    var dir = try parent.dir.openDir(io_mod.getIo(), name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());
    try normalizeAndVerifyPrivateDir(dir);
    return .{ .dir = dir };
}

fn normalizeAndVerifyPrivateDir(dir: std.Io.Dir) !void {
    const initial = try dir.stat(io_mod.getIo());
    if (initial.kind != .directory) return error.DurablePathUnsafe;
    if (initial.permissions.toMode() & 0o200 == 0) {
        return error.PrivateStatePermissionsUnsupported;
    }
    try dir.setPermissions(
        io_mod.getIo(),
        std.Io.File.Permissions.fromMode(0o700),
    );
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn loadStore(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    backend: StorageBackend,
    keychain: KeychainBackend,
) !Store {
    return loadStoreControlled(alloc, dir, backend, keychain, null);
}

fn loadStoreControlled(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    backend: StorageBackend,
    keychain: KeychainBackend,
    cancel_flag: ?*const std.atomic.Value(bool),
) !Store {
    try checkCancellation(cancel_flag);
    const from_file = try loadFromDir(alloc, dir);
    switch (selectReadDecision(backend, from_file != null)) {
        .use_profile_file => return from_file orelse .{},
        .migrate_profile_file => {
            var store = from_file.?;
            errdefer store.deinit(alloc);
            try writeStoreToKeychainControlled(
                alloc,
                store,
                keychain,
                cancel_flag,
            );
            if (store.rejected_entries > 0) {
                debug_trace.logf(
                    "mcp",
                    "removed unreadable MCP credential entries actor=migration count={d}",
                    .{store.rejected_entries},
                );
            }
            try checkCancellation(cancel_flag);
            try deleteCredentialFile(dir);
            return store;
        },
        .read_keychain => {},
    }

    try checkCancellation(cancel_flag);
    const maybe_bytes = keychain.load(alloc, cancel_flag) catch |err| switch (err) {
        error.KeychainItemNotFound => null,
        else => return err,
    };
    const bytes = maybe_bytes orelse return .{};
    defer secret.zeroAndFree(alloc, bytes);
    if (bytes.len > max_store_bytes) return error.InvalidMcpCredentialStore;
    return parseStore(alloc, bytes);
}

fn loadFromDir(alloc: Allocator, dir: *io_mod.VerifiedDir) !?Store {
    var file = dir.dir.openFile(
        io_mod.getIo(),
        profile_paths.mcp_credentials_file_name,
        .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o600) {
        return error.PrivateStatePermissionsUnsupported;
    }
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_store_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return try parseStore(alloc, bytes);
}

fn parseStore(alloc: Allocator, bytes: []const u8) !Store {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpCredentialStore;
    const version = parsed.value.object.get("version") orelse
        return error.InvalidMcpCredentialStore;
    if (version != .integer or version.integer != schema_version) {
        return error.InvalidMcpCredentialStore;
    }
    const values = parsed.value.object.get("credentials") orelse
        return error.InvalidMcpCredentialStore;
    if (values != .array) return error.InvalidMcpCredentialStore;

    var store: Store = .{};
    errdefer store.deinit(alloc);
    for (values.array.items) |value| {
        if (value != .object) {
            store.rejected_entries += 1;
            continue;
        }
        const object = value.object;
        const server_identity = dupeRequiredString(
            alloc,
            object,
            "server_identity",
        ) catch |err| switch (err) {
            error.InvalidMcpCredentialStore => {
                store.rejected_entries += 1;
                continue;
            },
            else => |other| return other,
        };
        var credentials = parseCredentials(alloc, object) catch |err| {
            alloc.free(server_identity);
            switch (err) {
                error.InvalidMcpCredentialStore => {
                    store.rejected_entries += 1;
                    continue;
                },
                else => |other| return other,
            }
        };
        store.credentials.append(alloc, .{
            .server_identity = server_identity,
            .credentials = credentials,
        }) catch |err| {
            alloc.free(server_identity);
            credentials.deinit(alloc);
            return err;
        };
    }
    return store;
}

fn parseCredentials(
    alloc: Allocator,
    object: std.json.ObjectMap,
) !mcp_auth.Credentials {
    const endpoint = try dupeRequiredString(alloc, object, "endpoint");
    errdefer alloc.free(endpoint);
    const resource = try dupeRequiredString(alloc, object, "resource");
    errdefer alloc.free(resource);
    const issuer = try dupeRequiredString(alloc, object, "issuer");
    errdefer alloc.free(issuer);
    const client_id = try dupeRequiredString(alloc, object, "client_id");
    errdefer alloc.free(client_id);
    const client_secret = try dupeOptionalString(alloc, object, "client_secret");
    errdefer if (client_secret) |value| secret.zeroAndFree(alloc, value);
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeOptionalString(alloc, object, "refresh_token");
    errdefer if (refresh_token) |value| secret.zeroAndFree(alloc, value);
    const scope = try dupeStringAllowEmpty(alloc, object, "scope");
    errdefer alloc.free(scope);
    const token_type = try dupeRequiredString(alloc, object, "token_type");
    errdefer alloc.free(token_type);
    const token_endpoint_auth_method = try dupeRequiredString(
        alloc,
        object,
        "token_endpoint_auth_method",
    );
    errdefer alloc.free(token_endpoint_auth_method);
    const authorization_endpoint = try dupeRequiredString(
        alloc,
        object,
        "authorization_endpoint",
    );
    errdefer alloc.free(authorization_endpoint);
    const token_endpoint = try dupeRequiredString(alloc, object, "token_endpoint");
    errdefer alloc.free(token_endpoint);
    const revocation_endpoint = try dupeOptionalString(
        alloc,
        object,
        "revocation_endpoint",
    );
    errdefer if (revocation_endpoint) |value| alloc.free(value);
    const expires_at_value = object.get("expires_at_ms") orelse
        return error.InvalidMcpCredentialStore;
    const expires_at_ms: i64 = switch (expires_at_value) {
        .integer => |value| value,
        .null => std.math.maxInt(i64),
        else => return error.InvalidMcpCredentialStore,
    };
    return .{
        .endpoint = endpoint,
        .resource = resource,
        .issuer = issuer,
        .client_id = client_id,
        .client_secret = client_secret,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .scope = scope,
        .token_type = token_type,
        .token_endpoint_auth_method = token_endpoint_auth_method,
        .expires_at_ms = expires_at_ms,
        .authorization_endpoint = authorization_endpoint,
        .token_endpoint = token_endpoint,
        .revocation_endpoint = revocation_endpoint,
    };
}

fn writeStore(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    store: Store,
    backend: StorageBackend,
    keychain: KeychainBackend,
) !void {
    switch (backend) {
        .profile_file => try writeStoreToFile(alloc, dir, store),
        .macos_keychain => try writeStoreToKeychain(alloc, store, keychain),
    }
}

fn writeStoreToFile(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    store: Store,
) !void {
    const bytes = try serializeStore(alloc, store);
    defer secret.zeroAndFree(alloc, bytes);
    try io_mod.durableReplaceVerified(
        alloc,
        dir,
        profile_paths.mcp_credentials_file_name,
        bytes,
    );
}

fn writeStoreToKeychain(
    alloc: Allocator,
    store: Store,
    keychain: KeychainBackend,
) !void {
    return writeStoreToKeychainControlled(alloc, store, keychain, null);
}

fn writeStoreToKeychainControlled(
    alloc: Allocator,
    store: Store,
    keychain: KeychainBackend,
    cancel_flag: ?*const std.atomic.Value(bool),
) !void {
    const bytes = try serializeStore(alloc, store);
    defer secret.zeroAndFree(alloc, bytes);
    try checkCancellation(cancel_flag);
    try keychain.store(bytes, cancel_flag);
    try checkCancellation(cancel_flag);
    const persisted = keychain.load(alloc, cancel_flag) catch |err| switch (err) {
        error.KeychainItemNotFound => return error.McpCredentialStoreWriteMismatch,
        else => return err,
    } orelse return error.McpCredentialStoreWriteMismatch;
    defer secret.zeroAndFree(alloc, persisted);
    if (!std.mem.eql(u8, bytes, persisted)) {
        return error.McpCredentialStoreWriteMismatch;
    }
}

fn checkCancellation(cancel_flag: ?*const std.atomic.Value(bool)) !void {
    if (cancel_flag) |flag| {
        if (flag.load(.acquire)) return error.Cancelled;
    }
}

fn serializeStore(alloc: Allocator, store: Store) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer {
        @memset(out.written(), 0);
        out.deinit();
    }
    try out.writer.writeAll("{\"version\":1,\"credentials\":[");
    for (store.credentials.items, 0..) |entry, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeEntry(&out.writer, entry);
    }
    try out.writer.writeAll("]}");
    if (out.written().len > max_store_bytes) {
        return error.McpCredentialStoreTooLarge;
    }
    return out.toOwnedSlice();
}

fn clearStore(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    backend: StorageBackend,
    keychain: KeychainBackend,
) !void {
    switch (backend) {
        .profile_file => try deleteCredentialFile(dir),
        .macos_keychain => {
            _ = try keychain.delete(alloc);
            try deleteCredentialFile(dir);
        },
    }
}

fn deleteCredentialFile(dir: *io_mod.VerifiedDir) !void {
    dir.dir.deleteFile(
        io_mod.getIo(),
        profile_paths.mcp_credentials_file_name,
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try io_mod.syncVerifiedDir(dir.dir);
}

fn writeEntry(writer: *std.Io.Writer, entry: StoredCredential) !void {
    const credentials = entry.credentials;
    try writer.writeAll("{\"server_identity\":");
    try std.json.Stringify.value(entry.server_identity, .{}, writer);
    inline for ([_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "endpoint", .value = credentials.endpoint },
        .{ .key = "resource", .value = credentials.resource },
        .{ .key = "issuer", .value = credentials.issuer },
        .{ .key = "client_id", .value = credentials.client_id },
    }) |field| {
        try writer.print(",\"{s}\":", .{field.key});
        try std.json.Stringify.value(field.value, .{}, writer);
    }
    try writer.writeAll(",\"client_secret\":");
    try writeOptionalString(writer, credentials.client_secret);
    try writer.writeAll(",\"access_token\":");
    try std.json.Stringify.value(credentials.access_token, .{}, writer);
    try writer.writeAll(",\"refresh_token\":");
    try writeOptionalString(writer, credentials.refresh_token);
    inline for ([_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "scope", .value = credentials.scope },
        .{ .key = "token_type", .value = credentials.token_type },
        .{
            .key = "token_endpoint_auth_method",
            .value = credentials.token_endpoint_auth_method,
        },
    }) |field| {
        try writer.print(",\"{s}\":", .{field.key});
        try std.json.Stringify.value(field.value, .{}, writer);
    }
    try writer.print(",\"expires_at_ms\":{d}", .{credentials.expires_at_ms});
    try writer.writeAll(",\"authorization_endpoint\":");
    try std.json.Stringify.value(credentials.authorization_endpoint, .{}, writer);
    try writer.writeAll(",\"token_endpoint\":");
    try std.json.Stringify.value(credentials.token_endpoint, .{}, writer);
    try writer.writeAll(",\"revocation_endpoint\":");
    try writeOptionalString(writer, credentials.revocation_endpoint);
    try writer.writeByte('}');
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

fn dupeRequiredString(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return error.InvalidMcpCredentialStore;
    if (value != .string or value.string.len == 0) {
        return error.InvalidMcpCredentialStore;
    }
    return alloc.dupe(u8, value.string);
}

fn dupeStringAllowEmpty(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return error.InvalidMcpCredentialStore;
    if (value != .string) return error.InvalidMcpCredentialStore;
    return alloc.dupe(u8, value.string);
}

fn dupeOptionalString(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) {
        return error.InvalidMcpCredentialStore;
    }
    return try alloc.dupe(u8, value.string);
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestHome = struct {
    map: std.process.Environ.Map,

    fn init(home: []const u8) !TestHome {
        _ = try stableTestEnviron();
        var result = TestHome{
            .map = std.process.Environ.Map.init(std.testing.allocator),
        };
        errdefer result.map.deinit();
        try result.map.put("HOME", home);
        try result.map.put("FX_DISABLE_KEYCHAIN", "1");
        return result;
    }

    fn activate(self: *TestHome) void {
        io_mod.setEnvironMap(&self.map);
    }

    fn deinit(self: *TestHome) void {
        if (stable_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        self.* = undefined;
    }
};

const FakeKeychain = struct {
    alloc: Allocator,
    value: ?[]u8 = null,
    store_calls: usize = 0,
    delete_calls: usize = 0,
    fail_store: bool = false,
    corrupt_store: bool = false,
    stall_load: bool = false,
    stall_store: bool = false,
    load_started: std.atomic.Value(bool) = .init(false),
    store_started: std.atomic.Value(bool) = .init(false),

    fn deinit(self: *FakeKeychain) void {
        if (self.value) |value| secret.zeroAndFree(self.alloc, value);
        self.* = undefined;
    }

    fn backend(self: *FakeKeychain) KeychainBackend {
        return .{
            .context = self,
            .load_fn = loadCallback,
            .store_fn = storeCallback,
            .delete_fn = deleteCallback,
        };
    }

    fn loadCallback(
        raw_context: ?*anyopaque,
        alloc: Allocator,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) KeychainError!?[]u8 {
        const self: *FakeKeychain = @ptrCast(@alignCast(raw_context.?));
        if (self.stall_load) {
            self.load_started.store(true, .release);
            const flag = cancel_flag orelse return error.KeychainReadFailed;
            while (!flag.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            return error.Cancelled;
        }
        const value = self.value orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn storeCallback(
        raw_context: ?*anyopaque,
        value: []const u8,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) KeychainError!void {
        const self: *FakeKeychain = @ptrCast(@alignCast(raw_context.?));
        if (self.stall_store) {
            self.store_started.store(true, .release);
            const flag = cancel_flag orelse return error.KeychainWriteFailed;
            while (!flag.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            return error.Cancelled;
        }
        self.store_calls += 1;
        if (self.fail_store) return error.KeychainWriteFailed;
        const replacement = try self.alloc.dupe(
            u8,
            if (self.corrupt_store and value.len > 0)
                value[0 .. value.len - 1]
            else
                value,
        );
        if (self.value) |previous| secret.zeroAndFree(self.alloc, previous);
        self.value = replacement;
    }

    fn deleteCallback(
        raw_context: ?*anyopaque,
        _: Allocator,
    ) KeychainError!bool {
        const self: *FakeKeychain = @ptrCast(@alignCast(raw_context.?));
        self.delete_calls += 1;
        const previous = self.value orelse return false;
        secret.zeroAndFree(self.alloc, previous);
        self.value = null;
        return true;
    }
};

fn testCredentials(
    alloc: Allocator,
    endpoint: []const u8,
    access_token: []const u8,
) !mcp_auth.Credentials {
    const owned_endpoint = try alloc.dupe(u8, endpoint);
    errdefer alloc.free(owned_endpoint);
    const resource = try alloc.dupe(u8, endpoint);
    errdefer alloc.free(resource);
    const issuer = try alloc.dupe(u8, "https://issuer.example");
    errdefer alloc.free(issuer);
    const client_id = try alloc.dupe(u8, "client");
    errdefer alloc.free(client_id);
    const owned_access_token = try alloc.dupe(u8, access_token);
    errdefer secret.zeroAndFree(alloc, owned_access_token);
    const refresh_token = try alloc.dupe(u8, "refresh-secret");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const scope = try alloc.dupe(u8, "tools.read");
    errdefer alloc.free(scope);
    const token_type = try alloc.dupe(u8, "Bearer");
    errdefer alloc.free(token_type);
    const auth_method = try alloc.dupe(u8, "none");
    errdefer alloc.free(auth_method);
    const authorization_endpoint = try alloc.dupe(
        u8,
        "https://issuer.example/authorize",
    );
    errdefer alloc.free(authorization_endpoint);
    return .{
        .endpoint = owned_endpoint,
        .resource = resource,
        .issuer = issuer,
        .client_id = client_id,
        .access_token = owned_access_token,
        .refresh_token = refresh_token,
        .scope = scope,
        .token_type = token_type,
        .token_endpoint_auth_method = auth_method,
        .expires_at_ms = 123_456,
        .authorization_endpoint = authorization_endpoint,
        .token_endpoint = try alloc.dupe(u8, "https://issuer.example/token"),
    };
}
