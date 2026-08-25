# Deployment Troubleshooting

Things that go wrong during Phases 6-8 and how to diagnose them.

## Container won't start

### `Error response from daemon: failed to create task ... cannot find /dev/net/tun`

The host doesn't have the TUN device, or the container can't see it. Check:

```bash
ls -l /dev/net/tun                  # should exist on host
docker exec amneziawg ls -l /dev/net/tun  # should exist in container
```

If missing on host: `sudo modprobe tun` + add to `/etc/modules-load.d/modules.conf`. If still missing after that, the VPS kernel doesn't support TUN (common on LXC/OpenVZ-based VPS plans) — switch providers.

### `Error response from daemon: driver failed programming external connectivity ... port is already allocated`

Another process is bound to the chosen `SERVERPORT`. Find it:

```bash
sudo ss -lunp "sport = :51820"
```

Either stop the conflicting process or choose another `SERVERPORT`.

### Container in restart loop

```bash
docker compose logs --tail=200
```

Look for the first ERROR line. Common causes:
- Missing capability (`NET_ADMIN`) — check `cap_add` block.
- Missing sysctl (`src_valid_mark`) — check `sysctls` block.
- Bad `INTERNAL_SUBNET` format — must be `X.X.X.0` (network address, not host).
- Bad `AWG_*` value — e.g., `S1+56 == S2`, `H1-H4` not unique, `Jmin >= Jmax`. The container logs the failed validation.

## Tunnel is up but no traffic

### `docker exec amneziawg awg show` shows the peer but no `latest handshake`

The peer hasn't connected yet. Check from the client side:
- Client config has the right `Endpoint` (matches `SERVERURL:SERVERPORT`)?
- Client config has the AWG params (Jc/S/H/I) — *check both `[Interface]` for I1-I5 and the top of `[Interface]` for S/H*?
- UDP port is reachable from client → server? `nc -u -v <server> 51820` from the client should not say "Connection refused" (though UDP "connect" is fuzzy — better signal: `tcpdump -i any port 51820 -n` on the server while the client tries to connect).

### Handshake completes but no internet through the tunnel

This is almost always a routing/firewall issue on the server:

```bash
# On the server
sysctl net.ipv4.ip_forward                # must be 1
sysctl net.ipv4.conf.all.src_valid_mark   # must be 1
sudo iptables -t nat -L POSTROUTING -nv   # should show MASQUERADE for 10.13.13.0/24
```

If MASQUERADE rule is missing, the container can route to the internet but the return path is broken. Add it:

```bash
sudo iptables -t nat -A POSTROUTING -s 10.13.13.0/24 -o eth0 -j MASQUERADE
# Or via ufw/firewalld/nftables — see system-setup.md
```

### Client sees the tunnel as connected but can't resolve DNS

The peer is trying to resolve via `PEERDNS`. If `PEERDNS=auto`, the container's CoreDNS at `10.13.13.1` should answer. Check:

```bash
docker exec amneziawg netstat -ulnp | grep :53   # CoreDNS should be listening
docker exec amneziawg cat /config/coredns/Corefile
```

If CoreDNS is not running (port 53 was already bound at startup), set `USE_COREDNS=true` explicitly or change `PEERDNS` to a public resolver like `1.1.1.1`.

## Amnezia app reports "AWG 1.5" but we deployed 2.0

H1-H4 are written as single integers instead of ranges. The container auto-generates ranges for AWG 2.0 — check the generated config:

```bash
docker exec amneziawg cat /config/wg_confs/wg0.conf | grep '^H[1-4]'
```

Should look like:
```
H1 = 90666522-140666522
H2 = 1145769205-1195769205
```

If they're single integers, `AWG_VERSION` was inferred as 1.5. Either explicitly set `AWG_VERSION=2.0` or check that the user didn't pass single-integer overrides for H1-H4.

## Tunnel fails to start after enabling the AWG 3.1 switches

Two different errors, two different causes:

| Error from `awg-quick` | Who rejected it |
|---|---|
| `Unable to modify interface: Invalid argument` | The **kernel module** — the bundled `awg` parsed the key fine and the kernel refused it over netlink. This is the case inside this container, whose tools are pinned at 3.1 |
| `Line unrecognized: RandomTrailers` | The **userspace tools** — an `awg` build older than 3.1 does not know the key at all. Only relevant outside this container, e.g. on a client host |

