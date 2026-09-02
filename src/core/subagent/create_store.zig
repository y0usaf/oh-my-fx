const std = @import("std");
const domain = @import("domain.zig");
const io_mod = @import("../shared/io.zig");
const session_child_store = @import("../session/session_child_store.zig");
const tool_result = @import("tool_result.zig");

const Allocator = std.mem.Allocator;
const schema_version: u64 = 3;
const process_epoch_schema_version: u64 = 2;
const legacy_schema_version: u64 = 1;
const max_record_bytes: usize = 512 * 1024;
const max_outstanding_operations: usize = 256;
const record_file = "create-operations.json";
const lock_file = "subagent-control.lock";
const lock_deadline_ms: u64 = 2000;

pub const Entry = struct {
    operation_id: []u8,
    request_fingerprint: [32]u8,
    child_id: []u8,

    fn deinit(self: *Entry, alloc: Allocator) void {
        alloc.free(self.operation_id);
        alloc.free(self.child_id);
        self.* = undefined;
    }
};

pub const OutstandingOperation = struct {
    operation_id: []u8,

    fn deinit(self: *OutstandingOperation, alloc: Allocator) void {
        alloc.free(self.operation_id);
        self.* = undefined;
    }
};

pub const IdentityResolution = enum {
    receipt,
    stable_failure,
    aborted_before_effect,
    pending_approval,
    retryable_failure,
    commit_indeterminate,
};

pub const IdentityFinalization = enum {
    retire,
    retain,
};

pub fn identityFinalization(
    resolution: IdentityResolution,
) IdentityFinalization {
    return switch (resolution) {
        .receipt,
        .stable_failure,
        .aborted_before_effect,
        => .retire,
        .pending_approval,
        .retryable_failure,
        .commit_indeterminate,
        => .retain,
    };
}

