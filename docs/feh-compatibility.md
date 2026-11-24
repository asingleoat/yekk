# feh compatibility

This reference describes Yekk's supported options and controls.
See [feh's manual](https://man.finalrewind.org/1/feh/) for feh itself.

Each window has an ordered **image list**: the files opened in that window.
Next and previous move through this list. After the last image, next returns to
the first image by default.

## Command line

Short options can be combined: `-FZD3` means `-F -Z -D 3`.
An option's value can follow it directly: `-Sfilename` means `-S filename`.
Long options accept `=`, as in `--sort=filename`.
Use `--` before a filename that starts with `-`.

### Opening and ordering images

With no image arguments, Yekk opens images from the current directory.
An explicit file argument opens only that file. Directory arguments add their images
to the list. You can supply several files and directories.

| Option | Effect |
| --- | --- |
| `--browse FILE` | Open the file and include other images from its directory. |
| `-\| FILE`, `--start-at FILE` | Start with this file. Without other inputs, include images from its directory. |
| `-r`, `--recursive` | Include subdirectories. Do not follow symbolic links to directories. |
| `--no-recursive` | Exclude subdirectories. |
| `-S MODE`, `--sort MODE` | Choose the ordering described below. |
| `--min-dimension WIDTHxHEIGHT`, `--max-dimension WIDTHxHEIGHT` | Limit image dimensions in pixels. A zero or negative axis has no limit. |
| `--version-sort` | Compare numbers numerically in `name`, `filename` or `dirname` ordering. |
| `-n`, `--reverse` | Reverse the list order. |
| `-z`, `--randomize` | Shuffle the list. Shuffle again when advancing from the last image to the first. |

| Sort mode | Order |
| --- | --- |
| `name` | Full file paths, in case-sensitive text order. |
| `filename` | Filenames without directories, in case-sensitive text order. |
| `dirname` | Parent-directory paths, in case-sensitive text order. |
| `mtime` | File modification time, newest first. |
| `size` | File size on disk, smallest first. |
| `width`, `height`, `pixels` | Image width, height or pixel count, smallest first. |
| `format` | Image format name, in text order. |
| `none` | Input order and filesystem directory-enumeration order. |
| `natural` | Filenames with numeric comparison: `frame2.tif` before `frame10.tif`. This is Yekk's default. |

Dimension filters and metadata sorts probe images on a worker before
selection. For `--start-at`, use the same path spelling as the input. If
there is no exact match, Yekk starts at the first entry with the same
filename.

### Window size and zoom

The **viewport** is the image-display area inside the window.
A **backing pixel** is one pixel in the window's drawing buffer.
At 100% zoom, one image pixel maps to one backing pixel.

**Fit** shows the entire image without cropping. **Fill** covers the viewport,
so parts of the image can lie outside the window. **Panning** moves the image
inside the viewport without changing its zoom.

| Option | Effect |
| --- | --- |
| `-g GEOMETRY`, `--geometry GEOMETRY` | Set window size and optional position. See the example below. |
| `-x`, `--borderless` | Remove window borders and title bar. |
| `-F`, `--fullscreen` | Use fullscreen. |
| `-Z`, `--auto-zoom` | Enlarge small images to fit. |
| `-.`, `--scale-down` | Reduce large images to fit. |
| `--zoom PERCENT` | Set the initial zoom percentage. `100` means actual size. |
| `--zoom max` | Use the same sizing behavior as `-Z`. |
| `--zoom fill` | Enlarge images to cover the viewport. Add `-.` to allow reduction too. |
| `--zoom-step PERCENT` | Set the zoom increment. The default is 25%. |
| `--keep-zoom-vp` | Keep the current zoom and image position when switching images. |

Combine `-Z -.` to enlarge or reduce images to fit. Fullscreen reduces large
images by default. With automatic sizing, a numeric `--zoom` value limits the
zoom. For example, `-Z -. --zoom 150` fits images without enlarging beyond 150%.

The default zoom increment multiplies the current zoom by 1.25 when zooming in.
Zooming out divides it by 1.25. For example, 100% becomes 125% or 80%.

`--keep-zoom-vp` keeps the image's top-left position when switching images.
Panning is constrained separately on each axis: smaller images remain inside the
viewport, and larger images continue to cover it. There is one retained view
for the window. Yekk also carries an adjusted zoom when you set a numeric
`--zoom` at startup.

Geometry uses `WIDTHxHEIGHT`, optionally followed by signed X and Y offsets.
For example, `960x640+20+30` requests a 960×640 window, offset 20 from the left
and 30 from the top of the desktop work area. Negative offsets measure from the
right or bottom. Sizes and offsets use points on macOS and logical window pixels on Linux.
These can differ from backing pixels on high-DPI displays. Wayland controls placement.

### Slideshows and source changes

A slideshow advances automatically after a delay.
Source watching checks whether the existing image files have changed.

| Option | Effect |
| --- | --- |
| `-D SECONDS`, `--slideshow-delay SECONDS` | Start a slideshow. A negative delay starts paused, using its absolute value. |
| `--on-last-slide resume` | Continue the slideshow from the first image. |
| `--on-last-slide hold` | Pause on the last image. |
| `--on-last-slide quit` | Close the window after the last image. |
| `-R SECONDS`, `--reload SECONDS` | Check file changes at this interval. Zero disables watching. |

Watching does not search directories for new files. It keeps the last valid image
if a replacement file is incomplete or invalid.

### Text file lists and image information

`-f FILE` or `--filelist FILE` reads one image path per line.
Empty lines are skipped. Both Unix and Windows line endings are accepted.
Relative paths are interpreted from Yekk's working directory.
On close, Yekk saves the remaining image list to that file as absolute paths.

Use `-` or `-f -` to read standard input. This input is never written back.
A missing `-f FILE`, without other image inputs, starts with the current directory.

Text input is limited to 1 MiB. An image list accepts at most 16,384 entries
and 8 MiB of stored path text.
Names containing a line feed or trailing carriage return cannot be saved in this
format. Yekk rejects them before replacing the file. Other save errors return a
nonzero exit status.

Saving uses atomic file replacement. If `FILE` is a symbolic link, saving replaces
the link itself, not its target.

| Option | Output, without opening a window |
| --- | --- |
| `-l`, `--list` | Tab-separated rows with image dimensions, format, pixel count, size, alpha and input path. |
| `-L FORMAT`, `--customlist FORMAT` | One line for each readable image header, formatted with placeholders. |
| `-U`, `--loadable` | Print paths that Yekk decodes. Exit with status 1 if any image fails. |
| `-u`, `--unloadable` | Print paths that Yekk cannot decode. Exit with status 1 if any image succeeds. |
| `--print-filelist` | One path per line. |
| `--formats` | Supported filename extensions for the current decoder backend. |
| `-h`, `--help` | Command-line usage. |
| `-v`, `--version` | Yekk version. |

`--list` and `--customlist` read headers and skip unreadable ones.
The loadability modes decode and release one image at a time. The feh
listing modes keep the path spelling supplied on the command line or read
from a file list. `--print-filelist` prints absolute paths.

For custom output, `%f` prints the path and `%n` prints the filename.
The other metadata placeholders are listed under
[command placeholders](#command-placeholders). In these modes, `-A` runs
once for each row or path printed. These commands write to the terminal or
output stream that started Yekk.

## Triage hooks

A **command hook** runs a shell command when you press its assigned key.
For example, use two commands to move photos into keep or discard directories:

```sh
mkdir -p "$HOME/Pictures/keep" "$HOME/Pictures/discard"
yekk --draw-actions \
  --action1 '[Keep]mv -n %F "$HOME/Pictures/keep/"' \
  --action2 '[Discard]mv -n %F "$HOME/Pictures/discard/"' \
  "$HOME/Pictures/inbox"
```

Press **1** or **2** to move the displayed file. `--action1` through `--action9`
assign commands to keys 1–9. `-A COMMAND` or `--action COMMAND` assigns a command
to Return and 0. `[Title]` sets the label shown by `-G` or `--draw-actions`.
Use `-d` or `--draw-filename` to display the filename over the image.

A command succeeds when its exit status is 0. After success, Yekk selects the
next image. Prefix the command with `;` to reload the current image instead.
For example, `;[Inspect]COMMAND` labels a reload command.
A shell test such as `[ -L %F ]` remains a test because its `[` is followed by a space.

Commands run through `/bin/sh -c` with Yekk's working directory and environment.
Standard input is `/dev/null`, so commands cannot read from the terminal.

### Command placeholders

Yekk replaces placeholders such as `%F` before running the command.
It supplies shell quotation for paths and format names so each becomes one argument.
Do not add quotation marks around `%F`, `%N`, `%t` or `%L`.

| Placeholder | Replacement |
| --- | --- |
| `%F` | Full path of the displayed image file. |
| `%N` | Its filename without the directory. |
| `%w` | Image width in pixels. |
| `%h` | Image height in pixels. |
| `%s` | File size on disk, in bytes. |
| `%S` | File size with a human-readable unit. |
| `%p` | Image pixel count. |
| `%P` | Pixel count with a human-readable unit. |
| `%u` | Image position in the list, starting at 1. |
| `%l` | Number of images in the list. |
| `%g` | Viewport width and height as `W,H`, in backing pixels. |
| `%o` | Image's top-left X and Y position as `X,Y`, in backing pixels. |
| `%z` | Zoom factor with two decimal places. Actual size is 1.00. |
| `%Z` | Zoom factor with eight decimal places in a viewer window. |
| `%r` | Rotation in radians. |
| `%a` | Slideshow state: `playing` or `paused`. |
| `%m` | Current mode, such as `slideshow` or `list`. |
| `%v` | Yekk name and version. |
| `%V` | Yekk process ID. |
| `%t` | Source image format. |
| `%L` | Path to a temporary text file containing this command's copy of the image list. |
| `%%` | A literal percent sign. |

`%o` is measured from the viewport's top-left corner before manual rotation.
Positive X points right. Positive Y points down. Values round to whole pixels.
Yekk removes the `%L` file after the command finishes.
`%f`, `%n` and unknown placeholders cause an error.

### Commands during navigation

A window runs one command at a time. Yekk rejects additional commands until it
finishes. You can select other images while the command runs.
The command uses the file that was displayed when you pressed its key.
Its completion does not advance from a different image you have since selected.

If a command removes the file from its original path, Yekk removes its list entry.
On failure, Yekk reports the exit status and up to 1,024 bytes of output.
Closing the window cancels the command.

Command text accepts up to 4,095 bytes before placeholder replacement and
16,383 bytes afterward. Commands and Trash act on symbolic links themselves,
not the linked files.

## Interface and keys

Hold an arrow key to repeat navigation or zoom at the system repeat rate.

| Key or mouse input | Action |
| --- | --- |
| Space, n, Right | Next image. |
| Backspace, p, Left | Previous image. |
| Home / End | First / last image. |
| Page Up / Page Down | Forward / backward by about 5% of the image list. |
| z | Select a random image. |
| [ / ] | First image in the previous / next consecutive group from another directory. |
| Up / Down | Zoom in / out. |
| * | Actual size: 100% zoom. |
| / | Fit the entire image in the viewport. |
| ! | Fill the viewport, allowing parts of the image outside it. |
| Z | Toggle automatic image sizing. |
| k | Toggle keeping zoom and image position between images. |
| Ctrl + arrows | Pan by 64 backing pixels. |
| Alt + arrows | Pan by 75% of the viewport width or height. |
| < / > | Rotate left / right. |
| underscore / vertical bar | Mirror vertically / horizontally. |
| f | Toggle fullscreen. |
| r | Reload the image file. |
| R | Redraw with smooth scaling. |
| h | Pause or resume the slideshow. |
| + / - | Increase / decrease the file-change check interval. |
| a / d | Show or hide command labels / filename. |
| A | Switch between smooth scaling and nearest-neighbor scaling. |
| i / ? | Show image information / key bindings. |
| Delete | Remove the image from the list without deleting the file. |
| Ctrl + Delete | Request confirmation before moving the file to Trash. |
| m / right click | Open the action menu. |
| Left drag / click | Pan / next image. |
| Middle drag / click | Zoom / actual size. |
| Mouse wheel | Previous / next image. |
| x | Close this window. |
| q / Escape | Quit all windows. |

Hold a next or previous key to view images in order. Each image stays on screen
for at least one frame before another key repeat can advance. Release the key to
stop. A new press can skip an image that is still loading.

For directory navigation, consecutive images from one directory form a group.
`[` and `]` move between those groups in the existing image list.
They do not search for more images.

Smooth scaling blends neighboring pixels. Nearest-neighbor scaling uses the
closest source pixel without blending. Escape dismisses information or help
before quitting. View changes do not modify the image file.

On macOS, trackpad scrolling pans, Command-scroll zooms at the pointer, and pinch
zooms. Command-W closes a window. Command-Q quits all windows.
See [Linux controls](linux.md#desktop-controls) for Linux shortcuts.

### Configuration and key bindings

A key binding assigns a key to a viewer action, such as `next_img` or `action_1`.
Bindings load from `$XDG_CONFIG_HOME/yekk/keys`, default `~/.config/yekk/keys`.
Use `--keys FILE` to read another file.

Each line names an action followed by its keys. A line replaces all bindings for
that action. An action name without keys removes its bindings.
If several lines assign the same key, the last assignment wins.

Prefixes select modifier keys: `C-` for Ctrl, `S-` for Shift, `1-` for Alt/Option,
and `4-` for Super/Command. Uppercase letters imply Shift. Common `KP_*` names select keypad keys.
For example, `C-k` means hold Ctrl and press k.

```text
action_1 1 C-k
action_2 2 C-d
next_img space Right
prev_img BackSpace Left
jump_first Home
jump_last End
```

Use `-T NAME` or `--theme NAME` to load a named theme from a feh
`themes` file. Yekk looks in `$XDG_CONFIG_HOME/feh` or `~/.config/feh`,
then in `/etc/feh`. The theme supplies options before the command line.

Mouse bindings use feh button numbers and the same modifier prefixes as
key bindings. Yekk reads `$XDG_CONFIG_HOME/yekk/buttons`, default
`~/.config/yekk/buttons`. Use `--buttons FILE` to read a different file.

```text
pan 1
zoom 2
action_1 C-1
toggle_menu 3
```

Settings use `key = value` in `$XDG_CONFIG_HOME/yekk/config`, default
`~/.config/yekk/config`. `--config FILE` takes priority over `YEKK_CONFIG` and
the default path. Command-line options override settings from the file.

```text
action_1 = [Keep]mv -n %F "$HOME/Pictures/keep/"
action_2 = [Discard]mv -n %F "$HOME/Pictures/discard/"
```

## Differences and unsupported features

Yekk adds these options:

| Option | Meaning |
| --- | --- |
| `--shuffle` | Same as `--randomize`. |
| `--slideshow SECONDS` | Same as `--slideshow-delay SECONDS`. |
| `--keep-view` | Same as `--keep-zoom-vp`. |
| `--watch` | Enable checks for changes to existing files. |
| `--fit MODE` | Choose an initial sizing mode from the table below. |
| `--aggressive` | Preload the rest of the image list while RAM is available. See [cache policy](cache-and-pressure.md). |

`--browse`, `--config`, `--formats` and `--print-filelist` are also Yekk options,
described above. Yekk's sizing modes are:

| Mode | Initial size |
| --- | --- |
| `shrink` | Reduce large images to fit; keep small images at 100%. This is the default. |
| `fit` | Enlarge or reduce to show the whole image. |
| `fill` | Enlarge or reduce to cover the viewport. |
| `width` | Match the viewport width, allowing vertical cropping. |
| `height` | Match the viewport height, allowing horizontal cropping. |
| `actual` | 100% zoom. |
| `enlarge` | Enlarge small images to fit; keep large images at 100%. |
| `enlarge_fill` | Enlarge until the viewport is covered; never reduce below 100%. |

The `natural` sort mode is a Yekk extension. Directory searches skip names
starting with `.`. Explicit paths can open these files.

Yekk does not support these feh features:

- Pointer hiding.
- Full X11 keysym/keypad coverage and keyboard input from the terminal.
- Captions, EXIF overlays and `--info` shell overlays.
- Source editing and saving transformed images.
- Signal controls and URL downloads.
- Montage, index and thumbnail modes.
- X11/window-manager options, wallpaper setting and `-w`.

Unknown options return exit status 2. See [validation](validation.md) for tests.
