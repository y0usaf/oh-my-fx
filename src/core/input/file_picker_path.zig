const std = @import("std");

pub fn needsQuotes(path: []const u8) bool {
    return std.mem.findScalar(u8, path, ' ') != null;
}

pub fn isRepresentable(path: []const u8) bool {
    if (path.len > 0 and path[0] == '"') return false;
    for (path) |byte| {
        if (byte == '\t' or byte == '\n' or byte == '\r') return false;
    }
    return !needsQuotes(path) or std.mem.findScalar(u8, path, '"') == null;
}

test "representable paths cannot open picker quote grammar" {
    try std.testing.expect(!isRepresentable("\"leading-quote"));
    try std.testing.expect(isRepresentable("embedded-\"-quote"));
}
