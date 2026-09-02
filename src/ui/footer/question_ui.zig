const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const ui_render = @import("../render.zig");
const question_freeform_layout = @import("question_freeform_layout.zig");

const Allocator = std.mem.Allocator;

pub fn questionPanelRowsForLayout(
    _: Allocator,
    projection: question_prompt.Projection,
    cols: u16,
) !u16 {
    return questionPanelRowCount(projection, cols);
}

fn questionPanelRowCount(
    projection: question_prompt.Projection,
    row_budget: usize,
) u16 {
    const entry = projection.current_entry orelse return 1;
    const question_width = questionTextWidth(row_budget);
    var count: usize = 2 + wrappedTextLineCount(entry.question, question_width, question_width);
    for (entry.options, 0..) |opt, index| {
        count +|= questionOptionLineCount(entry, opt, index, row_budget);
    }
    return @intCast(@min(count, std.math.maxInt(u16)));
}

pub fn nextPanelLine(text: []const u8, start: *usize) []const u8 {
    if (start.* >= text.len) return "";
    var line_end = start.*;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    const line = text[start.*..line_end];
    start.* = if (line_end < text.len) line_end + 1 else text.len;
    return line;
}

pub fn composeQuestionPanelText(
    alloc: Allocator,
    projection: question_prompt.Projection,
    cols: u16,
) ![]u8 {
    const row_budget: usize = cols;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const entry = projection.current_entry orelse {
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    };

    // The question is its own header; batch progress lives in the hint row.
    try writeQuestionPanelQuestion(&out.writer, entry.question, row_budget);
    try out.writer.writeByte('\n');

    for (entry.options, 0..) |opt, j| {
        try writeQuestionPanelOptionLine(&out.writer, entry, opt, j, row_budget);
    }

    try out.writer.writeByte('\n');

    return out.toOwnedSlice();
}

fn writeQuestionPanelQuestion(
    writer: *std.Io.Writer,
    question: []const u8,
    row_budget: usize,
) !void {
    const content_width = questionTextWidth(row_budget);
    var start: usize = 0;
    var first = true;
    while (first or start < question.len) {
        const line = if (question.len == 0)
            WrappedTextLine{ .content_end = 0, .next_start = 0 }
        else
            nextWrappedTextLine(question, start, content_width);
        try writer.writeAll("  ");
        try writer.writeAll(ui_render.bold_style);
        try writer.writeAll(question[start..line.content_end]);
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
        if (question.len == 0) break;
        first = false;
        start = line.next_start;
    }
}

fn questionTextWidth(row_budget: usize) usize {
    return @max(row_budget -| 2, 1);
}

