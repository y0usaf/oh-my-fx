//! Tokens produced by the shell lexer.

const std = @import("std");

const source = @import("source.zig");

pub const Kind = enum {
    word,
    newline,
    semicolon,
    double_semicolon,
    semicolon_ampersand,
    double_semicolon_ampersand,
    ampersand,
    ampersand_greater,
    ampersand_greater_greater,
    pipe,
    pipe_ampersand,
    pipe_pipe,
    ampersand_ampersand,
    bang,
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    less,
    less_less,
    less_less_dash,
    less_less_less,
    less_ampersand,
    less_greater,
    greater,
    greater_greater,
    greater_ampersand,
    clobber,
    io_number,
    /// Processed here-document body emitted after the newline that starts
    /// it. The span covers the raw body including the delimiter line; the
    /// text holds the body with <tab> stripping already applied and the
    /// delimiter line excluded. `quoted` records a quoted delimiter, which
    /// suppresses expansion of the body.
    here_doc_body,
    /// A here-document body whose delimiter line was not found before the
    /// end of input; the body runs to the end of the input.
    here_doc_body_unterminated,
    eof,
};

pub const ReservedWord = enum {
    if_kw,
    then_kw,
    else_kw,
    elif_kw,
    fi_kw,
    do_kw,
    done_kw,
    case_kw,
    esac_kw,
    while_kw,
    until_kw,
    for_kw,
    in_kw,
    function_kw,
};

const ReservedWordMap = std.StaticStringMap(ReservedWord);

pub const reserved_words: ReservedWordMap = .initComptime(.{
    .{ "case", .case_kw },
    .{ "do", .do_kw },
    .{ "done", .done_kw },
    .{ "elif", .elif_kw },
    .{ "else", .else_kw },
    .{ "esac", .esac_kw },
    .{ "fi", .fi_kw },
    .{ "for", .for_kw },
    .{ "function", .function_kw },
    .{ "if", .if_kw },
    .{ "in", .in_kw },
    .{ "then", .then_kw },
    .{ "until", .until_kw },
    .{ "while", .while_kw },
});

pub fn lookupReservedWord(text: []const u8) ?ReservedWord {
    return reserved_words.get(text);
}

/// True when the reserved word is followed by a command list, so the next
/// word is back in command position.
pub fn reservedWordStartsCommandList(reserved: ReservedWord) bool {
    return switch (reserved) {
        .if_kw, .then_kw, .else_kw, .elif_kw, .do_kw, .while_kw, .until_kw => true,
        else => false,
    };
}

/// True when the token ends the current command so the next word is in
/// command position.
pub fn startsCommandPosition(kind: Kind) bool {
    return switch (kind) {
        .newline,
        .semicolon,
        .ampersand,
        .ampersand_greater,
        .ampersand_greater_greater,
        .pipe,
        .pipe_ampersand,
        .pipe_pipe,
        .ampersand_ampersand,
        .bang,
        .left_paren,
        .right_paren,
        .left_brace,
        .here_doc_body,
        .here_doc_body_unterminated,
        => true,
        else => false,
    };
}

/// True when the token is a redirection operator whose next word is the
/// redirection target rather than command text.
pub fn isRedirectionOperator(kind: Kind) bool {
    return switch (kind) {
        .less,
        .less_less,
        .less_less_dash,
        .less_less_less,
        .less_ampersand,
        .less_greater,
        .greater,
        .greater_greater,
        .greater_ampersand,
        .ampersand_greater,
        .ampersand_greater_greater,
        .clobber,
        => true,
        else => false,
    };
}

/// True when the raw word text has the shape of a shell assignment word
/// (`NAME=...` or the Bash-compatible `NAME+=...`).
pub fn isAssignmentWord(text: []const u8) bool {
    const equals_index = std.mem.indexOfScalar(u8, text, '=') orelse return false;
    const name_end = if (equals_index > 0 and text[equals_index - 1] == '+') equals_index - 1 else equals_index;
    const name = text[0..name_end];
    if (name.len == 0) return false;
    if (!isNameStart(name[0])) return false;
    for (name[1..]) |byte| if (!isNameContinue(byte)) return false;
    return true;
}

