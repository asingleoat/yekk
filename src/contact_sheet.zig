//! Layout and compose contact sheets with one canvas. Native encoders write
//! the finished image, and the viewer can reuse the tile positions for clicks.
const std = @import("std");
const c = @import("system");
const runtime = @import("runtime");
const catalog = @import("catalog.zig");
const hooks = @import("hooks.zig");
const memory = @import("memory.zig");
const output = @import("image_output.zig");

pub const Options = struct {
    mode: enum { viewer, montage, index, fullindex, thumbnails } = .viewer,
    destination: ?[:0]const u8 = null,
    output_only: bool = false,
    thumb_width: u16 = 60,
    thumb_height: u16 = 60,
    limit_width: ?u16 = null,
    limit_height: ?u16 = null,
    label: ?[:0]const u8 = null,
    background: ?[:0]const u8 = null,
    opacity: u8 = 255,
    stretch: bool = false,
    ignore_aspect: bool = false,
    cache: bool = false,
    font: ?@import("typography.zig").Font = null,
    title_font: ?@import("typography.zig").Font = null,
    title: ?[:0]const u8 = null,
    redraw: u32 = 10,

    pub fn labels(self: Options) [:0]const u8 {
        if (self.mode == .montage) return "";
        return self.label orelse if (self.mode == .fullindex) "%n\\n%S\\n%wx%h" else "%n";
    }
};
pub const Layout = struct {
    width: u32,
    height: u32,
    columns: u32,
    cell_width: u32,
    cell_height: u32,
    count: usize,
    heading: u32,

    fn init(options: Options, count: usize) !Layout {
        if (count == 0) return error.NoImagesFound;
        const label = options.labels();
        var rows: u32 = if (label.len == 0) 0 else 1;
        rows += @intCast(std.mem.count(u8, label, "\n") + std.mem.count(u8, label, "\\n"));
        const cell_width: u32 = options.thumb_width;
        const line_height: u32 = if (options.font) |font| @as(u32, font.points) + 5 else 16;
        const cell_height: u32 = @as(u32, options.thumb_height) + rows * line_height;
        const heading: u32 = if (options.title_font) |font| @as(u32, font.points) + 8 else 0;
        const max_width: u32 = options.limit_width orelse 800;
        const max_rows: u32 = if (options.limit_height) |height| (height -| heading) / cell_height else std.math.maxInt(u32);
        if (max_rows == 0) return error.InvalidContactSheet;
        const cols_needed: u32 = @intCast(std.math.divCeil(usize, count, max_rows) catch unreachable);
        const allowed = if (options.limit_height != null and options.limit_width == null)
            cols_needed
        else
            @max(1, max_width / cell_width);
        const columns: u32 = @min(count, allowed);
        const actual_rows = @min(max_rows, std.math.divCeil(u32, @intCast(count), columns) catch unreachable);
        const needed_width = try std.math.mul(u32, columns, cell_width);
        const needed_height = try std.math.add(u32, heading, try std.math.mul(u32, actual_rows, cell_height));
        return .{
            .width = options.limit_width orelse if (options.limit_height == null) @min(needed_width, max_width) else needed_width,
            .height = options.limit_height orelse needed_height,
            .columns = columns,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .count = @min(count, @as(usize, columns) * actual_rows),
            .heading = heading,
        };
    }

    pub fn hit(self: Layout, x: f64, y: f64) ?usize {
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or y < 0 or x >= @as(f64, @floatFromInt(self.width)) or y >= @as(f64, @floatFromInt(self.height))) return null;
        const col = @as(u32, @intFromFloat(x)) / self.cell_width;
        const py: u32 = @intFromFloat(y);
        if (py < self.heading) return null;
        const row = (py - self.heading) / self.cell_height;
        if (col >= self.columns) return null;
        const index = @as(usize, row) * self.columns + col;
        return if (index < self.count) index else null;
    }
};