fn writeQuestionPanelOptionLine(
    writer: *std.Io.Writer,
    entry: question_prompt.EntryProjection,
    opt: question_prompt.OwnedQuestionOption,
    index: usize,
    row_budget: usize,
) !void {
    const selected = index == entry.choice_index;
    // No caret: selection reads purely from the white-vs-gray contrast.
    const option_style = if (selected) ui_render.selected_completion_style else ui_render.dim_style;

    var ordinal_buf: [16]u8 = undefined;
    const ordinal = std.fmt.bufPrint(&ordinal_buf, "{d}) ", .{index + 1}) catch "";
    const prefix_width = question_freeform_layout.optionPrefixWidth(index);

    if (selected and opt.is_freeform_slot) {
        try writeSelectedFreeformOptionLines(writer, entry, ordinal, prefix_width, row_budget);
        return;
    }

    const label = questionOptionLabel(entry, opt);
    const description = opt.description orelse "";
    const has_description = description.len > 0;
    const description_col = if (has_description) questionDescriptionColumn(row_budget) else 0;
    const widths = questionOptionLabelWidths(index, row_budget, has_description);

    if (description_col > 0) {
        const description_width = @max(row_budget -| description_col, 1);
        const description_indent = description_col - 1;
        var label_start: usize = 0;
        var description_start: usize = 0;
        var row_index: usize = 0;
        while (row_index == 0 or label_start < label.len or description_start < description.len) : (row_index += 1) {
            const label_available = row_index == 0 or label_start < label.len;
            const label_line = if (!label_available or label.len == 0)
                WrappedTextLine{ .content_end = label_start, .next_start = label_start }
            else
                nextWrappedTextLine(label, label_start, if (row_index == 0) widths.first else widths.continuation);
            const description_available = description_start < description.len;
            const description_line = if (description_available)
                nextWrappedTextLine(description, description_start, description_width)
            else
                WrappedTextLine{ .content_end = description_start, .next_start = description_start };

            if (row_index == 0) {
                try writer.writeAll(option_style);
                try writer.writeAll(question_freeform_layout.option_row_indent);
                try writer.writeAll(ordinal);
            } else {
                try writer.splatByteAll(' ', prefix_width);
                try writer.writeAll(option_style);
            }
            if (label_available) try writer.writeAll(label[label_start..label_line.content_end]);
            try writer.writeAll(ui_render.reset_style);

            if (description_available) {
                const visible = prefix_width + if (label_available)
                    display_width.visibleWidth(label[label_start..label_line.content_end])
                else
                    0;
                if (visible < description_indent) {
                    try writer.splatByteAll(' ', description_indent - visible);
                } else {
                    try writer.writeByte(' ');
                }
                try writer.writeAll(ui_render.dim_style);
                try writer.writeAll(description[description_start..description_line.content_end]);
                try writer.writeAll(ui_render.reset_style);
            }
            try writer.writeByte('\n');

            if (label_available) label_start = label_line.next_start;
            if (description_available) description_start = description_line.next_start;
        }
        return;
    }

    var start: usize = 0;
    var first = true;
    while (first or start < label.len) {
        const line = if (label.len == 0)
            WrappedTextLine{ .content_end = 0, .next_start = 0 }
        else
            nextWrappedTextLine(label, start, if (first) widths.first else widths.continuation);

        if (first) {
            try writer.writeAll(option_style);
            try writer.writeAll(question_freeform_layout.option_row_indent);
            try writer.writeAll(ordinal);
        } else {
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(option_style);
        }
        try writer.writeAll(label[start..line.content_end]);
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
        if (label.len == 0) break;
        first = false;
        start = line.next_start;
    }

    if (has_description) {
        const description_width = @max(row_budget -| prefix_width, 1);
        var description_start: usize = 0;
        while (description_start < description.len) {
            const line = nextWrappedTextLine(description, description_start, description_width);
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(ui_render.dim_style);
            try writer.writeAll(description[description_start..line.content_end]);
            try writer.writeAll(ui_render.reset_style);
            try writer.writeByte('\n');
            description_start = line.next_start;
        }
    }
}

fn questionOptionLineCount(
    entry: question_prompt.EntryProjection,
    opt: question_prompt.OwnedQuestionOption,
    index: usize,
    row_budget: usize,
) usize {
    if (index == entry.choice_index and opt.is_freeform_slot) {
        return question_freeform_layout.lineCount(
            entry.freeform_buffer,
            entry.freeform_cursor,
            question_freeform_layout.contentWidth(entry.choice_index, row_budget),
        );
    }

    const description = opt.description orelse "";
    const has_description = description.len > 0;
    const widths = questionOptionLabelWidths(index, row_budget, has_description);
    const label_lines = wrappedTextLineCount(questionOptionLabel(entry, opt), widths.first, widths.continuation);
    if (!has_description) return label_lines;

    const description_col = questionDescriptionColumn(row_budget);
    const description_width = if (description_col > 0)
        @max(row_budget -| description_col, 1)
    else
        @max(row_budget -| question_freeform_layout.optionPrefixWidth(index), 1);
    const description_lines = wrappedTextLineCount(description, description_width, description_width);
    return if (description_col > 0)
        @max(label_lines, description_lines)
    else
        label_lines +| description_lines;
}

fn questionOptionLabel(
    entry: question_prompt.EntryProjection,
    opt: question_prompt.OwnedQuestionOption,
) []const u8 {
    if (!opt.is_freeform_slot) return opt.label;
    return if (entry.freeform_buffer.len == 0)
        question_prompt.freeform_option_label
    else
        entry.freeform_buffer;
}

const QuestionOptionLabelWidths = struct {
    first: usize,
    continuation: usize,
};

fn questionOptionLabelWidths(
    index: usize,
    row_budget: usize,
    has_description: bool,
) QuestionOptionLabelWidths {
    const prefix_width = question_freeform_layout.optionPrefixWidth(index);
    const description_col = if (has_description) questionDescriptionColumn(row_budget) else 0;
    const label_end = if (description_col > prefix_width + 2) description_col - 2 else row_budget;
    const first = @max(label_end -| prefix_width, 1);
    return .{
        .first = first,
        .continuation = if (description_col > 0)
            first
        else
            @max(row_budget -| prefix_width, 1),
    };
}

const WrappedTextLine = struct {
    content_end: usize,
    next_start: usize,
};

fn wrappedTextLineCount(text: []const u8, first_width: usize, continuation_width: usize) usize {
    if (text.len == 0) return 1;

    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len) : (count += 1) {
        const line = nextWrappedTextLine(text, start, if (count == 0) first_width else continuation_width);
        start = line.next_start;
    }
    return @max(count, 1);
}

