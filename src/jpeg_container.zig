//! Allocation-free JPEG container completeness checks (ITU-T T.81, annex B).
//! ImageIO can report truncated entropy data as complete and return black pixels.
//! This walks marker boundaries, not Huffman samples; ImageIO remains the decoder.
const std = @import("std");
const n = @import("runtime");
const Failure = error{ IncompleteImage, DecodeFailed, UnreadableImage };

const Reader = struct {
    fd: ?c_int = null,
    size: usize,
    position: usize = 0,
    base: usize = 0,
    bytes: []const u8 = &.{},
    buffer: [32 * 1024]u8 = undefined,

    fn available(self: *Reader) Failure![]const u8 {
        if (self.position >= self.size) return error.IncompleteImage;
        if (self.position < self.base or self.position - self.base >= self.bytes.len) {
            const fd = self.fd orelse return error.IncompleteImage;
            const count = while (true) {
                const result = n.pread(fd, &self.buffer, @min(self.buffer.len, self.size - self.position), @intCast(self.position));
                if (result < 0 and n.errno().* == 4) continue; // EINTR
                break result;
            };
            if (count < 0) return error.UnreadableImage;
            if (count == 0) return error.IncompleteImage;
            self.base = self.position;
            self.bytes = self.buffer[0..@intCast(count)];
        }
        return self.bytes[self.position - self.base ..];
    }
    fn byte(self: *Reader) Failure!u8 {
        const value = (try self.available())[0];
        self.position += 1;
        return value;
    }
    fn skip(self: *Reader, count: usize) Failure!void {
        if (count > self.size - self.position) return error.IncompleteImage;
        self.position += count;
    }
    fn marker(self: *Reader, entropy: bool) Failure!u8 {
        while (true) {
            if (entropy) {
                const bytes = try self.available();
                self.position += std.mem.indexOfScalar(u8, bytes, 0xff) orelse {
                    self.position += bytes.len;
                    continue;
                };
            }
            if (try self.byte() != 0xff) return error.DecodeFailed;
            var code = try self.byte();
            while (code == 0xff) code = try self.byte(); // marker fill bytes
            if (entropy and (code == 0 or (code >= 0xd0 and code <= 0xd7))) continue;
            if (code == 0 or (code >= 0xd0 and code <= 0xd7)) return error.DecodeFailed;
            return code;
        }
    }
};

fn walk(reader: *Reader) Failure!void {
    if (try reader.byte() != 0xff or try reader.byte() != 0xd8) return error.DecodeFailed;
    var entropy = false;
    var saw_scan = false;
    while (true) {
        const marker = try reader.marker(entropy);
        if (marker == 0xd9) return if (saw_scan) {} else error.DecodeFailed;
        if (marker == 0xd8) return error.DecodeFailed;
        if (marker == 0x01) continue; // stand-alone TEM marker
        const length = @as(usize, try reader.byte()) * 256 + try reader.byte();
        if (length < 2) return error.DecodeFailed;
        try reader.skip(length - 2);
        if (marker == 0xda) {
            if (length < 6) return error.DecodeFailed;
            saw_scan = true;
            entropy = true;
        } else entropy = false;
    }
}

pub fn validate(fd: c_int, size: usize) Failure!void {
    var reader: Reader = .{ .fd = fd, .size = size };
    try walk(&reader);
}
fn validateBytes(bytes: []const u8) Failure!void {
    var reader: Reader = .{ .size = bytes.len, .bytes = bytes };
    try walk(&reader);
}

test "JPEG completeness skips embedded EOI, accepts scan boundaries and trailers" {
    // APP payload contains a fake EOI. Entropy contains stuffing and a restart.
    const first = "\xff\xd8\xff\xe1\x00\x04\xff\xd9\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x12\xff\x00\x34\xff\xd0\x56";
    const last = "\xff\xc4\x00\x02\xff\xda\x00\x08\x01\x01\x00\x01\x3f\x00\x78\xff\xff\xd9";
    try validateBytes(first ++ last ++ "trailing data");
    for (2..first.len + last.len) |end| try std.testing.expectError(error.IncompleteImage, validateBytes((first ++ last)[0..end]));
    try std.testing.expectError(error.DecodeFailed, validateBytes("\xff\xd8\xff\xe1\x00\x01"));
    try std.testing.expectError(error.DecodeFailed, validateBytes("\xff\xd8\xff\xd9"));
}
