//! Develop camera sensor data through LibRaw's reentrant C API.
const std = @import("std");
const c = @import("raw_bindings");
const source = @import("source");
const Extent = @import("raster").Extent;
const Decoded = @import("pixel_storage").Decoded;
const Error = source.Error || error{ OutOfMemory, Cancelled, SourceChanged };
const Cancel = ?*const std.atomic.Value(bool);
const ReadFailure = std.atomic.Value(bool);

const Session = struct {
    raw: *c.libraw_data_t,
    file: source.Open,
    cancel: Cancel,

    fn open(file: source.Open, cancel: Cancel, read_failure: *ReadFailure) Error!Session {
        try cancelled(cancel);
        const raw: *c.libraw_data_t = @ptrCast(c.libraw_init(c.LIBRAW_OPTIONS_NO_DATAERR_CALLBACK) orelse return error.OutOfMemory);
        errdefer c.libraw_close(raw);
        if (cancel) |flag| c.libraw_set_progress_handler(raw, progress, @constCast(flag));
        c.libraw_set_dataerror_handler(raw, readError, read_failure);
        // Use the validated descriptor, even if the original pathname is replaced.
        // The stdio stream reads from disk without mapping a mutable source file.
        const prefix = if (@import("builtin").os.tag == .linux) "/proc/self/fd/" else "/dev/fd/";
        var buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buffer, prefix ++ "{d}", .{file.fd}, 0) catch unreachable;
        const status = if (@hasDecl(c, "libraw_open_file_ex"))
            c.libraw_open_file_ex(raw, path.ptr, 0)
        else
            c.libraw_open_file(raw, path.ptr);
        try check(status);
        if (read_failure.load(.acquire)) return error.IncompleteImage;
        raw.params.use_camera_wb = 1;
        raw.params.output_bps = 16;
        raw.params.output_color = 1; // sRGB primaries
        raw.params.gamm[0] = 1.0 / 2.4;
        raw.params.gamm[1] = 12.92;
        return .{ .raw = raw, .file = file, .cancel = cancel };
    }

    fn close(self: Session) void {
        c.libraw_close(self.raw);
    }

    fn extent(self: Session) Error!Extent {
        try check(c.libraw_adjust_sizes_info_only(self.raw));
        // LibRaw applies the camera orientation during this size calculation
        // and when constructing its processed bitmap.
        const sizes = self.raw.sizes;
        return Extent.init(sizes.iwidth, sizes.iheight);
    }

    fn ensureCurrent(self: Session) Error!void {
        try cancelled(self.cancel);
        if (!self.file.unchanged()) return error.SourceChanged;
    }
};

fn check(status: c_int) Error!void {
    return switch (status) {
        c.LIBRAW_SUCCESS => {},
        c.LIBRAW_UNSUFFICIENT_MEMORY, c.LIBRAW_MEMPOOL_OVERFLOW => error.OutOfMemory,
        c.LIBRAW_CANCELLED_BY_CALLBACK => error.Cancelled,
        c.LIBRAW_IO_ERROR => error.IncompleteImage,
        else => error.DecodeFailed,
    };
}

fn cancelled(cancel: Cancel) Error!void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
}

fn progress(context: ?*anyopaque, _: c.LibRaw_progress, _: c_int, _: c_int) callconv(.c) c_int {
    const flag: *const std.atomic.Value(bool) = @ptrCast(@alignCast(context.?));
    return @intFromBool(flag.load(.acquire));
}

fn parallelProgress(context: ?*anyopaque, stage: c.LibRaw_progress, iteration: c_int, expected: c_int) callconv(.c) c_int {
    // LibRaw 0.22.2's AHD threads read a shared stop flag that the callback
    // can set without synchronization. Cancel at the next stage boundary.
    if (stage == c.LIBRAW_PROGRESS_INTERPOLATE) return 0;
    return progress(context, stage, iteration, expected);
}

fn readError(context: ?*anyopaque, _: [*c]const u8, _: i64) callconv(.c) void {
    const failure: *ReadFailure = @ptrCast(@alignCast(context.?));
    failure.store(true, .release);
}

pub fn probe(file: source.Open, cancel: Cancel) Error!Extent {
    var read_failure: ReadFailure = .init(false);
    const session = try Session.open(file, cancel, &read_failure);
    defer session.close();
    const size = try session.extent();
    try session.ensureCurrent();
    return size;
}

pub const Options = struct {
    prefix_bytes: usize = 0,
    workers: usize = 1,
    raw_retirement: bool = false,
    cancel: Cancel = null,
};

