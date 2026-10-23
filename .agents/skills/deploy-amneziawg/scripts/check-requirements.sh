#!/usr/bin/env bash
#
# check-requirements.sh — Run all Phase 1 deployment checks on the current
# host and print a summary table. Exit 0 on all-OK or only-warnings, exit 1
# if any required check failed.
#
# Usage: ./check-requirements.sh [serverport]
#   serverport: UDP port to check availability (default 51820)

set -u

PORT="${1:-51820}"

# Color codes (only if stdout is a tty)
if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_FAIL=""; C_RESET=""
fi

fail_count=0
warn_count=0

row() {
    local status=$1 label=$2 detail=$3
    case "$status" in
        OK)   printf '  %s[ OK ]%s  %-14s %s\n' "$C_OK"   "$C_RESET" "$label:" "$detail" ;;
        WARN) printf '  %s[WARN]%s  %-14s %s\n' "$C_WARN" "$C_RESET" "$label:" "$detail"; warn_count=$((warn_count+1)) ;;
        FAIL) printf '  %s[FAIL]%s  %-14s %s\n' "$C_FAIL" "$C_RESET" "$label:" "$detail"; fail_count=$((fail_count+1)) ;;
        MISS) printf '  %s[MISS]%s  %-14s %s\n' "$C_FAIL" "$C_RESET" "$label:" "$detail"; fail_count=$((fail_count+1)) ;;
    esac
}

echo "Requirements check (target port: UDP/$PORT)"
echo

# --- OS ---
if [ "$(uname -s)" != "Linux" ]; then
    row FAIL "OS" "$(uname -s) — only Linux is supported"
else
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|fedora|rocky|almalinux|centos|arch|manjaro|alpine|opensuse-tumbleweed|opensuse-leap)
                row OK "OS" "${PRETTY_NAME:-$ID $VERSION_ID}"
                ;;
            *)
                row WARN "OS" "${PRETTY_NAME:-$ID} — untested, may work"
                ;;
        esac
    else
        row WARN "OS" "Linux, but /etc/os-release missing — unknown distro"
    fi
fi

# --- Architecture ---
arch=$(uname -m)
case "$arch" in
    x86_64|amd64)  row OK   "Architecture" "$arch" ;;
    aarch64|arm64) row OK   "Architecture" "$arch" ;;
    *)             row FAIL "Architecture" "$arch — image only supports amd64/arm64" ;;
esac

# --- Kernel + TUN ---
kver=$(uname -r)
if [ -c /dev/net/tun ]; then
    row OK "Kernel" "$kver, /dev/net/tun present"
else
    if modprobe tun 2>/dev/null && [ -c /dev/net/tun ]; then
        row OK "Kernel" "$kver, /dev/net/tun loaded via modprobe"
    else
        row FAIL "Kernel" "$kver, /dev/net/tun missing — VPS may be LXC/OpenVZ without TUN support"
    fi
fi

# --- AmneziaWG kernel module (optional) ---
if lsmod 2>/dev/null | grep -q '^amneziawg' || modinfo amneziawg &>/dev/null; then
    row OK "AWG module" "kernel module available (in-kernel datapath)"
else
    row WARN "AWG module" "not installed — userspace amneziawg-go fallback will be used (fine)"
fi

# --- Docker ---
if ! command -v docker &>/dev/null; then
    row MISS "Docker" "not installed"
    docker_ok=0
