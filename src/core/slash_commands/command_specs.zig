const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const list_window = @import("../shared/list_window.zig");
const mod_registry = @import("../mods/registry.zig");

const Allocator = std.mem.Allocator;

pub const TopLevelKind = enum {
    help,
    ask,
    acp,
    pr,
    issue,
    login,
    logout,
    setup,
    status,
    permissions,
    mcp,
    models,
    provider,
    doctor,
    background,
    teams,
    session,
    sessions,
    @"resume",
    credits,
    usage,
    upgrade,
    replay,
    workspace,
};

pub const SlashKind = enum {
    quit,
    clear_screen,
    new_session,
    reset_session,
    resume_session,
    continue_recovery,
    rename_session,
    help,
    login,
    logout,
    setup,
    status,
    background,
    background_stop,
    background_open,
    background_logs,
    image,
    images,
    model,
    permissions,
    allowlist,
    stats,
    usage,
    undo,
    mcp,
    skills,
    copy,
    feedback,
    trace,
    compact,
    settings,
    alias,
    credits,
    paste,
    fast,
    statusline,
    notifications,
    workspace,
    version,
};

pub const OptionDoc = struct {
    flag: []const u8,
    description: []const u8,
};

pub const TopLevelSpec = struct {
    kind: TopLevelKind,
    token: []const u8,
    aliases: []const []const u8 = &.{},
    usage: []const u8,
    summary: []const u8,
    options: []const OptionDoc = &.{},
    details: []const []const u8 = &.{},
    hidden_from_top_level_help: bool = false,
};

pub const TopLevelHelpEntry = struct {
    kind: ?TopLevelKind = null,
    usage: []const u8,
    summary: ?[]const u8 = null,
};

pub const TopLevelHelpGroup = struct {
    entries: []const TopLevelHelpEntry,
};

pub const TopLevelFlag = struct {
    usage: []const u8,
    description: []const u8,
};

pub const TopLevelExample = struct {
    command: []const u8,
    description: []const u8,
};

pub const TopLevelResource = struct {
    label: []const u8,
    value: []const u8,
    link: bool = false,
};

pub const TopLevelRegistry = struct {
    specs: []const TopLevelSpec = &.{},
    description: []const u8,
    interactive_hint: []const u8,
    help_groups: []const TopLevelHelpGroup = &.{},
    flags: []const TopLevelFlag = &.{},
    examples: []const TopLevelExample = &.{},
    notes: []const []const u8 = &.{},
    resources: []const TopLevelResource = &.{},
};

pub const SlashPresentationCategory = enum {
    general,
    session,
    account,
    model,
    appearance,
    security,
    workspace,
    media,
    agents,
    extensions,
    product,

    pub fn label(self: SlashPresentationCategory) []const u8 {
        return switch (self) {
            .general => "General",
            .session => "Session",
            .account => "Account",
            .model => "Model",
            .appearance => "Appearance",
            .security => "Security",
            .workspace => "Workspace",
            .media => "Media",
            .agents => "Agents",
            .extensions => "Extensions",
            .product => "Product",
        };
    }
};

pub const SlashSpec = struct {
    kind: SlashKind,
    command: []const u8,
    aliases: []const []const u8 = &.{},
    show_aliases_in_completion: bool = true,
    help_entry: ?[]const u8 = null,
    completion_description: ?[]const u8 = null,
    presentation_category: ?SlashPresentationCategory = null,
    show_in_welcome: bool = false,
    has_args: bool = false,
    accepts_payload: bool = false,
    requires_prompt_credential: bool = false,
};

pub const SlashRegistry = mod_registry.CommandRegistry(SlashSpec);
pub const child_chat_slash_command_count: usize = 3;

pub fn childChatSlashRegistry(
    registry: SlashRegistry,
    storage: *[child_chat_slash_command_count]SlashSpec,
) SlashRegistry {
    var count: usize = 0;
    for (registry.commands) |spec| {
        switch (spec.kind) {
            .quit, .model, .skills => {
                std.debug.assert(count < storage.len);
                storage[count] = spec;
                count += 1;
            },
            else => {},
        }
    }
    return .{ .commands = storage[0..count] };
}

pub const HelpMenu = struct {
    active: bool = false,
    category: ?SlashPresentationCategory = null,
    selected_index: usize = 0,
    window_start: usize = 0,

    pub fn open(self: *HelpMenu) void {
        self.* = .{ .active = true };
    }

    pub fn close(self: *HelpMenu) void {
        self.* = .{};
    }

    pub fn resetForQuery(self: *HelpMenu) void {
        self.selected_index = 0;
        self.window_start = 0;
    }

    pub fn cycleCategory(self: *HelpMenu, delta: i32) bool {
        if (!self.active or delta == 0) return false;
        const count: i32 = @intCast(std.meta.fields(SlashPresentationCategory).len + 1);
        var next: i32 = if (self.category) |category|
            @as(i32, @intCast(@intFromEnum(category))) + 1
        else
            0;
        next += delta;
        while (next < 0) next += count;
        while (next >= count) next -= count;
        self.category = if (next == 0)
            null
        else
            @enumFromInt(next - 1);
        self.resetForQuery();
        return true;
    }

    pub fn move(self: *HelpMenu, registry: SlashRegistry, query: []const u8, delta: i32, visible_items: u16) bool {
        const item_count = helpCatalogCountForCategory(registry, self.category, query);
        if (!self.active or item_count == 0) return false;

        const current: i32 = @intCast(self.selected_index % item_count);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(item_count)) - 1;
        if (next >= @as(i32, @intCast(item_count))) next = 0;
        self.selected_index = @intCast(next);
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            @max(visible_items, 1),
        );
        return true;
    }

    pub fn selectedSpec(self: *const HelpMenu, registry: SlashRegistry, query: []const u8) ?*const SlashSpec {
        const item_count = helpCatalogCountForCategory(registry, self.category, query);
        if (!self.active or item_count == 0) return null;
        return helpCatalogSpecAtForCategory(registry, self.category, query, self.selected_index % item_count);
    }
};

pub const top_level_help_default_width: usize = 80;

pub const HelpStyle = enum {
    plain,
    ansi,
};

const HelpRole = enum {
    brand,
    heading,
    syntax,
    muted,
    label,
    link,
};

pub fn matchesTopLevel(registry: TopLevelRegistry, token: []const u8, kind: TopLevelKind) bool {
    const spec = topLevelSpec(registry, kind);
    return matchesCommandToken(token, spec.token, spec.aliases);
}

