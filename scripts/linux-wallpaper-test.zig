//! Test the portal request on a private bus without changing desktop settings.
const c = @import("linux_bindings");
const std = @import("std");

const Fixture = struct {
    loop: *c.GMainLoop,
    matched: bool = false,
};
fn call(connection: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, parameters: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, userdata: ?*anyopaque) callconv(.c) void {
    const fixture: *Fixture = @ptrCast(@alignCast(userdata.?));
    defer c.g_main_loop_quit(fixture.loop);
    fixture.matched = respond(connection.?, sender, method, parameters.?, invocation.?) catch false;
    if (!fixture.matched) c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.portal.Error.Failed", "Invalid wallpaper data");
}
fn respond(connection: *c.GDBusConnection, sender: [*c]const u8, method: [*c]const u8, parameters: *c.GVariant, invocation: *c.GDBusMethodInvocation) !bool {
    if (!std.mem.eql(u8, std.mem.span(method), "SetWallpaperFile")) return false;
    const options = c.g_variant_get_child_value(parameters, 2) orelse return false;
    defer c.g_variant_unref(options);
    var token: [*c]const u8 = null;
    var setting: [*c]const u8 = null;
    if (c.g_variant_lookup(options, "handle_token", "&s", &token) == 0 or
        c.g_variant_lookup(options, "set-on", "&s", &setting) == 0 or
        !std.mem.eql(u8, std.mem.span(setting), "background")) return false;
    const fd_handle = c.g_variant_get_child_value(parameters, 1) orelse return false;
    defer c.g_variant_unref(fd_handle);
    const fds = c.g_dbus_message_get_unix_fd_list(c.g_dbus_method_invocation_get_message(invocation)) orelse return false;
    const fd = c.g_unix_fd_list_get(fds, c.g_variant_get_handle(fd_handle), null);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var png: [24]u8 = undefined;
    if (c.read(fd, &png, png.len) != png.len or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return false;
    if (std.mem.readInt(u32, png[16..20], .big) == 0 or std.mem.readInt(u32, png[20..24], .big) == 0) return false;
    var request_buffer: [256]u8 = undefined;
    const request = try std.fmt.bufPrintSentinel(&request_buffer, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ std.mem.span(sender)[1..], std.mem.span(token) }, 0);
    for (request_buffer[0..request.len]) |*byte| if (byte.* == '.') {
        byte.* = '_';
    };
    c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(o)", request.ptr));
    const vartype: *const c.GVariantType = @ptrCast("{sv}");
    const dict = c.g_variant_new_array(vartype, null, 0);
    return c.g_dbus_connection_emit_signal(connection, sender, request.ptr, "org.freedesktop.portal.Request", "Response", c.g_variant_new("(u@a{sv})", @as(c_uint, 0), dict), null) != 0;
}
pub export fn main() c_int {
    var err: [*c]c.GError = null;
    defer if (err != null) c.g_error_free(err);
    const connection = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse return 2;
    defer c.g_object_unref(connection);
    const name = c.g_dbus_connection_call_sync(connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", c.g_variant_new("(su)", @as([*:0]const u8, "org.freedesktop.portal.Desktop"), @as(c_uint, 0)), null, c.G_DBUS_CALL_FLAGS_NONE, 5000, null, &err) orelse return 2;
    defer c.g_variant_unref(name);
    const info = c.g_dbus_node_info_new_for_xml("<node><interface name='org.freedesktop.portal.Wallpaper'><method name='SetWallpaperFile'><arg type='s' direction='in'/><arg type='h' direction='in'/><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method></interface></node>", &err) orelse return 2;
    defer c.g_dbus_node_info_unref(info);
    var fixture: Fixture = .{ .loop = c.g_main_loop_new(null, 0) orelse return 2 };
    defer c.g_main_loop_unref(fixture.loop);
    var table = std.mem.zeroes(c.GDBusInterfaceVTable);
    table.method_call = call;
    const id = c.g_dbus_connection_register_object(connection, "/org/freedesktop/portal/desktop", info.*.interfaces[0], &table, &fixture, null, &err);
    if (id == 0) return 2;
    defer _ = c.g_dbus_connection_unregister_object(connection, id);
    _ = c.puts("READY");
    _ = c.fflush(c.stdout);
    c.g_main_loop_run(fixture.loop);
    _ = c.g_dbus_connection_flush_sync(connection, null, null);
    return if (fixture.matched) 0 else 1;
}
