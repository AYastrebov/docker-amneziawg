#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2016  # IP6_* globals are consumed by init-amneziawg-confs/run; SC2016: single quotes are intentional for literal pattern matching
# IPv6 helpers for init-amneziawg-confs. Sourced, not executed.
# Pure functions read only their arguments or the documented globals so the
# file can be unit-tested outside the container (tests/ipv6-lib.test.sh).
#
# Globals consumed: IP6_SUBNET, IP6_EXIT, INTERFACE,
#                   IP6_TEMPLATE_READY (set by ip6_migrate_templates),
#                   IP6_MTU_READY, IP6_MTU_BAD (set by ip6_check_template_mtu)
# Globals produced: IP6_PREFIX, IP6_SUBNET_EFFECTIVE, IP6_EXIT_EFFECTIVE,
#                   IP6_POSTUP, IP6_POSTDOWN

# a.b.c -> fdaa:bbcc:0000:: (RFC 4193 ULA, deterministic per subnet)
ip6_derive_prefix() {
    local iface=$1 a b c
    IFS=. read -r a b c <<< "${iface}"
    # 10# forces decimal: printf treats a leading zero (08) as octal and fails
    printf 'fd%02x:%02x%02x:0000::\n' "$((10#${a}))" "$((10#${b}))" "$((10#${c}))"
}

# IPv6 is opt-in: unset (or "off") keeps the container byte-for-byte on the
# pre-IPv6 behaviour, templates and Corefile included. "auto" or a prefix
# enables it. s6 drops empty variables, so "unset" also covers IP6_SUBNET=.
ip6_requested() {
    local v="${IP6_SUBNET:-}"
    [[ -n "${v}" && "${v,,}" != "off" ]]
}

