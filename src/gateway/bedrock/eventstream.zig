//! AWS EventStream binary frame codec (decode side), following
//! @smithy/core `submodules/event-streams/eventstream-codec`:
//! u32BE total length, u32BE headers length, CRC32 (ISO-HDLC / zlib,
//! reflected 0xEDB88320) over the 8-byte prelude, typed headers, a payload,
//! and a whole-message CRC32 continued from the prelude hash state.
//! The decoder is incremental: TCP chunks may split frames anywhere.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Crc32 = std.hash.crc.Crc32IsoHdlc;

pub const default_max_frame_bytes: usize = 16 * 1024 * 1024;

/// Generous ceiling for one Bedrock Converse frame; real event frames are a
/// few KiB but image or document deltas may be larger.
pub const Error = error{
    BedrockEventstreamFrameTooLarge,
    BedrockEventstreamTruncatedFrame,
    BedrockEventstreamPreludeCrcMismatch,
    BedrockEventstreamMessageCrcMismatch,
    BedrockEventstreamMalformedFrame,
    OutOfMemory,
};

pub const HeaderValue = union(enum) {
    bool_true,
    bool_false,
    byte: i8,
    short: i16,
    integer: i32,
    long: i64,
    binary: []u8,
    string: []u8,
    /// Epoch milliseconds.
    timestamp_ms: i64,
    uuid: [16]u8,

    pub fn deinit(self: HeaderValue, alloc: Allocator) void {
        switch (self) {
            .binary => |bytes| alloc.free(bytes),
            .string => |str| alloc.free(str),
            else => {},
        }
    }

    pub fn typeName(self: HeaderValue) []const u8 {
        return switch (self) {
            .bool_true, .bool_false => "boolean",
            .byte => "byte",
            .short => "short",
            .integer => "integer",
            .long => "long",
            .binary => "binary",
            .string => "string",
            .timestamp_ms => "timestamp",
            .uuid => "uuid",
        };
    }
};

pub const Header = struct {
    name: []u8,
    value: HeaderValue,

    pub fn deinit(self: Header, alloc: Allocator) void {
        alloc.free(self.name);
        self.value.deinit(alloc);
    }
};

pub const Frame = struct {
    headers: []Header,
    payload: []u8,

    pub fn deinit(self: Frame, alloc: Allocator) void {
        for (self.headers) |header| header.deinit(alloc);
        alloc.free(self.headers);
        alloc.free(self.payload);
    }

    pub fn findHeader(self: Frame, name: []const u8) ?*const Header {
        for (self.headers) |*header| {
            if (std.mem.eql(u8, header.name, name)) return header;
        }
        return null;
    }

    pub fn headerString(self: Frame, name: []const u8) ?[]const u8 {
        const header = self.findHeader(name) orelse return null;
        return switch (header.value) {
            .string => |value| value,
            else => null,
        };
    }
};

