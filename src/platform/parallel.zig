//! Joined decoder jobs. A failed thread start runs that job on the caller.
const std = @import("std");
const builtin = @import("builtin");
extern "c" fn qos_class_self() u32;
extern "c" fn dispatch_get_global_queue(isize, usize) *anyopaque;
extern "c" fn dispatch_group_create() ?*anyopaque;
extern "c" fn dispatch_group_async_f(*anyopaque, *anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_group_wait(*anyopaque, u64) isize;
extern "c" fn dispatch_release(*anyopaque) void;

pub fn run(work: anytype, comptime function: anytype) void {
    const W = @typeInfo(@TypeOf(work)).pointer.child;
    if (builtin.os.tag == .macos and work.len > 1) {
        if (dispatch_group_create()) |group| {
            defer dispatch_release(group);
            const qos = qos_class_self();
            const queue = dispatch_get_global_queue(if (qos == 0) 0x19 else qos, 0);
            const callback = struct {
                fn call(context: ?*anyopaque) callconv(.c) void {
                    function(@as(*W, @ptrCast(@alignCast(context.?))));
                }
            }.call;
            for (work[1..]) |*item| dispatch_group_async_f(group, queue, item, callback);
            function(&work[0]);
            _ = dispatch_group_wait(group, std.math.maxInt(u64));
            return;
        }
    }
    for (work[1..]) |*item| item.thread = std.Thread.spawn(.{}, function, .{item}) catch serial: {
        function(item);
        break :serial null;
    };
    function(&work[0]);
    for (work[1..]) |*item| if (item.thread) |thread| thread.join();
}
