//! Keyboard input from the foreground terminal, with no blocking reads.
const std = @import("std");
const c = @import("system");
const actions = @import("actions.zig");

pub const Terminal = struct {
    original: ?c.struct_termios = null,
    pub const Key = struct { value: u16, modifiers: usize = 0 };

    pub fn enable(self: *Terminal) bool {
        if (c.isatty(0) != 1 or c.tcgetpgrp(0) != c.getpgrp()) return false;
        var saved: c.struct_termios = undefined;
        if (c.tcgetattr(0, &saved) != 0) return false;
        var raw = saved;
        raw.c_lflag &= ~@as(c.tcflag_t, c.ICANON | c.ECHO);
        raw.c_cc[c.VMIN] = 0;
        raw.c_cc[c.VTIME] = 0;
        if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return false;
        self.original = saved;
        return true;
    }
    pub fn disable(self: *Terminal) void {
        if (self.original) |*saved| _ = c.tcsetattr(0, c.TCSANOW, saved);
        self.original = null;
    }
    pub fn next(self: *const Terminal) ?Key {
        if (self.original == null or c.tcgetpgrp(0) != c.getpgrp()) return null;
        const ch = byte() orelse return null;
        if (ch == 27) {
            const next_byte = byte() orelse return .{ .value = 27 };
            if (next_byte == '[' or next_byte == 'O') {
                return .{ .value = switch (byte() orelse return null) {
                    'A' => 0xf700,
                    'B' => 0xf701,
                    'C' => 0xf703,
                    'D' => 0xf702,
                    'H' => 0xf729,
                    'F' => 0xf72b,
                    else => return null,
                } };
            }
            var key = printable(next_byte) orelse return null;
            key.modifiers |= actions.option;
            return key;
        }
        return printable(ch);
    }
};

fn byte() ?u8 {
    var ch: u8 = 0;
    return if (c.read(0, &ch, 1) == 1) ch else null;
}
fn printable(ch: u8) ?Terminal.Key {
    return switch (ch) {
        '\r', '\n' => .{ .value = 13 },
        8, 127 => .{ .value = 127 },
        'A'...'Z' => .{ .value = ch, .modifiers = actions.shift },
        else => if (ch >= 32 and ch <= 126) .{ .value = ch } else null,
    };
}
