#!/usr/bin/env python3
"""Deterministic release-regression fixtures; never reads the scan corpus."""
from pathlib import Path
import argparse
import struct
import subprocess
import zlib

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--cjpeg', type=Path, help='optional libjpeg cjpeg to regenerate progressive JPEG')
p.add_argument('--vips', type=Path, help='optional pinned vips to regenerate JPEG XL fixtures')
p.add_argument('--cjxl', type=Path, help='optional pinned JPEG XL encoder for the orientation fixture')
p.add_argument('--djxl', type=Path, help='optional pinned JPEG XL decoder for reference pixels')
a = p.parse_args()
if bool(a.cjxl) != bool(a.djxl):
    p.error('--cjxl and --djxl must be supplied together')
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

# BMP variants exercise independent SDL and ImageIO decoders with identical RGB.
def bmp(width, height, bits, pixels, palette=b'', masks=b'', compression=0, dib=40, colour=0, profile=b''):
    header = bytearray(dib)
    struct.pack_into('<IiiHHIIiiII', header, 0, dib, width, height, 1, bits, compression, len(pixels), 0, 0, len(palette) // 4, 0)
    if dib >= 108:
        struct.pack_into('<I', header, 56, colour)
    offset = 14 + dib + len(masks) + len(palette)
    if profile:
        struct.pack_into('<II', header, 112, offset + len(pixels) - 14, len(profile))
    size = offset + len(pixels) + len(profile)
    return struct.pack('<2sIHHI', b'BM', size, 0, 0, offset) + header + masks + palette + pixels + profile

rgb = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255), (0, 0, 0), (255, 255, 0)]
def packed24(top_down=False):
    rows = [rgb[:3], rgb[3:]]
    return b''.join(b''.join(bytes((b, g, r)) for r, g, b in row) + b'\0' * 3 for row in (rows if top_down else rows[::-1]))
regular = bmp(3, 2, 24, packed24())
(fixtures / 'bmp-rgb24.bmp').write_bytes(regular)
(fixtures / 'bmp-topdown.bmp').write_bytes(bmp(3, -2, 24, packed24(True)))
values = [0xffff, 0, 0xffe0, 0xf800, 0x07e0, 0x001f]
(fixtures / 'bmp-rgb565.bmp').write_bytes(bmp(3, 2, 16, struct.pack('<3H', *values[:3]) + b'\0\0' + struct.pack('<3H', *values[3:]) + b'\0\0', masks=struct.pack('<3I', 0xf800, 0x7e0, 0x1f), compression=3))
palette = b''.join(bytes((b, g, r, 0)) for r, g, b in rgb)
(fixtures / 'bmp-pal8.bmp').write_bytes(bmp(3, 2, 8, bytes([3, 4, 5, 0, 0, 1, 2, 0]), palette))
(fixtures / 'bmp-pal4.bmp').write_bytes(bmp(3, 2, 4, bytes([0x34, 0x50, 0, 0, 0x01, 0x20, 0, 0]), palette))
black_red = bytes([0, 0, 0, 0, 0, 0, 255, 0])
(fixtures / 'bmp-pal1.bmp').write_bytes(bmp(3, 2, 1, bytes([0, 0, 0, 0, 0xe0, 0, 0, 0]), black_red))
(fixtures / 'bmp-rle8.bmp').write_bytes(bmp(3, 2, 8, bytes([3, 0, 0, 0, 3, 1, 0, 0, 0, 1]), black_red, compression=1))
(fixtures / 'bmp-rle4.bmp').write_bytes(bmp(3, 2, 4, bytes([3, 0, 0, 0, 3, 0x11, 0, 0, 0, 1]), black_red, compression=2))
(fixtures / 'bmp-truncated.bmp').write_bytes(regular[:-1])
(fixtures / 'bmp-linked-profile.bmp').write_bytes(bmp(3, 2, 24, packed24(), dib=124, colour=0x4c494e4b, profile=b'/tmp/do-not-open.icc\0'))
(fixtures / 'bmp-invalid-profile.bmp').write_bytes(bmp(3, 2, 24, packed24(), dib=124, colour=0x4d424544, profile=b'invalid ICC profile'))

