{
  description = "gsm-sip-bridge: bridges cellular calls and SIP over GSM, VoWiFi or VoLTE";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Pins the toolchain to rust-toolchain.toml, as the Docker build and CI do.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      # ALSA, libudev and the VoWiFi tunnel tooling are Linux-only.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ rust-overlay.overlays.default ];
            }
          )
        );

      workspaceVersion = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).workspace.package.version;

      # The codec libraries PJSIP is built with; the bridge links them too.
      codecLibs = pkgs: [
        pkgs.opencore-amr
        pkgs.vo-amrwbenc
        pkgs.libopus
      ];
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          inherit (pkgs) lib;

          # PJSIP as docker/Dockerfile builds it: static, with this project's
          # config_site.h (16 kHz L16, no local-hostname lookup) and the AMR-NB,
          # AMR-WB and Opus codecs. Stock pjproject packages set neither.
          pjproject = pkgs.stdenv.mkDerivation {
            pname = "pjproject";
            version = "2.17";

            src = pkgs.fetchzip {
              url = "https://github.com/pjsip/pjproject/archive/refs/tags/2.17.tar.gz";
              hash = "sha256-n7J7+l+DVNSHZdmoBTYN6Lx++3CXwtUwvgzPiR2+Teg=";
            };

            nativeBuildInputs = [ pkgs.pkg-config ];
            buildInputs = [
              pkgs.openssl
              pkgs.alsa-lib
              pkgs.libuuid
            ]
            ++ codecLibs pkgs;

            postPatch = ''
              cp ${./docker/pjsip-config-site.h} pjlib/include/pj/config_site.h
              patchShebangs .
            '';

            # The bridge links these archives into a position-independent binary.
            env.CFLAGS = "-fPIC";

            # pjproject links through $(LD) and expects the compiler driver
            # there; stdenv's LD=ld leaves libc off the link line.
            preConfigure = ''
              export LD="$CC"
            '';

            configureFlags = [
              "--disable-shared"
              "--enable-static"
              "--disable-video"
              "--disable-v4l2"
              "--with-external-pa=no"
              "--with-opencore-amr=${lib.getDev pkgs.opencore-amr}"
              "--with-opencore-amrwbenc=${lib.getDev pkgs.vo-amrwbenc}"
              "--with-opus=${lib.getDev pkgs.libopus}"
            ];

            # configure drops a codec silently when it cannot find its library,
            # which would only show at runtime as a missing codec.
            postConfigure = ''
              for m in PJMEDIA_HAS_OPENCORE_AMRNB_CODEC PJMEDIA_HAS_OPENCORE_AMRWB_CODEC PJMEDIA_HAS_OPUS_CODEC; do
                grep -Eq "#define $m[[:space:]]+1" pjmedia/include/pjmedia-codec/config_auto.h \
                  || { echo "pjproject configure did not enable $m" >&2; exit 1; }
              done
            '';

            preBuild = "make dep";
            enableParallelBuilding = true;

            meta = {
              description = "PJSIP built for gsm-sip-bridge";
              homepage = "https://www.pjsip.org";
              license = lib.licenses.gpl2Plus;
              platforms = lib.platforms.linux;
            };
          };

          toolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = toolchain;
            rustc = toolchain;
          };

          gsm-sip-bridge = rustPlatform.buildRustPackage {
            pname = "gsm-sip-bridge";
            version = workspaceVersion;

            # Only what the build reads, so docs or local config changes do not
            # trigger a rebuild. docker/strongswan holds a template that
            # supervise/render.rs compiles in.
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./Cargo.toml
                ./Cargo.lock
                ./rust-toolchain.toml
                ./pjsua-sys
                ./pjsua-safe
                ./amr-sys
                ./amr-safe
                ./siptest
                ./gsm-sip-bridge
                ./docker/strongswan
              ];
            };

            cargoLock.lockFile = ./Cargo.lock;

            nativeBuildInputs = [
              pkgs.pkg-config
              # Sets LIBCLANG_PATH and the clang include path for pjsua-sys's bindgen.
              rustPlatform.bindgenHook
            ];
            buildInputs = [
              pjproject
              pkgs.openssl
              pkgs.alsa-lib
              pkgs.libuuid
              pkgs.udev
              pkgs.pcsclite
            ]
            ++ codecLibs pkgs;

            # Link the PJSIP archives, as the Docker build does.
            env.PJSUA_SYS_STATIC = "1";

            cargoBuildFlags = [
              "--package"
              "gsm-sip-bridge"
              "--bin"
              "gsm-sip-bridge"
              "--features"
              "gsm-sip-bridge/pjsip-linked,gsm-sip-bridge/amr-linked"
            ];

            # The suite runs through `make test` in the dev shell; it exercises
            # the build without the linked features, so it would not test this
            # derivation's binary anyway.
            doCheck = false;

            meta = {
              description = "Bridges cellular calls and SIP/VoIP over GSM, VoWiFi or VoLTE";
              license = lib.licenses.mit;
              mainProgram = "gsm-sip-bridge";
              platforms = lib.platforms.linux;
            };
          };
          strongswan-epdg = pkgs.callPackage ./nix/strongswan-epdg.nix { };
          vpcd = pkgs.callPackage ./nix/vpcd.nix { };
          service = pkgs.callPackage ./nix/service.nix {
            inherit gsm-sip-bridge strongswan-epdg vpcd;
          };
        in
        {
          inherit
            pjproject
            gsm-sip-bridge
            strongswan-epdg
            vpcd
            service
            ;
          default = gsm-sip-bridge;
        }
      );

      # services.gsm-sip-bridge; see nix/nixos-module.nix and docs/development.md.
      nixosModules.default = import ./nix/nixos-module.nix self;

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.gsm-sip-bridge ];
          packages = [
            pkgs.gnumake
            pkgs.cargo-nextest
            pkgs.cargo-deny
            pkgs.shellcheck
          ];
          env.PJSUA_SYS_STATIC = "1";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
