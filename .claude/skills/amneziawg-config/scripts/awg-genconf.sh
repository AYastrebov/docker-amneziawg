#!/usr/bin/env bash
#
# awg-genconf.sh — Generate AmneziaWG configs (1.5 / 2.0 / 3.0 / 3.1).
#
# Emits either a complete set of configs (server + every peer, with keys), or
# just the obfuscation parameter block for pasting into configs you already
# have. Every protocol and performance constraint is enforced; see the
# "Constraints" comment below and references/parameters.md.
#
# Usage:
#   awg-genconf.sh --endpoint vpn.example.com:51820 [options]
#   awg-genconf.sh --params-only [--format conf|compose|env] [options]
#
# Common options:
#   --version 1.5|2.0|3.0|3.1   Protocol mode                    (default 2.0)
#   --peers N | name1,name2     Peer count or names              (default 1)
#   --endpoint HOST:PORT        Server address peers dial        (required unless --params-only)
#   --subnet 10.13.13.0         Tunnel subnet, .1 is the server  (default 10.13.13.0)
#   --port N                    Server ListenPort                (default from --endpoint, else 51820)
#   --dns IP[,IP]               DNS for peers                    (default 1.1.1.1,1.0.0.1)
#   --allowed-ips CIDR[,CIDR]   Peer AllowedIPs                  (default 0.0.0.0/0)
#   --mtu N                     Tunnel MTU                       (default 1280)
#   --outdir DIR                Where to write configs           (default ./awg-configs)
#   --nat-iface IFACE           Emit PostUp/PostDown masquerade rules for IFACE.
#                               Without it the rules are written commented out,
#                               since peers default to AllowedIPs 0.0.0.0/0 and
#                               would otherwise blackhole after handshaking.
#   --params-only               Emit only the obfuscation block
#   --format conf|compose|env   Output shape for --params-only   (default conf)
#
# Obfuscation toggles:
#   --random-trailers on|off    AWG 3.1 trailers        (default: on under 3.1)
#   --disable-cookies on|off    AWG 3.1 cookie suppression        (default off)
#   --content-padding on|off    ContentPaddingAddition            (default off — see below)
#   --h-format range|compat     H1-H4 as 2.0 ranges, or 1,2,3,4   (default range)
#   --no-psk                    Skip per-peer pre-shared keys     (default: PSKs on)
#
# Constraints enforced
# --------------------
# Protocol:
#   Jmin < Jmax <= 1280; S1 <= 1132; S2 <= 1188; S3 <= 64; S4 <= 32
#   S1 + 56 != S2 (else padded init and response are the same length)
#   H1-H4 >= 5, unique, non-overlapping (2.0+ range format; 1.5 single ints)
#   S1-S4 >= 12 when HeaderProtectionKey is set (the nonce is the first 12
#     bytes of the S-prefix), enforced by the kernel module in netlink.c
#   RejectAfterTime.lo > RekeyAfterTime.hi and > KeepaliveTimeout.lo + RekeyTimeout.lo
#
# Performance (measured; see references/performance.md):
#   S1 == S2 == S3 == S4 whenever RandomTrailers is on with wide 2.0+ H ranges.
#     Trailers relax the receiver's type check from "== expected_len" to ">=",
#     so the H range test becomes the only discriminator. Unequal S values make
#     three of four branches read the type field at the wrong offset; garbage
#     lands in a 50M-wide range ~1.16% of the time each, so ~3.5% of transport
#     packets are dropped. Measured: upload 100 -> 2 Mbit/s.
#   S4 <= 20, so a full-size packet still fits a 1500-byte path at MTU 1420
#     (per-packet overhead is 60 + S4 over IPv4).
#   ContentPaddingAddition off by default: ~22% of download throughput, because
#     randomizing every datagram length defeats UDP_GRO batching on userspace
#     clients. It also takes precedence over RandomTrailers on send while the
#     receiver still runs the loose match — the worst of both.

set -euo pipefail

