# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Summary

Docker container for AmneziaWG VPN built on LinuxServer.io base images with s6-overlay process supervision. Two modes: **server** (auto-generates configs when `PEERS` is set) and **client** (uses manual configs from `/config/wg_confs/`). The container brings up ALL `.conf` files in `/config/wg_confs/` on startup.

## Build & Test

```bash
# Build image locally
docker build -t amneziawg-test .

# Run server mode smoke test (tunnel won't work without /dev/net/tun — expected)
docker run -d --name awg-test --cap-add NET_ADMIN \
  -e PEERS=2 -e SERVERURL=test.example.com \
  -v /tmp/awg-test:/config amneziawg-test

# Verify config generation
docker logs awg-test
docker exec awg-test cat /config/wg_confs/wg0.conf
docker exec awg-test cat /config/peer1/peer1.conf
docker exec awg-test /app/show-peer 1

# Cleanup
docker rm -f awg-test && rm -rf /tmp/awg-test
```

There is no automated test suite. CI runs smoke tests on PRs: binary presence, s6 structure, show-peer executable check.

## Architecture

### Dockerfile: 5-stage multi-arch build with two targets

| Stage | Base | Output |
|---|---|---|
| `go-builder` | `golang:1.25.12-alpine` | `/src/amneziawg-go` (static binary, CGO) |
| `tools-builder` | `alpine:3.24` | `/usr/bin/awg` (compiled C) + `/usr/bin/awg-quick` (bash script copied from `src/wg-quick/linux.bash`) |
| `api-builder` | `golang:1.25.12-alpine` | `/awg-api` (static binary, pure Go + Gin + Swagger) |
| `awg-api` **(target)** | `alpine:3.24` | API sidecar image — `awg` + `awg-quick` + `awg-api`, no s6 |
| `runtime` **(default target)** | `ghcr.io/linuxserver/baseimage-alpine:3.24` | VPN image — no API binary |

Build targets: `docker build .` or `--target runtime` (VPN), `--target awg-api` (sidecar).

**`runtime` must remain the last stage in the file.** Docker builds the final stage when no `--target` is given, so moving it would silently make a plain `docker build .` produce the API image instead of the VPN one.

Runtime creates compatibility symlinks: `wg → awg`, `wg-quick → awg-quick`, `/etc/wireguard → /config/wg_confs`.

### s6-overlay service chain

```
init-config (LSIO) → init-amneziawg-module (oneshot) → init-amneziawg-confs (oneshot) → svc-coredns (longrun) → svc-amneziawg (oneshot)
```

