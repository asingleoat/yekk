//! libvips / LittleCMS adapter. Native source samples remain 8 or 16 bit;
//! floating point is an internal linear-light working format, not HDR support.
const std = @import("std");
const t = @import("linux_types.zig");
const c = t.c;
const Image = t.Image;
const Metadata = t.Metadata;
const tiff = @import("tiff_pixels");
const build_options = @import("build_options");
const Extent = @import("raster").Extent;
const source_file = @import("source");
const jxl = @import("jxl_pixels");
var decode_workers: usize = 1;
var busy_workers: std.atomic.Value(usize) = .init(0);
var srgb16: [65536]f32 = undefined;
var srgb8: [256]f32 = undefined;
const Error = error{ NativeImageFailed, OutOfMemory, UnsupportedSampleFormat };
pub fn check(status: c_int) Error!void {
    if (status != 0) return error.NativeImageFailed;
}
pub fn init(workers: c_int) c_int {
    if (c.vips_init("yekk") != 0) return -1;
    c.vips_block_untrusted_set(1);
    c.vips_cache_set_max(0);
    const selected: c_int = if (workers > 0) workers else @intCast(@min(std.math.maxInt(c_int), @import("linux_resources.zig").physicalCores()));
    c.vips_concurrency_set(selected);
    decode_workers = @intCast(@max(1, c.vips_concurrency_get()));
    for (&srgb16, 0..) |*value, sample| {
        var unused: f32 = undefined;
        if (c.vips_col_sRGB2scRGB_16(@intCast(sample), @intCast(sample), @intCast(sample), value, &unused, &unused) != 0) return -1;
    }
    for (&srgb8, 0..) |*value, sample| {
        var unused: f32 = undefined;
        if (c.vips_col_sRGB2scRGB_8(@intCast(sample), @intCast(sample), @intCast(sample), value, &unused, &unused) != 0) return -1;
    }
    return 0;
}
pub fn shutdown() void {
    c.vips_shutdown();
}
pub fn lastError() [*:0]const u8 {
    return c.vips_error_buffer();
}
pub fn probe(path: [*:0]const u8, result: *Metadata) c_int {
    const file = source_file.open(std.mem.span(path), false) catch return -1;
    defer file.close();
    if (std.meta.activeTag(file.format) == .jxl) {
        const header = jxl.probe(file) catch return -1;
        result.* = .{ .width = header.extent.width, .height = header.extent.height, .bits = header.bits };
        @memcpy(result.format[0..3], "jxl");
        return 0;
    }
    const candidate = if (std.meta.activeTag(file.format) == .pnm) @import("pnm").Plan.open(std.mem.span(path), null) catch return -1 else null;
    if (candidate) |plan| {
        defer plan.deinit();
        result.* = .{ .width = plan.extent.width, .height = plan.extent.height, .bits = if (plan.maximum > 255) 16 else 8 };
        const format = plan.format();
        @memcpy(result.format[0..format.len], format);
        return 0;
    }
    const input = openImage(file, false) catch return -1;
    defer t.unref(input);
    const extent = Extent.init(input.*.Xsize, input.*.Ysize) catch return -1;
    if (input.*.BandFmt < c.VIPS_FORMAT_UCHAR or input.*.BandFmt >= c.VIPS_FORMAT_LAST) return -1;
    const orientation = c.vips_image_get_orientation(input);
    if (orientation < 1 or orientation > 8) return -1;
    result.* = .{ .width = if (orientation >= 5) extent.height else extent.width, .height = if (orientation >= 5) extent.width else extent.height, .bits = @intCast(c.vips_format_sizeof(input.*.BandFmt) * 8) };
    var loader: [*c]const u8 = "unknown";
    _ = c.vips_image_get_string(input, "vips-loader", &loader);
    const name = t.text(loader);
    const end = std.mem.indexOf(u8, name, "load") orelse name.len;
    const length = @min(end, result.format.len - 1);
    @memcpy(result.format[0..length], name[0..length]);
    return 0;
}
pub fn formats() void {
    inline for (.{ ".bmp", ".pbm", ".pgm", ".ppm", ".pnm", ".jxl" }) |suffix| _ = c.puts(suffix);
    // Report enabled image readers, rather than every installed native plugin.
    inline for (.{
        .{ "jpegload_source", .{ ".jpg", ".jpeg", ".jpe", ".jfif" } },
        .{ "pngload_source", .{".png"} },
        .{ "tiffload_source", .{ ".tif", ".tiff" } },
        .{ "gifload_source", .{".gif"} },
        .{ "webpload_source", .{".webp"} },
        .{ "heifload_source", .{ ".heic", ".heif", ".avif" } },
    }) |entry| {
        if (c.vips_operation_new(entry[0])) |operation| {
            defer t.unref(operation);
            if (c.vips_operation_get_flags(operation) & (c.VIPS_OPERATION_BLOCKED | c.VIPS_OPERATION_UNTRUSTED) == 0) inline for (entry[1]) |suffix| { _ = c.puts(suffix); };
        }
    }
}
pub fn linearProfile() c.cmsHPROFILE {
    const white: c.cmsCIExyY = .{ .x = 0.3127, .y = 0.3290, .Y = 1 };
    const primaries: c.cmsCIExyYTRIPLE = .{ .Red = .{ .x = 0.64, .y = 0.33, .Y = 1 }, .Green = .{ .x = 0.30, .y = 0.60, .Y = 1 }, .Blue = .{ .x = 0.15, .y = 0.06, .Y = 1 } };
    const curve = c.cmsBuildGamma(null, 1) orelse return null;
    defer c.cmsFreeToneCurve(curve);
    const curves = [_]?*c.cmsToneCurve{ curve, curve, curve };
    return c.cmsCreateRGBProfile(&white, &primaries, &curves);
}
fn destroyTransform(data: ?*anyopaque) callconv(.c) void {
    c.cmsDeleteTransform(data);
}
fn destroyProfile(data: ?*anyopaque) callconv(.c) void {
    _ = c.cmsCloseProfile(data);
}
fn releaseObject(data: ?*anyopaque) callconv(.c) void {
    t.unref(data);
}
fn generate(output_arg: [*c]c.VipsRegion, sequence: ?*anyopaque, _: ?*anyopaque, transform: ?*anyopaque, _: [*c]c.gboolean) callconv(.c) c_int {
    const output = &output_arg[0];
    const input: *c.VipsRegion = @ptrCast(@alignCast(sequence.?));
    const rectangle = &output.valid;
    if (c.vips_region_prepare(input, rectangle) != 0) return -1;
    const profile = c.g_object_get_data(@ptrCast(output.im), "yekk-input-profile");
    const alpha = input.im.*.Bands > c.cmsChannelsOf(c.cmsGetColorSpace(profile));
    var y = rectangle.top;
    while (y < rectangle.top + rectangle.height) : (y += 1) {
        const offset_out = @as(usize, @intCast(y - output.valid.top)) * @as(usize, @intCast(output.bpl)) + @as(usize, @intCast(rectangle.left - output.valid.left)) * @as(usize, @intCast(output.im.*.Bands)) * @sizeOf(f32);
        const pixel_size = c.vips_format_sizeof(input.im.*.BandFmt) * @as(usize, @intCast(input.im.*.Bands));
        const offset_in = @as(usize, @intCast(y - input.valid.top)) * @as(usize, @intCast(input.bpl)) + @as(usize, @intCast(rectangle.left - input.valid.left)) * pixel_size;
        const line: [*]f32 = @ptrCast(@alignCast(output.data + offset_out));
        c.cmsDoTransform(transform, input.data + offset_in, line, @intCast(rectangle.width));
        if (!alpha and output.im.*.Bands == 4) for (0..@intCast(rectangle.width)) |x| {
            line[x * 4 + 3] = 1;
        };
    }
    return 0;
}
fn iccLinear(source: *c.VipsImage, opaque_source: bool) Error!*c.VipsImage {
    var data: ?*const anyopaque = null;
    var size: usize = 0;
    try check(c.vips_image_get_blob(source, c.VIPS_META_ICC_NAME, &data, &size));
    if (size > std.math.maxInt(u32)) return error.NativeImageFailed;
    const input = c.cmsOpenProfileFromMem(data, @intCast(size)) orelse return error.NativeImageFailed;
    var owned_profile = true;
    defer if (owned_profile) {
        _ = c.cmsCloseProfile(input);
    };
    const linear = linearProfile() orelse return error.NativeImageFailed;
    defer _ = c.cmsCloseProfile(linear);
    const extra = source.Bands - @as(c_int, @intCast(c.cmsChannelsOf(c.cmsGetColorSpace(input))));
    var format = c.cmsFormatterForColorspaceOfProfile(input, @intCast(c.vips_format_sizeof(source.BandFmt)), 0);
    if (extra < 0 or extra > 1 or format == 0) return error.NativeImageFailed;
    format |= @as(u32, @intCast(extra)) << 7; // LCMS EXTRA_SH.
    const transform = c.cmsCreateTransform(input, format, linear, (if (opaque_source) c.TYPE_RGB_FLT else c.TYPE_RGBA_FLT), c.INTENT_RELATIVE_COLORIMETRIC, @as(u32, c.cmsFLAGS_NOCACHE) | @as(u32, if (extra != 0 and !opaque_source) c.cmsFLAGS_COPY_ALPHA else 0)) orelse return error.NativeImageFailed;
    var owned_transform = true;
    defer if (owned_transform) c.cmsDeleteTransform(transform);
    const output = c.vips_image_new() orelse return error.NativeImageFailed;
    errdefer t.unref(output);
    c.g_object_set_data_full(@ptrCast(output), "yekk-source", c.g_object_ref(source), releaseObject);
    c.g_object_set_data_full(@ptrCast(output), "yekk-transform", transform, destroyTransform);
    owned_transform = false;
    c.g_object_set_data_full(@ptrCast(output), "yekk-input-profile", input, destroyProfile);
    owned_profile = false;
    try check(c.vips_image_pipelinev(output, c.VIPS_DEMAND_STYLE_SMALLTILE, source, @as(?*anyopaque, null)));
    output.*.Bands = if (opaque_source) 3 else 4;
    output.*.BandFmt = c.VIPS_FORMAT_FLOAT;
    output.*.Type = c.VIPS_INTERPRETATION_scRGB;
    output.*.Coding = c.VIPS_CODING_NONE;
    try check(c.vips_image_generate(output, c.vips_start_one, generate, c.vips_stop_one, source, transform));
    return output;
}
// Only minimum storage admission is checked; no application RAM quota.
var reserved: std.atomic.Value(u64) = .init(0);
fn availableMemory() u64 {
    var available: u64 = std.math.maxInt(u64);
    const file = c.fopen("/proc/meminfo", "re");
    if (file != null) {
        defer _ = c.fclose(file);
        var line: [256]u8 = undefined;
        while (c.fgets(&line, line.len, file) != null) {
            const value = std.mem.span(@as([*:0]u8, @ptrCast(&line)));
            if (std.mem.startsWith(u8, value, "MemAvailable:")) {
                var words = std.mem.tokenizeAny(u8, value[13..], " \t");
                available = (std.fmt.parseInt(u64, words.next() orelse break, 10) catch break) *| 1024;
                break;
            }
        }
    }
    const groups = c.fopen("/proc/self/cgroup", "re");
    if (groups == null) return available;
    defer _ = c.fclose(groups);
    var line: [4096]u8 = undefined;
    while (c.fgets(&line, line.len, groups) != null) {
        const value = std.mem.trimEnd(u8, t.text(@ptrCast(&line)), "\r\n");
        if (!std.mem.startsWith(u8, value, "0::/")) continue;
        var path: [4096]u8 = undefined;
        var name = std.fmt.bufPrint(&path, "/sys/fs/cgroup{s}", .{value[3..]}) catch break;
        while (true) {
            const limit = readCounter(name, "memory.max");
            const used = readCounter(name, "memory.current");
            if (limit != null and used != null) available = @min(available, limit.? -| used.?);
            if (name.len <= "/sys/fs/cgroup".len) break;
            name = name[0 .. std.mem.lastIndexOfScalar(u8, name, '/') orelse break];
        }
        break;
    }
    return available;
}
fn readCounter(directory: []const u8, filename: []const u8) ?u64 {
    var path: [4160]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&path, "{s}/{s}", .{ directory, filename }, 0) catch return null;
    const file = c.fopen(name.ptr, "re");
    if (file == null) return null;
    defer _ = c.fclose(file);
    var line: [80]u8 = undefined;
    if (c.fgets(&line, line.len, file) == null) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, t.text(@ptrCast(&line)), " \r\n"), 10) catch null;
}
const Owner = struct {
    allocator: std.mem.Allocator,
    slab: []align(64) u8,
    fn destroy(opaque_owner: ?*anyopaque) callconv(.c) void {
        const owner: *Owner = @ptrCast(@alignCast(opaque_owner.?));
        const allocator = owner.allocator;
        const slab = owner.slab;
        if (build_options.debug_allocator) allocator.free(slab) else allocator.rawFree(slab, .fromByteUnits(64), @returnAddress());
    }
};
pub const Loaded = struct { prefix: *align(64) anyopaque, pixels: Image };

