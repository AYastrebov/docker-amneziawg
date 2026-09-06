# What obfuscation costs, and why

Which AmneziaWG parameters affect throughput and latency, traced to upstream source and confirmed
by measurement. Read this when the user cares about speed, or asks why a recommended value is
what it is.

## Handshake-only vs per-packet

Obfuscation splits cleanly. Only the second group can affect steady-state speed.

| Parameter | Per-packet cost | Source |
|---|---|---|
| `Jc`, `Jmin`, `Jmax` | none — handshake only | `send.c:71-89` |
| `S1`, `S2`, `S3` | none — init/response/cookie only | `send.c:89,161,179` |
| `I1`-`I5` | none — sent every 120s | — |
| `H1`-`H4` | none — a value substituted into an existing field | `send.c:293` |
| `S4` | **+S4 bytes + one CSPRNG call per packet** | `send.c:297-298` |
| `HeaderProtectionKey` | one `chacha_init` + 16-byte XOR per packet | `header_protection.c:6-23` |
| `ContentPaddingAddition` | **+random bytes per packet** | `peer.h:110-124` |
| `RandomTrailers` | **+random bytes per packet** | `peer.h:98-108` |

So "more obfuscation" is not uniformly "slower". Junk packets and signature packets are free once
the tunnel is up; only four settings are on the data path.

## The three padding mechanisms are mutually exclusive

`send.c:253-260` (mirrored in `amneziawg-go` `device/send.go:607-614`):

```c
if (!u16_range_is_zero(content_padding_addition))      // wins if set
    padding_len = wg_peer_skb_randomize_padding_addition(...);
else if (peer->device->random_trailers)                // only if CPA is unset
    padding_len = wg_peer_skb_random_trailer(...);
else
    padding_len = calculate_skb_padding(skb);          // stock: pad to multiple of 16
```

`ContentPaddingAddition` silently disables `RandomTrailers` **on the send path**. It does not
disable it on the receive path — `receive.c:47` reads the flag directly:

```c
bool random_trailers = wg->random_trailers;   // not gated on CPA
```

Setting both therefore gives you the receive-side behaviour of trailers (and the risk below) with
none of the send-side obfuscation. Pick one.

## Why `RandomTrailers` needs equal S values

Trailers change how a receiver identifies packet types. Without them each type is matched by exact
length; with them, length becomes a lower bound only (`receive.c:51,62,73`):

```c
random_trailers ? skb->len >= expected_len : skb->len == expected_len
```

The receiver then tries initiation, response, cookie and transport in order. For each it reads a
4-byte type field **at that type's own prefix offset** (`S1`, `S2`, `S3`, `S4`) and tests it
against the matching `H` range.

Once `>=` always passes, the type test is the only thing left. And when `S1`-`S4` differ, the
first three branches read the type field at the wrong offset and get garbage. Garbage lands inside
a 50,000,000-wide `H` range with probability 50e6 / 2³² = 1.16% per branch, three branches:

**≈3.49% of data packets are misclassified as handshakes and dropped.**

Feeding that into the Mathis model at 22ms RTT and a 1140-byte MSS predicts 2.7 Mbit/s. Measured:
1.7-2.4 Mbit/s against a ~100 Mbit/s baseline.

Setting `S1 = S2 = S3 = S4` removes the failure completely: every branch then reads the *true*
type field, and because `H1`-`H4` must not overlap, a transport packet cannot match the
initiation, response or cookie range. Narrowing `H1`-`H4` to `1,2,3,4` fixes it independently, by
shrinking each range to a single value.

This is what the upstream docs mean by "when using `RandomTrailers` it is recommended to set the
same values for `S1`, `S2`, `S3` and `S4`".

## Measurements

Client: userspace `amneziawg-go` 3.1.20260814, 20-core desktop. Server: `amneziawg` kernel module
3.1.20260812, 1 vCPU. 22ms RTT, client path MTU 1280, tunnel MTU 1180. Without the tunnel the
link does 107↑ / 181↓ Mbit/s. Server CPU stayed at 36-40% throughout, so none of this is
CPU-bound.

| Configuration | ↑ Mbit/s | ↓ Mbit/s | wire bytes per 64-byte ping |
|---|---:|---:|---:|
| plain WireGuard | 100.5 | 132.4 | 170 |
| `HeaderProtectionKey` + `S=12` | 99.7 | 131.6 | 182 |
| ↑ plus `RandomTrailers` | 99.7 | 125.3 | 537 |
| ↑ plus `ContentPaddingAddition 1-16` | 99.7 | 102.4 | 186 |
| `RandomTrailers` + unequal S + wide H | **1.7** | 115.0 | 258 |
| ↑ at the default 1420 MTU (S4=27) | **0.5** | 75.5 | 263 |

The small-packet column is measured *after* a bulk transfer, so the trailer window has grown to
full MTU — the realistic case for mixed traffic.

Each of these independently repairs the collapse, confirming the mechanism:

| Variant | ↑ Mbit/s |
|---|---:|
| unequal `S`, wide `H`, trailers on | 1.7 / 2.4 |
| same but trailers off | 98.0 / 98.6 |
| same but `S1=S2=S3=S4` | 95.1 / 99.4 |
| same but `H1..H4 = 1,2,3,4` | 98.5 / 95.3 |

## Per-parameter notes

**`HeaderProtectionKey` is effectively free** — 131.6 vs 132.4 Mbit/s. One ChaCha20 init and a
16-byte XOR per packet, plus the `S ≥ 12` floor it forces. Keep it on for 3.x.

**`RandomTrailers` costs little on bulk, a lot on small packets.** Bulk barely moves (125.3 vs
131.6) because the trailer short-circuits for full-size packets — `peer.h:105` checks
`udp_window > size`, which is false when the packet already *is* the largest seen. Small packets
are where it lands: a 64-byte ping costs 537 wire bytes instead of 182, roughly 3x. That falls on
TCP ACKs, DNS and VoIP, and it is metered traffic on mobile.

**`ContentPaddingAddition` costs ~22% of download.** 102.4 vs 131.6, reproduced across six runs,
zero retransmits, server at 37% CPU. `tcpdump` shows why:

```
no CPA:   88789 packets of 1228 bytes,  39297 of 108      <- two uniform sizes
with CPA:  4421 of 1232, 4416 of 1235, 4406 of 1233, ...  <- smeared over ~16 sizes
```

`amneziawg-go` receives with socket-level `UDP_GRO` (`conn/gso_linux.go`), and the kernel only
coalesces **consecutive equal-sized** datagrams into one read. Randomizing every length defeats
that batching, so the client pays per-datagram overhead instead of per-batch. `RandomTrailers`
avoids this because it leaves full-size packets alone.

The 22% is measured and reproduced; the `UDP_GRO` attribution is inference from the size
distributions plus the code, not an isolated experiment.

**`S4` is the MTU-relevant one.** Overhead is `60 + S4` on IPv4. At the default 1420 tunnel MTU,
`S4 > 20` pushes full-size packets past 1500 and every one fragments — that is the 75.5 Mbit/s row
above. Many mobile networks and CGNATs drop IP fragments outright, so the symptom is "pings fine,
downloads crawl".

The formula is verified to the byte, not inferred: `struct message_data` is 16 bytes (type 4 +
key index 4 + counter 8) plus a 16-byte Poly1305 tag, and a wire capture of a tunnel running
`MTU 1208, S4 12` showed 118,559 of 118,565 full-size datagrams at exactly
`1208 + 12 + 32 = 1252` bytes of UDP payload — 1280 on the wire, the path MTU exactly. The
`route MTU − 80 → 1420` default is `set_mtu_up()` in `awg-quick`, confirmed by bringing up a
conf with no `MTU` line. The 6 remaining datagrams were oversized kernel-side handshake-burst
packets above the trailer window cap (up to 1443 B, cause unidentified) — negligible for
throughput since handshakes retry, but a reason not to state that trailers can *never* fragment.

## A note on where padding is capped

Both `ContentPaddingAddition` and `RandomTrailers` cap their padding at `udp_window − packet_len`,
where `udp_window` is a high-water mark over datagrams both sent *and* received (`send.c:243`,
`receive.c:571`), starting at 500. It is **not** capped at the MTU, which is a common
misconception. Because receiving a padded datagram raises the mark, content padding does grow
full-size sends slightly — measured 1228 → 1229-1244 on the wire. For *transport* packets the cap
holds and fragmentation stays impossible in practice (verified: 118,559 of 118,565 captured
full-size datagrams at exactly the cap). It is not absolute, though: the handshake-burst
outliers above were observed over the cap, so treat "cannot fragment" as a transport-path
property rather than a guarantee about every packet the tunnel emits. Neither mechanism is
quite as free as "only pads small packets" implies either.

## Recommended shape

Best speed while still genuinely 3.1:

```ini
S1 = 12          # all four equal — required with RandomTrailers
S2 = 12
S3 = 12
S4 = 12          # HeaderProtectionKey floor; <= 20 keeps MTU 1420 safe
HeaderProtectionKey = <32 random bytes, base64>
RandomTrailers = on
# ContentPaddingAddition deliberately not set
MTU = 1280
```

Cost against plain WireGuard: **−1% upload, −5% download, +0.3ms RTT.**

Drop `RandomTrailers` too and you are within 1% of plain WireGuard both ways, with small packets
back to 182 bytes. That is the right trade for latency-sensitive or metered traffic.

## Reproducing

```bash
git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
rg -n -A8 'u16_range_is_zero\(content_padding_addition\)' src/send.c  # padding precedence
rg -n 'random_trailers \? skb->len' src/receive.c                     # loose type matching
rg -n -B2 -A6 'HEADER_PROTECTION_NONCE_SIZE' src/netlink.c            # the S >= 12 floor
```