pub const Canvas = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn row(self: Canvas, y: usize) []u8 {
        return self.pixels[y * @as(usize, self.width) * 4 ..][0 .. @as(usize, self.width) * 4];
    }

    pub fn preview(self: Canvas, target: Canvas) void {
        const area = fit(.{ .width = target.width, .height = target.height }, self.width, self.height, .{ .stretch = false });
        const background = [4]u8{ 24, 24, 24, 255 };
        for (0..target.height) |y| {
            const row_pixels = std.mem.bytesAsSlice([4]u8, target.row(y));
            if (y < area.y or y >= area.y + area.height) {
                @memset(row_pixels, background);
                continue;
            }
            const input = std.mem.bytesAsSlice([4]u8, self.row((y - area.y) * @as(usize, self.height) / area.height));
            @memset(row_pixels[0..area.x], background);
            for (row_pixels[area.x..][0..area.width], 0..) |*to, x| {
                const from = input[x * @as(usize, self.width) / area.width];
                for (0..3) |channel| to[channel] = from[channel] +| @as(u8, @intCast((24 * @as(u16, 255 - from[3]) + 127) / 255));
                to[3] = 255;
            }
            @memset(row_pixels[area.x + area.width ..], background);
        }
    }
};
pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
};
pub fn fit(container: Rect, width: u32, height: u32, options: Options) Rect {
    if (options.ignore_aspect) return container;
    var scale = @min(@as(f64, @floatFromInt(container.width)) / @as(f64, @floatFromInt(width)), @as(f64, @floatFromInt(container.height)) / @as(f64, @floatFromInt(height)));
    if (!options.stretch) scale = @min(1, scale);
    const w: u32 = @intFromFloat(@max(1, @round(scale * @as(f64, @floatFromInt(width)))));
    const h: u32 = @intFromFloat(@max(1, @round(scale * @as(f64, @floatFromInt(height)))));
    return .{ .x = container.x + (container.width - w) / 2, .y = container.y + (container.height - h) / 2, .width = w, .height = h };
}
pub fn composite(destination: *[4]u8, rgb: *const [3]u8, opacity: u8) void {
    const source: u16 = opacity;
    const keep: u16 = 255 - source;
    for (0..3) |channel| destination[channel] = @intCast((@as(u16, rgb[channel]) * source + @as(u16, destination[channel]) * keep + 127) / 255);
    destination[3] = @intCast(source + (@as(u16, destination[3]) * keep + 127) / 255);
}

