const std = @import("std");
const Allocator = std.mem.Allocator;

const display_width = @import("../shared/display_width.zig");
const ansi = @import("presentation/ansi.zig");
const tu = @import("presentation/text_util.zig");
const bp = @import("presentation/block_parse.zig");
const payload = @import("presentation/payload.zig");
const inline_render = @import("presentation/inline_render.zig");
const block_render = @import("presentation/block_render.zig");

/// Prevents OSC 8 hyperlinks from coalescing across wrapped terminal rows.
var link_id_counter: u32 = 1;

pub const setInlineCodeTheme = ansi.setInlineCodeTheme;
pub const writeHorizontalRule = ansi.writeHorizontalRule;

pub const TableColumnAlign = payload.TableColumnAlign;
pub const TableRow = payload.TableRow;
pub const TablePayload = payload.TablePayload;
pub const CodeBlockPayload = payload.CodeBlockPayload;
pub const TableCompletion = payload.TableCompletion;
pub const CodeBlockCompletion = payload.CodeBlockCompletion;
pub const ThematicRuleCompletion = payload.ThematicRuleCompletion;
pub const MarkdownCompletions = payload.MarkdownCompletions;

/// Allocator-owned assistant output queued for root or child presentation.
pub const Event = union(enum) {
    text: []u8,
    table: TablePayload,
    code_block: CodeBlockPayload,
    thematic_rule,

    pub fn clone(self: Event, alloc: Allocator) Allocator.Error!Event {
        return switch (self) {
            .text => |text| .{ .text = try alloc.dupe(u8, text) },
            .table => |table| .{ .table = try table.clone(alloc) },
            .code_block => |block| .{ .code_block = try block.clone(alloc) },
            .thematic_rule => .thematic_rule,
        };
    }

    pub fn requiresTextDrain(self: Event) bool {
        return switch (self) {
            .text => false,
            .table, .code_block, .thematic_rule => true,
        };
    }

    pub fn retainedByteCount(self: Event) usize {
        return switch (self) {
            .text => |text| text.len,
            .table => |table| blk: {
                var total: usize = table.alignments.len;
                for (table.rows) |row| {
                    total +|= row.cells.len * @sizeOf([]u8);
                    for (row.cells) |cell| total +|= cell.len;
                }
                break :blk total;
            },
            .code_block => |block| block.language.len +| block.code.len,
            .thematic_rule => 1,
        };
    }

    pub fn deinit(self: *Event, alloc: Allocator) void {
        switch (self.*) {
            .text => |text| alloc.free(text),
            .table => |*table| table.deinit(alloc),
            .code_block => |*block| block.deinit(alloc),
            .thematic_rule => {},
        }
        self.* = undefined;
    }
};

pub const renderCodeBlockPayload = block_render.renderCodeBlockPayload;
pub const renderTablePayload = block_render.renderTablePayload;
pub const writeTableHeaderCell = block_render.writeTableHeaderCell;

pub fn parseTablePayload(alloc: Allocator, buf: []const u8) !payload.TablePayload {
    return block_render.parseTablePayload(alloc, buf, &link_id_counter);
}

const isPipeLine = bp.isPipeLine;
const max_link_url_bytes = ansi.max_link_url_bytes;
const horizontal_rule_width = ansi.horizontal_rule_width;
const dim_open = ansi.dim_open;
const dim_close = ansi.dim_close;
const table_horiz = ansi.table_horiz;

const Footnote = struct {
    label: []u8,
    number: ?usize = null,
    body: std.ArrayList(u8) = .empty,
    has_definition: bool = false,

    fn deinit(self: *Footnote, alloc: Allocator) void {
        alloc.free(self.label);
        self.body.deinit(alloc);
    }
};

const ActiveFootnote = struct {
    index: usize,
    append_body: bool,
};

