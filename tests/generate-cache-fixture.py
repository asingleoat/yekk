#!/usr/bin/env python3
"""Deterministic multi-strip RGB16 fixture crossing 32-pixel transpose blocks."""
from pathlib import Path
import struct
width, height, rows = 257, 64, 40
fields = [(256,4,1,width),(257,4,1,height),(258,3,3,0),(259,3,1,1),(262,3,1,2),(273,4,2,0),(274,3,1,6),(277,3,1,3),(278,4,1,rows),(279,4,2,0),(284,3,1,1),(339,3,1,1)]
extra = 8 + 2 + len(fields)*12 + 4
pixel_start = extra + 6 + 8 + 8
fixed = {258:extra,273:extra+6,279:extra+14}
header = b'II' + struct.pack('<HIH',42,8,len(fields))
for tag, kind, count, value in fields:
    value = fixed.get(tag,value)
    encoded = struct.pack('<H',value)+b'\0\0' if kind == 3 and count == 1 else struct.pack('<I',value)
    header += struct.pack('<HHI',tag,kind,count)+encoded
header += struct.pack('<I',0)+struct.pack('<HHH',16,16,16)
header += struct.pack('<II',pixel_start,pixel_start+width*rows*6)
header += struct.pack('<II',width*rows*6,width*(height-rows)*6)
pixels = b''.join(struct.pack('<HHH',(x*257+y)&65535,(y*911+x*3)&65535,(x*31)^(y*127)) for y in range(height) for x in range(width))
Path(__file__).with_name('fixtures').joinpath('rgb16-cache-rotate.tif').write_bytes(header+pixels)
