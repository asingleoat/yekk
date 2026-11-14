//! Process services shared by the native backends.
const builtin = @import("builtin");
pub const files = @import("file_abi.zig");
pub const darwin = builtin.os.tag == .macos;
extern "c" fn __error() *c_int;
extern "c" fn __errno_location() *c_int;
const Timespec = extern struct { sec: isize, nsec: isize };
extern "c" fn clock_gettime(c_int, *Timespec) c_int;
extern "c" fn write(c_int, [*]const u8, usize) isize;
pub extern "c" fn pread(c_int, [*]u8, usize, i64) isize;
pub fn errno() *c_int {
    return if (darwin) __error() else __errno_location();
}
pub fn now() f64 {
    var time: Timespec = undefined;
    if (clock_gettime(if (darwin) 6 else 1, &time) != 0) return 0;
    return @as(f64, @floatFromInt(time.sec)) + @as(f64, @floatFromInt(time.nsec)) / 1e9;
}
pub fn output(fd: c_int, bytes: []const u8) void {
    var used: usize = 0;
    while (used < bytes.len) {
        const count = write(fd, bytes[used..].ptr, bytes.len - used);
        if (count < 0 and errno().* == 4) continue;
        if (count <= 0) return;
        used += @intCast(count);
    }
}
