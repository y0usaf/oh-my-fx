const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const session_catalog = @import("../session/session_catalog.zig");
const session_store = @import("../session/session_store.zig");
const session_bridge = @import("session_bridge.zig");
const terminal_engine = @import("../terminal/engine.zig");
const terminal_contracts = @import("../terminal/contracts.zig");
const ui_terminal = @import("../../ui/terminal/terminal.zig");
const model_mod = @import("model.zig");

const Allocator = std.mem.Allocator;
const sidebar_width: u16 = 26;
const min_terminal_width: u16 = 40;
const poll_ms: i32 = 16;
const max_sessions: usize = 64;
const max_scrollback_rows: usize = 10_000;
const wheel_scroll_rows: usize = 3;
const archive_dir_name = "archive";

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn fork() std.posix.pid_t;
extern "c" fn setsid() std.posix.pid_t;
extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn write(fd: c_int, bytes: [*]const u8, len: usize) isize;

const ioctl_set_controlling_terminal: c_int = switch (builtin.os.tag) {
    .macos => 0x20007461,
    .linux => @intCast(std.os.linux.T.IOCSCTTY),
    else => 0,
};
const ioctl_set_window_size: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
    .linux => @intCast(std.os.linux.T.IOCSWINSZ),
    else => 0,
};

const Child = struct {
    master_fd: std.posix.fd_t,
    pid: std.posix.pid_t,
    grid: terminal_engine.Grid,
    direct_endpoint_path: []u8,
    direct_render: bool = false,
    scrollback: std.ArrayList([]u8) = .empty,
    scroll_offset: usize = 0,
    exited: bool = false,

    fn deinit(self: *Child, alloc: Allocator) void {
        if (!self.exited) {
            std.posix.kill(self.pid, .TERM) catch {};
            _ = waitForChild(self.pid, 1000);
        }
        if (self.master_fd >= 0) closeFd(self.master_fd);
        if (self.direct_endpoint_path.len > 0) {
            std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), self.direct_endpoint_path) catch {};
        }
        for (self.scrollback.items) |line| alloc.free(line);
        self.scrollback.deinit(alloc);
        if (self.direct_endpoint_path.len > 0) alloc.free(self.direct_endpoint_path);
        self.grid.deinit();
    }

    fn resize(self: *Child, cols: u16, rows: u16) !void {
        try self.grid.resize(cols, rows);
        self.scroll_offset = @min(self.scroll_offset, self.scrollback.items.len);
        var size = std.posix.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (std.c.ioctl(self.master_fd, ioctl_set_window_size, &size) == -1) return error.PtyResizeFailed;
    }

    fn feed(self: *Child, alloc: Allocator, bytes: []const u8) !void {
        for (bytes) |byte| {
            var top_line: std.ArrayList(u8) = .empty;
            defer top_line.deinit(alloc);
            try self.grid.rowText(1, &top_line);

            const full_screen_region = self.grid.scroll_top == 1 and self.grid.scroll_bottom == self.grid.rows;
            var result = try self.grid.feedMode(&.{byte}, .native_live);
            defer result.deinit(alloc);
            for (result.replies.items) |reply| _ = writeFd(self.master_fd, reply.bytes) catch 0;

            if (full_screen_region and result.stats.scroll_rows != 0) {
                const line = std.mem.trimEnd(u8, top_line.items, " ");
                try self.scrollback.append(alloc, try alloc.dupe(u8, line));
                var removed_count: usize = 0;
                while (self.scrollback.items.len > max_scrollback_rows) {
                    const removed = self.scrollback.orderedRemove(0);
                    alloc.free(removed);
                    removed_count += 1;
                }
                if (self.scroll_offset != 0) {
                    self.scroll_offset = @min(
                        self.scroll_offset + 1 -| removed_count,
                        self.scrollback.items.len,
                    );
                }
            }
        }
    }

    fn scroll(self: *Child, delta: isize) void {
        if (delta > 0) {
            self.scroll_offset = @min(self.scroll_offset + @as(usize, @intCast(delta)), self.scrollback.items.len);
        } else if (delta < 0) {
            self.scroll_offset -|= @as(usize, @intCast(-delta));
        }
    }
};

