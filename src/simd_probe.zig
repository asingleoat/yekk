//! Research-only CPU SIMD comparison against the existing Accelerate path.
const std = @import("std");
const n = @import("platform/native.zig");
const Buffer = extern struct { data: ?*anyopaque, height: usize, width: usize, row_bytes: usize };
extern "c" fn vImageConvert_RGB16UtoRGBA16U(*const Buffer, ?*const Buffer, u16, *const Buffer, bool, u32) isize;
const V = @Vector(8, u16);
fn vectorConvert(source: []const u16, output: []u16, width: usize, rows: usize, stride: usize) void {
    const alpha: V = @splat(65535);
    for (0..rows) |row| {
        var x: usize = 0;
        while (x + 4 <= width) : (x += 4) {
            const offset = (row * width + x) * 3;
            const left = @as(*align(2) const V, @ptrCast(source.ptr + offset)).*;
            const right = @as(*align(2) const V, @ptrCast(source.ptr + offset + 4)).*;
            const a = @shuffle(u16, left, alpha, @as(@Vector(8, i32), .{ 0, 1, 2, -1, 3, 4, 5, -1 }));
            const b = @shuffle(u16, right, alpha, @as(@Vector(8, i32), .{ 2, 3, 4, -1, 5, 6, 7, -1 }));
            @as(*align(2) V, @ptrCast(output.ptr + row * stride + x * 4)).* = a;
            @as(*align(2) V, @ptrCast(output.ptr + row * stride + x * 4 + 8)).* = b;
        }
        while (x < width) : (x += 1) {
            const src = (row * width + x) * 3;
            const dst = row * stride + x * 4;
            output[dst] = source[src];
            output[dst + 1] = source[src + 1];
            output[dst + 2] = source[src + 2];
            output[dst + 3] = 65535;
        }
    }
}
pub export fn main(_: c_int, _: [*][*:0]const u8) c_int {
    const width = 17151;
    const rows = 40;
    const stride = std.mem.alignForward(usize, width * 8, 64) / 2;
    const source_size = std.mem.alignForward(usize, width * rows * 3, 32);
    const dest_size = stride * rows;
    const slab = std.heap.c_allocator.alignedAlloc(u16, .fromByteUnits(64), source_size + dest_size * 2) catch return 1;
    defer std.heap.c_allocator.free(slab);
    const source = slab[0..source_size];
    const native = slab[source_size..][0..dest_size];
    const candidate = slab[source_size + dest_size ..][0..dest_size];
    for (source, 0..) |*value, i| value.* = @truncate(i *% 1777);
    @memset(native, 0);
    @memset(candidate, 0);
    const src: Buffer = .{ .data = source.ptr, .height = rows, .width = width, .row_bytes = width * 6 };
    const dst: Buffer = .{ .data = native.ptr, .height = rows, .width = width, .row_bytes = stride * 2 };
    var a: [31]f64 = undefined;
    var b: [31]f64 = undefined;
    for (0..32) |round| for (0..2) |step| {
        const which = (round + step) % 2;
        const started = n.now();
        if (which == 0) {
            if (vImageConvert_RGB16UtoRGBA16U(&src, null, 65535, &dst, false, 16) != 0) return 1;
        } else vectorConvert(source, candidate, width, rows, stride);
        const elapsed = (n.now() - started) * 1000;
        if (round > 0) {
            if (which == 0) a[round - 1] = elapsed else b[round - 1] = elapsed;
        }
    };
    if (!std.mem.eql(u16, native, candidate)) return 2;
    std.mem.sort(f64, &a, {}, std.sort.asc(f64));
    std.mem.sort(f64, &b, {}, std.sort.asc(f64));
    var text: [512]u8 = undefined;
    n.output(1, std.fmt.bufPrint(&text, "{{\"width\":{d},\"rows\":{d},\"samples\":31,\"equal\":true,\"vimage_median_ms\":{d:.6},\"zig_simd_median_ms\":{d:.6}}}\n", .{ width, rows, a[15], b[15] }) catch return 1);
    return 0;
}
