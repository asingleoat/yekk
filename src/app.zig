const std = @import("std");
const memory = @import("memory.zig");
const objc = @import("objc");
const c = @import("system");
const n = @import("platform/native.zig");
const core = @import("core.zig");
const decoder = @import("decoder.zig");
const catalog = @import("catalog.zig");
const cache = @import("cache.zig");
const actions = @import("actions.zig");
const hooks = @import("hooks.zig");
const commands = @import("commands.zig");
const options = @import("options.zig");
const presentation = @import("presentation.zig");
const sessions = @import("sessions.zig");
const navigation = @import("navigation.zig");
const view_actions = @import("view_actions.zig");
const input = @import("session_input.zig");
const O = objc.Object;
const nil: O = .{ .value = null };
const Entry = catalog.Entry;
const Image = decoder.Image;
const Action = actions.Action;
// Completion callbacks and display replacement must retain queue headroom for
// two renders, two decodes and closing, even during rapid cached navigation.
const retirement_headroom = 16;

const Cached = struct {
    stamp: Stamp = .{},
    image: ?*Image = null,
    version: u64 = 1,
    image_version: u64 = 0,
    failed_version: u64 = 0,
    failure: ?decoder.Failure = null,
    older: ?usize = null,
    newer: ?usize = null,
    rotation: u2 = 0,
    mirror_x: bool = false,
    mirror_y: bool = false,
    presentation_bytes: usize = 0,
};
const Job = struct {
    stamp: Stamp = .{},
    owner: *State = undefined,
    busy: bool = false,
    prefetch: bool = false,
    id: usize = 0,
    version: u64 = 0,
    path: [:0]const u8 = "",
    edge: u32 = 0,
    workers: usize = 1,
    limits: decoder.Limits = .{},
    elapsed_ms: f64 = 0,
    image: ?*Image = null,
    failure: ?decoder.Failure = null,
};
const Retirement = union(enum) {
    image: *Image,
    surface: n.Ref,

    fn destroy(self: Retirement) void {
        switch (self) {
            .image => |image| image.destroy(),
            .surface => |surface| n.CFRelease(surface),
        }
    }
};
const Releaser = struct {
    busy: bool = false,
    count: usize = 0,
    items: [32]Retirement = undefined,
    clear_context: bool = false,
};
const Stamp = @import("source").Stamp;
const Watch = struct {
    busy: bool = false,
    count: usize = 0,
    cursor: usize = 0,
    items: [16]struct { entry: Entry, stamp: Stamp } = undefined,
};
const Auxiliary = enum { reveal, external, trash, snapshot };
const Aux = struct {
    busy: bool = false,
    kind: Auxiliary = .reveal,
    path: [:0]const u8 = "",
    success: bool = false,
    id: ?usize = null,
    native_image: ?n.Ref = null,
};
const HookJob = struct {
    busy: bool = false,
    id: usize = 0,
    selection: u64 = 0,
    reload: bool = false,
    path: [:0]const u8 = "",
    command: [16384]u8 = undefined,
    template: hooks.Command = .{},
    snapshot: hooks.Snapshot = .{ .path = "" },
    manifest_count: usize = 0,
    result: commands.Result = .{},
    failure: ?anyerror = null,
    exists: bool = true,
};
const Cli = @import("cli.zig").Options;
const Prepared = struct {
    source: *Image,
    id: usize,
    version: u64,
    view: core.View,
    pixels: presentation.Request,
    purpose: presentation.Purpose,
};
const PrepareFailure = struct { id: usize, version: u64, request: presentation.Request, generation: u64 };
const RenderIntent = enum { foreground, prefetch };
const RenderWork = struct {
    // Owns one source reference until its completion callback retires it.
    wanted: Prepared,
    intent: RenderIntent,
    revision: u64,
    cache_epoch: u64,
    prefetch_generation: u64,
};
const RenderJob = struct {
    owner: *State = undefined,
    work: ?RenderWork = null,
    surface: ?presentation.Surface = null,
    elapsed_ms: f64 = 0,
};

const State = struct {
    slot: usize = 0,
    native_inputs: O = nil,
    catalog: catalog.Catalog = .{},
    input: [catalog.capacity][:0]const u8 = undefined,
    input_count: usize = 0,
    filelist_data: [1024 * 1024]u8 = undefined,
    initial: [1]Entry = undefined,
    entries: []Entry = &.{},
    positions: [catalog.capacity]usize = @splat(std.math.maxInt(usize)),
    indexing: bool = false,
    indexed: bool = false,
    index_failure: ?anyerror = null,
    options: catalog.Options = .{},
    settings: actions.Settings = .init(),
    index_settings: actions.Settings = .init(),
    settings_applied: bool = false,
    finished_launching: bool = false,
    ever_displayed: bool = false,
    cli: Cli = .{},
    cancel: std.atomic.Value(bool) = .init(false),
    cached: [catalog.capacity]Cached = @splat(.{}),
    stamps: [catalog.capacity]Stamp = @splat(.{}),
    oldest: ?usize = null,
    newest: ?usize = null,
    desired: ?usize = null,
    current: ?*Image = null,
    // Pin the published provider until CALayer has replaced its contents.
    // Final surface retirement then runs through the bounded worker queue.
    presented_surface: ?n.Ref = null,
    displayed: ?usize = null,
    displayed_path: [:0]const u8 = "",
    forward: bool = true,
    jobs: [2]Job = @splat(.{}),
    release_queue: [128]Retirement = undefined,
    release_head: usize = 0,
    release_count: usize = 0,
    releaser: Releaser = .{},
    clear_context_requested: bool = false,
    pressure: cache.Pressure = .normal,
    memory_retry: ?struct { id: usize, version: u64 } = null,
    memory_retry_id: ?usize = null,
    memory_retry_version: u64 = 0,
    memory_failures: usize = 0,
    memory_retries: usize = 0,
    memory_reclaimed: usize = 0,
    pressure_source: ?*anyopaque = null,
    pressure_cancelling: bool = false,
    watch: Watch = .{},
    aux: Aux = .{},
    hook: HookJob = .{},
    hook_paths: [catalog.capacity][:0]const u8 = undefined,
    selection_revision: u64 = 0,
    filelist_saving: bool = false,
    filelist_saved: bool = false,
    filelist_failure: ?anyerror = null,
    show_actions: bool = false,
    show_filename: bool = false,
    mouse_moved: bool = false,
    middle_zoom: bool = false,
    mouse_origin: n.Point = .{ .x = 0, .y = 0 },
    geometry: core.View = .{},
    render_jobs: [2]RenderJob = @splat(.{}),
    prefetch_generation: u64 = 0,
    prepare_failures: [2]?PrepareFailure = @splat(null),
    render_wanted: ?Prepared = null,
    render_presented: ?Prepared = null,
    render_revision: u64 = 0,
    render_presented_revision: u64 = 0,
    held_advance: navigation.HeldAdvance = .{},
    advance_display_link: O = nil,
    render_failed_revision: u64 = 0,
    worker_render_ms: f64 = 0,
    worst_native_contents_ms: f64 = 0,
    render_count: usize = 0,
    render_cache_hits: usize = 0,
    preview_queued: bool = false,
    preview_wanted: ?Prepared = null,
    heartbeat_last: f64 = 0,
    heartbeat_worst_ms: f64 = 0,
    heartbeat_count: usize = 0,
    closing: bool = false,
    pumping: bool = false,
    close_cursor: usize = 0,
    app: O = nil,
    window: O = nil,
    view: O = nil,
    layer: O = nil,
    overlay: O = nil,
    delegate: O = nil,
    timer: O = nil,
    open_panel: O = nil,
    alert: O = nil,
    pending_sheets: usize = 0,
    trash_id: ?usize = null,
    show_info: bool = false,
    show_help: bool = false,
    nearest: bool = false,
    dragging: ?n.Point = null,
    last_slide: f64 = 0,
    last_watch: f64 = 0,
    slideshow_running: bool = false,
    slide_failures: usize = 0,
    limits: decoder.Limits = .{},
    notice: [1024]u8 = @splat(0),
    notice_len: usize = 0,
    status_queued: bool = false,
    decode_count: usize = 0,
    cache_hits: usize = 0,
    resident_bytes: usize = 0,
    smoke_stage: usize = 0,
    smoke_count: usize = 0,
    smoke_failed: bool = false,
    benchmark_step: usize = 0,
    automation_queued: bool = false,
    smoke_image: ?*Image = null,
    warm_decodes: usize = 0,
    warm_redecodes: usize = 0,
    switch_started: f64 = 0,
    switch_ms: f64 = 0,
    worst_switch_ms: f64 = 0,
    worst_warm_switch_ms: f64 = 0,
    worker_decode_ms: f64 = 0,
    native_contents_ms: f64 = 0,
    native_layout_ms: f64 = 0,
    benchmark_viewport: core.Size = .{ .width = 0, .height = 0 },
    benchmark_backing: f64 = 1,
    snapshot_path: ?[:0]const u8 = null,
    started: f64 = 0,
};
const Control = struct {
    active: [sessions.capacity]bool = @splat(false),
    app: O = nil,
    delegate: O = nil,
    session_class: objc.Class = undefined,
    view_class: objc.Class = undefined,
    window_class: objc.Class = undefined,
    initialized: bool = false,
    finished_launching: bool = false,
    cli_inputs: bool = false,
    failed: bool = false,
    total_decodes: usize = 0,
    total_hits: usize = 0,
    warm_redecodes: usize = 0,
    worst_switch: f64 = 0,
    worst_warm_switch: f64 = 0,
    active_decodes: usize = 0,
    active_renders: usize = 0,
    speculative_renders: usize = 0,
    active_decode_workers: usize = 0,
    decode_worker_budget: usize = 8,
    speculative_decodes: usize = 0,
    waking: bool = false,
    allow_prefetch: bool = true,
    memory_recovering: bool = false,
    config_override: ?[:0]const u8 = null,
};
const Root = struct {
    sessions: [sessions.capacity]State,
    control: Control,
    renderer: presentation.Renderer,
};
var root: *Root = undefined;
var control: *Control = undefined;

// Initialize live metadata without materializing a giant aggregate constant or
// touching dormant session/path storage. Every skipped array is guarded by its
// initialized count before access. Keep scalar defaults defined on the types.
fn initState(state: *State, slot: usize, limits: decoder.Limits) void {
    @setEvalBranchQuota(4000);
    inline for (@typeInfo(State).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "catalog") and
            !std.mem.eql(u8, name, "input") and
            !std.mem.eql(u8, name, "filelist_data") and
            !std.mem.eql(u8, name, "hook_paths") and
            !std.mem.eql(u8, name, "initial") and
            !std.mem.eql(u8, name, "positions") and
            !std.mem.eql(u8, name, "cached") and
            !std.mem.eql(u8, name, "stamps") and
            !std.mem.eql(u8, name, "release_queue"))
            @field(state, name) = @field(@as(State, .{}), name);
    }
    inline for (@typeInfo(catalog.Catalog).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "entries") and !std.mem.eql(u8, name, "paths"))
            @field(state.catalog, name) = @field(@as(catalog.Catalog, .{}), name);
    }
    @memset(&state.positions, std.math.maxInt(usize));
    for (&state.cached) |*item| item.* = .{};
    @memset(std.mem.asBytes(&state.stamps), 0);
    state.slot = slot;
    state.limits = limits;
    state.started = n.now();
    state.catalog.random = .init(@bitCast(state.started));
}
// Native callbacks select their owning window. Every background handoff carries
// its session explicitly and establishes its own thread-local context.
threadlocal var s: *State = undefined;
fn sessionContext(context: ?*anyopaque) void {
    s = @ptrCast(@alignCast(context.?));
}
fn useSession(object: objc.c.id) void {
    var pointer: ?*anyopaque = null;
    _ = c.object_getInstanceVariable(object, "yekkState", &pointer);
    sessionContext(pointer);
}
fn bindSession(object: O) void {
    _ = c.object_setInstanceVariable(object.value, "yekkState", s);
}