# Accepts "<1-4 hextets>::/64" (any case) in fc00::/7 (ULA) or 2000::/3
# (global unicast). Prints the lowercase prefix without the /64. Returns 1 on
# anything else: a link-local or multicast prefix passes the syntax check but
# cannot be assigned as a unicast address, and awg-quick would take the whole
# tunnel down trying.
ip6_validate_subnet() {
    local v="${1,,}" h
    [[ "${v}" =~ ^([0-9a-f]{1,4}:){0,3}[0-9a-f]{1,4}::/64$ ]] || return 1
    h="${v%%:*}"
    h=$(printf '%4s' "${h}"); h="${h// /0}"   # "fd" is 00fd, not fd00
    [[ "${h}" =~ ^(f[cd]|[23]) ]] || return 1
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

# <file> <key> -> the value of the first active "<key> = ..." line, with the
# inline "# comment" awg-quick strips (${line%%\#*}) stripped the same way and
# all whitespace removed. Prints nothing when there is no such line.
ip6_conf_value() {
    local line
    line=$(grep -m1 -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null) || return 0
    line="${line%%\#*}"
    line="${line#*=}"
    printf '%s\n' "${line//[[:space:]]/}"
}

# <peer conf> -> the IPv4 address on its Address line, without a mask. The
# line may list both families in any order and with or without spaces
# ("10.13.13.2,fd..::2/128", "fd..::2/128, 10.13.13.2") and may end in a
# comment ("10.13.13.2/32 # laptop"). Prints nothing when there is no IPv4
# address.
ip6_conf_ipv4() {
    local line addr
    line=$(ip6_conf_value "$1" Address)
    local IFS=,
    for addr in ${line}; do
        if [[ "${addr}" == *.* && "${addr}" != *:* ]]; then
            printf '%s\n' "${addr%%/*}"
            return 0
        fi
    done
}

# IPv6 needs an interface MTU of at least 1280 (RFC 8200). The kernel enforces
# it the hard way: 'ip link set mtu 1208 dev wg0' on an interface that already
# holds an IPv6 address removes that address, and awg-quick's next
# 'ip -6 route add' fails with "RTNETLINK answers: No such device" - under
# set -e that tears the whole tunnel down, IPv4 included. A peer conf below
# 1280 does the same on a Linux client (and Windows refuses the address).
IP6_MIN_MTU=1280

# Prints the value of the first "MTU = N" line in a conf or template, nothing
# when there is no MTU line (awg-quick then derives one, which is >= 1280 on
# any ordinary link). "MTU = 1208 # DS-Lite" yields 1208, as it does for
# awg-quick; keeping the comment would make the value non-numeric and let the
# template pass the floor check it is meant to fail.
ip6_conf_mtu() {
    ip6_conf_value "$1" MTU
}

# Sets IP6_MTU_READY=1 when no template pins an MTU below IP6_MIN_MTU, else 0
# with IP6_MTU_BAD naming the offending file(s). Checked before IPv6 is handed
# out so a too-small MTU costs the IPv6 feature, not the tunnel. A value that
# is not a number is left for awg-quick to reject and counts as ready.
ip6_check_template_mtu() {   # <template>...
    local f mtu
    IP6_MTU_READY=1
    IP6_MTU_BAD=""
    for f in "$@"; do
        mtu=$(ip6_conf_mtu "$f")
        [[ "${mtu}" =~ ^[0-9]+$ ]] || continue
        if (( mtu < IP6_MIN_MTU )); then
            IP6_MTU_READY=0
            IP6_MTU_BAD="${IP6_MTU_BAD:+${IP6_MTU_BAD}, }${f} (MTU = ${mtu})"
        fi
    done
}

# Sets IP6_PREFIX ("" when IPv6 is disabled) and IP6_SUBNET_EFFECTIVE.
# Uses the ip6_stack_enabled probe defined below: without an IPv6 stack the
# container cannot even hold the address, so no prefix may be handed out.
ip6_resolve_subnet() {
    local requested="${IP6_SUBNET:-}" derived
    derived=$(ip6_derive_prefix "${INTERFACE}")
    if ! ip6_requested; then
        IP6_PREFIX=""
        IP6_SUBNET_EFFECTIVE="off"
        if [[ -n "${requested}" ]]; then
            echo "**** IPv6 is disabled (IP6_SUBNET=off); peers get IPv4 addresses only ****"
        else
            echo "**** IPv6 is disabled (default); peers get IPv4 addresses only. Set IP6_SUBNET=auto to enable it ****"
        fi
        return 0
    fi
    # A server template whose PostUp/PostDown cannot carry the IPv6 rules
    # (customised, no placeholder) would hand peers addresses the firewall
    # knows nothing about. Behave exactly as IP6_SUBNET=off instead.
    if [[ "${IP6_TEMPLATE_READY:-1}" != "1" ]]; then
        IP6_PREFIX=""
        IP6_SUBNET_EFFECTIVE="off"
        echo "**** IPv6 is disabled because /config/templates/server.conf has no \${IP6_POSTUP}/\${IP6_POSTDOWN} placeholders; peers get IPv4 addresses only. See README section \"IPv6\" ****"
        return 0
    fi
    # A template that pins MTU below 1280 would make the kernel strip the IPv6
    # address again as soon as awg-quick sets the MTU, and the tunnel would die
    # on the next 'ip -6 route add' (see IP6_MIN_MTU). Behave as IP6_SUBNET=off.
    if [[ "${IP6_MTU_READY:-1}" != "1" ]]; then
        IP6_PREFIX=""
        IP6_SUBNET_EFFECTIVE="off"
        echo "**** IPv6 is disabled because ${IP6_MTU_BAD:-a template} pins the tunnel MTU below the IPv6 minimum of ${IP6_MIN_MTU}: the kernel removes IPv6 from an interface whose MTU is under 1280, so with an IPv6 address awg-quick would fail on 'ip -6 route add' with 'No such device' and take the tunnel down, on the server and on Linux clients alike. Set MTU = 1280 or higher in both templates (or drop the line) to enable IPv6; peers get IPv4 addresses only until then. See README section \"IPv6\" ****"
        return 0
    fi
    # No IPv6 stack: 'ip -6 address add' and 'ip -6 route add' would fail, and
    # awg-quick (set -e, teardown trap) would take the whole tunnel down with
    # them - including IPv4. Behave exactly as IP6_SUBNET=off instead.
    if ! ip6_stack_enabled; then
        IP6_PREFIX=""
        IP6_SUBNET_EFFECTIVE="off"
        if [[ -n "${requested}" ]]; then
            echo "**** IPv6 is disabled in this container's kernel (sysctl net.ipv6.conf.all.disable_ipv6=1 or net.ipv6.conf.default.disable_ipv6=1), so IP6_SUBNET=\"${requested}\" is ignored; peers get IPv4 addresses only ****"
        else
            echo "**** IPv6 is disabled in this container's kernel (sysctl net.ipv6.conf.all.disable_ipv6=1 or net.ipv6.conf.default.disable_ipv6=1); peers get IPv4 addresses only ****"
        fi
        return 0
    fi
    # No filter table: nothing could ever block or NAT peers' IPv6, and with a
    # route and forwarding the kernel would simply forward it. Fail closed.
    if ! ip6_filter_available; then
        IP6_PREFIX=""
        IP6_SUBNET_EFFECTIVE="off"
        echo "**** IPv6 is disabled: the ip6tables filter table is unavailable in this container (the host kernel has no usable ip6table_filter), so peers' IPv6 could not be filtered; peers get IPv4 addresses only ****"
        return 0
    fi
    if [[ "${requested,,}" == "auto" ]]; then
        IP6_PREFIX="${derived}"
    elif IP6_PREFIX=$(ip6_validate_subnet "${requested}"); then
        :
    else
        echo "**** IP6_SUBNET \"${requested}\" is invalid (expected auto, off, or a ULA or global /64 such as fd12:3456:789a::/64); using derived ${derived}/64 ****"
        IP6_PREFIX="${derived}"
    fi
    IP6_SUBNET_EFFECTIVE="${IP6_PREFIX}/64"
    echo "**** IPv6 tunnel prefix is ${IP6_SUBNET_EFFECTIVE} (server $(ip6_server_addr "${IP6_PREFIX}")) ****"
}

# ---- exit mode ---------------------------------------------------------
# Probes read the container's own netns. Tests override them.
# wg0 is created after this runs and takes its devconf from "default", not
# "all": either one set to 1 makes 'ip -6 address add ... dev wg0' fail.
ip6_stack_enabled() {
    [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == "0" ]] &&
        [[ "$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)" == "0" ]]
}
# Interface of the first IPv6 default route; empty when there is none.
ip6_default_route_dev() {
    ip -6 route show default 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}
