//! GitHub Copilot provider: RFC 8628 device-flow OAuth against
//! github.com (or a GitHub Enterprise domain), a 0600 token cache at
//! `~/.fx/copilot-auth.json`, and short-lived Copilot bearer tokens exchanged
//! via `copilot_internal/v2/token`. Chat traffic is served THROUGH the
//! Anthropic Messages transport (`anthropic_messages.streamWithCallOptions`)
//! with Copilot editor headers merged in — no duplicated SSE logic.
//!
//! Wire reference: oh-my-pi `utils/oauth/github-copilot.ts`,
//! `utils/oauth/device-code.ts`, `providers/github-copilot-headers.ts`.
const std = @import("std");
const anthropic_messages = @import("anthropic_messages.zig");
const gateway_client = @import("client.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const model_provider = @import("../core/config/model_provider.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

/// VS Code Copilot Chat OAuth app id.
pub const client_id = "Iv1.b507a08c87ecfe98";
pub const oauth_scope = "read:user";
pub const default_enterprise_domain = "github.com";
/// Fallback chat origin when the access token carries no proxy endpoint.
pub const default_chat_base_url = "https://api.individual.githubcopilot.com";

pub const editor_user_agent = "GitHubCopilotChat/0.35.0";
pub const editor_version = "vscode/1.99.0";
pub const editor_plugin_version = "copilot-chat/0.35.0";
pub const copilot_integration_id = "vscode-chat";

const env_copilot_github_token = "COPILOT_GITHUB_TOKEN";
pub const cache_dir_name = ".fx";
pub const cache_file_name = "copilot-auth.json";
const cache_lock_name = "copilot-auth.lock";
/// Stored expiry already includes this safety buffer (pi parity).
const refresh_safety_buffer_ms: i64 = 5 * 60 * 1000;
const lock_timeout_ms: u64 = 10_000;
const max_auth_body_bytes: usize = 256 * 1024;
const auth_connect_timeout_ms: i64 = 30_000;
const min_poll_interval_ms: u64 = 1000;
const default_poll_interval_ms: u64 = 5000;
/// Permanent increment after `slow_down` (RFC 8628 section 3.5).
const slow_down_increment_ms: u64 = 5000;

// ---------------------------------------------------------------------------
// Credential record persistence
// ---------------------------------------------------------------------------

/// Mirrors pi's oauth record shape:
/// `{type:"oauth", refresh, access, expires(ms), enterpriseUrl?}`.
pub const CredentialRecord = struct {
    /// Long-lived GitHub GHU refresh credential (`ghu_...`).
    refresh_token: []u8,
    /// Short-lived Copilot bearer blob (`tid=...;exp=...`).
    access_token: []u8,
    /// Wall-clock milliseconds after which `access_token` must be refreshed.
    expires_ms: i64,
    enterprise_domain: ?[]u8 = null,

    pub fn deinit(self: *CredentialRecord, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.refresh_token);
        secret.zeroAndFree(alloc, self.access_token);
        if (self.enterprise_domain) |domain| alloc.free(domain);
        self.* = undefined;
    }
};

pub fn homeDir() ?[]const u8 {
    return io_mod.getenv("HOME") orelse io_mod.getenv("USERPROFILE");
}

pub fn cacheFilePathAlloc(alloc: Allocator) ![]u8 {
    const home = homeDir() orelse return error.CopilotHomeUnavailable;
    return std.fs.path.join(alloc, &.{ home, cache_dir_name, cache_file_name });
}

fn renderCredentialJson(alloc: Allocator, record: *const CredentialRecord) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"type\":\"oauth\",\"refresh\":");
    try std.json.Stringify.value(record.refresh_token, .{}, writer);
    try writer.writeAll(",\"access\":");
    try std.json.Stringify.value(record.access_token, .{}, writer);
    try writer.print(",\"expires\":{d}", .{record.expires_ms});
    if (record.enterprise_domain) |domain| {
        try writer.writeAll(",\"enterpriseUrl\":");
        try std.json.Stringify.value(domain, .{}, writer);
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const unwrapped = value orelse return null;
    if (unwrapped != .string) return null;
    return unwrapped.string;
}

