const std = @import("std");
const debug_trace = @import("../../shared/debug_trace.zig");
const types = @import("../../shared/types.zig");
const execution_memory_helpers = @import("../execution_memory.zig");
const result_store = @import("../../session/result_store.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const command_output_content = @import("../../tooling/command_output_content.zig");
const io_mod = @import("../../shared/io.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const tool_result_limits = @import("../../tooling/tool_result_limits.zig");

const runtime_config = @import("config.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;

comptime {
    std.debug.assert(command_replay_store.model_handle_notice_reserve_bytes < tool_result_limits.min_configured_tool_result_bytes);
}
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const Config = runtime_config.Config;
const ToolExecutionStatus = runtime_tool_contracts.ToolExecutionStatus;

const steering_open = "<user_steering>\n";
const steering_close = "\n</user_steering>";

pub fn steeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, steering_open ++ "{s}" ++ steering_close, .{text});
}

pub fn persistedStatusForCurrentFxLocalResult(
    status: ToolExecutionStatus,
    output: []const u8,
) types.PersistedToolStatus {
    if (status == .failure) return .failure;
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub fn classifyProviderExecutedResultStatus(output: []const u8) types.PersistedToolStatus {
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub fn buildExecutionMemory(alloc: Allocator, within_turn_suffix: []const ChatMessage) !types.ExecutionMemory {
    var execution = try execution_memory_helpers.buildNormalChatExecutionMemory(
        alloc,
        within_turn_suffix,
    );
    errdefer types.freeExecutionMemory(alloc, execution);

    var steering: std.ArrayList([]u8) = .empty;
    errdefer {
        for (steering.items) |text| alloc.free(text);
        steering.deinit(alloc);
    }
    for (within_turn_suffix) |message| {
        if (message.role != .user) continue;
        const content = message.content orelse continue;
        const text = steeringText(content) orelse continue;
        const copy = try alloc.dupe(u8, text);
        steering.append(alloc, copy) catch |err| {
            alloc.free(copy);
            return err;
        };
    }
    execution.steering = try steering.toOwnedSlice(alloc);
    return execution;
}

fn steeringText(content: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, steering_open) or !std.mem.endsWith(u8, content, steering_close)) return null;
    return content[steering_open.len .. content.len - steering_close.len];
}

pub fn buildInterruptedExecutionMemory(
    alloc: Allocator,
    current_turn_messages: []const ChatMessage,
    active_tool_call: ?ToolCall,
) !types.ExecutionMemory {
    var filtered: std.ArrayList(ChatMessage) = .empty;
    defer filtered.deinit(alloc);
    try filtered.ensureTotalCapacity(alloc, current_turn_messages.len);
    var allocated_call_slices: std.ArrayList([]ToolCall) = .empty;
    defer {
        for (allocated_call_slices.items) |calls| alloc.free(calls);
        allocated_call_slices.deinit(alloc);
    }

    var i: usize = 0;
    while (i < current_turn_messages.len) {
        const item = current_turn_messages[i];
        if (item.role != .assistant or item.tool_calls.len == 0) {
            i += 1;
            continue;
        }

        var result_end = i + 1;
        while (result_end < current_turn_messages.len and
            current_turn_messages[result_end].role == .tool) : (result_end += 1)
        {}
        const result_messages = current_turn_messages[i + 1 .. result_end];
        var user_tail_end = result_end;
        while (user_tail_end < current_turn_messages.len and
            current_turn_messages[user_tail_end].role == .user) : (user_tail_end += 1)
        {}
        const user_tail = current_turn_messages[result_end..user_tail_end];

        var completed_count: usize = 0;
        for (item.tool_calls) |call| {
            if (active_tool_call) |active| {
                if (std.mem.eql(u8, call.id, active.id)) continue;
            }
            if (hasToolResultForCall(result_messages, call.id)) {
                completed_count += 1;
            }
        }

        if (completed_count > 0) {
            const calls = try alloc.alloc(ToolCall, completed_count);
            errdefer alloc.free(calls);
            try allocated_call_slices.append(alloc, calls);

            var completed_index: usize = 0;
            for (item.tool_calls) |call| {
                if (active_tool_call) |active| {
                    if (std.mem.eql(u8, call.id, active.id)) continue;
                }
                if (!hasToolResultForCall(result_messages, call.id)) continue;
                calls[completed_index] = call;
                completed_index += 1;
            }

            var projected = item;
            projected.tool_calls = calls;
            filtered.appendAssumeCapacity(projected);
            for (result_messages) |result| {
                const result_call_id = result.tool_call_id orelse continue;
                if (execution_memory_helpers.findToolCallById(
                    calls,
                    result_call_id,
                ) != null) {
                    filtered.appendAssumeCapacity(result);
                }
            }
            for (user_tail) |entry| {
                if (!entry.permission_feedback) continue;
                if (entry.tool_call_id) |source_tool_call_id| {
                    if (execution_memory_helpers.findToolCallById(calls, source_tool_call_id) == null) {
                        continue;
                    }
                }
                filtered.appendAssumeCapacity(entry);
            }
        }
        i = user_tail_end;
    }

    return buildExecutionMemory(alloc, filtered.items);
}

pub fn retainCancelledCommandReplay(
    arena: Allocator,
    result_memory: ?types.ToolResultMemory,
    capture: ?*command_replay_store.Capture,
) ?types.CancelledCommandPresentation {
    if (capture) |candidate| {
        const replay: ?types.CommandOutputReplay = switch (candidate.policy()) {
            .required => blk: {
                const descriptor = candidate.retainRequired(arena) catch |err| {
                    debug_trace.logf(
                        "session",
                        "cancelled command replay retention unavailable err={s}",
                        .{@errorName(err)},
                    );
                    break :blk .unavailable;
                } orelse break :blk null;
                break :blk .{ .available = descriptor };
            },
            .best_effort => candidate.retain(arena),
        };
        if (replay) |retained| return .{ .output_replay = retained };
    }
    const replay = if (result_memory) |memory|
        memory.command_output_replay
    else
        null;
    return if (replay) |value| .{ .output_replay = value } else null;
}


fn hasToolResultForCall(
    result_messages: []const ChatMessage,
    call_id: []const u8,
) bool {
    for (result_messages) |result| {
        if (result.tool_call_id) |result_call_id| {
            if (std.mem.eql(u8, result_call_id, call_id)) return true;
        }
    }
    return false;
}

pub fn prepareToolModelOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    raw_output: []const u8,
) !result_store.PreparedResult {
    return prepareCapturedToolModelOutput(
        arena,
        config,
        tool_call,
        raw_output,
        null,
    );
}

