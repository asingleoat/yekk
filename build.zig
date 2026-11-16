const std = @import("std");

pub fn build(b: *std.Build) !void {
    // The locked master caches configure results without tracking our SDK and
    // pkg-config environment reads. Reconfigure so entering a new Nix shell
    // cannot silently keep the previous native libraries; artifact caches stay.
    b.graph.poisonCache();
    var target = b.standardTargetOptions(.{
        .default_target = if (@import("builtin").os.tag == .macos) .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } } } else if (@import("builtin").os.tag == .linux) .{
            // Native ABI detection in an isolated Nix build can choose musl even
            // though our linked native dependencies use glibc. State that contract.
            .os_tag = .linux,
            .abi = .gnu,
            .glibc_version = b.graph.host.result.os.version_range.linux.glibc,
        } else .{},
    });
    if (target.result.os.tag == .linux) {
        var query = target.query;
        // An explicit -Dcpu can make standardTargetOptions omit default_target.
        // The native dependencies still require glibc, including in isolation.
        if (query.abi == null) query.abi = .gnu;
        if (query.abi.? != .gnu) return error.LinuxDependenciesRequireGlibc;
        query.os_tag = .linux;
        if (query.glibc_version == null) query.glibc_version = b.graph.host.result.os.version_range.linux.glibc;
        if (b.graph.environ_map.get("YEKK_LINUX_LOADER")) |loader| {
            query.dynamic_linker = .init(loader);
        }
        target = b.resolveTargetQuery(query);
    } else if (target.result.os.tag == .macos and target.query.os_version_min == null) {
        var query = target.query;
        query.os_tag = .macos;
        query.os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } };
        target = b.resolveTargetQuery(query);
    }
    const optimize = b.standardOptimizeOption(.{});
    const raster = b.createModule(.{ .root_source_file = b.path("src/raster.zig"), .target = target, .optimize = optimize });
    const portable = b.option(bool, "portable-linux", "Prefer static image libraries for the portable Linux release") orelse false;
    if (target.result.os.tag == .linux) return buildLinux(b, target, optimize, portable, raster);
    if (portable) return error.PortableLinuxRequiresLinuxTarget;
    if (target.result.os.tag != .macos) return error.UnsupportedPlatform;
    const sdk = b.graph.environ_map.get("SDKROOT") orelse return error.EnterNixDevelopmentShell;
    const objc_path = b.graph.environ_map.get("YEKK_OBJC") orelse return error.EnterNixDevelopmentShell;
    const translated = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/objc-runtime.h"),
        .target = target,
        .optimize = optimize,
    });
    translated.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    const bindings = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ objc_path, "src/main.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    const system = translated.createModule();
    const services = b.createModule(.{ .root_source_file = b.path("src/platform/runtime.zig"), .target = target, .optimize = optimize, .link_libc = true });
    services.addImport("system", system);
    const source = sourceModule(b, target, optimize, system, services, raster);
    const tiff = try tiffModule(b, target, optimize, system, services, portable, raster, source);
    const pnm = pnmModule(b, target, optimize, source, raster, tiff.import_table.get("pixel_storage").?, tiff.import_table.get("parallel").?);
    const png = try pngModule(b, target, optimize, source, raster, tiff.import_table.get("pixel_storage").?, portable);
    const jpeg = try jpegModule(b, target, optimize, source, raster, tiff.import_table.get("pixel_storage").?, false);
    bindings.addImport("objc-c", system);
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("objc", bindings);
    root.addImport("tiff_pixels", tiff);
    root.addImport("system", system);
    root.addImport("runtime", services);
    root.addImport("source", source);
    root.addImport("pnm", pnm);
    root.addImport("png", png);
    root.addImport("jpeg", jpeg);
    root.addImport("raster", raster);
    const geometry = b.createModule(.{ .root_source_file = b.path("src/geometry.zig"), .target = target, .optimize = optimize });
    root.addImport("geometry", geometry);
    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "debug_allocator", b.option(bool, "debug-allocator", "Use the thread-safe debug allocator and fail on owned leaks") orelse false);
    root.addOptions("build_options", runtime_options);
    const tiff_path = b.graph.environ_map.get("YEKK_TIFF_LIB") orelse return error.EnterNixDevelopmentShell;
    root.addLibraryPath(.{ .cwd_relative = tiff_path });
    root.linkSystemLibrary("tiff", .{});
    linkNative(b, root, sdk);
    const exe = b.addExecutable(.{ .name = "yekk", .root_module = root });
    b.installArtifact(exe);
    const app_binary = b.addInstallFile(exe.getEmittedBin(), "Yekk.app/Contents/MacOS/yekk");
    b.getInstallStep().dependOn(&app_binary.step);
    b.installFile("packaging/Info.plist", "Yekk.app/Contents/Info.plist");
    const dmg = b.addSystemCommand(&.{ "python3", "scripts/package-dmg.py", "--app" });
    dmg.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "Yekk.app" } });
    dmg.has_side_effects = true;
    dmg.step.dependOn(b.getInstallStep());
    b.step("dmg", "Build a portable macOS DMG (no publisher signing or notarization)").dependOn(&dmg.step);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Open a viewing session").dependOn(&run.step);

    const core_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/core.zig"), .target = target, .optimize = optimize }) });
    const run_core = b.addRunArtifact(core_tests);
    const catalog_root = b.createModule(.{ .root_source_file = b.path("src/catalog.zig"), .target = target, .optimize = optimize, .link_libc = true });
    catalog_root.addImport("system", system);
    catalog_root.addImport("runtime", services);
    const catalog_tests = b.addTest(.{ .root_module = catalog_root });
    const test_step = b.step("test", "Test shared policies and native decoder fixtures");
    linkNative(b, tiff, sdk);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tiff })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = raster })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pnm })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = png })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = jpeg })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = source.import_table.get("bmp").? })).step);
    test_step.dependOn(&run_core.step);
    test_step.dependOn(&b.addRunArtifact(catalog_tests).step);
    const cache_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/cache.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(cache_tests).step);
    const action_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/actions.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(action_tests).step);
    const geometry_tests = b.addTest(.{ .root_module = geometry });
    test_step.dependOn(&b.addRunArtifact(geometry_tests).step);
    const option_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/options.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(option_tests).step);
    const hook_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/hooks.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(hook_tests).step);
    const command_root = b.createModule(.{ .root_source_file = b.path("src/commands.zig"), .target = target, .optimize = optimize, .link_libc = true });
    command_root.addImport("system", system);
    command_root.addImport("runtime", services);
    const command_tests = b.addTest(.{ .root_module = command_root });
    test_step.dependOn(&b.addRunArtifact(command_tests).step);
    inline for (.{ "cli", "session_input", "source", "navigation", "view_actions", "hook_execution", "color" }) |name| {
        const shared = if (comptime std.mem.eql(u8, name, "source")) source else b.createModule(.{ .root_source_file = b.path("src/" ++ name ++ ".zig"), .target = target, .optimize = optimize, .link_libc = true });
        shared.addImport("system", system);
        shared.addImport("runtime", services);
        shared.addImport("geometry", geometry);
        linkNative(b, shared, sdk);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shared })).step);
    }
    const session_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/sessions.zig"), .target = target, .optimize = optimize }) });
    test_step.dependOn(&b.addRunArtifact(session_tests).step);
    const decoder_root = b.createModule(.{ .root_source_file = b.path("src/decoder_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    decoder_root.addLibraryPath(.{ .cwd_relative = tiff_path });
    decoder_root.linkSystemLibrary("tiff", .{});
    decoder_root.addImport("system", system);
    decoder_root.addImport("runtime", services);
    decoder_root.addImport("tiff_pixels", tiff);
    decoder_root.addImport("raster", raster);
    decoder_root.addImport("source", source);
    decoder_root.addImport("pnm", pnm);
    decoder_root.addImport("png", png);
    decoder_root.addImport("jpeg", jpeg);
    linkNative(b, decoder_root, sdk);
    const decoder_tests = b.addTest(.{ .root_module = decoder_root });
    test_step.dependOn(&b.addRunArtifact(decoder_tests).step);

    const presentation_root = b.createModule(.{ .root_source_file = b.path("src/presentation_tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    presentation_root.addImport("objc", bindings);
    presentation_root.addImport("system", system);
    presentation_root.addImport("runtime", services);
    presentation_root.addImport("tiff_pixels", tiff);
    presentation_root.addImport("raster", raster);
    presentation_root.addImport("source", source);
    presentation_root.addImport("pnm", pnm);
    presentation_root.addImport("png", png);
    presentation_root.addImport("jpeg", jpeg);
    const presentation_options = b.addOptions();
    presentation_options.addOption(bool, "gpu", b.option(bool, "test-gpu", "Also verify Core Image GPU color/sampling on this machine") orelse false);
    presentation_root.addOptions("test_options", presentation_options);
    presentation_root.addLibraryPath(.{ .cwd_relative = tiff_path });
    presentation_root.linkSystemLibrary("tiff", .{});
    linkNative(b, presentation_root, sdk);
    const presentation_tests = b.addTest(.{ .root_module = presentation_root });
    test_step.dependOn(&b.addRunArtifact(presentation_tests).step);

    const bench_root = b.createModule(.{ .root_source_file = b.path("src/bench_image.zig"), .target = target, .optimize = optimize, .link_libc = true });
    bench_root.addImport("system", system);
    bench_root.addImport("runtime", services);
    bench_root.addImport("tiff_pixels", tiff);
    bench_root.addImport("raster", raster);
    bench_root.addImport("source", source);
    bench_root.addImport("pnm", pnm);
    bench_root.addImport("png", png);
    bench_root.addImport("jpeg", jpeg);
    bench_root.addOptions("build_options", runtime_options);
    bench_root.addImport("objc", bindings);
    bench_root.addLibraryPath(.{ .cwd_relative = tiff_path });
    bench_root.linkSystemLibrary("tiff", .{});
    linkNative(b, bench_root, sdk);
    const bench = b.addExecutable(.{ .name = "yekk-bench-image", .root_module = bench_root });
    const install_bench = b.addInstallArtifact(bench, .{});
    b.step("build-bench-image", "Build the single-image decode and read benchmark").dependOn(&install_bench.step);

    const simd_root = b.createModule(.{ .root_source_file = b.path("src/simd_probe.zig"), .target = target, .optimize = optimize, .link_libc = true });
    simd_root.addImport("runtime", services);
    linkNative(b, simd_root, sdk);
    const simd = b.addExecutable(.{ .name = "yekk-simd-probe", .root_module = simd_root });
    const install_simd = b.addInstallArtifact(simd, .{});
    b.step("build-simd-probe", "Build research-only RGB16 SIMD comparison").dependOn(&install_simd.step);

    if (b.option([]const u8, "tiff-lib", "Override the Nix libtiff library directory for the research probe") orelse b.graph.environ_map.get("YEKK_TIFF_LIB")) |tiff_lib| {
        const probe_root = b.createModule(.{ .root_source_file = b.path("src/tiff_probe.zig"), .target = target, .optimize = optimize, .link_libc = true });
        probe_root.addImport("runtime", services);
        linkNative(b, probe_root, sdk);
        probe_root.addLibraryPath(.{ .cwd_relative = tiff_lib });
        probe_root.linkSystemLibrary("tiff", .{});
        const probe = b.addExecutable(.{ .name = "yekk-tiff-probe", .root_module = probe_root });
        const install_probe = b.addInstallArtifact(probe, .{});
        b.step("build-tiff-probe", "Build the standalone TIFF paging probe for process memory measurement").dependOn(&install_probe.step);
        const probe_run = b.addRunArtifact(probe);
        probe_run.addPassthruArgs();
        b.step("tiff-probe", "Measure TIFF region decoding (research; no viewer changes)").dependOn(&probe_run.step);
    }
}

fn buildLinux(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, portable: bool, raster: *std.Build.Module) !void {
    const translated = b.addTranslateC(.{ .root_source_file = b.path("src/platform/posix.h"), .target = target, .optimize = optimize });
    const system = translated.createModule();
    const services = b.createModule(.{ .root_source_file = b.path("src/platform/runtime.zig"), .target = target, .optimize = optimize, .link_libc = true });
    services.addImport("system", system);
    const source = sourceModule(b, target, optimize, system, services, raster);
    const tiff = try tiffModule(b, target, optimize, system, services, portable, raster, source);
    const pnm = pnmModule(b, target, optimize, source, raster, tiff.import_table.get("pixel_storage").?, tiff.import_table.get("parallel").?);
    const png = try pngModule(b, target, optimize, source, raster, tiff.import_table.get("pixel_storage").?, portable);
    const runtime_options = b.addOptions();
    const use_debug_allocator = b.option(bool, "debug-allocator", "Use the thread-safe debug allocator and fail on owned leaks") orelse false;
    runtime_options.addOption(bool, "debug_allocator", use_debug_allocator);
    runtime_options.addOption([:0]const u8, "version", @import("src/version.zig").number);
    const root = b.createModule(.{ .root_source_file = b.path("src/linux_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    root.addImport("system", system);
    root.addImport("runtime", services);
    root.addImport("source", source);
    root.addImport("pnm", pnm);
    root.addImport("png", png);
    const geometry = b.createModule(.{ .root_source_file = b.path("src/geometry.zig"), .target = target, .optimize = optimize });
    root.addImport("geometry", geometry);
    const color = b.createModule(.{ .root_source_file = b.path("src/color.zig"), .target = target, .optimize = optimize });
    const bindings = b.addTranslateC(.{ .root_source_file = b.path("src/platform/linux-bindings.h"), .target = target, .optimize = optimize });
    const include_flags = b.run(&.{ "pkg-config", "--cflags-only-I", "vips", "sdl3", "lcms2", "x11", "xi", "xext", "xfixes", "libjxl", "libjxl_threads" });
    var includes = std.mem.tokenizeAny(u8, include_flags, " \t\r\n");
    while (includes.next()) |flag| {
        if (!std.mem.startsWith(u8, flag, "-I")) return error.UnexpectedPkgConfigFlag;
        bindings.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
    }
    runtime_options.addOption(?[:0]const u8, "font_file", if (b.graph.environ_map.get("YEKK_FONT_FILE")) |path| try b.allocator.dupeSentinel(u8, path, 0) else null);
    const native = b.createModule(.{ .root_source_file = b.path("src/platform/linux.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const bindings_module = bindings.createModule();
    const jxl = b.createModule(.{ .root_source_file = b.path("src/jxl_pixels.zig"), .target = target, .optimize = optimize, .link_libc = true });
    jxl.addImport("jxl_bindings", bindings_module);
    jxl.addImport("source", source);
    jxl.addImport("raster", raster);
    jxl.addImport("pixel_storage", tiff.import_table.get("pixel_storage").?);
    native.addImport("jxl_pixels", jxl);
    native.addImport("linux_bindings", bindings_module);
    native.addImport("geometry", geometry);
    native.addImport("color", color);
    native.addImport("tiff_pixels", tiff);
    native.addImport("raster", raster);
    native.addImport("source", source);
    native.addImport("pnm", pnm);
    native.addImport("png", png);
    const jpeg = try jpegModule(b, target, optimize, source, raster, tiff.import_table.get("pixel_storage").?, portable);
    native.addImport("jpeg", jpeg);
    const runtime_module = runtime_options.createModule();
    native.addImport("build_options", runtime_module);
    try linkLinux(b, native, portable);
    root.addImport("linux", native);
    root.addImport("build_options", runtime_module);
    try linkLinux(b, root, portable);
    const bench_root = b.createModule(.{ .root_source_file = b.path("src/bench_linux_image.zig"), .target = target, .optimize = optimize, .link_libc = true });
    bench_root.addImport("system", system);
    bench_root.addImport("runtime", services);
    bench_root.addImport("linux", native);
    try linkLinux(b, bench_root, portable);
    const bench = b.addExecutable(.{ .name = "yekk-bench-image", .root_module = bench_root });
    linuxLibC(b, bench);
    b.step("build-bench-image", "Build production Linux decode and viewport benchmark").dependOn(&b.addInstallArtifact(bench, .{}).step);
    const exe = b.addExecutable(.{ .name = "yekk", .root_module = root });
    linuxLibC(b, exe);
    b.installArtifact(exe);
    b.installFile("packaging/yekk.desktop", "share/applications/yekk.desktop");
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Open a viewing session").dependOn(&run.step);
    const tests = b.step("test", "Test shared navigation, catalog, hooks and Linux decoding");
    const tiff_tests = b.addTest(.{ .root_module = tiff });
    linuxLibC(b, tiff_tests);
    tests.dependOn(&b.addRunArtifact(tiff_tests).step);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = raster })).step);
    const pnm_tests = b.addTest(.{ .root_module = pnm });
    linuxLibC(b, pnm_tests);
    tests.dependOn(&b.addRunArtifact(pnm_tests).step);
    const jpeg_tests = b.addTest(.{ .root_module = jpeg });
    linuxLibC(b, jpeg_tests);
    tests.dependOn(&b.addRunArtifact(jpeg_tests).step);
    const png_tests = b.addTest(.{ .root_module = png });
    linuxLibC(b, png_tests);
    tests.dependOn(&b.addRunArtifact(png_tests).step);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = source.import_table.get("bmp").? })).step);
    inline for (.{ "core", "catalog", "cache", "actions", "geometry", "options", "hooks", "commands", "sessions", "navigation", "view_actions", "hook_execution", "cli", "session_input", "source", "linux_controls", "linux_menu", "color" }) |name| {
        const module = if (comptime std.mem.eql(u8, name, "geometry")) geometry else if (comptime std.mem.eql(u8, name, "color")) color else if (comptime std.mem.eql(u8, name, "source")) source else b.createModule(.{ .root_source_file = b.path("src/" ++ name ++ ".zig"), .target = target, .optimize = optimize, .link_libc = true });
        module.addImport("system", system);
        module.addImport("runtime", services);
        if (comptime !std.mem.eql(u8, name, "geometry")) module.addImport("geometry", geometry);
        const compiled = b.addTest(.{ .root_module = module });
        linuxLibC(b, compiled);
        tests.dependOn(&b.addRunArtifact(compiled).step);
    }
    const decoder_tests = b.createModule(.{ .root_source_file = b.path("src/linux_app.zig"), .target = target, .optimize = optimize, .link_libc = true });
    decoder_tests.addImport("system", system);
    decoder_tests.addImport("runtime", services);
    decoder_tests.addImport("source", source);
    decoder_tests.addImport("geometry", geometry);
    decoder_tests.addImport("linux", native);
    decoder_tests.addImport("build_options", runtime_module);
    try linkLinux(b, decoder_tests, portable);
    if (b.option(bool, "test-desktop", "Build private Linux desktop interoperability fixtures") orelse false) {
        const fixture_step = b.step("build-linux-fixtures", "Build Zig desktop interoperability fixtures");
        const x11 = b.addTranslateC(.{ .root_source_file = b.path("scripts/linux-x11-bindings.h"), .target = target, .optimize = optimize });
        const xflags = b.run(&.{ "pkg-config", "--cflags-only-I", "--libs-only-L", "--libs-only-l", "x11" });
        inline for (.{ "linux-file-manager-test", "linux-x11-fixture" }) |name| {
            const fixture = b.createModule(.{ .root_source_file = b.path("scripts/" ++ name ++ ".zig"), .target = target, .optimize = optimize, .link_libc = true });
            fixture.addImport("linux_bindings", bindings_module);
            if (comptime std.mem.eql(u8, name, "linux-x11-fixture")) {
                var flags = std.mem.tokenizeAny(u8, xflags, " \t\r\n");
                while (flags.next()) |flag| {
                    if (std.mem.startsWith(u8, flag, "-I")) x11.addSystemIncludePath(.{ .cwd_relative = flag[2..] }) else if (std.mem.startsWith(u8, flag, "-L")) {
                        fixture.addLibraryPath(.{ .cwd_relative = flag[2..] });
                        fixture.addRPath(.{ .cwd_relative = flag[2..] });
                    } else if (std.mem.startsWith(u8, flag, "-l")) fixture.linkSystemLibrary(flag[2..], .{ .use_pkg_config = .no });
                }
                fixture.addImport("x11", x11.createModule());
            }
            try linkLinux(b, fixture, portable);
            const binary = b.addExecutable(.{ .name = name, .root_module = fixture });
            linuxLibC(b, binary);
            fixture_step.dependOn(&b.addInstallArtifact(binary, .{}).step);
        }
    }
    const native_tests = b.addTest(.{ .root_module = decoder_tests });
    linuxLibC(b, native_tests);
    tests.dependOn(&b.addRunArtifact(native_tests).step);
}

fn linuxLibC(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    if (artifact.root_module.resolved_target.?.result.os.tag == .linux) {
        if (b.graph.environ_map.get("YEKK_LIBC")) |path| artifact.setLibCFile(.{ .cwd_relative = path });
    }
}

fn linkLinux(b: *std.Build, module: *std.Build.Module, portable: bool) !void {
    // SDL's .pc includes linker switches Zig's pkg-config parser cannot yet
    // consume. Query the structured flag subsets and explicitly retain rpaths.
    const flags = b.run(if (portable)
        &.{ "pkg-config", "--static", "--cflags-only-I", "--libs-only-L", "--libs-only-l", "vips", "sdl3", "lcms2", "x11", "libtiff-4", "libjxl", "libjxl_threads" }
    else
        &.{ "pkg-config", "--cflags-only-I", "--libs-only-L", "--libs-only-l", "vips", "sdl3", "lcms2", "x11", "libjxl", "libjxl_threads" });
    try linkLinuxLibraries(b, module, portable, flags);
}

fn linkLinuxLibraries(b: *std.Build, module: *std.Build.Module, portable: bool, flags: []const u8) !void {
    if (portable) {
        if (module.resolved_target.?.result.cpu.arch == .aarch64) {
            module.addObjectFile(.{ .cwd_relative = b.graph.environ_map.get("YEKK_GCC_RUNTIME") orelse return error.EnterPortableLinuxBuild });
        }
        const paths = b.graph.environ_map.get("YEKK_RELEASE_LIB_DIRS") orelse return error.EnterPortableLinuxBuild;
        var directories = std.mem.tokenizeScalar(u8, paths, ':');
        while (directories.next()) |directory| {
            std.Io.Dir.accessAbsolute(b.graph.io, directory, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            module.addLibraryPath(.{ .cwd_relative = directory });
            module.addRPath(.{ .cwd_relative = directory });
        }
    }
    var tokens = std.mem.tokenizeAny(u8, flags, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.startsWith(u8, token, "-I")) module.addSystemIncludePath(.{ .cwd_relative = token[2..] }) else if (std.mem.startsWith(u8, token, "-L")) {
            module.addLibraryPath(.{ .cwd_relative = token[2..] });
            module.addRPath(.{ .cwd_relative = token[2..] });
        } else if (portable and (std.mem.eql(u8, token, "-lstdc++") or std.mem.eql(u8, token, "-lc++"))) {
            // The archives were compiled by the pinned GCC toolchain. Zig's
            // -lstdc++ alias selects libc++, which has a different C++ ABI.
            module.addObjectFile(.{ .cwd_relative = b.graph.environ_map.get("YEKK_CXX_LIBRARY") orelse return error.EnterPortableLinuxBuild });
        } else if (portable and (std.mem.eql(u8, token, "-latomic_asneeded") or std.mem.eql(u8, token, "-lgcc_s_asneeded"))) {
            // These Nix compiler-wrapper aliases are linker scripts. Resolve
            // their actual shared library instead of passing a nested -l to LLD.
            module.linkSystemLibrary(if (std.mem.eql(u8, token, "-latomic_asneeded")) "atomic" else "gcc_s", .{ .use_pkg_config = .no });
        } else if (std.mem.startsWith(u8, token, "-l")) module.linkSystemLibrary(token[2..], .{ .use_pkg_config = .no, .preferred_link_mode = if (portable) .static else .dynamic, .search_strategy = if (portable) .mode_first else .paths_first }) else return error.UnexpectedPkgConfigFlag;
    }
}

fn linkNative(b: *std.Build, module: *std.Build.Module, sdk: []const u8) void {
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    module.linkSystemLibrary("objc", .{});
    inline for (.{ "AppKit", "Foundation", "QuartzCore", "CoreGraphics", "CoreImage", "Metal", "IOSurface", "ImageIO", "CoreFoundation", "Accelerate" }) |framework| module.linkFramework(framework, .{});
}

fn tiffModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, system: *std.Build.Module, services: *std.Build.Module, portable: bool, raster: *std.Build.Module, source: *std.Build.Module) !*std.Build.Module {
    const bindings = b.addTranslateC(.{ .root_source_file = b.path("src/platform/tiff-bindings.h"), .target = target, .optimize = optimize });
    const include = b.graph.environ_map.get("YEKK_TIFF_INCLUDE") orelse std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=includedir", "libtiff-4" }), " \t\r\n");
    bindings.addSystemIncludePath(.{ .cwd_relative = include });
    if (target.result.os.tag == .macos) if (b.graph.environ_map.get("SDKROOT")) |sdk| bindings.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    const module = b.createModule(.{ .root_source_file = b.path("src/tiff_pixels.zig"), .target = target, .optimize = optimize, .link_libc = true });
    module.addImport("tiff_bindings", bindings.createModule());
    module.addImport("parallel", b.createModule(.{ .root_source_file = b.path("src/platform/parallel.zig"), .target = target, .optimize = optimize, .link_libc = true }));
    module.addImport("system", system);
    module.addImport("runtime", services);
    module.addImport("raster", raster);
    module.addImport("source", source);
    const storage = b.createModule(.{ .root_source_file = b.path("src/pixel_storage.zig"), .target = target, .optimize = optimize });
    storage.addImport("system", system);
    module.addImport("pixel_storage", storage);
    const library = b.graph.environ_map.get("YEKK_TIFF_LIB") orelse std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=libdir", "libtiff-4" }), " \t\r\n");
    module.addLibraryPath(.{ .cwd_relative = library });
    module.addRPath(.{ .cwd_relative = library });
    // Standalone decoder tests need libtiff's private archive dependencies too.
    if (portable) try linkLinuxLibraries(b, module, true, b.run(&.{ "pkg-config", "--static", "--libs-only-L", "--libs-only-l", "libtiff-4" })) else module.linkSystemLibrary("tiff", .{ .use_pkg_config = .no });
    return module;
}

fn sourceModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, system: *std.Build.Module, services: *std.Build.Module, raster: *std.Build.Module) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path("src/source.zig"), .target = target, .optimize = optimize, .link_libc = true });
    module.addImport("system", system);
    module.addImport("runtime", services);
    const bmp = b.createModule(.{ .root_source_file = b.path("src/bmp.zig"), .target = target, .optimize = optimize });
    bmp.addImport("raster", raster);
    module.addImport("bmp", bmp);
    return module;
}