pub fn parseCredentialJson(alloc: Allocator, text: []const u8) !CredentialRecord {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CopilotCredentialInvalid,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.CopilotCredentialInvalid;
    const object = parsed.value.object;

    const record_type = optionalString(object.get("type")) orelse return error.CopilotCredentialInvalid;
    if (!std.mem.eql(u8, record_type, "oauth")) return error.CopilotCredentialInvalid;
    const refresh = optionalString(object.get("refresh")) orelse return error.CopilotCredentialInvalid;
    const access = optionalString(object.get("access")) orelse return error.CopilotCredentialInvalid;
    const expires_value = object.get("expires") orelse return error.CopilotCredentialInvalid;
    if (expires_value != .integer) return error.CopilotCredentialInvalid;

    var enterprise_domain: ?[]u8 = null;
    errdefer if (enterprise_domain) |domain| alloc.free(domain);
    if (object.get("enterpriseUrl")) |value| {
        if (optionalString(value)) |domain| {
            enterprise_domain = try alloc.dupe(u8, domain);
        }
    }

    return .{
        .refresh_token = try alloc.dupe(u8, refresh),
        .access_token = try alloc.dupe(u8, access),
        .expires_ms = expires_value.integer,
        .enterprise_domain = enterprise_domain,
    };
}

/// Atomically replaces `~/.fx/copilot-auth.json` through the durable private
/// helpers: the `.fx` directory is created 0700 when missing and the file is
/// swapped in with 0600 permissions plus fsync coverage.
pub fn saveCredentialRecord(alloc: Allocator, record: *const CredentialRecord) !void {
    const path = try cacheFilePathAlloc(alloc);
    defer alloc.free(path);
    const home = std.fs.path.dirname(path).?;
    const grandparent = std.fs.path.dirname(home) orelse return error.CopilotCachePathInvalid;

    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.fs.path.basename(home));
    defer dir.close();

    const json = try renderCredentialJson(alloc, record);
    defer alloc.free(json);
    try io_mod.durableReplaceVerified(alloc, &dir, cache_file_name, json);
}

pub fn loadCredentialRecord(alloc: Allocator) !?CredentialRecord {
    const path = try cacheFilePathAlloc(alloc);
    defer alloc.free(path);

    const zio = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(zio);
    const text = io_mod.readFileToEnd(alloc, &file, max_auth_body_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CopilotCredentialUnreadable,
    };
    defer alloc.free(text);
    return try parseCredentialJson(alloc, text);
}

// ---------------------------------------------------------------------------
// Device flow (RFC 8628)
// ---------------------------------------------------------------------------

pub const DeviceCodeGrant = struct {
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    expires_in_s: i64,
    interval_s: i64,

    pub fn deinit(self: *DeviceCodeGrant, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.device_code);
        alloc.free(self.user_code);
        alloc.free(self.verification_uri);
        self.* = undefined;
    }
};

/// Normalizes an optional GitHub Enterprise input: URL-parse (prepending
/// `https://` when no scheme is present), take the hostname; empty becomes
/// `github.com`.
pub fn normalizeEnterpriseDomain(alloc: Allocator, raw: []const u8) ![]u8 {
    var work: std.ArrayList(u8) = .empty;
    defer work.deinit(alloc);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n/");
    if (trimmed.len == 0) return alloc.dupe(u8, default_enterprise_domain);
    if (std.mem.indexOf(u8, trimmed, "://") == null) {
        try work.appendSlice(alloc, "https://");
    }
    try work.appendSlice(alloc, trimmed);
    const uri = std.Uri.parse(work.items) catch return error.CopilotEnterpriseDomainInvalid;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
        return error.CopilotEnterpriseDomainInvalid;
    }
    const host = uri.host orelse return error.CopilotEnterpriseDomainInvalid;
    const component = switch (host) {
        .raw => |raw_host| raw_host,
        .percent_encoded => |encoded| encoded,
    };
    return alloc.dupe(u8, component);
}

fn formEncodeValue(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(byte),
            else => try writer.print("%{X:0>2}", .{byte}),
        }
    }
}

const device_code_grant_type = "urn:ietf:params:oauth:grant-type:device_code";

fn deviceCodeRequestUrl(alloc: Allocator, domain: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "https://{s}/login/device/code", .{domain});
}

fn accessTokenPollUrl(alloc: Allocator, domain: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "https://{s}/login/oauth/access_token", .{domain});
}

