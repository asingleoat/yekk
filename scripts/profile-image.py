#!/usr/bin/env python3
"""Interleave before/after CPU image trials; preserve raw results and hashes."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import signal
import statistics
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('images', nargs='+', type=Path)
p.add_argument('--baseline', type=Path, required=True)
p.add_argument('--candidate', type=Path, required=True)
p.add_argument('--repeats', type=int, default=7)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
if a.repeats < 3: p.error('at least three repetitions are required')
binaries = {name: path.resolve(strict=True) for name, path in [('before', a.baseline), ('after', a.candidate)]}
def execute(args):
    process = subprocess.Popen(list(map(str, args)), start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try: out, err = process.communicate(timeout=120)
    except BaseException:
        os.killpg(process.pid, signal.SIGKILL); process.communicate(); raise
    if process.returncode: raise RuntimeError(f'{args}: {err}')
    return json.loads(out)

a.output.parent.mkdir(parents=True, exist_ok=True)
with a.output.open('x') as output:
    def save(value): output.write(json.dumps(value, sort_keys=True) + '\n'); output.flush()
    save(dict(kind='metadata', utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), os=platform.platform(), seed=20261025,
              binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for name, path in binaries.items()},
              conditions='Sequential fresh processes; full read primes each trial; randomized interleaved variants; warm file data, not storage-cold. Checksums outside decode clocks.'))
    randomizer = random.Random(20261025)
    for image in a.images:
        image = image.expanduser().resolve(strict=True)
        before = image.stat()
        results = []
        trials = [(repeat, mode) for repeat in range(a.repeats) for mode in ['before', 'after', 'after-static']]
        randomizer.shuffle(trials)
        for repeat, mode in trials:
            exe = binaries['before' if mode == 'before' else 'after']
            priming = execute([exe, 'read', image])
            args = [exe, 'decode', image, '--workers', '8']
            if mode == 'after': args += ['--dynamic']
            if mode == 'after-static': args += ['--static']
            record = execute(args)
            record.update(kind='measurement', image=str(image), repeat=repeat, variant=mode, priming_read_ms=priming['wall_ms'])
            save(record); results.append(record)
            print(f'{image.name} {mode} {record["wall_ms"]:.3f} ms allocation={record["allocation_ms"]:.3f} ms', flush=True)
        if len({r['checksum'] for r in results}) != 1: raise RuntimeError('decoded bytes changed')
        now = image.stat()
        if (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (now.st_ino, now.st_size, now.st_mtime_ns, now.st_ctime_ns): raise RuntimeError('source changed')
        for mode in ['before', 'after', 'after-static']:
            samples = [r for r in results if r['variant'] == mode]
            summary = dict(kind='summary', image=str(image), variant=mode, samples=len(samples))
            for key in ['wall_ms', 'allocation_ms', 'decode_wall_ms', 'blocks_ms', 'conversion_ms', 'native_ms', 'user_ms', 'system_ms', 'peak_rss_bytes', 'lane_min_ms', 'lane_max_ms']:
                if key in samples[0]: summary[key] = statistics.median(r[key] for r in samples)
            summary.update(min_ms=min(r['wall_ms'] for r in samples), max_ms=max(r['wall_ms'] for r in samples))
            save(summary); print(json.dumps(summary, sort_keys=True), flush=True)