version="2.0"; peers_arg="1"; endpoint=""; subnet="10.13.13.0"; port=""
dns="1.1.1.1,1.0.0.1"; allowed_ips="0.0.0.0/0"; mtu="1280"; outdir="./awg-configs"
params_only=0; format="conf"; random_trailers=""; disable_cookies="off"
content_padding="off"; h_format="range"; use_psk=1; nat_iface=""
ep_host=""; ep_port=""

die() { echo "error: $*" >&2; exit 2; }
# Without this, a flag whose value was forgotten dies on `set -u` with
# "$2: unbound variable", which reads as a script crash rather than a typo.
need_val() { [ $# -ge 2 ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) need_val "$@"; version="$2"; shift 2 ;;
        --peers) need_val "$@"; peers_arg="$2"; shift 2 ;;
        --endpoint) need_val "$@"; endpoint="$2"; shift 2 ;;
        --subnet) need_val "$@"; subnet="$2"; shift 2 ;;
        --port) need_val "$@"; port="$2"; shift 2 ;;
        --dns) need_val "$@"; dns="$2"; shift 2 ;;
        --allowed-ips) need_val "$@"; allowed_ips="$2"; shift 2 ;;
        --mtu) need_val "$@"; mtu="$2"; shift 2 ;;
        --outdir) need_val "$@"; outdir="$2"; shift 2 ;;
        --params-only) params_only=1; shift ;;
        --format) need_val "$@"; format="$2"; shift 2 ;;
        --random-trailers) need_val "$@"; random_trailers="$2"; shift 2 ;;
        --disable-cookies) need_val "$@"; disable_cookies="$2"; shift 2 ;;
        --content-padding) need_val "$@"; content_padding="$2"; shift 2 ;;
        --h-format) need_val "$@"; h_format="$2"; shift 2 ;;
        --nat-iface) need_val "$@"; nat_iface="$2"; shift 2 ;;
        --no-psk) use_psk=0; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case "$version" in 1.5|2.0|3.0|3.1) ;; *) die "--version must be 1.5, 2.0, 3.0 or 3.1" ;; esac
case "$format" in conf|compose|env) ;; *) die "--format must be conf, compose or env" ;; esac
case "$h_format" in range|compat) ;; *) die "--h-format must be range or compat" ;; esac

case "$version" in 3.0|3.1) has_3x=1 ;; *) has_3x=0 ;; esac
case "$version" in 2.0|3.0|3.1) has_2x=1 ;; *) has_2x=0 ;; esac

# 3.1 is "the 3.0 parameter set plus RandomTrailers". DisableCookies is never
# implied: it gives up WireGuard's DoS mitigation and, unlike RandomTrailers,
# does not have to match between ends, so it stays a deliberate choice.
if [ "$version" = "3.1" ] && [ -z "$random_trailers" ]; then random_trailers="on"; fi
[ -n "$random_trailers" ] || random_trailers="off"
for sw in "$random_trailers" "$disable_cookies" "$content_padding"; do
    case "$sw" in on|off) ;; *) die "toggles must be on or off" ;; esac
done

if [ "$content_padding" = "on" ] && [ "$random_trailers" = "on" ]; then
    die "ContentPaddingAddition suppresses RandomTrailers on send but not on receive.
       Pick one. See references/performance.md."
fi
# ContentPaddingAddition only exists in the 3.x parameter set. Silently dropping
# the flag would hand back a config that looks like it honoured the request.
if [ "$content_padding" = "on" ] && [ "$has_3x" = 0 ]; then
    die "--content-padding requires --version 3.0 or 3.1 (ContentPaddingAddition is a 3.x key; got $version)"
fi
if [ "$random_trailers" = "on" ] && [ "$has_2x" = 0 ]; then
    echo "note: RandomTrailers with AWG 1.5 — single-integer H values keep type" >&2
    echo "      detection unambiguous, so equal S values are not required here." >&2
