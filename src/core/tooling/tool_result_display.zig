const std = @import("std");

/// Returns the human-readable body from established tool result envelopes.
/// Malformed or unfamiliar output stays literal so presentation never hides
/// tool evidence it cannot identify safely.
pub fn contentForDisplay(body: []const u8) []const u8 {
    var rest = body;
    if (std.mem.startsWith(u8, rest, "<path>")) {
        const path_close = std.mem.find(u8, rest, "</path>") orelse return body;
        rest = std.mem.trimStart(u8, rest[path_close + "</path>".len ..], "\r\n");
    }
    if (!std.mem.startsWith(u8, rest, "<content>")) return body;
    rest = std.mem.trimStart(u8, rest["<content>".len..], "\r\n");
    if (!std.mem.endsWith(u8, rest, "</content>")) return body;
    return std.mem.trimEnd(u8, rest[0 .. rest.len - "</content>".len], "\r\n");
}

test "contentForDisplay unwraps path and content result" {
    try std.testing.expectEqualStrings(
        "1\talpha\n2\tbeta",
        contentForDisplay("<path>README.md</path>\n<content>\n1\talpha\n2\tbeta\n</content>"),
    );
}

test "contentForDisplay preserves unknown or malformed output" {
    const raw = "<path>README.md</path>\n<content>missing close";
    try std.testing.expectEqualStrings(raw, contentForDisplay(raw));
    try std.testing.expectEqualStrings("plain output", contentForDisplay("plain output"));
}
