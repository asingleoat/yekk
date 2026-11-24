//! SDL window and presentation adapter. Viewport upload stays on the worker.
const std = @import("std");
const t = @import("linux_types.zig");
const c = t.c;
const render = @import("linux_render.zig");
const Frame = t.Frame;
const Geometry = t.Geometry;
fn elapsed(start: u64) f64 {
    return @as(f64, @floatFromInt(c.SDL_GetPerformanceCounter() - start)) * 1000 / @as(f64, @floatFromInt(c.SDL_GetPerformanceFrequency()));
}
fn refreshInterval(w: *t.Window) void {
    const mode = c.SDL_GetCurrentDisplayMode(c.SDL_GetDisplayForWindow(w.window));
    if (mode == null) return;
    const rate: f64 = @floatCast(mode.*.refresh_rate);
    if (std.math.isFinite(rate) and rate > 0) w.refresh_interval = 1 / rate;
}
pub fn open(software: c_int, start_fullscreen: c_int, borderless: c_int) c_int {
    const w = t.current();
    if (c.SDL_WasInit(c.SDL_INIT_VIDEO) & c.SDL_INIT_VIDEO == 0) {
        _ = c.SDL_SetAppMetadata("Yekk", @import("build_options").version.ptr, "dev.yekk.viewer");
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return -1;
    }
    @import("linux_input.zig").initializeWake();
    w.window = c.SDL_CreateWindow("Yekk — loading", 1100, 760, c.SDL_WINDOW_HIDDEN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | @as(u64, if (start_fullscreen != 0) c.SDL_WINDOW_FULLSCREEN else 0) | @as(u64, if (borderless != 0) c.SDL_WINDOW_BORDERLESS else 0)) orelse return -1;
    _ = c.SDL_SetPointerProperty(c.SDL_GetWindowProperties(w.window), "yekk.context", w);
    @import("linux_x11.zig").install(w.window);
    w.display_profile = c.SDL_GetWindowICCProfile(w.window, &w.display_profile_size);
    w.content_scale = 1;
    w.output_epoch.store(1, .release);
    w.worker_epoch = 1;
    refreshInterval(w);
    if (software == 0 and c.getenv("SDL_RENDER_DRIVER") == null) {
        w.gpu = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, false, null);
        if (w.gpu != null and c.SDL_ClaimWindowForGPUDevice(w.gpu, w.window)) {
            // Keep submitted images in order. Acquisition below is nonblocking;
            // a full vsync queue defers presentation instead of waiting on UI.
            const mode: c.SDL_GPUPresentMode = c.SDL_GPU_PRESENTMODE_VSYNC;
            if (c.SDL_WindowSupportsGPUPresentMode(w.gpu, w.window, mode) and c.SDL_SetGPUSwapchainParameters(w.gpu, w.window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, mode)) {
                w.swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(w.gpu, w.window);
                _ = c.fprintf(c.stderr, "SDL video=%s presentation=gpu-%s (worker upload)\n", c.SDL_GetCurrentVideoDriver(), c.SDL_GetGPUDeviceDriver(w.gpu));
                _ = c.SDL_ShowWindow(w.window);
                _ = render.refreshDisplay();
                return 0;
            }
            c.SDL_ReleaseWindowFromGPUDevice(w.gpu, w.window);
        }
        if (w.gpu != null) c.SDL_DestroyGPUDevice(w.gpu);
        w.gpu = null;
    }
    w.renderer = c.SDL_CreateRenderer(w.window, if (software != 0) "software" else null);
    if (w.renderer == null and software == 0) w.renderer = c.SDL_CreateRenderer(w.window, "software");
    if (w.renderer == null) return -1;
    const no_vsync = c.SDL_SetRenderVSync(w.renderer, 0);
    _ = c.fprintf(c.stderr, "SDL video=%s renderer=%s no_vsync=%d\n", c.SDL_GetCurrentVideoDriver(), c.SDL_GetRendererName(w.renderer), @as(c_int, @intFromBool(no_vsync)));
    _ = c.SDL_SetRenderDrawColor(w.renderer, 24, 24, 24, 255);
    _ = c.SDL_RenderClear(w.renderer);
    const warm = c.SDL_CreateTexture(w.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, 1, 1);
    if (warm != null) {
        const pixel = [_]u8{ 24, 24, 24, 255 };
        _ = c.SDL_SetTextureBlendMode(warm, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_UpdateTexture(warm, null, &pixel, pixel.len);
        _ = c.SDL_RenderTexture(w.renderer, warm, null, null);
    }
    _ = c.SDL_RenderPresent(w.renderer);
    c.SDL_DestroyTexture(warm);
    _ = c.SDL_ShowWindow(w.window);
    _ = render.refreshDisplay();
    return 0;
}
pub fn close() void {
    const w = t.current();
    _ = c.fprintf(c.stderr, "SDL stages: max_upload_ms=%.3f max_draw_ms=%.3f max_present_ms=%.3f\n", w.upload_max_ms, w.draw_max_ms, w.present_max_ms);
    for (&w.textures) |*texture| {
        c.SDL_DestroyTexture(texture.*);
        texture.* = null;
    }
    if (w.gpu != null) {
        if (w.upload_texture != null) c.SDL_ReleaseGPUTexture(w.gpu, w.upload_texture);
        if (w.upload_buffer != null) c.SDL_ReleaseGPUTransferBuffer(w.gpu, w.upload_buffer);
        w.upload_texture = null;
        w.upload_buffer = null;
        w.upload_width = 0;
        w.upload_height = 0;
        c.SDL_ReleaseWindowFromGPUDevice(w.gpu, w.window);
        c.SDL_DestroyGPUDevice(w.gpu);
        w.gpu = null;
    }
    c.SDL_DestroyRenderer(w.renderer);
    c.SDL_DestroyWindow(w.window);
    w.renderer = null;
    w.window = null;
}
pub fn shutdown() void {
    c.SDL_Quit();
}
pub fn id() u32 {
    return c.SDL_GetWindowID(t.current().window);
}
pub fn hide() void {
    _ = c.SDL_HideWindow(t.current().window);
}
pub fn title(text: [*:0]const u8) void {
    _ = c.SDL_SetWindowTitle(t.current().window, text);
}
pub fn size(width: *c_int, height: *c_int) void {
    const w = t.current();
    var x: c_int = 0;
    var y: c_int = 0;
    const valid = if (w.gpu != null) c.SDL_GetWindowSizeInPixels(w.window, &x, &y) else c.SDL_GetRenderOutputSize(w.renderer, &x, &y);
    if (valid and x > 0 and y > 0) {
        width.* = x;
        height.* = y;
    }
}
pub fn captureNormal(w: *t.Window) void {
    if (w.window == null or c.SDL_GetWindowFlags(w.window) & (c.SDL_WINDOW_FULLSCREEN | c.SDL_WINDOW_MINIMIZED | c.SDL_WINDOW_MAXIMIZED) != 0) return;
    const g = &w.normal_geometry;
    _ = c.SDL_GetWindowSize(w.window, &g.width, &g.height);
    _ = c.SDL_GetWindowPosition(w.window, &g.x, &g.y);
    g.valid = @intFromBool(g.width > 0 and g.height > 0);
}
pub fn fullscreen() void {
    const w = t.current();
    captureNormal(w);
    _ = c.SDL_SetWindowFullscreen(w.window, c.SDL_GetWindowFlags(w.window) & c.SDL_WINDOW_FULLSCREEN == 0);
}
pub fn capture(g: *Geometry) void {
    captureNormal(t.current());
    g.* = t.current().normal_geometry;
}
pub fn load(g: *Geometry) void {
    g.* = .{};
    const path = c.g_build_filename(c.g_get_user_state_dir(), @as([*:0]const u8, "yekk"), @as([*:0]const u8, "window"), @as(?*anyopaque, null));
    defer c.g_free(path);
    const file = c.fopen(path, "re");
    if (file == null) return;
    defer _ = c.fclose(file);
    var version: c_int = 0;
    if (c.fscanf(file, "%d %d %d %d %d", &version, &g.width, &g.height, &g.x, &g.y) == 5 and version == 1 and g.width > 0 and g.height > 0) g.valid = 1;
}
pub fn save(g: *const Geometry) void {
    if (g.valid == 0) return;
    const directory = c.g_build_filename(c.g_get_user_state_dir(), @as([*:0]const u8, "yekk"), @as(?*anyopaque, null));
    defer c.g_free(directory);
    if (c.g_mkdir_with_parents(directory, 0o700) != 0) return;
    const path = c.g_build_filename(directory, @as([*:0]const u8, "window"), @as(?*anyopaque, null));
    defer c.g_free(path);
    var buffer: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "1 {d} {d} {d} {d}\n", .{ g.width, g.height, g.x, g.y }) catch return;
    const file = c.g_file_new_for_path(path);
    defer t.unref(file);
    var err: [*c]c.GError = null;
    if (c.g_file_replace_contents(file, text.ptr, text.len, null, 0, c.G_FILE_CREATE_PRIVATE, null, null, &err) == 0 and err != null) {
        _ = c.fprintf(c.stderr, "window geometry could not be saved: %s\n", err.*.message);
        c.g_error_free(err);
    }
}
pub fn restore(g: *const Geometry) void {
    if (g.valid == 0) return;
    const desired: c.SDL_Rect = .{ .x = g.x, .y = g.y, .w = g.width, .h = g.height };
    var display = c.SDL_GetDisplayForRect(&desired);
    if (display == 0) display = c.SDL_GetPrimaryDisplay();
    var bounds: c.SDL_Rect = undefined;
    if (!c.SDL_GetDisplayUsableBounds(display, &bounds)) return;
    const width = @min(g.width, bounds.w);
    const height = @min(g.height, bounds.h);
    const x = std.math.clamp(g.x, bounds.x, bounds.x + bounds.w - width);
    const y = std.math.clamp(g.y, bounds.y, bounds.y + bounds.h - height);
    const w = t.current();
    _ = c.SDL_SetWindowSize(w.window, width, height);
    _ = c.SDL_SetWindowPosition(w.window, x, y);
    w.normal_geometry = .{ .width = width, .height = height, .x = x, .y = y, .valid = 1 };
}
pub fn density() f32 {
    const value = c.SDL_GetWindowPixelDensity(t.current().window);
    return if (std.math.isFinite(value) and value > 0) value else 1;
}
pub fn resizeImage(width: c_int, height: c_int, clip: bool) void {
    const scale: f64 = density();
    geometryWithClip(.{ .width = @intFromFloat(@min(std.math.maxInt(c_int), @max(1, @ceil(@as(f64, @floatFromInt(width)) / scale)))), .height = @intFromFloat(@min(std.math.maxInt(c_int), @max(1, @ceil(@as(f64, @floatFromInt(height)) / scale)))) }, clip);
}
pub fn geometry(request: @import("geometry").Geometry) void {
    geometryWithClip(request, true);
}
pub fn geometryWithClip(request: @import("geometry").Geometry, clip: bool) void {
    const window = t.current().window;
    var bounds: c.SDL_Rect = undefined;
    var width: c_int = @intCast(request.width);
    var height: c_int = @intCast(request.height);
    if (clip and c.SDL_GetDisplayUsableBounds(c.SDL_GetDisplayForWindow(window), &bounds)) {
        width = @min(width, bounds.w);
        height = @min(height, bounds.h);
    }
    _ = c.SDL_SetWindowSize(window, width, height);
    if (request.position) |position| if (c.SDL_GetDisplayUsableBounds(c.SDL_GetDisplayForWindow(window), &bounds)) {
        _ = c.SDL_SetWindowPosition(window, @intFromFloat(@as(f64, @floatFromInt(bounds.x)) + position.x.resolve(@floatFromInt(bounds.w - width))), @intFromFloat(@as(f64, @floatFromInt(bounds.y)) + position.y.resolve(@floatFromInt(bounds.h - height))));
    };
}
fn textureInfo(frame: *const Frame) c.SDL_GPUTextureCreateInfo {
    var info = t.zero(c.SDL_GPUTextureCreateInfo);
    info.type = c.SDL_GPU_TEXTURETYPE_2D;
    info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
    info.width = @intCast(frame.width);
    info.height = @intCast(frame.height);
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    info.sample_count = c.SDL_GPU_SAMPLECOUNT_1;
    return info;
}
fn blit(command: ?*c.SDL_GPUCommandBuffer, source: ?*c.SDL_GPUTexture, destination: ?*c.SDL_GPUTexture, frame: *const Frame) void {
    var info = t.zero(c.SDL_GPUBlitInfo);
    info.source.texture = source;
    info.source.w = @intCast(frame.width);
    info.source.h = @intCast(frame.height);
    info.destination.texture = destination;
    info.destination.w = @intCast(frame.width);
    info.destination.h = @intCast(frame.height);
    info.load_op = c.SDL_GPU_LOADOP_DONT_CARE;
    info.filter = c.SDL_GPU_FILTER_NEAREST;
    c.SDL_BlitGPUTexture(command, &info);
}
fn wait(command: ?*c.SDL_GPUCommandBuffer) bool {
    const gpu = t.current().gpu;
    var fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(command) orelse return false;
    defer c.SDL_ReleaseGPUFence(gpu, fence);
    return c.SDL_WaitForGPUFences(gpu, true, &fence, 1);
}
pub fn prepare(frame: *Frame) c_int {
    const w = t.current();
    if (w.gpu == null) return 0;
    if (frame.bytes > std.math.maxInt(u32)) return -1;
    if (w.upload_width != frame.width or w.upload_height != frame.height) {
        if (w.upload_texture != null) c.SDL_ReleaseGPUTexture(w.gpu, w.upload_texture);
        if (w.upload_buffer != null) c.SDL_ReleaseGPUTransferBuffer(w.gpu, w.upload_buffer);
        w.upload_texture = null;
        w.upload_buffer = null;
        w.upload_width = frame.width;
        w.upload_height = frame.height;
    }
    var info = textureInfo(frame);
    if (w.upload_texture == null) w.upload_texture = c.SDL_CreateGPUTexture(w.gpu, &info);
    if (w.upload_buffer == null) {
        var transfer = t.zero(c.SDL_GPUTransferBufferCreateInfo);
        transfer.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        transfer.size = @intCast(frame.bytes);
        w.upload_buffer = c.SDL_CreateGPUTransferBuffer(w.gpu, &transfer);
    }
    if (w.upload_texture == null or w.upload_buffer == null) return -1;
    const mapped = c.SDL_MapGPUTransferBuffer(w.gpu, w.upload_buffer, false) orelse return -1;
    @memcpy(t.bytes(mapped, frame.bytes), t.bytes(frame.pixels, frame.bytes));
    c.SDL_UnmapGPUTransferBuffer(w.gpu, w.upload_buffer);
    info.format = w.swapchain_format;
    frame.gpu_texture = c.SDL_CreateGPUTexture(w.gpu, &info) orelse return -1;
    const command = c.SDL_AcquireGPUCommandBuffer(w.gpu) orelse return -1;
    const copy = c.SDL_BeginGPUCopyPass(command) orelse {
        _ = c.SDL_CancelGPUCommandBuffer(command);
        return -1;
    };
    var transfer = t.zero(c.SDL_GPUTextureTransferInfo);
    transfer.transfer_buffer = w.upload_buffer;
    transfer.pixels_per_row = @intCast(frame.width);
    transfer.rows_per_layer = @intCast(frame.height);
    var region = t.zero(c.SDL_GPUTextureRegion);
    region.texture = w.upload_texture;
    region.w = @intCast(frame.width);
    region.h = @intCast(frame.height);
    region.d = 1;
    c.SDL_UploadToGPUTexture(copy, &transfer, &region, false);
    c.SDL_EndGPUCopyPass(copy);
    blit(command, w.upload_texture, frame.gpu_texture, frame);
    return if (wait(command)) 0 else -1;
}
pub fn verify(frame: *Frame) c_int {
    const w = t.current();
    if (w.gpu == null) return 1;
    const info = textureInfo(frame);
    const rgba = c.SDL_CreateGPUTexture(w.gpu, &info) orelse return -1;
    defer c.SDL_ReleaseGPUTexture(w.gpu, rgba);
    var transfer_info = t.zero(c.SDL_GPUTransferBufferCreateInfo);
    transfer_info.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
    transfer_info.size = @intCast(frame.bytes);
    const buffer = c.SDL_CreateGPUTransferBuffer(w.gpu, &transfer_info) orelse return -1;
    defer c.SDL_ReleaseGPUTransferBuffer(w.gpu, buffer);
    const command = c.SDL_AcquireGPUCommandBuffer(w.gpu) orelse return -1;
    blit(command, frame.gpu_texture, rgba, frame);
    const copy = c.SDL_BeginGPUCopyPass(command) orelse {
        _ = c.SDL_CancelGPUCommandBuffer(command);
        return -1;
    };
    var region = t.zero(c.SDL_GPUTextureRegion);
    region.texture = rgba;
    region.w = @intCast(frame.width);
    region.h = @intCast(frame.height);
    region.d = 1;
    var destination = t.zero(c.SDL_GPUTextureTransferInfo);
    destination.transfer_buffer = buffer;
    destination.pixels_per_row = @intCast(frame.width);
    destination.rows_per_layer = @intCast(frame.height);
    c.SDL_DownloadFromGPUTexture(copy, &region, &destination);
    c.SDL_EndGPUCopyPass(copy);
    if (!wait(command)) return -1;
    const actual = c.SDL_MapGPUTransferBuffer(w.gpu, buffer, false) orelse return -1;
    defer c.SDL_UnmapGPUTransferBuffer(w.gpu, buffer);
    return if (std.mem.eql(u8, t.bytes(actual, frame.bytes), t.bytes(frame.pixels, frame.bytes))) 0 else -1;
}
pub fn present(frame: *Frame) c_int {
    if (render.frameCurrent(frame) == 0) return 2;
    const w = t.current();
    refreshInterval(w);
    const started = c.SDL_GetPerformanceCounter();
    if (w.gpu != null) {
        const command = c.SDL_AcquireGPUCommandBuffer(w.gpu) orelse return -1;
        var swapchain: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_AcquireGPUSwapchainTexture(command, w.window, &swapchain, &width, &height)) {
            _ = c.SDL_CancelGPUCommandBuffer(command);
            return -1;
        }
        if (swapchain == null) {
            _ = c.SDL_CancelGPUCommandBuffer(command);
            return 1;
        }
        const resized = width != frame.width or height != frame.height;
        if (resized) {
            var target = t.zero(c.SDL_GPUColorTargetInfo);
            target.texture = swapchain;
            target.clear_color = .{ .r = 24.0 / 255.0, .g = 24.0 / 255.0, .b = 24.0 / 255.0, .a = 1 };
            target.load_op = c.SDL_GPU_LOADOP_CLEAR;
            target.store_op = c.SDL_GPU_STOREOP_STORE;
            const pass = c.SDL_BeginGPURenderPass(command, &target, 1, null) orelse {
                _ = c.SDL_SubmitGPUCommandBuffer(command);
                return -1;
            };
            c.SDL_EndGPURenderPass(pass);
        }
        const copy = c.SDL_BeginGPUCopyPass(command) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(command);
            return -1;
        };
        var source = t.zero(c.SDL_GPUTextureLocation);
        source.texture = frame.gpu_texture;
        var destination = t.zero(c.SDL_GPUTextureLocation);
        destination.texture = swapchain;
        c.SDL_CopyGPUTextureToTexture(copy, &source, &destination, @min(width, @as(u32, @intCast(frame.width))), @min(height, @as(u32, @intCast(frame.height))), 1, false);
        c.SDL_EndGPUCopyPass(copy);
        if (!c.SDL_SubmitGPUCommandBuffer(command)) return -1;
        w.present_max_ms = @max(w.present_max_ms, elapsed(started));
        return if (resized) 2 else 0;
    }
    if (w.texture_width != frame.width or w.texture_height != frame.height) {
        for (&w.textures) |*texture| {
            c.SDL_DestroyTexture(texture.*);
            texture.* = null;
        }
        w.texture_width = frame.width;
        w.texture_height = frame.height;
    }
    const slot = &w.textures[w.texture_index];
    if (slot.* == null) {
        slot.* = c.SDL_CreateTexture(w.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, frame.width, frame.height) orelse return -1;
        _ = c.SDL_SetTextureBlendMode(slot.*, c.SDL_BLENDMODE_BLEND);
    }
    const texture = slot.*;
    w.texture_index = (w.texture_index + 1) % w.textures.len;
    if (!c.SDL_UpdateTexture(texture, null, frame.pixels, frame.width * 4)) return -1;
    const uploaded = c.SDL_GetPerformanceCounter();
    _ = c.SDL_SetRenderDrawColor(w.renderer, 24, 24, 24, 255);
    if (!c.SDL_RenderClear(w.renderer) or !c.SDL_RenderTexture(w.renderer, texture, null, null)) return -1;
    const drawn = c.SDL_GetPerformanceCounter();
    if (!c.SDL_RenderPresent(w.renderer)) return -1;
    const factor = 1000 / @as(f64, @floatFromInt(c.SDL_GetPerformanceFrequency()));
    w.upload_max_ms = @max(w.upload_max_ms, @as(f64, @floatFromInt(uploaded - started)) * factor);
    w.draw_max_ms = @max(w.draw_max_ms, @as(f64, @floatFromInt(drawn - uploaded)) * factor);
    w.present_max_ms = @max(w.present_max_ms, elapsed(drawn));
    return 0;
}
