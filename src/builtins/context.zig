const std = @import("std");
const background_runtime = @import("../core/background/background_runtime.zig");
const change_tracker = @import("../core/workspace/change_tracker.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const host = @import("../core/hosts/host.zig");
const host_target = @import("../core/hosts/target.zig");
const io_mod = @import("../core/shared/io.zig");
const model_context_encoding = @import("../core/shared/model_context_encoding.zig");
const pathing = @import("../core/workspace/pathing.zig");
const process_supervisor = @import("../core/background/process_supervisor.zig");
const session_runtime = @import("../core/session/session.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const types = @import("../core/shared/types.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const context_limits = @import("../core/config/context_limits.zig");
const prompt_policy_contract = @import("../core/config/prompt_policy.zig");

const Allocator = std.mem.Allocator;
const BackgroundRuntime = background_runtime.BackgroundRuntime;
const ChatMessage = types.ChatMessage;
const SessionRuntime = session_runtime.SessionRuntime;
const trim_chars = " \t\r\n";
const omission_source_prefix_bytes: usize = 256;
const retained_omission_count = context_contract.Limits.project_omission_records;

const InitialContextInput = context_contract.InitialContextInput;
const LaterContextInput = context_contract.LaterContextInput;
const ProviderContext = context_contract.ProviderContext;
const StaticContextInput = context_contract.StaticContextInput;
const TransientContextInput = context_contract.TransientContextInput;
const workspace_access = @import("../core/workspace/workspace_access.zig");
const sort_utils = @import("../core/shared/sort_utils.zig");

pub const gateway_system_prompt = @embedFile("system_prompt.md");

pub fn modelPromptOverlay(model: []const u8) ?[]const u8 {
    _ = model;
    return null;
}

pub const prompt_policy = prompt_policy_contract.Policy{
    .system_prompt = gateway_system_prompt,
    .model_prompt_overlay_fn = modelPromptOverlay,
};

pub const provider = context_contract.Provider{
    .id = "builtin.default_context",
    .gather_project_context_fn = gatherProjectContext,
    .select_applicable_project_context_fn = selectApplicableProjectContext,
    .append_static_fn = appendStatic,
    .append_transient_fn = appendTransient,
};

const project_instruction_guidance =
    "Direct user instructions take precedence over project instructions. " ++
    "When project instructions conflict, follow the narrowest applicable project scope.";

const CandidateClass = enum {
    ancestor,
    target,
};

const RuleCandidate = struct {
    source: []const u8,
    scope: []const u8,
    class: CandidateClass,
    body: ?[]const u8 = null,
    observed_bytes: usize = 0,
    distance: usize = std.math.maxInt(usize),
};

const LoadedRule = struct {
    source: []const u8,
    body: []const u8,
    observed_bytes: usize,
};

const RuleBody = struct {
    text: []const u8,
    observed_bytes: usize,
};

const RenderedRule = struct {
    source: []const u8,
    start: usize,
    end: usize,
    is_global: bool = false,
};

const RuleLoad = union(enum) {
    missing,
    blank,
    body: RuleBody,
    omitted: context_contract.OmissionReason,
};

const SelectionOptions = struct {
    workspace_root: []const u8,
    targets: []const context_contract.ApplicableTarget,
    delivered_sources: []const []const u8 = &.{},
    evaluated_endpoints: []const []const u8 = &.{},
    initial_omissions: []const context_contract.ContextOmissionInput = &.{},
    initial_omission_summary: ?context_contract.ContextOmissionSummary = null,
    home: ?[]const u8 = null,
    initial: bool,
    load_project_instruction_files: bool = true,
    context_limits: context_limits.Values = .{},
};

const SelectionScratch = struct {
    arena: Allocator,
    candidates: std.ArrayList(RuleCandidate) = .empty,
    ranking_endpoints: std.ArrayList([]const u8) = .empty,
    delivered_sources: std.ArrayList([]const u8) = .empty,
    evaluated_endpoints: std.ArrayList([]const u8) = .empty,
    omissions: std.ArrayList(context_contract.ContextOmissionInput) = .empty,
    notices: std.ArrayList([]const u8) = .empty,
    omission_summary: context_contract.ContextOmissionSummaryBuilder = .{},

    fn addDelivered(self: *SelectionScratch, source: []const u8) !void {
        if (!containsString(self.delivered_sources.items, source)) {
            try self.delivered_sources.append(self.arena, source);
        }
    }

    fn addEvaluated(self: *SelectionScratch, endpoint: []const u8) !void {
        if (!containsString(self.evaluated_endpoints.items, endpoint)) {
            try self.evaluated_endpoints.append(self.arena, endpoint);
        }
    }

    fn addRankingEndpoint(self: *SelectionScratch, endpoint: []const u8) !void {
        if (!containsString(self.ranking_endpoints.items, endpoint)) {
            try self.ranking_endpoints.append(self.arena, endpoint);
        }
    }

    fn addOmission(self: *SelectionScratch, source: []const u8, reason: context_contract.OmissionReason) !void {
        for (self.omissions.items) |omission| {
            if (omission.reason == reason and std.mem.eql(u8, omission.source, source)) return;
        }
        if (self.omissions.items.len == retained_omission_count) {
            self.omission_summary.add(source, reason);
            return;
        }
        try self.omissions.append(self.arena, .{ .source = source, .reason = reason });
        logBoundedOmission(reason, source);
        if (reason == .home_outside_workspace) return;

        var notice: std.Io.Writer.Allocating = .init(self.arena);
        defer notice.deinit();
        try notice.writer.print("[context] project instructions action=omitted reason={s} source=\"", .{reason.label()});
        const source_truncated = try writeBoundedOmissionSource(&notice.writer, source);
        try notice.writer.writeAll("\"");
        if (source_truncated) {
            const digest = omissionSourceDigest(source);
            try notice.writer.print(" source_bytes={d} source_sha256={s}", .{ source.len, digest });
        }
        try notice.writer.writeAll("; repair=");
        try writeOmissionRepair(&notice.writer, reason);
        try self.addNotice(try notice.toOwnedSlice());
    }

    fn addNotice(self: *SelectionScratch, notice: []const u8) !void {
        try self.notices.append(self.arena, notice);
    }
};

fn loadsProjectInstructionFiles() bool {
    return !host_target.is_wasm;
}

fn gatherProjectContext(alloc: Allocator, input: InitialContextInput) context_contract.ProviderError!ProviderContext {
    return gatherProjectContextWithHome(alloc, input, io_mod.getenv("HOME"));
}

fn gatherProjectContextWithHome(
    alloc: Allocator,
    input: InitialContextInput,
    home: ?[]const u8,
) context_contract.ProviderError!ProviderContext {
    return selectProjectContext(alloc, .{
        .workspace_root = input.workspace_root,
        .targets = input.targets,
        .initial_omissions = input.omissions,
        .initial_omission_summary = input.omission_summary,
        .home = home,
        .initial = true,
        .load_project_instruction_files = loadsProjectInstructionFiles(),
        .context_limits = input.context_limits,
    });
}

fn selectApplicableProjectContext(alloc: Allocator, input: LaterContextInput) context_contract.ProviderError!ProviderContext {
    return selectProjectContext(alloc, .{
        .workspace_root = input.workspace_root,
        .targets = input.targets,
        .delivered_sources = input.delivered_sources,
        .evaluated_endpoints = input.evaluated_endpoints,
        .initial = false,
        .load_project_instruction_files = loadsProjectInstructionFiles(),
        .context_limits = input.context_limits,
    });
}

fn selectProjectContext(alloc: Allocator, options: SelectionOptions) context_contract.ProviderError!ProviderContext {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: SelectionScratch = .{ .arena = arena };

    for (options.initial_omissions) |omission| {
        try scratch.addOmission(omission.source, omission.reason);
    }
    if (options.initial_omission_summary) |summary| scratch.omission_summary.merge(summary);

    var global_rule: ?LoadedRule = null;
    var global_source_path: ?[]const u8 = null;
    var project_rule: ?LoadedRule = null;

    if (options.initial) {
        try scratch.addEvaluated(options.workspace_root);
        try scratch.addRankingEndpoint(options.workspace_root);
    }

    if (options.load_project_instruction_files) {
        if (options.initial) {
            if (options.home) |home| {
                const canonical_home: ?[]u8 = io_mod.realpathAlloc(arena, home) catch |err| blk: {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    try scratch.addOmission(home, .home_unavailable);
                    break :blk null;
                };
                if (canonical_home) |home_root| {
                    global_source_path = try std.fs.path.join(arena, &.{ home_root, ".fx", "AGENTS.md" });
                    global_rule = try loadRuleForSelection(arena, &scratch, global_source_path.?, options.context_limits.project_instruction_file_bytes);
                    if (pathing.pathInside(home_root, options.workspace_root)) {
                        try collectLaunchAncestorCandidates(arena, &scratch, home_root, options.workspace_root, options.delivered_sources);
                    } else {
                        try scratch.addOmission(options.workspace_root, .home_outside_workspace);
                    }
                }
            } else {
                try scratch.addOmission("HOME", .home_unavailable);
            }

            if (std.fs.path.isAbsolute(options.workspace_root)) {
                const project_source = try std.fs.path.join(arena, &.{ options.workspace_root, "AGENTS.md" });
                if (global_source_path == null or
                    !std.mem.eql(u8, global_source_path.?, project_source))
                {
                    project_rule = try loadRuleForSelection(arena, &scratch, project_source, options.context_limits.project_instruction_file_bytes);
                }
            } else {
                try scratch.addOmission(options.workspace_root, .unsafe_target);
            }
        }

        for (options.targets) |target| {
            try collectTargetCandidates(arena, &scratch, options, target);
        }
    }

    var usable: std.ArrayList(*RuleCandidate) = .empty;
    for (scratch.candidates.items) |*candidate| {
        switch (try loadRule(arena, candidate.source, options.context_limits.project_instruction_file_bytes)) {
            .body => |body| {
                candidate.body = body.text;
                candidate.observed_bytes = body.observed_bytes;
                candidate.distance = minimumDistance(candidate.scope, scratch.ranking_endpoints.items);
                try usable.append(arena, candidate);
            },
            .missing, .blank => {},
            .omitted => |reason| try scratch.addOmission(candidate.source, reason),
        }
    }

    sort_utils.sort(*RuleCandidate, usable.items, {}, rankCandidateLessThan);
    const selected_count = @min(usable.items.len, context_contract.Limits.scoped_rules);
    for (usable.items, 0..) |candidate, index| {
        if (index < selected_count) {
            try scratch.addDelivered(candidate.source);
        } else {
            try scratch.addOmission(candidate.source, .selection_cap);
        }
    }
    const selected = usable.items[0..selected_count];
    sort_utils.sort(*RuleCandidate, selected, {}, renderCandidateLessThan);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var rendered_rules: std.ArrayList(RenderedRule) = .empty;
    defer rendered_rules.deinit(arena);

    if (global_rule != null or project_rule != null or selected.len > 0) {
        try appendSection(&out, "project-instructions-guidance", project_instruction_guidance);
    }
    if (global_rule) |rule| {
        const start = out.written().len;
        try appendSectionFrom(&out, "global-rules", rule.source, rule.body);
        try appendProjectInstructionLimitMarker(&out, &scratch, rule.source, rule.observed_bytes, options.context_limits.project_instruction_file_bytes);
        try rendered_rules.append(arena, .{ .source = rule.source, .start = start, .end = out.written().len, .is_global = true });
    }
    for (selected) |candidate| {
        if (candidate.class == .ancestor) {
            const start = out.written().len;
            try appendScopedSectionFrom(&out, candidate.source, candidate.scope, candidate.body.?);
            try appendProjectInstructionLimitMarker(&out, &scratch, candidate.source, candidate.observed_bytes, options.context_limits.project_instruction_file_bytes);
            try rendered_rules.append(arena, .{ .source = candidate.source, .start = start, .end = out.written().len });
        }
    }
    if (project_rule) |rule| {
        const start = out.written().len;
        try appendSectionFrom(&out, "project-rules", rule.source, rule.body);
        try appendProjectInstructionLimitMarker(&out, &scratch, rule.source, rule.observed_bytes, options.context_limits.project_instruction_file_bytes);
        try rendered_rules.append(arena, .{ .source = rule.source, .start = start, .end = out.written().len });
    }
    for (selected) |candidate| {
        if (candidate.class == .target) {
            const start = out.written().len;
            try appendScopedSectionFrom(&out, candidate.source, candidate.scope, candidate.body.?);
            try appendProjectInstructionLimitMarker(&out, &scratch, candidate.source, candidate.observed_bytes, options.context_limits.project_instruction_file_bytes);
            try rendered_rules.append(arena, .{ .source = candidate.source, .start = start, .end = out.written().len });
        }
    }

    sort_utils.sort(context_contract.ContextOmissionInput, scratch.omissions.items, {}, omissionLessThan);
    for (scratch.omissions.items) |omission| {
        try appendOmission(&out, omission);
    }
    if (scratch.omission_summary.omitted_count > 0) try appendOmissionSummary(&out, &scratch);
    try appendOmissionSummaryNotice(&scratch);
    sort_utils.sort([]const u8, scratch.delivered_sources.items, {}, stringLessThan);
    sort_utils.sort([]const u8, scratch.evaluated_endpoints.items, {}, stringLessThan);

    var result: ProviderContext = .{};
    errdefer result.deinit(alloc);
    if (out.written().len > 0) {
        const full = try out.toOwnedSlice();
        if (full.len > options.context_limits.project_instructions_total_bytes.effectiveBytes()) {
            defer alloc.free(full);
            result.content = try capProjectInstructionsTotal(
                alloc,
                arena,
                &scratch,
                full,
                rendered_rules.items,
                options.context_limits.project_instructions_total_bytes,
            );
        } else {
            result.content = full;
        }
    }
    result.delivered_sources = try dupeOwnedStringSlice(alloc, scratch.delivered_sources.items);
    result.evaluated_endpoints = try dupeOwnedStringSlice(alloc, scratch.evaluated_endpoints.items);
    result.notices = try dupeOwnedStringSlice(alloc, scratch.notices.items);
    return result;
}

fn loadRuleForSelection(
    arena: Allocator,
    scratch: *SelectionScratch,
    source: []const u8,
    limit: context_limits.Resolved,
) !?LoadedRule {
    switch (try loadRule(arena, source, limit)) {
        .body => |body| {
            try scratch.addDelivered(source);
            return .{ .source = source, .body = body.text, .observed_bytes = body.observed_bytes };
        },
        .missing, .blank => return null,
        .omitted => |reason| {
            try scratch.addOmission(source, reason);
            return null;
        },
    }
}

fn collectLaunchAncestorCandidates(
    arena: Allocator,
    scratch: *SelectionScratch,
    home: []const u8,
    workspace_root: []const u8,
    prior_delivered: []const []const u8,
) !void {
    var current = std.fs.path.dirname(workspace_root);
    while (current) |scope| : (current = std.fs.path.dirname(scope)) {
        if (std.mem.eql(u8, scope, home)) break;
        if (!pathing.pathInside(home, scope)) break;
        try appendRuleCandidate(arena, scratch, scope, .ancestor, prior_delivered);
    }
}

fn collectTargetCandidates(
    arena: Allocator,
    scratch: *SelectionScratch,
    options: SelectionOptions,
    target: context_contract.ApplicableTarget,
) !void {
    const raw_endpoint = switch (target.kind) {
        .file => std.fs.path.dirname(target.path) orelse target.path,
        .directory => target.path,
    };
    const endpoint = if (raw_endpoint.len > 0) raw_endpoint else target.path;
    if (containsString(options.evaluated_endpoints, endpoint) or
        containsString(scratch.evaluated_endpoints.items, endpoint)) return;

    try scratch.addEvaluated(endpoint);
    if (!std.fs.path.isAbsolute(endpoint)) {
        try scratch.addOmission(if (target.path.len > 0) target.path else "(empty target)", .unsafe_target);
        return;
    }
    if (!pathing.pathInside(options.workspace_root, endpoint)) return;

    try scratch.addRankingEndpoint(endpoint);
    var current: ?[]const u8 = endpoint;
    while (current) |scope| : (current = std.fs.path.dirname(scope)) {
        if (std.mem.eql(u8, scope, options.workspace_root)) break;
        if (!pathing.pathInside(options.workspace_root, scope)) break;
        try appendRuleCandidate(arena, scratch, scope, .target, options.delivered_sources);
    }
}

fn appendRuleCandidate(
    arena: Allocator,
    scratch: *SelectionScratch,
    scope: []const u8,
    class: CandidateClass,
    prior_delivered: []const []const u8,
) !void {
    const source = try std.fs.path.join(arena, &.{ scope, "AGENTS.md" });
    if (containsString(prior_delivered, source) or containsString(scratch.delivered_sources.items, source)) return;
    for (scratch.candidates.items) |candidate| {
        if (std.mem.eql(u8, candidate.source, source)) return;
    }
    try scratch.candidates.append(arena, .{
        .source = source,
        .scope = scope,
        .class = class,
    });
}

fn loadRule(arena: Allocator, path: []const u8, limit: context_limits.Resolved) Allocator.Error!RuleLoad {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir => .missing,
            else => .{ .omitted = .unreadable },
        };
    };
    if (stat.kind != .file and stat.kind != .sym_link) return .{ .omitted = .non_regular };

    var file = if (stat.kind == .sym_link) blk: {
        const logical_parent = std.fs.path.dirname(path) orelse return .{ .omitted = .symlink };
        const authority = io_mod.realpathAlloc(arena, logical_parent) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .omitted = .symlink };
        };
        const canonical_target = io_mod.realpathAlloc(arena, path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .omitted = .symlink };
        };
        if (!pathing.pathInside(authority, canonical_target)) return .{ .omitted = .symlink };

        const target_parent = std.fs.path.dirname(canonical_target) orelse return .{ .omitted = .symlink };
        const target_name = std.fs.path.basename(canonical_target);
        if (target_name.len == 0) return .{ .omitted = .symlink };
        var parent_dir = io_mod.openDirAbsoluteNoFollow(target_parent, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .omitted = .symlink };
        };
        defer parent_dir.close(io_mod.getIo());
        break :blk parent_dir.openFile(io_mod.getIo(), target_name, .{
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .omitted = .symlink };
        };
    } else std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| {
        return switch (err) {
            error.FileNotFound, error.NotDir => .missing,
            error.SymLinkLoop => .{ .omitted = .symlink },
            error.IsDir => .{ .omitted = .non_regular },
            else => .{ .omitted = .unreadable },
        };
    };
    defer file.close(io_mod.getIo());

    const opened_stat = file.stat(io_mod.getIo()) catch return .{ .omitted = .unreadable };
    if (opened_stat.kind != .file) return .{ .omitted = if (stat.kind == .sym_link) .symlink else .non_regular };
    const observed_bytes = std.math.cast(usize, opened_stat.size) orelse return .{ .omitted = .oversized };
    if (observed_bytes > context_limits.emergency_ceiling_bytes) return .{ .omitted = .oversized };

    const has_content = validateRuleUtf8(&file, observed_bytes) catch
        return .{ .omitted = .unreadable };
    if (!has_content) return .blank;
    const read_len = @min(
        observed_bytes,
        @min(limit.effectiveBytes() +| 3, context_limits.emergency_ceiling_bytes),
    );
    const content = try arena.alloc(u8, read_len);
    const bytes_read = file.readPositionalAll(io_mod.getIo(), content, 0) catch
        return .{ .omitted = .unreadable };
    if (bytes_read != read_len) return .{ .omitted = .unreadable };
    const prefix_len = context_limits.lineSafePrefixLength(content, limit.effectiveBytes());
    const trimmed = std.mem.trim(u8, content[0..prefix_len], trim_chars);
    return .{ .body = .{ .text = trimmed, .observed_bytes = observed_bytes } };
}

