{ pkgs, libraw, nixpkgsSource, zig }:
let
  lib = pkgs.lib;
  # --static consults Requires.private even for a library that ultimately stays
  # shared. Supply its development metadata transitively, rather than maintaining
  # a second handwritten copy of each library's private dependency graph.
  entry = package: { key = package.drvPath; inherit package; };
  privateMetadata = map (item: item.package) (builtins.genericClosure {
    # x265's pinned recipe records its NUMA library as a native build input.
    startSet = map entry (with pkgs; [
      glib pango libheif libjxl numactl libimagequant cgif
      libexif libhwy libxml2 expat fontconfig
    ]);
    operator = item: map entry (lib.filter lib.isDerivation (
      (item.package.buildInputs or []) ++ (item.package.propagatedBuildInputs or [])
    ));
  });
  static = package: overrides: (package.override ({
    stdenv = pkgs.stdenvAdapters.makeStaticLibraries pkgs.stdenv;
  } // overrides)).overrideAttrs { doCheck = false; };
  zlib = static pkgs.zlib {};
  libdeflate = static pkgs.libdeflate {};
  libjpeg = static pkgs.libjpeg {};
  libpng = static pkgs.libpng { inherit zlib; };
  libwebp = static pkgs.libwebp { inherit libjpeg libpng; tiffSupport = false; };
  lcms2 = static pkgs.lcms2 { inherit zlib libjpeg libtiff; };
  libtiff = static pkgs.libtiff { inherit zlib libjpeg libwebp; };
  sdl3 = (static pkgs.sdl3 {}).overrideAttrs (old: {
    # Nix's SDL patches hardcode store paths for runtime drivers and Zenity.
    # A portable build must discover those on the destination machine.
    postPatch = "";
    cmakeFlags = lib.filter (flag: !(lib.hasPrefix "-DSDL_DEPS_SHARED" flag)) old.cmakeFlags ++ [
      "-DSDL_STATIC=ON" "-DSDL_SHARED=OFF" "-DSDL_DEPS_SHARED=ON"
      "-DSDL_TESTS=OFF" "-DSDL_INSTALL_TESTS=OFF"
      "-DSDL_AUDIO=OFF" "-DSDL_CAMERA=OFF" "-DSDL_JOYSTICK=OFF"
      "-DSDL_HAPTIC=OFF" "-DSDL_SENSOR=OFF" "-DSDL_TRAY=OFF"
    ];
    postInstall = ''mkdir -p "$installedTests"'';
    postFixup = "";
  });
  vips = (static pkgs.vips {
    inherit libjpeg libpng libwebp libtiff lcms2;
    withIntrospection = false;
    withDevDoc = false;
    # Only the application's catalog formats and text renderer are needed.
    cfitsio = null; fftw = null; libarchive = null; libraw = null;
    librsvg = null; libultrahdr = null; matio = null; openexr = null;
    openjpeg = null; openslide = null; poppler = null;
    imagemagick = null; libjxl = null;
  }).overrideAttrs (old: {
    buildInputs = old.buildInputs ++ privateMetadata;
    mesonFlags = old.mesonFlags ++ [
      "-Dmodules=disabled" "-Dcplusplus=false" "-Ddeprecated=false"
      "-Dprefer_static=true" "-Dexamples=false"
      # Keep the native Radiance reader so floating input reaches our existing
      # sample-format rejection, rather than Magick silently normalizing it.
      "-Dauto_features=disabled"
    ] ++ map (name: "-D${name}=enabled") [
      "cgif" "exif" "fontconfig" "heif" "imagequant" "jpeg"
      "lcms" "highway" "pangocairo" "png" "tiff" "webp" "zlib"
    ];
    postFixup = "";
  });
  dependencies = [ sdl3 vips libtiff lcms2 libdeflate zlib libjpeg libpng libwebp pkgs.libx11 pkgs.libxi pkgs.libxext pkgs.libxfixes libraw ] ++ privateMetadata;
  sourcePackages = dependencies ++ [ pkgs.glibc pkgs.stdenv.cc.cc pkgs.dejavu_fonts zig ];
  sourceInputs = lib.unique (lib.concatMap (package:
    lib.optional (package ? src && lib.isDerivation package.src) package.src
    ++ lib.optional (package ? cargoDeps && lib.isDerivation package.cargoDeps) package.cargoDeps
  ) sourcePackages);
in {
  inherit sdl3 vips libtiff lcms2 dependencies;
  metadata = pkgs.writeText "yekk-dependencies.json" (builtins.toJSON (map (package: {
    name = package.pname or package.name;
    version = package.version or "";
    library = builtins.unsafeDiscardStringContext (toString (package.lib or package.out or package));
    homepage = package.meta.homepage or "";
    licenses = map (license: if builtins.isAttrs license then license.spdxId or license.shortName or "unknown" else toString license)
      (lib.toList (package.meta.license or []));
  }) sourcePackages));
  librarySources = pkgs.linkFarm "yekk-library-sources" (map (source: {
    name = builtins.unsafeDiscardStringContext (builtins.baseNameOf (toString source));
    path = source;
  }) sourceInputs ++ [{ name = "nixpkgs-build-recipes"; path = nixpkgsSource; }]
    ++ lib.optional pkgs.stdenv.hostPlatform.isx86_64 {
      name = "yekk-libraw-ahd.patch";
      path = ./libraw-ahd.patch;
    });
}
