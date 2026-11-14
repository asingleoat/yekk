#!/usr/bin/env python3
"""Deterministic release-regression fixtures; never reads the scan corpus."""
from pathlib import Path
import argparse
import struct
import subprocess
import zlib

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--cjpeg', type=Path, help='optional libjpeg cjpeg to regenerate progressive JPEG')
a = p.parse_args()
fixtures = Path(__file__).resolve().parent / 'fixtures'
jpeg = (fixtures / 'orientation6.jpg').read_bytes()
for cut in (4, 64):
    (fixtures / f'jpeg-incomplete-{cut}.jpg').write_bytes(jpeg[:-cut])
(fixtures / 'jpeg-trailer.jpg').write_bytes(jpeg + b'trailing application data\xff\xd9')
(fixtures / 'jpeg-boundary.jpg').write_bytes(jpeg[:-2] + b'\xff' * (32768 - len(jpeg) + 2) + b'\xff\xd9')

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

width, height = 2048, 128
row = b'\0' + b''.join(struct.pack('>H', x * 65535 // (width - 1)) for x in range(width))
header = struct.pack('>IIBBBBB', width, height, 16, 0, 0, 0, 0)
(fixtures / 'detail-wide.png').write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(row * height)) + chunk(b'IEND', b''))
if a.cjpeg:
    pixels = bytes(channel for y in range(48) for x in range(64) for channel in (x * 4, y * 5, (x + y) * 2))
    result = subprocess.run([str(a.cjpeg), '-progressive', '-quality', '90'], input=b'P6\n64 48\n255\n' + pixels, check=True, capture_output=True)
    (fixtures / 'jpeg-progressive.jpg').write_bytes(result.stdout)
