//! Shared libtiff decoding, checked storage layout, prediction and orientation.
const std = @import("std");
const c = @import("tiff_bindings");
const system = @import("system");
const runtime = @import("runtime");
const source_file = @import("source");
const platform = @import("platform/tiff_runtime.zig");
pub const Failure = error{ OutOfMemory, UnreadableImage, InvalidDimensions, SizeOverflow, DecodeFailed, IncompleteImage, SourceChanged, Cancelled };
pub const Options = struct { workers: usize = 1, no_cache: bool = false, poison_allocation: bool = false, dynamic: bool = false, simd_predictor: bool = false, raw_retirement: bool = false, prefix_bytes: usize = 0, row_alignment: usize = 64, cancel: ?*const std.atomic.Value(bool) = null };
pub const Timings = struct {
    metadata_ms: f64 = 0,
    allocation_ms: f64 = 0,
    blocks_ms: f64 = 0,
    conversion_ms: f64 = 0,
    native_ms: f64 = 0,
    total_ms: f64 = 0,
    decode_wall_ms: f64 = 0,
    workers: usize = 1,
    blocks: usize = 0,
    lane_min_ms: f64 = std.math.inf(f64),
    lane_max_ms: f64 = 0,
    simd_predictor: bool = false,
};

fn openHandle(path: [:0]const u8) ?*c.TIFF {
    const opened = source_file.open(path, false) catch return null;
    return c.TIFFFdOpen(opened.fd, path.ptr, "rm") orelse {
        opened.close();
        return null;
    };
}
const Header = struct {
    width: u32,
    height: u32,
    orientation: u16,
    block_w: u32,
    block_h: u32,
    tiled: bool,
    scratch_bytes: usize,
    predictor: bool,
    fn read(tif: *c.TIFF) Failure!?Header {
        var width: u32 = 0;
        var height: u32 = 0;
        var bits: u16 = 0;
        var samples: u16 = 0;
        var photo: u16 = 0;
        var planar: u16 = 1;
        var format: u16 = 1;
        var orientation: u16 = 1;
        if (c.TIFFGetField(tif, 256, &width) == 0 or c.TIFFGetField(tif, 257, &height) == 0 or c.TIFFGetField(tif, 258, &bits) == 0 or c.TIFFGetField(tif, 277, &samples) == 0) return null;
        _ = c.TIFFGetField(tif, 262, &photo);
        _ = c.TIFFGetField(tif, 284, &planar);
        _ = c.TIFFGetField(tif, 339, &format);
        _ = c.TIFFGetField(tif, 274, &orientation);
        if (bits != 16 or samples != 3 or photo != 2 or planar != 1 or format != 1 or orientation < 1 or orientation > 8) return null;
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const tiled = c.TIFFIsTiled(tif) != 0;
        var block_w = width;
        var block_h = height;
        if (tiled) {
            if (c.TIFFGetField(tif, 322, &block_w) == 0 or c.TIFFGetField(tif, 323, &block_h) == 0) return error.InvalidDimensions;
        } else {
            _ = c.TIFFGetField(tif, 278, &block_h);
            block_h = @min(block_h, height);
        }
        if (block_w == 0 or block_h == 0) return error.InvalidDimensions;
        const scratch = if (tiled) c.TIFFTileSize64(tif) else c.TIFFStripSize64(tif);
        if (scratch == 0 or scratch > std.math.maxInt(isize) or scratch % 2 != 0) return error.SizeOverflow;
        const expected = try (try @import("raster").Extent.init(block_w, block_h)).bytes(3, 2);
        if (scratch != expected) return error.InvalidDimensions;
        var compression: u16 = 1;
        var predictor: u16 = 1;
        _ = c.TIFFGetField(tif, 259, &compression);
        if (compression == 8 or compression == 32946) _ = c.TIFFGetField(tif, 317, &predictor);
        return .{ .width = width, .height = height, .orientation = orientation, .block_w = block_w, .block_h = block_h, .tiled = tiled, .scratch_bytes = @intCast(scratch), .predictor = predictor == 2 };
    }
};
pub const Plan = struct {
    name: [4096:0]u8,
    tif: *c.TIFF,
    header: Header,
    stamp: source_file.Stamp,
    profile: []const u8,

    pub fn open(path: []const u8) Failure!?Plan {
        var name: [4096:0]u8 = undefined;
        if (path.len == 0 or path.len >= name.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.UnreadableImage;
        @memcpy(name[0..path.len], path);
        name[path.len] = 0;
        const path_z = name[0..path.len :0];
        const opened = try source_file.open(path_z, false);
        if (std.meta.activeTag(opened.format) != .tiff) {
            opened.close();
            return null;
        }
        const tif = c.TIFFFdOpen(opened.fd, path_z.ptr, "rm") orelse {
            opened.close();
            return error.DecodeFailed;
        };
        var owned = true;
        defer if (owned) c.TIFFClose(tif);
        const header = (try Header.read(tif)) orelse return null;
        var profile_len: u32 = 0;
        var profile_ptr: ?[*]const u8 = null;
        _ = c.TIFFGetField(tif, 34675, &profile_len, &profile_ptr);
        owned = false;
        return .{ .name = name, .tif = tif, .header = header, .stamp = opened.stamp, .profile = if (profile_ptr) |p| p[0..profile_len] else "" };
    }
    fn validateHandle(self: *const Plan, tif: *c.TIFF) Failure!void {
        var stat: system.struct_stat = undefined;
        if (runtime.files.fstat(c.TIFFFileno(tif), &stat) != 0) return error.UnreadableImage;
        if (!std.meta.eql(source_file.Stamp.fromStat(stat), self.stamp)) return error.SourceChanged;
        const header = (try Header.read(tif)) orelse return error.SourceChanged;
        if (!std.meta.eql(header, self.header)) return error.SourceChanged;
    }
    pub fn deinit(self: *Plan) void {
        c.TIFFClose(self.tif);
    }
    pub fn workerCount(self: Plan, requested: usize, measured: bool) usize {
        const rows = std.math.divCeil(usize, self.header.height, self.header.block_h) catch unreachable;
        return if (!measured and @as(u64, self.header.width) * self.header.height < 8 * 1024 * 1024) 1 else @max(1, @min(requested, rows));
    }
    pub fn decode(self: *Plan, comptime measured: bool, allocator: std.mem.Allocator, options: Options, timings: ?*Timings) Failure!Decoded {
        if (options.no_cache and !platform.noCache(self.tif)) return error.UnreadableImage;
        const width: usize = if (self.header.orientation >= 5) self.header.height else self.header.width;
        const height: usize = if (self.header.orientation >= 5) self.header.width else self.header.height;
        const rows = std.math.divCeil(usize, self.header.height, self.header.block_h) catch return error.InvalidDimensions;
        const workers = self.workerCount(options.workers, measured);
        const layout = try storageLayout(width, height, self.header.scratch_bytes, workers, options.prefix_bytes, options.row_alignment, self.profile.len);
        const allocation_started = if (measured) runtime.now() else 0;
        const slab: []align(64) u8 = if (options.poison_allocation) allocator.alignedAlloc(u8, .fromByteUnits(64), layout.total) catch return error.OutOfMemory else allocation: {
            const pointer = allocator.rawAlloc(layout.total, .fromByteUnits(64), @returnAddress()) orelse return error.OutOfMemory;
            break :allocation @as([*]align(64) u8, @alignCast(pointer))[0..layout.total];
        };
        errdefer if (options.raw_retirement) allocator.rawFree(slab, .fromByteUnits(64), @returnAddress()) else allocator.free(slab);
        const prefix = try align64(options.prefix_bytes);
        const pixels = slab[prefix..][0..layout.pixel_bytes];
        const profile = slab[prefix + layout.pixel_bytes ..][0..self.profile.len];
        @memcpy(profile, self.profile);
        const cursor: *std.atomic.Value(usize) = @ptrCast(@alignCast(slab[layout.context_offset..].ptr));
        cursor.* = .init(0);
        const work: [*]BlockWork = @ptrCast(@alignCast(slab[layout.context_offset + 64 ..].ptr));
        const use_simd = options.simd_predictor and self.header.predictor;
        for (0..workers) |lane| work[lane] = .{ .plan = self, .cancel = options.cancel, .path = &self.name, .tif = if (lane == 0) self.tif else null, .no_cache = options.no_cache, .first_row = @intCast((rows * lane / workers) * self.header.block_h), .end_row = if (options.dynamic) self.header.height else @intCast(@min(self.header.height, (rows * (lane + 1) / workers) * self.header.block_h)), .next_row = if (options.dynamic) cursor else null, .simd_predictor = use_simd, .width = self.header.width, .height = self.header.height, .block_w = self.header.block_w, .block_h = self.header.block_h, .tiled = self.header.tiled, .orientation = self.header.orientation, .row_bytes = layout.row_bytes, .scratch = @alignCast(slab[layout.profile_offset + layout.profile_stride + layout.scratch_stride * lane ..][0..self.header.scratch_bytes]), .output = @ptrCast(@alignCast(pixels.ptr)) };
        if (measured) timings.?.allocation_ms = (runtime.now() - allocation_started) * 1000;
        const decode_started = if (measured) runtime.now() else 0;
        platform.run(work[0..workers], struct {
            fn run(item: *BlockWork) void {
                runWorker(measured, item);
            }
        }.run);
        for (work[0..workers]) |*lane| {
            if (lane.failure) |err| return err;
            if (measured) {
                timings.?.blocks_ms += lane.timings.blocks_ms;
                timings.?.conversion_ms += lane.timings.conversion_ms;
                timings.?.blocks += lane.timings.blocks;
                timings.?.lane_min_ms = @min(timings.?.lane_min_ms, lane.elapsed_ms);
                timings.?.lane_max_ms = @max(timings.?.lane_max_ms, lane.elapsed_ms);
            }
        }
        if (measured) {
            timings.?.workers = workers;
            timings.?.simd_predictor = use_simd;
            timings.?.decode_wall_ms = (runtime.now() - decode_started) * 1000;
        }
        try self.validateHandle(self.tif);
        return .{ .allocator = allocator, .slab = slab, .pixels = pixels, .profile = profile, .width = @intCast(width), .height = @intCast(height), .row_bytes = layout.row_bytes, .raw_retirement = options.raw_retirement };
    }
};
pub const Decoded = @import("pixel_storage").Decoded;
const BlockWork = struct {
    plan: *const Plan,
    cancel: ?*const std.atomic.Value(bool) = null,
    simd_predictor: bool = false,
    next_row: ?*std.atomic.Value(usize) = null,
    elapsed_ms: f64 = 0,
    path: [*:0]const u8,
    tif: ?*c.TIFF,
    no_cache: bool,
    first_row: u32,
    end_row: u32,
    width: u32,
    height: u32,
    block_w: u32,
    block_h: u32,
    tiled: bool,
    orientation: u16,
    row_bytes: usize,
    scratch: []align(64) u8,
    output: [*]u16,
    timings: Timings = .{},
    failure: ?Failure = null,
    thread: ?std.Thread = null,
};
fn runWorker(comptime measured: bool, work: *BlockWork) void {
    const started = if (measured) runtime.now() else 0;
    defer if (measured) {
        work.elapsed_ms = (runtime.now() - started) * 1000;
    };
    const own_handle = work.tif == null;
    const tif = work.tif orelse openHandle(std.mem.span(work.path)) orelse {
        work.failure = error.DecodeFailed;
        return;
    };
    defer if (own_handle) c.TIFFClose(tif);
    work.plan.validateHandle(tif) catch |err| {
        work.failure = err;
        return;
    };
    if (work.no_cache and !platform.noCache(tif)) {
        work.failure = error.UnreadableImage;
        return;
    }
    if (work.simd_predictor and c.TIFFSetField(tif, 317, @as(c_int, 1)) == 0) {
        work.failure = error.DecodeFailed;
        return;
    }
    defer if (!own_handle and work.simd_predictor) {
        _ = c.TIFFSetField(tif, 317, @as(c_int, 2));
    };
    decodeBlocks(measured, work, tif) catch |err| {
        work.failure = err;
    };
}
fn decodeBlocks(comptime measured: bool, work: *BlockWork, tif: *c.TIFF) Failure!void {
    const width = work.width;
    const height = work.height;
    const block_w = work.block_w;
    const block_h = work.block_h;
    const tiled = work.tiled;
    const orientation = work.orientation;
    const row_bytes = work.row_bytes;
    const scratch = work.scratch;
    const output = work.output;
    const stride = row_bytes / 2;
    var by: u32 = if (work.next_row) |cursor| @intCast(@min(height, cursor.fetchAdd(block_h, .monotonic))) else work.first_row;
    while (by < work.end_row) : (by = if (work.next_row) |cursor| @intCast(@min(height, cursor.fetchAdd(block_h, .monotonic))) else by + @min(block_h, height - by)) {
        if (work.cancel) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
        var bx: u32 = 0;
        while (bx < width) : (bx += @min(block_w, width - bx)) {
            const index = if (tiled) c.TIFFComputeTile(tif, bx, by, 0, 0) else c.TIFFComputeStrip(tif, by, 0);
            const block_started = if (measured) runtime.now() else 0;
            const decoded = if (tiled) c.TIFFReadEncodedTile(tif, index, scratch.ptr, @intCast(scratch.len)) else c.TIFFReadEncodedStrip(tif, index, scratch.ptr, @intCast(scratch.len));
            const conversion_started = if (measured) runtime.now() else 0;
            if (measured) {
                work.timings.blocks_ms += (conversion_started - block_started) * 1000;
                work.timings.blocks += 1;
            }
            if (decoded <= 0 or @as(usize, @intCast(decoded)) > scratch.len) return error.DecodeFailed;
            const raw: [*]const u16 = @ptrCast(@alignCast(scratch.ptr));
            const rows = @min(block_h, height - by);
            const columns = @min(block_w, width - bx);
            const required = (@as(usize, rows - 1) * block_w + columns) * 6;
            if (required > @as(usize, @intCast(decoded))) return error.IncompleteImage;
            if (work.simd_predictor) {
                const values: [*]u16 = @ptrCast(@alignCast(scratch.ptr));
                for (0..rows) |row| @import("predictor.zig").rgb16(values[row * @as(usize, block_w) * 3 ..][0 .. @as(usize, columns) * 3]);
            }
            if (orientation == 1) {
                platform.insert(scratch.ptr, output + @as(usize, by) * stride + @as(usize, bx) * 4, columns, rows, @as(usize, block_w) * 6, row_bytes) catch return error.DecodeFailed;
                // Initialize padding with the worker's newly written rows,
                // avoiding a serial first-touch pass across the entire image.
                if (bx + columns == width) for (0..rows) |row| {
                    @memset(output[(@as(usize, by) + row) * stride + @as(usize, width) * 4 ..][0 .. stride - @as(usize, width) * 4], 0);
                };
                if (measured) work.timings.conversion_ms += (runtime.now() - conversion_started) * 1000;
                continue;
            }
            switch (orientation) {
                inline 2, 3, 4, 5, 6, 7, 8 => |value| orientBlock(value, work, raw, bx, by, rows, columns),
                else => unreachable,
            }
            if (measured) work.timings.conversion_ms += (runtime.now() - conversion_started) * 1000;
        }
    }
}

// Rotated output traverses distant rows in the naïve pixel loop. Small
// transpose blocks keep source and destination cache lines useful together.
// Specialize orientation once per stored block, not once per source pixel.
fn orientBlock(comptime orientation: u16, work: *const BlockWork, raw: [*]const u16, bx: usize, by: usize, rows: usize, columns: usize) void {
    const stride = work.row_bytes / 2;
    const out_width: usize = if (orientation >= 5) work.height else work.width;
    const tile: usize = if (orientation >= 5) 32 else @max(rows, columns);
    var row_start: usize = 0;
    while (row_start < rows) : (row_start += @min(tile, rows - row_start)) {
        var col_start: usize = 0;
        while (col_start < columns) : (col_start += @min(tile, columns - col_start)) {
            for (row_start..@min(rows, row_start + tile)) |row| for (col_start..@min(columns, col_start + tile)) |column| {
                const source = (row * work.block_w + column) * 3;
                const x = bx + column;
                const y = by + row;
                const dx = switch (orientation) {
                    2, 3 => work.width - 1 - x,
                    5, 8 => y,
                    6, 7 => work.height - 1 - y,
                    else => x,
                };
                const dy = switch (orientation) {
                    3, 4 => work.height - 1 - y,
                    5, 6 => x,
                    7, 8 => work.width - 1 - x,
                    else => y,
                };
                const target = dy * stride + dx * 4;
                work.output[target] = raw[source];
                work.output[target + 1] = raw[source + 1];
                work.output[target + 2] = raw[source + 2];
                work.output[target + 3] = 65535;
                if (dx + 1 == out_width) @memset(work.output[target + 4 ..][0 .. stride - out_width * 4], 0);
            };
        }
    }
}

fn align64(value: usize) Failure!usize {
    return (std.math.add(usize, value, 63) catch return error.SizeOverflow) & ~@as(usize, 63);
}
pub const Layout = struct { row_bytes: usize, pixel_bytes: usize, profile_offset: usize, profile_stride: usize, scratch_stride: usize, context_offset: usize, total: usize };
pub fn storageLayout(width: usize, height: usize, scratch: usize, workers: usize, prefix_bytes: usize, row_alignment: usize, profile_bytes: usize) Failure!Layout {
    const raw_row = std.math.mul(usize, width, 8) catch return error.SizeOverflow;
    const row = if (row_alignment == 64) try align64(raw_row) else raw_row;
    const pixels = std.math.mul(usize, row, height) catch return error.SizeOverflow;
    if (pixels > std.math.maxInt(isize)) return error.SizeOverflow;
    const stride = try align64(scratch);
    const prefix = try align64(prefix_bytes);
    const profile = try align64(profile_bytes);
    const profile_offset = try align64(std.math.add(usize, prefix, pixels) catch return error.SizeOverflow);
    const base = std.math.add(usize, profile_offset, profile) catch return error.SizeOverflow;
    const context = std.math.add(usize, base, std.math.mul(usize, stride, workers) catch return error.SizeOverflow) catch return error.SizeOverflow;
    const contexts = std.math.mul(usize, @sizeOf(BlockWork), workers) catch return error.SizeOverflow;
    const total = std.math.add(usize, std.math.add(usize, context, 64) catch return error.SizeOverflow, contexts) catch return error.SizeOverflow;
    if (total > std.math.maxInt(isize)) return error.SizeOverflow;
    return .{ .row_bytes = row, .pixel_bytes = pixels, .profile_offset = profile_offset, .profile_stride = profile, .scratch_stride = stride, .context_offset = context, .total = total };
}

test "TIFF helpers reject path replacement and header drift before conversion" {
    var path: ["/tmp/yekk-tiff-XXXXXX".len:0]u8 = "/tmp/yekk-tiff-XXXXXX".*;
    const fd = system.mkstemp(&path);
    try std.testing.expect(fd >= 0);
    _ = system.close(fd);
    _ = system.unlink(&path);
    defer _ = system.unlink(&path);
    var first: [4096]u8 = undefined;
    var second: [4096]u8 = undefined;
    try std.testing.expect(system.realpath("tests/fixtures/rgb16-orientation1.tif", &first) != null);
    try std.testing.expect(system.realpath("tests/fixtures/rgb16-orientation6.tif", &second) != null);
    try std.testing.expectEqual(@as(c_int, 0), system.symlink(@ptrCast(&first), &path));
    var plan = (try Plan.open(std.mem.span(@as([*:0]const u8, &path)))).?;
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.workerCount(2, true));
    _ = system.unlink(&path);
    try std.testing.expectEqual(@as(c_int, 0), system.symlink(@ptrCast(&second), &path));
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var timing: Timings = .{};
    try std.testing.expectError(error.SourceChanged, plan.decode(true, allocator.allocator(), .{ .workers = 2, .poison_allocation = true }, &timing));
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    try std.testing.expect(c.TIFFSetField(plan.tif, 256, @as(u32, plan.header.width + 1)) != 0);
    try std.testing.expectError(error.SourceChanged, plan.decode(true, allocator.allocator(), .{ .workers = 1, .poison_allocation = true }, &timing));
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}
