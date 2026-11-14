# Yekk

A native photo viewer for macOS and Linux, written in Zig. Open files or folders,
inspect large images at full resolution, and navigate with feh-style controls. No import
step or image database is required.

Yekk retains decoded images and prepares adjacent images in the background. Yekk reuses
decoded pixels when you return to cached detail. Memory pressure controls cache removal.
The cache has no fixed RAM limit. Background workers render color-managed views and
release image storage. You can use navigation controls while an image loads.

## Build and run

[Nix](https://nixos.org/) supplies the locked Zig master and native dependencies:

```sh
nix develop path:.
zig build -Doptimize=ReleaseSafe
./zig-out/bin/yekk /path/to/photos
./zig-out/bin/yekk --browse /path/to/scan.tif
```

With no arguments, Yekk browses the current directory. An explicit file opens as a
one-image list. Use `--browse` to include other images from the same directory. Use `-r`
for recursive folders, `--help` for options and `--formats` for the backend's supported
formats. `--list` prints metadata from image headers. `--print-filelist` prints file
paths.

These commands do not open a window.

`nix build path:.` builds the native package and runs unit/decoder tests. macOS requires
version 14 or later. Linux supports X11 and Wayland through SDL. See [Linux
setup](docs/linux.md). Linux ARM64 is a best-effort build target. Runtime tests on ARM64
hardware are not complete.

[Release preparation](docs/release.md) covers architecture-specific macOS DMGs and
relocatable Linux archives, including `steam-run` on NixOS. macOS releases have no
Developer ID signature or notarization.

## Viewing

Files and directories can be mixed, sorted, reversed or shuffled. Native opening and
drag-and-drop create independent windows in the same process. Source watching retains
the last valid pixels during incomplete replacements. Slideshows and persistent file
lists support browsing and triage.

| Control | Action |
| --- | --- |
| Space, n, Right / Backspace, p, Left | Next / previous; hold arrows to repeat |
| Home / End; Page Up / Page Down | First / last; forward / backward 5% |
| Up / Down; *; /; ! | Zoom; actual pixels; fit; fill |
| Left drag / click; wheel | Pan / next; previous / next |
| Middle drag / click | Zoom / actual pixels |
| < / >; [ / ] | Rotate; previous / next directory sequence |
| a / d / A / i / ? | Actions / filename / filtering / info / shortcuts |
| r / f / h / k / Z | Reload / fullscreen / pause / keep viewport / auto zoom |
| 0 or Return; 1–9 | Default hook; numbered hooks |
| x; q / Escape | Close window; quit all |

Right click or `m` opens the action menu. Delete removes an entry from the list.
Ctrl-Delete asks for confirmation before it moves the file to Trash. View
transformations do not change source files. macOS also supports Command-O, Command-W,
Command-Q, trackpad pan/pinch and Command-scroll zoom. Linux uses Ctrl-O to open files,
Ctrl-Shift-O for folders and Ctrl/Super-wheel for zoom.

`-Z` enlarges small images. `-.` reduces large images to fit the window. Combine them to
fit both ways. `--zoom 100` starts at actual size. `--keep-zoom-vp` carries numeric zoom
and viewport position between images. The [feh compatibility
reference](docs/feh-compatibility.md) explains these options, key bindings, hooks and
remaining differences.

## Photo triage

Hooks run on workers while navigation remains usable. For example, press **1** to keep a
photo or **2** to discard it:

```sh
mkdir -p "$HOME/Pictures/keep" "$HOME/Pictures/discard"
yekk -G \
  --action1 '[Keep]mv -n %F "$HOME/Pictures/keep/"' \
  --action2 '[Discard]mv -n %F "$HOME/Pictures/discard/"' \
  "$HOME/Pictures/inbox"
```

Yekk replaces `%F` with a shell-quoted path. Do not add quotation marks around `%F`. The
hook commands move files into the destination directories.

Settings load from `$XDG_CONFIG_HOME/yekk/config` (default `~/.config/yekk/config`),
with `--config FILE` or `YEKK_CONFIG` overrides. Command-line settings take precedence.
Bindings use feh's `action key1 key2 ...` syntax in the adjacent `keys` file, or a file
selected by `--keys FILE`.

```text
fit = shrink
wrap = true
keep_view = true
checker = true
bind Cmd+e = external
action_1 = [Keep]mv -n %F "$HOME/Pictures/keep/"
```

## Implementation and development

- [Architecture](docs/architecture.md): shared Zig policy, native boundaries and allocation ownership.
- [Caching and memory pressure](docs/cache-and-pressure.md): retained history, prefetch and recovery.
- [Presentation](docs/presentation.md): color, viewport rendering and native surface lifetimes.
- [Performance techniques](docs/performance.md): TIFF decoding, data layout and SIMD.
- [Large images](docs/large-image-paging.md): full-resolution viewing and region-decoding constraints.
- [Validation](docs/validation.md): regression checks, profiling and benchmark methodology.
- [Release preparation](docs/release.md): packaging, portability checks and source bundles.

Yekk uses [GPL-3.0-or-later](LICENSE). Bundled third-party libraries keep their own
licenses.
