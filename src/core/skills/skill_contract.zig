const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const max_frontmatter_bytes: usize = 64 * 1024;
pub const max_name_bytes: usize = 256;
pub const max_description_bytes: usize = 4 * 1024;

pub const SkillSource = enum {
    workspace_fx,
    workspace_shared,
    workspace_opencode,
    workspace_codex,
    workspace_claude,
    workspace_agents,
    workspace_claw,
    global_fx,
    global_opencode,
    global_codex,
    global_claude,
    global_agents,
    global_claw,
};

/// One default skill root. `path` is relative to a workspace ancestor or the
/// home directory, depending on which table declares the spec.
pub const RootSpec = struct {
    source: SkillSource,
    path: []const u8,
};

/// Borrowed root policy supplied by a product capability owner.
pub const RootPolicy = struct {
    workspace_roots: []const RootSpec = &.{},
    /// Source identity for the managed install directory passed to discovery.
    /// A null source excludes that directory from the policy.
    managed_root_source: ?SkillSource,
    global_roots: []const RootSpec = &.{},
};

pub const InvalidMetadataCause = enum {
    missing_closing_delimiter,
    missing_name,
    duplicate_recognized_key,
    invalid_name,
    name_too_long,
    description_too_long,
    malformed_quote,
    unsupported_multiline,
    invalid_utf8,
    control_byte,
};

pub const MetadataStatus = union(enum) {
    no_frontmatter,
    valid,
    invalid: InvalidMetadataCause,
};

const BlockDescriptionStyle = enum {
    folded_clip,
    folded_strip,
    literal_clip,
};

pub const BlockDescription = struct {
    style: BlockDescriptionStyle,
    base_indent: usize,
    decoded_len: usize,

    fn decode_into(self: BlockDescription, raw: []const u8, output: []u8) void {
        std.debug.assert(output.len == self.decoded_len);
        const written = decode_block_description(raw, self.base_indent, self.style, output);
        std.debug.assert(written == output.len);
    }
};

pub const ParsedSkillFile = struct {
    name: ?[]const u8,
    description: ?[]const u8,
    description_block: ?BlockDescription = null,
    body: []const u8,
    status: MetadataStatus,
};

pub const SkillMetadata = struct {
    name: []const u8,
    description: []const u8,
    description_block: ?BlockDescription,

    pub fn description_len(self: SkillMetadata) usize {
        return if (self.description_block) |block| block.decoded_len else self.description.len;
    }

    pub fn write_description(self: SkillMetadata, output: []u8) void {
        std.debug.assert(output.len == self.description_len());
        if (self.description_block) |block| {
            block.decode_into(self.description, output);
        } else {
            @memcpy(output, self.description);
        }
    }
};

pub const SkillMetadataResult = union(enum) {
    valid: SkillMetadata,
    invalid: InvalidMetadataCause,
};

pub fn resolveMetadata(parsed: ParsedSkillFile, fallback_name: []const u8) SkillMetadataResult {
    return switch (parsed.status) {
        .no_frontmatter => if (invalidSkillNameCause(fallback_name)) |cause|
            .{ .invalid = cause }
        else
            .{ .valid = .{ .name = fallback_name, .description = "", .description_block = null } },
        .valid => .{ .valid = .{
            .name = parsed.name.?,
            .description = parsed.description orelse "",
            .description_block = parsed.description_block,
        } },
        .invalid => |cause| .{ .invalid = cause },
    };
}

