//! Window-local action menu; fixed rows and the same named actions as keys.
const std = @import("std");
const actions = @import("actions.zig");
pub const items = [_]actions.Action{ .actual, .fit, .shrink, .fill, .zoom_in, .zoom_out, .rotate_right, .rotate_left, .mirror_horizontal, .mirror_vertical, .fullscreen, .reload, .slideshow, .info, .open, .reveal, .external, .remove, .save_filelist, .trash, .close, .quit, .action_0, .action_1, .action_2, .action_3, .action_4, .action_5, .action_6, .action_7, .action_8, .action_9, .menu, .render, .draw_actions, .draw_filename, .auto_zoom, .reload_plus, .reload_minus, .pan_left_page, .pan_right_page, .pan_up_page, .pan_down_page, .random, .next_directory, .previous_directory, .jump_forward, .jump_back, .next, .previous, .first, .last, .fit_width, .fit_height, .pan_left, .pan_right, .pan_up, .pan_down, .help, .watch, .wrap, .keep_view, .nearest, .background, .resize_window };
pub const count = items.len;
pub const labels: [count][*:0]const u8 = labels: {
    @setEvalBranchQuota(20000);
    var result: [count][*:0]const u8 = undefined;
    for (items, 0..) |action, i| {
        const name = @tagName(action);
        var text: [name.len:0]u8 = undefined;
        for (name, 0..) |character, j| text[j] = if (character == '_') ' ' else if (j == 0) std.ascii.toUpper(character) else character;
        text[name.len] = 0;
        const stable = text;
        result[i] = &stable;
    }
    break :labels result;
};
pub const Menu = struct {
    open: bool = false,
    selected: usize = 0,
    first: usize = 0,
    rows: usize = 1,
    x: i32 = 8,
    y: i32 = 8,
    width: i32 = 320,
    row_height: i32 = 24,
    scale: f32 = 1,
    pub fn layout(self: *Menu, width: i32, height: i32, scale: f32) void {
        self.scale = @max(0.5, scale);
        self.row_height = @max(1, @as(i32, @intFromFloat(24 * self.scale)));
        self.width = @max(1, @min(width - 8, @as(i32, @intFromFloat(320 * self.scale))));
        self.rows = @min(count, @as(usize, @intCast(@max(1, @divTrunc(height - 8, self.row_height)))));
        self.x = @max(0, @min(self.x, width - self.width));
        self.y = @max(0, @min(self.y, height - @as(i32, @intCast(self.rows)) * self.row_height));
        self.reveal();
    }
    fn reveal(self: *Menu) void {
        if (self.selected < self.first) self.first = self.selected;
        if (self.selected >= self.first + self.rows) self.first = self.selected + 1 - self.rows;
        self.first = @min(self.first, count - self.rows);
    }
    pub fn move(self: *Menu, backwards: bool) void {
        self.selected = if (backwards) (self.selected + count - 1) % count else (self.selected + 1) % count;
        self.reveal();
    }
    pub fn hit(self: *const Menu, x: f32, y: f32) ?usize {
        const row = (y - @as(f32, @floatFromInt(self.y))) / @as(f32, @floatFromInt(self.row_height));
        if (x < @as(f32, @floatFromInt(self.x)) or x >= @as(f32, @floatFromInt(self.x + self.width)) or row < 0 or row >= @as(f32, @floatFromInt(self.rows))) return null;
        const item = self.first + @as(usize, @intFromFloat(row));
        return if (item < count) item else null;
    }
    pub fn action(self: *const Menu) actions.Action {
        return items[self.selected];
    }
};

test "menu scrolls through every named action and clips hit tests to visible rows" {
    var menu: Menu = .{ .open = true };
    try std.testing.expectEqual(actions.Action.actual, menu.action());
    menu.layout(300, 90, 2);
    try std.testing.expectEqual(@as(usize, 1), menu.rows);
    for (0..count) |_| menu.move(false);
    try std.testing.expectEqual(@as(usize, 0), menu.selected);
    menu.move(true);
    try std.testing.expectEqual(count - 1, menu.first);
    try std.testing.expectEqual(actions.Action.resize_window, menu.action());
    try std.testing.expectEqual(count - 1, menu.hit(@floatFromInt(menu.x + 1), @floatFromInt(menu.y + 1)).?);
    try std.testing.expect(menu.hit(-1, -1) == null);
}

test "menu contains each action exactly once" {
    var seen: [@typeInfo(actions.Action).@"enum".field_names.len]bool = @splat(false);
    for (items) |action| {
        const index = @backingInt(action);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |value| try std.testing.expect(value);
}
