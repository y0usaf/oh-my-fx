const std = @import("std");
const build_checkpoint = @import("build_checkpoint.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const assistant_wrap = @import("assistant_wrap.zig");
const transcript_measure = @import("transcript_measure.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const input_visual_layout = @import("../input/visual_layout.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const assistant_presentation = @import("../../core/agent/assistant_presentation.zig");
const code_highlight = @import("code_highlight.zig");
const code_highlight_languages = @import("code_highlight_languages.zig");

const Allocator = std.mem.Allocator;

pub const WalkResult = transcript_measure.WalkResult;
pub const walkText = transcript_measure.walkText;
pub const nextCursorColForLine = transcript_measure.nextCursorColForLine;
pub const skipVisualRowsInLine = transcript_measure.skipVisualRowsInLine;
pub const visualRowsForLine = transcript_measure.visualRowsForLine;

pub const CommandOutputDisplayState = struct {
    open_block: ?usize = null,
    open_command_block: ?usize = null,
};

pub const CodeHighlightTheme = code_highlight.Theme;

pub const Styles = struct {
    system_notice_label_style: []const u8 = "",
    system_notice_text_style: []const u8 = "",
    reset_style: []const u8 = "",
    dim_style: []const u8 = "",
    red_style: []const u8 = "",
    cancelled_text_style: []const u8 = "",
    notice_information_style: []const u8 = "",
    notice_success_style: []const u8 = "",
    notice_warning_style: []const u8 = "",
    notice_error_style: []const u8 = "",
    notice_cancelled_style: []const u8 = "",
    code_highlight_theme: CodeHighlightTheme = .dark,
};

pub const ToolFallbackDisposition = enum {
    completion_unreported,
    not_executed,
};

pub const ToolDetailRecord = struct {
    entry_id: u32,
    created_at_ms: i64 = 0,
    tool_name: []u8,
    captured_command: bool = false,
    activity_kind: ?types.ToolActivityKind = null,
    arguments_json: ?[]u8 = null,
    result: ?[]u8 = null,
    result_handle: ?[]u8 = null,
    command_artifact_handle: ?[]u8 = null,
    command_output_replay: ?types.CommandOutputReplay = null,
    command_process_presentation: ?types.CommandProcessPresentation = null,
    outcome: ?types.ToolOutcomeKind = null,
    fallback_disposition: ?ToolFallbackDisposition = null,
    lifecycle_id: ?types.ToolLifecycleId = null,
    presentation_group_id: ?types.ToolPresentationGroupId = null,
    command_output_entry_id: ?u32 = null,

    pub fn isCapturedCommand(self: ToolDetailRecord) bool {
        // Hand-built details and restored records may predate the explicit
        // classifier. Preserve their historical presentation contract.
        return self.captured_command or std.mem.eql(u8, self.tool_name, "run_command");
    }

    pub fn deinit(self: *ToolDetailRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.tool_name);
        if (self.arguments_json) |value| alloc.free(value);
        if (self.result) |value| alloc.free(value);
        if (self.result_handle) |value| alloc.free(value);
        if (self.command_artifact_handle) |value| alloc.free(value);
        if (self.command_output_replay) |replay| {
            types.freeCommandOutputReplay(alloc, replay);
        }
        if (self.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
        self.* = undefined;
    }
};

pub const FullDetailAppend = struct {
    attached: bool = false,
    ends_with_newline: bool = false,
};

pub const FullPresentationSink = struct {
    context: *anyopaque,
    skip_entry: *const fn (context: *anyopaque, entry: TranscriptEntry, index: usize) bool,
    override_kind: *const fn (context: *anyopaque, entry: TranscriptEntry) ?TranscriptBlockKind,
    append_override: *const fn (context: *anyopaque, entry: TranscriptEntry, out: *std.Io.Writer.Allocating) anyerror!bool,
    before_entry: *const fn (context: *anyopaque, entry_id: u32, out: *std.Io.Writer.Allocating) anyerror!void,
    append_detail: *const fn (context: *anyopaque, entry_id: u32, out: *std.Io.Writer.Allocating) anyerror!FullDetailAppend,
};

pub const AssistantTurnSegments = struct {
    /// Raw streamed text from the pacer, with inline SGR runs. No
    /// injected wraps. Paint-time reflow decides wrap boundaries
    /// for the current cols and reasserts SGR at each boundary so
    /// bold and colour never leak into continuation rows.
    text: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *AssistantTurnSegments, alloc: Allocator) void {
        self.text.deinit(alloc);
    }
};

pub const RawEntryClass = enum {
    welcome,
    turn_summary,
    tool_status,
    command_output,
    diff_block,
    question_resolution,
    subagent_status,
    unknown_raw,
};

pub const TranscriptBlockKind = enum {
    user_turn,
    assistant_turn,
    assistant_table,
    assistant_code_block,
    assistant_thematic_rule,
    turn_summary,
    welcome,
    tool_status,
    command_output,
    diff_block,
    system_notice,
    error_notice,
    cancel_notice,
    subagent_status,
    unknown_raw,
};

pub const TranscriptEntryClass = enum {
    user_turn,
    assistant_turn,
    assistant_table,
    assistant_code_block,
    assistant_thematic_rule,
    welcome,
    turn_summary,
    tool_status,
    command_output,
    diff_block,
    system_notice,
    context_notice,
    error_notice,
    cancel_notice,
    subagent_status,
    unknown_raw,
};

pub const LineProvenance = union(enum) {
    entry: struct {
        entry_id: u32,
        entry_class: TranscriptEntryClass,
    },
    block_separator,
    boundary_blank,
    capped_continuation,
    folded_command_output: struct {
        entry_id: ?u32,
        stream: command_output_content.Stream,
    },
    unattributed,
    empty_transcript,
};

pub const RowProvenance = struct {
    row: u16,
    source: LineProvenance,
};

pub fn blockKindForRawClass(class: RawEntryClass) TranscriptBlockKind {
    return switch (class) {
        .welcome => .welcome,
        .turn_summary => .turn_summary,
        .tool_status => .tool_status,
        .command_output => .command_output,
        .diff_block => .diff_block,
        .question_resolution => .cancel_notice,
        .subagent_status => .subagent_status,
        .unknown_raw => .unknown_raw,
    };
}

pub fn blockKindForNoticeTone(tone: types.NoticeTone) TranscriptBlockKind {
    return switch (tone) {
        .information, .success, .warning, .neutral => .system_notice,
        .@"error" => .error_notice,
        .cancelled => .cancel_notice,
    };
}

pub fn blockGapRowsBetween(prev: TranscriptBlockKind, next: TranscriptBlockKind) u16 {
    return default_block_gap_policy.gapBetween(prev, next);
}

fn blockKindForEntry(entry: TranscriptEntry) TranscriptBlockKind {
    return switch (entry) {
        .raw_bytes => |e| blockKindForRawClass(e.class),
        .semantic_notice => |e| blockKindForNoticeTone(e.tone),
        .user_turn => .user_turn,
        .assistant_turn => .assistant_turn,
        .assistant_table => .assistant_table,
        .assistant_code_block => .assistant_code_block,
        .assistant_thematic_rule => .assistant_thematic_rule,
    };
}

pub fn isEntryVisibleInCompactPresentation(entry: TranscriptEntry) bool {
    return switch (entry) {
        .raw_bytes => true,
        .semantic_notice => |notice| notice.visibility == .compact_and_full,
        else => true,
    };
}

pub fn entryClassForEntry(entry: TranscriptEntry) TranscriptEntryClass {
    return switch (entry) {
        .user_turn => .user_turn,
        .assistant_turn => .assistant_turn,
        .assistant_table => .assistant_table,
        .assistant_code_block => .assistant_code_block,
        .assistant_thematic_rule => .assistant_thematic_rule,
        .semantic_notice => |notice| switch (notice.tone) {
            .information, .success, .warning, .neutral => if (std.ascii.eqlIgnoreCase(notice.topic, "context"))
                .context_notice
            else
                .system_notice,
            .@"error" => .error_notice,
            .cancelled => .cancel_notice,
        },
        .raw_bytes => |raw| switch (raw.class) {
            .welcome => .welcome,
            .turn_summary => .turn_summary,
            .tool_status => .tool_status,
            .command_output => .command_output,
            .diff_block => .diff_block,
            .question_resolution => .cancel_notice,
            .subagent_status => .subagent_status,
            .unknown_raw => .unknown_raw,
        },
    };
}

pub const BlockGapPolicy = struct {
    default_gap_rows: u16 = 1,

    pub fn gapBetween(self: BlockGapPolicy, prev: TranscriptBlockKind, next: TranscriptBlockKind) u16 {
        if (prev == .tool_status and next == .command_output) return 0;
        if (prev == .command_output and next == .command_output) return 0;
        if (prev == .subagent_status and next == .subagent_status) return 0;
        return self.default_gap_rows;
    }
};

pub const EntryRenderOverride = struct {
    entry_id: u32,
    kind: TranscriptBlockKind,
    bytes: []const u8,
};

pub const EntryRenderAction = union(enum) {
    keep,
    hide,
    override: struct {
        kind: TranscriptBlockKind,
        bytes: []const u8,
    },
};

pub const default_block_gap_policy: BlockGapPolicy = .{};

pub const TranscriptEntry = union(enum) {
    /// Banners, command-output summaries, system notices, spinners:
    /// content with a fixed byte shape that does not reshape across
    /// widths. Entry owns the byte slice; freed with the entry.
    raw_bytes: RawBytesEntry,
    /// One retained semantic notice. Topic and body are owned by the entry;
    /// paint-time rendering supplies theme, width, marker, and spacing.
    semantic_notice: SemanticNoticeEntry,
    /// One user prompt. Stored as its logical text plus images and optional
    /// display-only skill spans; the bordered card is rebuilt at paint time
    /// at the current cols so reshape is correct at any width.
    user_turn: UserTurnEntry,
    /// One assistant response, populated incrementally as the pacer
    /// emits tokens. Reflowed at paint time for the current cols.
    assistant_turn: AssistantTurnEntry,
    /// One completed Markdown table, retained as cells so it can be
    /// re-laid out at the active terminal width.
    assistant_table: AssistantTableEntry,
    /// One completed Markdown code block, retained as literal source so it
    /// can be re-laid out at the active terminal width.
    assistant_code_block: AssistantCodeBlockEntry,
    /// One completed Markdown thematic rule, retained semantically so it
    /// can fill the active terminal width.
    assistant_thematic_rule: AssistantThematicRuleEntry,

    pub const RawBytesEntry = struct {
        id: u32,
        created_at_ms: i64 = 0,
        bytes: []const u8,
        class: RawEntryClass = .unknown_raw,
        lifecycle_pinned: bool = false,
    };

    pub const SemanticNoticeEntry = struct {
        id: u32,
        created_at_ms: i64 = 0,
        topic: []const u8,
        tone: types.NoticeTone,
        body: []const u8,
        visibility: types.NoticeVisibility,
        // The producer will replace this entry in place; its bytes are not
        // final and must not be released into terminal history.
        pending_replacement: bool = false,
    };

    pub const UserTurnEntry = struct {
        id: u32,
        created_at_ms: i64 = 0,
        turn: types.UserTurn,
        skill_tokens: []input_visual_layout.SkillTokenSpan = &.{},
    };

    pub const AssistantTurnEntry = struct {
        id: u32,
        created_at_ms: i64 = 0,
        segments: AssistantTurnSegments,
    };

    pub const AssistantTableEntry = struct {
        id: u32,
        created_at_ms: i64 = 0,
        table: assistant_presentation.TablePayload,
    };

    pub const AssistantCodeBlockEntry = struct {
        id: u32,
        created_at_ms: i64 = 0,
        block: assistant_presentation.CodeBlockPayload,
    };

    pub const AssistantThematicRuleEntry = struct {
        id: u32,
        created_at_ms: i64 = 0,
    };

    pub fn id(self: TranscriptEntry) u32 {
        return switch (self) {
            .raw_bytes => |e| e.id,
            .semantic_notice => |e| e.id,
            .user_turn => |e| e.id,
            .assistant_turn => |e| e.id,
            .assistant_table => |e| e.id,
            .assistant_code_block => |e| e.id,
            .assistant_thematic_rule => |e| e.id,
        };
    }

    pub fn createdAtMs(self: TranscriptEntry) i64 {
        return switch (self) {
            .raw_bytes => |e| e.created_at_ms,
            .semantic_notice => |e| e.created_at_ms,
            .user_turn => |e| e.created_at_ms,
            .assistant_turn => |e| e.created_at_ms,
            .assistant_table => |e| e.created_at_ms,
            .assistant_code_block => |e| e.created_at_ms,
            .assistant_thematic_rule => |e| e.created_at_ms,
        };
    }

    pub fn deinit(self: *TranscriptEntry, alloc: Allocator) void {
        switch (self.*) {
            .raw_bytes => |e| {
                alloc.free(e.bytes);
            },
            .semantic_notice => |e| {
                alloc.free(e.topic);
                alloc.free(e.body);
            },
            .user_turn => |*e| {
                types.freeUserTurn(alloc, e.turn);
                for (e.skill_tokens) |token| {
                    alloc.free(@constCast(token.name));
                    alloc.free(@constCast(token.path));
                }
                if (e.skill_tokens.len > 0) alloc.free(e.skill_tokens);
            },
            .assistant_turn => |*e| e.segments.deinit(alloc),
            .assistant_table => |*e| e.table.deinit(alloc),
            .assistant_code_block => |*e| e.block.deinit(alloc),
            .assistant_thematic_rule => {},
        }
    }
};

/// Reflow assistant text to fit within `cols` while preserving inline
/// SGR attributes and OSC 8 links across wrap boundaries. Paragraphs wrap at whitespace
/// and move a preceding word down when that avoids a single-word tail.
/// Pre-existing hard newlines in `text` are honoured. The returned slice is
/// owned by the caller and freed with `alloc`.
pub fn wrapAssistantText(alloc: Allocator, text: []const u8, cols: u16) ![]u8 {
    return assistant_wrap.wrapAssistantText(alloc, text, cols);
}

fn renderThematicRuleForTranscript(alloc: Allocator, cols: u16) ![]u8 {
    if (cols == 0) return alloc.dupe(u8, "");

    const gutter = assistant_wrap.gutterWidth(cols);
    const rule_width = cols -| gutter;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendNTimes(alloc, ' ', gutter);
    try out.appendSlice(alloc, "\x1b[2m");
    var i: u16 = 0;
    while (i < rule_width) : (i += 1) try out.appendSlice(alloc, "\xe2\x94\x80");
    try out.appendSlice(alloc, "\x1b[22m");
    return out.toOwnedSlice(alloc);
}

fn toolStatusOmissionMarker(cols: u16) []const u8 {
    return switch (cols) {
        0 => "",
        1 => ".",
        2 => "..",
        else => "...",
    };
}

const ToolStatusLine = struct {
    end: usize,
    next: usize,
    hard_break: bool = false,
    omitted_rune: bool = false,
};

fn skipToolStatusWrapWhitespace(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
    return index;
}

fn toolStatusTokenExceedsWidth(text: []const u8, start: usize, max_width: usize) bool {
    if (max_width == 0) return false;

    var index = start;
    var width: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, index);
            if (end <= index) return false;
            index = end;
            continue;
        }
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') return false;
        if (byte < 32) {
            index += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, index);
        const cell_width = unit.cell_width;
        if (width + cell_width > max_width) return true;
        width += cell_width;
        index += unit.byte_len;
    }
    return false;
}

