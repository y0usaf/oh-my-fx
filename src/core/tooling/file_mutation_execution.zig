const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const tool_contracts = @import("../agent/runtime/tool_contracts.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation = @import("file_mutation.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const ToolExecutionResult = tool_contracts.ToolExecutionResult;
const max_file_mutation_success_bytes: usize = 8 * 1024;

const FileMutationPrepareError = @typeInfo(
    @typeInfo(@TypeOf(file_mutation.prepare)).@"fn".return_type.?,
).error_union.error_set;

const FileMutationApplyError = @typeInfo(
    @typeInfo(@TypeOf(file_mutation.apply)).@"fn".return_type.?,
).error_union.error_set;

pub const Input = struct {
    call_allocator: Allocator,
    result_allocator: Allocator,
    call: ToolCall,
    authorization: ?file_mutation_contract.FileExecutionAuthorization,
    maybe_cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_id: ?types.ToolLifecycleId = null,
};

pub const Error = error{
    OutOfMemory,
    Cancelled,
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

pub fn execute(input: Input) Error!ToolExecutionResult {
    var authorization = input.authorization orelse return fileMutationFailure(
        input.result_allocator,
        "file mutation execution authority is invalid",
        "preflight failed",
    );
    if (allocatorsEqual(input.call_allocator, input.result_allocator)) {
        return fileMutationFailure(
            input.result_allocator,
            "file mutation execution requires distinct call and result owners",
            "preflight failed",
        );
    }
    if (authorization.prepared == null) {
        if (authorization.policy_targets.prompt_required) {
            return fileMutationFailure(
                input.result_allocator,
                "file mutation execution requires prepared approval",
                "preflight failed",
            );
        }
        authorization.prepared = switch (file_mutation.prepare(
            input.call_allocator,
            input.call,
            authorization.input,
            authorization.policy_targets,
        ) catch |err| return mapFileMutationOperationalError(err)) {
            .prepared => |prepared| prepared,
            .semantic_failure => |reason| return fileMutationFailure(
                input.result_allocator,
                reason,
                "preflight failed",
            ),
        };
    }

    const prepared = authorization.prepared.?;
    if (file_mutation_contract.preparedMutationIsNoop(prepared)) {
        return .{
            .status = .success,
            .model_output = try std.fmt.allocPrint(
                input.result_allocator,
                "No changes to {s}; it already contains the requested content",
                .{prepared.display_path},
            ),
        };
    }

    const prepared_result = try prepareFileMutationSuccessResult(
        input.call_allocator,
        input.result_allocator,
        prepared,
    );
    var prepared_result_owned = true;
    defer if (prepared_result_owned) {
        input.result_allocator.free(prepared_result.model_output);
    };

    var fallback_cancel_flag = std.atomic.Value(bool).init(false);
    const applied = file_mutation.apply(
        input.call_allocator,
        input.result_allocator,
        input.call,
        authorization,
        input.maybe_cancel_flag orelse &fallback_cancel_flag,
    ) catch |err| return mapFileMutationApplyError(
        input.result_allocator,
        err,
    );
    return switch (applied) {
        .committed => |committed_file_handoff| blk: {
            var handoff = committed_file_handoff;
            if (input.lifecycle_id) |lifecycle_id| {
                captureFullViewAfterCommit(
                    &handoff,
                    input.result_allocator,
                    prepared.after_content,
                    lifecycle_id,
                );
            }
            prepared_result_owned = false;
            break :blk .{
                .status = .success,
                .model_output = prepared_result.model_output,
                .prepared_result_memory = prepared_result.memory,
                .committed_file_handoff = handoff,
            };
        },
        .rejected => |rejection| fileMutationRejectionResult(
            input.result_allocator,
            authorization.policy_targets,
            input.call,
            rejection,
        ),
    };
}

fn captureFullViewAfterCommit(
    handoff: *file_mutation.CommittedFileHandoff,
    alloc: Allocator,
    after_content: []const u8,
    lifecycle_id: types.ToolLifecycleId,
) void {
    handoff.attachFullView(alloc, after_content, lifecycle_id) catch |err| {
        debug_trace.logf(
            "tool",
            "committed file full-view capture unavailable call_id={s} err={s}",
            .{ lifecycle_id.call_id, @errorName(err) },
        );
    };
}

fn prepareFileMutationSuccessResult(
    call_alloc: Allocator,
    result_alloc: Allocator,
    prepared: file_mutation_contract.PreparedFileMutation,
) Allocator.Error!tool_result_limits.PreparedInlineResult {
    var encoded_path = try text_utils.encodeTerminalSafe(
        call_alloc,
        fileMutationDisplayTargetPath(prepared.policy_targets),
        diff_mod.max_encoded_path_bytes,
    );
    defer encoded_path.deinit(call_alloc);

    const raw_output = try std.fmt.allocPrint(
        call_alloc,
        "{s} {s} ({d} bytes)",
        .{
            if (prepared.kind == .write) "wrote" else "edited",
            encoded_path.bytes,
            prepared.after_content.len,
        },
    );
    defer call_alloc.free(raw_output);
    return tool_result_limits.prepareInlineResult(
        result_alloc,
        prepared.tool_name,
        raw_output,
        max_file_mutation_success_bytes,
    );
}

fn fileMutationDisplayTargetPath(
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) []const u8 {
    if (policy_targets.anchor.scope == .external) {
        return policy_targets.canonical_target_path;
    }
    const start = @min(
        policy_targets.anchor.path_end + 1,
        policy_targets.canonical_target_path.len,
    );
    return policy_targets.canonical_target_path[start..];
}

fn fileMutationFailure(
    alloc: Allocator,
    message: []const u8,
    detail: []const u8,
) Allocator.Error!ToolExecutionResult {
    return .{
        .status = .failure,
        .status_detail = detail,
        .model_output = try alloc.dupe(u8, message),
    };
}

fn allocatorsEqual(a: Allocator, b: Allocator) bool {
    return a.ptr == b.ptr and a.vtable == b.vtable;
}

fn mapFileMutationOperationalError(
    err: FileMutationPrepareError,
) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Cancelled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
    };
}

