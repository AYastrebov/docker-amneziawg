#!/usr/bin/env bash
#
# gen-awg-params.sh — Generate a valid AmneziaWG obfuscation parameter set.
#
# Usage:
#   ./gen-awg-params.sh [--version 2.0|3.0|3.1|1.5] [--format compose|env|conf]
#                       [--random-trailers on|off] [--disable-cookies on|off]
#
# Defaults: --version 2.0 --format compose
#
# --version 3.1 implies --random-trailers on. DisableCookies is never enabled
# implicitly: it gives up WireGuard's DoS mitigation and, unlike RandomTrailers,
# does not have to match between ends.
#
# Output is suitable for pasting into docker-compose.yml (compose), shell
# `export` lines (env), or directly into a .conf [Interface] block (conf).
#
# All constraints are enforced:
#   - Jmin < Jmax, Jmax <= 1280
#   - S1 <= 1132, S2 <= 1188, S1+56 != S2
#   - S3 <= 64, S4 <= 32 (zero for AWG 1.5)
#   - H1..H4: all >= 5, all unique, non-overlapping ranges from distinct
#     quadrants of the 32-bit space (AWG 2.0); single integers (AWG 1.5)
#   - I1: default QUIC Initial packet per RFC 9000 (AWG 2.0+); empty (1.5)
#   - S1..S4 >= 12 for AWG 3.x (HeaderProtection reads its nonce from the first
#     12 bytes of the S-padding)
#   - RejectAfterTime.lo > RekeyAfterTime.hi and > KeepaliveTimeout.lo +
#     RekeyTimeout.lo (amneziawg-go device/timers.go)

set -euo pipefail

version="2.0"
format="compose"
random_trailers=""
disable_cookies=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --format)  format="$2";  shift 2 ;;
        --random-trailers) random_trailers="$2"; shift 2 ;;
        --disable-cookies) disable_cookies="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

case "$version" in 2.0|3.0|3.1|1.5) ;; *) echo "version must be 2.0, 3.0, 3.1 or 1.5" >&2; exit 2 ;; esac
case "$format"  in compose|env|conf) ;; *) echo "format must be compose|env|conf" >&2; exit 2 ;; esac

# AWG 3.x carries the header-protection/timer parameter set. 2.0+ carries the
# H1-H4 range format and I1-I5 signatures; 3.x builds on 2.0 and keeps both.
case "$version" in 3.0|3.1) has_3x=1 ;; *) has_3x=0 ;; esac
case "$version" in 2.0|3.0|3.1) has_2x=1 ;; *) has_2x=0 ;; esac

# --version 3.1 is a preset for "3.0 params plus RandomTrailers".
[ "$version" = "3.1" ] && [ -z "$random_trailers" ] && random_trailers="on"
for sw in "$random_trailers" "$disable_cookies"; do
    case "$sw" in ""|on|off) ;; *) echo "switches must be on or off" >&2; exit 2 ;; esac
done

# Portable random integer in [min, max] inclusive.
rand_range() {
    local min=$1 max=$2 span
    span=$(( max - min + 1 ))
    # $RANDOM is 15 bits; chain two for a 30-bit value then modulo.
    echo $(( min + ( ( (RANDOM << 15) | RANDOM ) % span ) ))
}

JC=$(rand_range 3 8)
JMIN=$(rand_range 40 80)
JMAX=$(rand_range $((JMIN + 50)) 250)

# S1, S2 with S1+56 != S2 invariant.
while :; do
    S1=$(rand_range 15 150)
    S2=$(rand_range 15 150)
    [ $((S1 + 56)) -ne "$S2" ] && break
done

if [ "$has_3x" = 1 ]; then
    # AWG 3.x: S1..S4 must all be >= 12 — HeaderProtection reads its nonce from
    # the first 12 bytes of the S-padding.
    S3=$(rand_range 12 55)
    S4=$(rand_range 12 27)
    [ "$S1" -lt 12 ] && S1=$(rand_range 12 150)
    [ "$S2" -lt 12 ] && S2=$(rand_range 12 150)
    # Re-check the S1+56 invariant after any bump above.
    while [ $((S1 + 56)) -eq "$S2" ]; do S2=$(rand_range 12 150); done