fn scanToolStatusLine(text: []const u8, start: usize, max_width: usize) ToolStatusLine {
    if (start >= text.len or max_width == 0) return .{ .end = start, .next = start };

    var index = start;
    var width: usize = 0;
    var last_wrap_end: ?usize = null;
    var last_wrap_next: usize = start;
    while (index < text.len) {
        const byte = text[index];
        if (byte == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, index);
            if (end <= index) return .{ .end = index, .next = text.len, .omitted_rune = true };
            index = end;
            continue;
        }
        if (byte == '\n' or byte == '\r') {
            const next = if (byte == '\r' and index + 1 < text.len and text[index + 1] == '\n')
                index + 2
            else
                index + 1;
            return .{ .end = index, .next = next, .hard_break = true };
        }
        if (byte == ' ' or byte == '\t') {
            const next = skipToolStatusWrapWhitespace(text, index);
            const cell_width: usize = if (byte == ' ') 1 else 0;
            if (width + cell_width > max_width) {
                return .{ .end = index, .next = next };
            }
            last_wrap_end = index;
            last_wrap_next = next;
            width += cell_width;
            index += 1;
            continue;
        }
        if (byte < 32) {
            index += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, index);
        const cell_width = unit.cell_width;
        if (width + cell_width > max_width) {
            if (last_wrap_end) |end| {
                if (toolStatusTokenExceedsWidth(text, last_wrap_next, max_width)) {
                    return .{ .end = index, .next = index };
                }
                return .{ .end = end, .next = last_wrap_next };
            }
            if (width == 0) {
                return .{
                    .end = index,
                    .next = index + unit.byte_len,
                    .omitted_rune = true,
                };
            }
            return .{ .end = index, .next = index };
        }
        width += cell_width;
        index += unit.byte_len;
    }

    return .{ .end = index, .next = index };
}

fn lineLeavesToolStatusContent(text: []const u8, line: ToolStatusLine) bool {
    return line.next < text.len or line.omitted_rune;
}

fn plainToolStatusFitsPreview(text: []const u8, cols: u16) bool {
    if (text.len > cols) return false;

    var hard_breaks: u8 = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            0x1b => return false,
            '\n' => {
                hard_breaks += 1;
                if (hard_breaks > 1) return false;
            },
            '\r' => {
                hard_breaks += 1;
                if (hard_breaks > 1) return false;
                if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
            },
            else => {},
        }
    }
    return true;
}

fn toolStatusNeedsPreview(text: []const u8, cols: u16) bool {
    if (cols == 0 or text.len == 0) return false;
    if (plainToolStatusFitsPreview(text, cols)) return false;

    const first = scanToolStatusLine(text, 0, cols);
    if (first.omitted_rune) return true;
    if (first.hard_break) return first.next < text.len;
    return lineLeavesToolStatusContent(text, first);
}

fn appendToolStatusSgrReplay(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var index: usize = 0;
    var replayed_sgr = false;
    while (index < text.len) {
        if (text[index] != 0x1b) {
            index += 1;
            continue;
        }

        const end = display_width.ansiSequenceEnd(text, index);
        if (end <= index) {
            index += 1;
            continue;
        }
        const sequence = text[index..end];
        if (sequence.len >= 3 and sequence[1] == '[' and sequence[sequence.len - 1] == 'm') {
            if (!replayed_sgr) {
                try out.appendSlice(alloc, "\x1b[0m");
                replayed_sgr = true;
            }
            try out.appendSlice(alloc, sequence);
        }
        index = end;
    }
}

const DiffPrefix = struct {
    text_start: usize,
    width: u16,
};

fn skipDiffPrefixAnsi(line: []const u8, index: *usize) bool {
    while (index.* < line.len and line[index.*] == 0x1b) {
        const end = display_width.ansiSequenceEnd(line, index.*);
        if (end <= index.*) return false;
        index.* = end;
    }
    return true;
}

fn consumeDiffPrefixByte(line: []const u8, index: *usize, expected: u8) bool {
    if (!skipDiffPrefixAnsi(line, index)) return false;
    if (index.* >= line.len or line[index.*] != expected) return false;
    index.* += 1;
    return true;
}

