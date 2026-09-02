const std = @import("std");
const core_types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const message = @import("../shared/message.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const image_attachments = @import("../images/image_attachments.zig");
const generation_usage_provider = @import("generation_usage_provider.zig");
const web_fetch_artifacts = @import("web_fetch_artifacts.zig");
const command_replay_store = @import("command_replay_store.zig");
pub const session_usage = @import("session_usage.zig");
pub const profile_usage_runtime = @import("profile_usage_runtime.zig");
const command_contract = @import("../execution/command_contract.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const Allocator = std.mem.Allocator;


const compact_continuation_preamble = "This session is being continued from earlier compacted context. The summary below covers the earlier portion of the conversation.\n\n";
const compact_recent_messages_note = "Recent conversation turns are preserved verbatim.";
const compact_direct_resume_instruction = "Continue the conversation from where it left off without asking the user to repeat context. Resume directly.";
const compact_summary_max_chars: usize = 1200;
const compact_summary_max_lines: usize = 24;
const compact_summary_max_line_chars: usize = 160;

pub const interrupted_turn_notice: core_types.SemanticNotice = .{
    .topic = "system",
    .tone = .cancelled,
    .body = "cancelled",
};

pub const failed_turn_notice: core_types.SemanticNotice = .{
    .topic = "system",
    .tone = .@"error",
    .body = "failed",
};

pub fn interruptedTurnNotice(entry: InterruptedHistoryTurn) core_types.SemanticNotice {
    return switch (entry.terminal_reason) {
        .cancelled => interrupted_turn_notice,
        .failed => failed_turn_notice,
    };
}

pub const interrupted_turn_context =
    "<turn_aborted>\n" ++
    "The previous turn ended before completion. Any tools or commands may have partially executed. " ++
    "Do not continue this request unless the user explicitly asks to continue.\n" ++
    "</turn_aborted>";

pub fn projectSnapshotLocator(buffer: []u8, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return path;
    return std.fmt.bufPrint(buffer, "images/{s}", .{std.fs.path.basename(path)});
}

pub const interrupted_before_completion_output = "The previous response ended before completion.";
pub const aborted_tool_output = "aborted by user";

/// Conversation language tag stored in session records.
pub const ConversationLanguage = core_types.ConversationLanguage;
/// Image attachment metadata stored on user turns.
pub const ImageAttachment = core_types.ImageAttachment;
/// User-side text and image attachments for a stored history turn.
pub const UserTurn = core_types.UserTurn;
/// Gateway tool call metadata stored when an interrupted turn is cancelled during a tool call.
pub const ToolCall = core_types.ToolCall;
/// Stored assistant response paired with the user turn that produced it.
pub const AssistantHistoryTurn = core_types.AssistantHistoryTurn;
/// Stored background command metadata paired with the user turn that produced it.
pub const BackgroundCommandHistoryTurn = core_types.BackgroundCommandHistoryTurn;
pub const StableBackgroundRecordId = core_types.StableBackgroundRecordId;
pub const CancelledCommandPresentation = core_types.CancelledCommandPresentation;
/// Stored interrupted turn marker, optionally paired with the active tool call.
pub const InterruptedHistoryTurn = core_types.InterruptedHistoryTurn;
pub const InterruptedTerminalReason = core_types.InterruptedTerminalReason;

fn formatInterruptedToolOutput(
    alloc: Allocator,
    entry: InterruptedHistoryTurn,
) ![]u8 {
    const presentation = entry.cancelled_command orelse
        return alloc.dupe(u8, aborted_tool_output);
    const replay = presentation.output_replay orelse
        return alloc.dupe(u8, aborted_tool_output);
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return alloc.dupe(u8, aborted_tool_output),
    };
    return command_replay_store.appendModelHandleNotice(
        alloc,
        aborted_tool_output,
        descriptor.handle,
    ) catch |err| switch (err) {
        error.InvalidReplayHandle => {
            debug_trace.logf(
                "session",
                "cancelled command replay handle omitted from model context handle_bytes={d}",
                .{descriptor.handle.len},
            );
            return alloc.dupe(u8, aborted_tool_output);
        },
        else => return err,
    };
}

/// Stored compacted context summary produced by core history compaction.
pub const CompactedSummaryHistoryTurn = core_types.CompactedSummaryHistoryTurn;
/// One persisted session history record.
pub const HistoryTurn = core_types.HistoryTurn;
pub const freeUserTurn = core_types.freeUserTurn;
pub const dupeUserTurn = core_types.dupeUserTurn;
pub const max_work_id_bytes: usize = 128;

pub const WorkIdAssociation = enum {
    none,
    copy_event,
    already_associated,
};

pub const WorkIdError = error{
    InvalidWorkId,
    ConflictingWorkId,
};

pub fn validateWorkId(work_id: []const u8) WorkIdError!void {
    if (work_id.len == 0 or work_id.len > max_work_id_bytes or
        !std.unicode.utf8ValidateSlice(work_id) or
        std.mem.indexOfScalar(u8, work_id, 0) != null)
    {
        return error.InvalidWorkId;
    }
}

pub fn historyTurnWorkId(turn: HistoryTurn) ?[]const u8 {
    return switch (turn) {
        .assistant => |entry| entry.user.work_id,
        .background_command => |entry| entry.user.work_id,
        .interrupted => |entry| entry.user.work_id,
        .compacted_summary => null,
    };
}

/// Purely decides how authoritative event provenance relates to one turn.
pub fn decideWorkIdAssociation(
    turn: HistoryTurn,
    event_work_id: ?[]const u8,
) WorkIdError!WorkIdAssociation {
    const turn_work_id = historyTurnWorkId(turn);
    if (turn_work_id) |work_id| try validateWorkId(work_id);
    if (event_work_id) |work_id| try validateWorkId(work_id);

    if (event_work_id == null) {
        return if (turn_work_id == null) .none else error.ConflictingWorkId;
    }
    if (turn == .compacted_summary) return error.ConflictingWorkId;
    if (turn_work_id) |work_id| {
        return if (std.mem.eql(u8, work_id, event_work_id.?))
            .already_associated
        else
            error.ConflictingWorkId;
    }
    return .copy_event;
}

/// Installs a separately owned work ID after pure association succeeds.
pub fn copyWorkIdToTurn(
    alloc: Allocator,
    turn: *HistoryTurn,
    work_id: []const u8,
) (Allocator.Error || WorkIdError)!void {
    if (try decideWorkIdAssociation(turn.*, work_id) != .copy_event) return;
    const owned = try alloc.dupe(u8, work_id);
    switch (turn.*) {
        .assistant => |*entry| entry.user.work_id = owned,
        .background_command => |*entry| entry.user.work_id = owned,
        .interrupted => |*entry| entry.user.work_id = owned,
        .compacted_summary => unreachable,
    }
}

pub const freeHistoryTurn = core_types.freeHistoryTurn;
pub const dupeToolCall = core_types.dupeToolCall;
pub const freeToolCall = core_types.freeToolCall;
pub const dupeCompletedToolNames = core_types.dupeCompletedToolNames;
pub const freeCompletedToolNames = core_types.freeCompletedToolNames;
pub const ExecutionMemory = core_types.ExecutionMemory;
pub const ToolExecutionStep = core_types.ToolExecutionStep;
pub const PersistedToolResult = core_types.PersistedToolResult;
pub const PersistedToolStatus = core_types.PersistedToolStatus;
pub const FileEvidence = core_types.FileEvidence;
pub const FileEvidenceAction = core_types.FileEvidenceAction;
pub const freeExecutionMemory = core_types.freeExecutionMemory;
pub const freeToolCallSlice = core_types.freeToolCallSlice;
pub const freePersistedToolResults = core_types.freePersistedToolResults;

/// Builds a sorted, independently owned attachment catalog from complete
/// canonical history plus current-turn images. The caller frees the returned
/// slice with `core_types.freeImageAttachmentSlice` using the same allocator.
pub fn collect_image_catalog(
    alloc: Allocator,
    canonical_history: []const HistoryTurn,
    current_images: []const ImageAttachment,
) (Allocator.Error || error{
    ImageCatalogTooLarge,
    InvalidImageId,
    DuplicateImageId,
})![]ImageAttachment {
    var attachment_count = current_images.len;
    for (canonical_history) |turn| {
        attachment_count = std.math.add(
            usize,
            attachment_count,
            images_for_history_turn(turn).len,
        ) catch return error.ImageCatalogTooLarge;
    }
    if (attachment_count == 0) return &.{};

    const catalog = try alloc.alloc(ImageAttachment, attachment_count);
    errdefer alloc.free(catalog);
    var copied: usize = 0;
    errdefer for (catalog[0..copied]) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    };

    for (canonical_history) |turn| {
        for (images_for_history_turn(turn)) |attachment| {
            catalog[copied] = try dupeImageAttachment(alloc, attachment);
            copied += 1;
        }
    }
    for (current_images) |attachment| {
        catalog[copied] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }

    sort_utils.sort(ImageAttachment, catalog, {}, image_id_less_than);
    var previous_id: ?usize = null;
    for (catalog) |attachment| {
        if (attachment.id == 0) return error.InvalidImageId;
        if (previous_id == attachment.id) return error.DuplicateImageId;
        previous_id = attachment.id;
    }
    std.debug.assert(image_attachments.imageAttachmentsSortedById(catalog));
    return catalog;
}

/// Rebuilds an owned catalog after queue review replaces the current-turn
/// attachments. Historical authority is retained; the old current slice must
/// still match the catalog exactly or the replacement is rejected as stale.
pub fn replace_image_catalog_current_images(
    alloc: Allocator,
    catalog: []const ImageAttachment,
    old_current_images: []const ImageAttachment,
    new_current_images: []const ImageAttachment,
) (Allocator.Error || error{
    ImageCatalogTooLarge,
    InvalidImageId,
    DuplicateImageId,
    StaleImageCatalog,
})![]ImageAttachment {
    try validate_image_catalog(catalog);

    for (old_current_images, 0..) |old_current, index| {
        if (old_current.id == 0) return error.InvalidImageId;
        for (old_current_images[0..index]) |prior| {
            if (prior.id == old_current.id) return error.DuplicateImageId;
        }
        const authorized = image_attachment_for_id(catalog, old_current.id) orelse
            return error.StaleImageCatalog;
        if (!image_attachments_equal(authorized, old_current)) return error.StaleImageCatalog;
    }

    const retained_count = std.math.sub(usize, catalog.len, old_current_images.len) catch
        return error.StaleImageCatalog;
    const attachment_count = std.math.add(
        usize,
        retained_count,
        new_current_images.len,
    ) catch return error.ImageCatalogTooLarge;
    if (attachment_count == 0) return &.{};

    const replacement = try alloc.alloc(ImageAttachment, attachment_count);
    errdefer alloc.free(replacement);
    var copied: usize = 0;
    errdefer for (replacement[0..copied]) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    };

    for (catalog) |attachment| {
        if (image_attachment_for_id(old_current_images, attachment.id) != null) continue;
        replacement[copied] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    std.debug.assert(copied == retained_count);
    for (new_current_images) |attachment| {
        replacement[copied] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }

    sort_utils.sort(ImageAttachment, replacement, {}, image_id_less_than);
    try validate_image_catalog(replacement);
    return replacement;
}

