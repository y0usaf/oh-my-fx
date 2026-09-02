const std = @import("std");
const builtin = @import("builtin");
const command_policy = @import("command_policy.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const terminal_contracts = @import("../terminal/contracts.zig");
const terminal_client_runtime = @import("../terminal/client.zig");
const terminal_ui_projection = @import("../terminal/ui_projection.zig");
const types = @import("../shared/types.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const max_run_command_activity_bytes = 120;
const max_run_command_activity_source_bytes = max_run_command_activity_bytes * max_run_command_activity_bytes;
pub const max_auto_permission_reason_presentation_bytes: usize = 160;

pub const ToolActionInput = struct {
    tool_registry: tool_dispatch.Registry,
    call: ToolCall,
    workspace_root: []const u8 = "",
    display_target: ?[]const u8 = null,
    is_available_dynamic_mcp_tool: bool = false,
};

pub const RunCommandActivity = struct {
    detail: []const u8,
    compatibility_tool: ?*const tool_dispatch.Tool,
};

pub fn isProviderSearchAlias(name: []const u8) bool {
    return std.mem.eql(u8, name, "perplexity_search") or
        std.mem.eql(u8, name, "parallel_search");
}

fn projectRunCommandActivitySource(
    command: []const u8,
    workspace_root_input: []const u8,
    storage: *[max_run_command_activity_bytes + 1]u8,
) []const u8 {
    const display_command = stripNoopCurrentDirectoryPrefix(command);
    var workspace_root_end = workspace_root_input.len;
    while (workspace_root_end > 1 and workspace_root_input[workspace_root_end - 1] == '/') {
        workspace_root_end -= 1;
    }
    const workspace_root = workspace_root_input[0..workspace_root_end];
    const can_abbreviate_workspace = workspace_root.len > 1 and workspace_root[0] == '/';
    const source_limit = @min(display_command.len, max_run_command_activity_source_bytes);
    var source_index: usize = 0;
    var projected_len: usize = 0;
    var line_boundary_pending = false;

    while (source_index < source_limit) {
        const byte = display_command[source_index];
        if (byte == '\r' or byte == '\n') {
            line_boundary_pending = true;
            source_index += 1;
            continue;
        }
        if (line_boundary_pending and (byte == ' ' or byte == '\t')) {
            source_index += 1;
            continue;
        }
        if (line_boundary_pending) {
            line_boundary_pending = false;
            if (projected_len > 0) {
                storage[projected_len] = ' ';
                projected_len += 1;
                if (projected_len == storage.len) break;
            }
        }

        if (can_abbreviate_workspace and
            workspace_root.len <= source_limit - source_index and
            workspaceRootMatchesAt(display_command, workspace_root, source_index))
        {
            storage[projected_len] = '.';
            projected_len += 1;
            if (projected_len == storage.len) break;
            source_index += workspace_root.len;
            continue;
        }

        storage[projected_len] = byte;
        projected_len += 1;
        if (projected_len == storage.len) break;
        source_index += 1;
    }

    return storage[0..projected_len];
}

fn stripNoopCurrentDirectoryPrefix(command: []const u8) []const u8 {
    const prefix = "cd . &&";
    if (!std.mem.startsWith(u8, command, prefix)) return command;
    if (command.len == prefix.len or !std.ascii.isWhitespace(command[prefix.len])) return command;

    const remainder = std.mem.trimStart(u8, command[prefix.len..], " \t\r\n");
    return if (remainder.len > 0) remainder else command;
}

fn workspaceRootMatchesAt(command: []const u8, workspace_root: []const u8, index: usize) bool {
    if (!std.mem.startsWith(u8, command[index..], workspace_root)) return false;
    if (index > 0 and isPathTokenByte(command[index - 1])) return false;

    const next_index = index + workspace_root.len;
    if (next_index == command.len) return true;
    return command[next_index] == '/' or !isPathTokenByte(command[next_index]);
}

fn isPathTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '/', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatRunCommandPermissionLabel(
    alloc: Allocator,
    command: []const u8,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const encoded = try text_utils.encodeTerminalSafe(
        scratch,
        command,
        max_run_command_activity_bytes,
    );
    const suffix = try commandApprovalLabelSuffix(scratch, "terminal", command);
    return std.fmt.allocPrint(alloc, "terminal.exec {s}{s}", .{ encoded.bytes, suffix });
}

pub fn isAdvertisedDynamicMcpName(registry: tool_dispatch.Registry, name: []const u8, advertised: []const []const u8) bool {
    if (registry.lookup(name) != null) return false;
    for (advertised) |advertised_name| {
        if (std.mem.eql(u8, advertised_name, name)) return true;
    }
    return false;
}

/// The caller owns `detail` and must free it with `alloc`.
pub fn formatRunCommandActivity(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
) !?RunCommandActivity {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch return null;
    if (!isCapturedCommandCall(registry, call, args)) return null;
    const command = tool_args.optionalStringArg(args, "command") orelse return null;
    var projected_storage: [max_run_command_activity_bytes + 1]u8 = undefined;
    const projected = projectRunCommandActivitySource(command, workspace_root, &projected_storage);
    const encoded = try text_utils.encodeTerminalSafe(scratch, projected, max_run_command_activity_bytes);
    return .{
        .detail = try alloc.dupe(u8, encoded.bytes),
        .compatibility_tool = if (try tool_dispatch.matchRunCommandCompatibility(registry, command)) |matched| matched.tool else null,
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn resolveTerminalDisplayTargetFromRows(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
    rows: []const terminal_ui_projection.Row,
) !?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const session_id = terminalDisplayTargetSessionId(
        scratch_state.allocator(),
        registry,
        call,
    ) orelse return null;
    return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        rows,
    ));
}

fn terminalDisplayTargetSessionId(
    scratch: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) ?[]const u8 {
    const spec = registry.lookup(call.name) orelse return null;
    if (spec.executor_kind != .terminal) return null;
    const args = tool_args.parseToolArgsObject(
        scratch,
        call.arguments_json,
    ) catch return null;
    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (presentation.label_arg_kind != .session_id) return null;
    return tool_args.optionalStringArg(args, "session_id");
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn resolveTerminalSessionTargetFromRows(
    alloc: Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    rows: []const terminal_ui_projection.Row,
) ![]const u8 {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.session_id, session_id)) continue;
        if (row.label.len == 0 or std.mem.eql(u8, row.label, session_id)) break;
        return try formatTerminalDisplayTarget(
            alloc,
            workspace_root,
            row.label,
        );
    }

    var encoded = try text_utils.encodeTerminalSafe(
        alloc,
        session_id,
        max_run_command_activity_bytes - "session ".len,
    );
    defer encoded.deinit(alloc);
    return try std.fmt.allocPrint(alloc, "session {s}", .{encoded.bytes});
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn resolveTerminalDisplayTarget(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    terminal_client: ?*terminal_client_runtime.Runtime,
    call: ToolCall,
) !?[]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch_state.deinit();
    const session_id = terminalDisplayTargetSessionId(
        scratch_state.allocator(),
        registry,
        call,
    ) orelse return null;
    const runtime = terminal_client orelse return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        &.{},
    ));
    var snapshot = try runtime.terminalProjection(std.heap.c_allocator);
    defer snapshot.deinit();
    return @as(?[]const u8, try resolveTerminalSessionTargetFromRows(
        alloc,
        workspace_root,
        session_id,
        snapshot.rows,
    ));
}

