//! PNG container, filters, sample expansion and Adam7 in Zig. libdeflate owns
//! only zlib decompression. Pixels, ICC data and temporary bytes share one slab.
const std = @import("std");
const c = @import("png_bindings");
const source = @import("source");
const Extent = @import("raster").Extent;
pub const Decoded = @import("pixel_storage").Decoded;
pub const Failure = source.Error || error{ OutOfMemory, Cancelled, SourceChanged };
pub const Options = struct {
    order: @import("pixel_storage").Order = .rgba,
    prefix_bytes: usize = 0,
    row_alignment: usize = 1,
    raw_retirement: bool = false,
    cancel: ?*const std.atomic.Value(bool) = null,
};
const Kind = enum(u8) { gray = 0, rgb = 2, palette = 3, gray_alpha = 4, rgba = 6 };
const Header = struct {
    extent: Extent,
    depth: u8,
    kind: Kind,
    interlace: bool,
    fn channels(self: Header) usize {
        return switch (self.kind) {
            .gray, .palette => 1,
            .rgb => 3,
            .gray_alpha => 2,
            .rgba => 4,
        };
    }
    fn rowBytes(self: Header, width: usize) Failure!usize {
        return (try add(try mul(width, self.channels() * self.depth), 7)) / 8;
    }
};
const Profile = struct { compressed: source.Range, bytes: usize, gray: bool };
const Pass = struct { x: usize, y: usize, dx: usize, dy: usize };
const adam7 = [_]Pass{
    .{ .x = 0, .y = 0, .dx = 8, .dy = 8 }, .{ .x = 4, .y = 0, .dx = 8, .dy = 8 },
    .{ .x = 0, .y = 4, .dx = 4, .dy = 8 }, .{ .x = 2, .y = 0, .dx = 4, .dy = 4 },
    .{ .x = 0, .y = 2, .dx = 2, .dy = 4 }, .{ .x = 1, .y = 0, .dx = 2, .dy = 2 },
    .{ .x = 0, .y = 1, .dx = 1, .dy = 2 },
};
const whole: Pass = .{ .x = 0, .y = 0, .dx = 1, .dy = 1 };
fn span(size: usize, start: usize, step: usize) usize {
    return if (size <= start) 0 else (size - start + step - 1) / step;
}
const Chunk = struct {
    kind: [4]u8,
    payload: source.Range,
    end: u64,
    fn read(file: source.Open, at: u64) Failure!Chunk {
        const size: u64 = @intCast(file.stamp.bytes);
        if (at > size or size - at < 12) return error.IncompleteImage;
        var bytes: [8]u8 = undefined;
        try readExact(file, &bytes, at);
        const length = std.mem.readInt(u32, bytes[0..4], .big);
        if (length > 0x7fffffff or length > size - at - 12) return error.DecodeFailed;
        for (bytes[4..8]) |letter| if (!std.ascii.isAlphabetic(letter)) return error.DecodeFailed;
        return .{ .kind = bytes[4..8].*, .payload = .{ .file = file, .offset = at + 8, .length = length }, .end = at + 12 + length };
    }
    fn is(self: Chunk, kind: *const [4]u8) bool {
        return std.mem.eql(u8, &self.kind, kind);
    }
    fn body(self: Chunk, output: []u8) Failure!void {
        if (output.len != self.payload.length) return error.DecodeFailed;
        try readExact(self.payload.file, output, self.payload.offset);
        try self.crc(output);
    }
    fn crc(self: Chunk, data: []const u8) Failure!void {
        const initial = c.libdeflate_crc32(0, &self.kind, 4);
        try self.checkCrc(c.libdeflate_crc32(initial, data.ptr, data.len));
    }
    fn checkCrc(self: Chunk, actual: u32) Failure!void {
        var expected: [4]u8 = undefined;
        try readExact(self.payload.file, &expected, self.end - 4);
        if (std.mem.readInt(u32, &expected, .big) != actual) return error.DecodeFailed;
    }
};
pub const Plan = struct {
    file: source.Open,
    header: Header,
    orientation: source.Orientation = .identity,
    exif: ?source.Range = null,
    palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 }),
    palette_len: usize = 0,
    transparent: ?[3]u16 = null,
    profile: ?Profile = null,
    compressed_bytes: usize = 0,
    native_color: bool = false,
    animated: bool = false,

    pub fn read(file: source.Open, cancel: ?*const std.atomic.Value(bool)) Failure!Plan {
        var signature: [8]u8 = undefined;
        try readExact(file, &signature, 0);
        if (!std.mem.eql(u8, &signature, "\x89PNG\r\n\x1a\n")) return error.DecodeFailed;
        const first = try Chunk.read(file, 8);
        if (!first.is("IHDR")) return error.DecodeFailed;
        var ihdr: [13]u8 = undefined;
        try first.body(&ihdr);
        const width = std.mem.readInt(u32, ihdr[0..4], .big);
        const height = std.mem.readInt(u32, ihdr[4..8], .big);
        if (width > 0x7fffffff or height > 0x7fffffff) return error.InvalidDimensions;
        const kind: Kind = switch (ihdr[9]) {
            inline 0, 2, 3, 4, 6 => |value| @fromBackingInt(value),
            else => return error.DecodeFailed,
        };
        const depth = ihdr[8];
        switch (kind) {
            .gray => if (depth != 1 and depth != 2 and depth != 4 and depth != 8 and depth != 16) return error.DecodeFailed,
            .palette => if (depth != 1 and depth != 2 and depth != 4 and depth != 8) return error.DecodeFailed,
            else => if (depth != 8 and depth != 16) return error.DecodeFailed,
        }
        if (ihdr[10] != 0 or ihdr[11] != 0 or ihdr[12] > 1) return error.DecodeFailed;
        const dimensions = try Extent.init(width, height);
        _ = try dimensions.bytes(4, if (depth == 16) 2 else 1);
        var plan: Plan = .{ .file = file, .header = .{ .extent = dimensions, .depth = depth, .kind = kind, .interlace = ihdr[12] != 0 } };
        var at = first.end;
        var data: enum { before, inside, after } = .before;
        var saw_trns = false;
        var saw_gamma = false;
        var saw_chrm = false;
        var srgb = false;
        while (true) {
            try cancelled(cancel);
            const chunk = try Chunk.read(file, at);
            const before = data == .before;
            if (chunk.is("IDAT")) {
                if (data == .after or (kind == .palette and plan.palette_len == 0)) return error.DecodeFailed;
                data = .inside;
                plan.compressed_bytes = try add(plan.compressed_bytes, chunk.payload.length);
            } else {
                if (data == .inside) data = .after;
                if (chunk.is("IEND")) {
                    if (before or plan.compressed_bytes == 0 or chunk.payload.length != 0 or chunk.end != @as(u64, @intCast(file.stamp.bytes))) return error.IncompleteImage;
                    try chunk.body(&.{});
                    plan.native_color = plan.native_color or ((saw_gamma or saw_chrm) and !srgb and plan.profile == null);
                    if (!file.unchanged()) return error.SourceChanged;
                    return plan;
                } else if (chunk.is("PLTE")) {
                    if (!before or saw_trns or plan.palette_len != 0 or kind == .gray or kind == .gray_alpha or chunk.payload.length == 0 or chunk.payload.length > 768 or chunk.payload.length % 3 != 0) return error.DecodeFailed;
                    plan.palette_len = chunk.payload.length / 3;
                    if (kind == .palette and plan.palette_len > @as(usize, 1) << @intCast(depth)) return error.DecodeFailed;
                    var palette: [768]u8 = undefined;
                    try chunk.body(palette[0..chunk.payload.length]);
                    for (0..plan.palette_len) |i| @memcpy(plan.palette[i][0..3], palette[i * 3 ..][0..3]);
                } else if (chunk.is("tRNS")) {
                    if (!before or saw_trns) return error.DecodeFailed;
                    saw_trns = true;
                    switch (kind) {
                        .palette => {
                            if (plan.palette_len == 0 or chunk.payload.length == 0 or chunk.payload.length > plan.palette_len) return error.DecodeFailed;
                            var alpha: [256]u8 = undefined;
                            try chunk.body(alpha[0..chunk.payload.length]);
                            for (0..chunk.payload.length) |i| plan.palette[i][3] = alpha[i];
                        },
                        .gray, .rgb => {
                            var value: [6]u8 = @splat(0);
                            try chunk.body(value[0..if (kind == .gray) @as(usize, 2) else 6]);
                            var samples: [3]u16 = undefined;
                            for (&samples, 0..) |*sample, i| {
                                sample.* = std.mem.readInt(u16, value[i * 2 ..][0..2], .big);
                                if (sample.* > (@as(u32, 1) << @intCast(depth)) - 1) return error.DecodeFailed;
                            }
                            plan.transparent = samples;
                        },
                        else => return error.DecodeFailed,
                    }
                } else if (chunk.is("iCCP")) {
                    if (!before or plan.profile != null or plan.palette_len != 0) return error.DecodeFailed;
                    plan.native_color = plan.native_color or srgb;
                    plan.profile = try readProfile(chunk.payload, cancel);
                    const gray = kind == .gray or kind == .gray_alpha;
                    if (plan.profile.?.gray != gray) return error.DecodeFailed;
                } else if (chunk.is("eXIf")) {
                    if (!before or plan.exif != null) return error.DecodeFailed;
                    plan.exif = chunk.payload;
                    plan.orientation = try source.exifOrientation(chunk.payload);
                } else if (chunk.is("sRGB")) {
                    if (!before or srgb or plan.palette_len != 0) return error.DecodeFailed;
                    plan.native_color = plan.native_color or plan.profile != null;
                    var intent: [1]u8 = undefined;
                    try chunk.body(&intent);
                    if (intent[0] > 3) return error.DecodeFailed;
                    srgb = true;
                } else if (chunk.is("gAMA")) {
                    if (!before or saw_gamma or plan.palette_len != 0) return error.DecodeFailed;
                    var gamma: [4]u8 = undefined;
                    try chunk.body(&gamma);
                    if (std.mem.readInt(u32, &gamma, .big) == 0) return error.DecodeFailed;
                    saw_gamma = true;
                } else if (chunk.is("cHRM")) {
                    if (!before or saw_chrm or plan.palette_len != 0) return error.DecodeFailed;
                    var chromaticities: [32]u8 = undefined;
                    try chunk.body(&chromaticities);
                    saw_chrm = true;
                } else if (chunk.is("acTL") or chunk.is("fcTL") or chunk.is("fdAT")) {
                    plan.animated = true;
                } else if (chunk.is("cICP") or chunk.is("mDCV") or chunk.is("cLLI")) {
                    // Preserve native handling of color encodings outside the
                    // SDR ICC/sRGB contract. These do not enable HDR support.
                    plan.native_color = true;
                } else if (std.ascii.isUpper(chunk.kind[0])) return error.DecodeFailed;
            }
            at = chunk.end;
        }
    }
    pub fn extent(self: Plan) Extent {
        return if (self.orientation.swapsAxes()) .{ .width = self.header.extent.height, .height = self.header.extent.width } else self.header.extent;
    }
    pub fn opaqueSource(self: Plan) bool {
        if (self.header.kind == .gray_alpha or self.header.kind == .rgba or self.transparent != null) return false;
        if (self.header.kind == .palette) for (self.palette[0..self.palette_len]) |entry| if (entry[3] != 255) return false;
        return true;
    }
    fn rawBytes(self: Plan) Failure!usize {
        var total: usize = 0;
        const passes = if (self.header.interlace) &adam7 else &[_]Pass{whole};
        for (passes) |pass| {
            const width = span(self.header.extent.width, pass.x, pass.dx);
            const height = span(self.header.extent.height, pass.y, pass.dy);
            if (width != 0 and height != 0) total = try add(total, try mul(try add(try self.header.rowBytes(width), 1), height));
        }
        return total;
    }
    const Layout = struct { prefix: usize, row: usize, end: usize, profile_end: usize, compressed_end: usize, total: usize };
    fn layout(self: Plan, options: Options) Failure!Layout {
        if (options.row_alignment == 0 or !std.math.isPowerOfTwo(options.row_alignment)) return error.SizeOverflow;
        const size = self.extent();
        const prefix = try alignTo(options.prefix_bytes, 64);
        const row = try alignTo(try mul(size.width, if (self.header.depth == 16) 8 else 4), options.row_alignment);
        const end = try add(prefix, try mul(row, size.height));
        const profile_end = try add(end, if (self.profile) |p| p.bytes else 0);
        const compressed_end = try add(profile_end, @max(self.compressed_bytes, if (self.profile) |p| p.compressed.length else 0));
        return .{ .prefix = prefix, .row = row, .end = end, .profile_end = profile_end, .compressed_end = compressed_end, .total = try add(compressed_end, try self.rawBytes()) };
    }
    pub fn storageBytes(self: Plan, options: Options) Failure!usize {
        return (try self.layout(options)).total;
    }
    pub fn decode(self: Plan, allocator: std.mem.Allocator, options: Options) Failure!Decoded {
        try cancelled(options.cancel);
        const storage = try self.layout(options);
        const pointer = allocator.rawAlloc(storage.total, .fromByteUnits(64), @returnAddress()) orelse return error.OutOfMemory;
        const slab = @as([*]align(64) u8, @alignCast(pointer))[0..storage.total];
        const decoded: Decoded = .{ .order = options.order, .allocator = allocator, .slab = slab, .pixels = slab[storage.prefix..storage.end], .profile = slab[storage.end..storage.profile_end], .width = self.extent().width, .height = self.extent().height, .row_bytes = storage.row, .bits_per_component = if (self.header.depth == 16) 16 else 8, .raw_retirement = options.raw_retirement };
        errdefer decoded.deinit();
        const decompressor = c.libdeflate_alloc_decompressor() orelse return error.OutOfMemory;
        defer c.libdeflate_free_decompressor(decompressor);
        const compressed = slab[storage.profile_end..storage.compressed_end];
        const raw = slab[storage.compressed_end..];
        if (self.profile) |profile| {
            const input = compressed[0..profile.compressed.length];
            try readExact(self.file, input, profile.compressed.offset);
            try inflate(decompressor, input, slab[storage.end..storage.profile_end]);
            const bytes = decoded.profile;
            if (bytes.len < 132 or std.mem.readInt(u32, bytes[0..4], .big) != bytes.len or !std.mem.eql(u8, bytes[36..40], "acsp") or !std.mem.eql(u8, bytes[16..20], if (profile.gray) "GRAY" else "RGB ")) return error.DecodeFailed;
        }
        try self.collect(compressed[0..self.compressed_bytes], options.cancel);
        try cancelled(options.cancel);
        try inflate(decompressor, compressed[0..self.compressed_bytes], raw);
        try cancelled(options.cancel);
        if (self.header.depth == 16) try self.restore(u16, raw, decoded, options.cancel) else try self.restore(u8, raw, decoded, options.cancel);
        const row_pixels = @as(usize, decoded.width) * 4 * (decoded.bits_per_component / 8);
        if (row_pixels < decoded.row_bytes) for (0..decoded.height) |y| @memset(decoded.pixels[y * decoded.row_bytes + row_pixels ..][0 .. decoded.row_bytes - row_pixels], 0);
        if (!self.file.unchanged()) return error.SourceChanged;
        return decoded;
    }
    fn collect(self: Plan, output: []u8, cancel: ?*const std.atomic.Value(bool)) Failure!void {
        var at: u64 = 8;
        var written: usize = 0;
        var scratch: [64 * 1024]u8 = undefined;
        while (at < @as(u64, @intCast(self.file.stamp.bytes))) {
            const chunk = try Chunk.read(self.file, at);
            const idat = chunk.is("IDAT");
            if (idat and chunk.payload.length > output.len - written) return error.SourceChanged;
            var crc = c.libdeflate_crc32(0, &chunk.kind, 4);
            var offset: usize = 0;
            while (offset < chunk.payload.length) {
                try cancelled(cancel);
                const count = @min(scratch.len, chunk.payload.length - offset);
                const buffer = if (idat) output[written..][offset..][0..count] else scratch[0..count];
                try readExact(self.file, buffer, chunk.payload.offset + offset);
                crc = c.libdeflate_crc32(crc, buffer.ptr, buffer.len);
                offset += count;
            }
            try chunk.checkCrc(crc);
            if (idat) written += chunk.payload.length;
            at = chunk.end;
        }
        if (written != output.len) return error.SourceChanged;
    }
    fn restore(self: Plan, comptime Sample: type, raw: []u8, decoded: Decoded, cancel: ?*const std.atomic.Value(bool)) Failure!void {
        const passes = if (self.header.interlace) &adam7 else &[_]Pass{whole};
        var at: usize = 0;
        for (passes) |pass| {
            const width = span(self.header.extent.width, pass.x, pass.dx);
            const height = span(self.header.extent.height, pass.y, pass.dy);
            if (width == 0 or height == 0) continue;
            const row_bytes = try self.header.rowBytes(width);
            const bpp = @max(1, (self.header.channels() * self.header.depth + 7) / 8);
            var prior: ?[]const u8 = null;
            for (0..height) |y| {
                try cancelled(cancel);
                const filter = raw[at];
                const row = raw[at + 1 ..][0..row_bytes];
                switch (bpp) {
                    inline 1, 2, 3, 4, 6, 8 => |stride| switch (filter) {
                        inline 0, 1, 2, 3, 4 => |f| unfilter(stride, f, row, prior),
                        else => return error.DecodeFailed,
                    },
                    else => unreachable,
                }
                self.expand(Sample, row, width, pass, y, decoded) catch return error.DecodeFailed;
                prior = row;
                at += row_bytes + 1;
            }
        }
        std.debug.assert(at == raw.len);
    }
    fn expand(self: Plan, comptime Sample: type, row: []const u8, width: usize, pass: Pass, y: usize, decoded: Decoded) Failure!void {
        if (Sample == u8 and self.orientation == .identity and pass.dx == 1 and self.transparent == null) {
            const output = decoded.pixels[(pass.y + y * pass.dy) * decoded.row_bytes ..][0 .. width * 4];
            if (self.header.kind == .rgba and decoded.order == .rgba) {
                @memcpy(output, row);
                return;
            }
            if (self.header.kind == .rgb) {
                switch (decoded.order) {
                    .rgba => for (0..width) |x| {
                        @memcpy(output[x * 4 ..][0..3], row[x * 3 ..][0..3]);
                        output[x * 4 + 3] = 255;
                    },
                    .argb => for (0..width) |x| {
                        output[x * 4] = 255;
                        @memcpy(output[x * 4 + 1 ..][0..3], row[x * 3 ..][0..3]);
                    },
                }
                return;
            }
        }
        const channels = self.header.channels();
        const max: u16 = if (Sample == u16) 65535 else 255;
        for (0..width) |x| {
            var rgba: [4]Sample = undefined;
            var values: [4]u16 = @splat(0);
            if (self.header.depth < 8) {
                const bit = x * self.header.depth;
                const shift: u3 = @intCast(8 - self.header.depth - bit % 8);
                values[0] = (row[bit / 8] >> shift) & ((@as(u16, 1) << @intCast(self.header.depth)) - 1);
            } else for (0..channels) |ch| {
                const offset = (x * channels + ch) * @sizeOf(Sample);
                values[ch] = if (Sample == u16) std.mem.readInt(u16, row[offset..][0..2], .big) else row[offset];
            }
            switch (self.header.kind) {
                .palette => {
                    if (values[0] >= self.palette_len) return error.DecodeFailed;
                    for (&rgba, self.palette[values[0]]) |*out, sample| out.* = sample;
                },
                .gray, .gray_alpha => {
                    const gray: Sample = @intCast(if (self.header.depth < 8) @as(u32, values[0]) * 255 / ((@as(u32, 1) << @intCast(self.header.depth)) - 1) else values[0]);
                    rgba = .{ gray, gray, gray, if (self.header.kind == .gray_alpha) @intCast(values[1]) else if (self.transparent != null and values[0] == self.transparent.?[0]) 0 else max };
                },
                .rgb, .rgba => rgba = .{ @intCast(values[0]), @intCast(values[1]), @intCast(values[2]), if (self.header.kind == .rgba) @intCast(values[3]) else if (self.transparent != null and std.mem.eql(u16, values[0..3], &self.transparent.?)) 0 else max },
            }
            const sx = pass.x + x * pass.dx;
            const sy = pass.y + y * pass.dy;
            const w = self.header.extent.width;
            const h = self.header.extent.height;
            const point = self.orientation.point(w, h, sx, sy);
            const output: *[4]Sample = @ptrCast(@alignCast(decoded.pixels[point.y * decoded.row_bytes + point.x * 4 * @sizeOf(Sample) ..].ptr));
            output.* = switch (decoded.order) {
                .rgba => rgba,
                .argb => .{ rgba[3], rgba[0], rgba[1], rgba[2] },
            };
        }
    }
};
fn readProfile(range: source.Range, cancel: ?*const std.atomic.Value(bool)) Failure!Profile {
    var prefix: [82]u8 = undefined;
    const count = try range.readAt(&prefix, 0);
    const end = std.mem.indexOfScalar(u8, prefix[0..count], 0) orelse return error.DecodeFailed;
    if (end == 0 or end > 79 or end + 2 >= count or prefix[end + 1] != 0) return error.DecodeFailed;
    for (prefix[0..end], 0..) |value, i| {
        if (value < 32 or (value > 126 and value < 161) or (value == 32 and (i == 0 or i + 1 == end or prefix[i - 1] == 32))) return error.DecodeFailed;
    }
    const compressed: source.Range = .{ .file = range.file, .offset = range.offset + end + 2, .length = range.length - end - 2 };
    // ICC declares its complete size in the first four inflated bytes. Read
    // only its fixed header before planning the sole application allocation.
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    if (c.inflateInit_(&stream, c.ZLIB_VERSION, @sizeOf(c.z_stream)) != c.Z_OK) return error.OutOfMemory;
    defer _ = c.inflateEnd(&stream);
    var header: [128]u8 = undefined;
    stream.next_out = &header;
    stream.avail_out = header.len;
    var input: [4096]u8 = undefined;
    var position: usize = 0;
    while (stream.avail_out != 0) {
        try cancelled(cancel);
        if (stream.avail_in == 0) {
            const read = try compressed.readAt(&input, position);
            if (read == 0) return error.IncompleteImage;
            stream.next_in = &input;
            stream.avail_in = @intCast(read);
            position += read;
        }
        const previous = stream.total_out;
        const status = c.inflate(&stream, c.Z_NO_FLUSH);
        if (status != c.Z_OK or (stream.total_out == previous and stream.avail_in != 0)) return error.DecodeFailed;
    }
    const size = std.mem.readInt(u32, header[0..4], .big);
    if (size < 132 or !std.mem.eql(u8, header[36..40], "acsp")) return error.DecodeFailed;
    const gray = std.mem.eql(u8, header[16..20], "GRAY");
    if (!gray and !std.mem.eql(u8, header[16..20], "RGB ")) return error.DecodeFailed;
    return .{ .compressed = compressed, .bytes = size, .gray = gray };
}
fn inflate(decoder: *c.libdeflate_decompressor, input: []const u8, output: []u8) Failure!void {
    var consumed: usize = 0;
    var actual: usize = 0;
    if (c.libdeflate_zlib_decompress_ex(decoder, input.ptr, input.len, output.ptr, output.len, &consumed, &actual) != c.LIBDEFLATE_SUCCESS or consumed != input.len or actual != output.len) return error.DecodeFailed;
}
fn cancelled(flag: ?*const std.atomic.Value(bool)) Failure!void {
    if (flag) |value| if (value.load(.acquire)) return error.Cancelled;
}
fn readExact(file: source.Open, output: []u8, offset: u64) Failure!void {
    var read: usize = 0;
    while (read < output.len) {
        const count = try file.readAt(output[read..], offset + read);
        if (count == 0) return error.IncompleteImage;
        read += count;
    }
}
fn add(a: usize, b: usize) Failure!usize {
    const value = std.math.add(usize, a, b) catch return error.SizeOverflow;
    return if (value > std.math.maxInt(isize)) error.SizeOverflow else value;
}
fn mul(a: usize, b: usize) Failure!usize {
    const value = std.math.mul(usize, a, b) catch return error.SizeOverflow;
    return if (value > std.math.maxInt(isize)) error.SizeOverflow else value;
}
fn alignTo(value: usize, alignment: usize) Failure!usize {
    return (try add(value, alignment - 1)) & ~(alignment - 1);
}
fn unfilter(comptime stride: usize, comptime filter: u8, row: []u8, prior: ?[]const u8) void {
    if (filter == 0) return;
    for (row, 0..) |*value, x| {
        const left: u8 = if (x >= stride) row[x - stride] else 0;
        const up: u8 = if (prior) |p| p[x] else 0;
        const upper_left: u8 = if (prior != null and x >= stride) prior.?[x - stride] else 0;
        const predicted = switch (filter) {
            1 => left,
            2 => up,
            3 => @as(u8, @intCast((@as(u16, left) + up) / 2)),
            4 => paeth(left, up, upper_left),
            else => unreachable,
        };
        value.* +%= predicted;
    }
}
fn paeth(a: u8, b: u8, upper_left: u8) u8 {
    const p = @as(i16, a) + b - upper_left;
    const da = @abs(p - a);
    const db = @abs(p - b);
    const dc = @abs(p - upper_left);
    return if (da <= db and da <= dc) a else if (db <= dc) b else upper_left;
}

