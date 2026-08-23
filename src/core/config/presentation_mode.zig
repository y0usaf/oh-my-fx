const std = @import("std");

pub const MaxxingMode = enum {
    minimal,
    legacy,

    pub const default: MaxxingMode = .minimal;
    const legacy_alias = "normal";

    pub fn label(self: MaxxingMode) []const u8 {
        return switch (self) {
            .minimal => "minimal",
            .legacy => "legacy",
        };
    }

    pub fn parse(value: []const u8) ?MaxxingMode {
        const trimmed = std.mem.trim(u8, value, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, MaxxingMode.minimal.label())) return .minimal;
        if (std.ascii.eqlIgnoreCase(trimmed, MaxxingMode.legacy.label()) or
            std.ascii.eqlIgnoreCase(trimmed, legacy_alias))
        {
            return .legacy;
        }
        return null;
    }

    pub fn isPersistedLabel(value: []const u8) bool {
        return std.mem.eql(u8, value, MaxxingMode.minimal.label()) or
            std.mem.eql(u8, value, MaxxingMode.legacy.label()) or
            std.mem.eql(u8, value, legacy_alias);
    }
};

test "maxxing mode uses minimal and legacy labels while accepting normal settings" {
    try std.testing.expectEqual(MaxxingMode.minimal, MaxxingMode.default);
    try std.testing.expectEqual(MaxxingMode.minimal, MaxxingMode.parse("minimal").?);
    try std.testing.expectEqualStrings("minimal", MaxxingMode.minimal.label());
    try std.testing.expectEqual(MaxxingMode.legacy, MaxxingMode.parse(" LEGACY ").?);
    try std.testing.expectEqualStrings("legacy", MaxxingMode.legacy.label());
    try std.testing.expectEqual(MaxxingMode.legacy, MaxxingMode.parse("normal").?);
    try std.testing.expect(MaxxingMode.parse("bare") == null);
    try std.testing.expect(MaxxingMode.isPersistedLabel("minimal"));
    try std.testing.expect(MaxxingMode.isPersistedLabel("legacy"));
    try std.testing.expect(MaxxingMode.isPersistedLabel("normal"));
    try std.testing.expect(!MaxxingMode.isPersistedLabel(" MINIMAL "));
}