pub const Record = struct {
    root_id: []u8,
    generation: u64,
    entries: []Entry,
    outstanding_operations: []OutstandingOperation,
    identity_epoch_high: u64 = 0,
    legacy_replay_closed: bool = false,
    model_replay_floor: u64 = 0,
    human_replay_floor: u64 = 0,
    model_epoch_high: u64 = 0,
    human_epoch_high: u64 = 0,

    pub fn init(alloc: Allocator, root_id: []const u8) !Record {
        const owned_root = try alloc.dupe(u8, root_id);
        errdefer alloc.free(owned_root);
        const entries = try alloc.alloc(Entry, 0);
        errdefer alloc.free(entries);
        return .{
            .root_id = owned_root,
            .generation = 0,
            .entries = entries,
            .outstanding_operations = try alloc.alloc(OutstandingOperation, 0),
        };
    }

    pub fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.root_id);
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
        for (self.outstanding_operations) |*operation| operation.deinit(alloc);
        alloc.free(self.outstanding_operations);
        self.* = undefined;
    }

    pub fn find(self: Record, operation_id: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.operation_id, operation_id)) return entry;
        }
        return null;
    }

    pub fn classify(self: Record, operation_id: []const u8) IdentityStatus {
        if (self.find(operation_id) != null) return .retained;
        const identity = tool_result.parseBoundOperationId(operation_id) orelse
            return if (self.legacy_replay_closed) .expired else .absent;
        if (identity.authority == .process_local) return .expired;
        if (self.hasOutstanding(operation_id)) return .absent;
        return .expired;
    }

    pub fn outstandingEpochForInvocation(
        self: Record,
        invocation_id: []const u8,
        source: domain.OperationIdentitySource,
    ) ?u64 {
        for (self.outstanding_operations) |operation| {
            if (!tool_result.boundOperationMatchesInvocation(
                operation.operation_id,
                invocation_id,
                source,
            )) continue;
            return tool_result.parseBoundOperationId(operation.operation_id).?.epoch;
        }
        return null;
    }

    pub fn hasOutstanding(self: Record, operation_id: []const u8) bool {
        for (self.outstanding_operations) |operation| {
            if (std.mem.eql(u8, operation.operation_id, operation_id)) return true;
        }
        return false;
    }

    pub fn reserveIdentity(
        self: *Record,
        alloc: Allocator,
        invocation_id: []const u8,
        source: domain.OperationIdentitySource,
    ) !u64 {
        if (self.outstandingEpochForInvocation(invocation_id, source)) |epoch| {
            return epoch;
        }
        if (self.outstanding_operations.len == max_outstanding_operations) {
            return error.TooManyOutstandingOperations;
        }
        const epoch = try std.math.add(u64, self.identity_epoch_high, 1);
        const operation_id = try tool_result.boundOperationIdAlloc(
            alloc,
            invocation_id,
            source,
            epoch,
        );
        errdefer alloc.free(operation_id);
        const replacement = try alloc.alloc(
            OutstandingOperation,
            self.outstanding_operations.len + 1,
        );
        @memcpy(
            replacement[0..self.outstanding_operations.len],
            self.outstanding_operations,
        );
        replacement[self.outstanding_operations.len] = .{
            .operation_id = operation_id,
        };
        alloc.free(self.outstanding_operations);
        self.outstanding_operations = replacement;
        self.identity_epoch_high = epoch;
        self.generation = try std.math.add(u64, self.generation, 1);
        return epoch;
    }

    pub fn completeIdentity(
        self: *Record,
        alloc: Allocator,
        operation_id: []const u8,
    ) !bool {
        var remove_index: ?usize = null;
        for (self.outstanding_operations, 0..) |operation, index| {
            if (std.mem.eql(u8, operation.operation_id, operation_id)) {
                remove_index = index;
                break;
            }
        }
        const index = remove_index orelse return false;
        const replacement = try alloc.alloc(
            OutstandingOperation,
            self.outstanding_operations.len - 1,
        );
        @memcpy(replacement[0..index], self.outstanding_operations[0..index]);
        @memcpy(
            replacement[index..],
            self.outstanding_operations[index + 1 ..],
        );
        self.outstanding_operations[index].deinit(alloc);
        alloc.free(self.outstanding_operations);
        self.outstanding_operations = replacement;
        self.generation = try std.math.add(u64, self.generation, 1);
        return true;
    }

    pub fn finalizeIdentity(
        self: *Record,
        alloc: Allocator,
        operation_id: []const u8,
        finalization: IdentityFinalization,
    ) !bool {
        return switch (finalization) {
            .retain => false,
            .retire => self.completeIdentity(alloc, operation_id),
        };
    }

    pub fn append(
        self: *Record,
        alloc: Allocator,
        operation_id: []const u8,
        request_fingerprint: [32]u8,
        child_id: []const u8,
    ) !void {
        const next_generation = try std.math.add(u64, self.generation, 1);
        const owned_operation = try alloc.dupe(u8, operation_id);
        errdefer alloc.free(owned_operation);
        const owned_child = try alloc.dupe(u8, child_id);
        errdefer alloc.free(owned_child);
        const replacement = try alloc.alloc(Entry, self.entries.len + 1);
        @memcpy(replacement[0..self.entries.len], self.entries);
        replacement[self.entries.len] = .{
            .operation_id = owned_operation,
            .request_fingerprint = request_fingerprint,
            .child_id = owned_child,
        };
        alloc.free(self.entries);
        self.entries = replacement;
        self.generation = next_generation;
        if (tool_result.parseBoundOperationId(operation_id)) |identity| {
            self.legacy_replay_closed = true;
            if (identity.authority != .manager) return;
            switch (identity.source) {
                .model => self.model_epoch_high = @max(self.model_epoch_high, identity.epoch),
                .human => self.human_epoch_high = @max(self.human_epoch_high, identity.epoch),
            }
        }
    }

    fn clone(self: Record, alloc: Allocator) !Record {
        const root_id = try alloc.dupe(u8, self.root_id);
        errdefer alloc.free(root_id);
        const entries = try alloc.alloc(Entry, self.entries.len);
        var initialized: usize = 0;
        errdefer {
            for (entries[0..initialized]) |*entry| entry.deinit(alloc);
            alloc.free(entries);
        }
        for (self.entries) |entry| {
            const operation_id = try alloc.dupe(u8, entry.operation_id);
            errdefer alloc.free(operation_id);
            entries[initialized] = .{
                .operation_id = operation_id,
                .request_fingerprint = entry.request_fingerprint,
                .child_id = try alloc.dupe(u8, entry.child_id),
            };
            initialized += 1;
        }
        const outstanding = try alloc.alloc(
            OutstandingOperation,
            self.outstanding_operations.len,
        );
        var outstanding_initialized: usize = 0;
        errdefer {
            for (outstanding[0..outstanding_initialized]) |*operation| {
                operation.deinit(alloc);
            }
            alloc.free(outstanding);
        }
        for (self.outstanding_operations, outstanding) |operation, *copy| {
            copy.* = .{
                .operation_id = try alloc.dupe(u8, operation.operation_id),
            };
            outstanding_initialized += 1;
        }
        return .{
            .root_id = root_id,
            .generation = self.generation,
            .entries = entries,
            .outstanding_operations = outstanding,
            .identity_epoch_high = self.identity_epoch_high,
            .legacy_replay_closed = self.legacy_replay_closed,
            .model_replay_floor = self.model_replay_floor,
            .human_replay_floor = self.human_replay_floor,
            .model_epoch_high = self.model_epoch_high,
            .human_epoch_high = self.human_epoch_high,
        };
    }
};

