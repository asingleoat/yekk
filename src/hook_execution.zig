//! Shared worker-side hook preparation, manifest lifetime and process execution.
const std = @import("std");
const c = @import("system");
const hooks = @import("hooks.zig");
const commands = @import("commands.zig");
const input = @import("session_input.zig");
const catalog = @import("catalog.zig");
pub const Paths = union(enum) {
    paths: []const [:0]const u8,
    entries: struct { entries: []const catalog.Entry, order: ?[]const usize = null, first: ?catalog.Entry = null },
};
pub fn run(buffer: []u8, template: hooks.Command, captured: hooks.Snapshot, paths: Paths, cancel: *const std.atomic.Value(bool)) !commands.Result {
    return execute(buffer, template.body(), captured, paths, cancel, false);
}
pub fn runInfo(buffer: []u8, template: []const u8, captured: hooks.Snapshot, paths: Paths, cancel: *const std.atomic.Value(bool)) !commands.Result {
    return execute(buffer, template, captured, paths, cancel, true);
}
fn execute(buffer: []u8, template: []const u8, captured: hooks.Snapshot, paths: Paths, cancel: *const std.atomic.Value(bool), info: bool) !commands.Result {
    if (cancel.load(.acquire)) return error.Cancelled;
    var snapshot = captured;
    var temporary: [4096]u8 = undefined;
    var manifest: ?[:0]const u8 = null;
    defer if (manifest) |path| {
        _ = c.unlink(path.ptr);
    };
    if (hooks.needsManifest(template)) {
        const base = if (c.getenv("TMPDIR")) |value| std.mem.span(value) else "/tmp";
        const path = try std.fmt.bufPrintSentinel(&temporary, "{s}/yekk-hook-XXXXXX", .{base}, 0);
        const fd = c.mkstemp(path.ptr);
        if (fd < 0) return error.ManifestFailed;
        defer _ = c.close(fd);
        manifest = path;
        switch (paths) {
            .entries => |listing| try input.writeEntries(fd, listing.entries, listing.order, listing.first),
            .paths => |names| for (names) |name| {
                if (std.mem.indexOfScalar(u8, name, '\n') != null or std.mem.endsWith(u8, name, "\r")) return error.UnrepresentableFilelistPath;
                if (cancel.load(.acquire)) return error.Cancelled;
                try input.writeAll(fd, name);
                try input.writeAll(fd, "\n");
            },
        }
        snapshot.manifest = path;
    }
    const command = try hooks.format(buffer, template, snapshot);
    if (info) return commands.runInfo(command, cancel);
    return commands.runWithOutput(command, cancel, if (snapshot.mode.hasWindow()) .capture else .inherit);
}
