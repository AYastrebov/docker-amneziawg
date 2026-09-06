---
name: amneziawg-config
description: >-
  Generate and validate AmneziaWG (AWG) VPN configs for protocol versions 1.5, 2.0, 3.0 and 3.1 —
  server and peer .conf files, keys, and every obfuscation parameter (Jc/Jmin/Jmax, S1-S4, H1-H4,
  I1-I5, HeaderProtectionKey, ContentPaddingAddition, RandomTrailers, DisableCookies) plus MTU.
  Use this whenever the user is creating, editing, reviewing or debugging an AmneziaWG setup —
  including "set up AmneziaWG", "generate AWG obfuscation parameters", "what should S4 be",
  "my AmneziaWG tunnel is slow", "upload is way slower than download on my VPN", "AWG 3.1 config",
  "my peers won't connect after I changed the params", or any time you see a .conf containing
  Jc/S1/H1/I1 keys. Use it before hand-writing or hand-editing any AWG parameter: several
  constraints interact in non-obvious ways and getting them wrong silently costs ~98% of upload
  throughput while the tunnel still appears to work. Works standalone with any AmneziaWG
  deployment (kernel module, amneziawg-go, Amnezia app, router, Docker). Not for plain WireGuard
  configs that have no obfuscation parameters.
---

# AmneziaWG configuration

AmneziaWG is WireGuard plus an obfuscation layer. The cryptography is untouched; what changes is
that packets get junk prefixes, randomized headers, disguise packets before the handshake, and
optionally header encryption and per-packet padding.

The obfuscation parameters are easy to generate and easy to get subtly wrong. Several of them
interact, and the failure mode is usually not "no connection" — it is a tunnel that connects,
passes small traffic fine, and quietly runs at 2% of the expected speed. Use the bundled scripts
rather than hand-rolling values; they encode constraints that are documented in scattered places
or only visible in the upstream source.

## Start here

**Generating a new config set** (keys, server conf, one conf per peer):

```bash
scripts/awg-genconf.sh --version 3.1 --peers laptop,phone \
    --endpoint vpn.example.com:51820 --outdir ./awg-configs
```

**Generating just the parameter block**, to paste into configs that already exist:

```bash
scripts/awg-genconf.sh --params-only --version 2.0                    # .conf lines
scripts/awg-genconf.sh --params-only --version 3.1 --format compose   # docker-compose env
scripts/awg-genconf.sh --params-only --version 3.0 --format env       # shell exports
```

**Checking configs** — always do this after editing anything by hand, and first when
troubleshooting:

```bash
scripts/awg-lint.py wg0.conf peer1.conf peer2.conf
```

Passing several files also cross-checks that the shared values agree, which is the single most
common reason a previously-working peer stops connecting. Run `--help` on the generator for the
full option list.

If the user is debugging rather than creating, go to `references/troubleshooting.md` — it maps
symptoms ("upload collapsed", "download is ~20% low", "downloads crawl but pings are fine") to
the specific parameter at fault.

## Choosing a version

| Version | What it adds |
|---|---|
| `1.5` | Junk packets, S1/S2 padding, single-integer H values |
| `2.0` | S3/S4, H1-H4 as ranges, I1-I5 disguise packets |
| `3.0` | `HeaderProtectionKey`, `ContentPaddingAddition`, randomized timers |
| `3.1` | `RandomTrailers`, `DisableCookies` |

Default to **2.0** unless the user tells you their endpoints run newer software. The newer modes
fail closed — a client that cannot parse a key does not connect at all, and on the kernel datapath
an old module reports `Unable to modify interface: Invalid argument`.

**Do not guess which client versions support which protocol version.** Upstream publishes no
per-version client minimums; the docs say only that a config works "if the client supports the
protocol version for which the file was released". The one widely-cited datum is that AWG 2.0
needs AmneziaVPN ≥ 4.8.12.9. For 3.0 and 3.1 there is no published table, and native apps on all
platforms have been gaining 3.x support over time — so stating that a given app "only supports
2.0" is an invention, not a fact. When the user asks for "the newest my app supports", either ask
them what version they run, or give them 2.0 while saying plainly that 3.x is worth trying and
costs nothing to test: if the client cannot parse the keys the tunnel simply refuses to come up,
which is a fast and non-destructive check.

Server-side you *can* check the kernel datapath directly with `cat /sys/module/amneziawg/version`;
3.1 keys need a 3.1 module. That tells you nothing about the clients.

`RandomTrailers` and `DisableCookies` are independent booleans that work with **any** version, so
`2.0` plus `RandomTrailers` is valid. `3.1` is just shorthand for "the 3.0 parameter set plus
`RandomTrailers = on`".

## The constraints that actually bite

Full tables are in `references/parameters.md`. These four are the ones that cause real damage and
that hand-written configs get wrong:

**`RandomTrailers` requires `S1 = S2 = S3 = S4`.** Turning trailers on relaxes the receiver's
packet-type check from an exact length match to a lower bound, which leaves the `H` ranges as the
only thing separating packet types. Each type's check reads the type field at *its own* `S`
offset, so when the four differ, three of the four checks read garbage — and garbage falls inside
a 50-million-wide `H` range about 1.16% of the time each. Roughly **3.5% of data packets get
dropped** as malformed handshakes. TCP collapses: measured upload fell from 100 to 2 Mbit/s while
download barely moved, which is why this reads as "my upload is broken" rather than "my VPN is
down". Setting the four equal makes every check read the true type field, and non-overlapping `H`
ranges then exclude it deterministically.

**Do not set `ContentPaddingAddition` together with `RandomTrailers`.** Content padding takes
precedence on the send path and suppresses the trailers, but the receive path checks the trailer
flag directly — so you get the loose matching and its misclassification risk with none of the
obfuscation. Pick one.

**`ContentPaddingAddition` costs about 22% of download throughput** on its own. Giving every
datagram a different length defeats `UDP_GRO` batching, which only coalesces consecutive
equal-sized datagrams. Leave it at `0` unless per-packet size randomization is specifically
wanted; `RandomTrailers` achieves a similar goal without the bulk-transfer cost, because it skips
packets that are already full-size.

**`HeaderProtectionKey` forces `S1`-`S4` ≥ 12.** The ChaCha20 nonce is read from the first 12
bytes of the S-prefix, so shorter prefixes are rejected outright by the kernel module. This is
why 3.x configs have a floor of 12 where 2.0 can go lower.

## MTU

Per-packet overhead is `60 + S4` over IPv4 and `80 + S4` over IPv6 — the 20/40-byte IP header, 8
bytes of UDP, 32 bytes of AmneziaWG framing, plus the `S4` junk prefix.

`wg-quick`/`awg-quick` derive `route MTU − 80` = 1420 and know nothing about `S4`, so a full-size
packet is `1420 + 60 + S4` on IPv4 and fragments past 1500 as soon as `S4 > 20`. Fragmented UDP is
dropped or rate-limited by many mobile networks, CGNATs and DPI boxes, which shows up as
"connects fine, small things work, downloads crawl".

Keep `S4 ≤ 20`, and write an explicit `MTU`. **1280 is the right default** — its wire packets
(`1340 + S4`) clear PPPoE, LTE and every ordinary path. On a known-clean IPv4 path you can use
`1500 − 60 − S4`. But the IPv6 1280-byte floor guarantees the packet *on the wire*, not the tunnel
MTU: if the path is itself ~1280 (DS-Lite, tunnel-in-tunnel), use `path − 60 − S4` — 1208 at
`S4 = 12` — or full-size packets still fragment. When a user reports slowness despite MTU 1280,
measure the path (`ping -M do` binary search) before concluding MTU is not the problem.

## Which values must match

| Parameter | Must be identical everywhere |
|---|:---:|
| `S1`-`S4`, `H1`-`H4`, `I1`-`I5` | yes |
| `HeaderProtectionKey` | yes |
| `RandomTrailers` | yes — a peer without it drops the padded handshakes from a peer with it |
| `Jc`, `Jmin`, `Jmax` | no — each side picks its own junk |
| 3.x timer ranges | no — each endpoint draws a value from its own range |
| `DisableCookies` | no — purely local behaviour |

Changing any of the shared values invalidates every peer config already distributed. Warn the
user about this before regenerating; peers on phones do not auto-update.

`I1`-`I5` must live in the `[Interface]` section, above any `[Peer]` block. The Amnezia app only
inspects `[Interface]` when deciding which protocol version a config is, and ignores signature
packets found under `[Peer]`.

## Reference files

- `references/parameters.md` — every parameter, its range, its constraint, and CPS tag syntax for
  writing custom `I1`-`I5` disguises. Read when picking or validating specific values.
- `references/performance.md` — which parameters cost throughput and why, with measurements and
  upstream source citations. Read when the user cares about speed or asks why a value is
  recommended.
- `references/troubleshooting.md` — symptom-to-cause table. Read first when something is broken.

## Scope

This skill deals in `.conf` files — the format every AmneziaWG implementation reads. Deployments
wrap that in their own configuration: the Amnezia app has a GUI, routers have their own syntax,
and container images expose environment variables whose names differ per image. Those wrappers
are outside what is documented here, so give the user `.conf` content and let them map it, or ask
what their deployment expects. Inventing an environment variable name is an easy way to hand
someone a setting that silently does nothing.

## If the scripts cannot run

The generator needs only bash and `/dev/urandom`; key derivation prefers `awg` or `wg` and falls
back to Python with the `cryptography` package. If none of that is available, generate parameters
by hand from `references/parameters.md`, then still describe the constraints to the user — the
interactions above are the part that matters, not the specific random values.