pub fn prepareCapturedToolModelOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    raw_output: []const u8,
    capture: ?*command_replay_store.Capture,
) !result_store.PreparedResult {
    const required_command_replay = if (capture) |candidate|
        candidate.policy() == .required
    else
        false;
    if (!required_command_replay and
        (config.session_child_capability != null or config.tool_result_dir != null) and
        raw_output.len > result_store.large_result_threshold_bytes)
    {
        const redacted_output = try execution_memory_helpers.redactText(
            arena,
            raw_output,
        );
        if (config.session_child_capability != null) {
            return result_store.prepareManaged(
                arena,
                config.session_child_capability,
                tool_call.id,
                tool_call.name,
                raw_output.len,
                redacted_output,
                config.max_tool_result_bytes,
            );
        }
        return result_store.prepare(
            arena,
            config.tool_result_dir,
            tool_call.id,
            tool_call.name,
            raw_output.len,
            redacted_output,
            config.max_tool_result_bytes,
        );
    }
    const model_output_budget = if (required_command_replay)
        config.max_tool_result_bytes -| command_replay_store.model_handle_notice_reserve_bytes
    else
        config.max_tool_result_bytes;
    const safe_output = try tool_result_limits.prepareModelOutput(
        arena,
        tool_call.name,
        raw_output,
        model_output_budget,
    );
    return .{
        .model_output = safe_output,
        .memory = .{
            .output_bytes = raw_output.len,
            .stored_output_bytes = safe_output.len,
            .truncated = safe_output.len < raw_output.len,
        },
    };
}

pub fn applyToolResultMemory(
    prepared: *types.ToolResultMemory,
    source: ?types.ToolResultMemory,
) void {
    const source_memory = source orelse return;
    prepared.command_output_replay = source_memory.command_output_replay;
    prepared.command_process_presentation = source_memory.command_process_presentation;
    prepared.terminal_action_presentation = source_memory.terminal_action_presentation;
    const source_covers_full_file =
        source_memory.model_view_covers_full_file orelse return;
    prepared.model_view_covers_full_file =
        source_covers_full_file and
        !source_memory.truncated and
        source_memory.output_handle == null and
        !prepared.truncated and
        prepared.output_handle == null;
}

