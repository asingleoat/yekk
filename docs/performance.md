# Performance techniques

## TIFF decoding

The shared Zig decoder handles supported contiguous RGB16 TIFFs. libtiff parses
storage, normalizes byte order and decompresses strips or tiles.
Other variants use the general library decoders.

One aligned slab holds pixels, copied ICC data, worker records and scratch.
Workers use independent TIFF handles and disjoint output regions.
Contiguous block ranges avoid per-block scheduling. Failure or cancellation
joins all helpers before releasing storage. The decoder publishes only complete images.

Each worker initializes its output row padding. This avoids a separate pass over
the whole buffer. Transposed orientations use 32×32 traversal for cache locality.
Orientation selection occurs outside the pixel loop. Channel insertion uses
Accelerate on macOS and vectorized Zig on Linux.

## SIMD prediction

For supported RGB16 Deflate TIFFs with Predictor 2, Zig reconstructs three
interleaved channel prefix sums modulo 2¹⁶. Eight-sample vectors use shifted
additions. The last three reconstructed samples carry into the next vector.
Scalar tails handle short rows. Carry resets at each row.

This path disables the library predictor but keeps library decompression.
Output must match the native predictor byte for byte, including padding.
Native predictor time belongs to block decoding. Zig predictor time belongs to
conversion. Compare total decode time when evaluating these implementations.

## Workers and memory

Automatic TIFF concurrency uses performance or physical cores on macOS.
Linux uses physical cores within process affinity, with an available-core
fallback. Loads share the budget. See [scheduling limits](cache-and-pressure.md#background-limits).

Production frees use the allocator's raw free interface to avoid overwriting a
dead slab. The debug allocator keeps poisoning for lifetime checks.
After helpers finish, dead scratch pages use `MADV_FREE` on macOS or
`MADV_DONTNEED` on Linux. Live pixels and metadata remain untouched.
Memory advice does not guarantee an immediate RSS reduction.

## Viewport rendering

Linux keeps source pixels and dyadic reductions. Each level reduces dimensions
by a power of two. Opaque images use three-channel working storage.
Input conversion combines sRGB lookup, alpha normalization and premultiplication.
Output tiles combine composition and sRGB encoding without a second full-view pass.

Eligible integer-aligned opaque sRGB views bypass floating-point color work.
The renderer copies 8-bit pixels or converts normalized 16-bit samples with
widened `(sample + 128) / 257` arithmetic. Other views use the color pipeline.
Nearest sampling selects source samples before conversion.

Canvas bounds prevent unnecessary reads. Background and checker colors convert
once per frame. The renderer selects opaque and alpha kernels outside pixel loops.
Worker notifications avoid polling delays for normal requests.
See [presentation](presentation.md) for native surfaces and textures.

## Measurement

Remove repeated work before optimizing instructions. Measure allocations, decoded
bytes, repeated decodes, memory traffic and native costs alongside elapsed time.
Use branch-free code or SIMD when measurements show a benefit.

Replace library decoders only after correctness and end-to-end performance checks.
Preserve precision, profiles, alpha, malformed-input behavior and ownership.
The main cost depends on the image and view. See [benchmarking](validation.md#benchmarking-and-profiling).