ip6_forwarding_enabled() {
    [[ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" == "1" ]]
}
# The nat table (ip6table_nat) and the MASQUERADE target (xt_MASQUERADE, or
# nft_masq under iptables-nft) are separate modules, and a MASQUERADE PostUp on
# a host missing either fails and takes the whole tunnel with it. Listing the
# table only proves the first, so try the target itself in a scratch chain of
# the nat table, with the same unique-name, clean-only-our-own rules as the
# REJECT probe below.
ip6_nat_available() {
    local chain="AWG_PROBE_$$_${RANDOM}" rc=0
    ip6tables -t nat -N "${chain}" >/dev/null 2>&1 || return 1
    ip6tables -t nat -A "${chain}" -j MASQUERADE >/dev/null 2>&1 || rc=1
    ip6tables -t nat -F "${chain}" >/dev/null 2>&1
    ip6tables -t nat -X "${chain}" >/dev/null 2>&1
    return "${rc}"
}
# Every mode's FORWARD rules need the filter table (ip6table_filter).
ip6_filter_available() {
    ip6tables -S FORWARD >/dev/null 2>&1
}
# The REJECT target is a separate module (ip6t_REJECT, or the xt compat layer
# under iptables-nft) and cannot be listed, only used: try it in a scratch
# chain that is removed again straight away.
# The chain name is unique per invocation and only a chain this call created
# is removed: on network_mode: host the table is shared with the host and
# other containers, and a fixed name could flush someone else's rules.
ip6_reject_available() {
    local chain="AWG_PROBE_$$_${RANDOM}" rc=0
    ip6tables -N "${chain}" >/dev/null 2>&1 || return 1
    ip6tables -A "${chain}" -j REJECT --reject-with icmp6-adm-prohibited >/dev/null 2>&1 || rc=1
    ip6tables -F "${chain}" >/dev/null 2>&1
    ip6tables -X "${chain}" >/dev/null 2>&1
    return "${rc}"
}

# Sets IP6_EXIT_EFFECTIVE, IP6_POSTUP, IP6_POSTDOWN from IP6_EXIT and IP6_PREFIX.
ip6_resolve_exit() {
    local mode="${IP6_EXIT:-auto}" reason="" dev="" offrules="reject"
    local accept='ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT'
    # "off" is no IPv6 *egress*, not no IPv6: a bare "-i %i -j REJECT" would also
    # reject wg0 -> wg0 forwarding and make peers unreachable to each other over
    # IPv6 while IPv4 (ACCEPT) still allows it. Keep the intra-tunnel path open.
    local intra='ip6tables -A FORWARD -i %i -o %i -j ACCEPT'
    local reject="${intra}; ip6tables -A FORWARD -i %i -j REJECT --reject-with icmp6-adm-prohibited; ip6tables -A FORWARD -o %i -j REJECT --reject-with icmp6-adm-prohibited"
    local drop="${intra}; ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP"
    # Exactly what the pre-IPv6 template hard-coded (#36), so a container
    # with IPv6 disabled renders the same wg0.conf as before the feature.
    local legacy='ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP'
    local masq
    mode="${mode,,}"
    IP6_POSTUP=""
    IP6_POSTDOWN=""
    if [[ -z "${IP6_PREFIX}" ]]; then
        IP6_EXIT_EFFECTIVE="disabled"
        # Without a filter table those DROPs fail PostUp and take IPv4 down,
        # which the hard-coded template used to do; skip them there instead.
        # A customised PostUp (template not ready) never adds them, so its
        # placeholder-carrying PostDown must not try to delete them either.
        if [[ "${IP6_TEMPLATE_READY:-1}" != "1" ]]; then
            echo "**** IPv6 exit: disabled (customised PostUp/PostDown; no IPv6 rules added to them) ****"
        elif ip6_filter_available; then
            IP6_POSTUP="${legacy}"
            IP6_POSTDOWN="${legacy//-A/-D}"
            echo "**** IPv6 exit: disabled (peers' IPv6 traffic into the tunnel is dropped) ****"
        else
            echo "**** IPv6 exit: disabled (ip6tables filter table unavailable; no IPv6 rules applied) ****"
        fi
        return 0
    fi
    case "${mode}" in
        auto|nat|routed|off) ;;
        *)
            echo "**** IP6_EXIT \"${IP6_EXIT}\" is not one of auto|nat|routed|off; using auto ****"
            mode="auto"
            ;;
    esac
    dev=$(ip6_default_route_dev)
    # ip6_resolve_subnet already left IP6_PREFIX empty without an IPv6 stack
    # or filter table, so neither needs a second check here.
    if [[ "${mode}" == "auto" ]]; then
        if [[ -z "${dev}" ]]; then
            mode="off"; reason="no IPv6 default route in the container"
        elif ! ip6_forwarding_enabled; then
            # The REJECT rules never fire here: with forwarding off the kernel
            # drops non-local packets before the FORWARD chain. Say so.
            mode="off"; reason="sysctl net.ipv6.conf.all.forwarding is 0, so peers' IPv6 is dropped silently rather than refused - set it to 1 even without egress"
        elif ip6_is_ula "${IP6_PREFIX}"; then
            # Only on the auto path: a forced nat is honoured verbatim, failure
            # and all (spec 4.2). auto must not pick a mode whose PostUp fails.
            if ip6_nat_available; then
                mode="nat"
            else
                mode="off"; reason="IPv6 NAT is unavailable in this container (the host kernel has no usable ip6table_nat or MASQUERADE target)"
            fi
        else
            mode="routed"
        fi
    fi
    # NAT only the tunnel prefix, and out of the interface the default route
    # actually uses: on network_mode: host that is rarely eth+, and a rule that
    # never matches forwards the ULA unmasqueraded into a blackhole. eth+ is
    # kept only for a forced nat with no route, where nothing would match anyway.
    masq="ip6tables -t nat -A POSTROUTING -s ${IP6_PREFIX}/64 -o ${dev:-eth+} -j MASQUERADE"
    # off is the safe fallback, so it must never fail PostUp itself (that
    # takes IPv4 down too): REJECT if usable, else DROP. The filter table
    # itself is guaranteed by ip6_resolve_subnet.
    if [[ "${mode}" == "off" ]] && ! ip6_reject_available; then
        offrules="drop"
    fi
    IP6_EXIT_EFFECTIVE="${mode}"
    case "${mode}" in
        nat)    IP6_POSTUP="${accept}; ${masq}" ;;
        routed) IP6_POSTUP="${accept}" ;;
        off)
            case "${offrules}" in
                reject) IP6_POSTUP="${reject}" ;;
                drop)   IP6_POSTUP="${drop}" ;;
            esac
            ;;
    esac
    IP6_POSTDOWN="${IP6_POSTUP//ip6tables -A/ip6tables -D}"
    IP6_POSTDOWN="${IP6_POSTDOWN//-t nat -A/-t nat -D}"
    case "${mode}" in
        nat)    echo "**** IPv6 exit: nat (peers' IPv6 traffic is masqueraded out of ${dev:-eth+}) ****" ;;
        routed) echo "**** IPv6 exit: routed (no NAT; ${IP6_PREFIX}/64 must be routed to this host and, on a bridge network, by the host to this container - the container cannot check either. See README section \"Routed global prefix\") ****" ;;
        off)
            if [[ -n "${reason}" ]]; then
                echo "**** IPv6 exit: off (${reason}). Peers get IPv6 addresses but IPv6 traffic is rejected. To enable IPv6 egress set 'networks.default.enable_ipv6: true' and sysctl 'net.ipv6.conf.all.forwarding=1' in docker-compose.yml, or set IP6_SUBNET=off to disable IPv6 entirely ****"
            else
                echo "**** IPv6 exit: off (IP6_EXIT=off). Peers get IPv6 addresses but IPv6 traffic is rejected ****"
            fi
            if [[ "${offrules}" == "drop" ]]; then
                echo "**** IPv6 exit: the ip6tables REJECT target is unavailable; peers' IPv6 traffic is dropped instead (IPv6 connections time out rather than fail fast unless peers use the built-in DNS) ****"
            fi
            ;;
    esac
}

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

