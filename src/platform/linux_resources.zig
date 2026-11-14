//! Resource discovery respects the process affinity; topology is advisory.
const std = @import("std");
const c = @import("linux_bindings");
fn allowed(mask: *const c.cpu_set_t, cpu: usize) bool {
    const words: [*]const c_ulong = @ptrCast(mask);
    return words[cpu / @bitSizeOf(c_ulong)] & (@as(c_ulong, 1) << @intCast(cpu % @bitSizeOf(c_ulong))) != 0;
}
pub fn physicalCores() usize {
    const fallback = std.Thread.getCpuCount() catch 1;
    var mask: c.cpu_set_t = undefined;
    if (c.sched_getaffinity(0, @sizeOf(@TypeOf(mask)), &mask) != 0) return fallback;
    const limit = @sizeOf(@TypeOf(mask)) * 8;
    var count: usize = 0;
    for (0..limit) |cpu| {
        if (!allowed(&mask, cpu)) continue;
        var name: [160]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&name, "/sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list", .{cpu}, 0) catch return fallback;
        const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return fallback;
        var data: [4096]u8 = undefined;
        const length = c.read(fd, &data, data.len);
        _ = c.close(fd);
        if (length <= 0 or length == data.len) return fallback;
        var siblings = std.mem.tokenizeAny(u8, data[0..@intCast(length)], ",\n");
        var first: ?usize = null;
        while (siblings.next()) |text| {
            const dash = std.mem.indexOfScalar(u8, text, '-');
            const start = std.fmt.parseInt(usize, text[0 .. dash orelse text.len], 10) catch return fallback;
            const end = if (dash) |at| std.fmt.parseInt(usize, text[at + 1 ..], 10) catch return fallback else start;
            if (end < start) return fallback;
            var sibling = start;
            while (sibling <= end and sibling < limit) : (sibling += 1) {
                if (allowed(&mask, sibling)) {
                    first = @min(first orelse sibling, sibling);
                    break;
                }
            }
        }
        if (first == cpu) count += 1;
    }
    return if (count > 0) count else fallback;
}
