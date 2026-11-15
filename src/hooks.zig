//! Bounded feh-style command descriptions and shell-safe substitutions.
const std = @import("std");
const core = @import("core.zig");
pub const Command = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    body_start: usize = 0,
    title_start: usize = 0,
    title_len: usize = 0,
    reload: bool = false,
    pub fn set(self: *Command, text: []const u8) !void {
        if (text.len >= self.bytes.len or std.mem.indexOfScalar(u8, text, 0) != null) return error.CommandTooLong;
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
        self.body_start = 0;
        self.title_start = 0;
        self.title_len = 0;
        self.reload = text.len > 0 and text[0] == ';';
        if (self.reload) self.body_start = 1;
        if (self.body_start < text.len and text[self.body_start] == '[' and self.body_start + 1 < text.len and text[self.body_start + 1] != ' ') {
            if (std.mem.indexOfScalarPos(u8, text, self.body_start + 1, ']')) |end| {
                self.title_start = self.body_start + 1;
                self.title_len = end - self.title_start;
                self.body_start = end + 1;
            }
        }
        if (std.mem.trim(u8, self.body(), " \t").len == 0) {
            self.len = 0;
            self.body_start = 0;
            self.title_len = 0;
        }
    }
    pub fn body(self: *const Command) []const u8 {
        return self.bytes[self.body_start..self.len];
    }
    pub fn title(self: *const Command) []const u8 {
        return self.bytes[self.title_start..][0..self.title_len];
    }
};
pub const Snapshot = struct {
    path: []const u8,
    width: u32 = 0,
    height: u32 = 0,
    bytes: u64 = 0,
    index: usize = 1,
    count: usize = 1,
    viewport_width: u32 = 0,
    viewport_height: u32 = 0,
    offset_x: f64 = 0,
    offset_y: f64 = 0,
    zoom: f64 = 1,
    rotation: u2 = 0,
    playing: bool = false,
    pid: i32 = 0,
    manifest: []const u8 = "",
    image_format: []const u8 = "unknown",

    /// View coordinates use backing pixels, with positive Y downward.
    pub fn withView(self: Snapshot, view: core.View, viewport: core.Size) Snapshot {
        var result = self;
        result.viewport_width = @intFromFloat(viewport.width);
        result.viewport_height = @intFromFloat(viewport.height);
        result.offset_x = (viewport.width - @as(f64, @floatFromInt(self.width)) * view.scale) / 2 + view.pan_x;
        result.offset_y = (viewport.height - @as(f64, @floatFromInt(self.height)) * view.scale) / 2 + view.pan_y;
        result.zoom = view.scale;
        return result;
    }
};
const Writer = struct {
    output: []u8,
    len: usize = 0,
    fn add(self: *Writer, bytes: []const u8) !void {
        if (bytes.len > self.output.len - self.len) return error.CommandTooLong;
        @memcpy(self.output[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn number(self: *Writer, comptime pattern: []const u8, values: anytype) !void {
        var buffer: [128]u8 = undefined;
        try self.add(try std.fmt.bufPrint(&buffer, pattern, values));
    }
    fn quoted(self: *Writer, bytes: []const u8) !void {
        try self.add("'");
        for (bytes) |byte| {
            if (byte == '\'') try self.add("'\\''") else try self.add(&.{byte});
        }
        try self.add("'");
    }
};
pub fn format(output: []u8, template: []const u8, image: Snapshot) ![:0]const u8 {
    if (output.len == 0) return error.CommandTooLong;
    var writer: Writer = .{ .output = output[0 .. output.len - 1] };
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] != '%') {
            try writer.add(template[i..][0..1]);
            continue;
        }
        i += 1;
        if (i == template.len) return error.InvalidSpecifier;
        switch (template[i]) {
            '%' => try writer.add("%"),
            'F' => try writer.quoted(image.path),
            'N' => try writer.quoted(std.fs.path.basename(image.path)),
            'f', 'n' => return error.UnsafeSpecifier,
            'w' => try writer.number("{d}", .{image.width}),
            'h' => try writer.number("{d}", .{image.height}),
            's' => try writer.number("{d}", .{image.bytes}),
            'S' => try writer.number("{d:.1}MB", .{@as(f64, @floatFromInt(image.bytes)) / 1e6}),
            'p' => try writer.number("{d}", .{@as(u64, image.width) * image.height}),
            'P' => try writer.number("{d:.1}MP", .{@as(f64, @floatFromInt(@as(u64, image.width) * image.height)) / 1e6}),
            'l' => try writer.number("{d}", .{image.count}),
            'u' => try writer.number("{d}", .{image.index}),
            'g' => try writer.number("{d},{d}", .{ image.viewport_width, image.viewport_height }),
            'o' => try writer.number("{d:.0},{d:.0}", .{ image.offset_x, image.offset_y }),
            'z' => try writer.number("{d:.2}", .{image.zoom * 100}),
            'Z' => try writer.number("{d:.8}", .{image.zoom * 100}),
            'r' => try writer.number("{d:.8}", .{@as(f64, @floatFromInt(image.rotation)) * std.math.pi / 2.0}),
            'a' => try writer.add(if (image.playing) "playing" else "paused"),
            'm' => try writer.add("slideshow"),
            'v' => try writer.add(@import("version.zig").text),
            'V' => try writer.number("{d}", .{image.pid}),
            't' => try writer.quoted(image.image_format),
            'L' => if (image.manifest.len > 0) try writer.quoted(image.manifest) else return error.ManifestUnavailable,
            else => return error.InvalidSpecifier,
        }
    }
    output[writer.len] = 0;
    return output[0..writer.len :0];
}
test "hook coordinates report image position rather than center-relative pan" {
    const source: Snapshot = .{ .path = "scan.tif", .width = 640, .height = 480, .index = 3, .count = 5 };
    const cases = [_]struct { viewport: core.Size, view: core.View, expected: []const u8 }{
        .{ .viewport = .{ .width = 1000, .height = 700 }, .view = .{}, .expected = "1000,700|180,110|100.00" },
        .{ .viewport = .{ .width = 320, .height = 240 }, .view = .{ .pan_x = -16, .pan_y = 32 }, .expected = "320,240|-176,-88|100.00" },
        .{ .viewport = .{ .width = 1000, .height = 700 }, .view = .{ .scale = 2, .pan_x = 17, .pan_y = -9 }, .expected = "1000,700|-123,-139|200.00" },
    };
    for (cases) |case| {
        const snapshot = source.withView(case.view, case.viewport);
        var output: [128]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, try format(&output, "%g|%o|%z", snapshot));
        try std.testing.expectEqual(source.index, snapshot.index);
        try std.testing.expectEqual(source.count, snapshot.count);
    }
    const odd = source.withView(.{}, .{ .width = 961, .height = 641 });
    try std.testing.expectEqual(@as(f64, 160.5), odd.offset_x);
    try std.testing.expectEqual(@as(f64, 80.5), odd.offset_y);
}
test "commands retain titles, semicolon behavior and shell tests" {
    var command: Command = .{};
    try command.set(";[Keep]mv %F keep/");
    try std.testing.expect(command.reload);
    try std.testing.expectEqualStrings("Keep", command.title());
    try std.testing.expectEqualStrings("mv %F keep/", command.body());
    try command.set("[ -L %F ] && true");
    try std.testing.expectEqualStrings("[ -L %F ] && true", command.body());
}
test "filenames are single quoted including shell metacharacters and newlines" {
    var output: [1024]u8 = undefined;
    const result = try format(&output, "printf '%%s' %F %N %w %u", .{ .path = "/tmp/雪'$(false)\n.png", .width = 123, .index = 2 });
    try std.testing.expectEqualStrings("printf '%s' '/tmp/雪'\\''$(false)\n.png' '雪'\\''$(false)\n.png' 123 2", result);
    try std.testing.expectError(error.UnsafeSpecifier, format(&output, "echo %f", .{ .path = "x" }));
    try std.testing.expectError(error.InvalidSpecifier, format(&output, "echo %?", .{ .path = "x" }));
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.CommandTooLong, format(&small, "%F", .{ .path = "long" }));
}

pub fn needsManifest(template: []const u8) bool {
    return usesSpecifier(template, 'L');
}
pub fn usesSpecifier(template: []const u8, specifier: u8) bool {
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] != '%') continue;
        i += 1;
        if (i < template.len and template[i] == specifier) return true;
    }
    return false;
}
test "empty commands disable hooks and escaped percent avoids manifest work" {
    var command: Command = .{};
    try command.set(";[empty]   ");
    try std.testing.expectEqual(@as(usize, 0), command.body().len);
    try std.testing.expect(!needsManifest("echo %%L"));
    try std.testing.expect(needsManifest("echo %L %L"));
}
