//! Shared keyboard view semantics in backing pixels, with positive Y downward.
const actions = @import("actions.zig");
const core = @import("core.zig");
pub fn apply(action: actions.Action, settings: *actions.Settings, view: *core.View, viewport: core.Size) bool {
    switch (action) {
        .zoom_in => view.zoom(settings.zoom_step, 0, 0),
        .zoom_out => view.zoom(1 / settings.zoom_step, 0, 0),
        .actual, .fit, .shrink, .fill, .fit_width, .fit_height => {
            view.mode = switch (action) {
                .actual => .actual,
                .fit => .fit,
                .shrink => .shrink,
                .fill => .fill,
                .fit_width => .width,
                else => .height,
            };
            view.reset();
            view.use_initial_zoom = false;
            if (action == .actual) view.scale = 1;
        },
        .auto_zoom => {
            settings.fit = switch (settings.fit) {
                .fit, .fill => .shrink,
                .enlarge, .enlarge_fill => .actual,
                else => .fit,
            };
            view.mode = settings.fit;
            view.reset();
        },
        .pan_left => {
            view.pan_x -= 64;
            view.manual = true;
        },
        .pan_right => {
            view.pan_x += 64;
            view.manual = true;
        },
        .pan_up => {
            view.pan_y -= 64;
            view.manual = true;
        },
        .pan_down => {
            view.pan_y += 64;
            view.manual = true;
        },
        .pan_left_page => {
            view.pan_x -= viewport.width * 0.75;
            view.manual = true;
        },
        .pan_right_page => {
            view.pan_x += viewport.width * 0.75;
            view.manual = true;
        },
        .pan_up_page => {
            view.pan_y -= viewport.height * 0.75;
            view.manual = true;
        },
        .pan_down_page => {
            view.pan_y += viewport.height * 0.75;
            view.manual = true;
        },
        else => return false,
    }
    return true;
}
pub fn transform(action: actions.Action, rotation: *u2, mirror: *u2) bool {
    switch (action) {
        .rotate_right => rotation.* +%= 1,
        .rotate_left => rotation.* -%= 1,
        .mirror_horizontal => mirror.* ^= 1,
        .mirror_vertical => mirror.* ^= 2,
        else => return false,
    }
    return true;
}
pub fn reloadInterval(settings: *actions.Settings, increase: bool) void {
    settings.watch_seconds = @max(0, (if (settings.watch) settings.watch_seconds else @as(f64, 0)) + @as(f64, if (increase) 1 else -1));
    settings.watch = settings.watch_seconds > 0;
}
pub fn isScaleMode(action: actions.Action) bool {
    return switch (action) {
        .actual, .fit, .shrink, .fill, .fit_width, .fit_height, .auto_zoom => true,
        else => false,
    };
}
