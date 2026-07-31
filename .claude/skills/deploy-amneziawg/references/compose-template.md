# docker-compose.yml — Annotated Template

This is the production deploy template. Fill in `<<...>>` placeholders with the user's chosen values from Phase 3-5.

## Minimal server-mode template

```yaml
services:
  amneziawg:
    image: ghcr.io/ayastrebov/docker-amneziawg:latest
    container_name: amneziawg
    cap_add:
      - NET_ADMIN
      # SYS_MODULE is NOT required for the kernel datapath — this container never
      # calls modprobe; it expects the wireguard/amneziawg module to already be
      # loaded on the host. Keep it only on minimal hosts that don't auto-load
      # iptables NAT modules. Otherwise omit.
      # - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - PUID=<<host user uid, e.g. 1000>>
      - PGID=<<host user gid, e.g. 1000>>
      - TZ=<<IANA timezone, e.g. Europe/Berlin>>

      # Server mode — set PEERS to enable
      - SERVERURL=<<vpn.example.com OR auto>>
      - SERVERPORT=<<external port, default 51820>>
      - PEERS=<<count OR comma-separated names>>
      - PEERDNS=<<auto OR 1.1.1.1, 8.8.8.8>>
      - INTERNAL_SUBNET=<<10.13.13.0>>
      - ALLOWEDIPS=<<0.0.0.0/0, ::/0>>
      - PERSISTENTKEEPALIVE_PEERS=<<all OR peer names OR omit>>
      - LOG_CONFS=true

      # AWG version (omit for default 2.0)
      # - AWG_VERSION=2.0

      # AWG obfuscation — omit all of these to let the container randomize.
      # Pin them only if you need to reproduce this exact setup elsewhere.
      # - AWG_JC=4
      # - AWG_JMIN=50
      # - AWG_JMAX=200
      # - AWG_S1=86
      # - AWG_S2=12
      # - AWG_S3=42
      # - AWG_S4=15
      # - AWG_H1=90666522-140666522
      # - AWG_H2=1145769205-1195769205
      # - AWG_H3=2200871888-2250871888
      # - AWG_H4=3255974571-3305974571
      # - AWG_I1=<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>
    volumes:
      - ./config:/config
    ports:
      # IMPORTANT: container always listens on 51820 internally regardless of SERVERPORT.
      # Map external SERVERPORT to internal 51820.
      - "<<SERVERPORT>>:51820/udp"
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
    restart: unless-stopped
```

## Important rules when filling the template

### Port mapping with custom `SERVERPORT`

The container **always** listens on `51820/udp` internally. If the user chose a non-default `SERVERPORT`:

```yaml
environment:
  - SERVERPORT=32948
ports:
  - "32948:51820/udp"   # ✅ Correct: external 32948 → internal 51820
  # - "32948:32948/udp" # ❌ Wrong: container isn't listening on 32948
```

### Kernel datapath vs userspace fallback

The container picks its datapath at startup by running `ip link add dev test type amneziawg` (the amnezia kernel module's link kind — `awg-quick` brings tunnels up with `type amneziawg`, not `type wireguard`, so a plain wireguard module does not enable the kernel datapath). If that succeeds, it uses the kernel datapath via netlink. If it fails, it falls back to userspace `amneziawg-go` (works fine for almost all use cases; slightly higher CPU).

The container **does not load kernel modules itself** — it only checks whether they're already loaded. So the recipe for in-kernel datapath is:

1. On the **host**, install + load the `wireguard` kernel module (built-in to most modern kernels — usually nothing to do) or the `amneziawg` module (see [amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)).
2. No special container config needed — `cap_add: NET_ADMIN` is sufficient.

`SYS_MODULE` is **not** required to use the kernel datapath. The init script even prints a message recommending you drop it once the kernel module is active. The only edge case where `SYS_MODULE` may still be useful is on minimal hosts that don't auto-load iptables NAT modules — in that case keep it. Otherwise, omit it.

A `/lib/modules:/lib/modules` bind mount is **not needed** for this container at all (nothing inside ever calls `modprobe`). Some compose examples in the wild include it — that's a copy-paste from generic kernel-module-loading patterns and is a no-op here.

### `PUID`/`PGID`

Match the host user that owns `<deploy-dir>/config/`. On most clean VPS:
```bash
id -u  # → 1000 (typical first user)
id -g  # → 1000
```

If deploying as root (some minimal cloud images), use `PUID=0 PGID=0` — but recommend creating a non-root user first.

### `SERVERURL`

- If the user has a DNS name pointing at the VPS: use it. Survives IP changes.
- If not: use `auto` (container will detect external IP via `ifconfig.me`-style lookup at boot).
- If `auto` is wrong (e.g., behind double NAT, or the VPS has a different public IP than what `auto` finds): the user can hardcode an IP.

### `PEERS` formatting

- Numeric: `PEERS=3` → directories `peer1`, `peer2`, `peer3`
- Named: `PEERS=laptop,phone,tablet` → directories `peer_laptop`, `peer_phone`, `peer_tablet`

Names: lowercase, alphanumeric + `-` + `_`, no spaces. Validate before writing.

### Per-peer overrides

If the user wants per-peer settings, add separate env vars *after* the main `PEERS` line:

```yaml
- PEERS=laptop,phone,homeserver
- PERSISTENTKEEPALIVE_PEERS=laptop,phone   # mobile peers behind NAT
- SERVER_ALLOWEDIPS_PEER_homeserver=192.168.1.0/24  # route home LAN to homeserver peer
```

The `SERVER_ALLOWEDIPS_PEER_X` pattern uses the peer name (without the `peer_` prefix for named peers, or just the number for numeric).

## Client mode (no PEERS)

If the user wants to deploy purely as a client (e.g., to route a Docker network through an upstream AWG provider), drop `PEERS=` and place the AWG `.conf` file at `./config/wg_confs/wg0.conf` before starting:

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
      # No PEERS = client mode. CoreDNS is auto-disabled.
    volumes:
      - ./config:/config
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

No `ports:` needed — client mode is outbound-only.

## After writing the file

```bash
cd <deploy-dir>
docker compose pull
docker compose up -d
docker compose logs --tail=200
docker exec amneziawg awg show
```
