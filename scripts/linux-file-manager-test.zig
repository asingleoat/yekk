//! Private D-Bus fixture; never contacts the user's desktop bus.
const c = @import("linux_bindings");
const std = @import("std");
const Fixture = struct { loop: ?*c.GMainLoop, uri: [*c]const u8, matched: bool = false };
fn call(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, parameters: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, userdata: ?*anyopaque) callconv(.c) void {
    const fixture: *Fixture = @ptrCast(@alignCast(userdata.?));
    const values = c.g_variant_get_child_value(parameters, 0);
    defer c.g_variant_unref(values);
    var count: usize = 0;
    const uris = c.g_variant_dup_strv(values, &count);
    defer c.g_strfreev(uris);
    fixture.matched = std.mem.eql(u8, std.mem.span(method), "ShowItems") and count == 1 and std.mem.eql(u8, std.mem.span(uris[0]), std.mem.span(fixture.uri));
    c.g_dbus_method_invocation_return_value(invocation, null);
    c.g_main_loop_quit(fixture.loop);
}
pub export fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    if (argc != 2) return 2;
    var err: [*c]c.GError = null;
    defer if (err != null) {
        _ = c.fprintf(c.stderr, "%s\n", err.*.message);
        c.g_error_free(err);
    };
    const connection = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &err) orelse return 2;
    defer c.g_object_unref(connection);
    const reply_type: *const c.GVariantType = @ptrCast("(u)");
    const name = c.g_dbus_connection_call_sync(connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", c.g_variant_new("(su)", @as([*:0]const u8, "org.freedesktop.FileManager1"), @as(c_uint, 0)), reply_type, c.G_DBUS_CALL_FLAGS_NONE, 5000, null, &err) orelse return 2;
    c.g_variant_unref(name);
    const info = c.g_dbus_node_info_new_for_xml("<node><interface name='org.freedesktop.FileManager1'><method name='ShowItems'><arg name='URIs' type='as' direction='in'/><arg name='StartupId' type='s' direction='in'/></method></interface></node>", &err) orelse return 2;
    defer c.g_dbus_node_info_unref(info);
    const file = c.g_file_new_for_path(argv[1]);
    defer c.g_object_unref(file);
    const uri = c.g_file_get_uri(file);
    defer c.g_free(uri);
    var fixture: Fixture = .{ .loop = c.g_main_loop_new(null, 0), .uri = uri };
    defer c.g_main_loop_unref(fixture.loop);
    var table = std.mem.zeroes(c.GDBusInterfaceVTable);
    table.method_call = call;
    const id = c.g_dbus_connection_register_object(connection, "/org/freedesktop/FileManager1", info.*.interfaces[0], &table, &fixture, null, &err);
    if (id == 0) return 2;
    defer _ = c.g_dbus_connection_unregister_object(connection, id);
    _ = c.puts("READY");
    _ = c.fflush(c.stdout);
    c.g_main_loop_run(fixture.loop);
    _ = c.g_dbus_connection_flush_sync(connection, null, null);
    _ = c.puts(if (fixture.matched) "REVEALED" else "MISMATCH");
    return if (fixture.matched) 0 else 1;
}
