package main

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/curve25519"
)

// uapiDialTimeout bounds a single socket read so a wedged amneziawg-go can't
// stall the stats poller.
const uapiDialTimeout = 3 * time.Second

// UAPIClient reads tunnel statistics from amneziawg-go's userspace UAPI. Each
// userspace interface exposes a <iface>.sock under dir, speaking the
// line-oriented WireGuard cross-platform UAPI: the client writes "get=1\n\n"
// and the engine streams "key=value\n" lines terminated by "errno=<n>\n\n".
//
// Only the read (get=) path is implemented; the type is deliberately shaped so
// a set= writer (live peer add/remove/reconfigure) can be added later without
// touching call sites.
type UAPIClient struct {
	dir string
}

func (c UAPIClient) sockPath(iface string) string {
	return filepath.Join(c.dir, iface+".sock")
}

// interfaces lists the userspace interfaces that currently expose a UAPI
// socket. An empty result means userspace mode is not in use (kernel-mode
// datapath, or no tunnels up) — callers fall back to the awg CLI. A missing
// directory is not an error, just "no sockets".
func (c UAPIClient) interfaces() ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(c.dir, "*.sock"))
	if err != nil {
		return nil, err
	}
	ifaces := make([]string, 0, len(matches))
	for _, m := range matches {
		ifaces = append(ifaces, strings.TrimSuffix(filepath.Base(m), ".sock"))
	}
	return ifaces, nil
}

// get dials one interface's UAPI socket and returns its stats.
func (c UAPIClient) get(iface string) (*TunnelInfo, error) {
	conn, err := net.DialTimeout("unix", c.sockPath(iface), uapiDialTimeout)
	if err != nil {
		return nil, fmt.Errorf("dial uapi socket: %w", err)
	}
	defer func() { _ = conn.Close() }()

	_ = conn.SetDeadline(time.Now().Add(uapiDialTimeout))
	if _, err := io.WriteString(conn, "get=1\n\n"); err != nil {
		return nil, fmt.Errorf("write get request: %w", err)
	}
	return ParseUAPIGet(iface, conn)
}

// ParseUAPIGet parses a UAPI get= response into a TunnelInfo. It is socket-free
// (takes an io.Reader) so it can be unit-tested against captured transcripts.
//
// Keys arrive as hex; the rest of the API surface (and GetPeerDetail's
// public-key matching against on-disk keyfiles) uses base64, matching
// `awg show all dump`, so public keys are converted here.
//
// Secrets on the wire — private_key, preshared_key, header_protection_key — are
// never surfaced. private_key is used transiently to derive the interface's
// public key (amneziawg-go does not emit it) and then dropped.
func ParseUAPIGet(iface string, r io.Reader) (*TunnelInfo, error) {
	t := &TunnelInfo{Name: iface}
	var cur *PeerStat // nil until the first public_key= line

	scanner := bufio.NewScanner(r)
	// Peer lines can carry many allowed_ip entries; keep a generous line cap.
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			break // blank line terminates the response
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}

		if key == "errno" {
			if val != "0" {
				return nil, fmt.Errorf("uapi errno=%s", val)
			}
			break
		}

		// The first public_key switches from device scope to peer scope, and
		// each subsequent one starts a new peer.
		if key == "public_key" {
			pk, err := hexKeyToBase64(val)
			if err != nil {
				return nil, fmt.Errorf("peer public_key: %w", err)
			}
			t.Peers = append(t.Peers, PeerStat{PublicKey: pk})
			cur = &t.Peers[len(t.Peers)-1]
			continue
		}

		if cur == nil {
			parseUAPIDeviceLine(t, key, val)
		} else {
			parseUAPIPeerLine(cur, key, val)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return t, nil
}

func parseUAPIDeviceLine(t *TunnelInfo, key, val string) {
	switch key {
	case "listen_port":
		if p, err := strconv.Atoi(val); err == nil {
			t.Interface.ListenPort = p
		}
	case "private_key":
		// Derive the interface public key; never store the private key.
		if pub, err := derivePublicKey(val); err == nil {
			t.Interface.PublicKey = pub
		}
	}
	// Everything else (fwmark, jc/jmin/jmax, s1-s4, h1-h4, i1-i5,
	// header_protection_key, timers) is not part of live stats and is ignored.
}

func parseUAPIPeerLine(p *PeerStat, key, val string) {
	switch key {
	case "endpoint":
		p.Endpoint = val
	case "allowed_ip":
		if p.AllowedIPs == "" {
			p.AllowedIPs = val
		} else {
			p.AllowedIPs += "," + val
		}
	case "last_handshake_time_sec":
		if ts, err := strconv.ParseInt(val, 10, 64); err == nil && ts > 0 {
			p.LatestHandshake = time.Unix(ts, 0).UTC().Format(time.RFC3339)
		}
	case "tx_bytes":
		p.TransferTx, _ = strconv.ParseInt(val, 10, 64)
	case "rx_bytes":
		p.TransferRx, _ = strconv.ParseInt(val, 10, 64)
	}
	// preshared_key, header_protection_key, private_key: secrets, never read.
	// protocol_version, persistent_keepalive_interval, last_handshake_time_nsec:
	// not part of the exposed PeerStat shape.
}

// hexKeyToBase64 converts a 32-byte hex key (UAPI wire form) to base64 (the
// form `awg show` prints and the rest of the API uses).
func hexKeyToBase64(h string) (string, error) {
	raw, err := hex.DecodeString(h)
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("key is %d bytes, want 32", len(raw))
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}

// derivePublicKey computes the Curve25519 public key for a hex private key and
// returns it base64-encoded. The interface public key is not emitted by the
// UAPI, only the private key, so it must be derived.
func derivePublicKey(hexPriv string) (string, error) {
	priv, err := hex.DecodeString(hexPriv)
	if err != nil {
		return "", err
	}
	if len(priv) != 32 {
		return "", fmt.Errorf("private key is %d bytes, want 32", len(priv))
	}
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(pub), nil
}