fn validateRuleUtf8(file: *std.Io.File, byte_count: usize) !bool {
    var read_offset: usize = 0;
    var has_content = false;
    var validator: text_utils.IncrementalUtf8Validator = .{};
    var chunk: [16 * 1024]u8 = undefined;

    while (read_offset < byte_count) {
        const wanted = @min(chunk.len, byte_count - read_offset);
        const bytes_read = try file.readPositionalAll(io_mod.getIo(), chunk[0..wanted], read_offset);
        if (bytes_read != wanted) return error.UnexpectedEndOfFile;
        if (std.mem.trim(u8, chunk[0..bytes_read], trim_chars).len != 0) has_content = true;
        try validator.append(chunk[0..bytes_read]);
        read_offset += bytes_read;
    }
    try validator.finish();
    return has_content;
}

fn minimumDistance(scope: []const u8, endpoints: []const []const u8) usize {
    var minimum: usize = std.math.maxInt(usize);
    const scope_depth = pathDepth(scope);
    for (endpoints) |endpoint| {
        if (!pathing.pathInside(scope, endpoint)) continue;
        minimum = @min(minimum, pathDepth(endpoint) - scope_depth);
    }
    return minimum;
}

fn pathDepth(path: []const u8) usize {
    var count: usize = 0;
    var in_component = false;
    for (path) |byte| {
        if (byte == std.fs.path.sep) {
            in_component = false;
        } else if (!in_component) {
            count += 1;
            in_component = true;
        }
    }
    return count;
}

