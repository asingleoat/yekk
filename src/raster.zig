//! Validate file dimensions before address arithmetic or native buffer calls.
const std = @import("std");
pub const Error = error{ InvalidDimensions, SizeOverflow };
pub const Extent = struct {
    width: u32,
    height: u32,

    pub fn init(width: i64, height: i64) Error!Extent {
        if (width <= 0 or height <= 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return error.InvalidDimensions;
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }
    pub fn bytes(self: Extent, channels: usize, sample_bytes: usize) Error!usize {
        const pixel = std.math.mul(usize, channels, sample_bytes) catch return error.SizeOverflow;
        const row = std.math.mul(usize, self.width, pixel) catch return error.SizeOverflow;
        const total = std.math.mul(usize, row, self.height) catch return error.SizeOverflow;
        if (pixel == 0 or total > std.math.maxInt(isize)) return error.SizeOverflow;
        return total;
    }
};

test "untrusted dimensions and channel expansion cannot wrap buffer lengths" {
    inline for (.{ .{ 0, 1 }, .{ -1, 1 }, .{ 1, -1 }, .{ 1, 0 }, .{ 4294967296, 1 } }) |size| {
        try std.testing.expectError(error.InvalidDimensions, Extent.init(size[0], size[1]));
    }
    const largest = try Extent.init(std.math.maxInt(u32), std.math.maxInt(u32));
    try std.testing.expectError(error.SizeOverflow, largest.bytes(4, 2));
    const signed = try Extent.init(std.math.maxInt(i32), std.math.maxInt(i32));
    try std.testing.expectError(error.SizeOverflow, signed.bytes(4, 1));
    const large = try Extent.init(1_000_000, 1_000_000);
    try std.testing.expectEqual(@as(usize, 8_000_000_000_000), try large.bytes(4, 2));
}
