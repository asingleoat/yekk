# Large images and region decoding

Yekk currently retains full decoded images for fast 100% inspection and repeated
panning. It renders only the visible viewport. Yekk sets no fixed image-byte limit or
limit based on a fraction of RAM. Checked sizes, native API constraints and available
memory still apply. Allocation can fail. Arbitrary source-region paging is not
implemented.

A smaller displayed region does not necessarily mean less decoding. ImageIO's
whole-image and thumbnail interfaces do not establish which compressed source regions
are read. Likewise, cropping a decoded image or using a tiled presentation layer does
not provide a region decoder.

## Storage layout determines useful granularity

| Source layout | Region-decoding consideration |
| --- | --- |
| Tiled TIFF | Independently compressed tiles can serve intersecting regions. |
| Small TIFF strips | A region needs full-width strips, including pixels outside the viewport. |
| One/few large compressed strips | Even a small view may require a large sequential decode. |
| Existing image pyramid | Select a suitable level and its intersecting blocks. |
| Other formats | Downsampling and random-access capabilities depend on the decoder and format. |

Compression state and horizontal prediction constrain access within a block. A generated
pyramid or reusable backing store could amortize sequential work, but adds startup work
or temporary storage. It must improve useful first-view and repeated-pan latency over
retaining a full decode. Source files must remain unchanged.

## Requirements for a paged backend

Keep an overview available while loading detail, and distinguish pending detail from
actual source resolution. Cache blocks by source version, resolution, coordinates and
decode parameters. Use viewport request revisions to control publication. Do not include
those revisions in reusable block identity. Deduplicate in-flight work and retain useful
completed blocks when the viewport changes.

Pin visible data and native readers before reusing slots. Pressure-driven reclamation
must avoid repeatedly decoding the same regions during a pan/retrace. The existing
one-image allocation contract needs an explicit layout for page slots, descriptors and
codec scratch. Virtual address reservation alone says nothing about resident memory or
allocation churn.

Compare full loading and region loading on real layouts. Count decoded blocks and bytes
during forward pans, backward pans and zoom cycles. Resident detail must require no new
decoding. Validate boundaries, all orientations, precision, ICC, alpha, malformed
offsets and cancellation. Include render/upload time and first useful detail, rather
than reporting decoder time alone.

## TIFF probe

The optional macOS `tiff-probe` target compares block reads and ImageIO paths using
synthetic RGB16 TIFF layouts. It is a research tool, not the viewer's cache policy. Its
fixed scratch and cache limits apply only to the probe.

```sh
nix develop path:.
zig build tiff-probe -Doptimize=ReleaseSafe -- generate /tmp/yekk-tiled.tif tiles
zig build tiff-probe -Doptimize=ReleaseSafe -- blocks-cached /tmp/yekk-tiled.tif --verify-synthetic
```

Generation refuses to overwrite a path. Repeat with `strips` or `single-strip`, and
compare `blocks`, `imageio-preview` and `imageio-full` modes. Synthetic sample
verification checks block reuse. It does not validate integrated color, presentation or
production tail latency. See [benchmarking](validation.md#benchmarking-and-profiling).
