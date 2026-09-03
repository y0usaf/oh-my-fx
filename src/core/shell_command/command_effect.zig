const std = @import("std");
const command_lex = @import("command_lex.zig");

const max_command_bytes = 8 * 1024;
const max_ls_operands = 64;
const max_git_pathspecs = 64;
const max_line_count = 10_000;
const max_git_log_count = 1_000;
pub const max_direct_pipeline_stages = 8;

/// Returns true only for a small parsed set of ordinary development commands
/// whose effects are expected and recoverable in auto mode. Unknown syntax,
/// dynamic shell expansion, publication, deletion, and wrappers remain on the
/// normal review path.
pub fn knownReversibleAutoCommand(
    alloc: std.mem.Allocator,
    command: []const u8,
    background: bool,
) std.mem.Allocator.Error!bool {
    if (background) return false;
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len == 0 or trimmed.len > max_command_bytes or
        std.mem.findScalar(u8, trimmed, '\n') != null or
        std.mem.findScalar(u8, trimmed, '\r') != null)
    {
        return false;
    }

    var argv = command_lex.tokenize_argv(alloc, trimmed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer argv.deinit(alloc);
    if (argv.tokens.len == 0) return false;

    var stage_start: usize = 0;
    var index: usize = 0;
    while (index <= argv.tokens.len) : (index += 1) {
        const at_end = index == argv.tokens.len;
        if (!at_end and !std.mem.eql(u8, argv.tokens[index].value, "&&")) {
            if (isUnsupportedAutoControlOperator(argv.tokens[index])) return false;
            continue;
        }
        if (!reversibleAutoStage(argv.tokens[stage_start..index])) return false;
        stage_start = index + 1;
    }
    return true;
}

fn isUnsupportedAutoOperator(token: command_lex.ArgvToken) bool {
    return isUnsupportedAutoControlOperator(token) or
        (!token.quoted and command_lex.redirection_kind(token.value) != null);
}

fn isUnsupportedAutoControlOperator(token: command_lex.ArgvToken) bool {
    if (token.quoted) return false;
    if (std.mem.eql(u8, token.value, "&&")) return false;
    return std.mem.eql(u8, token.value, "|") or
        std.mem.eql(u8, token.value, "||") or
        std.mem.eql(u8, token.value, "&") or
        std.mem.eql(u8, token.value, ";") or
        std.mem.eql(u8, token.value, "(") or
        std.mem.eql(u8, token.value, ")") or
        std.mem.eql(u8, token.value, "{") or
        std.mem.eql(u8, token.value, "}");
}

fn reversibleAutoStage(raw_tokens: []const command_lex.ArgvToken) bool {
    var tokens = raw_tokens;
    if (tokens.len >= 3 and
        !tokens[tokens.len - 3].quoted and
        !tokens[tokens.len - 2].quoted and
        !tokens[tokens.len - 1].quoted and
        std.mem.eql(u8, tokens[tokens.len - 3].value, "2") and
        std.mem.eql(u8, tokens[tokens.len - 2].value, ">&") and
        std.mem.eql(u8, tokens[tokens.len - 1].value, "1"))
    {
        tokens = tokens[0 .. tokens.len - 3];
    }
    if (tokens.len == 0) return false;
    for (tokens) |token| {
        if (isUnsupportedAutoOperator(token) or tokenHasDynamicShellSyntax(token.raw)) {
            return false;
        }
    }

    const executable = tokens[0].value;
    const words = tokens[1..];
    if (std.mem.eql(u8, executable, "node")) {
        return words.len == 1 and isVersionFlag(words[0].value);
    }
    if (std.mem.eql(u8, executable, "which")) {
        return words.len > 0 and allOperands(words);
    }
    if (std.mem.eql(u8, executable, "git")) return reversibleGit(words);
    if (std.mem.eql(u8, executable, "npm")) return reversibleNpm(words);
    if (std.mem.eql(u8, executable, "bun")) return reversiblePackageRunner(words);
    if (std.mem.eql(u8, executable, "pnpm")) return reversiblePackageRunner(words);
    if (std.mem.eql(u8, executable, "yarn")) return reversiblePackageRunner(words);
    if (std.mem.eql(u8, executable, "zig")) {
        return words.len > 0 and std.mem.eql(u8, words[0].value, "build");
    }
    return false;
}

