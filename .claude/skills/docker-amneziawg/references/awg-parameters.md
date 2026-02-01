# AmneziaWG Obfuscation Parameters

AmneziaWG extends WireGuard with traffic obfuscation to bypass Deep Packet Inspection (DPI). These parameters modify packet structure to make VPN traffic unrecognizable.

**Critical**: Server and all clients must use identical obfuscation values.

## Parameter Categories

### Junk Packets (Jc, Jmin, Jmax)

Random data packets sent before each handshake to confuse traffic analysis.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `AWG_JC` | int | Random 3-8 | Number of junk packets per handshake (recommended: 3-8) |
| `AWG_JMIN` | int | Random 40-80 | Minimum junk packet size in bytes |
| `AWG_JMAX` | int | Random 500-1000 | Maximum junk packet size in bytes |

**Constraints**: `JMIN` must be ≤ `JMAX`

**How it works**: Before initiating a handshake, the client sends `Jc` packets of random data with sizes between `Jmin` and `Jmax` bytes. This obscures the handshake pattern that DPI systems look for.

### Packet Padding (S1, S2, S3, S4)

Adds padding bytes to different message types to obscure their true size.

| Parameter | Type | Default | Message Type |
|-----------|------|---------|--------------|
| `AWG_S1` | int | Random 15-150 | Handshake initiation |
| `AWG_S2` | int | Random 15-150 | Handshake response |
| `AWG_S3` | int | 0 | Cookie reply |
| `AWG_S4` | int | 0 | Transport data |

**How it works**: Each parameter specifies how many random padding bytes to add to that message type. This prevents DPI from identifying messages by their characteristic sizes.

**Note**: S3 and S4 are typically left at 0 for most use cases. S1 and S2 provide sufficient obfuscation for handshakes.

### Header Obfuscation (H1, H2, H3, H4)

Modifies the 4-byte type field at the start of each packet.

| Parameter | Type | Default | Message Type |
|-----------|------|---------|--------------|
| `AWG_H1` | int32 | Random | Handshake initiation (normally: 1) |
| `AWG_H2` | int32 | Random | Handshake response (normally: 2) |
| `AWG_H3` | int32 | Random | Cookie reply (normally: 3) |
| `AWG_H4` | int32 | Random | Transport data (normally: 4) |

**How it works**: Standard WireGuard uses fixed values 1-4 to identify packet types. AmneziaWG replaces these with arbitrary 32-bit integers, making traffic unrecognizable as WireGuard.

**Value range**: 1 to 2147483647 (positive 32-bit integers)

## Implementation in This Project

### Generation (init-amneziawg-confs/run)

```bash
# Junk packets
AWG_JC=${AWG_JC:-$(shuf -i 3-8 -n 1)}
AWG_JMIN=${AWG_JMIN:-$(shuf -i 40-80 -n 1)}
AWG_JMAX=${AWG_JMAX:-$(shuf -i 500-1000 -n 1)}

# Padding
AWG_S1=${AWG_S1:-$(shuf -i 15-150 -n 1)}
AWG_S2=${AWG_S2:-$(shuf -i 15-150 -n 1)}
AWG_S3=${AWG_S3:-0}
AWG_S4=${AWG_S4:-0}

# Headers
AWG_H1=${AWG_H1:-$(shuf -i 1-2147483647 -n 1)}
AWG_H2=${AWG_H2:-$(shuf -i 1-2147483647 -n 1)}
AWG_H3=${AWG_H3:-$(shuf -i 1-2147483647 -n 1)}
AWG_H4=${AWG_H4:-$(shuf -i 1-2147483647 -n 1)}
```

### Persistence

Values are saved to `/config/server/awg_params` for consistency across container restarts:

```
AWG_JC=5
AWG_JMIN=62
AWG_JMAX=847
AWG_S1=98
AWG_S2=45
AWG_S3=0
AWG_S4=0
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
Jmax = 847
S1 = 98
S2 = 45
S3 = 0
S4 = 0
H1 = 1755269708
H2 = 2101520157
H3 = 1829552136
H4 = 2016351429
```

## Advanced Parameters (Not Implemented)

AmneziaWG also supports custom signature packets (`I1`-`I5`) for advanced obfuscation. These are client-side only and use special tag syntax:

- `<b 0x[hex]>` - Static bytes
- `<r [size]>` - Random bytes
- `<rd [size]>` - Random digits
- `<rc [size]>` - Random characters
- `<t>` - Unix timestamp
- `<c>` - Packet counter

These are not implemented in this project as they're rarely needed and add complexity.

## Troubleshooting

### Connection fails after changing parameters
All clients must be updated with matching values. Regenerate peer configs and redistribute.

### High CPU usage
Reduce `Jc` value. More junk packets = more processing overhead.

### Handshake timeout
Ensure `JMAX` isn't too large. Very large junk packets may be dropped by some networks.

## References

- [amneziawg-go README](https://github.com/amnezia-vpn/amneziawg-go)
- [AmneziaVPN Documentation](https://docs.amnezia.org/)
