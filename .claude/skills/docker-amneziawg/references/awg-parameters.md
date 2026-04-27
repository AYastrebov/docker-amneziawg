# AmneziaWG Obfuscation Parameters

AmneziaWG extends WireGuard with traffic obfuscation to bypass Deep Packet Inspection (DPI). These parameters modify packet structure to make VPN traffic unrecognizable.

**Critical**: Server and all clients must use identical obfuscation values.

## Parameter Categories

### Junk Packets (Jc, Jmin, Jmax)

Random data packets sent before each handshake to confuse traffic analysis.

| Parameter | Type | Default | Constraints | Description |
|-----------|------|---------|-------------|-------------|
| `AWG_JC` | int | Random 3-8 | 1-128, recommended 4-12 | Number of junk packets per handshake |
| `AWG_JMIN` | int | Random 40-80 | < JMAX | Minimum junk packet size in bytes |
| `AWG_JMAX` | int | Random 80-250 | ≤ 1280 | Maximum junk packet size in bytes |

**How it works**: Before initiating a handshake, the client sends `Jc` packets of random data with sizes between `Jmin` and `Jmax` bytes. This obscures the handshake pattern that DPI systems look for.

**Note**: Jc, Jmin, and Jmax may vary between client and server (unlike other parameters).

### Packet Padding (S1, S2, S3, S4)

Adds padding bytes to different message types to obscure their true size.

| Parameter | Type | Default | Constraints | Message Type |
|-----------|------|---------|-------------|--------------|
| `AWG_S1` | int | Random 15-150 | ≤ 1132 (1280-148) | Handshake initiation |
| `AWG_S2` | int | Random 15-150 | ≤ 1188 (1280-92) | Handshake response |
| `AWG_S3` | int | Random 8-55 (2.0) / 0 (1.5) | ≤ 64 | Cookie reply |
| `AWG_S4` | int | Random 4-27 (2.0) / 0 (1.5) | ≤ 32 | Transport data (per-packet overhead, keep small) |

**Critical constraint**: `S1 + 56 ≠ S2` (these values must not have this relationship)

**How it works**: Each parameter specifies how many random padding bytes to add to that message type. This prevents DPI from identifying messages by their characteristic sizes.

**Note**: S3 and S4 are AWG 2.0 extensions (set to 0 in AWG 1.5). S4 should be kept small (4-27) since it adds overhead to every data packet. S3 can be slightly larger (8-55) since cookie replies are rare.

### Header Obfuscation (H1, H2, H3, H4)

Modifies the 4-byte type field at the start of each packet.

| Parameter | Type | Default | Constraints | Message Type |
|-----------|------|---------|-------------|--------------|
| `AWG_H1` | string | Random | 5-2147483647, unique | Handshake initiation (normally: 1) |
| `AWG_H2` | string | Random | 5-2147483647, unique | Handshake response (normally: 2) |
| `AWG_H3` | string | Random | 5-2147483647, unique | Cookie reply (normally: 3) |
| `AWG_H4` | string | Random | 5-2147483647, unique | Transport data (normally: 4) |

**How it works**: Standard WireGuard uses fixed values 1-4 to identify packet types. AmneziaWG replaces these with arbitrary 32-bit integers, making traffic unrecognizable as WireGuard.

**Critical constraint**: H1, H2, H3, and H4 must all be different from each other.

**Value range**: 5 to 2147483647 (positive 32-bit integers, minimum 5 to avoid collision with standard WireGuard values)

**AWG 2.0 range format**: H1-H4 also support range syntax (e.g., `H1 = 100-999`). When a range is specified, the actual header value is chosen randomly from that range for each packet, providing additional randomization.

## Implementation in This Project

### Generation (init-amneziawg-confs/run)

