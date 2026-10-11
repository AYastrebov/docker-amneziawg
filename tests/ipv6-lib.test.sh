#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016  # IP6_SUBNET/IP6_EXIT/INTERFACE are read by the library under test; SC2016: single quotes are intentional for literal pattern matching
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
# only fc00::/7 and 2000::/3: anything else cannot be a unicast interface address
assert_eq "fc00:1::" "$(ip6_validate_subnet 'fc00:1::/64')" "fc00::/7 low half accepted"
assert_eq "3fff:1::" "$(ip6_validate_subnet '3fff:1::/64')" "2000::/3 top accepted"
assert_eq "2a01:4f8:1::" "$(ip6_validate_subnet '2a01:4f8:1::/64')" "short first hextet GUA accepted"
assert_fail "link-local fe80::/64" ip6_validate_subnet 'fe80::/64'
assert_fail "multicast ff00::/64" ip6_validate_subnet 'ff00::/64'
assert_fail "unspecified ::/64 (no hextet)" ip6_validate_subnet '::/64'
assert_fail "fd::/64 is 00fd, not ULA" ip6_validate_subnet 'fd::/64'
assert_fail "2::/64 is 0002, not GUA" ip6_validate_subnet '2::/64'
assert_fail "4000::/64 outside 2000::/3" ip6_validate_subnet '4000::/64'

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

# ---- Address read-back --------------------------------------------------
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
conf_addr() { printf '[Interface]\n%s\nDNS = 10.13.13.1\n' "$1" > "$TMPD/a.conf"; ip6_conf_ipv4 "$TMPD/a.conf"; }
assert_eq "10.13.13.2" "$(conf_addr 'Address = 10.13.13.2')" "read-back: v4 only"
assert_eq "10.13.13.2" "$(conf_addr 'Address = 10.13.13.2,fd0a:0d0d:0000::2/128')" "read-back: dual, no space"
assert_eq "10.13.13.2" "$(conf_addr 'Address = 10.13.13.2, fd0a:0d0d:0000::2/128')" "read-back: dual, space after comma"
assert_eq "10.13.13.2" "$(conf_addr 'Address = fd0a:0d0d:0000::2/128, 10.13.13.2')" "read-back: v6 first"
assert_eq "10.13.13.2" "$(conf_addr 'Address=10.13.13.2/32')" "read-back: mask stripped, no spaces"
assert_eq "" "$(conf_addr 'Address = fd0a:0d0d:0000::2/128')" "read-back: v6 only -> empty"
assert_eq "10.13.13.2" "$(conf_addr 'Address = 10.13.13.2/32 # laptop')" "read-back: inline comment stripped like awg-quick"
assert_eq "10.13.13.2" "$(conf_addr 'Address = 10.13.13.2, fd0a:0d0d:0000::2/128 #dual')" "read-back: dual with comment"
assert_eq "" "$(conf_addr '# Address = 10.13.13.9')" "read-back: commented-out line ignored"

# ---- probe overrides ---------------------------------------------------
# The probes read the container's own netns, which the test host does not
# have. Override them all up front so every resolver test is deterministic;
# the defaults describe a host with a full IPv6 stack.
# Keep the real REJECT probe reachable under another name for its own test.
eval "$(declare -f ip6_reject_available | sed '1s/^ip6_reject_available/real_ip6_reject_available/')"
eval "$(declare -f ip6_nat_available | sed '1s/^ip6_nat_available/real_ip6_nat_available/')"
stack=1; route=0; fwd=0; natok=1; filterok=1; rejectok=1; routedev=eth0
ip6_stack_enabled()     { [[ $stack == 1 ]]; }
ip6_default_route_dev() { if [[ $route == 1 ]]; then echo "$routedev"; fi; }
ip6_forwarding_enabled(){ [[ $fwd == 1 ]]; }
ip6_nat_available()     { [[ $natok == 1 ]]; }
ip6_filter_available()  { [[ $filterok == 1 ]]; }
ip6_reject_available()  { [[ $rejectok == 1 ]]; }

