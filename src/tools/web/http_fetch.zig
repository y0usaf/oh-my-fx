const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");
const url_policy = @import("url_policy.zig");

const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;
const posix = std.posix;

pub const max_body_bytes: usize = 10 * 1024 * 1024;
const max_redirect_hops: usize = 10;
const default_hop_timeout_ms: i64 = 60 * 1000;
const max_header_bytes: usize = 64 * 1024;
const plain_transport_buffer_len: usize = 4096;
const tls_transport_buffer_len: usize = std.crypto.tls.Client.min_buffer_len;
const tls_allow_truncation_attacks = false;

const FailureStage = enum {
    connect,
    tls_handshake,
    request_write,
    response_head,
    response_body,
};

const BodyFraming = union(enum) {
    no_body,
    content_length: usize,
    chunked,
    close_delimited,
};

var default_resolver_ctx: u8 = 0;
var default_connector_ctx: u8 = 0;

pub const Deadline = struct {
    deadline_ms: i64,
};

pub const FetchOptions = struct {
    max_body_bytes: usize = max_body_bytes,
    deadline: ?Deadline = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const Resolver = struct {
    ctx: *anyopaque,
    resolve: *const fn (*anyopaque, Allocator, []const u8, u16, FetchOptions) anyerror![]IpAddress,
};

pub const Connector = struct {
    ctx: *anyopaque,
    get: *const fn (*anyopaque, Allocator, PinnedTarget, FetchOptions) anyerror!ConnectorResponse,
};

pub const Transport = struct {
    resolver: Resolver,
    connector: Connector,
};

pub fn defaultTransport() Transport {
    return .{
        .resolver = .{ .ctx = @ptrCast(&default_resolver_ctx), .resolve = resolveDefault },
        .connector = .{ .ctx = @ptrCast(&default_connector_ctx), .get = connectDefault },
    };
}

pub const PinnedTarget = struct {
    url: url_policy.ValidatedUrl,
    admitted_addresses: []const IpAddress,
    tls_server_name: []const u8,
    host_header: []const u8,
};

pub const ConnectorResponse = struct {
    status: std.http.Status,
    body: []u8,
    location: ?[]u8 = null,
    content_encoding: ?[]u8 = null,
    content_encoding_count: usize = 0,
    content_type: ?[]u8 = null,

    pub fn deinit(self: *ConnectorResponse, alloc: Allocator) void {
        alloc.free(self.body);
        if (self.location) |location| alloc.free(location);
        if (self.content_encoding) |encoding| alloc.free(encoding);
        if (self.content_type) |mime| alloc.free(mime);
        self.* = .{ .status = .ok, .body = &.{} };
    }
};

pub const Success = struct {
    final_url: []u8,
    status: std.http.Status,
    body: []u8,
    content_type: ?[]u8 = null,

    fn deinit(self: *Success, alloc: Allocator) void {
        alloc.free(self.final_url);
        alloc.free(self.body);
        if (self.content_type) |mime| alloc.free(mime);
        self.* = .{ .final_url = &.{}, .status = .ok, .body = &.{} };
    }
};

pub const FailureKind = enum {
    non_success_status,
    unexpected_content_encoding,
};

pub const Failure = struct {
    kind: FailureKind,
    status: ?std.http.Status = null,
    body: []u8 = &.{},
    content_encoding: ?[]u8 = null,

    fn deinit(self: *Failure, alloc: Allocator) void {
        alloc.free(self.body);
        if (self.content_encoding) |encoding| alloc.free(encoding);
        self.* = .{ .kind = .non_success_status };
    }
};

pub const Result = union(enum) {
    success: Success,
    failure: Failure,
    cross_host_redirect: []u8,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        switch (self.*) {
            .success => |*success| success.deinit(alloc),
            .failure => |*failure| failure.deinit(alloc),
            .cross_host_redirect => |url| alloc.free(url),
        }
        self.* = .{ .failure = .{ .kind = .non_success_status } };
    }
};

pub fn fetch(alloc: Allocator, initial: url_policy.ValidatedUrl, options: FetchOptions, transport: Transport) anyerror!Result {
    var current = try cloneUrl(alloc, initial);
    defer current.deinit(alloc);

    var hop: usize = 0;
    while (hop <= max_redirect_hops) : (hop += 1) {
        const hop_options = hopOptions(options);
        const addresses = try resolveAddresses(alloc, current, hop_options, transport.resolver);
        defer alloc.free(addresses);

        if (addresses.len == 0) return error.NoAddressReturned;
        for (addresses) |address| {
            if (!url_policy.isPublicAddress(address)) return error.NonPublicDnsAnswer;
        }

        const host_header = try hostHeader(alloc, current);
        defer alloc.free(host_header);

        const pinned: PinnedTarget = .{
            .url = current,
            .admitted_addresses = addresses,
            .tls_server_name = current.canonical_host,
            .host_header = host_header,
        };

        var response = try transport.connector.get(transport.connector.ctx, alloc, pinned, hop_options);
        defer response.deinit(alloc);

        if (isRedirectStatus(response.status)) {
            const location = response.location orelse return error.MissingRedirectLocation;
            var redirect = try url_policy.redirectTarget(alloc, current, location);
            defer redirect.deinit(alloc);

            switch (redirect.kind) {
                .follow => {
                    current.deinit(alloc);
                    current = try cloneUrl(alloc, redirect.target.?);
                    continue;
                },
                .cross_host => {
                    return .{ .cross_host_redirect = try alloc.dupe(u8, redirect.cross_host_url.?) };
                },
            }
        }

        if (response.content_encoding_count > 1)
            return unexpectedContentEncoding(alloc, response.status, response.content_encoding orelse "multiple Content-Encoding fields");

        const content_encoding = if (response.content_encoding) |encoding|
            parseContentEncoding(encoding) orelse
                return unexpectedContentEncoding(alloc, response.status, encoding)
        else
            std.http.ContentEncoding.identity;

        if (content_encoding != .identity) {
            if (response.status.class() != .success)
                return unexpectedContentEncoding(alloc, response.status, response.content_encoding.?);

            const decoded_body = decodeContentEncoding(alloc, content_encoding, response.body, options.max_body_bytes) catch |err| switch (err) {
                error.OutOfMemory, error.BodyTooLarge => return err,
                else => return unexpectedContentEncoding(alloc, response.status, response.content_encoding.?),
            };
            errdefer alloc.free(decoded_body);
            const final_url = try alloc.dupe(u8, current.retrieval_url);
            errdefer alloc.free(final_url);
            const content_type = if (response.content_type) |mime| try alloc.dupe(u8, mime) else null;
            errdefer if (content_type) |mime| alloc.free(mime);
            return .{ .success = .{
                .final_url = final_url,
                .status = response.status,
                .body = decoded_body,
                .content_type = content_type,
            } };
        }

        if (response.status.class() != .success) {
            return .{ .failure = .{
                .kind = .non_success_status,
                .status = response.status,
                .body = try alloc.dupe(u8, response.body),
            } };
        }

        return .{ .success = .{
            .final_url = try alloc.dupe(u8, current.retrieval_url),
            .status = response.status,
            .body = try alloc.dupe(u8, response.body),
            .content_type = if (response.content_type) |mime| try alloc.dupe(u8, mime) else null,
        } };
    }

    return error.RedirectLimitExceeded;
}

fn unexpectedContentEncoding(alloc: Allocator, status: std.http.Status, encoding: []const u8) !Result {
    return .{ .failure = .{
        .kind = .unexpected_content_encoding,
        .status = status,
        .content_encoding = try alloc.dupe(u8, encoding),
    } };
}

fn parseContentEncoding(encoding: []const u8) ?std.http.ContentEncoding {
    if (std.ascii.eqlIgnoreCase(encoding, "identity")) return .identity;
    if (std.ascii.eqlIgnoreCase(encoding, "gzip")) return .gzip;
    if (std.ascii.eqlIgnoreCase(encoding, "deflate")) return .deflate;
    if (std.ascii.eqlIgnoreCase(encoding, "zstd")) return .zstd;
    return null;
}

fn decodeContentEncoding(
    alloc: Allocator,
    content_encoding: std.http.ContentEncoding,
    encoded: []const u8,
    cap: usize,
) ![]u8 {
    const scratch_len: usize = switch (content_encoding) {
        .gzip, .deflate => std.compress.flate.max_window_len,
        .zstd => std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
        .identity, .compress => unreachable,
    };
    const scratch = try alloc.alloc(u8, scratch_len);
    defer alloc.free(scratch);

    var encoded_reader: std.Io.Reader = .fixed(encoded);
    var decompressor: std.http.Decompress = undefined;
    const decoded_reader = std.http.Decompress.init(&decompressor, &encoded_reader, scratch, content_encoding);
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(alloc);
    const overflow_limit = std.math.add(usize, cap, 1) catch return error.BodyTooLarge;
    decoded_reader.appendRemaining(alloc, &decoded, .limited(overflow_limit)) catch |err| switch (err) {
        error.StreamTooLong => return error.BodyTooLarge,
        else => return err,
    };
    if (decoded.items.len > cap) return error.BodyTooLarge;
    return decoded.toOwnedSlice(alloc);
}

