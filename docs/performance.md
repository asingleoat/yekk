# Performance techniques

See [caching](cache-and-pressure.md) for reuse of decoded images and prepared views.
This guide covers the work needed when those results are not already available.

## TIFF decoding

The shared Zig decoder handles supported interleaved 16-bit RGB TIFFs. Each pixel stores
red, green and blue samples together. libtiff reads the file structure, converts
byte order and decompresses the pixels. Other TIFF variants use the general decoders.

TIFF divides images into row strips or rectangular tiles. Workers decode separate
blocks with separate libtiff handles. Each worker writes a different output region.
Consecutive block ranges avoid a shared queue operation for every block.

One allocation holds pixels, color-profile data, worker records and temporary
buffers. Each worker initializes its own row padding. This avoids a separate
initialization pass over the image. Cancellation waits for all workers before
freeing that storage. The decoder publishes only complete images.

Orientations that exchange width and height use 32×32 blocks for output writes.
This keeps nearby writes close together in memory. Platform code adds the opaque
alpha channel with Accelerate on macOS and vectorized Zig on Linux.

## SIMD prediction

TIFF Predictor 2 stores differences between adjacent samples of the same channel.
The decoder adds those differences to reconstruct the original values:

```text
Stored values:   10,  2,  3
Decoded values:  10, 12, 15
```

SIMD applies one CPU operation to several values at once. Zig processes eight
16-bit samples per vector. It carries the last value for each color channel into
the next vector. It handles remaining samples one at a time. Each row starts
with fresh state. Arithmetic wraps at 65,536, as required for 16-bit samples.

This path replaces prediction, not Deflate decompression. libtiff still decompresses
the data. The reconstructed pixels and padding must match the library predictor
byte for byte.

The library includes prediction in block-decode time. Zig records it in conversion
time. Compare total decode time when evaluating these paths.

## Workers and memory

macOS selects performance or physical cores. Linux counts physical cores allowed
by the process's CPU affinity. Available logical cores provide a fallback.
Loads share this worker budget. See [background limits](cache-and-pressure.md#background-limits).

Production cleanup avoids overwriting an entire image allocation before freeing it.
The debug allocator keeps memory poisoning to detect lifetime errors.

After workers finish, full pages of unused temporary storage can be released with
`MADV_FREE` on macOS or `MADV_DONTNEED` on Linux. Live pixels and metadata remain
available. This memory advice does not guarantee an immediate reduction in resident memory.

## Viewport rendering

Linux caches smaller versions of the source image. Each level halves width and
height. Nearby zoom levels can reuse these pixels instead of reducing the full
image again.

Opaque images use three color channels in working buffers. They need no alpha
channel there. Input conversion combines color conversion and alpha calculations.
Output conversion combines background composition and sRGB encoding in one pass.

Aligned opaque sRGB views can use integer conversion when they need no filtering
or profile conversion. The renderer copies 8-bit pixels directly. It converts
normalized 16-bit samples with `(sample + 128) / 257`, using wider integers to
prevent overflow. Other views use the general color pipeline.

The renderer skips pixels outside the image area. It converts background colors
once per frame and selects opaque or alpha-processing code outside pixel loops.
Workers notify the UI when results are ready. No polling delay is needed for
normal requests. See [presentation](presentation.md) for native display surfaces.

## Measurement

Remove repeated work before optimizing instructions. Measure elapsed time,
allocations, decoded bytes, repeated decodes and native-library costs.
Use branch-free code or SIMD when measurements show a benefit.

A replacement decoder must improve end-to-end performance while preserving pixels,
color profiles, alpha, error handling and ownership. See [benchmarking](validation.md#benchmarking-and-profiling).
