//! Temporary downloads live for the process, including when several windows
//! share a file. Remote names are kept separate from paths used for decoding.
const std = @import("std");
const c = @import("system");
const runtime = @import("runtime");

pub const Options = struct {
    keep_in: ?[:0]const u8 = null,
    insecure: bool = false,
    refresh_on_revisit: bool = false,
};
pub const Transfer = *const fn ([:0]const u8, c_int, bool, ?*const std.atomic.Value(bool)) anyerror!void;

pub fn isUrl(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "https://") or std.mem.startsWith(u8, path, "http://");
}
fn leaf(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return "image";
    const tail = url[scheme + 3 ..];
    const end = std.mem.indexOfAny(u8, tail, "?#") orelse tail.len;
    const name = if (std.mem.lastIndexOfScalar(u8, tail[0..end], '/')) |slash| tail[slash + 1 .. end] else "";
    if (name.len == 0 or name.len > 200 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return "image";
    for (name) |byte| if (byte < 32 or byte == 127) return "image";
    return name;
}

pub const Session = struct {
    transfer: Transfer,
    work_dir_lock: std.atomic.Mutex = .unlocked,
    directory: [4096]u8 = undefined,
    length: usize = 0,
    next: std.atomic.Value(usize) = .init(0),

    pub fn workDir(self: *Session) ![:0]const u8 {
        while (!self.work_dir_lock.tryLock()) _ = c.poll(null, 0, 1);
        defer self.work_dir_lock.unlock();
        if (self.length == 0) {
            const env = c.getenv("TMPDIR");
            const base = if (env != null and std.fs.path.isAbsolute(std.mem.span(env))) std.mem.span(env) else "/tmp";
            const path = try std.fmt.bufPrintSentinel(&self.directory, "{s}/yekk-http-XXXXXX", .{base}, 0);
            if (c.mkdtemp(path.ptr) == null) return error.DownloadDirectoryFailed;
            self.length = path.len;
        }
        return self.directory[0..self.length :0];
    }
    pub fn uniqueNumber(self: *Session) usize {
        return self.next.fetchAdd(1, .monotonic);
    }

    pub fn fetch(self: *Session, output: []u8, url: [:0]const u8, options: Options, cancel: ?*const std.atomic.Value(bool)) ![:0]const u8 {
        const keep = options.keep_in != null;
        const directory = options.keep_in orelse try self.workDir();
        const number = self.uniqueNumber();
        const path = try std.fmt.bufPrintSentinel(output, "{s}/feh_{d}_{d:0>6}_{s}", .{ directory, c.getpid(), number, leaf(url) }, 0);
        try self.download(url, path, directory, keep, options.insecure, cancel);
        return path;
    }

    pub fn refresh(self: *const Session, url: [:0]const u8, path: [:0]const u8, options: Options, cancel: *const std.atomic.Value(bool)) !void {
        try self.download(url, path, std.fs.path.dirname(path) orelse ".", false, options.insecure, cancel);
    }

    fn download(self: *const Session, url: [:0]const u8, path: [:0]const u8, directory: []const u8, exclusive: bool, insecure: bool, cancel: ?*const std.atomic.Value(bool)) !void {
        var buffer: [4096]u8 = undefined;
        const temp = try std.fmt.bufPrintSentinel(&buffer, "{s}/.yekk-http-XXXXXX", .{directory}, 0);
        const fd = c.mkstemp(temp.ptr);
        if (fd < 0) return error.DownloadFileFailed;
        var open = true;
        defer if (open) {
            _ = c.close(fd);
        };
        defer _ = c.unlink(temp.ptr);
        if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) == -1) return error.DownloadFileFailed;
        try self.transfer(url, fd, insecure, cancel);
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        const closed = c.close(fd);
        open = false;
        if (closed != 0) return error.DownloadFileFailed;
        if (exclusive) {
            if (c.link(temp.ptr, path.ptr) != 0) return error.DownloadFileFailed;
        } else if (c.rename(temp.ptr, path.ptr) != 0) return error.DownloadFileFailed;
    }

    pub fn deinit(self: *Session) void {
        if (self.length == 0) return;
        const path = self.directory[0..self.length :0];
        if (runtime.files.opendir(path.ptr)) |dir| {
            const fd = c.dirfd(dir);
            while (runtime.files.readdir(dir)) |entry| {
                const name = std.mem.sliceTo(&entry.*.d_name, 0);
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                _ = c.unlinkat(fd, &entry.*.d_name, 0);
            }
            _ = c.closedir(dir);
        }
        _ = c.rmdir(path.ptr);
        self.length = 0;
    }
};
