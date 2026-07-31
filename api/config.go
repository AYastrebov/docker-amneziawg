package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Package-level paths — overridden in tests or via environment variables
// for sidecar deployments (see specs/api-decoupling.md).
var (
	configDir        = "/config"
	activeConfsPath  = "/run/activeconfs"
	uptimePath       = "/proc/uptime"
	buildVersionPath = "/build_version"
	s6EnvDir         = "/run/s6-overlay/container_environment"
)

func init() {
	if v := os.Getenv("CONFIG_DIR"); v != "" {
		configDir = v
	}
	if v := os.Getenv("ACTIVE_CONFS_PATH"); v != "" {
		activeConfsPath = v
	}
	if v := os.Getenv("BUILD_VERSION_PATH"); v != "" {
		buildVersionPath = v
	}
	if v := os.Getenv("S6_ENV_DIR"); v != "" {
		s6EnvDir = v
	}
}

// ServerInfo holds aggregated server information.
type ServerInfo struct {
	Mode       string            `json:"mode"`
	Tunnels    []string          `json:"tunnels"`
	Uptime     string            `json:"uptime"`
	Version    map[string]string `json:"version"`
	ServerURL  string            `json:"server_url,omitempty"`
	ServerPort string            `json:"server_port,omitempty"`
	Subnet     string            `json:"internal_subnet,omitempty"`
	PublicKey  string            `json:"public_key,omitempty"`
	AWGParams  map[string]string `json:"awg_params,omitempty"`
}

// PeerInfo holds summary information about a peer.
type PeerInfo struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	PublicKey string `json:"public_key"`
	Address   string `json:"address,omitempty"`
	HasConfig bool   `json:"has_config"`
	HasQR     bool   `json:"has_qr"`
}

// PeerDetail holds full details for a single peer.
type PeerDetail struct {
	PeerInfo
	Config string    `json:"config,omitempty"`
	Stats  *PeerStat `json:"stats,omitempty"`
}

// safeNameRe matches only characters allowed in peer directory names.
var safeNameRe = regexp.MustCompile(`[^a-zA-Z0-9_-]`)

// ResolvePeerID converts user input to the internal peer directory name.
// Numeric input "1" → "peer1", named input "laptop" → "peer_laptop".
// If input already starts with "peer" it's returned as-is (after sanitization).
func ResolvePeerID(input string) string {
	var id string
	if strings.HasPrefix(input, "peer") {
		id = input
	} else {
		// Check if all digits
		allDigits := true
		for _, c := range input {
			if c < '0' || c > '9' {
				allDigits = false
				break
			}
		}
		if allDigits && input != "" {
			id = "peer" + input
		} else {
			// Named peer — sanitize like show-peer does
			id = "peer_" + safeNameRe.ReplaceAllString(input, "")
		}
	}
	// Always sanitize the final ID to prevent path traversal.
	// Only allow alphanumeric, underscore, and hyphen.
	return safeNameRe.ReplaceAllString(id, "")
}

// GetServerInfo reads server configuration and status.
func GetServerInfo() (*ServerInfo, error) {
	info := &ServerInfo{
		Version: map[string]string{},
	}

	// Determine mode: server mode has PEERS set (peer dirs exist)
	peers, _ := filepath.Glob(filepath.Join(configDir, "peer*"))
	if len(peers) > 0 {
		info.Mode = "server"
	} else {
		info.Mode = "client"
	}

	// Active tunnels from activeconfs
	if data, err := os.ReadFile(activeConfsPath); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			// activeconfs uses declare -p format; extract conf names
			if strings.Contains(line, ".conf") {
				// Extract just the tunnel name from path like /config/wg_confs/wg0.conf
				parts := strings.Split(line, "/")
				for _, p := range parts {
					// Clean up surrounding quotes/brackets before checking suffix
					cleaned := strings.Trim(p, `"'()]`)
					if strings.HasSuffix(cleaned, ".conf") {
						name := strings.TrimSuffix(cleaned, ".conf")
						if name != "" {
							info.Tunnels = append(info.Tunnels, name)
						}
					}
				}
			}
		}
	}
	if info.Tunnels == nil {
		info.Tunnels = []string{}
	}

	// Uptime
	if data, err := os.ReadFile(uptimePath); err == nil {
		fields := strings.Fields(string(data))
		if len(fields) > 0 {
			info.Uptime = fields[0] + "s"
		}
	}

	// Version from build_version
	if data, err := os.ReadFile(buildVersionPath); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if k, v, ok := strings.Cut(line, ": "); ok {
				v = strings.TrimSpace(v)
				switch k {
				case "amneziawg-tools":
					info.Version["amneziawg_tools"] = v
				case "amneziawg-go":
					info.Version["amneziawg_go"] = v
				}
			}
		}
	}

	// Server URL/port/subnet from s6 container environment
	info.ServerURL = readEnvFile("SERVERURL")
	info.ServerPort = readEnvFile("SERVERPORT")
	info.Subnet = readEnvFile("INTERNAL_SUBNET")

	// Public key
	if data, err := os.ReadFile(filepath.Join(configDir, "server", "publickey-server")); err == nil {
		info.PublicKey = strings.TrimSpace(string(data))
	}

	// AWG params
	info.AWGParams = readAWGParams()

	return info, nil
}

