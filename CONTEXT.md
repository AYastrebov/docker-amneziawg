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

- **init-amneziawg-module**: Tests kernel support via `ip link add dev test type wireguard`. Falls back to `amneziawg-go` userspace (exports `WG_QUICK_USERSPACE_IMPLEMENTATION`).
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
| S4 | <= 32 (default 4-27 in 2.0, 0 in 1.5) | Transport padding — **per-packet overhead, keep small** |
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

## CI/CD

### docker-build.yml

- Push to `master`/`main` -> multi-arch build (`amd64`, `arm64`) -> `ghcr.io/ayastrebov/docker-amneziawg:latest` + tools version tag
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

## External References

- [AmneziaVPN Documentation](https://docs.amnezia.org/)
- [AmneziaWG Self-Hosted Setup](https://docs.amnezia.org/documentation/instructions/new-amneziawg-selfhosted/)
- [AmneziaWG Kernel Module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
- [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go)
- [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools)
- [AmneziaWG Architect](https://architect.vai-rice.space/) — GUI CPS config generator
- [amneziawg-installer](https://github.com/bivlked/amneziawg-installer) — Bare-metal Bash installer
- [LinuxServer docker-wireguard](https://github.com/linuxserver/docker-wireguard) — Upstream inspiration
