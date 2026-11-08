# strongSwan for the VoWiFi tunnel, as docker/Dockerfile builds it: osmocom's
# strongswan-epdg fork (P-CSCF attribute request, USIM AKA over PC/SC) at the
# same pinned commit, plus this repo's vici `dpd` patch, with only the plugins
# the bridge uses.
{
  lib,
  stdenv,
  fetchgit,
  autoreconfHook,
  pkg-config,
  bison,
  flex,
  gperf,
  gettext,
  perl,
  python3,
  openssl,
  pcsclite,
}:

stdenv.mkDerivation {
  pname = "strongswan-epdg";
  version = "5.9-epdg-022f3e5";

  src = fetchgit {
    url = "https://gitea.osmocom.org/ims-volte-vowifi/strongswan-epdg.git";
    rev = "022f3e515b2c7b607def0fbbf1d7b9b1df08fb8c";
    hash = "sha256-Go2AeCq8PjAPBd2F+vf0IKlR8Ysa+nVJNHxzn1HO9so=";
  };

  patches = [ ../docker/patches/0002-strongswan-vici-dpd.patch ];

  nativeBuildInputs = [
    autoreconfHook
    pkg-config
    bison
    flex
    gperf
    gettext
    perl
    python3
  ];
  buildInputs = [
    openssl
    pcsclite
  ];

  # gettext 1.0 keeps AC_LIB_PREFIX and friends in share/gettext/m4, outside
  # aclocal's search path; the Dockerfile passes the same -I.
  autoreconfFlags = [
    "--install"
    "--force"
    "--verbose"
    "-I"
    "${gettext}/share/gettext/m4"
  ];

  # The code base is gnu17; a C23 default breaks its callback prototypes.
  env.CFLAGS = "-fPIC -std=gnu17";

  # Runtime config lives under /etc, as in the image; supervise points charon
  # at its own rendered file through STRONGSWAN_CONF.
  configureFlags = [
    "--sysconfdir=/etc"
    "--disable-defaults"
    "--enable-charon"
    "--enable-ikev2"
    "--enable-swanctl"
    "--enable-vici"
    "--enable-eap-aka"
    "--enable-eap-sim"
    "--enable-eap-sim-pcsc"
    "--enable-eap-identity"
    "--enable-p-cscf"
    "--enable-openssl"
    "--enable-random"
    "--enable-nonce"
    "--enable-hmac"
    "--enable-socket-default"
    "--enable-kernel-netlink"
    "--enable-resolve"
    "--enable-updown"
    "--enable-stroke"
  ];

  # Install the default config tree into the package instead of /etc.
  installFlags = [
    "sysconfdir=${placeholder "out"}/etc"
    "strongswan_conf=${placeholder "out"}/etc/strongswan.conf"
    "swanctldir=${placeholder "out"}/etc/swanctl"
  ];

  enableParallelBuilding = true;

  meta = {
    description = "strongSwan with osmocom's ePDG changes, built for gsm-sip-bridge";
    homepage = "https://gitea.osmocom.org/ims-volte-vowifi/strongswan-epdg";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
  };
}
