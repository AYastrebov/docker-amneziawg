# Architecture

How the image is built, how the s6 services start, what lands in `/config`, and how CI builds and releases it. User-facing setup is in [README.md](../README.md); contributor rules are in [AGENTS.md](../AGENTS.md) and [development.md](development.md); obfuscation parameters are in [awg-obfuscation.md](awg-obfuscation.md).

## Architecture Overview

### Dockerfile: 3-Stage Multi-Arch Build

| Stage | Base | Output |
|---|---|---|
| `go-builder` | `golang:1.26.9-alpine` | `/src/amneziawg-go` (static binary, CGO) |
| `tools-builder` | `alpine:3.24` | `/usr/bin/awg` (compiled C) + `/usr/bin/awg-quick` (bash script from `src/wg-quick/linux.bash`) |
| runtime | `ghcr.io/linuxserver/baseimage-alpine:3.24` | Production image |

Runtime creates compatibility symlinks: `wg` -> `awg`, `wg-quick` -> `awg-quick`, `/etc/wireguard` -> `/config/wg_confs`.

Both upstream versions are pinned as `ARG` defaults at the top of the Dockerfile:
- `AMNEZIAWG_GO_VERSION` — amneziawg-go tag (e.g., `v0.2.17`)
- `AMNEZIAWG_TOOLS_VERSION` — amneziawg-tools release (e.g., `v1.0.20260223`)

### s6-Overlay Service Chain

```
init-config (LSIO) -> init-amneziawg-module (oneshot) -> init-amneziawg-confs (oneshot) -> svc-amneziawg (oneshot) -> svc-dnsmasq (longrun)
```

