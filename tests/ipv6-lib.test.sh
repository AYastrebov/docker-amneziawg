#!/usr/bin/env bash
# shellcheck disable=SC2034  # IP6_SUBNET/IP6_EXIT/INTERFACE are read by the library under test
# Unit tests for root/app/ipv6-lib.sh. Runs on any machine with bash >= 4.
# Usage: bash tests/ipv6-lib.test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
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
assert_eq "fdc0:a808:0000::" "$(ip6_derive_prefix 192.168.08)" "leading-zero octet is decimal, not octal"

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
