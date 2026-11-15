//! SDL frontend. The UI exchanges immutable requests and viewport results with
//! workers; it never indexes directories, decodes, scales or waits for a worker.
const std = @import("std");
const native = @import("linux");
const posix = @import("system");
const runtime = @import("runtime");
const memory = @import("memory.zig");
const catalog = @import("catalog.zig");
const core = @import("core.zig");
const options = @import("options.zig");
const hooks = @import("hooks.zig");
const commands = @import("commands.zig");
const actions = @import("actions.zig");
const controls = @import("linux_controls.zig");
const input = @import("session_input.zig");
const menu = @import("linux_menu.zig");

const Mutex = struct {
    value: std.atomic.Mutex = .unlocked,
    fn tryLock(self: *Mutex) bool {
        return self.value.tryLock();
    }
    fn unlock(self: *Mutex) void {
        self.value.unlock();
    }
    // Only workers call lock(). UI access always uses tryLock and retries on
    // its next event iteration. No native work runs inside these sections.
    fn lock(self: *Mutex) void {
        while (!self.tryLock()) std.atomic.spinLoopHint();
    }
};

const FrameKey = struct {
    view: native.render.View,
    checker: bool,
    fn matches(self: FrameKey, other: FrameKey) bool {
        return self.checker == other.checker and self.view.samePixels(other.view);
    }
};
const RetiredFrames = struct {
    items: [3]native.Frame = @splat(.{}),
    count: usize = 0,
    fn take(self: *RetiredFrames, frame: *native.Frame) void {
        if (frame.pixels == null) return;
        self.items[self.count] = frame.*;
        self.count += 1;
        frame.* = .{};
    }
    fn free(self: *RetiredFrames) void {
        for (self.items[0..self.count]) |*frame| native.render.free(frame);
    }
};
const CachedFrame = struct {
    owner: *Image = undefined,
    key: ?FrameKey = null,
    purpose: core.SurfacePurpose = .interaction,
    frame: native.Frame = .{},
    leases: std.atomic.Value(usize) = .init(0),
    retired: std.atomic.Value(bool) = .init(true),
    fn borrow(self: *CachedFrame) native.Frame {
        _ = self.owner.retain();
        _ = self.leases.fetchAdd(1, .monotonic);
        var frame = self.frame;
        frame.storage = .{ .borrowed = .{ .context = self, .release = release } };
        return frame;
    }
    // Frame retirement runs on the render worker, or its coordinator after join.
    // No native frees or image destruction take place on the UI thread.
    fn release(context: *anyopaque) void {
        const self: *CachedFrame = @ptrCast(@alignCast(context));
        const owner = self.owner;
        const count = self.leases.fetchSub(1, .acq_rel);
        std.debug.assert(count > 0);
        if (count == 1 and self.retired.load(.acquire)) native.render.free(&self.frame);
        owner.destroy();
    }
};
const Image = struct {
    refs: std.atomic.Value(usize) = .init(1),
    pixels: native.Image,
    stamp: Stamp = .{},
    link_stamp: ?Stamp = null,
    frames: [3]CachedFrame = @splat(.{}),
    cache_epoch: u64 = 0,
    fn retain(self: *Image) *Image {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    // Metadata access is protected by State.lock; frame pixels are immutable.
    fn cached(self: *Image, key: FrameKey) ?*CachedFrame {
        for (&self.frames) |*slot| if (slot.key) |stored| {
            if (stored.matches(key) and native.render.frameCurrent(&slot.frame) != 0) return slot;
        };
        return null;
    }
    fn borrowFrame(self: *Image, key: FrameKey, purpose: core.SurfacePurpose) ?native.Frame {
        const slot = self.cached(key) orelse return null;
        if (purpose == .overview and slot.purpose != .overview) {
            for (&self.frames) |*old| if (old != slot and old.key != null and old.purpose == .overview) {
                old.key = null;
                old.retired.store(true, .release);
            };
            slot.purpose = .overview;
        }
        self.cache_epoch +%= 1;
        return slot.borrow();
    }
    fn storeFrame(self: *Image, frame: *native.Frame, key: FrameKey, purpose: core.SurfacePurpose, retired: *RetiredFrames) ?native.Frame {
        var available: ?*CachedFrame = null;
        for (&self.frames) |*slot| {
            if (slot.leases.load(.acquire) == 0 and (slot.key == null or slot.purpose == purpose)) {
                available = slot;
                break;
            }
        }
        const target = available orelse return null;
        for (&self.frames) |*slot| if (slot.key != null and slot.purpose == purpose) {
            slot.key = null;
            slot.retired.store(true, .release);
            if (slot.leases.load(.acquire) == 0) retired.take(&slot.frame);
        };
        retired.take(&target.frame);
        target.frame = frame.*;
        frame.* = .{};
        target.key = key;
        target.purpose = purpose;
        target.retired.store(false, .release);
        self.cache_epoch +%= 1;
        return target.borrow();
    }
    fn clearFrames(self: *Image, retired: *RetiredFrames) void {
        for (&self.frames) |*slot| {
            slot.key = null;
            slot.retired.store(true, .release);
            if (slot.leases.load(.acquire) == 0) retired.take(&slot.frame);
        }
        self.cache_epoch +%= 1;
    }
    fn destroy(self: *Image) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (&self.frames) |*slot| {
            std.debug.assert(slot.leases.load(.acquire) == 0);
            native.render.free(&slot.frame);
        }
        native.image.free(&self.pixels);
    }
};

const Stamp = @import("source").Stamp;
const Entry = struct { image: ?*Image = null, failed: bool = false, reload: bool = false, refreshing: bool = false, version: u64 = 0, stamp: ?Stamp = null };
const Request = controls.Request;
const Result = struct { requested_at: f64 = 0, pixels: native.Frame = native.Frame{}, revision: u64 = 0, image_version: u64 = 0, index: usize = 0, width: u32 = 0, height: u32 = 0, view: core.View = .{}, stamp: ?Stamp = null, link_stamp: ?Stamp = null };
// Single UI producer / render-worker consumer. A full queue leaves ownership
// with the UI for a later tick; neither native frees nor waiting run on the UI.
const FrameRetirement = struct {
    frames: [4]native.Frame = undefined,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    fn push(self: *FrameRetirement, frame: *native.Frame) bool {
        if (frame.pixels == null) return true;
        const head = self.head.load(.monotonic);
        const next = (head + 1) % self.frames.len;
        if (next == self.tail.load(.acquire)) return false;
        self.frames[head] = frame.*;
        frame.* = native.Frame{};
        self.head.store(next, .release);
        return true;
    }
    fn pop(self: *FrameRetirement) ?native.Frame {
        const tail = self.tail.load(.monotonic);
        if (tail == self.head.load(.acquire)) return null;
        const frame = self.frames[tail];
        self.tail.store((tail + 1) % self.frames.len, .release);
        return frame;
    }
    fn collect(self: *FrameRetirement) void {
        while (self.pop()) |item| {
            var frame = item;
            native.render.free(&frame);
        }
    }
};
const HookJob = struct {
    kind: enum { shell, trash, reveal, external } = .shell,
    link_stamp: ?Stamp = null,
    template: hooks.Command = .{},
    snapshot: hooks.Snapshot = .{ .path = "" },
    order: [catalog.capacity]usize = undefined,
    count: usize = 0,
    index: usize = 0,
    revision: u64 = 0,
    reload: bool = false,
    source_stamp: ?Stamp = null,
};
const Config = struct {
    paths: [catalog.capacity][:0]const u8 = undefined,
    count: usize = 0,
    catalog_options: catalog.Options = .{},
    fullscreen: bool = false,
    borderless: bool = false,
    software: bool = false,
    listing: @import("cli.zig").Listing = .none,
    formats: bool = false,
    filelist: ?[:0]const u8 = null,
    filelist_data: [1024 * 1024 + 1]u8 = undefined,
    geometry: ?@import("geometry").Geometry = null,
    settings: actions.Settings = .{},
    paused: bool = false,
    initial_zoom: ?f64 = null,
    draw_filename: bool = false,
    draw_actions: bool = false,
    benchmark: bool = false,
    smoke: bool = false,
    smoke_hook: bool = false,
    smoke_reload: bool = false,
    smoke_resize: bool = false,
    verify_gpu: bool = false,
    trace: bool = false,
    test_keys: ?[:0]const u8 = null,
    test_open: ?[:0]const u8 = null,
    window_test: ?[:0]const u8 = null,
    test_wait: bool = false,
    watch_test: bool = false,
    recovery_test: bool = false,
    native_recovery_test: bool = false,
    prefetch: bool = true,
    stress: usize = 0,
    workers: c_int = 0,
    snapshot: ?[:0]const u8 = null,
};
const State = struct {
    context: ?*native.Window = null,
    config: Config = .{},
    catalog: catalog.Catalog = .{},
    entries: [catalog.capacity]Entry = @splat(.{}),
    lock: Mutex = .{},
    stop: std.atomic.Value(bool) = .init(false),
    changed: @import("platform/linux_notification.zig").Notification = .{},
    indexed: std.atomic.Value(bool) = .init(false),
    index_failed: std.atomic.Value(bool) = .init(false),
    reload_pending: std.atomic.Value(bool) = .init(false),
    presented_revision: std.atomic.Value(u64) = .init(0),
    presented_version: std.atomic.Value(u64) = .init(0),
    prefetch_blocked: ?usize = null,
    prepare_failures: [2]?struct { index: usize, version: u64, key: FrameKey, epoch: u64 } = @splat(null),
    request: Request = .{},
    requested_at: f64 = 0,
    result: Result = .{},
    retirement: FrameRetirement = .{},
    hook_job: HookJob = .{},
    hook_pending: bool = false,
    hook_running: bool = false,
    hook_failed: bool = false,
    render_failed_revision: u64 = 0,
    derived_reclaim: std.atomic.Value(bool) = .init(false),
    render_reclaim: std.atomic.Value(bool) = .init(false),
    render_reclaimed: std.atomic.Value(u64) = .init(0),
    native_retries: std.atomic.Value(usize) = .init(0),
    decode_count: usize = 0,
    pressure_events: std.atomic.Value(usize) = .init(0),
    allocation_retries: std.atomic.Value(usize) = .init(0),
    inactive_reclaimed: std.atomic.Value(usize) = .init(0),
    controller: controls.Controller = .{},
    removed: [catalog.capacity]std.atomic.Value(bool) = undefined,
    removal_pending: std.atomic.Value(bool) = .init(false),
    save_failed: std.atomic.Value(bool) = .init(false),
    hook_finished: usize = 0,
    hook_advance: ?usize = null,
    hook_remove: ?usize = null,
    hook_revision: u64 = 0,
    controller_ready: std.atomic.Value(bool) = .init(false),
    fn getRequest(self: *State) Request {
        self.lock.lock();
        defer self.lock.unlock();
        return self.request;
    }
};
fn output(comptime format: []const u8, args: anytype) void {
    var buffer: [8192]u8 = undefined;
    runtime.output(2, std.fmt.bufPrint(&buffer, format, args) catch "diagnostic too long\n");
}
fn parse(state: *State, args: []const [*:0]const u8) !bool {
    const cfg = &state.config;
    var common: @import("cli.zig").Options = .{};
    var config_path: ?[:0]const u8 = null;
    var keys: ?[:0]const u8 = null;
    var scan: options.Iterator = .{ .args = args };
    while (try scan.next()) |item| {
        if (item.positional) continue;
        if (std.mem.eql(u8, item.name, "alloc-stats") or std.mem.eql(u8, item.name, "allocation-stats")) memory.report = true;
        if (std.mem.eql(u8, item.name, "help")) {
            usage();
            return false;
        }
        if (std.mem.eql(u8, item.name, "version")) {
            runtime.output(1, @import("version.zig").text ++ " (Linux)\n");
            return false;
        }
        if (std.mem.eql(u8, item.name, "config")) config_path = item.value;
        if (std.mem.eql(u8, item.name, "keys")) keys = item.value;
    }
    try input.loadSettings(&cfg.settings, config_path, keys);
    state.request.view.mode = cfg.settings.fit;
    var it: options.Iterator = .{ .args = args };
    while (try it.next()) |item| {
        if (item.positional) {
            if (std.mem.eql(u8, item.name, "-")) {
                cfg.filelist = "-";
                continue;
            }
            if (cfg.count == cfg.paths.len) return error.TooManyPaths;
            cfg.paths[cfg.count] = item.value.?;
            cfg.count += 1;
            continue;
        }
        const name = item.name;
        const value = item.value orelse "";
        if (try common.parse(item, &cfg.catalog_options)) continue;
        if (std.mem.eql(u8, name, "software")) cfg.software = true else if (std.mem.eql(u8, name, "formats")) cfg.formats = true else if (std.mem.eql(u8, name, "benchmark")) cfg.benchmark = true else if (std.mem.eql(u8, name, "smoke-resize-test")) cfg.smoke_resize = true else if (std.mem.eql(u8, name, "smoke-reload-test")) cfg.smoke_reload = true else if (std.mem.eql(u8, name, "smoke-hook-test")) cfg.smoke_hook = true else if (std.mem.eql(u8, name, "smoke-test")) cfg.smoke = true else if (std.mem.eql(u8, name, "no-prefetch")) cfg.prefetch = false else if (std.mem.eql(u8, name, "native-recovery-test")) {
            if (!memory.debug_enabled) return error.DebugAllocatorRequired;
            cfg.native_recovery_test = true;
        } else if (std.mem.eql(u8, name, "recovery-test")) {
            if (!memory.debug_enabled) return error.DebugAllocatorRequired;
            cfg.recovery_test = true;
            cfg.prefetch = false;
        } else if (std.mem.eql(u8, name, "snapshot")) cfg.snapshot = value else if (std.mem.eql(u8, name, "stress-test")) {
            cfg.stress = try std.fmt.parseInt(usize, value, 10);
            if (cfg.stress == 0) return error.InvalidCycles;
        } else if (std.mem.eql(u8, name, "verify-gpu")) cfg.verify_gpu = true else if (std.mem.eql(u8, name, "nearest")) state.request.nearest = true else if (std.mem.eql(u8, name, "trace-events")) cfg.trace = true else if (std.mem.eql(u8, name, "window-test")) cfg.window_test = value else if (std.mem.eql(u8, name, "test-wait")) cfg.test_wait = true else if (std.mem.eql(u8, name, "test-open")) cfg.test_open = value else if (std.mem.eql(u8, name, "test-keys")) cfg.test_keys = value else if (std.mem.eql(u8, name, "watch-test")) cfg.watch_test = true else {
            output("Unknown option: --{s}\n", .{name});
            return error.UnsupportedOption;
        }
    }
    common.apply(&cfg.settings);
    memory.report = memory.report or common.allocation_stats;
    cfg.workers = std.math.cast(c_int, common.decode_workers orelse 0) orelse return error.InvalidWorkerCount;
    cfg.filelist = common.filelist orelse cfg.filelist;
    cfg.fullscreen = common.fullscreen;
    cfg.borderless = common.borderless;
    cfg.geometry = common.geometry;
    cfg.listing = common.listing;
    cfg.draw_actions = common.draw_actions;
    cfg.draw_filename = common.draw_filename;
    cfg.paused = if (common.slideshow) |slideshow| slideshow.paused else false;
    cfg.initial_zoom = common.zoom;
    state.request.view = .initial(cfg.settings.fit, common.zoom);
    state.request.initial_zoom = common.zoom;
    if (cfg.watch_test) {
        cfg.settings.watch = true;
        cfg.settings.watch_seconds = 0.25;
    }
    if (cfg.filelist) |path| try input.filelist(path, &cfg.filelist_data, &cfg.paths, &cfg.count, &state.stop);
    if (cfg.count == 0) {
        if (cfg.catalog_options.start_at) |path| {
            cfg.paths[0] = path;
            cfg.catalog_options.browse = true;
        } else cfg.paths[0] = ".";
        cfg.count = 1;
    }
    if (cfg.geometry) |g| if (g.width > std.math.maxInt(c_int) or g.height > std.math.maxInt(c_int) or (if (g.position) |position| position.x.distance() > std.math.maxInt(c_int) or position.y.distance() > std.math.maxInt(c_int) else false)) return error.InvalidGeometry;
    if (cfg.smoke_hook and cfg.settings.hooks[0].body().len == 0) return error.HookTestRequiresAction;
    return true;
}
fn usage() void {
    runtime.output(1, "usage: yekk [OPTIONS] [IMAGE|DIRECTORY...]\n" ++
        "-F fullscreen, -g GEOMETRY, -x borderless, -r recursive, -n reverse, -z shuffle,\n" ++
        "-S SORT, --version-sort, --browse, --start-at PATH, -f FILELIST (- for stdin),\n" ++
        "-Z fit, -. shrink, --fit MODE, --zoom PERCENT|max|fill, --zoom-step PERCENT,\n" ++
        "--keep-zoom-vp, --no-wrap, -D SECONDS (negative: paused), --on-last-slide POLICY,\n" ++
        "-R SECONDS, --watch, -A COMMAND, --action1..9 COMMAND, --config FILE, --keys FILE,\n" ++
        "-l metadata list, --print-filelist, --formats, --software, --decode-workers N,\n" ++
        "--benchmark, --alloc-stats. Keys follow the shared feh action map.\n");
}

