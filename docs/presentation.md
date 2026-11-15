# Viewport presentation

The **viewport** is the image-display area inside a window.
Workers render its output pixels from a cached decoded image.
A **display surface** is the pixel storage passed to the window system.
It needs only viewport dimensions. A full source image need not fit in one GPU texture.
Decoding uses the shared TIFF decoder or a platform library.
Yekk does not implement GPU decompression.

## Coordinates and color

A backing pixel is one pixel in the window's drawing buffer.
Window coordinates can use different units on high-DPI displays.
At actual size, one source pixel maps to one backing pixel.
Transforms calculate scale, rotation, mirroring and pan in these pixel coordinates.

Filtering uses linear-light values, which represent light intensity.
For sRGB output, a 50% black/white mix is about 188 on an 8-bit scale.
Alpha represents opacity. Multiplying color values by alpha before filtering
prevents hidden colors in fully transparent pixels from affecting the result.
This representation is called premultiplied alpha.

Output is standard dynamic range (SDR). Supported RGB and grayscale sources keep
their pixel precision and ICC color profiles. An ICC profile describes how to
interpret the color values. Rendering converts them for the output color space.
See [view reuse](cache-and-pressure.md#reuse-and-prefetch).

## macOS

A worker creates one shared Core Image context, the object used for rendering.
It uses the system-selected Metal device. When available, the device's recommended
working-set size guides Core Image's memory budget. This does not impose a
decoded-image cache limit. Each loaded image creates its Core Image source once.

Processing uses 32-bit floating-point values in extended linear sRGB.
Output uses 16-bit floating-point values in an IOSurface, a shared pixel buffer.
The worker waits for rendering to finish before making the result available.
Core Animation displays that surface and handles final conversion for the monitor.

A Core Graphics image provider exposes the same pixels for inspection and caching.
It owns a reference and a read lock on the surface. Core Animation layers hold
separate references while displaying it. Yekk releases its final provider reference
on a worker. Source pixels also stay alive until rendering jobs finish.

If shared-surface rendering fails, the renderer returns a completed CGImage,
Core Graphics' image object. Software rendering uses this path too.
Each window has two preallocated job records and one replaceable pending view.
The UI can display ready cache hits during another render.
Workers clear intermediate caches under memory pressure.

## Linux

Workers prepare and upload viewport textures through SDL GPU/Vulkan.
A texture is pixel storage accessible to the GPU. Workers wait for upload
completion before reusing temporary upload storage.

The UI submits a copy to an available swapchain image, one of the GPU buffers
the window system uses for display. If none is available, it retries later.
SDL's renderer is the fallback. Use `--software` to select software presentation.
Image decoding and viewport preparation remain CPU work on either path.

Linux converts prepared pixels for the display's ICC profile.
A profile change increments its output version and queues a new color transform
on a worker. Frames made for an older version cannot display.
Invalid or missing profiles use sRGB. A buffer cannot be reused while a reader
or the window system still uses it. See [rendering techniques](performance.md#viewport-rendering).

Native calls can still incur driver or compositor delays.
See [validation](validation.md) for color, lifetime and timing checks.
