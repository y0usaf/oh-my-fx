const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const settings_catalog = @import("../../core/config/settings_catalog.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const ui_render = @import("../render.zig");

const Allocator = std.mem.Allocator;
const AppearanceMenuProjection = render_input.AppearanceMenuProjection;

pub const row_count: u16 = 4;

pub noinline fn composeAppearanceMenuRow(
    alloc: Allocator,
    projection: AppearanceMenuProjection,
    row_index: u16,
    visible_rows: u16,
    width: u16,
) !std.ArrayList(u8) {
    const empty: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= visible_rows) return empty;
    if (visible_rows == 1) {
        return composeSettingRow(
            alloc,
            projection,
            selectedSetting(projection),
            true,
            width,
        );
    }
    if (row_index == 0) return composeStyledRow(alloc, "Appearance", width, ui_render.selected_completion_style);
    if (visible_rows >= row_count and row_index == 1) return empty;

    const setting_row = row_index - if (visible_rows >= row_count) @as(u16, 2) else 1;
    return switch (setting_row) {
        0 => composeSettingRow(alloc, projection, .input_appearance, selectedSetting(projection) == .input_appearance, width),
        1 => composeSettingRow(alloc, projection, .maxxing_mode, selectedSetting(projection) == .maxxing_mode, width),
        else => empty,
    };
}

fn selectedSetting(projection: AppearanceMenuProjection) settings_catalog.SettingId {
    return if (projection.selected_index % settings_catalog.appearanceChoiceCount() < 2)
        .input_appearance
    else
        .maxxing_mode;
}

fn composeStyledRow(
    alloc: Allocator,
    text: []const u8,
    width: u16,
    style: []const u8,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSettingRow(
    alloc: Allocator,
    projection: AppearanceMenuProjection,
    setting: settings_catalog.SettingId,
    selected: bool,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const indent: usize = if (width <= 2) 0 else 2;
    if (indent > 0) try row.appendSlice(alloc, "  ");
    try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
    const value_col = valueColumn(projection.snapshot, setting, width);
    try row_text.appendSingleLineEllipsized(
        alloc,
        &row,
        settings_catalog.specFor(setting).label,
        value_col -| indent,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    try row_text.appendSpacesToColumn(alloc, &row, value_col);

    const option_count = settings_catalog.optionCount(&projection.snapshot, setting);
    for (0..option_count) |index| {
        const before_option = display_width.visibleWidthIgnoringAnsi(row.items);
        if (before_option >= width) break;
        if (index > 0) try row.appendNTimes(alloc, ' ', @min(@as(usize, 2), @as(usize, width) - before_option));
        const option = settings_catalog.optionAt(&projection.snapshot, setting, index) orelse continue;
        const current = std.ascii.eqlIgnoreCase(option, projection.snapshot.value(setting));
        try row.appendSlice(alloc, if (current) ui_render.selected_completion_style else ui_render.dim_style);
        const used = display_width.visibleWidthIgnoringAnsi(row.items);
        try row_text.appendSingleLineEllipsized(alloc, &row, option, @as(usize, width) -| used);
        try row.appendSlice(alloc, ui_render.reset_style);
        if (display_width.visibleWidthIgnoringAnsi(row.items) >= width) break;
    }
    return row;
}

fn valueColumn(snapshot: settings_catalog.Snapshot, setting: settings_catalog.SettingId, width: u16) usize {
    const total_width: usize = width;
    const right_column_start = total_width * 2 / 3;
    const right_column_width = total_width - right_column_start;
    var options_width: usize = 0;
    const option_count = settings_catalog.optionCount(&snapshot, setting);
    for (0..option_count) |index| {
        if (index > 0) options_width += 2;
        const option = settings_catalog.optionAt(&snapshot, setting, index) orelse continue;
        options_width += display_width.visibleWidth(option);
    }
    const block_width = @min(options_width, right_column_width);
    return right_column_start + (right_column_width - block_width) / 2;
}

test "appearance menu matches settings rows without markers or descriptions" {
    const projection: AppearanceMenuProjection = .{
        .active = true,
        .selected_index = 0,
        .snapshot = .{ .input_appearance = "tint", .maxxing_mode = "minimal" },
    };

    var header = try composeAppearanceMenuRow(std.testing.allocator, projection, 0, row_count, 80);
    defer header.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, header.items, "Appearance") != null);

    var input = try composeAppearanceMenuRow(std.testing.allocator, projection, 2, row_count, 80);
    defer input.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, input.items, "Input appearance") != null);
    try std.testing.expect(std.mem.find(u8, input.items, "lines") != null);
    try std.testing.expect(std.mem.find(u8, input.items, "tint") != null);
    try std.testing.expect(std.mem.find(u8, input.items, "✓") == null);
    try std.testing.expect(std.mem.find(u8, input.items, "❯") == null);

    var presentation = try composeAppearanceMenuRow(std.testing.allocator, projection, 3, row_count, 80);
    defer presentation.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, presentation.items, "Maxxing mode") != null);
    try std.testing.expect(std.mem.find(u8, presentation.items, "minimal") != null);
    try std.testing.expect(std.mem.find(u8, presentation.items, "legacy") != null);
}

test "appearance menu rows remain single-line and width safe" {
    const projection: AppearanceMenuProjection = .{ .active = true };
    for ([_]u16{ 1, 4, 18 }) |width| {
        var row = try composeAppearanceMenuRow(std.testing.allocator, projection, 2, row_count, width);
        defer row.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
    }
}
