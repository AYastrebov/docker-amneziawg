# Requirements Check — Detailed Reference

This is the full Phase 1 check matrix. Run all checks before printing the summary table to the user.

## 1. Operating System

```bash
# Must be Linux
[ "$(uname -s)" = "Linux" ] || fail "macOS/Windows hosts not supported"

# Distro detection
. /etc/os-release  # provides $ID, $VERSION_ID, $ID_LIKE
```

**Supported distros** (tested):

| `$ID` | Versions | Docker install method |
|---|---|---|
| `ubuntu` | 20.04, 22.04, 24.04 | `get.docker.com` script (works on all current LTS) |
| `debian` | 11, 12, 13 | `get.docker.com` script |
| `fedora` | 38+ | `dnf install docker docker-compose-plugin` |
| `rocky` / `almalinux` / `centos` | 8, 9 | `dnf install docker-ce docker-ce-cli docker-compose-plugin` (after adding Docker repo) |
| `arch` | rolling | `pacman -S docker docker-compose` |
| `alpine` | 3.18+ | `apk add docker docker-cli-compose` — works, but warn user about minimal default toolchain |
| `opensuse-tumbleweed` / `opensuse-leap` | recent | `zypper install docker docker-compose` |

**Borderline / use with caution:**
- **CoreOS / Flatcar / Bottlerocket** — Docker is already there but immutable rootfs. Skip "install Docker" step; the rest works.
- **Synology DSM / OpenWRT / TrueNAS** — User likely knows what they're doing. Confirm Docker daemon is reachable, then skip install steps.

