const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const generation_usage_provider = @import("../session/generation_usage_provider.zig");
const gateway_provider = @import("gateway_provider.zig");
const web_search_provider = @import("../tooling/web_search_provider.zig");
const auto_classifier = @import("../permissions/auto_classifier.zig");
const model_catalog = @import("model_catalog.zig");

const Allocator = std.mem.Allocator;

pub const Bundle = struct {
    pub const AuthStrategy = enum {
        vercel,
        chatgpt,
        grok,
    };
    pub const Capabilities = struct {
        fx_search: bool = false,
        vision_fallback: bool = false,
    };

    capabilities: Capabilities = .{},
    presentation: ?*const provider_catalog.Entry = null,
    auth_strategy: ?AuthStrategy = null,
    fallback_model_capabilities_fn: *const fn ([]const u8) model_capabilities.Capabilities = emptyModelCapabilities,
    agent_stream: ?stream_provider.Provider = null,
    cli_model_catalog: ?gateway_provider.CliModelCatalogProvider = null,
    model_catalog: ?model_catalog.Provider = null,
    permission_reviewer: ?auto_classifier.Provider = null,
    deferred_usage: ?generation_usage_provider.Provider = null,
    credits: ?gateway_provider.CreditsProvider = null,
    fx_search: ?web_search_provider.Provider = null,

    pub fn agent_stream_or_unavailable(self: Bundle) stream_provider.Provider {
        return self.agent_stream orelse stream_provider.unavailable_provider;
    }

    pub fn fallbackModelCapabilities(self: Bundle, model: []const u8) model_capabilities.Capabilities {
        return self.fallback_model_capabilities_fn(model);
    }
};

fn emptyModelCapabilities(_: []const u8) model_capabilities.Capabilities {
    return .{};
}

pub const Set = struct {
    gateway: Bundle,
    codex: Bundle,
    grok: Bundle,

    pub fn select(self: Set, provider: model_provider.ProviderId) Bundle {
        return switch (provider) {
            .gateway => self.gateway,
            .codex => self.codex,
            .grok => self.grok,
        };
    }

    pub fn deferredUsageProviders(self: Set) generation_usage_provider.Set {
        return .{
            .gateway = self.gateway.deferred_usage,
            .codex = self.codex.deferred_usage,
            .grok = self.grok.deferred_usage,
        };
    }
};

pub fn gateway_only(gateway: Bundle) Set {
    return .{
        .gateway = gateway,
        .codex = .{},
        .grok = .{},
    };
}
