# API Decoupling Design Proposal

## Overview

Split the monolithic `docker-amneziawg` image into a lightweight base VPN image and an optional `awg-api` sidecar image. This enables three use cases:

1. **Base VPN only** — slim image without API binary or service.
2. **Standalone API** — `awg-api` binary runs on a host with system-installed `amneziawg-go`/`awg-tools`.
3. **Docker Compose stack** — three services: `amneziawg` + `awg-api` + `webui`.

The existing `/config` directory structure is preserved exactly. Only the packaging and runtime wiring change.

---

## Hard Constraint: Network Namespace

`awg show all dump` (used for live tunnel stats and WebSockets) communicates via netlink / userspace sockets scoped to the **network namespace** of the WireGuard interface.

Therefore, any container running the API must share the VPN container's network namespace (Docker `network_mode: service:amneziawg`) or run on the same host natively.

---

## 1. Architecture: Two Images, Shared Build Stage

A single `Dockerfile` with two `--target` final stages keeps `amneziawg-tools` build logic in one place.

### Image 1: `docker-amneziawg` (Base VPN)

| Attribute | Value |
|---|---|
| Base | `ghcr.io/linuxserver/baseimage-alpine:3.24` |
| Contents | `amneziawg-go`, `awg`, `awg-quick`, s6-overlay services |
| **Removed** | `awg-api` binary, `svc-awg-api` service, port `8081` |
| Size impact | ~22 MB smaller than current monolith |

### Image 2: `awg-api` (API Sidecar)

| Attribute | Value |
|---|---|
| Base | `alpine:3.24` (no LSIO overhead — the API is a single static Go binary + `awg` CLI) |
| Contents | `awg` binary, `awg-api` binary, lightweight entrypoint |
| Size | ~25–30 MB total |
| Port | `8081/tcp` |

**Why `alpine:3.24` and not `ghcr.io/linuxserver/baseimage-alpine`?**  
The API sidecar doesn't need s6-overlay, user management (`abc:abc`), init hooks, or branding. Alpine keeps the sidecar minimal.

---

## 2. API Code Changes (`api/`)

Hardcoded container paths become environment-driven with current values as defaults.

| Variable | Default | Purpose |
|---|---|---|
| `CONFIG_DIR` | `/config` | Peer configs, server keys, `awg_params` |
| `ACTIVE_CONFS_PATH` | `/run/activeconfs` | Active tunnel manifest |
| `BUILD_VERSION_PATH` | `/build_version` | Version strings |
| `S6_ENV_DIR` | `/run/s6-overlay/container_environment` | s6 env fallback |
| `AWG_BINARY_PATH` | `/usr/bin/awg` | `awg show` binary |

**Files to modify:**
- `api/config.go` — read `CONFIG_DIR`, `ACTIVE_CONFS_PATH`, `BUILD_VERSION_PATH`, `S6_ENV_DIR` from `os.Getenv`.
- `api/awg.go` — read `AWG_BINARY_PATH` from `os.Getenv`.
- `api/services.go` — no changes required; already degrades gracefully to `"unknown"` when `s6-svstat` is absent.

---

## 3. Base VPN Image Changes

### s6-overlay service removal
- **Delete** `root/etc/s6-overlay/s6-rc.d/svc-awg-api/` (run, finish, type, notification-fd, dependencies.d).
- **Delete** `root/etc/s6-overlay/s6-rc.d/user/contents.d/svc-awg-api`.

### Active tunnel state sharing
The API sidecar cannot see `/run/activeconfs` (ephemeral tmpfs inside the VPN container).

**`root/etc/s6-overlay/s6-rc.d/svc-amneziawg/run`:**
```bash
declare -p AWG_CONFS > /run/activeconfs
declare -p AWG_CONFS > /config/server/activeconfs   # NEW: shared with sidecar
```

**`root/etc/s6-overlay/s6-rc.d/svc-amneziawg/finish`:**
```bash
if [[ -f "/run/activeconfs" ]]; then
    . /run/activeconfs
elif [[ -f "/config/server/activeconfs" ]]; then
    . /config/server/activeconfs
fi
```

### Build version sharing
**`root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run`:** copy `/build_version` to `/config/server/build_version` so the sidecar can report versions.

### Dockerfile base target
Remove `api-builder` stage consumption, `EXPOSE 8081/tcp`.

---

## 4. API Sidecar Image (`--target awg-api`)

```dockerfile
FROM alpine:3.24 AS awg-api
RUN apk add --no-cache ca-certificates netcat-openbsd
COPY --from=tools-builder /tools-install/usr/bin/awg /usr/bin/awg
COPY --from=api-builder /awg-api /usr/bin/awg-api
COPY api/entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EXPOSE 8081/tcp
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD nc -z localhost ${API_PORT:-8081}
```

**`api/entrypoint.sh`:**
```bash
#!/bin/sh
if [ -z "$API_TOKEN" ]; then
    if [ -f /config/server/api_token ]; then
        API_TOKEN=$(cat /config/server/api_token)
    else
        API_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        mkdir -p /config/server
        echo "$API_TOKEN" > /config/server/api_token
        chmod 600 /config/server/api_token
        echo "API token generated: $API_TOKEN"
    fi
    export API_TOKEN
fi
export API_PORT=${API_PORT:-8081}
exec /usr/bin/awg-api
```

