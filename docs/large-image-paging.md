# Large images and region decoding

Yekk loads the full decoded image. Zooming to 100% and panning reuse those pixels.
Workers render only the visible viewport. Available memory, checked sizes and
native API constraints limit loading.

Region decoding would load only the source blocks needed for a view.
Yekk does not implement it yet.

## Format constraints

A small viewport does not guarantee a small decode. The file's compression layout
determines how much data a decoder must read and decompress.
Cropping an already decoded image does not reduce this work.

| Source layout | Decode constraint |
| --- | --- |
| Tiled TIFF | Decode independent tiles that intersect the view. |
| Small TIFF strips | Decode full-width strips, including pixels outside the view. |
| Large compressed strips | A small view can require a large sequential decode. |
| Image pyramid | Choose a resolution level, then its blocks. |
| Other formats | Random access and downsampling depend on the decoder. |

An image pyramid stores several resolutions. Generating one adds initial work or
temporary storage. It must improve viewing latency over full loading without
changing source files.

## Paged-backend requirements

- Keep an overview visible while detail loads.
- Identify blocks by source version, resolution, coordinates and decode settings.
- Use request revisions to control display replacement, not block identity.
- Reuse completed blocks across pans and zooms. Do not schedule duplicate loads.
- Keep storage alive while a view or render job reads it.
- Fit reusable block slots, descriptors and temporary buffers into the image allocation.
- Remove cached blocks under memory pressure.

Compare against full loading on real file layouts. Measure time to first detail,
repeated pans, decoded bytes, rendering and upload. Resident blocks must need no
new decoding. Check pixels, block edges, orientation, profiles, alpha, invalid
offsets and cancellation.

## TIFF probe

The macOS probe compares TIFF block reads with ImageIO using synthetic RGB16 data:

```sh
nix develop path:.
zig build tiff-probe -Doptimize=ReleaseSafe -- generate /tmp/yekk-tiled.tif tiles
zig build tiff-probe -Doptimize=ReleaseSafe -- blocks-cached /tmp/yekk-tiled.tif --verify-synthetic
```

Generation refuses to overwrite files. Other layouts are `strips` and
`single-strip`. Modes include `blocks`, `imageio-preview` and `imageio-full`.
Fixed cache and temporary-buffer limits apply only to this probe.
See [benchmarking](validation.md#benchmarking-and-profiling).
