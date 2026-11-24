#!/usr/bin/env python3
"""Real feh-style CLI and native key-hook checks, using disposable image copies."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
viewer = Path(os.environ.get('YEKK_VIEWER', str(root / 'zig-out/bin/yekk'))).resolve()
supervisor = root / 'scripts/supervise.py'
with tempfile.TemporaryDirectory(prefix='yekk-feh-') as directory:
    work = Path(directory).resolve()
    env = dict(os.environ, YEKK_CONFIG=str(work / 'no-config'), XDG_CONFIG_HOME=str(work / 'config'))
    for name in ['keep', 'discard', 'images']:
        (work / name).mkdir()
    paths = [work / 'images' / name for name in ['frame1.png', "frame2 雪'$(exit 73)\n.png", 'frame10.png']]
    for path in paths:
        path.write_bytes((root / 'tests/fixtures/alpha.content').read_bytes())
    # Explicit symlink input must reach the action as the link, just as when
    # discovered in a directory. Moving it must leave its original untouched.
    original = work / 'original.png'
    original.write_bytes(paths[1].read_bytes())
    paths[1].unlink()
    paths[1].symlink_to(original)
    env.update(KEEP=str(work / 'keep'), DISCARD=str(work / 'discard'), LOG=str(work / 'actions.log'), MANIFEST=str(work / 'manifest'), HOOK_VIEW=str(work / 'hook-view'))
    def cli(*args, cwd=work):
        return subprocess.check_output([str(viewer), *map(str, args)], cwd=cwd, env=env, text=True, timeout=5)
    def gui(*args, cwd=work):
        return subprocess.check_output(['python3', str(supervisor), str(viewer), *map(str, args)], cwd=cwd, env=env, text=True, timeout=35)
    # Paths containing newlines are valid argv/hook inputs but cannot be
    # represented in the newline-delimited file-list interface.
    plain = [paths[0], paths[2]]
    filelist = work / 'input-list'
    filelist.write_text(''.join(str(path) + '\n' for path in plain))
    assert cli('-f', filelist, '--print-filelist').splitlines() == list(map(str, plain))
    assert cli('--sort=filename', '--version-sort', '--print-filelist', *plain).splitlines() == list(map(str, plain))
    info = cli('-l', paths[0]).splitlines()
    assert info[0].startswith('NUM\tFORMAT\tWIDTH') and info[1].split('\t')[1:4] == ['png', '3', '2'], info
    # These headless cases also run on Linux, before the platform-specific
    # native hook and single-instance checks below.
    valid_png = work / "alpha.png"
    valid_png.write_bytes((root / "tests/fixtures/alpha.content").read_bytes())
    valid_jpeg = work / "orientation6.jpg"
    valid_jpeg.write_bytes((root / "tests/fixtures/orientation6.jpg").read_bytes())
    broken = work / "truncated.png"
    broken.write_bytes((root / "tests/fixtures/truncated.png").read_bytes())
    rows = cli("-l", "orientation6.jpg", "truncated.png", "alpha.png").splitlines()
    assert rows == [
        "NUM\tFORMAT\tWIDTH\tHEIGHT\tPIXELS\tSIZE\tALPHA\tFILENAME",
        "1\tjpg\t2\t3\t  6 \t898 \t-\torientation6.jpg",
        "2\tpng\t3\t2\t  6 \t 83 \tX\talpha.png",
    ], rows
    assert cli("-L", r"%m\t%w,%h\t%t\t%f\t%n", "./orientation6.jpg") == (
        "list\t2,3\tjpg\t./orientation6.jpg\torientation6.jpg\n"
    )

    def classify(flag, paths, status, text):
        run = subprocess.run([str(viewer), flag, *paths], cwd=work, env=env,
                             text=True, capture_output=True, timeout=5)
        assert (run.returncode, run.stdout) == (status, text), run

    classify("-U", ["alpha.png", "truncated.png"], 1, "alpha.png\n")
    classify("-u", ["alpha.png", "truncated.png"], 1, "truncated.png\n")
    classify("--loadable", ["alpha.png"], 0, "alpha.png\n")
    classify("--unloadable", ["truncated.png"], 0, "truncated.png\n")
    classify("--loadable", ["alpha.png", "missing.png"], 0, "alpha.png\n")
    classify("-l", ["truncated.png"], 1, "")
    assert cli("-L", "%u/%l|%z|%Z|%r", "alpha.png", "truncated.png", "orientation6.jpg") == (
        "1/2|1.00||\n2/2|1.00||\n"
    )
    assert cli("-L%n", "--sort=width", "alpha.png", "orientation6.jpg") == "orientation6.jpg\nalpha.png\n"
    assert cli("-L%n", "--sort=height", "orientation6.jpg", "alpha.png") == "alpha.png\norientation6.jpg\n"
    assert cli("-L%n", "--sort=format", "alpha.png", "orientation6.jpg") == "orientation6.jpg\nalpha.png\n"
    assert cli("-L%n", "--min-dimension", "3x0", "orientation6.jpg", "alpha.png") == "alpha.png\n"
    assert cli("-L%n", "--max-dimension", "0x2", "orientation6.jpg", "alpha.png") == "alpha.png\n"
    assert cli("-L%n", "--sort=none", "orientation6.jpg", "alpha.png") == "orientation6.jpg\nalpha.png\n"

    configs = Path(env["XDG_CONFIG_HOME"]) / "feh"
    configs.mkdir(parents=True)
    (configs / "themes").write_text("triage --sort height --customlist '%h %n' \\\n --max-dimension 200x200\n")
    assert cli("-Ttriage", "orientation6.jpg", "alpha.png") == "2 alpha.png\n3 orientation6.jpg\n"
    assert cli("-Ttriage", "--sort=width", "alpha.png", "orientation6.jpg") == "3 orientation6.jpg\n2 alpha.png\n"
    cli("-L%n", "-A", "printf '%%s\\n' %F > \"$LOG\"", "orientation6.jpg")
    assert (work / "actions.log").read_text() == "orientation6.jpg\n"
    (work / "actions.log").unlink()
    assert cli("-L%n", "-A", "printf 'action: %%s\\n' %F", "orientation6.jpg", "alpha.png") == (
        "action: orientation6.jpg\naction: alpha.png\norientation6.jpg\nalpha.png\n"
    )
    if "--headless" in sys.argv[1:]:
        print("feh listing, catalog and theme checks passed")
        raise SystemExit(0)
    output = gui('-xg960x640-0+0', '--hook-test', '-f', work / 'session-list', '-G', '-A', "printf 'zero\\n' >> \"$LOG\"; printf '%%s\\n' %g %w %h %z %o > \"$HOOK_VIEW\"", '--action1=[Keep]mv %F "$KEEP/"',
                 '--action2=;[Inspect]printf inspect >> "$LOG"', '--action3=exit 7', '--action4=sleep 0.2; test -f %F',
                 '--action5=sleep 0.2; mv %F "$DISCARD/"', '--action7=echo %f', '--action8=cat %L > "$MANIFEST"', *paths)
    assert 'HOOK_TEST_PASSED' in output, output
    assert (work / 'actions.log').read_text() == 'zero\ninspect'
    viewport, width, height, zoom, origin = (work / 'hook-view').read_text().splitlines()
    vw, vh = map(int, viewport.split(','))
    x, y = map(int, origin.split(','))
    scale = float(zoom)
    assert abs(x - (vw - int(width) * scale) / 2) <= 0.5
    assert abs(y - (vh - int(height) * scale) / 2) <= 0.5
    assert not paths[0].exists() and (work / 'discard' / paths[0].name).is_file()
    assert not paths[1].exists() and (work / 'keep' / paths[1].name).is_file()
    assert (work / 'keep' / paths[1].name).is_symlink() and original.is_file()
    assert paths[2].is_file() and (work / 'manifest').read_text() == str(paths[2]) + '\n'
    assert (work / 'session-list').read_text() == str(paths[2]) + '\n'
    assert cli('--print-filelist', cwd=work / 'images').strip() == str(paths[2])
    # An argument-free input set must start a single cwd session, including
    # when other options are supplied. The supervisor guards process creation.
    assert 'passed' in gui('--benchmark', cwd=work / 'images')
    print('feh CLI and native hook integration: passed')
