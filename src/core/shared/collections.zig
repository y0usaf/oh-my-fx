const std = @import("std");

pub fn freeStringList(alloc: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| alloc.free(item);
    list.deinit(alloc);
}