- **init-amneziawg-module**: Tests kernel support via `ip link add dev test type amneziawg` (the amnezia module's rtnl link kind — awg-quick creates `type amneziawg`, not `type wireguard`). Falls back to `amneziawg-go` userspace (exports `WG_QUICK_USERSPACE_IMPLEMENTATION`).
- **init-amneziawg-confs**: Config generation using eval+heredoc template expansion from `/config/templates/`. Server mode generates keys, wg0.conf, peer configs, QR codes. Client mode defaults `USE_DNS=false`. Unless `USE_DNS=false`, writes the dnsmasq base config (server: bound to wg0; client: all interfaces).
- **svc-dnsmasq**: Longrun dnsmasq forwarder for peers on `PEERDNS=auto`. Depends on `svc-amneziawg`, so it starts after the tunnel step, whether or not the tunnel came up (`svc-amneziawg/run` exits 0 on failure; dnsmasq then logs "interface wg0 does not currently exist" and listens on nothing until wg0 appears, since loopback is excluded too). `interface=wg0` + `bind-dynamic` picks wg0 up when it appears and rebinds when it is recreated. Base config `/run/dnsmasq/dnsmasq.conf` is written by `write_dnsmasq_conf()` in init-amneziawg-confs on every start unless `USE_DNS=false` (client mode with `USE_DNS=true` listens on all interfaces, since its tunnels need not be called wg0) (container-owned, never in `/config`); users add `*.conf` drop-ins to `/config/dnsmasq/` via `conf-dir` (created 0755 under an explicit umask, since `generate_confs` leaves `umask 077` behind). Forwards to `/etc/resolv.conf` — no `domain-needed`/`bogus-priv`, because single-label Docker container names must reach `127.0.0.11`. Validated with `dnsmasq --test` before exec; a broken drop-in logs once and sleeps instead of restart-looping. Auto-disabled if port 53 is already bound on a wildcard address (and `USE_DNS` not explicitly set): server mode binds `wg0` only (`interface=wg0` + `except-interface=lo`), so loopback resolvers are not a conflict. A bind failure at runtime (dnsmasq exit 2) is caught by `svc-dnsmasq/finish`, which exits 125 so s6 leaves the service down instead of restart-looping it. Also disabled by `USE_DNS=false`. In client mode, defaults to `false` unless overridden. Disabling in server mode breaks DNS for peers using `PEERDNS=auto` — set `PEERDNS` to a public resolver. dnsmasq drops to the `dnsmasq` user, keeping only `CAP_NET_BIND_SERVICE`.
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

Uses manual `.conf` files from `/config/wg_confs/`. All `.conf` files are brought up on startup. dnsmasq is auto-disabled.

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
├── dnsmasq/              # User dnsmasq drop-ins (*.conf), read after the generated base config
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
├── AGENTS.md                               # Agent instructions (always loaded); CLAUDE.md imports it
├── Dockerfile                              # 3-stage multi-arch build
├── docker-compose.yml                      # Example configuration
├── awg0.conf.example                       # Example config
├── root/
│   ├── app/
│   │   ├── show-peer                       # QR code display utility
│   │   └── ipv6-lib.sh                     # IPv6 prefix/exit resolution, template migration (sourced, unit-tested)
│   ├── defaults/
│   │   ├── server.conf                     # Server template (eval+heredoc)
│   │   └── peer.conf                       # Peer template (eval+heredoc)
│   └── etc/s6-overlay/s6-rc.d/
│       ├── init-adduser/branding           # Custom container branding
│       ├── init-amneziawg-module/          # Kernel module detection
│       ├── init-amneziawg-confs/           # Config generation
│       ├── svc-amneziawg/                  # Tunnel service (oneshot up/down)
│       ├── svc-dnsmasq/                    # dnsmasq service (longrun)
│       └── user/contents.d/                # Service registration (empty files)
├── tests/
│   ├── ipv6-lib.test.sh                    # Unit tests for root/app/ipv6-lib.sh (no container)
│   └── smoke.sh                            # Image smoke test, run by CI on PRs
├── docs/                                   # Architecture, development rules, AWG references, specs/plans
├── .agents/skills/                         # Agent Skills (.claude/skills and .agent/skills are symlinks)
└── .github/workflows/
    ├── docker-build.yml                    # Main build pipeline (multi-arch)
    └── upstream-check.yml                  # Daily upstream version check
```

## CI/CD

### docker-build.yml

- A `changes` gate job diffs each push/PR first: only `Dockerfile`, `root/**`, `.dockerignore` and the workflow itself are image content, so docs/skills/compose-only pushes skip the build and release entirely. The gate is an explicit `git diff` job, NOT an `on.push.paths` filter — path filters share the `push` block with the `v*` tag trigger and behave ambiguously for tag pushes, which could silently break semver releases. Tags, `workflow_dispatch`, and diffs with no reachable base all fail open (build)
- Push to `master`/`main` touching image paths → builds multi-arch (`amd64`, `arm64`) and pushes to `ghcr.io/ayastrebov/docker-amneziawg:latest` + upstream tools version tag, then creates a GitHub Release tagged with the tools version (skipped if the release already exists)
- `v*` tags → semantic version tags (`1.0.0`, `1.0`, `1`)
- PRs → smoke tests only (single-platform `--load` build, no multi-arch QEMU), in `tests/smoke.sh`: binaries, s6 structure, service types, dependency chain, dnsmasq (CoreDNS absent, a drop-in record answered on loopback, which a `listen-address` drop-in adds for the test, `filter-AAAA`), branding, AWG 3.1 and IPv6 config generation, the DNS toggle. The script is a file rather than an inline step because GitHub rejects a `run:` step over 21,000 characters at load time (zero jobs, "workflow file issue"). Run it locally with `docker build -t test-image . && bash tests/smoke.sh`
- Upstream versions are read from the Dockerfile `ARG` pins (single source of truth); `workflow_dispatch` accepts `amneziawg_go_version` and `amneziawg_tools_version` overrides for one-off builds

### upstream-check.yml

Daily at 06:00 UTC:
- Compares `ARG` defaults in Dockerfile against latest amneziawg-tools and amneziawg-go releases
- If new version detected: updates Dockerfile and opens a pull request; the build workflow runs on merge

### Versioning

Container images are tagged with the upstream `amneziawg-tools` version (e.g., `1.0.20260223`). Both upstream versions are pinned as `ARG` defaults at the top of the Dockerfile:
- `AMNEZIAWG_GO_VERSION` — amneziawg-go tag (e.g., `v0.2.16`)
- `AMNEZIAWG_TOOLS_VERSION` — amneziawg-tools release (e.g., `v1.0.20260223`)

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
| Peers have no DNS after `USE_DNS=false` | dnsmasq disabled but `PEERDNS=auto` still points peers at the container | Set `PEERDNS=1.1.1.1` (or another public resolver) when disabling dnsmasq |
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
