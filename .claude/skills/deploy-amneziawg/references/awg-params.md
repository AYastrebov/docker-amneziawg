# AWG Obfuscation Parameters — Deployment Reference

This reference is specific to deployment-time decisions. For implementation/code-level details, see the project's `CONTEXT.md` and `.claude/skills/docker-amneziawg/references/awg-parameters.md`. For the throughput cost of each parameter, see [`docs/awg-performance.md`](../../../../docs/awg-performance.md).

> [!WARNING]
> **`AWG_VERSION=3.1` as the container generates it today is slow.** It emits `RandomTrailers=on` together with independently-drawn `S1`-`S4`, which makes the receiver misclassify and drop ~3.5% of transport packets — measured upload falls from ~100 to ~2 Mbit/s. When deploying 3.1, pin `S1 = S2 = S3 = S4` explicitly (`scripts/gen-awg-params.sh --version 3.1` now does this). Details and measurements: [`docs/awg-performance.md`](../../../../docs/awg-performance.md).

## Relationship to upstream Amnezia docs

The [official AmneziaWG self-hosted page](https://docs.amnezia.org/documentation/instructions/new-amneziawg-selfhosted/) deliberately publishes **no numeric defaults or constraint tables** — upstream expects users to install via the AmneziaVPN desktop app, which handles parameter generation invisibly over SSH. This Docker container reproduces that auto-generation logic explicitly, with the constraints documented below.

Practically: if a user is following upstream docs by hand, they'll have to fill in S/H/I/J values themselves. This skill should default to *not* asking them — the container will randomize on first boot. Only override if the user has a concrete reason.

## TL;DR for deploy

**The default behavior is correct for almost everyone.** If the user doesn't have strong opinions:

- Set `AWG_VERSION=2.0` (or omit — `2.0` is the default). Move to `3.0`/`3.1` only when every client is known to support it.
- Leave **all** `AWG_*` parameters unset in `docker-compose.yml`.
- The container generates valid random values on first start, respecting every constraint, and persists them to `/config/server/awg_params`. Restarts reuse the saved values.

Override only if:
1. The user is migrating from an existing AmneziaWG setup and needs to match its parameters.
2. The user wants to back up the compose file alone (not the `config/` directory) and have the same params on rebuild — pin the values in compose.
3. The user has a specific reason (custom CPS for a particular protocol disguise, matching a partner's setup, etc.).

## Version comparison

| Feature | AWG 2.0 (default) | AWG 1.5 |
|---|---|---|
| S3/S4 | Random non-zero | Fixed 0 |
| H1-H4 format | Range pairs (`90666522-140666522`) — required for AmneziaVPN app to recognize as AWG 2.0 | Single integers (`90666522`) |
| I1-I5 | I1 auto-generated as QUIC Initial packet (RFC 9000); I2-I5 empty | All empty (disabled) |
| AmneziaVPN client | 4.8.12.9+ required | Any version |
| DPI resistance | Strong (mimics QUIC, randomized padding everywhere) | Weaker (no CPS, no per-packet padding) |

**Choose 1.5 only if** the user explicitly needs to support clients on AmneziaVPN < 4.8.12.9 — e.g., older Android devices stuck on an old Play Store version, or non-Amnezia third-party AWG clients that haven't implemented 2.0.

### AWG 3.0 and 3.1

`AWG_VERSION=3.0` adds a second parameter set on top of everything 2.0 does:

| Param | Default (random) | Notes |
|---|---|---|
| `AWG_HEADER_PROTECTION_KEY` | 32 random bytes, base64 | Encrypts packet headers. **Must be identical on server and every client.** Requires S1-S4 ≥ 12 — the nonce is read from the first 12 bytes of the S-padding |
| `AWG_CONTENT_PADDING` | `lo-hi` within 16-128 | Extra random padding per transport packet. `0` disables. **Recommend `0`** — measured at ~22% of download throughput, and it suppresses `RandomTrailers` on the send path while leaving the receive path's loose matching on |
| `AWG_REKEY_AFTER_TIME` | `lo-hi` within 100-145s | WireGuard default is 120 |
| `AWG_REKEY_TIMEOUT` | `lo-hi` within 4-10s | Default 5 |
| `AWG_REJECT_AFTER_TIME` | `lo-hi`, derived | Default 180. Must exceed RekeyAfterTime.hi, and KeepaliveTimeout.lo + RekeyTimeout.lo |
| `AWG_KEEPALIVE_TIMEOUT` | `lo-hi` within 8-22s | Default 10 |
| `AWG_MAX_HANDSHAKE_ATTEMPTS` | `lo-hi` within 12-28 | Default 18 |

Timers are **ranges**, and each endpoint draws its own value from within the range — the two sides do not have to land on the same number. Only `HeaderProtectionKey` must match.

`AWG_VERSION=3.1` is a preset: the 3.0 parameter set plus `AWG_RANDOM_TRAILERS=on`. AWG 3.1 itself is not a new parameter set upstream — it is two independent `[Interface]` booleans:

| Env var | Effect | Must match on both ends |
|---|---|:---:|
| `AWG_RANDOM_TRAILERS` | Random-length trailer on handshake init/response/cookie-reply packets, so they lose their fixed length | **Yes** |
| `AWG_DISABLE_COOKIES` | No cookie-reply messages under load, removing a distinctive probe response. Costs WireGuard's DoS mitigation | No |

Both accept `on`/`off` and work with **any** `AWG_VERSION`, so `2.0` + `AWG_RANDOM_TRAILERS=on` is a valid combination. Only `on` writes a key; unset or `off` omits it entirely rather than writing `= off`.

#### `RandomTrailers` requires `S1 = S2 = S3 = S4`

Turning trailers on relaxes the receiver's packet-type check from an exact length match to `>=`, leaving only the `H` range test to tell types apart. With `S1`-`S4` all different, three of the four branches read the type field at the wrong offset; garbage lands inside a 50M-wide `H` range about 1.16% of the time each, so ~3.5% of transport packets get dropped as malformed handshakes. Measured: **upload 100 → 2 Mbit/s**.

Whenever you deploy `AWG_RANDOM_TRAILERS=on` alongside AWG 2.0+ (which uses wide `H` ranges), pin all four `S` values to the same number:

```yaml
      - AWG_RANDOM_TRAILERS=on
      - AWG_S1=12
      - AWG_S2=12
      - AWG_S3=12
      - AWG_S4=12
      - AWG_CONTENT_PADDING=0
```

`scripts/gen-awg-params.sh --version 3.1` emits exactly this shape. AWG 1.5 is exempt — its `H` values are single integers, so a wrong-offset read matches with probability 2⁻³², not 1.16%.

Do **not** set `AWG_CONTENT_PADDING` alongside trailers: it takes precedence on the send path and suppresses them, but the receiver still runs the loose match, so you get the risk and none of the obfuscation. The generator refuses that combination.

`off` is also the way to turn a switch back off — an absent variable means "reuse the saved value" from `/config/server/awg_params`, and an empty one is indistinguishable from absent because s6 drops empty variables from `container_environment`.

`AWG_DISABLE_COOKIES` is never turned on implicitly, including under `3.1` — it is a security trade the user should make deliberately.

**Kernel datapath caveat.** The bundled userspace `amneziawg-go` is a 3.1 build and always accepts these keys. The host `amneziawg` kernel module may not be: check `cat /sys/module/amneziawg/version` and require ≥ 3.1. On an older module the bundled `awg` parses the keys and the kernel refuses them, so `awg-quick` fails with `Unable to modify interface: Invalid argument` and the tunnel does not come up. (`Line unrecognized` is what older *userspace* tools report instead — not applicable inside this container.) The container warns at startup when it can read a numeric version from that file, and stays silent otherwise, so check it yourself rather than treating no warning as an all-clear.

## Parameter constraints (full table)

All values are integers unless noted.

| Param | Range | Default (random) | Constraint |
|---|---|---|---|
| `AWG_JC` | 1-128 | 3-8 | Junk packet count before handshake. Higher = more noise but slower handshake. |
| `AWG_JMIN` | 1-1279 | 40-80 | Min junk packet size in bytes. Must be < `JMAX`. |
| `AWG_JMAX` | 2-1280 | 80-250 | Max junk packet size in bytes. |
| `AWG_S1` | 0-1132 | 15-150 | Init packet padding. **S1 + 56 must ≠ S2** (otherwise looks like base WireGuard). |
| `AWG_S2` | 0-1188 | 15-150 | Response packet padding. |
| `AWG_S3` | 0-64 | 8-55 (2.0) / 12-55 (3.x) / 0 (1.5) | Cookie message padding. |
| `AWG_S4` | 0-32 | 4-20 (2.0) / 12-20 (3.x) / 0 (1.5) | Transport packet padding. **Per-packet overhead — keep small** (every data packet pays this cost). Keep **≤ 20**: overhead is `60 + S4`, so anything above 20 pushes a full-size packet past 1500 at `awg-quick`'s default 1420 MTU and fragments every one of them. |
| `AWG_H1`-`H4` | ≥ 5 | Quadrant ranges (2.0) / single ints (1.5) | All four must be unique. Values 1-4 are reserved for standard WireGuard header types. |
| `AWG_I1`-`I5` | tag syntax string | QUIC Initial for I1 in 2.0, all empty in 1.5 | I1 must be set for I2-I5 to be meaningful. Tag syntax may contain `=`, parse with `cut -d= -f2-` not `-f2`. |

### Why the H constraint matters

When using AWG 2.0, the H1-H4 values **must use range format** (like `90666522-140666522`) for the AmneziaVPN client to identify the server as AWG 2.0. Single integers (legal in AWG 1.5) cause the client to report "AWG 1.5" and disables I1-I5 processing.

The container's auto-generator picks four non-overlapping ranges within the 32-bit unsigned space, one per "quadrant" of the value space. This is what you want.

### Why S1+56 ≠ S2 matters

The init/response handshake packets in WireGuard have a 56-byte length difference. If `S1 + 56 == S2`, the *padded* packets are the same size as the *unpadded* ones — which makes the obfuscation pointless because DPI can fingerprint the size signature. The container's randomizer avoids this collision; if the user supplies values manually, validate.

## Generating values manually

Use `scripts/gen-awg-params.sh` to produce a valid set. The script implements all constraints and prints the values as an env-var block you can paste into `docker-compose.yml`.

## When server and client values must match

| Param | Must match | Can differ |
|---|---|---|
| S1, S2, S3, S4 | ✅ Server and every client | — |
| H1, H2, H3, H4 | ✅ Server and every client | — |
| I1, I2, I3, I4, I5 | ✅ Server and every client | — |
| Jc, Jmin, Jmax | ❌ | ✅ Per-side (each side can have its own junk config) |

This is the "**redistribute every peer config**" footgun: if the user changes any of S/H/I after peers are already deployed, every existing peer config becomes invalid and needs to be re-issued. The container handles this correctly for newly-generated configs (they're built from the current `awg_params`), but old configs on user devices won't auto-update.

## Custom Protocol Signatures (I1-I5)

For AWG 2.0, the I1 packet disguises the first handshake as another UDP protocol. The container's default is a QUIC Initial packet (RFC 9000), which is a strong choice — QUIC traffic is extremely common and hard to block without false positives.

If the user wants to disguise as something else:

| Disguise | Where to get the CPS tag |
|---|---|
| QUIC Initial (default) | Auto-generated |
| DNS query | [AmneziaWG Architect](https://architect.vai-rice.space/) |
| DTLS / SIP / HTTP/3 / custom | [AmneziaWG Architect](https://architect.vai-rice.space/) |

CPS tag syntax:

| Tag | Description |
|---|---|
| `<b 0xHEX>` | Static hex bytes (e.g., `<b 0x170303>`) |
| `<r N>` | N random bytes (max 1000) |
| `<rd N>` | N random digits (0-9) |
| `<rc N>` | N random characters (a-zA-Z) |
| `<t>` | 32-bit Unix timestamp |

Example DNS query disguise (looks like a DNS request from a random source port):
```
AWG_I1=<b 0x0001><b 0x0100><b 0x00010000><b 0x00000000><rd 4><b 0x00000020><rc 8><b 0x076578616d706c6503636f6d00><b 0x0001><b 0x0001>
```

These are intentionally fiddly. **Don't ask the user to hand-write these.** If they want a non-default disguise, send them to the Architect web tool and ask them to paste in the resulting CPS string.