else
    if docker info &>/dev/null; then
        dv=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        row OK "Docker" "$dv (daemon reachable)"
        docker_ok=1
    elif sudo -n docker info &>/dev/null; then
        dv=$(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        row WARN "Docker" "$dv installed but current user needs sudo — add to docker group"
        docker_ok=1
    else
        row FAIL "Docker" "installed but daemon not reachable (not running? permission denied?)"
        docker_ok=0
    fi
fi

# --- Compose v2 ---
if docker compose version &>/dev/null; then
    cv=$(docker compose version --short 2>/dev/null || docker compose version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    row OK "Compose v2" "$cv"
elif command -v docker-compose &>/dev/null; then
    cv=$(docker-compose --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    row WARN "Compose" "legacy v1 ($cv) — upgrade to v2 when convenient"
else
    row MISS "Compose v2" "not installed — bundled with current Docker install"
fi

# --- Permissions ---
if [ "$(id -u)" = "0" ]; then
    row OK "Permissions" "running as root"
elif id -nG 2>/dev/null | grep -qw docker; then
    if docker ps &>/dev/null; then
        row OK "Permissions" "user $(id -un) is in docker group"
    else
        row WARN "Permissions" "user $(id -un) is in docker group but docker ps fails — re-login required"
    fi
elif sudo -n true 2>/dev/null; then
    row WARN "Permissions" "user $(id -un) has passwordless sudo (not in docker group)"
else
    row FAIL "Permissions" "user $(id -un) lacks docker group AND sudo"
fi

# --- Port ---
if command -v ss &>/dev/null; then
    if ss -lun "sport = :$PORT" 2>/dev/null | grep -q ":$PORT"; then
        bound=$(ss -lunp "sport = :$PORT" 2>/dev/null | awk 'NR>1 {print $NF}' | head -1)
        row FAIL "Port UDP/$PORT" "already in use: $bound"
    else
        row OK "Port UDP/$PORT" "free"
    fi
elif command -v lsof &>/dev/null; then
    if lsof -iUDP:"$PORT" -P -n 2>/dev/null | grep -q UDP; then
        row FAIL "Port UDP/$PORT" "already in use"
    else
        row OK "Port UDP/$PORT" "free"
    fi
else
    row WARN "Port UDP/$PORT" "neither ss nor lsof installed — cannot verify"
fi

# --- Disk ---
target_dir="/opt"
[ -d "$target_dir" ] || target_dir="/"
avail_mb=$(df -BM "$target_dir" 2>/dev/null | awk 'NR==2 {gsub("M",""); print $4}')
if [ -n "${avail_mb:-}" ]; then
    if [ "$avail_mb" -lt 500 ]; then
        row WARN "Disk" "${avail_mb}MB free in $target_dir — tight"
    else
        row OK "Disk" "${avail_mb}MB free in $target_dir"
    fi
else
    row WARN "Disk" "couldn't read df $target_dir"
fi

# --- Memory ---
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
if [ -n "${mem_mb:-}" ]; then
    if [ "$mem_mb" -lt 256 ]; then
        row WARN "Memory" "${mem_mb}MB total — tight"
    else
        row OK "Memory" "${mem_mb}MB total"
    fi
fi

# --- Sysctls ---
# Only ip_forward genuinely matters on the host. src_valid_mark and disable_ipv6
# are set inside the container's netns via compose 'sysctls:' — host values don't
# need to be touched. Look in PATH first, then fall back to absolute path
# (some minimal distros omit /sbin from non-root PATH).
sysctl_bin=$(command -v sysctl 2>/dev/null || { [ -x /usr/sbin/sysctl ] && echo /usr/sbin/sysctl; } || { [ -x /sbin/sysctl ] && echo /sbin/sysctl; })
if [ -n "${sysctl_bin:-}" ]; then
    ipfwd=$("$sysctl_bin" -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    if [ "$ipfwd" = "1" ]; then
        row OK "Sysctls" "ip_forward=1 (set)"
    else
        row WARN "Sysctls" "ip_forward=$ipfwd — will be set during install"
    fi
else
    row WARN "Sysctls" "sysctl binary not found in PATH or /usr/sbin or /sbin"
fi

echo
if [ "$fail_count" -gt 0 ]; then
    echo "${C_FAIL}Result:${C_RESET} $fail_count blocking issue(s), $warn_count warning(s)"
    exit 1
elif [ "$warn_count" -gt 0 ]; then
    echo "${C_WARN}Result:${C_RESET} ready to deploy (with $warn_count warning(s))"
    exit 0
else
    echo "${C_OK}Result:${C_RESET} all checks passed — ready to deploy"
    exit 0
fi
