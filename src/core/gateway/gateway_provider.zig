const std = @import("std");
const credentials = @import("../auth/credentials.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const output_contracts = @import("../output/output_contracts.zig");
const model_catalog = @import("model_catalog.zig");
const model_catalog_metadata = @import("model_catalog_metadata.zig");

const Allocator = std.mem.Allocator;

pub const ResolveChatUrlFn = *const fn (?*anyopaque, []const u8) []const u8;

pub const ChatUrlProvider = struct {
    /// When set, context must remain valid until every in-flight `resolve` returns.
    context: ?*anyopaque = null,
    resolve_fn: ResolveChatUrlFn,

    pub fn resolve(self: ChatUrlProvider, fallback: []const u8) []const u8 {
        return self.resolve_fn(self.context, fallback);
    }
};

pub const CliModelCatalogInput = struct {
    access: credentials.CatalogAccess = .{ .public_only = .no_credential },
    endpoint: []const u8,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const CliModelCatalogResult = union(enum) {
    loaded: struct {
        /// Owned model id strings; the caller frees them with `collections.freeStringList`.
        ids: std.ArrayList([]u8),
        provenance: model_catalog.Provenance,
    },
    failure: model_catalog.FailedOutcome,
};

pub const FetchCliModelCatalogFn = *const fn (
    ?*anyopaque,
    Allocator,
    CliModelCatalogInput,
) CliModelCatalogResult;

pub const CliModelCatalogProvider = struct {
    /// When set, context must remain valid until every in-flight `fetch` returns.
    context: ?*anyopaque = null,
    fetch_fn: FetchCliModelCatalogFn,

    pub fn fetch(
        self: CliModelCatalogProvider,
        alloc: Allocator,
        input: CliModelCatalogInput,
    ) CliModelCatalogResult {
        return self.fetch_fn(self.context, alloc, input);
    }
};

pub const CreditsLookupInput = struct {
    credential: ?[]const u8,
    credential_source: ?credentials.Source = null,
    tenant: ?[]const u8,
};

pub const FetchCreditsFn = *const fn (
    ?*anyopaque,
    Allocator,
    CreditsLookupInput,
) output_contracts.CreditsSnapshot;

pub const CreditsProvider = struct {
    /// When set, context must remain valid until every in-flight `fetch` returns.
    context: ?*anyopaque = null,
    fetch_fn: FetchCreditsFn,

    /// The returned snapshot owns its populated provider fields. The caller
    /// must call `CreditsSnapshot.deinit`.
    pub fn fetch(
        self: CreditsProvider,
        alloc: Allocator,
        input: CreditsLookupInput,
    ) output_contracts.CreditsSnapshot {
        return self.fetch_fn(self.context, alloc, input);
    }
};

fn fetchCreditsUnavailable(
    _: ?*anyopaque,
    alloc: Allocator,
    _: CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return .{
        .err_message = alloc.dupe(u8, "Credits are unavailable for the selected provider.") catch null,
    };
}

pub const unavailable_credits_provider = CreditsProvider{
    .fetch_fn = fetchCreditsUnavailable,
};

pub const Provider = struct {
    oauth_transport: oauth_transport.Provider,
    chat_url: ChatUrlProvider,
};


const CapabilityResolverState = enum {
    idle,
    ready,
    failed,
};

pub const CapabilityResolver = struct {
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty,
    state: CapabilityResolverState = .idle,

    pub fn deinit(self: *CapabilityResolver, alloc: Allocator) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
    }

    pub fn resolve(
        self: *CapabilityResolver,
        alloc: Allocator,
        provider: model_catalog.Provider,
        input: model_catalog.FetchInput,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
    ) model_capabilities.ResolveError!model_capabilities.Capabilities {
        if (self.state == .idle) {
            const result = model_catalog.fetchWithPublicFallback(provider, alloc, input);
            const loaded = switch (result) {
                .loaded => |loaded| loaded,
                .failed => |failed| {
                    const failure = failed.failure;
                    if (failure.category == .cancellation) {
                        debug_trace.logf(
                            "gateway",
                            "model catalog lookup outcome=cancelled model={s}",
                            .{model},
                        );
                        return failCapabilities(error.Cancelled);
                    }
                    self.state = .failed;
                    debug_trace.logf(
                        "gateway",
                        "model catalog lookup outcome=fetch_failed model={s} category={t}",
                        .{ model, failure.category },
                    );
                    return fallback;
                },
            };
            self.catalog = loaded.catalog;
            self.state = .ready;
        }

        if (self.state == .failed) {
            debug_trace.logf(
                "gateway",
                "model catalog lookup outcome=cache_failed model={s}",
                .{model},
            );
            return fallback;
        }
        for (self.catalog.items) |entry| {
            if (std.mem.eql(u8, entry.id, model)) {
                debug_trace.logf(
                    "gateway",
                    "model catalog lookup outcome=ready_hit model={s}",
                    .{model},
                );
                return model_capabilities.mergeCapabilities(
                    fallback,
                    model_catalog_metadata.fromCatalogEntry(entry),
                );
            }
        }
        debug_trace.logf(
            "gateway",
            "model catalog lookup outcome=missing_entry model={s}",
            .{model},
        );
        return fallback;
    }

    pub fn available(
        self: *const CapabilityResolver,
        model: []const u8,
        fallback: model_capabilities.Capabilities,
    ) model_capabilities.Capabilities {
        if (self.state == .ready) {
            for (self.catalog.items) |entry| {
                if (std.mem.eql(u8, entry.id, model)) {
                    return model_capabilities.mergeCapabilities(
                        fallback,
                        model_catalog_metadata.fromCatalogEntry(entry),
                    );
                }
            }
        }
        return fallback;
    }

    pub fn catalogEntries(self: *const CapabilityResolver) ?[]const model_catalog.ModelCatalogEntry {
        if (self.state != .ready) return null;
        return self.catalog.items;
    }

    pub fn adoptOwnedCatalog(
        self: *CapabilityResolver,
        alloc: Allocator,
        owned_catalog: *std.ArrayList(model_catalog.ModelCatalogEntry),
    ) void {
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.catalog = owned_catalog.*;
        owned_catalog.* = .empty;
        self.state = .ready;
    }
};

inline fn failCapabilities(err: anytype) @TypeOf(err)!model_capabilities.Capabilities {
    return @errorCast(failCapabilitiesDynamic(err));
}

noinline fn failCapabilitiesDynamic(err: anyerror) anyerror!model_capabilities.Capabilities {
    return err;
}


const FakeCatalog = struct {
    outcome: enum {
        cancelled,
        unavailable,
        authenticated_rejected_then_ready,
        ready,
    },
    calls: usize = 0,
    saw_authenticated_access: bool = false,
    saw_public_retry: bool = false,

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: model_catalog.FetchInput,
    ) Allocator.Error!model_catalog.ProviderResult {
        const self: *FakeCatalog = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.outcome == .authenticated_rejected_then_ready) {
            if (self.calls == 1) {
                self.saw_authenticated_access =
                    std.mem.eql(u8, input.access.authorizationCredential() orelse "", "test-key") and
                    std.mem.eql(u8, input.access.teamContext() orelse "", "team_123");
                return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
            }
            self.saw_public_retry =
                input.access.authorizationCredential() == null and
                input.access.teamContext() == null and
                input.access.publicOnlyReason() == .authenticated_credential_rejected;
            self.outcome = .ready;
        }
        switch (self.outcome) {
            .cancelled => return .{ .failure = .{ .category = .cancellation } },
            .unavailable => return .{ .failure = .{ .category = .transport } },
            .authenticated_rejected_then_ready => unreachable,
            .ready => {
                var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
                errdefer model_catalog.freeModelCatalog(alloc, &entries);
                const id = try alloc.dupe(u8, "provider/model");
                errdefer alloc.free(id);
                const model_type = try alloc.dupe(u8, "language");
                errdefer alloc.free(model_type);
                const entry = model_catalog.ModelCatalogEntry{
                    .id = id,
                    .model_type = model_type,
                    .has_vision = true,
                    .has_file_input = true,
                    .context_window = 256_000,
                    .max_tokens = 32_000,
                };
                try entries.append(alloc, entry);
                return .{ .catalog = entries };
            },
        }
    }

    fn provider(self: *FakeCatalog) model_catalog.Provider {
        return .{
            .context = self,
            .fetch_fn = fetch,
        };
    }
};


const FakeChatUrl = struct {
    resolved: []const u8,

    fn resolve(raw: ?*anyopaque, fallback: []const u8) []const u8 {
        const self: *FakeChatUrl = @ptrCast(@alignCast(raw.?));
        _ = fallback;
        return self.resolved;
    }
};