fn cls(comptime name: [:0]const u8) objc.Class {
    return objc.getClass(name) orelse @panic("required macOS class missing");
}
fn string(bytes: []const u8) O {
    return cls("NSString").msgSend(O, "alloc", .{}).msgSend(O, "initWithBytes:length:encoding:", .{ bytes.ptr, bytes.len, @as(usize, if (std.unicode.utf8ValidateSlice(bytes)) 4 else 5) });
}
fn setText(target: O, selector: [:0]const u8, text: []const u8) void {
    const value = string(text);
    defer value.release();
    target.msgSend(void, selector, .{value});
}
fn url(path: [:0]const u8) O {
    const value = string(path);
    defer value.release();
    return cls("NSURL").msgSend(O, "fileURLWithPath:", .{value});
}
fn entry(id: usize) ?Entry {
    if (!s.indexed) {
        if (s.entries.len > 0 and s.initial[0].id == id) return s.initial[0];
        return null;
    }
    const p = s.positions[id];
    return if (p < s.entries.len) s.entries[p] else null;
}
fn position(id: usize) ?usize {
    if (!s.indexed) return if (s.entries.len > 0 and s.initial[0].id == id) 0 else null;
    return if (s.positions[id] < s.entries.len) s.positions[id] else null;
}
fn notice(comptime format: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&s.notice, format, args) catch "Operation failed";
    s.notice_len = text.len;
    status();
}
fn viewport() core.Size {
    const bounds = s.view.msgSend(n.Rect, "bounds", .{});
    const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
    return .{ .width = bounds.size.width * backing, .height = bounds.size.height * backing };
}
fn sourceSize(image: *Image) core.Size {
    return sourceSizeFor(s.displayed orelse return .{ .width = @floatFromInt(image.source_width), .height = @floatFromInt(image.source_height) }, image);
}
fn sourceSizeFor(id: usize, image: *Image) core.Size {
    const rotated = s.cached[id].rotation & 1 != 0;
    return .{ .width = @floatFromInt(if (rotated) image.source_height else image.source_width), .height = @floatFromInt(if (rotated) image.source_width else image.source_height) };
}
fn layout() void {
    if (s.current) |image| {
        const id = s.displayed orelse return;
        s.geometry = requestedView(id, image);
        requestRender(prepared(id, image, s.geometry));
    }
    status();
}
fn status() void {
    if (s.window.value == null or s.closing or s.status_queued) return;
    s.status_queued = true;
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, updateStatus);
}
fn updateStatus(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.status_queued = false;
    if (s.closing) {
        pump();
        return;
    }
    if (s.window.value == null or s.closing) return;
    var buffer: [4096]u8 = undefined;
    const shown = if (s.displayed != null) std.fs.path.basename(s.displayed_path) else "Yekk";
    const target = if (s.desired) |id| std.fs.path.basename((entry(id) orelse return).path) else "";
    const failed = if (s.desired) |id| s.cached[id].failed_version == s.cached[id].version else false;
    const render_pending = s.render_wanted != null and s.render_presented_revision != s.render_revision;
    const loading = render_pending or s.desired != null and (s.displayed != s.desired or (s.current != null and s.cached[s.desired.?].image_version != s.cached[s.desired.?].version));
    const text = if (s.notice_len > 0) std.fmt.bufPrint(&buffer, "{s} — {s}", .{ shown, s.notice[0..s.notice_len] }) catch shown else if (s.settings.error_line != 0) std.fmt.bufPrint(&buffer, "{s} — config error on line {d}", .{ shown, s.settings.error_line }) catch shown else if (failed) std.fmt.bufPrint(&buffer, "{s} — {s}: {s}", .{ shown, target, @errorName(s.cached[s.desired.?].failure.?) }) catch shown else if (loading or (s.desired != null and s.current == null)) std.fmt.bufPrint(&buffer, "{s} — loading {s}", .{ shown, target }) catch shown else if (s.indexing and s.current == null) "Yekk — discovering images…" else if (s.current) |image| std.fmt.bufPrint(&buffer, "{s} — {d}/{d} · {d:.0}%{s}", .{ shown, (position(s.displayed.?) orelse 0) + 1, s.entries.len, s.geometry.scale * 100, if (image.width < image.source_width or image.height < image.source_height) " · preview" else "" }) catch shown else "Yekk — Command-O to open images";
    setText(s.window, "setTitle:", text);
    if (failed) s.held_advance.presented(n.CACurrentMediaTime());
    updateOverlay();
}
fn detach(id: usize) void {
    const r = &s.cached[id];
    if (r.older) |older| s.cached[older].newer = r.newer else s.oldest = r.newer;
    if (r.newer) |newer| s.cached[newer].older = r.older else s.newest = r.older;
    r.older = null;
    r.newer = null;
}
fn touch(id: usize) void {
    const r = &s.cached[id];
    if (s.newest == id) return;
    if (r.older != null or r.newer != null or s.oldest == id) detach(id);
    r.older = s.newest;
    if (s.newest) |newest| s.cached[newest].newer = id else s.oldest = id;
    s.newest = id;
}
fn enqueueRelease(image: *Image) bool {
    return enqueueRetirement(.{ .image = image });
}
fn enqueueRetirement(item: Retirement) bool {
    if (s.release_count == s.release_queue.len) return false;
    s.release_queue[(s.release_head + s.release_count) % s.release_queue.len] = item;
    s.release_count += 1;
    return true;
}
fn releasePump() void {
    // A cleared layer no longer needs its pin. Keep it until queue space is
    // available, including when closing or removing the last catalog entry.
    if (s.closing or s.displayed == null) if (s.presented_surface) |surface| {
        if (enqueueRetirement(.{ .surface = surface })) s.presented_surface = null;
    };
    if (s.releaser.busy or (s.release_count == 0 and !s.clear_context_requested)) return;
    s.releaser.count = @min(s.releaser.items.len, s.release_count);
    for (s.releaser.items[0..s.releaser.count]) |*item| {
        item.* = s.release_queue[s.release_head];
        s.release_head = (s.release_head + 1) % s.release_queue.len;
        s.release_count -= 1;
    }
    s.releaser.busy = true;
    s.releaser.clear_context = s.clear_context_requested or s.pressure != .normal;
    s.clear_context_requested = false;
    n.dispatch_async_f(n.dispatch_get_global_queue(0x11, 0), s, releaseWorker);
}
fn releaseWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    for (s.releaser.items[0..s.releaser.count]) |item| item.destroy();
    if (s.releaser.clear_context) root.renderer.clearCaches();
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, released);
}
fn released(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.releaser.busy = false;
    wakeAll();
}
fn isMemoryFailure(failure: ?decoder.Failure) bool {
    return if (failure) |err| err == error.OutOfMemory else false;
}
fn adequate(id: usize, image: *Image) bool {
    return core.hasDetail(.{ .width = @floatFromInt(image.source_width), .height = @floatFromInt(image.source_height) }, .{ .width = @floatFromInt(image.width), .height = @floatFromInt(image.height) }, requestedView(id, image).scale);
}
fn present(id: usize, image: *Image) bool {
    requestRender(prepared(id, image, requestedView(id, image)));
    return s.current == image;
}
fn requestedView(id: usize, image: *Image) core.View {
    return viewFor(id, image, s.displayed != id);
}
fn viewFor(id: usize, image: *Image, navigating: bool) core.View {
    var view = s.geometry;
    const size = sourceSizeFor(id, image);
    const vp = viewport();
    if (navigating) {
        if (!s.settings.keep_view) {
            view = .initial(s.settings.fit, s.cli.zoom);
        } else if (s.current) |old| {
            view.pan_y = -view.pan_y;
            view = view.keptViewport(sourceSize(old), size, vp);
            view.pan_y = -view.pan_y;
        }
    }
    if (!view.manual) view.scale = core.initialScale(view.mode, if (view.use_initial_zoom) s.cli.zoom else null, size, vp);
    if (s.settings.keep_view) view.clampViewport(size, vp) else view.clamp(size, vp);
    return view;
}
fn prepared(id: usize, image: *Image, view: core.View) Prepared {
    const vp = viewport();
    const size = sourceSizeFor(id, image);
    const center = core.center(view, size, vp);
    const r = s.cached[id];
    const cos: f64 = switch (r.rotation) {
        0 => 1,
        2 => -1,
        else => 0,
    };
    const sin: f64 = switch (r.rotation) {
        1 => -1,
        3 => 1,
        else => 0,
    };
    const mx: f64 = if (r.mirror_x) -1 else 1;
    const my: f64 = if (r.mirror_y) -1 else 1;
    const sx = view.scale * @as(f64, @floatFromInt(image.source_width)) / @as(f64, @floatFromInt(image.width));
    const sy = view.scale * @as(f64, @floatFromInt(image.source_height)) / @as(f64, @floatFromInt(image.height));
    const a = cos * mx * sx;
    const b = sin * my * sx;
    const c0 = -sin * mx * sy;
    const d = cos * my * sy;
    return .{ .source = image, .id = id, .version = s.cached[id].image_version, .view = view, .purpose = view.surfacePurpose(), .pixels = .{ .width = @intFromFloat(@max(1, @min(16384, @round(vp.width)))), .height = @intFromFloat(@max(1, @min(16384, @round(vp.height)))), .nearest = s.nearest, .transform = .{ .a = a, .b = b, .c = c0, .d = d, .tx = center.x - (a * @as(f64, @floatFromInt(image.width)) + c0 * @as(f64, @floatFromInt(image.height))) / 2, .ty = center.y - (b * @as(f64, @floatFromInt(image.width)) + d * @as(f64, @floatFromInt(image.height))) / 2 } } };
}
fn previewTransform(next: Prepared) void {
    const old = s.render_presented orelse return;
    if (old.source != next.source) return;
    const a = old.pixels.transform;
    const b = next.pixels.transform;
    const determinant = a.a * a.d - a.b * a.c;
    if (determinant == 0) return;
    const transform: n.Affine = .{
        .a = (b.a * a.d - b.c * a.b) / determinant,
        .b = (b.b * a.d - b.d * a.b) / determinant,
        .c = (b.c * a.a - b.a * a.c) / determinant,
        .d = (b.d * a.a - b.b * a.c) / determinant,
    };
    const tx = b.tx - transform.a * a.tx - transform.c * a.ty;
    const ty = b.ty - transform.b * a.tx - transform.d * a.ty;
    const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
    const x = @as(f64, @floatFromInt(old.pixels.width)) / 2;
    const y = @as(f64, @floatFromInt(old.pixels.height)) / 2;
    const transaction = cls("CATransaction");
    transaction.msgSend(void, "begin", .{});
    transaction.msgSend(void, "setDisableActions:", .{true});
    s.layer.msgSend(void, "setContentsScale:", .{backing});
    s.layer.msgSend(void, "setBounds:", .{n.rect(0, 0, @as(f64, @floatFromInt(old.pixels.width)) / backing, @as(f64, @floatFromInt(old.pixels.height)) / backing)});
    s.layer.msgSend(void, "setAffineTransform:", .{transform});
    s.layer.msgSend(void, "setPosition:", .{n.Point{ .x = (transform.a * x + transform.c * y + tx) / backing, .y = (transform.b * x + transform.d * y + ty) / backing }});
    transaction.msgSend(void, "commit", .{});
}
fn requestRender(wanted: Prepared) void {
    if (s.closing) return;
    if (s.render_wanted == null or !std.meta.eql(s.render_wanted.?, wanted)) {
        s.render_revision += 1;
        s.render_wanted = wanted;
        s.preview_wanted = wanted;
        if (!s.preview_queued) {
            s.preview_queued = true;
            n.dispatch_async_f(n.dispatch_get_main_queue(), s, updatePreview);
        }
    }
    renderPump();
}
fn updatePreview(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.preview_queued = false;
    if (!s.closing and s.render_presented_revision != s.render_revision) {
        if (s.preview_wanted) |wanted| previewTransform(wanted);
    }
    s.preview_wanted = null;
    if (s.closing) pump();
}
fn rendersBusy() bool {
    for (s.render_jobs) |job| if (job.work != null) return true;
    return false;
}
fn rendering(image: *Image) bool {
    for (s.render_jobs) |job| if (job.work) |work| {
        if (work.wanted.source == image) return true;
    };
    return false;
}
fn startRender(wanted: Prepared, intent: RenderIntent) bool {
    if (rendering(wanted.source) or control.active_renders >= 2 or s.release_count >= s.release_queue.len - retirement_headroom) return false;
    for (&s.render_jobs) |*job| if (job.work == null) {
        _ = wanted.source.retain();
        job.* = .{ .owner = s, .work = .{ .wanted = wanted, .intent = intent, .revision = s.render_revision, .cache_epoch = wanted.source.cache_epoch, .prefetch_generation = s.prefetch_generation } };
        control.active_renders += 1;
        if (intent == .prefetch) control.speculative_renders += 1;
        s.render_count += 1;
        n.dispatch_async_f(n.dispatch_get_global_queue(if (intent == .prefetch) 0x11 else 0x19, 0), job, renderWorker);
        return true;
    };
    return false;
}
fn renderPump() void {
    const wanted = s.render_wanted orelse return;
    if (s.closing or s.render_failed_revision == s.render_revision) return;
    if (s.render_presented_revision == s.render_revision) return;
    // Cache publication is main-queue-only. Existing immutable surfaces remain
    // readable even while a worker prepares another view of this same source.
    if (s.current != wanted.source and s.cached[wanted.id].image != wanted.source) return;
    if (wanted.source.cachedSurface(wanted.pixels)) |surface| {
        s.render_cache_hits += 1;
        _ = applyPrepared(wanted, s.render_revision, surface);
        return;
    }
    if (!control.memory_recovering) _ = startRender(wanted, .foreground);
}
fn clearPrepareFailure(id: usize) void {
    for (&s.prepare_failures) |*failure| if (failure.*) |value| {
        if (value.id == id) failure.* = null;
    };
}
fn failedPreparation(wanted: Prepared) bool {
    for (s.prepare_failures) |failure| if (failure) |value| {
        if (value.id == wanted.id and value.version == wanted.version and value.generation == s.prefetch_generation and std.meta.eql(value.request, wanted.pixels)) return true;
    };
    return false;
}
fn rememberPrepareFailure(work: RenderWork) void {
    const pos = position(s.desired orelse return) orelse return;
    for (cache.adjacent(pos, s.entries.len, s.forward, s.settings.wrap), 0..) |index, side| if (index) |i| {
        if (s.entries[i].id == work.wanted.id) s.prepare_failures[side] = .{ .id = work.wanted.id, .version = work.wanted.version, .request = work.wanted.pixels, .generation = work.prefetch_generation };
    };
}
fn renderPrefetchPump() void {
    // One speculative task leaves one global slot free for foreground work.
    // wakeAll's first pass admits foreground work across every window first.
    if (!control.allow_prefetch or control.memory_recovering or s.closing or s.pressure != .normal or !s.indexed or s.current == null or s.displayed != s.desired or s.render_presented_revision != s.render_revision or control.active_renders != 0 or control.speculative_renders != 0 or control.active_decodes > control.speculative_decodes) return;
    if (s.cli.stress_cycles > 0 and s.cli.stress_no_prefetch) return;
    const pos = position(s.desired orelse return) orelse return;
    for (cache.adjacent(pos, s.entries.len, s.forward, s.settings.wrap)) |index| if (index) |i| {
        const id = s.entries[i].id;
        const record = &s.cached[id];
        const image = record.image orelse continue;
        if (record.image_version != record.version or record.failed_version == record.version or rendering(image)) continue;
        const wanted = prepared(id, image, viewFor(id, image, true));
        if (image.cachedSurface(wanted.pixels) != null) continue;
        if (failedPreparation(wanted)) continue;
        _ = startRender(wanted, .prefetch);
        return;
    };
}
fn renderWorker(context: ?*anyopaque) callconv(.c) void {
    const job: *RenderJob = @ptrCast(@alignCast(context.?));
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const wanted = job.work.?.wanted;
    const started = n.now();
    job.surface = root.renderer.prepare(wanted.source, wanted.pixels) catch null;
    job.elapsed_ms = (n.now() - started) * 1000;
    n.dispatch_async_f(n.dispatch_get_main_queue(), job, rendered);
}
fn rendered(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    const job: *RenderJob = @ptrCast(@alignCast(context.?));
    s = job.owner;
    const work = job.work.?;
    const wanted = work.wanted;
    const record = &s.cached[wanted.id];
    control.active_renders -= 1;
    if (work.intent == .prefetch) control.speculative_renders -= 1;
    s.worker_render_ms += job.elapsed_ms;
    const valid = !s.closing and record.image == wanted.source and record.version == wanted.version and record.image_version == wanted.version;
    const foreground = work.intent == .foreground and work.revision == s.render_revision;
    const needed = if (s.render_wanted) |latest| latest.source == wanted.source and latest.version == wanted.version and std.meta.eql(latest.pixels, wanted.pixels) else false;
    if (job.surface) |surface| {
        // A superseded task must not replace a surface used since it started.
        // Inactive, still-valid sources can otherwise retain useful completed work.
        const admit = valid and (needed or wanted.source.cache_epoch == work.cache_epoch) and (needed or work.intent == .foreground or (s.pressure == .normal and !control.memory_recovering));
        if (admit) {
            if (wanted.source.storeSurface(surface, if (needed) s.render_wanted.?.purpose else wanted.purpose)) |old| std.debug.assert(enqueueRetirement(.{ .surface = old.native() }));
            s.resident_bytes -= record.presentation_bytes;
            record.presentation_bytes = wanted.source.presentationBytes();
            s.resident_bytes += record.presentation_bytes;
            clearPrepareFailure(wanted.id);
            if (foreground) _ = applyPrepared(wanted, work.revision, surface.native());
        } else std.debug.assert(enqueueRetirement(.{ .surface = surface.native() }));
    } else if (valid) {
        if (foreground) {
            s.render_failed_revision = work.revision;
            notice("Cannot prepare image for display", .{});
        } else if (work.intent == .prefetch) rememberPrepareFailure(work);
    }
    job.surface = null;
    std.debug.assert(enqueueRelease(wanted.source));
    job.work = null;
    wakeAll();
}