fn diffPrefix(line: []const u8) ?DiffPrefix {
    var index: usize = 0;
    if (!consumeDiffPrefixByte(line, &index, ' ')) return null;
    if (!consumeDiffPrefixByte(line, &index, ' ')) return null;
    if (!skipDiffPrefixAnsi(line, &index)) return null;
    if (!std.mem.startsWith(u8, line[index..], "│")) return null;
    index += "│".len;
    if (!consumeDiffPrefixByte(line, &index, ' ')) return null;

    while (true) {
        if (!skipDiffPrefixAnsi(line, &index)) return null;
        if (index >= line.len or line[index] != ' ') break;
        index += 1;
    }
    var digit_count: usize = 0;
    while (true) {
        if (!skipDiffPrefixAnsi(line, &index)) return null;
        if (index >= line.len or !std.ascii.isDigit(line[index])) break;
        digit_count += 1;
        index += 1;
    }
    if (digit_count == 0) return null;
    if (!consumeDiffPrefixByte(line, &index, ' ')) return null;
    if (!skipDiffPrefixAnsi(line, &index) or index >= line.len) return null;
    switch (line[index]) {
        '+', '-', ' ' => {},
        else => return null,
    }
    index += 1;
    if (!consumeDiffPrefixByte(line, &index, ' ')) return null;
    if (!skipDiffPrefixAnsi(line, &index)) return null;

    const text_start = index;
    const width = std.math.cast(u16, display_width.visibleWidthIgnoringAnsi(line[0..text_start])) orelse return null;
    if (width < 4) return null;
    return .{ .text_start = text_start, .width = width };
}

fn isCompleteSgr(sequence: []const u8) bool {
    return sequence.len >= 3 and sequence[0] == 0x1b and sequence[1] == '[' and sequence[sequence.len - 1] == 'm';
}

fn appendSgrTransitions(
    alloc: Allocator,
    transitions: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] != 0x1b) {
            index += display_width.decodeNextRune(bytes, index).len;
            continue;
        }
        const end = display_width.ansiSequenceEnd(bytes, index);
        if (end <= index) return;
        const sequence = bytes[index..end];
        if (isCompleteSgr(sequence)) try transitions.appendSlice(alloc, sequence);
        index = end;
    }
}

fn reflowDiffRow(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    prefix: DiffPrefix,
    cols: u16,
) !void {
    try out.appendSlice(alloc, line[0..prefix.text_start]);

    var sgr_transitions: std.ArrayList(u8) = .empty;
    defer sgr_transitions.deinit(alloc);
    try appendSgrTransitions(alloc, &sgr_transitions, line[0..prefix.text_start]);

    var col: u16 = prefix.width + 1;
    var index = prefix.text_start;
    while (index < line.len) {
        if (line[index] == 0x1b) {
            const end = display_width.ansiSequenceEnd(line, index);
            if (end <= index) {
                try out.appendSlice(alloc, line[index..]);
                return;
            }
            const sequence = line[index..end];
            try out.appendSlice(alloc, sequence);
            if (isCompleteSgr(sequence)) try sgr_transitions.appendSlice(alloc, sequence);
            index = end;
            continue;
        }

        const unit = display_width.displayUnitAt(line, index);
        const width = unit.cell_width;
        if (width == 0) {
            try out.appendSlice(alloc, line[index .. index + unit.byte_len]);
            index += unit.byte_len;
            continue;
        }
        const cell_width: u16 = @intCast(width);
        if (display_width.shouldWrapAt(col, cell_width, cols)) {
            try out.appendSlice(alloc, "\x1b[0m\n");
            try out.appendSlice(alloc, sgr_transitions.items);
            try out.appendSlice(alloc, "  │ ");
            try out.appendNTimes(alloc, ' ', prefix.width - 4);
            col = prefix.width + 1;
        }
        try out.appendSlice(alloc, line[index .. index + unit.byte_len]);
        col += cell_width;
        index += unit.byte_len;
    }
}

/// Reflows logical diff rows for the current terminal width. The caller owns
/// the returned bytes.
pub fn reflowDiffBlock(alloc: Allocator, text: []const u8, cols: u16) ![]u8 {
    if (cols == 0 or text.len == 0) return alloc.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var start: usize = 0;
    while (start < text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = newline orelse text.len;
        const line = text[start..end];
        if (diffPrefix(line)) |prefix| {
            if (prefix.width < cols) {
                try reflowDiffRow(alloc, &out, line, prefix, cols);
            } else {
                try out.appendSlice(alloc, line);
            }
        } else {
            try out.appendSlice(alloc, line);
        }
        if (newline) |_| {
            try out.append(alloc, '\n');
            start = end + 1;
        } else break;
    }
    return out.toOwnedSlice(alloc);
}

fn formatToolStatusPreview(alloc: Allocator, text: []const u8, cols: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (cols == 0 or text.len == 0) return out.toOwnedSlice(alloc);

    const first = scanToolStatusLine(text, 0, cols);
    try out.appendSlice(alloc, text[0..first.end]);
    if (!lineLeavesToolStatusContent(text, first)) {
        if (first.hard_break) try out.append(alloc, '\n');
        return out.toOwnedSlice(alloc);
    }

    try out.append(alloc, '\n');
    try appendToolStatusSgrReplay(alloc, &out, text[0..first.end]);
    const continuation_indent: usize = if (cols >= 6) 2 else 0;
    try out.appendNTimes(alloc, ' ', continuation_indent);
    const continuation_width = @as(usize, cols) - continuation_indent;
    const full_second = scanToolStatusLine(text, first.next, continuation_width);
    if (!first.omitted_rune and !lineLeavesToolStatusContent(text, full_second)) {
        try out.appendSlice(alloc, text[first.next..full_second.end]);
        if (full_second.hard_break) try out.append(alloc, '\n');
        return out.toOwnedSlice(alloc);
    }

    const marker = toolStatusOmissionMarker(cols);
    const clipped_second = scanToolStatusLine(text, first.next, continuation_width - marker.len);
    try out.appendSlice(alloc, text[first.next..clipped_second.end]);
    try out.appendSlice(alloc, marker);
    if (std.mem.findScalar(u8, text, 0x1b) != null) try out.appendSlice(alloc, "\x1b[0m");
    return out.toOwnedSlice(alloc);
}

/// Renders a typed command status as one clipped physical row. The caller owns
/// the returned bytes.
pub fn formatCompactCommandStatus(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (cols == 0 or text.len == 0) return alloc.alloc(u8, 0);

    const line_end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    var next = line_end;
    if (next < text.len) {
        if (text[next] == '\r' and next + 1 < text.len and text[next + 1] == '\n') {
            next += 2;
        } else {
            next += 1;
        }
    }
    const line = text[0..line_end];
    const preserve_trailing_newline = text.len > 0 and
        (text[text.len - 1] == '\n' or text[text.len - 1] == '\r');
    if (next == text.len and display_width.visibleWidthIgnoringAnsi(line) <= cols) {
        return if (preserve_trailing_newline)
            std.fmt.allocPrint(alloc, "{s}\n", .{line})
        else
            alloc.dupe(u8, line);
    }

    const prefix = display_width.prefixByWidthIgnoringAnsi(line, cols - 1);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, prefix);
    try out.appendSlice(alloc, "…");
    if (std.mem.findScalar(u8, prefix, 0x1b) != null) {
        try out.appendSlice(alloc, "\x1b[0m");
    }
    if (preserve_trailing_newline) try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
}

fn formatFullToolStatus(alloc: Allocator, text: []const u8, cols: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (cols == 0 or text.len == 0) return out.toOwnedSlice(alloc);

    var start: usize = 0;
    var continuation = false;
    while (start < text.len) {
        const indent: usize = if (continuation and cols >= 6) 2 else 0;
        const line = scanToolStatusLine(text, start, @as(usize, cols) - indent);
        if (continuation) {
            try out.append(alloc, '\n');
            try appendToolStatusSgrReplay(alloc, &out, text[0..start]);
            try out.appendNTimes(alloc, ' ', indent);
        }
        try out.appendSlice(alloc, text[start..line.end]);

        if (line.next > start) {
            start = line.next;
        } else if (line.end > start) {
            start = line.end;
        } else {
            const unit = display_width.displayUnitAt(text, start);
            try out.append(alloc, '?');
            start += unit.byte_len;
        }
        continuation = true;

        if (line.hard_break and start == text.len) try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

pub fn renderTableForTranscript(
    alloc: Allocator,
    table: assistant_presentation.TablePayload,
    cols: u16,
) ![]u8 {
    var rendered: std.ArrayList(u8) = .empty;
    errdefer rendered.deinit(alloc);
    if (cols <= 2) {
        try renderUnboxedTable(alloc, table, cols, &rendered);
    } else {
        const widths = try alloc.alloc(usize, table.column_count);
        defer alloc.free(widths);
        @memset(widths, 0);
        for (table.rows) |row| for (row.cells, 0..) |cell, col| {
            widths[col] = @max(widths[col], display_width.visibleWidthIgnoringAnsi(cell));
        };
        const grid_width = table.column_count * 3 + 1 + sumWidths(widths);
        if (table.column_count > 0 and grid_width <= cols) {
            try renderBoxedGrid(alloc, table, widths, &rendered);
        } else {
            try renderBoxedVertical(alloc, table, cols, &rendered);
        }
    }
    return rendered.toOwnedSlice(alloc);
}

pub fn renderCodeBlockForTranscript(
    alloc: Allocator,
    block: assistant_presentation.CodeBlockPayload,
    cols: u16,
) ![]u8 {
    return renderCodeBlockForTranscriptWithTheme(alloc, block, cols, .dark);
}

fn renderCodeBlockForTranscriptWithTheme(
    alloc: Allocator,
    block: assistant_presentation.CodeBlockPayload,
    cols: u16,
    theme: CodeHighlightTheme,
) ![]u8 {
    var rendered: std.ArrayList(u8) = .empty;
    errdefer rendered.deinit(alloc);
    if (cols == 0) return rendered.toOwnedSlice(alloc);

    const profile = if (block.language.len > 0)
        code_highlight_languages.resolve(block.language)
    else
        code_highlight_languages.infer(alloc, block.code);
    const language = if (block.language.len > 0)
        block.language
    else if (profile) |inferred|
        inferred.label
    else
        "";
    const styled_code = if (profile) |resolved|
        try code_highlight.highlight(alloc, block.code, resolved, theme)
    else
        null;
    defer if (styled_code) |code| alloc.free(code);
    const code = styled_code orelse block.code;

    const max_code_width = maxCodeLineWidth(block.code);
    if (cols <= 5) {
        try renderUnboxedCode(alloc, code, cols, &rendered);
        return rendered.toOwnedSlice(alloc);
    }

    const panel_width = codePanelWidth(max_code_width, language, cols);
    if (language.len > 0) {
        try appendCodePanelHeader(alloc, &rendered, panel_width, language);
    } else {
        try appendCodePanelRule(alloc, &rendered, panel_width);
    }

    var start: usize = 0;
    var emitted_line = false;
    while (start < code.len) {
        const end = std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
        try appendCodePanelLine(alloc, &rendered, code[start..end], panel_width);
        emitted_line = true;
        if (end == code.len) break;
        start = end + 1;
    }
    if (!emitted_line) try appendCodePanelLine(alloc, &rendered, "", panel_width);
    try appendCodePanelRule(alloc, &rendered, panel_width);
    return rendered.toOwnedSlice(alloc);
}

const CodeStyle = struct {
    foreground: ?[]const u8 = null,

    fn apply(self: *CodeStyle, text: []const u8) void {
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] == 0x1b) {
                const end = display_width.ansiSequenceEnd(text, index);
                if (end > index) {
                    self.applySequence(text[index..end]);
                    index = end;
                    continue;
                }
            }
            const rune = display_width.decodeNextRune(text, index);
            index += rune.len;
        }
    }

    fn applySequence(self: *CodeStyle, sequence: []const u8) void {
        if (sequence.len < 4 or sequence[0] != 0x1b or sequence[1] != '[' or sequence[sequence.len - 1] != 'm') return;
        if (std.mem.startsWith(u8, sequence, "\x1b[38;5;")) {
            self.foreground = sequence;
        } else if (std.mem.eql(u8, sequence, "\x1b[39m") or std.mem.eql(u8, sequence, "\x1b[0m")) {
            self.foreground = null;
        }
    }
};

