const std = @import("std");
const objc = @import("objc");
const n = @import("platform/native.zig");
const decoder = @import("decoder.zig");
const presentation = @import("presentation.zig");

fn rgba8(image: n.Ref, pixels: []u8, width: usize, height: usize) !void {
    @memset(pixels, 0);
    const color = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB).?;
    defer n.CFRelease(color);
    const context = n.CGBitmapContextCreate(pixels.ptr, width, height, 8, width * 4, color, 0x4001) orelse return error.ContextFailed;
    defer n.CFRelease(context);
    n.CGContextDrawImage(context, n.rect(0, 0, @floatFromInt(width), @floatFromInt(height)), image);
}
fn compareIdentity(path: []const u8, software: bool, p3: bool) !void {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        var renderer: presentation.Renderer = .{ .software = software };
        defer renderer.deinit();
        const image = try decoder.loadWithAllocator(path, 0, counted.allocator());
        defer image.destroy();
        if (p3) {
            const color = n.CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3).?;
            defer n.CFRelease(color);
            const tagged = n.CGImageCreateCopyWithColorSpace(image.native, color).?;
            n.CFRelease(image.native);
            image.native = tagged;
        }
        const request: presentation.Request = .{ .width = image.width, .height = image.height, .transform = .{ .a = 1, .b = 0, .c = 0, .d = 1 } };
        const surface = try renderer.render(image, request, .interaction);
        try std.testing.expectEqual(@as(usize, 16), n.CGImageGetBitsPerComponent(surface));
        try std.testing.expectEqual(image.width, n.CGImageGetWidth(surface));
        try std.testing.expectEqual(image.height, n.CGImageGetHeight(surface));
        try std.testing.expectEqual(surface, try renderer.render(image, request, .interaction));
        var before: [2048]u8 = undefined;
        var after: [2048]u8 = undefined;
        const count = @as(usize, image.width) * image.height * 4;
        try rgba8(image.native, before[0..count], image.width, image.height);
        try rgba8(surface, after[0..count], image.width, image.height);
        for (before[0..count], after[0..count]) |a, b| try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 1);
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
        renderer.clearCaches();
    }
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}
extern "c" var kCGColorSpaceDisplayP3: n.Ref;

test "optional GPU rendering preserves alpha, high precision and wide-gamut color" {
    if (!@import("test_options").gpu) return error.SkipZigTest;
    try compareIdentity("tests/fixtures/alpha.content", false, false);
    try compareIdentity("tests/fixtures/rgb16-orientation6.tif", false, false);
    try compareIdentity("tests/fixtures/rgb16-orientation1.tif", false, true);
}

test "software viewport rendering preserves oriented RGB16, alpha and P3 profiles" {
    inline for (.{
        "tests/fixtures/rgb16-orientation1.tif",
        "tests/fixtures/rgb16-orientation2.tif",
        "tests/fixtures/rgb16-orientation3.tif",
        "tests/fixtures/rgb16-orientation4.tif",
        "tests/fixtures/rgb16-orientation5.tif",
        "tests/fixtures/rgb16-orientation6.tif",
        "tests/fixtures/rgb16-orientation7.tif",
        "tests/fixtures/rgb16-orientation8.tif",
        "tests/fixtures/rgb16-tiled-big.tif",
        "tests/fixtures/alpha.content",
        "tests/fixtures/gray16.png",
    }) |file| {
        try compareIdentity(file, true, false);
    }
    try compareIdentity("tests/fixtures/rgb16-orientation1.tif", true, true);
}

