# Linux

The Linux frontend uses the shared Zig policy and locked toolchain. SDL supplies windows
and input. libvips supplies general decoding. LittleCMS supplies color conversion. GIO
supplies desktop actions. The flake exposes x86_64 and aarch64 packages and shells.

aarch64 is a best-effort build target. Runtime tests on ARM64 hardware are not complete.

## Build and dependencies

```sh
nix develop path:.
zig build -Doptimize=ReleaseSafe
./zig-out/bin/yekk --browse /path/to/image.tif
./zig-out/bin/yekk -r /path/to/photos
nix build path:. --no-link
```

The Nix package supplies library paths, a desktop entry, the shared MIME database and a
Zenity fallback for file dialogs. It preserves desktop data paths and provides standard
XDG defaults when unset. This native package is distinct from the [relocatable release
archive](release.md#linux).

Building outside Nix requires the matching Zig master, pkg-config, SDL 3.4+, libvips,
libtiff, LittleCMS, Xlib/XInput and Xext/Xfixes headers. Process spawning uses glibc
2.34+ close-from actions. Nix pins headers, libraries and the loader. Use the Nix shell
to select matching dependencies. Builds respect `NIX_BUILD_CORES`.

## Viewing and rendering

Directories, recursive discovery, explicit/persistent file lists, sorting, slideshows,
source watching, hooks and configurable bindings use shared behavior. See the [feh
reference](feh-compatibility.md) for options and differences. Native opening and local
drops create independent windows without spawning a viewer process. Closing one window
keeps the other windows open. `q` or Escape closes all windows.

The common RGB16 TIFF path uses the shared parallel Zig/libtiff decoder. Other variants
and formats use libvips. The decoder keeps source precision, orientation and supported
RGB/gray ICC profiles. It converts other profiled color spaces to SDR RGB.
Floating-point source formats are rejected. Recognition uses contents rather than
requiring a matching suffix.

Publication checks source identity, size and mtime, and incomplete replacements preserve
the last valid display.

Full pixels support actual-size pan without redecoding. Retained reductions and prepared
views avoid repeated scaling work. SDL GPU/Vulkan presents viewport textures that
workers prepare. If GPU presentation is unavailable, Yekk uses SDL's renderer. Use
`--software` to select software rendering. `SDL_VIDEO_DRIVER` and `SDL_RENDER_DRIVER`
select native test backends.

See [presentation](presentation.md), [caching](cache-and-pressure.md) and [performance
techniques](performance.md) for ownership and resource policy.

## Desktop integration

Ctrl-O opens file selection. Ctrl-Shift-O opens directory selection. Both operations run
asynchronously. The desktop portal is preferred when available, with a Zenity fallback.
Right click or `m` opens the action menu. Ctrl/Super-wheel zooms at the pointer.

Horizontal scrolling pans the image. The X11 adapter uses SDL's public native-event hook
to select source-device input when focused and avoid duplicate source/master clicks. SDL
is unmodified, and no time-based debounce filter is used.

Normal geometry is stored in `$XDG_STATE_HOME/yekk/window` (default
`~/.local/state/yekk/window`). Yekk constrains restored geometry to the available
desktop. Wayland controls window placement. Fullscreen/maximized/minimized bounds do not
overwrite the normal frame. Explicit `--geometry` and automated diagnostics bypass
persistence. Reads precede window creation and saves run on the closing coordinator.

Delete removes a list entry. Ctrl-Delete asks for confirmation before it moves the file
to GIO Trash. Enter confirms the operation. Navigation cancels the operation. The worker
rechecks captured source/link identities. Trash acts on the symlink itself.

If Trash fails, Yekk keeps the file. It does not permanently delete the file. `reveal`
calls FileManager1.ShowItems. `external` passes a literal file argument to the
registered GIO handler. It does not use a shell. Both actions run on workers.

They reject handlers that would start another Yekk process.

```text
bind v = reveal
bind e = external
```

Settings and feh-style keys use the shared paths and CLI precedence described in the
[README](../README.md#photo-triage). Configuration errors show the file and line.
Invalid CLI options return status 2. Source watching updates existing entries, not the
directory listing.

## Validation

The [validation guide](validation.md#linux) lists private X11/Wayland desktop, color,
input, lifecycle and pressure tests. They supervise every graphical process and inject
input only into private displays. Test physical HiDPI displays, monitor changes,
hardware compositors and GPU/driver families separately. Private compositor tests do not
verify these combinations.
