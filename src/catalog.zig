//! One startup-owned catalog. Build only on the indexing worker; publish once.
const std = @import("std");
const c = @import("system");
const runtime = @import("runtime");
const files = runtime.files;
const remote = @import("remote.zig");
pub const capacity = 16384;
pub const path_capacity = 8 * 1024 * 1024;
pub const Dimensions = struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn parse(text: []const u8) !Dimensions {
        const split = std.mem.indexOfScalar(u8, text, 'x') orelse return error.InvalidDimensions;
        return .{ .width = try axis(text[0..split]), .height = try axis(text[split + 1 ..]) };
    }

    fn axis(text: []const u8) !u32 {
        const value = std.fmt.parseInt(i64, text, 10) catch return error.InvalidDimensions;
        return std.math.cast(u32, @max(0, value)) orelse error.InvalidDimensions;
    }
};
pub const Info = struct {
    size: Dimensions,
    format: [32]u8 = @splat(0),
    alpha: bool = false,

    pub fn init(width: u32, height: u32, format: []const u8, alpha: bool) Info {
        var result: Info = .{ .size = .{ .width = width, .height = height }, .alpha = alpha };
        const label = if (std.mem.eql(u8, format, "jpeg")) "jpg" else if (std.mem.eql(u8, format, "tif")) "tiff" else format;
        const len = @min(label.len, result.format.len - 1);
        @memcpy(result.format[0..len], label[0..len]);
        return result;
    }

    pub fn name(self: *const Info) []const u8 {
        return std.mem.sliceTo(&self.format, 0);
    }
};
pub const Probe = *const fn ([:0]const u8, ?*const std.atomic.Value(bool)) ?Info;
pub const Validate = *const fn ([:0]const u8, ?*const std.atomic.Value(bool)) anyerror!bool;
pub const Entry = struct {
    path: [:0]const u8,
    label: ?[:0]const u8 = null,
    id: usize,
    mtime: i128 = 0,
    bytes: i64 = 0,
    downloaded: bool = false,

    pub fn savedPath(self: Entry) [:0]const u8 {
        return if (self.downloaded) self.display() else self.path;
    }
    pub fn display(self: Entry) [:0]const u8 {
        return self.label orelse self.path;
    }
};
pub const Sort = enum { natural, name, filename, dirname, mtime, size, none, width, height, pixels, format };
pub const Options = struct {
    recursive: bool = false,
    browse: bool = false,
    sort: ?Sort = null,
    reverse: bool = false,
    shuffle: bool = false,
    version_sort: bool = false,
    start_at: ?[:0]const u8 = null,
    minimum: Dimensions = .{},
    maximum: Dimensions = .{},
    report_paths: bool = false,
    preload: bool = false,
    quiet: bool = false,
    verbose: bool = false,
    network: remote.Options = .{},

    pub fn needsInfo(self: Options) bool {
        return self.minimum.width != 0 or self.minimum.height != 0 or
            self.maximum.width != 0 or self.maximum.height != 0 or switch (self.sort orelse .none) {
            .width, .height, .pixels, .format => true,
            else => false,
        };
    }
};

