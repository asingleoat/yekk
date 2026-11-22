# Performance techniques

See [caching](cache-and-pressure.md) for reuse of decoded images and prepared views.
This guide describes work performed when those results are not already available.

## TIFF decoding

The shared Zig decoder handles supported interleaved 16-bit RGB TIFFs.
Each pixel stores red, green and blue samples together, with 16 bits per sample.
libtiff reads the file structure, converts samples to the machine's byte order
and decompresses the pixels. Other TIFF variants use the general decoders.

TIFF divides images into row strips or rectangular tiles. Workers decode separate
blocks with separate libtiff file handles. Each writes a different output region.
Consecutive block ranges avoid a shared queue operation for every block.
A single large compressed strip provides little block-level parallelism.

One allocation holds pixels, color-profile data, worker records and temporary
buffers. Row padding is unused space between the end of one pixel row and the
start of the next. Each worker initializes that padding while writing its rows.
This avoids a separate initialization pass over the whole image.
Cancellation waits for workers before freeing their storage.

Orientations that exchange width and height use 32×32 blocks for output writes.
This lets successive writes reuse small regions of CPU cache.
Platform code converts RGB to RGBA by adding an opaque alpha channel.
macOS uses Apple's Accelerate routines. Linux uses vectorized Zig.

## PNM decoding

Shared Zig code decodes PBM, PGM and PPM files. One allocation holds the image
record and RGBA pixels. RGBA adds an alpha value to each red, green and blue pixel.
Large binary images share the decoder worker budget. Each worker reads input
into the end of its own output region. Conversion proceeds forward, so each
input sample is read before output can overwrite it. This avoids a second
image-sized allocation and copy. Workers also clear row padding. All workers
finish before their shared allocation can be released.

The decoder selects sample width, channel count and sample-range conversion
before entering pixel loops. Full-range 8-bit and 16-bit samples need no scaling.
Other ranges use checked integer scaling. Header probing does not decode pixels.

## PNG and JPEG decoding

PNG header parsing plans one allocation for pixels, ICC data, compressed input
and filter buffers. The decoder reads IDAT payloads directly into that storage
and checks CRCs during the read. libdeflate expands the zlib stream. Zig restores
row filters and expands samples to RGBA without a separate full-file copy.
The common RGB8 path selects its pixel layout outside the pixel loop.

The shared JPEG adapter stores compressed
input, pixels, ICC data and orientation buffers in one allocation. The native
decoder does not retain another copy of Exif or ICC data. Rotated output uses
small cache tiles.

JPEG represents image blocks with coefficients: numbers that describe patterns
of brightness and color. Huffman coding assigns bit patterns of different
lengths to these numbers. In sequential JPEG, each block is encoded in one scan.
Zig combines a Huffman code and its following value bits in one lookup.
Longer codes use checked code tables. JPEG inserts a zero after each compressed
data byte with value 255; Zig removes these zeros in the owned input buffer.
libjpeg-turbo retains the integer
inverse transform, chroma upsampling and color output. The result must match its
stock decoder byte for byte. Progressive images and images with restart markers
retain the stock decoder.

The adapter reads the initial fields of two internal C structures. Their layout
is checked against libjpeg-turbo 3.2.0 with `JPEG_LIB_VERSION=62`. Other library
builds retain their existing decoder. TurboJPEG catches decode errors in C and
returns failure to Zig. The tables use worker stack storage.

On macOS, only supported sequential JPEGs with chroma subsampling use the shared
path. Chroma subsampling stores fewer color samples than brightness samples.
ImageIO retains full-chroma and other JPEG variants. This keeps its faster
hardware path for the tested full-chroma scan.

These paths reuse the worker queues and decoded-image cache. They do not add
decode work to the UI thread. Production can return completed temporary-buffer
pages to the OS while retaining decoded pixels.

## JPEG XL and camera RAW

libjxl reads JPEG XL in blocks and writes the first image into the cache.
It applies the image orientation and retains integer sample precision,
transparency and the color profile. The macOS decoder uses this path to reject
truncated streams. ImageIO accepted truncated examples in local checks.

