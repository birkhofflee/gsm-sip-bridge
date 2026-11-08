# NixOS module for the bridge: the same unit `.#service`'s installer writes on
# other systemd hosts (nix/service.nix), declared instead. `flake` is this
# repository's flake, so the default package follows the flake input the host
# pins.
flake:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.gsm-sip-bridge;
  toml = pkgs.formats.toml { };
  unit = cfg.package.passthru;
  configFile =
    if cfg.configFile != null then cfg.configFile else toml.generate "gsm-sip-bridge.toml" cfg.settings;
in
{
  options.services.gsm-sip-bridge = {
    enable = lib.mkEnableOption "gsm-sip-bridge, bridging a SIM's calls and SMS to SIP over VoWiFi, VoLTE or GSM";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.stdenv.hostPlatform.system}.service;
      defaultText = lib.literalExpression "gsm-sip-bridge.packages.\${system}.service";
      description = "The service package: the bridge plus strongSwan, vpcd and the unit's pieces.";
    };

    settings = lib.mkOption {
      type = toml.type;
      default = { };
      example = lib.literalExpression ''
        {
          cs.enabled = false;
          vowifi = { enabled = true; modem_flight_mode = true; };
          sip_server = {
            enabled = true;
            ring_aor = "1001";
            account = [ { username = "1001"; password = "env:PHONE_1001_PASSWORD"; } ];
          };
          sms = { enabled = true; db_path = "/data/store.db"; };
        }
      '';
      description = ''
        `config.toml` as Nix (see `config.toml.example` and
        `docs/configuration.md`). It ends up in the Nix store, which any user
        can read, so give secrets as `"env:VAR"` and put the values in
        {option}`environmentFile`. Ignored when {option}`configFile` is set.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/etc/gsm-sip-bridge/config.toml";
      description = "An existing `config.toml`, used instead of {option}`settings`.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/gsm-sip-bridge.env";
      description = ''
        `KEY=value` lines for the `env:` references in the config, such as
        `docker/.env`. Give a path outside the Nix store.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the ports below. Keep them reachable from the LAN or a VPN only:
        a SIP registrar open to the internet invites toll fraud.
      '';
    };

    firewall = {
      sipPort = lib.mkOption {
        type = lib.types.port;
        default = 5060;
        description = "UDP port of `[sip_server].listen_port`.";
      };
      webuiPort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = 8080;
        description = "TCP port of `[webui].port`, or null to leave it closed.";
      };
      rtpPorts = lib.mkOption {
        type = lib.types.attrsOf lib.types.port;
        default = {
          from = 4000;
          to = 4099;
        };
        description = "UDP range the phone-facing media uses (PJSIP allocates from 4000).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.configFile != null || cfg.settings != { };
        message = "services.gsm-sip-bridge: set settings or configFile.";
      }
    ];

    # ModemManager opens the modem's AT ports and locks the bridge out.
    warnings =
      lib.optional (config.networking.modemmanager.enable or false)
        "services.gsm-sip-bridge: ModemManager is enabled and will hold the modem's AT ports; set networking.modemmanager.enable = false.";

    environment.systemPackages = [ cfg.package ];

    # Empty mount points the unit mounts over in its own namespace, and the
    # writable state behind them.
    systemd.tmpfiles.rules =
      map (d: "d ${d} 0755 root root -") unit.mountDirs
      ++ [ "f ${unit.mountFile} 0644 root root -" ]
      ++ map (d: "d ${unit.stateDir}/${d} 0755 root root -") [
        "strongswan.d"
        "swanctl"
        "reader.conf.d"
        "data"
      ]
      ++ [ "f ${unit.stateDir}/strongswan-shared.conf 0644 root root -" ];

    systemd.services.gsm-sip-bridge = {
      description = "gsm-sip-bridge (GSM, VoWiFi and VoLTE to SIP)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "systemd-tmpfiles-setup.service"
      ];
      environment = {
        GSM_SIP_BRIDGE_BIN = unit.bin;
        GSM_SIP_BRIDGE_CONFIG = "${configFile}";
      };
      # A lone setting, not NixOS's `path`: the bridge expects exactly the
      # image's tools, in this order.
      serviceConfig = {
        Type = "simple";
        Environment = [ "PATH=${unit.runtimePath}" ];
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        ExecStartPre = unit.prepare;
        ExecStart = "${unit.bin} --config ${configFile} supervise";
        PrivateTmp = true;
        BindPaths = unit.bindPaths;
        BindReadOnlyPaths = unit.bindReadOnlyPaths;
        # supervise stops its own children in order, within 60s.
        KillMode = "mixed";
        TimeoutStopSec = 90;
        Restart = "always";
        RestartSec = 5;
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedUDPPorts = [ cfg.firewall.sipPort ];
      allowedUDPPortRanges = [ cfg.firewall.rtpPorts ];
      allowedTCPPorts = lib.optional (cfg.firewall.webuiPort != null) cfg.firewall.webuiPort;
    };
  };
}