pub const MarkdownProcessor = struct {
    line_buf: std.ArrayList(u8) = .empty,
    pending_top_level_line: std.ArrayList(u8) = .empty,
    pipe_buf: std.ArrayList(u8) = .empty,
    code_buf: std.ArrayList(u8) = .empty,
    code_language: std.ArrayList(u8) = .empty,
    in_code_block: bool = false,
    code_fence_marker: ?u8 = null,
    in_pipe_block: bool = false,
    pipe_last_line_has_lf: bool = false,
    active_blockquote: ?bp.BlockquotePrefix = null,
    active_definition: bool = false,
    footnotes: std.ArrayList(Footnote) = .empty,
    active_footnote: ?ActiveFootnote = null,
    next_footnote_number: usize = 0,
    previous_line_was_blank: bool = true,

    pub fn deinit(self: *MarkdownProcessor, alloc: Allocator) void {
        self.line_buf.deinit(alloc);
        self.pending_top_level_line.deinit(alloc);
        self.pipe_buf.deinit(alloc);
        self.code_buf.deinit(alloc);
        self.code_language.deinit(alloc);
        self.deinitFootnotes(alloc);
    }

    pub fn reset(self: *MarkdownProcessor, alloc: Allocator) void {
        self.line_buf.clearAndFree(alloc);
        self.pending_top_level_line.clearAndFree(alloc);
        self.pipe_buf.clearAndFree(alloc);
        self.code_buf.clearAndFree(alloc);
        self.code_language.clearAndFree(alloc);
        self.deinitFootnotes(alloc);
        self.in_code_block = false;
        self.code_fence_marker = null;
        self.in_pipe_block = false;
        self.pipe_last_line_has_lf = false;
        self.active_blockquote = null;
        self.active_definition = false;
        self.active_footnote = null;
        self.next_footnote_number = 0;
        self.previous_line_was_blank = true;
    }

    pub fn push(self: *MarkdownProcessor, alloc: Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
        try self.pushWithCompletions(alloc, input, out, .{});
    }

    pub fn pushWithTableCompletion(
        self: *MarkdownProcessor,
        alloc: Allocator,
        input: []const u8,
        out: *std.ArrayList(u8),
        completion: ?*const payload.TableCompletion,
    ) !void {
        try self.pushWithCompletions(alloc, input, out, .{ .table = completion });
    }

    pub fn pushWithCompletions(
        self: *MarkdownProcessor,
        alloc: Allocator,
        input: []const u8,
        out: *std.ArrayList(u8),
        completions: payload.MarkdownCompletions,
    ) !void {
        for (input) |byte| {
            if (byte == '\n') {
                const line_end = self.line_buf.items.len - @intFromBool(
                    self.line_buf.items.len > 0 and self.line_buf.items[self.line_buf.items.len - 1] == '\r',
                );
                try self.handleLine(alloc, self.line_buf.items[0..line_end], true, out, completions);
                self.line_buf.clearRetainingCapacity();
            } else {
                try self.line_buf.append(alloc, byte);
            }
        }
    }

    /// Rebuilds structural Markdown state from source that is already visible.
    /// Buffered bytes are discarded so later chunks emit only new content.
    pub fn restorePresentedPrefix(
        self: *MarkdownProcessor,
        alloc: Allocator,
        source: []const u8,
    ) !void {
        self.reset(alloc);
        var discarded: std.ArrayList(u8) = .empty;
        defer discarded.deinit(alloc);

        try self.push(alloc, source, &discarded);
        if (self.line_buf.items.len > 0) {
            try self.handleLine(
                alloc,
                self.line_buf.items,
                false,
                &discarded,
                .{},
            );
            self.line_buf.clearRetainingCapacity();
        }
        self.pending_top_level_line.clearRetainingCapacity();
        self.pipe_buf.clearRetainingCapacity();
        self.in_pipe_block = false;
        self.pipe_last_line_has_lf = false;
        self.code_buf.clearRetainingCapacity();
    }

    pub fn flush(self: *MarkdownProcessor, alloc: Allocator, out: *std.ArrayList(u8)) !void {
        try self.flushWithCompletions(alloc, out, .{});
    }

    pub fn flushWithTableCompletion(
        self: *MarkdownProcessor,
        alloc: Allocator,
        out: *std.ArrayList(u8),
        completion: ?*const payload.TableCompletion,
    ) !void {
        try self.flushWithCompletions(alloc, out, .{ .table = completion });
    }

    pub fn flushWithCompletions(
        self: *MarkdownProcessor,
        alloc: Allocator,
        out: *std.ArrayList(u8),
        completions: payload.MarkdownCompletions,
    ) !void {
        defer self.active_blockquote = null;
        defer self.active_definition = false;
        defer self.active_footnote = null;
        const had_partial_line = self.line_buf.items.len > 0;
        const len_before = out.items.len;
        if (self.line_buf.items.len > 0) {
            try self.handleLine(alloc, self.line_buf.items, false, out, completions);
            self.line_buf.clearRetainingCapacity();
        }
        try self.flushPendingTopLevelLine(alloc, out);
        if (had_partial_line and out.items.len > len_before and out.items[out.items.len - 1] == '\n') {
            out.items.len -= 1;
        }
        if (self.in_pipe_block) try self.finalizePipeBlock(alloc, out, completions.table);
        if (self.in_code_block) {
            try self.finalizeCodeBlock(alloc, out, completions.code);
            self.in_code_block = false;
            self.code_fence_marker = null;
        }
        try self.flushFootnotes(alloc, out);
    }

    fn handleLine(
        self: *MarkdownProcessor,
        alloc: Allocator,
        line: []const u8,
        line_has_lf: bool,
        out: *std.ArrayList(u8),
        completions: payload.MarkdownCompletions,
    ) !void {
        const fs = self.footnoteSink();
        defer self.previous_line_was_blank = tu.isBlankMarkdownLine(line);

        if (self.in_code_block) {
            self.active_definition = false;
            if (self.code_fence_marker) |marker| {
                if (bp.codeFenceMarker(tu.leftTrim(line)) == marker) {
                    try self.finalizeCodeBlock(alloc, out, completions.code);
                    self.in_code_block = false;
                    self.code_fence_marker = null;
                    return;
                }
            } else if (!tu.isBlankMarkdownLine(line) and !bp.hasIndentedCodePrefix(line)) {
                try self.finalizeCodeBlock(alloc, out, completions.code);
                self.in_code_block = false;
                try self.handleLine(alloc, line, line_has_lf, out, completions);
                return;
            }
            const code_line = if (self.code_fence_marker == null and !tu.isBlankMarkdownLine(line))
                bp.deindentCodeLine(line)
            else
                line;
            try self.appendCodeLine(alloc, code_line, line_has_lf, out, completions.code);
            return;
        }

        if (self.in_pipe_block) {
            self.active_definition = false;
            if (bp.isPipeLine(line) and self.pipe_buf.items.len + line.len + 1 <= ansi.max_pipe_buffer_bytes) {
                try self.pipe_buf.appendSlice(alloc, line);
                try self.pipe_buf.append(alloc, '\n');
                self.pipe_last_line_has_lf = line_has_lf;
                return;
            }
            try self.finalizePipeBlock(alloc, out, completions.table);
        }

        if (self.active_footnote) |active| {
            if (bp.footnoteContinuationBody(line)) |body| {
                if (active.append_body) {
                    var note = &self.footnotes.items[active.index];
                    try note.body.append(alloc, '\n');
                    try note.body.appendSlice(alloc, body);
                }
                return;
            }
            self.active_footnote = null;
        }

        if (bp.parseFootnoteDefinition(line)) |definition| {
            self.active_definition = false;
            try self.flushPendingTopLevelLine(alloc, out);
            try self.beginFootnoteDefinition(alloc, definition);
            return;
        }

        if (completions.thematic_rule != null and self.pending_top_level_line.items.len > 0) {
            if (bp.parseSetextUnderline(line)) |level| {
                self.active_definition = false;
                try block_render.writeHeading(alloc, level, tu.withoutTerminalHardBreakMarker(self.pending_top_level_line.items, true), out, &fs, &link_id_counter);
                try out.append(alloc, '\n');
                self.pending_top_level_line.clearRetainingCapacity();
                return;
            }
            if (bp.definitionMarkerBody(line)) |body| {
                try self.flushPendingTopLevelLine(alloc, out);
                try block_render.writeDefinitionLine(alloc, body, line_has_lf, out, &fs, &link_id_counter);
                self.active_definition = true;
                return;
            }
            self.active_definition = false;
            try self.flushPendingTopLevelLine(alloc, out);
        }

        if (self.active_blockquote) |blockquote| {
            self.active_definition = false;
            if (bp.isLazyBlockquoteContinuation(line)) {
                try block_render.writeBlockquoteLine(alloc, blockquote, line, line_has_lf, out, &fs, &link_id_counter);
                try out.append(alloc, '\n');
                return;
            }
            self.active_blockquote = null;
        }

        if (bp.hasIndentedCodePrefix(line) and (bp.parseUnorderedList(line) != null or bp.parseOrderedList(line) != null)) {
            self.active_definition = false;
            try self.processLine(alloc, line, line_has_lf, out);
            try out.append(alloc, '\n');
            return;
        }

        if (self.previous_line_was_blank and bp.hasIndentedCodePrefix(line)) {
            self.active_definition = false;
            self.in_code_block = true;
            self.code_fence_marker = null;
            self.code_language.clearRetainingCapacity();
            try self.appendCodeLine(alloc, bp.deindentCodeLine(line), line_has_lf, out, completions.code);
            return;
        }

        if (!self.in_code_block and bp.isPipeLine(line)) {
            self.active_definition = false;
            self.in_pipe_block = true;
            try self.pipe_buf.appendSlice(alloc, line);
            try self.pipe_buf.append(alloc, '\n');
            self.pipe_last_line_has_lf = line_has_lf;
            return;
        }

        if (bp.codeFenceMarker(tu.leftTrim(line))) |marker| {
            self.active_definition = false;
            self.in_code_block = true;
            self.code_fence_marker = marker;
            self.code_language.clearRetainingCapacity();
            try self.code_language.appendSlice(alloc, bp.codeFenceLanguage(tu.leftTrim(line)));
            return;
        }

        if (self.active_definition) {
            if (bp.definitionMarkerBody(line)) |body| {
                try block_render.writeDefinitionLine(alloc, body, line_has_lf, out, &fs, &link_id_counter);
                return;
            }
        }
        self.active_definition = false;

        if (line_has_lf and completions.thematic_rule != null and bp.isSetextCandidate(line)) {
            try self.pending_top_level_line.appendSlice(alloc, line);
            return;
        }

        if (bp.isHorizontalRule(line)) {
            if (completions.thematic_rule) |completion| {
                try completion.deliver(completion.ctx, out);
                return;
            }
        }

        try self.processLine(alloc, line, line_has_lf, out);
        try out.append(alloc, '\n');
    }

    fn appendCodeLine(
        self: *MarkdownProcessor,
        alloc: Allocator,
        line: []const u8,
        line_has_lf: bool,
        out: *std.ArrayList(u8),
        completion: ?*const payload.CodeBlockCompletion,
    ) !void {
        if (completion != null) {
            try self.code_buf.appendSlice(alloc, line);
            try self.code_buf.append(alloc, '\n');
            return;
        }
        try self.processLine(alloc, line, line_has_lf, out);
        try out.append(alloc, '\n');
    }

    fn flushPendingTopLevelLine(self: *MarkdownProcessor, alloc: Allocator, out: *std.ArrayList(u8)) !void {
        if (self.pending_top_level_line.items.len == 0) return;
        try self.processLine(alloc, self.pending_top_level_line.items, true, out);
        try out.append(alloc, '\n');
        self.pending_top_level_line.clearRetainingCapacity();
    }

    fn processLine(
        self: *MarkdownProcessor,
        alloc: Allocator,
        line: []const u8,
        line_has_lf: bool,
        out: *std.ArrayList(u8),
    ) !void {
        const fs = self.footnoteSink();
        if (self.in_code_block) {
            try ansi.writeDim(alloc, out, ansi.vertical_rule_prefix);
            try out.appendSlice(alloc, line);
            return;
        }

        if (bp.isHorizontalRule(line)) {
            try ansi.writeHorizontalRule(alloc, out);
            return;
        }

        if (bp.parseHeader(line)) |header| {
            try block_render.writeHeading(alloc, header.level, tu.withoutTerminalHardBreakMarker(header.content, line_has_lf), out, &fs, &link_id_counter);
            return;
        }

        if (bp.parseBlockquote(line)) |parsed| {
            const blockquote = bp.BlockquotePrefix{
                .indent = parsed.indent.len,
                .depth = parsed.depth,
            };
            self.active_blockquote = if (bp.isBlockquoteParagraph(parsed.content)) blockquote else null;
            try block_render.writeBlockquoteLine(alloc, blockquote, parsed.content, line_has_lf, out, &fs, &link_id_counter);
            return;
        }

        if (bp.parseUnorderedList(line)) |parsed| {
            try out.appendSlice(alloc, parsed.indent);
            if (bp.parseTaskListItem(parsed.content)) |task| {
                try block_render.writeTaskListMarker(alloc, out, task);
                try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(task.content, line_has_lf), out, false, &fs, &link_id_counter);
                return;
            }
            try ansi.writeDim(alloc, out, ansi.bullet_marker);
            try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(parsed.content, line_has_lf), out, false, &fs, &link_id_counter);
            return;
        }

        if (bp.parseOrderedList(line)) |parsed| {
            try out.appendSlice(alloc, parsed.indent);
            try ansi.writeDim(alloc, out, parsed.marker);
            try out.append(alloc, ' ');
            if (bp.parseTaskListItem(parsed.content)) |task| {
                try block_render.writeTaskListMarker(alloc, out, task);
                try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(task.content, line_has_lf), out, false, &fs, &link_id_counter);
                return;
            }
            try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(parsed.content, line_has_lf), out, false, &fs, &link_id_counter);
            return;
        }

        try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(line, line_has_lf), out, false, &fs, &link_id_counter);
    }

    fn finalizePipeBlock(
        self: *MarkdownProcessor,
        alloc: Allocator,
        out: *std.ArrayList(u8),
        completion: ?*const payload.TableCompletion,
    ) !void {
        const fs = self.footnoteSink();
        defer {
            self.pipe_buf.clearRetainingCapacity();
            self.in_pipe_block = false;
            self.pipe_last_line_has_lf = false;
        }

        if (bp.isValidTable(self.pipe_buf.items)) {
            if (completion) |sink| {
                var table = try block_render.parseTablePayloadWithFootnotes(alloc, self.pipe_buf.items, &fs, &link_id_counter);
                var delivered = false;
                errdefer if (!delivered) table.deinit(alloc);
                try sink.deliver(sink.ctx, table, out);
                delivered = true;
                return;
            }
            try block_render.renderTable(alloc, self.pipe_buf.items, out, &fs, &link_id_counter);
            return;
        }

        var start: usize = 0;
        while (start < self.pipe_buf.items.len) {
            const end = std.mem.indexOfScalarPos(u8, self.pipe_buf.items, start, '\n') orelse self.pipe_buf.items.len;
            const line_has_lf = if (end + 1 == self.pipe_buf.items.len) self.pipe_last_line_has_lf else true;
            try self.processLine(alloc, self.pipe_buf.items[start..end], line_has_lf, out);
            if (line_has_lf) try out.append(alloc, '\n');
            start = end + 1;
        }
    }

    fn finalizeCodeBlock(
        self: *MarkdownProcessor,
        alloc: Allocator,
        out: *std.ArrayList(u8),
        completion: ?*const payload.CodeBlockCompletion,
    ) !void {
        defer {
            self.code_buf.clearRetainingCapacity();
            self.code_language.clearRetainingCapacity();
        }

        const sink = completion orelse return;
        var language: ?[]u8 = try alloc.dupe(u8, self.code_language.items);
        errdefer if (language) |owned| alloc.free(owned);
        const code = try alloc.dupe(u8, self.code_buf.items);
        var block = payload.CodeBlockPayload{
            .language = language.?,
            .code = code,
        };
        language = null;
        var delivered = false;
        errdefer if (!delivered) block.deinit(alloc);
        try sink.deliver(sink.ctx, block, out);
        delivered = true;
    }

    fn deinitFootnotes(self: *MarkdownProcessor, alloc: Allocator) void {
        for (self.footnotes.items) |*note| note.deinit(alloc);
        self.footnotes.clearAndFree(alloc);
    }

    fn findOrAppendFootnote(self: *MarkdownProcessor, alloc: Allocator, label: []const u8) !usize {
        for (self.footnotes.items, 0..) |note, index| {
            if (std.mem.eql(u8, note.label, label)) return index;
        }

        const owned_label = try alloc.dupe(u8, label);
        errdefer alloc.free(owned_label);
        try self.footnotes.append(alloc, .{ .label = owned_label });
        return self.footnotes.items.len - 1;
    }

    fn footnoteSink(self: *MarkdownProcessor) payload.FootnoteSink {
        return .{ .ctx = self, .register = registerFootnoteThunk };
    }

    fn registerFootnoteReference(self: *MarkdownProcessor, alloc: Allocator, label: []const u8) !usize {
        const index = try self.findOrAppendFootnote(alloc, label);
        if (self.footnotes.items[index].number == null) {
            self.next_footnote_number += 1;
            self.footnotes.items[index].number = self.next_footnote_number;
        }
        return self.footnotes.items[index].number.?;
    }

    fn beginFootnoteDefinition(
        self: *MarkdownProcessor,
        alloc: Allocator,
        definition: bp.ParsedFootnoteDefinition,
    ) !void {
        const index = try self.findOrAppendFootnote(alloc, definition.label);
        const note = &self.footnotes.items[index];
        if (note.has_definition) {
            self.active_footnote = .{ .index = index, .append_body = false };
            return;
        }
        try note.body.appendSlice(alloc, definition.body);
        note.has_definition = true;
        self.active_footnote = .{ .index = index, .append_body = true };
    }

    fn flushFootnotes(self: *MarkdownProcessor, alloc: Allocator, out: *std.ArrayList(u8)) !void {
        const fs = self.footnoteSink();
        defer self.deinitFootnotes(alloc);
        defer self.next_footnote_number = 0;

        var has_note = false;
        for (self.footnotes.items) |note| {
            if (note.number != null and note.has_definition) {
                has_note = true;
                break;
            }
        }
        if (!has_note) return;

        while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
            out.items.len -= 1;
        }
        if (out.items.len > 0) {
            try out.appendSlice(alloc, "\n\n");
        } else {
            try out.append(alloc, '\n');
        }

        var number: usize = 1;
        while (number <= self.next_footnote_number) : (number += 1) {
            for (self.footnotes.items) |*note| {
                if (note.number != number or !note.has_definition) continue;
                try block_render.writeFootnoteDefinitionMarker(alloc, out, number);
                try block_render.writeFootnoteBody(alloc, note.body.items, out, &fs, number, &link_id_counter);
                break;
            }
        }
    }
};

fn registerFootnoteThunk(ctx: *anyopaque, alloc: Allocator, label: []const u8) anyerror!usize {
    const self: *MarkdownProcessor = @ptrCast(@alignCast(ctx));
    return self.registerFootnoteReference(alloc, label);
}

fn checkSetextLookaheadAllocationFailures(alloc: Allocator) !void {
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "allocation title\n---\n", &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqualStrings("\x1b[1mallocation title\x1b[22m\n", out.items);
}

fn checkDefinitionListAllocationFailures(alloc: Allocator) !void {
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Status\n: **Running**\n: second definition\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqualStrings(
        "Status\n" ++
            "\x1b[2m  \x1b[22m\x1b[1mRunning\x1b[22m\n" ++
            "\x1b[2m  \x1b[22msecond definition\n",
        out.items,
    );
}

fn checkFootnoteAllocationFailures(alloc: Allocator) !void {
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "The cache is scoped to this request.[^cache]\n" ++
            "[^cache]: First **formatted** line.\n" ++
            "  Second continuation line.\n",
        &out,
    );
    try processor.flush(alloc, &out);
}
