# REST API Sidecar Rebase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the REST API sidecar from PR #10 onto today's `master`, aligned with the AWG 3.0 merge and the reworked CI, fixing the five issues found in the sidecar audit.

**Architecture:** The API is a separate Go binary shipped as a second image target from the same Dockerfile. The VPN container stays unchanged and slim; the sidecar joins its network namespace and reads the shared `/config` volume. This plan reapplies that work on a fresh branch rather than rebasing 13 stale commits, because intermediate commits reference Alpine 3.21 stages and would not build.

**Tech Stack:** Go 1.25 (Gin, gorilla/websocket, swaggo), Docker multi-stage/multi-target, GitHub Actions, bash (s6-overlay).

**Spec:** `docs/superpowers/specs/2026-07-31-api-sidecar-rebase-design.md`

**Branch:** `feat/api-v2`, already created from `master` at `fc3ecdc`. The spec's design commit (`96b5a0a`) is already on it.

## Global Constraints

- Source branch for all `api/` files: `origin/feat/api` (PR #10). Retrieve with `git show origin/feat/api:<path>`. Do not invent API code.
- `feat/api` and PR #10 must remain untouched until the replacement is accepted.
- Image bases must match master exactly: `golang:1.25.12-alpine`, `alpine:3.24`, `ghcr.io/linuxserver/baseimage-alpine:3.24`.
- `api/go.mod` keeps `go 1.24.4`. Do not raise it.
- Upstream pins stay as master has them: `AMNEZIAWG_GO_VERSION=v3.0.2`, `AMNEZIAWG_TOOLS_VERSION=v3.0.20260730`. The CI's Dockerfile-as-source-of-truth logic must keep working.
- The VPN (`runtime`) image must never contain `/usr/bin/awg-api` or `/etc/s6-overlay/s6-rc.d/svc-awg-api`.
- Go indentation is tabs. Shell scripts in `root/` use 4 spaces; Dockerfile and YAML use 2.
- The final PR is squash-merged, so per-task commits are fine — no need to collapse them into the spec's five-commit narrative.
- **The compose-stack test and multi-arch build cannot be verified on macOS.** Do not mark them done. Task 10 records them as requiring a Linux host.

---

### Task 1: Import the API source tree

Brings in PR #10's `api/` directory unchanged, establishing a green baseline before any fixes. Importing and fixing in one step would make it impossible to tell whether a test failure came from the port or the fix.

**Files:**
- Create: everything under `api/` (28 files)

**Interfaces:**
- Produces: package `main` in `api/`, including `readAWGParams() map[string]string`, `swaggerEnabled() bool`, `HandleWebSocket(hub *Hub, c *gin.Context)`, `HandleLogsWebSocket(store *LogStore, c *gin.Context)`, `constantTimeTokenMatch(got, expected string) bool`, and the test helpers `setupTestConfig(t *testing.T) string` / `setupTestPaths(t *testing.T, cfgDir string)`.

- [ ] **Step 1: Copy the api/ tree from the old branch**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
git checkout origin/feat/api -- api/
git status --short api/ | head -40
```

Expected: 28 files staged as new, including `main.go`, `config.go`, `handlers.go`, `ws.go`, `logs.go`, `awg.go`, `awg_events.go`, `system.go`, `services.go`, `middleware.go`, `entrypoint.sh`, `.golangci.yml`, `go.mod`, `go.sum`, `docs/docs.go`, and 13 `*_test.go` files.

- [ ] **Step 2: Verify the tree builds and tests pass**

```bash
cd api && go build ./... && go test -race ./... 2>&1 | tail -20
```

Expected: build succeeds; all tests PASS. If `go.sum` entries are missing, run `go mod download` and re-run — do not edit `go.mod`.

- [ ] **Step 3: Confirm the dependency versions match the spec's assumptions**

```bash
grep -E "gin-gonic/gin |gorilla/websocket " api/go.mod
```

Expected: `github.com/gin-gonic/gin v1.10.0` and `github.com/gorilla/websocket v1.5.3`. Task 3's fix depends on gin v1.10.0's logger behaviour; if the version differs, stop and report.

- [ ] **Step 4: Commit**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
git add api/
git commit -m "feat(api): REST API sidecar service

Imports the REST API sidecar from PR #10 unchanged: server info, tunnel
and peer state, host metrics, s6 service status, structured logs, and
WebSocket feeds for stats and logs. Audit fixes follow in separate commits."
```

---

### Task 2: Finding 1 — allowlist AWG params so the header protection key cannot leak

`readAWGParams` currently copies every `AWG_*` line from `/config/server/awg_params` into a map served by `GET /api/v1/server`. Since the AWG 3.0 merge that file also contains `AWG_HEADER_PROTECTION_KEY`, a symmetric secret shared with every client.

**Files:**
- Modify: `api/config.go` (function `readAWGParams`, and a new package-level var above it)
- Test: `api/config_test.go` (add one test)

**Interfaces:**
- Consumes: `readAWGParams() map[string]string` from Task 1.
- Produces: `awgParamAllowlist map[string]struct{}` — package-level, consulted by `readAWGParams`. Signature of `readAWGParams` is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `api/config_test.go`:

```go
func TestReadAWGParams_ExcludesSecrets(t *testing.T) {
	tmpDir := t.TempDir()
	origConfigDir := configDir
	configDir = tmpDir
	defer func() { configDir = origConfigDir }()

	serverDir := filepath.Join(tmpDir, "server")
	if err := os.MkdirAll(serverDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(serverDir, "awg_params"), []byte(
		"AWG_VERSION=3.0\n"+
			"AWG_JC=5\n"+
			"AWG_CONTENT_PADDING=32-55\n"+
			"AWG_REKEY_AFTER_TIME=101-113\n"+
			"AWG_HEADER_PROTECTION_KEY=kSg0FM1gjG7HCRXgfZImxrWfAKbb14YiRXnP9I6iQFI=\n"+
			"AWG_FUTURE_SECRET=should-not-appear\n",
	), 0644); err != nil {
		t.Fatal(err)
	}

	params := readAWGParams()

	// Allowlisted params still come through, including the 3.0 additions.
	if params["version"] != "3.0" {
		t.Errorf("version = %q, want 3.0", params["version"])
	}
	if params["content_padding"] != "32-55" {
		t.Errorf("content_padding = %q, want 32-55", params["content_padding"])
	}
	if params["rekey_after_time"] != "101-113" {
		t.Errorf("rekey_after_time = %q, want 101-113", params["rekey_after_time"])
	}

	// The shared secret must never be exposed.
	if v, ok := params["header_protection_key"]; ok {
		t.Errorf("header_protection_key leaked to API: %q", v)
	}

	// Unknown keys are dropped, so a future secret fails closed.
	if v, ok := params["future_secret"]; ok {
		t.Errorf("unknown param future_secret leaked: %q", v)
	}
}
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd api && go test -run TestReadAWGParams_ExcludesSecrets -v ./... 2>&1 | tail -15
```

Expected: FAIL with `header_protection_key leaked to API: "kSg0FM1..."` and `unknown param future_secret leaked`.

- [ ] **Step 3: Add the allowlist**

In `api/config.go`, immediately above `func readAWGParams()`, insert:

```go
// awgParamAllowlist enumerates the AWG parameters that are safe to expose over
// the API. readAWGParams drops anything absent from this set, so a secret
// written into awg_params — AWG_HEADER_PROTECTION_KEY today, whatever upstream
// adds tomorrow — is excluded by default rather than leaking until someone
// notices. Adding a genuinely new non-secret parameter here is a one-liner.
var awgParamAllowlist = map[string]struct{}{
	"version": {},
	"jc":      {}, "jmin": {}, "jmax": {},
	"s1": {}, "s2": {}, "s3": {}, "s4": {},
	"h1": {}, "h2": {}, "h3": {}, "h4": {},
	"i1": {}, "i2": {}, "i3": {}, "i4": {}, "i5": {},
	// AWG 3.0 — timers and padding are not secret; the header protection key is.
	"content_padding":        {},
	"rekey_after_time":       {},
	"rekey_timeout":          {},
	"reject_after_time":      {},
	"keepalive_timeout":      {},
	"max_handshake_attempts": {},
}
```

- [ ] **Step 4: Enforce it in the parse loop**

In `readAWGParams`, replace these three lines:

```go
			key := strings.TrimPrefix(strings.TrimSpace(k), "AWG_")
			key = strings.ToLower(key)
			params[key] = strings.TrimSpace(v)
```

with:

```go
			key := strings.TrimPrefix(strings.TrimSpace(k), "AWG_")
			key = strings.ToLower(key)
			if _, allowed := awgParamAllowlist[key]; !allowed {
				continue
			}
			params[key] = strings.TrimSpace(v)
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd api && go test -race ./... 2>&1 | tail -15
```

Expected: PASS, including the pre-existing `TestReadAWGParams` (its `version`, `jc`, and `i1` keys are all allowlisted).

- [ ] **Step 6: Commit**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
git add api/config.go api/config_test.go
git commit -m "fix(api): allowlist AWG params so the header protection key cannot leak

readAWGParams copied every AWG_* line from /config/server/awg_params into
the response of GET /api/v1/server. Since AWG 3.0 that file also holds
AWG_HEADER_PROTECTION_KEY — a symmetric key that must be identical on the
server and every client — so the endpoint exposed a shared secret.

Replaces pass-through with an explicit allowlist covering the obfuscation
parameters and the 3.0 timers. Unknown keys are dropped, so a future
upstream secret is excluded by default instead of leaking silently."
```

---

### Task 3: Finding 2 — accept the WebSocket token via header instead of the query string

Both WS routes authenticate with `?token=`. gin v1.10.0's logger appends the raw query to the logged path (`logger.go:273`), so every connect writes `/api/v1/ws/stats?token=<secret>` to the sidecar's stdout and to any reverse-proxy access log.

**Files:**
- Modify: `api/ws.go` (upgrader config, new `wsToken` helper)
- Modify: `api/main.go` (both WS route closures, logger `SkipPaths`)
- Test: `api/ws_test.go`

**Interfaces:**
- Consumes: `constantTimeTokenMatch(got, expected string) bool` from Task 1.
- Produces: `wsToken(c *gin.Context) string` in `api/ws.go` — returns the presented token, or `""` if none was supplied by any accepted mechanism.

- [ ] **Step 1: Write the failing test**

Append to `api/ws_test.go`:

```go
func TestWSToken_PrecedenceAndFallbacks(t *testing.T) {
	gin.SetMode(gin.TestMode)

	newCtx := func(target string, headers map[string]string) *gin.Context {
		req := httptest.NewRequest(http.MethodGet, target, nil)
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		c, _ := gin.CreateTestContext(httptest.NewRecorder())
		c.Request = req
		return c
	}

	tests := []struct {
		name    string
		target  string
		headers map[string]string
		want    string
	}{
		{
			name:    "subprotocol wins",
			target:  "/api/v1/ws/stats?token=fromquery",
			headers: map[string]string{"Sec-WebSocket-Protocol": "bearer, fromproto"},
			want:    "fromproto",
		},
		{
			name:    "authorization header used when no subprotocol",
			target:  "/api/v1/ws/stats?token=fromquery",
			headers: map[string]string{"Authorization": "Bearer fromheader"},
			want:    "fromheader",
		},
		{
			name:   "query string still works (deprecated)",
			target: "/api/v1/ws/stats?token=fromquery",
			want:   "fromquery",
		},
		{
			name:   "nothing supplied",
			target: "/api/v1/ws/stats",
			want:   "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := wsToken(newCtx(tt.target, tt.headers)); got != tt.want {
				t.Errorf("wsToken() = %q, want %q", got, tt.want)
			}
		})
	}
}
```

Ensure `api/ws_test.go` imports `net/http`, `net/http/httptest`, and `github.com/gin-gonic/gin`.

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd api && go test -run TestWSToken_PrecedenceAndFallbacks ./... 2>&1 | tail -10
```