fn applyPrepared(wanted: Prepared, revision: u64, surface: n.Ref) bool {
    if (s.release_count >= s.release_queue.len - retirement_headroom) return false;
    if (s.current != wanted.source) {
        // Leave room for running decode/render completions and closing even
        // when rapid cache hits outrun the retirement worker.
        if (s.current) |old| if (!enqueueRelease(old)) return false;
        s.current = wanted.source.retain();
    }
    s.displayed = wanted.id;
    s.displayed_path = (entry(wanted.id) orelse return false).path;
    s.geometry = wanted.view;
    s.ever_displayed = true;
    touch(wanted.id);
    const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
    const transaction = cls("CATransaction");
    transaction.msgSend(void, "begin", .{});
    transaction.msgSend(void, "setDisableActions:", .{true});
    if (wanted.purpose == .overview) if (wanted.source.protectOverview(surface)) |old| {
        std.debug.assert(enqueueRetirement(.{ .surface = old.native() }));
        if (s.cached[wanted.id].image == wanted.source) {
            s.cached[wanted.id].presentation_bytes -= old.bytes();
            s.resident_bytes -= old.bytes();
        }
    };
    const previous_surface = s.presented_surface;
    if (previous_surface != surface) s.presented_surface = n.CFRetain(surface);
    const started = n.now();
    s.layer.msgSend(void, "setContents:", .{wanted.source.displayContents(surface)});
    s.layer.msgSend(void, "setContentsScale:", .{backing});
    s.layer.msgSend(void, "setAffineTransform:", .{n.Affine{ .a = 1, .b = 0, .c = 0, .d = 1 }});
    s.benchmark_viewport = .{ .width = @floatFromInt(wanted.pixels.width), .height = @floatFromInt(wanted.pixels.height) };
    s.benchmark_backing = backing;
    const width = @as(f64, @floatFromInt(wanted.pixels.width)) / backing;
    const height = @as(f64, @floatFromInt(wanted.pixels.height)) / backing;
    s.layer.msgSend(void, "setBounds:", .{n.rect(0, 0, width, height)});
    s.layer.msgSend(void, "setPosition:", .{n.Point{ .x = width / 2, .y = height / 2 }});
    transaction.msgSend(void, "commit", .{});
    const commit_ms = (n.now() - started) * 1000;
    s.native_contents_ms += commit_ms;
    s.worst_native_contents_ms = @max(s.worst_native_contents_ms, commit_ms);
    if (previous_surface != surface) if (previous_surface) |old| {
        std.debug.assert(enqueueRetirement(.{ .surface = old }));
        // Cache hits can publish directly from layout, outside pump(). Their
        // retirement needs its own wakeup even when no render job completes.
        releasePump();
    };
    if (s.cli.benchmark and s.heartbeat_last > 0) s.heartbeat_worst_ms = @max(s.heartbeat_worst_ms, (n.now() - s.heartbeat_last) * 1000);
    wanted.source.usedSurface();
    s.render_presented = wanted;
    s.render_presented_revision = revision;
    s.held_advance.presented(n.CACurrentMediaTime());
    s.last_slide = n.now();
    s.slide_failures = 0;
    if (s.switch_started > 0) {
        s.switch_ms = (n.now() - s.switch_started) * 1000;
        s.worst_switch_ms = @max(s.worst_switch_ms, s.switch_ms);
        if (s.cli.benchmark and s.benchmark_step > @min(s.entries.len, 5) * @as(usize, 2)) s.worst_warm_switch_ms = @max(s.worst_warm_switch_ms, s.switch_ms);
        s.switch_started = 0;
    }
    status();
    return true;
}

fn select(index: usize, reload: bool) void {
    if (s.closing or index >= s.entries.len) return;
    const id = s.entries[index].id;
    if (s.desired) |previous| if (position(previous)) |p| {
        if (p != index) s.forward = index > p;
    };
    s.desired = id;
    s.selection_revision += 1;
    s.held_advance.selected();
    s.render_revision += 1;
    s.render_wanted = null;
    s.preview_wanted = null;
    s.notice_len = 0;
    s.switch_started = n.now();
    s.memory_retry = null;
    s.memory_retry_id = null;
    if (isMemoryFailure(s.cached[id].failure)) {
        s.cached[id].failed_version = 0;
    }
    if (reload) {
        s.cached[id].version += 1;
        s.cached[id].failed_version = 0;
    }
    if (s.cached[id].image != null and s.cached[id].image_version == s.cached[id].version) s.cache_hits += 1;
    status();
    pump();
}
fn navigate(delta: isize, slideshow: bool) void {
    if (s.entries.len == 0) return;
    const index = if (s.desired) |id| position(id) orelse 0 else 0;
    switch (navigation.step(index, s.entries.len, delta, slideshow, &s.settings)) {
        .stay => {},
        .quit => close(),
        .hold => {
            s.slideshow_running = false;
            configureTimer();
        },
        .select => |target| {
            if (s.indexed and s.options.shuffle and delta > 0 and target.wrapped and s.entries.len > 1) {
                s.catalog.random.random().shuffle(Entry, s.entries);
                for (s.entries, 0..) |e, i| s.positions[e.id] = i;
            }
            if (target.position != index) select(target.position, false);
        },
    }
}

fn inflight(id: usize) ?*Job {
    for (&s.jobs) |*job| if (job.busy and job.id == id and job.version == s.cached[id].version) return job;
    return null;
}
fn start(job: *Job, id: usize, prefetch: bool) bool {
    if (prefetch and s.cli.stress_cycles > 0 and s.cli.stress_no_prefetch) return false;
    if (control.memory_recovering) return false;
    if (s.release_count >= s.release_queue.len - retirement_headroom) return false;
    if (!cache.admitDecode(control.active_decodes, control.speculative_decodes, !prefetch) or (prefetch and !control.allow_prefetch)) return false;
    const available = control.decode_worker_budget - control.active_decode_workers;
    if (available == 0) return false;
    const path = (entry(id) orelse return false).path;
    // Extension is a scheduling hint only; content still selects the decoder.
    const ext = std.fs.path.extension(path);
    const is_tiff = std.ascii.eqlIgnoreCase(ext, ".tif") or std.ascii.eqlIgnoreCase(ext, ".tiff");
    const workers: usize = @intCast(@min(available, if (is_tiff) (if (prefetch) @max(1, control.decode_worker_budget / 2) else control.decode_worker_budget) else 1));
    var edge: u32 = 0;
    if (s.pressure == .critical) {
        if (s.cached[id].image) |image| {
            edge = core.detailEdge(.{ .width = @floatFromInt(image.source_width), .height = @floatFromInt(image.source_height) }, requestedView(id, image).scale);
        } else {
            const vp = viewport();
            edge = @intFromFloat(@max(1, @min(std.math.maxInt(u32), @ceil(@max(vp.width, vp.height)))));
        }
    }
    job.* = .{ .owner = s, .busy = true, .prefetch = prefetch, .id = id, .version = s.cached[id].version, .path = path, .workers = workers, .limits = s.limits, .edge = edge };
    job.limits.tiff_workers = workers;
    job.limits.raw_retirement = !memory.debug_enabled;
    job.limits.cancel = &s.cancel;
    s.decode_count += 1;
    control.active_decodes += 1;
    control.active_decode_workers += workers;
    if (prefetch) control.speculative_decodes += 1;
    n.dispatch_async_f(n.dispatch_get_global_queue(if (prefetch) 0x11 else 0x19, 0), job, decodeWorker);
    return true;
}
fn wakeAll() void {
    if (control.waking) return;
    control.waking = true;
    defer control.waking = false;
    const previous = s;
    defer s = previous;
    control.allow_prefetch = false;
    for (&root.sessions, control.active) |*session, active| if (active) {
        s = session;
        pump();
    };
    finishMemoryRecovery();
    control.allow_prefetch = true;
    for (&root.sessions, control.active) |*session, active| if (active) {
        s = session;
        pump();
    };
}
fn pump() void {
    if (s.pumping) return;
    s.pumping = true;
    defer s.pumping = false;
    releasePump();
    if (s.closing) {
        closePump();
        return;
    }
    trimPressure();
    if (s.desired) |id| {
        const r = &s.cached[id];
        if (r.image != null and r.image_version == r.version) _ = present(id, r.image.?);
        if (r.failed_version == r.version and isMemoryFailure(r.failure) and (s.memory_retry_id != id or s.memory_retry_version != r.version)) beginMemoryRecovery(id);
        const need = r.image == null or r.image_version != r.version or !adequate(id, r.image.?);
        if (need and r.failed_version != r.version) {
            if (inflight(id)) |job| {
                if (job.prefetch) {
                    job.prefetch = false;
                    control.speculative_decodes -= 1;
                }
            } else {
                for (&s.jobs) |*job| if (!job.busy) {
                    _ = start(job, id, false);
                    break;
                };
            }
        }
        if (s.indexed and s.current != null and s.displayed == id and s.pressure == .normal and r.image != null and r.image_version == r.version and r.failed_version != r.version and adequate(id, r.image.?)) {
            var speculative = false;
            for (s.jobs) |job| if (job.busy and job.prefetch) {
                speculative = true;
            };
            if (!speculative) {
                const neighbors = cache.adjacent(position(id) orelse 0, s.entries.len, s.forward, s.settings.wrap);
                for (neighbors) |neighbor| if (neighbor) |index| {
                    const other = s.entries[index].id;
                    const target = &s.cached[other];
                    if ((target.image != null and target.image_version == target.version) or target.failed_version == target.version or inflight(other) != null) continue;
                    for (&s.jobs) |*job| if (!job.busy) {
                        _ = start(job, other, true);
                        break;
                    };
                    break;
                };
            }
        }
    }
    renderPump();
    renderPrefetchPump();
    releasePump();
    status();
    if (s.cli.smoke or s.cli.benchmark or s.cli.watch_test or s.cli.hook_test) automation();
}
fn decodeWorker(context: ?*anyopaque) callconv(.c) void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const job: *Job = @ptrCast(@alignCast(context.?));
    s = job.owner;
    const started = if (s.cli.benchmark) n.now() else 0;
    const before = (Stamp.read(job.path) orelse Stamp{});
    job.image = decoder.loadWithLimits(job.path, job.edge, memory.allocator(), job.limits) catch |err| result: {
        job.failure = err;
        break :result null;
    };
    if (job.image) |image| image.async_retirement = true;
    job.stamp = (Stamp.read(job.path) orelse Stamp{});
    if (job.image != null and !std.meta.eql(before, job.stamp)) {
        job.image.?.destroy();
        job.image = null;
        job.failure = error.SourceChanged;
    }
    if (s.cli.benchmark) job.elapsed_ms = (n.now() - started) * 1000;
    n.dispatch_async_f(n.dispatch_get_main_queue(), job, decoded);
}
fn decoded(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    const job: *Job = @ptrCast(@alignCast(context.?));
    s = job.owner;
    if (s.cli.benchmark) s.worker_decode_ms += job.elapsed_ms;
    const r = &s.cached[job.id];
    if (job.image) |image| {
        if (!s.closing and r.version == job.version and (!job.prefetch or s.pressure == .normal)) {
            if (r.image) |old| {
                s.resident_bytes -= old.accountedBytes() + r.presentation_bytes;
                r.presentation_bytes = 0;
                std.debug.assert(enqueueRelease(old));
            }
            r.image = image;
            clearPrepareFailure(job.id);
            r.stamp = job.stamp;
            if (s.indexed) s.stamps[job.id] = job.stamp;
            r.image_version = job.version;
            r.failed_version = 0;
            r.failure = null;
            s.resident_bytes += image.accountedBytes();
            touch(job.id);
        } else std.debug.assert(enqueueRelease(image));
    } else if (!s.closing and r.version == job.version) {
        r.failure = job.failure;
        r.failed_version = job.version;
        if (isMemoryFailure(job.failure)) s.memory_failures += 1;
    }
    control.active_decodes -= 1;
    control.active_decode_workers -= job.workers;
    if (job.prefetch) control.speculative_decodes -= 1;
    job.busy = false;
    job.image = null;
    wakeAll();
}
fn trimPressure() void {
    const pressure: cache.Pressure = if (control.memory_recovering) .critical else s.pressure;
    if (pressure == .normal) return;
    var candidate_id = s.oldest;
    var count: usize = 0;
    while (candidate_id) |id| {
        if (count >= 16 or s.release_count >= s.release_queue.len - retirement_headroom) break;
        const r = &s.cached[id];
        const next = r.newer;
        var neighbor = false;
        if (s.desired) |desired| if (position(desired)) |pos| {
            for (cache.adjacent(pos, s.entries.len, true, s.settings.wrap)) |index| if (index) |i| {
                if (s.entries[i].id == id) neighbor = true;
            };
        };
        if (cache.reclaim(.{ .state = .ready, .displayed = s.displayed == id }, pressure, s.desired == id, neighbor)) {
            if (r.image) |image| {
                std.debug.assert(enqueueRelease(image));
                s.resident_bytes -= image.accountedBytes() + r.presentation_bytes;
                r.presentation_bytes = 0;
                r.image = null;
                detach(id);
                if (control.memory_recovering) s.memory_reclaimed += 1;
            }
        }
        candidate_id = next;
        count += 1;
    }
}
fn beginMemoryRecovery(id: usize) void {
    const r = &s.cached[id];
    s.memory_retry_id = id;
    s.memory_retry_version = r.version;
    s.memory_retry = .{ .id = id, .version = r.version };
    if (control.memory_recovering) return;
    control.memory_recovering = true;
    // A failed allocation is real pressure even if the OS has not signalled it.
    // Reclaim inactive history across windows in existing bounded worker batches.
    for (&root.sessions, control.active) |*session, active| if (active) {
        session.clear_context_requested = true;
        session.prefetch_generation +%= 1;
    };
}
fn finishMemoryRecovery() void {
    if (!control.memory_recovering or control.active_decodes != 0 or control.active_renders != 0) return;
    for (&root.sessions, control.active) |*session, active| if (active) {
        if (session.release_count != 0 or session.releaser.busy or session.clear_context_requested) return;
    };
    control.memory_recovering = false;
    for (&root.sessions, control.active) |*session, active| if (active) {
        if (session.memory_retry) |retry| {
            session.memory_retry = null;
            const r = &session.cached[retry.id];
            if (!session.closing and session.desired == retry.id and r.version == retry.version and isMemoryFailure(r.failure)) {
                // Exactly one automatic retry after retirement has completed.
                // Another failure stays visible until selection/pressure changes.
                r.failed_version = 0;
                session.memory_retries += 1;
            }
        }
    };
}
fn pressureChanged(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    if (s.closing) return;
    const flags = n.dispatch_source_get_data(s.pressure_source.?);
    setPressure(if (flags & 4 != 0) .critical else if (flags & 2 != 0) .warning else .normal);
}
fn setPressure(pressure: cache.Pressure) void {
    if (pressure == .normal and s.pressure != .normal) s.prefetch_generation +%= 1;
    if (pressure == .normal and s.pressure != .normal) if (s.desired) |id| {
        const r = &s.cached[id];
        if (isMemoryFailure(r.failure)) {
            r.failed_version = 0;
            s.memory_retry_id = null;
        }
    };
    s.pressure = pressure;
    if (pressure != .normal) s.clear_context_requested = true;
    pump();
}
fn pressureCancelled(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    n.dispatch_release(s.pressure_source.?);
    s.pressure_source = null;
    s.pressure_cancelling = false;
    pump();
}
fn closePump() void {
    if (s.current) |image| {
        if (!enqueueRelease(image)) return;
        s.current = null;
    }
    var processed: usize = 0;
    while (s.close_cursor < s.cached.len and processed < 64 and s.release_count < s.release_queue.len - retirement_headroom) : (s.close_cursor += 1) {
        if (s.cached[s.close_cursor].image) |image| {
            std.debug.assert(enqueueRelease(image));
            s.cached[s.close_cursor].image = null;
            processed += 1;
        }
    }
    releasePump();
    if (s.close_cursor != s.cached.len or s.release_count != 0 or s.releaser.busy or s.indexing or s.watch.busy or s.aux.busy or s.hook.busy or s.pressure_cancelling or rendersBusy() or s.preview_queued or s.automation_queued or s.status_queued or s.pending_sheets > 0) return;
    for (s.jobs) |job| if (job.busy) return;
    if (s.filelist_saving) return;
    if (!s.filelist_saved and s.cli.filelist != null and !std.mem.eql(u8, s.cli.filelist.?, "-") and s.indexed and s.index_failure == null) {
        s.filelist_saving = true;
        n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, saveFilelistWorker);
        return;
    }

    control.failed = control.failed or s.smoke_failed or (s.input_count > 0 and !s.ever_displayed);
    control.total_decodes += s.decode_count;
    control.total_hits += s.cache_hits;
    control.warm_redecodes += s.warm_redecodes;
    control.worst_switch = @max(control.worst_switch, s.worst_switch_ms);
    control.worst_warm_switch = @max(control.worst_warm_switch, s.worst_warm_switch_ms);
    s.window.msgSend(void, "setDelegate:", .{nil});
    std.debug.assert(s.presented_surface == null);
    s.layer.release();
    s.overlay.release();
    s.view.release();
    s.window.release();
    s.delegate.release();
    if (s.native_inputs.value != null) {
        s.native_inputs.release();
        s.native_inputs = nil;
    }
    control.active[s.slot] = false;
    for (control.active) |active| if (active) return;
    control.app.msgSend(void, "stop:", .{nil});
    const event = cls("NSEvent").msgSend(O, "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{ @as(usize, 15), n.Point{ .x = 0, .y = 0 }, @as(usize, 0), @as(f64, 0), @as(isize, 0), nil, @as(i16, 0), @as(isize, 0), @as(isize, 0) });
    control.app.msgSend(void, "postEvent:atStart:", .{ event, true });
}
fn windowWillClose(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    if (s.closing) return;
    s.closing = true;
    stopHeldAdvance();
    if (s.advance_display_link.value != null) {
        s.advance_display_link.msgSend(void, "invalidate", .{});
        s.advance_display_link.release();
        s.advance_display_link = nil;
    }
    s.render_revision += 1;
    s.render_wanted = null;
    s.cancel.store(true, .release);
    if (s.timer.value != null) {
        s.timer.msgSend(void, "invalidate", .{});
        s.timer = nil;
    }
    if (s.open_panel.value != null) s.open_panel.msgSend(void, "cancel:", .{nil});
    if (s.alert.value != null) s.window.msgSend(void, "endSheet:returnCode:", .{ s.alert.msgSend(O, "window", .{}), @as(i64, 1001) });
    s.layer.msgSend(void, "setContents:", .{nil});
    if (s.pressure_source) |source| {
        s.pressure_cancelling = true;
        n.dispatch_source_cancel(source);
    }
    pump();
}
fn close() void {
    if (!s.closing) {
        if (s.cli.borderless) s.window.msgSend(void, "close", .{}) else s.window.msgSend(void, "performClose:", .{nil});
    }
}

