const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length]u8;

pub const CacheScope = enum {
    private,
    public,
};

pub const Capability = enum {
    tools_list,
    resources_list,
    resource_templates_list,
    resource_read,
    prompts_list,
    prompt_get,
    completion,
};

pub const CacheKey = struct {
    server_identity: Digest,
    protocol_version: Digest,
    capability: Capability,
    normalized_arguments: Digest,
    private_auth_identity: ?Digest,

    pub fn eql(left: CacheKey, right: CacheKey) bool {
        return std.mem.eql(u8, &left.server_identity, &right.server_identity) and
            std.mem.eql(u8, &left.protocol_version, &right.protocol_version) and
            left.capability == right.capability and
            std.mem.eql(u8, &left.normalized_arguments, &right.normalized_arguments) and
            optionalDigestEql(left.private_auth_identity, right.private_auth_identity);
    }
};

const CacheKeyInput = struct {
    server_identity: []const u8,
    protocol_version: []const u8,
    capability: Capability,
    normalized_arguments: []const u8,
    scope: CacheScope,
    auth_identity: Digest,
};

pub fn buildCacheKey(input: CacheKeyInput) CacheKey {
    return .{
        .server_identity = digest(input.server_identity),
        .protocol_version = digest(input.protocol_version),
        .capability = input.capability,
        .normalized_arguments = digest(input.normalized_arguments),
        .private_auth_identity = if (input.scope == .private)
            input.auth_identity
        else
            null,
    };
}

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Produces an opaque partition identity without retaining header names or
/// credential values. Header order is significant because it is part of the
/// effective request identity.
pub fn authIdentity(headers: []const Header) Digest {
    var hasher = Sha256.init(.{});
    for (headers) |header| {
        hashLengthPrefixed(&hasher, header.name);
        hashLengthPrefixed(&hasher, header.value);
    }
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub const Freshness = enum {
    fresh,
    stale,
    refreshing,
    failed_refresh,
};

pub const SubscriptionIdentity = struct {
    request_id: u64,
    generation: u64,
};

pub const SnapshotMetadata = struct {
    key: CacheKey,
    connection_generation: u64,
    catalog_generation: u64,
    fetched_at_ms: u64,
    expires_at_ms: u64,
    scope: CacheScope,
    freshness: Freshness = .fresh,
    refresh_attempt: u8 = 0,
    retry_at_ms: u64 = 0,
    content_digest: Digest,
    subscription: ?SubscriptionIdentity = null,
};

fn expiryFromTtl(fetched_at_ms: u64, ttl_ms: u64) u64 {
    return fetched_at_ms +| ttl_ms;
}

pub fn pageExpiry(
    protocol: Protocol,
    received_at_ms: u64,
    ttl_present: bool,
    ttl_ms: u64,
) u64 {
    return expiryFromTtl(
        received_at_ms,
        snapshotTtl(protocol, ttl_present, ttl_ms),
    );
}

pub fn earliestExpiry(current: ?u64, page_expiry_ms: u64) u64 {
    return if (current) |expiry_ms|
        @min(expiry_ms, page_expiry_ms)
    else
        page_expiry_ms;
}

const RefreshDecision = struct {
    action: enum {
        hit,
        refresh,
        retry_later,
        already_refreshing,
    },
    may_serve_snapshot: bool,
};

pub fn decideRefresh(
    metadata: SnapshotMetadata,
    requested_key: CacheKey,
    now_ms: u64,
    invalidated: bool,
) RefreshDecision {
    const same_partition = metadata.key.eql(requested_key);
    if (!same_partition) return .{
        .action = .refresh,
        .may_serve_snapshot = false,
    };
    if (metadata.freshness == .refreshing) return .{
        .action = .already_refreshing,
        .may_serve_snapshot = true,
    };
    if (metadata.freshness == .failed_refresh and now_ms < metadata.retry_at_ms) {
        return .{
            .action = .retry_later,
            .may_serve_snapshot = true,
        };
    }
    if (invalidated) return .{
        .action = .refresh,
        .may_serve_snapshot = true,
    };
    if (metadata.freshness == .fresh and now_ms < metadata.expires_at_ms) {
        return .{
            .action = .hit,
            .may_serve_snapshot = true,
        };
    }
    return .{
        .action = .refresh,
        .may_serve_snapshot = true,
    };
}

pub fn effectiveFreshness(
    metadata: SnapshotMetadata,
    now_ms: u64,
    invalidated: bool,
) Freshness {
    return switch (metadata.freshness) {
        .refreshing, .failed_refresh => metadata.freshness,
        .fresh, .stale => if (invalidated or now_ms >= metadata.expires_at_ms)
            .stale
        else
            .fresh,
    };
}

pub fn beginRefresh(metadata: SnapshotMetadata) SnapshotMetadata {
    var next = metadata;
    next.freshness = .refreshing;
    return next;
}

const retry_initial_ms: u64 = 100;
const retry_max_ms: u64 = 5_000;
const retry_max_attempt: u8 = 8;

pub fn retryDelayMs(attempt: u8) u64 {
    var delay = retry_initial_ms;
    var remaining = @min(attempt, retry_max_attempt);
    while (remaining > 0) : (remaining -= 1) {
        delay = @min(delay *| 2, retry_max_ms);
    }
    return delay;
}

pub fn failedRefresh(metadata: SnapshotMetadata, now_ms: u64) SnapshotMetadata {
    var next = metadata;
    next.freshness = .failed_refresh;
    next.refresh_attempt = @min(metadata.refresh_attempt +| 1, retry_max_attempt);
    next.retry_at_ms = now_ms +| retryDelayMs(metadata.refresh_attempt);
    return next;
}

const ReplacementDecision = enum {
    reject_stale_generation,
    reject_cache_key,
    metadata_only,
    replace_snapshot,
};

pub fn authorizeReplacement(
    current: SnapshotMetadata,
    source_connection_generation: u64,
    source_catalog_generation: u64,
    active_key: CacheKey,
    replacement_key: CacheKey,
    replacement_content_digest: Digest,
) ReplacementDecision {
    if (current.connection_generation != source_connection_generation or
        current.catalog_generation != source_catalog_generation)
    {
        return .reject_stale_generation;
    }
    if (!active_key.eql(replacement_key)) return .reject_cache_key;
    if (std.mem.eql(u8, &current.content_digest, &replacement_content_digest)) {
        return .metadata_only;
    }
    return .replace_snapshot;
}

pub const Protocol = enum {
    legacy,
    modern,
};

fn snapshotTtl(protocol: Protocol, ttl_present: bool, ttl_ms: u64) u64 {
    if (ttl_present) return ttl_ms;
    return switch (protocol) {
        .modern => 0,
        .legacy => std.math.maxInt(u64),
    };
}

pub const NotificationKind = enum {
    subscription_acknowledged,
    subscription_filter_unsupported,
    tools_list_changed,
    resources_list_changed,
    resource_updated,
    prompts_list_changed,
    subscription_cancelled,
    other,
};

pub const Notification = struct {
    kind: NotificationKind,
    subscription_id: ?u64 = null,
    cancelled_request_id: ?u64 = null,
    resource_uri: ?[]const u8 = null,
};

const SubscriptionExpectation = struct {
    protocol: Protocol,
    capability_advertised: bool,
    connection_generation: u64,
    event_connection_generation: u64,
    subscription: ?SubscriptionIdentity,
    acknowledged: bool,
};

const NotificationDecision = enum {
    acknowledge,
    invalidate,
    close_subscription,
    close_unsupported,
    ignore_unadvertised,
    ignore_malformed,
    ignore_duplicate,
    ignore_late_generation,
    ignore_unrelated,
};

pub fn classifyNotification(
    expectation: SubscriptionExpectation,
    notification: Notification,
) NotificationDecision {
    if (!expectation.capability_advertised) return .ignore_unadvertised;
    if (expectation.connection_generation != expectation.event_connection_generation) {
        return .ignore_late_generation;
    }
    if (expectation.protocol == .legacy) {
        return switch (notification.kind) {
            .tools_list_changed,
            .resources_list_changed,
            .resource_updated,
            .prompts_list_changed,
            => .invalidate,
            else => .ignore_unrelated,
        };
    }

    const subscription = expectation.subscription orelse return .ignore_late_generation;
    return switch (notification.kind) {
        .subscription_acknowledged => {
            const subscription_id = notification.subscription_id orelse
                return .ignore_malformed;
            if (subscription_id != subscription.request_id) return .ignore_late_generation;
            if (expectation.acknowledged) return .ignore_duplicate;
            return .acknowledge;
        },
        .subscription_filter_unsupported => {
            const subscription_id = notification.subscription_id orelse
                return .ignore_malformed;
            if (subscription_id != subscription.request_id) return .ignore_late_generation;
            if (expectation.acknowledged) return .ignore_duplicate;
            return .close_unsupported;
        },
        .tools_list_changed,
        .resources_list_changed,
        .resource_updated,
        .prompts_list_changed,
        => {
            const subscription_id = notification.subscription_id orelse
                return .ignore_malformed;
            if (subscription_id != subscription.request_id) return .ignore_late_generation;
            if (!expectation.acknowledged) return .ignore_late_generation;
            return .invalidate;
        },
        .subscription_cancelled => {
            const request_id = notification.cancelled_request_id orelse
                return .ignore_malformed;
            return if (request_id == subscription.request_id)
                .close_subscription
            else
                .ignore_late_generation;
        },
        .other => .ignore_unrelated,
    };
}

const CoalesceDecision = enum {
    enqueue,
    already_pending,
    ignore,
};

pub fn decideCoalesce(pending: bool, notification: NotificationDecision) CoalesceDecision {
    if (notification != .invalidate) return .ignore;
    return if (pending) .already_pending else .enqueue;
}

pub fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    Sha256.hash(bytes, &result, .{});
    return result;
}