Expected: FAIL to compile — `undefined: wsToken`.

- [ ] **Step 3: Implement wsToken**

In `api/ws.go`, add after the `upgrader` var:

```go
// wsToken extracts the bearer token from a WebSocket handshake, in precedence
// order: Sec-WebSocket-Protocol (the only header a browser can set on a WS
// handshake), then Authorization for non-browser clients, then the deprecated
// ?token= query parameter. The query form is retained for one release because
// gin logs raw query strings, which is what put the token in access logs.
func wsToken(c *gin.Context) string {
	protos := websocket.Subprotocols(c.Request)
	for i, p := range protos {
		if strings.EqualFold(p, "bearer") && i+1 < len(protos) {
			return protos[i+1]
		}
	}

	if auth := c.GetHeader("Authorization"); auth != "" {
		parts := strings.SplitN(auth, " ", 2)
		if len(parts) == 2 && strings.EqualFold(parts[0], "Bearer") {
			return parts[1]
		}
	}

	if q := c.Query("token"); q != "" {
		slog.Warn("websocket token supplied via query string is deprecated and will be removed; use Sec-WebSocket-Protocol: bearer, <token>",
			"path", c.Request.URL.Path)
		return q
	}

	return ""
}
```

Add `"log/slog"` and `"strings"` to `api/ws.go`'s imports if not already present.