fn loadSettings() void {
    input.loadSettings(&s.index_settings, control.config_override, s.cli.keys) catch {
        if (s.index_settings.error_line == 0) s.index_settings.error_line = 1;
    };
}
fn initialIndexed(e: Entry) void {
    s.initial[0] = e;
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, initialReady);
}
fn applySettings() void {
    if (s.settings_applied) return;
    s.settings = s.index_settings;
    s.settings_applied = true;
    s.cli.apply(&s.settings);
    s.show_actions = s.cli.draw_actions;
    s.show_filename = s.cli.draw_filename;
    s.geometry.mode = s.settings.fit;
    s.slideshow_running = s.settings.interval > 0 and !(if (s.cli.slideshow) |slideshow| slideshow.paused else false);
    background();
    configureTimer();
    menus();
    if (s.settings.error_line != 0) notice("Configuration error on line {d}", .{s.settings.error_line});
}
fn indexWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    loadSettings();
    if (s.native_inputs.value != null) for (0..s.input_count) |i| {
        const path = s.native_inputs.msgSend(O, "objectAtIndex:", .{i});
        if (!path.msgSend(bool, "isKindOfClass:", .{cls("NSString")})) {
            s.index_failure = error.InvalidPath;
            n.dispatch_async_f(n.dispatch_get_main_queue(), s, indexReady);
            return;
        }
        const bytes = path.msgSend([*c]const u8, "UTF8String", .{});
        if (bytes == null) {
            s.index_failure = error.InvalidPath;
            n.dispatch_async_f(n.dispatch_get_main_queue(), s, indexReady);
            return;
        }
        s.input[i] = std.mem.span(bytes);
    };
    readFilelist() catch |err| {
        s.index_failure = err;
        n.dispatch_async_f(n.dispatch_get_main_queue(), s, indexReady);
        return;
    };
    s.catalog.build(s.input[0..s.input_count], s.options) catch |err| {
        s.index_failure = err;
    };
    for (s.catalog.entries[0..s.catalog.count]) |e| s.stamps[e.id] = (Stamp.read(e.path) orelse Stamp{});
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, indexReady);
}
fn initialReady(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    if (s.closing) return;
    applySettings();
    s.entries = &s.initial;
    select(0, false);
}
fn indexReady(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.indexing = false;
    s.indexed = true;
    if (s.closing) {
        pump();
        return;
    }
    applySettings();
    s.entries = s.catalog.entries[0..s.catalog.count];
    for (s.entries, 0..) |e, i| {
        s.positions[e.id] = i;
        if (s.cached[e.id].image != null) s.stamps[e.id] = s.cached[e.id].stamp;
    }
    if (s.desired == null and s.entries.len > 0) {
        const start_position = if (s.catalog.selected) |path| selected: {
            for (s.entries, 0..) |e, i| if (std.mem.eql(u8, e.path, path)) break :selected i;
            break :selected 0;
        } else 0;
        select(start_position, false);
    }
    if (s.index_failure) |err| notice("{s}", .{@errorName(err)});
    if (s.cli.smoke and s.entries.len >= 3) {
        for (0..2000) |i| select(if (i % 2 == 0) 0 else 2, false);
    }
    pump();
}

fn append(buffer: []u8, used: *usize, comptime format: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(buffer[used.*..], format, args) catch return;
    used.* += text.len;
}
fn updateOverlay() void {
    if (s.overlay.value == null) return;
    s.overlay.msgSend(void, "setHidden:", .{!s.show_info and !s.show_help and !s.show_actions and !s.show_filename});
    if (!s.show_info and !s.show_help and !s.show_actions and !s.show_filename) return;
    var buffer: [24576]u8 = undefined;
    var used: usize = 0;
    if (s.show_help) {
        append(&buffer, &used, "Yekk shortcuts — ? or Escape to dismiss\n\n", .{});
        for (s.settings.bindings[0..s.settings.binding_count]) |binding| {
            var key: [1]u8 = .{@truncate(binding.key)};
            const name = actions.keyName(binding.key);
            append(&buffer, &used, "{s}{s}{s}{s}{s}  {s}\n", .{ if (binding.modifiers & actions.command != 0) "Cmd+" else "", if (binding.modifiers & actions.shift != 0) "Shift+" else "", if (binding.modifiers & actions.option != 0) "Alt+" else "", if (binding.modifiers & actions.control != 0) "Ctrl+" else "", if (name.len == 0) &key else name, @tagName(binding.action) });
        }
        append(&buffer, &used, "\nAll actions are available in the Actions menu.\nConfig: ~/.config/yekk/config\nSyntax: bind Cmd+e = external\n", .{});
    } else {
        append(&buffer, &used, "{s}\n", .{s.displayed_path});
        if (s.show_info) if (s.current) |image| append(&buffer, &used, "{d} × {d} source · {d} × {d} decoded · {d}-bit\nZoom {d:.1}% · {d}/{d}\nResident cache {d:.1} MiB · {d} decodes · {d} hits\n{s} pressure · watch {any} · keep view {any}\n", .{ image.source_width, image.source_height, image.width, image.height, image.bits_per_component, s.geometry.scale * 100, (position(s.displayed.?) orelse 0) + 1, s.entries.len, @as(f64, @floatFromInt(s.resident_bytes)) / (1024 * 1024), s.decode_count, s.cache_hits, @tagName(s.pressure), s.settings.watch, s.settings.keep_view });
        if (s.show_actions) for (&s.settings.hooks, 0..) |*hook, number| {
            if (hook.len > 0) append(&buffer, &used, "{d}: {s}\n", .{ number, if (hook.title_len > 0) hook.title() else hook.body() });
        };
        if (s.notice_len > 0) append(&buffer, &used, "{s}\n", .{s.notice[0..s.notice_len]});
        if (s.desired != null and s.desired != s.displayed) append(&buffer, &used, "Pending: {s}\n", .{(entry(s.desired.?) orelse return).path});
    }
    setText(s.overlay, "setStringValue:", buffer[0..used]);
    const bounds = s.view.msgSend(n.Rect, "bounds", .{});
    s.overlay.msgSend(void, "setFrame:", .{n.rect(16, 16, @max(1, bounds.size.width - 32), @max(1, @min(bounds.size.height - 32, if (s.show_help) @as(f64, 900) else 180)))});
}

fn configureTimer() void {
    const needed = s.settings.watch or s.slideshow_running or s.cli.benchmark;
    if (needed and s.timer.value == null) {
        s.timer = cls("NSTimer").msgSend(O, "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", .{ @as(f64, if (s.cli.benchmark) 1.0 / 120.0 else 0.25), s.delegate, objc.sel("tick:"), nil, true });
        s.timer.msgSend(void, "setTolerance:", .{@as(f64, if (s.cli.benchmark) 0 else 0.05)});
    } else if (!needed and s.timer.value != null) {
        s.timer.msgSend(void, "invalidate", .{});
        s.timer = nil;
    }
}
fn tick(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    if (s.closing) return;
    const now = n.now();
    if (s.cli.benchmark) {
        if (s.heartbeat_last > 0) s.heartbeat_worst_ms = @max(s.heartbeat_worst_ms, (now - s.heartbeat_last) * 1000);
        s.heartbeat_last = now;
        s.heartbeat_count += 1;
    }
    if (s.slideshow_running and now - s.last_slide >= s.settings.interval and s.desired != null) {
        const id = s.desired.?;
        const failed = s.cached[id].failed_version == s.cached[id].version;
        if (failed) s.slide_failures += 1;
        if (s.slide_failures >= s.entries.len) {
            s.slideshow_running = false;
            configureTimer();
            notice("Slideshow stopped: no readable images", .{});
        } else if (failed or (s.current != null and s.desired == s.displayed)) {
            s.last_slide = now;
            if (!s.settings.slideshow_loop and position(id) == s.entries.len - 1) {
                s.slideshow_running = false;
                configureTimer();
            } else navigate(1, true);
        }
    }
    if (s.settings.watch and s.indexed and !s.watch.busy and now - s.last_watch >= s.settings.watch_seconds) {
        s.last_watch = now;
        s.watch.count = 0;
        if (s.desired) |id| if (entry(id)) |e| {
            s.watch.items[0] = .{ .entry = e, .stamp = .{} };
            s.watch.count = 1;
        };
        var tried: usize = 0;
        while (s.watch.count < s.watch.items.len and tried < s.entries.len) : (tried += 1) {
            if (s.entries.len == 0) break;
            const e = s.entries[s.watch.cursor % s.entries.len];
            s.watch.cursor += 1;
            if (s.desired == e.id) continue;
            if (s.cached[e.id].image != null) {
                s.watch.items[s.watch.count] = .{ .entry = e, .stamp = .{} };
                s.watch.count += 1;
            }
        }
        if (s.watch.count > 0) {
            s.watch.busy = true;
            n.dispatch_async_f(n.dispatch_get_global_queue(0x11, 0), s, watchWorker);
        }
    }
}
fn watchWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    for (s.watch.items[0..s.watch.count]) |*item| item.stamp = (Stamp.read(item.entry.path) orelse Stamp{});
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, watched);
}
fn watched(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.watch.busy = false;
    if (!s.closing) for (s.watch.items[0..s.watch.count]) |item| {
        if (!std.meta.eql(item.stamp, s.stamps[item.entry.id]) or (s.desired == item.entry.id and s.cached[item.entry.id].failed_version == s.cached[item.entry.id].version and !isMemoryFailure(s.cached[item.entry.id].failure))) {
            s.stamps[item.entry.id] = item.stamp;
            const r = &s.cached[item.entry.id];
            r.version += 1;
            r.failed_version = 0;
        }
    };
    pump();
}
fn runHook(number: usize) void {
    if (s.hook.busy) {
        notice("A command action is still running", .{});
        return;
    }
    const command = &s.settings.hooks[number];
    if (command.len == 0) return;
    if (!s.indexed or s.current == null or s.desired != s.displayed) {
        notice("Wait for the selected image to finish loading", .{});
        return;
    }
    const id = s.displayed.?;
    const image = s.current.?;
    const path = (entry(id) orelse return).path;
    const vp = viewport();
    s.hook.snapshot = (hooks.Snapshot{
        .path = path,
        .width = image.source_width,
        .height = image.source_height,
        .bytes = @intCast(@max(0, s.stamps[id].bytes)),
        .index = (position(id) orelse 0) + 1,
        .count = s.entries.len,
        .rotation = s.cached[id].rotation,
        .playing = s.slideshow_running,
        .pid = c.getpid(),
    }).withView(.{ .scale = s.geometry.scale, .pan_x = s.geometry.pan_x, .pan_y = -s.geometry.pan_y }, vp);
    s.hook.template = command.*;
    s.hook.manifest_count = 0;
    if (hooks.needsManifest(command.body())) {
        for (s.entries, 0..) |e, i| s.hook_paths[i] = e.path;
        s.hook.manifest_count = s.entries.len;
    }
    s.hook.busy = true;
    s.hook.id = id;
    s.hook.selection = s.selection_revision;
    s.hook.reload = command.reload;
    s.hook.path = path;
    s.hook.failure = null;
    notice("Running action {d}: {s}", .{ number, command.title() });
    n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, hookWorker);
}
fn executeHook() !commands.Result {
    var snapshot = s.hook.snapshot;
    var meta = if (hooks.usesSpecifier(s.hook.template.body(), 't')) decoder.metadata(s.hook.path) catch null else null;
    if (meta) |*value| snapshot.image_format = value.format[0..value.format_len];
    return @import("hook_execution.zig").run(&s.hook.command, s.hook.template, snapshot, .{ .paths = s.hook_paths[0..s.hook.manifest_count] }, &s.cancel);
}

fn hookWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    s.hook.result = executeHook() catch |err| failed: {
        s.hook.failure = err;
        break :failed .{};
    };
    s.hook.exists = @import("source").exists(s.hook.path);
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, hookDone);
}
fn hookDone(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.hook.busy = false;
    if (!s.closing) {
        s.notice_len = 0;
        const job = &s.hook;
        const still_selected = s.desired == job.id and s.selection_revision == job.selection;
        if (!job.exists) {
            removeEntry(job.id);
        } else if (job.result.success() and job.failure == null and still_selected) {
            if (job.reload) {
                if (position(job.id)) |p| select(p, true);
            } else navigate(1, false);
        }
        if (job.failure) |err| notice("Command action: {s}", .{@errorName(err)}) else if (!job.result.success()) {
            if (job.result.exitCode()) |code| notice("Command failed (exit {d}): {s}", .{ code, job.result.output[0..@min(job.result.len, 800)] }) else notice("Command terminated (signal {d})", .{job.result.status & 0x7f});
        } else notice("Command action completed", .{});
    }
    pump();
}

