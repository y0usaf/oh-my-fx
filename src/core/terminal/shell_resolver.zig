const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
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

pub const ShellKind = enum { bash, zsh };

pub fn shellKind(path: []const u8) ?ShellKind {
    const basename = std.Io.Dir.path.basename(path);
    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    return null;
}

pub const Invocation = struct {
    path: []const u8,
    values: [8][]const u8 = @splat(""),
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
    // pathForReexec consults the OS for the on-disk executable; on macOS the
    // underlying query carries a wide error set, which collapses here so the
    // public resolver error set stays small.
    const self_path = self_exe.pathForReexec(alloc) catch return error.UnsupportedShell;
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
    if (comptime !builtin.link_libc or builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
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

pub fn environmentForShellSpec(
    alloc: Allocator,
    configured_login_shell: ?[]const u8,
    shell: contracts.ShellSpec,
) (ResolveError || Allocator.Error)!Environment {
    const invocation = try resolve(configured_login_shell, shell);
    return switch (shell) {
        .user_login => .{ .user = try alloc.dupe(u8, invocation.path) },
        .executable => |value| if (value.clean_start)
            .{ .clean = try alloc.dupe(u8, invocation.path) }
        else
            .{ .user = try alloc.dupe(u8, invocation.path) },
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

/// Stderr marker, followed by a nonce, that a snapshot bootstrap writes with
/// exit status 125 when the replay stopped before the command could start.
pub const snapshot_replay_failure_prefix = "fx-shell-snapshot-replay-failed:";

/// Builds the clean-shell argv for a snapshot run. The shell sources the
/// replay and the command from stdin, so no snapshot text or command appears
/// in argv. `failure_marker` reaches stderr, with exit status 125, only when
/// the replay stopped before the command started.
pub fn snapshotInvocation(
    alloc: Allocator,
    shell_path: []const u8,
    failure_marker: []const u8,
) (ResolveError || Allocator.Error)!Invocation {
    const kind = shellKind(shell_path) orelse return error.UnsupportedShell;
    var invocation = Invocation{ .path = shell_path };
    invocation.append(shell_path);
    switch (kind) {
        .zsh => invocation.append("-f"),
        .bash => {
            invocation.append("--noprofile");
            invocation.append("--norc");
            invocation.append("-O");
            invocation.append("expand_aliases");
        },
    }
    var bootstrap: std.ArrayList(u8) = .empty;
    errdefer bootstrap.deinit(alloc);
    try bootstrap.appendSlice(
        alloc,
        "\\builtin source /dev/fd/0; __fx_snapshot_status=$?; " ++
            "if [[ -z ${__fx_snapshot_restored-} ]]; then \\builtin printf '%s' ",
    );
    try appendShellWord(&bootstrap, alloc, failure_marker);
    // Re-raise the common termination signals so the supervisor reports a
    // signal, as it does when the shell runs the command directly.
    try bootstrap.appendSlice(
        alloc,
        " >&2; \\builtin exit 125; fi; " ++
            "case $__fx_snapshot_status in 129|130|137|143) " ++
            "\\builtin kill -$((__fx_snapshot_status - 128)) $$;; esac; " ++
            "\\builtin exit $__fx_snapshot_status",
    );
    invocation.setCommand(try bootstrap.toOwnedSlice(alloc));
    return invocation;
}

/// Builds the stdin script for a snapshot run: the replay, the restored flag
/// the bootstrap checks, and the command. The command is single-quoted so it
/// is parsed only when `eval` runs, after the replayed aliases exist, and it
/// runs with stdin from /dev/null so it cannot read the rest of the script.
pub fn snapshotScript(
    alloc: Allocator,
    replay: []const u8,
    command: []const u8,
) Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    try output.appendSlice(alloc, replay);
    if (replay.len != 0 and replay[replay.len - 1] != '\n') try output.append(alloc, '\n');
    try output.appendSlice(alloc, "__fx_snapshot_restored=1\n\\builtin eval -- ");
    try appendShellWord(&output, alloc, command);
    try output.appendSlice(alloc, " </dev/null\n");
    return output.toOwnedSlice(alloc);
}

/// Payload section markers written by `snapshotCaptureScript`. Each marker is
/// followed by `:` and the capture nonce.
pub const snapshot_marker_prefix = "FXSNAP:";

const zsh_capture_script =
    \\{
    \\\builtin zmodload zsh/parameter 2>/dev/null
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' ${(k)aliases} ${(k)galiases} ${(k)saliases} ${(k)functions}
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\\builtin typeset -p fpath
    \\for __fx_snapshot_name in ${(ko)functions}; do
    \\  case $__fx_snapshot_name in (_*|prompt_*|__fx_snapshot_*) continue;; esac
    \\  \builtin functions -- $__fx_snapshot_name
    \\done
    \\\builtin alias -L
    \\\builtin alias -sL
    \\for __fx_snapshot_name in extendedglob globdots nullglob nomatch kshglob shglob globstarshort bareglobqual caseglob numericglobsort rcexpandparam shwordsplit ksharrays magicequalsubst equals braceccl rcquotes shortloops cshnullglob globsubst; do
    \\  if [[ -o $__fx_snapshot_name ]]; then
    \\    \builtin print -r -- "\\builtin setopt $__fx_snapshot_name"
    \\  else
    \\    \builtin print -r -- "\\builtin unsetopt $__fx_snapshot_name"
    \\  fi
    \\done
    \\\builtin printf '\0FXSNAP:@NONCE@:END\0'
    \\} 2>/dev/null
;

const bash_capture_script =
    \\{
    \\\builtin printf 'FXSNAP:@NONCE@:ENV\0'
    \\/usr/bin/env -0
    \\\builtin printf 'FXSNAP:@NONCE@:NAMES\0'
    \\\builtin printf '%s\0' $(\builtin compgen -a) $(\builtin compgen -A function)
    \\\builtin printf 'FXSNAP:@NONCE@:REPLAY\0'
    \\for __fx_snapshot_name in $(\builtin compgen -A function); do
    \\  case $__fx_snapshot_name in _*|__fx_snapshot_*) continue;; esac
    \\  \builtin declare -f -- "$__fx_snapshot_name"
    \\done
    \\\builtin alias -p
    \\for __fx_snapshot_name in extglob nullglob dotglob globstar nocaseglob failglob nocasematch globasciiranges; do
    \\  \builtin shopt -p "$__fx_snapshot_name" 2>/dev/null
    \\done
    \\\builtin printf '\0FXSNAP:@NONCE@:END\0'
    \\} 2>/dev/null
;

/// Builds the script a login shell runs once to capture its state as a
/// NUL-delimited payload: exported environment, alias and function names, and
/// a replay of functions, aliases, and selected options. Every section marker
/// carries `nonce`, so output printed by the user's startup files cannot be
/// mistaken for the payload. `nonce` must be ASCII hex.
pub fn snapshotCaptureScript(
    alloc: Allocator,
    kind: ShellKind,
    nonce: []const u8,
) Allocator.Error![]u8 {
    for (nonce) |byte| std.debug.assert(std.ascii.isHex(byte));
    const template = switch (kind) {
        .zsh => zsh_capture_script,
        .bash => bash_capture_script,
    };
    return std.mem.replaceOwned(u8, alloc, template, "@NONCE@", nonce);
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

    try output.appendSlice(alloc, "set +x; export AI_AGENT=fx; ");
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

test "bootstrap quotes private paths and separates command completion" {
    const commandless = try buildBootstrap(
        std.testing.allocator,
        "/tmp/fx'bin",
        "/tmp/control",
        "nonce",
        null,
    );
    defer std.testing.allocator.free(commandless);
    try std.testing.expectEqualStrings(
        "set +x; export AI_AGENT=fx; '/tmp/fx'\"'\"'bin' '--fx-internal-terminal-control' " ++
            "'/tmp/control' 'nonce' 'shell-ready' || exit 125\n",
        commandless,
    );

    const command = try buildBootstrap(
        std.testing.allocator,
        "/tmp/fx",
        "/tmp/control",
        "nonce",
        "/tmp/command",
    );
    defer std.testing.allocator.free(command);
    try std.testing.expect(
        std.mem.find(u8, command, "'command-started'") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, command, "builtin eval --") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, command, "exit \"$fx_terminal_status\"") != null,
    );

    const source = try buildSourceCommand(
        std.testing.allocator,
        "/tmp/bootstrap'file",
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(
        ". '/tmp/bootstrap'\"'\"'file'\n",
        source,
    );
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
