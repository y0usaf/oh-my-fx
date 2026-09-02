const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Result = enum {
    accepted,
    refused,
    unavailable,
};

pub const ValidateFn = *const fn (?*anyopaque, Allocator, []const u8) Result;

pub const Provider = struct {
    /// When set, context must remain valid until every in-flight validation returns.
    context: ?*anyopaque = null,
    validate_fn: ValidateFn,

    pub fn validate(self: Provider, alloc: Allocator, api_key: []const u8) Result {
        return self.validate_fn(self.context, alloc, api_key);
    }
};

fn validateUnavailable(_: ?*anyopaque, _: Allocator, _: []const u8) Result {
    return .unavailable;
}

pub const unavailable_provider = Provider{
    .validate_fn = validateUnavailable,
};