---

## 5. Docker Compose Stack (`docker-compose.stack.yml`)

```yaml
services:
  amneziawg:
    image: ghcr.io/ayastrebov/docker-amneziawg:latest
    cap_add: [NET_ADMIN]
    sysctls: [net.ipv4.conf.all.src_valid_mark=1]
    devices: [/dev/net/tun:/dev/net/tun]
    volumes:
      - awg-config:/config
    ports:
      - "51820:51820/udp"
      - "8081:8081/tcp"   # Published on VPN container's netns

  awg-api:
    image: ghcr.io/ayastrebov/awg-api:latest
    network_mode: service:amneziawg   # Shares netns with VPN container
    volumes:
      - awg-config:/config
    environment:
      - CONFIG_DIR=/config
      - ACTIVE_CONFS_PATH=/config/server/activeconfs
      - BUILD_VERSION_PATH=/config/server/build_version
      - AWG_BINARY_PATH=/usr/bin/awg

  webui:
    image: <your-webui-image>
    ports:
      - "80:80/tcp"
    environment:
      - API_URL=http://amneziawg:8081/api/v1

volumes:
  awg-config:
```

**Networking note:** `awg-api` uses `network_mode: service:amneziawg`, so it has no bridge IP of its own. Port mapping `8081:8081/tcp` must be declared on the `amneziawg` service. The `webui` container reaches the API via the `amneziawg` service name.

---

## 6. Standalone Binary Distribution

The `awg-api` binary is already `CGO_ENABLED=0` static Go. A CI job cross-compiles it for GitHub Releases:

- `awg-api-linux-amd64`
- `awg-api-linux-arm64`

Usage on a host with system `amneziawg-go`/`awg-tools`:
```bash
export CONFIG_DIR=/etc/amneziawg
export AWG_BINARY_PATH=/usr/bin/awg
export API_TOKEN=...
./awg-api-linux-amd64
```

---

## 7. CI/CD & Tagging Strategy

Two images built from the same repo, same triggers, separate tags.

| Image | Versioning | Tags |
|---|---|---|
| `docker-amneziawg` | Tracks upstream `amneziawg-tools` version | `latest`, `v3.0.20260730`, semver |
| `awg-api` | Independent semantic versioning | `latest`, `v1.0.0` |

**Proposed workflow changes:**
- `.github/workflows/docker-build.yml` builds both `--target`s in parallel, multi-arch (`amd64`, `arm64`).
- Release job attaches `awg-api-linux-amd64` and `awg-api-linux-arm64` binaries to GitHub Releases.

---

## 8. Migration & Breaking Changes

No backward compatibility. The all-in-one mode is removed immediately.

| Removed | Replacement |
|---|---|
| `USE_API=true` env var on base image | Run `awg-api` sidecar image |
| Port `8081` on base image | Map on `amneziawg` service in compose, or publish via `docker run -p 8081:8081` |
| `svc-awg-api` s6 service | API runs as separate container or host process |

---

## 9. Files to Create, Modify, or Delete

### Create
- `api/entrypoint.sh` — API sidecar entrypoint.
- `docker-compose.stack.yml` — 3-service compose reference.

### Modify
- `Dockerfile` — add `awg-api` target, remove API from base target.
- `api/config.go` — env-driven paths.
- `api/awg.go` — env-driven `awgBinary`.
- `root/etc/s6-overlay/s6-rc.d/svc-amneziawg/run` — write `/config/server/activeconfs`.
- `root/etc/s6-overlay/s6-rc.d/svc-amneziawg/finish` — fallback to `/config/server/activeconfs`.
- `root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run` — copy `/build_version` to `/config/server/build_version`.
- `.github/workflows/docker-build.yml` — build both targets, release binaries.

### Delete
- `root/etc/s6-overlay/s6-rc.d/svc-awg-api/` (entire directory).
- `root/etc/s6-overlay/s6-rc.d/user/contents.d/svc-awg-api`.

---

## 10. Design Decisions Log

| Question | Decision | Rationale |
|---|---|---|
| Single Dockerfile or separate `api/Dockerfile`? | **Single** with `--target` | Avoids duplicating `tools-builder` stage. |
| API image base: `alpine:3.24` or LSIO? | **`alpine:3.24`** | API doesn't need s6-overlay or init hooks. |
| Include `awg-quick` in API image? | **No** (only `awg`) | Current API is read-only; `awg-quick` not used. |
| How does the sidecar read tunnel stats? | **UAPI socket first, `awg show` fallback** | Userspace tunnels are read directly from `/run/amneziawg/<iface>.sock` (`api/uapi.go`) — no fork/exec and a self-describing `key=value` protocol instead of positional columns. Kernel-mode hosts expose no socket (the datapath is netlink), so `awg show all dump` remains as the fallback. Dropping `awg` entirely would require a native genetlink client for family `amneziawg` — a possible follow-up. |
| `ACTIVE_CONFS_PATH` default: `/run/activeconfs` or `/config/server/activeconfs`? | **`/run/activeconfs`** (with `/config/server` fallback) | Keeps existing finish-script logic working inside the VPN container while sharing state with the sidecar. |
| API versioning tied to base image? | **No** — independent semver | API evolves independently from upstream tools. |
