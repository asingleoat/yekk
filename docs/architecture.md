# Architecture

Yekk uses Zig for shared logic and platform adapters. Nix pins the compiler and
libraries. Zig's C translator imports system and third-party declarations.

## Shared policy and native effects

Validate input at module boundaries. Use types that preserve valid states.
Keep state transitions pure where possible. Platform adapters apply native effects.

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

CLI modes use enums. Optional hook overrides distinguish inherited settings from
disabled hooks. File-list output validates a borrowed `LineList` before writing.

macOS adapters use AppKit, dispatch, ImageIO, Core Image and Core Graphics.
Linux adapters use SDL, libvips, LittleCMS and GIO. Both use the shared policies.

## Allocation and lifetime

Yekk makes one startup allocation and one owned allocation per loaded image
representation. A representation is a decoded image at a given resolution.
Libraries, threads and graphics drivers make separate allocations.

The TIFF slab stores metadata, pixels, ICC data, worker records and scratch.
A slab is one allocation with a checked layout. Catalog capacity is eight windows,
16,384 entries and 8 MiB of copied paths per window.

Workers return immutable results and retain sources until readers finish.
A tagged frame type holds an owned buffer, native reference or exclusive buffer
lease. All readers and the compositor must release a buffer before reuse.

The UI handles bounded state changes and presentation. Workers handle file access,
indexing, decoding, rendering, hooks and resource release. Requests carry revisions.
Handoffs use try-locks and bounded queues. A full release queue keeps ownership
for a later handoff. The UI does not wait for workers or release large buffers.

Closing hides the window before its coordinator cancels and joins workers.
The session slot becomes available after cleanup.

## Image model

Supported source pixels keep 8/16-bit precision and ICC profiles. The RGB16 TIFF
path uses libtiff. Other variants use ImageIO on macOS or libvips on Linux.
Output is SDR. Internal floating-point calculations support filtering and color
conversion. HDR and clipboard operations are outside scope.

See [caching](cache-and-pressure.md), [presentation](presentation.md),
[performance](performance.md) and [region decoding](large-image-paging.md).
