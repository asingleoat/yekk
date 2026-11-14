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

pub const Open = struct {
    fd: c_int,
    stamp: Stamp,
    pub fn close(self: Open) void {
        _ = c.close(self.fd);
    }
};
pub const Error = error{ UnreadableImage, IncompleteImage, DecodeFailed };
/// Validate source kind and container completeness before invoking any decoder.
/// Native libraries still validate their complete format-specific contents.
pub fn open(path: [:0]const u8, completeness: bool) Error!Open {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return error.UnreadableImage;
    errdefer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (files.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size < 2) return error.UnreadableImage;
    var signature: [8]u8 = undefined;
    const count = runtime.pread(fd, &signature, signature.len, 0);
    if (count < 2) return error.UnreadableImage;
    const std = @import("std");
    if (count == signature.len and std.mem.eql(u8, &signature, "\x89PNG\r\n\x1a\n")) {
        var tail: [12]u8 = undefined;
        if (stat.st_size < 20 or runtime.pread(fd, &tail, tail.len, stat.st_size - 12) != tail.len or !std.mem.eql(u8, &tail, "\x00\x00\x00\x00IEND\xae\x42\x60\x82")) return error.IncompleteImage;
    } else if (completeness and signature[0] == 0xff and signature[1] == 0xd8) {
        try @import("jpeg_container.zig").validate(fd, @intCast(stat.st_size));
    }
    return .{ .fd = fd, .stamp = Stamp.fromStat(stat) };
}

test "existence accepts a borrowed path slice without sentinel storage" {
    const std = @import("std");
    const original = "tests/fixtures/gray16.png extra";
    const path = original[0.."tests/fixtures/gray16.png".len];
    try std.testing.expect(exists(path));
    try std.testing.expect(!exists("tests/fixtures/does-not-exist.png"));
}
