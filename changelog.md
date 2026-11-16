# Changelog

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