/// Returns a new owned catalog containing any image authority introduced by a
/// completed history turn. Existing IDs must either match exactly or the
/// queued catalog is rejected as stale.
pub fn merge_image_catalog_history_turn(
    alloc: Allocator,
    catalog: []const ImageAttachment,
    turn: HistoryTurn,
) (Allocator.Error || error{
    ImageCatalogTooLarge,
    InvalidImageId,
    DuplicateImageId,
    StaleImageCatalog,
})![]ImageAttachment {
    try validate_image_catalog(catalog);
    const additions = images_for_history_turn(turn);
    var missing_count: usize = 0;
    for (additions, 0..) |addition, index| {
        if (addition.id == 0) return error.InvalidImageId;
        for (additions[0..index]) |prior| {
            if (prior.id == addition.id) return error.DuplicateImageId;
        }
        if (image_attachment_for_id(catalog, addition.id)) |existing| {
            if (!image_attachments_equal(existing, addition)) return error.StaleImageCatalog;
        } else {
            missing_count += 1;
        }
    }

    const attachment_count = std.math.add(usize, catalog.len, missing_count) catch
        return error.ImageCatalogTooLarge;
    if (attachment_count == 0) return &.{};
    const merged = try alloc.alloc(ImageAttachment, attachment_count);
    errdefer alloc.free(merged);
    var copied: usize = 0;
    errdefer for (merged[0..copied]) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    };
    for (catalog) |attachment| {
        merged[copied] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    for (additions) |attachment| {
        if (image_attachment_for_id(catalog, attachment.id) != null) continue;
        merged[copied] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    sort_utils.sort(ImageAttachment, merged, {}, image_id_less_than);
    try validate_image_catalog(merged);
    return merged;
}

fn validate_image_catalog(catalog: []const ImageAttachment) error{
    InvalidImageId,
    DuplicateImageId,
}!void {
    var previous_id: ?usize = null;
    for (catalog) |attachment| {
        if (attachment.id == 0) return error.InvalidImageId;
        if (previous_id != null and previous_id.? >= attachment.id) {
            if (previous_id.? == attachment.id) return error.DuplicateImageId;
            return error.InvalidImageId;
        }
        previous_id = attachment.id;
    }
}

fn image_attachment_for_id(
    attachments: []const ImageAttachment,
    id: usize,
) ?ImageAttachment {
    for (attachments) |attachment| {
        if (attachment.id == id) return attachment;
    }
    return null;
}

fn image_attachments_equal(lhs: ImageAttachment, rhs: ImageAttachment) bool {
    return lhs.id == rhs.id and
        std.mem.eql(u8, lhs.path, rhs.path) and
        std.mem.eql(u8, lhs.media_type, rhs.media_type) and
        optionalBytesEqual(lhs.snapshot_path, rhs.snapshot_path) and
        optionalBytesEqual(lhs.snapshot_sha256, rhs.snapshot_sha256);
}

fn optionalBytesEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn images_for_history_turn(turn: HistoryTurn) []const ImageAttachment {
    return switch (turn) {
        .compacted_summary => &.{},
        .assistant => |entry| entry.user.images,
        .background_command => |entry| entry.user.images,
        .interrupted => |entry| entry.user.images,
    };
}

fn mutable_images_for_history_turn(turn: *HistoryTurn) []ImageAttachment {
    return switch (turn.*) {
        .compacted_summary => &.{},
        .assistant => |*entry| entry.user.images,
        .background_command => |*entry| entry.user.images,
        .interrupted => |*entry| entry.user.images,
    };
}

fn mutable_images_slice_for_history_turn(turn: *HistoryTurn) ?*[]ImageAttachment {
    return switch (turn.*) {
        .compacted_summary => null,
        .assistant => |*entry| &entry.user.images,
        .background_command => |*entry| &entry.user.images,
        .interrupted => |*entry| &entry.user.images,
    };
}

fn user_text_for_history_turn(turn: HistoryTurn) []const u8 {
    return switch (turn) {
        .compacted_summary => "",
        .assistant => |entry| entry.user.text,
        .background_command => |entry| entry.user.text,
        .interrupted => |entry| entry.user.text,
    };
}

const LegacyImagePlaceholderIterator = struct {
    text: []const u8,
    offset: usize = 0,

    const prefix = "[Image #";
    const Slot = struct {
        id: ?usize,
        start: usize,
        length: usize,
    };

    fn next(self: *@This()) ?Slot {
        const relative_start = std.mem.indexOf(u8, self.text[self.offset..], prefix) orelse
            return null;
        const start = self.offset + relative_start;
        if (image_attachments.matchImagePlaceholder(self.text, start)) |match| {
            self.offset = start + match.length;
            return .{ .id = match.id, .start = start, .length = match.length };
        }

        const body_start = start + prefix.len;
        self.offset = if (std.mem.indexOfScalar(u8, self.text[body_start..], ']')) |relative_end|
            body_start + relative_end + 1
        else
            body_start;
        return .{ .id = null, .start = start, .length = self.offset - start };
    }
};

const LegacyImageRepair = struct {
    turn_index: usize,
    image_index: usize,
    placeholder: ?LegacyImagePlaceholderIterator.Slot,
    assigned_id: usize = 0,
};

const LegacyTurnTextRepair = struct {
    turn_index: usize,
    text: []u8,
};

fn history_placeholder_id_count(history: []const HistoryTurn, id: usize) usize {
    var count: usize = 0;
    for (history) |turn| {
        var placeholders = LegacyImagePlaceholderIterator{
            .text = user_text_for_history_turn(turn),
        };
        while (placeholders.next()) |placeholder| {
            if (placeholder.id != null and placeholder.id.? == id) count += 1;
        }
    }
    return count;
}

fn legacy_placeholder_claim(
    history: []const HistoryTurn,
    placeholder: ?LegacyImagePlaceholderIterator.Slot,
) ?usize {
    const slot = placeholder orelse return null;
    const placeholder_id = slot.id orelse return null;
    if (placeholder_id == 0) return null;
    if (history_placeholder_id_count(history, placeholder_id) != 1) return null;
    if (history_contains_image_id(history, placeholder_id)) return null;
    return placeholder_id;
}

fn legacy_repairs_contain_id(repairs: []const LegacyImageRepair, id: usize) bool {
    for (repairs) |repair| {
        if (repair.assigned_id == id) return true;
    }
    return false;
}

fn assign_legacy_image_ids(
    history: []const HistoryTurn,
    repairs: []LegacyImageRepair,
) error{ImageIdOverflow}!void {
    for (repairs) |*repair| {
        repair.assigned_id = legacy_placeholder_claim(history, repair.placeholder) orelse 0;
    }

    var candidate: usize = 1;
    for (repairs) |*repair| {
        if (repair.assigned_id != 0) continue;
        while (history_contains_image_id(history, candidate) or
            legacy_repairs_contain_id(repairs, candidate))
        {
            candidate = std.math.add(usize, candidate, 1) catch
                return error.ImageIdOverflow;
        }
        repair.assigned_id = candidate;
    }
}

fn rebuilt_legacy_turn_text(
    alloc: Allocator,
    history: []const HistoryTurn,
    turn_index: usize,
    repairs: []const LegacyImageRepair,
) Allocator.Error!?[]u8 {
    const text = user_text_for_history_turn(history[turn_index]);
    var needs_rebuild = false;
    for (repairs) |repair| {
        if (repair.turn_index != turn_index) continue;
        const placeholder = repair.placeholder orelse continue;
        const legacy_id = placeholder.id orelse continue;
        if (legacy_id != repair.assigned_id) needs_rebuild = true;
    }
    if (!needs_rebuild) return null;

    var rebuilt: std.Io.Writer.Allocating = .init(alloc);
    errdefer rebuilt.deinit();
    var cursor: usize = 0;
    for (repairs) |repair| {
        if (repair.turn_index != turn_index) continue;
        const placeholder = repair.placeholder orelse continue;
        const legacy_id = placeholder.id orelse continue;
        if (legacy_id == repair.assigned_id) continue;

        std.debug.assert(placeholder.start >= cursor);
        std.debug.assert(placeholder.start + placeholder.length <= text.len);
        rebuilt.writer.writeAll(text[cursor..placeholder.start]) catch return error.OutOfMemory;
        image_attachments.writeImagePlaceholder(&rebuilt.writer, repair.assigned_id) catch return error.OutOfMemory;
        cursor = placeholder.start + placeholder.length;
    }
    rebuilt.writer.writeAll(text[cursor..]) catch return error.OutOfMemory;
    return rebuilt.toOwnedSlice() catch return error.OutOfMemory;
}

fn mutable_user_for_history_turn(turn: *HistoryTurn) ?*UserTurn {
    return switch (turn.*) {
        .compacted_summary => null,
        .assistant => |*entry| &entry.user,
        .background_command => |*entry| &entry.user,
        .interrupted => |*entry| &entry.user,
    };
}

/// Repairs image IDs omitted by the legacy session deep-copy path. This is
/// only for allocator-owned history loaded from durable storage. Rebuilt text
/// remains owned by its history turn. Returns whether any attachment changed.
pub fn repair_legacy_zero_image_ids(
    alloc: Allocator,
    history: []HistoryTurn,
) (Allocator.Error || error{ImageIdOverflow})!bool {
    var repairs: std.ArrayList(LegacyImageRepair) = .empty;
    defer repairs.deinit(alloc);
    for (history, 0..) |*turn, turn_index| {
        var placeholders = LegacyImagePlaceholderIterator{
            .text = user_text_for_history_turn(turn.*),
        };
        for (mutable_images_for_history_turn(turn), 0..) |attachment, image_index| {
            const placeholder = placeholders.next();
            if (attachment.id != 0) continue;
            try repairs.append(alloc, .{
                .turn_index = turn_index,
                .image_index = image_index,
                .placeholder = placeholder,
            });
        }
    }
    if (repairs.items.len == 0) return false;

    try assign_legacy_image_ids(history, repairs.items);

    var text_repairs: std.ArrayList(LegacyTurnTextRepair) = .empty;
    defer text_repairs.deinit(alloc);
    errdefer for (text_repairs.items) |repair| alloc.free(repair.text);
    for (history, 0..) |_, turn_index| {
        const rebuilt = try rebuilt_legacy_turn_text(
            alloc,
            history,
            turn_index,
            repairs.items,
        ) orelse continue;
        text_repairs.append(alloc, .{ .turn_index = turn_index, .text = rebuilt }) catch |err| {
            alloc.free(rebuilt);
            return err;
        };
    }

    for (repairs.items) |repair| {
        mutable_images_for_history_turn(&history[repair.turn_index])[repair.image_index].id =
            repair.assigned_id;
    }
    for (text_repairs.items) |repair| {
        const user = mutable_user_for_history_turn(&history[repair.turn_index]).?;
        alloc.free(user.text);
        user.text = repair.text;
    }
    return true;
}

pub fn repair_legacy_image_snapshots(
    alloc: Allocator,
    history: []HistoryTurn,
    snapshot_dir: []const u8,
) Allocator.Error!bool {
    const snapshot_dir_existed = snapshot_directory_exists(snapshot_dir);
    const candidate = try alloc.alloc(HistoryTurn, history.len);
    var copied: usize = 0;
    errdefer {
        for (candidate[0..copied]) |turn| freeHistoryTurn(alloc, turn);
        alloc.free(candidate);
    }
    while (copied < history.len) : (copied += 1) {
        candidate[copied] = try dupeHistoryTurn(alloc, history[copied]);
    }

    const changed = repair_legacy_image_snapshots_in_place(
        alloc,
        candidate,
        snapshot_dir,
    ) catch |err| {
        cleanup_candidate_snapshot_files(candidate, history);
        if (!snapshot_dir_existed) remove_empty_snapshot_directory(snapshot_dir);
        return err;
    };
    if (!changed) {
        freeHistoryTurnSlice(alloc, candidate);
        return false;
    }

    for (history, candidate) |*current, *replacement| {
        std.mem.swap(HistoryTurn, current, replacement);
    }
    freeHistoryTurnSlice(alloc, candidate);
    return true;
}

pub fn repair_legacy_images_transactionally(
    alloc: Allocator,
    history: []HistoryTurn,
    snapshot_dir: []const u8,
) (Allocator.Error || error{ImageIdOverflow})!bool {
    const candidate = try alloc.alloc(HistoryTurn, history.len);
    var copied: usize = 0;
    errdefer {
        for (candidate[0..copied]) |turn| freeHistoryTurn(alloc, turn);
        alloc.free(candidate);
    }
    while (copied < history.len) : (copied += 1) {
        candidate[copied] = try dupeHistoryTurn(alloc, history[copied]);
    }

    const ids_changed = try repair_legacy_zero_image_ids(alloc, candidate);
    const snapshots_changed = try repair_legacy_image_snapshots(
        alloc,
        candidate,
        snapshot_dir,
    );
    if (!ids_changed and !snapshots_changed) {
        freeHistoryTurnSlice(alloc, candidate);
        return false;
    }

    for (history, candidate) |*current, *replacement| {
        std.mem.swap(HistoryTurn, current, replacement);
    }
    freeHistoryTurnSlice(alloc, candidate);
    return true;
}

fn snapshot_directory_exists(path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), path, .{}) catch return false;
    dir.close(io_mod.getIo());
    return true;
}

fn remove_empty_snapshot_directory(path: []const u8) void {
    std.Io.Dir.deleteDirAbsolute(io_mod.getIo(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => debug_trace.logf(
            "session",
            "event=legacy_snapshot_directory_cleanup_failed err={s}",
            .{@errorName(err)},
        ),
    };
}

fn repair_legacy_image_snapshots_in_place(
    alloc: Allocator,
    history: []HistoryTurn,
    snapshot_dir: []const u8,
) Allocator.Error!bool {
    var changed = false;
    for (history) |*turn| {
        const images_ptr = mutable_images_slice_for_history_turn(turn) orelse continue;
        if (images_ptr.*.len == 0) continue;

        var drop_indexes: std.ArrayList(usize) = .empty;
        defer drop_indexes.deinit(alloc);
        for (images_ptr.*, 0..) |*image, image_index| {
            if (image.snapshot_path != null and image.snapshot_sha256 != null) continue;
            image_attachments.captureImageSnapshot(alloc, image, snapshot_dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf(
                        "session",
                        "legacy image snapshot unavailable id={d} err={s}",
                        .{ image.id, @errorName(err) },
                    );
                    try drop_indexes.append(alloc, image_index);
                    continue;
                },
            };
            changed = true;
        }
        if (drop_indexes.items.len == 0) continue;

        const retained_len = images_ptr.*.len - drop_indexes.items.len;
        var retained: []ImageAttachment = if (retained_len > 0)
            try alloc.alloc(ImageAttachment, retained_len)
        else
            &.{};
        var retained_index: usize = 0;
        var drop_cursor: usize = 0;
        for (images_ptr.*, 0..) |image, image_index| {
            const drop = drop_cursor < drop_indexes.items.len and
                drop_indexes.items[drop_cursor] == image_index;
            if (drop) {
                core_types.freeImageAttachment(alloc, image);
                drop_cursor += 1;
                continue;
            }
            retained[retained_index] = image;
            retained_index += 1;
        }
        alloc.free(images_ptr.*);
        images_ptr.* = retained;
        changed = true;
    }
    return changed;
}

