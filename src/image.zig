const std = @import("std");
const n = @import("platform/native.zig");
pub const Backend = enum { image_io, libtiff, pnm, png, jpeg, jxl, raw };
pub const Failure = error{ OutOfMemory, UnreadableImage, InvalidDimensions, SizeOverflow, DecodeFailed, IncompleteImage, SourceChanged, Cancelled };
// Scheduling options impose no application RAM quota.
pub const Limits = struct { tiff_workers: usize = 0, simd_predictor: bool = true, raw_retirement: bool = false, cancel: ?*const std.atomic.Value(bool) = null };
pub const RenderRequest = struct {
    width: u32,
    height: u32,
    transform: n.Affine,
    nearest: bool = false,
    pub fn density(self: RenderRequest) f64 {
        const t = self.transform;
        return @max(@sqrt(t.a * t.a + t.b * t.b), @sqrt(t.c * t.c + t.d * t.d));
    }
};
pub const SurfacePurpose = @import("core.zig").SurfacePurpose;
pub const Surface = struct {
    request: RenderRequest,
    storage: union(enum) {
        bitmap: n.Ref,
        // The CGImage provider owns the shared storage. `display` is borrowed
        // from it; CALayer retains that IOSurface independently when published.
        shared: struct { image: n.Ref, display: n.Ref },
    },
    pub fn native(self: Surface) n.Ref {
        return switch (self.storage) {
            .bitmap => |value| value,
            .shared => |value| value.image,
        };
    }
    pub fn contents(self: Surface) n.Ref {
        return switch (self.storage) {
            .bitmap => |value| value,
            .shared => |value| value.display,
        };
    }
    pub fn bytes(self: Surface) usize {
        return n.CGImageGetBytesPerRow(self.native()) * n.CGImageGetHeight(self.native());
    }
};
pub const Image = struct {
    references: std.atomic.Value(u32) = .init(1),
    allocator: std.mem.Allocator,
    native: n.Ref,
    source_width: u32,
    source_height: u32,
    width: u32,
    height: u32,
    decoded_bytes: usize,
    pixel_offset: usize = 0,
    bits_per_component: usize,
    backend: Backend = .image_io,
    async_retirement: bool = false,
    raw_retirement: bool = false,
    scratch_reclaimable_bytes: usize = 0,
    // A single worker at a time owns ci_source. In the application, only the
    // main queue reads/writes the completed surface cache; jobs own their outputs.
    ci_source: ?n.Ref = null,
    // Protect automatic fitted views through manual zooms at every density.
    // Request and native ownership are present or absent together.
    interaction: ?Surface = null,
    cache_epoch: u64 = 0,
    overview: ?Surface = null,
    // For the owned-buffer backend, the provider owns this same allocation.
    // The image record, pixels, and reusable codec block scratch share one slab.
    slab: ?[]align(64) u8 = null,
    pub fn accountedBytes(self: *const Image) usize {
        return if (self.slab) |slab| slab.len - self.scratch_reclaimable_bytes else self.decoded_bytes + @sizeOf(Image);
    }

    pub fn cachedSurface(self: *const Image, request: RenderRequest) ?n.Ref {
        for ([_]?Surface{ self.interaction, self.overview }) |cached| {
            if (cached) |surface| if (std.meta.eql(surface.request, request)) return surface.native();
        }
        return null;
    }
    /// Takes ownership and returns the previous surface for worker retirement.
    pub fn storeSurface(self: *Image, surface: Surface, purpose: SurfacePurpose) ?Surface {
        const slot = switch (purpose) {
            .overview => &self.overview,
            .interaction => &self.interaction,
        };
        const previous = slot.*;
        slot.* = surface;
        self.cache_epoch +%= 1;
        return previous;
    }
    /// A manual view can exactly match a later automatic fit. Protect that
    /// existing surface by moving its ownership rather than rendering a copy.
    pub fn protectOverview(self: *Image, native: n.Ref) ?Surface {
        if (self.overview) |surface| if (surface.native() == native) return null;
        if (self.interaction) |surface| if (surface.native() == native) {
            self.interaction = null;
            return self.storeSurface(surface, .overview);
        };
        return null;
    }
    pub fn usedSurface(self: *Image) void {
        self.cache_epoch +%= 1;
    }
    pub fn displayContents(self: *const Image, image: n.Ref) n.Ref {
        for ([_]?Surface{ self.interaction, self.overview }) |cached| {
            if (cached) |surface| if (surface.native() == image) return surface.contents();
        }
        return image;
    }
    pub fn presentationBytes(self: *const Image) usize {
        return (if (self.interaction) |surface| surface.bytes() else 0) + (if (self.overview) |surface| surface.bytes() else 0);
    }
    pub fn ownedPixels(self: *const Image) ?[]const u8 {
        const slab = self.slab orelse return null;
        return slab[self.pixel_offset..][0..self.decoded_bytes];
    }
    pub fn retain(self: *Image) *Image {
        _ = self.references.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn destroy(self: *Image) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        const owned_backing = self.slab != null;
        const allocator = self.allocator;
        const native = self.native;
        if (self.interaction) |surface| n.CFRelease(surface.native());
        if (self.overview) |surface| n.CFRelease(surface.native());
        if (self.ci_source) |source| n.CFRelease(source);
        n.CFRelease(native);
        // A provider-backed image can outlive the application's wrapper refs
        // inside Core Animation. Its final provider callback frees the slab.
        if (!owned_backing) allocator.destroy(self);
    }
    pub fn releasePixels(info: ?*anyopaque, _: ?*const anyopaque, _: usize) callconv(.c) void {
        const self: *Image = @ptrCast(@alignCast(info.?));
        if ((self.async_retirement or self.allocator.vtable == std.heap.c_allocator.vtable) and pthread_main_np() != 0) {
            n.dispatch_async_f(n.dispatch_get_global_queue(0x11, 0), self, freePixels);
        } else freePixels(self);
    }
    fn freePixels(info: ?*anyopaque) callconv(.c) void {
        const self: *Image = @ptrCast(@alignCast(info.?));
        const allocator = self.allocator;
        const slab = self.slab.?;
        if (self.raw_retirement) {
            // The provider's final callback proves no reader can use these
            // pixels again. Avoid poisoning gigabytes before unmapping them.
            allocator.rawFree(slab, .fromByteUnits(64), @returnAddress());
        } else allocator.free(slab);
    }
};
extern "c" fn pthread_main_np() c_int;
