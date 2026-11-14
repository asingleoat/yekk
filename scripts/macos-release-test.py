#!/usr/bin/env python3
"""Mount a release DMG read-only and exercise its bundled executable."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--package', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
images = [a.package] if a.package.is_file() else list(a.package.glob('Yekk-*-macos-*.dmg'))
assert len(images) == 1, images
image = images[0].resolve(strict=True)
with tempfile.TemporaryDirectory(prefix='yekk mounted release ') as temporary:
    mount = Path(temporary) / 'volume'
    mount.mkdir()
    subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(image)],
                   check=True, capture_output=True, text=True)
    try:
        resources = mount / 'Yekk.app/Contents/Resources'
        assert (resources / 'LICENSE').is_file()
        assert json.loads((resources / 'THIRD-PARTY.json').read_text())
        notices = [path for path in (resources / 'licenses').rglob('*') if path.is_file()]
        assert notices
        env = {key: value for key, value in os.environ.items() if not key.startswith('DYLD_')}
        env['YEKK_VIEWER'] = str(mount / 'Yekk.app/Contents/MacOS/yekk')
        result = subprocess.run(['sh', 'scripts/smoke.sh'], cwd=root, env=env,
                                capture_output=True, text=True, timeout=120)
        report = dict(dmg=image.name, sha256=hashlib.sha256(image.read_bytes()).hexdigest(),
                      status=result.returncode, license_notice_files=len(notices),
                      stdout=result.stdout, stderr=result.stderr)
        a.output.parent.mkdir(parents=True, exist_ok=True)
        a.output.write_text(json.dumps(report, indent=2) + '\n')
        print(result.stdout, result.stderr)
        assert result.returncode == 0, report
    finally:
        subprocess.run(['hdiutil', 'detach', str(mount)], check=True, capture_output=True, text=True)
