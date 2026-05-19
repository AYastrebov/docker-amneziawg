# Implementation Spec: API Decoupling

Split the monolithic image into two independently-published Docker images built from the same repository. The API sidecar is completely optional — the VPN image works standalone without it.

Based on [DECOUPLING.md](../DECOUPLING.md).

---

## Terminology

| Term | Meaning |
|---|---|
| **VPN image** | `ghcr.io/ayastrebov/docker-amneziawg` — the main container that runs tunnels |
| **API image** | `ghcr.io/ayastrebov/awg-api` — optional sidecar for REST API / WebSocket / Swagger |
| **sidecar** | Docker pattern: a helper container sharing volumes and/or network namespace with the primary |

---

## Step 0: Prerequisites

Merge the `feat/api` branch to `master` first. This spec assumes all current API code (handlers, logs, WebSocket, services, system metrics, tests) is already on the default branch.

---

## Step 1: Make API paths fully env-driven

The API binary must work both inside the VPN container (current all-in-one) and standalone in its own container with only `/config` mounted.

### 1.1 `api/config.go` — load paths from environment

Current package-level vars already exist. Add `init()` to read from env with current values as defaults:

```go
func init() {
    if v := os.Getenv("CONFIG_DIR"); v != "" {
        configDir = v
    }
    if v := os.Getenv("ACTIVE_CONFS_PATH"); v != "" {
        activeConfsPath = v
    }
    if v := os.Getenv("BUILD_VERSION_PATH"); v != "" {
        buildVersionPath = v
    }
    if v := os.Getenv("S6_ENV_DIR"); v != "" {
        s6EnvDir = v
    }
}
```

No behavior change when env vars are unset.

### 1.2 `api/awg.go` — env-driven binary path

```go
func init() {
    if v := os.Getenv("AWG_BINARY_PATH"); v != "" {
        awgBinary = v
    }
}
```

### 1.3 `api/system.go` — env-driven disk path

```go
func init() {
    if v := os.Getenv("CONFIG_DIR"); v != "" {
        diskPath = v
    }
}
```

### 1.4 `api/services.go` — graceful s6 degradation

Already degrades to `"unknown"` when `s6-svstat` is absent. The sidecar won't have s6. Remove `"svc-awg-api"` from `knownServices` since the API container can't query its own s6 status. In the sidecar it returns `[]` for all — acceptable.

### 1.5 Verification

Existing Go tests must still pass (they already override these vars). Add one test that sets `CONFIG_DIR` env var and confirms it takes effect.

---

## Step 2: VPN container shares state to `/config/server/`

The sidecar mounts the same `/config` volume but can't see the VPN container's `/run/` tmpfs. Two pieces of runtime state need sharing.

### 2.1 Active tunnel list

**File: `root/etc/s6-overlay/s6-rc.d/svc-amneziawg/run`**

After the existing `declare -p AWG_CONFS > /run/activeconfs`, add:

```bash
declare -p AWG_CONFS > /config/server/activeconfs
```

**File: `root/etc/s6-overlay/s6-rc.d/svc-amneziawg/finish`**

Add fallback to shared copy:

```bash
if [[ -f "/run/activeconfs" ]]; then
    . /run/activeconfs
elif [[ -f "/config/server/activeconfs" ]]; then
    . /config/server/activeconfs
fi
```

(Replace the existing `if [[ -f "/run/activeconfs" ]]` block.)

### 2.2 Build version

**File: `root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run`**

After config generation, add one line:

```bash
cp /build_version /config/server/build_version 2>/dev/null || true
```

This runs once at init, so the sidecar can read version info from the shared volume.

### 2.3 API sidecar default paths

In the sidecar image, the entrypoint sets these defaults:

| Variable | Sidecar default | Why different from VPN default |
|---|---|---|
| `ACTIVE_CONFS_PATH` | `/config/server/activeconfs` | Can't see `/run/activeconfs` |
| `BUILD_VERSION_PATH` | `/config/server/build_version` | Can't see `/build_version` |
| `S6_ENV_DIR` | `/config/server/s6env` | s6 container_environment not available |