fn isNameStart(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn isNameContinue(byte: u8) bool {
    return isNameStart(byte) or switch (byte) {
        '0'...'9' => true,
        else => false,
    };
}

/// Walks a token stream and classifies each word by its grammatical role.
/// This is the single shared notion of "command position" used by the
/// interactive diagnostics and completion analysis.
///
/// Reserved words are only recognized in command position, matching the
/// grammar rather than the lexer's lexical marking. IO numbers preserve
/// command position because redirections may precede the command word.
pub const CommandPositionTracker = struct {
    command_position: bool = true,
    skip_redirection_target: bool = false,

    pub const Class = enum {
        /// Word in command position: the command name of its command.
        command,
        /// Assignment word before the command name; command position persists.
        assignment,
        /// Reserved word recognized in command position.
        reserved,
        /// Word in argument position.
        argument,
        /// Word consumed as the target of a preceding redirection operator.
        redirection_target,
        /// Any non-word token.
        operator,
    };

    pub fn classify(self: *CommandPositionTracker, tok: Token) Class {
        if (tok.kind == .word) {
            if (self.skip_redirection_target) {
                self.skip_redirection_target = false;
                return .redirection_target;
            }
            if (!self.command_position) return .argument;
            if (tok.reserved) |reserved| {
                self.command_position = reservedWordStartsCommandList(reserved);
                return .reserved;
            }
            if (isAssignmentWord(tok.text)) return .assignment;
            self.command_position = false;
            return .command;
        }
        if (tok.kind == .io_number) return .operator;
        if (isRedirectionOperator(tok.kind)) {
            self.skip_redirection_target = true;
            return .operator;
        }
        self.command_position = startsCommandPosition(tok.kind);
        return .operator;
    }
};

pub const Token = struct {
    kind: Kind,
    span: source.Span,
    text: []const u8 = "",
    reserved: ?ReservedWord = null,
    quoted: bool = false,

    pub fn validate(self: Token) void {
        self.span.validate();
        if (self.reserved != null) {
            std.debug.assert(self.kind == .word);
            std.debug.assert(!self.quoted);
            std.debug.assert(self.text.len != 0);
        }
        switch (self.kind) {
            .word, .io_number => std.debug.assert(self.text.len != 0),
            .here_doc_body, .here_doc_body_unterminated => {},
            else => std.debug.assert(!self.quoted),
        }
    }
};

const test_lexer = @import("lexer.zig");

test "command position tracker classifies assignments redirections and segments" {
    const src = "FOO=bar cached < nope; if tr";
    const source_file: source.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = src };
    const tokens = try test_lexer.lex(std.testing.allocator, source_file);
    defer std.testing.allocator.free(tokens);

    var tracker: CommandPositionTracker = .{};
    var classes: std.ArrayList(CommandPositionTracker.Class) = .empty;
    defer classes.deinit(std.testing.allocator);
    for (tokens) |tok| {
        if (tok.kind == .eof) break;
        try classes.append(std.testing.allocator, tracker.classify(tok));
    }

    const expected = [_]CommandPositionTracker.Class{
        .assignment, // FOO=bar
        .command, // cached
        .operator, // <
        .redirection_target, // nope
        .operator, // ;
        .reserved, // if
        .command, // tr
    };
    try std.testing.expectEqualSlices(CommandPositionTracker.Class, &expected, classes.items);
}

test "command position tracker treats reserved words as arguments outside command position" {
    const src = "echo if foo";
    const source_file: source.Source = .{ .id = 1, .kind = .command_string, .name = "-c", .text = src };
    const tokens = try test_lexer.lex(std.testing.allocator, source_file);
    defer std.testing.allocator.free(tokens);

    var tracker: CommandPositionTracker = .{};
    try std.testing.expectEqual(CommandPositionTracker.Class.command, tracker.classify(tokens[0]));
    try std.testing.expectEqual(CommandPositionTracker.Class.argument, tracker.classify(tokens[1]));
    try std.testing.expectEqual(CommandPositionTracker.Class.argument, tracker.classify(tokens[2]));
}

test "reserved word lookup uses static map" {
    try std.testing.expectEqual(ReservedWord.if_kw, lookupReservedWord("if").?);
    try std.testing.expectEqual(ReservedWord.then_kw, lookupReservedWord("then").?);
    try std.testing.expectEqual(ReservedWord.done_kw, lookupReservedWord("done").?);
    try std.testing.expectEqual(@as(?ReservedWord, null), lookupReservedWord("printf"));
}
