const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const context_limits = @import("../../core/config/context_limits.zig");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const result_store = @import("../../core/session/result_store.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");

const Allocator = std.mem.Allocator;
const max_results: usize = 8;

const Input = tool_args.OwnedSearchQueryInput;

const Match = struct {
    skill: *const skill_runtime.Skill,
    score: lexical_relevance.Score,
};

const Ranked = struct {
    matches: [max_results]Match = undefined,
    count: usize = 0,
    more_available: bool = false,
};

const ProjectionCheck = union(enum) {
    valid,
    invalid,
    identity_changed: usize,
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return switch (try tool_args.decodeOwnedSearchQuery(ctx.allocator, args_json, "skill_search")) {
        .failure => |body| .{ .failure = body },
        .input => |input| .{ .input = .{ .ptr = input, .deinit_fn = tool_args.destroyOwnedSearchQueryInput } },
    };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const model_output = search(
        ctx,
        &input.prepared,
        @min(ctx.max_tool_result_bytes, result_store.large_result_threshold_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "skill_search failed: {s}",
            .{@errorName(err)},
        ) },
    };
    return .{ .success = model_output };
}

pub fn search(
    ctx: tool_dispatch.DispatchContext,
    query: *const lexical_relevance.PreparedQuery,
    max_bytes: usize,
) ![]u8 {
    var discovery = try builtin_skills.loadVisibleSkillsForTool(
        ctx.allocator,
        ctx.workspace_root,
        ctx.skills_dir,
    );
    defer discovery.deinit(ctx.allocator);
    skill_runtime.traceDiagnostics("skill_search", discovery.diagnostics);
    try reportDiagnostics(ctx, discovery.diagnostics);

    return renderProjectedSearch(
        ctx.allocator,
        query,
        discovery.skills,
        ctx.context_limits.skill_description_bytes,
        max_bytes,
    );
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn reportDiagnostics(
    ctx: tool_dispatch.DispatchContext,
    diagnostics: []const skill_runtime.SkillDiagnostic,
) error{OutOfMemory}!void {
    if (diagnostics.len == 0) return;
    var notice: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer notice.deinit();
    skill_runtime.writeDiagnosticSummary(ctx.allocator, &notice.writer, diagnostics) catch
        return error.OutOfMemory;
    if (notice.written().len > 0) {
        try tool_dispatch.reportContextNotice(ctx, notice.written());
    }
}

fn rankSkills(
    query: *const lexical_relevance.PreparedQuery,
    skills: []const skill_runtime.Skill,
) Ranked {
    var ranked = Ranked{};
    for (skills) |*skill| {
        const identities = [_][]const u8{skill.name};
        const strong = [_][]const u8{skill.name};
        const weak = [_][]const u8{skill.description};
        const candidate = Match{
            .skill = skill,
            .score = lexical_relevance.score(query, &identities, &strong, &weak) orelse continue,
        };

        var insertion_index = ranked.count;
        while (insertion_index > 0 and
            lexical_relevance.order(candidate.score, ranked.matches[insertion_index - 1].score) == .gt)
        {
            insertion_index -= 1;
        }
        if (ranked.count < max_results) {
            var move_index = ranked.count;
            while (move_index > insertion_index) : (move_index -= 1) {
                ranked.matches[move_index] = ranked.matches[move_index - 1];
            }
            ranked.matches[insertion_index] = candidate;
            ranked.count += 1;
        } else {
            ranked.more_available = true;
            if (insertion_index < max_results) {
                var move_index = max_results - 1;
                while (move_index > insertion_index) : (move_index -= 1) {
                    ranked.matches[move_index] = ranked.matches[move_index - 1];
                }
                ranked.matches[insertion_index] = candidate;
            }
        }
    }
    return ranked;
}

fn renderProjectedSearch(
    alloc: Allocator,
    query: *const lexical_relevance.PreparedQuery,
    skills: []const skill_runtime.Skill,
    description_limit: context_limits.Resolved,
    max_bytes: usize,
) ![]u8 {
    var ranked = rankSkills(query, skills);
    var retained_count = ranked.count;
    var projection_omitted = false;

    while (true) {
        const more_available = ranked.more_available or projection_omitted;
        const raw = renderRawSearch(
            alloc,
            ranked.matches[0..retained_count],
            description_limit.effectiveBytes(),
            more_available,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        defer alloc.free(raw);

        const projected = @constCast(try tool_result_limits.prepareModelOutput(
            alloc,
            "skill_search",
            raw,
            max_bytes,
        ));
        errdefer alloc.free(projected);
        const check = try checkProjection(
            alloc,
            projected,
            ranked.matches[0..retained_count],
            more_available,
        );
        switch (check) {
            .valid => {
                const second = try tool_result_limits.prepareModelOutput(
                    alloc,
                    "skill_search",
                    projected,
                    max_bytes,
                );
                defer alloc.free(@constCast(second));
                if (std.mem.eql(u8, projected, second)) return projected;
            },
            .invalid, .identity_changed => {},
        }

        const remove_index = switch (check) {
            .identity_changed => |index| index,
            .valid, .invalid => if (retained_count > 0) retained_count - 1 else {
                alloc.free(projected);
                return error.SkillSearchResultLimitTooSmall;
            },
        };
        alloc.free(projected);
        var index = remove_index;
        while (index + 1 < retained_count) : (index += 1) {
            ranked.matches[index] = ranked.matches[index + 1];
        }
        retained_count -= 1;
        projection_omitted = true;
    }
}

fn renderRawSearch(
    alloc: Allocator,
    matches: []const Match,
    description_limit: usize,
    more_available: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"skills\":[");
    for (matches, 0..) |match, index| {
        if (index > 0) try out.writer.writeByte(',');
        const description_end = context_limits.utf8PrefixLength(
            match.skill.description,
            description_limit,
        );
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(match.skill.name, .{}, &out.writer);
        try out.writer.writeAll(",\"description\":");
        try std.json.Stringify.value(match.skill.description[0..description_end], .{}, &out.writer);
        try out.writer.writeAll(",\"location\":");
        try std.json.Stringify.value(match.skill.path, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.print("],\"count\":{d},\"more_available\":{s}}}", .{
        matches.len,
        if (more_available) "true" else "false",
    });
    return try out.toOwnedSlice();
}

fn checkProjection(
    alloc: Allocator,
    projected: []const u8,
    matches: []const Match,
    more_available: bool,
) !ProjectionCheck {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, projected, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .invalid,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .invalid;

    const skills_value = parsed.value.object.get("skills") orelse return .invalid;
    const count_value = parsed.value.object.get("count") orelse return .invalid;
    const more_value = parsed.value.object.get("more_available") orelse return .invalid;
    if (skills_value != .array or
        count_value != .integer or
        count_value.integer < 0 or
        more_value != .bool or
        more_value.bool != more_available or
        skills_value.array.items.len != matches.len)
    {
        return .invalid;
    }
    const count = std.math.cast(usize, count_value.integer) orelse return .invalid;
    if (count != matches.len) return .invalid;

    for (skills_value.array.items, matches, 0..) |value, match, index| {
        if (value != .object) return .invalid;
        const name = value.object.get("name") orelse return .invalid;
        const description = value.object.get("description") orelse return .invalid;
        const location = value.object.get("location") orelse return .invalid;
        if (name != .string or description != .string or location != .string) return .invalid;
        if (!std.mem.eql(u8, name.string, match.skill.name) or
            !std.mem.eql(u8, location.string, match.skill.path))
        {
            return .{ .identity_changed = index };
        }
    }
    return .valid;
}







