# Caching and memory pressure

Yekk keeps decoded images until memory pressure, allocation failure, source
invalidation, reload, removal or session close. The cache has no fixed byte,
age or image-count limit.

## Reuse and prefetch

After displaying the selected image, workers decode its neighbors and prepare
views. Foreground requests take priority. Selecting an image during prefetch
uses the existing load.

Cache keys include source version, geometry, filtering and output-profile
generation. Request revisions control display replacement without invalidating
reusable pixels. A ready cache hit can display while another view renders.

The fitted view and latest interaction view occupy separate cache entries.
Manual zoom preserves the fitted view, including at scales below 100%.
An exact view hit avoids decoding and rendering. New pan positions can require
viewport rendering, but full decoded pixels need no further source decoding.

## Background limits

At most two native decodes run across windows, including one speculative decode.
Speculative work prepares images before selection. Fast TIFF loads share a CPU
worker budget. Speculative loads request at most half. `--decode-workers N`
overrides automatic selection.

macOS permits two viewport renders globally, including one speculative render.
Each source has one render owner. New requests replace pending work.
Stale results cannot replace the current display.

## Pressure and failure

macOS memory-pressure notifications request worker cleanup. Linux uses memory
PSI triggers or stall-counter sampling. Pressure releases inactive history and
derived views. It suspends adjacent prefetch for the affected selection.

Allocation checks use current available memory. Linux includes MemAvailable,
cgroup v2 ancestor limits and concurrent decode reservations. These checks cannot
guarantee allocation success.

After allocation failure, workers release inactive history and intermediate
storage, then retry once. They keep the active source and last valid display.
An exhausted retry reports an error. Source watching also avoids repeated
attempts on an unchanged corrupt file.

Live pixel storage is not kernel-discardable. Reclaiming it requires cache removal.
See [validation](validation.md) for reuse and recovery checks.
