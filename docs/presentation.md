# Viewport presentation

Yekk retains the decoded, orientation-correct source and prepares a color-managed
viewport on a worker. Only viewport-sized display surfaces are required, so full source
dimensions do not depend on a single GPU texture's maximum size. Image decoding remains
on the CPU.

## Shared model

Transforms map source pixels to drawable backing pixels, including scale, rotation,
mirroring, pan and pixel-aligned actual size. Actual size means one source pixel per
backing pixel, independently of logical UI scale. Source precision and ICC profiles
remain attached to the cached image.

Filtering and alpha composition use linear-light, premultiplied values. Floating-point
working storage supports these calculations. Display output is SDR. The surrounding
canvas is separate from projected image edges. View keys include rendering inputs and
output-profile generation, preventing reuse across incompatible transforms or display
profiles.

Automatic fitted views and the most recent interaction view have separate cache roles.
Manual zoom preserves fit. An exact cached view needs no source decoding or viewport
rendering. A new pan position can require viewport rendering. Workers publish immutable
completed outputs, and only a matching current request can replace the display. Old
valid pixels remain visible while work is pending.

## macOS

A shared Core Image context is initialized on a render worker using the system's
selected Metal device. When available, the device's recommended working-set size
controls the Core Image render-task budget. The image cache has no corresponding limit.
Each source creates its CIImage once.

Intermediate processing uses 32-bit float in extended linear sRGB. The GPU path renders
to a half-float IOSurface and waits for completion on the worker before publication.
Core Animation receives the surface directly. A read-only CGImage provider pins the same
storage for inspection and cache ownership, avoiding an eager whole-source bitmap
conversion during UI commit.

The provider owns the surface reference and read lock. Published surfaces and native
layer contents hold separate references to storage. Workers release the final storage
reference. Source invalidation or session close cannot release an in-flight job's
pixels. If shared rendering is unavailable, the renderer uses a completed CGImage. The
software renderer uses the same interface.

Intermediate caches can be cleared under pressure without clearing them on normal
navigation.

There are two startup-owned job records per window and one replaceable desired view. At
most two renders run globally, including one speculative render, with one render owner
per source. Foreground admission takes priority. The main queue can present a ready
cache hit while another render is active.

## Linux

libvips and LittleCMS supply decoding and color operations around the shared TIFF path.
The renderer keeps native samples and dyadic reductions. General filtered output uses
linear-light working values. Eligible integer-aligned opaque sRGB views use direct
conversion. See [performance techniques](performance.md).

SDL GPU/Vulkan is the preferred presentation path. Workers prepare and upload viewport
textures, waiting before reusing staging storage. The UI submits a copy when a swapchain
image is available and retries later otherwise. If GPU presentation is unavailable, Yekk
uses SDL's renderer. Use `--software` to select software rendering.

Frame storage distinguishes owned, native-referenced and reusable leased buffers. A
buffer cannot be reused until its readers and compositor ownership end. A monitor or
profile change queues transform replacement on a worker. Output-generation checks reject
frames prepared with the old transform. Missing or invalid profiles fall back to sRGB.

## Validation boundaries

Check source samples separately from display output. Fixtures exercise precision,
orientation, ICC, alpha, nearest and filtered scaling, pixel alignment and exact surface
reuse. A native presentation submission does not identify when a frame becomes visible.
Heartbeat gaps measure event-loop availability. They do not measure hardware input
latency. Drivers and compositors can still introduce latency inside native calls.

See [validation](validation.md) for regression and profiling commands.