fn auxiliary(kind: Auxiliary) void {
    auxiliaryForId(kind, s.displayed orelse return);
}
fn auxiliaryForId(kind: Auxiliary, id: usize) void {
    if (s.aux.busy) {
        notice("A file operation is still running", .{});
        return;
    }
    const e = entry(id) orelse return;
    s.aux = .{ .busy = true, .kind = kind, .path = e.path, .id = id };
    n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, auxiliaryWorker);
}
fn auxiliaryWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    switch (s.aux.kind) {
        .reveal => {
            const urls = cls("NSArray").msgSend(O, "arrayWithObject:", .{url(s.aux.path)});
            cls("NSWorkspace").msgSend(O, "sharedWorkspace", .{}).msgSend(void, "activateFileViewerSelectingURLs:", .{urls});
            s.aux.success = true;
        },
        .external => {
            s.aux.success = cls("NSWorkspace").msgSend(O, "sharedWorkspace", .{}).msgSend(bool, "openURL:", .{url(s.aux.path)});
        },
        .trash => {
            s.aux.success = cls("NSFileManager").msgSend(O, "defaultManager", .{}).msgSend(bool, "trashItemAtURL:resultingItemURL:error:", .{ url(s.aux.path), @as(?*objc.c.id, null), @as(?*objc.c.id, null) });
        },
        .snapshot => {
            const image = s.aux.native_image.?;
            defer n.CFRelease(image);
            const path = s.aux.path;
            const file = n.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0);
            if (file) |target| {
                defer n.CFRelease(target);
                const png = string("public.png");
                defer png.release();
                if (n.CGImageDestinationCreateWithURL(target, @ptrCast(png.value.?), 1, null)) |destination| {
                    defer n.CFRelease(destination);
                    n.CGImageDestinationAddImage(destination, image, null);
                    s.aux.success = n.CGImageDestinationFinalize(destination) != 0;
                }
            }
        },
    }
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, auxiliaryDone);
}
fn auxiliaryDone(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.aux.busy = false;
    if (!s.closing) {
        if (s.aux.success and s.aux.kind == .trash and s.aux.id != null) removeEntry(s.aux.id.?);
        notice("{s}", .{if (s.aux.success) "Operation complete" else "Operation failed"});
    }
    pump();
}
fn launchSelection(paths: O) void {
    const previous = s;
    defer s = previous;
    openSelection(paths) catch |err| {
        s = previous;
        notice("Cannot open session: {s}", .{@errorName(err)});
    };
}
fn openSelection(paths: O) !void {
    if (!paths.msgSend(bool, "isKindOfClass:", .{cls("NSArray")})) return error.InvalidSelection;
    const count = paths.msgSend(usize, "count", .{});
    if (count == 0) return;
    if (count > catalog.capacity) return error.InputCapacityExceeded;
    var target: ?*State = null;
    for (&root.sessions, control.active) |*candidate, active| {
        if (active and !candidate.closing and !candidate.indexing and !candidate.indexed and (candidate.input_count == 0 or candidate.cli.default_directory)) {
            target = candidate;
            break;
        }
    }
    var created = false;
    if (target == null) {
        for (&root.sessions, control.active, 0..) |*candidate, active, slot| {
            if (!active) {
                initState(candidate, slot, s.limits);
                candidate.cli.smoke = s.cli.smoke_windows;
                control.active[slot] = true;
                target = candidate;
                created = true;
                break;
            }
        }
    }
    s = target orelse return error.SessionCapacityExceeded;
    s.cli.default_directory = false;
    s.native_inputs = paths.msgSend(O, "copy", .{});
    s.input_count = count;
    s.options.browse = count == 1;
    if (created) try launch() else startIndex();
}
fn startIndex() void {
    s.indexing = true;
    s.catalog.cancel = &s.cancel;
    s.catalog.on_initial = if (s.options.sort != null or s.options.reverse or s.options.shuffle or s.options.start_at != null or s.cli.filelist != null) null else initialIndexed;
    n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, indexWorker);
}

const OpenCompletion = objc.Block(struct { session: *State }, .{i64}, void);
fn openCompleted(context: *const OpenCompletion.Context, response: i64) callconv(.c) void {
    const previous = s;
    defer s = previous;
    s = context.session;
    const panel = s.open_panel;
    s.open_panel = nil;
    s.pending_sheets -= 1;
    if (response == 1 and !s.closing) {
        const urls = panel.msgSend(O, "URLs", .{});
        const paths = cls("NSMutableArray").msgSend(O, "new", .{});
        defer paths.release();
        for (0..urls.msgSend(usize, "count", .{})) |i| paths.msgSend(void, "addObject:", .{urls.msgSend(O, "objectAtIndex:", .{i}).msgSend(O, "path", .{})});
        launchSelection(paths);
    }
    panel.release();
    pump();
}
fn openDialog() void {
    if (s.open_panel.value != null) return;
    s.open_panel = cls("NSOpenPanel").msgSend(O, "openPanel", .{}).retain();
    s.pending_sheets += 1;
    s.open_panel.msgSend(void, "setCanChooseDirectories:", .{true});
    s.open_panel.msgSend(void, "setCanChooseFiles:", .{true});
    s.open_panel.msgSend(void, "setAllowsMultipleSelection:", .{true});
    const handler = OpenCompletion.init(.{ .session = s }, openCompleted);
    s.open_panel.msgSend(void, "beginSheetModalForWindow:completionHandler:", .{ s.window, &handler });
}
const TrashCompletion = objc.Block(struct { session: *State }, .{i64}, void);
fn trashConfirmed(context: *const TrashCompletion.Context, response: i64) callconv(.c) void {
    const previous = s;
    defer s = previous;
    s = context.session;
    s.pending_sheets -= 1;
    s.alert.release();
    s.alert = nil;
    if (response == 1000 and !s.closing) if (s.trash_id) |id| {
        auxiliaryForId(.trash, id);
    };
    s.trash_id = null;
    pump();
}
fn confirmTrash() void {
    if (s.current == null or s.alert.value != null) return;
    const alert = cls("NSAlert").msgSend(O, "new", .{});
    s.alert = alert;
    s.trash_id = s.displayed;
    s.pending_sheets += 1;
    setText(alert, "setMessageText:", "Move this image to Trash?");
    setText(alert, "setInformativeText:", s.displayed_path);
    const yes = string("Move to Trash");
    defer yes.release();
    const no = string("Cancel");
    defer no.release();
    _ = alert.msgSend(O, "addButtonWithTitle:", .{yes});
    _ = alert.msgSend(O, "addButtonWithTitle:", .{no});
    const handler = TrashCompletion.init(.{ .session = s }, trashConfirmed);
    alert.msgSend(void, "beginSheetModalForWindow:completionHandler:", .{ s.window, &handler });
}
fn removeEntry(id: usize) void {
    if (s.desired == id or s.displayed == id) {
        s.render_revision += 1;
        s.render_wanted = null;
    }
    if (!s.indexed) return;
    const p = position(id) orelse return;
    s.positions[id] = std.math.maxInt(usize);
    std.mem.copyForwards(Entry, s.entries[p .. s.entries.len - 1], s.entries[p + 1 ..]);
    s.entries = s.entries[0 .. s.entries.len - 1];
    for (s.entries, 0..) |e, i| s.positions[e.id] = i;
    s.cached[id].version += 1;
    if (s.entries.len > 0) {
        if (s.desired == id) select(@min(p, s.entries.len - 1), false) else {
            status();
            pump();
        }
    } else {
        s.desired = null;
        s.displayed = null;
        s.layer.msgSend(void, "setContents:", .{nil});
        if (s.current) |image| {
            std.debug.assert(enqueueRelease(image));
            s.current = null;
        }
        status();
    }
}
fn background() void {
    // Native pattern colors render the transparency backdrop without an app
    // redraw loop. A tiny native image is created only when toggled.
    if (!s.settings.checker) {
        s.window.msgSend(void, "setBackgroundColor:", .{cls("NSColor").msgSend(O, "colorWithWhite:alpha:", .{ @as(f64, 0.08), @as(f64, 1) })});
        return;
    }
    const size: n.Size = .{ .width = 16, .height = 16 };
    const image = cls("NSImage").msgSend(O, "alloc", .{}).msgSend(O, "initWithSize:", .{size});
    defer image.release();
    image.msgSend(void, "lockFocus", .{});
    cls("NSColor").msgSend(O, "colorWithWhite:alpha:", .{ @as(f64, 0.25), @as(f64, 1) }).msgSend(void, "setFill", .{});
    NSRectFill(n.rect(0, 0, 16, 16));
    cls("NSColor").msgSend(O, "colorWithWhite:alpha:", .{ @as(f64, 0.4), @as(f64, 1) }).msgSend(void, "setFill", .{});
    NSRectFill(n.rect(0, 0, 8, 8));
    NSRectFill(n.rect(8, 8, 8, 8));
    image.msgSend(void, "unlockFocus", .{});
    s.window.msgSend(void, "setBackgroundColor:", .{cls("NSColor").msgSend(O, "colorWithPatternImage:", .{image})});
}
extern "c" fn NSRectFill(n.Rect) void;
fn perform(action: Action) void {
    var view = s.geometry;
    // AppKit's view coordinates have positive Y upward.
    view.pan_y = -view.pan_y;
    if (view_actions.apply(action, &s.settings, &view, viewport())) {
        view.pan_y = -view.pan_y;
        s.geometry = view;
        layout();
        ensureDetail();
        return;
    }
    switch (action) {
        .menu => showMenu(s.app.msgSend(O, "currentEvent", .{})),
        .render => {
            s.nearest = false;
            layout();
        },
        .action_0, .action_1, .action_2, .action_3, .action_4, .action_5, .action_6, .action_7, .action_8, .action_9 => runHook(@intCast(@backingInt(action) - @backingInt(Action.action_0))),
        .draw_actions => {
            s.show_actions = !s.show_actions;
            updateOverlay();
        },
        .draw_filename => {
            s.show_filename = !s.show_filename;
            updateOverlay();
        },
        .reload_plus, .reload_minus => {
            view_actions.reloadInterval(&s.settings, action == .reload_plus);
            configureTimer();
            notice("Reload interval: {d:.1}s", .{s.settings.watch_seconds});
        },
        .random => if (s.entries.len > 0) {
            select(s.catalog.random.random().uintLessThan(usize, s.entries.len), false);
        },
        .jump_forward => if (s.desired) |id| {
            select(navigation.jump(position(id) orelse 0, s.entries.len, true), false);
        },
        .jump_back => if (s.desired) |id| {
            select(navigation.jump(position(id) orelse 0, s.entries.len, false), false);
        },
        .next_directory, .previous_directory => {
            const p = position(s.desired orelse return) orelse return;
            if (navigation.directory(s.entries, null, p, action == .next_directory)) |target| select(target, false);
        },
        .next => navigate(1, false),
        .previous => navigate(-1, false),
        .first => select(0, false),
        .last => if (s.entries.len > 0) {
            select(s.entries.len - 1, false);
        },
        .close => close(),
        .quit => closeAll(),
        .open => openDialog(),
        .fullscreen => s.window.msgSend(void, "toggleFullScreen:", .{nil}),
        .reload => if (s.desired) |id| {
            if (position(id)) |p| select(p, true);
        },
        .rotate_right, .rotate_left, .mirror_horizontal, .mirror_vertical => if (s.displayed) |id| {
            const r = &s.cached[id];
            var mirror: u2 = @as(u2, @intFromBool(r.mirror_x)) | (@as(u2, @intFromBool(r.mirror_y)) << 1);
            _ = view_actions.transform(action, &r.rotation, &mirror);
            r.mirror_x = mirror & 1 != 0;
            r.mirror_y = mirror & 2 != 0;
            layout();
        },
        .info => {
            s.show_info = !s.show_info;
            s.show_help = false;
            updateOverlay();
        },
        .help => {
            s.show_help = !s.show_help;
            updateOverlay();
        },
        .nearest => {
            s.nearest = !s.nearest;
            const filter = string(if (s.nearest) "nearest" else "trilinear");
            const magnification = string(if (s.nearest) "nearest" else "linear");
            defer magnification.release();
            defer filter.release();
            s.layer.msgSend(void, "setMagnificationFilter:", .{magnification});
            s.layer.msgSend(void, "setMinificationFilter:", .{filter});
            layout();
        },
        .background => {
            s.settings.checker = !s.settings.checker;
            background();
        },
        .wrap => {
            s.settings.wrap = !s.settings.wrap;
            pump();
        },
        .keep_view => {
            s.settings.keep_view = !s.settings.keep_view;
            status();
        },
        .watch => {
            s.settings.watch = !s.settings.watch;
            configureTimer();
            status();
        },
        .slideshow => {
            s.slideshow_running = !s.slideshow_running;
            if (s.settings.interval <= 0) s.settings.interval = 3;
            s.last_slide = n.now();
            configureTimer();
        },
        .reveal => auxiliary(.reveal),
        .external => auxiliary(.external),
        .remove => if (s.displayed) |id| {
            removeEntry(id);
        },
        .trash => confirmTrash(),
        .resize_window => if (s.current) |image| {
            const size = sourceSize(image);
            const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
            const screen = s.window.msgSend(O, "screen", .{}).msgSend(n.Rect, "visibleFrame", .{});
            s.window.msgSend(void, "setContentSize:", .{n.Size{ .width = @min(screen.size.width, size.width / backing), .height = @min(screen.size.height - 40, size.height / backing) }});
        },
        else => unreachable, // View actions returned through the shared handler above.
    }
}
fn ensureDetail() void {
    if (s.current) |image| {
        const displayed = s.displayed orelse return;
        if (s.desired != displayed) return;
        if (!adequate(displayed, image)) pump();
    }
}
fn resized(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    layout();
    ensureDetail();
}
fn accepts(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}
fn stopHeldAdvance() void {
    s.held_advance.cancel();
    s.advance_display_link.msgSend(void, "setPaused:", .{true});
}
fn scheduleHeldAdvance() void {
    if (!s.held_advance.pending()) return;
    if (s.advance_display_link.value == null) {
        const link = s.view.msgSend(O, "displayLinkWithTarget:selector:", .{ s.delegate, objc.sel("advanceFrame:") });
        if (link.value == null) return;
        s.advance_display_link = link.msgSend(O, "retain", .{});
        const run_loop = cls("NSRunLoop").msgSend(O, "mainRunLoop", .{});
        const mode: O = .{ .value = @ptrCast(@alignCast(@constCast(n.NSRunLoopCommonModes))) };
        link.msgSend(void, "addToRunLoop:forMode:", .{ run_loop, mode });
    }
    s.advance_display_link.msgSend(void, "setPaused:", .{false});
}
fn advanceFrame(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    if (s.closing) return;
    const link: O = .{ .value = raw };
    // timestamp is the refresh that has passed, not the next target refresh.
    const through = link.msgSend(f64, "timestamp", .{});
    if (std.math.isFinite(through)) if (s.held_advance.take(through)) |direction| {
        perform(if (direction == .next) .next else .previous);
    };
    if (!s.held_advance.pending()) s.advance_display_link.msgSend(void, "setPaused:", .{true});
}
fn keyUp(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const event: O = .{ .value = raw };
    s.held_advance.release(event.msgSend(u16, "keyCode", .{}));
    if (!s.held_advance.pending()) s.advance_display_link.msgSend(void, "setPaused:", .{true});
}
fn resignedKey(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    stopHeldAdvance();
}
fn keyDown(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const event: O = .{ .value = raw };
    const chars = event.msgSend(O, "charactersIgnoringModifiers", .{});
    if (chars.msgSend(usize, "length", .{}) == 0) return;
    const key = chars.msgSend(u16, "characterAtIndex:", .{@as(usize, 0)});
    const repeated = event.msgSend(bool, "isARepeat", .{});
    const action = s.settings.lookup(key, event.msgSend(usize, "modifierFlags", .{}));
    if (action == .next or action == .previous) {
        const direction: navigation.HeldAdvance.Direction = if (action == .next) .next else .previous;
        const code = event.msgSend(u16, "keyCode", .{});
        if (repeated) {
            s.held_advance.repeat(code, direction);
            scheduleHeldAdvance();
        } else {
            stopHeldAdvance();
            s.held_advance.press(code, direction);
            perform(action.?);
        }
        return;
    }
    if (!repeated) stopHeldAdvance();
    if (key == 0x1B) {
        if (s.show_help or s.show_info) {
            s.show_help = false;
            s.show_info = false;
            updateOverlay();
        } else if (action) |bound| perform(bound);
    } else if (action) |bound| perform(bound);
}
fn scroll(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const event: O = .{ .value = raw };
    const dx = event.msgSend(f64, "scrollingDeltaX", .{});
    const dy = event.msgSend(f64, "scrollingDeltaY", .{});
    const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
    if (event.msgSend(usize, "modifierFlags", .{}) & actions.command != 0) {
        const p = s.view.msgSend(n.Point, "convertPoint:fromView:", .{ event.msgSend(n.Point, "locationInWindow", .{}), nil });
        const vp = viewport();
        s.geometry.zoom(@exp(std.math.clamp(dy * 0.02, -1, 1)), p.x * backing - vp.width / 2, p.y * backing - vp.height / 2);
        layout();
        ensureDetail();
    } else if (!event.msgSend(bool, "hasPreciseScrollingDeltas", .{}) and dy != 0) {
        navigate(if (dy > 0) -1 else 1, false);
    } else {
        s.geometry.pan_x -= dx * backing;
        s.geometry.pan_y += dy * backing;
        layout();
    }
}
fn magnify(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const event: O = .{ .value = raw };
    const p = s.view.msgSend(n.Point, "convertPoint:fromView:", .{ event.msgSend(n.Point, "locationInWindow", .{}), nil });
    const vp = viewport();
    const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
    s.geometry.zoom(@max(0.1, 1 + event.msgSend(f64, "magnification", .{})), p.x * backing - vp.width / 2, p.y * backing - vp.height / 2);
    layout();
    ensureDetail();
}
fn mouseDown(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    s.mouse_moved = false;
    s.dragging = (O{ .value = raw }).msgSend(n.Point, "locationInWindow", .{});
    s.mouse_origin = s.dragging.?;
}
fn mouseUp(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    if (s.dragging != null and !s.mouse_moved) navigate(1, false);
    s.dragging = null;
}
fn mouseDragged(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const p = (O{ .value = raw }).msgSend(n.Point, "locationInWindow", .{});
    if (s.dragging) |last| {
        s.mouse_moved = s.mouse_moved or @abs(p.x - s.mouse_origin.x) > 2 or @abs(p.y - s.mouse_origin.y) > 2;
        const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
        s.geometry.pan_x += (p.x - last.x) * backing;
        s.geometry.pan_y += (p.y - last.y) * backing;
        layout();
    }
    s.dragging = p;
}
fn showMenu(event: O) void {
    if (event.value == null) return;
    menus();
    const main = s.app.msgSend(O, "mainMenu", .{});
    const name = string("Actions");
    defer name.release();
    const item = main.msgSend(O, "itemWithTitle:", .{name});
    if (item.value == null) return;
    cls("NSMenu").msgSend(void, "popUpContextMenu:withEvent:forView:", .{ item.msgSend(O, "submenu", .{}), event, s.view });
}
fn rightMouseDown(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    stopHeldAdvance();
    showMenu(.{ .value = raw });
}
fn middleMouseDown(self: objc.c.id, selector: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const event: O = .{ .value = raw };
    if (event.msgSend(i64, "buttonNumber", .{}) != 2) return;
    mouseDown(self, selector, raw);
    const previous = s;
    defer s = previous;
    useSession(self);
    s.middle_zoom = true;
}
fn middleMouseDragged(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    if (!s.middle_zoom) return;
    const point = (O{ .value = raw }).msgSend(n.Point, "locationInWindow", .{});
    if (s.dragging) |last| {
        s.mouse_moved = s.mouse_moved or @abs(point.x - s.mouse_origin.x) > 2;
        const anchor = s.view.msgSend(n.Point, "convertPoint:fromView:", .{ s.mouse_origin, nil });
        const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
        const vp = viewport();
        s.geometry.zoom(@exp(std.math.clamp((point.x - last.x) * 0.01, -1, 1)), anchor.x * backing - vp.width / 2, anchor.y * backing - vp.height / 2);
        layout();
        ensureDetail();
    }
    s.dragging = point;
}
fn middleMouseUp(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    if (s.middle_zoom and !s.mouse_moved) perform(.actual);
    s.middle_zoom = false;
    s.dragging = null;
}
fn actionClicked(self: objc.c.id, _: objc.c.SEL, sender: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const tag = (O{ .value = sender }).msgSend(isize, "tag", .{});
    if (tag >= 0 and tag < @typeInfo(Action).@"enum".field_names.len) perform(@fromBackingInt(@intCast(tag)));
}
fn dragEntered(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) u64 {
    return 1;
}
fn dragPerformed(self: objc.c.id, _: objc.c.SEL, sender: objc.c.id) callconv(.c) bool {
    const previous = s;
    defer s = previous;
    useSession(self);
    const board = (O{ .value = sender }).msgSend(O, "draggingPasteboard", .{});
    const type_name = string("NSFilenamesPboardType");
    defer type_name.release();
    const paths = board.msgSend(O, "propertyListForType:", .{type_name});
    if (paths.value == null) return false;
    launchSelection(paths);
    return true;
}
fn finderOpen(_: objc.c.id, _: objc.c.SEL, _: objc.c.id, paths_raw: objc.c.id) callconv(.c) void {
    if (sessions.route(control.cli_inputs, control.finished_launching, false, 0) != .ignore_cli_replay) launchSelection(.{ .value = paths_raw });
    control.app.msgSend(void, "replyToOpenOrPrint:", .{@as(usize, 0)});
}
fn didFinishLaunching(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    control.finished_launching = true;
    const previous = s;
    defer s = previous;
    for (&root.sessions, control.active) |*session, active| if (active and session.cli.default_directory and !session.indexing) {
        s = session;
        s.cli.default_directory = false;
        startIndex();
    };
}
fn closeAll() void {
    const previous = s;
    defer s = previous;
    for (&root.sessions, control.active) |*candidate, active| if (active) {
        s = candidate;
        close();
    };
}
fn shouldTerminate(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) u64 {
    closeAll();
    return 0;
}
fn becameKey(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    menus();
}