fn nextWrappedTextLine(text: []const u8, start: usize, content_width: usize) WrappedTextLine {
    if (start >= text.len) return .{ .content_end = text.len, .next_start = text.len };

    const newline = std.mem.findScalar(u8, text[start..], '\n');
    const segment_end = if (newline) |relative| start + relative else text.len;
    const segment = text[start..segment_end];
    const prefix = display_width.wrapCutIgnoringAnsi(segment, content_width);
    if (prefix.len < segment.len) {
        if (prefix.len > 0) {
            const content_end = start + prefix.len;
            var next_start = content_end;
            while (next_start < segment_end and
                (text[next_start] == ' ' or text[next_start] == '\t'))
            {
                next_start += 1;
            }
            return .{ .content_end = content_end, .next_start = next_start };
        }

        const unit = display_width.displayUnitAt(text, start);
        const end = @min(start + unit.byte_len, segment_end);
        return .{ .content_end = end, .next_start = end };
    }

    return .{
        .content_end = segment_end,
        .next_start = if (segment_end < text.len) segment_end + 1 else segment_end,
    };
}

fn writeSelectedFreeformOptionLines(
    writer: *std.Io.Writer,
    entry: question_prompt.EntryProjection,
    ordinal: []const u8,
    prefix_width: usize,
    row_budget: usize,
) !void {
    const reverse = "\x1b[7m";
    const buffer = entry.freeform_buffer;
    const cursor = question_freeform_layout.normalizedCursor(buffer, entry.freeform_cursor);
    const content_width = question_freeform_layout.contentWidth(entry.choice_index, row_budget);

    if (buffer.len == 0) {
        try writer.writeAll(ui_render.selected_completion_style);
        try writer.writeAll(question_freeform_layout.option_row_indent);
        try writer.writeAll(ordinal);
        try writer.writeAll(ui_render.reset_style);
        try writer.writeAll(reverse);
        try writer.writeByte(' ');
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
        return;
    }

    var start: usize = 0;
    var first = true;
    var last_width: usize = 0;
    var trailing_hard_break = false;
    while (start < buffer.len) {
        const line = question_freeform_layout.nextLine(buffer, start, content_width);
        const end = line.content_end;
        last_width = display_width.visibleWidth(buffer[start..end]);
        trailing_hard_break = line.hard_break and line.next_start == buffer.len;

        if (first) {
            try writer.writeAll(ui_render.selected_completion_style);
            try writer.writeAll(question_freeform_layout.option_row_indent);
            try writer.writeAll(ordinal);
        } else {
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(ui_render.selected_completion_style);
        }

        if (cursor >= start and cursor < end) {
            try writer.writeAll(buffer[start..cursor]);
            try writer.writeAll(ui_render.reset_style);
            try writer.writeAll(reverse);
            const cursor_unit = display_width.displayUnitAt(buffer, cursor);
            const cursor_end = @min(cursor + cursor_unit.byte_len, end);
            try writer.writeAll(buffer[cursor..cursor_end]);
            try writer.writeAll(ui_render.reset_style);
            if (cursor_end < end) {
                try writer.writeAll(ui_render.selected_completion_style);
                try writer.writeAll(buffer[cursor_end..end]);
            }
        } else {
            try writer.writeAll(buffer[start..end]);
        }

        if (cursor == end and line.hard_break) {
            try writer.writeAll(ui_render.reset_style);
            try writer.writeAll(reverse);
            try writer.writeByte(' ');
        } else if (line.next_start == buffer.len and !line.hard_break and cursor == buffer.len and last_width < content_width) {
            try writer.writeAll(ui_render.reset_style);
            try writer.writeAll(reverse);
            try writer.writeByte(' ');
        }
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');

        first = false;
        start = line.next_start;
    }

    if (trailing_hard_break or (cursor == buffer.len and last_width == content_width)) {
        try writer.splatByteAll(' ', prefix_width);
        try writer.writeAll(reverse);
        try writer.writeByte(' ');
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
    }
}

fn questionDescriptionColumn(row_budget: usize) usize {
    if (row_budget >= 72) return 38;
    if (row_budget >= 52) return 30;
    return 0;
}

