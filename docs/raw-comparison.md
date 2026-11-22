# Camera RAW comparison

This test measures the time from starting a viewer to seeing the first fitted
photo. A fitted view shows the whole photo within the available image area.
Each program used its own window layout.

- Yekk 0.2.4 developed the sensor data and cached the full-resolution pixels.
- Geeqie 3.3 showed the JPEG stored in the RAW file by the camera. The Sony
  preview measured 1616×1080 pixels. [Geeqie manual](https://www.geeqie.org/help/GuideMainWindowMenus.html)
- darktable 5.6.2 opened the photo in darkroom and developed the fitted view
  with its default processing settings. OpenCL was disabled. [darktable manual](https://docs.darktable.org/usermanual/5.6/en/darkroom/overview/)

## Results

The table shows the fastest trial for each file and viewer.

| Camera | Yekk (s) | Geeqie (s) | darktable (s) |
| --- | ---: | ---: | ---: |
| Sony A7 III ARW | 0.79 | 1.60 | 3.40 |
| Canon 5D Mark III CR2 | 0.93 | 1.77 | 3.42 |
| Nikon D750 NEF | 0.95 | 1.78 | 3.43 |

The chart in the [README](../README.md#camera-raw) shows all trials as ticks.
The [CSV](assets/raw-comparison.csv) contains all 108 trials.
Yekk reached the reference first in all 36 sets of three trials.
The three programs apply different color and tone settings.

## Conditions

- AMD Ryzen 9 7950X, Linux x86_64, private 1280×800 Xvfb display, CPU rendering.
- Yekk used a native ReleaseFast build of tag `v0.2.4` with a baseline CPU target.
  Geeqie and darktable came from the same locked Nixpkgs input.
- Read each input into the OS file cache before starting the process. Each
  process had a fresh profile and empty image cache. darktable used an
  in-memory catalog and skipped the welcome screen. The test used a private
  desktop message bus.
- Run each photo 12 times per viewer. Use every order of the three viewers
  twice per photo. Shuffle the order and keep all trials.
- Capture a 240×160-pixel area inside the fitted photo. Stop when it matches
  that viewer's reference. Require an exact match for Yekk and Geeqie.
  For darktable, reduce both captures to 24×16 pixels before comparison.
  Across each 8-bit color channel, allow a mean absolute difference of 2.5
  and a root mean square difference of 3.5. This allows small differences from
  resizing the same fitted photo.

The three public test files came from raw.pixls.us. Sony supplied a compressed
ARW. Canon supplied a CR2 and Nikon supplied a lossless compressed NEF.

- [Sony A7 III ARW](https://raw.pixls.us/getfile.php/2414/nice/Sony%20-%20ILCE-7M3%20-%2014bit%2014bit%20compressed%20%283:2%29.ARW)
- [Canon 5D Mark III CR2](https://raw.pixls.us/getfile.php/771/nice/Canon%20-%20EOS%205D%20Mark%20III.CR2)
- [Nikon D750 NEF](https://raw.pixls.us/getfile.php/898/nice/Nikon%20-%20D750%20-%2014bit%2014bit%20compressed%20%28Lossless%29%20%283:2%29.NEF)
