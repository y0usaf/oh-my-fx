const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const openai_codex = @import("openai_codex.zig");
const openai_codex_models = @import("openai_codex_models.zig");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");

const Allocator = std.mem.Allocator;

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewCodex,
};

fn reviewCodex(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return responses_reviewer.review(alloc, input, request, .{
        .source = .chatgpt_subscription,
        .model = openai_codex_models.reviewer_model,
        .validate_fn = validateCredential,
        .build_fn = openai_codex.buildRequest,
        .send_fn = sendPrepared,
    });
}

fn validateCredential(
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    const account_id = try chatgpt_oauth.extractAccountId(alloc, input.credential);
    alloc.free(account_id);
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return openai_codex.streamPrepared(alloc, request, payload);
}