const Entry = struct {
    id: ?[]u8,
    title: []u8,
    child: ?Child = null,
    attached: ?Attached = null,

    fn deinit(self: *Entry, alloc: Allocator) void {
        if (self.child) |*child| child.deinit(alloc);
        if (self.attached) |*attached| attached.deinit(alloc);
        if (self.id) |id| alloc.free(id);
        alloc.free(self.title);
        self.* = undefined;
    }
};

const Attached = struct {
    endpoint_path: []u8,
    grid: terminal_engine.Grid,

    fn deinit(self: *Attached, alloc: Allocator) void {
        alloc.free(self.endpoint_path);
        self.grid.deinit();
        self.* = undefined;
    }
};

const TerminalGuard = struct {
    original: std.posix.termios,

    fn enter() !TerminalGuard {
        if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or std.c.isatty(std.posix.STDOUT_FILENO) == 0) return error.NotATerminal;
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.iflag.IXOFF = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        const vmin: usize = if (builtin.os.tag == .linux) 6 else 16;
        const vtime: usize = if (builtin.os.tag == .linux) 5 else 17;
        if (vmin < raw.cc.len and vtime < raw.cc.len) {
            raw.cc[vmin] = 1;
            raw.cc[vtime] = 0;
        }
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        try writeStdout("\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?25l\x1b[2J\x1b[H");
        return .{ .original = original };
    }

    fn leave(self: TerminalGuard) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
        writeStdout("\x1b[0m\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l") catch {};
    }
};

