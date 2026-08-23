//! AWS Signature Version 4 (header variant) reduced to what Bedrock Converse
//! signs: a fixed set of `host`, `x-amz-date`, `x-amz-content-sha256`, and an
//! optional `x-amz-security-token` header over an empty canonical query.
//! Canonical-request rules follow @smithy/signature-v4 (`SignatureV4Base.js`,
//! `credentialDerivation.js`); the tests below port vectors from the official
//! AWS `aws-sig-v4-test-suite` fixture embedded in `suite.fixture.js`.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
pub const Sha256 = std.crypto.hash.sha2.Sha256;

/// Bedrock signs under the plain `bedrock` service name, never the endpoint
/// subdomain `bedrock-runtime`.
pub const service_bedrock = "bedrock";
pub const algorithm = "AWS4-HMAC-SHA256";

pub const sha256_hex_len = Sha256.digest_length * 2;
pub const signature_hex_len = HmacSha256.mac_length * 2;
pub const long_date_len = 16;
pub const short_date_len = 8;
const max_secret_bytes = 256;

pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Everything required to produce an `Authorization` header for one request.
/// Header names must already be lowercase; values are trimmed and internal
/// whitespace runs collapsed during signing, matching getCanonicalHeaders.
pub const RequestToSign = struct {
    method: []const u8,
    /// Already percent-encoded per the canonical-path rules.
    canonical_path: []const u8,
    canonical_query: []const u8 = "",
    headers: []const Header,
    payload_hash_hex: []const u8,
};

pub fn hexLower(out: []u8, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    std.debug.assert(out.len == bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 0x0f];
    }
}

pub fn payloadHashHex(out: *[sha256_hex_len]u8, payload: []const u8) void {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    hexLower(out, &digest);
}

/// Renders an epoch-millisecond timestamp as `YYYYMMDDTHHMMSSZ`.
pub fn longDate(buf: *[long_date_len]u8, milli_timestamp: i64) error{ InvalidSigningTimestamp, NoSpaceLeft }![]const u8 {
    if (milli_timestamp < 0) return error.InvalidSigningTimestamp;
    const seconds = @divFloor(milli_timestamp, std.time.ms_per_s);
    const day_seconds = @mod(seconds, std.time.s_per_day);
    const days = @divFloor(seconds, std.time.s_per_day);
    const civil = civilFromDays(days);
    const hour = @divFloor(day_seconds, 3600);
    const minute = @divFloor(@mod(day_seconds, 3600), 60);
    const second = @mod(day_seconds, 60);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        @as(u64, @intCast(civil.year)),
        civil.month,
        civil.day,
        @as(u64, @intCast(hour)),
        @as(u64, @intCast(minute)),
        @as(u64, @intCast(second)),
    });
}

/// Howard Hinnant's civil-from-days algorithm; valid for the epoch range
/// SigV4 timestamps occupy.
fn civilFromDays(days: i64) struct { year: i64, month: u64, day: u64 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const year = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const day = doy - (153 * mp + 2) / 5 + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = if (month <= 2) year + 1 else year,
        .month = month,
        .day = day,
    };
}

/// `{date}/{region}/{service}/aws4_request` credential scope.
pub fn credentialScope(buf: []u8, short_date: []const u8, region: []const u8, service: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}/aws4_request", .{ short_date, region, service }) catch unreachable;
}

/// HMAC-SHA256 chain from the raw secret to the scoped signing key.
pub fn deriveSigningKey(
    out: *[HmacSha256.mac_length]u8,
    secret_access_key: []const u8,
    short_date: []const u8,
    region: []const u8,
    service: []const u8,
) error{SecretTooLong}!void {
    if (secret_access_key.len > max_secret_bytes) return error.SecretTooLong;
    var seed_buf: [4 + max_secret_bytes]u8 = undefined;
    const seed = std.fmt.bufPrint(&seed_buf, "AWS4{s}", .{secret_access_key}) catch unreachable;

    var k_date: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&k_date, short_date, seed);
    var k_region: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&k_region, region, &k_date);
    var k_service: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&k_service, service, &k_region);
    HmacSha256.create(out, "aws4_request", &k_service);
}

pub fn computeSignatureHex(
    out: *[signature_hex_len]u8,
    signing_key: *const [HmacSha256.mac_length]u8,
    string_to_sign: []const u8,
) void {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, string_to_sign, signing_key);
    hexLower(out, &mac);
}