/// Step 1: obtain a device + user code pair for the browser authorization.
pub fn requestDeviceCode(
    alloc: Allocator,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    domain: []const u8,
) !DeviceCodeGrant {
    const url = try deviceCodeRequestUrl(alloc, domain);
    defer alloc.free(url);
    var body_writer: std.Io.Writer.Allocating = .init(alloc);
    defer body_writer.deinit();
    try body_writer.writer.writeAll("client_id=");
    try formEncodeValue(&body_writer.writer, client_id);
    try body_writer.writer.writeAll("&scope=read:user");

    var reply = try performAuthRequest(
        alloc,
        .POST,
        url,
        body_writer.written(),
        null,
        &.{},
        cancel_flag,
        deadline,
    );
    defer reply.deinit(alloc);
    if (reply.status != .ok) return error.CopilotDeviceCodeRejected;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, reply.body, .{}) catch
        return error.CopilotDeviceCodeResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CopilotDeviceCodeResponseInvalid;
    const object = parsed.value.object;

    // Strict field validation per the reference client.
    const device_code = optionalString(object.get("device_code")) orelse
        return error.CopilotDeviceCodeResponseInvalid;
    const user_code = optionalString(object.get("user_code")) orelse
        return error.CopilotDeviceCodeResponseInvalid;
    const verification_uri = optionalString(object.get("verification_uri")) orelse
        return error.CopilotDeviceCodeResponseInvalid;
    const expires_value = object.get("expires_in") orelse return error.CopilotDeviceCodeResponseInvalid;
    if (expires_value != .integer or expires_value.integer <= 0) {
        return error.CopilotDeviceCodeResponseInvalid;
    }
    const interval_s: i64 = blk: {
        if (object.get("interval")) |interval_value| {
            if (interval_value == .integer and interval_value.integer > 0) break :blk interval_value.integer;
        }
        break :blk 5;
    };

    // Security quirk from the reference client: never surface a
    // verification_uri that is not an absolute http(s) URL.
    const parsed_uri = std.Uri.parse(verification_uri) catch return error.CopilotUntrustedVerificationUri;
    if (!std.ascii.eqlIgnoreCase(parsed_uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(parsed_uri.scheme, "https"))
    {
        return error.CopilotUntrustedVerificationUri;
    }

    return .{
        .device_code = try alloc.dupe(u8, device_code),
        .user_code = try alloc.dupe(u8, user_code),
        .verification_uri = try alloc.dupe(u8, verification_uri),
        .expires_in_s = expires_value.integer,
        .interval_s = interval_s,
    };
}

fn pollIntervalMs(interval_s: i64) u64 {
    if (interval_s <= 0) return min_poll_interval_ms;
    const scaled: u64 = @intCast(interval_s * std.time.ms_per_s);
    return @max(scaled, min_poll_interval_ms);
}

pub const PollOutcome = union(enum) {
    /// Owned long-lived GHU access token.
    access_token: []u8,
    pending,
    slow_down,
};

pub const PollVerdict = union(enum) {
    outcome: PollOutcome,
    fatal,
};

fn interpretPollResponse(alloc: Allocator, body: []const u8) !PollVerdict {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return error.CopilotDeviceTokenResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CopilotDeviceTokenResponseInvalid;
    const object = parsed.value.object;

    if (object.get("access_token")) |token_value| {
        if (token_value == .string and token_value.string.len > 0) {
            return .{ .outcome = .{ .access_token = try alloc.dupe(u8, token_value.string) } };
        }
    }
    if (object.get("error")) |error_value| {
        if (optionalString(error_value)) |error_name| {
            if (std.mem.eql(u8, error_name, "authorization_pending")) return .{ .outcome = .pending };
            if (std.mem.eql(u8, error_name, "slow_down")) return .{ .outcome = .slow_down };
            return .fatal;
        }
    }
    return error.CopilotDeviceTokenResponseInvalid;
}

/// Step 2: poll until the user authorizes. First poll fires immediately; the
/// interval defaults to 5s (min 1s) and grows permanently by 5s on slow_down.
pub fn awaitAccessToken(
    alloc: Allocator,
    grant: *const DeviceCodeGrant,
    domain: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) ![]u8 {
    const zio = io_mod.getIo();
    const url = try accessTokenPollUrl(alloc, domain);
    defer alloc.free(url);
    var body_writer: std.Io.Writer.Allocating = .init(alloc);
    defer body_writer.deinit();
    try body_writer.writer.writeAll("client_id=");
    try formEncodeValue(&body_writer.writer, client_id);
    try body_writer.writer.writeAll("&device_code=");
    try formEncodeValue(&body_writer.writer, grant.device_code);
    try body_writer.writer.writeAll("&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code");
    const form_body = body_writer.written();

    var interval_ms = pollIntervalMs(grant.interval_s);
    const started_ns = std.Io.Clock.Timestamp.now(zio, .awake).raw.toNanoseconds();
    const expires_ns: ?i128 = if (grant.expires_in_s > 0)
        started_ns + @as(i128, grant.expires_in_s) * std.time.ns_per_s
    else
        null;

    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (expires_ns) |limit| {
            const now_ns = std.Io.Clock.Timestamp.now(zio, .awake).raw.toNanoseconds();
            if (now_ns >= limit) return error.CopilotDeviceFlowTimedOut;
        }

        var reply = try performAuthRequest(alloc, .POST, url, form_body, null, &.{}, cancel_flag, deadline);
        defer reply.deinit(alloc);
        switch (try interpretPollResponse(alloc, reply.body)) {
            .outcome => |outcome| switch (outcome) {
                .access_token => |token| return token,
                .pending => {},
                .slow_down => interval_ms += slow_down_increment_ms,
            },
            .fatal => return error.CopilotDeviceFlowDenied,
        }
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        try sleepCancellable(interval_ms, cancel_flag);
    }
}