pub fn matchesSlashExact(registry: SlashRegistry, cmd: []const u8, kind: SlashKind) bool {
    const matched = registry.matchExact(cmd) orelse return false;
    return matched.command.kind == kind;
}

pub fn matchedSlashPrefix(registry: SlashRegistry, cmd: []const u8, kind: SlashKind) ?[]const u8 {
    return registry.matchEntryPrefix(cmd, slashSpecPtr(registry, kind));
}

pub fn renderTopLevelHelp(alloc: Allocator, registry: TopLevelRegistry, columns: usize, version: []const u8) ![]u8 {
    return renderTopLevelHelpWithStyle(alloc, registry, columns, version, .plain);
}

pub fn renderTopLevelHelpWithStyle(alloc: Allocator, registry: TopLevelRegistry, columns: usize, version: []const u8, style: HelpStyle) ![]u8 {
    const width = normalizedTopLevelHelpWidth(columns);
    const command_usage_width = maxTopLevelHelpUsageWidth(registry);
    const flag_usage_width = maxTopLevelFlagUsageWidth(registry);
    const resource_label_width = maxTopLevelResourceLabelWidth(registry);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeStyled(&out.writer, style, .brand, "𝒇x");
    try out.writer.writeByte(' ');
    try writeStyleStart(&out.writer, style, .muted);
    try out.writer.writeByte('v');
    try out.writer.writeAll(version);
    try writeStyleEnd(&out.writer, style);
    try out.writer.writeByte('\n');
    try writeWrappedStyledLine(&out.writer, "", "", registry.description, width, style, .muted);
    try out.writer.writeByte('\n');
    try writeWrappedStyledLine(&out.writer, "", "", registry.interactive_hint, width, style, .muted);

    try writeSectionHeading(&out.writer, style, "Usage:");
    try writeWrappedStyledLine(&out.writer, "  ", "  ", "fx [flags]", width, style, .syntax);
    try writeWrappedStyledLine(&out.writer, "  ", "  ", "fx <command> [...flags] [...args]", width, style, .syntax);

    try writeSectionHeading(&out.writer, style, "Commands:");
    for (registry.help_groups, 0..) |group, group_index| {
        if (group_index > 0) try out.writer.writeByte('\n');
        for (group.entries) |entry| {
            try writeTopLevelHelpEntry(&out.writer, registry, entry, command_usage_width, width, style);
        }
    }

    try writeSectionHeading(&out.writer, style, "Flags:");
    for (registry.flags) |flag| {
        try writeTopLevelFlag(&out.writer, flag, flag_usage_width, width, style);
    }
    try out.writer.writeByte('\n');

    try writeStyled(&out.writer, style, .heading, "Examples:");
    try out.writer.writeByte('\n');
    for (registry.examples) |example| {
        try writeTopLevelExample(&out.writer, example, width, style);
    }

    for (registry.notes) |note| {
        try writeWrappedStyledLine(&out.writer, "", "", note, width, style, .muted);
    }

    try out.writer.writeByte('\n');
    for (registry.resources) |resource| {
        try writeTopLevelResource(&out.writer, resource, resource_label_width, width, style);
    }

    return try out.toOwnedSlice();
}

pub fn renderTopLevelCommandHelp(alloc: Allocator, registry: TopLevelRegistry, kind: TopLevelKind) ![]u8 {
    const spec = topLevelSpec(registry, kind);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("fx ");
    try out.writer.writeAll(spec.token);
    try out.writer.writeAll("\n\n");
    try out.writer.writeAll(spec.summary);
    try out.writer.writeAll("\n\nUsage:\n");
    try out.writer.writeAll("  fx ");
    try out.writer.writeAll(spec.usage);
    try out.writer.writeByte('\n');

    if (spec.options.len > 0) {
        var flag_width: usize = 0;
        for (spec.options) |opt| flag_width = @max(flag_width, opt.flag.len);

        try out.writer.writeAll("\nOptions:\n");
        for (spec.options) |opt| {
            try out.writer.writeAll("  ");
            try out.writer.writeAll(opt.flag);
            try writePadding(&out.writer, flag_width - opt.flag.len + 2);
            try out.writer.writeAll(opt.description);
            try out.writer.writeByte('\n');
        }
    }

    if (spec.details.len > 0) {
        try out.writer.writeByte('\n');
        for (spec.details) |line| {
            try out.writer.writeAll(line);
            try out.writer.writeByte('\n');
        }
    }

    return try out.toOwnedSlice();
}

pub fn topLevelKindFromToken(registry: TopLevelRegistry, token: []const u8) ?TopLevelKind {
    for (registry.specs) |spec| {
        if (matchesCommandToken(token, spec.token, spec.aliases)) return spec.kind;
    }
    return null;
}

pub fn renderSlashHelp(alloc: Allocator, registry: SlashRegistry) ![]u8 {
    return renderSlashEntries(alloc, registry, false);
}

pub fn renderSlashWelcome(alloc: Allocator, registry: SlashRegistry) ![]u8 {
    return renderSlashEntries(alloc, registry, true);
}

pub fn helpCatalogCount(registry: SlashRegistry, query: []const u8) usize {
    var count: usize = 0;
    for (std.meta.tags(SlashPresentationCategory)) |category| {
        count += helpCatalogCategoryCount(registry, query, category);
    }
    return count;
}

pub fn helpCatalogCountForCategory(
    registry: SlashRegistry,
    category: ?SlashPresentationCategory,
    query: []const u8,
) usize {
    return if (category) |value|
        helpCatalogCategoryCount(registry, query, value)
    else
        helpCatalogCount(registry, query);
}

pub fn helpCatalogCategoryCount(registry: SlashRegistry, query: []const u8, category: SlashPresentationCategory) usize {
    var count: usize = 0;
    for (registry.commands) |spec| {
        if (spec.presentation_category != category or !helpCatalogSpecMatches(spec, query)) continue;
        count += 1;
    }
    return count;
}

pub fn helpCatalogSpecAt(registry: SlashRegistry, query: []const u8, display_index: usize) ?*const SlashSpec {
    var current: usize = 0;
    for (std.meta.tags(SlashPresentationCategory)) |category| {
        for (registry.commands) |*spec| {
            if (spec.presentation_category != category or !helpCatalogSpecMatches(spec.*, query)) continue;
            if (current == display_index) return spec;
            current += 1;
        }
    }
    return null;
}

