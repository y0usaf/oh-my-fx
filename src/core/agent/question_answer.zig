const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const EncodeError = Allocator.Error || std.Io.Writer.Error || error{
    AnswerCountMismatch,
};

/// Encodes ordered question entries and answers as an owned JSON result.
/// The caller owns the returned slice and must free it with `alloc`.
pub fn encodeJson(
    alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
    answers: []const []const u8,
) EncodeError![]u8 {
    if (entries.len != answers.len) return error.AnswerCountMismatch;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"question\":");
        try std.json.Stringify.value(entry.question, .{}, &out.writer);
        try out.writer.writeAll(",\"answer\":");
        try std.json.Stringify.value(answers[index], .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");

    return out.toOwnedSlice();
}

/// Decodes a successful question result. Returned strings borrow from `output`
/// or allocations in `arena`; both must outlive the returned answers.
pub fn decodeJson(
    arena: Allocator,
    output: []const u8,
) Allocator.Error!?[]const types.QuestionAnswer {
    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        output,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    if (root != .array) return null;
    const items = root.array.items;
    if (items.len < 1 or items.len > 4) return null;

    const answers = try arena.alloc(types.QuestionAnswer, items.len);
    for (items, 0..) |item, index| {
        if (item != .object) return null;
        const question = item.object.get("question") orelse return null;
        const answer = item.object.get("answer") orelse return null;
        if (question != .string or answer != .string) return null;
        answers[index] = .{
            .question = question.string,
            .answer = answer.string,
        };
    }

    return answers;
}
