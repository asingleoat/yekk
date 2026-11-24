//! Parse font options and find fonts in the configured search directories.
const std = @import("std");
const c = @import("system");

pub const Font = struct {
    family: []const u8,
    points: u16,
    file: ?[:0]const u8 = null,

    pub fn parse(text: []const u8) !Font {
        const split = std.mem.lastIndexOfScalar(u8, text, '/') orelse return error.InvalidFont;
        if (split == 0 or split >= 200) return error.InvalidFont;
        const size = std.fmt.parseInt(u16, text[split + 1 ..], 10) catch return error.InvalidFont;
        if (size == 0 or size > 512) return error.InvalidFont;
        return .{ .family = text[0..split], .points = size };
    }
    pub fn describe(self: Font, buffer: []u8) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buffer, "{s} {d}", .{ self.family, self.points }, 0);
    }
};

pub const SearchPaths = struct {
    directories: [16][:0]const u8 = undefined,
    count: usize = 0,

    pub fn add(self: *SearchPaths, directory: [:0]const u8) !void {
        if (directory.len == 0) return error.InvalidFontPath;
        if (self.count == self.directories.len) return error.TooManyFontPaths;
        self.directories[self.count] = directory;
        self.count += 1;
    }

    fn find(self: *const SearchPaths, name: []const u8, buffer: []u8) ?[:0]const u8 {
        if (findIn(name, "", buffer)) |path| return path;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
        for (self.directories[0..self.count]) |directory| {
            if (findIn(name, directory, buffer)) |path| return path;
        }
        return null;
    }

    fn findIn(name: []const u8, directory: []const u8, buffer: []u8) ?[:0]const u8 {
        const extension = std.fs.path.extension(name);
        const has_extension = std.ascii.eqlIgnoreCase(extension, ".ttf") or std.ascii.eqlIgnoreCase(extension, ".otf");
        for (if (has_extension) &[_][]const u8{""} else &[_][]const u8{ ".ttf", ".otf" }) |suffix| {
            const path = std.fmt.bufPrintSentinel(buffer, "{s}{s}{s}{s}", .{ directory, if (directory.len == 0) "" else "/", name, suffix }, 0) catch return null;
            var metadata: c.struct_stat = undefined;
            if (c.stat(path.ptr, &metadata) == 0 and metadata.st_mode & c.S_IFMT == c.S_IFREG) return path;
        }
        return null;
    }
};

pub const ResolvedFont = struct {
    path: [4096]u8 = undefined,
    name: [256]u8 = undefined,

    pub fn apply(self: *ResolvedFont, font: *?Font, paths: *const SearchPaths, resolve: anytype) !void {
        const face = if (font.*) |*value| value else return;
        const path = paths.find(face.family, &self.path) orelse return;
        const name = try resolve(path, &self.name);
        face.file = path;
        face.family = name;
    }
};
