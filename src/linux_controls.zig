//! UI-owned session state. Catalog identities never move while workers use them.
const std = @import("std");
const core = @import("core.zig");
const actions = @import("actions.zig");
const catalog = @import("catalog.zig");
const navigation = @import("navigation.zig");
const view_actions = @import("view_actions.zig");
pub const Request = struct {
    index: usize = 0,
    revision: u64 = 1,
    selection_serial: u64 = 0,
    width: c_int = 1100,
    height: c_int = 760,
    view: core.View = .{},
    navigation: union(enum) { keep, reset: core.View } = .{ .reset = .{} },
    view_source: ?struct { index: usize, revision: u64, size: core.Size } = null,
    nearest: bool = false,
    initial_zoom: ?f64 = null,
    rotation: u2 = 0,
    mirror: u2 = 0,
    previous: ?usize = null,
    next: ?usize = null,
    watch: bool = false,
    watch_seconds: f64 = 1,
    overlay: [4096:0]u8 = @splat(0),
    overlay_len: usize = 0,
    checker: bool = false,
    info: bool = false,
    ordinal: usize = 1,
    active_count: usize = 1,
    playing: bool = false,
    menu: @import("linux_menu.zig").Menu = .{},

    pub fn forNeighbor(self: Request, index: usize) Request {
        var next = self;
        next.index = index;
        switch (self.navigation) {
            .keep => {},
            .reset => |view| {
                next.view = view;
                next.view_source = null;
                next.rotation = 0;
                next.mirror = 0;
            },
        }
        return next;
    }
};
pub const Effect = struct { changed: bool = false, reload: bool = false, quit: bool = false, quit_all: bool = false, removed: ?usize = null, hook: ?usize = null, platform: ?actions.Action = null };
pub const Controller = struct {
    settings: actions.Settings = .{},
    initial_zoom: ?f64 = null,
    order: [catalog.capacity]usize = undefined,
    count: usize = 0,
    position: usize = 0,
    playing: bool = false,
    deadline: ?f64 = null,
    shown_index: ?usize = null,
    held_advance: navigation.HeldAdvance = .{},
    selection_serial: u64 = 0,
    shuffle_wrap: bool = false,
    info: bool = false,
    help: bool = false,
    draw_filename: bool = false,
    draw_actions: bool = false,
    random: std.Random.DefaultPrng = .init(0),

    pub fn start(self: *Controller, count: usize, initial: usize, request: *Request) void {
        self.count = count;
        self.position = initial;
        for (self.order[0..count], 0..) |*id, i| id.* = i;
        self.neighbors(request);
    }
    pub fn neighbors(self: *const Controller, request: *Request) void {
        self.snapshotNavigation(request);
        request.selection_serial = self.selection_serial;
        if (self.count == 0) {
            request.next = null;
            request.previous = null;
            return;
        }
        request.index = self.order[self.position];
        request.next = if (self.position + 1 < self.count) self.order[self.position + 1] else if (self.settings.wrap and self.count > 1) self.order[0] else null;
        request.previous = if (self.position > 0) self.order[self.position - 1] else if (self.settings.wrap and self.count > 1) self.order[self.count - 1] else null;
        request.watch = self.settings.watch;
        request.watch_seconds = self.settings.watch_seconds;
    }
    pub fn snapshotNavigation(self: *const Controller, request: *Request) void {
        request.initial_zoom = self.initial_zoom;
        request.navigation = if (self.settings.keep_view) .keep else .{ .reset = .initial(self.settings.fit, self.initial_zoom) };
    }
    pub fn select(self: *Controller, position: usize, request: *Request) bool {
        if (self.count == 0 or position >= self.count) return false;
        if (self.position == position and self.shown_index != null) return false;
        self.position = position;
        self.selection_serial += 1;
        self.held_advance.selected();
        if (!self.settings.keep_view) {
            request.view = .initial(self.settings.fit, self.initial_zoom);
            request.view_source = null;
            request.rotation = 0;
            request.mirror = 0;
        }
        self.deadline = null;
        self.shown_index = null;
        self.neighbors(request);
        request.revision += 1;
        return true;
    }
    pub fn removeId(self: *Controller, id: usize, request: *Request) Effect {
        for (self.order[0..self.count], 0..) |candidate, position| if (candidate == id) {
            const selected = self.position == position;
            self.count -= 1;
            std.mem.copyForwards(usize, self.order[position..self.count], self.order[position + 1 .. self.count + 1]);
            if (self.count == 0) return .{ .removed = id, .quit = true };
            if (position < self.position) self.position -= 1;
            self.position = @min(self.position, self.count - 1);
            if (selected) {
                self.shown_index = null;
                self.deadline = null;
                _ = self.select(self.position, request);
            }
            self.neighbors(request);
            return .{ .removed = id, .changed = selected };
        };
        return .{};
    }
    pub fn step(self: *Controller, backwards: bool, timed: bool, request: *Request) Effect {
        if (self.count == 0) return .{ .quit = true };
        switch (navigation.step(self.position, self.count, if (backwards) -1 else 1, timed, &self.settings)) {
            .stay => return .{},
            .quit => return .{ .quit = true },
            .hold => {
                self.playing = false;
                self.deadline = null;
                return .{};
            },
            .select => |target| {
                if (!backwards and target.wrapped and self.shuffle_wrap) self.random.random().shuffle(usize, self.order[0..self.count]);
                if (self.count == 1) {
                    self.deadline = null;
                    return .{};
                }
                return .{ .changed = self.select(target.position, request) };
            },
        }
    }
    pub fn presented(self: *Controller, index: usize, now: f64) void {
        if (self.count == 0 or self.order[self.position] != index) return;
        self.held_advance.presented(now);
        if (self.shown_index != index) {
            self.shown_index = index;
            self.deadline = if (self.playing and self.settings.interval > 0) now + self.settings.interval else null;
        }
    }
    pub fn tick(self: *Controller, now: f64, failed: bool, request: *Request) Effect {
        if (!self.playing or self.settings.interval <= 0) return .{};
        if (failed and self.deadline == null) self.deadline = now + self.settings.interval;
        if (self.deadline) |at| if (now >= at) {
            self.deadline = now + self.settings.interval;
            return self.step(false, true, request);
        };
        return .{};
    }
    pub fn apply(self: *Controller, action: actions.Action, request: *Request, entries: []const catalog.Entry, now: f64) Effect {
        if (self.count == 0) return .{ .quit = true };
        const number = @backingInt(action);
        if (number <= @backingInt(actions.Action.action_9)) return .{ .hook = number };
        if (view_actions.apply(action, &self.settings, &request.view, .{ .width = @floatFromInt(request.width), .height = @floatFromInt(request.height) })) {
            return .{ .changed = true };
        }
        if (self.settings.edit and view_actions.editOrientation(action) != null) return .{ .platform = action };
        if (view_actions.transform(action, &request.rotation, &request.mirror)) return .{ .changed = true };
        switch (action) {
            .next => return self.step(false, false, request),
            .previous => return self.step(true, false, request),
            .first => return .{ .changed = self.select(0, request) },
            .last => return .{ .changed = self.select(self.count - 1, request) },
            .jump_forward, .jump_back => {
                return .{ .changed = self.select(navigation.jump(self.position, self.count, action == .jump_forward), request) };
            },
            .random => return .{ .changed = self.select(self.random.random().uintLessThan(usize, self.count), request) },
            .next_directory, .previous_directory => {
                const target = navigation.directory(entries, self.order[0..self.count], self.position, action == .next_directory) orelse return .{};
                return .{ .changed = self.select(target, request) };
            },
            .remove => {
                return self.removeId(request.index, request);
            },
            .quit => return .{ .quit = true, .quit_all = true },
            .close => return .{ .quit = true },
            .reload => return .{ .changed = true, .reload = true },
            .render => return .{ .changed = true },
            .nearest => request.nearest = !request.nearest,
            .keep_view => {
                self.settings.keep_view = !self.settings.keep_view;
                return .{ .changed = true };
            },
            .wrap => {
                self.settings.wrap = !self.settings.wrap;
                self.neighbors(request);
                return .{ .changed = true };
            },
            .watch => {
                self.settings.watch = !self.settings.watch;
                self.neighbors(request);
                return .{ .changed = true };
            },
            .reload_plus, .reload_minus => {
                view_actions.reloadInterval(&self.settings, action == .reload_plus);
                self.neighbors(request);
                return .{ .changed = true };
            },
            .slideshow => {
                self.playing = !self.playing;
                if (self.settings.interval <= 0) self.settings.interval = 3;
                self.deadline = if (self.playing and self.shown_index != null) now + self.settings.interval else null;
                return .{ .changed = true };
            },
            else => return .{ .platform = action },
        }
        return .{ .changed = true };
    }
};
pub fn orientedSize(width: u32, height: u32, rotation: u2) core.Size {
    return .{ .width = @floatFromInt(if (rotation & 1 == 0) width else height), .height = @floatFromInt(if (rotation & 1 == 0) height else width) };
}

