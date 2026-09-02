const std = @import("std");

const command_admission = @import("../permissions/command_admission.zig");
const direct_command = @import("../permissions/direct_command.zig");
const command_runner = @import("../execution/command_runner.zig");
const command_effect = @import("../shell_command/command_effect.zig");

pub const RouteKind = enum {
    direct_read_only,
    approved_shell,
};

/// An admitted foreground command prepared for local execution.
///
/// The direct plan owns its allocations. The caller must call `deinit`.
pub const PreparedCommand = union(enum) {
    direct_read_only: command_effect.DirectReadOnlyPlan,
    approved_shell: struct {
        command_ctx: command_admission.CommandContext,
        reason: command_effect.ApprovalReason,
        source: command_admission.ShellAuthorizationSource,
    },

    pub fn deinit(self: *PreparedCommand, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .direct_read_only => |*plan| plan.deinit(alloc),
            .approved_shell => {},
        }
        self.* = undefined;
    }
};

pub const CommandResult = struct {
    route: RouteKind,
    result: command_runner.CommandExecutionResult,
};

/// Upper bound for raw callback bytes that can still be represented by the
/// command's ordinary foreground result. Above this bound execution either
/// rejects output or promotes it to an unordered command artifact.
pub fn foregroundResultComparisonLimit(
    command: PreparedCommand,
    approved_shell_limit: usize,
) usize {
    return switch (command) {
        .direct_read_only => direct_command.direct_output_limit_bytes,
        .approved_shell => approved_shell_limit,
    };
}

/// Executes a prepared foreground command without taking ownership of it.
pub fn executePreparedCommand(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    command: PreparedCommand,
) !CommandResult {
    return switch (command) {
        .direct_read_only => |plan| .{
            .route = .direct_read_only,
            .result = try direct_command.executeDirectReadOnly(cfg, alloc, plan),
        },
        .approved_shell => |shell| .{
            .route = .approved_shell,
            .result = try command_runner.executeCommandInEnvironment(
                cfg,
                alloc,
                shell.command_ctx.command,
                shell.command_ctx.resolved_cwd,
                shell.command_ctx.environment,
            ),
        },
    };
}
