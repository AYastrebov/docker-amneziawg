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

When the API is enabled, Swagger UI is at:

```
http://localhost:8081/swagger/index.html
```

OpenAPI JSON spec:

```
http://localhost:8081/swagger/doc.json
```

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

Returns `text/plain` with `Content-Disposition: attachment; filename="peer1.conf"`.

#### `GET /api/v1/peers/:id/qr`

Download the QR code PNG for a peer's config.

```bash
curl -H "Authorization: Bearer $TOKEN" -o peer1.png http://localhost:8081/api/v1/peers/1/qr
```

Returns `image/png`.

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

## Security

- The server's `privatekey-server` file is never served. Peer `.conf` files (which contain the peer's `PrivateKey`) are available via `/peers/:id/config`, so treat the API token like a secret.
- Put a reverse proxy with TLS in front if you expose this to the internet.
- The API binds to `0.0.0.0`. Control access via Docker port mapping.
- Token is stored at `/config/server/api_token` with mode `600`.
