# Preparing a release

Build architecture-specific artifacts with baseline CPU settings. Test extracted or
mounted packages rather than relying on a working Nix-store executable. Complete local
builds and qualification before enabling hosted builds. The checked-in GitHub workflows
are disabled. Enable workflows only after a separate manual decision. Publication also
requires a manual decision.

| Target | Artifact | Qualification |
| --- | --- | --- |
| macOS 14+, ARM64 | DMG | Native runtime checks |
| macOS 14+, x86_64 | DMG | Record native Intel or Rosetta coverage explicitly |
| Linux x86_64 | tar.gz | Desktop checks, relocation and runtime isolation |
| Linux aarch64 | tar.gz | Best effort; runtime unverified until tested on ARM hardware |

An aarch64 release asset must build successfully. State its unverified runtime status
beside the asset. ARM hardware qualification does not block the release. Build success
alone is not runtime verification.

## macOS

```sh
nix develop path:. -c zig build test dmg -Doptimize=ReleaseSafe -Dcpu=baseline
nix develop path:. -c python3 scripts/macos-release-test.py \
  --package dist --output dist/macos-release-validation.json
```

Give the test a directory that contains one target DMG. Alternatively, give the test the
DMG path. Packaging writes the DMG, provenance/checksum manifest and SHA-256 file. The
app carries dylibs with relative load commands. Packaging verifies the image, audits
load commands and launches the relocated executable without Nix library paths. The
release test mounts the DMG read-only.

It tests the bundled viewer and then detaches the DMG.

No Developer ID certificate or notarization is used. Local ad-hoc Mach-O signatures
carry no publisher identity and are required on Apple Silicon after load-command
changes. A downloaded app may require first-launch Gatekeeper approval. No Apple account
credentials are needed for packaging.

The DMG includes `LICENSE`, dependency notices and `THIRD-PARTY.json`. The companion
`yekk-macos-ARCH-library-sources.tar.gz` contains pinned library sources, Objective-C
binding sources and Nixpkgs build recipes. Intel macOS uses a separately locked Nixpkgs
Darwin branch. All targets use the same Zig master.

## Linux

```sh
nix build path:.#linux-release --out-link result-release --cores 4
nix develop path:. -c python3 scripts/linux-release-test.py \
  --package result-release --isolate --output dist/linux-release-validation.json
```

Run `--isolate` on an ordinary Linux distribution with `/usr/bin/python3` and
`/usr/bin/bwrap` (bubblewrap). It hides `/nix` in a private mount namespace and tests
the archive after relocation into a path containing spaces and shell metacharacters.
Checks include decoding, fit/actual-size views, cached navigation, damaged input and
literal hook arguments. Namespace-restricted test hosts can use `--isolate-sudo`, which
drops privileges before running the tests. On NixOS, run under `steam-run` without
`--isolate`.

`--minimal-root PATH_TO_STATIC_BUSYBOX` supplies a separate decoder-only portability
check with neither `/nix` nor host shared libraries. It does not replace ordinary
desktop, input or GPU validation.

Extract `yekk-VERSION-linux-ARCH.tar.gz`. Run `./yekk`. On NixOS, run `steam-run
./yekk`. Keep `lib`, `libexec` and `share` together. Core SDL, libvips, libtiff and
LittleCMS libraries link statically. The archive includes the remaining shared libraries
and the matching glibc loader.

The launcher locates its directory at runtime, so the build path and Nix are
unnecessary. Graphics drivers and desktop services still come from the host. This is a
relocatable directory distribution, not a fully static single ELF file.

The archive includes licenses and dependency metadata. Its separate
`-library-sources.tar.gz` includes pinned dependency sources and build recipes, and is
substantially larger than the runtime archive.

## Qualification and publication

Run the relevant [regression and stability checks](validation.md), including closing
with work in flight, hooks, source replacement and pressure recovery. Record
architecture, OS, display backend, executable/source hashes and validation limits in
local reports under `dist/`. Keep timing diagnostics separate from performance
acceptance claims. Inspect image viewing from the mounted DMG and relocated Linux
archive on the intended runtime environments.

Include these with each release:

- Platform/architecture binaries and their SHA-256 files.
- `LICENSE`, dependency notices and `THIRD-PARTY.json`.
- Companion library-source archives, including pinned sources, vendor inputs
and Nixpkgs build/patch recipes.
- The exact project source archive and commit identity for the artifacts.
- Explicit runtime-unverified labels for best-effort targets.

Yekk uses GPL-3.0-or-later. Bundled dependencies keep their own licenses. Static library
distribution requires preserving the corresponding source and build materials provided
by the packaging tools. Generate the project source archive from the release commit. Do
not reuse an archive from an older candidate. Keep local validation reports outside
tracked documentation.

Publication remains a manual step after reviewing the artifacts.
