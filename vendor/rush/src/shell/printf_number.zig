//! Numeric operand parsing for the POSIX `printf` utility.

const std = @import("std");

pub const Signed = struct {
    value: i64,
    diagnostic_required: bool = false,
};

pub const Unsigned = struct {
    value: u64,
    diagnostic_required: bool = false,
};

pub const Float = struct {
    value: f64,
    diagnostic_required: bool = false,
};

const IntegerConstant = struct {
    magnitude: u64,
    negative: bool = false,
    complete: bool = true,
    overflow: bool = false,
};

const Magnitude = struct {
    value: u64,
    overflow: bool = false,
};

const SignedValue = struct {
    value: i64,
    overflow: bool = false,
};

const UnsignedValue = struct {
    value: u64,
    overflow: bool = false,
};

pub fn parseSigned(arg: []const u8) Signed {
    const parsed = parseIntegerConstant(arg) catch return .{
        .value = 0,
        .diagnostic_required = true,
    };
    const converted = signedValue(parsed);
    return .{
        .value = converted.value,
        .diagnostic_required = !parsed.complete or converted.overflow,
    };
}

pub fn parseUnsigned(arg: []const u8) Unsigned {
    const parsed = parseIntegerConstant(arg) catch return .{
        .value = 0,
        .diagnostic_required = true,
    };
    const converted = unsignedValue(parsed);
    return .{
        .value = converted.value,
        .diagnostic_required = !parsed.complete or converted.overflow,
    };
}

fn signedValue(parsed: IntegerConstant) SignedValue {
    if (!parsed.negative) {
        if (parsed.magnitude > std.math.maxInt(i64)) return .{ .value = std.math.maxInt(i64), .overflow = true };
        return .{ .value = @intCast(parsed.magnitude), .overflow = parsed.overflow };
    }
    const max_plus_one = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
    if (parsed.magnitude == max_plus_one) return .{ .value = std.math.minInt(i64), .overflow = parsed.overflow };
    if (parsed.magnitude > max_plus_one) return .{ .value = std.math.minInt(i64), .overflow = true };
    return .{ .value = -@as(i64, @intCast(parsed.magnitude)), .overflow = parsed.overflow };
}

fn unsignedValue(parsed: IntegerConstant) UnsignedValue {
    if (!parsed.negative) return .{ .value = parsed.magnitude, .overflow = parsed.overflow };
    if (parsed.overflow) return .{ .value = std.math.maxInt(u64), .overflow = true };
    return .{ .value = (~parsed.magnitude) +% 1 };
}

fn parseMagnitude(text: []const u8, base: u8) !Magnitude {
    const value = std.fmt.parseInt(u64, text, base) catch |err| switch (err) {
        error.Overflow => return .{ .value = std.math.maxInt(u64), .overflow = true },
        else => return err,
    };
    return .{ .value = value };
}

fn skipIntegerWhitespace(arg: []const u8, cursor: *usize) void {
    while (cursor.* < arg.len and std.ascii.isWhitespace(arg[cursor.*])) : (cursor.* += 1) {}
}

fn integerParseComplete(arg: []const u8, cursor: usize) bool {
    var trailing = cursor;
    skipIntegerWhitespace(arg, &trailing);
    return trailing == arg.len;
}

fn parseIntegerConstant(arg: []const u8) !IntegerConstant {
    if (arg.len == 0) return .{ .magnitude = 0 };
    if (arg[0] == '\'' or arg[0] == '"') return .{
        .magnitude = if (arg.len > 1) arg[1] else 0,
        .complete = arg.len <= 2,
    };

    var cursor: usize = 0;
    skipIntegerWhitespace(arg, &cursor);
    if (cursor >= arg.len) return error.InvalidCharacter;

    var negative = false;
    if (arg[cursor] == '+' or arg[cursor] == '-') {
        negative = arg[cursor] == '-';
        cursor += 1;
    }
    if (cursor >= arg.len or !std.ascii.isDigit(arg[cursor])) return error.InvalidCharacter;

    const digits_start: usize = cursor;
    var base: u8 = 10;
    if (arg[cursor] == '0') {
        base = 8;
        cursor += 1;
        if (cursor < arg.len and (arg[cursor] == 'x' or arg[cursor] == 'X')) {
            base = 16;
            cursor += 1;
            const hex_start = cursor;
            while (cursor < arg.len and std.ascii.isHex(arg[cursor])) : (cursor += 1) {}
            if (cursor == hex_start) return .{ .magnitude = 0, .negative = negative, .complete = false };
            const magnitude = try parseMagnitude(arg[hex_start..cursor], base);
            return .{
                .magnitude = magnitude.value,
                .negative = negative,
                .complete = integerParseComplete(arg, cursor),
                .overflow = magnitude.overflow,
            };
        }
        while (cursor < arg.len and arg[cursor] >= '0' and arg[cursor] <= '7') : (cursor += 1) {}
    } else {
        while (cursor < arg.len and std.ascii.isDigit(arg[cursor])) : (cursor += 1) {}
    }
    const magnitude = try parseMagnitude(arg[digits_start..cursor], base);
    return .{
        .magnitude = magnitude.value,
        .negative = negative,
        .complete = integerParseComplete(arg, cursor),
        .overflow = magnitude.overflow,
    };
}

pub fn parseFloat(arg: []const u8) Float {
    const trimmed = trimFloatWhitespace(arg);
    if (trimmed.len == 0) return .{ .value = 0 };
    if (std.fmt.parseFloat(f64, trimmed)) |value| return .{ .value = value } else |_| {}
    var end = trimmed.len;
    while (end > 0) : (end -= 1) {
        if (std.fmt.parseFloat(f64, trimmed[0..end])) |value| {
            return .{ .value = value, .diagnostic_required = true };
        } else |_| {}
    }
    return .{ .value = 0, .diagnostic_required = true };
}

fn trimFloatWhitespace(arg: []const u8) []const u8 {
    var start: usize = 0;
    while (start < arg.len and std.ascii.isWhitespace(arg[start])) : (start += 1) {}
    var end = arg.len;
    while (end > start and std.ascii.isWhitespace(arg[end - 1])) : (end -= 1) {}
    return arg[start..end];
}
