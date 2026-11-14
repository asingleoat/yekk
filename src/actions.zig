const std = @import("std");
const hooks = @import("hooks.zig");
pub const Action = enum {
    action_0,
    action_1,
    action_2,
    action_3,
    action_4,
    action_5,
    action_6,
    action_7,
    action_8,
    action_9,
    menu,
    render,
    draw_actions,
    draw_filename,
    auto_zoom,
    reload_plus,
    reload_minus,
    pan_left_page,
    pan_right_page,
    pan_up_page,
    pan_down_page,
    random,
    next_directory,
    previous_directory,
    jump_forward,
    jump_back,
    next,
    previous,
    first,
    last,
    zoom_in,
    zoom_out,
    actual,
    fit,
    shrink,
    fill,
    fit_width,
    fit_height,
    pan_left,
    pan_right,
    pan_up,
    pan_down,
    rotate_right,
    rotate_left,
    mirror_horizontal,
    mirror_vertical,
    fullscreen,
    reload,
    info,
    help,
    close,
    quit,
    open,
    slideshow,
    watch,
    wrap,
    keep_view,
    reveal,
    external,
    remove,
    trash,
    nearest,
    background,
    resize_window,
};
pub const Binding = struct { key: u16, modifiers: usize = 0, action: Action };
pub const command: usize = 1 << 20;
pub const shift: usize = 1 << 17;
pub const option: usize = 1 << 19;
pub const control: usize = 1 << 18;
pub const defaults = [_]Binding{
    .{ .key = 'm', .action = .menu },                                  .{ .key = 'r', .modifiers = shift, .action = .render },
    .{ .key = '+', .action = .reload_plus },                           .{ .key = '-', .action = .reload_minus },
    .{ .key = 0xF702, .modifiers = option, .action = .pan_left_page }, .{ .key = 0xF703, .modifiers = option, .action = .pan_right_page },
    .{ .key = 0xF700, .modifiers = option, .action = .pan_up_page },   .{ .key = 0xF701, .modifiers = option, .action = .pan_down_page },
    .{ .key = ' ', .action = .next },                                  .{ .key = 'n', .action = .next },
    .{ .key = 0xF703, .action = .next },                               .{ .key = 0x7f, .action = .previous },
    .{ .key = 'p', .action = .previous },                              .{ .key = 0xF702, .action = .previous },
    .{ .key = 0xF729, .action = .first },                              .{ .key = 0xF72B, .action = .last },
    .{ .key = 0xF72C, .action = .jump_forward },                       .{ .key = 0xF72D, .action = .jump_back },
    .{ .key = 0xF700, .action = .zoom_in },                            .{ .key = 0xF701, .action = .zoom_out },
    .{ .key = '*', .action = .actual },                                .{ .key = '/', .action = .fit },
    .{ .key = '!', .action = .fill },                                  .{ .key = 'f', .action = .fullscreen },
    .{ .key = 'r', .action = .reload },                                .{ .key = 'i', .action = .info },
    .{ .key = '?', .action = .help },                                  .{ .key = 'q', .action = .quit },
    .{ .key = 0x1b, .action = .quit },                                 .{ .key = 'x', .action = .close },
    .{ .key = 'a', .action = .draw_actions },                          .{ .key = 'd', .action = .draw_filename },
    .{ .key = 'a', .modifiers = shift, .action = .nearest },           .{ .key = 'h', .action = .slideshow },
    .{ .key = 'k', .action = .keep_view },                             .{ .key = 'w', .action = .resize_window },
    .{ .key = 'z', .action = .random },                                .{ .key = 'z', .modifiers = shift, .action = .auto_zoom },
    .{ .key = '[', .action = .previous_directory },                    .{ .key = ']', .action = .next_directory },
    .{ .key = '<', .action = .rotate_left },                           .{ .key = '>', .action = .rotate_right },
    .{ .key = '_', .action = .mirror_vertical },                       .{ .key = '|', .action = .mirror_horizontal },
    .{ .key = 0xF728, .action = .remove },                             .{ .key = 0xF728, .modifiers = control, .action = .trash },
    .{ .key = 0xF702, .modifiers = control, .action = .pan_right },    .{ .key = 0xF703, .modifiers = control, .action = .pan_left },
    .{ .key = 0xF700, .modifiers = control, .action = .pan_down },     .{ .key = 0xF701, .modifiers = control, .action = .pan_up },
    .{ .key = '0', .action = .action_0 },                              .{ .key = '\r', .action = .action_0 },
    .{ .key = '1', .action = .action_1 },                              .{ .key = '2', .action = .action_2 },
    .{ .key = '3', .action = .action_3 },                              .{ .key = '4', .action = .action_4 },
    .{ .key = '5', .action = .action_5 },                              .{ .key = '6', .action = .action_6 },
    .{ .key = '7', .action = .action_7 },                              .{ .key = '8', .action = .action_8 },
    .{ .key = '9', .action = .action_9 },                              .{ .key = 'w', .modifiers = command, .action = .close },
    .{ .key = 'q', .modifiers = command, .action = .quit },            .{ .key = 'o', .modifiers = command, .action = .open },
};
pub const Settings = struct {
    bindings: [128]Binding = undefined,
    binding_count: usize = 0,
    wrap: bool = true,
    hooks: [10]hooks.Command = @splat(.{}),
    zoom_step: f64 = 1.25,
    on_last: enum { @"resume", hold, quit } = .@"resume",
    keep_view: bool = false,
    watch: bool = false,
    watch_seconds: f64 = 1,
    checker: bool = false,
    interval: f64 = 0,
    slideshow_loop: bool = true,
    fit: @import("core.zig").ScaleMode = .shrink,
    error_line: usize = 0,

    pub fn init() Settings {
        var self: Settings = .{};
        @memcpy(self.bindings[0..defaults.len], &defaults);
        self.binding_count = defaults.len;
        if (@import("builtin").os.tag == .linux) self.parse("bind Ctrl+o = open\nbind Ctrl+Shift+o = open\n");
        return self;
    }
    pub fn lookup(self: *const Settings, key: u16, modifiers: usize) ?Action {
        const lower: u16 = if (key <= 127) std.ascii.toLower(@intCast(key)) else key;
        for (self.bindings[0..self.binding_count]) |b| {
            const relevant = command | option | control | (if (b.modifiers & shift != 0 or (lower >= 'a' and lower <= 'z')) shift else @as(usize, 0));
            if (b.key == lower and b.modifiers == modifiers & relevant) return b.action;
        }
        return null;
    }
    pub fn parse(self: *Settings, bytes: []const u8) void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var line_number: usize = 0;
        while (lines.next()) |line| {
            line_number += 1;
            const text = std.mem.trim(u8, line, " \r\t");
            if (text.len == 0 or text[0] == '#') continue;
            self.setting(text) catch {
                if (self.error_line == 0) self.error_line = line_number;
            };
        }
    }
    pub fn parseKeys(self: *Settings, bytes: []const u8) void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var line_number: usize = 0;
        while (lines.next()) |line| {
            line_number += 1;
            var words = std.mem.tokenizeAny(u8, line, " \t\r");
            const name = words.next() orelse continue;
            if (name[0] == '#') continue;
            const action = actionName(name) orelse {
                if (self.error_line == 0) self.error_line = line_number;
                continue;
            };
            // A feh keys line replaces ALL previous bindings for its action.
            var i: usize = 0;
            while (i < self.binding_count) {
                if (self.bindings[i].action == action) {
                    self.binding_count -= 1;
                    std.mem.copyForwards(Binding, self.bindings[i..self.binding_count], self.bindings[i + 1 .. self.binding_count + 1]);
                } else i += 1;
            }
            while (words.next()) |key| {
                if (key[0] == '#') break;
                var binding = parseKey(key) catch {
                    if (self.error_line == 0) self.error_line = line_number;
                    continue;
                };
                binding.action = action;
                self.bind(binding) catch {
                    if (self.error_line == 0) self.error_line = line_number;
                };
            }
        }
    }
    fn bind(self: *Settings, binding: Binding) !void {
        for (self.bindings[0..self.binding_count]) |*b| if (b.key == binding.key and b.modifiers == binding.modifiers) {
            b.* = binding;
            return;
        };
        if (self.binding_count == self.bindings.len) return error.TooManyBindings;
        self.bindings[self.binding_count] = binding;
        self.binding_count += 1;
    }
    fn setting(self: *Settings, text: []const u8) !void {
        const pair = std.mem.cutScalar(u8, text, '=') orelse return error.InvalidSetting;
        const key = std.mem.trim(u8, pair[0], " \t");
        const value = std.mem.trim(u8, pair[1], " \t");
        if (std.mem.startsWith(u8, key, "bind ")) {
            var binding = try parseKey(std.mem.trim(u8, key[5..], " \t"));
            binding.action = actionName(value) orelse return error.UnknownAction;
            try self.bind(binding);
        } else if (std.mem.startsWith(u8, key, "action_") and key.len == 8 and std.ascii.isDigit(key[7])) {
            try self.hooks[key[7] - '0'].set(value);
        } else if (std.mem.eql(u8, key, "fit")) {
            self.fit = std.meta.stringToEnum(@TypeOf(self.fit), value) orelse return error.InvalidSetting;
        } else if (std.mem.eql(u8, key, "slideshow")) {
            const seconds = try std.fmt.parseFloat(f64, value);
            if (!std.math.isFinite(seconds) or seconds <= 0) return error.InvalidSetting;
            self.interval = seconds;
        } else {
            const enabled = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.InvalidSetting;
            if (std.mem.eql(u8, key, "wrap")) self.wrap = enabled else if (std.mem.eql(u8, key, "keep_view")) self.keep_view = enabled else if (std.mem.eql(u8, key, "watch")) self.watch = enabled else if (std.mem.eql(u8, key, "checker")) self.checker = enabled else if (std.mem.eql(u8, key, "slideshow_loop")) self.slideshow_loop = enabled else return error.UnknownSetting;
        }
    }
};
pub fn parseKey(text: []const u8) !Binding {
    var name = text;
    var b: Binding = .{ .key = 0, .action = .help };
    while (true) {
        if (name.len >= 2 and name[1] == '-' and std.mem.indexOfScalar(u8, "CS14", name[0]) != null) {
            b.modifiers |= switch (name[0]) {
                'C' => control,
                'S' => shift,
                '1' => option,
                else => command,
            };
            name = name[2..];
        } else if (std.mem.startsWith(u8, name, "Cmd+")) {
            b.modifiers |= command;
            name = name[4..];
        } else if (std.mem.startsWith(u8, name, "Shift+")) {
            b.modifiers |= shift;
            name = name[6..];
        } else if (std.mem.startsWith(u8, name, "Alt+")) {
            b.modifiers |= option;
            name = name[4..];
        } else if (std.mem.startsWith(u8, name, "Ctrl+")) {
            b.modifiers |= control;
            name = name[5..];
        } else break;
    }
    if (name.len == 1 and std.ascii.isUpper(name[0])) b.modifiers |= shift;
    const named = .{ .{ "plus", @as(u16, '+') }, .{ "minus", @as(u16, '-') }, .{ "asterisk", @as(u16, '*') }, .{ "slash", @as(u16, '/') }, .{ "exclam", @as(u16, '!') }, .{ "bracketleft", @as(u16, '[') }, .{ "bracketright", @as(u16, ']') }, .{ "less", @as(u16, '<') }, .{ "greater", @as(u16, '>') }, .{ "underscore", @as(u16, '_') }, .{ "bar", @as(u16, '|') }, .{ "question", @as(u16, '?') } };
    inline for (named) |pair| if (std.mem.eql(u8, name, pair[0])) {
        b.key = pair[1];
        return b;
    };
    b.key = if (name.len == 1) std.ascii.toLower(name[0]) else if ((std.mem.eql(u8, name, "Space") or std.mem.eql(u8, name, "space"))) ' ' else if (std.mem.eql(u8, name, "Right")) 0xF703 else if (std.mem.eql(u8, name, "Left")) 0xF702 else if (std.mem.eql(u8, name, "Home")) 0xF729 else if (std.mem.eql(u8, name, "End")) 0xF72B else if (std.mem.eql(u8, name, "Backspace")) 0x7F else if (std.mem.eql(u8, name, "Up")) 0xF700 else if (std.mem.eql(u8, name, "Down")) 0xF701 else if (std.mem.eql(u8, name, "Return")) 13 else if (std.mem.eql(u8, name, "Escape")) 27 else if (std.mem.eql(u8, name, "Delete")) 0xF728 else if (std.mem.eql(u8, name, "Page_Up") or std.mem.eql(u8, name, "Prior")) 0xF72C else if (std.mem.eql(u8, name, "Page_Down") or std.mem.eql(u8, name, "Next")) 0xF72D else if (std.mem.eql(u8, name, "BackSpace")) 0x7f else return error.UnknownKey;
    return b;
}
pub fn keyName(key: u16) []const u8 {
    return switch (key) {
        ' ' => "Space",
        0x7F => "Backspace",
        0xF703 => "Right",
        0xF702 => "Left",
        0xF729 => "Home",
        0xF72B => "End",
        else => "",
    };
}
test "bindings are overridden while config errors leave valid settings usable" {
    var s = Settings.init();
    s.parse("wrap = true\nbind n = previous\nbind Cmd+Shift+e = external\nunknown = true\nkeep_view = true\n");
    try std.testing.expect(s.wrap and s.keep_view);
    try std.testing.expectEqual(@as(usize, 4), s.error_line);
    try std.testing.expectEqual(Action.previous, s.lookup('n', 0).?);
    try std.testing.expectEqual(Action.external, s.lookup('E', command | shift).?);
}

