//! Static per-provider model catalog fallbacks generated from models.dev and
//! vendor /models endpoints (see scripts/generate_provider_models.ts), plus
//! the generic live-fetch-with-fallback seam every provider descriptor shares.
const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_provider = @import("../core/config/model_provider.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const chat_completions = @import("chat_completions.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

pub const generated = @import("provider_catalogs_generated_data.zig");
pub const Entry = generated.Entry;

comptime {
    if (generated.entries.len != std.meta.fields(model_provider.ProviderId).len) {
        @compileError("generated catalog rows out of sync with ProviderId variants");
    }
    for (std.meta.tags(model_provider.ProviderId), generated.provider_names) |tag, name| {
        if (!std.mem.eql(u8, @tagName(tag), name)) {
            @compileError("generated catalog row order out of sync with ProviderId: " ++ name);
        }
    }
}

/// Borrowed generated row for one provider; entries alias comptime rodata.
pub fn generatedSlice(provider: model_provider.ProviderId) []const Entry {
    return generated.entries[@intFromEnum(provider)];
}

/// Converts the generated row into owned catalog entries whose id/model_type
/// strings the caller releases with `freeModelCatalog`.
pub fn dupGeneratedCatalog(
    alloc: Allocator,
    provider: model_provider.ProviderId,
) Allocator.Error!std.ArrayList(model_catalog.ModelCatalogEntry) {
    const static_entries = generatedSlice(provider);
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    try catalog.ensureTotalCapacity(alloc, static_entries.len);
    for (static_entries) |static_entry| {
        const id = try alloc.dupe(u8, static_entry.id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        catalog.appendAssumeCapacity(.{
            .id = id,
            .model_type = model_type,
            .released = static_entry.released,
            .has_tool_use = static_entry.has_tool_use,
            .has_reasoning = static_entry.has_reasoning,
            .reasoning_efforts = .empty,
            .supports_fast_mode = static_entry.supports_fast_mode,
            .has_vision = static_entry.has_vision,
            .has_file_input = static_entry.has_file_input,
            .has_web_search = false,
            .has_explicit_caching = false,
            .has_implicit_caching = false,
            .context_window = static_entry.context_window,
            .max_tokens = static_entry.max_tokens,
            .web_search_price = null,
        });
    }
    return catalog;
}

/// Live `/models` seam for one descriptor: attaches Authorization only to the
/// provider that owns the active credential and parses the tolerant
/// OpenAI-style listing shape. Pair with
/// `model_catalog.fetchWithPublicFallback` (or `fetchWithGeneratedFallback`)
/// for provenance handling.
pub fn catalogProviderFor(descriptor: *const model_provider.Descriptor) model_catalog.Provider {
    return .{
        .context = @constCast(descriptor),
        .fetch_fn = fetchLiveCatalog,
    };
}

/// CLI projection of `catalogProviderFor`: serves bare model ids.
pub fn cliCatalogProviderFor(descriptor: *const model_provider.Descriptor) gateway_provider.CliModelCatalogProvider {
    return .{
        .context = @constCast(descriptor),
        .fetch_fn = fetchCliModelCatalog,
    };
}

/// Runs the live fetch with anonymous-fallback semantics, then degrades to the
/// generated static row when every live attempt failed. Cancellation always
/// propagates; auth failures fall back too so a rejected key still yields a
/// usable picker backed by checked-in data.
pub fn fetchWithGeneratedFallback(
    descriptor: *const model_provider.Descriptor,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) model_catalog.FetchResult {
    const result = model_catalog.fetchWithPublicFallback(catalogProviderFor(descriptor), alloc, input);
    switch (result) {
        .loaded => return result,
        .failed => |failed| {
            if (failed.failure.category == .cancellation) return result;
            const catalog = dupGeneratedCatalog(alloc, descriptor.id) catch
                return .{ .failed = failed };
            return .{ .loaded = .{
                .catalog = catalog,
                .provenance = .{
                    .access = model_catalog.AccessMetadata.init(input.access),
                    .anonymous_fallback_used = failed.anonymous_fallback_used,
                    .fallback_failure = failed.failure,
                },
            } };
        },
    }
}

fn fetchCliModelCatalog(
    context: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));
    return switch (model_catalog.fetchWithPublicFallback(catalogProviderFor(descriptor), alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchLiveCatalog(
    context: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const descriptor: *const model_provider.Descriptor = @ptrCast(@alignCast(context.?));

    // Never send one provider's credential to another provider's endpoint:
    // only the credential whose origin is exactly this descriptor travels.
    const credential = catalogCredential(descriptor, input.access);

    const request_url = modelsUrl(alloc, descriptor) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var response = fetchCatalogResponse(alloc, request_url, credential, cancel_flag, deadline) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .{ .failure = .{ .category = .cancellation } };
        return .{ .failure = .{ .category = .transport, .retryable = true } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

/// Authorization bytes for a live catalog fetch, or null. A credential moves
/// only when its declared origin equals this descriptor's provider; foreign
/// provider keys, gateway stacks, and subscriptions never travel.
fn catalogCredential(
    descriptor: *const model_provider.Descriptor,
    access: credentials.CatalogAccess,
) ?[]const u8 {
    const source = access.credentialSource() orelse return null;
    const expected: types.CredentialSource = .{ .provider_api_key = descriptor.id };
    if (!source.eql(expected)) return null;
    return access.authorizationCredential();
}

const max_catalog_models: usize = 4096;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;

fn e2eModelsEnvName(buf: []u8, slug: []const u8) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll("FX_E2E_") catch return null;
    for (slug) |ch| {
        const mapped: u8 = switch (ch) {
            'a'...'z' => ch - 32,
            '-', '.' => '_',
            else => ch,
        };
        writer.writeByte(mapped) catch return null;
    }
    writer.writeAll("_MODELS_URL") catch return null;
    return writer.buffered();
}

fn modelsUrl(alloc: Allocator, descriptor: *const model_provider.Descriptor) ![]u8 {
    var name_buf: [64]u8 = undefined;
    const env_name = e2eModelsEnvName(&name_buf, model_provider.providerSlug(descriptor.id)) orelse
        return error.InvalidE2EModelsEndpointName;
    if (io_mod.getenv(env_name)) |override| {
        // E2E overrides must stay on loopback so tests never exfiltrate.
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EModelsEndpoint;
        return alloc.dupe(u8, override);
    }
    if (descriptor.base_url.len == 0) return error.ProviderCatalogEndpointMissing;
    return chat_completions.resolveEndpointUrl(alloc, descriptor.base_url, "/models");
}

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: ?[]const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        var auth_header_storage: ?[]u8 = null;
        defer if (auth_header_storage) |value| secret.zeroAndFree(self.alloc, value);
        if (self.credential) |credential| {
            auth_header_storage = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{credential});
        }
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer self.alloc.free(body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = if (auth_header_storage) |value|
                    .{ .override = value }
                else
                    .default,
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{
                .{ .name = "accept", .value = "application/json" },
            },
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ProviderCatalogTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_catalog_bytes) return error.ProviderCatalogTooLarge;
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn fetchCatalogResponse(
    alloc: Allocator,
    url: []const u8,
    credential: ?[]const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !FetchResponse {
    var operation = FetchOperation{
        .alloc = alloc,
        .url = url,
        .credential = credential,
    };
    return gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

/// Parses the tolerant OpenAI-style `{data:[...]}` listing shape. Rich
/// metadata (`architecture`, `supported_parameters`, `context_length`) is
/// extracted when present; plain `{id}` listings still yield entries with
/// zeroed limits and conservative capabilities.
fn parseCatalog(
    alloc: Allocator,
    body_json: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProviderModelCatalog;
    const data = parsed.value.object.get("data") orelse
        return error.InvalidProviderModelCatalog;
    if (data != .array) return error.InvalidProviderModelCatalog;
    if (data.array.items.len > max_catalog_models) return error.InvalidProviderModelCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |value| {
        if (value != .object) continue;
        const entry = parseCatalogEntry(alloc, value.object) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SkipEntry => continue,
        };
        try catalog.append(alloc, entry);
    }
    return catalog;
}

fn parseCatalogEntry(alloc: Allocator, object: std.json.ObjectMap) !model_catalog.ModelCatalogEntry {
    const raw_id = optionalString(object.get("id")) orelse return error.SkipEntry;
    if (raw_id.len == 0 or raw_id.len > max_model_id_bytes) return error.SkipEntry;
    for (raw_id) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.SkipEntry;
    }

    // Rich listings carry an architecture object; tolerate its absence and
    // only drop models we positively know cannot emit text.
    const architecture = optionalObject(object.get("architecture"));
    if (architecture) |arch| {
        if (optionalStringArray(arch.get("output_modalities"))) |output_modalities| {
            if (!stringArrayContains(output_modalities, "text")) return error.SkipEntry;
        }
    }
    const input_modalities: ?std.json.Array = if (architecture) |arch|
        optionalStringArray(arch.get("input_modalities"))
    else
        null;
    const supported_parameters = optionalStringArray(object.get("supported_parameters"));

    const context_window: u32 = blk: {
        const value = object.get("context_length") orelse break :blk 0;
        if (value != .integer) break :blk 0;
        if (value.integer <= 0 or value.integer > std.math.maxInt(u32)) break :blk 0;
        break :blk @intCast(value.integer);
    };

    const id = try alloc.dupe(u8, raw_id);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    return .{
        .id = id,
        .model_type = model_type,
        .has_tool_use = stringArrayContains(supported_parameters, "tools"),
        .has_reasoning = stringArrayContains(supported_parameters, "reasoning"),
        .reasoning_efforts = .empty,
        .has_vision = stringArrayContains(input_modalities, "image"),
        .has_file_input = stringArrayContains(input_modalities, "file"),
        .context_window = context_window,
    };
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const unwrapped = value orelse return null;
    if (unwrapped != .string) return null;
    return unwrapped.string;
}

fn optionalObject(value: ?std.json.Value) ?std.json.ObjectMap {
    const unwrapped = value orelse return null;
    if (unwrapped != .object) return null;
    return unwrapped.object;
}

fn optionalStringArray(value: ?std.json.Value) ?std.json.Array {
    const unwrapped = value orelse return null;
    if (unwrapped != .array) return null;
    return unwrapped.array;
}

fn stringArrayContains(array: ?std.json.Array, needle: []const u8) bool {
    const unwrapped = array orelse return false;
    for (unwrapped.items) |item| {
        if (item == .string and std.ascii.eqlIgnoreCase(item.string, needle)) return true;
    }
    return false;
}

test "every generated row is populated and sorted by id" {
    inline for (std.meta.tags(model_provider.ProviderId)) |provider| {
        const slice = generatedSlice(provider);
        try std.testing.expect(slice.len > 0);
        var index: usize = 1;
        while (index < slice.len) : (index += 1) {
            try std.testing.expect(std.mem.lessThan(u8, slice[index - 1].id, slice[index].id));
        }
    }
}

test "dupGeneratedCatalog yields owned entries freed by freeModelCatalog" {
    const alloc = std.testing.allocator;
    var catalog = try dupGeneratedCatalog(alloc, .deepseek);
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try std.testing.expect(catalog.items.len == generatedSlice(.deepseek).len);
    try std.testing.expectEqualStrings(generatedSlice(.deepseek)[0].id, catalog.items[0].id);
    try std.testing.expectEqualStrings("language", catalog.items[0].model_type);
}

test "provider catalog parses rich openrouter-shaped listings" {
    const body =
        \\{"data":[
        \\  {"id":"vendor/rich","context_length":200000,
        \\   "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
        \\   "supported_parameters":["tools","reasoning"]},
        \\  {"id":"vendor/embed","context_length":1024,
        \\   "architecture":{"input_modalities":["text"],"output_modalities":["embeddings"]}}
        \\]}
    ;
    var catalog = try parseCatalog(std.testing.allocator, body);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    const rich = catalog.items[0];
    try std.testing.expectEqualStrings("vendor/rich", rich.id);
    try std.testing.expect(rich.has_tool_use);
    try std.testing.expect(rich.has_reasoning);
    try std.testing.expect(rich.has_vision);
    try std.testing.expectEqual(@as(u32, 200000), rich.context_window);
}

test "provider catalog tolerates listings without architecture metadata" {
    const body =
        \\{"data":[
        \\  {"id":"plain/model"},
        \\  {"id":"plain/limited","context_length":8192}
        \\]}
    ;
    var catalog = try parseCatalog(std.testing.allocator, body);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    for (catalog.items) |item| {
        try std.testing.expect(!item.has_tool_use);
        try std.testing.expect(!item.has_reasoning);
        try std.testing.expect(!item.has_vision);
    }
    try std.testing.expectEqual(@as(u32, 0), catalog.items[0].context_window);
    try std.testing.expectEqual(@as(u32, 8192), catalog.items[1].context_window);
}

test "e2e model list env names uppercase provider slugs" {
    var buf: [64]u8 = undefined;
    const name = e2eModelsEnvName(&buf, "google-vertex").?;
    try std.testing.expectEqualStrings("FX_E2E_GOOGLE_VERTEX_MODELS_URL", name);
}

test "foreign credentials never attach to another provider's catalog fetch" {
    const alloc = std.testing.allocator;
    const descriptor = model_provider.ProviderId.openrouter.descriptor();
    const expected_openrouter: types.CredentialSource = .{ .provider_api_key = .openrouter };

    // Matching origin travels.
    const matching_source: types.CredentialSource = .{ .provider_api_key = .openrouter };
    try std.testing.expect(matching_source.eql(expected_openrouter));
    // Foreign origins never do.
    inline for (.{ .deepseek, .anthropic, .groq }) |foreign| {
        const foreign_source: types.CredentialSource = .{ .provider_api_key = foreign };
        try std.testing.expect(!foreign_source.eql(expected_openrouter));
    }
    const gateway_source: types.CredentialSource = .ai_gateway_api_key;
    try std.testing.expect(!gateway_source.eql(expected_openrouter));
    const chatgpt_source: types.CredentialSource = .chatgpt_subscription;
    try std.testing.expect(!chatgpt_source.eql(expected_openrouter));

    // Public-only access never carries authorization bytes regardless.
    const public_access: credentials.CatalogAccess = .{ .public_only = .no_credential };
    try std.testing.expect(catalogCredential(descriptor, public_access) == null);
    _ = alloc;
}

const CaptureFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    body: []const u8,
    saw_authorization: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    server_open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn init(body: []const u8) !@This() {
        var fixture: @This() = .{ .server = undefined, .body = body };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.server_open) return;
        const zio = self.io();
        self.stopping.store(true, .seq_cst);
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            self.wakeAccept();
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
        self.server_open = false;
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn wakeAccept(self: *@This()) void {
        var wake_io_backend: std.Io.Threaded = .init_single_threaded;
        const zio = wake_io_backend.io();
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        var stream = address.connect(zio, .{ .mode = .stream }) catch return;
        stream.close(zio);
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and err == error.SocketNotListening) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        var stream = try self.server.accept(zio);
        defer stream.close(zio);
        if (self.stopping.load(.seq_cst)) return;
        var socket_buffer: [4096]u8 = undefined;
        var reader = stream.reader(zio, &socket_buffer);
        var request: [16 * 1024]u8 = undefined;
        var request_len: usize = 0;
        while (request_len < request.len) {
            request[request_len] = try reader.interface.takeByte();
            request_len += 1;
            if (std.mem.endsWith(u8, request[0..request_len], "\r\n\r\n")) break;
        } else return error.TestRequestTooLarge;
        if (std.ascii.indexOfIgnoreCase(request[0..request_len], "authorization:") != null) {
            self.saw_authorization.store(true, .seq_cst);
        }

        var writer_buffer: [16 * 1024]u8 = undefined;
        var writer = stream.writer(zio, &writer_buffer);
        try writer.interface.print(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{self.body.len},
        );
        try writer.interface.writeAll(self.body);
        try writer.interface.flush();
    }
};

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;
    const map = try std.heap.page_allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(std.heap.page_allocator);
    stable_test_environ = map;
    return map;
}

