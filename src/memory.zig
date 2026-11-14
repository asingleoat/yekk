//! Runtime allocation instrumentation. Debug bookkeeping is separate from the
//! production contract of one startup slab and one allocation per image.
const std = @import("std");
const options = @import("build_options");
const n = @import("runtime");
var debug_allocator: std.heap.DebugAllocator(.{ .thread_safe = true, .safety = true, .stack_trace_frames = 12 }) = .init;
var allocations: std.atomic.Value(usize) = .init(0);
var frees: std.atomic.Value(usize) = .init(0);
var live_bytes: std.atomic.Value(usize) = .init(0);
var peak_bytes: std.atomic.Value(usize) = .init(0);
var token: u8 = 0;
var fail_allocations: std.atomic.Value(usize) = .init(0);
pub const debug_enabled = options.debug_allocator;
pub var report: bool = false;
/// Deterministic native lifecycle tests exercise the real allocator failure path.
/// The production allocator has no injection branch or additional atomic load.
pub fn failNext(count: usize) void {
    std.debug.assert(debug_enabled);
    fail_allocations.store(count, .release);
}
fn backing() std.mem.Allocator {
    return if (options.debug_allocator) debug_allocator.allocator() else std.heap.c_allocator;
}
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = &token, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
}
fn allocate(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    if (debug_enabled) {
        var remaining = fail_allocations.load(.acquire);
        while (remaining > 0) {
            remaining = fail_allocations.cmpxchgWeak(remaining, remaining - 1, .acq_rel, .acquire) orelse return null;
        }
    }
    const pointer = backing().rawAlloc(len, alignment, ra) orelse return null;
    _ = allocations.fetchAdd(1, .monotonic);
    const live = live_bytes.fetchAdd(len, .monotonic) + len;
    var peak = peak_bytes.load(.monotonic);
    while (live > peak) {
        peak = peak_bytes.cmpxchgWeak(peak, live, .monotonic, .monotonic) orelse break;
    }
    return pointer;
}
// Runtime slabs never resize; refusing in-place growth keeps ownership simple.
fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}
fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}
fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const len = bytes.len;
    backing().rawFree(bytes, alignment, ra);
    _ = live_bytes.fetchSub(len, .release);
    _ = frees.fetchAdd(1, .release);
}
pub fn finish() bool {
    // Called after every window, renderer and autorelease pool is gone. Native
    // providers can finish retiring on dispatch workers after the last UI close.
    // This is process teardown; no live UI waits on this diagnostic drain.
    const deadline = n.now() + 5;
    while ((options.debug_allocator or report) and live_bytes.load(.acquire) > 0 and n.now() < deadline) {
        _ = poll(null, 0, 10);
    }
    const clean = live_bytes.load(.acquire) == 0;
    if (report or options.debug_allocator) {
        var buffer: [512]u8 = undefined;
        n.output(2, std.fmt.bufPrint(&buffer, "owned allocations: debug={any}, allocations={d}, frees={d}, peak_bytes={d}, live_bytes={d}\n", .{ options.debug_allocator, allocations.load(.acquire), frees.load(.acquire), peak_bytes.load(.acquire), live_bytes.load(.acquire) }) catch "allocation statistics overflow\n");
    }
    if (options.debug_allocator) {
        if (!clean) {
            _ = debug_allocator.detectLeaks();
            return false;
        }
        return debug_allocator.deinit() == .ok;
    }
    return true;
}
extern "c" fn poll(?*anyopaque, u32, c_int) c_int;
