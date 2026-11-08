# vsmartcard's virtual PC/SC reader, as docker/Dockerfile builds it: the pcscd
# driver that strongSwan's eap-sim-pcsc talks to and that `vowifi-usim-bridge`
# serves over TCP. Eight slots, one per possible VoWiFi line.
{
  lib,
  stdenv,
  fetchgit,
  autoreconfHook,
  pkg-config,
  python3,
  help2man,
  pcsclite,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "vpcd";
  version = "0-unstable-809675d";

  src = fetchgit {
    url = "https://github.com/frankmorgner/vsmartcard.git";
    rev = "809675dc982addfc3fdb8cbaf177e4430477b0b2";
    # fetchgit fetches submodules by default. vsmartcard's belong to the
    # Android app, ccid and the Windows installer, none of which this build
    # touches, and the hash below is of the checkout without them.
    fetchSubmodules = false;
    hash = "sha256-I44XrC7v1G9hxaZ9zDlyUVPaSEx5HUAvDRBGsC8DYDs=";
  };
  sourceRoot = "${finalAttrs.src.name}/virtualsmartcard";

  nativeBuildInputs = [
    autoreconfHook
    pkg-config
    python3
    help2man
  ];
  buildInputs = [ pcsclite ];

  configureFlags = [
    "--enable-serialdropdir=${placeholder "out"}/lib/pcsc/drivers/serial"
    "--enable-serialconfdir=${placeholder "out"}/etc/reader.conf.d"
    "--enable-vpcdslots=8"
  ];

  # Only the reader and its pcscd driver, not the vicc/vpicc test clients.
  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES -C src/vpcd
    make -j$NIX_BUILD_CORES -C src/ifd-vpcd
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    make -C src/vpcd install
    make -C src/ifd-vpcd install
    runHook postInstall
  '';

  meta = {
    description = "Virtual PC/SC reader driver (vsmartcard vpcd)";
    homepage = "https://github.com/frankmorgner/vsmartcard";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
  };
})
