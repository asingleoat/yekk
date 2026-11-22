# Changelog

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
