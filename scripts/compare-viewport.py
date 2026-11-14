#!/usr/bin/env python3
"""Compare RGB/alpha samples in two noninterlaced 8-bit PNG viewport captures."""
import argparse
import json
import math
from pathlib import Path
import struct
import zlib


def png(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG')
    offset = 8
    compressed = bytearray()
    dimensions = None
    while offset < len(data):
        length, = struct.unpack_from('>I', data, offset)
        kind = data[offset + 4:offset + 8]
        chunk = data[offset + 8:offset + 8 + length]
        crc, = struct.unpack_from('>I', data, offset + 8 + length)
        if zlib.crc32(kind + chunk) != crc:
            raise ValueError('PNG checksum mismatch')
        if kind == b'IHDR':
            width, height, bits, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', chunk)
            if bits != 8 or color not in (2, 6) or compression or filtering or interlace:
                raise ValueError('requires noninterlaced RGB/RGBA8 PNG')
            dimensions = (width, height, 3 if color == 2 else 4)
        elif kind == b'IDAT':
            compressed.extend(chunk)
        elif kind == b'IEND':
            break
        offset += length + 12
    width, height, channels = dimensions
    raw = zlib.decompress(compressed)
    stride = width * channels
    if len(raw) != (stride + 1) * height:
        raise ValueError('unexpected decoded byte count')
    result = bytearray()
    previous = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            a = row[x - channels] if x >= channels else 0
            b = previous[x]
            c = previous[x - channels] if x >= channels else 0
            if kind == 0:
                prediction = 0
            elif kind == 1:
                prediction = a
            elif kind == 2:
                prediction = b
            elif kind == 3:
                prediction = (a + b) // 2
            elif kind == 4:
                p = a + b - c
                distances = (abs(p - a), abs(p - b), abs(p - c))
                prediction = (a, b, c)[distances.index(min(distances))]
            else:
                raise ValueError('invalid PNG filter')
            row[x] = (row[x] + prediction) & 255
        if channels == 3:
            for x in range(width):
                result.extend(row[x * 3:x * 3 + 3])
                result.append(255)
        else:
            result.extend(row)
        previous = row
    return width, height, result


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference')
parser.add_argument('candidate')
args = parser.parse_args()
w, h, first = png(args.reference)
w2, h2, second = png(args.candidate)
if (w, h) != (w2, h2):
    raise SystemExit('viewport dimensions differ')
max_rgb = max_alpha = changed_rgb = squared_rgb = changed_alpha = 0
for i, (a, b) in enumerate(zip(first, second)):
    difference = abs(a - b)
    if i % 4 == 3:
        max_alpha = max(max_alpha, difference)
        changed_alpha += bool(difference)
    else:
        max_rgb = max(max_rgb, difference)
        changed_rgb += bool(difference)
        squared_rgb += difference ** 2
print(json.dumps({'width': w, 'height': h, 'rgb_max_abs': max_rgb,
                  'rgb_rms': math.sqrt(squared_rgb / (w * h * 3)),
                  'rgb_changed_percent': changed_rgb * 100 / (w * h * 3),
                  'alpha_max_abs': max_alpha, 'alpha_changed_samples': changed_alpha}, sort_keys=True))
