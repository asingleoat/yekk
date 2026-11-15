#!/usr/bin/env python3
"""Relocate the native app's dylib closure, sign, audit and build a local DMG."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, default=root / 'zig-out/Yekk.app')
p.add_argument('--output', type=Path)
p.add_argument('--dependency-assets', type=Path, default=os.environ.get('YEKK_DARWIN_RELEASE_ASSETS'))
a = p.parse_args()
if a.dependency_assets is None:
    p.error('dependency notices and sources are required; build in nix develop')
source = a.app.resolve(strict=True)
with (source / 'Contents/Info.plist').open('rb') as stream:
    bundle = plistlib.load(stream)
    version = bundle['CFBundleShortVersionString']
    minimum_macos = bundle['LSMinimumSystemVersion']
architecture = subprocess.check_output(['/usr/bin/lipo', '-archs', str(source / 'Contents/MacOS/yekk')], text=True).strip()
suffix = architecture if ' ' not in architecture else 'universal2'
output = (a.output or root / 'dist' / f'Yekk-{version}-macos-{suffix}.dmg').resolve()
output.parent.mkdir(parents=True, exist_ok=True)
def run(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT, **kwargs)
def copy_output(source, destination):
    # Nix inputs are read-only. Publish writable artifacts atomically so repeat
    # builds can replace them and an interrupted copy preserves the old result.
    descriptor, pending = tempfile.mkstemp(prefix='.yekk-release-', dir=destination.parent)
    os.close(descriptor)
    try:
        shutil.copyfile(source, pending)
        os.chmod(pending, 0o644)
        os.replace(pending, destination)
    finally:
        Path(pending).unlink(missing_ok=True)
def dependencies(path):
    return [line.strip().split(' (', 1)[0] for line in run('/usr/bin/otool', '-L', path).splitlines()[1:] if ' (' in line]
def rpaths(path):
    lines = run('/usr/bin/otool', '-l', path).splitlines()
    return list(dict.fromkeys(lines[i+2].strip().split(' (', 1)[0].removeprefix('path ') for i, line in enumerate(lines) if line.strip() == 'cmd LC_RPATH'))
def system(path): return path.startswith(('/System/Library/', '/usr/lib/'))
def deployment_versions(path):
    command = None
    versions = []
    for line in run('/usr/bin/otool', '-l', path).splitlines():
        fields = line.split()
        if fields[:1] == ['cmd']: command = fields[1]
        if fields and ((command == 'LC_BUILD_VERSION' and fields[0] == 'minos') or
                       (command == 'LC_VERSION_MIN_MACOSX' and fields[0] == 'version')):
            versions.append(fields[1])
    return versions
def version_tuple(value): return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])
def resolve(dep, owner, executable):
    candidates = [dep]
    if dep.startswith('@rpath/'):
        candidates = [base + dep[len('@rpath'):] for base in rpaths(owner) + rpaths(executable)]
    for item in candidates:
        item = item.replace('@loader_path', str(owner.parent)).replace('@executable_path', str(executable.parent))
        path = Path(item)
        if path.is_absolute() and path.is_file(): return path.resolve()
    raise RuntimeError(f'unresolved dependency {dep} in {owner}')
with tempfile.TemporaryDirectory(prefix='yekk-dmg-') as temporary:
    stage = Path(temporary) / 'volume'; stage.mkdir()
    app = stage / 'Yekk.app'; shutil.copytree(source, app, symlinks=True)
    # Nix package directories are read-only; only the staging copy is modified.
    for directory in [app, *app.rglob('*')]:
        if directory.is_dir() and not directory.is_symlink():
            directory.chmod(directory.stat().st_mode | 0o200)
    executable = source / 'Contents/MacOS/yekk'
    copied_executable = app / 'Contents/MacOS/yekk'
    libraries = app / 'Contents/Frameworks'; libraries.mkdir(exist_ok=True)
    queue = [(executable, copied_executable)]
    copied = {}; names = {}; provenance = []
    while queue:
        original, target = queue.pop(0)
        if target.is_symlink():
            target.unlink(); shutil.copy2(original.resolve(), target)
        target.chmod(target.stat().st_mode | 0o200)
        for dep in dependencies(original):
            if system(dep): continue
            resolved = resolve(dep, original, executable)
            # dylib IDs appear as the first otool -L entry too.
            if resolved == original.resolve(): continue
            if resolved not in copied:
                name = Path(dep).name
                if name in names and names[name] != resolved: raise RuntimeError(f'library name collision: {name}')
                names[name] = resolved; copied[resolved] = libraries / name
                shutil.copy2(resolved, copied[resolved]); copied[resolved].chmod(0o755)
                queue.append((resolved, copied[resolved]))
                provenance.append(dict(name=name, source=str(resolved), sha256=hashlib.sha256(resolved.read_bytes()).hexdigest()))
            run('/usr/bin/install_name_tool', '-change', dep, '@rpath/' + copied[resolved].name, target)
        for path in rpaths(target):
            if path.startswith('/nix/store/'):
                run('/usr/bin/install_name_tool', '-delete_rpath', path, target)
        if target != copied_executable:
            run('/usr/bin/install_name_tool', '-id', '@rpath/' + target.name, target)
    run('/usr/bin/install_name_tool', '-add_rpath', '@executable_path/../Frameworks', copied_executable)
    resources = app / 'Contents/Resources'; resources.mkdir(exist_ok=True)
    shutil.copy2(root / 'LICENSE', resources / 'LICENSE')
    shutil.copytree(a.dependency_assets / 'licenses', resources / 'licenses', dirs_exist_ok=True)
    shutil.copy2(a.dependency_assets / 'THIRD-PARTY.json', resources / 'THIRD-PARTY.json')
    (resources / 'bundled-libraries.json').write_text(json.dumps(provenance, indent=2) + '\n')
    for path in [*copied.values(), copied_executable]:
        if any(version_tuple(value) > version_tuple(minimum_macos) for value in deployment_versions(path)):
            raise RuntimeError(f'{path.name} requires a newer macOS than the declared {minimum_macos}')
        for dep in dependencies(path):
            if not system(dep) and not (dep.startswith('@rpath/') and (libraries / Path(dep).name).is_file()):
                raise RuntimeError(f'nonportable load command {dep} in {path}')
        if any('/nix/store/' in item for item in rpaths(path)): raise RuntimeError('Nix rpath survived relocation')
    for path in [*copied.values(), app]:
        # Relocating Mach-O load commands invalidates their local signatures.
        # Apple Silicon requires ad-hoc signatures; no publisher identity or
        # signing credential is used and no notarization is performed.
        run('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', path)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    env = {key: value for key, value in os.environ.items() if not key.startswith('DYLD_')}
    env['DYLD_PRINT_LIBRARIES'] = '1'
    loaded = run(copied_executable, '--version', env=env)
    if '/nix/store/' in loaded: raise RuntimeError('relocated app loaded a Nix library at runtime')
    (stage / 'Applications').symlink_to('/Applications')
    (stage / 'Read Me.txt').write_text('Drag Yekk.app to Applications.\nAd-hoc development builds are not notarized.\n')
    with (app / 'Contents/Info.plist').open('rb') as stream: version = plistlib.load(stream)['CFBundleShortVersionString']
    temporary_dmg = Path(temporary) / 'Yekk.dmg'
    run('/usr/bin/hdiutil', 'create', '-volname', 'Yekk', '-srcfolder', stage, '-format', 'UDZO', temporary_dmg)
    run('/usr/bin/hdiutil', 'verify', temporary_dmg)
    copy_output(temporary_dmg, output)
    manifest = dict(version=version, license='GPL-3.0-or-later', dmg=output.name, sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                    signing='ad-hoc (no publisher identity)', notarized=False, minimum_macos=minimum_macos, libraries=provenance,
                    executable_archs=run('/usr/bin/lipo', '-archs', copied_executable).strip())
    output.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    output.with_suffix('.dmg.sha256').write_text(manifest['sha256'] + '  ' + output.name + '\n')
    for path in a.dependency_assets.glob('*.tar.gz*'):
        copy_output(path, output.parent / path.name)
    print(f'Built {output} ({output.stat().st_size} bytes)')
