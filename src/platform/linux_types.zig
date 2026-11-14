//! Native library handles and per-window storage. No opaque application ABI.
const std = @import("std");
pub const c = @import("linux_bindings");
pub const View = struct {
    width: c_int,
    height: c_int,
    scale: f64,
    x: f64 = 0,
    y: f64 = 0,
    nearest: bool = false,
    transform: c_uint = 0,
    fitted: bool = false,
    pub fn samePixels(self: View, other: View) bool {
        var pixels = self;
        pixels.fitted = other.fitted;
        return std.meta.eql(pixels, other);
    }
};
pub const Preview = struct {
    view: View,
    epoch: u64,
    checker: bool,
    surface: *c.VipsImage,
};
pub const Image = struct {
    image: ?*c.VipsImage = null,
    width: u32 = 0,
    height: u32 = 0,
    bits: u32 = 0,
    bytes: usize = 0,
    opaque_source: bool = false,
    // u32 source coordinates have at most 32 dyadic levels. This bounds
    // metadata, without imposing a byte quota on retained pixel storage.
    levels: [@bitSizeOf(u32)]?*c.VipsImage = @splat(null),
    preview: ?Preview = null,
    overview: ?*c.VipsImage = null,
    working: ?*c.VipsImage = null,
    overview_scale: f64 = 0,
    overview_nearest: c_int = 0,
};
pub const Surface = struct {
    busy: std.atomic.Value(bool) = .init(false),
    pixels: ?*anyopaque = null,
    capacity: usize = 0,
};
pub const Frame = struct {
    storage: union(enum) { owned, native: *c.VipsImage, reusable: *Surface, borrowed: struct { context: *anyopaque, release: *const fn (*anyopaque) void } } = .owned,
    pixels: ?*anyopaque = null,
    width: c_int = 0,
    height: c_int = 0,
    bytes: usize = 0,
    gpu_texture: ?*c.SDL_GPUTexture = null,
    linear: c_int = 0,
    output_epoch: u64 = 0,
};
pub const Event = struct {
    kind: c_int = 0,
    key: c_int = 0,
    x: f32 = 0,
    y: f32 = 0,
    anchor_x: f32 = 0,
    anchor_y: f32 = 0,
    modifiers: u32 = 0,
    window_id: u32 = 0,
    mouse_id: u32 = 0,
    timestamp: u64 = 0,
};
pub const Geometry = struct { width: c_int = 0, height: c_int = 0, x: c_int = 0, y: c_int = 0, valid: c_int = 0 };
pub const Metadata = struct { width: u32 = 0, height: u32 = 0, bits: u32 = 0, format: [32]u8 = @splat(0) };
pub const window_limit = 8;
pub const Selection = struct { bytes: [1048576]u8 = undefined, offsets: [16384]u32 = undefined, count: u32 = 0, used: u32 = 0, window_id: u32 = 0 };
pub const Window = struct {
    window: ?*c.SDL_Window = null,
    renderer: ?*c.SDL_Renderer = null,
    gpu: ?*c.SDL_GPUDevice = null,
    swapchain_format: c.SDL_GPUTextureFormat = 0,
    upload_texture: ?*c.SDL_GPUTexture = null,
    upload_buffer: ?*c.SDL_GPUTransferBuffer = null,
    upload_width: c_int = 0,
    upload_height: c_int = 0,
    textures: [3]?*c.SDL_Texture = @splat(null),
    texture_index: usize = 0,
    texture_width: c_int = 0,
    texture_height: c_int = 0,
    pressure_trigger: bool = false,
    upload_max_ms: f64 = 0,
    draw_max_ms: f64 = 0,
    present_max_ms: f64 = 0,
    display_profile: ?*anyopaque = null,
    display_profile_size: usize = 0,
    display_transform: c.cmsHTRANSFORM = null,
    display_prepared: bool = false,
    encoding: ?@import("color").Encoding = null,
    // The worker, pending result and displayed frame can each hold a surface.
    surfaces: [3]Surface = @splat(.{}),
    overlay_cache: ?*c.VipsImage = null,
    pipeline: std.atomic.Value(u8) = .init(0),
    profile_wanted: std.atomic.Value(bool) = .init(false),
    output_epoch: std.atomic.Value(u64) = .init(0),
    worker_epoch: u64 = 0,
    next_profile: ?*anyopaque = null,
    next_profile_size: usize = 0,
    next_profile_ready: bool = false,
    content_scale: f32 = 1,
    menu_labels: ?[*]const [*:0]const u8 = null,
    menu_count: c_int = 0,
    menu_selected: c_int = 0,
    menu_first: c_int = 0,
    menu_rows: c_int = 0,
    menu_x: c_int = 0,
    menu_y: c_int = 0,
    menu_width: c_int = 0,
    menu_row_height: c_int = 0,
    menu_scale: f32 = 1,
    menu_glyphs: [80]?*c.VipsImage = @splat(null),
    mouse_distance: f32 = 0,
    mouse_anchor_x: f32 = 0,
    mouse_anchor_y: f32 = 0,
    mouse_button: u32 = 0,
    fail_native: std.atomic.Value(u32) = .init(0),
    normal_geometry: Geometry = .{},
    psi_last_total: u64 = 0,
    psi_initialized: bool = false,
    psi_checked: i64 = 0,
    psi_window_started: i64 = 0,
};
var fallback: Window = .{};
threadlocal var active: *Window = &fallback;
// Workers bind once on entry; the event thread binds when selecting a window.
// Native SDL callbacks resolve their original window id instead of this binding.
pub fn bind(window: ?*Window) void {
    active = window orelse &fallback;
}
pub fn current() *Window {
    return active;
}
pub fn unref(value: anytype) void {
    const pointer: ?*anyopaque = @ptrCast(value);
    if (pointer) |p| c.g_object_unref(p);
}
pub fn clear(value: anytype) void {
    unref(value.*);
    value.* = null;
}
pub fn text(value: [*c]const u8) []const u8 {
    return if (value == null) "" else std.mem.span(value);
}
pub fn same(a: [*c]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, text(a), b);
}
pub fn zero(comptime T: type) T {
    return std.mem.zeroes(T);
}
pub fn bytes(pointer: ?*anyopaque, length: usize) []u8 {
    return @as([*]u8, @ptrCast(pointer.?))[0..length];
}
