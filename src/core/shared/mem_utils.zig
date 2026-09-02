const std = @import("std");

// Centralize generic free paths that Zig would otherwise duplicate at each
// error exit, reducing generated code to one call per cleanup site.

/// Drop-in replacement for `alloc.free(slice)`.
pub fn free(alloc: std.mem.Allocator, memory: anytype) void {
    const info = @typeInfo(@TypeOf(memory)).pointer;
    comptime std.debug.assert(info.size == .slice);
    const bytes: []u8 = @ptrCast(@constCast(std.mem.absorbSentinel(memory)));
    freeErased(
        alloc,
        bytes.ptr,
        bytes.len,
        .fromByteUnits(info.alignment orelse @alignOf(info.child)),
        @returnAddress(),
    );
}

/// Drop-in replacement for `list.deinit(alloc)` on an unmanaged array list.
pub fn deinitList(alloc: std.mem.Allocator, list: anytype) void {
    free(alloc, list.allocatedSlice());
    list.* = undefined;
}

noinline fn freeErased(
    alloc: std.mem.Allocator,
    ptr: [*]u8,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    if (len == 0) return;
    const bytes = ptr[0..len];
    @memset(bytes, undefined);
    alloc.rawFree(bytes, alignment, ret_addr);
}