fn cleanup_candidate_snapshot_files(
    candidate: []const HistoryTurn,
    original: []const HistoryTurn,
) void {
    for (candidate, original) |candidate_turn, original_turn| {
        image_attachments.deleteUnreferencedImageSnapshots(
            images_for_history_turn(candidate_turn),
            images_for_history_turn(original_turn),
        );
    }
}

fn make_owned_legacy_image_turn(
    alloc: Allocator,
    text: []const u8,
    assistant: []const u8,
    path: []const u8,
) !HistoryTurn {
    var turn = try makeAssistantTurn(alloc, text, assistant);
    errdefer freeHistoryTurn(alloc, turn);
    turn.assistant.user.images = try core_types.dupeImageAttachmentSlice(alloc, &.{.{
        .path = @constCast(path),
        .media_type = @constCast("image/png"),
    }});
    return turn;
}

fn sessionTestSnapshotDir(alloc: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "snapshots" });
}

fn writeSessionTestImage(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    name: []const u8,
    data: []const u8,
) ![]u8 {
    {
        var file = try tmp.dir.createFile(std.testing.io, name, .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, data);
    }
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
}














fn history_contains_image_id(history: []const HistoryTurn, id: usize) bool {
    for (history) |turn| {
        for (images_for_history_turn(turn)) |attachment| {
            if (attachment.id == id) return true;
        }
    }
    return false;
}

fn image_id_less_than(_: void, lhs: ImageAttachment, rhs: ImageAttachment) bool {
    return lhs.id < rhs.id;
}

pub const PersistedToolArgumentsSource = enum {
    schema_v3,
    legacy,
};

pub fn repairPersistedToolArguments(
    alloc: Allocator,
    calls: []ToolCall,
    results: []PersistedToolResult,
    source: PersistedToolArgumentsSource,
) !void {
    for (calls) |call| {
        if (call.argument_integrity == .malformed_json) {
            _ = try persistedResultForMalformedCall(calls, results, call);
        }
    }

    for (calls) |*call| {
        if (call.argument_integrity != .malformed_json) continue;
        const result = try persistedResultForMalformedCall(calls, results, call.*);
        const failure_output = try tool_result_errors.malformedToolArgumentsJson(alloc, call.name);

        alloc.free(result.output);
        if (result.output_handle) |handle| alloc.free(handle);
        if (result.preview) |preview| alloc.free(preview);
        result.status = .failure;
        result.output = failure_output;
        result.output_handle = null;
        result.preview = null;
        result.output_bytes = failure_output.len;
        result.stored_output_bytes = failure_output.len;
        result.truncated = false;
        result.provider_native = false;
        call.argument_integrity = .valid;
        tracePersistedToolArgumentsRepair(call.*, source, true);
    }
}

pub fn repairPersistedInterruptedToolArguments(
    call: *ToolCall,
    source: PersistedToolArgumentsSource,
) void {
    if (call.argument_integrity != .malformed_json) return;
    call.argument_integrity = .valid;
    tracePersistedToolArgumentsRepair(call.*, source, false);
}

fn persistedResultForMalformedCall(
    calls: []ToolCall,
    results: []PersistedToolResult,
    call: ToolCall,
) !*PersistedToolResult {
    var matching_calls: usize = 0;
    for (calls) |candidate| {
        if (std.mem.eql(u8, candidate.id, call.id)) matching_calls += 1;
    }
    if (matching_calls != 1) return error.InvalidSessionFormat;

    var matched_result: ?*PersistedToolResult = null;
    for (results) |*result| {
        if (!std.mem.eql(u8, result.tool_call_id, call.id)) continue;
        if (matched_result != null) return error.InvalidSessionFormat;
        matched_result = result;
    }

    const result = matched_result orelse return error.InvalidSessionFormat;
    if (!std.mem.eql(u8, result.tool_name, call.name)) return error.InvalidSessionFormat;
    return result;
}

fn tracePersistedToolArgumentsRepair(
    call: ToolCall,
    source: PersistedToolArgumentsSource,
    paired_result: bool,
) void {
    debug_trace.eventf(
        "session",
        "persisted_tool_arguments_repaired",
        .{},
        "source={s} call_id={s} tool={s} failure=malformed_json paired_result={s}",
        .{ @tagName(source), call.id, call.name, if (paired_result) "true" else "false" },
    );
}

pub const WebFetchArtifactState = union(enum) {
    none,
    store: web_fetch_artifacts.Store,
    unavailable: anyerror,
};

