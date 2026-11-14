# Caching and memory pressure

User-facing latency takes priority over a small resident footprint. Yekk retains valid
decoded history and useful prepared viewports until memory pressure, allocation failure,
source invalidation, explicit reload/removal or session close. Normal navigation has no
decoded-byte, age or image-count eviction quota.

## Reuse and prefetch

After the selected image is presented, workers decode the next and previous images and
prepare their expected viewports. Foreground requests take priority. When the user
selects an image during its preload, Yekk can use that load. It does not start a
duplicate load. Prefetch is bounded to adjacent work, not the entire directory.

Decoded sources and prepared views have different identities. A reusable result must
match the source version and the rendering inputs, including geometry, filtering and
output-profile generation. A selection revision identifies the requested selection. It
controls whether a result can replace the display. A new revision does not invalidate
reusable pixels. A ready cache hit can publish while another view is rendering.

Prepared views distinguish the automatic fitted view from the latest interaction view.
Zooming manually, including below 100%, preserves the fitted surface. Returning to an
exact retained view avoids both decoding and viewport rendering. Full decoded pixels
remain available for 100% zoom and panning. New pan positions can require rendering a
viewport, but do not decode the source again. Yekk does not retain every previous pan
surface.

## Bounded background work

Across windows, at most two native decodes run, with at most one speculative decode.
Fast TIFF loads share a worker budget based on available CPU resources. Speculative work
prepares images before the user selects them. It requests at most half of the worker
budget. `--decode-workers N` overrides automatic selection. macOS additionally limits
viewport rendering to two jobs globally, including at most one speculative job and one
render owner per source.

Requests are immutable snapshots with revisions. A new view request can replace pending
work. Rapid navigation follows the latest selection. Stale completion may still provide
reusable cached data, but cannot replace the current display. Jobs and published frames
retain their source until their readers finish. Heavy releases and intermediate-cache
clearing happen on workers.

## Pressure and allocation failure

macOS memory-pressure notifications signal worker reclamation rather than performing it
in the callback. Linux observes memory PSI, with stall-counter sampling when trigger
registration is unavailable. Pressure reclaims inactive history and derived work. Yekk
suspends adjacent prefetch for the affected selection. This prevents repeated cache
removal and loading.

Allocation admission uses current available resources rather than a fraction of
installed RAM. Linux includes MemAvailable, cgroup v2 limits/current usage along the
ancestor chain and concurrent decode reservations. Checked arithmetic and native API
constraints still apply. Admission checks cannot guarantee allocation success. Native
libraries and other processes can change available memory after a check.

After allocation failure, workers release inactive history and native intermediate
storage. They keep the active source and last valid display. They permit one retry.
Exhausted recovery reports an error instead of continuously retrying. Watching likewise
avoids repeatedly decoding the same corrupt source version.

Dead, page-aligned TIFF scratch can be advised with `MADV_FREE` on macOS or
`MADV_DONTNEED` on Linux after helpers finish. This touches no live pixels or metadata,
and does not guarantee an immediate RSS reduction. Live decoded images are not
kernel-discardable: marking arbitrary library-owned pixel memory purgeable would require
a separate ownership and reconstruction protocol.

## Verification

Track native decodes, allocations and prepared-view hits separately. Warm navigation
must establish that both target images are resident before asserting zero redecodes.
Exercise fit → actual → pan → next → previous, manual scales below 100%, stale
completions, source replacement and closing with work in flight. Use test controls to
inject allocation failure and memory pressure. Do not exhaust host RAM to test recovery.
See [validation](validation.md).
