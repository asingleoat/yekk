#!/usr/bin/env python3
"""Functional parity checks; no assertions about throughput or latency."""
import argparse
import itertools
import hashlib
import json
import os
from pathlib import Path
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", default="zig-out/bin/yekk")
parser.add_argument("--output", default="dist/linux-parity.json")
parser.add_argument("--video-driver", default=os.environ.get("SDL_VIDEO_DRIVER", "dummy"))
parser.add_argument("--fixture", type=Path, help="use a prebuilt linux-file-manager-test executable")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
os.chdir(root)
binary = Path(args.binary).resolve(strict=True)
report = {"video_driver": args.video_driver, "binary": str(binary),
          "compositor_scale": os.environ.get("YEKK_TEST_COMPOSITOR_SCALE"),
          "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "cases": [],
          "source_sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in sorted(Path("src").rglob("*")) if path.is_file()},
          "validation_sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in [Path(__file__).relative_to(root), Path("scripts/linux-file-manager-test.zig"), Path("flake.lock")]}}
output = Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, SDL_VIDEO_DRIVER=args.video_driver, SDL_RENDER_DRIVER="software", YEKK_TEST_TIMEOUT="90")


def record(name, result, expected=0):
    case = dict(name=name, status=result.returncode, stdout=result.stdout, stderr=result.stderr)
    report["cases"].append(case)
    output.write_text(json.dumps(report, indent=2) + "\n")
    assert result.returncode == expected, case
    assert "live_bytes=0" in result.stderr, case
    print(name + ": passed", flush=True)
    return result


def command(arguments, gui=False):
    result = [str(binary), "--alloc-stats", "--decode-workers", "2", "--no-prefetch", *map(str, arguments)]
    return [sys.executable, "scripts/supervise.py", *result] if gui else result


def check(name, arguments, gui=False, expected=0, stdin=None):
    result = subprocess.run(command(arguments, gui), env=environment, input=stdin,
                            capture_output=True, text=True, timeout=100)
    return record(name, result, expected)


def views(result):
    return [dict(field.split("=", 1) for field in line.split()[1:])
            for line in result.stdout.splitlines() if line.startswith("VIEW ")]


