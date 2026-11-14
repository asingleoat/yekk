//! Pinned SDL X11 workaround: select one representation of button events.
//! XI2 emits both source-device and master-device events. SDL's per-source
//! state cannot deduplicate a complete down/up pair queued on each device.
//! Retain source events when SDL has mouse focus (the same condition SDL uses
//! to accept them), and keep master events for its unfocused-window path.
//! No timestamps, buffering, allocations, or debounce interval are involved.
const t = @import("linux_types.zig");
const c = t.c;
var opcode: c_int = 0;
pub fn install(window: ?*c.SDL_Window) void {
    if (opcode != 0 or !t.same(c.SDL_GetCurrentVideoDriver(), "x11")) return;
    const display: ?*c.Display = @ptrCast(@alignCast(c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null)));
    if (display == null) return;
    var first_event: c_int = 0;
    var first_error: c_int = 0;
    if (c.XQueryExtension(display, "XInputExtension", &opcode, &first_event, &first_error) == 0) return;
    c.SDL_SetX11EventHook(filter, null);
}
fn filter(_: ?*anyopaque, event: [*c]c.XEvent) callconv(.c) bool {
    // SDL calls the hook before and after loading a generic-event cookie.
    if (event.*.type != c.GenericEvent) return true;
    const cookie = &event.*.xcookie;
    if (cookie.extension != opcode or cookie.data == null or (cookie.evtype != c.XI_ButtonPress and cookie.evtype != c.XI_ButtonRelease)) return true;
    const button: *const c.XIDeviceEvent = @ptrCast(@alignCast(cookie.data.?));
    if (button.detail < 1 or button.detail > 3 or button.deviceid == button.sourceid) return true;
    const focused = c.SDL_GetMouseFocus() orelse return true;
    const target = c.SDL_GetNumberProperty(c.SDL_GetWindowProperties(focused), c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    return target <= 0 or @as(u64, @intCast(target)) != button.event;
}
