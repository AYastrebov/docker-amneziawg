# Docker AmneziaWG

[![Docker Build](https://github.com/AYastrebov/docker-amneziawg/actions/workflows/docker-build.yml/badge.svg)](https://github.com/AYastrebov/docker-amneziawg/actions/workflows/docker-build.yml)
[![GitHub Container Registry](https://img.shields.io/badge/ghcr.io-docker--amneziawg-blue?logo=docker)](https://github.com/AYastrebov/docker-amneziawg/pkgs/container/docker-amneziawg)
[![GitHub release](https://img.shields.io/github/v/release/AYastrebov/docker-amneziawg)](https://github.com/AYastrebov/docker-amneziawg/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

[AmneziaWG](https://docs.amnezia.org/) VPN container that generates configs, manages peers, and prints QR codes. Based on [LinuxServer.io](https://www.linuxserver.io/) base images with s6-overlay.

AmneziaWG extends WireGuard with traffic obfuscation to bypass Deep Packet Inspection (DPI). AWG 2.0 (default) auto-generates all obfuscation parameters including Custom Protocol Signatures (I1-I5), so you don't need to configure them manually.

## Supported Architectures

| Architecture | Available |
|:---:|:---:|
| x86-64 | amd64 |
| arm64 | aarch64 |

## Application Setup

The container runs in two modes:

- **Server mode** — set `PEERS` to auto-generate server config, peer configs, and QR codes
- **Client mode** — place `.conf` files in `./config/wg_confs/` (no `PEERS` needed)

### Kernel Module

For best performance, install the [AmneziaWG kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) on your host (or rely on the in-tree `wireguard` module that ships with most modern kernels). The container auto-detects kernel support and falls back to the `amneziawg-go` userspace implementation when no module is loaded. `SYS_MODULE` is **not** required to use the kernel datapath — the container never calls `modprobe`. See the Parameters table below for when (if ever) you might want it.

### AWG Protocol Version

| Version | When to Use |
|---------|-------------|
| `2.0` (default) | Full DPI evasion with I1-I5 signatures. Requires AmneziaVPN app 4.8.12.9+ |
| `1.5` | Legacy compatibility with older clients. No I1-I5, S3=S4=0 |

Set via `AWG_VERSION` environment variable. All obfuscation parameters are randomized automatically — override only if you need specific values (e.g., to match an existing setup).

## Usage

### Docker Compose (recommended)

```yaml
services:
  amneziawg:
    image: ghcr.io/ayastrebov/docker-amneziawg:latest
    container_name: amneziawg
    cap_add:
      - NET_ADMIN
      # - SYS_MODULE  # rarely needed — see Parameters table
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - SERVERURL=vpn.example.com
      - SERVERPORT=51820 #optional
      - PEERS=laptop,phone,tablet
      - PEERDNS=auto #optional
      - INTERNAL_SUBNET=10.13.13.0 #optional
      - ALLOWEDIPS=0.0.0.0/0, ::/0 #optional
      - PERSISTENTKEEPALIVE_PEERS=all #optional
      - LOG_CONFS=true #optional
      # - AWG_VERSION=2.0 #optional
    volumes:
      - ./config:/config
    ports:
      - 51820:51820/udp
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

### Docker CLI

```bash
docker run -d \
  --name amneziawg \
  --cap-add NET_ADMIN \
  `# --cap-add SYS_MODULE  rarely needed; see Parameters table` \
  --device /dev/net/tun:/dev/net/tun \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  -e SERVERURL=vpn.example.com \
  -e PEERS=3 \
  -p 51820:51820/udp \
  -v ./config:/config \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --restart unless-stopped \
  ghcr.io/ayastrebov/docker-amneziawg:latest
```

### Client Mode

```bash
# Place your .conf file(s) in ./config/wg_confs/ and start:
docker run -d \
  --name amneziawg \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -v ./config:/config \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --restart unless-stopped \
  ghcr.io/ayastrebov/docker-amneziawg:latest
```

## Parameters

| Parameter | Function |
|-----------|----------|
| `-p 51820:51820/udp` | WireGuard port |
| `-e PUID=1000` | User ID for file ownership |
| `-e PGID=1000` | Group ID for file ownership |
| `-e TZ=Etc/UTC` | Timezone ([list](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones#List)) |
| `-e SERVERURL=auto` | Server URL/IP for peer configs. `auto` detects external IP |
| `-e SERVERPORT=51820` | Port advertised to peers. Use ≤ 9999 if your ISP blocks high UDP ports |
| `-e PEERS=3` | Number or comma-separated names (`laptop,phone`). Enables server mode |
| `-e PEERDNS=auto` | DNS for peers. `auto` = container's CoreDNS at subnet.1 |
| `-e INTERNAL_SUBNET=10.13.13.0` | VPN subnet (.1 = server, .2+ = peers) |
| `-e ALLOWEDIPS=0.0.0.0/0, ::/0` | Peer AllowedIPs |
| `-e PERSISTENTKEEPALIVE_PEERS=` | Which peers get keepalive: `all` or comma-separated names/numbers |
| `-e SERVER_ALLOWEDIPS_PEER_X=` | Per-peer server AllowedIPs for site-to-site VPN |
| `-e LOG_CONFS=true` | Show generated configs and QR codes in container logs |
| `-e USE_COREDNS=true` | Enable/disable built-in CoreDNS. Defaults to `true` in server mode, `false` in client mode. Auto-disables when port 53 is already bound unless explicitly set. **Warning:** setting `false` in server mode breaks DNS for peers that use `PEERDNS=auto` (the default) — set `PEERDNS` to a public resolver like `1.1.1.1` if you disable CoreDNS |
| `-e AWG_VERSION=2.0` | Protocol version: `2.0` (default, full DPI evasion) or `1.5` (legacy) |
| `-v /config` | Persistent config volume |
| `--cap-add NET_ADMIN` | Required for tunnel management |
| `--cap-add SYS_MODULE` | Usually not needed. The container does **not** load kernel modules itself — it only checks whether `wireguard`/`amneziawg` is already loaded on the host. Keep `SYS_MODULE` only on minimal hosts that don't auto-load iptables NAT modules. |
| `--sysctl net.ipv4.ip_forward=1` | Enable IP forwarding |
| `--device /dev/net/tun` | TUN device access |

### AmneziaWG Obfuscation Parameters

All parameters are optional — random values are generated automatically. Server and all clients must use identical values.

| Parameter | Default | Constraints |
|-----------|---------|-------------|
| `-e AWG_JC=` | Random 3-8 | Junk packet count (1-128) |
| `-e AWG_JMIN=` | Random 40-80 | Min junk size in bytes. Must be < JMAX |
| `-e AWG_JMAX=` | Random 80-250 | Max junk size in bytes (max 1280) |
| `-e AWG_S1=` | Random 15-150 | Init padding bytes (max 1132). S1+56 must not equal S2 |
| `-e AWG_S2=` | Random 15-150 | Response padding bytes (max 1188) |
| `-e AWG_S3=` | Random 8-55 (2.0) / 0 (1.5) | Cookie padding bytes (max 64) |
| `-e AWG_S4=` | Random 4-27 (2.0) / 0 (1.5) | Transport padding bytes (max 32). Per-packet overhead — keep small |
| `-e AWG_H1=` | Auto range (2.0) / int (1.5) | Header obfuscation. H1-H4 must be unique, all >= 5 |
| `-e AWG_H2=` | Auto range (2.0) / int (1.5) | AWG 2.0 uses range format (e.g. `90666522-140666522`) |
| `-e AWG_H3=` | Auto range (2.0) / int (1.5) | Single integers cause the Amnezia app to report AWG 1.5 |
| `-e AWG_H4=` | Auto range (2.0) / int (1.5) | |
| `-e AWG_I1=` | Auto QUIC Initial (2.0) / empty (1.5) | Custom Protocol Signature packet. See [CPS tag reference](#custom-protocol-signatures-i1-i5) |
| `-e AWG_I2=` | empty | Requires I1 to be set |
| `-e AWG_I3=` | empty | |
| `-e AWG_I4=` | empty | |
| `-e AWG_I5=` | empty | |

### Custom Protocol Signatures (I1-I5)

AWG 2.0 sends CPS packets before handshakes to masquerade VPN traffic as another UDP protocol. I1 is auto-generated as a QUIC Initial packet (RFC 9000) by default.

| Tag | Description | Example |
|-----|-------------|---------|
| `<b 0xHEX>` | Static hex bytes | `<b 0x170303>` |
| `<r N>` | N random bytes | `<r 32>` |
| `<rd N>` | N random digits | `<rd 8>` |
| `<rc N>` | N random chars (a-zA-Z) | `<rc 16>` |
| `<t>` | 32-bit Unix timestamp | |

Use [AmneziaWG Architect](https://architect.vai-rice.space/) to generate custom CPS configs for QUIC, DNS, DTLS, SIP, HTTP/3 and more.

### Custom SERVERPORT

The container always listens on port 51820 internally. When using a custom `SERVERPORT`, map the external port to the internal one:

```yaml
environment:
  - SERVERPORT=32948
ports:
  - 32948:51820/udp  # NOT 32948:32948/udp
```

## Show Peer QR Codes

```bash
docker exec amneziawg /app/show-peer 1 2 3
docker exec amneziawg /app/show-peer laptop phone tablet
```

## Support Info

```bash
# Container logs
docker logs amneziawg

# Interface status
docker exec amneziawg awg show

# Shell access
docker exec -it amneziawg /bin/bash
```

## Building Locally

```bash
docker build -t amneziawg .
# Multi-arch:
docker buildx build --platform linux/amd64,linux/arm64 -t amneziawg .
```

## Links

- [AmneziaVPN Documentation](https://docs.amnezia.org/)
- [AmneziaWG Kernel Module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
- [AmneziaWG Architect](https://architect.vai-rice.space/) — GUI config generator for custom I1-I5 signatures
- [amneziawg-installer](https://github.com/bivlked/amneziawg-installer) — Bash installer for AmneziaWG 2.0 on Ubuntu/Debian
- [Advanced Hub Mode](ADVANCED_AWG_HUB.md) — server + client in one container with upstream VPN routing
- [LinuxServer docker-wireguard](https://github.com/linuxserver/docker-wireguard) — inspiration for this project

## License

MIT License - see [LICENSE](LICENSE) file.