pub fn run(resume_id: ?[]const u8) !u8 {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.MuxUnsupported;
    const alloc = if (comptime builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;
    const workspace = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace);
    const executable = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(executable);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    var store = try session_store.Store.initReadOnly(alloc, workspace);
    defer store.deinit(alloc);
    var summaries = try store.listForWorkspace(alloc);
    defer {
        for (summaries.items) |*summary| summary.deinit(alloc);
        summaries.deinit(alloc);
    }
    for (summaries.items[0..@min(summaries.items.len, max_sessions)]) |summary| {
        try entries.append(alloc, .{
            .id = try alloc.dupe(u8, summary.id),
            .title = try alloc.dupe(u8, session_catalog.displayTitle(summary)),
        });
    }
    if (resume_id) |wanted| {
        for (entries.items, 0..) |entry, index| {
            if (entry.id != null and std.mem.eql(u8, entry.id.?, wanted)) {
                if (index != 0) std.mem.swap(Entry, &entries.items[0], &entries.items[index]);
                break;
            }
        }
    }
    if (entries.items.len == 0) try appendDraft(alloc, &entries);

    var state = model_mod.Model{ .session_count = entries.items.len };
    const guard = try TerminalGuard.enter();
    defer guard.leave();

    var input_escape: [64]u8 = undefined;
    var input_escape_len: usize = 0;
    var last_rows: u16 = 0;
    var last_cols: u16 = 0;
    var last_frame: std.ArrayList(u8) = .empty;
    defer last_frame.deinit(alloc);
    // Paint chrome before any bridge I/O so a stalled peer cannot blank the UI.
    {
        const layout = try ui_terminal.queryLayout(std.posix.STDIN_FILENO, 0);
        try renderIfChanged(alloc, entries.items, state, layout.cols, layout.rows, &last_frame);
    }

    while (true) {
        const layout = try ui_terminal.queryLayout(std.posix.STDIN_FILENO, 0);
        const terminal_cols = @max(min_terminal_width, layout.cols -| sidebar_width);
        if (layout.rows != last_rows or layout.cols != last_cols) {
            last_rows = layout.rows;
            last_cols = layout.cols;
            for (entries.items) |*entry| if (entry.child) |*child| try child.resize(terminal_cols, layout.rows);
        }
        if (entries.items[state.selected].child == null and
            entries.items[state.selected].attached == null)
        {
            if (entries.items[state.selected].id) |session_id| {
                const endpoint_path = try session_bridge.endpointPath(alloc, store.sessions_dir, session_id);
                if (session_bridge.requestScreen(alloc, endpoint_path)) |grid| {
                    entries.items[state.selected].attached = .{
                        .endpoint_path = endpoint_path,
                        .grid = grid,
                    };
                } else |_| {
                    alloc.free(endpoint_path);
                    entries.items[state.selected].child = try spawnFx(alloc, executable, workspace, entries.items[state.selected].id, terminal_cols, layout.rows);
                }
            } else {
                entries.items[state.selected].child = try spawnFx(alloc, executable, workspace, null, terminal_cols, layout.rows);
            }
        }
        if (entries.items[state.selected].attached) |*attached| {
            refreshAttached(alloc, attached) catch {};
        }
        if (entries.items[state.selected].child) |*child| {
            refreshDirectChild(alloc, child) catch {};
        }

        var poll_fds: [max_sessions + 1]std.posix.pollfd = undefined;
        var owners: [max_sessions]?usize = @splat(null);
        var poll_len: usize = 1;
        poll_fds[0] = .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 };
        for (entries.items, 0..) |entry, index| {
            if (entry.child) |child| {
                poll_fds[poll_len] = .{ .fd = child.master_fd, .events = std.posix.POLL.IN, .revents = 0 };
                owners[poll_len - 1] = index;
                poll_len += 1;
            }
        }
        _ = try std.posix.poll(poll_fds[0..poll_len], poll_ms);

        var i: usize = 1;
        while (i < poll_len) : (i += 1) {
            if ((poll_fds[i].revents & std.posix.POLL.IN) == 0) continue;
            const index = owners[i - 1].?;
            var buf: [8192]u8 = undefined;
            while (true) {
                const count = std.posix.read(poll_fds[i].fd, &buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => break,
                };
                if (count == 0) break;
                const child = &entries.items[index].child.?;
                if (!child.direct_render) try child.feed(alloc, buf[0..count]);
                if (count < buf.len) break;
            }
        }

        if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
            var buf: [128]u8 = undefined;
            const count = try std.posix.read(std.posix.STDIN_FILENO, &buf);
            for (buf[0..count]) |byte| {
                if (input_escape_len != 0 or byte == 0x1b) {
                    if (input_escape_len < input_escape.len) {
                        input_escape[input_escape_len] = byte;
                        input_escape_len += 1;
                    }
                    if (isCtrlDelete(input_escape[0..input_escape_len])) {
                        try archiveSelected(alloc, &entries, &state, store.sessions_dir, store.home_dir);
                        input_escape_len = 0;
                    } else if (escapeSequenceComplete(input_escape[0..input_escape_len])) {
                        const sequence = input_escape[0..input_escape_len];
                        if (scrollDeltaForEscape(sequence, layout.rows)) |delta| {
                            if (entries.items[state.selected].child) |*child| {
                                if (child.direct_render) {
                                    try forwardSelected(entries.items, state.selected, sequence);
                                } else {
                                    child.scroll(delta);
                                }
                            }
                        } else {
                            if (entries.items[state.selected].child) |*child| child.scroll_offset = 0;
                            try forwardSelected(entries.items, state.selected, sequence);
                        }
                        input_escape_len = 0;
                    }
                    continue;
                }
                const action = model_mod.actionForByte(byte);
                switch (action) {
                    .quit => return 0,
                    .new_session => {
                        try appendDraft(alloc, &entries);
                        state.reconcile(entries.items.len);
                        state.selected = entries.items.len - 1;
                    },
                    .none => if (state.focus == .terminal) {
                        if (entries.items[state.selected].child) |*child| child.scroll_offset = 0;
                        try forwardSelected(entries.items, state.selected, &.{byte});
                    },
                    else => state.apply(action),
                }
            }
        }
        try renderIfChanged(alloc, entries.items, state, layout.cols, layout.rows, &last_frame);
    }
}

fn appendDraft(alloc: Allocator, entries: *std.ArrayList(Entry)) !void {
    try entries.append(alloc, .{ .id = null, .title = try alloc.dupe(u8, "New session") });
}

