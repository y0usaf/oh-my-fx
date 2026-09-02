const std = @import("std");

const Allocator = std.mem.Allocator;
const max_input_bytes = 4096;

pub const Runtime = struct {
    expected_terminal_row: u16 = 0,
    input: std.ArrayList(u8) = .empty,
    is_active: bool = false,
    is_disabled: bool = false,
    late_response_pending: bool = false,

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.input.deinit(alloc);
    }

    pub fn active(self: Runtime) bool {
        return self.is_active;
    }

    pub fn disabled(self: Runtime) bool {
        return self.is_disabled;
    }

    pub fn expectedRow(self: Runtime) u16 {
        std.debug.assert(self.is_active);
        return self.expected_terminal_row;
    }

    pub fn retainedInput(self: Runtime) []const u8 {
        return self.input.items;
    }

    pub fn begin(
        self: *Runtime,
        alloc: Allocator,
        expected_row: u16,
        first_byte: u8,
    ) !void {
        std.debug.assert(!self.is_active);
        std.debug.assert(expected_row > 0);
        self.input.clearRetainingCapacity();
        try self.input.append(alloc, first_byte);
        self.expected_terminal_row = expected_row;
        self.is_active = true;
        self.late_response_pending = false;
    }

    pub fn canRetainBytes(self: Runtime, byte_len: usize) bool {
        return byte_len <= max_input_bytes -| self.input.items.len;
    }

    pub fn retainBytes(
        self: *Runtime,
        alloc: Allocator,
        bytes: []const u8,
    ) !void {
        std.debug.assert(self.is_active);
        if (!self.canRetainBytes(bytes.len)) return error.NativeClearProbeInputOverflow;
        try self.input.appendSlice(alloc, bytes);
    }

    pub fn settle(self: *Runtime) []const u8 {
        std.debug.assert(self.is_active);
        self.is_active = false;
        self.expected_terminal_row = 0;
        return self.input.items;
    }

    pub fn clearSettledInput(self: *Runtime) void {
        std.debug.assert(!self.is_active);
        self.input.clearRetainingCapacity();
    }

    pub fn disable(self: *Runtime, await_late_response: bool) void {
        self.is_disabled = true;
        self.late_response_pending = await_late_response;
    }

    pub fn awaitingLateResponse(self: Runtime) bool {
        return self.late_response_pending;
    }

    pub fn finishLateResponse(self: *Runtime) void {
        self.late_response_pending = false;
    }
};