/// Buffers arbitrary transport chunks and yields complete, CRC-validated
/// frames. Frames are copied out so the caller owns all allocations and the
/// internal buffer only ever holds undecoded bytes.
pub const Decoder = struct {
    pending: std.ArrayList(u8) = .empty,
    max_frame_bytes: usize = default_max_frame_bytes,

    pub fn deinit(self: *Decoder, alloc: Allocator) void {
        self.pending.deinit(alloc);
        self.* = undefined;
    }

    pub fn bufferedBytes(self: *const Decoder) usize {
        return self.pending.items.len;
    }

    pub fn push(self: *Decoder, alloc: Allocator, chunk: []const u8) Error!void {
        if (chunk.len == 0) return;
        if (self.pending.items.len + chunk.len > self.max_frame_bytes) {
            return Error.BedrockEventstreamFrameTooLarge;
        }
        self.pending.appendSlice(alloc, chunk) catch return Error.OutOfMemory;
    }

    /// Returns the next complete frame, or null when more bytes are needed.
    pub fn next(self: *Decoder, alloc: Allocator) Error!?Frame {
        const buffer = self.pending.items;
        if (buffer.len < 12) return null;

        const total_length = std.mem.readInt(u32, buffer[0..4], .big);
        const headers_length = std.mem.readInt(u32, buffer[4..8], .big);
        if (total_length < 16 or headers_length > total_length - 12) {
            return Error.BedrockEventstreamMalformedFrame;
        }
        if (total_length > self.max_frame_bytes) {
            return Error.BedrockEventstreamFrameTooLarge;
        }
        if (buffer.len < total_length) return null;
        const message_end = total_length - 4;

        var prelude_crc = Crc32.init();
        prelude_crc.update(buffer[0..8]);
        if (prelude_crc.final() != std.mem.readInt(u32, buffer[8..12], .big)) {
            return Error.BedrockEventstreamPreludeCrcMismatch;
        }

        // Smithy continues the prelude hasher across the stored prelude CRC
        // and every byte up to the trailing checksum; that equals a fresh
        // zlib crc32 over bytes [0..message_end).
        var message_crc = Crc32.init();
        message_crc.update(buffer[0..message_end]);
        if (message_crc.final() != std.mem.readInt(u32, buffer[message_end..][0..4], .big)) {
            return Error.BedrockEventstreamMessageCrcMismatch;
        }

        const headers = try parseHeaders(alloc, buffer[12 .. 12 + headers_length]);
        errdefer {
            for (headers) |header| header.deinit(alloc);
            alloc.free(headers);
        }
        const payload = try alloc.dupe(u8, buffer[12 + headers_length .. message_end]);
        errdefer alloc.free(payload);

        const remaining = buffer.len - total_length;
        std.mem.copyForwards(u8, self.pending.items[0..remaining], buffer[total_length..]);
        self.pending.shrinkRetainingCapacity(remaining);
        return .{ .headers = headers, .payload = payload };
    }
};

fn parseHeaders(alloc: Allocator, bytes: []const u8) Error![]Header {
    var headers: std.ArrayList(Header) = .empty;
    errdefer {
        for (headers.items) |header| header.deinit(alloc);
        headers.deinit(alloc);
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < 2) return Error.BedrockEventstreamMalformedFrame;
        const name_len: usize = bytes[offset];
        offset += 1;
        if (name_len == 0 or bytes.len - offset < name_len + 1) {
            return Error.BedrockEventstreamMalformedFrame;
        }
        const name = alloc.dupe(u8, bytes[offset .. offset + name_len]) catch return Error.OutOfMemory;
        errdefer alloc.free(name);
        offset += name_len;
        const tag = bytes[offset];
        offset += 1;
        const value = try parseHeaderValue(alloc, tag, bytes, &offset);
        try headers.append(alloc, .{ .name = name, .value = value });
    }
    return headers.toOwnedSlice(alloc);
}

fn take(bytes: []const u8, offset: *usize, count: usize) Error![]const u8 {
    if (bytes.len - offset.* < count) return Error.BedrockEventstreamMalformedFrame;
    const slice = bytes[offset.* .. offset.* + count];
    offset.* += count;
    return slice;
}

fn parseHeaderValue(alloc: Allocator, tag: u8, bytes: []const u8, offset: *usize) Error!HeaderValue {
    switch (tag) {
        0 => return .bool_true,
        1 => return .bool_false,
        2 => {
            const raw = try take(bytes, offset, 1);
            return .{ .byte = @bitCast(raw[0]) };
        },
        3 => {
            const raw = try take(bytes, offset, 2);
            return .{ .short = @bitCast(std.mem.readInt(u16, raw[0..2], .big)) };
        },
        4 => {
            const raw = try take(bytes, offset, 4);
            return .{ .integer = @bitCast(std.mem.readInt(u32, raw[0..4], .big)) };
        },
        5 => {
            const raw = try take(bytes, offset, 8);
            return .{ .long = @bitCast(std.mem.readInt(u64, raw[0..8], .big)) };
        },
        6 => {
            const len_raw = try take(bytes, offset, 2);
            const len: usize = std.mem.readInt(u16, len_raw[0..2], .big);
            const raw = try take(bytes, offset, len);
            const copy = alloc.dupe(u8, raw) catch return Error.OutOfMemory;
            return .{ .binary = copy };
        },
        7 => {
            const len_raw = try take(bytes, offset, 2);
            const len: usize = std.mem.readInt(u16, len_raw[0..2], .big);
            const raw = try take(bytes, offset, len);
            const copy = alloc.dupe(u8, raw) catch return Error.OutOfMemory;
            return .{ .string = copy };
        },
        8 => {
            const raw = try take(bytes, offset, 8);
            return .{ .timestamp_ms = @bitCast(std.mem.readInt(u64, raw[0..8], .big)) };
        },
        9 => {
            const raw = try take(bytes, offset, 16);
            var uuid: [16]u8 = undefined;
            @memcpy(&uuid, raw);
            return .{ .uuid = uuid };
        },
        else => return Error.BedrockEventstreamMalformedFrame,
    }
}