test "nearest viewport rendering duplicates pixels without another source allocation" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        var renderer: presentation.Renderer = .{ .software = true };
        defer renderer.deinit();
        const image = try decoder.loadWithAllocator("tests/fixtures/alpha.content", 0, counted.allocator());
        defer image.destroy();
        const rendered = try renderer.render(image, .{ .width = 6, .height = 4, .transform = .{ .a = 2, .b = 0, .c = 0, .d = 2 }, .nearest = true }, .interaction);
        var reference: [24]u8 = undefined;
        var pixels: [96]u8 = undefined;
        try rgba8(image.native, &reference, 3, 2);
        try rgba8(rendered, &pixels, 6, 4);
        for (0..4) |y| for (0..6) |x| for (0..4) |channel| {
            const a = reference[((y / 2) * 3 + x / 2) * 4 + channel];
            const b = pixels[(y * 6 + x) * 4 + channel];
            try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) <= 1);
        };
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
        renderer.clearCaches();
    }
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test "invalid viewport does not initialize renderer or publish pixels" {
    const image = try decoder.loadWithAllocator("tests/fixtures/alpha.content", 0, std.testing.allocator);
    defer image.destroy();
    var renderer: presentation.Renderer = .{};
    try std.testing.expectError(error.InvalidViewport, renderer.render(image, .{ .width = 0, .height = 1, .transform = .{ .a = 1, .b = 0, .c = 0, .d = 1 } }, .interaction));
    try std.testing.expect(image.interaction == null and image.overview == null and image.ci_source == null);
    renderer.clearCaches();
    try std.testing.expectEqual(@as(isize, 0), renderer.once);
}

test "opaque minified image stays opaque and nearest overrides antialiasing" {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var renderer: presentation.Renderer = .{ .software = true };
    defer renderer.deinit();
    const image = try decoder.loadWithAllocator("tests/fixtures/checker16.png", 0, std.testing.allocator);
    defer image.destroy();
    var request: presentation.Request = .{ .width = 1, .height = 1, .transform = .{ .a = 0.125, .b = 0, .c = 0, .d = 0.125 } };
    var pixels: [4]u8 = undefined;
    try rgba8(try renderer.render(image, request, .interaction), &pixels, 1, 1);
    try std.testing.expectEqual(@as(u8, 255), pixels[3]);
    try std.testing.expect(pixels[0] > 100 and pixels[0] < 210);
    request.nearest = true;
    try rgba8(try renderer.render(image, request, .interaction), &pixels, 1, 1);
    try std.testing.expectEqual(@as(u8, 255), pixels[3]);
    try std.testing.expect(pixels[0] < 2 or pixels[0] > 253);
}

test "fitted viewport survives partial zoom, actual-size panning and unpublished work" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        var renderer: presentation.Renderer = .{ .software = true };
        defer renderer.deinit();
        const image = try decoder.loadWithAllocator("tests/fixtures/checker16.png", 0, counted.allocator());
        defer image.destroy();
        const fit: presentation.Request = .{ .width = 4, .height = 4, .transform = .{ .a = 0.5, .b = 0, .c = 0, .d = 0.5 } };
        // An exact manual view can become the automatic fit without another
        // render or duplicate cache ownership.
        const manual = try renderer.render(image, fit, .interaction);
        const surface = try renderer.render(image, fit, .overview);
        try std.testing.expectEqual(manual, surface);
        try std.testing.expect(image.interaction == null);
        var before: [64]u8 = undefined;
        var after: [64]u8 = undefined;
        try rgba8(surface, &before, 4, 4);
        for ([_]f64{ 0.625, 0.875 }) |scale| {
            var zoom = fit;
            zoom.transform.a = scale;
            zoom.transform.d = scale;
            _ = try renderer.render(image, zoom, .interaction);
            try std.testing.expectEqual(surface, image.cachedSurface(fit).?);
        }
        const epoch = image.cache_epoch;
        var pending = fit;
        pending.transform.a = 0.75;
        pending.transform.d = 0.75;
        const unpublished = try renderer.prepare(image, pending);
        defer n.CFRelease(unpublished.native());
        try std.testing.expectEqual(epoch, image.cache_epoch);
        try std.testing.expect(image.cachedSurface(pending) == null);
        try std.testing.expectEqual(surface, image.cachedSurface(fit).?);
        for (0..4) |step| {
            const actual: presentation.Request = .{ .width = 4, .height = 4, .transform = .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = -@as(f64, @floatFromInt(step)) } };
            const detail = try renderer.render(image, actual, .interaction);
            try std.testing.expectEqual(detail, image.cachedSurface(actual).?);
        }
        try std.testing.expectEqual(surface, try renderer.render(image, fit, .overview));
        try rgba8(surface, &after, 4, 4);
        try std.testing.expectEqualSlices(u8, &before, &after);
        try std.testing.expectEqual(image.interaction.?.bytes() + image.overview.?.bytes(), image.presentationBytes());
        var different = fit;
        different.nearest = true;
        try std.testing.expect(image.cachedSurface(different) == null);
        different = fit;
        different.width = 3;
        try std.testing.expect(image.cachedSurface(different) == null);
        renderer.clearCaches();
        // Clearing Core Image intermediates must not invalidate owned surfaces.
        try std.testing.expectEqual(surface, try renderer.render(image, fit, .overview));
        try std.testing.expectEqual(@as(usize, 1), counted.alloc_index);
    }
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
}