fn decode(path: [:0]const u8) !*Image {
    return decodeWithAllocator(path, memory.allocator());
}
fn decodeWithAllocator(path: [:0]const u8, allocator: std.mem.Allocator) !*Image {
    return decodeScheduled(path, allocator, .{});
}
fn decodeScheduled(path: [:0]const u8, allocator: std.mem.Allocator, load_options: native.image.LoadOptions) !*Image {
    const link_stamp = Stamp.readLink(path) orelse return error.UnreadableImage;
    const opened = try @import("source").open(path, true);
    defer opened.close();
    const loaded = native.image.loadOpened(@sizeOf(Image), allocator, path.ptr, opened, load_options) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        else => error.DecodeFailed,
    };
    const image: *Image = @ptrCast(loaded.prefix);
    image.* = .{ .pixels = loaded.pixels };
    for (&image.frames) |*slot| slot.owner = image;
    errdefer image.destroy();
    if (!std.meta.eql(@as(?Stamp, opened.stamp), Stamp.read(path))) return error.SourceChanged;
    if (!std.meta.eql(@as(?Stamp, link_stamp), Stamp.readLink(path))) return error.SourceChanged;
    image.stamp = opened.stamp;
    image.link_stamp = link_stamp;
    return image;
}
fn reclaim(state: *State, protected: usize) void {
    for (state.entries[0..state.catalog.count], 0..) |*entry, entry_index| {
        if (!@import("cache.zig").reclaim(.{ .state = .ready }, .critical, entry_index == protected, false)) continue;
        state.lock.lock();
        const image = entry.image;
        entry.image = null;
        state.lock.unlock();
        if (image) |value| {
            if (protected != std.math.maxInt(usize)) _ = state.inactive_reclaimed.fetchAdd(1, .monotonic);
            value.destroy(); // Large frees stay off the UI thread.
        }
    }
}
fn index(state: *State) !void {
    state.catalog.cancel = &state.stop;
    try state.catalog.build(state.config.paths[0..state.config.count], state.config.catalog_options);
    if (state.catalog.selected) |selected| {
        for (state.catalog.entries[0..state.catalog.count], 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, selected)) state.request.index = i;
        }
    }
    state.indexed.store(true, .release);
    state.changed.notify();
    native.input.wake();
}
fn watched(state: *State, id: usize) void {
    if (state.removed[id].load(.acquire)) return;
    state.lock.lock();
    const interested = state.entries[id].image != null or state.entries[id].failed;
    const before = state.entries[id].stamp;
    state.lock.unlock();
    if (!interested) return;
    const stamp = Stamp.read(state.catalog.entries[id].path);
    state.lock.lock();
    defer state.lock.unlock();
    const entry = &state.entries[id];
    if ((entry.image != null or entry.failed) and std.meta.eql(before, entry.stamp)) {
        if (!std.meta.eql(stamp, entry.stamp)) {
            entry.stamp = stamp;
            entry.refreshing = true;
            entry.failed = false;
        }
    }
}
fn watchWorker(state: *State) void {
    if (state.context) |context| native.types.bind(context);
    var watch_at: f64 = 0;
    var cursor: usize = 0;
    while (!state.stop.load(.acquire)) {
        if (state.indexed.load(.acquire)) {
            const request = state.getRequest();
            if (request.watch and runtime.now() >= watch_at) {
                watched(state, request.index);
                for (0..@min(8, state.catalog.count)) |_| {
                    if (cursor != request.index) watched(state, cursor);
                    cursor = (cursor + 1) % state.catalog.count;
                }
                watch_at = runtime.now() + request.watch_seconds;
            }
        }
        _ = posix.poll(null, 0, 20);
    }
}
fn saveFilelist(state: *State) !void {
    const destination = state.config.filelist orelse return;
    if (!state.controller_ready.load(.acquire)) {
        var request = state.request;
        state.controller.start(state.catalog.count, request.index, &request);
    }
    try input.save(destination, state.catalog.entries[0..state.catalog.count], state.controller.order[0..state.controller.count]);
}
// Process-wide decode lanes match the shared native thread pool. Foreground
// requests take priority; at most one lane may be speculative.
const DecodeLanes = struct {
    active: std.atomic.Value(usize) = .init(0),
    foreground_waiting: std.atomic.Value(usize) = .init(0),
    speculative: std.atomic.Value(bool) = .init(false),
    fn acquire(self: *DecodeLanes, foreground: bool, stop: *const std.atomic.Value(bool)) bool {
        if (foreground) _ = self.foreground_waiting.fetchAdd(1, .acq_rel);
        defer if (foreground) {
            _ = self.foreground_waiting.fetchSub(1, .release);
        };
        var speculative = false;
        if (!foreground) {
            if (self.foreground_waiting.load(.acquire) > 0 or self.speculative.swap(true, .acq_rel)) return false;
            speculative = true;
        }
        while (!stop.load(.acquire)) {
            var used = self.active.load(.acquire);
            while (used < @import("cache.zig").decode_lanes) {
                if (self.active.cmpxchgWeak(used, used + 1, .acq_rel, .acquire)) |observed| used = observed else return true;
            }
            if (!foreground) break;
            _ = posix.poll(null, 0, 5);
        }
        if (speculative) self.speculative.store(false, .release);
        return false;
    }
    fn release(self: *DecodeLanes, foreground: bool) void {
        _ = self.active.fetchSub(1, .release);
        if (!foreground) self.speculative.store(false, .release);
    }
};
var decode_lanes: DecodeLanes = .{};
fn decodeWorker(state: *State) void {
    if (state.context) |context| native.types.bind(context);
    index(state) catch |err| {
        if (err != error.Cancelled) output("directory: {s}\n", .{@errorName(err)});
        state.index_failed.store(true, .release);
        return;
    };
    defer saveFilelist(state) catch |err| {
        output("filelist save failed: {s}\n", .{@errorName(err)});
        state.save_failed.store(true, .release);
    };
    const pressure = native.desktop.pressureOpen();
    defer native.desktop.pressureClose(pressure);
    // Cancellation can return from an in-flight decode. Cached history still
    // belongs to this worker and must be retired on every exit path.
    defer reclaim(state, std.math.maxInt(usize));
    var pressure_selection: ?usize = null;
    while (!state.stop.load(.acquire)) {
        const observed = state.changed.observe();
        const request = state.getRequest();
        if (state.render_reclaim.swap(false, .acq_rel)) {
            reclaim(state, request.index);
            pressure_selection = request.index;
            state.lock.lock();
            state.prefetch_blocked = request.index;
            state.lock.unlock();
            _ = state.render_reclaimed.fetchAdd(1, .release);
        }
        if (state.removal_pending.swap(false, .acq_rel)) {
            for (state.entries[0..state.catalog.count], 0..) |*entry, id| {
                if (!state.removed[id].load(.acquire)) continue;
                state.lock.lock();
                const retired = entry.image;
                entry.image = null;
                entry.version += 1;
                state.lock.unlock();
                if (retired) |image| image.destroy();
            }
        }
        if (state.reload_pending.swap(false, .acq_rel)) for (state.entries[0..state.catalog.count]) |*entry| {
            state.lock.lock();
            if (entry.reload) {
                entry.failed = false;
                entry.refreshing = true;
                entry.reload = false;
            }
            state.lock.unlock();
        };
        if (native.desktop.pressureCheck(pressure) != 0) {
            state.lock.lock();
            state.prefetch_blocked = request.index;
            state.lock.unlock();
            _ = state.pressure_events.fetchAdd(1, .monotonic);
            state.derived_reclaim.store(true, .release);
            state.changed.notify();
            reclaim(state, request.index);
            pressure_selection = request.index;
        }
        var target: ?usize = null;
        state.lock.lock();
        const selected = state.entries[request.index];
        if (!state.removed[request.index].load(.acquire) and !selected.failed and (selected.image == null or selected.refreshing)) target = request.index else if (selected.image != null and !selected.failed and state.config.prefetch and pressure_selection != request.index and state.presented_revision.load(.acquire) == request.revision) {
            for ([_]?usize{ request.next, request.previous }) |candidate| if (candidate) |id| {
                if (!state.removed[id].load(.acquire) and !state.entries[id].failed and (state.entries[id].image == null or state.entries[id].refreshing)) {
                    target = id;
                    break;
                }
            };
        }
        state.lock.unlock();
        if (target) |id| {
            const foreground = id == request.index;
            if (!decode_lanes.acquire(foreground, &state.stop)) {
                _ = posix.poll(null, 0, 5);
                continue;
            }
            defer decode_lanes.release(foreground);
            if (state.stop.load(.acquire)) continue;
            const path = state.catalog.entries[id].path;
            const stamp = Stamp.read(path);
            const image = decodeScheduled(path, memory.allocator(), .{ .speculative = !foreground, .cancel = &state.stop }) catch |first_error| retry: {
                if (state.stop.load(.acquire)) return;
                if (first_error != error.OutOfMemory) {
                    output("decode {s}: {s}; {s}\n", .{ path, @errorName(first_error), native.image.lastError() });
                    failedDecode(state, id, stamp);
                    continue;
                }
                pressure_selection = request.index;
                state.lock.lock();
                state.prefetch_blocked = request.index;
                state.lock.unlock();
                _ = state.allocation_retries.fetchAdd(1, .monotonic);
                reclaim(state, state.getRequest().index);
                break :retry decodeScheduled(path, memory.allocator(), .{ .speculative = !foreground, .cancel = &state.stop }) catch |err| {
                    if (state.stop.load(.acquire)) return;
                    output("decode {s}: {s} after reclaim\n", .{ path, @errorName(err) });
                    failedDecode(state, id, stamp);
                    continue;
                };
            };
            state.lock.lock();
            const retired = state.entries[id].image;
            const removed = state.removed[id].load(.acquire);
            state.entries[id].image = if (removed) null else image;
            state.entries[id].stamp = image.stamp;
            state.entries[id].failed = false;
            state.entries[id].refreshing = false;
            state.entries[id].version += 1;
            state.decode_count += 1;
            state.lock.unlock();
            state.changed.notify();
            if (retired) |value| value.destroy();
            if (removed) image.destroy();
        } else state.changed.wait(observed, 20);
    }
}
fn failedDecode(state: *State, id: usize, stamp: ?Stamp) void {
    state.lock.lock();
    defer state.lock.unlock();
    state.entries[id].failed = true;
    state.entries[id].refreshing = false;
    state.entries[id].stamp = stamp;
    // Keep the last valid representation through partial writes and missing
    // replacements. An unchanged failure never schedules another decode.
}

