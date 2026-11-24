//! Names and atomic publication for generated images.
const std = @import("std");
const c = @import("system");
const runtime = @import("runtime");

pub fn temporaryDirectory() [:0]const u8 {
    if (c.getenv("TMPDIR")) |env| {
        const path = std.mem.span(env);
        if (std.fs.path.isAbsolute(path)) return path;
    }
    return "/tmp";
}

pub const Format = enum {
    png,
    jpeg,
    tiff,

    pub fn fromPath(path: []const u8) ?Format {
        const extension = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(extension, ".png")) return .png;
        if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return .jpeg;
        if (std.ascii.eqlIgnoreCase(extension, ".tif") or std.ascii.eqlIgnoreCase(extension, ".tiff")) return .tiff;
        return null;
    }
    fn suffix(self: Format) [:0]const u8 {
        return switch (self) {
            .png => ".png",
            .jpeg => ".jpg",
            .tiff => ".tif",
        };
    }
};
pub const Temporary = struct {
    data: [4096]u8 = undefined,
    len: usize = 0,

    pub fn create(self: *Temporary, directory: []const u8, format: Format) !void {
        const suffix = format.suffix();
        const name = try std.fmt.bufPrintSentinel(&self.data, "{s}/.yekk-image-XXXXXX{s}", .{ directory, suffix }, 0);
        const fd = c.mkstemps(name.ptr, @intCast(suffix.len));
        if (fd < 0) return error.ImageOutputFailed;
        self.len = name.len;
        _ = c.close(fd);
    }
    pub fn path(self: *const Temporary) [:0]const u8 {
        return self.data[0..self.len :0];
    }
    pub fn deinit(self: *const Temporary) void {
        if (self.len > 0) _ = c.unlink(self.path().ptr);
    }
    pub fn replace(self: *const Temporary, destination: [:0]const u8) !void {
        if (c.rename(self.path().ptr, destination.ptr) != 0) return error.ImageOutputFailed;
    }
    pub fn publish(self: *const Temporary, destination: [:0]const u8) !bool {
        const result = if (runtime.darwin)
            c.renamex_np(self.path().ptr, destination.ptr, c.RENAME_EXCL)
        else
            c.renameat2(c.AT_FDCWD, self.path().ptr, c.AT_FDCWD, destination.ptr, c.RENAME_NOREPLACE);
        if (result == 0) return true;
        if (runtime.errno().* == c.EEXIST) return false;
        return error.ImageOutputFailed;
    }
};

var serial: std.atomic.Value(usize) = .init(1);
pub fn saveCopy(directory: [:0]const u8, original: []const u8, context: anytype, encode: anytype) !void {
    // Keep a familiar extension when both native backends can write it.
    const name = std.fs.path.basename(original);
    const original_format = Format.fromPath(name);
    const format = original_format orelse .png;
    const suffix = if (original_format != null) "" else format.suffix();
    var temporary: Temporary = .{};
    try temporary.create(directory, format);
    defer temporary.deinit();
    try encode(context, temporary.path(), format);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const id = serial.fetchAdd(1, .monotonic);
        const destination = try std.fmt.bufPrintSentinel(&buffer, "{s}/feh_{d}_{d:0>6}_{s}{s}", .{ directory, c.getpid(), id, name, suffix }, 0);
        if (try temporary.publish(destination)) return;
    }
}

pub fn editJpeg(path: [:0]const u8, expected: ?@import("source").Stamp, operation: @import("source").Orientation, allocator: std.mem.Allocator) !void {
    const source = @import("source");
    const file = try source.open(path, true);
    defer file.close();
    if (!std.meta.eql(@as(?source.Stamp, file.stamp), expected) or !std.meta.eql(source.Stamp.readLink(path), expected)) return error.SourceChanged;
    const edited = try @import("jpeg").edit(file, operation, allocator);
    defer edited.deinit();
    var temporary: Temporary = .{};
    defer temporary.deinit();
    try temporary.create(std.fs.path.dirname(path) orelse ".", .jpeg);
    var attrs: c.struct_stat = undefined;
    if (runtime.files.fstat(file.fd, &attrs) != 0) return error.SourceChanged;
    const fd = c.open(temporary.path().ptr, c.O_WRONLY | c.O_CLOEXEC);
    if (fd < 0) return error.ImageOutputFailed;
    defer _ = c.close(fd);
    try @import("session_input.zig").writeAll(fd, edited.data[0..edited.len]);
    if (c.fchmod(fd, attrs.st_mode & 0o777) != 0 or c.fsync(fd) != 0) return error.ImageOutputFailed;
    if (!file.unchanged() or !std.meta.eql(source.Stamp.readLink(path), expected)) return error.SourceChanged;
    try temporary.replace(path);
}
