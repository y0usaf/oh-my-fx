const std = @import("std");

/// Encodes untrusted dynamic metadata once at its final model-markup boundary; source-owned instruction bodies remain raw within their own limits.
pub fn writeScalar(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < value.len) {
        if (std.mem.startsWith(u8, value[index..], "\xc2\x85")) {
            try writer.writeAll("&#x85;");
            index += 2;
            continue;
        }
        if (std.mem.startsWith(u8, value[index..], "\xe2\x80\xa8")) {
            try writer.writeAll("&#x2028;");
            index += 3;
            continue;
        }
        if (std.mem.startsWith(u8, value[index..], "\xe2\x80\xa9")) {
            try writer.writeAll("&#x2029;");
            index += 3;
            continue;
        }

        const byte = value[index];
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            0x00...0x1f, 0x7f => try writer.print("&#x{x:0>2};", .{byte}),
            else => try writer.writeByte(byte),
        }
        index += 1;
    }
}