With `AWG_RANDOM_TRAILERS` or `AWG_DISABLE_COOKIES` set, the first one means the host `amneziawg` **kernel module** predates 3.1:

```bash
cat /sys/module/amneziawg/version   # need >= 3.1
docker logs <container> | grep -i "kernel module"
```

The container warns about this at startup. Two fixes:

1. Upgrade the host module — `apt install --only-upgrade amneziawg-dkms` (or reinstall the DKMS package), then reboot or reload the module.
2. Drop the switches: set `AWG_RANDOM_TRAILERS=off` and `AWG_DISABLE_COOKIES=off` and restart. The rest of the AWG parameter set works on older modules, so there is no need to leave `AWG_VERSION=3.1`.

   Removing the variables entirely is **not** enough — like every other `AWG_*` setting they are restored from `/config/server/awg_params`, so an absent variable means "reuse the saved value". An empty value does not work either: s6 drops empty variables from `container_environment`, so the script sees it as absent. `off` is the one that works, and it omits the key from the config rather than writing `= off`, which is what an old module needs.

Note that the tunnel fails **closed** here — nothing comes up, rather than one option being silently ignored.

## Peers on AWG 3.1 can't connect, server looks fine

`RandomTrailers` changes the receive path as well as the send path. A peer without it expects handshake packets of exactly one length and drops the padded ones. It must be on for the server **and** every peer, or for none of them.

The container writes it into every conf it generates, so container-generated peers are consistent automatically. Suspect this when a peer conf was hand-written, carried over from an older deployment, or used with a client that ignores unknown `[Interface]` keys.

Also check the client actually supports 3.1 — an AmneziaVPN app or `amneziawg` build older than 3.1 will not parse the key.

## QR code not in logs

`LOG_CONFS=true` must be set. By default it's `true`, but if the user disabled it:

```bash
docker exec amneziawg /app/show-peer <peer-name>
```

This works without `LOG_CONFS` and prints both the conf and a terminal QR.

## Logs say "Generating configs..." but then nothing

Config generation hung. Common cause: `SERVERURL=auto` and the container can't reach the external IP lookup service. Hardcode an IP/DNS name and recreate:

```bash
docker compose down
# Edit docker-compose.yml: change SERVERURL=auto → SERVERURL=1.2.3.4
docker compose up -d
```

## After changing AWG params, peers can't connect

Expected. Any change to S1-S4, H1-H4, or I1-I5 invalidates every existing peer config. Either:
1. Revert the change, or
2. Redistribute every peer config (`docker exec amneziawg /app/show-peer <name>` and re-import on each device).

## Container started fine but the user's phone won't connect from cellular

Likely the mobile carrier blocks UDP on the chosen port. Try:
- `SERVERPORT=443` (most carriers don't block 443/udp because of QUIC), but check that no other service uses 443/udp on the VPS.
- `SERVERPORT` ≤ 9999 — some carriers blanket-block high UDP ports.
- Enable `PERSISTENTKEEPALIVE_PEERS=<that peer>` so the tunnel survives carrier NAT rebinds.

## Cloud-provider firewall is blocking despite host firewall being open

Already covered in `system-setup.md` — remind the user to check Security Groups / Network ACLs at the cloud-provider level. `ufw status` saying "Allow" means nothing if AWS/GCP/Hetzner's firewall is in front and closed.

## Container starts but `docker exec amneziawg awg show` says "command not found"

Wrong container name (the user changed `container_name:`). Find it:

```bash
docker ps --format '{{.Names}}'
```

Use the actual name in subsequent `docker exec` commands.

## Persistent config got out of sync (env vars don't match generated configs)

The container saves env vars to `/config/.donoteditthisfile` and only regenerates configs if something changed. If the user manually edited generated configs, those edits stick. To force a full regeneration:

```bash
docker compose down
sudo rm <deploy-dir>/config/.donoteditthisfile
sudo rm -rf <deploy-dir>/config/server <deploy-dir>/config/wg_confs <deploy-dir>/config/peer*
docker compose up -d
```

**Warning:** this regenerates the server keypair too, invalidating all peer configs. Only do this if the user accepts re-issuing every peer.

If only AWG obfuscation params need refreshing:

```bash
docker compose down
sudo rm <deploy-dir>/config/server/awg_params
docker compose up -d  # re-randomizes AWG_* and rewrites configs, but server keypair survives
```