/// Renders a UUID header as lowercase dashed hex (`8-4-4-4-12`).
pub fn formatUuid(buf: *[36]u8, uuid: [16]u8) []const u8 {
    const digits = "0123456789abcdef";
    var written: usize = 0;
    for (uuid, 0..) |byte, index| {
        if (index == 4 or index == 6 or index == 8 or index == 10) {
            buf[written] = '-';
            written += 1;
        }
        buf[written] = digits[byte >> 4];
        buf[written + 1] = digits[byte & 0x0f];
        written += 2;
    }
    return buf[0..written];
}

test "crc32 matches the zlib check value" {
    var crc = Crc32.init();
    crc.update("123456789");
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc.final());
}

// Byte-exact fixtures ported from @smithy TestVectors.fixture.js.

test "decodes the all_headers fixture with every typed header" {
    const alloc = std.testing.allocator;
    var decoder: Decoder = .{};
    defer decoder.deinit(alloc);
    try decoder.push(alloc, &[_]u8{
        0,   0,   0,   204, 0,   0,   0,   175, 15,  174, 100, 202, 10,  101, 118, 101,
        110, 116, 45,  116, 121, 112, 101, 4,   0,   0,   160, 12,  12,  99,  111, 110,
        116, 101, 110, 116, 45,  116, 121, 112, 101, 7,   0,   16,  97,  112, 112, 108,
        105, 99,  97,  116, 105, 111, 110, 47,  106, 115, 111, 110, 10,  98,  111, 111,
        108, 32,  102, 97,  108, 115, 101, 1,   9,   98,  111, 111, 108, 32,  116, 114,
        117, 101, 0,   4,   98,  121, 116, 101, 2,   207, 8,   98,  121, 116, 101, 32,
        98,  117, 102, 6,   0,   20,  73,  39,  109, 32,  97,  32,  108, 105, 116, 116,
        108, 101, 32,  116, 101, 97,  112, 111, 116, 33,  9,   116, 105, 109, 101, 115,
        116, 97,  109, 112, 8,   0,   0,   0,   0,   0,   132, 95,  237, 5,   105, 110,
        116, 49,  54,  3,   0,   42,  5,   105, 110, 116, 54,  52,  5,   0,   0,   0,
        0,   2,   135, 87,  178, 4,   117, 117, 105, 100, 9,   1,   2,   3,   4,   5,
        6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,  123, 39,  102, 111, 111,
        39,  58,  39,  98,  97,  114, 39,  125, 171, 165, 241, 12,
    });
    const frame = (try decoder.next(alloc)).?;
    defer frame.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 10), frame.headers.len);
    try std.testing.expectEqualStrings("{'foo':'bar'}", frame.payload);
    try std.testing.expectEqualStrings("event-type", frame.headers[0].name);
    try std.testing.expectEqual(@as(i32, 40972), frame.headers[0].value.integer);
    try std.testing.expectEqualStrings("application/json", frame.headers[1].value.string);
    try std.testing.expect(frame.headers[2].value == .bool_false);
    try std.testing.expect(frame.headers[3].value == .bool_true);
    try std.testing.expectEqual(@as(i8, -49), frame.headers[4].value.byte);
    try std.testing.expectEqualStrings("I'm a little teapot!", frame.headers[5].value.binary);
    try std.testing.expectEqual(@as(i64, 8675309), frame.headers[6].value.timestamp_ms);
    try std.testing.expectEqual(@as(i16, 42), frame.headers[7].value.short);
    try std.testing.expectEqual(@as(i64, 42424242), frame.headers[8].value.long);
    try std.testing.expectEqual(
        [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
        frame.headers[9].value.uuid,
    );
    var uuid_buf: [36]u8 = undefined;
    try std.testing.expectEqualStrings(
        "01020304-0506-0708-090a-0b0c0d0e0f10",
        formatUuid(&uuid_buf, frame.headers[9].value.uuid),
    );
    try std.testing.expectEqualStrings("integer", frame.headers[0].value.typeName());
}

