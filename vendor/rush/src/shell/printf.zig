//! POSIX printf utility formatting semantics.
//!
//! This module owns shell-level `printf` parsing, operand conversion, format
//! reuse, escapes, and diagnostics. Evaluation code remains responsible for
//! routing the resulting stdout/stderr bytes to the active execution frame.

const std = @import("std");
const printf_float = @import("printf_float.zig");
const printf_number = @import("printf_number.zig");

pub const ExitStatus = u8;
const Writer = std.Io.Writer;

pub fn evaluate(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: *Writer,
    stderr: *Writer,
) !ExitStatus {
    std.debug.assert(argv.len != 0);
    std.debug.assert(std.mem.eql(u8, argv[0], "printf"));

    var format_index: usize = 1;
    if (format_index < argv.len and std.mem.eql(u8, argv[format_index], "--")) format_index += 1;
    if (format_index >= argv.len) {
        var status: ExitStatus = 2;
        try printfDiagnostic(stderr, &status, "missing format operand");
        return status;
    }

    var status: ExitStatus = 0;
    try appendPrintfOutput(
        allocator,
        stdout,
        stderr,
        &status,
        argv[format_index],
        argv[format_index + 1 ..],
    );
    return status;
}

const PrintfSpec = struct {
    spec: u8,
    argument: ?usize = null,
    left_adjust: bool = false,
    zero_pad: bool = false,
    sign_plus: bool = false,
    sign_space: bool = false,
    alternate: bool = false,
    width_from_argument: bool = false,
    width: ?usize = null,
    precision_from_argument: bool = false,
    precision: ?usize = null,
};

const PrintfIntegerBase = enum { decimal, octal, lower_hex, upper_hex };

const PrintfArgumentMode = enum { none, numbered, unnumbered };

fn appendPrintfOutput(
    allocator: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    status: *ExitStatus,
    format: []const u8,
    args: []const []const u8,
) !void {
    const argument_mode = analyzePrintfFormat(format) catch |err| switch (err) {
        error.MixedArguments => {
            try printfDiagnostic(stderr, status, "invalid format");
            return;
        },
    };

    var arg_index: usize = 0;
    var numbered_base: usize = 0;
    var first_pass = true;
    while (first_pass or switch (argument_mode) {
        .numbered => numbered_base < args.len,
        .none, .unnumbered => arg_index < args.len,
    }) {
        first_pass = false;
        const before = if (argument_mode == .numbered) numbered_base else arg_index;
        var pass_max_numbered_argument: usize = 0;
        var index: usize = 0;
        while (index < format.len) {
            switch (format[index]) {
                '\\' => {
                    index += 1;
                    if (index >= format.len) {
                        try stdout.writeByte('\\');
                    } else {
                        _ = try appendEscapedSequence(stdout, format, &index, .format);
                    }
                },
                '%' => {
                    index += 1;
                    if (index >= format.len) {
                        try printfDiagnostic(stderr, status, "invalid format");
                        break;
                    }
                    const spec = parsePrintfSpec(format, &index) orelse {
                        try printfDiagnostic(stderr, status, "invalid format");
                        continue;
                    };
                    if (spec.spec == '%') {
                        if (spec.width_from_argument or spec.precision_from_argument) {
                            try printfDiagnostic(stderr, status, "invalid format");
                            continue;
                        }
                        try stdout.writeByte('%');
                        continue;
                    }
                    const resolved_spec = try resolvePrintfDynamicSpec(
                        stderr,
                        status,
                        spec,
                        args,
                        &arg_index,
                    );
                    const arg = if (spec.argument) |argument_number| blk: {
                        pass_max_numbered_argument = @max(pass_max_numbered_argument, argument_number);
                        const offset = std.math.add(usize, numbered_base, argument_number - 1) catch {
                            try printfDiagnostic(stderr, status, "missing argument");
                            return;
                        };
                        if (offset >= args.len) {
                            try printfDiagnostic(stderr, status, "missing argument");
                            return;
                        }
                        break :blk args[offset];
                    } else if (arg_index < args.len) blk: {
                        const value = args[arg_index];
                        arg_index += 1;
                        break :blk value;
                    } else "";
                    if (!try appendPrintfConversion(
                        allocator,
                        stdout,
                        stderr,
                        status,
                        resolved_spec,
                        arg,
                    )) return;
                },
                else => {
                    try stdout.writeByte(format[index]);
                    index += 1;
                },
            }
        }
        if (argument_mode == .numbered) {
            if (pass_max_numbered_argument == 0) break;
            numbered_base = std.math.add(usize, numbered_base, pass_max_numbered_argument) catch {
                try printfDiagnostic(stderr, status, "missing argument");
                return;
            };
            if (numbered_base == before) break;
        } else if (arg_index == before) break;
    }
}