fn optionalDigestEql(left: ?Digest, right: ?Digest) bool {
    if ((left == null) != (right == null)) return false;
    if (left) |value| return std.mem.eql(u8, &value, &right.?);
    return true;
}

fn hashLengthPrefixed(hasher: *Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .big);
    hasher.update(&length);
    hasher.update(bytes);
}

fn testMetadata(key: CacheKey, generation: u64, content: []const u8) SnapshotMetadata {
    return .{
        .key = key,
        .connection_generation = 4,
        .catalog_generation = generation,
        .fetched_at_ms = 100,
        .expires_at_ms = 200,
        .scope = if (key.private_auth_identity == null) .public else .private,
        .content_digest = digest(content),
    };
}

test "duplicate notifications are idempotent" {
    const subscription = SubscriptionIdentity{ .request_id = 17, .generation = 3 };
    const notification = Notification{
        .kind = .tools_list_changed,
        .subscription_id = 17,
    };
    const expectation = SubscriptionExpectation{
        .protocol = .modern,
        .capability_advertised = true,
        .connection_generation = 4,
        .event_connection_generation = 4,
        .subscription = subscription,
        .acknowledged = true,
    };
    const classified = classifyNotification(expectation, notification);
    try std.testing.expectEqual(NotificationDecision.invalidate, classified);
    try std.testing.expectEqual(CoalesceDecision.enqueue, decideCoalesce(false, classified));
    try std.testing.expectEqual(CoalesceDecision.already_pending, decideCoalesce(true, classified));
}

