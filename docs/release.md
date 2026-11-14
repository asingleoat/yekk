# Release packaging

Complete local builds and tests before hosted builds. GitHub workflows are
disabled. Enabling them and publishing releases require manual approval.

| Target | Package | Runtime checks |
| --- | --- | --- |
| macOS 14+, ARM64 | DMG | Native ARM64 |
| macOS 14+, x86_64 | DMG | Record native Intel or Rosetta coverage |
| Linux x86_64 | tar.gz | Desktop, relocation and isolation |
| Linux aarch64 | tar.gz | Best effort; runtime unverified |

An aarch64 asset must build successfully. Label its unverified runtime status.
ARM hardware tests do not block the release.

## macOS

```sh
nix develop path:. -c zig build test dmg -Doptimize=ReleaseSafe -Dcpu=baseline
nix develop path:. -c python3 scripts/macos-release-test.py \
  --package dist --output dist/macos-release-validation.json
```

Give `--package` one DMG path or a directory containing one DMG.
Packaging writes checksums and provenance, audits library paths and tests
relocation without Nix library paths. The release test mounts the DMG read-only,
tests its viewer and detaches it.

Packages use local ad-hoc signatures without Developer ID or notarization.
Downloaded apps may require Gatekeeper approval on first launch.
Intel macOS uses a separate locked Nixpkgs Darwin branch with the same Zig master.

## Linux

```sh
nix build path:.#linux-release --out-link result-release --cores 4
nix develop path:. -c python3 scripts/linux-release-test.py \
  --package result-release --isolate --output dist/linux-release-validation.json
```

`--isolate` requires an ordinary Linux distribution with `/usr/bin/python3` and
`/usr/bin/bwrap`. It hides `/nix` and tests the relocated archive.
On NixOS, run under `steam-run` without `--isolate`.

Add `--isolate-sudo` to `--isolate` where namespace setup needs privileges. Tests drop to the
caller before execution. `--minimal-root PATH_TO_STATIC_BUSYBOX` provides a
separate decoder-only check without Nix or host libraries.

Extract `yekk-VERSION-linux-ARCH.tar.gz`. Run `./yekk`, or `steam-run ./yekk`
on NixOS. Keep `lib`, `libexec` and `share` together.

Core SDL, libvips, libtiff and LittleCMS libraries link statically. The archive
includes remaining shared libraries and the matching glibc loader.
It needs host graphics drivers and desktop services, but no Nix installation.
It is a directory distribution, not a single static executable.

## Release contents

Include these files:

- Platform binaries and SHA-256 files.
- `LICENSE`, dependency notices and `THIRD-PARTY.json`.
- Companion library-source archives with pinned sources, vendor inputs and build recipes.
- The project source archive and exact commit identity.
- Runtime-unverified labels for best-effort targets.

Generate the project archive from the release commit. Keep dependency sources
and Nixpkgs recipes with the release. Do not reuse an older source archive.

Run the [validation checks](validation.md) on mounted or extracted packages.
Record architecture, OS, display backend, hashes and test limits under `dist/`.
Test actual viewing on the intended desktop. Publish after manual review.