fn analyzePrintfFormat(format: []const u8) error{MixedArguments}!PrintfArgumentMode {
    var result: PrintfArgumentMode = .none;
    var index: usize = 0;
    while (index < format.len) {
        switch (format[index]) {
            '\\' => {
                index += 1;
                if (index < format.len) skipPrintfFormatEscape(format, &index);
            },
            '%' => {
                index += 1;
                if (index >= format.len) return result;
                const spec = parsePrintfSpec(format, &index) orelse return result;
                if (spec.spec == '%') continue;
                if (spec.width_from_argument or spec.precision_from_argument) {
                    if (result == .numbered) return error.MixedArguments;
                    result = .unnumbered;
                }
                if (spec.argument != null) {
                    if (result == .unnumbered) return error.MixedArguments;
                    result = .numbered;
                } else {
                    if (result == .numbered) return error.MixedArguments;
                    result = .unnumbered;
                }
            },
            else => index += 1,
        }
    }
    return result;
}

fn skipPrintfFormatEscape(format: []const u8, index: *usize) void {
    switch (format[index.*]) {
        'a', 'b', 'f', 'n', 'r', 't', 'v', '\\' => index.* += 1,
        'x' => {
            index.* += 1;
            var count: usize = 0;
            while (index.* < format.len and count < 2) : (count += 1) {
                _ = std.fmt.charToDigit(format[index.*], 16) catch break;
                index.* += 1;
            }
        },
        '0'...'7' => {
            var count: usize = 0;
            while (index.* < format.len and
                count < 3 and
                format[index.*] >= '0' and
                format[index.*] <= '7') : (count += 1)
            {
                index.* += 1;
            }
        },
        else => {},
    }
}

fn printfDiagnostic(
    stderr: *Writer,
    status: *ExitStatus,
    message: []const u8,
) !void {
    status.* = if (status.* == 2) 2 else 1;
    try stderr.writeAll("printf: ");
    try stderr.writeAll(message);
    try stderr.writeByte('\n');
}

fn printfNumericDiagnostic(
    stderr: *Writer,
    status: *ExitStatus,
) !void {
    try printfDiagnostic(stderr, status, "numeric argument required");
}

fn resolvePrintfDynamicSpec(
    stderr: *Writer,
    status: *ExitStatus,
    spec: PrintfSpec,
    args: []const []const u8,
    arg_index: *usize,
) !PrintfSpec {
    var result = spec;
    if (result.width_from_argument) {
        const value = try parsePrintfSigned(
            stderr,
            status,
            nextPrintfArgument(args, arg_index),
        );
        applyPrintfDynamicWidth(&result, value);
    }
    if (result.precision_from_argument) {
        const value = try parsePrintfSigned(
            stderr,
            status,
            nextPrintfArgument(args, arg_index),
        );
        result.precision = if (value < 0) null else printfDynamicMagnitude(value);
    }
    result.width_from_argument = false;
    result.precision_from_argument = false;
    return result;
}

fn nextPrintfArgument(args: []const []const u8, arg_index: *usize) []const u8 {
    if (arg_index.* >= args.len) return "";
    const value = args[arg_index.*];
    arg_index.* += 1;
    return value;
}

fn applyPrintfDynamicWidth(spec: *PrintfSpec, value: i64) void {
    if (value < 0) {
        spec.left_adjust = true;
    }
    spec.width = printfDynamicMagnitude(value);
}

fn printfDynamicMagnitude(value: i64) usize {
    const magnitude: u64 = if (value < 0) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    return std.math.cast(usize, magnitude) orelse std.math.maxInt(usize);
}