const EndpointEnvironment = struct {
    map: std.process.Environ.Map,

    fn install(env_name: []const u8, models_url: []const u8) !*@This() {
        _ = try stableTestEnviron();
        const self = try std.heap.page_allocator.create(@This());
        self.* = .{ .map = std.process.Environ.Map.init(std.heap.page_allocator) };
        errdefer std.heap.page_allocator.destroy(self);
        try self.map.put(env_name, models_url);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *@This()) void {
        io_mod.setEnvironMap(stable_test_environ.?);
        self.map.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

test "live catalog fetch sends credentials only to the owning provider" {
    const alloc = std.testing.allocator;
    const body = "{\"data\":[{\"id\":\"loop/model\",\"context_length\":4096}]}";
    var fixture = try CaptureFixture.init(body);
    defer fixture.deinit();
    try fixture.start();
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/models", .{fixture.port()});
    defer alloc.free(url);

    var name_buf: [64]u8 = undefined;
    const env_name_buf = e2eModelsEnvName(&name_buf, "openrouter").?;
    const env_name = try alloc.dupe(u8, env_name_buf);
    defer alloc.free(env_name);

    // Foreign provider key: fetch succeeds anonymously, no Authorization sent.
    {
        const environment = try EndpointEnvironment.install(env_name, url);
        defer environment.deinit();
        const descriptor = model_provider.ProviderId.openrouter.descriptor();
        const foreign_access: credentials.CatalogAccess = .{ .authenticated = .{
            .source = .{ .provider_api_key = .deepseek },
            .credential = "deepseek-secret",
            .team_context = null,
        } };
        const result = try catalogProviderFor(descriptor).fetch(alloc, .{
            .access = foreign_access,
            .endpoint = "",
        });
        switch (result) {
            .catalog => |catalog| {
                var owned = catalog;
                defer model_catalog.freeModelCatalog(alloc, &owned);
                try std.testing.expectEqual(@as(usize, 1), owned.items.len);
                try std.testing.expectEqualStrings("loop/model", owned.items[0].id);
            },
            .failure => return error.TestExpectedCatalogSuccess,
        }
    }
    try std.testing.expect(fixture.failure == null);
    try std.testing.expect(!fixture.saw_authorization.load(.seq_cst));
}

test "live catalog fetch attaches the owning provider's key" {
    const alloc = std.testing.allocator;
    const body = "{\"data\":[{\"id\":\"loop/model\"}]}";
    var fixture = try CaptureFixture.init(body);
    defer fixture.deinit();
    try fixture.start();
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/models", .{fixture.port()});
    defer alloc.free(url);

    var name_buf: [64]u8 = undefined;
    const env_name_buf = e2eModelsEnvName(&name_buf, "openrouter").?;
    const env_name = try alloc.dupe(u8, env_name_buf);
    defer alloc.free(env_name);

    const environment = try EndpointEnvironment.install(env_name, url);
    defer environment.deinit();
    const descriptor = model_provider.ProviderId.openrouter.descriptor();
    const access: credentials.CatalogAccess = .{ .authenticated = .{
        .source = .{ .provider_api_key = .openrouter },
        .credential = "openrouter-secret",
        .team_context = null,
    } };
    const result = try catalogProviderFor(descriptor).fetch(alloc, .{
        .access = access,
        .endpoint = "",
    });
    switch (result) {
        .catalog => |catalog| {
            var owned = catalog;
            defer model_catalog.freeModelCatalog(alloc, &owned);
            try std.testing.expectEqual(@as(usize, 1), owned.items.len);
        },
        .failure => return error.TestExpectedCatalogSuccess,
    }
    try std.testing.expect(fixture.failure == null);
    try std.testing.expect(fixture.saw_authorization.load(.seq_cst));
}

test "generated fallback serves static rows with live failure provenance" {
    const alloc = std.testing.allocator;
    // Port 1 on loopback refuses connections: deterministic transport failure.
    const environment = try EndpointEnvironment.install(
        "FX_E2E_DEEPSEEK_MODELS_URL",
        "http://127.0.0.1:1/models",
    );
    defer environment.deinit();
    const descriptor = model_provider.ProviderId.deepseek.descriptor();
    var result = fetchWithGeneratedFallback(descriptor, alloc, .{
        .access = .{ .public_only = .no_credential },
        .endpoint = "",
    });
    defer switch (result) {
        .loaded => |*loaded| model_catalog.freeModelCatalog(alloc, &loaded.catalog),
        .failed => {},
    };
    switch (result) {
        .loaded => |loaded| {
            try std.testing.expect(!loaded.provenance.anonymous_fallback_used);
            try std.testing.expectEqual(
                model_catalog.FailureCategory.transport,
                loaded.provenance.fallback_failure.?.category,
            );
            const static_entries = generatedSlice(.deepseek);
            try std.testing.expect(loaded.catalog.items.len == static_entries.len);
            for (loaded.catalog.items, static_entries) |owned, static_entry| {
                try std.testing.expectEqualStrings(static_entry.id, owned.id);
            }
        },
        .failed => return error.TestExpectedGeneratedFallback,
    }
}
