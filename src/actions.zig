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
    save_filelist,
    toggle_exif,
    toggle_caption,
    toggle_pointer,
    save_image,
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
    .{ .key = keypad_plus, .action = .zoom_in },                       .{ .key = keypad_minus, .action = .zoom_out },
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
    .{ .key = 'o', .action = .toggle_pointer },                        .{ .key = 's', .action = .save_image },
    .{ .key = 'e', .action = .toggle_exif },                           .{ .key = 'c', .action = .toggle_caption },
    .{ .key = 'l', .modifiers = shift, .action = .save_filelist },
};
pub const MouseAction = union(enum) {
    pan,
    zoom,
    action: Action,
};
const MouseBinding = struct { button: u8, modifiers: usize = 0, action: MouseAction };
const mouse_defaults = [_]MouseBinding{
    .{ .button = 1, .action = .pan },
    .{ .button = 2, .action = .zoom },
    .{ .button = 3, .action = .{ .action = .menu } },
    .{ .button = 4, .action = .{ .action = .previous } },
    .{ .button = 5, .action = .{ .action = .next } },
};
pub const keypad_zero: u16 = 0xE100;
pub const keypad_decimal = keypad_zero + 10;
pub const keypad_enter = keypad_zero + 11;
pub const keypad_plus = keypad_zero + 12;
pub const keypad_minus = keypad_zero + 13;
pub const keypad_multiply = keypad_zero + 14;
pub const keypad_divide = keypad_zero + 15;
pub const keypad_equal = keypad_zero + 16;
const keypad_printable = "0123456789.\r+-*/=";