# <file> <key> <var> -> true when an active "<key> = ..." line expands the
# placeholder variable: "${var}" or a "${var:+...}"-style expansion. A comment
# or an unrelated line mentioning it must not count, or a template would pass
# as migrated while its real PostUp has none; nor may a look-alike such as
# "${IP6_POSTUP_EXTRA}", which would leave IP6_TEMPLATE_READY=1 while the
# firewall rules are never expanded and peers get unmanaged IPv6 addresses.
ip6_key_has_marker() {
    local file=$1 key=$2 var=$3 line
    local re='\$\{'"${var}"'[}:+-]'
    [[ -f "${file}" ]] || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*${key}[[:space:]]*= ]] || continue
        [[ "${line}" =~ ${re} ]] && return 0
    done < "${file}"
    return 1
}

# <file> <new line> <var> <key> <old line>...
ip6_migrate_line() {
    local file=$1 new=$2 var=$3 label=$4 old line tmp
    shift 4
    [[ -f "${file}" ]] || return 0
    if ip6_key_has_marker "${file}" "${label}" "${var}"; then
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
    echo "**** ${file}: ${label} line is customised and has no \${${var}} placeholder; IPv6 will not be applied to it. See README section \"IPv6\" ****"
    return 0
}

# <file> <key> <var> <old line>... -> true when the active <key> line
# already expands the placeholder or is one of the known old lines, i.e.
# ip6_migrate_line can handle it.
ip6_line_migratable() {
    local file=$1 key=$2 var=$3 old
    shift 3
    ip6_key_has_marker "${file}" "${key}" "${var}" && return 0
    for old in "$@"; do
        grep -Fxq -- "${old}" "${file}" && return 0
    done
    return 1
}

