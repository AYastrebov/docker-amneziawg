# AmneziaWG REST API

REST API for reading peer configs, tunnel stats, and server info. Useful if you're building a web UI or a Telegram bot on top of the container.

## Quick Start

1. Enable the API in your `docker-compose.yml`:

```yaml
environment:
  - USE_API=true
ports:
  - 8081:8081/tcp
```

2. Start the container. The API token is auto-generated and printed in logs:

```
**** API token generated: a1b2c3d4e5f6... ****
**** Save this token — it will not be shown again ****
```

The token is also saved to `/config/server/api_token`.

3. Test the API:

```bash
# Health check (no auth)
curl http://localhost:8081/health

# List peers (with auth)
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:8081/api/v1/peers
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `USE_API` | `false` | Enable the REST API |
| `API_PORT` | `8081` | TCP listen port |
| `API_TOKEN` | *(auto-generated)* | Bearer token for authentication |
| `API_READONLY` | `true` | Read-only mode (future use) |
| `API_SWAGGER` | `true` | Mount the unauthenticated Swagger UI at `/swagger/*`. Set to `false` in production to avoid exposing the API surface to anyone who can reach the port. |

## Authentication

All endpoints except `/health` require a Bearer token in the `Authorization` header:

```
Authorization: Bearer YOUR_TOKEN
```

WebSocket connections authenticate via query parameter:

```
ws://localhost:8081/api/v1/ws/stats?token=YOUR_TOKEN
```

## Swagger UI

When the API is enabled (and `API_SWAGGER` is left at its default `true`), Swagger UI is at:

```
http://localhost:8081/swagger/index.html
```

OpenAPI JSON spec:

```
http://localhost:8081/swagger/doc.json
```

Both endpoints are **unauthenticated** by design (Swagger UI loads the spec from the browser). For internet-exposed deployments, set `API_SWAGGER=false` so that the spec — which lists every endpoint and its parameters — doesn't leak to attackers, or keep Swagger reachable only via your reverse proxy on an internal hostname.

## Endpoints

### Infrastructure

#### `GET /health`

Health check. No authentication required.

```bash
curl http://localhost:8081/health
```

```json
{"status": "ok"}
```

### Server

#### `GET /api/v1/server`

Server information including mode, tunnels, version, network config, and AWG parameters.

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/server
```

```json
{
  "data": {
    "mode": "server",
    "tunnels": ["wg0"],
    "uptime": "3600.50s",
    "version": {
      "amneziawg_tools": "v1.0.20260223",
      "amneziawg_go": "v0.2.18"
    },
    "server_url": "vpn.example.com",
    "server_port": "51820",
    "internal_subnet": "10.13.13.0",
    "public_key": "BASE64_PUBLIC_KEY",
    "awg_params": {
      "version": "2.0",
      "jc": "5",
      "jmin": "50",
      "jmax": "200",
      "s1": "86",
      "s2": "12",
      "h1": "90666522-140666522",
      "h2": "536870912-586870912",
      "h3": "1073741824-1123741824",
      "h4": "1610612736-1660612736"
    }
  }
}
```

#### `GET /api/v1/system`

Host runtime metrics for the panel's health badge. Lightweight — designed to be polled every 5–10 seconds.

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/system
```

```json
{
  "data": {
    "cpu": { "load_1m": 0.42, "load_5m": 0.38, "load_15m": 0.30, "cores": 4 },
    "memory": { "total_bytes": 2147483648, "used_bytes": 512000000, "used_percent": 23.8 },
    "disk": { "path": "/config", "total_bytes": 21474836480, "used_bytes": 1073741824, "used_percent": 5.0 },
    "uptime_seconds": 3601.5
  }
}
```

Missing `/proc` files yield zero values instead of a 500 — the panel prefers "unknown" to a broken badge.

#### `GET /api/v1/version`

Just the upstream component versions and build date. Cheaper than `/api/v1/server` for "is there a new image?" probes.

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/version
```

```json
{
  "data": {
    "amneziawg_tools": "v1.0.20260223",
    "amneziawg_go": "v0.2.18"
  }
}
```

#### `GET /api/v1/services`

s6-overlay service runtime status. Useful for debugging ("why is DNS down?").

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/services
```

```json
{
  "data": [
    { "name": "svc-amneziawg", "status": "up",      "uptime_seconds": 3601 },
    { "name": "svc-coredns",   "status": "up",      "uptime_seconds": 3600 },
    { "name": "svc-awg-api",   "status": "up",      "uptime_seconds": 3600 }
  ]
}
```

`status` is `up`, `down`, or `unknown` (the latter when s6 runtime state isn't reachable — e.g. running outside the container).

### Tunnels

#### `GET /api/v1/tunnels`

Live tunnel statistics from `awg show all dump`.

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/tunnels
```

```json
{
  "data": [
    {
      "name": "wg0",
      "interface": {
        "public_key": "BASE64_KEY",
        "listen_port": 51820
      },
      "peers": [
        {
          "public_key": "BASE64_KEY",
          "endpoint": "1.2.3.4:51820",
          "allowed_ips": "10.13.13.2/32",
          "latest_handshake": "2026-05-18T10:30:00Z",
          "transfer_rx": 123456,
          "transfer_tx": 789012
        }
      ]
    }
  ]
}
```

#### `GET /api/v1/tunnels/:name`

Live stats for a single tunnel by name. Returns 404 if the tunnel isn't active.

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/tunnels/wg0
```

Same shape as one entry in `GET /api/v1/tunnels`.

### Peers

#### `GET /api/v1/peers`

List all configured peers.

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/peers
```

```json
{
  "data": [
    {
      "id": "peer1",
      "name": "1",
      "public_key": "BASE64_KEY",
      "address": "10.13.13.2",
      "has_config": true,
      "has_qr": true
    }
  ]
}
```

#### `GET /api/v1/peers/:id`

Get detailed info for a single peer. The `:id` can be:
- Full ID: `peer1`, `peer_laptop`
- Numeric shorthand: `1` (resolves to `peer1`)
- Name shorthand: `laptop` (resolves to `peer_laptop`)

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/peers/1
```

```json
{
  "data": {
    "id": "peer1",
    "name": "1",
    "public_key": "BASE64_KEY",
    "address": "10.13.13.2",
    "has_config": true,
    "has_qr": true,
    "config": "[Interface]\nAddress = 10.13.13.2\n...",
    "stats": {
      "public_key": "BASE64_KEY",
      "endpoint": "1.2.3.4:51820",
      "latest_handshake": "2026-05-18T10:30:00Z",
      "transfer_rx": 123456,
      "transfer_tx": 789012
    }
  }
}
```

#### `GET /api/v1/peers/:id/config`

Download the raw `.conf` file for a peer.

```bash
curl -H "Authorization: Bearer $TOKEN" -O http://localhost:8081/api/v1/peers/1/config
```

Returns `text/plain` with `Content-Disposition: attachment; filename="peer1.conf"` by default.

Pass `?inline=1` to omit the `Content-Disposition` header so the browser (or panel) renders the file inline instead of downloading it:

```bash
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/peers/1/config?inline=1
```

#### `GET /api/v1/peers/:id/qr`

Download the QR code PNG for a peer's config.

```bash
curl -H "Authorization: Bearer $TOKEN" -o peer1.png http://localhost:8081/api/v1/peers/1/qr
```

Returns `image/png`.

#### `HEAD /api/v1/peers/:id/qr`

Cheap existence probe. Returns 200 with `Content-Type: image/png` and no body when the QR exists, 404 otherwise.

```bash
curl -I -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/peers/1/qr
```

### Logs

The container polls `awg show` every 5 seconds and emits a structured log entry whenever a peer appears, goes away, or completes a handshake. Entries are kept in an in-memory ring buffer (5000 lines) and exposed through a REST tail and a WebSocket stream. Sensitive fields (`PrivateKey`, `PreSharedKey`, bearer tokens) are scrubbed before lines enter the buffer.

#### `GET /api/v1/logs`

Paginated tail. Returns lines newest-first.

Query params:

| Param | Default | Description |
|---|---|---|
| `limit` | `200` | Max lines (capped at 1000) |
| `before` | — | Cursor: line `id` (ULID) or RFC3339 timestamp; returns lines older than this |
| `level` | all | Comma-separated levels (`debug`, `info`, `warn`, `error`) |
| `source` | all | Comma-separated sources (`awg`, `api`, …) |

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8081/api/v1/logs?limit=100&level=info,warn&source=awg"
```

```json
{
  "data": {
    "lines": [
      {
        "id": "01HXYZ...",
        "t": "2026-05-18T10:30:00.123Z",
        "level": "info",
        "source": "awg",
        "msg": "peer laptop handshake completed (endpoint 1.2.3.4:51820)"
      }
    ],
    "next": "01HXYW..."
  }
}
```

`next` is the cursor for the next (older) page. It's empty when fewer than `limit` lines were returned.

#### `GET /api/v1/ws/logs?token=YOUR_TOKEN`

WebSocket stream of new log lines. One JSON object per frame, same shape as REST. `level` and `source` filters work the same way and are applied server-side.

```javascript
const ws = new WebSocket(
  'ws://localhost:8081/api/v1/ws/logs?token=YOUR_TOKEN&level=warn,error'
)

ws.onmessage = (event) => {
  const line = JSON.parse(event.data)
  console.log(line.t, line.level, line.source, line.msg)
}
```

If a client falls behind the broadcast rate the server closes the socket with WebSocket close code **1013 ("Try Again Later")**. Reconnect with exponential backoff.

The expected init pattern: REST-fetch the most recent ~200 lines, then open the WebSocket. New frames received during the REST call should be buffered and merged.

### WebSocket: Live Stats

#### `GET /api/v1/ws/stats?token=YOUR_TOKEN`

WebSocket endpoint for real-time tunnel statistics. Pushes full snapshots every 2 seconds.

```javascript
const ws = new WebSocket('ws://localhost:8081/api/v1/ws/stats?token=YOUR_TOKEN');

ws.onmessage = (event) => {
  const stats = JSON.parse(event.data);
  console.log(stats.data);      // Array of TunnelInfo
  console.log(stats.timestamp); // ISO 8601 timestamp
};
```

Message format matches `GET /api/v1/tunnels` with an added `timestamp` field.

## Error Responses

Error responses look like this:

```json
{
  "error": {
    "code": "NOT_FOUND",
    "message": "Peer peer99 not found"
  }
}
```

| Code | HTTP Status | Description |
|---|---|---|
| `UNAUTHORIZED` | 401 | Missing or invalid Bearer token |
| `NOT_FOUND` | 404 | Requested peer does not exist |
| `INTERNAL_ERROR` | 500 | Server error (e.g., `awg show` failed) |

For the logs WebSocket specifically, server-initiated closures use:

| WS close code | Meaning |
|---|---|
| `1013` | "Try Again Later" — client fell behind broadcast rate; reconnect with backoff |

## Security

- The server's `privatekey-server` file is never served. Peer `.conf` files (which contain the peer's `PrivateKey`) are available via `/peers/:id/config`, so treat the API token like a secret.
- Put a reverse proxy with TLS in front if you expose this to the internet.
- The API binds to `0.0.0.0`. Control access via Docker port mapping.
- Token is stored at `/config/server/api_token` with mode `600`.

## Deployment notes

### Reverse proxy and CORS

The API does not set CORS headers itself. If you serve a browser SPA (e.g. the web panel) on a different origin than the API, put a reverse proxy in front and have it add the `Access-Control-Allow-*` headers for your panel origin.

Minimal nginx example:

```nginx
server {
  listen 443 ssl http2;
  server_name vpn-api.example.com;

  # TLS bits omitted

  location / {
    proxy_pass http://127.0.0.1:8081;
    proxy_http_version 1.1;
    proxy_set_header Host $host;

    # WebSocket upgrade for /api/v1/ws/*
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_upgrade;
    proxy_read_timeout 1d;

    # CORS for the panel origin
    add_header Access-Control-Allow-Origin  "https://panel.example.com" always;
    add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;

    if ($request_method = OPTIONS) {
      return 204;
    }
  }
}
```

Same idea works with Caddy, Traefik, or any other proxy that can add response headers.
