//! Read only the first TIFF IFD's orientation. Offsets stay inside the APP/eXIf
//! payload; no metadata pointer or sub-IFD is followed into another object.
const std = @import("std");
pub const Orientation = enum(u4) {
    identity = 1,
    mirror_x,
    half_turn,
    mirror_y,
    transpose,
    clockwise,
    transverse,
    counterclockwise,
    pub fn swapsAxes(self: Orientation) bool {
        return @backingInt(self) >= 5;
    }
    pub fn point(self: Orientation, width: usize, height: usize, x: usize, y: usize) struct { x: usize, y: usize } {
        return switch (self) {
            .identity => .{ .x = x, .y = y },
            .mirror_x => .{ .x = width - 1 - x, .y = y },
            .half_turn => .{ .x = width - 1 - x, .y = height - 1 - y },
            .mirror_y => .{ .x = x, .y = height - 1 - y },
            .transpose => .{ .x = y, .y = x },
            .clockwise => .{ .x = height - 1 - y, .y = x },
            .transverse => .{ .x = height - 1 - y, .y = width - 1 - x },
            .counterclockwise => .{ .x = y, .y = width - 1 - x },
        };
    }
};
pub fn orientation(view: anytype) !Orientation {
    var header: [8]u8 = undefined;
    if (try view.readAt(&header, 0) != header.len) return error.DecodeFailed;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, header[0..4], "II\x2a\x00")) .little else if (std.mem.eql(u8, header[0..4], "MM\x00\x2a")) .big else return error.DecodeFailed;
    const offset = std.mem.readInt(u32, header[4..8], endian);
    if (offset == 0) return .identity;
    if (offset < 8 or offset > view.length or view.length - offset < 2) return error.DecodeFailed;
    var count_bytes: [2]u8 = undefined;
    if (try view.readAt(&count_bytes, offset) != 2) return error.IncompleteImage;
    const count = std.mem.readInt(u16, &count_bytes, endian);
    if (@as(usize, count) * 12 + 4 > view.length - offset - 2) return error.DecodeFailed;
    var buffer: [12 * 128]u8 = undefined;
    var first: usize = 0;
    var result: ?Orientation = null;
    while (first < count) {
        const entries = @min(count - first, buffer.len / 12);
        const bytes = buffer[0 .. entries * 12];
        if (try view.readAt(bytes, offset + 2 + first * 12) != bytes.len) return error.IncompleteImage;
        for (0..entries) |i| {
            const entry = bytes[i * 12 ..][0..12];
            if (std.mem.readInt(u16, entry[0..2], endian) != 274) continue;
            if (result != null or std.mem.readInt(u16, entry[2..4], endian) != 3 or std.mem.readInt(u32, entry[4..8], endian) != 1) return error.DecodeFailed;
            const value = std.mem.readInt(u16, entry[8..10], endian);
            if (value < 1 or value > 8) return error.DecodeFailed;
            result = @fromBackingInt(@as(u4, @intCast(value)));
        }
        first += entries;
    }
    return result orelse .identity;
}