fn hopOptions(options: FetchOptions) FetchOptions {
    var effective = normalizedOptions(options);
    if (effective.deadline == null) {
        effective.deadline = .{ .deadline_ms = monotonicMillis() + default_hop_timeout_ms };
    }
    return effective;
}

fn normalizedOptions(options: FetchOptions) FetchOptions {
    return .{
        .max_body_bytes = if (options.max_body_bytes == 0) max_body_bytes else options.max_body_bytes,
        .deadline = options.deadline,
        .cancel_flag = options.cancel_flag,
    };
}

fn resolveAddresses(alloc: Allocator, target: url_policy.ValidatedUrl, options: FetchOptions, resolver: Resolver) ![]IpAddress {
    if (target.literal_address) |literal| {
        var address = literal;
        address.setPort(target.port);
        const out = try alloc.alloc(IpAddress, 1);
        out[0] = address;
        return out;
    }
    return resolver.resolve(resolver.ctx, alloc, target.canonical_host, target.port, normalizedOptions(options));
}

fn cloneUrl(alloc: Allocator, source: url_policy.ValidatedUrl) !url_policy.ValidatedUrl {
    return .{
        .scheme = source.scheme,
        .canonical_host = try alloc.dupe(u8, source.canonical_host),
        .port = source.port,
        .explicit_port = source.explicit_port,
        .path_query = try alloc.dupe(u8, source.path_query),
        .retrieval_url = try alloc.dupe(u8, source.retrieval_url),
        .literal_address = source.literal_address,
    };
}

fn hostHeader(alloc: Allocator, target: url_policy.ValidatedUrl) ![]u8 {
    const host = try hostForHeader(alloc, target.canonical_host);
    defer alloc.free(host);
    if (target.explicit_port) |port| return std.fmt.allocPrint(alloc, "{s}:{d}", .{ host, port });
    return alloc.dupe(u8, host);
}

fn hostForHeader(alloc: Allocator, canonical_host: []const u8) ![]u8 {
    if (std.mem.findScalar(u8, canonical_host, ':') == null) return alloc.dupe(u8, canonical_host);
    return std.fmt.allocPrint(alloc, "[{s}]", .{canonical_host});
}

fn isRedirectStatus(status: std.http.Status) bool {
    return status == .moved_permanently or
        status == .found or
        status == .see_other or
        status == .temporary_redirect or
        status == .permanent_redirect;
}

fn resolveDefault(_: *anyopaque, alloc: Allocator, host: []const u8, port: u16, options: FetchOptions) anyerror![]IpAddress {
    try checkControl(options);
    const host_name = try std.Io.net.HostName.init(host);
    if (options.deadline) |deadline| return resolveWithDeadline(alloc, host_name, port, deadline, options);
    return collectLookup(alloc, host_name, port, options);
}

const ResolveSelect = union(enum) {
    lookup: anyerror![]IpAddress,
    timeout: anyerror!void,
};

fn resolveWithDeadline(alloc: Allocator, host_name: std.Io.net.HostName, port: u16, deadline: Deadline, options: FetchOptions) anyerror![]IpAddress {
    const zio = io_mod.getIo();
    var select_buffer: [2]ResolveSelect = undefined;
    var select: std.Io.Select(ResolveSelect) = .init(zio, &select_buffer);

    try select.concurrent(.lookup, collectLookup, .{ alloc, host_name, port, options });
    try select.concurrent(.timeout, waitForDeadline, .{deadline});

    const result = try select.await();
    switch (result) {
        .lookup => |lookup_result| {
            select.cancelDiscard();
            return lookup_result;
        },
        .timeout => |timeout_result| {
            cancelResolveSelect(alloc, &select);
            try timeout_result;
            return error.Timeout;
        },
    }
}

fn collectLookup(alloc: Allocator, host_name: std.Io.net.HostName, port: u16, options: FetchOptions) anyerror![]IpAddress {
    try checkControl(options);
    const zio = io_mod.getIo();
    var lookup_buffer: [64]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    try std.Io.net.HostName.lookup(host_name, zio, &lookup_queue, .{ .port = port });

    var addresses: std.ArrayList(IpAddress) = .empty;
    errdefer addresses.deinit(alloc);
    while (lookup_queue.getOne(zio)) |item| {
        switch (item) {
            .address => |address| try addresses.append(alloc, address),
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {},
        error.Canceled => return error.Canceled,
    }
    try checkControl(options);
    if (addresses.items.len == 0) return error.NoAddressReturned;
    return addresses.toOwnedSlice(alloc);
}

fn waitForDeadline(deadline: Deadline) anyerror!void {
    const timestamp: std.Io.Clock.Timestamp = .{
        .clock = .awake,
        .raw = std.Io.Timestamp.fromNanoseconds(@as(i96, deadline.deadline_ms) * std.time.ns_per_ms),
    };
    try timestamp.wait(io_mod.getIo());
    return error.Timeout;
}

fn cancelResolveSelect(alloc: Allocator, select: *std.Io.Select(ResolveSelect)) void {
    while (select.cancel()) |item| switch (item) {
        .lookup => |lookup_result| {
            const addresses = lookup_result catch continue;
            alloc.free(addresses);
        },
        .timeout => {},
    };
}

const Dialer = struct {
    ctx: *anyopaque,
    connect_fn: *const fn (*anyopaque, IpAddress, FetchOptions) anyerror!posix.fd_t,
};

fn connectDefaultDialer(_: *anyopaque, address: IpAddress, options: FetchOptions) anyerror!posix.fd_t {
    return connectPinned(address, options);
}

fn connectAdmitted(addresses: []const IpAddress, options: FetchOptions, dialer: Dialer) anyerror!posix.fd_t {
    if (addresses.len == 0) return error.NoAddressReturned;

    for (addresses, 0..) |address, index| {
        try checkControl(options);
        const fd = dialer.connect_fn(dialer.ctx, address, options) catch |err| {
            traceDialFailure(index, addresses.len, err);
            if (!isRetryableConnectError(err)) return err;
            if (index + 1 == addresses.len) return err;
            try checkControl(options);
            continue;
        };
        return fd;
    }
    unreachable;
}

fn isRetryableConnectError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.ConnectionFailed,
        error.UnexpectedClose,
        error.Timeout,
        => true,
        else => false,
    };
}

fn connectDefault(_: *anyopaque, alloc: Allocator, target: PinnedTarget, options: FetchOptions) anyerror!ConnectorResponse {
    const effective = normalizedOptions(options);
    const dialer: Dialer = .{
        .ctx = @ptrCast(&default_connector_ctx),
        .connect_fn = connectDefaultDialer,
    };
    const fd = connectAdmitted(target.admitted_addresses, effective, dialer) catch |err| {
        traceFailure(.connect, err);
        return err;
    };
    defer closeFd(fd);

    return switch (target.url.scheme) {
        .http => try fetchPlain(alloc, fd, target, effective),
        .https => try fetchTls(alloc, fd, target, effective),
    };
}

fn fetchPlain(alloc: Allocator, fd: posix.fd_t, target: PinnedTarget, options: FetchOptions) anyerror!ConnectorResponse {
    var writer: PlainDeadlineWriter = undefined;
    writer.init(fd, options);
    writeRequest(&writer.interface, target, options) catch |err| {
        const root = unwrapWriteFailure(err, writer.err);
        traceFailure(.request_write, root);
        return root;
    };
    writer.interface.flush() catch |err| {
        const root = unwrapWriteFailure(err, writer.err);
        traceFailure(.request_write, root);
        return root;
    };

    var reader: PlainDeadlineReader = undefined;
    reader.init(fd, options);
    var failure_stage: FailureStage = .response_head;
    return readResponse(alloc, &reader.interface, options.max_body_bytes, options, &failure_stage) catch |err| {
        const root = unwrapReadFailure(err, null, reader.err);
        traceFailure(failure_stage, root);
        return root;
    };
}

