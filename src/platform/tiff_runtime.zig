//! Small native adapters for the shared TIFF pipeline.
const builtin = @import("builtin");
const c = @import("system");
const tiff = @import("tiff_bindings");
const Buffer = extern struct { data: ?*anyopaque, height: usize, width: usize, row_bytes: usize };
extern "c" fn vImageConvert_RGB16UtoRGBA16U(*const Buffer, ?*const Buffer, u16, *const Buffer, bool, u32) isize;

pub const run = @import("parallel").run;
pub fn noCache(handle: *tiff.TIFF) bool {
    if (builtin.os.tag == .macos) return c.fcntl(tiff.TIFFFileno(handle), c.F_NOCACHE, @as(c_int, 1)) == 0;
    return false;
}
pub fn insert(input: [*]const u8, output: [*]u16, width: usize, height: usize, source_stride: usize, destination_stride: usize) !void {
    if (builtin.os.tag == .macos) {
        const src: Buffer = .{ .data = @constCast(input), .height = height, .width = width, .row_bytes = source_stride };
        const dst: Buffer = .{ .data = output, .height = height, .width = width, .row_bytes = destination_stride };
        if (vImageConvert_RGB16UtoRGBA16U(&src, null, 65535, &dst, false, 16) != 0) return error.DecodeFailed;
    } else {
        const rgb: [*]const u16 = @ptrCast(@alignCast(input));
        for (0..height) |row| {
            const src = rgb + row * source_stride / 2;
            const dst = output + row * destination_stride / 2;
            var x: usize = 0;
            while (x + 8 <= width) : (x += 8) {
                const first = @as(*align(2) const @Vector(16, u16), @ptrCast(src + x * 3)).*;
                const last = @as(*align(2) const @Vector(16, u16), @ptrCast(src + x * 3 + 8)).*;
                const V = @Vector(8, u16);
                const alpha: V = @splat(65535);
                const red = @shuffle(u16, first, last, @as(@Vector(8, i32), .{ 0, 3, 6, 9, 12, 15, -11, -14 }));
                const green = @shuffle(u16, first, last, @as(@Vector(8, i32), .{ 1, 4, 7, 10, 13, -9, -12, -15 }));
                const blue = @shuffle(u16, first, last, @as(@Vector(8, i32), .{ 2, 5, 8, 11, 14, -10, -13, -16 }));
                const rg = @shuffle(u16, red, green, @as(@Vector(16, i32), .{ 0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8 }));
                const ba = @shuffle(u16, blue, alpha, @as(@Vector(16, i32), .{ 0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6, -7, 7, -8 }));
                @as(*align(2) @Vector(32, u16), @ptrCast(dst + x * 4)).* = @shuffle(u16, rg, ba, @as(@Vector(32, i32), .{ 0, 1, -1, -2, 2, 3, -3, -4, 4, 5, -5, -6, 6, 7, -7, -8, 8, 9, -9, -10, 10, 11, -11, -12, 12, 13, -13, -14, 14, 15, -15, -16 }));
            }
            while (x < width) : (x += 1) {
                @memcpy(dst[x * 4 ..][0..3], src[x * 3 ..][0..3]);
                dst[x * 4 + 3] = 65535;
            }
        }
    }
}
