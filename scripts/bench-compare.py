#!/usr/bin/env python3
"""Randomized ABBA/BAAB comparisons of headless Yekk benchmarks.

The replication unit is a four-process block, never an individual frame.
No timing-based exclusions or significance-based early stopping are performed.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import statistics
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--plan', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--blocks', type=int, default=24)
parser.add_argument('--seed', type=int, default=20261113)
args = parser.parse_args()
for path in [args.output, args.output.with_suffix('.jsonl'), args.output.with_suffix('.progress.json')]:
    if path.exists():
        parser.error(f'refusing to overwrite existing evidence: {path}')
if args.blocks < 12 or args.blocks % 2:
    parser.error('--blocks must be even and at least 12; select it before running')
plan = json.loads(args.plan.read_text())
comparisons = plan['comparisons']
if not comparisons or len({c['name'] for c in comparisons}) != len(comparisons):
    parser.error('comparison names must be nonempty and unique')
for c in comparisons:
    if c['metric'] not in ['first_fit', 'steady', 'steady_even']:
        parser.error('metric must be first_fit, steady or steady_even')
    for key in ['control', 'candidate']:
        c[key] = str(Path(c[key]).resolve(strict=True))
image = Path(plan['image']).resolve(strict=True)


def cpu():
    if sys.platform != 'linux':
        return None
    fields = Path('/proc/stat').read_text().splitlines()[0].split()[1:9]
    values = list(map(int, fields))
    return sum(values), values[3] + values[4]


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def save():
    args.output.parent.mkdir(parents=True, exist_ok=True)
    complete = report.get('completed') or report.get('failed') or not args.output.exists()
    path = args.output if complete else args.output.with_suffix('.progress.json')
    data = report if complete else {'completed_blocks': sum(len(b['runs']) == 4 for b in report['blocks']), 'planned_blocks': args.blocks * len(comparisons), 'last': report['blocks'][-1]['name'] if report['blocks'] else 'warmup'}
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(path)


def record_run(block, result):
    event = {'comparison': block['name'], 'block': block.get('number', 'warmup'), 'order': block['order'], 'run': result}
    with args.output.with_suffix('.jsonl').open('a') as raw:
        raw.write(json.dumps(event, separators=(',', ':')) + '\n')


def run(c, label):
    executable = c['control' if label == 'A' else 'candidate']
    command = [executable, c['mode'], str(image), '--workers', str(plan.get('workers', 8)),
               '--width', str(plan.get('width', 3840)), '--height', str(plan.get('height', 2160)),
               '--iterations', str(c.get('iterations', plan.get('iterations', 64)))]
    before = cpu()
    started = time.monotonic()
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired as error:
        return {'label': label, 'command': command, 'error': 'process timeout',
                'process_wall_ms': (time.monotonic() - started) * 1000,
                'stdout': (error.stdout or b'').decode(errors='replace'),
                'stderr': (error.stderr or b'').decode(errors='replace')}
    after = cpu()
    result = {'label': label, 'command': command, 'status': process.returncode,
              'process_wall_ms': (time.monotonic() - started) * 1000,
              'load': os.getloadavg(), 'stderr': process.stderr,
              'total_cpu_busy_including_benchmark': 1 - (after[1] - before[1]) / max(1, after[0] - before[0]) if before is not None and after is not None else None}
    try:
        result['records'] = [json.loads(line) for line in process.stdout.splitlines()]
    except (ValueError, TypeError):
        result['error'] = 'invalid JSON output'
        result['stdout'] = process.stdout
        return result
    if process.returncode:
        result['error'] = 'nonzero process status'
        return result
    frames = [r for r in result['records'] if r['mode'] == 'prepare']
    samples = [r['wall_ms'] for r in frames if (r['step'] == 0 if c['metric'] == 'first_fit' else r['step'] >= 4 and (c['metric'] != 'steady_even' or r['step'] % 2 == 0))]
    if not samples or any(not math.isfinite(x) or x < 0 for x in samples):
        result['error'] = 'missing or invalid timing samples'
        return result
    result['metric_unfloored_ms'] = statistics.median(samples)
    resolutions = [r['resolution_ms'] for r in result['records'] if r['mode'] == 'clock']
    resolution = max(resolutions, default=0)
    result['clock_resolution_ms'] = resolution
    result['metric_below_clock_resolution'] = result['metric_unfloored_ms'] < resolution
    # Cached calls can finish within one clock tick. Use an explicit upper
    # measurement bound, rather than logging zero or inventing nanosecond precision.
    result['metric_ms'] = max(resolution, result['metric_unfloored_ms'])
    if not math.isfinite(result['metric_ms']) or result['metric_ms'] <= 0:
        result['error'] = 'nonpositive metric without a clock resolution'
        return result
    result['frames_in_metric'] = len(samples)
    return result


seeded = random.Random(args.seed)
schedules = {}
for c in comparisons:
    order = ['ABBA'] * (args.blocks // 2) + ['BAAB'] * (args.blocks // 2)
    seeded.shuffle(order)
    schedules[c['name']] = order
rounds = []
for i in range(args.blocks):
    names = [c['name'] for c in comparisons]
    seeded.shuffle(names)
    rounds.append(names)
report = {'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'protocol': {'blocks_per_comparison': args.blocks, 'processes_per_block': 4,
                       'seed': args.seed, 'order': 'balanced randomized ABBA/BAAB; comparison order shuffled each round',
                       'warmup': 'one four-process block per comparison, excluded in advance',
                       'metric': 'per-process first-fit time or median after four warmup frames; steady_even selects even steps only',
                       'replication_unit': 'four-process block; frame timings are not independent replicates',
                       'sub_tick_policy': 'per-process median below the reported clock resolution is conservatively floored to that resolution; raw values retained',
                       'stopping': 'fixed in advance; no significance-based stopping or timing exclusions',
                       'interval': 'family-adjusted circular moving-block bootstrap; 3 consecutive blocks per resampled chunk',
                       'schedule': schedules, 'rounds': rounds},
          'plan': plan, 'image_sha256': digest(image),
          'binary_sha256': {p: digest(p)
                            for c in comparisons for p in [c['control'], c['candidate']]},
          'image_stat_before': [image.stat().st_dev, image.stat().st_ino, image.stat().st_size, image.stat().st_mtime_ns, image.stat().st_ctime_ns],
          'harness_sha256': digest(__file__), 'load_before': os.getloadavg(), 'host': list(os.uname()), 'affinity': sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else None, 'warmup': [], 'blocks': []}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.with_suffix('.jsonl').write_text('')
save()
by_name = {c['name']: c for c in comparisons}
for c in comparisons:
    block = {'name': c['name'], 'order': 'ABBA', 'runs': []}
    report['warmup'].append(block)
    for label in block['order']:
        result = run(c, label)
        block['runs'].append(result)
        record_run(block, result)
        save()
        if 'error' in result:
            report['failed'] = True
            save()
            raise SystemExit('warmup failed; preserved without silently excluding it')
for number, names in enumerate(rounds):
    for name in names:
        block = {'name': name, 'number': number, 'order': schedules[name][number], 'runs': []}
        report['blocks'].append(block)
        for label in block['order']:
            result = run(by_name[name], label)
            block['runs'].append(result)
            record_run(block, result)
            save()
            if 'error' in result:
                report['failed'] = True
                save()
                raise SystemExit('comparison failed; preserved without silently excluding it')
        logs = {label: [math.log(r['metric_ms']) for r in block['runs'] if r['label'] == label] for label in 'AB'}
        block['log_ratio'] = statistics.mean(logs['B']) - statistics.mean(logs['A'])
        save()
    print(f'Completed round {number + 1}/{args.blocks}', flush=True)

# Analyze only after the fixed schedule has completed. Resample whole temporal
# chunks, rather than pretending frames or immediately adjacent runs are IID.
report['analysis'] = {}
family_alpha = 0.05 / len(comparisons)
for index, c in enumerate(comparisons):
    blocks = [b for b in report['blocks'] if b['name'] == c['name']]
    effects = [b['log_ratio'] for b in blocks]
    rng = random.Random(args.seed + index + 1)
    distribution = []
    for _ in range(20000):
        sample = []
        while len(sample) < len(effects):
            start = rng.randrange(len(effects))
            sample.extend(effects[(start + j) % len(effects)] for j in range(3))
        distribution.append(statistics.mean(sample[:len(effects)]))
    distribution.sort()
    low = math.exp(distribution[int(len(distribution) * family_alpha / 2)])
    high = math.exp(distribution[min(len(distribution)-1, math.ceil(len(distribution) * (1-family_alpha/2))-1)])
    result = {'candidate_over_control': math.exp(statistics.mean(effects)),
              'family_adjusted_interval': [low, high], 'interval_coverage': 1-family_alpha,
              'blocks': len(blocks), 'chunk_blocks': 3,
              'order_ratios': {order: math.exp(statistics.mean(b['log_ratio'] for b in blocks if b['order'] == order)) for order in ['ABBA', 'BAAB']},
              'control_median_ms': statistics.median(r['metric_ms'] for b in blocks for r in b['runs'] if r['label'] == 'A'),
              'candidate_median_ms': statistics.median(r['metric_ms'] for b in blocks for r in b['runs'] if r['label'] == 'B'),
              'classification': 'faster' if high < 1 else 'slower' if low > 1 else 'inconclusive'}
    # A randomization check follows the actual balanced orientation assignment.
    # Under the sharp null, orientation only changes the sign of each block's
    # time-slot contrast; unrestricted per-frame permutations would be invalid.
    contrasts = [b['log_ratio'] * (1 if b['order'] == 'ABBA' else -1) for b in blocks]
    observed = abs(statistics.mean(effects))
    signs = [1] * (len(blocks) // 2) + [-1] * (len(blocks) // 2)
    exceed = 0
    for _ in range(20000):
        rng.shuffle(signs)
        exceed += abs(sum(sign * contrast for sign, contrast in zip(signs, contrasts)) / len(blocks)) >= observed
    result['randomization_p'] = (exceed + 1) / 20001
    result['family_alpha'] = family_alpha
    result['order_disagreement'] = (result['order_ratios']['ABBA'] < 1) != (result['order_ratios']['BAAB'] < 1)
    if result['randomization_p'] > family_alpha or result['order_disagreement']:
        result['classification'] = 'inconclusive'
    report['analysis'][c['name']] = result
    print(c['name'], json.dumps(result), flush=True)
report['sanity_passed'] = all(report['analysis'][c['name']]['classification'] == 'inconclusive' for c in comparisons if c['control'] == c['candidate'])
report['image_stat_after'] = [image.stat().st_dev, image.stat().st_ino, image.stat().st_size, image.stat().st_mtime_ns, image.stat().st_ctime_ns]
if report['image_stat_after'] != report['image_stat_before']:
    report['failed'] = True
    save()
    raise SystemExit('input identity changed during the study')
report['completed'] = True
save()
