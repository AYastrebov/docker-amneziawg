package main

import (
	"errors"
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

func init() {
	if v := os.Getenv("AWG_BINARY_PATH"); v != "" {
		awgBinary = v
	}
}

// getTunnelStatsFunc can be replaced in tests to avoid calling the real `awg` binary.
var getTunnelStatsFunc = getTunnelStatsReal

// GetTunnelStats returns live tunnel statistics.
// Delegates to getTunnelStatsFunc (mockable in tests).
func GetTunnelStats() ([]TunnelInfo, error) {
	return getTunnelStatsFunc()
}

// getTunnelStatsReal parses the output of `awg show all dump`.
//
// The dump format is tab-separated:
//
//	Interface line: <iface>\t<private_key>\t<public_key>\t<listen_port>\t<fwmark>
//	Peer line:      <iface>\t<public_key>\t<preshared_key>\t<endpoint>\t<allowed_ips>\t<latest_handshake>\t<transfer_rx>\t<transfer_tx>\t<persistent_keepalive>
func getTunnelStatsReal() ([]TunnelInfo, error) {
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

		ifaceName := fields[0]

		if len(fields) == 5 {
			// Interface line
			port, _ := strconv.Atoi(fields[3])
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
