# Caching and memory pressure

Yekk keeps decoded images until memory pressure, allocation failure, source
changes, reload, removal or session close. The cache has no fixed byte, age or
image-count limit.

## Reuse and prefetch

After displaying the selected image, workers load the next and previous images
and prepare their views. Foreground requests take priority. Selecting an image
during prefetch uses the load already in progress.

A cached view must match its source version, geometry, filter and display color
profile. Request revisions control which result can replace the display.
A new selection does not invalidate reusable pixels. A ready cache hit can display
while another view renders.

The cache keeps the fitted view separately from the latest manually adjusted view.
Manual zoom preserves the fitted view, including at scales below 100%.
An exact view hit avoids decoding and rendering. A new pan position can need
viewport rendering, but it reuses the full decoded image.

## Background limits

At most two native decodes run across windows. At most one is speculative:
it prepares an image before selection. Fast TIFF loads share a CPU worker budget.
Speculative loads request at most half. `--decode-workers N` overrides automatic selection.

macOS permits two viewport renders globally, with at most one speculative render.
Each source has one render owner. New requests replace pending work.
Stale results cannot replace the current display.

## Pressure and failure

Memory pressure means that the OS reports a shortage of available memory.
macOS notifications request worker cleanup. Linux uses pressure-stall information
(PSI), through notifications or sampled stall counters. Workers release inactive
images and derived views. Prefetch stops for the affected selection.

Before allocating, Yekk checks current available memory. Linux includes system
MemAvailable, container or cgroup limits, and concurrent decode reservations.
Other processes can consume memory after the check, so allocation can still fail.

After failure, workers release inactive images and intermediate storage, then
retry once. They keep the active source and last valid display.
An exhausted retry reports an error. Source watching also avoids repeated
attempts on an unchanged corrupt file.

Live pixels are not marked discardable. The OS cannot discard them on request
without Yekk first removing the cache entry. See [validation](validation.md) for
reuse and recovery checks.