fn fetchTls(alloc: Allocator, fd: posix.fd_t, target: PinnedTarget, options: FetchOptions) anyerror!ConnectorResponse {
    const zio = io_mod.getIo();

    var ca_bundle: std.crypto.Certificate.Bundle = .empty;
    defer ca_bundle.deinit(alloc);
    var ca_lock: std.Io.RwLock = .init;
    const now = std.Io.Clock.real.now(zio);
    ca_bundle.rescan(alloc, zio, now) catch |err| {
        traceFailure(.tls_handshake, err);
        return err;
    };

    var encrypted_reader: TlsDeadlineReader = undefined;
    encrypted_reader.init(fd, options);
    var encrypted_writer: TlsDeadlineWriter = undefined;
    encrypted_writer.init(fd, options);

    const tls_read_buffer = try alloc.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer alloc.free(tls_read_buffer);
    const tls_write_buffer = try alloc.alloc(u8, std.crypto.tls.Client.min_buffer_len);
    defer alloc.free(tls_write_buffer);
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    zio.random(&entropy);

    var tls_client = std.crypto.tls.Client.init(
        &encrypted_reader.interface,
        &encrypted_writer.interface,
        .{
            .host = .{ .explicit = target.tls_server_name },
            .ca = .{ .bundle = .{
                .gpa = alloc,
                .io = zio,
                .lock = &ca_lock,
                .bundle = &ca_bundle,
            } },
            .read_buffer = tls_read_buffer,
            .write_buffer = tls_write_buffer,
            .entropy = &entropy,
            .realtime_now = now,
            .allow_truncation_attacks = tls_allow_truncation_attacks,
        },
    ) catch |err| {
        const root = switch (err) {
            error.ReadFailed => unwrapReadFailure(err, null, encrypted_reader.err),
            error.WriteFailed => unwrapWriteFailure(err, encrypted_writer.err),
            else => err,
        };
        traceFailure(.tls_handshake, root);
        return root;
    };

    writeRequest(&tls_client.writer, target, options) catch |err| {
        const root = unwrapWriteFailure(err, encrypted_writer.err);
        traceFailure(.request_write, root);
        return root;
    };
    tls_client.writer.flush() catch |err| {
        const root = unwrapWriteFailure(err, encrypted_writer.err);
        traceFailure(.request_write, root);
        return root;
    };
    encrypted_writer.interface.flush() catch |err| {
        const root = unwrapWriteFailure(err, encrypted_writer.err);
        traceFailure(.request_write, root);
        return root;
    };

    var failure_stage: FailureStage = .response_head;
    return readResponse(alloc, &tls_client.reader, options.max_body_bytes, options, &failure_stage) catch |err| {
        const root = unwrapReadFailure(err, tls_client.read_err, encrypted_reader.err);
        traceFailure(failure_stage, root);
        return root;
    };
}

fn writeRequest(writer: *std.Io.Writer, target: PinnedTarget, options: FetchOptions) !void {
    try checkControl(options);
    try writer.print(
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "User-Agent: fx (web_fetch; +https://github.com/vercel-labs/fx)\r\n" ++
            "Accept: text/markdown, text/html, */*\r\n" ++
            "Accept-Encoding: gzip, deflate, zstd\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ target.url.path_query, target.host_header },
    );
}

fn readResponse(
    alloc: Allocator,
    reader: *std.Io.Reader,
    cap: usize,
    options: FetchOptions,
    failure_stage: *FailureStage,
) anyerror!ConnectorResponse {
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(alloc);

    var scratch: [4096]u8 = undefined;
    var cumulative_head_bytes: usize = 0;
    var interim_count: usize = 0;
    var final_head_end: usize = undefined;
    var final_head: ?ParsedHead = null;

    while (final_head == null) {
        const remaining_budget = max_header_bytes - cumulative_head_bytes;
        var complete_head_end: ?usize = null;
        while (complete_head_end == null) {
            if (std.mem.find(u8, received.items, "\r\n\r\n")) |terminator_index| {
                const candidate_end = terminator_index + "\r\n\r\n".len;
                if (candidate_end > remaining_budget) return error.HttpHeadersOversize;
                complete_head_end = candidate_end;
                break;
            }
            if (received.items.len >= remaining_budget) return error.HttpHeadersOversize;
            const n = try readSome(reader, &scratch, options);
            if (n == 0) return error.UnexpectedClose;
            try received.appendSlice(alloc, scratch[0..n]);
        }

        const head_end = complete_head_end.?;
        var parsed = try parseHead(alloc, received.items[0 .. head_end - "\r\n\r\n".len]);
        const status_code = @intFromEnum(parsed.status);
        if (status_code >= 100 and status_code < 200) {
            if (status_code == 101) {
                parsed.deinit(alloc);
                return error.UnsupportedProtocolUpgrade;
            }
            if (interim_count >= 16) {
                parsed.deinit(alloc);
                return error.TooManyInterimResponses;
            }
            interim_count += 1;
            cumulative_head_bytes += head_end;
            parsed.deinit(alloc);

            const pending_len = received.items.len - head_end;
            std.mem.copyForwards(u8, received.items[0..pending_len], received.items[head_end..]);
            received.items.len = pending_len;
            continue;
        }

        final_head_end = head_end;
        final_head = parsed;
    }

    var head = final_head.?;
    errdefer head.deinit(alloc);

    const framing = head.framing;
    failure_stage.* = .response_body;

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    const pending_body = received.items[final_head_end..];
    switch (framing) {
        .no_body => {
            if (pending_body.len > 0) return error.UnexpectedBodyForBodylessResponse;
        },
        .chunked => {
            var chunk_reader = BodyReader.init(reader, pending_body, options);
            try readChunkedBody(&chunk_reader, &body, alloc, cap);
        },
        .content_length => |content_length| {
            try appendCapped(&body, alloc, pending_body[0..@min(pending_body.len, content_length)], cap);
            if (content_length > cap) return error.BodyTooLarge;
            while (body.items.len < content_length) {
                const n = try readSome(reader, &scratch, options);
                if (n == 0) return error.UnexpectedClose;
                const remaining = content_length - body.items.len;
                try appendCapped(&body, alloc, scratch[0..@min(n, remaining)], cap);
            }
        },
        .close_delimited => {
            try appendCapped(&body, alloc, pending_body, cap);
            while (true) {
                const n = try readSome(reader, &scratch, options);
                if (n == 0) break;
                try appendCapped(&body, alloc, scratch[0..n], cap);
            }
        },
    }

    return .{
        .status = head.status,
        .body = try body.toOwnedSlice(alloc),
        .location = head.location,
        .content_encoding = head.content_encoding,
        .content_encoding_count = head.content_encoding_count,
        .content_type = head.content_type,
    };
}

fn readSome(reader: *std.Io.Reader, scratch: []u8, options: FetchOptions) !usize {
    while (true) {
        try checkControl(options);
        // Do not let a later TLS record failure mask plaintext already authenticated and buffered.
        const buffered = reader.buffered();
        if (buffered.len > 0) {
            const n = @min(buffered.len, scratch.len);
            @memcpy(scratch[0..n], buffered[0..n]);
            reader.toss(n);
            return n;
        }
        var data: [1][]u8 = .{scratch};
        const n = reader.readVec(&data) catch |err| switch (err) {
            error.EndOfStream => return 0,
            error.ReadFailed => return error.ReadFailed,
        };
        if (n > 0) return n;
    }
}

const ParsedHead = struct {
    version: HttpVersion,
    status: std.http.Status,
    framing: BodyFraming,
    location: ?[]u8 = null,
    content_encoding: ?[]u8 = null,
    content_encoding_count: usize = 0,
    content_type: ?[]u8 = null,

    fn deinit(self: *ParsedHead, alloc: Allocator) void {
        if (self.location) |location| alloc.free(location);
        if (self.content_encoding) |encoding| alloc.free(encoding);
        if (self.content_type) |mime| alloc.free(mime);
        self.* = .{
            .version = .http_1_1,
            .status = .ok,
            .framing = .close_delimited,
        };
    }
};

const HttpVersion = enum {
    http_1_0,
    http_1_1,
};

const StatusLine = struct {
    version: HttpVersion,
    status: std.http.Status,
};

const FieldLine = struct {
    name: []const u8,
    value: []const u8,
};

const NormalizedField = struct {
    storage: []u8,
    field: FieldLine,

    fn deinit(self: *@This(), alloc: Allocator) void {
        alloc.free(self.storage);
        self.* = undefined;
    }
};

