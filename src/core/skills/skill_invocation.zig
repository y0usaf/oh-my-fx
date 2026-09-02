const std = @import("std");
const io_mod = @import("../shared/io.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const skill_contract = @import("skill_contract.zig");
const skill_runtime = @import("skill_runtime.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const context_limits = @import("../config/context_limits.zig");
const test_debug_trace = if (@import("builtin").is_test)
    @import("../shared/debug_trace.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ambiguous_skill_suffix_fmt = "; {d} additional advertised location{s} omitted by the {d}-byte tool-result limit. Refresh available skills and retry with an advertised name and location.";
const discovery_model_notice = "<skill_discovery_warning details=\"context_notice\" />\n";
const test_workspace_roots = [_]skill_contract.RootSpec{
    .{ .source = .workspace_shared, .path = "skills" },
};
const test_root_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &test_workspace_roots,
    .managed_root_source = .global_fx,
};

/// Borrows a previously discovered skill inventory for one invocation.
pub const Catalog = struct {
    skills: []const skill_runtime.Skill,
    diagnostics: []const skill_runtime.SkillDiagnostic = &.{},
};

const CandidateCheck = struct {
    skill: *const skill_runtime.Skill,
    validation: CandidateValidation,
};

const CandidateValidation = union(enum) {
    current,
    missing,
    name_mismatch,
    skipped: skill_runtime.SkillDiagnosticCause,
};

const TestLoadHook = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque) anyerror!void,
};

const LoadOptions = struct {
    test_after_candidate_validation: if (@import("builtin").is_test) ?TestLoadHook else void =
        if (@import("builtin").is_test) null else {},
};

const ExecuteOutput = struct {
    model_output: []const u8,
    notice: ?[]const u8 = null,
    diagnostic_notice: ?[]const u8 = null,
};

/// Owns every non-null output slice. Release it with `freeExecuteResult`, or
/// transfer the model output with `takeModelOutput`.
pub const ExecuteResult = union(enum) {
    loaded: ExecuteOutput,
    failure: ExecuteOutput,

    pub fn modelOutput(self: ExecuteResult) []const u8 {
        return switch (self) {
            .loaded, .failure => |output| output.model_output,
        };
    }

    pub fn contextNotice(self: ExecuteResult) ?[]const u8 {
        return switch (self) {
            .loaded, .failure => |output| output.notice,
        };
    }

    pub fn diagnosticNotice(self: ExecuteResult) ?[]const u8 {
        return switch (self) {
            .loaded, .failure => |output| output.diagnostic_notice,
        };
    }
};

/// Borrows the identity selected by a caller.
pub const ExplicitBinding = struct {
    name: []const u8,
    path: []const u8,
};

/// Owns `text` and both optional notices.
pub const ExplicitPromptSection = struct {
    text: []u8,
    notice: ?[]u8 = null,
    diagnostic_notice: ?[]u8 = null,

    pub fn deinit(self: *ExplicitPromptSection, alloc: Allocator) void {
        alloc.free(self.text);
        if (self.notice) |notice| alloc.free(notice);
        if (self.diagnostic_notice) |notice| alloc.free(notice);
        self.* = .{ .text = &.{} };
    }
};