const VisibleUnit = struct {
    start: usize,
    len: usize,
    width: usize,
};

fn firstCodeGlyph(text: []const u8) ?VisibleUnit {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, index);
            if (end > index) {
                index = end;
                continue;
            }
        }
        const unit = display_width.displayUnitAt(text, index);
        if (unit.cell_width > 0) return .{ .start = index, .len = unit.byte_len, .width = unit.cell_width };
        index += unit.byte_len;
    }
    return null;
}

fn maxCodeLineWidth(code: []const u8) usize {
    var max_width: usize = 0;
    var start: usize = 0;
    while (start < code.len) {
        const end = std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
        max_width = @max(max_width, display_width.visibleWidth(code[start..end]));
        if (end == code.len) break;
        start = end + 1;
    }
    return max_width;
}

fn codePanelWidth(max_code_width: usize, language: []const u8, cols: u16) usize {
    const label_width = if (language.len == 0) 0 else @min(
        display_width.visibleWidth(language),
        @as(usize, cols) - 4,
    );
    return @min(@as(usize, cols), @max(@as(usize, 6), @max(max_code_width, label_width + 4)));
}

fn appendCodePanelHeader(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    panel_width: usize,
    language: []const u8,
) !void {
    const label_limit = panel_width - 4;
    const label_prefix = display_width.prefixByWidth(language, label_limit);
    const label = if (label_prefix.len > 0) label_prefix else "?";
    const label_width = display_width.visibleWidth(label);

    try out.appendSlice(alloc, "\x1b[2m─ ");
    try out.appendSlice(alloc, label);
    try out.append(alloc, ' ');
    var edge: usize = 0;
    while (edge < panel_width - 3 - label_width) : (edge += 1) try out.appendSlice(alloc, "─");
    try out.appendSlice(alloc, "\x1b[22m\n");
}

fn appendCodePanelRule(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    panel_width: usize,
) !void {
    try out.appendSlice(alloc, "\x1b[2m");
    var edge: usize = 0;
    while (edge < panel_width) : (edge += 1) try out.appendSlice(alloc, "─");
    try out.appendSlice(alloc, "\x1b[22m\n");
}

fn appendCodePanelLine(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
    panel_width: usize,
) !void {
    const indent = leadingCodeIndent(line);
    const indent_width = display_width.visibleWidth(indent);
    var remaining = line;
    var continuation = false;
    var style: CodeStyle = .{};
    if (remaining.len == 0) {
        try out.append(alloc, '\n');
        return;
    }
    while (remaining.len > 0) {
        const continuation_indent = if (continuation and indent_width < panel_width) indent else "";
        const available_width = panel_width - display_width.visibleWidth(continuation_indent);
        var prefix = display_width.prefixByWidthIgnoringAnsi(remaining, available_width);
        if (firstCodeGlyph(prefix) == null) {
            const rune = firstCodeGlyph(remaining) orelse {
                style.apply(remaining);
                break;
            };
            if (rune.width > available_width) {
                var fallback_style = style;
                fallback_style.apply(remaining[0..rune.start]);
                try appendCodeRow(alloc, out, continuation_indent, fallback_style, "?", fallback_style);
                style = fallback_style;
                remaining = remaining[rune.start + rune.len ..];
                continuation = true;
                continue;
            }
            prefix = remaining[0 .. rune.start + rune.len];
        }
        const row_style = style;
        style.apply(prefix);
        try appendCodeRow(alloc, out, continuation_indent, row_style, prefix, style);
        remaining = remaining[prefix.len..];
        continuation = true;
    }
}

fn leadingCodeIndent(line: []const u8) []const u8 {
    var index: usize = 0;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    return line[0..index];
}

fn appendCodeRow(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    leading: []const u8,
    before: CodeStyle,
    content: []const u8,
    after: CodeStyle,
) !void {
    try out.appendSlice(alloc, leading);
    if (before.foreground) |foreground| try out.appendSlice(alloc, foreground);
    try out.appendSlice(alloc, content);
    if (after.foreground != null) try out.appendSlice(alloc, "\x1b[0m");
    try out.append(alloc, '\n');
}

fn renderUnboxedCode(
    alloc: Allocator,
    code: []const u8,
    cols: u16,
    out: *std.ArrayList(u8),
) !void {
    var start: usize = 0;
    while (start < code.len) {
        const end = std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
        const line = code[start..end];
        const indent = leadingCodeIndent(line);
        const indent_width = display_width.visibleWidth(indent);
        var remaining = line;
        var continuation = false;
        var style: CodeStyle = .{};
        if (remaining.len == 0) {
            try out.append(alloc, '\n');
        } else while (remaining.len > 0) {
            const continuation_indent = if (continuation and indent_width < cols) indent else "";
            const available_width = @as(usize, cols) - display_width.visibleWidth(continuation_indent);
            var prefix = display_width.prefixByWidthIgnoringAnsi(remaining, available_width);
            if (firstCodeGlyph(prefix) == null) {
                const rune = firstCodeGlyph(remaining) orelse {
                    style.apply(remaining);
                    break;
                };
                if (rune.width > available_width) {
                    var fallback_style = style;
                    fallback_style.apply(remaining[0..rune.start]);
                    try out.appendSlice(alloc, continuation_indent);
                    if (fallback_style.foreground) |foreground| try out.appendSlice(alloc, foreground);
                    try out.append(alloc, '?');
                    if (fallback_style.foreground != null) try out.appendSlice(alloc, "\x1b[0m");
                    style = fallback_style;
                    remaining = remaining[rune.start + rune.len ..];
                    try out.append(alloc, '\n');
                    continuation = true;
                    continue;
                }
                prefix = remaining[0 .. rune.start + rune.len];
            }
            const row_style = style;
            style.apply(prefix);
            try out.appendSlice(alloc, continuation_indent);
            if (row_style.foreground) |foreground| try out.appendSlice(alloc, foreground);
            try out.appendSlice(alloc, prefix);
            if (style.foreground != null) try out.appendSlice(alloc, "\x1b[0m");
            try out.append(alloc, '\n');
            remaining = remaining[prefix.len..];
            continuation = true;
        }
        if (end == code.len) break;
        start = end + 1;
    }
}

fn sumWidths(widths: []const usize) usize {
    var total: usize = 0;
    for (widths) |width| total += width;
    return total;
}

fn appendTableBorder(alloc: Allocator, out: *std.ArrayList(u8), left: []const u8, middle: []const u8, right: []const u8, widths: []const usize) !void {
    try out.appendSlice(alloc, left);
    for (widths, 0..) |width, index| {
        if (index > 0) try out.appendSlice(alloc, middle);
        var count: usize = 0;
        while (count < width + 2) : (count += 1) try out.appendSlice(alloc, "─");
    }
    try out.appendSlice(alloc, right);
    try out.append(alloc, '\n');
}

fn renderBoxedGrid(alloc: Allocator, table: assistant_presentation.TablePayload, widths: []const usize, out: *std.ArrayList(u8)) !void {
    try appendTableBorder(alloc, out, "┌", "┬", "┐", widths);
    for (table.rows, 0..) |row, row_index| {
        try out.appendSlice(alloc, "│");
        for (widths, 0..) |width, col| {
            const cell: []const u8 = if (col < row.cells.len) row.cells[col] else "";
            const visible = display_width.visibleWidthIgnoringAnsi(cell);
            const pad = width -| visible;
            const alignment: assistant_presentation.TableColumnAlign = if (row_index == 0) .left else table.alignments[col];
            const left_pad = switch (alignment) {
                .left => 0,
                .right => pad,
                .center => pad / 2,
            };
            try out.append(alloc, ' ');
            try out.appendNTimes(alloc, ' ', left_pad);
            if (row_index == 0) {
                try assistant_presentation.writeTableHeaderCell(alloc, out, cell);
            } else {
                try out.appendSlice(alloc, cell);
            }
            try out.appendNTimes(alloc, ' ', pad - left_pad);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, "│");
        }
        try out.append(alloc, '\n');
        if (row_index == 0 and table.rows.len > 1) try appendTableBorder(alloc, out, "├", "┼", "┤", widths);
        if (row_index > 0 and row_index + 1 < table.rows.len) try appendTableBorder(alloc, out, "├", "┼", "┤", widths);
    }
    try appendTableBorder(alloc, out, "└", "┴", "┘", widths);
}

fn appendVerticalLine(alloc: Allocator, out: *std.ArrayList(u8), content: []const u8, inner_width: usize) !void {
    var remaining = content;
    if (remaining.len == 0) {
        try out.appendSlice(alloc, "│");
        try out.appendNTimes(alloc, ' ', inner_width);
        try out.appendSlice(alloc, "│\n");
        return;
    }
    while (remaining.len > 0) {
        var prefix = display_width.prefixByWidthIgnoringAnsi(remaining, inner_width);
        var consumed = prefix.len;
        if (prefix.len == 0) {
            const unit = display_width.displayUnitAt(remaining, 0);
            prefix = "?";
            consumed = unit.byte_len;
        }
        const visible = display_width.visibleWidthIgnoringAnsi(prefix);
        try out.appendSlice(alloc, "│");
        try out.appendSlice(alloc, prefix);
        try out.appendNTimes(alloc, ' ', inner_width -| visible);
        try out.appendSlice(alloc, "│\n");
        remaining = remaining[consumed..];
    }
}

