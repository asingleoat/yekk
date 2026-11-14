//! A nonallocating worker notification. The UI only signals; it never waits.
const std = @import("std");
const linux = std.os.linux;
pub const Notification = struct {
    revision: std.atomic.Value(u32) = .init(0),

    pub fn observe(self: *const Notification) u32 {
        return self.revision.load(.acquire);
    }
    pub fn notify(self: *Notification) void {
        _ = self.revision.fetchAdd(1, .release);
        _ = linux.futex_4arg(&self.revision.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32), null);
    }
    pub fn wait(self: *Notification, observed: u32, milliseconds: u32) void {
        const timeout: linux.timespec = .{ .sec = milliseconds / 1000, .nsec = @as(isize, milliseconds % 1000) * 1_000_000 };
        _ = linux.futex_4arg(&self.revision.raw, .{ .cmd = .WAIT, .private = true }, observed, &timeout);
    }
};