fi
if [ "$params_only" = 0 ] && [ -z "$endpoint" ]; then
    die "--endpoint HOST:PORT is required (or use --params-only)"
fi

# Split HOST:PORT. A bare host writes an Endpoint that awg-quick rejects, and a
# bare IPv6 address is worse: "${endpoint##*:}" would silently yield the last
# hextet as the ListenPort. Demand an explicit port, bracketed for IPv6.
if [ -n "$endpoint" ]; then
    case "$endpoint" in
        \[*\]:*)  ep_host="${endpoint%]:*}"; ep_host="${ep_host#\[}"
                  ep_port="${endpoint##*]:}" ;;
        *:*:*)    die "IPv6 endpoint needs brackets and a port: --endpoint '[$endpoint]:51820'" ;;
        *:*)      ep_host="${endpoint%:*}"; ep_port="${endpoint##*:}" ;;
        *)        die "--endpoint must be HOST:PORT (got '$endpoint')" ;;
    esac
    [ -n "$ep_host" ] || die "--endpoint has an empty host: '$endpoint'"
    case "$ep_port" in
        ''|*[!0-9]*) die "--endpoint port must be numeric (got '$ep_port')" ;;
    esac
    { [ "$ep_port" -ge 1 ] && [ "$ep_port" -le 65535 ]; } \
        || die "--endpoint port out of range: $ep_port"
fi

# ListenPort defaults to the port peers dial, which is right unless the server
# sits behind a port-forward; --port overrides it.
[ -n "$port" ] || port="${ep_port:-51820}"
case "$port" in
    ''|*[!0-9]*) die "--port must be numeric (got '$port')" ;;
esac

# ---------------------------------------------------------------- randomness
rand_range() {   # inclusive [min,max]; $RANDOM is 15 bits so chain two
    local min=$1 max=$2 span=$(( $2 - $1 + 1 ))
    echo $(( min + ( ( (RANDOM << 15) | RANDOM ) % span ) ))
}
rand_b64_32() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }

# Key helpers. Prefer the real tools; fall back to Python so the skill still
# works on a box that has no wireguard userspace installed.
gen_privkey() {
    if command -v awg >/dev/null 2>&1; then awg genkey
    elif command -v wg >/dev/null 2>&1; then wg genkey
    else python3 -c 'import os,base64
k=bytearray(os.urandom(32)); k[0]&=248; k[31]&=127; k[31]|=64
print(base64.b64encode(bytes(k)).decode())'
    fi
}
gen_pubkey() {   # private key on stdin
    if command -v awg >/dev/null 2>&1; then awg pubkey
    elif command -v wg >/dev/null 2>&1; then wg pubkey
    else python3 -c 'import sys,base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization
p=X25519PrivateKey.from_private_bytes(base64.b64decode(sys.stdin.read().strip()))
print(base64.b64encode(p.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode())' \
    || die "need awg, wg, or python3 with the cryptography package to derive public keys"
    fi
}

# ------------------------------------------------------------ S1..S4 values
# With RandomTrailers on and wide H ranges, all four must be equal or ~3.5% of
# transport packets are dropped. Equal S1/S2 would normally re-expose plain
# WireGuard's fixed 56-byte init/response size gap, which is why they are
# otherwise varied — but trailers randomize handshake lengths anyway, so that
# gap is already gone. Do not "restore" varied S values under trailers.
need_equal_s=0
if [ "$random_trailers" = "on" ] && [ "$has_2x" = 1 ]; then need_equal_s=1; fi

s_floor=4; [ "$has_3x" = 1 ] && s_floor=12

if [ "$need_equal_s" = 1 ]; then
    S1=$(rand_range "$s_floor" 20); S2=$S1; S3=$S1; S4=$S1
elif [ "$has_2x" = 1 ]; then
    while :; do
        S1=$(rand_range 15 150); S2=$(rand_range 15 150)
        [ $((S1 + 56)) -ne "$S2" ] && break
    done
    if [ "$has_3x" = 1 ]; then
        [ "$S1" -lt 12 ] && S1=$(rand_range 12 150)
        [ "$S2" -lt 12 ] && S2=$(rand_range 12 150)
        while [ $((S1 + 56)) -eq "$S2" ]; do S2=$(rand_range 12 150); done
    fi
    S3=$(rand_range "$s_floor" 55)
    S4=$(rand_range "$s_floor" 20)
else
    S1=$(rand_range 15 150)
    while :; do S2=$(rand_range 15 150); [ $((S1 + 56)) -ne "$S2" ] && break; done
    S3=0; S4=0
fi

JC=$(rand_range 3 8); JMIN=$(rand_range 40 80); JMAX=$(rand_range $((JMIN + 50)) 250)

# ------------------------------------------------------------------ H1..H4
# One range per quadrant of the 32-bit space so they can never overlap. The
# Amnezia app uses the range *format* to recognise AWG 2.0 — single integers
# make it report 1.5 — which is why range is the default even though upstream
# suggests 1,2,3,4 when header protection is doing the hiding anyway.
if [ "$has_2x" = 1 ] && [ "$h_format" = "range" ]; then
    w=50000000
    h1=$(rand_range 5 $((1073741823 - w)));          H1="${h1}-$((h1 + w))"
    h2=$(rand_range 1073741824 $((2147483647 - w))); H2="${h2}-$((h2 + w))"
    h3=$(rand_range 2147483648 $((3221225471 - w))); H3="${h3}-$((h3 + w))"
    h4=$(rand_range 3221225472 $((4294967295 - w))); H4="${h4}-$((h4 + w))"
elif [ "$has_2x" = 1 ]; then
    H1=1; H2=2; H3=3; H4=4       # compat: disables custom headers entirely
else
    H1=$(rand_range 5 1073741823); H2=$(rand_range 1073741824 2147483647)
    H3=$(rand_range 2147483648 3221225471); H4=$(rand_range 3221225472 4294967295)
fi

# I1: a QUIC Initial packet (RFC 9000 s14.1), the same disguise the Amnezia app
# ships by default. Swap it via references/parameters.md if you want DNS/DTLS.
I1=""
[ "$has_2x" = 1 ] && I1='<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>'

# ------------------------------------------------------------ AWG 3.x block
if [ "$has_3x" = 1 ]; then
    # A ChaCha20 symmetric key — 32 full-entropy bytes. Deliberately NOT
    # `awg genkey`, whose output is bit-clamped for Curve25519.
    HPK=$(rand_b64_32)
    if [ "$content_padding" = "on" ]; then
        cp_lo=$(rand_range 16 72); CPA="${cp_lo}-$(rand_range $((cp_lo + 8)) 128)"
    else
        CPA="0"
    fi
    rt_lo=$(rand_range 4 6);   REKEY_TIMEOUT="${rt_lo}-$((rt_lo + $(rand_range 1 4)))"
    kt_lo=$(rand_range 8 14);  KEEPALIVE_TIMEOUT="${kt_lo}-$((kt_lo + $(rand_range 2 8)))"
    ra_lo=$(rand_range 100 120); ra_hi=$((ra_lo + $(rand_range 10 25)))
    REKEY_AFTER_TIME="${ra_lo}-${ra_hi}"
    floor=$(( ra_hi + ${KEEPALIVE_TIMEOUT##*-} + ${REKEY_TIMEOUT##*-} + 15 ))
    [ "$floor" -lt 170 ] && floor=170
    REJECT_AFTER_TIME="${floor}-$((floor + $(rand_range 10 25)))"
    mh_lo=$(rand_range 12 18); MAX_HANDSHAKE="${mh_lo}-$((mh_lo + $(rand_range 2 10)))"
fi

# ------------------------------------------------------------- self-checks
[ "$JMIN" -lt "$JMAX" ] || die "BUG: Jmin >= Jmax"
[ "$JMAX" -le 1280 ]   || die "BUG: Jmax > 1280"
[ "$S1" -le 1132 ]     || die "BUG: S1 > 1132"
[ "$S2" -le 1188 ]     || die "BUG: S2 > 1188"
[ "$S3" -le 64 ]       || die "BUG: S3 > 64"
[ "$S4" -le 20 ]       || die "BUG: S4 > 20 (fragments at the default 1420 MTU)"
[ $((S1 + 56)) -ne "$S2" ] || [ "$need_equal_s" = 1 ] || die "BUG: S1+56 == S2"
if [ "$need_equal_s" = 1 ]; then
    { [ "$S1" = "$S2" ] && [ "$S2" = "$S3" ] && [ "$S3" = "$S4" ]; } \
        || die "BUG: RandomTrailers needs S1==S2==S3==S4"
fi
if [ "$has_3x" = 1 ]; then
    for sv in "$S1" "$S2" "$S3" "$S4"; do
        [ "$sv" -ge 12 ] || die "BUG: S=$sv < 12 with HeaderProtectionKey"
    done
    [ "${REJECT_AFTER_TIME%%-*}" -gt "${REKEY_AFTER_TIME##*-}" ] \
        || die "BUG: RejectAfterTime.lo <= RekeyAfterTime.hi"
    [ "${#HPK}" -eq 44 ] || die "BUG: HeaderProtectionKey is not 32 bytes of base64"
fi

# ------------------------------------------------------------------ output
# The obfuscation block, in file order. I1-I5 must sit in [Interface] and ahead
# of any [Peer] section: the Amnezia app only inspects [Interface] when it
# decides which protocol version a config is.
awg_block() {
    printf 'Jc = %s\nJmin = %s\nJmax = %s\nS1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' \
        "$JC" "$JMIN" "$JMAX" "$S1" "$S2" "$S3" "$S4"
    printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$H1" "$H2" "$H3" "$H4"
    [ -n "$I1" ] && printf 'I1 = %s\n' "$I1"
    if [ "$has_3x" = 1 ]; then
        printf 'HeaderProtectionKey = %s\n' "$HPK"
        [ "$CPA" != "0" ] && printf 'ContentPaddingAddition = %s\n' "$CPA"
        printf 'RekeyAfterTime = %s\nRekeyTimeout = %s\nRejectAfterTime = %s\n' \
            "$REKEY_AFTER_TIME" "$REKEY_TIMEOUT" "$REJECT_AFTER_TIME"
        printf 'KeepaliveTimeout = %s\nMaxHandshakeAttempts = %s\n' \
            "$KEEPALIVE_TIMEOUT" "$MAX_HANDSHAKE"
    fi
    [ "$random_trailers" = "on" ] && printf 'RandomTrailers = on\n'
    [ "$disable_cookies" = "on" ] && printf 'DisableCookies = on\n'
    return 0
}

emit_kv() {   # $1 conf key, $2 env key, $3 value
    case "$format" in
        conf)    printf '%s = %s\n' "$1" "$3" ;;
        compose) printf '      - %s=%s\n' "$2" "$3" ;;
        env)     printf 'export %s=%q\n' "$2" "$3" ;;
    esac
}

emit_params_only() {
    case "$format" in
        conf)    printf '# AmneziaWG %s obfuscation — paste into [Interface] on the server and EVERY peer\n' "$version" ;;
        compose) printf '# AmneziaWG %s obfuscation parameters\n      - AWG_VERSION=%s\n' "$version" "$version" ;;
        env)     printf '# AmneziaWG %s obfuscation parameters\nexport AWG_VERSION=%s\n' "$version" "$version" ;;
    esac
    emit_kv Jc AWG_JC "$JC"; emit_kv Jmin AWG_JMIN "$JMIN"; emit_kv Jmax AWG_JMAX "$JMAX"
    emit_kv S1 AWG_S1 "$S1"; emit_kv S2 AWG_S2 "$S2"
    emit_kv S3 AWG_S3 "$S3"; emit_kv S4 AWG_S4 "$S4"
    emit_kv H1 AWG_H1 "$H1"; emit_kv H2 AWG_H2 "$H2"
    emit_kv H3 AWG_H3 "$H3"; emit_kv H4 AWG_H4 "$H4"
    [ -n "$I1" ] && emit_kv I1 AWG_I1 "$I1"
    if [ "$has_3x" = 1 ]; then
        emit_kv HeaderProtectionKey AWG_HEADER_PROTECTION_KEY "$HPK"
        # A pinned 0 is what turns off a generator that would otherwise invent
        # its own range, so it is worth emitting for compose/env even though a
        # .conf simply omits the key.
        if [ "$CPA" != "0" ] || [ "$format" != "conf" ]; then
            emit_kv ContentPaddingAddition AWG_CONTENT_PADDING "$CPA"
        fi
        emit_kv RekeyAfterTime AWG_REKEY_AFTER_TIME "$REKEY_AFTER_TIME"
        emit_kv RekeyTimeout AWG_REKEY_TIMEOUT "$REKEY_TIMEOUT"
        emit_kv RejectAfterTime AWG_REJECT_AFTER_TIME "$REJECT_AFTER_TIME"
        emit_kv KeepaliveTimeout AWG_KEEPALIVE_TIMEOUT "$KEEPALIVE_TIMEOUT"
        emit_kv MaxHandshakeAttempts AWG_MAX_HANDSHAKE_ATTEMPTS "$MAX_HANDSHAKE"
    fi
    [ "$random_trailers" = "on" ] && emit_kv RandomTrailers AWG_RANDOM_TRAILERS on
    [ "$disable_cookies" = "on" ] && emit_kv DisableCookies AWG_DISABLE_COOKIES on
    return 0
}