**Reject and stop:**
- Anything without systemd *and* without OpenRC (the container's sysctls and `/dev/net/tun` setup need a real init system).
- Distros older than the matrix above — they ship Docker too old to support compose v2.

## 2. Architecture

```bash
arch=$(uname -m)
case "$arch" in
    x86_64|amd64) ;;
    aarch64|arm64) ;;
    *) fail "Architecture $arch not supported (image only builds amd64/arm64)" ;;
esac
```

armv7 (32-bit Pi) is **not** supported by the upstream image.

> Note: official Amnezia docs list **only x86_64** as supported. This container image is built multi-arch, so arm64 (e.g., Hetzner CAX, Oracle Ampere, AWS Graviton, Raspberry Pi 4/5) works too. Mention this if the user is on arm64 — it's a deliberate divergence from upstream.

## 3. Kernel

```bash
# Kernel version minimums:
#   - 4.14+ for AWG 2.0 (per official Amnezia docs)
#   - 5.6+  for in-kernel WireGuard datapath (otherwise userspace amneziawg-go fallback)
kver=$(uname -r)

# TUN device
[ -c /dev/net/tun ] || {
    # Try to load it
    modprobe tun 2>/dev/null || fail "/dev/net/tun missing and modprobe tun failed — kernel may be missing TUN support"
}

# IPv4 reachable? Amnezia upstream considers IPv6-only hosts unsupported.
ip -4 route get 1.1.1.1 &>/dev/null || warn "Host appears to have no IPv4 default route — AmneziaWG over IPv6-only is not officially supported"

# IPv6 egress (optional): peers always get an IPv6 address inside the tunnel; this only
# affects whether that traffic can exit the container.
ip -6 route get 2001:4860:4860::8888 &>/dev/null && ok "Host has IPv6 egress — peers can get IPv6 via NAT66" || warn "No IPv6 egress on host — peers will be IPv4-only (no leak either way)"
docker version --format '{{.Server.Version}}' 2>/dev/null | awk -F. '{exit ($1>=27)?0:1}' && ok "Docker >= 27: enable_ipv6 does NAT66 natively" || warn "Docker < 27: set \"ip6tables\": true in daemon.json before enabling IPv6 on the network"

# Optional: AmneziaWG kernel module
# Check if available (don't require — userspace fallback works)
if lsmod | grep -q amneziawg || modinfo amneziawg &>/dev/null; then
    note "amneziawg kernel module available — will run in-kernel (faster)"
else
    note "amneziawg kernel module not available — will fall back to amneziawg-go userspace (works fine, slightly higher CPU)"
fi
```

If AmneziaWG kernel module is not installed, *do not* try to install it as part of this skill — it requires DKMS/kernel headers and is brittle across distros. Direct the user to https://github.com/amnezia-vpn/amneziawg-linux-kernel-module if they ask, but make it clear the userspace fallback is fine for almost all use cases.

## 4. Docker

```bash
# Daemon reachable?
if ! command -v docker &>/dev/null; then
    missing+=(docker)
elif ! docker info &>/dev/null; then
    # Docker installed but daemon not running or permission denied
    if ! sudo -n docker info &>/dev/null 2>&1; then
        fail "Docker daemon not reachable. Either start it (systemctl start docker) or add the user to the docker group."
    fi
fi

# Version >= 20.10 for sysctls in compose
docker_version=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
```

## 5. Docker Compose v2

```bash
# Prefer v2 (built-in 'docker compose'), accept v1 fallback ('docker-compose')
if docker compose version &>/dev/null; then
    compose_cmd="docker compose"
elif command -v docker-compose &>/dev/null; then
    compose_cmd="docker-compose"
    warn "Using legacy docker-compose v1. Upgrade to v2 (docker-compose-plugin) when convenient."
else
    missing+=(docker-compose-plugin)
fi
```

## 6. Permissions

```bash
# Can the current user run docker without sudo?
if ! docker ps &>/dev/null; then
    if groups | grep -q '\bdocker\b'; then
        warn "User is in docker group but docker ps fails — re-login required, or use sudo for this session"
    else
        # Will need sudo or group add
        if ! sudo -n true 2>/dev/null; then
            fail "Need sudo access (for first-time setup) or membership in docker group"
        fi
    fi
fi
```

## 7. Port availability

```bash
serverport=${SERVERPORT:-51820}

# Check if UDP port is already bound
if ss -lun "sport = :$serverport" 2>/dev/null | grep -q ":$serverport"; then
    fail "UDP port $serverport already in use. Pick another via SERVERPORT, or stop the conflicting process."
fi
```

`ss` is preferred over `netstat` (modern, in iproute2). If `ss` isn't available, fall back to `lsof -iUDP:$serverport -P -n` or `netstat -lun`.

## 8. Disk and memory (soft checks)

```bash
# Disk: image is ~150MB, configs are tiny. Need ~500MB free in deploy dir.
df_avail_mb=$(df -BM /opt 2>/dev/null | awk 'NR==2 {gsub("M",""); print $4}')
[ "${df_avail_mb:-0}" -lt 500 ] && warn "Less than 500MB free in /opt — consider another deploy location"

# Memory: container idle uses ~30MB. No real minimum, but warn under 256MB total.
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mb" -lt 256 ] && warn "Host has only ${mem_mb}MB RAM — should still work but is tight"
```

These are soft — don't block on them, just inform.

## Summary table format

After all checks, print a single table the user can read at a glance:

```
Requirements check:
  [OK]   OS:           Ubuntu 24.04 (supported)
  [OK]   Architecture: x86_64
  [OK]   Kernel:       6.8.0-45-generic, /dev/net/tun present
  [WARN] AWG module:   not loaded, will use userspace amneziawg-go (fine)
  [MISS] Docker:       not installed — proposing to install via get.docker.com
  [MISS] Compose v2:   not installed — bundled with Docker install
  [OK]   Permissions:  user 'ubuntu' has sudo
  [OK]   Port:         UDP 51820 free
  [OK]   Disk:         42GB free in /opt
  [OK]   Memory:       2048MB total

Missing: docker, docker-compose-plugin
Proposed actions:
  1. Install Docker + compose plugin via https://get.docker.com
  2. Add user 'ubuntu' to docker group
  3. Write sysctls to /etc/sysctl.d/99-amneziawg.conf
  4. Open UDP/51820 in ufw

Proceed? [y/N]
```

Always show this *and wait for confirmation* before mutating system state.
