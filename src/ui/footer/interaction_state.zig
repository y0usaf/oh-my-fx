const std = @import("std");
const approval_decision = @import("../../core/permissions/approval_decision.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const permission_request = @import("../../core/permissions/permission_request.zig");
const types = @import("../../core/shared/types.zig");
const input_action = @import("../../core/input/input_action.zig");
const ui_input = @import("../input/runtime.zig");

const Allocator = std.mem.Allocator;
const ApprovalPrompt = approval_prompt.ApprovalPrompt;

pub const approval_chrome_rows: u16 = 3;
pub const approval_panel_rows_compact: u16 = 8;
pub const approval_panel_rows_spacious: u16 = 11;
pub const approval_spacious_min_terminal_rows: u16 = 34;
pub const approval_once_label = "1. Yes";
pub const approval_always_file_label = "2. Yes, and don't ask again for this request";
pub const approval_deny_label = "3. No";
pub const approval_hint = "1–3 Choose now    ↑↓ or Tab Options    Enter Confirm    Esc Cancel";
pub const approval_amendment_hint = "1–3 Choose now    ↑↓ Options    Tab Amend    Enter Confirm    Esc Cancel";
pub const approval_hint_compact = "1–3 Choose now    Enter Confirm    Esc Cancel";
pub const approval_hint_minimal = "Enter Confirm    Esc Cancel";
// Ordered widest-first; every variant keeps the enter/esc controls so narrow
// terminals never lose the submit and cancel instructions.
pub const approval_hint_variants = [_][]const u8{ approval_hint, approval_hint_compact, approval_hint_minimal };
pub const approval_amendment_hint_variants = [_][]const u8{ approval_amendment_hint, approval_hint_compact, approval_hint_minimal };

pub const ApprovalScreenCommit = struct {
    request_id: u64,
    rows: u16,
    cols: u16,
    file_identity_visible: bool,
    all_decision_controls_visible: bool,
    changed_or_notice_visible: bool,
    document_scrollable: bool,
};

pub const ApprovalScreenState = struct {
    document_scroll_rows: usize = 0,
    screen_commit: ?ApprovalScreenCommit = null,
    changed_or_notice_observed: bool = false,
    file_document_hydrated: bool = false,

    pub fn clear(self: *ApprovalScreenState) void {
        self.* = .{};
    }

    pub fn scrollDocument(self: *ApprovalScreenState, delta: i32) void {
        if (delta < 0) {
            const amount: usize = @intCast(-@as(i64, delta));
            self.document_scroll_rows -|= amount;
        } else {
            self.document_scroll_rows +|= @intCast(delta);
        }
    }

    pub fn clampDocumentScroll(self: *ApprovalScreenState, max_scroll_rows: usize) void {
        self.document_scroll_rows = @min(self.document_scroll_rows, max_scroll_rows);
    }

    pub fn invalidateScreenCommit(self: *ApprovalScreenState) void {
        self.screen_commit = null;
    }

    pub fn markFileDocumentHydrated(self: *ApprovalScreenState) void {
        self.file_document_hydrated = true;
    }

    pub fn recordScreenCommit(
        self: *ApprovalScreenState,
        request_id: u64,
        commit: ApprovalScreenCommit,
    ) void {
        if (request_id != commit.request_id) return;
        self.screen_commit = commit;
        self.changed_or_notice_observed = self.changed_or_notice_observed or
            commit.changed_or_notice_visible;
    }
};

fn applyApprovalByteForTest(
    prompt: *ApprovalPrompt,
    alloc: Allocator,
    byte: u8,
    max_len: ?usize,
) !approval_decision.Event {
    const action = ui_input.approvalActionFromByte(byte) orelse return .none;
    const amendment_allowed: ?bool = if (prompt.request) |request|
        request.amendment_allowed
    else
        null;
    return prompt.decision.apply(
        alloc,
        action,
        amendment_allowed,
        max_len,
    );
}










