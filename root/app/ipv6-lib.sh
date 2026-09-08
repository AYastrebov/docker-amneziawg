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