pub const SessionRuntime = struct {
    history: std.ArrayList(HistoryTurn) = .empty,
    context_notice_hashes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    context_notice_lock: std.Io.Mutex = .init,
    web_fetch_artifacts: WebFetchArtifactState = .none,
    language_lock: std.Io.Mutex = .init,
    conversation_language: ConversationLanguage = ConversationLanguage.default(),
    usage: session_usage.Usage = session_usage.Usage.initFresh(),
    profile_usage: profile_usage_runtime.Runtime = .{},
    permission_state_lock: std.Io.Mutex = .init,
    permission_state: session_permission_state.State = .{},
    /// Count limit for owned model-context snapshots; canonical history is not truncated.
    max_history_turns: usize,
    context_history_start: usize = 0,

    pub fn init(
        max_history_turns: usize,
        provider: generation_usage_provider.Provider,
    ) SessionRuntime {
        return .{
            .usage = session_usage.Usage.initFreshWithProvider(provider),
            .max_history_turns = max_history_turns,
        };
    }

    pub fn initWithProviders(
        max_history_turns: usize,
        providers: generation_usage_provider.Set,
    ) SessionRuntime {
        return .{
            .usage = session_usage.Usage.initFreshWithProviders(providers),
            .max_history_turns = max_history_turns,
        };
    }

    pub fn deinit(self: *SessionRuntime, alloc: Allocator) void {
        self.clearWebFetchArtifacts();
        self.usage.configurePublicationSink(null);
        self.usage.configureCheckpointSink(null);
        self.usage.deinit(alloc);
        self.profile_usage.deinit(alloc);
        self.permission_state.deinit(alloc);
        self.clearHistory(alloc);
        self.history.deinit(alloc);
        self.context_notice_hashes.deinit(alloc);
    }

    pub fn initializeProfileUsage(
        self: *SessionRuntime,
        alloc: Allocator,
        home_path: ?[]const u8,
    ) !profile_usage_runtime.InitializeOutcome {
        self.usage.configurePublicationSink(null);
        return self.profile_usage.initialize(alloc, home_path);
    }

    /// Attaches callbacks only after the host has placed SessionRuntime at its
    /// final address.
    pub fn attachProfileUsagePublisher(
        self: *SessionRuntime,
        alloc: Allocator,
    ) void {
        self.usage.configurePublicationSink(
            if (self.profile_usage.isAvailable())
                self.profile_usage.publisherSink(alloc)
            else
                null,
        );
    }

    pub fn ensureProfileUsageReadable(
        self: *SessionRuntime,
        alloc: Allocator,
        home_path: ?[]const u8,
    ) !profile_usage_runtime.InitializeOutcome {
        if (self.profile_usage.isAvailable()) return .available;
        return self.initializeProfileUsage(alloc, home_path);
    }

    pub fn reset(self: *SessionRuntime, alloc: Allocator) void {
        self.clearWebFetchArtifacts();
        self.usage.resetFresh(alloc);
        self.clearPermissionState(alloc);
        self.clearHistory(alloc);
        self.clearContextNotices();
        self.setConversationLanguage(ConversationLanguage.default());
    }

    pub fn restore(self: *SessionRuntime, alloc: Allocator, language: ConversationLanguage, history: []const HistoryTurn) !void {
        self.clearWebFetchArtifacts();
        self.usage.resetLegacy(alloc);
        self.clearPermissionState(alloc);
        self.clearHistory(alloc);
        self.clearContextNotices();
        self.setConversationLanguage(language);

        for (history) |turn| {
            try self.appendHistoryEntry(alloc, turn);
        }
    }

    pub fn restoreWithContextHistoryStart(
        self: *SessionRuntime,
        alloc: Allocator,
        language: ConversationLanguage,
        history: []const HistoryTurn,
        context_history_start: usize,
    ) !void {
        if (context_history_start > history.len) return error.InvalidContextHistoryStart;
        try self.restore(alloc, language, history);
        self.context_history_start = context_history_start;
    }

    pub fn restoreWithPermissionState(
        self: *SessionRuntime,
        alloc: Allocator,
        language: ConversationLanguage,
        history: []const HistoryTurn,
        context_history_start: usize,
        permission_state: session_permission_state.State,
    ) !void {
        if (context_history_start > history.len) {
            return error.InvalidContextHistoryStart;
        }
        var permission_copy = try session_permission_state.dupe(
            alloc,
            permission_state,
        );
        errdefer permission_copy.deinit(alloc);
        try self.restoreWithContextHistoryStart(
            alloc,
            language,
            history,
            context_history_start,
        );
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        self.permission_state.deinit(alloc);
        self.permission_state = permission_copy;
    }

    pub fn snapshotPermissionState(
        self: *SessionRuntime,
        alloc: Allocator,
    ) !session_permission_state.State {
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        return session_permission_state.dupe(alloc, self.permission_state);
    }

    pub fn applyPermissionEvent(
        self: *SessionRuntime,
        alloc: Allocator,
        event: session_permission_state.ConfirmedRuleEvent,
    ) !session_permission_state.ApplyStatus {
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        const result = try session_permission_state.apply(
            alloc,
            self.permission_state,
            event,
        );
        return switch (result) {
            .applied => |next| blk: {
                self.permission_state.deinit(alloc);
                self.permission_state = next;
                break :blk .applied;
            },
            .stale => .stale,
            .full => .full,
            .invalid => .invalid,
        };
    }

    pub fn replacePermissionStateOwned(
        self: *SessionRuntime,
        alloc: Allocator,
        state: *session_permission_state.State,
    ) void {
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        self.permission_state.deinit(alloc);
        self.permission_state = state.*;
        state.* = .{};
    }

    fn clearPermissionState(self: *SessionRuntime, alloc: Allocator) void {
        self.permission_state_lock.lockUncancelable(io_mod.getIo());
        defer self.permission_state_lock.unlock(io_mod.getIo());
        self.permission_state.deinit(alloc);
    }

    pub fn configureWebFetchArtifacts(self: *SessionRuntime, alloc: Allocator, session_dir: []const u8) void {
        self.clearWebFetchArtifacts();
        const store = web_fetch_artifacts.Store.init(alloc, session_dir) catch |err| {
            self.web_fetch_artifacts = .{ .unavailable = err };
            return;
        };
        self.web_fetch_artifacts = .{ .store = store };
    }

    pub fn clearWebFetchArtifacts(self: *SessionRuntime) void {
        switch (self.web_fetch_artifacts) {
            .store => |*store| store.deinit(),
            .none, .unavailable => {},
        }
        self.web_fetch_artifacts = .none;
    }

    /// Returns true once for each distinct source-limit notice in this live
    /// session. Size and limit are part of the rendered notice, so either
    /// changing makes the updated condition visible again.
    pub fn claimContextNotice(self: *SessionRuntime, alloc: Allocator, notice: []const u8) !bool {
        self.context_notice_lock.lockUncancelable(io_mod.getIo());
        defer self.context_notice_lock.unlock(io_mod.getIo());
        const result = try self.context_notice_hashes.getOrPut(
            alloc,
            std.hash.Wyhash.hash(0, notice),
        );
        return !result.found_existing;
    }

    pub fn clearContextNotices(self: *SessionRuntime) void {
        self.context_notice_lock.lockUncancelable(io_mod.getIo());
        defer self.context_notice_lock.unlock(io_mod.getIo());
        self.context_notice_hashes.clearRetainingCapacity();
    }

    pub fn webFetchArtifactStore(self: *SessionRuntime) ?*web_fetch_artifacts.Store {
        return switch (self.web_fetch_artifacts) {
            .store => |*store| store,
            .none, .unavailable => null,
        };
    }

    pub fn webFetchArtifactError(self: *SessionRuntime) ?anyerror {
        return switch (self.web_fetch_artifacts) {
            .unavailable => |err| err,
            .none, .store => null,
        };
    }

    pub fn clearHistory(self: *SessionRuntime, alloc: Allocator) void {
        for (self.history.items) |turn| {
            freeHistoryTurn(alloc, turn);
        }
        self.history.clearRetainingCapacity();
        self.context_history_start = 0;
    }

    pub fn historyLen(self: *const SessionRuntime) usize {
        return self.history.items.len;
    }

    pub fn contextHistoryStart(self: *const SessionRuntime) usize {
        return self.context_history_start;
    }

    pub fn compactedTurnCount(self: *const SessionRuntime) usize {
        if (self.history.items.len == 0) return 0;
        return switch (self.history.items[0]) {
            .compacted_summary => |entry| entry.removed_turn_count,
            else => 0,
        };
    }

    pub fn compactionCount(self: *const SessionRuntime) usize {
        if (self.history.items.len == 0) return 0;
        return switch (self.history.items[0]) {
            .compacted_summary => |entry| entry.compaction_count,
            else => 0,
        };
    }

    pub fn snapshotHistory(self: *const SessionRuntime, alloc: Allocator) ![]HistoryTurn {
        var copy: std.ArrayList(HistoryTurn) = .empty;
        errdefer {
            for (copy.items) |turn| {
                freeHistoryTurn(alloc, turn);
            }
            copy.deinit(alloc);
        }
        try appendHistoryCopies(alloc, &copy, self.history.items);
        return copy.toOwnedSlice(alloc);
    }

    pub fn snapshotImageCatalog(
        self: *const SessionRuntime,
        alloc: Allocator,
        current_images: []const ImageAttachment,
    ) ![]ImageAttachment {
        return collect_image_catalog(alloc, self.history.items, current_images);
    }

    pub fn snapshotContextHistory(self: *const SessionRuntime, alloc: Allocator) ![]HistoryTurn {
        return snapshotOwnedContextHistory(
            alloc,
            self.history.items,
            self.context_history_start,
            self.max_history_turns,
        );
    }

    pub fn appendHistoryEntry(self: *SessionRuntime, alloc: Allocator, turn: HistoryTurn) !void {
        const copy = try dupeHistoryTurn(alloc, turn);
        var owns_copy = true;
        errdefer if (owns_copy) freeHistoryTurn(alloc, copy);

        try self.history.append(alloc, copy);
        owns_copy = false;
    }

    pub fn appendAssistantHistoryTurn(self: *SessionRuntime, alloc: Allocator, user: []const u8, assistant: []const u8) !void {
        const turn = try makeAssistantTurn(alloc, user, assistant);
        var owns_turn = true;
        errdefer if (owns_turn) freeHistoryTurn(alloc, turn);

        try self.history.append(alloc, turn);
        owns_turn = false;
    }

    pub fn appendBackgroundCommandHistoryTurn(self: *SessionRuntime, alloc: Allocator, user: []const u8, background: command_contract.BackgroundCommand) !void {
        const user_text = try alloc.dupe(u8, user);
        var owns_user_text = true;
        errdefer if (owns_user_text) alloc.free(user_text);

        const log_path = try alloc.dupe(u8, background.log_path);
        var owns_log_path = true;
        errdefer if (owns_log_path) alloc.free(log_path);

        const url: ?[]u8 = if (background.url) |url_text| try alloc.dupe(u8, url_text) else null;
        var owns_url = url != null;
        errdefer if (owns_url) {
            if (url) |url_text| alloc.free(url_text);
        };

        const turn = HistoryTurn{ .background_command = .{
            .user = .{ .text = user_text, .images = &.{} },
            .log_path = log_path,
            .expect_url = background.expect_url,
            .url = url,
            .background_record_id = background.background_record_id,
        } };
        owns_user_text = false;
        owns_log_path = false;
        owns_url = false;

        var owns_turn = true;
        errdefer if (owns_turn) freeHistoryTurn(alloc, turn);

        try self.history.append(alloc, turn);
        owns_turn = false;
    }

    pub fn appendHistoryMessages(
        alloc: Allocator,
        messages: *std.ArrayList(message.Message),
        history: []const HistoryTurn,
    ) !void {
        _ = try appendHistoryMessagesImpl(alloc, messages, history, true);
    }

    pub fn appendHistoryChatMessages(
        alloc: Allocator,
        messages: *std.ArrayList(core_types.ChatMessage),
        history: []const HistoryTurn,
    ) !void {
        _ = try appendHistoryChatMessagesImpl(alloc, messages, history, true);
    }

    pub fn setConversationLanguageFromUserMessage(self: *SessionRuntime, text: []const u8) void {
        const fallback = self.languageSnapshot();
        self.setConversationLanguage(inferConversationLanguage(text, fallback));
    }

    pub fn languageSnapshot(self: *const SessionRuntime) ConversationLanguage {
        const mutable: *SessionRuntime = @constCast(self);
        mutable.language_lock.lockUncancelable(io_mod.getIo());
        defer mutable.language_lock.unlock(io_mod.getIo());
        return mutable.conversation_language;
    }

    pub fn lastAssistantReply(self: *const SessionRuntime) ?[]const u8 {
        var i = self.history.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.history.items[i]) {
                .assistant => |entry| {
                    if (entry.assistant.len > 0) return entry.assistant;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn lastSummary(self: *const SessionRuntime) ?[]const u8 {
        for (self.history.items) |turn| {
            switch (turn) {
                .compacted_summary => |entry| return entry.summary,
                else => {},
            }
        }
        return null;
    }

    pub fn forceCompaction(self: *SessionRuntime) void {
        if (self.history.items.len <= 1) return;
        self.context_history_start = self.history.items.len - 1;
    }

    fn setConversationLanguage(self: *SessionRuntime, language: ConversationLanguage) void {
        self.language_lock.lockUncancelable(io_mod.getIo());
        defer self.language_lock.unlock(io_mod.getIo());
        self.conversation_language = language;
    }
};

fn appendHistoryCopies(
    alloc: Allocator,
    destination: *std.ArrayList(HistoryTurn),
    history: []const HistoryTurn,
) !void {
    try destination.ensureUnusedCapacity(alloc, history.len);
    for (history) |turn| {
        const copy = try dupeHistoryTurn(alloc, turn);
        destination.appendAssumeCapacity(copy);
    }
}

/// Builds an independently owned prompt-history snapshot from canonical history.
pub fn snapshotOwnedContextHistory(
    alloc: Allocator,
    canonical_history: []const HistoryTurn,
    context_history_start: usize,
    max_history_turns: usize,
) ![]HistoryTurn {
    var copy: std.ArrayList(HistoryTurn) = .empty;
    errdefer {
        for (copy.items) |turn| {
            freeHistoryTurn(alloc, turn);
        }
        copy.deinit(alloc);
    }

    const start = @min(context_history_start, canonical_history.len);
    try appendCompactedPrefix(
        alloc,
        &copy,
        canonical_history[0..start],
    );
    try appendHistoryCopies(alloc, &copy, canonical_history[start..]);
    _ = try compactHistory(&copy, alloc, max_history_turns);
    return copy.toOwnedSlice(alloc);
}

fn appendCompactedPrefix(
    alloc: Allocator,
    destination: *std.ArrayList(HistoryTurn),
    history: []const HistoryTurn,
) !void {
    if (history.len == 0) return;

    const has_existing_summary = history[0] == .compacted_summary;
    const existing_summary = if (has_existing_summary) history[0].compacted_summary else null;
    const removed = history[@intFromBool(has_existing_summary)..];
    if (removed.len == 0) {
        try appendHistoryCopies(alloc, destination, history);
        return;
    }

    const summary = try buildCompactedSummaryTurn(alloc, existing_summary, removed);
    errdefer freeHistoryTurn(alloc, .{ .compacted_summary = summary });
    try destination.append(alloc, .{ .compacted_summary = summary });
}

/// Frees an owned image attachment slice and each attachment field.
pub fn freeImageAttachmentSlice(alloc: Allocator, attachments: []ImageAttachment) void {
    for (attachments) |attachment| {
        core_types.freeImageAttachment(alloc, attachment);
    }
    if (attachments.len > 0) alloc.free(attachments);
}
/// Frees an owned history slice; callers pass slices returned by session helpers.
pub fn freeHistoryTurnSlice(alloc: Allocator, turns: []HistoryTurn) void {
    for (turns) |turn| freeHistoryTurn(alloc, turn);
    if (turns.len > 0) alloc.free(turns);
}
/// Deep-copies an image attachment slice; caller owns the returned slice and frees with freeImageAttachmentSlice.
pub fn dupeImageAttachmentSlice(alloc: Allocator, attachments: []const ImageAttachment) ![]ImageAttachment {
    if (attachments.len == 0) return &.{};
    const copy = try alloc.alloc(ImageAttachment, attachments.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            core_types.freeImageAttachment(alloc, copy[i]);
        }
    }
    for (attachments, 0..) |attachment, i| {
        copy[i] = try dupeImageAttachment(alloc, attachment);
        copied += 1;
    }
    return copy;
}
fn dupeImageAttachment(alloc: Allocator, src: ImageAttachment) !ImageAttachment {
    const path = try alloc.dupe(u8, src.path);
    errdefer alloc.free(path);
    const media_type = try alloc.dupe(u8, src.media_type);
    errdefer alloc.free(media_type);
    const snapshot_path = if (src.snapshot_path) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (snapshot_path) |value| alloc.free(value);
    const snapshot_sha256 = if (src.snapshot_sha256) |value|
        try alloc.dupe(u8, value)
    else
        null;
    return .{
        .id = src.id,
        .path = path,
        .media_type = media_type,
        .snapshot_path = snapshot_path,
        .snapshot_sha256 = snapshot_sha256,
    };
}
/// Deep-copies one history turn; caller owns the returned turn and frees with freeHistoryTurn.
pub fn dupeHistoryTurn(alloc: Allocator, turn: HistoryTurn) !HistoryTurn {
    switch (turn) {
        .compacted_summary => |entry| {
            const summary = try alloc.dupe(u8, entry.summary);
            errdefer alloc.free(summary);
            const root_user_messages = try core_types.dupeCompletedToolNames(
                alloc,
                entry.root_user_messages,
            );
            errdefer core_types.freeCompletedToolNames(alloc, root_user_messages);
            const permission_feedback = try core_types.dupePermissionFeedback(
                alloc,
                entry.permission_feedback,
            );
            return .{ .compacted_summary = .{
                .summary = summary,
                .removed_turn_count = entry.removed_turn_count,
                .compaction_count = entry.compaction_count,
                .root_user_messages = root_user_messages,
                .root_user_messages_complete = entry.root_user_messages_complete,
                .permission_feedback = permission_feedback,
                .permission_feedback_complete = entry.permission_feedback_complete,
            } };
        },
        .assistant => |entry| {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);
            const assistant_copy = try alloc.dupe(u8, entry.assistant);
            errdefer alloc.free(assistant_copy);
            const execution = try core_types.dupeExecutionMemory(alloc, entry.execution);
            return .{ .assistant = .{
                .user = user,
                .assistant = assistant_copy,
                .execution = execution,
            } };
        },
        .background_command => |entry| {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);
            const assistant = if (entry.assistant) |text| try alloc.dupe(u8, text) else null;
            errdefer if (assistant) |text| alloc.free(text);
            const execution = try core_types.dupeExecutionMemory(alloc, entry.execution);
            errdefer core_types.freeExecutionMemory(alloc, execution);
            const log_path = try alloc.dupe(u8, entry.log_path);
            errdefer alloc.free(log_path);
            const url: ?[]u8 = if (entry.url) |url_bytes| try alloc.dupe(u8, url_bytes) else null;
            return .{ .background_command = .{
                .user = user,
                .assistant = assistant,
                .execution = execution,
                .log_path = log_path,
                .expect_url = entry.expect_url,
                .url = url,
                .background_record_id = entry.background_record_id,
            } };
        },
        .interrupted => |entry| {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);
            const assistant = if (entry.assistant) |text| try alloc.dupe(u8, text) else null;
            errdefer if (assistant) |text| alloc.free(text);
            const tool_call = if (entry.tool_call) |call| try core_types.dupeToolCall(alloc, call) else null;
            errdefer if (tool_call) |call| core_types.freeToolCall(alloc, call);
            const completed_tool_names = try core_types.dupeCompletedToolNames(alloc, entry.completed_tool_names);
            errdefer core_types.freeCompletedToolNames(alloc, completed_tool_names);
            const cancelled_command = if (entry.cancelled_command) |presentation|
                try core_types.dupeCancelledCommandPresentation(alloc, presentation)
            else
                null;
            errdefer if (cancelled_command) |presentation| {
                core_types.freeCancelledCommandPresentation(alloc, presentation);
            };
            const execution = try core_types.dupeExecutionMemory(alloc, entry.execution);
            return .{ .interrupted = .{
                .user = user,
                .assistant = assistant,
                .tool_call = tool_call,
                .completed_tool_names = completed_tool_names,
                .execution = execution,
                .cancelled_command = cancelled_command,
                .terminal_reason = entry.terminal_reason,
            } };
        },
    }
}
pub fn appendAssistantTurnWithExecution(
    alloc: Allocator,
    current: []HistoryTurn,
    user_text: []const u8,
    assistant_text: []const u8,
    execution: *core_types.ExecutionMemory,
) ![]HistoryTurn {
    const user_copy = try alloc.dupe(u8, user_text);
    errdefer alloc.free(user_copy);
    const assistant_copy = try alloc.dupe(u8, assistant_text);
    errdefer alloc.free(assistant_copy);
    const next = try alloc.alloc(HistoryTurn, current.len + 1);
    errdefer alloc.free(next);

    std.mem.copyForwards(HistoryTurn, next[0..current.len], current);
    next[current.len] = .{ .assistant = .{
        .user = .{ .text = user_copy, .images = &.{} },
        .assistant = assistant_copy,
        .execution = execution.*,
    } };
    execution.* = .{};
    if (current.len > 0) alloc.free(current);
    return next;
}

