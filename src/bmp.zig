//! BMP container bounds only. Native libraries decode palette and pixel data.
const std = @import("std");
const Extent = @import("raster").Extent;
pub const Error = error{ DecodeFailed, IncompleteImage, InvalidDimensions, SizeOverflow };
pub const Header = struct {
    extent: Extent,
    profile: ?struct { offset: usize, length: usize } = null,

    pub fn read(bytes: []const u8, file_bytes: u64) Error!Header {
        if (bytes.len < 26 or !std.mem.eql(u8, bytes[0..2], "BM")) return error.IncompleteImage;
        if (u32le(bytes[2..6]) > file_bytes) return error.IncompleteImage;
        const dib = u32le(bytes[14..18]);
        const end = @as(u64, dib) + 14;
        if (end > file_bytes) return error.IncompleteImage;
        const offset = u32le(bytes[10..14]);
        if (offset < end or offset >= file_bytes) return error.DecodeFailed;
        var width: i64 = undefined;
        var height: i64 = undefined;
        var bits: u16 = undefined;
        var compression: u32 = 0;
        var result: Header = undefined;
        if (dib == 12) {
            width = u16le(bytes[18..20]);
            height = u16le(bytes[20..22]);
            if (u16le(bytes[22..24]) != 1) return error.DecodeFailed;
            bits = u16le(bytes[24..26]);
        } else {
            switch (dib) {
                40, 52, 56, 64, 108, 124 => {},
                else => return error.DecodeFailed,
            }
            if (bytes.len < @min(end, 138)) return error.IncompleteImage;
            width = @as(i32, @bitCast(u32le(bytes[18..22])));
            height = @as(i32, @bitCast(u32le(bytes[22..26])));
            if (u16le(bytes[26..28]) != 1) return error.DecodeFailed;
            bits = u16le(bytes[28..30]);
            compression = u32le(bytes[30..34]);
            if (u32le(bytes[34..38]) > file_bytes - offset) return error.IncompleteImage;
        }
        if (height < 0 and compression != 0 and compression != 3 and compression != 6) return error.DecodeFailed;
        if (width > std.math.maxInt(i32) or height == std.math.minInt(i32)) return error.InvalidDimensions;
        const extent = try Extent.init(width, if (height < 0) -height else height);
        _ = try extent.bytes(4, 1);
        result = .{ .extent = extent };
        switch (bits) {
            1, 4, 8, 16, 24, 32 => {},
            else => return error.DecodeFailed,
        }
        const declared = if (dib == 12) 0 else u32le(bytes[46..50]);
        if (@as(u64, declared) * 4 > offset - end) return error.IncompleteImage;
        if (bits <= 8) {
            const maximum = @as(u32, 1) << @as(u5, @intCast(bits));
            const count = if (declared == 0) maximum else declared;
            if (count > maximum or @as(u64, count) * @as(u64, if (dib == 12) 3 else 4) > offset - end) return error.IncompleteImage;
        }
        if (compression == 0 or compression == 3 or compression == 6) {
            if (compression != 0 and bits != 16 and bits != 32) return error.DecodeFailed;
            if (compression == 3 or compression == 6) {
                const count: usize = if (compression == 6 or dib >= 56) 4 else 3;
                const mask_end = 54 + count * 4;
                if (mask_end > bytes.len or mask_end > offset) return error.IncompleteImage;
                var used: u32 = 0;
                for (0..count) |index| {
                    const mask = u32le(bytes[54 + index * 4 ..]);
                    const lowest = mask & (0 -% mask);
                    if ((index < 3 and mask == 0) or (mask & used) != 0 or (mask & (mask +% lowest)) != 0 or (bits == 16 and mask > 65535)) return error.DecodeFailed;
                    used |= mask;
                }
            }
            const row = (@as(u64, extent.width) * bits + 31) / 32 * 4;
            const stored = std.math.mul(u64, row, extent.height) catch return error.SizeOverflow;
            if (stored > file_bytes - offset) return error.IncompleteImage;
        } else if (!((compression == 1 and bits == 8) or (compression == 2 and bits == 4))) return error.DecodeFailed;
        if (dib >= 108) {
            const colour = u32le(bytes[70..74]);
            // Never let an input file select an external ICC profile path.
            if (colour == 0x4c494e4b) return error.DecodeFailed; // PROFILE_LINKED
            if (colour == 0x4d424544) { // PROFILE_EMBEDDED
                if (dib != 124) return error.DecodeFailed;
                const start = @as(u64, u32le(bytes[126..130])) + 14;
                const length = u32le(bytes[130..134]);
                if (length == 0 or start < end or start > file_bytes or length > file_bytes - start) return error.IncompleteImage;
                result.profile = .{ .offset = @intCast(start), .length = length };
            }
        }
        return result;
    }
};
fn u32le(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
fn u16le(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

test "BMP rejects truncated pixels, dimensions, compression and linked profiles" {
    var bytes: [142]u8 = @splat(0);
    @memcpy(bytes[0..2], "BM");
    std.mem.writeInt(u32, bytes[10..14], 138, .little);
    std.mem.writeInt(u32, bytes[14..18], 124, .little);
    std.mem.writeInt(u32, bytes[18..22], 1, .little);
    std.mem.writeInt(u32, bytes[22..26], 1, .little);
    std.mem.writeInt(u16, bytes[26..28], 1, .little);
    std.mem.writeInt(u16, bytes[28..30], 24, .little);
    const valid = try Header.read(&bytes, bytes.len);
    try std.testing.expectEqual(@as(u32, 1), valid.extent.width);
    try std.testing.expectError(error.IncompleteImage, Header.read(bytes[0..141], 141));
    std.mem.writeInt(u32, bytes[70..74], 0x4c494e4b, .little);
    try std.testing.expectError(error.DecodeFailed, Header.read(&bytes, bytes.len));
    std.mem.writeInt(u32, bytes[70..74], 0x4d424544, .little);
    std.mem.writeInt(u32, bytes[126..130], 124, .little);
    std.mem.writeInt(u32, bytes[130..134], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.IncompleteImage, Header.read(&bytes, bytes.len));
    std.mem.writeInt(u32, bytes[18..22], 0x80000000, .little);
    try std.testing.expectError(error.InvalidDimensions, Header.read(&bytes, bytes.len));
}
