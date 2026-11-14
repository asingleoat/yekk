//! A read-only decode probe plus an opt-in synthetic fixture generator.
//! This is deliberately separate from the viewer. No performance claim or
//! production format coverage follows from the existence of these APIs.
const std = @import("std");
const n = @import("platform/native.zig");
const TIFF = opaque {};
extern "c" fn TIFFOpen([*:0]const u8, [*:0]const u8) ?*TIFF;
extern "c" fn TIFFFdOpen(c_int, [*:0]const u8, [*:0]const u8) ?*TIFF;
extern "c" fn TIFFClose(*TIFF) void;
extern "c" fn TIFFGetField(*TIFF, u32, ...) c_int;
extern "c" fn TIFFSetField(*TIFF, u32, ...) c_int;
extern "c" fn TIFFIsTiled(*TIFF) c_int;
extern "c" fn TIFFTileSize64(*TIFF) u64;
extern "c" fn TIFFStripSize64(*TIFF) u64;
extern "c" fn TIFFComputeTile(*TIFF, u32, u32, u32, u16) u32;
extern "c" fn TIFFComputeStrip(*TIFF, u32, u16) u32;
extern "c" fn TIFFReadEncodedTile(*TIFF, u32, *anyopaque, isize) isize;
extern "c" fn TIFFReadEncodedStrip(*TIFF, u32, *anyopaque, isize) isize;
extern "c" fn TIFFWriteEncodedTile(*TIFF, u32, *anyopaque, isize) isize;
extern "c" fn TIFFWriteEncodedStrip(*TIFF, u32, *anyopaque, isize) isize;
extern "c" fn clock_gettime(c_int, *Time) c_int;
const Time = extern struct { sec: i64, nsec: i64 };
extern "c" fn CGImageSourceCreateImageAtIndex(n.Ref, usize, ?n.Ref) ?n.Ref;

const Info = struct {
    width: u32 = 0,
    height: u32 = 0,
    bits: u16 = 0,
    samples: u16 = 0,
    planar: u16 = 1,
    photometric: u16 = 0,
    compression: u16 = 1,
    orientation: u16 = 1,
    sample_format: u16 = 1,
    block_w: u32 = 0,
    block_h: u32 = 0,
    tiled: bool = false,
};

fn info(tif: *TIFF) !Info {
    var result: Info = .{};
    if (TIFFGetField(tif, 256, &result.width) == 0 or TIFFGetField(tif, 257, &result.height) == 0 or
        TIFFGetField(tif, 258, &result.bits) == 0 or TIFFGetField(tif, 277, &result.samples) == 0) return error.MissingTags;
    _ = TIFFGetField(tif, 284, &result.planar);
    _ = TIFFGetField(tif, 262, &result.photometric);
    _ = TIFFGetField(tif, 259, &result.compression);
    _ = TIFFGetField(tif, 274, &result.orientation);
    _ = TIFFGetField(tif, 339, &result.sample_format);
    result.tiled = TIFFIsTiled(tif) != 0;
    if (result.tiled) {
        if (TIFFGetField(tif, 322, &result.block_w) == 0 or TIFFGetField(tif, 323, &result.block_h) == 0) return error.MissingTags;
    } else {
        result.block_w = result.width;
        result.block_h = result.height;
        _ = TIFFGetField(tif, 278, &result.block_h);
        result.block_h = @min(result.block_h, result.height);
    }
    if (result.width == 0 or result.height == 0 or result.block_w == 0 or result.block_h == 0) return error.InvalidDimensions;
    return result;
}

fn now() f64 {
    var t: Time = undefined;
    if (clock_gettime(6, &t) != 0) @panic("clock_gettime"); // CLOCK_MONOTONIC, Darwin
    return @as(f64, @floatFromInt(t.sec)) + @as(f64, @floatFromInt(t.nsec)) / 1e9;
}

fn report(comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    n.output(1, std.fmt.bufPrint(&buffer, format, args) catch "report overflow\n");
}

// Deterministic RGB16 pattern. An independent coordinate-based reference checks
// every requested sample after libtiff has actually decompressed the blocks.
fn sample(x: u32, y: u32, channel: usize) u16 {
    const value = switch (channel) {
        0 => x *% 17 +% y *% 31,
        1 => x *% 13 +% y *% 7,
        else => (x ^ y) *% 19,
    };
    return @truncate(value);
}