fn normalizeHeaderValue(buf: []u8, value: []const u8) []const u8 {
    var written: usize = 0;
    var pending_space = false;
    var seen_content = false;
    for (value) |byte| {
        switch (byte) {
            ' ', '\t' => pending_space = seen_content,
            else => {
                if (pending_space and written > 0) {
                    buf[written] = ' ';
                    written += 1;
                }
                pending_space = false;
                buf[written] = byte;
                written += 1;
                seen_content = true;
            },
        }
    }
    return buf[0..written];
}

const NormalizedHeader = struct {
    name: []const u8,
    value: []const u8,
};

fn lessByName(_: void, a: NormalizedHeader, b: NormalizedHeader) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}
/// Lowercased, trimmed, and sorted `name1;name2;...` signed-headers list.
pub fn signedHeadersValue(alloc: Allocator, req: RequestToSign) ![]u8 {
    const normalized = try normalizeHeaders(alloc, req.headers);
    defer normalized.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (normalized.items, 0..) |header, index| {
        if (index > 0) try out.writer.writeByte(';');
        try out.writer.writeAll(header.name);
    }
    return out.toOwnedSlice();
}

const NormalizedHeaders = struct {
    items: []NormalizedHeader,
    /// Backing store for the lowered names and collapsed values; `items`
    /// slices into it, so it must be freed after `items`.
    storage: []u8,

    fn deinit(self: *const NormalizedHeaders, alloc: Allocator) void {
        alloc.free(self.items);
        alloc.free(self.storage);
    }
};

fn normalizeHeaders(alloc: Allocator, headers: []const Header) !NormalizedHeaders {
    const items = try alloc.alloc(NormalizedHeader, headers.len);
    errdefer alloc.free(items);
    const storage = try alloc.alloc(u8, headers.len * 320);
    errdefer alloc.free(storage);
    var used: usize = 0;
    for (headers, 0..) |header, index| {
        if (header.name.len + header.value.len > storage.len - used) return error.HeaderTooLongToSign;
        for (header.name, 0..) |byte, offset| {
            storage[used + offset] = std.ascii.toLower(byte);
        }
        const name = storage[used .. used + header.name.len];
        used += header.name.len;
        const value = normalizeHeaderValue(storage[used..], header.value);
        used += value.len;
        items[index] = .{ .name = name, .value = value };
    }
    std.mem.sort(NormalizedHeader, items, {}, lessByName);
    return .{ .items = items, .storage = storage };
}

pub fn canonicalRequest(alloc: Allocator, req: RequestToSign) ![]u8 {
    const normalized = try normalizeHeaders(alloc, req.headers);
    defer normalized.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll(req.method);
    try writer.writeByte('\n');
    try writer.writeAll(req.canonical_path);
    try writer.writeByte('\n');
    try writer.writeAll(req.canonical_query);
    try writer.writeByte('\n');
    for (normalized.items) |header| {
        try writer.writeAll(header.name);
        try writer.writeByte(':');
        try writer.writeAll(header.value);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
    for (normalized.items, 0..) |header, index| {
        if (index > 0) try writer.writeByte(';');
        try writer.writeAll(header.name);
    }
    try writer.writeByte('\n');
    try writer.writeAll(req.payload_hash_hex);
    return out.toOwnedSlice();
}

pub fn stringToSign(
    alloc: Allocator,
    long_date_value: []const u8,
    scope: []const u8,
    canonical: []const u8,
) ![]u8 {
    var canonical_hash: [sha256_hex_len]u8 = undefined;
    payloadHashHex(&canonical_hash, canonical);
    return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}", .{
        algorithm,
        long_date_value,
        scope,
        canonical_hash,
    });
}

/// Full `Authorization` header value for one request.
pub fn authorizationHeader(
    alloc: Allocator,
    credentials: Credentials,
    long_date_value: []const u8,
    region: []const u8,
    service: []const u8,
    req: RequestToSign,
) ![]u8 {
    if (long_date_value.len != long_date_len) return error.InvalidSigningTimestamp;
    const canonical = try canonicalRequest(alloc, req);
    defer alloc.free(canonical);

    var scope_buf: [short_date_len + 1 + 64 + 1 + 32 + 1 + 16]u8 = undefined;
    const scope = credentialScope(&scope_buf, long_date_value[0..short_date_len], region, service);
    const sts = try stringToSign(alloc, long_date_value, scope, canonical);
    defer alloc.free(sts);

    var signing_key: [HmacSha256.mac_length]u8 = undefined;
    try deriveSigningKey(&signing_key, credentials.secret_access_key, long_date_value[0..short_date_len], region, service);
    var signature: [signature_hex_len]u8 = undefined;
    computeSignatureHex(&signature, &signing_key, sts);

    const signed_headers = try signedHeadersValue(alloc, req);
    defer alloc.free(signed_headers);

    return std.fmt.allocPrint(alloc, "{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{
        algorithm,
        credentials.access_key_id,
        scope,
        signed_headers,
        signature,
    });
}

