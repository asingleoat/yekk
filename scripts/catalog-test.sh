#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
viewer=${YEKK_VIEWER:-./zig-out/bin/yekk}
task_directory=$(mktemp -d "${TMPDIR:-/tmp}/yekk-catalog.XXXXXX")
trap 'rm -rf "$task_directory"' EXIT HUP INT TERM
mkdir "$task_directory/images" "$task_directory/images/nested" "$task_directory/empty"
cp tests/fixtures/alpha.content "$task_directory/images/image10.png"
cp tests/fixtures/alpha.content "$task_directory/images/image2.png"
cp tests/fixtures/orientation6.jpg "$task_directory/images/image1.jpg"
cp tests/fixtures/alpha.content "$task_directory/images/.hidden.png"
cp tests/fixtures/alpha.content "$task_directory/images/nested/image3.png"
cp tests/fixtures/alpha.content "$task_directory/first.png"
cp tests/fixtures/alpha.content "$task_directory/last.png"
printf 'not an image\n' > "$task_directory/images/notes.txt"
ln -s .. "$task_directory/images/nested/loop"
names() { "$viewer" --print-filelist "$@" | sed 's|.*/||'; }
test "$(names "$task_directory/images")" = "$(printf 'image1.jpg\nimage2.png\nimage10.png')"
test "$(names --recursive "$task_directory/images")" = "$(printf 'image1.jpg\nimage2.png\nimage3.png\nimage10.png')"
test "$(names --sort name "$task_directory/images")" = "$(printf 'image1.jpg\nimage10.png\nimage2.png')"
test "$(names --reverse "$task_directory/images")" = "$(printf 'image10.png\nimage2.png\nimage1.jpg')"
test "$(names "$task_directory/first.png" "$task_directory/images" "$task_directory/last.png")" = "$(printf 'first.png\nimage1.jpg\nimage2.png\nimage10.png\nlast.png')"
test "$(names --browse "$task_directory/images/image2.png")" = "$(printf 'image1.jpg\nimage2.png\nimage10.png')"
test "$(names "$task_directory/images/.hidden.png")" = '.hidden.png'
ln -s ../first.png "$task_directory/images/link.png"
test "$(names "$task_directory/images/link.png")" = 'link.png'
test "$(names --browse --start-at "$task_directory/images/link.png" "$task_directory/images/link.png" | sed -n '/^link.png$/p')" = 'link.png'
if "$viewer" --print-filelist "$task_directory/empty" >/dev/null 2>&1; then exit 1; fi
printf 'catalog integration: passed\n'
