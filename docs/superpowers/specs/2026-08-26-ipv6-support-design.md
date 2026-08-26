# IPv6 support for docker-amneziawg — design

Date: 2026-08-26
Status: approved design, pending implementation
Supersedes: PR #36 (`fix: update server configuration for IPv4-only support and prevent IPv6 leak`)

## 1. Problem

The container is IPv4-only inside the tunnel, but the peer template ships
`AllowedIPs = 0.0.0.0/0, ::/0`. That combination is wrong in both directions:

- A peer whose tunnel interface has **no IPv6 address** does not, on most client
  OSes, install the `::/0` route at all. On a dual-stack client network, IPv6
  traffic then bypasses the tunnel entirely. This is the leak reported upstream
  (linuxserver/docker-wireguard#347) and in our PR #36.
- A peer that *does* route `::/0` into the tunnel gets its IPv6 packets
  forwarded by the server's `ip6tables FORWARD ACCEPT` rule into a container that
  has no IPv6 route, so they are silently black-holed. `ip6tables -t nat
  MASQUERADE` also requires `ip6table_nat` on the host; where it is missing the
  `PostUp` line fails and `awg-quick` (`set -e`) tears the whole tunnel down.

PR #36 replaced the rules with `DROP`, which fixes neither the client-side leak
nor the fail-slow behaviour, and hardcodes a policy into a user-owned template
that any later change has to migrate again.

## 2. Goals

1. No IPv6 leak from dual-stack clients, **for every deployment, without
   configuration**.
2. Real IPv6 through the tunnel when the host has IPv6 and the operator enables
   it on the Docker network. Zero `daemon.json` changes; zero impact on other
   containers on the host.
3. When IPv6 egress is not available, IPv6 fails **fast** (ICMPv6 reject) and,
   for peers using the container's CoreDNS, is not even attempted (no AAAA).
4. Existing deployments upgrade with one automatic config regeneration and
   keep working with no compose changes.
5. Firewall policy lives in the script, not in user templates, so the next
   change is script-only.

### Non-goals

- IPv6 for the outer AWG endpoint. `SERVERURL=auto` detects the IPv4 address
  (`curl -4`, taken from PR #36). Docker ≥ 27 already publishes the port on
  `[::]`, so a hostname with an AAAA record works passively; that is documented,
  not built.
- Routed GUA with NDP proxying. A user who has a **routed** prefix can use
  `IP6_EXIT=routed`; on-link `/64`s (the common VPS shape) are out of scope.
- IPv6 `PEERDNS` addresses, client mode, Docker daemon configuration.

## 3. Evidence behind the choices

- **ULA + NAT66 over routed GUA.** Surveyed four production VPSes on
  2026-08-26: webdock (`/124` GUA), ionos (`/80`), oracle (single dynamic
  `/128` from RA), vdsina (on-link `/64`). None can route a prefix to peers
  without extra machinery; all four have IPv6 egress. NAT66 works on all four.
- **Docker does NAT66 natively.** Docker ≥ 27: `ip6tables` is on by default;
  `enable_ipv6: true` on a compose network with no subnet auto-allocates a ULA
  `/64` and masquerades outbound IPv6 as the host. No daemon restart.
  (Verified in Docker docs; one network on webdock already runs this way.)
- **Address-always, exit-separately is the industry pattern.** sing-box TUN
  defaults to `["172.19.0.1/30", "fdfe:dcba:9876::1/126"]`; xray's WireGuard
  outbound defaults to `["10.0.0.1", "fd59:7153:2388:b5fd::1"]`. Both treat the
  exit's IPv6 capability as a separate, auto-detectable decision (xray
  `queryStrategy: UseSystem`, sing-box `dns.strategy: ipv4_only`).
- **Container facts (verified on webdock, image `latest`, nft backend):**
  `ip6tables -j REJECT --reject-with icmp6-adm-prohibited` works;
  `ip6tables -t nat MASQUERADE` works; the Alpine CoreDNS build includes the
  `template` plugin; `sysctl -w` inside the container is **denied** — sysctls
  must come from the compose `sysctls:` block.

## 4. Design

### 4.1 Addressing

| `IP6_SUBNET` value | effect |
|---|---|
| unset | prefix derived from `INTERNAL_SUBNET`: octets `a.b.c` → `fdAA:BBCC:0000::/64` in hex, e.g. `10.13.13.0` → `fd0a:0d0d:0000::/64`. Deterministic, no persisted state, distinct per container. |
| `<prefix>::/64` | user prefix, ULA or GUA. |
| `off` | no IPv6 anywhere. Output is byte-identical to the pre-feature container. |

Validation of a user prefix: must match `^[0-9a-fA-F:]+::/64$`, must contain no
`:::`, and must have at most 4 hextets before the `::`. Anything else logs
`**** IP6_SUBNET "<value>" is invalid (expected e.g. fd12:3456:789a::/64); using derived <prefix> ****`
and falls back to the derived ULA. A bad value never produces a broken conf.
`/64` is the only accepted length: it keeps address math to string
concatenation.

The literal `off` is required for disabling. An empty value cannot serve that
role because s6 drops empty variables from `container_environment`
(see CLAUDE.md).

Derived addresses (`P` = prefix without the `/64`):

- server: `P1/128` → written as `Address = ${INTERFACE}.1,P1/128`
- peer with IPv4 host index `N` (`10.13.13.N`): `PN/128`. The IPv6 host part
  **is** the IPv4 last octet, in decimal-as-hex-literal form (peer `.10` gets
  `::10`, not `::a`). This is deliberate: it is readable, cannot collide, needs
  no second conflict-detection loop, and a peer's two addresses can never
  disagree.

Peer conf: `Address = 10.13.13.N,PN/128`. Server conf peer block:
`AllowedIPs = 10.13.13.N/32,PN/128[,${SERVER_ALLOWEDIPS_PEER_X}]`.
Peer `AllowedIPs` default stays `0.0.0.0/0, ::/0`.

Existing-peer handling: `CLIENT_IP` is read from the existing peer conf with
`awk '{print $NF}' | cut -d, -f1` (the `Address` line may now be a list). The
IPv6 address is always recomputed from `CLIENT_IP`, never read back, so a change
of `IP6_SUBNET` is applied everywhere on regeneration.

### 4.2 Exit mode

`IP6_EXIT=auto|nat|routed|off`, default `auto`. Resolved once at startup by
`resolve_ip6_exit()` into `IP6_EXIT_EFFECTIVE`, `IP6_POSTUP`, `IP6_POSTDOWN`.

| effective mode | `IP6_POSTUP` | `auto` selects it when |
|---|---|---|
| `nat` | `ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -A FORWARD -o %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE` | v6 default route present **and** `forwarding=1` **and** prefix is ULA (`fc00::/7`) |
| `routed` | the two `ACCEPT` rules only | same, but prefix is GUA |
| `off` | `ip6tables -A FORWARD -i %i -j REJECT --reject-with icmp6-adm-prohibited; ip6tables -A FORWARD -o %i -j REJECT --reject-with icmp6-adm-prohibited` | otherwise |
| (none) | empty | `IP6_SUBNET=off` — no `ip6tables` invocation at all |

`IP6_POSTDOWN` is the same list with `-A` → `-D`.

Detection inputs, read inside the container:
- route: `ip -6 route show default` non-empty
- forwarding: `/proc/sys/net/ipv6/conf/all/forwarding` == `1`
- ipv6 enabled: `/proc/sys/net/ipv6/conf/all/disable_ipv6` == `0`

Whenever `auto` resolves to `off`, one log line states the reason and the fix,
e.g.
`**** IPv6 exit: off (no IPv6 default route in the container). Peers get IPv6 addresses but IPv6 traffic is rejected. To enable, set networks.default.enable_ipv6: true and sysctl net.ipv6.conf.all.forwarding=1 in docker-compose.yml ****`

Forced modes are honoured verbatim. `IP6_EXIT=nat` on a host without a route
or without `ip6table_nat` fails `PostUp` and therefore the tunnel — the same
behaviour as an explicit misconfiguration today — and the README says so.
Unknown values log a warning and behave as `auto`.

`IP6_SUBNET=off` implies exit `off` **with no rules**: a user disabling IPv6
must get exactly the old behaviour, including on hosts with no `ip6tables`
support at all.

### 4.3 Templates and migration

New default `root/defaults/server.conf`:

```
[Interface]
Address = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}
ListenPort = 51820
PrivateKey = $(cat /config/server/privatekey-server)
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE${IP6_POSTUP:+; ${IP6_POSTUP}}
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE${IP6_POSTDOWN:+; ${IP6_POSTDOWN}}
Jc = ${AWG_JC}
...
```

New default `root/defaults/peer.conf`: `Address = ${CLIENT_IP}${CLIENT_IP6:+,${CLIENT_IP6}}`.

Migration of user-owned `/config/templates/*.conf` runs next to the existing
PresharedKey migration, once per line, idempotent:

| file | old line (exact, as shipped before this change) | new line |
|---|---|---|
| server.conf | `Address = ${INTERFACE}.1` | `Address = ${INTERFACE}.1${SERVER_IP6:+,${SERVER_IP6}}` |
| server.conf | the shipped `PostUp = ...` (v4 + v6 ACCEPT/MASQUERADE) | the new `PostUp` |
| server.conf | the shipped `PostDown = ...` | the new `PostDown` |
| peer.conf | `Address = ${CLIENT_IP}` | `Address = ${CLIENT_IP}${CLIENT_IP6:+,${CLIENT_IP6}}` |

Matching is exact-line (`grep -Fxq`), replacement via `sed` on that exact line.
If a template contains neither the old line nor the new variable for a given
row, the script logs
`**** /config/templates/server.conf: PostUp is customised and has no ${IP6_POSTUP}; IPv6 firewall rules will not be applied. See README "IPv6" ****`
and continues. A customised template never blocks startup.

### 4.4 CoreDNS AAAA suppression

When `IP6_EXIT_EFFECTIVE` is `off` (including `IP6_SUBNET=off`) and CoreDNS is
enabled, peers on `PEERDNS=auto` must not receive AAAA records. Mechanism:

- The default `root/defaults/Corefile` gains `import generated/*.conf` inside
  the server block. `/defaults/Corefile` is copied to `/config/coredns/Corefile`
  only when absent, as today.
- `init-amneziawg-confs` always writes `/config/coredns/generated/ipv6.conf`:
  either the block below, or an empty file (so `import` always has a match and
  a stale block from a previous run is cleared).

```
template IN AAAA . {
    rcode NOERROR
}
```

- Existing user `Corefile`s are not edited. If the file lacks `import
  generated/*.conf`, one log hint says what to add. If CoreDNS is disabled, the
  generated file is still written (harmless) and no hint is logged.
- `template` has priority over `forward` in CoreDNS' plugin order, so AAAA
  queries never reach the upstream resolver.

### 4.5 Persistence and change detection

`save_vars()` adds `ORIG_IP6_SUBNET` (effective prefix or `off`) and
`ORIG_IP6_EXIT` (effective mode). Both join the regeneration `if`.

- Upgrade: old `.donoteditthisfile` lacks both → mismatch → one regeneration.
  Peer keys, PSKs and IPv4 addresses are preserved by the existing code paths.
- Enabling Docker IPv6 later: restart → `auto` resolves to `nat` → mismatch →
  regeneration (server `PostUp` changes; peer confs unchanged in content).
- Not stored in `awg_params`: this is not an obfuscation parameter.

### 4.6 docker-compose.yml and deploy skill

`docker-compose.yml` (shipped example) gains, commented with explanation:

```yaml
    sysctls:
      - net.ipv6.conf.all.forwarding=1
networks:
  default:
    enable_ipv6: true
```

and the commented env examples `IP6_SUBNET`, `IP6_EXIT`. The deploy skill's
`compose-template.md` includes them by default; `requirements.md` gains a check
(`ip -6 route get 2001:4860:4860::8888`) that reports whether the host has IPv6
egress and whether Docker is ≥ 27; `gen-awg-params.sh` is unchanged (not an
obfuscation param).

### 4.7 PR #36 disposition

Take `curl -s -4 icanhazip.com` as its own commit with credit. Decline the
`DROP` rules and the README rewrite with a link to this spec.

## 5. Failure modes and how they are handled

| situation | behaviour |
|---|---|
| host kernel has no `ip6table_nat` | `auto` never selects `nat` without a v6 route; on hosts with a route but no module, `PostUp` fails as any bad rule would; README troubleshooting entry. |
| host has no `ip6table_filter` / IPv6 disabled at kernel level | `disable_ipv6=1` → `auto` → `off`. If `ip6tables` itself is unusable, the user sets `IP6_SUBNET=off` (no rules at all). Logged hint names this. |
| user template customised | warned, never fatal (4.3). |
| invalid `IP6_SUBNET` | warned, derived prefix used (4.1). |
| `IP6_SUBNET` changed | all peer IPv6 addresses recomputed on regeneration (4.1). |
| `INTERNAL_SUBNET` changed | derived prefix changes with it; same regeneration path as today. |
| client that cannot parse an IPv6 `Address` | `IP6_SUBNET=off`. |
| operator forces `nat` where it cannot work | tunnel fails to come up with the ip6tables error in the log — explicit, not silent. |
| CoreDNS custom Corefile | hint logged; DNS keeps working as before, AAAA not filtered. |
| IPv4 host index > 254 or non-numeric | impossible: `CLIENT_IP` is always `${INTERFACE}.N` with `N` in 2..254. |

## 6. Testing

CI (`docker-build.yml` smoke, runners have no IPv6):
1. Default run: peer conf `Address` contains `,fd0a:0d0d:0000::2/128`; server
   conf `Address` ends `,fd0a:0d0d:0000::1/128`; each server peer block
   `AllowedIPs` has `/32,` and `/128`; `PostUp` contains `icmp6-adm-prohibited`;
   `generated/ipv6.conf` contains `template IN AAAA`; log contains
   `IPv6 exit: off`.
2. `IP6_SUBNET=off`: no `fd0a`, no `ip6tables` in any conf; `generated/ipv6.conf`
   still contains the template block.
3. `IP6_SUBNET=fd12:3456:789a::/64`: peers get `fd12:3456:789a::N/128`.
4. `IP6_SUBNET=bogus`: log contains `is invalid`, derived prefix used.
5. Pre-seeded old-style `/config/templates/server.conf` and `peer.conf`:
   migrated; output identical to test 1.
6. Pre-seeded customised `PostUp`: warning logged, container starts.
7. `IP6_EXIT=routed` on the runner: `PostUp` has the two `ACCEPT` rules and no
   `MASQUERADE`; no `REJECT`.

VPS (webdock, real IPv6, Docker 29): on the `amneziawg-31` stack only:
- Before enabling Docker IPv6: from a peer, `curl -6 -m 5 ifconfig.co` fails
  immediately (not a timeout); `dig AAAA google.com @10.13.14.1` returns no
  answer; `curl -4` works. `amneziawg` (2.0) container untouched.
- After `enable_ipv6: true` + forwarding sysctl and a restart: log says
  `IPv6 exit: nat`; from a peer, `curl -6 ifconfig.co` returns the VPS's IPv6
  address; `dig AAAA` returns records; browserleaks shows no v6 leak.

## 7. Documentation

README: new "IPv6" section (what you get by default, how to enable egress —
three compose lines —, `IP6_SUBNET`/`IP6_EXIT` reference, routed mode, how to
turn it off, troubleshooting for `ip6table_nat`). Env var table rows for both
variables. CHANGELOG entry. CLAUDE.md: variable-adding checklist gains the
IPv6 rows; a "Do not hardcode firewall policy in templates" gotcha. Deploy
skill references updated (4.6).