pub fn helpCatalogSpecAtForCategory(
    registry: SlashRegistry,
    category: ?SlashPresentationCategory,
    query: []const u8,
    display_index: usize,
) ?*const SlashSpec {
    const value = category orelse return helpCatalogSpecAt(registry, query, display_index);
    var current: usize = 0;
    for (registry.commands) |*spec| {
        if (spec.presentation_category != value or !helpCatalogSpecMatches(spec.*, query)) continue;
        if (current == display_index) return spec;
        current += 1;
    }
    return null;
}

fn helpCatalogSpecMatches(spec: SlashSpec, query: []const u8) bool {
    if (spec.help_entry == null or spec.completion_description == null or spec.presentation_category == null) return false;

    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (tokens.next()) |token| {
        if (containsIgnoreCase(spec.command, token) or
            containsIgnoreCase(spec.help_entry.?, token) or
            containsIgnoreCase(spec.completion_description.?, token) or
            containsIgnoreCase(spec.presentation_category.?.label(), token))
        {
            continue;
        }
        for (spec.aliases) |alias| {
            if (containsIgnoreCase(alias, token)) break;
        } else return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

pub fn topLevelUsage(registry: TopLevelRegistry, kind: TopLevelKind) []const u8 {
    return topLevelSpec(registry, kind).usage;
}

pub fn firstSlashCompletion(registry: SlashRegistry, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0 or prefix[0] != '/') return null;
    for (registry.commands) |spec| {
        if (spec.help_entry == null) continue;
        if (std.mem.startsWith(u8, spec.command, prefix) and spec.command.len > prefix.len) {
            return spec.command;
        }
        if (spec.show_aliases_in_completion) {
            for (spec.aliases) |alias| {
                if (std.mem.startsWith(u8, alias, prefix) and alias.len > prefix.len) {
                    return alias;
                }
            }
        }
    }
    return null;
}

const slash_completion_match_rank_count: usize = 3;

const SlashCompletionCommandMatch = struct {
    command: []const u8,
    rank: usize,
};

const SlashCompletionMatch = struct {
    spec: *const SlashSpec,
    command: []const u8,
};

fn completionCommandMatchRank(command: []const u8, prefix: []const u8) ?usize {
    if (std.mem.eql(u8, command, prefix)) return 0;
    if (std.mem.startsWith(u8, command, prefix)) return 1;
    if (prefix.len <= 1 or command.len <= 1) return null;
    if (std.mem.find(u8, command[1..], prefix[1..]) != null) return 2;
    return null;
}

fn bestCompletionCommandMatch(spec: SlashSpec, prefix: []const u8) ?SlashCompletionCommandMatch {
    var best: ?SlashCompletionCommandMatch = if (completionCommandMatchRank(spec.command, prefix)) |rank|
        .{ .command = spec.command, .rank = rank }
    else
        null;

    if (spec.show_aliases_in_completion) {
        for (spec.aliases) |alias| {
            const rank = completionCommandMatchRank(alias, prefix) orelse continue;
            if (best == null or rank < best.?.rank) {
                best = .{ .command = alias, .rank = rank };
            }
        }
    }
    return best;
}

pub fn matchedCompletionCommand(spec: SlashSpec, prefix: []const u8) ?[]const u8 {
    return (bestCompletionCommandMatch(spec, prefix) orelse return null).command;
}

fn nthSlashCommandCompletionMatch(registry: SlashRegistry, prefix: []const u8, n: usize) ?SlashCompletionMatch {
    var idx: usize = 0;
    for (0..slash_completion_match_rank_count) |rank| {
        for (registry.commands) |*spec| {
            if (spec.help_entry == null) continue;
            const match = bestCompletionCommandMatch(spec.*, prefix) orelse continue;
            if (match.rank != rank) continue;
            if (idx == n) {
                return .{
                    .spec = spec,
                    .command = match.command,
                };
            }
            idx += 1;
        }
    }
    return null;
}

pub fn slashCompletionPrefix(registry: SlashRegistry, input: []const u8) ?[]const u8 {
    const prefix = std.mem.trimStart(u8, input, " \t\r\n");
    if (prefix.len == 0 or prefix[0] != '/') return null;

    const command_end = std.mem.indexOfAny(u8, prefix, " \t\r\n") orelse return prefix;
    const spec = registry.lookup(prefix[0..command_end]) orelse return prefix;
    if (!spec.has_args) return null;
    return prefix;
}

pub fn slashCompletionCount(registry: SlashRegistry, prefix: []const u8) usize {
    if (allowlistArgCompletionPrefix(prefix)) |query| {
        return allowlistArgCompletionCount(query);
    }
    if (statuslineArgCompletionPrefix(prefix)) |query| {
        return statuslineArgCompletionCount(query);
    }
    if (notificationsArgCompletionPrefix(prefix)) |query| {
        return notificationsArgCompletionCount(query);
    }
    if (permissionsArgCompletionPrefix(prefix)) |query| {
        return permissionsArgCompletionCount(query);
    }
    if (workspaceArgCompletionPrefix(prefix)) |query| {
        return workspaceArgCompletionCount(query);
    }
    if (prefix.len == 0 or prefix[0] != '/') return 0;
    var count: usize = 0;
    for (registry.commands) |spec| {
        if (spec.help_entry == null) continue;
        if (matchedCompletionCommand(spec, prefix) != null) count += 1;
    }
    return count;
}

pub fn nthSlashCompletion(registry: SlashRegistry, prefix: []const u8, n: usize) ?[]const u8 {
    if (allowlistArgCompletionPrefix(prefix)) |query| {
        return nthAllowlistArgCompletion(query, n);
    }
    if (statuslineArgCompletionPrefix(prefix)) |query| {
        return nthStatuslineArgCompletion(query, n);
    }
    if (notificationsArgCompletionPrefix(prefix)) |query| {
        return nthNotificationsArgCompletion(query, n);
    }
    if (permissionsArgCompletionPrefix(prefix)) |query| {
        return nthPermissionsArgCompletion(query, n);
    }
    if (workspaceArgCompletionPrefix(prefix)) |query| {
        return nthWorkspaceArgCompletion(query, n);
    }
    if (prefix.len == 0 or prefix[0] != '/') return null;
    return (nthSlashCommandCompletionMatch(registry, prefix, n) orelse return null).command;
}

/// Returns the byte offset where the argument portion begins for
/// known arg-completion commands. Returns 0 when
/// the prefix is not an arg-completion command.
pub fn argCompletionAnchor(prefix: []const u8) usize {
    if (statuslineArgCompletionPrefix(prefix) != null) return "/statusline ".len;
    if (notificationsArgCompletionPrefix(prefix) != null) return "/sound ".len;
    if (permissionsArgCompletionPrefix(prefix) != null) return "/permissions ".len;
    if (workspaceArgCompletionPrefix(prefix) != null) return "/workspace ".len;
    if (allowlistArgCompletionAnchor(prefix)) |anchor| return anchor;
    return 0;
}

/// Like `nthSlashCompletion` but returns the display label only.
/// For argument completions the command prefix is stripped so the bar
/// shows only the argument. For everything else the
/// full command string is returned unchanged.
pub fn nthSlashCompletionLabel(registry: SlashRegistry, prefix: []const u8, n: usize) ?[]const u8 {
    if (allowlistArgCompletionPrefix(prefix)) |query| {
        return nthAllowlistArgLabel(query, n);
    }
    if (statuslineArgCompletionPrefix(prefix)) |query| {
        return nthStatuslineArgLabel(query, n);
    }
    if (notificationsArgCompletionPrefix(prefix)) |query| {
        return nthNotificationsArgLabel(query, n);
    }
    if (permissionsArgCompletionPrefix(prefix)) |query| {
        return nthPermissionsArgLabel(query, n);
    }
    if (workspaceArgCompletionPrefix(prefix)) |query| {
        return nthWorkspaceArgLabel(query, n);
    }
    return nthSlashCompletion(registry, prefix, n);
}

pub fn nthSlashCompletionDescription(registry: SlashRegistry, prefix: []const u8, n: usize) ?[]const u8 {
    if (allowlistArgCompletionPrefix(prefix) != null) return null;
    if (statuslineArgCompletionPrefix(prefix) != null) return null;
    if (notificationsArgCompletionPrefix(prefix) != null) return null;
    if (permissionsArgCompletionPrefix(prefix) != null) return null;
    if (workspaceArgCompletionPrefix(prefix) != null) return null;
    if (prefix.len == 0 or prefix[0] != '/') return null;
    return (nthSlashCommandCompletionMatch(registry, prefix, n) orelse return null).spec.completion_description;
}

pub fn nthSlashCompletionCategory(registry: SlashRegistry, prefix: []const u8, n: usize) ?SlashPresentationCategory {
    if (argCompletionAnchor(prefix) != 0) return null;
    if (prefix.len == 0 or prefix[0] != '/') return null;
    return (nthSlashCommandCompletionMatch(registry, prefix, n) orelse return null).spec.presentation_category;
}

pub fn slashCompletionHasArgs(registry: SlashRegistry, command: []const u8) bool {
    if (allowlistCompletionHasArgs(command)) return true;
    if (std.mem.eql(u8, command, "/workspace add") or
        std.mem.eql(u8, command, "/workspace remove")) return true;
    for (registry.commands) |spec| {
        if (std.mem.eql(u8, spec.command, command)) return spec.has_args;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, alias, command)) return spec.has_args;
        }
    }
    return false;
}

