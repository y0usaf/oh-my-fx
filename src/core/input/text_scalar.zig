const std = @import("std");

pub const Owner = enum {
    composer,
    question_freeform,
    approval_amendment,
};

pub const Scalar = struct {
    owner: Owner,
    bytes: [4]u8,
    len: usize,

    pub fn slice(self: *const Scalar) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const DropReason = enum {
    invalid_utf8,
    owner_changed,
};

pub const Drop = struct {
    reason: DropReason,
    owner: Owner,
    bytes: usize,
};

pub const Step = struct {
    scalar: ?Scalar = null,
    dropped: ?Drop = null,
};

pub const State = struct {
    owner: ?Owner = null,
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: usize = 0,
    expected_len: usize = 0,
};

pub const Transition = struct {
    next: State,
    step: Step,
};

pub const Pending = struct {
    owner: Owner,
    bytes: usize,
};

pub const ResetTransition = struct {
    next: State = .{},
    dropped: ?Pending = null,
};

pub fn hasPending(state: State) bool {
    return state.len > 0;
}

pub fn reset(state: State) ResetTransition {
    return .{
        .dropped = if (state.owner) |owner| .{
            .owner = owner,
            .bytes = state.len,
        } else null,
    };
}

pub fn advance(state: State, owner: Owner, byte: u8) Transition {
    if (state.owner != null and state.owner.? != owner) {
        const restarted = advance(.{}, owner, byte);
        var step = restarted.step;
        const restarted_drop_bytes = if (step.dropped) |drop| drop.bytes else 0;
        step.dropped = .{
            .reason = .owner_changed,
            .owner = state.owner.?,
            .bytes = state.len + restarted_drop_bytes,
        };
        return .{ .next = restarted.next, .step = step };
    }

    if (state.len == 0) {
        const expected_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            return .{
                .next = .{},
                .step = .{ .dropped = .{
                    .reason = .invalid_utf8,
                    .owner = owner,
                    .bytes = 1,
                } },
            };
        };
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        bytes[0] = byte;
        if (expected_len == 1) {
            return .{
                .next = .{},
                .step = .{ .scalar = .{ .owner = owner, .bytes = bytes, .len = 1 } },
            };
        }
        return .{
            .next = .{
                .owner = owner,
                .bytes = bytes,
                .len = 1,
                .expected_len = expected_len,
            },
            .step = .{},
        };
    }

    if (byte & 0xC0 != 0x80) {
        const restarted = advance(.{}, owner, byte);
        var step = restarted.step;
        const restarted_drop_bytes = if (step.dropped) |drop| drop.bytes else 0;
        step.dropped = .{
            .reason = .invalid_utf8,
            .owner = owner,
            .bytes = state.len + restarted_drop_bytes,
        };
        return .{ .next = restarted.next, .step = step };
    }

    var next = state;
    next.bytes[next.len] = byte;
    next.len += 1;
    if (next.len < next.expected_len) return .{ .next = next, .step = .{} };

    _ = std.unicode.utf8Decode(next.bytes[0..next.len]) catch {
        return .{
            .next = .{},
            .step = .{ .dropped = .{
                .reason = .invalid_utf8,
                .owner = owner,
                .bytes = next.len,
            } },
        };
    };
    return .{
        .next = .{},
        .step = .{ .scalar = .{ .owner = owner, .bytes = next.bytes, .len = next.len } },
    };
}