fn renderBoxedVertical(alloc: Allocator, table: assistant_presentation.TablePayload, cols: u16, out: *std.ArrayList(u8)) !void {
    const inner_width: usize = cols - 2;
    try out.appendSlice(alloc, "┌");
    var edge: usize = 0;
    while (edge < inner_width) : (edge += 1) try out.appendSlice(alloc, "─");
    try out.appendSlice(alloc, "┐\n");
    for (table.rows[1..], 0..) |row, row_index| {
        for (table.alignments, 0..) |_, col| {
            var field: std.ArrayList(u8) = .empty;
            defer field.deinit(alloc);
            const header: []const u8 = if (col < table.rows[0].cells.len) table.rows[0].cells[col] else "";
            const value: []const u8 = if (col < row.cells.len) row.cells[col] else "";
            try field.appendSlice(alloc, header);
            try field.appendSlice(alloc, ": ");
            try field.appendSlice(alloc, value);
            try appendVerticalLine(alloc, out, field.items, inner_width);
        }
        if (row_index + 1 < table.rows.len - 1) {
            try out.appendSlice(alloc, "├");
            edge = 0;
            while (edge < inner_width) : (edge += 1) try out.appendSlice(alloc, "─");
            try out.appendSlice(alloc, "┤\n");
        }
    }
    try out.appendSlice(alloc, "└");
    edge = 0;
    while (edge < inner_width) : (edge += 1) try out.appendSlice(alloc, "─");
    try out.appendSlice(alloc, "┘\n");
}

fn renderUnboxedTable(alloc: Allocator, table: assistant_presentation.TablePayload, cols: u16, out: *std.ArrayList(u8)) !void {
    const width: usize = cols;
    for (table.rows[1..]) |row| for (table.alignments, 0..) |_, col| {
        const header: []const u8 = if (col < table.rows[0].cells.len) table.rows[0].cells[col] else "";
        const value: []const u8 = if (col < row.cells.len) row.cells[col] else "";
        var field: std.ArrayList(u8) = .empty;
        defer field.deinit(alloc);
        try field.appendSlice(alloc, header);
        try field.appendSlice(alloc, ": ");
        try field.appendSlice(alloc, value);
        const prefix = display_width.prefixByWidthIgnoringAnsi(field.items, width);
        try out.appendSlice(alloc, prefix);
        try out.append(alloc, '\n');
    };
}

const NoticeLine = struct {
    end: usize,
    next: usize,
};

const notice_osc8_prefix = "\x1b]8;";
const notice_osc8_close = "\x1b]8;;\x1b\\";

fn updateNoticeHyperlinkState(fragment: []const u8, active: *?[]const u8) void {
    var offset: usize = 0;
    while (std.mem.findPos(u8, fragment, offset, notice_osc8_prefix)) |start| {
        const sequence_end = display_width.ansiSequenceEnd(fragment, start);
        if (sequence_end <= start or sequence_end > fragment.len) return;
        const sequence = fragment[start..sequence_end];
        const terminator_len: usize = if (sequence[sequence.len - 1] == 0x07)
            1
        else if (sequence.len >= 2 and sequence[sequence.len - 2] == 0x1b and sequence[sequence.len - 1] == '\\')
            2
        else
            return;
        const payload = sequence[notice_osc8_prefix.len .. sequence.len - terminator_len];
        const separator = std.mem.findScalar(u8, payload, ';') orelse return;
        active.* = if (separator + 1 == payload.len)
            null
        else
            sequence;
        offset = sequence_end;
    }
}

fn skipNoticeWhitespace(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
    return index;
}

fn scanNoticeLine(text: []const u8, start: usize, max_width: usize) NoticeLine {
    std.debug.assert(max_width > 0);
    if (start >= text.len) return .{ .end = start, .next = start };

    var index = start;
    var width: usize = 0;
    var last_wrap_end: ?usize = null;
    var last_wrap_next: usize = start;
    while (index < text.len) {
        const byte = text[index];
        if (byte == 0x1b) {
            const sequence_end = display_width.ansiSequenceEnd(text, index);
            if (sequence_end <= index) return .{ .end = index, .next = index + 1 };
            index = sequence_end;
            continue;
        }
        if (byte == '\n' or byte == '\r') {
            const next = if (byte == '\r' and index + 1 < text.len and text[index + 1] == '\n')
                index + 2
            else
                index + 1;
            return .{ .end = index, .next = next };
        }
        if (byte == ' ' or byte == '\t') {
            const next = skipNoticeWhitespace(text, index);
            if (width + 1 > max_width) {
                return .{ .end = index, .next = next };
            }
            last_wrap_end = index;
            last_wrap_next = next;
            width += 1;
            index += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, index);
        const cell_width = unit.cell_width;
        if (width + cell_width > max_width) {
            if (last_wrap_end) |end| {
                if (end > start) return .{ .end = end, .next = last_wrap_next };
            }
            if (index == start) {
                return .{ .end = index + unit.byte_len, .next = index + unit.byte_len };
            }
            return .{ .end = index, .next = index };
        }
        width += cell_width;
        index += unit.byte_len;
        if (byte == '/' or byte == '\\') {
            last_wrap_end = index;
            last_wrap_next = index;
        }
    }
    return .{ .end = index, .next = index };
}

fn noticeLabelStyle(styles: Styles, tone: types.NoticeTone) []const u8 {
    return switch (tone) {
        .information => styles.notice_information_style,
        .success => styles.notice_success_style,
        .warning => styles.notice_warning_style,
        .@"error" => styles.notice_error_style,
        .cancelled => styles.notice_cancelled_style,
        .neutral => styles.system_notice_text_style,
    };
}

fn noticeContinuationIndent(text: []const u8, cursor: usize, cols: u16) usize {
    if (cols <= 2 or cursor >= text.len) return 0;
    if (text[cursor] == '\n' or text[cursor] == '\r') return 2;
    const unit = display_width.displayUnitAt(text, cursor);
    return if (unit.cell_width <= cols - 2) 2 else 0;
}

fn appendNoticeRow(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    logical: []const u8,
    label_end: usize,
    start: usize,
    end: usize,
    indent: usize,
    styles: Styles,
    tone: types.NoticeTone,
    active_hyperlink: *?[]const u8,
) !void {
    try out.appendNTimes(alloc, ' ', indent);
    if (active_hyperlink.*) |opener| try out.appendSlice(alloc, opener);
    if (start < @min(end, label_end)) {
        try out.appendSlice(alloc, noticeLabelStyle(styles, tone));
        try out.appendSlice(alloc, logical[start..@min(end, label_end)]);
        try out.appendSlice(alloc, styles.reset_style);
    }
    if (end > label_end) {
        try out.appendSlice(alloc, styles.system_notice_text_style);
        try out.appendSlice(alloc, logical[@max(start, label_end)..end]);
        try out.appendSlice(alloc, styles.reset_style);
    }
    if (start == end) try out.appendSlice(alloc, styles.reset_style);
    updateNoticeHyperlinkState(logical[start..end], active_hyperlink);
    if (active_hyperlink.* != null) try out.appendSlice(alloc, notice_osc8_close);
}

