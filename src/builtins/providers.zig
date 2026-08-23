//! Registry-driven provider routing. Every variant resolves through its
//! comptime descriptor: fx-native transports stay hand-wired, every other
//! protocol dispatches on the descriptor pointer.
const std = @import("std");
const model_provider = @import("../core/config/model_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway = @import("gateway.zig");
const anthropic_messages = @import("../gateway/anthropic_messages.zig");
const bedrock_converse = @import("../gateway/bedrock_converse.zig");
const chat_completions = @import("../gateway/chat_completions.zig");
const google_generative_ai = @import("../gateway/google_generative_ai.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_responses = @import("../gateway/openai_responses.zig");
const provider_catalogs = @import("../gateway/provider_catalogs.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");

pub fn agentStream(provider: model_provider.ProviderId) stream_provider.Provider {
    const descriptor = provider.descriptor();
    return switch (descriptor.protocol) {
        .fx_gateway => gateway.agent_stream_provider,
        .codex_responses => openai_codex.agent_stream_provider,
        .chat_completions => chat_completions.providerFor(descriptor),
        .anthropic_messages => anthropic_messages.providerFor(descriptor),
        .google_generative_ai => google_generative_ai.providerFor(descriptor),
        .openai_responses => openai_responses.providerFor(descriptor),
        .bedrock_converse => bedrock_converse.providerFor(descriptor),
    };
}

pub fn modelCatalog(provider: model_provider.ProviderId) model_catalog.Provider {
    return switch (provider) {
        .gateway => gateway.model_catalog_provider,
        .codex => openai_codex_models.model_catalog_provider,
        .grok => xai_grok_models.model_catalog_provider,
        inline else => |id| provider_catalogs.catalogProviderFor(id.descriptor()),
    };
}
test "subscription providers opt out of Gateway usage observation" {
    try std.testing.expect(agentStream(.gateway).observes_gateway_usage);
    try std.testing.expect(!agentStream(.codex).observes_gateway_usage);
    try std.testing.expect(!agentStream(.grok).observes_gateway_usage);
    // Descriptor-driven transports inherit their descriptor's observation flag.
    inline for ([_]model_provider.ProviderId{ .openrouter, .deepseek }) |id| {
        try std.testing.expectEqual(
            id.descriptor().observes_gateway_usage,
            agentStream(id).observes_gateway_usage,
        );
    }
}
