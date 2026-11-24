//! Worker-only GIO desktop operations and Linux memory pressure observation.
const std = @import("std");
const t = @import("linux_types.zig");
const c = t.c;
pub fn action(path: [*:0]const u8, kind: c_int) c_int {
    const file = c.g_file_new_for_path(path);
    defer t.unref(file);
    var err: [*c]c.GError = null;
    defer if (err != null) {
        _ = c.fprintf(c.stderr, "desktop operation: %s\n", err.*.message);
        c.g_error_free(err);
    };
    if (kind == 1) return if (c.g_file_trash(file, null, &err) != 0) 0 else -1;
    if (kind == 2) {
        const uri = c.g_file_get_uri(file);
        defer c.g_free(uri);
        const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse return -1;
        defer t.unref(bus);
        const uris = [_][*c]const u8{ uri, null };
        const reply = c.g_dbus_connection_call_sync(bus, "org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems", c.g_variant_new("(^ass)", &uris, @as([*:0]const u8, "")), null, c.G_DBUS_CALL_FLAGS_NONE, 5000, null, &err) orelse return -1;
        c.g_variant_unref(reply);
        return 0;
    }
    const app = c.g_file_query_default_handler(file, null, &err) orelse return -1;
    defer t.unref(app);
    const executable = c.g_app_info_get_executable(app);
    const id = c.g_app_info_get_id(app);
    const program = if (executable != null) c.g_find_program_in_path(executable) else null;
    defer c.g_free(program);
    const self = t.same(id, "yekk.desktop") or sameFile(program, "/proc/self/exe") or
        sameFile(program, c.getenv("YEKK_ENTRY_EXECUTABLE")) or
        sameFile(program, c.getenv("YEKK_NATIVE_EXECUTABLE"));
    const test_root = c.getenv("YEKK_TEST_DESKTOP_ROOT");
    const allowed = test_root == null or (program != null and std.mem.startsWith(u8, t.text(program), t.text(test_root)) and t.text(program).len > t.text(test_root).len and t.text(program)[t.text(test_root).len] == '/');
    if (self or !allowed) {
        _ = c.fprintf(c.stderr, "external open refused: self handler or unapproved test handler\n");
        return -1;
    }
    const context = c.g_app_launch_context_new();
    defer t.unref(context);
    var files = t.zero(c.GList);
    files.data = file;
    return if (c.g_app_info_launch(app, &files, context, &err) != 0) 0 else -1;
}
fn sameFile(first: [*c]const u8, second: [*c]const u8) bool {
    if (first == null or second == null) return false;
    var a: c.struct_stat = undefined;
    var b: c.struct_stat = undefined;
    return c.stat(first, &a) == 0 and c.stat(second, &b) == 0 and
        a.st_dev == b.st_dev and a.st_ino == b.st_ino;
}
pub fn pressureOpen() c_int {
    const w = t.current();
    w.pressure_trigger = false;
    const fd = c.open("/proc/pressure/memory", c.O_RDWR | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return c.open("/proc/pressure/memory", c.O_RDONLY | c.O_CLOEXEC);
    const trigger = "some 150000 2000000";
    if (c.write(fd, trigger, trigger.len) != trigger.len) {
        _ = c.close(fd);
        return c.open("/proc/pressure/memory", c.O_RDONLY | c.O_CLOEXEC);
    }
    w.pressure_trigger = true;
    return fd;
}
pub fn pressureCheck(fd: c_int) c_int {
    if (fd < 0) return 0;
    const w = t.current();
    const now = c.g_get_monotonic_time();
    if (now - w.psi_checked < 250000) return 0;
    w.psi_checked = now;
    var p: c.struct_pollfd = .{ .fd = fd, .events = c.POLLPRI, .revents = 0 };
    var triggered = w.pressure_trigger and c.poll(&p, 1, 0) > 0 and p.revents & c.POLLPRI != 0 and p.revents & c.POLLERR == 0;
    var buffer: [512]u8 = undefined;
    const count = c.pread(fd, &buffer, buffer.len, 0);
    if (count > 0) {
        const text = buffer[0..@intCast(count)];
        if (std.mem.indexOf(u8, text, "total=")) |index| {
            var words = std.mem.tokenizeAny(u8, text[index + 6 ..], " \r\n");
            if (std.fmt.parseInt(u64, words.next() orelse "", 10)) |value| {
                if (!w.psi_initialized or now - w.psi_window_started >= 2000000) {
                    if (w.psi_initialized and value -| w.psi_last_total >= 150000) triggered = true;
                    w.psi_initialized = true;
                    w.psi_last_total = value;
                    w.psi_window_started = now;
                }
            } else |_| {}
        }
    }
    return @intFromBool(triggered);
}
pub fn pressureClose(fd: c_int) void {
    if (fd >= 0) {
        _ = c.close(fd);
    }
}

const wallpaper_bus: [:0]const u8 = "org.freedesktop.portal.Desktop";
const Response = struct { loop: *c.GMainLoop, code: c_uint = 2 };
fn wallpaperResponse(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, parameters: ?*c.GVariant, userdata: ?*anyopaque) callconv(.c) void {
    const state: *Response = @ptrCast(@alignCast(userdata.?));
    if (parameters) |value| {
        const code = c.g_variant_get_child_value(value, 0);
        if (code != null) {
            defer c.g_variant_unref(code);
            state.code = c.g_variant_get_uint32(code);
        }
    }
    c.g_main_loop_quit(state.loop);
}
fn wallpaperTimeout(userdata: ?*anyopaque) callconv(.c) c.gboolean {
    const state: *Response = @ptrCast(@alignCast(userdata.?));
    c.g_main_loop_quit(state.loop);
    return 0;
}
pub fn setWallpaper(fd: c_int) !void {
    var err: ?*c.GError = null;
    defer if (err) |value| c.g_error_free(value);
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse return error.WallpaperPortalUnavailable;
    defer t.unref(bus);
    const context = c.g_main_context_new() orelse return error.OutOfMemory;
    defer c.g_main_context_unref(context);
    c.g_main_context_push_thread_default(context);
    defer c.g_main_context_pop_thread_default(context);
    const loop = c.g_main_loop_new(context, 0) orelse return error.OutOfMemory;
    defer c.g_main_loop_unref(loop);
    const files = c.g_unix_fd_list_new() orelse return error.OutOfMemory;
    defer t.unref(files);
    const index = c.g_unix_fd_list_append(files, fd, &err);
    if (index < 0) return error.WallpaperPortalUnavailable;

    var token_buffer: [96]u8 = undefined;
    const token = try std.fmt.bufPrintSentinel(&token_buffer, "yekk_{x}_{x}", .{ c.getpid(), @as(u64, @bitCast(c.g_get_monotonic_time())) }, 0);
    const sender = t.text(c.g_dbus_connection_get_unique_name(bus));
    if (sender.len < 2 or sender[0] != ':') return error.WallpaperPortalUnavailable;
    var path_buffer: [256]u8 = undefined;
    const request = try std.fmt.bufPrintSentinel(&path_buffer, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ sender[1..], token }, 0);
    for (path_buffer[0..request.len]) |*byte| if (byte.* == '.') {
        byte.* = '_';
    };
    var state: Response = .{ .loop = loop };
    const subscription = c.g_dbus_connection_signal_subscribe(bus, wallpaper_bus, "org.freedesktop.portal.Request", "Response", request.ptr, null, c.G_DBUS_SIGNAL_FLAGS_NONE, wallpaperResponse, &state, null);
    defer c.g_dbus_connection_signal_unsubscribe(bus, subscription);
    const timeout = c.g_timeout_source_new(30000) orelse return error.OutOfMemory;
    defer c.g_source_unref(timeout);
    c.g_source_set_callback(timeout, wallpaperTimeout, &state, null);
    _ = c.g_source_attach(timeout, context);
    defer c.g_source_destroy(timeout);

    const dictionary_type = c.g_variant_type_new("a{sv}") orelse return error.OutOfMemory;
    defer c.g_variant_type_free(dictionary_type);
    const dict = c.g_variant_builder_new(dictionary_type) orelse return error.OutOfMemory;
    defer c.g_variant_builder_unref(dict);
    c.g_variant_builder_add(dict, "{sv}", @as([*:0]const u8, "handle_token"), c.g_variant_new_string(token.ptr));
    c.g_variant_builder_add(dict, "{sv}", @as([*:0]const u8, "set-on"), c.g_variant_new_string("background"));
    c.g_variant_builder_add(dict, "{sv}", @as([*:0]const u8, "show-preview"), c.g_variant_new_boolean(0));
    const args = c.g_variant_new("(sh@a{sv})", @as([*:0]const u8, ""), index, c.g_variant_builder_end(dict));
    const reply = c.g_dbus_connection_call_with_unix_fd_list_sync(bus, wallpaper_bus, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Wallpaper", "SetWallpaperFile", args, null, c.G_DBUS_CALL_FLAGS_NONE, 5000, files, null, null, &err) orelse return error.WallpaperPortalUnavailable;
    defer c.g_variant_unref(reply);
    const handle = c.g_variant_get_child_value(reply, 0) orelse return error.WallpaperPortalUnavailable;
    defer c.g_variant_unref(handle);
    if (!std.mem.eql(u8, t.text(c.g_variant_get_string(handle, null)), request)) return error.WallpaperPortalUnavailable;
    c.g_main_loop_run(loop);
    if (state.code != 0) return error.WallpaperNotApplied;
}