/// The caller owns the returned allocation and must free it with `alloc`.
fn formatTerminalDisplayTarget(
    alloc: Allocator,
    workspace_root: []const u8,
    raw: []const u8,
) ![]u8 {
    var projected_storage: [max_run_command_activity_bytes + 1]u8 = undefined;
    const projected = projectRunCommandActivitySource(
        raw,
        workspace_root,
        &projected_storage,
    );
    const encoded = try text_utils.encodeTerminalSafe(
        alloc,
        projected,
        max_run_command_activity_bytes,
    );
    return encoded.bytes;
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPlainAction(alloc: Allocator, input: ToolActionInput) ![]const u8 {
    const call = input.call;
    if (file_mutation_contract.isToolName(call.name)) {
        const spec = input.tool_registry.lookup(call.name) orelse
            return std.fmt.allocPrint(alloc, "Working: {s}", .{call.name});
        return std.fmt.allocPrint(
            alloc,
            "{s} {s}",
            .{ spec.action_label, input.display_target orelse spec.label_arg_default },
        );
    }

    if (try formatRunCommandActivity(alloc, input.tool_registry, input.workspace_root, call)) |activity| {
        defer alloc.free(activity.detail);
        const action_label = if (activity.compatibility_tool) |tool| tool.action_label else "Running";
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ action_label, activity.detail });
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const spec = input.tool_registry.lookup(call.name) orelse {
        if (isProviderSearchAlias(call.name)) {
            const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
                return std.fmt.allocPrint(alloc, "Searching web", .{});
            };
            return std.fmt.allocPrint(alloc, "Searching {s}", .{try formatWebSearchActionDetail(scratch, args)});
        }
        if (input.is_available_dynamic_mcp_tool) return std.fmt.allocPrint(alloc, "MCP: {s}", .{call.name});
        return std.fmt.allocPrint(alloc, "Working: {s}", .{call.name});
    };
    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return std.fmt.allocPrint(alloc, "Working: {s}", .{call.name});
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (spec.executor_kind == .web_search) {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ presentation.action_label, try formatWebSearchActionDetail(scratch, args) });
    }
    const value = input.display_target orelse
        tool_dispatch.presentationLabelValue(presentation, args) orelse
        presentation.label_arg_default;
    return std.fmt.allocPrint(alloc, "{s} {s}", .{ presentation.action_label, value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPermissionLabel(alloc: Allocator, registry: tool_dispatch.Registry, call: ToolCall) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    if (try runCommandCompatibilitySource(scratch, registry, call)) |source| {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ source.tool.name, source.command });
    }
    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return try alloc.dupe(u8, call.name);
    };
    if (isCapturedCommandCall(registry, call, args)) {
        const command = tool_args.optionalStringArg(args, "command") orelse
            return try alloc.dupe(u8, call.name);
        return formatRunCommandPermissionLabel(alloc, command);
    }
    const spec = registry.lookup(call.name) orelse return try alloc.dupe(u8, call.name);
    if (file_mutation_contract.isToolName(call.name)) {
        return std.fmt.allocPrint(
            alloc,
            "{s} {s}",
            .{ call.name, spec.label_arg_default },
        );
    }
    const value = tool_dispatch.toolLabelValue(spec.*, args) orelse return try alloc.dupe(u8, call.name);

    if (spec.label_arg_kind == .command) {
        const suffix = try commandApprovalLabelSuffix(scratch, call.name, value);
        if (tool_args.optionalStringArg(args, "cwd")) |cwd| {
            return std.fmt.allocPrint(alloc, "{s} {s} @ {s}{s}", .{ call.name, value, cwd, suffix });
        }
        return std.fmt.allocPrint(alloc, "{s} {s}{s}", .{ call.name, value, suffix });
    }

    return std.fmt.allocPrint(alloc, "{s} {s}", .{ call.name, value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchActionDetail(alloc: Allocator, args: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var label_buf: [160]u8 = undefined;
    const query = tool_args.optionalStringArg(args, "query") orelse "web";
    try out.writer.writeAll(text_utils.clippedLabel(&label_buf, query, 120));
    try appendWebSearchDomains(&out.writer, "allowed", args.get("allowed_domains"));
    try appendWebSearchDomains(&out.writer, "blocked", args.get("blocked_domains"));
    return try out.toOwnedSlice();
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchProgressPlain(alloc: Allocator, progress: types.WebSearchProgress) ![]u8 {
    var query_buf: [160]u8 = undefined;
    return switch (progress) {
        .query_started => |query| std.fmt.allocPrint(
            alloc,
            "Searching {s}",
            .{text_utils.clippedLabel(&query_buf, query, 120)},
        ),
        .results_received => |entry| std.fmt.allocPrint(
            alloc,
            "Found {d} result{s} for {s}",
            .{ entry.result_count, if (entry.result_count == 1) "" else "s", text_utils.clippedLabel(&query_buf, entry.query, 120) },
        ),
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebFetchProgressPlain(alloc: Allocator, progress: types.WebFetchProgress) ![]u8 {
    var url_buf: [types.WebFetchCompletion.max_url_len]u8 = undefined;
    return switch (progress) {
        .fetching => |url| std.fmt.allocPrint(alloc, "Fetching {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
        .converting => |url| std.fmt.allocPrint(alloc, "Converting {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
    };
}

fn appendWebSearchDomains(writer: *std.Io.Writer, label: []const u8, value: ?std.json.Value) !void {
    const array = value orelse return;
    if (array != .array or array.array.items.len == 0) return;
    try writer.print(" | {s}: ", .{label});
    var domain_buf: [64]u8 = undefined;
    const shown = @min(array.array.items.len, 3);
    for (array.array.items[0..shown], 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        if (item != .string) {
            try writer.writeAll("?");
            continue;
        }
        try writer.writeAll(text_utils.clippedLabel(&domain_buf, item.string, 48));
    }
    if (array.array.items.len > shown) try writer.print(" +{d}", .{array.array.items.len - shown});
}

fn commandApprovalLabelSuffix(alloc: Allocator, tool_name: []const u8, command: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, tool_name, "run_command") and
        !std.mem.eql(u8, tool_name, "terminal")) return "";
    const risk = command_policy.command_risk_note_for(command);
    const safer = command_policy.command_safer_alternative_for(command);
    if (risk == null and safer == null) return "";
    const risk_text = if (risk) |note| stripNotePrefix(note) else null;
    if (risk_text) |note| {
        if (safer) |alternative| {
            return std.fmt.allocPrint(alloc, " (risk: {s}; {s})", .{ note, alternative });
        }
        return std.fmt.allocPrint(alloc, " (risk: {s})", .{note});
    }
    if (safer) |alternative| {
        return std.fmt.allocPrint(alloc, " ({s})", .{alternative});
    }
    return "";
}

fn stripNotePrefix(note: []const u8) []const u8 {
    const prefix = "note: ";
    if (std.mem.startsWith(u8, note, prefix)) return note[prefix.len..];
    return note;
}

const RunCommandCompatibilitySource = struct {
    tool: *const tool_dispatch.Tool,
    command: []const u8,
};

fn runCommandCompatibilitySource(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
) !?RunCommandCompatibilitySource {
    const args = tool_args.parseToolArgsObject(alloc, call.arguments_json) catch return null;
    if (!isCapturedCommandCall(registry, call, args)) return null;
    const command = tool_args.optionalStringArg(args, "command") orelse return null;
    const matched = (try tool_dispatch.matchRunCommandCompatibility(registry, command)) orelse return null;
    return .{ .tool = matched.tool, .command = command };
}

fn isCapturedCommandCall(
    registry: tool_dispatch.Registry,
    call: ToolCall,
    args: std.json.ObjectMap,
) bool {
    // Historical sessions retain their original tool name. Presentation may
    // interpret those records, but execution remains unavailable because the
    // registry no longer contains a `run_command` tool.
    if (std.mem.eql(u8, call.name, "run_command")) return true;
    const tool = registry.lookup(call.name) orelse return false;
    if (tool.executor_kind == .run_command) return true;
    const expected = tool.captured_command_action orelse return false;
    const action = tool_args.optionalStringArg(args, "action") orelse return false;
    return std.mem.eql(u8, action, expected);
}

fn matchesTestSkillInstall(command: []const u8) bool {
    return std.mem.startsWith(u8, command, "npx skills add ");
}

fn executeTestSkillInstall(
    ctx: tool_dispatch.DispatchContext,
    _: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, "installed") };
}

const test_install_skill = blk: {
    var tool = test_builtin_tools.skill;
    tool.name = "install_skill";
    tool.model_schema.name = "install_skill";
    tool.executor_kind = .install_skill;
    tool.activity_kind = .write;
    tool.requires_approval = true;
    tool.action_label = "Installing skill";
    tool.completed_action_label = "Installed skill";
    tool.label_arg_kind = .source;
    tool.label_arg_default = "skill";
    tool.run_command_compatibility = .{
        .matches = matchesTestSkillInstall,
        .execute = executeTestSkillInstall,
    };
    break :blk tool;
};

const test_web_search = blk: {
    var tool = test_builtin_tools.read_file;
    tool.name = "web_search";
    tool.model_schema.name = "web_search";
    tool.executor_kind = .web_search;
    tool.action_label = "Searching";
    tool.completed_action_label = "Searched";
    tool.label_arg_kind = .query;
    tool.label_arg_default = "web";
    break :blk tool;
};

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_web_search,
    test_builtin_tools.terminal,
    test_builtin_tools.memory,
    test_builtin_tools.skill,
    test_install_skill,
    test_builtin_tools.ask_user_question,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_presentation_tool = blk: {
    var tool = test_builtin_tools.memory;
    tool.name = "custom_presentation";
    tool.action_label = "Inspecting";
    tool.label_arg_kind = .name;
    tool.label_arg_default = "custom fallback";
    break :blk tool;
};
const custom_presentation_registry = tool_dispatch.Registry{ .tools = &.{custom_presentation_tool} };














fn expectContains(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, text, needle) != null);
}
