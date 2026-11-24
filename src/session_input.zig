//! Bounded startup input and atomic file-list output. No live UI calls these.
const std = @import("std");
const c = @import("system");
const runtime = @import("runtime");
const files = runtime.files;
const actions = @import("actions.zig");
const catalog = @import("catalog.zig");
const options = @import("options.zig");

pub const Arguments = struct {
    theme: options.Iterator,
    cli: options.Iterator,

    pub fn next(self: *Arguments) !?options.Item {
        while (true) {
            const item = (try self.theme.next()) orelse (try self.cli.next()) orelse return null;
            if (item.positional or !std.mem.eql(u8, item.name, "theme")) return item;
        }
    }
};

/// The caller owns this storage until the viewer exits. Positional arguments
/// and option values from the theme remain valid for the indexing worker.
pub const Theme = struct {
    data: [65537]u8 = undefined,
    args: [512][*:0]const u8 = undefined,
    count: usize = 0,

    pub fn load(self: *Theme, cli: []const [*:0]const u8) !Arguments {
        var chosen: ?[]const u8 = null;
        var scan: options.Iterator = .{ .args = cli };
        while (try scan.next()) |item| {
            if (!item.positional and std.mem.eql(u8, item.name, "theme")) chosen = item.value;
        }
        if (chosen) |name| {
            var path: [4096]u8 = undefined;
            var bytes: [65537]u8 = undefined;
            const config = if (c.getenv("XDG_CONFIG_HOME")) |value|
                try std.fmt.bufPrintSentinel(&path, "{s}/feh/themes", .{std.mem.span(value)}, 0)
            else if (c.getenv("HOME")) |value|
                try std.fmt.bufPrintSentinel(&path, "{s}/.config/feh/themes", .{std.mem.span(value)}, 0)
            else
                "/etc/feh/themes";
            const contents = (try read(config, &bytes, true)) orelse
                (try read("/etc/feh/themes", &bytes, true)) orelse return error.ThemeNotFound;
            try self.parse(contents, name);
        }
        return .{ .theme = .{ .args = self.args[0..self.count] }, .cli = .{ .args = cli } };
    }

    fn parse(self: *Theme, contents: []const u8, name: []const u8) !void {
        if (name.len == 0 or std.mem.indexOfScalar(u8, contents, 0) != null) return error.InvalidTheme;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var continuing = false;
        var selected = false;
        var length: usize = 0;
        while (lines.next()) |raw| {
            var line = std.mem.trim(u8, raw, " \t\r");
            if (!continuing) {
                if (line.len == 0 or line[0] == '#') continue;
                const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
                selected = std.mem.eql(u8, line[0..end], name);
                line = std.mem.trimStart(u8, line[end..], " \t");
            }
            continuing = std.mem.endsWith(u8, line, "\\");
            if (continuing) line = line[0 .. line.len - 1];
            if (!selected) continue;
            if (length + line.len + 1 >= self.data.len) return error.InputTooLarge;
            @memcpy(self.data[length..][0..line.len], line);
            length += line.len;
            if (!continuing) {
                try self.tokenize(length);
                return;
            }
            self.data[length] = ' ';
            length += 1;
        }
        return if (selected) error.InvalidTheme else error.ThemeNotFound;
    }

    fn tokenize(self: *Theme, length: usize) !void {
        var read_index: usize = 0;
        var write_index: usize = 0;
        while (read_index < length) {
            if (std.ascii.isWhitespace(self.data[read_index])) {
                read_index += 1;
                continue;
            }
            if (self.count == self.args.len) return error.TooManyThemeOptions;
            const start = write_index;
            var quote: ?u8 = null;
            while (read_index < length) {
                const ch = self.data[read_index];
                read_index += 1;
                if (quote == ch) {
                    quote = null;
                } else if (quote == null and (ch == '\'' or ch == '"')) {
                    quote = ch;
                } else if (quote == null and std.ascii.isWhitespace(ch)) {
                    break;
                } else {
                    self.data[write_index] = ch;
                    write_index += 1;
                }
            }
            if (quote != null) return error.InvalidTheme;
            self.data[write_index] = 0;
            self.args[self.count] = self.data[start..write_index :0].ptr;
            self.count += 1;
            write_index += 1;
        }
    }
};

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
pub fn loadSettings(settings: *actions.Settings, config: ?[:0]const u8, keys: ?[:0]const u8, buttons: ?[:0]const u8) !void {
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
    const buttons_path = buttons orelse try defaultPath(&path, "buttons");
    if (buttons_path) |full| {
        const bytes = read(full, &data, buttons == null) catch |err| {
            inputDiagnostic("buttons", full, 0);
            return err;
        };
        if (bytes) |text| settings.parseButtons(text);
        if (settings.error_line != 0) {
            inputDiagnostic("buttons", full, settings.error_line);
            return error.InvalidButtons;
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
// Every path in a catalog takes one separator byte, both in memory and on disk.
pub const FilelistBytes = [catalog.path_capacity + 1]u8;

pub fn filelist(path: [:0]const u8, data: *FilelistBytes, paths: [][:0]const u8, count: *usize, cancel: ?*const std.atomic.Value(bool)) !void {
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
const Entries = struct {
    entries: []const catalog.Entry,
    order: ?[]const usize = null,
    first: ?catalog.Entry = null,

    fn len(self: Entries) usize {
        return if (self.order) |ids| ids.len else self.entries.len;
    }
    fn path(self: Entries, index: usize) [:0]const u8 {
        const id = if (self.order) |ids| ids[index] else index;
        if (id == 0 and self.first != null) return self.first.?.savedPath();
        return self.entries[id].savedPath();
    }
};

/// A borrowed view, checked before opening a file for writing.
const LineList = union(enum) {
    catalog: Entries,
    paths: []const [:0]const u8,

    fn len(self: LineList) usize {
        return switch (self) {
            .catalog => |entries| entries.len(),
            .paths => |paths| paths.len,
        };
    }
    fn path(self: LineList, index: usize) [:0]const u8 {
        return switch (self) {
            .catalog => |entries| entries.path(index),
            .paths => |paths| paths[index],
        };
    }
    fn checked(self: LineList) !LineList {
        if (self == .catalog) if (self.catalog.order) |order| for (order) |id| {
            if (id >= self.catalog.entries.len) return error.InvalidFilelistOrder;
        };
        for (0..self.len()) |index| {
            const name = self.path(index);
            if (std.mem.indexOfScalar(u8, name, '\n') != null or std.mem.endsWith(u8, name, "\r")) return error.UnrepresentableFilelistPath;
        }
        return self;
    }
    fn write(self: LineList, fd: c_int) !void {
        for (0..self.len()) |index| {
            try writeAll(fd, self.path(index));
            try writeAll(fd, "\n");
        }
    }
};

pub fn writeEntries(fd: c_int, entries: []const catalog.Entry, order: ?[]const usize, first: ?catalog.Entry) !void {
    const list = try (LineList{ .catalog = .{ .entries = entries, .order = order, .first = first } }).checked();
    try list.write(fd);
}
pub fn save(path: [:0]const u8, entries: []const catalog.Entry, order: ?[]const usize) !void {
    if (std.mem.eql(u8, path, "-")) return;
    const list = try (LineList{ .catalog = .{ .entries = entries, .order = order } }).checked();
    try saveFile(path, .{ .list = list }, .replace);
}

pub fn saveWithFirst(path: [:0]const u8, entries: []const catalog.Entry, first: catalog.Entry) !void {
    if (std.mem.eql(u8, path, "-")) return;
    const list = try (LineList{ .catalog = .{ .entries = entries, .first = first } }).checked();
    try saveFile(path, .{ .list = list }, .replace);
}
pub fn saveText(path: [:0]const u8, text: []const u8) !void {
    try saveFile(path, .{ .text = text }, .replace);
}

fn saveFile(path: [:0]const u8, contents: union(enum) { list: LineList, text: []const u8 }, mode: enum { replace, create }) !void {
    var buffer: [4096]u8 = undefined;
    const temporary = try std.fmt.bufPrintSentinel(&buffer, "{s}.yekk-XXXXXX", .{path}, 0);
    const fd = c.mkstemp(temporary.ptr);
    if (fd < 0) return error.FilelistWriteFailed;
    var open = true;
    defer if (open) {
        _ = c.close(fd);
    };
    defer _ = c.unlink(temporary.ptr);
    if (mode == .replace) {
        var stat: c.struct_stat = undefined;
        if (files.stat(path.ptr, &stat) == 0 and c.fchmod(fd, stat.st_mode & 0o777) != 0) return error.FilelistWriteFailed;
    }
    switch (contents) {
        .list => |list| try list.write(fd),
        .text => |text| try writeAll(fd, text),
    }
    if (c.fsync(fd) != 0) return error.FilelistWriteFailed;
    const status = c.close(fd);
    open = false;
    if (status != 0) return error.FilelistWriteFailed;

    const published = if (mode == .replace)
        c.rename(temporary.ptr, path.ptr)
    else if (runtime.darwin)
        c.renamex_np(temporary.ptr, path.ptr, c.RENAME_EXCL)
    else
        c.renameat2(c.AT_FDCWD, temporary.ptr, c.AT_FDCWD, path.ptr, c.RENAME_NOREPLACE);
    if (published == 0) return;
    if (mode == .create and runtime.errno().* == c.EEXIST) return error.FilelistNameTaken;
    return error.FilelistWriteFailed;
}

var export_number: std.atomic.Value(usize) = .init(1);
fn saveExport(buffer: []u8, directory: [:0]const u8, paths: []const [:0]const u8) ![:0]const u8 {
    const list = try (LineList{ .paths = paths }).checked();
    while (true) {
        const number = export_number.fetchAdd(1, .monotonic);
        const path = try std.fmt.bufPrintSentinel(buffer, "{s}/feh_{d}_{d:0>6}_filelist", .{ directory, c.getpid(), number }, 0);
        saveFile(path, .{ .list = list }, .create) catch |err| switch (err) {
            error.FilelistNameTaken => continue,
            else => return err,
        };
        return path;
    }
}

/// The UI captures path slices in display order. The catalog owns the path bytes
/// until the worker finishes. Reordering or removing entries leaves both intact.
pub const FilelistExport = struct {
    const Phase = enum(u8) { idle, pending, done };
    pub const Result = union(enum) { saved: [:0]const u8, failed: anyerror };

    phase: std.atomic.Value(Phase) = .init(.idle),
    paths: [catalog.capacity][:0]const u8 = undefined,
    count: usize = 0,
    name: [4096]u8 = undefined,
    result: Result = undefined,

    pub fn busy(self: *const FilelistExport) bool {
        return self.phase.load(.acquire) != .idle;
    }

    pub fn queue(self: *FilelistExport, entries: []const catalog.Entry, order: ?[]const usize) bool {
        if (self.busy()) return false;
        const source: Entries = .{ .entries = entries, .order = order };
        self.count = source.len();
        for (self.paths[0..self.count], 0..) |*path, index| path.* = source.path(index);
        self.phase.store(.pending, .release);
        return true;
    }

    pub fn runPending(self: *FilelistExport, directory: [:0]const u8) bool {
        if (self.phase.load(.acquire) != .pending) return false;
        self.result = if (saveExport(&self.name, directory, self.paths[0..self.count])) |path|
            .{ .saved = path }
        else |err| failed: {
            var diagnostic: [128]u8 = undefined;
            runtime.output(2, std.fmt.bufPrint(&diagnostic, "yekk: could not save file list: {s}\n", .{@errorName(err)}) catch "yekk: could not save file list\n");
            break :failed .{ .failed = err };
        };
        self.phase.store(.done, .release);
        return true;
    }

    /// The result is valid until the UI queues another save.
    pub fn take(self: *FilelistExport) ?Result {
        if (self.phase.load(.acquire) != .done) return null;
        const result = self.result;
        self.phase.store(.idle, .release);
        return result;
    }
};