fn pnmModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: *std.Build.Module, raster: *std.Build.Module, storage: *std.Build.Module, parallel: *std.Build.Module) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path("src/pnm.zig"), .target = target, .optimize = optimize, .link_libc = true });
    module.addImport("source", source);
    module.addImport("raster", raster);
    module.addImport("pixel_storage", storage);
    module.addImport("parallel", parallel);
    module.addImport("system", source.import_table.get("system").?);
    return module;
}

fn pngModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: *std.Build.Module, raster: *std.Build.Module, storage: *std.Build.Module, portable: bool) !*std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path("src/png.zig"), .target = target, .optimize = optimize, .link_libc = true });
    module.addImport("source", source);
    module.addImport("raster", raster);
    module.addImport("pixel_storage", storage);
    const bindings = b.addTranslateC(.{ .root_source_file = b.path("src/platform/png-bindings.h"), .target = target, .optimize = optimize });
    if (target.result.os.tag == .macos) {
        const sdk = b.graph.environ_map.get("SDKROOT") orelse return error.EnterNixDevelopmentShell;
        bindings.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
        inline for (.{ "DEFLATE", "ZLIB" }, .{ "deflate", "z" }) |name, library| {
            bindings.addSystemIncludePath(.{ .cwd_relative = b.graph.environ_map.get("YEKK_" ++ name ++ "_INCLUDE") orelse return error.EnterNixDevelopmentShell });
            const path = b.graph.environ_map.get("YEKK_" ++ name ++ "_LIB") orelse return error.EnterNixDevelopmentShell;
            module.addLibraryPath(.{ .cwd_relative = path });
            module.addRPath(.{ .cwd_relative = path });
            module.linkSystemLibrary(library, .{ .use_pkg_config = .no });
        }
    } else {
        const flags = b.run(&.{ "pkg-config", "--cflags-only-I", "libdeflate", "zlib" });
        var tokens = std.mem.tokenizeAny(u8, flags, " \t\r\n");
        while (tokens.next()) |flag| bindings.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
        try linkLinuxLibraries(b, module, portable, b.run(&.{ "pkg-config", "--libs-only-L", "--libs-only-l", "libdeflate", "zlib" }));
    }
    module.addImport("png_bindings", bindings.createModule());
    return module;
}