elif [ "$version" = "2.0" ]; then
    S3=$(rand_range 8 55)
    S4=$(rand_range 4 27)
else
    S3=0
    S4=0
fi

# H1..H4: split the 32-bit space into 4 quadrants, pick one range per quadrant.
# Range width: 50_000_000 (~1.2% of quadrant). Width is identical to what the
# container generates so the Amnezia client recognizes the values as AWG 2.0.
q1_lo=5;          q1_hi=1073741823
q2_lo=1073741824; q2_hi=2147483647
q3_lo=2147483648; q3_hi=3221225471
q4_lo=3221225472; q4_hi=4294967295
range_width=50000000

if [ "$has_2x" = 1 ]; then
    # Pick a starting value in each quadrant, then build a range of width 50M.
    h1_start=$(rand_range $q1_lo $((q1_hi - range_width)))
    h2_start=$(rand_range $q2_lo $((q2_hi - range_width)))
    h3_start=$(rand_range $q3_lo $((q3_hi - range_width)))
    h4_start=$(rand_range $q4_lo $((q4_hi - range_width)))
    H1="${h1_start}-$((h1_start + range_width))"
    H2="${h2_start}-$((h2_start + range_width))"
    H3="${h3_start}-$((h3_start + range_width))"
    H4="${h4_start}-$((h4_start + range_width))"
else
    # AWG 1.5: single integers, all unique, all >= 5.
    H1=$(rand_range $q1_lo $q1_hi)
    H2=$(rand_range $q2_lo $q2_hi)
    H3=$(rand_range $q3_lo $q3_hi)
    H4=$(rand_range $q4_lo $q4_hi)
fi

# I1 default for 2.0+: QUIC Initial (RFC 9000) — matches container default.
if [ "$has_2x" = 1 ]; then
    I1='<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>'
else
    I1=""
fi

# AWG 3.x parameter set. Ranges mirror what the container generates so a
# hand-pinned set and a container-generated one look alike.
if [ "$has_3x" = 1 ]; then
    # Shared symmetric key: 32 full-entropy random bytes, base64. This is a
    # ChaCha20 header-protection key, so it must NOT be a bit-clamped
    # Curve25519 private key (`awg genkey`) — plain random bytes are correct.
    HPK=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

    cp_lo=$(rand_range 16 72)
    CONTENT_PADDING="${cp_lo}-$(rand_range $((cp_lo + 8)) 128)"

    rt_lo=$(rand_range 4 6)
    REKEY_TIMEOUT="${rt_lo}-$((rt_lo + $(rand_range 1 4)))"

    kt_lo=$(rand_range 8 14)
    KEEPALIVE_TIMEOUT="${kt_lo}-$((kt_lo + $(rand_range 2 8)))"

    ra_lo=$(rand_range 100 120)
    ra_hi=$((ra_lo + $(rand_range 10 25)))
    REKEY_AFTER_TIME="${ra_lo}-${ra_hi}"

    # RejectAfterTime.lo must clear both RekeyAfterTime.hi and
    # KeepaliveTimeout.lo + RekeyTimeout.lo, with headroom.
    floor=$(( ra_hi + ${KEEPALIVE_TIMEOUT##*-} + ${REKEY_TIMEOUT##*-} + 15 ))
    [ "$floor" -lt 170 ] && floor=170
    REJECT_AFTER_TIME="${floor}-$((floor + $(rand_range 10 25)))"

    mh_lo=$(rand_range 12 18)
    MAX_HANDSHAKE_ATTEMPTS="${mh_lo}-$((mh_lo + $(rand_range 2 10)))"
fi

# Key naming differs per format:
#   compose/env: AWG_S1, AWG_H1, ...  (what the container env vars are called)
#   conf:        S1, H1, ...           (what goes in the wireguard .conf file)
emit() {
    local env_key=$1 conf_key=$2 v=$3
    case "$format" in
        compose) printf '      - %s=%s\n' "$env_key"  "$v" ;;
        env)     printf 'export %s=%q\n' "$env_key"   "$v" ;;
        conf)    printf '%s = %s\n'      "$conf_key"  "$v" ;;
    esac
}

case "$format" in
    compose) printf '# AmneziaWG %s obfuscation parameters (pin these to reproduce this exact setup)\n' "$version" ;;
    env)     printf '# AmneziaWG %s obfuscation parameters\n' "$version" ;;
    conf)    printf '# AWG %s obfuscation parameters — insert in [Interface] of every .conf (server and peers)\n' "$version" ;;