/// Returns an owned semantic notice block without surrounding blank rows.
pub fn renderSemanticNotice(
    alloc: Allocator,
    notice: types.SemanticNotice,
    styles: Styles,
    cols: u16,
) ![]u8 {
    var logical: std.ArrayList(u8) = .empty;
    defer logical.deinit(alloc);
    try logical.appendSlice(alloc, "● ");
    // An empty topic drops the "Topic:" label and renders the body alone.
    if (notice.topic.len > 0) {
        try logical.append(alloc, std.ascii.toUpper(notice.topic[0]));
        try logical.appendSlice(alloc, notice.topic[1..]);
        try logical.append(alloc, ':');
    }
    const label_end = logical.items.len;
    const body = std.mem.trimEnd(u8, notice.body, "\r\n");
    if (body.len > 0) {
        if (notice.topic.len > 0) try logical.append(alloc, ' ');
        try logical.appendSlice(alloc, body);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var cursor: usize = 0;
    var row: usize = 0;
    var active_hyperlink: ?[]const u8 = null;
    while (cursor < logical.items.len) : (row += 1) {
        if (row > 0) try out.append(alloc, '\n');
        const indent: usize = if (row > 0) noticeContinuationIndent(logical.items, cursor, cols) else 0;
        const available: usize = @max(@as(usize, cols) -| indent, 1);
        const line = scanNoticeLine(logical.items, cursor, available);
        try appendNoticeRow(
            &out,
            alloc,
            logical.items,
            label_end,
            cursor,
            line.end,
            indent,
            styles,
            notice.tone,
            &active_hyperlink,
        );
        std.debug.assert(line.next > cursor);
        cursor = line.next;
    }
    return out.toOwnedSlice(alloc);
}

const TranscriptPresentation = enum {
    compact,
    full,
};

pub fn renderEntryToBlock(
    alloc: Allocator,
    entry: TranscriptEntry,
    cols: u16,
    styles: Styles,
) !RenderedBlock {
    return renderEntryToBlockForPresentation(alloc, entry, cols, styles, .compact);
}

fn renderEntryToBlockForPresentation(
    alloc: Allocator,
    entry: TranscriptEntry,
    cols: u16,
    styles: Styles,
    presentation: TranscriptPresentation,
) !RenderedBlock {
    return renderEntryToBlockForPresentationInterruptible(
        alloc,
        entry,
        cols,
        styles,
        presentation,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

fn renderEntryToBlockForPresentationInterruptible(
    alloc: Allocator,
    entry: TranscriptEntry,
    cols: u16,
    styles: Styles,
    presentation: TranscriptPresentation,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !RenderedBlock {
    const kind = blockKindForEntry(entry);
    if (presentation == .compact and !isEntryVisibleInCompactPresentation(entry)) {
        return .{
            .kind = kind,
            .bytes = "",
            .stored_tail_newlines = 0,
        };
    }
    return switch (entry) {
        .raw_bytes => |e| if (e.class == .tool_status and presentation == .full) blk: {
            const full = try formatFullToolStatus(alloc, e.bytes, cols);
            break :blk try normalizeOwnedRenderedBlock(alloc, kind, full);
        } else if (e.class == .tool_status and toolStatusNeedsPreview(e.bytes, cols)) blk: {
            const preview = try formatToolStatusPreview(alloc, e.bytes, cols);
            break :blk try normalizeOwnedRenderedBlock(alloc, kind, preview);
        } else if (e.class == .diff_block and presentation == .compact) blk: {
            const compact = try reflowDiffBlock(alloc, e.bytes, cols);
            break :blk try normalizeOwnedRenderedBlock(alloc, kind, compact);
        } else try normalizeRenderedBlockTail(alloc, kind, e.bytes),
        .semantic_notice => |e| blk: {
            const rendered = try renderSemanticNotice(
                alloc,
                .{
                    .topic = e.topic,
                    .tone = e.tone,
                    .body = e.body,
                    .visibility = e.visibility,
                },
                styles,
                cols,
            );
            break :blk try normalizeOwnedRenderedBlock(alloc, kind, rendered);
        },
        .user_turn => |e| blk: {
            const card = try user_message_card.buildUserPromptCardWithSkillTokensForTerminalPresentationInterruptible(
                alloc,
                e.turn.text,
                e.turn.images,
                cols,
                e.skill_tokens,
                checkpoint,
            );
            break :blk try normalizeOwnedRenderedBlock(alloc, kind, card);
        },
        .assistant_turn => |e| blk: {
            const wrapped = try assistant_wrap.wrapTranscriptAssistantTextWithFinalityInterruptible(
                alloc,
                e.segments.text.items,
                cols,
                checkpoint,
            );
            const trimmed = trimAssistantBlockHead(wrapped.bytes);
            const trimmed_head_bytes = wrapped.bytes.len - trimmed.len;
            var block = try normalizeOwnedRenderedBlockWithAllocation(
                alloc,
                kind,
                trimmed,
                wrapped.bytes,
            );
            block.assistant_finalized_prefix_bytes =
                wrapped.finalized_prefix_bytes -| trimmed_head_bytes;
            break :blk block;
        },
        .assistant_table => |e| blk: {
            const gutter = assistant_wrap.gutterWidth(cols);
            const rendered = try renderTableForTranscript(alloc, e.table, cols -| gutter);
            defer alloc.free(rendered);
            const prefixed = try assistant_wrap.prefixStructuralRows(alloc, rendered, gutter);
            break :blk try normalizeOwnedRenderedBlock(alloc, kind, prefixed);
        },
        .assistant_code_block => |e| blk: {
            const gutter = assistant_wrap.gutterWidth(cols);
            const rendered = try renderCodeBlockForTranscriptWithTheme(
                alloc,
                e.block,
                cols -| gutter,
                styles.code_highlight_theme,
            );
            defer alloc.free(rendered);
            const prefixed = try assistant_wrap.prefixStructuralRows(alloc, rendered, gutter);
            break :blk try normalizeOwnedRenderedBlock(alloc, kind, prefixed);
        },
        .assistant_thematic_rule => blk: {
            const rendered = try renderThematicRuleForTranscript(alloc, cols);
            break :blk .{
                .kind = kind,
                .bytes = rendered,
                .stored_tail_newlines = 0,
                .allocation = rendered,
                .owned = true,
            };
        },
    };
}

fn normalizeOwnedRenderedBlock(
    alloc: Allocator,
    kind: TranscriptBlockKind,
    bytes: []const u8,
) !RenderedBlock {
    return normalizeOwnedRenderedBlockWithAllocation(alloc, kind, bytes, bytes);
}

fn normalizeOwnedRenderedBlockWithAllocation(
    alloc: Allocator,
    kind: TranscriptBlockKind,
    bytes: []const u8,
    allocation: []const u8,
) !RenderedBlock {
    errdefer alloc.free(allocation);
    var block = try normalizeRenderedBlockTail(alloc, kind, bytes);
    if (block.owned) {
        alloc.free(allocation);
    } else {
        block.allocation = allocation;
        block.owned = true;
    }
    return block;
}

pub fn renderEntriesForFullPresentationInterruptible(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
    sink: *const FullPresentationSink,
    out: *std.Io.Writer.Allocating,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !void {
    var sequence: BlockSequenceState = .{};

    for (entries, 0..) |entry, entry_index| {
        try build_checkpoint.tick(checkpoint);
        const entry_id = entry.id();
        if (sink.skip_entry(sink.context, entry, entry_index)) {
            try sink.before_entry(sink.context, entry_id, out);
            continue;
        }

        if (sink.override_kind(sink.context, entry)) |kind| {
            try out.writer.splatByteAll('\n', sequence.separatorNewlineCountBefore(kind));
            try sink.before_entry(sink.context, entry_id, out);
            const override_ends_with_newline = try sink.append_override(sink.context, entry, out);
            const detail = try sink.append_detail(sink.context, entry_id, out);
            sequence.observe(
                kind,
                if (detail.attached) detail.ends_with_newline else override_ends_with_newline,
                0,
            );
            continue;
        }

        const block = try renderEntryToBlockForPresentationInterruptible(
            alloc,
            entry,
            cols,
            styles,
            .full,
            checkpoint,
        );
        defer block.deinit(alloc);
        if (!renderedBlockHasContent(block)) continue;

        try out.writer.splatByteAll('\n', sequence.separatorNewlineCountBefore(block.kind));
        try sink.before_entry(sink.context, entry_id, out);
        try out.writer.writeAll(block.bytes);
        const detail = try sink.append_detail(sink.context, entry_id, out);
        sequence.observe(block.kind, detail.ends_with_newline, if (detail.attached) 0 else block.stored_tail_newlines);
    }

    try out.writer.splatByteAll('\n', sequence.finalNewlineCount());
}

fn renderedBlockHasContent(block: RenderedBlock) bool {
    return block.bytes.len > 0;
}

pub fn leadingWelcomeCutLine(alloc: Allocator, entries: []const TranscriptEntry, cols: u16, styles: Styles) !?usize {
    if (entries.len == 0) return null;
    for (entries[1..]) |entry| {
        switch (entry) {
            .user_turn, .assistant_turn, .assistant_table, .assistant_code_block, .assistant_thematic_rule => return null,
            .raw_bytes, .semantic_notice => {},
        }
    }
    const boundary = try leadingWelcomeBoundary(alloc, entries, cols, styles) orelse return null;
    return boundary.full_cut_line;
}

pub const LeadingWelcomeBoundary = struct {
    full_cut_line: usize,
    tail_replay_line: usize,
};

pub fn leadingWelcomeBoundary(alloc: Allocator, entries: []const TranscriptEntry, cols: u16, styles: Styles) !?LeadingWelcomeBoundary {
    if (entries.len == 0) return null;
    if (entries[0] != .raw_bytes or entries[0].raw_bytes.class != .welcome) return null;

    const welcome_block = try renderEntryToBlock(alloc, entries[0], cols, styles);
    defer welcome_block.deinit(alloc);
    if (!renderedBlockHasContent(welcome_block)) return null;
    const welcome_line_count = renderedHardLineCount(welcome_block.bytes);
    if (welcome_line_count == 0) return null;

    var next_kind: ?TranscriptBlockKind = null;
    for (entries[1..]) |entry| {
        const next_block = try renderEntryToBlock(alloc, entry, cols, styles);
        defer next_block.deinit(alloc);
        if (!renderedBlockHasContent(next_block)) continue;
        next_kind = next_block.kind;
        break;
    }
    const following_kind = next_kind orelse return null;

    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(alloc);
    try prefix.appendSlice(alloc, welcome_block.bytes);
    try appendBlockSeparator(&prefix, alloc, default_block_gap_policy.gapBetween(welcome_block.kind, following_kind));

    return .{
        .full_cut_line = renderedHardLineCount(prefix.items),
        .tail_replay_line = welcome_line_count - 1,
    };
}

fn renderedHardLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var total: usize = 1;
    for (bytes[0 .. bytes.len - 1]) |byte| {
        if (byte == '\n') total += 1;
    }
    return total;
}

const RenderedEntries = struct {
    bytes: []u8,
    target_entry_start_line: ?usize,
    target_entry_start_byte: ?usize,
};

const BlockSequenceState = struct {
    previous_kind: ?TranscriptBlockKind = null,
    previous_ends_with_newline: bool = false,
    emitted_any: bool = false,
    final_tail_newlines: usize = 0,

    fn gapRowsBefore(self: BlockSequenceState, next_kind: TranscriptBlockKind) u16 {
        if (!self.emitted_any) return 0;
        return default_block_gap_policy.gapBetween(self.previous_kind.?, next_kind);
    }

    fn separatorNewlineCountBefore(self: BlockSequenceState, next_kind: TranscriptBlockKind) u16 {
        if (!self.emitted_any) return 0;
        return blockSeparatorNewlineCount(self.previous_kind.?, next_kind) -| @intFromBool(self.previous_ends_with_newline);
    }

    fn observe(
        self: *BlockSequenceState,
        kind: TranscriptBlockKind,
        ends_with_newline: bool,
        tail_newlines: usize,
    ) void {
        self.previous_kind = kind;
        self.previous_ends_with_newline = ends_with_newline;
        self.final_tail_newlines = tail_newlines;
        self.emitted_any = true;
    }

    fn finalNewlineCount(self: BlockSequenceState) u16 {
        if (!self.emitted_any) return 0;
        return finalBlockTailNewlineCount(self.final_tail_newlines);
    }
};

const RenderEntriesOptions = struct {
    target_entry_id: ?u32 = null,
    target_byte_entry_id: ?u32 = null,
    finality_entry_ids: []const u32 = &.{},
    finality_entry_floor_bytes: []?usize = &.{},
    omitted_entry_id: ?u32 = null,
    entry_actions: []const EntryRenderAction = &.{},
    summary_entry_ids: []const ?u32 = &.{},
    summary_transcript_indices: []usize = &.{},
    line_provenance: ?*std.ArrayList(LineProvenance) = null,
    entry_overrides: []const EntryRenderOverride = &.{},

    fn resetSummaryIndices(self: RenderEntriesOptions) void {
        std.debug.assert(self.summary_entry_ids.len == self.summary_transcript_indices.len);
        @memset(self.summary_transcript_indices, 0);
    }

    fn shouldOmit(
        self: RenderEntriesOptions,
        entry_index: usize,
        entry: TranscriptEntry,
    ) bool {
        if (self.omitted_entry_id == entry.id()) return true;
        if (self.entry_actions.len == 0) return false;
        std.debug.assert(self.entry_actions.len > entry_index);
        return self.entry_actions[entry_index] == .hide;
    }

    fn overrideForEntry(
        self: RenderEntriesOptions,
        entry_index: usize,
        entry: TranscriptEntry,
    ) ?EntryRenderOverride {
        if (self.entry_actions.len > 0) {
            std.debug.assert(self.entry_actions.len > entry_index);
            return switch (self.entry_actions[entry_index]) {
                .override => |override| .{
                    .entry_id = entry.id(),
                    .kind = override.kind,
                    .bytes = override.bytes,
                },
                .keep, .hide => null,
            };
        }
        for (self.entry_overrides) |override| {
            if (override.entry_id == entry.id()) return override;
        }
        return null;
    }
};

const RenderEntriesBuilder = struct {
    out: std.ArrayList(u8) = .empty,
    sequence: BlockSequenceState = .{},
    line_index: usize = 0,
    target_entry_start_line: ?usize = null,
    target_entry_start_byte: ?usize = null,

    fn deinit(self: *RenderEntriesBuilder, alloc: Allocator) void {
        self.out.deinit(alloc);
    }

    fn appendSeparatorBefore(
        self: *RenderEntriesBuilder,
        alloc: Allocator,
        next_kind: TranscriptBlockKind,
        provenance: ?*std.ArrayList(LineProvenance),
    ) !void {
        if (!self.sequence.emitted_any) return;

        const gap_rows = self.sequence.gapRowsBefore(next_kind);
        const separator_newlines = self.sequence.separatorNewlineCountBefore(next_kind);
        try self.out.appendNTimes(alloc, '\n', separator_newlines);
        self.line_index += separator_newlines;
        if (provenance) |lines| {
            var gap_index: u16 = 0;
            while (gap_index < gap_rows) : (gap_index += 1) {
                try lines.append(alloc, .block_separator);
            }
        }
        debug_trace.logf(
            "transcript.block_gap",
            "prev={s} next={s} rows={d}",
            .{ @tagName(self.sequence.previous_kind.?), @tagName(next_kind), gap_rows },
        );
    }

    fn appendBlockProvenance(
        alloc: Allocator,
        provenance: ?*std.ArrayList(LineProvenance),
        entry: TranscriptEntry,
        block: RenderedBlock,
    ) !void {
        const lines = provenance orelse return;
        const source = LineProvenance{ .entry = .{
            .entry_id = entry.id(),
            .entry_class = entryClassForEntry(entry),
        } };
        var block_line: usize = 0;
        const block_lines = renderedHardLineCount(block.bytes);
        while (block_line < block_lines) : (block_line += 1) {
            try lines.append(alloc, source);
        }
    }

    fn appendBlock(
        self: *RenderEntriesBuilder,
        alloc: Allocator,
        entry: TranscriptEntry,
        block: RenderedBlock,
        options: RenderEntriesOptions,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !void {
        try self.appendSeparatorBefore(alloc, block.kind, options.line_provenance);

        const entry_id = entry.id();
        if (options.target_entry_id == entry_id) self.target_entry_start_line = self.line_index;
        if (options.target_byte_entry_id == entry_id) self.target_entry_start_byte = self.out.items.len;
        for (options.finality_entry_ids, 0..) |finality_entry_id, index| {
            if (finality_entry_id == entry_id) {
                options.finality_entry_floor_bytes[index] = self.out.items.len +
                    (block.assistant_finalized_prefix_bytes orelse 0);
            }
        }
        for (options.summary_entry_ids, 0..) |summary_entry_id, index| {
            if (summary_entry_id != null and summary_entry_id.? == entry_id) {
                options.summary_transcript_indices[index] = self.line_index + 1;
            }
        }

        try self.out.appendSlice(alloc, block.bytes);
        try appendBlockProvenance(alloc, options.line_provenance, entry, block);
        for (block.bytes) |byte| {
            try build_checkpoint.tick(checkpoint);
            if (byte == '\n') self.line_index += 1;
        }
        self.sequence.observe(block.kind, false, block.stored_tail_newlines);
    }

    fn finish(self: *RenderEntriesBuilder, alloc: Allocator) !RenderedEntries {
        try self.out.appendNTimes(alloc, '\n', self.sequence.finalNewlineCount());
        return .{
            .bytes = try self.out.toOwnedSlice(alloc),
            .target_entry_start_line = self.target_entry_start_line,
            .target_entry_start_byte = self.target_entry_start_byte,
        };
    }
};

/// Reflows structured entries at paint-time width and centralizes block spacing.
fn renderEntries(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
    options: RenderEntriesOptions,
) !RenderedEntries {
    return renderEntriesInterruptible(alloc, entries, cols, styles, options, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

fn renderEntriesInterruptible(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
    options: RenderEntriesOptions,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !RenderedEntries {
    std.debug.assert(options.finality_entry_ids.len == options.finality_entry_floor_bytes.len);
    options.resetSummaryIndices();
    if (options.entry_actions.len > 0) {
        std.debug.assert(options.entry_actions.len == entries.len);
    }

    var builder: RenderEntriesBuilder = .{};
    errdefer builder.deinit(alloc);

    for (entries, 0..) |entry, entry_index| {
        try build_checkpoint.tick(checkpoint);
        if (options.shouldOmit(entry_index, entry)) continue;
        if (options.overrideForEntry(entry_index, entry)) |override| {
            const block = try normalizeRenderedBlockTail(
                alloc,
                override.kind,
                override.bytes,
            );
            defer block.deinit(alloc);
            if (!renderedBlockHasContent(block)) continue;
            try builder.appendBlock(alloc, entry, block, options, checkpoint);
            continue;
        }
        const block = try renderEntryToBlockForPresentationInterruptible(
            alloc,
            entry,
            cols,
            styles,
            .compact,
            checkpoint,
        );
        defer block.deinit(alloc);
        if (!renderedBlockHasContent(block)) continue;

        try builder.appendBlock(alloc, entry, block, options, checkpoint);
    }

    return builder.finish(alloc);
}

pub fn renderEntriesToBytes(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
) ![]u8 {
    return (try renderEntries(alloc, entries, cols, styles, .{})).bytes;
}

pub fn renderEntriesWithOverridesToBytes(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
    entry_overrides: []const EntryRenderOverride,
) ![]u8 {
    return (try renderEntries(alloc, entries, cols, styles, .{
        .entry_overrides = entry_overrides,
    })).bytes;
}

pub fn renderEntriesWithProjectionToBytes(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
    entry_actions: []const EntryRenderAction,
) ![]u8 {
    return (try renderEntries(alloc, entries, cols, styles, .{
        .entry_actions = entry_actions,
    })).bytes;
}

pub fn renderedEntryStartLine(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    entry_id: u32,
    cols: u16,
    styles: Styles,
) !?usize {
    const rendered = try renderEntries(alloc, entries, cols, styles, .{ .target_entry_id = entry_id });
    defer alloc.free(rendered.bytes);
    return rendered.target_entry_start_line;
}

pub const TranscriptFlowBytes = struct {
    bytes: []u8,
    trailing_boundary_blank_rows: u16,
    target_entry_start_line: ?usize = null,
};

pub fn renderEntriesToFlowBytes(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
) !TranscriptFlowBytes {
    return renderEntriesToFlowBytesForEntry(alloc, entries, cols, styles, null);
}

pub fn renderEntriesToFlowBytesForEntry(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
    target_entry_id: ?u32,
) !TranscriptFlowBytes {
    const rendered = try renderEntries(alloc, entries, cols, styles, .{ .target_entry_id = target_entry_id });
    errdefer alloc.free(rendered.bytes);

    const boundary = splitTrailingBoundaryRows(rendered.bytes);
    if (boundary.content_len == rendered.bytes.len) {
        return .{
            .bytes = rendered.bytes,
            .trailing_boundary_blank_rows = boundary.blank_rows,
            .target_entry_start_line = rendered.target_entry_start_line,
        };
    }

    const trimmed = try alloc.dupe(u8, rendered.bytes[0..boundary.content_len]);
    alloc.free(rendered.bytes);
    return .{
        .bytes = trimmed,
        .trailing_boundary_blank_rows = boundary.blank_rows,
        .target_entry_start_line = rendered.target_entry_start_line,
    };
}

pub const TranscriptPreparationBytes = struct {
    bytes: []u8,
    trailing_boundary_blank_rows: u16,
    target_entry_start_line: ?usize = null,
    target_entry_start_byte: ?usize = null,
    folded_summary_indices: []usize,
    line_provenance: []const LineProvenance = &.{},

    pub fn deinit(self: *TranscriptPreparationBytes, alloc: Allocator) void {
        alloc.free(self.bytes);
        alloc.free(self.folded_summary_indices);
        if (self.line_provenance.len > 0) alloc.free(self.line_provenance);
        self.* = undefined;
    }
};

pub const TranscriptPreparationOptions = struct {
    target_entry_id: ?u32 = null,
    target_byte_entry_id: ?u32 = null,
    finality_entry_ids: []const u32 = &.{},
    /// Parallel to `finality_entry_ids`. Each rendered nomination writes the
    /// first byte that remains mutable; immutable entries use their start.
    finality_entry_floor_bytes: []?usize = &.{},
    omitted_entry_id: ?u32 = null,
    entry_actions: []const EntryRenderAction = &.{},
    folded_summary_entry_ids: []const ?u32 = &.{},
    capture_provenance: bool = false,
    entry_overrides: []const EntryRenderOverride = &.{},
};

pub fn renderEntriesForPreparation(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
    options: TranscriptPreparationOptions,
) !TranscriptPreparationBytes {
    return renderEntriesForPreparationInterruptible(
        alloc,
        entries,
        cols,
        styles,
        options,
        null,
    ) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn renderEntriesForPreparationInterruptible(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
    options: TranscriptPreparationOptions,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !TranscriptPreparationBytes {
    const summary_indices = try alloc.alloc(usize, options.folded_summary_entry_ids.len);
    errdefer alloc.free(summary_indices);
    var line_provenance: std.ArrayList(LineProvenance) = .empty;
    errdefer line_provenance.deinit(alloc);
    const rendered = try renderEntriesInterruptible(
        alloc,
        entries,
        cols,
        styles,
        .{
            .target_entry_id = options.target_entry_id,
            .target_byte_entry_id = options.target_byte_entry_id,
            .finality_entry_ids = options.finality_entry_ids,
            .finality_entry_floor_bytes = options.finality_entry_floor_bytes,
            .omitted_entry_id = options.omitted_entry_id,
            .entry_actions = options.entry_actions,
            .summary_entry_ids = options.folded_summary_entry_ids,
            .summary_transcript_indices = summary_indices,
            .line_provenance = if (options.capture_provenance) &line_provenance else null,
            .entry_overrides = options.entry_overrides,
        },
        checkpoint,
    );
    errdefer alloc.free(rendered.bytes);

    const boundary = splitTrailingBoundaryRows(rendered.bytes);
    const kept_line_count = renderedHardLineCount(rendered.bytes[0..boundary.content_len]);
    if (options.capture_provenance) {
        std.debug.assert(kept_line_count <= line_provenance.items.len);
        line_provenance.items.len = kept_line_count;
    }
    const owned_provenance = if (options.capture_provenance)
        try line_provenance.toOwnedSlice(alloc)
    else
        &.{};
    errdefer if (owned_provenance.len > 0) alloc.free(owned_provenance);
    if (boundary.content_len == rendered.bytes.len) {
        return .{
            .bytes = rendered.bytes,
            .trailing_boundary_blank_rows = boundary.blank_rows,
            .target_entry_start_line = rendered.target_entry_start_line,
            .target_entry_start_byte = rendered.target_entry_start_byte,
            .folded_summary_indices = summary_indices,
            .line_provenance = owned_provenance,
        };
    }

    const trimmed = try alloc.dupe(u8, rendered.bytes[0..boundary.content_len]);
    alloc.free(rendered.bytes);
    return .{
        .bytes = trimmed,
        .trailing_boundary_blank_rows = boundary.blank_rows,
        .target_entry_start_line = rendered.target_entry_start_line,
        .target_entry_start_byte = rendered.target_entry_start_byte,
        .folded_summary_indices = summary_indices,
        .line_provenance = owned_provenance,
    };
}

const BoundarySplit = struct {
    content_len: usize,
    blank_rows: u16,
};

fn splitTrailingBoundaryRows(bytes: []const u8) BoundarySplit {
    var blank_rows: usize = 0;
    var content_len = if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') bytes.len - 1 else bytes.len;
    while (content_len > 0) {
        const line_start = if (std.mem.findScalarLast(u8, bytes[0..content_len], '\n')) |newline|
            newline + 1
        else
            0;
        if (!isBoundaryBlankLine(bytes[line_start..content_len])) break;
        blank_rows += 1;
        content_len = if (line_start > 0) line_start - 1 else 0;
    }

    return .{
        .content_len = content_len,
        .blank_rows = @intCast(@min(blank_rows, @as(usize, std.math.maxInt(u16)))),
    };
}

fn isBoundaryBlankLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) {
        const byte = line[i];
        if (byte == 0x1b) {
            const end = display_width.ansiSequenceEnd(line, i);
            if (end <= i) return false;
            i = end;
            continue;
        }
        switch (byte) {
            ' ', '\t', '\r' => i += 1,
            else => return false,
        }
    }
    return true;
}

pub fn stripTrailingNewline(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\n') return text[0 .. text.len - 1];
    return text;
}

fn trimAssistantBlockHead(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and text[start] == '\n') : (start += 1) {}
    return text[start..];
}

pub fn isVisuallyBlankLine(text: []const u8) bool {
    return display_width.visibleWidthIgnoringAnsi(stripTrailingNewline(text)) == 0;
}

pub fn trimBlockTail(bytes: []const u8) []const u8 {
    var end = if (trailingAnsiOnlySuffixAfterFinalNewline(bytes)) |suffix| bytes.len - suffix.len else bytes.len;
    while (end > 0 and bytes[end - 1] == '\n') : (end -= 1) {}
    return bytes[0..end];
}

fn isAnsiOnlyTail(bytes: []const u8) bool {
    if (bytes.len == 0) return false;

    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] != 0x1b) return false;
        const next = display_width.ansiSequenceEnd(bytes, i);
        if (next <= i) return false;
        i = next;
    }
    return true;
}

fn trailingAnsiOnlySuffixAfterFinalNewline(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] == '\n') return null;
    const newline = std.mem.findScalarLast(u8, bytes, '\n') orelse return null;
    const suffix = bytes[newline + 1 ..];
    return if (isAnsiOnlyTail(suffix)) suffix else null;
}

fn normalizeRenderedBlockTail(alloc: Allocator, kind: TranscriptBlockKind, bytes: []const u8) !RenderedBlock {
    const ansi_suffix = trailingAnsiOnlySuffixAfterFinalNewline(bytes);
    const logical_end = if (ansi_suffix) |suffix| bytes.len - suffix.len else bytes.len;
    var tail_newlines: usize = 0;
    var content_end = logical_end;
    while (content_end > 0 and bytes[content_end - 1] == '\n') : (content_end -= 1) {
        tail_newlines += 1;
    }

    if (ansi_suffix) |suffix| {
        if (tail_newlines > 0) {
            const normalized = try alloc.alloc(u8, content_end + suffix.len);
            @memcpy(normalized[0..content_end], bytes[0..content_end]);
            @memcpy(normalized[content_end..], suffix);
            return .{
                .kind = kind,
                .bytes = normalized,
                .stored_tail_newlines = tail_newlines,
                .allocation = normalized,
                .owned = true,
            };
        }
    }

    return .{
        .kind = kind,
        .bytes = bytes[0..content_end],
        .stored_tail_newlines = tail_newlines,
        .owned = false,
    };
}

pub fn tailVisibleBlockKind(entries: []const TranscriptEntry) ?TranscriptBlockKind {
    return tailVisibleBlockKindOmittingEntries(entries, null, &.{}, .full);
}

pub fn compactTailVisibleBlockKind(entries: []const TranscriptEntry) ?TranscriptBlockKind {
    return tailVisibleBlockKindOmittingEntries(entries, null, &.{}, .compact);
}

pub fn compactTailVisibleBlockKindWithoutEntry(
    entries: []const TranscriptEntry,
    omitted_entry_id: u32,
) ?TranscriptBlockKind {
    return tailVisibleBlockKindOmittingEntries(entries, omitted_entry_id, &.{}, .compact);
}

pub fn compactTailVisibleBlockKindForProjection(
    entries: []const TranscriptEntry,
    omitted_entry_id: ?u32,
    entry_actions: []const EntryRenderAction,
) ?TranscriptBlockKind {
    return tailVisibleBlockKindOmittingEntries(
        entries,
        omitted_entry_id,
        entry_actions,
        .compact,
    );
}

fn tailVisibleBlockKindOmittingEntries(
    entries: []const TranscriptEntry,
    omitted_entry_id: ?u32,
    entry_actions: []const EntryRenderAction,
    presentation: TranscriptPresentation,
) ?TranscriptBlockKind {
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        const entry = entries[index];
        if (omitted_entry_id == entry.id()) continue;
        if (entry_actions.len > 0) {
            std.debug.assert(entry_actions.len == entries.len);
            if (entry_actions[index] == .hide) continue;
        }
        if (presentation == .compact and !isEntryVisibleInCompactPresentation(entry)) continue;
        switch (entry) {
            .raw_bytes => |e| {
                if (trimBlockTail(e.bytes).len == 0) continue;
                return blockKindForRawClass(e.class);
            },
            .semantic_notice => |e| {
                if (e.topic.len == 0 and e.body.len == 0) continue;
                return blockKindForNoticeTone(e.tone);
            },
            .user_turn => return .user_turn,
            .assistant_turn => |e| {
                if (e.segments.text.items.len == 0) continue;
                return .assistant_turn;
            },
            .assistant_table => return .assistant_table,
            .assistant_code_block => return .assistant_code_block,
            .assistant_thematic_rule => return .assistant_thematic_rule,
        }
    }
    return null;
}

pub fn footerBoundaryGapRowsForTail(kind: ?TranscriptBlockKind) u16 {
    return switch (kind orelse return 0) {
        .assistant_turn,
        .turn_summary,
        .tool_status,
        .system_notice,
        .error_notice,
        .cancel_notice,
        .subagent_status,
        => 1,
        else => 0,
    };
}

fn appendBlockSeparator(out: *std.ArrayList(u8), alloc: Allocator, gap_rows: u16) !void {
    try out.appendNTimes(alloc, '\n', 1 + gap_rows);
}

pub fn blockSeparatorNewlineCount(prev: TranscriptBlockKind, next: TranscriptBlockKind) u16 {
    return 1 + default_block_gap_policy.gapBetween(prev, next);
}

pub fn finalBlockTailNewlineCount(stored_tail_newlines: usize) u16 {
    return if (stored_tail_newlines == 0) 0 else if (stored_tail_newlines > 1) 2 else 1;
}

pub const RenderedBlock = struct {
    kind: TranscriptBlockKind,
    bytes: []const u8,
    stored_tail_newlines: usize,
    allocation: []const u8 = &.{},
    owned: bool = false,
    assistant_finalized_prefix_bytes: ?usize = null,

    pub fn deinit(self: RenderedBlock, alloc: Allocator) void {
        if (self.owned) alloc.free(self.allocation);
    }
};

pub fn transcriptLineCount(text: []const u8) usize {
    var total: usize = 1;
    for (text) |byte| {
        if (byte == '\n') total += 1;
    }
    return total;
}

fn appendWithoutAsciiWhitespace(out: *std.ArrayList(u8), alloc: Allocator, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        ' ', '\t', '\r', '\n' => {},
        else => try out.append(alloc, byte),
    };
}
