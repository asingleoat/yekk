//! One startup-owned catalog. Build only on the indexing worker; publish once.
const std = @import("std");
const c = @import("system");
const runtime = @import("runtime");
const files = runtime.files;
pub const capacity = 16384;
pub const Entry = struct { path: [:0]const u8, id: usize, mtime: i128 = 0, bytes: i64 = 0 };
pub const Sort = enum { natural, name, filename, dirname, mtime, size, none };
pub const Options = struct { recursive: bool = false, browse: bool = false, sort: ?Sort = null, reverse: bool = false, shuffle: bool = false, version_sort: bool = false, start_at: ?[:0]const u8 = null };

pub const Catalog = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    entries: [capacity]Entry = undefined,
    count: usize = 0,
    paths: [8 * 1024 * 1024]u8 = undefined,
    used: usize = 0,
    random: std.Random.DefaultPrng = .init(0),
    selected: ?[:0]const u8 = null,
    initial: ?Entry = null,
    on_initial: ?*const fn (Entry) void = null,

    fn add(self: *Catalog, path: []const u8, st: c.struct_stat) !void {
        if (self.selected) |selected| if (std.mem.eql(u8, selected, path)) {
            for (self.entries[0..self.count]) |e| if (std.mem.eql(u8, selected, path) and std.mem.eql(u8, e.path, path)) return;
        };
        if (self.count == capacity or path.len + 1 > self.paths.len - self.used) return error.CatalogCapacityExceeded;
        const start = self.used;
        @memcpy(self.paths[start..][0..path.len], path);
        self.paths[start + path.len] = 0;
        self.used += path.len + 1;
        const modified = if (runtime.darwin) st.st_mtimespec else st.st_mtim;
        const entry: Entry = .{ .path = self.paths[start..][0..path.len :0], .id = self.count, .bytes = st.st_size, .mtime = @as(i128, modified.tv_sec) * std.time.ns_per_s + modified.tv_nsec };
        self.entries[self.count] = entry;
        self.count += 1;
    }

    pub fn build(self: *Catalog, inputs: []const [:0]const u8, options: Options) !void {
        for (inputs, 0..) |input, argument| {
            if (self.cancel) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
            var resolved: [4096]u8 = undefined;
            var st: c.struct_stat = undefined;
            if (files.stat(input.ptr, &st) != 0) return error.PathNotReadable;
            if (st.st_mode & c.S_IFMT == c.S_IFDIR) {
                if (c.realpath(input.ptr, &resolved) == null) return error.PathNotReadable;
                try self.directory(std.mem.sliceTo(&resolved, 0), options, 0);
            } else if (st.st_mode & c.S_IFMT == c.S_IFREG) {
                const path = try operationPath(input, &resolved);
                try self.add(path, st);
                if (argument == 0) {
                    self.initial = self.entries[self.count - 1];
                    if (self.on_initial) |callback| callback(self.initial.?);
                }
                if (options.browse and inputs.len == 1) {
                    self.selected = self.entries[0].path;
                    try self.directory(std.fs.path.dirname(path).?, options, 0);
                    std.mem.sort(Entry, self.entries[0..self.count], Sort.natural, less);
                }
            } else return error.UnsupportedFileType;
        }
        if (options.sort) |mode| {
            if (mode != .none) std.mem.sort(Entry, self.entries[0..self.count], options, ordered);
        } else if (options.version_sort) std.mem.sort(Entry, self.entries[0..self.count], Sort.natural, less);
        if (options.start_at) |input| {
            var resolved: [4096]u8 = undefined;
            const target = operationPath(input, &resolved) catch return error.StartImageNotFound;
            self.selected = null;
            for (self.entries[0..self.count]) |e| if (std.mem.eql(u8, target, e.path)) {
                self.selected = e.path;
                break;
            };
            if (self.selected == null) return error.StartImageNotFound;
        }
        if (options.reverse) std.mem.reverse(Entry, self.entries[0..self.count]);
        if (options.shuffle) self.random.random().shuffle(Entry, self.entries[0..self.count]);
        if (self.count == 0) return error.NoImagesFound;
    }

    fn directory(self: *Catalog, path: []const u8, options: Options, depth: usize) !void {
        if (depth >= 64 or path.len >= 4095) return error.DirectoryDepthOrPathLimit;
        var full: [4096:0]u8 = undefined;
        @memcpy(full[0..path.len], path);
        full[path.len] = 0;
        const dir = files.opendir(&full) orelse return error.DirectoryNotReadable;
        defer _ = c.closedir(dir);
        const start = self.count;
        while (true) {
            if (self.cancel) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
            runtime.errno().* = 0;
            const raw = files.readdir(dir) orelse {
                if (runtime.errno().* != 0) return error.DirectoryReadFailed;
                break;
            };
            const name = std.mem.sliceTo(&raw.*.d_name, 0);
            if (name.len == 0 or name[0] == '.') continue;
            const separator: usize = if (std.mem.endsWith(u8, path, "/")) 0 else 1;
            const prefix = path.len + separator;
            if (prefix + name.len >= full.len) return error.DirectoryDepthOrPathLimit;
            @memcpy(full[0..path.len], path);
            if (separator != 0) full[path.len] = '/';
            @memcpy(full[prefix..][0..name.len], name);
            full[prefix + name.len] = 0;
            const child = full[0 .. prefix + name.len :0];
            var st: c.struct_stat = undefined;
            if (files.lstat(child.ptr, &st) != 0) continue; // A concurrently removed entry.
            const kind = st.st_mode & c.S_IFMT;
            if (kind == c.S_IFDIR) {
                if (options.recursive) try self.directory(child, options, depth + 1);
            } else if (candidate(name)) {
                if (kind == c.S_IFLNK) {
                    if (files.stat(child.ptr, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) continue;
                } else if (kind != c.S_IFREG) continue;
                try self.add(child, st);
            }
        }
        if (options.sort != .none) std.mem.sort(Entry, self.entries[start..self.count], Sort.natural, less);
    }
};

