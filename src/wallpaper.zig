//! Portable wallpaper layouts. Platform services apply the composed image.
const std = @import("std");
const c = @import("system");
pub const Mode = enum { center, fill, max, scale, tile };
pub const Size = struct { width: u32, height: u32 };
pub const Box = struct { x: f64, y: f64, width: f64, height: f64 };

pub fn placement(mode: Mode, screen: Size, image: Size, geometry: ?@import("geometry").Geometry) Box {
    const width: f64 = @floatFromInt(screen.width);
    const height: f64 = @floatFromInt(screen.height);
    const iw: f64 = @floatFromInt(image.width);
    const ih: f64 = @floatFromInt(image.height);
    const scale = switch (mode) {
        .center, .tile => 1,
        .fill => @max(width / iw, height / ih),
        .max => @min(width / iw, height / ih),
        .scale => return .{ .x = 0, .y = 0, .width = width, .height = height },
    };
    const w = @max(1, @round(scale * iw));
    const h = @max(1, @round(scale * ih));
    if (mode == .tile) return .{ .x = 0, .y = 0, .width = w, .height = h };
    const position = if (geometry) |value| value.position else null;
    return .{
        .x = if (position) |offset| offset.x.resolve(width - w) else @floor((width - w) / 2),
        .y = if (position) |offset| offset.y.resolve(height - h) else @floor((height - h) / 2),
        .width = w,
        .height = h,
    };
}

pub fn macDirectory(buffer: []u8) ![:0]const u8 {
    const home = c.getenv("HOME");
    if (home == null or !std.fs.path.isAbsolute(std.mem.span(home))) return error.WallpaperDirectoryUnavailable;
    const directory = try std.fmt.bufPrintSentinel(buffer, "{s}/Library/Application Support/Yekk", .{std.mem.span(home)}, 0);
    if (c.mkdir(directory.ptr, 0o700) != 0 and @import("runtime").errno().* != c.EEXIST) return error.WallpaperDirectoryUnavailable;
    return directory;
}
