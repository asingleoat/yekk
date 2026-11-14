#!/usr/bin/env python3
"""Stage a relocatable Linux runtime, audit its ELF closure and archive it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--font', type=Path, required=True)
p.add_argument('--mime', type=Path, required=True)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--dependency-sources', type=Path, required=True)
p.add_argument('--dependency-metadata', type=Path, required=True)
p.add_argument('--version', required=True)
a = p.parse_args()
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.]+)?', a.version):
    p.error('invalid release version')
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
tree = out / ('yekk-' + a.version + '-linux-' + platform.machine())
tree.mkdir()
(tree / 'libexec').mkdir()
(tree / 'lib').mkdir()
(tree / 'share').mkdir()


def run(*args):
    try:
        return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(str(args[0]) + ': ' + error.output) from error


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def closure(path):
    result = {}
    text = run('ldd', path)
    for line in text.splitlines():
        if 'not found' in line:
            raise RuntimeError('unresolved build dependency: ' + line)
        match = re.match(r'\s*(\S+) => (/\S+) \(', line)
        if match:
            name, source = match.groups()
            name = Path(name).name
            source = Path(source).resolve(strict=True)
            if name in result and result[name] != source:
                raise RuntimeError('library name collision: ' + name)
            result[name] = source
    return result


binary = tree / 'libexec/yekk'
shutil.copy2(a.binary, binary)
binary.chmod(0o755)
deps = closure(a.binary)
for forbidden in ('libvips.so', 'libSDL3.so', 'libtiff.so', 'liblcms2.so'):
    if any(name.startswith(forbidden) for name in run('patchelf', '--print-needed', a.binary).splitlines()):
        raise RuntimeError('release core dependency is not static: ' + forbidden)
loader = Path(run('patchelf', '--print-interpreter', a.binary).strip()).resolve(strict=True)
loader_name = loader.name
deps[loader_name] = loader
provenance = []
for name, source in sorted(deps.items()):
    destination = tree / 'lib' / name
    shutil.copy2(source, destination)
    destination.chmod(0o755)
    provenance.append(dict(name=name, source=str(source), sha256=sha(source)))
    for needed in run('patchelf', '--print-needed', destination).splitlines():
        if '/' in needed:
            run('patchelf', '--replace-needed', needed, Path(needed).name, destination)
    if name != loader_name:
        run('patchelf', '--set-rpath', '$ORIGIN', destination)
run('patchelf', '--set-rpath', '$ORIGIN/../lib', binary)
# The launcher uses the matching bundled loader explicitly. Keep the ELF's
# interpreter conventional as well, for inspection/tools and compatible hosts.
system_loader = '/lib64/ld-linux-x86-64.so.2' if platform.machine() == 'x86_64' else '/lib/ld-linux-aarch64.so.1'
run('patchelf', '--set-interpreter', system_loader, binary)
shutil.copy2(a.font, tree / 'share/DejaVuSans.ttf')
shutil.copytree(a.mime, tree / 'share/mime')
shutil.copy2(a.source / 'packaging/yekk.desktop', tree / 'share/yekk.desktop')
shutil.copy2(a.source / 'LICENSE', tree / 'LICENSE')
run('python3', a.source / 'packaging/license-notices.py',
    '--sources', a.dependency_sources, '--output', tree / 'licenses')
launcher = tree / 'yekk'
multiarch = {'x86_64': 'x86_64-linux-gnu', 'aarch64': 'aarch64-linux-gnu'}[platform.machine()]
launcher.write_text('''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
export YEKK_ENTRY_EXECUTABLE="$root/yekk"
export YEKK_NATIVE_EXECUTABLE="$root/libexec/yekk"
export YEKK_FONT_FILE="$root/share/DejaVuSans.ttf"
export XDG_DATA_DIRS="$root/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$root/lib/''' + loader_name + '''" --library-path "$root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}:/lib:/usr/lib:/lib64:/usr/lib64:/lib/''' + multiarch + ''':/usr/lib/''' + multiarch + '''" "$root/libexec/yekk" "$@"
''')
launcher.chmod(0o755)
manifest = dict(version=a.version, license='GPL-3.0-or-later', architecture=platform.machine(),
                static_libraries=['libvips', 'SDL3', 'libtiff', 'lcms2', 'libjpeg', 'libpng', 'libwebp', 'zlib'],
                bundled_libraries=provenance, interpreter=system_loader)
(tree / 'THIRD-PARTY.json').write_text(json.dumps(json.loads(a.dependency_metadata.read_text()), indent=2) + '\n')
for path in [binary, *(tree / 'lib').iterdir()]:
    needed = run('patchelf', '--print-needed', path).splitlines()
    assert all((tree / 'lib' / name).is_file() for name in needed), (path, needed)
    assert '/nix/store/' not in run('patchelf', '--print-rpath', path), path
    assert all('/' not in name for name in needed), (path, needed)
environment = {key: value for key, value in os.environ.items()
               if not key.startswith(('LD_', 'DYLD_', 'YEKK_'))}
check = subprocess.run([str(launcher), '--version'], env=environment, capture_output=True, text=True, check=True)
manifest['version_output'] = check.stdout.strip()
(tree / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')
(tree / 'README.txt').write_text('''Run ./yekk [image or directory]. Keep the lib, libexec and share folders together.
On NixOS, run: steam-run ./yekk [image or directory]
The host provides its graphics drivers and X11/Wayland desktop libraries.
The bundled loader/runtime avoids requiring a particular host glibc release.
Source and reproducible build recipes: https://github.com/asingleoat/yekk
''')
archive = out / (tree.name + '.tar.gz')
with tarfile.open(archive, 'w:gz') as stream:
    stream.add(tree, arcname=tree.name)
manifest['archive_sha256'] = sha(archive)
manifest['archive_bytes'] = archive.stat().st_size
(out / (tree.name + '.json')).write_text(json.dumps(manifest, indent=2) + '\n')
(out / (archive.name + '.sha256')).write_text(manifest['archive_sha256'] + '  ' + archive.name + '\n')
sources = out / (tree.name + '-library-sources.tar.gz')
with tarfile.open(sources, 'w:gz') as stream:
    for path in sorted(a.dependency_sources.iterdir()):
        source = path.resolve(strict=True)
        suffix = next((ending for ending in ['.tar.gz', '.tar.xz', '.tar.bz2', '.zip']
                       if source.name.endswith(ending)), '') if source.is_file() else ''
        stream.add(source, arcname='library-sources/' + path.name + suffix)
(out / (sources.name + '.sha256')).write_text(sha(sources) + '  ' + sources.name + '\n')
print('Built', archive, '(' + str(archive.stat().st_size) + ' bytes)')
