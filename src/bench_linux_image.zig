//! Headless timings of production Linux decode and viewport operations.
const std = @import("std");
const c = @import("system");
const native = @import("linux");
const runtime = @import("runtime");

fn output(comptime format: []const u8, values: anytype) void {
    var buffer: [4096]u8 = undefined;
    runtime.output(1, std.fmt.bufPrint(&buffer, format, values) catch @panic("benchmark output overflow"));
}
fn cpuMs(value: c.struct_timeval) f64 {
    return @as(f64, @floatFromInt(value.tv_sec)) * 1000 + @as(f64, @floatFromInt(value.tv_usec)) / 1000;
}
fn usage() c.struct_rusage {
    var result: c.struct_rusage = undefined;
    if (c.getrusage(c.RUSAGE_SELF, &result) != 0) @panic("getrusage failed");
    return result;
}
// glibc exposes these counters through anonymous unions on some ABIs.
fn counter(value: c.struct_rusage, comptime name: []const u8) i64 {
    if (@hasField(c.struct_rusage, name)) return @field(value, name);
    inline for (@typeInfo(c.struct_rusage).@"struct".field_names) |field| {
        const T = @FieldType(c.struct_rusage, field);
        if (@typeInfo(T) == .@"union" and @hasField(T, name)) return @field(@field(value, field), name);
    }
    @compileError("Missing rusage counter: " ++ name);
}
fn record(comptime mode: []const u8, step: usize, started: f64, before: c.struct_rusage) void {
    const elapsed = (runtime.now() - started) * 1000;
    const after = usage();
    output("{{\"mode\":\"{s}\",\"step\":{d},\"wall_ms\":{d:.3},\"user_ms\":{d:.3},\"system_ms\":{d:.3},\"peak_rss_bytes\":{d},\"major_faults\":{d},\"minor_faults\":{d},\"input_blocks\":{d},\"voluntary_switches\":{d},\"involuntary_switches\":{d}}}\n", .{ mode, step, elapsed, cpuMs(after.ru_utime) - cpuMs(before.ru_utime), cpuMs(after.ru_stime) - cpuMs(before.ru_stime), @as(u64, @intCast(counter(after, "ru_maxrss"))) * 1024, counter(after, "ru_majflt") - counter(before, "ru_majflt"), counter(after, "ru_minflt") - counter(before, "ru_minflt"), counter(after, "ru_inblock") - counter(before, "ru_inblock"), counter(after, "ru_nvcsw") - counter(before, "ru_nvcsw"), counter(after, "ru_nivcsw") - counter(before, "ru_nivcsw") });
}
fn run(argc: c_int, argv: [*][*:0]const u8) !void {
    if (argc < 3) return error.Usage;
    const mode = std.mem.span(argv[1]);
    if (!std.mem.eql(u8, mode, "decode") and !std.mem.eql(u8, mode, "render") and !std.mem.eql(u8, mode, "zoom") and !std.mem.eql(u8, mode, "pan")) return error.Usage;
    var workers: c_int = 0;
    var width: c_int = 960;
    var height: c_int = 640;
    var checksum = false;
    var nearest = false;
    var reference = false;
    var iterations: ?usize = null;
    var i: usize = 3;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--workers")) {
            i += 1;
            if (i >= argc) return error.Usage;
            workers = try std.fmt.parseInt(c_int, std.mem.span(argv[i]), 10);
            if (workers < 0) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= argc) return error.Usage;
            iterations = try std.fmt.parseInt(usize, std.mem.span(argv[i]), 10);
            if (iterations.? == 0) return error.Usage;
        } else if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= argc) return error.Usage;
            const value = try std.fmt.parseInt(c_int, std.mem.span(argv[i]), 10);
            if (value <= 0) return error.Usage;
            if (std.mem.eql(u8, arg, "--width")) width = value else height = value;
        } else if (std.mem.eql(u8, arg, "--checksum")) checksum = true else if (std.mem.eql(u8, arg, "--nearest")) nearest = true else if (std.mem.eql(u8, arg, "--reference")) reference = true else return error.Usage;
    }
    if (native.image.init(workers) != 0) return error.DecoderInitFailed;
    defer native.shutdown();
    var image: native.Image = .{};
    defer native.image.free(&image);
    const before = usage();
    const started = runtime.now();
    if (native.image.decode(argv[2], &image) != 0) return error.DecodeFailed;
    record("decode", 0, started, before);
    output("{{\"mode\":\"image\",\"width\":{d},\"height\":{d},\"bits\":{d},\"decoded_bytes\":{d},\"workers\":{d}}}\n", .{ image.width, image.height, image.bits, image.bytes, workers });
    if (checksum) {
        const bytes: [*]const u8 = @ptrCast(image.image.?.data);
        const hash = std.hash.XxHash64.hash(0, bytes[0..image.bytes]);
        output("{{\"mode\":\"checksum\",\"checksum\":{d}}}\n", .{hash});
    }
    if (std.mem.eql(u8, mode, "decode")) return;
    output("{{\"mode\":\"configuration\",\"viewport_width\":{d},\"viewport_height\":{d},\"actual_workers\":{d},\"nearest\":{any}}}\n", .{ width, height, native.types.c.vips_concurrency_get(), nearest });
    const fit = @min(@as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(image.width)), @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(image.height)));
    const zoom_cycle = std.mem.eql(u8, mode, "zoom");
    const pan_cycle = std.mem.eql(u8, mode, "pan");
    for (0..iterations orelse (if (pan_cycle) @as(usize, 64) else if (zoom_cycle) 8 else 6)) |step| {
        const scale: f64 = if (pan_cycle) 1 else if (zoom_cycle) (if (step % 2 == 0) 0.05 else 0.0625) else if (step < 2 or step == 5) fit else 1;
        const pan: f64 = if (pan_cycle) @as(f64, @floatFromInt(step % 17)) * 64 else if (!zoom_cycle and step >= 2 and step < 5) @as(f64, @floatFromInt(step - 1)) * 64 else 0;
        const x = @round((@as(f64, @floatFromInt(width)) - @as(f64, @floatFromInt(image.width)) * scale) / 2) + pan;
        const y = @round((@as(f64, @floatFromInt(height)) - @as(f64, @floatFromInt(image.height)) * scale) / 2);
        var frame: native.Frame = .{};
        defer native.render.free(&frame);
        if (native.render.begin() != 0) return error.RendererBusy;
        defer native.render.end();
        const render_before = usage();
        const render_started = runtime.now();
        if (reference) {
            if (native.render.render(&image, width, height, scale, x, y, @intFromBool(nearest), 0, &frame) != 0) return error.RenderFailed;
            record("render", step, render_started, render_before);
            const finish_before = usage();
            const finish_started = runtime.now();
            if (native.render.finish(&frame, "", 0) != 0) return error.FinishFailed;
            record("finish", step, finish_started, finish_before);
        } else {
            if (native.render.prepare(&image, .{ .width = width, .height = height, .scale = scale, .x = x, .y = y, .nearest = nearest, .fitted = scale == fit and pan == 0 }, "", false, &frame) != 0) return error.RenderFailed;
            record("prepare", step, render_started, render_before);
        }
    }
}
pub export fn main(argc: c_int, argv: [*][*:0]const u8) c_int {
    run(argc, argv) catch |err| {
        runtime.output(2, @errorName(err));
        runtime.output(2, "\n");
        return 1;
    };
    return 0;
}
