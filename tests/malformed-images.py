#!/usr/bin/env python3
"""Exercise decoder boundaries in separate, supervised processes."""
import argparse
import binascii
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
binary = args.binary.resolve(strict=True)
fixtures = root / 'tests/fixtures'
report = {'cases': [], 'passed': False}
args.output.parent.mkdir(parents=True, exist_ok=True)
if sys.platform.startswith('linux'):
    import resource
    # Test containment only. The viewer has no fixed application RAM quota.
    resource.setrlimit(resource.RLIMIT_AS, (4 * 1024**3, 4 * 1024**3))


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data))


with tempfile.TemporaryDirectory(prefix='yekk-invalid-images-') as temporary:
    folder = Path(temporary)
    corpus = []

    def add(name, data, expected=None):
        path = folder / name
        path.write_bytes(data)
        corpus.append((path, expected))

    png = (fixtures / 'alpha.content').read_bytes()
    add('valid.png', png, 0)
    add('literal.png[page=999999]', png, 0)
    jpeg = (fixtures / 'orientation6.jpg').read_bytes()
    tiff = (fixtures / 'rgb16-orientation1.tif').read_bytes()
    bmp = (fixtures / 'bmp-rgb24.bmp').read_bytes()
    for extension, data in [('png', png), ('jpg', jpeg), ('tif', tiff), ('bmp', bmp)]:
        for length in sorted({0, 1, 2, 8, 16, len(data) // 2, len(data) - 1}):
            add(f'truncated-{length}.{extension}', data[:length], 1)
    for width, height in [(0, 2), (3, 0), (0xffffffff, 0xffffffff)]:
        header = bytearray(png[16:29])
        struct.pack_into('>II', header, 0, width, height)
        add(f'dimensions-{width}-{height}.png', png[:8] + chunk(b'IHDR', header) + png[33:], 1)
    for profile in [b'', b'acsp', b'\xff' * 132, b'\0' * 128 + b'\xff' * 4]:
        add(f'icc-{len(corpus)}.png', png[:33] + chunk(b'iCCP', b'profile\0\0' + zlib.compress(profile)) + png[33:])
    for marker in [b'\xff\xe1', b'\xff\xe2']:
        for payload in [b'', b'Exif\0\0II*\0\xff\xff\xff\xff', b'ICC_PROFILE\0\1\1' + b'\xff' * 132]:
            segment = marker + struct.pack('>H', len(payload) + 2) + payload
            add(f'metadata-{len(corpus)}.jpg', jpeg[:2] + segment + jpeg[2:])
    endian = '<' if tiff[:2] == b'II' else '>'
    directory = struct.unpack_from(endian + 'I', tiff, 4)[0]
    entries = struct.unpack_from(endian + 'H', tiff, directory)[0]
    for index in range(entries):
        position = directory + 2 + index * 12
        tag, kind, count = struct.unpack_from(endian + 'HHI', tiff, position)
        if count == 1 and kind in (3, 4) and tag in (256, 257, 258, 274, 277, 278, 284, 339):
            for value in (0, 0xffff if kind == 3 else 0xffffffff):
                data = bytearray(tiff)
                struct.pack_into(endian + ('H' if kind == 3 else 'I'), data, position + 8, value)
                # Maximum width AND height rejects arithmetic before allocation.
                if tag in (256, 257) and value == 0xffffffff:
                    for other in range(entries):
                        at = directory + 2 + other * 12
                        if struct.unpack_from(endian + 'H', tiff, at)[0] in (256, 257):
                            struct.pack_into(endian + 'I', data, at + 8, value)
                add(f'tag-{tag}-{value}.tif', data)
    for offset, value in [(2, 0xffffffff), (10, 0), (10, 0xffffffff), (14, 0xffffffff), (18, 0x80000000), (22, 0x80000000), (30, 0xffffffff), (34, 0xffffffff), (46, 0xffffffff)]:
        data = bytearray(bmp)
        struct.pack_into('<I', data, offset, value)
        add(f'field-{offset}-{value}.bmp', data, 1)
    for name in ['bmp-linked-profile.bmp', 'bmp-truncated.bmp']:
        add(name, (fixtures / name).read_bytes(), 1)
    for name in ['pnm-truncated.ppm', 'pnm-invalid-sample.ppm', 'pnm-invalid-range.pgm', 'pnm-invalid-number.ppm']:
        add(name, (fixtures / name).read_bytes(), 1)
    for index, header in enumerate([b'P6\n0 1\n255\n', b'P6\n1 0\n255\n', b'P6\n4294967295 4294967295\n65535\n', b'P3\n1 1\n0\n0 0 0', b'P2\n1 1\n255\n-1', b'P1\n1 1\n2']):
        add(f'header-{index}.pnm', header, 1)
    pipe = folder / 'named-pipe.png'
    os.mkfifo(pipe)
    corpus.append((pipe, 1))
    environment = dict(os.environ, YEKK_CONFIG=str(folder / 'no-config'), YEKK_TEST_TIMEOUT='8')
    for path, expected in corpus:
        command = [sys.executable, str(root / 'scripts/supervise.py'), str(binary), '--alloc-stats', '--benchmark', str(path)]
        result = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True, timeout=15)
        case = {'name': path.name, 'status': result.returncode, 'expected': expected, 'stdout': result.stdout, 'stderr': result.stderr}
        report['cases'].append(case)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        assert result.returncode in (0, 1), case
        if expected is not None:
            assert result.returncode == expected, case
        assert 'live_bytes=0' in result.stderr, case
    report['passed'] = True
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{len(corpus)} supervised input cases passed')
