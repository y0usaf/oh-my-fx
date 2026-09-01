//! Source identity and locations for shell diagnostics.

const std = @import("std");

pub const SourceId = u32;

pub const SourceKind = enum {
    command_string,
    standard_input,
    script_file,
    sourced_file,
    interactive,
};

pub const Source = struct {
    id: SourceId,
    kind: SourceKind,
    name: []const u8,
    text: []const u8,

    pub fn validate(self: Source) void {
        std.debug.assert(self.name.len != 0);
    }
};

pub const Position = struct {
    source_id: SourceId = 0,
    byte_offset: usize = 0,
    line: usize = 1,
    column: usize = 1,

    pub fn advance(self: *Position, bytes: []const u8) void {
        for (bytes) |byte| {
            self.byte_offset += 1;
            if (byte == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
        }
    }
};

pub const Span = struct {
    source_id: SourceId = 0,
    start: usize = 0,
    end: usize = 0,
    start_line: usize = 1,
    start_column: usize = 1,

    pub fn init(start: Position, end_offset: usize) Span {
        std.debug.assert(end_offset >= start.byte_offset);
        const span: Span = .{
            .source_id = start.source_id,
            .start = start.byte_offset,
            .end = end_offset,
            .start_line = start.line,
            .start_column = start.column,
        };
        span.validate();
        return span;
    }

    pub fn validate(self: Span) void {
        std.debug.assert(self.end >= self.start);
        std.debug.assert(self.start_line != 0);
        std.debug.assert(self.start_column != 0);
    }

    pub fn len(self: Span) usize {
        self.validate();
        return self.end - self.start;
    }

    pub fn isEmpty(self: Span) bool {
        return self.len() == 0;
    }
};