/// The caller's record and decoder pixels share one owned allocation. The
/// native source owns it until its final reference, including lazy graphs.
pub const LoadOptions = struct { speculative: bool = false, cancel: ?*const std.atomic.Value(bool) = null };
fn acquireWorkers(wanted: usize, options: LoadOptions) !usize {
    const desired = @min(wanted, if (options.speculative) @max(1, decode_workers / 2) else decode_workers);
    while (true) {
        if (options.cancel) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
        var used = busy_workers.load(.acquire);
        while (used < decode_workers) {
            const count = @min(desired, decode_workers - used);
            if (busy_workers.cmpxchgWeak(used, used + count, .acq_rel, .acquire)) |observed| used = observed else return count;
        }
        _ = c.poll(null, 0, 1);
    }
}
pub fn reserveTemporary(bytes: u64) Error!void {
    const available = availableMemory();
    var held = reserved.load(.acquire);
    while (true) {
        if (bytes > available or held > available - bytes) return error.OutOfMemory;
        held = reserved.cmpxchgWeak(held, held + bytes, .acq_rel, .acquire) orelse return;
    }
}
pub fn releaseTemporary(bytes: u64) void {
    _ = reserved.fetchSub(bytes, .release);
}
pub fn loadWithPrefix(prefix_bytes: usize, allocator: std.mem.Allocator, path: [*:0]const u8, load_options: LoadOptions) !Loaded {
    const file = try source_file.open(std.mem.span(path), false);
    defer file.close();
    return loadOpened(prefix_bytes, allocator, path, file, load_options);
}
/// The caller keeps this validated regular-file handle alive until return.
pub fn loadOpened(prefix_bytes: usize, allocator: std.mem.Allocator, path: [*:0]const u8, file: source_file.Open, load_options: LoadOptions) !Loaded {
    const owner_offset = std.mem.alignForward(usize, prefix_bytes, 64);
    const kind = std.meta.activeTag(file.format);
    if (kind == .jxl) {
        const workers = try acquireWorkers(decode_workers, load_options);
        defer _ = busy_workers.fetchSub(workers, .release);
        const result = try jxl.load(file, allocator, .{ .prefix_bytes = owner_offset + @sizeOf(Owner), .workers = workers, .cancel = load_options.cancel, .raw_retirement = !build_options.debug_allocator }, reserveTemporary, releaseTemporary);
        return wrapJxl(result, allocator, owner_offset);
    }
    if (kind == .tiff) if (try tiff.Plan.open(std.mem.span(path))) |opened| {
        var plan = opened;
        defer plan.deinit();
        if (!std.meta.eql(file.stamp, plan.stamp)) return error.SourceChanged;
        var supported = true;
        if (plan.profile.len > 0) {
            const profile = c.cmsOpenProfileFromMem(plan.profile.ptr, @intCast(plan.profile.len));
            if (profile) |value| {
                supported = c.cmsGetColorSpace(value) == c.cmsSigRgbData;
                _ = c.cmsCloseProfile(value);
            } else supported = false;
        }
        if (supported) {
            if (plan.header.width > std.math.maxInt(c_int) or plan.header.height > std.math.maxInt(c_int)) return error.InvalidDimensions;
            const workers = try acquireWorkers(plan.workerCount(decode_workers, false), load_options);
            defer _ = busy_workers.fetchSub(workers, .release);
            const width: usize = if (plan.header.orientation >= 5) plan.header.height else plan.header.width;
            const height: usize = if (plan.header.orientation >= 5) plan.header.width else plan.header.height;
            const layout = try tiff.storageLayout(width, height, plan.header.scratch_bytes, workers, owner_offset + @sizeOf(Owner), 1, plan.profile.len);
            try reserveTemporary(layout.total);
            defer releaseTemporary(layout.total);
            const decoded = try plan.decode(false, allocator, .{ .workers = workers, .simd_predictor = true, .raw_retirement = !build_options.debug_allocator, .prefix_bytes = owner_offset + @sizeOf(Owner), .row_alignment = 1, .cancel = load_options.cancel }, null);
            return wrapDecoded(decoded, allocator, owner_offset);
        }
    };
    if (kind == .pnm) if (try @import("pnm").Plan.open(std.mem.span(path), load_options.cancel)) |plan| {
        defer plan.deinit();
        if (!std.meta.eql(file.stamp, plan.file.stamp)) return error.SourceChanged;
        if (plan.extent.width > std.math.maxInt(c_int) or plan.extent.height > std.math.maxInt(c_int)) return error.InvalidDimensions;
        const workers = try acquireWorkers(plan.workerCount(decode_workers), load_options);
        defer _ = busy_workers.fetchSub(workers, .release);
        const options: @import("pnm").Options = .{ .prefix_bytes = owner_offset + @sizeOf(Owner), .row_alignment = .contiguous, .raw_retirement = !build_options.debug_allocator, .cancel = load_options.cancel, .workers = workers };
        const bytes = try plan.storageBytes(options);
        try reserveTemporary(bytes);
        defer releaseTemporary(bytes);
        return wrapDecoded(try plan.decode(allocator, options), allocator, owner_offset);
    };
    var pixels: Image = .{};
    try decodeImage(file, &pixels);
    errdefer free(&pixels);
    const slab = try allocator.alignedAlloc(u8, .fromByteUnits(64), owner_offset + @sizeOf(Owner));
    const owner: *Owner = @ptrCast(@alignCast(slab[owner_offset..].ptr));
    owner.* = .{ .allocator = allocator, .slab = slab };
    c.g_object_set_data_full(@ptrCast(pixels.image), "yekk-owner", owner, Owner.destroy);
    return .{ .prefix = @ptrCast(slab.ptr), .pixels = pixels };
}
fn wrapJxl(result: jxl.Result, allocator: std.mem.Allocator, owner_offset: usize) !Loaded {
    var owned = true;
    errdefer if (owned) result.decoded.deinit();
    const data = result.decoded.profile;
    const profile = c.cmsOpenProfileFromMem(data.ptr, @intCast(data.len)) orelse return error.NativeImageFailed;
    defer _ = c.cmsCloseProfile(profile);
    const colour = c.cmsGetColorSpace(profile);
    const gray = colour == c.cmsSigGrayData;
    if (colour != c.cmsSigRgbData and !(result.gray_source and gray)) return error.NativeImageFailed;
    owned = false;
    return wrapDecodedWithAttributes(result.decoded, allocator, owner_offset, result.opaque_source, gray);
}
fn wrapDecoded(decoded: tiff.Decoded, allocator: std.mem.Allocator, owner_offset: usize) !Loaded {
    return wrapDecodedWithAttributes(decoded, allocator, owner_offset, true, false);
}
fn wrapDecodedWithAttributes(decoded: tiff.Decoded, allocator: std.mem.Allocator, owner_offset: usize, opaque_source: bool, gray_profile: bool) !Loaded {
    var owned = true;
    errdefer if (owned) decoded.deinit();
    const resident = c.vips_image_new_from_memory(decoded.pixels.ptr, decoded.pixels.len, @intCast(decoded.width), @intCast(decoded.height), 4, if (decoded.bits_per_component == 16) c.VIPS_FORMAT_USHORT else c.VIPS_FORMAT_UCHAR) orelse return error.OutOfMemory;
    errdefer t.unref(resident);
    const owner: *Owner = @ptrCast(@alignCast(decoded.slab[owner_offset..].ptr));
    owner.* = .{ .allocator = allocator, .slab = decoded.slab };
    c.g_object_set_data_full(@ptrCast(resident), "yekk-owner", owner, Owner.destroy);
    owned = false;
    resident.*.Type = if (decoded.bits_per_component == 16) c.VIPS_INTERPRETATION_RGB16 else c.VIPS_INTERPRETATION_sRGB;
    if (decoded.profile.len > 0) {
        c.vips_image_set_blob_copy(resident, c.VIPS_META_ICC_NAME, decoded.profile.ptr, decoded.profile.len);
        c.vips_image_set_int(resident, "yekk-native-profile", 1);
        c.vips_image_set_int(resident, "yekk-gray-profile", @intFromBool(gray_profile));
    }
    _ = decoded.reclaimScratch();
    return .{ .prefix = @ptrCast(decoded.slab.ptr), .pixels = .{ .image = resident, .width = decoded.width, .height = decoded.height, .bits = decoded.bits_per_component, .bytes = decoded.pixels.len, .opaque_source = opaque_source } };
}
pub fn decode(path: [*:0]const u8, result: *Image) c_int {
    result.* = .{};
    const loaded = loadWithPrefix(0, std.heap.c_allocator, path, .{}) catch |err| return if (err == error.OutOfMemory) -2 else -1;
    result.* = loaded.pixels;
    return 0;
}
/// File names are literal paths, never libvips option strings. Pin the regular
/// file before handing it to a native loader; do not reopen a raced path.
fn openImage(opened: source_file.Open, memory: bool) Error!*c.VipsImage {
    if (opened.bmp()) |header| {
        const bytes = std.math.add(usize, header.extent.bytes(4, 2) catch return error.NativeImageFailed, if (header.profile) |profile| profile.length else 0) catch return error.NativeImageFailed;
        if (memory) try reserveTemporary(bytes);
        defer if (memory) releaseTemporary(bytes);
        return @import("linux_bmp.zig").load(opened, memory);
    }
    // The pinned libvips duplicates this descriptor; we retain the original.
    const source = c.vips_source_new_from_descriptor(opened.fd) orelse return error.NativeImageFailed;
    defer t.unref(source);
    return c.vips_image_new_from_source(source, "", "access", @as(c_int, c.VIPS_ACCESS_RANDOM), "memory", @as(c_int, @intFromBool(memory)), "fail_on", @as(c_int, c.VIPS_FAIL_ON_WARNING), @as(?*anyopaque, null)) orelse error.NativeImageFailed;
}
fn decodeImage(file: source_file.Open, result: *Image) Error!void {
    c.vips_error_clear();
    const input = try openImage(file, true);
    defer t.unref(input);
    // Explicitly reject floating/HDR source formats, including TIFF variants.
    if (input.*.Bands <= 0 or (input.*.BandFmt != c.VIPS_FORMAT_UCHAR and input.*.BandFmt != c.VIPS_FORMAT_USHORT) or input.*.Coding != c.VIPS_CODING_NONE) return error.UnsupportedSampleFormat;
    const extent = Extent.init(input.*.Xsize, input.*.Ysize) catch return error.NativeImageFailed;
    const sample: usize = if (input.*.BandFmt == c.VIPS_FORMAT_USHORT) 2 else 1;
    const minimum = @max(extent.bytes(4, sample) catch return error.OutOfMemory, extent.bytes(@intCast(input.*.Bands), sample) catch return error.OutOfMemory);
    try reserveTemporary(minimum);
    defer releaseTemporary(minimum);
    var oriented: ?*c.VipsImage = null;
    try check(c.vips_autorot(input, &oriented, @as(?*anyopaque, null)));
    defer t.unref(oriented);
    var colour: ?*c.VipsImage = null;
    defer t.unref(colour);
    var native_profile = false;
    var gray_profile = false;
    if (c.vips_image_get_typeof(oriented, c.VIPS_META_ICC_NAME) != 0) {
        var data: ?*const anyopaque = null;
        var size: usize = 0;
        try check(c.vips_image_get_blob(oriented, c.VIPS_META_ICC_NAME, &data, &size));
        if (size > std.math.maxInt(u32)) return error.NativeImageFailed;
        const profile = c.cmsOpenProfileFromMem(data, @intCast(size)) orelse return error.NativeImageFailed;
        const space = c.cmsGetColorSpace(profile);
        _ = c.cmsCloseProfile(profile);
        const bands = oriented.?.Bands;
        native_profile = space == c.cmsSigRgbData and (bands == 3 or bands == 4);
        gray_profile = space == c.cmsSigGrayData and (bands == 1 or bands == 2);
        if (native_profile) try check(c.vips_copy(oriented, &colour, @as(?*anyopaque, null))) else if (gray_profile) {
            try check(c.vips_colourspace(oriented, &colour, if (sample == 2) @as(c_int, c.VIPS_INTERPRETATION_RGB16) else @as(c_int, c.VIPS_INTERPRETATION_sRGB), @as(?*anyopaque, null)));
            native_profile = true;
        } else colour = try iccLinear(oriented.?, false);
    } else try check(c.vips_colourspace(oriented, &colour, if (sample == 2) @as(c_int, c.VIPS_INTERPRETATION_RGB16) else @as(c_int, c.VIPS_INTERPRETATION_sRGB), @as(?*anyopaque, null)));
    // Non-RGB ICC input is normalized to an SDR RGB16 source. Only the lazy
    // display working graph uses floats; no floating source or TIFF offer.
    if (colour.?.BandFmt == c.VIPS_FORMAT_FLOAT) {
        var converted: ?*c.VipsImage = null;
        try check(c.vips_colourspace(colour, &converted, c.VIPS_INTERPRETATION_RGB16, @as(?*anyopaque, null)));
        t.unref(colour);
        colour = converted;
        const profile = c.cmsCreate_sRGBProfile() orelse return error.NativeImageFailed;
        defer _ = c.cmsCloseProfile(profile);
        try attachProfile(colour.?, profile);
        native_profile = true;
    }
    if (native_profile) {
        c.vips_image_set_int(colour, "yekk-native-profile", 1);
        c.vips_image_set_int(colour, "yekk-gray-profile", @intFromBool(gray_profile));
    }
    var alpha: ?*c.VipsImage = null;
    if (c.vips_image_hasalpha(colour) != 0) alpha = @ptrCast(@alignCast(c.g_object_ref(colour))) else try check(c.vips_addalpha(colour, &alpha, @as(?*anyopaque, null)));
    defer t.unref(alpha);
    if (alpha.?.Bands != 4 or (alpha.?.BandFmt != c.VIPS_FORMAT_UCHAR and alpha.?.BandFmt != c.VIPS_FORMAT_USHORT)) return error.UnsupportedSampleFormat;
    const output_extent = Extent.init(alpha.?.Xsize, alpha.?.Ysize) catch return error.NativeImageFailed;
    const bytes = output_extent.bytes(4, if (alpha.?.BandFmt == c.VIPS_FORMAT_USHORT) 2 else 1) catch return error.OutOfMemory;
    const extra = bytes -| minimum;
    if (extra > 0) try reserveTemporary(extra);
    defer if (extra > 0) releaseTemporary(extra);
    const resident = c.vips_image_copy_memory(alpha) orelse return error.NativeImageFailed;
    result.* = .{ .image = resident, .width = output_extent.width, .height = output_extent.height, .bits = if (resident.*.BandFmt == c.VIPS_FORMAT_USHORT) 16 else 8, .bytes = bytes, .opaque_source = c.vips_image_hasalpha(colour) == 0 };
}
/// Called only by the render worker; source pixels and UI-held frames remain valid.
pub fn dropDerived(image: *Image) void {
    if (image.preview) |preview| t.unref(preview.surface);
    image.preview = null;
    t.clear(&image.overview);
    for (&image.levels) |*level| t.clear(level);
    t.clear(&image.working);
}
pub fn free(image: *Image) void {
    const old = image.*;
    image.* = .{};
    if (old.preview) |preview| t.unref(preview.surface);
    t.unref(old.overview);
    for (old.levels) |level| t.unref(level);
    t.unref(old.working);
    // The last native source reference can release the caller's whole record.
    t.unref(old.image);
}
pub fn pixel(image: *Image, x: c_int, y: c_int, rgba: *[4]u16) c_int {
    if (x < 0 or y < 0 or x >= image.width or y >= image.height) return -1;
    const base = c.vips_image_get_data(image.image) orelse return -1;
    const offset = (@as(usize, @intCast(y)) * image.width + @as(usize, @intCast(x))) * 4;
    if (image.bits == 16) @memcpy(rgba, @as([*]const u16, @ptrCast(@alignCast(base)))[offset..][0..4]) else {
        const values: [*]const u8 = @ptrCast(base);
        for (rgba, 0..) |*value, i| value.* = @as(u16, values[offset + i]) * 257;
    }
    return 0;
}
fn rawLinear(comptime Sample: type, comptime opaque_source: bool, out_arg: [*c]c.VipsRegion, sequence: ?*anyopaque) c_int {
    const output = &out_arg[0];
    const input: *c.VipsRegion = @ptrCast(@alignCast(sequence.?));
    const rectangle = &output.valid;
    if (c.vips_region_prepare(input, rectangle) != 0) return -1;
    const channels = if (opaque_source) 3 else 4;
    var y = rectangle.top;
    while (y < rectangle.top + rectangle.height) : (y += 1) {
        const input_offset = @as(usize, @intCast(y - input.valid.top)) * @as(usize, @intCast(input.bpl)) + @as(usize, @intCast(rectangle.left - input.valid.left)) * 4 * @sizeOf(Sample);
        const output_offset = @as(usize, @intCast(y - output.valid.top)) * @as(usize, @intCast(output.bpl)) + @as(usize, @intCast(rectangle.left - output.valid.left)) * channels * @sizeOf(f32);
        const src: [*]const Sample = @ptrCast(@alignCast(input.data + input_offset));
        const dst: [*]f32 = @ptrCast(@alignCast(output.data + output_offset));
        const table = if (Sample == u16) &srgb16 else &srgb8;
        for (0..@intCast(rectangle.width)) |x| {
            const alpha: f32 = if (opaque_source) 1 else @floatCast(@as(f64, @floatFromInt(src[x * 4 + 3])) * (1.0 / @as(f64, std.math.maxInt(Sample))));
            inline for (0..3) |ch| dst[x * channels + ch] = table[src[x * 4 + ch]] * alpha;
            if (!opaque_source) dst[x * channels + 3] = alpha;
        }
    }
    return 0;
}
fn rawGenerator(comptime Sample: type, comptime opaque_source: bool) c.VipsGenerateFn {
    return struct {
        fn generate(out: [*c]c.VipsRegion, sequence: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: [*c]c.gboolean) callconv(.c) c_int {
            return rawLinear(Sample, opaque_source, out, sequence);
        }
    }.generate;
}
fn defaultLinear(image: *Image) Error!*c.VipsImage {
    const source = image.image.?;
    const output = c.vips_image_new() orelse return error.OutOfMemory;
    errdefer t.unref(output);
    c.g_object_set_data_full(@ptrCast(output), "yekk-source", c.g_object_ref(source), releaseObject);
    try check(c.vips_image_pipelinev(output, c.VIPS_DEMAND_STYLE_SMALLTILE, source, @as(?*anyopaque, null)));
    output.*.Bands = if (image.opaque_source) 3 else 4;
    output.*.BandFmt = c.VIPS_FORMAT_FLOAT;
    output.*.Type = c.VIPS_INTERPRETATION_scRGB;
    output.*.Coding = c.VIPS_CODING_NONE;
    const generator = if (image.bits == 16) (if (image.opaque_source) rawGenerator(u16, true) else rawGenerator(u16, false)) else (if (image.opaque_source) rawGenerator(u8, true) else rawGenerator(u8, false));
    try check(c.vips_image_generate(output, c.vips_start_one, generator, c.vips_stop_one, source, null));
    return output;
}
/// Opaque sources produce RGB; alpha-bearing sources produce premultiplied RGBA.
pub fn linearSource(image: *Image) Error!*c.VipsImage {
    var rgb: ?*c.VipsImage = null;
    defer t.unref(rgb);
    var alpha: ?*c.VipsImage = null;
    defer t.unref(alpha);
    var joined: ?*c.VipsImage = null;
    defer t.unref(joined);
    var linear: ?*c.VipsImage = null;
    defer t.unref(linear);
    var native: c_int = 0;
    var gray: c_int = 0;
    if (c.vips_image_get_typeof(image.image, "yekk-native-profile") != 0) _ = c.vips_image_get_int(image.image, "yekk-native-profile", &native);
    if (c.vips_image_get_typeof(image.image, "yekk-gray-profile") != 0) _ = c.vips_image_get_int(image.image, "yekk-gray-profile", &gray);
    var output: ?*c.VipsImage = null;
    if (native != 0) {
        var input = image.image;
        if (gray != 0) {
            try check(c.vips_extract_band(input, &rgb, 0, @as(?*anyopaque, null)));
            try check(c.vips_extract_band(input, &alpha, 3, @as(?*anyopaque, null)));
            try check(c.vips_bandjoin2(rgb, alpha, &joined, @as(?*anyopaque, null)));
            input = joined;
        }
        linear = try iccLinear(input.?, image.opaque_source);
        if (image.opaque_source) {
            const result = linear.?;
            linear = null;
            return result;
        }
        try check(c.vips_premultiply(linear, &output, "max_alpha", @as(f64, 1), @as(?*anyopaque, null)));
    } else return defaultLinear(image);
    return output orelse error.NativeImageFailed;
}

