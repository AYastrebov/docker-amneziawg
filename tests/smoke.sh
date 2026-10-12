#!/bin/bash
# Smoke tests for a freshly built image, run by the PR job of
# .github/workflows/docker-build.yml and locally:
#   docker build -t test-image . && bash tests/smoke.sh
# Lives here rather than inline in the workflow because GitHub Actions
# rejects a single `run:` step over 21,000 characters at load time (the run
# then shows zero jobs and "workflow file issue"), and this script is past it.
# The tunnel cannot come up without /dev/net/tun, so everything here checks
# config generation and service wiring, not traffic.
set -e
: "${GITHUB_STEP_SUMMARY:=/dev/null}"
export GITHUB_STEP_SUMMARY
cd "$(dirname "$0")/.."

# <container name> -> waits for init-amneziawg-confs to finish in it.
# "Configuration complete" is its last line, and a container is recreated
# for every scenario, so its log only ever holds this run.
wait_config() {
  for _ in $(seq 1 45); do
    docker logs "$1" 2>&1 | grep -q 'Configuration complete' && return 0
    sleep 2
  done
  echo "$1: container never finished config generation"; docker logs "$1"; exit 1
}

echo "## Smoke tests" >> "$GITHUB_STEP_SUMMARY"

# Check binaries exist
echo "### Binary check" >> "$GITHUB_STEP_SUMMARY"
docker run --rm test-image ls -la /usr/bin/awg /usr/bin/awg-quick /usr/bin/amneziawg-go /usr/bin/wg /usr/bin/wg-quick
echo "- Binaries present" >> "$GITHUB_STEP_SUMMARY"

# Check s6-overlay structure (all 4 services + branding)
echo "### s6-overlay structure" >> "$GITHUB_STEP_SUMMARY"
docker run --rm test-image sh -c '
  test -f /etc/s6-overlay/s6-rc.d/init-amneziawg-module/type && echo "init-amneziawg-module: OK"
  test -f /etc/s6-overlay/s6-rc.d/init-amneziawg-confs/type && echo "init-amneziawg-confs: OK"
  test -f /etc/s6-overlay/s6-rc.d/svc-dnsmasq/type && echo "svc-dnsmasq: OK"
  test -f /etc/s6-overlay/s6-rc.d/svc-amneziawg/type && echo "svc-amneziawg: OK"
  test -f /etc/s6-overlay/s6-rc.d/init-adduser/branding && echo "branding: OK"
'
echo "- All services registered" >> "$GITHUB_STEP_SUMMARY"

# Verify service types
echo "### Service types" >> "$GITHUB_STEP_SUMMARY"
docker run --rm test-image sh -c '
  echo "init-amneziawg-module: $(cat /etc/s6-overlay/s6-rc.d/init-amneziawg-module/type)"
  echo "init-amneziawg-confs: $(cat /etc/s6-overlay/s6-rc.d/init-amneziawg-confs/type)"
  echo "svc-dnsmasq: $(cat /etc/s6-overlay/s6-rc.d/svc-dnsmasq/type)"
  echo "svc-amneziawg: $(cat /etc/s6-overlay/s6-rc.d/svc-amneziawg/type)"
'
echo "- Service types verified" >> "$GITHUB_STEP_SUMMARY"

# Check dependencies
echo "### Dependency chain" >> "$GITHUB_STEP_SUMMARY"
docker run --rm test-image sh -c '
  test -f /etc/s6-overlay/s6-rc.d/init-amneziawg-module/dependencies.d/init-config && echo "module depends on init-config: OK"
  test -f /etc/s6-overlay/s6-rc.d/init-amneziawg-confs/dependencies.d/init-amneziawg-module && echo "confs depends on module: OK"
  test -f /etc/s6-overlay/s6-rc.d/svc-dnsmasq/dependencies.d/init-services && echo "dnsmasq depends on init-services: OK"
  # dnsmasq starts once wg0 has its address; started earlier it races
  # awg-quick. It also needs the base config init-amneziawg-confs writes,
  # which this dependency covers transitively.
  test -f /etc/s6-overlay/s6-rc.d/svc-dnsmasq/dependencies.d/svc-amneziawg && echo "dnsmasq depends on amneziawg: OK" \
    || { echo "svc-dnsmasq must depend on svc-amneziawg"; exit 1; }
  test ! -e /etc/s6-overlay/s6-rc.d/svc-amneziawg/dependencies.d/svc-dnsmasq \
    || { echo "svc-amneziawg must not depend on svc-dnsmasq (dependency cycle)"; exit 1; }
