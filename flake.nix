{
  description = "Yekk — native asynchronous image viewer";
  inputs = {
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # nix develop resolves Bash through the input named nixpkgs as well. Keep
    # that input usable on Intel, which 26.11 removed; other targets use unstable.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    zig-objc = { url = "github:mitchellh/zig-objc"; flake = false; };
  };
  outputs = { self, nixpkgs, nixpkgs-unstable, zig-overlay, zig-objc }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      nixpkgsFor = system: if system == "x86_64-darwin" then nixpkgs else nixpkgs-unstable;
      pkgsFor = system: (nixpkgsFor system).legacyPackages.${system};
      zigFor = system: (if system == "x86_64-darwin" then
        (import zig-overlay { nixpkgs = nixpkgsFor system; pkgs = pkgsFor system; inherit system; }).master
        else zig-overlay.packages.${system}.master).overrideAttrs (old: {
        # The pinned master's command builder retains a slice into a temporary
        # target query. Copy it before that query leaves scope (visible on ARM).
        # zig-overlay disables fixup and its custom install phase omits hooks.
        installPhase = old.installPhase + ''
          substituteInPlace "$out/lib/compiler/Maker/Step/Compile.zig" \
            --replace-fail 'zig_args.appendAssumeCapacity(dynamic_linker_path);' \
            'zig_args.appendAssumeCapacity(try arena.dupe(u8, dynamic_linker_path));'
        '';
      });
      linuxLibc = pkgs: pkgs.runCommand "yekk-libc.conf" {
        nativeBuildInputs = [ pkgs.stdenv.cc ];
      } ''
        cat > "$out" <<EOF
        include_dir=${pkgs.lib.getDev pkgs.glibc}/include
        sys_include_dir=${pkgs.lib.getDev pkgs.glibc}/include
        cc_dir=$(dirname "$($CC -print-file-name=crtbegin.o)")
        crt_dir=$(dirname "$($CC -print-file-name=crt1.o)")
        msvc_lib_dir=
        kernel32_lib_dir=
        darwin_sdk_dir=
        EOF
      '';
      linuxLibgcc = pkgs: pkgs.runCommand "yekk-libgcc.a" {
        nativeBuildInputs = [ pkgs.stdenv.cc ];
      } ''
        cp "$($CC -print-libgcc-file-name)" "$out"
      '';
    in {
      packages = eachSystem (system:
        let pkgs = pkgsFor system; in rec {
          default = yekk;
          yekk = pkgs.stdenvNoCC.mkDerivation {
            pname = "yekk";
            version = "0.2.1";
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./build.zig ./build.zig.zon ./src ./LICENSE
                (pkgs.lib.fileset.fileFilter (file: !(file.hasExt "pyc") && file.name != ".DS_Store") ./tests)
                (pkgs.lib.fileset.fileFilter (file: !(file.hasExt "pyc") && file.name != ".DS_Store") ./packaging)
              ];
            };
            nativeBuildInputs = [ (zigFor system) ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.pkg-config pkgs.makeWrapper pkgs.desktop-file-utils ];
            buildInputs = [ pkgs.libtiff pkgs.libdeflate pkgs.zlib ] ++ (if pkgs.stdenv.hostPlatform.isDarwin then [ pkgs.apple-sdk ] else [ pkgs.sdl3 pkgs.vips pkgs.libjxl pkgs.lcms2 pkgs.libx11 pkgs.libxi pkgs.libxext pkgs.libxfixes ]);
            YEKK_TIFF_LIB = "${pkgs.lib.getLib pkgs.libtiff}/lib";
            YEKK_TIFF_INCLUDE = "${pkgs.lib.getDev pkgs.libtiff}/include";
            YEKK_DEFLATE_INCLUDE = "${pkgs.lib.getDev pkgs.libdeflate}/include";
            YEKK_DEFLATE_LIB = "${pkgs.lib.getLib pkgs.libdeflate}/lib";
            YEKK_ZLIB_INCLUDE = "${pkgs.lib.getDev pkgs.zlib}/include";
            YEKK_ZLIB_LIB = "${pkgs.lib.getLib pkgs.zlib}/lib";
            SDKROOT = if pkgs.stdenv.hostPlatform.isDarwin then "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" else "";
            YEKK_LINUX_LOADER = if pkgs.stdenv.hostPlatform.isLinux then pkgs.stdenv.cc.bintools.dynamicLinker else "";
            YEKK_LIBC = if pkgs.stdenv.hostPlatform.isLinux then "${linuxLibc pkgs}" else "";
            YEKK_FONT_FILE = if pkgs.stdenv.hostPlatform.isLinux then "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf" else "";
            YEKK_OBJC = "${zig-objc}";
            strictDeps = true;
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/yekk-zig-global"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/yekk-zig-local"
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
              zig build -j"$NIX_BUILD_CORES" -Doptimize=ReleaseFast -Dcpu=baseline --prefix "$out"
              runHook postBuild
            '';
            doCheck = true;
            checkPhase = ''
              zig build test -j"$NIX_BUILD_CORES" -Doptimize=ReleaseFast -Dcpu=baseline
              zig build test -j"$NIX_BUILD_CORES" -Doptimize=ReleaseSafe -Dcpu=baseline
            '';
            postFixup = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
              substituteInPlace "$out/share/applications/yekk.desktop" \
                --replace-fail 'Exec=yekk %F' "Exec=$out/bin/yekk %F"
              desktop-file-validate "$out/share/applications/yekk.desktop"
              wrapProgram "$out/bin/yekk" \
                --set-default XDG_DATA_DIRS /usr/local/share:/usr/share \
                --prefix XDG_DATA_DIRS : "${pkgs.shared-mime-info}/share" \
                --prefix PATH : "${pkgs.zenity}/bin" \
                --set YEKK_ENTRY_EXECUTABLE "$out/bin/yekk"
            '';
            dontInstall = true;
            meta.platforms = systems;
            meta.mainProgram = "yekk";
            meta.license = pkgs.lib.licenses.gpl3Plus;
          };
        } // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          linux-release-unwrapped = let
            libraries = import ./packaging/linux-libraries.nix { inherit pkgs; nixpkgsSource = nixpkgs-unstable; zig = zigFor system; };
          in self.packages.${system}.yekk.overrideAttrs (old: {
            pname = "yekk-linux-release";
            nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.python3 pkgs.patchelf pkgs.binutils (pkgs.lib.getBin pkgs.glibc) ];
            buildInputs = libraries.dependencies;
            YEKK_TIFF_LIB = "${pkgs.lib.getLib libraries.libtiff}/lib";
            YEKK_TIFF_INCLUDE = "${pkgs.lib.getDev libraries.libtiff}/include";
            YEKK_FONT_FILE = "";
            YEKK_CXX_LIBRARY = "${pkgs.stdenv.cc.cc.lib}/lib/libstdc++.so";
            # GCC-built ARM archives use outlined atomics from its static
            # runtime. Zig's compiler-rt does not provide the GCC sync variants.
            YEKK_GCC_RUNTIME = if pkgs.stdenv.hostPlatform.isAarch64 then "${linuxLibgcc pkgs}" else "";
            # Build-input edges sometimes explicitly select a dev output. ELF
            # libraries live in lib/out instead; getLib intentionally preserves
            # explicitly selected outputs, so normalize them before that call.
            YEKK_RELEASE_LIB_DIRS = pkgs.lib.makeLibraryPath (
              map (package: package.lib or package.out or package) libraries.dependencies
              ++ [ pkgs.stdenv.cc.cc.lib ]
            );
            buildPhase = ''
              runHook preBuild
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/yekk-zig-global"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/yekk-zig-local"
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS YEKK_FONT_FILE
              zig build -j"$NIX_BUILD_CORES" -Doptimize=ReleaseFast -Dcpu=baseline -Dportable-linux=true --prefix "$out"
              runHook postBuild
            '';
            checkPhase = ''
              zig build test -j"$NIX_BUILD_CORES" -Doptimize=ReleaseFast -Dcpu=baseline -Dportable-linux=true
              zig build test -j"$NIX_BUILD_CORES" -Doptimize=ReleaseSafe -Dcpu=baseline -Dportable-linux=true
            '';
            postFixup = "";
            dontPatchELF = true;
            dontStrip = true;
            dontAutoPatchelf = true;
          });
          linux-release = let
            libraries = import ./packaging/linux-libraries.nix { inherit pkgs; nixpkgsSource = nixpkgs-unstable; zig = zigFor system; };
            binary = self.packages.${system}.linux-release-unwrapped;
          in pkgs.runCommand "yekk-linux-release-0.2.1" {
            nativeBuildInputs = [ pkgs.python3 pkgs.patchelf pkgs.binutils (pkgs.lib.getBin pkgs.glibc) ];
            meta.platforms = pkgs.lib.platforms.linux;
          } ''
              python3 ${./scripts/package-linux.py} --binary "${binary}/bin/yekk" \
                --output "$out" --font ${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf \
                --mime ${pkgs.shared-mime-info}/share/mime \
                --source ${binary.src} --dependency-sources ${libraries.librarySources} \
                --dependency-metadata ${libraries.metadata} --version 0.2.1
          '';
        });
      devShells = eachSystem (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = [ (zigFor system) pkgs.libtiff pkgs.libdeflate pkgs.zlib pkgs.python3 ] ++ (if pkgs.stdenv.hostPlatform.isDarwin then [ pkgs.apple-sdk ] else [ pkgs.pkg-config pkgs.sdl3 pkgs.vips pkgs.libjxl pkgs.lcms2 pkgs.libx11 pkgs.libxi pkgs.libxext pkgs.libxfixes pkgs.shared-mime-info pkgs.procps pkgs.dbus pkgs.xorg-server pkgs.xdotool pkgs.zenity pkgs.weston pkgs.openbox pkgs.xdg-desktop-portal pkgs.xdg-desktop-portal-gtk pkgs.patchelf pkgs.binutils pkgs.strace pkgs.bubblewrap ]);
            YEKK_TEST_PORTAL = if pkgs.stdenv.hostPlatform.isLinux then "${pkgs.xdg-desktop-portal}" else "";
            YEKK_TEST_PORTAL_GTK = if pkgs.stdenv.hostPlatform.isLinux then "${pkgs.xdg-desktop-portal-gtk}" else "";
            YEKK_LINUX_LOADER = if pkgs.stdenv.hostPlatform.isLinux then pkgs.stdenv.cc.bintools.dynamicLinker else "";
            YEKK_LIBC = if pkgs.stdenv.hostPlatform.isLinux then "${linuxLibc pkgs}" else "";
            YEKK_FONT_FILE = if pkgs.stdenv.hostPlatform.isLinux then "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf" else "";
            YEKK_OBJC = "${zig-objc}";
            # Production RGB16 TIFF backend and the optional paging probe.
            YEKK_DARWIN_RELEASE_ASSETS = if pkgs.stdenv.hostPlatform.isDarwin then
              "${import ./packaging/darwin-libraries.nix { inherit pkgs; zigObjc = zig-objc; nixpkgsSource = nixpkgsFor system; zig = zigFor system; }}" else "";
            YEKK_TIFF_LIB = "${pkgs.lib.getLib pkgs.libtiff}/lib";
            YEKK_TIFF_INCLUDE = "${pkgs.lib.getDev pkgs.libtiff}/include";
            YEKK_DEFLATE_INCLUDE = "${pkgs.lib.getDev pkgs.libdeflate}/include";
            YEKK_DEFLATE_LIB = "${pkgs.lib.getLib pkgs.libdeflate}/lib";
            YEKK_ZLIB_INCLUDE = "${pkgs.lib.getDev pkgs.zlib}/include";
            YEKK_ZLIB_LIB = "${pkgs.lib.getLib pkgs.zlib}/lib";
            shellHook = ''
              export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
              # Zig discovers the pinned SDK via SDKROOT/xcrun. Nix flags
              # otherwise disable Zig's Darwin SDK discovery.
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            '';
          };
        });
    };
}
