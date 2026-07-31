package main

import (
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// TunnelInfo represents a WireGuard/AmneziaWG tunnel interface with its peers.
type TunnelInfo struct {
	Name      string     `json:"name"`
	Interface IfaceInfo  `json:"interface"`
	Peers     []PeerStat `json:"peers"`
}

// IfaceInfo holds interface-level stats from `awg show`.
type IfaceInfo struct {
	PublicKey  string `json:"public_key"`
	ListenPort int    `json:"listen_port"`
}

// PeerStat holds per-peer live statistics from `awg show`.
type PeerStat struct {
	PublicKey       string `json:"public_key"`
	Endpoint        string `json:"endpoint,omitempty"`
	AllowedIPs      string `json:"allowed_ips,omitempty"`
	LatestHandshake string `json:"latest_handshake,omitempty"`
	TransferRx      int64  `json:"transfer_rx"`
	TransferTx      int64  `json:"transfer_tx"`
}

// awgBinary is the path to the awg command. Defaults to a fixed path to
// prevent PATH manipulation; overridable via AWG_BINARY_PATH for sidecar
// deployments where awg lives at a different location.
var awgBinary = "/usr/bin/awg"

// awgSocketDir holds the amneziawg-go UAPI sockets (one <iface>.sock per
// userspace interface). Overridable via AWG_SOCKET_DIR. This is the primary
// stats source; the awg CLI is only used as a fallback for kernel-mode
// interfaces, which have no socket (see getTunnelStatsReal).
var awgSocketDir = "/run/amneziawg"

func init() {
	if v := os.Getenv("AWG_BINARY_PATH"); v != "" {
		awgBinary = v
	}
	if v := os.Getenv("AWG_SOCKET_DIR"); v != "" {
		awgSocketDir = v
	}
}

// getTunnelStatsFunc can be replaced in tests to avoid calling the real `awg` binary.
var getTunnelStatsFunc = getTunnelStatsReal

// GetTunnelStats returns live tunnel statistics.
// Delegates to getTunnelStatsFunc (mockable in tests).
func GetTunnelStats() ([]TunnelInfo, error) {
	return getTunnelStatsFunc()
}

// getTunnelStatsReal returns live tunnel stats, preferring the amneziawg-go
// UAPI socket and falling back to the awg CLI.
//
// Userspace mode (the default): amneziawg-go exposes a <iface>.sock per
// interface under awgSocketDir. Reading the UAPI get= stream avoids forking
// awg and parses a self-describing key=value protocol instead of the
// positional `awg show all dump` columns. If any socket is present we use the
// UAPI exclusively.
//
// Kernel mode (host has a 3.0-capable amneziawg module): there is no socket —
// the datapath is generic netlink — so awgSocketDir is empty and we fall back
// to `awg show all dump`, which speaks netlink. A container uses a single
// datapath (init-amneziawg-module picks one), so socket-present ⇒ userspace
// for every interface. Zero sockets also covers the tunnels-down case, where
// the CLI already returns an empty list.
func getTunnelStatsReal() ([]TunnelInfo, error) {
	ifaces, err := (UAPIClient{dir: awgSocketDir}).interfaces()
	if err == nil && len(ifaces) > 0 {
		return getTunnelStatsViaUAPI(ifaces)
	}
	return getTunnelStatsViaCLI()
}

// getTunnelStatsViaUAPI reads each interface's stats over its UAPI socket. A
// single failing socket is logged and skipped rather than failing the whole
// response, mirroring the CLI path's tolerance for tunnels being down.
func getTunnelStatsViaUAPI(ifaces []string) ([]TunnelInfo, error) {
	client := UAPIClient{dir: awgSocketDir}
	tunnels := make([]TunnelInfo, 0, len(ifaces))
	for _, iface := range ifaces {
		t, err := client.get(iface)
		if err != nil {
			slog.Warn("uapi: reading interface stats failed, skipping", "iface", iface, "err", err)
			continue
		}
		tunnels = append(tunnels, *t)
	}
	return tunnels, nil
}

// getTunnelStatsViaCLI parses the output of `awg show all dump`.
//
// The dump format is tab-separated. `awg show all dump` prints one device line
// per interface, immediately followed by that interface's peer lines:
//
//	Device line: <iface>\t<private_key>\t<public_key>\t<listen_port>\t<fwmark>
//	Peer line:   <iface>\t<public_key>\t<preshared_key>\t<endpoint>\t<allowed_ips>\t<latest_handshake>\t<transfer_rx>\t<transfer_tx>\t<persistent_keepalive>
//
// The device line above is plain WireGuard's. AmneziaWG appends its own
// parameters (Jc/Jmin/Jmax, S1-S4, H1-H4, I1-I5, and in 3.0 the header
// protection key plus six timers), producing 28 fields in practice — for
// every protocol version, since unset values are emitted as `(null)`, `(none)`
// or `0` rather than omitted. Line type is therefore determined by position,
// never by field count.
func getTunnelStatsViaCLI() ([]TunnelInfo, error) {
	out, err := exec.Command(awgBinary, "show", "all", "dump").Output()
	if err != nil {
		// Tunnels may be down — return empty list instead of error
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() != 0 {
			return []TunnelInfo{}, nil
		}
		return nil, err
	}

	return ParseAWGDump(string(out))
}

// ParseAWGDump parses the tab-separated output of `awg show all dump`.
func ParseAWGDump(output string) ([]TunnelInfo, error) {
	tunnels := map[string]*TunnelInfo{}
	var order []string

	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < 4 {
			continue
		}

		ifaceName := fields[0]

		// A device line is the first line seen for an interface and has an
		// integer listen port in field 3; a peer line has an endpoint there
		// ("(none)" or "host:port"). Do not switch on len(fields):
		// AmneziaWG's device line carries its obfuscation parameters and is
		// far longer than WireGuard's five fields, and its width varies with
		// the protocol version. Only the public key (field 2) and listen port
		// are surfaced — the private key in field 1 and the AWG 3.0 header
		// protection key are deliberately never read.
		port, portErr := strconv.Atoi(fields[3])
		_, seen := tunnels[ifaceName]

		if !seen && portErr == nil {
			t := &TunnelInfo{
				Name: ifaceName,
				Interface: IfaceInfo{
					PublicKey:  fields[2],
					ListenPort: port,
				},
			}
			tunnels[ifaceName] = t
			order = append(order, ifaceName)
		} else if len(fields) >= 8 {
			// Peer line
			t, ok := tunnels[ifaceName]
			if !ok {
				continue
			}
			rx, _ := strconv.ParseInt(fields[6], 10, 64)
			tx, _ := strconv.ParseInt(fields[7], 10, 64)

			handshake := ""
			if ts, err := strconv.ParseInt(fields[5], 10, 64); err == nil && ts > 0 {
				handshake = time.Unix(ts, 0).UTC().Format(time.RFC3339)
			}

			endpoint := fields[3]
			if endpoint == "(none)" {
				endpoint = ""
			}

			t.Peers = append(t.Peers, PeerStat{
				PublicKey:       fields[1],
				Endpoint:        endpoint,
				AllowedIPs:      fields[4],
				LatestHandshake: handshake,
				TransferRx:      rx,
				TransferTx:      tx,
			})
		}
	}

	result := make([]TunnelInfo, 0, len(order))
	for _, name := range order {
		result = append(result, *tunnels[name])
	}
	return result, nil
}