```bash
# Junk packets
AWG_JC=${AWG_JC:-$(shuf -i 3-8 -n 1)}
AWG_JMIN=${AWG_JMIN:-$(shuf -i 40-80 -n 1)}
AWG_JMAX=${AWG_JMAX:-$(shuf -i 80-250 -n 1)}

# Padding
AWG_S1=${AWG_S1:-$(shuf -i 15-150 -n 1)}
AWG_S2=${AWG_S2:-$(shuf -i 15-150 -n 1)}
AWG_S3=${AWG_S3:-$(shuf -i 8-55 -n 1)}   # AWG 2.0
AWG_S4=${AWG_S4:-$(shuf -i 4-27 -n 1)}   # AWG 2.0, keep small (per-packet)

# Headers (min 5 to avoid collision with standard WireGuard values 1-4)
AWG_H1=${AWG_H1:-$(shuf -i 5-2147483647 -n 1)}
AWG_H2=${AWG_H2:-$(shuf -i 5-2147483647 -n 1)}
AWG_H3=${AWG_H3:-$(shuf -i 5-2147483647 -n 1)}
AWG_H4=${AWG_H4:-$(shuf -i 5-2147483647 -n 1)}
```

### Persistence

Values are saved to `/config/server/awg_params` for consistency across container restarts:

```
AWG_JC=5
AWG_JMIN=62
AWG_JMAX=847
AWG_S1=98
AWG_S2=45
AWG_S3=25
AWG_S4=12
AWG_H1=1755269708
AWG_H2=2101520157
AWG_H3=1829552136
AWG_H4=2016351429
```

### Config File Format

Parameters appear in both server and peer configs under `[Interface]`:

```ini
[Interface]
Address = 10.13.13.1/24
PrivateKey = ...
# AmneziaWG Obfuscation Parameters
Jc = 5
Jmin = 62
Jmax = 180
S1 = 98
S2 = 45
S3 = 25
S4 = 12
H1 = 1755269708
H2 = 2101520157
H3 = 1829552136
H4 = 2016351429
```

## Custom Protocol Signature Packets (I1-I5) - AWG 2.0

AWG 2.0 introduces Custom Protocol Signature (CPS) packets that are sent before handshakes to masquerade VPN traffic as other UDP protocols.

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `AWG_I1` | string | (empty) | First signature packet definition |
| `AWG_I2` | string | (empty) | Second signature packet |
| `AWG_I3` | string | (empty) | Third signature packet |
| `AWG_I4` | string | (empty) | Fourth signature packet |
| `AWG_I5` | string | (empty) | Fifth signature packet |

**Important**: I1 is required for I2-I5 to work. All signature packets form a chain.

### Tag Syntax

| Tag | Description | Example | Output |
|-----|-------------|---------|--------|
| `<b 0xHEX>` | Static hex bytes | `<b 0x170303>` | `\x17\x03\x03` |
| `<r N>` | N random bytes (max 1000) | `<r 32>` | 32 random bytes |
| `<rd N>` | N random digits (0-9) | `<rd 8>` | 8 random digit bytes |
| `<rc N>` | N random characters (a-zA-Z) | `<rc 16>` | 16 random letter bytes |
| `<t>` | 32-bit Unix timestamp | `<t>` | Current epoch time |

**Maximum packet size**: 5KB per signature packet.

### Use Cases

#### Scenario 1: Protocol Allowlisting

When networks only permit specific UDP protocols (TLS over UDP, DNS, QUIC):

```bash
# Mimic TLS record layer
AWG_I1=<b 0x160301><r 2><b 0x0100><r 32><t>
```

#### Scenario 2: Sophisticated DPI

When DPI systems inspect packet patterns deeply:

```bash
# Multi-packet signature chain
AWG_I1=<b 0x170303><r 2><b 0x0100><t>
AWG_I2=<b 0x170303><r 4><c>
```

#### Scenario 3: Protocol Mimicry

To make traffic appear as specific applications:

```bash
# DNS-like signature (starts with transaction ID)
AWG_I1=<r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>
```

### Sample Configurations

#### TLS ClientHello-like

```ini
[Interface]
# ... other params ...
I1 = <b 0x160301><r 2><b 0x0100><r 32><t>
```

#### QUIC-like

```ini
[Interface]
# ... other params ...
I1 = <b 0xc0><r 4><b 0x00000001><r 16><t>
```

