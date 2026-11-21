const std = @import("std");
const decoder = @import("decoder.zig");
const n = @import("platform/native.zig");

test "malformed and missing inputs fail without owning an image" {
    try std.testing.expectError(error.UnreadableImage, decoder.load("/this/file/does/not/exist.png", 1000));
    try std.testing.expectError(error.UnreadableImage, decoder.load("build.zig", 1000));
}

test "BMP metadata and native decoding reject truncated and linked-profile files" {
    inline for (.{ "rgb24", "topdown", "rgb565", "pal8", "pal4", "pal1", "rle8", "rle4" }) |kind| {
        const image = try decoder.load("tests/fixtures/bmp-" ++ kind ++ ".bmp", 0);
        try std.testing.expectEqual(@as(u32, 3), image.width);
        try std.testing.expectEqual(@as(u32, 2), image.height);
        image.destroy();
    }
    inline for (.{ "truncated", "linked-profile" }) |kind| {
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        if (decoder.loadWithAllocator("tests/fixtures/bmp-" ++ kind ++ ".bmp", 0, allocator.allocator())) |image| {
            image.destroy();
            return error.AcceptedInvalidBmp;
        } else |_| {}
        try std.testing.expectEqual(@as(usize, 0), allocator.alloc_index);
    }
}

test "PNM native providers retain the shared decoder's precision and single slab" {
    inline for (.{ "p1.pbm", "p4.pbm", "p2-8.pgm", "p2-16.pgm", "p5-8.pgm", "p5-16.pgm", "p3-8.ppm", "p3-16.ppm", "p6-8.ppm", "p6-16.ppm" }) |name| {
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decoder.loadWithAllocator("tests/fixtures/pnm-" ++ name, 0, allocator.allocator());
        try std.testing.expectEqual(decoder.Backend.pnm, image.backend);
        try std.testing.expectEqual(@as(u32, 3), image.width);
        try std.testing.expectEqual(@as(u32, 2), image.height);
        const bits: usize = if (std.mem.indexOf(u8, name, "16") != null) 16 else 8;
        try std.testing.expectEqual(bits, n.CGImageGetBitsPerComponent(image.native));
        if (bits == 16 and std.mem.endsWith(u8, name, ".ppm")) {
            const samples: *const [4]u16 = @ptrCast(@alignCast(image.ownedPixels().?.ptr));
            try std.testing.expectEqualSlices(u16, &.{ 0x1234, 0xabcd, 0xff, 65535 }, samples);
        }
        image.destroy();
        try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
        try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    }
}

test "contents identify a PNG with an unrelated extension, including alpha" {
    for ([_]u32{ 0, 1000 }) |edge| {
        const image = try decoder.load("tests/fixtures/alpha.content", edge);
        defer image.destroy();
        try std.testing.expectEqual(@as(u32, 3), image.source_width);
        try std.testing.expectEqual(@as(u32, 2), image.source_height);
        try std.testing.expectEqual(@as(u32, 3), image.width);
        try std.testing.expect(image.decoded_bytes >= 3 * 2 * 4);
        var pixels: [24]u8 = @splat(0);
        const space = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB).?;
        defer n.CFRelease(space);
        const context = n.CGBitmapContextCreate(&pixels, 3, 2, 8, 12, space, 0x4001).?; // RGBA premultiplied, byte-order big
        defer n.CFRelease(context);
        n.CGContextDrawImage(context, n.rect(0, 0, 3, 2), image.native);
        var alpha: [6]u8 = undefined;
        for (&alpha, 0..) |*a, i| a.* = pixels[i * 4 + 3];
        std.mem.sort(u8, &alpha, {}, std.sort.asc(u8));
        try std.testing.expectEqualSlices(u8, &.{ 0, 128, 255, 255, 255, 255 }, &alpha);
    }
}

test "shared PNG providers preserve 16-bit pixels, orientation and a single allocation" {
    inline for (.{ "png-2-16-1.png", "png-orientation6-le.png", "png-profile-srgb.png" }) |name| {
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decoder.loadWithAllocator("tests/fixtures/" ++ name, 0, counted.allocator());
        try std.testing.expectEqual(decoder.Backend.png, image.backend);
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
        if (comptime std.mem.indexOf(u8, name, "orientation") != null) {
            try std.testing.expectEqual(@as(u32, 2), image.width);
            try std.testing.expectEqual(@as(u32, 3), image.height);
        } else {
            const first: [*]const u16 = @ptrCast(@alignCast(image.ownedPixels().?.ptr));
            try std.testing.expectEqualSlices(u16, &.{ 37, 1274, 2511 }, first[0..3]);
        }
        image.destroy();
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    }
    const native = try decoder.load("tests/fixtures/png-gamma.png", 0);
    defer native.destroy();
    try std.testing.expectEqual(decoder.Backend.image_io, native.backend);
}

