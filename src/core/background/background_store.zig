const std = @import("std");
const io_mod = @import("../shared/io.zig");
const process_supervisor = @import("process_supervisor.zig");
const session_child_store = @import("../session/session_child_store.zig");

const Allocator = std.mem.Allocator;
const legacy_schema_version: i64 = 1;
const schema_version: i64 = 2;
const max_record_bytes: usize = 256 * 1024;
pub const StableBackgroundRecordId =
    process_supervisor.StableBackgroundRecordId;

pub const LogStorage = union(enum) {
    managed_session: struct {
        managed_log_name: []u8,
    },
    external: struct {
        path: []u8,
    },

    pub fn deinit(self: *LogStorage, alloc: Allocator) void {
        switch (self.*) {
            .managed_session => |value| alloc.free(value.managed_log_name),
            .external => |value| alloc.free(value.path),
        }
        self.* = undefined;
    }
};

pub fn renderLogStorageJson(
    alloc: Allocator,
    storage: LogStorage,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    switch (storage) {
        .managed_session => |value| {
            try session_child_store.SessionChildCapability.validateManagedName(
                value.managed_log_name,
            );
            try out.writer.writeAll(
                "{\"kind\":\"managed_session\",\"managed_log_name\":",
            );
            try std.json.Stringify.value(
                value.managed_log_name,
                .{},
                &out.writer,
            );
        },
        .external => |value| {
            if (!std.fs.path.isAbsolute(value.path)) {
                return error.InvalidBackgroundRecord;
            }
            try out.writer.writeAll("{\"kind\":\"external\",\"path\":");
            try std.json.Stringify.value(value.path, .{}, &out.writer);
        },
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn parseLogStorageJson(
    alloc: Allocator,
    json_text: []const u8,
) !LogStorage {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json_text,
        .{},
    ) catch return error.InvalidBackgroundRecord;
    defer parsed.deinit();
    const object = try requireObject(parsed.value);
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "managed_session")) {
        const name = try requireString(object, "managed_log_name");
        session_child_store.SessionChildCapability.validateManagedName(name) catch
            return error.InvalidBackgroundRecord;
        return .{ .managed_session = .{
            .managed_log_name = try alloc.dupe(u8, name),
        } };
    }
    if (std.mem.eql(u8, kind, "external")) {
        const path = try requireString(object, "path");
        if (!std.fs.path.isAbsolute(path)) {
            return error.InvalidBackgroundRecord;
        }
        return .{ .external = .{
            .path = try alloc.dupe(u8, path),
        } };
    }
    return error.InvalidBackgroundRecord;
}

pub fn classifyLegacyLogStorage(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    legacy_path: []const u8,
    explicit_external_dir: ?[]const u8,
) !?LogStorage {
    if (!std.fs.path.isAbsolute(legacy_path)) return null;
    const parent = std.fs.path.dirname(legacy_path) orelse return null;
    const basename = std.fs.path.basename(legacy_path);
    session_child_store.SessionChildCapability.validateManagedName(basename) catch
        return null;

    const managed_route = try capability.displayRoutePath(
        alloc,
        .background_logs,
    );
    defer alloc.free(managed_route);
    if (std.mem.eql(u8, parent, managed_route)) {
        return .{ .managed_session = .{
            .managed_log_name = try alloc.dupe(u8, basename),
        } };
    }
    const external_dir = explicit_external_dir orelse return null;
    if (!std.mem.eql(u8, parent, external_dir)) return null;
    return .{ .external = .{
        .path = try alloc.dupe(u8, legacy_path),
    } };
}

pub const TaskState = process_supervisor.TaskState;

