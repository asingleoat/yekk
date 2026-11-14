//! feh/X geometry syntax, interpreted in native window points.
const std = @import("std");
/// The edge is significant even for a zero distance (`-0`).
pub const Offset = union(enum) {
    near: u32,
    far: u32,

    pub fn distance(self: Offset) u32 {
        return switch (self) {
            inline else => |value| value,
        };
    }
    pub fn resolve(self: Offset, available: f64) f64 {
        const value: f64 = @floatFromInt(self.distance());
        return switch (self) {
            .near => value,
            .far => available - value,
        };
    }
};
pub const Geometry = struct {
    width: u32,
    height: u32,
    position: ?struct { x: Offset, y: Offset } = null,
    pub fn parse(text: []const u8) !Geometry {
        const cross = std.mem.indexOfScalar(u8, text, 'x') orelse return error.InvalidGeometry;
        var end = cross + 1;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        var result: Geometry = .{ .width = try std.fmt.parseInt(u32, text[0..cross], 10), .height = try std.fmt.parseInt(u32, text[cross + 1 .. end], 10) };
        if (result.width == 0 or result.height == 0) return error.InvalidGeometry;
        if (end == text.len) return result;
        if (text[end] != '+' and text[end] != '-') return error.InvalidGeometry;
        const right = text[end] == '-';
        const x_start = end + 1;
        end = x_start;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        const x = try std.fmt.parseInt(u32, text[x_start..end], 10);
        if (end == text.len or (text[end] != '+' and text[end] != '-')) return error.InvalidGeometry;
        const y = try std.fmt.parseInt(u32, text[end + 1 ..], 10);
        result.position = .{ .x = if (right) .{ .far = x } else .{ .near = x }, .y = if (text[end] == '-') .{ .far = y } else .{ .near = y } };
        return result;
    }
};
test "geometry preserves edge-relative negative zero and rejects incomplete positions" {
    const plain = try Geometry.parse("960x640");
    try std.testing.expect(plain.position == null);
    const position = try Geometry.parse("960x640-0+17");
    try std.testing.expectEqual(Offset{ .far = 0 }, position.position.?.x);
    try std.testing.expectEqual(Offset{ .near = 17 }, position.position.?.y);
    try std.testing.expectEqual(320, position.position.?.x.resolve(320));
    try std.testing.expectEqual(17, position.position.?.y.resolve(240));
    try std.testing.expectError(error.InvalidGeometry, Geometry.parse("960x640+2"));
    try std.testing.expectError(error.InvalidGeometry, Geometry.parse("0x640"));
}
