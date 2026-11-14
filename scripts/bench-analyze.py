#!/usr/bin/env python3
"""Analyze paired minimums from a completed benchmark study.

Use the faster process result for each variant within a four-process block.
Compare the paired results. Keep the raw study unchanged and write a new file.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import statistics


def analyze(report, draws=20000, clock_resolution_ms=0):
    if not report.get('completed') or report.get('failed'):
        raise ValueError('study did not complete successfully')
    if not math.isfinite(clock_resolution_ms) or clock_resolution_ms < 0:
        raise ValueError('invalid clock resolution')
    def metric(run):
        return max(clock_resolution_ms, run['metric_ms'])
    comparisons = report['plan']['comparisons']
    alpha = 0.05 / len(comparisons)
    seed = report['protocol']['seed']
    results = {}
    for index, comparison in enumerate(comparisons):
        blocks = [b for b in report['blocks'] if b['name'] == comparison['name']]
        effects = []
        minima = []
        for block in blocks:
            pair = {label: min(metric(r) for r in block['runs'] if r['label'] == label)
                    for label in 'AB'}
            minima.append(pair)
            effects.append(math.log(pair['B']) - math.log(pair['A']))
        if len(effects) != report['protocol']['blocks_per_comparison']:
            raise ValueError('missing measured blocks')
        estimate = statistics.median(effects)
        rng = random.Random(seed + index + 1001)
        bootstrap = []
        for _ in range(draws):
            sample = []
            while len(sample) < len(effects):
                start = rng.randrange(len(effects))
                sample.extend(effects[(start + j) % len(effects)] for j in range(3))
            bootstrap.append(statistics.median(sample[:len(effects)]))
        bootstrap.sort()
        interval = [math.exp(bootstrap[int(draws * alpha / 2)]),
                    math.exp(bootstrap[min(draws - 1, math.ceil(draws * (1 - alpha / 2)) - 1)])]
        contrasts = [effect * (1 if block['order'] == 'ABBA' else -1)
                     for effect, block in zip(effects, blocks)]
        signs = [1] * (len(effects) // 2) + [-1] * (len(effects) // 2)
        observed_score = abs(sum((value > 0) - (value < 0) for value in effects))
        exceed = 0
        for _ in range(draws):
            rng.shuffle(signs)
            score = abs(sum(sign * ((value > 0) - (value < 0)) for sign, value in zip(signs, contrasts)))
            exceed += score >= observed_score
        p = (exceed + 1) / (draws + 1)
        orders = {order: math.exp(statistics.median(effect for effect, block in zip(effects, blocks)
                                                  if block['order'] == order)) for order in ['ABBA', 'BAAB']}
        disagreement = (orders['ABBA'] < 1) != (orders['BAAB'] < 1)
        classification = 'faster' if interval[1] < 1 else 'slower' if interval[0] > 1 else 'inconclusive'
        if p > alpha or disagreement:
            classification = 'inconclusive'
        results[comparison['name']] = {
            'candidate_over_control': math.exp(estimate),
            'family_adjusted_interval': interval, 'interval_coverage': 1 - alpha,
            'randomization_p': p, 'randomization_statistic': 'absolute signed count of paired minimum log effects', 'family_alpha': alpha, 'order_ratios': orders,
            'order_disagreement': disagreement, 'classification': classification,
            'blocks': len(blocks), 'processes_per_variant_per_block': 2,
            'control_block_minimum_median_ms': statistics.median(pair['A'] for pair in minima),
            'candidate_block_minimum_median_ms': statistics.median(pair['B'] for pair in minima),
            'block_minima_ms': minima,
        }
        for label, name in [('A', 'control'), ('B', 'candidate')]:
            runs = [run for block in blocks for run in block['runs'] if run['label'] == label]
            frames = [frame for run in runs for frame in run['records'] if frame['mode'] == 'prepare']
            results[comparison['name']][name + '_global_minimum_workload_ms'] = min(metric(r) for r in runs)
            results[comparison['name']][name + '_below_resolution_processes'] = sum(r.get('metric_unfloored_ms', r['metric_ms']) < max(clock_resolution_ms, r.get('clock_resolution_ms', 0)) for r in runs)
            # Includes first-use frames deliberately; the headline estimate uses
            # the matched workloads and warmup policy defined by the run plan.
            results[comparison['name']][name + '_maximum_recorded_frame_ms'] = max(r['wall_ms'] for r in frames)
    return {
        'method': 'median of within-quartet paired minimum log ratios; 3-quartet circular block bootstrap; balanced-orientation signed-count randomization',
        'draws': draws, 'clock_resolution_override_ms': clock_resolution_ms, 'analysis': results,
        'sanity_passed': all(results[c['name']]['classification'] == 'inconclusive'
                             for c in comparisons if c['control'] == c['candidate']),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('study', type=Path)
    parser.add_argument('--clock-resolution-ms', type=float, default=0, help='conservative lower bound when correcting known clock metadata; preserves raw study')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('refusing to overwrite analysis evidence')
    report = json.loads(args.study.read_text())
    result = analyze(report, clock_resolution_ms=args.clock_resolution_ms)
    result['study_file'] = str(args.study)
    result['study_sha256'] = hashlib.sha256(args.study.read_bytes()).hexdigest()
    result['analyzer_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as out:
        out.write(json.dumps(result, indent=2) + '\n')
    for name, comparison in result['analysis'].items():
        print(name, comparison['classification'], comparison['candidate_over_control'],
              comparison['family_adjusted_interval'], flush=True)


if __name__ == '__main__':
    main()