fn sleepCancellable(total_ms: u64, cancel_flag: *std.atomic.Value(bool)) !void {
    var remaining_ms = total_ms;
    while (remaining_ms > 0) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const chunk_ms = @min(remaining_ms, 100);
        io_mod.sleep(chunk_ms * std.time.ns_per_ms);
        remaining_ms -= chunk_ms;
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
}

// ---------------------------------------------------------------------------
// Copilot token exchange
// ---------------------------------------------------------------------------

pub const CopilotToken = struct {
    /// Opaque `tid=...;exp=...` blob used directly as the chat Bearer value.
    token: []u8,
    expires_at_s: i64,

    pub fn deinit(self: *CopilotToken, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        self.* = undefined;
    }
};

fn copilotTokenExchangeUrl(alloc: Allocator, domain: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "https://api.{s}/copilot_internal/v2/token", .{domain});
}

/// Step 3: exchange the long-lived GHU for the short-lived Copilot API token.
pub fn exchangeCopilotToken(
    alloc: Allocator,
    github_access_token: []const u8,
    domain: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) !CopilotToken {
    const url = try copilotTokenExchangeUrl(alloc, domain);
    defer alloc.free(url);
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{github_access_token});
    const reply_headers = [1]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
    };
    var reply = try performAuthRequest(
        alloc,
        .GET,
        url,
        null,
        authorization,
        &reply_headers,
        cancel_flag,
        deadline,
    );
    defer reply.deinit(alloc);
    if (reply.status != .ok) return error.CopilotTokenExchangeFailed;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, reply.body, .{}) catch
        return error.CopilotTokenResponseInvalid;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CopilotTokenResponseInvalid;
    const object = parsed.value.object;
    const token = optionalString(object.get("token")) orelse return error.CopilotTokenResponseInvalid;
    const expires_value = object.get("expires_at") orelse return error.CopilotTokenResponseInvalid;
    if (expires_value != .integer) return error.CopilotTokenResponseInvalid;
    return .{
        .token = try alloc.dupe(u8, token),
        .expires_at_s = expires_value.integer,
    };
}

/// Derives the chat base URL from the proxy endpoint embedded in the access
/// token: `proxy-ep=proxy.individual.githubcopilot.com` becomes
/// `https://api.individual.githubcopilot.com`. Falls back to the default.
pub fn baseUrlFromAccessToken(alloc: Allocator, access_token: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, access_token, "proxy-ep=")) |start| {
        const host_start = start + "proxy-ep=".len;
        const rest = access_token[host_start..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const proxy_host = rest[0..end];
        // The token embeds `proxy.<host>`; chat traffic uses `api.<host>`.
        if (std.mem.startsWith(u8, proxy_host, "proxy.")) {
            return std.fmt.allocPrint(alloc, "https://api.{s}", .{proxy_host["proxy.".len..]});
        }
        if (proxy_host.len > 0) {
            return std.fmt.allocPrint(alloc, "https://{s}", .{proxy_host});
        }
    }
    return alloc.dupe(u8, default_chat_base_url);
}