const NormalizedFieldIterator = struct {
    alloc: Allocator,
    raw: []const u8,
    cursor: usize = 0,

    fn next(self: *@This()) !?NormalizedField {
        const first = self.nextRawLine() orelse return null;
        if (first.len == 0 or first[0] == ' ' or first[0] == '\t')
            return error.InvalidHttpResponse;

        var normalized: std.ArrayList(u8) = .empty;
        errdefer normalized.deinit(self.alloc);
        try normalized.appendSlice(self.alloc, first);

        while (self.cursor < self.raw.len) {
            const saved_cursor = self.cursor;
            const continuation = self.nextRawLine() orelse break;
            if (continuation.len == 0 or (continuation[0] != ' ' and continuation[0] != '\t')) {
                self.cursor = saved_cursor;
                break;
            }
            try normalized.append(self.alloc, ' ');
            try normalized.appendSlice(self.alloc, std.mem.trimStart(u8, continuation, " \t"));
        }

        const storage = try normalized.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(storage);
        return .{
            .storage = storage,
            .field = try parseFieldLine(storage),
        };
    }

    fn nextRawLine(self: *@This()) ?[]const u8 {
        if (self.cursor >= self.raw.len) return null;
        const remaining = self.raw[self.cursor..];
        if (std.mem.find(u8, remaining, "\r\n")) |line_end| {
            self.cursor += line_end + 2;
            return remaining[0..line_end];
        }
        self.cursor = self.raw.len;
        return remaining;
    }
};

const TransferCodingState = struct {
    present: bool = false,
    count: usize = 0,
    sole_is_chunked: bool = false,
};

const TransferCoding = struct {
    name: []const u8,
    has_parameters: bool,
};

const ResponseFramingState = struct {
    content_length: ?usize = null,
    content_length_present: bool = false,
    transfer_coding: TransferCodingState = .{},
};

fn parseHead(alloc: Allocator, header: []const u8) !ParsedHead {
    const status_end = std.mem.find(u8, header, "\r\n");
    const status_line = if (status_end) |end| header[0..end] else header;
    const fields = if (status_end) |end| header[end + 2 ..] else "";
    const status = try parseStatusLine(status_line);

    var parsed: ParsedHead = .{
        .version = status.version,
        .status = status.status,
        .framing = .close_delimited,
    };
    errdefer parsed.deinit(alloc);

    var framing: ResponseFramingState = .{};
    var iterator: NormalizedFieldIterator = .{ .alloc = alloc, .raw = fields };
    while (try iterator.next()) |normalized_value| {
        var normalized = normalized_value;
        defer normalized.deinit(alloc);
        try applyHeadField(alloc, &parsed, &framing, normalized.field);
    }
    parsed.framing = try responseBodyFraming(status, framing);
    return parsed;
}

fn applyHeadField(
    alloc: Allocator,
    parsed: *ParsedHead,
    framing: *ResponseFramingState,
    field: FieldLine,
) !void {
    if (std.ascii.eqlIgnoreCase(field.name, "Location")) {
        try replaceOwned(alloc, &parsed.location, field.value);
    } else if (std.ascii.eqlIgnoreCase(field.name, "Content-Encoding")) {
        if (parsed.content_encoding == null)
            try replaceOwned(alloc, &parsed.content_encoding, field.value);
        parsed.content_encoding_count += 1;
    } else if (std.ascii.eqlIgnoreCase(field.name, "Content-Type")) {
        try replaceOwned(alloc, &parsed.content_type, field.value);
    } else if (std.ascii.eqlIgnoreCase(field.name, "Content-Length")) {
        framing.content_length_present = true;
        try parseContentLengthValue(field.value, &framing.content_length);
    } else if (std.ascii.eqlIgnoreCase(field.name, "Transfer-Encoding")) {
        framing.transfer_coding.present = true;
        try parseTransferEncodingValue(field.value, &framing.transfer_coding);
    }
}

fn responseBodyFraming(status: StatusLine, framing: ResponseFramingState) !BodyFraming {
    const transfer_coding = framing.transfer_coding;
    if (transfer_coding.present and transfer_coding.count == 0)
        return error.InvalidHttpResponse;
    if (status.version == .http_1_0 and transfer_coding.present)
        return error.InvalidHttpResponse;

    const status_code = @intFromEnum(status.status);
    return if (status_code == 204 or status_code == 304)
        .no_body
    else if (transfer_coding.present and framing.content_length_present)
        return error.AmbiguousHttpFraming
    else if (transfer_coding.present)
        if (transfer_coding.count == 1 and transfer_coding.sole_is_chunked)
            .chunked
        else
            return error.UnsupportedTransferEncoding
    else if (framing.content_length) |len|
        .{ .content_length = len }
    else
        .close_delimited;
}

fn parseStatusLine(line: []const u8) !StatusLine {
    if (line.len < 13) return error.InvalidHttpResponse;
    const version: HttpVersion = if (std.mem.eql(u8, line[0..8], "HTTP/1.0"))
        .http_1_0
    else if (std.mem.eql(u8, line[0..8], "HTTP/1.1"))
        .http_1_1
    else
        return error.InvalidHttpResponse;
    if (line[8] != ' ' or line[12] != ' ') return error.InvalidHttpResponse;
    for (line[9..12]) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidHttpResponse;
    }
    const code = std.fmt.parseInt(u16, line[9..12], 10) catch return error.InvalidHttpResponse;
    if (code < 100 or code > 599) return error.InvalidHttpResponse;
    for (line[13..]) |byte| {
        if (byte == '\t' or byte == ' ' or (byte >= 0x21 and byte <= 0x7e) or byte >= 0x80)
            continue;
        return error.InvalidHttpResponse;
    }
    return .{
        .version = version,
        .status = @enumFromInt(code),
    };
}

fn isTchar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn parseFieldLine(line: []const u8) !FieldLine {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t')
        return error.InvalidHttpResponse;

    const colon = std.mem.findScalar(u8, line, ':') orelse
        return error.InvalidHttpResponse;
    const name = line[0..colon];
    if (name.len == 0) return error.InvalidHttpResponse;
    for (name) |byte| {
        if (!isTchar(byte)) return error.InvalidHttpResponse;
    }

    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    for (value) |byte| {
        if (byte == '\t' or byte == ' ' or byte >= 0x21) continue;
        return error.InvalidHttpResponse;
    }
    if (std.mem.findScalar(u8, value, 0x7f) != null)
        return error.InvalidHttpResponse;
    return .{ .name = name, .value = value };
}

fn parseContentLengthValue(value: []const u8, expected: *?usize) !void {
    var members = std.mem.splitScalar(u8, value, ',');
    while (members.next()) |raw_member| {
        const member = std.mem.trim(u8, raw_member, " \t");
        if (member.len == 0) return error.InvalidHttpResponse;
        for (member) |byte| {
            if (!std.ascii.isDigit(byte)) return error.InvalidHttpResponse;
        }
        const len = std.fmt.parseInt(usize, member, 10) catch return error.InvalidHttpResponse;
        if (expected.*) |prior| {
            if (prior != len) return error.AmbiguousHttpFraming;
        } else {
            expected.* = len;
        }
    }
}

fn parseTransferEncodingValue(value: []const u8, state: *TransferCodingState) !void {
    var member_start: usize = 0;
    var in_quote = false;
    var escaped = false;

    var index: usize = 0;
    while (index <= value.len) : (index += 1) {
        const at_end = index == value.len;
        const byte = if (at_end) 0 else value[index];
        if (!at_end and in_quote) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_quote = false;
            }
            continue;
        }
        if (!at_end and byte == '"') {
            in_quote = true;
            continue;
        }
        if (!at_end and byte != ',') continue;
        if (in_quote or escaped) return error.InvalidHttpResponse;

        const member = std.mem.trim(u8, value[member_start..index], " \t");
        member_start = index + 1;
        if (member.len == 0) continue;

        const coding = try parseTransferCodingMember(member);
        if (std.ascii.eqlIgnoreCase(coding.name, "chunked") and coding.has_parameters)
            return error.InvalidHttpResponse;
        state.count += 1;
        state.sole_is_chunked = state.count == 1 and std.ascii.eqlIgnoreCase(coding.name, "chunked");
    }
}

fn parseTransferCodingMember(member: []const u8) !TransferCoding {
    var index: usize = 0;
    const name = consumeToken(member, &index) orelse return error.InvalidHttpResponse;
    var has_parameters = false;
    while (index < member.len) {
        skipOws(member, &index);
        if (index == member.len or member[index] != ';') return error.InvalidHttpResponse;
        index += 1;
        skipOws(member, &index);
        _ = consumeToken(member, &index) orelse return error.InvalidHttpResponse;
        skipOws(member, &index);
        if (index == member.len or member[index] != '=') return error.InvalidHttpResponse;
        index += 1;
        skipOws(member, &index);
        if (index == member.len) return error.InvalidHttpResponse;
        if (member[index] == '"') {
            try consumeQuotedString(member, &index);
        } else {
            _ = consumeToken(member, &index) orelse return error.InvalidHttpResponse;
        }
        has_parameters = true;
    }
    return .{ .name = name, .has_parameters = has_parameters };
}

