# Linux

Yekk supports X11 and Wayland. x86_64 has local runtime coverage.
aarch64 is a best-effort build target without ARM hardware runtime verification.

## Build

Use the [README commands](../README.md#build-and-run).
`nix build path:.` builds the native package. It includes a desktop entry,
MIME data and a Zenity fallback for file dialogs.
See [release packaging](release.md#linux) for a portable archive.

Outside Nix, building requires matching Zig master, pkg-config, SDL 3.4+,
libvips, libtiff, LittleCMS, Xlib/XInput and Xext/Xfixes headers.
Process spawning requires glibc 2.34+. Nix pins matching headers, libraries
and the loader. Builds respect `NIX_BUILD_CORES`.

## Desktop controls

| Control | Action |
| --- | --- |
| Ctrl-O | Open files in another window |
| Ctrl-Shift-O | Open directories in another window |
| Ctrl/Super-wheel | Zoom at the pointer |
| Horizontal scroll | Pan |
| m / right click | Open the action menu |
| Delete | Remove the entry from the list |
| Ctrl-Delete | Request confirmed Trash |

Enter confirms Trash. Navigation cancels it. Trash acts on symlinks themselves.
Failure does not cause permanent deletion.

File selection uses the desktop portal when available, with a Zenity fallback.
`reveal` opens the file manager. `external` opens the registered GIO handler
without a shell. Handlers that would launch another Yekk process are rejected.

Normal window geometry is stored in `$XDG_STATE_HOME/yekk/window`, or
`~/.local/state/yekk/window`. Wayland controls placement. Explicit `--geometry`
bypasses saved geometry. Fullscreen and maximized bounds do not replace normal bounds.

See [configuration and keys](feh-compatibility.md#interface-and-keys)
for shared settings and controls.

## Rendering

RGB16 TIFFs use the shared Zig/libtiff decoder. Other formats use libvips.
RGB/gray ICC profiles remain attached to native samples. Other profiled color
spaces convert to SDR RGB. Floating-point source formats are rejected.

SDL GPU/Vulkan is the preferred display path. Use `--software` for software
rendering. `SDL_VIDEO_DRIVER` and `SDL_RENDER_DRIVER` select test backends.
See [presentation](presentation.md) and [Linux tests](validation.md#linux).