/// Resolve the directory for consistent absolute paths, retaining the selected
/// leaf. Decoding/stat may follow a symlink; hooks, copying paths and Trash must
/// operate on that link rather than unexpectedly acting on its target.
fn operationPath(input: [:0]const u8, output: *[4096]u8) ![:0]const u8 {
    const parent = std.fs.path.dirname(input) orelse ".";
    const leaf = std.fs.path.basename(input);
    var directory: [4096]u8 = undefined;
    if (parent.len >= directory.len or leaf.len == 0) return error.PathNotReadable;
    @memcpy(directory[0..parent.len], parent);
    directory[parent.len] = 0;
    if (c.realpath(&directory, output) == null) return error.PathNotReadable;
    var used = std.mem.sliceTo(output, 0).len;
    if (used == 0 or output[used - 1] != '/') {
        if (used + 1 >= output.len) return error.DirectoryDepthOrPathLimit;
        output[used] = '/';
        used += 1;
    }
    if (leaf.len >= output.len - used) return error.DirectoryDepthOrPathLimit;
    @memcpy(output[used..][0..leaf.len], leaf);
    output[used + leaf.len] = 0;
    return output[0 .. used + leaf.len :0];
}

pub fn candidate(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    inline for (.{ ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".gif", ".bmp", ".webp", ".heic", ".heif", ".avif", ".jxl", ".pbm", ".pgm", ".ppm", ".pnm" }) |supported| if (std.ascii.eqlIgnoreCase(ext, supported)) return true;
    return false;
}

pub fn natural(a: []const u8, b: []const u8) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a.len and bi < b.len) {
        if (std.ascii.isDigit(a[ai]) and std.ascii.isDigit(b[bi])) {
            var ae = ai;
            var be = bi;
            while (ae < a.len and std.ascii.isDigit(a[ae])) : (ae += 1) {}
            while (be < b.len and std.ascii.isDigit(b[be])) : (be += 1) {}
            while (ai < ae and a[ai] == '0') : (ai += 1) {}
            while (bi < be and b[bi] == '0') : (bi += 1) {}
            if (ae - ai != be - bi) return std.math.order(ae - ai, be - bi);
            const digits = std.mem.order(u8, a[ai..ae], b[bi..be]);
            if (digits != .eq) return digits;
            ai = ae;
            bi = be;
        } else {
            const char = std.math.order(std.ascii.toLower(a[ai]), std.ascii.toLower(b[bi]));
            if (char != .eq) return char;
            ai += 1;
            bi += 1;
        }
    }
    const rest = std.math.order(a.len - ai, b.len - bi);
    return if (rest == .eq) std.mem.order(u8, a, b) else rest;
}
fn less(mode: Sort, a: Entry, b: Entry) bool {
    if (mode == .mtime and a.mtime != b.mtime) return a.mtime > b.mtime;
    if (mode == .size and a.bytes != b.bytes) return a.bytes < b.bytes;
    const name_a = if (mode == .name) a.path else if (mode == .dirname) std.fs.path.dirname(a.path) orelse "" else std.fs.path.basename(a.path);
    const name_b = if (mode == .name) b.path else if (mode == .dirname) std.fs.path.dirname(b.path) orelse "" else std.fs.path.basename(b.path);
    const order = if (mode == .name or mode == .filename or mode == .dirname) std.mem.order(u8, name_a, name_b) else natural(name_a, name_b);
    return if (order == .eq) std.mem.lessThan(u8, a.path, b.path) else order == .lt;
}

test "natural ordering is deterministic with arbitrary length numbers" {
    try std.testing.expect(natural("frame2.tif", "frame10.tif") == .lt);
    try std.testing.expect(natural("frame0002.tif", "frame2.tif") == .lt);
    try std.testing.expect(natural("999999999999999999999", "1000000000000000000000") == .lt);
    try std.testing.expect(natural("A", "a") == .lt);
    try std.testing.expect(candidate("FILM.TIFF"));
    try std.testing.expect(!candidate("notes.md"));
}

fn ordered(options: Options, a: Entry, b: Entry) bool {
    const mode = options.sort orelse .natural;
    if (!options.version_sort or (mode != .name and mode != .filename and mode != .dirname)) return less(mode, a, b);
    const left = if (mode == .filename) std.fs.path.basename(a.path) else if (mode == .dirname) std.fs.path.dirname(a.path) orelse "" else a.path;
    const right = if (mode == .filename) std.fs.path.basename(b.path) else if (mode == .dirname) std.fs.path.dirname(b.path) orelse "" else b.path;
    const order = natural(left, right);
    return if (order == .eq) std.mem.lessThan(u8, a.path, b.path) else order == .lt;
}
