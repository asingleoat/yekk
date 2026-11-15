# Viewer comparison

This test measures time spent waiting while reviewing three photos.
It compares Yekk, feh and imv on one Linux machine.

## Task

1. Open photo 1 fitted to the window. Inspect it at 100%, then fit it again.
2. Do the same for photos 2 and 3.
3. Return to photo 2, inspect it at 100%, then fit it again.
4. Return to photo 1 and inspect it at 100%.

At 100%, one source pixel maps to one window pixel.
After opening or switching photos, wait two seconds at fit-to-window, including
return visits. Wait one second after each 100% view. Do not pause after a fit reset.
These pauses allow background loading and represent inspection time.

The main result is the sum of the 14 action times, excluding the fixed pauses.
Each time bar shows the fastest complete run of six. Colors separate the first
photo, the next two photos and the two return visits. Ticks show all six runs.
All parts of a bar come from the same run.
Memory bars show the largest peak viewer RSS across the six runs. RSS is memory
held in RAM by that process; it excludes the separate display server and test driver.

## Results

| Images | Viewer | Minimum wait (s) | Maximum wait (s) | Peak RAM (GiB) |
| --- | --- | ---: | ---: | ---: |
| TIFF | Yekk | 1.38 | 2.77 | 6.08 |
| TIFF | feh | 17.57 | 20.60 | 4.63 |
| TIFF | imv | 26.23 | 30.95 | 4.45 |
| JPEG | Yekk | 0.54 | 0.86 | 0.84 |
| JPEG | feh | 0.96 | 1.16 | 0.28 |
| JPEG | imv | 1.24 | 2.04 | 0.57 |

The first 100% TIFF view took 13 ms in one Yekk run and 200–720 ms in the other
five. feh and imv took 10–38 ms for that action. For the first fitted JPEG view,
minimum time was 0.24 s for feh and 0.44 s for Yekk.

## Conditions

- AMD Ryzen 9 7950X, 16 cores; 125 GiB usable RAM. Other jobs ran on the machine.
- Yekk source `ce189c0`, ReleaseSafe, debug allocator disabled; feh 3.13.1; imv 5.0.1.
- Three 239 MP RGB TIFF scans, 16 bits per channel, with Deflate compression, 1.09–1.24 GB each.
- JPEG copies of the same photos: 23–24 MP RGB, 8 bits per channel, quality 90, 5–14 MB each.
- A 960×640-pixel window on a private Xvfb X11 display at scale 1.
- Yekk uses SDL software rendering; imv uses Mesa software OpenGL. feh uses Imlib2.
- Yekk uses its default prefetch and cache policy. imv uses its default policy.
  feh uses a 2,047 MiB cache. This is one MiB below its
  [documented limit](https://man.finalrewind.org/1/feh/) and fits Imlib2's signed
  integer cache-size interface.

Read all three files before starting each viewer process. This populates the OS
file cache. Each process starts with no decoded images. This is a file-cache-warm
test, not a storage-speed test. No host caches are flushed.

Run all six viewer-order permutations once, in a fixed shuffled order. Keep every
completed trial. Minimum times reduce the effect of unrelated work that can delay
execution. Small differences remain inconclusive.

## Measurement limits

The test driver sends an X11 key event, then reads the complete client window.
Timing stops when its pixels match an untimed reference for that viewer and task
step. Startup timing begins before launching the common process supervisor.
Earlier previews do not end the timer unless they match the reference.

Reference captures must be stable and show the expected image and zoom.
Each viewer has its own references because filtering and color conversion differ.
The test checks when a view is ready, not equal image quality.

Readback, hashing and a two-millisecond polling pause add measurement overhead.
This is an off-screen CPU test. It does not measure physical screen latency,
GPU performance, macOS performance, storage-cold loads or long browsing sessions
under memory pressure. The scans are private and are not distributed.

## Repeat the task

Build a production binary as described in the [README](../README.md#build-and-run).
Use a new output directory for each binary, configuration or image set.
On Linux, get the benchmark tools from the pinned Nix input:

```sh
mkdir -p dist
nix build --impure --expr '
  let f = builtins.getFlake (toString ./.);
      p = import f.inputs.nixpkgs-unstable { system = builtins.currentSystem; };
  in p.buildEnv {
    name = "viewer-benchmark-tools";
    paths = [ p.feh p.imv p.openbox p.xorg-server p.procps
      (p.python3.withPackages (ps: [ ps.python-xlib ps.pillow ps.matplotlib ])) ];
  }' --out-link dist/viewer-tools
export PATH="$PWD/dist/viewer-tools/bin:$PATH"
```

```sh
python3 scripts/compare-viewers.py --calibrate --output dist/viewers \
  --yekk zig-out/bin/yekk photo1.tif photo2.tif photo3.tif
python3 scripts/compare-viewers.py --rounds 6 --output dist/viewers \
  --yekk zig-out/bin/yekk photo1.tif photo2.tif photo3.tif
```

Inspect the reference captures before accepting timings. Raw measurements, logs
and captures stay under `dist/`. GUI processes run under the supervisor and input
is restricted to the display created by the script.

See the [action times](assets/viewer-comparison.csv) and
[build and image metadata](assets/viewer-comparison.json).
Regenerate the chart with:

```sh
python3 scripts/compare-viewers.py --plot-csv docs/assets/viewer-comparison.csv \
  --output docs/assets/viewer-comparison.svg
```
