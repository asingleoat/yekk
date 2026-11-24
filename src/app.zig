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
    failure: ?anyerror = null,
    remote_selected: bool = false,
    remote_refresh: bool = false,
    older: ?usize = null,
    newer: ?usize = null,
    rotation: u2 = 0,
    mirror_x: bool = false,
    mirror_y: bool = false,
    presentation_bytes: usize = 0,
    prefetch_estimate: ?struct { version: u64, bytes: u64 } = null,
};
const DecodeIntent = enum { foreground, neighbor, aggressive };
const Job = struct {
    stamp: Stamp = .{},
    owner: *State = undefined,
    busy: bool = false,
    prefetch: bool = false,
    aggressive: bool = false,
    foreground_reserve: u64 = 0,
    known_estimate: ?u64 = null,
    selection: u64 = 0,
    admission: union(enum) { not_needed, admitted: u64, deferred: u64 } = .not_needed,
    id: usize = 0,
    version: u64 = 0,
    path: [:0]const u8 = "",
    refresh_url: ?[:0]const u8 = null,
    edge: u32 = 0,
    workers: usize = 1,
    limits: decoder.Limits = .{},
    elapsed_ms: f64 = 0,
    image: ?*Image = null,
    failure: ?anyerror = null,
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
const Auxiliary = enum { reveal, external, trash, snapshot, save_image, edit_image };
const Aux = struct {
    busy: bool = false,
    kind: Auxiliary = .reveal,
    path: [:0]const u8 = "",
    success: bool = false,
    id: ?usize = null,
    native_image: ?n.Ref = null,
    rotation: u2 = 0,
    mirror: u2 = 0,
    stamp: ?Stamp = null,
    edit: @import("source").Orientation = .identity,
    failure: ?anyerror = null,
};
const HookJob = struct {
    busy: bool = false,
    thumbnail: bool = false,
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
const viewer_text = @import("viewer_text.zig");
const process_input = @import("process_input.zig");
const image_output = @import("image_output.zig");
const contact_sheet = @import("contact_sheet.zig");
const desktop_wallpaper = @import("wallpaper.zig");
const typography = @import("typography.zig");
const Font = typography.Font;
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
    gallery: contact_sheet.Gallery = .{},
    sheet_preview: ?n.Ref = null,
    sheet_preview_queued: std.atomic.Value(bool) = .init(false),
    input: [catalog.capacity][:0]const u8 = undefined,
    input_count: usize = 0,
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
    filelist_export: input.FilelistExport = .{},
    filelist_saving: bool = false,
    filelist_saved: bool = false,
    filelist_failure: ?anyerror = null,
    text: viewer_text.Options = .{},
    text_work: viewer_text.Work = .{},
    text_result: ?viewer_text.Result = null,
    caption_editor: viewer_text.Editor = .{},
    caption_write: viewer_text.CaptionWrite = .{},
    show_actions: bool = false,
    show_filename: bool = false,
    mouse_moved: bool = false,
    middle_zoom: bool = false,
    drag_button: ?u8 = null,
    mouse_origin: n.Point = .{ .x = 0, .y = 0 },
    geometry: core.View = .{},
    render_jobs: [2]RenderJob = @splat(.{}),
    prefetch_generation: u64 = 0,
    prefetch_sweep: cache.PrefetchSweep = .{},
    aggressive_paused: ?u64 = null,
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
    hidden_cursor: O = nil,
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
    output_dir: [:0]const u8 = ".",
    terminal: process_input.Terminal = .{},
};
const Root = struct {
    sessions: [sessions.capacity]State,
    control: Control,
    renderer: presentation.Renderer,
    filelist_data: input.FilelistBytes,
    downloads: @import("remote.zig").Session,
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
fn textFont(font: ?Font, fallback: f64) O {
    if (font) |face| {
        const name = string(face.family);
        defer name.release();
        const value = cls("NSFont").msgSend(O, "fontWithName:size:", .{ name, @as(f64, @floatFromInt(face.points)) });
        if (value.value != null) return value;
        return cls("NSFont").msgSend(O, "systemFontOfSize:", .{@as(f64, @floatFromInt(face.points))});
    }
    return cls("NSFont").msgSend(O, "systemFontOfSize:", .{fallback});
}
fn resolveFont(path: [:0]const u8, buffer: []u8) ![]const u8 {
    const font_url: n.Ref = @ptrCast(url(path).value orelse return error.InvalidFontFile);
    const descriptors = n.CTFontManagerCreateFontDescriptorsFromURL(font_url) orelse return error.InvalidFontFile;
    defer n.CFRelease(descriptors);
    if (n.CFArrayGetCount(descriptors) == 0) return error.InvalidFontFile;
    const name = n.CTFontDescriptorCopyAttribute(n.CFArrayGetValueAtIndex(descriptors, 0), n.kCTFontNameAttribute) orelse return error.InvalidFontFile;
    defer n.CFRelease(name);
    if (n.CFStringGetCString(name, buffer.ptr, @intCast(buffer.len), 0x08000100) == 0) return error.InvalidFontFile;
    _ = n.CTFontManagerRegisterFontsForURL(font_url, 1, null);
    return std.mem.sliceTo(buffer, 0);
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
    const displayed = if (s.displayed) |id| entry(id) else null;
    const shown = if (displayed) |item| std.fs.path.basename(item.display()) else "Yekk";
    const target = if (s.desired) |id| std.fs.path.basename((entry(id) orelse return).display()) else "";
    const failed = if (s.desired) |id| s.cached[id].failed_version == s.cached[id].version else false;
    const render_pending = s.render_wanted != null and s.render_presented_revision != s.render_revision;
    const loading = render_pending or s.desired != null and (s.displayed != s.desired or (s.current != null and s.cached[s.desired.?].image_version != s.cached[s.desired.?].version));
    const standard_title = if (s.notice_len > 0) std.fmt.bufPrint(&buffer, "{s} — {s}", .{ shown, s.notice[0..s.notice_len] }) catch shown else if (s.settings.error_line != 0) std.fmt.bufPrint(&buffer, "{s} — config error on line {d}", .{ shown, s.settings.error_line }) catch shown else if (failed) std.fmt.bufPrint(&buffer, "{s} — {s}: {s}", .{ shown, target, @errorName(s.cached[s.desired.?].failure.?) }) catch shown else if (s.indexing and s.gallery.progress.load(.acquire) > 0) std.fmt.bufPrint(&buffer, "Contact sheet {d}/{d}", .{ s.gallery.progress.load(.acquire), s.gallery.total.load(.acquire) }) catch "Contact sheet" else if (loading or (s.desired != null and s.current == null)) std.fmt.bufPrint(&buffer, "{s} — loading {s}", .{ shown, target }) catch shown else if (s.indexing and s.current == null) "Yekk — discovering images…" else if (s.current) |image| std.fmt.bufPrint(&buffer, "{s} — {d}/{d} · {d:.0}%{s}", .{ shown, (position(s.displayed.?) orelse 0) + 1, s.entries.len, s.geometry.scale * 100, if (image.width < image.source_width or image.height < image.source_height) " · preview" else "" }) catch shown else "Yekk — Command-O to open images";
    var custom_buffer: [8192]u8 = undefined;
    const text = if (s.text.title != null and s.notice_len == 0 and !failed and !loading and s.current != null) title: {
        var snapshot = displaySnapshot(s.displayed.?, s.current.?);
        if (displayed) |item| snapshot.path = item.display();
        break :title hooks.formatList(&custom_buffer, s.text.title.?, snapshot) catch standard_title;
    } else standard_title;
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
fn isMemoryFailure(failure: ?anyerror) bool {
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
    scheduleText();
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
    const selected = s.entries[index];
    const id = selected.id;
    const record = &s.cached[id];
    const refresh_url = selected.downloaded and (reload or (s.options.network.refresh_on_revisit and s.desired != id and record.remote_selected));
    record.remote_selected = selected.downloaded;
    if (s.desired) |previous| if (position(previous)) |p| {
        if (p != index) s.forward = index > p;
    };
    s.desired = id;
    s.caption_editor.path = null;
    s.text_work.cancel();
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
    if (reload or refresh_url) {
        record.version += 1;
        record.failed_version = 0;
        record.remote_refresh = record.remote_refresh or refresh_url;
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
fn start(job: *Job, id: usize, intent: DecodeIntent) bool {
    const prefetch = intent != .foreground;
    if (prefetch and s.cli.stress_cycles > 0 and s.cli.stress_no_prefetch) return false;
    if (control.memory_recovering) return false;
    if (s.release_count >= s.release_queue.len - retirement_headroom) return false;
    if (!cache.admitDecode(control.active_decodes, control.speculative_decodes, !prefetch) or (prefetch and !control.allow_prefetch)) return false;
    const available = control.decode_worker_budget - control.active_decode_workers;
    if (available == 0) return false;
    const selected = entry(id) orelse return false;
    const record = &s.cached[id];
    if (record.remote_refresh) {
        if (prefetch) return false;
        for (s.jobs) |active| if (active.busy and active.id == id and active.refresh_url != null) return false;
    }
    const path = selected.path;
    // Extension is a scheduling hint only; content still selects the decoder.
    const ext = std.fs.path.extension(path);
    const is_parallel = std.ascii.eqlIgnoreCase(ext, ".tif") or std.ascii.eqlIgnoreCase(ext, ".tiff") or std.ascii.eqlIgnoreCase(ext, ".jxl") or
        (@import("builtin").cpu.arch == .aarch64 and @import("source").rawCandidate(path));
    const workers: usize = @intCast(@min(available, if (is_parallel) (if (prefetch) @max(1, control.decode_worker_budget / 2) else control.decode_worker_budget) else 1));
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
    if (record.remote_refresh) {
        record.remote_refresh = false;
        job.refresh_url = selected.savedPath();
    }
    job.aggressive = intent == .aggressive;
    if (job.aggressive) {
        job.selection = s.selection_revision;
        for (&root.sessions, control.active) |*session, active| if (active) {
            if (session.current) |image| job.foreground_reserve = @max(job.foreground_reserve, image.accountedBytes());
        };
        if (s.cached[id].prefetch_estimate) |estimate| if (estimate.version == job.version) {
            job.known_estimate = estimate.bytes;
        };
    }
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
                    _ = start(job, id, .foreground);
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
                        _ = start(job, other, .neighbor);
                        break;
                    };
                    break;
                };
                aggressivePrefetch(id);
            }
        }
    }
    renderPump();
    renderPrefetchPump();
    releasePump();
    status();
    configureTimer();
    if (s.cli.smoke or s.cli.benchmark or s.cli.watch_test or s.cli.hook_test) automation();
}
fn aggressivePrefetch(selected: usize) void {
    if (!s.cli.aggressive or s.aggressive_paused == s.selection_revision or !control.allow_prefetch or control.memory_recovering) return;
    if (!cache.admitDecode(control.active_decodes, control.speculative_decodes, false)) return;
    s.prefetch_sweep.configure(.{ .current = position(selected) orelse return, .count = s.entries.len, .selection = s.selection_revision, .version = s.cached[selected].version });
    const now = n.now();
    if (!s.prefetch_sweep.ready(now)) return;
    const available = n.availableMemory();
    var reserve: u64 = 0;
    for (&root.sessions, control.active) |*session, active| if (active) {
        if (session.current) |image| reserve = @max(reserve, image.accountedBytes());
    };
    while (s.prefetch_sweep.next(now, available)) |index| {
        const id = s.entries[index].id;
        const target = &s.cached[id];
        if ((target.image != null and target.image_version == target.version) or target.failed_version == target.version or inflight(id) != null) continue;
        if (target.prefetch_estimate) |estimate| if (estimate.version == target.version and !cache.prefetchFits(available, estimate.bytes, reserve)) {
            s.prefetch_sweep.blocked(estimate.bytes +| reserve);
            continue;
        };
        for (&s.jobs) |*job| if (!job.busy) {
            if (!start(job, id, .aggressive)) s.prefetch_sweep.retryCandidate();
            return;
        };
        s.prefetch_sweep.retryCandidate();
        return;
    }
}
fn loadJob(job: *Job, before: Stamp) decoder.Failure!?*Image {
    if (job.aggressive) {
        const estimate = job.known_estimate orelse estimate: {
            const metadata = try decoder.metadataWithCancel(job.path, job.limits.cancel);
            break :estimate cache.prefetchEstimate(metadata.width, metadata.height, @intCast(@max(0, before.bytes)));
        };
        if (!cache.prefetchFits(n.availableMemory(), estimate, job.foreground_reserve)) {
            job.admission = .{ .deferred = estimate };
            return null;
        }
        job.admission = .{ .admitted = estimate };
    }
    return try decoder.loadWithLimits(job.path, job.edge, memory.allocator(), job.limits);
}
fn decodeWorker(context: ?*anyopaque) callconv(.c) void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const job: *Job = @ptrCast(@alignCast(context.?));
    s = job.owner;
    const started = if (s.cli.benchmark) n.now() else 0;
    var before: Stamp = .{};
    job.image = result: {
        if (job.refresh_url) |remote_url| root.downloads.refresh(remote_url, job.path, s.options.network, &s.cancel) catch |err| {
            job.failure = err;
            break :result null;
        };
        before = Stamp.read(job.path) orelse Stamp{};
        break :result loadJob(job, before) catch |err| failed: {
            job.failure = err;
            break :failed null;
        };
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
    if (r.version == job.version) switch (job.admission) {
        .not_needed => {},
        .admitted, .deferred => |bytes| r.prefetch_estimate = .{ .version = job.version, .bytes = bytes },
    };
    if (job.admission == .deferred) {
        if (s.prefetch_sweep.config) |config| if (config.selection == job.selection) s.prefetch_sweep.blocked(job.admission.deferred +| job.foreground_reserve);
    }
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
    } else if (job.aggressive and job.prefetch and isMemoryFailure(job.failure)) {
        // Background filling must not evict useful history to force a new load.
        s.aggressive_paused = s.selection_revision;
    } else if (job.admission != .deferred and !s.closing and r.version == job.version) {
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
        session.aggressive_paused = session.selection_revision;
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
    if (pressure != .normal) s.aggressive_paused = s.selection_revision;
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
    if (s.close_cursor != s.cached.len or s.release_count != 0 or s.releaser.busy or s.indexing or s.watch.busy or s.aux.busy or s.hook.busy or s.pressure_cancelling or rendersBusy() or s.preview_queued or s.automation_queued or s.status_queued or s.pending_sheets > 0 or s.sheet_preview_queued.load(.acquire)) return;
    for (s.jobs) |job| if (job.busy) return;
    if (s.filelist_saving or s.filelist_export.busy() or !s.text_work.idle() or s.caption_write.busy()) return;
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
    if (s.hidden_cursor.value != null) s.hidden_cursor.release();
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
    s.text_work.cancel();
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
    input.loadSettings(&s.index_settings, control.config_override, s.cli.keys, s.cli.buttons) catch {
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
    s.text = s.cli.text;
    s.nearest = s.settings.nearest;
    if (s.nearest) {
        const sampler = string("nearest");
        defer sampler.release();
        s.layer.msgSend(void, "setMinificationFilter:", .{sampler});
        s.layer.msgSend(void, "setMagnificationFilter:", .{sampler});
    }
    s.window.msgSend(void, "invalidateCursorRectsForView:", .{s.view});
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
    s.catalog.probe = catalogInfo;
    s.catalog.downloads = &root.downloads;
    s.options.network = s.cli.network();
    s.catalog.validate = catalogValidate;
    s.catalog.build(s.input[0..s.input_count], s.options) catch |err| {
        s.index_failure = err;
    };
    if (s.index_failure == null and s.cli.sheet.mode != .viewer) {
        buildContactSheet() catch |err| {
            s.index_failure = err;
        };
    }
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
fn openIndexedWindows() !void {
    const origin = s;
    defer s = origin;
    var available: usize = 1;
    for (control.active) |active| if (!active) {
        available += 1;
    };
    if (origin.entries.len > available) return error.MultiwindowCapacityExceeded;
    for (origin.entries[1..]) |image| {
        for (&root.sessions, control.active, 0..) |*candidate, active, slot| {
            if (active) continue;
            initState(candidate, slot, origin.limits);
            candidate.cli = origin.cli;
            candidate.cli.filelist = null;
            candidate.cli.multiwindow = false;
            candidate.cli.default_directory = false;
            candidate.input[0] = image.path;
            candidate.input_count = 1;
            s = candidate;
            try launch();
            control.active[slot] = true;
            break;
        }
    }
    origin.entries.len = 1;
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
    if (s.cli.multiwindow and s.index_failure == null) {
        openIndexedWindows() catch |err| {
            n.output(2, @errorName(err));
            n.output(2, "\n");
            s.smoke_failed = true;
            closeAll();
            return;
        };
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
fn textKey(id: usize) viewer_text.Key {
    return .{ .index = id, .version = s.render_presented.?.version, .selection = s.selection_revision, .exif = s.text.exif_visible, .info = s.text.info_visible };
}
fn displayedText() ?*const viewer_text.Result {
    const id = s.displayed orelse return null;
    if (s.render_presented == null) return null;
    if (s.text_result) |*result| if (std.meta.eql(result.key, textKey(id))) return result;
    return null;
}
fn displaySnapshot(id: usize, image: *const Image) hooks.Snapshot {
    return (hooks.Snapshot{
        .path = s.displayed_path,
        .mode = s.text.mode,
        .width = image.source_width,
        .height = image.source_height,
        .bytes = @intCast(@max(0, s.stamps[id].bytes)),
        .index = (position(id) orelse 0) + 1,
        .count = s.entries.len,
        .rotation = s.cached[id].rotation,
        .playing = s.slideshow_running,
        .pid = c.getpid(),
        .image_format = if (displayedText()) |result| if (result.format) |*format| format.name() else "unknown" else "unknown",
    }).withView(.{ .scale = s.geometry.scale, .pan_x = s.geometry.pan_x, .pan_y = -s.geometry.pan_y }, viewport());
}
fn scheduleText() void {
    if (s.closing or !s.text.wanted() or s.render_presented == null) return;
    const id = s.displayed orelse return;
    if (id != s.desired or displayedText() != null) return;
    if (!s.text_work.submit(.{ .key = textKey(id), .path = s.displayed_path, .snapshot = displaySnapshot(id, s.current orelse return), .options = s.text }, s.entries, null)) return;
    n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, textWorker);
}
fn textWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    _ = s.text_work.runPending(catalogInfo);
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, textReady);
}
fn textReady(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    s.text_result = s.text_work.take();
    if (!s.closing) {
        scheduleText();
        status();
    }
    pump();
}

fn editCaption() void {
    if (s.closing or s.current == null or s.desired != s.displayed or s.text.caption_dir == null or s.caption_write.busy()) return;
    const result = displayedText() orelse return;
    s.caption_editor.begin(s.displayed_path, result.caption.bytes());
    updateOverlay();
}
fn saveCaption() void {
    if (!(s.caption_write.submit(&s.caption_editor, s.text.caption_dir.?) catch false)) {
        notice("Could not save caption", .{});
        return;
    }
    s.caption_editor.path = null;
    n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, captionWorker);
}
fn captionWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    _ = s.caption_write.runPending();
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, captionReady);
}
fn captionReady(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    const saved = s.caption_write.take().?;
    if (!s.closing) {
        s.text_result = null;
        s.text_work.cancel();
        scheduleText();
        notice("{s}", .{if (saved) "Caption saved" else "Could not save caption"});
    }
    pump();
}
fn captionKey(event: O, key: u16) void {
    const modifiers = event.msgSend(usize, "modifierFlags", .{});
    switch (key) {
        27 => s.caption_editor.path = null,
        13, 3 => if (modifiers & actions.control != 0) s.caption_editor.add("\n") else saveCaption(),
        8, 127 => s.caption_editor.backspace(),
        else => if (modifiers & (actions.control | actions.command) == 0) {
            const chars = event.msgSend(O, "characters", .{});
            const bytes = chars.msgSend([*c]const u8, "UTF8String", .{});
            if (bytes != null) s.caption_editor.add(std.mem.span(bytes));
        },
    }
    updateOverlay();
}

