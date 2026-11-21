# Linux

Yekk supports X11 and Wayland, the window systems used by Linux desktops.
Runtime tests cover x86_64. ARM64 (aarch64) builds are best effort and have not
been tested on ARM hardware.

## Build

Use the [README commands](../README.md#build-and-run).
`nix build path:.` builds the native Nix package. It includes a desktop entry,
file-type descriptions and Zenity for file-selection dialogs.
This package uses Nix-store dependencies. The [portable release archive](release.md#linux)
bundles its runtime libraries and does not require Nix.

Outside Nix, building requires the matching Zig master, pkg-config, SDL 3.4+,
libvips, libtiff, LittleCMS, Xlib/XInput and Xext/Xfixes headers.
Process spawning requires glibc 2.34+. Nix supplies matching headers, libraries
and the executable loader. Builds respect `NIX_BUILD_CORES`.

## Desktop controls

| Control | Action |
| --- | --- |
| Ctrl-O | Choose files for a new window. |
| Ctrl-Shift-O | Choose directories for a new window. |
| Ctrl/Super-wheel | Zoom around the pointer position. |
| Horizontal scroll | Pan the image. |
| m / right click | Open the action menu. |
| Delete | Remove the image from the list without deleting its file. |
| Ctrl-Delete | Ask before moving the file to Trash. |

Super is usually the Windows key. Enter confirms a Trash request.
Navigation cancels it. For a symbolic link, Trash moves the link itself.
A failed Trash request does not cause permanent deletion.

File selection uses `xdg-desktop-portal`, a desktop service that provides dialogs,
when available. Zenity provides the fallback dialog.
The `reveal` action shows the file in the file manager.
The `external` action opens it with its registered application through GIO.
No shell is used. Yekk rejects applications that would start another Yekk process.

## Saved window size and position

The last windowed size and position are stored in `$XDG_STATE_HOME/yekk/window`,
default `~/.local/state/yekk/window`. Fullscreen and maximized sizes do not replace
these values. Wayland decides window placement.

An explicit `--geometry` ignores the saved values and does not update them.
See [configuration and keys](feh-compatibility.md#interface-and-keys)
for shared settings and controls.

## Decoding and display

RGB16 means 16-bit red, green and blue samples. Supported RGB16 TIFFs use the
shared Zig/libtiff decoder. JPEG XL and camera RAW use libjxl and LibRaw.
Other formats use libvips.
RGB and grayscale images keep their ICC color profiles, which describe how to
interpret their color values. Other profiled color spaces convert to SDR RGB.
SDR means standard dynamic range. Floating-point source formats are rejected.

SDL GPU/Vulkan is the preferred presentation path: it sends prepared pixels to
the window. Use `--software` for software presentation. Decoding and viewport
preparation run on the CPU with either path.

For backend tests, `SDL_VIDEO_DRIVER` selects the window system.
Setting `SDL_RENDER_DRIVER` selects SDL's renderer instead of the GPU API path.
See [presentation](presentation.md) and [Linux tests](validation.md#linux).
