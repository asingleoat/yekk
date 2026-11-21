# Architecture

Yekk shares navigation, settings, hooks and view calculations between macOS and
Linux. Platform adapters translate operating-system events into shared actions
and call native window, decoder and graphics APIs.

Nix selects the compiler and dependency versions recorded in `flake.lock`.
Zig's C translator imports declarations from system and third-party headers.
Shared logic and platform adapters are Zig.

## Shared policy and native effects

Validate input before passing it to code that assumes valid data.
For example, `LineList` checks image-order indices and rejects filenames that
cannot occupy one line in a text file. The writer then accepts that validated
value without repeating those checks during output.

Use pure functions for parsing and state calculations where possible.
A pure function computes its result from its arguments without file access or
changes to external state. Platform adapters then read files, update windows or run commands.

| Modules | Responsibility |
| --- | --- |
| `options.zig`, `cli.zig` | Command-line arguments and setting overrides |
| `actions.zig`, `view_actions.zig` | Actions, key bindings, settings and view changes |
| `navigation.zig`, `catalog.zig` | Directory discovery, sorting and navigation |
| `geometry.zig`, `core.zig` | Window geometry and image-position calculations |
| `source.zig`, `jpeg_container.zig`, `exif.zig` | File identity, completeness and bounded orientation metadata |
| `session_input.zig` | Configuration, key files and image-list files |
| `hooks.zig`, `hook_execution.zig`, `commands.zig` | Command substitution and child-process execution |
| `cache.zig`, `sessions.zig`, `memory.zig` | Cache policy, window sessions and allocation counters |
| `tiff_pixels.zig` | Shared RGB16 TIFF decoding and SIMD prediction |
| `png.zig`, `pnm.zig` | Shared PNG and Netpbm decoding |
| `jpeg.zig`, `jpeg_entropy.zig` | Shared JPEG storage, metadata, Huffman decoding and libjpeg-turbo adapter |
| `jxl_pixels.zig` | Shared libjxl adapter |
| `raw_pixels.zig` | Shared LibRaw adapter for camera sensor data |
| `pixel_storage.zig` | Owned pixel slabs and temporary-buffer reclamation |

macOS uses AppKit, dispatch, ImageIO, Core Image and Core Graphics.
Linux uses SDL, libvips, LittleCMS and GIO. These APIs differ; shared application
policies do not depend on them.

## Images and views

A **decoded image** contains source pixels and metadata, including its color
profile. A **prepared view** contains the pixels needed for a particular window
size, zoom and pan position. A large source can produce many different views.

The **catalog** stores image paths and file properties for a window.
It has space for 16,384 entries and 8 MiB of path text. The process has eight
window slots. These are structural limits, separate from image-cache memory.

Yekk makes one startup allocation and one owned allocation per loaded image
representation. A representation is a decoded image at a given resolution.
The TIFF, PNG and direct JPEG allocations include pixels, metadata and temporary
buffers. TIFF also stores worker records. Libraries, threads and graphics drivers
make separate allocations.

## Ownership and lifetime

An owner must release the resource it holds. A retained reference keeps native
storage alive until that reference is released. Workers keep source references
while reading pixels and do not change completed results.

A **frame** is the display result passed from a worker to the UI.
Its tagged type records one of three storage states:

- An owned pixel buffer.
- A retained reference to a native display surface.
- An exclusive lease on a reusable buffer.

A lease reserves the buffer for a job or frame. Other writers cannot reuse it
until the lease ends. Readers and the window compositor must finish before reuse.
The compositor is the system component that combines window contents for display.

## UI and workers

The UI thread handles input and updates windows. Background workers handle file
access, indexing, decoding, rendering, commands and large resource releases.

Every view request has a revision number. If the user requests B while A is
loading, A's completion cannot replace B. The UI tries locks without waiting
and defers work when a lock is busy.

Work queues have fixed capacity. If the cleanup queue is full, the UI keeps its
resource reference and retries the handoff later. Closing first hides the window.
Worker cancellation and cleanup finish before its window slot becomes available again.

## Image model

Supported source pixels keep 8/16-bit precision and ICC color profiles.
An ICC profile describes how to interpret the image's color values.
The shared RGB16 TIFF decoder uses libtiff. Shared Zig code decodes PBM, PGM
and PPM. Both platforms use libjxl for JPEG XL and LibRaw for camera RAW. Linux uses SDL for BMP. Other variants use
ImageIO on macOS or enabled libvips codecs on Linux. See [image input checks](input-safety.md).

Display output is standard dynamic range (SDR). Floating-point calculations
support filtering and color conversion. HDR and clipboard operations are outside scope.

See [caching](cache-and-pressure.md), [presentation](presentation.md),
[performance](performance.md) and [region decoding](large-image-paging.md).