fn parsePrintfSpec(format: []const u8, index: *usize) ?PrintfSpec {
    var result: PrintfSpec = .{ .spec = 0 };
    if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        if (index.* < format.len and format[index.*] == '$') {
            const argument_number = std.fmt.parseInt(usize, format[start..index.*], 10) catch return null;
            if (argument_number == 0) return null;
            result.argument = argument_number;
            index.* += 1;
        } else {
            index.* = start;
        }
    }
    while (index.* < format.len) {
        switch (format[index.*]) {
            '-' => result.left_adjust = true,
            '0' => result.zero_pad = true,
            '+' => result.sign_plus = true,
            ' ' => result.sign_space = true,
            '#' => result.alternate = true,
            else => break,
        }
        index.* += 1;
    }
    if (index.* < format.len and format[index.*] == '*') {
        result.width_from_argument = true;
        index.* += 1;
    } else if (index.* < format.len and std.ascii.isDigit(format[index.*])) {
        const start = index.*;
        while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
        result.width = std.fmt.parseInt(usize, format[start..index.*], 10) catch null;
    }
    if (index.* < format.len and format[index.*] == '.') {
        index.* += 1;
        const start = index.*;
        if (index.* < format.len and format[index.*] == '*') {
            result.precision_from_argument = true;
            index.* += 1;
        } else {
            while (index.* < format.len and std.ascii.isDigit(format[index.*])) : (index.* += 1) {}
            result.precision = if (start == index.*) 0 else std.fmt.parseInt(usize, format[start..index.*], 10) catch 0;
        }
    }
    if (index.* >= format.len) return null;
    result.spec = format[index.*];
    index.* += 1;
    return result;
}

fn appendPrintfConversion(
    allocator: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    status: *ExitStatus,
    spec: PrintfSpec,
    arg: []const u8,
) !bool {
    if (isPrintfFloatSpec(spec.spec)) {
        try appendPrintfFloatConversion(allocator, stdout, stderr, status, spec, arg);
        return true;
    }

    switch (spec.spec) {
        'd', 'i' => {
            try appendPrintfSignedInteger(
                stdout,
                spec,
                try parsePrintfSigned(stderr, status, arg),
            );
            return true;
        },
        'u' => {
            try appendPrintfUnsignedInteger(
                stdout,
                spec,
                try parsePrintfUnsigned(stderr, status, arg),
                .decimal,
            );
            return true;
        },
        'o' => {
            try appendPrintfUnsignedInteger(
                stdout,
                spec,
                try parsePrintfUnsigned(stderr, status, arg),
                .octal,
            );
            return true;
        },
        'x' => {
            try appendPrintfUnsignedInteger(
                stdout,
                spec,
                try parsePrintfUnsigned(stderr, status, arg),
                .lower_hex,
            );
            return true;
        },
        'X' => {
            try appendPrintfUnsignedInteger(
                stdout,
                spec,
                try parsePrintfUnsigned(stderr, status, arg),
                .upper_hex,
            );
            return true;
        },
        else => {},
    }

    if (spec.spec == 'b') {
        if (spec.width == null and spec.precision == null) {
            return appendPrintfEscapedString(stdout, arg);
        }
        var escaped: Writer.Allocating = .init(allocator);
        defer escaped.deinit();
        const keep_going = try appendPrintfEscapedString(&escaped.writer, arg);
        const bytes = try escaped.toOwnedSlice();
        defer allocator.free(bytes);
        try appendPadded(stdout, truncatePrintfBytes(bytes, spec.precision), spec);
        return keep_going;
    }

    switch (spec.spec) {
        's' => try appendPadded(stdout, truncatePrintfBytes(arg, spec.precision), spec),
        'c' => {
            const byte: [1]u8 = .{if (arg.len == 0) 0 else arg[0]};
            try appendPadded(stdout, &byte, spec);
        },
        else => {
            try printfDiagnostic(stderr, status, "invalid conversion");
        },
    }
    return true;
}

fn truncatePrintfBytes(text: []const u8, precision: ?usize) []const u8 {
    const limit = if (precision) |value| @min(value, text.len) else text.len;
    return text[0..limit];
}

fn appendPrintfSignedInteger(
    stdout: *Writer,
    spec: PrintfSpec,
    value: i64,
) !void {
    const negative = value < 0;
    const magnitude: u64 = if (negative) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
    try appendPrintfInteger(stdout, spec, magnitude, negative, .decimal);
}