test "optional shared output preserves pixels, fallback and independent surface lifetime" {
    if (!@import("test_options").gpu) return error.SkipZigTest;
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var display: ?n.Ref = null;
    defer if (display) |surface| n.CFRelease(surface);
    var retained: ?n.Ref = null;
    defer if (retained) |surface| n.CFRelease(surface);
    var expected: [64]u8 = undefined;
    {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        var renderer: presentation.Renderer = .{};
        defer renderer.deinit();
        const image = try decoder.loadWithAllocator("tests/fixtures/rgb16-orientation1.tif", 0, counted.allocator());
        defer image.destroy();
        const reference = try decoder.loadWithAllocator("tests/fixtures/rgb16-orientation1.tif", 0, counted.allocator());
        defer reference.destroy();
        const p3 = n.CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3).?;
        defer n.CFRelease(p3);
        for ([_]*decoder.Image{ image, reference }) |source| {
            const tagged = n.CGImageCreateCopyWithColorSpace(source.native, p3).?;
            n.CFRelease(source.native);
            source.native = tagged;
        }
        const request: presentation.Request = .{ .width = 4, .height = 4, .transform = .{ .a = 0.5, .b = 0, .c = 0, .d = 0.5 } };
        const shared = try renderer.render(image, request, .interaction);
        if (renderer.shared_frames.load(.monotonic) == 0) return error.SkipZigTest;
        try std.testing.expect(image.displayContents(shared) != shared);
        display = n.CFRetain(image.displayContents(shared));
        retained = n.CFRetain(shared);
        try rgba8(shared, &expected, 4, 4);
        renderer.shared_enabled.store(false, .release);
        var actual: [64]u8 = undefined;
        const bitmap = try renderer.render(reference, request, .interaction);
        try rgba8(bitmap, &actual, 4, 4);
        const shared_bytes = n.CGDataProviderCopyData(n.CGImageGetDataProvider(shared)).?;
        defer n.CFRelease(shared_bytes);
        const bitmap_bytes = n.CGDataProviderCopyData(n.CGImageGetDataProvider(bitmap)).?;
        defer n.CFRelease(bitmap_bytes);
        try std.testing.expectEqual(@as(usize, 16), n.CGImageGetBitsPerComponent(shared));
        try std.testing.expect(n.CGImageGetBitmapInfo(shared) & 0x100 != 0);
        // Compare visible half-float samples, excluding each native allocator's
        // row padding. This checks precision beyond normalized RGBA8 captures.
        for (0..4) |row| {
            const first = n.CFDataGetBytePtr(shared_bytes) + row * n.CGImageGetBytesPerRow(shared);
            const second = n.CFDataGetBytePtr(bitmap_bytes) + row * n.CGImageGetBytesPerRow(bitmap);
            try std.testing.expectEqualSlices(u8, first[0..32], second[0..32]);
        }
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectEqual(@as(usize, 1), renderer.shared_frames.load(.monotonic));
        renderer.clearCaches();
        var changed = request;
        changed.transform.tx = 0.5;
        _ = try renderer.render(image, changed, .interaction);
        try std.testing.expectEqual(@as(usize, 2), renderer.shared_frames.load(.monotonic));
    }
    // The source and context may retire while the native display still pins
    // an older surface. Its provider must retain the backing independently.
    try std.testing.expectEqual(counted.allocated_bytes, counted.freed_bytes);
    var actual: [64]u8 = undefined;
    try rgba8(retained.?, &actual, 4, 4);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    const color = n.CFRetain(n.CGImageGetColorSpace(retained.?).?);
    defer n.CFRelease(color);
    n.CFRelease(retained.?);
    retained = null;
    const recovered = @import("platform/render_surface.zig").copyImage(display.?, color).?;
    defer n.CFRelease(recovered);
    try rgba8(recovered, &actual, 4, 4);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expectEqual(@as(usize, 2), counted.alloc_index);
}
