# Performance techniques

Optimize repeated work and memory traffic before instruction count. A cached decoded
image and a prepared view can remove complete pipeline stages. Avoid decoding the same
image again before optimizing pixel loops. Measure whole-image readiness and interaction
separately, using the [benchmark methodology](validation.md#benchmarking-and-profiling).

## Parallel TIFF decoding

The shared Zig decoder handles supported contiguous RGB16 TIFFs. LibTIFF parses storage,
handles byte order and decompresses independently encoded strips or tiles. Other
variants stay with the general-purpose library decoders.

A checked layout places output pixels, copied ICC data, worker records and per-worker
scratch in one aligned image slab. Helpers use independent TIFF handles and disjoint
output regions. Contiguous block ranges avoid a scheduling operation for each block.
After cancellation or failure, the decoder waits for all helpers before it releases the
slab. It publishes only complete decoded images.

The worker writing each output row initializes its padding. This avoids a serial
whole-buffer initialization pass and redundant page writes. For transposed TIFF
orientations, 32×32 output traversal improves locality instead of scattering individual
stores across the image. Orientation selection happens outside the inner pixel loop.
Edge handling preserves clipped tiles and all eight orientations.

Channel insertion uses Accelerate on macOS and vectorized Zig on Linux. Decoded samples
keep 16-bit precision. A separate stage converts samples for display. The native libtiff
predictor remains available as a correctness reference.

## SIMD horizontal prediction

For supported RGB16 Deflate images with TIFF Predictor 2, the Zig predictor reconstructs
three interleaved channel prefix sums modulo 2¹⁶. Eight-sample vectors use shifted
additions. The final three reconstructed samples carry into the next vector. Scalar
tails handle short rows, and carry resets at every row. The decoder disables the library
predictor only for this supported path. The library still decompresses the data.

Correctness requires byte-identical output against the native predictor across byte
orders, widths, tiles, strips and orientations, including row padding. Native prediction
time forms part of library block time. Zig prediction time forms part of conversion
time. These phase times do not measure the same operations. Compare total decode time
and CPU consumption before attributing a change to one phase.

## Resource use and memory traffic

Automatic TIFF concurrency uses performance/physical cores on macOS and physical cores
within process affinity on Linux, with available-core fallbacks. Loads share the worker
budget. Speculative work uses at most half. Two decode lanes, including at most one
speculative load, prevent neighboring images from consuming unbounded concurrent work.
`--decode-workers N` supports explicit tuning.

Production retirement avoids an unnecessary safety-mode write over a dead slab by using
the allocator's raw free boundary. The debug allocator retains poisoning for lifetime
checks. Full pages of finished scratch may be returned through platform memory advice
without touching retained pixels, profiles or metadata. These optimizations require
exclusive ownership. Helpers must finish before Yekk releases their storage.

## Viewport work

Linux keeps source pixels and reusable dyadic reductions. Each dyadic level reduces
image dimensions by a power of two. Filtering uses linear-light premultiplied values,
with three-channel working storage for opaque images. Input conversion combines sRGB
lookup, alpha normalization and premultiplication. Output tiles combine composition and
sRGB encoding, avoiding a full floating-point viewport followed by another conversion
pass.

Opaque sRGB views can bypass floating-point color calculations at actual size and
integer-aligned magnification. The renderer copies 8-bit pixels directly. It converts
normalized 16-bit samples with widened `(sample + 128) / 257` arithmetic. General ICC,
alpha and filtered views use the appropriate color pipeline. Nearest sampling selects
source samples before conversion. Canvas bounds prevent unnecessary pixel reads.

The renderer converts constant background and checker colors once per frame. Opaque and
alpha kernels are selected outside the pixel loop.

Both platforms retain fitted and interaction viewports separately. Exact hits avoid
rendering and upload. Other views render only the display viewport. The [platform
presentation paths](presentation.md) own native buffers and textures. Worker wakeups and
coalesced UI notifications avoid a polling interval on normal request delivery.

## Evaluating changes

Use library decoders until a replacement improves end-to-end performance while
preserving precision, profiles, alpha, malformed-input behavior and ownership. Measure
allocation count, decoded bytes, repeated decodes, memory bandwidth and native costs
alongside wall time. Choose branch-free code or wider SIMD only when the measured
workload benefits. The main cost depends on the image. Storage, decompression, color
conversion, GPU upload or resampling can dominate. A view can require more than one
display frame to complete.
