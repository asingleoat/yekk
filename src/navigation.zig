//! Navigation policy, independent of native windows and decoder storage.
const std = @import("std");
const actions = @import("actions.zig");
const catalog = @import("catalog.zig");
pub const Step = union(enum) { stay, hold, quit, select: struct { position: usize, wrapped: bool } };
pub fn step(current: usize, count: usize, delta: isize, timed: bool, settings: *const actions.Settings) Step {
    if (count == 0) return .stay;
    const raw = @as(isize, @intCast(current)) + delta;
    const end = raw < 0 or raw >= count;
    if (timed and end) {
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
    settings.on_last = .quit;
    try std.testing.expect(step(2, 3, 1, true, &settings) == .quit);
    settings.on_last = .@"resume";
    settings.slideshow_loop = true;
    const next = step(2, 3, 1, true, &settings).select;
    try std.testing.expect(next.position == 0 and next.wrapped);
}
