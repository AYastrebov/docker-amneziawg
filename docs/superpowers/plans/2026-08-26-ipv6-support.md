# IPv6 Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every peer a ULA IPv6 address by default (closing the dual-stack leak), NAT66 IPv6 egress when the Docker network has IPv6, and fast-fail (ICMPv6 reject + no AAAA) when it does not.

**Architecture:** Pure decision logic (prefix derivation/validation, exit-mode resolution, template migration, CoreDNS filter) lives in a new sourceable library `root/app/ipv6-lib.sh` with a bash unit-test script that runs on any machine. `init-amneziawg-confs/run` sources the library, resolves `IP6_PREFIX` / `IP6_EXIT_EFFECTIVE` / `IP6_POSTUP` / `IP6_POSTDOWN` once at startup, and the templates consume them via `${VAR:+...}` expansion so firewall policy never lives in user-owned templates again. CI runs the unit tests and container smoke scenarios.

**Tech Stack:** bash 5 (Alpine), s6-overlay v3, awg-quick (bash), ip6tables (nft backend), CoreDNS `template` plugin, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-26-ipv6-support-design.md`

## Global Constraints

- s6 drops empty env vars: disabling is the literal `IP6_SUBNET=off`, never an empty value.
- `IP6_SUBNET` accepts only `<1-4 hextets>::/64`; invalid → warn + derived ULA, never a broken conf.
- `IP6_SUBNET=off` must produce output byte-identical to the current container (no `ip6tables` at all).
- `auto` exit → `nat` only when: `disable_ipv6=0` AND a v6 default route exists AND `forwarding=1` AND prefix is ULA. GUA → `routed`. Otherwise `off` (REJECT rules) with a one-line reason.
- Peer IPv6 host part is the IPv4 last octet written literally (`10.13.13.10` → `::10/128`).
- Derived prefix: `a.b.c.0` → `fd<aa>:<bb><cc>:0000::/64` in lowercase hex (`10.13.13.0` → `fd0a:0d0d:0000::`).
- Templates in `/config/templates/` are user-owned: migrate by exact-line match, warn (never fail) on customised lines.
- Existing user `Corefile`s are never edited; only hinted.
- Shell style: 4-space indent, `# shellcheck shell=bash`, `local` only inside functions, `**** message ****` log format.
- Commits: conventional commits; end every commit message with the two trailer lines used in this repo (`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD`).
- Branch: `feature/ipv6-support`, rebased on `master` at `656d987` (#36 merged: shipped template now has `ip6tables ... DROP` rules and `SERVERURL=auto` already uses `curl -4`).

---

### Task 1: Library skeleton + prefix derivation and validation

**Files:**
- Create: `root/app/ipv6-lib.sh`
- Create: `tests/ipv6-lib.test.sh`

**Interfaces:**
- Produces:
  - `ip6_derive_prefix <INTERFACE>` — stdout: prefix ending in `::`, e.g. `fd0a:0d0d:0000::`. `INTERFACE` is the 3-octet string the run script already computes (`10.13.13`).
  - `ip6_validate_subnet <value>` — stdout: normalised lowercase prefix ending in `::` (the `/64` stripped); exit 1 (no output) when invalid.
  - `ip6_resolve_subnet` — reads `IP6_SUBNET`, `INTERFACE`; sets global `IP6_PREFIX` (`""` when off) and `IP6_SUBNET_EFFECTIVE` (`off` or `<prefix>/64`); logs one line.
  - `ip6_is_ula <prefix>` — exit 0 when prefix is inside `fc00::/7`.
  - `ip6_server_addr <prefix>` → `<prefix>1/128`; `ip6_peer_addr <prefix> <client_ip>` → `<prefix><last-octet>/128`.
- Test harness: `tests/ipv6-lib.test.sh` defines `assert_eq <expected> <actual> <name>` and `assert_fail <name> <cmd...>`, exits non-zero on any failure, prints `PASS n / FAIL m`.

- [ ] **Step 1: Write the failing tests**

Create `tests/ipv6-lib.test.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for root/app/ipv6-lib.sh. Runs on any machine with bash >= 4.
# Usage: bash tests/ipv6-lib.test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../root/app/ipv6-lib.sh
source "${HERE}/../root/app/ipv6-lib.sh"

PASS=0; FAIL=0
assert_eq() {
    local expected=$1 actual=$2 name=$3
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$name" "$expected" "$actual"
    fi
}
assert_fail() {
    local name=$1; shift
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); printf 'FAIL: %s (expected non-zero exit)\n' "$name"
    else
        PASS=$((PASS + 1))
    fi
}
assert_contains() {
    local haystack=$1 needle=$2 name=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); printf 'FAIL: %s\n  missing: %q\n  in:      %q\n' "$name" "$needle" "$haystack"
    fi
}

# ---- prefix derivation -------------------------------------------------
assert_eq "fd0a:0d0d:0000::" "$(ip6_derive_prefix 10.13.13)" "derive default subnet"
assert_eq "fdc0:a801:0000::" "$(ip6_derive_prefix 192.168.1)" "derive 192.168.1"
assert_eq "fdac:1f00:0000::" "$(ip6_derive_prefix 172.31.0)" "derive 172.31.0"

# ---- validation --------------------------------------------------------
assert_eq "fd12:3456:789a::" "$(ip6_validate_subnet 'fd12:3456:789a::/64')" "valid ULA /64"
assert_eq "2001:db8:1::" "$(ip6_validate_subnet '2001:db8:1::/64')" "valid GUA /64"
assert_eq "fd12::" "$(ip6_validate_subnet 'FD12::/64')" "lowercased, one hextet"
assert_eq "fd12:1:2:3::" "$(ip6_validate_subnet 'fd12:1:2:3::/64')" "four hextets"
assert_fail "five hextets" ip6_validate_subnet 'fd12:1:2:3:4::/64'
assert_fail "no /64" ip6_validate_subnet 'fd12:3456::'
assert_fail "/48" ip6_validate_subnet 'fd12:3456::/48'
assert_fail "/80" ip6_validate_subnet 'fd12:3456::/80'
assert_fail "no double colon" ip6_validate_subnet 'fd12:3456:1:2:3:4:5:6/64'
assert_fail "triple colon" ip6_validate_subnet 'fd12:::/64'
assert_fail "non-hex" ip6_validate_subnet 'fdzz::/64'
assert_fail "hextet too long" ip6_validate_subnet 'fd123:4::/64'
assert_fail "empty" ip6_validate_subnet ''
assert_fail "off is not a prefix" ip6_validate_subnet 'off'

# ---- ULA test ----------------------------------------------------------
if ip6_is_ula 'fd0a:0d0d:0000::'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: fd is ULA"; fi
if ip6_is_ula 'fc00::'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: fc is ULA"; fi
assert_fail "2001 is not ULA" ip6_is_ula '2001:db8::'
assert_fail "fe80 is not ULA" ip6_is_ula 'fe80::'

# ---- addresses ---------------------------------------------------------
assert_eq "fd0a:0d0d:0000::1/128" "$(ip6_server_addr 'fd0a:0d0d:0000::')" "server addr"
assert_eq "fd0a:0d0d:0000::2/128" "$(ip6_peer_addr 'fd0a:0d0d:0000::' 10.13.13.2)" "peer .2"
assert_eq "fd0a:0d0d:0000::10/128" "$(ip6_peer_addr 'fd0a:0d0d:0000::' 10.13.13.10)" "peer .10 literal"
assert_eq "fd0a:0d0d:0000::254/128" "$(ip6_peer_addr 'fd0a:0d0d:0000::' 10.13.13.254)" "peer .254"

# ---- resolve_subnet ----------------------------------------------------
INTERFACE=10.13.13
unset IP6_SUBNET
out=$(ip6_resolve_subnet; printf '%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "fd0a:0d0d:0000::|fd0a:0d0d:0000::/64" "${out##*$'\n'}" "unset -> derived"

IP6_SUBNET=off
out=$(ip6_resolve_subnet; printf '%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${out##*$'\n'}" "off -> empty prefix"
IP6_SUBNET=OFF
out=$(ip6_resolve_subnet; printf '%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${out##*$'\n'}" "OFF case-insensitive"

IP6_SUBNET='fd12:3456:789a::/64'
out=$(ip6_resolve_subnet; printf '%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "fd12:3456:789a::|fd12:3456:789a::/64" "${out##*$'\n'}" "user prefix"

IP6_SUBNET='bogus'
log=$(ip6_resolve_subnet 2>&1; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_contains "$log" 'IP6_SUBNET "bogus" is invalid' "invalid warns"
assert_eq "fd0a:0d0d:0000::|fd0a:0d0d:0000::/64" "${log##*$'\n'}" "invalid -> derived"

echo "PASS ${PASS} / FAIL ${FAIL}"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/ipv6-lib.test.sh`
Expected: fails immediately with `No such file or directory` for `root/app/ipv6-lib.sh`.

- [ ] **Step 3: Write the library**

Create `root/app/ipv6-lib.sh`:

```bash
#!/bin/bash
# shellcheck shell=bash
# IPv6 helpers for init-amneziawg-confs. Sourced, not executed.
# Pure functions read only their arguments or the documented globals so the
# file can be unit-tested outside the container (tests/ipv6-lib.test.sh).
#
# Globals consumed: IP6_SUBNET, IP6_EXIT, INTERFACE
# Globals produced: IP6_PREFIX, IP6_SUBNET_EFFECTIVE, IP6_EXIT_EFFECTIVE,
#                   IP6_POSTUP, IP6_POSTDOWN

# a.b.c -> fdaa:bbcc:0000:: (RFC 4193 ULA, deterministic per subnet)
ip6_derive_prefix() {
    local iface=$1 a b c
    IFS=. read -r a b c <<< "${iface}"
    printf 'fd%02x:%02x%02x:0000::\n' "${a}" "${b}" "${c}"
}

# Accepts "<1-4 hextets>::/64" (any case). Prints the lowercase prefix without
# the /64. Returns 1 on anything else.
ip6_validate_subnet() {
    local v="${1,,}"
    [[ "${v}" =~ ^([0-9a-f]{1,4}:){0,3}[0-9a-f]{1,4}::/64$ ]] || return 1
    printf '%s\n' "${v%/64}"
}

# fc00::/7 -> first byte is 0xfc or 0xfd
ip6_is_ula() {
    [[ "${1,,}" =~ ^f[cd][0-9a-f]{2}: ]]
}

ip6_server_addr() {
    printf '%s1/128\n' "$1"
}

# <prefix> <client_ipv4> -> <prefix><last octet>/128 ; the octet is written
# literally (10.13.13.10 -> ::10) so a peer's two addresses always line up.
ip6_peer_addr() {
    local prefix=$1 client_ip=$2
    printf '%s%s/128\n' "${prefix}" "${client_ip##*.}"
}

# Sets IP6_PREFIX ("" when IPv6 is disabled) and IP6_SUBNET_EFFECTIVE.
ip6_resolve_subnet() {
    local requested="${IP6_SUBNET:-}" derived
    derived=$(ip6_derive_prefix "${INTERFACE}")
    if [[ "${requested,,}" == "off" ]]; then
        IP6_PREFIX=""
        IP6_SUBNET_EFFECTIVE="off"
        echo "**** IPv6 is disabled (IP6_SUBNET=off); peers get IPv4 addresses only ****"
        return 0
    fi
    if [[ -z "${requested}" ]]; then
        IP6_PREFIX="${derived}"
    elif IP6_PREFIX=$(ip6_validate_subnet "${requested}"); then
        :
    else
        echo "**** IP6_SUBNET \"${requested}\" is invalid (expected e.g. fd12:3456:789a::/64); using derived ${derived}/64 ****"
        IP6_PREFIX="${derived}"
    fi
    IP6_SUBNET_EFFECTIVE="${IP6_PREFIX}/64"
    echo "**** IPv6 tunnel prefix is ${IP6_SUBNET_EFFECTIVE} (server $(ip6_server_addr "${IP6_PREFIX}")) ****"
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/ipv6-lib.test.sh`
Expected: last line `PASS 33 / FAIL 0` (count may differ by ±1 if you add cases; `FAIL 0` is the requirement).

- [ ] **Step 5: Lint**

Run: `shellcheck -s bash root/app/ipv6-lib.sh tests/ipv6-lib.test.sh` (install with `brew install shellcheck` if missing).
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add root/app/ipv6-lib.sh tests/ipv6-lib.test.sh
git commit -m "feat(ipv6): add prefix derivation and validation library with unit tests

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD"
```

---

### Task 2: Exit-mode resolution

**Files:**
- Modify: `root/app/ipv6-lib.sh` (append)
- Modify: `tests/ipv6-lib.test.sh` (append before the final `echo "PASS…"`)

**Interfaces:**
- Consumes: `IP6_PREFIX` from `ip6_resolve_subnet`.
- Produces:
  - Probe functions (overridable in tests): `ip6_stack_enabled`, `ip6_has_default_route`, `ip6_forwarding_enabled` — exit 0/1.
  - `ip6_resolve_exit` — reads `IP6_EXIT` (default `auto`), `IP6_PREFIX`; sets `IP6_EXIT_EFFECTIVE` (`nat|routed|off`), `IP6_POSTUP`, `IP6_POSTDOWN` (both `""` when `IP6_PREFIX` is empty); logs one line.

- [ ] **Step 1: Append failing tests**

Insert before `echo "PASS ${PASS} / FAIL ${FAIL}"` in `tests/ipv6-lib.test.sh`:

```bash
# ---- resolve_exit ------------------------------------------------------
# Probes are overridden so the tests do not depend on the host's network.
stack=0; route=0; fwd=0
ip6_stack_enabled()     { [[ $stack == 1 ]]; }
ip6_has_default_route() { [[ $route == 1 ]]; }
ip6_forwarding_enabled(){ [[ $fwd == 1 ]]; }

ACCEPT='ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT'
REJECT='ip6tables -A FORWARD -i %i -j REJECT --reject-with icmp6-adm-prohibited; ip6tables -A FORWARD -o %i -j REJECT --reject-with icmp6-adm-prohibited'
MASQ='ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE'

run_exit() {  # <IP6_EXIT> <IP6_PREFIX> <stack> <route> <fwd> -> "mode|postup|postdown" on last line
    IP6_EXIT=$1 IP6_PREFIX=$2 stack=$3 route=$4 fwd=$5
    local out
    out=$(ip6_resolve_exit; printf '\n%s|%s|%s' "$IP6_EXIT_EFFECTIVE" "$IP6_POSTUP" "$IP6_POSTDOWN")
    printf '%s' "${out##*$'\n'}"
}
run_exit_log() {
    IP6_EXIT=$1 IP6_PREFIX=$2 stack=$3 route=$4 fwd=$5
    ip6_resolve_exit
}

assert_eq "nat|${ACCEPT}; ${MASQ}|${ACCEPT//-A/-D}; ${MASQ/-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 1 1)" "auto: ula+route+fwd -> nat"
assert_eq "routed|${ACCEPT}|${ACCEPT//-A/-D}" \
    "$(run_exit auto 2001:db8:1:: 1 1 1)" "auto: gua+route+fwd -> routed"
assert_eq "off|${REJECT}|${REJECT//-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 0 1)" "auto: no route -> off"
assert_eq "off|${REJECT}|${REJECT//-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 1 0)" "auto: no forwarding -> off"
assert_eq "off|${REJECT}|${REJECT//-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 0 1 1)" "auto: stack disabled -> off"
assert_eq "nat|${ACCEPT}; ${MASQ}|${ACCEPT//-A/-D}; ${MASQ/-A/-D}" \
    "$(run_exit nat fd0a:0d0d:0000:: 0 0 0)" "forced nat ignores probes"
assert_eq "routed|${ACCEPT}|${ACCEPT//-A/-D}" \
    "$(run_exit routed fd0a:0d0d:0000:: 0 0 0)" "forced routed"
assert_eq "off|${REJECT}|${REJECT//-A/-D}" \
    "$(run_exit off fd0a:0d0d:0000:: 1 1 1)" "forced off"
assert_eq "nat|${ACCEPT}; ${MASQ}|${ACCEPT//-A/-D}; ${MASQ/-A/-D}" \
    "$(run_exit NAT fd0a:0d0d:0000:: 0 0 0)" "mode is case-insensitive"
assert_eq "off||" "$(run_exit auto '' 1 1 1)" "no prefix -> off, no rules"
assert_eq "off||" "$(run_exit nat '' 1 1 1)" "no prefix beats forced nat"
assert_eq "nat|${ACCEPT}; ${MASQ}|${ACCEPT//-A/-D}; ${MASQ/-A/-D}" \
    "$(run_exit bogus fd0a:0d0d:0000:: 1 1 1)" "unknown mode -> auto"
assert_contains "$(run_exit_log bogus fd0a:0d0d:0000:: 1 1 1)" 'IP6_EXIT "bogus" is not one of' "unknown mode warns"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 0 1)" 'no IPv6 default route' "off reason: route"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 0 1)" 'enable_ipv6: true' "off hint names the fix"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 1 0)" 'forwarding' "off reason: forwarding"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 1 1)" 'IPv6 exit: nat' "nat logged"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/ipv6-lib.test.sh 2>&1 | tail -3`
Expected: `ip6_resolve_exit: command not found` lines and `FAIL` > 0.

- [ ] **Step 3: Append the implementation**

Append to `root/app/ipv6-lib.sh`:

```bash
# ---- exit mode ---------------------------------------------------------
# Probes read the container's own netns. Tests override them.
ip6_stack_enabled() {
    [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "0" ]]
}
ip6_has_default_route() {
    [[ -n "$(ip -6 route show default 2>/dev/null)" ]]
}
ip6_forwarding_enabled() {
    [[ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" == "1" ]]
}

# Sets IP6_EXIT_EFFECTIVE, IP6_POSTUP, IP6_POSTDOWN from IP6_EXIT and IP6_PREFIX.
ip6_resolve_exit() {
    local mode="${IP6_EXIT:-auto}" reason=""
    local accept='ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT'
    local reject='ip6tables -A FORWARD -i %i -j REJECT --reject-with icmp6-adm-prohibited; ip6tables -A FORWARD -o %i -j REJECT --reject-with icmp6-adm-prohibited'
    local masq='ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE'
    mode="${mode,,}"
    IP6_POSTUP=""
    IP6_POSTDOWN=""
    if [[ -z "${IP6_PREFIX}" ]]; then
        IP6_EXIT_EFFECTIVE="off"
        echo "**** IPv6 exit: off (IPv6 disabled; no ip6tables rules will be applied) ****"
        return 0
    fi
    case "${mode}" in
        auto|nat|routed|off) ;;
        *)
            echo "**** IP6_EXIT \"${IP6_EXIT}\" is not one of auto|nat|routed|off; using auto ****"
            mode="auto"
            ;;
    esac
    if [[ "${mode}" == "auto" ]]; then
        if ! ip6_stack_enabled; then
            mode="off"; reason="IPv6 is disabled in the container (sysctl net.ipv6.conf.all.disable_ipv6=1)"
        elif ! ip6_has_default_route; then
            mode="off"; reason="no IPv6 default route in the container"
        elif ! ip6_forwarding_enabled; then
            mode="off"; reason="sysctl net.ipv6.conf.all.forwarding is 0"
        elif ip6_is_ula "${IP6_PREFIX}"; then
            mode="nat"
        else
            mode="routed"
        fi
    fi
    IP6_EXIT_EFFECTIVE="${mode}"
    case "${mode}" in
        nat)    IP6_POSTUP="${accept}; ${masq}" ;;
        routed) IP6_POSTUP="${accept}" ;;
        off)    IP6_POSTUP="${reject}" ;;
    esac
    IP6_POSTDOWN="${IP6_POSTUP//ip6tables -A/ip6tables -D}"
    IP6_POSTDOWN="${IP6_POSTDOWN//-t nat -A/-t nat -D}"
    case "${mode}" in
        nat)    echo "**** IPv6 exit: nat (peers' IPv6 traffic is masqueraded out of eth+) ****" ;;
        routed) echo "**** IPv6 exit: routed (no NAT; ${IP6_PREFIX}/64 must be routed to this host) ****" ;;
        off)
            if [[ -n "${reason}" ]]; then
                echo "**** IPv6 exit: off (${reason}). Peers get IPv6 addresses but IPv6 traffic is rejected. To enable IPv6 egress set 'networks.default.enable_ipv6: true' and sysctl 'net.ipv6.conf.all.forwarding=1' in docker-compose.yml, or set IP6_SUBNET=off to disable IPv6 entirely ****"
            else
                echo "**** IPv6 exit: off (IP6_EXIT=off). Peers get IPv6 addresses but IPv6 traffic is rejected ****"
            fi
            ;;
    esac
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/ipv6-lib.test.sh | tail -1`
Expected: `PASS <n> / FAIL 0`

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -s bash root/app/ipv6-lib.sh tests/ipv6-lib.test.sh
git add root/app/ipv6-lib.sh tests/ipv6-lib.test.sh
git commit -m "feat(ipv6): resolve exit mode (auto/nat/routed/off) into PostUp rules

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD"
```

