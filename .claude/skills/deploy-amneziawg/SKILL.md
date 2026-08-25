---
name: deploy-amneziawg
description: |
  End-to-end deployment of the docker-amneziawg AmneziaWG VPN container to a VPS or any compatible Linux host. Use this skill whenever the user wants to deploy, install, set up, provision, launch, or "go live" with this container — including on fresh Ubuntu/Debian/Fedora/Rocky/Alma/Arch hosts, cloud VPS (Hetzner, DigitalOcean, Linode, OVH, AWS EC2, etc.), or their own server. Trigger even if the user only says things like "set this up on my server", "I have a VPS, what now?", "help me install this", "run this on my Hetzner box", "spin up the VPN", or just "deploy". The skill checks OS/Docker/Compose/kernel requirements, installs missing pieces, opens firewall ports, configures sysctls, gathers user settings (server URL, port, peers, DNS, AllowedIPs), generates AmneziaWG obfuscation parameters, writes a docker-compose.yml, pulls the image, brings the stack up, and prints peer configs/QR codes.
---

# Deploy docker-amneziawg

End-to-end deployment of this AmneziaWG VPN container to a fresh or existing Linux host. The goal is for the user to go from "I have a VPS" to "my phone is on the VPN via QR code" in one guided session.

## How to behave during this skill

This is an interactive deployment, not a code-gen task. You are operating on a real machine the user owns. Treat every step as something a careful human ops person would do:

- **Confirm before destructive or globally-impactful actions** — installing packages, modifying firewalls, writing sysctls, opening ports. Show the exact command and what it changes. The user gave durable approval for "full setup" if they invoked this skill, but each *category* of system change still warrants a "here's what I'm about to do" beat.
- **Don't guess values silently.** When a setting matters (`SERVERURL`, port, peer names), ask the user. Default-heavy settings (`INTERNAL_SUBNET`, `ALLOWEDIPS`, `TZ`) can be defaulted but should be summarized back before deploy.
- **Explain *why*, briefly.** When you ask for a value or run a check, say what it's for in one phrase. Users deploying VPNs often haven't touched WireGuard internals — the skill is also lightly educational.
- **Surface errors immediately, don't paper over them.** If `docker compose up -d` fails or `awg show` returns no peers, stop and diagnose. Don't continue to "post-deploy steps" pretending it worked.

## Phase 0 — Where am I running?

Before anything else, figure out where Claude is executing relative to the target host. There are three cases:

1. **On the target VPS itself** (user SSH'd in, installed Claude Code on the box, and ran this skill there). Local shell commands hit the target directly.
2. **On the user's workstation, deploying to a remote VPS** via SSH. Every check and install command needs to be wrapped in `ssh user@host`.
3. **On the user's workstation, deploying locally** (e.g., a home server they're physically at).

**Detection heuristic:** Look at `hostname`, check whether you're in the repo working directory (workstation signal), and check for `cloud-init`/typical VPS markers (`/etc/cloud/`, hosting-provider metadata). If ambiguous, **ask the user explicitly** — don't guess. Example: "Are we deploying to this machine (where Claude is running now), or to a remote VPS over SSH?"