pub const IdentityStatus = enum { absent, retained, expired };

pub const LoadError = error{
    OutOfMemory,
    RecordNotFound,
    InvalidRecord,
    UnsupportedSchema,
    RecordTooLarge,
    PathUnsafe,
    PrivateStatePermissionsUnsupported,
    StoreFailed,
};

pub const SaveError = error{
    OutOfMemory,
    IdentityMismatch,
    RecordTooLarge,
    PathUnsafe,
    PrivateStatePermissionsUnsupported,
    CommitIndeterminate,
    StoreFailed,
};

pub const LockError = error{
    OutOfMemory,
    LockBusy,
    LockUnsupported,
    PathUnsafe,
    PrivateStatePermissionsUnsupported,
    StoreFailed,
};

pub const Store = struct {
    capability: *session_child_store.SessionChildCapability,
    expected_root_id: []const u8,

    pub fn acquireLock(self: Store) LockError!io_mod.TimedAdvisoryLock {
        return self.capability.acquireTimedAdvisoryLock(
            .subagent_control,
            lock_file,
            lock_deadline_ms,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LockBusy => error.LockBusy,
            error.LockUnsupported => error.LockUnsupported,
            error.SessionPathUnsafe => error.PathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.StoreFailed,
        };
    }

    pub fn loadOptional(self: Store, alloc: Allocator) LoadError!?Record {
        var file = self.capability.openFileReadOnly(
            alloc,
            .subagent_control,
            record_file,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.PathUnsafe,
            error.PrivateStatePermissionsUnsupported => {
                return error.PrivateStatePermissionsUnsupported;
            },
            else => return error.StoreFailed,
        };
        defer file.deinit();
        const bytes = file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.RecordTooLarge,
            else => return error.StoreFailed,
        };
        defer alloc.free(bytes);
        var record = try parseRecord(alloc, bytes);
        errdefer record.deinit(alloc);
        if (!std.mem.eql(u8, record.root_id, self.expected_root_id)) {
            return error.InvalidRecord;
        }
        return record;
    }

    pub fn save(self: Store, alloc: Allocator, record: Record) SaveError!void {
        if (!std.mem.eql(u8, record.root_id, self.expected_root_id)) {
            return error.IdentityMismatch;
        }
        var retained = record.clone(alloc) catch return error.OutOfMemory;
        defer retained.deinit(alloc);
        const bytes = prepareEncoded(alloc, &retained) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.RecordTooLarge => error.RecordTooLarge,
        };
        defer alloc.free(bytes);
        var entry = self.capability.atomicReplace(
            alloc,
            .subagent_control,
            record_file,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.PathUnsafe,
            error.PrivateStatePermissionsUnsupported => {
                return error.PrivateStatePermissionsUnsupported;
            },
            error.SessionChildCommitIndeterminate => return error.CommitIndeterminate,
            else => return error.StoreFailed,
        };
        entry.deinit(alloc);
    }
};

