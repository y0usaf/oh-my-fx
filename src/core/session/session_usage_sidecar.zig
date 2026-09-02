const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session_usage = @import("session_usage.zig");
const generation_usage = @import("generation_usage_provider.zig");
const stream_provider = @import("../agent/stream_provider.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const sidecar_file = "usage-v2.json";
pub const max_sidecar_bytes: usize = session_usage.max_snapshot_bytes + 512;

pub const RestoreOutcome = enum {
    missing,
    restored,
    invalid,
    mismatched,
};

pub const Captured = union(enum) {
    missing,
    invalid: []const u8,
    encoded: []u8,

    pub fn deinit(self: *Captured, alloc: Allocator) void {
        switch (self.*) {
            .encoded => |bytes| alloc.free(bytes),
            .missing, .invalid => {},
        }
        self.* = undefined;
    }
};

const Decoded = struct {
    session_id: []u8,
    snapshot: session_usage.Snapshot,

    fn deinit(self: *Decoded, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

pub fn write(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    snapshot: session_usage.Snapshot,
) !void {
    const encoded = try encode(alloc, session_id, snapshot);
    defer alloc.free(encoded);
    try writeEncoded(alloc, session_dir, encoded);
}

pub fn encode(
    alloc: Allocator,
    session_id: []const u8,
    snapshot: session_usage.Snapshot,
) ![]u8 {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try encoded.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &encoded.writer);
    try encoded.writer.writeAll(",\"snapshot\":");
    try session_usage.writeRichSnapshot(&encoded.writer, snapshot);
    try encoded.writer.writeByte('}');
    if (encoded.written().len > max_sidecar_bytes) {
        return error.UsageSidecarTooLarge;
    }
    return try encoded.toOwnedSlice();
}

pub fn writeEncoded(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    encoded: []const u8,
) !void {
    if (encoded.len == 0 or encoded.len > max_sidecar_bytes) {
        return error.UsageSidecarTooLarge;
    }
    try io_mod.durableReplaceVerified(
        alloc,
        session_dir,
        sidecar_file,
        encoded,
    );
}

pub fn capture(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
) Allocator.Error!Captured {
    const initial = session_dir.dir.statFile(io_mod.getIo(), sidecar_file, .{
        .follow_symlinks = false,
    }) catch |err| {
        if (err == error.FileNotFound) return .missing;
        return .{ .invalid = @errorName(err) };
    };
    if (initial.kind != .file or initial.nlink != 1 or
        initial.permissions.toMode() & 0o777 != 0o600)
    {
        return .{ .invalid = "unsafe_initial_shape" };
    }
    if (initial.size == 0) return .{ .invalid = "empty" };
    if (initial.size > max_sidecar_bytes) return .{ .invalid = "oversized" };

    var file = session_dir.dir.openFile(io_mod.getIo(), sidecar_file, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.FileNotFound) return .missing;
        return .{ .invalid = @errorName(err) };
    };
    defer file.close(io_mod.getIo());
    const verified = file.stat(io_mod.getIo()) catch |err|
        return .{ .invalid = @errorName(err) };
    if (verified.kind != .file or verified.nlink != 1 or
        verified.permissions.toMode() & 0o777 != 0o600)
    {
        return .{ .invalid = "unsafe_verified_shape" };
    }
    if (verified.size != initial.size) return .{ .invalid = "changed_during_open" };
    const bytes = io_mod.readFileToEnd(
        alloc,
        &file,
        max_sidecar_bytes,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .invalid = @errorName(err) };
    };
    return .{ .encoded = bytes };
}

pub fn restoreIfMatching(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    continuity_at_ms: i64,
    durable: *session_usage.Snapshot,
) !RestoreOutcome {
    var captured = try capture(alloc, session_dir);
    defer captured.deinit(alloc);
    return restoreCaptured(
        alloc,
        captured,
        session_id,
        continuity_at_ms,
        durable,
    );
}

