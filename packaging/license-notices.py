#!/usr/bin/env python3
"""Copy upstream license notices from pinned dependency sources, without unpacking code."""
import argparse
from pathlib import Path, PurePosixPath
import re
import tarfile
import zipfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--sources', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
notice = re.compile(r'^(licen[cs]e|copying|copyright|notice|authors|patents)([._-].*)?$', re.I)


def save(package, name, read):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or not notice.fullmatch(path.name):
        return
    target = a.output / package / Path(*path.parts)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(read())


for entry in sorted(a.sources.iterdir()):
    # Build recipes are provided in the source artifact, rather than collecting
    # unrelated Nixpkgs package-maintainer notices into the application bundle.
    if entry.name == 'nixpkgs-build-recipes':
        continue
    source = entry.resolve(strict=True)
    if source.is_dir():
        for path in source.rglob('*'):
            if path.is_file():
                save(entry.name, path.relative_to(source).as_posix(), path.read_bytes)
    elif tarfile.is_tarfile(source):
        with tarfile.open(source) as stream:
            for member in stream:
                if member.isfile():
                    def read():
                        with stream.extractfile(member) as content:
                            return content.read()
                    save(entry.name, member.name, read)
    elif zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as stream:
            for name in stream.namelist():
                if not name.endswith('/'):
                    save(entry.name, name, lambda: stream.read(name))
    else:
        save(entry.name, source.name, source.read_bytes)