# ---- resolve_subnet ----------------------------------------------------
INTERFACE=10.13.13
# opt-in: unset keeps the pre-IPv6 behaviour
unset IP6_SUBNET
log=$(ip6_resolve_subnet; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${log##*$'\n'}" "unset -> off (opt-in)"
assert_contains "$log" 'Set IP6_SUBNET=auto to enable it' "unset: says how to enable"
assert_fail "unset is not requested" ip6_requested
IP6_SUBNET=off; assert_fail "off is not requested" ip6_requested
IP6_SUBNET=Off; assert_fail "Off is not requested" ip6_requested
IP6_SUBNET=auto
if ip6_requested; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: auto is requested"; fi
out=$(ip6_resolve_subnet; printf '%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "fd0a:0d0d:0000::|fd0a:0d0d:0000::/64" "${out##*$'\n'}" "auto -> derived"
IP6_SUBNET=AUTO
out=$(ip6_resolve_subnet; printf '%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "fd0a:0d0d:0000::|fd0a:0d0d:0000::/64" "${out##*$'\n'}" "AUTO case-insensitive"

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

# no IPv6 stack in the container: no prefix at all, or awg-quick's 'ip -6 addr
# add' fails and set -e tears the whole tunnel (IPv4 included) down.
stack=0
IP6_SUBNET=auto
log=$(ip6_resolve_subnet 2>&1; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${log##*$'\n'}" "no stack -> empty prefix, off"
assert_contains "$log" 'IPv6 is disabled in this container' "no stack: reason logged"
assert_contains "$log" 'disable_ipv6=1' "no stack: names the sysctl"

IP6_SUBNET='fd12:3456:789a::/64'
log=$(ip6_resolve_subnet 2>&1; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${log##*$'\n'}" "no stack beats an explicit IP6_SUBNET"
assert_contains "$log" 'IP6_SUBNET="fd12:3456:789a::/64" is ignored' "no stack: explicit setting is called out"

IP6_SUBNET=off
log=$(ip6_resolve_subnet 2>&1; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${log##*$'\n'}" "no stack + off -> off"
assert_contains "$log" 'IP6_SUBNET=off' "off is reported as off, not as a missing stack"
stack=1

# no filter table: nothing could block peers' IPv6, so none is handed out
filterok=0
IP6_SUBNET=auto
log=$(ip6_resolve_subnet 2>&1; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${log##*$'\n'}" "no filter table -> no prefix (fail closed)"
assert_contains "$log" 'ip6table_filter' "no filter table: reason names the module"
IP6_SUBNET='2001:db8:1::/64'
log=$(ip6_resolve_subnet 2>&1; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${log##*$'\n'}" "no filter table beats an explicit GUA prefix"
filterok=1

# server template could not take the IPv6 placeholders: same as off
IP6_SUBNET=auto
IP6_TEMPLATE_READY=0
log=$(ip6_resolve_subnet 2>&1; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${log##*$'\n'}" "template not ready -> no prefix"
assert_contains "$log" 'no ${IP6_POSTUP}/${IP6_POSTDOWN} placeholders' "template not ready: reason logged"
unset IP6_TEMPLATE_READY

# ---- template MTU floor ------------------------------------------------
# The kernel strips IPv6 from an interface whose MTU drops under 1280, so a
# template pinning a smaller MTU must keep IPv6 off rather than kill the tunnel.
MTUDIR=$(mktemp -d)
trap 'rm -rf "$MTUDIR"' EXIT
mtu_templates() {  # <server MTU line or ""> <peer MTU line or "">
    printf '[Interface]\nAddress = x\n%s\nPostUp = y\n' "$1" > "$MTUDIR/server.conf"
    printf '[Interface]\nAddress = x\n%s\nDNS = z\n' "$2" > "$MTUDIR/peer.conf"
}
mtu_templates "MTU = 1208" ""
assert_eq "1208" "$(ip6_conf_mtu "$MTUDIR/server.conf")" "conf_mtu reads the value"
assert_eq "" "$(ip6_conf_mtu "$MTUDIR/peer.conf")" "conf_mtu: no MTU line -> empty"
assert_eq "" "$(ip6_conf_mtu "$MTUDIR/missing.conf")" "conf_mtu: missing file -> empty, no error"
mtu_templates "  MTU=1200  " ""
assert_eq "1200" "$(ip6_conf_mtu "$MTUDIR/server.conf")" "conf_mtu tolerates spacing"
mtu_templates "MTU = 1208 # DS-Lite path" ""
assert_eq "1208" "$(ip6_conf_mtu "$MTUDIR/server.conf")" "conf_mtu strips an inline comment like awg-quick"
mtu_templates "# MTU = 1208" ""
assert_eq "" "$(ip6_conf_mtu "$MTUDIR/server.conf")" "conf_mtu ignores a commented-out MTU line"

run_mtu() {  # -> "ready|bad"
    ip6_check_template_mtu "$MTUDIR/server.conf" "$MTUDIR/peer.conf"
    printf '%s|%s' "$IP6_MTU_READY" "$IP6_MTU_BAD"
}
mtu_templates "" ""
assert_eq "1|" "$(run_mtu)" "no MTU lines -> ready"
mtu_templates "MTU = 1280" "MTU = 1280"
assert_eq "1|" "$(run_mtu)" "1280 is the floor and passes"
mtu_templates "MTU = 1420" "MTU = 1400"
assert_eq "1|" "$(run_mtu)" "above the floor passes"
mtu_templates "MTU = 1208" ""
assert_eq "0|$MTUDIR/server.conf (MTU = 1208)" "$(run_mtu)" "server below 1280 -> not ready, file named"
mtu_templates "" "MTU = 1188"
assert_eq "0|$MTUDIR/peer.conf (MTU = 1188)" "$(run_mtu)" "peer below 1280 -> not ready (Linux clients fail the same way)"
mtu_templates "MTU = 1208" "MTU = 1208"
assert_eq "0|$MTUDIR/server.conf (MTU = 1208), $MTUDIR/peer.conf (MTU = 1208)" "$(run_mtu)" "both named"
mtu_templates "MTU = abc" ""
assert_eq "1|" "$(run_mtu)" "non-numeric MTU is left to awg-quick"
mtu_templates "MTU = 1208 # DS-Lite" ""
assert_eq "0|$MTUDIR/server.conf (MTU = 1208)" "$(run_mtu)" "inline comment does not hide a too-small MTU"
mtu_templates "MTU = 1279" ""
assert_eq "0|$MTUDIR/server.conf (MTU = 1279)" "$(run_mtu)" "1279 is below the floor"

IP6_SUBNET=auto
mtu_templates "MTU = 1208" ""
ip6_check_template_mtu "$MTUDIR/server.conf" "$MTUDIR/peer.conf"
log=$(ip6_resolve_subnet 2>&1; printf '\n%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "|off" "${log##*$'\n'}" "MTU below floor -> no prefix, off"
assert_contains "$log" "server.conf (MTU = 1208)" "MTU below floor: file and value logged"
assert_contains "$log" "No such device" "MTU below floor: names the symptom it prevents"
assert_contains "$log" "MTU = 1280 or higher" "MTU below floor: says how to fix"
mtu_templates "MTU = 1280" "MTU = 1280"
ip6_check_template_mtu "$MTUDIR/server.conf" "$MTUDIR/peer.conf"
out=$(ip6_resolve_subnet; printf '%s|%s' "$IP6_PREFIX" "$IP6_SUBNET_EFFECTIVE")
assert_eq "fd0a:0d0d:0000::|fd0a:0d0d:0000::/64" "${out##*$'\n'}" "MTU 1280 -> IPv6 proceeds"
unset IP6_MTU_READY IP6_MTU_BAD

# ---- resolve_exit ------------------------------------------------------

ACCEPT='ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT'
# off keeps wg0 -> wg0 forwarding open so peers can still reach each other over IPv6, as they can over IPv4
INTRA='ip6tables -A FORWARD -i %i -o %i -j ACCEPT'
REJECT="${INTRA}; ip6tables -A FORWARD -i %i -j REJECT --reject-with icmp6-adm-prohibited; ip6tables -A FORWARD -o %i -j REJECT --reject-with icmp6-adm-prohibited"
DROPR="${INTRA}; ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP"
masq() { printf 'ip6tables -t nat -A POSTROUTING -s %s/64 -o %s -j MASQUERADE' "$1" "${2:-eth0}"; }
MASQ=$(masq fd0a:0d0d:0000::)
MASQNR=$(masq fd0a:0d0d:0000:: eth+)  # forced nat without a default route

run_exit() {  # <IP6_EXIT> <IP6_PREFIX> <stack> <route> <fwd> [natok] -> "mode|postup|postdown" on last line
    IP6_EXIT=$1 IP6_PREFIX=$2 stack=$3 route=$4 fwd=$5 natok=${6:-1}
    local out
    out=$(ip6_resolve_exit; printf '\n%s|%s|%s' "$IP6_EXIT_EFFECTIVE" "$IP6_POSTUP" "$IP6_POSTDOWN")
    printf '%s' "${out##*$'\n'}"
}
run_exit_log() {
    IP6_EXIT=$1 IP6_PREFIX=$2 stack=$3 route=$4 fwd=$5 natok=${6:-1}
    ip6_resolve_exit
}

assert_eq "nat|${ACCEPT}; ${MASQ}|${ACCEPT//-A/-D}; ${MASQ/-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 1 1)" "auto: ula+route+fwd -> nat"
assert_eq "nat|${ACCEPT}; $(masq fd12:3456:789a::)|${ACCEPT//-A/-D}; $(masq fd12:3456:789a:: | sed s/-A/-D/)" \
    "$(run_exit auto fd12:3456:789a:: 1 1 1)" "nat rule is scoped to the resolved prefix"
assert_contains "$(run_exit auto fd0a:0d0d:0000:: 1 0 1)" "${INTRA}; ip6tables -A FORWARD -i %i -j REJECT" "off: intra-tunnel ACCEPT precedes the REJECTs"
assert_eq "routed|${ACCEPT}|${ACCEPT//-A/-D}" \
    "$(run_exit auto 2001:db8:1:: 1 1 1)" "auto: gua+route+fwd -> routed"
assert_eq "off|${REJECT}|${REJECT//-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 0 1)" "auto: no route -> off"
assert_eq "off|${REJECT}|${REJECT//-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 1 0)" "auto: no forwarding -> off"
assert_eq "nat|${ACCEPT}; ${MASQNR}|${ACCEPT//-A/-D}; ${MASQNR/-A/-D}" \
    "$(run_exit nat fd0a:0d0d:0000:: 0 0 0)" "forced nat ignores probes, eth+ without a route"
assert_eq "routed|${ACCEPT}|${ACCEPT//-A/-D}" \
    "$(run_exit routed fd0a:0d0d:0000:: 0 0 0)" "forced routed"
assert_eq "off|${REJECT}|${REJECT//-A/-D}" \
    "$(run_exit off fd0a:0d0d:0000:: 1 1 1)" "forced off"
assert_eq "nat|${ACCEPT}; ${MASQNR}|${ACCEPT//-A/-D}; ${MASQNR/-A/-D}" \
    "$(run_exit NAT fd0a:0d0d:0000:: 0 0 0)" "mode is case-insensitive"
# IPv6 disabled: exactly the DROP pair the pre-IPv6 template hard-coded
LEGACY='ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP'
assert_eq "disabled|${LEGACY}|${LEGACY//-A/-D}" "$(run_exit auto '' 1 1 1)" "no prefix -> disabled, legacy DROP"
assert_eq "disabled|${LEGACY}|${LEGACY//-A/-D}" "$(run_exit nat '' 1 1 1)" "no prefix beats forced nat"
filterok=0
assert_eq "disabled||" "$(run_exit auto '' 1 1 1)" "no prefix, no filter table -> no rules"
filterok=1
IP6_TEMPLATE_READY=0
assert_eq "disabled||" "$(run_exit auto '' 1 1 1)" "customised template -> no rules for its PostDown to delete"
unset IP6_TEMPLATE_READY
# the rendered default template is byte-identical to the pre-IPv6 one
IP6_POSTUP=$LEGACY
rendered=""
eval "rendered=\"$(grep '^PostUp' "$HERE/../root/defaults/server.conf")\""
assert_eq 'PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP' "$rendered" "disabled renders the pre-IPv6 PostUp"
assert_eq "nat|${ACCEPT}; ${MASQ}|${ACCEPT//-A/-D}; ${MASQ/-A/-D}" \
    "$(run_exit bogus fd0a:0d0d:0000:: 1 1 1)" "unknown mode -> auto"
assert_contains "$(run_exit_log bogus fd0a:0d0d:0000:: 1 1 1)" 'IP6_EXIT "bogus" is not one of' "unknown mode warns"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 0 1)" 'no IPv6 default route' "off reason: route"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 0 1)" 'enable_ipv6: true' "off hint names the fix"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 1 0)" 'forwarding' "off reason: forwarding"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 1 1)" 'IPv6 exit: nat' "nat logged"

# ip6table_nat missing: auto must not choose a mode whose PostUp fails and
# takes the tunnel (IPv4 included) down with it.
assert_eq "off|${REJECT}|${REJECT//-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 1 1 0)" "auto: ula but no ip6table_nat -> off"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 1 1 0)" 'IPv6 NAT is unavailable' "off reason names NAT"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 1 1 0)" 'ip6table_nat' "off reason names the module"
assert_eq "routed|${ACCEPT}|${ACCEPT//-A/-D}" \
    "$(run_exit auto 2001:db8:1:: 1 1 1 0)" "auto: routed does not need NAT"
assert_eq "nat|${ACCEPT}; ${MASQ}|${ACCEPT//-A/-D}; ${MASQ/-A/-D}" \
    "$(run_exit nat fd0a:0d0d:0000:: 1 1 1 0)" "forced nat is honoured without ip6table_nat"

# MASQUERADE follows the default route's interface (network_mode: host)
routedev=enp3s0
assert_eq "nat|${ACCEPT}; $(masq fd0a:0d0d:0000:: enp3s0)|${ACCEPT//-A/-D}; $(masq fd0a:0d0d:0000:: enp3s0 | sed s/-A/-D/)" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 1 1)" "nat masquerades out of the default route's dev"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 1 1)" 'masqueraded out of enp3s0' "nat log names the dev"
routedev=eth0

# off must never fail PostUp: REJECT -> DROP -> nothing, as the host allows
rejectok=0
assert_eq "off|${DROPR}|${DROPR//-A/-D}" \
    "$(run_exit auto fd0a:0d0d:0000:: 1 0 1)" "off without REJECT target -> DROP"
assert_contains "$(run_exit_log auto fd0a:0d0d:0000:: 1 0 1)" 'REJECT target is unavailable' "DROP fallback logged"
assert_eq "off|${DROPR}|${DROPR//-A/-D}" \
    "$(run_exit off fd0a:0d0d:0000:: 1 1 1)" "forced off without REJECT target -> DROP"
rejectok=1

# REJECT probe: a unique scratch chain, created before anything is touched and
# the only thing removed. A fixed name pre-flushed on network_mode: host could
# wipe a chain that belongs to the host or another container.
PROBE_CALLS=()
# shellcheck disable=SC2317  # mock, invoked indirectly by the probe
ip6tables() { PROBE_CALLS+=("$*"); return 0; }
real_ip6_reject_available; probe_rc=$?
assert_eq "0" "$probe_rc" "probe succeeds when ip6tables accepts REJECT"
assert_eq "-N" "${PROBE_CALLS[0]%% *}" "probe's first call creates the chain (no pre-flush)"
probe_chain="${PROBE_CALLS[0]#-N }"
assert_contains "$probe_chain" 'AWG_PROBE_' "probe chain is namespaced"
if [[ "$probe_chain" == "AWG_PROBE" ]]; then FAIL=$((FAIL+1)); echo "FAIL: probe chain must not be the fixed name AWG_PROBE"; else PASS=$((PASS+1)); fi
assert_eq "-F $probe_chain|-X $probe_chain" "${PROBE_CALLS[2]}|${PROBE_CALLS[3]}" "probe removes only the chain it created"
for c in "${PROBE_CALLS[@]}"; do [[ "$c" == *"$probe_chain"* ]] || { FAIL=$((FAIL+1)); echo "FAIL: probe touched something else: $c"; }; done
PROBE_CALLS=()
# shellcheck disable=SC2317  # mock, invoked indirectly by the probe
ip6tables() { PROBE_CALLS+=("$*"); [[ "$1" == "-N" ]] && return 1; return 0; }
assert_fail "probe fails when the chain cannot be created" real_ip6_reject_available
assert_eq "1" "${#PROBE_CALLS[@]}" "failed -N leaves nothing to clean up"

# NAT probe: same discipline, in the nat table, and it must try the MASQUERADE
# target itself. A host can load ip6table_nat and still lack xt_MASQUERADE.
PROBE_CALLS=()
# shellcheck disable=SC2317  # mock, invoked indirectly by the probe
ip6tables() { PROBE_CALLS+=("$*"); return 0; }
real_ip6_nat_available; probe_rc=$?
assert_eq "0" "$probe_rc" "nat probe succeeds when MASQUERADE is accepted"
assert_eq "-t nat -N" "${PROBE_CALLS[0]% *}" "nat probe creates its chain in the nat table first"
nat_chain="${PROBE_CALLS[0]##* }"
assert_contains "$nat_chain" 'AWG_PROBE_' "nat probe chain is namespaced"
assert_eq "-t nat -A $nat_chain -j MASQUERADE" "${PROBE_CALLS[1]}" "nat probe tries the MASQUERADE target"
assert_eq "-t nat -F $nat_chain|-t nat -X $nat_chain" "${PROBE_CALLS[2]}|${PROBE_CALLS[3]}" "nat probe removes only its own chain"
PROBE_CALLS=()
# shellcheck disable=SC2317  # mock: table loads, target does not
ip6tables() { PROBE_CALLS+=("$*"); [[ "$*" == *"-j MASQUERADE"* ]] && return 1; return 0; }
assert_fail "nat probe fails when only the MASQUERADE target is missing" real_ip6_nat_available
assert_eq "4" "${#PROBE_CALLS[@]}" "a failed MASQUERADE still cleans up the chain"
unset -f ip6tables

# ---- template migration ------------------------------------------------

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
ip6_migrate_templates "$TMPD/server.conf" "$TMPD/peer.conf" > "$TMPD/log"; log=$(cat "$TMPD/log")
assert_contains "$(cat "$TMPD/server.conf")" 'Address = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}' "server Address migrated"
assert_contains "$(cat "$TMPD/server.conf")" 'MASQUERADE${IP6_POSTUP:+; ${IP6_POSTUP}}' "PostUp migrated"
assert_contains "$(cat "$TMPD/server.conf")" 'MASQUERADE${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}' "PostDown migrated"
assert_eq "0" "$(grep -c 'ip6tables' "$TMPD/server.conf")" "old ip6tables rules gone"
assert_contains "$(cat "$TMPD/peer.conf")" 'Address = ${CLIENT_IP}${CLIENT_IP6:+,${CLIENT_IP6}}' "peer Address migrated"
assert_eq "7" "$(wc -l < "$TMPD/server.conf" | tr -d ' ')" "server line count unchanged"
assert_eq "7" "$(wc -l < "$TMPD/peer.conf" | tr -d ' ')" "peer line count unchanged"
assert_contains "$log" 'migrated PostUp' "migration logged"
assert_eq "1" "$IP6_TEMPLATE_READY" "default templates are ready"

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

# customised PostUp: warned, PostUp *and* PostDown untouched (a lone migrated
# PostDown would delete rules PostUp never added), IPv6 disabled
old_server "$TMPD/custom.conf"
sed -i.bak 's|^PostUp = .*|PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/my-hook.sh|' "$TMPD/custom.conf"
ip6_migrate_templates "$TMPD/custom.conf" "$TMPD/peer.conf" > "$TMPD/log"; log=$(cat "$TMPD/log")
assert_contains "$log" 'PostUp/PostDown are customised' "customised PostUp warned"
assert_contains "$(cat "$TMPD/custom.conf")" 'PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/my-hook.sh' "customised PostUp untouched"
assert_eq "0" "$(grep -c 'IP6_POSTDOWN' "$TMPD/custom.conf")" "PostDown not migrated alone"
assert_eq "1" "$(grep -c 'ip6tables -D FORWARD -i %i -j ACCEPT' "$TMPD/custom.conf")" "old PostDown kept"
assert_eq "0" "$IP6_TEMPLATE_READY" "customised pair -> template not ready"
assert_contains "$(cat "$TMPD/custom.conf")" '${SERVER_IP6:+' "Address still migrated in customised file"

# customised #36 DROP PostUp (eth+ changed): same, so peers never get IPv6
# addresses that the customised DROP would silently blackhole
drop_server "$TMPD/cdrop.conf"
sed -i.bak 's|eth+|ens+|' "$TMPD/cdrop.conf"
ip6_migrate_templates "$TMPD/cdrop.conf" "$TMPD/peer.conf" > /dev/null
assert_eq "0" "$IP6_TEMPLATE_READY" "customised DROP pair -> template not ready"
assert_eq "2" "$(grep -c -- '-j DROP$' "$TMPD/cdrop.conf")" "customised DROP pair untouched"

# PostUp already carries the placeholder, PostDown is the old default: the
# pair is migratable, PostDown is migrated
old_server "$TMPD/half.conf"
sed -i.bak 's|^PostUp = .*|PostUp = my-fw.sh${IP6_POSTUP:+; ${IP6_POSTUP}}|' "$TMPD/half.conf"
ip6_migrate_templates "$TMPD/half.conf" "$TMPD/peer.conf" > /dev/null
assert_eq "1" "$IP6_TEMPLATE_READY" "placeholder PostUp + old PostDown -> ready"
assert_contains "$(cat "$TMPD/half.conf")" 'MASQUERADE${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}' "PostDown migrated next to a placeholder PostUp"

# the placeholder only counts on the active PostUp/PostDown lines
old_server "$TMPD/comment.conf"
sed -i.bak 's|^PostUp = .*|PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/my-hook.sh|' "$TMPD/comment.conf"
printf '# TODO add ${IP6_POSTUP} and ${IP6_POSTDOWN} here\n' >> "$TMPD/comment.conf"
ip6_migrate_templates "$TMPD/comment.conf" "$TMPD/peer.conf" > /dev/null
assert_eq "0" "$IP6_TEMPLATE_READY" "marker in a comment does not make the template ready"
assert_eq "1" "$(grep -c 'ip6tables -D FORWARD -i %i -j ACCEPT' "$TMPD/comment.conf")" "comment marker: PostDown left alone"
old_server "$TMPD/commentaddr.conf"
printf '# ${SERVER_IP6} is set when IPv6 is on\n' >> "$TMPD/commentaddr.conf"
ip6_migrate_templates "$TMPD/commentaddr.conf" "$TMPD/peer.conf" > /dev/null
assert_contains "$(cat "$TMPD/commentaddr.conf")" 'Address = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}' "comment marker: Address still migrated"

# a look-alike variable on the active line is not the placeholder: it would
# leave the template "ready" while ${IP6_POSTUP} is never expanded
old_server "$TMPD/lookalike.conf"
sed -i.bak 's|^PostUp = .*|PostUp = iptables -A FORWARD -i %i -j ACCEPT; ${IP6_POSTUP_EXTRA}|' "$TMPD/lookalike.conf"
ip6_migrate_templates "$TMPD/lookalike.conf" "$TMPD/peer.conf" > "$TMPD/log"; log=$(cat "$TMPD/log")
assert_eq "0" "$IP6_TEMPLATE_READY" "look-alike \${IP6_POSTUP_EXTRA} does not make the template ready"
assert_contains "$log" 'PostUp/PostDown are customised' "look-alike PostUp warned"
assert_eq "1" "$(grep -c 'ip6tables -D FORWARD -i %i -j ACCEPT' "$TMPD/lookalike.conf")" "look-alike: PostDown left alone"
old_server "$TMPD/addrlook.conf"
sed -i.bak 's|^Address = .*|Address = ${INTERFACE}.1${SERVER_IP6_LEGACY}|' "$TMPD/addrlook.conf"
log=$(ip6_migrate_templates "$TMPD/addrlook.conf" "$TMPD/peer.conf")
assert_contains "$log" 'Address line is customised and has no ${SERVER_IP6} placeholder' "look-alike Address warned"
assert_eq "0" "$(grep -c 'SERVER_IP6:+' "$TMPD/addrlook.conf")" "look-alike Address left alone"
# both spellings of the real placeholder count: the shipped ${VAR:+...} form and a bare ${VAR}
printf 'PostUp = my-fw.sh${IP6_POSTUP:+; ${IP6_POSTUP}}\nAddress = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}\nPostDown = my-fw.sh down; ${IP6_POSTDOWN}\n' > "$TMPD/bare.conf"
ip6_migrate_templates "$TMPD/bare.conf" "$TMPD/peer.conf" > "$TMPD/log"
assert_eq "" "$(cat "$TMPD/log")" "bare \${IP6_POSTDOWN} -> silent"
assert_eq "1" "$IP6_TEMPLATE_READY" "bare \${IP6_POSTDOWN} counts as the placeholder"

# user already added the placeholder to a customised line: silent
printf 'PostUp = my-fw.sh${IP6_POSTUP:+; ${IP6_POSTUP}}\nAddress = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}\nPostDown = x${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}\n' > "$TMPD/marker.conf"
ip6_migrate_templates "$TMPD/marker.conf" "$TMPD/peer.conf" > "$TMPD/log"
assert_eq "" "$(cat "$TMPD/log")" "marker present -> silent"
assert_eq "1" "$IP6_TEMPLATE_READY" "marker present -> ready"

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
printf '. {\n    # import /config/coredns/generated/*.conf\n    forward . /etc/resolv.conf\n}\n' > "$CD/Corefile"
log=$(ip6_write_coredns_filter off "$CD")
assert_contains "$log" 'has no' "commented-out import still gets the hint"
printf '. {\n\timport /config/coredns/generated/*.conf\n    forward . /etc/resolv.conf\n}\n' > "$CD/Corefile"
log=$(ip6_write_coredns_filter off "$CD")
assert_eq "" "$log" "tab-indented import is active"

rm -rf "$CD"; mkdir -p "$CD"
log=$(ip6_write_coredns_filter off "$CD")
assert_contains "$(cat "$CD/generated/ipv6.conf")" 'template IN AAAA' "works before Corefile exists"
assert_eq "" "$log" "no Corefile -> no hint"

# unmodified pre-IPv6 Corefile is migrated to the new default; customised is not
printf '%s\n' "$IP6_OLD_COREFILE" > "$CD/Corefile"
log=$(ip6_migrate_corefile "$CD/Corefile" "$HERE/../root/defaults/Corefile")
assert_eq "$(cat "$HERE/../root/defaults/Corefile")" "$(cat "$CD/Corefile")" "old default Corefile replaced by new default"
assert_contains "$log" 'added' "Corefile migration logged"
log=$(ip6_migrate_corefile "$CD/Corefile" "$HERE/../root/defaults/Corefile")
assert_eq "" "$log" "Corefile migration is idempotent"
printf '. {\n    forward . 1.1.1.1\n}\n' > "$CD/Corefile"
log=$(ip6_migrate_corefile "$CD/Corefile" "$HERE/../root/defaults/Corefile")
assert_eq "" "$log" "customised Corefile left alone"
assert_contains "$(cat "$CD/Corefile")" 'forward . 1.1.1.1' "customised Corefile untouched"

# ---- shipped defaults match the migration targets -----------------------
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_SERVER_ADDRESS" "$HERE/../root/defaults/server.conf")" "defaults/server.conf Address == IP6_NEW_SERVER_ADDRESS"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_POSTUP" "$HERE/../root/defaults/server.conf")" "defaults/server.conf PostUp == IP6_NEW_POSTUP"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_POSTDOWN" "$HERE/../root/defaults/server.conf")" "defaults/server.conf PostDown == IP6_NEW_POSTDOWN"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_PEER_ADDRESS" "$HERE/../root/defaults/peer.conf")" "defaults/peer.conf Address == IP6_NEW_PEER_ADDRESS"
assert_eq "1" "$(grep -Fc -- "$IP6_COREDNS_IMPORT" "$HERE/../root/defaults/Corefile")" "defaults/Corefile has import"

echo "PASS ${PASS} / FAIL ${FAIL}"
[[ $FAIL -eq 0 ]]
