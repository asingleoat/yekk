# Changelog

## 0.2.6 — 2026-11-24

- Add feh-compatible list output, image decode checks, sort options, and
  filters for image width and height. Load feh themes and mouse bindings.
- Press **Shift+L** to save the current image list. Open the saved list with
  `-f FILE`.
- Set window titles and fonts. View and edit captions in separate text files.
  Show EXIF data or command output over an image.
- Open images in separate windows. Create and export contact sheets, and show
  thumbnails as they load. Click a thumbnail to open the image or run the
  configured action.
- Save a rotated or mirrored copy at full resolution. Use `--edit` to rotate
  or mirror JPEGs in place when the operation can keep every pixel.
- Navigate with terminal keys or signals. Set the desktop wallpaper on macOS
  or through the Wallpaper portal on Linux.

HTTP and HTTPS image URLs remain unsupported.

## 0.2.5 — 2026-11-21

- Load camera RAW files faster on Apple Silicon. Write directly to the final
  16-bit pixel buffer and process rotated images in blocks.
- Use less demosaicing scratch memory on Apple Silicon. Score Bayer RAW
  pixels with SIMD on Apple Silicon and x86_64 Linux.

## 0.2.4 — 2026-11-21

- Open JPEG XL and camera RAW files on macOS and Linux. RAW support includes
  Sony ARW, Canon CR2 and CR3, Nikon NEF, and DNG.
- Develop RAW images in parallel on Apple Silicon using LibRaw. The decoder
  preserves the full-resolution 16-bit output.
- Release temporary RAW pixels earlier to reduce peak memory use on macOS
  and Linux.

## 0.2.3 — 2026-11-15

- Holding a navigation key displays each image for at least one frame. A new
  key press can skip an image that is still loading. Releasing the key stops
  pending repeats.
- `--aggressive` preloads beyond the next and previous images while RAM is
  available. User requests take priority. Memory pressure stops further prefetch
  for the current selection.
- JPEG loading is faster for supported files. Zig performs part of the decoding,
  with the same pixels as libjpeg-turbo and its error recovery. Other variants
  retain their existing decoder. macOS keeps ImageIO where it is faster.
