//! Shared command-line semantics and setting overrides.
const std = @import("std");
const actions = @import("actions.zig");
const core = @import("core.zig");
const hooks = @import("hooks.zig");
const catalog = @import("catalog.zig");
const options = @import("options.zig");
pub const Listing = union(enum) { none, paths, metadata, custom: [:0]const u8, loadable, unloadable };
pub const Slideshow = struct { seconds: f64, paused: bool };
pub const Options = struct {
    config: ?[:0]const u8 = null,
    decode_workers: ?usize = null,
    aggressive: bool = false,
    allocation_stats: bool = false,
    no_wrap: bool = false,
    geometry: ?@import("geometry").Geometry = null,
    borderless: bool = false,
    // null inherits configuration; an empty command explicitly disables it.
    hooks: [10]?hooks.Command = @splat(null),
    zoom: ?f64 = null,
    zoom_step: ?f64 = null,
    on_last: ?@FieldType(actions.Settings, "on_last") = null,
    draw_actions: bool = false,
    draw_filename: bool = false,
    default_directory: bool = false,
    keys: ?[:0]const u8 = null,
    buttons: ?[:0]const u8 = null,
    hook_test: bool = false,
    filelist: ?[:0]const u8 = null,
    output_dir: ?[:0]const u8 = null,
    text: @import("viewer_text.zig").Options = .{},
    font_paths: @import("typography.zig").SearchPaths = .{},
    multiwindow: bool = false,
    sheet: @import("contact_sheet.zig").Options = .{},
    wallpaper: ?@import("wallpaper.zig").Mode = null,
    xinerama_index: ?usize = null,
    primary_only: bool = false,
    tap_zones: bool = false,
    no_menus: bool = false,
    no_screen_clip: bool = false,
    hide_pointer: bool = false,
    force_aliasing: bool = false,
    edit: bool = false,
    background: ?union(enum) { default, checks, color: [3]u8 } = null,
    keep_http: bool = false,
    insecure: bool = false,
    refresh_http: bool = false,
    scroll_step: ?f64 = null,
    reload_seconds: ?f64 = null,

    fit: ?core.ScaleMode = null,
    auto_zoom: bool = false,
    scale_down: bool = false,
    watch: bool = false,
    keep_view: bool = false,
    fullscreen: bool = false,
    slideshow: ?Slideshow = null,
    listing: Listing = .none,
    smoke: bool = false,
    benchmark: bool = false,
    benchmark_pan: bool = false,
    smoke_windows: bool = false,
    watch_test: bool = false,
    recovery_test: bool = false,
    detail_test: bool = false,
    stress_cycles: usize = 0,
    stress_no_prefetch: bool = false,
    pub fn parse(self: *Options, item: options.Item, listing: *catalog.Options) !bool {
        const name = item.name;
        const value = item.value orelse "";
        if (std.mem.eql(u8, name, "aggressive")) {
            self.aggressive = true;
        } else if (std.mem.eql(u8, name, "decode-workers")) {
            const workers = try std.fmt.parseInt(usize, value, 10);
            self.decode_workers = workers;
        } else if (std.mem.eql(u8, name, "geometry")) {
            self.geometry = try @import("geometry").Geometry.parse(value);
        } else if (std.mem.eql(u8, name, "borderless")) {
            self.borderless = true;
        } else if (std.mem.eql(u8, name, "action") or (name.len == 7 and std.mem.startsWith(u8, name, "action") and std.ascii.isDigit(name[6]))) {
            const slot: usize = if (name.len == 6) 0 else name[6] - '0';
            var command: hooks.Command = .{};
            try command.set(value);
            self.hooks[slot] = command;
        } else if (std.mem.eql(u8, name, "recursive")) {
            listing.recursive = true;
        } else if (std.mem.eql(u8, name, "no-recursive")) {
            listing.recursive = false;
        } else if (std.mem.eql(u8, name, "browse")) {
            listing.browse = true;
        } else if (std.mem.eql(u8, name, "reverse")) {
            listing.reverse = true;
        } else if (std.mem.eql(u8, name, "shuffle") or std.mem.eql(u8, name, "randomize")) {
            listing.shuffle = true;
        } else if (std.mem.eql(u8, name, "fullscreen")) {
            self.fullscreen = true;
        } else if (std.mem.eql(u8, name, "alloc-stats")) {
            self.allocation_stats = true;
        } else if (std.mem.eql(u8, name, "watch")) {
            self.watch = true;
        } else if (std.mem.eql(u8, name, "keep-view") or std.mem.eql(u8, name, "keep-zoom-vp")) {
            self.keep_view = true;
        } else if (std.mem.eql(u8, name, "list")) {
            self.listing = .metadata;
            listing.report_paths = true;
        } else if (std.mem.eql(u8, name, "customlist")) {
            self.listing = .{ .custom = value };
            listing.report_paths = true;
        } else if (std.mem.eql(u8, name, "loadable")) {
            self.listing = .loadable;
            listing.report_paths = true;
        } else if (std.mem.eql(u8, name, "unloadable")) {
            self.listing = .unloadable;
            listing.report_paths = true;
        } else if (std.mem.eql(u8, name, "print-filelist")) {
            self.listing = .paths;
            listing.report_paths = false;
        } else if (std.mem.eql(u8, name, "draw-actions")) {
            self.draw_actions = true;
        } else if (std.mem.eql(u8, name, "draw-filename")) {
            self.draw_filename = true;
        } else if (std.mem.eql(u8, name, "auto-zoom")) {
            self.auto_zoom = true;
            self.fit = .fit;
        } else if (std.mem.eql(u8, name, "scale-down")) {
            self.scale_down = true;
            self.fit = if (self.auto_zoom) .fit else .shrink;
        } else if (std.mem.eql(u8, name, "config")) {
            self.config = value;
        } else if (std.mem.eql(u8, name, "keys")) {
            self.keys = value;
        } else if (std.mem.eql(u8, name, "buttons")) {
            self.buttons = value;
        } else if (std.mem.eql(u8, name, "filelist")) {
            self.filelist = value;
        } else if (std.mem.eql(u8, name, "output-dir")) {
            if (value.len == 0) return error.EmptyOutputDirectory;
            self.output_dir = value;
        } else if (std.mem.eql(u8, name, "title")) {
            var buffer: [8192]u8 = undefined;
            _ = try hooks.formatList(&buffer, value, .{ .path = "" });
            self.text.title = value;
        } else if (std.mem.eql(u8, name, "thumb-title")) {
            var buffer: [8192]u8 = undefined;
            _ = try hooks.formatList(&buffer, value, .{ .path = "" });
            self.text.thumb_title = value;
        } else if (std.mem.eql(u8, name, "font")) {
            self.text.font = try @import("typography.zig").Font.parse(value);
        } else if (std.mem.eql(u8, name, "fontpath")) {
            try self.font_paths.add(value);
        } else if (std.mem.eql(u8, name, "menu-font")) {
            self.text.menu_font = try @import("typography.zig").Font.parse(value);
        } else if (std.mem.eql(u8, name, "title-font")) {
            self.sheet.title_font = try @import("typography.zig").Font.parse(value);
        } else if (std.mem.eql(u8, name, "thumb-redraw")) {
            self.sheet.redraw = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, name, "caption-path")) {
            self.text.caption_dir = value;
        } else if (std.mem.eql(u8, name, "draw-exif")) {
            self.text.exif_visible = true;
        } else if (std.mem.eql(u8, name, "info")) {
            const hidden = value.len > 0 and value[0] == ';';
            const command = if (hidden) value[1..] else value;
            var buffer: [16384]u8 = undefined;
            _ = try hooks.format(&buffer, command, .{ .path = "", .manifest = "manifest" });
            self.text.info = if (command.len == 0) null else command;
            self.text.info_visible = !hidden and command.len > 0;
        } else if (std.mem.eql(u8, name, "multiwindow")) {
            self.multiwindow = true;
        } else if (std.mem.eql(u8, name, "edit")) {
            self.edit = true;
        } else if (std.mem.eql(u8, name, "force-aliasing")) {
            self.force_aliasing = true;
        } else if (std.mem.eql(u8, name, "hide-pointer")) {
            self.hide_pointer = true;
        } else if (std.mem.eql(u8, name, "no-menus")) {
            self.no_menus = true;
        } else if (std.mem.eql(u8, name, "no-screen-clip")) {
            self.no_screen_clip = true;
        } else if (std.mem.eql(u8, name, "tap-zones")) {
            self.tap_zones = true;
        } else if (std.mem.eql(u8, name, "scroll-step")) {
            const step = try std.fmt.parseInt(i32, value, 10);
            self.scroll_step = @floatFromInt(step);
        } else if (std.mem.eql(u8, name, "auto-reload")) {
            self.reload_seconds = 1;
        } else if (std.mem.eql(u8, name, "cycle-once")) {
            self.on_last = .quit;
        } else if (std.mem.eql(u8, name, "quiet")) {
            listing.quiet = true;
        } else if (std.mem.eql(u8, name, "verbose")) {
            listing.verbose = true;
        } else if (std.mem.eql(u8, name, "preload")) {
            listing.preload = true;
        } else if (std.mem.eql(u8, name, "auto-rotate") or std.mem.eql(u8, name, "draw-tinted")) {
            // Metadata orientation and tinted overlays are already enabled.
        } else if (std.mem.eql(u8, name, "montage") or std.mem.eql(u8, name, "index") or std.mem.eql(u8, name, "fullindex") or std.mem.eql(u8, name, "thumbnails")) {
            self.sheet.mode = std.meta.stringToEnum(@FieldType(@TypeOf(self.sheet), "mode"), name).?;
        } else if (std.mem.eql(u8, name, "output") or std.mem.eql(u8, name, "output-only")) {
            if (value.len == 0) return error.EmptyOutputPath;
            self.sheet.destination = value;
            self.sheet.output_only = std.mem.eql(u8, name, "output-only");
        } else if (std.mem.eql(u8, name, "thumb-width")) {
            self.sheet.thumb_width = try positiveDimension(value);
        } else if (std.mem.eql(u8, name, "thumb-height")) {
            self.sheet.thumb_height = try positiveDimension(value);
        } else if (std.mem.eql(u8, name, "limit-width")) {
            self.sheet.limit_width = try positiveDimension(value);
        } else if (std.mem.eql(u8, name, "limit-height")) {
            self.sheet.limit_height = try positiveDimension(value);
        } else if (std.mem.eql(u8, name, "index-info")) {
            var buffer: [8192]u8 = undefined;
            _ = try hooks.formatList(&buffer, value, .{ .path = "" });
            self.sheet.label = value;
        } else if (std.mem.eql(u8, name, "bg")) {
            self.sheet.background = value;
        } else if (std.mem.eql(u8, name, "image-bg")) {
            self.background = if (std.mem.eql(u8, value, "default")) .default else if (std.mem.eql(u8, value, "checks")) .checks else .{ .color = try colorValue(value) };
        } else if (std.mem.eql(u8, name, "cache-thumbnails")) {
            self.sheet.cache = true;
        } else if (std.mem.eql(u8, name, "alpha")) {
            self.sheet.opacity = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, name, "stretch")) {
            self.sheet.stretch = true;
        } else if (std.mem.eql(u8, name, "ignore-aspect")) {
            self.sheet.ignore_aspect = true;
        } else if (std.mem.startsWith(u8, name, "bg-")) {
            self.wallpaper = std.meta.stringToEnum(@import("wallpaper.zig").Mode, name[3..]) orelse return false;
        } else if (std.mem.eql(u8, name, "xinerama-index")) {
            self.xinerama_index = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, name, "no-xinerama")) {
            self.primary_only = true;
        } else if (std.mem.eql(u8, name, "no-fehbg")) {
            // Native desktop settings persist the selected image.
        } else if (std.mem.eql(u8, name, "keep-http")) {
            self.keep_http = true;
        } else if (std.mem.eql(u8, name, "no-conversion-cache")) {
            self.refresh_http = true;
        } else if (std.mem.eql(u8, name, "insecure")) {
            self.insecure = true;
        } else if (std.mem.eql(u8, name, "start-at")) {
            listing.start_at = value;
        } else if (std.mem.eql(u8, name, "on-last-slide")) {
            self.on_last = std.meta.stringToEnum(@FieldType(actions.Settings, "on_last"), value) orelse return error.InvalidEndPolicy;
        } else if (std.mem.eql(u8, name, "fit")) {
            self.auto_zoom = false;
            self.scale_down = false;
            self.fit = std.meta.stringToEnum(core.ScaleMode, value) orelse return error.InvalidFitMode;
            self.zoom = null;
        } else if (std.mem.eql(u8, name, "sort")) {
            listing.sort = std.meta.stringToEnum(catalog.Sort, value) orelse return error.InvalidSortMode;
        } else if (std.mem.eql(u8, name, "min-dimension")) {
            listing.minimum = try catalog.Dimensions.parse(value);
        } else if (std.mem.eql(u8, name, "max-dimension")) {
            listing.maximum = try catalog.Dimensions.parse(value);
        } else if (std.mem.eql(u8, name, "version-sort")) {
            listing.version_sort = true;
        } else if (std.mem.eql(u8, name, "slideshow") or std.mem.eql(u8, name, "slideshow-delay")) {
            const seconds = try std.fmt.parseFloat(f64, value);
            if (!std.math.isFinite(seconds) or seconds == 0 or @abs(seconds) > 31536000) return error.InvalidInterval;
            self.slideshow = .{ .seconds = @abs(seconds), .paused = seconds < 0 };
        } else if (std.mem.eql(u8, name, "reload")) {
            const seconds = try std.fmt.parseFloat(f64, value);
            if (!std.math.isFinite(seconds) or seconds < 0 or seconds > 31536000) return error.InvalidInterval;
            self.reload_seconds = seconds;
        } else if (std.mem.eql(u8, name, "zoom-step")) {
            const percent = try std.fmt.parseFloat(f64, value);
            if (!std.math.isFinite(percent) or percent <= 0 or percent > 10000) return error.InvalidZoom;
            self.zoom_step = 1 + percent / 100;
        } else if (std.mem.eql(u8, name, "zoom")) {
            if (std.mem.eql(u8, value, "max")) {
                self.auto_zoom = true;
                self.fit = .fit;
            } else if (std.mem.eql(u8, value, "fill")) {
                self.auto_zoom = true;
                self.fit = .fill;
            } else {
                const percent = try std.fmt.parseFloat(f64, value);
                if (!std.math.isFinite(percent) or percent <= 0 or percent > 25600) return error.InvalidZoom;
                self.zoom = percent / 100;
                if (!self.auto_zoom and !self.scale_down) self.fit = .actual;
            }
        } else if (std.mem.eql(u8, name, "no-wrap")) {
            self.no_wrap = true;
        } else if (std.mem.eql(u8, name, "allocation-stats")) {
            self.allocation_stats = true;
        } else return false;
        return true;
    }
    pub fn finish(self: *Options) !void {
        if (self.sheet.destination != null and self.sheet.mode == .viewer) self.sheet.mode = .montage;
        const modes = [_]bool{ self.wallpaper != null, self.sheet.mode != .viewer, self.listing != .none, self.multiwindow };
        var count: u8 = 0;
        for (modes) |enabled| count += @intFromBool(enabled);
        if (count > 1) return error.ConflictingModes;
    }
    pub fn windowMode(self: *const Options) hooks.Mode {
        return switch (self.sheet.mode) {
            .viewer => if (self.multiwindow) .multiwindow else .slideshow,
            .montage => .montage,
            .index, .fullindex => .index,
            .thumbnails => .thumbnails,
        };
    }
    pub fn network(self: *const Options) @import("remote.zig").Options {
        return .{ .keep_in = if (self.keep_http) self.output_dir orelse "." else null, .insecure = self.insecure, .refresh_on_revisit = self.refresh_http };
    }
    pub fn apply(self: *const Options, settings: *actions.Settings) void {
        if (self.fit) |fit| settings.fit = if (self.auto_zoom and !self.scale_down and !(self.fullscreen and self.zoom == null)) switch (fit) {
            .fit => .enlarge,
            .fill => .enlarge_fill,
            else => fit,
        } else fit;
        if (self.watch) settings.watch = true;
        if (self.reload_seconds) |seconds| {
            settings.watch = seconds > 0;
            settings.watch_seconds = @max(0.25, seconds);
        }
        if (self.keep_view) settings.keep_view = true;
        if (self.slideshow) |slideshow| settings.interval = slideshow.seconds;
        if (self.zoom_step) |step| settings.zoom_step = step;
        if (self.scroll_step) |step| settings.scroll_step = step;
        if (self.no_menus) settings.menus = false;
        if (self.no_screen_clip) settings.no_screen_clip = true;
        if (self.tap_zones) settings.tap_zones = true;
        if (self.hide_pointer) settings.hide_pointer = true;
        if (self.force_aliasing) settings.nearest = true;
        if (self.edit) settings.edit = true;
        if (self.background) |background| switch (background) {
            .default => {},
            .checks => {
                settings.checker = true;
                settings.background_color = null;
            },
            .color => |color| {
                settings.checker = false;
                settings.background_color = color;
            },
        };
        if (self.on_last) |policy| {
            settings.on_last = policy;
            settings.slideshow_loop = true;
        }
        if (self.no_wrap) settings.wrap = false;
        for (self.hooks, 0..) |command, i| if (command) |override| {
            settings.hooks[i] = override;
        };
    }
};