test "shared JPEG providers preserve orientation, color tags and a single allocation" {
    if (!@import("jpeg").fast_huffman_available) return error.SkipZigTest;
    inline for (.{ "jpeg-sequential-orientation1.jpg", "jpeg-sequential-orientation6.jpg", "jpeg-profile-sequential-srgb.jpg" }) |name| {
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decoder.loadWithAllocator("tests/fixtures/" ++ name, 0, counted.allocator());
        defer image.destroy();
        try std.testing.expectEqual(decoder.Backend.jpeg, image.backend);
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
        const file = try @import("source").open("tests/fixtures/" ++ name, true);
        defer file.close();
        const plan = try @import("jpeg").Plan.read(file, null);
        const reference = try plan.decode(std.testing.allocator, .{ .fast_huffman = false });
        defer reference.deinit();
        try std.testing.expectEqual(reference.width, image.width);
        try std.testing.expectEqual(reference.height, image.height);
        const space = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB).?;
        defer n.CFRelease(space);
        var ours: [4096]u8 = @splat(0);
        const count = @as(usize, image.width) * image.height * 4;
        const context = n.CGBitmapContextCreate(&ours, image.width, image.height, 8, @as(usize, image.width) * 4, space, 0x4001).?;
        defer n.CFRelease(context);
        const rect = n.rect(0, 0, @floatFromInt(image.width), @floatFromInt(image.height));
        n.CGContextDrawImage(context, rect, image.native);
        // Compare the displayed pixels with the stock JPEG decoder. ImageIO
        // uses different chroma interpolation, most visibly on tiny images.
        for (ours[0..count], reference.pixels) |a, b| try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 1);
    }
    const gray_profile = try decoder.load("tests/fixtures/jpeg-profile-gray.jpg", 0);
    defer gray_profile.destroy();
    try std.testing.expectEqual(decoder.Backend.image_io, gray_profile.backend);
    const gray = try decoder.load("tests/fixtures/jpeg-gray.jpg", 0);
    defer gray.destroy();
    try std.testing.expectEqual(decoder.Backend.image_io, gray.backend);
}

test "shared PNG samples match ImageIO in an unscaled sRGB bitmap" {
    inline for (.{ "png-0-1-0.png", "png-0-8-0.png", "png-0-16-0-trns.png", "png-2-8-0.png", "png-2-16-0-trns.png", "png-4-16-0.png", "png-6-16-0.png", "png-profile-srgb.png" }) |name| {
        const owned = try decoder.load("tests/fixtures/" ++ name, 0);
        defer owned.destroy();
        const reference = try decoder.load("tests/fixtures/" ++ name, 1000);
        defer reference.destroy();
        const space = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB).?;
        defer n.CFRelease(space);
        var ours: [17 * 19 * 4]u8 = @splat(0);
        var theirs: [17 * 19 * 4]u8 = @splat(0);
        for ([_]struct { native: n.Ref, bytes: []u8 }{ .{ .native = owned.native, .bytes = &ours }, .{ .native = reference.native, .bytes = &theirs } }) |value| {
            const context = n.CGBitmapContextCreate(value.bytes.ptr, 17, 19, 8, 17 * 4, space, 0x4001).?;
            defer n.CFRelease(context);
            n.CGContextDrawImage(context, n.rect(0, 0, 17, 19), value.native);
        }
        var difference: usize = 0;
        for (ours, theirs) |a, b| difference = @max(difference, @abs(@as(i16, a) - b));
        if (difference > 1) std.debug.print("PNG {s}: bitmap difference {d}; source bits {d}/{d}\n", .{ name, difference, owned.bits_per_component, reference.bits_per_component });
        try std.testing.expect(difference <= 1);
    }
}

test "downsampling does not masquerade as full detail" {
    const image = try decoder.load("tests/fixtures/alpha.content", 2);
    defer image.destroy();
    try std.testing.expectEqual(@as(u32, 3), image.source_width);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expect(image.height <= 2);
}

