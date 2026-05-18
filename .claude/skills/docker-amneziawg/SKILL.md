---
name: docker-amneziawg
description: |
  Development skill for the docker-amneziawg project - an AmneziaWG VPN container with LinuxServer.io architecture and optional REST API. Use when working in the docker-amneziawg repository for: (1) Adding features or fixing bugs, (2) Modifying s6-overlay services, (3) Updating config generation, (4) Working with AmneziaWG obfuscation parameters, (5) Developing the Go REST API (adding routes, writing tests, security patterns), (6) Testing or building the Docker image. Triggers when working in a directory containing this project's structure (root/etc/s6-overlay, awg-related files, api/ Go code).
---

# docker-amneziawg Development Guide

## Documentation Layout

| File | Audience | Purpose |
|------|----------|---------|
| `README.md` | End users | Setup, usage, parameters (LinuxServer-style) |
| `CONTEXT.md` | AI agents | Architecture, parameter deep-dives, troubleshooting, CI/CD |
| `CLAUDE.md` | Developers | Dev patterns, conventions, gotchas, build/test commands |
| `API.md` | API consumers | Endpoint docs, curl examples, WebSocket usage |

For architecture details, parameter constraints, or troubleshooting tables, read `CONTEXT.md`.
For AWG parameter implementation specifics, read [references/awg-parameters.md](references/awg-parameters.md).

## Project Overview

AmneziaWG Docker container built on LinuxServer.io base images with s6-overlay process supervision. Provides automatic VPN configuration generation with DPI-bypass obfuscation.

Two modes: **server** (set `PEERS` to auto-generate configs) and **client** (place `.conf` files in `/config/wg_confs/`).

Optional REST API (`USE_API=true`) for programmatic access to peer configs, QR codes, tunnel stats, and server info.

## Project Structure

```
docker-amneziawg/
├── Dockerfile                    # 4-stage build (go-builder, tools-builder, api-builder, runtime)
├── docker-compose.yml            # Example configurations
├── CONTEXT.md                    # Technical reference for AI agents
├── API.md                        # REST API endpoint documentation
├── api/                          # Go REST API (Gin framework)
│   ├── main.go                   # Entry point, router, graceful shutdown
│   ├── middleware.go             # Bearer token auth (constant-time comparison)
│   ├── handlers.go              # Route handlers, response helpers
│   ├── awg.go                   # awg show all dump parser
│   ├── config.go                # Peer/server config readers, ResolvePeerID
│   ├── ws.go                    # WebSocket hub with context-based shutdown
│   ├── *_test.go                # Tests (59 tests, race-detector clean)
│   └── docs/                    # Auto-generated Swagger/OpenAPI (do not edit)
├── root/
│   ├── app/
│   │   └── show-peer             # QR code display utility
│   ├── defaults/
│   │   ├── server.conf           # Server config template (eval+heredoc)
│   │   ├── peer.conf             # Peer config template (eval+heredoc)
│   │   └── Corefile              # CoreDNS default config
│   └── etc/s6-overlay/s6-rc.d/
│       ├── init-amneziawg-module/    # Kernel module detection (oneshot)
│       ├── init-amneziawg-confs/     # Config generation (oneshot)
│       ├── svc-coredns/              # CoreDNS service (longrun)
│       ├── svc-amneziawg/            # Tunnel service (oneshot up/down)
│       ├── svc-awg-api/              # REST API service (longrun, disabled by default)
│       └── user/contents.d/          # Service registration (empty files)
└── .github/workflows/
    ├── docker-build.yml              # Main build pipeline (multi-arch)
    └── upstream-check.yml            # Daily upstream version check
```

## S6-Overlay Architecture

### Service Dependency Chain
```
init-amneziawg-module (oneshot) -> init-amneziawg-confs (oneshot) -> svc-coredns (longrun) -> svc-amneziawg (oneshot) -> svc-awg-api (longrun)
```

