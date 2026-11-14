# Testing and measurement

Store local reports, captures and profiles under ignored `dist/` paths.

## Core checks

```sh
nix develop path:.
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
sh scripts/catalog-test.sh
python3 scripts/supervisor-test.py
```

Fixtures cover parsing, navigation, cache policy, hooks, file lists and decoding.
TIFF checks include both byte orders, all orientations, strips, tiles and clipped
edges. Compare complete samples and padding across workers and predictors.
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
python3 scripts/linux-validation.py
python3 scripts/linux-parity-test.py
python3 scripts/linux-desktop-test.py --instant-click
python3 scripts/wayland-validation.py --parity
python3 scripts/wayland-validation.py --parity --scale 2 --output dist/wayland-scale2.json
python3 scripts/linux-memory-test.py
```

Desktop tests use private Xvfb/D-Bus or Weston sessions. Portal tests accept
`--dialog-driver portal`. Memory tests require a systemd user manager and apply
a private cgroup limit. They reject oversized images without filling host RAM.

GUI tests use `scripts/supervise.py` for deadlines and process-group cleanup.
Inject keyboard and pointer input only into private displays.
Test physical monitors, hardware compositors and GPU drivers separately.

## Benchmarking and profiling

Finish builds before timing. Keep source images read-only.
Record binary/source hashes, toolchain, architecture, image layout, backing size,
scale and worker count. Run profilers and capture diagnostics separately.

On macOS:

```sh
zig build build-bench-image -Doptimize=ReleaseSafe
python3 scripts/bench-image.py /path/to/scan.tif --workers 4 --output dist/decode.jsonl
python3 scripts/measure-phases.py /path/to/scan.tif --output dist/phases.jsonl
python3 scripts/compare-predictor.py /path/to/scan.tif --output dist/predictor.jsonl
python3 scripts/supervise.py ./zig-out/bin/yekk --benchmark-pan --fit actual /path/to/scan.tif
```

Linux supplies its own `build-bench-image` backend. Headless modes measure
preparation. Viewer tests include UI publication. Use `scripts/compare-viewport.py`
for saved-image comparisons.

Separate filesystem-warm, decoded-cache and prepared-view results.
Priming reads, fresh APFS clones and uncached flags do not prove cold storage.
Record actual read bytes. Do not flush host caches.

Use minimum times or lower envelopes to estimate throughput without host noise.
Report frame tail latency separately. For close comparisons, fix warmup and sample
counts before testing. Use randomized ABBA/BAAB blocks and an identical-binary
control. Check order effects, autocorrelation and clock resolution.
Keep slow samples and complete the planned trials.

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
Confirm navigation targets are resident before asserting zero redecodes.
Measure decode, conversion, preparation, upload and commit separately.
A commit timestamp does not identify a visible frame. A heartbeat does not measure
hardware input latency. See [package checks](release.md).
