//! Bounded Netpbm P1–P6 decoding. No native parser sees file metadata.
const std = @import("std");
const source = @import("source");
const Extent = @import("raster").Extent;
pub const Decoded = @import("pixel_storage").Decoded;
pub const Failure = source.Error || error{ OutOfMemory, SourceChanged, Cancelled };
const Kind = enum(u8) { bitmap_ascii = '1', gray_ascii, rgb_ascii, bitmap, gray, rgb };
pub const Options = struct {
    workers: usize = 1,
    prefix_bytes: usize = 0,
    row_alignment: enum { contiguous, cache_line } = .cache_line,
    raw_retirement: bool = false,
    cancel: ?*const std.atomic.Value(bool) = null,
};
const Reader = struct {
    file: source.Open,
    position: u64 = 0,
    base: u64 = 0,
    count: usize = 0,
    buffer: [4096]u8 = undefined,
    cancel: ?*const std.atomic.Value(bool) = null,
    fn peek(self: *Reader) Failure!?u8 {
        if (self.position >= @as(u64, @intCast(self.file.stamp.bytes))) return null;
        if (self.position < self.base or self.position - self.base >= self.count) {
            try cancelled(self.cancel);
            self.base = self.position;
            self.count = try self.file.readAt(&self.buffer, self.position);
            if (self.count == 0) return error.IncompleteImage;
        }
        return self.buffer[@intCast(self.position - self.base)];
    }
    fn take(self: *Reader) Failure!u8 {
        const value = (try self.peek()) orelse return error.IncompleteImage;
        self.position += 1;
        return value;
    }
    fn whitespace(self: *Reader) Failure!void {
        while (try self.peek()) |value| {
            if (std.ascii.isWhitespace(value)) {
                self.position += 1;
            } else if (value == '#') {
                while (try self.peek()) |comment| {
                    self.position += 1;
                    if (comment == '\n' or comment == '\r') break;
                }
            } else break;
        }
    }
    fn number(self: *Reader) Failure!u32 {
        try self.whitespace();
        var value: u32 = 0;
        var digits = false;
        while (try self.peek()) |digit| {
            if (!std.ascii.isDigit(digit)) {
                if (!std.ascii.isWhitespace(digit) and digit != '#') return error.DecodeFailed;
                break;
            }
            digits = true;
            value = std.math.mul(u32, value, 10) catch return error.DecodeFailed;
            value = std.math.add(u32, value, digit - '0') catch return error.DecodeFailed;
            self.position += 1;
        }
        if (!digits) return error.IncompleteImage;
        return value;
    }
    fn separator(self: *Reader) Failure!void {
        const value = try self.take();
        if (!std.ascii.isWhitespace(value)) return error.DecodeFailed;
        if (value == '\r' and try self.peek() == '\n') self.position += 1;
    }
};
pub const Plan = struct {
    file: source.Open,
    extent: Extent,
    kind: Kind,
    maximum: u16,
    offset: u64,
    input_bytes: usize,
    pub fn open(path: []const u8, cancel: ?*const std.atomic.Value(bool)) Failure!?Plan {
        var name: [4096]u8 = undefined;
        const terminated = std.fmt.bufPrintSentinel(&name, "{s}", .{path}, 0) catch return error.UnreadableImage;
        const file = try source.open(terminated, false);
        var owned = true;
        defer if (owned) file.close();
        if (std.meta.activeTag(file.format) != .pnm) return null;
        var reader: Reader = .{ .file = file, .cancel = cancel };
        if (try reader.take() != 'P') return null;
        const magic = try reader.take();
        if (magic < '1' or magic > '6') return null;
        const kind: Kind = @fromBackingInt(@intCast(magic));
        try reader.separator();
        const width = try reader.number();
        const height = try reader.number();
        const maximum = if (kind == .bitmap or kind == .bitmap_ascii) 1 else try reader.number();
        if (maximum == 0 or maximum > 65535) return error.DecodeFailed;
        const extent = try Extent.init(width, height);
        _ = try extent.bytes(4, if (maximum > 255) 2 else 1);
        const channels: usize = if (kind == .rgb or kind == .rgb_ascii) 3 else 1;
        const is_ascii = magic <= '3';
        if (!is_ascii) try reader.separator();
        const needed = if (kind == .bitmap) std.math.mul(usize, (@as(usize, width) + 7) / 8, height) catch return error.SizeOverflow else try extent.bytes(channels, if (!is_ascii and maximum > 255) 2 else 1);
        if (needed > @as(u64, @intCast(file.stamp.bytes)) - reader.position) return error.IncompleteImage;
        owned = false;
        return .{ .file = file, .extent = extent, .kind = kind, .maximum = @intCast(maximum), .offset = reader.position, .input_bytes = needed };
    }
    pub fn format(self: Plan) [:0]const u8 {
        return switch (self.kind) {
            .bitmap, .bitmap_ascii => "pbm",
            .gray, .gray_ascii => "pgm",
            .rgb, .rgb_ascii => "ppm",
        };
    }
    pub fn deinit(self: Plan) void {
        self.file.close();
    }
    pub fn workerCount(self: Plan, requested: usize) usize {
        if (@backingInt(self.kind) <= '3' or @as(u64, self.extent.width) * self.extent.height < 8 * 1024 * 1024) return 1;
        return @max(1, @min(requested, self.extent.height));
    }
    pub fn storageBytes(self: Plan, options: Options) Failure!usize {
        return (try self.layout(options)).total;
    }
    fn layout(self: Plan, options: Options) Failure!struct { prefix: usize, row: usize, pixels: usize, total: usize, work_offset: usize, workers: usize } {
        const pixel_bytes: usize = if (self.maximum > 255) 8 else 4;
        var row = std.math.mul(usize, self.extent.width, pixel_bytes) catch return error.SizeOverflow;
        if (options.row_alignment == .cache_line) row = try align64(row);
        const bytes = std.math.mul(usize, row, self.extent.height) catch return error.SizeOverflow;
        const prefix = try align64(options.prefix_bytes);
        const end = std.math.add(usize, prefix, bytes) catch return error.SizeOverflow;
        const workers = self.workerCount(options.workers);
        const work_offset = try align64(end);
        const work_bytes = if (workers > 1) std.math.mul(usize, workers, @sizeOf(Work)) catch return error.SizeOverflow else 0;
        const total = if (workers > 1) std.math.add(usize, work_offset, work_bytes) catch return error.SizeOverflow else end;
        if (total > std.math.maxInt(isize)) return error.SizeOverflow;
        return .{ .prefix = prefix, .row = row, .pixels = bytes, .total = total, .work_offset = work_offset, .workers = workers };
    }
    pub fn decode(self: Plan, allocator: std.mem.Allocator, options: Options) Failure!Decoded {
        try cancelled(options.cancel);
        const storage = try self.layout(options);
        const pointer = allocator.rawAlloc(storage.total, .fromByteUnits(64), @returnAddress()) orelse return error.OutOfMemory;
        const slab = @as([*]align(64) u8, @alignCast(pointer))[0..storage.total];
        const pixels = slab[storage.prefix..][0..storage.pixels];
        const bits: u8 = if (self.maximum > 255) 16 else 8;
        const decoded: Decoded = .{ .allocator = allocator, .slab = slab, .pixels = pixels, .profile = pixels[pixels.len..], .width = self.extent.width, .height = self.extent.height, .row_bytes = storage.row, .raw_retirement = options.raw_retirement, .bits_per_component = bits };
        errdefer decoded.deinit();
        if (@backingInt(self.kind) >= '4') {
            if (storage.workers == 1) {
                try self.decodeBinary(pixels, storage.row, options.cancel);
            } else {
                const work: [*]Work = @ptrCast(@alignCast(slab[storage.work_offset..].ptr));
                const input_row = self.input_bytes / self.extent.height;
                for (0..storage.workers) |lane| {
                    const first = @as(usize, self.extent.height) * lane / storage.workers;
                    const end = @as(usize, self.extent.height) * (lane + 1) / storage.workers;
                    var part = self;
                    part.extent.height = @intCast(end - first);
                    part.offset += first * input_row;
                    part.input_bytes = (end - first) * input_row;
                    work[lane] = .{ .plan = part, .pixels = pixels[first * storage.row .. end * storage.row], .stride = storage.row, .cancel = options.cancel };
                }
                @import("parallel").run(work[0..storage.workers], Work.run);
                for (work[0..storage.workers]) |item| if (item.failure) |err| return err;
            }
        } else {
            var reader: Reader = .{ .file = self.file, .position = self.offset, .cancel = options.cancel };
            if (bits == 16) try self.ascii(u16, &reader, pixels, storage.row) else try self.ascii(u8, &reader, pixels, storage.row);
        }
        if (!self.file.unchanged()) return error.SourceChanged;
        return decoded;
    }
    fn decodeBinary(self: Plan, pixels: []u8, stride: usize, cancel: ?*const std.atomic.Value(bool)) Failure!void {
        // Each job owns its complete output region, including the input tail.
        // Forward expansion reads each sample before output can overwrite it.
        const input = pixels[pixels.len - self.input_bytes ..];
        var read: usize = 0;
        while (read < input.len) {
            try cancelled(cancel);
            const count = try self.file.readAt(input[read..@min(input.len, read + 1024 * 1024)], self.offset + read);
            if (count == 0) return error.IncompleteImage;
            read += count;
        }
        if (self.maximum > 255) try self.binary(u16, input, pixels, stride, cancel) else try self.binary(u8, input, pixels, stride, cancel);
    }
    fn binary(self: Plan, comptime T: type, input: []const u8, pixels: []u8, stride: usize, cancel: ?*const std.atomic.Value(bool)) Failure!void {
        if (self.kind == .bitmap) {
            for (0..self.extent.height) |y| {
                try cancelled(cancel);
                const output = pixels[y * stride ..];
                for (0..self.extent.width) |x| {
                    const bit = (input[y * ((@as(usize, self.extent.width) + 7) / 8) + x / 8] >> @as(u3, @intCast(7 - x % 8))) & 1;
                    const value: u8 = 0 -% @as(u8, 1 - bit);
                    @memset(output[x * 4 ..][0..3], value);
                    output[x * 4 + 3] = 255;
                }
                @memset(output[@as(usize, self.extent.width) * 4 ..][0 .. stride - @as(usize, self.extent.width) * 4], 0);
            }
        } else if (self.kind == .rgb) {
            if (self.maximum == std.math.maxInt(T)) try self.binarySamples(T, 3, false, input, pixels, stride, cancel) else try self.binarySamples(T, 3, true, input, pixels, stride, cancel);
        } else {
            if (self.maximum == std.math.maxInt(T)) try self.binarySamples(T, 1, false, input, pixels, stride, cancel) else try self.binarySamples(T, 1, true, input, pixels, stride, cancel);
        }
    }
    fn binarySamples(self: Plan, comptime T: type, comptime channels: usize, comptime normalize: bool, input: []const u8, pixels: []u8, stride: usize, cancel: ?*const std.atomic.Value(bool)) Failure!void {
        for (0..self.extent.height) |y| {
            const output: [*]T = @ptrCast(@alignCast(pixels[y * stride ..].ptr));
            var x: usize = 0;
            while (x < self.extent.width) {
                try cancelled(cancel);
                const end = @min(self.extent.width, x + 8192);
                while (x < end) : (x += 1) {
                    var rgb: [3]T = undefined;
                    inline for (0..channels) |channel| {
                        const index = ((y * self.extent.width + x) * channels + channel) * @sizeOf(T);
                        const value = std.mem.readInt(T, input[index..][0..@sizeOf(T)], .big);
                        rgb[channel] = if (normalize) try scale(T, value, self.maximum) else value;
                    }
                    if (channels == 1) rgb = @splat(rgb[0]);
                    @memcpy(output[x * 4 ..][0..3], &rgb);
                    output[x * 4 + 3] = std.math.maxInt(T);
                }
            }
            @memset(pixels[y * stride + @as(usize, self.extent.width) * 4 * @sizeOf(T) ..][0 .. stride - @as(usize, self.extent.width) * 4 * @sizeOf(T)], 0);
        }
    }
    fn ascii(self: Plan, comptime T: type, reader: *Reader, pixels: []u8, stride: usize) Failure!void {
        const channels: usize = if (self.kind == .rgb_ascii) 3 else 1;
        for (0..self.extent.height) |y| {
            const output: [*]T = @ptrCast(@alignCast(pixels[y * stride ..].ptr));
            for (0..self.extent.width) |x| {
                var rgb: [3]T = undefined;
                for (0..channels) |channel| {
                    const value = if (self.kind == .bitmap_ascii) bit: {
                        try reader.whitespace();
                        const digit = try reader.take();
                        if (digit != '0' and digit != '1') return error.DecodeFailed;
                        break :bit @as(u32, '1') - digit;
                    } else try reader.number();
                    rgb[channel] = try scale(T, value, self.maximum);
                }
                if (channels == 1) rgb = @splat(rgb[0]);
                @memcpy(output[x * 4 ..][0..3], &rgb);
                output[x * 4 + 3] = std.math.maxInt(T);
            }
            @memset(pixels[y * stride + @as(usize, self.extent.width) * 4 * @sizeOf(T) ..][0 .. stride - @as(usize, self.extent.width) * 4 * @sizeOf(T)], 0);
        }
    }
};
const Work = struct {
    plan: Plan,
    pixels: []u8,
    stride: usize,
    cancel: ?*const std.atomic.Value(bool),
    failure: ?Failure = null,
    thread: ?std.Thread = null,
    fn run(self: *Work) void {
        self.plan.decodeBinary(self.pixels, self.stride, self.cancel) catch |err| {
            self.failure = err;
        };
    }
};
fn scale(comptime T: type, value: u32, maximum: u16) Failure!T {
    if (value > maximum) return error.DecodeFailed;
    return @intCast((value * std.math.maxInt(T) + maximum / 2) / maximum);
}
fn cancelled(cancel: ?*const std.atomic.Value(bool)) Failure!void {
    if (cancel) |value| if (value.load(.acquire)) return error.Cancelled;
}
fn align64(value: usize) Failure!usize {
    return (std.math.add(usize, value, 63) catch return error.SizeOverflow) & ~@as(usize, 63);
}

