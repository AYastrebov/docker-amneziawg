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

### Dockerfile: 3-stage multi-arch build

| Stage | Base | Output |
|---|---|---|
| `go-builder` | `golang:1.24.4-alpine` | `/src/amneziawg-go` (static binary, CGO) |
| `tools-builder` | `alpine:3.21` | `/usr/bin/awg` (compiled C) + `/usr/bin/awg-quick` (bash script copied from `src/wg-quick/linux.bash`) |
| runtime | `ghcr.io/linuxserver/baseimage-alpine:3.21` | Production image |

Runtime creates compatibility symlinks: `wg → awg`, `wg-quick → awg-quick`, `/etc/wireguard → /config/wg_confs`.

### s6-overlay service chain

```
init-amneziawg-module (oneshot) → init-amneziawg-confs (oneshot) → svc-amneziawg (longrun)
```

- **init-amneziawg-module**: Detects kernel module (amneziawg → wireguard → amneziawg-go userspace fallback)
- **init-amneziawg-confs**: All config generation logic (~460 lines). Server mode generates keys, wg0.conf, peer configs, QR codes. Client mode just checks for existing configs.
- **svc-amneziawg**: Calls `awg-quick up` for each `.conf` file. Traps SIGTERM for graceful shutdown. `finish` script tears down any remaining interfaces.

Dependencies are declared via empty files in `dependencies.d/`. Services are registered via empty files in `user/contents.d/`.

### Config persistence

AWG obfuscation params are saved to `/config/server/awg_params` and reloaded on restart. Configs only regenerate if `PEERS` or AWG params change (compared against saved state).

## Key Development Patterns

### s6-overlay scripts
- Shebang: `#!/usr/bin/with-contenv bash`
- Add `# shellcheck shell=bash` directive
- Must be `chmod +x`
- Use `lsiown -R abc:abc /config` for ownership (LinuxServer helper), fallback to `chown`

### Adding a new environment variable
1. Set default in `init-amneziawg-confs/run` (top section)
2. If persistent: add to `generate_awg_params()` save block AND `load_awg_params()` section
3. Use in `generate_server_config()` and/or `generate_peer_config()`
4. Document in `docker-compose.yml` (commented example) and `README.md`

### AWG obfuscation parameters
All clients and server must use identical values. Key constraints:
- `Jmin < Jmax`, `Jmax ≤ 1280`
- `S1 ≤ 1132`, `S2 ≤ 1188`, `S1+56 ≠ S2`
- `H1-H4` must be unique, all ≥ 5 (values 1-4 are standard WireGuard headers)
- `I1-I5` (AWG 2.0 signatures) use tag syntax with `=` signs — parse with `cut -d= -f2-` not `-f2`
- Detailed parameter reference: `.claude/skills/docker-amneziawg/references/awg-parameters.md`

## Conventions

- Commit messages: conventional commits (`feat:`, `fix:`, `docs:`, `chore:`)
- Branch naming: `feature/your-feature-name`
- Indentation: 4 spaces for shell scripts and s6-overlay files, 2 spaces for Dockerfile and YAML (see `.editorconfig`)
- `root/defaults/server.conf` and `peer.conf` are reference templates only — the generation script uses heredocs with direct variable interpolation, not template substitution

## CI/CD

GitHub Actions at `.github/workflows/docker-build.yml`:
- Push to `master`/`main` → builds multi-arch (`amd64`, `arm64`) and pushes to `ghcr.io/ayastrebov/docker-amneziawg:latest`
- `v*` tags → semantic version tags (`1.0.0`, `1.0`, `1`)
- PRs → build + smoke test only (no push)

## Common Gotchas

- `local` keyword is only valid inside functions — don't use in main script body
- `awg-quick` is a bash script, not compiled — it's copied from upstream `src/wg-quick/linux.bash`
- Exit code 137 on container stop is normal (SIGKILL), not an error
- The Dockerfile patches `awg-quick` to skip setting `src_valid_mark` sysctl if already set