/// Appends a finished turn to an owned prompt-context projection and reapplies its turn limit.
pub fn appendHistoryTurnToOwnedContext(
    alloc: Allocator,
    current: []HistoryTurn,
    turn: HistoryTurn,
    max_history_turns: usize,
) ![]HistoryTurn {
    var list: std.ArrayList(HistoryTurn) = .empty;
    errdefer {
        for (list.items) |owned_turn| {
            freeHistoryTurn(alloc, owned_turn);
        }
        list.deinit(alloc);
    }

    try list.ensureTotalCapacity(alloc, current.len + 1);
    for (current) |owned_turn| {
        list.appendAssumeCapacity(owned_turn);
    }
    if (current.len > 0) alloc.free(current);

    const duplicate = try dupeHistoryTurn(alloc, turn);
    var owns_duplicate = true;
    errdefer if (owns_duplicate) freeHistoryTurn(alloc, duplicate);

    try list.append(alloc, duplicate);
    owns_duplicate = false;
    _ = try compactHistory(&list, alloc, max_history_turns);
    return try list.toOwnedSlice(alloc);
}

/// Builds one owned assistant history turn; caller frees with freeHistoryTurn.
pub fn makeAssistantTurn(alloc: Allocator, user_text: []const u8, assistant_text: []const u8) !HistoryTurn {
    const user_copy = try alloc.dupe(u8, user_text);
    errdefer alloc.free(user_copy);
    const assistant_copy = try alloc.dupe(u8, assistant_text);
    errdefer alloc.free(assistant_copy);
    return .{ .assistant = .{
        .user = .{ .text = user_copy, .images = &.{} },
        .assistant = assistant_copy,
    } };
}





/// Projects stored history into request messages while preserving stored turn order.
pub fn appendHistoryMessages(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    history: []const HistoryTurn,
) !void {
    _ = try appendHistoryMessagesImpl(alloc, messages, history, true);
}

pub fn appendHistoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
) !void {
    _ = try appendHistoryChatMessagesImpl(alloc, messages, history, true);
}

pub const HistoryBudgetOptions = struct {
    max_tokens: usize = 0,
};

pub fn appendHistoryMessagesBudgeted(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    history: []const HistoryTurn,
    opts: HistoryBudgetOptions,
) !void {
    const keep = try selectBudgetedHistoryTurns(alloc, history, opts) orelse
        return appendHistoryMessages(alloc, messages, history);
    defer alloc.free(keep);

    const trimmed_context = try formatBudgetTrimmedHistoryContext(
        alloc,
        history,
        keep,
    );
    var owns_trimmed_context = true;
    errdefer if (owns_trimmed_context) alloc.free(trimmed_context);
    try messages.append(
        alloc,
        message.Message.systemOwned(trimmed_context),
    );
    owns_trimmed_context = false;

    var in_leading_summary_prefix = true;
    for (history, 0..) |turn, idx| {
        if (!keep[idx]) {
            in_leading_summary_prefix = continuesLeadingSummaryPrefix(in_leading_summary_prefix, turn);
            continue;
        }
        in_leading_summary_prefix = try appendHistoryMessagesImpl(
            alloc,
            messages,
            history[idx .. idx + 1],
            in_leading_summary_prefix,
        );
    }
}

pub fn appendHistoryChatMessagesBudgeted(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    opts: HistoryBudgetOptions,
) !void {
    const keep = try selectBudgetedHistoryTurns(alloc, history, opts) orelse
        return appendHistoryChatMessages(alloc, messages, history);
    defer alloc.free(keep);

    const trimmed_context = try formatBudgetTrimmedHistoryContext(alloc, history, keep);
    errdefer alloc.free(trimmed_context);
    try messages.append(alloc, .{ .role = .system, .content = trimmed_context });

    var in_leading_summary_prefix = true;
    for (history, 0..) |turn, idx| {
        if (!keep[idx]) {
            in_leading_summary_prefix = continuesLeadingSummaryPrefix(in_leading_summary_prefix, turn);
            continue;
        }
        in_leading_summary_prefix = try appendHistoryChatMessagesImpl(
            alloc,
            messages,
            history[idx .. idx + 1],
            in_leading_summary_prefix,
        );
    }
}

fn continuesLeadingSummaryPrefix(in_leading_summary_prefix: bool, turn: HistoryTurn) bool {
    return in_leading_summary_prefix and turn == .compacted_summary;
}

fn selectBudgetedHistoryTurns(
    alloc: Allocator,
    history: []const HistoryTurn,
    opts: HistoryBudgetOptions,
) !?[]bool {
    if (opts.max_tokens == 0 or history.len == 0) return null;

    const keep = try alloc.alloc(bool, history.len);
    errdefer alloc.free(keep);
    @memset(keep, false);

    var used_tokens: usize = 0;
    var kept_count: usize = 0;
    var i = history.len;
    while (i > 0) {
        i -= 1;
        const cost = estimateHistoryTurnTokens(history[i]);
        if (kept_count == 0 or used_tokens + cost <= opts.max_tokens) {
            keep[i] = true;
            used_tokens += cost;
            kept_count += 1;
        }
    }

    if (kept_count == history.len) {
        alloc.free(keep);
        return null;
    }
    return keep;
}

fn appendHistoryMessagesImpl(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    history: []const HistoryTurn,
    starts_in_leading_summary_prefix: bool,
) !bool {
    var in_leading_summary_prefix = starts_in_leading_summary_prefix;
    for (history) |turn| {
        const summary_is_system = in_leading_summary_prefix;
        in_leading_summary_prefix = continuesLeadingSummaryPrefix(in_leading_summary_prefix, turn);
        switch (turn) {
            .compacted_summary => |entry| {
                const text = try formatCompactedContinuationMessage(alloc, entry.summary);
                errdefer alloc.free(text);
                try messages.append(
                    alloc,
                    if (summary_is_system)
                        message.Message.systemOwned(text)
                    else
                        message.Message.userOwned(text),
                );
            },
            .assistant => |entry| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = .{ .text = entry.user.text },
                    .images = entry.user.images,
                });
                try appendExecutionMemoryMessages(alloc, messages, entry.execution);
                if (entry.assistant.len > 0) {
                    try messages.append(alloc, message.Message.assistantBorrowed(entry.assistant, &.{}));
                }
            },
            .background_command => |entry| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = .{ .text = entry.user.text },
                    .images = entry.user.images,
                });
                try appendExecutionMemoryMessages(alloc, messages, entry.execution);
                if (entry.assistant) |assistant| {
                    if (assistant.len > 0) {
                        try messages.append(alloc, message.Message.assistantBorrowed(assistant, &.{}));
                    }
                }
                const text = try formatBackgroundHistoryContext(alloc, entry);
                errdefer alloc.free(text);
                try messages.append(alloc, message.Message.userOwned(text));
            },
            .interrupted => |entry| {
                try messages.append(alloc, .{
                    .role = .user,
                    .content = .{ .text = entry.user.text },
                    .images = entry.user.images,
                });
                try appendExecutionMemoryMessages(alloc, messages, entry.execution);
                if (entry.tool_call) |tool_call| {
                    const assistant_content = try formatInterruptedAssistantToolContent(alloc, entry);
                    var owns_assistant_content = assistant_content != null;
                    errdefer if (owns_assistant_content) {
                        if (assistant_content) |text| alloc.free(text);
                    };
                    const calls = try alloc.alloc(core_types.ToolCall, 1);
                    var owns_calls = true;
                    var calls_initialized = false;
                    errdefer if (owns_calls) {
                        if (calls_initialized) core_types.freeToolCall(alloc, calls[0]);
                        alloc.free(calls);
                    };
                    calls[0] = try core_types.dupeToolCall(alloc, tool_call);
                    calls_initialized = true;
                    try messages.append(alloc, .{
                        .role = .assistant,
                        .content = if (assistant_content) |text| .{ .text = text } else null,
                        .tool_calls = calls,
                        .owns_content = assistant_content != null,
                        .owns_tool_calls = true,
                    });
                    owns_assistant_content = false;
                    owns_calls = false;
                    const tool_output = try formatInterruptedToolOutput(alloc, entry);
                    var owns_tool_output = true;
                    errdefer if (owns_tool_output) alloc.free(tool_output);
                    try messages.append(alloc, .{
                        .role = .tool,
                        .content = .{ .text = tool_output },
                        .tool_call_id = tool_call.id,
                        .tool_name = tool_call.name,
                        .tool_result_status = .failure,
                        .owns_content = true,
                    });
                    owns_tool_output = false;
                } else {
                    const assistant_content = try formatInterruptedAssistantClosedContent(alloc, entry);
                    var owns_assistant_content = true;
                    errdefer if (owns_assistant_content) alloc.free(assistant_content);
                    try messages.append(alloc, message.Message.assistantOwned(assistant_content, &.{}));
                    owns_assistant_content = false;
                }
                const text = try formatInterruptedHistoryContext(alloc, entry);
                errdefer alloc.free(text);
                try messages.append(alloc, message.Message.userOwned(text));
            },
        }
    }
    return in_leading_summary_prefix;
}

fn appendExecutionMemoryMessages(
    alloc: Allocator,
    messages: *std.ArrayList(message.Message),
    execution: core_types.ExecutionMemory,
) !void {
    for (execution.tool_steps) |step| {
        if (step.tool_calls.len == 0) continue;
        try messages.append(alloc, .{
            .role = .assistant,
            .content = if (step.assistant) |text| .{ .text = text } else null,
            .tool_calls = step.tool_calls,
        });
        for (step.tool_results) |result| {
            try messages.append(alloc, .{
                .role = .tool,
                .content = .{ .text = result.output },
                .tool_call_id = result.tool_call_id,
                .tool_name = result.tool_name,
                .tool_result_status = result.status,
            });
        }
        for (step.tool_results) |result| {
            for (result.permission_feedback) |feedback| {
                try messages.append(alloc, message.Message.userText(feedback));
            }
        }
    }
    if (execution.files.len > 0) {
        const text = try formatExecutionFileContext(alloc, execution.files);
        errdefer alloc.free(text);
        try messages.append(alloc, message.Message.userOwned(text));
    }
}

pub fn appendExecutionMemoryChatMessages(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    execution: core_types.ExecutionMemory,
) !void {
    for (execution.tool_steps) |step| {
        if (step.tool_calls.len == 0) continue;
        try messages.append(alloc, .{
            .role = .assistant,
            .content = step.assistant,
            .tool_calls = step.tool_calls,
        });
        for (step.tool_results) |result| {
            try messages.append(alloc, .{
                .role = .tool,
                .content = result.output,
                .tool_call_id = result.tool_call_id,
                .tool_name = result.tool_name,
                .tool_result_status = result.status,
            });
        }
        for (step.tool_results) |result| {
            for (result.permission_feedback) |feedback| {
                try messages.append(alloc, .{ .role = .user, .content = feedback });
            }
        }
    }
    if (execution.files.len > 0) {
        const text = try formatExecutionFileContext(alloc, execution.files);
        errdefer alloc.free(text);
        try messages.append(alloc, .{ .role = .user, .content = text });
    }
}