test "all Netpbm encodings preserve every pixel, padding and one owned slab" {
    inline for (.{ "p1.pbm", "p4.pbm", "p2-8.pgm", "p2-16.pgm", "p5-8.pgm", "p5-16.pgm", "p5-10.pgm", "p3-8.ppm", "p3-16.ppm", "p6-8.ppm", "p6-16.ppm" }) |name| {
        const plan = (try Plan.open("tests/fixtures/pnm-" ++ name, null)).?;
        defer plan.deinit();
        inline for (.{ .contiguous, .cache_line }) |alignment| {
            var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const image = try plan.decode(allocator.allocator(), .{ .row_alignment = alignment, .prefix_bytes = 17 });
            try std.testing.expectEqual(@as(u32, 3), image.width);
            try std.testing.expectEqual(@as(u32, 2), image.height);
            const rgb = [_][3]u16{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 255, 255, 255 }, .{ 0, 0, 0 }, .{ 255, 255, 0 } };
            const gray8 = [_]u16{ 0, 64, 127, 128, 200, 255 };
            const gray16 = [_]u16{ 0, 1, 0x1234, 0x8001, 0xabcd, 65535 };
            const gray10 = [_]u16{ 0, 64, 32735, 32800, 65471, 65535 };
            for (0..6) |index| {
                var expected: [4]u16 = undefined;
                if (plan.kind == .rgb or plan.kind == .rgb_ascii) {
                    for (0..3) |channel| expected[channel] = rgb[index][channel] * @as(u16, if (image.bits_per_component == 16) 257 else 1);
                    if (index == 0 and image.bits_per_component == 16) expected[0..3].* = .{ 0x1234, 0xabcd, 0xff };
                } else {
                    const value = if (plan.kind == .bitmap or plan.kind == .bitmap_ascii) @as(u16, if (index % 2 == 0) 0 else 255) else if (plan.maximum == 1023) gray10[index] else if (image.bits_per_component == 16) gray16[index] else gray8[index];
                    @memset(expected[0..3], value);
                }
                expected[3] = if (image.bits_per_component == 16) 65535 else 255;
                const offset = index / 3 * image.row_bytes + index % 3 * 4 * (image.bits_per_component / 8);
                for (expected, 0..) |value, channel| {
                    const actual: u16 = if (image.bits_per_component == 16) std.mem.readInt(u16, image.pixels[offset + channel * 2 ..][0..2], @import("builtin").cpu.arch.endian()) else image.pixels[offset + channel];
                    try std.testing.expectEqual(value, actual);
                }
            }
            for (0..image.height) |y| for (image.pixels[y * image.row_bytes + @as(usize, image.width) * 4 * (image.bits_per_component / 8) ..][0 .. image.row_bytes - @as(usize, image.width) * 4 * (image.bits_per_component / 8)]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            image.deinit();
            try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
            try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
        }
    }
}

