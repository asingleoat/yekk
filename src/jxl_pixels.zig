//! Direct, streamed libjxl decoding. Native jobs finish before slab retirement.
const std = @import("std");
const c = @import("jxl_bindings");
const source = @import("source");
const Extent = @import("raster").Extent;
const Decoded = @import("pixel_storage").Decoded;
const Error = source.Error || error{ OutOfMemory, Cancelled, SourceChanged };
pub const Header = struct {
    extent: Extent,
    bits: u8,
    opaque_source: bool,
    gray: bool,
    profile_bytes: usize,
};
const Session = struct {
    decoder: *c.JxlDecoder,
    runner: ?*anyopaque,
    file: source.Open,
    cancel: ?*const std.atomic.Value(bool),
    buffer: [64 * 1024]u8 = undefined,
    used: usize = 0,
    offset: u64 = 0,
    closed: bool = false,
    fn init(file: source.Open, workers: usize, cancel: ?*const std.atomic.Value(bool)) Error!Session {
        const decoder = c.JxlDecoderCreate(null) orelse return error.OutOfMemory;
        errdefer c.JxlDecoderDestroy(decoder);
        const runner = if (workers > 1) c.JxlThreadParallelRunnerCreate(null, workers - 1) orelse return error.OutOfMemory else null;
        errdefer if (runner) |value| c.JxlThreadParallelRunnerDestroy(value);
        if (runner) |value| try check(c.JxlDecoderSetParallelRunner(decoder, c.JxlThreadParallelRunner, value));
        try check(c.JxlDecoderSetKeepOrientation(decoder, c.JXL_FALSE));
        try check(c.JxlDecoderSetUnpremultiplyAlpha(decoder, c.JXL_TRUE));
        try check(c.JxlDecoderSubscribeEvents(decoder, c.JXL_DEC_BASIC_INFO | c.JXL_DEC_COLOR_ENCODING | c.JXL_DEC_FULL_IMAGE));
        // No input pointer escapes until the returned session is in place.
        return .{ .decoder = decoder, .runner = runner, .file = file, .cancel = cancel };
    }
    fn deinit(self: *Session) void {
        c.JxlDecoderDestroy(self.decoder);
        if (self.runner) |value| c.JxlThreadParallelRunnerDestroy(value);
    }
    fn next(self: *Session) Error!c.JxlDecoderStatus {
        while (true) {
            if (self.cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
            const status = c.JxlDecoderProcessInput(self.decoder);
            if (status == c.JXL_DEC_ERROR) return error.DecodeFailed;
            if (status != c.JXL_DEC_NEED_MORE_INPUT) return status;
            if (self.closed) return error.IncompleteImage;
            const left = c.JxlDecoderReleaseInput(self.decoder);
            // At NEED_MORE_INPUT the libjxl API retains fewer than 20 bytes.
            if (left > self.used or left >= self.buffer.len) return error.DecodeFailed;
            std.mem.copyForwards(u8, self.buffer[0..left], self.buffer[self.used - left .. self.used]);
            const count = try self.file.readAt(self.buffer[left..], self.offset);
            if (count == 0) return error.IncompleteImage;
            self.offset += count;
            self.used = left + count;
            try check(c.JxlDecoderSetInput(self.decoder, &self.buffer, self.used));
            if (self.offset == @as(u64, @intCast(self.file.stamp.bytes))) {
                c.JxlDecoderCloseInput(self.decoder);
                self.closed = true;
            }
        }
    }
    fn header(self: *Session) Error!Header {
        var info: ?c.JxlBasicInfo = null;
        while (true) switch (try self.next()) {
            c.JXL_DEC_BASIC_INFO => {
                var value: c.JxlBasicInfo = undefined;
                try check(c.JxlDecoderGetBasicInfo(self.decoder, &value));
                if (value.bits_per_sample == 0 or value.bits_per_sample > 16 or value.exponent_bits_per_sample != 0 or value.alpha_bits > 16 or value.alpha_exponent_bits != 0 or (value.num_color_channels != 1 and value.num_color_channels != 3)) return error.DecodeFailed;
                _ = try Extent.init(value.xsize, value.ysize);
                if (value.xsize > std.math.maxInt(c_int) or value.ysize > std.math.maxInt(c_int) or value.orientation != c.JXL_ORIENT_IDENTITY) return error.InvalidDimensions;
                info = value;
            },
            c.JXL_DEC_COLOR_ENCODING => {
                const value = info orelse return error.DecodeFailed;
                var size: usize = 0;
                try check(c.JxlDecoderGetICCProfileSize(self.decoder, c.JXL_COLOR_PROFILE_TARGET_DATA, &size));
                if (size == 0 or size > std.math.maxInt(u32)) return error.SizeOverflow;
                return .{ .extent = try Extent.init(value.xsize, value.ysize), .bits = if (@max(value.bits_per_sample, value.alpha_bits) > 8) 16 else 8, .opaque_source = value.alpha_bits == 0, .gray = value.num_color_channels == 1, .profile_bytes = size };
            },
            else => return error.IncompleteImage,
        };
    }
};
fn check(status: c.JxlDecoderStatus) Error!void {
    if (status != c.JXL_DEC_SUCCESS) return error.DecodeFailed;
}
pub fn probe(file: source.Open, cancel: ?*const std.atomic.Value(bool)) Error!Header {
    var session = try Session.init(file, 1, cancel);
    defer session.deinit();
    const header = try session.header();
    if (!file.unchanged()) return error.SourceChanged;
    return header;
}
pub const Options = struct {
    prefix_bytes: usize = 0,
    workers: usize = 1,
    keep_gray: bool = false,
    raw_retirement: bool = false,
    cancel: ?*const std.atomic.Value(bool) = null,
};
pub const Result = struct { decoded: Decoded, opaque_source: bool, gray_source: bool };
pub fn load(file: source.Open, allocator: std.mem.Allocator, options: Options, comptime reserve: anytype, comptime release: anytype) Error!Result {
    // Destroy the decoder and its runner before any failed output is freed.
    var owned: ?Decoded = null;
    defer if (owned) |value| value.deinit();
    var session = try Session.init(file, options.workers, options.cancel);
    defer session.deinit();
    const header = try session.header();
    const channels: u32 = if (header.gray and options.keep_gray) (if (header.opaque_source) @as(u32, 1) else 2) else 4;
    const bytes = try header.extent.bytes(channels, header.bits / 8);
    const prefix = (std.math.add(usize, options.prefix_bytes, 63) catch return error.SizeOverflow) & ~@as(usize, 63);
    const end = std.math.add(usize, prefix, bytes) catch return error.SizeOverflow;
    const total = std.math.add(usize, end, header.profile_bytes) catch return error.SizeOverflow;
    if (total > std.math.maxInt(isize)) return error.SizeOverflow;
    try reserve(total);
    defer release(total);
    const pointer = allocator.rawAlloc(total, .fromByteUnits(64), @returnAddress()) orelse return error.OutOfMemory;
    const slab = @as([*]align(64) u8, @alignCast(pointer))[0..total];
    const decoded: Decoded = .{ .allocator = allocator, .slab = slab, .pixels = slab[prefix..end], .profile = slab[end..], .width = header.extent.width, .height = header.extent.height, .row_bytes = @as(usize, header.extent.width) * channels * (header.bits / 8), .raw_retirement = options.raw_retirement, .bits_per_component = header.bits };
    owned = decoded;
    try check(c.JxlDecoderGetColorAsICCProfile(session.decoder, c.JXL_COLOR_PROFILE_TARGET_DATA, slab[end..].ptr, header.profile_bytes));
    const format: c.JxlPixelFormat = .{ .num_channels = channels, .data_type = if (header.bits == 16) c.JXL_TYPE_UINT16 else c.JXL_TYPE_UINT8, .endianness = c.JXL_NATIVE_ENDIAN, .@"align" = 0 };
    var phase: enum { awaiting_buffer, decoding, complete } = .awaiting_buffer;
    while (true) switch (try session.next()) {
        c.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
            if (phase != .awaiting_buffer) return error.DecodeFailed;
            var size: usize = 0;
            try check(c.JxlDecoderImageOutBufferSize(session.decoder, &format, &size));
            if (size != bytes) return error.InvalidDimensions;
            try check(c.JxlDecoderSetImageOutBuffer(session.decoder, &format, decoded.pixels.ptr, bytes));
            phase = .decoding;
        },
        c.JXL_DEC_FULL_IMAGE => {
            if (phase != .decoding) return error.DecodeFailed;
            phase = .complete;
            // The still-image contract displays the first complete frame.
            c.JxlDecoderSkipFrames(session.decoder, std.math.maxInt(usize));
        },
        c.JXL_DEC_SUCCESS => {
            if (phase != .complete) return error.IncompleteImage;
            if (!file.unchanged()) return error.SourceChanged;
            owned = null;
            return .{ .decoded = decoded, .opaque_source = header.opaque_source, .gray_source = header.gray };
        },
        else => return error.DecodeFailed,
    };
}
