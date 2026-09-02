//! Headless persistent shell session for in-process embedding.
//!
//! Each evalScript call is one REPL command evaluated by the shell core
//! against the real POSIX host. EXIT traps run on exit / fatal flow, and
//! once from finish if they have not already run.

const EmbedSession = @This();

const std = @import("std");

const host = @import("../host.zig");
const shell_mod = @import("../shell.zig");

const RushShell = shell_mod.Shell(host.RealHost);

shell: RushShell,
finished: bool = false,
exit_status: u8 = 0,

pub fn init(allocator: std.mem.Allocator, env: []const [*:0]const u8) !EmbedSession {
    const pwd = (host.RealHost{}).currentDir(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    defer if (pwd) |dir| allocator.free(dir);

    return .{
        .shell = RushShell.init(allocator, .{}, .{
            .env = env,
            .arg_zero = "omfx",
            .initial_pwd = pwd orelse "/",
        }),
    };
}

pub fn deinit(self: *EmbedSession) void {
    self.shell.deinit();
    self.* = undefined;
}

pub fn evalScript(self: *EmbedSession, text: []const u8) u8 {
    if (self.finished) return self.exit_status;

    self.shell.resetForTopLevelCommand();
    const src: shell_mod.source.Source = .{
        .id = 1,
        .kind = .command_string,
        .name = "omfx",
        .text = text,
    };
    const evaluated = self.shell.evalSource(src) catch |err| return self.reportEvalError(err);
    return switch (evaluated.flow) {
        .exit, .fatal => self.runExitOnce(evaluated.status),
        else => evaluated.status,
    };
}

pub fn finish(self: *EmbedSession) u8 {
    return self.runExitOnce(self.shell.state.last_status);
}

fn runExitOnce(self: *EmbedSession, status: u8) u8 {
    if (self.finished) return self.exit_status;
    self.finished = true;
    const final_status = shell_mod.eval.runExitTrap(&self.shell, status) catch {
        self.exit_status = 2;
        return self.reportEvalError(error.Unexpected);
    };
    self.exit_status = final_status;
    return final_status;
}

fn reportEvalError(self: *EmbedSession, err: anyerror) u8 {
    if (!shell_mod.parser.isParseError(err)) {
        self.shell.host.writeAll(.stderr, "rush: shell error\n") catch {};
    }
    return 2;
}