pub const Record = struct {
    id: u64,
    background_record_id: ?StableBackgroundRecordId = null,
    process_token: ?[]u8 = null,
    pid: []u8,
    command: []u8,
    cwd: []u8,
    log_path: []u8,
    log_storage: ?LogStorage = null,
    expect_url: bool,
    server_url: ?[]u8 = null,
    started_at_ms: i64,
    updated_at_ms: i64,
    exit_code: ?i32 = null,
    state: TaskState,
    diagnostic: ?[]u8 = null,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.pid);
        if (self.process_token) |process_token| alloc.free(process_token);
        alloc.free(self.command);
        alloc.free(self.cwd);
        alloc.free(self.log_path);
        if (self.log_storage) |*storage| storage.deinit(alloc);
        if (self.server_url) |url| alloc.free(url);
        if (self.diagnostic) |diagnostic| alloc.free(diagnostic);
        self.* = undefined;
    }

    pub fn fromTaskSnapshot(alloc: Allocator, snapshot: process_supervisor.TaskSnapshot, updated_at_ms: i64) !Record {
        const pid = try alloc.dupe(u8, snapshot.pid);
        errdefer alloc.free(pid);
        const command = try alloc.dupe(u8, snapshot.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, snapshot.cwd);
        errdefer alloc.free(cwd);
        const log_path = try alloc.dupe(u8, snapshot.log_path);
        errdefer alloc.free(log_path);

        var server_url: ?[]u8 = null;
        errdefer if (server_url) |url| alloc.free(url);
        if (snapshot.server_url) |url| {
            server_url = try alloc.dupe(u8, url);
        }

        return .{
            .id = snapshot.durable_record_id orelse snapshot.id,
            .background_record_id = snapshot.background_record_id,
            .process_token = if (snapshot.process_token) |token|
                try alloc.dupe(u8, token.view())
            else
                null,
            .pid = pid,
            .command = command,
            .cwd = cwd,
            .log_path = log_path,
            .log_storage = if (snapshot.managed_log_name) |name|
                .{ .managed_session = .{
                    .managed_log_name = try alloc.dupe(u8, name),
                } }
            else
                .{ .external = .{
                    .path = try alloc.dupe(u8, snapshot.log_path),
                } },
            .expect_url = snapshot.expect_url,
            .server_url = server_url,
            .started_at_ms = snapshot.started_at_ms,
            .updated_at_ms = updated_at_ms,
            .exit_code = snapshot.exit_code,
            .state = snapshot.state,
        };
    }
};