'
echo "- Dependency chain correct" >> "$GITHUB_STEP_SUMMARY"

# Check show-peer script and defaults
echo "### Scripts and defaults" >> "$GITHUB_STEP_SUMMARY"
docker run --rm test-image sh -c '
  test -x /app/show-peer && echo "show-peer: executable"
  test -f /defaults/server.conf && echo "server.conf template: present"
  test -f /defaults/peer.conf && echo "peer.conf template: present"
  test -f /build_version && cat /build_version
'
echo "- All defaults present" >> "$GITHUB_STEP_SUMMARY"

# Check dnsmasq binary (and that CoreDNS is gone)
echo "### dnsmasq" >> "$GITHUB_STEP_SUMMARY"
docker run --rm test-image dnsmasq --version | head -1
docker run --rm test-image sh -c '! command -v coredns' || { echo "coredns must not be in the image"; exit 1; }
echo "- dnsmasq binary present, CoreDNS removed" >> "$GITHUB_STEP_SUMMARY"

# Generate a real AWG 3.1 config set and check the keys land in the
# right sections. Tunnel activation is expected to fail on a CI
# runner; the confs are written by init-amneziawg-confs before that,
# and s6 keeps the container up either way.
echo "### AWG 3.1 config generation" >> "$GITHUB_STEP_SUMMARY"
docker rm -f awgci >/dev/null 2>&1 || true
docker run -d --name awgci --cap-add NET_ADMIN \
  -e PEERS=2 -e SERVERURL=ci.example.com -e INTERNAL_SUBNET=10.55.55.0 \
  -e AWG_VERSION=3.1 -e AWG_DISABLE_COOKIES=on \
  test-image >/dev/null
# Wait on the .png, not the .conf: the conf file exists from the
# moment the template heredoc runs, before the three awk passes that
# insert the signatures and the 3.x/3.1 keys. The png is the last
# thing generate_confs writes for a peer.
for _ in $(seq 1 45); do
  docker exec awgci test -f /config/peer2/peer2.png 2>/dev/null && break
  sleep 2
done
docker exec awgci test -f /config/peer2/peer2.png \
  || { echo "AWG 3.1: peer confs were never generated"; docker logs awgci; exit 1; }