pub fn parseSkillFile(content: []const u8) ParsedSkillFile {
    const header_start = frontmatterHeaderStart(content) orelse {
        return .{
            .name = null,
            .description = null,
            .body = content,
            .status = .no_frontmatter,
        };
    };
    const closing = findClosingDelimiter(content, header_start) orelse {
        return .{
            .name = null,
            .description = null,
            .body = content,
            .status = .{ .invalid = .missing_closing_delimiter },
        };
    };

    const header = content[header_start..closing.header_end];
    const body = std.mem.trimStart(u8, content[closing.body_start..], "\r\n");

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var description_block: ?BlockDescription = null;
    var invalid_cause: ?InvalidMetadataCause = null;
    var saw_name = false;
    var saw_description = false;
    var previous_line_recognized = false;

    var line_offset: usize = 0;
    while (headerLineAt(header, line_offset)) |line| {
        line_offset = line.next;
        const trimmed = std.mem.trim(u8, line.bytes, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (previous_line_recognized and (line.bytes[0] == ' ' or line.bytes[0] == '\t')) {
            setFirstInvalidCause(&invalid_cause, .unsupported_multiline);
            previous_line_recognized = false;
            continue;
        }

        const colon_idx = std.mem.find(u8, trimmed, ":") orelse {
            previous_line_recognized = false;
            continue;
        };
        const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
        const raw_value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t");

        if (std.mem.eql(u8, key, "name")) {
            previous_line_recognized = true;
            if (saw_name) setFirstInvalidCause(&invalid_cause, .duplicate_recognized_key);
            saw_name = true;
            const parsed_value = parseRecognizedValue(raw_value);
            name = parsed_value.value;
            if (parsed_value.invalid_cause) |cause| setFirstInvalidCause(&invalid_cause, cause);
        } else if (std.mem.eql(u8, key, "description")) {
            if (saw_description) setFirstInvalidCause(&invalid_cause, .duplicate_recognized_key);
            saw_description = true;
            if (block_description_style(raw_value)) |style| {
                const parsed_block = parse_block_description(header, line_offset, style);
                description = parsed_block.value;
                description_block = parsed_block.block;
                line_offset = parsed_block.next_offset;
                previous_line_recognized = false;
                if (parsed_block.invalid_cause) |cause| setFirstInvalidCause(&invalid_cause, cause);
            } else {
                previous_line_recognized = true;
                const parsed_value = parseRecognizedValue(raw_value);
                description = parsed_value.value;
                description_block = null;
                if (parsed_value.invalid_cause) |cause| setFirstInvalidCause(&invalid_cause, cause);
            }
        } else {
            previous_line_recognized = false;
        }
    }

    if (name) |skill_name| {
        if (invalidSkillNameCause(skill_name)) |cause| setFirstInvalidCause(&invalid_cause, cause);
    } else {
        setFirstInvalidCause(&invalid_cause, .missing_name);
    }
    if (description_block == null) {
        if (description) |skill_description| {
            if (skill_description.len > max_description_bytes) {
                setFirstInvalidCause(&invalid_cause, .description_too_long);
            } else if (invalidTextCause(skill_description)) |cause| {
                setFirstInvalidCause(&invalid_cause, cause);
            }
        }
    }
    if (invalid_cause != null) description_block = null;

    return .{
        .name = name,
        .description = description,
        .description_block = description_block,
        .body = body,
        .status = if (invalid_cause) |cause| .{ .invalid = cause } else .valid,
    };
}

const HeaderLine = struct {
    start: usize,
    bytes: []const u8,
    next: usize,
};

fn headerLineAt(header: []const u8, start: usize) ?HeaderLine {
    if (start >= header.len) return null;
    const newline_offset = std.mem.findScalar(u8, header[start..], '\n');
    const line_end = if (newline_offset) |offset| start + offset else header.len;
    const raw_line = header[start..line_end];
    const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
        raw_line[0 .. raw_line.len - 1]
    else
        raw_line;
    return .{
        .start = start,
        .bytes = line,
        .next = if (newline_offset != null) line_end + 1 else line_end,
    };
}

const ParsedBlockDescription = struct {
    value: []const u8,
    block: BlockDescription,
    next_offset: usize,
    invalid_cause: ?InvalidMetadataCause,
};

fn parse_block_description(header: []const u8, start: usize, style: BlockDescriptionStyle) ParsedBlockDescription {
    var base_indent: ?usize = null;
    var invalid_cause: ?InvalidMetadataCause = null;
    var can_decode = true;
    var line_offset = start;
    var block_end = header.len;

    while (headerLineAt(header, line_offset)) |line| {
        line_offset = line.next;
        if (is_structural_blank(line.bytes)) continue;

        const indent = leading_space_count(line.bytes);
        if (indent == 0) {
            if (line.bytes[0] == '\t') {
                setFirstInvalidCause(&invalid_cause, .unsupported_multiline);
                can_decode = false;
                continue;
            }
            block_end = line.start;
            line_offset = line.start;
            break;
        }
        if (indent < line.bytes.len and line.bytes[indent] == '\t') {
            setFirstInvalidCause(&invalid_cause, .unsupported_multiline);
            can_decode = false;
            continue;
        }

        if (base_indent) |established_indent| {
            if (indent < established_indent) {
                setFirstInvalidCause(&invalid_cause, .unsupported_multiline);
                can_decode = false;
                continue;
            }
        } else {
            base_indent = indent;
        }

        const content_line = line.bytes[base_indent.?..];
        if (invalidTextCause(content_line)) |cause| setFirstInvalidCause(&invalid_cause, cause);
    }

    const raw_value = header[start..block_end];
    const decoded_len = if (can_decode)
        decode_block_description(raw_value, base_indent orelse 0, style, null)
    else
        0;
    if (decoded_len > max_description_bytes) {
        setFirstInvalidCause(&invalid_cause, .description_too_long);
    }

    return .{
        .value = raw_value,
        .block = .{
            .style = style,
            .base_indent = base_indent orelse 0,
            .decoded_len = decoded_len,
        },
        .next_offset = line_offset,
        .invalid_cause = invalid_cause,
    };
}

fn block_description_style(value: []const u8) ?BlockDescriptionStyle {
    if (std.mem.eql(u8, value, ">")) return .folded_clip;
    if (std.mem.eql(u8, value, ">-")) return .folded_strip;
    if (std.mem.eql(u8, value, "|")) return .literal_clip;
    return null;
}

fn is_structural_blank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn leading_space_count(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

const DescriptionEmitter = struct {
    output: ?[]u8,
    len: usize = 0,

    fn write(self: *DescriptionEmitter, value: []const u8) void {
        const end = std.math.add(usize, self.len, value.len) catch std.math.maxInt(usize);
        if (self.output) |output| {
            std.debug.assert(end <= output.len);
            @memcpy(output[self.len..end], value);
        }
        self.len = end;
    }
};

fn decode_block_description(
    raw: []const u8,
    base_indent: usize,
    style: BlockDescriptionStyle,
    output: ?[]u8,
) usize {
    var last_nonblank_next: usize = 0;
    var line_offset: usize = 0;
    while (headerLineAt(raw, line_offset)) |line| {
        line_offset = line.next;
        if (!is_structural_blank(line.bytes)) last_nonblank_next = line.next;
    }
    if (last_nonblank_next == 0) return 0;

    var emitter: DescriptionEmitter = .{ .output = output };
    var previous_nonblank = false;
    var first = true;
    line_offset = 0;
    while (line_offset < last_nonblank_next) {
        const line = headerLineAt(raw, line_offset) orelse break;
        line_offset = line.next;
        const nonblank = !is_structural_blank(line.bytes);
        if (!first) {
            const separator = switch (style) {
                .literal_clip => "\n",
                .folded_clip, .folded_strip => if (previous_nonblank and nonblank) " " else "\n",
            };
            emitter.write(separator);
        }
        if (nonblank) emitter.write(line.bytes[base_indent..]);
        previous_nonblank = nonblank;
        first = false;
    }
    switch (style) {
        .folded_clip, .literal_clip => emitter.write("\n"),
        .folded_strip => {},
    }
    return emitter.len;
}

const ClosingDelimiter = struct {
    header_end: usize,
    body_start: usize,
};

pub fn frontmatterHeaderStart(content: []const u8) ?usize {
    if (std.mem.startsWith(u8, content, "---\r\n")) return 5;
    if (std.mem.startsWith(u8, content, "---\n")) return 4;
    if (std.mem.eql(u8, content, "---")) return 3;
    return null;
}

const SkillMetadataScanner = struct {
    offset: usize,
    line_prefix: [4]u8 = undefined,
    line_len: usize = 0,

    fn init(header_start: usize) SkillMetadataScanner {
        return .{ .offset = header_start };
    }

    fn scan(self: *SkillMetadataScanner, content: []const u8, complete: bool) bool {
        while (self.offset < content.len) {
            const byte = content[self.offset];
            self.offset += 1;
            if (byte == '\n') {
                const closing = self.isClosingLine(true);
                self.line_len = 0;
                if (closing) return true;
                continue;
            }
            if (self.line_len < self.line_prefix.len) {
                self.line_prefix[self.line_len] = byte;
            }
            self.line_len += 1;
        }
        return complete and self.isClosingLine(false);
    }

    fn isClosingLine(self: SkillMetadataScanner, newline_terminated: bool) bool {
        if (self.line_len == 3 and std.mem.eql(u8, self.line_prefix[0..3], "---")) return true;
        return newline_terminated and
            self.line_len == 4 and
            std.mem.eql(u8, self.line_prefix[0..4], "---\r");
    }
};

pub fn readMetadataPrefix(alloc: std.mem.Allocator, file: *std.Io.File, file_size: usize) ![]u8 {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    const readable_size = @min(file_size, max_frontmatter_bytes + 1);
    var scanner: ?SkillMetadataScanner = null;
    var metadata_complete = false;

    while (content.items.len < readable_size) {
        const wanted = @min(chunk.len, readable_size - content.items.len);
        const read = try file.readPositionalAll(io_mod.getIo(), chunk[0..wanted], content.items.len);
        if (read == 0) return error.UnexpectedEndOfFile;
        try content.appendSlice(alloc, chunk[0..read]);

        const file_complete = content.items.len == file_size;
        if (scanner == null) {
            if (content.items.len < 5 and !file_complete) continue;
            const header_start = frontmatterHeaderStart(content.items) orelse {
                metadata_complete = true;
                break;
            };
            scanner = SkillMetadataScanner.init(header_start);
        }
        if (scanner.?.scan(content.items, file_complete)) {
            metadata_complete = true;
            break;
        }
    }
    if (!metadata_complete and content.items.len < file_size) return error.StreamTooLong;
    return try content.toOwnedSlice(alloc);
}

fn findClosingDelimiter(content: []const u8, header_start: usize) ?ClosingDelimiter {
    var line_start = header_start;
    while (line_start <= content.len) {
        const newline_offset = std.mem.findScalar(u8, content[line_start..], '\n');
        const line_end = if (newline_offset) |offset| line_start + offset else content.len;
        const raw_line = content[line_start..line_end];
        const line = if (newline_offset != null and raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        if (std.mem.eql(u8, line, "---")) {
            return .{
                .header_end = line_start,
                .body_start = if (newline_offset != null) line_end + 1 else line_end,
            };
        }
        if (newline_offset == null) return null;
        line_start = line_end + 1;
    }
    return null;
}

const ParsedRecognizedValue = struct {
    value: []const u8,
    invalid_cause: ?InvalidMetadataCause = null,
};

fn parseRecognizedValue(value: []const u8) ParsedRecognizedValue {
    if (value.len > 0 and (value[0] == '|' or value[0] == '>')) {
        return .{ .value = value, .invalid_cause = .unsupported_multiline };
    }

    const starts_with_quote = value.len > 0 and (value[0] == '\'' or value[0] == '"');
    const ends_with_quote = value.len > 0 and (value[value.len - 1] == '\'' or value[value.len - 1] == '"');
    if (starts_with_quote or ends_with_quote) {
        if (value.len >= 2 and value[0] == value[value.len - 1]) {
            return .{ .value = value[1 .. value.len - 1] };
        }
        return .{ .value = value, .invalid_cause = .malformed_quote };
    }
    return .{ .value = value };
}

fn setFirstInvalidCause(current: *?InvalidMetadataCause, cause: InvalidMetadataCause) void {
    if (current.* == null) current.* = cause;
}

fn invalidTextCause(value: []const u8) ?InvalidMetadataCause {
    if (!std.unicode.utf8ValidateSlice(value)) return .invalid_utf8;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return .control_byte;
    }
    return null;
}

pub fn invalidSkillNameCause(name: []const u8) ?InvalidMetadataCause {
    if (name.len == 0) return .missing_name;
    if (name.len > max_name_bytes) return .name_too_long;
    if (invalidTextCause(name)) |cause| return cause;
    validateManagedSkillName(name) catch return .invalid_name;
    return null;
}

pub fn validateManagedSkillName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidSkillName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidSkillName;
    if (std.fs.path.isAbsolute(name)) return error.InvalidSkillName;
    if (std.mem.findScalar(u8, name, '/') != null) return error.InvalidSkillName;
    if (std.mem.findScalar(u8, name, '\\') != null) return error.InvalidSkillName;
}

fn expectResolvedDescription(content: []const u8, expected: []const u8) !void {
    const metadata = switch (resolveMetadata(parseSkillFile(content), "fallback")) {
        .valid => |value| value,
        .invalid => return error.TestExpectedValidMetadata,
    };
    const description = try std.testing.allocator.alloc(u8, metadata.description_len());
    defer std.testing.allocator.free(description);
    metadata.write_description(description);
    try std.testing.expectEqualStrings(expected, description);
}

fn fuzzParseSkillFile(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const input = buffer[0..len];
    const parsed = parseSkillFile(input);

    try expectBorrowedSlice(input, parsed.body);
    if (parsed.name) |name| try expectBorrowedSlice(input, name);
    if (parsed.description) |description| {
        try expectBorrowedSlice(input, description);
        if (parsed.description_block) |block| {
            try std.testing.expect(block.decoded_len <= max_description_bytes);
            var decoded: [max_description_bytes]u8 = undefined;
            block.decode_into(description, decoded[0..block.decoded_len]);
        }
    }
}

fn expectBorrowedSlice(input: []const u8, borrowed: []const u8) !void {
    const input_start = @intFromPtr(input.ptr);
    const input_end = input_start + input.len;
    const borrowed_start = @intFromPtr(borrowed.ptr);
    const borrowed_end = borrowed_start + borrowed.len;
    try std.testing.expect(borrowed_start >= input_start);
    try std.testing.expect(borrowed_end <= input_end);
}
