//! Sequential JPEG Huffman decoding. libjpeg-turbo retains marker validation,
//! integer IDCT, upsampling and color output. Lookup entries combine a Huffman
//! symbol and its signed amplitude, avoiding a second decode for common values.
const std = @import("std");
const c = @import("jpeg_bindings");
const Bits = if (@import("builtin").cpu.arch == .aarch64) 12 else 10;
pub const padding = 8;
pub const Failure = error{ DecodeFailed, Cancelled };
// The two private prefixes below are audited against the pinned 3.2.0 source.
// Other dependency versions use TurboJPEG unchanged. Public structs and function
// signatures come from translate-c, including the memory-manager callback.
pub const supported_abi = c.LIBJPEG_TURBO_VERSION_NUMBER == 3002000 and c.JPEG_LIB_VERSION == 62;
const EntropyPrefix = extern struct {
    start_pass: ?*const fn (c.j_decompress_ptr) callconv(.c) void,
    decode_mcu: ?*const fn (c.j_decompress_ptr, [*c]c.JBLOCKROW) callconv(.c) c.boolean,
};
fn entropy(info: *c.struct_jpeg_decompress_struct) *EntropyPrefix {
    return @ptrCast(@alignCast(info.entropy));
}
const Entry = extern struct { value: i16 = 0, used: u8 = 0, step: u8 = 0 };
const Short = extern struct { symbol: u8 = 0, used: u8 = 0 };
const Huffman = struct {
    short: [256]Short,
    first: [17]u32,
    count: [17]u32,
    index: [17]u32,
    values: [256]u8,
    fn init(self: *Huffman, table: *const c.JHUFF_TBL) !void {
        @memset(&self.short, .{});
        self.first = @splat(0);
        self.count = @splat(0);
        self.index = @splat(0);
        self.values = table.huffval;
        var code: u32 = 0;
        var at: u32 = 0;
        for (1..17) |n| {
            const count: u32 = table.bits[n];
            if (code + count >= (@as(u32, 1) << @intCast(n)) and count != 0 or at + count > 256) return error.InvalidTable;
            self.first[n] = code;
            self.count[n] = count;
            self.index[n] = at;
            if (n <= 8) for (0..count) |i| {
                const start = (code + i) << @intCast(8 - n);
                const span = @as(usize, 1) << @intCast(8 - n);
                @memset(self.short[start..][0..span], .{ .symbol = table.huffval[at + i], .used = @intCast(n) });
            };
            at += count;
            code = (code + count) << 1;
        }
    }
    inline fn decode(self: *const Huffman, reader: *Reader) !u8 {
        try reader.ensure();
        const short = self.short[reader.peek(8)];
        if (short.used != 0) {
            reader.skip(short.used);
            return short.symbol;
        }
        const look = reader.peek(16);
        for (9..17) |n| {
            const value: u32 = @intCast(look >> @intCast(16 - n));
            const first = self.first[n];
            if (value >= first and value - first < self.count[n]) {
                reader.skip(@intCast(n));
                return self.values[self.index[n] + value - first];
            }
        }
        return error.InvalidCode;
    }
};
const AcTable = struct {
    huff: Huffman,
    fast: [1 << Bits]Entry,
    fn init(self: *AcTable, table: *const c.JHUFF_TBL) !void {
        try self.huff.init(table);
        @memset(&self.fast, .{});
        for (1..17) |n| {
            const count = self.huff.count[n];
            for (0..count) |i| {
                const code = self.huff.first[n] + i;
                const symbol = self.huff.values[self.huff.index[n] + i];
                const size = symbol & 15;
                const run = symbol >> 4;
                if (size > 10 or (size == 0 and run != 0 and run != 15)) return error.InvalidTable;
                if (n + size > Bits) continue;
                for (0..@as(usize, 1) << @intCast(size)) |magnitude| {
                    const prefix = (code << @intCast(size)) | magnitude;
                    const start = prefix << @intCast(Bits - n - size);
                    const span = @as(usize, 1) << @intCast(Bits - n - size);
                    const entry: Entry = .{ .value = extend(@intCast(magnitude), size), .used = @intCast(n + size), .step = if (size != 0) run + 1 else if (run == 15) 16 else 0 };
                    @memset(self.fast[start..][0..span], entry);
                }
            }
        }
    }
    inline fn decode(self: *const AcTable, reader: *Reader) !Entry {
        try reader.ensure();
        const entry = self.fast[reader.peek(Bits)];
        if (entry.used != 0) {
            reader.skip(entry.used);
            return entry;
        }
        const symbol = try self.huff.decode(reader);
        const size = symbol & 15;
        const run = symbol >> 4;
        if (size > 10) return error.InvalidCode;
        if (size == 0) {
            if (run != 0 and run != 15) return error.InvalidCode;
            return .{ .step = if (run == 15) 16 else 0 };
        }
        return .{ .value = try reader.receive(size), .step = run + 1 };
    }
};
const Reader = struct {
    input: []const u8,
    at: usize = 0,
    bits: u64 = 0,
    left: u8 = 0,
    inline fn ensure(self: *Reader) !void {
        if (self.left >= 32) return;
        if (self.at > self.input.len + 4) return error.EndOfBits;
        const remaining = self.input.len -| self.at;
        const word = if (remaining >= 4) std.mem.readInt(u32, self.input[self.at..][0..4], .big) else tail: {
            var bytes: [4]u8 = @splat(0);
            if (remaining != 0) @memcpy(bytes[0..remaining], self.input[self.at..]);
            break :tail std.mem.readInt(u32, &bytes, .big);
        };
        self.bits |= @as(u64, word) << @intCast(32 - self.left);
        // at counts virtual zero padding as well. Bound the consumed bit count
        // after every MCU so truncated streams cannot become valid pixels.
        self.at += 4;
        self.left += 32;
    }
    inline fn peek(self: Reader, comptime n: usize) usize {
        return @intCast(self.bits >> (64 - n));
    }
    inline fn skip(self: *Reader, n: u8) void {
        self.bits <<= @intCast(n);
        self.left -= n;
    }
    inline fn receive(self: *Reader, n: u8) !i16 {
        if (n == 0) return 0;
        if (n > 11) return error.InvalidCode;
        try self.ensure();
        const value: u16 = @intCast(self.bits >> @intCast(64 - n));
        self.skip(n);
        return extend(value, n);
    }
};
inline fn extend(value: u16, n: u8) i16 {
    if (n == 0) return 0;
    const threshold = @as(u16, 1) << @intCast(n - 1);
    return @intCast(if (value >= threshold) @as(i32, value) else @as(i32, value) + 1 - (@as(i32, 1) << @intCast(n)));
}
const natural = [64]u8{ 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 };
const Block = struct { component: usize, dc: *const Huffman, ac: *const AcTable };
const State = struct {
    reader: Reader,
    entropy_bytes: usize,
    dc: [4]Huffman,
    ac: [4]AcTable,
    blocks: [10]Block,
    block_count: usize,
    remaining_mcus: u64,
    previous: [4]i32 = @splat(0),
    fn init(self: *State, info: *c.struct_jpeg_decompress_struct, scratch: []u8) !void {
        if (info.progressive_mode != 0 or info.arith_code != 0 or info.data_precision != 8 or info.restart_interval != 0 or info.comps_in_scan != info.num_components or (info.num_components != 1 and info.num_components != 3) or info.Ss != 0 or info.Se != 63 or info.Ah != 0 or info.Al != 0) return error.UnsupportedLayout;
        if (info.blocks_in_MCU < 1 or info.blocks_in_MCU > 10) return error.InvalidLayout;
        self.block_count = @intCast(info.blocks_in_MCU);
        self.remaining_mcus = @as(u64, info.MCUs_per_row) * info.MCU_rows_in_scan;
        if (self.remaining_mcus == 0) return error.InvalidLayout;
        self.previous = @splat(0);
        var dc_ready: [4]bool = @splat(false);
        var ac_ready: [4]bool = @splat(false);
        for (0..self.block_count) |i| {
            const membership = info.MCU_membership[i];
            if (membership < 0 or membership >= info.comps_in_scan or membership >= 4) return error.InvalidLayout;
            const ci: usize = @intCast(membership);
            const component = info.cur_comp_info[ci];
            if (component == null or component.*.dc_tbl_no < 0 or component.*.ac_tbl_no < 0) return error.InvalidTable;
            const dc_index: usize = @intCast(component.*.dc_tbl_no);
            const ac_index: usize = @intCast(component.*.ac_tbl_no);
            if (dc_index >= 4 or ac_index >= 4 or info.dc_huff_tbl_ptrs[dc_index] == null or info.ac_huff_tbl_ptrs[ac_index] == null) return error.InvalidTable;
            if (!dc_ready[dc_index]) {
                try self.dc[dc_index].init(@ptrCast(info.dc_huff_tbl_ptrs[dc_index]));
                dc_ready[dc_index] = true;
            }
            if (!ac_ready[ac_index]) {
                try self.ac[ac_index].init(@ptrCast(info.ac_huff_tbl_ptrs[ac_index]));
                ac_ready[ac_index] = true;
            }
            self.blocks[i] = .{ .component = ci, .dc = &self.dc[dc_index], .ac = &self.ac[ac_index] };
        }
        const src = info.src;
        const input = src.*.next_input_byte[0..src.*.bytes_in_buffer];
        if (input.len > scratch.len - padding or input.ptr != scratch.ptr) return error.InvalidLayout;
        var read: usize = 0;
        var written: usize = 0;
        while (read < input.len) {
            if (read & 0xffff == 0) try checkCancel(@as(*Hook, @ptrCast(@alignCast(info.client_data.?))).cancel);
            if (input.len - read >= 8) {
                const word = std.mem.readInt(u64, input[read..][0..8], .little);
                const inv = ~word;
                if (((inv -% 0x0101010101010101) & ~inv & 0x8080808080808080) == 0) {
                    std.mem.writeInt(u64, scratch[written..][0..8], word, .little);
                    read += 8;
                    written += 8;
                    continue;
                }
            }
            const value = input[read];
            if (value != 255) {
                scratch[written] = value;
                written += 1;
                read += 1;
                continue;
            }
            if (read + 1 >= input.len) return error.MissingMarker;
            if (input[read + 1] == 0) {
                scratch[written] = 255;
                written += 1;
                read += 2;
                continue;
            }
            var marker = read + 1;
            while (marker < input.len and input[marker] == 255) marker += 1;
            if (marker >= input.len or input[marker] == 0 or (input[marker] >= 0xd0 and input[marker] <= 0xd7)) return error.InvalidMarker;
            self.entropy_bytes = written;
            // Padding may overlap the marker only after compaction. Save it
            // first; the native marker reader continues from the original tail.
            const marker_code = input[marker];
            const tail = marker + 1;
            // Keep the marker tail intact: tiny scans may not free eight bytes.
            // Reader pads its final word instead of reading past entropy bytes.
            self.reader = .{ .input = scratch[0..written] };
            src.*.next_input_byte += tail;
            src.*.bytes_in_buffer -= tail;
            info.unread_marker = marker_code;
            return;
        }
        return error.MissingMarker;
    }
    fn decode(self: *State, blocks: [*c]c.JBLOCKROW) !void {
        if (blocks == null) return error.NullBlocks;
        var reader = self.reader;
        for (self.blocks[0..self.block_count], 0..) |block, index| {
            if (blocks[index] == null) return error.NullBlock;
            const destination: *[64]i16 = @ptrCast(blocks[index]);
            const size = try block.dc.decode(&reader);
            const delta = try reader.receive(size);
            const dc = try std.math.add(i32, self.previous[block.component], delta);
            if (dc < std.math.minInt(i16) or dc > std.math.maxInt(i16)) return error.InvalidDc;
            self.previous[block.component] = dc;
            destination[0] = @intCast(dc);
            var k: usize = 1;
            while (k < 64) {
                const entry = try block.ac.decode(&reader);
                if (entry.step == 0) break;
                if (entry.value == 0) {
                    k += 16;
                    if (k > 64) return error.InvalidRun;
                } else {
                    k += entry.step - 1;
                    if (k >= 64) return error.InvalidRun;
                    destination[natural[k]] = entry.value;
                    k += 1;
                }
            }
        }
        if (reader.at - reader.left / 8 > self.entropy_bytes) return error.EndOfBits;
        if (self.remaining_mcus == 0) return error.InvalidLayout;
        self.remaining_mcus -= 1;
        if (self.remaining_mcus == 0 and reader.at - reader.left / 8 != self.entropy_bytes) return error.ExcessEntropy;
        self.reader = reader;
    }
};
const TurboPrefix = extern struct { cinfo: c.struct_jpeg_compress_struct, dinfo: c.struct_jpeg_decompress_struct };
const Hook = struct {
    state: State = undefined,
    info: *c.struct_jpeg_decompress_struct,
    original: @FieldType(c.struct_jpeg_memory_mgr, "alloc_small"),
    client: ?*anyopaque,
    input: []u8,
    cancel: ?*const std.atomic.Value(bool),
    attached: bool = false,
    failure: ?Failure = null,
    original_decode: @FieldType(EntropyPrefix, "decode_mcu") = null,
    scan: c_int = 0,
    fn allocate(raw: c.j_common_ptr, pool: c_int, size: usize) callconv(.c) ?*anyopaque {
        const info: *c.struct_jpeg_decompress_struct = @ptrCast(raw);
        const self: *Hook = @ptrCast(@alignCast(info.client_data.?));
        const result = self.original.?(raw, pool, size);
        if (info.entropy != null and info.blocks_in_MCU > 0) {
            info.mem.*.alloc_small = self.original;
            const start = @intFromPtr(info.src.*.next_input_byte);
            const base = @intFromPtr(self.input.ptr);
            if (start < base or start - base > self.input.len - padding or info.src.*.bytes_in_buffer > self.input.len - padding - (start - base)) self.fatal(error.DecodeFailed);
            self.state.init(info, self.input[start - base ..]) catch |err| self.fatal(if (err == error.Cancelled) error.Cancelled else error.DecodeFailed);
            self.original_decode = entropy(info).decode_mcu;
            self.scan = info.input_scan_number;
            entropy(info).decode_mcu = Hook.decode;
            self.attached = true;
        }
        return result;
    }
    fn fatal(self: *Hook, failure: Failure) noreturn {
        self.failure = failure;
        self.info.err.*.msg_code = c.JERR_BAD_HUFF_TABLE;
        // Called only within tj3Decompress8's C error boundary. No Zig-owned
        // resources or defers live in these callback frames.
        self.info.err.*.error_exit.?(@ptrCast(self.info));
        unreachable;
    }
    fn decode(raw: c.j_decompress_ptr, blocks: [*c]c.JBLOCKROW) callconv(.c) c.boolean {
        const info: *c.struct_jpeg_decompress_struct = @ptrCast(raw);
        const self: *Hook = @ptrCast(@alignCast(info.client_data.?));
        checkCancel(self.cancel) catch self.fatal(error.Cancelled);
        if (info.input_scan_number != self.scan) {
            // A later scan has new native DC/bit state and native table setup.
            entropy(info).decode_mcu = self.original_decode;
            return self.original_decode.?(raw, blocks);
        }
        self.state.decode(blocks) catch self.fatal(error.DecodeFailed);
        return 1;
    }
};
fn eligible(info: *const c.struct_jpeg_decompress_struct) bool {
    return info.progressive_mode == 0 and info.arith_code == 0 and info.data_precision == 8 and info.restart_interval == 0 and info.comps_in_scan == info.num_components and (info.num_components == 1 or info.num_components == 3) and info.Ss == 0 and info.Se == 63 and info.Ah == 0 and info.Al == 0;
}
fn checkCancel(cancel: ?*const std.atomic.Value(bool)) Failure!void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
}
/// input owns padding writable bytes beyond length. The file itself is never
/// modified. Returns whether the Zig Huffman path was used.
pub fn decode(handle: c.tjhandle, input: []u8, length: usize, output: []u8, width: u32, height: u32, format: c_int, cancel: ?*const std.atomic.Value(bool), fast: bool) Failure!bool {
    try checkCancel(cancel);
    if (length > input.len or input.len - length < padding) return error.DecodeFailed;
    if (fast and supported_abi) {
        const prefix: *TurboPrefix = @ptrCast(@alignCast(handle.?));
        const info = &prefix.dinfo;
        if (info.image_width != width or info.image_height != height) return error.DecodeFailed;
        if (eligible(info)) {
            var hook: Hook = .{ .info = info, .original = info.mem.*.alloc_small, .client = info.client_data, .input = input, .cancel = cancel };
            info.client_data = &hook;
            info.mem.*.alloc_small = Hook.allocate;
            defer {
                // entropy belongs to the image pool, which finish/abort frees.
                // mem and client_data belong to the still-live decompressor.
                info.mem.*.alloc_small = hook.original;
                info.client_data = hook.client;
            }
            const status = c.tj3Decompress8(handle, input.ptr, length, output.ptr, 0, format);
            if (hook.failure) |failure| return failure;
            if (status != 0) return error.DecodeFailed;
            try checkCancel(cancel);
            return hook.attached;
        }
    }
    if (c.tj3Decompress8(handle, input.ptr, length, output.ptr, 0, format) != 0) return error.DecodeFailed;
    try checkCancel(cancel);
    return false;
}

