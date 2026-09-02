const std = @import("std");

/// Rewrites `json` without insignificant whitespace and with raw control
/// bytes inside string literals escaped, so an NDJSON frame stays on one line.
/// All other bytes pass through unchanged, preserving valid input tokens.
pub fn write_compact(writer: *std.Io.Writer, json: []const u8) !void {
    var in_string = false;
    var escape_pending = false;
    for (json) |byte| {
        if (!in_string) {
            switch (byte) {
                ' ', '\t', '\n', '\r' => {},
                else => {
                    if (byte == '"') in_string = true;
                    try writer.writeByte(byte);
                },
            }
            continue;
        }
        if (byte < 0x20) {
            // Raw control bytes are invalid JSON inside a string; escaping
            // them keeps malformed model output inside its NDJSON frame.
            try writer.print("\\u{x:0>4}", .{byte});
            escape_pending = false;
            continue;
        }
        try writer.writeByte(byte);
        if (escape_pending) {
            escape_pending = false;
        } else switch (byte) {
            '\\' => escape_pending = true,
            '"' => in_string = false,
            else => {},
        }
    }
}
