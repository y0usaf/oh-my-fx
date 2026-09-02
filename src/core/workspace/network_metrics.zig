// In-memory ring buffer of recent gateway HTTP calls. Used by /trace
// to surface latency / error patterns without forcing a persistent trace
// log. Process-wide and lock-protected: callers do not need to plumb the
// buffer through their context.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const max_model_len: usize = 64;
pub const max_error_len: usize = 48;
pub const max_stop_reason_len: usize = 48;
pub const max_gateway_schema_diagnostic_len: usize = 160;
pub const max_gateway_request_shape_len: usize = 512;
pub const ring_capacity: usize = 32;

pub const NetworkCallKind = enum {
    gateway,
    web_search,
    web_fetch_target,
};

pub const NetworkCall = struct {
    kind: NetworkCallKind = .gateway,
    started_at_ms: i64 = 0,
    duration_ms: u32 = 0,
    status: u16 = 0,
    response_bytes: u32 = 0,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    is_web_search: bool = false,
    web_search_requests: u32 = 0,
    turn_id: u64 = 0,
    step_id: u64 = 0,
    subagent_id: u64 = 0,
    model_buf: [max_model_len]u8 = [_]u8{0} ** max_model_len,
    model_len: u8 = 0,
    error_buf: [max_error_len]u8 = [_]u8{0} ** max_error_len,
    error_len: u8 = 0,
    stop_reason_buf: [max_stop_reason_len]u8 = [_]u8{0} ** max_stop_reason_len,
    stop_reason_len: u8 = 0,
    gateway_schema_diagnostic_buf: [max_gateway_schema_diagnostic_len]u8 = [_]u8{0} ** max_gateway_schema_diagnostic_len,
    gateway_schema_diagnostic_len: u16 = 0,
    gateway_request_shape_buf: [max_gateway_request_shape_len]u8 = [_]u8{0} ** max_gateway_request_shape_len,
    gateway_request_shape_len: u16 = 0,

    pub fn model(self: *const NetworkCall) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn errorName(self: *const NetworkCall) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn terminalStopReason(self: *const NetworkCall) []const u8 {
        return self.stop_reason_buf[0..self.stop_reason_len];
    }

    pub fn gatewaySchemaDiagnostic(self: *const NetworkCall) []const u8 {
        return self.gateway_schema_diagnostic_buf[0..self.gateway_schema_diagnostic_len];
    }

    pub fn gatewayRequestShape(self: *const NetworkCall) []const u8 {
        return self.gateway_request_shape_buf[0..self.gateway_request_shape_len];
    }

    pub fn setModel(self: *NetworkCall, name: []const u8) void {
        const n = @min(name.len, max_model_len);
        @memcpy(self.model_buf[0..n], name[0..n]);
        self.model_len = @intCast(n);
    }

    pub fn setError(self: *NetworkCall, name: []const u8) void {
        const n = @min(name.len, max_error_len);
        @memcpy(self.error_buf[0..n], name[0..n]);
        self.error_len = @intCast(n);
    }

    pub fn setTerminalStopReason(self: *NetworkCall, reason: []const u8) void {
        const n = @min(reason.len, max_stop_reason_len);
        @memcpy(self.stop_reason_buf[0..n], reason[0..n]);
        self.stop_reason_len = @intCast(n);
    }

    pub fn setGatewaySchemaDiagnostic(self: *NetworkCall, diagnostic: []const u8) void {
        const n = @min(diagnostic.len, max_gateway_schema_diagnostic_len);
        @memcpy(self.gateway_schema_diagnostic_buf[0..n], diagnostic[0..n]);
        self.gateway_schema_diagnostic_len = @intCast(n);
    }

    pub fn setGatewayRequestShape(self: *NetworkCall, shape: []const u8) void {
        const n = @min(shape.len, max_gateway_request_shape_len);
        @memcpy(self.gateway_request_shape_buf[0..n], shape[0..n]);
        self.gateway_request_shape_len = @intCast(n);
    }
};

var mutex: std.Io.Mutex = .init;
var ring: [ring_capacity]NetworkCall = [_]NetworkCall{.{}} ** ring_capacity;
var head: usize = 0;
var stored: usize = 0;

pub fn record(call: NetworkCall) void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    ring[head] = call;
    head = (head + 1) % ring_capacity;
    if (stored < ring_capacity) stored += 1;
}

pub fn snapshot(out: []NetworkCall) usize {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    const n = @min(stored, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = (head + ring_capacity - n + i) % ring_capacity;
        out[i] = ring[idx];
    }
    return n;
}

pub fn reset() void {
    const zio = io_mod.getIo();
    mutex.lockUncancelable(zio);
    defer mutex.unlock(zio);
    head = 0;
    stored = 0;
}

pub fn resetForTest() void {
    reset();
}