fn colorValue(value: []const u8) ![3]u8 {
    if (value.len > 0 and value[0] == '#') {
        const width = (value.len - 1) / 3;
        if (width == 0 or width > 4 or value.len != 1 + 3 * width) return error.InvalidBackgroundColor;
        const max: u32 = (@as(u32, 1) << @as(u5, @intCast(width * 4))) - 1;
        var rgb: [3]u8 = undefined;
        for (&rgb, 0..) |*component, index| {
            const number = try std.fmt.parseInt(u16, value[1 + index * width ..][0..width], 16);
            component.* = @intCast((@as(u32, number) * 255 + max / 2) / max);
        }
        return rgb;
    }
    const named = .{
        .{ "black", [3]u8{ 0, 0, 0 } },      .{ "white", [3]u8{ 255, 255, 255 } },
        .{ "gray", [3]u8{ 190, 190, 190 } }, .{ "grey", [3]u8{ 190, 190, 190 } },
        .{ "red", [3]u8{ 255, 0, 0 } },      .{ "green", [3]u8{ 0, 255, 0 } },
        .{ "blue", [3]u8{ 0, 0, 255 } },     .{ "yellow", [3]u8{ 255, 255, 0 } },
        .{ "cyan", [3]u8{ 0, 255, 255 } },   .{ "magenta", [3]u8{ 255, 0, 255 } },
    };
    inline for (named) |item| if (std.ascii.eqlIgnoreCase(item[0], value)) return item[1];
    return error.InvalidBackgroundColor;
}
fn positiveDimension(value: []const u8) !u16 {
    const size = try std.fmt.parseInt(u16, value, 10);
    return if (size == 0) error.InvalidDimensions else size;
}
test "CLI overrides preserve option order, inheritance and explicit disabling" {
    var parsed: Options = .{};
    var listing: catalog.Options = .{};
    var settings = actions.Settings.init();
    settings.parse("fit = shrink\nwatch = true\n");
    try std.testing.expect(try parsed.parse(.{ .name = "reload", .value = "0" }, &listing));
    try std.testing.expect(try parsed.parse(.{ .name = "zoom", .value = "150" }, &listing));
    try std.testing.expect(try parsed.parse(.{ .name = "fit", .value = "width" }, &listing));
    parsed.apply(&settings);
    try std.testing.expect(!settings.watch);
    try std.testing.expectEqual(core.ScaleMode.width, settings.fit);
    try std.testing.expect(parsed.zoom == null);
    try std.testing.expectError(error.InvalidZoom, parsed.parse(.{ .name = "zoom", .value = "nan" }, &listing));
    try std.testing.expect(try parsed.parse(.{ .name = "list" }, &listing));
    try std.testing.expect(try parsed.parse(.{ .name = "print-filelist" }, &listing));
    try std.testing.expect(parsed.listing == .paths);
    try settings.hooks[0].set("echo keep");
    try settings.hooks[1].set("echo inherited");
    try std.testing.expect(try parsed.parse(.{ .name = "action", .value = "" }, &listing));
    try std.testing.expect(try parsed.parse(.{ .name = "slideshow-delay", .value = "-2.5" }, &listing));
    parsed.apply(&settings);
    try std.testing.expectEqual(@as(usize, 0), settings.hooks[0].body().len);
    try std.testing.expectEqualStrings("echo inherited", settings.hooks[1].body());
    try std.testing.expectEqual(Slideshow{ .seconds = 2.5, .paused = true }, parsed.slideshow.?);
    try std.testing.expectEqual(2.5, settings.interval);
}

