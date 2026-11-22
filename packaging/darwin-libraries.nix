{ pkgs, zigObjc, nixpkgsSource, zig }:
let
  lib = pkgs.lib;
  packages = (with pkgs; [ libtiff zlib libdeflate libjpeg lerc xz zstd libwebp libjxl libraw brotli libhwy lcms2 gettext zig ])
    ++ lib.optional pkgs.stdenv.hostPlatform.isAarch64 pkgs.llvmPackages.openmp;
  architecture = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64";
  sources = pkgs.linkFarm "yekk-macos-library-sources" (map (package: {
    name = package.pname;
    path = package.src;
  }) packages ++ [
    { name = "zig-objc"; path = zigObjc; }
    { name = "nixpkgs-build-recipes"; path = nixpkgsSource; }
  ] ++ lib.optionals pkgs.stdenv.hostPlatform.isAarch64 [
    { name = "yekk-libraw-ahd.patch"; path = ./libraw-ahd.patch; }
    { name = "yekk-libraw-locality.patch"; path = ./libraw-locality.patch; }
  ]);
  metadata = pkgs.writeText "yekk-macos-dependencies.json" (builtins.toJSON (
    map (package: {
      name = package.pname;
      version = package.version;
      homepage = package.meta.homepage or "";
      licenses = map (license: license.spdxId or license.shortName)
        (lib.toList package.meta.license);
    }) packages ++ [{ name = "zig-objc"; version = zigObjc.rev; licenses = [ "MIT" ]; }]
  ));
in pkgs.runCommand "yekk-macos-release-dependencies" {
  nativeBuildInputs = [ pkgs.python3 ];
} ''
  mkdir -p "$out/licenses"
  python3 ${./license-notices.py} --sources ${sources} --output "$out/licenses"
  cp ${metadata} "$out/THIRD-PARTY.json"
  python3 - ${sources} "$out" <<'PY'
  from pathlib import Path
  import hashlib, sys, tarfile
  sources, output = map(Path, sys.argv[1:])
  archive = output / 'yekk-macos-${architecture}-library-sources.tar.gz'
  with tarfile.open(archive, 'w:gz') as stream:
      for path in sorted(sources.iterdir()):
          stream.add(path.resolve(strict=True), arcname='library-sources/' + path.name)
  archive.with_suffix('.gz.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
  PY
''
