//! Navigation policy, independent of native windows and decoder storage.
const std = @import("std");
const actions = @import("actions.zig");
const catalog = @import("catalog.zig");
pub const Step = union(enum) { stay, hold, quit, select: struct { position: usize, wrapped: bool } };

/// Fresh presses remain immediate. Auto-repeat retains one pending step until
/// a display refresh has passed the current selection's first presentation.
pub const HeldAdvance = struct {
    pub const Direction = enum { next, previous };
    held: ?struct { key: u32, direction: Direction, pending: bool = false } = null,
    presentation: union(enum) { waiting, submitted: f64 } = .waiting,

    pub fn press(self: *HeldAdvance, key: u32, direction: Direction) void {
        self.held = .{ .key = key, .direction = direction };
    }
    pub fn repeat(self: *HeldAdvance, key: u32, direction: Direction) void {
        if (self.held) |*held| if (held.key == key and held.direction == direction) {
            held.pending = true;
        };
    }
    pub fn release(self: *HeldAdvance, key: u32) void {
        if (self.held) |held| if (held.key == key) self.cancel();
    }
    pub fn cancel(self: *HeldAdvance) void {
        self.held = null;
    }
    pub fn selected(self: *HeldAdvance) void {
        self.presentation = .waiting;
    }
    pub fn presented(self: *HeldAdvance, time: f64) void {
        if (self.presentation == .waiting) self.presentation = .{ .submitted = time };
    }
    pub fn pending(self: HeldAdvance) bool {
        return if (self.held) |held| held.pending else false;
    }
    pub fn submitted(self: HeldAdvance) ?f64 {
        if (!self.pending()) return null;
        return switch (self.presentation) {
            .waiting => null,
            .submitted => |time| time,
        };
    }
    pub fn take(self: *HeldAdvance, displayed_through: f64) ?Direction {
        const at = self.submitted() orelse return null;
        if (displayed_through < at) return null;
        const held = &self.held.?;
        held.pending = false;
        return held.direction;
    }
};
pub fn step(current: usize, count: usize, delta: isize, timed: bool, settings: *const actions.Settings) Step {
    if (count == 0) return .stay;
    const raw = @as(isize, @intCast(current)) + delta;
    const end = raw < 0 or raw >= count;
    if (end and (timed or settings.on_last == .hold or (settings.on_last == .quit and raw >= count))) {
        switch (settings.on_last) {
            .quit => return .quit,
            .hold => return .hold,
            .@"resume" => if (!settings.slideshow_loop) return .hold,
        }
    }
    const wrap = if (timed) settings.slideshow_loop else settings.wrap;
    const next: usize = @intCast(if (wrap) @mod(raw, @as(isize, @intCast(count))) else std.math.clamp(raw, 0, @as(isize, @intCast(count - 1))));
    if (next == current and count > 1) return .stay;
    return .{ .select = .{ .position = next, .wrapped = end and wrap } };
}
pub fn jump(current: usize, count: usize, forward: bool) usize {
    if (count == 0) return 0;
    const delta = @max(1, count / 20);
    return if (forward) @min(count - 1, current + delta) else current -| delta;
}
pub fn directory(entries: []const catalog.Entry, order: ?[]const usize, current: usize, forward: bool) ?usize {
    const count = if (order) |ids| ids.len else entries.len;
    if (count == 0) return null;
    const original = dirname(entries, order, current);
    var i = current;
    while (if (forward) i + 1 < count else i > 0) {
        if (forward) i += 1 else i -= 1;
        if (!std.mem.eql(u8, original, dirname(entries, order, i))) {
            if (!forward) {
                const target = dirname(entries, order, i);
                while (i > 0 and std.mem.eql(u8, target, dirname(entries, order, i - 1))) i -= 1;
            }
            return i;
        }
    }
    return null;
}
fn dirname(entries: []const catalog.Entry, order: ?[]const usize, position: usize) []const u8 {
    return std.fs.path.dirname(entries[if (order) |ids| ids[position] else position].path) orelse "";
}
test "manual boundaries and slideshow endpoints use one policy" {
    var settings = actions.Settings.init();
    settings.wrap = false;
    try std.testing.expect(step(0, 3, -1, false, &settings) == .stay);
    settings.on_last = .hold;
    try std.testing.expect(step(2, 3, 1, true, &settings) == .hold);
    try std.testing.expect(step(0, 3, -1, false, &settings) == .hold);
    settings.on_last = .quit;
    try std.testing.expect(step(2, 3, 1, true, &settings) == .quit);
    try std.testing.expect(step(2, 3, 1, false, &settings) == .quit);
    settings.on_last = .@"resume";
    settings.slideshow_loop = true;
    const next = step(2, 3, 1, true, &settings).select;
    try std.testing.expect(next.position == 0 and next.wrapped);
}

test "held navigation coalesces repeats until a displayed frame and stops on release" {
    var held: HeldAdvance = .{};
    held.press(9, .next);
    held.selected();
    for (0..1000) |_| held.repeat(9, .next);
    try std.testing.expect(held.take(1000) == null);
    held.presented(1001);
    try std.testing.expect(held.take(1000.999) == null);
    try std.testing.expectEqual(HeldAdvance.Direction.next, held.take(1001).?);
    try std.testing.expect(held.take(1002) == null);
    held.selected();
    held.repeat(9, .next);
    held.release(8); // Another key cannot release this one.
    try std.testing.expect(held.pending());
    held.release(9);
    held.presented(1003);
    try std.testing.expect(held.take(1004) == null);
    held.repeat(9, .next); // Ignore repeat events left after release/focus loss.
    try std.testing.expect(!held.pending());
}

test "a new press discards an older queued repeat and may skip an unseen selection" {
    var held: HeldAdvance = .{};
    held.press(9, .next);
    held.selected();
    held.repeat(9, .next);
    held.press(9, .next);
    try std.testing.expect(!held.pending());
    held.selected();
    held.repeat(9, .next);
    held.presented(1);
    held.presented(2); // Detail/overlay updates cannot postpone the first frame.
    try std.testing.expectEqual(HeldAdvance.Direction.next, held.take(1).?);
    held.press(8, .previous);
    held.repeat(9, .next);
    try std.testing.expect(!held.pending());
    held.repeat(8, .previous);
    held.cancel();
    try std.testing.expect(held.take(3) == null);
}