pub fn restoreCaptured(
    alloc: Allocator,
    captured: Captured,
    session_id: []const u8,
    continuity_at_ms: i64,
    durable: *session_usage.Snapshot,
) !RestoreOutcome {
    const bytes = switch (captured) {
        .missing => {
            try markContinuityGapIfNeeded(alloc, durable, continuity_at_ms);
            return .missing;
        },
        .invalid => |reason| {
            debug_trace.logf(
                "session",
                "event=usage_sidecar_invalid reason={s}",
                .{reason},
            );
            try markContinuityGapIfNeeded(alloc, durable, continuity_at_ms);
            return .invalid;
        },
        .encoded => |value| value,
    };
    var decoded = decode(alloc, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        traceInvalid(err);
        try markContinuityGapIfNeeded(alloc, durable, continuity_at_ms);
        return .invalid;
    };
    var decoded_owned = true;
    defer if (decoded_owned) decoded.deinit(alloc);
    if (!std.mem.eql(u8, decoded.session_id, session_id)) {
        traceInvalid(error.UsageSidecarSessionMismatch);
        try markContinuityGapIfNeeded(alloc, durable, continuity_at_ms);
        return .invalid;
    }

    if (!session_usage.billingProjectionEql(
        durable.*,
        decoded.snapshot,
    )) {
        carryRecoveryState(durable, &decoded.snapshot);
        try markContinuityGapIfNeeded(alloc, durable, continuity_at_ms);
        debug_trace.logf(
            "session",
            "event=usage_sidecar_mismatched reason=billing_projection_changed",
            .{},
        );
        return .mismatched;
    }

    if (!session_usage.rollbackProjectionEql(
        durable.*,
        decoded.snapshot,
    )) {
        mergeRichExtensions(durable, &decoded.snapshot);
        return .restored;
    }

    durable.deinit(alloc);
    durable.* = decoded.snapshot;
    alloc.free(decoded.session_id);
    decoded_owned = false;
    return .restored;
}

fn mergeRichExtensions(
    durable: *session_usage.Snapshot,
    rich: *session_usage.Snapshot,
) void {
    durable.reasoning_tokens = rich.reasoning_tokens;
    durable.request_count = rich.request_count;
    for (durable.models, rich.models) |*target, source| {
        target.reasoning_tokens = source.reasoning_tokens;
        target.request_count = source.request_count;
    }
    for (durable.pending, rich.pending) |*target, source| {
        target.observed_at_ms = source.observed_at_ms;
    }
    carryRecoveryState(durable, rich);
}

fn markContinuityGapIfNeeded(
    alloc: Allocator,
    durable: *session_usage.Snapshot,
    continuity_at_ms: i64,
) !void {
    if (durable.next_sequence <= 1) return;
    // Missing or unreadable rich state is indistinguishable from a rollback
    // binary advancing billable usage without updating the sidecar. Preserve
    // canonical totals, but qualifies rolling reports that include this gap.
    try session_usage.appendIncidentOwned(alloc, durable, .{
        .occurred_at_ms = @max(continuity_at_ms, 0),
        .completeness = .incomplete,
    });
}

fn carryRecoveryState(
    durable: *session_usage.Snapshot,
    rich: *session_usage.Snapshot,
) void {
    if (durable.publication_backlog.len == 0 and
        rich.publication_backlog.len > 0)
    {
        durable.publication_backlog = rich.publication_backlog;
        rich.publication_backlog = &.{};
    }
    if (durable.incidents.len == 0 and rich.incidents.len > 0) {
        durable.incidents = rich.incidents;
        rich.incidents = &.{};
    }
}

fn decode(alloc: Allocator, bytes: []const u8) !Decoded {
    if (bytes.len == 0 or bytes.len > max_sidecar_bytes) {
        return error.InvalidUsageSidecar;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUsageSidecar,
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 3) {
        return error.InvalidUsageSidecar;
    }
    const schema = parsed.value.object.get("schema_version") orelse
        return error.InvalidUsageSidecar;
    if (schema != .integer or schema.integer != 1) {
        return error.InvalidUsageSidecar;
    }
    const session_id_value = parsed.value.object.get("session_id") orelse
        return error.InvalidUsageSidecar;
    if (session_id_value != .string or session_id_value.string.len == 0) {
        return error.InvalidUsageSidecar;
    }
    const snapshot_value = parsed.value.object.get("snapshot") orelse
        return error.InvalidUsageSidecar;
    if (snapshot_value != .object or
        snapshot_value.object.get("schema_version") == null)
    {
        return error.InvalidUsageSidecar;
    }

    const session_id = try alloc.dupe(u8, session_id_value.string);
    errdefer alloc.free(session_id);
    var snapshot = try session_usage.parseSnapshotValue(alloc, snapshot_value);
    errdefer snapshot.deinit(alloc);
    return .{
        .session_id = session_id,
        .snapshot = snapshot,
    };
}

fn traceInvalid(err: anyerror) void {
    debug_trace.logf(
        "session",
        "event=usage_sidecar_invalid err={s}",
        .{@errorName(err)},
    );
}

fn openTestVerifiedDir(dir: std.Io.Dir) !io_mod.VerifiedDir {
    return .{
        .dir = try dir.openDir(
            io_mod.getIo(),
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ),
    };
}

fn legacyCopyForTest(
    alloc: Allocator,
    snapshot: session_usage.Snapshot,
) !session_usage.Snapshot {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try session_usage.writeSnapshot(&encoded.writer, snapshot);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer parsed.deinit();
    return session_usage.parseSnapshotValue(alloc, parsed.value);
}