fn freeBlob(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    c.g_free(data);
    return 0;
}
fn attachProfile(image: *c.VipsImage, profile: c.cmsHPROFILE) Error!void {
    var size: u32 = 0;
    if (c.cmsSaveProfileToMem(profile, null, &size) == 0) return error.NativeImageFailed;
    const data = c.g_try_malloc(size) orelse return error.OutOfMemory;
    if (c.cmsSaveProfileToMem(profile, data, &size) == 0) {
        c.g_free(data);
        return error.NativeImageFailed;
    }
    c.vips_image_set_blob(image, c.VIPS_META_ICC_NAME, freeBlob, data, size);
}
pub fn testProfilePng(input_path: [*:0]const u8, output_path: [*:0]const u8, gray: c_int) c_int {
    testProfile(input_path, output_path, gray != 0) catch return -1;
    return 0;
}
fn testProfile(input_path: [*:0]const u8, output_path: [*:0]const u8, gray: bool) Error!void {
    const input = c.vips_image_new_from_file(input_path, @as(?*anyopaque, null)) orelse return error.NativeImageFailed;
    defer t.unref(input);
    var output: ?*c.VipsImage = null;
    defer t.unref(output);
    if (gray) {
        try check(c.vips_extract_band(input, &output, 0, @as(?*anyopaque, null)));
        output.?.Type = if (input.*.BandFmt == c.VIPS_FORMAT_USHORT) c.VIPS_INTERPRETATION_GREY16 else c.VIPS_INTERPRETATION_B_W;
        const curve = c.cmsBuildGamma(null, 1) orelse return error.NativeImageFailed;
        defer c.cmsFreeToneCurve(curve);
        const profile = c.cmsCreateGrayProfile(c.cmsD50_xyY(), curve) orelse return error.NativeImageFailed;
        defer _ = c.cmsCloseProfile(profile);
        try attachProfile(output.?, profile);
    } else {
        try check(c.vips_copy(input, &output, @as(?*anyopaque, null)));
        var profile: ?*c.VipsBlob = null;
        try check(c.vips_profile_load("p3", &profile, @as(?*anyopaque, null)));
        defer c.vips_area_unref(@ptrCast(profile));
        var size: usize = 0;
        const data = c.vips_blob_get(profile, &size);
        c.vips_image_set_blob_copy(output, c.VIPS_META_ICC_NAME, data, size);
    }
    try check(c.vips_pngsave(output, output_path, @as(?*anyopaque, null)));
}