/// Percent-encodes one URI path byte per the canonical escaping rule: only
/// RFC 3986 unreserved characters survive, hexadecimal digits are uppercase.
pub fn byteNeedsEscape(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => false,
        else => true,
    };
}

/// Encodes a single path segment (slashes are NOT preserved).
pub fn escapeUriSegment(alloc: Allocator, segment: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (segment) |byte| {
        if (!byteNeedsEscape(byte)) {
            try out.append(alloc, byte);
        } else {
            try out.append(alloc, '%');
            const digits = "0123456789ABCDEF";
            try out.append(alloc, digits[byte >> 4]);
            try out.append(alloc, digits[byte & 0x0f]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Encodes a model identifier for the `/model/{modelId}/...` httpLabel:
/// every reserved byte becomes `%XX` uppercase while the literal `/`
/// characters inside ARN-style ids stay in the path (smithy restores `%2F`).
pub fn escapeModelIdPath(alloc: Allocator, model_id: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (model_id) |byte| {
        if (!byteNeedsEscape(byte) or byte == '/') {
            try out.append(alloc, byte);
        } else {
            try out.append(alloc, '%');
            const digits = "0123456789ABCDEF";
            try out.append(alloc, digits[byte >> 4]);
            try out.append(alloc, digits[byte & 0x0f]);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "payload hash matches documented empty-body digest" {
    var hash: [sha256_hex_len]u8 = undefined;
    payloadHashHex(&hash, "");
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &hash,
    );
}

test "long date renders UTC compact form" {
    var buf: [long_date_len]u8 = undefined;
    try std.testing.expectEqualStrings("20150830T123600Z", try longDate(&buf, 1440938160000));
    try std.testing.expectEqualStrings("20260101T000000Z", try longDate(&buf, 1767225600000));
    try std.testing.expectEqualStrings("19700101T000000Z", try longDate(&buf, 0));
    try std.testing.expectError(error.InvalidSigningTimestamp, longDate(&buf, -1));
}

test "signing key chain is deterministic for the fixture credentials" {
    var key_a: [HmacSha256.mac_length]u8 = undefined;
    var key_b: [HmacSha256.mac_length]u8 = undefined;
    try deriveSigningKey(&key_a, "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", service_bedrock);
    try deriveSigningKey(&key_b, "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", service_bedrock);
    try std.testing.expectEqualSlices(u8, &key_a, &key_b);
    var other: [HmacSha256.mac_length]u8 = undefined;
    try deriveSigningKey(&other, "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam");
    try std.testing.expect(!std.mem.eql(u8, &key_a, &other));
}

const FixtureVector = struct {
    name: []const u8,
    headers: []const Header,
    path: []const u8,
    authorization: []const u8,
};

// Ported verbatim from @smithy/signature-v4 suite.fixture.js (official AWS
// aws-sig-v4-test-suite): shared credentials, signing date, and scope.
const vector_credentials = Credentials{
    .access_key_id = "AKIDEXAMPLE",
    .secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
};

fn runFixtureVector(vector: FixtureVector) !void {
    const alloc = std.testing.allocator;
    var hash: [sha256_hex_len]u8 = undefined;
    payloadHashHex(&hash, "");
    var date_buf: [long_date_len]u8 = undefined;
    const date = try longDate(&date_buf, 1440938160000);
    const authorization = try authorizationHeader(
        alloc,
        vector_credentials,
        date,
        "us-east-1",
        "service",
        .{
            .method = "GET",
            .canonical_path = vector.path,
            .headers = vector.headers,
            .payload_hash_hex = &hash,
        },
    );
    defer alloc.free(authorization);
    try std.testing.expectEqualStrings(vector.authorization, authorization);
}

test "sigv4 fixture vectors match official aws-sig-v4-test-suite signatures" {
    try runFixtureVector(.{
        .name = "get-vanilla",
        .headers = &.{
            .{ .name = "host", .value = "example.amazonaws.com" },
            .{ .name = "x-amz-date", .value = "20150830T123600Z" },
        },
        .path = "/",
        .authorization = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
    });
    try runFixtureVector(.{
        .name = "get-header-key-duplicate",
        .headers = &.{
            .{ .name = "host", .value = "example.amazonaws.com" },
            .{ .name = "my-header1", .value = "value2,value2,value1" },
            .{ .name = "x-amz-date", .value = "20150830T123600Z" },
        },
        .path = "/",
        .authorization = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;my-header1;x-amz-date, Signature=c9d5ea9f3f72853aea855b47ea873832890dbdd183b4468f858259531a5138ea",
    });
    try runFixtureVector(.{
        .name = "get-header-value-trim",
        .headers = &.{
            .{ .name = "host", .value = "example.amazonaws.com" },
            .{ .name = "my-header1", .value = "value1" },
            .{ .name = "my-header2", .value = "\"a   b   c\"" },
            .{ .name = "x-amz-date", .value = "20150830T123600Z" },
        },
        .path = "/",
        .authorization = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;my-header1;my-header2;x-amz-date, Signature=acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736",
    });
    try runFixtureVector(.{
        .name = "get-unreserved",
        .headers = &.{
            .{ .name = "host", .value = "example.amazonaws.com" },
            .{ .name = "x-amz-date", .value = "20150830T123600Z" },
        },
        .path = "/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
        .authorization = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f",
    });
    try runFixtureVector(.{
        .name = "get-utf8",
        .headers = &.{
            .{ .name = "host", .value = "example.amazonaws.com" },
            .{ .name = "x-amz-date", .value = "20150830T123600Z" },
        },
        .path = "/%E1%88%B4",
        .authorization = "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85",
    });
}

test "session token joins the signed header set" {
    const alloc = std.testing.allocator;
    var hash: [sha256_hex_len]u8 = undefined;
    payloadHashHex(&hash, "{}");
    var date_buf: [long_date_len]u8 = undefined;
    const date = try longDate(&date_buf, 1440938160000);
    const base = RequestToSign{
        .method = "POST",
        .canonical_path = "/model/us.anthropic.claude-opus-4-6-v1/converse-stream",
        .headers = &.{
            .{ .name = "host", .value = "bedrock-runtime.us-east-1.amazonaws.com" },
            .{ .name = "x-amz-content-sha256", .value = &hash },
            .{ .name = "x-amz-date", .value = date },
        },
        .payload_hash_hex = &hash,
    };
    const unsigned = try authorizationHeader(
        alloc,
        .{ .access_key_id = "AKID", .secret_access_key = "secret" },
        date,
        "us-east-1",
        service_bedrock,
        base,
    );
    defer alloc.free(unsigned);
    var headers_with_token: std.ArrayList(Header) = .empty;
    defer headers_with_token.deinit(alloc);
    try headers_with_token.appendSlice(alloc, base.headers);
    try headers_with_token.append(alloc, .{ .name = "x-amz-security-token", .value = "tok" });
    const signed_with_token = try authorizationHeader(
        alloc,
        .{ .access_key_id = "AKID", .secret_access_key = "secret", .session_token = "tok" },
        date,
        "us-east-1",
        service_bedrock,
        .{
            .method = base.method,
            .canonical_path = base.canonical_path,
            .headers = headers_with_token.items,
            .payload_hash_hex = base.payload_hash_hex,
        },
    );
    defer alloc.free(signed_with_token);
    try std.testing.expect(std.mem.indexOf(u8, unsigned, "SignedHeaders=host;x-amz-content-sha256;x-amz-date,") != null);
    try std.testing.expect(std.mem.indexOf(u8, signed_with_token, "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token,") != null);
    try std.testing.expect(!std.mem.eql(u8, unsigned, signed_with_token));
}

test "model id path keeps arn slashes and escapes colons" {
    const alloc = std.testing.allocator;
    const simple = try escapeModelIdPath(alloc, "us.anthropic.claude-opus-4-6-v1");
    defer alloc.free(simple);
    try std.testing.expectEqualStrings("us.anthropic.claude-opus-4-6-v1", simple);
    const arn = try escapeModelIdPath(alloc, "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/abc123");
    defer alloc.free(arn);
    try std.testing.expectEqualStrings(
        "arn%3Aaws%3Abedrock%3Aus-east-1%3A123456789012%3Aapplication-inference-profile/abc123",
        arn,
    );
}
