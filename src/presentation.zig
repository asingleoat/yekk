//! Worker-only color-managed rendering. Completed native surfaces contain
//! viewport pixels, never the entire high-resolution source.
const std = @import("std");
const objc = @import("objc");
const n = @import("platform/native.zig");
const Image = @import("image.zig").Image;
const O = objc.Object;
extern "c" var kCIFormatRGBAh: c_int;
extern "c" var kCIFormatRGBAf: c_int;
extern "c" var kCIContextMemoryLimit: n.Ref;
extern "c" fn CGColorSpaceCopyPropertyList(n.Ref) ?n.Ref;
extern "c" fn MTLCreateSystemDefaultDevice() ?n.Ref;
extern "c" var kCIContextWorkingFormat: n.Ref;
extern "c" var kCIContextCacheIntermediates: n.Ref;
extern "c" var kCIContextWorkingColorSpace: n.Ref;
extern "c" var kCIContextUseSoftwareRenderer: n.Ref;
extern "c" var kCGColorSpaceExtendedLinearSRGB: n.Ref;
extern "c" fn dispatch_once_f(*isize, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
pub const Purpose = @import("image.zig").SurfacePurpose;
pub const Surface = @import("image.zig").Surface;
pub const Request = @import("image.zig").RenderRequest;
pub const Renderer = struct {
    once: isize = 0,
    context: O = .{ .value = null },
    color: ?n.Ref = null,
    surface_color: ?n.Ref = null,
    software: bool = false,
    device_budget_bytes: u64 = 0,
    shared_frames: std.atomic.Value(usize) = .init(0),
    shared_enabled: std.atomic.Value(bool) = .init(true),
    ready: std.atomic.Value(bool) = .init(false),
    pub fn deinit(self: *Renderer) void {
        self.context.release();
        if (self.surface_color) |color| n.CFRelease(color);
        if (self.color) |color| n.CFRelease(color);
    }
    fn initialize(context: ?*anyopaque) callconv(.c) void {
        const self: *Renderer = @ptrCast(@alignCast(context.?));
        self.color = n.CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        const color = self.color orelse return;
        self.surface_color = CGColorSpaceCopyPropertyList(color);
        var format: c_int = kCIFormatRGBAf;
        const number = n.CFNumberCreate(null, 3, &format) orelse return;
        defer n.CFRelease(number);
        // Let the system choose the GPU. Use that same device's reported
        // working-set guidance for Core Image, rather than a fixed MB quota or
        // a fraction of host RAM (which is inappropriate for discrete GPUs).
        const device_ref = if (self.software) null else MTLCreateSystemDefaultDevice();
        const device: O = .{ .value = if (device_ref) |ref| @ptrCast(@alignCast(@constCast(ref))) else null };
        defer device.release();
        const budget = if (device.value != null) device.msgSend(u64, "recommendedMaxWorkingSetSize", .{}) else 0;
        var megabytes: i64 = @intCast(budget / (1024 * 1024));
        const memory = if (megabytes > 0) n.CFNumberCreate(null, 4, &megabytes) else null;
        defer if (memory) |value| n.CFRelease(value);
        if (memory != null) self.device_budget_bytes = budget;
        const keys = [_]n.Ref{ kCIContextWorkingFormat, kCIContextCacheIntermediates, kCIContextWorkingColorSpace, kCIContextUseSoftwareRenderer, kCIContextMemoryLimit };
        const values = [_]n.Ref{ number, n.kCFBooleanTrue, color, if (self.software) n.kCFBooleanTrue else n.kCFBooleanFalse, memory orelse number };
        const options = n.CFDictionaryCreate(null, &keys, &values, if (memory != null) keys.len else keys.len - 1, &n.kCFTypeDictionaryKeyCallBacks, &n.kCFTypeDictionaryValueCallBacks) orelse return;
        defer n.CFRelease(options);
        const allocated = objc.getClass("CIContext").?.msgSend(O, "alloc", .{});
        self.context = if (device.value != null) allocated.msgSend(O, "initWithMTLDevice:options:", .{ device, options }) else allocated.msgSend(O, "initWithOptions:", .{options});
        if (self.context.value != null) self.ready.store(true, .release);
    }
    /// Synchronous adapter for headless callers that also own their cache.
    pub fn render(self: *Renderer, image: *Image, request: Request, purpose: Purpose) !n.Ref {
        if (image.cachedSurface(request)) |surface| {
            if (purpose == .overview) if (image.protectOverview(surface)) |previous| n.CFRelease(previous.native());
            return surface;
        }
        const completed = try self.prepare(image, request);
        if (image.storeSurface(completed, purpose)) |previous| n.CFRelease(previous.native());
        return completed.native();
    }
    /// Returns an owned immutable surface. One worker per image; no mutation of
    /// completed caches, so the UI can publish existing hits during this work.
    pub fn prepare(self: *Renderer, image: *Image, request: Request) !Surface {
        if (request.width == 0 or request.height == 0 or request.width > 16384 or request.height > 16384) return error.InvalidViewport;
        dispatch_once_f(&self.once, self, initialize);
        if (self.context.value == null) return error.RendererUnavailable;
        if (image.ci_source == null) {
            const created = objc.getClass("CIImage").?.msgSend(O, "alloc", .{}).msgSend(O, "initWithCGImage:", .{image.native});
            if (created.value == null) return error.RenderFailed;
            image.ci_source = @ptrCast(created.value.?);
        }
        const input: O = .{ .value = @ptrCast(@alignCast(@constCast(image.ci_source.?))) };
        if (input.value == null) return error.RenderFailed;
        const sampled = if (request.nearest) input.msgSend(O, "imageBySamplingNearest", .{}) else input;
        const transformed = sampled.msgSend(O, "imageByApplyingTransform:highQualityDownsample:", .{ request.transform, !request.nearest });
        const bounds = n.rect(0, 0, @floatFromInt(request.width), @floatFromInt(request.height));
        const clear_color = objc.getClass("CIColor").?.msgSend(O, "colorWithRed:green:blue:alpha:", .{ @as(f64, 0), @as(f64, 0), @as(f64, 0), @as(f64, 0) });
        const clear = objc.getClass("CIImage").?.msgSend(O, "imageWithColor:", .{clear_color}).msgSend(O, "imageByCroppingToRect:", .{bounds});
        const composite = transformed.msgSend(O, "imageByCompositingOverImage:", .{clear}).msgSend(O, "imageByCroppingToRect:", .{bounds});
        const shared = if (!self.software and self.surface_color != null and self.shared_enabled.load(.acquire)) @import("platform/render_surface.zig").render(self.context, composite, bounds, self.color.?, self.surface_color.?) else null;
        if (!self.software) {
            if (shared != null) {
                _ = self.shared_frames.fetchAdd(1, .monotonic);
            } else self.shared_enabled.store(false, .release);
        }
        const completed: Surface = .{ .request = request, .storage = if (shared) |value| .{ .shared = .{ .image = value.image, .display = value.display } } else .{ .bitmap = self.context.msgSend(?n.Ref, "createCGImage:fromRect:format:colorSpace:deferred:", .{ composite, bounds, kCIFormatRGBAh, self.color.?, false }) orelse return error.RenderFailed } };
        return completed;
    }

    pub fn clearCaches(self: *Renderer) void {
        // Pressure before the first render must not allocate a GPU context.
        if (!self.ready.load(.acquire)) return;
        self.context.msgSend(void, "clearCaches", .{});
        // A transient failure must not permanently disable the shared path.
        self.shared_enabled.store(true, .release);
    }
};
