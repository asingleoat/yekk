# Yekk

I paid for the whole machine and I'm going to use the whole machine.

Yekk is an image viewer for macOS and Linux, written in Zig. It aggressively caches decoded image data to make interactive use as snappy as possible. It will use all of your RAM if it can, and politely return it when the OS requests.

Runs on macOS 14+ or Linux with X11 or Wayland.

Download macOS and Linux binaries from [Releases](https://github.com/asingleoat/yekk/releases).

## Build and run

[Nix](https://nixos.org/) supplies the pinned Zig master and dependencies.

```sh
nix develop path:.
zig build -Doptimize=ReleaseSafe
./zig-out/bin/yekk /path/to/photos
```

With no arguments, Yekk opens the current directory. A file argument opens only
that image. Use `--browse FILE` to include other images from the same directory.
Use `-r` to include subdirectories. Use `--help` to list options.

## Controls

| Control | Action |
| --- | --- |
| Left / Right | Previous / next image |
| Up / Down | Zoom in / out |
| * | Actual size |
| / | Fit to window |
| Left drag | Pan |
| ? | Show key bindings |
| q | Quit |

See the [feh compatibility reference](docs/feh-compatibility.md) for options,
controls, configuration and hook examples.

## Documentation

- [Linux support](docs/linux.md)
- [Architecture](docs/architecture.md)
- [Performance techniques](docs/performance.md)
- [Testing and benchmarks](docs/validation.md)
- [Release packaging](docs/release.md)

Licensed under [GPL-3.0-or-later](LICENSE).