/// Resolves the Bearer value for one chat request, in precedence order:
/// explicit key handed down by core, `COPILOT_GITHUB_TOKEN`, cached Copilot
/// token, then a locked refresh via `copilot_internal/v2/token`. The caller
/// owns and must zero-free the returned bytes.
pub fn resolveBearerToken(
    alloc: Allocator,
    explicit_key: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) ![]u8 {
    if (explicit_key.len > 0) return alloc.dupe(u8, explicit_key);
    if (io_mod.getenv(env_copilot_github_token)) |env_token| {
        if (env_token.len > 0) return alloc.dupe(u8, env_token);
    }

    var record = (try loadCredentialRecord(alloc)) orelse return error.CopilotNotSignedIn;
    defer record.deinit(alloc);
    if (io_mod.milliTimestamp() < record.expires_ms) {
        return alloc.dupe(u8, record.access_token);
    }

    // Expired: refresh under the advisory lock so concurrent instances do not
    // stampede the exchange endpoint; the loser re-reads merged state first.
    const path = try cacheFilePathAlloc(alloc);
    defer alloc.free(path);
    const home = std.fs.path.dirname(path).?;
    const grandparent = std.fs.path.dirname(home) orelse return error.CopilotCachePathInvalid;
    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.fs.path.basename(home));
    defer dir.close();

    var lock = try io_mod.acquireTimedAdvisoryLockCancellable(&dir, cache_lock_name, lock_timeout_ms, cancel_flag);
    defer lock.release();

    var latest = (try loadCredentialRecord(alloc)) orelse return error.CopilotNotSignedIn;
    defer latest.deinit(alloc);
    if (io_mod.milliTimestamp() < latest.expires_ms) {
        return alloc.dupe(u8, latest.access_token);
    }

    const domain = if (latest.enterprise_domain) |domain|
        domain
    else
        default_enterprise_domain;
    var refreshed = try exchangeCopilotToken(alloc, latest.refresh_token, domain, cancel_flag, deadline);
    defer refreshed.deinit(alloc);

    var updated: CredentialRecord = .{
        .refresh_token = try alloc.dupe(u8, latest.refresh_token),
        .access_token = try alloc.dupe(u8, refreshed.token),
        .expires_ms = refreshed.expires_at_s * std.time.ms_per_s - refresh_safety_buffer_ms,
        .enterprise_domain = if (latest.enterprise_domain) |existing| try alloc.dupe(u8, existing) else null,
    };
    errdefer updated.deinit(alloc);
    try saveCredentialRecord(alloc, &updated);
    return alloc.dupe(u8, refreshed.token);
}

// ---------------------------------------------------------------------------
// Chat transport (wrapping the Anthropic Messages internals)
// ---------------------------------------------------------------------------

pub fn expectedCredentialSource(descriptor: *const model_provider.Descriptor) types.CredentialSource {
    return .{ .provider_api_key = descriptor.id };
}

/// Builds the transport for the GitHub Copilot descriptor. Request bodies are
/// byte-identical to plain Anthropic Messages; only headers and the resolved
/// bearer/endpoint differ.
pub fn providerFor(descriptor: *const model_provider.Descriptor) stream_provider.Provider {
    return .{
        .context = @constCast(descriptor),
        .observes_gateway_usage = descriptor.observes_gateway_usage,
        .build_fn = buildViaDescriptor,
        .stream_fn = streamViaDescriptor,
    };
}

fn buildViaDescriptor(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.BuildRequest,
) anyerror![]u8 {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));
    return anthropic_messages.buildRequestBody(descriptor, alloc, request);
}

/// Last-message role decides X-Initiator: anything not ending in a user turn
/// means the agent is driving (pi parity).
fn initiatorFromPayload(payload: []const u8) []const u8 {
    const assistant_index = std.mem.lastIndexOf(u8, payload, "\"role\":\"assistant\"");
    const user_index = std.mem.lastIndexOf(u8, payload, "\"role\":\"user\"");
    if (assistant_index == null and user_index == null) return "user";
    if (assistant_index != null and (user_index == null or assistant_index.? > user_index.?)) {
        return "agent";
    }
    return "user";
}

fn payloadHasImage(payload: []const u8) bool {
    return std.mem.indexOf(u8, payload, "{\"type\":\"image\"") != null;
}

fn resolveChatUrl(alloc: Allocator, descriptor: *const model_provider.Descriptor, bearer: []const u8) ![]u8 {
    var name_buf: [64]u8 = undefined;
    if (anthropic_messages.e2eEnvName(&name_buf, model_provider.providerSlug(descriptor.id), "_CHAT_URL")) |name| {
        if (io_mod.getenv(name)) |override| {
            if (!gateway_client.isLoopbackHttpUrl(override)) return error.CopilotInvalidE2EEndpoint;
            return alloc.dupe(u8, override);
        }
    }
    const base = baseUrlFromAccessToken(alloc, bearer) catch
        try alloc.dupe(u8, descriptor.base_url);
    defer alloc.free(base);
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrint(alloc, "{s}/v1/messages", .{trimmed});
}