fn allowlistCompletionHasArgs(command: []const u8) bool {
    const completions_with_more_args = [_][]const u8{
        "/allowlist add",
        "/allowlist remove",
        "/allowlist reset",
        "/allowlist view",
        "/allowlist local",
        "/allowlist user",
        "/allowlist local add",
        "/allowlist local remove",
        "/allowlist local reset",
        "/allowlist user add",
        "/allowlist user remove",
        "/allowlist user reset",
        "/allowlist add command",
        "/allowlist add tool",
        "/allowlist add url",
        "/allowlist add web-fetch-domain",
        "/allowlist remove command",
        "/allowlist remove tool",
        "/allowlist remove url",
        "/allowlist remove web-fetch-domain",
        "/allowlist local add command",
        "/allowlist local add tool",
        "/allowlist local add url",
        "/allowlist local add web-fetch-domain",
        "/allowlist local remove command",
        "/allowlist local remove tool",
        "/allowlist local remove url",
        "/allowlist local remove web-fetch-domain",
        "/allowlist user add command",
        "/allowlist user add tool",
        "/allowlist user add url",
        "/allowlist user add web-fetch-domain",
        "/allowlist user remove command",
        "/allowlist user remove tool",
        "/allowlist user remove url",
        "/allowlist user remove web-fetch-domain",
    };
    for (completions_with_more_args) |completion| {
        if (std.mem.eql(u8, command, completion)) return true;
    }
    return false;
}

const statusline_arg_completions = [_][]const u8{
    "/statusline context",
    "/statusline session",
    "/statusline workspace",
};

const notifications_arg_completions = [_][]const u8{
    "/sound on",
    "/sound off",
    "/sound max",
};

const permissions_arg_completions = [_][]const u8{
    "/permissions ask",
    "/permissions auto",
    "/permissions remember",
    "/permissions revoke",
    "/permissions yolo",
    "/permissions reset",
};

const workspace_arg_completions = [_][]const u8{
    "/workspace list",
    "/workspace add",
    "/workspace remove",
    "/workspace clear",
};

const allowlist_action_completions = [_][]const u8{
    "/allowlist view",
    "/allowlist add",
    "/allowlist remove",
    "/allowlist reset",
    "/allowlist local",
    "/allowlist user",
};

const allowlist_view_completions = [_][]const u8{
    "/allowlist view effective",
    "/allowlist view local",
    "/allowlist view user",
};

const allowlist_scoped_action_suffixes = [_][]const u8{
    "add",
    "remove",
    "reset",
};

const allowlist_add_kind_completions = [_][]const u8{
    "/allowlist add command",
    "/allowlist add tool",
    "/allowlist add url",
    "/allowlist add web-fetch-domain",
};

const allowlist_remove_kind_completions = [_][]const u8{
    "/allowlist remove command",
    "/allowlist remove tool",
    "/allowlist remove url",
    "/allowlist remove web-fetch-domain",
};

const allowlist_reset_scope_completions = [_][]const u8{
    "/allowlist reset commands",
    "/allowlist reset tools",
    "/allowlist reset urls",
    "/allowlist reset web-fetch-domains",
    "/allowlist reset all",
};

const allowlist_add_tool_completions = [_][]const u8{
    "/allowlist add tool read_file",
    "/allowlist add tool write_file",
    "/allowlist add tool edit_file",
    "/allowlist add tool glob_files",
    "/allowlist add tool grep_files",
    "/allowlist add tool skill",
    "/allowlist add tool install_skill",
    "/allowlist add tool subagent",
};

const allowlist_remove_tool_completions = [_][]const u8{
    "/allowlist remove tool read_file",
    "/allowlist remove tool write_file",
    "/allowlist remove tool edit_file",
    "/allowlist remove tool glob_files",
    "/allowlist remove tool grep_files",
    "/allowlist remove tool skill",
    "/allowlist remove tool install_skill",
    "/allowlist remove tool subagent",
};

