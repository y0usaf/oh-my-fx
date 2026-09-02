const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const list_window = @import("../../core/shared/list_window.zig");
const model_cache_runtime = @import("../../core/app/model_cache_runtime.zig");
const model_capabilities = @import("../../core/config/model_capabilities.zig");
const ui_render = @import("../render.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const ModelMenuProjection = render_input.ModelMenuProjection;

const header_rows: u16 = 1;
const roomy_top_gap_rows: u16 = 1;
const item_rows: u16 = 1;
const status_gap_rows: u16 = 1;
pub const max_visible_items: u16 = 20;
pub const max_inline_rows: u16 = header_rows + roomy_top_gap_rows + max_visible_items + status_gap_rows + 1;

const ModelMenuLayout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    visible_items: u16 = 0,
    first_item_row: u16 = header_rows,
    item_stride: u16 = item_rows,
    show_header: bool = true,
    state_row: ?u16 = null,
    status_row: ?u16 = null,
    row_count: u16 = 0,

    fn build(projection: ModelMenuProjection, row_budget: u16) ModelMenuLayout {
        if (row_budget == 0) return .{};

        const match_count = projection.filteredItemCount();
        const selected = if (match_count > 0) projection.selected_index % match_count else 0;
        if (projection.load_state != .ready or match_count == 0) {
            const state_row: u16 = if (row_budget == 1)
                0
            else if (row_budget == 2)
                1
            else
                header_rows + roomy_top_gap_rows;
            var row_count = state_row + 1;
            const show_status = projection.load_state == .ready and
                loadedCatalogStatusText(projection.catalog_state) != null and
                row_budget >= row_count + status_gap_rows + 1;
            const status_row = if (show_status) row_count + status_gap_rows else null;
            if (status_row) |row| row_count = row + 1;
            return .{
                .match_count = match_count,
                .selected = selected,
                .show_header = row_budget > 1,
                .state_row = state_row,
                .status_row = status_row,
                .row_count = row_count,
            };
        }
        if (row_budget == 1) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .first_item_row = 0,
                .show_header = false,
                .row_count = 1,
            };
        }
        if (row_budget == 2) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .first_item_row = 1,
                .row_count = 2,
            };
        }
        const first_item_row = header_rows + roomy_top_gap_rows;
        const item_budget = row_budget - first_item_row;
        const visible_items: u16 = @intCast(@min(match_count, @max(item_budget, 1), max_visible_items));
        const show_status = loadedCatalogStatusText(projection.catalog_state) != null and item_budget - visible_items >= status_gap_rows + 1;
        const status_row = if (show_status) first_item_row + visible_items + status_gap_rows else null;
        return .{
            .match_count = match_count,
            .selected = selected,
            .visible_items = visible_items,
            .first_item_row = first_item_row,
            .item_stride = item_rows,
            .status_row = status_row,
            .row_count = first_item_row + visible_items + @intFromBool(show_status) * (status_gap_rows + 1),
        };
    }
};

