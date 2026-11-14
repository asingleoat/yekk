#!/usr/bin/env python3
"""Run Linux validation in a private, bounded, headless Weston compositor."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--parity", action="store_true", help="run the controls and file workflow suite")
parser.add_argument("--scale", type=int, choices=[1,2], default=1, help="private compositor output scale")
args, forwarded = parser.parse_known_args()
suite = "linux-parity-test.py" if args.parity else "linux-validation.py"
output = "dist/linux-wayland-parity.json" if args.parity else "dist/linux-wayland-validation.json"

with tempfile.TemporaryDirectory(prefix="yekk-wayland-") as temporary:
    runtime = Path(temporary)
    environment = os.environ.copy()
    environment.update(XDG_RUNTIME_DIR=str(runtime), WAYLAND_DISPLAY="yekk-test", SDL_VIDEO_DRIVER="wayland")
    environment["YEKK_TEST_COMPOSITOR_SCALE"] = str(args.scale)
    with (runtime / "weston.log").open("w+") as log:
        compositor = subprocess.Popen(["weston", "--backend=headless", "--renderer=pixman",
                                       "--socket=yekk-test", "--idle-time=0", "--no-config", "--fake-seat", f"--scale={args.scale}"],
                                      env=environment, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 15
            while not (runtime / "yekk-test").exists():
                if compositor.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise RuntimeError("private compositor failed:\n" + log.read())
                time.sleep(0.05)
            completed = subprocess.run([sys.executable, str(Path(__file__).with_name(suite)),
                                        "--video-driver", "wayland", "--output", output,
                                        *forwarded], env=environment, timeout=300)
            if completed.returncode:
                raise SystemExit(completed.returncode)
        finally:
            try:
                os.killpg(compositor.pid, signal.SIGTERM)
                compositor.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(compositor.pid, signal.SIGKILL)
                compositor.wait(timeout=5)
            except ProcessLookupError:
                pass