// libraw_r uses OpenMP on some builds. Limit this worker's OpenMP tasks
// while LibRaw runs. The setting belongs to the calling thread's task.
const ThreadBudget = struct {
    const Set = *const fn (c_int) callconv(.c) void;
    const Get = *const fn () callconv(.c) c_int;
    const Setting = struct {
        set: Set,
        previous: c_int,
    };
    threads: Setting,
    blocktime: ?Setting,

    fn setScoped(getter: [*:0]const u8, setter: [*:0]const u8, value: c_int) ?Setting {
        const get: Get = @ptrCast(@alignCast(c.dlsym(c.RTLD_DEFAULT, getter) orelse return null));
        const set: Set = @ptrCast(@alignCast(c.dlsym(c.RTLD_DEFAULT, setter) orelse return null));
        const previous = get();
        set(value);
        return .{ .set = set, .previous = previous };
    }

    fn begin(workers: usize) ?ThreadBudget {
        const threads = setScoped("omp_get_max_threads", "omp_set_num_threads", @intCast(@min(std.math.maxInt(c_int), @max(1, workers)))) orelse return null;
        // LLVM OpenMP can otherwise spin after a batch ends.
        return .{ .threads = threads, .blocktime = setScoped("kmp_get_blocktime", "kmp_set_blocktime", 0) };
    }

    fn end(self: ThreadBudget) void {
        if (self.blocktime) |setting| setting.set(setting.previous);
        self.threads.set(self.threads.previous);
    }
};

pub fn load(file: source.Open, allocator: std.mem.Allocator, options: Options, comptime reserve: anytype, comptime release: anytype) Error!Decoded {
    var read_failure: ReadFailure = .init(false);
    const session = try Session.open(file, options.cancel, &read_failure);
    defer session.close();
    const size = try Extent.init(session.raw.sizes.width, session.raw.sizes.height);
    const sensor = try Extent.init(session.raw.sizes.raw_width, session.raw.sizes.raw_height);
    // A small RAW has at most one tile of demosaic work.
    const workers = if (sensor.width <= 256 and sensor.height <= 256) 1 else options.workers;
    const budget = ThreadBudget.begin(workers);
    defer if (budget) |scope| scope.end();
    if (budget != null and workers > 1) {
        if (options.cancel) |flag| c.libraw_set_progress_handler(session.raw, parallelProgress, @constCast(flag));
    }
    // Account for native unpacking, demosaic scratch and the processed bitmap.
    const workspace = try sensor.bytes(32, 1);
    const reserve_bytes = std.math.add(usize, workspace, try size.bytes(8, 1)) catch return error.SizeOverflow;
    try reserve(reserve_bytes);
    defer release(reserve_bytes);
    try session.ensureCurrent();
    try check(c.libraw_unpack(session.raw));
    if (read_failure.load(.acquire)) return error.IncompleteImage;
    try session.ensureCurrent();
    if (@import("raw_options").simd_demosaic) {
        if (@hasDecl(c, "libraw_yekk_set_ahd_rows_handler")) {
            c.libraw_yekk_set_ahd_rows_handler(session.raw, @import("raw_ahd.zig").rolling);
        } else if (@hasDecl(c, "libraw_yekk_set_ahd_handler")) {
            c.libraw_yekk_set_ahd_handler(session.raw, @import("raw_ahd.zig").score);
        }
    }
    try check(c.libraw_dcraw_process(session.raw));
    try session.ensureCurrent();
    if (@hasDecl(c, "libraw_yekk_prepare_rgba16")) {
        if (try exportDirect(session, allocator, options)) |decoded| return decoded;
    }
    var status: c_int = c.LIBRAW_SUCCESS;
    const bitmap = c.libraw_dcraw_make_mem_image(session.raw, &status);
    if (bitmap == null) {
        try check(status);
        return error.DecodeFailed;
    }
    defer c.libraw_dcraw_clear_mem(bitmap);
    const header = bitmap[0];
    if (header.type != c.LIBRAW_IMAGE_BITMAP or header.bits != 16 or (header.colors != 1 and header.colors != 3)) return error.DecodeFailed;
    const output = try Extent.init(header.width, header.height);
    if (try output.bytes(header.colors, 2) != header.data_size) return error.DecodeFailed;
    try cancelled(options.cancel);
    // The exported bitmap owns its RGB samples. Drop the development buffer
    // before allocating the viewer's RGBA pixels.
    c.libraw_free_image(session.raw);
    const result = try allocatePixels(allocator, output, options);
    errdefer result.deinit();
    const input: [*]align(2) const u8 = @ptrCast(@alignCast(&bitmap[0].data));
    const dest = std.mem.bytesAsSlice(u16, result.pixels);
    const samples = std.mem.bytesAsSlice(u16, input[0..header.data_size]);
    for (0..output.height) |row| {
        try cancelled(options.cancel);
        const start = row * output.width;
        for (start..start + output.width) |i| {
            const color = i * header.colors;
            const r = samples[color];
            dest[i * 4 ..][0..4].* = if (header.colors == 3) .{ r, samples[color + 1], samples[color + 2], 65535 } else .{ r, r, r, 65535 };
        }
    }
    try session.ensureCurrent();
    return result;
}