esac

# AWG_VERSION is an env var only — there's no such key in the .conf file.
case "$format" in
    compose) printf '      - AWG_VERSION=%s\n' "$version" ;;
    env)     printf 'export AWG_VERSION=%s\n' "$version" ;;
esac

emit AWG_JC   Jc    "$JC"
emit AWG_JMIN Jmin  "$JMIN"
emit AWG_JMAX Jmax  "$JMAX"
emit AWG_S1   S1    "$S1"
emit AWG_S2   S2    "$S2"
emit AWG_S3   S3    "$S3"
emit AWG_S4   S4    "$S4"
emit AWG_H1   H1    "$H1"
emit AWG_H2   H2    "$H2"
emit AWG_H3   H3    "$H3"
emit AWG_H4   H4    "$H4"
[ -n "$I1" ] && emit AWG_I1 I1 "$I1"

if [ "$has_3x" = 1 ]; then
    emit AWG_HEADER_PROTECTION_KEY   HeaderProtectionKey    "$HPK"
    emit AWG_CONTENT_PADDING         ContentPaddingAddition "$CONTENT_PADDING"
    emit AWG_REKEY_AFTER_TIME        RekeyAfterTime         "$REKEY_AFTER_TIME"
    emit AWG_REKEY_TIMEOUT           RekeyTimeout           "$REKEY_TIMEOUT"
    emit AWG_REJECT_AFTER_TIME       RejectAfterTime        "$REJECT_AFTER_TIME"
    emit AWG_KEEPALIVE_TIMEOUT       KeepaliveTimeout       "$KEEPALIVE_TIMEOUT"
    emit AWG_MAX_HANDSHAKE_ATTEMPTS  MaxHandshakeAttempts   "$MAX_HANDSHAKE_ATTEMPTS"
fi

# AWG 3.1 interface switches — independent of the version above. Only "on" is
# emitted: the container omits the key for "off" rather than writing "= off"
# (off is the endpoint default), and a pinned set should match that.
[ "$random_trailers" = "on" ] && emit AWG_RANDOM_TRAILERS RandomTrailers "$random_trailers"
[ "$disable_cookies" = "on" ] && emit AWG_DISABLE_COOKIES DisableCookies "$disable_cookies"

# Sanity self-check
[ "$S1" -le 1132 ] || { echo "BUG: S1 > 1132" >&2; exit 1; }
[ "$S2" -le 1188 ] || { echo "BUG: S2 > 1188" >&2; exit 1; }
[ "$S3" -le 64 ]   || { echo "BUG: S3 > 64"   >&2; exit 1; }
[ "$S4" -le 32 ]   || { echo "BUG: S4 > 32"   >&2; exit 1; }
[ "$JMIN" -lt "$JMAX" ] || { echo "BUG: Jmin >= Jmax" >&2; exit 1; }
[ "$JMAX" -le 1280 ]    || { echo "BUG: Jmax > 1280"  >&2; exit 1; }
[ $((S1 + 56)) -ne "$S2" ] || { echo "BUG: S1+56 == S2" >&2; exit 1; }
if [ "$has_3x" = 1 ]; then
    for sv in "$S1" "$S2" "$S3" "$S4"; do
        [ "$sv" -ge 12 ] || { echo "BUG: S value $sv < 12 with HeaderProtectionKey set" >&2; exit 1; }
    done
    [ "${REJECT_AFTER_TIME%%-*}" -gt "${REKEY_AFTER_TIME##*-}" ] \
        || { echo "BUG: RejectAfterTime.lo <= RekeyAfterTime.hi" >&2; exit 1; }
    [ "${REJECT_AFTER_TIME%%-*}" -gt $(( ${KEEPALIVE_TIMEOUT%%-*} + ${REKEY_TIMEOUT%%-*} )) ] \
        || { echo "BUG: RejectAfterTime.lo <= KeepaliveTimeout.lo + RekeyTimeout.lo" >&2; exit 1; }
    [ "${#HPK}" -eq 44 ] || { echo "BUG: HeaderProtectionKey is not 32 bytes base64" >&2; exit 1; }
fi
