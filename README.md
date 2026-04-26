# Docker AmneziaWG

[![Docker Build](https://github.com/AYastrebov/docker-amneziawg/actions/workflows/docker-build.yml/badge.svg)](https://github.com/AYastrebov/docker-amneziawg/actions/workflows/docker-build.yml)
[![GitHub Container Registry](https://img.shields.io/badge/ghcr.io-docker--amneziawg-blue?logo=docker)](https://github.com/AYastrebov/docker-amneziawg/pkgs/container/docker-amneziawg)
[![GitHub release](https://img.shields.io/github/v/release/AYastrebov/docker-amneziawg)](https://github.com/AYastrebov/docker-amneziawg/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Docker container for running AmneziaWG VPN with automatic configuration generation, peer management, and QR code support. Built on LinuxServer.io base images with s6-overlay process supervision.

## Features

- **AWG 2.0 by Default**: Full AmneziaWG 2.0 support with Custom Protocol Signatures (I1-I5), S3/S4 padding, and auto-generated TLS-like DPI evasion out of the box
- **AWG 1.5 Fallback**: Set `AWG_VERSION=1.5` for legacy client compatibility (AmneziaVPN < 4.8.12.9)
- **Automatic Configuration**: Generate server and peer configs from environment variables
- **QR Code Support**: Display peer configs as QR codes for easy mobile setup
- **CoreDNS Integration**: Built-in DNS server for peers (auto-enabled in server mode)
- **Multi-Peer Management**: Support for numbered or named peers (e.g., `laptop,phone,tablet`)
- **Per-Peer Options**: `PERSISTENTKEEPALIVE_PEERS` and `SERVER_ALLOWEDIPS_PEER_X` for site-to-site VPN
- **s6-overlay Supervision**: Reliable process management with graceful shutdown
- **Dual Mode**: Server mode (auto-generate) or Client mode (manual configs)
- **[Advanced Hub Mode](ADVANCED_AWG_HUB.md)**: Run server + client in one container with upstream VPN routing and failover
- **Multi-Architecture**: Supports `linux/amd64` and `linux/arm64`

## Quick Start

### Server Mode (Recommended)

Create a VPN server with automatic peer configuration:

```bash
docker run -d \
  --name amneziawg \
  --cap-add NET_ADMIN \
  --cap-add SYS_MODULE \
  --device /dev/net/tun:/dev/net/tun \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  -e SERVERURL=vpn.example.com \
  -e PEERS=3 \
  -p 51820:51820/udp \
  -v ./config:/config \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --restart unless-stopped \
  ghcr.io/ayastrebov/docker-amneziawg:latest
```

View QR codes for peers:

```bash
docker exec amneziawg /app/show-peer 1 2 3
```

### Client Mode

Use pre-existing configuration files:

```bash
# Place your config in ./config/wg_confs/wg0.conf
docker run -d \
  --name amneziawg \
  --cap-add NET_ADMIN \
  --cap-add SYS_MODULE \
  --device /dev/net/tun:/dev/net/tun \
  -v ./config:/config \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --restart unless-stopped \
  ghcr.io/ayastrebov/docker-amneziawg:latest
```

### Docker Compose

```yaml
services:
  amneziawg:
    image: ghcr.io/ayastrebov/docker-amneziawg:latest
    container_name: amneziawg
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - SERVERURL=vpn.example.com
      - SERVERPORT=51820
      - PEERS=laptop,phone,tablet
      - PEERDNS=auto
      - INTERNAL_SUBNET=10.13.13.0
      - ALLOWEDIPS=0.0.0.0/0, ::/0
      - PERSISTENTKEEPALIVE_PEERS=all
      - LOG_CONFS=true
      # - AWG_VERSION=2.0      # "2.0" (default) or "1.5" for legacy clients
    volumes:
      - ./config:/config
    ports:
      - 51820:51820/udp
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

## Environment Variables

### Server Mode (when `PEERS` is set)

| Variable | Default | Description |
|----------|---------|-------------|
| `PEERS` | - | Number or comma-separated names (enables server mode) |
| `SERVERURL` | `auto` | External server URL/IP (`auto` to detect) |
| `SERVERPORT` | `51820` | Listen port |
| `INTERNAL_SUBNET` | `10.13.13.0` | VPN subnet (peers get .2, .3, etc.) |
| `PEERDNS` | `auto` | DNS for peers (`auto` = container DNS at SUBNET.1) |
| `ALLOWEDIPS` | `0.0.0.0/0, ::/0` | Peer allowed IPs |
| `PERSISTENTKEEPALIVE_PEERS` | - | Which peers get keepalive: `all` or comma-separated names/numbers |
| `SERVER_ALLOWEDIPS_PEER_X` | - | Per-peer server AllowedIPs for site-to-site (e.g., `SERVER_ALLOWEDIPS_PEER_laptop=192.168.1.0/24`) |
| `LOG_CONFS` | `true` | Show QR codes in container logs |
| `USE_COREDNS` | `true` (server) | Enable CoreDNS for peer DNS resolution; `false` in client mode |

### AmneziaWG Protocol Version

| Variable | Default | Description |
|----------|---------|-------------|
| `AWG_VERSION` | `2.0` | Protocol version: `2.0` (full DPI evasion with I1-I5 signatures) or `1.5` (legacy, compatible with AmneziaVPN < 4.8.12.9) |

### AmneziaWG Obfuscation

AmneziaWG extends WireGuard with obfuscation features to bypass Deep Packet Inspection (DPI). All parameters are optional - if not set, random values are generated automatically. **Important**: Server and all clients must use identical obfuscation values.

#### Junk Packets

Junk packets are random data sent before each handshake to confuse traffic analysis.

| Variable | Default | Constraints | Description |
|----------|---------|-------------|-------------|
| `AWG_JC` | Random 3-8 | 1-128, recommended 4-12 | Number of junk packets to send before handshake initiation |
| `AWG_JMIN` | Random 40-80 | < JMAX | Minimum junk packet size in bytes |
| `AWG_JMAX` | Random 500-1000 | ≤ 1280 | Maximum junk packet size in bytes |

#### Packet Padding

Padding bytes are added to handshake and transport messages to obscure their true size.

| Variable | Default | Constraints | Description |
|----------|---------|-------------|-------------|
| `AWG_S1` | Random 15-150 | ≤ 1132, S1+56 ≠ S2 | Bytes added to handshake initiation message |
| `AWG_S2` | Random 15-150 | ≤ 1188, S1+56 ≠ S2 | Bytes added to handshake response message |
| `AWG_S3` | Random 15-150 (2.0) / 0 (1.5) | - | Bytes added to cookie reply message |
| `AWG_S4` | Random 15-150 (2.0) / 0 (1.5) | - | Bytes added to transport data messages |

#### Header Obfuscation

These values modify the 4-byte type field at the start of each packet, making traffic unrecognizable as WireGuard.

| Variable | Default | Constraints | Description |
|----------|---------|-------------|-------------|
| `AWG_H1` | Random range (AWG 2.0) / integer (1.5) | ≥ 5, must be unique | Header value for handshake initiation |
| `AWG_H2` | Random range (AWG 2.0) / integer (1.5) | ≥ 5, must be unique | Header value for handshake response |
| `AWG_H3` | Random range (AWG 2.0) / integer (1.5) | ≥ 5, must be unique | Header value for cookie reply |
| `AWG_H4` | Random range (AWG 2.0) / integer (1.5) | ≥ 5, must be unique | Header value for transport data |

**AWG 2.0:** H1-H4 are auto-generated as non-overlapping range pairs (e.g., `H1=90666522-140666522`) using a quadrant strategy. The Amnezia app uses range format to identify AWG 2.0 — single integers cause the app to report AWG 1.5 even with I1-I5 set. You can supply custom ranges via env vars (e.g., `AWG_H1=100000-50100000`).

**AWG 1.5:** Single integers are used for backward compatibility.

#### Signature Packets (AWG 2.0 Advanced)

Custom Protocol Signature (CPS) packets sent before handshakes to masquerade VPN traffic as other UDP protocols. See [AWG 2.0 Advanced Setup](#awg-20-advanced-setup) for usage details.

| Variable | Default | Description |
|----------|---------|-------------|
| `AWG_I1` | TLS Client Hello (2.0) / empty (1.5) | First signature packet definition (auto-generated in AWG 2.0) |
| `AWG_I2` | (empty) | Second signature packet (requires I1) |
| `AWG_I3` | (empty) | Third signature packet (requires I1) |
| `AWG_I4` | (empty) | Fourth signature packet (requires I1) |
| `AWG_I5` | (empty) | Fifth signature packet (requires I1) |

See [AmneziaWG Kernel Module Configuration](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module#configuration) for official parameter constraints.

#### Recommended Values

For most DPI bypass scenarios, the auto-generated random values work well. AWG 2.0 (default) auto-generates a TLS Client Hello I1 signature and random S3/S4 padding. If you need specific values (e.g., to match an existing setup):

```yaml
environment:
  - AWG_VERSION=2.0  # Default; set to 1.5 for legacy clients
  - AWG_JC=4         # 3-8 recommended
  - AWG_JMIN=50
  - AWG_JMAX=1000
  - AWG_S1=86
  - AWG_S2=12
  - AWG_S3=25        # AWG 2.0 cookie padding
  - AWG_S4=15        # AWG 2.0 transport padding
  # AWG 2.0: H1-H4 must use range format (non-overlapping quadrants)
  - AWG_H1=142503-15687642
  - AWG_H2=647372451-697372451
  - AWG_H3=1173841824-1223841824
  - AWG_H4=1687654321-1737654321
```

### AWG 2.0 Advanced Setup

For advanced DPI evasion scenarios where standard obfuscation isn't sufficient, AWG 2.0 introduces Custom Protocol Signature (CPS) packets via the I1-I5 parameters.

#### When to Use I1-I5

- Traffic is being blocked despite standard AWG obfuscation
- Network performs protocol allowlisting (only permits specific UDP protocols)
- You need to masquerade VPN traffic as another protocol (TLS, DNS, QUIC)

#### Tag Reference

| Tag | Description | Example |
|-----|-------------|---------|
| `<b 0xHEX>` | Static hex bytes | `<b 0x170303>` (TLS 1.2 record header) |
| `<r N>` | N random bytes (max 1000) | `<r 32>` for 32 random bytes |
| `<rd N>` | N random digits (0-9) | `<rd 8>` for 8 random digit bytes |
| `<rc N>` | N random characters (a-zA-Z) | `<rc 16>` for 16 random letter bytes |
| `<t>` | 32-bit Unix timestamp | Current time |

#### Example: TLS-like Signature

```yaml
environment:
  - AWG_JC=4
  - AWG_JMIN=50
  - AWG_JMAX=1000
  - AWG_S1=86
  - AWG_S2=12
  # TLS ClientHello-like signature packet
  - AWG_I1=<b 0x160301><r 2><b 0x0100><r 32><t>
```

#### Extracting Protocol Signatures

To create custom signatures that mimic real protocols:

1. Capture target protocol traffic with Wireshark
2. Export first UDP packet bytes as hex
3. Convert to tag syntax: `<b 0x[hex]>`
4. Add dynamic elements (`<t>`, `<r N>`) for variability

#### Compatibility Notes

- **I1 is required** - I2-I5 only work when I1 is set
- **AWG 2.0** (default) auto-generates I1 with a TLS Client Hello signature — override with custom value or set `AWG_VERSION=1.5` to disable
- Requires AWG 2.0 compatible clients (AmneziaVPN 4.8.12.9+)
- Server and all clients must have matching I1-I5 values
- Set `AWG_VERSION=1.5` for backward compatibility with older clients (disables I1-I5, sets S3=S4=0)

### LinuxServer Standard

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | User ID for file ownership |
| `PGID` | `1000` | Group ID for file ownership |
| `TZ` | `Etc/UTC` | Timezone |

## Configuration

### Volume Structure

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
├── coredns/              # CoreDNS configuration
│   └── Corefile          # CoreDNS config (auto-copied from defaults)
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

### Manual Configuration (Client Mode)

Place your configuration files in `./config/wg_confs/`:

```ini
# ./config/wg_confs/wg0.conf
[Interface]
PrivateKey = <your-private-key>
Address = 10.0.0.2/32
DNS = 8.8.8.8
# AmneziaWG parameters (must match server)
Jc = 4
Jmin = 50
Jmax = 1000
S1 = 86
S2 = 12
S3 = 0
S4 = 0
H1 = 1755269708
H2 = 2101520157
H3 = 1829552136
H4 = 2016351429

[Peer]
PublicKey = <server-public-key>
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

## Commands

### Show Peer QR Codes

```bash
# By number
docker exec amneziawg /app/show-peer 1 2 3

# By name
docker exec amneziawg /app/show-peer laptop phone tablet
```

### Check Status

```bash
# Interface status
docker exec amneziawg awg show

# Container logs
docker logs amneziawg

# Health check
docker inspect amneziawg --format='{{.State.Health.Status}}'
```

### Manual Interface Control

```bash
# Bring down interface
docker exec amneziawg awg-quick down /config/wg_confs/wg0.conf

# Bring up interface
docker exec amneziawg awg-quick up /config/wg_confs/wg0.conf
```

## Migration from Previous Version

If you're upgrading from the previous simple entrypoint version:

### Automatic Migration

The container automatically migrates legacy configs:
- `/config/awg0.conf` → `/config/wg_confs/wg0.conf`
- `/config/wg0.conf` → `/config/wg_confs/wg0.conf`

### Manual Migration

1. Update your volume mount:
   ```yaml
   # Old
   volumes:
     - ./awg0.conf:/etc/wireguard/awg0.conf

   # New
   volumes:
     - ./config:/config
   ```

2. Move your config file:
   ```bash
   mkdir -p ./config/wg_confs
   mv ./awg0.conf ./config/wg_confs/wg0.conf
   ```

3. Remove the `command:` line from your docker-compose.yml (no longer needed)

## Kernel Module

For optimal performance, install the AmneziaWG kernel module on your host:

```bash
git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
cd amneziawg-linux-kernel-module
sudo apt install linux-headers-$(uname -r) build-essential  # Debian/Ubuntu
make && sudo make install
sudo modprobe amneziawg
```

The container automatically detects support via `ip link add type wireguard`:
1. WireGuard/AmneziaWG kernel module (preferred — if the test succeeds, no userspace binary needed)
2. `amneziawg-go` userspace (fallback — auto-exported as `WG_QUICK_USERSPACE_IMPLEMENTATION`)

If the kernel module is already loaded, you can safely remove the `SYS_MODULE` capability from your container.

## Building

### Local Build

```bash
docker build -t amneziawg .
```

### Multi-Architecture Build

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t amneziawg .
```

## Project Structure

```
docker-amneziawg/
├── Dockerfile                              # 3-stage multi-arch build
├── docker-compose.yml                      # Example configuration
├── root/
│   ├── app/
│   │   └── show-peer                       # QR code display utility
│   ├── defaults/
│   │   ├── server.conf                     # Server template (eval+heredoc)
│   │   ├── peer.conf                       # Peer template (eval+heredoc)
│   │   └── Corefile                        # CoreDNS default config
│   └── etc/s6-overlay/s6-rc.d/
│       ├── init-adduser/branding           # Custom container branding
│       ├── init-amneziawg-module/          # Kernel module detection
│       ├── init-amneziawg-confs/           # Config generation
│       ├── svc-coredns/                    # CoreDNS service (longrun)
│       └── svc-amneziawg/                  # Tunnel service (oneshot up/down)
├── awg0.conf.example                       # Example config
└── README.md
```

## Best Practices: Bypassing Russian Censorship (TSPU/DPI)

Russia deploys TSPU (Technical Means of Counteracting Threats) equipment at ISP network nodes that performs deep packet inspection. This section covers practical recommendations for configuring AmneziaWG to avoid detection.

### How TSPU Detects VPN Traffic

1. **Protocol signature matching** - standard WireGuard has a fixed 148-byte Init packet and header type values 1-4. DPI matches these exactly.
2. **Packet length statistical analysis** - uniform data packet sizes are distinctive for WireGuard.
3. **Junk packet pattern detection** - some ISPs (notably MTS) fingerprint the burst of junk packets AWG 1.0 sends at connection start.
4. **TLS fingerprinting** - on port 443, TSPU checks whether UDP traffic matches expected QUIC/TLS patterns.
5. **Behavioral analysis** - sustained symmetric bidirectional tunnels running 24/7 are flagged.
6. **IP reputation / ASN blocking** - known VPS provider IP ranges may be preemptively blocked.

### Port Selection

**Use a random high port (10000-65535). Avoid the default 51820.**

| Port | Risk Level | Notes |
|------|------------|-------|
| 51820 | High | Default WireGuard port, actively fingerprinted |
| 443/udp | Medium | Works with QUIC-like I1 signatures, but TSPU applies TLS fingerprinting |
| Random high | Low | Harder for DPI to profile since there is no expected protocol to match |

### Server Location

Closer servers with less monitored transit links work best:

| Country | Latency from Moscow | Notes |
|---------|-------------------|-------|
| Finland | 20-30ms | Close proximity, generally reliable |
| Estonia | 25-35ms | Recommended by Amnezia team |
| Kazakhstan | 15-25ms | Lowest latency, less cross-border filtering |
| Poland | 35-45ms | Good balance of latency and reliability |

Avoid Netherlands and Germany - heavy filtering reported on major transit links. Prefer smaller regional VPS providers over well-known ones (DigitalOcean, Vultr, Hetzner) whose IP ranges are easier to blacklist.

### Recommended Configuration

For best results, use AWG 2.0 with Custom Protocol Signatures:

```yaml
services:
  amneziawg:
    image: ghcr.io/ayastrebov/docker-amneziawg:latest
    container_name: amneziawg
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - SERVERURL=vpn.example.com
      - SERVERPORT=39743
      - PEERS=phone,laptop
      - PEERDNS=1.1.1.1, 8.8.8.8
      - INTERNAL_SUBNET=10.13.13.0
      - ALLOWEDIPS=0.0.0.0/0, ::/0
      # Obfuscation - randomize these values for your setup
      # Leave H1-H4 unset to auto-generate quadrant-based ranges (recommended)
      - AWG_JC=4
      - AWG_JMIN=50
      - AWG_JMAX=1000
      - AWG_S1=67
      - AWG_S2=89
      - AWG_S3=25
      - AWG_S4=0
      # AWG 2.0 - QUIC-like signature packet
      - AWG_I1=<b 0xc0000000><r 16><t>
    volumes:
      - ./config:/config
    ports:
      - 39743:39743/udp
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

### Common Mistakes

| Mistake | Why It Fails |
|---------|-------------|
| Using port 51820 | Immediate WireGuard fingerprint match |
| S1=0, S2=0 | Packet sizes stay at standard WireGuard lengths (148 bytes for Init) |
| Same params as a popular tutorial | If many users share identical S/H values, DPI can fingerprint that set |
| S1 + 56 equals S2 | Response packet size becomes predictable relative to Init |
| AWG 1.0 on MTS | MTS specifically detects junk packet bursts; upgrade to AWG 2.0 |
| 24/7 single-connection tunnel | Behavioral analysis flags persistent symmetric traffic |
| Well-known VPS IP ranges | IPs may be preemptively blocked regardless of protocol |

### Tips

- **Always randomize your own parameter values** - do not copy exact values from examples. The auto-generated random defaults in this container are a good starting point.
- **Use AWG 2.0 with I1 signatures** when possible - it is significantly harder for TSPU to detect than AWG 1.0 junk packets alone.
- **Keep S4 small** (0-32) - data packet padding is per-packet overhead, large values kill throughput.
- **Consider split tunneling** (`ALLOWEDIPS=`) to route only necessary traffic through VPN, reducing the traffic profile.
- **Have a fallback ready** - the Amnezia team recommends VLESS+Reality (XRay) as a backup protocol when AWG faces active blocking campaigns.
- **Update regularly** - TSPU detection evolves; keep both server and client software up to date.

## Troubleshooting

### Custom SERVERPORT: use `SERVERPORT:51820/udp` mapping

The container always listens internally on port **51820**. When using a custom `SERVERPORT`, the Docker port mapping must forward the external port to the internal 51820:

```yaml
environment:
  - SERVERPORT=32948
ports:
  - 32948:51820/udp  # external:internal — NOT 32948:32948/udp
```

### No configuration files found

Ensure you either:
- Set `PEERS` environment variable for server mode
- Place `.conf` files in `./config/wg_confs/`

### Permission denied

Check that capabilities are set:
```yaml
cap_add:
  - NET_ADMIN
  - SYS_MODULE
```

### Tunnel fails to start

Check container logs:
```bash
docker logs amneziawg
```

Verify sysctl settings:
```yaml
sysctls:
  - net.ipv4.ip_forward=1
  - net.ipv4.conf.all.src_valid_mark=1
```

### QR code not displaying

Ensure `LOG_CONFS=true` is set, or use:
```bash
docker exec amneziawg /app/show-peer 1 2 3
```

## Links

- [GitHub Repository](https://github.com/AYastrebov/docker-amneziawg)
- [Docker Images](https://github.com/AYastrebov/docker-amneziawg/pkgs/container/docker-amneziawg)
- [AmneziaVPN Documentation](https://docs.amnezia.org/)
- [AmneziaWG Kernel Module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
- [AmneziaWG-go](https://github.com/amnezia-vpn/amneziawg-go)
- [AmneziaWG Tools](https://github.com/amnezia-vpn/amneziawg-tools)
- [Advanced AWG Hub Guide](ADVANCED_AWG_HUB.md) — run server + client in one container for censorship bypass proxy
- [LinuxServer docker-wireguard](https://github.com/linuxserver/docker-wireguard) (inspiration for this project)
- [LinuxServer Advanced WireGuard Hub](https://www.linuxserver.io/blog/advanced-wireguard-hub) (inspiration for the hub guide)
- [LinuxServer.io](https://www.linuxserver.io/)

## License

MIT License - see [LICENSE](LICENSE) file.