---

### Task 3: Template migration

**Files:**
- Modify: `root/app/ipv6-lib.sh` (append)
- Modify: `tests/ipv6-lib.test.sh` (append)

**Interfaces:**
- Produces:
  - `ip6_migrate_line <file> <new-line> <marker> <label> <old-exact-line>...` — if `<file>` contains `<marker>` (fixed string, anywhere) → no-op; else if it contains any `<old-exact-line>` as a whole line → replace that line with `<new-line>` and log `migrated`; else log a `customised` warning. Always exits 0.
  - `ip6_migrate_templates <server.conf> <peer.conf>` — applies the four rows from the spec §4.3; `PostUp`/`PostDown` each recognise **two** old variants (pre-#36 ACCEPT+MASQUERADE, and #36's DROP).
- Constants (exported for the run script and the tests):
  - `IP6_OLD_SERVER_ADDRESS`, `IP6_NEW_SERVER_ADDRESS`, `IP6_OLD_POSTUP_ACCEPT`, `IP6_OLD_POSTUP_DROP`, `IP6_NEW_POSTUP`, `IP6_OLD_POSTDOWN_ACCEPT`, `IP6_OLD_POSTDOWN_DROP`, `IP6_NEW_POSTDOWN`, `IP6_OLD_PEER_ADDRESS`, `IP6_NEW_PEER_ADDRESS`.

- [ ] **Step 1: Append failing tests**

```bash
# ---- template migration ------------------------------------------------
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

old_server() {  # exactly the template shipped before this feature
    cat > "$1" <<'EOF'
[Interface]
Address = ${INTERFACE}.1
ListenPort = 51820
PrivateKey = $(cat /config/server/privatekey-server)
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o eth+ -j MASQUERADE
Jc = ${AWG_JC}
EOF
}
old_peer() {
    cat > "$1" <<'EOF'
[Interface]
Address = ${CLIENT_IP}
PrivateKey = $(cat /config/${PEER_ID}/privatekey-${PEER_ID})
DNS = ${PEERDNS}

[Peer]
AllowedIPs = ${ALLOWEDIPS}
EOF
}
drop_server() {  # the template shipped by #36 (656d987): ip6tables DROP, no v6 NAT
    cat > "$1" <<'EOF'
[Interface]
Address = ${INTERFACE}.1
ListenPort = 51820
PrivateKey = $(cat /config/server/privatekey-server)
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; ip6tables -D FORWARD -i %i -j DROP; ip6tables -D FORWARD -o %i -j DROP
Jc = ${AWG_JC}
EOF
}

old_server "$TMPD/server.conf"; old_peer "$TMPD/peer.conf"
log=$(ip6_migrate_templates "$TMPD/server.conf" "$TMPD/peer.conf")
assert_contains "$(cat "$TMPD/server.conf")" 'Address = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}' "server Address migrated"
assert_contains "$(cat "$TMPD/server.conf")" 'MASQUERADE${IP6_POSTUP:+; ${IP6_POSTUP}}' "PostUp migrated"
assert_contains "$(cat "$TMPD/server.conf")" 'MASQUERADE${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}' "PostDown migrated"
assert_eq "0" "$(grep -c 'ip6tables' "$TMPD/server.conf")" "old ip6tables rules gone"
assert_contains "$(cat "$TMPD/peer.conf")" 'Address = ${CLIENT_IP}${CLIENT_IP6:+,${CLIENT_IP6}}' "peer Address migrated"
assert_eq "7" "$(wc -l < "$TMPD/server.conf" | tr -d ' ')" "server line count unchanged"
assert_eq "7" "$(wc -l < "$TMPD/peer.conf" | tr -d ' ')" "peer line count unchanged"
assert_contains "$log" 'migrated PostUp' "migration logged"

# #36 DROP variant migrates the same way
drop_server "$TMPD/drop.conf"
log=$(ip6_migrate_templates "$TMPD/drop.conf" "$TMPD/peer.conf")
assert_contains "$(cat "$TMPD/drop.conf")" 'MASQUERADE${IP6_POSTUP:+; ${IP6_POSTUP}}' "DROP variant PostUp migrated"
assert_contains "$(cat "$TMPD/drop.conf")" 'MASQUERADE${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}' "DROP variant PostDown migrated"
assert_eq "0" "$(grep -c 'DROP' "$TMPD/drop.conf")" "DROP rules gone"
assert_contains "$log" 'migrated PostUp' "DROP migration logged"

# idempotent: second run changes nothing and logs nothing about migration
before=$(cat "$TMPD/server.conf" "$TMPD/peer.conf")
log=$(ip6_migrate_templates "$TMPD/server.conf" "$TMPD/peer.conf")
assert_eq "$before" "$(cat "$TMPD/server.conf" "$TMPD/peer.conf")" "second run is a no-op"
assert_eq "" "$log" "second run is silent"

# customised PostUp: warned, untouched, other lines still migrated
old_server "$TMPD/custom.conf"
sed -i.bak 's|^PostUp = .*|PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/my-hook.sh|' "$TMPD/custom.conf"
log=$(ip6_migrate_templates "$TMPD/custom.conf" "$TMPD/peer.conf")
assert_contains "$log" 'PostUp line is customised' "customised PostUp warned"
assert_contains "$(cat "$TMPD/custom.conf")" 'PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/my-hook.sh' "customised PostUp untouched"
assert_contains "$(cat "$TMPD/custom.conf")" '${SERVER_IP6:+' "Address still migrated in customised file"

# user already added the placeholder to a customised line: silent
printf 'PostUp = my-fw.sh${IP6_POSTUP:+; ${IP6_POSTUP}}\nAddress = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}\nPostDown = x${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}\n' > "$TMPD/marker.conf"
log=$(ip6_migrate_templates "$TMPD/marker.conf" "$TMPD/peer.conf")
assert_eq "" "$log" "marker present -> silent"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/ipv6-lib.test.sh 2>&1 | grep -c 'command not found'`
Expected: `>= 1`

- [ ] **Step 3: Append the implementation**

```bash
# ---- template migration ------------------------------------------------
# The exact lines shipped in root/defaults before IPv6 support, and their
# replacements. User templates are matched line-for-line; a customised line
# is left alone with a warning.
IP6_OLD_SERVER_ADDRESS='Address = ${INTERFACE}.1'
IP6_NEW_SERVER_ADDRESS='Address = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}'
# Two PostUp/PostDown generations exist in the wild: the original ACCEPT+MASQUERADE
# lines, and the DROP lines shipped by #36 (656d987). Both migrate to the placeholder.
IP6_OLD_POSTUP_ACCEPT='PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE'
IP6_OLD_POSTUP_DROP='PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP'
IP6_NEW_POSTUP='PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE${IP6_POSTUP:+; ${IP6_POSTUP}}'
IP6_OLD_POSTDOWN_ACCEPT='PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o eth+ -j MASQUERADE'
IP6_OLD_POSTDOWN_DROP='PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; ip6tables -D FORWARD -i %i -j DROP; ip6tables -D FORWARD -o %i -j DROP'
IP6_NEW_POSTDOWN='PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}'
IP6_OLD_PEER_ADDRESS='Address = ${CLIENT_IP}'
IP6_NEW_PEER_ADDRESS='Address = ${CLIENT_IP}${CLIENT_IP6:+,${CLIENT_IP6}}'

# <file> <new line> <marker> <label> <old line>...
ip6_migrate_line() {
    local file=$1 new=$2 marker=$3 label=$4 old line tmp
    shift 4
    [[ -f "${file}" ]] || return 0
    if grep -Fq -- "${marker}" "${file}"; then
        return 0
    fi
    for old in "$@"; do
        if grep -Fxq -- "${old}" "${file}"; then
            tmp=$(mktemp)
            while IFS= read -r line || [[ -n "${line}" ]]; do
                if [[ "${line}" == "${old}" ]]; then
                    printf '%s\n' "${new}"
                else
                    printf '%s\n' "${line}"
                fi
            done < "${file}" > "${tmp}"
            cat "${tmp}" > "${file}"
            rm -f "${tmp}"
            echo "**** ${file}: migrated ${label} line for IPv6 support ****"
            return 0
        fi
    done
    echo "**** ${file}: ${label} line is customised and has no ${marker} placeholder; IPv6 will not be applied to it. See README section \"IPv6\" ****"
    return 0
}

# <server template> <peer template>
ip6_migrate_templates() {
    local server=$1 peer=$2
    ip6_migrate_line "${server}" "${IP6_NEW_SERVER_ADDRESS}" '${SERVER_IP6'   'Address'  "${IP6_OLD_SERVER_ADDRESS}"
    ip6_migrate_line "${server}" "${IP6_NEW_POSTUP}"         '${IP6_POSTUP'   'PostUp'   "${IP6_OLD_POSTUP_ACCEPT}"   "${IP6_OLD_POSTUP_DROP}"
    ip6_migrate_line "${server}" "${IP6_NEW_POSTDOWN}"       '${IP6_POSTDOWN' 'PostDown' "${IP6_OLD_POSTDOWN_ACCEPT}" "${IP6_OLD_POSTDOWN_DROP}"
    ip6_migrate_line "${peer}"   "${IP6_NEW_PEER_ADDRESS}"   '${CLIENT_IP6'   'Address'  "${IP6_OLD_PEER_ADDRESS}"
}
```

Note the markers are `${SERVER_IP6`, `${IP6_POSTUP`, `${IP6_POSTDOWN`, `${CLIENT_IP6` (no closing brace) so both `${X}` and `${X:+…}` spellings count as "already migrated".

- [ ] **Step 4: Run tests, lint, commit**

```bash
bash tests/ipv6-lib.test.sh | tail -1        # PASS n / FAIL 0
shellcheck -s bash root/app/ipv6-lib.sh tests/ipv6-lib.test.sh
git add root/app/ipv6-lib.sh tests/ipv6-lib.test.sh
git commit -m "feat(ipv6): migrate both template generations to IPv6 placeholders, warn on customised lines

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD"
```

---

### Task 4: CoreDNS AAAA filter

**Files:**
- Modify: `root/app/ipv6-lib.sh` (append)
- Modify: `tests/ipv6-lib.test.sh` (append)
- Modify: `root/defaults/Corefile`

**Interfaces:**
- Produces: `ip6_write_coredns_filter <exit-effective> <coredns-dir>` — always (re)writes `<coredns-dir>/generated/ipv6.conf`: the AAAA template block when `<exit-effective>` is `off`, an empty file otherwise. If `<coredns-dir>/Corefile` exists and lacks the fixed string `import /config/coredns/generated/*.conf`, logs one hint. Exits 0.

- [ ] **Step 1: Append failing tests**

```bash
# ---- coredns filter ----------------------------------------------------
CD="$TMPD/coredns"; mkdir -p "$CD"
printf '. {\n    forward . /etc/resolv.conf\n}\n' > "$CD/Corefile"
log=$(ip6_write_coredns_filter off "$CD")
assert_contains "$(cat "$CD/generated/ipv6.conf")" 'template IN AAAA .' "off -> AAAA filter written"
assert_contains "$(cat "$CD/generated/ipv6.conf")" 'rcode NOERROR' "filter answers NOERROR"
assert_contains "$log" 'import /config/coredns/generated/*.conf' "custom Corefile gets a hint"

log=$(ip6_write_coredns_filter nat "$CD")
assert_eq "" "$(cat "$CD/generated/ipv6.conf")" "nat -> filter cleared"
assert_eq "0" "$(ip6_write_coredns_filter routed "$CD"; wc -c < "$CD/generated/ipv6.conf" | tr -d ' ')" "routed -> filter cleared"

printf '. {\n    import /config/coredns/generated/*.conf\n    forward . /etc/resolv.conf\n}\n' > "$CD/Corefile"
log=$(ip6_write_coredns_filter off "$CD")
assert_eq "" "$log" "Corefile with import -> no hint"

rm -rf "$CD"; mkdir -p "$CD"
log=$(ip6_write_coredns_filter off "$CD")
assert_contains "$(cat "$CD/generated/ipv6.conf")" 'template IN AAAA' "works before Corefile exists"
assert_eq "" "$log" "no Corefile -> no hint"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/ipv6-lib.test.sh 2>&1 | grep -c 'ip6_write_coredns_filter: command not found'`
Expected: `>= 1`

- [ ] **Step 3: Append the implementation**

```bash
# ---- coredns AAAA filter -----------------------------------------------
IP6_COREDNS_IMPORT='import /config/coredns/generated/*.conf'

# <exit-effective> <coredns dir>
ip6_write_coredns_filter() {
    local mode=$1 dir=$2
    mkdir -p "${dir}/generated"
    if [[ "${mode}" == "off" ]]; then
        cat <<'EOF' > "${dir}/generated/ipv6.conf"
# Generated by init-amneziawg-confs: IPv6 exit is off, so peers using this
# resolver get no AAAA records and never attempt IPv6. Do not edit; it is
# rewritten on every start.
template IN AAAA . {
    rcode NOERROR
}
EOF
    else
        : > "${dir}/generated/ipv6.conf"
    fi
    if [[ -f "${dir}/Corefile" ]] && ! grep -Fq -- "${IP6_COREDNS_IMPORT}" "${dir}/Corefile"; then
        echo "**** ${dir}/Corefile has no '${IP6_COREDNS_IMPORT}' line; AAAA filtering for peers is not active. Add that line inside the server block to enable it ****"
    fi
}
```

- [ ] **Step 4: Update the shipped Corefile**

Replace `root/defaults/Corefile` with:

```
. {
    loop
    errors
    health
    cache
    import /config/coredns/generated/*.conf
    forward . /etc/resolv.conf
}
```

- [ ] **Step 5: Run tests, lint, commit**

```bash
bash tests/ipv6-lib.test.sh | tail -1        # PASS n / FAIL 0
shellcheck -s bash root/app/ipv6-lib.sh tests/ipv6-lib.test.sh
git add root/app/ipv6-lib.sh tests/ipv6-lib.test.sh root/defaults/Corefile
git commit -m "feat(ipv6): suppress AAAA answers from CoreDNS when IPv6 exit is off

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD"
```

---

### Task 5: Wire the library into the run script and templates

**Files:**
- Modify: `root/defaults/server.conf:2,5,6`
- Modify: `root/defaults/peer.conf:2`
- Modify: `root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run` — see exact anchors below (line numbers are from `656d987`; re-grep if they drift)
- Modify: `Dockerfile` (only if `root/app` is not already copied — check first)

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: globals `SERVER_IP6`, `CLIENT_IP6` used by the templates; `ORIG_IP6_SUBNET`, `ORIG_IP6_EXIT` in `.donoteditthisfile`.

- [ ] **Step 1: Confirm `root/app` ships in the image**

Run: `grep -n 'COPY root' Dockerfile && ls root/app`
Expected: a `COPY root/ /` line and `show-peer` listed next to `ipv6-lib.sh`. If `COPY` is narrower, extend it — do not add a second COPY.

- [ ] **Step 2: Update the default templates**

`root/defaults/server.conf` lines 2, 5, 6 become exactly `IP6_NEW_SERVER_ADDRESS`, `IP6_NEW_POSTUP`, `IP6_NEW_POSTDOWN` from Task 3:

```
Address = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}
```
```
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE${IP6_POSTUP:+; ${IP6_POSTUP}}
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}
```

`root/defaults/peer.conf` line 2:
```
Address = ${CLIENT_IP}${CLIENT_IP6:+,${CLIENT_IP6}}
```

Guard against drift: the constants in the library and the shipped defaults must stay identical, so add this check to `tests/ipv6-lib.test.sh` (before the final echo):

```bash
# ---- shipped defaults match the migration targets -----------------------
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_SERVER_ADDRESS" "$HERE/../root/defaults/server.conf")" "defaults/server.conf Address == IP6_NEW_SERVER_ADDRESS"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_POSTUP" "$HERE/../root/defaults/server.conf")" "defaults/server.conf PostUp == IP6_NEW_POSTUP"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_POSTDOWN" "$HERE/../root/defaults/server.conf")" "defaults/server.conf PostDown == IP6_NEW_POSTDOWN"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_PEER_ADDRESS" "$HERE/../root/defaults/peer.conf")" "defaults/peer.conf Address == IP6_NEW_PEER_ADDRESS"
assert_eq "1" "$(grep -Fc -- "$IP6_COREDNS_IMPORT" "$HERE/../root/defaults/Corefile")" "defaults/Corefile has import"
```

Run `bash tests/ipv6-lib.test.sh | tail -1` → `FAIL 0`.

- [ ] **Step 3: Source the library and migrate templates**

In the run script, directly after the PresharedKey migration block (ends line 30, `fi`), add:

```bash
# IPv6 helpers (prefix derivation, exit mode, template migration, CoreDNS filter)
# shellcheck source=../../../../app/ipv6-lib.sh
source /app/ipv6-lib.sh
# move IPv6 address/firewall placeholders into user templates (backwards compatibility)
ip6_migrate_templates /config/templates/server.conf /config/templates/peer.conf
```

- [ ] **Step 4: Resolve prefix and exit mode in the server-mode main logic**

After the `ALLOWEDIPS` echo (line ~701, `echo "**** AllowedIPs for peers $ALLOWEDIPS ****"`) add:

```bash
    # IPv6: derive/validate the tunnel prefix, then decide what the server
    # does with peers' IPv6 traffic. Sets IP6_PREFIX, IP6_SUBNET_EFFECTIVE,
    # IP6_EXIT_EFFECTIVE, IP6_POSTUP, IP6_POSTDOWN.
    ip6_resolve_subnet
    ip6_resolve_exit
    SERVER_IP6=""
    if [[ -n "${IP6_PREFIX}" ]]; then
        SERVER_IP6=$(ip6_server_addr "${IP6_PREFIX}")
    fi
```

- [ ] **Step 5: Compute the peer address and server AllowedIPs in `generate_confs`**

Line 550 (`CLIENT_IP=$(grep "Address" ... | awk '{print $NF}')`) becomes:

```bash
                CLIENT_IP=$(grep "Address" "/config/${PEER_ID}/${PEER_ID}.conf" | awk '{print $NF}' | cut -d, -f1)
```

Immediately before `if [[ -f "/config/${PEER_ID}/presharedkey-${PEER_ID}" ]]; then` (line ~563, after the `for idx` loop's closing `fi`) add:

```bash
            # IPv6 address is always recomputed from the IPv4 one, never read
            # back, so a prefix change is applied on regeneration.
            CLIENT_IP6=""
            if [[ -n "${IP6_PREFIX}" ]]; then
                CLIENT_IP6=$(ip6_peer_addr "${IP6_PREFIX}" "${CLIENT_IP}")
            fi
```

The two server `AllowedIPs` heredocs (lines ~607 and ~611) become:

```bash
AllowedIPs = ${CLIENT_IP}/32${CLIENT_IP6:+,${CLIENT_IP6}},${!SERVER_ALLOWEDIPS}
```
and
```bash
AllowedIPs = ${CLIENT_IP}/32${CLIENT_IP6:+,${CLIENT_IP6}}
```

- [ ] **Step 6: Persist and detect changes**

In `save_vars()` after `ORIG_PERSISTENTKEEPALIVE_PEERS="$PERSISTENTKEEPALIVE_PEERS"` add:

```bash
ORIG_IP6_SUBNET="$IP6_SUBNET_EFFECTIVE"
ORIG_IP6_EXIT="$IP6_EXIT_EFFECTIVE"
```

In the regeneration `if`, after the `PERSISTENTKEEPALIVE_PEERS` comparison line add:

```bash
           [[ "$IP6_SUBNET_EFFECTIVE" != "$ORIG_IP6_SUBNET" ]] || \
           [[ "$IP6_EXIT_EFFECTIVE" != "$ORIG_IP6_EXIT" ]] || \
```

- [ ] **Step 7: Write the CoreDNS filter**

Replace the `# set up CoreDNS` block (lines ~770-772) with:

```bash
# set up CoreDNS
if [[ ! -f /config/coredns/Corefile ]]; then
    mkdir -p /config/coredns
    cp /defaults/Corefile /config/coredns/Corefile
fi
# AAAA filter for peers: active only when IPv6 exit is off. In client mode
# IP6_EXIT_EFFECTIVE is unset; treat that as "no filter".
ip6_write_coredns_filter "${IP6_EXIT_EFFECTIVE:-nat}" /config/coredns
```

- [ ] **Step 8: Static checks**

```bash
bash -n root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run
shellcheck -s bash -x root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run
bash tests/ipv6-lib.test.sh | tail -1
```
Expected: no syntax error; shellcheck clean apart from the pre-existing disables in the header; `FAIL 0`.

- [ ] **Step 9: Local template-expansion check (no Docker needed)**

Run this from the repo root to prove the heredoc expansion produces valid lines in all three exit states:

```bash
bash -c '
source root/app/ipv6-lib.sh
INTERFACE=10.13.13; AWG_JC=4; AWG_JMIN=40; AWG_JMAX=70; AWG_S1=0; AWG_S2=0; AWG_S3=0; AWG_S4=0; AWG_H1=5; AWG_H2=6; AWG_H3=7; AWG_H4=8
for exit in off nat; do
  IP6_EXIT=$exit; ip6_resolve_subnet >/dev/null; ip6_resolve_exit >/dev/null
  SERVER_IP6=$(ip6_server_addr "$IP6_PREFIX")
  eval "$(printf %s)
cat <<DUDE
$(sed "s|\$(cat /config/server/privatekey-server)|KEY|" root/defaults/server.conf)
DUDE" | sed -n "2p;5p;6p"
  echo ---
done
IP6_SUBNET=off; ip6_resolve_subnet >/dev/null; ip6_resolve_exit >/dev/null; SERVER_IP6=""
eval "$(printf %s)
cat <<DUDE
$(sed "s|\$(cat /config/server/privatekey-server)|KEY|" root/defaults/server.conf)
DUDE" | sed -n "2p;5p;6p"
'
```
Expected:
- block 1 (`off`): `Address = 10.13.13.1,fd0a:0d0d:0000::1/128`; PostUp ends with `; ip6tables -A FORWARD -i %i -j REJECT --reject-with icmp6-adm-prohibited; ip6tables -A FORWARD -o %i -j REJECT --reject-with icmp6-adm-prohibited`; PostDown same with `-D`.
- block 2 (`nat`): PostUp ends with `; ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE`.
- block 3 (`IP6_SUBNET=off`): `Address = 10.13.13.1`, PostUp/PostDown end at `MASQUERADE` with **no** `ip6tables` at all — identical to the pre-feature template output.

- [ ] **Step 10: Commit**

```bash
git add root/defaults/server.conf root/defaults/peer.conf root/etc/s6-overlay/s6-rc.d/init-amneziawg-confs/run tests/ipv6-lib.test.sh
git commit -m "feat(ipv6): assign ULA addresses to peers and drive ip6tables from the resolved exit mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD"
```

---

### Task 6: CI — unit tests and container smoke scenarios

**Files:**
- Modify: `.github/workflows/docker-build.yml` — new step before `Build and push` (line ~107); new scenarios inside `Test image (PR only)` before `echo "All smoke tests passed!"` (line ~257).

**Interfaces:**
- Consumes: log strings and file names from Tasks 1–5 exactly as written there.

- [ ] **Step 1: Add the unit-test step**

Insert before the `Build and push` step:

```yaml
      - name: Unit tests (ipv6-lib)
        run: bash tests/ipv6-lib.test.sh
```

- [ ] **Step 2: Add the smoke scenarios**

Insert before `echo "All smoke tests passed!" >> "$GITHUB_STEP_SUMMARY"`:

```bash
          # ---------------------------------------------------------------
          # IPv6: addressing, exit-mode resolution, migration, CoreDNS filter.
          # GitHub runners have no IPv6 route, so auto must resolve to "off".
          echo "### IPv6 config generation" >> "$GITHUB_STEP_SUMMARY"
          start_awgci() {  # <extra docker run args...>
            docker rm -f awgci >/dev/null 2>&1 || true
            docker run -d --name awgci --cap-add NET_ADMIN \
              -e PEERS=2 -e SERVERURL=ci.example.com -e INTERNAL_SUBNET=10.13.13.0 \
              "$@" test-image >/dev/null
            for _ in $(seq 1 45); do
              docker exec awgci test -f /config/peer2/peer2.png 2>/dev/null && break
              sleep 2
            done
            docker exec awgci test -f /config/peer2/peer2.png \
              || { echo "IPv6: peer confs were never generated"; docker logs awgci; exit 1; }
          }
          fail() { echo "IPv6: $1"; docker logs awgci; docker exec awgci cat /config/wg_confs/wg0.conf /config/peer1/peer1.conf; exit 1; }

          # 1. defaults
          start_awgci
          docker exec awgci grep -q '^Address = 10.13.13.2,fd0a:0d0d:0000::2/128$' /config/peer1/peer1.conf || fail "peer1 lacks derived ULA address"
          docker exec awgci grep -q '^Address = 10.13.13.3,fd0a:0d0d:0000::3/128$' /config/peer2/peer2.conf || fail "peer2 lacks derived ULA address"
          docker exec awgci grep -q '^Address = 10.13.13.1,fd0a:0d0d:0000::1/128$' /config/wg_confs/wg0.conf || fail "server lacks ULA address"
          docker exec awgci grep -q '^AllowedIPs = 10.13.13.2/32,fd0a:0d0d:0000::2/128$' /config/wg_confs/wg0.conf || fail "server AllowedIPs lacks /128"
          docker exec awgci grep -q 'icmp6-adm-prohibited' /config/wg_confs/wg0.conf || fail "PostUp lacks REJECT on a no-IPv6 runner"
          docker exec awgci grep -q 'MASQUERADE; ip6tables' /config/wg_confs/wg0.conf || fail "ip6tables rules not appended after v4 MASQUERADE"
          docker exec awgci grep -q 'template IN AAAA' /config/coredns/generated/ipv6.conf || fail "AAAA filter not written"
          docker exec awgci grep -q 'import /config/coredns/generated' /config/coredns/Corefile || fail "Corefile lacks import"
          docker logs awgci 2>&1 | grep -q 'IPv6 exit: off (no IPv6 default route' || fail "auto did not log the off reason"
          docker exec awgci grep -q '^ORIG_IP6_SUBNET="fd0a:0d0d:0000::/64"$' /config/.donoteditthisfile || fail "IP6_SUBNET not persisted"
          docker exec awgci grep -q '^ORIG_IP6_EXIT="off"$' /config/.donoteditthisfile || fail "IP6_EXIT not persisted"
          echo "  defaults: ULA addresses, REJECT rules, AAAA filter"

          # 2. IP6_SUBNET=off -> byte-identical to the old behaviour
          start_awgci -e IP6_SUBNET=off
          docker exec awgci grep -q '^Address = 10.13.13.2$' /config/peer1/peer1.conf || fail "off: peer address not v4-only"
          docker exec awgci grep -q '^Address = 10.13.13.1$' /config/wg_confs/wg0.conf || fail "off: server address not v4-only"
          if docker exec awgci grep -q 'ip6tables' /config/wg_confs/wg0.conf; then fail "off: ip6tables rules present"; fi
          docker exec awgci grep -q 'MASQUERADE$' /config/wg_confs/wg0.conf || fail "off: PostUp does not end at v4 MASQUERADE"
          docker exec awgci grep -q 'template IN AAAA' /config/coredns/generated/ipv6.conf || fail "off: AAAA filter should still be active"
          echo "  IP6_SUBNET=off: identical to pre-IPv6 output"

          # 3. user prefix
          start_awgci -e IP6_SUBNET=fd12:3456:789a::/64
          docker exec awgci grep -q '^Address = 10.13.13.2,fd12:3456:789a::2/128$' /config/peer1/peer1.conf || fail "user prefix not applied"
          echo "  IP6_SUBNET=<prefix>: applied"

          # 4. invalid prefix -> warn + derived
          start_awgci -e IP6_SUBNET=bogus
          docker logs awgci 2>&1 | grep -q 'IP6_SUBNET "bogus" is invalid' || fail "invalid prefix not warned"
          docker exec awgci grep -q 'fd0a:0d0d:0000::2/128' /config/peer1/peer1.conf || fail "invalid prefix did not fall back"
          echo "  invalid IP6_SUBNET: warned, derived prefix used"

          # 5. forced routed -> ACCEPT only, no NAT, no REJECT
          start_awgci -e IP6_EXIT=routed
          docker exec awgci grep -q 'ip6tables -A FORWARD -i %i -j ACCEPT' /config/wg_confs/wg0.conf || fail "routed: no ACCEPT"
          if docker exec awgci grep -qE 'ip6tables -t nat|icmp6-adm-prohibited' /config/wg_confs/wg0.conf; then fail "routed: NAT or REJECT present"; fi
          docker exec awgci test ! -s /config/coredns/generated/ipv6.conf || fail "routed: AAAA filter should be empty"
          echo "  IP6_EXIT=routed: ACCEPT only"

          # 6. old user templates are migrated
          docker rm -f awgci >/dev/null 2>&1 || true
          docker volume rm -f awgci-cfg >/dev/null 2>&1 || true
          docker run --rm -v awgci-cfg:/config test-image sh -c '
            mkdir -p /config/templates
            printf "%s\n" "[Interface]" "Address = \${INTERFACE}.1" "ListenPort = 51820" "PrivateKey = \$(cat /config/server/privatekey-server)" \
              "PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE" \
              "PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o eth+ -j MASQUERADE" \
              "Jc = \${AWG_JC}" "Jmin = \${AWG_JMIN}" "Jmax = \${AWG_JMAX}" "S1 = \${AWG_S1}" "S2 = \${AWG_S2}" "S3 = \${AWG_S3}" "S4 = \${AWG_S4}" "H1 = \${AWG_H1}" "H2 = \${AWG_H2}" "H3 = \${AWG_H3}" "H4 = \${AWG_H4}" > /config/templates/server.conf
            printf "%s\n" "[Interface]" "Address = \${CLIENT_IP}" "PrivateKey = \$(cat /config/\${PEER_ID}/privatekey-\${PEER_ID})" "DNS = \${PEERDNS}" "" "[Peer]" "PublicKey = \$(cat /config/server/publickey-server)" "PresharedKey = \$(cat /config/\${PEER_ID}/presharedkey-\${PEER_ID})" "Endpoint = \${SERVERURL}:\${SERVERPORT}" "AllowedIPs = \${ALLOWEDIPS}" > /config/templates/peer.conf
          '
          start_awgci -v awgci-cfg:/config
          docker logs awgci 2>&1 | grep -q 'migrated PostUp line' || fail "migration: PostUp not migrated"
          docker exec awgci grep -q 'fd0a:0d0d:0000::2/128' /config/peer1/peer1.conf || fail "migration: peer address missing after migration"
          docker exec awgci grep -q 'icmp6-adm-prohibited' /config/wg_confs/wg0.conf || fail "migration: REJECT missing after migration"
          if docker exec awgci grep -q 'ip6tables -A FORWARD -i %i -j ACCEPT' /config/wg_confs/wg0.conf; then fail "migration: old ACCEPT rules survived"; fi
          echo "  old templates: migrated"

          # 6b. #36 DROP templates (what master ships between 656d987 and this PR) migrate too
          docker rm -f awgci >/dev/null 2>&1 || true
          docker run --rm -v awgci-cfg:/config test-image sh -c '
            sed -i "s|^PostUp = .*|PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP|" /config/templates/server.conf
            sed -i "s|^PostDown = .*|PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; ip6tables -D FORWARD -i %i -j DROP; ip6tables -D FORWARD -o %i -j DROP|" /config/templates/server.conf
          '
          start_awgci -v awgci-cfg:/config
          docker logs awgci 2>&1 | grep -q 'migrated PostUp line' || fail "DROP migration: PostUp not migrated"
          if docker exec awgci grep -q -- '-j DROP' /config/wg_confs/wg0.conf; then fail "DROP migration: DROP rules survived"; fi
          docker exec awgci grep -q 'icmp6-adm-prohibited' /config/wg_confs/wg0.conf || fail "DROP migration: REJECT missing"
          echo "  #36 DROP templates: migrated"

          # 7. customised PostUp is warned about, not fatal
          docker rm -f awgci >/dev/null 2>&1 || true
          docker run --rm -v awgci-cfg:/config test-image sh -c 'sed -i "s|^PostUp = .*|PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/hook.sh|" /config/templates/server.conf'
          start_awgci -v awgci-cfg:/config
          docker logs awgci 2>&1 | grep -q 'PostUp line is customised' || fail "customised PostUp not warned"
          docker exec awgci grep -q '^PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/hook.sh$' /config/wg_confs/wg0.conf || fail "customised PostUp altered"
          echo "  customised template: warned, untouched"

          docker rm -f awgci >/dev/null 2>&1 || true
          docker volume rm -f awgci-cfg >/dev/null 2>&1 || true
          echo "- IPv6 config generation correct" >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 3: Validate YAML and push for CI**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/docker-build.yml'))" && echo YAML-OK
git add .github/workflows/docker-build.yml
git commit -m "ci: unit-test ipv6-lib and smoke-test IPv6 config generation scenarios

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD"
git push -u origin feature/ipv6-support
gh pr create --draft --title "feat: IPv6 support (ULA by default, NAT66 egress, leak-proof)" --body "Implements docs/superpowers/specs/2026-08-26-ipv6-support-design.md. Supersedes #36.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD"
```

- [ ] **Step 4: Watch CI**

Run: `gh pr checks --watch`
Expected: `build` passes. If a scenario fails, the `fail` helper dumps logs and both confs into the job log; fix the product (not the test) unless the test's expectation contradicts the spec.

---

### Task 7: Documentation, compose example, deploy skill

**Files:**
- Modify: `README.md` (env table row after `ALLOWEDIPS` ~line 142; new `## IPv6` section after the AWG 3.1 section; troubleshooting entry)
- Modify: `docker-compose.yml` (env comments ~line 38; `sysctls:` block ~line 91; new `networks:` block at end of the first service example)
- Modify: `CHANGELOG.md` (top entry)
- Modify: `CLAUDE.md` ("Adding a new environment variable" and "Common Gotchas")
- Modify: `.claude/skills/deploy-amneziawg/references/compose-template.md`, `.claude/skills/deploy-amneziawg/references/requirements.md`, `.claude/skills/deploy-amneziawg/references/troubleshooting.md`, `.claude/skills/deploy-amneziawg/SKILL.md`
- Modify: `.claude/skills/docker-amneziawg/SKILL.md` (mention `root/app/ipv6-lib.sh` and `tests/ipv6-lib.test.sh`)

- [ ] **Step 1: README env table rows**

Replace the `ALLOWEDIPS` row (rewritten by #36; it says the tunnel is IPv4-only and that `::/0` "sinks" IPv6, which stops being true here) with:

```markdown
| `-e ALLOWEDIPS=0.0.0.0/0, ::/0` | Traffic peers route into the tunnel. Keep `::/0`: peers now have an IPv6 address, so all IPv6 enters the tunnel and is either forwarded (IPv6 egress enabled) or rejected at the server — never leaked. Narrow to specific subnets for split tunnelling |
```

After it add:

```markdown
| `-e IP6_SUBNET=` | IPv6 tunnel prefix, `<prefix>::/64`. Default: ULA derived from `INTERNAL_SUBNET` (`10.13.13.0` → `fd0a:0d0d:0000::/64`). `off` disables IPv6 entirely |
| `-e IP6_EXIT=auto` | What the server does with peers' IPv6 traffic: `auto` (NAT when the container has IPv6, otherwise reject), `nat`, `routed`, `off` |
```

- [ ] **Step 2: README `## IPv6` section**

```markdown
## IPv6

Every peer gets an IPv6 address inside the tunnel by default (a ULA derived from
`INTERNAL_SUBNET`), so dual-stack clients route **all** their IPv6 into the
tunnel instead of leaking it around the VPN. What happens to that traffic at
the server depends on whether the container itself has IPv6:

| container has IPv6 route | `IP6_EXIT=auto` resolves to | peers experience |
|---|---|---|
| no (default Docker network) | `off` — traffic is rejected with ICMPv6, and the built-in DNS returns no AAAA records | IPv4-only, no leak, no hangs |
| yes | `nat` — masqueraded out of the container like IPv4 | full IPv6 |

### Enable IPv6 egress

Three lines in `docker-compose.yml`; nothing on the Docker daemon, nothing on
other containers (Docker ≥ 27 allocates a ULA and does NAT66 itself):

```yaml
services:
  amneziawg:
    sysctls:
      - net.ipv6.conf.all.forwarding=1   # add to the existing block
networks:
  default:
    enable_ipv6: true
```

Then `docker compose up -d` and check the log for `IPv6 exit: nat`. Peer confs
are unchanged by this; only the server's firewall rules are.

### Options

- `IP6_SUBNET=fd12:3456:789a::/64` — pick your own prefix. A global (non-`fd`)
  prefix makes `auto` choose `routed` (no NAT): use it only when that `/64` is
  actually routed to the host.
- `IP6_SUBNET=off` — no IPv6 addresses, no `ip6tables` rules, output identical
  to earlier releases. Use this if a client cannot parse an IPv6 `Address`.
- `IP6_EXIT=nat|routed|off` — override auto-detection. Forcing `nat` on a host
  without an IPv6 route or without the `ip6table_nat` kernel module makes
  `PostUp` fail and the tunnel will not come up; the error is in the log.

The outer endpoint (the UDP port clients connect to) stays IPv4. Docker
publishes it on `[::]` too, so a hostname with an AAAA record also works, but
`SERVERURL=auto` always picks the IPv4 address.

### Upgrading

Templates in `/config/templates/` are migrated automatically (the old
hard-coded `ip6tables` rules are replaced by `${IP6_POSTUP}` placeholders). If
you customised `PostUp`/`PostDown`/`Address`, the log says which line was left
alone; add the placeholder shown in `root/defaults/server.conf` yourself. A
custom `/config/coredns/Corefile` needs
`import /config/coredns/generated/*.conf` inside the server block for AAAA
filtering; the log reminds you.
```

- [ ] **Step 3: README troubleshooting entry**

In the troubleshooting section add:

```markdown
- **`ip6tables: ... No chain/target/match by that name` in the log and the tunnel does not start** — the host lacks an IPv6 netfilter module (`ip6table_nat` or `ip6table_filter`). With `IP6_EXIT=auto` this only happens when you forced a mode; otherwise set `IP6_SUBNET=off`.
- **IPv6 sites hang on peers** — the peer is not using the container's DNS (`PEERDNS` set to a public resolver) and the exit is `off`. Either enable IPv6 egress or set `PEERDNS=auto`.
```

- [ ] **Step 4: docker-compose.yml**

Next to the `ALLOWEDIPS` comment add:

```yaml
      # ---- IPv6 ----
      # Peers always get a ULA IPv6 address (derived from INTERNAL_SUBNET) so dual-stack
      # clients cannot leak IPv6 around the tunnel. Egress needs the two IPv6 lines below.
      # - IP6_SUBNET=fd12:3456:789a::/64   # Own prefix; "off" disables IPv6 entirely
      # - IP6_EXIT=auto                    # auto | nat | routed | off
```

In `sysctls:` add `- net.ipv6.conf.all.forwarding=1` with the comment `# IPv6 egress (with enable_ipv6 below)`, and after the service add:

```yaml
networks:
  default:
    enable_ipv6: true   # Docker >= 27 allocates a ULA and does NAT66; remove to keep IPv6 off
```

- [ ] **Step 5: CHANGELOG, CLAUDE.md, skills**

CHANGELOG top entry:

```markdown
## Unreleased

### Added
- IPv6 inside the tunnel: peers get a ULA address by default (derived from `INTERNAL_SUBNET`), closing the dual-stack leak. `IP6_SUBNET` sets or disables (`off`) the prefix; `IP6_EXIT` (`auto|nat|routed|off`) controls egress. With `enable_ipv6: true` on the Docker network, IPv6 is masqueraded like IPv4; without it, IPv6 is rejected fast and CoreDNS returns no AAAA records.
- `root/app/ipv6-lib.sh` with unit tests (`tests/ipv6-lib.test.sh`, run in CI).

### Changed
- Firewall rules in `server.conf` templates are now `${IP6_POSTUP}`/`${IP6_POSTDOWN}` placeholders; user templates are migrated automatically, customised lines are warned about.
- `Corefile` gains `import /config/coredns/generated/*.conf`.
```

CLAUDE.md — in "Adding a new environment variable" add step: `6. IPv6-related: logic goes in root/app/ipv6-lib.sh with a case in tests/ipv6-lib.test.sh, not in the run script`. In "Common Gotchas" add:

```markdown
- Firewall policy never goes into `root/defaults/*.conf` literally — templates are user-owned copies, so every literal change needs another migration. Put policy in `ip6_resolve_exit()` and expand `${IP6_POSTUP}`/`${IP6_POSTDOWN}`.
- `IP6_SUBNET=off` is the only way to disable IPv6 (s6 drops empty vars). `off` must keep producing byte-identical pre-IPv6 output — CI checks it.
- `ip6_resolve_exit()` probes the *container's* netns; runtime `sysctl -w` is denied, so `net.ipv6.conf.all.forwarding=1` must come from compose `sysctls:`.
```

Deploy skill:
- `compose-template.md`: add the `forwarding` sysctl and `networks.default.enable_ipv6: true` to the template with the same comments as Step 4.
- `requirements.md`: after the IPv4 route check add
  ```bash
  ip -6 route get 2001:4860:4860::8888 &>/dev/null && ok "Host has IPv6 egress — peers can get IPv6 via NAT66" || warn "No IPv6 egress on host — peers will be IPv4-only (no leak either way)"
  docker version --format '{{.Server.Version}}' 2>/dev/null | awk -F. '{exit ($1>=27)?0:1}' && ok "Docker >= 27: enable_ipv6 does NAT66 natively" || warn "Docker < 27: set \"ip6tables\": true in daemon.json before enabling IPv6 on the network"
  ```
- `troubleshooting.md`: copy the two README troubleshooting bullets.
- `SKILL.md`: in the settings-gathering step, mention that IPv6 egress is on by default in the generated compose when the host has IPv6, and how to opt out (`IP6_SUBNET=off`).
- `.claude/skills/docker-amneziawg/SKILL.md`: add `root/app/ipv6-lib.sh` / `tests/ipv6-lib.test.sh` to the file map and `bash tests/ipv6-lib.test.sh` to the test commands.

- [ ] **Step 6: Commit**

```bash
git add README.md docker-compose.yml CHANGELOG.md CLAUDE.md .claude/skills
git commit -m "docs: document IPv6 support, compose example and deploy-skill checks

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01P2tF5XWZge3gugw6xP8tbD"
git push
```

---

### Task 8: Real-world verification on webdock (amneziawg-31 stack only)

**Files:** none in the repo. Touches only `~/amneziawg-31/` on the VPS. The `amneziawg` (2.0) container must not be restarted.

- [ ] **Step 1: Build the image on the VPS**

```bash
rsync -a --delete --exclude .git ./ webdock:~/docker-amneziawg-ipv6/
ssh webdock 'cd ~/docker-amneziawg-ipv6 && docker build -t amneziawg-ipv6:test . 2>&1 | tail -3'
```
Expected: `naming to docker.io/library/amneziawg-ipv6:test`.

- [ ] **Step 2: Phase A — no Docker IPv6 (exit must resolve to off)**

```bash
ssh webdock 'cd ~/amneziawg-31 && cp docker-compose.yml docker-compose.yml.pre-ipv6 && sed -i "s|image: .*|image: amneziawg-ipv6:test|" docker-compose.yml && docker compose up -d && sleep 20 && docker logs amneziawg-31 2>&1 | grep -E "IPv6|migrated|customised"'
ssh webdock 'docker exec amneziawg-31 ip6tables -S FORWARD; docker exec amneziawg-31 cat /config/peer1/peer1.conf | grep Address; docker exec amneziawg-31 dig +short AAAA google.com @127.0.0.1; docker ps --format "{{.Names}} {{.Status}}" | grep amneziawg'
```
Expected: log shows `IPv6 tunnel prefix is fd0a:0d0e:0000::/64` (subnet is `10.13.14.0`), `migrated Address/PostUp/PostDown line`, `IPv6 exit: off (no IPv6 default route`; `ip6tables -S FORWARD` shows the two `REJECT` rules; peer1 `Address = 10.13.14.2,fd0a:0d0e:0000::2/128`; `dig AAAA` prints nothing; `amneziawg` container's status still shows its old uptime. Note the templates on this stack carry the hand-added `RandomTrailers`/`DisableCookies` lines from the earlier 3.1 deployment — they are unrelated to the migrated lines and must survive.

From a phone/laptop with the peer1 conf (re-import it — the address changed): `curl -6 -m 5 https://ifconfig.co` must fail immediately with "Network unreachable"/"Connection refused"-class error, not a timeout; `curl -4 https://ifconfig.co` returns the VPS IPv4.

- [ ] **Step 3: Phase B — enable Docker IPv6**

```bash
ssh webdock 'cd ~/amneziawg-31 && python3 - <<EOF
import re,io
p="docker-compose.yml"; s=open(p).read()
if "net.ipv6.conf.all.forwarding=1" not in s:
    s=s.replace("      - net.ipv6.conf.all.disable_ipv6=0","      - net.ipv6.conf.all.disable_ipv6=0\n      - net.ipv6.conf.all.forwarding=1")
if "enable_ipv6" not in s:
    s+="\nnetworks:\n  default:\n    enable_ipv6: true\n"
open(p,"w").write(s)
EOF
docker compose up -d 2>&1 | tail -2 && sleep 20 && docker logs amneziawg-31 2>&1 | grep -E "IPv6 exit|regenerating"'
ssh webdock 'docker exec amneziawg-31 sh -c "ip -6 route show default; ip6tables -S FORWARD; ip6tables -t nat -S POSTROUTING; dig +short AAAA google.com @127.0.0.1 | head -1; curl -6 -s -m 5 https://ifconfig.co"'
```
Expected: compose recreates the network with IPv6 (`amneziawg-31_default` gets a `fd..::/64`), log shows `IPv6 exit: nat` and `Server related environment variables changed, regenerating`; `ip6tables -S FORWARD` shows two `ACCEPT`, nat shows `MASQUERADE`; `dig AAAA` returns an address; `curl -6` from inside the container prints `2a0f:f01:210:f1::` (the host's IPv6).

From the peer: `curl -6 https://ifconfig.co` returns `2a0f:f01:210:f1::`; https://browserleaks.com/ip shows the VPS for both families.

- [ ] **Step 4: Record and restore**

Paste both phases' outputs into the PR description under "Verified on a real host". Leave the stack on Phase B (it is the intended end state) but restore the published image tag once the PR is merged and the image is built:

```bash
ssh webdock 'cd ~/amneziawg-31 && sed -i "s|image: amneziawg-ipv6:test|image: ghcr.io/ayastrebov/docker-amneziawg:latest|" docker-compose.yml'
```
(do not `up -d` until the new image is on ghcr).

---

### Task 9: Follow up on #36 and mark the PR ready

**Files:** none.

- [ ] **Step 1: Draft the #36 follow-up comment — do not post without the user's go-ahead**

#36 is merged (`656d987`). Its DROP template is migrated by this PR, so the only thing owed is a heads-up to the author. Write to the scratchpad:

```
Follow-up: #<new PR> builds on this. Peers now always get an IPv6 address inside the tunnel (that is what makes dual-stack clients actually install the ::/0 route), and the server rejects IPv6 with ICMPv6 when it has no IPv6 route — your DROP template is migrated to that automatically — or NATs it when the Docker network has enable_ipv6: true. If you can try the new image on your host-network setup, that would be a useful data point.
```

- [ ] **Step 2: Mark the PR ready**

```bash
gh pr ready
gh pr view --web
```

Then ask the user whether to post the #36 follow-up.

---

## Self-review

**Spec coverage:** §4.1 addressing → Tasks 1, 5. §4.2 exit → Tasks 2, 5. §4.3 templates/migration (both PostUp generations) → Tasks 3, 5. §4.4 CoreDNS → Tasks 4, 5. §4.5 persistence → Task 5 step 6. §4.6 compose/deploy skill → Task 7. §4.7 PR #36 → Task 9 (the `curl -4` half is already on master). §5 failure modes: invalid prefix (T1), customised template (T3), forced nat fails loudly (documented T7), `IP6_SUBNET=off` no rules (T2 test "no prefix beats forced nat", T6 scenario 2), custom Corefile hint (T4). §6 testing: spec scenarios 1–7 → Task 6 (spec 7 `routed` = CI 5; spec 5 & 6 = CI 6, 6b & 7); VPS → Task 8. §7 docs → Task 7.

**Placeholder scan:** none; every code step has full content. Task 9's `<new PR>` is known only at execution time and is marked as such.

**Type/name consistency:** `IP6_PREFIX`, `IP6_SUBNET_EFFECTIVE`, `IP6_EXIT_EFFECTIVE`, `IP6_POSTUP`, `IP6_POSTDOWN`, `SERVER_IP6`, `CLIENT_IP6`, `ip6_resolve_subnet`, `ip6_resolve_exit`, `ip6_server_addr`, `ip6_peer_addr`, `ip6_migrate_line` (new-line-first signature), `ip6_migrate_templates`, `ip6_write_coredns_filter`, `IP6_COREDNS_IMPORT`, `IP6_OLD_POSTUP_ACCEPT`/`_DROP`, `IP6_OLD_POSTDOWN_ACCEPT`/`_DROP` are spelled identically in Tasks 1–6. CI scenario 1 uses `INTERNAL_SUBNET=10.13.13.0` so the derived prefix `fd0a:0d0d:0000::` matches the unit tests; Task 8 uses the VPS's `10.13.14.0` → `fd0a:0d0e:0000::`.
