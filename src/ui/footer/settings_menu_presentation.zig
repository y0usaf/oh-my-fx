const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const SettingsMenuProjection = render_input.SettingsMenuProjection;
const roomy_header_rows: u16 = 2;
pub const max_inline_rows: u16 = roomy_header_rows + std.meta.fields(settings_catalog.SettingId).len;

fn inlineModelRowCount(projection: SettingsMenuProjection) u16 {
    if (!projection.models.active) return 0;
    if (projection.models.load_state != .ready or projection.models.filteredItemCount() == 0) return 1;
    return @intCast(@min(projection.models.filteredItemCount(), 6));
}

const BodyRow = union(enum) {
    none,
    item: struct {
        item: settings_catalog.Item,
        selected: bool,
    },
    model: usize,
};

const Layout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    first_item: usize = 0,
    visible_items: u16 = 0,
    body_start_row: u16 = 0,
    row_count: u16 = 0,
    model_only: bool = false,
};

pub fn menuRowCount(projection: SettingsMenuProjection, width: u16, max_rows: u16) u16 {
    return buildBrowseLayout(projection, width, max_rows).row_count;
}

pub fn visibleNavigationItemsForBudget(
    projection: SettingsMenuProjection,
    width: u16,
    row_budget: u16,
) u16 {
    return @max(buildBrowseLayout(projection, width, row_budget).visible_items, 1);
}

pub fn visibleModelItemsForBudget(
    projection: SettingsMenuProjection,
    width: u16,
    row_budget: u16,
) u16 {
    const layout = buildBrowseLayout(projection, width, row_budget);
    var visible: u16 = 0;
    var row_index = layout.body_start_row;
    while (row_index < layout.row_count) : (row_index += 1) {
        switch (browseBodyRowAt(
            projection,
            layout,
            row_index - layout.body_start_row,
        )) {
            .model => visible += 1,
            else => {},
        }
    }
    return visible;
}

pub fn composeSettingsMenuRow(
    alloc: Allocator,
    projection: SettingsMenuProjection,
    row_index: u16,
    width: u16,
    row_count: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= row_count) return empty;

    const layout = buildBrowseLayout(projection, width, row_count);
    if (row_index < layout.body_start_row) {
        if (row_index == 0) return composeBrowseHeader(alloc, projection, width);
        return empty;
    }
    if (layout.match_count == 0) return composeEmptyRow(alloc, width);
    const value_col = valueColumn(projection, width);
    return switch (browseBodyRowAt(projection, layout, row_index - layout.body_start_row)) {
        .none => empty,
        .item => |body| composeItemRow(alloc, projection.snapshot, body.item, body.selected, width, value_col),
        .model => |display_index| composeModelRow(alloc, projection, display_index, width, value_col),
    };
}

fn buildBrowseLayout(projection: SettingsMenuProjection, width: u16, max_rows: u16) Layout {
    if (max_rows == 0) return .{};
    const match_count = projection.filteredItemCount();
    const selected = if (match_count == 0) 0 else projection.selected_index % match_count;
    const show_header = max_rows > 2;
    const body_start_row: u16 = if (show_header) roomy_header_rows else 0;
    if (match_count == 0) {
        return .{
            .body_start_row = body_start_row,
            .row_count = @min(max_rows, body_start_row + 1),
        };
    }

    const body_budget = max_rows - body_start_row;
    var first_item = if (projection.models.active)
        selected
    else
        @min(projection.window_start, match_count - 1);
    if (selected < first_item) first_item = selected;
    var body = measureBrowseBody(projection, width, first_item, body_budget);
    while (selected >= first_item + body.visible_items and first_item < selected) {
        first_item += 1;
        body = measureBrowseBody(projection, width, first_item, body_budget);
    }
    if (body.visible_items == 0) {
        first_item = selected;
        body = measureBrowseBody(projection, width, first_item, body_budget);
    }
    return .{
        .match_count = match_count,
        .selected = selected,
        .first_item = first_item,
        .visible_items = body.visible_items,
        .body_start_row = body_start_row,
        .model_only = projection.models.active and body_budget == 1,
        .row_count = body_start_row + body.rows,
    };
}

const Measurement = struct {
    visible_items: u16 = 0,
    rows: u16 = 0,
};

fn measureBrowseBody(projection: SettingsMenuProjection, width: u16, first_item: usize, row_budget: u16) Measurement {
    var result: Measurement = .{};
    _ = width;
    var display_index = first_item;
    while (projection.itemAt(display_index)) |item| : (display_index += 1) {
        const required: u16 = 1;
        if (result.rows + required > row_budget) break;
        const model_rows: u16 = if (item.id == .model)
            @min(inlineModelRowCount(projection), row_budget - result.rows - required)
        else
            0;
        result.rows += required + model_rows;
        result.visible_items += 1;
    }
    if (projection.models.active and row_budget == 1 and result.visible_items > 0) {
        result.rows = 1;
    }
    return result;
}

fn browseBodyRowAt(projection: SettingsMenuProjection, layout: Layout, target: u16) BodyRow {
    if (layout.model_only) return if (target == 0) .{ .model = 0 } else .none;
    var row: u16 = 0;
    var offset: usize = 0;
    while (offset < layout.visible_items) : (offset += 1) {
        const display_index = layout.first_item + offset;
        const item = projection.itemAt(display_index) orelse return .none;
        if (row == target) return .{ .item = .{
            .item = item,
            .selected = display_index == layout.selected,
        } };
        row += 1;
        if (item.id == .model and projection.models.active) {
            const model_count = inlineModelRowCount(projection);
            var model_offset: u16 = 0;
            while (model_offset < model_count) : (model_offset += 1) {
                if (row == target) return .{ .model = model_offset };
                row += 1;
            }
        }
    }
    return .none;
}