pub const Catalog = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    entries: [capacity]Entry = undefined,
    count: usize = 0,
    paths: [path_capacity]u8 = undefined,
    used: usize = 0,
    random: std.Random.DefaultPrng = .init(0),
    selected: ?[:0]const u8 = null,
    initial: ?Entry = null,
    on_initial: ?*const fn (Entry) void = null,
    probe: ?Probe = null,
    validate: ?Validate = null,
    downloads: ?*remote.Session = null,
    // Populated by metadata sorting, filtering or listing.
    info: [capacity]Info = undefined,
    info_ready: bool = false,

    fn add(self: *Catalog, path: []const u8, label: ?[]const u8, st: c.struct_stat, downloaded: bool) !void {
        if (self.selected) |selected| if (std.mem.eql(u8, selected, path)) {
            for (self.entries[0..self.count]) |e| if (std.mem.eql(u8, e.path, path)) return;
        };
        if (self.count == capacity) return error.CatalogCapacityExceeded;
        const stored = try self.storePath(path);
        const display = if (label) |value| if (std.mem.eql(u8, value, path)) null else try self.storePath(value) else null;
        const modified = if (runtime.darwin) st.st_mtimespec else st.st_mtim;
        const entry: Entry = .{ .path = stored, .label = display, .id = self.count, .downloaded = downloaded, .bytes = st.st_size, .mtime = @as(i128, modified.tv_sec) * std.time.ns_per_s + modified.tv_nsec };
        self.entries[self.count] = entry;
        self.count += 1;
    }

    fn storePath(self: *Catalog, path: []const u8) ![:0]const u8 {
        if (path.len + 1 > self.paths.len - self.used) return error.CatalogCapacityExceeded;
        const start = self.used;
        @memcpy(self.paths[start..][0..path.len], path);
        self.paths[start + path.len] = 0;
        self.used += path.len + 1;
        return self.paths[start..][0..path.len :0];
    }

    pub fn build(self: *Catalog, inputs: []const [:0]const u8, options: Options) !void {
        const keep_labels = options.report_paths or options.start_at != null;
        for (inputs, 0..) |input, argument| {
            if (self.cancel) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
            var resolved: [4096]u8 = undefined;
            var staging: [4096]u8 = undefined;
            const downloaded = remote.isUrl(input);
            const local = if (downloaded) (self.downloads orelse return error.NetworkUnavailable).fetch(&staging, input, options.network, self.cancel) catch |err| {
                if (err == error.Cancelled) return err;
                if (!options.quiet) diagnosePath("yekk: cannot download ", input);
                continue;
            } else input;
            var st: c.struct_stat = undefined;
            if (files.stat(local.ptr, &st) != 0) {
                if (!options.report_paths) return error.PathNotReadable;
                if (!options.quiet) diagnosePath("yekk: cannot read ", input);
                continue;
            }
            if (st.st_mode & c.S_IFMT == c.S_IFDIR) {
                if (c.realpath(input.ptr, &resolved) == null) return error.PathNotReadable;
                try self.directory(std.mem.sliceTo(&resolved, 0), if (keep_labels) input else null, options, 0);
            } else if (st.st_mode & c.S_IFMT == c.S_IFREG) {
                const path = try operationPath(local, &resolved);
                try self.add(path, if (keep_labels or downloaded) input else null, st, downloaded);
                if (argument == 0) {
                    self.initial = self.entries[self.count - 1];
                    if (!options.preload and !options.needsInfo()) if (self.on_initial) |callback| callback(self.initial.?);
                }
                if (options.browse and !downloaded and inputs.len == 1) {
                    self.selected = self.entries[0].path;
                    try self.directory(std.fs.path.dirname(path).?, if (keep_labels) std.fs.path.dirname(input) orelse "." else null, options, 0);
                    if (options.sort != .none) std.mem.sort(Entry, self.entries[0..self.count], Sort.natural, less);
                }
            } else return error.UnsupportedFileType;
        }
        if (options.preload or options.needsInfo()) try self.filterInfo(options);
        if (options.sort) |mode| {
            if (mode != .none) std.mem.sort(Entry, self.entries[0..self.count], SortContext{ .options = options, .info = &self.info }, ordered);
        } else if (options.version_sort) std.mem.sort(Entry, self.entries[0..self.count], Sort.natural, less);
        if (options.reverse) std.mem.reverse(Entry, self.entries[0..self.count]);
        if (options.shuffle) self.random.random().shuffle(Entry, self.entries[0..self.count]);
        if (options.start_at) |input| {
            self.selected = null;
            for (self.entries[0..self.count]) |entry| {
                if (std.mem.eql(u8, input, entry.display())) {
                    self.selected = entry.path;
                    break;
                }
            }
            if (self.selected == null) for (self.entries[0..self.count]) |e| {
                if (std.mem.eql(u8, std.fs.path.basename(input), std.fs.path.basename(e.path))) {
                    self.selected = e.path;
                    break;
                }
            };
            if (self.selected == null) return error.StartImageNotFound;
        }
        if (self.count == 0) return error.NoImagesFound;
        if (options.verbose) {
            var line: [96]u8 = undefined;
            runtime.output(2, try std.fmt.bufPrint(&line, "yekk: indexed {d} files\n", .{self.count}));
        }
    }

    pub fn prepareListingInfo(self: *Catalog, probe: Probe) usize {
        var readable: usize = 0;
        for (self.entries[0..self.count]) |entry| {
            if (!self.info_ready) self.info[entry.id] = probe(entry.path, self.cancel) orelse .{ .size = .{} };
            if (self.info[entry.id].size.width != 0) readable += 1;
        }
        self.info_ready = true;
        return readable;
    }
    pub fn listingInfo(self: *const Catalog, entry: Entry) ?Info {
        if (!self.info_ready) return null;
        const info = self.info[entry.id];
        return if (info.size.width != 0) info else null;
    }

    fn filterInfo(self: *Catalog, options: Options) !void {
        const needs_info = options.needsInfo();
        const validate = if (options.preload) self.validate orelse return error.MetadataUnavailable else null;
        const probe = if (needs_info) self.probe orelse return error.MetadataUnavailable else null;
        var count: usize = 0;
        for (self.entries[0..self.count]) |entry| {
            if (self.cancel) |cancel| if (cancel.load(.acquire)) return error.Cancelled;
            if (validate) |validate_file| if (!(try validate_file(entry.path, self.cancel))) {
                if (!options.quiet) diagnosePath("yekk: cannot decode ", entry.display());
                continue;
            };
            if (probe) |probe_info| {
                const info = probe_info(entry.path, self.cancel) orelse continue;
                if (info.size.width < options.minimum.width or info.size.height < options.minimum.height or
                    (options.maximum.width != 0 and info.size.width > options.maximum.width) or
                    (options.maximum.height != 0 and info.size.height > options.maximum.height)) continue;
                self.info[count] = info;
            }
            var kept = entry;
            kept.id = count;
            self.entries[count] = kept;
            count += 1;
        }
        self.count = count;
        self.info_ready = needs_info;
    }

    fn directory(self: *Catalog, path: []const u8, display: ?[]const u8, options: Options, depth: usize) !void {
        if (depth >= 64 or path.len >= 4095) return error.DirectoryDepthOrPathLimit;
        var full: [4096:0]u8 = undefined;
        var label_buffer: [4096]u8 = undefined;
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
            const label = if (display) |dir_name|
                try std.fmt.bufPrint(&label_buffer, "{s}{s}{s}", .{ dir_name, if (std.mem.endsWith(u8, dir_name, "/")) "" else "/", name })
            else
                null;
            if (kind == c.S_IFDIR) {
                if (options.recursive) try self.directory(child, label, options, depth + 1);
            } else if (options.report_paths or candidate(name)) {
                if (kind == c.S_IFLNK) {
                    if (files.stat(child.ptr, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) continue;
                } else if (kind != c.S_IFREG) continue;
                try self.add(child, label, st, false);
            }
        }
        if (options.sort != .none) std.mem.sort(Entry, self.entries[start..self.count], Sort.natural, less);
    }
};