fn rankCandidateLessThan(_: void, lhs: *RuleCandidate, rhs: *RuleCandidate) bool {
    if (lhs.distance != rhs.distance) return lhs.distance < rhs.distance;
    const lhs_depth = pathDepth(lhs.scope);
    const rhs_depth = pathDepth(rhs.scope);
    if (lhs_depth != rhs_depth) return lhs_depth > rhs_depth;
    return std.mem.lessThan(u8, lhs.source, rhs.source);
}

fn renderCandidateLessThan(_: void, lhs: *RuleCandidate, rhs: *RuleCandidate) bool {
    const lhs_depth = pathDepth(lhs.scope);
    const rhs_depth = pathDepth(rhs.scope);
    if (lhs_depth != rhs_depth) return lhs_depth < rhs_depth;
    return std.mem.lessThan(u8, lhs.source, rhs.source);
}

fn omissionLessThan(_: void, lhs: context_contract.ContextOmissionInput, rhs: context_contract.ContextOmissionInput) bool {
    if (!std.mem.eql(u8, lhs.source, rhs.source)) return std.mem.lessThan(u8, lhs.source, rhs.source);
    return @intFromEnum(lhs.reason) < @intFromEnum(rhs.reason);
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn containsString(strings: []const []const u8, value: []const u8) bool {
    for (strings) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn dupeOwnedStringSlice(alloc: Allocator, strings: []const []const u8) Allocator.Error![][]u8 {
    if (strings.len == 0) return &.{};
    const owned = try alloc.alloc([]u8, strings.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |string| alloc.free(string);
        alloc.free(owned);
    }
    for (strings, 0..) |string, index| {
        owned[index] = try alloc.dupe(u8, string);
        initialized += 1;
    }
    return owned;
}

fn appendSection(out: *std.Io.Writer.Allocating, tag: []const u8, body: []const u8) !void {
    if (body.len == 0) return;
    if (out.written().len > 0) try out.writer.writeAll("\n\n");
    try out.writer.print("<{s}>\n{s}\n</{s}>", .{ tag, body, tag });
}

fn appendSectionFrom(out: *std.Io.Writer.Allocating, tag: []const u8, from_path: []const u8, body: []const u8) !void {
    if (body.len == 0) return;
    if (out.written().len > 0) try out.writer.writeAll("\n\n");
    try out.writer.print("<{s} from=\"", .{tag});
    try model_context_encoding.writeScalar(&out.writer, from_path);
    try out.writer.print("\">\n{s}\n</{s}>", .{ body, tag });
}

fn appendScopedSectionFrom(out: *std.Io.Writer.Allocating, from_path: []const u8, scope: []const u8, body: []const u8) !void {
    if (body.len == 0) return;
    if (out.written().len > 0) try out.writer.writeAll("\n\n");
    try out.writer.writeAll("<scoped-rules from=\"");
    try model_context_encoding.writeScalar(&out.writer, from_path);
    try out.writer.writeAll("\" scope=\"");
    try model_context_encoding.writeScalar(&out.writer, scope);
    try out.writer.print("\">\n{s}\n</scoped-rules>", .{body});
}

fn appendOmission(out: *std.Io.Writer.Allocating, omission: context_contract.ContextOmissionInput) !void {
    if (out.written().len > 0) try out.writer.writeAll("\n\n");
    try out.writer.writeAll("<project-rules-omitted from=\"");
    const source_truncated = try writeBoundedOmissionSource(&out.writer, omission.source);
    try out.writer.writeAll("\"");
    if (source_truncated) {
        const digest = omissionSourceDigest(omission.source);
        try out.writer.print(
            " source_bytes=\"{d}\" source_sha256=\"{s}\"",
            .{ omission.source.len, digest },
        );
    }
    try out.writer.writeAll(" reason=\"");
    try model_context_encoding.writeScalar(&out.writer, omission.reason.label());
    try out.writer.writeAll("\" />");
}

fn appendOmissionSummary(out: *std.Io.Writer.Allocating, scratch: *const SelectionScratch) !void {
    if (out.written().len > 0) try out.writer.writeAll("\n\n");
    try out.writer.print(
        "<project-rules-omitted-summary omitted_count=\"{d}\" reasons=\"",
        .{scratch.omission_summary.omitted_count},
    );
    try writeOmissionReasonCounts(&out.writer, scratch.omission_summary.reason_counts, false);
    const digest = omissionSummaryDigest(scratch);
    try out.writer.print("\" records_sha256=\"{s}\" />", .{digest});
}

fn appendOmissionSummaryNotice(scratch: *SelectionScratch) !void {
    if (scratch.omission_summary.omitted_count == 0) return;
    const digest = omissionSummaryDigest(scratch);
    debug_trace.logf(
        "context",
        "project_rules_omitted_summary omitted_count={d} records_sha256={s}",
        .{ scratch.omission_summary.omitted_count, digest },
    );

    const hidden_count = scratch.omission_summary.reason_counts[@intFromEnum(context_contract.OmissionReason.home_outside_workspace)];
    const actionable_count = scratch.omission_summary.omitted_count - hidden_count;
    if (actionable_count == 0) return;

    var notice: std.Io.Writer.Allocating = .init(scratch.arena);
    defer notice.deinit();
    try notice.writer.print(
        "[context] project instructions action=omitted summary: {d} additional records; reasons=\"",
        .{actionable_count},
    );
    try writeOmissionReasonCounts(&notice.writer, scratch.omission_summary.reason_counts, true);
    try notice.writer.print("\" records_sha256={s}; repair=review the listed omission reasons", .{digest});
    try scratch.addNotice(try notice.toOwnedSlice());
}

fn writeOmissionReasonCounts(
    writer: *std.Io.Writer,
    counts: [std.meta.fields(context_contract.OmissionReason).len]usize,
    actionable_only: bool,
) !void {
    var wrote_any = false;
    for (counts, 0..) |count, index| {
        const reason: context_contract.OmissionReason = @enumFromInt(index);
        if (count == 0 or (actionable_only and reason == .home_outside_workspace)) continue;
        if (wrote_any) try writer.writeAll(", ");
        try writer.print("{s}:{d}", .{ reason.label(), count });
        wrote_any = true;
    }
}

fn omissionSummaryDigest(scratch: *const SelectionScratch) [24]u8 {
    const summary = scratch.omission_summary.finish().?;
    return std.fmt.bytesToHex(summary.digest[0..12].*, .lower);
}

fn logBoundedOmission(reason: context_contract.OmissionReason, source: []const u8) void {
    if (source.len <= omission_source_prefix_bytes) {
        debug_trace.logf(
            "context",
            "project_rules_omitted reason={s} source=\"{f}\"",
            .{ reason.label(), std.zig.fmtString(source) },
        );
        return;
    }
    const prefix_len = context_limits.utf8PrefixLength(source, omission_source_prefix_bytes);
    const digest = omissionSourceDigest(source);
    debug_trace.logf(
        "context",
        "project_rules_omitted reason={s} source=\"{f}...\" source_bytes={d} source_sha256={s}",
        .{ reason.label(), std.zig.fmtString(source[0..prefix_len]), source.len, digest },
    );
}

fn writeBoundedOmissionSource(writer: *std.Io.Writer, source: []const u8) !bool {
    if (source.len <= omission_source_prefix_bytes) {
        try model_context_encoding.writeScalar(writer, source);
        return false;
    }
    const prefix_len = context_limits.utf8PrefixLength(source, omission_source_prefix_bytes);
    try model_context_encoding.writeScalar(writer, source[0..prefix_len]);
    try writer.writeAll("...");
    return true;
}

fn omissionSourceDigest(source: []const u8) [24]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.fmt.bytesToHex(digest[0..12].*, .lower);
}

fn writeOmissionRepair(writer: *std.Io.Writer, reason: context_contract.OmissionReason) !void {
    switch (reason) {
        .home_unavailable => try writer.writeAll("set HOME to an accessible directory"),
        .home_outside_workspace => try writer.writeAll("open a workspace below HOME"),
        .unsafe_target => try writer.writeAll("use an absolute local target"),
        .unreadable => try writer.writeAll("make the rule file readable UTF-8"),
        .oversized => try writer.print(
            "keep the rule file smaller than {d} bytes",
            .{context_limits.emergency_ceiling_bytes},
        ),
        .non_regular => try writer.writeAll("replace the source with a regular file"),
        .symlink => try writer.writeAll("replace the symlink with a regular file"),
        .selection_cap => try writer.writeAll("reduce applicable AGENTS.md files"),
    }
}

fn appendProjectInstructionLimitMarker(
    out: *std.Io.Writer.Allocating,
    scratch: *SelectionScratch,
    source: []const u8,
    observed_bytes: usize,
    limit: context_limits.Resolved,
) !void {
    if (observed_bytes <= limit.effectiveBytes()) return;
    if (out.written().len > 0) try out.writer.writeAll("\n\n");
    try out.writer.writeAll("<context_limit name=\"project_instruction_file_bytes\" action=\"truncated\" source_file=\"");
    try model_context_encoding.writeScalar(&out.writer, source);
    try out.writer.print(
        "\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" override=\"--context-limit project_instruction_file_bytes=BYTES|off\" />",
        .{ observed_bytes, limit.effectiveBytes(), limit.source.label() },
    );
    var notice: std.Io.Writer.Allocating = .init(scratch.arena);
    defer notice.deinit();
    try notice.writer.writeAll("[context] project instruction file \"");
    try model_context_encoding.writeScalar(&notice.writer, source);
    try notice.writer.print(
        "\" truncated: observed={d} bytes effective={d} bytes source={s}; override with --context-limit project_instruction_file_bytes=BYTES|off",
        .{ observed_bytes, limit.effectiveBytes(), limit.source.label() },
    );
    try scratch.addNotice(try notice.toOwnedSlice());
}

fn capProjectInstructionsTotal(
    alloc: Allocator,
    arena: Allocator,
    scratch: *SelectionScratch,
    full: []const u8,
    rendered_rules: []const RenderedRule,
    limit: context_limits.Resolved,
) ![]u8 {
    const consequence_start = if (rendered_rules.len > 0) rendered_rules[rendered_rules.len - 1].end else 0;
    const observed_bytes = consequence_start;
    const effective_limit = limit.effectiveBytes();
    if (observed_bytes <= effective_limit) return alloc.dupe(u8, full);

    const retained = try arena.alloc(bool, rendered_rules.len);
    @memset(retained, false);
    const preamble_end = if (rendered_rules.len > 0) rendered_rules[0].start else 0;
    var retained_bytes: usize = 0;
    const include_preamble = preamble_end > 0 and preamble_end <= effective_limit;

    if (preamble_end == 0 or include_preamble) {
        for (rendered_rules, 0..) |rule, index| {
            if (!rule.is_global) continue;
            if (projectRuleFitsTotalLimit(
                effective_limit,
                if (include_preamble) preamble_end else 0,
                retained_bytes,
                rule.end - rule.start,
            )) {
                retained[index] = true;
                retained_bytes += rule.end - rule.start;
            }
            break;
        }
        if (rendered_rules.len > 0) {
            const closest_index = rendered_rules.len - 1;
            if (!retained[closest_index]) {
                const closest = rendered_rules[closest_index];
                if (projectRuleFitsTotalLimit(
                    effective_limit,
                    if (include_preamble) preamble_end else 0,
                    retained_bytes,
                    closest.end - closest.start,
                )) {
                    retained[closest_index] = true;
                    retained_bytes += closest.end - closest.start;
                }
            }
        }
        for (rendered_rules, 0..) |rule, index| {
            if (retained[index]) continue;
            if (!projectRuleFitsTotalLimit(
                effective_limit,
                if (include_preamble) preamble_end else 0,
                retained_bytes,
                rule.end - rule.start,
            )) {
                continue;
            }
            retained[index] = true;
            retained_bytes += rule.end - rule.start;
        }
    }

    var omitted_names: std.Io.Writer.Allocating = .init(arena);
    defer omitted_names.deinit();
    var omitted_count: usize = 0;
    for (rendered_rules, retained) |rule, keep| {
        if (keep) continue;
        if (omitted_count > 0) try omitted_names.writer.writeAll(", ");
        try model_context_encoding.writeScalar(&omitted_names.writer, rule.source);
        omitted_count += 1;
    }

    var capped: std.Io.Writer.Allocating = .init(alloc);
    defer capped.deinit();
    if (include_preamble) {
        try capped.writer.writeAll(full[0..preamble_end]);
    }
    for (rendered_rules, retained) |rule, keep| {
        if (!keep) continue;
        try capped.writer.writeAll(full[rule.start..rule.end]);
    }
    const prior_consequences = std.mem.trimStart(u8, full[consequence_start..], "\r\n");
    if (prior_consequences.len > 0) {
        if (capped.written().len > 0) try capped.writer.writeAll("\n\n");
        try capped.writer.writeAll(prior_consequences);
    }
    const marker = try projectInstructionsLimitMarker(alloc, observed_bytes, effective_limit, limit.source.label(), omitted_count);
    defer alloc.free(marker);
    if (capped.written().len > 0) try capped.writer.writeAll("\n\n");
    try capped.writer.writeAll(marker);

    try scratch.addNotice(try std.fmt.allocPrint(
        arena,
        "[context] project instructions omitted {d} source(s) ({s}): observed={d} bytes effective={d} bytes source={s}; override with --context-limit project_instructions_total_bytes=BYTES|off",
        .{ omitted_count, omitted_names.written(), observed_bytes, effective_limit, limit.source.label() },
    ));
    return try capped.toOwnedSlice();
}

fn projectRuleFitsTotalLimit(
    effective_bytes: usize,
    preamble_bytes: usize,
    retained_bytes: usize,
    candidate_bytes: usize,
) bool {
    return preamble_bytes + retained_bytes + candidate_bytes <= effective_bytes;
}

fn projectInstructionsLimitMarker(
    alloc: Allocator,
    observed_bytes: usize,
    effective_bytes: usize,
    source: []const u8,
    omitted_count: usize,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "<context_limit name=\"project_instructions_total_bytes\" action=\"omitted\" omitted_count=\"{d}\" observed_bytes=\"{d}\" effective_bytes=\"{d}\" source=\"{s}\" override=\"--context-limit project_instructions_total_bytes=BYTES|off\" />",
        .{ omitted_count, observed_bytes, effective_bytes, source },
    );
}

