//! Viewer text is prepared off the UI thread and belongs to one displayed image.
const std = @import("std");
const hooks = @import("hooks.zig");
const source = @import("source");
const catalog = @import("catalog.zig");
const input = @import("session_input.zig");

pub const Options = struct {
    mode: hooks.Mode = .slideshow,
    title: ?[:0]const u8 = null,
    thumb_title: ?[:0]const u8 = null,
    font: ?@import("typography.zig").Font = null,
    menu_font: ?@import("typography.zig").Font = null,
    caption_dir: ?[:0]const u8 = null,
    info: ?[:0]const u8 = null,
    info_visible: bool = false,
    exif_visible: bool = false,

    pub fn wanted(self: Options) bool {
        return self.caption_dir != null or self.exif_visible or (self.info_visible and self.info != null) or self.needsFormat();
    }
    pub fn needsFormat(self: Options) bool {
        return (if (self.title) |title| hooks.usesSpecifier(title, 't') else false) or
            (if (self.info) |info| self.info_visible and hooks.usesSpecifier(info, 't') else false);
    }
};
pub const Key = struct {
    index: usize,
    version: u64,
    selection: u64,
    exif: bool,
    info: bool,
};
pub const Job = struct {
    key: Key,
    path: [:0]const u8,
    snapshot: hooks.Snapshot,
    options: Options,
};
pub const Text = struct {
    data: [1024]u8 = undefined,
    len: usize = 0,
    pub fn bytes(self: *const Text) []const u8 {
        return self.data[0..self.len];
    }
    fn copy(self: *Text, text: []const u8) void {
        self.len = @min(self.data.len, text.len);
        @memcpy(self.data[0..self.len], text[0..self.len]);
        for (self.data[0..self.len]) |*byte| if (byte.* < 32 and byte.* != '\n' and byte.* != '\t') {
            byte.* = ' ';
        };
        if (!std.unicode.utf8ValidateSlice(self.bytes())) {
            for (self.data[0..self.len]) |*byte| if (byte.* >= 128) {
                byte.* = '?';
            };
        }
    }
};
pub const Result = struct {
    key: Key,
    caption: Text = .{},
    camera: Text = .{},
    info: Text = .{},
    format: ?catalog.Info = null,
};

pub fn captionPath(output: []u8, path: [:0]const u8, directory: [:0]const u8) ![:0]const u8 {
    const parent = if (std.fs.path.isAbsolute(directory)) directory else std.fs.path.dirname(path) orelse ".";
    const relative = if (std.fs.path.isAbsolute(directory)) "" else directory;
    return std.fmt.bufPrintSentinel(output, "{s}/{s}/{s}.txt", .{ parent, relative, std.fs.path.basename(path) }, 0);
}

fn readCaption(path: [:0]const u8, directory: [:0]const u8, out: *Text) void {
    var name: [4096]u8 = undefined;
    const sidecar = captionPath(&name, path, directory) catch return;
    // Keep room for the EOF check in session_input.read.
    var bytes: [1025]u8 = undefined;
    if (input.read(sidecar, &bytes, true) catch null) |value| out.copy(std.mem.trimEnd(u8, value, "\r\n"));
}
fn readCamera(path: [:0]const u8, out: *Text, cancel: *const std.atomic.Value(bool)) void {
    const file = source.open(path, false) catch return;
    defer file.close();
    const range = switch (file.format) {
        .jpeg => (@import("jpeg").Plan.read(file, cancel) catch return).exif,
        .png => (@import("png").Plan.read(file, cancel) catch return).exif,
        .tiff, .raw => source.Range{ .file = file, .offset = 0, .length = @intCast(file.stamp.bytes) },
        else => null,
    } orelse return;
    var bytes: [1024]u8 = undefined;
    const camera = source.describeExif(range, &bytes, cancel) catch return;
    out.copy(camera);
}
fn prepare(job: Job, paths: []const [:0]const u8, probe: catalog.Probe, cancel: *const std.atomic.Value(bool)) Result {
    var result: Result = .{ .key = job.key };
    if (job.options.caption_dir) |directory| readCaption(job.path, directory, &result.caption);
    if (job.options.exif_visible) readCamera(job.path, &result.camera, cancel);
    if (job.options.needsFormat() and !cancel.load(.acquire)) result.format = probe(job.path, cancel);
    if (job.options.info_visible and !cancel.load(.acquire)) if (job.options.info) |template| {
        var buffer: [16384]u8 = undefined;
        var snapshot = job.snapshot;
        if (result.format) |*value| snapshot.image_format = value.name();
        const completed = @import("hook_execution.zig").runInfo(&buffer, template, snapshot, .{ .paths = paths }, cancel) catch return result;
        result.info.copy(std.mem.trimEnd(u8, completed.output[0..completed.len], "\r\n"));
    };
    return result;
}

