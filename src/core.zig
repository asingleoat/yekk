const std = @import("std");

pub const ScaleMode = enum { shrink, fit, fill, width, height, actual, enlarge, enlarge_fill };
pub const Size = struct { width: f64, height: f64 };
pub const Point = struct { x: f64, y: f64 };
pub fn center(view: View, image: Size, viewport: Size) Point {
    const width = image.width * view.scale;
    const height = image.height * view.scale;
    var x = (viewport.width - width) / 2 + view.pan_x;
    var y = (viewport.height - height) / 2 + view.pan_y;
    if (view.scale == 1) {
        x = @round(x);
        y = @round(y);
    }
    return .{ .x = x + width / 2, .y = y + height / 2 };
}

/// All dimensions and pan offsets here are backing pixels, never AppKit points.
pub fn scaleFor(mode: ScaleMode, image: Size, viewport: Size) f64 {
    if (image.width <= 0 or image.height <= 0 or viewport.width <= 0 or viewport.height <= 0) return 1;
    const x = viewport.width / image.width;
    const y = viewport.height / image.height;
    return switch (mode) {
        .shrink => @min(1, @min(x, y)),
        .enlarge => @max(1, @min(x, y)),
        .enlarge_fill => @max(1, @max(x, y)),
        .fit => @min(x, y),
        .fill => @max(x, y),
        .width => x,
        .height => y,
        .actual => 1,
    };
}

pub fn initialScale(mode: ScaleMode, zoom: ?f64, image: Size, viewport: Size) f64 {
    const requested = zoom orelse return scaleFor(mode, image, viewport);
    return switch (mode) {
        .actual => requested,
        .shrink => @min(requested, scaleFor(.fit, image, viewport)),
        .enlarge, .enlarge_fill => if (scaleFor(mode, image, viewport) > 1) @min(requested, scaleFor(mode, image, viewport)) else requested,
        else => @min(requested, scaleFor(mode, image, viewport)),
    };
}

/// Needed source sampling density; zoom beyond 100% still only needs the source.
/// ImageIO rounds the short thumbnail edge down, so compare whole pixel counts.
pub fn hasDetail(source: Size, decoded: Size, scale: f64) bool {
    const sampling = @min(1, scale);
    return decoded.width >= @max(1, @floor(source.width * sampling)) and decoded.height >= @max(1, @floor(source.height * sampling));
}
/// Zero requests the full decoder path. No fixed thumbnail or memory ceiling.
pub fn detailEdge(source: Size, scale: f64) u32 {
    if (scale >= 1) return 0;
    return @intFromFloat(@max(1, @min(std.math.maxInt(u32), @ceil(@max(source.width, source.height) * scale))));
}

test "preview adequacy follows sampling density for all fit modes and rotations" {
    const source: Size = .{ .width = 18000, .height = 9000 };
    const preview: Size = .{ .width = 960, .height = 480 };
    const vp: Size = .{ .width = 960, .height = 640 };
    try std.testing.expect(hasDetail(source, preview, scaleFor(.fit, source, vp)));
    inline for (.{ ScaleMode.fill, ScaleMode.height }) |mode| try std.testing.expect(!hasDetail(source, preview, scaleFor(mode, source, vp)));
    const rotated: Size = .{ .width = source.height, .height = source.width };
    try std.testing.expect(!hasDetail(source, preview, scaleFor(.width, rotated, vp)));
    try std.testing.expectEqual(@as(u32, 1280), detailEdge(source, scaleFor(.fill, source, vp)));
    try std.testing.expectEqual(@as(u32, 0), detailEdge(source, 1));
    try std.testing.expect(hasDetail(source, source, 256));
    try std.testing.expect(hasDetail(.{ .width = 3, .height = 2 }, .{ .width = 2, .height = 1 }, 2.0 / 3.0));
}

pub const SurfacePurpose = enum { overview, interaction };

