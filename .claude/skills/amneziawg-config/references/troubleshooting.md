# Troubleshooting AmneziaWG

Start by running the linter — it catches most of what follows and explains each finding:

```bash
scripts/awg-lint.py wg0.conf peer1.conf
```

Pass the server conf *and* at least one peer conf when you can. A large share of "it used to
work" reports are a shared value drifting between the two, which is only visible by comparison.

## Symptom → cause

| Symptom | Most likely cause |
|---|---|
| **Upload collapses (~2 Mbit/s), download nearly fine** | `RandomTrailers = on` with unequal `S1`-`S4`. ~3.5% of data packets misclassified and dropped |
| **Download ~20-25% below expectations, upload fine** | `ContentPaddingAddition` set. Randomized datagram lengths defeat `UDP_GRO` batching |
| **Handshake succeeds, pings fine, downloads crawl** | MTU. `S4 > 20` at the default 1420 fragments every full-size packet |
| **Tunnel never comes up at all** | A shared value differs between ends (`S`/`H`/`I`/`HeaderProtectionKey`/`RandomTrailers`), or the endpoint software is too old for a key in the config |
| **`Unable to modify interface: Invalid argument`** | Kernel module older than the parameters used. Check `cat /sys/module/amneziawg/version` |
| **`Line unrecognized`** | Userspace `awg` tools older than the parameters used |
| **Worked before, one peer stopped after a change** | Shared values were regenerated server-side; that peer still has the old config and must be re-issued |
| **Amnezia app reports "AWG 1.5" for a 2.0 config** | `H1`-`H4` are single integers rather than ranges. Also disables `I1`-`I5` processing |
| **App connects but obfuscation seems inactive** | `I1`-`I5` placed under `[Peer]`. The app only inspects `[Interface]` |
| **High CPU on a small server** | Expected only at high packet rates; check for fragmentation first, it doubles packet count |

## Reading the direction of a failure

The direction that breaks is diagnostic, because the two endpoints often run different
implementations.

- **Upload broken, download fine** — the *server's* receive path is dropping packets. Packet-type
  misclassification lives here; it is the `RandomTrailers` + unequal `S` bug.
- **Download broken, upload fine** — the *client's* receive path, or the server's send path. Think
  `ContentPaddingAddition` (batching) or MTU/fragmentation.
- **Both directions equally slow** — usually MTU, or the link itself. Test without the tunnel
  first to establish a ceiling.

## Confirming an MTU problem

Find the real path MTU from the client:

```bash
lo=100; hi=1472
while [ $((hi-lo)) -gt 1 ]; do
    mid=$(((lo+hi)/2))
    if ping -c1 -W2 -M do -s $mid <server-ip> >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
done
echo "path MTU = $((lo+28))"
```

Then check the config fits: a full-size packet is `MTU + 60 + S4` on IPv4. If that exceeds the
measured path MTU, lower the tunnel `MTU` (1280 is safe everywhere) or lower `S4`.

Paths are frequently smaller than 1500 — PPPoE is 1492, LTE is often ≤1400, and DS-Lite or other
tunnelled access can land at 1280. The server usually has a clean 1500 and cannot know this, so
the client side is where the fragmentation actually happens.

## Confirming a misclassification problem

If upload is collapsed and `RandomTrailers = on`, compare `S1`-`S4`. If they differ, that is
almost certainly it. To confirm before changing anything, set `RandomTrailers = off` on both ends
— upload should return to normal immediately. Then decide whether to keep trailers with equal `S`
values, or leave them off.

Note that this bug does **not** show up as a handshake failure or as an obvious error in logs. The
misclassified packets are treated as malformed handshake messages and dropped silently; on the
kernel module you may see rate-limited `Unknown message` entries with `dyndbg` enabled, but
nothing by default.

## Verifying what is actually on the wire

```bash
# Largest UDP payloads on the tunnel port — should be uniform under bulk transfer
sudo timeout 7 tcpdump -i any -nn -q udp port <port> \
  | grep -oE 'length [0-9]+' | awk '{print $2}' | sort -n | uniq -c | sort -rn | head
```

Healthy bulk traffic shows one dominant large size and one dominant small size (data and ACKs). A
flat smear across many sizes means `ContentPaddingAddition` is active. Sizes above
`path MTU − 28` mean fragmentation.

Check the negotiated parameters actually in force:

```bash
awg show <interface>          # or: wg show, on a plain WireGuard build
```

This prints the live `jc/jmin/jmax/s1..s4/h1..h4/i1` and the 3.x keys, which is the authoritative
answer when a config file and the running interface might disagree.

## When peers must be re-issued

Changing any of `S1`-`S4`, `H1`-`H4`, `I1`-`I5` or `HeaderProtectionKey` invalidates every peer
config already handed out. There is no negotiation — a peer with stale values simply cannot be
understood. Regenerate and redistribute all of them together, and remember that configs already
imported into a phone app do not update themselves.

`Jc`/`Jmin`/`Jmax`, the 3.x timer ranges, and `DisableCookies` can be changed on one side alone.