# All six Netpbm encodings, with byte-order and noncanonical sample ranges.
bitmap = '101\n010\n'
(fixtures / 'pnm-p1.pbm').write_bytes(b'P1\n3 2\n' + bitmap.encode())
(fixtures / 'pnm-p4.pbm').write_bytes(b'P4\n3 2\n' + bytes([0xa0, 0x40]))
for magic, bits, values, maximum in [
    ('P2', 8, [0, 64, 127, 128, 200, 255], 255),
    ('P2', 16, [0, 1, 0x1234, 0x8001, 0xabcd, 65535], 65535),
    ('P5', 8, [0, 64, 127, 128, 200, 255], 255),
    ('P5', 16, [0, 1, 0x1234, 0x8001, 0xabcd, 65535], 65535),
    ('P5', 10, [0, 1, 511, 512, 1022, 1023], 1023),
    ('P3', 8, [v for pixel in rgb for v in pixel], 255),
    ('P6', 8, [v for pixel in rgb for v in pixel], 255),
    ('P3', 16, [0x1234, 0xabcd, 0xff] + [v * 257 for pixel in rgb[1:] for v in pixel], 65535),
    ('P6', 16, [0x1234, 0xabcd, 0xff] + [v * 257 for pixel in rgb[1:] for v in pixel], 65535),
]:
    header = f'{magic}\n# metadata comment\n3 2\n{maximum}\n'.encode()
    if magic in ('P2', 'P3'):
        payload = (' # sample comment\n' + ' '.join(map(str, values)) + '\n').encode()
    elif maximum > 255:
        payload = struct.pack('>' + 'H' * len(values), *values)
    else:
        payload = bytes(values)
    extension = 'ppm' if magic in ('P3', 'P6') else 'pgm'
    (fixtures / f'pnm-{magic.lower()}-{bits}.{extension}').write_bytes(header + payload)
(fixtures / 'pnm-binary-whitespace.ppm').write_bytes(b'P6\n1 1\n255\n# \n')
(fixtures / 'pnm-binary-crlf.ppm').write_bytes(b'P6\r\n1 1\r\n255\r\n\n #')
(fixtures / 'pnm-truncated.ppm').write_bytes(b'P6\n3 2\n65535\n' + b'\0' * 35)
(fixtures / 'pnm-invalid-sample.ppm').write_bytes(b'P3\n1 1\n255\n0 256 0\n')
(fixtures / 'pnm-invalid-range.pgm').write_bytes(b'P5\n1 1\n65536\n\0\0')
(fixtures / 'pnm-invalid-number.ppm').write_bytes(b'P6\n42949672960 1\n255\n')

if a.vips:
    for kind, source in [('rgb8', 'pnm-p6-8.ppm'), ('rgb16', 'pnm-p6-16.ppm'), ('gray16', 'pnm-p5-16.pgm'), ('alpha', 'alpha.content')]:
        subprocess.run([str(a.vips), 'jxlsave', str(fixtures / source), str(fixtures / f'jxl-{kind}.jxl'), '--lossless'], check=True)
    # Extract the same RGB8 codestream without its container boxes.
    container = (fixtures / 'jxl-rgb8.jxl').read_bytes()
    at = 0
    parts = []
    while at < len(container):
        size = struct.unpack_from('>I', container, at)[0]
        if size < 8 or size > len(container) - at:
            raise ValueError('invalid encoder container box')
        kind = container[at + 4:at + 8]
        if kind == b'jxlc':
            parts = [container[at + 8:at + size]]
            break
        if kind == b'jxlp':
            index = struct.unpack_from('>I', container, at + 8)[0]
            if index & 0x7fffffff != len(parts):
                raise ValueError('unexpected encoder codestream part index')
            parts.append(container[at + 12:at + size])
        at += size
    if not parts:
        raise ValueError('encoder did not produce a codestream box')
    (fixtures / 'jxl-rgb8-raw.jxl').write_bytes(b''.join(parts))

if a.cjxl:
    output = fixtures / 'jxl-orientation6.jxl'
    subprocess.run([str(a.cjxl), str(fixtures / 'orientation6.jpg'), str(output)], check=True)
    subprocess.run([str(a.djxl), str(output), str(fixtures / 'jxl-orientation6-reference.ppm')], check=True)