fn generate(path: [*:0]const u8, layout: []const u8) !void {
    const tiled = std.mem.eql(u8, layout, "tiles");
    const single = std.mem.eql(u8, layout, "single-strip");
    if (!tiled and !single and !std.mem.eql(u8, layout, "strips")) return error.InvalidLayout;
    // TIFFOpen would truncate. Require exclusive creation of a NEW fixture.
    const fd = n.open(path, @as(c_int, 0xA02), @as(c_int, 0o600)); // O_RDWR|O_CREAT|O_EXCL
    if (fd < 0) return error.FixtureMustNotExist;
    // Transfer this exact file descriptor; do not reopen a path between the
    // exclusive creation check and writing the fixture.
    const tif = TIFFFdOpen(fd, path, "w") orelse {
        _ = n.close(fd);
        return error.OpenFailed;
    };
    defer TIFFClose(tif);
    const width = 8192;
    const height = 8192;
    const block_w: u32 = if (tiled) 256 else width;
    const block_h: u32 = if (tiled) 256 else if (single) height else 64;
    if (TIFFSetField(tif, 256, @as(u32, width)) == 0 or TIFFSetField(tif, 257, @as(u32, height)) == 0 or
        TIFFSetField(tif, 258, @as(c_int, 16)) == 0 or TIFFSetField(tif, 277, @as(c_int, 3)) == 0 or
        TIFFSetField(tif, 262, @as(c_int, 2)) == 0 or TIFFSetField(tif, 284, @as(c_int, 1)) == 0 or
        TIFFSetField(tif, 259, @as(c_int, 8)) == 0 or TIFFSetField(tif, 274, @as(c_int, 1)) == 0) return error.SetTagFailed;
    if (tiled) {
        if (TIFFSetField(tif, 322, block_w) == 0 or TIFFSetField(tif, 323, block_h) == 0) return error.SetTagFailed;
    } else if (TIFFSetField(tif, 278, block_h) == 0) return error.SetTagFailed;
    const pixels = try std.heap.c_allocator.alloc(u16, @as(usize, block_w) * block_h * 3);
    defer std.heap.c_allocator.free(pixels);
    var y: u32 = 0;
    while (y < height) : (y += block_h) {
        var x: u32 = 0;
        while (x < width) : (x += block_w) {
            for (0..block_h) |row| for (0..block_w) |col| {
                for (0..3) |channel| pixels[(row * block_w + col) * 3 + channel] = sample(x + @as(u32, @intCast(col)), y + @as(u32, @intCast(row)), channel);
            };
            const index = if (tiled) TIFFComputeTile(tif, x, y, 0, 0) else TIFFComputeStrip(tif, y, 0);
            const size: isize = @intCast(pixels.len * 2);
            const written = if (tiled) TIFFWriteEncodedTile(tif, index, pixels.ptr, size) else TIFFWriteEncodedStrip(tif, index, pixels.ptr, size);
            if (written < 0) return error.WriteFailed;
        }
    }
    report("generated,{s},8192,8192,RGB16,deflate\n", .{layout});
}

const CacheEntry = struct {
    index: ?u32 = null,
    bytes: usize = 0,
    last_use: u64 = 0,
    pinned: bool = false,
};