pub fn menuRowCount(projection: ModelMenuProjection, _: u16, max_rows: u16) u16 {
    return ModelMenuLayout.build(projection, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(projection: ModelMenuProjection, row_budget: u16) u16 {
    return ModelMenuLayout.build(projection, row_budget).visible_items;
}

pub fn composeModelMenuRow(
    alloc: Allocator,
    projection: ModelMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const row: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count) return row;

    const layout = ModelMenuLayout.build(projection, row_count);
    if (layout.show_header and row_index == 0) return composeHeaderRow(alloc, projection, width);
    if (projection.load_state != .ready or layout.match_count == 0) {
        if (layout.state_row == row_index) return composeStateRow(alloc, projection, width);
        if (layout.status_row == row_index) {
            const text = loadedCatalogStatusText(projection.catalog_state) orelse return row;
            return composeDimmedRow(alloc, text, width);
        }
        return row;
    }
    if (layout.status_row) |status_row| {
        if (row_index == status_row) {
            const text = loadedCatalogStatusText(projection.catalog_state) orelse return row;
            return composeDimmedRow(alloc, text, width);
        }
    }
    if (row_index < layout.first_item_row) return row;

    const body_offset = row_index - layout.first_item_row;
    const visible_offset = body_offset / layout.item_stride;
    if (visible_offset >= layout.visible_items) return row;
    const item_row = body_offset % layout.item_stride;
    const window_start = list_window.updateEdgeStart(
        projection.window_start,
        layout.match_count,
        layout.selected,
        layout.visible_items,
    );
    const display_index = window_start + visible_offset;
    const item = projection.itemAt(display_index) orelse return row;

    if (item_row == 0) {
        return composeTitleRow(
            alloc,
            item.*,
            display_index == layout.selected,
            modelFactsColumn(projection, width),
            width,
        );
    }
    return row;
}

fn composeHeaderRow(alloc: Allocator, projection: ModelMenuProjection, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try appendHeaderTitle(alloc, &row, projection.filteredItemCount());

    const tabs = ProviderTabs.build(projection.items);
    const active_position = tabs.activePosition(projection.provider_index);
    const active_index = tabs.indices[active_position];
    const title_width = display_width.visibleWidthIgnoringAnsi(row.items);
    if (title_width + 2 + providerTabWidth(active_index, active_index) > width) {
        try row.appendSlice(alloc, "  ");
        try appendProviderTabAt(alloc, &row, active_index, active_index);
        return cloneClippedRow(alloc, row.items, width);
    }

    var start = active_position;
    var end = active_position + 1;
    while (true) {
        var expanded = false;
        if (end < tabs.len and title_width + 2 + providerRangeWidth(tabs, start, end + 1, active_index) <= width) {
            end += 1;
            expanded = true;
        }
        if (start > 0 and title_width + 2 + providerRangeWidth(tabs, start - 1, end, active_index) <= width) {
            start -= 1;
            expanded = true;
        }
        if (!expanded) break;
    }

    try row.appendSlice(alloc, "  ");
    if (start > 0) {
        try appendProviderOverflowMarker(alloc, &row);
        try row.appendSlice(alloc, "  ");
    }
    for (start..end) |position| {
        if (position > start) try row.appendSlice(alloc, "  ");
        try appendProviderTabAt(alloc, &row, tabs.indices[position], active_index);
    }
    if (end < tabs.len) {
        try row.appendSlice(alloc, "  ");
        try appendProviderOverflowMarker(alloc, &row);
    }
    return cloneClippedRow(alloc, row.items, width);
}

const ProviderTabs = struct {
    indices: [model_cache_runtime.model_provider_filter_count]usize = undefined,
    len: usize = 0,

    fn build(items: []const model_cache_runtime.ModelMenuItem) ProviderTabs {
        var tabs: ProviderTabs = .{};
        for (0..model_cache_runtime.model_provider_filter_count) |index| {
            const filter: model_cache_runtime.ModelProviderFilter = @enumFromInt(index);
            if (!model_cache_runtime.modelProviderFilterAvailable(items, filter)) continue;
            tabs.indices[tabs.len] = index;
            tabs.len += 1;
        }
        return tabs;
    }

    fn activePosition(self: ProviderTabs, active_index: usize) usize {
        for (self.indices[0..self.len], 0..) |index, position| {
            if (index == active_index) return position;
        }
        return 0;
    }
};

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Models {d}", .{count}) catch "Models";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendProviderTab(alloc: Allocator, row: *std.ArrayList(u8), label: []const u8, active: bool) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, label);
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendProviderTabAt(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    index: usize,
    active_index: usize,
) !void {
    try appendProviderTab(alloc, row, providerTabLabel(index), index == active_index);
}

fn appendProviderOverflowMarker(alloc: Allocator, row: *std.ArrayList(u8)) !void {
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, "…");
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn providerTabLabel(index: usize) []const u8 {
    const filter: model_cache_runtime.ModelProviderFilter = @enumFromInt(index);
    return switch (filter) {
        .all => "All",
        .anthropic => "Anthropic",
        .openai => "OpenAI",
        .xai => "xAI",
        .zai => "Z.AI",
        .others => "Others",
    };
}

fn providerTabWidth(index: usize, active_index: usize) usize {
    const active_padding: usize = if (index == active_index) 2 else 0;
    return display_width.visibleWidth(providerTabLabel(index)) + active_padding;
}

fn providerRangeWidth(
    tabs: ProviderTabs,
    start: usize,
    end: usize,
    active_index: usize,
) usize {
    var width: usize = if (start > 0) 3 else 0;
    for (start..end) |position| {
        if (position > start) width += 2;
        width += providerTabWidth(tabs.indices[position], active_index);
    }
    if (end < tabs.len) width += 3;
    return width;
}

fn modelFactsColumn(projection: ModelMenuProjection, width: u16) ?usize {
    const indent_width: usize = if (width <= 2) 0 else 2;
    const content_width: usize = width;
    var facts_width: usize = 0;
    var longest_name_width: usize = 8;
    for (projection.items) |item| {
        facts_width = @max(facts_width, compactFactsWidth(item.capabilities));
        longest_name_width = @max(longest_name_width, display_width.visibleWidth(item.id));
    }
    if (facts_width == 0 or content_width < indent_width + 8 + 2 + facts_width) return null;
    const natural_column = indent_width + longest_name_width + 2;
    return @min(natural_column, content_width - facts_width);
}

fn composeTitleRow(
    alloc: Allocator,
    item: model_cache_runtime.ModelMenuItem,
    selected: bool,
    facts_column: ?usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent_width: u16 = if (width <= 2) 0 else 2;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(alloc);
    try appendCompactFacts(alloc, &facts, item.capabilities);

    const prefix_width = display_width.visibleWidthIgnoringAnsi(row.items);
    const content_width = @as(usize, width);
    const facts_start = facts_column orelse content_width;
    const show_facts = facts.items.len > 0 and facts_start >= prefix_width + 8 + 2;
    const id_budget = if (show_facts) facts_start - prefix_width - 2 else content_width -| prefix_width;
    try row_text.appendSingleLineMiddleEllipsized(alloc, &row, item.id, id_budget);
    if (selected) try row.appendSlice(alloc, ui_render.reset_style);

    if (show_facts) {
        try row_text.appendSpacesToColumn(alloc, &row, facts_start);
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, facts.items, content_width - facts_start);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn appendCompactFacts(
    alloc: Allocator,
    facts: *std.ArrayList(u8),
    capabilities: model_capabilities.Capabilities,
) !void {
    if (capabilities.context_window) |tokens| try appendTokenFact(alloc, facts, tokens, "context");
    if (capabilities.max_output_tokens) |tokens| try appendTokenFact(alloc, facts, tokens, "output");
    if (capabilities.supports_fast_mode) try appendMetadataFact(alloc, facts, "Fast");
}

fn compactFactsWidth(capabilities: model_capabilities.Capabilities) usize {
    var width: usize = 0;
    if (capabilities.context_window) |tokens| {
        if (width > 0) width += display_width.visibleWidth(" · ");
        width += tokenFactWidth(tokens, "context");
    }
    if (capabilities.max_output_tokens) |tokens| {
        if (width > 0) width += display_width.visibleWidth(" · ");
        width += tokenFactWidth(tokens, "output");
    }
    if (capabilities.supports_fast_mode) {
        if (width > 0) width += display_width.visibleWidth(" · ");
        width += display_width.visibleWidth("Fast");
    }
    return width;
}

fn appendTokenFact(alloc: Allocator, text: *std.ArrayList(u8), tokens: u32, suffix: []const u8) !void {
    var buf: [48]u8 = undefined;
    const label = try formatTokenFact(&buf, tokens, suffix);
    try appendMetadataFact(alloc, text, label);
}

fn tokenFactWidth(tokens: u32, suffix: []const u8) usize {
    var buf: [48]u8 = undefined;
    const label = formatTokenFact(&buf, tokens, suffix) catch return 0;
    return display_width.visibleWidth(label);
}

fn formatTokenFact(buf: *[48]u8, tokens: u32, suffix: []const u8) ![]const u8 {
    if (tokens >= 1_000_000 and tokens % 1_000_000 == 0) {
        return try std.fmt.bufPrint(buf, "{d}M {s}", .{ tokens / 1_000_000, suffix });
    }
    if (tokens >= 1_000 and tokens % 1_000 == 0) {
        return try std.fmt.bufPrint(buf, "{d}K {s}", .{ tokens / 1_000, suffix });
    }
    return try std.fmt.bufPrint(buf, "{d} {s}", .{ tokens, suffix });
}

fn appendMetadataFact(alloc: Allocator, text: *std.ArrayList(u8), fact: []const u8) !void {
    if (text.items.len > 0) try text.appendSlice(alloc, " · ");
    try text.appendSlice(alloc, fact);
}

fn composeStateRow(alloc: Allocator, projection: ModelMenuProjection, width: u16) !std.ArrayList(u8) {
    const text = switch (projection.load_state) {
        .loading => "Loading models…",
        .failed => retryableFailureText(projection.catalog_state.failure) orelse "Unable to load models.",
        .ready => if (projection.items.len == 0) "No models available." else "No models found.",
    };
    return composeDimmedRow(alloc, text, width);
}

fn loadedCatalogStatusText(state: model_cache_runtime.ModelMenuCatalogState) ?[]const u8 {
    if (retryableFailureText(state.failure)) |text| return text;
    if (state.private_models_hidden) {
        const reason = state.public_only_reason orelse return "Using the public model catalog.";
        return switch (reason) {
            .no_credential => "Using the public model catalog; sign in or use an API key for team-private models.",
            .fx_login_team_required => "Choose a Vercel team to load its private models.",
            .fx_login_refresh_required => "Vercel sign-in must refresh before team-private models can load.",
            .credential_refresh_failed => "Vercel sign-in refresh failed; using the public model catalog.",
            .authenticated_credential_rejected => "Your Gateway credential was rejected; using the public model catalog.",
            .chatgpt_subscription => "Codex models require an authenticated Codex catalog.",
            .grok_subscription => "Grok models require an authenticated Grok catalog.",
        };
    }
    if (state.access_level == .authenticated) {
        const source = state.source orelse return "Using an authenticated AI Gateway catalog.";
        return switch (source) {
            .fx_login => "Gateway catalog: authenticated with fx login.",
            .ai_gateway_api_key => "Note: Gateway catalog is authenticated with an API key",
            .vercel_oidc_token => "Gateway catalog: authenticated with the Vercel session.",
            .stored_key => "Gateway catalog: authenticated with the stored API key.",
            .chatgpt_subscription => "Codex catalog: authenticated with a subscription.",
            .grok_subscription => "Grok catalog: authenticated with a subscription.",
        };
    }
    return null;
}

fn retryableFailureText(failure: ?model_cache_runtime.ModelMenuCatalogState.Failure) ?[]const u8 {
    const value = failure orelse return null;
    if (!value.retryable) return null;
    return switch (value.category) {
        .rate_limited => "AI Gateway rate limited model discovery; retry /model.",
        .transport, .gateway_unavailable => "Could not reach AI Gateway; retry /model.",
        else => "Could not refresh model catalog; retry /model.",
    };
}

fn composeDimmedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClippedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}