The `CONFIG_DIR` and `AWG_BINARY_PATH` defaults stay the same (`/config`, `/usr/bin/awg`).

---

## Step 3: Dockerfile — two targets from shared build stages

Replace the current single-target Dockerfile with a multi-target build. Builder stages (1-3) are unchanged. The runtime stage splits into two targets.

### Layout

```
# Stage 1: go-builder        (amneziawg-go, unchanged)
# Stage 2: tools-builder     (awg + awg-quick, unchanged)
# Stage 3: api-builder        (awg-api binary + swag, unchanged)
# Stage 4a: runtime           (VPN image — default target)
# Stage 4b: awg-api           (API sidecar image)
```

### 4a: VPN image (`--target runtime`, default)

Same as current Stage 4 except:
- **Remove** `COPY --from=api-builder /awg-api /usr/bin/awg-api`
- **Remove** `EXPOSE 8081/tcp`
- The s6 `svc-awg-api` service directory is **deleted** from the repo (Step 5)

### 4b: API sidecar image (`--target awg-api`)

```dockerfile
# ============================================================================
# Stage 4b: API sidecar image
# ============================================================================
FROM alpine:3.21 AS awg-api

RUN apk add --no-cache ca-certificates netcat-openbsd

# awg binary for `awg show all dump`
COPY --from=tools-builder /tools-install/usr/bin/awg /usr/bin/awg
# awg-quick for potential future write operations
COPY --from=tools-builder /tools-install/usr/bin/awg-quick /usr/bin/awg-quick

# API binary
COPY --from=api-builder /awg-api /usr/bin/awg-api

# Entrypoint handles token generation and env defaults
COPY api/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/bin/awg /usr/bin/awg-quick

EXPOSE 8081/tcp

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
    CMD nc -z localhost ${API_PORT:-8081}

ENTRYPOINT ["/entrypoint.sh"]
```

**Key decisions:**
- Base: `alpine:3.21` — no LSIO overhead, no s6-overlay. The API is a single Go binary.
- Includes both `awg` AND `awg-quick` as the user specified it's OK to copy these. Useful for future write ops.
- `ca-certificates` for HTTPS if API ever needs outbound calls. `netcat-openbsd` for HEALTHCHECK.
- No `amneziawg-go` — the sidecar doesn't manage tunnels.

---

## Step 4: Create `api/entrypoint.sh`

```bash
#!/bin/sh
set -e

# --- Sidecar-specific defaults (different from VPN container defaults) ---
export CONFIG_DIR="${CONFIG_DIR:-/config}"
export ACTIVE_CONFS_PATH="${ACTIVE_CONFS_PATH:-/config/server/activeconfs}"
export BUILD_VERSION_PATH="${BUILD_VERSION_PATH:-/config/server/build_version}"
export S6_ENV_DIR="${S6_ENV_DIR:-/config/server/s6env}"
export AWG_BINARY_PATH="${AWG_BINARY_PATH:-/usr/bin/awg}"
export API_PORT="${API_PORT:-8081}"

# --- Token management ---
if [ -z "$API_TOKEN" ]; then
    if [ -f "$CONFIG_DIR/server/api_token" ]; then
        API_TOKEN=$(cat "$CONFIG_DIR/server/api_token")
    else
        API_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        mkdir -p "$CONFIG_DIR/server"
        printf '%s' "$API_TOKEN" > "$CONFIG_DIR/server/api_token"
        chmod 600 "$CONFIG_DIR/server/api_token"
        echo "API token generated: $API_TOKEN"
        echo "Save this token — it will not be shown again"
    fi
    export API_TOKEN
fi

# --- Wait for VPN container to populate config (optional) ---
if [ "${WAIT_FOR_CONFIG:-false}" = "true" ]; then
    echo "Waiting for VPN container to populate $CONFIG_DIR/server..."
    timeout=${WAIT_TIMEOUT:-60}
    elapsed=0
    while [ ! -f "$CONFIG_DIR/server/publickey-server" ] && [ "$elapsed" -lt "$timeout" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if [ ! -f "$CONFIG_DIR/server/publickey-server" ]; then
        echo "Warning: timed out waiting for config after ${timeout}s, starting anyway"
    fi
fi

exec /usr/bin/awg-api "$@"
```