test "neighbor prediction follows live keep-view and auto-zoom settings" {
    var model: Controller = .{ .settings = .init() };
    var request: Request = .{};
    model.start(2, 0, &request);
    for ([_]actions.Action{ .keep_view, .auto_zoom, .keep_view, .auto_zoom }) |action| {
        _ = model.apply(action, &request, &.{}, 0);
        request.view.manual = true;
        request.view.scale = 0.5;
        request.view.pan_x = 19;
        request.rotation = 1;
        request.mirror = 2;
        model.snapshotNavigation(&request);
        const target = if (model.position == 0) @as(usize, 1) else 0;
        const predicted = request.forNeighbor(target);
        try std.testing.expect(model.select(target, &request));
        try std.testing.expectEqual(predicted.view, request.view);
        try std.testing.expectEqual(predicted.rotation, request.rotation);
        try std.testing.expectEqual(predicted.mirror, request.mirror);
    }
}

test "explicit initial zoom remains the navigation default after temporary scale changes" {
    var model: Controller = .{ .settings = .init(), .initial_zoom = 1.5 };
    model.settings.fit = .actual;
    var request: Request = .{};
    model.start(3, 0, &request);
    try std.testing.expect(model.select(1, &request));
    try std.testing.expectEqual(@as(?f64, 1.5), request.initial_zoom);
    const predicted = request.forNeighbor(2);
    try std.testing.expect(model.select(2, &request));
    try std.testing.expectEqual(predicted.view, request.view);
    try std.testing.expectEqual(@as(?f64, 1.5), request.initial_zoom);
    _ = model.apply(.fit, &request, &.{}, 0);
    try std.testing.expect(!request.view.use_initial_zoom);
    try std.testing.expect(model.select(0, &request));
    try std.testing.expectEqual(@as(?f64, 1.5), request.initial_zoom);
    try std.testing.expect(request.view.use_initial_zoom);
}

