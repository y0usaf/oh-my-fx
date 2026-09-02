const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Workflow = enum {
    pull_request,
    issue,
};

pub const Draft = struct {
    title: []u8,
    body: []u8,

    pub fn deinit(self: Draft, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
    }
};

pub const PublishResult = struct {
    ok: bool,
    text: []u8,

    pub fn deinit(self: PublishResult, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

const CompletedProcess = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

pub fn parseDraft(alloc: Allocator, text: []const u8) !Draft {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidGithubDraft;

    const first_break = std.mem.findScalar(u8, trimmed, '\n') orelse {
        const title = try alloc.dupe(u8, trimmed);
        errdefer alloc.free(title);
        const body = try alloc.dupe(u8, "");
        return .{
            .title = title,
            .body = body,
        };
    };

    const title_slice = std.mem.trim(u8, trimmed[0..first_break], " \t\r\n");
    if (title_slice.len == 0) return error.InvalidGithubDraft;

    const body_slice = std.mem.trimStart(u8, trimmed[first_break + 1 ..], " \t\r\n");
    const title = try alloc.dupe(u8, title_slice);
    errdefer alloc.free(title);
    const body = try alloc.dupe(u8, body_slice);
    return .{
        .title = title,
        .body = body,
    };
}

pub fn publish(alloc: Allocator, workflow: Workflow, draft: Draft) !PublishResult {
    var argv = try buildPublishArgv(alloc, workflow, draft.title, draft.body);
    defer argv.deinit(alloc);

    const result = runPublishCommand(alloc, argv.items) catch |err| {
        return publishResultFromRunError(alloc, err);
    };
    return publishResultFromProcess(alloc, result);
}

fn buildPublishArgv(alloc: Allocator, workflow: Workflow, title: []const u8, body: []const u8) !std.ArrayList([]const u8) {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(alloc);

    try argv.append(alloc, "gh");
    try argv.append(alloc, switch (workflow) {
        .pull_request => "pr",
        .issue => "issue",
    });
    try argv.append(alloc, "create");
    try argv.append(alloc, "--title");
    try argv.append(alloc, title);
    try argv.append(alloc, "--body");
    try argv.append(alloc, body);
    return argv;
}

fn runPublishCommand(alloc: Allocator, argv: []const []const u8) !CompletedProcess {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn publishResultFromRunError(alloc: Allocator, err: anyerror) !PublishResult {
    return switch (err) {
        error.FileNotFound => .{ .ok = false, .text = try alloc.dupe(u8, "gh CLI not found in PATH") },
        else => err,
    };
}

fn publishResultFromProcess(alloc: Allocator, result: CompletedProcess) !PublishResult {
    defer alloc.free(result.stderr);

    if (result.term.exited != 0) {
        defer alloc.free(result.stdout);
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_trimmed.len > 0) {
            return .{ .ok = false, .text = try alloc.dupe(u8, stderr_trimmed) };
        }
        return .{ .ok = false, .text = try alloc.dupe(u8, "gh command failed") };
    }

    const stdout_trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (stdout_trimmed.len == 0) {
        alloc.free(result.stdout);
        return .{ .ok = true, .text = try alloc.dupe(u8, "created successfully") };
    }
    if (stdout_trimmed.len == result.stdout.len) {
        return .{ .ok = true, .text = result.stdout };
    }

    const text = alloc.dupe(u8, stdout_trimmed) catch |err| {
        alloc.free(result.stdout);
        return err;
    };
    alloc.free(result.stdout);
    return .{ .ok = true, .text = text };
}
