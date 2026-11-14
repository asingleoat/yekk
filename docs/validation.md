# Validation and measurement

Keep regression fixtures and reusable test/profiling tools in the repository. Write raw
measurements, captures, profiles and local qualification reports under ignored `dist/`
paths. Documentation describes current techniques and contracts. Results from one
machine do not guarantee product performance.

## Core checks

```sh
nix develop path:.
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe
sh scripts/catalog-test.sh
python3 scripts/supervisor-test.py
```

Unit and decoder checks cover validated options, view math, navigation, cache policy,
source identity, hooks and file-list output. TIFF fixtures exercise exact 16-bit
samples, both byte orders, strips/tiles, clipped edges and all eight orientations.
Compare whole output including padding across worker counts and native/SIMD predictors.
Validate malformed, truncated and unsupported inputs, checked dimensions, allocation
failure and independent native references.

Use `-Ddebug-allocator=true` to detect owned allocation/lifetime errors. Check
allocation balance. Check for zero live owned bytes at exit. Use separate tools to check
native frameworks and codecs. Closing, cancellation and partial failure must join
helpers and retire every frame lease. Exercise saturated retirement queues as well as
ordinary delivery.

Avoid tests that merely reproduce an implementation detail.

## macOS

```sh
zig build test -Doptimize=ReleaseSafe -Dtest-gpu=true
sh scripts/smoke.sh
python3 scripts/feh-test.py
python3 scripts/watch-test.py
zig build -Doptimize=ReleaseSafe -Ddebug-allocator=true --prefix zig-out-debug
python3 scripts/stability.py --output dist/stability.json
```

The GPU checks complement software fixtures for color, alpha, scaling, ownership and
prepared surfaces. Supervised integration checks exercise rapid navigation, independent
windows, source replacement, shell hooks and persistent file lists. Stability runs
alternate speculative prefetch availability and inject failure without forcing
system-wide memory pressure. Source-write tests use temporary copies. Physical monitor,
minimum-OS and native Intel coverage remain separate from software fixtures or Rosetta
execution.

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

Desktop tests provide private Xvfb/window-manager/D-Bus or Weston sessions. Portal mode
(`--dialog-driver portal`) adds private portal services. Checks include chooser
lifetime, independent windows, escaped drops, key/pointer input, ICC changes and
geometry. Memory tests require a systemd user manager and apply an isolated test-only
cgroup limit to reject a sparse oversized image before allocation. They do not fill host
RAM. Private desktop tests do not substitute for physical HiDPI, monitor changes,
hardware Wayland or additional GPU/driver coverage.

Every graphical invocation uses `scripts/supervise.py` for deadlines, process-group
cleanup and recursive-viewer detection. Automated keyboard/pointer injection is confined
to private displays. Decoder-only tools do not open windows.

## Benchmarking and profiling

Finish compilation and packaging before collecting timings. Record source and executable
hashes, toolchain, architecture, image layout/size, viewport backing size, scale, worker
count and relevant flags. Keep full-resolution source data read-only. Run profiling and
checksum/capture diagnostics separately from timing trials so their overhead does not
contaminate comparisons.

On macOS, the decoder benchmark can be built and run with:

```sh
zig build build-bench-image -Doptimize=ReleaseSafe
python3 scripts/bench-image.py /path/to/scan.tif --workers 4 --output dist/decode.jsonl
python3 scripts/measure-phases.py /path/to/scan.tif --output dist/phases.jsonl
python3 scripts/compare-predictor.py /path/to/scan.tif --output dist/predictor.jsonl
python3 scripts/supervise.py ./zig-out/bin/yekk --benchmark-pan --fit actual /path/to/scan.tif
```

The Linux build supplies its own `build-bench-image` backend. Headless render, pan and
zoom modes measure preparation. Supervised viewer tests also include UI publication. Use
`scripts/compare-viewport.py` for saved-image comparisons and platform profilers for CPU
stacks, allocation traffic and native/driver behavior.

Distinguish filesystem-warm, decoded-cache and prepared-view hits. A priming read is not
a cold-storage experiment. Fresh APFS clone inodes and uncached file flags do not
eliminate device or controller caches. Record actual read-byte counts for storage
measurements. Do not flush the host's global caches.

Host noise generally prolongs execution. Use minimum times or lower envelopes to
estimate throughput without interference. Report interactive frame tail latency
separately. For close changes, preselect warmup and sample counts, randomize matched
ABBA/BAAB blocks, and include an identical-binary control. `scripts/bench-compare.py`
executes JSON plans and `scripts/bench-analyze.py` analyzes paired block results. Check
order effects, autocorrelation and clock resolution.

Keep slow samples. Complete the planned sample count before you compare results.
Inconclusive differences stay inconclusive.

A minimal comparison plan uses the same image, view size and workers for both binaries.
Save this locally as `dist/plan.json`, changing paths as needed:

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

Count decodes, prepared hits and allocations alongside latency. Establish that both
navigation targets are resident before asserting zero warm redecodes. Measure decode,
conversion, viewport preparation, upload and commit separately. A native commit
timestamp is not a visible frame, and a heartbeat is not measured hardware input
latency. Repeat representative formats, orientations and view sizes before generalizing
a local improvement.

For portability and mounted/extracted-package checks, see [release
preparation](release.md).