fn blocks(path: [*:0]const u8, verify: bool, cached: bool) !void {
    // Disable mmap to make the access strategy explicit; OS file cache still
    // applies. This is not a cold-storage experiment.
    const tif = TIFFOpen(path, "rm") orelse return error.OpenFailed;
    defer TIFFClose(tif);
    const i = try info(tif);
    report("source,{d},{d},bits={d},samples={d},compression={d},orientation={d},layout={s},block={d}x{d}\n", .{ i.width, i.height, i.bits, i.samples, i.compression, i.orientation, if (i.tiled) "tiles" else "strips", i.block_w, i.block_h });
    // Research deliberately restricts the sample layout rather than silently
    // treating raw TIFF blocks as display-ready pixels. No color conversion.
    if (i.bits != 16 or i.samples != 3 or i.planar != 1 or i.photometric != 2 or i.sample_format != 1 or i.orientation != 1) return error.ProbeRequiresTopLeftContiguousRGB16;
    const bytes = if (i.tiled) TIFFTileSize64(tif) else TIFFStripSize64(tif);
    if (bytes == 0 or bytes > 512 * 1024 * 1024 or bytes % 2 != 0) return error.ScratchLimit;
    const slots: usize = if (cached) @intCast(@min(256, (128 * 1024 * 1024) / bytes)) else 1;
    if (slots == 0) return error.StoredBlockExceeds128MiBCache;
    const block_samples: usize = @intCast(bytes / 2);
    const storage = try std.heap.c_allocator.alloc(u16, block_samples * slots);
    defer std.heap.c_allocator.free(storage);
    var entries: [256]CacheEntry = @splat(.{});
    var tick: u64 = 0;
    const viewport_w = @min(i.width, 2048);
    const viewport_h = @min(i.height, 1536);
    var timings: [12]f64 = undefined;
    var checksum: u64 = 0;
    var total_decoded: u64 = 0;
    var total_blocks: u64 = 0;
    var hits: u64 = 0;
    const all_start = now();
    for (&timings, 0..) |*duration, step| {
        const blocks_before = total_blocks;
        const hits_before = hits;
        // Move forward in two dimensions, then retrace the exact same views.
        const phase = if (step < 6) step else 11 - step;
        const x: u32 = @intCast((phase * 173) % (@as(usize, i.width - viewport_w) + 1));
        const y: u32 = @intCast((phase * 113) % (@as(usize, i.height - viewport_h) + 1));
        const started = now();
        if (cached) {
            for (entries[0..slots]) |*entry| entry.pinned = false;
            // Pin ALL already-resident blocks needed by this view before any
            // eviction; scanning misses first must not evict a later hit.
            var pin_y = y / i.block_h * i.block_h;
            while (pin_y < y + viewport_h) : (pin_y += i.block_h) {
                var pin_x = x / i.block_w * i.block_w;
                while (pin_x < x + viewport_w) : (pin_x += i.block_w) {
                    const index = if (i.tiled) TIFFComputeTile(tif, pin_x, pin_y, 0, 0) else TIFFComputeStrip(tif, pin_y, 0);
                    for (entries[0..slots]) |*entry| if (entry.index == index) {
                        entry.pinned = true;
                    };
                }
            }
        }
        var by = y / i.block_h * i.block_h;
        while (by < y + viewport_h) : (by += i.block_h) {
            var bx = x / i.block_w * i.block_w;
            while (bx < x + viewport_w) : (bx += i.block_w) {
                const index = if (i.tiled) TIFFComputeTile(tif, bx, by, 0, 0) else TIFFComputeStrip(tif, by, 0);
                var found: ?usize = null;
                if (cached) for (entries[0..slots], 0..) |entry, slot| {
                    if (entry.index == index) {
                        found = slot;
                        break;
                    }
                };
                var victim: ?usize = null;
                if (found == null) {
                    for (entries[0..slots], 0..) |entry, slot| {
                        if (entry.pinned) continue;
                        if (victim == null or entry.last_use < entries[victim.?].last_use) victim = slot;
                    }
                }
                const slot = found orelse victim orelse return error.WorkingSetExceedsProbeCache;
                const scratch = storage[slot * block_samples ..][0..block_samples];
                if (found != null) {
                    hits += 1;
                } else {
                    const decoded = if (i.tiled) TIFFReadEncodedTile(tif, index, scratch.ptr, @intCast(bytes)) else TIFFReadEncodedStrip(tif, index, scratch.ptr, @intCast(bytes));
                    if (decoded <= 0) return error.DecodeFailed;
                    entries[slot].index = index;
                    entries[slot].bytes = @intCast(decoded);
                    total_blocks += 1;
                    total_decoded += @intCast(decoded);
                }
                tick += 1;
                entries[slot].last_use = tick;
                entries[slot].pinned = cached;
                const end_y = @min(@as(u64, by) + i.block_h, y + viewport_h);
                const end_x = @min(@as(u64, bx) + i.block_w, x + viewport_w);
                var py: u32 = @max(by, y);
                while (py < end_y) : (py += 1) {
                    var px: u32 = @max(bx, x);
                    while (px < end_x) : (px += 1) {
                        const offset = (@as(usize, py - by) * i.block_w + px - bx) * 3;
                        if ((offset + 3) * 2 > entries[slot].bytes) return error.ShortDecode;
                        for (0..3) |channel| {
                            const value = scratch[offset + channel];
                            checksum +%= value;
                            if (verify and value != sample(px, py, channel)) return error.PixelMismatch;
                        }
                    }
                }
            }
        }
        duration.* = (now() - started) * 1000;
        report("view,step={d},x={d},y={d},new_decodes={d},cache_hits={d},ready_ms={d:.3}\n", .{ step, x, y, total_blocks - blocks_before, hits - hits_before, duration.* });
    }
    const total_ms = (now() - all_start) * 1000;
    const first_ms = timings[0];
    std.mem.sort(f64, &timings, {}, std.sort.asc(f64));
    report("blocks{s},viewport={d}x{d},buffer_bytes={d},blocks_decoded={d},cache_hits={d},decoded_bytes={d},first_ms={d:.3},p50_ms={d:.3},p95_ms={d:.3},total_ms={d:.3},checksum={d},verified={any}\n", .{ if (cached) "-cached" else "", viewport_w, viewport_h, bytes * slots, total_blocks, hits, total_decoded, first_ms, timings[5], timings[11], total_ms, checksum, verify });
}