fn scopedAllowlistCompletions(
    comptime scope: []const u8,
    comptime source: anytype,
) [source.len][]const u8 {
    var result: [source.len][]const u8 = undefined;
    inline for (source, 0..) |completion, idx| {
        const suffix = if (std.mem.startsWith(u8, completion, "/allowlist "))
            completion["/allowlist ".len..]
        else
            completion;
        result[idx] = std.fmt.comptimePrint("/allowlist {s} {s}", .{ scope, suffix });
    }
    return result;
}

const allowlist_local_action_completions = scopedAllowlistCompletions("local", allowlist_scoped_action_suffixes);
const allowlist_user_action_completions = scopedAllowlistCompletions("user", allowlist_scoped_action_suffixes);
const allowlist_local_add_kind_completions = scopedAllowlistCompletions("local", allowlist_add_kind_completions);
const allowlist_user_add_kind_completions = scopedAllowlistCompletions("user", allowlist_add_kind_completions);
const allowlist_local_remove_kind_completions = scopedAllowlistCompletions("local", allowlist_remove_kind_completions);
const allowlist_user_remove_kind_completions = scopedAllowlistCompletions("user", allowlist_remove_kind_completions);
const allowlist_local_reset_scope_completions = scopedAllowlistCompletions("local", allowlist_reset_scope_completions);
const allowlist_user_reset_scope_completions = scopedAllowlistCompletions("user", allowlist_reset_scope_completions);
const allowlist_local_add_tool_completions = scopedAllowlistCompletions("local", allowlist_add_tool_completions);
const allowlist_user_add_tool_completions = scopedAllowlistCompletions("user", allowlist_add_tool_completions);
const allowlist_local_remove_tool_completions = scopedAllowlistCompletions("local", allowlist_remove_tool_completions);
const allowlist_user_remove_tool_completions = scopedAllowlistCompletions("user", allowlist_remove_tool_completions);

fn argCompletionPrefix(prefix: []const u8, command: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, prefix, command)) return null;
    if (prefix.len == command.len) return null;
    const boundary = prefix[command.len];
    if (boundary != ' ' and boundary != '\t') return null;
    return std.mem.trim(u8, prefix[command.len..], " \t");
}

fn rawArgCompletionPrefix(prefix: []const u8, command: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, prefix, command)) return null;
    if (prefix.len == command.len) return null;
    const boundary = prefix[command.len];
    if (boundary != ' ' and boundary != '\t') return null;
    return std.mem.trimStart(u8, prefix[command.len..], " \t");
}

pub fn allowlistArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return rawArgCompletionPrefix(prefix, "/allowlist");
}

pub fn statuslineArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/statusline");
}

pub fn notificationsArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/sound");
}

pub fn permissionsArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/permissions");
}

pub fn workspaceArgCompletionPrefix(prefix: []const u8) ?[]const u8 {
    return argCompletionPrefix(prefix, "/workspace");
}

fn argCompletionCount(completions: []const []const u8, command_with_space_len: usize, query: []const u8) usize {
    var count: usize = 0;
    for (completions) |completion| {
        if (argCompletionMatches(completion, command_with_space_len, query)) count += 1;
    }
    return count;
}

fn statuslineArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&statusline_arg_completions, "/statusline ".len, query);
}

fn notificationsArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&notifications_arg_completions, "/sound ".len, query);
}

fn permissionsArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&permissions_arg_completions, "/permissions ".len, query);
}

fn workspaceArgCompletionCount(query: []const u8) usize {
    return argCompletionCount(&workspace_arg_completions, "/workspace ".len, query);
}

fn allowlistArgCompletionCount(query: []const u8) usize {
    const state = allowlistArgCompletionState(query);
    return argCompletionCount(state.completions, state.label_offset, state.query);
}

fn nthArgCompletion(completions: []const []const u8, command_with_space_len: usize, query: []const u8, n: usize) ?[]const u8 {
    var idx: usize = 0;
    for (completions) |completion| {
        if (!argCompletionMatches(completion, command_with_space_len, query)) continue;
        if (idx == n) return completion;
        idx += 1;
    }
    return null;
}

fn nthStatuslineArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&statusline_arg_completions, "/statusline ".len, query, n);
}

fn nthStatuslineArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthStatuslineArgCompletion(query, n) orelse return null;
    return full["/statusline ".len..];
}

fn nthNotificationsArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&notifications_arg_completions, "/sound ".len, query, n);
}

fn nthNotificationsArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthNotificationsArgCompletion(query, n) orelse return null;
    return full["/sound ".len..];
}

fn nthPermissionsArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&permissions_arg_completions, "/permissions ".len, query, n);
}

fn nthPermissionsArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthPermissionsArgCompletion(query, n) orelse return null;
    return full["/permissions ".len..];
}

fn nthWorkspaceArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    return nthArgCompletion(&workspace_arg_completions, "/workspace ".len, query, n);
}

fn nthWorkspaceArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const full = nthWorkspaceArgCompletion(query, n) orelse return null;
    return full["/workspace ".len..];
}

fn nthAllowlistArgCompletion(query: []const u8, n: usize) ?[]const u8 {
    const state = allowlistArgCompletionState(query);
    return nthArgCompletion(state.completions, state.label_offset, state.query, n);
}

fn nthAllowlistArgLabel(query: []const u8, n: usize) ?[]const u8 {
    const state = allowlistArgCompletionState(query);
    const full = nthArgCompletion(state.completions, state.label_offset, state.query, n) orelse return null;
    return full[state.label_offset..];
}

/// Returns the index of `label` among the matching arg completions for
/// the given prefix, or null if the label is not in the filtered set.
pub fn argCompletionIndexForLabel(prefix: []const u8, label: []const u8) ?usize {
    if (allowlistArgCompletionPrefix(prefix)) |query| {
        const state = allowlistArgCompletionState(query);
        return indexOfArgLabel(state.completions, state.label_offset, state.query, label);
    }
    if (statuslineArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&statusline_arg_completions, "/statusline ".len, query, label);
    }
    if (notificationsArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&notifications_arg_completions, "/sound ".len, query, label);
    }
    if (permissionsArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&permissions_arg_completions, "/permissions ".len, query, label);
    }
    if (workspaceArgCompletionPrefix(prefix)) |query| {
        return indexOfArgLabel(&workspace_arg_completions, "/workspace ".len, query, label);
    }
    return null;
}