test "PNG preserves every integer layout, Adam7 pass, row filter and transparency value in one slab" {
    inline for (.{ .{ 0, 1 }, .{ 0, 2 }, .{ 0, 4 }, .{ 0, 8 }, .{ 0, 16 }, .{ 2, 8 }, .{ 2, 16 }, .{ 3, 1 }, .{ 3, 2 }, .{ 3, 4 }, .{ 3, 8 }, .{ 4, 8 }, .{ 4, 16 }, .{ 6, 8 }, .{ 6, 16 } }) |format| {
        const kind = format[0];
        const depth = format[1];
        for (0..2) |interlace| for (0..if (kind == 0 or kind == 2) @as(usize, 2) else 1) |trns| {
            var name: [128]u8 = undefined;
            const path = try std.fmt.bufPrintSentinel(&name, "tests/fixtures/png-{d}-{d}-{d}{s}.png", .{ kind, depth, interlace, @as([]const u8, if (trns == 1) "-trns" else "") }, 0);
            const file = try source.open(path, false);
            defer file.close();
            const plan = try Plan.read(file, null);
            var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const decoded = try plan.decode(counted.allocator(), .{ .prefix_bytes = 67, .row_alignment = 64 });
            defer decoded.deinit();
            try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
            try std.testing.expectEqual(@as(usize, 0), @intFromPtr(decoded.pixels.ptr) % 64);
            const max: u32 = (@as(u32, 1) << depth) - 1;
            for (0..19) |y| for (0..17) |x| {
                var values: [4]u32 = undefined;
                for (&values, 0..) |*value, ch| value.* = @intCast((x * 257 + y * 911 + ch * 1237 + 37) & max);
                const first = if (kind == 3) [_]u32{ (values[0] * 37 + 5) & 255, (values[0] * 67 + 11) & 255, (values[0] * 97 + 17) & 255 } else if (kind == 0 or kind == 4) @as([3]u32, @splat(values[0] * (if (depth < 8) @as(u32, 255) else max) / max)) else values[0..3].*;
                const transparent = if (kind == 0) values[0] == (37 & max) else values[0] == (37 & max) and values[1] == ((1237 + 37) & max) and values[2] == ((2474 + 37) & max);
                const alpha: u32 = if (kind == 3) (values[0] * 53) & 255 else if (kind == 4) values[1] else if (kind == 6) values[3] else if (trns == 1 and transparent) 0 else if (depth < 8) 255 else max;
                const expected = [_]u32{ first[0], first[1], first[2], alpha };
                const at = y * decoded.row_bytes + x * (if (depth == 16) @as(usize, 8) else 4);
                for (expected, 0..) |sample, ch| {
                    const actual = if (depth == 16) @as([*]const u16, @ptrCast(@alignCast(decoded.pixels[at..].ptr)))[ch] else decoded.pixels[at + ch];
                    try std.testing.expectEqual(sample, actual);
                }
            };
        };
    }
}
test "PNG Exif orientation stays within its chunk in both byte orders" {
    for (1..9) |orientation| inline for (.{ "le", "be" }) |endian| {
        var name: [128]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&name, "tests/fixtures/png-orientation{d}-{s}.png", .{ orientation, endian }, 0);
        const file = try source.open(path, false);
        defer file.close();
        const plan = try Plan.read(file, null);
        const decoded = try plan.decode(std.testing.allocator, .{});
        defer decoded.deinit();
        const maps = [_][6]usize{ .{ 0, 1, 2, 3, 4, 5 }, .{ 2, 1, 0, 5, 4, 3 }, .{ 5, 4, 3, 2, 1, 0 }, .{ 3, 4, 5, 0, 1, 2 }, .{ 0, 3, 1, 4, 2, 5 }, .{ 3, 0, 4, 1, 5, 2 }, .{ 5, 2, 4, 1, 3, 0 }, .{ 2, 5, 1, 4, 0, 3 } };
        for (maps[orientation - 1], 0..) |src, dst| for (0..3) |ch| {
            try std.testing.expectEqual(@as(u8, @truncate((src % 3) * 257 + (src / 3) * 911 + ch * 1237 + 37)), decoded.pixels[dst * 4 + ch]);
        };
    };
}
test "PNG cancellation and allocation failure release all ownership" {
    const file = try source.open("tests/fixtures/png-adam7-tiny.png", false);
    defer file.close();
    const plan = try Plan.read(file, null);
    const decoded = try plan.decode(std.testing.allocator, .{});
    decoded.deinit();
    var failed = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, plan.decode(failed.allocator(), .{}));
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, plan.decode(std.testing.allocator, .{ .cancel = &cancel }));
}
test "PNG profiles retain their complete RGB and gray data in the pixel slab" {
    inline for (.{ "srgb", "gray" }) |name| {
        const file = try source.open("tests/fixtures/png-profile-" ++ name ++ ".png", false);
        defer file.close();
        const plan = try Plan.read(file, null);
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const decoded = try plan.decode(counted.allocator(), .{});
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
        try std.testing.expectEqual(plan.profile.?.bytes, decoded.profile.len);
        try std.testing.expect(std.mem.eql(u8, decoded.profile[16..20], if (comptime std.mem.eql(u8, name, "gray")) "GRAY" else "RGB "));
        decoded.deinit();
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    }
}