fn appendHistoryChatMessagesImpl(
    alloc: Allocator,
    messages: *std.ArrayList(core_types.ChatMessage),
    history: []const HistoryTurn,
    starts_in_leading_summary_prefix: bool,
) !bool {
    var in_leading_summary_prefix = starts_in_leading_summary_prefix;
    for (history) |turn| {
        const summary_is_system = in_leading_summary_prefix;
        in_leading_summary_prefix = continuesLeadingSummaryPrefix(in_leading_summary_prefix, turn);
        switch (turn) {
            .compacted_summary => |entry| {
                const text = try formatCompactedContinuationMessage(alloc, entry.summary);
                errdefer alloc.free(text);
                try messages.append(alloc, .{
                    .role = if (summary_is_system) .system else .user,
                    .content = text,
                });
            },
            .assistant => |entry| {
                try messages.append(alloc, .{ .role = .user, .content = entry.user.text, .images = entry.user.images });
                try appendExecutionMemoryChatMessages(alloc, messages, entry.execution);
                if (entry.assistant.len > 0) {
                    try messages.append(alloc, .{ .role = .assistant, .content = entry.assistant });
                }
            },
            .background_command => |entry| {
                try messages.append(alloc, .{ .role = .user, .content = entry.user.text, .images = entry.user.images });
                try appendExecutionMemoryChatMessages(alloc, messages, entry.execution);
                if (entry.assistant) |assistant| {
                    if (assistant.len > 0) {
                        try messages.append(alloc, .{ .role = .assistant, .content = assistant });
                    }
                }
                const text = try formatBackgroundHistoryContext(alloc, entry);
                errdefer alloc.free(text);
                try messages.append(alloc, .{ .role = .user, .content = text });
            },
            .interrupted => |entry| {
                try messages.append(alloc, .{ .role = .user, .content = entry.user.text, .images = entry.user.images });
                try appendExecutionMemoryChatMessages(alloc, messages, entry.execution);
                if (entry.tool_call) |tool_call| {
                    const assistant_content = try formatInterruptedAssistantToolContent(alloc, entry);
                    const calls = try alloc.alloc(core_types.ToolCall, 1);
                    calls[0] = try core_types.dupeToolCall(alloc, tool_call);
                    try messages.append(alloc, .{ .role = .assistant, .content = assistant_content, .tool_calls = calls });
                    const tool_output = try formatInterruptedToolOutput(alloc, entry);
                    try messages.append(alloc, .{
                        .role = .tool,
                        .content = tool_output,
                        .tool_call_id = tool_call.id,
                        .tool_name = tool_call.name,
                        .tool_result_status = .failure,
                    });
                } else {
                    const assistant_content = try formatInterruptedAssistantClosedContent(alloc, entry);
                    try messages.append(alloc, .{ .role = .assistant, .content = assistant_content });
                }
                const text = try formatInterruptedHistoryContext(alloc, entry);
                errdefer alloc.free(text);
                try messages.append(alloc, .{ .role = .user, .content = text });
            },
        }
    }
    return in_leading_summary_prefix;
}
/// Infers a conversation language tag from text using core's script-counting heuristic.
pub fn inferConversationLanguage(text: []const u8, fallback: ConversationLanguage) ConversationLanguage {
    var counts: ScriptCounts = .{};
    var i: usize = 0;
    while (i < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + width > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + width]) catch {
            i += width;
            continue;
        };
        classifyCodepoint(&counts, codepoint);
        i += width;
    }
    if (counts.hiragana + counts.katakana > 0) return ConversationLanguage.literal("ja");
    if (counts.hangul > 0) return ConversationLanguage.literal("ko");
    const scores = [_]struct { count: usize, tag: ConversationLanguage }{
        .{ .count = counts.han, .tag = ConversationLanguage.literal("und-Hani") },
        .{ .count = counts.arabic, .tag = ConversationLanguage.literal("und-Arab") },
        .{ .count = counts.hebrew, .tag = ConversationLanguage.literal("und-Hebr") },
        .{ .count = counts.cyrillic, .tag = ConversationLanguage.literal("und-Cyrl") },
        .{ .count = counts.greek, .tag = ConversationLanguage.literal("und-Grek") },
        .{ .count = counts.devanagari, .tag = ConversationLanguage.literal("und-Deva") },
        .{ .count = counts.thai, .tag = ConversationLanguage.literal("und-Thai") },
        .{ .count = counts.latin, .tag = ConversationLanguage.literal("und-Latn") },
    };
    var best_count: usize = 0;
    var best_tag = fallback;
    var tied = false;
    for (scores) |entry| {
        if (entry.count == 0) continue;
        if (entry.count > best_count) {
            best_count = entry.count;
            best_tag = entry.tag;
            tied = false;
            continue;
        }
        if (entry.count == best_count) tied = true;
    }
    if (best_count == 0 or tied) return fallback;
    return best_tag;
}

pub fn formatCompactedContinuationMessage(alloc: Allocator, summary: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}{s}\n\n{s}\n{s}",
        .{ compact_continuation_preamble, summary, compact_recent_messages_note, compact_direct_resume_instruction },
    );
}

pub fn formatBackgroundHistoryContext(alloc: Allocator, entry: BackgroundCommandHistoryTurn) ![]u8 {
    if (entry.url) |url| {
        return std.fmt.allocPrint(alloc, "Session event: a previous user request launched a background server. Log: {s}. URL observed at launch: {s}. Re-check runtime context for current liveness before reusing it.", .{ entry.log_path, url });
    }
    if (entry.expect_url) {
        return std.fmt.allocPrint(alloc, "Session event: a previous user request launched a background server. Log: {s}. Re-check runtime context for current liveness and URL state before reusing it.", .{entry.log_path});
    }
    return std.fmt.allocPrint(alloc, "Session event: a previous user request launched a background command. Log: {s}. Re-check runtime context for current liveness before treating it as running.", .{entry.log_path});
}

pub fn formatExecutionFileContext(alloc: Allocator, files: []const core_types.FileEvidence) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    out.writer.writeAll("Session file evidence from previous tool execution. Re-read stale paths before relying on exact contents:") catch return error.OutOfMemory;
    for (files) |file| {
        out.writer.print("\n- action={s} status={s} path={s}", .{ @tagName(file.action), @tagName(file.status), file.path }) catch return error.OutOfMemory;
        if (file.new_path) |new_path| {
            out.writer.print(" new_path={s}", .{new_path}) catch return error.OutOfMemory;
        }
        if (file.model_view_covers_full_file) {
            out.writer.writeAll(" model_view=full") catch return error.OutOfMemory;
        }
        if (file.stale) {
            out.writer.writeAll(" stale=true") catch return error.OutOfMemory;
        }
        out.writer.print(" tool={s}", .{file.tool_name}) catch return error.OutOfMemory;
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn formatExecutionReplayContext(
    alloc: Allocator,
    execution: core_types.ExecutionMemory,
) !?[]u8 {
    if (execution.isEmpty()) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.writeAll("Previous tool execution:") catch return error.OutOfMemory;

    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| {
            if (assistant.len > 0) {
                out.writer.print("\n\nAssistant:\n{s}", .{assistant}) catch return error.OutOfMemory;
            }
        }
        for (step.tool_results) |result| {
            out.writer.print(
                "\n\nTool {s} ({s}):\n{s}",
                .{ result.tool_name, @tagName(result.status), result.output },
            ) catch return error.OutOfMemory;
            for (result.permission_feedback) |feedback| {
                out.writer.print(
                    "\n\nUser permission feedback:\n{s}",
                    .{feedback},
                ) catch return error.OutOfMemory;
            }
        }
    }
    if (execution.files.len > 0) {
        const files = try formatExecutionFileContext(alloc, execution.files);
        defer alloc.free(files);
        out.writer.print("\n\n{s}", .{files}) catch return error.OutOfMemory;
    }

    return out.toOwnedSlice() catch return error.OutOfMemory;
}


pub fn formatInterruptedHistoryContext(alloc: Allocator, entry: InterruptedHistoryTurn) ![]u8 {
    _ = entry;
    return alloc.dupe(u8, interrupted_turn_context);
}

pub fn formatCompletedToolSummary(alloc: Allocator, names: []const []u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    out.writer.print(
        "Interrupted by user after completing {d} tool call{s}: ",
        .{ names.len, if (names.len == 1) "" else "s" },
    ) catch return error.OutOfMemory;
    for (names, 0..) |name, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(name) catch return error.OutOfMemory;
    }
    out.writer.writeByte('.') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn formatInterruptedAssistantToolContent(alloc: Allocator, entry: InterruptedHistoryTurn) Allocator.Error!?[]u8 {
    const assistant = entry.assistant;
    const has_assistant = assistant != null and assistant.?.len > 0;
    const has_completed_tools = entry.completed_tool_names.len > 0;
    if (!has_assistant and !has_completed_tools) return null;

    if (!has_completed_tools) return @as(?[]u8, try alloc.dupe(u8, assistant.?));

    const summary = try formatCompletedToolSummary(alloc, entry.completed_tool_names);
    var owns_summary = true;
    errdefer if (owns_summary) alloc.free(summary);
    if (!has_assistant) return @as(?[]u8, summary);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.print("{s}\n\n{s}", .{ assistant.?, summary }) catch return error.OutOfMemory;
    alloc.free(summary);
    owns_summary = false;
    return @as(?[]u8, out.toOwnedSlice() catch return error.OutOfMemory);
}

fn formatInterruptedAssistantClosedContent(alloc: Allocator, entry: InterruptedHistoryTurn) Allocator.Error![]u8 {
    if (entry.completed_tool_names.len > 0) {
        if (try formatInterruptedAssistantToolContent(alloc, entry)) |text| return text;
    }
    if (entry.assistant) |assistant| {
        if (assistant.len > 0) return formatInterruptedPartialAssistantClosedContent(alloc, assistant);
    }
    return alloc.dupe(u8, interrupted_before_completion_output);
}

fn formatInterruptedPartialAssistantClosedContent(alloc: Allocator, assistant: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ assistant, interrupted_before_completion_output });
}

fn compactHistory(history: *std.ArrayList(HistoryTurn), alloc: Allocator, max_history_turns: usize) !bool {
    if (max_history_turns == 0 or history.items.len <= max_history_turns) return false;

    if (max_history_turns <= 1) {
        while (history.items.len > max_history_turns) {
            const oldest = history.orderedRemove(0);
            freeHistoryTurn(alloc, oldest);
        }
        return true;
    }

    const preserve_recent_turns = preservedRecentTurnCount(max_history_turns);
    const existing_summary_len: usize = if (history.items.len > 0 and history.items[0] == .compacted_summary) 1 else 0;
    if (history.items.len <= existing_summary_len + preserve_recent_turns) return false;

    const keep_from = history.items.len - preserve_recent_turns;
    const removed = history.items[existing_summary_len..keep_from];
    if (removed.len == 0) return false;

    const existing_summary = if (existing_summary_len == 1) history.items[0].compacted_summary else null;
    const next_summary = try buildCompactedSummaryTurn(alloc, existing_summary, removed);
    errdefer freeHistoryTurn(alloc, .{ .compacted_summary = next_summary });

    const preserved_len = history.items.len - keep_from;
    const next_items = try alloc.alloc(HistoryTurn, preserved_len + 1);
    const old_allocated = history.allocatedSlice();

    next_items[0] = .{ .compacted_summary = next_summary };
    if (preserved_len > 0) {
        std.mem.copyForwards(HistoryTurn, next_items[1 .. 1 + preserved_len], history.items[keep_from..]);
    }

    var i: usize = 0;
    while (i < keep_from) : (i += 1) {
        freeHistoryTurn(alloc, history.items[i]);
    }

    alloc.free(old_allocated);
    history.items = next_items;
    history.capacity = next_items.len;
    return true;
}

fn buildCompactedSummaryTurn(
    alloc: Allocator,
    existing: ?CompactedSummaryHistoryTurn,
    removed: []const HistoryTurn,
) !CompactedSummaryHistoryTurn {
    return .{
        .summary = try buildCompactedSummaryText(alloc, existing, removed),
        .removed_turn_count = (if (existing) |entry| entry.removed_turn_count else 0) + removed.len,
        .compaction_count = (if (existing) |entry| entry.compaction_count else 0) + 1,
        .root_user_messages = &.{},
        .root_user_messages_complete = false,
        .permission_feedback = &.{},
        .permission_feedback_complete = false,
    };
}




fn buildCompactedSummaryText(
    alloc: Allocator,
    existing: ?CompactedSummaryHistoryTurn,
    removed: []const HistoryTurn,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(arena);

    try lines.append(arena, "Conversation summary:");
    try lines.append(arena, try std.fmt.allocPrint(arena, "- Earlier turns compacted: {d}", .{removed.len}));

    if (existing) |entry| {
        try lines.append(arena, "- Previously compacted context:");
        var existing_lines = std.mem.splitScalar(u8, entry.summary, '\n');
        while (existing_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            try lines.append(arena, try std.fmt.allocPrint(arena, "  {s}", .{trimmed}));
        }
    }

    try appendUserSummaryLines(arena, &lines, removed);
    try appendAssistantSummaryLines(arena, &lines, removed);
    try appendExecutionSummaryLines(arena, &lines, removed);
    try appendBackgroundSummaryLines(arena, &lines, removed);
    try appendInterruptedSummaryLines(arena, &lines, removed);

    if (lines.items.len <= 2) {
        try lines.append(arena, "- Earlier conversation context compacted.");
    }

    return compressSummaryLines(alloc, lines.items);
}