fn consumeToken(bytes: []const u8, index: *usize) ?[]const u8 {
    const start = index.*;
    while (index.* < bytes.len and isTchar(bytes[index.*])) index.* += 1;
    if (index.* == start) return null;
    return bytes[start..index.*];
}

fn skipOws(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and (bytes[index.*] == ' ' or bytes[index.*] == '\t'))
        index.* += 1;
}

fn consumeQuotedString(bytes: []const u8, index: *usize) !void {
    if (index.* >= bytes.len or bytes[index.*] != '"') return error.InvalidHttpResponse;
    index.* += 1;
    while (index.* < bytes.len) {
        const byte = bytes[index.*];
        if (byte == '"') {
            index.* += 1;
            return;
        }
        if (byte == '\\') {
            index.* += 1;
            if (index.* >= bytes.len or !isQuotedPairByte(bytes[index.*]))
                return error.InvalidHttpResponse;
            index.* += 1;
            continue;
        }
        if (!isQuotedTextByte(byte)) return error.InvalidHttpResponse;
        index.* += 1;
    }
    return error.InvalidHttpResponse;
}

fn isQuotedTextByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == 0x21 or
        (byte >= 0x23 and byte <= 0x5b) or
        (byte >= 0x5d and byte <= 0x7e) or
        byte >= 0x80;
}

fn isQuotedPairByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or
        (byte >= 0x21 and byte <= 0x7e) or
        byte >= 0x80;
}

fn appendCapped(body: *std.ArrayList(u8), alloc: Allocator, bytes: []const u8, cap: usize) !void {
    if (bytes.len > cap - body.items.len) return error.BodyTooLarge;
    try body.appendSlice(alloc, bytes);
}

const BodyReader = struct {
    reader: *std.Io.Reader,
    pending: []const u8,
    options: FetchOptions,
    index: usize = 0,
    scratch: [4096]u8 = undefined,

    fn init(reader: *std.Io.Reader, pending: []const u8, options: FetchOptions) BodyReader {
        return .{ .reader = reader, .pending = pending, .options = options };
    }

    fn available(self: *BodyReader) []const u8 {
        return self.pending[self.index..];
    }

    fn refill(self: *BodyReader) !bool {
        const n = try readSome(self.reader, &self.scratch, self.options);
        if (n == 0) return false;
        self.pending = self.scratch[0..n];
        self.index = 0;
        return true;
    }

    fn readByte(self: *BodyReader) !?u8 {
        if (self.index >= self.pending.len) {
            if (!try self.refill()) return null;
        }
        const byte = self.pending[self.index];
        self.index += 1;
        return byte;
    }

    fn readLine(self: *BodyReader, alloc: Allocator) ![]u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(alloc);
        while (true) {
            const byte = (try self.readByte()) orelse return error.UnexpectedClose;
            if (byte == '\r') {
                const lf = (try self.readByte()) orelse return error.UnexpectedClose;
                if (lf != '\n') return error.InvalidHttpResponse;
                return line.toOwnedSlice(alloc);
            }
            if (byte == '\n') return error.InvalidHttpResponse;
            if (line.items.len >= 4096) return error.InvalidHttpResponse;
            try line.append(alloc, byte);
        }
    }

    fn appendBytes(self: *BodyReader, body: *std.ArrayList(u8), alloc: Allocator, len: usize, cap: usize) !void {
        var remaining = len;
        while (remaining > 0) {
            if (self.index >= self.pending.len) {
                if (!try self.refill()) return error.UnexpectedClose;
            }
            const available_bytes = self.available();
            const take = @min(available_bytes.len, remaining);
            try appendCapped(body, alloc, available_bytes[0..take], cap);
            self.index += take;
            remaining -= take;
        }
    }

    fn expectCrLf(self: *BodyReader) !void {
        const cr = (try self.readByte()) orelse return error.UnexpectedClose;
        const lf = (try self.readByte()) orelse return error.UnexpectedClose;
        if (cr != '\r' or lf != '\n') return error.InvalidHttpResponse;
    }
};

fn readChunkedBody(reader: *BodyReader, body: *std.ArrayList(u8), alloc: Allocator, cap: usize) !void {
    while (true) {
        const line = try reader.readLine(alloc);
        defer alloc.free(line);
        const chunk_len = try parseChunkSizeLine(line);
        if (chunk_len == 0) {
            return readChunkedTrailers(reader, alloc);
        }
        if (chunk_len > cap - body.items.len) return error.BodyTooLarge;
        try reader.appendBytes(body, alloc, chunk_len, cap);
        try reader.expectCrLf();
    }
}

fn parseChunkSizeLine(line: []const u8) !usize {
    var index: usize = 0;
    while (index < line.len and std.ascii.isHex(line[index])) index += 1;
    if (index == 0) return error.InvalidHttpResponse;
    const chunk_len = std.fmt.parseInt(usize, line[0..index], 16) catch
        return error.InvalidHttpResponse;
    try parseChunkExtensions(line, &index);
    return chunk_len;
}

fn parseChunkExtensions(line: []const u8, index: *usize) !void {
    while (index.* < line.len) {
        const bws_start = index.*;
        skipOws(line, index);
        if (index.* == line.len) {
            if (index.* != bws_start) return error.InvalidHttpResponse;
            return;
        }
        if (line[index.*] != ';') return error.InvalidHttpResponse;
        index.* += 1;
        skipOws(line, index);
        _ = consumeToken(line, index) orelse return error.InvalidHttpResponse;

        const before_optional_value_bws = index.*;
        skipOws(line, index);
        if (index.* < line.len and line[index.*] == '=') {
            index.* += 1;
            skipOws(line, index);
            if (index.* == line.len) return error.InvalidHttpResponse;
            if (line[index.*] == '"') {
                try consumeQuotedString(line, index);
            } else {
                _ = consumeToken(line, index) orelse return error.InvalidHttpResponse;
            }
        } else if (index.* == line.len and index.* != before_optional_value_bws) {
            return error.InvalidHttpResponse;
        }
    }
}

fn readChunkedTrailers(reader: *BodyReader, alloc: Allocator) !void {
    var raw_trailers: std.ArrayList(u8) = .empty;
    defer raw_trailers.deinit(alloc);
    var trailer_bytes: usize = 0;

    while (true) {
        const line = try reader.readLine(alloc);
        defer alloc.free(line);
        const charged = line.len + 2;
        if (charged > max_header_bytes - trailer_bytes)
            return error.HttpTrailersOversize;
        trailer_bytes += charged;
        if (line.len == 0) break;

        if (raw_trailers.items.len > 0)
            try raw_trailers.appendSlice(alloc, "\r\n");
        try raw_trailers.appendSlice(alloc, line);
    }

    var iterator: NormalizedFieldIterator = .{
        .alloc = alloc,
        .raw = raw_trailers.items,
    };
    while (try iterator.next()) |normalized_value| {
        var normalized = normalized_value;
        normalized.deinit(alloc);
    }
}

fn connectPinned(address: IpAddress, options: FetchOptions) !posix.fd_t {
    try checkControl(options);
    const family: posix.sa_family_t = switch (address) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const fd = try openSocket(family);
    errdefer closeFd(fd);

    var storage: PosixAddress = undefined;
    const len = addressToPosix(address, &storage);
    while (true) switch (posix.errno(posix.system.connect(fd, &storage.any, len))) {
        .SUCCESS => return fd,
        .INTR => {
            try checkControl(options);
            continue;
        },
        .INPROGRESS, .AGAIN, .ALREADY => {
            try pollFd(fd, posix.POLL.OUT, options);
            try checkSocketError(fd);
            return fd;
        },
        else => |err| return classifyConnectErrno(err),
    };
}

fn classifyConnectErrno(err: posix.E) anyerror {
    return switch (err) {
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.Timeout,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .NETDOWN => error.NetworkDown,
        .NOBUFS, .NOMEM => error.SystemResources,
        .BADF => error.InvalidDescriptor,
        .CANCELED => error.Canceled,
        .IO => error.InputOutput,
        else => error.ConnectionFailed,
    };
}

const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

fn addressToPosix(address: IpAddress, storage: *PosixAddress) posix.socklen_t {
    return switch (address) {
        .ip4 => |ip4| {
            storage.in = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            storage.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return @sizeOf(posix.sockaddr.in6);
        },
    };
}

fn openSocket(family: posix.sa_family_t) !posix.fd_t {
    const fd = while (true) {
        const rc = posix.system.socket(family, posix.SOCK.STREAM, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => break @as(posix.fd_t, @intCast(rc)),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.SocketOpenFailed,
        }
    };
    errdefer closeFd(fd);
    try setCloexec(fd);
    try setNonblocking(fd);
    return fd;
}

