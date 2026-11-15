//! Direct libjpeg-turbo adapter. Metadata, storage and orientation are shared
//! Zig code; the native library retains entropy, IDCT and upsampling work.
const std = @import("std");
const c = @import("jpeg_bindings");
const source = @import("source");
const Extent = @import("raster").Extent;
pub const Decoded = @import("pixel_storage").Decoded;
const Failure = source.Error || error{ OutOfMemory, SourceChanged, Cancelled };
pub const Options = struct {
    prefix_bytes: usize = 0,
    raw_retirement: bool = false,
    cancel: ?*const std.atomic.Value(bool) = null,
};
pub const Plan = struct {
    file: source.Open,
    stored: Extent,
    orientation: source.Orientation = .identity,
    gray: bool,
    native: bool,
    profile_parts: [255]?source.Range = @splat(null),
    profile_count: usize = 0,
    profile_bytes: usize = 0,
    pub fn read(file: source.Open, cancel: ?*const std.atomic.Value(bool)) Failure!Plan {
        var signature: [2]u8 = undefined;
        try readExact(file, &signature, 0);
        if (!std.mem.eql(u8, &signature, "\xff\xd8")) return error.DecodeFailed;
        const length: u64 = @intCast(file.stamp.bytes);
        var at: u64 = 2;
        var dimensions: ?Extent = null;
        var gray = false;
        var native = false;
        var orientation: source.Orientation = .identity;
        var saw_exif = false;
        var parts: [255]?source.Range = @splat(null);
        var part_count: usize = 0;
        var profile_bytes: usize = 0;
        while (true) {
            try cancelled(cancel);
            var marker: [2]u8 = undefined;
            try readExact(file, &marker, at);
            if (marker[0] != 0xff) return error.DecodeFailed;
            at += 2;
            while (marker[1] == 0xff) {
                try readExact(file, marker[1..], at);
                at += 1;
            }
            const code = marker[1];
            if (code == 0x01) continue;
            if (code == 0 or code == 0xd8 or code == 0xd9 or (code >= 0xd0 and code <= 0xd7)) return error.DecodeFailed;
            var size_bytes: [2]u8 = undefined;
            try readExact(file, &size_bytes, at);
            const size = std.mem.readInt(u16, &size_bytes, .big);
            if (size < 2 or at > length or size > length - at) return error.IncompleteImage;
            const payload: source.Range = .{ .file = file, .offset = at + 2, .length = size - 2 };
            if (code == 0xda) {
                const stored = dimensions orelse return error.DecodeFailed;
                for (parts[0..part_count]) |part| if (part == null) return error.DecodeFailed;
                if (!file.unchanged()) return error.SourceChanged;
                return .{ .file = file, .stored = stored, .orientation = orientation, .gray = gray, .native = native, .profile_parts = parts, .profile_count = part_count, .profile_bytes = profile_bytes };
            }
            if ((code >= 0xc0 and code <= 0xcf) and code != 0xc4 and code != 0xc8 and code != 0xcc) {
                if (dimensions != null or payload.length < 6) return error.DecodeFailed;
                var sof: [6]u8 = undefined;
                try readExact(file, &sof, payload.offset);
                dimensions = try Extent.init(std.mem.readInt(u16, sof[3..5], .big), std.mem.readInt(u16, sof[1..3], .big));
                if (payload.length != 6 + @as(usize, sof[5]) * 3) return error.DecodeFailed;
                gray = sof[5] == 1;
                native = (sof[0] != 8 or (sof[5] != 1 and sof[5] != 3) or (code != 0xc0 and code != 0xc1 and code != 0xc2));
                _ = try dimensions.?.bytes(4, 1);
            } else if (code == 0xe1 and payload.length >= 6) {
                var prefix: [6]u8 = undefined;
                try readExact(file, &prefix, payload.offset);
                if (std.mem.eql(u8, &prefix, "Exif\x00\x00")) {
                    // Some writers append another Exif block with auxiliary
                    // tags. The first block supplies the image orientation.
                    if (!saw_exif) orientation = try source.exifOrientation(source.Range{ .file = file, .offset = payload.offset + 6, .length = payload.length - 6 });
                    saw_exif = true;
                }
            } else if (code == 0xe2 and payload.length >= 12) {
                var prefix: [14]u8 = undefined;
                if (try payload.readAt(&prefix, 0) < 12) return error.IncompleteImage;
                if (std.mem.eql(u8, prefix[0..12], "ICC_PROFILE\x00")) {
                    if (payload.length < 14) return error.DecodeFailed;
                    const number = prefix[12];
                    const count = prefix[13];
                    if (count == 0 or number == 0 or number > count or (part_count != 0 and part_count != count) or parts[number - 1] != null) return error.DecodeFailed;
                    part_count = count;
                    const part: source.Range = .{ .file = file, .offset = payload.offset + 14, .length = payload.length - 14 };
                    parts[number - 1] = part;
                    profile_bytes = try add(profile_bytes, part.length);
                }
            }
            at += size;
        }
    }
    pub fn extent(self: Plan) Extent {
        return if (self.orientation.swapsAxes()) .{ .width = self.stored.height, .height = self.stored.width } else self.stored;
    }
    const Layout = struct { prefix: usize, end: usize, profile_end: usize, input_end: usize, total: usize };
    fn layout(self: Plan, options: Options) Failure!Layout {
        const prefix = (try add(options.prefix_bytes, 63)) & ~@as(usize, 63);
        const end = try add(prefix, try self.stored.bytes(4, 1));
        const profile_end = try add(end, self.profile_bytes);
        const input_end = try add(profile_end, @intCast(self.file.stamp.bytes));
        const total = try add(input_end, if (self.orientation == .identity) 0 else try self.stored.bytes(4, 1));
        return .{ .prefix = prefix, .end = end, .profile_end = profile_end, .input_end = input_end, .total = total };
    }
    pub fn storageBytes(self: Plan, options: Options) Failure!usize {
        return (try self.layout(options)).total;
    }
    pub fn decode(self: Plan, allocator: std.mem.Allocator, options: Options) Failure!Decoded {
        try cancelled(options.cancel);
        if (self.native) return error.DecodeFailed;
        const storage = try self.layout(options);
        const decoder = c.tj3Init(c.TJINIT_DECOMPRESS) orelse return error.OutOfMemory;
        defer c.tj3Destroy(decoder);
        try check(c.tj3Set(decoder, c.TJPARAM_STOPONWARNING, 1));
        // Metadata lives in our slab. Do not retain a duplicate native copy.
        try check(c.tj3Set(decoder, c.TJPARAM_SAVEMARKERS, 0));
        const pointer = allocator.rawAlloc(storage.total, .fromByteUnits(64), @returnAddress()) orelse return error.OutOfMemory;
        const slab = @as([*]align(64) u8, @alignCast(pointer))[0..storage.total];
        const size = self.extent();
        const decoded: Decoded = .{ .allocator = allocator, .slab = slab, .pixels = slab[storage.prefix..storage.end], .profile = slab[storage.end..storage.profile_end], .width = size.width, .height = size.height, .row_bytes = @as(usize, size.width) * 4, .bits_per_component = 8, .raw_retirement = options.raw_retirement };
        errdefer decoded.deinit();
        const input = slab[storage.profile_end..storage.input_end];
        // Read in cancellable blocks, directly into the retained slab scratch.
        var offset: usize = 0;
        while (offset < input.len) {
            try cancelled(options.cancel);
            const end = @min(input.len, offset + 1024 * 1024);
            try readExact(self.file, input[offset..end], offset);
            offset = end;
        }
        try check(c.tj3DecompressHeader(decoder, input.ptr, input.len));
        if (c.tj3Get(decoder, c.TJPARAM_JPEGWIDTH) != self.stored.width or c.tj3Get(decoder, c.TJPARAM_JPEGHEIGHT) != self.stored.height or c.tj3Get(decoder, c.TJPARAM_PRECISION) != 8) return error.SourceChanged;
        const colorspace = c.tj3Get(decoder, c.TJPARAM_COLORSPACE);
        if (colorspace != c.TJCS_RGB and colorspace != c.TJCS_YCbCr and colorspace != c.TJCS_GRAY) return error.DecodeFailed;
        if (self.gray != (colorspace == c.TJCS_GRAY)) return error.SourceChanged;
        var profile_at = storage.end;
        for (self.profile_parts[0..self.profile_count]) |maybe_part| {
            const part = maybe_part.?;
            const start: usize = @intCast(part.offset);
            if (start > input.len or part.length > input.len - start) return error.SourceChanged;
            @memcpy(slab[profile_at..][0..part.length], input[start..][0..part.length]);
            profile_at += part.length;
        }
        if (self.profile_count != 0) {
            const profile = decoded.profile;
            if (profile.len < 132 or std.mem.readInt(u32, profile[0..4], .big) != profile.len or !std.mem.eql(u8, profile[36..40], "acsp") or !std.mem.eql(u8, profile[16..20], if (self.gray) "GRAY" else "RGB ")) return error.DecodeFailed;
        }
        try cancelled(options.cancel);
        const pixels = if (self.orientation == .identity) decoded.pixels else slab[storage.input_end..];
        try check(c.tj3Decompress8(decoder, input.ptr, input.len, pixels.ptr, 0, c.TJPF_RGBA));
        try cancelled(options.cancel);
        if (self.orientation != .identity) self.orient(pixels, decoded, options.cancel) catch return error.Cancelled;
        if (!self.file.unchanged()) return error.SourceChanged;
        return decoded;
    }
    fn orient(self: Plan, input: []const u8, decoded: Decoded, cancel: ?*const std.atomic.Value(bool)) Failure!void {
        const width: usize = self.stored.width;
        const height: usize = self.stored.height;
        // Keep transposed writes inside small cache tiles.
        var by: usize = 0;
        while (by < height) : (by += 32) {
            try cancelled(cancel);
            var bx: usize = 0;
            while (bx < width) : (bx += 32) for (by..@min(height, by + 32)) |y| for (bx..@min(width, bx + 32)) |x| {
                const point = self.orientation.point(width, height, x, y);
                @memcpy(decoded.pixels[point.y * decoded.row_bytes + point.x * 4 ..][0..4], input[(y * width + x) * 4 ..][0..4]);
            };
        }
    }
};
fn check(status: c_int) Failure!void {
    if (status != 0) return error.DecodeFailed;
}
fn cancelled(flag: ?*const std.atomic.Value(bool)) Failure!void {
    if (flag) |value| if (value.load(.acquire)) return error.Cancelled;
}
fn add(a: usize, b: usize) Failure!usize {
    const result = std.math.add(usize, a, b) catch return error.SizeOverflow;
    return if (result > std.math.maxInt(isize)) error.SizeOverflow else result;
}
fn readExact(file: source.Open, output: []u8, offset: u64) Failure!void {
    var read: usize = 0;
    while (read < output.len) {
        const count = try file.readAt(output[read..], offset + read);
        if (count == 0) return error.IncompleteImage;
        read += count;
    }
}

