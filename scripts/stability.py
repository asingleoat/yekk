#!/usr/bin/env python3
"""Bounded native lifetime/pressure stress using an instrumented viewer."""
import argparse
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--executable', type=Path, default=root / 'zig-out-debug/bin/yekk')
p.add_argument('--repeats', type=int, default=8)
p.add_argument('--cycles', type=int, default=512)
p.add_argument('--output', type=Path)
a = p.parse_args()
if a.repeats < 1 or a.cycles < 16: p.error('positive repeats and at least 16 cycles required')
viewer = a.executable.resolve(strict=True)
viewer_sha256 = hashlib.sha256(viewer.read_bytes()).hexdigest()
records = []
def save():
    if a.output:
        a.output.parent.mkdir(parents=True, exist_ok=True)
        pending = a.output.with_suffix(a.output.suffix + '.tmp')
        pending.write_text(json.dumps(dict(executable=str(viewer), sha256=viewer_sha256, cycles=a.cycles, repeats=a.repeats,
                                          malloc_scribble=True, malloc_guard_edges=True, records=records), indent=2) + '\n')
        pending.replace(a.output)

with tempfile.TemporaryDirectory(prefix='yekk-stability-') as temporary:
    env = dict(os.environ, YEKK_CONFIG=str(Path(temporary) / 'none'), XDG_CONFIG_HOME=temporary,
               MallocScribble='1', MallocGuardEdges='1', YEKK_TEST_TIMEOUT='60', YEKK_VIEWER=str(viewer))
    sources = ['predictor16-little-strips.tif', 'predictor16-big-strips.tif', 'predictor16-little-tiled.tif', 'predictor16-big-tiled.tif']
    for repeat in range(a.repeats):
        inputs = ['tests/fixtures/orientation6.jpg', 'tests/fixtures/truncated.png', 'tests/fixtures/' + sources[repeat % len(sources)]]
        command = ['python3', 'scripts/supervise.py', str(viewer), '--stress-test', str(a.cycles), *inputs]
        if repeat % 2:
            # A warm-cache assertion must establish its own warmup even when
            # speculative admission is unavailable. This used to fail reliably.
            command.append('--stress-no-prefetch')
        result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=70)
        records.append(dict(repeat=repeat, command=command, status=result.returncode, stdout=result.stdout, stderr=result.stderr))
        save()
        print(result.stdout, end='', flush=True); print(result.stderr, end='', flush=True)
        if result.returncode or 'STRESS_PASSED' not in result.stdout or 'live_bytes=0' not in result.stderr:
            raise RuntimeError('instrumented lifetime/pressure test failed')
    # Distinct workflows cover Finder routing, hooks, file-list replacement,
    # source watching and recovery in the same allocator mode.
    valid = ['tests/fixtures/orientation6.jpg', 'tests/fixtures/gray16.png', 'tests/fixtures/detail-wide.png']
    for command in [['sh', 'scripts/smoke.sh'], ['python3', 'scripts/feh-test.py'], ['python3', 'scripts/watch-test.py'],
                    ['python3', 'scripts/supervise.py', str(viewer), '--recovery-test', *valid],
                    ['python3', 'scripts/supervise.py', str(viewer), '--detail-test', *valid]]:
        result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=120)
        records.append(dict(command=command, status=result.returncode, stdout=result.stdout, stderr=result.stderr))
        save()
        print(result.stdout, end='', flush=True)
        if result.returncode: raise RuntimeError(result.stderr)
print('instrumented stability suite: passed')
