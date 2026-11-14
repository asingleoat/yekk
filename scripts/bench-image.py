#!/usr/bin/env python3
"""Repeat a single read-only image benchmark in fresh, deadline-bound processes."""
import argparse
import datetime
import contextlib
import ctypes
import tempfile
import json
import hashlib
import os
import platform
from pathlib import Path
import signal
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("image", type=Path)
parser.add_argument("--executable", type=Path, default=Path("zig-out/bin/yekk-bench-image"))
parser.add_argument("--repeats", type=int, default=5)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--label", default="baseline")
parser.add_argument("--poison", action="store_true", help="include the redundant safe-build full-allocation initialization for comparison")
parser.add_argument("--workers", type=int, default=1)
parser.add_argument("--fresh-clone", action="store_true", help="use a new temporary APFS clone inode for every measurement; verify disk-read accounting")
parser.add_argument("--no-cache", action="store_true", help="also measure per-descriptor F_NOCACHE reads/decodes")
args = parser.parse_args()
if args.workers < 1:
    parser.error("workers must be positive")
if not 1 <= args.repeats <= 100:
    parser.error("repeats must be between 1 and 100")
image = args.image.expanduser().resolve(strict=True)
executable = args.executable.resolve(strict=True)
stat = image.stat()

def command_text(command):
    return subprocess.check_output(command, text=True, timeout=10).strip()

metadata = {
    "kind": "metadata", "label": args.label,
    "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "input_name": image.name, "input_bytes": stat.st_size,
    "input_mtime_ns": stat.st_mtime_ns,
    "executable": os.path.relpath(executable, Path.cwd()),
    "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
    "poison_allocation": args.poison, "fresh_clone": args.fresh_clone,
    "os": platform.platform(), "machine": platform.machine(),
    "cpu": command_text(["sysctl", "-n", "machdep.cpu.brand_string"]),
    "physical_memory_bytes": int(command_text(["sysctl", "-n", "hw.memsize"])),
    "repeats": args.repeats, "workers": args.workers,
    "conditions": "Each measurement reads a fresh-inode temporary APFS clone; source blocks are shared copy-on-write. Disk-read accounting verifies file data was read. Device caches are not flushed." if args.fresh_clone else "Fresh processes; warm decode preceded by full sequential read. F_NOCACHE is per descriptor, not a machine-wide cache flush or guaranteed storage-cold run. No concurrent benchmark jobs.",
}
@contextlib.contextmanager
def input_file():
    if not args.fresh_clone:
        yield image
        return
    library = ctypes.CDLL(None, use_errno=True)
    library.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    library.clonefile.restype = ctypes.c_int
    with tempfile.TemporaryDirectory(prefix="yekk-bench-clone-", dir="/tmp") as folder:
        target = Path(folder) / image.name
        if library.clonefile(os.fsencode(image), os.fsencode(target), 0):
            raise OSError(ctypes.get_errno(), "clonefile failed")
        if target.stat().st_ino == stat.st_ino:
            raise RuntimeError("clone did not produce a fresh inode")
        yield target

args.output.parent.mkdir(parents=True, exist_ok=True)
# Refuse to overwrite previous evidence.
with args.output.open("x") as output:
    def save(record):
        output.write(json.dumps(record, sort_keys=True) + "\n")
        output.flush()
    save(metadata)
    results = []
    for repeat in range(args.repeats):
        modes = [("read", False), ("decode", False)]
        if args.fresh_clone:
            modes = [("read", args.no_cache), ("decode", args.no_cache)]
        elif args.no_cache:
            modes += [("read", True), ("decode", True)]
        for mode, no_cache in modes:
            with input_file() as measured_input:
                command = [str(executable), mode, str(measured_input)]
                if mode == "decode":
                    command += ["--workers", str(args.workers)]
                    if args.poison:
                        command.append("--poison")
                if no_cache:
                    command.append("--no-cache")
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, start_new_session=True)
                try:
                    stdout, stderr = process.communicate(timeout=120)
                except BaseException:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate()
                    raise
            if process.returncode:
                raise RuntimeError(f"benchmark failed ({process.returncode}): {stderr}")
            record = json.loads(stdout)
            record.update(kind="measurement", repeat=repeat, label=args.label)
            # First cached read establishes a warm decode; later reads should be warm.
            record["warmup"] = not args.fresh_clone and repeat == 0 and mode == "read" and not no_cache
            record["storage_io_verified"] = record["disk_counter_available"] and record["disk_read_bytes"] >= stat.st_size * 0.95
            if args.fresh_clone and not record["storage_io_verified"]:
                save(record)
                raise RuntimeError("fresh clone did not register sufficient disk reads; refusing to label it a storage measurement")
            if stderr:
                record["stderr"] = stderr
            save(record)
            results.append(record)
            print(f"{args.label} {mode} nocache={no_cache} {record['wall_ms']:.3f} ms", flush=True)
    checksums = {r["checksum"] for r in results if r["mode"] == "decode"}
    if len(checksums) != 1:
        raise RuntimeError("decoded output changed between repetitions/cache modes")
    if image.stat().st_mtime_ns != stat.st_mtime_ns or image.stat().st_size != stat.st_size or image.stat().st_ino != stat.st_ino or image.stat().st_ctime_ns != stat.st_ctime_ns:
        raise RuntimeError("input changed during the experiment")
    for mode, no_cache in [("read", False), ("decode", False), ("read", True), ("decode", True)]:
        samples = [r for r in results if r["mode"] == mode and r["no_cache"] == no_cache and not r["warmup"]]
        if not samples:
            continue
        keys = ["wall_ms", "metadata_ms", "allocation_ms", "decode_wall_ms", "blocks_ms", "conversion_ms", "native_ms", "user_ms", "system_ms", "disk_read_bytes", "peak_rss_bytes"]
        summary = {key: statistics.median(r[key] for r in samples) for key in keys if key in samples[0]}
        summary.update(kind="summary", label=args.label, mode=mode, no_cache=no_cache, samples=len(samples), statistic="median")
        summary["min_wall_ms"] = min(r["wall_ms"] for r in samples)
        summary["max_wall_ms"] = max(r["wall_ms"] for r in samples)
        save(summary)
        print(json.dumps(summary, sort_keys=True), flush=True)
