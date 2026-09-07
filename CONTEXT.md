# CONTEXT.md — Technical Reference for AI Agents

This document provides deep technical context for AI agents working on or answering questions about the docker-amneziawg project. For human-friendly setup instructions, see [README.md](README.md). For developer contribution patterns, see [CLAUDE.md](CLAUDE.md).

## Architecture Overview

### Dockerfile: 3-Stage Multi-Arch Build

| Stage | Base | Output |
|---|---|---|
| `go-builder` | `golang:1.24.4-alpine` | `/src/amneziawg-go` (static binary, CGO) |
| `tools-builder` | `alpine:3.24` | `/usr/bin/awg` (compiled C) + `/usr/bin/awg-quick` (bash script from `src/wg-quick/linux.bash`) |
| runtime | `ghcr.io/linuxserver/baseimage-alpine:3.24` | Production image |

Runtime creates compatibility symlinks: `wg` -> `awg`, `wg-quick` -> `awg-quick`, `/etc/wireguard` -> `/config/wg_confs`.

Both upstream versions are pinned as `ARG` defaults at the top of the Dockerfile:
- `AMNEZIAWG_GO_VERSION` — amneziawg-go tag (e.g., `v0.2.17`)
- `AMNEZIAWG_TOOLS_VERSION` — amneziawg-tools release (e.g., `v1.0.20260223`)

### s6-Overlay Service Chain

```
init-config (LSIO) -> init-amneziawg-module (oneshot) -> init-amneziawg-confs (oneshot) -> svc-coredns (longrun) -> svc-amneziawg (oneshot)
```

