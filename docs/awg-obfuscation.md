# AmneziaWG Obfuscation

Parameter constraints, CPS tag syntax, the default I1, data-path cost and MTU. For how `init-amneziawg-confs/run` generates and persists the values, see [awg-parameters.md](awg-parameters.md); for measurements, [awg-performance.md](awg-performance.md).

All parameters are optional and auto-generated with random values if not set. Server and all clients must use identical values (except Jc/Jmin/Jmax which may differ).

## Parameter Constraints

| Param | Range | Critical Notes |
|-------|-------|----------------|
| Jc | 1-128 (default 3-8) | Number of junk packets before handshake |
| Jmin | < Jmax (default 40-80) | Min junk packet size |
| Jmax | <= 1280 (default 80-250) | Max junk packet size |
| S1 | <= 1132 (default 15-150) | Init padding. **S1+56 must not equal S2** |
| S2 | <= 1188 (default 15-150) | Response padding |
| S3 | <= 64 (default 8-55 in 2.0, 0 in 1.5) | Cookie padding |
| S4 | <= 32 (default 4-20 in 2.0, 12-20 in 3.x, 0 in 1.5) | Transport padding — **per-packet overhead, keep small**. Keep <= 20 or full-size packets fragment at the default 1420 MTU |
| H1-H4 | >= 5, all unique | Header obfuscation. AWG 2.0: range format (e.g. `90666522-140666522`). AWG 1.5: single integers |
| I1-I5 | tag syntax | CPS packets. I1 required for I2-I5. AWG 2.0 auto-generates QUIC Initial for I1 |

## AWG 2.0 vs 1.5

| Feature | AWG 2.0 (default) | AWG 1.5 |
|---------|-------------------|---------|
| S3/S4 | Random non-zero | Fixed 0 |
| H1-H4 format | Range pairs (quadrant strategy) | Single integers |
| I1-I5 | Auto-generated QUIC Initial for I1 | Empty (disabled) |
| Client requirement | AmneziaVPN 4.8.12.9+ | Any AmneziaVPN version |
| App detection | Range H values -> "AWG 2.0" | Integer H values -> "AWG 1.5" |

## CPS Tag Syntax (I1-I5)

| Tag | Description | Example |
|-----|-------------|---------|
| `<b 0xHEX>` | Static hex bytes | `<b 0x170303>` |
| `<r N>` | N random bytes — no size limit in current AmneziaWG (see below) | `<r 32>` |
| `<rd N>` | N random digits (0-9) | `<rd 8>` |
| `<rc N>` | N random characters (a-zA-Z) | `<rc 16>` |
| `<t>` | 32-bit Unix timestamp | Current epoch time |

Tags with `=` signs: parse with `cut -d= -f2-` not `-f2`.

## Default QUIC Initial Packet (AWG 2.0)

```
<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>
```

Breakdown: Long Header (Initial, 4-byte pkt num) + QUIC v1 + DCID(8 random) + no SCID + no token + length 1182 + random pkt num + random payload = 1200 bytes total (RFC 9000 section 14.1 minimum).

The trailing `<r 1178>` is intentional: a 1200-byte QUIC Initial cannot be written within 1000-byte tags without splitting, and no current implementation requires that.

## `<r N>` size

There is no per-tag size limit in current AmneziaWG. The 1000-byte cap that older versions of this
document stated existed in exactly one implementation and is gone:

- `amneziawg-go` ≤ v0.2.15 rejected `<r>`/`<rc>`/`<rd>` above 1000 in `newRandomGeneratorBase`
  (`device/awg/tag_generator.go:73`, `if size > 1000`). Removed 2025-12-01 by `0361c54`
  ("fix: refactor processing of junk packets", PR #103); every release since v0.2.16, including
  the pinned v3.1.20260828, parses the size with a bare `strconv.Atoi` (`device/obf_rand.go:8-17`).
- `amneziawg-tools` (`config.c:533`, `strdup`) and the kernel module (`junk.c:108-124`,
  `kstrtoint`; `netlink.c:58`, unbounded `NLA_NUL_STRING`) never had one.

docs.amnezia.org still lists `<r length>` as "length ≤ 1000" (and `<rc>`/`<rd>` "N ≤ 1000"), so
third-party parsers written to the published text may enforce it. Observed: Keenetic NDMS ASC
rejects a peer conf carrying this container's default I1 with `invalid I1 value`, while a
KeeneticOS 5.1 user reports `…<r 1000><r 184>` working (forum.keenetic.ru topic 27738). The exact
threshold is not confirmed, and `invalid I1 value` is not size-specific (forum.keenetic.com topic
26532 shows it from an unrelated cause). For such a parser, split only the oversized tag into consecutive tags of the same kind and
leave the rest of the value untouched — the default's `<r 1178>` becomes `<r 1000><r 178>`, so the
full value reads `<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1000><r 178>`. That is
byte-identical on the wire: both stacks fill one buffer tag by tag
(`junk.c` `jp_spec_setup`, `amneziawg-go` `obfChain`), and I1-I5 are send-only, so peers holding
either spelling interoperate. The container deliberately keeps the single-tag form.

For custom protocols (DNS, DTLS, SIP, HTTP/3): use [AmneziaWG Architect](https://architect.vai-rice.space/).

## Data-path cost of each parameter

Full analysis, measurements and reproduction steps: [`awg-performance.md`](awg-performance.md).

Handshake-only, zero steady-state cost: `Jc`/`Jmin`/`Jmax`, `S1`-`S3`, `I1`-`I5`, `H1`-`H4`. Per-packet cost: `S4` (bytes + a CSPRNG call), `HeaderProtectionKey` (one `chacha_init` + 16-byte XOR, effectively free), `ContentPaddingAddition` and `RandomTrailers` (bytes).

**`RandomTrailers` requires `S1 == S2 == S3 == S4` under AWG 2.0+.** Trailers relax the receiver's type check from `skb->len == expected_len` to `>=` (`receive.c:51,62,73`), leaving only the `H` range test to discriminate. The four branches read the type field at their own `S` offset, so unequal values make three of them read garbage, which falls inside a 50M-wide `H` range with p ≈ 1.16% each — about **3.5% of transport packets dropped**. Mathis at 22ms RTT predicts 2.7 Mbit/s; measured 1.7-2.4 against ~100 Mbit/s baseline. Equal `S` values make every branch read the true type, and non-overlapping `H` ranges then exclude it deterministically. Narrow `H` (`1,2,3,4`) fixes it independently.

`generate_awg_params()` handles this: when `AWG_RANDOM_TRAILERS` resolves to `on` and `awg_has_2x_features`, one value is drawn for all four S parameters (12-20), and an explicitly pinned unequal set produces a startup warning. The 3.1 switch normalization runs **before** the S values are drawn so the constraint is known in time — moving it back below reintroduces the bug silently. `generate_awg3_params()` likewise defaults `AWG_CONTENT_PADDING` to `0` under trailers, since content padding suppresses them on send (`send.c:254`) while the receive path stays loose (`receive.c:47`), and warns if the user pins both.

`ContentPaddingAddition` costs ~22% of download throughput: randomizing every datagram length defeats `UDP_GRO` coalescing on userspace clients (`conn/gso_linux.go`), which only batches consecutive equal-sized datagrams.

## MTU and per-packet overhead

`awg-quick` sets the tunnel MTU to `route MTU − 80` (1420 on a 1500 link), exactly like wg-quick. The 80 covers IPv6 (40) + UDP (8) + WG framing (32). It does **not** include `S4`, which amneziawg-go prepends to every transport datagram (`send.go`: `crypt := elem.buffer[:elem.padding]`), so a full-size packet is `MTU + 60 + S4` over IPv4 / `MTU + 80 + S4` over IPv6 and fragments at 1500 when `S4 > 20` (IPv4) or `S4 > 0` (IPv6). Fragmented UDP is dropped or throttled by many CGNATs, mobile networks and DPI — the symptom is "connects, small things work, downloads crawl".

`ContentPaddingAddition` and transport-side `RandomTrailers` do not fragment *transport* packets: both cap their padding at `udpWindow − packet`, where `udpWindow` starts at `DefaultUdpWindow = 500` and grows to the largest datagram seen on the peer (reset on endpoint change). Transport trailers are used only when `ContentPaddingAddition` is zero (three-tier fallback: content padding → random trailer → 16-byte alignment). Wire captures confirm the transport cap exactly (118,559 of 118,565 full-size datagrams at precisely `MTU + S4 + 32`), but a handful of kernel-side *handshake-burst* packets were observed above the cap (up to 1443 B payload on a 1252-cap session) — root-caused upstream: modules built before `4569c4c6` (2026-09-06) appended trailers to I1-I5 and junk packets unconditionally (`wg_socket_send_buffer_to_peer`). The fix did not bump `version.h`, so a patched module still reports `3.1.20260812`; detect it via the package version or the `bool trailer` parameter, not the version string. On older modules a rekey can fragment on a narrow path; handshakes retry, so the impact is latency, not throughput. See `docs/awg-performance.md`.

The cap is the **observed UDP window, not the MTU** (`peer.h:110-124`), and the window is a high-water mark over datagrams both sent *and received* (`send.c:243`, `receive.c:571`). Receiving a padded datagram therefore raises it above the local full-size packet, so `ContentPaddingAddition` does grow full-size sends by a few bytes — measured 1228 → 1229-1244 on the wire. `RandomTrailers` does not, because it short-circuits when `udp_window > size` is false (`peer.h:105`).

Guidance (documented in README "MTU"): 1280 for mobile/PPPoE/unknown paths (clears any path with MTU >= `1340 + S4` on the wire for IPv4 endpoints, `1360 + S4` for IPv6; a path that is *itself* ~1280, e.g. DS-Lite, needs `path − 60 − S4` = 1208 at S4=12 over IPv4, `path − 80 − S4` = 1188 over IPv6 — the IPv6 1280 floor guarantees the *outer* packet, not the tunnel MTU); `1500 − 60 − S4` (1413 for the default max S4 = 27) for wired IPv4; `1500 − 80 − S4` for IPv6 endpoints. The container does not write `MTU`; users add it to the confs or templates. Sources: amneziawg-go `device/send.go`, `device/constants.go`; wiki.amnezia.host 3.1 upgrade guide; bivlked/amneziawg-installer ADVANCED.md (sets 1280 since v5.7.4); Any-Tech-ARCHITECT `scripts/awg-gen.sh` (parameter ranges, no MTU guidance).

With `IP6_SUBNET` set, 1280 is also a hard floor: Linux strips IPv6 from an interface whose MTU is under 1280, so a template below it would take the tunnel down on `ip -6 route add` ("No such device"). `ip6_check_template_mtu` in `root/app/ipv6-lib.sh` keeps IPv6 off, with the file named in the log, when either template pins less — the constrained-path values (1208/1188) are IPv4-only territory. README "IPv6 › MTU floor".
