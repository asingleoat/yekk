#!/usr/bin/env python3
"""Add orientation metadata to a fixed JPEG without changing compressed pixels."""
from pathlib import Path
import struct

folder = Path(__file__).resolve().parent / 'fixtures'
original = (folder / 'orientation6.jpg').read_bytes()
core = bytearray(original[:2])
sequential = bytearray(original[:2])
offset = 2
while offset < len(original):
    marker = original[offset + 1]
    if marker == 0xda:
        core.extend(original[offset:])
        # This 3x2 fixture has one MCU, so no restart occurs inside its scan.
        # Removing its DRI declaration exercises the sequential fast path.
        assert not any(bytes([255, code]) in original[offset:] for code in range(0xd0, 0xd8))
        sequential.extend(original[offset:])
        break
    length = struct.unpack_from('>H', original, offset + 2)[0]
    payload = original[offset + 4:offset + 2 + length]
    if not (marker == 0xe1 and payload.startswith(b'Exif\0\0')):
        core.extend(original[offset:offset + 2 + length])
        if marker != 0xdd:
            sequential.extend(original[offset:offset + 2 + length])
    offset += length + 2
for orientation in range(1, 9):
    exif = b'Exif\0\0II' + struct.pack('<HIH', 42, 8, 1) + struct.pack('<HHIHHI', 274, 3, 1, orientation, 0, 0)
    segment = b'\xff\xe1' + struct.pack('>H', len(exif) + 2) + exif
    (folder / f'jpeg-orientation{orientation}.jpg').write_bytes(core[:2] + segment + core[2:])
    (folder / f'jpeg-sequential-orientation{orientation}.jpg').write_bytes(sequential[:2] + segment + sequential[2:])
for name, image in [('srgb', bytes(core)), ('sequential-srgb', bytes(sequential)), ('gray', (folder / 'jpeg-gray.jpg').read_bytes())]:
    profile = (folder / f'decoder-{name.removeprefix("sequential-")}.icc').read_bytes()
    middle = len(profile) // 2
    markers = bytearray()
    for index, part in [(2, profile[middle:]), (1, profile[:middle])]:
        payload = b'ICC_PROFILE\0' + bytes([index, 2]) + part
        markers.extend(b'\xff\xe2' + struct.pack('>H', len(payload) + 2) + payload)
    (folder / f'jpeg-profile-{name}.jpg').write_bytes(image[:2] + markers + image[2:])
print('Generated JPEG orientation cases with identical compressed pixels')
