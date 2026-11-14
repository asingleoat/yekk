# Viewport presentation

The viewport is the visible area of the window. Workers render that output from
cached decoded pixels. Display surfaces need only viewport dimensions, even when
the source image exceeds GPU texture limits. Image decoding runs on the CPU.

## Coordinates and color

Transforms map source pixels to display backing pixels. They include scale,
rotation, mirroring and pan. Actual size maps one source pixel to one backing
pixel, independently of UI scale.

Filtering uses linear-light values, which represent light intensity.
Alpha represents opacity. Before mixing transparent pixels, the renderer
multiplies color values by alpha.
This is premultiplied alpha. It preserves correct colors at transparent edges.

Output is SDR. Source precision and ICC color profiles remain attached to the
cached image. Display profiles have version numbers. A prepared view must match
the current version. See [view reuse](cache-and-pressure.md#reuse-and-prefetch).

## macOS

A worker creates a shared Core Image context on the system-selected Metal device.
When available, the device's recommended working-set size guides the render budget.
Each loaded image creates its Core Image source once.

Processing uses 32-bit float in extended linear sRGB. Output uses 16-bit float
in an IOSurface, which is shared pixel storage. The worker waits for rendering
to finish before making the result available. Core Animation displays that surface.
A CGImage provider exposes the same pixels for inspection and caching.

The provider owns a surface reference and read lock. Native layers hold separate
references. Workers release the final storage reference. Jobs keep their source
pixels alive through invalidation or close. If shared rendering fails, the
renderer returns a completed CGImage. Software rendering uses this path too.

Each window has two preallocated job records and one replaceable pending view.
The main queue can display ready cache hits during another render.
Workers clear intermediate caches under memory pressure.

## Linux

Workers prepare and upload viewport textures through SDL GPU/Vulkan.
They wait for upload completion before reusing temporary upload storage.
The UI copies to an available swapchain image: a GPU buffer for window display.
If none is available, it retries later. SDL's renderer is the fallback.
Use `--software` to select software rendering.

Readers and the compositor must release leased buffers before reuse.
Monitor or profile changes queue color-transform replacement on a worker.
Version checks reject old frames. Invalid or missing profiles use sRGB.
See [rendering techniques](performance.md#viewport-rendering).

Native calls can still incur driver or compositor delays.
See [validation](validation.md) for color, lifetime and timing checks.