---

## Step 5: Remove `svc-awg-api` from VPN image

### Delete files

```
root/etc/s6-overlay/s6-rc.d/svc-awg-api/type
root/etc/s6-overlay/s6-rc.d/svc-awg-api/run
root/etc/s6-overlay/s6-rc.d/svc-awg-api/notification-fd
root/etc/s6-overlay/s6-rc.d/svc-awg-api/dependencies.d/svc-amneziawg
root/etc/s6-overlay/s6-rc.d/svc-awg-api/dependencies.d/       (directory)
root/etc/s6-overlay/s6-rc.d/svc-awg-api/                       (directory)
root/etc/s6-overlay/s6-rc.d/user/contents.d/svc-awg-api
```

### Update `api/services.go`

Remove `"svc-awg-api"` from `knownServices` — the sidecar can't see its own s6 state, and the VPN container no longer has this service.

```go
knownServices = []string{
    "svc-amneziawg",
    "svc-coredns",
}
```

---

## Step 6: Docker Compose — sidecar wiring

### 6.1 Update `docker-compose.yml`

Replace the commented `USE_API` / `API_PORT` / `API_TOKEN` env vars with a sidecar service definition:

```yaml
services:
  amneziawg:
    image: ghcr.io/ayastrebov/docker-amneziawg:latest
    container_name: amneziawg
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      # - SERVERURL=auto
      # - PEERS=3
      # ... (existing AWG config vars unchanged)
    volumes:
      - ./config:/config
    ports:
      - 51820:51820/udp
      # API port is published here because awg-api shares this network namespace
      # - 8081:8081/tcp
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
    restart: unless-stopped

  # ---- Optional: REST API sidecar ----
  # Uncomment to enable the REST API on port 8081.
  # Shares the VPN container's network namespace (required for `awg show`).
  #
  # awg-api:
  #   image: ghcr.io/ayastrebov/awg-api:latest
  #   container_name: awg-api
  #   network_mode: service:amneziawg
  #   depends_on:
  #     amneziawg:
  #       condition: service_started
  #   volumes:
  #     - ./config:/config
  #   environment:
  #     # - API_TOKEN=            # Auto-generated if empty
  #     # - API_PORT=8081
  #     # - API_SWAGGER=true
  #     - WAIT_FOR_CONFIG=true    # Wait for VPN to generate configs before starting
  #   restart: unless-stopped
```

### 6.2 Key Docker Compose details

| Concern | Solution |
|---|---|
| **Network namespace** | `network_mode: service:amneziawg` — sidecar shares the VPN container's network stack. Required for `awg show all dump` to see tunnel interfaces via netlink. |
| **Port publishing** | `8081:8081/tcp` goes on the `amneziawg` service because the sidecar has no network of its own. |
| **Shared volume** | Both mount `./config:/config`. Peer configs, keys, AWG params, active tunnel list, and API token all live here. |
| **Startup ordering** | `depends_on` + `WAIT_FOR_CONFIG=true` ensures the API waits for the VPN to generate configs. |
| **No capabilities needed** | The sidecar only reads config files and runs `awg show`. No `NET_ADMIN`, no `SYS_MODULE`, no `/dev/net/tun`. |

### 6.3 `network_mode: service:*` implications

When using `network_mode: service:amneziawg`:
- The sidecar cannot define its own `ports:` — all port mappings go on `amneziawg`
- The sidecar cannot have its own `networks:` configuration
- `localhost` inside the sidecar IS the VPN container's network stack
- The sidecar can reach the VPN's CoreDNS at `127.0.0.1:53`
- Other compose services reach the API at `http://amneziawg:8081` (the VPN service name)

### 6.4 Alternative: UAPI socket sharing (userspace mode only)

