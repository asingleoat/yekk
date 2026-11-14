#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
viewer=${YEKK_VIEWER:-./zig-out/bin/yekk}
"$viewer" --version
"$viewer" --help >/dev/null
"$viewer" --formats >/dev/null
expect_usage_error() {
  status=0
  "$viewer" "$@" >/dev/null 2>/dev/null || status=$?
  test "$status" -eq 2
}
expect_usage_error --unknown
expect_usage_error --fit
expect_usage_error --fit nonsense
expect_usage_error --zoom NaN
expect_usage_error --action1
task_fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/yekk-smoke.XXXXXX")
trap 'rm -rf "$task_fixture_dir"' EXIT HUP INT TERM
selected_path="$task_fixture_dir/photo 雪.png"
export YEKK_CONFIG="$task_fixture_dir/no-config"
cp tests/fixtures/alpha.content "$selected_path"
python3 scripts/supervise.py "$viewer" --smoke-test tests/fixtures/orientation6.jpg tests/fixtures/truncated.png "$selected_path"
python3 scripts/supervise.py "$viewer" --smoke-windows tests/fixtures/orientation6.jpg tests/fixtures/truncated.png "$selected_path"
