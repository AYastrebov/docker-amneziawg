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
- [Speed and latency](#speed-and-latency)
- [MTU](#mtu)
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
      # - AWG_RANDOM_TRAILERS=on #optional
      # - AWG_DISABLE_COOKIES=on #optional
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

If you run the kernel datapath with `RandomTrailers`, use a module built from upstream **`4569c4c6`** (2026-09-06) or newer: earlier 3.1 modules appended random trailers to I1-I5 signature packets and junk packets too, producing occasional oversized handshake-burst datagrams that fragment on narrow paths. Note that `/sys/module/amneziawg/version` still reads `3.1.20260812` on the fixed build — upstream did not bump it — so check `dpkg -l amneziawg-dkms` (`…+4569c4c…` or newer) rather than the version string; see [docs/awg-performance.md](docs/awg-performance.md#checking-whether-your-module-has-the-fix). The bundled userspace `amneziawg-go` never had this bug.

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
| `-e AWG_VERSION=2.0` | Protocol version: `2.0` (default, full DPI evasion), `3.0` (header protection and randomized timers), `3.1` (3.0 plus `RandomTrailers`) or `1.5` (legacy) |
| `-e AWG_RANDOM_TRAILERS=` | `on`/`off`. Pads handshake packets to a random length. Works with any `AWG_VERSION`; defaults to `on` under `3.1`. Must match on every end. `off` omits the key |
| `-e AWG_DISABLE_COOKIES=` | `on`/`off`. Stops cookie-reply messages under load. Works with any `AWG_VERSION`; always opt-in. Does not need to match. `off` omits the key |
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
| `3.1` | Everything `3.0` generates, plus `RandomTrailers = on`. Requires 3.1-capable software on every end. `DisableCookies` stays off unless you ask for it |
| `1.5` | Legacy compatibility with older clients. No I1-I5, S3=S4=0 |

Set this with the `AWG_VERSION` environment variable. Every obfuscation value is randomized for you, so override them only to match an existing setup.

Like the obfuscation parameters, the version is saved to `/config/server/awg_params` and restored when the variable is absent, so recreating a container from a compose file that no longer sets it keeps the deployment on the version its peer confs were built for.

> [!IMPORTANT]
> `AWG_VERSION=3.0` needs 3.0-capable software at both ends. The container handles its own side either way: it runs 3.0 in userspace with the bundled `amneziawg-go`, and switches to the kernel datapath automatically when a 3.0-capable module is loaded on the host. The generated config is the same in both cases. Your peers need an AmneziaVPN app or amneziawg build that supports 3.0.

> [!NOTE]
> `AWG_VERSION=3.1` is a convenience preset, not a distinct parameter set. Upstream AWG 3.1 added two independent `[Interface]` switches on top of 3.0, and you can set either one with any `AWG_VERSION`. See [AWG 3.1 interface options](#awg-31-interface-options).

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
| `-e AWG_S4=` | Random 4-20 (2.0) / 12-20 (3.x) / 0 (1.5) | Transport padding bytes (max 32). Per-packet overhead, keep it small |
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

AWG 3.1 added two `[Interface]` booleans (`on` or `off`) rather than a new parameter set. They are independent of each other and of `AWG_VERSION`, so you can pair either one with `2.0` or `3.0`.

| Option | Env var | Effect | Must match on both ends |
|--------|---------|--------|:---:|
| `RandomTrailers` | `AWG_RANDOM_TRAILERS` | Appends a random number of random bytes to handshake initiation, response and cookie-reply packets, so those packets no longer have a fixed length. The trailer is drawn per packet to fill up to a window that starts at 500 bytes and grows to the largest datagram seen on the connection. When `ContentPaddingAddition` is `0`, the same trailer is also applied to transport packets, which can inflate every small packet (TCP ACKs, DNS) to close to full size — see [MTU](#mtu) | Yes |
| `DisableCookies` | `AWG_DISABLE_COOKIES` | Stops the endpoint from answering with cookie-reply messages when it is under load, which removes a distinctive response to probing. You give up WireGuard's built-in DoS mitigation in exchange | No |

The container writes whichever of these is `on` into the `[Interface]` block of the server conf and every peer conf, so both ends stay in step. Unset, or `off`, and the key is not written at all.

`AWG_VERSION=3.1` is shorthand for the 3.0 parameter set plus `AWG_RANDOM_TRAILERS=on`. `DisableCookies` is never turned on for you: it trades away WireGuard's DoS mitigation, and since it does not have to match between ends it is a per-deployment call rather than part of a protocol mode. Set it explicitly if you want it:

```yaml
      - AWG_VERSION=3.1
      - AWG_DISABLE_COOKIES=on
```

Setting a switch explicitly persists it like any other AWG parameter, so it survives a restart with the var removed. A switch that came only from the `3.1` preset does not: drop back to `AWG_VERSION=2.0` and `RandomTrailers` goes away with the rest of the 3.x keys, which is what you want when you are downgrading to get an older client connected again.

Either switch also works on its own, with any version:

```yaml
      - AWG_VERSION=2.0
      - AWG_RANDOM_TRAILERS=on
```

`RandomTrailers` changes the receive path as well as the send path. A peer without it expects handshake packets of exactly one length and drops the padded ones, so enable it on the server and every peer, or on none of them. Because the container writes it to every conf it generates, that holds automatically — but a peer conf you wrote by hand, or an older client, will not connect.

That same receive-path change is why `RandomTrailers` needs `S1 = S2 = S3 = S4`. Once packet lengths are only a lower bound, the `H` ranges are all that separate one packet type from another, and unequal `S` values make three of the four checks read the type field at the wrong offset. Roughly 3.5% of data packets then get dropped as malformed handshakes. Set the four `S` values equal whenever you turn trailers on — see [Speed and latency](#speed-and-latency).

Both options need 3.1-capable software wherever they are used: the bundled userspace `amneziawg-go`, or [kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) v3.1.x on the host for the kernel datapath. On an older host module the tunnel fails to come up with `Unable to modify interface: Invalid argument` — the bundled `awg` parses the keys, and the kernel is what refuses them. (An `awg` build older than 3.1, which you would only meet outside this container, instead reports `Line unrecognized`.) The container reads `/sys/module/amneziawg/version` at startup and warns before either happens — but only when that file exists and holds a numeric version. A missing file, or a string it cannot read as a number (`v3.1.0`, a git-describe or distro-suffixed version), is passed over rather than guessed at, so no warning is not proof the module is new enough. Check it yourself if you are unsure.

To turn a switch back off, set it to `off` rather than removing it — removing the variable means "reuse the saved value", the same as every other `AWG_*` setting. `off` omits the key from the generated configs rather than writing `= off`; since off is the endpoint default anyway the two are equivalent, and omitting it keeps the config readable by an older amneziawg that does not know the key at all. That makes `AWG_RANDOM_TRAILERS=off` the way to rescue a tunnel these switches have broken, without leaving `AWG_VERSION=3.1`.

> [!NOTE]
> Earlier versions of this image did not generate these keys, so the documented workaround was to add them by hand to `/config/templates/server.conf` and `/config/templates/peer.conf`. If you did that, remove the hand-added lines and set the env vars instead — otherwise the key is written twice.

## Custom protocol signatures (I1-I5)

AWG 2.0 sends signature packets before the handshake to make VPN traffic look like some other UDP protocol. I1 defaults to a QUIC Initial packet (RFC 9000).

| Tag | Description | Example |
|-----|-------------|---------|
| `<b 0xHEX>` | Static hex bytes | `<b 0x170303>` |
| `<r N>` | N random bytes | `<r 32>` |
| `<rd N>` | N random digits | `<rd 8>` |
| `<rc N>` | N random chars (a-zA-Z) | `<rc 16>` |
| `<t>` | 32-bit Unix timestamp | |

Current AmneziaWG puts no size limit on a random tag, and the default I1 uses a single `<r 1178>`. Some third-party parsers still enforce an older 1000-byte-per-tag rule (observed: Keenetic rejects the default with `invalid I1 value`); for those, replace only the trailing `<r 1178>` with `<r 1000><r 178>` and leave the rest of the value as it is — the default then reads `<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1000><r 178>`. The two forms are identical on the wire, so peers on either interoperate. See [CONTEXT.md](CONTEXT.md).

[AmneziaWG Architect](https://architect.vai-rice.space/) generates signature strings for QUIC, DNS, DTLS, SIP, HTTP/3 and others.

## Custom SERVERPORT

The container always listens on 51820 inside the network namespace. `SERVERPORT` only changes what peer configs advertise, so map the external port onto 51820:

```yaml
environment:
  - SERVERPORT=32948
ports:
  - 32948:51820/udp  # NOT 32948:32948/udp
```

## Speed and latency

Most obfuscation is free: `Jc`/`Jmin`/`Jmax`, `S1`-`S3` and `I1`-`I5` only touch handshake packets, and `H1`-`H4` just substitute a value into a field that already exists. Four settings cost something on every data packet — `S4`, `HeaderProtectionKey`, `ContentPaddingAddition` and `RandomTrailers`.

Measured over a 22ms internet path (kernel-module server, userspace client, link capable of 107↑ / 181↓ Mbit/s):

| Configuration | ↑ Mbit/s | ↓ Mbit/s | wire bytes per 64-byte ping |
|---|---:|---:|---:|
| plain WireGuard | 100.5 | 132.4 | 170 |
| `HeaderProtectionKey` + `S=12` | 99.7 | 131.6 | 182 |
| ↑ plus `RandomTrailers` | 99.7 | 125.3 | 537 |
| ↑ plus `ContentPaddingAddition` | 99.7 | 102.4 | 186 |
| `RandomTrailers` with unequal `S1`-`S4` | **1.7** | 115.0 | 258 |

> [!IMPORTANT]
> **`RandomTrailers` requires `S1 = S2 = S3 = S4`.** Trailers relax the receiver's packet-type check from an exact length match to `>=`, leaving only the `H` range test to separate types. With `S1`-`S4` all different, three of the four checks read the type field at the wrong offset and misfire about 1.16% of the time each, so roughly **3.5% of data packets are dropped** and TCP collapses — that last row above.
>
> The container handles this for you: with trailers on it draws a single value for all four, and warns if you pin them unequal yourself. You only need to think about it when writing configs by hand, or when adopting parameters generated elsewhere.

Versions before this fix generated unequal `S` values under `AWG_VERSION=3.1`. Existing installs keep their saved parameters and are not regenerated, so if you deployed 3.1 earlier, check `/config/server/awg_params` — if `AWG_S1`-`AWG_S4` differ, set them to one value explicitly and redistribute the peer configs.

`AWG_CONTENT_PADDING` defaults to `0` when trailers are on, and is worth `0` generally: content padding costs about 22% of download throughput, because giving every datagram a different length defeats the receiving client's UDP batching. It also takes precedence over `RandomTrailers` on the send path while leaving the receive path's loose matching switched on, so enabling both gives you the cost of trailers and none of their benefit.

Keep `AWG_S4` at **20 or below**. Per-packet overhead is `60 + S4`, so a larger value pushes a full-size packet past 1500 bytes at the default 1420 tunnel MTU and fragments every one of them — see [MTU](#mtu).

Full analysis, source references and how to reproduce the measurements: [docs/awg-performance.md](docs/awg-performance.md).

## MTU

The container does not write an `MTU` line, so `awg-quick` does what it does for plain WireGuard: it takes the MTU of the route to the endpoint (1500 on most links) and subtracts 80, giving a tunnel MTU of 1420. That 80 covers an IPv6 header, UDP and the 32-byte WireGuard transport framing. It does **not** cover the bytes AmneziaWG adds on top, and that is why users on AWG 3.x report that dropping the MTU to 1280 makes the tunnel faster — sometimes dramatically.

### What AmneziaWG adds to every transport packet

Each encrypted data packet on the wire is

```
IP (20 IPv4 / 40 IPv6) + UDP (8) + S4 + 16-byte header + payload (≤ MTU) + ContentPadding + 16-byte tag
```

compared with plain WireGuard, where `S4` and `ContentPadding` are both zero. The pieces behave differently:

| Component | Size | On a full-size packet | Notes |
|-----------|------|-----------------------|-------|
| `S4` | random 4-20 (2.0) / 12-20 (3.x), max 32 | **Adds to the datagram** | The only part `awg-quick`'s 80-byte allowance does not know about. Also carries the header-protection nonce in 3.x, which is why it cannot go below 12 there |
| `ContentPaddingAddition` (3.x) | random `lo-hi`, container default within 16-128 | A few bytes | Capped at the largest datagram seen so far, not at the MTU — and that high-water mark counts packets *received* as well as sent, so it drifts above the current packet size and full-size packets do grow a little. Not enough to fragment, but it costs ~22% of download by breaking the receiver's UDP batching. Set `AWG_CONTENT_PADDING=0` |
| `RandomTrailers` (3.1) on transport | random `0 … window − packet` | Nothing — capped at the largest datagram already seen | Only active on transport packets when `ContentPaddingAddition = 0`. With it, a 52-byte TCP ACK can become a ~1400-byte datagram |

So with the default 1420 tunnel MTU a full-size packet becomes `1420 + 60 + S4` bytes over IPv4, and `1420 + 80 + S4` over IPv6. Over IPv4 that exceeds 1500 as soon as `S4 > 20`; over an IPv6 endpoint it exceeds 1500 for any `S4 > 0`. The random `S4` the container picks is above 20 roughly 30 % of the time in 2.0 (7 of 24 values) and 44 % in 3.x (7 of 16) — which is why one deployment is fine and the next one is "slow for no reason".

### Why an oversized packet is slow rather than broken

A UDP datagram larger than the path MTU is not rejected; the kernel fragments it into two IP packets. Every full-size packet of a download now costs two packets on the wire, the far end has to reassemble them, and — the part that actually hurts — many carrier-grade NATs, mobile networks, cloud load balancers and DPI boxes drop IP fragments outright or rate-limit them. Each dropped fragment loses the whole datagram, the TCP inside the tunnel sees loss, backs off, and throughput collapses while small packets (pings, handshakes, web pages) keep working. Fragmented UDP is also a classic fingerprint for DPI, which undoes the point of the obfuscation.

The client side has the same problem in the other direction, and it usually has a *smaller* path MTU than the server: PPPoE (1492), LTE/5G (often 1400 or less, and iOS enforces path MTU strictly), IPv6-over-IPv4 transitions, corporate Wi-Fi. `awg-quick` on the server has no way of knowing any of this.

1280 leaves 220 bytes of headroom on a 1500-byte IPv4 path — enough for `S4`, UDP, IP and a few hops of extra encapsulation — and its wire packets (`1280 + 60 + S4`) clear PPPoE (1492), LTE (~1400) and every ordinary path. That is why it is the value people converge on, and why Amnezia's own installers and the 3.1 upgrade guides set it by default.

Be precise about what the "IPv6 minimum" argument guarantees, though: the 1280-byte floor applies to the packet **on the wire**, and a tunnel MTU of 1280 produces wire packets of `1340 + S4` bytes over an IPv4 endpoint and `1360 + S4` over an IPv6 one. On a path whose own MTU really is 1280 — DS-Lite, some LTE and tunnel-in-tunnel setups — those still fragment. The truly-safe-everywhere tunnel MTU is `1280 − 60 − S4` for an IPv4 endpoint (1208 at `S4 = 12`) or `1280 − 80 − S4` for IPv6 (1188), which keeps the outer packet at or under 1280. We verified the IPv4 case on such a path: at tunnel MTU 1208, 118,559 of 118,565 full-size datagrams measured exactly 1280 on the wire (the remainder were the handshake-burst outliers documented in [docs/awg-performance.md](docs/awg-performance.md)), and tunnel MTU 1280 would have fragmented every one of them. Measure your path (`ping -M do` binary search) rather than assuming; use 1280 when the path is normal or unknown-but-probably-normal, and `path − 60 − S4` (IPv4) / `path − 80 − S4` (IPv6) when you know the path is constrained.

### Which value to pick

| Situation | Tunnel MTU | Why |
|-----------|-----------:|-----|
| Mobile clients, PPPoE, unknown paths, anything that "works but is slow" | **1280** | Clears every ordinary path (needs path MTU ≥ `1340 + S4` on the wire for an IPv4 endpoint, `1360 + S4` for IPv6); the cost is a ~10% higher header-to-payload ratio, which is nothing next to fragmentation loss |
| Path that is itself constrained to ~1280 (DS-Lite, tunnel-in-tunnel, some LTE) | `path − 60 − S4` (IPv4) / `path − 80 − S4` (IPv6) | The outer packet must fit the *path*, not the IPv6 floor: at `S4 = 12` a 1280-byte path needs tunnel MTU **1208** (IPv4 endpoint) or **1188** (IPv6). Measure with a `ping -M do` binary search |
| Wired clients on a clean 1500-byte path, IPv4 endpoint | 1400-1413 | `1500 − 20 − 8 − 32 − S4`. 1413 is the ceiling for the largest default `S4` (27), 1408 for the hard maximum (32); 1400 also survives one extra 8-byte encapsulation |
| IPv6 endpoint on a 1500-byte path | 1380-1393 | `1500 − 40 − 8 − 32 − S4`: 1393 for `S4 = 27`, 1388 for `S4 = 32` |
| You have set `AWG_S4` yourself | `path − 60 (IPv4) / 80 (IPv6) − S4` | Recompute when you change `S4` |

Do not go above the derived number expecting more speed: the tunnel MTU is a ceiling, and every byte above the path limit is paid back as fragmentation. Going lower than you need only adds per-packet overhead: on a normal path there is no reason to drop under 1280, and on a constrained path no reason to drop under that path's own derived value (1208 IPv4 / 1188 IPv6 on a true 1280-byte path at `S4 = 12`). The number is derived, not magic.

If you rely on `RandomTrailers` without `ContentPaddingAddition` (3.1 with `AWG_CONTENT_PADDING=0`), a lower MTU also helps in a second way: the trailer window tracks the largest datagram seen, so a smaller MTU caps how far small packets can be inflated, which matters on asymmetric links where the upload ACK stream is what limits download speed.

### How to set it

For an existing deployment, add an `MTU` line to the `[Interface]` section of the generated confs and restart the container. For new deployments (or before the next regeneration), put the line in `/config/templates/server.conf` and `/config/templates/peer.conf` instead — templates are only read when the configs are (re)generated, which happens on first start or when a server-side or `AWG_*` variable changes:

```ini
[Interface]
Address = ...
MTU = 1280
```

Set it on both the server conf (`/config/wg_confs/wg0.conf`) and every peer conf (`/config/peerN/peerN.conf`, then re-import on the device — QR codes and `.conf` files are regenerated from the templates only, so hand-edited peer confs must be re-distributed). The two sides do not have to agree — each side's MTU only limits what *it* sends — but a peer left at 1420 still fragments its uploads. The AmneziaVPN app exposes MTU in the connection settings; on Windows the WinTUN adapter ignores the config value and uses 1280 regardless.

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
