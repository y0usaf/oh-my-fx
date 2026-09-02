const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const session_child_store = @import("../session/session_child_store.zig");

pub const BackgroundLaunchPolicy = enum {
    process_local_long_lived,
    durable_long_lived,
    saved_headless,
};

pub const StableBackgroundRecordId = types.StableBackgroundRecordId;

pub const ProcessInstanceToken = struct {
    bytes: [128]u8 = undefined,
    len: u8 = 0,

    pub fn parse(text: []const u8) !ProcessInstanceToken {
        if (text.len == 0 or text.len > 128) {
            return error.InvalidProcessInstanceToken;
        }
        for (text) |byte| {
            if (!std.ascii.isAscii(byte) or std.ascii.isUpper(byte) or
                std.ascii.isWhitespace(byte) or
                std.ascii.isControl(byte))
            {
                return error.InvalidProcessInstanceToken;
            }
        }
        var parts = std.mem.splitScalar(u8, text, ':');
        const platform = parts.next() orelse
            return error.InvalidProcessInstanceToken;
        const boot_id = parts.next() orelse
            return error.InvalidProcessInstanceToken;
        if (!isLowerHex(boot_id, 32)) {
            return error.InvalidProcessInstanceToken;
        }
        if (std.mem.eql(u8, platform, "linux")) {
            const start_ticks = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            if (parts.next() != null or
                !isCanonicalDecimal(start_ticks))
            {
                return error.InvalidProcessInstanceToken;
            }
        } else if (std.mem.eql(u8, platform, "macos")) {
            const start_sec = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            const start_usec = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            if (parts.next() != null or
                !isCanonicalDecimal(start_sec) or
                !isCanonicalDecimal(start_usec))
            {
                return error.InvalidProcessInstanceToken;
            }
        } else {
            return error.InvalidProcessInstanceToken;
        }
        var token = ProcessInstanceToken{};
        @memcpy(token.bytes[0..text.len], text);
        token.len = @intCast(text.len);
        return token;
    }

    pub fn view(self: *const ProcessInstanceToken) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: ProcessInstanceToken, other: ProcessInstanceToken) bool {
        return std.mem.eql(u8, self.view(), other.view());
    }
};

fn isLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and
            (byte < 'a' or byte > 'f'))
        {
            return false;
        }
    }
    return true;
}

fn isCanonicalDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > 1 and value[0] == '0') return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    _ = std.fmt.parseInt(u64, value, 10) catch return false;
    return true;
}

pub const TokenMatch = enum {
    matched,
    missing,
    mismatched,
    unavailable,
};

pub var process_token_match_for_test: ?*const fn ([]const u8, ProcessInstanceToken) TokenMatch = null;
pub var process_token_capture_for_test: ?*const fn (
    std.mem.Allocator,
    []const u8,
) anyerror!ProcessInstanceToken = null;

pub const RecordAuthority = union(enum) {
    none,
    read_only: *session_child_store.SessionChildCapability,
    writable: *session_child_store.SessionChildCapability,
};

pub fn captureProcessInstanceToken(
    alloc: std.mem.Allocator,
    pid_text: []const u8,
) !ProcessInstanceToken {
    if (process_token_capture_for_test) |callback| {
        return callback(alloc, pid_text);
    }
    return error.ProcessIdentityUnsupported;
}

pub fn matchProcessInstanceToken(
    alloc: std.mem.Allocator,
    pid_text: []const u8,
    expected: ProcessInstanceToken,
) TokenMatch {
    if (process_token_match_for_test) |callback| {
        return callback(pid_text, expected);
    }
    const actual = captureProcessInstanceToken(alloc, pid_text) catch |err| {
        return switch (err) {
            error.ProcessNotFound => .missing,
            else => .unavailable,
        };
    };
    return if (actual.eql(expected)) .matched else .mismatched;
}