// Single UI producer and single worker consumer. The worker owns the result
// until it publishes done. A different selection cancels any running command.
pub const Work = struct {
    const Phase = enum(u8) { idle, pending, done };
    phase: std.atomic.Value(Phase) = .init(.idle),
    cancelled: std.atomic.Value(bool) = .init(false),
    job: Job = undefined,
    result: Result = undefined,
    paths: [catalog.capacity][:0]const u8 = undefined,
    path_count: usize = 0,

    pub fn idle(self: *const Work) bool {
        return self.phase.load(.acquire) == .idle;
    }
    pub fn cancel(self: *Work) void {
        self.cancelled.store(true, .release);
    }
    pub fn submit(self: *Work, job: Job, entries: []const catalog.Entry, order: ?[]const usize) bool {
        if (!self.idle()) {
            if (!std.meta.eql(job.key, self.job.key)) self.cancel();
            return false;
        }
        self.job = job;
        self.path_count = 0;
        if (job.options.info_visible and hooks.needsManifest(job.options.info orelse "")) {
            self.path_count = if (order) |ids| ids.len else entries.len;
            for (self.paths[0..self.path_count], 0..) |*path, i| path.* = entries[if (order) |ids| ids[i] else i].path;
        }
        self.cancelled.store(false, .release);
        self.phase.store(.pending, .release);
        return true;
    }
    pub fn runPending(self: *Work, probe: catalog.Probe) bool {
        if (self.phase.load(.acquire) != .pending) return false;
        self.result = prepare(self.job, self.paths[0..self.path_count], probe, &self.cancelled);
        self.phase.store(.done, .release);
        return true;
    }
    pub fn take(self: *Work) ?Result {
        if (self.phase.load(.acquire) != .done) return null;
        const result = self.result;
        const cancelled = self.cancelled.load(.acquire);
        self.phase.store(.idle, .release);
        return if (cancelled) null else result;
    }
};

pub const Editor = struct {
    path: ?[:0]const u8 = null,
    draft: Text = .{},

    pub fn begin(self: *Editor, path: [:0]const u8, current: []const u8) void {
        self.path = path;
        self.draft.copy(current);
    }
    pub fn add(self: *Editor, text: []const u8) void {
        if (self.path == null or text.len == 0 or text.len > self.draft.data.len - self.draft.len or !std.unicode.utf8ValidateSlice(text)) return;
        for (text) |byte| if (byte < 32 and byte != '\n' and byte != '\t') return;
        @memcpy(self.draft.data[self.draft.len..][0..text.len], text);
        self.draft.len += text.len;
    }
    pub fn backspace(self: *Editor) void {
        if (self.draft.len == 0) return;
        self.draft.len -= 1;
        while (self.draft.len > 0 and self.draft.data[self.draft.len] & 0xc0 == 0x80) self.draft.len -= 1;
    }
};

pub const CaptionWrite = struct {
    const Phase = enum(u8) { idle, pending, done };
    phase: std.atomic.Value(Phase) = .init(.idle),
    filename: [4096:0]u8 = undefined,
    len: usize = 0,
    text: Text = .{},
    failed: bool = false,

    pub fn busy(self: *const CaptionWrite) bool {
        return self.phase.load(.acquire) != .idle;
    }
    pub fn submit(self: *CaptionWrite, editor: *const Editor, directory: [:0]const u8) !bool {
        if (self.busy()) return false;
        self.len = (try captionPath(&self.filename, editor.path orelse return false, directory)).len;
        self.text = editor.draft;
        self.phase.store(.pending, .release);
        return true;
    }
    pub fn runPending(self: *CaptionWrite) bool {
        if (self.phase.load(.acquire) != .pending) return false;
        self.failed = false;
        input.saveText(self.filename[0..self.len :0], self.text.bytes()) catch {
            self.failed = true;
        };
        self.phase.store(.done, .release);
        return true;
    }
    pub fn take(self: *CaptionWrite) ?bool {
        if (self.phase.load(.acquire) != .done) return null;
        const success = !self.failed;
        self.phase.store(.idle, .release);
        return success;
    }
};
