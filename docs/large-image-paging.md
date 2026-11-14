# Large images and region decoding

Yekk retains full decoded images and renders the visible viewport.
Zooming to 100% and panning reuse those pixels. Available memory, checked sizes
and native API constraints limit loading. Source-region paging is not implemented.

## Format constraints

A small viewport does not guarantee a small decode. Cropping a decoded image or
using tiled presentation does not provide source-region decoding.

| Source layout | Decode constraint |
| --- | --- |
| Tiled TIFF | Decode intersecting independent tiles. |
| Small TIFF strips | Decode full-width strips, including pixels outside the view. |
| Large compressed strips | A small view can require a large sequential decode. |
| Image pyramid | Select a resolution level and its blocks. |
| Other formats | Random access and downsampling depend on the decoder. |

Compression and prediction constrain access within blocks. A generated pyramid
or backing store adds initial work or temporary storage. It must improve viewing
latency over full loading without changing source files.

## Paged-backend requirements

Keep an overview visible while loading detail. Key blocks by source version,
resolution, coordinates and decode parameters. Request revisions control display
replacement, not block identity. Reuse completed blocks and deduplicate pending work.

Pin visible blocks and native readers before reusing slots. Fit page slots,
descriptors and scratch into the image allocation. Pressure-driven removal must
avoid repeated decoding during pan and zoom cycles.

Compare against full loading on real layouts. Measure first detail, repeated
pans, decoded bytes, rendering and upload. Check samples, block boundaries,
orientation, ICC, alpha, malformed offsets and cancellation.

## TIFF probe

The macOS probe compares TIFF block reads with ImageIO using synthetic RGB16 data:

```sh
nix develop path:.
zig build tiff-probe -Doptimize=ReleaseSafe -- generate /tmp/yekk-tiled.tif tiles
zig build tiff-probe -Doptimize=ReleaseSafe -- blocks-cached /tmp/yekk-tiled.tif --verify-synthetic
```

Generation refuses to overwrite files. Other layouts are `strips` and
`single-strip`. Modes include `blocks`, `imageio-preview` and `imageio-full`.
Fixed cache and scratch limits apply only to this probe.
See [benchmarking](validation.md#benchmarking-and-profiling).