Key points:
- `svc-amneziawg` is a **oneshot** — tunnels stay up without a running process
- `svc-coredns` is a **longrun** — continuously serves DNS for peers
- `svc-awg-api` is a **longrun** — disabled by default, runs `sleep infinity` when `USE_API != true`
- Dependencies: empty files in `dependencies.d/`. Registration: empty files in `user/contents.d/`

### Script Requirements
- Shebang: `#!/usr/bin/with-contenv bash`
- Must be executable (`chmod +x`)
- Use `lsiown` for LinuxServer permission management

## Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PEERS` | - | Enables server mode. Number ("3") or names ("laptop,phone") |
| `SERVERURL` | auto | Server URL/IP for peer configs |
| `SERVERPORT` | 51820 | Port advertised to peers. Use <= 9999 if ISP blocks high UDP |
| `INTERNAL_SUBNET` | 10.13.13.0 | VPN subnet (.1 = server, .2+ = peers) |
| `PEERDNS` | auto | DNS for peers (auto = container's CoreDNS at subnet.1) |
| `LOG_CONFS` | true | Show QR codes in container logs |
| `AWG_VERSION` | 2.0 | Protocol version: 2.0 (full DPI evasion) or 1.5 (legacy) |
| `USE_API` | false | Enable REST API on port API_PORT |
| `API_PORT` | 8081 | TCP listen port for the API (8080 taken by CoreDNS health) |
| `API_TOKEN` | auto | Bearer token. Auto-generated to `/config/server/api_token` on first run |
| `API_READONLY` | true | Reserved for future write operations |

## AmneziaWG Obfuscation — Quick Reference

For detailed parameter docs, see [references/awg-parameters.md](references/awg-parameters.md) or `CONTEXT.md`.

| Param | Default | Key Constraint |
|-------|---------|----------------|
| `AWG_S1` | Random 15-150 | <= 1132, **S1+56 must not equal S2** |
| `AWG_S2` | Random 15-150 | <= 1188 |
| `AWG_S3` | Random 8-55 (2.0) / 0 (1.5) | <= 64 |
| `AWG_S4` | Random 4-27 (2.0) / 0 (1.5) | <= 32, **per-packet overhead — keep small** |
| `AWG_H1-H4` | Range (2.0) / int (1.5) | >= 5, all unique, non-overlapping |
| `AWG_I1-I5` | Auto QUIC Initial (2.0) / empty (1.5) | In `[Interface]` before `[Peer]` |

**Critical**: Server and all clients must use identical S1-S4, H1-H4, I1-I5 values. Jc/Jmin/Jmax may differ.

## Common Development Tasks

### Adding a New Environment Variable
1. Set default in `init-amneziawg-confs/run` main logic section
2. If persistent: add to `save_vars()` (as `ORIG_X`) AND the change detection `if` block
3. For AWG params: also add to `generate_awg_params()` save block AND `load_awg_params()` grep section
4. For config output: add to templates in `root/defaults/` (eval+heredoc), `append_awg_signatures()` (server conf), or `append_awg_signatures_to_interface()` (peer confs — inserts before `[Peer]` via awk)
5. Document in `docker-compose.yml` and `README.md`

### Testing Container Changes
```bash
docker build -t amneziawg-test .
docker run -d --name awg-test --cap-add NET_ADMIN \
  -e PEERS=2 -e SERVERURL=test.example.com \
  -v /tmp/awg-test:/config amneziawg-test
docker logs awg-test
docker exec awg-test cat /config/wg_confs/wg0.conf
docker exec awg-test cat /config/peer1/peer1.conf
docker rm -f awg-test
```

Tunnel startup fails without `--device /dev/net/tun` — expected in testing.

## REST API Development

The API is a standalone Go binary (`/usr/bin/awg-api`) built from the `api/` directory. It reads the same `/config` volume as the container and calls `/usr/bin/awg` for live tunnel stats.

### File Layout

| File | Responsibility |
|------|---------------|
| `main.go` | Gin router setup, signal handling, graceful shutdown. WebSocket hub lifecycle managed via `context.Context` |
| `middleware.go` | `BearerAuth` middleware using `crypto/subtle.ConstantTimeCompare`. Also exports `constantTimeTokenMatch` for WebSocket auth |
| `handlers.go` | One handler per endpoint. `internalError()` logs full error server-side, returns generic message to client |
| `awg.go` | `ParseAWGDump()` parses tab-separated `awg show all dump` output. Binary called via absolute path `/usr/bin/awg` |
| `config.go` | `ResolvePeerID()`, `GetServerInfo()`, `ListPeers()`, `GetPeerDetail()`. Reads peer dirs, awg_params, s6 env files |
| `ws.go` | `Hub` with `Run(ctx)` for context-based shutdown. `CheckOrigin` validates Origin matches Host. Broadcasts stats every 2s |
| `docs/` | Auto-generated by `swag init` — never edit manually |

### Patterns

**Response envelope** — every endpoint uses the same format:
```go
// Success
SuccessResponse(data)  // → {"data": ...}

// Errors
ErrorResponse("NOT_FOUND", "Peer X not found")      // → {"error": {"code": "...", "message": "..."}}
internalError(c, err)                                 // logs err, returns generic 500
```

**Peer ID resolution** — user input goes through `ResolvePeerID()` which:
- Numeric `"1"` becomes `"peer1"`
- Named `"laptop"` becomes `"peer_laptop"`
- Already-prefixed `"peer_laptop"` passes through
- ALL output is sanitized through `safeNameRe` (`[^a-zA-Z0-9_-]`), stripping `../` and any special characters. This prevents path traversal regardless of input.

**Mockable externals** — the `awg` binary is never called in tests. Package-level vars allow test overrides:
```go
var getTunnelStatsFunc = getTunnelStatsReal  // replaced by mockTunnelStats(t) in tests
var configDir = "/config"                     // replaced by setupTestPaths(t, tmpDir)
```

**WebSocket hub** — `Hub.Run(ctx)` selects on `ctx.Done()` to exit cleanly. On cancel, it closes all client connections and returns. The main function creates a `context.WithCancel` and calls `hubCancel()` before server shutdown.

**Typed broadcast** — WebSocket messages use `StatsSnapshot` struct (not `map[string]interface{}`):
```go
type StatsSnapshot struct {
    Data      []TunnelInfo `json:"data"`
    Timestamp string       `json:"timestamp"`
    Error     string       `json:"error,omitempty"`
}
```

### Security Patterns

These are the security measures in the API code. Maintain them when adding new endpoints:

- **Constant-time token comparison** — `crypto/subtle.ConstantTimeCompare` in both `BearerAuth` middleware and WebSocket query param auth. Never use `==` for token comparison.
- **Path traversal prevention** — `ResolvePeerID` sanitizes all output through `safeNameRe`. Even input starting with `"peer"` gets sanitized, so `peer../../etc` becomes `peeretc`.
- **Error sanitization** — `internalError()` logs the real error with `log.Printf`, returns `"Internal server error"` to the client. Never pass `err.Error()` to the response.
- **Absolute binary path** — `awgBinary = "/usr/bin/awg"` prevents PATH manipulation.
- **WebSocket origin check** — `CheckOrigin` allows requests with no Origin header (non-browser clients like curl) but validates that Origin host matches request Host when present.
- **Private keys in peer configs** — `/peers/:id/config` returns the raw `.conf` file including the peer's private key. This is by design (provisioning endpoint). The Bearer token is the only access control.

### Testing the API

Run all tests with the race detector:
```bash
cd api && go test ./... -count=1 -race
```

**Test helpers** in `testhelper_test.go`:

| Helper | What it does |
|--------|-------------|
| `setupTestRouter(t)` | Creates Gin router with all routes. Hub goroutine cleaned up via `context.WithCancel` + `t.Cleanup(cancel)` |
| `setupTestConfig(t)` | Creates temp dir with peer1, peer_laptop, server keys, awg_params. All `os.MkdirAll`/`os.WriteFile` errors checked with `t.Fatal` |
| `setupTestPaths(t, dir)` | Overrides package-level path vars, restores originals via `t.Cleanup` |
| `mockTunnelStats(t)` | Replaces `getTunnelStatsFunc` with canned data (wg0, 2 peers) |
| `mockTunnelStatsError(t)` | Makes `GetTunnelStats` return an error — for testing 500 paths |
| `mustUnmarshal(t, data, v)` | `json.Unmarshal` that fails the test on error, not silently |
| `doRequest(r, method, path, headers)` | Shorthand for httptest request/response |
| `authHeader()` | Returns valid `Authorization: Bearer ...` header |

**What to test for every endpoint:**
1. Happy path (200 with expected data)
2. Authentication (401 without token)
3. Not found (404 for missing peer)
4. Server error (500 using `mockTunnelStatsError`, verify internal details are NOT leaked)
5. Path traversal payloads (if endpoint takes user input)

### Adding a New API Endpoint

1. Write the handler in `handlers.go` with swaggo annotations:
   ```go
   // handleNewThing godoc
   // @Summary Short description
   // @Tags peers
   // @Security BearerAuth
   // @Success 200 {object} apiResponse
   // @Failure 401 {object} apiError
   // @Router /api/v1/new-thing [get]
   func handleNewThing(c *gin.Context) { ... }
   ```
2. Register the route in `main.go` inside the `v1` group (for auth) or outside (for public)
3. Add the same route in `setupTestRouter()` in `testhelper_test.go`
4. Write tests covering happy path, 401, 404/500 error paths
5. Regenerate OpenAPI docs: `cd api && swag init --parseDependency --output docs`
6. Update `API.md` with endpoint documentation and curl examples

### Adding an Env Var Consumed by the API

1. Read it via `readEnvFile("VAR_NAME")` in config.go — this checks s6 env files first, falls back to `os.Getenv`
2. Export it in the s6 run script: `root/etc/s6-overlay/s6-rc.d/svc-awg-api/run`
3. Document in `docker-compose.yml` (commented example) and `README.md` parameters table

## Common Gotchas

| Issue | Solution |
|-------|----------|
| `local: can only be used in a function` | Remove `local` keyword from main script body |
| awg-quick not found in build | Copy from `src/wg-quick/linux.bash`, not compiled |
| Service not starting | Check: executable bit, shebang, registered in `user/contents.d/` |
| Exit code 137 | Normal — container was stopped (SIGKILL) |
| I1-I5 must be in `[Interface]`, not `[Peer]` | Use `append_awg_signatures_to_interface()` for peer confs |
| `cut -d= -f2` truncates I-params with `=` | Use `cut -d= -f2-` (tag syntax contains `=` signs) |
| Loading `awg_params` with `source` | Never — overrides Docker env vars. Use `grep`/`cut` with `${VAR:-fallback}` |
| Amnezia app shows AWG 1.5 instead of 2.0 | H1-H4 must use range format, not single integers |
| `SERVERPORT` mapping in Docker | Map as `SERVERPORT:51820/udp` — container always listens on 51820 internally |
| API tests fail with "awg not available" | Expected — `mockTunnelStats(t)` replaces the real binary call. The log line comes from `mockTunnelStatsError` tests |
| `swag init` fails | Run from the `api/` directory with `--parseDependency --output docs` |
| Hub goroutine leak in tests | Always pass `context.WithCancel` to `hub.Run(ctx)` and call `t.Cleanup(cancel)` |

## GitHub Actions Workflows

### docker-build.yml
- Push to `master`/`main` -> builds multi-arch and tags as `latest` + tools version
- Push `v*` tags -> semantic version tags (1.0.0, 1.0, 1)
- Pull requests -> single-platform smoke test (no push)
- `workflow_dispatch` accepts version overrides
- Smoke tests verify: binaries (including `awg-api`), s6 structure, service types, dependency chain

### upstream-check.yml
- Daily at 06:00 UTC: compares Dockerfile ARG defaults against latest upstream releases
- Auto-updates Dockerfile and triggers build if new version found
- Has concurrency control and version format validation

Multi-arch: `linux/amd64`, `linux/arm64`