/// Builds the ordered prompt section for explicit bindings and prompt matches.
/// The returned section owns its output slices.
pub fn buildExplicitPromptSection(
    alloc: Allocator,
    catalog: Catalog,
    prompt: []const u8,
    bindings: []const ExplicitBinding,
    limits: context_limits.Values,
) !ExplicitPromptSection {
    const binding_plan = try buildExplicitBindingPlan(alloc, catalog.skills, prompt, bindings);
    defer alloc.free(binding_plan);
    if (binding_plan.len == 0) {
        return .{ .text = try alloc.dupe(u8, "") };
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var notices: std.Io.Writer.Allocating = .init(alloc);
    defer notices.deinit();
    var diagnostic_notices: std.Io.Writer.Allocating = .init(alloc);
    defer diagnostic_notices.deinit();

    try out.writer.writeAll("Explicitly invoked skill content for this query:\n");
    for (binding_plan) |binding| {
        try appendExplicitSkill(
            alloc,
            &out.writer,
            &notices.writer,
            &diagnostic_notices,
            catalog,
            binding.name,
            binding.path,
            limits,
        );
    }

    const text = try out.toOwnedSlice();
    errdefer alloc.free(text);
    const notice = if (notices.written().len > 0) try notices.toOwnedSlice() else null;
    errdefer if (notice) |value| alloc.free(value);
    const diagnostic_notice = if (diagnostic_notices.written().len > 0) try diagnostic_notices.toOwnedSlice() else null;
    return .{ .text = text, .notice = notice, .diagnostic_notice = diagnostic_notice };
}

fn buildExplicitBindingPlan(
    alloc: Allocator,
    skills: []const skill_runtime.Skill,
    prompt: []const u8,
    bindings: []const ExplicitBinding,
) ![]ExplicitBinding {
    const matched_indices = try skill_runtime.matchExplicitSkillIndices(alloc, prompt, skills);
    defer alloc.free(matched_indices);

    var plan: std.ArrayList(ExplicitBinding) = .empty;
    defer plan.deinit(alloc);
    var loaded_paths = std.StringHashMap(void).init(alloc);
    defer loaded_paths.deinit();

    for (bindings) |binding| {
        if (loaded_paths.contains(binding.path)) continue;
        try loaded_paths.put(binding.path, {});
        try plan.append(alloc, binding);
    }
    for (matched_indices) |index| {
        const skill = skills[index];
        if (loaded_paths.contains(skill.path)) continue;
        try loaded_paths.put(skill.path, {});
        try plan.append(alloc, .{ .name = skill.name, .path = skill.path });
    }
    return plan.toOwnedSlice(alloc);
}

fn appendExplicitSkill(
    alloc: Allocator,
    out: *std.Io.Writer,
    notices: *std.Io.Writer,
    diagnostic_notices: *std.Io.Writer.Allocating,
    catalog: Catalog,
    name: []const u8,
    location: []const u8,
    limits: context_limits.Values,
) !void {
    const result = try loadByIdentity(alloc, catalog, name, location, null, 0, limits, null);
    defer freeExecuteResult(alloc, result);
    try out.writeAll(result.modelOutput());
    try out.writeByte('\n');
    if (result.contextNotice()) |notice| {
        try notices.writeAll(notice);
        if (!std.mem.endsWith(u8, notice, "\n")) try notices.writeByte('\n');
    }
    if (result.diagnosticNotice()) |notice| {
        if (diagnostic_notices.written().len == 0) {
            try diagnostic_notices.writer.writeAll(notice);
            if (!std.mem.endsWith(u8, notice, "\n")) try diagnostic_notices.writer.writeByte('\n');
        }
    }
}

/// Resolves and reads one skill from an already discovered catalog.
/// The returned result owns its output slices.
pub fn loadByIdentity(
    alloc: Allocator,
    catalog: Catalog,
    name: []const u8,
    location: ?[]const u8,
    resource: ?[]const u8,
    offset: usize,
    limits: context_limits.Values,
    max_tool_result_bytes: ?usize,
) !ExecuteResult {
    return loadByIdentityWithOptions(
        alloc,
        catalog,
        name,
        location,
        resource,
        offset,
        limits,
        max_tool_result_bytes,
        .{},
    );
}

fn loadByIdentityWithOptions(
    alloc: Allocator,
    catalog: Catalog,
    name: []const u8,
    location: ?[]const u8,
    resource: ?[]const u8,
    offset: usize,
    limits: context_limits.Values,
    max_tool_result_bytes: ?usize,
    options: LoadOptions,
) !ExecuteResult {
    const resolution = skill_runtime.resolveSkill(catalog.skills, name, location);
    var opened_candidate: ?skill_runtime.OpenedSkillCandidate = null;
    defer if (opened_candidate) |*candidate| candidate.deinit();
    const candidate_check: ?CandidateCheck = switch (resolution) {
        .found => |skill| blk: {
            const validation: CandidateValidation = switch (try skill_runtime.openValidatedSkillCandidate(alloc, skill.*)) {
                .current => |candidate| current: {
                    opened_candidate = candidate;
                    break :current .current;
                },
                .missing => .missing,
                .name_mismatch => .name_mismatch,
                .skipped => |cause| .{ .skipped = cause },
            };
            break :blk .{
                .skill = skill,
                .validation = validation,
            };
        },
        .not_found, .ambiguous_name, .name_location_mismatch => null,
    };
    const current_diagnostic: ?skill_runtime.SkillDiagnostic = if (candidate_check) |check|
        switch (check.validation) {
            .skipped => |cause| .{
                .path = check.skill.path,
                .source = check.skill.source,
                .scope = .candidate,
                .cause = cause,
            },
            .current, .missing, .name_mismatch => null,
        }
    else
        null;
    if (current_diagnostic) |diagnostic| {
        skill_runtime.traceDiagnostics("skill_invocation", &.{diagnostic});
    }

    var discovery_notice = try formatDiscoveryNotice(alloc, catalog.diagnostics, current_diagnostic);
    errdefer if (discovery_notice) |notice| alloc.free(notice);
    const primary_budget = if (max_tool_result_bytes) |limit|
        executePrimaryBudget(limit, discovery_notice != null)
    else
        std.math.maxInt(usize);

    const skill = switch (resolution) {
        .found => |skill| skill,
        .not_found => {
            if (location) |exact_location| {
                return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatExactSkillNotFound(alloc, name, exact_location, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
            }
            return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatMissingSkill(alloc, name, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
        },
        .ambiguous_name => return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatAmbiguousSkill(alloc, catalog.skills, name, primary_budget) } }, &discovery_notice, max_tool_result_bytes),
        .name_location_mismatch => return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatSkillLocationMismatch(alloc, name, location.?, primary_budget) } }, &discovery_notice, max_tool_result_bytes),
    };
    switch (candidate_check.?.validation) {
        .current => {},
        .missing, .skipped => {
            if (location) |exact_location| {
                return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatExactSkillNotFound(alloc, name, exact_location, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
            }
            return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatMissingSkill(alloc, name, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
        },
        .name_mismatch => {
            if (location) |exact_location| {
                return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatSkillLocationMismatch(alloc, name, exact_location, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
            }
            return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try formatMissingSkill(alloc, name, primary_budget) } }, &discovery_notice, max_tool_result_bytes);
        },
    }
    if (comptime @import("builtin").is_test) {
        if (options.test_after_candidate_validation) |hook| try hook.check(hook.ctx);
    }

    const resource_path = resource orelse "SKILL.md";
    const candidate = if (opened_candidate) |*current| current else unreachable;
    const resource_read = try readSkillResource(alloc, candidate, resource_path, limits.skill_file_bytes);
    defer alloc.free(resource_read.bytes);
    if (offset > resource_read.bytes.len or !std.unicode.utf8ValidateSlice(resource_read.bytes[0..offset])) {
        return attachOwnedDiscoveryNotice(alloc, .{ .failure = .{ .model_output = try alloc.dupe(u8, "skill offset must be at a valid UTF-8 boundary within the selected resource") } }, &discovery_notice, max_tool_result_bytes);
    }
    if (offset == resource_read.bytes.len and resource_read.observed_bytes > resource_read.bytes.len) {
        return attachOwnedDiscoveryNotice(alloc, try contextLimitFailure(alloc, try formatSkillFileBlocked(
            alloc,
            resource_path,
            resource_read.observed_bytes,
            limits.skill_file_bytes,
        )), &discovery_notice, max_tool_result_bytes);
    }

    const remaining = resource_read.bytes[offset..];
    const chunk_limit = limits.skill_chunk_bytes;
    const chunk_len = context_limits.lineSafePrefixLength(remaining, chunk_limit.effectiveBytes());
    if (remaining.len > 0 and chunk_len == 0) {
        return attachOwnedDiscoveryNotice(alloc, try contextLimitFailure(alloc, try formatSkillChunkBlocked(
            alloc,
            skill.name,
            resource_path,
            remaining.len,
            chunk_limit,
            offset,
        )), &discovery_notice, max_tool_result_bytes);
    }
    const next_offset = offset + chunk_len;
    const chunk_truncated = next_offset < resource_read.bytes.len;
    const file_blocked = next_offset == resource_read.bytes.len and resource_read.observed_bytes > resource_read.bytes.len;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("<skill_content name=\"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, skill.name) catch return error.OutOfMemory;
    out.writer.writeAll("\" resource=\"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, resource_path) catch return error.OutOfMemory;
    out.writer.print("\" offset=\"{d}\" next_offset=\"{d}\">\n", .{ offset, next_offset }) catch return error.OutOfMemory;
    out.writer.writeAll(remaining[0..chunk_len]) catch return error.OutOfMemory;
    if (chunk_truncated) {
        out.writer.print(
            "\n<context_limit name=\"skill_chunk_bytes\" action=\"truncated\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" next_offset=\"{d}\" override=\"--context-limit skill_chunk_bytes=BYTES|off\" />",
            .{ remaining.len, chunk_limit.effectiveBytes(), chunk_limit.source.label(), next_offset },
        ) catch return error.OutOfMemory;
    } else if (file_blocked) {
        out.writer.writeByte('\n') catch return error.OutOfMemory;
        writeSkillFileBlockedMarker(
            &out.writer,
            resource_path,
            resource_read.observed_bytes,
            limits.skill_file_bytes,
        ) catch return error.OutOfMemory;
    }
    out.writer.writeAll("\n</skill_content>") catch return error.OutOfMemory;

    const model_content = out.toOwnedSlice() catch return error.OutOfMemory;
    const notice = if (chunk_truncated)
        formatSkillChunkNotice(
            alloc,
            skill.name,
            resource_path,
            remaining.len,
            chunk_limit,
            next_offset,
        ) catch |err| {
            alloc.free(model_content);
            return err;
        }
    else if (file_blocked)
        formatSkillFileBlockedNotice(
            alloc,
            skill.name,
            resource_path,
            resource_read.observed_bytes,
            limits.skill_file_bytes,
        ) catch |err| {
            alloc.free(model_content);
            return err;
        }
    else
        null;

    return attachOwnedDiscoveryNotice(alloc, .{ .loaded = .{ .model_output = model_content, .notice = notice } }, &discovery_notice, max_tool_result_bytes);
}

fn formatDiscoveryNotice(
    alloc: Allocator,
    diagnostics: []const skill_runtime.SkillDiagnostic,
    additional: ?skill_runtime.SkillDiagnostic,
) error{OutOfMemory}!?[]u8 {
    if (diagnostics.len == 0 and additional == null) return null;
    var combined = diagnostics;
    var owned_combined: ?[]skill_runtime.SkillDiagnostic = null;
    defer if (owned_combined) |items| alloc.free(items);
    if (additional) |diagnostic| {
        const items = try alloc.alloc(skill_runtime.SkillDiagnostic, diagnostics.len + 1);
        @memcpy(items[0..diagnostics.len], diagnostics);
        items[diagnostics.len] = diagnostic;
        owned_combined = items;
        combined = items;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    skill_runtime.writeDiagnosticSummary(alloc, &out.writer, combined) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn attachExecuteNotice(
    alloc: Allocator,
    result: ExecuteResult,
    additional: ?[]u8,
    max_tool_result_bytes: ?usize,
) error{OutOfMemory}!ExecuteResult {
    const notice = additional orelse return result;
    errdefer freeExecuteResult(alloc, result);
    errdefer alloc.free(notice);

    return switch (result) {
        inline .loaded, .failure => |output, tag| blk: {
            var updated = output;
            const model_output = if (max_tool_result_bytes) |limit| bounded: {
                const model_notice_len = @min(discovery_model_notice.len, limit);
                const primary_budget = executePrimaryBudget(limit, true);
                const prepared_primary = @constCast(try tool_result_limits.prepareModelOutput(
                    alloc,
                    "skill",
                    output.model_output,
                    primary_budget,
                ));
                defer alloc.free(prepared_primary);
                const primary_len = context_limits.utf8PrefixLength(prepared_primary, primary_budget);
                break :bounded try std.mem.concat(alloc, u8, &.{
                    discovery_model_notice[0..model_notice_len],
                    prepared_primary[0..primary_len],
                });
            } else try std.mem.concat(alloc, u8, &.{ discovery_model_notice, output.model_output });
            errdefer alloc.free(model_output);
            alloc.free(@constCast(output.model_output));
            updated.model_output = model_output;
            updated.diagnostic_notice = notice;
            break :blk @unionInit(ExecuteResult, @tagName(tag), updated);
        },
    };
}

fn attachOwnedDiscoveryNotice(
    alloc: Allocator,
    result: ExecuteResult,
    additional: *?[]u8,
    max_tool_result_bytes: ?usize,
) error{OutOfMemory}!ExecuteResult {
    const notice = additional.*;
    additional.* = null;
    return attachExecuteNotice(alloc, result, notice, max_tool_result_bytes);
}

fn executePrimaryBudget(max_tool_result_bytes: usize, include_discovery_notice: bool) usize {
    if (!include_discovery_notice) return max_tool_result_bytes;
    return max_tool_result_bytes - @min(discovery_model_notice.len, max_tool_result_bytes);
}

fn contextLimitFailure(alloc: Allocator, model_output: []u8) error{OutOfMemory}!ExecuteResult {
    errdefer alloc.free(model_output);
    return .{ .failure = .{
        .model_output = model_output,
        .notice = try alloc.dupe(u8, model_output),
    } };
}

fn formatSkillChunkBlocked(
    alloc: Allocator,
    skill_name: []const u8,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
    offset: usize,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("<context_limit name=\"skill_chunk_bytes\" action=\"blocked\" skill=\"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, skill_name) catch return error.OutOfMemory;
    out.writer.writeAll("\" resource=\"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, resource) catch return error.OutOfMemory;
    out.writer.print(
        "\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" offset=\"{d}\" override=\"--context-limit skill_chunk_bytes=BYTES|off\" />",
        .{ observed_bytes, limit.effectiveBytes(), limit.source.label(), offset },
    ) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn formatMissingSkill(alloc: Allocator, name: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    const prefix = "Skill \"";
    const suffix = "\" not found. Refresh available skills and retry with an advertised name.";
    const fallback = "Skill not found. Refresh available skills and retry with an advertised name.";
    return formatBoundedIdentityError(alloc, prefix, name, suffix, fallback, max_bytes);
}

fn formatBoundedIdentityError(
    alloc: Allocator,
    prefix: []const u8,
    value: []const u8,
    suffix: []const u8,
    fallback: []const u8,
    max_bytes: usize,
) error{OutOfMemory}![]u8 {
    const fixed_len = std.math.add(usize, prefix.len, suffix.len) catch return boundedSkillError(alloc, fallback, max_bytes);
    if (fixed_len +| 3 >= max_bytes) return boundedSkillError(alloc, fallback, max_bytes);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    model_context_encoding.writeScalar(&encoded.writer, value) catch return error.OutOfMemory;
    const ellipsis_len: usize = if (encoded.written().len > max_bytes - fixed_len) 3 else 0;
    const value_budget = max_bytes - fixed_len - ellipsis_len;
    const prefix_len = boundedEncodedPrefixLength(encoded.written(), value_budget);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(prefix) catch return error.OutOfMemory;
    out.writer.writeAll(encoded.written()[0..prefix_len]) catch return error.OutOfMemory;
    if (prefix_len < encoded.written().len) out.writer.writeAll("...") catch return error.OutOfMemory;
    out.writer.writeAll(suffix) catch return error.OutOfMemory;
    return boundedSkillError(alloc, out.written(), max_bytes);
}

fn formatExactSkillNotFound(alloc: Allocator, name: []const u8, location: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    return formatBoundedIdentityPairError(
        alloc,
        "Skill \"",
        name,
        "\" was not found at advertised location \"",
        location,
        "\". Refresh available skills and retry with an advertised name and location.",
        "Skill was not found at the advertised location. Refresh available skills and retry with an advertised name and location.",
        max_bytes,
    );
}

fn formatSkillLocationMismatch(alloc: Allocator, name: []const u8, location: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    return formatBoundedIdentityPairError(
        alloc,
        "Skill \"",
        name,
        "\" does not match the skill advertised at location \"",
        location,
        "\". Refresh available skills and retry with the advertised name and location.",
        "Skill name and location do not match one advertised skill. Refresh available skills and retry with the advertised name and location.",
        max_bytes,
    );
}

fn formatBoundedIdentityPairError(
    alloc: Allocator,
    prefix: []const u8,
    first: []const u8,
    middle: []const u8,
    second: []const u8,
    suffix: []const u8,
    fallback: []const u8,
    max_bytes: usize,
) error{OutOfMemory}![]u8 {
    const fixed_len = std.math.add(usize, prefix.len, middle.len) catch return boundedSkillError(alloc, fallback, max_bytes);
    const complete_fixed_len = std.math.add(usize, fixed_len, suffix.len) catch return boundedSkillError(alloc, fallback, max_bytes);
    if (complete_fixed_len +| 6 >= max_bytes) return boundedSkillError(alloc, fallback, max_bytes);

    var encoded_first: std.Io.Writer.Allocating = .init(alloc);
    defer encoded_first.deinit();
    model_context_encoding.writeScalar(&encoded_first.writer, first) catch return error.OutOfMemory;
    var encoded_second: std.Io.Writer.Allocating = .init(alloc);
    defer encoded_second.deinit();
    model_context_encoding.writeScalar(&encoded_second.writer, second) catch return error.OutOfMemory;

    const available = max_bytes - complete_fixed_len - 6;
    const first_budget = @min(encoded_first.written().len, @min(available, skill_contract.max_name_bytes));
    const second_budget = available - first_budget;
    const first_len = boundedEncodedPrefixLength(encoded_first.written(), first_budget);
    const second_len = boundedEncodedPrefixLength(encoded_second.written(), second_budget);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(prefix) catch return error.OutOfMemory;
    out.writer.writeAll(encoded_first.written()[0..first_len]) catch return error.OutOfMemory;
    if (first_len < encoded_first.written().len) out.writer.writeAll("...") catch return error.OutOfMemory;
    out.writer.writeAll(middle) catch return error.OutOfMemory;
    out.writer.writeAll(encoded_second.written()[0..second_len]) catch return error.OutOfMemory;
    if (second_len < encoded_second.written().len) out.writer.writeAll("...") catch return error.OutOfMemory;
    out.writer.writeAll(suffix) catch return error.OutOfMemory;
    return boundedSkillError(alloc, out.written(), max_bytes);
}

fn boundedEncodedPrefixLength(encoded: []const u8, max_bytes: usize) usize {
    var prefix_len = context_limits.utf8PrefixLength(encoded, max_bytes);
    if (std.mem.lastIndexOfScalar(u8, encoded[0..prefix_len], '&')) |amp_index| {
        if (std.mem.indexOfScalar(u8, encoded[amp_index..prefix_len], ';') == null) prefix_len = amp_index;
    }
    return prefix_len;
}

fn formatAmbiguousSkill(alloc: Allocator, skills: []const skill_runtime.Skill, name: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    var match_count: usize = 0;
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.name, name)) match_count += 1;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("Skill \"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, name) catch return error.OutOfMemory;
    out.writer.writeAll("\" is ambiguous. Retry with the name and one advertised location: ") catch return error.OutOfMemory;

    var shown_count: usize = 0;
    for (skills) |skill| {
        if (!std.mem.eql(u8, skill.name, name)) continue;

        var choice: std.Io.Writer.Allocating = .init(alloc);
        defer choice.deinit();
        choice.writer.writeByte('"') catch return error.OutOfMemory;
        model_context_encoding.writeScalar(&choice.writer, skill.path) catch return error.OutOfMemory;
        choice.writer.writeByte('"') catch return error.OutOfMemory;

        const omitted_count = match_count - (shown_count + 1);
        const suffix_len = ambiguousSkillSuffixLen(omitted_count, max_bytes);
        const separator = if (shown_count > 0) ", " else "";
        const choice_with_suffix_len = std.math.add(usize, choice.written().len, suffix_len) catch std.math.maxInt(usize);
        const appended_len = std.math.add(usize, separator.len, choice_with_suffix_len) catch std.math.maxInt(usize);
        const prospective_len = std.math.add(usize, out.written().len, appended_len) catch std.math.maxInt(usize);
        if (prospective_len > max_bytes) break;

        out.writer.writeAll(separator) catch return error.OutOfMemory;
        out.writer.writeAll(choice.written()) catch return error.OutOfMemory;
        shown_count += 1;
    }

    if (shown_count == 0) {
        out.clearRetainingCapacity();
        out.writer.print(
            "Requested skill name is ambiguous; all {d} advertised locations were omitted by the {d}-byte tool-result limit. Refresh available skills and retry with an advertised name and location.",
            .{ match_count, max_bytes },
        ) catch return error.OutOfMemory;
    } else {
        try writeAmbiguousSkillSuffix(&out.writer, match_count - shown_count, max_bytes);
    }
    return boundedSkillError(alloc, out.written(), max_bytes);
}

fn ambiguousSkillSuffixLen(omitted_count: usize, max_bytes: usize) usize {
    if (omitted_count == 0) return 1;
    return std.fmt.count(ambiguous_skill_suffix_fmt, .{ omitted_count, if (omitted_count == 1) "" else "s", max_bytes });
}

fn writeAmbiguousSkillSuffix(writer: *std.Io.Writer, omitted_count: usize, max_bytes: usize) error{OutOfMemory}!void {
    if (omitted_count == 0) return writer.writeByte('.') catch error.OutOfMemory;
    writer.print(
        ambiguous_skill_suffix_fmt,
        .{ omitted_count, if (omitted_count == 1) "" else "s", max_bytes },
    ) catch return error.OutOfMemory;
}

fn boundedSkillError(alloc: Allocator, text: []const u8, max_bytes: usize) error{OutOfMemory}![]u8 {
    return @constCast(try tool_result_limits.prepareModelOutput(alloc, "skill", text, max_bytes));
}

/// Returns the owned model output and releases the result's optional notices.
/// The caller owns the returned slice.
pub fn takeModelOutput(alloc: Allocator, result: ExecuteResult) []u8 {
    return switch (result) {
        .loaded, .failure => |output| blk: {
            if (output.notice) |notice| alloc.free(@constCast(notice));
            if (output.diagnostic_notice) |notice| alloc.free(@constCast(notice));
            break :blk @constCast(output.model_output);
        },
    };
}

pub fn freeExecuteResult(alloc: Allocator, result: ExecuteResult) void {
    switch (result) {
        .loaded, .failure => |output| {
            alloc.free(@constCast(output.model_output));
            if (output.notice) |notice| alloc.free(@constCast(notice));
            if (output.diagnostic_notice) |notice| alloc.free(@constCast(notice));
        },
    }
}

fn loadVisibleSkillsForContext(alloc: Allocator, workspace_root: []const u8, skills_dir: []const u8) !skill_runtime.SkillDiscovery {
    if (io_mod.getenv("HOME") orelse homeFromSkillsDir(skills_dir)) |home| {
        return skill_runtime.loadVisibleSkills(alloc, workspace_root, home, skills_dir, test_root_policy);
    }
    return skill_runtime.loadVisibleSkills(alloc, workspace_root, null, skills_dir, test_root_policy);
}

fn homeFromSkillsDir(skills_dir: []const u8) ?[]const u8 {
    const suffix = "/.fx/skills";
    if (!std.mem.endsWith(u8, skills_dir, suffix)) return null;
    return skills_dir[0 .. skills_dir.len - suffix.len];
}

const SkillResourceRead = struct {
    bytes: []u8,
    observed_bytes: usize,
};

fn readSkillResource(
    alloc: Allocator,
    candidate: *skill_runtime.OpenedSkillCandidate,
    resource: []const u8,
    limit: context_limits.Resolved,
) !SkillResourceRead {
    return readSkillResourceWithCeiling(
        alloc,
        candidate,
        resource,
        limit,
        context_limits.emergency_ceiling_bytes,
    );
}

fn readSkillResourceWithCeiling(
    alloc: Allocator,
    candidate: *skill_runtime.OpenedSkillCandidate,
    resource: []const u8,
    limit: context_limits.Resolved,
    safety_ceiling: usize,
) !SkillResourceRead {
    if (skill_runtime.resourceIsSkillFile(resource)) {
        return readSkillResourceFile(
            alloc,
            candidate.skillFile(),
            limit,
            safety_ceiling,
        );
    }

    var file = try candidate.openResource(resource);
    defer file.close(io_mod.getIo());
    return readSkillResourceFile(alloc, &file, limit, safety_ceiling);
}

fn readSkillResourceFile(
    alloc: Allocator,
    file: *std.Io.File,
    limit: context_limits.Resolved,
    safety_ceiling: usize,
) !SkillResourceRead {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file) return error.InvalidSkillResource;
    const observed_bytes = std.math.cast(usize, stat.size) orelse return error.SkillFileLimitExceeded;
    const effective_limit = limit.effectiveBytes();
    try validateSkillResourceUtf8(file, @min(observed_bytes, safety_ceiling), observed_bytes);

    const read_len = @min(observed_bytes, @min(effective_limit +| 3, safety_ceiling));
    const bytes = try alloc.alloc(u8, read_len);
    errdefer alloc.free(bytes);
    const bytes_read = try file.readPositionalAll(io_mod.getIo(), bytes, 0);
    if (bytes_read != read_len) return error.UnexpectedEndOfFile;
    const allowed_len = context_limits.lineSafePrefixLength(bytes, effective_limit);
    if (allowed_len != bytes.len) {
        return .{
            .bytes = try alloc.realloc(bytes, allowed_len),
            .observed_bytes = observed_bytes,
        };
    }
    return .{
        .bytes = bytes,
        .observed_bytes = observed_bytes,
    };
}

fn validateSkillResourceUtf8(file: *std.Io.File, byte_count: usize, observed_bytes: usize) !void {
    var read_offset: usize = 0;
    var validator: text_utils.IncrementalUtf8Validator = .{};
    var chunk: [16 * 1024]u8 = undefined;

    while (read_offset < byte_count) {
        const wanted = @min(chunk.len, byte_count - read_offset);
        const bytes_read = try file.readPositionalAll(io_mod.getIo(), chunk[0..wanted], read_offset);
        if (bytes_read != wanted) return error.UnexpectedEndOfFile;
        validator.append(chunk[0..bytes_read]) catch return error.BinarySkillResource;
        read_offset += bytes_read;
    }
    if (validator.pending_len > 0 and byte_count < observed_bytes) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(validator.pending[0]) catch
            return error.BinarySkillResource;
        const lookahead_len = @min(sequence_len - validator.pending_len, observed_bytes - byte_count);
        var lookahead: [3]u8 = undefined;
        const bytes_read = try file.readPositionalAll(io_mod.getIo(), lookahead[0..lookahead_len], byte_count);
        if (bytes_read != lookahead_len) return error.UnexpectedEndOfFile;
        validator.append(lookahead[0..bytes_read]) catch return error.BinarySkillResource;
    }
    validator.finish() catch return error.BinarySkillResource;
}

fn formatSkillFileBlocked(
    alloc: Allocator,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeSkillFileBlockedMarker(&out.writer, resource, observed_bytes, limit);
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeSkillFileBlockedMarker(
    writer: *std.Io.Writer,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
) error{OutOfMemory}!void {
    writer.writeAll("<context_limit name=\"skill_file_bytes\" action=\"blocked_remainder\" observed_bytes=\"") catch return error.OutOfMemory;
    writer.print("{d}\" effective_bytes=\"{d}\" source=\"{s}\" resource=\"", .{
        observed_bytes,
        limit.effectiveBytes(),
        limit.source.label(),
    }) catch return error.OutOfMemory;
    model_context_encoding.writeScalar(writer, resource) catch return error.OutOfMemory;
    writer.writeAll("\" override=\"--context-limit skill_file_bytes=BYTES|off\" />") catch return error.OutOfMemory;
}

fn formatSkillFileBlockedNotice(
    alloc: Allocator,
    skill_name: []const u8,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("[context] skill resource \"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, skill_name) catch return error.OutOfMemory;
    out.writer.writeByte('/') catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, resource) catch return error.OutOfMemory;
    out.writer.print(
        "\" remainder blocked: observed={d} bytes effective={d} bytes source={s}; override with --context-limit skill_file_bytes=BYTES|off",
        .{ observed_bytes, limit.effectiveBytes(), limit.source.label() },
    ) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn formatSkillChunkNotice(
    alloc: Allocator,
    skill_name: []const u8,
    resource: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
    next_offset: usize,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll("[context] skill resource \"") catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, skill_name) catch return error.OutOfMemory;
    out.writer.writeByte('/') catch return error.OutOfMemory;
    model_context_encoding.writeScalar(&out.writer, resource) catch return error.OutOfMemory;
    out.writer.print(
        "\" truncated: observed={d} bytes effective={d} bytes source={s}; continue with offset={d} or override with --context-limit skill_chunk_bytes=BYTES|off",
        .{ observed_bytes, limit.effectiveBytes(), limit.source.label(), next_offset },
    ) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}



fn openTestSkillCandidate(
    alloc: Allocator,
    root: []const u8,
) !skill_runtime.OpenedSkillCandidate {
    const name = std.fs.path.basename(root);
    return switch (try skill_runtime.openValidatedSkillCandidate(alloc, .{
        .name = name,
        .description = "",
        .path = root,
        .source = .workspace_shared,
    })) {
        .current => |candidate| candidate,
        .missing, .name_mismatch, .skipped => error.InvalidTestSkillCandidate,
    };
}

fn expectSkillResourceRejected(alloc: Allocator, root: []const u8, resource: []const u8) !void {
    var candidate = openTestSkillCandidate(alloc, root) catch return;
    defer candidate.deinit();
    const loaded = readSkillResource(alloc, &candidate, resource, (context_limits.Values{}).skill_file_bytes) catch return;
    defer alloc.free(loaded.bytes);
    return error.TestUnexpectedResult;
}


fn createSkillSymlinkOrSkip(
    dir: std.Io.Dir,
    target_path: []const u8,
    link_path: []const u8,
    is_directory: bool,
) !void {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = is_directory }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) {
            return error.SkipZigTest;
        }
        return err;
    };
}


fn checkSkillErrorFormattingAllocationFailures(alloc: Allocator) !void {
    const missing = try formatMissingSkill(alloc, "workflow", tool_result_limits.default_max_tool_result_bytes);
    alloc.free(missing);
    const exact = try formatExactSkillNotFound(alloc, "workflow", "/tmp/skills/workflow", tool_result_limits.default_max_tool_result_bytes);
    alloc.free(exact);
    const mismatch = try formatSkillLocationMismatch(alloc, "workflow", "/tmp/skills/workflow", tool_result_limits.default_max_tool_result_bytes);
    alloc.free(mismatch);

    const duplicates = [_]skill_runtime.Skill{
        .{ .name = "workflow", .description = "A", .path = "/tmp/a/workflow", .source = .workspace_shared },
        .{ .name = "workflow", .description = "B", .path = "/tmp/b/workflow", .source = .global_fx },
    };
    const ambiguous = try formatAmbiguousSkill(alloc, &duplicates, "workflow", tool_result_limits.default_max_tool_result_bytes);
    alloc.free(ambiguous);
}

fn checkSkillLoadAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
) !void {
    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    const result = try loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        "workflow",
        null,
        null,
        0,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
    freeExecuteResult(alloc, result);
}

fn checkExplicitPromptSectionAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
    limits: context_limits.Values,
) !void {
    var discovery = try loadVisibleSkillsForContext(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    var section = try buildExplicitPromptSection(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        "$workflow",
        &.{},
        limits,
    );
    defer section.deinit(alloc);
    try std.testing.expect(section.notice != null);
    try std.testing.expect(section.diagnostic_notice != null);
}

fn setTestHome(home: ?[]const u8) !void {
    const map = try std.heap.c_allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(std.heap.c_allocator);
    if (home) |value| try map.put("HOME", value);
    io_mod.setEnvironMap(map);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) == null);
}




const CandidatePathReplacementHook = struct {
    dir: *std.Io.Dir,

    fn check(raw: *anyopaque) !void {
        const self: *CandidatePathReplacementHook = @ptrCast(@alignCast(raw));
        try self.dir.rename(
            "home/.fx/skills/workflow",
            self.dir.*,
            "home/.fx/skills/workflow-original",
            io_mod.getIo(),
        );
        try self.dir.rename(
            "home/replacement/workflow",
            self.dir.*,
            "home/.fx/skills/workflow",
            io_mod.getIo(),
        );
    }
};