// ListPeers enumerates peer directories and returns summary info.
func ListPeers() ([]PeerInfo, error) {
	entries, err := os.ReadDir(configDir)
	if err != nil {
		return nil, fmt.Errorf("reading config dir: %w", err)
	}

	peers := make([]PeerInfo, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), "peer") {
			continue
		}

		peerID := e.Name()
		p := PeerInfo{
			ID:   peerID,
			Name: peerDisplayName(peerID),
		}

		// Public key
		if data, err := os.ReadFile(filepath.Join(configDir, peerID, "publickey-"+peerID)); err == nil {
			p.PublicKey = strings.TrimSpace(string(data))
		}

		// Address from config
		confPath := filepath.Join(configDir, peerID, peerID+".conf")
		if _, err := os.Stat(confPath); err == nil {
			p.HasConfig = true
			p.Address = extractAddressFromConf(confPath)
		}

		// QR code
		pngPath := filepath.Join(configDir, peerID, peerID+".png")
		if _, err := os.Stat(pngPath); err == nil {
			p.HasQR = true
		}

		peers = append(peers, p)
	}
	return peers, nil
}

// GetPeerDetail returns full details for a single peer.
func GetPeerDetail(peerID string) (*PeerDetail, error) {
	peerDir := filepath.Join(configDir, peerID)
	if _, err := os.Stat(peerDir); err != nil {
		return nil, err
	}

	detail := &PeerDetail{
		PeerInfo: PeerInfo{
			ID:   peerID,
			Name: peerDisplayName(peerID),
		},
	}

	// Public key
	if data, err := os.ReadFile(filepath.Join(peerDir, "publickey-"+peerID)); err == nil {
		detail.PublicKey = strings.TrimSpace(string(data))
	}

	// Config text
	confPath := filepath.Join(peerDir, peerID+".conf")
	if data, err := os.ReadFile(confPath); err == nil {
		detail.HasConfig = true
		detail.Config = string(data)
		detail.Address = extractAddressFromConf(confPath)
	}

	// QR availability
	pngPath := filepath.Join(peerDir, peerID+".png")
	if _, err := os.Stat(pngPath); err == nil {
		detail.HasQR = true
	}

	// Live stats — match by public key
	if detail.PublicKey != "" {
		if tunnels, err := GetTunnelStats(); err == nil {
			for _, t := range tunnels {
				for _, p := range t.Peers {
					if p.PublicKey == detail.PublicKey {
						stat := p
						detail.Stats = &stat
						break
					}
				}
			}
		}
	}

	return detail, nil
}

// --- helpers ---

func peerDisplayName(peerID string) string {
	if strings.HasPrefix(peerID, "peer_") {
		return strings.TrimPrefix(peerID, "peer_")
	}
	return strings.TrimPrefix(peerID, "peer")
}

func extractAddressFromConf(confPath string) string {
	f, err := os.Open(confPath)
	if err != nil {
		return ""
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if k, v, ok := strings.Cut(line, "="); ok {
			if strings.TrimSpace(k) == "Address" {
				return strings.TrimSpace(v)
			}
		}
	}
	return ""
}

func readEnvFile(name string) string {
	// s6-overlay stores container environment in individual files
	data, err := os.ReadFile(filepath.Join(s6EnvDir, name))
	if err != nil {
		// Fallback to OS env
		return os.Getenv(name)
	}
	return strings.TrimSpace(string(data))
}

// awgParamAllowlist enumerates the AWG parameters that are safe to expose over
// the API. readAWGParams drops anything absent from this set, so a secret
// written into awg_params — AWG_HEADER_PROTECTION_KEY today, whatever upstream
// adds tomorrow — is excluded by default rather than leaking until someone
// notices. Adding a genuinely new non-secret parameter here is a one-liner.
var awgParamAllowlist = map[string]struct{}{
	"version": {},
	"jc":      {}, "jmin": {}, "jmax": {},
	"s1": {}, "s2": {}, "s3": {}, "s4": {},
	"h1": {}, "h2": {}, "h3": {}, "h4": {},
	"i1": {}, "i2": {}, "i3": {}, "i4": {}, "i5": {},
	// AWG 3.0 — timers and padding are not secret; the header protection key is.
	"content_padding":        {},
	"rekey_after_time":       {},
	"rekey_timeout":          {},
	"reject_after_time":      {},
	"keepalive_timeout":      {},
	"max_handshake_attempts": {},
}

func readAWGParams() map[string]string {
	params := map[string]string{}
	f, err := os.Open(filepath.Join(configDir, "server", "awg_params"))
	if err != nil {
		return params
	}
	defer func() { _ = f.Close() }()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Use cut with -f2- equivalent: split on first = only
		if k, v, ok := strings.Cut(line, "="); ok {
			key := strings.TrimPrefix(strings.TrimSpace(k), "AWG_")
			key = strings.ToLower(key)
			if _, allowed := awgParamAllowlist[key]; !allowed {
				continue
			}
			params[key] = strings.TrimSpace(v)
		}
	}
	return params
}

// StatsSnapshot is the typed envelope for WebSocket broadcast messages.
type StatsSnapshot struct {
	Data      []TunnelInfo `json:"data"`
	Timestamp string       `json:"timestamp"`
	Error     string       `json:"error,omitempty"`
}

// GetTunnelStatsSnapshot returns tunnel stats for WebSocket broadcast.
func GetTunnelStatsSnapshot() StatsSnapshot {
	tunnels, err := GetTunnelStats()
	if err != nil {
		return StatsSnapshot{
			Data:      []TunnelInfo{},
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Error:     err.Error(),
		}
	}
	return StatsSnapshot{
		Data:      tunnels,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	}
}