fn bareView(request: Request) bool {
    return request.overlay_len == 0 and !request.info and !request.menu.open;
}
fn resultFor(request: Request, image: *Image, version: u64, requested_at: f64) Result {
    var view = request.view;
    const size = controls.orientedSize(image.pixels.width, image.pixels.height, request.rotation);
    const viewport: core.Size = .{ .width = @floatFromInt(request.width), .height = @floatFromInt(request.height) };
    if (request.navigation == .keep) if (request.view_source) |source| {
        if (source.index != request.index) view = view.keptViewport(source.size, size, viewport);
    };
    if (!view.manual) view.scale = core.initialScale(view.mode, if (view.use_initial_zoom) request.initial_zoom else null, size, viewport);
    if (request.navigation == .keep) view.clampViewport(size, viewport) else view.clamp(size, viewport);
    return .{ .requested_at = requested_at, .revision = request.revision, .image_version = version, .index = request.index, .width = image.pixels.width, .height = image.pixels.height, .view = view, .stamp = image.stamp, .link_stamp = image.link_stamp };
}
fn frameKey(request: Request, result: Result) FrameKey {
    const view = result.view;
    const size = controls.orientedSize(result.width, result.height, request.rotation);
    const center = core.center(view, size, .{ .width = @floatFromInt(request.width), .height = @floatFromInt(request.height) });
    return .{ .view = .{ .width = request.width, .height = request.height, .scale = view.scale, .x = center.x - size.width * view.scale / 2, .y = center.y - size.height * view.scale / 2, .nearest = request.nearest, .transform = @as(c_uint, request.rotation) | (@as(c_uint, request.mirror) << 2), .fitted = view.surfacePurpose() == .overview }, .checker = request.checker };
}
fn borrowResult(request: Request, image: *Image, version: u64, requested_at: f64) ?Result {
    if (!bareView(request)) return null;
    var result = resultFor(request, image, version, requested_at);
    result.pixels = image.borrowFrame(frameKey(request, result), result.view.surfacePurpose()) orelse return null;
    return result;
}
fn clearFrameCache(state: *State, image: *Image) void {
    var retired: RetiredFrames = .{};
    state.lock.lock();
    image.clearFrames(&retired);
    state.lock.unlock();
    retired.free();
}
fn renderWorker(state: *State) void {
    if (state.context) |context| native.types.bind(context);
    defer state.retirement.collect();
    var rendered_revision: u64 = 0;
    var rendered_version: u64 = 0;
    var retry_revision: u64 = 0;
    var retried = false;
    var snapshot_saved = false;
    var gpu_verified = false;
    while (!state.stop.load(.acquire)) {
        const observed = state.changed.observe();
        state.retirement.collect();
        if (!state.indexed.load(.acquire)) {
            state.changed.wait(observed, 50);
            continue;
        }
        if (state.derived_reclaim.swap(false, .acq_rel)) {
            state.lock.lock();
            const cached = state.entries[state.request.index].image;
            if (cached) |value| _ = value.retain();
            state.prepare_failures = @splat(null);
            state.lock.unlock();
            if (cached) |value| {
                clearFrameCache(state, value);
                native.image.dropDerived(&value.pixels);
                value.destroy();
            }
            native.render.dropBuffers();
        }
        state.lock.lock();
        var request = state.request;
        var requested_at = state.requested_at;
        var entry = state.entries[request.index];
        const displayed = state.presented_revision.load(.acquire) == request.revision and state.presented_version.load(.acquire) == entry.version;
        var foreground = !displayed and !entry.reload and entry.image != null and (request.revision != rendered_revision or (!entry.refreshing and entry.version != rendered_version));
        var image: ?*Image = if (foreground) entry.image else null;
        const displayed_view = if (request.view_source) |source| source.index == request.index and source.revision == request.revision else false;
        if (image == null and displayed and displayed_view and state.config.prefetch and state.prefetch_blocked != request.index and state.render_failed_revision != request.revision) {
            for ([_]?usize{ request.next, request.previous }, 0..) |candidate, side| if (candidate) |id| {
                const neighbor = state.entries[id];
                const value = neighbor.image orelse continue;
                if (neighbor.reload or neighbor.refreshing or state.removed[id].load(.acquire)) continue;
                var predicted = request.forNeighbor(id);
                predicted.overlay_len = 0;
                predicted.overlay[0] = 0;
                predicted.info = false;
                predicted.menu.open = false;
                const key = frameKey(predicted, resultFor(predicted, value, neighbor.version, 0));
                if (value.cached(key) != null) continue;
                if (state.prepare_failures[side]) |failure| {
                    if (failure.index == id and failure.version == neighbor.version and failure.key.matches(key) and failure.epoch == native.types.current().output_epoch.load(.acquire)) continue;
                }
                request = predicted;
                requested_at = 0;
                entry = neighbor;
                image = value;
                foreground = false;
                break;
            };
        }
        const image_version = entry.version;
        const epoch = if (image) |value| value.cache_epoch else 0;
        if (image) |value| _ = value.retain();
        var cached_result: ?Result = null;
        if (image) |value| if (foreground) {
            cached_result = borrowResult(request, value, image_version, requested_at);
        };
        state.lock.unlock();
        const value = image orelse {
            state.changed.wait(observed, 50);
            continue;
        };
        defer value.destroy();
        var result = cached_result orelse resultFor(request, value, image_version, requested_at);
        const key = frameKey(request, result);
        if (cached_result == null) {
            if (native.render.begin() != 0) {
                _ = posix.poll(null, 0, 5);
                continue;
            }
            defer native.render.end();
            var overlay_buffer: [4608]u8 = undefined;
            const overlay = if (request.info) (std.fmt.bufPrintSentinel(&overlay_buffer, "{d}/{d}  {d}x{d}  {d}-bit  {d:.1}%  {s}\n{s}", .{ request.ordinal, request.active_count, value.pixels.width, value.pixels.height, value.pixels.bits, result.view.scale * 100, if (request.playing) "playing" else "paused", request.overlay[0..request.overlay_len] }, 0) catch request.overlay[0..request.overlay_len :0]) else request.overlay[0..request.overlay_len :0];
            native.render.menuConfig(if (request.menu.open) &menu.labels else null, if (request.menu.open) @intCast(menu.count) else 0, @intCast(request.menu.selected), @intCast(request.menu.first), @intCast(request.menu.rows), request.menu.x, request.menu.y, request.menu.width, request.menu.row_height, request.menu.scale);
            if (state.config.trace) output("PREPARE index={d} revision={d} prefetch={any} fitted={any} scale={d:.8} at_s={d:.6}\n", .{ request.index, request.revision, !foreground, key.view.fitted, key.view.scale, runtime.now() });
            var status = native.render.prepare(&value.pixels, key.view, overlay, request.checker, &result.pixels);
            if (status == 0) status = native.window.prepare(&result.pixels);
            if (status != 0) {
                native.render.free(&result.pixels);
                if (!foreground) {
                    state.lock.lock();
                    const latest = state.request;
                    for ([_]?usize{ latest.next, latest.previous }, 0..) |id, side| if (id == request.index) {
                        state.prepare_failures[side] = .{ .index = request.index, .version = image_version, .key = key, .epoch = native.types.current().output_epoch.load(.acquire) };
                    };
                    state.lock.unlock();
                    continue;
                }
                if (retry_revision != request.revision) {
                    retry_revision = request.revision;
                    retried = false;
                }
                if (status == -2 and !retried) {
                    retried = true;
                    clearFrameCache(state, value);
                    native.image.dropDerived(&value.pixels);
                    native.render.dropBuffers();
                    const serial = state.render_reclaimed.load(.acquire);
                    state.render_reclaim.store(true, .release);
                    state.changed.notify();
                    while (!state.stop.load(.acquire) and state.render_reclaimed.load(.acquire) == serial) _ = posix.poll(null, 0, 5);
                    _ = state.native_retries.fetchAdd(1, .release);
                    continue;
                }
                output("render failed: {s}\n", .{native.image.lastError()});
                state.lock.lock();
                state.render_failed_revision = request.revision;
                state.lock.unlock();
                rendered_revision = request.revision;
                rendered_version = image_version;
                continue;
            }
        }
        if (foreground and !snapshot_saved) {
            if (state.config.snapshot) |path| {
                if (native.render.save(&result.pixels, path.ptr) != 0) output("snapshot failed: {s}\n", .{native.image.lastError()});
            }
            snapshot_saved = true;
        }
        if (foreground and state.config.verify_gpu and !gpu_verified) {
            const status = native.window.verify(&result.pixels);
            output("GPU viewport readback: {s}\n", .{if (status == 0) "passed" else if (status == 1) "unavailable (fallback renderer)" else "FAILED"});
            if (status < 0) {
                state.lock.lock();
                state.render_failed_revision = request.revision;
                state.lock.unlock();
                native.render.free(&result.pixels);
                rendered_revision = request.revision;
                rendered_version = image_version;
                continue;
            }
            gpu_verified = true;
        }
        var retired: RetiredFrames = .{};
        var admitted = false;
        state.lock.lock();
        const latest = state.request;
        const valid = state.entries[request.index].image == value and state.entries[request.index].version == image_version and !state.entries[request.index].reload;
        const latest_result = resultFor(latest, value, image_version, 0);
        const same_view = bareView(request) and bareView(latest) and frameKey(latest, latest_result).matches(key);
        const current = valid and latest.index == request.index and (latest.revision == request.revision or same_view);
        if (valid and cached_result == null and bareView(request) and (current or value.cache_epoch == epoch) and (foreground or current or state.prefetch_blocked != latest.index)) {
            if (value.storeFrame(&result.pixels, key, if (current) latest_result.view.surfacePurpose() else result.view.surfacePurpose(), &retired)) |lease| {
                result.pixels = lease;
                admitted = true;
            }
        }
        var previous: native.Frame = .{};
        if (current) {
            result.view = latest_result.view;
            result.revision = latest.revision;
            result.requested_at = state.requested_at;
            previous = state.result.pixels;
            state.result = result;
        }
        state.lock.unlock();
        retired.free();
        if (admitted and state.config.trace) output("CACHED index={d} version={d} fitted={any} scale={d:.8} gpu={any} at_s={d:.6}\n", .{ request.index, image_version, key.view.fitted, key.view.scale, result.pixels.gpu_texture != null, runtime.now() });
        if (current) {
            native.render.free(&previous);
            native.input.wake();
        } else native.render.free(&result.pixels);
        if (foreground) {
            rendered_revision = request.revision;
            rendered_version = image_version;
        }
    }
}

fn executeHook(state: *State, job: *HookJob) !commands.Result {
    var source_path: [4096]u8 = undefined;
    const original_path = try std.fmt.bufPrintSentinel(&source_path, "{s}", .{job.snapshot.path}, 0);
    if (!std.meta.eql(Stamp.read(original_path), job.source_stamp)) return error.SourceChanged;
    var command: [16384]u8 = undefined;
    var metadata: native.Metadata = undefined;
    if (hooks.usesSpecifier(job.template.body(), 't')) {
        if (native.image.probe(@ptrCast(job.snapshot.path.ptr), &metadata) != 0) return error.MetadataFailed;
        job.snapshot.image_format = std.mem.sliceTo(&metadata.format, 0);
    }
    return @import("hook_execution.zig").run(&command, job.template, job.snapshot, .{ .entries = .{ .entries = state.catalog.entries[0..state.catalog.count], .order = job.order[0..job.count] } }, &state.stop);
}

fn auxiliary(state: *State, job: *HookJob) !commands.Result {
    if (state.stop.load(.acquire)) return error.Cancelled;
    var buffer: [4096]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buffer, "{s}", .{job.snapshot.path}, 0);
    if (!std.meta.eql(Stamp.read(path), job.source_stamp) or !std.meta.eql(Stamp.readLink(path), job.link_stamp)) return error.SourceChanged;
    if (native.desktop.action(path.ptr, switch (job.kind) {
        .trash => 1,
        .reveal => 2,
        else => 3,
    }) != 0) return error.DesktopOperationFailed;
    return .{ .status = 0 };
}
fn hookWorker(state: *State) void {
    if (state.context) |context| native.types.bind(context);
    while (!state.stop.load(.acquire)) {
        state.lock.lock();
        const pending = state.hook_pending;
        var job: HookJob = undefined;
        if (pending) {
            job = state.hook_job;
            state.hook_pending = false;
            state.hook_running = true;
        }
        state.lock.unlock();
        if (pending) {
            var failed = false;
            const result = (if (job.kind == .shell) executeHook(state, &job) else auxiliary(state, &job)) catch |err| value: {
                output("hook failed: {s}\n", .{@errorName(err)});
                failed = true;
                break :value commands.Result{};
            };
            runtime.output(2, result.output[0..result.len]);
            const exists = @import("source").exists(job.snapshot.path);
            state.lock.lock();
            state.hook_running = false;
            state.hook_failed = failed or !result.success();
            state.hook_finished += 1;
            state.hook_revision = job.revision;
            state.hook_remove = if (!exists and (job.kind == .shell or (job.kind == .trash and !failed and result.success()))) job.index else null;
            state.hook_advance = if (job.kind == .shell and exists and !job.reload and !state.hook_failed) job.index else null;
            if (job.kind == .shell and job.reload and !state.hook_failed) {
                state.entries[job.index].reload = true;
                state.reload_pending.store(true, .release);
            }
            state.lock.unlock();
        } else _ = posix.poll(null, 0, 10);
    }
}

fn navigate(request: *Request, count: usize, backwards: bool) void {
    request.index = if (backwards) (request.index + count - 1) % count else (request.index + 1) % count;
    request.view.reset();
    request.revision += 1;
}
fn modifiers(raw: u32) usize {
    return (if (raw & 1 != 0) actions.shift else @as(usize, 0)) |
        (if (raw & 2 != 0) actions.control else @as(usize, 0)) |
        (if (raw & 4 != 0) actions.option else @as(usize, 0)) |
        (if (raw & 8 != 0) actions.command else @as(usize, 0));
}
fn overlayText(request: *Request, comptime format: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(request.overlay[request.overlay_len..request.overlay.len], format, args) catch return;
    request.overlay_len += text.len;
    request.overlay[request.overlay_len] = 0;
}
fn makeOverlay(state: *State, request: *Request, notice: []const u8) void {
    request.overlay_len = 0;
    request.overlay[0] = 0;
    const model = &state.controller;
    if (model.draw_filename) overlayText(request, "{s}\n", .{state.catalog.entries[request.index].path});
    request.info = model.info;
    request.ordinal = model.position + 1;
    request.active_count = model.count;
    request.playing = model.playing;
    if (model.draw_actions) for (&model.settings.hooks, 0..) |*hook, i| {
        if (hook.body().len == 0) continue;
        const label = if (hook.title().len > 0) hook.title() else hook.body();
        overlayText(request, "{d}: {s}\n", .{ i, label[0..@min(label.len, 160)] });
    };
    if (model.help) {
        overlayText(request, "Active keys (repeat help/menu to hide):\n", .{});
        for (model.settings.bindings[0..model.settings.binding_count]) |binding| {
            var buffer: [16]u8 = undefined;
            const named = actions.keyName(binding.key);
            const key = if (named.len > 0) named else if (binding.key > 32 and binding.key < 127) std.fmt.bufPrint(&buffer, "{c}", .{@as(u8, @intCast(binding.key))}) catch "?" else std.fmt.bufPrint(&buffer, "0x{x}", .{binding.key}) catch "?";
            overlayText(request, "{s}{s}{s}{s}{s}: {s}\n", .{ if (binding.modifiers & actions.control != 0) "Ctrl+" else "", if (binding.modifiers & actions.shift != 0) "Shift+" else "", if (binding.modifiers & actions.option != 0) "Alt+" else "", if (binding.modifiers & actions.command != 0) "Super+" else "", key, @tagName(binding.action) });
        }
    }
    if (notice.len > 0) overlayText(request, "{s}\n", .{notice});
}
fn markRemoved(state: *State, id: usize) void {
    state.removed[id].store(true, .release);
    state.removal_pending.store(true, .release);
}
// Each window has reusable startup storage. Its coordinator owns worker joins
// and retirement. During handoff the UI touches only Life.
const Phase = enum(u8) { handoff, active, failed, retired };
const Life = struct {
    state: *State,
    context: ?*native.Window = null,
    prepare: bool = false,
    software: bool = false,
    prefetch: bool = true,
    trace: bool = false,
    workers: c_int = 0,
    catalog_options: catalog.Options = .{},
    filename: bool = false,
    draw_actions: bool = false,
    extra_frame: native.Frame = native.Frame{},
    extra_retired: native.Frame = native.Frame{},
    geometry: native.Geometry = std.mem.zeroes(native.Geometry),
    persist_geometry: bool = false,
    selection: native.Selection = undefined,
    settings: actions.Settings = .{},
    width: c_int = 1100,
    height: c_int = 760,
    nearest: bool = false,
    paused: bool = false,
    view: core.View = .{},
    quit: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.handoff),
    save_failed: bool = false,
    test_opened: bool = false,
};

fn initialize(state: *State) void {
    @memset(std.mem.asBytes(state), 0);
    state.config = .{};
    state.catalog.cancel = null;
    state.catalog.selected = null;
    state.catalog.initial = null;
    state.catalog.on_initial = null;
    const seed: u64 = @bitCast(runtime.now());
    state.catalog.random = .init(seed);
    state.lock = .{};
    state.request = .{};
    state.requested_at = 0;
    state.result = .{};
    state.controller.random = .init(seed);
}
fn configureController(state: *State) void {
    state.controller.settings = state.config.settings;
    state.controller.initial_zoom = state.config.initial_zoom;
    state.controller.playing = state.config.settings.interval > 0 and !state.config.paused;
    state.controller.shuffle_wrap = state.config.catalog_options.shuffle;
    state.controller.draw_filename = state.config.draw_filename;
    state.controller.draw_actions = state.config.draw_actions;
    state.request.checker = state.config.settings.checker;
}
fn coordinate(life: *Life) void {
    if (life.context) |context| native.types.bind(context);
    defer native.render.free(&life.extra_frame);
    defer native.render.free(&life.extra_retired);
    const state = life.state;
    const functions = .{ decodeWorker, renderWorker, hookWorker, watchWorker };
    var threads: [functions.len]std.Thread = undefined;
    var count: usize = 0;
    defer {
        state.stop.store(true, .release);
        state.changed.notify();
        for (threads[0..count]) |thread| thread.join();
        native.render.free(&state.result.pixels);
        life.save_failed = life.save_failed or state.save_failed.load(.acquire);
    }
    inline for (functions) |function| {
        threads[count] = std.Thread.spawn(.{}, function, .{state}) catch {
            state.stop.store(true, .release);
            state.changed.notify();
            life.phase.store(.failed, .release);
            while (!life.quit.load(.acquire)) _ = posix.poll(null, 0, 5);
            return;
        };
        count += 1;
    }
    life.phase.store(.active, .release);
    while (!life.quit.load(.acquire)) _ = posix.poll(null, 0, 5);
}

