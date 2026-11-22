//! One-image, one-process benchmark. Never opens an application or launches work.
const std = @import("std");
const c = @import("system");
const n = @import("platform/native.zig");
const tiff = @import("tiff_decoder.zig");
const decoder = @import("decoder.zig");
extern "c" fn CGImageGetShouldInterpolate(n.Ref) bool;
extern "c" fn proc_pid_rusage(c_int, c_int, *c.struct_rusage_info_v2) c_int;

fn output(comptime format: []const u8, values: anytype) void {
    var buffer: [4096]u8 = undefined;
    n.output(1, std.fmt.bufPrint(&buffer, format, values) catch @panic("benchmark output overflow"));
}
fn cpuMs(value: c.struct_timeval) f64 {
    return @as(f64, @floatFromInt(value.tv_sec)) * 1000 + @as(f64, @floatFromInt(value.tv_usec)) / 1000;
}
fn diskBytes() ?u64 {
    var info: c.struct_rusage_info_v2 = undefined;
    if (proc_pid_rusage(c.getpid(), 2, &info) != 0) return null;
    return info.ri_diskio_bytesread;
}
fn rawRead(path: [*:0]const u8, no_cache: bool) !void {
    const fd = c.open(path, c.O_RDONLY | c.O_NONBLOCK);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (no_cache and c.fcntl(fd, c.F_NOCACHE, @as(c_int, 1)) != 0) return error.NoCacheUnavailable;
    const buffer = try std.heap.c_allocator.alignedAlloc(u8, .fromByteUnits(4096), 8 * 1024 * 1024);
    defer std.heap.c_allocator.free(buffer);
    var before: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_SELF, &before);
    const disk_before = diskBytes();
    const started = n.now();
    var bytes: u64 = 0;
    var guard: u64 = 0;
    while (true) {
        const count = c.read(fd, buffer.ptr, buffer.len);
        if (count == 0) break;
        if (count < 0) {
            if (c.__error().* == c.EINTR) continue;
            return error.ReadFailed;
        }
        bytes += @intCast(count);
        guard +%= buffer[0];
    }
    const elapsed = (n.now() - started) * 1000;
    const disk_after = diskBytes();
    var after: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_SELF, &after);
    output("{{\"mode\":\"read\",\"no_cache\":{any},\"bytes\":{d},\"wall_ms\":{d:.3},\"user_ms\":{d:.3},\"system_ms\":{d:.3},\"disk_read_bytes\":{d},\"disk_counter_available\":{any},\"peak_rss_bytes\":{d},\"guard\":{d}}}\n", .{ no_cache, bytes, elapsed, cpuMs(after.ru_utime) - cpuMs(before.ru_utime), cpuMs(after.ru_stime) - cpuMs(before.ru_stime), if (disk_after != null and disk_before != null) disk_after.? - disk_before.? else 0, disk_after != null and disk_before != null, after.ru_maxrss, guard });
}
// Diagnostic allocations and file writes happen only on explicit request,
// after the timing interval. O_EXCL protects existing files and source scans.
fn dumpRgba(image: n.Ref, prefix: []const u8, step: usize) !void {
    const width = n.CGImageGetWidth(image);
    const height = n.CGImageGetHeight(image);
    const pixels = try std.heap.c_allocator.alloc(u8, width * height * 4);
    defer std.heap.c_allocator.free(pixels);
    @memset(pixels, 0);
    const color = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB) orelse return error.OutOfMemory;
    defer n.CFRelease(color);
    const context = n.CGBitmapContextCreate(pixels.ptr, width, height, 8, width * 4, color, 0x4001) orelse return error.RenderFailed;
    defer n.CFRelease(context);
    n.CGContextDrawImage(context, n.rect(0, 0, @floatFromInt(width), @floatFromInt(height)), image);
    var path: [4096]u8 = undefined;
    const name = try std.fmt.bufPrint(path[0 .. path.len - 1], "{s}-{d}.rgba", .{ prefix, step });
    path[name.len] = 0;
    const fd = c.open(path[0..name.len :0], c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var written: usize = 0;
    while (written < pixels.len) {
        const count = c.write(fd, pixels.ptr + written, pixels.len - written);
        if (count <= 0) return error.WriteFailed;
        written += @intCast(count);
    }
}
fn ownedSamples(image: *decoder.Image) []const u8 {
    if (@hasDecl(decoder.Image, "ownedPixels")) return image.ownedPixels().?;
    const header = std.mem.alignForward(usize, @sizeOf(decoder.Image), 64);
    return image.slab.?[header..][0..image.decoded_bytes];
}
fn usage() c.struct_rusage {
    var result: c.struct_rusage = undefined;
    if (c.getrusage(c.RUSAGE_SELF, &result) != 0) @panic("getrusage failed");
    return result;
}
fn run(argc: c_int, argv: [*][*:0]const u8) !void {
    if (argc < 3) return error.Usage;
    const mode = std.mem.span(argv[1]);
    var options: tiff.Options = .{ .raw_retirement = true, .simd_predictor = true };
    var width: u32 = 960;
    var height: u32 = 640;
    var iterations: usize = 64;
    var nearest = false;
    var checksum_surface = false;
    var checksum_pixels = false;
    var dump_prefix: ?[]const u8 = null;
    var i: usize = 3;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--dump-rgba")) {
            i += 1;
            if (i >= argc) return error.Usage;
            dump_prefix = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "--height") or std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= argc) return error.Usage;
            const value = try std.fmt.parseInt(u32, std.mem.span(argv[i]), 10);
            if (value == 0) return error.Usage;
            if (std.mem.eql(u8, arg, "--width")) width = value else if (std.mem.eql(u8, arg, "--height")) height = value else iterations = value;
        } else if (std.mem.eql(u8, arg, "--nearest")) nearest = true else if (std.mem.eql(u8, arg, "--checksum")) checksum_pixels = true else if (std.mem.eql(u8, arg, "--checksum-surface")) checksum_surface = true else if (std.mem.eql(u8, arg, "--native-predictor")) options.simd_predictor = false else if (std.mem.eql(u8, arg, "--simd-predictor")) options.simd_predictor = true else if (std.mem.eql(u8, arg, "--poison-free")) options.raw_retirement = false else if (std.mem.eql(u8, arg, "--dynamic")) options.dynamic = true else if (std.mem.eql(u8, arg, "--static")) options.dynamic = false else if (std.mem.eql(u8, arg, "--no-cache")) options.no_cache = true else if (std.mem.eql(u8, arg, "--poison")) options.poison_allocation = true else if (std.mem.eql(u8, arg, "--workers")) {
            i += 1;
            if (i >= argc) return error.Usage;
            options.workers = try std.fmt.parseInt(usize, std.mem.span(argv[i]), 10);
            if (options.workers < 1) return error.Usage;
        } else return error.Usage;
    }
    const no_cache = options.no_cache;
    if (std.mem.eql(u8, mode, "read")) return rawRead(argv[2], no_cache);
    if (std.mem.eql(u8, mode, "load")) {
        var counted = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
        const elapsed = measure: {
            const before = usage();
            const started = n.now();
            const image = try decoder.loadWithLimits(std.mem.span(argv[2]), 0, counted.allocator(), .{ .raw_retirement = true, .tiff_workers = options.workers });
            const elapsed = (n.now() - started) * 1000;
            defer image.destroy();
            const after = usage();
            output("{{\"mode\":\"resources\",\"user_ms\":{d:.3},\"system_ms\":{d:.3},\"peak_rss_bytes\":{d}}}\n", .{ cpuMs(after.ru_utime) - cpuMs(before.ru_utime), cpuMs(after.ru_stime) - cpuMs(before.ru_stime), after.ru_maxrss });
            if (checksum_pixels) {
                const pixels = image.ownedPixels() orelse return error.NoOwnedPixels;
                output("{{\"mode\":\"checksum\",\"checksum\":{d}}}\n", .{std.hash.XxHash64.hash(0, pixels)});
            }
            if (dump_prefix) |prefix| try dumpRgba(image.native, prefix, 0);
            output("{{\"mode\":\"image\",\"width\":{d},\"height\":{d},\"bits\":{d},\"backend\":\"{s}\"}}\n", .{ image.width, image.height, image.bits_per_component, @tagName(image.backend) });
            break :measure elapsed;
        };
        if (counted.alloc_index != 1 or counted.allocated_bytes != counted.freed_bytes) return error.AllocationInvariant;
        output("{{\"mode\":\"load\",\"wall_ms\":{d:.6},\"allocations\":{d}}}\n", .{ elapsed, counted.alloc_index });
        return;
    }
    if (std.mem.eql(u8, mode, "verify")) {
        var counted = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
        var first: tiff.Timings = .{};
        var second: tiff.Timings = .{};
        const serial = (try tiff.measure(std.mem.span(argv[2]), counted.allocator(), .{}, &first, .{ .workers = 1 })) orelse return error.UnsupportedTiff;
        defer serial.destroy();
        const parallel = (try tiff.measure(std.mem.span(argv[2]), counted.allocator(), .{}, &second, options)) orelse return error.UnsupportedTiff;
        defer parallel.destroy();
        if (serial.width != parallel.width or serial.height != parallel.height or serial.decoded_bytes != parallel.decoded_bytes or !std.mem.eql(u8, ownedSamples(serial), ownedSamples(parallel))) return error.PixelMismatch;
        output("{{\"mode\":\"verify\",\"equal\":true,\"bytes_compared\":{d},\"parallel_workers\":{d},\"allocations\":{d}}}\n", .{ serial.decoded_bytes, second.workers, counted.alloc_index });
        return;
    }
    if (std.mem.eql(u8, mode, "render") or std.mem.eql(u8, mode, "pan") or std.mem.eql(u8, mode, "zoom") or std.mem.eql(u8, mode, "fit-return") or std.mem.eql(u8, mode, "zoom-sweep")) {
        const objc = @import("objc");
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        // Match runtime.now(): Darwin CLOCK_MONOTONIC, not MONOTONIC_RAW.
        var resolution: c.struct_timespec = undefined;
        if (c.clock_getres(c.CLOCK_MONOTONIC, &resolution) != 0) return error.ClockUnavailable;
        output("{{\"mode\":\"clock\",\"resolution_ms\":{d:.9}}}\n", .{@as(f64, @floatFromInt(resolution.tv_sec)) * 1000 + @as(f64, @floatFromInt(resolution.tv_nsec)) / 1e6});
        const load_started = n.now();
        const image = try decoder.loadWithLimits(std.mem.span(argv[2]), 0, std.heap.c_allocator, .{ .tiff_workers = options.workers, .raw_retirement = true });
        defer image.destroy();
        output("{{\"mode\":\"load\",\"wall_ms\":{d:.3}}}\n", .{(n.now() - load_started) * 1000});
        var renderer: @import("presentation.zig").Renderer = .{};
        defer renderer.deinit();
        const fit = @min(@as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(image.width)), @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(image.height)));
        for (0..iterations) |step| {
            // Production render jobs drain their own autorelease pool.
            const frame_pool = objc.AutoreleasePool.init();
            defer frame_pool.deinit();
            const scale: f64 = if (std.mem.eql(u8, mode, "pan")) 1 else if (std.mem.eql(u8, mode, "zoom-sweep")) fit * std.math.pow(f64, 1.015625, @as(f64, @floatFromInt(step % 17))) else if (std.mem.eql(u8, mode, "zoom")) (if (step % 2 == 0) fit else fit * 1.25) else if (std.mem.eql(u8, mode, "fit-return")) (if (step % 2 == 0) fit else 1) else if (step < 2 or step % 6 == 5) fit else 1;
            const pan: f64 = if (std.mem.eql(u8, mode, "pan")) @as(f64, @floatFromInt(step % 17)) * 64 else if (std.mem.eql(u8, mode, "render") and step >= 2 and step % 6 < 5) @as(f64, @floatFromInt(step % 6)) * 64 else 0;
            const before = usage();
            const started = n.now();
            const request: @import("presentation.zig").Request = .{ .width = width, .height = height, .transform = .{ .a = scale, .b = 0, .c = 0, .d = scale, .tx = @round((@as(f64, @floatFromInt(width)) - @as(f64, @floatFromInt(image.width)) * scale) / 2) + pan, .ty = @round((@as(f64, @floatFromInt(height)) - @as(f64, @floatFromInt(image.height)) * scale) / 2) }, .nearest = nearest };
            const rendered = if (@hasDecl(@TypeOf(renderer), "prepare")) try renderer.render(image, request, if (scale == fit and pan == 0) .overview else .interaction) else try renderer.render(image, request);
            const elapsed = (n.now() - started) * 1000;
            const after = usage();
            output("{{\"mode\":\"prepare\",\"step\":{d},\"wall_ms\":{d:.6},\"user_ms\":{d:.3},\"system_ms\":{d:.3},\"peak_rss_bytes\":{d},\"scale\":{d:.8}}}\n", .{ step, elapsed, cpuMs(after.ru_utime) - cpuMs(before.ru_utime), cpuMs(after.ru_stime) - cpuMs(before.ru_stime), after.ru_maxrss, scale });
            if (step == 0) output("{{\"mode\":\"renderer\",\"device_budget_bytes\":{d},\"shared_frames\":{d},\"interpolate\":{any}}}\n", .{ if (@hasField(@TypeOf(renderer), "device_budget_bytes")) renderer.device_budget_bytes else @as(u64, 0), if (@hasField(@TypeOf(renderer), "shared_frames")) renderer.shared_frames.load(.monotonic) else @as(usize, 0), CGImageGetShouldInterpolate(rendered) });
            if (dump_prefix) |prefix| try dumpRgba(rendered, prefix, step);
            if (checksum_surface) {
                const provider = n.CGImageGetDataProvider(rendered);
                const data = n.CGDataProviderCopyData(provider) orelse return error.OutOfMemory;
                defer n.CFRelease(data);
                const bytes = n.CGImageGetBytesPerRow(rendered) * n.CGImageGetHeight(rendered);
                output("{{\"mode\":\"surface\",\"step\":{d},\"checksum\":{d},\"bytes\":{d}}}\n", .{ step, std.hash.XxHash64.hash(0, n.CFDataGetBytePtr(data)[0..bytes]), bytes });
            }
        }
        return;
    }
    if (!std.mem.eql(u8, mode, "decode")) return error.Usage;
    var timings: tiff.Timings = .{};
    var counted = std.testing.FailingAllocator.init(std.heap.c_allocator, .{});
    var before: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_SELF, &before);
    const disk_before = diskBytes();
    const started = n.now();
    const image = (try tiff.measure(std.mem.span(argv[2]), counted.allocator(), .{}, &timings, options)) orelse return error.UnsupportedTiff;
    const elapsed = (n.now() - started) * 1000;
    const disk_after = diskBytes();
    var after: c.struct_rusage = undefined;
    _ = c.getrusage(c.RUSAGE_SELF, &after);
    const checksum_started = n.now();
    const checksum = std.hash.XxHash64.hash(0, ownedSamples(image));
    const checksum_ms = (n.now() - checksum_started) * 1000;
    const decoded_width = image.width;
    const decoded_height = image.height;
    const decoded_bytes = image.decoded_bytes;
    const allocated_bytes = counted.allocated_bytes;
    const reclaimable = image.scratch_reclaimable_bytes;
    const destroy_started = n.now();
    image.destroy();
    const destroy_ms = (n.now() - destroy_started) * 1000;
    if (counted.alloc_index != 1 or counted.allocated_bytes != counted.freed_bytes) return error.AllocationInvariant;
    output("{{\"mode\":\"decode\",\"no_cache\":{any},\"width\":{d},\"height\":{d},\"decoded_bytes\":{d},\"allocated_bytes\":{d},\"allocations\":{d},\"wall_ms\":{d:.3},\"workers\":{d},\"decode_wall_ms\":{d:.3},\"metadata_ms\":{d:.3},\"allocation_ms\":{d:.3},\"blocks_ms\":{d:.3},\"conversion_ms\":{d:.3},\"native_ms\":{d:.3},\"blocks\":{d},\"user_ms\":{d:.3},\"system_ms\":{d:.3},\"disk_read_bytes\":{d},\"disk_counter_available\":{any},\"peak_rss_bytes\":{d},\"checksum\":{d},\"checksum_ms\":{d:.3},\"destroy_ms\":{d:.3},\"lane_min_ms\":{d:.3},\"lane_max_ms\":{d:.3},\"scratch_reclaimable_bytes\":{d},\"simd_predictor\":{any}}}\n", .{ no_cache, decoded_width, decoded_height, decoded_bytes, allocated_bytes, counted.alloc_index, elapsed, timings.workers, timings.decode_wall_ms, timings.metadata_ms, timings.allocation_ms, timings.blocks_ms, timings.conversion_ms, timings.native_ms, timings.blocks, cpuMs(after.ru_utime) - cpuMs(before.ru_utime), cpuMs(after.ru_stime) - cpuMs(before.ru_stime), if (disk_after != null and disk_before != null) disk_after.? - disk_before.? else 0, disk_after != null and disk_before != null, after.ru_maxrss, checksum, checksum_ms, destroy_ms, timings.lane_min_ms, timings.lane_max_ms, reclaimable, timings.simd_predictor });
}
pub export fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    run(argc, argv) catch |err| {
        n.output(2, @errorName(err));
        n.output(2, "\nUsage: yekk-bench-image read|load|decode|verify|render|pan|zoom|zoom-sweep|fit-return FILE [--no-cache] [--workers N] [--poison] [--poison-free] [--dynamic] [--native-predictor] [--width N --height N --iterations N] [--nearest] [--checksum] [--checksum-surface] [--dump-rgba PREFIX]\n");
        return 1;
    };
    return 0;
}