if [ "$params_only" = 1 ]; then
    emit_params_only
    exit 0
fi

# ------------------------------------------------------- full config output
case "$peers_arg" in
    ''|*[!0-9]*) IFS=',' read -r -a PEER_NAMES <<< "$peers_arg" ;;
    *) PEER_NAMES=(); for i in $(seq 1 "$peers_arg"); do PEER_NAMES+=("peer$i"); done ;;
esac
[ "${#PEER_NAMES[@]}" -ge 1 ] || die "no peers requested"
# Peers occupy .2 upwards in a /24, so .254 is the last usable host and 253 is
# the ceiling. Without this, larger counts silently emit .255 and then invalid
# addresses above .255.
[ "${#PEER_NAMES[@]}" -le 253 ] \
    || die "${#PEER_NAMES[@]} peers exceeds the 253 a /24 holds; use a larger --subnet scheme"

net="${subnet%.*}"                       # 10.13.13.0 -> 10.13.13
[ "$net" != "$subnet" ] || die "--subnet must look like 10.13.13.0"

mkdir -p "$outdir"
chmod 700 "$outdir"

SRV_PRIV=$(gen_privkey); SRV_PUB=$(printf '%s' "$SRV_PRIV" | gen_pubkey)

server_conf="$outdir/wg0.conf"
{
    printf '[Interface]\n'
    printf 'Address = %s.1/24\n' "$net"
    printf 'ListenPort = %s\n' "$port"
    printf 'PrivateKey = %s\n' "$SRV_PRIV"
    printf 'MTU = %s\n' "$mtu"
    # Peers below get AllowedIPs 0.0.0.0/0 by default, so without IP forwarding
    # and NAT the tunnel handshakes and then blackholes every packet. Emit the
    # rules when the egress interface is known; otherwise leave a commented
    # template rather than guessing an interface name that is wrong on most
    # hosts (eth0 on cloud images, ens3/enp1s0 elsewhere).
    if [ -n "$nat_iface" ]; then
        printf 'PostUp = iptables -A FORWARD -i %%i -j ACCEPT; iptables -A FORWARD -o %%i -j ACCEPT; iptables -t nat -A POSTROUTING -o %s -j MASQUERADE\n' "$nat_iface"
        printf 'PostDown = iptables -D FORWARD -i %%i -j ACCEPT; iptables -D FORWARD -o %%i -j ACCEPT; iptables -t nat -D POSTROUTING -o %s -j MASQUERADE\n' "$nat_iface"
    else
        printf '# No routing/NAT configured. Peers use AllowedIPs %s, so unless this host\n' "$allowed_ips"
        printf '# already forwards and masquerades, the tunnel will connect and then drop all\n'
        printf '# traffic. Re-run with --nat-iface <egress-interface>, or uncomment and edit:\n'
        printf '#PostUp = iptables -A FORWARD -i %%i -j ACCEPT; iptables -A FORWARD -o %%i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE\n'
        printf '#PostDown = iptables -D FORWARD -i %%i -j ACCEPT; iptables -D FORWARD -o %%i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE\n'
    fi
    printf '\n# AmneziaWG %s obfuscation — identical on every peer\n' "$version"
    awg_block
} > "$server_conf"