fn appendPrintfUnsignedInteger(
    stdout: *Writer,
    spec: PrintfSpec,
    value: u64,
    base: PrintfIntegerBase,
) !void {
    var unsigned_spec = spec;
    unsigned_spec.sign_plus = false;
    unsigned_spec.sign_space = false;
    try appendPrintfInteger(stdout, unsigned_spec, value, false, base);
}

fn appendPrintfInteger(
    stdout: *Writer,
    spec: PrintfSpec,
    magnitude: u64,
    negative: bool,
    base: PrintfIntegerBase,
) !void {
    var digit_buffer: [64]u8 = undefined;
    const raw_digits = try formatPrintfIntegerDigits(&digit_buffer, magnitude, base);

    var digits: []const u8 = raw_digits;
    if (spec.precision == 0 and magnitude == 0) digits = "";

    var precision_zeroes: usize = if (spec.precision) |precision|
        if (precision > digits.len) precision - digits.len else 0
    else
        0;
    if (base == .octal and spec.alternate) {
        if (digits.len + precision_zeroes == 0) {
            precision_zeroes = 1;
        } else if ((digits.len == 0 or digits[0] != '0') and precision_zeroes == 0) {
            precision_zeroes = 1;
        }
    }

    var prefix_buffer: [2]u8 = undefined;
    const prefix: []const u8 = switch (base) {
        .decimal => blk: {
            if (negative) {
                prefix_buffer[0] = '-';
                break :blk prefix_buffer[0..1];
            }
            if (spec.sign_plus) {
                prefix_buffer[0] = '+';
                break :blk prefix_buffer[0..1];
            }
            if (spec.sign_space) {
                prefix_buffer[0] = ' ';
                break :blk prefix_buffer[0..1];
            }
            break :blk "";
        },
        .octal => "",
        .lower_hex => if (spec.alternate and magnitude != 0) "0x" else "",
        .upper_hex => if (spec.alternate and magnitude != 0) "0X" else "",
    };

    const unpadded_len = prefix.len + precision_zeroes + digits.len;
    const width = spec.width orelse 0;
    const width_pad = if (width > unpadded_len) width - unpadded_len else 0;
    const use_zero_width_pad = spec.zero_pad and !spec.left_adjust and spec.precision == null;
    const leading_spaces: usize = if (!spec.left_adjust and !use_zero_width_pad) width_pad else 0;
    const width_zeroes: usize = if (use_zero_width_pad) width_pad else 0;
    const trailing_spaces: usize = if (spec.left_adjust) width_pad else 0;

    try stdout.splatByteAll(' ', leading_spaces);
    try stdout.writeAll(prefix);
    try stdout.splatByteAll('0', width_zeroes + precision_zeroes);
    try stdout.writeAll(digits);
    try stdout.splatByteAll(' ', trailing_spaces);
}

fn formatPrintfIntegerDigits(buffer: []u8, value: u64, base: PrintfIntegerBase) ![]const u8 {
    return switch (base) {
        .decimal => std.fmt.bufPrint(buffer, "{d}", .{value}),
        .octal => std.fmt.bufPrint(buffer, "{o}", .{value}),
        .lower_hex => std.fmt.bufPrint(buffer, "{x}", .{value}),
        .upper_hex => std.fmt.bufPrint(buffer, "{X}", .{value}),
    };
}

fn appendPadded(
    stdout: *Writer,
    text: []const u8,
    spec: PrintfSpec,
) !void {
    const width = spec.width orelse 0;
    const pad_len = if (width > text.len) width - text.len else 0;
    const pad_byte: u8 = if (spec.zero_pad and !spec.left_adjust) '0' else ' ';
    if (!spec.left_adjust) try stdout.splatByteAll(pad_byte, pad_len);
    try stdout.writeAll(text);
    if (spec.left_adjust) try stdout.splatByteAll(' ', pad_len);
}

fn isPrintfFloatSpec(spec: u8) bool {
    return switch (spec) {
        'a', 'A', 'e', 'E', 'f', 'F', 'g', 'G' => true,
        else => false,
    };
}