fn setCloexec(fd: posix.fd_t) !void {
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.SocketOptionFailed,
    };
}

fn setNonblocking(fd: posix.fd_t) !void {
    const current = while (true) {
        const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            else => return error.SocketOptionFailed,
        }
    };
    const current_flags: usize = @intCast(current);
    const nonblock_flag: usize = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    const next: usize = current_flags | nonblock_flag;
    while (true) switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, next))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.SocketOptionFailed,
    };
}

fn checkSocketError(fd: posix.fd_t) !void {
    var value: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &value, &len) != 0) return error.ConnectionFailed;
    if (value == 0) return;
    const socket_error: posix.E = @enumFromInt(value);
    return classifyConnectErrno(socket_error);
}

fn closeFd(fd: posix.fd_t) void {
    while (true) switch (posix.errno(posix.system.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

fn traceFailure(stage: FailureStage, err: anyerror) void {
    debug_trace.logf(
        "tool",
        "web_fetch transport failed stage={s} err={s}",
        .{ @tagName(stage), @errorName(err) },
    );
}

fn traceDialFailure(attempt_index: usize, attempt_count: usize, err: anyerror) void {
    debug_trace.logf(
        "tool",
        "web_fetch dial failed stage=connect attempt={d}/{d} err={s}",
        .{ attempt_index + 1, attempt_count, @errorName(err) },
    );
}

fn unwrapReadFailure(err: anyerror, tls_err: ?anyerror, transport_err: ?anyerror) anyerror {
    if (err != error.ReadFailed) return err;
    if (tls_err) |root| return root;
    if (transport_err) |root| return root;
    return error.ReadFailed;
}

fn unwrapWriteFailure(err: anyerror, transport_err: ?anyerror) anyerror {
    if (err != error.WriteFailed) return err;
    if (transport_err) |root| return root;
    return error.WriteFailed;
}

const PlainDeadlineReader = DeadlineReader(plain_transport_buffer_len);
const TlsDeadlineReader = DeadlineReader(tls_transport_buffer_len);
const PlainDeadlineWriter = DeadlineWriter(plain_transport_buffer_len);
const TlsDeadlineWriter = DeadlineWriter(tls_transport_buffer_len);

fn DeadlineReader(comptime buffer_len: usize) type {
    return struct {
        fd: posix.fd_t,
        options: FetchOptions,
        buffer: [buffer_len]u8 = undefined,
        interface: std.Io.Reader = undefined,
        err: ?anyerror = null,

        fn init(self: *@This(), fd: posix.fd_t, options: FetchOptions) void {
            self.* = .{ .fd = fd, .options = options };
            self.interface = .{
                .vtable = &.{
                    .stream = stream,
                    .readVec = readVec,
                },
                .buffer = &self.buffer,
                .seek = 0,
                .end = 0,
            };
        }

        fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
            for (data) |dest| {
                if (dest.len == 0) continue;
                const n = rawRead(self.fd, dest, self.options) catch |err| {
                    self.err = err;
                    return error.ReadFailed;
                };
                if (n == 0) return error.EndOfStream;
                return n;
            }
            const dest = reader.buffer[reader.end..];
            if (dest.len == 0) return 0;
            const n = rawRead(self.fd, dest, self.options) catch |err| {
                self.err = err;
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            reader.end += n;
            return 0;
        }

        fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const dest = limit.slice(try writer.writableSliceGreedy(1));
            var data: [1][]u8 = .{dest};
            const n = readVec(reader, &data) catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return error.ReadFailed,
            };
            writer.advance(n);
            return n;
        }
    };
}

fn DeadlineWriter(comptime buffer_len: usize) type {
    return struct {
        fd: posix.fd_t,
        options: FetchOptions,
        buffer: [buffer_len]u8 = undefined,
        interface: std.Io.Writer = undefined,
        err: ?anyerror = null,

        fn init(self: *@This(), fd: posix.fd_t, options: FetchOptions) void {
            self.* = .{ .fd = fd, .options = options };
            self.interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = &self.buffer,
                .end = 0,
            };
        }

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("interface", writer));
            if (writer.end > 0) {
                rawWriteAll(self.fd, writer.buffer[0..writer.end], self.options) catch |err| {
                    self.err = err;
                    return error.WriteFailed;
                };
                writer.end = 0;
            }

            var consumed: usize = 0;
            for (data, 0..) |part, index| {
                const repeat = if (index == data.len - 1) splat else 1;
                var count: usize = 0;
                while (count < repeat) : (count += 1) {
                    rawWriteAll(self.fd, part, self.options) catch |err| {
                        self.err = err;
                        return error.WriteFailed;
                    };
                    consumed += part.len;
                }
            }
            return consumed;
        }
    };
}

const PollError = posix.PollError || error{Interrupted};

const Poller = struct {
    ctx: ?*anyopaque,
    poll_fn: *const fn (?*anyopaque, []posix.pollfd, i32) PollError!usize,
};

fn pollDefault(_: ?*anyopaque, fds: []posix.pollfd, timeout_ms: i32) PollError!usize {
    const fds_count = std.math.cast(posix.nfds_t, fds.len) orelse
        return error.SystemResources;
    const rc = posix.system.poll(fds.ptr, fds_count, timeout_ms);
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => error.Interrupted,
        .NOMEM => error.SystemResources,
        .NETDOWN => error.NetworkDown,
        .FAULT, .INVAL => unreachable,
        else => |err| posix.unexpectedErrno(err),
    };
}

const default_poller: Poller = .{
    .ctx = null,
    .poll_fn = pollDefault,
};

const SyscallErrorAction = union(enum) {
    retry,
    failure: anyerror,
};

const RawSyscallResult = union(enum) {
    count: usize,
    failure: posix.E,
};

const ReadSyscall = struct {
    ctx: ?*anyopaque,
    read_fn: *const fn (?*anyopaque, posix.fd_t, []u8) RawSyscallResult,
};

fn readDefault(_: ?*anyopaque, fd: posix.fd_t, buf: []u8) RawSyscallResult {
    const rc = posix.system.read(fd, buf.ptr, buf.len);
    return switch (posix.errno(rc)) {
        .SUCCESS => .{ .count = @intCast(rc) },
        else => |err| .{ .failure = err },
    };
}

const default_read_syscall: ReadSyscall = .{
    .ctx = null,
    .read_fn = readDefault,
};

fn classifyReadErrno(err: posix.E) SyscallErrorAction {
    return switch (err) {
        .AGAIN, .INTR => .retry,
        .CONNRESET => .{ .failure = error.ConnectionResetByPeer },
        .PIPE => .{ .failure = error.BrokenPipe },
        .NOTCONN => .{ .failure = error.SocketUnconnected },
        .NETDOWN => .{ .failure = error.NetworkDown },
        .NOBUFS, .NOMEM => .{ .failure = error.SystemResources },
        .IO => .{ .failure = error.InputOutput },
        .BADF => .{ .failure = error.InvalidDescriptor },
        .CANCELED => .{ .failure = error.Canceled },
        .TIMEDOUT => .{ .failure = error.Timeout },
        else => .{ .failure = error.ReadFailed },
    };
}

fn classifyWriteErrno(err: posix.E) SyscallErrorAction {
    return switch (err) {
        .AGAIN, .INTR => .retry,
        .CONNRESET => .{ .failure = error.ConnectionResetByPeer },
        .PIPE => .{ .failure = error.BrokenPipe },
        .NOTCONN => .{ .failure = error.SocketUnconnected },
        .NETDOWN => .{ .failure = error.NetworkDown },
        .NOBUFS, .NOMEM => .{ .failure = error.SystemResources },
        .IO => .{ .failure = error.InputOutput },
        .BADF => .{ .failure = error.InvalidDescriptor },
        .CANCELED => .{ .failure = error.Canceled },
        .TIMEDOUT => .{ .failure = error.Timeout },
        else => .{ .failure = error.WriteFailed },
    };
}

fn rawRead(fd: posix.fd_t, buf: []u8, options: FetchOptions) !usize {
    return rawReadWith(fd, buf, options, default_poller, default_read_syscall);
}

fn rawReadWith(
    fd: posix.fd_t,
    buf: []u8,
    options: FetchOptions,
    poller: Poller,
    syscall: ReadSyscall,
) !usize {
    while (true) {
        try pollFdWith(fd, posix.POLL.IN, options, poller);
        switch (syscall.read_fn(syscall.ctx, fd, buf)) {
            .count => |count| return count,
            .failure => |err| switch (classifyReadErrno(err)) {
                .retry => {
                    if (err == .INTR) try checkControl(options);
                    continue;
                },
                .failure => |root| return root,
            },
        }
    }
}

