//! Private X11 interoperability fixture: XDND, root ICC, and pixel reads.
const std = @import("std");
const x = @import("x11");
const c = @import("linux_bindings");
fn atom(display: ?*x.Display, name: [*:0]const u8) x.Atom {
    return x.XInternAtom(display, name, 0);
}
fn message(display: ?*x.Display, target: x.Window, kind: x.Atom, values: [5]c_long) void {
    var event = std.mem.zeroes(x.XEvent);
    event.xclient.type = x.ClientMessage;
    event.xclient.window = target;
    event.xclient.message_type = kind;
    event.xclient.format = 32;
    event.xclient.data.l = values;
    _ = x.XSendEvent(display, target, 0, x.NoEventMask, &event);
    _ = x.XFlush(display);
}
fn component(pixel: c_ulong, mask: c_ulong) u8 {
    if (mask == 0) return 0;
    const shift: std.math.Log2Int(c_ulong) = @intCast(@ctz(mask));
    const normalized = mask >> shift;
    return @intCast(((pixel >> shift) & normalized) * 255 / normalized);
}
pub export fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    if (argc < 3) return 2;
    const display = x.XOpenDisplay(null) orelse return 2;
    defer _ = x.XCloseDisplay(display);
    const root = x.XDefaultRootWindow(display);
    const command = std.mem.span(argv[1]);
    if (std.mem.eql(u8, command, "close")) {
        const target = std.fmt.parseInt(x.Window, std.mem.span(argv[2]), 0) catch return 2;
        message(display, target, atom(display, "WM_PROTOCOLS"), .{ @intCast(atom(display, "WM_DELETE_WINDOW")), x.CurrentTime, 0, 0, 0 });
        _ = x.XSync(display, 0);
        return 0;
    }
    if (std.mem.eql(u8, command, "screen")) {
        const screen = x.XDefaultScreen(display);
        const width = x.XDisplayWidth(display, screen);
        const height = x.XDisplayHeight(display, screen);
        const image = x.XGetImage(display, root, 0, 0, @intCast(width), @intCast(height), std.math.maxInt(c_ulong), x.ZPixmap) orelse return 2;
        defer _ = image.*.f.destroy_image.?(image);
        _ = c.printf("P6\n%d %d\n255\n", width, height);
        var y: c_int = 0;
        while (y < height) : (y += 1) {
            var col: c_int = 0;
            while (col < width) : (col += 1) {
                const pixel = image.*.f.get_pixel.?(image, col, y);
                const rgb = [_]u8{ component(pixel, image.*.red_mask), component(pixel, image.*.green_mask), component(pixel, image.*.blue_mask) };
                _ = c.fwrite(&rgb, 1, 3, c.stdout);
            }
        }
        return 0;
    }
    if (std.mem.eql(u8, command, "pixel")) {
        const target = std.fmt.parseInt(x.Window, std.mem.span(argv[2]), 0) catch return 2;
        var attrs: x.XWindowAttributes = undefined;
        if (x.XGetWindowAttributes(display, target, &attrs) == 0) return 2;
        const image = x.XGetImage(display, target, @divTrunc(attrs.width, 2), @divTrunc(attrs.height, 2), 1, 1, std.math.maxInt(c_ulong), x.ZPixmap) orelse return 2;
        defer _ = image.*.f.destroy_image.?(image);
        const pixel = image.*.f.get_pixel.?(image, 0, 0);
        _ = c.printf("[%u,%u,%u]\n", @as(c_uint, component(pixel, attrs.visual.*.red_mask)), @as(c_uint, component(pixel, attrs.visual.*.green_mask)), @as(c_uint, component(pixel, attrs.visual.*.blue_mask)));
        return 0;
    }
    if (std.mem.eql(u8, command, "profile")) {
        const gamma = std.fmt.parseFloat(f64, std.mem.span(argv[2])) catch return 2;
        const property = atom(display, "_ICC_PROFILE");
        if (gamma <= 0) {
            _ = x.XDeleteProperty(display, root, property);
        } else {
            const white: c.cmsCIExyY = .{ .x = 0.3127, .y = 0.3290, .Y = 1 };
            const primaries: c.cmsCIExyYTRIPLE = .{ .Red = .{ .x = 0.64, .y = 0.33, .Y = 1 }, .Green = .{ .x = 0.30, .y = 0.60, .Y = 1 }, .Blue = .{ .x = 0.15, .y = 0.06, .Y = 1 } };
            const curve = c.cmsBuildGamma(null, gamma) orelse return 2;
            defer c.cmsFreeToneCurve(curve);
            const curves = [_]?*c.cmsToneCurve{ curve, curve, curve };
            const profile = c.cmsCreateRGBProfile(&white, &primaries, &curves) orelse return 2;
            defer _ = c.cmsCloseProfile(profile);
            var size: u32 = 0;
            if (c.cmsSaveProfileToMem(profile, null, &size) == 0) return 2;
            const data = c.g_malloc(size) orelse return 2;
            defer c.g_free(data);
            if (c.cmsSaveProfileToMem(profile, data, &size) == 0) return 2;
            _ = x.XChangeProperty(display, root, property, x.XA_CARDINAL, 8, x.PropModeReplace, @ptrCast(data), @intCast(size));
        }
        _ = x.XSync(display, 0);
        return 0;
    }
    if (!std.mem.eql(u8, command, "drop") or argc != 4) return 2;
    const target = std.fmt.parseInt(x.Window, std.mem.span(argv[2]), 0) catch return 2;
    const source = x.XCreateSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0);
    defer _ = x.XDestroyWindow(display, source);
    const selection = atom(display, "XdndSelection");
    const uri_type = atom(display, "text/uri-list");
    const status = atom(display, "XdndStatus");
    const drop = atom(display, "XdndDrop");
    const finished = atom(display, "XdndFinished");
    const uri = c.g_filename_to_uri(argv[3], null, null);
    if (uri == null) return 2;
    defer c.g_free(uri);
    const body = c.g_strconcat(uri, @as([*:0]const u8, "\r\n"), @as(?*anyopaque, null));
    if (body == null) return 2;
    defer c.g_free(body);
    _ = x.XSetSelectionOwner(display, selection, source, x.CurrentTime);
    message(display, target, atom(display, "XdndEnter"), .{ @intCast(source), 5 << 24, @intCast(uri_type), 0, 0 });
    var child: x.Window = 0;
    var left: c_int = 0;
    var top: c_int = 0;
    _ = x.XTranslateCoordinates(display, target, root, 20, 20, &left, &top, &child);
    message(display, target, atom(display, "XdndPosition"), .{ @intCast(source), 0, (@as(c_long, left) << 16) | (top & 0xffff), x.CurrentTime, @intCast(atom(display, "XdndActionCopy")) });
    const deadline = c.g_get_monotonic_time() + 15000000;
    while (c.g_get_monotonic_time() < deadline) {
        if (x.XPending(display) == 0) {
            var fd: c.struct_pollfd = .{ .fd = x.XConnectionNumber(display), .events = c.POLLIN, .revents = 0 };
            _ = c.poll(&fd, 1, 50);
            continue;
        }
        var e: x.XEvent = undefined;
        _ = x.XNextEvent(display, &e);
        if (e.type == x.ClientMessage and e.xclient.message_type == status) {
            if (e.xclient.data.l[1] & 1 == 0) return 1;
            message(display, target, drop, .{ @intCast(source), 0, x.CurrentTime, 0, 0 });
        } else if (e.type == x.SelectionRequest) {
            const request = e.xselectionrequest;
            const property = if (request.property != 0) request.property else request.target;
            _ = x.XChangeProperty(display, request.requestor, property, uri_type, 8, x.PropModeReplace, body, @intCast(std.mem.span(body).len));
            var response = std.mem.zeroes(x.XEvent);
            response.xselection.type = x.SelectionNotify;
            response.xselection.requestor = request.requestor;
            response.xselection.selection = request.selection;
            response.xselection.target = request.target;
            response.xselection.property = property;
            response.xselection.time = request.time;
            _ = x.XSendEvent(display, request.requestor, 0, x.NoEventMask, &response);
            _ = x.XFlush(display);
        } else if (e.type == x.ClientMessage and e.xclient.message_type == finished) {
            if (e.xclient.data.l[1] & 1 == 0) return 1;
            _ = c.puts("DROP_SENT");
            return 0;
        }
    }
    return 1;
}