fn appendPrintfFloatConversion(
    allocator: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    status: *ExitStatus,
    spec: PrintfSpec,
    arg: []const u8,
) !void {
    const value = try parsePrintfFloat(stderr, status, arg);
    try printf_float.render(allocator, stdout, value, .{
        .spec = spec.spec,
        .left_adjust = spec.left_adjust,
        .zero_pad = spec.zero_pad,
        .sign_plus = spec.sign_plus,
        .sign_space = spec.sign_space,
        .alternate = spec.alternate,
        .width = spec.width,
        .precision = spec.precision,
    });
}

fn parsePrintfSigned(
    stderr: *Writer,
    status: *ExitStatus,
    arg: []const u8,
) !i64 {
    const parsed = printf_number.parseSigned(arg);
    if (parsed.diagnostic_required) try printfNumericDiagnostic(stderr, status);
    return parsed.value;
}

fn parsePrintfUnsigned(
    stderr: *Writer,
    status: *ExitStatus,
    arg: []const u8,
) !u64 {
    const parsed = printf_number.parseUnsigned(arg);
    if (parsed.diagnostic_required) try printfNumericDiagnostic(stderr, status);
    return parsed.value;
}

fn parsePrintfFloat(
    stderr: *Writer,
    status: *ExitStatus,
    arg: []const u8,
) !f64 {
    const parsed = printf_number.parseFloat(arg);
    if (parsed.diagnostic_required) try printfNumericDiagnostic(stderr, status);
    return parsed.value;
}

fn appendPrintfEscapedString(
    stdout: *Writer,
    text: []const u8,
) !bool {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] != '\\') {
            try stdout.writeByte(text[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index >= text.len) {
            try stdout.writeByte('\\');
        } else if (!try appendEscapedSequence(stdout, text, &index, .percent_b)) {
            return false;
        }
    }
    return true;
}

const PrintfEscapeMode = enum { format, percent_b };

fn appendEscapedSequence(
    stdout: *Writer,
    text: []const u8,
    index: *usize,
    mode: PrintfEscapeMode,
) !bool {
    const byte = text[index.*];
    switch (byte) {
        'a' => try stdout.writeByte(0x07),
        'b' => try stdout.writeByte(0x08),
        'c' => {
            if (mode == .format) {
                try stdout.writeByte('\\');
                return true;
            }
            index.* += 1;
            return false;
        },
        'f' => try stdout.writeByte(0x0c),
        'n' => try stdout.writeByte('\n'),
        'r' => try stdout.writeByte('\r'),
        't' => try stdout.writeByte('\t'),
        'v' => try stdout.writeByte(0x0b),
        '\\' => try stdout.writeByte('\\'),
        'x' => {
            if (mode == .format) {
                try stdout.writeByte('\\');
                return true;
            }
            try appendHexEscape(stdout, text, index);
            return true;
        },
        '0'...'7' => {
            try appendOctalEscape(stdout, text, index, mode);
            return true;
        },
        else => {
            try stdout.writeByte('\\');
            if (mode == .format) return true;
            try stdout.writeByte(byte);
        },
    }
    index.* += 1;
    return true;
}

fn appendHexEscape(
    stdout: *Writer,
    text: []const u8,
    index: *usize,
) !void {
    var value: u8 = 0;
    var count: usize = 0;
    var cursor = index.* + 1;
    while (cursor < text.len and count < 2) : (count += 1) {
        const digit = std.fmt.charToDigit(text[cursor], 16) catch break;
        value = value * 16 + digit;
        cursor += 1;
    }
    if (count == 0) {
        try stdout.writeByte('\\');
        try stdout.writeByte('x');
        index.* += 1;
    } else {
        try stdout.writeByte(value);
        index.* = cursor;
    }
}

fn appendOctalEscape(
    stdout: *Writer,
    text: []const u8,
    index: *usize,
    mode: PrintfEscapeMode,
) !void {
    var value: u16 = 0;
    var count: usize = 0;
    var cursor = index.*;
    if (mode == .percent_b and cursor < text.len and text[cursor] == '0') cursor += 1;
    while (cursor < text.len and count < 3 and text[cursor] >= '0' and text[cursor] <= '7') : (count += 1) {
        value = value * 8 + (text[cursor] - '0');
        cursor += 1;
    }
    if (count == 0) {
        try stdout.writeByte(0);
        index.* += 1;
    } else {
        try stdout.writeByte(@intCast(value & 0xff));
        index.* = cursor;
    }
}

