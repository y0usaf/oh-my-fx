const std = @import("std");
const frame_surface = @import("frame_surface.zig");
const paint_plan = @import("paint_plan.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

pub fn gridCellsEqual(
    left_grid: vt_emulator.Grid,
    left: vt_emulator.Cell,
    right_grid: vt_emulator.Grid,
    right: vt_emulator.Cell,
) bool {
    if (!baseCellsEqual(left.codepoint, left.width, left.style, right.codepoint, right.width, right.style)) {
        return false;
    }
    if (!resourceIdsMatchByBytes(
        left.combining_suffix_id,
        right.combining_suffix_id,
        if (left.combining_suffix_id == 0) null else left_grid.combiningSuffix(left.combining_suffix_id),
        if (right.combining_suffix_id == 0) null else right_grid.combiningSuffix(right.combining_suffix_id),
    )) {
        return false;
    }
    return resourceIdsMatchByBytes(
        left.style.hyperlink_id,
        right.style.hyperlink_id,
        if (left.style.hyperlink_id == 0) null else left_grid.hyperlinkUrl(left.style.hyperlink_id),
        if (right.style.hyperlink_id == 0) null else right_grid.hyperlinkUrl(right.style.hyperlink_id),
    );
}

pub fn gridSurfaceCellsEqual(
    grid: vt_emulator.Grid,
    grid_cell: vt_emulator.Cell,
    surface: frame_surface.FrameSurface,
    surface_cell: frame_surface.FrameCell,
) bool {
    if (!baseCellsEqual(
        grid_cell.codepoint,
        grid_cell.width,
        grid_cell.style,
        surface_cell.codepoint,
        surface_cell.width,
        surface_cell.style,
    )) {
        return false;
    }
    if (!resourceIdsMatchByBytes(
        grid_cell.combining_suffix_id,
        surface_cell.combining_suffix_id,
        if (grid_cell.combining_suffix_id == 0) null else grid.combiningSuffix(grid_cell.combining_suffix_id),
        if (surface_cell.combining_suffix_id == 0) null else surface.combiningSuffix(surface_cell.combining_suffix_id),
    )) {
        return false;
    }
    return resourceIdsMatchByBytes(
        grid_cell.style.hyperlink_id,
        surface_cell.style.hyperlink_id,
        if (grid_cell.style.hyperlink_id == 0) null else grid.hyperlinkUrl(grid_cell.style.hyperlink_id),
        if (surface_cell.style.hyperlink_id == 0) null else surface.hyperlinkUrl(surface_cell.style.hyperlink_id),
    );
}

fn baseCellsEqual(
    left_codepoint: u21,
    left_width: u8,
    left_style: vt_emulator.Style,
    right_codepoint: u21,
    right_width: u8,
    right_style: vt_emulator.Style,
) bool {
    return left_codepoint == right_codepoint and
        left_width == right_width and
        left_style.fg.eql(right_style.fg) and
        left_style.bg.eql(right_style.bg) and
        left_style.flags.eql(right_style.flags);
}

fn resourceIdsMatchByBytes(
    left_id: u32,
    right_id: u32,
    left_bytes: ?[]const u8,
    right_bytes: ?[]const u8,
) bool {
    if (left_id == 0 or right_id == 0) return left_id == right_id;
    const left = left_bytes orelse return false;
    const right = right_bytes orelse return false;
    return std.mem.eql(u8, left, right);
}
