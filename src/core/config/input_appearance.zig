const std = @import("std");

pub const InputAppearance = enum {
    lines,
    tint,

    pub const default: InputAppearance = .tint;

    pub fn label(self: InputAppearance) []const u8 {
        return switch (self) {
            .lines => "lines",
            .tint => "tint",
        };
    }

    pub fn parse(value: []const u8) ?InputAppearance {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, InputAppearance.lines.label())) return .lines;
        if (std.ascii.eqlIgnoreCase(trimmed, InputAppearance.tint.label())) return .tint;
        return null;
    }

    pub fn isPersistedLabel(value: []const u8) bool {
        return std.mem.eql(u8, value, InputAppearance.lines.label()) or
            std.mem.eql(u8, value, InputAppearance.tint.label());
    }
};

test "input appearance owns parsing defaults and persisted labels" {
    try std.testing.expectEqual(InputAppearance.tint, InputAppearance.default);
    try std.testing.expectEqual(InputAppearance.lines, InputAppearance.parse(" LINES ").?);
    try std.testing.expectEqualStrings("lines", InputAppearance.lines.label());
    try std.testing.expectEqual(InputAppearance.tint, InputAppearance.parse("tint").?);
    try std.testing.expectEqualStrings("tint", InputAppearance.tint.label());
    try std.testing.expect(InputAppearance.parse("minimal-maxxing") == null);
    try std.testing.expect(InputAppearance.parse("no-lines") == null);
    try std.testing.expect(InputAppearance.isPersistedLabel("lines"));
    try std.testing.expect(InputAppearance.isPersistedLabel("tint"));
    try std.testing.expect(!InputAppearance.isPersistedLabel(" LINES "));
}