fn writeTestFile(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(name)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try dir.createFile(io_mod.getIo(), name, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn createSymlinkOrSkip(dir: std.Io.Dir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    if (std.fs.path.dirname(link_path)) |parent| {
        try dir.createDirPath(io_mod.getIo(), parent);
    }
    dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };
}

fn checkLaterSelectionAllocationFailures(alloc: Allocator, workspace: []const u8, target: []const u8) !void {
    var context = try selectApplicableProjectContext(alloc, .{
        .workspace_root = workspace,
        .targets = &.{.{ .path = target, .kind = .file }},
        .delivered_sources = &.{},
        .evaluated_endpoints = &.{},
    });
    defer context.deinit(alloc);
}

const GitInfo = struct {
    branch: ?[]const u8 = null,
    worktree: GitWorktreeState = .unknown,
    remote: ?GitHubRepoIdentity = null,
};

const GitHubRepoIdentity = struct {
    repo: []const u8,
    repo_name: []const u8,
    host: []const u8 = "github.com",
};

const GitWorktreeState = enum {
    dirty,
    unknown,

    fn label(self: GitWorktreeState) []const u8 {
        return switch (self) {
            .dirty => "dirty",
            .unknown => "unknown",
        };
    }
};

const GitPathPresence = enum {
    present,
    missing,
    unknown,
};

const IndexEntryMatch = enum {
    clean,
    dirty,
    unknown,
};

const Date = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn buildTurnContextFragment(arena: Allocator, workspace_root: []const u8) ![]const u8 {
    const cwd = currentWorkingDirectory(arena) catch "(unavailable)";
    const os_text = try host.operatingSystemText(arena);
    const date_text = try todayUtcText(arena);
    const shell = shellPath() orelse "(unknown)";
    const home = homeDir() orelse "(unknown)";
    const git = collectGitInfo(arena, workspace_root) catch GitInfo{};

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    try out.writer.writeAll("<fx-turn-context>\n");
    try out.writer.writeAll("workspace_root: ");
    try model_context_encoding.writeScalar(&out.writer, if (workspace_root.len > 0) workspace_root else "(unavailable)");
    try out.writer.writeByte('\n');
    try out.writer.writeAll("current_directory: ");
    try model_context_encoding.writeScalar(&out.writer, cwd);
    try out.writer.writeByte('\n');
    try out.writer.print("operating_system: {s}\n", .{os_text});
    try out.writer.writeAll("shell_path: ");
    try model_context_encoding.writeScalar(&out.writer, shell);
    try out.writer.writeByte('\n');
    try out.writer.print("date_utc: {s}\n", .{date_text});
    try out.writer.writeAll("home_directory: ");
    try model_context_encoding.writeScalar(&out.writer, home);
    try out.writer.writeByte('\n');
    if (git.branch) |branch| {
        try out.writer.writeAll("git_branch: ");
        try model_context_encoding.writeScalar(&out.writer, branch);
        try out.writer.writeByte('\n');
    }
    try out.writer.print("git_worktree: {s}\n", .{git.worktree.label()});
    if (git.remote) |remote| {
        try out.writer.writeAll("github_repo: ");
        try model_context_encoding.writeScalar(&out.writer, remote.repo);
        try out.writer.writeByte('\n');
        try out.writer.writeAll("repo_name: ");
        try model_context_encoding.writeScalar(&out.writer, remote.repo_name);
        try out.writer.writeByte('\n');
        try out.writer.writeAll("github_host: ");
        try model_context_encoding.writeScalar(&out.writer, remote.host);
        try out.writer.writeByte('\n');
    }
    try out.writer.writeAll("</fx-turn-context>");

    return try out.toOwnedSlice();
}

fn buildTurnContextFragmentForHost(
    arena: Allocator,
    workspace_root: []const u8,
    host_workspace: ?context_contract.HostWorkspaceContext,
) ![]const u8 {
    const workspace = host_workspace orelse
        return buildTurnContextFragment(arena, workspace_root);
    const os_text = try host.operatingSystemText(arena);
    const date_text = try todayUtcText(arena);

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try out.writer.writeAll("<fx-turn-context>\nworkspace_root: ");
    try model_context_encoding.writeScalar(&out.writer, workspace.root);
    try out.writer.writeAll("\ncurrent_directory: ");
    try model_context_encoding.writeScalar(&out.writer, workspace.cwd);
    try out.writer.print("\noperating_system: {s}\nshell_path: just-bash\ndate_utc: {s}\nhome_directory: ", .{ os_text, date_text });
    try model_context_encoding.writeScalar(&out.writer, workspace.home);
    try out.writer.writeAll(
        "\ngit_available: false\n" ++
            "git_worktree: unavailable\n" ++
            "</fx-turn-context>",
    );
    return try out.toOwnedSlice();
}

fn currentWorkingDirectory(arena: Allocator) ![]const u8 {
    return std.process.currentPathAlloc(io_mod.getIo(), arena);
}

fn shellPath() ?[]const u8 {
    return io_mod.getenv("SHELL") orelse io_mod.getenv("COMSPEC");
}

fn homeDir() ?[]const u8 {
    return io_mod.getenv("HOME") orelse io_mod.getenv("USERPROFILE");
}

fn todayUtcText(arena: Allocator) ![]const u8 {
    return formatUtcDateFromMillis(arena, io_mod.milliTimestamp());
}

fn formatUtcDateFromMillis(arena: Allocator, epoch_ms: i64) ![]const u8 {
    const days = @divFloor(epoch_ms, std.time.ms_per_day);
    const date = civilFromUnixDays(days);
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u64, @intCast(date.year)),
        @as(u64, @intCast(date.month)),
        @as(u64, @intCast(date.day)),
    });
}

