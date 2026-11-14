#!/usr/bin/env python3
"""Interleave library and SIMD TIFF predictor trials with exact output hashes."""
import argparse,hashlib,json,random,statistics,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('images',type=Path,nargs='+');p.add_argument('--repeats',type=int,default=7)
p.add_argument('--executable',type=Path,default=Path('zig-out/bin/yekk-bench-image'))
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();exe=a.executable.resolve(strict=True)
with a.output.open('x') as out:
 def save(x):out.write(json.dumps(x,sort_keys=True)+'\n');out.flush()
 save(dict(kind='metadata',executable=str(exe),sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),condition='Randomized, sequential warm-file-data trials; native libtiff predictor versus native-order SIMD predictor; same library inflater, scheduling and output layout'))
 for image in a.images:
  image=image.resolve(strict=True);identity=image.stat();values=[]
  trials=[(i,mode) for i in range(a.repeats) for mode in ['native','simd']];random.Random(20261025).shuffle(trials)
  for repeat,mode in trials:
   subprocess.run([str(exe),'read',str(image)],check=True,stdout=subprocess.DEVNULL,timeout=30)
   command=[str(exe),'decode',str(image),'--workers','8']+(['--simd-predictor'] if mode=='simd' else ['--native-predictor'])
   r=json.loads(subprocess.check_output(command,text=True,timeout=90));r.update(kind='measurement',image=str(image),variant=mode,repeat=repeat);save(r);values.append(r)
   print(image.name,mode,r['wall_ms'],flush=True)
  if len({r['checksum'] for r in values})!=1:raise RuntimeError('decoded output mismatch')
  for mode in ['native','simd']:
   rows=[r for r in values if r['variant']==mode]
   summary=dict(kind='summary',image=str(image),variant=mode,samples=len(rows),**{k:statistics.median(r[k] for r in rows) for k in ['wall_ms','blocks_ms','conversion_ms','user_ms','system_ms','destroy_ms']})
   save(summary);print(summary,flush=True)
  now=image.stat()
  assert (identity.st_ino,identity.st_size,identity.st_mtime_ns,identity.st_ctime_ns)==(now.st_ino,now.st_size,now.st_mtime_ns,now.st_ctime_ns)