LibRaw unpacks the sensor samples and develops them into a 16-bit sRGB image.
Development uses camera white balance when available. It includes demosaicing,
which estimates the missing color channels at each sensor pixel. The viewer
caches the developed image at full resolution. On Linux and Apple Silicon,
LibRaw uses OpenMP to run parts of development on multiple CPU cores. These
workers share the viewer decode budget. The viewer releases LibRaw's
development buffer before it allocates the cached image.

Measure unpacking and development separately when comparing RAW decoders.
Replacing the unpacker can only reduce the first cost. Use the same camera
file, color settings and output precision when checking a faster path.

## SIMD prediction

TIFF Predictor 2 stores differences between adjacent samples of the same channel.
The decoder adds those differences to reconstruct the original values:

```text
Stored values:   10,  2,  3
Decoded values:  10, 12, 15
```

Single Instruction, Multiple Data (SIMD) applies one CPU operation to several
values at once. Zig processes eight 16-bit samples per vector.
It carries the last value for each color channel into the next vector.
Remaining samples are handled one at a time. Each row starts with fresh state.
Arithmetic wraps at 65,536: adding 1 to 65,535 produces 0.

This path replaces prediction. libtiff still performs Deflate decompression.
The reconstructed pixels and padding must match the library predictor byte for byte.

The library includes prediction in block-decode time. Zig records it in conversion
time. Compare total decode time when evaluating these paths.

## Workers and memory

macOS selects performance or physical CPU cores. Linux counts physical cores
allowed by the process's CPU affinity: the CPUs it is permitted to run on.
Available logical CPUs provide a fallback when physical-core information is unavailable.
Loads share this worker budget. See [background limits](cache-and-pressure.md#background-limits).

Production cleanup avoids overwriting an entire image allocation before freeing it.
The debug allocator keeps memory poisoning: writes of known patterns that help
expose access to released storage. Keep debug-allocator measurements separate
from production measurements.

After workers finish, Yekk can advise the OS that full pages of temporary storage
are no longer needed. It uses `MADV_FREE` on macOS or `MADV_DONTNEED` on Linux.
A page is an OS memory-management unit. Live pixels and metadata remain available.
This advice does not guarantee an immediate reduction in resident memory,
the part of the process currently held in RAM.

## Viewport rendering

Linux caches smaller versions of the source image. Each level halves width and
height. A 4000×3000 image can therefore reuse a 2000×1500 or 1000×750 level.
Nearby zoom levels use these pixels instead of reducing the full image again.

Opaque images use three color channels in working buffers. They need no alpha
channel there. Input conversion combines color conversion and alpha calculations.
Output conversion combines background composition and sRGB encoding in one pass.

Some opaque sRGB views need neither filtering nor profile conversion.
When their pixels align with the output grid, they can use integer conversion.
The renderer copies 8-bit pixels directly. It converts unsigned 16-bit samples
with `(sample + 128) / 257`, using wider integers to prevent overflow.
For example, 65,535 becomes 255. Other views use the general color pipeline.

The renderer skips pixels outside the image area. It converts background colors
once per frame and selects opaque or alpha-processing code outside pixel loops.
Workers notify the UI when results are ready. Normal requests need no polling delay.
See [presentation](presentation.md) for native display surfaces and color calculations.

## Build mode

Production builds use `ReleaseFast`. Compare `ReleaseSmall` with the same input,
CPU target and decoder settings before selecting it. Smaller code can improve
instruction-cache use, but it can also reduce loop optimization.
Use paired minimum times and keep slow samples. See [benchmarking](validation.md#comparing-builds).

## Measurement

Remove repeated work before optimizing instructions. Measure elapsed time,
allocations, decoded bytes, repeated decodes and time spent in decoder or graphics libraries.
Use branch-free code or SIMD when measurements show a benefit.

Compare complete image loading as well as individual routines.
A replacement decoder must preserve pixels, color profiles, alpha, error handling
and ownership while improving end-to-end performance.
See [benchmarking](validation.md#benchmarking-and-profiling).