fn cacheDirectory(output_buf: []u8) ![:0]const u8 {
    var parent_buf: [4096]u8 = undefined;
    const xdg = c.getenv("XDG_CACHE_HOME");
    const home = c.getenv("HOME");
    const parent = if (xdg != null and std.fs.path.isAbsolute(std.mem.span(xdg)))
        std.mem.span(xdg)
    else if (home != null and std.fs.path.isAbsolute(std.mem.span(home)))
        try std.fmt.bufPrintSentinel(&parent_buf, "{s}/.cache", .{std.mem.span(home)}, 0)
    else
        return error.CacheDirectoryUnavailable;
    if (c.mkdir(parent.ptr, 0o700) != 0 and runtime.errno().* != c.EEXIST) return error.CacheDirectoryUnavailable;
    const directory = try std.fmt.bufPrintSentinel(output_buf, "{s}/yekk-thumbnails", .{parent}, 0);
    if (c.mkdir(directory.ptr, 0o700) != 0 and runtime.errno().* != c.EEXIST) return error.CacheDirectoryUnavailable;
    return directory;
}
fn cacheName(buffer: []u8, directory: [:0]const u8, entry: catalog.Entry, region: Rect, options: Options) ![:0]const u8 {
    var args: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&args, "{d} {d} {d} {d} {any} {any}", .{ entry.bytes, entry.mtime, region.width, region.height, options.stretch, options.ignore_aspect });
    var hash = std.crypto.hash.Blake3.init(.{});
    hash.update(entry.path);
    hash.update(text);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bufPrintSentinel(buffer, "{s}/{x}.png", .{ directory, digest }, 0);
}
const Cache = struct {
    directory: [:0]const u8,
    scratch: []u8,

    fn tile(self: Cache, canvas: Canvas, entry: catalog.Entry, region: Rect, options: Options, state: *const catalog.Catalog, backend: anytype) !catalog.Dimensions {
        if (entry.downloaded) return backend.tile(canvas, entry.path, region, options);
        var filename: [4096]u8 = undefined;
        const path = cacheName(&filename, self.directory, entry, region, options) catch return backend.tile(canvas, entry.path, region, options);
        var cached_opts = options;
        cached_opts.ignore_aspect = true;
        if (c.access(path.ptr, c.R_OK) == 0) {
            if (backend.tile(canvas, path, region, cached_opts)) |_| {
                if (state.probe) |probe| if (probe(entry.path, state.cancel)) |info| return info.size;
                return .{};
            } else |_| {}
        }
        const tile_canvas: Canvas = .{ .pixels = self.scratch[0 .. @as(usize, region.width) * region.height * 4], .width = region.width, .height = region.height };
        @memset(tile_canvas.pixels, 0);
        var unblended = options;
        unblended.opacity = 255;
        const extent = try backend.tile(tile_canvas, entry.path, .{ .width = region.width, .height = region.height }, unblended);
        for (0..region.height) |y| {
            const source = tile_canvas.row(y);
            const target = canvas.row(region.y + y)[@as(usize, region.x) * 4 ..];
            for (0..region.width) |x| {
                const rgba = source[x * 4 ..][0..4];
                const dst = target[x * 4 ..][0..4];
                const alpha: u16 = (@as(u16, rgba[3]) * options.opacity + 127) / 255;
                for (0..4) |channel| {
                    dst[channel] = @intCast((@as(u16, rgba[channel]) * options.opacity + @as(u16, dst[channel]) * (255 - alpha) + 127) / 255);
                }
            }
        }
        publish(tile_canvas, path, self.directory, backend) catch {};
        return extent;
    }
    fn publish(canvas: Canvas, path: [:0]const u8, directory: [:0]const u8, backend: anytype) !void {
        var staged: output.Temporary = .{};
        defer staged.deinit();
        try staged.create(directory, .png);
        try backend.encode(canvas, staged.path(), .png);
        try staged.replace(path);
    }
};

