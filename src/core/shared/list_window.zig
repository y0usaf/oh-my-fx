const std = @import("std");

pub const default_max_picker_rows: u16 = 6;

pub const Window = struct {
    start: usize,
    end: usize,
};

pub fn centered(count: usize, selected: usize, max_rows: u16) Window {
    if (count == 0 or max_rows == 0) return .{ .start = 0, .end = 0 };
    const rows: usize = max_rows;
    if (count <= rows) return .{ .start = 0, .end = count };

    var start = if (selected >= rows / 2) selected - rows / 2 else 0;
    if (start + rows > count) start = count - rows;
    return .{ .start = start, .end = start + rows };
}

pub fn edgeFromSelection(count: usize, selected: usize, max_rows: u16) Window {
    if (count == 0 or max_rows == 0) return .{ .start = 0, .end = 0 };
    const rows: usize = max_rows;
    if (count <= rows) return .{ .start = 0, .end = count };

    const start = if (selected >= rows) selected - rows + 1 else 0;
    return .{ .start = start, .end = @min(start + rows, count) };
}

pub fn edgeFromStart(count: usize, start: usize, max_rows: u16) Window {
    if (count == 0 or max_rows == 0) return .{ .start = 0, .end = 0 };
    const rows: usize = max_rows;
    if (count <= rows) return .{ .start = 0, .end = count };

    const clamped_start = @min(start, count - rows);
    return .{ .start = clamped_start, .end = clamped_start + rows };
}

pub fn updateEdgeStart(current_start: usize, count: usize, selected: usize, max_rows: u16) usize {
    if (count == 0 or max_rows == 0) return 0;
    const rows: usize = max_rows;
    if (count <= rows) return 0;

    const clamped_selected = @min(selected, count - 1);
    var start = @min(current_start, count - rows);
    if (clamped_selected < start) {
        start = clamped_selected;
    } else if (clamped_selected >= start + rows) {
        start = clamped_selected - rows + 1;
    }
    return start;
}