fn civilFromUnixDays(days_since_epoch: i64) Date {
    const z = days_since_epoch + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + if (mp < 10) @as(i64, 3) else -9;
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn collectGitInfo(arena: Allocator, workspace_root: []const u8) !GitInfo {
    if (workspace_root.len == 0) return .{};

    const started_ns = io_mod.nanoTimestamp();
    const git_dir = try resolveGitDir(arena, workspace_root);
    if (git_dir == null or gitReadExpired(started_ns)) return .{};

    const head_path = try std.fs.path.join(arena, &.{ git_dir.?, "HEAD" });
    const head = readSmallFile(arena, head_path, context_contract.Limits.git_metadata_file_bytes) catch return .{};
    if (gitReadExpired(started_ns)) return .{};

    const common_git_dir = try resolveCommonGitDir(arena, git_dir.?);
    const remote = if (gitReadExpired(started_ns))
        null
    else
        try collectGitHubRepoIdentity(arena, common_git_dir, started_ns);

    return .{
        .branch = try branchFromHead(arena, head),
        .worktree = detectGitWorktreeState(arena, workspace_root, git_dir.?, started_ns),
        .remote = remote,
    };
}

fn resolveGitDir(arena: Allocator, workspace_root: []const u8) !?[]const u8 {
    const dot_git = try std.fs.path.join(arena, &.{ workspace_root, ".git" });
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), dot_git, .{ .follow_symlinks = false }) catch return null;

    if (stat.kind == .directory) return dot_git;
    if (stat.kind != .file) return null;

    const content = readSmallFile(arena, dot_git, context_contract.Limits.git_metadata_file_bytes) catch return null;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const raw = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (raw.len == 0) return null;
    if (std.fs.path.isAbsolute(raw)) return try arena.dupe(u8, raw);
    return try std.fs.path.join(arena, &.{ workspace_root, raw });
}