pub const BackgroundRegistration = struct {
    display_id: ?u64 = null,
    pid: []const u8,
    process_token: ?ProcessInstanceToken = null,
    policy: BackgroundLaunchPolicy = .process_local_long_lived,
    source_session_id: ?[]const u8 = null,
    background_record_id: ?StableBackgroundRecordId = null,
    durable_record_id: ?u64 = null,
    record_authority: RecordAuthority = .none,
    managed_log_name: ?[]const u8 = null,
    command: []const u8,
    cwd: []const u8,
    log_path: []const u8,
    expect_url: bool,
    url: ?[]const u8 = null,
};

pub const TaskState = enum {
    running,
    exited,
    failed,
    stopped,
    dead,
    stale,
};

pub const RecordPersistenceState = enum {
    not_applicable,
    confirmed,
    initial_record_degraded,
    record_update_degraded,
};

pub const TaskCompletion = struct {
    id: u64,
    state: TaskState,
    exit_code: ?i32,
};

pub const TaskRecord = struct {
    id: u64,
    pid: []u8,
    process_token: ?ProcessInstanceToken = null,
    policy: BackgroundLaunchPolicy = .process_local_long_lived,
    source_session_id: ?[]u8 = null,
    background_record_id: ?StableBackgroundRecordId = null,
    durable_record_id: ?u64 = null,
    record_authority: RecordAuthority = .none,
    record_persistence: RecordPersistenceState = .not_applicable,
    record_warning_emitted: bool = false,
    managed_log_name: ?[]u8 = null,
    command: []u8,
    cwd: []u8,
    log_path: []u8,
    expect_url: bool,
    server_url: ?[]u8 = null,
    started_at_ms: i64,
    exit_code: ?i32 = null,
    state: TaskState = .running,

    pub fn deinit(self: *TaskRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.pid);
        if (self.source_session_id) |source_session_id| {
            alloc.free(source_session_id);
        }
        if (self.managed_log_name) |managed_log_name| {
            alloc.free(managed_log_name);
        }
        alloc.free(self.command);
        alloc.free(self.cwd);
        alloc.free(self.log_path);
        if (self.server_url) |url| alloc.free(url);
    }
};

pub const RuntimeContextSnapshot = struct {
    process_id: ?u64 = null,
    background_log_path: ?[]u8 = null,
    background_expect_url: bool = false,
    server_url: ?[]u8 = null,
    tasks: []TaskSnapshot = &.{},

    pub fn deinit(self: RuntimeContextSnapshot, alloc: std.mem.Allocator) void {
        if (self.background_log_path) |log_path| alloc.free(log_path);
        if (self.server_url) |url| alloc.free(url);
        for (self.tasks) |task| task.deinit(alloc);
        if (self.tasks.len > 0) alloc.free(self.tasks);
    }
};

pub const PublishServerUrlResult = enum {
    updated,
    stale,
    duplicate,
};

pub const TaskSnapshot = struct {
    id: u64,
    pid: []u8,
    process_token: ?ProcessInstanceToken = null,
    policy: BackgroundLaunchPolicy = .process_local_long_lived,
    source_session_id: ?[]u8 = null,
    background_record_id: ?StableBackgroundRecordId = null,
    durable_record_id: ?u64 = null,
    record_authority: RecordAuthority = .none,
    record_persistence: RecordPersistenceState = .not_applicable,
    managed_log_name: ?[]u8 = null,
    command: []u8,
    cwd: []u8,
    log_path: []u8,
    expect_url: bool,
    server_url: ?[]u8 = null,
    started_at_ms: i64,
    exit_code: ?i32 = null,
    state: TaskState,

    pub fn deinit(self: TaskSnapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.pid);
        if (self.source_session_id) |source_session_id| {
            alloc.free(source_session_id);
        }
        if (self.managed_log_name) |managed_log_name| {
            alloc.free(managed_log_name);
        }
        alloc.free(self.command);
        alloc.free(self.cwd);
        alloc.free(self.log_path);
        if (self.server_url) |url| alloc.free(url);
    }
};

pub const TaskListSnapshot = struct {
    items: []TaskSnapshot,

    pub fn deinit(self: TaskListSnapshot, alloc: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(alloc);
        alloc.free(self.items);
    }
};

pub const TaskSelection = union(enum) {
    last,
    id: u64,
};

pub const StopSelection = TaskSelection;

