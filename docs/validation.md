# Testing and measurement

Store local reports, captures and profiles under ignored `dist/` paths.
Run commands from the repository root inside the Nix development shell.

## Core checks

```sh
nix develop path:.
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
sh scripts/catalog-test.sh
```

Fixtures cover parsing, navigation, cache policy, hooks, file lists and decoding.
TIFF checks include both byte orders, all orientations, strips, tiles and clipped
edges. Compare complete samples and row padding across workers and predictors.
Check malformed input, allocation failure and retained native references.

Use `-Ddebug-allocator=true` for lifetime checks. Check balanced owned allocations
and zero live owned bytes at exit. Native library allocations need separate tools.
Exercise cancellation, partial failure, pending frames and full release queues.

## macOS

```sh
zig build test -Doptimize=ReleaseSafe -Dtest-gpu=true
sh scripts/smoke.sh
python3 scripts/feh-test.py
python3 scripts/watch-test.py
zig build -Doptimize=ReleaseSafe -Ddebug-allocator=true --prefix zig-out-debug
python3 scripts/stability.py --output dist/stability.json
```

GPU fixtures check color, alpha, scaling and surface ownership.
Integration tests cover navigation, windows, hooks, file lists and source changes.
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

| Script | Purpose |
| --- | --- |
| `linux-validation.py` | Decode, allocation, rendering and warm-cache checks |
| `linux-parity-test.py` | CLI, settings, hooks and shared viewing behavior |
| `linux-desktop-test.py` | Real desktop input, dialogs, drops and monitor profiles |
| `wayland-validation.py` | Run validation or parity tests in private Weston |
| `linux-memory-test.py` | Test oversized-image rejection inside a cgroup limit |

Desktop tests use private Xvfb/D-Bus or Weston sessions. Portal tests accept
`--dialog-driver portal`. The memory test requires a systemd user manager.
It does not fill host RAM. Zig fixtures and `private_bus.py` support these tests.

GUI tests use `supervise.py` for deadlines and process-group cleanup.
`supervisor-test.py` checks its Linux fork/exec guard.
Inject keyboard and pointer input only into private displays.
Test physical monitors, hardware compositors and GPU drivers separately.

## Benchmarking and profiling

Finish builds before timing. Keep source images read-only.
Record binary/source hashes, toolchain, architecture, image layout, backing size,
scale and worker count. Run profilers and capture diagnostics separately.

### Decode measurements

On macOS, build the benchmark and run a decode:

```sh
zig build build-bench-image -Doptimize=ReleaseSafe
./zig-out/bin/yekk-bench-image decode /path/to/scan.tif --workers 4
python3 scripts/bench-image.py /path/to/scan.tif --workers 4 --output dist/decode.jsonl
```

The executable reports stage times, memory and decoded checksums.
`bench-image.py` repeats reads and decodes with file-cache controls.
For another worker count, change `--workers`. Use `--native-predictor` to measure
the library predictor. Check exact native/SIMD output with:

```sh
./zig-out/bin/yekk-bench-image verify tests/fixtures/predictor16-little-tiled.tif --workers 4
```

Linux supplies its own `build-bench-image` backend. Headless modes measure
preparation. Supervised viewer tests also include UI publication:

```sh
python3 scripts/supervise.py ./zig-out/bin/yekk --benchmark-pan --fit actual /path/to/scan.tif
```

Use `compare-viewport.py` to compare saved PNG images.
Separate filesystem-warm, decoded-cache and prepared-view results.
Priming reads, fresh APFS clones and uncached flags do not prove cold storage.
Record actual read bytes. Do not flush host caches.

### Comparing builds

Use minimum times to estimate throughput without host noise. Report frame tail
latency separately. Set warmup and sample counts before testing.
An ABBA block runs the control, candidate, candidate and control in that order.
A BAAB block reverses the order. Randomized blocks reduce time-order bias.
Include an identical-binary control to check the method.

`bench-compare.py` collects trials. `bench-analyze.py` compares the paired minimums
and calculates uncertainty. Keep slow samples and complete the planned trials.
Check order effects and clock resolution before interpreting a small difference.

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

```sh
python3 scripts/bench-compare.py --plan dist/plan.json --blocks 24 --output dist/comparison.json
python3 scripts/bench-analyze.py dist/comparison.json --output dist/analysis.json
```

Count decodes, prepared hits and allocations alongside time.
Confirm navigation targets are cached before asserting zero redecodes.
Measure decode, conversion, preparation, upload and commit separately.
A native display submission does not identify a visible frame.
A heartbeat does not measure hardware input latency. See [package checks](release.md).