fn jpegModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: *std.Build.Module, raster: *std.Build.Module, storage: *std.Build.Module, portable: bool) !*std.Build.Module {
    const jpeg = b.createModule(.{ .root_source_file = b.path("src/jpeg.zig"), .target = target, .optimize = optimize, .link_libc = true });
    jpeg.addImport("source", source);
    jpeg.addImport("raster", raster);
    jpeg.addImport("pixel_storage", storage);
    const jpeg_bindings = b.addTranslateC(.{ .root_source_file = b.path("src/platform/jpeg-bindings.h"), .target = target, .optimize = optimize });
    if (target.result.os.tag == .macos) {
        const include = b.graph.environ_map.get("YEKK_JPEG_INCLUDE") orelse return error.EnterNixDevelopmentShell;
        jpeg_bindings.addSystemIncludePath(.{ .cwd_relative = include });
        const sdk = b.graph.environ_map.get("SDKROOT") orelse return error.EnterNixDevelopmentShell;
        jpeg_bindings.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    } else {
        var includes = std.mem.tokenizeAny(u8, b.run(&.{ "pkg-config", "--cflags-only-I", "libturbojpeg" }), " \t\r\n");
        while (includes.next()) |flag| jpeg_bindings.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
    }
    jpeg.addImport("jpeg_bindings", jpeg_bindings.createModule());
    if (target.result.os.tag == .macos) {
        const library = b.graph.environ_map.get("YEKK_JPEG_LIB") orelse return error.EnterNixDevelopmentShell;
        jpeg.addLibraryPath(.{ .cwd_relative = library });
        jpeg.addRPath(.{ .cwd_relative = library });
        jpeg.linkSystemLibrary("turbojpeg", .{ .use_pkg_config = .no });
    } else {
        try linkLinuxLibraries(b, jpeg, portable, b.run(if (portable) &.{ "pkg-config", "--static", "--libs-only-L", "--libs-only-l", "libturbojpeg" } else &.{ "pkg-config", "--libs-only-L", "--libs-only-l", "libturbojpeg" }));
    }
    return jpeg;
}