test "failed refresh preserves the last valid snapshot" {
    const identity = authIdentity(&.{});
    const key = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .private,
        .auth_identity = identity,
    });
    const current = testMetadata(key, 9, "valid snapshot");
    const failed = failedRefresh(current, 250);
    try std.testing.expectEqual(Freshness.failed_refresh, failed.freshness);
    try std.testing.expectEqual(current.catalog_generation, failed.catalog_generation);
    try std.testing.expectEqualSlices(u8, &current.content_digest, &failed.content_digest);
    try std.testing.expect(failed.retry_at_ms > 250);
}

test "a stale generation cannot replace newer state" {
    const key = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .public,
        .auth_identity = authIdentity(&.{}),
    });
    const current = testMetadata(key, 12, "newer");
    try std.testing.expectEqual(
        ReplacementDecision.reject_stale_generation,
        authorizeReplacement(current, 4, 11, key, key, digest("older")),
    );
}

test "private cache state cannot cross authentication identities" {
    const first_identity = authIdentity(&.{.{ .name = "Authorization", .value = "first" }});
    const second_identity = authIdentity(&.{.{ .name = "Authorization", .value = "second" }});
    const first = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .private,
        .auth_identity = first_identity,
    });
    const second = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .private,
        .auth_identity = second_identity,
    });
    const decision = decideRefresh(testMetadata(first, 1, "private"), second, 101, false);
    try std.testing.expectEqual(.refresh, decision.action);
    try std.testing.expect(!decision.may_serve_snapshot);

    const public_first = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .public,
        .auth_identity = first_identity,
    });
    const public_second = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .public,
        .auth_identity = second_identity,
    });
    try std.testing.expect(public_first.eql(public_second));
    try std.testing.expectEqual(
        ReplacementDecision.reject_cache_key,
        authorizeReplacement(
            testMetadata(first, 1, "private"),
            4,
            1,
            second,
            first,
            digest("replacement"),
        ),
    );
}

test "equivalent validated refreshes do not replace snapshot content" {
    const key = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .public,
        .auth_identity = authIdentity(&.{}),
    });
    const current = testMetadata(key, 2, "same schema");
    try std.testing.expectEqual(
        ReplacementDecision.metadata_only,
        authorizeReplacement(current, 4, 2, key, key, digest("same schema")),
    );
}