fn addMethod(class: objc.Class, comptime name: [:0]const u8, implementation: anytype) void {
    if (!class.addMethod(name, implementation)) @panic("cannot register native callback");
}
fn menus() void {
    const menu = cls("NSMenu").msgSend(O, "new", .{});
    defer menu.release();
    const app_item = cls("NSMenuItem").msgSend(O, "new", .{});
    defer app_item.release();
    const app_menu = cls("NSMenu").msgSend(O, "new", .{});
    defer app_menu.release();
    addMenuAction(app_menu, .quit, "Quit Yekk");
    app_item.msgSend(void, "setSubmenu:", .{app_menu});
    menu.msgSend(void, "addItem:", .{app_item});
    const actions_item = cls("NSMenuItem").msgSend(O, "new", .{});
    defer actions_item.release();
    setText(actions_item, "setTitle:", "Actions");
    const action_menu = cls("NSMenu").msgSend(O, "new", .{});
    defer action_menu.release();
    setText(action_menu, "setTitle:", "Actions");
    inline for (@typeInfo(Action).@"enum".field_names, @typeInfo(Action).@"enum".field_values) |name, value| {
        var label: [64]u8 = undefined;
        @memcpy(label[0..name.len], name);
        for (label[0..name.len]) |*ch| if (ch.* == '_') {
            ch.* = ' ';
        };
        label[0] = std.ascii.toUpper(label[0]);
        addMenuAction(action_menu, @fromBackingInt(@intCast(value)), label[0..name.len]);
    }
    actions_item.msgSend(void, "setSubmenu:", .{action_menu});
    menu.msgSend(void, "addItem:", .{actions_item});
    s.app.msgSend(void, "setMainMenu:", .{menu});
}
fn addMenuAction(menu: O, action: Action, label: []const u8) void {
    const title_text = string(label);
    defer title_text.release();
    var key: [1]u8 = undefined;
    var key_text: []const u8 = "";
    var modifiers: usize = actions.command;
    for (s.settings.bindings[0..s.settings.binding_count]) |binding| {
        if (binding.action == action and binding.modifiers & actions.command != 0 and binding.key <= 127) {
            key[0] = @intCast(binding.key);
            key_text = &key;
            modifiers = binding.modifiers;
            break;
        }
    }
    const equivalent = string(key_text);
    defer equivalent.release();
    const item = menu.msgSend(O, "addItemWithTitle:action:keyEquivalent:", .{ title_text, objc.sel("performAction:"), equivalent });
    item.msgSend(void, "setTarget:", .{s.delegate});
    item.msgSend(void, "setTag:", .{@as(isize, @backingInt(action))});
    item.msgSend(void, "setKeyEquivalentModifierMask:", .{modifiers});
}
fn nativeBool(value: anytype) bool {
    return switch (@TypeOf(value)) {
        bool => value,
        else => value != 0,
    };
}
fn initializeNative() !void {
    const window_class = objc.allocateClassPair(cls("NSWindow"), "YekkWindow") orelse return error.NativeInitialization;
    addMethod(window_class, "canBecomeKeyWindow", accepts);
    addMethod(window_class, "canBecomeMainWindow", accepts);
    objc.registerClassPair(window_class);
    control.window_class = window_class;
    const delegate_class = objc.allocateClassPair(cls("NSObject"), "YekkDelegate") orelse return error.NativeInitialization;
    addMethod(delegate_class, "windowWillClose:", windowWillClose);
    addMethod(delegate_class, "windowDidResize:", resized);
    addMethod(delegate_class, "windowDidChangeBackingProperties:", resized);
    addMethod(delegate_class, "performAction:", actionClicked);
    addMethod(delegate_class, "tick:", tick);
    addMethod(delegate_class, "windowDidBecomeKey:", becameKey);
    addMethod(delegate_class, "windowDidResignKey:", resignedKey);
    addMethod(delegate_class, "advanceFrame:", advanceFrame);
    if (!nativeBool(c.class_addIvar(delegate_class.value, "yekkState", @sizeOf(*State), 3, "^v"))) return error.NativeInitialization;
    objc.registerClassPair(delegate_class);
    control.session_class = delegate_class;
    const view_class = objc.allocateClassPair(cls("NSView"), "YekkView") orelse return error.NativeInitialization;
    addMethod(view_class, "acceptsFirstResponder", accepts);
    addMethod(view_class, "keyDown:", keyDown);
    addMethod(view_class, "keyUp:", keyUp);
    addMethod(view_class, "scrollWheel:", scroll);
    addMethod(view_class, "magnifyWithEvent:", magnify);
    addMethod(view_class, "mouseDown:", mouseDown);
    addMethod(view_class, "mouseDragged:", mouseDragged);
    addMethod(view_class, "mouseUp:", mouseUp);
    addMethod(view_class, "rightMouseDown:", rightMouseDown);
    addMethod(view_class, "otherMouseDown:", middleMouseDown);
    addMethod(view_class, "otherMouseDragged:", middleMouseDragged);
    addMethod(view_class, "otherMouseUp:", middleMouseUp);
    addMethod(view_class, "draggingEntered:", dragEntered);
    addMethod(view_class, "performDragOperation:", dragPerformed);
    if (!nativeBool(c.class_addIvar(view_class.value, "yekkState", @sizeOf(*State), 3, "^v"))) return error.NativeInitialization;
    objc.registerClassPair(view_class);
    control.view_class = view_class;
    control.app = cls("NSApplication").msgSend(O, "sharedApplication", .{});
    _ = control.app.msgSend(bool, "setActivationPolicy:", .{@as(isize, 0)});
    const app_class = objc.allocateClassPair(cls("NSObject"), "YekkApplicationDelegate") orelse return error.NativeInitialization;
    addMethod(app_class, "application:openFiles:", finderOpen);
    addMethod(app_class, "applicationDidFinishLaunching:", didFinishLaunching);
    addMethod(app_class, "applicationShouldTerminate:", shouldTerminate);
    objc.registerClassPair(app_class);
    control.delegate = app_class.msgSend(O, "new", .{});
    control.app.msgSend(void, "setDelegate:", .{control.delegate});
    control.initialized = true;
}
fn launch() !void {
    if (!control.initialized) try initializeNative();
    s.app = control.app;
    s.delegate = control.session_class.msgSend(O, "new", .{});
    bindSession(s.delegate);
    s.window = control.window_class.msgSend(O, "alloc", .{}).msgSend(O, "initWithContentRect:styleMask:backing:defer:", .{ n.rect(0, 0, 960, 640), @as(usize, if (s.cli.borderless) 0 else 15), @as(usize, 2), false });
    if (s.window.value == null) return error.NativeInitialization;
    s.window.msgSend(void, "setReleasedWhenClosed:", .{false});
    s.window.msgSend(void, "setDelegate:", .{s.delegate});
    const frame_name = string("YekkSession");
    defer frame_name.release();
    if (s.cli.geometry == null and !s.cli.benchmark and !s.cli.smoke and !s.cli.hook_test and !s.cli.watch_test) _ = s.window.msgSend(bool, "setFrameAutosaveName:", .{frame_name});
    if (s.cli.geometry) |geometry| {
        s.window.msgSend(void, "setContentSize:", .{n.Size{ .width = @floatFromInt(geometry.width), .height = @floatFromInt(geometry.height) }});
        if (geometry.position) |placement| {
            var screen = s.window.msgSend(O, "screen", .{});
            if (screen.value == null) screen = cls("NSScreen").msgSend(O, "mainScreen", .{});
            const visible = screen.msgSend(n.Rect, "visibleFrame", .{});
            const frame = s.window.msgSend(n.Rect, "frame", .{});
            s.window.msgSend(void, "setFrameTopLeftPoint:", .{n.Point{ .x = visible.origin.x + placement.x.resolve(visible.size.width - frame.size.width), .y = visible.origin.y + visible.size.height - placement.y.resolve(visible.size.height - frame.size.height) }});
        }
    }
    s.view = control.view_class.msgSend(O, "alloc", .{}).msgSend(O, "initWithFrame:", .{n.rect(0, 0, 960, 640)});
    bindSession(s.view);
    s.view.msgSend(void, "setWantsLayer:", .{true});
    const root_layer = s.view.msgSend(O, "layer", .{});
    root_layer.msgSend(void, "setMasksToBounds:", .{true});
    s.layer = cls("CALayer").msgSend(O, "new", .{});
    const sampling = string("trilinear");
    defer sampling.release();
    s.layer.msgSend(void, "setMinificationFilter:", .{sampling});
    root_layer.msgSend(void, "addSublayer:", .{s.layer});
    s.window.msgSend(void, "setContentView:", .{s.view});
    _ = s.window.msgSend(bool, "makeFirstResponder:", .{s.view});
    s.overlay = cls("NSTextField").msgSend(O, "alloc", .{}).msgSend(O, "initWithFrame:", .{n.rect(16, 16, 600, 160)});
    s.overlay.msgSend(void, "setEditable:", .{false});
    s.overlay.msgSend(void, "setSelectable:", .{false});
    s.overlay.msgSend(void, "setBezeled:", .{false});
    s.overlay.msgSend(void, "setDrawsBackground:", .{true});
    s.overlay.msgSend(void, "setBackgroundColor:", .{cls("NSColor").msgSend(O, "colorWithWhite:alpha:", .{ @as(f64, 0.05), @as(f64, 0.85) })});
    s.overlay.msgSend(void, "setTextColor:", .{cls("NSColor").msgSend(O, "whiteColor", .{})});
    s.overlay.msgSend(void, "setFont:", .{cls("NSFont").msgSend(O, "monospacedSystemFontOfSize:weight:", .{ @as(f64, 11), @as(f64, 0) })});
    s.overlay.msgSend(void, "setHidden:", .{true});
    s.view.msgSend(void, "addSubview:", .{s.overlay});
    const drag_type = string("NSFilenamesPboardType");
    defer drag_type.release();
    s.view.msgSend(void, "registerForDraggedTypes:", .{cls("NSArray").msgSend(O, "arrayWithObject:", .{drag_type})});
    background();
    menus();
    status();
    s.pressure_source = n.dispatch_source_create(n.pressureType(), 0, 7, n.dispatch_get_main_queue()) orelse return error.NativeInitialization;
    n.dispatch_set_context(s.pressure_source.?, s);
    n.dispatch_source_set_event_handler_f(s.pressure_source.?, pressureChanged);
    n.dispatch_source_set_cancel_handler_f(s.pressure_source.?, pressureCancelled);
    n.dispatch_resume(s.pressure_source.?);
    s.window.msgSend(void, "makeKeyAndOrderFront:", .{nil});
    s.app.msgSend(void, "activateIgnoringOtherApps:", .{true});
    if (s.cli.fullscreen) perform(.fullscreen);
    if ((s.input_count > 0 or s.cli.filelist != null) and !s.cli.default_directory) startIndex();
}
fn automation() void {
    if (!automationReady() or s.automation_queued) return;
    s.automation_queued = true;
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, automated);
}
fn automationReady() bool {
    if (control.memory_recovering or (rendersBusy() and !s.cli.benchmark_pan) or (s.render_wanted != null and s.render_presented_revision != s.render_revision and s.render_failed_revision != s.render_revision) or s.indexing or !s.indexed or s.closing or s.releaser.busy or s.release_count > 0 or s.aux.busy or s.hook.busy or s.pending_sheets > 0) return false;
    if (!s.cli.benchmark_pan and control.speculative_renders != 0) return false;
    for (s.jobs) |job| if (job.busy and !(s.cli.benchmark_pan and job.prefetch and s.current != null and s.displayed == s.desired)) return false;
    if (s.desired) |id| {
        const record = &s.cached[id];
        const ready = record.image != null and record.image_version == record.version;
        if (!ready and record.failed_version != record.version) return false;
        if (ready and s.displayed != id) return false;
    }
    return true;
}
fn smokeKey(key: []const u8, modifiers: usize) void {
    smokeKeyEvent(key, modifiers, .press);
}
fn smokeKeyEvent(key: []const u8, modifiers: usize, kind: enum { press, repeat, release }) void {
    const chars = string(key);
    defer chars.release();
    const event = cls("NSEvent").msgSend(O, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, if (kind == .release) 11 else 10), n.Point{ .x = 0, .y = 0 }, modifiers, @as(f64, 0), s.window.msgSend(isize, "windowNumber", .{}), nil, chars, chars, kind == .repeat, @as(u16, 0) });
    if (kind == .release) s.view.msgSend(void, "keyUp:", .{event}) else s.view.msgSend(void, "keyDown:", .{event});
}
fn snapshotForTest() void {
    const path = s.snapshot_path orelse return;
    if (s.aux.busy) return;
    const vp = viewport();
    const color = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB) orelse return;
    defer n.CFRelease(color);
    const context = n.CGBitmapContextCreate(null, @intFromFloat(vp.width), @intFromFloat(vp.height), 8, 0, color, 0x4001) orelse return;
    defer n.CFRelease(context);
    const scale = s.window.msgSend(f64, "backingScaleFactor", .{});
    n.CGContextScaleCTM(context, scale, scale);
    s.view.msgSend(O, "layer", .{}).msgSend(void, "renderInContext:", .{context});
    const image = n.CGBitmapContextCreateImage(context) orelse return;
    s.aux = .{ .busy = true, .kind = .snapshot, .path = path, .native_image = image };
    n.dispatch_async_f(n.dispatch_get_global_queue(0x11, 0), s, auxiliaryWorker);
}
fn testWindowOpens() void {
    const paths = cls("NSMutableArray").msgSend(O, "new", .{});
    defer paths.release();
    for (s.entries[0..3]) |e| {
        const path = string(e.path);
        paths.msgSend(void, "addObject:", .{path});
        path.release();
    }
    for (0..sessions.capacity + 2) |_| launchSelection(paths);
    var count: usize = 0;
    for (control.active) |active| if (active) {
        count += 1;
    };
    s.smoke_failed = s.smoke_failed or count != sessions.capacity;
}
fn automated(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.automation_queued = false;
    if (s.closing) {
        pump();
        return;
    }
    // Admission/readiness can change between enqueueing and main-queue delivery
    // (for example wakeAll's second pass can start another neighbor prefetch).
    if (!automationReady()) return;
    if (s.entries.len == 0 or ((s.cli.smoke or s.cli.watch_test) and s.entries.len < 3)) {
        s.smoke_failed = true;
        close();
        return;
    }
    if (s.cli.stress_cycles > 0) {
        stressTest();
        return;
    }
    if (s.cli.recovery_test) {
        recoveryTest();
        return;
    }
    if (s.cli.detail_test) {
        detailTest();
        return;
    }
    if (s.cli.hook_test) {
        hookTest();
        return;
    }
    if (s.cli.watch_test) {
        const id = s.entries[2].id;
        if (s.smoke_stage == 0) {
            s.smoke_stage = 1;
            select(2, false);
        } else if (s.smoke_stage == 1) {
            s.smoke_image = s.current;
            s.smoke_stage = 2;
            n.output(1, "WATCH_READY\n");
        } else if (s.smoke_stage == 2 and s.cached[id].failed_version == s.cached[id].version) {
            s.smoke_failed = s.current != s.smoke_image;
            s.smoke_stage = 3;
            n.output(1, "WATCH_RETAINED\n");
        } else if (s.smoke_stage == 3 and s.cached[id].image_version == s.cached[id].version and s.current != s.smoke_image) {
            s.smoke_failed = s.smoke_failed or s.current.?.source_width != 2 or s.current.?.source_height != 1 or s.current.?.bits_per_component != 16;
            n.output(1, "WATCH_RECOVERED\n");
            close();
        }
        return;
    }
    if (s.cli.benchmark) {
        if (s.cli.benchmark_pan) {
            panBenchmark();
            return;
        }
        const count: usize = @min(s.entries.len, 5);
        if (s.benchmark_step == count * 2) s.warm_decodes = s.decode_count;
        if (s.benchmark_step == count * 4) {
            s.warm_redecodes = s.decode_count - s.warm_decodes;
            snapshotForTest();
            close();
            return;
        }
        const phase = s.benchmark_step % (count * 2);
        s.benchmark_step += 1;
        select(if (phase < count) phase else count * 2 - 1 - phase, false);
        return;
    }
    switch (s.smoke_stage) {
        0 => {
            s.smoke_failed = s.current == null or s.displayed != s.entries[2].id;
            s.smoke_image = s.current;
            s.smoke_stage = 1;
            select(1, false);
        },
        1 => {
            s.smoke_failed = s.smoke_failed or s.current != s.smoke_image or s.cached[s.entries[1].id].failed_version == 0;
            s.smoke_stage = 2;
            select(0, false);
        },
        2 => {
            s.smoke_count = s.decode_count;
            s.smoke_stage = 3;
            select(2, false);
        },
        3 => {
            s.smoke_failed = s.smoke_failed or s.decode_count != s.smoke_count;
            smokeKey("*", 0);
            s.smoke_failed = s.smoke_failed or s.geometry.scale != 1;
            perform(.rotate_right);
            perform(.rotate_left);
            perform(.info);
            perform(.help);
            perform(.help);
            perform(.info);
            perform(.background);
            perform(.background);
            s.smoke_stage = if (s.cli.smoke_windows) 5 else 4;
            if (!s.cli.smoke_windows and s.slot == 0) {
                confirmTrash();
                if (s.alert.value != null) s.window.msgSend(void, "endSheet:returnCode:", .{ s.alert.msgSend(O, "window", .{}), @as(i64, 1001) });
            }
            pump();
        },
        4 => {
            smokeKey("n", 0); // Fresh press wraps from image 2 to image 0.
            s.smoke_count = @intCast(s.selection_revision);
            for (0..100) |_| smokeKeyEvent("n", 0, .repeat);
            s.smoke_failed = s.smoke_failed or s.desired != s.entries[0].id or s.selection_revision != s.smoke_count;
            s.smoke_stage = 7; // The real display-link callback must admit one step.
        },
        7 => {
            if (s.desired == s.entries[0].id) return;
            s.smoke_failed = s.smoke_failed or s.desired != s.entries[1].id or s.selection_revision != s.smoke_count + 1;
            smokeKeyEvent("n", 0, .release);
            smokeKey("n", 0);
            for (0..100) |_| smokeKeyEvent("n", 0, .repeat);
            smokeKeyEvent("n", 0, .release);
            smokeKey("n", 0); // Skip image 2 before its next refresh.
            smokeKeyEvent("n", 0, .release);
            s.smoke_failed = s.smoke_failed or s.desired != s.entries[0].id or s.held_advance.pending();
            s.smoke_stage = 8;
        },
        8 => {
            s.smoke_failed = s.smoke_failed or s.desired != s.entries[0].id;
            n.output(1, if (s.smoke_failed) "HELD_NAVIGATION_FAILED\n" else "HELD_NAVIGATION_PASSED\n");
            s.smoke_stage = 5;
            select(2, false);
        },
        5 => {
            if (s.cli.smoke_windows) testWindowOpens();
            s.pressure = .critical;
            s.smoke_stage = 6;
            pump();
        },
        else => {
            s.smoke_failed = s.smoke_failed or s.current != s.smoke_image or s.cached[s.entries[0].id].image != null;
            s.pressure = .normal;
            select(0, false);
            select(2, false);
            smokeKey("w", actions.command);
        },
    }
}

