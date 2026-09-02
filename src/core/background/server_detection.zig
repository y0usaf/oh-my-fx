const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

pub fn detectServerUrl(alloc: std.mem.Allocator, external_path: []const u8) !?[]u8 {
    const content = readLogSnapshot(alloc, external_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(content);

    return detectServerUrlFromContent(alloc, content);
}

pub fn detectServerUrlFromContent(
    alloc: std.mem.Allocator,
    content: []const u8,
) !?[]u8 {
    const url = extractUrl(content) orelse return null;
    return try alloc.dupe(u8, url);
}

pub fn isLikelyServerCommand(command: []const u8) bool {
    return hasCommandTokensInOrder(command, &.{ "npm", "run", "dev" }) or
        hasCommandTokensInOrder(command, &.{ "npm", "run", "start" }) or
        hasCommandTokensInOrder(command, &.{ "pnpm", "dev" }) or
        hasCommandTokensInOrder(command, &.{ "pnpm", "run", "dev" }) or
        hasCommandTokensInOrder(command, &.{ "pnpm", "start" }) or
        hasCommandTokensInOrder(command, &.{ "yarn", "dev" }) or
        hasCommandTokensInOrder(command, &.{ "yarn", "start" }) or
        hasCommandTokensInOrder(command, &.{ "bun", "dev" }) or
        hasCommandTokensInOrder(command, &.{ "bun", "run", "dev" }) or
        hasCommandTokensInOrder(command, &.{ "next", "dev" }) or
        hasCommandTokensInOrder(command, &.{"vite"}) or
        hasCommandTokensInOrder(command, &.{ "astro", "dev" }) or
        hasCommandTokensInOrder(command, &.{"serve"});
}

fn hasCommandTokensInOrder(command: []const u8, expected: []const []const u8) bool {
    if (expected.len == 0) return false;

    var token_index: usize = 0;
    var i: usize = 0;
    while (i < command.len) {
        while (i < command.len and !isCommandTokenByte(command[i])) : (i += 1) {}
        if (i >= command.len) break;

        const start = i;
        while (i < command.len and isCommandTokenByte(command[i])) : (i += 1) {}
        const token = command[start..i];
        if (std.ascii.eqlIgnoreCase(token, expected[token_index])) {
            token_index += 1;
            if (token_index == expected.len) return true;
        }
    }

    return false;
}

fn isCommandTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == '/';
}

fn readLogSnapshot(alloc: std.mem.Allocator, external_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        external_path,
        .{},
    );
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 64 * 1024);
}

fn extractUrl(text: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    var best_url: ?[]const u8 = null;
    var best_score: i32 = std.math.minInt(i32);
    var best_start: usize = 0;

    while (nextUrlCandidate(text, search_start)) |candidate| {
        const score = scoreUrlCandidate(candidate.url, candidate.line);
        if (best_url == null or score > best_score or (score == best_score and candidate.start > best_start)) {
            best_url = candidate.url;
            best_score = score;
            best_start = candidate.start;
        }
        search_start = candidate.start + candidate.url.len;
    }

    return best_url;
}

const UrlCandidate = struct {
    url: []const u8,
    line: []const u8,
    start: usize,
};

fn nextUrlCandidate(text: []const u8, search_start: usize) ?UrlCandidate {
    const schemes = [_][]const u8{ "http://", "https://" };

    var best_start: ?usize = null;
    for (schemes) |scheme| {
        if (std.mem.indexOfPos(u8, text, search_start, scheme)) |start| {
            if (best_start == null or start < best_start.?) {
                best_start = start;
            }
        }
    }

    const start = best_start orelse return null;
    var end = start;
    while (end < text.len) : (end += 1) {
        const ch = text[end];
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == ')' or ch == '"' or ch == '\'') {
            break;
        }
    }

    const line_start = if (std.mem.findScalarLast(u8, text[0..start], '\n')) |index| index + 1 else 0;
    const line_end = std.mem.findScalarPos(u8, text, end, '\n') orelse text.len;

    return .{
        .url = text[start..end],
        .line = text[line_start..line_end],
        .start = start,
    };
}

fn scoreUrlCandidate(url: []const u8, line: []const u8) i32 {
    var score: i32 = 0;

    if (text_utils.containsIgnoreCase(url, "localhost") or std.mem.find(u8, url, "127.0.0.1") != null or std.mem.find(u8, url, "[::1]") != null) {
        score += 100;
    } else if (std.mem.find(u8, url, "0.0.0.0") != null) {
        score += 80;
    } else if (std.mem.find(u8, url, "192.168.") != null or std.mem.find(u8, url, "10.") != null or std.mem.find(u8, url, "172.") != null) {
        score += 40;
    }

    if (text_utils.containsIgnoreCase(line, "local")) score += 20;
    if (text_utils.containsIgnoreCase(line, "url")) score += 6;
    if (text_utils.containsIgnoreCase(line, "ready") or text_utils.containsIgnoreCase(line, "started") or text_utils.containsIgnoreCase(line, "listening") or text_utils.containsIgnoreCase(line, "server")) score += 10;
    if (text_utils.containsIgnoreCase(line, "network")) score -= 15;
    if (text_utils.containsIgnoreCase(line, "error") or text_utils.containsIgnoreCase(line, "warn")) score -= 25;

    return score;
}
