//! Allocation-free argument iterator, including short bundles and --name=value.
const std = @import("std");
pub const Item = struct { name: []const u8, value: ?[:0]const u8 = null, positional: bool = false };
pub const Iterator = struct {
    args: []const [*:0]const u8,
    index: usize = 0,
    short: [:0]const u8 = "",
    positional: bool = false,
    pub fn next(self: *Iterator) !?Item {
        if (self.short.len > 0) {
            const key = self.short[0];
            self.short = self.short[1..];
            const name: []const u8 = switch (key) {
                'h' => "help",
                'v' => "version",
                'F' => "fullscreen",
                'g' => "geometry",
                'x' => "borderless",
                'r' => "recursive",
                'n' => "reverse",
                'z' => "randomize",
                'A' => "action",
                'D' => "slideshow-delay",
                'S' => "sort",
                'Z' => "auto-zoom",
                '.' => "scale-down",
                'G' => "draw-actions",
                'd' => "draw-filename",
                'R' => "reload",
                'l' => "list",
                'L' => "customlist",
                'U' => "loadable",
                'u' => "unloadable",
                'T' => "theme",
                'f' => "filelist",
                '|' => "start-at",
                else => return error.UnknownOption,
            };
            var item: Item = .{ .name = name };
            if (needsValue(name)) {
                item.value = if (self.short.len > 0) self.short else try self.value();
                self.short = "";
            }
            return item;
        }
        if (self.index == self.args.len) return null;
        const arg = std.mem.span(self.args[self.index]);
        self.index += 1;
        if (!self.positional and std.mem.eql(u8, arg, "--")) {
            self.positional = true;
            return self.next();
        }
        if (self.positional or arg.len < 2 or arg[0] != '-') return .{ .name = arg, .value = arg, .positional = true };
        if (arg[1] != '-') {
            self.short = arg[1..];
            return self.next();
        }
        const name = arg[2..];
        if (std.mem.indexOfScalar(u8, name, '=')) |at| {
            if (!needsValue(name[0..at])) return error.UnexpectedValue;
            return .{ .name = name[0..at], .value = name[at + 1 ..] };
        }
        return .{ .name = name, .value = if (needsValue(name)) try self.value() else null };
    }
    fn value(self: *Iterator) ![:0]const u8 {
        if (self.index == self.args.len) return error.MissingValue;
        const result = std.mem.span(self.args[self.index]);
        self.index += 1;
        return result;
    }
};
fn needsValue(name: []const u8) bool {
    if (std.mem.eql(u8, name, "action") or (name.len == 7 and std.mem.startsWith(u8, name, "action") and std.ascii.isDigit(name[6]))) return true;
    inline for (.{ "sort", "customlist", "min-dimension", "max-dimension", "theme", "buttons", "fit", "slideshow", "slideshow-delay", "snapshot", "config", "zoom", "zoom-step", "on-last-slide", "reload", "filelist", "start-at", "keys", "stress-test", "geometry", "decode-workers", "test-keys", "test-open", "window-test" }) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}
test "feh short bundles, attached values, equals and literal file arguments" {
    var args = [_][*:0]const u8{ "-FZD-3", "--action1=mv %F keep/", "--", "-film.tiff" };
    var it: Iterator = .{ .args = &args };
    try std.testing.expectEqualStrings("fullscreen", (try it.next()).?.name);
    try std.testing.expectEqualStrings("auto-zoom", (try it.next()).?.name);
    try std.testing.expectEqualStrings("-3", (try it.next()).?.value.?);
    try std.testing.expectEqualStrings("mv %F keep/", (try it.next()).?.value.?);
    const file = (try it.next()).?;
    try std.testing.expect(file.positional);
    try std.testing.expectEqualStrings("-film.tiff", file.name);
    try std.testing.expect(try it.next() == null);
}