fn appendUserSummaryLines(arena: Allocator, lines: *std.ArrayList([]const u8), removed: []const HistoryTurn) !void {
    var added: usize = 0;
    var saw_header = false;
    for (removed) |turn| {
        const user_text = switch (turn) {
            .assistant => |entry| entry.user.text,
            .background_command => |entry| entry.user.text,
            .interrupted => |entry| entry.user.text,
            .compacted_summary => continue,
        };

        const summary = compactLineText(arena, user_text, compact_summary_max_line_chars - 4) catch continue;
        if (summary.len == 0) continue;
        if (!saw_header) {
            try lines.append(arena, "- Recent user requests:");
            saw_header = true;
        }
        try lines.append(arena, try std.fmt.allocPrint(arena, "  - {s}", .{summary}));
        added += 1;
        if (added >= 4) break;
    }
}

fn appendAssistantSummaryLines(arena: Allocator, lines: *std.ArrayList([]const u8), removed: []const HistoryTurn) !void {
    var added: usize = 0;
    var saw_header = false;
    for (removed) |turn| {
        const assistant_text = switch (turn) {
            .assistant => |entry| entry.assistant,
            .background_command => |entry| entry.assistant orelse continue,
            .interrupted => |entry| entry.assistant orelse continue,
            else => continue,
        };

        const summary = compactLineText(arena, assistant_text, compact_summary_max_line_chars - 4) catch continue;
        if (summary.len == 0) continue;
        if (!saw_header) {
            try lines.append(arena, "- Assistant outcomes:");
            saw_header = true;
        }
        try lines.append(arena, try std.fmt.allocPrint(arena, "  - {s}", .{summary}));
        added += 1;
        if (added >= 3) break;
    }
}

fn appendExecutionSummaryLines(arena: Allocator, lines: *std.ArrayList([]const u8), removed: []const HistoryTurn) !void {
    var added: usize = 0;
    var saw_header = false;
    for (removed) |turn| {
        const execution = switch (turn) {
            .assistant => |entry| entry.execution,
            .background_command => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            else => continue,
        };

        for (execution.tool_steps) |step| {
            for (step.tool_results) |result| {
                if (!saw_header) {
                    try lines.append(arena, "- Tool execution evidence:");
                    saw_header = true;
                }
                try lines.append(arena, try formatToolResultEvidenceLine(arena, result));
                added += 1;
                if (added >= 4) return;
            }
        }

        for (execution.files) |file| {
            if (!saw_header) {
                try lines.append(arena, "- Tool execution evidence:");
                saw_header = true;
            }
            const stale = if (file.stale) ", stale" else "";
            try lines.append(arena, try std.fmt.allocPrint(arena, "  - file {s}: {s}{s}", .{ @tagName(file.action), file.path, stale }));
            added += 1;
            if (added >= 4) return;
        }
    }
}

fn formatBudgetTrimmedHistoryContext(alloc: Allocator, history: []const HistoryTurn, keep: []const bool) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(arena);

    var omitted: usize = 0;
    for (keep) |kept| {
        if (!kept) omitted += 1;
    }
    try lines.append(arena, try std.fmt.allocPrint(arena, "Context budget trimmed {d} older history turn(s). Recent turns are preserved verbatim.", .{omitted}));
    try appendBudgetCompactedSummaryLines(arena, &lines, history, keep);
    try lines.append(arena, "Preserved key evidence from trimmed turns:");

    var added: usize = 0;
    for (history, 0..) |turn, idx| {
        if (keep[idx]) continue;
        added += try appendBudgetEvidenceForTurn(arena, &lines, turn, 6 - @min(added, 6));
        if (added >= 6) break;
    }
    if (added == 0) try lines.append(arena, "- No tool evidence was present in trimmed turns.");
    return compressSummaryLines(alloc, lines.items);
}

fn appendBudgetCompactedSummaryLines(arena: Allocator, lines: *std.ArrayList([]const u8), history: []const HistoryTurn, keep: []const bool) !void {
    for (history, 0..) |turn, idx| {
        if (keep[idx]) continue;
        const entry = switch (turn) {
            .compacted_summary => |value| value,
            else => continue,
        };

        try lines.append(arena, "Preserved compacted summary from trimmed history:");
        var added: usize = 0;
        var summary_lines = std.mem.splitScalar(u8, entry.summary, '\n');
        while (summary_lines.next()) |line| {
            const summary = compactLineText(arena, line, compact_summary_max_line_chars - 4) catch continue;
            if (summary.len == 0) continue;
            try lines.append(arena, try std.fmt.allocPrint(arena, "- {s}", .{summary}));
            added += 1;
            if (added >= 6) break;
        }
        if (added == 0) try lines.append(arena, "- Compacted summary was present but empty.");
        return;
    }
}

fn appendBudgetEvidenceForTurn(arena: Allocator, lines: *std.ArrayList([]const u8), turn: HistoryTurn, remaining: usize) !usize {
    if (remaining == 0) return 0;
    const execution = switch (turn) {
        .assistant => |entry| entry.execution,
        .background_command => |entry| entry.execution,
        .interrupted => |entry| entry.execution,
        else => return 0,
    };
    var added: usize = 0;
    for (execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            try lines.append(arena, try formatToolResultEvidenceLine(arena, result));
            added += 1;
            if (added >= remaining) return added;
        }
    }
    for (execution.files) |file| {
        const stale = if (file.stale) ", stale" else "";
        try lines.append(arena, try std.fmt.allocPrint(arena, "- file {s}: {s}{s}", .{ @tagName(file.action), file.path, stale }));
        added += 1;
        if (added >= remaining) return added;
    }
    return added;
}

fn formatToolResultEvidenceLine(arena: Allocator, result: core_types.PersistedToolResult) ![]const u8 {
    if (result.output_handle) |handle| {
        if (result.preview) |preview| {
            const compact_preview = try compactLineText(arena, preview, 96);
            return std.fmt.allocPrint(arena, "- {s} {s} ({d} stored bytes, handle={s}, preview={s})", .{ result.tool_name, @tagName(result.status), result.stored_output_bytes, handle, compact_preview });
        }
        return std.fmt.allocPrint(arena, "- {s} {s} ({d} stored bytes, handle={s})", .{ result.tool_name, @tagName(result.status), result.stored_output_bytes, handle });
    }
    return std.fmt.allocPrint(arena, "- {s} {s} ({d} stored bytes)", .{ result.tool_name, @tagName(result.status), result.stored_output_bytes });
}

fn estimateHistoryTurnTokens(turn: HistoryTurn) usize {
    return switch (turn) {
        .compacted_summary => |entry| estimateTextTokens(entry.summary),
        .assistant => |entry| estimateTextTokens(entry.user.text) + estimateTextTokens(entry.assistant) + estimateExecutionTokens(entry.execution),
        .background_command => |entry| estimateTextTokens(entry.user.text) +
            (if (entry.assistant) |assistant| estimateTextTokens(assistant) else 0) +
            estimateExecutionTokens(entry.execution) +
            estimateTextTokens(entry.log_path) +
            (if (entry.url) |url| estimateTextTokens(url) else 0),
        .interrupted => |entry| estimateTextTokens(entry.user.text) +
            (if (entry.assistant) |assistant| estimateTextTokens(assistant) else 0) +
            estimateExecutionTokens(entry.execution),
    };
}

fn estimateExecutionTokens(execution: core_types.ExecutionMemory) usize {
    var total: usize = 0;
    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| total += estimateTextTokens(assistant);
        for (step.tool_calls) |call| {
            total += estimateTextTokens(call.name) + estimateTextTokens(call.arguments_json);
        }
        for (step.tool_results) |result| {
            if (result.preview) |preview| {
                total += estimateTextTokens(preview);
            } else {
                total += estimateTextTokens(result.output);
            }
            if (result.output_handle) |handle| total += estimateTextTokens(handle);
            for (result.permission_feedback) |feedback| {
                total += estimateTextTokens(feedback);
            }
        }
    }
    for (execution.files) |file| {
        total += estimateTextTokens(file.path) + estimateTextTokens(file.tool_name);
    }
    return total;
}

fn estimateTextTokens(text: []const u8) usize {
    var count: usize = 0;
    var span_len: usize = 0;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (span_len > 0) {
                count += (span_len + 3) / 4;
                span_len = 0;
            }
        } else {
            span_len += 1;
        }
    }
    if (span_len > 0) count += (span_len + 3) / 4;
    return count;
}

fn appendBackgroundSummaryLines(arena: Allocator, lines: *std.ArrayList([]const u8), removed: []const HistoryTurn) !void {
    var added: usize = 0;
    var saw_header = false;
    for (removed) |turn| {
        const entry = switch (turn) {
            .background_command => |value| value,
            else => continue,
        };

        if (!saw_header) {
            try lines.append(arena, "- Background activity:");
            saw_header = true;
        }

        const line = if (entry.url) |url|
            try std.fmt.allocPrint(arena, "  - log={s}, url={s}", .{ entry.log_path, url })
        else if (entry.expect_url)
            try std.fmt.allocPrint(arena, "  - log={s}, local server started (URL pending)", .{entry.log_path})
        else
            try std.fmt.allocPrint(arena, "  - log={s}", .{entry.log_path});
        try lines.append(arena, line);
        added += 1;
        if (added >= 3) break;
    }
}

fn appendInterruptedSummaryLines(arena: Allocator, lines: *std.ArrayList([]const u8), removed: []const HistoryTurn) !void {
    var added: usize = 0;
    var saw_header = false;
    for (removed) |turn| {
        const entry = switch (turn) {
            .interrupted => |value| value,
            else => continue,
        };

        if (!saw_header) {
            try lines.append(arena, "- Incomplete turns:");
            saw_header = true;
        }

        const line = try std.fmt.allocPrint(
            arena,
            "  - {s}",
            .{interruptedTurnNotice(entry).body},
        );
        try lines.append(arena, line);
        added += 1;
        if (added >= 3) break;
    }
}

fn compressSummaryLines(alloc: Allocator, lines: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(alloc);

    var line_count: usize = 0;
    var char_count: usize = 0;
    var omitted: usize = 0;

    for (lines) |line| {
        const normalized = std.mem.trim(u8, line, " \t\r\n");
        if (normalized.len == 0) continue;
        if (containsLine(seen.items, normalized)) {
            omitted += 1;
            continue;
        }

        try seen.append(alloc, normalized);

        const candidate_chars = normalized.len + @intFromBool(line_count > 0);
        if (line_count >= compact_summary_max_lines or char_count + candidate_chars > compact_summary_max_chars) {
            omitted += 1;
            continue;
        }

        if (line_count > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(normalized);
        line_count += 1;
        char_count += candidate_chars;
    }

    if (omitted > 0 and line_count < compact_summary_max_lines) {
        const notice = try std.fmt.allocPrint(alloc, "- ... {d} additional line(s) omitted.", .{omitted});
        defer alloc.free(notice);
        const candidate_chars = notice.len + @intFromBool(line_count > 0);
        if (char_count + candidate_chars <= compact_summary_max_chars) {
            if (line_count > 0) try out.writer.writeByte('\n');
            try out.writer.writeAll(notice);
        }
    }

    return try out.toOwnedSlice();
}

fn containsLine(lines: []const []const u8, candidate: []const u8) bool {
    for (lines) |line| {
        if (std.mem.eql(u8, line, candidate)) return true;
    }
    return false;
}

fn preservedRecentTurnCount(max_history_turns: usize) usize {
    if (max_history_turns <= 2) return 1;
    return @min(max_history_turns - 1, 4);
}

fn compactLineText(arena: Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    var wrote_space = false;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        const is_space = byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t';
        if (is_space) {
            if (out.written().len > 0) wrote_space = true;
            i += 1;
            continue;
        }

        if (wrote_space and out.written().len < max_bytes) {
            try out.writer.writeByte(' ');
            wrote_space = false;
        }
        if (out.written().len >= max_bytes) break;
        const next_i = text_utils.utf8ForwardBoundary(text, i + 1);
        const codepoint_len = next_i - i;
        if (codepoint_len > max_bytes - out.written().len) break;
        try out.writer.writeAll(text[i..next_i]);
        i = next_i;
    }

    const written = std.mem.trim(u8, out.written(), " \t\r\n");
    return if (written.len == 0) arena.dupe(u8, "") else arena.dupe(u8, written);
}

