# feh compatibility

Yekk follows feh's single-image browsing and triage workflow. The reference is [feh's
upstream manual](https://man.finalrewind.org/1/feh/). Both platforms use shared CLI and
action policies. Native key modifiers, menus and desktop integration differ. See the
[Linux reference](linux.md).

## Command line

Short options can be bundled (`-FZD3`), value options accept attached arguments
(`-Sfilename`) and long options accept `=` (`--action1='mv %F keep/'`). `--` ends option
parsing. With no image arguments, Yekk discovers images in the current directory. A
single explicit image stays a one-image list. `--browse FILE` includes other images from
the same directory. `--start-at FILE` alone discovers images in the same directory and
selects that image.

With other paths, it selects that file in the resulting list.

| Options | Behavior |
| --- | --- |
| `-g`, `--geometry WxH[±X±Y]`; `-x`, `--borderless` | Native window size/edge-relative position in points; borderless windows retain keyboard focus and close actions |
| `-F`, `--fullscreen` | Native fullscreen |
| `-r`, `--recursive`, `--no-recursive` | Background directory discovery; directory symlinks are not traversed |
| `-S`, `--sort` | `name` (full path), `filename` (basename), `dirname`, `mtime` (newest first), `size` (ascending), `none`; `natural` is a Yekk extension |
| `--version-sort` | Natural numeric comparison for path/name/directory sorting |
| `-n`, `--reverse`; `-z`, `--randomize` | Reverse or shuffle; randomized lists reshuffle on forward wrap |
| `-Z`, `--auto-zoom`; `-.`, `--scale-down` | Enlarge small images; shrink large images. Combine them to fit in both directions, in either order. Fullscreen also shrinks large images by default. |
| `--zoom PERCENT\|max\|fill`, `--zoom-step PERCENT` | Initial zoom and multiplicative zoom increment (25% default) |
| `--keep-zoom-vp` | Carry the current numeric zoom and image origin between images, constrained to valid viewport bounds; this is not per-image view restoration |
| `-D`, `--slideshow-delay SECONDS` | Timed navigation; negative values start paused |
| `--on-last-slide resume\|hold\|quit` | Wrap, pause or close on the final timed slide |
| `-R`, `--reload SECONDS` | Poll existing sources for changes; zero disables watching |
| `-A`, `--action`; `--action1` … `--action9` | Explicit shell command hooks |
| `-G`, `--draw-actions`; `-d`, `--draw-filename` | Toggleable native text overlays |
| `-f`, `--filelist FILE` | Read newline-delimited paths and save the remaining ordered list atomically on close; create a missing list |
| `-`, `-f -` | Read a newline-delimited list from stdin; never write back to stdin |
| `-\|`, `--start-at FILE` | Select a particular image |
| `-l`, `--list` | Header metadata table: number, format, oriented dimensions, pixels, encoded bytes and filename |
| `-h`, `--help`; `-v`, `--version` | Usage and Yekk version |

Yekk also supports `--fit`, `--browse`, `--shuffle`, `--slideshow`, `--watch`,
`--keep-view`, `--config`, `--formats` and `--print-filelist`. The last prints plain
paths. Both list modes run without windows. Metadata listing reads headers, without
decoding all image pixels, so it is not a full decodability check.

File lists are bounded to 1 MiB of input and the normal 16,384 entries / 8 MiB catalog
path capacity. Paths are relative to the working directory when read and written as
absolute paths with resolved parent directories. A file symlink's final filename is
preserved: hooks, Trash act on the link, whether opened directly or discovered in its
directory. Target identity is inspected separately for source-change detection. Empty
lines are skipped. Command-line arguments and `%F` support newlines in filenames.

File lists cannot represent those names. Saving such a name fails and keeps the existing
list unchanged. A missing `-f` file with no other inputs discovers the current
directory. Saving atomically replaces the named file. If that name identifies a symlink,
saving replaces the link itself. A save error is reported on stderr with a failing exit
status.

## Triage hooks

1. Create the destination directories.
2. Start Yekk with the hook commands:

```sh
mkdir -p "$HOME/Pictures/keep" "$HOME/Pictures/discard"
yekk --draw-actions \
  --action1 '[Keep]mv -n %F "$HOME/Pictures/keep/"' \
  --action2 '[Discard]mv -n %F "$HOME/Pictures/discard/"' \
  "$HOME/Pictures/inbox"
```

Press **1** or **2** to run the corresponding command on the displayed source. Return or
0 runs `--action`. Numbers 1–9 run the numbered hooks. `[Title]` sets the displayed
action name. Put `;` before the title or command to reload the current source after
success. This prevents automatic advance.

A bracketed shell test that starts with a space, such as `[ -L %F ]`, remains a shell
expression.

Commands run through `/bin/sh -c` on workers. They inherit the viewer's working
directory and environment. They read stdin from `/dev/null`. Yekk supplies shell
quotation for `%F` and `%N`. Do not add quotation marks around these placeholders.
Literal shell percent signs must be written `%%`.

Supported substitutions: `%F`, `%N`, `%w`, `%h`, `%s`, `%S`, `%p`, `%P`, `%l`, `%u`,
`%g`, `%o`, `%r`, `%z`, `%Z`, `%a`, `%m`, `%v`, `%V`, `%t`, `%L`, `%%`. `%t` queries the
source header only when requested. `%L` writes a snapshot of the ordered file list on a
worker. All `%L` substitutions in that command use the same path. The worker removes the
snapshot after the command finishes. `%v` identifies Yekk.

`%m` is `slideshow`. `%g` and `%o` use display backing pixels. `%f` / `%n` and unknown
specifiers fail rather than insert an unsafe filename or ambiguous expansion.

Each window has one active hook slot. Repeated requests while it is busy are rejected
without queuing more processes. The hook captures source identity and selection
revision. Navigation remains usable while it runs. Completion does not advance a newer
selection. If the captured path disappeared, Yekk removes its entry.

A different selected image stays selected. Failed commands keep their source selected
and report their exit code and up to 1 KiB of captured output. Successful commands
advance or reload as above. Yekk drains further output so verbose commands cannot
deadlock on its pipe.

Closing cancels the active hook's process group, escalates to SIGKILL after 300 ms if
necessary, and reaps the shell on the worker. Only an explicit key or menu action starts
the hook shell. Opening files and Finder launch callbacks do not start another Yekk
process.

Hook descriptions (up to 4095 bytes), expanded commands (up to 16,383 bytes), job
snapshots, bindings and catalog metadata occupy the existing startup slab. There is no
additional Yekk heap allocation for running a hook. Native process, dispatch, codec and
graphics allocations remain outside the owned-allocation contract.

## Interface and keys

Holding Right/Left repeats next/previous navigation at the system keyboard repeat rate
on both platforms. Up/Down similarly repeat zoom. New requests advance from the latest
selection while background rendering catches up.

| Keys / mouse | Action |
| --- | --- |
| Space, n, Right / Backspace, p, Left | Next / previous; wrap by default |
| Home / End | First / last |
| Page Up / Page Down | Forward / backward approximately 5% |
| z; [ / ] | Random image; previous / next directory sequence |
| Up / Down; *; /; ! | Zoom in / out; actual pixels; fit; fill |
| Z; k | Toggle auto zoom; keep viewport |
| Ctrl + arrows; Alt + arrows | Pan by a step; pan by a page |
| < / >; underscore; vertical bar | Temporary left / right rotation; vertical / horizontal mirror |
| f; r; R; h | Fullscreen; reload source; render with filtering; pause slideshow |
| + / - | Increase / decrease source watch interval |
| a; d; A; i; ? | Actions; filename; filtering; information; active bindings |
| Delete; Ctrl + Delete | Remove entry; confirmed Trash |
| m / right click | Native Actions menu |
| Left drag / click | Pan / next image |
| Middle drag / click | Zoom / actual pixels |
| Mouse wheel | Previous / next |
| Trackpad scroll; Cmd + scroll; pinch | Pan; zoom at pointer; zoom |
| x / Cmd-W; q / Escape / Cmd-Q | Close window; quit all |

Escape dismisses an information/help overlay before quitting. View operations do not
rewrite sources. Actual size is one source pixel per display backing pixel.

Bindings load from `$XDG_CONFIG_HOME/yekk/keys`, or `~/.config/yekk/keys`. `--keys FILE`
can point directly to an existing feh keys file. Each line uses `action key1 key2 ...`.
An action with no keys removes its bindings. A line replaces all previous keys for that
action, and a later binding wins a key conflict. Supported modifiers are `C-`, `S-`,
`1-` (Option) and `4-` (Command), including combinations.

Uppercase letters imply Shift. Common named keys and punctuation names work.
Keypad-specific X11 keysyms are not supported.

```text
action_1 1 C-k
action_2 2 C-d
next_img space Right
prev_img BackSpace Left
jump_first Home
jump_last End
```

Yekk's existing `key = value` configuration remains in `$XDG_CONFIG_HOME/yekk/config`
(default `~/.config/yekk/config`), with `--config FILE` / `YEKK_CONFIG` overrides. CLI
values take precedence. For persistent command descriptions it additionally accepts:

```text
action_1 = [Keep]mv -n %F "$HOME/Pictures/keep/"
action_2 = [Discard]mv -n %F "$HOME/Pictures/discard/"
```

## Differences and remaining work

Directory discovery uses natural order by default. It skips hidden directory entries.
Explicit hidden file arguments work. Default sizing remains shrink to fit in a native
window. `Z` toggles fit/shrink behavior. Source change polling avoids re-decoding
unchanged files and does not rescan folders for newly added files.

Filelist output columns are similar to feh, not a byte-compatible report. A nonzero hook
status intentionally prevents automatic advance. Terminal key input and terminal/stdout
streaming from hooks are not implemented.

Yekk does not support these feh features:

- Themes, custom button files and pointer hiding.
- Full X11 keysym and keypad coverage.
- Captions, EXIF overlays and `--info` shell overlays.
- Custom list formatting, `--loadable`, `--unloadable` and dimension/format sorts.
- Source editing and saving transformed images.
- Signal controls and URL downloads.
- Montage, index and thumbnail modes.
- X11/window-manager options and wallpaper setting.

Unknown CLI options fail with exit status 2. Native Finder opening supports eight
sessions in one process. Yekk does not support feh's `-w` command-line mode.

See [validation](validation.md) for reusable CLI, binding, hook and desktop checks.