test "binary raster bytes keep whitespace and comment markers as pixel samples" {
    inline for (.{ "whitespace", "crlf" }) |name| {
        const plan = (try Plan.open("tests/fixtures/pnm-binary-" ++ name ++ ".ppm", null)).?;
        defer plan.deinit();
        const image = try plan.decode(std.testing.allocator, .{});
        defer image.deinit();
        try std.testing.expectEqualSlices(u8, if (std.mem.eql(u8, name, "whitespace")) &.{ 35, 32, 10, 255 } else &.{ 10, 32, 35, 255 }, image.pixels[0..4]);
    }
}

test "Netpbm rejects incomplete payloads, overflowing numbers and invalid samples" {
    inline for (.{ "truncated.ppm", "invalid-range.pgm", "invalid-number.ppm" }) |name| {
        if (Plan.open("tests/fixtures/pnm-" ++ name, null)) |maybe| {
            if (maybe) |plan| plan.deinit();
            return error.AcceptedInvalidHeader;
        } else |_| {}
    }
    const plan = (try Plan.open("tests/fixtures/pnm-invalid-sample.ppm", null)).?;
    defer plan.deinit();
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try std.testing.expectError(error.DecodeFailed, plan.decode(allocator.allocator(), .{}));
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    var stop: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, plan.decode(allocator.allocator(), .{ .cancel = &stop }));
}