fn indexOfArgLabel(completions: []const []const u8, command_with_space_len: usize, query: []const u8, label: []const u8) ?usize {
    var idx: usize = 0;
    for (completions) |completion| {
        if (!argCompletionMatches(completion, command_with_space_len, query)) continue;
        const arg = completion[command_with_space_len..];
        if (std.mem.eql(u8, arg, label)) return idx;
        idx += 1;
    }
    return null;
}

fn argCompletionMatches(completion: []const u8, command_with_space_len: usize, query: []const u8) bool {
    const arg = completion[command_with_space_len..];
    return query.len == 0 or std.ascii.startsWithIgnoreCase(arg, query);
}

const AllowlistArgCompletionState = struct {
    completions: []const []const u8,
    label_offset: usize,
    query: []const u8,
};

fn allowlistArgCompletionState(query: []const u8) AllowlistArgCompletionState {
    const split = splitAllowlistArgQuery(query);
    if (split.has_rest) {
        if (std.ascii.eqlIgnoreCase(split.word, "view")) {
            return .{
                .completions = &allowlist_view_completions,
                .label_offset = "/allowlist view ".len,
                .query = split.rest,
            };
        }
        if (std.ascii.eqlIgnoreCase(split.word, "local")) {
            return scopedAllowlistArgCompletionState(.local, split.rest);
        }
        if (std.ascii.eqlIgnoreCase(split.word, "user")) {
            return scopedAllowlistArgCompletionState(.user, split.rest);
        }
        if (std.ascii.eqlIgnoreCase(split.word, "add")) {
            if (allowlistToolArgQuery(split.rest)) |tool_query| {
                return .{
                    .completions = &allowlist_add_tool_completions,
                    .label_offset = "/allowlist add tool ".len,
                    .query = tool_query,
                };
            }
            return .{
                .completions = &allowlist_add_kind_completions,
                .label_offset = "/allowlist add ".len,
                .query = split.rest,
            };
        }
        if (std.ascii.eqlIgnoreCase(split.word, "remove")) {
            if (allowlistToolArgQuery(split.rest)) |tool_query| {
                return .{
                    .completions = &allowlist_remove_tool_completions,
                    .label_offset = "/allowlist remove tool ".len,
                    .query = tool_query,
                };
            }
            return .{
                .completions = &allowlist_remove_kind_completions,
                .label_offset = "/allowlist remove ".len,
                .query = split.rest,
            };
        }
        if (std.ascii.eqlIgnoreCase(split.word, "reset")) {
            return .{
                .completions = &allowlist_reset_scope_completions,
                .label_offset = "/allowlist reset ".len,
                .query = split.rest,
            };
        }
        return .{ .completions = &.{}, .label_offset = "/allowlist ".len, .query = "" };
    }

    return .{
        .completions = &allowlist_action_completions,
        .label_offset = "/allowlist ".len,
        .query = split.word,
    };
}

const AllowlistCompletionScope = enum {
    local,
    user,
};

fn scopedAllowlistArgCompletionState(
    scope: AllowlistCompletionScope,
    query: []const u8,
) AllowlistArgCompletionState {
    const scope_label = @tagName(scope);
    const split = splitAllowlistArgQuery(query);
    if (!split.has_rest) {
        return switch (scope) {
            .local => .{
                .completions = &allowlist_local_action_completions,
                .label_offset = "/allowlist local ".len,
                .query = split.word,
            },
            .user => .{
                .completions = &allowlist_user_action_completions,
                .label_offset = "/allowlist user ".len,
                .query = split.word,
            },
        };
    }

    if (std.ascii.eqlIgnoreCase(split.word, "add")) {
        if (allowlistToolArgQuery(split.rest)) |tool_query| {
            return switch (scope) {
                .local => .{
                    .completions = &allowlist_local_add_tool_completions,
                    .label_offset = "/allowlist local add tool ".len,
                    .query = tool_query,
                },
                .user => .{
                    .completions = &allowlist_user_add_tool_completions,
                    .label_offset = "/allowlist user add tool ".len,
                    .query = tool_query,
                },
            };
        }
        return switch (scope) {
            .local => .{
                .completions = &allowlist_local_add_kind_completions,
                .label_offset = "/allowlist local add ".len,
                .query = split.rest,
            },
            .user => .{
                .completions = &allowlist_user_add_kind_completions,
                .label_offset = "/allowlist user add ".len,
                .query = split.rest,
            },
        };
    }
    if (std.ascii.eqlIgnoreCase(split.word, "remove")) {
        if (allowlistToolArgQuery(split.rest)) |tool_query| {
            return switch (scope) {
                .local => .{
                    .completions = &allowlist_local_remove_tool_completions,
                    .label_offset = "/allowlist local remove tool ".len,
                    .query = tool_query,
                },
                .user => .{
                    .completions = &allowlist_user_remove_tool_completions,
                    .label_offset = "/allowlist user remove tool ".len,
                    .query = tool_query,
                },
            };
        }
        return switch (scope) {
            .local => .{
                .completions = &allowlist_local_remove_kind_completions,
                .label_offset = "/allowlist local remove ".len,
                .query = split.rest,
            },
            .user => .{
                .completions = &allowlist_user_remove_kind_completions,
                .label_offset = "/allowlist user remove ".len,
                .query = split.rest,
            },
        };
    }
    if (std.ascii.eqlIgnoreCase(split.word, "reset")) {
        return switch (scope) {
            .local => .{
                .completions = &allowlist_local_reset_scope_completions,
                .label_offset = "/allowlist local reset ".len,
                .query = split.rest,
            },
            .user => .{
                .completions = &allowlist_user_reset_scope_completions,
                .label_offset = "/allowlist user reset ".len,
                .query = split.rest,
            },
        };
    }
    return .{
        .completions = &.{},
        .label_offset = "/allowlist ".len + scope_label.len + 1,
        .query = "",
    };
}