fn imageio(path: [*:0]const u8, full: bool) !void {
    const bytes = std.mem.span(path);
    const started = now();
    const url = n.CFURLCreateFromFileSystemRepresentation(null, bytes.ptr, @intCast(bytes.len), 0) orelse return error.OpenFailed;
    defer n.CFRelease(url);
    const source = n.CGImageSourceCreateWithURL(url, null) orelse return error.OpenFailed;
    defer n.CFRelease(source);
    var edge: i64 = 2048;
    const limit = n.CFNumberCreate(null, 4, &edge) orelse return error.OutOfMemory;
    defer n.CFRelease(limit);
    const keys = [_]n.Ref{ n.kCGImageSourceShouldCacheImmediately, n.kCGImageSourceCreateThumbnailFromImageAlways, n.kCGImageSourceCreateThumbnailWithTransform, n.kCGImageSourceThumbnailMaxPixelSize };
    const values = [_]n.Ref{ n.kCFBooleanTrue, n.kCFBooleanTrue, n.kCFBooleanTrue, limit };
    const options = n.CFDictionaryCreate(null, &keys, &values, keys.len, null, null) orelse return error.OutOfMemory;
    defer n.CFRelease(options);
    const image = (if (full) CGImageSourceCreateImageAtIndex(source, 0, options) else n.CGImageSourceCreateThumbnailAtIndex(source, 0, options)) orelse return error.DecodeFailed;
    defer n.CFRelease(image);
    report("imageio-{s},width={d},height={d},bpc={d},decoded_bytes={d},decode_ms={d:.3}\n", .{ if (full) "full" else "preview", n.CGImageGetWidth(image), n.CGImageGetHeight(image), n.CGImageGetBitsPerComponent(image), n.CGImageGetBytesPerRow(image) * n.CGImageGetHeight(image), (now() - started) * 1000 });
}

fn run(argc: c_int, argv: [*][*:0]const u8) !void {
    if (argc < 3 or argc > 4) return error.Usage;
    const mode = std.mem.span(argv[1]);
    if (std.mem.eql(u8, mode, "generate") and argc == 4) return generate(argv[2], std.mem.span(argv[3]));
    if (std.mem.eql(u8, mode, "blocks") or std.mem.eql(u8, mode, "blocks-cached")) return blocks(argv[2], argc == 4 and std.mem.eql(u8, std.mem.span(argv[3]), "--verify-synthetic"), std.mem.eql(u8, mode, "blocks-cached"));
    if (std.mem.eql(u8, mode, "imageio-preview")) return imageio(argv[2], false);
    if (std.mem.eql(u8, mode, "imageio-full")) return imageio(argv[2], true);
    return error.Usage;
}

pub export fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    run(argc, argv) catch |err| {
        n.output(2, @errorName(err));
        n.output(2, "\nUsage: tiff-probe generate NEW_FILE tiles|strips|single-strip\n       tiff-probe blocks|blocks-cached FILE [--verify-synthetic]\n       tiff-probe imageio-preview|imageio-full FILE\n");
        return 1;
    };
    return 0;
}