fn panBenchmark() void {
    const stage = s.smoke_stage;
    s.smoke_stage += 1;
    switch (stage) {
        0 => {
            s.smoke_count = s.decode_count;
            perform(.fit);
        },
        1 => perform(.actual),
        2...9 => {
            s.geometry.pan_x += if (stage < 6) @as(f64, 64) else -64;
            layout();
        },
        10...13 => perform(.rotate_right),
        14, 15 => perform(.mirror_horizontal),
        16, 17 => perform(.nearest),
        18 => {
            s.geometry.pan_x = 0;
            s.geometry.pan_y = 0;
            layout();
        },
        19 => {
            // One running render and one replaceable desired view, even under
            // a burst of input. Only the final centered view may publish.
            for (0..128) |i| {
                s.geometry.pan_x = @as(f64, @floatFromInt(i % 32)) * 16;
                layout();
            }
            s.geometry.pan_x = 0;
            layout();
        },
        else => {
            s.smoke_failed = s.smoke_failed or s.decode_count != s.smoke_count or s.geometry.scale != 1 or s.geometry.pan_x != 0 or s.render_presented_revision != s.render_revision;
            s.warm_redecodes = s.decode_count - s.smoke_count;
            snapshotForTest();
            close();
            return;
        },
    }
    automation();
}

fn stressTest() void {
    const phase = s.smoke_stage % 16;
    if (phase == 0) {
        // Worker admission/prefetch is independent of automation delivery. A
        // quiet selected image does not prove both test images have warmed.
        // Establish that precondition before counting any work as repeated work.
        if (s.entries.len >= 3) for ([_]usize{ 0, 2 }) |index| {
            const r = &s.cached[s.entries[index].id];
            if (r.failed_version == r.version) {
                s.smoke_failed = true;
                close();
                return;
            }
            if (r.image == null or r.image_version != r.version or !adequate(s.entries[index].id, r.image.?)) {
                select(index, false);
                return;
            }
        };
        s.warm_decodes = s.decode_count;
    }
    if (phase >= 1 and phase <= 7) {
        s.warm_redecodes = @max(s.warm_redecodes, s.decode_count - s.warm_decodes);
        s.smoke_failed = s.smoke_failed or s.warm_redecodes != 0;
    }
    if (s.entries.len < 3) {
        s.smoke_failed = true;
        close();
        return;
    }
    s.smoke_failed = s.smoke_failed or control.active_decodes > 2 or control.active_renders > 2 or control.speculative_renders > 1 or control.active_decode_workers > control.decode_worker_budget or s.release_count > s.release_queue.len or s.render_presented_revision > s.render_revision;
    if (s.smoke_stage >= s.cli.stress_cycles) {
        n.output(1, if (s.smoke_failed) "STRESS_FAILED\n" else "STRESS_PASSED\n");
        // Finish with work outstanding, exercising cancellation/retirement.
        select(0, true);
        perform(.zoom_in);
        close();
        return;
    }
    switch (s.smoke_stage % 16) {
        0...5 => select(if (s.smoke_stage % 2 == 0) 0 else 2, false),
        6 => {
            for (0..128) |i| select(if (i % 2 == 0) 0 else 2, false);
        },
        7 => {
            perform(.actual);
            perform(.pan_left);
            perform(.pan_right);
        },
        8 => setPressure(.warning),
        9 => setPressure(.critical),
        10 => setPressure(.normal),
        11 => perform(.reload),
        12 => perform(.nearest),
        13 => {
            perform(.mirror_horizontal);
            perform(.mirror_horizontal);
        },
        14 => select(1, false), // A malformed source must retain valid display pixels.
        else => {
            s.smoke_failed = s.smoke_failed or s.current == null;
            select(0, false);
        },
    }
    s.smoke_stage += 1;
    automation();
}

fn recoveryTest() void {
    if (s.entries.len != 3) {
        s.smoke_failed = true;
        close();
        return;
    }
    const id = s.entries[2].id;
    const r = &s.cached[id];
    if (s.smoke_stage == 1) {
        for (s.entries, 0..) |e, index| if (s.cached[e.id].image == null) {
            select(index, false);
            return;
        };
        if (s.desired != id) {
            select(2, false);
            return;
        }
    }
    var trace: [256]u8 = undefined;
    n.output(1, std.fmt.bufPrint(&trace, "recovery stage={d} failures={d} retries={d} reclaimed={d} version={d}/{d} failed={d} retained={any}\n", .{ s.smoke_stage, s.memory_failures, s.memory_retries, s.memory_reclaimed, r.image_version, r.version, r.failed_version, s.current == s.smoke_image }) catch "recovery diagnostic overflow\n");
    switch (s.smoke_stage) {
        0 => select(2, false),
        1 => {
            s.smoke_failed = s.smoke_failed or s.cached[s.entries[0].id].image == null or s.cached[s.entries[1].id].image == null;
            memory.failNext(1);
            select(2, true);
        },
        2 => {
            s.smoke_failed = s.smoke_failed or s.memory_failures != 1 or s.memory_retries != 1 or s.memory_reclaimed < 2 or r.image_version != r.version or r.failure != null;
            s.smoke_image = s.current;
            memory.failNext(2);
            select(2, true);
        },
        3 => {
            s.smoke_failed = s.smoke_failed or s.memory_failures != 3 or s.memory_retries != 2 or !isMemoryFailure(r.failure) or r.failed_version != r.version or s.current != s.smoke_image;
            const count = s.decode_count;
            for (0..32) |_| pump();
            s.smoke_failed = s.smoke_failed or count != s.decode_count;
            // An explicit reselection retries a transient failure, without
            // requiring a source mutation or invalidating a valid source version.
            select(2, false);
        },
        4 => {
            s.smoke_failed = s.smoke_failed or r.image_version != r.version or r.failure != null;
            s.smoke_image = s.current;
            memory.failNext(2);
            select(2, true);
        },
        5 => {
            s.smoke_failed = s.smoke_failed or s.memory_failures != 5 or s.memory_retries != 3 or !isMemoryFailure(r.failure) or s.current != s.smoke_image;
            setPressure(.warning);
            setPressure(.normal);
        },
        else => {
            s.smoke_failed = s.smoke_failed or r.image_version != r.version or r.failure != null;
            n.output(1, if (s.smoke_failed) "RECOVERY_TEST_FAILED\n" else "RECOVERY_TEST_PASSED\n");
            close();
            return;
        },
    }
    s.smoke_stage += 1;
    automation();
}