If remote: collect SSH connection info up front (host/IP, user, port, auth method — key path or password via the user's own ssh-agent). **Test the SSH connection** with a trivial command (`ssh ... 'echo ok'`) before doing anything else. If it fails, fix that first.

For the rest of the skill, use `RUN` to mean "execute on the target host" — wrap in SSH if remote, run directly if local.

## Phase 1 — Requirements check

Read `references/requirements.md` for the full check list, distro detection logic, and architecture-specific notes. The short version:

| Check | What | If missing |
|---|---|---|
| OS | Linux + supported distro (`/etc/os-release`) | Stop. Not portable to macOS/Windows hosts. |
| Architecture | `x86_64` or `aarch64` | Stop. Image is only built for amd64/arm64. |
| Kernel | `uname -r`, `/dev/net/tun` present | Load `tun` module if missing. |
| Docker | `docker --version` | Offer to install via the official `get.docker.com` script. |
| Docker Compose v2 | `docker compose version` | Install `docker-compose-plugin` (modern Docker bundles it). |
| Permissions | User in `docker` group, or `sudo` available | Add to group + remind that re-login is needed. |
| Port free | UDP `SERVERPORT` not already bound | Ask user to pick another or stop the conflicting service. |
| AWG kernel module | Optional — `ip link add dev awgtest type amneziawg` | Falls back to userspace `amneziawg-go` automatically. Note this to the user. |

Run the checks, then **print a single summary table** of pass/fail before installing anything. Don't install silently — show the user what's missing, what you propose to install, and confirm.

## Phase 2 — Install missing pieces

For Docker installation commands per distro, firewall configuration (ufw / firewalld / nftables / iptables), and sysctl persistence, see `references/system-setup.md`.

Key system-level changes for this container:

```bash
# Persistent sysctls (write to /etc/sysctl.d/99-amneziawg.conf):
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=0

# Firewall: open SERVERPORT/udp (default 51820/udp)
# Also: NAT/masquerade for the VPN subnet if peers will route through the host
```

Do these in this order: (1) install Docker, (2) sysctls, (3) firewall, (4) ensure `/dev/net/tun`. Verify each step before proceeding.

## Phase 3 — Gather deployment settings

Ask the user for these settings. Group related questions to minimize back-and-forth — use `AskUserQuestion` with multi-question batches where possible, not one question per round-trip.

### Core settings (always ask)

| Setting | Env var | Default | Notes for the user |
|---|---|---|---|
| Server URL/IP | `SERVERURL` | `auto` (container detects external IP) | Use a real DNS name if the user has one — it survives IP changes. |
| Server port | `SERVERPORT` | `51820` | UDP. High ports (e.g., 32948, 51820) work on most networks. **Consider ≤ 9999** only if peers will be on mobile carriers known to block high UDP ports — real-world deployments use 32948 etc. without issues. Examples of low ports if blocks are expected: 1234, 4500, 8443. **If non-default, the host port maps `SERVERPORT:51820/udp`** — container always listens on 51820 internally. |
| Timezone | `TZ` | `Etc/UTC` | Pick from the IANA list. Affects log timestamps only. |
| Peers | `PEERS` | — (required for server mode) | See Phase 4. |

### Optional settings (ask if user wants to customize)

| Setting | Env var | Default | When to override |
|---|---|---|---|
| VPN subnet | `INTERNAL_SUBNET` | `10.13.13.0` | Change if `10.13.13.0/24` conflicts with the user's LAN. |
| Peer DNS | `PEERDNS` | `auto` (container's CoreDNS) | Override to `1.1.1.1, 8.8.8.8` if the user wants public resolvers. |
| Allowed IPs | `ALLOWEDIPS` | `0.0.0.0/0, ::/0` | Restrict to specific subnets for split-tunnel. |
| Persistent keepalive | `PERSISTENTKEEPALIVE_PEERS` | unset | Set to `all` for mobile peers behind NAT. |
| Per-peer site-to-site routes | `SERVER_ALLOWEDIPS_PEER_X` | unset | For routing back to a peer's LAN subnet. |
| Log configs | `LOG_CONFS` | `true` | Keep `true` initially to see QR codes; can disable later. |

For the full list of env vars, see the existing `docker-compose.yml` in the repo root.

## Phase 4 — Peer planning

Ask the user how to define peers. Two formats:

- **By count**: `PEERS=3` produces `peer1`, `peer2`, `peer3`
- **By name**: `PEERS=laptop,phone,tablet` produces `peer_laptop`, `peer_phone`, `peer_tablet` (underscore prefix is intentional — matches LinuxServer convention)

Named is friendlier — recommend it. If the user gives names, sanity-check them (no spaces, no special chars except `-` and `_`).

For each peer, optionally ask:
- Should it have `PERSISTENTKEEPALIVE` (recommend yes for mobile/NAT'd peers)?
- Should the server route a specific LAN subnet to it (site-to-site)?

## Phase 5 — AWG obfuscation parameters

This is the part most users don't understand. Read `references/awg-params.md` for full constraints, randomization rules, and the version split.

**Default recommendation: don't touch any AWG_* params.** The container auto-generates good values on first start (S1-S4, H1-H4 as quadrant ranges, I1 as a QUIC Initial packet matching RFC 9000). All of these get persisted to `/config/server/awg_params` and reused on restart.

Ask the user only:

1. **AWG version**:

   | Version | Pitch | Client requirement |
   |---|---|---|
   | `2.0` (default) | Full DPI evasion — I1-I5 signatures, H1-H4 ranges | AmneziaVPN app ≥ 4.8.12.9 |
   | `3.0` | Adds header protection, content padding, randomized timers | 3.0-capable client |
   | `3.1` | 3.0 plus `RandomTrailers` — handshake packets lose their fixed length | 3.1-capable client |
   | `1.5` | Legacy, easier to fingerprint | Any AmneziaVPN version |

   Recommend `2.0` unless the user knows every client is on 3.x software. The newer modes buy real DPI resistance but fail closed: a client that cannot parse the keys will not connect at all.

   For `3.1`, also mention `AWG_DISABLE_COOKIES=on` as a separate opt-in. It is **not** enabled by `AWG_VERSION=3.1`, because it gives up WireGuard's built-in DoS mitigation. Unlike `RandomTrailers` it does not have to match between ends, so it can be turned on server-side alone.

   Both switches also work with any version — `AWG_VERSION=2.0` plus `AWG_RANDOM_TRAILERS=on` is valid if the clients support it.

   If the host will use the **kernel datapath**, 3.1 switches need the `amneziawg` kernel module at v3.1 or newer. Check with `cat /sys/module/amneziawg/version`. On an older module the bundled `awg` parses the keys and the *kernel* refuses them, so `awg-quick` fails with `Unable to modify interface: Invalid argument` and the tunnel never comes up. (`Line unrecognized` is the different failure you get from userspace tools older than 3.1, which you would only meet outside this container.)

   The container warns at startup when it can read a numeric version from that file, but stays silent on a missing or non-numeric one — so run the check yourself rather than relying on the warning.

2. **Override randoms?** Offer three modes:
   - **Auto (recommended)** — leave `AWG_*` env vars unset; container randomizes on first boot.
   - **Generate now and pin in compose** — useful if the user wants to back up the docker-compose.yml and recreate the same setup elsewhere. Use `scripts/gen-awg-params.sh` to produce a valid set respecting all constraints:

     ```bash
     ./scripts/gen-awg-params.sh --version 3.1                        # 3.0 params + RandomTrailers
     ./scripts/gen-awg-params.sh --version 3.1 --disable-cookies on   # ...and no cookie replies
     ./scripts/gen-awg-params.sh --version 2.0 --random-trailers on   # switch without the 3.x param set
     ```
   - **User provides specific values** — for matching an existing AmneziaWG deployment. Validate against constraints before writing.

If the user picks "generate now", explain: server and **every** client must use identical S1-S4, H1-H4, I1-I5 values, plus `HeaderProtectionKey` and `RandomTrailers` when those are in play. Jc/Jmin/Jmax and the 3.x timer ranges may differ per side — each endpoint draws its own value from the range. `DisableCookies` is per-endpoint. Changing any of the shared values later means redistributing every peer config.

## Phase 6 — Write docker-compose.yml and deploy

1. Pick a deploy directory. Default: `/opt/amneziawg/`. Confirm with user.
2. Create `<deploy-dir>/config/` (will hold generated peer configs).
3. Write `<deploy-dir>/docker-compose.yml` using the answers from Phases 3-5. Use the template from `references/compose-template.md` — it has the exact structure including `cap_add`, `devices`, `sysctls`, and the correct port mapping logic for custom `SERVERPORT`.
4. Run `docker compose pull` and show progress.
5. Run `docker compose up -d`.
6. Wait ~5 seconds, then `docker compose logs --tail=100`. Look for:
   - `[init-amneziawg-confs] Generating configs...` — config generation OK
   - `[ls.io-init] done.` — s6 init complete
   - `[svc-amneziawg] Activating tunnel wg0...` — tunnel up
   - **Errors to catch**: missing `/dev/net/tun`, port already in use, "Cannot find device wg0", sysctl write failures.
7. Verify with `docker exec amneziawg awg show` — should list peers.

If anything looks wrong, stop and debug. Common gotchas are in `references/troubleshooting.md`.

## Phase 7 — Hand off configs to the user

For each peer:

```bash
docker exec amneziawg /app/show-peer <peer-name-or-number>
```

This prints the peer's `.conf` and a terminal QR code. The user scans with AmneziaVPN on their phone, or copies the `.conf` to a desktop client.

Tell the user:

- **Where the configs live on disk**: `<deploy-dir>/config/peer_<name>/peer_<name>.conf` and `.png`. They should back up this whole `config/` directory — it contains the server private key and all peer keys.
- **How to add more peers later**: edit `PEERS=...` in docker-compose.yml, then `docker compose up -d`. The container preserves existing peers and only generates configs for new names.
- **How to view configs again later**: `docker exec amneziawg /app/show-peer <name>`.
- **Where to get the client app**: https://amnezia.org/ (mention AmneziaVPN 4.8.12.9+ is required for AWG 2.0).

## Phase 8 — Post-deploy verification

Quick smoke test from a client:
1. Import the config into AmneziaVPN.
2. Connect. Tunnel should come up within a few seconds.
3. `curl https://api.ipify.org` from the client device → should show the VPS's public IP.
4. On the server: `docker exec amneziawg awg show` → endpoint and last-handshake timestamps should appear.

If the handshake never completes:
- Check the firewall on the VPS (and any cloud-provider security group / network ACL — `ufw` alone doesn't help if the cloud provider blocks the port at their edge).
- Check that the client app version supports AWG 2.0 (if so configured).
- Re-read the logs: `docker compose logs`.

## What NOT to do

- Don't run `docker compose up` (foreground) — always `-d`.
- Don't `chmod 777` the config directory — the container's `PUID/PGID` (default `1000:1000`) should match the user's UID on the host.
- Don't expose port 51820 over TCP — AmneziaWG is UDP-only.
- Don't put the AWG params behind a config-management system that re-randomizes on every apply — they need to be stable across restarts. The container persists them to `/config/server/awg_params` already; just don't fight it.
- Don't bypass the requirements check just because the user is in a hurry. If `/dev/net/tun` is missing, the container will start and look healthy but no traffic will flow.

## Relationship to upstream Amnezia docs

Upstream [Amnezia self-hosted instructions](https://docs.amnezia.org/documentation/instructions/install-vpn-on-server) describe a GUI-driven flow: install the AmneziaVPN desktop app, point it at a fresh VPS over SSH, and the app installs Docker, configures the server, and produces share-able configs — all without the user touching a terminal.

This skill is the opposite — a terminal-first flow for users who:
- Want to understand and own each step (sysctls, firewall, compose).
- Don't have the desktop app, or are deploying headless from a server they're already SSH'd into.
- Want reproducibility (a committed `docker-compose.yml` they can recreate from).

Where upstream is silent (firewall rules, sysctls, NAT/MASQUERADE, peer file extraction), this skill is explicit. Where upstream is stricter (x86_64 only), this skill is broader (multi-arch). Defer to upstream's [supported VPS matrix](https://docs.amnezia.org/documentation/supported-linux-os-for-vps) when classifying distros.

## References

- `references/requirements.md` — Detailed requirements check matrix + distro detection
- `references/system-setup.md` — Docker install, firewall, sysctls per distro
- `references/awg-params.md` — Full AWG obfuscation parameter reference and constraints
- `references/compose-template.md` — Annotated docker-compose.yml template
- `references/troubleshooting.md` — Common deploy failures and fixes
- `scripts/gen-awg-params.sh` — Generate a valid AWG_* parameter set respecting all constraints
- `scripts/check-requirements.sh` — Run all Phase 1 checks on the current host and print a summary table

External:
- [Amnezia self-hosted setup (official)](https://docs.amnezia.org/documentation/instructions/install-vpn-on-server)
- [AWG 2.0 upgrade notes](https://docs.amnezia.org/documentation/instructions/new-amneziawg-selfhosted/)
- [Supported VPS / distro matrix](https://docs.amnezia.org/documentation/supported-linux-os-for-vps)