fn diagnosePath(prefix: []const u8, path: []const u8) void {
    var line: [8192]u8 = undefined;
    runtime.output(2, std.fmt.bufPrint(&line, "{s}{s}\n", .{ prefix, path }) catch prefix);
}

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
    return @import("source").rawCandidate(name);
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
    const name_a = if (mode == .name) a.display() else if (mode == .dirname) std.fs.path.dirname(a.display()) orelse "" else std.fs.path.basename(a.display());
    const name_b = if (mode == .name) b.display() else if (mode == .dirname) std.fs.path.dirname(b.display()) orelse "" else std.fs.path.basename(b.display());
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

const SortContext = struct { options: Options, info: *const [capacity]Info };
fn ordered(context: SortContext, a: Entry, b: Entry) bool {
    const options = context.options;
    const mode = options.sort orelse .natural;
    switch (mode) {
        .width, .height, .pixels, .format => {
            const left = &context.info[a.id];
            const right = &context.info[b.id];
            const order = switch (mode) {
                .width => std.math.order(left.size.width, right.size.width),
                .height => std.math.order(left.size.height, right.size.height),
                .pixels => std.math.order(@as(u64, left.size.width) * left.size.height, @as(u64, right.size.width) * right.size.height),
                .format => std.mem.order(u8, left.name(), right.name()),
                else => unreachable,
            };
            return if (order == .eq) a.id < b.id else order == .lt;
        },
        else => {},
    }
    if (!options.version_sort or (mode != .name and mode != .filename and mode != .dirname)) return less(mode, a, b);
    const left = if (mode == .filename) std.fs.path.basename(a.path) else if (mode == .dirname) std.fs.path.dirname(a.path) orelse "" else a.path;
    const right = if (mode == .filename) std.fs.path.basename(b.path) else if (mode == .dirname) std.fs.path.dirname(b.path) orelse "" else b.path;
    const order = natural(left, right);
    return if (order == .eq) std.mem.lessThan(u8, a.path, b.path) else order == .lt;
}