test "valid changed refresh authorizes one whole snapshot replacement" {
    const key = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .public,
        .auth_identity = authIdentity(&.{}),
    });
    const current = testMetadata(key, 2, "old complete snapshot");
    try std.testing.expectEqual(
        ReplacementDecision.replace_snapshot,
        authorizeReplacement(current, 4, 2, key, key, digest("new complete snapshot")),
    );
}

test "expiry and retry arithmetic saturate" {
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        expiryFromTtl(std.math.maxInt(u64) - 1, 10),
    );
    var metadata = testMetadata(buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .public,
        .auth_identity = authIdentity(&.{}),
    }), 1, "snapshot");
    metadata.refresh_attempt = retry_max_attempt;
    const failed = failedRefresh(metadata, std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.maxInt(u64), failed.retry_at_ms);
    try std.testing.expectEqual(retry_max_attempt, failed.refresh_attempt);
}

test "TTL defaults are version scoped and preserve clock boundaries" {
    try std.testing.expectEqual(@as(u64, 0), snapshotTtl(.modern, true, 0));
    try std.testing.expectEqual(@as(u64, 0), snapshotTtl(.modern, false, 99));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        snapshotTtl(.modern, true, std.math.maxInt(u64)),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        snapshotTtl(.legacy, false, 0),
    );

    const key = buildCacheKey(.{
        .server_identity = "server",
        .protocol_version = "2026-07-28",
        .capability = .tools_list,
        .normalized_arguments = "{}",
        .scope = .public,
        .auth_identity = authIdentity(&.{}),
    });
    var metadata = testMetadata(key, 1, "boundary");
    metadata.expires_at_ms = 500;
    try std.testing.expectEqual(.hit, decideRefresh(metadata, key, 499, false).action);
    try std.testing.expectEqual(.refresh, decideRefresh(metadata, key, 500, false).action);
}

test "paginated cache expiry uses each page receive time" {
    const first_expiry = pageExpiry(.modern, 1_000, true, 100);
    try std.testing.expectEqual(@as(u64, 1_100), first_expiry);

    const later_expiry = pageExpiry(.modern, 1_050, true, 500);
    try std.testing.expectEqual(
        first_expiry,
        earliestExpiry(first_expiry, later_expiry),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        pageExpiry(.modern, std.math.maxInt(u64) - 1, true, 100),
    );
    try std.testing.expectEqual(
        @as(u64, 2_000),
        pageExpiry(.modern, 2_000, true, 0),
    );
    try std.testing.expectEqual(
        @as(u64, 3_000),
        pageExpiry(.modern, 3_000, false, 99),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        pageExpiry(.legacy, 4_000, false, 0),
    );
}

test "modern notification classification rejects malformed late and duplicate events" {
    const subscription = SubscriptionIdentity{ .request_id = 8, .generation = 2 };
    const base = SubscriptionExpectation{
        .protocol = .modern,
        .capability_advertised = true,
        .connection_generation = 5,
        .event_connection_generation = 5,
        .subscription = subscription,
        .acknowledged = false,
    };
    try std.testing.expectEqual(
        NotificationDecision.ignore_malformed,
        classifyNotification(base, .{ .kind = .subscription_acknowledged }),
    );
    try std.testing.expectEqual(
        NotificationDecision.ignore_late_generation,
        classifyNotification(base, .{
            .kind = .subscription_acknowledged,
            .subscription_id = 9,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.acknowledge,
        classifyNotification(base, .{
            .kind = .subscription_acknowledged,
            .subscription_id = 8,
        }),
    );
    var acknowledged = base;
    acknowledged.acknowledged = true;
    try std.testing.expectEqual(
        NotificationDecision.ignore_duplicate,
        classifyNotification(acknowledged, .{
            .kind = .subscription_acknowledged,
            .subscription_id = 8,
        }),
    );
    var late = acknowledged;
    late.event_connection_generation = 4;
    try std.testing.expectEqual(
        NotificationDecision.ignore_late_generation,
        classifyNotification(late, .{
            .kind = .tools_list_changed,
            .subscription_id = 8,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.close_subscription,
        classifyNotification(acknowledged, .{
            .kind = .subscription_cancelled,
            .cancelled_request_id = 8,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.close_unsupported,
        classifyNotification(base, .{
            .kind = .subscription_filter_unsupported,
            .subscription_id = 8,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.ignore_malformed,
        classifyNotification(base, .{
            .kind = .subscription_filter_unsupported,
        }),
    );
    try std.testing.expectEqual(
        NotificationDecision.ignore_late_generation,
        classifyNotification(acknowledged, .{
            .kind = .subscription_cancelled,
            .cancelled_request_id = 7,
        }),
    );
}