const TestPixels = struct {
    pixels: []u8,
    attached: bool,
    fn deinit(self: TestPixels) void {
        std.testing.allocator.free(self.pixels);
    }
};
fn testDecode(bytes: []const u8, fast: bool) !TestPixels {
    const input = try std.testing.allocator.alloc(u8, bytes.len + padding);
    defer std.testing.allocator.free(input);
    @memcpy(input[0..bytes.len], bytes);
    const handle = c.tj3Init(c.TJINIT_DECOMPRESS) orelse return error.OutOfMemory;
    defer c.tj3Destroy(handle);
    if (c.tj3Set(handle, c.TJPARAM_STOPONWARNING, 1) != 0) return error.DecodeFailed;
    if (@hasDecl(c, "TJPARAM_SAVEMARKERS")) if (c.tj3Set(handle, c.TJPARAM_SAVEMARKERS, 0) != 0) return error.DecodeFailed;
    if (c.tj3DecompressHeader(handle, input.ptr, bytes.len) != 0) return error.DecodeFailed;
    const width = c.tj3Get(handle, c.TJPARAM_JPEGWIDTH);
    const height = c.tj3Get(handle, c.TJPARAM_JPEGHEIGHT);
    // Test mutations must not allocate an arbitrary size from corrupted SOF.
    if (width < 1 or height < 1 or width > 512 or height > 512) return error.DecodeFailed;
    const output = try std.testing.allocator.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4);
    errdefer std.testing.allocator.free(output);
    const attached = try decode(handle, input, bytes.len, output, @intCast(width), @intCast(height), c.TJPF_RGBA, null, fast);
    return .{ .pixels = output, .attached = attached };
}
fn testJpeg(width: c_int, height: c_int, subsampling: c_int, quality: c_int, progressive: bool, restart: bool) ![]u8 {
    const rgb = try std.testing.allocator.alloc(u8, @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 3);
    defer std.testing.allocator.free(rgb);
    var random = std.Random.DefaultPrng.init(42);
    random.random().bytes(rgb);
    const handle = c.tj3Init(c.TJINIT_COMPRESS) orelse return error.OutOfMemory;
    defer c.tj3Destroy(handle);
    if (c.tj3Set(handle, c.TJPARAM_QUALITY, quality) != 0 or c.tj3Set(handle, c.TJPARAM_SUBSAMP, subsampling) != 0 or c.tj3Set(handle, c.TJPARAM_OPTIMIZE, 1) != 0 or c.tj3Set(handle, c.TJPARAM_PROGRESSIVE, @intFromBool(progressive)) != 0 or c.tj3Set(handle, c.TJPARAM_RESTARTBLOCKS, if (restart) 1 else 0) != 0) return error.EncodeFailed;
    var bytes: [*c]u8 = null;
    var length: usize = 0;
    if (c.tj3Compress8(handle, rgb.ptr, width, 0, height, c.TJPF_RGB, &bytes, &length) != 0) return error.EncodeFailed;
    defer c.tj3Free(bytes);
    return std.testing.allocator.dupe(u8, bytes[0..length]);
}
test "Huffman path matches TurboJPEG across MCU edges, tables, sampling and fallback variants" {
    for ([_]c_int{ 1, 7, 8, 15, 16, 17, 63, 257 }) |width| {
        for ([_]c_int{ c.TJSAMP_444, c.TJSAMP_422, c.TJSAMP_420, c.TJSAMP_GRAY }) |sampling| {
            for ([_]c_int{ 25, 75, 95 }) |quality| {
                const bytes = try testJpeg(width, 19, sampling, quality, false, false);
                defer std.testing.allocator.free(bytes);
                const stock = try testDecode(bytes, false);
                defer stock.deinit();
                const fast = try testDecode(bytes, true);
                defer fast.deinit();
                try std.testing.expectEqual(supported_abi, fast.attached);
                try std.testing.expectEqualSlices(u8, stock.pixels, fast.pixels);
            }
        }
    }
    for ([_]bool{ false, true }) |progressive| {
        const bytes = try testJpeg(63, 19, c.TJSAMP_420, 90, progressive, !progressive);
        defer std.testing.allocator.free(bytes);
        const stock = try testDecode(bytes, false);
        defer stock.deinit();
        const fast = try testDecode(bytes, true);
        defer fast.deinit();
        try std.testing.expect(!fast.attached);
        try std.testing.expectEqualSlices(u8, stock.pixels, fast.pixels);
    }
}
test "damaged JPEG tables and entropy remain contained by the C error boundary" {
    const original = try testJpeg(17, 19, c.TJSAMP_420, 90, false, false);
    defer std.testing.allocator.free(original);
    const bytes = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(bytes);
    // Change each byte, including marker lengths, code counts, amplitudes and
    // the entropy tail. If the vendor accepts it, pixels must still agree.
    for (0..bytes.len) |at| {
        @memcpy(bytes, original);
        bytes[at] ^= 0xff;
        const stock = testDecode(bytes, false) catch {
            if (testDecode(bytes, true)) |result| {
                result.deinit();
                return error.AcceptedVendorRejectedJpeg;
            } else |_| {}
            continue;
        };
        defer stock.deinit();
        const fast = testDecode(bytes, true) catch continue;
        defer fast.deinit();
        try std.testing.expectEqualSlices(u8, stock.pixels, fast.pixels);
    }
    for (2..original.len) |length| {
        if (testDecode(original[0..length], true)) |result| {
            result.deinit();
            return error.AcceptedTruncatedJpeg;
        } else |_| {}
    }
}
