//! All functions in this module run off the UI thread.
//! Backend contract: return orientation-correct, color-tagged, eagerly decoded
//! pixels; retain native precision; one Yekk allocation per representation.
const std = @import("std");
const n = @import("platform/native.zig");

// Image metadata uses u32 dimensions; this is a representation constraint.
pub const max_source_dimension = std.math.maxInt(u32);
pub const Backend = @import("image.zig").Backend;
pub const Failure = @import("image.zig").Failure;
pub const Limits = @import("image.zig").Limits;
pub const Image = @import("image.zig").Image;

fn number(dictionary: n.Ref, key: n.Ref) Failure!?i64 {
    const value = n.CFDictionaryGetValue(dictionary, key) orelse return null;
    if (n.CFGetTypeID(value) != n.CFNumberGetTypeID()) return error.InvalidDimensions;
    var result: i64 = 0;
    if (n.CFNumberGetValue(value, 4, &result) == 0) return error.InvalidDimensions; // kCFNumberSInt64Type
    return result;
}

pub fn load(path: []const u8, max_pixel: u32) Failure!*Image {
    return loadWithAllocator(path, max_pixel, std.heap.c_allocator);
}

/// ImageIO tolerates truncated PNG/JPEG data even when both status APIs say
/// "complete". Validate container completeness before asking it for pixels.
/// This is container validation, not a second decoder. O_NONBLOCK prevents
/// a named pipe from tying up a worker indefinitely during open.
fn preflight(path: []const u8, completeness: bool) Failure!std.meta.Tag(@import("source").Format) {
    var buffer: [4096:0]u8 = undefined;
    if (path.len == 0 or path.len >= buffer.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.UnreadableImage;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const source = try @import("source").open(buffer[0..path.len :0], completeness);
    defer source.close();
    return std.meta.activeTag(source.format);
}

pub fn loadWithAllocator(path: []const u8, max_pixel: u32, allocator: std.mem.Allocator) Failure!*Image {
    return loadWithLimits(path, max_pixel, allocator, .{});
}
pub fn loadWithLimits(path: []const u8, max_pixel: u32, allocator: std.mem.Allocator, limits: Limits) Failure!*Image {
    const source_format = try preflight(path, true);
    if (source_format == .tiff and max_pixel == 0) if (try @import("tiff_decoder.zig").load(path, allocator, limits)) |decoded| return decoded;
    if (source_format == .pnm) {
        const plan = (try @import("pnm").Plan.open(path, null)) orelse return error.SourceChanged;
        defer plan.deinit();
        const space = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB) orelse return error.OutOfMemory;
        defer n.CFRelease(space);
        const decoded = try plan.decode(allocator, .{ .prefix_bytes = @sizeOf(Image), .raw_retirement = limits.raw_retirement, .workers = if (limits.tiff_workers == 0) n.performanceCores() else limits.tiff_workers });
        return @import("tiff_decoder.zig").fromDecoded(decoded, space, .pnm);
    }
    const url = n.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse return error.UnreadableImage;
    defer n.CFRelease(url);
    const source_keys = [_]n.Ref{n.kCGImageSourceShouldCache};
    const source_values = [_]n.Ref{n.kCFBooleanFalse};
    const source_options = n.CFDictionaryCreate(null, &source_keys, &source_values, 1, null, null) orelse return error.OutOfMemory;
    defer n.CFRelease(source_options);
    const source = n.CGImageSourceCreateWithURL(url, source_options) orelse return error.UnreadableImage;
    defer n.CFRelease(source);
    const props = n.CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return error.UnreadableImage;
    defer n.CFRelease(props);
    var width = (try number(props, n.kCGImagePropertyPixelWidth)) orelse return error.InvalidDimensions;
    var height = (try number(props, n.kCGImagePropertyPixelHeight)) orelse return error.InvalidDimensions;
    if (width <= 0 or height <= 0 or width > max_source_dimension or height > max_source_dimension) return error.InvalidDimensions;
    const orientation = (try number(props, n.kCGImagePropertyOrientation)) orelse 1;
    if (orientation < 1 or orientation > 8) return error.InvalidDimensions;
    if (orientation >= 5 and orientation <= 8) std.mem.swap(i64, &width, &height);
    const largest: u32 = @intCast(@max(width, height));
    const edge = if (max_pixel == 0) largest else @min(largest, max_pixel);
    // Validate address arithmetic, without imposing an application RAM budget.
    const ratio = @as(f64, @floatFromInt(edge)) / @as(f64, @floatFromInt(largest));
    const out_w: usize = @intFromFloat(@ceil(@as(f64, @floatFromInt(width)) * ratio));
    const out_h: usize = @intFromFloat(@ceil(@as(f64, @floatFromInt(height)) * ratio));
    _ = try (try @import("raster").Extent.init(@intCast(out_w), @intCast(out_h))).bytes(4, 2);
    var limit: i64 = edge;
    const limit_number = n.CFNumberCreate(null, 4, &limit) orelse return error.OutOfMemory;
    defer n.CFRelease(limit_number);
    const keys = [_]n.Ref{ n.kCGImageSourceCreateThumbnailFromImageAlways, n.kCGImageSourceCreateThumbnailWithTransform, n.kCGImageSourceThumbnailMaxPixelSize, n.kCGImageSourceShouldCacheImmediately };
    const values = [_]n.Ref{ n.kCFBooleanTrue, n.kCFBooleanTrue, limit_number, n.kCFBooleanTrue };
    const options = n.CFDictionaryCreate(null, &keys, &values, keys.len, null, null) orelse return error.OutOfMemory;
    defer n.CFRelease(options);
    var native = n.CGImageSourceCreateThumbnailAtIndex(source, 0, options) orelse return error.DecodeFailed;
    errdefer n.CFRelease(native);
    if (n.CGImageSourceGetStatus(source) != 0 or n.CGImageSourceGetStatusAtIndex(source, 0) != 0) return error.IncompleteImage;
    // Float components and HDR output are outside the still-image contract.
    if (n.CGImageGetBitmapInfo(native) & (1 << 8) != 0 or n.CGImageGetBitsPerComponent(native) > 16) return error.DecodeFailed;
    // Preserve tagged profiles. Only untagged RGB receives the sRGB fallback.
    if (n.CGImageGetColorSpace(native) == null) {
        const srgb = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB) orelse return error.OutOfMemory;
        defer n.CFRelease(srgb);
        if (n.CGImageCreateCopyWithColorSpace(native, srgb)) |tagged| {
            n.CFRelease(native);
            native = tagged;
        } else return error.DecodeFailed;
    }
    const decoded_width = n.CGImageGetWidth(native);
    const decoded_height = n.CGImageGetHeight(native);
    if (decoded_width == 0 or decoded_height == 0 or decoded_width > max_source_dimension or decoded_height > max_source_dimension) return error.InvalidDimensions;
    const pixel_bits = n.CGImageGetBitsPerPixel(native);
    if (pixel_bits == 0 or n.CGImageGetBitsPerComponent(native) == 0) return error.DecodeFailed;
    const row_bits = std.math.mul(usize, decoded_width, pixel_bits) catch return error.SizeOverflow;
    const minimum_row = (std.math.add(usize, row_bits, 7) catch return error.SizeOverflow) / 8;
    if (n.CGImageGetBytesPerRow(native) < minimum_row) return error.DecodeFailed;
    const decoded_bytes = std.math.mul(usize, n.CGImageGetBytesPerRow(native), decoded_height) catch return error.SizeOverflow;
    if (decoded_bytes > std.math.maxInt(isize)) return error.SizeOverflow;
    const image = allocator.create(Image) catch return error.OutOfMemory;
    image.* = .{
        .allocator = allocator,
        .native = native,
        .source_width = @intCast(width),
        .source_height = @intCast(height),
        .width = @intCast(decoded_width),
        .height = @intCast(decoded_height),
        .decoded_bytes = decoded_bytes,
        .bits_per_component = n.CGImageGetBitsPerComponent(native),
    };
    return image;
}

