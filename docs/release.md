# Release packaging

Attach tested portable binaries.
Complete local builds and tests before using hosted builds.
GitHub workflows are disabled. Enabling them and publishing releases require
manual approval.

## Targets and test coverage

Build a separate package for each operating system and CPU architecture.
Record which runtime tests were performed on each package.

| Target | Package | Runtime checks |
| --- | --- | --- |
| macOS 14+, ARM64 | DMG disk image | Run on Apple Silicon. |
| macOS 14+, x86_64 | DMG disk image | Record whether execution used Intel hardware or Rosetta. |
| Linux x86_64 | Compressed tar archive | Test viewing, relocation and filesystem isolation. |
| Linux ARM64 (aarch64) | Compressed tar archive | Best effort. Record VM and physical desktop checks separately. |

Rosetta runs Intel programs on Apple Silicon. Its results do not establish
native Intel hardware coverage. An aarch64 package must build successfully.
Label the runtime checks that were possible. ARM hardware tests do not block
the release.

## macOS

A DMG is a disk image containing `Yekk.app` and license information.
Mounting it makes those files available as a volume.

```sh
nix develop path:. -c zig build test dmg -Doptimize=ReleaseFast -Dcpu=baseline
nix develop path:. -c python3 scripts/macos-release-test.py \
  --package dist --output dist/macos-release-validation.json
```

`-Dcpu=baseline` selects the application's baseline CPU instruction set.
Run the mounted-image check once per DMG. `--package` accepts one DMG path or
a directory containing one DMG.

Packaging records checksums and library versions. It checks the paths used to
find shared libraries and tests the app from a different directory without Nix
library paths. The release test mounts the DMG read-only, tests its viewer and
detaches the volume afterward.

Packages use local ad-hoc code signatures without a signing certificate.
They have no Apple Developer ID signature or notarization.
Downloaded apps may require macOS first-launch approval.
Intel macOS uses a separate locked Nixpkgs Darwin branch with the same Zig master.

## Linux

```sh
nix build path:.#linux-release --out-link result-release --cores 4
nix develop path:. -c python3 scripts/linux-release-test.py \
  --package result-release --isolate --output dist/linux-release-validation.json
```

The test extracts the archive into a different directory before launching it.
This checks that it does not depend on its original installation path.

`--isolate` requires an ordinary Linux distribution with `/usr/bin/python3` and
`/usr/bin/bwrap`. Bubblewrap gives the test a separate filesystem view with
`/nix` hidden. On NixOS, run under `steam-run` without `--isolate`.

If filesystem-namespace setup needs privileges, add `--isolate-sudo`.
Setup uses sudo, then runs tests as the calling user.
`--minimal-root PATH_TO_STATIC_BUSYBOX` instead creates a minimal filesystem
without Nix or host libraries. This tests decoding only, not desktop presentation.
The argument must name a statically linked BusyBox executable.

Extract `yekk-VERSION-linux-ARCH.tar.gz`. Run `./yekk`, or `steam-run ./yekk`
on NixOS. Keep `lib`, `libexec` and `share` beside the launcher.
`VERSION` is the release version; `ARCH` is `x86_64` or `aarch64`.

Static linking places library code inside the executable. The Linux executable
contains the core SDL, libvips, libtiff and LittleCMS libraries.
Other shared libraries remain separate files in the archive.
The bundled glibc loader starts the executable with these matching libraries.
Host graphics drivers and desktop services are still required.
This is a directory distribution, not a single static executable.

## Release contents

Include `LICENSE`, dependency notices and `THIRD-PARTY.json` in each package.
The Git tag identifies the exact source, including Nix inputs and patches.
The flake's `release-sources` output contains the pinned dependency sources
and Nixpkgs build recipes. Record runtime coverage in the release notes.

Run the [validation checks](validation.md) on mounted or extracted packages.
Store architecture, OS, display backend, file hashes and untested cases under `dist/`.
Test viewing on the intended desktop. Tag the tested commit and publish after
manual review.
