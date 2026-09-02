const std = @import("std");
const model_provider = @import("../config/model_provider.zig");

const Allocator = std.mem.Allocator;

pub const LookupInput = struct {
    credential: []const u8,
    tenant: ?[]const u8,
    origin: []const u8,
    generation_id: []const u8,
    cancel_flag: *std.atomic.Value(bool),
};

pub const Record = struct {
    id: []const u8,
    created_at_ms: i64 = 0,
    model: []const u8,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64 = null,
    billable_web_search_calls: u64,
};

pub const LookupOutcome = union(enum) {
    found: Record,
    retry,
    preserve_pending,
    reject,

    pub fn deinit(self: *LookupOutcome, alloc: Allocator) void {
        switch (self.*) {
            .found => |record| {
                alloc.free(@constCast(record.id));
                alloc.free(@constCast(record.model));
            },
            .retry, .preserve_pending, .reject => {},
        }
        self.* = undefined;
    }
};

pub const LookupError = Allocator.Error || error{
    Cancelled,
    Unavailable,
};

pub const LookupFn = *const fn (
    context: ?*anyopaque,
    alloc: Allocator,
    input: LookupInput,
) LookupError!LookupOutcome;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight lookup returns.
    context: ?*anyopaque = null,
    lookup_fn: LookupFn,

    /// A `.found` outcome owns its record strings; the caller must call
    /// `LookupOutcome.deinit`.
    pub fn lookup(
        self: Provider,
        alloc: Allocator,
        input: LookupInput,
    ) LookupError!LookupOutcome {
        return self.lookup_fn(self.context, alloc, input);
    }
};

fn lookupUnavailable(
    _: ?*anyopaque,
    _: Allocator,
    _: LookupInput,
) LookupError!LookupOutcome {
    return error.Unavailable;
}

pub const unavailable_provider = Provider{
    .lookup_fn = lookupUnavailable,
};

pub const Set = struct {
    gateway: ?Provider = null,
    codex: ?Provider = null,
    grok: ?Provider = null,

    pub fn gatewayOnly(provider: Provider) Set {
        return .{ .gateway = provider };
    }

    pub fn select(self: Set, provider: model_provider.ProviderId) ?Provider {
        return switch (provider) {
            .gateway => self.gateway,
            .codex => self.codex,
            .grok => self.grok,
        };
    }
};