for idx in "${!PEER_NAMES[@]}"; do
    name="${PEER_NAMES[$idx]}"
    ip="$net.$((idx + 2))"
    priv=$(gen_privkey); pub=$(printf '%s' "$priv" | gen_pubkey)
    psk=""; [ "$use_psk" = 1 ] && psk=$(rand_b64_32)

    # Server side: one [Peer] block per client.
    {
        printf '\n[Peer]\n# %s\nPublicKey = %s\n' "$name" "$pub"
        [ -n "$psk" ] && printf 'PresharedKey = %s\n' "$psk"
        printf 'AllowedIPs = %s/32\n' "$ip"
    } >> "$server_conf"

    # Peer side. The obfuscation block stays in [Interface], above [Peer].
    {
        printf '[Interface]\n'
        printf 'Address = %s/32\n' "$ip"
        printf 'PrivateKey = %s\n' "$priv"
        printf 'DNS = %s\n' "$dns"
        printf 'MTU = %s\n' "$mtu"
        printf '\n# AmneziaWG %s obfuscation — identical on server and every peer\n' "$version"
        awg_block
        printf '\n[Peer]\nPublicKey = %s\n' "$SRV_PUB"
        [ -n "$psk" ] && printf 'PresharedKey = %s\n' "$psk"
        printf 'Endpoint = %s\n' "$endpoint"
        printf 'AllowedIPs = %s\n' "$allowed_ips"
        printf 'PersistentKeepalive = 25\n'
    } > "$outdir/$name.conf"
    chmod 600 "$outdir/$name.conf"
