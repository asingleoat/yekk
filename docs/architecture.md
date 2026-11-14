# Architecture

Yekk's priorities are stability, responsive interaction and reuse of expensive work.
Application and platform code is Zig. Zig's C translator imports system and third-party
declarations from header files. Third-party libraries keep their native implementations.
The toolchain and libraries are pinned through Nix.

## Shared policy and native effects

Put behavior that does not depend on the platform in shared modules. Validate input at
module boundaries. Use types that preserve valid states. Keep state transitions pure
where possible. Platform adapters translate native events and apply effects.

| Modules | Responsibility |
| --- | --- |
| `options.zig`, `cli.zig` | Argument syntax, validated options and overrides |
| `actions.zig`, `view_actions.zig` | Actions, bindings, settings and view transitions |
| `navigation.zig`, `catalog.zig` | List boundaries, slideshow endpoints, discovery and sorting |
| `geometry.zig`, `core.zig` | Geometry parsing and viewport math |
| `source.zig`, `jpeg_container.zig` | File identity, preflight and JPEG completeness checks |
| `session_input.zig` | Configuration, keys and atomic file-list output |
| `hooks.zig`, `hook_execution.zig`, `commands.zig` | Hook expansion, manifests, child execution and cancellation |
| `cache.zig`, `sessions.zig`, `memory.zig` | Cache/admission policy, session routing and allocation instrumentation |
| `tiff_pixels.zig` | Checked RGB16 TIFF decoding and SIMD prediction |

The CLI listing mode uses an enum. An optional hook override distinguishes inherited
settings from a disabled hook. Window offsets carry their edge, including negative zero.
File-list output first constructs a validated, borrowed `LineList`. The writer then
creates a temporary file and replaces the destination. The writer does not repeat
validation.

macOS adapters integrate AppKit, dispatch, ImageIO, Core Image and Core Graphics. Linux
adapters integrate SDL, libvips, LittleCMS and GIO. Each adapter manages its native
event loop, workers and resource ownership. Both adapters use shared CLI, navigation,
hook and view policies. Linux input and desktop fixtures are Zig too.

## Allocation and lifetime

Yekk makes one startup allocation for fixed-capacity state and one owned allocation per
loaded image representation. A representation is one decoded version of an image at a
given resolution. A slab is one allocation that stores related data. The TIFF slab holds
metadata, pixels, ICC data, worker records and scratch storage. Yekk checks all sizes
before allocation. Libraries, frameworks, threads and graphics drivers make separate
allocations.

The allocation contract counts only allocations that Yekk owns.

Catalog storage has structural bounds: eight windows, 16,384 entries and 8 MiB of copied
paths per window. These limits apply to catalog storage. The image cache has no fixed
byte limit or limit based on a fraction of RAM.

Workers return owned immutable results. Jobs retain their sources, and native surfaces
can retain pixels independently of the image wrapper. Frame storage uses a tagged type
to record ownership. It contains an owned buffer, a native surface reference or an
exclusive lease on a reusable viewport buffer. A buffer is available for reuse only
after all readers and the compositor release their leases.

The UI performs bounded state changes and native presentation. Retirement means the
release of image and display resources after their users finish. Indexing, file access,
decoding, rendering, hooks and heavy retirement run on workers. Handoffs use revisions,
replaceable pending requests, try-locks and bounded queues. A full retirement queue
preserves ownership for a later handoff rather than freeing storage or waiting on the UI
thread. Closing first hides the window.

Its coordinator then cancels work and waits for workers to finish. The session slot
becomes available after cleanup. Native presentation calls still require latency
measurement.

## Image model

Source pixels retain supported 8/16-bit precision and ICC profiles. The common RGB16
TIFF path uses libtiff. Other formats and TIFF variants use ImageIO on macOS or libvips
on Linux. Decoder replacement requires correctness and end-to-end performance evidence,
including malformed input and color handling.

Output is SDR. Floating-point working pixels support linear-light filtering, color
conversion and alpha composition. HDR and clipboard operations are outside product
scope. Full decoded images support repeated 100% inspection. Source-region paging is
[future work](large-image-paging.md).

See [caching](cache-and-pressure.md), [presentation](presentation.md) and [performance
techniques](performance.md) for the data paths and scheduling rules.