- **init-amneziawg-module**: Tests kernel support via `ip link add dev test type amneziawg` (the amnezia module's rtnl link kind — awg-quick creates `type amneziawg`, not `type wireguard`). Falls back to `amneziawg-go` userspace (exports `WG_QUICK_USERSPACE_IMPLEMENTATION`).
- **init-amneziawg-confs**: Config generation using eval+heredoc template expansion from `/config/templates/`. Server mode generates keys, wg0.conf, peer configs, QR codes. Client mode disables CoreDNS.
- **svc-coredns**: Longrun CoreDNS service with `notification-fd 3` health checks. Auto-disabled if port 53 already bound (and `USE_COREDNS` not explicitly set) or `USE_COREDNS=false`. In client mode, defaults to `false` unless overridden. Disabling in server mode breaks DNS for peers using `PEERDNS=auto` — set `PEERDNS` to a public resolver.
- **svc-amneziawg**: Oneshot service (up/down scripts). Validates `[Interface]` in each .conf, activates tunnels, saves active confs to `/run/activeconfs` via `declare -p`. Finish script tears down in reverse order.

Dependencies are declared via empty files in `dependencies.d/`. Services are registered via empty files in `user/contents.d/`.

### Config Persistence

All env vars are saved to `/config/.donoteditthisfile` (LinuxServer pattern) for change detection on restart. AWG obfuscation params are additionally saved to `/config/server/awg_params` and loaded as fallback (via `grep`/`cut`, NOT `source` — to preserve env var priority). Configs only regenerate if any saved var differs from the current value.

## Operating Modes

### Server Mode (PEERS is set)

Auto-generates:
- Server keypair in `/config/server/`
- `wg0.conf` in `/config/wg_confs/`
- Per-peer configs, keypairs, preshared keys, QR codes in `/config/<peer_name>/`
- AWG obfuscation parameters in `/config/server/awg_params`

Peer naming: numeric peers -> `peer1`, `peer2`; named peers -> `peer_laptop`, `peer_phone` (underscore prefix, matching LinuxServer).

### Client Mode (no PEERS)

Uses manual `.conf` files from `/config/wg_confs/`. All `.conf` files are brought up on startup. CoreDNS is auto-disabled.

## Volume Structure

```
./config/
├── wg_confs/             # WireGuard config files (auto-generated or manual)
│   └── wg0.conf          # Server config (interface)
├── server/               # Server keys and params (auto-generated)
│   ├── privatekey-server
│   ├── publickey-server
│   └── awg_params        # Saved AWG obfuscation parameters
├── templates/            # User-customizable config templates
│   ├── server.conf       # Server template (eval+heredoc expanded)
│   └── peer.conf         # Peer template (eval+heredoc expanded)
├── coredns/              # CoreDNS configuration
│   └── Corefile
├── .donoteditthisfile    # Saved env vars for change detection
├── peer1/                # Numeric peer (PEERS=3)
│   ├── peer1.conf
│   ├── peer1.png         # QR code image
│   ├── privatekey-peer1
│   ├── publickey-peer1
│   └── presharedkey-peer1
└── peer_laptop/          # Named peer (PEERS=laptop,phone)
    ├── peer_laptop.conf
    └── peer_laptop.png
```

## Project File Structure

```
docker-amneziawg/
├── Dockerfile                              # 3-stage multi-arch build
├── docker-compose.yml                      # Example configuration
├── root/
│   ├── app/
│   │   └── show-peer                       # QR code display utility
│   ├── defaults/
│   │   ├── server.conf                     # Server template (eval+heredoc)
│   │   ├── peer.conf                       # Peer template (eval+heredoc)
│   │   └── Corefile                        # CoreDNS default config
│   └── etc/s6-overlay/s6-rc.d/
│       ├── init-adduser/branding           # Custom container branding
│       ├── init-amneziawg-module/          # Kernel module detection
│       ├── init-amneziawg-confs/           # Config generation
│       ├── svc-coredns/                    # CoreDNS service (longrun)
│       └── svc-amneziawg/                  # Tunnel service (oneshot up/down)
├── awg0.conf.example                       # Example config
└── .github/workflows/
    ├── docker-build.yml                    # Main build pipeline (multi-arch)
    └── upstream-check.yml                  # Daily upstream version check
```

## AmneziaWG Obfuscation — Deep Dive

All parameters are optional and auto-generated with random values if not set. Server and all clients must use identical values (except Jc/Jmin/Jmax which may differ).

### Parameter Constraints

| Param | Range | Critical Notes |
|-------|-------|----------------|
| Jc | 1-128 (default 3-8) | Number of junk packets before handshake |
| Jmin | < Jmax (default 40-80) | Min junk packet size |
| Jmax | <= 1280 (default 80-250) | Max junk packet size |
| S1 | <= 1132 (default 15-150) | Init padding. **S1+56 must not equal S2** |
| S2 | <= 1188 (default 15-150) | Response padding |
| S3 | <= 64 (default 8-55 in 2.0, 0 in 1.5) | Cookie padding |
| S4 | <= 32 (default 4-20 in 2.0, 12-20 in 3.x, 0 in 1.5) | Transport padding — **per-packet overhead, keep small**. Keep <= 20 or full-size packets fragment at the default 1420 MTU |
| H1-H4 | >= 5, all unique | Header obfuscation. AWG 2.0: range format (e.g. `90666522-140666522`). AWG 1.5: single integers |
| I1-I5 | tag syntax | CPS packets. I1 required for I2-I5. AWG 2.0 auto-generates QUIC Initial for I1 |

### AWG 2.0 vs 1.5

| Feature | AWG 2.0 (default) | AWG 1.5 |
|---------|-------------------|---------|
| S3/S4 | Random non-zero | Fixed 0 |
| H1-H4 format | Range pairs (quadrant strategy) | Single integers |
| I1-I5 | Auto-generated QUIC Initial for I1 | Empty (disabled) |
| Client requirement | AmneziaVPN 4.8.12.9+ | Any AmneziaVPN version |
| App detection | Range H values -> "AWG 2.0" | Integer H values -> "AWG 1.5" |

### CPS Tag Syntax (I1-I5)

| Tag | Description | Example |
|-----|-------------|---------|
| `<b 0xHEX>` | Static hex bytes | `<b 0x170303>` |
| `<r N>` | N random bytes (max 1000) | `<r 32>` |
| `<rd N>` | N random digits (0-9) | `<rd 8>` |
| `<rc N>` | N random characters (a-zA-Z) | `<rc 16>` |
| `<t>` | 32-bit Unix timestamp | Current epoch time |

Tags with `=` signs: parse with `cut -d= -f2-` not `-f2`.

### Default QUIC Initial Packet (AWG 2.0)

```
<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>
```

Breakdown: Long Header (Initial, 4-byte pkt num) + QUIC v1 + DCID(8 random) + no SCID + no token + length 1182 + random pkt num + random payload = 1200 bytes total (RFC 9000 section 14.1 minimum).

For custom protocols (DNS, DTLS, SIP, HTTP/3): use [AmneziaWG Architect](https://architect.vai-rice.space/).

### Data-path cost of each parameter

Full analysis, measurements and reproduction steps: [`docs/awg-performance.md`](docs/awg-performance.md).

Handshake-only, zero steady-state cost: `Jc`/`Jmin`/`Jmax`, `S1`-`S3`, `I1`-`I5`, `H1`-`H4`. Per-packet cost: `S4` (bytes + a CSPRNG call), `HeaderProtectionKey` (one `chacha_init` + 16-byte XOR, effectively free), `ContentPaddingAddition` and `RandomTrailers` (bytes).

**`RandomTrailers` requires `S1 == S2 == S3 == S4` under AWG 2.0+.** Trailers relax the receiver's type check from `skb->len == expected_len` to `>=` (`receive.c:51,62,73`), leaving only the `H` range test to discriminate. The four branches read the type field at their own `S` offset, so unequal values make three of them read garbage, which falls inside a 50M-wide `H` range with p ≈ 1.16% each — about **3.5% of transport packets dropped**. Mathis at 22ms RTT predicts 2.7 Mbit/s; measured 1.7-2.4 against ~100 Mbit/s baseline. Equal `S` values make every branch read the true type, and non-overlapping `H` ranges then exclude it deterministically. Narrow `H` (`1,2,3,4`) fixes it independently.

`generate_awg_params()` handles this: when `AWG_RANDOM_TRAILERS` resolves to `on` and `awg_has_2x_features`, one value is drawn for all four S parameters (12-20), and an explicitly pinned unequal set produces a startup warning. The 3.1 switch normalization runs **before** the S values are drawn so the constraint is known in time — moving it back below reintroduces the bug silently. `generate_awg3_params()` likewise defaults `AWG_CONTENT_PADDING` to `0` under trailers, since content padding suppresses them on send (`send.c:254`) while the receive path stays loose (`receive.c:47`), and warns if the user pins both.

`ContentPaddingAddition` costs ~22% of download throughput: randomizing every datagram length defeats `UDP_GRO` coalescing on userspace clients (`conn/gso_linux.go`), which only batches consecutive equal-sized datagrams.

### MTU and per-packet overhead

`awg-quick` sets the tunnel MTU to `route MTU − 80` (1420 on a 1500 link), exactly like wg-quick. The 80 covers IPv6 (40) + UDP (8) + WG framing (32). It does **not** include `S4`, which amneziawg-go prepends to every transport datagram (`send.go`: `crypt := elem.buffer[:elem.padding]`), so a full-size packet is `MTU + 60 + S4` over IPv4 / `MTU + 80 + S4` over IPv6 and fragments at 1500 when `S4 > 20` (IPv4) or `S4 > 0` (IPv6). Fragmented UDP is dropped or throttled by many CGNATs, mobile networks and DPI — the symptom is "connects, small things work, downloads crawl".

`ContentPaddingAddition` and transport-side `RandomTrailers` do not fragment *transport* packets: both cap their padding at `udpWindow − packet`, where `udpWindow` starts at `DefaultUdpWindow = 500` and grows to the largest datagram seen on the peer (reset on endpoint change). Transport trailers are used only when `ContentPaddingAddition` is zero (three-tier fallback: content padding → random trailer → 16-byte alignment). Wire captures confirm the transport cap exactly (118,559 of 118,565 full-size datagrams at precisely `MTU + S4 + 32`), but a handful of kernel-side *handshake-burst* packets were observed above the cap (up to 1443 B payload on a 1252-cap session) — root-caused upstream: modules built before `4569c4c6` (2026-09-06) appended trailers to I1-I5 and junk packets unconditionally (`wg_socket_send_buffer_to_peer`). The fix did not bump `version.h`, so a patched module still reports `3.1.20260812`; detect it via the package version or the `bool trailer` parameter, not the version string. On older modules a rekey can fragment on a narrow path; handshakes retry, so the impact is latency, not throughput. See `docs/awg-performance.md`.

The cap is the **observed UDP window, not the MTU** (`peer.h:110-124`), and the window is a high-water mark over datagrams both sent *and received* (`send.c:243`, `receive.c:571`). Receiving a padded datagram therefore raises it above the local full-size packet, so `ContentPaddingAddition` does grow full-size sends by a few bytes — measured 1228 → 1229-1244 on the wire. `RandomTrailers` does not, because it short-circuits when `udp_window > size` is false (`peer.h:105`).

Guidance (documented in README "MTU"): 1280 for mobile/PPPoE/unknown paths (clears any path with MTU >= `1340 + S4` on the wire for IPv4 endpoints, `1360 + S4` for IPv6; a path that is *itself* ~1280, e.g. DS-Lite, needs `path − 60 − S4` = 1208 at S4=12 over IPv4, `path − 80 − S4` = 1188 over IPv6 — the IPv6 1280 floor guarantees the *outer* packet, not the tunnel MTU); `1500 − 60 − S4` (1413 for the default max S4 = 27) for wired IPv4; `1500 − 80 − S4` for IPv6 endpoints. The container does not write `MTU`; users add it to the confs or templates. Sources: amneziawg-go `device/send.go`, `device/constants.go`; wiki.amnezia.host 3.1 upgrade guide; bivlked/amneziawg-installer ADVANCED.md (sets 1280 since v5.7.4); Any-Tech-ARCHITECT `scripts/awg-gen.sh` (parameter ranges, no MTU guidance).

## CI/CD

### docker-build.yml

- A `changes` gate job runs first and skips build+release when a push/PR touches nothing image-affecting. Image content is `Dockerfile`, `root/**`, `.dockerignore` and the workflow itself; docs, skills and compose examples never reach the image. Tag pushes, `workflow_dispatch` and unreachable-base diffs fail open (always build)
- Push to `master`/`main` touching image paths -> multi-arch build (`amd64`, `arm64`) -> `ghcr.io/ayastrebov/docker-amneziawg:latest` + tools version tag
- `v*` tags -> semantic version tags (`1.0.0`, `1.0`, `1`)
- PRs -> smoke tests only (single-platform `--load` build): binaries, s6 structure, service types, dependency chain, CoreDNS, branding
- `workflow_dispatch` accepts `amneziawg_go_version` and `amneziawg_tools_version` overrides

### upstream-check.yml

Daily at 06:00 UTC: compares Dockerfile `ARG` defaults against latest amneziawg-tools release and amneziawg-go tag. If new version detected: updates Dockerfile via `sed`, commits, triggers build workflow. Has concurrency control and version format validation.

### Versioning

Container images are tagged with the upstream `amneziawg-tools` version (e.g., `1.0.20260223`).

## Troubleshooting Reference

| Issue | Cause | Solution |
|-------|-------|----------|
| No config files found | Neither PEERS set nor .conf files present | Set PEERS env var or place configs in `./config/wg_confs/` |
| Permission denied | Missing capabilities | Add `NET_ADMIN` (required). `SYS_MODULE` is **not** needed for the kernel datapath — the container only checks whether wireguard/amneziawg is already loaded on the host. Keep `SYS_MODULE` only on minimal hosts that don't auto-load iptables NAT modules. |
| Tunnel fails to start | Missing sysctl or TUN device | Add `net.ipv4.ip_forward=1` sysctl and `/dev/net/tun` device |
| Exit code 137 | Normal SIGKILL on container stop | Not an error |
| Custom SERVERPORT not working | Wrong port mapping | Map as `SERVERPORT:51820/udp` — container always listens on 51820 internally |
| Amnezia app shows AWG 1.5 | H1-H4 using single integers | Use range format for AWG 2.0 (e.g. `90666522-140666522`) |
| QR code not displaying | LOG_CONFS disabled | Set `LOG_CONFS=true` or use `docker exec amneziawg /app/show-peer 1` |
| High CPU | Too many junk packets | Reduce AWG_JC value |
| Connection fails after param change | Client/server mismatch | Redistribute updated peer configs to all clients |
| ISP blocks VPN on high ports | Some ISPs block UDP > 9999 | Use SERVERPORT <= 9999 |
| Peers have no DNS after `USE_COREDNS=false` | CoreDNS disabled but `PEERDNS=auto` still points peers at the container | Set `PEERDNS=1.1.1.1` (or another public resolver) when disabling CoreDNS |
| Tunnel connects but downloads are slow, pings fine | Full-size packets fragment: 1420 + 60/80 + S4 > path MTU | Set `MTU` explicitly: 1280 on ordinary paths, `path − 60 − S4` (IPv4) / `path − 80 − S4` (IPv6) when the path itself is constrained (a true 1280-byte path needs 1208/1188); see README "MTU" |

## External References

- [AmneziaVPN Documentation](https://docs.amnezia.org/)
- [AmneziaWG Self-Hosted Setup](https://docs.amnezia.org/documentation/instructions/new-amneziawg-selfhosted/)
- [AmneziaWG Kernel Module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
- [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go)
- [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools)
- [AmneziaWG Architect](https://architect.vai-rice.space/) — GUI CPS config generator
- [amneziawg-installer](https://github.com/bivlked/amneziawg-installer) — Bare-metal Bash installer
- [LinuxServer docker-wireguard](https://github.com/linuxserver/docker-wireguard) — Upstream inspiration
