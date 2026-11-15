//! Core Graphics ownership adapter for the shared libtiff decoder.
const std = @import("std");
const n = @import("platform/native.zig");
const model = @import("image.zig");
const shared = @import("tiff_pixels");
pub const Options = shared.Options;
pub const Timings = shared.Timings;
pub const Layout = shared.Layout;

pub fn load(path: []const u8, allocator: std.mem.Allocator, limits: model.Limits) model.Failure!?*model.Image {
    return loadImpl(false, path, allocator, null, .{ .workers = limits.tiff_workers, .simd_predictor = limits.simd_predictor, .raw_retirement = limits.raw_retirement });
}
pub fn measure(path: []const u8, allocator: std.mem.Allocator, _: model.Limits, timings: *Timings, options: Options) model.Failure!?*model.Image {
    return loadImpl(true, path, allocator, timings, options);
}
fn loadImpl(comptime measured: bool, path: []const u8, allocator: std.mem.Allocator, timings: ?*Timings, options: Options) model.Failure!?*model.Image {
    const started = if (measured) n.now() else 0;
    var plan = (try shared.Plan.open(path)) orelse return null;
    defer plan.deinit();
    const space = if (plan.profile.len > 0) profile: {
        const data = n.CFDataCreate(null, plan.profile.ptr, @intCast(plan.profile.len)) orelse return error.OutOfMemory;
        defer n.CFRelease(data);
        break :profile n.CGColorSpaceCreateWithICCData(data) orelse return null;
    } else n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB) orelse return error.OutOfMemory;
    defer n.CFRelease(space);
    if (n.CGColorSpaceGetModel(space) != 1) return null;
    var selected = options;
    selected.prefix_bytes = @sizeOf(model.Image);
    selected.row_alignment = 64;
    if (selected.workers == 0) selected.workers = n.performanceCores();
    if (measured) timings.?.metadata_ms = (n.now() - started) * 1000;
    const decoded = try plan.decode(measured, allocator, selected, timings);
    const native_started = if (measured) n.now() else 0;
    const image = try fromDecoded(decoded, space, .libtiff);
    if (measured) {
        timings.?.native_ms = (n.now() - native_started) * 1000;
        timings.?.total_ms = (n.now() - started) * 1000;
    }
    return image;
}
pub fn storageLayout(width: usize, height: usize, scratch: usize, workers: usize) model.Failure!Layout {
    return shared.storageLayout(width, height, scratch, workers, @sizeOf(model.Image), 64, 0);
}

/// Takes ownership on both success and failure; the provider retains the slab.
pub fn fromDecoded(decoded: shared.Decoded, space: n.Ref, backend: model.Backend) model.Failure!*model.Image {
    var provider_owns = false;
    errdefer if (!provider_owns) decoded.deinit();
    const image: *model.Image = @ptrCast(decoded.slab.ptr);
    image.* = .{ .allocator = decoded.allocator, .native = undefined, .source_width = decoded.width, .source_height = decoded.height, .width = decoded.width, .height = decoded.height, .decoded_bytes = decoded.pixels.len, .pixel_offset = @intFromPtr(decoded.pixels.ptr) - @intFromPtr(decoded.slab.ptr), .bits_per_component = decoded.bits_per_component, .backend = backend, .raw_retirement = decoded.raw_retirement, .slab = decoded.slab };
    image.scratch_reclaimable_bytes = decoded.reclaimScratch();
    const provider = n.CGDataProviderCreateWithData(image, decoded.pixels.ptr, decoded.pixels.len, model.Image.releasePixels) orelse return error.OutOfMemory;
    provider_owns = true;
    defer n.CFRelease(provider);
    image.native = n.CGImageCreate(decoded.width, decoded.height, decoded.bits_per_component, @as(usize, decoded.bits_per_component) * 4, decoded.row_bytes, space, if (decoded.bits_per_component == 16) 0x1005 else 0x4005, provider, null, true, 0) orelse return error.DecodeFailed;
    return image;
}
