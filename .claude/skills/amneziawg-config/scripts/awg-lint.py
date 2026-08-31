#!/usr/bin/env python3
"""awg-lint.py — check AmneziaWG configs for constraint and performance bugs.

Usage:
    awg-lint.py wg0.conf [peer1.conf ...]

One file is checked on its own. Given several, the shared obfuscation values are
also cross-checked, since a server and its peers must agree on S/H/I,
HeaderProtectionKey and RandomTrailers or the tunnel will not come up.

Exit status is 1 if any ERROR was reported, 0 otherwise (warnings do not fail).
"""
import re
import sys
from collections import OrderedDict

# Values that every endpoint must carry identically. Jc/Jmin/Jmax and the 3.x
# timer ranges are deliberately absent: each side draws its own.
SHARED = ["S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
          "I1", "I2", "I3", "I4", "I5", "HeaderProtectionKey", "RandomTrailers"]

INT_KEYS = ["Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "MTU"]


class Conf:
    def __init__(self, path):
        self.path = path
        self.iface = OrderedDict()   # [Interface] keys
        self.peer_keys = []          # keys seen in any [Peer] section
        self.n_peers = 0
        section = None
        with open(path, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                if line.startswith("["):
                    section = line.strip("[]").strip().lower()
                    if section == "peer":
                        self.n_peers += 1
                    continue
                if "=" not in line:
                    continue
                # I1-I5 values contain '=' inside their tag syntax, so split once.
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if section == "interface":
                    self.iface[k] = v
                elif section == "peer":
                    self.peer_keys.append(k)

    def get(self, key, default=None):
        return self.iface.get(key, default)

    def int_of(self, key):
        v = self.get(key)
        if v is None:
            return None
        try:
            return int(v)
        except ValueError:
            return None


def parse_range(v):
    """'100-140' -> (100,140); '7' -> (7,7); None if unparseable."""
    if v is None:
        return None
    m = re.fullmatch(r"\s*(\d+)\s*-\s*(\d+)\s*", v)
    if m:
        return int(m.group(1)), int(m.group(2))
    if re.fullmatch(r"\s*\d+\s*", v):
        n = int(v)
        return n, n
    return None


class Report:
    def __init__(self):
        self.errors, self.warnings, self.infos = [], [], []

    def error(self, msg):
        self.errors.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)

    def info(self, msg):
        self.infos.append(msg)


def detect_version(c):
    if c.get("HeaderProtectionKey"):
        return "3.1" if c.get("RandomTrailers", "off").lower() == "on" else "3.0"
    h1 = parse_range(c.get("H1"))
    wide = h1 is not None and h1[1] > h1[0]
    if wide or c.get("I1"):
        return "2.0"
    if (c.int_of("S3"), c.int_of("S4")) == (0, 0):
        return "1.5"
    return "2.0"


def check(c, rep):
    ver = detect_version(c)
    rep.info(f"detected AWG {ver}")

    s = {k: c.int_of(k) for k in ("S1", "S2", "S3", "S4")}
    jc, jmin, jmax = c.int_of("Jc"), c.int_of("Jmin"), c.int_of("Jmax")
    hpk = c.get("HeaderProtectionKey")
    rt = c.get("RandomTrailers", "off").lower() == "on"
    cpa_raw = c.get("ContentPaddingAddition")
    cpa = parse_range(cpa_raw)
    cpa_on = cpa is not None and cpa != (0, 0)

    # ---- hard protocol limits
    for key, limit in (("S1", 1132), ("S2", 1188), ("S3", 64), ("S4", 32)):
        if s[key] is not None and s[key] > limit:
            rep.error(f"{key} = {s[key]} exceeds the maximum of {limit}")
    if jmin is not None and jmax is not None and jmin >= jmax:
        rep.error(f"Jmin ({jmin}) must be less than Jmax ({jmax})")
    if jmax is not None and jmax > 1280:
        rep.error(f"Jmax = {jmax} exceeds 1280")
    if jc is not None and not 0 <= jc <= 128:
        rep.error(f"Jc = {jc} is outside 0-128")

    # ---- H values
    hs = {k: parse_range(c.get(k)) for k in ("H1", "H2", "H3", "H4")}
    present = {k: v for k, v in hs.items() if v is not None}
    compat = all(v == (i + 1, i + 1) for i, (k, v) in enumerate(sorted(present.items())))
    if present and not compat:
        for k, v in present.items():
            if v[0] < 5:
                rep.error(f"{k} = {c.get(k)} — values 1-4 are reserved for standard "
                          f"WireGuard message types; use >= 5 or set all four to 1,2,3,4")
        items = sorted(present.items(), key=lambda kv: kv[1][0])
        for (k1, r1), (k2, r2) in zip(items, items[1:]):
            if r1[1] >= r2[0]:
                rep.error(f"{k1} ({c.get(k1)}) and {k2} ({c.get(k2)}) overlap — "
                          f"H ranges must be disjoint or packet types become ambiguous")
        widths = [v[1] - v[0] for v in present.values()]
        if ver in ("2.0", "3.0", "3.1") and max(widths) == 0:
            rep.warn("H1-H4 are single integers. The Amnezia app uses the range "
                     "format to recognise AWG 2.0+ and will report this as 1.5, "
                     "which also disables I1-I5 processing")

    # ---- header protection floor (enforced by the kernel module, netlink.c)
    if hpk:
        if len(hpk) != 44:
            rep.error(f"HeaderProtectionKey is {len(hpk)} chars; expected 44 "
                      f"(32 bytes base64)")
        for k in ("S1", "S2", "S3", "S4"):
            if s[k] is not None and s[k] < 12:
                rep.error(f"{k} = {s[k]} but HeaderProtectionKey is set — the nonce is "
                          f"read from the first 12 bytes of the S-prefix, so all of "
                          f"S1-S4 must be >= 12. The kernel module rejects this config")

    # ---- the big one: RandomTrailers needs equal S values
    if rt:
        wide_h = any(v[1] > v[0] for v in present.values()) if present else False
        vals = [s[k] for k in ("S1", "S2", "S3", "S4")]
        if None not in vals and len(set(vals)) > 1:
            if wide_h:
                total = sum(v[1] - v[0] + 1 for v in present.values()
                            if v is not None) - (
                            (present.get("H4", (0, 0))[1] - present.get("H4", (0, 0))[0] + 1)
                            if "H4" in present else 0)
                pct = 100.0 * total / 2**32
                rep.error(
                    f"RandomTrailers is on but S1-S4 differ ({vals}). Trailers relax "
                    f"the receiver's packet-type check from an exact length match to "
                    f">=, leaving the H ranges as the only discriminator — and each "
                    f"type is read at its own S offset, so three of the four checks "
                    f"read garbage. About {pct:.1f}% of transport packets will be "
                    f"dropped as malformed handshakes (upload collapses; download is "
                    f"barely affected). Fix: set S1 = S2 = S3 = S4")
            else:
                rep.info("RandomTrailers with unequal S values, but H1-H4 are narrow "
                         "enough that wrong-offset reads effectively never match")

    # ---- padding interaction
    if cpa_on and rt:
        rep.error(
            "ContentPaddingAddition and RandomTrailers are both set. Content padding "
            "wins on the send path and suppresses the trailers, but the receiver "
            "still runs the loose length match — you get the risk of trailers and "
            "none of the obfuscation. Set ContentPaddingAddition = 0, or drop "
            "RandomTrailers")
    elif cpa_on:
        rep.warn(
            f"ContentPaddingAddition = {cpa_raw} costs roughly 22% of download "
            f"throughput: a different length on every datagram defeats UDP_GRO "
            f"batching on userspace clients. Set it to 0 unless you specifically "
            f"need per-packet size randomisation")

    # ---- S1+56 == S2
    if s["S1"] is not None and s["S2"] is not None:
        if s["S1"] + 56 == s["S2"]:
            rep.warn(f"S1 + 56 == S2 ({s['S1']}+56={s['S2']}) — the padded init and "
                     f"response packets end up the same length, which is its own "
                     f"fingerprint")

    # ---- MTU vs S4
    mtu = c.int_of("MTU")
    s4 = s["S4"] or 0
    overhead4, overhead6 = 60 + s4, 80 + s4
    if mtu is None:
        derived = 1420 + overhead4
        if derived > 1500:
            rep.warn(f"No MTU set. wg-quick/awg-quick derives 1420 on a 1500-byte link "
                     f"and ignores S4, so a full-size packet becomes {derived} bytes over "
                     f"IPv4 and fragments even on a clean path. Set MTU explicitly "
                     f"(1280 is safe everywhere)")
        else:
            rep.warn(f"No MTU set. wg-quick/awg-quick derives 1420; with S4={s4} that is "
                     f"{derived} bytes over IPv4, which fits a 1500-byte path — but any "
                     f"client on a smaller one (PPPoE 1492, LTE ~1400, DS-Lite 1280) will "
                     f"fragment. Set MTU explicitly (1280 is safe everywhere)")
    else:
        if mtu + overhead4 > 1500:
            rep.error(f"MTU {mtu} with S4={s4} makes a full-size packet "
                      f"{mtu + overhead4} bytes over IPv4, past the 1500 limit — every "
                      f"one fragments. Maximum here is {1500 - overhead4}")
        elif mtu + overhead6 > 1500:
            rep.warn(f"MTU {mtu} with S4={s4} is {mtu + overhead6} bytes over an IPv6 "
                     f"endpoint, past 1500. Fine on IPv4; use "
                     f"{1500 - overhead6} if the endpoint is IPv6")
        if mtu > 1280:
            rep.info(f"MTU {mtu} is above 1280. That is fine on a clean path, but "
                     f"1280 is the value that survives PPPoE, LTE and IPv6 "
                     f"transitions without fragmenting")
    if s4 > 20:
        rep.warn(f"S4 = {s4} is large. Overhead is 60+S4 per packet, so anything "
                 f"above 20 breaks the default 1420 MTU on a 1500-byte path")

    # ---- 3.x timers
    ra, rj = parse_range(c.get("RekeyAfterTime")), parse_range(c.get("RejectAfterTime"))
    kt, rt_o = parse_range(c.get("KeepaliveTimeout")), parse_range(c.get("RekeyTimeout"))
    if ra and rj and rj[0] <= ra[1]:
        rep.error(f"RejectAfterTime.lo ({rj[0]}) must exceed RekeyAfterTime.hi "
                  f"({ra[1]}), or a keypair expires before it is renewed")
    if rj and kt and rt_o and rj[0] <= kt[0] + rt_o[0]:
        rep.error(f"RejectAfterTime.lo ({rj[0]}) must exceed KeepaliveTimeout.lo + "
                  f"RekeyTimeout.lo ({kt[0]}+{rt_o[0]})")

    # ---- placement
    misplaced = [k for k in c.peer_keys
                 if re.fullmatch(r"I[1-5]", k) or k in
                 ("S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
                  "HeaderProtectionKey", "RandomTrailers", "DisableCookies")]
    if misplaced:
        rep.error(f"obfuscation keys found in a [Peer] section: "
                  f"{', '.join(sorted(set(misplaced)))}. They belong in [Interface] — "
                  f"the Amnezia app only inspects [Interface] to decide the protocol "
                  f"version, and I1-I5 are ignored entirely from [Peer]")

    # An empty value is not the same as an absent key: `awg setconf` rejects
    # "I2 =" outright with "Line unrecognized", so a conf carrying empty
    # placeholders cannot be loaded by awg-quick at all — even though the same
    # file may work in a GUI client with a more forgiving parser.
    empty_i = [f"I{n}" for n in range(1, 6)
               if c.get(f"I{n}") is not None and not c.get(f"I{n}").strip()]
    if empty_i:
        rep.error(f"{', '.join(empty_i)} present but empty. `awg setconf` rejects an "
                  f"empty value ('Line unrecognized'), so awg-quick cannot load this "
                  f"config — delete the line instead of leaving it blank")

    for n in range(2, 6):
        v = c.get(f"I{n}")
        if v and v.strip() and not (c.get("I1") or "").strip():
            rep.error(f"I{n} is set without I1; signature packets are sent in order "
                      f"and I1 must be present")


def cross_check(confs, rep):
    for key in SHARED:
        seen, missing = {}, []
        for c in confs:
            v = c.get(key)
            # An empty value carries no signature, so it means the same thing as
            # an absent key for comparison purposes. It is still invalid syntax,
            # which the per-file check reports separately — no need to also call
            # it a mismatch here.
            if v is None or not v.strip():
                missing.append(c.path)
            else:
                seen.setdefault(v, []).append(c.path)
        if not seen:
            continue        # nobody sets it — consistent by omission
        # A key present in one config and absent from another is just as fatal as
        # two different values, and it is the more common way a peer conf goes
        # bad (hand-edited, or copied from a config generated at another time).
        # RandomTrailers is exempt: absence there means "off", a real value, and
        # the dedicated check below compares it with that default applied.
        if missing and key != "RandomTrailers":
            present = sorted({p for ps in seen.values() for p in ps})
            rep.error(f"{key} is set in {', '.join(present)} but missing from "
                      f"{', '.join(missing)} — every endpoint must carry the same "
                      f"obfuscation values, so this tunnel will not come up")
        if len(seen) > 1:
            detail = "; ".join(f"{v!r} in {', '.join(p)}" for v, p in seen.items())
            rep.error(f"{key} differs between configs — every endpoint must match: "
                      f"{detail}")
    # RandomTrailers absent on one side is as fatal as a mismatch: the receiver
    # without it expects exact handshake lengths and drops the padded ones.
    rts = {c.path: c.get("RandomTrailers", "off").lower() for c in confs}
    if len(set(rts.values())) > 1:
        rep.error(f"RandomTrailers is not consistent across configs ({rts}). A peer "
                  f"without it drops the padded handshakes from a peer with it, so "
                  f"the tunnel never comes up")


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip())
        return 2
    paths = argv[1:]
    failed = False
    confs = []
    for p in paths:
        rep = Report()
        try:
            c = Conf(p)
        except OSError as e:
            print(f"\n=== {p} ===\n  ERROR  cannot read: {e}")
            failed = True
            continue
        confs.append(c)
        check(c, rep)
        print(f"\n=== {p} ===")
        for m in rep.errors:
            print(f"  ERROR  {m}")
        for m in rep.warnings:
            print(f"  WARN   {m}")
        for m in rep.infos:
            print(f"  info   {m}")
        if not (rep.errors or rep.warnings):
            print("  OK     no problems found")
        failed = failed or bool(rep.errors)

    if len(confs) > 1:
        rep = Report()
        cross_check(confs, rep)
        print(f"\n=== cross-check ({len(confs)} configs) ===")
        for m in rep.errors:
            print(f"  ERROR  {m}")
        if not rep.errors:
            print("  OK     shared obfuscation values agree")
        failed = failed or bool(rep.errors)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