When the VPN runs in userspace mode (`amneziawg-go`), the daemon creates a Unix socket at `/var/run/wireguard/awg0.sock`. The `awg show` command talks to this socket, not netlink. In theory, sharing just this socket directory via a volume (`awg_sockets:/var/run/wireguard`) could replace `network_mode: service:amneziawg`.

**Not recommended as the primary approach** because:
- When the kernel module is loaded (the preferred fast path), `awg` uses netlink — no socket exists. This approach only works in userspace mode.
- `network_mode: service:*` works universally for both kernel and userspace modes.

However, this could be a fallback for environments where network namespace sharing is problematic (e.g., some orchestrators that don't support `network_mode: service:*`).

---

## Step 7: CI/CD — build and publish both images

### 7.1 Update `.github/workflows/docker-build.yml`

The workflow needs two `docker/build-push-action` steps: one for each target.

**Add API image metadata step:**

```yaml
- name: Extract metadata for API image
  id: api-meta
  uses: docker/metadata-action@v5
  with:
    images: ${{ env.REGISTRY }}/ayastrebov/awg-api
    tags: |
      type=raw,value=latest,enable={{is_default_branch}}
      type=ref,event=branch
      type=ref,event=pr
      type=semver,pattern={{version}}
      type=sha,prefix=sha-
```

**Modify existing VPN build step:**

Add `target: runtime` to the existing `docker/build-push-action`.

**Add API image build step (parallel with VPN):**

```yaml
- name: Build and push API image
  if: github.event_name != 'pull_request'
  uses: docker/build-push-action@v6
  with:
    context: .
    target: awg-api
    platforms: linux/amd64,linux/arm64
    push: true
    tags: ${{ steps.api-meta.outputs.tags }}
    labels: ${{ steps.api-meta.outputs.labels }}
    cache-from: type=gha,scope=awg-api
    cache-to: type=gha,mode=max,scope=awg-api
    build-args: |
      AMNEZIAWG_TOOLS_VERSION=${{ steps.versions.outputs.amneziawg_tools }}
      BUILDKIT_INLINE_CACHE=1
    provenance: false
    sbom: false
```

Note: the API image only needs `AMNEZIAWG_TOOLS_VERSION` (for the `awg` binary) — not `AMNEZIAWG_GO_VERSION`.

### 7.2 Update PR smoke tests

Add a second build + test block for the API image:

```bash
# Build API sidecar image
docker buildx build --platform linux/amd64 --load -t test-api-image \
  --target awg-api \
  --build-arg AMNEZIAWG_TOOLS_VERSION=${{ steps.versions.outputs.amneziawg_tools }} \
  .

# API sidecar smoke tests
echo "### API sidecar" >> "$GITHUB_STEP_SUMMARY"
docker run --rm test-api-image sh -c '
  test -x /usr/bin/awg && echo "awg: executable"
  test -x /usr/bin/awg-quick && echo "awg-quick: executable"
  test -x /usr/bin/awg-api && echo "awg-api: executable"
  test -x /entrypoint.sh && echo "entrypoint: executable"
'
echo "- API sidecar binaries present" >> "$GITHUB_STEP_SUMMARY"
```

Update the VPN image smoke tests:
- Remove checks for `awg-api` binary
- Remove checks for `svc-awg-api` service and its dependencies

### 7.3 Standalone binary release (future, not in scope)

The DECOUPLING.md proposes attaching `awg-api-linux-amd64` and `awg-api-linux-arm64` to GitHub Releases. This can be a follow-up — the two Docker images are the priority.

---

## Step 8: Documentation updates

### 8.1 `README.md`

Replace the current REST API section:

```markdown
## REST API (optional sidecar)

Add the `awg-api` sidecar container for a REST API with peer management,
live tunnel stats, and Swagger UI. See [API.md](API.md) for endpoints.

```yaml
services:
  amneziawg:
    image: ghcr.io/ayastrebov/docker-amneziawg:latest
    # ... (existing config)
    ports:
      - 51820:51820/udp
      - 8081:8081/tcp          # API port (published here, used by sidecar)

  awg-api:
    image: ghcr.io/ayastrebov/awg-api:latest
    network_mode: service:amneziawg
    depends_on: [amneziawg]
    volumes:
      - ./config:/config
    environment:
      - WAIT_FOR_CONFIG=true
```
```

### 8.2 `API.md`

Update Quick Start section to show the sidecar compose setup instead of `USE_API=true`.

### 8.3 `CLAUDE.md`

- Update Dockerfile description: "4-stage multi-arch build with two targets"
- Update s6-overlay service chain: remove `svc-awg-api`
- Add sidecar architecture note under a new "API Sidecar" section
- Remove `USE_API` from env var documentation
- Add note about `network_mode: service:amneziawg` requirement

---

## Step 9: Remove `USE_API` env var support

The VPN container no longer runs the API. Remove all references:

| File | What to remove |
|---|---|
| `docker-compose.yml` | `USE_API`, `API_PORT`, `API_TOKEN`, `API_READONLY` env vars |
| `CLAUDE.md` | `USE_API` references, `svc-awg-api` description |
| `README.md` | Old API section |
| `.github/workflows/docker-build.yml` | `svc-awg-api` smoke test checks |

---

## File Inventory

### Create

| File | Purpose |
|---|---|
| `api/entrypoint.sh` | Sidecar entrypoint: env defaults, token management, config wait |

### Modify

| File | Changes |
|---|---|
| `Dockerfile` | Add `awg-api` target stage; remove API binary + port from VPN target |
| `api/config.go` | Add `init()` reading `CONFIG_DIR`, `ACTIVE_CONFS_PATH`, `BUILD_VERSION_PATH`, `S6_ENV_DIR` from env |
| `api/awg.go` | Add `init()` reading `AWG_BINARY_PATH` from env |
| `api/system.go` | Add `init()` reading `CONFIG_DIR` into `diskPath` |
| `api/services.go` | Remove `"svc-awg-api"` from `knownServices` |
| `root/etc/s6-overlay/s6-rc.d/svc-amneziawg/run` | Add `declare -p AWG_CONFS > /config/server/activeconfs` |
| `root/etc/s6-overlay/s6-rc.d/svc-amneziawg/finish` | Add fallback to `/config/server/activeconfs` |
| `root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run` | Add `cp /build_version /config/server/build_version` |
| `docker-compose.yml` | Replace `USE_API` vars with commented sidecar service |
| `.github/workflows/docker-build.yml` | Build both targets; add API smoke tests; remove `svc-awg-api` VPN checks |
| `README.md` | Update REST API section to sidecar pattern |
| `API.md` | Update Quick Start to sidecar compose |
| `CLAUDE.md` | Update architecture, remove `svc-awg-api`, add sidecar notes |

### Delete

| File | Reason |
|---|---|
| `root/etc/s6-overlay/s6-rc.d/svc-awg-api/` | Entire directory — API no longer runs inside VPN container |
| `root/etc/s6-overlay/s6-rc.d/user/contents.d/svc-awg-api` | Service registration |

---

## Verification Checklist

1. **VPN image builds:** `docker buildx build --target runtime -t vpn-test .`
2. **API image builds:** `docker buildx build --target awg-api -t api-test .`
3. **VPN image has NO awg-api binary:** `docker run --rm vpn-test which awg-api` → not found
4. **API image has awg + awg-quick + awg-api:** confirmed present and executable
5. **API image has no s6-overlay:** no `/etc/s6-overlay/` directory
6. **Go tests pass:** `cd api && go test -race ./...` — env var overrides still work
7. **Compose stack works:**
   - VPN starts and generates configs
   - API sidecar starts after VPN, reads config from shared volume
   - `curl http://localhost:8081/health` → 200
   - `curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/peers` → peer list
   - `curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/tunnels` → tunnel stats (requires `/dev/net/tun`)
8. **VPN-only works:** VPN container alone with no sidecar — no errors, no dangling service
9. **Multi-arch:** both `linux/amd64` and `linux/arm64` build and push for both images