# Every key must sit in [Interface], i.e. above the first [Peer] line.
check_iface_key() {
  conf=$1; key=$2
  docker exec awgci awk -v k="$key" '
    /^\[Peer\]/ { exit }
    $1 == k { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$conf" || { echo "AWG 3.1: $key missing from [Interface] of $conf"; docker exec awgci cat "$conf"; exit 1; }
}
for conf in /config/wg_confs/wg0.conf /config/peer1/peer1.conf /config/peer2/peer2.conf; do
  for key in RandomTrailers DisableCookies HeaderProtectionKey; do
    check_iface_key "$conf" "$key"
  done
  echo "  $conf: 3.1 switches + header protection in [Interface]"
done

# HeaderProtectionKey must be identical everywhere; the switches must be on.
hpk_server=$(docker exec awgci awk '/^HeaderProtectionKey/ {print $3; exit}' /config/wg_confs/wg0.conf)
hpk_peer=$(docker exec awgci awk '/^HeaderProtectionKey/ {print $3; exit}' /config/peer1/peer1.conf)
if [ -z "$hpk_server" ] || [ "$hpk_server" != "$hpk_peer" ]; then
  echo "AWG 3.1: HeaderProtectionKey differs between server and peer"; exit 1
fi
docker exec awgci grep -q '^RandomTrailers = on$' /config/peer1/peer1.conf \
  || { echo "AWG 3.1: RandomTrailers not set to on"; exit 1; }
docker exec awgci grep -q '^DisableCookies = on$' /config/peer1/peer1.conf \
  || { echo "AWG 3.1: DisableCookies not set to on"; exit 1; }

# Default 2.0 must not emit the 3.x keys.
docker rm -f awgci >/dev/null 2>&1 || true
docker run -d --name awgci --cap-add NET_ADMIN \
  -e PEERS=1 -e SERVERURL=ci.example.com -e INTERNAL_SUBNET=10.56.56.0 \
  test-image >/dev/null
for _ in $(seq 1 45); do
  docker exec awgci test -f /config/peer1/peer1.png 2>/dev/null && break
  sleep 2
done
docker exec awgci test -f /config/peer1/peer1.png \
  || { echo "default 2.0: peer conf was never generated"; docker logs awgci; exit 1; }
if docker exec awgci grep -qE '^(RandomTrailers|DisableCookies|HeaderProtectionKey)' /config/peer1/peer1.conf; then
  echo "default AWG_VERSION=2.0 leaked 3.x keys into the peer conf"
  docker exec awgci cat /config/peer1/peer1.conf
  exit 1
fi
echo "  default 2.0: no 3.x keys emitted"
docker rm -f awgci >/dev/null 2>&1 || true
echo "- AWG 3.1 config generation correct" >> "$GITHUB_STEP_SUMMARY"

# ---------------------------------------------------------------
# IPv6: addressing, exit-mode resolution, migration, dnsmasq AAAA filter.
# GitHub runners have no IPv6 route, so auto must resolve to "off".
echo "### IPv6 config generation" >> "$GITHUB_STEP_SUMMARY"
start_awgci() {  # <extra docker run args...>
  docker rm -f awgci >/dev/null 2>&1 || true
  docker run -d --name awgci --cap-add NET_ADMIN \
    -e PEERS=2 -e SERVERURL=ci.example.com -e INTERNAL_SUBNET=10.13.13.0 \
    "$@" test-image >/dev/null
  # Wait on the log, not on /config/peer2/peer2.png: the volume-reusing
  # scenarios below already have that file from the previous run, so it
  # is true before this container has done anything.
  wait_config awgci
  docker exec awgci test -f /config/peer2/peer2.png \
    || { echo "IPv6: peer confs were never generated"; docker logs awgci; exit 1; }
}
fail() { echo "IPv6: $1"; docker logs awgci; docker exec awgci cat /config/wg_confs/wg0.conf /config/peer1/peer1.conf; exit 1; }

# 0. defaults: IPv6 is opt-in, output is the pre-IPv6 output
start_awgci
docker exec awgci grep -q '^Address = 10.13.13.2$' /config/peer1/peer1.conf || fail "default: peer address not v4-only"
docker exec awgci grep -q '^Address = 10.13.13.1$' /config/wg_confs/wg0.conf || fail "default: server address not v4-only"
docker exec awgci grep -qxF 'PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP' /config/wg_confs/wg0.conf || fail "default: PostUp differs from the pre-IPv6 one"
docker exec awgci grep -qxF 'PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; ip6tables -D FORWARD -i %i -j DROP; ip6tables -D FORWARD -o %i -j DROP' /config/wg_confs/wg0.conf || fail "default: PostDown differs from the pre-IPv6 one"
if docker exec awgci grep -q filter-AAAA /run/dnsmasq/dnsmasq.conf; then fail "default: AAAA filter must be off"; fi
docker exec awgci grep -qx "conf-dir=/config/dnsmasq,\*.conf" /run/dnsmasq/dnsmasq.conf || fail "default: dnsmasq drop-in dir not included"
docker exec awgci grep -qx "interface=wg0" /run/dnsmasq/dnsmasq.conf || fail "default: dnsmasq not bound to wg0"
docker exec awgci dnsmasq --test -C /run/dnsmasq/dnsmasq.conf || fail "default: dnsmasq rejects its config"
docker exec awgci test -f /config/dnsmasq/README || fail "default: /config/dnsmasq/README missing"
if docker exec awgci test -e /config/coredns; then fail "default: /config/coredns must not be created"; fi
docker logs awgci 2>&1 | grep -q 'Set IP6_SUBNET=auto to enable it' || fail "default: opt-in hint not logged"
docker exec awgci grep -q '^ORIG_IP6_EXIT="disabled"$' /config/.donoteditthisfile || fail "default: IP6_EXIT not persisted as disabled"
echo "  defaults: IPv6 disabled, pre-IPv6 output"

# 1. IP6_SUBNET=auto
start_awgci -e IP6_SUBNET=auto
docker exec awgci grep -q '^Address = 10.13.13.2,fd0a:0d0d:0000::2/128$' /config/peer1/peer1.conf || fail "peer1 lacks derived ULA address"
docker exec awgci grep -q '^Address = 10.13.13.3,fd0a:0d0d:0000::3/128$' /config/peer2/peer2.conf || fail "peer2 lacks derived ULA address"
docker exec awgci grep -q '^Address = 10.13.13.1,fd0a:0d0d:0000::1/128$' /config/wg_confs/wg0.conf || fail "server lacks ULA address"
docker exec awgci grep -q '^AllowedIPs = 10.13.13.2/32,fd0a:0d0d:0000::2/128$' /config/wg_confs/wg0.conf || fail "server AllowedIPs lacks /128"
docker exec awgci grep -q 'icmp6-adm-prohibited' /config/wg_confs/wg0.conf || fail "PostUp lacks REJECT on a no-IPv6 runner"
docker exec awgci grep -q 'MASQUERADE; ip6tables' /config/wg_confs/wg0.conf || fail "ip6tables rules not appended after v4 MASQUERADE"
docker exec awgci grep -q 'ip6tables -A FORWARD -i %i -o %i -j ACCEPT; ip6tables -A FORWARD -i %i -j REJECT' /config/wg_confs/wg0.conf || fail "off: intra-tunnel ACCEPT must precede the REJECTs"
docker exec awgci grep -qx filter-AAAA /run/dnsmasq/dnsmasq.conf || fail "AAAA filter not written"
docker exec awgci dnsmasq --test -C /run/dnsmasq/dnsmasq.conf || fail "dnsmasq rejects the config with filter-AAAA"
# dnsmasq does start on a runner (svc-amneziawg exits 0 when the tunnel
# fails) and serves on loopback, so the running service can be queried.
# The failed tunnel deleted the default route, and filter-AAAA only applies
# to forwarded answers, not to dnsmasq's own records: so a second dnsmasq on
# 127.0.0.1:5353 plays the upstream for smoke.test via a split-DNS drop-in.
sleep 3
docker exec awgci pgrep -x dnsmasq >/dev/null || fail "dnsmasq is not running"
docker exec awgci dnsmasq --port=5353 --listen-address=127.0.0.1 --bind-interfaces --no-resolv --no-hosts \
  --host-record=smoke.test,192.0.2.1,2001:db8::1 --pid-file=/tmp/upstream.pid
docker exec awgci sh -c 'printf "server=/smoke.test/127.0.0.1#5353\n" > /config/dnsmasq/smoke.conf'
docker exec awgci s6-svc -r /run/service/svc-dnsmasq; sleep 3
docker exec awgci nslookup -type=A smoke.test. 127.0.0.1 | grep -q '192.0.2.1' || fail "A record not forwarded to the split-DNS upstream from the drop-in"
if docker exec awgci nslookup -type=AAAA smoke.test. 127.0.0.1 | grep -q '2001:db8::1'; then fail "filter-AAAA did not strip the forwarded AAAA record"; fi
docker exec awgci sh -c 'kill "$(cat /tmp/upstream.pid)"; rm -f /config/dnsmasq/smoke.conf'
docker logs awgci 2>&1 | grep -q 'IPv6 exit: off (no IPv6 default route' || fail "auto did not log the off reason"
docker exec awgci grep -q '^ORIG_IP6_SUBNET="fd0a:0d0d:0000::/64"$' /config/.donoteditthisfile || fail "IP6_SUBNET not persisted"
docker exec awgci grep -q '^ORIG_IP6_EXIT="off"$' /config/.donoteditthisfile || fail "IP6_EXIT not persisted"
echo "  IP6_SUBNET=auto: ULA addresses, REJECT rules, AAAA filter"

# 2. IP6_SUBNET=off -> same as the default
start_awgci -e IP6_SUBNET=off
docker exec awgci grep -q '^Address = 10.13.13.2$' /config/peer1/peer1.conf || fail "off: peer address not v4-only"
docker exec awgci grep -q '^Address = 10.13.13.1$' /config/wg_confs/wg0.conf || fail "off: server address not v4-only"
docker exec awgci grep -qxF 'PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE; ip6tables -A FORWARD -i %i -j DROP; ip6tables -A FORWARD -o %i -j DROP' /config/wg_confs/wg0.conf || fail "off: PostUp differs from the pre-IPv6 one"
docker exec awgci grep -qxF 'PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE; ip6tables -D FORWARD -i %i -j DROP; ip6tables -D FORWARD -o %i -j DROP' /config/wg_confs/wg0.conf || fail "off: PostDown differs from the pre-IPv6 one"
if docker exec awgci grep -q 'icmp6-adm-prohibited' /config/wg_confs/wg0.conf; then fail "off: REJECT rules present"; fi
if docker exec awgci grep -q filter-AAAA /run/dnsmasq/dnsmasq.conf; then fail "off: AAAA filter must be off"; fi
echo "  IP6_SUBNET=off: pre-IPv6 output"

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
start_awgci -e IP6_SUBNET=auto -e IP6_EXIT=routed
docker exec awgci grep -q 'ip6tables -A FORWARD -i %i -j ACCEPT' /config/wg_confs/wg0.conf || fail "routed: no ACCEPT"
if docker exec awgci grep -qE 'ip6tables -t nat|icmp6-adm-prohibited' /config/wg_confs/wg0.conf; then fail "routed: NAT or REJECT present"; fi
if docker exec awgci grep -q filter-AAAA /run/dnsmasq/dnsmasq.conf; then fail "routed: AAAA filter must be off"; fi
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
  mkdir -p /config/coredns/generated
  : > /config/coredns/generated/ipv6.conf
  printf "%s\n" ". {" "    loop" "    errors" "    health" "    cache" "    forward . /etc/resolv.conf" "}" > /config/coredns/Corefile
'
# IPv6 left off: an upgraded installation is not touched at all
start_awgci -v awgci-cfg:/config
if docker logs awgci 2>&1 | grep -q 'migrated'; then fail "IPv6 off: templates must not be migrated"; fi
docker exec awgci grep -q 'ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE$' /config/templates/server.conf || fail "IPv6 off: template altered"
docker exec awgci grep -q 'ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE$' /config/wg_confs/wg0.conf || fail "IPv6 off: old template not rendered as-is"
# every earlier release created /config/coredns itself; one holding only the
# shipped defaults is removed, a customised one is kept and pointed out
docker logs awgci 2>&1 | grep -q 'Removed /config/coredns' || fail "unmodified /config/coredns not removed"
if docker exec awgci test -e /config/coredns; then fail "unmodified /config/coredns still present"; fi
docker exec awgci sh -c 'mkdir -p /config/coredns && printf ". {\n    forward . 1.1.1.1\n}\n" > /config/coredns/Corefile'
start_awgci -v awgci-cfg:/config
docker logs awgci 2>&1 | grep -q '/config/coredns is no longer used' || fail "customised /config/coredns not pointed out"
docker exec awgci grep -qx '    forward . 1.1.1.1' /config/coredns/Corefile || fail "customised Corefile must be left untouched"
docker exec awgci rm -rf /config/coredns
echo "  old templates with IPv6 off: untouched; stale /config/coredns: defaults removed, customised kept"
start_awgci -v awgci-cfg:/config -e IP6_SUBNET=auto
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
# A template edit is not watched by the container's change detection, so
# wg0.conf would not be regenerated and the greps below would read
# scenario 6's output. IP6_SUBNET is watched: varying it forces a rewrite.
start_awgci -v awgci-cfg:/config -e IP6_SUBNET=fd12:3456:789a::/64
docker logs awgci 2>&1 | grep -q 'migrated PostUp line' || fail "DROP migration: PostUp not migrated"
docker logs awgci 2>&1 | grep -q 'regenerating 1 server' || fail "DROP migration: confs were not regenerated"
if docker exec awgci grep -q -- '-j DROP' /config/wg_confs/wg0.conf; then fail "DROP migration: DROP rules survived"; fi
docker exec awgci grep -q 'icmp6-adm-prohibited' /config/wg_confs/wg0.conf || fail "DROP migration: REJECT missing"
echo "  #36 DROP templates: migrated"

# 7. customised PostUp is warned about, not fatal
docker rm -f awgci >/dev/null 2>&1 || true
docker run --rm -v awgci-cfg:/config test-image sh -c 'sed -i "s|^PostUp = .*|PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/hook.sh|" /config/templates/server.conf'
# Same reason as 6b: the template edit alone would not regenerate
# wg0.conf. Back to the derived prefix, which differs from 6b's.
start_awgci -v awgci-cfg:/config -e IP6_SUBNET=auto
docker logs awgci 2>&1 | grep -q 'regenerating 1 server' || fail "customised PostUp: confs were not regenerated"
docker logs awgci 2>&1 | grep -q 'PostUp/PostDown are customised' || fail "customised PostUp not warned"
docker exec awgci grep -q '^PostUp = iptables -A FORWARD -i %i -j ACCEPT; /config/hook.sh$' /config/wg_confs/wg0.conf || fail "customised PostUp altered"
if docker exec awgci grep -q 'ip6tables' /config/wg_confs/wg0.conf; then fail "customised PostUp: PostDown must not get IPv6 rules PostUp never adds"; fi
docker exec awgci grep -q '^Address = 10.13.13.2$' /config/peer1/peer1.conf || fail "customised PostUp: peers must not get IPv6 addresses"
echo "  customised template: warned, untouched, IPv6 disabled"

docker rm -f awgci >/dev/null 2>&1 || true
docker volume rm -f awgci-cfg >/dev/null 2>&1 || true
echo "- IPv6 config generation correct" >> "$GITHUB_STEP_SUMMARY"

# ---------------------------------------------------------------
# DNS toggle: what decides whether dnsmasq runs, and how it is configured.
echo "### dnsmasq toggle" >> "$GITHUB_STEP_SUMMARY"
docker rm -f awgdns >/dev/null 2>&1 || true
docker run -d --name awgdns --cap-add NET_ADMIN test-image >/dev/null
wait_config awgdns
[ "$(docker exec awgdns cat /run/s6/container_environment/USE_DNS)" = "false" ] \
  || { echo "client mode: USE_DNS must default to false"; docker logs awgdns; exit 1; }
docker exec awgdns test ! -e /config/dnsmasq \
  || { echo "client mode without USE_DNS: /config/dnsmasq must not be created"; exit 1; }
docker rm -f awgdns >/dev/null 2>&1 || true
docker run -d --name awgdns --cap-add NET_ADMIN -e USE_DNS=true -e USE_COREDNS=true test-image >/dev/null
wait_config awgdns
if docker exec awgdns grep -q '^interface=' /run/dnsmasq/dnsmasq.conf; then echo "client mode USE_DNS=true: must listen on all interfaces"; exit 1; fi
docker exec awgdns dnsmasq --test -C /run/dnsmasq/dnsmasq.conf || { echo "client mode: dnsmasq rejects its config"; exit 1; }
docker logs awgdns 2>&1 | grep -q 'USE_COREDNS is no longer read' \
  || { echo "USE_COREDNS not warned about"; docker logs awgdns; exit 1; }
docker rm -f awgdns >/dev/null 2>&1 || true
docker run -d --name awgdns --cap-add NET_ADMIN -e PEERS=1 -e SERVERURL=ci.example.com -e USE_DNS=false test-image >/dev/null
wait_config awgdns
docker logs awgdns 2>&1 | grep -q 'USE_DNS=false but PEERDNS is auto' \
  || { echo "USE_DNS=false with PEERDNS=auto not warned"; docker logs awgdns; exit 1; }
docker exec awgdns test ! -e /run/dnsmasq/dnsmasq.conf \
  || { echo "USE_DNS=false: no dnsmasq config should be written"; exit 1; }
docker rm -f awgdns >/dev/null 2>&1 || true
echo "  client mode: USE_DNS=false by default, all interfaces when enabled; USE_COREDNS warned; USE_DNS=false + PEERDNS=auto warned"
echo "- dnsmasq toggle correct" >> "$GITHUB_STEP_SUMMARY"

echo "All smoke tests passed!" >> "$GITHUB_STEP_SUMMARY"
echo "Smoke tests passed!"
