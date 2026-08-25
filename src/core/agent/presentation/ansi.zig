const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const io_mod = @import("../../shared/io.zig");

pub const bold_open = "\x1b[1m";
pub const bold_close = "\x1b[22m";
pub const italic_open = "\x1b[3m";
pub const italic_close = "\x1b[23m";
pub const dim_open = "\x1b[2m";
pub const dim_close = "\x1b[22m";
pub const underline_open = "\x1b[4m";
pub const underline_close = "\x1b[24m";
const task_completed_dark_open = "\x1b[38;5;252m";
const task_completed_light_open = "\x1b[38;5;238m";
pub var task_completed_open: []const u8 = task_completed_dark_open;
pub const task_completed_close = "\x1b[39m";
pub const strike_open = "\x1b[9m";
pub const strike_close = "\x1b[29m";
const inline_code_dark_open = "\x1b[38;5;245m";
const inline_code_light_open = "\x1b[38;5;247m";
pub var inline_code_open: []const u8 = inline_code_dark_open;
pub const inline_code_close = "\x1b[39m";

pub fn setInlineCodeTheme(light: bool) void {
    inline_code_open = if (light) inline_code_light_open else inline_code_dark_open;
    task_completed_open = if (light) task_completed_light_open else task_completed_dark_open;
}

// Keeps table intersections aligned with row separators.
pub const table_column_sep = " \xe2\x94\x82 ";
pub const table_horiz = "\xe2\x94\x80";
pub const table_junction = "\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80";
pub const vertical_rule_prefix = "\xe2\x94\x82 ";
pub const bullet_marker = "\xe2\x80\xa2 ";
pub const task_pending_marker = "\xe2\x98\x90";
pub const task_completed_marker = "\xe2\x9c\x93";

pub const max_pipe_buffer_bytes: usize = 32 * 1024;
/// Default rule length when no terminal width is discoverable.
pub const horizontal_rule_default_width: usize = 60;
/// Test hook: when set, writeHorizontalRule uses this width verbatim.
pub var horizontal_rule_width_override: ?usize = null;

fn resolveTerminalColumns() ?usize {
    if (comptime builtin.os.tag == .windows) return null;
    if (comptime !builtin.link_libc) return null;
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const req: c_int = @intCast(std.c.T.IOCGWINSZ);
    if (std.c.ioctl(std.posix.STDOUT_FILENO, req, &ws) == -1) return null;
    if (ws.col == 0) return null;
    return @as(usize, @intCast(ws.col));
}

/// Rule width: explicit override, then terminal size, then COLUMNS, then default.
pub fn horizontalRuleWidth() usize {
    if (horizontal_rule_width_override) |w| return w;
    if (resolveTerminalColumns()) |cols| return cols;
    if (io_mod.getenv("COLUMNS")) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len > 0) {
            if (std.fmt.parseInt(usize, trimmed, 10) catch null) |cols| {
                if (cols >= 20 and cols <= 500) return cols;
            }
        }
    }
    return horizontal_rule_default_width;
}
/// OSC 8 links longer than this fall back to literal rendering.
pub const max_link_url_bytes: usize = 2083;

pub fn writeDim(alloc: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try out.appendSlice(alloc, dim_open);
    try out.appendSlice(alloc, bytes);
    try out.appendSlice(alloc, dim_close);
}

pub fn writeHorizontalRule(alloc: Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(alloc, dim_open);
    var i: usize = 0;
    const width = horizontalRuleWidth();
    while (i < width) : (i += 1) try out.appendSlice(alloc, table_horiz);
    try out.appendSlice(alloc, dim_close);
}
