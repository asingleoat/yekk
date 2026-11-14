#!/usr/bin/env python3
"""Deflate + horizontal prediction, both byte orders, edge tiles and strips."""
from pathlib import Path
import struct,zlib
width,height=257,64
def sample(x,y):return ((x*257+y)&65535,(y*911+x*3)&65535,(x*31)^(y*127))
for endian,name in [('<','little'),('>','big')]:
 for tiled in [False,True]:
  bw,bh=(16,16) if tiled else (width,40)
  blocks=[]
  for y0 in range(0,height,bh):
   for x0 in range(0,width,bw):
    data=bytearray()
    for y in range(y0, y0+(bh if tiled else min(bh,height-y0))):
     previous=(0,0,0)
     for x in range(x0,x0+bw):
      values=sample(x,y) if x<width and y<height else (0,0,0)
      data+=struct.pack(endian+'HHH',*((values[c]-previous[c])&65535 for c in range(3)));previous=values
    blocks.append(zlib.compress(data))
  fields=[(256,4,1,width),(257,4,1,height),(258,3,3,0),(259,3,1,8),(262,3,1,2),(274,3,1,6),(277,3,1,3),(284,3,1,1),(317,3,1,2),(339,3,1,1)]
  if tiled:fields += [(322,4,1,bw),(323,4,1,bh),(324,4,len(blocks),0),(325,4,len(blocks),0)];offset_tag,count_tag=324,325
  else:fields +=[(273,4,len(blocks),0),(278,4,1,bh),(279,4,len(blocks),0)];offset_tag,count_tag=273,279
  fields.sort();extra=8+2+len(fields)*12+4;pixel_start=extra+6+len(blocks)*8
  offsets=[];cursor=pixel_start
  for block in blocks:offsets.append(cursor);cursor+=len(block)
  pointers={258:extra,offset_tag:extra+6,count_tag:extra+6+len(blocks)*4}
  header=(b'II' if endian=='<' else b'MM')+struct.pack(endian+'HIH',42,8,len(fields))
  for tag,kind,count,value in fields:
   value=pointers.get(tag,value)
   encoded=struct.pack(endian+'H',value)+b'\0\0' if kind==3 and count==1 else struct.pack(endian+'I',value)
   header+=struct.pack(endian+'HHI',tag,kind,count)+encoded
  header+=struct.pack(endian+'IHHH',0,16,16,16)+struct.pack(endian+'I'*len(blocks),*offsets)+struct.pack(endian+'I'*len(blocks),*map(len,blocks))
  Path(__file__).with_name('fixtures').joinpath(f'predictor16-{name}-'+('tiled' if tiled else 'strips')+'.tif').write_bytes(header+b''.join(blocks))