pub const Settings = struct {
    bindings: [128]Binding = undefined,
    binding_count: usize = 0,
    mouse: [128]MouseBinding = undefined,
    mouse_count: usize = 0,
    mouse_configured: bool = false,
    wrap: bool = true,
    hooks: [10]hooks.Command = @splat(.{}),
    zoom_step: f64 = 1.25,
    scroll_step: f64 = 64,
    tap_zones: bool = false,
    menus: bool = true,
    no_screen_clip: bool = false,
    nearest: bool = false,
    edit: bool = false,
    background_color: ?[3]u8 = null,
    hide_pointer: bool = false,
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
        @memcpy(self.mouse[0..mouse_defaults.len], &mouse_defaults);
        self.mouse_count = mouse_defaults.len;
        if (@import("builtin").os.tag == .linux) self.parse("bind Ctrl+o = open\nbind Ctrl+Shift+o = open\n");
        return self;
    }
    pub fn lookup(self: *const Settings, key: u16, modifiers: usize) ?Action {
        if (self.lookupKey(key, modifiers)) |action| return action;
        if (key == keypad_plus or key == keypad_minus) return null;
        if (key >= keypad_zero and key - keypad_zero < keypad_printable.len) return self.lookupKey(keypad_printable[key - keypad_zero], modifiers);
        return null;
    }

    fn lookupKey(self: *const Settings, key: u16, modifiers: usize) ?Action {
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
    pub fn lookupButton(self: *const Settings, button: u8, modifiers: usize) ?MouseAction {
        for (self.mouse[0..self.mouse_count]) |binding| {
            if (binding.button == button and binding.modifiers == modifiers & (command | option | control | shift)) return binding.action;
        }
        return null;
    }

    pub fn parseButtons(self: *Settings, bytes: []const u8) void {
        self.mouse_configured = true;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var number: usize = 0;
        while (lines.next()) |line| {
            number += 1;
            self.parseButtonLine(line) catch {
                if (self.error_line == 0) self.error_line = number;
            };
        }
    }

    fn parseButtonLine(self: *Settings, line: []const u8) !void {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const name = words.next() orelse return;
        if (name[0] == '#') return;
        const action: MouseAction = if (std.mem.eql(u8, name, "pan"))
            .pan
        else if (std.mem.eql(u8, name, "zoom"))
            .zoom
        else
            .{ .action = actionName(name) orelse return error.UnknownAction };
        var count: usize = 0;
        for (self.mouse[0..self.mouse_count]) |binding| {
            if (std.meta.eql(binding.action, action)) continue;
            self.mouse[count] = binding;
            count += 1;
        }
        self.mouse_count = count;
        while (words.next()) |word| {
            if (word[0] == '#') break;
            const parsed = parseModifiers(word);
            const button = std.fmt.parseInt(u8, parsed.name, 10) catch return error.InvalidButton;
            if (button == 0) return error.InvalidButton;
            const binding: MouseBinding = .{ .button = button, .modifiers = parsed.modifiers, .action = action };
            for (self.mouse[0..self.mouse_count]) |*previous| {
                if (previous.button == button and previous.modifiers == parsed.modifiers) {
                    previous.* = binding;
                    break;
                }
            } else {
                if (self.mouse_count == self.mouse.len) return error.TooManyBindings;
                self.mouse[self.mouse_count] = binding;
                self.mouse_count += 1;
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
fn parseModifiers(text: []const u8) struct { name: []const u8, modifiers: usize } {
    var name = text;
    var modifiers: usize = 0;
    while (true) {
        if (name.len >= 2 and name[1] == '-' and std.mem.indexOfScalar(u8, "CS14", name[0]) != null) {
            modifiers |= switch (name[0]) {
                'C' => control,
                'S' => shift,
                '1' => option,
                else => command,
            };
            name = name[2..];
        } else if (std.mem.startsWith(u8, name, "Cmd+")) {
            modifiers |= command;
            name = name[4..];
        } else if (std.mem.startsWith(u8, name, "Shift+")) {
            modifiers |= shift;
            name = name[6..];
        } else if (std.mem.startsWith(u8, name, "Alt+")) {
            modifiers |= option;
            name = name[4..];
        } else if (std.mem.startsWith(u8, name, "Ctrl+")) {
            modifiers |= control;
            name = name[5..];
        } else break;
    }
    return .{ .name = name, .modifiers = modifiers };
}

pub fn parseKey(text: []const u8) !Binding {
    const parsed = parseModifiers(text);
    const name = parsed.name;
    var b: Binding = .{ .key = 0, .action = .help, .modifiers = parsed.modifiers };
    if (std.mem.startsWith(u8, name, "KP_")) {
        const key = name[3..];
        if (key.len == 1 and std.ascii.isDigit(key[0])) {
            b.key = keypad_zero + @as(u16, key[0] - '0');
            return b;
        }
        const names = .{
            .{ "Decimal", keypad_decimal },  .{ "Delete", keypad_decimal },
            .{ "Enter", keypad_enter },      .{ "Add", keypad_plus },
            .{ "Subtract", keypad_minus },   .{ "Multiply", keypad_multiply },
            .{ "Divide", keypad_divide },    .{ "Equal", keypad_equal },
            .{ "Insert", keypad_zero },      .{ "End", keypad_zero + 1 },
            .{ "Down", keypad_zero + 2 },    .{ "Page_Down", keypad_zero + 3 },
            .{ "Next", keypad_zero + 3 },    .{ "Left", keypad_zero + 4 },
            .{ "Begin", keypad_zero + 5 },   .{ "Right", keypad_zero + 6 },
            .{ "Home", keypad_zero + 7 },    .{ "Up", keypad_zero + 8 },
            .{ "Page_Up", keypad_zero + 9 }, .{ "Prior", keypad_zero + 9 },
        };
        inline for (names) |pair| if (std.mem.eql(u8, key, pair[0])) {
            b.key = pair[1];
            return b;
        };
        return error.UnknownKey;
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
    const names = .{
        .{ "next_img", Action.next },                    .{ "prev_img", Action.previous },
        .{ "first_img", Action.first },                  .{ "last_img", Action.last },
        .{ "jump_first", Action.first },                 .{ "jump_last", Action.last },
        .{ "toggle_menu", Action.menu },                 .{ "toggle_fullscreen", Action.fullscreen },
        .{ "reload_image", Action.reload },              .{ "toggle_pause", Action.slideshow },
        .{ "toggle_actions", Action.draw_actions },      .{ "toggle_filenames", Action.draw_filename },
        .{ "toggle_info", Action.info },                 .{ "toggle_aliasing", Action.nearest },
        .{ "toggle_keep_vp", Action.keep_view },         .{ "toggle_auto_zoom", Action.auto_zoom },
        .{ "zoom_default", Action.actual },              .{ "zoom_fit", Action.fit },
        .{ "zoom_fill", Action.fill },                   .{ "size_to_image", Action.resize_window },
        .{ "next_dir", Action.next_directory },          .{ "prev_dir", Action.previous_directory },
        .{ "jump_fwd", Action.jump_forward },            .{ "jump_back", Action.jump_back },
        .{ "jump_random", Action.random },               .{ "orient_1", Action.rotate_right },
        .{ "orient_3", Action.rotate_left },             .{ "flip", Action.mirror_vertical },
        .{ "mirror", Action.mirror_horizontal },         .{ "remove", Action.remove },
        .{ "delete", Action.trash },                     .{ "scroll_left", Action.pan_right },
        .{ "scroll_right", Action.pan_left },            .{ "scroll_up", Action.pan_down },
        .{ "scroll_down", Action.pan_up },               .{ "scroll_left_page", Action.pan_left_page },
        .{ "scroll_right_page", Action.pan_right_page }, .{ "scroll_up_page", Action.pan_up_page },
        .{ "scroll_down_page", Action.pan_down_page },
    };
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

test "feh keypad defaults and mouse action names" {
    var settings = Settings.init();
    try std.testing.expectEqual(Action.zoom_in, settings.lookup(keypad_plus, 0));
    settings.parseKeys("zoom_in\naction_2 KP_Enter\njump_first Home\n");
    try std.testing.expectEqual(null, settings.lookup(keypad_plus, 0));
    try std.testing.expectEqual(Action.action_2, settings.lookup(keypad_enter, 0));
    try std.testing.expectEqual(Action.first, settings.lookup(0xF729, 0));
    settings.parseButtons("pan 2\nzoom 3\nnext_img 1\naction_1 C-1\ntoggle_menu 8\n");
    try std.testing.expectEqual(@as(usize, 0), settings.error_line);
    try std.testing.expectEqual(MouseAction.pan, settings.lookupButton(2, 0));
    try std.testing.expectEqual(MouseAction{ .action = .action_1 }, settings.lookupButton(1, control));
    try std.testing.expectEqual(MouseAction{ .action = .menu }, settings.lookupButton(8, 0));
}