### Implementation in This Project

#### Generation (init-amneziawg-confs/run)

At first startup (when `AWG_I1` is not set), `generate_default_signatures()` sets a QUIC Initial packet —
the same default used by the Amnezia app itself. The spec is persisted like all other AWG params.

```bash
# QUIC Initial (RFC 9000) ~1200B — Amnezia app default
AWG_I1="<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>"
```

**Packet breakdown:**
- `<b 0xc3>` — Long Header byte: Initial packet, 4-byte packet number
- `<b 0x00000001>` — QUIC version 1 (RFC 9000)
- `<b 0x08><r 8>` — DCID length=8, 8 random bytes (unique per connection)
- `<b 0x00><b 0x00>` — SCID length=0, token length=0
- `<b 0x449e>` — 2-byte QUIC length varint = 1182 (packet_number + payload)
- `<r 4>` — random packet number
- `<r 1178>` — random encrypted payload (AEAD ciphertext looks random)
- **Total: 1200 bytes** — meets RFC 9000 §14.1 minimum

**Why QUIC, not TLS ClientHello (0x160301)?** TLS runs over TCP. Sending a TLS record header over UDP
is anomalous and detectable by DPI systems that validate protocol-transport pairings. QUIC is designed
for UDP and is what Chrome/Firefox use for HTTPS — a QUIC packet on a UDP port is completely unremarkable.

**For custom protocols** (DNS, DTLS, SIP, HTTP/3): use [AmneziaWG Architect](https://architect.vai-rice.space/)
to generate a tailored I1 and set it via `AWG_I1=...` in your compose file.

**Supported amneziawg-go tags**: `<b 0xHEX>`, `<r N>`, `<rc N>`, `<rd N>`, `<t>`

#### Config File Output

I1-I5 are only written to config files when set (not empty):

```bash
[[ -n "$AWG_I1" ]] && echo "I1 = ${AWG_I1}" >> config.conf
```

#### Persistence

Values are saved to `/config/server/awg_params`:

```
AWG_I1=<b 0xc3><b 0x00000001><b 0x08><r 8><b 0x00><b 0x00><b 0x449e><r 4><r 1178>
AWG_I2=
AWG_I3=
AWG_I4=
AWG_I5=
```

Note: `<r N>` tags are expanded to fresh random bytes at each handshake by amneziawg-go — the spec
string itself is static, but every connection produces a unique packet.

### Compatibility Notes

- Requires AWG 2.0 compatible kernel module or `amneziawg-go` userspace
- Requires AWG 2.0 compatible tools (amneziawg-tools with CPS support)
- Requires AWG 2.0 compatible clients (AmneziaVPN 4.x+)
- Server and all clients must have matching I1-I5 values
- Standard WireGuard clients will NOT work with I1-I5 enabled
- Leave I1-I5 empty for backward compatibility with older clients

## Troubleshooting

### Connection fails after changing parameters
All clients must be updated with matching values. Regenerate peer configs and redistribute.

### High CPU usage
Reduce `Jc` value. More junk packets = more processing overhead.

### Handshake timeout
Ensure `JMAX` isn't too large. Very large junk packets may be dropped by some networks.

## References

- [AmneziaWG Kernel Module Configuration](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module#configuration) - Official parameter constraints
- [amneziawg-go README](https://github.com/amnezia-vpn/amneziawg-go) — Go userspace implementation; source of truth for supported tags and validation
- [AmneziaVPN Documentation](https://docs.amnezia.org/)
- [AmneziaWG Architect](https://architect.vai-rice.space/) ([source](https://github.com/Vadim-Khristenko/AmneziaWG-Architect)) — GUI config generator with 9 protocol presets (QUIC, DTLS, DNS, SIP, HTTP/3…); good reference for realistic I1 packet structures
- [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) — Bare-metal Bash installer; reference for S3/S4/Jmin/Jmax ranges and H1-H4 generation
- [pumbaX/awg-multi-script](https://github.com/pumbaX/awg-multi-script) — Multi-server setup script; reference for S3/S4/Jmax ranges
