#!/bin/sh
set -eu

usage='Usage: scripts/clean.sh [--cache]
Remove zig-out/. With --cache, also remove the generated Zig cache.'

case "$#:${1-}" in
    0:|1:--cache) ;;
    1:-h|1:--help) printf '%s\n' "$usage"; exit 0 ;;
    *) printf '%s\n' "$usage" >&2; exit 2 ;;
esac

CDPATH= cd -P "$(dirname "$0")/.."
if [ "${1-}" = --cache ] && [ -L .zig-cache ]; then
    printf '%s\n' 'Cannot clean a symlinked .zig-cache directory.' >&2
    exit 1
fi

rm -rf zig-out
if [ "${1-}" = --cache ]; then
    # Benchmark inputs and source snapshots also live in .zig-cache.
    rm -rf .zig-cache/c .zig-cache/h .zig-cache/o .zig-cache/tmp .zig-cache/z
fi