fn resolveCommonGitDir(arena: Allocator, git_dir: []const u8) ![]const u8 {
    const common_path = try std.fs.path.join(arena, &.{ git_dir, "commondir" });
    const content = readSmallFile(arena, common_path, context_contract.Limits.git_metadata_file_bytes) catch return git_dir;
    const raw = std.mem.trim(u8, content, " \t\r\n");
    if (raw.len == 0) return git_dir;
    if (std.fs.path.isAbsolute(raw)) return try arena.dupe(u8, raw);
    return try std.fs.path.join(arena, &.{ git_dir, raw });
}

fn collectGitHubRepoIdentity(arena: Allocator, git_dir: []const u8, started_ns: i128) !?GitHubRepoIdentity {
    if (gitReadExpired(started_ns)) return null;
    const config_path = try std.fs.path.join(arena, &.{ git_dir, "config" });
    const config = readSmallFile(arena, config_path, context_contract.Limits.git_config_file_bytes) catch return null;
    if (gitReadExpired(started_ns)) return null;
    return try parseGitHubRepoIdentityFromConfig(arena, config);
}

fn detectGitWorktreeState(arena: Allocator, workspace_root: []const u8, git_dir: []const u8, started_ns: i128) GitWorktreeState {
    if (gitReadExpired(started_ns)) return .unknown;

    // This bounded hint can prove tracked-file changes but cannot detect untracked files.
    const dirty_markers = [_][]const u8{
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "rebase-merge",
        "rebase-apply",
    };
    for (dirty_markers) |marker| {
        switch (gitPathPresence(git_dir, marker)) {
            .present => return .dirty,
            .unknown => return .unknown,
            .missing => {},
        }
    }
    switch (gitPathPresence(git_dir, "index.lock")) {
        .present, .unknown => return .unknown,
        .missing => {},
    }
    if (gitReadExpired(started_ns)) return .unknown;

    const index_path = std.fs.path.join(arena, &.{ git_dir, "index" }) catch return .unknown;
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), index_path, .{ .follow_symlinks = false }) catch return .unknown;
    if (stat.kind != .file or stat.size > context_contract.Limits.git_index_file_bytes) return .unknown;

    const index = readSmallFile(arena, index_path, @intCast(stat.size + 1)) catch return .unknown;
    if (gitReadExpired(started_ns)) return .unknown;

    return worktreeStateFromSmallIndex(arena, workspace_root, index, started_ns) catch .unknown;
}

fn gitPathPresence(git_dir: []const u8, child: []const u8) GitPathPresence {
    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, git_dir, .{}) catch return .unknown;
    defer dir.close(zio);
    _ = dir.statFile(zio, child, .{ .follow_symlinks = false }) catch |err| {
        return switch (err) {
            error.FileNotFound => .missing,
            else => .unknown,
        };
    };
    return .present;
}

fn worktreeStateFromSmallIndex(arena: Allocator, workspace_root: []const u8, index: []const u8, started_ns: i128) !GitWorktreeState {
    if (index.len < 12 or !std.mem.eql(u8, index[0..4], "DIRC")) return .unknown;

    const version = std.mem.readInt(u32, index[4..8], .big);
    if (version != 2 and version != 3) return .unknown;

    const entry_count = std.mem.readInt(u32, index[8..12], .big);
    if (entry_count == 0) return .unknown;
    if (entry_count > context_contract.Limits.git_index_entries) return .unknown;

    var offset: usize = 12;
    var entry_index: u32 = 0;
    while (entry_index < entry_count) : (entry_index += 1) {
        if (gitReadExpired(started_ns)) return .unknown;
        const entry_start = offset;
        if (index.len < entry_start + 62) return .unknown;

        const flags = std.mem.readInt(u16, index[entry_start + 60 ..][0..2], .big);
        const stage = (flags >> 12) & 0x3;
        if (stage != 0) return .dirty;

        const path_start = entry_start + 62;
        const path_len_from_flags = flags & 0x0fff;
        const path_end = if (path_len_from_flags < 0x0fff) blk: {
            const end = path_start + @as(usize, path_len_from_flags);
            if (end >= index.len or index[end] != 0) return .unknown;
            break :blk end;
        } else blk: {
            const rel_end = std.mem.findScalar(u8, index[path_start..], 0) orelse return .unknown;
            break :blk path_start + rel_end;
        };
        const path = index[path_start..path_end];
        if (!isSafeIndexPath(path)) return .unknown;

        switch (try indexEntryMatchesWorktree(arena, workspace_root, index[entry_start..], path)) {
            .clean => {},
            .dirty => return .dirty,
            .unknown => return .unknown,
        }

        const entry_len = (path_end - entry_start) + 1;
        const padded_entry_len = alignGitIndexEntryLen(entry_len);
        offset = entry_start + padded_entry_len;
        if (offset > index.len) return .unknown;
    }

    return .unknown;
}

fn indexEntryMatchesWorktree(arena: Allocator, workspace_root: []const u8, entry: []const u8, path: []const u8) !IndexEntryMatch {
    if (entry.len < 62) return .unknown;

    const mode = std.mem.readInt(u32, entry[24..28], .big);
    const mode_type = mode & 0o170000;
    if (mode_type != 0o100000) return .unknown;

    const index_mtime_sec = std.mem.readInt(u32, entry[8..12], .big);
    const index_mtime_nsec = std.mem.readInt(u32, entry[12..16], .big);
    const index_size = std.mem.readInt(u32, entry[36..40], .big);

    const abs_path = try std.fs.path.join(arena, &.{ workspace_root, path });
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), abs_path, .{ .follow_symlinks = false }) catch |err| {
        return switch (err) {
            error.FileNotFound => .dirty,
            else => .unknown,
        };
    };

    if (stat.kind != .file) return .dirty;
    if (stat.size != index_size) return .dirty;

    const mtime_sec = @divFloor(stat.mtime.nanoseconds, std.time.ns_per_s);
    const mtime_nsec = @mod(stat.mtime.nanoseconds, std.time.ns_per_s);
    if (mtime_sec < 0 or mtime_sec > std.math.maxInt(u32)) return .unknown;
    if (mtime_nsec < 0 or mtime_nsec > std.math.maxInt(u32)) return .unknown;

    if (index_mtime_sec != @as(u32, @intCast(mtime_sec))) return .dirty;
    if (index_mtime_nsec != @as(u32, @intCast(mtime_nsec))) return .dirty;
    return .clean;
}

fn isSafeIndexPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn alignGitIndexEntryLen(len: usize) usize {
    return (len + 7) & ~@as(usize, 7);
}

fn readSmallFile(arena: Allocator, path: []const u8, max_bytes: usize) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(arena, &file, max_bytes);
}

fn parseGitHubRepoIdentityFromConfig(arena: Allocator, config: []const u8) !?GitHubRepoIdentity {
    var in_origin = false;
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') continue;
        if (trimmed[0] == '[') {
            in_origin = isOriginRemoteSection(trimmed);
            continue;
        }
        if (!in_origin) continue;

        const eq = std.mem.findScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (!std.mem.eql(u8, key, "url")) continue;
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        return try parseGitHubRemoteUrl(arena, value);
    }
    return null;
}