fn composeBrowseHeader(alloc: Allocator, projection: SettingsMenuProjection, width: u16) !std.ArrayList(u8) {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try appendHeaderTitle(alloc, &wide, projection.filteredItemCount());
    inline for (std.meta.fields(settings_catalog.Category)) |field| {
        const category: settings_catalog.Category = @enumFromInt(field.value);
        try wide.appendSlice(alloc, "  ");
        try appendCategoryTab(alloc, &wide, category, category == projection.category);
    }
    if (display_width.visibleWidthIgnoringAnsi(wide.items) <= width) {
        return cloneClipped(alloc, wide.items, width);
    }

    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try appendHeaderTitle(alloc, &compact, projection.filteredItemCount());
    try compact.appendSlice(alloc, "  ");
    try appendCategoryTab(alloc, &compact, projection.category, true);
    if (display_width.visibleWidthIgnoringAnsi(compact.items) <= width) {
        return cloneClipped(alloc, compact.items, width);
    }

    compact.clearRetainingCapacity();
    try appendCategoryTab(alloc, &compact, projection.category, true);
    return cloneClipped(alloc, compact.items, width);
}

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Settings {d}", .{count}) catch "Settings";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendCategoryTab(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    category: settings_catalog.Category,
    active: bool,
) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, category.label());
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn composeItemRow(
    alloc: Allocator,
    snapshot: settings_catalog.Snapshot,
    item: settings_catalog.Item,
    selected: bool,
    width: u16,
    value_col: usize,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent: usize = if (width <= 2) 0 else 2;
    if (indent > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        item.label,
        value_col -| indent,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, value_col);

    const option_count = settings_catalog.optionCount(&snapshot, item.id);
    if (option_count == 0) {
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        try row_text.appendSingleLineEllipsized(alloc, &row, item.value, @as(usize, width) -| value_col);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    var option_index: usize = 0;
    while (option_index < option_count) : (option_index += 1) {
        if (option_index > 0) try row.appendSlice(alloc, "  ");
        const option = settings_catalog.optionAt(&snapshot, item.id, option_index) orelse continue;
        const current = std.ascii.eqlIgnoreCase(option, item.value);
        try row.appendSlice(alloc, if (current) ui_render.selected_completion_style else ui_render.dim_style);
        const used = display_width.visibleWidthIgnoringAnsi(row.items);
        try row_text.appendSingleLineEllipsized(alloc, &row, option, @as(usize, width) -| used);
        try row.appendSlice(alloc, ui_render.reset_style);
        if (display_width.visibleWidthIgnoringAnsi(row.items) >= width) break;
    }
    return row;
}

fn composeModelRow(
    alloc: Allocator,
    projection: SettingsMenuProjection,
    visible_offset: usize,
    width: u16,
    value_col: usize,
) !std.ArrayList(u8) {
    if (projection.models.load_state != .ready or projection.models.filteredItemCount() == 0) {
        const label = switch (projection.models.load_state) {
            .loading => "Loading models…",
            .ready => "No models found",
            .failed => "Models unavailable",
        };
        return composeStyledText(alloc, label, width, ui_render.dim_style, 4);
    }

    const match_count = projection.models.filteredItemCount();
    const selected = projection.models.selected_index % match_count;
    const visible_count: usize = @min(match_count, 6);
    var window_start = projection.models.window_start;
    if (selected < window_start) window_start = selected;
    if (selected >= window_start + visible_count) window_start = selected + 1 - visible_count;
    window_start = @min(window_start, match_count - visible_count);
    const display_index = window_start + visible_offset;
    const model = projection.models.itemAt(display_index) orelse return .empty;

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendSpacesToColumn(alloc, &row, value_col);
    try row.appendSlice(alloc, if (display_index == selected) ui_render.selected_completion_style else ui_render.dim_style);
    try row_text.appendSingleLineEllipsized(alloc, &row, model.id, @as(usize, width) -| value_col);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn valueColumn(projection: SettingsMenuProjection, width: u16) usize {
    const indent: usize = if (width <= 2) 0 else 2;
    var widest_label_width: usize = 0;
    var display_index: usize = 0;
    while (projection.itemAt(display_index)) |item| : (display_index += 1) {
        widest_label_width = @max(widest_label_width, display_width.visibleWidth(item.label));
    }
    return @min(indent + widest_label_width + picker_presentation.inline_picker_column_gap_width, width);
}

fn composeEmptyRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    return composeStyledText(alloc, "No settings found.", width, ui_render.dim_style, 0);
}

fn composeStyledText(alloc: Allocator, text: []const u8, width: u16, style: []const u8, indent: usize) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var spaces = indent;
    while (spaces > 0 and row.items.len < width) : (spaces -= 1) try row.append(alloc, ' ');
    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, text, @as(usize, width) -| indent);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn cloneClipped(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    return row;
}

const test_snapshot: settings_catalog.Snapshot = .{
    .model = "zai/glm-5.2",
    .effort = "default",
    .fast_mode = true,
    .permission_mode = "ask",
    .statusline_context = true,
    .statusline_session = false,
    .statusline_workspace = false,
    .startup_scrollback = true,
    .prompt_history = true,
    .sound_level = "on",
};