fn tokenHasDynamicShellSyntax(raw: []const u8) bool {
    for (raw) |byte| switch (byte) {
        '$', '`', '*', '?', '[', '~', '\n', '\r', ';', '(', ')', '{', '}' => return true,
        else => {},
    };
    return false;
}

fn isVersionFlag(value: []const u8) bool {
    return std.mem.eql(u8, value, "-v") or
        std.mem.eql(u8, value, "--version");
}

fn allOperands(tokens: []const command_lex.ArgvToken) bool {
    for (tokens) |token| {
        if (token.value.len == 0 or token.value[0] == '-') return false;
    }
    return true;
}

fn reversibleGit(words: []const command_lex.ArgvToken) bool {
    if (words.len == 0) return false;
    const subcommand = words[0].value;
    if (std.mem.eql(u8, subcommand, "status")) return true;
    if (std.mem.eql(u8, subcommand, "remote")) {
        return words.len == 2 and std.mem.eql(u8, words[1].value, "-v");
    }
    if (std.mem.eql(u8, subcommand, "worktree")) {
        return words.len >= 2 and std.mem.eql(u8, words[1].value, "list");
    }
    if (std.mem.eql(u8, subcommand, "fetch")) {
        for (words[1..]) |word| {
            if (std.mem.eql(u8, word.value, "--prune") or
                std.mem.eql(u8, word.value, "-p") or
                std.mem.eql(u8, word.value, "--prune-tags")) return false;
        }
        return true;
    }
    return false;
}

fn reversibleNpm(words: []const command_lex.ArgvToken) bool {
    if (words.len == 1 and isVersionFlag(words[0].value)) return true;
    if (words.len == 0) return false;
    const subcommand = words[0].value;
    if (std.mem.eql(u8, subcommand, "install") or
        std.mem.eql(u8, subcommand, "i") or
        std.mem.eql(u8, subcommand, "ci") or
        std.mem.eql(u8, subcommand, "test"))
    {
        return !hasGlobalPackageFlag(words[1..]);
    }
    return std.mem.eql(u8, subcommand, "run") and words.len >= 2;
}

fn reversiblePackageRunner(words: []const command_lex.ArgvToken) bool {
    if (words.len == 1 and isVersionFlag(words[0].value)) return true;
    if (words.len == 0) return false;
    const subcommand = words[0].value;
    if (std.mem.eql(u8, subcommand, "install") or
        std.mem.eql(u8, subcommand, "test"))
    {
        return !hasGlobalPackageFlag(words[1..]);
    }
    return std.mem.eql(u8, subcommand, "run") and words.len >= 2;
}

fn hasGlobalPackageFlag(words: []const command_lex.ArgvToken) bool {
    for (words) |word| {
        if (std.mem.eql(u8, word.value, "-g") or
            std.mem.eql(u8, word.value, "--global") or
            std.mem.eql(u8, word.value, "--location") or
            std.mem.eql(u8, word.value, "--location=global") or
            std.mem.eql(u8, word.value, "--prefix") or
            std.mem.startsWith(u8, word.value, "--prefix=")) return true;
    }
    return false;
}

const PrintfFormatLanguage = enum {
    portable_literal_newline_percent_string,
};

const PrintfPolicy = struct {
    executable: []const u8,
    format_language: PrintfFormatLanguage = .portable_literal_newline_percent_string,
};

const LsSymlinkSemantics = enum {
    platform_default,
};

const LsPolicy = struct {
    executable: []const u8,
    forced_argv: []const []const u8,
    symlink_semantics: LsSymlinkSemantics = .platform_default,
};

pub const ApprovalReason = enum {
    filesystem_write,
    network_access,
    process_or_system,
    background_process,
    dynamic_shell,
    unsupported_shell,
    unsupported_platform,
    unsupported_input_redirect,
    unsupported_argument,
    command_owned_input,
    unknown_command,
    planning_failure,
};

pub const EnvironmentProfile = enum {
    basic_read_only,
    git_read_only,
};

pub const DirectStage = struct {
    executable: []const u8,
    argv: []const []const u8,
    environment_profile: EnvironmentProfile,
};