test "binary expansion preserves overlapping input at chunk and row boundaries" {
    inline for (.{ u8, u16 }) |T| inline for (.{ 1, 3 }) |channels| {
        for ([_]u32{ 1, 2, 7, 8, 9, 15, 16, 17 }) |width| {
            inline for (.{ .contiguous, .cache_line }) |alignment| {
                const plan: Plan = .{ .file = .{ .fd = -1, .stamp = .{} }, .extent = try Extent.init(width, 3), .kind = if (channels == 3) .rgb else .gray, .maximum = std.math.maxInt(T), .offset = 0, .input_bytes = @as(usize, width) * 3 * channels * @sizeOf(T) };
                const layout_info = try plan.layout(.{ .row_alignment = alignment });
                var slab: [768]u8 align(64) = undefined;
                const pixels = slab[0..layout_info.pixels];
                const input = pixels[pixels.len - plan.input_bytes ..];
                for (0..plan.input_bytes / @sizeOf(T)) |i| std.mem.writeInt(T, input[i * @sizeOf(T) ..][0..@sizeOf(T)], @truncate(i * 7919 + 37), .big);
                try plan.binarySamples(T, channels, false, input, pixels, layout_info.row, null);
                for (0..3) |y| {
                    const row = pixels[y * layout_info.row ..][0..layout_info.row];
                    for (0..width) |x| for (0..4) |channel| {
                        const expected: T = if (channel == 3) std.math.maxInt(T) else @truncate(((y * width + x) * channels + if (channels == 1) @as(usize, 0) else channel) * 7919 + 37);
                        const actual = std.mem.readInt(T, row[(x * 4 + channel) * @sizeOf(T) ..][0..@sizeOf(T)], @import("builtin").cpu.arch.endian());
                        try std.testing.expectEqual(expected, actual);
                    };
                    for (row[@as(usize, width) * 4 * @sizeOf(T) ..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
                }
            }
        }
    };
}

test "joined PNM workers preserve every row and one-allocation ownership" {
    const c = @import("system");
    var path: ["/tmp/yekk-pnm-XXXXXX".len:0]u8 = "/tmp/yekk-pnm-XXXXXX".*;
    const fd = c.mkstemp(&path);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    defer _ = c.unlink(&path);
    const header = "P6\n4097 2048\n255\n";
    try std.testing.expectEqual(@as(isize, header.len), c.write(fd, header.ptr, header.len));
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, header.len + 4097 * 2048 * 3));
    for (0..2048) |y| {
        const rgb: [3]u8 = .{ @truncate(y), @truncate(y >> 3), 37 };
        try std.testing.expectEqual(@as(isize, 3), c.pwrite(fd, &rgb, 3, @intCast(header.len + y * 4097 * 3)));
    }
    const plan = (try Plan.open(std.mem.span(@as([*:0]const u8, &path)), null)).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 7), plan.workerCount(7));
    const serial = try plan.decode(std.testing.allocator, .{});
    defer serial.deinit();
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const parallel = try plan.decode(allocator.allocator(), .{ .workers = 7 });
    try std.testing.expectEqualSlices(u8, serial.pixels, parallel.pixels);
    parallel.deinit();
    try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}
