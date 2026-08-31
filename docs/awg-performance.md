# AmneziaWG obfuscation: speed and latency

How each obfuscation parameter costs throughput, why, and which values to pick. Everything here is traced to upstream source and confirmed by measurement over a real internet path.

Short version: **`RandomTrailers` combined with unequal `S1`-`S4` costs 98% of upload throughput.** The container generates exactly that combination under `AWG_VERSION=3.1`. See [Recommended parameters](#recommended-parameters).

## Which parameters cost anything

Obfuscation splits cleanly into handshake-time and per-packet work. Only the second group can affect steady-state speed.

| Parameter | Per-packet cost | Where |
|---|---|---|
| `Jc`, `Jmin`, `Jmax` | none — handshake only | `send.c:71-89` |
| `S1`, `S2`, `S3` | none — init/response/cookie only | `send.c:89,161,179` |
| `I1`-`I5` | none — sent every 120s | — |
| `H1`-`H4` | none — a value substituted into an existing field | `send.c:293` |
| `S4` | **+S4 bytes + one CSPRNG call per packet** | `send.c:297-298` |
| `HeaderProtectionKey` | one `chacha_init` + 16-byte XOR per packet | `header_protection.c:6-23` |
| `ContentPaddingAddition` | **+random bytes per packet** | `peer.h:110-124` |
| `RandomTrailers` | **+random bytes per packet** | `peer.h:98-108` |

The three padding mechanisms are mutually exclusive, and the precedence is not obvious (`send.c:253-260`, mirrored in `amneziawg-go` `device/send.go:607-614`):

```c
if (!u16_range_is_zero(content_padding_addition))      // wins if set
    padding_len = wg_peer_skb_randomize_padding_addition(...);
else if (peer->device->random_trailers)                // only if CPA is unset
    padding_len = wg_peer_skb_random_trailer(...);
else
    padding_len = calculate_skb_padding(skb);          // stock: pad to multiple of 16
```

So setting `ContentPaddingAddition` silently disables `RandomTrailers` **on the send path**. It does *not* disable it on the receive path — see below.

## The upload collapse

`RandomTrailers` changes how a receiver identifies packet types. With it off, each type is matched by exact length; with it on, length becomes a lower bound only (`receive.c:51,62,73`):

```c
random_trailers ? skb->len >= expected_len : skb->len == expected_len
```

The receiver then tries init, response, cookie and transport in order. For each it reads a 4-byte type field at that type's own padding offset (`S1`, `S2`, `S3`, `S4`) and tests it against the matching `H` range.

Once `>=` always passes, the type check is the only thing left separating the branches. And because the container draws `S1`-`S4` independently, they differ — so the init/response/cookie branches read the type field at the **wrong offset** and get garbage. Garbage lands inside a 50,000,000-wide `H` range with probability 50e6 / 2³² = 1.16% per branch, three branches, so:

**≈3.49% of data packets are misclassified as handshake messages and dropped.**

Feeding that loss into the Mathis model at the measured 22ms RTT and 1140-byte MSS predicts 2.7 Mbit/s. Measured: 1.7-2.4 Mbit/s.

Making `S1 = S2 = S3 = S4` removes the failure entirely: every branch then reads the *true* type field, and since `H1`-`H4` must not overlap, a transport packet cannot match the init, response or cookie range. This is what the [upstream docs](https://docs.amnezia.org/documentation/amnezia-wg) mean by "when using `RandomTrailers` it is recommended to set the same values for `S1`, `S2`, `S3` and `S4`".

Setting `H1`-`H4` to `1,2,3,4` fixes it too, by shrinking each range to a single value. Upstream recommends that separately whenever `HeaderProtectionKey` is set, since header protection already encrypts the type field and custom `H` values add nothing on top.

### `ContentPaddingAddition` does not save you

`ContentPaddingAddition` suppresses `RandomTrailers` on send (`send.c:254`), but the receive-side matching reads the flag directly (`receive.c:47`):

```c
bool random_trailers = wg->random_trailers;   // not gated on CPA
```

Setting both gives you the loose matching and its misclassification risk with none of the trailer obfuscation. It is the worst of the two, which is why the container now leaves `ContentPaddingAddition` at `0` whenever trailers are on.

## Measurements

Client: this repo's image, userspace `amneziawg-go` 3.1.20260814, 20-core i5-14600K.
Server: `amneziawg` kernel module 3.1.20260812, 1 vCPU Xeon 6230R.
Path: 22ms RTT, client path MTU 1280, tunnel MTU 1180. Without the tunnel the link does 107↑ / 181↓ Mbit/s. Server CPU stayed at 36-40% throughout, so nothing here is CPU-bound.

| Configuration | ↑ Mbit/s | ↓ Mbit/s | wire bytes per 64-byte ping |
|---|---:|---:|---:|
| plain WireGuard (no obfuscation) | 100.5 | 132.4 | 170 |
| `HeaderProtectionKey` + `S=12`, no CPA/RT | 99.7 | 131.6 | 182 |
| ↑ plus `RandomTrailers` | 99.7 | 125.3 | 537 |
| ↑ plus `ContentPaddingAddition 1-16` | 99.7 | 102.4 | 186 |
| **container `AWG_VERSION=3.1` default** | **1.7** | 115.0 | 258 |
| ↑ at `awg-quick`'s default MTU 1420 | **0.5** | 75.5 | 263 |

The small-packet column is measured *after* a bulk transfer, so the trailer window has grown to full MTU — which is the realistic case for mixed traffic.

Each of these independently repairs the collapse, confirming the mechanism:

| Variant | ↑ Mbit/s |
|---|---:|
| unequal `S`, wide `H`, `RandomTrailers=on` (the broken default) | 1.7 / 2.4 |
| same but `RandomTrailers` off | 98.0 / 98.6 |
| same but `S1=S2=S3=S4` | 95.1 / 99.4 |
| same but `H1..H4 = 1,2,3,4` | 98.5 / 95.3 |

### `HeaderProtectionKey` is effectively free

131.6 vs 132.4 Mbit/s. It costs one ChaCha20 init and a 16-byte XOR per packet, plus the `S4 ≥ 12` floor it forces (`netlink.c:810`). Keep it.

### `RandomTrailers` costs little bulk, a lot on small packets

Bulk throughput barely moves (125.3 vs 131.6 down) because the trailer short-circuits for full-size packets (`peer.h:105`, `udp_window > size` is false when the packet already *is* the largest seen). Small packets are where it lands: a 64-byte ping costs 537 wire bytes instead of 182, roughly 3x. That falls on TCP ACKs, DNS and VoIP, and it is metered traffic on mobile.

### `ContentPaddingAddition` costs 22% of download

102.4 vs 131.6 Mbit/s, reproduced across six runs, with zero retransmits and the server at 37% CPU. `tcpdump` on the server shows why:

```
no CPA:   88789 packets of 1228 bytes,  39297 of 108      <- two uniform sizes
with CPA:  4421 of 1232, 4416 of 1235, 4406 of 1233, ...  <- smeared over ~16 sizes
```

`amneziawg-go` receives with socket-level `UDP_GRO` (`conn/gso_linux.go`), and the kernel only coalesces **consecutive equal-sized** datagrams into one read. Randomizing every packet's length defeats that batching, so the client pays per-datagram syscall and processing overhead instead of per-batch. `RandomTrailers` avoids this because it leaves full-size packets alone; `ContentPaddingAddition` does not, because its clamp is the observed UDP window rather than the MTU, and the window ratchets above the current packet size.

The 22% figure is measured directly and reproduced. The GRO attribution is inference from the size distributions plus the code — it was not isolated by toggling `UDP_GRO`.

> The README's per-packet table previously said `ContentPaddingAddition` adds nothing to a full-size packet because it is capped at the MTU. That is not right: the cap is `udp_window - packet_len` (`peer.h:110-124`), where `udp_window` is a high-water mark over every datagram sent *and received* (`send.c:243`, `receive.c:571`). Receiving padded packets raises it, so full-size sends do get padded — 1228 becomes 1229-1244 above.

## MTU

Per-packet overhead is `20 (IPv4) + 8 (UDP) + 32 (AWG header + tag) + S4` = **`60 + S4`**.

`awg-quick` writes `route MTU − 80` = 1420 and knows nothing about `S4`, so on a 1500-byte IPv4 path:

- `S4 ≤ 20` → 1420 fits. **Keep `S4` at or below 20 and the default MTU is safe.**
- `S4 = 27` (a value the container picks often) → ceiling is 1413, so every full-size packet fragments. That is the 75.5 Mbit/s row above.

See [MTU](../README.md#mtu) for choosing a value; nothing in this document changes that guidance.

## Recommended parameters

Best speed while still genuinely AWG 3.1:

```ini
Jc = 6
Jmin = 76
Jmax = 236
S1 = 12          # all four equal — required when RandomTrailers is on
S2 = 12
S3 = 12
S4 = 12          # HeaderProtectionKey floor; ≤ 20 keeps MTU 1420 safe
H1 = 205127846-255127846
H2 = 592243917-642243917
H3 = 1526611121-1576611121
H4 = 1669322812-1719322812
I1 = <b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>
HeaderProtectionKey = <32 random bytes, base64>
RandomTrailers = on
MTU = 1280       # or path MTU − 60 − S4; awg-quick's 1420 ignores S4
# ContentPaddingAddition deliberately NOT set
# DisableCookies deliberately NOT set — it costs nothing in throughput and
# gives up WireGuard's DoS mitigation, so enable it only for DPI reasons
```

`MTU` is per-endpoint and does not have to match. 1280 assumes a 1500-byte path;
a client that is itself behind a 1280-byte path needs `1280 − 60 − S4` = 1208
instead, so measure rather than assume — see [MTU](#mtu) above.

Cost against plain WireGuard: **−1% upload, −5% download, +0.3ms RTT.**

Drop `RandomTrailers = on` as well and you are within 1% of plain WireGuard in both directions, with small packets back down to 182 bytes. That is the right trade if you carry a lot of latency-sensitive or metered traffic and can give up trailer obfuscation.

Do not set `ContentPaddingAddition`. It costs 22% of download, and setting it alongside `RandomTrailers` also disables the trailers on send while keeping the receive-side risk.

## Reproducing

```bash
# per-packet padding precedence
git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
rg -n -A8 'u16_range_is_zero\(content_padding_addition\)' src/send.c

# receive-side type matching
rg -n 'random_trailers \? skb->len' src/receive.c

# the S >= 12 floor under header protection
rg -n -B2 -A6 'HEADER_PROTECTION_NONCE_SIZE' src/netlink.c
```

## Sources

- [amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) — `src/send.c`, `src/receive.c`, `src/peer.h`, `src/netlink.c`, `src/header_protection.c`
- [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) — `device/send.go`, `device/receive.go`, `conn/gso_linux.go`
- [Official AmneziaWG parameter docs](https://docs.amnezia.org/documentation/amnezia-wg)
- [Any Tech ARCHITECT](https://github.com/Vadim-Khristenko/Any-Tech-ARCHITECT) — parameter generator and per-parameter rationale
