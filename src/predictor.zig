//! TIFF Predictor 2 for native-order chunky RGB16 rows. No allocation.
const std = @import("std");
const V = @Vector(8, u16);
pub fn rgb16(row: []u16) void {
    const zero: V = @splat(0);
    var carry: V = zero;
    var i: usize = 0;
    while (i + 8 <= row.len) : (i += 8) {
        var value = @as(*align(2) V, @ptrCast(row.ptr + i)).*;
        value +%= @shuffle(u16, value, zero, @as(@Vector(8, i32), .{ -1, -1, -1, 0, 1, 2, 3, 4 }));
        value +%= @shuffle(u16, value, zero, @as(@Vector(8, i32), .{ -1, -1, -1, -1, -1, -1, 0, 1 }));
        value +%= @shuffle(u16, carry, zero, @as(@Vector(8, i32), .{ 5, 6, 7, 5, 6, 7, 5, 6 }));
        @as(*align(2) V, @ptrCast(row.ptr + i)).* = value;
        carry = value;
    }
    while (i < row.len) : (i += 1) if (i >= 3) {
        row[i] +%= row[i - 3];
    };
}
test "SIMD predictor matches scalar wrapping and all row tail lengths" {
    var actual: [513]u16 = undefined;
    var expected: [513]u16 = undefined;
    for (0..171) |pixels| {
        const count = pixels * 3;
        for (0..count) |i| {
            actual[i] = @truncate(i *% 59341 +% pixels *% 513);
            expected[i] = actual[i];
        }
        for (3..@max(3, count)) |i| expected[i] +%= expected[i - 3];
        rgb16(actual[0..count]);
        try std.testing.expectEqualSlices(u16, expected[0..count], actual[0..count]);
    }
}
