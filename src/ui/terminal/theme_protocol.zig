const std = @import("std");
const user_message_card = @import("../assistant/user_message_card.zig");

pub const Rgb = user_message_card.Rgb;

pub const Background = struct {
    light: bool,
    rgb: Rgb,
};

pub fn parseOsc11Response(bytes: []const u8) ?Background {
    const prefix = "\x1b]11;rgb:";
    if (!std.mem.startsWith(u8, bytes, prefix)) return null;

    const rgb_end = if (std.mem.endsWith(u8, bytes, "\x1b\\"))
        bytes.len - 2
    else if (std.mem.endsWith(u8, bytes, "\x07"))
        bytes.len - 1
    else
        return null;
    if (rgb_end <= prefix.len) return null;

    var components: [3]u32 = undefined;
    var it = std.mem.splitScalar(u8, bytes[prefix.len..rgb_end], '/');
    for (&components) |*component| {
        const part = it.next() orelse return null;
        component.* = normalizeOsc11Component(part) orelse return null;
    }
    if (it.next() != null) return null;

    const luminance = (components[0] * 299 + components[1] * 587 + components[2] * 114) / 1000;
    return .{
        .light = luminance > 32768,
        .rgb = .{
            .r = @intCast(components[0] >> 8),
            .g = @intCast(components[1] >> 8),
            .b = @intCast(components[2] >> 8),
        },
    };
}

// Terminal.app is the one mainstream terminal that quantizes 38;2 colors
// itself; every other target either sets COLORTERM or renders RGB exactly.
pub fn truecolorSupportedForValues(colorterm: ?[]const u8, term_program: ?[]const u8) bool {
    if (colorterm) |value| {
        if (std.mem.find(u8, value, "truecolor") != null) return true;
        if (std.mem.find(u8, value, "24bit") != null) return true;
    }
    if (term_program) |value| {
        if (std.mem.eql(u8, value, "Apple_Terminal")) return false;
    }
    return true;
}




pub fn parseColorFgBgLight(colorfgbg: []const u8) bool {
    var last_semi: ?usize = null;
    for (colorfgbg, 0..) |byte, i| {
        if (byte == ';') last_semi = i;
    }
    const bg_str = if (last_semi) |pos| colorfgbg[pos + 1 ..] else return false;
    const bg = std.fmt.parseUnsigned(u8, bg_str, 10) catch return false;
    return bg >= 8;
}

fn normalizeOsc11Component(part: []const u8) ?u32 {
    if (part.len == 0 or part.len > 4) return null;
    const value = std.fmt.parseUnsigned(u32, part, 16) catch return null;
    const bits: u5 = @intCast(part.len * 4);
    const maximum = (@as(u32, 1) << bits) - 1;
    return @divTrunc(value * 0xffff, maximum);
}