fn isOriginRemoteSection(line: []const u8) bool {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return false;
    const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    const remote = "remote";
    if (!std.mem.startsWith(u8, section, remote)) return false;
    var rest = std.mem.trim(u8, section[remote.len..], " \t");
    if (rest.len < 2 or rest[0] != '"') return false;
    rest = rest[1..];
    const quote = std.mem.findScalar(u8, rest, '"') orelse return false;
    if (!std.mem.eql(u8, rest[0..quote], "origin")) return false;
    return std.mem.trim(u8, rest[quote + 1 ..], " \t").len == 0;
}

fn parseGitHubRemoteUrl(arena: Allocator, raw: []const u8) !?GitHubRepoIdentity {
    if (std.mem.startsWith(u8, raw, "https://")) {
        const without_scheme = raw["https://".len..];
        const slash = std.mem.findScalar(u8, without_scheme, '/') orelse return null;
        const url_host = without_scheme[0..slash];
        if (std.mem.findScalar(u8, url_host, '@') != null) return null;
        if (!std.mem.eql(u8, url_host, "github.com")) return null;
        return try parseGitHubRepoPath(arena, without_scheme[slash + 1 ..]);
    }

    const scp_prefix = "git@github.com:";
    if (std.mem.startsWith(u8, raw, scp_prefix)) {
        return try parseGitHubRepoPath(arena, raw[scp_prefix.len..]);
    }

    const ssh_prefix = "ssh://git@github.com/";
    if (std.mem.startsWith(u8, raw, ssh_prefix)) {
        return try parseGitHubRepoPath(arena, raw[ssh_prefix.len..]);
    }

    return null;
}

fn parseGitHubRepoPath(arena: Allocator, raw_path: []const u8) !?GitHubRepoIdentity {
    const path = std.mem.trim(u8, raw_path, " \t\r\n");
    const without_suffix = if (std.mem.endsWith(u8, path, ".git")) path[0 .. path.len - ".git".len] else path;
    if (without_suffix.len == 0) return null;
    if (std.mem.findScalar(u8, without_suffix, '?') != null or std.mem.findScalar(u8, without_suffix, '#') != null) return null;

    const slash = std.mem.findScalar(u8, without_suffix, '/') orelse return null;
    if (std.mem.findScalar(u8, without_suffix[slash + 1 ..], '/') != null) return null;

    const owner = without_suffix[0..slash];
    const repo_name = without_suffix[slash + 1 ..];
    if (!isSafeGitHubPathComponent(owner) or !isSafeGitHubPathComponent(repo_name)) return null;

    return .{
        .repo = try std.fmt.allocPrint(arena, "{s}/{s}", .{ owner, repo_name }),
        .repo_name = try arena.dupe(u8, repo_name),
    };
}

fn isSafeGitHubPathComponent(component: []const u8) bool {
    if (component.len == 0) return false;
    if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    for (component) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn branchFromHead(arena: Allocator, head: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, head, " \t\r\n");
    if (trimmed.len == 0) return null;

    const prefix = "ref:";
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        const ref = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
        const heads_prefix = "refs/heads/";
        if (std.mem.startsWith(u8, ref, heads_prefix)) {
            return try arena.dupe(u8, ref[heads_prefix.len..]);
        }
        return try arena.dupe(u8, ref);
    }

    const short_len = @min(trimmed.len, 12);
    return try std.fmt.allocPrint(arena, "detached:{s}", .{trimmed[0..short_len]});
}

fn gitReadExpired(started_ns: i128) bool {
    const elapsed = io_mod.nanoTimestamp() - started_ns;
    return elapsed > context_contract.Limits.git_read_budget_ns;
}

fn appendBeU16(list: *std.ArrayList(u8), alloc: Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], value, .big);
    try list.appendSlice(alloc, &buf);
}

fn appendBeU32(list: *std.ArrayList(u8), alloc: Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], value, .big);
    try list.appendSlice(alloc, &buf);
}

fn appendZeroes(list: *std.ArrayList(u8), alloc: Allocator, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try list.append(alloc, 0);
}

fn u32TimePart(ns: i128, divisor: i128) !u32 {
    const value = if (divisor == std.time.ns_per_s) @divFloor(ns, divisor) else @mod(ns, std.time.ns_per_s);
    if (value < 0 or value > std.math.maxInt(u32)) return error.TimeOutOfRange;
    return @intCast(value);
}

fn writeSinglePathGitIndex(dir: std.Io.Dir, index_path: []const u8, file_path: []const u8, index_rel_path: []const u8) !void {
    const alloc = std.testing.allocator;
    const stat = try dir.statFile(io_mod.getIo(), file_path, .{});
    const mtime_sec = try u32TimePart(stat.mtime.nanoseconds, std.time.ns_per_s);
    const mtime_nsec = try u32TimePart(stat.mtime.nanoseconds, 1);
    const size: u32 = @intCast(stat.size);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);

    try bytes.appendSlice(alloc, "DIRC");
    try appendBeU32(&bytes, alloc, 2);
    try appendBeU32(&bytes, alloc, 1);

    const entry_start = bytes.items.len;
    try appendBeU32(&bytes, alloc, mtime_sec);
    try appendBeU32(&bytes, alloc, mtime_nsec);
    try appendBeU32(&bytes, alloc, mtime_sec);
    try appendBeU32(&bytes, alloc, mtime_nsec);
    try appendBeU32(&bytes, alloc, 0);
    try appendBeU32(&bytes, alloc, 0);
    try appendBeU32(&bytes, alloc, 0o100644);
    try appendBeU32(&bytes, alloc, 0);
    try appendBeU32(&bytes, alloc, 0);
    try appendBeU32(&bytes, alloc, size);
    try appendZeroes(&bytes, alloc, 20);
    try appendBeU16(&bytes, alloc, @intCast(index_rel_path.len));
    try bytes.appendSlice(alloc, index_rel_path);
    try bytes.append(alloc, 0);
    while ((bytes.items.len - entry_start) % 8 != 0) try bytes.append(alloc, 0);
    try appendZeroes(&bytes, alloc, 20);

    try writeTestFile(dir, index_path, bytes.items);
}

fn appendStatic(input: StaticContextInput, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    if (input.project_context.len > 0) {
        try messages.append(arena, .{ .role = .system, .content = input.project_context });
    }
}

fn permissionModeContext(permission_mode: types.PermissionMode) []const u8 {
    return switch (permission_mode) {
        .ask => "Runtime context: permission mode is ask. Sensitive tool calls may require user approval unless configured rules or session grants already decide them. Tool admission remains authoritative.",
        .auto => "Runtime context: permission mode is auto. After configured rules, session grants, and deterministic safe-tool authority, fx sends each unresolved action to a narrow safety reviewer. A clear result authorizes only that exact action. A caution or unavailable result holds only that action and returns advice without opening a permission screen, disabling tools, or ending the turn. Exact cautions are reused for this turn; choose a materially different safe action or explain why no safe path remains. Tool admission and exact live revalidation remain authoritative.",
        .yolo => "Runtime context: permission mode is yolo. fx permission policy is disabled. Tool lookup, argument validation, execution authority, cancellation, limits, operating-system permissions, and remote authentication remain authoritative.",
    };
}

fn appendTransient(input: TransientContextInput, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const turn_context = try buildTurnContextFragmentForHost(
        arena,
        input.workspace_root,
        input.host_workspace,
    );
    const content = if (input.interactive)
        turn_context
    else
        try std.fmt.allocPrint(
            arena,
            "{s}\nRuntime context: this is a noninteractive run without live question UI; when a user-owned decision remains after inspection, stop and surface a concrete blocker in freeform text with the available options. Do not recommend or label one option as preferred.",
            .{turn_context},
        );
    try messages.append(arena, .{ .role = .system, .content = content });
    try appendWorkspaceAccessContext(input.access_scope, arena, messages);
    try messages.append(arena, .{ .role = .system, .content = permissionModeContext(input.permission_mode) });
    try appendFocusedVerificationContext(input.tracker, arena, messages);

    const runtime_state = try input.background.snapshot(arena);
    defer runtime_state.deinit(arena);

    if (runtime_state.tasks.len > 0) {
        var note: std.Io.Writer.Allocating = .init(arena);
        defer note.deinit();

        try note.writer.print("Runtime context: {d} background command{s} {s} running for this workspace. Reuse an existing matching server instead of starting a duplicate.\n", .{ runtime_state.tasks.len, if (runtime_state.tasks.len == 1) "" else "s", if (runtime_state.tasks.len == 1) "is" else "are" });
        for (runtime_state.tasks) |task| {
            try note.writer.print("- Background #{d}: command=", .{task.id});
            try model_context_encoding.writeScalar(&note.writer, task.command);
            try note.writer.writeAll("; cwd=");
            try model_context_encoding.writeScalar(&note.writer, task.cwd);
            try note.writer.writeAll("; pid=");
            try model_context_encoding.writeScalar(&note.writer, task.pid);
            try note.writer.writeAll("; log=");
            try model_context_encoding.writeScalar(&note.writer, task.log_path);
            if (task.server_url) |url| {
                try note.writer.writeAll("; url=");
                try model_context_encoding.writeScalar(&note.writer, url);
            } else if (task.expect_url) {
                try note.writer.writeAll("; url=pending");
            }
            try note.writer.writeByte('\n');
        }

        try messages.append(arena, .{ .role = .system, .content = try note.toOwnedSlice() });
    }

    try appendNonLiveBackgroundHistoryContext(input.background, input.session, arena, messages);
}