fn streamViaDescriptor(
    context: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.Request,
) !stream_provider.Result {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (request.credential_source) |source| {
        const expected: types.CredentialSource = .{ .provider_api_key = descriptor.id };
        if (!source.eql(expected)) return error.CopilotCredentialRequired;
    }

    const bounded_deadline: ?std.Io.Clock.Timestamp = request.deadline;
    const bearer = try resolveBearerToken(alloc, request.api_key, request.cancel_flag, bounded_deadline);
    defer secret.zeroAndFree(alloc, bearer);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    const endpoint_url = try resolveChatUrl(alloc, descriptor, bearer);
    defer alloc.free(endpoint_url);

    const dynamic: [3]std.http.Header = .{
        .{ .name = "X-Initiator", .value = initiatorFromPayload(request.payload) },
        .{ .name = "Openai-Intent", .value = "conversation-edits" },
        .{
            .name = "Copilot-Vision-Request",
            .value = if (payloadHasImage(request.payload)) "true" else "false",
        },
    };
    // The vision header is only meaningful when images are present.
    const extra_headers: []const std.http.Header = if (payloadHasImage(request.payload))
        &dynamic
    else
        dynamic[0..2];

    return anthropic_messages.streamWithCallOptions(descriptor, alloc, request, .{
        .endpoint_url = endpoint_url,
        .extra_headers = extra_headers,
        .force_bearer = true,
    });
}

// ---------------------------------------------------------------------------
// Shared bounded HTTP for auth endpoints
// ---------------------------------------------------------------------------

const HttpReply = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *HttpReply, alloc: Allocator) void {
        alloc.free(self.body);
        self.body = &.{};
    }
};