fn prepareEncoded(alloc: Allocator, record: *Record) error{ OutOfMemory, RecordTooLarge }![]u8 {
    return prepareEncodedLimit(alloc, record, max_record_bytes);
}

fn prepareEncodedLimit(
    alloc: Allocator,
    record: *Record,
    byte_limit: usize,
) error{ OutOfMemory, RecordTooLarge }![]u8 {
    while (true) {
        const bytes = renderRecord(alloc, record.*) catch return error.OutOfMemory;
        if (bytes.len <= byte_limit) return bytes;
        alloc.free(bytes);
        if (!try evictOldestHorizon(alloc, record)) return error.RecordTooLarge;
    }
}

fn evictOldestHorizon(alloc: Allocator, record: *Record) error{OutOfMemory}!bool {
    if (record.entries.len <= 1) return false;
    const evicted_index = oldestCommittedIssuanceIndex(record.entries);
    const evicted_identity = tool_result.parseBoundOperationId(
        record.entries[evicted_index].operation_id,
    );
    const retained = try alloc.alloc(Entry, record.entries.len - 1);
    @memcpy(retained[0..evicted_index], record.entries[0..evicted_index]);
    @memcpy(retained[evicted_index..], record.entries[evicted_index + 1 ..]);
    record.entries[evicted_index].deinit(alloc);
    alloc.free(record.entries);
    record.entries = retained;
    if (evicted_identity) |identity| {
        if (identity.authority != .manager) {
            record.legacy_replay_closed = true;
            return true;
        }
        const next = identity.epoch +| 1;
        switch (identity.source) {
            .model => record.model_replay_floor = @max(record.model_replay_floor, next),
            .human => record.human_replay_floor = @max(record.human_replay_floor, next),
        }
    } else {
        record.legacy_replay_closed = true;
    }
    return true;
}

fn oldestCommittedIssuanceIndex(entries: []const Entry) usize {
    var selected: ?usize = null;
    var selected_epoch: u64 = 0;
    for (entries, 0..) |entry, index| {
        const identity = tool_result.parseBoundOperationId(entry.operation_id);
        if (identity == null or identity.?.authority == .process_local) return index;
        if (selected == null or identity.?.epoch < selected_epoch) {
            selected = index;
            selected_epoch = identity.?.epoch;
        }
    }
    return selected.?;
}

