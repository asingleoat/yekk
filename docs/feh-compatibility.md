# feh compatibility

Yekk supports part of [feh's interface](https://man.finalrewind.org/1/feh/).
CLI behavior is shared across platforms. See [Linux](linux.md) for native controls.

## Command line

Options support bundles (`-FZD3`), attached values (`-Sfilename`) and long-option
values with `=`. `--` ends option parsing.

With no arguments, Yekk opens the current directory. A file argument opens only that file.
`--browse FILE` includes other images from the same directory. `--start-at FILE` alone opens its directory
and selects the file. With other paths, it selects the file within that list.

| Options | Behavior |
| --- | --- |
| `-g`, `--geometry WxH[±X±Y]` | Window size and edge-relative position |
| `-x`, `--borderless`; `-F`, `--fullscreen` | Borderless window; fullscreen |
| `-r`, `--recursive`, `--no-recursive` | Directory recursion without following directory symlinks |
| `-S`, `--sort` | `name` (path), `filename`, `dirname`, `mtime` (newest first), `size` (ascending), `none`, `natural` |
| `--version-sort` | Natural numeric comparison for name/path/directory sorts |
| `-n`, `--reverse`; `-z`, `--randomize` | Reverse; shuffle, with reshuffle on forward wrap |
| `-Z`, `--auto-zoom` | Enlarge small images |
| `-.`, `--scale-down` | Reduce large images to fit |
| `--zoom PERCENT\|max\|fill` | Initial zoom |
| `--zoom-step PERCENT` | Multiplicative zoom increment, default 25% |
| `--keep-zoom-vp` | Carry numeric zoom and image origin between images, within valid bounds |
| `-D`, `--slideshow-delay SECONDS` | Slideshow delay; negative values start paused |
| `--on-last-slide resume\|hold\|quit` | Wrap, pause or close at the final timed slide |
| `-R`, `--reload SECONDS` | Poll source changes; zero disables watching |
| `-A`, `--action`; `--action1` … `--action9` | Shell command hooks |
| `-G`, `--draw-actions`; `-d`, `--draw-filename` | Action and filename overlays |
| `-f`, `--filelist FILE` | Read paths and save the remaining list on close |
| `-`, `-f -` | Read paths from stdin without saving |
| `-\|`, `--start-at FILE` | Select a file |
| `-l`, `--list` | Header metadata, including dimensions and encoded size |
| `-h`, `--help`; `-v`, `--version` | Usage; version |

Combine `-Z` and `-.` to fit in both directions. Fullscreen reduces large images
by default. `--keep-zoom-vp` does not restore a separate view for each image.

Yekk also supports `--fit`, `--browse`, `--shuffle`, `--slideshow`, `--watch`,
`--keep-view`, `--config`, `--formats` and `--print-filelist`.
`--print-filelist` prints plain paths. Listing commands do not open windows.
Metadata listing reads headers and does not verify full decoding.

### File lists

Lists accept newline-delimited paths and skip empty lines. CRLF is accepted.
Input accepts at most 1 MiB, 16,384 entries and 8 MiB of copied paths.
Relative paths use the working directory. Saved paths are absolute.
Hooks and Trash preserve a file symlink's name and act on the link.

Saving atomically replaces the named file, including a symlink at that name.
Names containing a line feed (LF) or trailing carriage return (CR) are rejected before replacement.
Save errors return a nonzero exit status. A missing `-f` file without other
inputs starts with the current directory.

## Triage hooks

Create destination directories. Start Yekk:

```sh
mkdir -p "$HOME/Pictures/keep" "$HOME/Pictures/discard"
yekk --draw-actions \
  --action1 '[Keep]mv -n %F "$HOME/Pictures/keep/"' \
  --action2 '[Discard]mv -n %F "$HOME/Pictures/discard/"' \
  "$HOME/Pictures/inbox"
```

Press **1** or **2** to move the displayed file. Return or 0 runs `--action`.
`[Title]` sets the action label. A leading `;` reloads after success instead of
advancing. A test such as `[ -L %F ]` remains a shell expression.

Hooks run through `/bin/sh -c` with the viewer's environment and working directory.
Stdin is `/dev/null`. `%F` and `%N` already include shell quotation.
Do not add quotation marks around them. Use `%%` for a literal percent sign.

| Placeholder | Value |
| --- | --- |
| `%F`, `%N` | Full path; filename without its directory |
| `%w`, `%h` | Image width; height in pixels |
| `%s`, `%S` | Encoded file size in bytes; decimal MB |
| `%p`, `%P` | Pixel count; decimal megapixels |
| `%u`, `%l` | Current position, starting at 1; file-list count |
| `%g` | Viewport width and height as `W,H`, in backing pixels |
| `%o` | Image offset as `X,Y`, in backing pixels |
| `%z`, `%Z` | Zoom percentage with two; eight decimal places |
| `%r` | Rotation in radians |
| `%a` | `playing` or `paused` |
| `%m` | `slideshow` |
| `%v`, `%V` | Yekk version; process ID |
| `%t` | Source image format |
| `%L` | Path to a temporary snapshot of the ordered file list |
| `%%` | Literal percent sign |

Path and format values include shell quotation. `%L` creates one snapshot per
command and removes it afterward. `%f`, `%n` and unknown specifiers cause an error.

Each window runs one hook at a time. Navigation remains available.
Completion cannot advance a newer selection. If a hook moves the source away,
Yekk removes its entry. Failure prevents automatic advance and reports the exit
code with up to 1 KiB of output. Closing cancels the hook's process group.

Descriptions accept 4095 bytes. Expanded commands accept 16,383 bytes.

## Interface and keys

Hold an arrow key to repeat navigation or zoom at the system repeat rate.

| Keys / mouse | Action |
| --- | --- |
| Space, n, Right / Backspace, p, Left | Next / previous; wrap by default |
| Home / End | First / last |
| Page Up / Page Down | Forward / backward approximately 5% |
| z; [ / ] | Random image; previous / next directory sequence |
| Up / Down; *; /; ! | Zoom in / out; actual pixels; fit; fill |
| Z; k | Toggle auto zoom; keep viewport |
| Ctrl + arrows; Alt + arrows | Pan by a step; pan by a page |
| < / >; underscore; vertical bar | Rotate left / right; mirror vertically / horizontally |
| f; r; R; h | Fullscreen; reload; filtered rendering; pause slideshow |
| + / - | Increase / decrease watch interval |
| a; d; A; i; ? | Actions; filename; filtering; information; bindings |
| Delete; Ctrl + Delete | Remove entry; confirmed Trash |
| m / right click | Action menu |
| Left drag / click | Pan / next image |
| Middle drag / click | Zoom / actual pixels |
| Mouse wheel | Previous / next |
| Trackpad scroll; Cmd + scroll; pinch | Pan; pointer zoom; zoom on macOS |
| x / Cmd-W; q / Escape / Cmd-Q | Close window; quit all; Command shortcuts on macOS |

Escape dismisses information or help before quitting. View changes do not rewrite
files. Actual size means one source pixel per display backing pixel.

Bindings load from `$XDG_CONFIG_HOME/yekk/keys`, default `~/.config/yekk/keys`.
Use `--keys FILE` for another file. Each line replaces an action's bindings.
An action without keys removes its bindings. Later bindings win key conflicts.
Key prefixes select modifiers: `C-` is Ctrl, `S-` is Shift, `1-` is Alt/Option and `4-` is Super/Command.
Uppercase letters imply Shift.

```text
action_1 1 C-k
action_2 2 C-d
next_img space Right
prev_img BackSpace Left
jump_first Home
jump_last End
```

Settings use `key = value` in `$XDG_CONFIG_HOME/yekk/config`, default
`~/.config/yekk/config`. `--config FILE` overrides `YEKK_CONFIG` and the default
path. CLI settings take precedence over file settings.

```text
action_1 = [Keep]mv -n %F "$HOME/Pictures/keep/"
action_2 = [Discard]mv -n %F "$HOME/Pictures/discard/"
```

## Differences and remaining work

Discovery defaults to natural order and skips hidden entries. Explicit hidden
file arguments work. Windowed sizing defaults to shrink-to-fit.
Source watching updates existing entries without rescanning directories.
Metadata output is not byte-compatible with feh.

Yekk does not support these feh features:

- Themes, custom button files and pointer hiding.
- Full X11 keysym/keypad coverage and terminal input.
- Captions, EXIF overlays and `--info` shell overlays.
- Custom list formatting, `--loadable`, `--unloadable` and dimension/format sorts.
- Source editing and saving transformed images.
- Signal controls, URL downloads and terminal hook output streaming.
- Montage, index and thumbnail modes.
- X11/window-manager options, wallpaper setting and `-w`.

Unknown options return status 2. See [validation](validation.md) for tests.
