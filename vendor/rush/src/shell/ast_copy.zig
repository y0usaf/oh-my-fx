//! Deep copies persistent shell AST data.
//!
//! Nested data is duplicated into the supplied monotonic/definition allocator.
//! The output has that allocator's lifetime; the input need survive only the call.

const std = @import("std");

const ast = @import("ast.zig");

pub const Error = std.mem.Allocator.Error;

pub const CopiedFunction = struct {
    name: []const u8,
    source_name: []const u8,
    definition: ast.FunctionDefinition,
};

pub fn copyFunction(
    allocator: std.mem.Allocator,
    definition: ast.FunctionDefinition,
    source_name: []const u8,
) Error!CopiedFunction {
    const copied_name = try allocator.dupe(u8, definition.name);
    errdefer allocator.free(copied_name);
    const copied_source_name = try allocator.dupe(u8, source_name);
    errdefer allocator.free(copied_source_name);
    return .{
        .name = copied_name,
        .source_name = copied_source_name,
        .definition = .{
            .name = copied_name,
            .body = try copyCompoundCommand(allocator, definition.body),
            .redirections = try copyRedirections(allocator, definition.redirections),
        },
    };
}

fn copyList(allocator: std.mem.Allocator, list: ast.List) Error!ast.List {
    const entries = try allocator.alloc(ast.ListEntry, list.entries.len);
    for (list.entries, 0..) |entry, index| {
        entries[index] = .{
            .and_or = try copyAndOr(allocator, entry.and_or),
            .terminator = entry.terminator,
        };
    }
    return .{ .entries = entries };
}

fn copyAndOr(allocator: std.mem.Allocator, and_or: ast.AndOr) Error!ast.AndOr {
    const pipelines = try allocator.alloc(ast.AndOrPipeline, and_or.pipelines.len);
    for (and_or.pipelines, 0..) |pipeline, index| {
        pipelines[index] = .{
            .operator = pipeline.operator,
            .pipeline = try copyPipeline(allocator, pipeline.pipeline),
        };
    }
    return .{ .pipelines = pipelines };
}

fn copyPipeline(allocator: std.mem.Allocator, pipeline: ast.Pipeline) Error!ast.Pipeline {
    const stages = try allocator.alloc(ast.Command, pipeline.stages.len);
    for (pipeline.stages, 0..) |stage, index| stages[index] = try copyCommand(allocator, stage);
    return .{ .stages = stages, .negated = pipeline.negated };
}

