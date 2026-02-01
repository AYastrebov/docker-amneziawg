---
name: docker-amneziawg
description: |
  Development skill for the docker-amneziawg project - an AmneziaWG VPN container with LinuxServer.io architecture. Use when working in the docker-amneziawg repository for: (1) Adding features or fixing bugs, (2) Modifying s6-overlay services, (3) Updating config generation, (4) Working with AmneziaWG obfuscation parameters, (5) Testing or building the Docker image. Triggers when working in a directory containing this project's structure (root/etc/s6-overlay, awg-related files).
---

# docker-amneziawg Development Guide

## Project Overview

AmneziaWG Docker container built on LinuxServer.io base images with s6-overlay process supervision. Provides automatic VPN configuration generation with DPI-bypass obfuscation.

## Project Structure

```
docker-amneziawg/
├── Dockerfile                    # Multi-stage build (go-builder, tools-builder, runtime)
├── docker-compose.yml            # Example configurations
├── root/
│   ├── app/
│   │   └── show-peer             # QR code display utility
│   ├── defaults/
│   │   ├── server.conf           # Server config template (reference only)
│   │   └── peer.conf             # Peer config template (reference only)
│   └── etc/s6-overlay/s6-rc.d/
│       ├── init-amneziawg-module/    # Kernel module detection (oneshot)
│       ├── init-amneziawg-confs/     # Config generation (oneshot)
│       ├── svc-amneziawg/            # Tunnel service (longrun)
│       └── user/contents.d/          # Service registration (empty files)
└── .github/workflows/docker-build.yml
```

## S6-Overlay Architecture

### Service Types
- **oneshot**: Runs once at startup. Files: `type` (contains "oneshot"), `up` (path to run script), `run`
- **longrun**: Runs continuously. Files: `type` (contains "longrun"), `run`, `finish`

### Service Dependency Chain
```
init-amneziawg-module → init-amneziawg-confs → svc-amneziawg
```

Define dependencies via empty files in `dependencies.d/` named after the dependency service.

Register services by creating empty files in `user/contents.d/` named after the service.

### Script Requirements
- Shebang: `#!/usr/bin/with-contenv bash`
- Must be executable (`chmod +x`)
- Use `lsiown` for LinuxServer permission management

## Dockerfile Build Stages

| Stage | Purpose |
|-------|---------|
| `go-builder` | Compile `amneziawg-go` static binary from source |
| `tools-builder` | Compile `awg` binary + copy `awg-quick` from `src/wg-quick/linux.bash` |
| `runtime` | LinuxServer base + deps + binaries + `root/` filesystem |

**awg-quick patch** (avoid sysctl errors when already set):
```bash
sed -i 's|\[\[ $proto == -4 \]\] && cmd sysctl -q net\.ipv4\.conf\.all\.src_valid_mark=1|[[ $proto == -4 ]] \&\& [[ $(sysctl -n net.ipv4.conf.all.src_valid_mark) != 1 ]] \&\& cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1|'
```

## Config Generation

### Operating Modes
- **Server mode**: `PEERS` env var set → auto-generates server + peer configs with QR codes
- **Client mode**: No `PEERS` → uses manual configs from `/config/wg_confs/`

### Key Environment Variables
| Variable | Default | Description |
|----------|---------|-------------|
| `PEERS` | - | Enables server mode. Number ("3") or names ("laptop,phone") |
| `SERVERURL` | auto | Server URL/IP for peer configs |
| `SERVERPORT` | 51820 | Listen port |
| `INTERNAL_SUBNET` | 10.13.13.0 | VPN subnet (.1 = server, .2+ = peers) |
| `PEERDNS` | auto | DNS for peers (auto = 8.8.8.8, 8.8.4.4) |
| `LOG_CONFS` | true | Show QR codes in container logs |

### Generated File Structure
```
/config/
├── wg_confs/wg0.conf          # Server interface config
├── server/
│   ├── privatekey-server
│   ├── publickey-server
│   └── awg_params             # Persisted obfuscation values
└── <peer_name>/
    ├── <peer_name>.conf
    ├── <peer_name>.png        # QR code image
    ├── privatekey-<peer_name>
    ├── publickey-<peer_name>
    └── presharedkey-<peer_name>
```

## AmneziaWG Obfuscation

For detailed parameter documentation, see [references/awg-parameters.md](references/awg-parameters.md).

**Quick reference:**
| Param | Purpose | Default |
|-------|---------|---------|
| `AWG_JC` | Junk packet count before handshake | Random 3-8 |
| `AWG_JMIN` | Min junk packet size | Random 40-80 |
| `AWG_JMAX` | Max junk packet size | Random 500-1000 |
| `AWG_S1` | Init packet padding | Random 15-150 |
| `AWG_S2` | Response packet padding | Random 15-150 |
| `AWG_S3` | Cookie message padding | 0 |
| `AWG_S4` | Transport packet padding | 0 |
| `AWG_H1-H4` | Header obfuscation (32-bit) | Random |

**All clients and server must use identical values.**

## Common Development Tasks

### Adding a New Environment Variable
1. Add default value in `init-amneziawg-confs/run` (near top)
2. If persisted: add to `awg_params` save block and load section
3. Use in `generate_server_config()` and/or `generate_peer_config()`
4. Document in `docker-compose.yml` and `README.md`

### Testing Changes
```bash
# Build image
docker build -t amneziawg-test .

# Run server mode test
docker run -d --name awg-test \
  --cap-add NET_ADMIN \
  -e PEERS=2 \
  -e SERVERURL=test.example.com \
  -v /tmp/awg-test:/config \
  amneziawg-test

# Verify
docker logs awg-test
docker exec awg-test cat /config/wg_confs/wg0.conf
docker exec awg-test cat /config/peer1/peer1.conf
docker exec awg-test /app/show-peer 1

# Cleanup
docker rm -f awg-test
```

**Note**: Tunnel startup will fail without `--device /dev/net/tun` - this is expected in testing.

## Common Gotchas

| Issue | Solution |
|-------|----------|
| `local: can only be used in a function` | Remove `local` keyword from main script body |
| awg-quick not found in build | Copy from `src/wg-quick/linux.bash`, not compiled |
| Service not starting | Check: executable bit, shebang, registered in `user/contents.d/` |
| Exit code 137 | Normal - container was stopped (SIGKILL) |
| Permission errors on /config | Use `lsiown -R abc:abc /config` |

## GitHub Actions Workflow

Triggers:
- Push to `master`/`main` → builds and tags as `latest`
- Push `v*` tags → semantic version tags (1.0.0, 1.0, 1)
- Pull requests → build + smoke test (no push)

Multi-arch: `linux/amd64`, `linux/arm64`