fn updateOverlay() void {
    if (s.overlay.value == null) return;
    const extra = displayedText();
    const visible = s.caption_editor.path != null or s.show_info or s.show_help or s.show_actions or s.show_filename or (if (extra) |result|
        result.caption.len > 0 or result.camera.len > 0 or result.info.len > 0
    else
        false);
    s.overlay.msgSend(void, "setHidden:", .{!visible});
    if (!visible) return;
    var buffer: [24576]u8 = undefined;
    var used: usize = 0;
    if (s.caption_editor.path != null) {
        append(&buffer, &used, "Caption (Enter saves, Ctrl+Enter adds a line, Escape cancels)\n{s}\n", .{s.caption_editor.draft.bytes()});
    } else if (s.show_help) {
        append(&buffer, &used, "Yekk shortcuts — ? or Escape to dismiss\n\n", .{});
        for (s.settings.bindings[0..s.settings.binding_count]) |binding| {
            var key: [1]u8 = .{@truncate(binding.key)};
            const name = actions.keyName(binding.key);
            append(&buffer, &used, "{s}{s}{s}{s}{s}  {s}\n", .{ if (binding.modifiers & actions.command != 0) "Cmd+" else "", if (binding.modifiers & actions.shift != 0) "Shift+" else "", if (binding.modifiers & actions.option != 0) "Alt+" else "", if (binding.modifiers & actions.control != 0) "Ctrl+" else "", if (name.len == 0) &key else name, @tagName(binding.action) });
        }
        append(&buffer, &used, "\nAll actions are available in the Actions menu.\nConfig: ~/.config/yekk/config\nSyntax: bind Cmd+e = external\n", .{});
    } else {
        if (s.show_filename or s.show_info) append(&buffer, &used, "{s}\n", .{s.displayed_path});
        if (extra) |result| for ([_][]const u8{ result.caption.bytes(), result.camera.bytes(), result.info.bytes() }) |line| {
            if (line.len > 0) append(&buffer, &used, "{s}\n", .{line});
        };
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
    const needed = s.settings.watch or s.slideshow_running or s.cli.benchmark or (s.cli.aggressive and s.prefetch_sweep.phase == .waiting and s.aggressive_paused != s.selection_revision);
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
    if (s.caption_editor.path == null and s.slideshow_running and now - s.last_slide >= s.settings.interval and s.desired != null) {
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
            if (e.downloaded) {
                if (inflight(id) == null) {
                    const record = &s.cached[id];
                    record.version += 1;
                    record.failed_version = 0;
                    record.remote_refresh = true;
                    pump();
                }
            } else {
                s.watch.items[0] = .{ .entry = e, .stamp = .{} };
                s.watch.count = 1;
            }
        };
        var tried: usize = 0;
        while (s.watch.count < s.watch.items.len and tried < s.entries.len) : (tried += 1) {
            if (s.entries.len == 0) break;
            const e = s.entries[s.watch.cursor % s.entries.len];
            s.watch.cursor += 1;
            if (s.desired == e.id or e.downloaded) continue;
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
    if (s.cli.aggressive and s.prefetch_sweep.ready(now)) pump();
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
    s.hook.snapshot = displaySnapshot(id, image);
    s.hook.thumbnail = false;
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
    const execution = @import("hook_execution.zig");
    var snapshot = s.hook.snapshot;
    var meta = if (s.hook.thumbnail or hooks.usesSpecifier(s.hook.template.body(), 't')) decoder.metadataWithCancel(s.hook.path, &s.cancel) catch null else null;
    if (meta) |*value| {
        snapshot.image_format = value.format[0..value.format_len];
        if (s.hook.thumbnail) {
            snapshot.width = value.width;
            snapshot.height = value.height;
        }
    }
    const paths: execution.Paths = if (s.hook.thumbnail) .{ .entries = .{ .entries = s.catalog.entries[0..s.gallery.original_count], .first = s.gallery.original_first } } else .{ .paths = s.hook_paths[0..s.hook.manifest_count] };
    return execution.run(&s.hook.command, s.hook.template, snapshot, paths, &s.cancel);
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
        if (!job.thumbnail and !job.exists) {
            removeEntry(job.id);
        } else if (!job.thumbnail and job.result.success() and job.failure == null and still_selected) {
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
    const record = s.cached[id];
    s.aux = .{ .busy = true, .kind = kind, .path = e.path, .id = id, .rotation = record.rotation, .mirror = @as(u2, @intFromBool(record.mirror_x)) | (@as(u2, @intFromBool(record.mirror_y)) << 1), .stamp = if (kind == .save_image) record.stamp else null };
    n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, auxiliaryWorker);
}
fn writeImage(image: n.Ref, path: [:0]const u8, format: image_output.Format) !void {
    const target = n.CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), 0) orelse return error.ImageOutputFailed;
    defer n.CFRelease(target);
    const uti = string(switch (format) {
        .png => "public.png",
        .jpeg => "public.jpeg",
        .tiff => "public.tiff",
    });
    defer uti.release();
    const destination = n.CGImageDestinationCreateWithURL(target, @ptrCast(uti.value.?), 1, null) orelse return error.ImageOutputFailed;
    defer n.CFRelease(destination);
    n.CGImageDestinationAddImage(destination, image, null);
    if (n.CGImageDestinationFinalize(destination) == 0) return error.ImageOutputFailed;
}
fn writeTransformed(job: *const Aux, path: [:0]const u8, format: image_output.Format) !void {
    if (job.stamp) |stamp| if (!std.meta.eql(@as(?Stamp, stamp), Stamp.read(job.path))) return error.SourceChanged;
    const source_image = try decoder.loadWithLimits(job.path, 0, memory.allocator(), .{ .cancel = &s.cancel });
    defer source_image.destroy();
    if (job.stamp) |stamp| if (!std.meta.eql(@as(?Stamp, stamp), Stamp.read(job.path))) return error.SourceChanged;
    if (job.rotation == 0 and job.mirror == 0) return writeImage(source_image.native, path, format);
    const input_image = cls("CIImage").msgSend(O, "alloc", .{}).msgSend(O, "initWithCGImage:", .{source_image.native});
    defer input_image.release();
    var image = input_image.msgSend(O, "imageByApplyingOrientation:", .{([_]c_int{ 1, 6, 3, 8 })[job.rotation]});
    if (job.mirror & 1 != 0) image = image.msgSend(O, "imageByApplyingOrientation:", .{@as(c_int, 2)});
    if (job.mirror & 2 != 0) image = image.msgSend(O, "imageByApplyingOrientation:", .{@as(c_int, 4)});
    const ci_context = cls("CIContext").msgSend(O, "contextWithOptions:", .{nil});
    const transformed = ci_context.msgSend(?n.Ref, "createCGImage:fromRect:", .{ image, image.msgSend(n.Rect, "extent", .{}) }) orelse return error.RenderFailed;
    defer n.CFRelease(transformed);
    try writeImage(transformed, path, format);
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
            writeImage(image, s.aux.path, .png) catch {
                n.dispatch_async_f(n.dispatch_get_main_queue(), s, auxiliaryDone);
                return;
            };
            s.aux.success = true;
        },
        .edit_image => {
            image_output.editJpeg(s.aux.path, s.aux.stamp, s.aux.edit, memory.allocator()) catch |err| {
                s.aux.failure = err;
                n.dispatch_async_f(n.dispatch_get_main_queue(), s, auxiliaryDone);
                return;
            };
            s.aux.success = true;
        },
        .save_image => {
            image_output.saveCopy(control.output_dir, s.aux.path, &s.aux, writeTransformed) catch {
                n.dispatch_async_f(n.dispatch_get_main_queue(), s, auxiliaryDone);
                return;
            };
            s.aux.success = true;
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
        if (s.aux.success and s.aux.kind == .edit_image) {
            const id = s.aux.id.?;
            s.cached[id].version += 1;
            s.cached[id].failed_version = 0;
        }
        if (s.aux.failure) |err| notice("{s}", .{@errorName(err)}) else notice("{s}", .{if (s.aux.success) "Operation complete" else "Operation failed"});
    }
    pump();
}
fn launchSelection(paths: O) void {
    const previous = s;
    defer s = previous;
    openSelection(paths, true) catch |err| {
        s = previous;
        notice("Cannot open session: {s}", .{@errorName(err)});
    };
}
fn openSelection(paths: O, browse: bool) !void {
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
                candidate.cli.text = s.cli.text;
                candidate.cli.text.mode = if (browse) .slideshow else .thumbview;
                if (!browse) {
                    candidate.cli.text.title = s.cli.text.thumb_title;
                    candidate.cli.fullscreen = s.cli.fullscreen;
                }
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
    s.options.browse = browse and count == 1;
    if (created) try launch() else startIndex();
}
fn startIndex() void {
    s.indexing = true;
    s.catalog.cancel = &s.cancel;
    s.catalog.on_initial = if (s.cli.multiwindow or s.cli.sheet.mode != .viewer or s.options.sort != null or s.options.reverse or s.options.shuffle or s.options.start_at != null or s.cli.filelist != null) null else initialIndexed;
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
        if (s.settings.background_color) |rgb| {
            const red = @as(f64, @floatFromInt(rgb[0])) / 255;
            const green = @as(f64, @floatFromInt(rgb[1])) / 255;
            const blue = @as(f64, @floatFromInt(rgb[2])) / 255;
            const color = cls("NSColor").msgSend(O, "colorWithSRGBRed:green:blue:alpha:", .{ red, green, blue, @as(f64, 1) });
            s.window.msgSend(void, "setBackgroundColor:", .{color});
            return;
        }
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
    if (s.settings.edit) if (view_actions.editOrientation(action)) |operation| {
        if (s.aux.busy or s.current == null or s.displayed != s.desired) return;
        const id = s.displayed.?;
        s.aux = .{ .busy = true, .kind = .edit_image, .path = s.displayed_path, .id = id, .edit = operation, .stamp = s.cached[id].stamp };
        n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, auxiliaryWorker);
        return;
    };
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
        .toggle_exif => {
            s.text.exif_visible = !s.text.exif_visible;
            s.text_work.cancel();
            scheduleText();
            updateOverlay();
        },
        .toggle_caption => editCaption(),
        .toggle_pointer => {
            s.settings.hide_pointer = !s.settings.hide_pointer;
            s.window.msgSend(void, "invalidateCursorRectsForView:", .{s.view});
        },
        .info => {
            if (s.text.info != null) {
                s.text.info_visible = !s.text.info_visible;
                s.text_work.cancel();
                scheduleText();
            } else s.show_info = !s.show_info;
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
        .save_filelist => exportFilelist(),
        .save_image => if (s.current != null) auxiliary(.save_image),
        .resize_window => if (s.current) |image| {
            const size = sourceSize(image);
            const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
            const screen = s.window.msgSend(O, "screen", .{}).msgSend(n.Rect, "visibleFrame", .{});
            const width = size.width / backing;
            const height = size.height / backing;
            s.window.msgSend(void, "setContentSize:", .{n.Size{
                .width = if (s.settings.no_screen_clip) width else @min(screen.size.width, width),
                .height = if (s.settings.no_screen_clip) height else @min(screen.size.height - 40, height),
            }});
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
fn keypadKey(code: u16) ?u16 {
    return switch (code) {
        82...89 => actions.keypad_zero + code - 82,
        91, 92 => actions.keypad_zero + code - 83,
        65 => actions.keypad_decimal,
        76 => actions.keypad_enter,
        69 => actions.keypad_plus,
        78 => actions.keypad_minus,
        67 => actions.keypad_multiply,
        75 => actions.keypad_divide,
        81 => actions.keypad_equal,
        else => null,
    };
}
fn keyDown(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const event: O = .{ .value = raw };
    const chars = event.msgSend(O, "charactersIgnoringModifiers", .{});
    const code = event.msgSend(u16, "keyCode", .{});
    const key = keypadKey(code) orelse if (chars.msgSend(usize, "length", .{}) > 0)
        chars.msgSend(u16, "characterAtIndex:", .{@as(usize, 0)})
    else
        return;
    if (s.caption_editor.path != null) return captionKey(event, key);
    const repeated = event.msgSend(bool, "isARepeat", .{});
    const action = s.settings.lookup(key, event.msgSend(usize, "modifierFlags", .{}));
    if (action == .next or action == .previous) {
        const direction: navigation.HeldAdvance.Direction = if (action == .next) .next else .previous;
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
    if (repeated and (action == .save_filelist or action == .save_image)) return;
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
    if (s.settings.mouse_configured and !event.msgSend(bool, "hasPreciseScrollingDeltas", .{}) and (dy != 0 or dx != 0)) {
        const button: u8 = if (dy != 0) (if (dy > 0) 4 else 5) else if (dx > 0) 6 else 7;
        if (s.settings.lookupButton(button, event.msgSend(usize, "modifierFlags", .{}))) |bound| {
            if (bound == .action) perform(bound.action);
        }
        return;
    }
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
fn buttonNumber(event: O) u8 {
    const number = event.msgSend(i64, "buttonNumber", .{});
    return switch (number) {
        0 => 1,
        1 => 3,
        2 => 2,
        3...250 => @intCast(number + 5),
        else => 0,
    };
}
fn mouseDown(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const event: O = .{ .value = raw };
    const button = buttonNumber(event);
    const modifiers = if (s.settings.mouse_configured) event.msgSend(usize, "modifierFlags", .{}) else 0;
    const action = s.settings.lookupButton(button, modifiers) orelse return;
    stopHeldAdvance();
    if (action == .action) {
        if (action.action == .menu) showMenu(event) else perform(action.action);
        return;
    }
    s.drag_button = button;
    s.middle_zoom = action == .zoom;
    s.mouse_moved = false;
    s.dragging = event.msgSend(n.Point, "locationInWindow", .{});
    s.mouse_origin = s.dragging.?;
}
fn mouseUp(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    if (s.drag_button != buttonNumber(.{ .value = raw })) return;
    const legacy_click = !s.settings.mouse_configured and !s.mouse_moved;
    const zoom = s.middle_zoom;
    s.drag_button = null;
    s.dragging = null;
    if (legacy_click) {
        if (!zoom and openThumbnail(raw)) return;
        if (zoom) {
            perform(.actual);
        } else {
            const bounds = s.view.msgSend(n.Rect, "bounds", .{});
            const left = s.settings.tap_zones and s.mouse_origin.x < bounds.size.width / 2;
            navigate(if (left) -1 else 1, false);
        }
    }
}
fn mouseDragged(self: objc.c.id, _: objc.c.SEL, raw: objc.c.id) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    const event: O = .{ .value = raw };
    if (s.drag_button != buttonNumber(event)) return;
    const last = s.dragging orelse return;
    const point = event.msgSend(n.Point, "locationInWindow", .{});
    s.mouse_moved = s.mouse_moved or @abs(point.x - s.mouse_origin.x) > 2 or @abs(point.y - s.mouse_origin.y) > 2;
    const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
    if (s.middle_zoom) {
        const anchor = s.view.msgSend(n.Point, "convertPoint:fromView:", .{ s.mouse_origin, nil });
        const vp = viewport();
        s.geometry.zoom(@exp(std.math.clamp((point.x - last.x) * 0.01, -1, 1)), anchor.x * backing - vp.width / 2, anchor.y * backing - vp.height / 2);
    } else {
        s.geometry.pan_x += (point.x - last.x) * backing;
        s.geometry.pan_y += (point.y - last.y) * backing;
    }
    s.dragging = point;
    layout();
    if (s.middle_zoom) ensureDetail();
}
fn showMenu(event: O) void {
    if (event.value == null or !s.settings.menus) return;
    menus();
    const main = s.app.msgSend(O, "mainMenu", .{});
    const name = string("Actions");
    defer name.release();
    const item = main.msgSend(O, "itemWithTitle:", .{name});
    if (item.value == null) return;
    cls("NSMenu").msgSend(void, "popUpContextMenu:withEvent:forView:", .{ item.msgSend(O, "submenu", .{}), event, s.view });
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
fn frontSession() ?*State {
    for (&root.sessions, control.active) |*candidate, active| {
        if (active and !candidate.closing and candidate.window.msgSend(bool, "isKeyWindow", .{})) return candidate;
    }
    for (&root.sessions, control.active) |*candidate, active| if (active and !candidate.closing) return candidate;
    return null;
}
fn terminalInput(_: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    s = frontSession() orelse return;
    for (0..16) |_| {
        const key = control.terminal.next() orelse break;
        if (s.closing) break;
        if (s.settings.lookup(key.value, key.modifiers)) |action| perform(action);
    }
}
fn processNext(_: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    s = frontSession() orelse return;
    perform(if (s.entries.len == 1) .reload else .next);
}
fn processPrevious(_: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    s = frontSession() orelse return;
    perform(if (s.entries.len == 1) .reload else .previous);
}
fn signalHandler(_: c_int) callconv(.c) void {}
fn processQuit(_: ?*anyopaque) callconv(.c) void {
    closeAll();
}
fn processSource(kind: *anyopaque, handle: usize, handler: *const fn (?*anyopaque) callconv(.c) void) ?*anyopaque {
    const event = n.dispatch_source_create(kind, handle, 0, n.dispatch_get_main_queue()) orelse return null;
    n.dispatch_source_set_event_handler_f(event, handler);
    n.dispatch_resume(event);
    return event;
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
fn resetCursorRects(self: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const previous = s;
    defer s = previous;
    useSession(self);
    if (!s.settings.hide_pointer) return;
    if (s.hidden_cursor.value == null) {
        const transparent = cls("NSImage").msgSend(O, "alloc", .{}).msgSend(O, "initWithSize:", .{n.Size{ .width = 1, .height = 1 }});
        defer transparent.release();
        s.hidden_cursor = cls("NSCursor").msgSend(O, "alloc", .{}).msgSend(O, "initWithImage:hotSpot:", .{ transparent, n.Point{ .x = 0, .y = 0 } });
    }
    const bounds = s.view.msgSend(n.Rect, "bounds", .{});
    s.view.msgSend(void, "addCursorRect:cursor:", .{ bounds, s.hidden_cursor });
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
    if (s.cli.no_menus or !s.settings.menus) {
        s.app.msgSend(void, "setMainMenu:", .{menu});
        return;
    }
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
    if (s.text.menu_font) |font| {
        const font_key = string("NSFont");
        defer font_key.release();
        const attributes = cls("NSMutableDictionary").msgSend(O, "dictionary", .{});
        attributes.msgSend(void, "setObject:forKey:", .{ textFont(font, 11), font_key });
        const label_value = cls("NSAttributedString").msgSend(O, "alloc", .{}).msgSend(O, "initWithString:attributes:", .{ title_text, attributes });
        defer label_value.release();
        item.msgSend(void, "setAttributedTitle:", .{label_value});
    }
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
    addMethod(view_class, "resetCursorRects", resetCursorRects);
    addMethod(view_class, "keyDown:", keyDown);
    addMethod(view_class, "keyUp:", keyUp);
    addMethod(view_class, "scrollWheel:", scroll);
    addMethod(view_class, "magnifyWithEvent:", magnify);
    addMethod(view_class, "mouseDown:", mouseDown);
    addMethod(view_class, "mouseDragged:", mouseDragged);
    addMethod(view_class, "mouseUp:", mouseUp);
    addMethod(view_class, "rightMouseDown:", mouseDown);
    addMethod(view_class, "rightMouseDragged:", mouseDragged);
    addMethod(view_class, "rightMouseUp:", mouseUp);
    addMethod(view_class, "otherMouseDown:", mouseDown);
    addMethod(view_class, "otherMouseDragged:", mouseDragged);
    addMethod(view_class, "otherMouseUp:", mouseUp);
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
    s.overlay.msgSend(void, "setFont:", .{textFont(s.cli.text.font, 11)});
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
    if (s.cli.fullscreen and s.cli.sheet.mode != .thumbnails) perform(.fullscreen);
    if ((s.input_count > 0 or s.cli.filelist != null) and !s.cli.default_directory) startIndex();
}
fn automation() void {
    if (!automationReady() or s.automation_queued) return;
    s.automation_queued = true;
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, automated);
}
fn automationReady() bool {
    if (control.memory_recovering or (rendersBusy() and !s.cli.benchmark_pan) or (s.render_wanted != null and s.render_presented_revision != s.render_revision and s.render_failed_revision != s.render_revision) or s.indexing or !s.indexed or s.closing or s.releaser.busy or s.release_count > 0 or s.aux.busy or s.hook.busy or s.filelist_export.busy() or !s.text_work.idle() or s.pending_sheets > 0) return false;
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
            if (s.cli.output_dir != null) smokeKey("L", actions.shift);
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
            if (s.cli.output_dir != null) smokeKey("L", actions.shift);
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
        if (s.cli.output_dir) |path| control.output_dir = path;
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
fn exportFilelist() void {
    if (s.closing) return;
    if (s.gallery.layout != null) return notice("File list export is unavailable in contact sheet modes", .{});
    if (!s.indexed or s.index_failure != null or s.entries.len == 0) {
        notice("No image list to save", .{});
        return;
    }
    if (!s.filelist_export.queue(s.entries, null)) return;
    n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, exportFilelistWorker);
}
fn exportFilelistWorker(context: ?*anyopaque) callconv(.c) void {
    sessionContext(context);
    _ = s.filelist_export.runPending(control.output_dir);
    n.dispatch_async_f(n.dispatch_get_main_queue(), s, exportFilelistDone);
}
fn exportFilelistDone(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    const result = s.filelist_export.take().?;
    if (!s.closing) switch (result) {
        .saved => |path| notice("Saved file list to {s}", .{std.fs.path.basename(path)}),
        .failed => |err| notice("Could not save file list ({s})", .{@errorName(err)}),
    };
    pump();
}

const SheetBackend = struct {
    fn bitmap(canvas: contact_sheet.Canvas) !n.Ref {
        const color = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB) orelse return error.RenderFailed;
        defer n.CFRelease(color);
        return n.CGBitmapContextCreate(canvas.pixels.ptr, canvas.width, canvas.height, 8, @as(usize, canvas.width) * 4, color, 0x4001) orelse error.RenderFailed;
    }
    pub fn tile(canvas: contact_sheet.Canvas, path: [:0]const u8, cell: contact_sheet.Rect, sheet_options: contact_sheet.Options) !catalog.Dimensions {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const pixels = try decoder.loadWithLimits(path, @max(cell.width, cell.height), memory.allocator(), .{ .cancel = &s.cancel });
        defer pixels.destroy();
        const out = contact_sheet.fit(cell, pixels.source_width, pixels.source_height, sheet_options);
        const context = try bitmap(canvas);
        defer n.CFRelease(context);
        n.CGContextSetAlpha(context, @as(f64, @floatFromInt(sheet_options.opacity)) / 255);
        n.CGContextDrawImage(context, n.rect(@floatFromInt(out.x), @floatFromInt(canvas.height - out.y - out.height), @floatFromInt(out.width), @floatFromInt(out.height)), pixels.native);
        return .{ .width = pixels.source_width, .height = pixels.source_height };
    }
    pub fn label(canvas: contact_sheet.Canvas, text: [:0]const u8, area: contact_sheet.Rect, font: ?Font) !void {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const context = try bitmap(canvas);
        defer n.CFRelease(context);
        const native = cls("NSGraphicsContext");
        const graphics = native.msgSend(O, "graphicsContextWithCGContext:flipped:", .{ context, false });
        native.msgSend(void, "saveGraphicsState", .{});
        defer native.msgSend(void, "restoreGraphicsState", .{});
        native.msgSend(void, "setCurrentContext:", .{graphics});
        const font_key = string("NSFont");
        defer font_key.release();
        const color_key = string("NSColor");
        defer color_key.release();
        const attrs = cls("NSMutableDictionary").msgSend(O, "dictionary", .{});
        attrs.msgSend(void, "setObject:forKey:", .{ textFont(font, 11), font_key });
        attrs.msgSend(void, "setObject:forKey:", .{ cls("NSColor").msgSend(O, "whiteColor", .{}), color_key });
        const label_string = string(text);
        defer label_string.release();
        label_string.msgSend(void, "drawInRect:withAttributes:", .{ n.rect(@floatFromInt(area.x), @floatFromInt(canvas.height - area.y - area.height), @floatFromInt(area.width), @floatFromInt(area.height)), attrs });
    }
    pub fn progress(state: *State, canvas: contact_sheet.Canvas) void {
        if (state.sheet_preview_queued.swap(true, .acq_rel)) return;
        const boundary = contact_sheet.fit(.{ .width = 1024, .height = 768 }, canvas.width, canvas.height, .{});
        state.sheet_preview = preview(canvas, boundary.width, boundary.height);
        n.dispatch_async_f(n.dispatch_get_main_queue(), state, sheetProgress);
    }
    fn preview(canvas: contact_sheet.Canvas, width: u32, height: u32) ?n.Ref {
        const color = n.CGColorSpaceCreateWithName(n.kCGColorSpaceSRGB) orelse return null;
        defer n.CFRelease(color);
        const row = @as(usize, width) * 4;
        const context = n.CGBitmapContextCreate(null, width, height, 8, row, color, 0x4001) orelse return null;
        defer n.CFRelease(context);
        const pixels = n.CGBitmapContextGetData(context) orelse return null;
        canvas.preview(.{ .pixels = pixels[0 .. row * height], .width = width, .height = height });
        return n.CGBitmapContextCreateImage(context);
    }
    pub fn encode(canvas: contact_sheet.Canvas, path: [:0]const u8, format: image_output.Format) !void {
        const context = try bitmap(canvas);
        defer n.CFRelease(context);
        const sheet_image = n.CGBitmapContextCreateImage(context) orelse return error.RenderFailed;
        defer n.CFRelease(sheet_image);
        try writeImage(sheet_image, path, format);
    }
};
fn sheetProgress(context: ?*anyopaque) callconv(.c) void {
    const previous = s;
    defer s = previous;
    sessionContext(context);
    defer {
        s.sheet_preview_queued.store(false, .release);
        if (s.closing) closePump();
    }
    if (s.sheet_preview) |image| {
        s.sheet_preview = null;
        defer n.CFRelease(image);
        if (!s.closing and s.indexing and s.current == null) {
            const bounds = s.view.msgSend(n.Rect, "bounds", .{});
            const scale_factor = s.window.msgSend(f64, "backingScaleFactor", .{});
            const width: f64 = @floatFromInt(n.CGImageGetWidth(image));
            const height: f64 = @floatFromInt(n.CGImageGetHeight(image));
            const scale = @min(1 / scale_factor, bounds.size.width / width, bounds.size.height / height);
            const w = width * scale;
            const h = height * scale;
            const transaction = cls("CATransaction");
            transaction.msgSend(void, "begin", .{});
            transaction.msgSend(void, "setDisableActions:", .{true});
            s.layer.msgSend(void, "setFrame:", .{n.rect((bounds.size.width - w) / 2, (bounds.size.height - h) / 2, w, h)});
            s.layer.msgSend(void, "setContents:", .{@as(O, .{ .value = @ptrCast(@alignCast(@constCast(image))) })});
            transaction.msgSend(void, "commit", .{});
        }
    }
    status();
}
fn buildContactSheet() !void {
    var effective = s.cli.sheet;
    effective.font = s.cli.text.font;
    effective.title = s.cli.text.title;
    if (effective.mode == .viewer) effective.mode = .montage;
    const temporary = if (effective.destination == null) try root.downloads.workDir() else ".";
    try s.gallery.build(&s.catalog, effective, temporary, s, SheetBackend);
}
fn setWallpaper() !void {
    var directory_buffer: [4096]u8 = undefined;
    const directory = try desktop_wallpaper.macDirectory(&directory_buffer);
    const screens = cls("NSScreen").msgSend(O, "screens", .{});
    const screen_count = screens.msgSend(usize, "count", .{});
    if (screen_count == 0) return error.NoDisplay;
    const first = s.cli.xinerama_index orelse 0;
    if (first >= screen_count) return error.NoDisplay;
    const end = if (s.cli.xinerama_index != null or s.cli.primary_only) first + 1 else screen_count;
    const workspace = cls("NSWorkspace").msgSend(O, "sharedWorkspace", .{});
    for (first..end) |index| {
        const screen = screens.msgSend(O, "objectAtIndex:", .{index});
        const frame = screen.msgSend(n.Rect, "frame", .{});
        const scale = screen.msgSend(f64, "backingScaleFactor", .{});
        if (!std.math.isFinite(frame.size.width * scale) or !std.math.isFinite(frame.size.height * scale) or frame.size.width * scale < 1 or frame.size.height * scale < 1 or frame.size.width * scale > 65535 or frame.size.height * scale > 65535) return error.InvalidDisplay;
        const extent: desktop_wallpaper.Size = .{ .width = @intFromFloat(frame.size.width * scale), .height = @intFromFloat(frame.size.height * scale) };
        const entry_index = @min(index - first, s.catalog.count - 1);
        const edge = if (s.cli.wallpaper == .tile or s.cli.wallpaper == .center) 0 else @max(extent.width, extent.height);
        const image = try decoder.loadWithLimits(s.catalog.entries[entry_index].path, edge, memory.allocator(), .{});
        defer image.destroy();
        const allocation_bytes = try std.math.mul(usize, @as(usize, extent.width) * extent.height, 4);
        const data = try memory.allocator().alloc(u8, allocation_bytes);
        defer memory.allocator().free(data);
        const canvas: contact_sheet.Canvas = .{ .pixels = data, .width = extent.width, .height = extent.height };
        @memset(data, 0);
        const background_rgb = if (s.cli.background) |color| if (color == .color) color.color else [3]u8{ 0, 0, 0 } else [3]u8{ 0, 0, 0 };
        for (0..allocation_bytes / 4) |px| data[px * 4 ..][0..4].* = background_rgb ++ [_]u8{255};
        const context = try SheetBackend.bitmap(canvas);
        defer n.CFRelease(context);
        const mode = s.cli.wallpaper.?;
        const box = desktop_wallpaper.placement(mode, extent, .{ .width = image.source_width, .height = image.source_height }, s.cli.geometry);
        const rows: usize = if (mode == .tile) @intFromFloat(@ceil(@as(f64, @floatFromInt(extent.height)) / box.height)) else 1;
        const columns: usize = if (mode == .tile) @intFromFloat(@ceil(@as(f64, @floatFromInt(extent.width)) / box.width)) else 1;
        for (0..rows) |row| for (0..columns) |col| {
            const x = box.x + @as(f64, @floatFromInt(col)) * box.width;
            const y = box.y + @as(f64, @floatFromInt(row)) * box.height;
            n.CGContextDrawImage(context, n.rect(x, @as(f64, @floatFromInt(extent.height)) - y - box.height, box.width, box.height), image.native);
        };
        const wallpaper_image = n.CGBitmapContextCreateImage(context) orelse return error.RenderFailed;
        defer n.CFRelease(wallpaper_image);
        var staged: image_output.Temporary = .{};
        defer staged.deinit();
        try staged.create(directory, .png);
        try writeImage(wallpaper_image, staged.path(), .png);
        var path_buffer: [4096]u8 = undefined;
        const destination = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/wallpaper-{d}.png", .{ directory, index }, 0);
        try staged.replace(destination);
        if (!workspace.msgSend(bool, "setDesktopImageURL:forScreen:options:error:", .{ url(destination), screen, cls("NSDictionary").msgSend(O, "dictionary", .{}), @as(?*objc.c.id, null) }))
            return error.WallpaperNotApplied;
    }
}
fn openThumbnail(raw: objc.c.id) bool {
    if (s.cli.sheet.mode != .thumbnails or s.current == null or s.geometry.scale <= 0) return false;
    const id = s.displayed orelse return false;
    const event: O = .{ .value = raw };
    const location = event.msgSend(n.Point, "locationInWindow", .{});
    const backing = s.window.msgSend(f64, "backingScaleFactor", .{});
    const view = displaySnapshot(id, s.current.?);
    const hit = s.gallery.imageAt(&s.catalog, (location.x * backing - view.offset_x) / view.zoom, (@as(f64, @floatFromInt(view.viewport_height)) - location.y * backing - view.offset_y) / view.zoom) orelse return true;
    const command = s.settings.hooks[0];
    if (command.len > 0) {
        if (!s.hook.busy) {
            s.hook = .{ .busy = true, .thumbnail = true, .path = hit.entry.path, .template = command, .snapshot = hit.snapshot(view, s.gallery.original_count) };
            n.dispatch_async_f(n.dispatch_get_global_queue(0x19, 0), s, hookWorker);
        }
        return true;
    }
    const image_path = string(hit.entry.path);
    defer image_path.release();
    const paths = cls("NSArray").msgSend(O, "arrayWithObject:", .{image_path});
    const previous = s;
    defer s = previous;
    openSelection(paths, false) catch {
        s = previous;
        notice("Could not open thumbnail", .{});
    };
    return true;
}

fn persistFilelist() !void {
    if (s.gallery.layout != null) return s.gallery.saveFilelist(s.cli.filelist.?, &s.catalog);
    const list = if (s.cli.multiwindow) s.catalog.entries[0..s.catalog.count] else s.entries;
    try input.save(s.cli.filelist.?, list, null);
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
    try input.filelist(path, &root.filelist_data, &s.input, &s.input_count, &s.cancel);
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
    \\  -S, --sort natural|name|filename|dirname|mtime|size|none|width|height|pixels|format
    \\  --min-dimension WxH     --max-dimension WxH
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
    \\  -j, --output-dir DIR   Shift+L saves the current file list
    \\  -|, --start-at FILE     --keys FILE           --config FILE
    \\  -l, --list              -L, --customlist FORMAT
    \\  -U, --loadable          -u, --unloadable       --print-filelist
    \\  -T, --theme NAME        --buttons FILE        --formats
    \\  -w, --multiwindow        -^, --title FORMAT    -Y, --hide-pointer
    \\  -K, --caption-path DIR   --draw-exif           --info COMMAND
    \\  -m, --montage            -i, --index           -t, --thumbnails
    \\  -o, --output FILE        -O, --output-only FILE
    \\  -p, --preload            -k, --keep-http       --edit
    \\  -h, --help              -v, --version
    \\  --decode-workers N      CPU decode budget (0: automatic)   --alloc-stats
    \\  --aggressive            Preload the list while memory is available
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
fn catalogInfo(path: [:0]const u8, cancel: ?*const std.atomic.Value(bool)) ?catalog.Info {
    const meta = decoder.metadataWithCancel(path, cancel) catch return null;
    return catalog.Info.init(meta.width, meta.height, meta.format[0..meta.format_len], meta.alpha);
}

fn catalogLoadable(path: [:0]const u8) anyerror!bool {
    return catalogValidate(path, null);
}
fn catalogValidate(path: [:0]const u8, cancel: ?*const std.atomic.Value(bool)) anyerror!bool {
    const image = decoder.loadWithLimits(path, 0, memory.allocator(), .{ .cancel = cancel }) catch |err| return switch (err) {
        error.OutOfMemory, error.Cancelled => err,
        else => false,
    };
    image.destroy();
    return true;
}
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
    root.downloads = .{ .transfer = @import("network.zig").download };
    defer if (memory.debug_enabled) memory.allocator().destroy(root) else memory.allocator().rawFree(@as([*]u8, @ptrCast(root))[0..@sizeOf(Root)], .of(Root), @returnAddress());
    defer root.renderer.deinit();
    defer root.downloads.deinit();
    s = &root.sessions[0];
    initState(s, 0, .{});
    control.active[0] = true;
    control.decode_worker_budget = n.performanceCores();
    var theme: input.Theme = .{};
    var iterator = theme.load(argv[1..@intCast(argc)]) catch |err| {
        n.output(2, @errorName(err));
        n.output(2, "\n");
        return 2;
    };
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
            n.output(1, ".jxl\n");
            inline for (@import("source").raw_suffixes) |suffix| n.output(1, suffix ++ "\n");
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
    s.cli.finish() catch |err| {
        n.output(2, @errorName(err));
        n.output(2, "\n");
        return 2;
    };
    var fonts: [3]typography.ResolvedFont = @splat(.{});
    const selected_fonts = [_]*?Font{ &s.cli.text.font, &s.cli.text.menu_font, &s.cli.sheet.title_font };
    for (&fonts, selected_fonts) |*storage, font| storage.apply(font, &s.cli.font_paths, resolveFont) catch {
        n.output(2, "yekk: invalid font file\n");
        return 2;
    };
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
    if (s.cli.listing != .none or s.cli.sheet.output_only or s.cli.wallpaper != null) {
        readFilelist() catch |err| {
            n.output(2, @errorName(err));
            n.output(2, "\n");
            return 1;
        };
        s.catalog.probe = catalogInfo;
        s.catalog.downloads = &root.downloads;
        s.options.network = s.cli.network();
        s.catalog.validate = catalogValidate;
        s.catalog.build(s.input[0..s.input_count], s.options) catch |err| {
            n.output(2, @errorName(err));
            n.output(2, "\n");
            return 1;
        };
        if (s.cli.wallpaper != null) {
            setWallpaper() catch |err| {
                n.output(2, @errorName(err));
                n.output(2, "\n");
                return 1;
            };
            return 0;
        }
        if (s.cli.sheet.output_only) {
            buildContactSheet() catch |err| {
                n.output(2, @errorName(err));
                n.output(2, "\n");
                return 1;
            };
            return 0;
        }
        if (s.cli.listing != .paths) {
            input.loadSettings(&s.settings, s.cli.config, s.cli.keys, s.cli.buttons) catch return 2;
            s.cli.apply(&s.settings);
        }
        const matched = @import("listings.zig").run(s.cli.listing, &s.catalog, catalogInfo, catalogLoadable, s.settings.hooks[0]) catch |err| {
            n.output(2, @errorName(err));
            n.output(2, "\n");
            return 1;
        };
        if (s.cli.filelist) |path| if (!std.mem.eql(u8, path, "-")) {
            s.entries = s.catalog.entries[0..s.catalog.count];
            persistFilelist() catch |err| {
                n.output(2, @errorName(err));
                n.output(2, "\n");
                return 1;
            };
        };
        return if (matched) 0 else 1;
    }
    s.cli.text.mode = s.cli.windowMode();
    control.cli_inputs = !s.cli.default_directory;
    launch() catch |err| {
        n.output(2, @errorName(err));
        n.output(2, "\n");
        return 1;
    };
    const use_terminal = !(if (s.cli.filelist) |file| std.mem.eql(u8, file, "-") else false);
    if (use_terminal) _ = control.terminal.enable();
    defer control.terminal.disable();
    const signals = [_]c_int{ c.SIGUSR1, c.SIGUSR2, c.SIGINT, c.SIGTERM };
    const targets = .{ processNext, processPrevious, processQuit, processQuit };
    var sources: [signals.len + 1]?*anyopaque = @splat(null);
    inline for (signals, targets, 0..) |number, target, i| {
        if (i < 2 or control.terminal.original != null) {
            _ = c.signal(number, signalHandler);
            sources[i] = processSource(n.signalType(), @intCast(number), target);
        }
    }
    if (control.terminal.original != null) {
        sources[signals.len] = processSource(n.readType(), 0, terminalInput);
        if (sources[signals.len] == null) control.terminal.disable();
    }
    defer for (sources) |slot| {
        if (slot) |event| {
            n.dispatch_source_cancel(event);
            n.dispatch_release(event);
        }
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