fn mapFileMutationApplyError(
    alloc: Allocator,
    err: FileMutationApplyError,
) Error!ToolExecutionResult {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultContractViolation => fileMutationFailure(
            alloc,
            "file mutation result contract is invalid",
            "preflight failed",
        ),
    };
}

fn fileMutationRejectionResult(
    alloc: Allocator,
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
    call: ToolCall,
    rejection: file_mutation.ApplyRejection,
) Allocator.Error!ToolExecutionResult {
    debug_trace.logf(
        "tool",
        "typed file mutation apply rejected call_id={s} reason={s} residue_count={d}",
        .{ call.id, @tagName(rejection.reason), rejection.created_parent_residue.len },
    );

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(switch (rejection.reason) {
        .binding_mismatch => "file mutation rejected because the approved call no longer matches",
        .stale_preimage => "file mutation rejected because the file changed after preview; make a new tool call for a fresh preview",
        .cancelled => "file mutation cancelled before commit",
        .traversal_changed => "file mutation rejected because the approved path traversal changed",
        .staged_source_changed => "file mutation rejected because the staged file changed before commit",
        .io_failure => "file mutation failed before commit",
    }) catch return error.OutOfMemory;
    if (rejection.created_parent_residue.len > 0) {
        out.writer.writeAll("; approved parent cleanup residue:") catch
            return error.OutOfMemory;
        for (rejection.created_parent_residue) |residue| {
            const raw_path =
                policy_targets.canonical_target_path[0..residue.path_end];
            var encoded = try text_utils.encodeTerminalSafe(
                alloc,
                raw_path,
                diff_mod.max_encoded_label_bytes,
            );
            defer encoded.deinit(alloc);
            out.writer.print(" {s} ({s})", .{
                encoded.bytes,
                @tagName(residue.reason),
            }) catch return error.OutOfMemory;
        }
    }
    return .{
        .status = .failure,
        .status_detail = switch (rejection.reason) {
            .stale_preimage => "stale preview",
            .cancelled => "cancelled",
            else => "rejected",
        },
        .model_output = try out.toOwnedSlice(),
    };
}