test "printf formats integer string and character conversions without allocation" {
    var stdout_buffer: [256]u8 = undefined;
    var stdout: Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr: Writer = .fixed(&stderr_buffer);

    const status = try evaluate(
        std.testing.failing_allocator,
        &.{ "printf", "<%+05d><%.3s><%c><%b>", "7", "abcdef", "Z", "A\\nB" },
        &stdout,
        &stderr,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualStrings("<+0007><abc><Z><A\nB>", stdout.buffered());
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "printf evaluates POSIX format reuse and escapes" {
    var stdout: Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = try evaluate(
        std.testing.allocator,
        &.{ "printf", "[%5s][%-5s][%.3s][%04d]\\n", "a", "b", "abcdef", "7", "c", "d", "xyz", "8" },
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualStrings(
        "[    a][b    ][abc][0007]\n[    c][d    ][xyz][0008]\n",
        stdout.writer.buffered(),
    );
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "printf reports numeric conversion diagnostics" {
    var stdout: Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = try evaluate(
        std.testing.allocator,
        &.{ "printf", "%d:%x\n", "5x ", " 0x1fg " },
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectEqual(@as(ExitStatus, 1), status);
    try std.testing.expectEqualStrings("5:1f\n", stdout.writer.buffered());
    try std.testing.expectEqualStrings(
        "printf: numeric argument required\nprintf: numeric argument required\n",
        stderr.writer.buffered(),
    );
}

test "printf reports trailing bytes after quoted integer constants" {
    var stdout: Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = try evaluate(
        std.testing.allocator,
        &.{ "printf", "%d\n", "'3", "\"+3", "'-3" },
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectEqual(@as(ExitStatus, 1), status);
    try std.testing.expectEqualStrings("51\n43\n45\n", stdout.writer.buffered());
    try std.testing.expectEqualStrings(
        "printf: numeric argument required\nprintf: numeric argument required\n",
        stderr.writer.buffered(),
    );
}

test "printf format operand does not recognize hexadecimal escapes" {
    var stdout: Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = try evaluate(
        std.testing.allocator,
        &.{ "printf", "A\\x41Z\\n" },
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualStrings("A\\x41Z\n", stdout.writer.buffered());
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "printf octal escapes wrap to one byte" {
    var stdout: Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = try evaluate(
        std.testing.allocator,
        &.{ "printf", "A\\400B:%b", "C\\0777D" },
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0, 'B', ':', 'C', 255, 'D' }, stdout.writer.buffered());
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "printf formats floating point conversions without C snprintf" {
    var stdout: Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = try evaluate(
        std.testing.allocator,
        &.{
            "printf",
            "<%f><%.2f><%e><%E><%g><%G><%a><%A>\n",
            "1.5",
            "1.5",
            "1000",
            "1000",
            "1000",
            "1000",
            "1.5",
            "1.5",
        },
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectEqual(@as(ExitStatus, 0), status);
    try std.testing.expectEqualStrings(
        "<1.500000><1.50><1.000000e+03><1.000000E+03><1000><1000><0x1.8p+0><0X1.8P+0>\n",
        stdout.writer.buffered(),
    );
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "printf floating point formatting applies flags width precision and partial numeric diagnostics" {
    var stdout: Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const status = try evaluate(
        std.testing.allocator,
        &.{
            "printf",
            "<%+ f><%+010.2f><% 10.2e><%-10.3g><%#.0f><%#.3g><%.0f><%.1f><%.0g><%.0a><%010.2a><%.1a><%.2f><%.2f>\n",
            "1.5",
            "1.5",
            "1.5",
            "1000",
            "1",
            "1000",
            "2.5",
            "1.25",
            "2.5",
            "1.5",
            "1.5",
            "0x1.08p0",
            " 1.5 ",
            "0x10.1p2x",
        },
        &stdout.writer,
        &stderr.writer,
    );

    try std.testing.expectEqual(@as(ExitStatus, 1), status);
    const expected_stdout = "<+1.500000><+000001.50><  1.50e+00><1e+03     ><1.><1.00e+03>" ++
        "<2><1.2><2><0x2p+0><0x01.80p+0><0x1.0p+0><1.50><64.25>\n";
    try std.testing.expectEqualStrings(
        expected_stdout,
        stdout.writer.buffered(),
    );
    try std.testing.expectEqualStrings("printf: numeric argument required\n", stderr.writer.buffered());
}