test "direct JPEG preserves all orientations, progressive scans and trailers in one owned slab" {
    const reference_file = try source.open("tests/fixtures/jpeg-orientation1.jpg", true);
    defer reference_file.close();
    const reference_plan = try Plan.read(reference_file, null);
    const reference = try reference_plan.decode(std.testing.allocator, .{});
    defer reference.deinit();
    const maps = [_][6]usize{ .{ 0, 1, 2, 3, 4, 5 }, .{ 2, 1, 0, 5, 4, 3 }, .{ 5, 4, 3, 2, 1, 0 }, .{ 3, 4, 5, 0, 1, 2 }, .{ 0, 3, 1, 4, 2, 5 }, .{ 3, 0, 4, 1, 5, 2 }, .{ 5, 2, 4, 1, 3, 0 }, .{ 2, 5, 1, 4, 0, 3 } };
    for (maps, 1..) |map, orientation| {
        var name: [128]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&name, "tests/fixtures/jpeg-orientation{d}.jpg", .{orientation}, 0);
        const file = try source.open(path, true);
        defer file.close();
        const plan = try Plan.read(file, null);
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const decoded = try plan.decode(counted.allocator(), .{ .prefix_bytes = 65 });
        for (map, 0..) |src, dst| try std.testing.expectEqualSlices(u8, reference.pixels[src * 4 ..][0..4], decoded.pixels[dst * 4 ..][0..4]);
        decoded.deinit();
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    }
    inline for (.{ "jpeg-trailer.jpg", "jpeg-boundary.jpg", "jpeg-progressive.jpg", "orientation6.jpg" }) |name| {
        const file = try source.open("tests/fixtures/" ++ name, true);
        defer file.close();
        const plan = try Plan.read(file, null);
        const decoded = try plan.decode(std.testing.allocator, .{});
        decoded.deinit();
    }
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, reference_plan.decode(failed.allocator(), .{}));
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, reference_plan.decode(std.testing.allocator, .{ .cancel = &cancel }));
}
test "JPEG retains out-of-order ICC segments and expands grayscale without a native metadata copy" {
    inline for (.{ "jpeg-profile-srgb.jpg", "jpeg-profile-gray.jpg", "jpeg-gray.jpg" }) |name| {
        const file = try source.open("tests/fixtures/" ++ name, true);
        defer file.close();
        const plan = try Plan.read(file, null);
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const decoded = try plan.decode(counted.allocator(), .{});
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
        if (comptime std.mem.indexOf(u8, name, "profile") != null) {
            try std.testing.expectEqual(@as(usize, 2), plan.profile_count);
            try std.testing.expect(std.mem.eql(u8, decoded.profile[16..20], if (plan.gray) "GRAY" else "RGB "));
        }
        if (plan.gray) for (0..@as(usize, decoded.width) * decoded.height) |i| {
            try std.testing.expectEqual(decoded.pixels[i * 4], decoded.pixels[i * 4 + 1]);
            try std.testing.expectEqual(decoded.pixels[i * 4], decoded.pixels[i * 4 + 2]);
            try std.testing.expectEqual(@as(u8, 255), decoded.pixels[i * 4 + 3]);
        };
        decoded.deinit();
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    }
}