test "16-bit input precision survives native decode" {
    const image = try decoder.load("tests/fixtures/gray16.png", 0);
    defer image.destroy();
    try std.testing.expectEqual(@as(usize, 16), image.bits_per_component);
}

test "oversized dimensions are rejected before pixel decoding" {
    try std.testing.expectError(error.InvalidDimensions, decoder.load("tests/fixtures/huge.png", 1000));
}

test "truncated data never publishes a partial image" {
    if (decoder.load("tests/fixtures/truncated.png", 1000)) |image| {
        image.destroy();
        return error.AcceptedTruncatedImage;
    } else |_| {}
}

test "each successful image load uses exactly one owned allocation and frees it" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const image = try decoder.loadWithAllocator("tests/fixtures/alpha.content", 0, counted.allocator());
    try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
    image.destroy();
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test "incomplete JPEG entropy is rejected before image allocation" {
    inline for (.{ "tests/fixtures/jpeg-incomplete-4.jpg", "tests/fixtures/jpeg-incomplete-64.jpg" }) |file| {
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        try std.testing.expectError(error.IncompleteImage, decoder.loadWithAllocator(file, 0, counted.allocator()));
        try std.testing.expectEqual(@as(usize, 0), counted.alloc_index);
    }
}
test "complete JPEGs retain legal trailers and progressive scans" {
    inline for (.{ "tests/fixtures/jpeg-trailer.jpg", "tests/fixtures/jpeg-progressive.jpg", "tests/fixtures/jpeg-boundary.jpg" }) |file| {
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decoder.loadWithAllocator(file, 0, counted.allocator());
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
        try std.testing.expectEqual(@as(u32, if (std.mem.endsWith(u8, file, "progressive.jpg")) 64 else 2), image.width);
        image.destroy();
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    }
}

test "allocation failure after native decode unwinds without publishing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decoder.loadWithAllocator("tests/fixtures/alpha.content", 0, failing.allocator()));
}

test "JPEG EXIF orientation is applied before dimensions and presentation" {
    const image = try decoder.load("tests/fixtures/orientation6.jpg", 0);
    defer image.destroy();
    try std.testing.expectEqual(@as(u32, 2), image.source_width);
    try std.testing.expectEqual(@as(u32, 3), image.source_height);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 3), image.height);
}

test "libtiff preserves all RGB16 values in both byte orders and all orientations" {
    const source = [_][3]u16{ .{ 65535, 0, 0 }, .{ 0, 65535, 0 }, .{ 0, 0, 65535 }, .{ 65535, 65535, 65535 }, .{ 0, 0, 0 }, .{ 0x1234, 0xabcd, 0x00ff } };
    const maps = [_][6]usize{ .{ 0, 1, 2, 3, 4, 5 }, .{ 2, 1, 0, 5, 4, 3 }, .{ 5, 4, 3, 2, 1, 0 }, .{ 3, 4, 5, 0, 1, 2 }, .{ 0, 3, 1, 4, 2, 5 }, .{ 3, 0, 4, 1, 5, 2 }, .{ 5, 2, 4, 1, 3, 0 }, .{ 2, 5, 1, 4, 0, 3 } };
    for (maps, 1..) |map, orientation| {
        var name: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "tests/fixtures/rgb16-orientation{d}.tif", .{orientation});
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decoder.loadWithAllocator(path, 0, allocator.allocator());
        try std.testing.expectEqual(decoder.Backend.libtiff, image.backend);
        try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
        const width: usize = if (orientation >= 5) 2 else 3;
        try std.testing.expectEqual(width, image.width);
        const data = n.CGDataProviderCopyData(n.CGImageGetDataProvider(image.native)).?;
        const bytes = n.CFDataGetBytePtr(data);
        const row = n.CGImageGetBytesPerRow(image.native);
        for (map, 0..) |index, pixel| {
            const offset = pixel / width * row + pixel % width * 8;
            for (source[index], 0..) |value, channel| try std.testing.expectEqual(value, std.mem.readInt(u16, bytes[offset + channel * 2 ..][0..2], .little));
        }
        n.CFRelease(data);
        image.destroy();
        try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    }
}