fn spawnFx(alloc: Allocator, executable: []const u8, workspace: []const u8, session_id: ?[]const u8, cols: u16, rows: u16) !Child {
    const endpoint_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/fx-mux-{d}-{d}.sock",
        .{ std.c.getpid(), io_mod.nanoTimestamp() },
    );
    errdefer alloc.free(endpoint_path);
    const endpoint_z = try alloc.dupeZ(u8, endpoint_path);
    defer alloc.free(endpoint_z);
    const flags = std.posix.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true };
    const master_fd = posix_openpt(@bitCast(flags));
    if (master_fd < 0) return error.PtyUnavailable;
    errdefer closeFd(master_fd);
    if (grantpt(master_fd) != 0 or unlockpt(master_fd) != 0) return error.PtyUnavailable;
    const slave_name = ptsname(master_fd) orelse return error.PtyUnavailable;
    const slave_path = try alloc.dupeZ(u8, std.mem.span(slave_name));
    defer alloc.free(slave_path);
    const exe_z = try alloc.dupeZ(u8, executable);
    defer alloc.free(exe_z);
    const workspace_z = try alloc.dupeZ(u8, workspace);
    defer alloc.free(workspace_z);
    const id_z = if (session_id) |id| try alloc.dupeZ(u8, id) else null;
    defer if (id_z) |id| alloc.free(id);

    const pid = fork();
    if (pid < 0) return error.PtySpawnFailed;
    if (pid == 0) {
        _ = setsid();
        const slave_flags = std.posix.O{ .ACCMODE = .RDWR, .NOCTTY = false };
        const slave_fd = std.posix.openatZ(std.posix.AT.FDCWD, slave_path, slave_flags, 0) catch std.c._exit(126);
        _ = std.c.ioctl(slave_fd, ioctl_set_controlling_terminal, @as(c_int, 0));
        _ = dup2(slave_fd, std.posix.STDIN_FILENO);
        _ = dup2(slave_fd, std.posix.STDOUT_FILENO);
        _ = dup2(slave_fd, std.posix.STDERR_FILENO);
        if (slave_fd > std.posix.STDERR_FILENO) closeFd(slave_fd);
        closeFd(master_fd);
        _ = chdir(workspace_z.ptr);
        _ = setenv("FX_AUTO_UPGRADE", "0", 1);
        _ = setenv(session_bridge.direct_endpoint_env, endpoint_z.ptr, 1);
        var argv: [3:null]?[*:0]const u8 = .{ exe_z.ptr, null, null };
        if (id_z) |id| {
            argv[1] = "resume";
            argv[2] = id.ptr;
        }
        _ = execv(exe_z.ptr, &argv);
        std.c._exit(127);
    }
    var grid = try terminal_engine.Grid.init(alloc, cols, rows);
    errdefer grid.deinit();
    var child = Child{
        .master_fd = master_fd,
        .pid = pid,
        .grid = grid,
        .direct_endpoint_path = endpoint_path,
    };
    try child.resize(cols, rows);
    return child;
}

fn forwardSelected(entries: []Entry, selected: usize, bytes: []const u8) !void {
    if (entries[selected].child) |child| {
        if (child.direct_render) {
            session_bridge.sendInput(child.direct_endpoint_path, bytes) catch {};
        } else {
            var offset: usize = 0;
            while (offset < bytes.len) offset += try writeFd(child.master_fd, bytes[offset..]);
        }
    } else if (entries[selected].attached) |attached| {
        session_bridge.sendInput(attached.endpoint_path, bytes) catch {};
    }
}

fn refreshAttached(alloc: Allocator, attached: *Attached) !void {
    const next = try session_bridge.requestScreen(alloc, attached.endpoint_path);
    attached.grid.deinit();
    attached.grid = next;
}

fn refreshDirectChild(alloc: Allocator, child: *Child) !void {
    const next = try session_bridge.requestScreen(alloc, child.direct_endpoint_path);
    child.grid.deinit();
    child.grid = next;
    child.direct_render = true;
}

fn renderIfChanged(
    alloc: Allocator,
    entries: []const Entry,
    state: model_mod.Model,
    cols: u16,
    rows: u16,
    last_frame: *std.ArrayList(u8),
) !void {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(alloc);
    try buildFrame(alloc, entries, state, cols, rows, &frame);
    // Keep the hardware cursor hidden for the complete repaint. Otherwise each
    // row movement is visible before the final cursor position is restored.
    const wire = try frameWireBytesChanged(alloc, frame.items, last_frame) orelse return;
    defer alloc.free(wire);
    try writeStdout(wire);
}