- [ ] **Step 4: Make the server echo the negotiated subprotocol**

In `api/ws.go`, add the `Subprotocols` field to the existing `upgrader` var so gorilla selects and echoes `bearer` when the client offers it (browsers reject a handshake whose subprotocol is not echoed):

```go
var upgrader = websocket.Upgrader{
	Subprotocols: []string{"bearer"},
	CheckOrigin: func(r *http.Request) bool {
```

Leave the existing `CheckOrigin` body untouched.

- [ ] **Step 5: Use it in both routes**

In `api/main.go`, replace the two WS route closures:

```go
	r.GET("/api/v1/ws/stats", func(c *gin.Context) {
		wsToken := c.Query("token")
		if wsToken == "" || !constantTimeTokenMatch(wsToken, token) {
```

becomes:

```go
	r.GET("/api/v1/ws/stats", func(c *gin.Context) {
		presented := wsToken(c)
		if presented == "" || !constantTimeTokenMatch(presented, token) {
```

and the same substitution in the `/api/v1/ws/logs` route (`presented := wsToken(c)`, `if presented == "" || !constantTimeTokenMatch(presented, token)`).

- [ ] **Step 6: Stop logging the legacy query form**

In `api/main.go`, replace:

```go
		SkipPaths: []string{"/health"},
```

with:

```go
		// WS paths are skipped because the deprecated ?token= form would
		// otherwise be written to the access log verbatim.
		SkipPaths: []string{"/health", "/api/v1/ws/stats", "/api/v1/ws/logs"},
```

- [ ] **Step 7: Run the tests**

```bash
cd api && go test -race ./... 2>&1 | tail -15
```

Expected: PASS, including the pre-existing WS tests (the query form still authenticates).

- [ ] **Step 8: Commit**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
git add api/ws.go api/main.go api/ws_test.go
git commit -m "fix(api): accept WebSocket token via header, stop logging it

