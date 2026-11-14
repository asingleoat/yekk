#!/usr/bin/env python3
"""Test the extracted release, including after moving it, without build paths."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--package', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--isolate', action='store_true', help='hide /nix; requires an ordinary Linux host')
p.add_argument('--isolate-sudo', action='store_true', help='create the mount namespace with sudo, then run as the caller')
p.add_argument('--minimal-root', type=Path, help='decoder-only isolation using a static BusyBox on NixOS')
a = p.parse_args()
if a.isolate_sudo and not a.isolate:
    p.error('--isolate-sudo requires --isolate')
root = Path(__file__).resolve().parents[1]
archives = [path for path in a.package.glob('yekk-*-linux-*.tar.gz') if not path.name.endswith('-library-sources.tar.gz')]
assert len(archives) == 1, archives
archive = archives[0].resolve(strict=True)
report = dict(archive=archive.name, archive_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
              nix_hidden=a.isolate or bool(a.minimal_root), decoder_only=bool(a.minimal_root), cases=[])
env = {key: value for key, value in os.environ.items()
       if not key.startswith(('LD_', 'DYLD_', 'YEKK_', 'VIPS_', 'MAGICK_', 'GI_'))}
env.update(SDL_VIDEO_DRIVER='dummy', YEKK_TEST_TIMEOUT='60')
a.output.parent.mkdir(parents=True, exist_ok=True)


def save():
    a.output.write_text(json.dumps(report, indent=2) + '\n')


with tempfile.TemporaryDirectory(prefix='yekk-release-check-') as temporary:
    folder = Path(temporary)
    with tarfile.open(archive) as stream:
        stream.extractall(folder, filter='data')
    original = next(folder.glob('yekk-*'))
    # This path is independent of the build/install prefix and shell-sensitive.
    tree = folder / "moved release ' $literal"
    original.rename(tree)
    binary = tree / 'yekk'
    env.update(YEKK_CONFIG=str(folder / 'none'), XDG_CONFIG_HOME=str(folder / 'config'))
    prefix = []
    if a.isolate:
        assert Path('/usr/bin/python3').exists(), 'isolation needs the host Python outside Nix'
        # Ubuntu's user-namespace policy is attached to its /usr/bin/bwrap.
        # Use that packaged helper rather than a different Nix store executable.
        assert Path('/usr/bin/bwrap').exists(), 'isolation needs the distribution bubblewrap package'
        prefix = ['/usr/bin/bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--tmpfs', '/nix',
                  '--bind', str(folder), str(folder), '--dev-bind', '/dev', '/dev',
                  '--proc', '/proc', '--setenv', 'PATH', '/usr/bin:/bin', '--']
        if a.isolate_sudo:
            preserved = []
            for key in ['SDL_VIDEO_DRIVER', 'YEKK_TEST_TIMEOUT', 'YEKK_CONFIG', 'XDG_CONFIG_HOME',
                        'HOME', 'USER', 'LOGNAME']:
                if key in env:
                    preserved.extend(['--setenv', key, env[key]])
            prefix = ['sudo', '--non-interactive', *prefix[:-1], *preserved, '--',
                      '/usr/bin/setpriv', '--reuid', str(os.getuid()), '--regid', str(os.getgid()),
                      '--clear-groups', '--inh-caps=-all', '--ambient-caps=-all',
                      '--bounding-set=-all', '--no-new-privs', '--']
    elif a.minimal_root:
        prefix = ['bwrap', '--die-with-parent', '--unshare-all', '--proc', '/proc',
                  '--dev', '/dev', '--tmpfs', '/tmp', '--ro-bind', str(root), str(root),
                  '--bind', str(folder), str(folder), '--dir', '/bin',
                  '--ro-bind', str(a.minimal_root.resolve(strict=True)), '/bin/busybox',
                  '--symlink', 'busybox', '/bin/sh', '--symlink', 'busybox', '/bin/dirname',
                  '--setenv', 'PATH', '/bin', '--']

    def check(name, arguments, gui=False, expected=0):
        command = [str(binary), '--alloc-stats', *map(str, arguments)]
        if gui:
            python = '/usr/bin/python3' if a.isolate else sys.executable
            command = [python, str(root / 'scripts/supervise.py'), *command]
        completed = subprocess.run(prefix + command, env=env, capture_output=True, text=True, timeout=75)
        record = dict(name=name, command=command, status=completed.returncode,
                      stdout=completed.stdout, stderr=completed.stderr)
        report['cases'].append(record)
        save()
        assert completed.returncode == expected, record
        assert 'live_bytes=0' in completed.stderr, record
        print(name + ': passed', flush=True)
        return completed

    version = check('version from relocated artifact', ['--version'])
    metadata = json.loads((tree / 'release.json').read_text())
    assert version.stdout.startswith('yekk ' + metadata['version']), version.stdout
    fixtures = root / 'tests/fixtures'
    # Generate the remaining catalog formats with the pinned development
    # codecs, then decode them with the extracted release inside isolation.
    sample = folder / 'sample.v'
    fixture_env = dict(os.environ, VIPS_CONCURRENCY='2')
    subprocess.run(['vips', 'black', str(sample), '96', '64', '--bands', '3'], env=fixture_env, check=True, capture_output=True)
    for extension in ['bmp', 'gif', 'webp', 'heic', 'avif', 'jxl', 'ppm']:
        generated = folder / ('sample.' + extension)
        generated_fixture = subprocess.run(['vips', 'copy', str(sample), str(generated)], env=fixture_env, capture_output=True, text=True)
        assert generated_fixture.returncode == 0, (extension, generated_fixture.stderr)
        check('decode generated ' + extension, ['--benchmark', generated])
    for name in ['alpha.content', 'gray16.png', 'rgb16-tiled-big.tif', 'jpeg-progressive.jpg']:
        check('decode ' + name, ['--benchmark', fixtures / name])
    if not a.minimal_root:
        check('present fitted viewport', ['--software', '--smoke-test', '--snapshot', folder / 'fit.png', fixtures / 'alpha.content'], gui=True)
        check('actual-size viewport', ['--zoom', '100', '--smoke-test', fixtures / 'rgb16-orientation6.tif'], gui=True)
        check('cached navigation', ['--stress-test', '64', fixtures / 'rgb16-orientation1.tif', fixtures / 'rgb16-orientation6.tif'], gui=True)
        check('damaged input rejected', ['--smoke-test', fixtures / 'jpeg-incomplete-4.jpg'], gui=True, expected=1)
        hook = folder / 'hook-result'
        check('literal hook arguments', ['--smoke-hook-test', '-A', "printf '%%s' %F > '" + str(hook) + "'", fixtures / 'alpha.content'], gui=True)
        assert hook.read_text() == str(fixtures / 'alpha.content')
        assert (folder / 'fit.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
report['passed'] = True
save()
