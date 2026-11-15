# Testing and measurement

See [image input checks](input-safety.md) for the decoder trust boundary and
the supervised malformed-file corpus.

Run commands from the repository root inside the Nix development shell.
Store local reports, captures and profiles under ignored `dist/` paths.

## Core checks

```sh
nix develop path:.
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
sh scripts/catalog-test.sh
```

A **test fixture** is a file with known pixels or deliberately invalid structure.
Fixtures cover parsing, navigation, cache policy, commands, image lists and decoding.
TIFF checks include both byte orders, all orientations, strips, tiles and clipped edges.
Compare complete samples and row padding across worker counts and predictors.

Use `-Ddebug-allocator=true` for allocation and lifetime checks.
Require equal owned allocation/free counts and `live_bytes=0` when the process exits.
Native libraries allocate outside these counters.

Test malformed input and allocation failure. Close windows while work is pending.
Check that native image references remain readable for their required lifetime.
Exercise full cleanup queues, where the UI must defer release without losing ownership.

## macOS

```sh
zig build test -Doptimize=ReleaseSafe -Dtest-gpu=true
sh scripts/smoke.sh
python3 scripts/feh-test.py
python3 scripts/watch-test.py
zig build -Doptimize=ReleaseSafe -Ddebug-allocator=true --prefix zig-out-debug
python3 scripts/stability.py --output dist/stability.json
```

GPU fixtures check color, alpha, scaling and display-surface ownership.
Integration tests exercise the application through its input and worker paths.
They cover navigation, windows, commands, image lists and source changes.
Stability tests inject failures and vary prefetch availability.
Tests that write source files use temporary copies.

## Linux

```sh
zig build test -Doptimize=ReleaseSafe -Ddebug-allocator=true
zig build -Doptimize=ReleaseSafe -Ddebug-allocator=true
python3 scripts/supervisor-test.py
python3 scripts/linux-validation.py
python3 scripts/linux-parity-test.py
python3 scripts/linux-desktop-test.py --instant-click
python3 scripts/wayland-validation.py --parity
python3 scripts/wayland-validation.py --parity --scale 2 --output dist/wayland-scale2.json
python3 scripts/linux-memory-test.py
```

Here, **parity** means matching macOS behavior for shared options and actions,
not matching its execution times.

| Script | Purpose |
| --- | --- |
| `linux-validation.py` | Decode, allocation, rendering and cached-navigation checks. |
| `linux-parity-test.py` | Command line, settings, shell commands and shared viewing behavior. |
| `linux-desktop-test.py` | Desktop input, dialogs, file drops and monitor profiles. |
| `wayland-validation.py` | Run validation or parity tests in a separate Weston compositor. |
| `linux-memory-test.py` | Check oversized-image rejection inside a cgroup memory limit. |

Xvfb supplies an X11 display without a physical screen. Weston supplies a Wayland
compositor. Tests create separate displays and D-Bus service connections.
Their keyboard and pointer events do not target the user's desktop.
`--scale 2` tests two backing pixels per logical window unit on each axis.

Portal tests accept `--dialog-driver portal` and start private file-dialog services.
The memory test requires a systemd user manager. It limits its own cgroup, a Linux
resource-control group, rather than filling host RAM.
Zig fixtures and `private_bus.py` support these tests.

GUI tests use `supervise.py` for deadlines, child-process cleanup and recursive
viewer detection. `supervisor-test.py` checks that ordinary launch helpers are
accepted and a newly executed viewer copy is rejected.
Test physical monitors, hardware compositors and GPU drivers separately.

## Benchmarking and profiling

For comparisons with other viewers, see the [photo-review task](viewer-comparison.md).
It measures complete window pixels with the same external check for each viewer.

A benchmark measures elapsed time for specified work. A profiler records where
time or allocations occur. Run them separately so profiling overhead does not
change the timing comparison. Finish builds first and keep source images read-only.

Record the binary/source hashes, compiler, architecture, image layout, viewport
size, display scale and worker count. A backing pixel is one pixel in the window's
drawing buffer; it can differ from a logical window-coordinate unit.

### Decode measurements

On macOS, build the benchmark and run a decode:

```sh
zig build build-bench-image -Doptimize=ReleaseFast
./zig-out/bin/yekk-bench-image decode /path/to/scan.tif --workers 4
python3 scripts/bench-image.py /path/to/scan.tif --workers 4 --output dist/decode.jsonl
```

The executable reports stage times, memory and a decoded-pixel checksum.
`bench-image.py` repeats reads and decodes with file-cache controls.
Change `--workers` to compare CPU worker counts.
Use `--native-predictor` to measure libtiff's horizontal predictor instead of Zig's.
The `verify` mode checks their complete output bytes:

```sh
./zig-out/bin/yekk-bench-image verify tests/fixtures/predictor16-little-tiled.tif --workers 4
```

Linux supplies its own `build-bench-image` backend.
Headless modes create no visible window and measure preparation work.
Supervised viewer benchmarks also submit results to the window system:

```sh
python3 scripts/supervise.py ./zig-out/bin/yekk --benchmark-pan --fit actual /path/to/scan.tif
```

Use `compare-viewport.py` to compare saved PNG pixels.
Keep these cache states separate in timing results:

| State | Work reused |
| --- | --- |
| Filesystem-warm | The OS already has file data, but Yekk still decodes it. |
| Decoded-image hit | Yekk reuses source pixels, but a new view can need rendering. |
| Prepared-view hit | Yekk reuses viewport pixels; final display work remains. |

A priming read reads the file before timing to populate the OS file cache.
An APFS clone is a new file that shares stored data blocks with the original.
Neither this nor uncached-read flags prove that storage-device caches are cold.
Record actual read bytes. Do not flush host caches.

### Comparing builds

Benchmark shared changes on Linux and macOS when possible. Report each platform
separately. State which workloads or platforms were not measured.

The **control** is the reference binary; the **candidate** contains the change.
Set warmup and sample counts before testing. Use minimum times to estimate
throughput without host noise. Report slow requests separately and name the timed stage.

Record the build mode. Production uses `ReleaseFast`; compare `ReleaseSmall`
before selecting it for a target. Use `ReleaseSafe` and the debug allocator for
checked validation, separate from performance measurements.

An ABBA group runs control, candidate, candidate and control.
A BAAB group reverses that order. Randomized groups reduce time-order bias.
Include an identical-binary comparison to check the method.
Set both `control` and `candidate` to the same executable path for this check.

`bench-compare.py` collects trials. `bench-analyze.py` selects the faster control
and candidate result within each group, then compares these paired minimums.
For example, A=10, B=12, B=11, A=14 ms contributes A=10 and B=11 ms.
The candidate/control ratio for this group is 1.1.

The analyzer combines groups and reports uncertainty and order checks.
A ratio below 1 favors the candidate. It can still classify the result as
inconclusive when those checks fail. Keep slow samples and complete the planned trials.
Clock resolution is the smallest time difference the timer can distinguish.
Results below it cannot support a precise speed comparison.

Save a comparison plan as `dist/plan.json`:

```json
{
  "image": "/path/to/scan.tif",
  "workers": 4,
  "width": 1920,
  "height": 1080,
  "comparisons": [{
    "name": "pan", "mode": "pan", "metric": "steady",
    "control": "/path/to/baseline/yekk-bench-image",
    "candidate": "/path/to/candidate/yekk-bench-image"
  }]
}
```

`workers: null` keeps the binary's automatic worker budget.
The `process` metric measures the whole headless process, including startup and
cleanup. `decode` measures the decoder record. `load` measures the full source
load before frame preparation; it includes decoder setup and decoded pixel storage.
`width` and `height` specify backing pixels. `mode` selects the benchmark workload.
The `steady` metric uses median preparation time after four warmup frames per process.
The analyzer then takes the faster process result for each variant within a group.

```sh
python3 scripts/bench-compare.py --plan dist/plan.json --blocks 24 --output dist/comparison.json
python3 scripts/bench-analyze.py dist/comparison.json --output dist/analysis.json
```

Count decodes, prepared-view hits and allocations alongside time.
Confirm navigation targets are cached before asserting zero redecodes.
Measure decode, conversion, preparation, upload and display submission separately.
Submission records when Yekk hands pixels to the window system, not when they become visible.
A heartbeat measures UI timer callbacks, not hardware input latency.
See [package checks](release.md).