/// Header-only metadata. No pixel decode or Yekk allocation; worker/CLI use.
pub const Metadata = struct {
    width: u32,
    height: u32,
    format: [128]u8 = undefined,
    format_len: usize = 0,
};
pub fn metadata(path: []const u8) Failure!Metadata {
    const source_format = try preflight(path, false);
    if (source_format == .pnm) {
        const plan = (try @import("pnm").Plan.open(path, null)) orelse return error.SourceChanged;
        defer plan.deinit();
        var result: Metadata = .{ .width = plan.extent.width, .height = plan.extent.height };
        const format = plan.format();
        @memcpy(result.format[0..format.len], format);
        result.format_len = format.len;
        return result;
    }
    const url = n.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse return error.UnreadableImage;
    defer n.CFRelease(url);
    const source = n.CGImageSourceCreateWithURL(url, null) orelse return error.UnreadableImage;
    defer n.CFRelease(source);
    const props = n.CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return error.UnreadableImage;
    defer n.CFRelease(props);
    var width = (try number(props, n.kCGImagePropertyPixelWidth)) orelse return error.InvalidDimensions;
    var height = (try number(props, n.kCGImagePropertyPixelHeight)) orelse return error.InvalidDimensions;
    if (width <= 0 or height <= 0 or width > max_source_dimension or height > max_source_dimension) return error.InvalidDimensions;
    const orientation = (try number(props, n.kCGImagePropertyOrientation)) orelse 1;
    if (orientation < 1 or orientation > 8) return error.InvalidDimensions;
    if (orientation >= 5 and orientation <= 8) std.mem.swap(i64, &width, &height);
    var result: Metadata = .{ .width = @intCast(width), .height = @intCast(height) };
    const kind = n.CGImageSourceGetType(source) orelse return error.UnreadableImage;
    if (n.CFStringGetCString(kind, &result.format, result.format.len, 0x08000100) == 0) return error.UnreadableImage;
    result.format_len = std.mem.indexOfScalar(u8, &result.format, 0) orelse return error.UnreadableImage;
    const uti = result.format[0..result.format_len];
    const known = .{ .{ "public.png", "png" }, .{ "public.jpeg", "jpeg" }, .{ "public.tiff", "tiff" }, .{ "com.compuserve.gif", "gif" }, .{ "public.heic", "heic" }, .{ "org.webmproject.webp", "webp" } };
    inline for (known) |pair| if (std.mem.eql(u8, uti, pair[0])) {
        @memcpy(result.format[0..pair[1].len], pair[1]);
        result.format_len = pair[1].len;
        break;
    };
    return result;
}