test "provider pins TIFF pixels after the application releases its last image ref" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const image = try decoder.loadWithAllocator("tests/fixtures/rgb16-orientation1.tif", 0, allocator.allocator());
    const native = n.CFRetain(image.native);
    image.destroy();
    try std.testing.expectEqual(@as(usize, 0), allocator.freed_bytes);
    const data = n.CGDataProviderCopyData(n.CGImageGetDataProvider(native)).?;
    try std.testing.expectEqual(@as(u16, 65535), std.mem.readInt(u16, n.CFDataGetBytePtr(data)[0..2], .little));
    n.CFRelease(data);
    n.CFRelease(native);
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "RGB16 decoder allocation failure does not publish a partial image" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decoder.loadWithAllocator("tests/fixtures/rgb16-orientation1.tif", 0, allocator.allocator()));
}
test "big-endian RGB16 tiles preserve samples across clipped tile edges" {
    const image = try decoder.loadWithAllocator("tests/fixtures/rgb16-tiled-big.tif", 0, std.testing.allocator);
    defer image.destroy();
    try std.testing.expectEqual(decoder.Backend.libtiff, image.backend);
    const data = n.CGDataProviderCopyData(n.CGImageGetDataProvider(image.native)).?;
    defer n.CFRelease(data);
    const bytes = n.CFDataGetBytePtr(data);
    const row_bytes = n.CGImageGetBytesPerRow(image.native);
    for (0..18) |y| for (0..19) |x| {
        const expected = [_]u16{ @truncate(x * 1431 + y * 73), @truncate(x * 17 + y * 157), @truncate((x ^ y) * 256) };
        for (expected, 0..) |value, channel| try std.testing.expectEqual(value, std.mem.readInt(u16, bytes[y * row_bytes + x * 8 + channel * 2 ..][0..2], .little));
    };
}

test "parallel strip and tile decoding matches every serial byte including padding" {
    const tiff = @import("tiff_decoder.zig");
    const files = .{
        "tests/fixtures/rgb16-orientation1.tif",
        "tests/fixtures/rgb16-orientation2.tif",
        "tests/fixtures/rgb16-orientation3.tif",
        "tests/fixtures/rgb16-orientation4.tif",
        "tests/fixtures/rgb16-orientation5.tif",
        "tests/fixtures/rgb16-orientation6.tif",
        "tests/fixtures/rgb16-orientation7.tif",
        "tests/fixtures/rgb16-orientation8.tif",
        "tests/fixtures/rgb16-tiled-big.tif",
    };
    inline for (files) |file| {
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var serial_time: tiff.Timings = .{};
        var parallel_time: tiff.Timings = .{};
        const serial = (try tiff.measure(file, counted.allocator(), .{}, &serial_time, .{ .workers = 1 })).?;
        const parallel = (try tiff.measure(file, counted.allocator(), .{}, &parallel_time, .{ .workers = 8 })).?;
        try std.testing.expect(parallel_time.workers > 1);
        try std.testing.expectEqual(serial_time.blocks, parallel_time.blocks);
        try std.testing.expectEqual(serial.decoded_bytes, parallel.decoded_bytes);
        try std.testing.expectEqualSlices(u8, serial.ownedPixels().?, parallel.ownedPixels().?);
        serial.destroy();
        parallel.destroy();
        try std.testing.expectEqual(@as(usize, 2), counted.alloc_index);
        try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    }
}

