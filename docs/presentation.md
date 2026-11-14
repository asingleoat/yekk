# Viewport presentation

Workers render a color-managed viewport from retained decoded pixels.
Display surfaces cover the viewport, so source dimensions can exceed GPU
texture limits. Image decoding runs on the CPU.

## Coordinates and color

Transforms map source pixels to display backing pixels. They include scale,
rotation, mirroring and pan. Actual size maps one source pixel to one backing
pixel, independently of UI scale.

Filtering and alpha composition use linear-light, premultiplied values.
Output is SDR. Source precision and ICC profiles remain attached to the image.
View keys include the output-profile generation. See [view reuse](cache-and-pressure.md#reuse-and-prefetch).

## macOS

A worker creates a shared Core Image context on the system-selected Metal device.
The device's recommended working-set size guides its render-task budget.
Each loaded image creates its CIImage once.

Processing uses 32-bit float in extended linear sRGB. The GPU renders to a
half-float IOSurface. The worker waits for completion before publication.
Core Animation receives the surface directly. A read-only CGImage provider
holds the same storage for inspection and caching.

The provider owns a surface reference and read lock. Native layers hold separate
references. Workers release final storage references. Jobs retain source pixels
through invalidation or close. If shared rendering fails, the renderer returns
a completed CGImage. Software rendering uses the same fallback.

Each window has two startup-owned job records and one replaceable desired view.
The main queue can display ready hits during another render. Pressure clears
intermediate caches on workers.

## Linux

SDL GPU/Vulkan presents worker-prepared viewport textures. Workers finish uploads
before reusing staging storage. The UI copies to an available swapchain image.
If none is available, it retries later. SDL's renderer is the fallback.
Use `--software` to select software rendering.

Readers and the compositor must release leased buffers before reuse.
Monitor or profile changes queue worker-side transform replacement.
Generation checks reject old frames. Invalid or missing profiles use sRGB.
See [rendering techniques](performance.md#viewport-rendering).

Native calls can still incur driver or compositor delays.
See [validation](validation.md) for color, lifetime and timing checks.