const Ui = struct {
    initialized: bool = false,
    display_dirty: bool = false,
    ignore_click: bool = false,
    menu: menu.Menu = .{},
    open_test_requested: bool = false,
    request: Request = .{},
    dirty: bool = false,
    reload_pending: bool = false,
    ready: bool = false,
    source: core.Size = .{ .width = 0, .height = 0 },
    base_width: u32 = 0,
    base_height: u32 = 0,
    presented: usize = 0,
    started: f64 = 0,
    max_event_ms: f64 = 0,
    hook_submitted: bool = false,
    hook_serial: usize = 0,
    displayed_index: ?usize = null,
    displayed_stamp: ?Stamp = null,
    displayed_link_stamp: ?Stamp = null,
    trash_confirmation: ?HookJob = null,
    pending_hook: HookJob = .{},
    hook_queued: bool = false,
    pending: Result = .{},
    retiring: native.Frame = native.Frame{},
    notice: [256]u8 = undefined,
    notice_text: []const u8 = "",
    test_keys: std.mem.TokenIterator(u8, .scalar) = undefined,
    test_key_pending: bool = false,
    watch_stage: u8 = 0,
    first_version: u64 = 0,
    fn start(self: *Ui, state: *State) void {
        self.* = .{ .initialized = true, .request = state.request, .started = runtime.now(), .test_keys = std.mem.tokenizeScalar(u8, state.config.test_keys orelse "", ',') };
    }
};
const UiEffect = enum { idle, close, quit_all };
fn sessionTick(state: *State, life: *Life, ui: *Ui, incoming: native.Event) !UiEffect {
    _ = state.retirement.push(&ui.retiring);
    var event = incoming;
    if (state.config.test_keys != null and event.kind == 2) ui.test_key_pending = false;
    if (state.index_failed.load(.acquire)) {
        if (state.config.smoke or state.config.stress > 0) return error.IndexFailed;
        native.window.title("Yekk — could not open selection; Ctrl+O to retry");
    }
    const event_start = runtime.now();
    defer ui.max_event_ms = @max(ui.max_event_ms, (runtime.now() - event_start) * 1000);
    if (event.kind == 1) return .close;
    if (event.kind == 11) {
        ui.display_dirty = true;
        native.render.displayChanged();
    }
    if (ui.display_dirty and native.render.refreshDisplay() == 0) {
        ui.display_dirty = false;
        ui.menu.layout(ui.request.width, ui.request.height, native.render.contentScale());
        ui.request.revision += 1;
        ui.dirty = true;
    }
    if (event.kind == 2 and (event.modifiers & 2 != 0 or event.modifiers & 8 != 0) and (event.key == 'o' or event.key == 'O') and !ui.ready) {
        native.input.openDialog(if (event.modifiers & 1 != 0) .directories else .files, if (ui.ready) state.catalog.entries[ui.request.index].path else state.config.paths[0]);
    }
    if (!ui.ready and event.kind == 2 and (event.key == 'q' or event.key == 27)) return .quit_all;
    if (!ui.ready and state.indexed.load(.acquire) and state.lock.tryLock()) {
        ui.request = state.request;
        state.lock.unlock();
        var width: c_int = 0;
        var height: c_int = 0;
        native.window.size(&width, &height);
        if (width > 0 and height > 0 and (width != ui.request.width or height != ui.request.height)) {
            ui.request.width = width;
            ui.request.height = height;
            ui.request.revision += 1;
        }
        state.controller.start(state.catalog.count, ui.request.index, &ui.request);
        if (state.config.recovery_test and state.catalog.count < 2) return error.RecoveryTestNeedsTwoImages;
        state.controller_ready.store(true, .release);
        ui.ready = true;
        ui.dirty = true;
    }
    if (ui.ready) {
        var effect: controls.Effect = .{};
        var confirmation_changed = false;
        if (ui.trash_confirmation) |job| {
            if (event.kind == 2 or event.kind == 3 or event.kind == 4 or event.kind == 6 or event.kind == 8 or event.kind == 9) {
                ui.trash_confirmation = null;
                confirmation_changed = true;
                ui.notice_text = "Trash cancelled";
                state.controller.deadline = if (state.controller.playing) runtime.now() + state.controller.settings.interval else null;
                if (event.kind == 2 and event.key == 13) {
                    ui.pending_hook = job;
                    ui.hook_queued = true;
                    ui.notice_text = "Moving captured source to Trash";
                    event.kind = 0;
                } else if (event.kind == 2 and event.key == 27) event.kind = 0;
            }
        }
        var menu_action: ?actions.Action = null;
        if (event.kind == 6 and event.key == 3) {
            ui.menu.open = !ui.menu.open;
            ui.menu.x = @intFromFloat(event.x);
            ui.menu.y = @intFromFloat(event.y);
            ui.menu.layout(ui.request.width, ui.request.height, native.render.contentScale());
            effect.changed = true;
            event.kind = 0;
        }
        if (ui.menu.open) {
            if (event.kind == 2) {
                switch (event.key) {
                    0xf700 => ui.menu.move(true),
                    0xf701 => ui.menu.move(false),
                    13 => {
                        menu_action = ui.menu.action();
                        ui.menu.open = false;
                    },
                    27, 'm' => ui.menu.open = false,
                    else => {},
                }
                effect.changed = true;
                event.kind = 0;
            } else if (event.kind == 3) {
                ui.menu.move(event.y > 0);
                effect.changed = true;
                event.kind = 0;
            } else if (event.kind == 6 and event.key == 1) {
                if (ui.menu.hit(event.x, event.y)) |item| {
                    ui.menu.selected = item;
                    menu_action = ui.menu.action();
                }
                ui.menu.open = false;
                ui.ignore_click = true;
                effect.changed = true;
                event.kind = 0;
            } else if (event.kind == 4 or event.kind == 9) event.kind = 0;
        }
        if (menu_action) |action| {
            effect = state.controller.apply(action, &ui.request, state.catalog.entries[0..state.catalog.count], runtime.now());
            effect.changed = true;
        }
        if (event.kind == 2 and event.key > 0 and event.key <= 65535) {
            if (state.controller.settings.lookup(@intCast(event.key), modifiers(event.modifiers))) |action| effect = state.controller.apply(action, &ui.request, state.catalog.entries[0..state.catalog.count], runtime.now());
            if (state.config.test_keys != null) effect.changed = true;
        }
        if (event.kind == 3 and event.y != 0) effect = state.controller.step(event.y > 0, false, &ui.request);
        if (event.kind == 8) {
            if (ui.ignore_click) ui.ignore_click = false else if (event.key == 1) effect = state.controller.step(false, false, &ui.request) else if (event.key == 2) effect = state.controller.apply(.actual, &ui.request, state.catalog.entries[0..state.catalog.count], runtime.now());
        }
        if (event.kind == 12) ui.ignore_click = false;
        if (event.kind == 9) {
            ui.request.view.zoom(std.math.pow(f64, state.controller.settings.zoom_step, event.y), event.anchor_x - @as(f32, @floatFromInt(ui.request.width)) / 2, event.anchor_y - @as(f32, @floatFromInt(ui.request.height)) / 2);
            effect.changed = true;
        }
        if (event.kind == 4) {
            ui.request.view.pan_x += event.x;
            ui.request.view.pan_y += event.y;
            ui.request.view.manual = true;
            effect.changed = true;
        }
        if (event.kind == 5) {
            native.window.size(&ui.request.width, &ui.request.height);
            effect.changed = true;
        }
        effect.changed = effect.changed or confirmation_changed;
        if (effect.quit_all) return .quit_all;
        if (effect.quit) {
            if (effect.removed) |id| markRemoved(state, id);
            return .close;
        }
        if (effect.removed) |id| markRemoved(state, id);
        ui.reload_pending = ui.reload_pending or effect.reload;
        if (effect.platform) |action| {
            switch (action) {
                .fullscreen => native.window.fullscreen(),
                .open => {
                    native.input.openDialog(if (event.modifiers & 1 != 0) .directories else .files, if (ui.ready) state.catalog.entries[ui.request.index].path else state.config.paths[0]);
                },
                .trash, .reveal, .external => if (ui.displayed_index == ui.request.index and state.controller.shown_index == ui.request.index and !ui.hook_queued) {
                    const job: HookJob = .{
                        .kind = switch (action) {
                            .trash => .trash,
                            .reveal => .reveal,
                            else => .external,
                        },
                        .snapshot = .{ .path = state.catalog.entries[ui.request.index].path },
                        .index = ui.request.index,
                        .revision = state.controller.selection_serial,
                        .source_stamp = ui.displayed_stamp,
                        .link_stamp = ui.displayed_link_stamp,
                    };
                    if (action == .trash) {
                        ui.trash_confirmation = job;
                        ui.notice_text = std.fmt.bufPrint(&ui.notice, "Move to Trash: {s}? Enter confirms; Esc cancels", .{std.fs.path.basename(job.snapshot.path)[0..@min(160, std.fs.path.basename(job.snapshot.path).len)]}) catch "Move captured file to Trash? Enter confirms; Esc cancels";
                    } else {
                        ui.pending_hook = job;
                        ui.hook_queued = true;
                        ui.notice_text = "Preparing desktop operation";
                    }
                    effect.changed = true;
                },
                .info => {
                    state.controller.info = !state.controller.info;
                    effect.changed = true;
                },
                .help => {
                    state.controller.help = !state.controller.help;
                    effect.changed = true;
                },
                .menu => {
                    ui.menu.open = !ui.menu.open;
                    ui.menu.layout(ui.request.width, ui.request.height, native.render.contentScale());
                    effect.changed = true;
                },
                .draw_filename => {
                    state.controller.draw_filename = !state.controller.draw_filename;
                    effect.changed = true;
                },
                .draw_actions => {
                    state.controller.draw_actions = !state.controller.draw_actions;
                    effect.changed = true;
                },
                .background => {
                    ui.request.checker = !ui.request.checker;
                    effect.changed = true;
                },
                .resize_window => {
                    if (ui.base_width > 0) native.window.resizeImage(@intFromFloat(ui.source.width), @intFromFloat(ui.source.height));
                },
                else => {
                    ui.notice_text = std.fmt.bufPrint(&ui.notice, "Action not available on Linux yet: {s}", .{@tagName(action)}) catch "Action unavailable";
                    effect.changed = true;
                },
            }
        }
        if (effect.changed and ui.request.width > 0 and ui.request.height > 0) {
            ui.source = controls.orientedSize(ui.base_width, ui.base_height, ui.request.rotation);
            ui.request.view.clamp(ui.source, .{ .width = @floatFromInt(ui.request.width), .height = @floatFromInt(ui.request.height) });
            ui.request.revision += 1;
            ui.dirty = true;
        }
        if (effect.hook) |action_index| {
            const action = &state.controller.settings.hooks[action_index];
            if (action.body().len > 0 and ui.displayed_index == ui.request.index and state.controller.shown_index == ui.request.index and !ui.hook_queued) {
                ui.pending_hook.kind = .shell;
                ui.pending_hook.template = action.*;
                ui.pending_hook.snapshot = (hooks.Snapshot{
                    .path = state.catalog.entries[ui.request.index].path,
                    .width = ui.base_width,
                    .height = ui.base_height,
                    .bytes = @intCast(@max(0, if (ui.displayed_stamp) |stamp| stamp.bytes else state.catalog.entries[ui.request.index].bytes)),
                    .index = state.controller.position + 1,
                    .count = state.controller.count,
                    .rotation = ui.request.rotation,
                    .playing = state.controller.playing,
                    .pid = posix.getpid(),
                }).withView(ui.request.view, .{ .width = @floatFromInt(ui.request.width), .height = @floatFromInt(ui.request.height) });
                ui.pending_hook.index = ui.request.index;
                ui.pending_hook.reload = action.reload;
                ui.pending_hook.revision = state.controller.selection_serial;
                ui.pending_hook.source_stamp = ui.displayed_stamp;
                ui.pending_hook.count = if (hooks.needsManifest(action.body())) state.controller.count else 0;
                @memcpy(ui.pending_hook.order[0..ui.pending_hook.count], state.controller.order[0..ui.pending_hook.count]);
                ui.hook_queued = true;
            }
        }
        if (ui.hook_queued and state.lock.tryLock()) {
            if (!state.hook_running and !state.hook_pending and ui.hook_serial == state.hook_finished) {
                state.hook_job = ui.pending_hook;
                state.hook_pending = true;
                ui.hook_submitted = true;
                ui.hook_queued = false;
            }
            state.lock.unlock();
        }
    }
    var result: Result = .{};
    // Once a result leaves State it belongs to this tick, including early
    // slideshow/hook exits. The UI only transfers ownership to worker cleanup.
    defer if (!state.retirement.push(&result.pixels)) {
        std.debug.assert(ui.retiring.pixels == null);
        ui.retiring = result.pixels;
    };
    var failed = false;
    var render_failed = false;
    var retained_failure = false;
    var reload_busy = false;
    var current_version: u64 = 0;
    var retries: usize = 0;
    var reclaimed: usize = 0;
    var have_snapshot = false;
    var hook_done = false;
    var hook_failed = false;
    var completed_hook = false;
    var advance: ?usize = null;
    var remove: ?usize = null;
    var completion_revision: u64 = 0;
    if (ui.ready and state.lock.tryLock()) {
        have_snapshot = true;
        if (ui.retiring.pixels == null) {
            result = state.result;
            state.result.pixels = native.Frame{};
        }
        retained_failure = state.entries[ui.request.index].failed and state.entries[ui.request.index].image != null;
        reload_busy = state.entries[ui.request.index].reload or state.entries[ui.request.index].refreshing;
        current_version = state.entries[ui.request.index].version;
        retries = state.allocation_retries.load(.acquire);
        reclaimed = state.inactive_reclaimed.load(.acquire);
        render_failed = state.render_failed_revision == ui.request.revision;
        failed = (state.entries[ui.request.index].failed and !retained_failure) or state.render_failed_revision == ui.request.revision;
        hook_done = ui.hook_submitted and !state.hook_pending and !state.hook_running;
        hook_failed = state.hook_failed;
        if (ui.hook_serial != state.hook_finished) {
            ui.hook_serial = state.hook_finished;
            completed_hook = true;
            advance = state.hook_advance;
            remove = state.hook_remove;
            completion_revision = state.hook_revision;
        }
        state.lock.unlock();
    }
    if (ui.ready and completed_hook) {
        var effect: controls.Effect = .{};
        if (remove) |id| effect = state.controller.removeId(id, &ui.request) else if (advance) |id| {
            if (ui.request.index == id and completion_revision == state.controller.selection_serial) effect = state.controller.step(false, false, &ui.request);
        }
        if (effect.removed) |id| markRemoved(state, id);
        if (effect.quit) return .close;
        ui.request.revision += 1;
        ui.dirty = true;
        ui.notice_text = if (hook_failed) "Command failed (see stderr)" else "Command completed";
    }
    if (ui.ready and ui.trash_confirmation == null) {
        const was_playing = state.controller.playing;
        const tick = state.controller.tick(runtime.now(), failed, &ui.request);
        if (tick.quit) return .close;
        if (tick.changed) ui.dirty = true;
        if (was_playing != state.controller.playing and state.controller.info) {
            ui.request.revision += 1;
            ui.dirty = true;
        }
    }
    if (ui.ready and ui.dirty) {
        ui.request.menu = ui.menu;
        state.controller.snapshotNavigation(&ui.request);
        makeOverlay(state, &ui.request, ui.notice_text);
        if (state.lock.tryLock()) {
            state.request = ui.request;
            state.requested_at = if (state.config.trace) runtime.now() else 0;
            if (ui.reload_pending) {
                state.entries[ui.request.index].reload = true;
                state.reload_pending.store(true, .release);
                ui.reload_pending = false;
            }
            state.lock.unlock();
            state.changed.notify();
            ui.dirty = false;
        }
    }
    if (!ui.dirty and ui.ready and ui.retiring.pixels == null and (result.pixels.pixels == null or result.revision != ui.request.revision)) {
        if (state.retirement.push(&result.pixels) and state.lock.tryLock()) {
            const selected = state.entries[ui.request.index];
            const already_shown = state.presented_revision.load(.acquire) == ui.request.revision and state.presented_version.load(.acquire) == selected.version;
            if (!already_shown and !selected.reload) if (selected.image) |image| {
                if (borrowResult(ui.request, image, selected.version, state.requested_at)) |ready| {
                    result = ready;
                    if (state.config.trace) output("CACHE_HIT index={d} revision={d} at_s={d:.6}\n", .{ ui.request.index, ui.request.revision, runtime.now() });
                }
            };
            state.lock.unlock();
        }
    }
    if (ui.retiring.pixels != null) return .idle;
    if (result.pixels.pixels != null) {
        if (!state.retirement.push(&ui.pending.pixels)) {
            ui.retiring = ui.pending.pixels;
            ui.pending = result;
            result.pixels = .{};
            return .idle;
        }
    } else {
        result = ui.pending;
        ui.pending = .{};
    }
    if (result.pixels.pixels != null) {
        if (!have_snapshot) {
            ui.pending = result;
            result.pixels = .{};
            return .idle;
        }
        if (!ui.dirty and result.revision == ui.request.revision and result.index == ui.request.index and result.image_version == current_version and !(state.presented_revision.load(.acquire) == result.revision and state.presented_version.load(.acquire) == result.image_version)) {
            const status = native.window.present(&result.pixels);
            if (status < 0) return error.PresentFailed;
            if (status == 1) {
                ui.pending = result;
                result.pixels = native.Frame{};
                return .idle;
            }
            if (status == 2) return .idle;
            ui.base_width = result.width;
            ui.base_height = result.height;
            ui.source = controls.orientedSize(result.width, result.height, ui.request.rotation);
            ui.displayed_index = result.index;
            ui.displayed_stamp = result.stamp;
            ui.displayed_link_stamp = result.link_stamp;
            state.presented_version.store(result.image_version, .release);
            state.presented_revision.store(result.revision, .release);
            state.controller.presented(result.index, runtime.now());
            ui.request.view = result.view;
            ui.request.view_source = .{ .index = result.index, .revision = result.revision, .size = ui.source };
            // Publish the resolved numeric view before predicting neighbors.
            // An automatic fit request does not yet contain its computed zoom.
            ui.dirty = true;
            var title: [8192]u8 = undefined;
            const text = try std.fmt.bufPrintSentinel(&title, "{s} — {d}/{d} — {d}×{d} — {d:.1}%", .{ state.catalog.entries[result.index].path, state.controller.position + 1, state.controller.count, result.width, result.height, result.view.scale * 100 }, 0);
            native.window.title(text.ptr);
            ui.presented += 1;
            if (ui.presented == 1) ui.first_version = result.image_version;
            if (state.config.native_recovery_test) {
                if (ui.presented == 1) {
                    native.render.failNativeNext();
                    ui.request.checker = !ui.request.checker; // Force a real allocation, not a ready hit.
                    ui.request.revision += 1;
                    ui.dirty = true;
                } else {
                    if (state.native_retries.load(.acquire) != 1) return error.NativeRecoveryFailed;
                    runtime.output(1, "NATIVE_RECOVERY_PASSED\n");
                    return .close;
                }
            }
            if (state.config.recovery_test) {
                if (ui.presented == 1) {
                    memory.failNext(1);
                    _ = state.controller.step(false, false, &ui.request);
                    ui.dirty = true;
                } else if (ui.request.index != 0) {
                    if (retries != 1 or reclaimed == 0) return error.RecoveryFailed;
                    runtime.output(1, "RECOVERY_PASSED\n");
                    return .close;
                }
            }
            if (state.config.trace) {
                var buffer: [512]u8 = undefined;
                runtime.output(1, try std.fmt.bufPrint(&buffer, "VIEW index={d} count={d} id={d} scale={d:.8} rotation={d} mirror={d} playing={any} width={d} height={d} window={d} dpi_scale={d:.3} viewport_width={d} viewport_height={d} pixel_density={d:.3} at_ms={d:.3} request_ms={d:.3}\n", .{ state.controller.position, state.controller.count, ui.request.index, result.view.scale, ui.request.rotation, ui.request.mirror, state.controller.playing, result.width, result.height, native.window.id(), native.render.contentScale(), ui.request.width, ui.request.height, native.window.density(), (runtime.now() - ui.started) * 1000, if (result.requested_at > 0) (runtime.now() - result.requested_at) * 1000 else 0 }));
            }
            if (state.config.test_keys != null and !ui.test_key_pending) {
                if (ui.test_keys.next()) |key| {
                    const binding = try actions.parseKey(key);
                    const flags: c_uint = (if (binding.modifiers & actions.shift != 0) @as(c_uint, 1) else 0) | (if (binding.modifiers & actions.control != 0) @as(c_uint, 2) else 0) | (if (binding.modifiers & actions.option != 0) @as(c_uint, 4) else 0) | (if (binding.modifiers & actions.command != 0) @as(c_uint, 8) else 0);
                    ui.test_key_pending = true;
                    native.input.testKeyMod(binding.key, flags);
                } else if (!ui.hook_queued and (!ui.hook_submitted or hook_done) and !reload_busy) {
                    if (hook_failed) return error.HookFailed;
                    if (!state.config.test_wait) return .close;
                }
            }
            if (state.config.watch_test) {
                if (ui.watch_stage == 0) {
                    runtime.output(1, "WATCH_READY\n");
                    ui.watch_stage = 1;
                } else if (ui.watch_stage == 2 and result.image_version != ui.first_version) {
                    runtime.output(1, "WATCH_RECOVERED\n");
                    return .close;
                }
            }
            if (state.config.smoke_hook and ui.presented == 1) native.input.testKey(13);
            if (state.config.smoke_reload) {
                if (ui.presented == 1) native.input.testKey('r') else if (result.image_version != ui.first_version) return .close;
            }
            if (state.config.smoke_resize) {
                const sizes = [_][2]c_int{ .{ 640, 480 }, .{ 1600, 900 }, .{ 320, 240 }, .{ 1100, 760 } };
                if (ui.presented > sizes.len) return .close;
                native.input.testResize(sizes[ui.presented - 1][0], sizes[ui.presented - 1][1]);
                native.window.size(&ui.request.width, &ui.request.height);
                ui.request.revision += 1;
                ui.dirty = true;
            }
            if (state.config.test_open) |path| {
                if (ui.presented == 1) {
                    native.input.testDrop(path);
                    ui.open_test_requested = true;
                }
            }
            if (life.test_opened and ui.presented == 1) runtime.output(1, "OPEN_PRESENTED\n");
            if (state.config.smoke or (state.config.stress > 0 and ui.presented >= state.config.stress)) return .close;
            if (state.config.stress > 0) {
                if (ui.presented % 3 == 0) {
                    _ = state.controller.step(false, false, &ui.request);
                    ui.request.revision += 1;
                } else {
                    ui.request.view.manual = true;
                    ui.request.view.scale = if (ui.presented % 3 == 1) 1 else result.view.scale;
                    ui.request.view.pan_x += 64;
                    ui.request.revision += 1;
                }
                ui.dirty = true;
            }
        }
    }
    if (state.config.watch_test and ui.watch_stage == 1 and retained_failure) {
        runtime.output(1, "WATCH_RETAINED\n");
        ui.watch_stage = 2;
    }
    if (failed) {
        native.window.title(if (render_failed) "Yekk — RenderFailed (see stderr)" else "Yekk — DecodeFailed (see stderr)");
        if (state.config.smoke or state.config.smoke_hook or state.config.smoke_reload or state.config.smoke_resize or state.config.recovery_test or state.config.native_recovery_test or state.config.stress > 0) return if (render_failed) error.RenderFailed else error.DecodeFailed;
    }
    if (state.config.smoke_hook and hook_done) {
        if (hook_failed) return error.HookFailed;
        return .close;
    }

    return .idle;
}