pub const View = struct {
    mode: ScaleMode = .shrink,
    manual: bool = false,
    use_initial_zoom: bool = true,
    scale: f64 = 1,
    pan_x: f64 = 0,
    pan_y: f64 = 0,

    pub fn initial(mode: ScaleMode, initial_scale: ?f64) View {
        return .{ .mode = mode, .scale = initial_scale orelse 1 };
    }

    // Feh keeps the numeric zoom and displayed image origin, then constrains
    // that origin to the new image. Coordinates here have positive Y downward.
    pub fn keptViewport(self: View, previous: Size, next: Size, viewport: Size) View {
        var kept = self;
        const before = center(self, previous, viewport);
        kept.manual = true;
        kept.pan_x = before.x - previous.width * self.scale / 2 - (viewport.width - next.width * self.scale) / 2;
        kept.pan_y = before.y - previous.height * self.scale / 2 - (viewport.height - next.height * self.scale) / 2;
        kept.clampViewport(next, viewport);
        return kept;
    }

    pub fn clampViewport(self: *View, image: Size, viewport: Size) void {
        const x = @abs(image.width * self.scale - viewport.width) / 2;
        const y = @abs(image.height * self.scale - viewport.height) / 2;
        self.pan_x = std.math.clamp(self.pan_x, -x, x);
        self.pan_y = std.math.clamp(self.pan_y, -y, y);
    }

    pub fn surfacePurpose(self: View) SurfacePurpose {
        return if (!self.manual and self.mode != .actual) .overview else .interaction;
    }

    pub fn reset(self: *View) void {
        self.manual = false;
        self.use_initial_zoom = true;
        self.pan_x = 0;
        self.pan_y = 0;
    }

    pub fn clamp(self: *View, image: Size, viewport: Size) void {
        const x = @max(0, (image.width * self.scale - viewport.width) / 2);
        const y = @max(0, (image.height * self.scale - viewport.height) / 2);
        self.pan_x = std.math.clamp(self.pan_x, -x, x);
        self.pan_y = std.math.clamp(self.pan_y, -y, y);
    }

    pub fn zoom(self: *View, factor: f64, anchor_x: f64, anchor_y: f64) void {
        const next = std.math.clamp(self.scale * factor, 1.0 / 65536.0, 256.0);
        const ratio = next / self.scale;
        self.pan_x = anchor_x - (anchor_x - self.pan_x) * ratio;
        self.pan_y = anchor_y - (anchor_y - self.pan_y) * ratio;
        self.scale = next;
        self.manual = true;
    }
};

test "fit policies use backing pixels and never enlarge shrink mode" {
    const t = std.testing;
    try t.expectEqual(SurfacePurpose.overview, (View{ .mode = .fit }).surfacePurpose());
    try t.expectEqual(SurfacePurpose.overview, (View{ .mode = .fill, .scale = 2 }).surfacePurpose());
    try t.expectEqual(SurfacePurpose.interaction, (View{ .manual = true, .scale = 0.5 }).surfacePurpose());
    try t.expectEqual(SurfacePurpose.interaction, (View{ .mode = .actual }).surfacePurpose());
    const image: Size = .{ .width = 4000, .height = 2000 };
    const viewport: Size = .{ .width = 1000, .height = 1000 };
    try t.expectEqual(0.25, scaleFor(.shrink, image, viewport));
    try t.expectEqual(0.5, scaleFor(.fill, image, viewport));
    try t.expectEqual(1, scaleFor(.actual, image, viewport));
    try t.expectEqual(1, scaleFor(.shrink, viewport, image));
    try t.expectEqual(2, scaleFor(.fit, viewport, image));
}

test "kept viewport preserves numeric zoom and image origin with edge constraints" {
    const viewport: Size = .{ .width = 300, .height = 200 };
    const previous: Size = .{ .width = 1000, .height = 500 };
    const next: Size = .{ .width = 1200, .height = 800 };
    const view: View = .{ .mode = .fit, .scale = 0.5, .pan_x = -70, .pan_y = 10 };
    const kept = view.keptViewport(previous, next, viewport);
    try std.testing.expect(kept.manual);
    try std.testing.expectEqual(view.scale, kept.scale);
    const before = center(view, previous, viewport);
    const after = center(kept, next, viewport);
    try std.testing.expectEqual(before.x - previous.width * view.scale / 2, after.x - next.width * kept.scale / 2);
    try std.testing.expectEqual(before.y - previous.height * view.scale / 2, after.y - next.height * kept.scale / 2);
    const small: Size = .{ .width = 200, .height = 100 };
    const limited = kept.keptViewport(next, small, viewport);
    const origin = center(limited, small, viewport);
    try std.testing.expectEqual(@as(f64, 0), origin.x - small.width * limited.scale / 2);
    try std.testing.expectEqual(@as(f64, 0), origin.y - small.height * limited.scale / 2);
}

test "pointer zoom preserves the image coordinate under the pointer" {
    var view: View = .{ .scale = 0.5, .pan_x = 40, .pan_y = -12 };
    const before_x = (200 - view.pan_x) / view.scale;
    const before_y = (-50 - view.pan_y) / view.scale;
    view.zoom(2, 200, -50);
    try std.testing.expectEqual(before_x, (200 - view.pan_x) / view.scale);
    try std.testing.expectEqual(before_y, (-50 - view.pan_y) / view.scale);
    view.clamp(.{ .width = 10, .height = 20 }, .{ .width = 1000, .height = 1000 });
    try std.testing.expectEqual(0, view.pan_x);
    try std.testing.expectEqual(0, view.pan_y);
}

test "actual-size placement keeps odd dimensions on backing-pixel edges" {
    const point = center(.{}, .{ .width = 17151, .height = 13958 }, .{ .width = 960, .height = 640 });
    const left = point.x - 17151.0 / 2.0;
    const bottom = point.y - 13958.0 / 2.0;
    try std.testing.expectEqual(@round(left), left);
    try std.testing.expectEqual(@round(bottom), bottom);
}
