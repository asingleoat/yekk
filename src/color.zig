//! Exact SDR quantization of linear-light f32 samples. No per-pixel powers.
const std = @import("std");
const one = @as(u32, @bitCast(@as(f32, 1)));
const first_bucket = @as(u32, @bitCast(@as(f32, 0.5 / 255.0 / 12.92))) >> 16;
const bucket_count = (one >> 16) - first_bucket;

pub const Encoding = struct {
    buckets: [bucket_count]u8,
    thresholds: [257]u32,

    /// Each bucket spans less than one encoded sample. Its lower result plus
    /// one exact threshold comparison covers every f32 within that bucket.
    pub fn init() Encoding {
        var result: Encoding = undefined;
        result.thresholds[0] = 0;
        result.thresholds[256] = one;
        for (1..256) |code| {
            var low: u32 = 0;
            var high: u32 = one;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (reference(@bitCast(middle)) >= code) high = middle else low = middle + 1;
            }
            result.thresholds[code] = low;
        }
        for (&result.buckets, 0..) |*value, index| {
            const bits: u32 = @as(u32, @intCast(index + first_bucket)) << 16;
            value.* = reference(@bitCast(bits));
            std.debug.assert(@as(u16, reference(@bitCast(bits + 65535))) <= @as(u16, value.*) + 1);
        }
        return result;
    }
    pub inline fn encode(self: *const Encoding, value: f32) u8 {
        const bits: u32 = @bitCast(value);
        // Also covers negative samples, signed zero, infinities and NaNs.
        if (bits >= 0x7f800000 or bits < self.thresholds[1]) return 0;
        if (bits >= one) return 255;
        const base = self.buckets[(bits >> 16) - first_bucket];
        return base + @as(u8, @intFromBool(bits >= self.thresholds[@as(usize, base) + 1]));
    }
};

/// Rounded conversion between normalized unsigned sample widths.
/// Keep the scalar expression simple; the compiler can vectorize the loop.
pub fn quantize16(source: []const u16, destination: []u8) void {
    std.debug.assert(source.len == destination.len);
    for (source, destination) |sample, *out| out.* = @intCast((@as(u32, sample) + 128) / 257);
}

fn reference(value: f32) u8 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    if (value >= 1) return 255;
    const encoded = if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255));
}

test "quantization preserves reference rounding at every transition and bucket edge" {
    const encoding = Encoding.init();
    for (encoding.thresholds[1..256]) |threshold| {
        for (threshold - 256..threshold + 256) |bits| {
            const value: f32 = @bitCast(@as(u32, @intCast(bits)));
            try std.testing.expectEqual(reference(value), encoding.encode(value));
        }
    }
    for (0..bucket_count) |index| {
        const first = @as(u32, @intCast(index + first_bucket)) << 16;
        for ([_]u32{ first, first + 1, first + 32768, first + 65534, first + 65535 }) |bits| {
            const value: f32 = @bitCast(bits);
            try std.testing.expectEqual(reference(value), encoding.encode(value));
        }
    }
    for ([_]f32{ 0, -0.0, -1, 1, 2, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |value| {
        try std.testing.expectEqual(reference(value), encoding.encode(value));
    }
}
