const std = @import("std");
const git_context = @import("git_context.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const ConversationLanguage = types.ConversationLanguage;

pub const Workflow = enum {
    pull_request,
    issue,
};

const PromptSnapshot = struct {
    in_git_repo: bool,
    text: []const u8,
};

pub fn buildPrompt(alloc: Allocator, workflow: Workflow, language: ConversationLanguage, context: []const u8) ![]u8 {
    const snapshot = try git_context.snapshot(alloc);
    defer snapshot.deinit(alloc);
    return buildPromptFromSnapshot(alloc, workflow, language, context, .{
        .in_git_repo = snapshot.in_git_repo,
        .text = snapshot.text,
    });
}

fn buildPromptFromSnapshot(alloc: Allocator, workflow: Workflow, language: ConversationLanguage, context: []const u8, snapshot: PromptSnapshot) ![]u8 {
    _ = language;
    const trimmed = std.mem.trim(u8, context, " \t\r\n");
    if (workflow == .pull_request and !snapshot.in_git_repo) return error.NotGitRepository;
    return switch (workflow) {
        .pull_request => buildPullRequestPrompt(alloc, trimmed, snapshot.text),
        .issue => buildIssuePrompt(alloc, trimmed, snapshot.text),
    };
}

fn buildPullRequestPrompt(alloc: Allocator, context: []const u8, snapshot_text: []const u8) ![]u8 {
    return if (context.len > 0)
        std.fmt.allocPrint(alloc, "Draft a GitHub pull request for the current branch. Reply in the same natural language as the current session. Additional context: {s}. Use this prepared git snapshot first and avoid shell commands unless they are truly necessary:\n\n{s}\n\nIf you need more context, read relevant files. Return only: Title, blank line, then a GitHub-flavored Markdown body with sections '## Summary' and '## Testing'. Do not create the PR with gh or publish anything unless I explicitly ask you to.", .{ context, snapshot_text })
    else
        std.fmt.allocPrint(alloc, "Draft a GitHub pull request for the current branch. Reply in the same natural language as the current session. Use this prepared git snapshot first and avoid shell commands unless they are truly necessary:\n\n{s}\n\nIf you need more context, read relevant files. Return only: Title, blank line, then a GitHub-flavored Markdown body with sections '## Summary' and '## Testing'. Do not create the PR with gh or publish anything unless I explicitly ask you to.", .{snapshot_text});
}

fn buildIssuePrompt(alloc: Allocator, context: []const u8, snapshot_text: []const u8) ![]u8 {
    return if (context.len > 0)
        std.fmt.allocPrint(alloc, "Draft a GitHub issue from the current context. Reply in the same natural language as the current session. Additional context: {s}. Use this prepared git snapshot first and avoid shell commands unless they are truly necessary:\n\n{s}\n\nIf you need more context, inspect relevant files, errors, or logs. Return only: Title, blank line, then a GitHub-flavored Markdown body with sections '## Summary', '## Steps to Reproduce', '## Expected', and '## Actual'. Do not create the issue with gh or publish anything unless I explicitly ask you to.", .{ context, snapshot_text })
    else
        std.fmt.allocPrint(alloc, "Draft a GitHub issue from the current context. Reply in the same natural language as the current session. Use this prepared git snapshot first and avoid shell commands unless they are truly necessary:\n\n{s}\n\nIf you need more context, inspect relevant files, errors, or logs. Return only: Title, blank line, then a GitHub-flavored Markdown body with sections '## Summary', '## Steps to Reproduce', '## Expected', and '## Actual'. Do not create the issue with gh or publish anything unless I explicitly ask you to.", .{snapshot_text});
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) == null);
}





