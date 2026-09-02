const std = @import("std");

pub const Profile = enum {
    clean,
    user,
};

/// Captured-command startup semantics bound into permission admission.
///
/// The shell path is part of explicit native profiles so execution cannot
/// silently switch environments after permission has been granted.
pub const Environment = union(enum) {
    legacy,
    clean: []const u8,
    user: []const u8,
    workspace_clean,

    pub fn eql(self: Environment, other: Environment) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .legacy, .workspace_clean => true,
            .clean => |path| std.mem.eql(u8, path, other.clean),
            .user => |path| std.mem.eql(u8, path, other.user),
        };
    }

    pub fn requiresShellRoute(self: Environment) bool {
        return switch (self) {
            .clean, .user => true,
            .legacy, .workspace_clean => false,
        };
    }
};

const permission_identity_prefix = "@fx-terminal-env:";

pub fn isExplicitPermissionCommandIdentity(value: []const u8) bool {
    return std.mem.startsWith(u8, value, permission_identity_prefix);
}

/// Binds shell startup to a retained command grant. Legacy callers keep the
/// plain-command identity; terminal profile calls bind the selected shell.
pub fn permissionCommandIdentity(
    alloc: std.mem.Allocator,
    environment: Environment,
    command: []const u8,
) ![]u8 {
    return switch (environment) {
        .legacy, .workspace_clean => alloc.dupe(u8, command),
        .clean => |path| formatPermissionCommandIdentity(alloc, "clean", path, command),
        .user => |path| formatPermissionCommandIdentity(alloc, "user", path, command),
    };
}

fn formatPermissionCommandIdentity(
    alloc: std.mem.Allocator,
    profile: []const u8,
    shell_path: []const u8,
    command: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        permission_identity_prefix ++ "{s}:{d}:{s}::{s}",
        .{ profile, shell_path.len, shell_path, command },
    );
}

/// Removes the opaque environment prefix only for configured permission-rule
/// matching and human-facing policy display. Session grants retain it.
pub fn commandFromPermissionIdentity(identity: []const u8) []const u8 {
    if (!isExplicitPermissionCommandIdentity(identity)) return identity;
    var rest = identity[permission_identity_prefix.len..];
    const profile_end = std.mem.findScalar(u8, rest, ':') orelse return identity;
    rest = rest[profile_end + 1 ..];
    const length_end = std.mem.findScalar(u8, rest, ':') orelse return identity;
    const shell_len = std.fmt.parseInt(usize, rest[0..length_end], 10) catch return identity;
    rest = rest[length_end + 1 ..];
    if (shell_len > rest.len or rest.len - shell_len < 2) return identity;
    if (!std.mem.eql(u8, rest[shell_len .. shell_len + 2], "::")) return identity;
    return rest[shell_len + 2 ..];
}

pub fn formatApprovalCommand(
    alloc: std.mem.Allocator,
    environment: Environment,
    command: []const u8,
) ![]u8 {
    return switch (environment) {
        .legacy => std.fmt.allocPrint(
            alloc,
            "# terminal.exec profile=omitted (legacy)\n{s}",
            .{command},
        ),
        .workspace_clean => std.fmt.allocPrint(
            alloc,
            "# terminal.exec profile=clean workspace=root-fixed\n{s}",
            .{command},
        ),
        .clean => |path| std.fmt.allocPrint(
            alloc,
            "# terminal.exec profile=clean shell={s}\n{s}",
            .{ path, command },
        ),
        .user => |path| std.fmt.allocPrint(
            alloc,
            "# terminal.exec profile=user shell={s}\n{s}",
            .{ path, command },
        ),
    };
}

pub const Host = enum {
    native,
    workspace_clean,
};
