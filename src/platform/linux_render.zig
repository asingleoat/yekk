//! Worker-side SDR viewport preparation using libvips and LittleCMS.
const std = @import("std");
const t = @import("linux_types.zig");
const c = t.c;
const image_api = @import("linux_image.zig");
const check = image_api.check;
const Frame = t.Frame;
const Image = t.Image;
const options = @import("build_options");
const color = @import("color");
pub fn contentScale() f32 {
    return t.current().content_scale;
}
pub fn displayChanged() void {
    t.current().profile_wanted.store(true, .release);
}
pub fn frameCurrent(frame: *const Frame) c_int {
    return @intFromBool(!t.current().profile_wanted.load(.acquire) and frame.output_epoch == t.current().output_epoch.load(.acquire));
}
pub fn begin() c_int {
    const w = t.current();
    if (w.pipeline.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) return 1;
    if (w.profile_wanted.load(.acquire) and !w.next_profile_ready) {
        w.pipeline.store(0, .release);
        return 1;
    }
    if (w.next_profile_ready) {
        c.SDL_free(w.display_profile);
        if (w.display_transform != null) c.cmsDeleteTransform(w.display_transform);
        w.display_transform = null;
        w.display_prepared = false;
        w.display_profile = w.next_profile;
        w.display_profile_size = w.next_profile_size;
        w.next_profile = null;
        w.next_profile_size = 0;
        w.next_profile_ready = false;
        t.clear(&w.overlay_cache);
        for (&w.menu_glyphs) |*glyph| t.clear(glyph);
    }
    w.worker_epoch = w.output_epoch.load(.acquire);
    return 0;
}
pub fn end() void {
    t.current().pipeline.store(0, .release);
}
pub fn contextFinish() void {
    const w = t.current();
    t.clear(&w.overlay_cache);
    for (&w.menu_glyphs) |*glyph| t.clear(glyph);
    if (w.display_transform != null) c.cmsDeleteTransform(w.display_transform);
    w.display_transform = null;
    c.SDL_free(w.display_profile);
    w.display_profile = null;
    c.SDL_free(w.next_profile);
    w.next_profile = null;
    w.display_prepared = false;
    w.display_profile_size = 0;
    dropBuffers();
}
pub fn dropBuffers() void {
    for (&t.current().surfaces) |*surface| {
        if (!surface.busy.load(.acquire)) {
            c.g_free(surface.pixels);
            surface.pixels = null;
            surface.capacity = 0;
        }
    }
}
const SurfaceLease = struct { surface: *t.Surface, reserved: u64 };
fn acquireSurface(bytes: usize) !?SurfaceLease {
    for (&t.current().surfaces) |*surface| {
        if (surface.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) continue;
        errdefer surface.busy.store(false, .release);
        var reserved: u64 = 0;
        errdefer image_api.releaseTemporary(reserved);
        if (surface.capacity < bytes) {
            c.g_free(surface.pixels);
            surface.pixels = null;
            surface.capacity = 0;
            try image_api.reserveTemporary(bytes);
            reserved = bytes;
            surface.pixels = c.g_try_malloc(bytes) orelse return error.OutOfMemory;
            surface.capacity = bytes;
        }
        return .{ .surface = surface, .reserved = reserved };
    }
    return null;
}
pub fn refreshDisplay() c_int {
    const w = t.current();
    displayChanged();
    if (w.pipeline.cmpxchgStrong(0, 2, .acquire, .monotonic) != null) return 1;
    defer w.pipeline.store(0, .release);
    if (w.next_profile_ready) return 1;
    w.content_scale = c.SDL_GetWindowDisplayScale(w.window);
    if (!std.math.isFinite(w.content_scale) or w.content_scale <= 0) w.content_scale = 1;
    w.next_profile = c.SDL_GetWindowICCProfile(w.window, &w.next_profile_size);
    w.next_profile_ready = true;
    _ = w.output_epoch.fetchAdd(1, .release);
    w.profile_wanted.store(false, .release);
    return 0;
}
// Test-only injection of an SDR display profile and UI scale.
pub fn testOutput(scale: f32, gamma: f64) c_int {
    const w = t.current();
    if (w.pipeline.cmpxchgStrong(0, 2, .acquire, .monotonic) != null) return 1;
    defer w.pipeline.store(0, .release);
    if (w.next_profile_ready) return 1;
    var data: ?*anyopaque = null;
    var size: u32 = 0;
    if (gamma > 0) {
        const white: c.cmsCIExyY = .{ .x = 0.3127, .y = 0.3290, .Y = 1 };
        const primaries: c.cmsCIExyYTRIPLE = .{ .Red = .{ .x = 0.64, .y = 0.33, .Y = 1 }, .Green = .{ .x = 0.30, .y = 0.60, .Y = 1 }, .Blue = .{ .x = 0.15, .y = 0.06, .Y = 1 } };
        const curve = c.cmsBuildGamma(null, gamma) orelse return -1;
        defer c.cmsFreeToneCurve(curve);
        const curves = [_]?*c.cmsToneCurve{ curve, curve, curve };
        const profile = c.cmsCreateRGBProfile(&white, &primaries, &curves) orelse return -1;
        defer _ = c.cmsCloseProfile(profile);
        if (c.cmsSaveProfileToMem(profile, null, &size) == 0) return -1;
        data = c.SDL_malloc(size) orelse return -1;
        if (c.cmsSaveProfileToMem(profile, data, &size) == 0) {
            c.SDL_free(data);
            return -1;
        }
    } else if (gamma < 0) {
        size = 4;
        data = c.SDL_calloc(1, size);
    }
    w.next_profile = data;
    w.next_profile_size = size;
    w.next_profile_ready = true;
    w.content_scale = scale;
    _ = w.output_epoch.fetchAdd(1, .release);
    w.profile_wanted.store(false, .release);
    return 0;
}
pub fn render(image: *Image, width: c_int, height: c_int, scale: f64, x: f64, y: f64, nearest: c_int, transform: c_uint, frame: *Frame) c_int {
    frame.* = .{};
    renderImage(image, width, height, scale, x, y, nearest != 0, transform, frame) catch |err| return if (err == error.OutOfMemory) -2 else -1;
    return 0;
}
pub const View = t.View;
const Encoder = union(enum) {
    srgb: *const color.Encoding,
    icc: *anyopaque,
    raw8,
    raw16,
};
const Output = struct {
    encoder: Encoder,
    checker: bool,
    check_size: usize,
    background: [2][3]f32,
    encoded_background: [2][4]u8 = .{ .{ 24, 24, 24, 255 }, .{ 48, 48, 48, 255 } },
    coverage: ?c.VipsRect,
    opaque_source: bool,
    fn backgroundIndex(self: *const Output, x: usize, y: usize) usize {
        return @intFromBool(self.checker and ((x / self.check_size) ^ (y / self.check_size)) & 1 != 0);
    }
};
fn composite(src: [*]const f32, background: [3]f32) [4]f32 {
    const alpha = if (std.math.isFinite(src[3])) std.math.clamp(src[3], 0, 1) else 0;
    var result: [4]f32 = .{ 0, 0, 0, 1 };
    inline for (0..3) |ch| result[ch] = (if (std.math.isFinite(src[ch])) src[ch] else 0) + background[ch] * (1 - alpha);
    return result;
}
// A borrowed output tile; clipping changes its origin without copying native
// region ownership or asking libvips to generate invisible float pixels.
const Tile = struct {
    area: c.VipsRect,
    data: [*]u8,
    stride: usize,
    fn clip(self: Tile, coverage: ?c.VipsRect) ?Tile {
        const image = coverage orelse return null;
        const left = @max(self.area.left, image.left);
        const top = @max(self.area.top, image.top);
        const right = @min(self.area.left + self.area.width, image.left + image.width);
        const bottom = @min(self.area.top + self.area.height, image.top + image.height);
        if (left >= right or top >= bottom) return null;
        return .{ .area = .{ .left = left, .top = top, .width = right - left, .height = bottom - top }, .data = self.data + @as(usize, @intCast(top - self.area.top)) * self.stride + @as(usize, @intCast(left - self.area.left)) * 4, .stride = self.stride };
    }
    fn background(self: Tile, context: *const Output) void {
        const width: usize = @intCast(self.area.width);
        for (0..@intCast(self.area.height)) |row| {
            const dst: [*]align(1) u32 = @ptrCast(self.data + row * self.stride);
            if (!context.checker) {
                @memset(dst[0..width], @as(u32, @bitCast(context.encoded_background[0])));
                continue;
            }
            var x: usize = 0;
            while (x < width) {
                const absolute = @as(usize, @intCast(self.area.left)) + x;
                const count = @min(width - x, context.check_size - absolute % context.check_size);
                const which = context.backgroundIndex(absolute, @as(usize, @intCast(self.area.top)) + row);
                @memset(dst[x..][0..count], @as(u32, @bitCast(context.encoded_background[which])));
                x += count;
            }
        }
    }
};
fn encodeOpaque(comptime Sample: type, output: Tile, input: *c.VipsRegion) void {
    const r = output.area;
    const count = @as(usize, @intCast(r.width)) * 4;
    for (0..@intCast(r.height)) |row| {
        const src_offset = (@as(usize, @intCast(r.top - input.valid.top)) + row) * @as(usize, @intCast(input.bpl)) + @as(usize, @intCast(r.left - input.valid.left)) * 4 * @sizeOf(Sample);
        const src: [*]const Sample = @ptrCast(@alignCast(input.data + src_offset));
        const dst = output.data + row * output.stride;
        if (Sample == u16) color.quantize16(src[0..count], dst[0..count]) else @memcpy(dst[0..count], src[0..count]);
    }
}
fn opaquePixel(src: [*]const f32) [4]f32 {
    var result: [4]f32 = .{ 0, 0, 0, 1 };
    inline for (0..3) |ch| result[ch] = if (std.math.isFinite(src[ch])) src[ch] else 0;
    return result;
}
fn encodeLinear(comptime opaque_source: bool, output: Tile, input: *c.VipsRegion, context: *const Output) void {
    const r = output.area;
    const channels = if (opaque_source) 3 else 4;
    for (0..@intCast(r.height)) |row| {
        const y = @as(usize, @intCast(r.top)) + row;
        const src_offset = (y - @as(usize, @intCast(input.valid.top))) * @as(usize, @intCast(input.bpl)) + @as(usize, @intCast(r.left - input.valid.left)) * channels * @sizeOf(f32);
        const src: [*]const f32 = @ptrCast(@alignCast(input.data + src_offset));
        const dst = output.data + row * output.stride;
        switch (context.encoder) {
            .srgb => |encoding| for (0..@intCast(r.width)) |x| {
                if (opaque_source) {
                    inline for (0..3) |ch| dst[x * 4 + ch] = encoding.encode(src[x * channels + ch]);
                } else {
                    const bg = context.background[context.backgroundIndex(@as(usize, @intCast(r.left)) + x, y)];
                    const pixel = composite(src + x * 4, bg);
                    inline for (0..3) |ch| dst[x * 4 + ch] = encoding.encode(pixel[ch]);
                }
                dst[x * 4 + 3] = 255;
            },
            .icc => |transform| {
                var scratch: [256][4]f32 = undefined;
                var x: usize = 0;
                while (x < @as(usize, @intCast(r.width))) {
                    const count = @min(scratch.len, @as(usize, @intCast(r.width)) - x);
                    for (scratch[0..count], 0..) |*pixel, i| pixel.* = if (opaque_source) opaquePixel(src + (x + i) * channels) else composite(src + (x + i) * 4, context.background[context.backgroundIndex(@as(usize, @intCast(r.left)) + x + i, y)]);
                    c.cmsDoTransform(transform, &scratch, dst + x * 4, @intCast(count));
                    x += count;
                }
            },
            else => unreachable,
        }
    }
}
fn encodeRegion(output_arg: [*c]c.VipsRegion, sequence: ?*anyopaque, _: ?*anyopaque, context_arg: ?*anyopaque, _: [*c]c.gboolean) callconv(.c) c_int {
    if (output_arg == null) return -1;
    const output: *c.VipsRegion = @ptrCast(output_arg);
    const input: *c.VipsRegion = @ptrCast(@alignCast(sequence.?));
    const context: *const Output = @ptrCast(@alignCast(context_arg.?));
    const tile: Tile = .{ .area = output.valid, .data = output.data, .stride = @intCast(output.bpl) };
    const visible = tile.clip(context.coverage);
    if (visible == null or !std.meta.eql(visible.?.area, tile.area)) tile.background(context);
    const image = visible orelse return 0;
    if (c.vips_region_prepare(input, &image.area) != 0) return -1;
    switch (context.encoder) {
        .raw8 => encodeOpaque(u8, image, input),
        .raw16 => encodeOpaque(u16, image, input),
        else => if (context.opaque_source) encodeLinear(true, image, input, context) else encodeLinear(false, image, input, context),
    }
    return 0;
}
/// Eagerly produces an encoded surface. Intermediate float tiles stay in the
/// worker pipeline instead of allocating a full float viewport and copying it.
pub fn prepare(image: *Image, view: View, overlay: [:0]const u8, checker: bool, frame: *Frame) c_int {
    frame.* = .{};
    prepareImpl(image, view, overlay, checker, frame) catch |err| return if (err == error.OutOfMemory) -2 else -1;
    return 0;
}
fn prepareImpl(image: *Image, view: View, overlay: [:0]const u8, checker: bool, frame: *Frame) !void {
    const w = t.current();
    if (overlay.len > 0 or w.menu_labels != null) {
        try renderImage(image, view.width, view.height, view.scale, view.x, view.y, view.nearest, view.transform, frame);
        errdefer free(frame);
        try finishLinear(frame, overlay.ptr, checker);
        return;
    }
    prepareOutput(w);
    if (image.preview) |cached| {
        if (cached.epoch == w.worker_epoch and cached.checker == checker and cached.view.samePixels(view)) {
            if (failAllocation()) return error.OutOfMemory;
            frame.* = .{ .storage = .{ .native = @ptrCast(@alignCast(c.g_object_ref(cached.surface))) }, .pixels = @constCast(c.vips_image_get_data(cached.surface)), .bytes = @as(usize, @intCast(view.width)) * @as(usize, @intCast(view.height)) * 4, .width = view.width, .height = view.height, .output_epoch = w.worker_epoch };
            return;
        }
    }
    var profile: c_int = 0;
    if (c.vips_image_get_typeof(image.image, "yekk-native-profile") != 0) _ = c.vips_image_get_int(image.image, "yekk-native-profile", &profile);
    const raw = image.opaque_source and profile == 0 and w.display_transform == null and view.scale == 1 and view.x == @floor(view.x) and view.y == @floor(view.y);
    const canvas = try buildView(image, view, if (raw) .encoded_rgba else if (image.opaque_source) .linear_rgb else .linear_rgba);
    const source = canvas.image;
    defer t.unref(source);
    if (!raw and w.display_transform == null and w.encoding == null) w.encoding = .init();
    var context: Output = .{
        .encoder = if (raw) (if (image.bits == 16) .raw16 else .raw8) else if (w.display_transform) |transform| .{ .icc = transform } else .{ .srgb = &w.encoding.? },
        .coverage = canvas.coverage,
        .opaque_source = image.opaque_source,
        .checker = checker,
        .check_size = @intFromFloat(@max(1, 12 * contentScale())),
        .background = backgroundValues(w, checker),
        .encoded_background = palette(w, checker),
    };
    if (w.display_transform) |transform| {
        const bg = context.background;
        const pixels = [2][4]f32{ bg[0] ++ [_]f32{1}, bg[1] ++ [_]f32{1} };
        c.cmsDoTransform(transform, &pixels, &context.encoded_background, 2);
    }
    if (failAllocation()) return error.OutOfMemory;
    const bytes = try std.math.mul(usize, try std.math.mul(usize, @intCast(view.width), @intCast(view.height)), 4);
    const lease = if (!view.fitted and view.scale >= 1) try acquireSurface(bytes) else null;
    if (lease == null) try image_api.reserveTemporary(bytes);
    defer image_api.releaseTemporary(if (lease) |held| held.reserved else bytes);
    const surface = if (lease) |held| held.surface else null;
    var published = false;
    defer if (!published) {
        if (surface) |slot| slot.busy.store(false, .release);
    };
    const encoded = (if (surface) |slot| c.vips_image_new_from_memory(slot.pixels, bytes, view.width, view.height, 4, c.VIPS_FORMAT_UCHAR) else c.vips_image_new()) orelse return error.OutOfMemory;
    defer t.unref(encoded);
    try check(c.vips_image_pipelinev(encoded, c.VIPS_DEMAND_STYLE_SMALLTILE, source, @as(?*anyopaque, null)));
    encoded.*.Bands = 4;
    encoded.*.BandFmt = c.VIPS_FORMAT_UCHAR;
    encoded.*.Type = c.VIPS_INTERPRETATION_sRGB;
    encoded.*.Coding = c.VIPS_CODING_NONE;
    try check(c.vips_image_generate(encoded, c.vips_start_one, encodeRegion, c.vips_stop_one, source, &context));
    if (surface) |slot| {
        frame.storage = .{ .reusable = slot };
        frame.pixels = slot.pixels;
        frame.bytes = bytes;
    } else frame.pixels = c.vips_image_write_to_memory(encoded, &frame.bytes) orelse return error.OutOfMemory;
    published = true;
    frame.width = view.width;
    frame.height = view.height;
    frame.output_epoch = w.worker_epoch;
    if (view.fitted) {
        // Retain the prepared fit surface while visiting actual size. Frames
        // hold a native reference, so replacing this cache cannot invalidate UI pixels.
        if (c.vips_image_new_from_memory(frame.pixels, frame.bytes, view.width, view.height, 4, c.VIPS_FORMAT_UCHAR)) |preview| {
            c.g_object_set_data_full(@ptrCast(preview), "yekk-preview-pixels", frame.pixels, c.g_free);
            frame.storage = .{ .native = preview };
            if (image.preview) |old| t.unref(old.surface);
            image.preview = .{ .view = view, .epoch = w.worker_epoch, .checker = checker, .surface = @ptrCast(@alignCast(c.g_object_ref(preview))) };
        }
    }
}
fn renderImage(image: *Image, width: c_int, height: c_int, scale: f64, x: f64, y: f64, nearest: bool, transform: c_uint, frame: *Frame) !void {
    const canvas = try buildView(image, .{ .width = width, .height = height, .scale = scale, .x = x, .y = y, .nearest = nearest, .transform = transform }, .linear_rgba);
    const view = canvas.image;
    defer t.unref(view);
    if (failAllocation()) return error.OutOfMemory;
    const pixels = c.vips_image_write_to_memory(view, &frame.bytes) orelse return error.OutOfMemory;
    frame.pixels = pixels;
    frame.width = width;
    frame.height = height;
    frame.linear = 1;
    frame.output_epoch = t.current().worker_epoch;
}
const Canvas = struct { image: *c.VipsImage, coverage: ?c.VipsRect };
const ViewFormat = enum { encoded_rgba, linear_rgb, linear_rgba };
fn buildView(image: *Image, view: View, format: ViewFormat) !Canvas {
    const raw = format == .encoded_rgba;
    const width = view.width;
    const height = view.height;
    const requested_scale = view.scale;
    const x = view.x;
    const y = view.y;
    const nearest = view.nearest;
    const transform = view.transform;
    if (width <= 0 or height <= 0 or !std.math.isFinite(requested_scale) or requested_scale <= 0 or !std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidViewport;
    if (!raw and image.working == null) image.working = try image_api.linearSource(image);
    var source = if (raw) image.image.? else image.working.?;
    var resized: ?*c.VipsImage = null;
    defer t.unref(resized);
    var scale = requested_scale;
    if (scale < 1 and !nearest) {
        var level: usize = 0;
        var density: f64 = 1;
        while (level + 1 < image.levels.len and density * 0.5 >= scale) {
            level += 1;
            density *= 0.5;
        }
        if (level > 0) {
            if (image.levels[level] == null) {
                var finer = level;
                while (finer > 0) {
                    finer -= 1;
                    if (image.levels[finer]) |cached| {
                        source = cached;
                        break;
                    }
                }
                var relative: f64 = 1;
                for (finer..level) |_| relative *= 0.5;
                try check(c.vips_resize(source, &resized, relative, "kernel", @as(c_int, c.VIPS_KERNEL_LANCZOS3), @as(?*anyopaque, null)));
                const bytes = @as(u64, @intCast(resized.?.Xsize)) * @as(u64, @intCast(resized.?.Ysize)) * @as(u64, @intCast(resized.?.Bands)) * @sizeOf(f32);
                try image_api.reserveTemporary(bytes);
                defer image_api.releaseTemporary(bytes);
                image.levels[level] = c.vips_image_copy_memory(resized) orelse return error.OutOfMemory;
                t.clear(&resized);
            }
            source = image.levels[level].?;
            scale /= density;
        }
    } else if (scale < 1) {
        // Nearest samples the original grid; a filtered pyramid would change it.
        if (image.overview == null or image.overview_scale != scale or image.overview_nearest == 0) {
            // Point sampling commutes with color conversion. Select source
            // samples first, then transform only the reduced pixels.
            try check(c.vips_resize(image.image, &resized, scale, "kernel", @as(c_int, c.VIPS_KERNEL_NEAREST), @as(?*anyopaque, null)));
            var reduced: Image = .{ .image = resized, .bits = image.bits, .opaque_source = image.opaque_source };
            const linear = try image_api.linearSource(&reduced);
            defer t.unref(linear);
            const bytes = @as(u64, @intCast(linear.Xsize)) * @as(u64, @intCast(linear.Ysize)) * @as(u64, @intCast(linear.Bands)) * @sizeOf(f32);
            try image_api.reserveTemporary(bytes);
            defer image_api.releaseTemporary(bytes);
            const memory = c.vips_image_copy_memory(linear) orelse return error.OutOfMemory;
            t.unref(image.overview);
            image.overview = memory;
            image.overview_scale = scale;
            image.overview_nearest = 1;
        }
        source = image.overview.?;
        scale = 1;
    }
    var rotated: ?*c.VipsImage = null;
    defer t.unref(rotated);
    var horizontal: ?*c.VipsImage = null;
    defer t.unref(horizontal);
    var vertical: ?*c.VipsImage = null;
    defer t.unref(vertical);
    if (transform & 3 != 0) {
        try check(c.vips_rot(source, &rotated, transform & 3, @as(?*anyopaque, null)));
        source = rotated.?;
    }
    if (transform & 4 != 0) {
        try check(c.vips_flip(source, &horizontal, c.VIPS_DIRECTION_HORIZONTAL, @as(?*anyopaque, null)));
        source = horizontal.?;
    }
    if (transform & 8 != 0) {
        try check(c.vips_flip(source, &vertical, c.VIPS_DIRECTION_VERTICAL, @as(?*anyopaque, null)));
        source = vertical.?;
    }
    const left: c_int = @intFromFloat(@min(@as(f64, @floatFromInt(width)), @max(0, @ceil(x - 0.5))));
    const top: c_int = @intFromFloat(@min(@as(f64, @floatFromInt(height)), @max(0, @ceil(y - 0.5))));
    const right: c_int = @intFromFloat(@min(@as(f64, @floatFromInt(width)), @max(0, @ceil(x + @as(f64, @floatFromInt(source.Xsize)) * scale - 0.5))));
    const bottom: c_int = @intFromFloat(@min(@as(f64, @floatFromInt(height)), @max(0, @ceil(y + @as(f64, @floatFromInt(source.Ysize)) * scale - 0.5))));
    var intermediate: ?*c.VipsImage = null;
    defer t.unref(intermediate);
    var result: ?*c.VipsImage = null;
    errdefer t.unref(result);
    if (right <= left or bottom <= top) {
        try check(c.vips_black(&intermediate, width, height, "bands", @as(c_int, if (format == .linear_rgb) 3 else 4), @as(?*anyopaque, null)));
        try check(c.vips_cast(intermediate, &result, (if (raw) source.BandFmt else c.VIPS_FORMAT_FLOAT), @as(?*anyopaque, null)));
    } else {
        const area_values = [_]c_int{ left, top, right - left, bottom - top };
        const area = c.vips_array_int_new(&area_values, 4) orelse return error.NativeImageFailed;
        defer c.vips_area_unref(@ptrCast(area));
        const interpolate = c.vips_interpolate_new(if (nearest) "nearest" else "bilinear") orelse return error.NativeImageFailed;
        defer t.unref(interpolate);
        if (raw) {
            try check(c.vips_extract_area(source, &intermediate, @as(c_int, @intFromFloat(@as(f64, @floatFromInt(left)) - x)), @as(c_int, @intFromFloat(@as(f64, @floatFromInt(top)) - y)), right - left, bottom - top, @as(?*anyopaque, null)));
        } else {
            try check(c.vips_affine(source, &intermediate, scale, @as(f64, 0), @as(f64, 0), scale, "oarea", area, "odx", x + (scale - 1) / 2, "ody", y + (scale - 1) / 2, "extend", @as(c_int, c.VIPS_EXTEND_COPY), "interpolate", interpolate, "premultiplied", @as(c_int, 1), @as(?*anyopaque, null)));
        }
        // Opaque production views stay RGB. The float reference/overlay path
        // explicitly requests coverage before transparent padding is added.
        var covered: ?*c.VipsImage = null;
        defer t.unref(covered);
        if (format == .linear_rgba and source.Bands == 3) try check(c.vips_bandjoin_const1(intermediate, &covered, @as(f64, 1), @as(?*anyopaque, null)));
        const visible = covered orelse intermediate.?;
        if (left == 0 and top == 0 and right == width and bottom == height) result = @ptrCast(@alignCast(c.g_object_ref(visible))) else try check(c.vips_embed(visible, &result, left, top, width, height, @as(?*anyopaque, null)));
    }
    return .{ .image = result orelse return error.NativeImageFailed, .coverage = if (left < right and top < bottom) .{ .left = left, .top = top, .width = right - left, .height = bottom - top } else null };
}

pub fn free(frame: *Frame) void {
    if (frame.storage == .borrowed) {
        const lease = frame.storage.borrowed;
        frame.* = .{};
        lease.release(lease.context);
        return;
    }
    if (frame.gpu_texture) |texture| c.SDL_ReleaseGPUTexture(t.current().gpu, texture);
    switch (frame.storage) {
        .reusable => |surface| surface.busy.store(false, .release),
        .native => |owner| t.unref(owner),
        .owned => c.g_free(frame.pixels),
        .borrowed => unreachable,
    }
    frame.* = .{};
}
pub fn failNativeNext() void {
    t.current().fail_native.store(1, .release);
}
fn failAllocation() bool {
    return options.debug_allocator and t.current().fail_native.swap(0, .acq_rel) > 0;
}
fn allocate(size: usize) ?*anyopaque {
    return if (failAllocation()) null else c.g_try_malloc(size);
}
pub fn menuConfig(labels: ?[*]const [*:0]const u8, count: c_int, selected: c_int, first: c_int, rows: c_int, x: c_int, y: c_int, width: c_int, row_height: c_int, scale: f32) void {
    const w = t.current();
    w.menu_labels = labels;
    w.menu_count = count;
    w.menu_selected = selected;
    w.menu_first = first;
    w.menu_rows = rows;
    w.menu_x = x;
    w.menu_y = y;
    w.menu_width = width;
    w.menu_row_height = row_height;
    w.menu_scale = scale;
}
pub fn textImage(text: [*:0]const u8, width: c_int, scale: f32, typeface: ?[*:0]const u8, font_file: ?[*:0]const u8) !*c.VipsImage {
    var image: ?*c.VipsImage = null;
    const environment_font = c.g_getenv("YEKK_FONT_FILE");
    const font = font_file orelse if (typeface != null) null else if (environment_font != null) environment_font else if (options.font_file) |path| path.ptr else null;
    try check(c.vips_text(&image, text, "font", typeface orelse @as([*:0]const u8, "DejaVu Sans 10"), "fontfile", @as(?[*:0]const u8, font), "dpi", @as(c_int, @intFromFloat(@round(72 * scale))), "rgba", @as(c_int, 1), "width", @as(c_int, @max(1, width)), @as(?*anyopaque, null)));
    defer t.unref(image);
    return c.vips_image_copy_memory(image) orelse error.NativeImageFailed;
}
fn drawGlyphs(frame: *Frame, glyphs: *c.VipsImage, left: c_int, top: c_int, clip_left: c_int, clip_top: c_int, clip_right: c_int, clip_bottom: c_int) !void {
    if (glyphs.Bands != 4 or glyphs.BandFmt != c.VIPS_FORMAT_UCHAR) return error.NativeImageFailed;
    const data: [*]const u8 = @ptrCast(c.vips_image_get_data(glyphs) orelse return error.NativeImageFailed);
    const pixels: [*]f32 = @ptrCast(@alignCast(frame.pixels.?));
    var y: c_int = 0;
    while (y < glyphs.Ysize) : (y += 1) {
        const py = y + top;
        if (py < @max(0, clip_top) or py >= @min(frame.height, clip_bottom)) continue;
        var x: c_int = 0;
        while (x < glyphs.Xsize) : (x += 1) {
            const px = x + left;
            if (px < @max(0, clip_left) or px >= @min(frame.width, clip_right)) continue;
            const offset: usize = @intCast((py * frame.width + px) * 4);
            const glyph: usize = @intCast((y * glyphs.Xsize + x) * 4);
            const alpha = @as(f32, @floatFromInt(data[glyph + 3])) / 255;
            for (0..3) |ch| pixels[offset + ch] = alpha + pixels[offset + ch] * (1 - alpha);
        }
    }
}
fn drawMenu(frame: *Frame) !void {
    const w = t.current();
    const labels = w.menu_labels orelse return;
    const pixels: [*]f32 = @ptrCast(@alignCast(frame.pixels.?));
    var row: c_int = 0;
    while (row < w.menu_rows) : (row += 1) {
        const item = w.menu_first + row;
        if (item >= w.menu_count or item >= w.menu_glyphs.len) break;
        const top = w.menu_y + row * w.menu_row_height;
        var y = @max(0, top);
        while (y < @min(top + w.menu_row_height, frame.height)) : (y += 1) {
            var x = @max(0, w.menu_x);
            while (x < @min(w.menu_x + w.menu_width, frame.width)) : (x += 1) {
                const offset: usize = @intCast((y * frame.width + x) * 4);
                @memcpy(pixels[offset..][0..4], if (item == w.menu_selected) &[_]f32{ 0.035, 0.12, 0.32, 1 } else &[_]f32{ 0.014, 0.014, 0.014, 1 });
            }
        }
        const glyph = &w.menu_glyphs[@intCast(item)];
        if (glyph.* == null) glyph.* = try textImage(labels[@intCast(item)], w.menu_width - 24, w.menu_scale, if (w.menu_font[0] == 0) null else &w.menu_font, w.menu_font_file);
        try drawGlyphs(frame, glyph.*.?, w.menu_x + @as(c_int, @intFromFloat(10 * w.menu_scale)), top + @divTrunc(w.menu_row_height - glyph.*.?.Ysize, 2), w.menu_x, top, w.menu_x + w.menu_width, top + w.menu_row_height);
    }
}
fn srgbToLinear(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}
pub fn finish(frame: *Frame, overlay: [*:0]const u8, checker: c_int) c_int {
    if (frame.linear == 0) return 0;
    finishLinear(frame, overlay, checker != 0) catch |err| return if (err == error.OutOfMemory) -2 else -1;
    return 0;
}
fn prepareOutput(w: *t.Window) void {
    if (!w.display_prepared) {
        w.display_prepared = true;
        if (w.display_profile != null and w.display_profile_size <= std.math.maxInt(u32)) {
            const linear = image_api.linearProfile();
            defer if (linear != null) {
                _ = c.cmsCloseProfile(linear);
            };
            const display = c.cmsOpenProfileFromMem(w.display_profile, @intCast(w.display_profile_size));
            defer if (display != null) {
                _ = c.cmsCloseProfile(display);
            };
            if (linear != null and display != null) w.display_transform = c.cmsCreateTransform(linear, c.TYPE_RGBA_FLT, display, c.TYPE_RGBA_8, c.INTENT_RELATIVE_COLORIMETRIC, @as(u32, c.cmsFLAGS_COPY_ALPHA) | @as(u32, c.cmsFLAGS_NOCACHE));
        }
    }
}
fn palette(window: *const t.Window, checker: bool) [2][4]u8 {
    if (!checker) if (window.background_color) |rgb| return @splat(rgb ++ [_]u8{255});
    return .{ .{ 24, 24, 24, 255 }, .{ 48, 48, 48, 255 } };
}
fn backgroundValues(window: *const t.Window, checker: bool) [2][3]f32 {
    const bytes = palette(window, checker);
    var values: [2][3]f32 = undefined;
    for (&values, bytes) |*rgb, encoded| {
        for (rgb, encoded[0..3]) |*component, value| component.* = @floatCast(srgbToLinear(@as(f64, @floatFromInt(value)) / 255));
    }
    return values;
}
fn finishLinear(frame: *Frame, overlay: [*:0]const u8, checker: bool) !void {
    const w = t.current();
    prepareOutput(w);
    if (w.display_transform == null and w.encoding == null) w.encoding = .init();
    const background_values = backgroundValues(w, checker);
    const pixels: [*]f32 = @ptrCast(@alignCast(frame.pixels.?));
    const check_size: usize = @intFromFloat(@max(1, 12 * contentScale()));
    if (w.display_transform == null and overlay[0] == 0 and w.menu_labels == null) {
        const encoded: [*]u8 = @ptrCast(frame.pixels.?);
        for (0..@intCast(frame.height)) |row| for (0..@intCast(frame.width)) |x| {
            const offset = (row * @as(usize, @intCast(frame.width)) + x) * 4;
            const alpha = if (std.math.isFinite(pixels[offset + 3])) std.math.clamp(pixels[offset + 3], 0, 1) else 0;
            const background = background_values[@intFromBool(checker and ((row / check_size) ^ (x / check_size)) & 1 != 0)];
            inline for (0..3) |channel| {
                const value = (if (std.math.isFinite(pixels[offset + channel])) pixels[offset + channel] else 0) + background[channel] * (1 - alpha);
                encoded[offset + channel] = w.encoding.?.encode(value);
            }
            encoded[offset + 3] = 255;
        };
        frame.bytes = @as(usize, @intCast(frame.width)) * @as(usize, @intCast(frame.height)) * 4;
        frame.linear = 0;
        return;
    }
    for (0..@intCast(frame.height)) |row| for (0..@intCast(frame.width)) |x| {
        const offset = (row * @as(usize, @intCast(frame.width)) + x) * 4;
        const alpha = if (std.math.isFinite(pixels[offset + 3])) std.math.clamp(pixels[offset + 3], 0, 1) else 0;
        const background = background_values[@intFromBool(checker and ((row / check_size) ^ (x / check_size)) & 1 != 0)];
        for (0..3) |ch| pixels[offset + ch] = (if (std.math.isFinite(pixels[offset + ch])) pixels[offset + ch] else 0) + background[ch] * (1 - alpha);
        pixels[offset + 3] = 1;
    };
    if (overlay[0] != 0) {
        var cached: [*c]const u8 = null;
        var width: c_int = 0;
        if (w.overlay_cache != null) {
            _ = c.vips_image_get_string(w.overlay_cache, "yekk-overlay", &cached);
            _ = c.vips_image_get_int(w.overlay_cache, "yekk-overlay-width", &width);
        }
        if (!t.same(cached, std.mem.span(overlay)) or width != frame.width) {
            const valid = c.g_utf8_make_valid(overlay, -1);
            defer c.g_free(valid);
            const escaped = c.g_markup_escape_text(valid, -1);
            defer c.g_free(escaped);
            const resident = try textImage(@ptrCast(escaped), frame.width - 16, contentScale(), if (w.overlay_font[0] == 0) null else &w.overlay_font, w.overlay_font_file);
            c.vips_image_set_string(resident, "yekk-overlay", overlay);
            c.vips_image_set_int(resident, "yekk-overlay-width", frame.width);
            t.clear(&w.overlay_cache);
            w.overlay_cache = resident;
        }
        const glyph = w.overlay_cache.?;
        const padding: c_int = @intFromFloat(8 * contentScale());
        var y = @divTrunc(padding, 2);
        while (y < @min(glyph.Ysize + @divTrunc(padding * 3, 2), frame.height)) : (y += 1) {
            var x = @divTrunc(padding, 2);
            while (x < @min(glyph.Xsize + @divTrunc(padding * 3, 2), frame.width)) : (x += 1) {
                const offset: usize = @intCast((y * frame.width + x) * 4);
                for (0..3) |ch| pixels[offset + ch] /= 3;
            }
        }
        try drawGlyphs(frame, glyph, padding, padding, 0, 0, frame.width, frame.height);
    }
    try drawMenu(frame);
    if (w.display_transform == null) {
        const encoded: [*]u8 = @ptrCast(frame.pixels.?);
        for (0..@as(usize, @intCast(frame.width)) * @as(usize, @intCast(frame.height))) |index| {
            inline for (0..3) |channel| encoded[index * 4 + channel] = w.encoding.?.encode(pixels[index * 4 + channel]);
            encoded[index * 4 + 3] = 255;
        }
        frame.bytes = @as(usize, @intCast(frame.width)) * @as(usize, @intCast(frame.height)) * 4;
        frame.linear = 0;
        return;
    }
    const size = @as(usize, @intCast(frame.width)) * @as(usize, @intCast(frame.height)) * 4;
    const data = allocate(size) orelse return error.OutOfMemory;
    const encoded: [*]u8 = @ptrCast(data);
    if (w.display_transform != null) {
        for (0..@intCast(frame.height)) |row| {
            const offset = row * @as(usize, @intCast(frame.width)) * 4;
            c.cmsDoTransform(w.display_transform, pixels + offset, encoded + offset, @intCast(frame.width));
        }
    }
    c.g_free(frame.pixels);
    frame.pixels = data;
    frame.bytes = size;
    frame.linear = 0;
}
pub fn save(frame: *Frame, path: [*:0]const u8) c_int {
    const image = c.vips_image_new_from_memory(frame.pixels, frame.bytes, frame.width, frame.height, 4, c.VIPS_FORMAT_UCHAR) orelse return -1;
    defer t.unref(image);
    const w = t.current();
    if (w.display_transform != null) c.vips_image_set_blob_copy(image, c.VIPS_META_ICC_NAME, w.display_profile, w.display_profile_size);
    return c.vips_image_write_to_file(image, path, @as(?*anyopaque, null));
}
