//! Bounded startup input and atomic file-list output. No live UI calls these.
const std = @import("std");
const c = @import("system");
const runtime = @import("runtime");
const files = runtime.files;
const actions = @import("actions.zig");
const catalog = @import("catalog.zig");

pub fn read(path: [:0]const u8, buffer: []u8, missing_ok: bool) !?[]u8 {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) {
        if (missing_ok and runtime.errno().* == c.ENOENT) return null;
        return error.InputNotReadable;
    }
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (files.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.InputNotRegularFile;
    if (stat.st_size < 0 or stat.st_size >= buffer.len) return error.InputTooLarge;
    var used: usize = 0;
    while (used < buffer.len) {
        const count = c.read(fd, buffer[used..].ptr, buffer.len - used);
        if (count < 0 and runtime.errno().* == c.EINTR) continue;
        if (count < 0) return error.InputReadFailed;
        if (count == 0) return buffer[0..used];
        used += @intCast(count);
    }
    return error.InputTooLarge;
}
pub fn loadSettings(settings: *actions.Settings, config: ?[:0]const u8, keys: ?[:0]const u8) !void {
    settings.* = .init();

    var path: [4096]u8 = undefined;
    var data: [65537]u8 = undefined;
    const config_path = config orelse path: {
        if (c.getenv("YEKK_CONFIG")) |value| break :path std.mem.span(value);
        break :path try defaultPath(&path, "config");
    };
    if (config_path) |full| {
        const bytes = read(full, &data, config == null) catch |err| {
            inputDiagnostic("config", full, 0);
            return err;
        };
        if (bytes) |text| settings.parse(text);
        if (settings.error_line != 0) {
            inputDiagnostic("config", full, settings.error_line);
            return error.InvalidConfig;
        }
    }
    const key_path = keys orelse try defaultPath(&path, "keys");
    if (key_path) |full| {
        const bytes = read(full, &data, keys == null) catch |err| {
            inputDiagnostic("keys", full, 0);
            return err;
        };
        if (bytes) |text| settings.parseKeys(text);
        if (settings.error_line != 0) {
            inputDiagnostic("keys", full, settings.error_line);
            return error.InvalidKeys;
        }
    }
}
fn inputDiagnostic(kind: []const u8, path: []const u8, line: usize) void {
    var buffer: [8192]u8 = undefined;
    runtime.output(2, std.fmt.bufPrint(&buffer, "{s} {s}:{d}: could not load settings\n", .{ kind, path, line }) catch "settings could not be loaded\n");
}
fn defaultPath(buffer: []u8, name: []const u8) !?[:0]const u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |value| return try std.fmt.bufPrintSentinel(buffer, "{s}/yekk/{s}", .{ std.mem.span(value), name }, 0);
    if (c.getenv("HOME")) |value| return try std.fmt.bufPrintSentinel(buffer, "{s}/.config/yekk/{s}", .{ std.mem.span(value), name }, 0);
    return null;
}
pub fn filelist(path: [:0]const u8, data: []u8, paths: [][:0]const u8, count: *usize, cancel: ?*const std.atomic.Value(bool)) !void {
    const bytes = if (std.mem.eql(u8, path, "-")) stdin: {
        var used: usize = 0;
        while (used < data.len) {
            if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
            var ready: c.struct_pollfd = .{ .fd = 0, .events = c.POLLIN, .revents = 0 };
            const result = c.poll(&ready, 1, 20);
            if (result < 0 and runtime.errno().* != c.EINTR) return error.FilelistNotReadable;
            if (result <= 0) continue;
            const length = c.read(0, data[used..].ptr, data.len - used);
            if (length < 0 and runtime.errno().* == c.EINTR) continue;
            if (length < 0) return error.FilelistNotReadable;
            if (length == 0) break :stdin data[0..used];
            used += @intCast(length);
        }
        return error.InputTooLarge;
    } else (try read(path, data, true)) orelse return;
    if (bytes.len >= data.len) return error.InputTooLarge;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidFilelist;
    data[bytes.len] = 0;
    var start: usize = 0;
    for (0..bytes.len + 1) |i| if (data[i] == '\n' or i == bytes.len) {
        var end = i;
        if (end > start and data[end - 1] == '\r') {
            data[end - 1] = 0;
            end -= 1;
        }
        data[i] = 0;
        if (end > start) {
            if (count.* == paths.len) return error.TooManyPaths;
            paths[count.*] = data[start..end :0];
            count.* += 1;
        }
        start = i + 1;
    };
}
pub fn writeAll(fd: c_int, bytes: []const u8) !void {
    var used: usize = 0;
    while (used < bytes.len) {
        const count = c.write(fd, bytes[used..].ptr, bytes.len - used);
        if (count < 0 and runtime.errno().* == c.EINTR) continue;
        if (count <= 0) return error.FilelistWriteFailed;
        used += @intCast(count);
    }
}
/// A borrowed catalog view validated for the line-list format. The catalog and
/// order remain immutable until writing finishes. Construction performs no I/O.
const LineList = struct {
    entries: []const catalog.Entry,
    order: ?[]const usize,

    fn init(entries: []const catalog.Entry, order: ?[]const usize) !LineList {
        const list: LineList = .{ .entries = entries, .order = order };
        for (0..list.len()) |index| {
            const id = if (order) |ids| ids[index] else index;
            if (id >= entries.len) return error.InvalidFilelistOrder;
            const name = entries[id].path;
            if (std.mem.indexOfScalar(u8, name, '\n') != null or std.mem.endsWith(u8, name, "\r")) return error.UnrepresentableFilelistPath;
        }
        return list;
    }
    fn len(self: LineList) usize {
        return if (self.order) |ids| ids.len else self.entries.len;
    }
    fn path(self: LineList, index: usize) [:0]const u8 {
        return self.entries[if (self.order) |ids| ids[index] else index].path;
    }
};
fn writeList(fd: c_int, list: LineList) !void {
    for (0..list.len()) |index| {
        try writeAll(fd, list.path(index));
        try writeAll(fd, "\n");
    }
}
pub fn writeEntries(fd: c_int, entries: []const catalog.Entry, order: ?[]const usize) !void {
    try writeList(fd, try .init(entries, order));
}
pub fn save(path: [:0]const u8, entries: []const catalog.Entry, order: ?[]const usize) !void {
    if (std.mem.eql(u8, path, "-")) return;
    const list = try LineList.init(entries, order);
    var buffer: [4096]u8 = undefined;
    const temporary = try std.fmt.bufPrintSentinel(&buffer, "{s}.yekk-XXXXXX", .{path}, 0);
    const fd = c.mkstemp(temporary.ptr);
    if (fd < 0) return error.FilelistWriteFailed;
    var open = true;
    defer if (open) {
        _ = c.close(fd);
    };
    defer _ = c.unlink(temporary.ptr);
    var stat: c.struct_stat = undefined;
    if (files.stat(path.ptr, &stat) == 0 and c.fchmod(fd, stat.st_mode & 0o777) != 0) return error.FilelistWriteFailed;
    try writeList(fd, list);
    if (c.fsync(fd) != 0) return error.FilelistWriteFailed;
    const status = c.close(fd);
    open = false;
    if (status != 0 or c.rename(temporary.ptr, path.ptr) != 0) return error.FilelistWriteFailed;
}
