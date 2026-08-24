# Docker AmneziaWG

[![Docker Build](https://github.com/AYastrebov/docker-amneziawg/actions/workflows/docker-build.yml/badge.svg)](https://github.com/AYastrebov/docker-amneziawg/actions/workflows/docker-build.yml)
[![GitHub Container Registry](https://img.shields.io/badge/ghcr.io-docker--amneziawg-blue?logo=docker)](https://github.com/AYastrebov/docker-amneziawg/pkgs/container/docker-amneziawg)
[![GitHub release](https://img.shields.io/github/v/release/AYastrebov/docker-amneziawg)](https://github.com/AYastrebov/docker-amneziawg/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

[AmneziaWG](https://docs.amnezia.org/) VPN server and client in one container. It writes the server config and hands you a ready config plus QR code for every peer, and it can answer DNS for connected clients. Built on [LinuxServer.io](https://www.linuxserver.io/) base images with s6-overlay.

AmneziaWG is WireGuard with added traffic obfuscation, so deep packet inspection has a harder time recognizing the handshake. The container picks random obfuscation values on first start, including the I1-I5 protocol signatures, then saves them and reuses them on later restarts so already distributed peer configs keep working.

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Modes](#modes)
- [Parameters](#parameters)
- [Protocol version](#protocol-version)
- [Obfuscation parameters](#obfuscation-parameters)
- [Custom protocol signatures (I1-I5)](#custom-protocol-signatures-i1-i5)
- [Custom SERVERPORT](#custom-serverport)
- [Managing peers](#managing-peers)
- [Support info](#support-info)
- [Building locally](#building-locally)
- [Links](#links)

## Quick start

Server mode, three peers, using Docker Compose:

```yaml
services:
  amneziawg:
    image: ghcr.io/ayastrebov/docker-amneziawg:latest
    container_name: amneziawg
    cap_add:
      - NET_ADMIN
      # - SYS_MODULE  # rarely needed, see Parameters
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

```bash
docker compose up -d
docker exec amneziawg /app/show-peer laptop   # config text and QR code
```

Each peer also gets a file on disk, at `./config/peer_laptop/peer_laptop.conf` for named peers or `./config/peer1/peer1.conf` when `PEERS` is a number.

The same thing with `docker run`:

```bash
docker run -d \
  --name amneziawg \
  --cap-add NET_ADMIN \
  `# --cap-add SYS_MODULE  rarely needed, see Parameters` \
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

## Requirements

- A Docker host with `/dev/net/tun` and the `NET_ADMIN` capability
- amd64 (x86-64) or arm64 (aarch64)

### Kernel module

The container works out of the box without a kernel module: it falls back to the bundled `amneziawg-go` userspace implementation. For better throughput, install the [AmneziaWG kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) on the host and the container will detect it and use it instead.

Keep the module and the image on the same feature generation. An older module still works with a newer image, but the kernel datapath only applies the options that module knows about.

> [!NOTE]
> `SYS_MODULE` is not required for the kernel datapath. The container never calls `modprobe`, it only checks whether the module is already loaded. See [Parameters](#parameters) for the one case where `SYS_MODULE` still helps.

## Modes

The container runs in one of two modes, decided by whether `PEERS` is set.

Set `PEERS` and you get server mode. The container generates keys, writes `wg0.conf`, writes one config and QR code per peer, and starts CoreDNS so peers on `PEERDNS=auto` have a resolver to talk to.

Leave `PEERS` unset and you get client mode. Drop your own `.conf` files into `./config/wg_confs/` and the container brings up every one of them on start. Nothing is generated, and CoreDNS stays off unless you ask for it.

```bash
# client mode: your configs, nothing generated
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
| `-e SERVERPORT=51820` | Port advertised to peers. Use <= 9999 if your ISP blocks high UDP ports |
| `-e PEERS=3` | Number or comma-separated names (`laptop,phone`). Enables server mode |
| `-e PEERDNS=auto` | DNS for peers. `auto` = container's CoreDNS at subnet.1 |
| `-e INTERNAL_SUBNET=10.13.13.0` | VPN subnet (.1 = server, .2+ = peers) |
| `-e ALLOWEDIPS=0.0.0.0/0, ::/0` | Traffic peers route into the tunnel. The tunnel itself is IPv4-only, so `::/0` is included deliberately: it sinks client IPv6 instead of forwarding it, which prevents IPv6 leaks on dual-stack client networks. Drop `::/0` if you would rather peers keep using their native IPv6 outside the tunnel, or narrow the value to specific subnets for split-tunnel routing |
| `-e PERSISTENTKEEPALIVE_PEERS=` | Which peers get keepalive: `all` or comma-separated names/numbers |
| `-e SERVER_ALLOWEDIPS_PEER_X=` | Per-peer server AllowedIPs for site-to-site VPN |
| `-e LOG_CONFS=true` | Show generated configs and QR codes in container logs |
| `-e USE_COREDNS=true` | Enable or disable the built-in CoreDNS. Defaults to `true` in server mode and `false` in client mode. Auto-disables when port 53 is already bound, unless you set it explicitly. Setting it to `false` in server mode breaks DNS for peers on `PEERDNS=auto`, so point `PEERDNS` at a public resolver such as `1.1.1.1` if you do |
| `-e AWG_VERSION=2.0` | Protocol version: `2.0` (default, full DPI evasion), `3.0` (header protection and randomized timers) or `1.5` (legacy) |
| `-v /config` | Persistent config volume |
| `--cap-add NET_ADMIN` | Required for tunnel management |
| `--cap-add SYS_MODULE` | Usually unnecessary. The container does not load kernel modules, it only checks whether `wireguard`/`amneziawg` is already loaded on the host. Keep `SYS_MODULE` only on minimal hosts that do not auto-load iptables NAT modules |
| `--sysctl net.ipv4.ip_forward=1` | Enable IP forwarding |
| `--device /dev/net/tun` | TUN device access |

## Protocol version

| Version | When to use |
|---------|-------------|
| `2.0` (default) | Full DPI evasion with I1-I5 signatures. Requires AmneziaVPN app 4.8.12.9+ |
| `3.0` | Adds header protection (`HeaderProtectionKey`), content padding and randomized protocol timers. Requires 3.0-capable clients, and `HeaderProtectionKey` must be identical on server and all clients |
| `1.5` | Legacy compatibility with older clients. No I1-I5, S3=S4=0 |

Set this with the `AWG_VERSION` environment variable. Every obfuscation value is randomized for you, so override them only to match an existing setup.

> [!IMPORTANT]
> `AWG_VERSION=3.0` needs 3.0-capable software at both ends. The container handles its own side either way: it runs 3.0 in userspace with the bundled `amneziawg-go`, and switches to the kernel datapath automatically when a 3.0-capable module is loaded on the host. The generated config is the same in both cases. Your peers need an AmneziaVPN app or amneziawg build that supports 3.0.

> [!NOTE]
> There is no `AWG_VERSION=3.1`. AWG 3.1 added two independent `[Interface]` switches rather than a new parameter set, and the container does not generate them. See [AWG 3.1 interface options](#awg-31-interface-options).

## Obfuscation parameters

Every value here is optional and random by default. Server and clients must agree on all of them, except the 3.0 timer ranges, where each side draws its own value.

| Parameter | Default | Constraints |
|-----------|---------|-------------|
| `-e AWG_JC=` | Random 3-8 | Junk packet count (1-128) |
| `-e AWG_JMIN=` | Random 40-80 | Min junk size in bytes. Must be < JMAX |
| `-e AWG_JMAX=` | Random 80-250 | Max junk size in bytes (max 1280) |
| `-e AWG_S1=` | Random 15-150 | Init padding bytes (max 1132). S1+56 must not equal S2 |
| `-e AWG_S2=` | Random 15-150 | Response padding bytes (max 1188) |
| `-e AWG_S3=` | Random 8-55 (2.0) / 12-55 (3.0) / 0 (1.5) | Cookie padding bytes (max 64) |
| `-e AWG_S4=` | Random 4-27 (2.0) / 12-27 (3.0) / 0 (1.5) | Transport padding bytes (max 32). Per-packet overhead, keep it small |
| `-e AWG_H1=` | Auto range (2.0) / int (1.5) | Header obfuscation. H1-H4 must be unique, all >= 5 |
| `-e AWG_H2=` | Auto range (2.0) / int (1.5) | AWG 2.0 uses range format (e.g. `90666522-140666522`) |
| `-e AWG_H3=` | Auto range (2.0) / int (1.5) | Single integers cause the Amnezia app to report AWG 1.5 |
| `-e AWG_H4=` | Auto range (2.0) / int (1.5) | |
| `-e AWG_I1=` | Auto QUIC Initial (2.0) / empty (1.5) | Custom protocol signature packet. See [tag reference](#custom-protocol-signatures-i1-i5) |
| `-e AWG_I2=` | empty | Requires I1 to be set |
| `-e AWG_I3=` | empty | |
| `-e AWG_I4=` | empty | |
| `-e AWG_I5=` | empty | |

### AWG 3.0 parameters

Generated only when `AWG_VERSION=3.0`. Timer values are `lo-hi` ranges and the endpoint picks a fresh random value inside the range, so the two sides do not have to match.

| Parameter | Default | Constraints |
|-----------|---------|-------------|
| `-e AWG_HEADER_PROTECTION_KEY=` | Auto-generated shared key | Encrypts packet headers. Must be identical on server and all clients. Requires S1-S4 >= 12 |
| `-e AWG_CONTENT_PADDING=` | Random range within 16-128 | Extra random padding per transport packet, `lo-hi` bytes. `0` disables |
| `-e AWG_REKEY_AFTER_TIME=` | Random range within 100-145s | Time before the initiator rekeys, `lo-hi` seconds (WireGuard default 120) |
| `-e AWG_REKEY_TIMEOUT=` | Random range within 4-10s | Handshake retransmit timeout, `lo-hi` seconds (default 5) |
| `-e AWG_REJECT_AFTER_TIME=` | Random range, derived | Keypair lifetime, `lo-hi` seconds (default 180). Must exceed RekeyAfterTime and KeepaliveTimeout + RekeyTimeout |
| `-e AWG_KEEPALIVE_TIMEOUT=` | Random range within 8-22s | Keepalive interval when idle, `lo-hi` seconds (default 10) |
| `-e AWG_MAX_HANDSHAKE_ATTEMPTS=` | Random range within 12-28 | Handshake retries before giving up, `lo-hi` count (default 18) |

### AWG 3.1 interface options

The bundled `amneziawg-go` and `awg` are 3.1 builds, which accept two extra `[Interface]` booleans (`on` or `off`). They work with any `AWG_VERSION` and the container does not write them for you. Add them by hand to `/config/templates/server.conf` and `/config/templates/peer.conf`, anywhere above the `[Peer]` section, or to your own `.conf` files in client mode.

| Option | Effect | Must match on both ends |
|--------|--------|:---:|
| `RandomTrailers = on` | Appends a random number of random bytes to handshake initiation, response and cookie-reply packets, so those packets no longer have a fixed length. The trailer is drawn per packet to fill up to a 500-byte window | Yes |
| `DisableCookies = on` | Stops the endpoint from answering with cookie-reply messages when it is under load, which removes a distinctive response to probing. You give up WireGuard's built-in DoS mitigation in exchange | No |

`RandomTrailers` changes the receive path as well as the send path. A peer without it expects handshake packets of exactly one length and drops the padded ones, so enable it on the server and every peer, or on none of them.

Both options need 3.1-capable software wherever they are used: the bundled userspace `amneziawg-go`, or [kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) v3.1.x on the host for the kernel datapath. Older `awg` builds reject the keys with `Line unrecognized`.

## Custom protocol signatures (I1-I5)

AWG 2.0 sends signature packets before the handshake to make VPN traffic look like some other UDP protocol. I1 defaults to a QUIC Initial packet (RFC 9000).

| Tag | Description | Example |
|-----|-------------|---------|
| `<b 0xHEX>` | Static hex bytes | `<b 0x170303>` |
| `<r N>` | N random bytes | `<r 32>` |
| `<rd N>` | N random digits | `<rd 8>` |
| `<rc N>` | N random chars (a-zA-Z) | `<rc 16>` |
| `<t>` | 32-bit Unix timestamp | |

[AmneziaWG Architect](https://architect.vai-rice.space/) generates signature strings for QUIC, DNS, DTLS, SIP, HTTP/3 and others.

## Custom SERVERPORT

The container always listens on 51820 inside the network namespace. `SERVERPORT` only changes what peer configs advertise, so map the external port onto 51820:

```yaml
environment:
  - SERVERPORT=32948
ports:
  - 32948:51820/udp  # NOT 32948:32948/udp
```

## Managing peers

```bash
docker exec amneziawg /app/show-peer 1 2 3
docker exec amneziawg /app/show-peer laptop phone tablet
```

## Support info

```bash
# container logs
docker logs amneziawg

# interface status
docker exec amneziawg awg show

# bundled amneziawg-go and amneziawg-tools versions
docker exec amneziawg cat /build_version

# shell access
docker exec -it amneziawg /bin/bash
```

## Building locally

```bash
docker build -t amneziawg .
# multi-arch:
docker buildx build --platform linux/amd64,linux/arm64 -t amneziawg .
```

## Links

- [AmneziaVPN documentation](https://docs.amnezia.org/)
- [AmneziaWG kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
- [AmneziaWG Architect](https://architect.vai-rice.space/), a GUI config generator for custom I1-I5 signatures
- [amneziawg-installer](https://github.com/bivlked/amneziawg-installer), a bash installer for AmneziaWG 2.0 on Ubuntu/Debian
- [Advanced hub mode](ADVANCED_AWG_HUB.md), server and client in one container with upstream VPN routing
- [LinuxServer docker-wireguard](https://github.com/linuxserver/docker-wireguard), the project this one is modeled on

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues go through [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE).