gin v1.10.0 appends the raw query string to the logged path, so every
WebSocket connect wrote /api/v1/ws/stats?token=<secret> to the sidecar's
stdout and to any reverse-proxy access log in front of it.

Adds Sec-WebSocket-Protocol (primary, browser-compatible) and
Authorization: Bearer (non-browser clients). The ?token= form still works
for one release with a deprecation warning, and the WS paths are added to
the logger's SkipPaths so it is no longer written meanwhile."
```

---

### Task 4: Finding 3 — make the Swagger UI opt-in

`/swagger/*any` is mounted outside the authenticated group and `swaggerEnabled()` returns true when `API_SWAGGER` is unset, so the whole API surface is readable unauthenticated by default. **This is a deliberate breaking change** — PR #10 chose on-by-default for backward compatibility.

**Files:**
- Modify: `api/main.go` (function `swaggerEnabled`)
- Test: `api/main_test.go`

**Interfaces:**
- Consumes: `swaggerEnabled() bool` from Task 1. Signature unchanged; only the unset-default flips.

- [ ] **Step 1: Write the failing test**

Append to `api/main_test.go`:

```go
func TestSwaggerEnabled_OptIn(t *testing.T) {
	tests := []struct {
		value string
		set   bool
		want  bool
	}{
		{set: false, want: false}, // unset now means disabled
		{value: "", set: true, want: false},
		{value: "true", set: true, want: true},
		{value: "TRUE", set: true, want: true},
		{value: "1", set: true, want: true},
		{value: "yes", set: true, want: true},
		{value: "on", set: true, want: true},
		{value: "false", set: true, want: false},
		{value: "0", set: true, want: false},
		{value: "banana", set: true, want: false},
	}

	for _, tt := range tests {
		name := tt.value
		if !tt.set {
			name = "<unset>"
		}
		t.Run(name, func(t *testing.T) {
			if tt.set {
				t.Setenv("API_SWAGGER", tt.value)
			} else {
				os.Unsetenv("API_SWAGGER")
			}
			if got := swaggerEnabled(); got != tt.want {
				t.Errorf("swaggerEnabled() = %v, want %v", got, tt.want)
			}
		})
	}
}
```

Ensure `api/main_test.go` imports `os` and `testing`.

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd api && go test -run TestSwaggerEnabled_OptIn -v ./... 2>&1 | tail -12
```

Expected: FAIL on the `<unset>` and empty-string cases — `swaggerEnabled() = true, want false`.

- [ ] **Step 3: Flip the default**

In `api/main.go`, replace the whole `swaggerEnabled` function (including its doc comment) with:

```go
// swaggerEnabled reports whether the Swagger UI should be mounted. The UI sits
// outside the authenticated route group, so it is opt-in: only "1", "true",
// "yes", or "on" (case-insensitive) enable it. Unset or anything else keeps it
// off, which is the safe default for a sidecar reachable through a public
// reverse proxy.
func swaggerEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("API_SWAGGER"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
```

- [ ] **Step 4: Fix any pre-existing test that assumed the old default**

```bash
cd api && go test -race ./... 2>&1 | tail -20
```

If a pre-existing test asserts Swagger is mounted without setting `API_SWAGGER`, add `t.Setenv("API_SWAGGER", "true")` to that test — do not revert the default. Re-run until green.

- [ ] **Step 5: Commit**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
git add api/main.go api/main_test.go
git commit -m "fix(api)!: make the Swagger UI opt-in

The /swagger route is mounted outside the authenticated group, so leaving
it on by default exposed the full API surface to unauthenticated callers.
It now requires API_SWAGGER=true.

BREAKING CHANGE: Swagger UI is no longer served unless API_SWAGGER is set
to 1/true/yes/on."
```

---

### Task 5: Finding 5 — create the API token file without a permissions window

`api/entrypoint.sh` writes `api_token` at the default umask and only then `chmod 600`, leaving a brief window where the token is world-readable.

**Files:**
- Modify: `api/entrypoint.sh` (lines 17-20)

**Interfaces:** none — shell only.

- [ ] **Step 1: Tighten the write**

In `api/entrypoint.sh`, replace:

```sh
        API_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        mkdir -p "$CONFIG_DIR/server"
        printf '%s' "$API_TOKEN" > "$CONFIG_DIR/server/api_token"
        chmod 600 "$CONFIG_DIR/server/api_token"
```

with:

```sh
        API_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        mkdir -p "$CONFIG_DIR/server"
        # Create with the restrictive mode already in place — chmod after the
        # write leaves the token world-readable in between.
        (umask 077; printf '%s' "$API_TOKEN" > "$CONFIG_DIR/server/api_token")
```

- [ ] **Step 2: Verify the resulting mode**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
rm -rf /tmp/tokentest && mkdir -p /tmp/tokentest
CONFIG_DIR=/tmp/tokentest sh -c '
  API_TOKEN=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d " \n")
  mkdir -p "$CONFIG_DIR/server"
  (umask 077; printf "%s" "$API_TOKEN" > "$CONFIG_DIR/server/api_token")
'
ls -l /tmp/tokentest/server/api_token
rm -rf /tmp/tokentest
```

Expected: `-rw-------` (mode 600).

- [ ] **Step 3: Check the script still parses**

```bash
sh -n api/entrypoint.sh && echo "entrypoint.sh OK"
```

Expected: `entrypoint.sh OK`.

- [ ] **Step 4: Commit**

```bash
git add api/entrypoint.sh
git commit -m "fix(api): create api_token with a restrictive umask

The token file was written at the default umask and chmod'd afterwards,
leaving a window where it was world-readable."
```

---

### Task 6: Two-target Dockerfile on master's image bases

Adds the `api-builder` and `awg-api` stages and labels the existing runtime stage, moving PR #10's stages onto Alpine 3.24 / Go 1.25.12.

**Files:**
- Modify: `Dockerfile` (line 43 area, and append two stages)

**Interfaces:**
- Produces: build targets `runtime` (default) and `awg-api`.

- [ ] **Step 1: Label the runtime stage**

In `Dockerfile`, replace line 43:

```dockerfile
FROM ghcr.io/linuxserver/baseimage-alpine:3.24
```

with:

```dockerfile
FROM ghcr.io/linuxserver/baseimage-alpine:3.24 AS runtime
```

Then update the stage-3 banner comment two lines above it from `# Stage 3: Runtime image using LinuxServer base` to `# Stage 3: Runtime image using LinuxServer base (default target)`.

- [ ] **Step 2: Update the header comment**

Replace line 4:

```dockerfile
# Multi-stage build: compile amneziawg-go, awg-tools, then create runtime image
```

with:

```dockerfile
# Multi-stage build with two final targets:
#   - runtime  (default): VPN container with s6-overlay
#   - awg-api:            lightweight REST API sidecar
```

- [ ] **Step 3: Append the API builder and sidecar stages**

Append to the end of `Dockerfile`:

```dockerfile

# ============================================================================
# Stage 4: Compile the REST API server
# ============================================================================
FROM golang:1.25.12-alpine AS api-builder

RUN go install github.com/swaggo/swag/cmd/swag@latest
WORKDIR /src/api
COPY api/go.mod api/go.sum ./
RUN go mod download
COPY api/ .
RUN swag init --parseDependency --output docs
RUN CGO_ENABLED=0 go build -ldflags '-s -w' -trimpath -o /awg-api .

# ============================================================================
# Stage 5: API sidecar image (build with --target awg-api)
# ============================================================================
FROM alpine:3.24 AS awg-api

RUN apk add --no-cache ca-certificates netcat-openbsd bash

# awg + awg-quick for tunnel stats
COPY --from=tools-builder /tools-install/usr/bin/awg /usr/bin/awg
COPY --from=tools-builder /tools-install/usr/bin/awg-quick /usr/bin/awg-quick
RUN chmod +x /usr/bin/awg /usr/bin/awg-quick

COPY --from=api-builder /awg-api /usr/bin/awg-api

# Entrypoint handles token generation and env defaults
COPY api/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8081/tcp
ENTRYPOINT ["/entrypoint.sh"]
```

- [ ] **Step 4: Confirm `.dockerignore` does not exclude the API sources**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
cat .dockerignore
```

If any line would exclude `api/` or `api/go.sum`, remove it. Test files are excluded by PR #10's `.dockerignore` on purpose — that is fine, since `go build` does not need them. If `api/` itself is excluded, the build will fail in Step 5.

- [ ] **Step 5: Build the VPN target and check it stayed slim**

```bash
docker build --build-arg BUILD_DATE=local --build-arg VERSION=local --target runtime -t awgtest:runtime . 2>&1 | tail -3
docker run --rm --entrypoint sh awgtest:runtime -c '
  command -v awg awg-quick amneziawg-go >/dev/null && echo "vpn binaries OK"
  ! test -f /usr/bin/awg-api && echo "awg-api correctly absent"
  ! test -d /etc/s6-overlay/s6-rc.d/svc-awg-api && echo "svc-awg-api correctly absent"'
```

Expected: all three lines print.

- [ ] **Step 6: Build the API target and check its contents**

```bash
docker build --build-arg BUILD_DATE=local --build-arg VERSION=local --target awg-api -t awgtest:api . 2>&1 | tail -3
docker run --rm --entrypoint sh awgtest:api -c '
  test -x /usr/bin/awg-api && echo "awg-api executable"
  command -v awg awg-quick >/dev/null && echo "awg tools present"
  ! test -d /etc/s6-overlay && echo "no s6 overlay (correct)"
  cat /etc/alpine-release'
```

Expected: the three confirmations plus an Alpine `3.24.x` release string.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile .dockerignore
git commit -m "feat: two-target Dockerfile for VPN runtime and API sidecar

Adds api-builder and awg-api stages and labels the runtime stage, so one
Dockerfile produces both images. The new stages use master's image bases
(golang 1.25.12, alpine 3.24) rather than the 3.21/1.24.4 pins the API
branch was written against. The VPN image is unchanged and still contains
no API binary."
```

---

### Task 7: CI — test the API and build both targets

**Files:**
- Create: `.github/workflows/api-tests.yml`
- Modify: `.github/workflows/docker-build.yml`

**Interfaces:**
- Consumes: build targets from Task 6.

- [ ] **Step 1: Import the API test workflow**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
git checkout origin/feat/api -- .github/workflows/api-tests.yml
cat .github/workflows/api-tests.yml
```

This file does not exist on master, so it imports without conflict.

- [ ] **Step 2: Align the Go version in that workflow**

If `api-tests.yml` pins `go-version` to `1.24.x` or similar, change it to:

```yaml
          go-version: '1.25'
```

so CI matches the `api-builder` stage. Leave the rest of the workflow alone.

- [ ] **Step 3: Read master's build job before editing it**

```bash
sed -n '30,120p' .github/workflows/docker-build.yml
```

Note how the version-resolution step reads the pins out of the Dockerfile — that logic must be preserved exactly. Note also the existing `docker/build-push-action` step and the smoke-test step names.

- [ ] **Step 4: Add `target: runtime` to the existing build step**

In the existing `docker/build-push-action` invocation in the `build` job, add `target: runtime` to its `with:` block, alongside the existing `context`/`platforms`/`tags` keys. This makes the default image explicit and keeps it identical to today's output.

- [ ] **Step 5: Add the API image build**

After the existing build step in the `build` job, add a sibling step:

```yaml
      - name: Build and push API sidecar image
        uses: docker/build-push-action@v6
        with:
          context: .
          target: awg-api
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ghcr.io/ayastrebov/awg-api:latest
          cache-from: type=gha,scope=awg-api
          cache-to: type=gha,mode=max,scope=awg-api
          build-args: |
            BUILD_DATE=${{ github.event.repository.updated_at }}
            VERSION=${{ steps.versions.outputs.tools_version }}
            AMNEZIAWG_TOOLS_VERSION=${{ steps.versions.outputs.amneziawg_tools }}
            BUILDKIT_INLINE_CACHE=1
          provenance: false
          sbom: false
```

These inputs mirror master's existing VPN build step exactly, except for
`target`, the separate cache scope (so the two targets do not evict each
other), the fixed tag, and the omission of `AMNEZIAWG_GO_VERSION` — the
sidecar never builds `amneziawg-go`. The `steps.versions` and
`steps.meta` step IDs already exist in this job.

- [ ] **Step 6: Extend the PR smoke test**

In the PR smoke-test job, after the existing single-platform `--load` build, add:

```yaml
          docker build --target awg-api --load -t awg-api-smoke .
          docker run --rm --entrypoint sh awg-api-smoke -c '
            test -x /usr/bin/awg-api && echo "awg-api: executable"
            ! test -d /etc/s6-overlay && echo "no s6 in sidecar: correct"'
          docker run --rm --entrypoint sh test-image -c '
            ! test -f /usr/bin/awg-api && echo "awg-api correctly absent from VPN image"
            ! test -d /etc/s6-overlay/s6-rc.d/svc-awg-api && echo "svc-awg-api correctly absent"'
```

The VPN image built by that job is tagged `test-image` (built at
`docker-build.yml:131` with `docker buildx build --platform linux/amd64
--load -t test-image`), which is what the second `docker run` above
inspects.

- [ ] **Step 7: Validate the workflow YAML**

```bash
python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['.github/workflows/docker-build.yml','.github/workflows/api-tests.yml']]; print('workflow YAML OK')"
```

Expected: `workflow YAML OK`.

- [ ] **Step 8: Confirm the version-resolution logic survived**

```bash
grep -n "ARG AMNEZIAWG_TOOLS_VERSION=" .github/workflows/docker-build.yml
```

Expected: still present in both the build and release jobs — the Dockerfile remains the single source of truth.

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/
git commit -m "ci: test the API and build both image targets

Adds the Go test workflow and builds the awg-api target alongside the VPN
image, with PR smoke tests asserting the sidecar has the API binary and no
s6, and that the VPN image has neither. Master's Dockerfile-as-source-of-
truth version resolution and release job are unchanged."
```

---

### Task 8: Finding 4 — share `build_version` with the sidecar in client mode too

**Files:**
- Modify: `root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run` (near the end, before the `# permissions` block)

**Interfaces:**
- Produces: `/config/server/build_version`, read by the sidecar via `BUILD_VERSION_PATH`.

- [ ] **Step 1: Add the copy with its own mkdir**

In `root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run`, insert immediately before the `# permissions` comment near the end of the file:

```bash
# share build version with sidecar containers via /config volume.
# mkdir is required because /config/server is otherwise only created in server
# mode (by generate_awg_params) — in client mode the copy would silently fail.
mkdir -p /config/server
cp /build_version /config/server/build_version 2>/dev/null || true

```

- [ ] **Step 2: Lint and syntax-check**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
shellcheck -S warning root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run && echo "SHELLCHECK CLEAN"
bash -n root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run && echo "SYNTAX OK"
```

Expected: both lines print.

- [ ] **Step 3: Verify in client mode (the mode that was broken)**

```bash
docker build --build-arg BUILD_DATE=local --build-arg VERSION=local --target runtime -t awgtest:runtime . 2>&1 | tail -1
SC=$(mktemp -d)/clientcfg && mkdir -p "$SC/wg_confs"
printf '[Interface]\nPrivateKey = %s\nAddress = 10.99.0.2/32\n' \
  "$(docker run --rm --entrypoint awg awgtest:runtime genkey)" > "$SC/wg_confs/wg0.conf"
docker rm -f bvtest >/dev/null 2>&1
docker run -d --name bvtest --cap-add NET_ADMIN --device /dev/net/tun \
  -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC -v "$SC:/config" awgtest:runtime >/dev/null
sleep 15
docker exec bvtest cat /config/server/build_version
docker rm -f bvtest >/dev/null && rm -rf "$SC"
```

Expected: the `build_version` contents print (`AmneziaWG version: local` etc.). Before this fix the file would not exist. The tunnel itself will not come up (the peer is fake) — that is irrelevant to this check.

- [ ] **Step 4: Verify server mode still works**

```bash
SC2=$(mktemp -d)/srvcfg && mkdir -p "$SC2"
docker rm -f bvsrv >/dev/null 2>&1
docker run -d --name bvsrv --cap-add NET_ADMIN --device /dev/net/tun \
  -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC -e SERVERURL=127.0.0.1 -e PEERS=1 \
  -e LOG_CONFS=false -v "$SC2:/config" \
  --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  awgtest:runtime >/dev/null
sleep 18
docker exec bvsrv cat /config/server/build_version
docker logs bvsrv 2>&1 | grep -c "All tunnels are now active"
docker rm -f bvsrv >/dev/null && rm -rf "$SC2"
```

Expected: version contents print, and the tunnel count is `1`.

- [ ] **Step 5: Commit**

```bash
git add root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run
git commit -m "feat: share build_version with sidecar containers

Copies /build_version into /config/server so a sidecar on the shared
volume can report the container version. Creates /config/server first —
it is otherwise only created in server mode, so in client mode the copy
failed silently and the sidecar reported no version."
```

---

### Task 9: Documentation and compose

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `docker-compose.yml`, `CHANGELOG.md`
- Create: `API.md`, `DECOUPLING.md` (imported from the old branch)

- [ ] **Step 1: Import the standalone API docs**

Both files exist at the old branch's root (verified with
`git ls-tree --name-only origin/feat/api`):

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
git checkout origin/feat/api -- API.md DECOUPLING.md
ls -l API.md DECOUPLING.md
```

Expected: both files present. They are new on `master`, so they import
without conflict.

- [ ] **Step 2: Correct the two changed behaviours in the imported docs**

Search the imported docs for the Swagger default and the WS token, and update both — they describe PR #10's behaviour, which Tasks 3 and 4 changed:

```bash
grep -rn "API_SWAGGER\|ws/stats?token\|ws/logs?token" API.md DECOUPLING.md README.md 2>/dev/null
```

For each hit: state that Swagger requires `API_SWAGGER=true`, and show the WebSocket connect using the subprotocol form, for example:

```javascript
new WebSocket("wss://host/api/v1/ws/stats", ["bearer", token]);
```

noting that `?token=` still works but is deprecated.

- [ ] **Step 3: Merge the README and CLAUDE.md sections**

```bash
git checkout origin/feat/api -- README.md CLAUDE.md docker-compose.yml
git diff --stat HEAD -- README.md CLAUDE.md docker-compose.yml
```

These three files auto-merged in the conflict probe, but the old-branch copies predate the AWG 3.0 docs. **Do not accept them wholesale.** Instead inspect the diff and re-apply only the API-related additions on top of master's current content:

```bash
git diff HEAD -- README.md | head -80
```

If master's AWG 3.0 sections (the `3.0` protocol-version row, the AWG 3.0 parameter table, the compose 3.0 block) are missing from the result, restore them with `git checkout HEAD -- <file>` and hand-add the API sections instead.

- [ ] **Step 4: Verify no AWG 3.0 documentation was lost**

```bash
grep -c "AWG_HEADER_PROTECTION_KEY\|header protection" README.md
grep -c "3.0" docker-compose.yml
grep -c "append_awg3_params" CLAUDE.md
```

Expected: all three greater than 0. If any is 0, the old branch's copy overwrote master's AWG 3.0 docs — restore and redo Step 3.

- [ ] **Step 5: Add CHANGELOG entries**

Under `## [Unreleased]` in `CHANGELOG.md`, add to `### Added`:

```markdown
- Optional REST API sidecar (`ghcr.io/ayastrebov/awg-api`) for monitoring: server info, tunnel stats, peer configs and QR codes, system metrics, structured logs, and WebSocket feeds
```

and to `### Fixed`:

```markdown
- API no longer exposes `AWG_HEADER_PROTECTION_KEY` — AWG parameters are now allowlisted
- WebSocket token is accepted via `Sec-WebSocket-Protocol`/`Authorization` instead of the query string, which gin wrote to the access log
- `build_version` is now shared with sidecars in client mode as well as server mode
```

and add a `### Changed` entry:

```markdown
- **Breaking:** the Swagger UI is now opt-in via `API_SWAGGER=true` (it is served outside the authenticated route group)
```

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md docker-compose.yml CHANGELOG.md API.md DECOUPLING.md
git commit -m "docs: API sidecar usage, compose example, and changelog

Documents the sidecar, its compose wiring, and the two behaviour changes
from the audit: opt-in Swagger and header-based WebSocket auth."
```

---

### Task 10: Full verification and PR

**Files:** none (verification and GitHub only).

- [ ] **Step 1: Full local test and lint pass**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg/api
go vet ./... && go test -race ./... 2>&1 | tail -8
command -v golangci-lint >/dev/null && golangci-lint run ./... || echo "golangci-lint not installed locally — CI will run it"
```

Expected: vet clean, all tests PASS.

- [ ] **Step 2: Build both targets from the final tree**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
docker build --build-arg BUILD_DATE=local --build-arg VERSION=local --target runtime -t awgfinal:runtime . 2>&1 | tail -1
docker build --build-arg BUILD_DATE=local --build-arg VERSION=local --target awg-api -t awgfinal:api . 2>&1 | tail -1
```

Expected: both succeed.

- [ ] **Step 3: End-to-end check that the secret is not exposed**

```bash
SC=$(mktemp -d)/awgapi && mkdir -p "$SC"
docker rm -f apivpn apisidecar >/dev/null 2>&1
docker run -d --name apivpn --cap-add NET_ADMIN --device /dev/net/tun \
  -e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC -e SERVERURL=127.0.0.1 -e PEERS=2 \
  -e AWG_VERSION=3.0 -e LOG_CONFS=false -v "$SC:/config" \
  --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  awgfinal:runtime >/dev/null
sleep 20
docker run -d --name apisidecar --network "container:apivpn" \
  -e WAIT_FOR_CONFIG=true -v "$SC:/config" awgfinal:api >/dev/null
sleep 10
TOKEN=$(cat "$SC/server/api_token")
docker exec apisidecar wget -qO- --header="Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8081/api/v1/server > /tmp/serverinfo.json
echo "--- 3.0 params present? ---"
grep -oE '"(version|content_padding|rekey_after_time)":"[^"]*"' /tmp/serverinfo.json
echo "--- secret leaked? (expect NO MATCH) ---"
grep -c "header_protection_key" /tmp/serverinfo.json || echo "0 — secret not exposed"
echo "--- swagger off by default? (expect 404) ---"
docker exec apisidecar wget -qO- -S http://127.0.0.1:8081/swagger/index.html 2>&1 | grep -E "HTTP/" | head -1
echo "--- token in sidecar logs? (expect 0) ---"
docker logs apisidecar 2>&1 | grep -c "token=" || echo "0"
```

Expected: 3.0 params present; `header_protection_key` count 0; Swagger returns 404; no `token=` in logs.

Note: `--network container:apivpn` is the CLI equivalent of compose's `network_mode: service:`, and is the closest this host can get to the real topology.

- [ ] **Step 4: Confirm the VPN container is unregressed**

```bash
docker logs apivpn 2>&1 | grep -E "AmneziaWG version: 3.0|All tunnels are now active"
docker exec apivpn awg show | grep -c "header protection key"
```

Expected: both log lines present; the device still reports its header protection key (the container must keep using it — only the API must not publish it).

- [ ] **Step 5: Clean up**

```bash
docker rm -f apivpn apisidecar >/dev/null 2>&1
docker rmi awgfinal:runtime awgfinal:api awgtest:runtime awgtest:api >/dev/null 2>&1
rm -rf "$SC" /tmp/serverinfo.json
docker ps -a --format '{{.Names}}' | grep -E "api(vpn|sidecar)|awgtest" || echo "clean"
```

- [ ] **Step 6: Push and open the PR**

```bash
cd /Users/Andrey.Yastrebov/VibeCode/docker-amneziawg
git push -u origin feat/api-v2
```

Then open a PR against `master` titled `feat: REST API sidecar (rebased onto AWG 3.0)`. The body must include:

- A summary reusing PR #10's endpoint table (retrieve with `gh pr view 10 --json body`).
- A **Rebase and audit** section listing the five findings and their fixes, headlining that `GET /api/v1/server` exposed `AWG_HEADER_PROTECTION_KEY` after the AWG 3.0 merge.
- A **Breaking changes** section for the Swagger default.
- A test plan with the Linux-only items left **unchecked** and labelled:

```markdown
- [ ] Full compose stack on a Linux host with `/dev/net/tun` (cannot be validated on macOS — Docker Desktop's VM does not reproduce `network_mode: service:` netns semantics faithfully)
- [ ] Multi-arch build (amd64 + arm64) — exercised by CI on merge
```

- A closing line: `Supersedes #10.`

- [ ] **Step 7: Report to the user**

Report the new PR URL, confirm PR #10 is still open and untouched, and ask whether to close #10 with a pointer to the replacement.

---

## Deferred, not done here

Tracked separately rather than expanded into this PR:

- `root/etc/s6-overlay/s6-rc.d/svc-coredns/run` is mode 644 while every other `run` is 755 (harmless — s6-rc still starts it).
- CoreDNS did not answer queries during macOS testing on the AWG 3.0 branch; unverified on Linux and unrelated to this work.
- The API's architecture, auth model, and endpoint surface stay as PR #10 designed them.
