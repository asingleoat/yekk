# Image input checks

Treat image files, metadata and filenames as untrusted input.
These checks run in production builds, including ReleaseFast.

- Open regular files with nonblocking file opens. Reject directories, devices
  and named pipes before calling a decoder.
- Check dimensions and buffer arithmetic before Yekk allocates pixel storage.
  Check decoded dimensions, sample format and row stride before publishing.
- Keep filenames literal. Linux supplies file descriptors to libvips, so text
  such as `[page=2]` in a filename cannot set decoder options.
- Check TIFF file identity and layout on each worker handle. Join all workers
  and discard the result if a worker fails or the source changes.
- Validate BMP header, palette, bit-mask, pixel and profile ranges. Reject BMP
  profiles that name an external file. Linux decodes BMP pixels with SDL.
- Decode PBM, PGM and PPM with shared Zig code. Validate numeric fields and sample
  values, preserve 16-bit samples, and reject incomplete pixel data.
- Decode JPEG XL directly with libjxl on Linux. Check dimensions, integer sample
  precision, profile size and output buffer size. Join native jobs before freeing
  storage. Use the orientation stored with JPEG XL image data. Ignore a second
  orientation tag in Exif metadata.
- Disable libvips operations marked as untrusted. Portable Linux packages omit
  ImageMagick and the libvips JPEG XL wrapper. Other image formats use ImageIO
  or enabled libvips codecs.

The PNM decoder stores binary input at the end of each worker's output region.
It expands pixels forward after each source sample has been read. This uses one
owned allocation for the image record, decoded pixels and worker records.

Native codecs and color-profile parsers run in the viewer process. A bug in one
of these libraries can affect that process. File identity checks detect changes;
they do not create an immutable snapshot. Decoder work can consume substantial
RAM and CPU. Separate restricted decoder processes would provide a stronger
boundary.

Keep the OS and bundled decoder libraries updated. Configuration files and
shell hooks contain user instructions and must come from a trusted source.

## Validation

Generate the fixtures, then run the supervised input corpus:

```sh
python3 tests/generate-release-fixtures.py
python3 tests/malformed-images.py --binary zig-out/bin/yekk \
  --output dist/malformed-images.json
```

The corpus checks malformed dimensions, profiles, tags and headers, truncated
payloads, literal filenames and named pipes. It requires clean process exits and
zero live Yekk allocations. Linux tests use a per-process address-space limit;
the application has no fixed RAM quota. Run this corpus on production and debug
allocator builds. It supplements the [decoder and ownership tests](validation.md).
