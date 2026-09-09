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

# ---- probe overrides ---------------------------------------------------
# The four probes read the container's own netns, which the test host does not
# have. Override them all up front so every resolver test is deterministic;
# the defaults describe a host with a full IPv6 stack.
stack=1; route=0; fwd=0; natok=1
ip6_stack_enabled()     { [[ $stack == 1 ]]; }
ip6_has_default_route() { [[ $route == 1 ]]; }
ip6_forwarding_enabled(){ [[ $fwd == 1 ]]; }
ip6_nat_available()     { [[ $natok == 1 ]]; }

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

# no IPv6 stack in the container: no prefix at all, or awg-quick's 'ip -6 addr
# add' fails and set -e tears the whole tunnel (IPv4 included) down.
stack=0
unset IP6_SUBNET
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

# ---- resolve_exit ------------------------------------------------------

ACCEPT='ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT'
# off keeps wg0 -> wg0 forwarding open so peers can still reach each other over IPv6, as they can over IPv4
INTRA='ip6tables -A FORWARD -i %i -o %i -j ACCEPT'
REJECT="${INTRA}; ip6tables -A FORWARD -i %i -j REJECT --reject-with icmp6-adm-prohibited; ip6tables -A FORWARD -o %i -j REJECT --reject-with icmp6-adm-prohibited"
masq() { printf 'ip6tables -t nat -A POSTROUTING -s %s/64 -o eth+ -j MASQUERADE' "$1"; }
MASQ=$(masq fd0a:0d0d:0000::)

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

# ---- shipped defaults match the migration targets -----------------------
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_SERVER_ADDRESS" "$HERE/../root/defaults/server.conf")" "defaults/server.conf Address == IP6_NEW_SERVER_ADDRESS"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_POSTUP" "$HERE/../root/defaults/server.conf")" "defaults/server.conf PostUp == IP6_NEW_POSTUP"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_POSTDOWN" "$HERE/../root/defaults/server.conf")" "defaults/server.conf PostDown == IP6_NEW_POSTDOWN"
assert_eq "1" "$(grep -Fxc -- "$IP6_NEW_PEER_ADDRESS" "$HERE/../root/defaults/peer.conf")" "defaults/peer.conf Address == IP6_NEW_PEER_ADDRESS"
assert_eq "1" "$(grep -Fc -- "$IP6_COREDNS_IMPORT" "$HERE/../root/defaults/Corefile")" "defaults/Corefile has import"

echo "PASS ${PASS} / FAIL ${FAIL}"
[[ $FAIL -eq 0 ]]
