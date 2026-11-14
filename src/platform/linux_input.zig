//! SDL event conversion and bounded asynchronous native input batches.
const std = @import("std");
const t = @import("linux_types.zig");
const c = t.c;
const window_api = @import("linux_window.zig");
var wake_event: u32 = 0;
var wake_pending: std.atomic.Value(bool) = .init(false);
pub fn initializeWake() void {
    if (wake_event == 0) wake_event = c.SDL_RegisterEvents(1);
}
pub fn wake() void {
    if (wake_event == 0 or wake_pending.swap(true, .acq_rel)) return;
    var notification = t.zero(c.SDL_Event);
    notification.type = wake_event;
    if (!c.SDL_PushEvent(&notification)) wake_pending.store(false, .release);
}
var selection: t.Selection = .{};
const Phase = enum(u8) { idle, writing, ready, failed, cancelled };
var status: std.atomic.Value(Phase) = .init(.idle);
var drop: enum { idle, collecting, failed } = .idle;
pub const Completion = union(enum) {
    selected: *const t.Selection,
    failed: u32,
    cancelled: u32,
};
fn append(path: [*:0]const u8) bool {
    const value = std.mem.span(path);
    const length = value.len + 1;
    if (value.len == 0 or selection.count == selection.offsets.len or length > selection.bytes.len - selection.used) return false;
    selection.offsets[selection.count] = selection.used;
    selection.count += 1;
    @memcpy(selection.bytes[selection.used..][0..value.len], value);
    selection.bytes[selection.used + value.len] = 0;
    selection.used += @intCast(length);
    return true;
}
fn dialogDone(userdata: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    selection.window_id = @intCast(@intFromPtr(userdata));
    var result: Phase = if (files == null) .failed else if (files[0] == null) .cancelled else .ready;
    if (files != null) {
        var i: usize = 0;
        while (files[i] != null) : (i += 1) if (!append(@ptrCast(files[i]))) {
            result = .failed;
            break;
        };
    }
    status.store(result, .release);
    wake();
}
pub const DialogKind = enum { files, directories };
pub fn openDialog(kind: DialogKind, location_arg: ?[:0]const u8) void {
    if (status.cmpxchgStrong(.idle, .writing, .acquire, .monotonic) != null) return;
    selection.count = 0;
    selection.used = 0;
    var folder: [4096]u8 = undefined;
    var location = location_arg;
    if (kind == .directories) if (location) |value| {
        if (std.mem.lastIndexOfScalar(u8, value, '/')) |slash| {
            if (slash + 1 < folder.len) {
                @memcpy(folder[0 .. slash + 1], value[0 .. slash + 1]);
                folder[slash + 1] = 0;
                location = folder[0 .. slash + 1 :0];
            }
        }
    };
    const window = t.current().window;
    const origin: ?*anyopaque = @ptrFromInt(c.SDL_GetWindowID(window));
    const initial = if (location) |path| path.ptr else null;
    switch (kind) {
        .directories => c.SDL_ShowOpenFolderDialog(dialogDone, origin, window, initial, true),
        .files => c.SDL_ShowOpenFileDialog(dialogDone, origin, window, null, 0, initial, true),
    }
}
/// Only a successful completion exposes paths. Copy before releasing the
/// callback's buffer; the caller owns `out` through its worker handoff.
pub fn take(out: *t.Selection) ?Completion {
    const value = status.load(.acquire);
    const completion: Completion = switch (value) {
        .idle, .writing => return null,
        .ready => selected: {
            out.window_id = selection.window_id;
            out.count = selection.count;
            out.used = selection.used;
            @memcpy(out.offsets[0..selection.count], selection.offsets[0..selection.count]);
            @memcpy(out.bytes[0..selection.used], selection.bytes[0..selection.used]);
            break :selected .{ .selected = out };
        },
        .failed => .{ .failed = selection.window_id },
        .cancelled => .{ .cancelled = selection.window_id },
    };
    status.store(.idle, .release);
    return completion;
}
pub fn testDialog(path: ?[*:0]const u8, outcome: c_int) void {
    if (status.cmpxchgStrong(.idle, .writing, .acquire, .monotonic) != null) return;
    selection.count = 0;
    selection.used = 0;
    const paths = [_][*c]const u8{ if (outcome == 0) null else path, null };
    dialogDone(null, if (outcome < 0) null else &paths, 0);
}
pub fn testDialogWindow(path: [*:0]const u8, id: u32) void {
    if (status.cmpxchgStrong(.idle, .writing, .acquire, .monotonic) != null) return;
    selection.count = 0;
    selection.used = 0;
    const paths = [_][*c]const u8{ path, null };
    dialogDone(@ptrFromInt(id), &paths, 0);
}
pub fn testClose() void {
    var injected = t.zero(c.SDL_Event);
    injected.window = t.zero(c.SDL_WindowEvent);
    injected.window.type = c.SDL_EVENT_WINDOW_CLOSE_REQUESTED;
    injected.window.windowID = window_api.id();
    _ = c.SDL_PushEvent(&injected);
}
pub fn testDrop(path: [*:0]const u8) void {
    const id = if (t.current().window != null) window_api.id() else 0;
    for ([_]u32{ c.SDL_EVENT_DROP_BEGIN, c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_COMPLETE }) |kind| {
        var injected = t.zero(c.SDL_Event);
        injected.drop = t.zero(c.SDL_DropEvent);
        injected.drop.type = kind;
        injected.drop.windowID = id;
        if (kind == c.SDL_EVENT_DROP_FILE) injected.drop.data = path;
        _ = c.SDL_PushEvent(&injected);
    }
}
fn portableKey(key: c.SDL_Keycode) c_int {
    return switch (key) {
        c.SDLK_LEFT => 0xf702,
        c.SDLK_RIGHT => 0xf703,
        c.SDLK_UP => 0xf700,
        c.SDLK_DOWN => 0xf701,
        c.SDLK_HOME => 0xf729,
        c.SDLK_END => 0xf72b,
        c.SDLK_PAGEUP => 0xf72c,
        c.SDLK_PAGEDOWN => 0xf72d,
        c.SDLK_DELETE => 0xf728,
        c.SDLK_BACKSPACE => 0x7f,
        else => if (key <= 0xffff) @intCast(key) else 0,
    };
}
fn scale(window: ?*c.SDL_Window) struct { x: f32, y: f32 } {
    var pw: c_int = 0;
    var ph: c_int = 0;
    var lw: c_int = 0;
    var lh: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &pw, &ph);
    _ = c.SDL_GetWindowSize(window, &lw, &lh);
    return .{ .x = @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(@max(1, lw))), .y = @as(f32, @floatFromInt(ph)) / @as(f32, @floatFromInt(@max(1, lh))) };
}
fn context(window: ?*c.SDL_Window) ?*t.Window {
    return @ptrCast(@alignCast(c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), "yekk.context", null)));
}
pub fn event(out: *t.Event) void {
    out.* = .{};
    var e: c.SDL_Event = undefined;
    if (!c.SDL_WaitEventTimeout(&e, 8)) return;
    if (e.type == wake_event) {
        wake_pending.store(false, .release);
        return;
    }
    out.timestamp = e.common.timestamp;
    switch (e.type) {
        c.SDL_EVENT_QUIT => out.kind = 10,
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
            out.window_id = e.window.windowID;
            out.kind = 1;
        },
        c.SDL_EVENT_KEY_DOWN => {
            out.window_id = e.key.windowID;
            out.kind = 2;
            out.key = portableKey(if (e.key.scancode != c.SDL_SCANCODE_UNKNOWN) c.SDL_GetKeyFromScancode(e.key.scancode, e.key.mod, false) else e.key.key);
            out.modifiers = @as(u32, @intFromBool(e.key.mod & c.SDL_KMOD_SHIFT != 0)) | (@as(u32, @intFromBool(e.key.mod & c.SDL_KMOD_CTRL != 0)) << 1) | (@as(u32, @intFromBool(e.key.mod & c.SDL_KMOD_ALT != 0)) << 2) | (@as(u32, @intFromBool(e.key.mod & c.SDL_KMOD_GUI != 0)) << 3);
        },
        c.SDL_EVENT_DROP_BEGIN => {
            out.window_id = e.drop.windowID;
            drop = if (status.cmpxchgStrong(.idle, .writing, .acquire, .monotonic) == null) .collecting else .idle;
            if (drop == .collecting) {
                selection.count = 0;
                selection.used = 0;
                selection.window_id = e.drop.windowID;
            }
        },
        c.SDL_EVENT_DROP_FILE => {
            if (drop == .collecting and selection.window_id == e.drop.windowID and !append(@ptrCast(e.drop.data))) drop = .failed;
        },
        c.SDL_EVENT_DROP_COMPLETE => {
            if (drop != .idle) status.store(if (drop == .failed) .failed else if (selection.count > 0) .ready else .cancelled, .release);
            drop = .idle;
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            out.mouse_id = e.wheel.which;
            out.window_id = e.wheel.windowID;
            out.kind = 3;
            out.y = e.wheel.y;
            const window = c.SDL_GetWindowFromID(e.wheel.windowID) orelse return;
            const s = scale(window);
            out.anchor_x = e.wheel.mouse_x * s.x;
            out.anchor_y = e.wheel.mouse_y * s.y;
            if (c.SDL_GetModState() & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI) != 0) out.kind = 9 else if (e.wheel.x != 0) {
                out.kind = 4;
                out.x = e.wheel.x * 48;
                out.y = e.wheel.y * 48;
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            out.mouse_id = e.button.which;
            out.window_id = e.button.windowID;
            const window = c.SDL_GetWindowFromID(e.button.windowID) orelse return;
            const w = context(window) orelse return;
            const s = scale(window);
            out.x = e.button.x * s.x;
            out.y = e.button.y * s.y;
            out.key = e.button.button;
            if (e.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN) {
                out.kind = 6;
                w.mouse_distance = 0;
                w.mouse_button = e.button.button;
                w.mouse_anchor_x = out.x;
                w.mouse_anchor_y = out.y;
            } else if (w.mouse_button == e.button.button) {
                out.kind = if (w.mouse_distance < 4) 8 else 12;
                w.mouse_button = 0;
            }
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            out.mouse_id = e.motion.which;
            out.window_id = e.motion.windowID;
            if (e.motion.state & (c.SDL_BUTTON_LMASK | c.SDL_BUTTON_MMASK) != 0) {
                const window = c.SDL_GetWindowFromID(e.motion.windowID) orelse return;
                const w = context(window) orelse return;
                const s = scale(window);
                w.mouse_distance += @abs(e.motion.xrel) + @abs(e.motion.yrel);
                if (e.motion.state & c.SDL_BUTTON_MMASK != 0) {
                    out.kind = 9;
                    out.y = -e.motion.yrel / 48;
                    out.anchor_x = w.mouse_anchor_x;
                    out.anchor_y = w.mouse_anchor_y;
                } else {
                    out.kind = 4;
                    out.x = e.motion.xrel * s.x;
                    out.y = e.motion.yrel * s.y;
                }
            }
        },
        c.SDL_EVENT_WINDOW_FOCUS_GAINED, c.SDL_EVENT_WINDOW_ICCPROF_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
            out.window_id = e.window.windowID;
            out.kind = 11;
        },
        c.SDL_EVENT_WINDOW_MOVED, c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_EXPOSED => {
            if (c.SDL_GetWindowFromID(e.window.windowID)) |window| if (context(window)) |w| {
                window_api.captureNormal(w);
            };
            out.window_id = e.window.windowID;
            out.kind = 5;
        },
        else => {},
    }
}
pub fn testKey(key: c_int) void {
    testKeyMod(key, 0);
}
pub fn testKeyMod(key: c_int, modifiers: c_uint) void {
    var e = t.zero(c.SDL_Event);
    e.key = t.zero(c.SDL_KeyboardEvent);
    e.key.type = c.SDL_EVENT_KEY_DOWN;
    e.key.windowID = window_api.id();
    e.key.key = @intCast(key);
    e.key.mod = @intCast(@as(u32, if (modifiers & 1 != 0) c.SDL_KMOD_SHIFT else 0) | @as(u32, if (modifiers & 2 != 0) c.SDL_KMOD_CTRL else 0) | @as(u32, if (modifiers & 4 != 0) c.SDL_KMOD_ALT else 0) | @as(u32, if (modifiers & 8 != 0) c.SDL_KMOD_GUI else 0));
    _ = c.SDL_PushEvent(&e);
}
pub fn testResize(width: c_int, height: c_int) void {
    _ = c.SDL_SetWindowSize(t.current().window, width, height);
}