const SlotStatus = enum { vacant, starting, active, closing };
const Slot = struct {
    state: State,
    life: Life,
    ui: Ui,
    native: native.Window,
    status: SlotStatus,
    id: u32,
};
const Application = struct {
    slots: [native.window_limit]Slot,
    selection: native.Selection,
    failed: bool,
    decodes: usize,
    pressure: usize,
    retries: usize,
    native_retries: usize,
    reclaimed: usize,
    window_test_path: ?[:0]const u8,
    window_test_stage: u8,
    window_test_origin: u32,
    window_test_child: u32,
    window_test_base: u32,
    window_test_last_count: usize,
    window_test_capacity_hit: bool,
    geometry: native.Geometry,
    persist_geometry: bool,
};
fn configureNativeInput(life: *Life) void {
    const state = life.state;
    initialize(state);
    state.context = life.context;
    state.config.settings = life.settings;
    state.config.software = life.software;
    state.config.workers = life.workers;
    state.config.prefetch = life.prefetch;
    state.config.trace = life.trace;
    state.config.smoke = life.test_opened;
    state.config.draw_filename = life.filename;
    state.config.draw_actions = life.draw_actions;
    state.config.catalog_options = life.catalog_options;
    state.config.paused = life.paused;
    state.config.count = life.selection.count;
    const used = life.selection.used;
    @memcpy(state.config.filelist_data[0..used], life.selection.bytes[0..used]);
    for (life.selection.offsets[0..life.selection.count], 0..) |offset, i| {
        const text = std.mem.sliceTo(state.config.filelist_data[offset..used], 0);
        state.config.paths[i] = state.config.filelist_data[offset .. offset + text.len :0];
    }
    state.request.width = life.width;
    state.request.height = life.height;
    state.request.nearest = life.nearest;
    state.request.view = life.view;
    configureController(state);
}
fn windowCoordinator(life: *Life) void {
    native.types.bind(life.context);
    if (life.prepare) configureNativeInput(life);
    coordinate(life);
    if (life.persist_geometry) native.window.save(&life.geometry);
    native.render.contextFinish();
    // This release is the coordinator's final access to application storage.
    // The detached thread's runtime cleanup does not access its window/session.
    life.phase.store(.retired, .release);
}
fn startSlot(slot: *Slot, initial: bool) !void {
    @memset(std.mem.asBytes(&slot.native), 0);
    native.types.bind(&slot.native);
    const cfg = if (initial) &slot.state.config else null;
    if (native.window.open(@intFromBool(if (cfg) |value| value.software else slot.life.software), @intFromBool(if (cfg) |value| value.fullscreen else false), @intFromBool(if (cfg) |value| value.borderless else false)) != 0) {
        native.render.contextFinish();
        native.window.close();
        return error.WindowFailed;
    }
    errdefer {
        native.render.contextFinish();
        native.window.close();
    }
    slot.id = native.window.id();
    slot.life.context = &slot.native;
    if (initial) {
        slot.state.context = &slot.native;
        native.window.restore(&slot.life.geometry);
        if (slot.state.config.geometry) |geometry| native.window.geometry(geometry);
        native.window.size(&slot.state.request.width, &slot.state.request.height);
    } else native.window.size(&slot.life.width, &slot.life.height);
    slot.ui.initialized = false;
    slot.status = .starting;
    const coordinator = try std.Thread.spawn(.{}, windowCoordinator, .{&slot.life});
    coordinator.detach();
}
fn closeSlot(slot: *Slot) void {
    if (slot.status == .vacant or slot.status == .closing) return;
    native.types.bind(&slot.native);
    if (slot.life.persist_geometry) native.window.capture(&slot.life.geometry);
    native.window.hide();
    if (slot.ui.initialized) {
        slot.life.extra_frame = slot.ui.pending.pixels;
        slot.life.extra_retired = slot.ui.retiring;
        slot.ui.pending = .{};
        slot.ui.retiring = native.Frame{};
    }
    slot.status = .closing;
    slot.life.quit.store(true, .release);
}
fn closeAll(application: *Application) void {
    for (&application.slots) |*slot| closeSlot(slot);
}
fn viewer(application: *Application) !void {
    const first = &application.slots[0];
    application.window_test_path = first.state.config.window_test;
    application.window_test_stage = 0;
    application.window_test_last_count = 0;
    application.window_test_capacity_hit = false;
    application.window_test_origin = 0;
    application.window_test_child = 0;
    application.window_test_base = 0;
    first.life = .{ .state = &first.state, .geometry = application.geometry, .persist_geometry = application.persist_geometry };
    defer {
        native.types.bind(null);
        native.window.shutdown();
    }
    try startSlot(first, true);
    var live: usize = 1;
    while (live > 0) {
        var incoming: native.Event = undefined;
        native.input.event(&incoming);
        if (incoming.kind == 10) closeAll(application);
        for (&application.slots) |*slot| {
            if (slot.status == .vacant) continue;
            const phase = slot.life.phase.load(.acquire);
            native.types.bind(&slot.native);
            if (phase == .retired) {
                application.failed = application.failed or slot.life.save_failed;
                application.decodes += slot.state.decode_count;
                application.pressure += slot.state.pressure_events.load(.acquire);
                application.retries += slot.state.allocation_retries.load(.acquire);
                application.native_retries += slot.state.native_retries.load(.acquire);
                application.reclaimed += slot.state.inactive_reclaimed.load(.acquire);
                if (memory.report or memory.debug_enabled) output("linux viewer: frames={d}, elapsed_ms={d:.3}, max_ui_work_ms={d:.3}\n", .{ if (slot.ui.initialized) slot.ui.presented else 0, if (slot.ui.initialized) (runtime.now() - slot.ui.started) * 1000 else 0, if (slot.ui.initialized) slot.ui.max_event_ms else 0 });
                native.window.close();
                slot.status = .vacant;
                slot.id = 0;
                live -= 1;
                continue;
            }
            if (slot.status == .closing) continue;
            if (incoming.window_id == slot.id and incoming.kind == 1) {
                closeSlot(slot);
                continue;
            }
            if (phase == .failed) {
                application.failed = true;
                closeSlot(slot);
                continue;
            }
            if (phase == .handoff) {
                if (incoming.window_id == slot.id and incoming.kind == 2 and (incoming.key == 'q' or incoming.key == 27)) closeAll(application);
                continue;
            }
            if (!slot.ui.initialized) slot.ui.start(&slot.state);
            slot.status = .active;
            const event = if (incoming.window_id == slot.id) incoming else std.mem.zeroes(native.Event);
            if (slot.state.config.trace and event.kind == 2) {
                var trace: [128]u8 = undefined;
                runtime.output(1, try std.fmt.bufPrint(&trace, "KEY window={d} key={d} modifiers={d}\n", .{ slot.id, event.key, event.modifiers }));
            }
            if (slot.state.config.trace and ((event.kind >= 3 and event.kind <= 9) or event.kind == 12)) {
                var trace: [256]u8 = undefined;
                runtime.output(1, try std.fmt.bufPrint(&trace, "INPUT window={d} kind={d} button={d} mouse={d} timestamp={d} x={d:.2} y={d:.2} menu={any} ignore_click={any}\n", .{ slot.id, event.kind, event.key, event.mouse_id, event.timestamp, event.x, event.y, slot.ui.menu.open, slot.ui.ignore_click }));
            }
            const effect = sessionTick(&slot.state, &slot.life, &slot.ui, event) catch |err| value: {
                output("window: {s}\n", .{@errorName(err)});
                application.failed = true;
                break :value UiEffect.close;
            };
            switch (effect) {
                .idle => {},
                .close => {
                    closeSlot(slot);
                },
                .quit_all => closeAll(application),
            }
        }
        if (native.input.take(&application.selection)) |completion| switch (completion) {
            .selected => |selection| {
                var origin: ?*Slot = null;
                var available: ?*Slot = null;
                for (&application.slots) |*slot| {
                    if (slot.status == .active and slot.id == selection.window_id) origin = slot;
                    if (slot.status == .vacant and available == null) available = slot;
                }
                if (origin) |source| {
                    if (available) |target| {
                        target.life = .{ .state = &target.state, .prepare = true };
                        const life = &target.life;
                        life.settings = source.state.controller.settings;
                        life.persist_geometry = source.life.persist_geometry;
                        life.settings.checker = source.ui.request.checker;
                        life.software = source.state.config.software;
                        life.prefetch = source.state.config.prefetch;
                        life.workers = source.state.config.workers;
                        life.trace = source.state.config.trace;
                        life.nearest = source.ui.request.nearest;
                        life.paused = !source.state.controller.playing;
                        life.filename = source.state.controller.draw_filename;
                        life.draw_actions = source.state.controller.draw_actions;
                        life.view = if (life.settings.keep_view) source.ui.request.view else .{ .mode = life.settings.fit };
                        life.catalog_options = source.state.config.catalog_options;
                        life.catalog_options.start_at = null;
                        life.catalog_options.browse = false;
                        life.selection.count = selection.count;
                        life.selection.used = selection.used;
                        @memcpy(life.selection.offsets[0..life.selection.count], selection.offsets[0..life.selection.count]);
                        @memcpy(life.selection.bytes[0..life.selection.used], selection.bytes[0..life.selection.used]);
                        life.test_opened = source.ui.open_test_requested;
                        startSlot(target, false) catch |err| {
                            output("open window: {s}\n", .{@errorName(err)});
                            source.ui.notice_text = "Could not create another window";
                            source.ui.request.revision += 1;
                            source.ui.dirty = true;
                            target.status = .vacant;
                            application.failed = true;
                            continue;
                        };
                        live += 1;
                        if (source.ui.open_test_requested) closeSlot(source);
                    } else {
                        source.ui.notice_text = "Eight windows are open; close one before opening another";
                        source.ui.request.revision += 1;
                        source.ui.dirty = true;
                        native.types.bind(&source.native);
                        application.window_test_capacity_hit = true;
                        native.window.title("Yekk — window capacity reached");
                    }
                } // A late native callback for a closed window is ignored.
            },
            .cancelled => {},
            .failed => |window_id| {
                output("native selection could not be read\n", .{});
                if (findSlot(application, window_id)) |source| {
                    source.ui.notice_text = "Could not read the native selection; Ctrl+O to retry";
                    source.ui.request.revision += 1;
                    source.ui.dirty = true;
                    native.types.bind(&source.native);
                    native.window.title("Yekk — native selection failed; Ctrl+O to retry");
                }
            },
        };
        windowTest(application) catch |err| {
            output("window lifecycle test: {s}\n", .{@errorName(err)});
            application.failed = true;
            application.window_test_stage = 255;
            closeAll(application);
        };
    }
    if (memory.report or memory.debug_enabled) output("linux cache: decodes={d}, pressure_events={d}, allocation_retries={d}, inactive_reclaimed={d}, native_retries={d}\n", .{ application.decodes, application.pressure, application.retries, application.reclaimed, application.native_retries });
    if (application.failed) return error.WindowOperationFailed;
}