done
chmod 600 "$server_conf"

cat >&2 <<EOF
Wrote AWG $version configs to $outdir/
  server : wg0.conf (${#PEER_NAMES[@]} peer(s), listening on $port)
  peers  : $(printf '%s.conf ' "${PEER_NAMES[@]}")

S1=$S1 S2=$S2 S3=$S3 S4=$S4  Jc=$JC Jmin=$JMIN Jmax=$JMAX  MTU=$mtu
RandomTrailers=$random_trailers  DisableCookies=$disable_cookies  ContentPadding=${CPA:-n/a}

Every peer must keep the obfuscation block byte-for-byte identical to the
server's. Changing any of S/H/I later invalidates configs already handed out.
Verify with:  awg-lint.py $server_conf $outdir/${PEER_NAMES[0]}.conf
EOF

if [ -z "$nat_iface" ]; then
    cat >&2 <<EOF

Routing is NOT set up. Peers use AllowedIPs $allowed_ips, so the server also needs:
  sysctl -w net.ipv4.ip_forward=1        (persist in /etc/sysctl.d/)
  the PostUp/PostDown rules commented at the top of wg0.conf, with your real
  egress interface — or re-run with --nat-iface <interface>
Without both, the tunnel handshakes and then drops all forwarded traffic.
EOF
fi