/// Terminal block rendered after an entire question batch resolves.
/// All answered → one anchored question row plus its muted answer row per
/// entry. Cancelled → single `■ Cancelled\n`.
pub fn composeQuestionResolutions(
    alloc: Allocator,
    prompt: *const question_prompt.QuestionPrompt,
    cancelled: bool,
    cols: u16,
) ![]u8 {
    if (cancelled) {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try writeCancelledResolution(&out.writer);
        return out.toOwnedSlice();
    }

    var answers: std.ArrayList(types.QuestionAnswer) = .empty;
    defer answers.deinit(alloc);
    try answers.ensureTotalCapacity(alloc, prompt.entries.items.len);
    for (prompt.entries.items) |entry| {
        answers.appendAssumeCapacity(.{
            .question = entry.question,
            .answer = entry.answer orelse "",
        });
    }

    return composeResolvedQuestionAnswers(alloc, answers.items, cols);
}

/// Terminal block rendered after a completed question batch resolves.
/// The answer pairs are borrowed and must outlive this call.
pub fn composeResolvedQuestionAnswers(
    alloc: Allocator,
    answers: []const types.QuestionAnswer,
    cols: u16,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    for (answers, 0..) |answer, index| {
        try writeQuestionAnswerResolution(&out.writer, answer.question, answer.answer, index + 1, cols);
    }

    return out.toOwnedSlice();
}

fn writeQuestionAnswerResolution(
    writer: *std.Io.Writer,
    question: []const u8,
    answer: []const u8,
    number: usize,
    cols: u16,
) !void {
    // The question is numbered by its position in the batch; the muted
    // answer hangs beneath, aligned under the question text. Pure
    // typography, so the block never reads as a tool group.
    var prefix_buf: [16]u8 = undefined;
    const question_prefix = std.fmt.bufPrint(&prefix_buf, "  {d}) ", .{number}) catch "  ";
    var indent_buf: [16]u8 = undefined;
    const indent = blk: {
        const width = @min(display_width.visibleWidth(question_prefix), indent_buf.len);
        @memset(indent_buf[0..width], ' ');
        break :blk indent_buf[0..width];
    };
    try writeResolutionField(writer, question_prefix, indent, question, cols, null);
    try writeResolutionField(writer, indent, indent, answer, cols, ui_render.statusline_style);
}

fn writeResolutionField(
    writer: *std.Io.Writer,
    first_prefix: []const u8,
    continuation_prefix: []const u8,
    text: []const u8,
    cols: u16,
    style: ?[]const u8,
) !void {
    var start: usize = 0;
    var first = true;
    while (true) {
        const line_end = if (std.mem.findScalar(u8, text[start..], '\n')) |relative|
            start + relative
        else
            text.len;
        const prefix = if (first) first_prefix else continuation_prefix;
        const prefix_width = display_width.visibleWidth(prefix);
        const budget = @as(usize, cols) -| prefix_width;

        if (style) |row_style| try writer.writeAll(row_style);
        try writer.writeAll(prefix);
        try writeTruncated(writer, text[start..line_end], budget);
        if (style != null) try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');

        if (line_end == text.len) break;
        start = line_end + 1;
        first = false;
    }
}

fn writeCancelledResolution(writer: *std.Io.Writer) !void {
    try writer.writeAll(ui_render.red_style);
    try writer.writeAll("■");
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll(" Cancelled");
    try writer.writeByte('\n');
}

fn writeTruncated(writer: *std.Io.Writer, text: []const u8, budget: usize) !void {
    if (budget == 0) return;
    if (display_width.visibleWidth(text) <= budget) {
        try writer.writeAll(text);
        return;
    }
    const keep_budget = if (budget > 1) budget - 1 else 0;
    const prefix = display_width.prefixByWidth(text, keep_budget);
    try writer.writeAll(prefix);
    try writer.writeAll("…");
}






fn expectQuestionPanelRowsMatch(
    prompt: *const question_prompt.QuestionPrompt,
    width: u16,
) !void {
    const projection = prompt.projection().?;
    const text = try composeQuestionPanelText(std.testing.allocator, projection, width);
    defer std.testing.allocator.free(text);

    var line_start: usize = 0;
    var serialized_rows: u16 = 0;
    while (line_start < text.len) {
        _ = nextPanelLine(text, &line_start);
        serialized_rows += 1;
    }

    const measured_rows = try questionPanelRowsForLayout(std.testing.allocator, projection, width);
    try std.testing.expectEqual(serialized_rows, measured_rows);
}











fn expectVisibleIndentBefore(text: []const u8, needle: []const u8, expected: usize) !void {
    const needle_start = std.mem.find(u8, text, needle) orelse return error.TestExpectedEqual;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..needle_start], '\n')) |newline|
        newline + 1
    else
        0;
    try std.testing.expectEqual(
        expected,
        display_width.visibleWidthIgnoringAnsi(text[line_start..needle_start]),
    );
}


