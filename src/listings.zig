//! Shared feh-style catalog output. No viewer session or graphics context is needed.
const std = @import("std");
const catalog = @import("catalog.zig");
const c = @import("system");
const darwin = @import("runtime").darwin;
const hooks = @import("hooks.zig");
const input = @import("session_input.zig");
const Listing = @import("cli.zig").Listing;
const hook_execution = @import("hook_execution.zig");

const header = "NUM\tFORMAT\tWIDTH\tHEIGHT\tPIXELS\tSIZE\tALPHA\tFILENAME\n";

pub fn run(
    listing: Listing,
    catalog_state: *catalog.Catalog,
    probe: catalog.Probe,
    canLoad: *const fn ([:0]const u8) anyerror!bool,
    command: hooks.Command,
) !bool {
    const entries = catalog_state.entries[0..catalog_state.count];
    const classifies = listing == .loadable or listing == .unloadable;
    const count = if (listing == .metadata or listing == .custom) catalog_state.prepareListingInfo(probe) else entries.len;
    if (count == 0) return false;
    const table = listing == .metadata or listing == .custom;
    if (listing == .metadata) try writeRow(header);
    var position: usize = 0;
    var all_match = true;
    var cancel: std.atomic.Value(bool) = .init(false);
    for (entries) |entry| {
        if (listing == .paths) {
            try outputPath(entry.savedPath());
            continue;
        }
        var metadata = catalog_state.listingInfo(entry);
        if (classifies) {
            if ((try canLoad(entry.path)) != (listing == .loadable)) {
                all_match = false;
                continue;
            }
            try outputPath(entry.display());
            if (metadata == null and command.body().len != 0) metadata = probe(entry.path, null);
        } else if (metadata == null) continue;
        position += 1;
        const info = metadata orelse catalog.Info.init(0, 0, "unknown", false);
        const pixels = @as(u64, info.size.width) * info.size.height;
        const bytes: u64 = @intCast(@max(0, entry.bytes));
        var buffer: [16384]u8 = undefined;
        const item: hooks.Snapshot = .{
            .path = entry.display(),
            .width = info.size.width,
            .height = info.size.height,
            .bytes = bytes,
            .index = position,
            .count = count,
            .image_format = info.name(),
            .mode = switch (listing) {
                .loadable => .loadables,
                .unloadable => .unloadables,
                else => .list,
            },
            .playing = true,
            .pid = c.getpid(),
        };
        if (listing == .metadata) {
            var pixel_text: [32]u8 = undefined;
            var byte_text: [32]u8 = undefined;
            try writeRow(try std.fmt.bufPrint(&buffer, "{d}\t{s}\t{d}\t{d}\t{s}\t{s}\t{c}\t", .{
                position,                                 info.name(),                            info.size.width,                       info.size.height,
                try hooks.humanSize(&pixel_text, pixels), try hooks.humanSize(&byte_text, bytes), @as(u8, if (info.alpha) 'X' else '-'),
            }));
            try writeRow(entry.display());
        } else if (listing == .custom) {
            try writeRow(try hooks.formatList(&buffer, listing.custom, item));
        }
        if (table) try writeRow("\n");
        if (command.body().len != 0) {
            const result = try hook_execution.run(&buffer, command, item, .{ .entries = .{ .entries = entries, .order = null } }, &cancel);
            if (!result.success()) try input.writeAll(2, "yekk: list action failed\n");
        }
    }
    if (table and c.fflush(stdout()) != 0) return error.WriteFailed;
    return all_match;
}

fn outputPath(path: []const u8) !void {
    try input.writeAll(1, path);
    try input.writeAll(1, "\n");
}

// Table output uses stdout buffering so an action can write to stdout in order
// with feh's list modes. Path-only reports write each path before its action.
fn writeRow(bytes: []const u8) !void {
    if (c.fwrite(bytes.ptr, 1, bytes.len, stdout()) != bytes.len) return error.WriteFailed;
}

fn stdout() @TypeOf(if (darwin) c.__stdoutp else c.stdout) {
    return if (darwin) c.__stdoutp else c.stdout;
}