fn buildFrame(
    alloc: Allocator,
    entries: []const Entry,
    state: model_mod.Model,
    cols: u16,
    rows: u16,
    out: *std.ArrayList(u8),
) !void {
    try out.appendSlice(alloc, "\x1b[H\x1b[0m");
    var row: u16 = 1;
    while (row <= rows) : (row += 1) {
        if (row == 1) {
            try appendPadded(alloc, out, "fx", sidebar_width);
        } else if (row - 2 < entries.len) {
            const index: usize = row - 2;
            const marker = if (index == state.selected) "> " else "  ";
            if (index == state.selected and state.focus == .sidebar) try out.appendSlice(alloc, "\x1b[7m");
            try out.appendSlice(alloc, marker);
            try appendPadded(alloc, out, entries[index].title, sidebar_width - 2);
            try out.appendSlice(alloc, "\x1b[0m");
        } else if (row == rows) {
            try appendPadded(alloc, out, "^N new  ^J/K switch  ^G/L focus  ^Q quit", sidebar_width);
        } else {
            try appendPadded(alloc, out, "", sidebar_width);
        }
        try out.appendSlice(alloc, "\x1b[2m│\x1b[0m");
        if (entries[state.selected].child) |child| {
            const history_len = child.scrollback.items.len;
            const viewport_start = history_len -| child.scroll_offset;
            const virtual_row = viewport_start + row - 1;
            if (virtual_row < history_len) {
                const line = child.scrollback.items[virtual_row];
                try out.appendSlice(alloc, line[0..@min(line.len, cols -| sidebar_width -| 1)]);
            } else {
                var line: std.ArrayList(u8) = .empty;
                defer line.deinit(alloc);
                const grid_row: u16 = @intCast(virtual_row - history_len + 1);
                try child.grid.rowText(grid_row, &line);
                try out.appendSlice(alloc, line.items[0..@min(line.items.len, cols -| sidebar_width -| 1)]);
            }
        } else if (entries[state.selected].attached) |attached| {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(alloc);
            try attached.grid.rowText(row, &line);
            try out.appendSlice(alloc, line.items[0..@min(line.items.len, cols -| sidebar_width -| 1)]);
        }
        try out.appendSlice(alloc, "\x1b[K");
        if (row != rows) try out.appendSlice(alloc, "\r\n");
    }
    try appendCursor(alloc, out, entries[state.selected], state, cols, rows);
}

fn appendCursor(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    entry: Entry,
    state: model_mod.Model,
    cols: u16,
    rows: u16,
) !void {
    const grid: ?terminal_engine.Grid = if (entry.child) |child|
        child.grid
    else if (entry.attached) |attached|
        attached.grid
    else
        null;
    if (state.focus != .terminal or grid == null or !grid.?.cursor_visible) {
        try out.appendSlice(alloc, "\x1b[?25l");
        return;
    }
    const cursor_row = @min(rows, @max(@as(u16, 1), grid.?.cursor_row));
    const terminal_width = cols -| sidebar_width -| 1;
    const cursor_col = sidebar_width + 1 + @min(terminal_width, @max(@as(u16, 1), grid.?.cursor_col));
    const sequence = try std.fmt.allocPrint(alloc, "\x1b[{d};{d}H\x1b[{d} q\x1b[?25h", .{
        cursor_row,
        cursor_col,
        cursorShapeCode(grid.?.cursor_shape, grid.?.cursor_blinking),
    });
    defer alloc.free(sequence);
    try out.appendSlice(alloc, sequence);
}

fn frameWireBytesChanged(
    alloc: Allocator,
    frame: []const u8,
    last_frame: *std.ArrayList(u8),
) !?[]u8 {
    if (std.mem.eql(u8, frame, last_frame.items)) return null;
    const wire = try std.mem.concat(alloc, u8, &.{ "\x1b[?2026h\x1b[?25l", frame, "\x1b[?2026l" });
    last_frame.clearRetainingCapacity();
    try last_frame.appendSlice(alloc, frame);
    return wire;
}

fn cursorShapeCode(shape: terminal_contracts.CursorShape, blinking: bool) u8 {
    return switch (shape) {
        .block => if (blinking) 1 else 2,
        .underline => if (blinking) 3 else 4,
        .bar => if (blinking) 5 else 6,
    };
}

fn appendPadded(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8, width: u16) !void {
    const slice = text[0..@min(text.len, width)];
    try out.appendSlice(alloc, slice);
    try out.appendNTimes(alloc, ' ', width - slice.len);
}

