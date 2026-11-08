# gsm-sip-bridge

[![CI](https://github.com/selvakn/gsm-sip-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/selvakn/gsm-sip-bridge/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/selvakn/gsm-sip-bridge)](RELEASE_NOTES.md)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

Put a SIM in a box on your network and its calls and texts show up in your
home phone system. Calls to the SIM's number ring your Asterisk or FreePBX
setup, or a SIP phone. Your PBX can also dial out through the SIM.

<!-- TODO(maintainer): one or two lines in your own words: why you built this. -->

<p align="center">
  <img src="screenshots/how-it-works.svg" alt="A carrier delivers calls over GSM voice, VoWiFi or VoLTE to gsm-sip-bridge, which hands them to your PBX or SIP phones over SIP" width="820">
</p>

> **Personal and hobby use only.** Cellular-to-VoIP gateways are regulated or
> banned in many countries, and may break your carrier's terms.
> Read the [disclaimer](DISCLAIMER.md) before you plug anything in.

## About this fork

This fork of [selvakn/gsm-sip-bridge](https://github.com/selvakn/gsm-sip-bridge)
adds the following on top of upstream `v8.25.0`. Every addition is opt-in or
keeps upstream's default behaviour unless noted.

| Area | What it adds |
|---|---|
| **Telegram** | SMS forwarding to a Telegram chat (`[sms].telegram_bot_token`, `telegram_chat_id`) as an alternative to Discord, with the same retry and late-delivery handling. Critical alerts go to Telegram too, reusing the SMS bot unless `[alerts]` sets its own. |
| **VoWiFi registration** | `[vowifi].access_network_info` sets the `P-Access-Network-Info` header the bridge sends to the carrier. Some carriers reject the hard-coded `3GPP-WLAN`. |
| **Keypad (DTMF)** | `[vowifi].offer_telephone_event` adds `telephone-event` to outbound calls, so menu keypresses reach the carrier. |
| **Flight mode** | `[vowifi].modem_flight_mode` keeps the modem's radio off (`AT+CFUN=4`), at startup and after every SIM recovery. VoWiFi only needs the SIM, and a roaming modem no longer attaches to the visited network. |
| **Missed-call alert** | Now fires for VoWiFi and VoLTE calls, not only GSM ones. |
| **Startup** | When auto-discovery finds no line at startup, the bridge keeps retrying instead of running without VoWiFi until restarted. It logs why each modem was turned away, and the health check reports a turned-away modem as unhealthy. |
| **Web UI** | Shows the line's own number as the network reports it at registration, so it no longer needs `msisdn` in config. |
| **Nix** | `flake.nix` builds the bridge, PJSIP, the patched strongSwan and `vpcd`. `.#service` runs the whole stack as a systemd unit without Docker, and `nixosModules.default` provides `services.gsm-sip-bridge`. See [Building with Nix](docs/development.md#building-with-nix). |

### Tested on a Quectel EG25-G

Tested on one setup:
- **Modem:** a Quectel EG25-G, sold as the DJI "Baiwang" 4G module, firmware `QDC507GLEFM21`, with its USB ID set to `2c7c:0125`. The bridge detects it as an EC20.
- **SIM:** Chunghwa Telecom (Taiwan).
- **Connection:** VoWiFi, roaming from Italy.
- **Host:** an aarch64 Ubuntu VM, running both the Docker image and the Nix systemd service.

| Works | Notes |
|---|---|
| ePDG tunnel and IMS registration | EAP-AKA over the modem's `AT+CSIM`, including in flight mode |
| Outbound calls | Two-way audio, with keypad menus |
| Inbound calls | To [Telephone](https://www.64characters.com/telephone/) on macOS. Linphone Desktop 6.2 registered but never rang; see [Operations](docs/operations.md) |
| Incoming SMS | Stored, shown in the web UI, and forwarded to Telegram |
| Missed-call alert | Delivered to Telegram |
| Recovery | SIM recovery, startup retry when no line is found, and a cold start after a reboot |

Not tested on this setup: GSM voice, VoLTE, outgoing SMS, and the other
critical alert categories.

### NixOS

```nix
# flake.nix of the host
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.gsm-sip-bridge.url = "github:birkhofflee/gsm-sip-bridge";

  outputs = { nixpkgs, gsm-sip-bridge, ... }: {
    nixosConfigurations.bridge = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ./configuration.nix
        gsm-sip-bridge.nixosModules.default
        {
          services.gsm-sip-bridge = {
            enable = true;
            configFile = ./config.toml;   # or `settings = { ... }`
            environmentFile = "/var/lib/secrets/gsm-sip-bridge.env";
            openFirewall = true;          # SIP 5060/udp, web UI 8080/tcp, media 4000-4099/udp
          };
          networking.modemmanager.enable = false;
        }
      ];
    };
  };
}
```

Keep secrets as `env:VAR` references in the config, with their values in
`environmentFile`. Anything in `settings` or `configFile` is copied into the
Nix store, which every user on the host can read.

## What you need

- **A Linux machine.** Any x86 box or a Raspberry Pi (arm64).
- **A SIM**, in a Quectel EC20/EC200 modem *or* a plain USB smart-card reader.
  A card reader is enough for Wi-Fi Calling; no modem needed.
- **Something to ring.** A PBX such as Asterisk or FreePBX, or just a
  softphone. The bridge can act as the SIP server itself.

## Three ways a call can arrive

| Path | How it reaches the bridge | Hardware |
|---|---|---|
| **GSM voice** | The modem answers and streams audio over USB | Quectel EC20 |
| **VoWiFi** | An IPsec tunnel to the carrier over your own internet connection | EC20, EC200, or a USB card reader |
| **VoLTE** | IMS over the modem's LTE data connection | EC20 or EC200 |

The carrier decides which path a call takes, and you can enable any mix of
them. VoWiFi and VoLTE run one line per SIM, so several numbers can share one
bridge. [Supported hardware](docs/supported-hardware.md) has the details and
the one-time modem setup.

## What you get

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="screenshots/webui-overview-dark.png">
    <img src="screenshots/webui-overview-light.png" alt="The web UI overview: three lines, each healthy, with registration, signal and active calls" width="820">
  </picture>
</p>

- **Calls in both directions.** Inbound calls are answered and handed to your
  PBX with the caller's number. Outbound calling is opt-in.
- **HD voice over VoWiFi.** Wideband audio (AMR-WB in, G.722 out) stays
  wideband end to end.
- **SMS** on every path, stored locally and optionally posted to Discord or Telegram.
- **A read-only web UI** for line health, call history and messages. It also
  shows one-time codes with a copy button.
- **Alerts** to Discord or Telegram when a line drops or recovers, plus Prometheus
  metrics and a Grafana dashboard.
- **Recovers by itself** from USB disconnects, lost registrations and stuck
  modems.

<details>
<summary>The SMS page</summary>
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="screenshots/webui-sms-dark.png">
    <img src="screenshots/webui-sms-light.png" alt="The web UI SMS page, with a one-time code pulled out and a copy button" width="820">
  </picture>
</p>
</details>

[Everything it does](docs/features.md) is listed in full in the docs.

## Quick start (Docker Compose)

Set up your modem first if you have one (enable USB audio, keep
ModemManager off it): see [supported hardware](docs/supported-hardware.md).

```bash
git clone https://github.com/selvakn/gsm-sip-bridge && cd gsm-sip-bridge/docker
cp ../config.toml.example config.toml   # add your PBX details
echo "SIP_PASSWORD=yourpassword" > .env
docker compose up -d
```

That starts the bridge along with Prometheus, Grafana and a read-only database
browser. The minimum config is the PBX the bridge should register to:

```toml
[sip]
server = "pbx.example.com"
username = "bridge-account"
password = "env:SIP_PASSWORD"
```

Turn on what you need with `[vowifi]`, `[volte]`, `[outbound]` and `[webui]`.
[`sample_configs/`](sample_configs/README.md) has a ready-made config for each
common setup, and the [configuration reference](docs/configuration.md) covers
every key.

## How it works

The bridge doesn't just pass along audio the modem has already decoded. For
VoWiFi it builds the IKEv2 tunnel to the carrier's ePDG itself, authenticates
to the IMS core with the SIM's own AKA keys, and protects SIP with Gm IPsec.
For VoLTE it does the same over the modem's LTE data connection, bypassing
the modem's own voice stack. It speaks SIP and RTP itself, transcoding AMR-WB
to G.722 between the two legs.

It's written in Rust. FFI is kept to two small crates, for PJSIP and the AMR
codecs. [Architecture](docs/architecture.md) walks through the call flows, the
audio pipeline and the per-line network namespaces.

<details>
<summary>More documentation</summary>

| | |
|---|---|
| **Set up** | [Supported hardware](docs/supported-hardware.md) · [Configuration](docs/configuration.md) · [Sample configs](sample_configs/README.md) |
| **Run** | [Operations and troubleshooting](docs/operations.md) · [Metrics and dashboards](docs/observability.md) |
| **Understand** | [Architecture](docs/architecture.md) · [VoWiFi bridge](docs/vowifi-bridge.md) · [Card-reader VoWiFi](docs/omnikey-pcsc-vowifi.md) · [Host-side VoLTE](docs/operations.md#host-side-ims-over-lte-volte) |
| **Build** | [Building from source](docs/development.md) · [Migrating from v4.1.x](docs/migrating-from-v4.1.x.md) |

[docs/README.md](docs/README.md) is the full index. `docs/` is also mirrored to
the wiki.
</details>

## Community

Questions, setups to show off, and ideas go in
[Discussions](https://github.com/selvakn/gsm-sip-bridge/discussions). Bugs go
in [Issues](https://github.com/selvakn/gsm-sip-bridge/issues). Support is
volunteer and best-effort.

## Acknowledgements

The VoWiFi bridge builds on work by the [Osmocom](https://osmocom.org/)
project: their
[VoWiFi with Asterisk](https://osmocom.org/projects/foss-ims-client/wiki/VoWiFi_with_Asterisk)
research, the `strongswan-epdg` fork, and sysmocom's VoLTE/Gm-IPsec Asterisk
patches mapped out the ePDG, IMS-AKA and Gm IPsec ground this project stands
on. Thank you.

---

GPL-3.0. Not affiliated with Quectel, Sangoma, FreePBX or any carrier.
See the [disclaimer](DISCLAIMER.md).
