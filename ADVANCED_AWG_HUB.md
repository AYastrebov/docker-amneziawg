# Advanced AmneziaWG Hub: Server + Client in One Container

A guide for running a single `docker-amneziawg` container as both a VPN server and VPN client simultaneously, routing all connected peer traffic through one or more upstream VPN providers with automatic failover.

Based on the [LinuxServer.io Advanced WireGuard Hub](https://www.linuxserver.io/blog/advanced-wireguard-hub) guide, adapted for AmneziaWG with DPI bypass capabilities.

## Use Case: Russian Censorship Bypass Proxy

```
                         ┌─────────────────────────────────┐
                         │      Russian VPS (hub)          │
                         │   docker-amneziawg container    │
┌──────────┐   AWG       │                                 │   WG/AWG   ┌──────────────┐
│  Phone   │──────────►  │  wg0 (server) ──► wg1 (client) ─┼──────────► │  Proton VPN  │
│  Laptop  │  encrypted  │                 ► wg2 (client) ─┼──────────► │  WARP / Exit │
│  Router  │  + DPI hide │                                 │            └──────────────┘
└──────────┘             └─────────────────────────────────┘
```

**Why this setup?**

- Your devices connect to a Russian VPS using AmneziaWG with full obfuscation — TSPU/DPI sees it as random UDP or QUIC traffic
- The VPS container forwards all traffic through upstream VPN providers (Proton, WARP, custom servers) located outside Russia
- You get a clean non-Russian exit IP while the initial connection stays invisible to DPI
- If one upstream tunnel fails, traffic automatically switches to the backup
- One container, one set of peer configs — no need to reconfigure devices when switching exit providers

## Architecture

The container brings up **all** `.conf` files found in `/config/wg_confs/` (sorted alphabetically). This means:

| Config file | Role | Created by |
|---|---|---|
| `wg0.conf` | **Server** — accepts peer connections | Auto-generated (server mode) |
| `wg1.conf` | **Client** — primary upstream tunnel (e.g., Proton) | You, manually |
| `wg2.conf` | **Client** — backup upstream tunnel (e.g., WARP) | You, manually |

Traffic flow: `peer device → wg0 → routing rules → wg1 (or wg2 on failover) → internet`

## Step-by-Step Setup

### Step 1: Initial Server Setup

Start the container in server mode to generate keys and peer configs:

```yaml
# docker-compose.yml
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
      - TZ=Europe/Moscow
      - SERVERURL=your-russian-vps-ip
      - SERVERPORT=443        # Use 443/udp to mimic QUIC
      - PEERS=phone,laptop
      - PEERDNS=auto
      - INTERNAL_SUBNET=10.13.13.0
      # AWG obfuscation — QUIC-like signature for TSPU bypass
      - AWG_JC=5
      - AWG_JMIN=50
      - AWG_JMAX=1000
      - AWG_S1=68
      - AWG_S2=43
      - AWG_H1=1009484613
      - AWG_H2=826498173
      - AWG_H3=1709786516
      - AWG_H4=766939893
      - AWG_I1=<b 0xc0000000><r 16><t>    # QUIC Initial-like
    volumes:
      - ./config:/config
      - /lib/modules:/lib/modules
    ports:
      - 443:51820/udp
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

```bash
docker compose up -d
# Wait for config generation
docker logs amneziawg
# Save peer QR codes
docker exec amneziawg /app/show-peer phone laptop
```

After first start, your `./config/` directory will have:

```
config/
├── wg_confs/
│   └── wg0.conf          ← auto-generated server config
├── server/
│   ├── privatekey-server
│   ├── publickey-server
│   └── awg_params
├── phone/
│   ├── phone.conf         ← give this to your phone
│   └── phone.png          ← QR code
└── laptop/
    ├── laptop.conf
    └── laptop.png
```

### Step 2: Stop the Container

```bash
docker compose down
```

### Step 3: Edit Server Config (wg0.conf)

Replace the auto-generated `PostUp`/`PostDown` rules in `./config/wg_confs/wg0.conf` with advanced routing rules.

Open `./config/wg_confs/wg0.conf` and replace the `PostUp` and `PostDown` lines:

```ini
[Interface]
Address = 10.13.13.1/24
ListenPort = 51820
PrivateKey = <your-server-private-key>

# --- Advanced Hub Routing Rules ---
# Keep local/VPN subnet traffic on the main routing table
PostUp = ip rule add pref 100 to 10.13.13.0/24 lookup main
PostUp = iptables -I FORWARD -i %i -d 10.0.0.0/8 -j ACCEPT
PostUp = iptables -I FORWARD -i %i -d 172.16.0.0/12 -j ACCEPT
PostUp = iptables -I FORWARD -i %i -d 192.168.0.0/16 -j ACCEPT
PostUp = iptables -I FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -A FORWARD -j REJECT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# Start failover monitoring
PostUp = /config/awg_failover.sh &

PreDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
PreDown = iptables -D FORWARD -j REJECT
PreDown = iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PreDown = iptables -D FORWARD -i %i -d 192.168.0.0/16 -j ACCEPT
PreDown = iptables -D FORWARD -i %i -d 172.16.0.0/12 -j ACCEPT
PreDown = iptables -D FORWARD -i %i -d 10.0.0.0/8 -j ACCEPT
PreDown = ip rule del to 10.13.13.0/24 lookup main

# AmneziaWG Obfuscation Parameters
Jc = 5
Jmin = 50
Jmax = 1000
S1 = 68
S2 = 43
S3 = 0
S4 = 0
H1 = 1009484613
H2 = 826498173
H3 = 1709786516
H4 = 766939893
I1 = <b 0xc0000000><r 16><t>

[Peer]
# phone
PublicKey = ...
PresharedKey = ...
AllowedIPs = 10.13.13.2/32

[Peer]
# laptop
PublicKey = ...
PresharedKey = ...
AllowedIPs = 10.13.13.3/32
```

> **Important**: After editing `wg0.conf` manually, the container will NOT overwrite it on restart unless PEERS or AWG parameters change. If you need to add new peers later, add the `[Peer]` blocks manually to preserve your custom PostUp/PostDown rules.

### Step 4: Create Upstream Client Configs

#### wg1.conf — Primary Tunnel (e.g., Proton VPN)

Get your WireGuard config from [Proton VPN](https://account.protonvpn.com/) (Settings → WireGuard → Create Config).

Create `./config/wg_confs/wg1.conf`:

```ini
[Interface]
PrivateKey = <proton-private-key>
Address = 10.2.0.2/32
# Use a separate routing table — do NOT set a default route here
Table = 55111

# Route peer traffic through this tunnel
PostUp = iptables -I FORWARD -i wg0 -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = ip rule add pref 10001 from 10.13.13.0/24 lookup 55111

PreDown = ip rule del from 10.13.13.0/24 lookup 55111
PreDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE
PreDown = iptables -D FORWARD -i wg0 -o %i -j ACCEPT

[Peer]
PublicKey = <proton-server-public-key>
AllowedIPs = 0.0.0.0/0
Endpoint = <proton-server-ip>:51820
PersistentKeepalive = 25
```

#### wg2.conf — Backup Tunnel (e.g., Cloudflare WARP)

For WARP, use [wgcf](https://github.com/ViRb3/wgcf) to generate a WireGuard config, then adapt it.

Create `./config/wg_confs/wg2.conf`:

```ini
[Interface]
PrivateKey = <warp-private-key>
Address = 172.16.0.2/32
Table = 55112

PostUp = iptables -I FORWARD -i wg0 -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = ip rule add pref 10002 from 10.13.13.0/24 lookup 55112

PreDown = ip rule del from 10.13.13.0/24 lookup 55112
PreDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE
PreDown = iptables -D FORWARD -i wg0 -o %i -j ACCEPT

[Peer]
PublicKey = <warp-public-key>
AllowedIPs = 0.0.0.0/0
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
```

#### wg3.conf — Custom AmneziaWG Exit Server (Optional)

If you have your own AmneziaWG server abroad (e.g., in Finland), you get the best of both worlds — AWG obfuscation on both hops.

Create `./config/wg_confs/wg3.conf`:

```ini
[Interface]
PrivateKey = <your-client-private-key>
Address = 10.14.14.2/32
Table = 55113

PostUp = iptables -I FORWARD -i wg0 -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = ip rule add pref 10003 from 10.13.13.0/24 lookup 55113

PreDown = ip rule del from 10.13.13.0/24 lookup 55113
PreDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE
PreDown = iptables -D FORWARD -i wg0 -o %i -j ACCEPT

# AmneziaWG obfuscation (must match the remote server)
Jc = 4
Jmin = 40
Jmax = 700
S1 = 42
S2 = 87
S3 = 0
S4 = 0
H1 = 587432981
H2 = 1298374521
H3 = 987341256
H4 = 1547892031

[Peer]
PublicKey = <finland-server-public-key>
PresharedKey = <preshared-key>
AllowedIPs = 0.0.0.0/0
Endpoint = <finland-server-ip>:443
PersistentKeepalive = 25
```

### Step 5: Create Failover Script

Create `./config/awg_failover.sh`:

```bash
#!/bin/bash
# AmneziaWG Hub Failover Monitor
# Monitors upstream tunnels and switches traffic on failure

# Targets to ping through each tunnel (public DNS servers)
TARGETS=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4")

# Number of failed pings before declaring tunnel down
FAILOVER_LIMIT=2

# Subnets of connected peers (traffic to route through upstream tunnels)
LOCAL_RANGES=("10.13.13.0/24")

# Tunnel definitions: "interface;routing_table;priority"
# Lower priority number = preferred tunnel
# Adjust this list to match your wg1, wg2, wg3, etc.
TUNNELS=("wg1;55111;10001" "wg2;55112;10002")
# If you also have wg3 (custom AWG), add it:
# TUNNELS=("wg1;55111;10001" "wg2;55112;10002" "wg3;55113;10003")

# How often to check each tunnel (seconds)
PING_INTERVAL=20

LOG_FILE="/config/awg_failover.log"

apply_rules() {
    for LOCAL_RANGE in "${LOCAL_RANGES[@]}"; do
        ip rule del from "${LOCAL_RANGE}" lookup "$1" 2>/dev/null
        ip rule add pref "$2" from "${LOCAL_RANGE}" lookup "$1"
    done
}

FAILED=()
INDEX=0

echo "$(date +'%Y-%m-%d %T') - Failover monitor started" >> "$LOG_FILE"
echo "$(date +'%Y-%m-%d %T') - Monitoring tunnels: ${TUNNELS[*]}" >> "$LOG_FILE"

while sleep "$PING_INTERVAL"; do
    COUNTER=1
    IFS=";" read -r -a TUNNEL <<< "${TUNNELS[INDEX]}"
    TUNNEL_NAME="${TUNNEL[0]}"
    TUNNEL_TABLE="${TUNNEL[1]}"
    TUNNEL_PRIORITY="${TUNNEL[2]}"

    # Ensure tunnel is up
    awg-quick up "${TUNNEL_NAME}" > /dev/null 2>&1

    # Ping targets through this specific tunnel
    for TARGET in "${TARGETS[@]}"; do
        if ! ping -c1 -w10 -I "${TUNNEL_NAME}" "${TARGET}" > /dev/null 2>&1; then
            ((COUNTER++))
        fi
    done

    if [[ "$COUNTER" -gt "$FAILOVER_LIMIT" ]] && [[ ! "${FAILED[*]}" =~ "${TUNNEL_NAME}" ]]; then
        # Tunnel just failed — deprioritize it
        echo "$(date +'%Y-%m-%d %T') - ${TUNNEL_NAME} FAILED (${COUNTER} pings lost)" >> "$LOG_FILE"
        apply_rules "${TUNNEL_TABLE}" "$((TUNNEL_PRIORITY + 1000))"
        FAILED+=("${TUNNEL_NAME}")

    elif [[ "$COUNTER" -le "$FAILOVER_LIMIT" ]] && [[ "${FAILED[*]}" =~ "${TUNNEL_NAME}" ]]; then
        # Tunnel recovered — restore original priority
        echo "$(date +'%Y-%m-%d %T') - ${TUNNEL_NAME} RESTORED" >> "$LOG_FILE"
        apply_rules "${TUNNEL_TABLE}" "${TUNNEL_PRIORITY}"
        FAILED=("${FAILED[@]/$TUNNEL_NAME}")

    elif [[ "$COUNTER" -gt "$FAILOVER_LIMIT" ]] && [[ "${FAILED[*]}" =~ "${TUNNEL_NAME}" ]]; then
        # Tunnel still down — bring it down to save resources, it will be retried
        awg-quick down "${TUNNEL_NAME}" > /dev/null 2>&1
    fi

    ((INDEX++))
    if [[ $((INDEX + 1)) -gt ${#TUNNELS[@]} ]]; then
        INDEX=0
    fi
done
```

Make it executable:

```bash
chmod +x ./config/awg_failover.sh
```

### Step 6: Start the Hub

```bash
docker compose up -d
```

Verify all tunnels are up:

```bash
docker exec amneziawg awg show
```

You should see `wg0`, `wg1`, `wg2` (and `wg3` if configured).

Check routing rules:

```bash
docker exec amneziawg ip rule show
```

Expected output (relevant lines):

```
100:    from all to 10.13.13.0/24 lookup main
10001:  from 10.13.13.0/24 lookup 55111
10002:  from 10.13.13.0/24 lookup 55112
```

Check failover log:

```bash
docker exec amneziawg cat /config/awg_failover.log
```

## How the Routing Works

1. **Peer traffic arrives** on `wg0` from subnet `10.13.13.0/24`
2. **Policy routing** (`ip rule`) directs it to routing table `55111` (wg1, highest priority)
3. **If wg1 fails**, the failover script deprioritizes table `55111` (pref 11001) and traffic falls through to table `55112` (wg2, pref 10002)
4. **If wg1 recovers**, its priority is restored (pref 10001) and traffic returns to it
5. **Local traffic** (to `10.13.13.0/24` and private subnets) stays on the `main` table and never goes through upstream tunnels

## Configuration Variants

### Single Upstream (No Failover)

If you only need one upstream tunnel (e.g., just Proton), skip `wg2.conf` and the failover script. Simplify `wg0.conf` PostUp/PostDown:

```ini
PostUp = iptables -I FORWARD -i %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o wg1 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o wg1 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
```

### Split Routing by Peer

Route different peers through different upstream tunnels. For example, `phone` through Proton and `laptop` through WARP:

In `wg1.conf` PostUp (Proton — only phone, `10.13.13.2`):
```ini
PostUp = iptables -I FORWARD -i wg0 -s 10.13.13.2 -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s 10.13.13.2 -o %i -j MASQUERADE
PostUp = ip rule add pref 10001 from 10.13.13.2/32 lookup 55111
PreDown = ip rule del from 10.13.13.2/32 lookup 55111
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.2 -o %i -j MASQUERADE
PreDown = iptables -D FORWARD -i wg0 -s 10.13.13.2 -o %i -j ACCEPT
```

In `wg2.conf` PostUp (WARP — only laptop, `10.13.13.3`):
```ini
PostUp = iptables -I FORWARD -i wg0 -s 10.13.13.3 -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s 10.13.13.3 -o %i -j MASQUERADE
PostUp = ip rule add pref 10002 from 10.13.13.3/32 lookup 55112
PreDown = ip rule del from 10.13.13.3/32 lookup 55112
PreDown = iptables -t nat -D POSTROUTING -s 10.13.13.3 -o %i -j MASQUERADE
PreDown = iptables -D FORWARD -i wg0 -s 10.13.13.3 -o %i -j ACCEPT
```

### Double AWG Obfuscation (Russia → Finland → Internet)

For maximum stealth against TSPU, use AmneziaWG on both hops:

1. **Hop 1** (device → Russian VPS): AWG with QUIC-like I1 signature on port 443/udp
2. **Hop 2** (Russian VPS → Finnish server): AWG with different obfuscation params

This gives you two layers of AWG obfuscation. The Russian VPS sees only obfuscated AWG from your device, and the outbound traffic from the VPS to Finland is also obfuscated — making it extremely difficult for TSPU to identify as VPN traffic in either direction.

Run a second `docker-amneziawg` instance on the Finnish server in standard server mode, then use its peer config as the basis for `wg3.conf` on the Russian hub (see Step 4 wg3 example above).

## Troubleshooting

### Peers connect but have no internet

Check that forwarding is enabled and upstream tunnel is working:

```bash
# Inside the container
docker exec amneziawg bash -c '
  echo "=== IP Rules ==="
  ip rule show
  echo ""
  echo "=== Routing Table 55111 (wg1) ==="
  ip route show table 55111
  echo ""
  echo "=== AWG Interfaces ==="
  awg show
  echo ""
  echo "=== Ping through wg1 ==="
  ping -c2 -I wg1 1.1.1.1
'
```

Common fixes:
- Ensure `net.ipv4.ip_forward=1` sysctl is set in docker-compose
- Check that the upstream VPN provider config is correct
- Verify `iptables` rules are applied: `docker exec amneziawg iptables -t nat -L -n`

### Failover not working

```bash
# Check failover log
docker exec amneziawg cat /config/awg_failover.log

# Check if the script is running
docker exec amneziawg ps aux | grep failover

# Check routing table priorities
docker exec amneziawg ip rule show
```

### Config regeneration overwrites custom wg0.conf

If you change `PEERS` or AWG parameters in docker-compose, the container will regenerate `wg0.conf` and overwrite your custom PostUp/PostDown rules.

To prevent this:
- After initial setup, do NOT change `PEERS` or AWG env vars
- To add new peers, manually edit `wg0.conf` and add `[Peer]` blocks
- Alternatively, unset `PEERS` to switch to client mode and manage all configs manually

### TSPU still blocking the connection

If your device-to-VPS connection is detected:
- Try a different port (see the port selection table in [README.md](README.md#best-practices-bypassing-russian-censorship-tspudpi))
- Enable AWG 2.0 I1 signature to mimic QUIC (`AWG_I1=<b 0xc0000000><r 16><t>`)
- Check that H1-H4 values are unique and not default WireGuard headers (1-4)
- Consider switching to a less obvious VPS provider (avoid Hetzner, DigitalOcean — prefer smaller providers)

## Proton VPN Config Extraction

1. Go to [Proton VPN Settings](https://account.protonvpn.com/) → WireGuard → Create Configuration
2. Select a server (e.g., `NL-FREE#123` or a Plus server)
3. Download the `.conf` file
4. Extract `PrivateKey`, `Address`, `PublicKey`, and `Endpoint` values
5. Use them in your `wg1.conf` (replacing the `[Interface]` and `[Peer]` sections, keeping the custom `Table` and routing rules)

## WARP Config Generation

```bash
# Install wgcf
# On the VPS or locally:
curl -L https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_amd64 -o wgcf
chmod +x wgcf

# Register and generate config
./wgcf register
./wgcf generate

# Extract PrivateKey, Address, PublicKey, Endpoint from wgcf-profile.conf
# Use them in your wg2.conf
```

## Further Reading

- [README.md](README.md) — Full container documentation and Russian censorship bypass tips
- [LinuxServer.io Advanced WireGuard Hub](https://www.linuxserver.io/blog/advanced-wireguard-hub) — Original guide this document is based on
- [AmneziaWG Protocol](https://docs.amnezia.org/documentation/amnezia-wg/) — How AWG obfuscation works
- [Proton VPN WireGuard Setup](https://protonvpn.com/support/wireguard-configurations/) — Getting WireGuard configs from Proton
