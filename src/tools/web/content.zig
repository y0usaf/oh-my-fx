const std = @import("std");
const content_contract = @import("../../core/tooling/web_fetch_content_contract.zig");
const text_utils = @import("../../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const max_converted_content_bytes = content_contract.max_converted_content_bytes;
pub const Kind = content_contract.Kind;
pub const Classification = content_contract.Classification;

pub fn classify(alloc: Allocator, content_type: ?[]const u8, body: []const u8) !Classification {
    if (content_type) |declared| {
        const normalized = try normalizedMime(alloc, declared);
        errdefer alloc.free(normalized);
        return .{
            .kind = declaredKind(normalized),
            .mime_type = normalized,
            .declared = true,
        };
    }

    if (text_utils.isModelSafeText(body)) {
        return .{
            .kind = .text,
            .mime_type = try alloc.dupe(u8, "text/plain"),
            .declared = false,
        };
    }

    return .{
        .kind = .binary,
        .mime_type = try alloc.dupe(u8, "application/octet-stream"),
        .declared = false,
    };
}

fn normalizedMime(alloc: Allocator, content_type: []const u8) ![]u8 {
    const parameter_start = std.mem.findScalar(u8, content_type, ';') orelse content_type.len;
    const trimmed = std.mem.trim(u8, content_type[0..parameter_start], " \t\r\n");
    if (trimmed.len == 0) return alloc.dupe(u8, "application/octet-stream");

    const normalized = try alloc.alloc(u8, trimmed.len);
    for (trimmed, 0..) |char, index| normalized[index] = std.ascii.toLower(char);
    return normalized;
}

fn declaredKind(mime: []const u8) Kind {
    if (std.mem.eql(u8, mime, "text/html")) return .html;
    if (std.mem.eql(u8, mime, "application/xhtml+xml")) return .html;
    if (std.mem.startsWith(u8, mime, "text/")) return .text;
    if (std.mem.eql(u8, mime, "application/json")) return .text;
    if (std.mem.eql(u8, mime, "application/xml")) return .text;
    if (std.mem.eql(u8, mime, "application/javascript")) return .text;
    if (std.mem.eql(u8, mime, "application/x-javascript")) return .text;
    if (std.mem.startsWith(u8, mime, "application/") and std.mem.endsWith(u8, mime, "+json")) return .text;
    if (std.mem.startsWith(u8, mime, "application/") and std.mem.endsWith(u8, mime, "+xml")) return .text;
    return .binary;
}