fn allowlistArgCompletionAnchor(prefix: []const u8) ?usize {
    const query = allowlistArgCompletionPrefix(prefix) orelse return null;
    const split = splitAllowlistArgQuery(query);
    if (!split.has_rest) return "/allowlist ".len;
    if (std.ascii.eqlIgnoreCase(split.word, "view")) return "/allowlist view ".len;
    if (std.ascii.eqlIgnoreCase(split.word, "local")) {
        return scopedAllowlistArgCompletionAnchor(.local, split.rest);
    }
    if (std.ascii.eqlIgnoreCase(split.word, "user")) {
        return scopedAllowlistArgCompletionAnchor(.user, split.rest);
    }
    if (std.ascii.eqlIgnoreCase(split.word, "add")) {
        if (allowlistToolArgQuery(split.rest) != null) return "/allowlist add tool ".len;
        return "/allowlist add ".len;
    }
    if (std.ascii.eqlIgnoreCase(split.word, "remove")) {
        if (allowlistToolArgQuery(split.rest) != null) return "/allowlist remove tool ".len;
        return "/allowlist remove ".len;
    }
    if (std.ascii.eqlIgnoreCase(split.word, "reset")) return "/allowlist reset ".len;
    return "/allowlist ".len;
}

fn scopedAllowlistArgCompletionAnchor(
    scope: AllowlistCompletionScope,
    query: []const u8,
) usize {
    const split = splitAllowlistArgQuery(query);
    const base = switch (scope) {
        .local => "/allowlist local ",
        .user => "/allowlist user ",
    };
    if (!split.has_rest) return base.len;
    if (std.ascii.eqlIgnoreCase(split.word, "add")) {
        if (allowlistToolArgQuery(split.rest) != null) return base.len + "add tool ".len;
        return base.len + "add ".len;
    }
    if (std.ascii.eqlIgnoreCase(split.word, "remove")) {
        if (allowlistToolArgQuery(split.rest) != null) return base.len + "remove tool ".len;
        return base.len + "remove ".len;
    }
    if (std.ascii.eqlIgnoreCase(split.word, "reset")) return base.len + "reset ".len;
    return base.len;
}

fn allowlistToolArgQuery(query: []const u8) ?[]const u8 {
    const split = splitAllowlistArgQuery(query);
    if (!split.has_rest) return null;
    if (!std.ascii.eqlIgnoreCase(split.word, "tool")) return null;
    return split.rest;
}

const AllowlistArgQuery = struct {
    word: []const u8,
    rest: []const u8,
    has_rest: bool,
};

fn splitAllowlistArgQuery(query: []const u8) AllowlistArgQuery {
    const trimmed_start = std.mem.trimStart(u8, query, " \t");
    for (trimmed_start, 0..) |c, idx| {
        if (c == ' ' or c == '\t') {
            return .{
                .word = trimmed_start[0..idx],
                .rest = std.mem.trimStart(u8, trimmed_start[idx + 1 ..], " \t"),
                .has_rest = true,
            };
        }
    }
    return .{ .word = trimmed_start, .rest = "", .has_rest = false };
}

fn renderSlashEntries(alloc: Allocator, registry: SlashRegistry, welcome_only: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var first = true;
    for (registry.commands) |spec| {
        if (welcome_only) {
            if (!spec.show_in_welcome) continue;
            if (!first) try out.writer.writeAll("  ");
            first = false;
            try out.writer.writeAll(spec.command);
            continue;
        }

        const entry = spec.help_entry orelse continue;
        if (!first) try out.writer.writeByte(' ');
        first = false;
        try out.writer.writeAll(entry);
    }

    return try out.toOwnedSlice();
}

fn topLevelSpec(registry: TopLevelRegistry, kind: TopLevelKind) TopLevelSpec {
    for (registry.specs) |spec| {
        if (spec.kind == kind) return spec;
    }
    unreachable;
}

fn slashSpec(registry: SlashRegistry, kind: SlashKind) SlashSpec {
    return slashSpecPtr(registry, kind).*;
}

fn slashSpecPtr(registry: SlashRegistry, kind: SlashKind) *const SlashSpec {
    for (registry.commands) |*spec| {
        if (spec.kind == kind) return spec;
    }
    unreachable;
}

fn matchesCommandToken(input: []const u8, primary: []const u8, aliases: []const []const u8) bool {
    if (std.mem.eql(u8, input, primary)) return true;
    for (aliases) |alias| {
        if (std.mem.eql(u8, input, alias)) return true;
    }

    if (input.len == 0) return false;
    const last = input[input.len - 1];
    if (last != ' ' and last != '\t') return false;

    const trimmed = std.mem.trimEnd(u8, input, " \t");
    if (std.mem.eql(u8, trimmed, primary)) return true;
    for (aliases) |alias| {
        if (std.mem.eql(u8, trimmed, alias)) return true;
    }
    return false;
}

fn normalizedTopLevelHelpWidth(columns: usize) usize {
    return if (columns == 0) top_level_help_default_width else columns;
}

fn maxTopLevelHelpUsageWidth(registry: TopLevelRegistry) usize {
    var width: usize = 0;
    for (registry.help_groups) |group| {
        for (group.entries) |entry| {
            if (entry.kind) |kind| {
                if (topLevelSpec(registry, kind).hidden_from_top_level_help) continue;
            }
            width = @max(width, entry.usage.len);
        }
    }
    return width;
}

fn maxTopLevelFlagUsageWidth(registry: TopLevelRegistry) usize {
    var width: usize = 0;
    for (registry.flags) |flag| {
        width = @max(width, flag.usage.len);
    }
    return width;
}

fn maxTopLevelResourceLabelWidth(registry: TopLevelRegistry) usize {
    var width: usize = 0;
    for (registry.resources) |resource| {
        width = @max(width, display_width.visibleWidth(resource.label));
    }
    return width;
}

fn writeTopLevelHelpEntry(writer: *std.Io.Writer, registry: TopLevelRegistry, entry: TopLevelHelpEntry, usage_width: usize, columns: usize, style: HelpStyle) !void {
    const spaces = "                                                                ";
    const summary = entry.summary orelse topLevelSpec(registry, entry.kind.?).summary;
    if (entry.kind) |kind| {
        if (topLevelSpec(registry, kind).hidden_from_top_level_help) return;
    }
    const padding = usage_width - entry.usage.len + 2;
    var prefix_buf: [128]u8 = undefined;
    var continuation_buf: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "  {s}{s}{s}{s}", .{ styleStart(style, .syntax), entry.usage, styleEnd(style), spaces[0..padding] });
    const continuation = try std.fmt.bufPrint(&continuation_buf, "  {s}", .{spaces[0 .. usage_width + 2]});
    try writeWrappedLine(writer, prefix, continuation, summary, columns);
}

fn writeTopLevelFlag(writer: *std.Io.Writer, flag: TopLevelFlag, usage_width: usize, columns: usize, style: HelpStyle) !void {
    const spaces = "                                                                ";
    const padding = usage_width - flag.usage.len + 2;
    var prefix_buf: [160]u8 = undefined;
    var continuation_buf: [96]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "  {s}{s}{s}{s}", .{ styleStart(style, .syntax), flag.usage, styleEnd(style), spaces[0..padding] });
    const continuation = try std.fmt.bufPrint(&continuation_buf, "  {s}", .{spaces[0 .. usage_width + 2]});
    try writeWrappedLine(writer, prefix, continuation, flag.description, columns);
}

