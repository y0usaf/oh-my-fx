const std = @import("std");

const builtin_tools = @import("tools.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const command_provider_contract = @import("../core/mcp/command_provider.zig");
const mcp_contract = @import("../core/mcp/mcp_contract.zig");
const mcp_health = @import("../core/mcp/health.zig");
const project_config = @import("../core/mcp/project_config.zig");
const workspace_config = @import("../core/mcp/workspace_config.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const elicitation = @import("../core/mcp/elicitation.zig");
const streamable_http = @import("../core/mcp/streamable_http.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const text_utils = @import("../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const CommandRequest = command_provider_contract.Request;
const CommandResult = command_provider_contract.Result;
const McpServerConfig = mcp_contract.McpServerConfig;
const McpTransport = mcp_contract.McpTransport;

const add_usage = "Usage: /mcp add <name> <command> [args...] or /mcp add --transport http <name> <url>";
const profile_lock_deadline_ms: u64 = 2_000;

pub const command_provider = command_provider_contract.Provider{ .handle_fn = handleCommand };

fn handleCommand(alloc: Allocator, rest: []const u8, command_request: CommandRequest) !CommandResult {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) {
        const summarize = command_request.summarize_servers orelse
            command_request.list_servers_and_tools;
        const summary = try summarize(command_request.list_ctx, alloc);
        errdefer alloc.free(summary);
        return .{
            .display = .{
                .block = try appendProfileWarning(
                    alloc,
                    command_request.home,
                    summary,
                ),
            },
        };
    }
    if (std.mem.eql(u8, trimmed, "list")) {
        const listing = try command_request.list_servers_and_tools(
            command_request.list_ctx,
            alloc,
        );
        errdefer alloc.free(listing);
        return .{
            .display = .{
                .block = try appendProfileWarning(
                    alloc,
                    command_request.home,
                    listing,
                ),
            },
        };
    }

    if (std.mem.startsWith(u8, trimmed, "resource ")) {
        return handleResourceCommand(alloc, std.mem.trimStart(u8, trimmed[9..], " \t"), command_request);
    }
    if (std.mem.startsWith(u8, trimmed, "prompt ")) {
        return handlePromptCommand(alloc, std.mem.trimStart(u8, trimmed[7..], " \t"), command_request);
    }

    const home = command_request.home orelse return lineLiteral(alloc, "HOME is not available.", false);
    const config_path = try configPathFromHome(alloc, home);
    defer alloc.free(config_path);

    if (std.mem.eql(u8, trimmed, "path")) {
        return lineParts(alloc, &.{config_path}, false);
    }

    if (std.mem.eql(u8, trimmed, "reload")) {
        var maybe_document: ?project_config.ProfileParseResult =
            loadProfileDocumentFromPath(alloc, config_path) catch null;
        defer if (maybe_document) |*document| document.deinit(alloc);
        if (maybe_document) |document| if (document.diagnostic) |warning| {
            const warning_text = try renderProfileWarning(alloc, warning);
            defer alloc.free(warning_text);
            return .{
                .display = .{ .line = try std.fmt.allocPrint(
                    alloc,
                    "{s}\nEvaluating trusted profile MCP configuration.",
                    .{warning_text},
                ) },
                .reload = true,
                .report_reload = true,
            };
        };
        return .{
            .display = .{
                .line = try alloc.dupe(u8, "Evaluating trusted profile MCP configuration."),
            },
            .reload = true,
            .report_reload = true,
        };
    }

    if (std.mem.startsWith(u8, trimmed, "trust ")) {
        var tokens = std.mem.tokenizeAny(u8, trimmed[6..], " \t");
        const operation = tokens.next() orelse
            return lineLiteral(alloc, "Usage: /mcp trust approve|reject <server> | approve-all | reset", false);
        if (std.mem.eql(u8, operation, "approve-all")) {
            if (tokens.next() != null) return lineLiteral(alloc, "Usage: /mcp trust approve-all", false);
            return .{
                .display = .{ .line = try alloc.dupe(u8, "Approving all project MCP servers for this workspace.") },
                .project_action = .approve_all,
            };
        }
        if (std.mem.eql(u8, operation, "reset")) {
            if (tokens.next() != null) return lineLiteral(alloc, "Usage: /mcp trust reset", false);
            return .{
                .display = .{ .line = try alloc.dupe(u8, "Resetting project MCP choices for this workspace.") },
                .project_action = .reset,
            };
        }
        const name = tokens.next() orelse
            return lineLiteral(alloc, "Usage: /mcp trust approve|reject <server>", false);
        if (tokens.next() != null) return lineLiteral(alloc, "Usage: /mcp trust approve|reject <server>", false);
        if (std.mem.eql(u8, operation, "approve")) {
            return .{
                .display = .{ .line = try std.fmt.allocPrint(alloc, "Approving project MCP server '{s}'.", .{name}) },
                .project_action = .{ .approve = name },
            };
        }
        if (std.mem.eql(u8, operation, "reject")) {
            return .{
                .display = .{ .line = try std.fmt.allocPrint(alloc, "Rejecting project MCP server '{s}'.", .{name}) },
                .project_action = .{ .reject = name },
            };
        }
        return lineLiteral(alloc, "Usage: /mcp trust approve|reject <server> | approve-all | reset", false);
    }

    if (std.mem.startsWith(u8, trimmed, "auth ")) {
        var tokens = std.mem.tokenizeAny(u8, trimmed[5..], " \t");
        const name = tokens.next() orelse
            return lineLiteral(alloc, "Usage: /mcp auth <name> [--open]", false);
        const confirmation = tokens.next();
        if (tokens.next() != null or
            (confirmation != null and !std.mem.eql(u8, confirmation.?, "--open")))
        {
            return lineLiteral(alloc, "Usage: /mcp auth <name> [--open]", false);
        }
        const validate = command_request.validate_authentication_server orelse
            return lineLiteral(
                alloc,
                "Interactive MCP authentication is unavailable here.",
                false,
            );
        validate(command_request.auth_ctx orelse command_request.list_ctx, name) catch |err| {
            return lineParts(
                alloc,
                &.{ "MCP authentication for '", name, "' failed: ", @errorName(err), "." },
                false,
            );
        };
        if (confirmation == null) {
            return lineParts(
                alloc,
                &.{ "Run /mcp auth ", name, " --open to confirm opening your browser." },
                false,
            );
        }
        const authenticate = command_request.authenticate_server orelse
            return lineLiteral(
                alloc,
                "Interactive MCP authentication is unavailable here.",
                false,
            );
        const authentication = authenticate(
            command_request.auth_ctx orelse command_request.list_ctx,
            name,
        ) catch |err| {
            return lineParts(
                alloc,
                &.{ "MCP authentication for '", name, "' failed: ", @errorName(err), "." },
                false,
            );
        };
        return switch (authentication) {
            .started => lineParts(
                alloc,
                &.{ "Waiting for MCP authentication for '", name, "'. You can continue using fx while the browser flow completes." },
                false,
            ),
            .busy => lineParts(
                alloc,
                &.{ "MCP authentication for '", name, "' is already in progress or MCP configuration is reloading." },
                false,
            ),
        };
    }

    if (std.mem.startsWith(u8, trimmed, "logout ")) {
        const name = std.mem.trim(u8, trimmed[7..], " \t");
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t") != null) {
            return lineLiteral(alloc, "Usage: /mcp logout <name>", false);
        }
        const logout = command_request.logout_server orelse
            return lineLiteral(alloc, "MCP logout is unavailable here.", false);
        const result = logout(
            command_request.auth_ctx orelse command_request.list_ctx,
            name,
        ) catch |err| {
            return lineParts(
                alloc,
                &.{ "MCP logout for '", name, "' failed: ", @errorName(err), "." },
                false,
            );
        };
        if (result.busy) {
            return lineParts(
                alloc,
                &.{ "MCP authentication for '", name, "' is still in progress. Wait for it to finish before logging out." },
                false,
            );
        }
        if (!result.removed) {
            return lineParts(
                alloc,
                &.{ "No stored MCP credentials found for '", name, "'." },
                false,
            );
        }
        if (result.repaired_entries > 0) {
            const text = if (result.revocation_failed)
                try std.fmt.allocPrint(
                    alloc,
                    "Logged out of MCP server '{s}' locally; remote revocation failed. Removed {d} unreadable MCP credential {s}.",
                    .{
                        name,
                        result.repaired_entries,
                        if (result.repaired_entries == 1) "entry" else "entries",
                    },
                )
            else
                try std.fmt.allocPrint(
                    alloc,
                    "Logged out of MCP server '{s}'. Removed {d} unreadable MCP credential {s}.",
                    .{
                        name,
                        result.repaired_entries,
                        if (result.repaired_entries == 1) "entry" else "entries",
                    },
                );
            return .{
                .display = .{ .line = text },
                .reload = !result.local_only,
            };
        }
        if (result.revocation_failed) {
            return lineParts(
                alloc,
                &.{ "Logged out of MCP server '", name, "' locally; remote revocation failed." },
                !result.local_only,
            );
        }
        return lineParts(
            alloc,
            &.{ "Logged out of MCP server '", name, "'." },
            !result.local_only,
        );
    }

    if (std.mem.startsWith(u8, trimmed, "remove ")) {
        const name = std.mem.trim(u8, trimmed[7..], " \t");
        if (name.len == 0) {
            return lineLiteral(alloc, "Usage: /mcp remove <name>", false);
        }

        const removed = removeServerFromPath(alloc, config_path, name) catch |err| {
            return lineParts(
                alloc,
                &.{ "Failed to remove MCP server '", name, "': ", @errorName(err), "." },
                false,
            );
        };
        if (!removed) {
            return lineParts(alloc, &.{ "MCP server '", name, "' not found." }, false);
        }
        return lineParts(alloc, &.{ "Removed MCP server '", name, "'." }, true);
    }

    if (std.mem.startsWith(u8, trimmed, "add ")) {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer tokens.deinit(alloc);

        var it = std.mem.tokenizeAny(u8, trimmed[4..], " \t");
        while (it.next()) |token| try tokens.append(alloc, token);

        const intent = command_provider_contract.parseAddIntent(tokens.items) catch |err| switch (err) {
            error.McpAddUsage => return lineLiteral(alloc, add_usage, false),
            else => return lineParts(
                alloc,
                &.{ "Failed to save MCP server config: ", @errorName(err), "." },
                false,
            ),
        };
        const warning = addProfileServerToPath(alloc, config_path, intent) catch |err| {
            return lineParts(
                alloc,
                &.{ "Failed to save MCP server config: ", @errorName(err), "." },
                false,
            );
        };
        const name = switch (intent) {
            .local => |local| local.name,
            .http => |http| http.name,
        };
        if (warning) |value| {
            const warning_text = try renderProfileWarning(alloc, value);
            defer alloc.free(warning_text);
            return lineParts(
                alloc,
                &.{ warning_text, "\nSaved MCP server '", name, "'." },
                true,
            );
        }
        return lineParts(alloc, &.{ "Saved MCP server '", name, "'." }, true);
    }

    return lineLiteral(
        alloc,
        "Usage: /mcp [list|resource|prompt|add|remove|path|reload|auth|logout|trust]",
        false,
    );
}

fn appendProfileWarning(
    alloc: Allocator,
    home: ?[]const u8,
    owned_body: []u8,
) ![]u8 {
    const home_path = home orelse return owned_body;
    const path = try configPathFromHome(alloc, home_path);
    defer alloc.free(path);
    var document = loadProfileDocumentFromPath(alloc, path) catch return owned_body;
    defer document.deinit(alloc);
    const warning = document.diagnostic orelse return owned_body;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(owned_body);
    if (out.written().len > 0 and out.written()[out.written().len - 1] != '\n') {
        try out.writer.writeByte('\n');
    }
    const warning_text = try renderProfileWarning(alloc, warning);
    defer alloc.free(warning_text);
    try out.writer.writeAll(warning_text);
    try out.writer.writeByte('\n');
    const rendered = try out.toOwnedSlice();
    alloc.free(owned_body);
    return rendered;
}

fn renderProfileWarning(
    alloc: Allocator,
    warning: project_config.ProfileDiagnostic,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("MCP config warning: {s}", .{@tagName(warning.cause)});
    if (warning.key()) |key| {
        const encoded = try text_utils.encodeTerminalSafe(alloc, key, 128);
        defer alloc.free(encoded.bytes);
        try out.writer.print(" key={s}", .{encoded.bytes});
    }
    try out.writer.print(
        " additional_matches={d}",
        .{warning.additional_matches},
    );
    return out.toOwnedSlice();
}

fn handleResourceCommand(alloc: Allocator, rest: []const u8, command_request: CommandRequest) !CommandResult {
    var input = rest;
    const action = takeToken(&input) orelse return lineLiteral(
        alloc,
        "Usage: /mcp resource [list|templates|read|complete] ...",
        false,
    );
    const context = command_request.feature_ctx orelse command_request.list_ctx;
    if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "templates")) {
        const server = takeToken(&input) orelse return lineLiteral(
            alloc,
            "Usage: /mcp resource list <server> or /mcp resource templates <server>",
            false,
        );
        if (takeToken(&input) != null) return lineLiteral(
            alloc,
            "Usage: /mcp resource list <server> or /mcp resource templates <server>",
            false,
        );
        const callback = command_request.list_resources orelse return lineLiteral(alloc, "MCP resources are unavailable here.", false);
        const text = callback(context, alloc, server, std.mem.eql(u8, action, "templates")) catch |err| {
            return lineParts(alloc, &.{ "MCP resource listing failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    if (std.mem.eql(u8, action, "read")) {
        const server = takeToken(&input) orelse return lineLiteral(alloc, "Usage: /mcp resource read <server> <uri>", false);
        const uri = std.mem.trim(u8, input, " \t");
        if (uri.len == 0) return lineLiteral(alloc, "Usage: /mcp resource read <server> <uri>", false);
        const callback = command_request.read_resource orelse return lineLiteral(alloc, "MCP resource reads are unavailable here.", false);
        const text = callback(context, alloc, server, uri) catch |err| {
            return lineParts(alloc, &.{ "MCP resource read failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    if (std.mem.eql(u8, action, "complete")) {
        const server = takeToken(&input) orelse return resourceCompletionUsage(alloc);
        const uri_template = takeToken(&input) orelse return resourceCompletionUsage(alloc);
        const variable_name = takeToken(&input) orelse return resourceCompletionUsage(alloc);
        const value = std.mem.trim(u8, input, " \t");
        const callback = command_request.complete_resource orelse return lineLiteral(alloc, "MCP resource completion is unavailable here.", false);
        const text = callback(context, alloc, server, uri_template, variable_name, value) catch |err| {
            return lineParts(alloc, &.{ "MCP resource completion failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    return lineLiteral(alloc, "Usage: /mcp resource [list|templates|read|complete] ...", false);
}

fn handlePromptCommand(alloc: Allocator, rest: []const u8, command_request: CommandRequest) !CommandResult {
    var input = rest;
    const action = takeToken(&input) orelse return lineLiteral(
        alloc,
        "Usage: /mcp prompt [list|get|complete] ...",
        false,
    );
    const context = command_request.feature_ctx orelse command_request.list_ctx;
    if (std.mem.eql(u8, action, "list")) {
        const server = takeToken(&input) orelse return lineLiteral(alloc, "Usage: /mcp prompt list <server>", false);
        if (takeToken(&input) != null) return lineLiteral(alloc, "Usage: /mcp prompt list <server>", false);
        const callback = command_request.list_prompts orelse return lineLiteral(alloc, "MCP prompts are unavailable here.", false);
        const text = callback(context, alloc, server) catch |err| {
            return lineParts(alloc, &.{ "MCP prompt listing failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    if (std.mem.eql(u8, action, "get")) {
        const server = takeToken(&input) orelse return promptGetUsage(alloc);
        const prompt_name = takeToken(&input) orelse return promptGetUsage(alloc);
        const arguments_json = if (std.mem.trim(u8, input, " \t").len > 0)
            std.mem.trim(u8, input, " \t")
        else
            "{}";
        const callback = command_request.get_prompt orelse return lineLiteral(alloc, "MCP prompt invocation is unavailable here.", false);
        const text = callback(context, alloc, server, prompt_name, arguments_json) catch |err| {
            return lineParts(alloc, &.{ "MCP prompt invocation failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    if (std.mem.eql(u8, action, "complete")) {
        const server = takeToken(&input) orelse return promptCompletionUsage(alloc);
        const prompt_name = takeToken(&input) orelse return promptCompletionUsage(alloc);
        const argument_name = takeToken(&input) orelse return promptCompletionUsage(alloc);
        const value = std.mem.trim(u8, input, " \t");
        const callback = command_request.complete_prompt orelse return lineLiteral(alloc, "MCP prompt completion is unavailable here.", false);
        const text = callback(context, alloc, server, prompt_name, argument_name, value) catch |err| {
            return lineParts(alloc, &.{ "MCP prompt completion failed: ", @errorName(err), "." }, false);
        };
        return .{ .display = .{ .block = text } };
    }
    return lineLiteral(alloc, "Usage: /mcp prompt [list|get|complete] ...", false);
}

fn takeToken(input: *[]const u8) ?[]const u8 {
    input.* = std.mem.trimStart(u8, input.*, " \t");
    if (input.*.len == 0) return null;
    const end = std.mem.indexOfAny(u8, input.*, " \t") orelse input.*.len;
    const token = input.*[0..end];
    input.* = input.*[end..];
    return token;
}

fn resourceCompletionUsage(alloc: Allocator) !CommandResult {
    return lineLiteral(alloc, "Usage: /mcp resource complete <server> <uri-template> <variable> [value]", false);
}

fn promptGetUsage(alloc: Allocator) !CommandResult {
    return lineLiteral(alloc, "Usage: /mcp prompt get <server> <name> [arguments-json]", false);
}

fn promptCompletionUsage(alloc: Allocator) !CommandResult {
    return lineLiteral(alloc, "Usage: /mcp prompt complete <server> <name> <argument> [value]", false);
}

fn lineLiteral(alloc: Allocator, text: []const u8, reload: bool) !CommandResult {
    return .{ .display = .{ .line = try alloc.dupe(u8, text) }, .reload = reload };
}

// Non-generic on purpose: a comptime-format sibling stamps out one
// formatter instantiation per call shape; every message here is a plain
// string splice.
fn lineParts(alloc: Allocator, parts: []const []const u8, reload: bool) !CommandResult {
    return .{ .display = .{ .line = try std.mem.concat(alloc, u8, parts) }, .reload = reload };
}

pub fn configPathFromHome(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.mcpConfigPath(alloc, home);
}

pub fn addProfileServer(
    alloc: Allocator,
    intent: command_provider_contract.AddIntent,
) !command_provider_contract.ProfileAddResult {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const config_path = try configPathFromHome(alloc, home);
    errdefer alloc.free(config_path);
    const warning = try addProfileServerToPath(alloc, config_path, intent);
    return .{ .profile_path = config_path, .warning = warning };
}

pub fn removeProfileServer(
    alloc: Allocator,
    name: []const u8,
) !command_provider_contract.ProfileRemoveResult {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const config_path = try configPathFromHome(alloc, home);
    errdefer alloc.free(config_path);
    const result = try removeProfileServerFromPath(alloc, config_path, name);
    return .{
        .profile_path = config_path,
        .removed = result.removed,
        .warning = result.warning,
    };
}

pub fn loadRuntime(
    alloc: Allocator,
    workspace_root: []const u8,
    elicitation_capabilities: elicitation.Capabilities,
) !?*mcp_runtime.McpRuntime {
    var profile: std.ArrayList(McpServerConfig) = .empty;
    defer freeConfigs(alloc, &profile);
    if (io_mod.getenv("HOME")) |home| {
        const config_path = try configPathFromHome(alloc, home);
        defer alloc.free(config_path);
        profile = try loadConfigFromPath(alloc, config_path);
    }

    var choice_load = config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("mcp", "workspace MCP choices unavailable err={s}", .{@errorName(err)});
        return runtimeFromConfigs(alloc, &profile, elicitation_capabilities);
    };
    defer choice_load.deinit(alloc);
    for (choice_load.diagnostics.items) |diagnostic| {
        var name_buf: [256]u8 = undefined;
        debug_trace.logf(
            "mcp",
            "workspace MCP choice diagnostic cause={s} server={s}",
            .{
                @tagName(diagnostic.cause),
                if (diagnostic.server_name) |name|
                    debug_trace.terminalPreview(name_buf[0..], name)
                else
                    "none",
            },
        );
    }

    var workspace = try workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choice_load.choices,
    );
    defer workspace.deinit(alloc);
    traceWorkspaceDiagnostics(workspace.diagnostics.items);

    var configs = try project_config.mergeNative(alloc, &profile, &workspace.configs);
    defer freeConfigs(alloc, &configs);
    var runtime = try runtimeFromConfigs(alloc, &configs, elicitation_capabilities);
    if (runtime == null and workspace.diagnostics.items.len > 0) {
        runtime = try alloc.create(mcp_runtime.McpRuntime);
        runtime.?.* = mcp_runtime.McpRuntime.initWithElicitation(
            alloc,
            elicitation_capabilities,
        );
    }
    if (runtime) |value| {
        value.takeWorkspaceDiagnostics(&workspace.diagnostics) catch |err| {
            value.deinit();
            alloc.destroy(value);
            return err;
        };
    }
    return runtime;
}

pub fn previewNativeWorkspaceAuthority(
    alloc: Allocator,
    workspace_root: []const u8,
) ![][]u8 {
    var choice_load = config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("mcp", "workspace MCP authority unavailable err={s}", .{@errorName(err)});
        return alloc.alloc([]u8, 0);
    };
    defer choice_load.deinit(alloc);
    var workspace = try workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choice_load.choices,
    );
    defer workspace.deinit(alloc);
    return project_config.authorityNames(alloc, workspace.configs.items, .all);
}

fn traceWorkspaceDiagnostics(diagnostics: []const project_config.WorkspaceDiagnostic) void {
    for (diagnostics) |diagnostic| {
        var name_buf: [256]u8 = undefined;
        var variable_buf: [160]u8 = undefined;
        debug_trace.logf(
            "mcp",
            "workspace MCP config skipped cause={s} server={s} field={s} variable={s}",
            .{
                @tagName(diagnostic.cause),
                if (diagnostic.server_name) |name|
                    debug_trace.terminalPreview(name_buf[0..], name)
                else
                    "none",
                if (diagnostic.environment_field) |field| @tagName(field) else "none",
                if (diagnostic.environment_variable) |name|
                    debug_trace.terminalPreview(variable_buf[0..], name)
                else
                    "none",
            },
        );
    }
}

pub fn inspectProfileConfig(
    alloc: Allocator,
) error{OutOfMemory}!mcp_contract.ProfileConfigDiagnostic {
    const home = io_mod.getenv("HOME") orelse return .clear;
    const config_path = try configPathFromHome(alloc, home);
    defer alloc.free(config_path);

    var document = loadProfileDocumentFromPath(alloc, config_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = err };
    };
    defer document.deinit(alloc);
    return if (document.diagnostic) |warning|
        .{ .warning = warning }
    else
        .clear;
}

pub fn inspectLocalConfig(
    alloc: Allocator,
    workspace_root: []const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    var profile: std.ArrayList(McpServerConfig) = .empty;
    defer freeConfigs(alloc, &profile);
    var profile_diagnostic: mcp_contract.ProfileConfigDiagnostic = .clear;
    if (io_mod.getenv("HOME")) |home| {
        const config_path = try configPathFromHome(alloc, home);
        defer alloc.free(config_path);
        var document = loadProfileDocumentFromPath(alloc, config_path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return emptyLocalInspection(alloc, .{ .failed = err }, @errorName(err));
        };
        defer document.deinit(alloc);
        profile_diagnostic = if (document.diagnostic) |warning|
            .{ .warning = warning }
        else
            .clear;
        profile = document.configs;
        document.configs = .empty;
    }

    var choice_load = config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return localInspectionFromConfigs(
            alloc,
            profile.items,
            &.{},
            profile_diagnostic,
            null,
        );
    };
    defer choice_load.deinit(alloc);
    var workspace = workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choice_load.choices,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return emptyLocalInspection(
            alloc,
            profile_diagnostic,
            @errorName(err),
        );
    };
    defer workspace.deinit(alloc);
    var configs = project_config.mergeNative(
        alloc,
        &profile,
        &workspace.configs,
    ) catch return error.OutOfMemory;
    defer freeConfigs(alloc, &configs);
    return localInspectionFromConfigs(
        alloc,
        configs.items,
        workspace.diagnostics.items,
        profile_diagnostic,
        null,
    );
}

fn emptyLocalInspection(
    alloc: Allocator,
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic,
    inspection_error: ?[]const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    return localInspectionFromConfigs(
        alloc,
        &.{},
        &.{},
        profile_diagnostic,
        inspection_error,
    );
}

fn localInspectionFromConfigs(
    alloc: Allocator,
    configs: []const McpServerConfig,
    diagnostics: []const project_config.WorkspaceDiagnostic,
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic,
    inspection_error: ?[]const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    const servers = try alloc.alloc(mcp_health.ConfiguredServerSnapshot, configs.len);
    var servers_initialized: usize = 0;
    errdefer {
        for (servers[0..servers_initialized]) |*server| server.deinit(alloc);
        alloc.free(servers);
    }
    for (configs, 0..) |config, index| {
        var encoded_name = try text_utils.encodeTerminalSafe(alloc, config.name, 256);
        servers[index] = .{
            .configured_name = encoded_name.bytes,
            .source = config.source,
            .scope = config.scope,
            .workspace_admission = config.workspace_admission,
            .required = config.required,
            .transport = config.transport,
        };
        encoded_name = undefined;
        servers_initialized += 1;
    }

    const issues = try alloc.alloc(mcp_health.ConfigurationIssue, diagnostics.len);
    var issues_initialized: usize = 0;
    errdefer {
        for (issues[0..issues_initialized]) |*issue| issue.deinit(alloc);
        alloc.free(issues);
    }
    for (diagnostics, 0..) |diagnostic, index| {
        issues[index] = .{
            .message = try project_config.renderWorkspaceDiagnostic(alloc, diagnostic),
        };
        issues_initialized += 1;
    }
    return .{
        .profile_diagnostic = profile_diagnostic,
        .snapshot = .{
            .servers = servers,
            .configuration_issues = issues,
        },
        .inspection_error = inspection_error,
    };
}

fn runtimeFromConfigs(
    alloc: Allocator,
    configs: *std.ArrayList(McpServerConfig),
    elicitation_capabilities: elicitation.Capabilities,
) !?*mcp_runtime.McpRuntime {
    if (configs.items.len == 0) return null;

    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    errdefer alloc.destroy(runtime);
    runtime.* = mcp_runtime.McpRuntime.initWithElicitation(alloc, elicitation_capabilities);
    errdefer runtime.deinit();
    while (configs.items.len > 0) {
        var config = configs.orderedRemove(0);
        runtime.addServer(config) catch |err| {
            config.deinit(alloc);
            return err;
        };
    }

    return runtime;
}

pub fn loadConfigFromPath(alloc: Allocator, path: []const u8) !std.ArrayList(McpServerConfig) {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| {
        if (err == error.FileNotFound) return .empty;
        logConfigFailure("open", path, err);
        return err;
    };
    defer file.close(io_mod.getIo());

    const json_text = io_mod.readFileToEnd(alloc, &file, 1024 * 1024) catch |err| {
        logConfigFailure("read", path, err);
        return err;
    };
    defer alloc.free(json_text);

    return loadConfigFromJson(alloc, json_text) catch |err| {
        logConfigFailure("load", path, err);
        return err;
    };
}

fn addProfileServerToPath(
    alloc: Allocator,
    path: []const u8,
    intent: command_provider_contract.AddIntent,
) !?project_config.ProfileDiagnostic {
    const next = switch (intent) {
        .local => |local| try configFromCommandParts(alloc, local.name, local.command, local.args),
        .http => |http| blk: {
            const owned_name = try alloc.dupe(u8, http.name);
            errdefer alloc.free(owned_name);
            const owned_url = try alloc.dupe(u8, http.url);
            break :blk McpServerConfig{
                .name = owned_name,
                .transport = .http,
                .url = owned_url,
                .allow_stored_credentials = true,
            };
        },
    };
    return addOrReplaceServer(alloc, path, next);
}

fn addOrReplaceServer(
    alloc: Allocator,
    path: []const u8,
    next_value: McpServerConfig,
) !?project_config.ProfileDiagnostic {
    var next = next_value;
    var moved = false;
    errdefer if (!moved) next.deinit(alloc);

    var lock = try acquireProfileMutationLock(path);
    defer lock.release();
    var document = try loadProfileDocumentFromPath(alloc, path);
    defer document.deinit(alloc);
    if (!document.mutation_allowed) return error.McpConfigAmbiguousServerKey;
    const configs = &document.configs;
    const warning = document.diagnostic;

    for (configs.items) |*existing| {
        if (!std.mem.eql(u8, existing.name, next.name)) continue;
        existing.deinit(alloc);
        existing.* = next;
        moved = true;
        try saveConfigsToPath(alloc, path, configs.items);
        return warning;
    }

    try configs.append(alloc, next);
    moved = true;
    try saveConfigsToPath(alloc, path, configs.items);
    return warning;
}

const ProfileRemoveFromPathResult = struct {
    removed: bool,
    warning: ?project_config.ProfileDiagnostic = null,
};

fn removeProfileServerFromPath(
    alloc: Allocator,
    path: []const u8,
    name: []const u8,
) !ProfileRemoveFromPathResult {
    var lock = try acquireProfileMutationLock(path);
    defer lock.release();
    var document = try loadProfileDocumentFromPath(alloc, path);
    defer document.deinit(alloc);
    if (!document.mutation_allowed) return error.McpConfigAmbiguousServerKey;
    const configs = &document.configs;
    const warning = document.diagnostic;

    for (configs.items, 0..) |config, i| {
        if (!std.mem.eql(u8, config.name, name)) continue;
        var removed = configs.orderedRemove(i);
        removed.deinit(alloc);
        try saveConfigsToPath(alloc, path, configs.items);
        return .{ .removed = true, .warning = warning };
    }

    return .{ .removed = false, .warning = warning };
}

fn removeServerFromPath(alloc: Allocator, path: []const u8, name: []const u8) !bool {
    return (try removeProfileServerFromPath(alloc, path, name)).removed;
}

fn loadConfigFromJson(alloc: Allocator, json_text: []const u8) !std.ArrayList(McpServerConfig) {
    return project_config.parseProfileJson(alloc, json_text);
}

fn loadProfileDocumentFromPath(
    alloc: Allocator,
    path: []const u8,
) !project_config.ProfileParseResult {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| {
        if (err == error.FileNotFound) return .{};
        return err;
    };
    defer file.close(io_mod.getIo());
    const json_text = try io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
    defer alloc.free(json_text);
    return project_config.parseProfileDocument(alloc, json_text);
}

fn acquireProfileMutationLock(path: []const u8) !io_mod.TimedAdvisoryLock {
    const parent = std.fs.path.dirname(path) orelse return error.McpConfigPathInvalid;
    const grandparent = std.fs.path.dirname(parent) orelse return error.McpConfigPathInvalid;
    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.fs.path.basename(parent));
    defer dir.close();
    return io_mod.acquireTimedAdvisoryLock(&dir, "mcp.lock", profile_lock_deadline_ms);
}

fn saveConfigsToPath(alloc: Allocator, path: []const u8, configs: []const McpServerConfig) !void {
    const json = try renderConfigJson(alloc, configs);
    defer alloc.free(json);

    const parent = std.fs.path.dirname(path) orelse return error.McpConfigPathInvalid;
    const grandparent = std.fs.path.dirname(parent) orelse return error.McpConfigPathInvalid;

    var enclosing = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), grandparent, .{ .iterate = true }),
    };
    defer enclosing.close();
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&enclosing, std.fs.path.basename(parent));
    defer dir.close();
    try io_mod.durableReplaceVerified(alloc, &dir, std.fs.path.basename(path), json);
}

fn freeConfigs(alloc: Allocator, configs: *std.ArrayList(McpServerConfig)) void {
    for (configs.items) |config| {
        var mutable = config;
        mutable.deinit(alloc);
    }
    configs.deinit(alloc);
}

fn findConfig(configs: []const McpServerConfig, name: []const u8) ?*const McpServerConfig {
    for (configs) |*config| {
        if (std.mem.eql(u8, config.name, name)) return config;
    }
    return null;
}

noinline fn logConfigFailure(action: []const u8, path: []const u8, err: anyerror) void {
    debug_trace.logf(
        "mcp",
        "failed to {s} config {s}: {s}",
        .{ action, path, @errorName(err) },
    );
}

fn configFromCommandParts(
    alloc: Allocator,
    name: []const u8,
    command: []const u8,
    command_args: []const []const u8,
) !McpServerConfig {
    const args: [][]u8 = if (command_args.len > 0) try alloc.alloc([]u8, command_args.len) else &.{};
    errdefer if (args.len > 0) alloc.free(args);

    var parsed: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < parsed) : (i += 1) alloc.free(args[i]);
    }

    for (command_args, 0..) |arg, i| {
        args[i] = try alloc.dupe(u8, arg);
        parsed += 1;
    }

    const owned_command = try alloc.dupe(u8, command);
    errdefer alloc.free(owned_command);

    return .{
        .name = try alloc.dupe(u8, name),
        .source = .profile,
        .scope = .profile,
        .command = owned_command,
        .args = args,
        .enabled = true,
    };
}

fn renderConfigJson(alloc: Allocator, configs: []const McpServerConfig) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"mcp\":{");
    for (configs, 0..) |config, i| {
        if (i > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(config.name, .{}, &out.writer);
        try out.writer.writeAll(":{");

        switch (config.transport) {
            .stdio => {
                try out.writer.writeAll("\"type\":\"local\",\"command\":[");
                try std.json.Stringify.value(try config.stdioCommand(), .{}, &out.writer);
                for (config.args) |arg| {
                    try out.writer.writeByte(',');
                    try std.json.Stringify.value(arg, .{}, &out.writer);
                }
                try out.writer.writeByte(']');
            },
            .sse => {
                try out.writer.writeAll("\"type\":\"sse\",\"url\":");
                try std.json.Stringify.value(try config.remoteUrl(), .{}, &out.writer);
            },
            .http => {
                try out.writer.writeAll("\"type\":\"http\",\"url\":");
                try std.json.Stringify.value(try config.remoteUrl(), .{}, &out.writer);
            },
        }

        try out.writer.print(",\"enabled\":{s}", .{if (config.enabled) "true" else "false"});
        if (config.required) try out.writer.writeAll(",\"required\":true");
        if (config.transport == .stdio or
            config.transport == .http or
            config.transport == .sse)
        {
            try out.writer.print(
                ",\"startup_timeout_ms\":{d},\"operation_timeout_ms\":{d}",
                .{ config.startup_timeout_ms, config.operation_timeout_ms },
            );
        }
        if (config.transport == .stdio) {
            try out.writer.print(",\"restart_limit\":{d}", .{config.restart_limit});
        }
        if (config.headers.len > 0) {
            try out.writer.writeAll(",\"headers\":{");
            for (config.headers, 0..) |header, header_i| {
                if (header_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(header.name, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(header.value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        if (config.header_env.len > 0) {
            try out.writer.writeAll(",\"header_env\":{");
            for (config.header_env, 0..) |ref, ref_i| {
                if (ref_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(ref.name, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(ref.env, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        if (config.bearer_token_env) |env_name| {
            try out.writer.writeAll(",\"bearer_token_env\":");
            try std.json.Stringify.value(env_name, .{}, &out.writer);
        }
        if (config.auth) |auth| {
            try out.writer.writeAll(",\"oauth\":{");
            var first_auth = true;
            if (auth.resource) |field| try writeOptionalJsonField(&out.writer, &first_auth, "resource", field);
            if (auth.issuer) |field| try writeOptionalJsonField(&out.writer, &first_auth, "issuer", field);
            if (auth.client_id) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_id", field);
            if (auth.client_secret_env) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_secret_env", field);
            if (auth.client_metadata_url) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_metadata_url", field);
            if (auth.scopes.len > 0) {
                if (!first_auth) try out.writer.writeByte(',');
                first_auth = false;
                try out.writer.writeAll("\"scopes\":[");
                for (auth.scopes, 0..) |scope, scope_i| {
                    if (scope_i > 0) try out.writer.writeByte(',');
                    try std.json.Stringify.value(scope, .{}, &out.writer);
                }
                try out.writer.writeByte(']');
            }
            try out.writer.writeByte('}');
        }
        if (config.env.len > 0) {
            try out.writer.writeAll(",\"environment\":{");
            for (config.env, 0..) |entry, env_i| {
                if (env_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(entry.key, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(entry.value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeOptionalJsonField(
    writer: *std.Io.Writer,
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const ListFixture = struct {
    text: []const u8,
    calls: usize = 0,
    summary_calls: usize = 0,

    fn list(raw_ctx: *anyopaque, alloc: Allocator) ![]u8 {
        const self: *ListFixture = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        return alloc.dupe(u8, self.text);
    }

    fn summary(raw_ctx: *anyopaque, alloc: Allocator) ![]u8 {
        const self: *ListFixture = @ptrCast(@alignCast(raw_ctx));
        self.summary_calls += 1;
        return alloc.dupe(u8, "MCP: no servers configured. Use /mcp add <name> <command> [args...].");
    }
};

fn request(home: ?[]const u8, fixture: *ListFixture) CommandRequest {
    return .{
        .home = home,
        .list_ctx = @ptrCast(fixture),
        .summarize_servers = ListFixture.summary,
        .list_servers_and_tools = ListFixture.list,
    };
}

fn tmpRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn tmpPath(alloc: Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, name });
}

fn tmpDirPath(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, dir, sub_path);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readFileForTest(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}