pub const Store = struct {
    capability: *session_child_store.SessionChildCapability,
    owned_capability: ?*session_child_store.SessionChildCapability = null,
    display_route_path: ?[]u8 = null,

    pub fn initManaged(
        capability: *session_child_store.SessionChildCapability,
    ) Store {
        return .{ .capability = capability };
    }

    /// Transitional legacy-only constructor retained until adapter conversion.
    pub fn initWithDir(alloc: Allocator, dir_path: []const u8) !Store {
        const owned = try alloc.create(session_child_store.SessionChildCapability);
        errdefer alloc.destroy(owned);
        owned.* = try session_child_store.SessionChildCapability.initLegacyRoute(
            alloc,
            dir_path,
            .background_records,
            .writable,
        );
        const display_route_path = try alloc.dupe(u8, dir_path);
        errdefer alloc.free(display_route_path);
        return .{
            .capability = owned,
            .owned_capability = owned,
            .display_route_path = display_route_path,
        };
    }

    pub fn initReadOnlyWithDir(
        alloc: Allocator,
        dir_path: []const u8,
    ) !Store {
        const owned = try alloc.create(
            session_child_store.SessionChildCapability,
        );
        errdefer alloc.destroy(owned);
        owned.* = try session_child_store.SessionChildCapability.initLegacyRoute(
            alloc,
            dir_path,
            .background_records,
            .read_only,
        );
        const display_route_path = try alloc.dupe(u8, dir_path);
        errdefer alloc.free(display_route_path);
        return .{
            .capability = owned,
            .owned_capability = owned,
            .display_route_path = display_route_path,
        };
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        if (self.owned_capability) |owned| {
            owned.deinit();
            alloc.destroy(owned);
        }
        if (self.display_route_path) |path| alloc.free(path);
        self.* = undefined;
    }

    pub fn sameBacking(self: Store, other: Store) bool {
        if (self.display_route_path) |left| {
            const right = other.display_route_path orelse return false;
            return std.mem.eql(u8, left, right);
        }
        return other.display_route_path == null and
            self.capability == other.capability;
    }

    pub fn nextId(self: Store) !u64 {
        var max_id: u64 = 0;
        var entries = try self.capability.iterate(
            std.heap.c_allocator,
            .background_records,
        );
        defer entries.deinit();
        for (entries.names) |name| {
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            const basename = name[0 .. name.len - ".json".len];
            const id = std.fmt.parseUnsigned(u64, basename, 10) catch continue;
            max_id = @max(max_id, id);
        }

        return max_id + 1;
    }

    pub fn saveTaskSnapshot(self: Store, alloc: Allocator, snapshot: process_supervisor.TaskSnapshot) !void {
        var record = try Record.fromTaskSnapshot(alloc, snapshot, io_mod.milliTimestamp());
        defer record.deinit(alloc);
        try self.saveRecord(alloc, record);
    }

    pub fn saveRecord(self: Store, alloc: Allocator, record: Record) !void {
        const name = try recordName(alloc, record.id);
        defer alloc.free(name);
        try self.validateIndeterminateCurrent(alloc);

        const text = try renderRecordJson(alloc, record);
        defer alloc.free(text);

        var entry = try self.capability.atomicReplace(
            alloc,
            .background_records,
            name,
            text,
        );
        entry.deinit(alloc);
    }

    fn validateIndeterminateCurrent(
        self: Store,
        alloc: Allocator,
    ) !void {
        const pending_name = self.capability.indeterminateEntryName(
            .background_records,
        ) orelse return;
        const expected_id = try recordIdFromName(pending_name);
        var current = try loadRecordFromFile(
            alloc,
            self.capability,
            pending_name,
        );
        defer current.deinit(alloc);
        if (current.id != expected_id) {
            return error.InvalidBackgroundRecord;
        }
    }

    pub fn delete(self: Store, alloc: Allocator, id: u64) !void {
        try self.validateIndeterminateCurrent(alloc);
        const name = try recordName(alloc, id);
        defer alloc.free(name);
        self.capability.delete(.background_records, name) catch |err| switch (err) {
            error.FileNotFound => return error.BackgroundRecordNotFound,
            else => return err,
        };
    }

    pub fn load(self: Store, alloc: Allocator, id: u64) !Record {
        const name = try recordName(alloc, id);
        defer alloc.free(name);
        return loadRecordFromFile(alloc, self.capability, name);
    }

    pub fn loadByStableId(
        self: Store,
        alloc: Allocator,
        stable_id: StableBackgroundRecordId,
    ) !Record {
        var found: ?Record = null;
        errdefer if (found) |*record| record.deinit(alloc);

        var entries = try self.capability.iterate(
            alloc,
            .background_records,
        );
        defer entries.deinit();
        for (entries.names) |name| {
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            var record = loadRecordFromFile(
                alloc,
                self.capability,
                name,
            ) catch |err| switch (err) {
                error.BackgroundRecordNotFound,
                error.InvalidBackgroundRecord,
                error.UnsupportedBackgroundSchema,
                => continue,
                else => return err,
            };
            const record_id = record.background_record_id orelse {
                record.deinit(alloc);
                continue;
            };
            if (!std.mem.eql(u8, &record_id, &stable_id)) {
                record.deinit(alloc);
                continue;
            }
            if (found != null) {
                record.deinit(alloc);
                return error.DuplicateBackgroundRecordIdentity;
            }
            found = record;
        }
        return found orelse error.BackgroundRecordNotFound;
    }

    pub fn loadLatest(self: Store, alloc: Allocator) !Record {
        var records = try self.list(alloc);
        defer {
            for (records.items) |*entry| {
                entry.deinit(alloc);
            }
            records.deinit(alloc);
        }

        if (records.items.len == 0) return error.NoBackgroundRecords;
        return records.orderedRemove(0);
    }

    pub fn list(self: Store, alloc: Allocator) !std.ArrayList(Record) {
        var results: std.ArrayList(Record) = .empty;
        errdefer {
            for (results.items) |*entry| entry.deinit(alloc);
            results.deinit(alloc);
        }

        var entries = try self.capability.iterate(
            alloc,
            .background_records,
        );
        defer entries.deinit();
        for (entries.names) |name| {
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            var record = loadRecordFromFile(
                alloc,
                self.capability,
                name,
            ) catch |err| switch (err) {
                error.BackgroundRecordNotFound,
                error.InvalidBackgroundRecord,
                error.UnsupportedBackgroundSchema,
                => continue,
                else => return err,
            };
            errdefer record.deinit(alloc);
            try results.append(alloc, record);
        }

        sortRecordsNewestFirst(results.items);
        return results;
    }
};

pub fn validateAllManagedRecords(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !void {
    var entries = try capability.iterate(alloc, .background_records);
    defer entries.deinit();
    for (entries.names) |name| {
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        _ = recordIdFromName(name) catch return error.InvalidBackgroundRecord;
        var record = try loadRecordFromFile(alloc, capability, name);
        record.deinit(alloc);
    }
}

pub fn recordBelongsToWorkspace(record: Record, workspace_root: []const u8) bool {
    return process_supervisor.pathBelongsToWorkspace(record.cwd, workspace_root);
}

fn recordName(alloc: Allocator, id: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}.json", .{id});
}

