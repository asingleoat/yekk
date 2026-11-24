//! Shared source identity for reload, publication, hooks and link operations.
const c = @import("system");
const runtime = @import("runtime");
const files = runtime.files;
pub const Stamp = struct {
    device: u64 = 0,
    inode: u64 = 0,
    bytes: i64 = 0,
    seconds: i64 = 0,
    nanoseconds: i64 = 0,
    pub fn read(path: [:0]const u8) ?Stamp {
        var stat: c.struct_stat = undefined;
        if (files.stat(path.ptr, &stat) != 0) return null;
        return fromStat(stat);
    }
    pub fn readLink(path: [:0]const u8) ?Stamp {
        var stat: c.struct_stat = undefined;
        if (files.lstat(path.ptr, &stat) != 0) return null;
        return fromStat(stat);
    }
    pub fn fromStat(stat: c.struct_stat) Stamp {
        const modified = if (runtime.darwin) stat.st_mtimespec else stat.st_mtim;
        return .{ .device = if (runtime.darwin) @as(u32, @bitCast(stat.st_dev)) else stat.st_dev, .inode = stat.st_ino, .bytes = stat.st_size, .seconds = modified.tv_sec, .nanoseconds = modified.tv_nsec };
    }
};
pub fn exists(path: []const u8) bool {
    const std = @import("std");
    var buffer: [4096]u8 = undefined;
    const terminated = std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0) catch return false;
    var stat: c.struct_stat = undefined;
    return files.stat(terminated.ptr, &stat) == 0 or (runtime.errno().* != c.ENOENT and runtime.errno().* != c.ENOTDIR);
}

pub const Format = union(enum) { other, tiff, pnm, png, jpeg, jxl, raw, bmp: @import("bmp").Header };
pub const raw_suffixes = .{ ".arw", ".sr2", ".srf", ".cr2", ".cr3", ".crw", ".nef", ".nrw", ".raf", ".dng", ".orf", ".rw2", ".pef", ".srw" };
pub fn rawCandidate(path: []const u8) bool {
    const std = @import("std");
    const extension = std.fs.path.extension(path);
    inline for (raw_suffixes) |suffix| if (std.ascii.eqlIgnoreCase(extension, suffix)) return true;
    return false;
}
pub const exifOrientation = @import("exif.zig").orientation;
pub const describeExif = @import("exif.zig").describe;
pub const composeOrientation = @import("exif.zig").compose;
pub const normalizeExif = @import("exif.zig").normalizeOrientation;
pub const Orientation = @import("exif.zig").Orientation;
pub const Range = struct {
    file: Open,
    offset: u64,
    length: usize,
    pub fn readAt(self: Range, output: []u8, offset: u64) Error!usize {
        if (offset >= self.length) return 0;
        return self.file.readAt(output[0..@min(output.len, self.length - @as(usize, @intCast(offset)))], self.offset + offset);
    }
};
pub const Open = struct {
    format: Format = .other,
    fd: c_int,
    stamp: Stamp,
    pub fn bmp(self: Open) ?@import("bmp").Header {
        return switch (self.format) {
            .bmp => |header| header,
            else => null,
        };
    }
    pub fn close(self: Open) void {
        _ = c.close(self.fd);
    }
    pub fn readAt(self: Open, output: []u8, offset: u64) Error!usize {
        if (offset >= @as(u64, @intCast(self.stamp.bytes))) return 0;
        const length = @min(output.len, @as(u64, @intCast(self.stamp.bytes)) - offset);
        while (true) {
            const count = runtime.pread(self.fd, output.ptr, length, @intCast(offset));
            if (count < 0 and runtime.errno().* == c.EINTR) continue;
            if (count < 0) return error.UnreadableImage;
            return @intCast(count);
        }
    }
    pub fn unchanged(self: Open) bool {
        var stat: c.struct_stat = undefined;
        return files.fstat(self.fd, &stat) == 0 and @import("std").meta.eql(self.stamp, Stamp.fromStat(stat));
    }
};
pub const Error = error{ UnreadableImage, IncompleteImage, DecodeFailed, InvalidDimensions, SizeOverflow };
/// Validate source kind and container completeness before invoking any decoder.
/// Native libraries still validate their complete format-specific contents.
pub fn open(path: [:0]const u8, completeness: bool) Error!Open {
    const std = @import("std");
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.UnreadableImage;
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return error.UnreadableImage;
    errdefer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (files.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size < 2) return error.UnreadableImage;
    var signature: [8]u8 = undefined;
    const count = runtime.pread(fd, &signature, signature.len, 0);
    if (count < 2) return error.UnreadableImage;
    if (count == signature.len and std.mem.eql(u8, &signature, "\x89PNG\r\n\x1a\n")) {
        var tail: [12]u8 = undefined;
        if (stat.st_size < 20 or runtime.pread(fd, &tail, tail.len, stat.st_size - 12) != tail.len or !std.mem.eql(u8, &tail, "\x00\x00\x00\x00IEND\xae\x42\x60\x82")) return error.IncompleteImage;
    } else if (completeness and signature[0] == 0xff and signature[1] == 0xd8) {
        try @import("jpeg_container.zig").validate(fd, @intCast(stat.st_size));
    }
    var format: Format = .other;
    if (count == 8 and std.mem.eql(u8, &signature, "\x89PNG\r\n\x1a\n")) format = .png;
    if (signature[0] == 0xff and signature[1] == 0xd8) format = .jpeg;
    if (count >= 4 and (std.mem.eql(u8, signature[0..4], "II\x2a\x00") or std.mem.eql(u8, signature[0..4], "MM\x00\x2a") or std.mem.eql(u8, signature[0..4], "II\x2b\x00") or std.mem.eql(u8, signature[0..4], "MM\x00\x2b"))) format = .tiff;
    if ((signature[0] == 0xff and signature[1] == 0x0a) or (count == 8 and std.mem.eql(u8, &signature, "\x00\x00\x00\x0cJXL "))) format = .jxl;
    if (signature[0] == 'P' and signature[1] >= '1' and signature[1] <= '6') format = .pnm;
    if (signature[0] == 'B' and signature[1] == 'M') {
        var header: [138]u8 = undefined;
        const length = runtime.pread(fd, &header, header.len, 0);
        if (length < 0) return error.UnreadableImage;
        format = .{ .bmp = try @import("bmp").Header.read(header[0..@intCast(length)], @intCast(stat.st_size)) };
    }
    if ((format == .other or format == .tiff) and rawCandidate(path)) format = .raw;
    return .{ .fd = fd, .stamp = Stamp.fromStat(stat), .format = format };
}

test "existence accepts a borrowed path slice without sentinel storage" {
    const std = @import("std");
    const original = "tests/fixtures/gray16.png extra";
    const path = original[0.."tests/fixtures/gray16.png".len];
    try std.testing.expect(exists(path));
    try std.testing.expect(!exists("tests/fixtures/does-not-exist.png"));
}
