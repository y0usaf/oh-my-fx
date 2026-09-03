const std = @import("std");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const digest_hex_bytes = 16;

pub fn contentAddressedHandle(
    alloc: Allocator,
    source_handle: []const u8,
    suffix: []const u8,
    digest: [Sha256.digest_length]u8,
) ![]u8 {
    if (suffix.len == 0 or !std.mem.endsWith(u8, source_handle, suffix)) {
        return error.InvalidArtifactHandle;
    }
    const digest_hex = std.fmt.bytesToHex(digest[0..8].*, .lower);
    return std.fmt.allocPrint(
        alloc,
        "{s}-{s}{s}",
        .{
            source_handle[0 .. source_handle.len - suffix.len],
            &digest_hex,
            suffix,
        },
    );
}

pub fn hasContentDigest(
    handle: []const u8,
    suffix: []const u8,
) bool {
    if (suffix.len == 0 or !std.mem.endsWith(u8, handle, suffix)) {
        return false;
    }
    const stem = handle[0 .. handle.len - suffix.len];
    const separator = std.mem.lastIndexOfScalar(u8, stem, '-') orelse
        return false;
    const encoded = stem[separator + 1 ..];
    if (encoded.len != digest_hex_bytes) return false;
    for (encoded) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return false;
        }
    }
    return true;
}

pub fn handleMatchesContentDigest(
    handle: []const u8,
    suffix: []const u8,
    digest: [Sha256.digest_length]u8,
) bool {
    if (!hasContentDigest(handle, suffix)) return false;
    const stem = handle[0 .. handle.len - suffix.len];
    const separator = std.mem.lastIndexOfScalar(u8, stem, '-').?;
    const encoded = stem[separator + 1 ..];
    const expected = std.fmt.bytesToHex(digest[0..8].*, .lower);
    return std.mem.eql(u8, encoded, &expected);
}

test "content addressed artifact handles authenticate exact bytes" {
    const alloc = std.testing.allocator;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("saved output", &digest, .{});
    const handle = try contentAddressedHandle(
        alloc,
        "fx-command-123.log",
        ".log",
        digest,
    );
    defer alloc.free(handle);
    try std.testing.expectEqualStrings(
        "fx-command-123-1b2a9cb5a0298dcb.log",
        handle,
    );
    try std.testing.expect(handleMatchesContentDigest(
        handle,
        ".log",
        digest,
    ));
    Sha256.hash("xaved output", &digest, .{});
    try std.testing.expect(!handleMatchesContentDigest(
        handle,
        ".log",
        digest,
    ));
}
