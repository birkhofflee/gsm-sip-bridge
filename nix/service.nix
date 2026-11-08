# Runs the bridge as docker/docker-compose.yml's gsm-sip-bridge service does,
# as a systemd unit on a non-NixOS host.
#
# supervise expects the image's layout: charon at /usr/libexec/ipsec, writable
# /etc/strongswan.d, /etc/swanctl and /etc/reader.conf.d, the vpcd driver under
# /usr/lib/pcsc, the store at /data and its own /tmp. The unit mounts those over
# the host paths inside its own mount namespace only, backed by the Nix store
# (read-only parts) and /var/lib/gsm-sip-bridge (writable parts). On the host
# itself the installer adds only empty mount points for them.
{
  lib,
  writeShellApplication,
  writeShellScript,
  runCommand,
  symlinkJoin,
  coreutils,
  util-linux,
  iproute2,
  iputils,
  procps,
  gnugrep,
  gnused,
  gawk,
  findutils,
  bash,
  pcsclite,
  systemd,
  gsm-sip-bridge,
  strongswan-epdg,
  vpcd,
}:

let
  bin = "${gsm-sip-bridge}/bin/gsm-sip-bridge";

  # What the image's runtime stage installs beside the binary.
  runtimePackages = [
    gsm-sip-bridge
    strongswan-epdg
    pcsclite.out
    iproute2
    iputils
    procps
    coreutils
    util-linux
    gnugrep
    gnused
    gawk
    findutils
    bash
  ];
  runtimePath = lib.concatMapStringsSep ":" (p: "${p}/bin:${p}/sbin") runtimePackages;

  # /etc/strongswan.d and /etc/swanctl as the image has them: strongSwan's own
  # defaults with this repo's files on top (docker/Dockerfile, runtime stage).
  etc = runCommand "gsm-sip-bridge-etc" { } ''
    mkdir -p $out/strongswan.d $out/swanctl/conf.d
    cp -r ${strongswan-epdg}/etc/strongswan.d/. $out/strongswan.d/
    chmod -R u+w $out/strongswan.d
    s=${../docker/strongswan}
    cp $s/charon-logging.conf $s/charon-extra.conf $s/swanctl-epdg.conf.template $out/strongswan.d/
    cp $s/p-cscf.conf $s/resolve.conf $out/strongswan.d/charon/
    install -m 755 $s/ims.updown $out/strongswan.d/ims.updown
    cp $s/swanctl.conf $out/swanctl/swanctl.conf
  '';

  stateDir = "/var/lib/gsm-sip-bridge";

  # Runs inside the unit's namespace, after the mounts: starts every run from
  # the packaged files, as a recreated container does.
  prepare = writeShellScript "gsm-sip-bridge-prepare" ''
    set -eu
    PATH=${
      lib.makeBinPath [
        coreutils
        findutils
      ]
    }
    for d in /etc/strongswan.d /etc/swanctl /etc/reader.conf.d; do
      find "$d" -mindepth 1 -delete
    done
    cp -r --no-preserve=mode ${etc}/strongswan.d/. /etc/strongswan.d/
    chmod 755 /etc/strongswan.d/ims.updown
    cp -r --no-preserve=mode ${etc}/swanctl/. /etc/swanctl/
    : > /etc/strongswan-shared.conf
  '';

  # Writable state mounted over the image paths.
  bindPaths = [
    "${stateDir}/strongswan.d:/etc/strongswan.d"
    "${stateDir}/swanctl:/etc/swanctl"
    "${stateDir}/reader.conf.d:/etc/reader.conf.d"
    "${stateDir}/strongswan-shared.conf:/etc/strongswan-shared.conf"
    "${stateDir}/data:/data"
  ];
  bindReadOnlyPaths = [
    "${strongswan-epdg}/libexec/ipsec:/usr/libexec/ipsec"
    "${vpcd}/lib/pcsc:/usr/lib/pcsc"
  ];
  # Created empty on the host by the installer; the unit mounts over them.
  mountDirs = [
    "/etc/strongswan.d"
    "/etc/swanctl"
    "/etc/reader.conf.d"
    "/usr/libexec/ipsec"
    "/usr/lib/pcsc"
    "/data"
  ];
  mountFile = "/etc/strongswan-shared.conf";

  install = writeShellApplication {
    name = "gsm-sip-bridge-install";
    runtimeInputs = [
      coreutils
      systemd
    ];
    text = ''
      usage() {
        cat <<'USAGE'
      Usage: gsm-sip-bridge-install --config PATH --env-file PATH [--import-docker-data DIR]
             gsm-sip-bridge-install --uninstall

      Installs gsm-sip-bridge.service (enabled, not started). Run as root.
        --config PATH              config.toml to run with (absolute path)
        --env-file PATH            file of KEY=value secrets, like docker/.env
        --import-docker-data DIR   copy an existing /data (for example the
                                   compose volume's _data directory) into the
                                   service's empty state; stop that container first
        --uninstall                stop and remove the unit and the empty mount
                                   points; keeps ${stateDir}
      USAGE
      }

      [ "$(id -u)" = 0 ] || { echo "gsm-sip-bridge-install: run as root" >&2; exit 1; }
      unit=/etc/systemd/system/gsm-sip-bridge.service
      # The unit points into the Nix store; this root keeps those paths
      # from being garbage-collected while it is installed. This script's
      # closure holds every one of them.
      gcroot=/nix/var/nix/gcroots/gsm-sip-bridge-service

      if [ "''${1:-}" = --uninstall ]; then
        systemctl disable --now gsm-sip-bridge.service 2>/dev/null || true
        rm -f "$unit" "$gcroot"
        systemctl daemon-reload
        f=${lib.escapeShellArg mountFile}
        [ -f "$f" ] && [ ! -s "$f" ] && rm -f "$f"
        for d in ${lib.escapeShellArgs mountDirs}; do
          rmdir "$d" 2>/dev/null || true
        done
        echo "removed gsm-sip-bridge.service; state kept in ${stateDir}"
        exit 0
      fi

      config="" envfile="" import=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --config) config="$2"; shift 2 ;;
          --env-file) envfile="$2"; shift 2 ;;
          --import-docker-data) import="$2"; shift 2 ;;
          -h|--help) usage; exit 0 ;;
          *) usage >&2; exit 2 ;;
        esac
      done
      [ -n "$config" ] && [ -n "$envfile" ] || { usage >&2; exit 2; }
      config=$(realpath -e "$config")
      envfile=$(realpath -e "$envfile")

      for d in ${lib.escapeShellArgs mountDirs}; do
        mkdir -p "$d"
      done
      f=${lib.escapeShellArg mountFile}
      [ -e "$f" ] || : > "$f"
      mkdir -p ${stateDir}/strongswan.d ${stateDir}/swanctl ${stateDir}/reader.conf.d ${stateDir}/data
      [ -e ${stateDir}/strongswan-shared.conf ] || : > ${stateDir}/strongswan-shared.conf

      if [ -n "$import" ]; then
        if [ -n "$(ls -A ${stateDir}/data)" ]; then
          echo "not importing: ${stateDir}/data is not empty" >&2
        else
          # Not -a: the container's uids mean nothing on the host.
          cp -r --preserve=timestamps "$import"/. ${stateDir}/data/
          chown -R root:root ${stateDir}/data
          echo "imported $import into ${stateDir}/data"
        fi
      fi

      cat > "$unit" <<UNIT
      [Unit]
      Description=gsm-sip-bridge (GSM, VoWiFi and VoLTE to SIP)
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=simple
      Environment=PATH=${runtimePath}
      Environment=GSM_SIP_BRIDGE_BIN=${bin}
      Environment=GSM_SIP_BRIDGE_CONFIG=$config
      EnvironmentFile=$envfile
      ExecStartPre=${prepare}
      ExecStart=${bin} --config $config supervise
      PrivateTmp=yes
      BindPaths=${lib.concatStringsSep " " bindPaths}
      BindReadOnlyPaths=${lib.concatStringsSep " " bindReadOnlyPaths}
      # supervise stops its own children in order, within 60s; SIGTERM goes to
      # it alone, and everything left is killed only after this timeout
      # (docker-compose.yml's stop_grace_period).
      KillMode=mixed
      TimeoutStopSec=90
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
      UNIT

      ln -sfn "$(dirname "$(dirname "$(readlink -f "$0")")")" "$gcroot"

      systemctl daemon-reload
      systemctl enable gsm-sip-bridge.service
      echo "installed $unit (enabled, not started)"
      echo "start it with: systemctl start gsm-sip-bridge"
    '';
  };

  # Runs a bridge subcommand inside the service's namespace, where its /tmp
  # state lives: gsm-sip-bridge-ctl vowifi-status, healthcheck, sms-status.
  ctl = writeShellApplication {
    name = "gsm-sip-bridge-ctl";
    runtimeInputs = [
      systemd
      util-linux
      coreutils
    ];
    text = ''
      [ "$(id -u)" = 0 ] || { echo "gsm-sip-bridge-ctl: run as root" >&2; exit 1; }
      pid=$(systemctl show -p MainPID --value gsm-sip-bridge.service)
      [ "$pid" != 0 ] || { echo "gsm-sip-bridge.service is not running" >&2; exit 1; }
      config=$(systemctl show -p Environment --value gsm-sip-bridge.service | tr ' ' '\n' | sed -n 's/^GSM_SIP_BRIDGE_CONFIG=//p')
      exec nsenter --target "$pid" --mount -- ${bin} --config "$config" "$@"
    '';
  };
in
symlinkJoin {
  name = "gsm-sip-bridge-service";
  paths = [
    install
    ctl
  ];
  # The unit's pieces, for nix/nixos-module.nix, so the NixOS service and the
  # installer's unit cannot drift apart.
  passthru = {
    inherit
      etc
      prepare
      bin
      runtimePath
      stateDir
      bindPaths
      bindReadOnlyPaths
      mountDirs
      mountFile
      ;
  };
  meta = {
    description = "Installer and control wrapper for running gsm-sip-bridge under systemd";
    platforms = lib.platforms.linux;
  };
}
