const std = @import("std");
const usage_report = @import("usage_report.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    active: bool = false,
    requested_scope: usage_report.Scope = .days_30,
    selected_model: usize = 0,
    expanded_model: ?usize = null,
    model_window_start: usize = 0,
    snapshot: ?usage_report.Snapshot = null,
    refresh_error: ?[]u8 = null,

    /// Takes ownership of `snapshot`; the caller must not deinitialize it.
    pub fn openOwned(
        self: *State,
        alloc: Allocator,
        snapshot: usage_report.Snapshot,
    ) void {
        self.close(alloc);
        self.* = .{
            .active = true,
            .requested_scope = snapshot.scope,
            .snapshot = snapshot,
        };
    }

    pub fn openError(
        self: *State,
        alloc: Allocator,
        scope_value: usage_report.Scope,
        message: []const u8,
    ) Allocator.Error!void {
        self.close(alloc);
        self.* = .{
            .active = true,
            .requested_scope = scope_value,
            .refresh_error = try alloc.dupe(u8, message),
        };
    }

    pub fn openLoading(
        self: *State,
        alloc: Allocator,
        scope_value: usage_report.Scope,
    ) void {
        self.close(alloc);
        self.* = .{
            .active = true,
            .requested_scope = scope_value,
        };
    }

    pub fn setLoadingScope(
        self: *State,
        alloc: Allocator,
        scope_value: usage_report.Scope,
    ) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(alloc);
        if (self.refresh_error) |message| alloc.free(message);
        self.snapshot = null;
        self.refresh_error = null;
        self.requested_scope = scope_value;
        self.selected_model = 0;
        self.expanded_model = null;
        self.model_window_start = 0;
    }

    pub fn close(self: *State, alloc: Allocator) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(alloc);
        if (self.refresh_error) |message| alloc.free(message);
        self.* = .{};
    }

    /// Replaces the frozen snapshot while retaining selection and expansion by
    /// model identifier when that model still exists.
    pub fn replaceOwned(
        self: *State,
        alloc: Allocator,
        snapshot: usage_report.Snapshot,
    ) void {
        const old_selected = if (self.snapshot) |old|
            if (old.models.len > 0)
                old.models[@min(self.selected_model, old.models.len - 1)].model
            else
                null
        else
            null;
        const old_expanded = if (self.snapshot) |old|
            if (self.expanded_model) |index|
                if (index < old.models.len) old.models[index].model else null
            else
                null
        else
            null;

        const selected = findModel(snapshot.models, old_selected) orelse
            @min(self.selected_model, snapshot.models.len -| 1);
        const expanded = findModel(snapshot.models, old_expanded);
        if (self.snapshot) |*old| old.deinit(alloc);
        if (self.refresh_error) |message| alloc.free(message);
        self.snapshot = snapshot;
        self.requested_scope = snapshot.scope;
        self.selected_model = selected;
        self.expanded_model = expanded;
        self.refresh_error = null;
        self.model_window_start = @min(self.model_window_start, selected);
    }

    pub fn recordRefreshFailure(
        self: *State,
        alloc: Allocator,
        attempted_scope: usage_report.Scope,
        message: []const u8,
    ) Allocator.Error!void {
        const owned = try alloc.dupe(u8, message);
        if (self.refresh_error) |old| alloc.free(old);
        self.refresh_error = owned;
        self.requested_scope = attempted_scope;
    }

    pub fn moveModel(
        self: *State,
        delta: i32,
        visible_model_rows: usize,
    ) bool {
        if (!self.active or delta == 0) return false;
        const snapshot = self.snapshot orelse return false;
        if (snapshot.models.len == 0) return false;
        const next = if (delta > 0)
            @min(self.selected_model +| 1, snapshot.models.len - 1)
        else
            self.selected_model -| 1;
        if (next == self.selected_model) return false;
        self.selected_model = next;
        self.keepSelectionVisible(visible_model_rows);
        return true;
    }

    pub fn toggleExpanded(self: *State, visible_model_rows: usize) bool {
        if (!self.active) return false;
        const snapshot = self.snapshot orelse return false;
        if (snapshot.models.len == 0) return false;
        const selected = @min(self.selected_model, snapshot.models.len - 1);
        self.expanded_model = if (self.expanded_model == selected) null else selected;
        self.keepSelectionVisible(visible_model_rows);
        return true;
    }

    pub fn scope(self: *const State) usage_report.Scope {
        return if (self.snapshot) |snapshot| snapshot.scope else self.requested_scope;
    }

    pub fn navigationScope(self: *const State) usage_report.Scope {
        return self.requested_scope;
    }

    fn keepSelectionVisible(self: *State, visible_model_rows: usize) void {
        const visible = @max(visible_model_rows, 1);
        if (self.selected_model < self.model_window_start) {
            self.model_window_start = self.selected_model;
        } else if (self.selected_model >= self.model_window_start +| visible) {
            self.model_window_start = self.selected_model - (visible - 1);
        }
    }
};

fn findModel(
    models: []const usage_report.ModelUsage,
    target: ?[]const u8,
) ?usize {
    const name = target orelse return null;
    for (models, 0..) |model, index| {
        if (std.mem.eql(u8, model.model, name)) return index;
    }
    return null;
}





fn testTotals(tokens: u64) usage_report.Totals {
    return .{
        .total_tokens = tokens,
        .input_tokens = tokens,
        .output_tokens = 0,
        .cache_read_tokens = 0,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .request_count = 1,
        .total_cost = 0,
    };
}