const AuthFetchOperation = struct {
    alloc: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    authorization: ?[]const u8,
    extra_headers: []const std.http.Header,

    pub fn run(self: *@This()) !HttpReply {
        const uri = try std.Uri.parse(self.url);
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        var request = try client.request(self.method, uri, .{
            .headers = .{
                .content_type = if (self.payload != null)
                    .{ .override = "application/x-www-form-urlencoded" }
                else
                    .omit,
                .authorization = if (self.authorization) |value|
                    .{ .override = value }
                else
                    .omit,
                .accept_encoding = .omit,
                .user_agent = .{ .override = editor_user_agent },
            },
            .extra_headers = self.extra_headers,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();
        if (self.payload) |payload| {
            request.transfer_encoding = .{ .content_length = payload.len };
            var send_buffer: [8192]u8 = undefined;
            var body_writer = try request.sendBodyUnflushed(&send_buffer);
            try body_writer.writer.writeAll(payload);
            try body_writer.end();
        } else {
            try request.sendBodiless();
        }
        if (request.connection) |connection| try connection.flush();

        var response = try request.receiveHead(&.{});
        var transfer_buffer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        const body = reader.allocRemaining(self.alloc, .limited(max_auth_body_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => return error.CopilotAuthResponseTooLarge,
            else => return err,
        };
        if (body.len > max_auth_body_bytes) {
            self.alloc.free(body);
            return error.CopilotAuthResponseTooLarge;
        }
        return .{ .status = response.head.status, .body = body };
    }
};

fn performAuthRequest(
    alloc: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    authorization: ?[]const u8,
    extra_headers: []const std.http.Header,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) !HttpReply {
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(auth_connect_timeout_ms),
    });
    if (deadline) |limit| {
        if (std.Io.Clock.Timestamp.compare(limit, .lt, connect_deadline)) {
            connect_deadline = limit;
        }
    }
    var operation = AuthFetchOperation{
        .alloc = alloc,
        .method = method,
        .url = url,
        .payload = payload,
        .authorization = authorization,
        .extra_headers = extra_headers,
    };
    return gateway_client.runBoundedHttpOperation(
        HttpReply,
        alloc,
        cancel_flag,
        connect_deadline,
        &operation,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "credential record json roundtrips all fields" {
    const alloc = testing.allocator;
    var original = CredentialRecord{
        .refresh_token = try alloc.dupe(u8, "ghu_refresh"),
        .access_token = try alloc.dupe(u8, "tid=abc;exp=1799999999"),
        .expires_ms = 1_799_999_399_000,
        .enterprise_domain = try alloc.dupe(u8, "ghe.corp"),
    };
    defer original.deinit(alloc);
    const json = try renderCredentialJson(alloc, &original);
    defer alloc.free(json);
    var restored = try parseCredentialJson(alloc, json);
    defer restored.deinit(alloc);

    try testing.expectEqualStrings(original.refresh_token, restored.refresh_token);
    try testing.expectEqualStrings(original.access_token, restored.access_token);
    try testing.expectEqual(original.expires_ms, restored.expires_ms);
    try testing.expectEqualStrings(original.enterprise_domain.?, restored.enterprise_domain.?);
}

test "credential record without enterprise url roundtrips" {
    const alloc = testing.allocator;
    var original = CredentialRecord{
        .refresh_token = try alloc.dupe(u8, "ghu_x"),
        .access_token = try alloc.dupe(u8, "tid=y"),
        .expires_ms = 42,
    };
    defer original.deinit(alloc);
    const json = try renderCredentialJson(alloc, &original);
    defer alloc.free(json);
    var restored = try parseCredentialJson(alloc, json);
    defer restored.deinit(alloc);
    try testing.expect(restored.enterprise_domain == null);
    try testing.expectEqualStrings("{\"type\":\"oauth\",\"refresh\":\"ghu_x\",\"access\":\"tid=y\",\"expires\":42}", json);
}

/// Installs a process-wide environ map pointing HOME at `home`. The map is
/// heap-allocated with the c allocator and intentionally never freed so the
/// global environ pointer stays valid for the whole test process (other
/// modules' getenv calls run after this test frame ends).
const TestHome = struct {
    map: std.process.Environ.Map,

    fn install(home: ?[]const u8) !*TestHome {
        const self = try std.heap.c_allocator.create(TestHome);
        errdefer std.heap.c_allocator.destroy(self);
        self.* = .{ .map = std.process.Environ.Map.init(std.heap.c_allocator) };
        if (home) |value| try self.map.put("HOME", value);
        io_mod.setEnvironMap(&self.map);
        return self;
    }
};
test "token cache roundtrips through temp HOME with private permissions" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    _ = try TestHome.install(home);

    var record = CredentialRecord{
        .refresh_token = try alloc.dupe(u8, "ghu_roundtrip"),
        .access_token = try alloc.dupe(u8, "tid=roundtrip;exp=999"),
        .expires_ms = 1234567890,
    };
    defer record.deinit(alloc);
    try saveCredentialRecord(alloc, &record);

    const file_stat = try tmp.dir.statFile(io_mod.getIo(), ".fx/copilot-auth.json", .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o600), file_stat.permissions.toMode() & 0o777);
    const dir_stat = try tmp.dir.statFile(io_mod.getIo(), ".fx", .{ .follow_symlinks = false });
    try testing.expectEqual(@as(u32, 0o700), dir_stat.permissions.toMode() & 0o777);

    var loaded = (try loadCredentialRecord(alloc)) orelse return error.TestUnexpectedResult;
    defer loaded.deinit(alloc);
    try testing.expectEqualStrings(record.refresh_token, loaded.refresh_token);
    try testing.expectEqualStrings(record.access_token, loaded.access_token);
    try testing.expectEqual(record.expires_ms, loaded.expires_ms);
}

test "loadCredentialRecord returns null when cache is absent" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    _ = try TestHome.install(home);
    try testing.expect((try loadCredentialRecord(alloc)) == null);
}

test "env token bypasses the cache without touching disk" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const test_home = try TestHome.install(home);
    try test_home.map.put("COPILOT_GITHUB_TOKEN", "ghu_env_bypass");

    var cancelled = std.atomic.Value(bool).init(false);
    const bearer = try resolveBearerToken(alloc, "", &cancelled, null);
    defer secret.zeroAndFree(alloc, bearer);
    try testing.expectEqualStrings("ghu_env_bypass", bearer);
    // Nothing was written under the temp HOME.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), ".fx/copilot-auth.json", .{}));
}

test "poll response classification matches reference semantics" {
    const alloc = testing.allocator;
    {
        var result = try interpretPollResponse(
            alloc,
            "{\"access_token\":\"ghu_ok\",\"token_type\":\"bearer\",\"scope\":\"read:user\"}",
        );
        defer cleanupInterpretResult(alloc, &result);
        try testing.expectEqualStrings("ghu_ok", result.outcome.access_token);
    }
    {
        var result = try interpretPollResponse(alloc, "{\"error\":\"authorization_pending\"}");
        defer cleanupInterpretResult(alloc, &result);
        try testing.expect(result.outcome == .pending);
    }
    {
        var result = try interpretPollResponse(alloc, "{\"error\":\"slow_down\"}");
        defer cleanupInterpretResult(alloc, &result);
        try testing.expect(result.outcome == .slow_down);
    }
    {
        var result = try interpretPollResponse(alloc, "{\"error\":\"expired_token\",\"error_description\":\"gone\"}");
        defer cleanupInterpretResult(alloc, &result);
        try testing.expect(result == .fatal);
    }
    try testing.expectError(error.CopilotDeviceTokenResponseInvalid, interpretPollResponse(alloc, "{}"));
}

