#!/usr/bin/env python3
"""Generate small PNG cases without an image library."""
from pathlib import Path
import argparse
import ctypes
import struct
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lcms-library', type=Path, help='regenerate the fixed-date ICC profiles with this LittleCMS library')
args = parser.parse_args()

folder = Path(__file__).resolve().parent / 'fixtures'
if args.lcms_library:
    cms = ctypes.CDLL(str(args.lcms_library.resolve(strict=True)))
    cms.cmsCreate_sRGBProfile.restype = ctypes.c_void_p
    cms.cmsD50_xyY.restype = ctypes.c_void_p
    cms.cmsBuildGamma.argtypes = [ctypes.c_void_p, ctypes.c_double]
    cms.cmsBuildGamma.restype = ctypes.c_void_p
    cms.cmsCreateGrayProfile.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cms.cmsCreateGrayProfile.restype = ctypes.c_void_p
    cms.cmsSaveProfileToMem.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    cms.cmsCloseProfile.argtypes = [ctypes.c_void_p]
    cms.cmsFreeToneCurve.argtypes = [ctypes.c_void_p]
    curve = cms.cmsBuildGamma(None, 1.0)
    assert curve
    try:
        for name, profile in [('srgb', cms.cmsCreate_sRGBProfile()), ('gray', cms.cmsCreateGrayProfile(cms.cmsD50_xyY(), curve))]:
            assert profile
            try:
                size = ctypes.c_uint32()
                assert cms.cmsSaveProfileToMem(profile, None, ctypes.byref(size))
                buffer = ctypes.create_string_buffer(size.value)
                assert cms.cmsSaveProfileToMem(profile, buffer, ctypes.byref(size))
                data = bytearray(buffer.raw)
                data[24:36] = struct.pack('>6H', 2000, 1, 1, 0, 0, 0)
                data[84:100] = bytes(16)
                (folder / f'decoder-{name}.icc').write_bytes(data)
            finally:
                cms.cmsCloseProfile(profile)
    finally:
        cms.cmsFreeToneCurve(curve)
signature = b'\x89PNG\r\n\x1a\n'
passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
          (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def paeth(a, b, c):
    p = a + b - c
    return min([(abs(p-a), 0, a), (abs(p-b), 1, b), (abs(p-c), 2, c)])[2]


def value(x, y, channel, depth):
    return (x * 257 + y * 911 + channel * 1237 + 37) & ((1 << depth) - 1)


def png(kind, depth, interlace, transparent=False, width=17, height=19, extra=b''):
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[kind]
    bpp = max(1, (channels * depth + 7) // 8)
    data = bytearray()
    for left, top, dx, dy in (passes if interlace else [(0, 0, 1, 1)]):
        xs, ys = list(range(left, width, dx)), list(range(top, height, dy))
        if not xs or not ys:
            continue
        previous = bytes((len(xs) * channels * depth + 7) // 8)
        for row_number, y in enumerate(ys):
            samples = [value(x, y, ch, depth) for x in xs for ch in range(channels)]
            if depth == 16:
                row = struct.pack('>' + 'H' * len(samples), *samples)
            elif depth == 8:
                row = bytes(samples)
            else:
                packed = bytearray((len(samples) * depth + 7) // 8)
                for i, sample in enumerate(samples):
                    packed[i * depth // 8] |= sample << (8 - depth - (i * depth % 8))
                row = bytes(packed)
            method = row_number % 5
            filtered = bytearray()
            for i, v in enumerate(row):
                a, b, c = (row[i-bpp] if i >= bpp else 0), previous[i], (previous[i-bpp] if i >= bpp else 0)
                prediction = [0, a, b, (a+b)//2, paeth(a, b, c)][method]
                filtered.append((v-prediction) & 255)
            data.extend(bytes([method]) + filtered)
            previous = row
    header = struct.pack('>IIBBBBB', width, height, depth, kind, 0, 0, interlace)
    metadata = bytearray(extra)
    if kind == 3:
        metadata.extend(chunk(b'PLTE', bytes(v for i in range(1 << depth) for v in ((i*37+5)&255, (i*67+11)&255, (i*97+17)&255))))
        metadata.extend(chunk(b'tRNS', bytes((i*53)&255 for i in range(1 << depth))))
    elif transparent:
        metadata.extend(chunk(b'tRNS', b''.join(struct.pack('>H', value(0, 0, ch, depth)) for ch in range(channels))))
    compressed = zlib.compress(data)
    middle = len(compressed) // 2
    return signature + chunk(b'IHDR', header) + metadata + chunk(b'IDAT', b'') + chunk(b'IDAT', compressed[:middle]) + chunk(b'IDAT', compressed[middle:]) + chunk(b'IEND', b'')


for kind, depths in [(0, [1, 2, 4, 8, 16]), (2, [8, 16]), (3, [1, 2, 4, 8]), (4, [8, 16]), (6, [8, 16])]:
    for depth in depths:
        for interlace in [0, 1]:
            for transparent in ([False, True] if kind in [0, 2] else [False]):
                name = f'png-{kind}-{depth}-{interlace}' + ('-trns' if transparent else '') + '.png'
                (folder / name).write_bytes(png(kind, depth, interlace, transparent))
for orientation in range(1, 9):
    for endian, prefix in [('<', b'II'), ('>', b'MM')]:
        exif = prefix + struct.pack(endian+'HIH', 42, 8, 1) + struct.pack(endian+'HHIHHI', 274, 3, 1, orientation, 0, 0)
        suffix = 'le' if endian == '<' else 'be'
        (folder / f'png-orientation{orientation}-{suffix}.png').write_bytes(png(2, 8, 0, width=3, height=2, extra=chunk(b'eXIf', exif)))
(folder / 'png-adam7-tiny.png').write_bytes(png(6, 8, 1, width=1, height=1))
# Exercise the deliberate native colorimetry route.
(folder / 'png-gamma.png').write_bytes(png(2, 8, 0, extra=chunk(b'gAMA', struct.pack('>I', 100000))))
for name, kind in [('srgb', 2), ('gray', 0)]:
    profile = (folder / f'decoder-{name}.icc').read_bytes()
    (folder / f'png-profile-{name}.png').write_bytes(png(kind, 16, 1, extra=chunk(b'iCCP', b'profile\0\0' + zlib.compress(profile))))
print('Generated PNG sample, filter, interlace, transparency and orientation cases')
