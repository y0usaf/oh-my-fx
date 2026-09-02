const std = @import("std");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    success,
    failure,
};

/// Owned provider output. The caller frees `body` with the allocator passed to
/// `Provider.execute`.
pub const Result = struct {
    status: Status,
    body: []u8,
};

pub const ExecuteFn = *const fn (
    ?*anyopaque,
    Allocator,
    *domain.Command,
    []const u8,
) Allocator.Error!Result;

/// Host-facing executor for one validated registered subagent command. The
/// caller retains command ownership; the provider may normalize it during the
/// synchronous call but must not retain the pointer.
pub const Provider = struct {
    context: ?*anyopaque = null,
    execute_fn: ExecuteFn,

    pub fn execute(
        self: Provider,
        alloc: Allocator,
        command: *domain.Command,
        invocation_id: []const u8,
    ) Allocator.Error!Result {
        return self.execute_fn(
            self.context,
            alloc,
            command,
            invocation_id,
        );
    }
};