const ScriptCounts = struct {
    latin: usize = 0,
    cyrillic: usize = 0,
    arabic: usize = 0,
    hebrew: usize = 0,
    devanagari: usize = 0,
    thai: usize = 0,
    greek: usize = 0,
    hangul: usize = 0,
    hiragana: usize = 0,
    katakana: usize = 0,
    han: usize = 0,
};
fn classifyCodepoint(counts: *ScriptCounts, codepoint: u21) void {
    if (isLatinCodepoint(codepoint)) {
        counts.latin += 1;
        return;
    }
    if (isCyrillicCodepoint(codepoint)) {
        counts.cyrillic += 1;
        return;
    }
    if (isArabicCodepoint(codepoint)) {
        counts.arabic += 1;
        return;
    }
    if (isHebrewCodepoint(codepoint)) {
        counts.hebrew += 1;
        return;
    }
    if (isDevanagariCodepoint(codepoint)) {
        counts.devanagari += 1;
        return;
    }
    if (isThaiCodepoint(codepoint)) {
        counts.thai += 1;
        return;
    }
    if (isGreekCodepoint(codepoint)) {
        counts.greek += 1;
        return;
    }
    if (isHangulCodepoint(codepoint)) {
        counts.hangul += 1;
        return;
    }
    if (codepoint >= 0x3040 and codepoint <= 0x309F) {
        counts.hiragana += 1;
        return;
    }
    if ((codepoint >= 0x30A0 and codepoint <= 0x30FF) or (codepoint >= 0x31F0 and codepoint <= 0x31FF) or (codepoint >= 0xFF66 and codepoint <= 0xFF9F)) {
        counts.katakana += 1;
        return;
    }
    if (isHanCodepoint(codepoint)) {
        counts.han += 1;
    }
}
fn isLatinCodepoint(codepoint: u21) bool {
    return (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z') or
        (codepoint >= 0x00C0 and codepoint <= 0x024F) or
        (codepoint >= 0x1E00 and codepoint <= 0x1EFF);
}
fn isCyrillicCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x0400 and codepoint <= 0x052F) or
        (codepoint >= 0x2DE0 and codepoint <= 0x2DFF) or
        (codepoint >= 0xA640 and codepoint <= 0xA69F);
}
fn isArabicCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x0600 and codepoint <= 0x06FF) or
        (codepoint >= 0x0750 and codepoint <= 0x077F) or
        (codepoint >= 0x08A0 and codepoint <= 0x08FF) or
        (codepoint >= 0xFB50 and codepoint <= 0xFDFF) or
        (codepoint >= 0xFE70 and codepoint <= 0xFEFF);
}
fn isHebrewCodepoint(codepoint: u21) bool {
    return codepoint >= 0x0590 and codepoint <= 0x05FF;
}
fn isDevanagariCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x0900 and codepoint <= 0x097F) or
        (codepoint >= 0xA8E0 and codepoint <= 0xA8FF);
}
fn isThaiCodepoint(codepoint: u21) bool {
    return codepoint >= 0x0E00 and codepoint <= 0x0E7F;
}
fn isGreekCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x0370 and codepoint <= 0x03FF) or
        (codepoint >= 0x1F00 and codepoint <= 0x1FFF);
}
fn isHangulCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x11FF) or
        (codepoint >= 0x3130 and codepoint <= 0x318F) or
        (codepoint >= 0xA960 and codepoint <= 0xA97F) or
        (codepoint >= 0xAC00 and codepoint <= 0xD7AF) or
        (codepoint >= 0xD7B0 and codepoint <= 0xD7FF);
}
fn isHanCodepoint(codepoint: u21) bool {
    return (codepoint >= 0x3400 and codepoint <= 0x4DBF) or
        (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or
        (codepoint >= 0x20000 and codepoint <= 0x2A6DF) or
        (codepoint >= 0x2A700 and codepoint <= 0x2B73F) or
        (codepoint >= 0x2B740 and codepoint <= 0x2B81F) or
        (codepoint >= 0x2B820 and codepoint <= 0x2CEAF);
}
































fn expectCanonicalHistoryFixtureUnchanged(
    canonical: []const HistoryTurn,
    context_history_start: usize,
) !void {
    try std.testing.expectEqual(@as(usize, 1), context_history_start);
    try std.testing.expectEqual(@as(usize, 3), canonical.len);
    try std.testing.expectEqualStrings(
        "canonical prefix",
        canonical[0].assistant.user.text,
    );
    try std.testing.expectEqualStrings(
        "prefix assistant",
        canonical[0].assistant.assistant,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[0].assistant.user.images.len);
    try std.testing.expectEqual(@as(usize, 1), canonical[0].assistant.user.images[0].id);
    try std.testing.expectEqualStrings(
        "/tmp/prefix.png",
        canonical[0].assistant.user.images[0].path,
    );
    try std.testing.expectEqualStrings(
        "image/png",
        canonical[0].assistant.user.images[0].media_type,
    );
    try std.testing.expectEqualStrings(
        "canonical background",
        canonical[1].background_command.user.text,
    );
    try std.testing.expectEqualStrings(
        "background assistant",
        canonical[1].background_command.assistant.?,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].background_command.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "checking preserved evidence",
        canonical[1].background_command.execution.tool_steps[0].assistant.?,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].background_command.execution.tool_steps[0].tool_calls.len);
    try std.testing.expectEqualStrings(
        "call_preserved",
        canonical[1].background_command.execution.tool_steps[0].tool_calls[0].id,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[1].background_command.execution.tool_steps[0].tool_calls[0].name,
    );
    try std.testing.expectEqualStrings(
        "{\"path\":\"fixture.txt\"}",
        canonical[1].background_command.execution.tool_steps[0].tool_calls[0].arguments_json,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[1].background_command.execution.tool_steps[0].tool_results.len);
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        canonical[1].background_command.execution.tool_steps[0].tool_results[0].status,
    );
    try std.testing.expectEqualStrings(
        "preserved failure",
        canonical[1].background_command.execution.tool_steps[0].tool_results[0].output,
    );
    try std.testing.expectEqualStrings(
        "result-call_preserved.txt",
        canonical[1].background_command.execution.tool_steps[0].tool_results[0].output_handle.?,
    );
    try std.testing.expectEqualStrings(
        "preserved preview",
        canonical[1].background_command.execution.tool_steps[0].tool_results[0].preview.?,
    );
    try std.testing.expectEqual(@as(usize, 17), canonical[1].background_command.execution.tool_steps[0].tool_results[0].output_bytes);
    try std.testing.expectEqual(@as(usize, 17), canonical[1].background_command.execution.tool_steps[0].tool_results[0].stored_output_bytes);
    try std.testing.expectEqual(@as(usize, 1), canonical[1].background_command.execution.files.len);
    try std.testing.expectEqualStrings(
        "src/preserved.zig",
        canonical[1].background_command.execution.files[0].path,
    );
    try std.testing.expectEqualStrings(
        "src/preserved-renamed.zig",
        canonical[1].background_command.execution.files[0].new_path.?,
    );
    try std.testing.expectEqualStrings(
        "call_preserved",
        canonical[1].background_command.execution.files[0].tool_call_id,
    );
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[1].background_command.execution.files[0].tool_name,
    );
    try std.testing.expectEqual(
        FileEvidenceAction.rename,
        canonical[1].background_command.execution.files[0].action,
    );
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        canonical[1].background_command.execution.files[0].status,
    );
    try std.testing.expect(canonical[1].background_command.execution.files[0].model_view_covers_full_file);
    try std.testing.expect(canonical[1].background_command.execution.files[0].stale);
    try std.testing.expectEqualStrings(
        "/tmp/preserved.log",
        canonical[1].background_command.log_path,
    );
    try std.testing.expect(canonical[1].background_command.expect_url);
    try std.testing.expectEqualStrings(
        "http://localhost:3000",
        canonical[1].background_command.url.?,
    );
    try std.testing.expectEqualStrings(
        "canonical interrupted",
        canonical[2].interrupted.user.text,
    );
    try std.testing.expectEqualStrings(
        "partial assistant",
        canonical[2].interrupted.assistant.?,
    );
    try std.testing.expectEqualStrings(
        "call_interrupted",
        canonical[2].interrupted.tool_call.?.id,
    );
    try std.testing.expectEqualStrings(
        "browser_navigate",
        canonical[2].interrupted.tool_call.?.name,
    );
    try std.testing.expectEqualStrings(
        "{\"url\":\"http://localhost:3000\"}",
        canonical[2].interrupted.tool_call.?.arguments_json,
    );
    try std.testing.expectEqual(@as(usize, 1), canonical[2].interrupted.completed_tool_names.len);
    try std.testing.expectEqualStrings(
        "read_file",
        canonical[2].interrupted.completed_tool_names[0],
    );
}

fn checkPromptHistorySnapshotAllocationFailures(alloc: Allocator) !void {
    var prefix_images = [_]ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/prefix.png"),
        .media_type = @constCast("image/png"),
    }};
    var calls = [_]ToolCall{.{
        .id = "call_preserved",
        .name = "read_file",
        .arguments_json = "{\"path\":\"fixture.txt\"}",
    }};
    var results = [_]PersistedToolResult{.{
        .tool_call_id = @constCast("call_preserved"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast("preserved failure"),
        .output_bytes = 17,
        .stored_output_bytes = 17,
        .output_handle = @constCast("result-call_preserved.txt"),
        .preview = @constCast("preserved preview"),
    }};
    var files = [_]FileEvidence{.{
        .path = @constCast("src/preserved.zig"),
        .new_path = @constCast("src/preserved-renamed.zig"),
        .tool_call_id = @constCast("call_preserved"),
        .tool_name = @constCast("read_file"),
        .action = .rename,
        .status = .failure,
        .model_view_covers_full_file = true,
        .stale = true,
    }};
    var steps = [_]ToolExecutionStep{.{
        .assistant = @constCast("checking preserved evidence"),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var completed_tool_names = [_][]u8{@constCast("read_file")};
    var canonical = [_]HistoryTurn{
        .{ .assistant = .{
            .user = .{
                .text = @constCast("canonical prefix"),
                .images = prefix_images[0..],
            },
            .assistant = @constCast("prefix assistant"),
        } },
        .{ .background_command = .{
            .user = .{ .text = @constCast("canonical background") },
            .assistant = @constCast("background assistant"),
            .execution = .{
                .tool_steps = steps[0..],
                .files = files[0..],
            },
            .log_path = @constCast("/tmp/preserved.log"),
            .expect_url = true,
            .url = @constCast("http://localhost:3000"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("canonical interrupted") },
            .assistant = @constCast("partial assistant"),
            .tool_call = .{
                .id = "call_interrupted",
                .name = "browser_navigate",
                .arguments_json = "{\"url\":\"http://localhost:3000\"}",
            },
            .completed_tool_names = completed_tool_names[0..],
        } },
    };
    const context_history_start: usize = 1;

    const prompt_history = snapshotOwnedContextHistory(
        alloc,
        &canonical,
        context_history_start,
        8,
    ) catch |err| {
        try expectCanonicalHistoryFixtureUnchanged(
            &canonical,
            context_history_start,
        );
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };
    defer freeHistoryTurnSlice(alloc, prompt_history);
    try expectCanonicalHistoryFixtureUnchanged(
        &canonical,
        context_history_start,
    );
}


fn checkPromptHistoryMessageProjectionAllocationFailures(
    alloc: Allocator,
    prompt_history: []const HistoryTurn,
) !void {
    var messages: std.ArrayList(message.Message) = .empty;
    defer deinitMessages(alloc, &messages);

    appendHistoryMessagesBudgeted(
        alloc,
        &messages,
        prompt_history,
        .{ .max_tokens = 1 },
    ) catch |err| {
        try std.testing.expectEqualStrings(
            "old user",
            prompt_history[0].assistant.user.text,
        );
        try std.testing.expectEqualStrings(
            "latest user",
            prompt_history[1].assistant.user.text,
        );
        try std.testing.expectEqual(
            PersistedToolStatus.failure,
            prompt_history[1].assistant.execution.tool_steps[0].tool_results[0].status,
        );
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expect(messages.items.len >= 6);
    try std.testing.expectEqualStrings(
        "latest user",
        messages.items[messages.items.len - 5].content.?.asText(),
    );
    try std.testing.expectEqual(
        PersistedToolStatus.failure,
        messages.items[messages.items.len - 3].tool_result_status.?,
    );
    try std.testing.expect(std.mem.find(
        u8,
        messages.items[messages.items.len - 2].content.?.asText(),
        "src/latest.zig",
    ) != null);
}







fn checkWorkProvenanceOwnershipFailures(alloc: Allocator) !void {
    var images = [_]ImageAttachment{.{
        .id = 1,
        .path = @constCast("/tmp/image.png"),
        .media_type = @constCast("image/png"),
    }};
    const copy = try dupeUserTurn(alloc, .{
        .text = @constCast("prompt"),
        .images = &images,
        .work_id = @constCast("work-owned"),
    });
    freeUserTurn(alloc, copy);
}








fn checkImageCatalogHistoryMergeAllocationFailures(alloc: Allocator) !void {
    const catalog = [_]ImageAttachment{.{
        .id = 2,
        .path = @constCast("/tmp/history.png"),
        .media_type = @constCast("image/png"),
    }};
    var added = [_]ImageAttachment{.{
        .id = 8,
        .path = @constCast("/tmp/completed.png"),
        .media_type = @constCast("image/png"),
    }};
    const turn: HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("completed"), .images = &added },
        .assistant = @constCast("done"),
    } };
    const merged = try merge_image_catalog_history_turn(alloc, &catalog, turn);
    defer core_types.freeImageAttachmentSlice(alloc, merged);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
}
















fn deinitMessages(alloc: Allocator, messages: *std.ArrayList(message.Message)) void {
    for (messages.items) |*msg| msg.deinit(alloc);
    messages.deinit(alloc);
}