test "parallel read failure joins helpers and releases the single slab" {
    const tiff = @import("tiff_decoder.zig");
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var timing: tiff.Timings = .{};
    try std.testing.expectError(error.DecodeFailed, tiff.measure("tests/fixtures/rgb16-bad-second-strip.tif", counted.allocator(), .{}, &timing, .{ .workers = 8 }));
    try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test "TIFF storage planning has no RAM fraction or GiB ceiling" {
    const tiff = @import("tiff_decoder.zig");
    const plan = try tiff.storageLayout(1_000_000, 1_000_000, 4096, 192);
    try std.testing.expectEqual(@as(usize, 8_000_000_000_000), plan.pixel_bytes);
    try std.testing.expect(plan.total > plan.pixel_bytes);
    try std.testing.expectError(error.SizeOverflow, tiff.storageLayout(std.math.maxInt(usize), 2, 0, 1));
    try std.testing.expectError(error.SizeOverflow, tiff.storageLayout(64, std.math.maxInt(usize), 0, 1));
}

test "cache-blocked rotation preserves every sample after scratch becomes reclaimable" {
    const tiff = @import("tiff_decoder.zig");
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var timing: tiff.Timings = .{};
    const image = (try tiff.measure("tests/fixtures/rgb16-cache-rotate.tif", counted.allocator(), .{}, &timing, .{ .workers = 2, .raw_retirement = true })).?;
    try std.testing.expect(image.scratch_reclaimable_bytes > 0);
    try std.testing.expectEqual(@as(u32, 64), image.width);
    try std.testing.expectEqual(@as(u32, 257), image.height);
    const native = n.CFRetain(image.native);
    image.destroy(); // Native provider must continue pinning the pixel allocation.
    try std.testing.expectEqual(@as(usize, 0), counted.freed_bytes);
    const data = n.CGDataProviderCopyData(n.CGImageGetDataProvider(native)).?;
    const bytes = n.CFDataGetBytePtr(data);
    const row = n.CGImageGetBytesPerRow(native);
    for (0..64) |y| for (0..257) |x| {
        const offset = x * row + (63 - y) * 8;
        const expected = [_]u16{ @truncate(x * 257 + y), @truncate(y * 911 + x * 3), @truncate((x * 31) ^ (y * 127)), 65535 };
        for (expected, 0..) |value, channel| try std.testing.expectEqual(value, std.mem.readInt(u16, bytes[offset + channel * 2 ..][0..2], .little));
    };
    n.CFRelease(data);
    n.CFRelease(native);
    try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test "SIMD prediction matches libtiff across byte orders, strips and clipped tiles" {
    const tiff = @import("tiff_decoder.zig");
    inline for (.{ "little-strips", "big-strips", "little-tiled", "big-tiled" }) |kind| {
        const path = "tests/fixtures/predictor16-" ++ kind ++ ".tif";
        var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var times: tiff.Timings = .{};
        const reference = (try tiff.measure(path, counted.allocator(), .{}, &times, .{ .workers = 2 })).?;
        defer reference.destroy();
        const candidate = (try tiff.measure(path, counted.allocator(), .{}, &times, .{ .workers = 2, .simd_predictor = true })).?;
        defer candidate.destroy();
        try std.testing.expect(times.simd_predictor);
        try std.testing.expectEqualSlices(u8, reference.ownedPixels().?, candidate.ownedPixels().?);
    }
}

test "macOS photo codecs preserve orientation, grayscale profiles, alpha and one owned slab" {
    inline for (.{
        .{ "jxl-rgb8-raw.jxl", .jxl, 3, 2, 8 },
        .{ "jxl-rgb16.jxl", .jxl, 3, 2, 16 },
        .{ "jxl-gray16.jxl", .jxl, 3, 2, 16 },
        .{ "jxl-alpha.jxl", .jxl, 3, 2, 8 },
        .{ "jxl-orientation6.jxl", .jxl, 2, 3, 8 },
        .{ "raw-bayer-orientation6.dng", .raw, 96, 128, 16 },
    }) |sample| {
        const path = "tests/fixtures/" ++ sample[0];
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        {
            const image = try decoder.loadWithAllocator(path, 0, allocator.allocator());
            defer image.destroy();
            try std.testing.expectEqual(@as(decoder.Backend, sample[1]), image.backend);
            try std.testing.expectEqual(@as(u32, sample[2]), image.width);
            try std.testing.expectEqual(@as(u32, sample[3]), image.height);
            try std.testing.expectEqual(@as(usize, sample[4]), image.bits_per_component);
            const metadata = try decoder.metadata(path);
            try std.testing.expectEqual(image.width, metadata.width);
            try std.testing.expectEqual(image.height, metadata.height);
            if (comptime std.mem.eql(u8, sample[0], "jxl-gray16.jxl")) {
                try std.testing.expectEqual(@as(c_int, 0), n.CGColorSpaceGetModel(n.CGImageGetColorSpace(image.native).?));
            }
            if (comptime std.mem.eql(u8, sample[0], "jxl-alpha.jxl")) {
                const pixels = image.ownedPixels().?;
                const alpha = [6]u8{ 0, 128, 255, 255, 255, 255 };
                var actual: [6]u8 = undefined;
                for (&actual, 0..) |*value, i| value.* = pixels[i * 4 + 3];
                std.mem.sort(u8, &actual, {}, std.sort.asc(u8));
                try std.testing.expectEqualSlices(u8, &alpha, &actual);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
        try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    }
}