fn writeTopLevelExample(writer: *std.Io.Writer, example: TopLevelExample, columns: usize, style: HelpStyle) !void {
    try writeWrappedStyledLine(writer, "  ", "  ", example.command, columns, style, .syntax);
    try writeWrappedStyledLine(writer, "      ", "      ", example.description, columns, style, .muted);
    try writer.writeByte('\n');
}

fn writeTopLevelResource(writer: *std.Io.Writer, resource: TopLevelResource, label_width: usize, columns: usize, style: HelpStyle) !void {
    const spaces = "                                                                ";
    const padding = label_width - display_width.visibleWidth(resource.label) + 2;
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}{s}{s}{s}", .{ styleStart(style, .label), resource.label, styleEnd(style), spaces[0..padding] });
    const value_role: HelpRole = if (resource.link) .link else .syntax;
    try writeWrappedStyledLine(writer, prefix, "  ", resource.value, columns, style, value_role);
}

fn writeSectionHeading(writer: *std.Io.Writer, style: HelpStyle, heading: []const u8) !void {
    try writer.writeByte('\n');
    try writeStyled(writer, style, .heading, heading);
    try writer.writeByte('\n');
}

fn writeStyled(writer: *std.Io.Writer, style: HelpStyle, role: HelpRole, text: []const u8) !void {
    try writeStyleStart(writer, style, role);
    try writer.writeAll(text);
    try writeStyleEnd(writer, style);
}

fn writeStyleStart(writer: *std.Io.Writer, style: HelpStyle, role: HelpRole) !void {
    try writer.writeAll(styleStart(style, role));
}

fn writeStyleEnd(writer: *std.Io.Writer, style: HelpStyle) !void {
    try writer.writeAll(styleEnd(style));
}

fn styleStart(style: HelpStyle, role: HelpRole) []const u8 {
    if (style == .plain) return "";
    return switch (role) {
        .brand => "\x1b[1m",
        .heading, .label => "\x1b[1m",
        .syntax => "\x1b[39m",
        .muted => "\x1b[38;5;243m",
        .link => "\x1b[4m",
    };
}

fn styleEnd(style: HelpStyle) []const u8 {
    return if (style == .ansi) "\x1b[0m" else "";
}

fn writeWrappedStyledLine(writer: *std.Io.Writer, prefix: []const u8, continuation_prefix: []const u8, text: []const u8, columns: usize, style: HelpStyle, role: HelpRole) !void {
    return writeWrappedLineDecorated(writer, prefix, continuation_prefix, text, columns, styleStart(style, role), styleEnd(style));
}

fn writeWrappedLine(writer: *std.Io.Writer, prefix: []const u8, continuation_prefix: []const u8, text: []const u8, columns: usize) !void {
    return writeWrappedLineDecorated(writer, prefix, continuation_prefix, text, columns, "", "");
}

fn writeWrappedLineDecorated(writer: *std.Io.Writer, prefix: []const u8, continuation_prefix: []const u8, text: []const u8, columns: usize, text_start: []const u8, text_end: []const u8) !void {
    const prefix_width = display_width.visibleWidthIgnoringAnsi(prefix);
    const continuation_width = display_width.visibleWidthIgnoringAnsi(continuation_prefix);
    var budget = if (columns > prefix_width) columns - prefix_width else 1;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var line_width: usize = 0;

    try writer.writeAll(prefix);
    try writer.writeAll(text_start);
    while (words.next()) |word| {
        const word_width = display_width.visibleWidthIgnoringAnsi(word);
        if (line_width == 0) {
            try writer.writeAll(word);
            line_width = word_width;
            continue;
        }

        if (line_width + 1 + word_width <= budget) {
            try writer.writeByte(' ');
            try writer.writeAll(word);
            line_width += 1 + word_width;
            continue;
        }

        try writer.writeAll(text_end);
        try writer.writeByte('\n');
        try writer.writeAll(continuation_prefix);
        try writer.writeAll(text_start);
        budget = if (columns > continuation_width) columns - continuation_width else 1;
        try writer.writeAll(word);
        line_width = word_width;
    }
    try writer.writeAll(text_end);
    try writer.writeByte('\n');
}

fn writePadding(writer: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writeByte(' ');
    }
}

fn topLevelTokenOccurrences(registry: TopLevelRegistry, token: []const u8) usize {
    var count: usize = 0;
    for (registry.specs) |spec| {
        if (std.mem.eql(u8, token, spec.token)) count += 1;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, token, alias)) count += 1;
        }
    }
    return count;
}

fn slashTokenOccurrences(registry: SlashRegistry, token: []const u8) usize {
    var count: usize = 0;
    for (registry.commands) |spec| {
        if (std.mem.eql(u8, token, spec.command)) count += 1;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, token, alias)) count += 1;
        }
    }
    return count;
}

fn topLevelIndexOccurrences(registry: TopLevelRegistry, kind: TopLevelKind) usize {
    var count: usize = 0;
    for (registry.help_groups) |group| {
        for (group.entries) |entry| {
            if (entry.kind == kind) count += 1;
        }
    }
    return count;
}

fn topLevelHelpContainsCommandToken(text: []const u8, token: []const u8) bool {
    var index: usize = 0;
    while (std.mem.find(u8, text[index..], token)) |relative| {
        const start = index + relative;
        const end = start + token.len;
        const before_ok = start == 0 or isTopLevelTokenBoundary(text[start - 1]);
        const after_ok = end == text.len or isTopLevelTokenBoundary(text[end]);
        if (before_ok and after_ok) return true;
        index = end;
    }
    return false;
}

fn isTopLevelTokenBoundary(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == ',' or byte == ':' or byte == '<' or byte == '>' or byte == '[' or byte == ']' or byte == '|';
}

fn testSlashRegistry() SlashRegistry {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.slash_registry;
}

fn testTopLevelRegistry() TopLevelRegistry {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.top_level_registry;
}

fn testTopLevelHelpText(alloc: Allocator) ![]u8 {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.renderTopLevelHelp(alloc, top_level_help_default_width, "9.8.7");
}

fn lineContainsBoth(text: []const u8, first: []const u8, second: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, first) != null and std.mem.find(u8, line, second) != null) return true;
    }
    return false;
}