def interact(name, arguments, callback):
    argv = command(arguments, gui=True)
    argv.insert(2, "--relay")
    process = subprocess.Popen(argv, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    streams = selectors.DefaultSelector()
    streams.register(process.stdout, selectors.EVENT_READ, "stdout")
    streams.register(process.stderr, selectors.EVENT_READ, "stderr")
    captured = {"stdout": bytearray(), "stderr": bytearray()}
    try:
        deadline = time.monotonic() + 90
        while streams.get_map():
            if time.monotonic() > deadline:
                raise TimeoutError(name + " did not complete")
            for key, _ in streams.select(0.1):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    streams.unregister(key.fileobj)
                    continue
                captured[key.data].extend(data)
                callback(captured["stdout"].decode())
        result = subprocess.CompletedProcess(argv, process.wait(timeout=5),
                                             captured["stdout"].decode(), captured["stderr"].decode())
        return record(name, result)
    finally:
        streams.close()
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                # These are only the children of this test's supervisor. GUI
                # applications have their own process groups, never a user's.
                children = Path(f"/proc/{process.pid}/task/{process.pid}/children")
                for pid in children.read_text().split() if children.exists() else []:
                    try:
                        if os.getpgid(int(pid)) == int(pid):
                            os.killpg(int(pid), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.kill()
                process.communicate(timeout=5)


with tempfile.TemporaryDirectory(prefix="yekk-linux-parity-") as temporary:
    folder = Path(temporary)
    environment.update(YEKK_CONFIG=str(folder / "absent-config"), XDG_CONFIG_HOME=str(folder), XDG_DATA_HOME=str(folder / "data"), YEKK_TEST_DESKTOP_ROOT=str(folder))
    first = root / "tests/fixtures/rgb16-orientation1.tif"
    second = root / "tests/fixtures/rgb16-orientation6.tif"
    config = folder / "config"
    config.write_text("fit = actual\nbind n = previous\n")
    result = check("config and CLI precedence", ["--config", config, "--zoom", "50", "--trace-events", "--test-keys", "n", first, second], gui=True)
    rows = views(result)
    debug_allocator = "debug=true" in result.stderr
    assert [identity for identity, _ in itertools.groupby(row["id"] for row in rows)] == ["0", "1"]
    assert all(float(row["scale"]) == 0.5 for row in rows)
    for flags in [['-Z'], ['-.'], ['-Z','-.'], ['-.','-Z']]:
        result = check('feh initial zoom ' + ' '.join(flags), [*flags, '--geometry', '900x600', '--trace-events', '--smoke-test', first], gui=True)
        row = views(result)[0]
        expected = 1 if flags == ['-.'] else min(int(row['viewport_width']) / int(row['width']), int(row['viewport_height']) / int(row['height']))
        assert abs(float(row['scale']) - expected) < 0.00001, result.stdout
    result = check('keep zoom freezes the resolved automatic scale across navigation', ['-Z', '--keep-zoom-vp', '--geometry', '900x600', '--trace-events', '--test-keys', 'Right,Left', first, second], gui=True)
    rows = views(result)
    assert [identity for identity, _ in itertools.groupby(row['id'] for row in rows)] == ['0','1','0'], result.stdout
    assert all(row['scale'] == rows[0]['scale'] for row in rows), result.stdout
    for flags in [[], ['--keep-zoom-vp']]:
        result = check('manual zoom navigation ' + ' '.join(flags), ['--zoom','100',*flags,'--trace-events','--test-keys','Up,Right,Left',first,second], gui=True)
        rows = views(result)
        states = [state for state, _ in itertools.groupby((row['id'], float(row['scale'])) for row in rows)]
        retained = 1.25 if flags else 1
        assert states == [('0',1),('0',1.25),('1',retained),('0',retained)], result.stdout
    keys = folder / "keys"
    keys.write_text("next_img C-k\n")
    result = check("feh keys replace defaults and preserve modifiers", ["--keys", keys, "--trace-events", "--test-keys", "n,C-k", first, second], gui=True)
    assert sum(line.startswith("KEY ") for line in result.stdout.splitlines()) == 2
    assert [identity for identity, _ in itertools.groupby(row["id"] for row in views(result))] == ["0", "1"]
    bad = folder / "bad-config"
    bad.write_text("unknown = true\n")
    result = check("invalid config is reported", ["--config", bad, first], expected=2)
    assert result.returncode == 2 and f"{bad}:1:" in result.stderr
    result = check("explicit missing keys is reported", ["--keys", folder / "missing", first], expected=2)
    assert result.returncode == 2
    result = check("explicit missing config is reported", ["--config", folder / "missing-config", first], expected=2)
    assert result.returncode == 2
    result = check("unknown options return usage status", ["--unsupported-yekk-option", first], expected=2)
    assert result.returncode == 2
    result = check("metadata list reads oriented headers", ["--list", second])
    columns = result.stdout.splitlines()[1].split("\t")
    assert columns[2:4] == ["2", "3"] and "allocations=1," in result.stderr
    result = check("runtime decoder format listing", ["--formats"])
    assert ".png" in result.stdout.splitlines()
    result = check("stdin filelist", ["--print-filelist", "-f", "-"], stdin=f"{first}\r\n\r\n{second}\n")
    assert result.stdout == f"{first}\n{second}\n"
    listing = folder / "images.txt"
    listing.write_text(f"{first}\n{second}\n")
    result = check("remove edits the filelist without deleting sources", ["-f", listing, "--trace-events", "--test-keys", "Delete"], gui=True)
    assert listing.read_text() == f"{second}\n" and first.exists() and second.exists()
    assert views(result)[-1]["id"] == "1" and views(result)[-1]["count"] == "1"
    export_dir = folder / "save here"
    export_dir.mkdir()
    check("save active filelist from a regular session", [
        "-j", export_dir, "--test-keys", "Delete,L", first, second,
    ], gui=True)
    [exported] = export_dir.glob("feh_*_000001_filelist")
    assert exported.read_text() == f"{second}\n" and first.exists() and second.exists()
    assert check("reopen exported filelist", ["-f", exported, "--print-filelist"]).stdout == f"{second}\n"
    edit_source = folder / "edit-source.jpg"
    check("generate a JPEG with whole transform blocks", [
        "-m", "-W32", "-H16", "-y32", "-E16", "-sX", "-O", edit_source, first,
    ])
    result = check("rotate a JPEG in place", ["--edit", "--trace-events", "--test-keys", "greater", edit_source], gui=True)
    assert check("read the edited JPEG", ["-L", "%w %h", edit_source]).stdout == "16 32\n"
    check("save the displayed transform as a copy", [
        "-j", export_dir, "--test-keys", "greater,s", edit_source,
    ], gui=True)
    [rotated_copy] = export_dir.glob("feh_*_edit-source.jpg")
    assert check("read the saved copy", ["-L", "%w %h", rotated_copy]).stdout == "32 16\n"
    result = check("failed filelist export reports the error and leaves the viewer usable", [
        "--output-dir", export_dir / "missing", "--trace-events", "--test-keys", "L,n", first, second,
    ], gui=True)
    assert "could not save file list" in result.stderr and views(result)[-1]["id"] == "1"
    listing.write_text(f"{first}\n")
    special = folder / "photo\n雪.png"
    special.symlink_to(root / "tests/fixtures/alpha.content")
    check("unrepresentable filelist preserves original", ["-f", listing, "--smoke-test", special], gui=True, expected=1)
    assert listing.read_text() == f"{first}\n"
    carriage = folder / "photo\r"
    carriage.symlink_to(root / "tests/fixtures/alpha.content")
    check("CRLF-ambiguous path preserves original filelist", ["-f", listing, "--print-filelist", carriage], expected=1)
    assert listing.read_text() == f"{first}\n"
    duplicate_paths = [folder / name / "same.tif" for name in ("a", "b")]
    for source, duplicate in zip((first, second), duplicate_paths):
        duplicate.parent.mkdir()
        shutil.copyfile(source, duplicate)
    relative_first = os.path.relpath(duplicate_paths[0], root)
    relative_second = os.path.relpath(duplicate_paths[1], root)
    for start, selected in [(relative_second, "1"), (str(duplicate_paths[1]), "0")]:
        result = check("start-at exact spelling then basename fallback " + selected,
                       ["--start-at", start, "--trace-events", "--smoke-test", relative_first, relative_second], gui=True)
        assert views(result)[0]["id"] == selected, result.stdout
    result = check("standalone start-at browses siblings", ["--start-at", second, "--print-filelist"])
    assert str(first) in result.stdout and str(second) in result.stdout
    result = check("nonwrapping navigation", ["--no-wrap", "--trace-events", "--test-keys", "Left,Right,Right", first, second], gui=True)
    # Compositors can add expose frames or coalesce a no-op at an endpoint.
    # Verify all input was dispatched and selection never wraps, independently
    # of how many times an unchanged image was presented.
    assert sum(line.startswith("KEY ") for line in result.stdout.splitlines()) == 3
    assert [identity for identity, _ in itertools.groupby(row["id"] for row in views(result))] == ["0", "1"]
    result = check("shared transforms and overlays", ["-g", "640x480-0+0", "-Gd", "--trace-events", "--test-keys", "greater,bar,underscore,question,question,i,i,A,A,asterisk", first], gui=True)
    transforms = [state for state, _ in itertools.groupby((row["rotation"], row["mirror"]) for row in views(result))]
    assert transforms[:4] == [("0", "0"), ("1", "0"), ("1", "1"), ("1", "3")]
    result = check("slideshow ends after displayed slides", ["-D", "0.03", "--on-last-slide", "quit", "--trace-events", first, second], gui=True)
    # Configure/expose events may present the same slide again. Check actual
    # selection transitions, not the compositor's number of presentations.
    assert [identity for identity, _ in itertools.groupby(row["id"] for row in views(result))] == ["0", "1"]
    result = check("negative slideshow starts paused", ["-D", "-0.03", "--trace-events", "--test-keys", "asterisk", first, second], gui=True)
    assert all(row["id"] == "0" and row["playing"] == "false" for row in views(result))
    if debug_allocator:
        result = check("allocation failure reclaims history and retries once", ["--recovery-test", first, second], gui=True)
        assert "RECOVERY_PASSED" in result.stdout and "allocation_retries=1" in result.stderr
    if debug_allocator:
        result = check("native viewport allocation failure reclaims and retries retained pixels", ["--native-recovery-test", first], gui=True)
        assert "NATIVE_RECOVERY_PASSED" in result.stdout and "native_retries=1" in result.stderr and "decodes=1," in result.stderr
    result = check("independent windows survive close, reuse, late callbacks and capacity", ["--window-test", second, first], gui=True)
    assert "WINDOWS_PASSED" in result.stdout
    result = check("dropped file asynchronously replaces session", ["--test-open", second, "--trace-events", first], gui=True)
    assert "OPEN_PRESENTED" in result.stdout and views(result)[-1]["width"] == "2" and views(result)[-1]["height"] == "3"
    check("invalid replacement reports error and retires previous session", ["--test-open", folder / "missing.png", first], gui=True, expected=1)
    drop_folder = folder / "drop-folder"
    drop_folder.mkdir()
    (drop_folder / "first.tif").symlink_to(first)
    (drop_folder / "second.tif").symlink_to(second)
    result = check("dropped directory indexes a replacement list", ["--test-open", drop_folder, "--trace-events", first], gui=True)
    assert "OPEN_PRESENTED" in result.stdout and int(views(result)[-1]["count"]) >= 2
    listing.write_text(f"{first}\n{second}\n")
    check("replacement saves original filelist without adopting new inputs", ["-f", listing, "--test-open", special], gui=True)
    assert listing.read_text() == f"{first}\n{second}\n"
    trash_source = folder / "trash-source.tif"
    trash_source.symlink_to(first)
    check("Trash cancellation keeps source", ["--test-keys", "C-Delete,Escape", trash_source, second], gui=True)
    assert trash_source.is_symlink()
    result = check("confirmed Trash removes symlink without touching target", ["--trace-events", "--test-keys", "C-Delete,Return", trash_source, second], gui=True)
    assert not trash_source.is_symlink() and first.exists() and views(result)[-1]["count"] == "1"
    trashed = list((folder / "data/Trash/files").glob("trash-source*"))
    assert len(trashed) == 1 and trashed[0].is_symlink()
    desktop_keys = folder / "desktop-keys"
    desktop_keys.write_text("external e\nreveal v\n")
    appdir = folder / "data/applications"
    appdir.mkdir(parents=True, exist_ok=True)
    external_output = folder / "external-argument"
    helper = folder / "record-open"
    helper.write_text("#!/bin/sh\nprintf '%s' \"$1\" > " + shlex.quote(str(external_output)) + "\n")
    helper.chmod(0o700)
    desktop = appdir / "yekk-test.desktop"
    desktop.write_text(f"[Desktop Entry]\nType=Application\nName=Yekk isolated test handler\nExec={helper} %f\nMimeType=image/tiff;image/png;\n")
    (folder / "mimeapps.list").write_text("[Default Applications]\nimage/tiff=yekk-test.desktop\nimage/png=yekk-test.desktop\n")
    check("external handler receives literal Unicode and newline path", ["--keys", desktop_keys, "--test-keys", "e", special], gui=True)
    deadline = time.monotonic() + 10
    while not external_output.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert external_output.read_text() == str(special)
    desktop.write_text(f"[Desktop Entry]\nType=Application\nName=Self handler test\nExec={binary} %f\nMimeType=image/tiff;image/png;\n")
    # Permit the chosen executable through the fixture's safety restriction so
    # this case proves the application's self-handler check rejected it.
    environment["YEKK_TEST_DESKTOP_ROOT"] = str(binary.parent)
    result = check("external handler rejects Yekk recursion", ["--keys", desktop_keys, "--test-keys", "e", special], gui=True, expected=1)
    assert "external open refused: self handler" in result.stderr
    assert "Yekk spawned another Yekk process" not in result.stderr
    native_binary = binary.parent / 'libexec/yekk'
    if native_binary.is_file():
        desktop.write_text(f"[Desktop Entry]\nType=Application\nName=Native self handler test\nExec={native_binary} %f\nMimeType=image/tiff;image/png;\n")
        environment["YEKK_TEST_DESKTOP_ROOT"] = str(native_binary.parent)
        result = check("portable loader rejects native executable recursion", ["--keys", desktop_keys, "--test-keys", "e", special], gui=True, expected=1)
        assert "external open refused: self handler" in result.stderr
        assert "Yekk spawned another Yekk process" not in result.stderr
    environment["YEKK_TEST_DESKTOP_ROOT"] = str(folder)
    # The service and bus are private to this test; never activate the desktop's
    # real file manager. Compile against the same locked GIO as the viewer.
    if args.fixture:
        manager = args.fixture.resolve(strict=True)
    else:
        subprocess.run(["zig", "build", "build-linux-fixtures", "-Dtest-desktop=true", "-Doptimize=ReleaseSafe", "-j2"], check=True)
        manager = root / "zig-out/bin/linux-file-manager-test"
    from private_bus import start_private_bus
    bus = start_private_bus(folder, environment)
    service = None
    old_address = environment.get("DBUS_SESSION_BUS_ADDRESS")
    def read_handshake(process, expected=None):
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        data = bytearray()
        deadline = time.monotonic() + 10
        try:
            while b"\n" not in data:
                if time.monotonic() > deadline:
                    raise TimeoutError("private D-Bus fixture did not start")
                if selector.select(0.1):
                    chunk = os.read(process.stdout.fileno(), 4096)
                    if not chunk:
                        raise RuntimeError("private D-Bus fixture exited before handshake")
                    data.extend(chunk)
        finally:
            selector.close()
        value = data.decode().strip()
        assert expected is None or value == expected, value
        return value
    try:
        environment["DBUS_SESSION_BUS_ADDRESS"] = read_handshake(bus)
        service = subprocess.Popen([str(manager), str(special)], env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        read_handshake(service, "READY")
        check("reveal uses FileManager1 with literal escaped file URI", ["--keys", desktop_keys, "--test-keys", "v", special], gui=True)
        stdout, stderr = service.communicate(timeout=10)
        assert service.returncode == 0 and b"REVEALED" in stdout, (stdout, stderr)
        wallpaper = manager.with_name("linux-wallpaper-test")
        if not args.fixture or wallpaper.is_file():
            for mode in ("center", "fill", "max", "scale", "tile"):
                service = subprocess.Popen([str(wallpaper)], env=environment, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
                read_handshake(service, "READY")
                check(f"wallpaper {mode} sends a PNG to the private portal", [f"--bg-{mode}", first])
                stdout, stderr = service.communicate(timeout=10)
                assert service.returncode == 0, (stdout, stderr)
    finally:
        if old_address is None:
            environment.pop("DBUS_SESSION_BUS_ADDRESS", None)
        else:
            environment["DBUS_SESSION_BUS_ADDRESS"] = old_address
        for child in [service, bus]:
            if child is not None and child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                child.communicate(timeout=5)
    result = check("size-to-image uses drawable pixels", ["--zoom", "100", "--trace-events", "--test-keys", "w,w", root / "tests/fixtures/detail-wide.png"], gui=True)
    assert views(result)[-1]["viewport_height"] == "128", result.stdout
    if os.environ.get("YEKK_TEST_COMPOSITOR_SCALE"):
        assert float(views(result)[-1]["pixel_density"]) == int(os.environ["YEKK_TEST_COMPOSITOR_SCALE"]),result.stdout
    result = check("action menu invokes actual size and dismisses without quitting", ["--zoom", "50", "--trace-events", "--test-keys", "m,Return,m,Escape", first], gui=True)
    assert float(views(result)[-1]["scale"]) == 1
    check("HDR input is rejected", ["--benchmark", root / "tests/fixtures/linear-hdr.hdr"], expected=1)
    coordinates = folder / "hook-coordinates"
    coordinate_command = "printf '%%s\\n' %g %w %h %z %o > " + shlex.quote(str(coordinates))
    for name, image, zoom, keys, pan in [
        ('centered', first, '100', 'Return', (0, 0)),
        ('zoomed', first, '150', 'Return', (0, 0)),
        ('panned', root / 'tests/fixtures/detail-wide.png', '2000', 'C-Right,C-Down,Return', (-64, -64)),
    ]:
        check('hook image coordinates ' + name, ['--geometry', '960x640', '--zoom', zoom,
              '-A', coordinate_command, '--test-keys', keys, image], gui=True)
        viewport, width, height, reported_zoom, origin = coordinates.read_text().splitlines()
        vw, vh = map(int, viewport.split(','))
        x, y = map(int, origin.split(','))
        scale = float(reported_zoom)
        assert abs(x - ((vw - int(width) * scale) / 2 + pan[0])) <= 0.5, name
        assert abs(y - ((vh - int(height) * scale) / 2 + pan[1])) <= 0.5, name
    hook_output = folder / "hook"
    hook = "printf '%%s' %F > " + shlex.quote(str(hook_output))
    result = check("successful hook advances", ["-A", hook, "--trace-events", "--test-keys", "Return", first, second], gui=True)
    assert hook_output.read_text() == str(first) and views(result)[-1]["id"] == "1"
    gate = folder / "complete-hook"
    def complete_after_navigation(text):
        if any("id=1 " in line for line in text.splitlines() if line.startswith("VIEW ")):
            gate.touch()
    waiting_hook = "while [ ! -e " + shlex.quote(str(gate)) + " ]; do sleep 0.02; done; " + hook
    result = interact("hook completion does not disturb subsequent navigation",
                      ["-A", waiting_hook, "--trace-events", "--test-keys", "Return,n", first, second,
                       root / "tests/fixtures/gray16.png"], complete_after_navigation)
    assert hook_output.read_text() == str(first) and views(result)[-1]["id"] == "1"
    manifest_copy = folder / "manifest-copy"
    manifest_name = folder / "manifest-name"
    hook = "printf '%%s' %L > " + shlex.quote(str(manifest_name)) + "; cat %L > " + shlex.quote(str(manifest_copy))
    check("hook manifest has snapshot order and is cleaned up", ["-A", hook, "--smoke-hook-test", first, second], gui=True)
    assert manifest_copy.read_text() == f"{first}\n{second}\n" and not Path(manifest_name.read_text()).exists()
    check("unsafe hook specifier fails without running shell", ["-A", "printf %f", "--smoke-hook-test", first], gui=True, expected=1)
    moving = folder / "move-me.tif"
    moved = folder / "moved.tif"
    shutil.copyfile(first, moving)
    result = check("triage removes moved source from active order", ["-A", "mv -n %F " + shlex.quote(str(moved)), "--trace-events", "--test-keys", "Return", moving, second], gui=True)
    assert moved.exists() and not moving.exists() and views(result)[-1]["count"] == "1"

    # A controlled partial write must retain old pixels, then adopt the completed
    # replacement. No polling deadline asserts decode speed on a busy machine.
    watched = folder / "watch.png"
    shutil.copyfile(root / "tests/fixtures/alpha.content", watched)
    phase = [0]
    def replace_source(text):
        if phase[0] == 0 and "WATCH_READY" in text:
            watched.write_bytes(b"\x89PNG\r\n\x1a\n")
            phase[0] = 1
        elif phase[0] == 1 and "WATCH_RETAINED" in text:
            replacement = folder / "replacement"
            shutil.copyfile(second, replacement)
            replacement.replace(watched)
            phase[0] = 2
    result = interact("watch retains partial replacements and recovers",
                      ["--watch-test", "--trace-events", watched], replace_source)
    assert "WATCH_RECOVERED" in result.stdout and phase[0] == 2
    assert views(result)[-1]["width"] == "2" and views(result)[-1]["height"] == "3"

report["passed"] = True
output.write_text(json.dumps(report, indent=2) + "\n")
print(output)
