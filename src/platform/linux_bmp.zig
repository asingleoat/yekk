//! SDL decodes BMP pixels from a pinned file; libvips owns the resulting surface.
const t = @import("linux_types.zig");
const c = t.c;
const File = @import("source").Open;
const Error = error{ NativeImageFailed, OutOfMemory };
const Stream = struct {
    file: *c.FILE,
    bytes: i64,
    fn size(data: ?*anyopaque) callconv(.c) i64 {
        const self: *Stream = @ptrCast(@alignCast(data.?));
        return self.bytes;
    }
    fn seek(data: ?*anyopaque, offset: i64, whence: c.SDL_IOWhence) callconv(.c) i64 {
        const self: *Stream = @ptrCast(@alignCast(data.?));
        if (c.fseeko(self.file, offset, @intCast(whence)) != 0) return -1;
        return c.ftello(self.file);
    }
    fn read(data: ?*anyopaque, output: ?*anyopaque, length: usize, status: [*c]c.SDL_IOStatus) callconv(.c) usize {
        const self: *Stream = @ptrCast(@alignCast(data.?));
        const count = c.fread(output, 1, length, self.file);
        if (count < length) status.* = if (c.ferror(self.file) != 0) c.SDL_IO_STATUS_ERROR else c.SDL_IO_STATUS_EOF;
        return count;
    }
};
fn destroySurface(data: ?*anyopaque) callconv(.c) void {
    c.SDL_DestroySurface(@ptrCast(@alignCast(data)));
}
fn freeProfile(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    c.g_free(data);
    return 0;
}
pub fn load(file: File, pixels: bool) Error!*c.VipsImage {
    const header = file.bmp() orelse return error.NativeImageFailed;
    const extent = header.extent;
    if (!pixels) {
        const image = c.vips_image_new() orelse return error.OutOfMemory;
        c.vips_image_init_fields(image, @intCast(extent.width), @intCast(extent.height), 4, c.VIPS_FORMAT_UCHAR, c.VIPS_CODING_NONE, c.VIPS_INTERPRETATION_sRGB, 1, 1);
        c.vips_image_set_string(image, "vips-loader", "bmpload");
        return image;
    }
    const descriptor = c.dup(file.fd);
    if (descriptor < 0) return error.NativeImageFailed;
    const input = c.fdopen(descriptor, "rb") orelse {
        _ = c.close(descriptor);
        return error.NativeImageFailed;
    };
    defer _ = c.fclose(input);
    var stream: Stream = .{ .file = input, .bytes = file.stamp.bytes };
    const callbacks: c.SDL_IOStreamInterface = .{ .version = @sizeOf(c.SDL_IOStreamInterface), .size = Stream.size, .seek = Stream.seek, .read = Stream.read, .write = null, .flush = null, .close = null };
    const io = c.SDL_OpenIO(&callbacks, &stream) orelse return error.OutOfMemory;
    var rgba = c.SDL_LoadBMP_IO(io, true) orelse return error.NativeImageFailed;
    var owned = true;
    defer if (owned) c.SDL_DestroySurface(rgba);
    if (rgba.*.w != extent.width or rgba.*.h != extent.height) return error.NativeImageFailed;
    if (rgba.*.format != c.SDL_PIXELFORMAT_RGBA32) {
        const converted = c.SDL_ConvertSurface(rgba, c.SDL_PIXELFORMAT_RGBA32) orelse return error.OutOfMemory;
        c.SDL_DestroySurface(rgba);
        rgba = converted;
    }
    const bytes = extent.bytes(4, 1) catch return error.NativeImageFailed;
    if (rgba.*.pitch < 0 or @as(usize, @intCast(rgba.*.pitch)) != @as(usize, extent.width) * 4) return error.NativeImageFailed;
    const image = c.vips_image_new_from_memory(rgba.*.pixels, bytes, @intCast(extent.width), @intCast(extent.height), 4, c.VIPS_FORMAT_UCHAR) orelse return error.OutOfMemory;
    errdefer t.unref(image);
    c.g_object_set_data_full(@ptrCast(image), "yekk-bmp-surface", rgba, destroySurface);
    owned = false;
    image.*.Type = c.VIPS_INTERPRETATION_sRGB;
    c.vips_image_set_string(image, "vips-loader", "bmpload");
    if (header.profile) |profile| {
        const data = c.g_try_malloc(profile.length) orelse return error.OutOfMemory;
        var offset: usize = 0;
        while (offset < profile.length) {
            const count = c.pread(file.fd, @as([*]u8, @ptrCast(data)) + offset, profile.length - offset, @intCast(profile.offset + offset));
            if (count <= 0) {
                c.g_free(data);
                return error.NativeImageFailed;
            }
            offset += @intCast(count);
        }
        c.vips_image_set_blob(image, c.VIPS_META_ICC_NAME, freeProfile, data, profile.length);
    }
    return image;
}
