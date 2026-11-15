# Caching and memory pressure

Yekk caches two kinds of data:

- **Decoded images:** source pixels available for new zoom and pan positions.
- **Prepared views:** rendered pixels for a particular viewport, zoom, pan and filter.

The viewport is the image-display area inside a window.
For example, a 6000×4000 image can supply a 960×640 fitted view and a 960×640
actual-size crop. Both views use the same decoded image.

Yekk keeps decoded images until memory pressure, allocation failure, reload,
a detected file change, list removal or window close. The cache has no fixed
byte, age or image-count eviction limit.

## Reuse and prefetch

**Prefetch** loads an image before the user selects it. After displaying the
selected image, workers load its next and previous neighbors and prepare views.
Requests from the user take priority. Selecting a neighbor during prefetch uses
the load already in progress.

A **cache hit** means the required data is already in memory.
A decoded-image hit avoids another decode. An exact prepared-view hit also
avoids rendering that viewport again. Final window-system display work remains.

The cache keeps the fitted view separately from the latest manually adjusted view.
Fit → zoom → next → previous can therefore return to decoded detail without a
new load. Returning to fit can reuse the original fitted pixels.
A new pan position can need rendering, but it still uses the decoded image.

## Valid data and current requests

These identifiers serve different purposes:

| Identifier | What it distinguishes |
| --- | --- |
| File stamp | File identity, size and modification time used to detect file changes. |
| Image version | Replacement pixel data from the image data previously loaded. |
| Request revision | The latest image or view requested by the user. |

Prepared views must match their source image, dimensions, transform and filter.
Linux also checks background settings and the display-profile version.
macOS leaves the final display-profile conversion to Core Animation.

A new request does not invalidate otherwise reusable pixels.
For example, A can finish loading after the user selects B. Its result can remain
cached for a later return to A, but it cannot replace B's display.
A ready cache hit can display while another view renders.

## Background limits

At most two images decode at once across all windows. At most one is a preload.
TIFF decodes share a CPU worker budget. A preload requests at most half that
budget. For example, with eight available workers, a preload requests at most four.
`--decode-workers N` overrides automatic worker selection.

macOS permits two viewport renders globally, with at most one preload render.
Only one render job at a time owns a given source image.
New requests replace pending work. Results from older requests cannot replace
the current display.

## Pressure and failure

**Memory pressure** means the OS reports a shortage of available memory.
macOS notifications request worker cleanup. Linux uses pressure-stall information
(PSI), which measures time processes spend waiting for memory.
Workers release images no longer displayed or used by a job, along with cached
reductions and prepared views. Prefetch stops for the affected selection.

Before decoding, Yekk checks available memory. Linux considers:

- `MemAvailable`, the kernel's estimate of available memory.
- cgroup limits, including limits imposed by containers or parent resource groups.
- Memory already reserved for other active decodes.

A cgroup is a Linux resource-control group. Its memory limit can be lower than
installed RAM. Other processes can consume memory after Yekk's check, so
allocation can still fail.

After failure, workers release inactive images and intermediate storage, then
retry once. They keep the active source and last valid display.
If the retry fails, Yekk reports the error. Source watching also avoids repeated
attempts on an unchanged corrupt file.

Live decoded pixels are not registered as OS-discardable memory.
Yekk releases them by removing unused cache entries.
See [validation](validation.md) for reuse and recovery checks.