pub fn actionName(name: []const u8) ?Action {
    const names = .{ .{ "next_img", Action.next }, .{ "prev_img", Action.previous }, .{ "first_img", Action.first }, .{ "last_img", Action.last }, .{ "toggle_fullscreen", Action.fullscreen }, .{ "reload_image", Action.reload }, .{ "toggle_pause", Action.slideshow }, .{ "toggle_actions", Action.draw_actions }, .{ "toggle_filenames", Action.draw_filename }, .{ "toggle_info", Action.info }, .{ "toggle_aliasing", Action.nearest }, .{ "toggle_keep_vp", Action.keep_view }, .{ "zoom_default", Action.actual }, .{ "zoom_fit", Action.fit }, .{ "zoom_fill", Action.fill }, .{ "next_dir", Action.next_directory }, .{ "prev_dir", Action.previous_directory }, .{ "jump_fwd", Action.jump_forward }, .{ "jump_back", Action.jump_back }, .{ "orient_1", Action.rotate_right }, .{ "orient_3", Action.rotate_left }, .{ "flip", Action.mirror_vertical }, .{ "mirror", Action.mirror_horizontal }, .{ "remove", Action.remove }, .{ "delete", Action.trash } };
    inline for (names) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
    const more = .{ .{ "toggle_menu", Action.menu }, .{ "jump_first", Action.first }, .{ "jump_last", Action.last }, .{ "jump_random", Action.random }, .{ "size_to_image", Action.resize_window }, .{ "toggle_auto_zoom", Action.auto_zoom }, .{ "toggle_keep_vp", Action.keep_view }, .{ "scroll_left", Action.pan_right }, .{ "scroll_right", Action.pan_left }, .{ "scroll_up", Action.pan_down }, .{ "scroll_down", Action.pan_up }, .{ "scroll_left_page", Action.pan_left_page }, .{ "scroll_right_page", Action.pan_right_page }, .{ "scroll_up_page", Action.pan_up_page }, .{ "scroll_down_page", Action.pan_down_page } };
    inline for (more) |pair| if (std.mem.eql(u8, name, pair[0])) return pair[1];
    return std.meta.stringToEnum(Action, name);
}
test "feh keys replace and unbind actions including upper case and numbered hooks" {
    var settings = Settings.init();
    settings.parseKeys("action_1 C-k 1\nnext_img\ntoggle_actions A\n");
    try std.testing.expect(settings.lookup('n', 0) == null);
    try std.testing.expectEqual(Action.action_1, settings.lookup('k', control).?);
    try std.testing.expectEqual(Action.action_1, settings.lookup('1', 0).?);
    try std.testing.expectEqual(Action.draw_actions, settings.lookup('A', shift).?);
    try std.testing.expect(settings.lookup('a', 0) == null);
    try std.testing.expectEqual(Action.actual, settings.lookup('*', shift).?);
    try std.testing.expectEqual(Action.quit, settings.lookup(27, 0).?);
}

test "clipboard actions and shortcuts are absent" {
    var settings = Settings.init();
    try std.testing.expect(settings.lookup('c', command) == null);
    try std.testing.expect(settings.lookup('c', command | shift) == null);
    settings.parse("bind c = copy_image\n");
    try std.testing.expectEqual(@as(usize, 1), settings.error_line);
}
