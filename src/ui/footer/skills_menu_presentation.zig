const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const list_window = @import("../../core/shared/list_window.zig");
const ui_render = @import("../render.zig");
const picker_presentation = @import("picker_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const SkillsMenuProjection = render_input.SkillsMenuProjection;

const header_rows: u16 = 1;
const roomy_top_gap_rows: u16 = 1;
const title_rows: u16 = 1;
// Each skill is a single line now, so there is no separate description row
// or gap.
const description_rows: u16 = 0;
const item_gap_rows: u16 = 0;

const SkillsMenuLayout = struct {
    match_count: usize = 0,
    selected: usize = 0,
    visible_items: u16 = 0,
    show_header: bool = true,
    first_item_row: u16 = header_rows,
    description_row_count: u16 = 0,
    item_stride: u16 = title_rows,
    row_count: u16 = 0,

    fn build(match_count: usize, selected_index: usize, row_budget: u16) SkillsMenuLayout {
        if (row_budget == 0) return .{};

        const selected = if (match_count > 0) selected_index % match_count else 0;
        if (match_count == 0) {
            return .{
                .match_count = 0,
                .row_count = @min(row_budget, header_rows + roomy_top_gap_rows + 1),
            };
        }

        if (row_budget == 1) {
            return .{
                .match_count = match_count,
                .selected = selected,
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
        if (row_budget < header_rows + roomy_top_gap_rows + title_rows + description_rows) {
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = 1,
                .first_item_row = 1,
                .description_row_count = 1,
                .item_stride = title_rows + description_rows,
                .row_count = 3,
            };
        }

        const first_item_row = header_rows + roomy_top_gap_rows;
        const item_stride = title_rows + description_rows + item_gap_rows;
        const item_budget = (row_budget - first_item_row +| item_gap_rows) / item_stride;
        const visible_items: u16 = @intCast(@min(match_count, @max(item_budget, 1)));
        return .{
            .match_count = match_count,
            .selected = selected,
            .visible_items = visible_items,
            .first_item_row = first_item_row,
            .description_row_count = description_rows,
            .item_stride = item_stride,
            .row_count = first_item_row + visible_items * item_stride - item_gap_rows,
        };
    }

    fn buildInline(match_count: usize, selected_index: usize, row_budget: u16) SkillsMenuLayout {
        if (row_budget == 0) return .{};

        const selected = if (match_count > 0) selected_index % match_count else 0;
        if (match_count == 0) {
            if (row_budget < header_rows + roomy_top_gap_rows + 1) {
                return .{
                    .show_header = false,
                    .first_item_row = 0,
                    .row_count = 1,
                };
            }
            return .{
                .first_item_row = header_rows + roomy_top_gap_rows,
                .row_count = header_rows + roomy_top_gap_rows + 1,
            };
        }

        if (row_budget <= 2) {
            const visible_items: u16 = @intCast(@min(match_count, row_budget));
            return .{
                .match_count = match_count,
                .selected = selected,
                .visible_items = visible_items,
                .show_header = false,
                .first_item_row = 0,
                .row_count = visible_items,
            };
        }

        const first_item_row = header_rows + roomy_top_gap_rows;
        const visible_items: u16 = @intCast(@min(match_count, row_budget - first_item_row));
        return .{
            .match_count = match_count,
            .selected = selected,
            .visible_items = visible_items,
            .first_item_row = first_item_row,
            .row_count = first_item_row + visible_items,
        };
    }
};

pub const PreparedSkillsMenu = struct {
    layout: SkillsMenuLayout,
    source_filter: skill_runtime.SkillMenuSourceFilter,
    catalog_empty: bool,
    window_start: usize,
    visible_skills: []*const skill_runtime.Skill,
    inline_name_column_width: ?usize,
    scope_column_width: usize,

    pub fn deinit(self: *PreparedSkillsMenu, alloc: Allocator) void {
        if (self.visible_skills.len > 0) alloc.free(self.visible_skills);
        self.* = undefined;
    }

    pub fn rowCount(self: PreparedSkillsMenu) u16 {
        return self.layout.row_count;
    }
};

pub fn prepareSkillsMenu(
    alloc: Allocator,
    projection: SkillsMenuProjection,
    row_budget: u16,
) !PreparedSkillsMenu {
    const match_count = visibleSkillCount(projection);
    const layout = SkillsMenuLayout.build(match_count, projection.selected_index, row_budget);
    return prepareSkillsMenuWithLayout(alloc, projection, layout, false);
}

pub fn prepareInlineSkillsMenu(
    alloc: Allocator,
    projection: SkillsMenuProjection,
    row_budget: u16,
) !PreparedSkillsMenu {
    const match_count = visibleSkillCount(projection);
    const layout = SkillsMenuLayout.buildInline(match_count, projection.selected_index, row_budget);
    return prepareSkillsMenuWithLayout(alloc, projection, layout, true);
}

fn prepareSkillsMenuWithLayout(
    alloc: Allocator,
    projection: SkillsMenuProjection,
    layout: SkillsMenuLayout,
    inline_mode: bool,
) !PreparedSkillsMenu {
    const window_start = list_window.updateEdgeStart(
        projection.window_start,
        layout.match_count,
        layout.selected,
        layout.visible_items,
    );

    var visible_skills: []*const skill_runtime.Skill = &.{};
    errdefer if (visible_skills.len > 0) alloc.free(visible_skills);
    if (layout.visible_items > 0) {
        visible_skills = try alloc.alloc(*const skill_runtime.Skill, layout.visible_items);
        const written = skill_runtime.fillSkillMenuRangeAtQuery(
            projection.items,
            projection.source_filter,
            projection.query,
            window_start,
            visible_skills,
        );
        if (written != visible_skills.len) return error.InconsistentSkillsMenuProjection;
    }

    return .{
        .layout = layout,
        .source_filter = projection.source_filter,
        .catalog_empty = projection.items.len == 0,
        .window_start = window_start,
        .visible_skills = visible_skills,
        .inline_name_column_width = if (inline_mode) matching_name_column_width(projection) else null,
        .scope_column_width = scopeColumnWidth(visible_skills),
    };
}

pub fn visibleNavigationRowsForBudget(
    projection: SkillsMenuProjection,
    row_budget: u16,
) u16 {
    return SkillsMenuLayout.build(
        visibleSkillCount(projection),
        projection.selected_index,
        row_budget,
    ).visible_items;
}

pub fn inlineVisibleNavigationRowsForBudget(
    projection: SkillsMenuProjection,
    row_budget: u16,
) u16 {
    return SkillsMenuLayout.buildInline(
        visibleSkillCount(projection),
        projection.selected_index,
        row_budget,
    ).visible_items;
}

pub fn inlineMenuRowCount(
    projection: SkillsMenuProjection,
    row_budget: u16,
) u16 {
    return SkillsMenuLayout.buildInline(
        visibleSkillCount(projection),
        projection.selected_index,
        row_budget,
    ).row_count;
}

pub fn composeSkillsMenuRow(
    alloc: Allocator,
    prepared: PreparedSkillsMenu,
    row_index: u16,
    width: u16,
) !std.ArrayList(u8) {
    const row: std.ArrayList(u8) = .empty;
    if (width == 0 or row_index >= prepared.layout.row_count) return row;
    if (prepared.layout.show_header and row_index == 0) {
        return composeHeaderRow(
            alloc,
            prepared.layout.match_count,
            prepared.source_filter,
            width,
        );
    }

    const layout = prepared.layout;
    if (layout.match_count == 0) {
        if (row_index < layout.row_count -| 1) return row;
        return composeEmptyRow(alloc, prepared.catalog_empty, prepared.source_filter, width);
    }
    if (row_index < layout.first_item_row) return row;

    const body_offset = row_index - layout.first_item_row;
    const visible_offset = body_offset / layout.item_stride;
    if (visible_offset >= layout.visible_items) return row;

    if (visible_offset >= prepared.visible_skills.len) return row;
    const display_index = prepared.window_start + visible_offset;
    const skill = prepared.visible_skills[visible_offset].*;

    // item_stride is 1: every skill is a single row.
    return composeSkillTitleRow(
        alloc,
        skill,
        display_index == layout.selected,
        prepared.inline_name_column_width,
        prepared.scope_column_width,
        width,
    );
}

fn matching_name_column_width(projection: SkillsMenuProjection) usize {
    var col: usize = 0;
    for (projection.items) |skill| {
        if (!skill_runtime.skillSourceMatchesFilter(skill.source, projection.source_filter)) continue;
        if (!skill_runtime.skill_matches_menu_query(skill, projection.query)) continue;
        col = @max(col, display_width.visibleWidth(skill.name));
    }
    return col;
}

// Widest source-scope label across the visible skills, so the scope column
// lines up vertically instead of drifting with each row's own width.
fn scopeColumnWidth(visible_skills: []const *const skill_runtime.Skill) usize {
    var col: usize = 0;
    for (visible_skills) |skill| {
        col = @max(col, display_width.visibleWidth(skillSourceScopeLabel(skill.source)));
    }
    return col;
}

fn composeHeaderRow(
    alloc: Allocator,
    match_count: usize,
    source_filter: skill_runtime.SkillMenuSourceFilter,
    width: u16,
) !std.ArrayList(u8) {
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(alloc);
    try appendHeaderTitle(alloc, &wide, match_count);

    for (skill_runtime.skill_menu_source_filters) |filter| {
        try wide.appendSlice(alloc, "  ");
        try appendSourceTab(alloc, &wide, filter, filter == source_filter);
    }

    if (display_width.visibleWidthIgnoringAnsi(wide.items) <= width) {
        return try cloneClippedRow(alloc, wide.items, width);
    }

    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try appendHeaderTitle(alloc, &compact, match_count);
    try compact.appendSlice(alloc, "    ");
    try compact.appendSlice(alloc, ui_render.dim_style);
    try compact.appendSlice(alloc, "Source ");
    try compact.appendSlice(alloc, ui_render.reset_style);
    try appendSourceTab(alloc, &compact, source_filter, true);
    if (display_width.visibleWidthIgnoringAnsi(compact.items) <= width) {
        return try cloneClippedRow(alloc, compact.items, width);
    }

    compact.clearRetainingCapacity();
    try appendHeaderTitle(alloc, &compact, match_count);
    try compact.appendSlice(alloc, "  ");
    try appendSourceTab(alloc, &compact, source_filter, true);
    if (display_width.visibleWidthIgnoringAnsi(compact.items) <= width) {
        return try cloneClippedRow(alloc, compact.items, width);
    }

    compact.clearRetainingCapacity();
    try appendSourceTab(alloc, &compact, source_filter, true);
    return try cloneClippedRow(alloc, compact.items, width);
}

fn appendHeaderTitle(alloc: Allocator, row: *std.ArrayList(u8), count: usize) !void {
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    var buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Skills {d}", .{count}) catch "Skills";
    try row.appendSlice(alloc, title);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn appendSourceTab(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    filter: skill_runtime.SkillMenuSourceFilter,
    active: bool,
) !void {
    try row.appendSlice(alloc, if (active) ui_render.selected_completion_style else ui_render.dim_style);
    if (active) try row.append(alloc, '[');
    try row.appendSlice(alloc, skill_runtime.skillMenuFilterLabel(filter));
    if (active) try row.append(alloc, ']');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn composeSkillTitleRow(
    alloc: Allocator,
    skill: skill_runtime.Skill,
    selected: bool,
    inline_name_width: ?usize,
    scope_col: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);

    const indent_width: usize = if (width <= 4) 0 else 2;
    if (indent_width > 0) try row.appendSlice(alloc, "  ");

    const scope = skillSourceScopeLabel(skill.source);
    const scope_width = @max(scope_col, display_width.visibleWidth(scope));
    const prefix_width = display_width.visibleWidthIgnoringAnsi(row.items);
    const content_width: usize = @as(usize, width) -| 1;
    const show_scope = if (inline_name_width) |name_col|
        scope_width > 0 and content_width >= prefix_width + name_col + picker_presentation.inline_picker_column_gap_width + scope_width
    else
        scope_width > 0 and content_width >= prefix_width + 8 + 2 + scope_width;
    const name_budget = if (!show_scope)
        @as(usize, width) -| prefix_width
    else if (inline_name_width) |name_col|
        name_col
    else
        content_width - prefix_width - scope_width - 2;

    // Selection by brightness: bold bright white when selected, dim gray
    // otherwise, applied to the whole row (name and scope). No marker glyph.
    const style = if (selected) ui_render.selected_completion_style else ui_render.dim_style;
    try row.appendSlice(alloc, style);
    try row_text.appendSingleLineEllipsized(alloc, &row, skill.name, name_budget);

    if (show_scope) {
        const scope_start = if (inline_name_width) |name_col|
            prefix_width + name_col + picker_presentation.inline_picker_column_gap_width
        else
            content_width - scope_width;
        try row_text.appendSpacesToColumn(alloc, &row, scope_start);
        try row.appendSlice(alloc, scope);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeEmptyRow(
    alloc: Allocator,
    catalog_empty: bool,
    source_filter: skill_runtime.SkillMenuSourceFilter,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    const text = if (catalog_empty)
        "No skills available."
    else if (source_filter == .all)
        "No skills found."
    else blk: {
        var buf: [96]u8 = undefined;
        break :blk std.fmt.bufPrint(
            &buf,
            "No {s} skills found.",
            .{skill_runtime.skillMenuFilterLabel(source_filter)},
        ) catch "No skills found.";
    };
    try row_text.appendSingleLineEllipsized(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn skillSourceScopeLabel(source: skill_runtime.SkillSource) []const u8 {
    return switch (source) {
        .global_fx => "fx · Global",
        .workspace_fx => "fx · Workspace",
        .workspace_shared => "fx · Workspace",
        .workspace_opencode => "OpenCode · Workspace",
        .global_opencode => "OpenCode · Global",
        .workspace_codex => "Codex · Workspace",
        .global_codex => "Codex · Global",
        .workspace_claude => "Claude · Workspace",
        .global_claude => "Claude · Global",
        .workspace_agents => "Agents · Workspace",
        .global_agents => "Agents · Global",
        .workspace_claw => "Claw · Workspace",
        .global_claw => "Claw · Global",
    };
}

fn cloneClippedRow(alloc: Allocator, text: []const u8, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, text, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn visibleSkillCount(projection: SkillsMenuProjection) usize {
    return skill_runtime.skillMenuFilterQueryCount(projection.items, projection.source_filter, projection.query);
}
