#!/usr/bin/env python3
"""Bound a GUI test and fail immediately if Yekk launches a Yekk child.

Each test gets a separate process group. Termination is limited to that group;
Explicit command hooks may create their own child groups; those are tracked
and cleaned up as well. Existing user instances are never included.
"""
import os
import signal
import selectors
import shutil
import subprocess
import sys
import time

arguments = sys.argv[1:]
relay = bool(arguments and arguments[0] == "--relay")
if relay:
    arguments.pop(0)
if not arguments:
    raise SystemExit("usage: supervise.py EXECUTABLE [ARGS...]")
executable = os.path.realpath(arguments[0])
# Nix launchers exec a hidden native binary in the same PID. Recognise both
# names, and learn the native inode without ever treating its shell as Yekk.
program_names = {os.path.basename(executable), "." + os.path.basename(executable) + "-wrapped"}
program_files = set()
program_arguments = {executable, os.path.join(os.path.dirname(executable), 'libexec', 'yekk')}
ps = shutil.which("ps")
if ps is None:
    raise SystemExit("supervise.py requires ps in PATH")
deadline = time.monotonic() + float(os.environ.get("YEKK_TEST_TIMEOUT", "30"))
owned_groups = set()
process = subprocess.Popen(arguments, start_new_session=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)

owned_groups.add(process.pid)

def stop_group():
    for group in owned_groups:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass

def check_children():
    if sys.platform.startswith("linux"):
        try:
            native = os.path.realpath(f"/proc/{process.pid}/exe")
            if os.path.basename(native) in program_names:
                stat = os.stat(native)
                program_files.add((stat.st_dev, stat.st_ino))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            pass
    rows = subprocess.check_output([ps, "-axo", "pid=,ppid=,pgid=,comm="], text=True)
    processes = {}
    for row in rows.splitlines():
        fields = row.strip().split(None, 3)
        if len(fields) == 4:
            processes[int(fields[0])] = (int(fields[1]), int(fields[2]), fields[3])
    descendants = {process.pid}
    while True:
        found = {pid for pid, (parent, _, _) in processes.items() if parent in descendants}
        if found <= descendants:
            break
        descendants.update(found)
    for pid in descendants - {process.pid}:
        _, group, command = processes[pid]
        if group in descendants:
            owned_groups.add(group)
        if sys.platform.startswith("linux"):
            try:
                with open(f'/proc/{pid}/stat') as stream:
                    flags = int(stream.read().rsplit(')', 1)[1].split()[6])
                # PF_FORKNOEXEC identifies the parent's image before exec.
                # GIO's launch helper briefly has Yekk's executable too; only
                # a newly executed copy is a recursive viewer instance.
                # Linux include/linux/sched.h defines this flag as 0x40.
                if flags & 0x40:
                    continue
            except (FileNotFoundError, ProcessLookupError, PermissionError, IndexError, ValueError):
                pass
        same_program = (os.path.realpath(command) == executable or
                        os.path.basename(command) in program_names)
        if sys.platform.startswith("linux"):
            try:
                stat = os.stat(f"/proc/{pid}/exe")
                same_program = same_program or (stat.st_dev, stat.st_ino) in program_files
                native = os.path.realpath(f"/proc/{pid}/exe")
                if os.path.basename(native).startswith('ld-linux-'):
                    # The relocatable release invokes its bundled loader. In
                    # that case /proc/PID/exe names the loader, not the viewer.
                    with open(f'/proc/{pid}/cmdline', 'rb') as stream:
                        command_arguments = stream.read().split(b'\0')
                    same_program = same_program or any(
                        os.path.realpath(os.fsdecode(arg)) in program_arguments
                        for arg in command_arguments[1:] if arg.startswith(b'/'))
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass
        if same_program:
            raise RuntimeError(f"Yekk spawned another Yekk process ({pid}); regression blocked")

try:
    if relay:
        streams = selectors.DefaultSelector()
        streams.register(process.stdout, selectors.EVENT_READ, sys.stdout.buffer)
        streams.register(process.stderr, selectors.EVENT_READ, sys.stderr.buffer)
        while streams.get_map():
            check_children()
            if time.monotonic() >= deadline:
                raise TimeoutError("GUI test exceeded its deadline")
            for key, _ in streams.select(timeout=0.1):
                data = os.read(key.fileobj.fileno(), 65536)
                if data:
                    key.data.write(data)
                    key.data.flush()
                else:
                    streams.unregister(key.fileobj)
        check_children()
        raise SystemExit(process.wait(timeout=1))
    while True:
        check_children()
        if time.monotonic() >= deadline:
            raise TimeoutError("GUI test exceeded its deadline")
        try:
            out, err = process.communicate(timeout=0.1)
            check_children()
            sys.stdout.buffer.write(out)
            sys.stderr.buffer.write(err)
            raise SystemExit(process.returncode)
        except subprocess.TimeoutExpired:
            pass
except (RuntimeError, TimeoutError, KeyboardInterrupt) as error:
    stop_group()
    out, err = process.communicate()
    sys.stdout.buffer.write(out)
    sys.stderr.buffer.write(err)
    print(error, file=sys.stderr)
    raise SystemExit(1)