fn cleanupInterpretResult(alloc: Allocator, result: anytype) void {
    switch (result.*) {
        .outcome => |outcome| switch (outcome) {
            .access_token => |token| secret.zeroAndFree(alloc, token),
            else => {},
        },
        .fatal => {},
    }
}

test "poll interval enforces the one-second floor" {
    try testing.expectEqual(@as(u64, 1000), pollIntervalMs(0));
    try testing.expectEqual(@as(u64, 1000), pollIntervalMs(1));
    try testing.expectEqual(@as(u64, 5000), pollIntervalMs(5));
}

test "enterprise domains normalize through URL parsing" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "", "/", "github.com", "https://github.com" }) |input| {
        const domain = try normalizeEnterpriseDomain(alloc, input);
        defer alloc.free(domain);
        try testing.expectEqualStrings("github.com", domain);
    }
    const ghe = try normalizeEnterpriseDomain(alloc, "ghe.corp.example/subpath");
    defer alloc.free(ghe);
    try testing.expectEqualStrings("ghe.corp.example", ghe);
    try testing.expectError(error.CopilotEnterpriseDomainInvalid, normalizeEnterpriseDomain(alloc, "ftp://bad"));
}

test "base url derives from proxy-ep with api prefix swap" {
    const alloc = testing.allocator;
    const token = "tid=abc;exp=999;proxy-ep=proxy.individual.githubcopilot.com;sku=copilot_chat";
    const url = try baseUrlFromAccessToken(alloc, token);
    defer alloc.free(url);
    try testing.expectEqualStrings("https://api.individual.githubcopilot.com", url);

    const fallback = try baseUrlFromAccessToken(alloc, "tid=abc;exp=999");
    defer alloc.free(fallback);
    try testing.expectEqualStrings(default_chat_base_url, fallback);
}

test "payload header heuristics track last role and image presence" {
    try testing.expectEqualStrings("user", initiatorFromPayload("[{\"role\":\"user\"}]"));
    try testing.expectEqualStrings("agent", initiatorFromPayload(
        "[{\"role\":\"user\"},{\"role\":\"assistant\"}]",
    ));
    try testing.expectEqualStrings("agent", initiatorFromPayload(
        "[{\"role\":\"assistant\"},{\"role\":\"tool_result\"}]",
    ));
    try testing.expect(!payloadHasImage("{\"messages\":[{\"role\":\"user\"}]}"));
    try testing.expect(payloadHasImage(
        "{\"messages\":[{\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\"}}]}]}",
    ));
}

test "wrong credential source is rejected before network I/O" {
    const alloc = testing.allocator;
    const descriptor = model_provider.descriptors[@intFromEnum(model_provider.ProviderId.github_copilot)];
    var delivery = stream_provider.DeliveryCertainty.init();
    var attempt_evidence: stream_provider.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);

    var capture: TestCapture = .{};
    defer capture.deinit(alloc);
    const provider = providerFor(&descriptor);
    const result = provider.stream(alloc, .{
        .api_key = "",
        .credential_source = .{ .provider_api_key = .anthropic },
        .team = null,
        .model = "claude-opus-4-6",
        .retry_count = 0,
        .chat_url = "https://api.individual.githubcopilot.com/v1/messages",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &attempt_evidence,
        .callback_ctx = &capture,
        .on_content_chunk = TestCapture.append,
        .on_tool_start = null,
        .on_reasoning_chunk = null,
        .cancel_flag = &cancelled,
    });
    try testing.expectError(error.CopilotCredentialRequired, result);
    try testing.expectEqual(
        stream_provider.DeliveryCertainty.State.definitely_unsent,
        delivery.load(),
    );
}

const TestCapture = struct {
    chunks: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn deinit(self: *TestCapture, alloc: Allocator) void {
        self.chunks.deinit(alloc);
    }

    fn append(raw: *anyopaque, chunk: []const u8) void {
        const self: *TestCapture = @ptrCast(@alignCast(raw));
        self.chunks.appendSlice(testing.allocator, chunk) catch {
            self.failed = true;
        };
    }
};
