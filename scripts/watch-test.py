#!/usr/bin/env python3
"""Exercise atomic replacement and incomplete writes on owned temporary files."""
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time
import signal

root = Path(__file__).resolve().parent.parent
def check_replacement(incomplete):
    with tempfile.TemporaryDirectory(prefix="yekk-watch-", dir="/tmp") as directory:
        folder = Path(directory)
        first, second, live = [folder / name for name in ("first.png", "second.png", "live.png")]
        for path in (first, second, live):
            shutil.copyfile(root / "tests/fixtures/alpha.content", path)
        env = dict(os.environ, YEKK_CONFIG=str(folder / "no-config"))
        process = subprocess.Popen([sys.executable, str(root / "scripts/supervise.py"), "--relay",
                                   os.environ.get("YEKK_VIEWER", str(root / "zig-out/bin/yekk")), "--watch-test",
                                   str(first), str(second), str(live)],
                                  cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # The supervisor normally buffers output; select its live relay for this
        # explicit handshake test, while retaining its no-child/deadline guard.
        try:
            def wait_for(token):
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    if not select.select([process.stdout], [], [], 0.2)[0]:
                        continue
                    line = process.stdout.readline()
                    if not line:
                        raise RuntimeError("watch test exited before " + token)
                    print(line.decode().strip())
                    if token.encode() in line:
                        return
                raise TimeoutError(token)

            wait_for("WATCH_READY")
            replacement = folder / "replacement.png"
            shutil.copyfile(root / 'tests/fixtures' / incomplete, replacement)
            os.replace(replacement, live)
            wait_for("WATCH_RETAINED")
            shutil.copyfile(root / "tests/fixtures/gray16.png", replacement)
            os.replace(replacement, live)
            wait_for("WATCH_RECOVERED")
            _, errors = process.communicate(timeout=10)
            if process.returncode:
                raise RuntimeError(errors.decode())
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                process.communicate(timeout=10)

for incomplete in ('truncated.png', 'jpeg-incomplete-4.jpg', 'jpeg-incomplete-64.jpg'):
    check_replacement(incomplete)
