const std = @import("std");
const process_supervisor = @import("process_supervisor.zig");

const Allocator = std.mem.Allocator;
const BackgroundLaunchPolicy = process_supervisor.BackgroundLaunchPolicy;
const StableBackgroundRecordId = process_supervisor.StableBackgroundRecordId;

pub const Identity = union(BackgroundLaunchPolicy) {
    process_local_long_lived: struct {
        display_id: u64,
    },
    durable_long_lived: Durable,
    saved_headless: Durable,

    const Durable = struct {
        display_id: u64,
        source_session_id: []u8,
        background_record_id: StableBackgroundRecordId,
    };

    pub fn displayId(self: Identity) u64 {
        return switch (self) {
            .process_local_long_lived => |value| value.display_id,
            .durable_long_lived, .saved_headless => |value| value.display_id,
        };
    }

    pub fn deinit(self: *Identity, alloc: Allocator) void {
        switch (self.*) {
            .process_local_long_lived => {},
            .durable_long_lived, .saved_headless => |value| {
                alloc.free(value.source_session_id);
            },
        }
        self.* = undefined;
    }

    pub fn eql(self: Identity, other: Identity) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) {
            return false;
        }
        return switch (self) {
            .process_local_long_lived => |value| switch (other) {
                .process_local_long_lived => |other_value| value.display_id == other_value.display_id,
                else => false,
            },
            .durable_long_lived => |value| switch (other) {
                .durable_long_lived => |other_value| durableEqual(value, other_value),
                else => false,
            },
            .saved_headless => |value| switch (other) {
                .saved_headless => |other_value| durableEqual(value, other_value),
                else => false,
            },
        };
    }
};

/// Caller owns the returned allocation.
pub fn format(alloc: Allocator, identity: Identity) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "launch_policy={s}\ndisplay_id={d}\n",
        .{ @tagName(identity), identity.displayId() },
    );
    switch (identity) {
        .process_local_long_lived => {},
        .durable_long_lived, .saved_headless => |durable| {
            var stable_id: [32]u8 = undefined;
            encodeRecordId(&stable_id, durable.background_record_id);
            try out.writer.print(
                "source_session_id={s}\n" ++
                    "background_record_id={s}\n",
                .{ durable.source_session_id, &stable_id },
            );
        },
    }
    return out.toOwnedSlice();
}

fn durableEqual(left: Identity.Durable, right: Identity.Durable) bool {
    return left.display_id == right.display_id and
        std.mem.eql(u8, left.source_session_id, right.source_session_id) and
        std.mem.eql(
            u8,
            &left.background_record_id,
            &right.background_record_id,
        );
}

fn encodeRecordId(
    out: *[32]u8,
    stable_id: StableBackgroundRecordId,
) void {
    const alphabet = "0123456789abcdef";
    for (stable_id, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}
