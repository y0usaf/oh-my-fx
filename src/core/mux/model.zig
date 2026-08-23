const std = @import("std");

pub const Focus = enum { sidebar, terminal };

pub const Action = enum {
    none,
    focus_sidebar,
    focus_terminal,
    previous_session,
    next_session,
    new_session,
    archive_session,
    quit,
};

pub const Model = struct {
    selected: usize = 0,
    session_count: usize = 0,
    focus: Focus = .terminal,

    pub fn apply(self: *Model, action: Action) void {
        switch (action) {
            .none, .new_session, .archive_session, .quit => {},
            .focus_sidebar => self.focus = .sidebar,
            .focus_terminal => self.focus = .terminal,
            .previous_session => {
                if (self.session_count != 0) {
                    self.selected = if (self.selected == 0) self.session_count - 1 else self.selected - 1;
                }
            },
            .next_session => {
                if (self.session_count != 0) self.selected = (self.selected + 1) % self.session_count;
            },
        }
    }

    pub fn reconcile(self: *Model, count: usize) void {
        self.session_count = count;
        if (count == 0) {
            self.selected = 0;
        } else if (self.selected >= count) {
            self.selected = count - 1;
        }
    }
};

pub fn actionForByte(byte: u8) Action {
    return switch (byte) {
        0x07 => .focus_sidebar,
        0x0c => .focus_terminal,
        0x0b => .previous_session,
        0x0a => .next_session,
        0x0e => .new_session,
        0x11 => .quit,
        else => .none,
    };
}

test "mux model wraps session navigation and reconciles removal" {
    var model = Model{ .session_count = 3 };
    model.apply(.previous_session);
    try std.testing.expectEqual(@as(usize, 2), model.selected);
    model.apply(.next_session);
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    model.selected = 2;
    model.reconcile(2);
    try std.testing.expectEqual(@as(usize, 1), model.selected);
}

test "mux ctrl navigation is decoded without consuming ordinary input" {
    try std.testing.expectEqual(Action.focus_sidebar, actionForByte(0x07));
    try std.testing.expectEqual(Action.next_session, actionForByte(0x0a));
    try std.testing.expectEqual(Action.previous_session, actionForByte(0x0b));
    try std.testing.expectEqual(Action.focus_terminal, actionForByte(0x0c));
    try std.testing.expectEqual(Action.new_session, actionForByte(0x0e));
    try std.testing.expectEqual(Action.none, actionForByte('x'));
}
test "mux leaves backspace and emacs chords to the hosted child" {
    try std.testing.expectEqual(Action.none, actionForByte(0x08));
    try std.testing.expectEqual(Action.none, actionForByte('x'));
}
