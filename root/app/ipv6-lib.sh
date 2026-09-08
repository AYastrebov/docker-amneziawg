#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # IP6_* globals are consumed by init-amneziawg-confs/run
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
    # 10# forces decimal: printf treats a leading zero (08) as octal and fails
    printf 'fd%02x:%02x%02x:0000::\n' "$((10#${a}))" "$((10#${b}))" "$((10#${c}))"
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
    # "off" is no IPv6 *egress*, not no IPv6: a bare "-i %i -j REJECT" would also
    # reject wg0 -> wg0 forwarding and make peers unreachable to each other over
    # IPv6 while IPv4 (ACCEPT) still allows it. Keep the intra-tunnel path open.
    local intra='ip6tables -A FORWARD -i %i -o %i -j ACCEPT'
    local reject="${intra}; ip6tables -A FORWARD -i %i -j REJECT --reject-with icmp6-adm-prohibited; ip6tables -A FORWARD -o %i -j REJECT --reject-with icmp6-adm-prohibited"
    # NAT only the tunnel prefix: the IPv4 rule is unqualified for historical
    # reasons, but on network_mode: host an unqualified -o eth+ would NAT66
    # every flow the host forwards.
    local masq="ip6tables -t nat -A POSTROUTING -s ${IP6_PREFIX}/64 -o eth+ -j MASQUERADE"
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
