#!/usr/bin/env python3
"""Private/local Linux checks. Every graphical invocation is supervised."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import struct
import sys
import tempfile
import time
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", default="zig-out/bin/yekk")
parser.add_argument("--output", default="dist/linux-validation.json")
parser.add_argument("--video-driver", default=os.environ.get("SDL_VIDEO_DRIVER", "dummy"))
parser.add_argument("--image", help="Optional full-size local image for a decode/100%% pan test")
parser.add_argument("--cycles", type=int, default=64)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
os.chdir(root)
binary = Path(args.binary).resolve(strict=True)
result_path = Path(args.output)
result_path.parent.mkdir(parents=True, exist_ok=True)
report = {"platform": sys.platform, "video_driver": args.video_driver, "cases": [],
          "source_sha256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in sorted(Path("src").rglob("*")) if p.is_file()}}
environment = os.environ.copy()
environment["SDL_VIDEO_DRIVER"] = args.video_driver
environment["YEKK_TEST_TIMEOUT"] = "60"


def check(name, arguments, gui=False, expected=0, allocations=None):
    command = [str(binary), "--allocation-stats", "--decode-workers", "2", *map(str, arguments)]
    if gui:
        command = [sys.executable, "scripts/supervise.py", *command]
    started = time.monotonic()
    completed = subprocess.run(command, capture_output=True, text=True,
                               env=environment, timeout=70)
    case = {"name": name, "arguments": list(map(str, arguments)),
            "supervised": gui, "exit_code": completed.returncode,
            "elapsed_ms": (time.monotonic() - started) * 1000,
            "stdout": completed.stdout, "stderr": completed.stderr}
    report["cases"].append(case)
    result_path.write_text(json.dumps(report, indent=2) + "\n")
    if expected == 0:
        assert completed.returncode == 0, case
    else:
        assert completed.returncode != 0, case
    stats = re.search(r"allocations=(\d+), frees=(\d+), peak_bytes=(\d+), live_bytes=(\d+)", completed.stderr)
    assert stats and stats[1] == stats[2] and int(stats[4]) == 0, case
    if allocations is not None:
        pressure = re.search(r"pressure_events=(\d+)", completed.stderr)
        if name == "warm navigation and pan" and pressure and int(pressure[1]) > 0:
            case["warm_allocation_count_not_asserted"] = "OS pressure legitimately reclaimed history"
        else:
            assert int(stats[1]) == allocations, case
    print(f"{name}: passed ({case['elapsed_ms']:.0f} ms)", flush=True)
    return completed


with tempfile.TemporaryDirectory(prefix="yekk-linux-validation-") as temporary:
    folder = Path(temporary)
    environment.update(YEKK_CONFIG=str(folder / "absent-config"), XDG_CONFIG_HOME=str(folder))
    target = root / "tests/fixtures/alpha.content"
    special = folder / "film '$(exit 73)\n.png"
    special.symlink_to(target)
    listed = check("symlink operation path", ["--print-filelist", special], allocations=1)
    assert listed.stdout == str(special) + "\n"
    hook_output = folder / "hook-output"
    check("hook quoting", ["--smoke-hook-test", "-A",
                           "printf '%%s' %F > " + shlex.quote(str(hook_output)), special],
          gui=True, allocations=2)
    assert hook_output.read_text() == str(special)
    check("hook failure", ["--smoke-hook-test", "-A", "exit 7", target],
          gui=True, expected=1, allocations=2)
    for name in ["frame10.png", "frame2.png"]:
        (folder / name).symlink_to(target)
    listing = check("directory natural order", ["--print-filelist", folder])
    assert listing.stdout.index("frame2.png") < listing.stdout.index("frame10.png")
    check("software presentation", ["--software", "--smoke-test", "--snapshot", folder / "viewport.png", target],
          gui=True, allocations=2)
    assert (folder / "viewport.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    check("explicit reload", ["--smoke-reload-test", target], gui=True, allocations=3)
    check("GPU viewport pixels", ["--verify-gpu", "--smoke-test", "--zoom", "100", target], gui=True, allocations=2)
    check("viewport resize", ["--smoke-resize-test", "tests/fixtures/detail-wide.png"], gui=True, allocations=2)
    check("warm navigation and pan", ["--stress-test", args.cycles,
                                      "tests/fixtures/rgb16-orientation1.tif",
                                      "tests/fixtures/rgb16-orientation6.tif"], gui=True, allocations=3)
    check("damaged input", ["--smoke-test", "tests/fixtures/jpeg-incomplete-4.jpg"],
          gui=True, expected=1, allocations=1)
    check("unsupported option", ["--not-a-yekk-option", target], expected=1, allocations=1)
    check("headless 16-bit decode", ["--benchmark", "tests/fixtures/rgb16-tiled-big.tif"], allocations=2)
    # Source width exceeds common GPU texture limits while decoded storage is
    # small. Full images must not be constrained by a presentation texture size.
    wide = folder / "wide.png"
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data +
                struct.pack(">I", zlib.crc32(kind + data)))
    compressor = zlib.compressobj()
    row = b"\0" + bytes([16, 128, 240, 255]) * 70000
    compressed = b"".join(compressor.compress(row) for _ in range(64)) + compressor.flush()
    wide.write_bytes(b"\x89PNG\r\n\x1a\n" +
                     chunk(b"IHDR", struct.pack(">IIBBBBB", 70000, 64, 8, 6, 0, 0, 0)) +
                     chunk(b"IDAT", compressed) + chunk(b"IEND", b""))
    decoded = check("70000-pixel source width", ["--benchmark", wide], allocations=2)
    assert json.loads(decoded.stdout)["width"] == 70000
    check("wide source actual pixel pan", ["--zoom", "100", "--stress-test", "9", wide],
          gui=True, allocations=2)
    if args.image:
        check("full-size decode", ["--benchmark", args.image], allocations=2)
        check("full-size actual pixel pan", ["--zoom", "100", "--stress-test", "9", args.image],
              gui=True, allocations=2)
report["passed"] = True
result_path.write_text(json.dumps(report, indent=2) + "\n")
print(result_path)