fn rawWriteAll(fd: posix.fd_t, bytes: []const u8, options: FetchOptions) !void {
    return rawWriteAllWith(fd, bytes, options, default_poller);
}

fn rawWriteAllWith(fd: posix.fd_t, bytes: []const u8, options: FetchOptions, poller: Poller) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        try pollFdWith(fd, posix.POLL.OUT, options, poller);
        const rc = std.c.send(
            fd,
            bytes[written..].ptr,
            bytes.len - written,
            @intCast(posix.MSG.NOSIGNAL),
        );
        const errno = posix.errno(rc);
        if (errno != .SUCCESS) switch (classifyWriteErrno(errno)) {
            .retry => {
                if (errno == .INTR) try checkControl(options);
                continue;
            },
            .failure => |root| return root,
        };
        const n: usize = @intCast(rc);
        if (n == 0) return error.UnexpectedClose;
        written += n;
    }
}

fn pollFd(fd: posix.fd_t, events: i16, options: FetchOptions) !void {
    return pollFdWith(fd, events, options, default_poller);
}

fn pollFdWith(fd: posix.fd_t, events: i16, options: FetchOptions, poller: Poller) !void {
    while (true) {
        var fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = events,
            .revents = 0,
        }};
        const ready = poller.poll_fn(
            poller.ctx,
            &fds,
            try pollTimeoutMs(options),
        ) catch |err| switch (err) {
            error.Interrupted => {
                try checkControl(options);
                continue;
            },
            else => return err,
        };
        if (ready == 0) continue;
        return classifyPollEvents(fd, events, fds[0].revents);
    }
}

fn classifyPollEvents(fd: posix.fd_t, events: i16, revents: i16) !void {
    if ((revents & posix.POLL.NVAL) != 0) return error.InvalidDescriptor;
    if ((revents & events) != 0) return;
    if (events == posix.POLL.IN and (revents & posix.POLL.HUP) != 0) return;
    if ((revents & posix.POLL.ERR) != 0) return pollSocketError(fd);
    if ((revents & posix.POLL.HUP) != 0) return error.UnexpectedClose;
    return error.UnexpectedClose;
}

fn pollSocketError(fd: posix.fd_t) !void {
    var value: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &value, &len) != 0)
        return error.UnexpectedClose;
    if (value == 0) return error.UnexpectedClose;
    const socket_error: posix.E = @enumFromInt(value);
    return switch (socket_error) {
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.Timeout,
        .NETDOWN => error.NetworkDown,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .PIPE => error.BrokenPipe,
        .NOTCONN => error.SocketUnconnected,
        .NOBUFS, .NOMEM => error.SystemResources,
        .IO => error.InputOutput,
        .BADF => error.InvalidDescriptor,
        .CANCELED => error.Canceled,
        else => error.UnexpectedClose,
    };
}

fn pollTimeoutMs(options: FetchOptions) !i32 {
    try checkControl(options);
    const max_chunk_ms: i64 = 1000;
    if (options.deadline) |deadline| {
        const remaining = deadline.deadline_ms - monotonicMillis();
        if (remaining <= 0) return error.Timeout;
        return @intCast(@min(max_chunk_ms, remaining));
    }
    return @intCast(max_chunk_ms);
}

fn checkControl(options: FetchOptions) !void {
    if (options.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Canceled;
    }
    if (options.deadline) |deadline| {
        if (monotonicMillis() >= deadline.deadline_ms) return error.Timeout;
    }
}

fn monotonicMillis() i64 {
    const ts = std.Io.Clock.awake.now(io_mod.getIo());
    return @intCast(@divFloor(ts.nanoseconds, 1_000_000));
}

fn appendRepeatedByte(list: *std.ArrayList(u8), alloc: Allocator, byte: u8, count: usize) !void {
    try list.ensureUnusedCapacity(alloc, count);
    for (0..count) |_| list.appendAssumeCapacity(byte);
}

fn appendBudgetedInterimResponse(
    list: *std.ArrayList(u8),
    alloc: Allocator,
    complete_head_len: usize,
) !void {
    const prefix = "HTTP/1.1 103 Early Hints\r\nX-Fill: ";
    const suffix = "\r\n\r\n";
    if (complete_head_len < prefix.len + suffix.len) return error.InvalidTestFixture;
    try list.appendSlice(alloc, prefix);
    try appendRepeatedByte(list, alloc, 'a', complete_head_len - prefix.len - suffix.len);
    try list.appendSlice(alloc, suffix);
}

fn appendTrailerLine(
    payload: *std.ArrayList(u8),
    alloc: Allocator,
    line_len: usize,
) !void {
    if (line_len < 2) return error.InvalidTestFixture;
    try payload.appendSlice(alloc, "X:");
    try appendRepeatedByte(payload, alloc, 'a', line_len - 2);
    try payload.appendSlice(alloc, "\r\n");
}

const FragmentedResponseReader = struct {
    payload: []const u8 = &.{},
    offset: usize = 0,
    max_chunk: usize = 1,
    zero_every: usize = 0,
    calls: usize = 0,
    buffer: [7]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(self: *@This(), payload: []const u8, max_chunk: usize, zero_every: usize) void {
        self.* = .{
            .payload = payload,
            .max_chunk = max_chunk,
            .zero_every = zero_every,
        };
        self.interface = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
        self.calls += 1;
        if (self.zero_every > 0 and self.calls % self.zero_every == 0) return 0;
        if (self.offset >= self.payload.len) return error.EndOfStream;

        for (data) |dest| {
            if (dest.len == 0) continue;
            const take = @min(dest.len, @min(self.max_chunk, self.payload.len - self.offset));
            @memcpy(dest[0..take], self.payload[self.offset..][0..take]);
            self.offset += take;
            return take;
        }
        return 0;
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = readVec(reader, &data) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        writer.advance(n);
        return n;
    }
};

