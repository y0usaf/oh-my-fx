const std = @import("std");

pub const background_processes = false;

pub fn isTarget(arch: std.Target.Cpu.Arch) bool {
    return arch == .wasm32 or arch == .wasm64;
}

/// Returns an owned target description. The caller must free it with `alloc`.
pub fn operatingSystemText(
    alloc: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
) std.mem.Allocator.Error![]u8 {
    return alloc.dupe(u8, @tagName(os_tag));
}