pub const DirectReadOnlyPlan = struct {
    command: []const u8,
    cwd: []const u8,
    stages: []const DirectStage,

    pub fn deinit(self: *DirectReadOnlyPlan, alloc: std.mem.Allocator) void {
        for (self.stages) |stage| {
            for (stage.argv) |arg| alloc.free(arg);
            alloc.free(stage.argv);
        }
        alloc.free(self.stages);
        alloc.free(self.cwd);
        alloc.free(self.command);
        self.* = undefined;
    }
};

pub const Admission = union(enum) {
    direct_read_only: DirectReadOnlyPlan,
    approval_required: ApprovalReason,

    pub fn deinit(self: *Admission, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .direct_read_only => |*direct| direct.deinit(alloc),
            .approval_required => {},
        }
        self.* = undefined;
    }
};

pub fn plan(
    alloc: std.mem.Allocator,
    command: []const u8,
    resolved_cwd: []const u8,
    background: bool,
    target_os: std.Target.Os.Tag,
) std.mem.Allocator.Error!Admission {
    if (background) return .{ .approval_required = .background_process };
    if (target_os != .macos and target_os != .linux) {
        return .{ .approval_required = .unsupported_platform };
    }

    const trimmed = std.mem.trim(u8, command, " \t\n");
    if (trimmed.len == 0) return .{ .approval_required = .unknown_command };
    if (trimmed.len > max_command_bytes) return .{ .approval_required = .unsupported_argument };
    if (validateShellShape(trimmed)) |reason| {
        return .{ .approval_required = reason };
    }

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const segments = command_lex.pipe_segments(scratch, trimmed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .approval_required = .unsupported_shell },
    };
    if (segments.len == 0) return .{ .approval_required = .unknown_command };
    if (segments.len > max_direct_pipeline_stages) {
        return .{ .approval_required = .process_or_system };
    }

    var planned: std.ArrayList(TemporaryStage) = .empty;
    for (segments) |segment| {
        if (segment.text.len == 0) return .{ .approval_required = .unsupported_shell };

        const argv = command_lex.tokenize_argv(scratch, segment.text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .approval_required = .unsupported_shell },
        };
        const parsed = try parseStage(scratch, argv.tokens, target_os);
        switch (parsed) {
            .approval_required => |reason| return .{ .approval_required = reason },
            .direct => |stage| try planned.append(scratch, stage),
        }
    }

    return ownPlan(alloc, command, resolved_cwd, planned.items);
}

const TemporaryStage = struct {
    executable: []const u8,
    argv: []const []const u8,
    environment_profile: EnvironmentProfile = .basic_read_only,
};

const StageAdmission = union(enum) {
    direct: TemporaryStage,
    approval_required: ApprovalReason,
};