fn findSlot(application: *Application, id: u32) ?*Slot {
    for (&application.slots) |*slot| if (slot.status != .vacant and slot.status != .closing and slot.id == id) return slot;
    return null;
}
fn windowTest(application: *Application) !void {
    const path = application.window_test_path orelse return;
    var active_count: usize = 0;
    var all_presented = true;
    for (&application.slots) |*slot| if (slot.status != .vacant and slot.status != .closing) {
        active_count += 1;
        all_presented = all_presented and slot.ui.initialized and slot.ui.presented > 0;
    };
    switch (application.window_test_stage) {
        0 => if (all_presented) {
            const origin = &application.slots[0];
            application.window_test_origin = origin.id;
            native.types.bind(&origin.native);
            native.input.testDrop(path.ptr);
            application.window_test_stage = 1;
        },
        1 => if (active_count == 2 and all_presented) {
            for (&application.slots) |*slot| if (slot.status == .active and slot.id != application.window_test_origin) {
                application.window_test_child = slot.id;
                native.types.bind(&slot.native);
                native.input.testKey('>');
                application.window_test_stage = 2;
                break;
            };
        },
        2 => {
            const child = findSlot(application, application.window_test_child) orelse return error.WindowTestLostChild;
            const origin = findSlot(application, application.window_test_origin) orelse return error.WindowTestLostOrigin;
            if (child.ui.request.rotation == 1 and child.ui.presented > 1) {
                if (origin.ui.request.rotation != 0) return error.WindowTestSharedView;
                native.types.bind(&origin.native);
                native.input.testClose();
                application.window_test_stage = 4;
            }
        },
        4 => if (findSlot(application, application.window_test_origin) == null and active_count == 1 and all_presented) {
            // Wait for slot retirement so reuse and a late callback exercise
            // genuinely different SDL window ids in the same startup storage.
            var retired = false;
            for (&application.slots) |*slot| if (slot.id == application.window_test_origin and slot.status != .vacant) {
                retired = true;
            };
            if (retired) return;
            native.input.testDialogWindow(path.ptr, application.window_test_origin);
            application.window_test_stage = 5;
        },
        5 => {
            if (active_count != 1) return error.WindowTestAcceptedLateCallback;
            const child = findSlot(application, application.window_test_child) orelse return error.WindowTestLostChild;
            native.types.bind(&child.native);
            native.input.testDrop(path.ptr);
            application.window_test_stage = 6;
        },
        6 => if (active_count == 2 and all_presented) {
            for (&application.slots) |*slot| if (slot.status == .active and slot.id != application.window_test_child) {
                application.window_test_base = slot.id;
            };
            if (application.window_test_base == 0 or application.window_test_base == application.window_test_origin) return error.WindowTestReusedIdentity;
            const child = findSlot(application, application.window_test_child) orelse return error.WindowTestLostChild;
            native.types.bind(&child.native);
            native.input.testClose();
            application.window_test_stage = 7;
        },
        7 => if (active_count == 1 and all_presented) {
            const base = findSlot(application, application.window_test_base) orelse return error.WindowTestLostBase;
            native.types.bind(&base.native);
            native.input.testDrop(path.ptr);
            application.window_test_last_count = active_count;
            application.window_test_stage = 8;
        },
        8 => if (all_presented and active_count > application.window_test_last_count) {
            application.window_test_last_count = active_count;
            const base = findSlot(application, application.window_test_base) orelse return error.WindowTestLostBase;
            native.types.bind(&base.native);
            native.input.testDrop(path.ptr);
            if (active_count == native.window_limit) application.window_test_stage = 9;
        },
        9 => {
            if (!application.window_test_capacity_hit) return;
            if (active_count != native.window_limit) return error.WindowTestCapacity;
            const base = findSlot(application, application.window_test_base) orelse return error.WindowTestLostBase;
            native.types.bind(&base.native);
            native.input.testKey('q');
            runtime.output(1, "WINDOWS_PASSED\n");
            application.window_test_stage = 10;
        },
        else => {},
    }
}

fn headless(state: *State) !void {
    try index(state);
    if (state.config.listing != .none) {
        if (state.config.listing == .metadata) runtime.output(1, "NUM\tFORMAT\tWIDTH\tHEIGHT\tPIXELS\tSIZE\tFILENAME\n");
        for (state.catalog.entries[0..state.catalog.count], 0..) |entry, position| {
            if (state.config.listing == .metadata) {
                var metadata: native.Metadata = undefined;
                if (native.image.probe(entry.path.ptr, &metadata) != 0) return error.MetadataFailed;
                var line: [512]u8 = undefined;
                runtime.output(1, try std.fmt.bufPrint(&line, "{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t", .{ position + 1, std.mem.sliceTo(&metadata.format, 0), metadata.width, metadata.height, @as(u64, metadata.width) * metadata.height, entry.bytes }));
            }
            runtime.output(1, entry.path);
            runtime.output(1, "\n");
        }
        try saveFilelist(state);
        return;
    }
    if (state.catalog.count != 1) return error.BenchmarkRequiresOneImage;
    const start = runtime.now();
    const image = try decode(state.catalog.entries[0].path);
    defer image.destroy();
    const decoded = runtime.now();
    var frame = native.Frame{};
    defer native.render.free(&frame);
    const scale = core.scaleFor(.fit, .{ .width = @floatFromInt(image.pixels.width), .height = @floatFromInt(image.pixels.height) }, .{ .width = 1100, .height = 760 });
    if (native.render.prepare(&image.pixels, .{ .width = 1100, .height = 760, .scale = scale, .fitted = true }, "", false, &frame) != 0) return error.RenderFailed;
    const rendered = runtime.now();
    if (state.config.snapshot) |path| if (native.render.save(&frame, path.ptr) != 0) return error.SnapshotFailed;
    var buffer: [1024]u8 = undefined;
    runtime.output(1, try std.fmt.bufPrint(&buffer, "{{\"backend\":\"libvips\",\"width\":{d},\"height\":{d},\"bits\":{d},\"decoded_bytes\":{d},\"decode_ms\":{d:.3},\"fit_ms\":{d:.3}}}\n", .{ image.pixels.width, image.pixels.height, image.pixels.bits, image.pixels.bytes, (decoded - start) * 1000, (rendered - decoded) * 1000 }));
}
pub fn run(args: []const [*:0]const u8) !void {
    const application = try memory.allocator().create(Application);
    defer memory.allocator().destroy(application);
    for (&application.slots) |*slot| {
        slot.status = .vacant;
        slot.id = 0;
    }
    application.failed = false;
    application.decodes = 0;
    application.pressure = 0;
    application.retries = 0;
    application.native_retries = 0;
    application.reclaimed = 0;
    const state = &application.slots[0].state;
    initialize(state);
    defer native.render.free(&state.result.pixels);
    const proceed = parse(state, args) catch |err| {
        output("arguments: {s}\n", .{@errorName(err)});
        return error.InvalidArguments;
    };
    if (!proceed) return;
    if (state.config.listing == .paths) return headless(state);
    configureController(state);
    if (native.image.init(state.config.workers) != 0) return error.DecoderInitFailed;
    defer native.shutdown();
    if (state.config.formats) {
        native.image.formats();
        return;
    }
    if (state.config.benchmark or state.config.listing != .none) try headless(state) else {
        application.geometry = std.mem.zeroes(native.Geometry);
        const cfg = &state.config;
        application.persist_geometry = cfg.geometry == null and cfg.test_keys == null and cfg.test_open == null and cfg.window_test == null and
            !cfg.smoke and !cfg.smoke_hook and !cfg.smoke_reload and !cfg.smoke_resize and !cfg.watch_test and !cfg.recovery_test and !cfg.native_recovery_test and cfg.stress == 0;
        if (application.persist_geometry) native.window.load(&application.geometry);
        try viewer(application);
    }
    if (state.save_failed.load(.acquire)) return error.FilelistWriteFailed;
}

var test_initialized = false;
fn initTestDecoder() !void {
    if (!test_initialized) {
        if (native.image.init(2) != 0) return error.DecoderInitFailed;
        test_initialized = true;
    }
}

test "Linux decode preserves 16-bit samples and all TIFF orientations" {
    try initTestDecoder();
    const source = [_][3]u16{ .{ 65535, 0, 0 }, .{ 0, 65535, 0 }, .{ 0, 0, 65535 }, .{ 65535, 65535, 65535 }, .{ 0, 0, 0 }, .{ 0x1234, 0xabcd, 0x00ff } };
    const maps = [_][6]usize{ .{ 0, 1, 2, 3, 4, 5 }, .{ 2, 1, 0, 5, 4, 3 }, .{ 5, 4, 3, 2, 1, 0 }, .{ 3, 4, 5, 0, 1, 2 }, .{ 0, 3, 1, 4, 2, 5 }, .{ 3, 0, 4, 1, 5, 2 }, .{ 5, 2, 4, 1, 3, 0 }, .{ 2, 5, 1, 4, 0, 3 } };
    for (maps, 1..) |map, orientation| {
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "tests/fixtures/rgb16-orientation{d}.tif", .{orientation}, 0);
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decodeWithAllocator(path, allocator.allocator());
        try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
        try std.testing.expectEqual(@as(u32, 16), image.pixels.bits);
        try std.testing.expectEqual(@as(u32, if (orientation >= 5) 2 else 3), image.pixels.width);
        for (map, 0..) |original, i| {
            var pixel: [4]u16 = undefined;
            try std.testing.expectEqual(@as(c_int, 0), native.image.pixel(&image.pixels, @intCast(i % image.pixels.width), @intCast(i / image.pixels.width), &pixel));
            try std.testing.expectEqualSlices(u16, &source[original], pixel[0..3]);
            try std.testing.expectEqual(@as(u16, 65535), pixel[3]);
        }
        image.destroy();
        try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    }
}

test "Linux decoder rejects incomplete files and unwinds allocation failure" {
    try initTestDecoder();
    inline for (.{ "tests/fixtures/jpeg-incomplete-4.jpg", "tests/fixtures/jpeg-incomplete-64.jpg", "tests/fixtures/truncated.png", "tests/fixtures/rgb16-bad-second-strip.tif", "tests/fixtures/huge.png" }) |path| {
        if (decodeWithAllocator(path, std.testing.allocator)) |image| {
            image.destroy();
            return error.AcceptedDamagedImage;
        } else |_| {}
    }
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decodeWithAllocator("tests/fixtures/alpha.content", allocator.allocator()));
}

test "Linux JPEG variants and grayscale preserve dimensions and precision" {
    try initTestDecoder();
    inline for (.{ "tests/fixtures/jpeg-trailer.jpg", "tests/fixtures/jpeg-progressive.jpg", "tests/fixtures/jpeg-boundary.jpg", "tests/fixtures/orientation6.jpg", "tests/fixtures/gray16.png", "tests/fixtures/rgb16-tiled-big.tif" }) |path| {
        const image = try decodeWithAllocator(path, std.testing.allocator);
        defer image.destroy();
        if (std.mem.endsWith(u8, path, "orientation6.jpg")) {
            try std.testing.expectEqual(@as(u32, 2), image.pixels.width);
            try std.testing.expectEqual(@as(u32, 3), image.pixels.height);
        }
        if (std.mem.endsWith(u8, path, "gray16.png")) try std.testing.expectEqual(@as(u32, 16), image.pixels.bits);
    }
}

test "untrusted native loaders remain blocked behind the shared PNM reader" {
    try initTestDecoder();
    const c = native.types.c;
    inline for (.{ "tests/fixtures/pnm-p6-8.ppm", "tests/fixtures/jxl-rgb8.jxl" }) |path| {
        if (c.vips_image_new_from_file(path, @as(?*anyopaque, null))) |image| {
            c.g_object_unref(image);
            return error.UntrustedReaderEnabled;
        }
        c.vips_error_clear();
    }
}

