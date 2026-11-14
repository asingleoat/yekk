#!/usr/bin/env python3
"""Measure CPU scaling and production versus poisoned retirement sequentially."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import signal
import statistics
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('image', type=Path)
p.add_argument('--executable', type=Path, default=Path('zig-out/bin/yekk-bench-image'))
p.add_argument('--workers', type=int, nargs='+', default=[1,2,4,8,os.cpu_count() or 1])
p.add_argument('--repeats', type=int, default=3)
p.add_argument('--output', type=Path, required=True)
a=p.parse_args(); image=a.image.expanduser().resolve(strict=True); exe=a.executable.resolve(strict=True)
if a.repeats<3 or min(a.workers)<1: p.error('at least three repetitions and positive workers required')
identity=image.stat()
def run(args):
    proc=subprocess.Popen([str(exe),*map(str,args)],start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try: out,err=proc.communicate(timeout=120)
    except BaseException:
        os.killpg(proc.pid,signal.SIGKILL);proc.communicate();raise
    if proc.returncode: raise RuntimeError(err)
    return json.loads(out)
trials=[(workers,False,i) for workers in sorted(set(a.workers)) for i in range(a.repeats)]
trials += [(max(a.workers),True,i) for i in range(a.repeats)]
random.Random(20261025).shuffle(trials); values=[]
with a.output.open('x') as out:
    def save(value):out.write(json.dumps(value,sort_keys=True)+'\n');out.flush()
    save(dict(kind='metadata',utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),executable=str(exe),sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),condition='Warm, sequential fresh processes; priming read before each trial; randomized order; debug allocator disabled'))
    for workers,poison,repeat in trials:
        run(['read',image])
        args=['decode',image,'--workers',workers]+(['--poison-free'] if poison else [])
        value=run(args);value.update(kind='measurement',poison_free=poison,repeat=repeat);save(value);values.append(value)
        print(f'workers={workers} poison_free={poison}: decode={value["wall_ms"]:.3f} free={value["destroy_ms"]:.3f} ms',flush=True)
    if len({v['checksum'] for v in values})!=1:raise RuntimeError('decoded bytes changed')
    for workers,poison in sorted({(v['workers'],v['poison_free']) for v in values}):
        rows=[v for v in values if (v['workers'],v['poison_free'])==(workers,poison)]
        summary=dict(kind='summary',workers=workers,poison_free=poison,samples=len(rows),**{key:statistics.median(v[key] for v in rows) for key in ['wall_ms','destroy_ms','user_ms','system_ms','allocated_bytes','scratch_reclaimable_bytes','peak_rss_bytes']})
        save(summary);print(summary,flush=True)
now=image.stat()
assert (identity.st_ino,identity.st_size,identity.st_mtime_ns,identity.st_ctime_ns)==(now.st_ino,now.st_size,now.st_mtime_ns,now.st_ctime_ns)
