const std = @import("std");
const builtin = @import("builtin");
const command_admission = @import("../permissions/command_admission.zig");
const command_environment = @import("command_environment.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const local_executor = @import("local_executor.zig");
const command_runner = @import("../execution/command_runner.zig");

pub const RouteKind = local_executor.RouteKind;
pub const PreparedCommandRoute = local_executor.PreparedCommand;
pub const RoutedCommandResult = local_executor.CommandResult;

/// Upper bound for raw callback bytes that can still be represented by the
/// route's ordinary foreground result. Above this bound the route either
/// rejects output or promotes it to an unordered command artifact.
pub fn foregroundResultComparisonLimit(
    route: PreparedCommandRoute,
    approved_shell_limit: usize,
) usize {
    return local_executor.foregroundResultComparisonLimit(route, approved_shell_limit);
}

pub fn prepareAuthorizedRoute(
    alloc: std.mem.Allocator,
    command_ctx: command_admission.CommandContext,
    authority: command_admission.CommandExecutionAuthority,
) !PreparedCommandRoute {
    if (command_ctx.target_os != builtin.os.tag) return error.CommandTargetMismatch;
    return switch (authority) {
        .direct_only => |fingerprint| blk: {
            if (!fingerprint.matches(command_ctx)) return error.CommandAdmissionChanged;
            var admission = command_effect.plan(
                alloc,
                command_ctx.command,
                command_ctx.resolved_cwd,
                command_ctx.background,
                command_ctx.target_os,
            ) catch return error.CommandAdmissionChanged;
            switch (admission) {
                .direct_read_only => |plan| {
                    debug_trace.logf("core", "terminal.exec authority=direct_only route=direct_read_only", .{});
                    break :blk .{ .direct_read_only = plan };
                },
                .approval_required => {
                    admission.deinit(alloc);
                    return error.CommandAdmissionChanged;
                },
            }
        },
        .shell_allowed => |shell| blk: {
            if (!shell.fingerprint.matches(command_ctx)) {
                return error.CommandAuthorityContextMismatch;
            }
            if (command_ctx.environment.requiresShellRoute()) {
                debug_trace.logf(
                    "core",
                    "terminal.exec authority=shell_allowed source={s} route=approved_shell environment={s}",
                    .{
                        @tagName(shell.source),
                        @tagName(std.meta.activeTag(command_ctx.environment)),
                    },
                );
                break :blk .{ .approved_shell = .{
                    .command_ctx = command_ctx,
                    .reason = .dynamic_shell,
                    .source = shell.source,
                } };
            }
            const admission = command_effect.plan(
                alloc,
                command_ctx.command,
                command_ctx.resolved_cwd,
                command_ctx.background,
                command_ctx.target_os,
            ) catch break :blk .{ .approved_shell = .{
                .command_ctx = command_ctx,
                .reason = .planning_failure,
                .source = shell.source,
            } };
            switch (admission) {
                .direct_read_only => |plan| {
                    debug_trace.logf("core", "terminal.exec authority=shell_allowed source={s} route=direct_read_only", .{@tagName(shell.source)});
                    break :blk .{ .direct_read_only = plan };
                },
                .approval_required => |reason| {
                    debug_trace.logf("core", "terminal.exec authority=shell_allowed source={s} route=approved_shell reason={s}", .{ @tagName(shell.source), @tagName(reason) });
                    break :blk .{ .approved_shell = .{
                        .command_ctx = command_ctx,
                        .reason = reason,
                        .source = shell.source,
                    } };
                },
            }
        },
    };
}

pub fn executePreparedRoute(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    route: PreparedCommandRoute,
) !RoutedCommandResult {
    return local_executor.executePreparedCommand(cfg, alloc, route);
}

pub fn executePlannedCommand(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    command_ctx: command_admission.CommandContext,
    authority: command_admission.CommandExecutionAuthority,
) !RoutedCommandResult {
    try validateConfigContext(cfg, command_ctx);
    const route = try prepareAuthorizedRoute(alloc, command_ctx, authority);
    return executePreparedRoute(cfg, alloc, route);
}

pub fn validateConfigContext(
    cfg: command_runner.Config,
    command_ctx: command_admission.CommandContext,
) !void {
    _ = cfg;
    if (command_ctx.target_os != builtin.os.tag) return error.CommandTargetMismatch;
}

fn context(command: []const u8, background: bool) command_admission.CommandContext {
    return .{
        .command = command,
        .resolved_cwd = "/tmp",
        .background = background,
        .target_os = builtin.os.tag,
    };
}

fn directAuthority(ctx: command_admission.CommandContext) command_admission.CommandExecutionAuthority {
    return .{ .direct_only = .init(ctx) };
}

fn shellAuthority(
    ctx: command_admission.CommandContext,
    source: command_admission.ShellAuthorizationSource,
) command_admission.CommandExecutionAuthority {
    return .{ .shell_allowed = .{
        .fingerprint = .init(ctx),
        .source = source,
    } };
}