test "slideshow starts its delay after presentation and respects hold/quit" {
    var model: Controller = .{ .settings = .init(), .playing = true };
    model.settings.interval = 2;
    var request: Request = .{};
    model.start(2, 0, &request);
    try std.testing.expect(!model.tick(100, false, &request).changed);
    model.presented(0, 100);
    try std.testing.expect(!model.tick(101, false, &request).changed);
    try std.testing.expect(model.tick(102, false, &request).changed);
    try std.testing.expectEqual(@as(usize, 1), request.index);
    try std.testing.expect(!model.tick(200, false, &request).changed);
    model.settings.on_last = .hold;
    model.presented(1, 200);
    try std.testing.expect(!model.tick(202, false, &request).quit);
    try std.testing.expect(!model.playing);
    model.settings.on_last = .quit;
    model.playing = true;
    model.deadline = 203;
    try std.testing.expect(model.tick(203, false, &request).quit);
}
test "removal retains stable catalog IDs and nonwrapping neighbor order" {
    var model: Controller = .{ .settings = .init() };
    model.settings.wrap = false;
    var request: Request = .{};
    model.start(3, 0, &request);
    try std.testing.expect(request.previous == null);
    const effect = model.apply(.remove, &request, &.{}, 0);
    try std.testing.expectEqual(@as(?usize, 0), effect.removed);
    try std.testing.expectEqual(@as(usize, 1), request.index);
    try std.testing.expectEqual(@as(?usize, 2), request.next);
    _ = model.step(false, false, &request);
    try std.testing.expect(request.next == null);
    try std.testing.expect(!model.step(false, false, &request).changed);
}

// Separate presses may skip a slow image. Native auto-repeat uses HeldAdvance.
test "separate navigation commands advance and reverse before presentation" {
    var model: Controller = .{ .settings = .init() };
    model.settings.wrap = false;
    var request: Request = .{};
    model.start(32, 0, &request);
    model.presented(0, 0);
    for (0..12) |_| try std.testing.expect(model.step(false, false, &request).changed);
    try std.testing.expectEqual(@as(usize, 12), request.index);
    try std.testing.expect(model.shown_index == null);
    for (0..7) |_| try std.testing.expect(model.step(true, false, &request).changed);
    try std.testing.expectEqual(@as(usize, 5), request.index);
    model.presented(request.index, 1);
    try std.testing.expectEqual(@as(?usize, 5), model.shown_index);
}

test "held steps wait for presentation while a fresh press skips a pending image" {
    var model: Controller = .{ .settings = .init() };
    var request: Request = .{};
    model.start(8, 0, &request);
    model.presented(0, 0);
    model.held_advance.press(9, .next);
    try std.testing.expect(model.step(false, false, &request).changed);
    for (0..100) |_| model.held_advance.repeat(9, .next);
    try std.testing.expect(model.held_advance.take(100) == null);
    model.presented(0, 101); // A stale completion cannot admit another step.
    try std.testing.expect(model.held_advance.take(102) == null);
    model.presented(1, 103);
    const direction = model.held_advance.take(103).?;
    try std.testing.expect(model.step(direction == .previous, false, &request).changed);
    try std.testing.expectEqual(@as(usize, 2), request.index);
    model.held_advance.repeat(9, .next);
    model.held_advance.release(9);
    model.held_advance.press(9, .next);
    try std.testing.expect(model.step(false, false, &request).changed);
    try std.testing.expectEqual(@as(usize, 3), request.index); // Image 2 need not finish.
    model.held_advance.repeat(9, .next);
    model.held_advance.release(9);
    model.presented(3, 104);
    try std.testing.expect(model.held_advance.take(105) == null);
    try std.testing.expectEqual(@as(usize, 3), request.index);
}