fn detailTest() void {
    if (s.entries.len != 3) {
        s.smoke_failed = true;
        close();
        return;
    }
    const id = s.entries[2].id;
    switch (s.smoke_stage) {
        0 => select(2, false),
        1, 3, 5 => {
            if (s.smoke_stage != 1) {
                s.smoke_failed = s.smoke_failed or s.current.?.width != s.current.?.source_width or s.decode_count != s.smoke_count + 1;
            }
            s.cached[id].rotation = if (s.smoke_stage == 3) 1 else 0;
            s.geometry.mode = .fit;
            s.geometry.reset();
            layout();
            setPressure(.critical);
            select(2, true);
        },
        2, 4, 6 => {
            s.smoke_failed = s.smoke_failed or s.current.?.width >= s.current.?.source_width or !adequate(id, s.current.?);
            s.smoke_count = s.decode_count;
            perform(switch (s.smoke_stage) {
                2 => .fill,
                4 => .fit_width,
                else => .fit_height,
            });
        },
        else => {
            s.smoke_failed = s.smoke_failed or s.current.?.width != s.current.?.source_width or s.decode_count != s.smoke_count + 1;
            const count = s.decode_count;
            perform(.actual);
            for (0..32) |_| {
                perform(.pan_left);
                perform(.pan_right);
            }
            s.smoke_failed = s.smoke_failed or count != s.decode_count;
            n.output(1, if (s.smoke_failed) "DETAIL_TEST_FAILED\n" else "DETAIL_TEST_PASSED\n");
            close();
            return;
        },
    }
    s.smoke_stage += 1;
    automation();
}

fn hookTest() void {
    switch (s.smoke_stage) {
        0 => {
            if (s.entries.len != 3 or s.desired != s.entries[0].id) {
                s.smoke_failed = true;
                close();
                return;
            }
            smokeKey("0", 0);
            // Repeated input is bounded; this must not execute a second command.
            smokeKey("0", 0);
        },
        1 => {
            s.smoke_failed = s.smoke_failed or s.desired != s.entries[1].id;
            smokeKey("1", 0);
        },
        2 => {
            if (s.entries.len != 2) {
                s.smoke_failed = true;
                close();
                return;
            }
            s.smoke_failed = s.smoke_failed or s.desired != s.entries[1].id;
            s.smoke_count = s.cached[s.desired.?].version;
            smokeKey("2", 0);
        },
        3 => {
            s.smoke_failed = s.smoke_failed or s.desired != s.entries[1].id or s.cached[s.desired.?].version <= s.smoke_count;
            smokeKey("3", 0);
        },
        4 => {
            s.smoke_failed = s.smoke_failed or s.hook.result.success() or s.desired != s.entries[1].id;
            smokeKey("4", 0);
            perform(.first);
        },
        5 => {
            s.smoke_failed = s.smoke_failed or s.desired != s.entries[0].id;
            smokeKey("5", 0);
            perform(.last);
        },
        6 => {
            s.smoke_failed = s.smoke_failed or s.entries.len != 1 or s.desired != s.entries[0].id;
            smokeKey("7", 0);
        },
        7 => {
            s.smoke_failed = s.smoke_failed or (s.hook.failure == null or s.hook.failure.? != error.UnsafeSpecifier) or s.entries.len != 1;
            smokeKey("8", 0);
        },
        else => {
            s.smoke_failed = s.smoke_failed or !s.hook.result.success() or s.hook.failure != null;
            n.output(if (s.smoke_failed) 2 else 1, if (s.smoke_failed) "HOOK_TEST_FAILED\n" else "HOOK_TEST_PASSED\n");
            close();
            return;
        },
    }
    s.smoke_stage += 1;
    automation();
}

fn parseOption(item: options.Item) !void {
    if (try s.cli.parse(item, &s.options)) {
        if (s.cli.decode_workers) |workers| control.decode_worker_budget = if (workers == 0) n.performanceCores() else workers;
        if (s.cli.config) |path| control.config_override = path;
        memory.report = memory.report or s.cli.allocation_stats;
        return;
    }
    const name = item.name;
    const value = item.value orelse "";
    if (std.mem.eql(u8, name, "smoke-test")) {
        s.cli.smoke = true;
    } else if (std.mem.eql(u8, name, "smoke-windows")) {
        s.cli.smoke = true;
        s.cli.smoke_windows = true;
    } else if (std.mem.eql(u8, name, "stress-test")) {
        s.cli.stress_cycles = try std.fmt.parseInt(usize, value, 10);
        if (s.cli.stress_cycles == 0) return error.InvalidCycles;
        s.cli.benchmark = true;
    } else if (std.mem.eql(u8, name, "stress-no-prefetch")) {
        s.cli.stress_no_prefetch = true;
    } else if (std.mem.eql(u8, name, "recovery-test")) {
        if (!memory.debug_enabled) return error.DebugAllocatorRequired;
        s.cli.recovery_test = true;
        s.cli.benchmark = true;
    } else if (std.mem.eql(u8, name, "detail-test")) {
        s.cli.detail_test = true;
        s.cli.benchmark = true;
    } else if (std.mem.eql(u8, name, "hook-test")) {
        s.cli.hook_test = true;
    } else if (std.mem.eql(u8, name, "watch-test")) {
        s.cli.watch_test = true;
        s.cli.watch = true;
    } else if (std.mem.eql(u8, name, "benchmark")) {
        s.cli.benchmark = true;
    } else if (std.mem.eql(u8, name, "benchmark-pan")) {
        s.cli.benchmark = true;
        s.cli.benchmark_pan = true;
    } else if (std.mem.eql(u8, name, "snapshot")) {
        s.snapshot_path = value;
    } else return error.UnknownOption;
}
fn persistFilelist() !void {
    try input.save(s.cli.filelist.?, s.entries, null);
}
fn saveFilelistWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    persistFilelist() catch |err| {
        s.filelist_failure = err;
    };
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, filelistSaved);
}
fn filelistSaved(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.filelist_saving = false;
    s.filelist_saved = true;
    if (s.filelist_failure) |err| {
        n.output(2, "yekk: could not save filelist: ");
        n.output(2, @errorName(err));
        n.output(2, "\n");
        control.failed = true;
    }
    pump();
}

fn readFilelist() !void {
    const path = s.cli.filelist orelse return;
    try input.filelist(path, &s.filelist_data, &s.input, &s.input_count, &s.cancel);
    if (s.input_count == 0) {
        s.input[0] = ".";
        s.input_count = 1;
    }
}

const usage =
    \\Yekk — native macOS image viewer (feh-style single-image workflow)
    \\Usage: yekk [OPTIONS] [--] FILE_OR_DIRECTORY...   (default: current directory)
    \\  -g, --geometry WxH[+X+Y]  -x, --borderless
    \\  -F, --fullscreen        -r, --recursive       --no-recursive
    \\  -S, --sort natural|name|filename|dirname|mtime|size|none
    \\  --version-sort          -n, --reverse        -z, --randomize
    \\  -Z, --auto-zoom          -., --scale-down     --zoom PERCENT|max|fill
    \\  --zoom-step PERCENT     --keep-zoom-vp        --browse FILE
    \\  -D, --slideshow-delay SECONDS  (negative: start paused)
    \\  --on-last-slide resume|hold|quit              -R, --reload SECONDS
    \\  -A, --action '[title]COMMAND'  --action1 ... --action9 COMMAND
    \\      Return/0 runs --action; 1-9 run numbered actions. Prefix ; to reload.
    \\      Use %F for shell-escaped path, %N for basename; %% for literal percent.
    \\  -G, --draw-actions      -d, --draw-filename
    \\  -f, --filelist FILE     - (or -f -) reads paths from stdin
    \\  -|, --start-at FILE     --keys FILE           --config FILE
    \\  -l, --list              --print-filelist      --formats
    \\  -h, --help              -v, --version
    \\  --decode-workers N      CPU decode budget (0: automatic)   --alloc-stats
    \\Yekk aliases: --fit shrink|fit|fill|width|height|actual, --shuffle,
    \\              --slideshow SECONDS, --watch, --keep-view.
    \\Keys: Space/n/Right next; Backspace/p/Left previous; Up/Down zoom;
    \\* actual; / fit; ! fill; <> rotate; [] directory; h pause; k keep view;
    \\i info; a actions; d filename; ? shortcuts; f fullscreen; r reload;
    \\drag pan; wheel navigate; trackpad pan; Cmd+scroll/pinch zoom;
    \\Cmd+O new session; x close; q/Esc quit.
    \\Config: ~/.config/yekk/config and ~/.config/yekk/keys (feh keys syntax).
    \\Compatibility details and unsupported feh features: docs/feh-compatibility.md
    \\
;
pub fn run(argc: c_int, argv: [*][*:0]const u8) c_int {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    // Informational invocations need no session slab or cache initialization.
    if (argc == 2) {
        const arg = std.mem.span(argv[1]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            n.output(1, usage);
            return 0;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            n.output(1, @import("version.zig").text ++ "\n");
            return 0;
        }
    }
    const allocation = memory.allocator().rawAlloc(@sizeOf(Root), .of(Root), @returnAddress()) orelse {
        n.output(2, "yekk: out of memory\n");
        return 1;
    };
    root = @ptrCast(@alignCast(allocation));
    control = &root.control;
    control.* = .{};
    root.renderer = .{};
    defer if (memory.debug_enabled) memory.allocator().destroy(root) else memory.allocator().rawFree(@as([*]u8, @ptrCast(root))[0..@sizeOf(Root)], .of(Root), @returnAddress());
    defer root.renderer.deinit();
    s = &root.sessions[0];
    initState(s, 0, .{});
    control.active[0] = true;
    control.decode_worker_budget = n.performanceCores();
    var iterator: options.Iterator = .{ .args = argv[1..@intCast(argc)] };
    while (iterator.next() catch |err| {
        n.output(2, @errorName(err));
        n.output(2, "\n");
        return 2;
    }) |item| {
        const arg = item.name;
        if (item.positional) {
            if (std.mem.eql(u8, arg, "-")) {
                s.cli.filelist = "-";
                continue;
            }
            if (arg.len == 0 or s.input_count == s.input.len) {
                n.output(2, "yekk: empty path or input capacity exceeded\n");
                return 2;
            }
            s.input[s.input_count] = item.value.?;
            s.input_count += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "help")) {
            n.output(1, usage);
            return 0;
        }
        if (std.mem.eql(u8, arg, "version")) {
            n.output(1, @import("version.zig").text ++ "\n");
            return 0;
        }
        if (std.mem.eql(u8, arg, "formats")) {
            const formats = n.CGImageSourceCopyTypeIdentifiers();
            defer n.CFRelease(formats);
            n.output(1, "ImageIO runtime types; primary/first still image only; variants require OS support.\nlibtiff: unsigned chunky RGB16 TIFF, strips/tiles, all eight orientations; other variants use ImageIO.\n");
            var buffer: [512]u8 = undefined;
            var index: isize = 0;
            while (index < n.CFArrayGetCount(formats)) : (index += 1) if (n.CFStringGetCString(n.CFArrayGetValueAtIndex(formats, index), &buffer, buffer.len, 0x08000100) != 0) {
                n.output(1, std.mem.sliceTo(&buffer, 0));
                n.output(1, "\n");
            };
            return 0;
        }
        parseOption(item) catch |err| {
            n.output(2, "yekk: ");
            n.output(2, arg);
            n.output(2, ": ");
            n.output(2, @errorName(err));
            n.output(2, "\n");
            return 2;
        };
    }
    if (s.input_count == 0 and s.cli.filelist == null) {
        if (s.options.start_at) |path| {
            s.input[0] = path;
            s.input_count = 1;
            s.options.browse = true;
        } else {
            s.input[0] = ".";
            s.input_count = 1;
            s.cli.default_directory = true;
        }
    }
    if (s.options.browse and s.input_count != 1) {
        n.output(2, "yekk: --browse requires exactly one input\n");
        return 2;
    }
    if (s.cli.listing != .none) {
        readFilelist() catch |err| {
            n.output(2, @errorName(err));
            n.output(2, "\n");
            return 1;
        };
        s.catalog.build(s.input[0..s.input_count], s.options) catch |err| {
            n.output(2, @errorName(err));
            n.output(2, "\n");
            return 1;
        };
        if (s.cli.listing == .metadata) n.output(1, "NUM\tFORMAT\tWIDTH\tHEIGHT\tPIXELS\tSIZE\tFILENAME\n");
        for (s.catalog.entries[0..s.catalog.count], 0..) |e, number| {
            if (s.cli.listing == .metadata) {
                const meta = decoder.metadata(e.path) catch {
                    n.output(2, "yekk: unreadable header: ");
                    n.output(2, e.path);
                    n.output(2, "\n");
                    continue;
                };
                var buffer: [512]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}\t{s}\t{d}\t{d}\t{d}\t{d}\t", .{ number + 1, meta.format[0..meta.format_len], meta.width, meta.height, @as(u64, meta.width) * meta.height, e.bytes }) catch return 1;
                n.output(1, text);
            }
            n.output(1, e.path);
            n.output(1, "\n");
        }
        if (s.cli.filelist) |path| if (!std.mem.eql(u8, path, "-")) {
            s.entries = s.catalog.entries[0..s.catalog.count];
            persistFilelist() catch |err| {
                n.output(2, @errorName(err));
                n.output(2, "\n");
                return 1;
            };
        };
        return 0;
    }
    control.cli_inputs = !s.cli.default_directory;
    launch() catch |err| {
        n.output(2, @errorName(err));
        n.output(2, "\n");
        return 1;
    };
    control.app.msgSend(void, "run", .{});
    control.app.msgSend(void, "setDelegate:", .{nil});
    control.delegate.release();
    s = &root.sessions[0];
    if (s.cli.smoke or s.cli.benchmark) {
        var buffer: [1024]u8 = undefined;
        var resource_usage: c.struct_rusage = undefined;
        const peak: i64 = if (c.getrusage(c.RUSAGE_SELF, &resource_usage) == 0) resource_usage.ru_maxrss else 0;
        const text = std.fmt.bufPrint(&buffer, "{s}: {s}; decodes={d}, cache_hits={d}, warm_redecodes={d}, worst_request_to_commit_ms={d:.3}, worst_warm_request_to_commit_ms={d:.3}, peak_rss_bytes={d}, elapsed_s={d:.3}\n", .{ if (s.cli.smoke) "native smoke" else "navigation benchmark", if (control.failed) "FAILED" else "passed", control.total_decodes, control.total_hits, control.warm_redecodes, control.worst_switch, control.worst_warm_switch, peak, n.now() - s.started }) catch "diagnostic output overflow\n";
        n.output(if (control.failed) 2 else 1, text);
        if (s.cli.benchmark) {
            const stages = std.fmt.bufPrint(&buffer, "single-session stages: worker_decode_ms={d:.3}, native_contents_ms={d:.3}, native_layout_ms={d:.3}, worker_budget={d}, worker_render_ms={d:.3}, worst_native_contents_ms={d:.3}, renders={d}, render_cache_hits={d}, heartbeat_max_gap_ms={d:.3}, heartbeats={d}, viewport={d:.0}x{d:.0}, backing_scale={d:.1}\n", .{ s.worker_decode_ms, s.native_contents_ms, s.native_layout_ms, control.decode_worker_budget, s.worker_render_ms, s.worst_native_contents_ms, s.render_count, s.render_cache_hits, s.heartbeat_worst_ms, s.heartbeat_count, s.benchmark_viewport.width, s.benchmark_viewport.height, s.benchmark_backing }) catch "stage output overflow\n";
            n.output(1, stages);
        }
    }
    return if (control.failed) 1 else 0;
}
