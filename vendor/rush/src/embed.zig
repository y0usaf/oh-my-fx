//! Headless embed root for omfx. The terminal engine owns all UI; this
//! module exposes only the persistent shell session.

const std = @import("std");

pub const host = @import("host.zig");
pub const shell = @import("shell.zig");
pub const Session = @import("host/EmbedSession.zig");

test {
    _ = Session;
}
