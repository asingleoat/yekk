//! Read EXIF from a bounded TIFF view. Only the camera metadata reader follows
//! the EXIF subdirectory. All offsets stay inside the supplied view.
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

const Camera = struct {
    make: [100]u8 = @splat(0),
    model: [100]u8 = @splat(0),
    captured: [32]u8 = @splat(0),
    exposure: ?[2]u32 = null,
    aperture: ?f64 = null,
    focal: ?f64 = null,
    iso: ?u32 = null,
};

const Meta = struct {
    entry: [12]u8,
    endian: std.builtin.Endian,

    fn kind(self: Meta) u16 {
        return std.mem.readInt(u16, self.entry[2..4], self.endian);
    }
    fn count(self: Meta) u32 {
        return std.mem.readInt(u32, self.entry[4..8], self.endian);
    }
    fn offset(self: Meta) u32 {
        return std.mem.readInt(u32, self.entry[8..12], self.endian);
    }
    fn long(self: Meta) ?u32 {
        if (self.count() != 1) return null;
        return switch (self.kind()) {
            3 => std.mem.readInt(u16, self.entry[8..10], self.endian),
            4 => self.offset(),
            else => null,
        };
    }
    fn read(self: Meta, view: anytype, output: []u8, length: u64) bool {
        if (length <= 4) {
            @memcpy(output, self.entry[8..][0..output.len]);
            return true;
        }
        const at = self.offset();
        if (at < 8 or at > view.length or length > view.length - at) return false;
        return (view.readAt(output, at) catch return false) == output.len;
    }
    fn ascii(self: Meta, view: anytype, output: []u8) void {
        const length = self.count();
        if (self.kind() != 2 or length == 0) return;
        const slice = output[0..@min(output.len - 1, length)];
        if (!self.read(view, slice, length)) @memset(slice, 0);
        for (slice) |*byte| if (byte.* != 0 and (byte.* < 32 or byte.* > 126)) {
            byte.* = '?';
        };
    }
    fn rational(self: Meta, view: anytype) ?[2]u32 {
        var bytes: [8]u8 = undefined;
        if (self.kind() != 5 or self.count() != 1 or !self.read(view, &bytes, bytes.len)) return null;
        const num = std.mem.readInt(u32, bytes[0..4], self.endian);
        const den = std.mem.readInt(u32, bytes[4..8], self.endian);
        return if (den == 0) null else .{ num, den };
    }
};
fn ratio(value: [2]u32) f64 {
    return @as(f64, @floatFromInt(value[0])) / @as(f64, @floatFromInt(value[1]));
}
fn scan(view: anytype, endian: std.builtin.Endian, offset: u32, camera: *Camera, sub: bool, cancel: *const std.atomic.Value(bool)) !?u32 {
    const start: u64 = offset;
    var count: [2]u8 = undefined;
    if (start < 8 or try view.readAt(&count, start) != count.len) return error.DecodeFailed;
    const entries = std.mem.readInt(u16, &count, endian);
    if (@as(u64, entries) * 12 + 2 > view.length - start) return error.DecodeFailed;
    var exif: ?u32 = null;
    var row: usize = 0;
    var buffer: [12 * 128]u8 = undefined;
    while (row < entries) {
        if (cancel.load(.acquire)) return error.Cancelled;
        const batch = @min(entries - row, buffer.len / 12);
        const bytes = buffer[0 .. batch * 12];
        if (try view.readAt(bytes, start + 2 + row * 12) != bytes.len) return error.DecodeFailed;
        for (0..batch) |index| {
            const meta: Meta = .{ .entry = bytes[index * 12 ..][0..12].*, .endian = endian };
            switch (std.mem.readInt(u16, meta.entry[0..2], endian)) {
                271 => if (!sub) meta.ascii(view, &camera.make),
                272 => if (!sub) meta.ascii(view, &camera.model),
                306 => if (!sub) meta.ascii(view, &camera.captured),
                33434 => camera.exposure = meta.rational(view),
                33437 => if (meta.rational(view)) |value| {
                    camera.aperture = ratio(value);
                },
                34665 => if (!sub) {
                    exif = meta.long();
                },
                34855 => camera.iso = meta.long(),
                36867 => meta.ascii(view, &camera.captured),
                37386 => if (meta.rational(view)) |value| {
                    camera.focal = ratio(value);
                },
                else => {},
            }
        }
        row += batch;
    }
    return exif;
}
pub fn describe(view: anytype, output: []u8, cancel: *const std.atomic.Value(bool)) ![]const u8 {
    var header: [8]u8 = undefined;
    if (try view.readAt(&header, 0) != header.len) return error.DecodeFailed;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, header[0..4], "II\x2a\x00")) .little else if (std.mem.eql(u8, header[0..4], "MM\x00\x2a")) .big else return error.DecodeFailed;
    const offset = std.mem.readInt(u32, header[4..8], endian);
    if (offset == 0) return "";
    var camera: Camera = .{};
    if (try scan(view, endian, offset, &camera, false, cancel)) |sub| {
        if (sub != offset and sub != 0) _ = try scan(view, endian, sub, &camera, true, cancel);
    }
    var writer = std.Io.Writer.fixed(output);
    const make = std.mem.sliceTo(&camera.make, 0);
    const model = std.mem.sliceTo(&camera.model, 0);
    if (make.len > 0 and !std.mem.startsWith(u8, model, make)) try writer.print("{s} ", .{make});
    if (model.len > 0) try writer.writeAll(model);
    if (writer.end > 0) try writer.writeByte('\n');
    const captured = std.mem.sliceTo(&camera.captured, 0);
    if (captured.len > 0) try writer.print("{s}\n", .{captured});
    if (camera.exposure) |value| {
        if (value[0] == 1) try writer.print("1/{d} s  ", .{value[1]}) else try writer.print("{d:.4} s  ", .{ratio(value)});
    }
    if (camera.aperture) |value| try writer.print("f/{d:.1}  ", .{value});
    if (camera.focal) |value| try writer.print("{d:.1} mm  ", .{value});
    if (camera.iso) |iso| try writer.print("ISO {d}", .{iso});
    return std.mem.trim(u8, writer.buffered(), " \n");
}

