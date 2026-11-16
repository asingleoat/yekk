//! Narrow, audited C ABI boundary. Objective-C messages use zig-objc.
//! Opaque Core Foundation objects follow Create/Copy ownership rules.
pub const Ref = *const anyopaque;
pub extern "c" fn CACurrentMediaTime() f64;
pub extern "c" var NSRunLoopCommonModes: Ref;
pub const Point = extern struct { x: f64, y: f64 };
pub const Size = extern struct { width: f64, height: f64 };
pub const Rect = extern struct { origin: Point, size: Size };
pub const Affine = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64 = 0, ty: f64 = 0 };
pub fn rect(x: f64, y: f64, width: f64, height: f64) Rect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
}
pub extern "c" fn CFRelease(Ref) void;
pub extern "c" fn CFDataCreate(?Ref, [*]const u8, isize) ?Ref;
pub extern "c" fn CFDataGetBytePtr(Ref) [*]const u8;
pub extern "c" fn CFRetain(Ref) Ref;
pub extern "c" fn CFURLCreateFromFileSystemRepresentation(?Ref, [*]const u8, isize, u8) ?Ref;
pub extern "c" fn CFDictionaryCreate(?Ref, [*]const Ref, [*]const Ref, isize, ?*const anyopaque, ?*const anyopaque) ?Ref;
pub extern "c" fn CFDictionaryGetValue(Ref, Ref) ?Ref;
// Only the addresses of these native callback tables cross the ABI boundary.
pub extern "c" var kCFTypeDictionaryKeyCallBacks: u8;
pub extern "c" var kCFTypeDictionaryValueCallBacks: u8;
pub extern "c" fn CFNumberCreate(?Ref, c_int, *const anyopaque) ?Ref;
pub extern "c" fn CFNumberGetValue(Ref, c_int, *anyopaque) u8;
pub extern "c" fn CFGetTypeID(Ref) usize;
pub extern "c" fn CFNumberGetTypeID() usize;
pub extern "c" fn CFArrayGetCount(Ref) isize;
pub extern "c" fn CFArrayGetValueAtIndex(Ref, isize) Ref;
pub extern "c" fn CFStringGetCString(Ref, [*]u8, isize, u32) u8;
pub extern "c" var kCFBooleanTrue: Ref;
pub extern "c" var kCFBooleanFalse: Ref;
pub extern "c" fn CGImageSourceCreateWithURL(Ref, ?Ref) ?Ref;
pub extern "c" fn CGImageSourceCreateWithData(Ref, ?Ref) ?Ref;
pub extern "c" fn CGImageSourceCreateImageAtIndex(Ref, usize, ?Ref) ?Ref;
pub extern "c" fn CGImageSourceCopyPropertiesAtIndex(Ref, usize, ?Ref) ?Ref;
pub extern "c" fn CGImageSourceCreateThumbnailAtIndex(Ref, usize, ?Ref) ?Ref;
pub extern "c" fn CGImageSourceCopyTypeIdentifiers() Ref;
pub extern "c" fn CGImageSourceGetStatusAtIndex(Ref, usize) c_int;
pub extern "c" fn CGImageSourceGetStatus(Ref) c_int;
pub extern "c" var kCGImageSourceShouldCache: Ref;
pub extern "c" var kCGImageSourceShouldCacheImmediately: Ref;
pub extern "c" var kCGImageSourceCreateThumbnailFromImageAlways: Ref;
pub extern "c" var kCGImageSourceCreateThumbnailWithTransform: Ref;
pub extern "c" var kCGImageSourceThumbnailMaxPixelSize: Ref;
pub extern "c" var kCGImagePropertyPixelWidth: Ref;
pub extern "c" var kCGImagePropertyPixelHeight: Ref;
pub extern "c" var kCGImagePropertyOrientation: Ref;
pub extern "c" fn CGImageGetWidth(Ref) usize;
pub extern "c" fn CGImageGetHeight(Ref) usize;
pub extern "c" fn CGImageGetBytesPerRow(Ref) usize;
pub extern "c" fn CGImageGetBitsPerComponent(Ref) usize;
pub extern "c" fn CGImageGetBitsPerPixel(Ref) usize;
pub extern "c" fn CGImageGetBitmapInfo(Ref) u32;
pub extern "c" fn CGBitmapContextCreate(?*anyopaque, usize, usize, usize, usize, Ref, u32) ?Ref;
pub extern "c" fn CGContextDrawImage(Ref, Rect, Ref) void;
pub extern "c" fn CGContextScaleCTM(Ref, f64, f64) void;
pub extern "c" fn CGBitmapContextCreateImage(Ref) ?Ref;
pub extern "c" fn CGImageDestinationCreateWithURL(Ref, Ref, usize, ?Ref) ?Ref;
pub extern "c" fn CGImageDestinationAddImage(Ref, Ref, ?Ref) void;
pub extern "c" fn CGImageDestinationFinalize(Ref) u8;
pub extern "c" fn CGColorSpaceCreateWithName(Ref) ?Ref;
pub extern "c" var kCGColorSpaceSRGB: Ref;
pub extern "c" fn CGImageGetColorSpace(Ref) ?Ref;
pub extern "c" fn CGColorSpaceCreateWithICCData(Ref) ?Ref;
pub extern "c" fn CGColorSpaceGetModel(Ref) c_int;
pub extern "c" fn CGDataProviderCreateWithData(?*anyopaque, ?*const anyopaque, usize, *const fn (?*anyopaque, ?*const anyopaque, usize) callconv(.c) void) ?Ref;
pub extern "c" fn CGImageCreate(usize, usize, usize, usize, usize, Ref, u32, Ref, ?[*]const f64, bool, c_int) ?Ref;
pub extern "c" fn CGImageGetDataProvider(Ref) Ref;
pub extern "c" fn CGDataProviderCopyData(Ref) ?Ref;
pub extern "c" fn CGImageCreateCopyWithColorSpace(Ref, Ref) ?Ref;
// dispatch_get_main_queue is an SDK inline, not an exported symbol.
extern "c" var _dispatch_main_q: u8;
pub fn dispatch_get_main_queue() *anyopaque {
    return &_dispatch_main_q;
}
pub extern "c" fn dispatch_get_global_queue(isize, usize) *anyopaque;
pub extern "c" fn dispatch_async_f(*anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
pub extern "c" fn write(c_int, [*]const u8, usize) isize;
pub extern "c" fn open([*:0]const u8, c_int, ...) c_int;
pub extern "c" fn close(c_int) c_int;
pub extern "c" fn lseek(c_int, i64, c_int) i64;
pub extern "c" fn pread(c_int, [*]u8, usize, i64) isize;
pub extern "c" fn CFAbsoluteTimeGetCurrent() f64;
pub const now = @import("runtime").now;
extern "c" var _dispatch_source_type_memorypressure: u8;
pub fn pressureType() *anyopaque {
    return &_dispatch_source_type_memorypressure;
}
pub extern "c" fn dispatch_source_create(*anyopaque, usize, usize, *anyopaque) ?*anyopaque;
pub extern "c" fn dispatch_set_context(*anyopaque, ?*anyopaque) void;
pub extern "c" fn dispatch_source_set_event_handler_f(*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
pub extern "c" fn dispatch_source_set_cancel_handler_f(*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
pub extern "c" fn dispatch_source_get_data(*anyopaque) usize;
pub extern "c" fn dispatch_resume(*anyopaque) void;
pub extern "c" fn dispatch_source_cancel(*anyopaque) void;
pub extern "c" fn dispatch_release(*anyopaque) void;
pub extern "c" fn _NSGetExecutablePath([*]u8, *u32) c_int;

pub const output = @import("runtime").output;
pub extern "c" fn CGImageSourceGetType(Ref) ?Ref;

extern "c" fn sysctlbyname([*:0]const u8, ?*anyopaque, ?*usize, ?*anyopaque, usize) c_int;
pub fn performanceCores() usize {
    var cores: u32 = 0;
    var size: usize = @sizeOf(u32);
    if (sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, null, 0) != 0) {
        size = @sizeOf(u32);
        _ = sysctlbyname("hw.physicalcpu", &cores, &size, null, 0);
    }
    return @max(1, cores);
}
