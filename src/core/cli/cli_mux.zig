const runtime = @import("../mux/runtime.zig");

pub const Options = struct {
    resume_id: ?[]const u8 = null,
};

pub fn parseArgs(args: []const [:0]const u8) !Options {
    if (args.len > 1) return error.TooManyArguments;
    return .{ .resume_id = if (args.len == 1) args[0] else null };
}

pub fn run(options: Options) !u8 {
    return runtime.run(options.resume_id);
}

test "mux parses at most one resume id" {
    const std = @import("std");
    try std.testing.expect((try parseArgs(&.{})).resume_id == null);
    try std.testing.expectEqualStrings("session-1", (try parseArgs(&.{"session-1"})).resume_id.?);
    try std.testing.expectError(error.TooManyArguments, parseArgs(&.{ "one", "two" }));
}
