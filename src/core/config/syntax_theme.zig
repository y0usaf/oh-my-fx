//! Configured syntax-highlighting palettes.
//!
//! The name is a config-owned enum so settings.json, the settings menu, and
//! the highlighter all speak one vocabulary. The palette for each name lives
//! in `ui/render_engine/code_highlight.zig`, which owns rendering.

const std = @import("std");

pub const Name = enum {
    default,
    mono,
    ocean,
    ember,
};

pub const count = std.meta.fields(Name).len;

pub fn label(name: Name) []const u8 {
    return @tagName(name);
}

pub fn parse(value: []const u8) ?Name {
    inline for (std.meta.fields(Name)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub const names = [_][]const u8{ "default", "mono", "ocean", "ember" };

test "syntax theme names round-trip through parse and label" {
    for (names, 0..) |name, index| {
        const parsed = parse(name).?;
        try std.testing.expectEqual(@as(Name, @enumFromInt(index)), parsed);
        try std.testing.expectEqualStrings(name, label(parsed));
    }
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("rainbow") == null);
    try std.testing.expectEqual(@as(usize, 4), names.len);
}