- **init-amneziawg-module**: Tests kernel support via `ip link add dev test type amneziawg` (the amnezia module's rtnl link kind — awg-quick creates `type amneziawg`, not `type wireguard`). Falls back to `amneziawg-go` userspace (exports `WG_QUICK_USERSPACE_IMPLEMENTATION`).
- **init-amneziawg-confs**: Config generation using eval+heredoc template expansion from `/config/templates/`. Server mode generates keys, wg0.conf, peer configs, QR codes. Client mode disables CoreDNS. Copies `/build_version` to `/config/server/build_version` for sidecar access (in both modes).
- **svc-coredns**: Longrun CoreDNS service with `notification-fd 3` health checks. Auto-disabled if port 53 already bound (and `USE_COREDNS` not explicitly set) or `USE_COREDNS=false`. In client mode, defaults to `false` unless overridden. Disabling in server mode breaks DNS for peers using `PEERDNS=auto` — set `PEERDNS` to a public resolver.
- **svc-amneziawg**: Oneshot service (up/down scripts). Validates `[Interface]` in each .conf, activates tunnels, saves active confs to `/run/activeconfs` via `declare -p`. Finish script tears down in reverse order.

Dependencies are declared via empty files in `dependencies.d/`. Services are registered via empty files in `user/contents.d/`.

### API sidecar (`awg-api` image)

The REST API runs as a separate container (`ghcr.io/ayastrebov/awg-api`), not inside the VPN container. It shares the VPN's network namespace via `network_mode: service:amneziawg` and the `/config` volume. It has its own entrypoint (`api/entrypoint.sh`) handling token generation and config wait. All file paths are env-driven (`CONFIG_DIR`, `ACTIVE_CONFS_PATH`, `BUILD_VERSION_PATH`, `S6_ENV_DIR`, `AWG_BINARY_PATH`) with sidecar-appropriate defaults.

Security invariants — do not regress these:
- `readAWGParams()` in `api/config.go` uses an **allowlist**. Never restore pass-through: `/config/server/awg_params` contains `AWG_HEADER_PROTECTION_KEY`, a symmetric key shared with every client. New non-secret params need adding to `awgParamAllowlist` to become visible.
- WebSocket auth reads the token from `Sec-WebSocket-Protocol` or `Authorization`. The `?token=` form is deprecated because gin logs raw query strings; the WS paths are in the logger's `SkipPaths` for that reason.
- Swagger is opt-in (`API_SWAGGER=true`) because `/swagger/*` is mounted outside the authenticated route group.

See `API.md` for endpoint docs and `DECOUPLING.md` for architecture rationale.

### Config persistence

All env vars are saved to `/config/.donoteditthisfile` (LinuxServer pattern) for change detection on restart. AWG obfuscation params are additionally saved to `/config/server/awg_params` and loaded as fallback (via `grep`/`cut`, NOT `source` — to preserve env var priority). Configs only regenerate if any saved var differs from the current value.

## Key Development Patterns

### s6-overlay scripts
- Shebang: `#!/usr/bin/with-contenv bash`
- Add `# shellcheck shell=bash` directive
- Must be `chmod +x`
- Use `lsiown -R abc:abc /config` for ownership (LinuxServer helper), fallback to `chown`

### Adding a new environment variable
1. Set default in `init-amneziawg-confs/run` main logic section
2. If persistent: add to `save_vars()` (as `ORIG_X`) AND the change detection `if` block
3. For AWG params: also add to `generate_awg_params()` save block AND `load_awg_params()` grep section
4. For config output: add to templates in `root/defaults/` (eval+heredoc expanded), `append_awg_signatures()` (server conf — appends after template, before peer blocks), or `append_awg_signatures_to_interface()` (peer confs — inserts before `[Peer]` using awk)
5. Document in `docker-compose.yml` (commented example) and `README.md`

### AWG obfuscation parameters
All clients and server must use identical values. Key constraints:
- `AWG_VERSION`: `"2.0"` (default, S3/S4 random, I1 randomly generated as QUIC Initial/DNS/DTLS), `"3.0"` (2.0 plus `HeaderProtectionKey`, `ContentPaddingAddition` and randomized timers; S1-S4 floors rise to 12) or `"1.5"` (S3=S4=0, no I1-I5)
- AWG 3.0 params live in `[Interface]` and are written by `append_awg3_params()` (server conf) / `append_awg3_params_to_interface()` (peer confs), generated by `generate_awg3_params()`. Timer values are `lo-hi` ranges and may differ per side; `HeaderProtectionKey` must be identical everywhere
- `Jmin < Jmax`, `Jmax ≤ 1280`
- `S1 ≤ 1132`, `S2 ≤ 1188`, `S1+56 ≠ S2`, `S3 ≤ 64`, `S4 ≤ 32` (S4 is per-packet overhead — keep small)
- `H1-H4` must be unique, all ≥ 5 (values 1-4 are standard WireGuard headers). **AWG 2.0 generates non-overlapping quadrant range pairs by default** (e.g., `H1=90666522-140666522`) — the Amnezia app uses range format to identify AWG 2.0; single integers cause it to report AWG 1.5. AWG 1.5 keeps single integers.
- `I1-I5` (AWG 2.0 signatures) use tag syntax with `=` signs — parse with `cut -d= -f2-` not `-f2`
- Detailed parameter reference: `CONTEXT.md` (architecture, parameters, troubleshooting) and `.claude/skills/docker-amneziawg/references/awg-parameters.md`

## Conventions

- Commit messages: conventional commits (`feat:`, `fix:`, `docs:`, `chore:`)
- Branch naming: `feature/your-feature-name`
- Indentation: 4 spaces for shell scripts and s6-overlay files, 2 spaces for Dockerfile and YAML (see `.editorconfig`)
- `root/defaults/server.conf` and `peer.conf` are eval+heredoc templates — they use `${VAR}` and `$(cat ...)` syntax that gets expanded at runtime via `eval "$(printf %s) cat <<DUDE ... DUDE"` (matching LinuxServer docker-wireguard pattern). Users can customize templates in `/config/templates/`

## CI/CD

### Workflows

**`docker-build.yml`** — main build pipeline:
- Push to `master`/`main` → builds multi-arch (`amd64`, `arm64`) and pushes to `ghcr.io/ayastrebov/docker-amneziawg:latest` + upstream tools version tag, then creates a GitHub Release tagged with the tools version (skipped if the release already exists)
- `v*` tags → semantic version tags (`1.0.0`, `1.0`, `1`)
- PRs → smoke tests only (single-platform `--load` build, no multi-arch QEMU): binaries, s6 structure, service types, dependency chain, CoreDNS, branding
- Upstream versions are read from the Dockerfile `ARG` pins (single source of truth); `workflow_dispatch` accepts `amneziawg_go_version` and `amneziawg_tools_version` overrides for one-off builds

**`upstream-check.yml`** — daily upstream version check (06:00 UTC):
- Compares `ARG` defaults in Dockerfile against latest amneziawg-tools and amneziawg-go releases
- If new version detected: updates Dockerfile and opens a pull request; the build workflow runs on merge

### Versioning

Container images are tagged with the upstream `amneziawg-tools` version (e.g., `1.0.20260223`). Both upstream versions are pinned as `ARG` defaults at the top of the Dockerfile:
- `AMNEZIAWG_GO_VERSION` — amneziawg-go tag (e.g., `v0.2.16`)
- `AMNEZIAWG_TOOLS_VERSION` — amneziawg-tools release (e.g., `v1.0.20260223`)

## Common Gotchas

- `local` keyword is only valid inside functions — don't use in main script body
- `awg-quick` is a bash script, not compiled — it's copied from upstream `src/wg-quick/linux.bash`
- Exit code 137 on container stop is normal (SIGKILL), not an error
- The Dockerfile patches `awg-quick` to skip setting `src_valid_mark` sysctl if already set
- Do NOT use `source` to load `awg_params` — it overrides Docker env vars. Use `grep`/`cut` with `${VAR:-fallback}` pattern
- Peer naming: numeric peers → `peer1`, `peer2`; named peers → `peer_laptop`, `peer_phone` (underscore prefix, matching LinuxServer)
- `INTERFACE` is derived from `INTERNAL_SUBNET` (e.g., `10.13.13` from `10.13.13.0`) — not a separate env var
- `svc-amneziawg` is a oneshot (not longrun) — tunnels stay up without a running process
- Container branding: `root/etc/s6-overlay/s6-rc.d/init-adduser/branding` + `LSIO_FIRST_PARTY=false` in Dockerfile
- I1-I5 must be in `[Interface]` in peer confs, not `[Peer]` — the Amnezia app only checks `[Interface]` for version detection. `append_awg_signatures_to_interface()` handles this via awk insertion before `[Peer]`. The server conf is fine with append since peer blocks haven't been added yet when signatures are written.
- Custom `SERVERPORT` requires port mapping `SERVERPORT:51820/udp` (not `SERVERPORT:SERVERPORT/udp`) — the container always listens on 51820 internally regardless of `SERVERPORT`.
- `SYS_MODULE` does NOT enable the kernel datapath. `init-amneziawg-module/run` never calls `modprobe` — it only probes whether the `amneziawg` module is already active on the host via `ip link add ... type amneziawg` (the amnezia module registers link kind `amneziawg`; a plain `wireguard` module is never used because `awg-quick` creates `type amneziawg` and otherwise falls back to userspace `amneziawg-go`). The init script even logs "you can remove the SYS_MODULE capability" once the module is active. Keep `SYS_MODULE` only on minimal hosts that don't auto-load iptables NAT modules. `/lib/modules:/lib/modules` bind mount is a no-op for this container.