pub fn normalizeOrientation(bytes: []u8) !void {
    if (bytes.len < 8) return error.DecodeFailed;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, bytes[0..4], "II\x2a\x00")) .little else if (std.mem.eql(u8, bytes[0..4], "MM\x00\x2a")) .big else return error.DecodeFailed;
    const offset = std.mem.readInt(u32, bytes[4..8], endian);
    if (offset == 0) return;
    if (offset < 8 or offset > bytes.len or bytes.len - offset < 2) return error.DecodeFailed;
    const length = std.mem.readInt(u16, bytes[offset..][0..2], endian);
    const start: usize = @as(usize, offset) + 2;
    if (@as(usize, length) * 12 > bytes.len - start) return error.DecodeFailed;
    for (0..length) |index| {
        const entry = bytes[start + index * 12 ..][0..12];
        if (std.mem.readInt(u16, entry[0..2], endian) != 274) continue;
        if (std.mem.readInt(u16, entry[2..4], endian) != 3 or std.mem.readInt(u32, entry[4..8], endian) != 1) return error.DecodeFailed;
        std.mem.writeInt(u16, entry[8..10], 1, endian);
    }
}

pub fn compose(first: Orientation, second: Orientation) Orientation {
    // Match the two basis directions on a square. Translation then follows
    // from the corner that maps to the origin.
    const origin = first.point(3, 3, 0, 0);
    const along_x = first.point(3, 3, 1, 0);
    const start = second.point(3, 3, origin.x, origin.y);
    const target_x = second.point(3, 3, along_x.x, along_x.y);
    inline for (std.meta.tags(Orientation)) |value| {
        const a = value.point(3, 3, 0, 0);
        const b = value.point(3, 3, 1, 0);
        if (a.x == start.x and a.y == start.y and b.x == target_x.x and b.y == target_x.y) return value;
    }
    unreachable;
}