test "SDL BMP decoding preserves palette, RLE, orientation and 565 pixels" {
    try initTestDecoder();
    inline for (.{ "rgb24", "topdown", "rgb565", "pal8", "pal4", "pal1", "rle8", "rle4" }) |kind| {
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decodeWithAllocator("tests/fixtures/bmp-" ++ kind ++ ".bmp", allocator.allocator());
        var pixel: [4]u16 = undefined;
        try std.testing.expectEqual(@as(c_int, 0), native.image.pixel(&image.pixels, 0, 0, &pixel));
        try std.testing.expectEqualSlices(u16, &.{ 65535, 0, 0, 65535 }, &pixel);
        try std.testing.expectEqual(@as(u32, 3), image.pixels.width);
        try std.testing.expectEqual(@as(u32, 2), image.pixels.height);
        image.destroy();
        try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
        try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    }
    inline for (.{ "truncated", "linked-profile", "invalid-profile" }) |kind| {
        if (decodeWithAllocator("tests/fixtures/bmp-" ++ kind ++ ".bmp", std.testing.allocator)) |image| {
            image.destroy();
            return error.AcceptedInvalidBmp;
        } else |_| {}
    }
}

test "decoder paths keep brackets literal and metadata probing rejects pipes" {
    try initTestDecoder();
    var path: ["/tmp/yekk-path-XXXXXX".len:0]u8 = "/tmp/yekk-path-XXXXXX".*;
    const fd = posix.mkstemp(&path);
    try std.testing.expect(fd >= 0);
    _ = posix.close(fd);
    defer _ = posix.unlink(&path);
    var target: [4096]u8 = undefined;
    try std.testing.expect(posix.realpath("tests/fixtures/alpha.content", &target) != null);
    var literal: [4096]u8 = undefined;
    const named = try std.fmt.bufPrintSentinel(&literal, "{s}[page=999999]", .{std.mem.span(@as([*:0]const u8, &path))}, 0);
    try std.testing.expectEqual(@as(c_int, 0), posix.symlink(@ptrCast(&target), named.ptr));
    defer _ = posix.unlink(named.ptr);
    const image = try decodeWithAllocator(named, std.testing.allocator);
    defer image.destroy();
    try std.testing.expectEqual(@as(u32, 3), image.pixels.width);
    var metadata: native.Metadata = .{};
    try std.testing.expectEqual(@as(c_int, 0), native.image.probe(named.ptr, &metadata));
    try std.testing.expectEqual(@as(u32, 3), metadata.width);
    _ = posix.unlink(&path);
    try std.testing.expectEqual(@as(c_int, 0), posix.mkfifo(&path, 0o600));
    try std.testing.expectEqual(@as(c_int, -1), native.image.probe(&path, &metadata));
}

test "shared PNM pixels and header probing retain native sample precision" {
    try initTestDecoder();
    inline for (.{ "p1.pbm", "p4.pbm", "p2-8.pgm", "p2-16.pgm", "p5-8.pgm", "p5-16.pgm", "p3-8.ppm", "p3-16.ppm", "p6-8.ppm", "p6-16.ppm" }) |name| {
        const path = "tests/fixtures/pnm-" ++ name;
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decodeWithAllocator(path, allocator.allocator());
        try std.testing.expectEqual(@as(u32, 3), image.pixels.width);
        try std.testing.expectEqual(@as(u32, 2), image.pixels.height);
        var metadata: native.Metadata = .{};
        try std.testing.expectEqual(@as(c_int, 0), native.image.probe(path, &metadata));
        try std.testing.expectEqual(metadata.bits, image.pixels.bits);
        if (metadata.bits == 16 and std.mem.endsWith(u8, name, ".ppm")) {
            var rgba: [4]u16 = undefined;
            try std.testing.expectEqual(@as(c_int, 0), native.image.pixel(&image.pixels, 0, 0, &rgba));
            try std.testing.expectEqualSlices(u16, &.{ 0x1234, 0xabcd, 0xff, 65535 }, &rgba);
        }
        image.destroy();
        try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
        try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    }
}

test "repeated native source loads release their file descriptors" {
    try initTestDecoder();
    const count = struct {
        fn open() !usize {
            const directory = runtime.files.opendir("/proc/self/fd") orelse return error.FdDirectoryUnavailable;
            defer _ = posix.closedir(directory);
            var result: usize = 0;
            while (runtime.files.readdir(directory) != null) result += 1;
            return result;
        }
    }.open;
    const warmup = try decodeWithAllocator("tests/fixtures/alpha.content", std.testing.allocator);
    warmup.destroy();
    const before = try count();
    for (0..32) |_| {
        const image = try decodeWithAllocator("tests/fixtures/alpha.content", std.testing.allocator);
        image.destroy();
        var metadata: native.Metadata = .{};
        try std.testing.expectEqual(@as(c_int, 0), native.image.probe("tests/fixtures/alpha.content", &metadata));
    }
    try std.testing.expectEqual(before, try count());
}

test "Linux viewport pans reuse full pixels and fit overview" {
    try initTestDecoder();
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const image = try decodeWithAllocator("tests/fixtures/detail-wide.png", allocator.allocator());
    defer image.destroy();
    var first = native.Frame{};
    defer native.render.free(&first);
    try std.testing.expectEqual(@as(c_int, 0), native.render.render(&image.pixels, 64, 64, 0.1, 0, 0, 0, 0, &first));
    const overview = image.pixels.levels[3];
    try std.testing.expect(overview != null);
    var second = native.Frame{};
    defer native.render.free(&second);
    try std.testing.expectEqual(@as(c_int, 0), native.render.render(&image.pixels, 64, 64, 0.1, -10, 0, 0, 0, &second));
    try std.testing.expectEqual(overview, image.pixels.levels[3]);
    var zoomed: native.Frame = .{};
    defer native.render.free(&zoomed);
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, .{ .width = 64, .height = 64, .scale = 0.125 }, "", false, &zoomed));
    try std.testing.expectEqual(overview, image.pixels.levels[3]);
    try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
    try std.testing.expectEqual(@as(c_int, 0), native.render.finish(&second, "", 0));
    try std.testing.expectEqual(@as(usize, 64 * 64 * 4), second.bytes);
}

test "fit cache survives actual-size views and pressure retirement without invalidating frames" {
    try initTestDecoder();
    const image = try decodeWithAllocator("tests/fixtures/detail-wide.png", std.testing.allocator);
    defer image.destroy();
    var first: native.Frame = .{};
    defer native.render.free(&first);
    const fit: native.render.View = .{ .width = 64, .height = 64, .scale = 0.1, .fitted = true };
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, fit, "", false, &first));
    const pixels = first.pixels;
    var partial: native.Frame = .{};
    defer native.render.free(&partial);
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, .{ .width = 64, .height = 64, .scale = 0.125 }, "", false, &partial));
    var actual: native.Frame = .{};
    defer native.render.free(&actual);
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, .{ .width = 64, .height = 64, .scale = 1 }, "", false, &actual));
    var returned: native.Frame = .{};
    defer native.render.free(&returned);
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, fit, "", false, &returned));
    try std.testing.expectEqual(pixels, returned.pixels);
    const before = std.hash.XxHash64.hash(0, native.types.bytes(pixels, first.bytes));
    native.image.dropDerived(&image.pixels);
    try std.testing.expect(image.pixels.preview == null);
    try std.testing.expectEqual(before, std.hash.XxHash64.hash(0, native.types.bytes(pixels, first.bytes)));
    var changed: native.Frame = .{};
    defer native.render.free(&changed);
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, fit, "", true, &changed));
    try std.testing.expect(changed.pixels != pixels);
}

test "cached frame leases retain fit pixels and the one source allocation through retirement" {
    try initTestDecoder();
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const image = try decodeWithAllocator("tests/fixtures/detail-wide.png", allocator.allocator());
    var retired: RetiredFrames = .{};
    defer retired.free();
    const fit: FrameKey = .{ .view = .{ .width = 64, .height = 64, .scale = 0.1, .fitted = true }, .checker = false };
    var pixels: native.Frame = .{};
    defer native.render.free(&pixels);
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, fit.view, "", false, &pixels));
    var first = image.storeFrame(&pixels, fit, .overview, &retired).?;
    defer native.render.free(&first);
    const original = first.pixels;
    const hash = std.hash.XxHash64.hash(0, native.types.bytes(first.pixels, first.bytes));
    const zoom: FrameKey = .{ .view = .{ .width = 64, .height = 64, .scale = 0.125 }, .checker = false };
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, zoom.view, "", false, &pixels));
    var partial = image.storeFrame(&pixels, zoom, .interaction, &retired).?;
    defer native.render.free(&partial);
    var returned = image.borrowFrame(fit, .overview).?;
    defer native.render.free(&returned);
    try std.testing.expectEqual(original, returned.pixels);
    image.clearFrames(&retired);
    native.image.dropDerived(&image.pixels);
    image.destroy(); // The frame leases alone now pin the source record.
    try std.testing.expectEqual(hash, std.hash.XxHash64.hash(0, native.types.bytes(returned.pixels, returned.bytes)));
    try std.testing.expect(allocator.allocated_bytes > allocator.freed_bytes);
    native.render.free(&first);
    native.render.free(&partial);
    native.render.free(&returned);
    try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "fused output matches the linear reference across profiles, transparency and geometry" {
    try initTestDecoder();
    var context: native.Window = .{};
    native.types.bind(&context);
    defer native.types.bind(null);
    defer native.render.contextFinish();
    inline for (.{ "tests/fixtures/alpha.content", "tests/fixtures/rgb16-orientation1.tif", "tests/fixtures/gray16.png" }) |path| {
        const image = try decodeWithAllocator(path, std.testing.allocator);
        defer image.destroy();
        for ([_]f64{ 0, 1.8 }) |gamma| {
            try std.testing.expectEqual(@as(c_int, 0), native.render.testOutput(1, gamma));
            try std.testing.expectEqual(@as(c_int, 0), native.render.begin());
            defer native.render.end();
            for ([_]f64{ 0.125, 1, 3.25 }) |scale| for ([_]c_uint{ 0, 1, 12 }) |transform| for ([_]bool{ false, true }) |checker| for ([_][2]f64{ .{ 1, 0 }, .{ -1000, -1000 }, .{ -1.25, 2.5 }, .{ 20, 20 } }) |offset| {
                var reference: native.Frame = .{};
                defer native.render.free(&reference);
                var prepared: native.Frame = .{};
                defer native.render.free(&prepared);
                try std.testing.expectEqual(@as(c_int, 0), native.render.render(&image.pixels, 17, 13, scale, offset[0], offset[1], 0, transform, &reference));
                try std.testing.expectEqual(@as(c_int, 0), native.render.finish(&reference, "", @intFromBool(checker)));
                try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, .{ .width = 17, .height = 13, .scale = scale, .x = offset[0], .y = offset[1], .transform = transform }, "", checker, &prepared));
                try std.testing.expectEqualSlices(u8, native.types.bytes(reference.pixels, reference.bytes), native.types.bytes(prepared.pixels, prepared.bytes));
            };
        }
    }
}

test "reusable viewport buffers preserve simultaneously published frames" {
    try initTestDecoder();
    var context: native.Window = .{};
    native.types.bind(&context);
    defer native.types.bind(null);
    defer native.render.contextFinish();
    const image = try decodeWithAllocator("tests/fixtures/rgb16-orientation1.tif", std.testing.allocator);
    defer image.destroy();
    var frames: [4]native.Frame = @splat(.{});
    defer for (&frames) |*frame| native.render.free(frame);
    for (&frames, 0..) |*frame, i| try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, .{ .width = 8, .height = 8, .scale = 1, .x = @floatFromInt(i) }, "", false, frame));
    for (frames[0..3]) |frame| try std.testing.expect(frame.storage == .reusable);
    try std.testing.expect(frames[3].storage == .owned);
    const before = std.hash.XxHash64.hash(0, native.types.bytes(frames[0].pixels, frames[0].bytes));
    const reusable = frames[1].pixels;
    native.render.free(&frames[1]);
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, .{ .width = 8, .height = 8, .scale = 1, .x = 4 }, "", false, &frames[1]));
    try std.testing.expectEqual(reusable, frames[1].pixels);
    try std.testing.expectEqual(before, std.hash.XxHash64.hash(0, native.types.bytes(frames[0].pixels, frames[0].bytes)));
}

test "native graph references pin the single owned image allocation" {
    try initTestDecoder();
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const image = try decodeWithAllocator("tests/fixtures/rgb16-orientation1.tif", allocator.allocator());
    const c = native.types.c;
    const source: *c.VipsImage = @ptrCast(@alignCast(c.g_object_ref(image.pixels.image).?));
    image.destroy();
    try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), allocator.freed_bytes);
    var borrowed: native.Image = .{ .image = source, .width = 3, .height = 2, .bits = 16 };
    var sample: [4]u16 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), native.image.pixel(&borrowed, 0, 0, &sample));
    try std.testing.expectEqualSlices(u16, &.{ 65535, 0, 0, 65535 }, &sample);
    c.g_object_unref(source);
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "direct opaque conversion matches linear reference for every 16-bit sample" {
    try initTestDecoder();
    const c = native.types.c;
    const values = try std.testing.allocator.alloc([4]u16, 65536);
    defer std.testing.allocator.free(values);
    for (values, 0..) |*pixel, i| pixel.* = .{ @intCast(i), @intCast(65535 - i), @truncate(i *% 59341), 65535 };
    const source = c.vips_image_new_from_memory(values.ptr, values.len * 8, 65536, 1, 4, c.VIPS_FORMAT_USHORT) orelse return error.OutOfMemory;
    source.*.Type = c.VIPS_INTERPRETATION_RGB16;
    var image: native.Image = .{ .image = source, .width = 65536, .height = 1, .bits = 16, .opaque_source = true };
    defer native.image.free(&image);
    var reference: native.Frame = .{};
    defer native.render.free(&reference);
    var prepared: native.Frame = .{};
    defer native.render.free(&prepared);
    try std.testing.expectEqual(@as(c_int, 0), native.render.render(&image, 65536, 1, 1, 0, 0, 0, 0, &reference));
    try std.testing.expectEqual(@as(c_int, 0), native.render.finish(&reference, "", 0));
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image, .{ .width = 65536, .height = 1, .scale = 1 }, "", false, &prepared));
    try std.testing.expectEqualSlices(u8, native.types.bytes(reference.pixels, reference.bytes), native.types.bytes(prepared.pixels, prepared.bytes));
}

test "Linux user transforms preserve source samples and use oriented viewport pixels" {
    try initTestDecoder();
    const image = try decodeWithAllocator("tests/fixtures/rgb16-orientation1.tif", std.testing.allocator);
    defer image.destroy();
    const source = [_][3]u8{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 255, 255, 255 }, .{ 0, 0, 0 }, .{ 0x12, 0xab, 1 } };
    const transforms = [_]c_uint{ 1, 4, 8, 5 };
    const maps = [_][6]usize{ .{ 3, 0, 4, 1, 5, 2 }, .{ 2, 1, 0, 5, 4, 3 }, .{ 3, 4, 5, 0, 1, 2 }, .{ 0, 3, 1, 4, 2, 5 } };
    for (transforms, maps) |transform, map| {
        var frame = native.Frame{};
        defer native.render.free(&frame);
        try std.testing.expectEqual(@as(c_int, 0), native.render.render(&image.pixels, if (transform & 1 != 0) 2 else 3, if (transform & 1 != 0) 3 else 2, 1, 0, 0, 1, transform, &frame));
        try std.testing.expectEqual(@as(c_int, 0), native.render.finish(&frame, "", 0));
        const pixels: [*]const u8 = @ptrCast(frame.pixels.?);
        for (map, 0..) |original, i| {
            try std.testing.expectEqualSlices(u8, &source[original], pixels[i * 4 ..][0..3]);
            try std.testing.expectEqual(@as(u8, 255), pixels[i * 4 + 3]);
        }
    }
    var pixel: [4]u16 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), native.image.pixel(&image.pixels, 2, 1, &pixel));
    try std.testing.expectEqualSlices(u16, &.{ 0x1234, 0xabcd, 0x00ff, 65535 }, &pixel);
}

