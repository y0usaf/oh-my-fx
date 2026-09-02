const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const host_target = @import("../core/hosts/target.zig");

const Allocator = std.mem.Allocator;

pub fn writeJsonStr(s: []const u8, w: *std.Io.Writer) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub const ErrorCode = struct {
    pub const request_frame_too_large: i64 = -32000;
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
};

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    null,
};

pub const Message = struct {
    id: ?RequestId = null,
    method: []const u8 = "",
    params_raw: ?[]const u8 = null,
    result_raw: ?[]const u8 = null,
    error_raw: ?[]const u8 = null,

    pub fn isResponse(self: Message) bool {
        return self.method.len == 0 and self.id != null and
            (self.result_raw != null or self.error_raw != null);
    }
};

pub const RpcError = struct {
    code: i64,
    message: []const u8,
};

pub fn parseMessage(alloc: Allocator, line: []const u8) !Message {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch
        return error.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidRequest;

    var msg = Message{};
    errdefer freeMessage(alloc, &msg);

    if (root.object.get("id")) |id_val| {
        switch (id_val) {
            .integer => |n| msg.id = .{ .integer = n },
            .string => |s| msg.id = .{ .string = try alloc.dupe(u8, s) },
            .null => msg.id = .null,
            else => return error.InvalidRequest,
        }
    }

    if (root.object.get("method")) |method_val| {
        switch (method_val) {
            .string => |s| msg.method = try alloc.dupe(u8, s),
            else => return error.InvalidRequest,
        }
    }

    if (root.object.get("params")) |params_val| {
        msg.params_raw = try stringifyValueAlloc(alloc, params_val);
    }

    if (root.object.get("result")) |result_val| {
        msg.result_raw = try stringifyValueAlloc(alloc, result_val);
    }
    if (root.object.get("error")) |error_val| {
        msg.error_raw = try stringifyValueAlloc(alloc, error_val);
    }
    if (msg.result_raw != null and msg.error_raw != null) return error.InvalidRequest;
    if (msg.method.len > 0 and (msg.result_raw != null or msg.error_raw != null)) return error.InvalidRequest;
    if (msg.method.len == 0 and !msg.isResponse()) return error.InvalidRequest;

    return msg;
}

fn stringifyValueAlloc(alloc: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

pub fn freeMessage(alloc: Allocator, msg: *Message) void {
    if (msg.method.len > 0) alloc.free(msg.method);
    if (msg.params_raw) |p| alloc.free(p);
    if (msg.result_raw) |p| alloc.free(p);
    if (msg.error_raw) |p| alloc.free(p);
    if (msg.id) |id| {
        switch (id) {
            .string => |s| alloc.free(s),
            else => {},
        }
    }
    msg.* = .{};
}

pub const Writer = struct {
    pub const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;

    const Callback = struct {
        context: ?*anyopaque,
        write_fn: WriteFn,
    };

    mutex: std.Io.Mutex = .init,
    stdout: std.Io.File,
    callback: ?Callback = null,

    const Frame = union(enum) {
        response: struct {
            id: ?RequestId,
            result_json: []const u8,
        },
        error_response: struct {
            id: ?RequestId,
            err: RpcError,
        },
        notification: struct {
            method: []const u8,
            params_json: []const u8,
        },
        request: struct {
            id: RequestId,
            method: []const u8,
            params_json: []const u8,
        },

        fn write(self: Frame, w: *std.Io.Writer) !void {
            switch (self) {
                .response => |response| {
                    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                    try writeId(w, response.id);
                    try w.writeAll(",\"result\":");
                    try w.writeAll(response.result_json);
                    try w.writeAll("}\n");
                },
                .error_response => |response| {
                    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                    try writeId(w, response.id);
                    try w.writeAll(",\"error\":{\"code\":");
                    try w.print("{d}", .{response.err.code});
                    try w.writeAll(",\"message\":");
                    try writeJsonStr(response.err.message, w);
                    try w.writeAll("}}\n");
                },
                .notification => |notification| {
                    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
                    try writeJsonStr(notification.method, w);
                    try w.writeAll(",\"params\":");
                    try w.writeAll(notification.params_json);
                    try w.writeAll("}\n");
                },
                .request => |request| {
                    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
                    try writeId(w, request.id);
                    try w.writeAll(",\"method\":");
                    try writeJsonStr(request.method, w);
                    try w.writeAll(",\"params\":");
                    try w.writeAll(request.params_json);
                    try w.writeAll("}\n");
                },
            }
        }
    };

    pub fn init() Writer {
        return .{ .stdout = std.Io.File.stdout() };
    }

    pub fn initCallback(context: ?*anyopaque, write_fn: WriteFn) Writer {
        return .{
            .stdout = std.Io.File.stdout(),
            .callback = .{
                .context = context,
                .write_fn = write_fn,
            },
        };
    }

    pub fn writeResponse(self: *Writer, alloc: Allocator, id: ?RequestId, result_json: []const u8) !void {
        try self.writeFrame(alloc, .{ .response = .{
            .id = id,
            .result_json = result_json,
        } });
    }

    pub fn writeError(self: *Writer, alloc: Allocator, id: ?RequestId, err: RpcError) !void {
        try self.writeFrame(alloc, .{ .error_response = .{
            .id = id,
            .err = err,
        } });
    }

    pub fn writeNotification(self: *Writer, alloc: Allocator, method: []const u8, params_json: []const u8) !void {
        try self.writeFrame(alloc, .{ .notification = .{
            .method = method,
            .params_json = params_json,
        } });
    }

    pub fn writeRequest(self: *Writer, alloc: Allocator, id: RequestId, method: []const u8, params_json: []const u8) !void {
        try self.writeFrame(alloc, .{ .request = .{
            .id = id,
            .method = method,
            .params_json = params_json,
        } });
    }

    fn writeFrame(self: *Writer, alloc: Allocator, frame: Frame) !void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try frame.write(&out.writer);

        const slice = try out.toOwnedSlice();
        defer alloc.free(slice);

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.callback) |callback| {
            try callback.write_fn(callback.context, slice);
        } else {
            try self.stdout.writeStreamingAll(io, slice);
        }
    }

    fn writeId(w: *std.Io.Writer, id: ?RequestId) !void {
        if (id) |rid| {
            switch (rid) {
                .integer => |n| try w.print("{d}", .{n}),
                .string => |s| try writeJsonStr(s, w),
                .null => try w.writeAll("null"),
            }
        } else {
            try w.writeAll("null");
        }
    }
};

