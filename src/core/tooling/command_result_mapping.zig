const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const command_contract = @import("../execution/command_contract.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const background_launch_identity = @import("../background/background_launch_identity.zig");
const background_runtime = @import("../background/background_runtime.zig");
const tool_result_errors = @import("tool_result_errors.zig");

const Allocator = std.mem.Allocator;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;

pub const Foreground = struct {
    pub fn cancelledFailure(
        arena: Allocator,
        result: command_contract.RunCommandResult,
    ) !?ToolExecutionResult {
        if (!result.cancelled) return null;
        const command_result_json: ?[]const u8 = if (result.command_result) |command_result|
            command_result.toJson(arena) catch |err| blk: {
                debug_trace.logf("tool", "cancelled command result metadata omitted err={s}", .{@errorName(err)});
                break :blk null;
            }
        else
            null;
        return .{
            .status = .failure,
            .cancelled = true,
            .model_output = "command cancelled\n",
            .command_result_json = command_result_json,
        };
    }

    pub fn nonZeroFailure(
        arena: Allocator,
        result: command_contract.RunCommandResult,
    ) !?ToolExecutionResult {
        const command_result = result.command_result orelse return null;
        const foreground = switch (command_result) {
            .foreground => |foreground| foreground,
            .background => return null,
        };
        if (foreground.termination_indeterminate) {
            const details = [_]tool_result_errors.Detail{
                .{ .name = "command", .value = .{ .string = foreground.command } },
                .{ .name = "cwd", .value = .{ .string = foreground.cwd } },
                .{ .name = "termination_indeterminate", .value = .{ .boolean = true } },
            };
            return .{
                .status = .failure,
                .model_output = try tool_result_errors.toolExecutionFailureJson(arena, .{
                    .tool_name = "terminal",
                    .message = "Command started, but its final process status could not be confirmed",
                    .details = &details,
                    .suggestion = "Do not retry the command unchanged because its side effects may already exist. Inspect the resulting state first.",
                }),
                .command_result_json = try command_result.toJson(arena),
            };
        }
        if ((foreground.exit_code == null or foreground.exit_code.? == 0) and
            foreground.signal == null and
            !foreground.timed_out) return null;

        var details: [6]tool_result_errors.Detail = undefined;
        var count: usize = 0;
        details[count] = .{ .name = "command", .value = .{ .string = foreground.command } };
        count += 1;
        details[count] = .{ .name = "cwd", .value = .{ .string = foreground.cwd } };
        count += 1;
        if (foreground.exit_code) |code| {
            details[count] = .{ .name = "exit_code", .value = .{ .integer = code } };
            count += 1;
        }
        if (foreground.signal) |signal| {
            details[count] = .{ .name = "signal", .value = .{ .unsigned = signal } };
            count += 1;
        }
        const stderr_text = extractEnvelope(result.output, "<stderr>\n", "\n</stderr>");
        if (stderr_text.len > 0) {
            details[count] = .{ .name = "stderr", .value = .{ .string = stderr_text } };
            count += 1;
        }

        return .{
            .status = .failure,
            .model_output = try tool_result_errors.toolExecutionFailureJson(arena, .{
                .tool_name = "terminal",
                .message = if (foreground.exit_code != null) "Command exited with non-zero status" else "Command terminated before completing successfully",
                .details = details[0..count],
                .suggestion = "Inspect stderr and the command context, then fix the command or explain the blocker rather than retrying unchanged.",
            }),
            .command_result_json = try command_result.toJson(arena),
        };
    }

    pub fn timeoutFailure(
        arena: Allocator,
        command: []const u8,
        cwd: []const u8,
        timeout_ms: ?usize,
        started_ms: ?i64,
    ) !ToolExecutionResult {
        const cleanup =
            "cleanup_scope=process_group_and_tracked_descendants\n" ++
            "cleanup_guarantee=best_effort\n" ++
            "message=command timed out; cleanup was attempted for the process group and tracked descendants, but fully detached descendants may remain\n";
        const output = if (timeout_ms) |ms|
            try std.fmt.allocPrint(
                arena,
                "timeout=true\ntimeout_ms={d}\n" ++ cleanup,
                .{ms},
            )
        else
            try arena.dupe(u8, "timeout=true\n" ++ cleanup);
        return .{
            .status = .failure,
            .model_output = output,
            .command_result_json = try (command_contract.CommandResult{ .foreground = .{
                .command = command,
                .cwd = cwd,
                .timed_out = true,
                .duration_ms = if (started_ms) |started| elapsedMs(started, io_mod.milliTimestamp()) else null,
            } }).toJson(arena),
            .tool_result_memory = .{
                .command_process_presentation = .timed_out,
            },
        };
    }

    pub fn outputCaptureFailure(arena: Allocator) !ToolExecutionResult {
        const details = [_]tool_result_errors.Detail{
            .{ .name = "output_capture_failed", .value = .{ .boolean = true } },
        };
        return .{
            .status = .failure,
            .model_output = try tool_result_errors.toolExecutionFailureJson(arena, .{
                .tool_name = "terminal",
                .message = "Command output could not be retained",
                .details = &details,
                .suggestion = "Do not retry unchanged. Inspect available command evidence, free storage if needed, or explain that complete output capture failed.",
            }),
            .tool_result_memory = .{
                .command_process_presentation = .output_capture_failed,
            },
        };
    }
};

pub const Background = struct {
    pub fn persistenceUnavailableFailure(arena: Allocator) !ToolExecutionResult {
        const output = try arena.dupe(
            u8,
            "background_persistence_required=true\n" ++
                "background_persistence_available=false\n" ++
                "mode=headless\n" ++
                "reason=session_store_unavailable\n" ++
                "message=headless background commands require session persistence so they can be inspected after fx ask exits. Remove --no-save or restore access to the session store, then retry.\n",
        );
        return .{ .status = .failure, .model_output = output, .finish_turn = true, .system_notice = output };
    }

    pub fn launchPreparationFailure(arena: Allocator, err: anyerror) !ToolExecutionResult {
        const output = try std.fmt.allocPrint(
            arena,
            "background_launch_failed=true\n" ++
                "error={s}\n" ++
                "message=background launch preparation failed before a job was started.\n",
            .{@errorName(err)},
        );
        return .{
            .status = .failure,
            .model_output = output,
            .finish_turn = true,
            .system_notice = output,
            .interactive_notice = .{
                .topic = "background",
                .tone = .@"error",
                .body = try std.fmt.allocPrint(
                    arena,
                    "Command launch preparation failed ({s}).",
                    .{@errorName(err)},
                ),
            },
        };
    }

    pub fn persistenceSaveFailure(
        arena: Allocator,
        err: anyerror,
        launch_identity_fields: []const u8,
    ) !ToolExecutionResult {
        const identity_fields = switch (err) {
            error.BackgroundTerminationIndeterminate,
            error.BackgroundProcessIdentityIndeterminate,
            => launch_identity_fields,
            else => "",
        };
        const details = switch (err) {
            error.BackgroundPersistenceRequired => "background_persistence_required=true\n" ++
                "background_started=true\n" ++
                "background_stopped=true\n" ++
                "reason=metadata_persist_failed\n" ++
                "message=headless background command metadata could not be confirmed, so the launched job was stopped instead of being reported as manageable.\n",
            error.BackgroundTerminationIndeterminate => "background_termination_indeterminate=true\n" ++
                "background_started=true\n" ++
                "background_stopped=unknown\n" ++
                "reason=termination_unconfirmed\n" ++
                "message=headless background command metadata could not be confirmed and termination could not be confirmed; the job may still be running.\n",
            error.BackgroundProcessIdentityIndeterminate => "background_process_identity_indeterminate=true\n" ++
                "background_command_released=false\n" ++
                "background_stopped=unknown\n" ++
                "reason=wrapper_cleanup_unconfirmed\n" ++
                "message=background wrapper cleanup could not be confirmed; the command was not reported as released and the wrapper process may still exist.\n",
            else => "background_launch_failed=true\n" ++
                "background_started=false\n" ++
                "reason=launch_failed\n" ++
                "message=background launch failed before a manageable job was confirmed.\n",
        };
        const output = try std.fmt.allocPrint(
            arena,
            "mode=headless\n" ++
                "error={s}\n" ++
                "{s}" ++
                "{s}",
            .{ @errorName(err), identity_fields, details },
        );
        const interactive_body = switch (err) {
            error.BackgroundPersistenceRequired => try arena.dupe(
                u8,
                "Command metadata could not be saved; the launched job was stopped.",
            ),
            error.BackgroundTerminationIndeterminate => try arena.dupe(
                u8,
                "Command metadata could not be saved; whether the launched job stopped could not be confirmed.",
            ),
            error.BackgroundProcessIdentityIndeterminate => try arena.dupe(
                u8,
                "Command cleanup could not be confirmed; the wrapper process may still exist.",
            ),
            else => try std.fmt.allocPrint(
                arena,
                "Command launch failed before a manageable job was confirmed ({s}).",
                .{@errorName(err)},
            ),
        };
        return .{
            .status = .failure,
            .model_output = output,
            .finish_turn = true,
            .system_notice = output,
            .interactive_notice = .{
                .topic = "background",
                .tone = .@"error",
                .body = interactive_body,
            },
        };
    }

    pub fn launchFailure(arena: Allocator, err: anyerror) !ToolExecutionResult {
        return .{ .model_output = try std.fmt.allocPrint(
            arena,
            "background launch failed\nreason={s}",
            .{@errorName(err)},
        ) };
    }

    pub fn fromTaskSnapshot(
        arena: Allocator,
        task: background_runtime.TaskSnapshot,
    ) !command_contract.BackgroundCommand {
        return .{
            .pid = try arena.dupe(u8, task.pid),
            .command = try arena.dupe(u8, task.command),
            .cwd = try arena.dupe(u8, task.cwd),
            .log_path = try arena.dupe(u8, task.log_path),
            .url = if (task.server_url) |url| try arena.dupe(u8, url) else null,
            .expect_url = task.expect_url,
        };
    }

    pub fn taskCommandResultJson(
        arena: Allocator,
        task: background_runtime.TaskSnapshot,
        state: []const u8,
    ) ![]const u8 {
        return (command_contract.CommandResult{ .background = .{
            .command = task.command,
            .cwd = task.cwd,
            .background_id = task.id,
            .pid = task.pid,
            .log_path = task.log_path,
            .state = state,
            .server_url = task.server_url,
        } }).toJson(arena);
    }

    pub fn commandResultJson(
        arena: Allocator,
        background: command_contract.BackgroundCommand,
        background_id: u64,
        state: []const u8,
    ) ![]const u8 {
        return (command_contract.CommandResult{ .background = .{
            .command = background.command,
            .cwd = background.cwd,
            .background_id = background_id,
            .pid = background.pid,
            .log_path = background.log_path,
            .state = state,
            .server_url = background.url,
        } }).toJson(arena);
    }

    pub fn formatReuseOutput(arena: Allocator, task: background_runtime.TaskSnapshot) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        defer out.deinit();

        try out.writer.writeAll("reused existing background command\n");
        try out.writer.print("id={d}\n", .{task.id});
        try out.writer.print("pid={s}\n", .{task.pid});
        try out.writer.print("log={s}\n", .{task.log_path});
        if (task.server_url) |url| {
            try out.writer.print("url={s}\n", .{url});
        }
        return try out.toOwnedSlice();
    }

    pub fn formatReuseNotice(arena: Allocator, task: background_runtime.TaskSnapshot) ![]const u8 {
        if (task.server_url) |url| {
            return std.fmt.allocPrint(arena, "Background #{d}: reusing running server at {s}", .{ task.id, url });
        }
        if (task.expect_url) {
            return std.fmt.allocPrint(arena, "Background #{d}: reusing running server. Waiting for local URL.", .{task.id});
        }
        return std.fmt.allocPrint(arena, "Background #{d}: reusing running command. Log: {s}", .{ task.id, task.log_path });
    }

    pub fn interactiveReuseNotice(arena: Allocator, task: background_runtime.TaskSnapshot) !types.SemanticNotice {
        const body = if (task.server_url) |url|
            try std.fmt.allocPrint(arena, "Command #{d} reused. Server: {s}.", .{ task.id, url })
        else if (task.expect_url)
            try std.fmt.allocPrint(arena, "Command #{d} reused. Waiting for local URL.", .{task.id})
        else
            try std.fmt.allocPrint(arena, "Command #{d} reused. Log: {s}", .{ task.id, task.log_path });
        return .{
            .topic = "background",
            .tone = .neutral,
            .body = body,
        };
    }
};

fn extractEnvelope(output: []const u8, open: []const u8, close: []const u8) []const u8 {
    const start = std.mem.find(u8, output, open) orelse return "";
    const body = output[start + open.len ..];
    const end = std.mem.find(u8, body, close) orelse return "";
    return body[0..end];
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    return if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn freeBackgroundCommand(alloc: Allocator, background: command_contract.BackgroundCommand) void {
    alloc.free(background.pid);
    alloc.free(background.command);
    alloc.free(background.cwd);
    alloc.free(background.log_path);
    if (background.url) |url| alloc.free(url);
}