# <server template> <peer template>
# Sets IP6_TEMPLATE_READY=1 when the server template carries both firewall
# placeholders after migration, 0 otherwise (ip6_resolve_subnet then disables
# IPv6, as a missing PostUp placeholder would leave peers' IPv6 unmanaged).
ip6_migrate_templates() {
    local server=$1 peer=$2
    IP6_TEMPLATE_READY=1
    ip6_migrate_line "${server}" "${IP6_NEW_SERVER_ADDRESS}" SERVER_IP6   'Address'  "${IP6_OLD_SERVER_ADDRESS}"
    # PostUp and PostDown are migrated as a pair or not at all: migrating one
    # alone leaves PostDown deleting rules PostUp never added (awg-quick down
    # fails), or PostUp adding rules PostDown never removes.
    if [[ -f "${server}" ]]; then
        if ip6_line_migratable "${server}" PostUp   IP6_POSTUP   "${IP6_OLD_POSTUP_ACCEPT}"   "${IP6_OLD_POSTUP_DROP}" &&
           ip6_line_migratable "${server}" PostDown IP6_POSTDOWN "${IP6_OLD_POSTDOWN_ACCEPT}" "${IP6_OLD_POSTDOWN_DROP}"; then
            ip6_migrate_line "${server}" "${IP6_NEW_POSTUP}"   IP6_POSTUP   'PostUp'   "${IP6_OLD_POSTUP_ACCEPT}"   "${IP6_OLD_POSTUP_DROP}"
            ip6_migrate_line "${server}" "${IP6_NEW_POSTDOWN}" IP6_POSTDOWN 'PostDown' "${IP6_OLD_POSTDOWN_ACCEPT}" "${IP6_OLD_POSTDOWN_DROP}"
            # Belt and braces: the active lines must carry the placeholders now.
            if ! ip6_key_has_marker "${server}" PostUp IP6_POSTUP ||
               ! ip6_key_has_marker "${server}" PostDown IP6_POSTDOWN; then
                IP6_TEMPLATE_READY=0
                echo "**** ${server}: PostUp/PostDown still lack the \${IP6_POSTUP}/\${IP6_POSTDOWN} placeholders after migration; IPv6 is disabled. See README section \"IPv6\" ****"
            fi
        else
            IP6_TEMPLATE_READY=0
            echo "**** ${server}: PostUp/PostDown are customised and do not both carry the \${IP6_POSTUP}/\${IP6_POSTDOWN} placeholders; both were left alone and IPv6 is disabled. See README section \"IPv6\" ****"
        fi
    fi
    ip6_migrate_line "${peer}"   "${IP6_NEW_PEER_ADDRESS}"   CLIENT_IP6   'Address'  "${IP6_OLD_PEER_ADDRESS}"
}

