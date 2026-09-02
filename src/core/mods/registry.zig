const std = @import("std");

/// Registry for tool-like capabilities keyed by stable public name.
pub fn ToolRegistry(comptime Tool: type) type {
    return struct {
        const Self = @This();

        tools: []const Tool = &.{},

        /// Looks up a tool by name. Duplicate registry names are a programmer bug.
        pub fn lookup(self: Self, name: []const u8) ?*const Tool {
            for (self.tools) |*tool| {
                if (std.mem.eql(u8, tool.name, name)) return tool;
            }
            return null;
        }
    };
}

/// Registry for command-like capabilities keyed by a public command token and aliases.
pub fn CommandRegistry(comptime Command: type) type {
    return struct {
        const Self = @This();

        pub const Match = struct {
            command: *const Command,
            token: []const u8,
        };

        commands: []const Command = &.{},

        pub fn lookup(self: Self, command: []const u8) ?*const Command {
            const matched = self.matchExact(command) orelse return null;
            return matched.command;
        }

        pub fn matchExact(self: Self, command: []const u8) ?Match {
            for (self.commands) |*entry| {
                if (matchesCommandToken(command, entry.command)) return .{ .command = entry, .token = entry.command };
                for (entry.aliases) |alias| {
                    if (matchesCommandToken(command, alias)) return .{ .command = entry, .token = alias };
                }
            }
            return null;
        }

        pub fn matchEntryPrefix(self: Self, command: []const u8, entry: *const Command) ?[]const u8 {
            for (self.commands) |*candidate| {
                if (candidate != entry) continue;
                if (startsWithCommandPrefix(command, candidate.command)) return candidate.command;
                for (candidate.aliases) |alias| {
                    if (startsWithCommandPrefix(command, alias)) return alias;
                }
                return null;
            }
            return null;
        }

        fn matchesCommandToken(input: []const u8, command: []const u8) bool {
            if (std.mem.eql(u8, input, command)) return true;

            if (input.len == 0) return false;
            const last = input[input.len - 1];
            if (last != ' ' and last != '\t') return false;

            const trimmed = std.mem.trimEnd(u8, input, " \t");
            return std.mem.eql(u8, trimmed, command);
        }

        fn startsWithCommandPrefix(input: []const u8, command: []const u8) bool {
            if (!std.mem.startsWith(u8, input, command)) return false;
            return input.len == command.len or input[command.len] == ' ' or input[command.len] == '\t';
        }
    };
}