fn allocatePixels(allocator: std.mem.Allocator, output: Extent, options: Options) Error!Decoded {
    const pixel_bytes = try output.bytes(4, 2);
    const prefix = (std.math.add(usize, options.prefix_bytes, 63) catch return error.SizeOverflow) & ~@as(usize, 63);
    const total = std.math.add(usize, prefix, pixel_bytes) catch return error.SizeOverflow;
    if (total > std.math.maxInt(isize)) return error.SizeOverflow;
    const slab = allocator.alignedAlloc(u8, .fromByteUnits(64), total) catch return error.OutOfMemory;
    const pixels = slab[prefix..];
    return .{ .allocator = allocator, .slab = slab, .pixels = pixels, .profile = slab[total..], .width = output.width, .height = output.height, .row_bytes = @as(usize, output.width) * 8, .raw_retirement = options.raw_retirement };
}

fn exportDirect(session: Session, allocator: std.mem.Allocator, options: Options) Error!?Decoded {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    var bits: c_int = 0;
    try check(c.libraw_yekk_prepare_rgba16(session.raw, &width, &height, &channels, &bits));
    if (bits != 16 or (channels != 1 and channels != 3) or width <= 0 or height <= 0) return null;
    const output = try Extent.init(@intCast(width), @intCast(height));
    const sizes = session.raw.sizes;
    const source_size = try Extent.init(sizes.width, sizes.height);
    const flip = sizes.flip;
    if (flip < 0 or flip > 7 or session.raw.image == null) return null;
    const transposed = (flip & 4) != 0;
    const vertical = (flip & 2) != 0;
    const horizontal = (flip & 1) != 0;
    if (output.width != (if (transposed) source_size.height else source_size.width) or
        output.height != (if (transposed) source_size.width else source_size.height)) return null;

    try cancelled(options.cancel);
    const result = try allocatePixels(allocator, output, options);
    errdefer result.deinit();
    const aligned: []align(2) u8 = @alignCast(result.pixels);
    const dst = std.mem.bytesAsSlice([4]u16, aligned);
    const src_info: Export = .{
        .samples = session.raw.image[0..dst.len],
        .curve = &session.raw.color.curve,
        .src_width = source_size.width,
        .src_height = source_size.height,
        .dst_width = output.width,
        .dst_height = output.height,
        .vertical = vertical,
        .horizontal = horizontal,
    };
    if (channels == 1) {
        try src_info.write(true, transposed, dst, options.cancel);
    } else {
        try src_info.write(false, transposed, dst, options.cancel);
    }
    try session.ensureCurrent();
    return result;
}

const Export = struct {
    samples: []const [4]u16,
    curve: *const [65536]u16,
    src_width: usize,
    src_height: usize,
    dst_width: usize,
    dst_height: usize,
    vertical: bool,
    horizontal: bool,

    fn write(self: Export, comptime mono: bool, transposed: bool, dest: [][4]u16, cancel: Cancel) Error!void {
        if (!transposed) {
            for (0..self.dst_height) |y| {
                try cancelled(cancel);
                self.writeSpan(mono, false, dest, y, 0, self.dst_width);
            }
            return;
        }
        const block = 32;
        var y: usize = 0;
        while (y < self.dst_height) : (y += block) {
            try cancelled(cancel);
            var x: usize = 0;
            while (x < self.dst_width) : (x += block) {
                for (y..@min(y + block, self.dst_height)) |row| {
                    self.writeSpan(mono, true, dest, row, x, @min(x + block, self.dst_width));
                }
            }
        }
    }

    inline fn writeSpan(self: Export, comptime mono: bool, comptime transposed: bool, dest: [][4]u16, y: usize, from: usize, to: usize) void {
        const row = if (transposed) from else y;
        const col = if (transposed) y else from;
        const src_y = if (self.vertical) self.src_height - 1 - row else row;
        const src_x = if (self.horizontal) self.src_width - 1 - col else col;
        const step: isize = if (transposed)
            (if (self.vertical) -@as(isize, @intCast(self.src_width)) else @intCast(self.src_width))
        else if (self.horizontal) -1 else 1;
        var index: isize = @intCast(src_y * self.src_width + src_x);
        for (dest[y * self.dst_width + from .. y * self.dst_width + to]) |*pixel| {
            const input = self.samples[@intCast(index)];
            const r = self.curve[input[0]];
            pixel.* = if (mono) .{ r, r, r, 65535 } else .{ r, self.curve[input[1]], self.curve[input[2]], 65535 };
            index += step;
        }
    }
};
