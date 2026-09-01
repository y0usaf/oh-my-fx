const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const command_environment = @import("../execution/command_environment.zig");
const io_mod = @import("../shared/io.zig");
const self_exe = @import("../shared/self_exe.zig");

const Allocator = std.mem.Allocator;

pub const ResolveError = error{
    RelativeShellPath,
    UnsupportedShell,
};

pub const Profile = command_environment.Profile;
pub const Environment = command_environment.Environment;

const rush_executable_token = "fx";

pub const Invocation = struct {
    path: []const u8,
    values: [6][]const u8 = @splat(""),
    len: usize = 0,

    pub fn argv(self: *const Invocation) []const []const u8 {
        return self.values[0..self.len];
    }

    fn append(self: *Invocation, value: []const u8) void {
        self.values[self.len] = value;
        self.len += 1;
    }

    pub fn setCommand(self: *Invocation, command: []const u8) void {
        self.append("-c");
        self.append(command);
    }
};
pub const rush_internal_mode = "--fx-internal-rush";

/// Builds the argv used to re-exec the embedded Rush app through fx.
///
/// `self_executable` is comptime so release callers can provide the absolute
/// fx path from build configuration without discovering it at runtime. Tests
/// and development builds may pass null, which deliberately uses the stable
/// internal executable token.
pub fn rushInvocation(
    self_executable: ?[]const u8,
    clean_start: bool,
) ResolveError!Invocation {
    const executable = self_executable orelse rush_executable_token;
    if (self_executable != null and !std.fs.path.isAbsolute(executable)) {
        return error.RelativeShellPath;
    }

    var result = Invocation{ .path = executable };
    result.append(executable);
    result.append(rush_internal_mode);
    if (!clean_start) result.append("--login");
    result.append("-i");
    return result;
}

pub fn capturedRushInvocation(
    self_executable: ?[]const u8,
    clean_start: bool,
    command: []const u8,
) ResolveError!Invocation {
    var invocation = try rushInvocation(self_executable, clean_start);
    removeInteractiveFlag(&invocation);
    invocation.setCommand(command);
    return invocation;
}

/// Builds the argv that re-executes this omfx process as the embedded rush
/// shell, resolving the on-disk self path so spawns do not depend on PATH.
pub fn capturedSelfInvocation(
    alloc: Allocator,
    clean_start: bool,
    command: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    const self_path = try self_exe.pathForReexec(alloc);
    var invocation = try rushInvocation(self_path, clean_start);
    removeInteractiveFlag(&invocation);
    invocation.setCommand(command);
    return invocation;
}

pub fn resolve(
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) ResolveError!Invocation {
    _ = configured_login_shell;
    const clean_start = switch (shell) {
        .user_login => false,
        .executable => |value| value.clean_start,
    };
    return rushInvocation(null, clean_start);
}

pub fn configuredLoginShellInto(buffer: []u8) ?[]const u8 {
    if (comptime !builtin.link_libc or builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return null;
    }
    var entry: std.c.passwd = undefined;
    var scratch: [4096]u8 = undefined;
    var found: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(
        std.c.getuid(),
        &entry,
        &scratch,
        scratch.len,
        &found,
    ) != 0) return null;
    const record = found orelse return null;
    const shell_ptr = record.shell orelse return null;
    const shell = std.mem.span(shell_ptr);
    if (shell.len == 0 or shell.len > buffer.len) return null;
    @memcpy(buffer[0..shell.len], shell);
    return buffer[0..shell.len];
}

pub fn environment(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: ?Profile,
) (ResolveError || Allocator.Error)!Environment {
    _ = configured_login_shell;
    const selected = profile orelse .user;
    return switch (selected) {
        .clean => .{ .clean = try alloc.dupe(u8, rush_executable_token) },
        .user => .{ .user = try alloc.dupe(u8, rush_executable_token) },
    };
}

pub fn profileShell(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    profile: Profile,
) (ResolveError || Allocator.Error)!contracts.ShellSpec {
    _ = configured_login_shell;
    return switch (profile) {
        .clean => .{ .executable = .{
            .path = try alloc.dupe(u8, rush_executable_token),
            .clean_start = true,
        } },
        .user => .user_login,
    };
}

pub fn capturedInvocation(
    alloc: Allocator,
    environment_value: Environment,
    command: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    switch (environment_value) {
        .legacy, .workspace_clean => return error.UnsupportedShell,
        .clean, .user => {},
    }
    return capturedSelfInvocation(alloc, false, command);
}

pub fn formatInvocationCommand(
    alloc: Allocator,
    invocation: *const Invocation,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    for (invocation.argv(), 0..) |word, index| {
        if (index != 0) try output.append(alloc, ' ');
        try appendShellWord(&output, alloc, word);
    }
    return output.toOwnedSlice(alloc);
}

fn removeInteractiveFlag(invocation: *Invocation) void {
    std.debug.assert(invocation.len > 0);
    std.debug.assert(std.mem.eql(u8, invocation.values[invocation.len - 1], "-i"));
    invocation.len -= 1;
}

pub fn buildBootstrap(
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);

    try output.appendSlice(alloc, "set +x; ");
    if (command_path) |path| {
        try output.appendSlice(alloc, "fx_terminal_command=$(< ");
        try appendShellWord(&output, alloc, path);
        try output.appendSlice(alloc, ") || exit 125; ");
    }
    try appendMarker(&output, alloc, executable, control_path, nonce, "shell-ready");
    if (command_path) |_| {
        try output.appendSlice(alloc, " || exit 125; ");
        try appendMarker(
            &output,
            alloc,
            executable,
            control_path,
            nonce,
            "command-started",
        );
        try output.appendSlice(
            alloc,
            " || exit 125; builtin eval -- \"$fx_terminal_command\"; " ++
                "fx_terminal_status=$?; exit \"$fx_terminal_status\"\n",
        );
    } else {
        try output.appendSlice(alloc, " || exit 125\n");
    }
    return output.toOwnedSlice(alloc);
}

pub fn buildSourceCommand(
    alloc: Allocator,
    bootstrap_path: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, ". ");
    try appendShellWord(&output, alloc, bootstrap_path);
    try output.append(alloc, '\n');
    return output.toOwnedSlice(alloc);
}

fn appendMarker(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    executable: []const u8,
    control_path: []const u8,
    nonce: []const u8,
    event: []const u8,
) Allocator.Error!void {
    try appendShellWord(output, alloc, executable);
    inline for (.{
        "--fx-internal-terminal-control",
        control_path,
        nonce,
        event,
    }) |word| {
        try output.append(alloc, ' ');
        try appendShellWord(output, alloc, word);
    }
}



fn appendShellWord(
    output: *std.ArrayList(u8),
    alloc: Allocator,
    word: []const u8,
) Allocator.Error!void {
    try output.append(alloc, '\'');
    for (word) |byte| {
        if (byte == '\'') {
            try output.appendSlice(alloc, "'\"'\"'");
        } else {
            try output.append(alloc, byte);
        }
    }
    try output.append(alloc, '\'');
}










fn checkBootstrapAllocationFailures(alloc: Allocator) !void {
    const bootstrap = try buildBootstrap(
        alloc,
        "/tmp/fx",
        "/tmp/control",
        "nonce",
        "/tmp/command",
    );
    defer alloc.free(bootstrap);
    const source = try buildSourceCommand(alloc, "/tmp/bootstrap");
    defer alloc.free(source);
}

