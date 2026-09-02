const std = @import("std");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

pub const max_error_code_bytes: usize = 64;

pub fn operationIdAlloc(alloc: Allocator, invocation_id: []const u8) ![]u8 {
    domain.validateOperationId(invocation_id) catch {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(invocation_id, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.allocPrint(alloc, "call_{s}", .{&hex});
    };
    return alloc.dupe(u8, invocation_id);
}

/// Binds an untrusted invocation identifier to fx-owned issuance metadata.
/// Only the digest of the provider/UI identifier is retained in the durable
/// operation identity.
pub fn boundOperationIdAlloc(
    alloc: Allocator,
    invocation_id: []const u8,
    source: domain.OperationIdentitySource,
    epoch: u64,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(invocation_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(
        alloc,
        "fxop:2:{s}:{d}:{s}",
        .{ operationSourceTag(source), epoch, &hex },
    );
}

pub fn parseBoundOperationId(value: []const u8) ?domain.BoundOperationIdentity {
    var parts = std.mem.splitScalar(u8, value, ':');
    if (!std.mem.eql(u8, parts.next() orelse return null, "fxop")) return null;
    const second = parts.next() orelse return null;
    const manager_issued = std.mem.eql(u8, second, "2");
    const source_raw = if (manager_issued)
        parts.next() orelse return null
    else
        second;
    const epoch_raw = parts.next() orelse return null;
    const digest = parts.next() orelse return null;
    if (parts.next() != null or digest.len != 64) return null;
    if (epoch_raw.len == 0 or (epoch_raw.len > 1 and epoch_raw[0] == '0')) return null;
    var decoded: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&decoded, digest) catch return null;
    const canonical = std.fmt.bytesToHex(decoded, .lower);
    if (!std.mem.eql(u8, &canonical, digest)) return null;
    const source: domain.OperationIdentitySource = if (std.mem.eql(u8, source_raw, "m"))
        .model
    else if (std.mem.eql(u8, source_raw, "h"))
        .human
    else
        return null;
    return .{
        .source = source,
        .epoch = std.fmt.parseUnsigned(u64, epoch_raw, 10) catch return null,
        .authority = if (manager_issued) .manager else .process_local,
    };
}

pub fn boundOperationMatchesInvocation(
    operation_id: []const u8,
    invocation_id: []const u8,
    source: domain.OperationIdentitySource,
) bool {
    const identity = parseBoundOperationId(operation_id) orelse return false;
    if (identity.authority != .manager or identity.source != source) return false;
    const digest_start = std.mem.findScalarLast(u8, operation_id, ':') orelse
        return false;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(invocation_id, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, operation_id[digest_start + 1 ..], &expected);
}

fn operationSourceTag(source: domain.OperationIdentitySource) []const u8 {
    return switch (source) {
        .model => "m",
        .human => "h",
    };
}

pub fn failureAlloc(
    alloc: Allocator,
    invocation_id: []const u8,
    child_id: ?[]const u8,
    status: []const u8,
    error_code: []const u8,
    retryable: bool,
    cursor: ?[]const u8,
) ![]u8 {
    const operation_id = try operationIdAlloc(alloc, invocation_id);
    defer alloc.free(operation_id);
    return outcomeAlloc(alloc, .{
        .ok = false,
        .operation_id = operation_id,
        .child_id = child_id,
        .status = status,
        .error_code = error_code[0..@min(error_code.len, max_error_code_bytes)],
        .retryable = retryable,
        .requested_json = "null",
        .cursor = cursor,
    });
}

pub const Outcome = struct {
    ok: bool,
    operation_id: []const u8,
    child_id: ?[]const u8,
    status: []const u8,
    error_code: ?[]const u8,
    retryable: bool,
    requested_json: []const u8,
    cursor: ?[]const u8,
};

pub fn outcomeAlloc(alloc: Allocator, outcome: Outcome) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"ok\":{s},\"operation_id\":", .{if (outcome.ok) "true" else "false"});
    try std.json.Stringify.value(outcome.operation_id, .{}, &out.writer);
    try out.writer.writeAll(",\"child_id\":");
    try optionalString(&out.writer, outcome.child_id);
    try out.writer.writeAll(",\"status\":");
    try std.json.Stringify.value(outcome.status, .{}, &out.writer);
    try out.writer.writeAll(",\"error_code\":");
    try optionalString(&out.writer, outcome.error_code);
    try out.writer.print(",\"retryable\":{s},\"requested\":", .{if (outcome.retryable) "true" else "false"});
    try out.writer.writeAll(outcome.requested_json);
    try out.writer.writeAll(",\"cursor\":");
    try optionalString(&out.writer, outcome.cursor);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn optionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}