/// Finalizes tentative command capture after bounded model output is prepared.
/// Required native exec always retains one authoritative replay and publishes
/// its handle; legacy exact round trips keep the existing discard optimization.
pub fn finalizeCommandReplay(
    arena: Allocator,
    tool_call: ToolCall,
    prepared: *result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    capture: ?*command_replay_store.Capture,
) !void {
    const candidate = capture orelse return;
    if (!candidate.hasOutput()) {
        candidate.discard(arena);
        return;
    }
    if (candidate.policy() == .required) {
        const descriptor = (try candidate.retainRequired(arena)) orelse return;
        prepared.memory.command_output_replay = .{ .available = descriptor };
        prepared.model_output = try command_replay_store.appendModelHandleNotice(
            arena,
            prepared.model_output,
            descriptor.handle,
        );
        prepared.memory.stored_output_bytes = prepared.model_output.len;
        return;
    }
    var captured = candidate.canonicalizeForComparison(arena) catch |err| {
        debug_trace.logf(
            "session",
            "command replay comparison unavailable call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer captured.deinit(arena);

    const source = selectedCommandSource(
        arena,
        prepared.*,
        session_child_capability,
        candidate.comparisonLimit(),
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay source comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer arena.free(source);
    var ordinary = (command_output_content.canonicalizeForegroundResult(
        arena,
        source,
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay envelope comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    }) orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer ordinary.deinit(arena);

    if (command_output_content.eql(captured, ordinary)) {
        candidate.discard(arena);
        return;
    }
    retainCommandReplay(arena, candidate, &prepared.memory);
}

fn selectedCommandSource(
    arena: Allocator,
    prepared: result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    comparison_limit: usize,
) !?[]u8 {
    const source_limit = std.math.add(
        usize,
        comparison_limit,
        command_output_content.max_foreground_result_envelope_bytes,
    ) catch return null;
    if (prepared.memory.output_handle) |handle| {
        const capability = session_child_capability orelse return null;
        var reader = try result_store.openReaderManaged(arena, capability, handle);
        defer reader.deinit();
        if (reader.size != prepared.memory.stored_output_bytes or
            reader.size > source_limit) return null;

        const source = try arena.alloc(u8, reader.size);
        errdefer arena.free(source);
        var offset: usize = 0;
        while (offset < source.len) {
            const page_len = @min(source.len - offset, 4 * 1024);
            const page = try reader.readPage(arena, offset, page_len);
            defer arena.free(page);
            if (page.len != page_len) return error.UnexpectedEndOfResult;
            @memcpy(source[offset..][0..page.len], page);
            offset += page.len;
        }
        return source;
    }
    if (prepared.model_output.len > source_limit) return null;
    const source = try execution_memory_helpers.redactText(arena, prepared.model_output);
    if (source.len > source_limit) {
        arena.free(source);
        return null;
    }
    return source;
}

fn retainCommandReplay(
    arena: Allocator,
    candidate: *command_replay_store.Capture,
    memory: *types.ToolResultMemory,
) void {
    memory.command_output_replay = candidate.retain(arena);
}

pub fn captureCommittedFilePresentation(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !types.CommittedFilePresentation {
    const path = try alloc.dupe(u8, handoff.preview.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, handoff.preview.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (handoff.preview.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = switch (line.op) {
                .context => .context,
                .addition => .addition,
                .deletion => .deletion,
                .elision => .elision,
                .notice => .notice,
            },
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try alloc.dupe(u8, line.text),
        };
        copied_lines += 1;
    }
    const full_view = handoff.full_view;
    const previous_content = if (full_view != null) if (handoff.tracker.previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null else null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (full_view) |full|
        try alloc.dupe(u8, full.after_content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?types.ToolLifecycleId = if (full_view) |full| .{
        .turn_id = full.lifecycle_id.turn_id,
        .call_id = try alloc.dupe(u8, full.lifecycle_id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    return .{
        .path = path,
        .kind = switch (handoff.tracker.kind) {
            .write => .added,
            .edit => .edited,
        },
        .lines = lines,
        .additions = handoff.preview.additions,
        .deletions = handoff.preview.deletions,
        .truncated = handoff.preview.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
    };
}

fn toolCall(id: []const u8, name: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}










