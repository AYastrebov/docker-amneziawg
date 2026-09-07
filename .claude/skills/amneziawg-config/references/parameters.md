# AmneziaWG parameter reference

Every obfuscation parameter, its legal range, and the constraint that governs it. All of these
live in the `[Interface]` section of a `.conf`. For the throughput cost of each, see
`performance.md`; for symptom-driven debugging, `troubleshooting.md`.

## Contents

- [Junk packets (Jc, Jmin, Jmax)](#junk-packets-jc-jmin-jmax)
- [Packet prefixes (S1-S4)](#packet-prefixes-s1-s4)
- [Header values (H1-H4)](#header-values-h1-h4)
- [Signature packets (I1-I5)](#signature-packets-i1-i5)
- [AWG 3.0 parameters](#awg-30-parameters)
- [AWG 3.1 switches](#awg-31-switches)
- [MTU](#mtu)
- [Version detection](#version-detection)
- [CPS tag syntax](#cps-tag-syntax)
- [Full constraint checklist](#full-constraint-checklist)

## Junk packets (Jc, Jmin, Jmax)

Random UDP datagrams sent before the handshake, so the start of a session is not a recognisable
fixed-size exchange.

| Key | Range | Typical | Notes |
|---|---|---|---|
| `Jc` | 0-128 | 3-8 | Count. Higher means more noise but a slower handshake |
| `Jmin` | 1-1279 | 40-80 | Minimum size in bytes; must be `< Jmax` |
| `Jmax` | 2-1280 | 80-250 | Maximum size in bytes |

These are handshake-only and cost nothing during a session. They do **not** have to match between
endpoints — each side generates its own junk.

## Packet prefixes (S1-S4)

Random bytes prepended to each message type so the fixed WireGuard packet sizes disappear.

| Key | Applies to | Max | Wire effect |
|---|---|---|---|
| `S1` | handshake initiation | 1132 | `len = 148 + S1` |
| `S2` | handshake response | 1188 | `len = 92 + S2` |
| `S3` | cookie reply | 64 | `len = 64 + S3` |
| `S4` | **every transport packet** | 32 | `len = payload + S4` |

`S4` is the only one on the data path — it is paid on every packet, in bandwidth and in MTU
headroom. Keep it at **20 or below** so a full-size packet still fits a 1500-byte path at the
default 1420 tunnel MTU.

The maxima above are **documented conventions, not runtime checks**: the Go implementation
parses `s1`-`s4` as bare 16-bit integers with no range validation (`device/uapi.go`), and the
kernel module only enforces the `≥ 12` header-protection floor (`netlink.c`). The S1/S2 caps are
payload-budget arithmetic against 1280 (`1132 = 1280 − 148`, `1188 = 1280 − 92`) — note that is
UDP *payload*, not the wire: a handshake at the cap is 1308 bytes on the wire over IPv4 and 1328
over IPv6, so "crosses any path unfragmented" would require the lower `1280 − 28 − 148 = 1104` /
`1280 − 48 − 148 = 1084` (S1) and `1160`/`1140` (S2). Staying inside them is
still right — other clients may validate, and exceeding them breaks handshakes on narrow paths —
but do not expect the endpoint to reject an out-of-range value for you.

Three constraints govern the rest:

- **`S1 + 56 ≠ S2`.** Plain WireGuard's initiation and response differ by 56 bytes. If
  `S2 = S1 + 56`, the two padded packets come out the same length, which is its own fingerprint.
- **All four ≥ 12 when `HeaderProtectionKey` is set.** The ChaCha20 nonce is read from the first
  12 bytes of the prefix, so anything shorter is rejected by the kernel module.
- **All four equal when `RandomTrailers` is on** (with AWG 2.0+ wide `H` ranges). See
  `performance.md`; this one silently destroys upload throughput. Equal `S1`/`S2` would normally
  re-expose the 56-byte gap above, but trailers randomize handshake lengths anyway, so the gap is
  already gone.

AWG 1.5 fixes `S3 = S4 = 0`.

## Header values (H1-H4)

WireGuard identifies message types with a 4-byte field holding 1, 2, 3 or 4. AmneziaWG substitutes
custom values so that field stops being a giveaway.

| Key | Replaces |
|---|---|
| `H1` | handshake initiation (1) |
| `H2` | handshake response (2) |
| `H3` | cookie reply (3) |
| `H4` | transport data (4) |

Rules:

- All four ≥ 5. Values 1-4 are the standard types; setting a key to its own standard value
  disables customisation for that type.
- All four unique and, in range form, **non-overlapping** — otherwise packet types are ambiguous
  and the receiver misclassifies them.
- **AWG 2.0+ expects the range format** (`205127846-255127846`). The Amnezia app uses the presence
  of ranges to decide a config is 2.0 or newer; single integers make it report AWG 1.5, which also
  disables `I1`-`I5` processing. AWG 1.5 uses single integers.

The usual generation strategy is one range per quadrant of the 32-bit space, width 50,000,000,
which makes overlap structurally impossible.

Upstream suggests setting `H1`-`H4` back to `1,2,3,4` when `HeaderProtectionKey` is in use, on the
grounds that header protection already encrypts the type field so custom values add nothing. That
is legitimate and has a side benefit — it removes the misclassification risk described in
`performance.md` — but it costs Amnezia-app version detection. Prefer ranges plus equal `S`
values unless the app's reported version does not matter.

## Signature packets (I1-I5)

Packets sent before the handshake (and every 120s) that imitate another protocol, so the first
thing a DPI box sees looks like QUIC, DNS or DTLS rather than a VPN.

`I1` must be set for `I2`-`I5` to mean anything; they are sent in order. All of them must be
identical on every endpoint, and must appear in `[Interface]` **above** any `[Peer]` block.

The common default is a QUIC Initial packet per RFC 9000 §14.1:

```
I1 = <b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>
```

Long header (Initial, 4-byte packet number) + QUIC v1 + 8-byte random DCID + no SCID + no token +
length 1182 + random packet number + random payload, totalling the 1200-byte RFC minimum. QUIC is
a good disguise because it is ubiquitous and hard to block without collateral damage.

Note that values contain `=` characters, so any parser splitting these lines must split on the
*first* `=` only.

## AWG 3.0 parameters

| Key | Type | Typical | Must match |
|---|---|---|:---:|
| `HeaderProtectionKey` | 32 bytes, base64 | random | **yes** |
| `ContentPaddingAddition` | `lo-hi` bytes, or `0` | `0` (see below) | no |
| `RekeyAfterTime` | `lo-hi` seconds | 100-145 (WG default 120) | no |
| `RekeyTimeout` | `lo-hi` seconds | 4-10 (default 5) | no |
| `RejectAfterTime` | `lo-hi` seconds | derived (default 180) | no |
| `KeepaliveTimeout` | `lo-hi` seconds | 8-22 (default 10) | no |
| `MaxHandshakeAttempts` | `lo-hi` count | 12-28 (default 18) | no |

`HeaderProtectionKey` is a **symmetric ChaCha20 key** — 32 bytes of full entropy. Do not generate
it with `awg genkey` / `wg genkey`, whose output is bit-clamped for Curve25519. Use
`head -c 32 /dev/urandom | base64`.

Timers are ranges and each endpoint draws its own value, so the two sides need not agree. Two
orderings must hold or keypairs expire before they are renewed:

- `RejectAfterTime.lo > RekeyAfterTime.hi`
- `RejectAfterTime.lo > KeepaliveTimeout.lo + RekeyTimeout.lo`

`ContentPaddingAddition` is documented under `performance.md` — the short version is that `0` is
usually right.

## AWG 3.1 switches

Two independent booleans (`on`/`off`) that work with any `AWG_VERSION`.

| Key | Effect | Must match |
|---|---|:---:|
| `RandomTrailers` | Appends a random-length trailer to handshake packets, and to transport packets when `ContentPaddingAddition` is `0`, so lengths stop being fixed | **yes** |
| `DisableCookies` | Stops sending cookie-reply messages under load, removing a distinctive response to probing. Gives up WireGuard's DoS mitigation | no |

Write the key only when enabling it. `off` is the endpoint default, so omitting the line is
equivalent and keeps the config readable by older software that does not know the key.

`RandomTrailers` must match because it changes the *receiver*: an endpoint without it expects
handshake packets of exactly one length and drops the padded ones. And it requires equal `S`
values — see the constraint list above.

## MTU

Overhead per transport packet:

```
IPv4:  20 (IP) + 8 (UDP) + 32 (AWG header + auth tag) + S4  =  60 + S4
IPv6:  40 (IP) + 8 (UDP) + 32                         + S4  =  80 + S4
```

`wg-quick`/`awg-quick` write `route MTU − 80` (1420 on a 1500-byte link), which accounts for
WireGuard but not for `S4`. Guidance:

| Situation | MTU |
|---|---|
| Mobile, PPPoE, unknown paths, "works but slow" | **1280** |
| Clean IPv4 path, known `S4` | `1500 − 60 − S4` |
| IPv6 endpoint | `1500 − 80 − S4` |

1280 clears every ordinary path — its wire packets are `1340 + S4` bytes over an IPv4 endpoint
(`1360 + S4` over IPv6), under PPPoE's 1492 and typical LTE. Note the IPv6 1280-byte floor
guarantees the packet **on the wire**, not the tunnel MTU: a path that is itself ~1280 (DS-Lite,
tunnel-in-tunnel) needs `path − 60 − S4` for an IPv4 endpoint (1208 at `S4 = 12`) or
`path − 80 − S4` for IPv6 (1188), or full-size packets still fragment — the IPv4 case verified by
capture on exactly such a path. Below that, lower values only add overhead.

## Version detection

Given an unlabelled config, infer the version:

| Signal | Version |
|---|---|
| `HeaderProtectionKey` present, `RandomTrailers = on` | 3.1 |
| `HeaderProtectionKey` present | 3.0 |
| `H` values in range form, or `I1` present | 2.0 |
| `S3 = S4 = 0`, single-integer `H` | 1.5 |

## CPS tag syntax

For writing custom `I1`-`I5` disguises:

| Tag | Meaning |
|---|---|
| `<b 0xHEX>` | Literal bytes, e.g. `<b 0x170303>` |
| `<r N>` | N cryptographically random bytes — no size limit in current AmneziaWG (see note below) |
| `<rc N>` | N random ASCII letters `[A-Za-z]` |
| `<rd N>` | N random decimal digits `[0-9]` |
| `<t>` | 32-bit Unix timestamp, network byte order |

#### `<r N>` size

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
26532 shows it from an unrelated cause). For such a parser, split the run into consecutive tags —
`<r 1000><r 178>` — which is byte-identical on the wire: both stacks fill one buffer tag by tag
(`junk.c` `jp_spec_setup`, `amneziawg-go` `obfChain`), and I1-I5 are send-only, so peers holding
either spelling interoperate. The container deliberately keeps the single-tag form.

Example DNS query disguise:

```
I1 = <b 0x0001><b 0x0100><b 0x00010000><b 0x00000000><rd 4><b 0x00000020><rc 8><b 0x076578616d706c6503636f6d00><b 0x0001><b 0x0001>
```

These are fiddly to write by hand. [AmneziaWG Architect](https://architect.vai-rice.space/)
generates them for QUIC, DNS, DTLS, SIP and HTTP/3.

## Full constraint checklist

Run `scripts/awg-lint.py` rather than checking by hand, but for reference:

- `Jmin < Jmax ≤ 1280`, `0 ≤ Jc ≤ 128`
- `S1 ≤ 1132`, `S2 ≤ 1188`, `S3 ≤ 64`, `S4 ≤ 32` (prefer `S4 ≤ 20`)
- `S1 + 56 ≠ S2`
- `S1`-`S4` ≥ 12 if `HeaderProtectionKey` is set
- `S1 = S2 = S3 = S4` if `RandomTrailers = on` with 2.0+ ranges
- `H1`-`H4` ≥ 5, unique, non-overlapping; range format for 2.0+
- `I1` required before `I2`-`I5`; all in `[Interface]` above `[Peer]`
- `HeaderProtectionKey` is 32 unclamped random bytes
- `ContentPaddingAddition = 0` unless deliberately wanted, never with `RandomTrailers`
- `RejectAfterTime.lo >` both `RekeyAfterTime.hi` and `KeepaliveTimeout.lo + RekeyTimeout.lo`
- Explicit `MTU`, `≤ 1500 − 60 − S4` on IPv4

## Sources

- [AmneziaWG official parameter docs](https://docs.amnezia.org/documentation/amnezia-wg)
- [amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
- [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go)
- [Any Tech ARCHITECT](https://github.com/Vadim-Khristenko/Any-Tech-ARCHITECT)