fn archiveSelected(alloc: Allocator, entries: *std.ArrayList(Entry), state: *model_mod.Model, sessions_dir: []const u8, home_dir: []const u8) !void {
    if (entries.items.len == 0) return;
    const entry = &entries.items[state.selected];
    const id = entry.id orelse return;
    if (entry.attached != null) return;
    if (entry.child) |*child| {
        std.posix.kill(child.pid, .TERM) catch {};
        _ = waitForChild(child.pid, 2000);
        child.exited = true;
    }
    const source = try session_store.sessionDirPath(alloc, sessions_dir, id);
    defer alloc.free(source);
    const archive_root = try std.fs.path.join(alloc, &.{ home_dir, ".fx", archive_dir_name });
    defer alloc.free(archive_root);
    std.Io.Dir.createDirAbsolute(io_mod.getIo(), archive_root, std.Io.File.Permissions.fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const destination = try std.fs.path.join(alloc, &.{ archive_root, id });
    defer alloc.free(destination);
    try std.Io.Dir.renameAbsolute(source, destination, io_mod.getIo());
    var removed = entries.orderedRemove(state.selected);
    removed.deinit(alloc);
    if (entries.items.len == 0) try appendDraft(alloc, entries);
    state.reconcile(entries.items.len);
}

fn waitForChild(pid: std.posix.pid_t, timeout_ms: i64) bool {
    const deadline = io_mod.milliTimestamp() + timeout_ms;
    while (io_mod.milliTimestamp() < deadline) {
        const waited = std.c.waitpid(pid, null, std.c.W.NOHANG);
        if (waited == pid) return true;
        if (waited < 0) return true;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

fn isCtrlDelete(bytes: []const u8) bool {
    return std.mem.eql(u8, bytes, "\x1b[3;5~") or std.mem.eql(u8, bytes, "\x1b[127;5u");
}

fn escapeSequenceComplete(bytes: []const u8) bool {
    if (bytes.len == 1) return false;
    if (bytes[1] == '[' or bytes[1] == 'O') {
        const last = bytes[bytes.len - 1];
        return bytes.len >= 3 and last >= '@' and last <= '~';
    }
    return bytes.len == 2;
}

fn scrollDeltaForEscape(bytes: []const u8, rows: u16) ?isize {
    if (std.mem.eql(u8, bytes, "\x1b[5~")) return @intCast(@max(rows -| 1, 1));
    if (std.mem.eql(u8, bytes, "\x1b[6~")) return -@as(isize, @intCast(@max(rows -| 1, 1)));
    if (std.mem.startsWith(u8, bytes, "\x1b[<64;") and std.mem.endsWith(u8, bytes, "M")) return wheel_scroll_rows;
    if (std.mem.startsWith(u8, bytes, "\x1b[<65;") and std.mem.endsWith(u8, bytes, "M")) return -@as(isize, wheel_scroll_rows);
    return null;
}

fn writeStdout(bytes: []const u8) !void {
    var stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io_mod.getIo(), bytes);
}

fn writeFd(fd: std.posix.fd_t, bytes: []const u8) !usize {
    const count = write(fd, bytes.ptr, bytes.len);
    if (count < 0) return error.PtyWriteFailed;
    return @intCast(count);
}

fn closeFd(fd: std.posix.fd_t) void {
    (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(io_mod.getIo());
}

/// Keeps benchmark-only setup outside the measured mux ingestion and rendering paths.
pub const BenchmarkHarness = struct {
    entries: std.ArrayList(Entry) = .empty,
    state: model_mod.Model,
    cols: u16,
    rows: u16,

    pub fn init(
        alloc: Allocator,
        session_count: usize,
        cols: u16,
        rows: u16,
    ) !BenchmarkHarness {
        if (session_count == 0 or session_count > max_sessions) return error.InvalidSessionCount;
        if (cols <= sidebar_width + 1 or rows == 0) return error.InvalidTerminalSize;

        var harness = BenchmarkHarness{
            .state = .{ .session_count = session_count },
            .cols = cols,
            .rows = rows,
        };
        errdefer harness.deinit(alloc);
        for (0..session_count) |index| {
            const title = try std.fmt.allocPrint(alloc, "Session {d}", .{index + 1});
            const grid = terminal_engine.Grid.init(alloc, cols - sidebar_width - 1, rows) catch |err| {
                alloc.free(title);
                return err;
            };
            harness.entries.append(alloc, .{
                .id = null,
                .title = title,
                .child = .{
                    .master_fd = -1,
                    .pid = 0,
                    .grid = grid,
                    .direct_endpoint_path = &.{},
                    .exited = true,
                },
            }) catch |err| {
                var owned_grid = grid;
                owned_grid.deinit();
                alloc.free(title);
                return err;
            };
        }
        return harness;
    }

    pub fn deinit(self: *BenchmarkHarness, alloc: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    pub fn feedSelected(self: *BenchmarkHarness, alloc: Allocator, bytes: []const u8) !void {
        try self.entries.items[self.state.selected].child.?.feed(alloc, bytes);
    }

    pub fn adoptSelectedGrid(self: *BenchmarkHarness, grid: terminal_engine.Grid) void {
        const child = &self.entries.items[self.state.selected].child.?;
        child.grid.deinit();
        child.grid = grid;
        child.direct_render = true;
    }

    pub fn selectNext(self: *BenchmarkHarness) void {
        self.state.apply(.next_session);
    }

    pub fn buildSelectedFrame(self: *BenchmarkHarness, alloc: Allocator, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        try buildFrame(alloc, self.entries.items, self.state, self.cols, self.rows, out);
    }
};

test "mux frame wire hides cursor during changed repaint and skips unchanged frame" {
    const alloc = std.testing.allocator;
    var last: std.ArrayList(u8) = .empty;
    defer last.deinit(alloc);

    const first = (try frameWireBytesChanged(alloc, "frame\x1b[4;9H\x1b[?25h", &last)).?;
    defer alloc.free(first);
    try std.testing.expect(std.mem.startsWith(u8, first, "\x1b[?2026h\x1b[?25l"));
    try std.testing.expect(std.mem.endsWith(u8, first, "\x1b[?2026l"));
    try std.testing.expectEqualStrings("frame\x1b[4;9H\x1b[?25h", last.items);
    try std.testing.expect((try frameWireBytesChanged(alloc, last.items, &last)) == null);
}

test "mux cursor shape codes preserve shape and blinking" {
    try std.testing.expectEqual(@as(u8, 1), cursorShapeCode(.block, true));
    try std.testing.expectEqual(@as(u8, 2), cursorShapeCode(.block, false));
    try std.testing.expectEqual(@as(u8, 3), cursorShapeCode(.underline, true));
    try std.testing.expectEqual(@as(u8, 6), cursorShapeCode(.bar, false));
}

test "mux recognizes ctrl delete encodings" {
    try std.testing.expect(isCtrlDelete("\x1b[3;5~"));
    try std.testing.expect(isCtrlDelete("\x1b[127;5u"));
    try std.testing.expect(!isCtrlDelete("\x1b[3~"));
}

test "mux escape decoder waits for complete CSI sequences" {
    try std.testing.expect(!escapeSequenceComplete("\x1b"));
    try std.testing.expect(!escapeSequenceComplete("\x1b["));
    try std.testing.expect(!escapeSequenceComplete("\x1b[3;5"));
    try std.testing.expect(escapeSequenceComplete("\x1b[3;5~"));
    try std.testing.expect(escapeSequenceComplete("\x1bx"));
}

test "mux decodes wheel and page scrolling" {
    try std.testing.expectEqual(@as(?isize, 3), scrollDeltaForEscape("\x1b[<64;80;12M", 24));
    try std.testing.expectEqual(@as(?isize, -3), scrollDeltaForEscape("\x1b[<65;80;12M", 24));
    try std.testing.expectEqual(@as(?isize, 23), scrollDeltaForEscape("\x1b[5~", 24));
    try std.testing.expectEqual(@as(?isize, -23), scrollDeltaForEscape("\x1b[6~", 24));
    try std.testing.expectEqual(@as(?isize, null), scrollDeltaForEscape("\x1b[A", 24));
}

test "mux child retains rows scrolled out of the full screen" {
    var child = Child{
        .master_fd = -1,
        .pid = 0,
        .grid = try terminal_engine.Grid.init(std.testing.allocator, 8, 2),
        .direct_endpoint_path = &.{},
        .exited = true,
    };
    defer {
        child.master_fd = -1;
        for (child.scrollback.items) |line| std.testing.allocator.free(line);
        child.scrollback.deinit(std.testing.allocator);
        child.grid.deinit();
    }

    try child.feed(std.testing.allocator, "one\r\ntwo\r\nthree");
    try std.testing.expectEqual(@as(usize, 1), child.scrollback.items.len);
    try std.testing.expectEqualStrings("one", child.scrollback.items[0]);

    child.scroll(1);
    try std.testing.expectEqual(@as(usize, 1), child.scroll_offset);
    try child.feed(std.testing.allocator, "\r\nfour");
    try std.testing.expectEqual(@as(usize, 2), child.scrollback.items.len);
    try std.testing.expectEqual(@as(usize, 2), child.scroll_offset);
    try std.testing.expectEqualStrings("two", child.scrollback.items[1]);
}