pub const Gallery = struct {
    layout: ?Layout = null,
    original_first: catalog.Entry = undefined,
    path: [4096]u8 = undefined,
    path_len: usize = 0,
    original_count: usize = 0,
    progress: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),

    pub const Tile = struct {
        entry: catalog.Entry,
        position: usize,

        pub fn snapshot(self: Tile, view: hooks.Snapshot, count: usize) hooks.Snapshot {
            var image = view;
            image.path = self.entry.path;
            image.index = self.position + 1;
            image.count = count;
            image.mode = .thumbnails;
            image.bytes = @intCast(@max(0, self.entry.bytes));
            image.width = 0;
            image.height = 0;
            return image;
        }
    };

    pub fn imageAt(self: *const Gallery, state: *const catalog.Catalog, x: f64, y: f64) ?Tile {
        const layout = self.layout orelse return null;
        const index = layout.hit(x, y) orelse return null;
        return .{ .entry = if (index == 0) self.original_first else state.entries[index], .position = index };
    }
    pub fn saveFilelist(self: *const Gallery, path: [:0]const u8, state: *const catalog.Catalog) !void {
        return @import("session_input.zig").saveWithFirst(path, state.entries[0..self.original_count], self.original_first);
    }
    pub fn build(self: *Gallery, state: *catalog.Catalog, options: Options, temporary_directory: [:0]const u8, context: anytype, backend: anytype) !void {
        const entries = state.entries[0..state.count];
        const layout = try Layout.init(options, entries.len);
        self.total.store(layout.count, .release);
        const count = try std.math.mul(usize, layout.width, layout.height);
        const allocator = memory.allocator();
        const bytes = try allocator.alloc(u8, try std.math.mul(usize, count, 4));
        defer allocator.free(bytes);
        const canvas: Canvas = .{ .pixels = bytes, .width = layout.width, .height = layout.height };
        @memset(bytes, 0);
        if (options.background == null or !std.mem.eql(u8, options.background.?, "trans")) {
            for (0..count) |index| bytes[index * 4 + 3] = 255;
        }
        if (options.background) |background| if (!std.mem.eql(u8, background, "trans")) {
            _ = try backend.tile(canvas, background, .{ .width = layout.width, .height = layout.height }, .{ .ignore_aspect = true });
        };
        var cache_directory: [4096]u8 = undefined;
        const cache: ?Cache = if (options.cache and options.thumb_width <= 256 and options.thumb_height <= 256) cache: {
            const directory = cacheDirectory(&cache_directory) catch break :cache null;
            const scratch = allocator.alloc(u8, @as(usize, options.thumb_width) * options.thumb_height * 4) catch break :cache null;
            break :cache .{ .directory = directory, .scratch = scratch };
        } else null;
        defer if (cache) |saved| allocator.free(saved.scratch);
        if (options.title_font) |font| backend.label(canvas, options.title orelse "Index", .{ .width = layout.width, .height = layout.heading }, font) catch {};
        var rendered: usize = 0;
        for (entries[0..layout.count], 0..) |entry, index| {
            if (state.cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
            if (!options.output_only and options.redraw > 0 and index > 0 and index % options.redraw == 0) {
                self.progress.store(index, .release);
                backend.progress(context, canvas);
            }
            const x: u32 = @as(u32, @intCast(index % layout.columns)) * layout.cell_width;
            const y: u32 = layout.heading + @as(u32, @intCast(index / layout.columns)) * layout.cell_height;
            const region: Rect = .{ .x = x, .y = y, .width = @min(layout.width - x, options.thumb_width), .height = @min(layout.height - y, options.thumb_height) };
            const generated = if (cache) |saved| saved.tile(canvas, entry, region, options, state, backend) else backend.tile(canvas, entry.path, region, options);
            const size = generated catch |err| switch (err) {
                error.Cancelled, error.OutOfMemory => return err,
                else => continue,
            };
            rendered += 1;
            const template = options.labels();
            if (template.len != 0 and region.y + region.height < layout.height) {
                var label: [8192]u8 = undefined;
                const text = hooks.formatList(&label, template, .{
                    .path = entry.display(),
                    .mode = if (options.mode == .thumbnails) .thumbnails else if (options.mode == .montage) .montage else .index,
                    .index = index + 1,
                    .count = layout.count,
                    .width = size.width,
                    .height = size.height,
                    .bytes = @intCast(@max(0, entry.bytes)),
                }) catch "";
                if (text.len != 0) backend.label(canvas, text, .{ .x = x, .y = y + region.height, .width = region.width, .height = @min(layout.cell_height - region.height, layout.height - y - region.height) }, options.font) catch {};
            }
        }
        if (rendered == 0) return error.NoLoadableImages;
        const destination = options.destination orelse try std.fmt.bufPrintSentinel(&self.path, "{s}/sheet-{d}.png", .{ temporary_directory, state.downloads.?.uniqueNumber() }, 0);
        const format = output.Format.fromPath(destination) orelse return error.UnsupportedOutputFormat;
        var staged: output.Temporary = .{};
        defer staged.deinit();
        try staged.create(std.fs.path.dirname(destination) orelse ".", format);
        try backend.encode(canvas, staged.path(), format);
        try staged.replace(destination);
        if (options.output_only) return;
        if (options.destination != null) {
            if (c.realpath(destination.ptr, &self.path) == null) return error.ImageOutputFailed;
            self.path_len = std.mem.sliceTo(&self.path, 0).len;
        } else self.path_len = destination.len;
        self.layout = layout;
        self.original_first = entries[0];
        self.original_count = entries.len;
        state.entries[0] = .{ .path = self.path[0..self.path_len :0], .id = 0 };
        state.count = 1;
        state.selected = null;
        state.initial = null;
        state.info_ready = false;
    }
};