fn validateShellShape(command: []const u8) ?ApprovalReason {
    if (!std.unicode.utf8ValidateSlice(command) or std.mem.findScalar(u8, command, 0) != null) {
        return .unsupported_shell;
    }
    if (std.mem.findScalar(u8, command, '\r') != null) return .unsupported_shell;

    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const ch = command[i];

        if (in_single) {
            if (ch == '\'') in_single = false;
            continue;
        }
        if (in_double) {
            if (ch == '"') {
                in_double = false;
                continue;
            }
            if (ch == '$' or ch == '`') return .dynamic_shell;
            if (ch == '\\' or ch == '\n') return .unsupported_shell;
            continue;
        }

        switch (ch) {
            '\'' => in_single = true,
            '"' => in_double = true,
            '$', '`', '*', '?', '[', '~' => return .dynamic_shell,
            '\\', '#', ';', '\n', '(', ')', '{', '}' => return .unsupported_shell,
            '&' => {
                if (i + 1 < command.len and command[i + 1] == '>') return .filesystem_write;
                return .unsupported_shell;
            },
            '|' => {
                if (i + 1 < command.len and command[i + 1] == '|') return .unsupported_shell;
            },
            '>' => return .filesystem_write,
            '<' => {
                if (i + 1 < command.len) {
                    switch (command[i + 1]) {
                        '(' => return .dynamic_shell,
                        '>' => return .filesystem_write,
                        '<', '&' => return .unsupported_shell,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return if (in_single or in_double) .unsupported_shell else null;
}

fn parseStage(
    alloc: std.mem.Allocator,
    tokens: []const command_lex.ArgvToken,
    target_os: std.Target.Os.Tag,
) std.mem.Allocator.Error!StageAdmission {
    var words: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < tokens.len) {
        const token = tokens[index];
        if (!token.quoted and std.mem.eql(u8, token.value, "<")) {
            return .{ .approval_required = .unsupported_input_redirect };
        }
        if (isOperatorToken(token)) return .{ .approval_required = .unsupported_shell };
        try words.append(alloc, token.value);
        index += 1;
    }

    if (words.items.len == 0) return .{ .approval_required = .unknown_command };
    if (std.mem.findScalar(u8, words.items[0], '=') != null) {
        return .{ .approval_required = .dynamic_shell };
    }

    const family = try planFamily(alloc, words.items, target_os);
    return switch (family) {
        .approval_required => |reason| .{ .approval_required = reason },
        .direct => |stage| .{ .direct = .{
            .executable = stage.executable,
            .argv = stage.argv,
            .environment_profile = stage.environment_profile,
        } },
    };
}

fn isOperatorToken(token: command_lex.ArgvToken) bool {
    if (token.quoted) return false;
    return std.mem.eql(u8, token.value, "|") or
        std.mem.eql(u8, token.value, "||") or
        std.mem.eql(u8, token.value, "&") or
        std.mem.eql(u8, token.value, "&&") or
        std.mem.eql(u8, token.value, ";") or
        command_lex.redirection_kind(token.value) != null;
}

fn planFamily(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    target_os: std.Target.Os.Tag,
) std.mem.Allocator.Error!StageAdmission {
    const command = words[0];
    if (isFilesystemMutation(command)) return .{ .approval_required = .filesystem_write };
    if (isNetworkCommand(command)) return .{ .approval_required = .network_access };
    if (isProcessOrSystemCommand(command)) return .{ .approval_required = .process_or_system };
    if (std.mem.eql(u8, command, "printf")) return planPrintf(alloc, words, target_os);
    if (std.mem.eql(u8, command, "pwd")) return planPwd(alloc, words);
    if (std.mem.eql(u8, command, "ls")) return planLs(alloc, words, target_os);
    if (std.mem.eql(u8, command, "wc")) return planWc(alloc, words);
    if (std.mem.eql(u8, command, "cat")) return planCat(alloc, words);
    if (std.mem.eql(u8, command, "head")) return planHeadOrTail(alloc, words, "/usr/bin/head");
    if (std.mem.eql(u8, command, "tail")) return planHeadOrTail(alloc, words, "/usr/bin/tail");
    if (std.mem.eql(u8, command, "grep")) return planGrep(alloc, words);
    if (std.mem.eql(u8, command, "git")) return planGit(alloc, words);
    return .{ .approval_required = .unknown_command };
}

fn planPrintf(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    target_os: std.Target.Os.Tag,
) std.mem.Allocator.Error!StageAdmission {
    const policy = printfPolicy(target_os);
    if (words.len < 2) return .{ .approval_required = .unsupported_argument };
    const format = words[1];
    const conversions = printfStringConversionCount(format) orelse {
        return .{ .approval_required = .unsupported_argument };
    };
    if (words.len - 2 != conversions) return .{ .approval_required = .unsupported_argument };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, policy.executable);
    try argv.appendSlice(alloc, words[1..]);
    return .{ .direct = .{
        .executable = policy.executable,
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn printfPolicy(target_os: std.Target.Os.Tag) PrintfPolicy {
    return switch (target_os) {
        .macos, .linux => .{ .executable = "/usr/bin/printf" },
        else => unreachable,
    };
}

fn printfStringConversionCount(format: []const u8) ?usize {
    if (format.len == 0 or format[0] == '-') return null;

    var count: usize = 0;
    var index: usize = 0;
    while (index < format.len) {
        const ch = format[index];
        if (ch < 0x20 or ch > 0x7e) return null;
        if (ch == '\\') {
            if (index + 1 >= format.len or format[index + 1] != 'n') return null;
            index += 2;
            continue;
        }
        if (ch == '%') {
            if (index + 1 >= format.len) return null;
            switch (format[index + 1]) {
                '%' => {},
                's' => count += 1,
                else => return null,
            }
            index += 2;
            continue;
        }
        index += 1;
    }
    return count;
}

fn planPwd(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    if (words.len > 2 or (words.len == 2 and !std.mem.eql(u8, words[1], "-P"))) {
        return .{ .approval_required = .unsupported_argument };
    }
    const argv = try alloc.dupe([]const u8, &.{ "/bin/pwd", "-P" });
    return .{ .direct = .{
        .executable = "/bin/pwd",
        .argv = argv,
    } };
}

fn planLs(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    target_os: std.Target.Os.Tag,
) std.mem.Allocator.Error!StageAdmission {
    const policy = lsPolicy(target_os);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, policy.executable);
    try argv.appendSlice(alloc, policy.forced_argv);

    var operands: std.ArrayList([]const u8) = .empty;
    var parsing_options = true;
    var explicit_separator = false;
    for (words[1..]) |word| {
        if (parsing_options and std.mem.eql(u8, word, "--")) {
            parsing_options = false;
            explicit_separator = true;
            continue;
        }
        if (parsing_options and word.len > 1 and word[0] == '-') {
            for (word[1..]) |flag| {
                const canonical = switch (flag) {
                    '1' => "-1",
                    'a' => "-a",
                    'A' => "-A",
                    'd' => "-d",
                    'F' => "-F",
                    'l', 'n' => "-n",
                    'p' => "-p",
                    else => return .{ .approval_required = .unsupported_argument },
                };
                try argv.append(alloc, canonical);
            }
            continue;
        }
        parsing_options = false;
        if (!explicit_separator and word.len > 1 and word[0] == '-') {
            return .{ .approval_required = .unsupported_argument };
        }
        try operands.append(alloc, word);
    }

    if (operands.items.len > max_ls_operands) {
        return .{ .approval_required = .unsupported_argument };
    }
    try argv.append(alloc, "--");
    try argv.appendSlice(alloc, operands.items);
    return .{ .direct = .{
        .executable = policy.executable,
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn lsPolicy(target_os: std.Target.Os.Tag) LsPolicy {
    return switch (target_os) {
        .macos, .linux => .{
            .executable = "/bin/ls",
            .forced_argv = &.{"-q"},
        },
        else => unreachable,
    };
}

fn planWc(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, "/usr/bin/wc");
    for (words[1..]) |word| {
        if (word.len < 2 or word[0] != '-') {
            return .{ .approval_required = .unsupported_argument };
        }
        for (word[1..]) |flag| {
            const canonical = switch (flag) {
                'L' => "-L",
                'c' => "-c",
                'l' => "-l",
                'm' => "-m",
                'w' => "-w",
                else => return .{ .approval_required = .unsupported_argument },
            };
            try argv.append(alloc, canonical);
        }
    }
    return .{ .direct = .{
        .executable = "/usr/bin/wc",
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn planCat(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    if (words.len != 1) return .{ .approval_required = .unsupported_argument };
    const argv = try alloc.dupe([]const u8, &.{"/bin/cat"});
    return .{ .direct = .{
        .executable = "/bin/cat",
        .argv = argv,
    } };
}

fn planHeadOrTail(
    alloc: std.mem.Allocator,
    words: []const []const u8,
    executable: []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var index: usize = 1;
    var count: []const u8 = "10";
    if (index < words.len and std.mem.eql(u8, words[index], "-n")) {
        if (index + 1 >= words.len or !boundedDecimal(words[index + 1], max_line_count)) {
            return .{ .approval_required = .unsupported_argument };
        }
        count = words[index + 1];
        index += 2;
    }

    if (index != words.len) return .{ .approval_required = .unsupported_argument };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ executable, "-n", count });
    return .{ .direct = .{
        .executable = executable,
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn planGrep(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, "/usr/bin/grep");

    var index: usize = 1;
    while (index < words.len) : (index += 1) {
        const word = words[index];
        if (std.mem.eql(u8, word, "--")) {
            index += 1;
            break;
        }
        if (word.len <= 1 or word[0] != '-') break;
        for (word[1..]) |flag| {
            const canonical = switch (flag) {
                'E' => "-E",
                'F' => "-F",
                'i' => "-i",
                'n' => "-n",
                'v' => "-v",
                else => return .{ .approval_required = .unsupported_argument },
            };
            try argv.append(alloc, canonical);
        }
    }
    if (index >= words.len) return .{ .approval_required = .unsupported_argument };
    if (words.len - index != 1) {
        return .{ .approval_required = .unsupported_argument };
    }
    try argv.append(alloc, "--");
    try argv.append(alloc, words[index]);
    return .{ .direct = .{
        .executable = "/usr/bin/grep",
        .argv = try argv.toOwnedSlice(alloc),
    } };
}

fn planGit(
    alloc: std.mem.Allocator,
    words: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    if (words.len < 2) return .{ .approval_required = .command_owned_input };
    if (std.mem.eql(u8, words[1], "status")) return planGitStatus(alloc, words[2..]);
    if (std.mem.eql(u8, words[1], "diff")) return planGitDiff(alloc, words[2..]);
    if (std.mem.eql(u8, words[1], "log")) return planGitLog(alloc, words[2..]);
    return .{ .approval_required = .command_owned_input };
}

fn appendGitPrelude(
    alloc: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try argv.appendSlice(alloc, &.{
        "/usr/bin/git",
        "--no-pager",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
    });
}

fn directGit(argv: []const []const u8) StageAdmission {
    return .{ .direct = .{
        .executable = "/usr/bin/git",
        .argv = argv,
        .environment_profile = .git_read_only,
    } };
}

fn planGitStatus(
    alloc: std.mem.Allocator,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendGitPrelude(alloc, &argv);
    try argv.appendSlice(alloc, &.{ "status", "--ignore-submodules=all" });
    for (arguments) |argument| {
        const canonical = if (std.mem.eql(u8, argument, "-s"))
            "--short"
        else if (std.mem.eql(u8, argument, "-b"))
            "--branch"
        else if (std.mem.eql(u8, argument, "--short") or
            std.mem.eql(u8, argument, "--branch") or
            std.mem.eql(u8, argument, "--porcelain") or
            std.mem.eql(u8, argument, "--porcelain=v1") or
            std.mem.eql(u8, argument, "--untracked-files=no") or
            std.mem.eql(u8, argument, "--untracked-files=normal") or
            std.mem.eql(u8, argument, "--untracked-files=all"))
            argument
        else
            return .{ .approval_required = .unsupported_argument };
        try argv.append(alloc, canonical);
    }
    return directGit(try argv.toOwnedSlice(alloc));
}

fn planGitDiff(
    alloc: std.mem.Allocator,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendGitPrelude(alloc, &argv);
    try argv.appendSlice(alloc, &.{ "diff", "--no-ext-diff", "--no-textconv", "--color=never" });

    var index: usize = 0;
    while (index < arguments.len and !std.mem.eql(u8, arguments[index], "--")) : (index += 1) {
        const argument = arguments[index];
        if (!(std.mem.eql(u8, argument, "--cached") or
            std.mem.eql(u8, argument, "--staged") or
            std.mem.eql(u8, argument, "--stat") or
            std.mem.eql(u8, argument, "--shortstat") or
            std.mem.eql(u8, argument, "--numstat") or
            std.mem.eql(u8, argument, "--name-only") or
            std.mem.eql(u8, argument, "--name-status") or
            std.mem.eql(u8, argument, "--check") or
            std.mem.eql(u8, argument, "--no-renames")))
        {
            return .{ .approval_required = .unsupported_argument };
        }
        try argv.append(alloc, argument);
    }
    const operands = if (index < arguments.len) arguments[index + 1 ..] else &.{};
    if (operands.len > max_git_pathspecs) {
        return .{ .approval_required = .unsupported_argument };
    }
    try argv.append(alloc, "--");
    try argv.appendSlice(alloc, operands);
    return directGit(try argv.toOwnedSlice(alloc));
}

fn planGitLog(
    alloc: std.mem.Allocator,
    arguments: []const []const u8,
) std.mem.Allocator.Error!StageAdmission {
    var argv: std.ArrayList([]const u8) = .empty;
    try appendGitPrelude(alloc, &argv);
    try argv.appendSlice(alloc, &.{ "log", "--no-ext-diff", "--no-textconv", "--color=never", "--max-count=100" });

    var index: usize = 0;
    while (index < arguments.len and !std.mem.eql(u8, arguments[index], "--")) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "-n")) {
            if (index + 1 >= arguments.len or !boundedDecimal(arguments[index + 1], max_git_log_count)) {
                return .{ .approval_required = .unsupported_argument };
            }
            try argv.appendSlice(alloc, arguments[index .. index + 2]);
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--max-count=")) {
            if (!boundedDecimal(argument["--max-count=".len..], max_git_log_count)) {
                return .{ .approval_required = .unsupported_argument };
            }
            try argv.append(alloc, argument);
            continue;
        }
        if (!(std.mem.eql(u8, argument, "--oneline") or
            std.mem.eql(u8, argument, "--stat") or
            std.mem.eql(u8, argument, "--shortstat") or
            std.mem.eql(u8, argument, "--name-only") or
            std.mem.eql(u8, argument, "--name-status") or
            std.mem.eql(u8, argument, "--no-merges") or
            std.mem.eql(u8, argument, "--decorate") or
            std.mem.eql(u8, argument, "--decorate=short") or
            std.mem.eql(u8, argument, "--decorate=no")))
        {
            return .{ .approval_required = .unsupported_argument };
        }
        try argv.append(alloc, argument);
    }
    const operands = if (index < arguments.len) arguments[index + 1 ..] else &.{};
    if (operands.len > max_git_pathspecs) {
        return .{ .approval_required = .unsupported_argument };
    }
    try argv.append(alloc, "--");
    try argv.appendSlice(alloc, operands);
    return directGit(try argv.toOwnedSlice(alloc));
}

fn boundedDecimal(value: []const u8, maximum: usize) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return false;
    return parsed <= maximum;
}

fn isFilesystemMutation(command: []const u8) bool {
    return std.mem.eql(u8, command, "touch") or
        std.mem.eql(u8, command, "rm") or
        std.mem.eql(u8, command, "mkdir") or
        std.mem.eql(u8, command, "rmdir") or
        std.mem.eql(u8, command, "mv") or
        std.mem.eql(u8, command, "cp") or
        std.mem.eql(u8, command, "install") or
        std.mem.eql(u8, command, "chmod") or
        std.mem.eql(u8, command, "chown") or
        std.mem.eql(u8, command, "ln");
}

fn isNetworkCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "curl") or
        std.mem.eql(u8, command, "wget") or
        std.mem.eql(u8, command, "ssh") or
        std.mem.eql(u8, command, "scp") or
        std.mem.eql(u8, command, "nc");
}

fn isProcessOrSystemCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "sh") or
        std.mem.eql(u8, command, "bash") or
        std.mem.eql(u8, command, "zsh") or
        std.mem.eql(u8, command, "dash") or
        std.mem.eql(u8, command, "env") or
        std.mem.eql(u8, command, "xargs") or
        std.mem.eql(u8, command, "sudo") or
        std.mem.eql(u8, command, "doas") or
        std.mem.eql(u8, command, "kill") or
        std.mem.eql(u8, command, "pkill") or
        std.mem.eql(u8, command, "nohup");
}

fn ownPlan(
    alloc: std.mem.Allocator,
    command: []const u8,
    resolved_cwd: []const u8,
    temporary: []const TemporaryStage,
) std.mem.Allocator.Error!Admission {
    const owned_command = try alloc.dupe(u8, command);
    errdefer alloc.free(owned_command);
    const cwd = try alloc.dupe(u8, resolved_cwd);
    errdefer alloc.free(cwd);
    const stages = try alloc.alloc(DirectStage, temporary.len);
    var initialized: usize = 0;
    errdefer {
        for (stages[0..initialized]) |stage| {
            for (stage.argv) |arg| alloc.free(arg);
            alloc.free(stage.argv);
        }
        alloc.free(stages);
    }

    for (temporary, 0..) |stage, stage_index| {
        const argv = try alloc.alloc([]const u8, stage.argv.len);
        var argv_initialized: usize = 0;
        errdefer {
            for (argv[0..argv_initialized]) |arg| alloc.free(arg);
            alloc.free(argv);
        }
        for (stage.argv, 0..) |arg, arg_index| {
            argv[arg_index] = try alloc.dupe(u8, arg);
            argv_initialized += 1;
        }
        stages[stage_index] = .{
            .executable = stage.executable,
            .argv = argv,
            .environment_profile = stage.environment_profile,
        };
        initialized += 1;
    }

    return .{ .direct_read_only = .{
        .command = owned_command,
        .cwd = cwd,
        .stages = stages,
    } };
}