pub const StopCandidate = struct {
    id: u64,
    pid: []u8,
    process_token: ?ProcessInstanceToken,
};

pub const ProcessSupervisor = struct {
    next_background_process_id: u64 = 1,
    display_id_exhausted: bool = false,
    reserved_display_ids: std.ArrayList(u64) = .empty,
    tasks: std.ArrayList(TaskRecord) = .empty,

    pub fn deinit(self: *ProcessSupervisor, alloc: std.mem.Allocator) void {
        for (self.tasks.items) |*task| task.deinit(alloc);
        self.tasks.deinit(alloc);
        self.reserved_display_ids.deinit(std.heap.c_allocator);
        self.* = .{};
    }

    pub fn reserveDisplayId(self: *ProcessSupervisor) !u64 {
        if (self.display_id_exhausted) return error.BackgroundIdentityUnavailable;
        var candidate = self.next_background_process_id;
        while (self.displayIdReserved(candidate)) {
            if (candidate == std.math.maxInt(u64)) {
                self.display_id_exhausted = true;
                return error.BackgroundIdentityUnavailable;
            }
            candidate += 1;
        }
        try self.reserved_display_ids.append(std.heap.c_allocator, candidate);
        if (candidate == std.math.maxInt(u64)) {
            self.display_id_exhausted = true;
        } else {
            self.next_background_process_id = candidate + 1;
        }
        return candidate;
    }

    pub fn reservePreferredDisplayId(
        self: *ProcessSupervisor,
        preferred: u64,
    ) !u64 {
        if (!self.displayIdReserved(preferred)) {
            try self.reserved_display_ids.append(std.heap.c_allocator, preferred);
            if (!self.display_id_exhausted and
                preferred >= self.next_background_process_id)
            {
                if (preferred == std.math.maxInt(u64)) {
                    self.display_id_exhausted = true;
                } else {
                    self.next_background_process_id = preferred + 1;
                }
            }
            return preferred;
        }
        return self.reserveDisplayId();
    }

    pub fn releaseDisplayId(self: *ProcessSupervisor, display_id: u64) void {
        for (self.reserved_display_ids.items, 0..) |reserved, index| {
            if (reserved != display_id) continue;
            _ = self.reserved_display_ids.orderedRemove(index);
            return;
        }
    }

    pub fn retainDisplayIdReservation(
        self: *ProcessSupervisor,
        display_id: u64,
    ) void {
        if (self.displayIdReserved(display_id)) return;
        self.reserved_display_ids.appendAssumeCapacity(display_id);
    }

    fn displayIdReserved(self: *const ProcessSupervisor, display_id: u64) bool {
        for (self.reserved_display_ids.items) |reserved| {
            if (reserved == display_id) return true;
        }
        for (self.tasks.items) |task| {
            if (task.id == display_id) return true;
        }
        return false;
    }

    pub fn registerBackground(self: *ProcessSupervisor, alloc: std.mem.Allocator, registration: BackgroundRegistration) !u64 {
        const process_id = if (registration.display_id) |reserved| blk: {
            var found = false;
            for (self.reserved_display_ids.items) |id| {
                if (id == reserved) found = true;
            }
            if (!found) return error.BackgroundIdentityUnavailable;
            break :blk reserved;
        } else try self.reserveDisplayId();
        errdefer self.releaseDisplayId(process_id);

        const pid = try alloc.dupe(u8, registration.pid);
        errdefer alloc.free(pid);
        const command = try alloc.dupe(u8, registration.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, registration.cwd);
        errdefer alloc.free(cwd);
        const log_path = try alloc.dupe(u8, registration.log_path);
        errdefer alloc.free(log_path);

        var server_url: ?[]u8 = null;
        errdefer if (server_url) |url| alloc.free(url);
        if (registration.url) |url| {
            server_url = try alloc.dupe(u8, url);
        }

        var source_session_id: ?[]u8 = null;
        errdefer if (source_session_id) |value| alloc.free(value);
        if (registration.source_session_id) |value| {
            source_session_id = try alloc.dupe(u8, value);
        }
        var managed_log_name: ?[]u8 = null;
        errdefer if (managed_log_name) |value| alloc.free(value);
        if (registration.managed_log_name) |value| {
            managed_log_name = try alloc.dupe(u8, value);
        }

        try self.tasks.append(alloc, .{
            .id = process_id,
            .pid = pid,
            .process_token = registration.process_token,
            .policy = registration.policy,
            .source_session_id = source_session_id,
            .background_record_id = registration.background_record_id,
            .durable_record_id = registration.durable_record_id orelse
                if (registration.background_record_id != null)
                    process_id
                else
                    null,
            .record_authority = registration.record_authority,
            .record_persistence = if (registration.background_record_id != null)
                .confirmed
            else
                .not_applicable,
            .managed_log_name = managed_log_name,
            .command = command,
            .cwd = cwd,
            .log_path = log_path,
            .expect_url = registration.expect_url,
            .server_url = server_url,
            .started_at_ms = io_mod.milliTimestamp(),
        });
        self.releaseDisplayId(process_id);

        return process_id;
    }

    pub fn restoreBackground(
        self: *ProcessSupervisor,
        alloc: std.mem.Allocator,
        task_snapshot: TaskSnapshot,
    ) !u64 {
        const process_id = try self.reservePreferredDisplayId(
            task_snapshot.id,
        );
        errdefer self.releaseDisplayId(process_id);

        const pid = try alloc.dupe(u8, task_snapshot.pid);
        errdefer alloc.free(pid);
        const command = try alloc.dupe(u8, task_snapshot.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, task_snapshot.cwd);
        errdefer alloc.free(cwd);
        const log_path = try alloc.dupe(u8, task_snapshot.log_path);
        errdefer alloc.free(log_path);

        var server_url: ?[]u8 = null;
        errdefer if (server_url) |url| alloc.free(url);
        if (task_snapshot.server_url) |url| {
            server_url = try alloc.dupe(u8, url);
        }
        var source_session_id: ?[]u8 = null;
        errdefer if (source_session_id) |value| alloc.free(value);
        if (task_snapshot.source_session_id) |value| {
            source_session_id = try alloc.dupe(u8, value);
        }
        var managed_log_name: ?[]u8 = null;
        errdefer if (managed_log_name) |value| alloc.free(value);
        if (task_snapshot.managed_log_name) |value| {
            managed_log_name = try alloc.dupe(u8, value);
        }

        try self.tasks.append(alloc, .{
            .id = process_id,
            .pid = pid,
            .process_token = task_snapshot.process_token,
            .policy = task_snapshot.policy,
            .source_session_id = source_session_id,
            .background_record_id = task_snapshot.background_record_id,
            .durable_record_id = task_snapshot.durable_record_id,
            .record_authority = task_snapshot.record_authority,
            .record_persistence = task_snapshot.record_persistence,
            .managed_log_name = managed_log_name,
            .command = command,
            .cwd = cwd,
            .log_path = log_path,
            .expect_url = task_snapshot.expect_url,
            .server_url = server_url,
            .started_at_ms = task_snapshot.started_at_ms,
            .exit_code = task_snapshot.exit_code,
            .state = task_snapshot.state,
        });
        self.releaseDisplayId(process_id);
        return process_id;
    }

    pub fn restoreBackgroundAsNew(self: *ProcessSupervisor, alloc: std.mem.Allocator, task_snapshot: TaskSnapshot) !u64 {
        const process_id = try self.reserveDisplayId();
        errdefer self.releaseDisplayId(process_id);

        const pid = try alloc.dupe(u8, task_snapshot.pid);
        errdefer alloc.free(pid);
        const command = try alloc.dupe(u8, task_snapshot.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, task_snapshot.cwd);
        errdefer alloc.free(cwd);
        const log_path = try alloc.dupe(u8, task_snapshot.log_path);
        errdefer alloc.free(log_path);

        var server_url: ?[]u8 = null;
        errdefer if (server_url) |url| alloc.free(url);
        if (task_snapshot.server_url) |url| {
            server_url = try alloc.dupe(u8, url);
        }
        var source_session_id: ?[]u8 = null;
        errdefer if (source_session_id) |value| alloc.free(value);
        if (task_snapshot.source_session_id) |value| {
            source_session_id = try alloc.dupe(u8, value);
        }
        var managed_log_name: ?[]u8 = null;
        errdefer if (managed_log_name) |value| alloc.free(value);
        if (task_snapshot.managed_log_name) |value| {
            managed_log_name = try alloc.dupe(u8, value);
        }

        try self.tasks.append(alloc, .{
            .id = process_id,
            .pid = pid,
            .process_token = task_snapshot.process_token,
            .policy = task_snapshot.policy,
            .source_session_id = source_session_id,
            .background_record_id = task_snapshot.background_record_id,
            .durable_record_id = task_snapshot.durable_record_id,
            .record_authority = task_snapshot.record_authority,
            .record_persistence = task_snapshot.record_persistence,
            .managed_log_name = managed_log_name,
            .command = command,
            .cwd = cwd,
            .log_path = log_path,
            .expect_url = task_snapshot.expect_url,
            .server_url = server_url,
            .started_at_ms = task_snapshot.started_at_ms,
            .exit_code = task_snapshot.exit_code,
            .state = task_snapshot.state,
        });
        self.releaseDisplayId(process_id);

        return process_id;
    }

    pub fn snapshot(self: *const ProcessSupervisor, alloc: std.mem.Allocator) !RuntimeContextSnapshot {
        var running_count: usize = 0;
        for (self.tasks.items) |task| {
            if (task.state == .running) running_count += 1;
        }
        if (running_count == 0) return .{};

        const items = try alloc.alloc(TaskSnapshot, running_count);
        errdefer alloc.free(items);

        var copied: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < copied) : (j += 1) items[j].deinit(alloc);
        }

        for (self.tasks.items) |task| {
            if (task.state != .running) continue;
            items[copied] = try copyTaskSnapshot(alloc, task);
            copied += 1;
        }

        var i = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = self.tasks.items[i];
            if (task.state != .running) continue;

            const log_path = try alloc.dupe(u8, task.log_path);
            errdefer alloc.free(log_path);
            var server_url: ?[]u8 = null;
            errdefer if (server_url) |url| alloc.free(url);
            if (task.server_url) |url| {
                server_url = try alloc.dupe(u8, url);
            }

            return .{
                .process_id = task.id,
                .background_log_path = log_path,
                .background_expect_url = task.expect_url,
                .server_url = server_url,
                .tasks = items,
            };
        }

        unreachable;
    }

    pub fn snapshotServerUrl(self: *const ProcessSupervisor, alloc: std.mem.Allocator, process_id: u64) !?[]u8 {
        const task = self.findTask(process_id) orelse return null;
        if (task.state != .running) return null;
        const url = task.server_url orelse return null;
        return try alloc.dupe(u8, url);
    }

    pub fn publishServerUrl(self: *ProcessSupervisor, alloc: std.mem.Allocator, process_id: u64, url: []u8) PublishServerUrlResult {
        const task = self.findTaskMutable(process_id) orelse {
            alloc.free(url);
            return .stale;
        };

        if (task.state != .running) {
            alloc.free(url);
            return .stale;
        }

        if (task.server_url) |existing| {
            if (std.mem.eql(u8, existing, url)) {
                alloc.free(url);
                return .duplicate;
            }
            alloc.free(existing);
        }

        task.server_url = url;
        task.expect_url = false;
        return .updated;
    }

    pub fn snapshotTasks(self: *const ProcessSupervisor, alloc: std.mem.Allocator) !TaskListSnapshot {
        const items = try alloc.alloc(TaskSnapshot, self.tasks.items.len);
        errdefer alloc.free(items);

        var copied: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < copied) : (i += 1) items[i].deinit(alloc);
        }

        for (self.tasks.items, 0..) |task, i| {
            items[i] = try copyTaskSnapshot(alloc, task);
            copied += 1;
        }

        return .{ .items = items };
    }

    pub fn stopCandidate(self: *const ProcessSupervisor, alloc: std.mem.Allocator, selection: StopSelection) !?StopCandidate {
        const task = self.findSelectedRunningTask(selection) orelse return null;

        return .{
            .id = task.id,
            .pid = try alloc.dupe(u8, task.pid),
            .process_token = task.process_token,
        };
    }

    pub fn snapshotTask(self: *const ProcessSupervisor, alloc: std.mem.Allocator, selection: TaskSelection) !?TaskSnapshot {
        const task = switch (selection) {
            .last => self.findLastTask() orelse return null,
            .id => |id| self.findTask(id) orelse return null,
        };

        return try copyTaskSnapshot(alloc, task);
    }

    pub fn markStopped(self: *ProcessSupervisor, process_id: u64) bool {
        const task = self.findTaskMutable(process_id) orelse return false;
        task.state = .stopped;
        task.expect_url = false;
        task.exit_code = null;
        return true;
    }

    pub fn markCompleted(self: *ProcessSupervisor, process_id: u64, exit_code: ?i32) ?TaskCompletion {
        const task = self.findTaskMutable(process_id) orelse return null;
        if (task.state != .running) return null;

        task.expect_url = false;
        task.exit_code = exit_code;
        task.state = if (exit_code) |code|
            if (code == 0) .exited else .failed
        else
            .dead;

        return .{ .id = task.id, .state = task.state, .exit_code = task.exit_code };
    }

    pub fn markDead(self: *ProcessSupervisor, process_id: u64) ?TaskCompletion {
        const task = self.findTaskMutable(process_id) orelse return null;
        if (task.state != .running) return null;

        task.expect_url = false;
        task.exit_code = null;
        task.state = .dead;
        return .{ .id = task.id, .state = task.state, .exit_code = task.exit_code };
    }

    pub fn markStale(self: *ProcessSupervisor, process_id: u64) ?TaskCompletion {
        const task = self.findTaskMutable(process_id) orelse return null;
        if (task.state != .running) return null;

        task.expect_url = false;
        task.exit_code = null;
        task.state = .stale;
        return .{ .id = task.id, .state = task.state, .exit_code = task.exit_code };
    }

    pub fn setRecordPersistence(
        self: *ProcessSupervisor,
        process_id: u64,
        state: RecordPersistenceState,
        warning_emitted: bool,
    ) bool {
        const task = self.findTaskMutable(process_id) orelse return false;
        task.record_persistence = state;
        task.record_warning_emitted = warning_emitted;
        return true;
    }

    pub fn markRecordDegraded(
        self: *ProcessSupervisor,
        process_id: u64,
        state: RecordPersistenceState,
    ) bool {
        const task = self.findTaskMutable(process_id) orelse return false;
        if (task.background_record_id == null) return false;
        const should_warn = !task.record_warning_emitted;
        task.record_persistence = state;
        task.record_warning_emitted = true;
        return should_warn;
    }

    pub fn markRecordProjectionDegraded(
        self: *ProcessSupervisor,
        process_id: u64,
    ) bool {
        const task = self.findTaskMutable(process_id) orelse return false;
        if (task.background_record_id == null) return false;
        task.record_persistence = .record_update_degraded;
        return true;
    }

    pub fn findReusableRunningTask(self: *const ProcessSupervisor, alloc: std.mem.Allocator, cwd: []const u8, command: []const u8, expect_url: bool) !?TaskSnapshot {
        _ = expect_url;
        var i = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = self.tasks.items[i];
            if (task.state != .running) continue;
            if (!std.mem.eql(u8, task.cwd, cwd)) continue;
            if (!commandsEquivalent(task.command, command)) continue;
            return try copyTaskSnapshot(alloc, task);
        }
        return null;
    }

    pub fn snapshotTaskByLogPath(self: *const ProcessSupervisor, alloc: std.mem.Allocator, log_path: []const u8) !?TaskSnapshot {
        var i = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = self.tasks.items[i];
            if (!std.mem.eql(u8, task.log_path, log_path)) continue;
            return try copyTaskSnapshot(alloc, task);
        }
        return null;
    }

    pub fn removeWorkspaceTasks(self: *ProcessSupervisor, alloc: std.mem.Allocator, workspace_root: []const u8) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            if (taskBelongsToWorkspace(self.tasks.items[i], workspace_root)) {
                var task = self.tasks.orderedRemove(i);
                task.deinit(alloc);
                removed += 1;
                continue;
            }
            i += 1;
        }
        return removed;
    }

    pub fn removeTask(
        self: *ProcessSupervisor,
        alloc: std.mem.Allocator,
        process_id: u64,
    ) bool {
        for (self.tasks.items, 0..) |task, index| {
            if (task.id != process_id) continue;
            var removed = self.tasks.orderedRemove(index);
            removed.deinit(alloc);
            return true;
        }
        return false;
    }

    fn findTask(self: *const ProcessSupervisor, process_id: u64) ?TaskRecord {
        for (self.tasks.items) |task| {
            if (task.id == process_id) return task;
        }
        return null;
    }

    fn findTaskMutable(self: *ProcessSupervisor, process_id: u64) ?*TaskRecord {
        for (self.tasks.items) |*task| {
            if (task.id == process_id) return task;
        }
        return null;
    }

    fn findLastRunningTask(self: *const ProcessSupervisor) ?TaskRecord {
        var i = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = self.tasks.items[i];
            if (task.state == .running) return task;
        }
        return null;
    }

    fn findLastTask(self: *const ProcessSupervisor) ?TaskRecord {
        if (self.tasks.items.len == 0) return null;
        return self.tasks.items[self.tasks.items.len - 1];
    }

    fn findSelectedRunningTask(self: *const ProcessSupervisor, selection: TaskSelection) ?TaskRecord {
        return switch (selection) {
            .last => self.findLastRunningTask(),
            .id => |id| blk: {
                const found = self.findTask(id) orelse return null;
                if (found.state != .running) return null;
                break :blk found;
            },
        };
    }
};