fn renderRecord(alloc: Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"schema_version\":{d},\"root_id\":", .{schema_version});
    try std.json.Stringify.value(record.root_id, .{}, &out.writer);
    try out.writer.print(",\"generation\":{d},\"entries\":[", .{record.generation});
    for (record.entries, 0..) |entry, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"operation_id\":");
        try std.json.Stringify.value(entry.operation_id, .{}, &out.writer);
        try out.writer.writeAll(",\"request_fingerprint\":");
        const fingerprint = std.fmt.bytesToHex(entry.request_fingerprint, .lower);
        try std.json.Stringify.value(fingerprint[0..], .{}, &out.writer);
        try out.writer.writeAll(",\"child_id\":");
        try std.json.Stringify.value(entry.child_id, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("],\"outstanding_operations\":[");
    for (record.outstanding_operations, 0..) |operation, index| {
        if (index != 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(operation.operation_id, .{}, &out.writer);
    }
    try out.writer.print(
        "],\"identity_epoch_high\":{d},\"legacy_replay_closed\":{},\"model_replay_floor\":{d},\"human_replay_floor\":{d},\"model_epoch_high\":{d},\"human_epoch_high\":{d}}}",
        .{
            record.identity_epoch_high,
            record.legacy_replay_closed,
            record.model_replay_floor,
            record.human_replay_floor,
            record.model_epoch_high,
            record.human_epoch_high,
        },
    );
    return out.toOwnedSlice();
}

fn parseRecord(alloc: Allocator, bytes: []const u8) LoadError!Record {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.InvalidRecord;
    defer parsed.deinit();
    const root = if (parsed.value == .object) parsed.value.object else return error.InvalidRecord;
    const version = requireU64(root, "schema_version") catch return error.InvalidRecord;
    if (version != schema_version and version != process_epoch_schema_version and
        version != legacy_schema_version)
    {
        return error.UnsupportedSchema;
    }
    const object = exactObject(parsed.value, if (version == schema_version) &.{
        "schema_version",
        "root_id",
        "generation",
        "entries",
        "outstanding_operations",
        "identity_epoch_high",
        "legacy_replay_closed",
        "model_replay_floor",
        "human_replay_floor",
        "model_epoch_high",
        "human_epoch_high",
    } else if (version == process_epoch_schema_version) &.{
        "schema_version",
        "root_id",
        "generation",
        "entries",
        "legacy_replay_closed",
        "model_replay_floor",
        "human_replay_floor",
        "model_epoch_high",
        "human_epoch_high",
    } else &.{
        "schema_version",
        "root_id",
        "generation",
        "entries",
    }) catch return error.InvalidRecord;
    const root_raw = requireString(object, "root_id") catch return error.InvalidRecord;
    domain.validateId(root_raw) catch return error.InvalidRecord;
    const entries_value = object.get("entries") orelse return error.InvalidRecord;
    if (entries_value != .array) return error.InvalidRecord;
    const generation = requireU64(object, "generation") catch return error.InvalidRecord;
    if (generation < entries_value.array.items.len) return error.InvalidRecord;
    const legacy_replay_closed = if (version != legacy_schema_version)
        requireBool(object, "legacy_replay_closed") catch return error.InvalidRecord
    else
        true;
    const stored_model_replay_floor = if (version != legacy_schema_version)
        requireU64(object, "model_replay_floor") catch return error.InvalidRecord
    else
        0;
    const stored_human_replay_floor = if (version != legacy_schema_version)
        requireU64(object, "human_replay_floor") catch return error.InvalidRecord
    else
        0;
    const stored_model_epoch_high = if (version != legacy_schema_version)
        requireU64(object, "model_epoch_high") catch return error.InvalidRecord
    else
        0;
    const stored_human_epoch_high = if (version != legacy_schema_version)
        requireU64(object, "human_epoch_high") catch return error.InvalidRecord
    else
        0;
    if (stored_model_replay_floor > stored_model_epoch_high +| 1 or
        stored_human_replay_floor > stored_human_epoch_high +| 1)
    {
        return error.InvalidRecord;
    }
    if (!legacy_replay_closed and (stored_model_replay_floor != 0 or
        stored_human_replay_floor != 0 or stored_model_epoch_high != 0 or
        stored_human_epoch_high != 0))
    {
        return error.InvalidRecord;
    }
    const model_replay_floor = if (version == schema_version)
        stored_model_replay_floor
    else
        0;
    const human_replay_floor = if (version == schema_version)
        stored_human_replay_floor
    else
        0;
    const model_epoch_high = if (version == schema_version)
        stored_model_epoch_high
    else
        0;
    const human_epoch_high = if (version == schema_version)
        stored_human_epoch_high
    else
        0;
    const identity_epoch_high = if (version == schema_version)
        requireU64(object, "identity_epoch_high") catch return error.InvalidRecord
    else
        0;

    const root_id = try alloc.dupe(u8, root_raw);
    errdefer alloc.free(root_id);
    const entries = try alloc.alloc(Entry, entries_value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    for (entries_value.array.items, entries) |value, *entry| {
        const entry_object = exactObject(value, &.{
            "operation_id",
            "request_fingerprint",
            "child_id",
        }) catch return error.InvalidRecord;
        const operation_raw = requireString(entry_object, "operation_id") catch
            return error.InvalidRecord;
        domain.validateOperationId(operation_raw) catch return error.InvalidRecord;
        if (tool_result.parseBoundOperationId(operation_raw)) |identity| {
            if (!legacy_replay_closed) return error.InvalidRecord;
            const high = switch (identity.source) {
                .model => if (version == schema_version)
                    model_epoch_high
                else
                    stored_model_epoch_high,
                .human => if (version == schema_version)
                    human_epoch_high
                else
                    stored_human_epoch_high,
            };
            if (identity.authority == .manager and version != schema_version) {
                return error.InvalidRecord;
            }
            if (identity.authority == .process_local and
                version == schema_version)
            {
                // Retained pre-migration identities replay exactly but never
                // contribute to the manager-issued horizon.
            } else if (identity.epoch > high) {
                return error.InvalidRecord;
            }
        }
        const child_raw = requireString(entry_object, "child_id") catch
            return error.InvalidRecord;
        domain.validateId(child_raw) catch return error.InvalidRecord;
        for (entries[0..initialized]) |prior| {
            if (std.mem.eql(u8, prior.operation_id, operation_raw) or
                std.mem.eql(u8, prior.child_id, child_raw)) return error.InvalidRecord;
        }
        const operation_id = try alloc.dupe(u8, operation_raw);
        errdefer alloc.free(operation_id);
        const child_id = try alloc.dupe(u8, child_raw);
        errdefer alloc.free(child_id);
        entry.* = .{
            .operation_id = operation_id,
            .request_fingerprint = parseFingerprint(entry_object) catch
                return error.InvalidRecord,
            .child_id = child_id,
        };
        initialized += 1;
    }
    const outstanding_value = if (version == schema_version)
        object.get("outstanding_operations") orelse return error.InvalidRecord
    else
        null;
    if (outstanding_value) |value| {
        if (value != .array) return error.InvalidRecord;
    }
    const outstanding_count = if (outstanding_value) |value|
        value.array.items.len
    else
        0;
    if (outstanding_count > max_outstanding_operations) {
        return error.InvalidRecord;
    }
    const outstanding = try alloc.alloc(OutstandingOperation, outstanding_count);
    var outstanding_initialized: usize = 0;
    errdefer {
        for (outstanding[0..outstanding_initialized]) |*operation| {
            operation.deinit(alloc);
        }
        alloc.free(outstanding);
    }
    if (outstanding_value) |value| {
        for (value.array.items, outstanding) |item, *operation| {
            if (item != .string) return error.InvalidRecord;
            domain.validateOperationId(item.string) catch return error.InvalidRecord;
            const identity = tool_result.parseBoundOperationId(item.string) orelse
                return error.InvalidRecord;
            if (identity.authority != .manager or
                identity.epoch > identity_epoch_high)
            {
                return error.InvalidRecord;
            }
            for (outstanding[0..outstanding_initialized]) |prior| {
                if (std.mem.eql(u8, prior.operation_id, item.string)) {
                    return error.InvalidRecord;
                }
            }
            operation.* = .{
                .operation_id = try alloc.dupe(u8, item.string),
            };
            outstanding_initialized += 1;
        }
    }
    if (identity_epoch_high < model_epoch_high or
        identity_epoch_high < human_epoch_high)
    {
        return error.InvalidRecord;
    }
    return .{
        .root_id = root_id,
        .generation = generation,
        .entries = entries,
        .outstanding_operations = outstanding,
        .identity_epoch_high = identity_epoch_high,
        .legacy_replay_closed = legacy_replay_closed,
        .model_replay_floor = model_replay_floor,
        .human_replay_floor = human_replay_floor,
        .model_epoch_high = model_epoch_high,
        .human_epoch_high = human_epoch_high,
    };
}

fn parseFingerprint(object: std.json.ObjectMap) ![32]u8 {
    const raw = try requireString(object, "request_fingerprint");
    if (raw.len != 64) return error.InvalidRecord;
    var fingerprint: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&fingerprint, raw) catch return error.InvalidRecord;
    const canonical = std.fmt.bytesToHex(fingerprint, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidRecord;
    return fingerprint;
}

fn exactObject(value: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    if (value != .object or value.object.count() != keys.len) return error.InvalidRecord;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidRecord;
    }
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidRecord;
    if (value != .string) return error.InvalidRecord;
    return value.string;
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidRecord;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidRecord,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch
            error.InvalidRecord,
        else => error.InvalidRecord,
    };
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidRecord;
    if (value != .bool) return error.InvalidRecord;
    return value.bool;
}