fn copyCommand(allocator: std.mem.Allocator, command: ast.Command) Error!ast.Command {
    return switch (command) {
        .simple => |simple| .{ .simple = try copySimpleCommand(allocator, simple) },
        .compound => |compound| .{ .compound = try copyCompoundInvocation(allocator, compound) },
        // ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
        .function_definition => |definition| .{
            .function_definition = (try copyFunction(allocator, definition, "rush")).definition,
        },
    };
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn copyCompoundInvocation(allocator: std.mem.Allocator, invocation: ast.CompoundInvocation) Error!ast.CompoundInvocation {
    return .{
        .body = try copyCompoundCommand(allocator, invocation.body),
        .redirections = try copyRedirections(allocator, invocation.redirections),
    };
}

fn copyCompoundCommand(allocator: std.mem.Allocator, command: ast.CompoundCommand) Error!ast.CompoundCommand {
    return switch (command) {
        .brace_group => |list| .{ .brace_group = try copyList(allocator, list) },
        .subshell => |list| .{ .subshell = try copyList(allocator, list) },
        .if_command => |if_command| .{ .if_command = try copyIfCommand(allocator, if_command) },
        .loop => |loop| .{ .loop = try copyLoopCommand(allocator, loop) },
        .for_command => |for_command| .{ .for_command = try copyForCommand(allocator, for_command) },
        .c_for_command => |c_for_command| .{ .c_for_command = try copyCForCommand(allocator, c_for_command) },
        .arithmetic_command => |arithmetic_command| .{
            .arithmetic_command = try copyArithmeticCommand(allocator, arithmetic_command),
        },
        .conditional_command => |conditional_command| .{
            .conditional_command = try copyConditionalCommand(allocator, conditional_command),
        },
        .case_command => |case_command| .{ .case_command = try copyCaseCommand(allocator, case_command) },
    };
}

fn copySimpleCommand(allocator: std.mem.Allocator, command: ast.SimpleCommand) Error!ast.SimpleCommand {
    const assignments = try allocator.alloc(ast.Assignment, command.assignments.len);
    for (command.assignments, 0..) |assignment, index| {
        assignments[index] = .{
            .name = try allocator.dupe(u8, assignment.name),
            .value = try copyWord(allocator, assignment.value),
            .append = assignment.append,
            .index = if (assignment.index) |assignment_index| try copyWord(allocator, assignment_index) else null,
            .array_values = if (assignment.array_values) |values|
                try copyArrayAssignmentElements(allocator, values)
            else
                null,
            .span = assignment.span,
        };
    }

    const words = try copyWords(allocator, command.words);
    const redirections = try copyRedirections(allocator, command.redirections);
    return .{
        .assignments = assignments,
        .words = words,
        .redirections = redirections,
        .span = command.span,
    };
}

fn copyWords(allocator: std.mem.Allocator, words: []const ast.Word) Error![]const ast.Word {
    const copied = try allocator.alloc(ast.Word, words.len);
    for (words, 0..) |word, index| copied[index] = try copyWord(allocator, word);
    return copied;
}

fn copyWord(allocator: std.mem.Allocator, word: ast.Word) Error!ast.Word {
    return .{
        .data = switch (word.data) {
            .literal => |literal| .{ .literal = try allocator.dupe(u8, literal) },
            .parts => |parts| .{ .parts = try copyWordParts(allocator, parts) },
            .declaration_array_assignment => |assignment| .{
                .declaration_array_assignment = .{
                    .name = try allocator.dupe(u8, assignment.name),
                    .values = try copyArrayAssignmentElements(allocator, assignment.values),
                    .append = assignment.append,
                    .span = assignment.span,
                },
            },
        },
        .span = word.span,
        .quoted = word.quoted,
    };
}

fn copyArrayAssignmentElements(
    allocator: std.mem.Allocator,
    elements: []const ast.ArrayAssignmentElement,
) Error![]const ast.ArrayAssignmentElement {
    const copied = try allocator.alloc(ast.ArrayAssignmentElement, elements.len);
    for (elements, 0..) |element, index| {
        copied[index] = .{
            .index = if (element.index) |element_index| try copyWord(allocator, element_index) else null,
            .value = try copyWord(allocator, element.value),
            .span = element.span,
        };
    }
    return copied;
}

fn copyWordParts(allocator: std.mem.Allocator, parts: []const ast.WordPart) Error![]const ast.WordPart {
    const copied = try allocator.alloc(ast.WordPart, parts.len);
    for (parts, 0..) |part, index| {
        copied[index] = switch (part) {
            .literal => |bytes| .{ .literal = try allocator.dupe(u8, bytes) },
            .escaped => |bytes| .{ .escaped = try allocator.dupe(u8, bytes) },
            .single_quoted => |bytes| .{ .single_quoted = try allocator.dupe(u8, bytes) },
            .double_quoted => |nested| .{ .double_quoted = try copyWordParts(allocator, nested) },
            .parameter => |parameter| .{ .parameter = try copyParameterExpansion(allocator, parameter) },
            .command_substitution => |substitution| .{
                .command_substitution = try copyCommandSubstitution(allocator, substitution),
            },
            .process_substitution => |substitution| .{
                .process_substitution = try copyProcessSubstitution(allocator, substitution),
            },
            .arithmetic => |bytes| .{ .arithmetic = try allocator.dupe(u8, bytes) },
        };
    }
    return copied;
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn copyParameterExpansion(allocator: std.mem.Allocator, parameter: ast.ParameterExpansion) Error!ast.ParameterExpansion {
    return .{
        .parameter = try copyParameter(allocator, parameter.parameter),
        .length = parameter.length,
        .array_indices = parameter.array_indices,
        .colon = parameter.colon,
        .op = parameter.op,
        .word = if (parameter.word) |word| try copyWord(allocator, word) else null,
        .second_word = if (parameter.second_word) |word| try copyWord(allocator, word) else null,
        .span = parameter.span,
    };
}

fn copyParameter(allocator: std.mem.Allocator, parameter: ast.Parameter) Error!ast.Parameter {
    return switch (parameter) {
        .variable => |name| .{ .variable = try allocator.dupe(u8, name) },
        .array => |array| .{ .array = .{
            .name = try allocator.dupe(u8, array.name),
            .subscript = switch (array.subscript) {
                .index => |index| .{ .index = try copyWord(allocator, index) },
                .all => |special| .{ .all = special },
            },
        } },
        .positional => |position| .{ .positional = position },
        .special => |special| .{ .special = special },
    };
}

fn copyCommandSubstitution(
    allocator: std.mem.Allocator,
    substitution: ast.CommandSubstitution,
) Error!ast.CommandSubstitution {
    return .{
        .source_text = try allocator.dupe(u8, substitution.source_text),
        .parsed = if (substitution.parsed) |program| try copyProgramPtr(allocator, program.*) else null,
        .line_offset = substitution.line_offset,
    };
}

fn copyProcessSubstitution(
    allocator: std.mem.Allocator,
    substitution: ast.ProcessSubstitution,
) Error!ast.ProcessSubstitution {
    return .{
        .kind = substitution.kind,
        .source_text = try allocator.dupe(u8, substitution.source_text),
        .parsed = if (substitution.parsed) |program| try copyProgramPtr(allocator, program.*) else null,
        .line_offset = substitution.line_offset,
    };
}

fn copyProgramPtr(allocator: std.mem.Allocator, program: ast.Program) Error!*const ast.Program {
    const copied = try allocator.create(ast.Program);
    copied.* = .{ .source_id = program.source_id, .body = try copyList(allocator, program.body) };
    return copied;
}

// ziglint-ignore: Z024 preserve existing readable expression shape; lint-only cleanup
fn copyRedirections(allocator: std.mem.Allocator, redirections: []const ast.Redirection) Error![]const ast.Redirection {
    const copied = try allocator.alloc(ast.Redirection, redirections.len);
    for (redirections, 0..) |redirection, index| {
        copied[index] = .{
            .fd = redirection.fd,
            .op = redirection.op,
            .target = try copyWord(allocator, redirection.target),
            .here_doc = if (redirection.here_doc) |here_doc| .{
                .body = try allocator.dupe(u8, here_doc.body),
                .delimiter_quoted = here_doc.delimiter_quoted,
                .parts = try copyWordParts(allocator, here_doc.parts),
            } else null,
            .span = redirection.span,
        };
    }
    return copied;
}

fn copyIfCommand(allocator: std.mem.Allocator, command: ast.IfCommand) Error!ast.IfCommand {
    const branches = try allocator.alloc(ast.IfBranch, command.branches.len);
    for (command.branches, 0..) |branch, index| {
        branches[index] = .{
            .condition = try copyList(allocator, branch.condition),
            .body = try copyList(allocator, branch.body),
        };
    }
    return .{
        .branches = branches,
        .else_body = if (command.else_body) |body| try copyList(allocator, body) else null,
    };
}

fn copyLoopCommand(allocator: std.mem.Allocator, command: ast.LoopCommand) Error!ast.LoopCommand {
    return .{
        .kind = command.kind,
        .condition = try copyList(allocator, command.condition),
        .body = try copyList(allocator, command.body),
    };
}

fn copyForCommand(allocator: std.mem.Allocator, command: ast.ForCommand) Error!ast.ForCommand {
    return .{
        .name = try allocator.dupe(u8, command.name),
        .words = switch (command.words) {
            .positional_parameters => .positional_parameters,
            .words => |words| .{ .words = try copyWords(allocator, words) },
        },
        .body = try copyList(allocator, command.body),
    };
}

fn copyCForCommand(allocator: std.mem.Allocator, command: ast.CForCommand) Error!ast.CForCommand {
    return .{
        .init = if (command.init) |init| try allocator.dupe(u8, init) else null,
        .condition = if (command.condition) |condition| try allocator.dupe(u8, condition) else null,
        .update = if (command.update) |update| try allocator.dupe(u8, update) else null,
        .body = try copyList(allocator, command.body),
    };
}

fn copyArithmeticCommand(
    allocator: std.mem.Allocator,
    command: ast.ArithmeticCommand,
) Error!ast.ArithmeticCommand {
    return .{ .expression = try allocator.dupe(u8, command.expression) };
}

fn copyConditionalCommand(
    allocator: std.mem.Allocator,
    command: ast.ConditionalCommand,
) Error!ast.ConditionalCommand {
    return .{ .expression = try copyConditionalExpressionValue(allocator, command.expression) };
}

fn copyConditionalExpression(
    allocator: std.mem.Allocator,
    expression: ast.ConditionalExpression,
) Error!*const ast.ConditionalExpression {
    const copied = try allocator.create(ast.ConditionalExpression);
    copied.* = try copyConditionalExpressionValue(allocator, expression);
    return copied;
}

fn copyConditionalExpressionValue(
    allocator: std.mem.Allocator,
    expression: ast.ConditionalExpression,
) Error!ast.ConditionalExpression {
    return switch (expression) {
        .word => |word| .{ .word = try copyWord(allocator, word) },
        .unary_not => |nested| .{ .unary_not = try copyConditionalExpression(allocator, nested.*) },
        .unary_test => |test_expr| .{ .unary_test = .{
            .operator = test_expr.operator,
            .operand = try copyWord(allocator, test_expr.operand),
        } },
        .binary => |binary| .{ .binary = .{
            .operator = binary.operator,
            .left = try copyConditionalExpression(allocator, binary.left.*),
            .right = try copyConditionalExpression(allocator, binary.right.*),
        } },
        .comparison => |comparison| .{ .comparison = .{
            .operator = comparison.operator,
            .left = try copyWord(allocator, comparison.left),
            .right = try copyWord(allocator, comparison.right),
        } },
    };
}

fn copyCaseCommand(allocator: std.mem.Allocator, command: ast.CaseCommand) Error!ast.CaseCommand {
    const arms = try allocator.alloc(ast.CaseArm, command.arms.len);
    for (command.arms, 0..) |arm, index| {
        arms[index] = .{
            .patterns = try copyWords(allocator, arm.patterns),
            .body = try copyList(allocator, arm.body),
            .fallthrough = arm.fallthrough,
        };
    }
    return .{ .word = try copyWord(allocator, command.word), .arms = arms };
}