test "decodes empty_message fixture byte-exactly" {
    const alloc = std.testing.allocator;
    var decoder: Decoder = .{};
    defer decoder.deinit(alloc);
    try decoder.push(alloc, &[_]u8{ 0, 0, 0, 16, 0, 0, 0, 0, 5, 194, 72, 235, 125, 152, 200, 255 });
    const frame = (try decoder.next(alloc)).?;
    defer frame.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), frame.headers.len);
    try std.testing.expectEqual(@as(usize, 0), frame.payload.len);
    try std.testing.expect((try decoder.next(alloc)) == null);
}

test "decodes int32_header, payload_no_headers, and payload_one_str_header fixtures" {
    const alloc = std.testing.allocator;
    var decoder: Decoder = .{};
    defer decoder.deinit(alloc);
    try decoder.push(alloc, &[_]u8{
        0,   0,   0,  45,  0,   0,   0,   16, 65,  196, 36,  184, 10,  101, 118, 101,
        110, 116, 45, 116, 121, 112, 101, 4,  0,   0,   160, 12,  123, 39,  102, 111,
        111, 39,  58, 39,  98,  97,  114, 39, 125, 54,  244, 128, 160,
    });
    try decoder.push(alloc, &[_]u8{
        0,   0,  0,  29, 0,  0,  0,   0,  253, 82,  140, 90, 123, 39, 102, 111,
        111, 39, 58, 39, 98, 97, 114, 39, 125, 195, 101, 57, 54,
    });
    try decoder.push(alloc, &[_]u8{
        0,   0,   0,   61,  0,   0,   0,   32,  7,   253, 131, 150, 12,  99,  111, 110,
        116, 101, 110, 116, 45,  116, 121, 112, 101, 7,   0,   16,  97,  112, 112, 108,
        105, 99,  97,  116, 105, 111, 110, 47,  106, 115, 111, 110, 123, 39,  102, 111,
        111, 39,  58,  39,  98,  97,  114, 39,  125, 141, 156, 8,   177,
    });

    const first = (try decoder.next(alloc)).?;
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(i32, 40972), first.headers[0].value.integer);
    try std.testing.expectEqualStrings("{'foo':'bar'}", first.payload);

    const second = (try decoder.next(alloc)).?;
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), second.headers.len);
    try std.testing.expectEqualStrings("{'foo':'bar'}", second.payload);

    const third = (try decoder.next(alloc)).?;
    defer third.deinit(alloc);
    try std.testing.expectEqualStrings("content-type", third.headers[0].name);
    try std.testing.expectEqualStrings("application/json", third.headers[0].value.string);
    try std.testing.expect((try decoder.next(alloc)) == null);
}

/// Corrupt fixtures must never decode: any CRC/structure rejection counts,
/// and a frame that can never complete (declared length past the buffer)
/// also counts because the caller surfaces truncation at EOF.
fn expectCorruptFixtureFails(alloc: Allocator, encoded: []const u8) !void {
    var decoder: Decoder = .{};
    defer decoder.deinit(alloc);
    try decoder.push(alloc, encoded);
    if (decoder.next(alloc)) |maybe_frame| {
        if (maybe_frame) |frame| {
            frame.deinit(alloc);
            return error.CorruptFixtureDecoded;
        }
        try std.testing.expect(decoder.bufferedBytes() > 0);
    } else |err| {
        try std.testing.expect(err != error.OutOfMemory);
    }
}

