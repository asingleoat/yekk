# Architecture

Shared Zig modules choose behavior. Platform adapters call the OS and native
libraries. Nix pins the compiler and dependencies. Zig's C translator imports
system and third-party declarations.

## Shared policy and native effects

Validate input at module boundaries. Use types that preserve valid states.
Keep state transitions pure where possible. For example, the file-list writer
accepts a validated `LineList` instead of checking raw input during output.

| Modules | Responsibility |
| --- | --- |
| `options.zig`, `cli.zig` | Arguments and overrides |
| `actions.zig`, `view_actions.zig` | Actions, bindings, settings and view changes |
| `navigation.zig`, `catalog.zig` | Discovery, sorting and navigation |
| `geometry.zig`, `core.zig` | Geometry parsing and viewport math |
| `source.zig`, `jpeg_container.zig` | File identity and completeness checks |
| `session_input.zig` | Configuration, keys and file lists |
| `hooks.zig`, `hook_execution.zig`, `commands.zig` | Hook expansion and process execution |
| `cache.zig`, `sessions.zig`, `memory.zig` | Cache policy, sessions and allocation tracking |
| `tiff_pixels.zig` | RGB16 TIFF decoding and SIMD prediction |

macOS uses AppKit, dispatch, ImageIO, Core Image and Core Graphics.
Linux uses SDL, libvips, LittleCMS and GIO. Both adapters use the shared policies.

## Allocation and lifetime

Yekk makes one startup allocation and one owned allocation per loaded image
representation. A representation is a decoded image at a given resolution.
Libraries, threads and graphics drivers make separate allocations.

A TIFF allocation stores pixels, metadata, ICC color profiles, worker records and
temporary buffers. Its layout is checked before allocation. Catalog capacity is
eight windows, 16,384 entries and 8 MiB of copied paths per window.

Workers do not change completed results. Jobs keep source pixels alive until
readers finish. A frame records one of three ownership states:

- An owned buffer.
- A reference to a native display surface.
- An exclusive lease on a reusable buffer.

All readers and the compositor must release a buffer before reuse.

## UI and workers

The UI handles bounded state changes and presentation. Workers handle file access,
indexing, decoding, rendering, hooks and resource release.

Requests carry revision numbers. Only a result for the current request can replace
the display. The UI tries locks without waiting and defers work when a lock is busy.
Queues have fixed capacity. If the release queue is full, the UI keeps ownership
and tries the handoff later.

Closing first hides the window. Its coordinator cancels work and waits for workers
to finish. The session slot becomes available after cleanup.

## Image model

Supported source pixels keep 8/16-bit precision and ICC color profiles.
The shared RGB16 TIFF decoder uses libtiff. Other variants use ImageIO on macOS
or libvips on Linux.

Display output is standard dynamic range (SDR). Floating-point calculations
support filtering and color conversion. HDR and clipboard operations are outside scope.

See [caching](cache-and-pressure.md), [presentation](presentation.md),
[performance](performance.md) and [region decoding](large-image-paging.md).
