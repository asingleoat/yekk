#!/usr/bin/env python3
"""Real feh-style CLI and native key-hook checks, using disposable image copies."""
from pathlib import Path
import os
import subprocess
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
    output = gui('-xg960x640-0+0', '--hook-test', '-f', work / 'session-list', '-G', '-A', "printf 'zero\\n' >> \"$LOG\"; printf '%%s\\n' %g %w %h %z %o > \"$HOOK_VIEW\"", '--action1=[Keep]mv %F "$KEEP/"',
                 '--action2=;[Inspect]printf inspect >> "$LOG"', '--action3=exit 7', '--action4=sleep 0.2; test -f %F',
                 '--action5=sleep 0.2; mv %F "$DISCARD/"', '--action7=echo %f', '--action8=cat %L > "$MANIFEST"', *paths)
    assert 'HOOK_TEST_PASSED' in output, output
    assert (work / 'actions.log').read_text() == 'zero\ninspect'
    viewport, width, height, zoom, origin = (work / 'hook-view').read_text().splitlines()
    vw, vh = map(int, viewport.split(','))
    x, y = map(int, origin.split(','))
    scale = float(zoom) / 100
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