# ---- coredns AAAA filter -----------------------------------------------
IP6_COREDNS_IMPORT='import /config/coredns/generated/*.conf'
# The Corefile shipped before IPv6 support. An unmodified copy is replaced by
# the new default; a customised one only gets the hint below.
IP6_OLD_COREFILE='. {
    loop
    errors
    health
    cache
    forward . /etc/resolv.conf
}'

# <Corefile> <new default Corefile>
ip6_migrate_corefile() {
    local file=$1 default=$2
    [[ -f "${file}" && -f "${default}" ]] || return 0
    if [[ "$(cat "${file}")" == "${IP6_OLD_COREFILE}" ]]; then
        cat "${default}" > "${file}"
        echo "**** ${file}: added '${IP6_COREDNS_IMPORT}' for IPv6 AAAA filtering ****"
    fi
}

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
        # An active directive, not a commented-out one
        if [[ -f "${dir}/Corefile" ]] && ! grep -Eq '^[[:space:]]*import[[:space:]]+/config/coredns/generated/\*\.conf([[:space:]]|$)' "${dir}/Corefile"; then
            echo "**** ${dir}/Corefile has no '${IP6_COREDNS_IMPORT}' line; AAAA filtering for peers is not active. Add that line inside the server block to enable it ****"
        fi
    else
        : > "${dir}/generated/ipv6.conf"
    fi
}
