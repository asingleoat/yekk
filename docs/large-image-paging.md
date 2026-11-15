# Large images and region decoding

Yekk currently loads the full decoded image. Zooming to 100% and panning reuse
those pixels. Workers render only the viewport, the image-display area inside
the window. Available memory, checked sizes and native API constraints limit loading.

**Region decoding** reads and decodes only the source regions needed for a view.
**Image paging** manages which decoded regions remain in memory.
Neither is implemented in Yekk yet. The requirements below describe a future backend.

## File layout determines decode work

A source block is a separately compressed unit, such as a TIFF strip or tile.
A small viewport can intersect only part of a block, but the decoder can still
need to decompress the whole block. Cropping an already decoded image does not
reduce that work.

| Source layout | Decode constraint |
| --- | --- |
| Tiled TIFF | Decode independent rectangular tiles that intersect the view. |
| Small TIFF strips | Decode full-width row strips, including pixels outside the view. |
| Large compressed strips | A small view can require a large sequential decode. |
| Image pyramid | Choose a resolution level, then its intersecting blocks. |
| Other formats | Random access and downsampling depend on the decoder. |

An **image pyramid** stores the same picture at several resolutions.
A smaller level can provide the fit-to-window overview. Full-resolution blocks
provide detail at 100%. Generating a pyramid adds initial work or temporary storage.
It must improve viewing latency over full loading without changing source files.

## Paged-backend requirements

- Keep an overview visible while detail loads.
- Identify blocks by image version, resolution, coordinates and decode settings.
- Use request revisions to control display replacement, not block identity.
- Reuse completed blocks across pans and zooms. Do not schedule duplicate loads.
- Keep storage alive while a view or render job reads it.
- Fit resident blocks, their records and temporary buffers into the image allocation.
- Remove unused blocks under memory pressure.

An image version identifies the image data being decoded. A request revision
identifies the user's latest view. Panning creates a new request, but cached
blocks from the same source can remain useful. See [cache identifiers](cache-and-pressure.md#valid-data-and-current-requests).

Compare against full loading on real file layouts. Measure time to first detail,
repeated pans, decoded bytes, rendering and upload. Returning to a block still in
memory must need no new decoding. Check pixels, block edges, orientation, color
profiles, alpha, invalid offsets and cancellation.

## TIFF probe

The macOS probe compares TIFF block reads with ImageIO using synthetic RGB16 data.
RGB16 stores 16 bits for each red, green and blue sample.

```sh
nix develop path:.
zig build tiff-probe -Doptimize=ReleaseSafe -- generate /tmp/yekk-tiled.tif tiles
zig build tiff-probe -Doptimize=ReleaseSafe -- blocks-cached /tmp/yekk-tiled.tif --verify-synthetic
```

Generation refuses to overwrite files. Other layouts are `strips` and
`single-strip`. Modes include `blocks`, `imageio-preview` and `imageio-full`.
`--verify-synthetic` checks decoded samples against the generated reference pattern.
Fixed cache and temporary-buffer limits apply only to this probe.
See [benchmarking](validation.md#benchmarking-and-profiling).