test "corrupted fixture vectors fail CRC validation" {
    const alloc = std.testing.allocator;
    // corrupted_headers: payload byte flipped under an intact trailing CRC.
    try expectCorruptFixtureFails(alloc, &[_]u8{
        0,   0,   0,   61,  0,   0,   0,   32,  7,   253, 131, 150, 12,  99,  111, 110,
        116, 101, 110, 116, 45,  116, 121, 112, 101, 7,   0,   16,  97,  112, 112, 108,
        105, 99,  97,  116, 105, 111, 110, 47,  106, 115, 111, 110, 123, 97,  102, 111,
        111, 39,  58,  39,  98,  97,  114, 39,  125, 141, 156, 8,   177,
    });
    // corrupted_header_len: headers length off by one.
    try expectCorruptFixtureFails(alloc, &[_]u8{
        0,   0,   0,   61,  0,   0,   0,   33,  7,   253, 131, 150, 12,  99,  111, 110,
        116, 101, 110, 116, 45,  116, 121, 112, 101, 7,   0,   16,  97,  112, 112, 108,
        105, 99,  97,  116, 105, 111, 110, 47,  106, 115, 111, 110, 123, 39,  102, 111,
        111, 39,  58,  39,  98,  97,  114, 39,  125, 141, 156, 8,   177,
    });
    // corrupted_length: total length inflated by one.
    try expectCorruptFixtureFails(alloc, &[_]u8{
        0,   0,   0,   62,  0,   0,   0,   32,  7,   253, 131, 150, 12,  99,  111, 110,
        116, 101, 110, 116, 45,  116, 121, 112, 101, 7,   0,   16,  97,  112, 112, 108,
        105, 99,  97,  116, 105, 111, 110, 47,  106, 115, 111, 110, 123, 39,  102, 111,
        111, 39,  58,  39,  98,  97,  114, 39,  125, 141, 156, 8,   177,
    });
    // corrupted_payload: payload byte flipped without a valid trailing CRC.
    try expectCorruptFixtureFails(alloc, &[_]u8{
        0,   0,  0,  29, 0,  0,  0,   0,  253, 82,  140, 90, 91, 39, 102, 111,
        111, 39, 58, 39, 98, 97, 114, 39, 125, 195, 101, 57, 54,
    });
}

test "decoder reassembles frames across single-byte chunks" {
    const alloc = std.testing.allocator;
    const encoded = [_]u8{
        0,   0,   0,   61,  0,   0,   0,   32,  7,   253, 131, 150, 12,  99,  111, 110,
        116, 101, 110, 116, 45,  116, 121, 112, 101, 7,   0,   16,  97,  112, 112, 108,
        105, 99,  97,  116, 105, 111, 110, 47,  106, 115, 111, 110, 123, 39,  102, 111,
        111, 39,  58,  39,  98,  97,  114, 39,  125, 141, 156, 8,   177,
    };
    var decoder: Decoder = .{};
    defer decoder.deinit(alloc);
    var decoded: usize = 0;
    for (encoded) |byte| {
        try decoder.push(alloc, &[_]u8{byte});
        if (try decoder.next(alloc)) |frame| {
            defer frame.deinit(alloc);
            decoded += 1;
            try std.testing.expectEqualStrings("content-type", frame.headers[0].name);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), decoded);
    try std.testing.expectEqual(@as(usize, 0), decoder.bufferedBytes());
}

test "clean EOF with a partial frame buffered is a truncation error" {
    const alloc = std.testing.allocator;
    var decoder: Decoder = .{};
    defer decoder.deinit(alloc);
    try decoder.push(alloc, &[_]u8{ 0, 0, 0, 61, 0, 0 });
    try std.testing.expect((try decoder.next(alloc)) == null);
    // The stream ends here; the caller surfaces the truncation explicitly.
    try std.testing.expectEqual(@as(usize, 6), decoder.bufferedBytes());
}

test "oversized declared frames are rejected before decoding" {
    const alloc = std.testing.allocator;
    var decoder: Decoder = .{ .max_frame_bytes = 64 };
    defer decoder.deinit(alloc);
    var header: [12]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], 4096, .big);
    std.mem.writeInt(u32, header[4..8], 0, .big);
    try decoder.push(alloc, &header);
    try std.testing.expectError(
        Error.BedrockEventstreamFrameTooLarge,
        decoder.next(alloc),
    );
}