pub const Reader = struct {
    pub const ReadFn = *const fn (?*anyopaque, []u8) usize;

    pub const frame_resource_byte_limit: usize = 8 * 1024 * 1024;
    pub const LineRead = union(enum) {
        line: []u8,
        overflow,
    };

    read_context: ?*anyopaque = null,
    read_fn: ReadFn,
    buf: [64 * 1024]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,

    pub fn init() Reader {
        return .{ .read_fn = readStdin };
    }

    pub fn initCallback(context: ?*anyopaque, read_fn: ReadFn) Reader {
        return .{
            .read_context = context,
            .read_fn = read_fn,
        };
    }

    fn initForTesting(context: *anyopaque, read_fn: ReadFn) Reader {
        return initCallback(context, read_fn);
    }

    // Native ACP uses raw read(2) because Linux may pass socket-based stdin to
    // child processes. WASI has no std.posix surface, so use the injected std.Io
    // backend and let the host's fd_read import suspend through JSPI.
    fn readStdin(_: ?*anyopaque, destination: []u8) usize {
        if (comptime host_target.is_wasm) {
            return std.Io.File.stdin().readStreaming(
                io_mod.getIo(),
                &.{destination},
            ) catch return 0;
        }
        return std.posix.read(std.posix.STDIN_FILENO, destination) catch return 0;
    }

    fn readFromSource(self: *Reader) usize {
        return self.read_fn(self.read_context, &self.buf);
    }

    pub fn readLine(self: *Reader, alloc: Allocator) !?LineRead {
        return self.readLineWithLimit(alloc, frame_resource_byte_limit);
    }

    fn readLineWithLimit(
        self: *Reader,
        alloc: Allocator,
        resource_byte_limit: usize,
    ) !?LineRead {
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(alloc);
        var overflow = false;

        while (true) {
            if (self.findNewline()) |nl_pos| {
                if (!overflow and !try appendFrameChunk(
                    alloc,
                    &line_buf,
                    self.buf[self.pos .. self.pos + nl_pos],
                    resource_byte_limit,
                )) {
                    overflow = true;
                    line_buf.clearAndFree(alloc);
                }
                self.pos += nl_pos + 1;
                if (overflow) return .overflow;
                if (line_buf.items.len == 0) continue;
                return .{ .line = try line_buf.toOwnedSlice(alloc) };
            }

            if (!overflow and self.pos < self.len and !try appendFrameChunk(
                alloc,
                &line_buf,
                self.buf[self.pos..self.len],
                resource_byte_limit,
            )) {
                overflow = true;
                line_buf.clearAndFree(alloc);
            }
            self.pos = 0;
            self.len = self.readFromSource();
            if (self.len == 0) return if (overflow) .overflow else null;
        }
    }

    fn appendFrameChunk(
        alloc: Allocator,
        line_buf: *std.ArrayList(u8),
        chunk: []const u8,
        resource_byte_limit: usize,
    ) !bool {
        const next_len = std.math.add(usize, line_buf.items.len, chunk.len) catch
            return false;
        if (next_len > resource_byte_limit) return false;
        try line_buf.appendSlice(alloc, chunk);
        return true;
    }

    fn findNewline(self: *Reader) ?usize {
        for (self.buf[self.pos..self.len], 0..) |c, i| {
            if (c == '\n') return i;
        }
        return null;
    }
};

const ChunkedTestSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    max_chunk: usize,

    fn read(raw: ?*anyopaque, destination: []u8) usize {
        const self: *ChunkedTestSource = @ptrCast(@alignCast(raw.?));
        if (self.offset == self.bytes.len) return 0;
        const remaining = self.bytes.len - self.offset;
        const count = @min(@min(remaining, destination.len), self.max_chunk);
        @memcpy(destination[0..count], self.bytes[self.offset .. self.offset + count]);
        self.offset += count;
        return count;
    }
};