fn recordIdFromName(name: []const u8) !u64 {
    if (!std.mem.endsWith(u8, name, ".json")) {
        return error.InvalidBackgroundRecord;
    }
    return std.fmt.parseUnsigned(
        u64,
        name[0 .. name.len - ".json".len],
        10,
    ) catch error.InvalidBackgroundRecord;
}

fn readRecordFile(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) ![]u8 {
    var file = capability.openFileReadOnly(
        alloc,
        .background_records,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.BackgroundRecordNotFound,
        else => return err,
    };
    defer file.deinit();

    return file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidBackgroundRecord,
        else => return err,
    };
}

/// Returns an owned record; caller must deinit it with Record.deinit.
fn loadRecordFromFile(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) !Record {
    const bytes = try readRecordFile(alloc, capability, name);
    defer alloc.free(bytes);
    return parseRecord(alloc, bytes);
}

fn renderRecordJson(alloc: Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const stable_id = record.background_record_id;
    try out.writer.print(
        "{{\"schema_version\":{d},\"id\":{d},\"started_at_ms\":{d},\"updated_at_ms\":{d}",
        .{
            if (stable_id != null) schema_version else legacy_schema_version,
            record.id,
            record.started_at_ms,
            record.updated_at_ms,
        },
    );
    if (stable_id) |value| {
        var encoded: [32]u8 = undefined;
        encodeStableId(&encoded, value);
        try out.writer.writeAll(",\"background_record_id\":");
        try std.json.Stringify.value(encoded[0..], .{}, &out.writer);
        try out.writer.writeAll(",\"process_token\":");
        if (record.process_token) |token| {
            _ = try process_supervisor.ProcessInstanceToken.parse(token);
            try std.json.Stringify.value(token, .{}, &out.writer);
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll(",\"log_storage\":");
        const storage = record.log_storage orelse
            return error.InvalidBackgroundRecord;
        const storage_json = try renderLogStorageJson(alloc, storage);
        defer alloc.free(storage_json);
        try out.writer.writeAll(storage_json);
    }
    try out.writer.writeAll(",\"pid\":");
    try std.json.Stringify.value(record.pid, .{}, &out.writer);
    try out.writer.writeAll(",\"command\":");
    try std.json.Stringify.value(record.command, .{}, &out.writer);
    try out.writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(record.cwd, .{}, &out.writer);
    try out.writer.writeAll(",\"log_path\":");
    try std.json.Stringify.value(record.log_path, .{}, &out.writer);
    try out.writer.print(",\"expect_url\":{s}", .{if (record.expect_url) "true" else "false"});
    try out.writer.writeAll(",\"server_url\":");
    if (record.server_url) |url| {
        try std.json.Stringify.value(url, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"exit_code\":");
    if (record.exit_code) |code| {
        try out.writer.print("{d}", .{code});
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"state\":");
    try std.json.Stringify.value(@tagName(record.state), .{}, &out.writer);
    try out.writer.writeAll(",\"diagnostic\":");
    if (record.diagnostic) |diagnostic| {
        try std.json.Stringify.value(diagnostic, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn parseRecord(alloc: Allocator, json_text: []const u8) !Record {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch return error.InvalidBackgroundRecord;
    defer parsed.deinit();

    const root = try requireObject(parsed.value);
    const record_schema_version = try requireSchemaVersion(root);

    const id = try requireU64(root, "id");
    var background_record_id: ?StableBackgroundRecordId = null;
    var process_token_raw: ?[]const u8 = null;
    var log_storage: ?LogStorage = null;
    errdefer if (log_storage) |*storage| storage.deinit(alloc);
    if (record_schema_version == schema_version) {
        background_record_id = try parseStableId(
            try requireString(root, "background_record_id"),
        );
        process_token_raw = try optionalString(root.get("process_token"));
        if (process_token_raw) |token| {
            _ = process_supervisor.ProcessInstanceToken.parse(token) catch
                return error.InvalidBackgroundRecord;
        }
        const storage_value = root.get("log_storage") orelse
            return error.InvalidBackgroundRecord;
        log_storage = try parseLogStorageValue(alloc, storage_value);
    }
    const pid_raw = try requireString(root, "pid");
    const command_raw = try requireString(root, "command");
    const cwd_raw = try requireString(root, "cwd");
    const log_path_raw = try requireString(root, "log_path");
    const expect_url = try requireBool(root, "expect_url");
    const server_url_raw = try optionalString(root.get("server_url"));
    const started_at_ms = try requireI64(root, "started_at_ms");
    const updated_at_ms = try requireI64(root, "updated_at_ms");
    const exit_code = try optionalI32(root.get("exit_code"));
    const state = try parseState(try requireString(root, "state"));
    const diagnostic_raw = try optionalString(root.get("diagnostic"));

    const pid = try alloc.dupe(u8, pid_raw);
    errdefer alloc.free(pid);
    const command = try alloc.dupe(u8, command_raw);
    errdefer alloc.free(command);
    const cwd = try alloc.dupe(u8, cwd_raw);
    errdefer alloc.free(cwd);
    const log_path = try alloc.dupe(u8, log_path_raw);
    errdefer alloc.free(log_path);

    var process_token: ?[]u8 = null;
    errdefer if (process_token) |value| alloc.free(value);
    if (process_token_raw) |value| {
        process_token = try alloc.dupe(u8, value);
    }

    var server_url: ?[]u8 = null;
    errdefer if (server_url) |url| alloc.free(url);
    if (server_url_raw) |url| {
        server_url = try alloc.dupe(u8, url);
    }

    var diagnostic: ?[]u8 = null;
    errdefer if (diagnostic) |value| alloc.free(value);
    if (diagnostic_raw) |value| {
        diagnostic = try alloc.dupe(u8, value);
    }

    return .{
        .id = id,
        .background_record_id = background_record_id,
        .process_token = process_token,
        .pid = pid,
        .command = command,
        .cwd = cwd,
        .log_path = log_path,
        .log_storage = log_storage,
        .expect_url = expect_url,
        .server_url = server_url,
        .started_at_ms = started_at_ms,
        .updated_at_ms = updated_at_ms,
        .exit_code = exit_code,
        .state = state,
        .diagnostic = diagnostic,
    };
}

fn parseState(raw: []const u8) !TaskState {
    return std.meta.stringToEnum(TaskState, raw) orelse error.InvalidBackgroundRecord;
}

fn requireSchemaVersion(object: std.json.ObjectMap) !i64 {
    const version = try requireI64(object, "schema_version");
    if (version != legacy_schema_version and version != schema_version) {
        return error.UnsupportedBackgroundSchema;
    }
    return version;
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidBackgroundRecord;
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    if (value != .string) return error.InvalidBackgroundRecord;
    return value.string;
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    if (value != .bool) return error.InvalidBackgroundRecord;
    return value.bool;
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    return switch (value) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    return switch (value) {
        .integer => |number| blk: {
            if (number < 0) return error.InvalidBackgroundRecord;
            break :blk @intCast(number);
        },
        .number_string => |text| std.fmt.parseUnsigned(u64, text, 10) catch return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

fn optionalString(maybe_value: ?std.json.Value) !?[]const u8 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidBackgroundRecord,
    };
}

fn optionalI32(maybe_value: ?std.json.Value) !?i32 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .null => null,
        .integer => |number| blk: {
            if (number < std.math.minInt(i32) or number > std.math.maxInt(i32)) {
                return error.InvalidBackgroundRecord;
            }
            break :blk @intCast(number);
        },
        .number_string => |text| std.fmt.parseInt(i32, text, 10) catch return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

pub fn sortRecordsNewestFirst(items: []Record) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j - 1].updated_at_ms < items[j].updated_at_ms) : (j -= 1) {
            std.mem.swap(Record, &items[j - 1], &items[j]);
        }
    }
}

pub const DurableRecordRank = struct {
    updated_at_ms: i64,
    source_session_id: []const u8,
    background_record_id: StableBackgroundRecordId,
};

pub fn durableRecordRanksBefore(
    left: DurableRecordRank,
    right: DurableRecordRank,
) bool {
    if (left.updated_at_ms != right.updated_at_ms) {
        return left.updated_at_ms > right.updated_at_ms;
    }
    const source_order = std.mem.order(
        u8,
        left.source_session_id,
        right.source_session_id,
    );
    if (source_order != .eq) return source_order == .gt;
    return std.mem.order(
        u8,
        &left.background_record_id,
        &right.background_record_id,
    ) == .gt;
}

fn parseLogStorageValue(
    alloc: Allocator,
    value: std.json.Value,
) !LogStorage {
    if (value != .object) return error.InvalidBackgroundRecord;
    const kind = try requireString(value.object, "kind");
    if (std.mem.eql(u8, kind, "managed_session")) {
        const name = try requireString(value.object, "managed_log_name");
        session_child_store.SessionChildCapability.validateManagedName(name) catch
            return error.InvalidBackgroundRecord;
        return .{ .managed_session = .{
            .managed_log_name = try alloc.dupe(u8, name),
        } };
    }
    if (std.mem.eql(u8, kind, "external")) {
        const path = try requireString(value.object, "path");
        if (!std.fs.path.isAbsolute(path)) {
            return error.InvalidBackgroundRecord;
        }
        return .{ .external = .{ .path = try alloc.dupe(u8, path) } };
    }
    return error.InvalidBackgroundRecord;
}

fn encodeStableId(
    out: *[32]u8,
    stable_id: StableBackgroundRecordId,
) void {
    const alphabet = "0123456789abcdef";
    for (stable_id, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn parseStableId(text: []const u8) !StableBackgroundRecordId {
    if (text.len != 32) return error.InvalidBackgroundRecord;
    var stable_id: StableBackgroundRecordId = undefined;
    for (&stable_id, 0..) |*byte, index| {
        const high = std.fmt.charToDigit(text[index * 2], 16) catch
            return error.InvalidBackgroundRecord;
        const low = std.fmt.charToDigit(text[index * 2 + 1], 16) catch
            return error.InvalidBackgroundRecord;
        if (std.ascii.isUpper(text[index * 2]) or
            std.ascii.isUpper(text[index * 2 + 1]))
        {
            return error.InvalidBackgroundRecord;
        }
        byte.* = @intCast(high * 16 + low);
    }
    return stable_id;
}

fn initTestStore(alloc: Allocator, root_dir: std.Io.Dir) !Store {
    try root_dir.createDirPath(io_mod.getIo(), "background");
    const bg_dir = try io_mod.dirRealpathAlloc(alloc, root_dir, "background");
    defer alloc.free(bg_dir);
    return Store.initWithDir(alloc, bg_dir);
}

fn writeStoreFile(alloc: Allocator, store: Store, name: []const u8, text: []const u8) !void {
    var entry = try store.capability.atomicReplace(
        alloc,
        .background_records,
        name,
        text,
    );
    entry.deinit(alloc);
}

fn writeRecordText(alloc: Allocator, store: Store, id: u64, text: []const u8) !void {
    const name = try recordName(alloc, id);
    defer alloc.free(name);
    try writeStoreFile(alloc, store, name, text);
}

fn validRecordJson(alloc: Allocator, id: u64, updated_at_ms: i64) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":1,\"id\":{d},\"started_at_ms\":1,\"updated_at_ms\":{d},\"pid\":\"{d}\",\"command\":\"npm run dev\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/{d}.log\",\"expect_url\":true,\"server_url\":\"http://localhost:{d}\",\"exit_code\":null,\"state\":\"running\"}}",
        .{ id, updated_at_ms, 1000 + id, id, 3000 + id },
    );
}

fn validRecordV2Json(
    alloc: Allocator,
    id: u64,
    stable_id: StableBackgroundRecordId,
    updated_at_ms: i64,
) ![]u8 {
    var encoded: [32]u8 = undefined;
    encodeStableId(&encoded, stable_id);
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":2,\"id\":{d},\"background_record_id\":\"{s}\",\"process_token\":\"linux:00112233445566778899aabbccddeeff:12345\",\"log_storage\":{{\"kind\":\"external\",\"path\":\"/tmp/{d}.log\"}},\"started_at_ms\":1,\"updated_at_ms\":{d},\"pid\":\"{d}\",\"command\":\"npm run dev\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/{d}.log\",\"expect_url\":true,\"server_url\":null,\"exit_code\":null,\"state\":\"running\",\"diagnostic\":null}}",
        .{ id, encoded[0..], id, updated_at_ms, 1000 + id, id },
    );
}

fn recordJsonWithNumericFields(
    alloc: Allocator,
    id: []const u8,
    started_at_ms: []const u8,
    updated_at_ms: []const u8,
    exit_code: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":1,\"id\":{s},\"started_at_ms\":{s},\"updated_at_ms\":{s},\"pid\":\"100\",\"command\":\"vite\",\"cwd\":\"/tmp\",\"log_path\":\"/tmp/a.log\",\"expect_url\":false,\"server_url\":null,\"exit_code\":{s},\"state\":\"running\"}}",
        .{ id, started_at_ms, updated_at_ms, exit_code },
    );
}

fn expectParseError(expected: anyerror, json_text: []const u8) !void {
    const alloc = std.testing.allocator;
    if (parseRecord(alloc, json_text)) |parsed| {
        var record = parsed;
        defer record.deinit(alloc);
        return error.ExpectedParseFailure;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}