const ZeroProgressReader = struct {
    calls: usize = 0,
    buffer: [1]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(self: *@This()) void {
        self.* = .{};
        self.interface = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn readVec(reader: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
        self.calls += 1;
        return 0;
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = writer;
        _ = limit;
        return readVec(reader, &.{}) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
    }
};

const ShortCompleteResponseReader = struct {
    payload: []const u8 = &.{},
    offset: usize = 0,
    zero_progress_reads: usize = 0,
    reads_after_payload: usize = 0,
    buffer: [1]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(self: *@This(), payload: []const u8, zero_progress_reads: usize) void {
        self.* = .{ .payload = payload, .zero_progress_reads = zero_progress_reads };
        self.interface = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn readVec(reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
        if (self.zero_progress_reads > 0) {
            self.zero_progress_reads -= 1;
            return 0;
        }
        if (self.offset >= self.payload.len) {
            self.reads_after_payload += 1;
            return error.ReadFailed;
        }
        for (data) |dest| {
            if (dest.len == 0) continue;
            const take = @min(dest.len, self.payload.len - self.offset);
            @memcpy(dest[0..take], self.payload[self.offset..][0..take]);
            self.offset += take;
            return take;
        }
        return 0;
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = readVec(reader, &data) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        writer.advance(n);
        return n;
    }
};

const ScriptedTlsBoundaryReader = struct {
    const EofMode = enum {
        clean,
        truncated,
    };

    source: *std.Io.Reader,
    eof_mode: EofMode,
    reads_after_payload: usize = 0,
    tls_err: ?anyerror = null,
    buffer: [plain_transport_buffer_len]u8 = undefined,
    interface: std.Io.Reader = undefined,

    fn init(self: *@This(), source: *std.Io.Reader, eof_mode: EofMode) void {
        self.* = .{
            .source = source,
            .eof_mode = eof_mode,
        };
        self.interface = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = &self.buffer,
            .seek = 0,
            .end = 0,
        };
    }

    fn readVec(reader: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("interface", reader));
        if (reader.seek == reader.end) {
            reader.seek = 0;
            reader.end = 0;
        }
        var data: [1][]u8 = .{reader.buffer[reader.end..]};
        const n = self.source.readVec(&data) catch |err| switch (err) {
            error.EndOfStream => {
                self.reads_after_payload += 1;
                if (self.eof_mode == .clean) return error.EndOfStream;
                self.tls_err = error.TlsConnectionTruncated;
                return error.ReadFailed;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        reader.end += n;
        return 0;
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = readVec(reader, &data) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        writer.advance(n);
        return n;
    }
};

fn pipeBackedTlsBoundaryReader(
    payload: []const u8,
    eof_mode: ScriptedTlsBoundaryReader.EofMode,
    transport_reader: *PlainDeadlineReader,
    boundary_reader: *ScriptedTlsBoundaryReader,
) !posix.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    errdefer closeFd(fds[0]);
    errdefer closeFd(fds[1]);

    const written = std.c.write(fds[1], payload.ptr, payload.len);
    if (written < 0 or @as(usize, @intCast(written)) != payload.len) return error.PipeWriteFailed;
    closeFd(fds[1]);

    transport_reader.init(fds[0], .{ .deadline = .{ .deadline_ms = monotonicMillis() + 1000 } });
    boundary_reader.init(&transport_reader.interface, eof_mode);
    return fds[0];
}

const ResponseSpec = struct {
    status: std.http.Status,
    body: []const u8,
    location: ?[]const u8 = null,
    content_encoding: ?[]const u8 = null,
};

const fake_recorded_calls = max_redirect_hops + 1;

const FakeResolver = struct {
    addresses: []const IpAddress,
    calls: usize = 0,
    last_host: ?[]u8 = null,
    last_port: ?u16 = null,
    deadlines: [fake_recorded_calls]?i64 = [_]?i64{null} ** fake_recorded_calls,

    fn resolver(self: *@This()) Resolver {
        return .{ .ctx = @ptrCast(self), .resolve = resolve };
    }

    fn deinit(self: *@This(), alloc: Allocator) void {
        if (self.last_host) |host| alloc.free(host);
        self.* = .{ .addresses = self.addresses };
    }

    fn resolve(raw: *anyopaque, alloc: Allocator, host: []const u8, port: u16, options: FetchOptions) anyerror![]IpAddress {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const call_index = self.calls;
        self.calls += 1;
        if (call_index < self.deadlines.len) {
            self.deadlines[call_index] = if (options.deadline) |deadline| deadline.deadline_ms else null;
        }
        if (self.last_host) |old| alloc.free(old);
        self.last_host = try alloc.dupe(u8, host);
        self.last_port = port;
        return alloc.dupe(IpAddress, self.addresses);
    }
};

const FakeConnector = struct {
    responses: []const ResponseSpec = &.{},
    err: ?anyerror = null,
    calls: usize = 0,
    last_admitted_len: ?usize = null,
    last_canonical_host: ?[]u8 = null,
    last_tls_server_name: ?[]u8 = null,
    last_host_header: ?[]u8 = null,
    last_path_query: ?[]u8 = null,
    last_first_admitted_address: ?IpAddress = null,
    last_max_body_bytes: ?usize = null,
    last_deadline_ms: ?i64 = null,
    deadlines: [fake_recorded_calls]?i64 = [_]?i64{null} ** fake_recorded_calls,
    sleep_after_first_call_ms: u64 = 0,

    fn connector(self: *@This()) Connector {
        return .{ .ctx = @ptrCast(self), .get = get };
    }

    fn deinit(self: *@This(), alloc: Allocator) void {
        if (self.last_canonical_host) |value| alloc.free(value);
        if (self.last_tls_server_name) |value| alloc.free(value);
        if (self.last_host_header) |value| alloc.free(value);
        if (self.last_path_query) |value| alloc.free(value);
        self.* = .{};
    }

    fn get(raw: *anyopaque, alloc: Allocator, target: PinnedTarget, options: FetchOptions) anyerror!ConnectorResponse {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const call_index = self.calls;
        self.calls += 1;
        self.last_admitted_len = target.admitted_addresses.len;
        self.last_first_admitted_address = if (target.admitted_addresses.len > 0)
            target.admitted_addresses[0]
        else
            null;
        self.last_max_body_bytes = options.max_body_bytes;
        if (options.deadline) |deadline| {
            self.last_deadline_ms = deadline.deadline_ms;
            if (call_index < self.deadlines.len) self.deadlines[call_index] = deadline.deadline_ms;
        }
        try replaceOwned(alloc, &self.last_canonical_host, target.url.canonical_host);
        try replaceOwned(alloc, &self.last_tls_server_name, target.tls_server_name);
        try replaceOwned(alloc, &self.last_host_header, target.host_header);
        try replaceOwned(alloc, &self.last_path_query, target.url.path_query);
        if (self.err) |err| return err;
        if (call_index == 0 and self.sleep_after_first_call_ms > 0) {
            io_mod.sleep(self.sleep_after_first_call_ms * std.time.ns_per_ms);
        }
        const index = @min(self.calls - 1, if (self.responses.len == 0) 0 else self.responses.len - 1);
        const spec = if (self.responses.len == 0) ResponseSpec{ .status = .ok, .body = "" } else self.responses[index];
        return .{
            .status = spec.status,
            .body = try alloc.dupe(u8, spec.body),
            .location = if (spec.location) |location| try alloc.dupe(u8, location) else null,
            .content_encoding = if (spec.content_encoding) |encoding| try alloc.dupe(u8, encoding) else null,
        };
    }
};

const RawResponseConnector = struct {
    payload: []const u8,

    fn connector(self: *@This()) Connector {
        return .{ .ctx = @ptrCast(self), .get = get };
    }

    fn get(raw: *anyopaque, alloc: Allocator, _: PinnedTarget, options: FetchOptions) anyerror!ConnectorResponse {
        const self: *@This() = @ptrCast(@alignCast(raw));
        var reader: std.Io.Reader = .fixed(self.payload);
        var failure_stage: FailureStage = .response_head;
        return readResponse(alloc, &reader, options.max_body_bytes, options, &failure_stage);
    }
};

fn replaceOwned(alloc: Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| alloc.free(old);
    slot.* = try alloc.dupe(u8, value);
}

fn ip(text: []const u8, port: u16) !IpAddress {
    return std.Io.net.IpAddress.parse(text, port);
}

const ScriptedDialer = struct {
    errors: []const ?anyerror,
    returned_fds: []const posix.fd_t,
    attempts: [4]IpAddress = undefined,
    deadlines: [4]?i64 = [_]?i64{null} ** 4,
    calls: usize = 0,
    cancel_after_call: ?usize = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,

    fn dialer(self: *@This()) Dialer {
        return .{ .ctx = @ptrCast(self), .connect_fn = connect };
    }

    fn connect(raw: *anyopaque, address: IpAddress, options: FetchOptions) anyerror!posix.fd_t {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const index = self.calls;
        self.calls += 1;
        self.attempts[index] = address;
        self.deadlines[index] = if (options.deadline) |deadline| deadline.deadline_ms else null;
        if (self.cancel_after_call == self.calls) {
            if (self.cancel_flag) |flag| flag.store(true, .seq_cst);
        }
        if (index < self.errors.len) {
            if (self.errors[index]) |err| return err;
        }
        if (index < self.returned_fds.len) return self.returned_fds[index];
        return error.ConnectionFailed;
    }
};

const ScriptedPoller = struct {
    result: enum { ready, interrupted_once, system_resources, network_down } = .ready,
    revents: i16 = 0,
    calls: usize = 0,
    observed_events: i16 = 0,
    observed_timeout_ms: i32 = 0,

    fn poller(self: *@This()) Poller {
        return .{ .ctx = @ptrCast(self), .poll_fn = poll };
    }

    fn poll(raw: ?*anyopaque, fds: []posix.pollfd, timeout_ms: i32) PollError!usize {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.observed_events = fds[0].events;
        self.observed_timeout_ms = timeout_ms;
        return switch (self.result) {
            .ready => blk: {
                fds[0].revents = self.revents;
                break :blk 1;
            },
            .interrupted_once => if (self.calls == 1)
                error.Interrupted
            else blk: {
                fds[0].revents = self.revents;
                break :blk 1;
            },
            .system_resources => error.SystemResources,
            .network_down => error.NetworkDown,
        };
    }
};

fn noOpSignalHandler(_: posix.SIG) callconv(.c) void {}

const PollSignalStorm = struct {
    target: std.c.pthread_t,
    stop: *std.atomic.Value(bool),

    fn run(self: @This()) void {
        for (0..300) |_| {
            io_mod.sleep(10 * std.time.ns_per_ms);
            if (self.stop.load(.seq_cst)) return;
            _ = std.c.pthread_kill(self.target, posix.SIG.USR1);
        }
    }
};

const InterruptingRead = struct {
    cancel_flag: *std.atomic.Value(bool),
    calls: usize = 0,

    fn syscall(self: *@This()) ReadSyscall {
        return .{ .ctx = @ptrCast(self), .read_fn = read };
    }

    fn read(raw: ?*anyopaque, _: posix.fd_t, _: []u8) RawSyscallResult {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.cancel_flag.store(true, .seq_cst);
        return .{ .failure = .INTR };
    }
};
