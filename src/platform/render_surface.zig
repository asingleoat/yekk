//! A completed, immutable Core Image render backed by shared native storage.
//! CGImage's provider pins the IOSurface until its final consumer retires.
const n = @import("native.zig");
const objc = @import("objc");
const O = objc.Object;
extern "c" var kIOSurfaceColorSpace: n.Ref;
extern "c" fn IOSurfaceSetValue(n.Ref, n.Ref, n.Ref) void;
extern "c" var kIOSurfaceWidth: n.Ref;
extern "c" var kIOSurfaceHeight: n.Ref;
extern "c" var kIOSurfaceBytesPerElement: n.Ref;
extern "c" var kIOSurfacePixelFormat: n.Ref;
extern "c" fn IOSurfaceCreate(n.Ref) ?n.Ref;
extern "c" fn IOSurfaceGetBaseAddress(n.Ref) ?[*]u8;
extern "c" fn IOSurfaceGetBytesPerRow(n.Ref) usize;
extern "c" fn IOSurfaceGetWidth(n.Ref) usize;
extern "c" fn IOSurfaceGetHeight(n.Ref) usize;
extern "c" fn IOSurfaceLock(n.Ref, u32, ?*u32) c_int;
extern "c" fn IOSurfaceUnlock(n.Ref, u32, ?*u32) c_int;
const read_only = 1;
extern "c" fn pthread_main_np() c_int;

fn release(context: ?*anyopaque, _: ?*const anyopaque, _: usize) callconv(.c) void {
    // Core Animation can drop its final provider reference on the UI thread.
    // Keep native unlock/unmap work on a worker, as for source-slab retirement.
    if (pthread_main_np() != 0) {
        n.dispatch_async_f(n.dispatch_get_global_queue(0x11, 0), context, unpin);
    } else unpin(context);
}
fn unpin(context: ?*anyopaque) callconv(.c) void {
    const surface: n.Ref = context.?;
    _ = IOSurfaceUnlock(surface, read_only, null);
    n.CFRelease(surface);
}

pub const Shared = struct { image: n.Ref, display: n.Ref };

/// Returns null for unsupported storage or a failed native render. The caller
/// can retain its existing bitmap renderer as a fallback. No pixels escape
/// until the render task has completed and the read lock is established.
pub fn render(context: O, image: O, bounds: n.Rect, color: n.Ref, color_properties: n.Ref) ?Shared {
    const width: usize = @intFromFloat(bounds.size.width);
    const height: usize = @intFromFloat(bounds.size.height);
    const keys = [_]n.Ref{ kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat };
    // Core Video's public 'RGhA' format: little-endian RGBA half floats.
    const numbers = [_]i64{ @intCast(width), @intCast(height), 8, 0x52476841 };
    var values: [4]n.Ref = undefined;
    var count: usize = 0;
    defer for (values[0..count]) |value| n.CFRelease(value);
    for (numbers, &values) |number, *value| {
        value.* = n.CFNumberCreate(null, 4, &number) orelse return null;
        count += 1;
    }
    const properties = n.CFDictionaryCreate(null, &keys, &values, keys.len, &n.kCFTypeDictionaryKeyCallBacks, &n.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer n.CFRelease(properties);
    const surface = IOSurfaceCreate(properties) orelse return null;
    IOSurfaceSetValue(surface, kIOSurfaceColorSpace, color_properties);
    defer n.CFRelease(surface);
    const destination = objc.getClass("CIRenderDestination").?.msgSend(O, "alloc", .{}).msgSend(O, "initWithIOSurface:", .{surface});
    if (destination.value == null) return null;
    defer destination.release();
    destination.msgSend(void, "setFlipped:", .{true});
    destination.msgSend(void, "setAlphaMode:", .{@as(usize, 1)});
    destination.msgSend(void, "setColorSpace:", .{color});
    var failure: ?n.Ref = null;
    const task = context.msgSend(O, "startTaskToRender:fromRect:toDestination:atPoint:error:", .{ image, bounds, destination, n.Point{ .x = 0, .y = 0 }, &failure });
    if (task.value == null or task.msgSend(?n.Ref, "waitUntilCompletedAndReturnError:", .{&failure}) == null) return null;
    const rendered = copyImage(surface, color) orelse return null;
    return .{ .image = rendered, .display = surface };
}

/// A read-only CGImage mirror of a validated RGhA surface. The provider owns
/// its own surface reference; callers may release their native reference.
pub fn copyImage(surface: n.Ref, color: n.Ref) ?n.Ref {
    const width = IOSurfaceGetWidth(surface);
    const height = IOSurfaceGetHeight(surface);
    if (IOSurfaceLock(surface, read_only, null) != 0) return null;
    var locked = true;
    defer if (locked) {
        _ = IOSurfaceUnlock(surface, read_only, null);
    };
    const pixels = IOSurfaceGetBaseAddress(surface) orelse return null;
    const stride = IOSurfaceGetBytesPerRow(surface);
    const provider = n.CGDataProviderCreateWithData(@constCast(surface), pixels, stride * height, release) orelse return null;
    // The provider now owns both the surface reference and its read lock.
    _ = n.CFRetain(surface);
    locked = false;
    defer n.CFRelease(provider);
    return n.CGImageCreate(width, height, 16, 64, stride, color, 0x1101, provider, null, true, 0);
}
