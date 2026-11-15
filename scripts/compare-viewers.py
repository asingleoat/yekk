#!/usr/bin/env python3
"""Compare real viewer window readiness on an owned, private X11 display."""

import argparse
import csv
import hashlib
import itertools
import json
import math
import os
import pathlib
import random
import selectors
import signal
import subprocess
import sys
import tempfile
import time


def chart(source, output):
    """Render the published six-run TIFF/JPEG report."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Patch

    matplotlib.rcParams.update(
        {"svg.fonttype": "none", "svg.hashsalt": "yekk-viewers", "font.size": 10}
    )
    with source.open() as stream:
        rows = list(csv.DictReader(stream))
    viewers = [("yekk", "Yekk"), ("feh", "feh"), ("imv", "imv")]
    phases = [
        (range(0, 3), "Open + inspect 1 photo", "#1466a3"),
        (range(3, 9), "Advance + inspect 2 photos", "#b45415"),
        (range(9, 14), "Return + inspect 2 photos", "#28774e"),
    ]
    fig, axes = plt.subplots(
        2, 2, figsize=(10, 6.6), gridspec_kw={"width_ratios": [3.4, 1]}
    )
    for (dataset, title), (timing, memory) in zip(
        [("tiff", "239 MP TIFF scans"), ("jpeg", "23–24 MP JPEG copies")], axes
    ):
        subset = [r for r in rows if r["dataset"] == dataset]
        for y, (viewer, label) in enumerate(viewers):
            runs = [
                [r for r in subset if r["viewer"] == viewer and r["trial"] == trial]
                for trial in sorted(
                    {r["trial"] for r in subset if r["viewer"] == viewer}
                )
            ]
            if len(runs) != 6 or any(
                sorted(int(r["step"]) for r in run) != list(range(14)) for run in runs
            ):
                raise ValueError(
                    "chart requires six complete runs per viewer and dataset"
                )
            totals = [sum(float(r["ms"]) for r in run) / 1000 for run in runs]
            best = runs[totals.index(min(totals))]
            left = 0
            for steps, _, color in phases:
                elapsed = (
                    sum(float(r["ms"]) for r in best if int(r["step"]) in steps) / 1000
                )
                timing.barh(y, elapsed, left=left, height=0.48, color=color)
                left += elapsed
            timing.plot(totals, [y] * len(totals), "|", color="black", markersize=9)
            timing.annotate(
                f" {min(totals):.2f} s",
                (min(totals), y),
                xytext=(0, -15),
                textcoords="offset points",
                va="center",
                fontsize=9,
            )
            peaks = [max(int(r["peak_rss_kib"]) for r in run) / 1048576 for run in runs]
            memory.barh(y, max(peaks), color="#666666", height=0.48)
            memory.plot(peaks, [y] * len(peaks), "|", color="black", markersize=9)
            memory.text(max(peaks), y, f" {max(peaks):.2g}", va="center", fontsize=9)
        timing.set_title(title, loc="left", fontweight="bold")
        timing.set_xlabel(
            "Total time waiting for window pixels (seconds; lower is better)"
        )
        timing.grid(axis="x", alpha=0.15)
        timing.set_xlim(0, timing.get_xlim()[1] * 1.12)
        memory.set_title("Peak viewer RAM", fontsize=10)
        memory.set_xlabel("GiB")
        memory.set_xlim(0, memory.get_xlim()[1] * 1.25)
        for ax in (timing, memory):
            ax.set_yticks(range(3), [v[1] for v in viewers] if ax == timing else [])
            ax.set_ylim(2.6, -0.6)
            ax.spines[["top", "right"]].set_visible(False)
    fig.legend(
        [Patch(color=c) for _, _, c in phases],
        [label for _, label, _ in phases],
        loc="upper center",
        ncol=3,
        frameon=False,
        fontsize=9,
    )
    first_zoom = [
        float(r["ms"])
        for r in rows
        if r["dataset"] == "tiff" and r["viewer"] == "yekk" and int(r["step"]) == 1
    ]
    fig.text(
        0.02,
        0.025,
        "Time bars: fastest complete run of six. Ticks: all six runs. Fixed inspection pauses excluded. RAM bars: maximum peak RSS.\n"
        "Private Xvfb; CPU rendering; warm file cache. Ryzen 9 7950X, 125 GiB usable RAM. Each time panel has its own scale.\n"
        f"First 100% TIFF view in Yekk: {min(first_zoom):.0f}–{max(first_zoom):.0f} ms; {sum(x >= 200 for x in first_zoom)}/6 runs took at least 200 ms.",
        fontsize=8,
    )
    fig.tight_layout(rect=(0, 0.13, 1, 0.93), h_pad=2.7)
    output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(
        output,
        metadata={
            "Date": None,
            "Title": "Yekk, feh and imv: photo-review waiting time and peak RAM",
        },
    )
    plt.close(fig)


def file_digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(8 * 1024 * 1024):
            value.update(block)
    return value.hexdigest()


p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--output", required=True, type=pathlib.Path)
p.add_argument(
    "--plot-csv",
    type=pathlib.Path,
    help="draw the comparison chart instead of running viewers",
)
p.add_argument("--yekk", type=pathlib.Path)
p.add_argument("--calibrate", action="store_true")
p.add_argument("--rounds", type=int, default=6)
p.add_argument(
    "--viewers",
    nargs="+",
    default=["yekk", "feh", "imv"],
    choices=["yekk", "feh", "imv"],
)
p.add_argument("--dwell", type=float, default=2)
p.add_argument("--settle", type=float, default=10)
p.add_argument("images", nargs="*", type=pathlib.Path)
a = p.parse_args()
if a.plot_csv:
    chart(a.plot_csv, a.output)
    raise SystemExit(0)
if not a.yekk or len(a.images) != 3:
    p.error("supply --yekk and exactly three images")
if a.rounds < 6 or a.rounds % 6 or len(set(a.viewers)) != 3:
    p.error("use all three viewers and a positive multiple of six rounds")
if (
    not math.isfinite(a.dwell)
    or not math.isfinite(a.settle)
    or a.dwell < 0
    or a.settle < 1
):
    p.error("--dwell must be nonnegative and --settle must be at least one second")
from Xlib import X, XK, display
from Xlib.ext import xtest
from PIL import Image

a.output.mkdir(parents=True, exist_ok=True)
a.images = [x.resolve(strict=True) for x in a.images]
if len(set(a.images)) != 3:
    p.error("supply three different image files")
a.yekk = a.yekk.resolve(strict=True)
root = pathlib.Path(__file__).resolve().parent.parent
sequence = [
    ("open", "1-fit", None),
    ("zoom", "1-actual", "a"),
    ("fit", "1-fit", "slash"),
    ("next", "2-fit", "Right"),
    ("zoom", "2-actual", "a"),
    ("fit", "2-fit", "slash"),
    ("next", "3-fit", "Right"),
    ("zoom", "3-actual", "a"),
    ("fit", "3-fit", "slash"),
    ("return", "2-fit", "Left"),
    ("zoom_return", "2-actual", "a"),
    ("fit", "2-fit", "slash"),
    ("return", "1-fit", "Left"),
    ("zoom_return", "1-actual", "a"),
]
refs_path = a.output / "references.json"
refs = json.loads(refs_path.read_text()) if refs_path.exists() else {}
if (a.output / "measurements.jsonl").exists():
    p.error("output already contains measurements")
if not a.calibrate:
    for viewer in a.viewers:
        for index, (_, state, _) in enumerate(sequence):
            if f"{viewer}/{index}-{state}" not in refs:
                p.error("calibrate all workflow steps before timing")


def stop(proc):
    if proc is None:
        return
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=3)


with tempfile.TemporaryDirectory(prefix="yekk-viewer-comparison-") as tmp:
    tmp = pathlib.Path(tmp)
    (tmp / "runtime").mkdir(mode=0o700)
    (tmp / "config/feh").mkdir(parents=True)
    (tmp / "config/feh/keys").write_text(
        "toggle_actions\nzoom_default a\nzoom_fit slash\n"
    )
    (tmp / "imv-config").write_text(
        "[options]\nwidth=960\nheight=640\nbackground=000000\noverlay=false\nscaling_mode=full\ninitial_pan=50 50\n[binds]\n<slash> = reset\n"
    )
    env = dict(
        os.environ,
        SDL_VIDEO_DRIVER="x11",
        SDL_RENDER_DRIVER="software",
        LIBGL_ALWAYS_SOFTWARE="1",
        XDG_CONFIG_HOME=str(tmp / "config"),
        XDG_CACHE_HOME=str(tmp / "cache"),
        XDG_RUNTIME_DIR=str(tmp / "runtime"),
        YEKK_CONFIG=str(tmp / "absent"),
        imv_config=str(tmp / "imv-config"),
        YEKK_TEST_TIMEOUT="240",
    )
    env.pop("WAYLAND_DISPLAY", None)
    read, write = os.pipe()
    xlog = (a.output / "xserver.log").open("w")
    server = subprocess.Popen(
        [
            "Xvfb",
            "-displayfd",
            str(write),
            "-screen",
            "0",
            "1280x800x24",
            "-dpi",
            "96",
            "-nolisten",
            "tcp",
            "-noreset",
            "-ac",
        ],
        pass_fds=[write],
        stdout=xlog,
        stderr=xlog,
        start_new_session=True,
    )
    os.close(write)
    wm = None
    try:
        with os.fdopen(read, "rb") as stream:
            sel = selectors.DefaultSelector()
            sel.register(stream, selectors.EVENT_READ)
            if not sel.select(15):
                raise TimeoutError("Xvfb readiness")
            env["DISPLAY"] = ":" + stream.readline().decode().strip()
            sel.close()
        wmconfig = tmp / "openbox.xml"
        wmconfig.write_text(
            '<openbox_config xmlns="http://openbox.org/3.4/rc"><focus><focusNew>yes</focusNew></focus><applications><application class="*"><decor>no</decor><position force="yes"><x>0</x><y>0</y></position></application></applications></openbox_config>'
        )
        wm = subprocess.Popen(
            ["openbox", "--sm-disable", "--config-file", str(wmconfig)],
            env=env,
            stdout=xlog,
            stderr=xlog,
            start_new_session=True,
        )
        d = display.Display(env["DISPLAY"])
        screen = d.screen()
        client_atom = d.intern_atom("_NET_CLIENT_LIST")
        deadline = time.monotonic() + 15
        while not screen.root.get_full_property(client_atom, X.AnyPropertyType):
            if time.monotonic() > deadline:
                raise TimeoutError("Openbox readiness")
            time.sleep(0.05)

        def window():
            prop = screen.root.get_full_property(client_atom, X.AnyPropertyType)
            for identifier in prop.value if prop else []:
                w = d.create_resource_object("window", int(identifier))
                g = w.get_geometry()
                if w.get_attributes().map_state == X.IsViewable and (
                    g.width,
                    g.height,
                ) == (960, 640):
                    return w

        def capture(w):
            return w.get_image(0, 0, 960, 640, X.ZPixmap, 4294967295).data

        def digest(raw):
            # Depth-24 X11 images have an undefined fourth byte. Compare colors,
            # not that padding byte, across independent display-server runs.
            rgb = Image.frombytes("RGB", (960, 640), raw, "raw", "BGRX")
            return hashlib.sha256(rgb.tobytes()).hexdigest()

        def key(w, name):
            d.set_input_focus(w, X.RevertToParent, X.CurrentTime)
            code = d.keysym_to_keycode(XK.string_to_keysym(name))
            assert code, name
            xtest.fake_input(d, X.KeyPress, code)
            xtest.fake_input(d, X.KeyRelease, code)
            d.flush()

        def warm():
            for file in a.images:
                with file.open("rb") as f:
                    while f.read(8 * 1024 * 1024):
                        pass

        def run(viewer, trial):
            warm()
            logpath = a.output / f"{viewer}-{trial}.log"
            log = logpath.open("w")
            commands = {
                "yekk": [
                    str(a.yekk),
                    "--keys",
                    str(tmp / "config/feh/keys"),
                    "-g",
                    "960x640+0+0",
                    "-Z",
                    "-.",
                ],
                "feh": [
                    "feh",
                    "-g",
                    "960x640+0+0",
                    "-Z",
                    "-.",
                    "-B",
                    "black",
                    "--cache-size",
                    "2047",
                ],
                "imv": [
                    "imv-x11",
                    "-W",
                    "960",
                    "-H",
                    "640",
                    "-s",
                    "full",
                    "-b",
                    "000000",
                ],
            }
            cmd = [
                sys.executable,
                str(root / "scripts/supervise.py"),
                *commands[viewer],
                *map(str, a.images),
            ]
            rows = []
            viewer_pid = None
            process = None
            start = time.perf_counter_ns()
            process = subprocess.Popen(
                cmd, env=env, stdout=log, stderr=log, start_new_session=True
            )
            try:
                deadline = time.monotonic() + 90
                w = None
                while w is None:
                    w = window()
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise TimeoutError("window: " + logpath.read_text()[-1000:])
                    time.sleep(0.002)
                children = (
                    pathlib.Path(f"/proc/{process.pid}/task/{process.pid}/children")
                    .read_text()
                    .split()
                )
                groups = []
                for child in children:
                    try:
                        if os.getpgid(int(child)) == int(child):
                            groups.append(int(child))
                    except ProcessLookupError:
                        pass
                if len(groups) != 1:
                    raise RuntimeError(("unexpected viewer groups", groups))
                viewer_pid = groups[0]
                d.warp_pointer(480, 320)
                d.sync()
                for index, (action, state, press) in enumerate(sequence):
                    if press:
                        start = time.perf_counter_ns()
                        key(w, press)
                    if a.calibrate:
                        time.sleep(a.settle)
                        raw = capture(w)
                        value = digest(raw)
                        title = w.get_wm_name()
                        print(viewer, state, title, flush=True)
                        if a.images[int(state[0]) - 1].name not in str(title):
                            raise RuntimeError("reference has the wrong image title")
                        time.sleep(0.3)
                        if digest(capture(w)) != value:
                            raise RuntimeError(
                                "unstable reference " + viewer + " " + state
                            )
                        # Fit rounding can differ between initial sizing and a fit key.
                        # Each workflow step therefore has its own reference.
                        refkey = viewer + "/" + str(index) + "-" + state
                        if refkey in refs and refs[refkey] != value:
                            raise RuntimeError("state mismatch " + refkey)
                        extrema = Image.frombytes(
                            "RGB", (960, 640), raw, "raw", "BGRX"
                        ).getextrema()
                        if (
                            max(high for _, high in extrema)
                            - min(low for low, _ in extrema)
                            < 20
                        ):
                            raise RuntimeError("blank reference " + refkey)
                        if (
                            state.endswith("actual")
                            and refs.get(
                                viewer
                                + "/"
                                + str(index - 1)
                                + "-"
                                + state.replace("actual", "fit")
                            )
                            == value
                        ):
                            raise RuntimeError("zoom had no effect " + refkey)
                        refs[refkey] = value
                        Image.frombytes("RGB", (960, 640), raw, "raw", "BGRX").save(
                            a.output / f"{viewer}-{index}-{state}.png"
                        )
                    else:
                        wanted = refs[viewer + "/" + str(index) + "-" + state]
                        polls = 0
                        longest = 0
                        deadline = time.monotonic() + 90
                        while True:
                            before = time.perf_counter_ns()
                            raw = capture(w)
                            value = digest(raw)
                            now = time.perf_counter_ns()
                            polls += 1
                            longest = max(longest, now - before)
                            if value == wanted:
                                break
                            if (
                                process.poll() is not None
                                or time.monotonic() > deadline
                            ):
                                Image.frombytes(
                                    "RGB", (960, 640), raw, "raw", "BGRX"
                                ).save(
                                    a.output / f"failed-{viewer}-{trial}-{index}.png"
                                )
                                raise TimeoutError(
                                    f"{viewer} {state} {value} wanted {wanted}: "
                                    + logpath.read_text()[-1000:]
                                )
                            time.sleep(0.002)
                        elapsed = (now - start) / 1000000.0
                        status = pathlib.Path(f"/proc/{viewer_pid}/status").read_text()
                        hwm = int(
                            next(
                                (
                                    l.split()[1]
                                    for l in status.splitlines()
                                    if l.startswith("VmHWM:")
                                )
                            )
                        )
                        io = dict(
                            line.split(":", 1)
                            for line in pathlib.Path(f"/proc/{viewer_pid}/io")
                            .read_text()
                            .splitlines()
                        )
                        rows.append(
                            dict(
                                viewer=viewer,
                                trial=trial,
                                step=index,
                                action=action,
                                state=state,
                                ms=elapsed,
                                polls=polls,
                                max_capture_ms=longest / 1000000.0,
                                peak_rss_kib=hwm,
                                physical_read_bytes=int(io["read_bytes"]),
                                load_1m=os.getloadavg()[0],
                            )
                        )
                        print(json.dumps(rows[-1]), flush=True)
                        time.sleep(
                            a.dwell
                            if action in ("open", "next", "return")
                            else 1
                            if action in ("zoom", "zoom_return")
                            else 0
                        )
                key(w, "q")
                process.wait(timeout=10)
                if process.returncode:
                    raise RuntimeError("viewer exited " + logpath.read_text()[-1000:])
                return rows
            finally:
                owned = {viewer_pid} if viewer_pid else set()
                try:
                    children = (
                        pathlib.Path(f"/proc/{process.pid}/task/{process.pid}/children")
                        .read_text()
                        .split()
                    )
                    for child in children:
                        try:
                            if os.getpgid(int(child)) == int(child):
                                owned.add(int(child))
                        except ProcessLookupError:
                            pass
                except FileNotFoundError:
                    pass
                for child in owned:
                    try:
                        os.killpg(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                stop(process)
                log.close()
                d.sync()
                time.sleep(0.1)

        if a.calibrate:
            for viewer in a.viewers:
                print("CALIBRATE " + viewer, flush=True)
                run(viewer, "calibration")
                refs_path.write_text(json.dumps(refs, indent=2) + "\n")
        else:
            orders = list(itertools.permutations(a.viewers))
            random.Random(20261114).shuffle(orders)
            plan = [orders[i % len(orders)] for i in range(a.rounds)]
            metadata = dict(
                images=[
                    dict(name=f.name, bytes=f.stat().st_size, sha256=file_digest(f))
                    for f in a.images
                ],
                sequence=sequence,
                plan=plan,
                dwell_fit_seconds=a.dwell,
                dwell_actual_seconds=1,
                dwell_after_reset_seconds=0,
                source=subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=root, text=True
                ).strip(),
                yekk_sha256=file_digest(a.yekk),
                harness_sha256=file_digest(pathlib.Path(__file__)),
                references_sha256=file_digest(refs_path),
                display="private Xvfb 1280x800x24, 96dpi; 960x640 window; SDL software and imv software OpenGL",
                poll_sleep_ms=2,
                commands={
                    viewer: [str(a.yekk)] if viewer == "yekk" else [viewer]
                    for viewer in a.viewers
                },
                started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            )
            (a.output / "metadata.json").write_text(
                json.dumps(metadata, indent=2) + "\n"
            )
            with (a.output / "measurements.jsonl").open("w") as f:
                for trial, order in enumerate(plan):
                    for viewer in order:
                        for row in run(viewer, trial):
                            f.write(json.dumps(row) + "\n")
                        f.flush()
    finally:
        stop(wm)
        stop(server)
        xlog.close()
