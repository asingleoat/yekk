//! Owned decoded pixels. Native providers retain the slab through their last reader.
const std = @import("std");
const system = @import("system");
pub const Decoded = struct {
    bits_per_component: u8 = 16,
    allocator: std.mem.Allocator,
    slab: []align(64) u8,
    pixels: []u8,
    profile: []const u8,
    width: u32,
    height: u32,
    row_bytes: usize,
    raw_retirement: bool,
    pub fn deinit(self: Decoded) void {
        if (self.raw_retirement) self.allocator.rawFree(self.slab, .fromByteUnits(64), @returnAddress()) else self.allocator.free(self.slab);
    }
    pub fn reclaimScratch(self: Decoded) usize {
        if (!self.raw_retirement) return 0;
        const page: usize = @intCast(system.getpagesize());
        const first = std.mem.alignForward(usize, @intFromPtr(self.profile.ptr) + self.profile.len, page);
        const last = std.mem.alignBackward(usize, @intFromPtr(self.slab.ptr) + self.slab.len, page);
        if (last > first and system.madvise(@ptrFromInt(first), last - first, (if (@import("builtin").os.tag == .macos) system.MADV_FREE else system.MADV_DONTNEED)) == 0) return last - first;
        return 0;
    }
};