test "feh auto zoom and scale down compose independently of order and explicit zoom" {
    const cases = [_]struct { args: []const [*:0]const u8, large: f64, small: f64 }{
        .{ .args = &.{"-Z"}, .large = 1, .small = 5 },
        .{ .args = &.{"-."}, .large = 0.25, .small = 1 },
        .{ .args = &.{ "-Z", "-." }, .large = 0.25, .small = 5 },
        .{ .args = &.{ "-.", "-Z" }, .large = 0.25, .small = 5 },
        .{ .args = &.{"-Z."}, .large = 0.25, .small = 5 },
        .{ .args = &.{ "-F", "-Z" }, .large = 0.25, .small = 5 },
        .{ .args = &.{ "--zoom", "150", "-Z", "-." }, .large = 0.25, .small = 1.5 },
        .{ .args = &.{ "-.", "-Z", "--zoom", "150" }, .large = 0.25, .small = 1.5 },
        .{ .args = &.{ "-F", "-Z", "--zoom", "100" }, .large = 1, .small = 1 },
        .{ .args = &.{ "--zoom", "max" }, .large = 1, .small = 5 },
    };
    for (cases) |case| {
        var parsed: Options = .{};
        var listing: catalog.Options = .{};
        var iterator: options.Iterator = .{ .args = case.args };
        while (try iterator.next()) |item| try std.testing.expect(try parsed.parse(item, &listing));
        var settings = actions.Settings.init();
        parsed.apply(&settings);
        const viewport: core.Size = .{ .width = 1000, .height = 1000 };
        try std.testing.expectEqual(case.large, core.initialScale(settings.fit, parsed.zoom, .{ .width = 4000, .height = 2000 }, viewport));
        try std.testing.expectEqual(case.small, core.initialScale(settings.fit, parsed.zoom, .{ .width = 200, .height = 100 }, viewport));
    }
}