test "queued hooks reject a source identity different from the displayed snapshot" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    var job: HookJob = .{};
    try job.template.set("exit 77");
    job.snapshot.path = "tests/fixtures/rgb16-orientation6.tif";
    job.source_stamp = Stamp.read("tests/fixtures/rgb16-orientation1.tif");
    try std.testing.expectError(error.SourceChanged, executeHook(state, &job));
}

test "native dialog callback publishes complete paths and cancellation without session pointers" {
    const selection = try std.testing.allocator.create(native.Selection);
    defer std.testing.allocator.destroy(selection);
    const thread = try std.Thread.spawn(.{}, struct {
        fn publish() void {
            native.input.testDialog("/tmp/photo\n雪.tif", 1);
        }
    }.publish, .{});
    thread.join();
    try std.testing.expectEqual(selection, native.input.take(selection).?.selected);
    try std.testing.expectEqual(@as(u32, 1), selection.count);
    try std.testing.expectEqualStrings("/tmp/photo\n雪.tif", std.mem.sliceTo(&selection.bytes, 0));
    try std.testing.expect(native.input.take(selection) == null);
    native.input.testDialog(null, 0);
    try std.testing.expectEqual(@as(u32, 0), native.input.take(selection).?.cancelled);
    native.input.testDialog(null, -1);
    try std.testing.expectEqual(@as(u32, 0), native.input.take(selection).?.failed);
    const oversized = try std.testing.allocator.alloc(u8, 1048577);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    oversized[oversized.len - 1] = 0;
    native.input.testDialog(@ptrCast(oversized.ptr), 1);
    try std.testing.expectEqual(@as(u32, 0), native.input.take(selection).?.failed);
}

test "desktop actions reject a different path identity before calling Trash" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);
    state.stop = .init(false);
    var job: HookJob = .{ .kind = .trash, .snapshot = .{ .path = "tests/fixtures/rgb16-orientation1.tif" }, .source_stamp = Stamp.read("tests/fixtures/rgb16-orientation1.tif"), .link_stamp = .{} };
    try std.testing.expectError(error.SourceChanged, auxiliary(state, &job));
}

test "coordinator joins its workers before retiring image owners" {
    try initTestDecoder();
    const application = try std.testing.allocator.create(Application);
    defer std.testing.allocator.destroy(application);
    const state = &application.slots[0].state;
    initialize(state);
    state.config.paths[0] = "tests/fixtures/rgb16-orientation1.tif";
    state.config.count = 1;
    state.config.prefetch = false;
    state.request.width = 3;
    state.request.height = 3;
    configureController(state);
    const life = &application.slots[0].life;
    life.* = .{ .state = state, .width = 3, .height = 3, .settings = state.config.settings };
    const thread = try std.Thread.spawn(.{}, coordinate, .{life});
    var joined = false;
    defer if (!joined) {
        life.quit.store(true, .release);
        thread.join();
    };
    const deadline = runtime.now() + 30;
    while (true) {
        if (runtime.now() > deadline) return error.CoordinatorTestTimedOut;
        if (life.phase.load(.acquire) == .active and state.indexed.load(.acquire)) {
            state.lock.lock();
            const ready = state.entries[0].image != null and state.result.pixels.pixels != null;
            state.lock.unlock();
            if (ready) break;
        }
        _ = posix.poll(null, 0, 5);
    }
    try std.testing.expectEqual(@as(usize, 1), state.catalog.count);
    life.quit.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(state.entries[0].image == null);
    try std.testing.expect(state.result.pixels.pixels == null);
}

fn testRenderedPixel(image: *Image, x: f64) ![4]u8 {
    try std.testing.expectEqual(@as(c_int, 0), native.render.begin());
    defer native.render.end();
    var frame = native.Frame{};
    defer native.render.free(&frame);
    try std.testing.expectEqual(@as(c_int, 0), native.render.prepare(&image.pixels, .{ .width = 1, .height = 1, .scale = 1, .x = x }, "", false, &frame));
    const pixels: [*]const u8 = @ptrCast(frame.pixels.?);
    return pixels[0..4].*;
}
test "filtering mixes linear light and premultiplied alpha without dark or coloured fringes" {
    try initTestDecoder();
    const edges = try decodeWithAllocator("tests/fixtures/linear-edges.png", std.testing.allocator);
    defer edges.destroy();
    const grey = try testRenderedPixel(edges, -0.5);
    try std.testing.expect(grey[0] >= 185 and grey[0] <= 190);
    try std.testing.expectEqual(grey[0], grey[1]);
    try std.testing.expectEqual(grey[0], grey[2]);
    const alpha = try decodeWithAllocator("tests/fixtures/linear-alpha.png", std.testing.allocator);
    defer alpha.destroy();
    const red = try testRenderedPixel(alpha, -0.5);
    try std.testing.expect(red[0] >= 185 and red[0] <= 195);
    try std.testing.expect(red[2] < 30);
    try std.testing.expectEqual(@as(u8, 255), red[3]);
}

test "magnification keeps edge samples opaque and clips the projected image bounds" {
    try initTestDecoder();
    const image = try decodeWithAllocator("tests/fixtures/linear-gray.png", std.testing.allocator);
    defer image.destroy();
    try std.testing.expectEqual(@as(c_int, 0), native.render.testOutput(1, 0));
    try std.testing.expectEqual(@as(c_int, 0), native.render.begin());
    defer native.render.end();
    var frame = native.Frame{};
    defer native.render.free(&frame);
    try std.testing.expectEqual(@as(c_int, 0), native.render.render(&image.pixels, 200, 100, 100, 0, 0, 0, 0, &frame));
    const linear: [*]const f32 = @ptrCast(@alignCast(frame.pixels.?));
    for ([_]usize{ 0, 50, 99 }) |x| try std.testing.expectEqual(@as(f32, 1), linear[(50 * 200 + x) * 4 + 3]);
    try std.testing.expectEqual(@as(f32, 0), linear[(50 * 200 + 100) * 4 + 3]);
    try std.testing.expectEqual(@as(c_int, 0), native.render.finish(&frame, "", 0));
    const pixels: [*]const u8 = @ptrCast(frame.pixels.?);
    for ([_]usize{ 0, 50, 99 }) |x| try std.testing.expectEqual(@as(u8, 128), pixels[(50 * 200 + x) * 4]);
}
test "display profile changes retire old transforms, reject stale frames and fall back from invalid profiles" {
    try initTestDecoder();
    const image = try decodeWithAllocator("tests/fixtures/linear-gray.png", std.testing.allocator);
    defer image.destroy();
    try std.testing.expectEqual(@as(c_int, 0), native.render.testOutput(1, 1));
    const managed = try testRenderedPixel(image, 0);
    try std.testing.expect(managed[0] >= 52 and managed[0] <= 58);
    var stale = native.Frame{};
    try std.testing.expectEqual(@as(c_int, 0), native.render.begin());
    try std.testing.expectEqual(@as(c_int, 1), native.render.testOutput(2, 0));
    try std.testing.expectEqual(@as(c_int, 0), native.render.render(&image.pixels, 1, 1, 1, 0, 0, 1, 0, &stale));
    native.render.end();
    defer native.render.free(&stale);
    try std.testing.expectEqual(@as(c_int, 0), native.render.testOutput(2, -1));
    try std.testing.expectEqual(@as(c_int, 0), native.render.frameCurrent(&stale));
    const fallback = try testRenderedPixel(image, 0);
    try std.testing.expectEqual(@as(u8, 128), fallback[0]);
    try std.testing.expectEqual(@as(c_int, 0), native.render.testOutput(1, 0));
    _ = try testRenderedPixel(image, 0);
}
test "viewport retirement preserves ownership under saturation and ring reuse" {
    var queue: FrameRetirement = .{};
    var storage: [8]u8 = undefined;
    for (0..3) |slot_index| {
        var frame = native.Frame{};
        frame.pixels = &storage[slot_index];
        try std.testing.expect(queue.push(&frame));
        try std.testing.expect(frame.pixels == null);
    }
    var waiting = native.Frame{};
    waiting.pixels = &storage[3];
    try std.testing.expect(!queue.push(&waiting));
    try std.testing.expectEqual(@as(?*anyopaque, &storage[3]), waiting.pixels);
    for (0..3) |slot_index| try std.testing.expectEqual(@as(?*anyopaque, &storage[slot_index]), queue.pop().?.pixels);
    try std.testing.expect(queue.pop() == null);
    try std.testing.expect(queue.push(&waiting));
    try std.testing.expectEqual(@as(?*anyopaque, &storage[3]), queue.pop().?.pixels);
    try std.testing.expect(queue.pop() == null);
}

test "slideshow close retires an acquired result without releasing it on the UI" {
    for ([_]bool{ false, true }) |saturated| {
        const state = try std.testing.allocator.create(State);
        defer std.testing.allocator.destroy(state);
        initialize(state);
        state.catalog.count = 1;
        configureController(state);
        state.controller.start(1, 0, &state.request);
        state.controller.playing = true;
        state.controller.settings.interval = 1;
        state.controller.settings.on_last = .quit;
        state.controller.deadline = 0;
        var released: usize = 0;
        var pixel: u8 = 0;
        const frame: native.Frame = .{ .pixels = &pixel, .storage = .{ .borrowed = .{
            .context = &released,
            .release = struct {
                fn release(context: *anyopaque) void {
                    const counter: *usize = @ptrCast(@alignCast(context));
                    counter.* += 1;
                }
            }.release,
        } } };
        if (saturated) for (0..3) |_| {
            var queued = frame;
            try std.testing.expect(state.retirement.push(&queued));
        };
        state.result.pixels = frame;
        var ui: Ui = .{ .ready = true, .request = state.request };
        var life: Life = .{ .state = state };
        try std.testing.expectEqual(UiEffect.close, try sessionTick(state, &life, &ui, std.mem.zeroes(native.Event)));
        try std.testing.expect(state.result.pixels.pixels == null);
        try std.testing.expectEqual(@as(usize, 0), released);
        state.retirement.collect();
        native.render.free(&ui.retiring);
        try std.testing.expectEqual(@as(usize, if (saturated) 4 else 1), released);
    }
}

test "embedded P3 and gray ICC profiles preserve raw samples and render without gamut clipping" {
    try initTestDecoder();
    var path: [@sizeOf(@TypeOf("/tmp/yekk-profile-XXXXXX".*)) - 1:0]u8 = "/tmp/yekk-profile-XXXXXX".*;
    const fd = posix.mkstemp(@ptrCast(&path));
    try std.testing.expect(fd >= 0);
    _ = posix.close(fd);
    defer _ = posix.unlink(@ptrCast(&path));
    const filename: [:0]const u8 = path[0..path.len :0];
    try std.testing.expectEqual(@as(c_int, 0), native.image.testProfilePng("tests/fixtures/rgb16-orientation1.tif", filename.ptr, 0));
    const p3 = try decodeWithAllocator(filename, std.testing.allocator);
    defer p3.destroy();
    var original: [4]u16 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), native.image.pixel(&p3.pixels, 1, 0, &original));
    try std.testing.expectEqualSlices(u16, &.{ 0, 65535, 0, 65535 }, &original);
    try std.testing.expectEqual(@as(c_int, 0), native.render.testOutput(1, 0));
    try std.testing.expectEqual(@as(c_int, 0), native.render.begin());
    var frame = native.Frame{};
    defer native.render.free(&frame);
    const status = native.render.render(&p3.pixels, 3, 2, 1, 0, 0, 1, 0, &frame);
    native.render.end();
    try std.testing.expectEqual(@as(c_int, 0), status);
    const values: [*]const f32 = @ptrCast(@alignCast(frame.pixels.?));
    try std.testing.expect(values[4] < -0.1);
    try std.testing.expect(values[5] > 1);
    try std.testing.expectEqual(@as(c_int, 0), native.render.testOutput(1, 0));
    try std.testing.expectEqual(@as(c_int, 0), native.image.testProfilePng("tests/fixtures/linear-gray.png", filename.ptr, 1));
    const gray = try decodeWithAllocator(filename, std.testing.allocator);
    defer gray.destroy();
    const displayed = try testRenderedPixel(gray, 0);
    try std.testing.expect(displayed[0] >= 185 and displayed[0] <= 190);
}

test "HDR and floating source variants are rejected" {
    try initTestDecoder();
    try std.testing.expectError(error.DecodeFailed, decodeWithAllocator("tests/fixtures/linear-hdr.hdr", std.testing.allocator));
    try std.testing.expectError(error.DecodeFailed, decodeWithAllocator("tests/fixtures/linear-gray.pfm", std.testing.allocator));
}

test "direct JPEG XL preserves precision, alpha, orientation and one owned slab" {
    try initTestDecoder();
    inline for (.{ .{ "rgb8", "pnm-p6-8.ppm" }, .{ "rgb8-raw", "pnm-p6-8.ppm" }, .{ "rgb16", "pnm-p6-16.ppm" }, .{ "gray16", "pnm-p5-16.pgm" }, .{ "alpha", "alpha.content" }, .{ "orientation6", "jxl-orientation6-reference.ppm" } }) |sample| {
        const path = "tests/fixtures/jxl-" ++ sample[0] ++ ".jxl";
        var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const image = try decodeWithAllocator(path, allocator.allocator());
        var owned = true;
        defer if (owned) image.destroy();
        const expected = try decodeWithAllocator("tests/fixtures/" ++ sample[1], std.testing.allocator);
        defer expected.destroy();
        try std.testing.expectEqual(expected.pixels.width, image.pixels.width);
        try std.testing.expectEqual(expected.pixels.height, image.pixels.height);
        try std.testing.expectEqual(expected.pixels.bits, image.pixels.bits);
        var metadata: native.Metadata = .{};
        try std.testing.expectEqual(@as(c_int, 0), native.image.probe(path, &metadata));
        try std.testing.expectEqual(image.pixels.width, metadata.width);
        try std.testing.expectEqual(image.pixels.height, metadata.height);
        try std.testing.expectEqual(image.pixels.bits, metadata.bits);
        var actual: [4]u16 = undefined;
        var reference: [4]u16 = undefined;
        for (0..image.pixels.height) |y| for (0..image.pixels.width) |x| {
            try std.testing.expectEqual(@as(c_int, 0), native.image.pixel(&image.pixels, @intCast(x), @intCast(y), &actual));
            try std.testing.expectEqual(@as(c_int, 0), native.image.pixel(&expected.pixels, @intCast(x), @intCast(y), &reference));
            try std.testing.expectEqualSlices(u16, &reference, &actual);
        };
        {
            var frame: native.Frame = .{};
            defer native.render.free(&frame);
            try std.testing.expectEqual(@as(c_int, 0), native.render.render(&image.pixels, 8, 8, 1, 0, 0, 1, 0, &frame));
        }
        image.destroy();
        owned = false;
        try std.testing.expectEqual(@as(usize, 1), allocator.alloc_index);
        try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    }
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decodeWithAllocator("tests/fixtures/jxl-rgb8.jxl", failure.allocator()));
    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, decodeScheduled("tests/fixtures/jxl-rgb8.jxl", std.testing.allocator, .{ .cancel = &cancel }));
}