fn appendWorkspaceAccessContext(
    maybe_scope: ?workspace_access.AccessScope,
    arena: Allocator,
    messages: *std.ArrayList(ChatMessage),
) !void {
    const scope = maybe_scope orelse return;
    var active_count: usize = 0;
    for (scope.additional_directories) |entry| {
        if (entry.active) active_count += 1;
    }
    if (active_count == 0) return;

    var note: std.Io.Writer.Allocating = .init(arena);
    defer note.deinit();
    try note.writer.writeAll(
        "Runtime context: the following additional directories are access-authorized for this run. Relative paths still resolve from the primary workspace. These directories do not contribute AGENTS.md or other project instructions.\n",
    );
    for (scope.additional_directories) |entry| {
        if (!entry.active) continue;
        try note.writer.writeAll("- ");
        try model_context_encoding.writeScalar(&note.writer, entry.path);
        try note.writer.writeByte('\n');
    }
    try messages.append(arena, .{ .role = .system, .content = try note.toOwnedSlice() });
}

fn appendFocusedVerificationContext(tracker: ?*change_tracker.ChangeTracker, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const current_tracker = tracker orelse return;
    if (current_tracker.stack.items.len == 0) return;

    var note: std.Io.Writer.Allocating = .init(arena);
    defer note.deinit();

    try note.writer.writeAll("Runtime context: this turn has tracked file changes. Choose focused verification from the touched areas first; do not run generic or expensive verification commands unless the touched paths justify them or the user asked for them. Preserve exact evidence from verification commands in the final summary.\n");
    try note.writer.print("- tracked_changes={d}\n", .{current_tracker.stack.items.len});
    var wrote_zig = false;
    var wrote_tests = false;
    var wrote_docs = false;
    var wrote_evals = false;
    var wrote_test_paths: usize = 0;
    for (current_tracker.stack.items) |op| {
        const path = op.path;
        if (!wrote_zig and std.mem.endsWith(u8, path, ".zig")) {
            try note.writer.writeAll("- touched_area=zig: run focused Zig tests/build checks for the changed module before broader verification.\n");
            wrote_zig = true;
        }
        if (!wrote_tests and (std.mem.find(u8, path, "/tests/") != null or std.mem.startsWith(u8, path, "tests/"))) {
            try note.writer.writeAll("- touched_area=tests: run the focused test file or suite that owns the changed test.\n");
            wrote_tests = true;
        }
        if (!wrote_evals and std.mem.find(u8, path, "tests/evals/") != null) {
            try note.writer.writeAll("- touched_area=evals: run the focused Bun eval or matrix test before considering model-backed evals. Do not treat tests/evals/agent-quality-matrix.test.ts as model-backed; it is deterministic.\n");
            wrote_evals = true;
        }
        if (wrote_test_paths < 5 and std.mem.endsWith(u8, path, ".test.ts")) {
            try note.writer.writeAll("- touched_test_file=");
            try model_context_encoding.writeScalar(&note.writer, path);
            try note.writer.writeAll(": run this test file directly before any broad suite.\n");
            wrote_test_paths += 1;
        }
        if (!wrote_docs and (std.mem.endsWith(u8, path, ".md") or std.mem.find(u8, path, "/docs/") != null)) {
            try note.writer.writeAll("- touched_area=docs: verify references and examples rather than running unrelated builds by default.\n");
            wrote_docs = true;
        }
    }

    try messages.append(arena, .{ .role = .system, .content = try note.toOwnedSlice() });
}

fn appendNonLiveBackgroundHistoryContext(background: *BackgroundRuntime, session: *SessionRuntime, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    var seen_log_paths: std.ArrayList([]const u8) = .empty;
    defer seen_log_paths.deinit(arena);

    var note: std.Io.Writer.Allocating = .init(arena);
    defer note.deinit();
    var wrote_header = false;

    for (session.history.items) |turn| {
        const entry = switch (turn) {
            .background_command => |value| value,
            else => continue,
        };
        if (containsLogPath(seen_log_paths.items, entry.log_path)) continue;
        try seen_log_paths.append(arena, entry.log_path);

        var task = (try background.snapshotTaskByLogPath(arena, entry.log_path)) orelse continue;
        defer task.deinit(arena);
        if (task.state == .running) continue;

        if (!wrote_header) {
            try note.writer.writeAll("Runtime context: previous background command history includes command(s) that are no longer live. Treat these as terminal historical records, not running tasks.\n");
            wrote_header = true;
        }
        try note.writer.writeAll("- command=");
        try model_context_encoding.writeScalar(&note.writer, task.command);
        try note.writer.writeAll("; log=");
        try model_context_encoding.writeScalar(&note.writer, task.log_path);
        try note.writer.print("; state={s}\n", .{@tagName(task.state)});
        debug_trace.logf(
            "background",
            "model context non-live background history display_id={d} state={s}",
            .{ task.id, @tagName(task.state) },
        );
    }

    if (!wrote_header) return;
    try note.writer.writeAll("For any listed command, answer liveness questions from this state; do not assume it is still running or reuse it as a live background task. Restart a listed command only if the user explicitly asks.");
    try messages.append(arena, .{ .role = .system, .content = try note.toOwnedSlice() });
}

fn containsLogPath(paths: []const []const u8, log_path: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, log_path)) return true;
    }
    return false;
}

const PromptContextFixture = struct {
    background: BackgroundRuntime = .{},
    session: SessionRuntime = .{ .max_history_turns = 8 },
    workspace_root: []const u8 = "/tmp",
    project_context: []const u8 = "",
    permission_mode: types.PermissionMode = .ask,
    tracker: ?*change_tracker.ChangeTracker = null,
    interactive: bool = true,

    fn deinit(self: *PromptContextFixture, alloc: Allocator) void {
        self.background.deinit(alloc);
        self.session.deinit(alloc);
    }

    fn transientInput(self: *PromptContextFixture) TransientContextInput {
        return .{
            .workspace_root = self.workspace_root,
            .interactive = self.interactive,
            .permission_mode = self.permission_mode,
            .tracker = self.tracker,
            .background = &self.background,
            .session = &self.session,
        };
    }

    fn staticInput(self: *PromptContextFixture) StaticContextInput {
        return .{ .project_context = self.project_context };
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) == null);
}

fn checkPromptContextSnapshotAllocationFailures(alloc: Allocator, live_log: []const u8, historical_log: []const u8) !void {
    var fixture = PromptContextFixture{};
    defer fixture.deinit(std.testing.allocator);

    _ = try fixture.background.registerBackground(std.testing.allocator, .{
        .pid = "12345",
        .command = "npm run dev",
        .cwd = fixture.workspace_root,
        .log_path = live_log,
        .expect_url = true,
    });
    const historical_id = try fixture.background.registerBackground(std.testing.allocator, .{
        .pid = "historical",
        .command = "npm run preview",
        .cwd = fixture.workspace_root,
        .log_path = historical_log,
        .expect_url = true,
    });
    try std.testing.expect(fixture.background.supervisor.markStopped(historical_id));
    try fixture.session.appendBackgroundCommandHistoryTurn(std.testing.allocator, "start preview", .{
        .pid = "historical",
        .command = "npm run preview",
        .cwd = fixture.workspace_root,
        .log_path = historical_log,
        .expect_url = true,
    });
    fixture.background.requestStop();

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(arena);
    appendTransient(fixture.transientInput(), arena, &messages) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try expectContains(messages.items[2].content.?, live_log);
    try expectContains(messages.items[3].content.?, historical_log);
}

fn expectDefaultPromptContains(needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, gateway_system_prompt, needle) != null);
}

fn expectDefaultPromptDoesNotContain(needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, gateway_system_prompt, needle) == null);
}