fn commandsEquivalent(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, normalizeCommand(a), normalizeCommand(b));
}

fn normalizeCommand(command: []const u8) []const u8 {
    return std.mem.trim(u8, command, " \t\r\n");
}

fn taskBelongsToWorkspace(task: TaskRecord, workspace_root: []const u8) bool {
    return pathBelongsToWorkspace(task.cwd, workspace_root);
}

pub fn pathBelongsToWorkspace(path: []const u8, workspace_root: []const u8) bool {
    if (std.mem.eql(u8, path, workspace_root)) return true;
    if (!std.mem.startsWith(u8, path, workspace_root)) return false;
    if (path.len <= workspace_root.len) return false;
    return path[workspace_root.len] == std.fs.path.sep;
}

fn copyTaskSnapshot(alloc: std.mem.Allocator, task: TaskRecord) !TaskSnapshot {
    const pid = try alloc.dupe(u8, task.pid);
    errdefer alloc.free(pid);
    const command = try alloc.dupe(u8, task.command);
    errdefer alloc.free(command);
    const cwd = try alloc.dupe(u8, task.cwd);
    errdefer alloc.free(cwd);
    const log_path = try alloc.dupe(u8, task.log_path);
    errdefer alloc.free(log_path);

    var server_url: ?[]u8 = null;
    errdefer if (server_url) |url| alloc.free(url);
    if (task.server_url) |url| {
        server_url = try alloc.dupe(u8, url);
    }

    return .{
        .id = task.id,
        .pid = pid,
        .process_token = task.process_token,
        .policy = task.policy,
        .source_session_id = if (task.source_session_id) |value|
            try alloc.dupe(u8, value)
        else
            null,
        .background_record_id = task.background_record_id,
        .durable_record_id = task.durable_record_id,
        .record_authority = task.record_authority,
        .record_persistence = task.record_persistence,
        .managed_log_name = if (task.managed_log_name) |value|
            try alloc.dupe(u8, value)
        else
            null,
        .command = command,
        .cwd = cwd,
        .log_path = log_path,
        .expect_url = task.expect_url,
        .server_url = server_url,
        .started_at_ms = task.started_at_ms,
        .exit_code = task.exit_code,
        .state = task.state,
    };
}













