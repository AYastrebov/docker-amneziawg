package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolvePeerID_Numeric(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"1", "peer1"},
		{"42", "peer42"},
		{"0", "peer0"},
	}
	for _, tc := range tests {
		if got := ResolvePeerID(tc.input); got != tc.expected {
			t.Errorf("ResolvePeerID(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestResolvePeerID_Named(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"laptop", "peer_laptop"},
		{"my-phone", "peer_my-phone"},
		{"tablet_2", "peer_tablet_2"},
	}
	for _, tc := range tests {
		if got := ResolvePeerID(tc.input); got != tc.expected {
			t.Errorf("ResolvePeerID(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestResolvePeerID_AlreadyResolved(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"peer1", "peer1"},
		{"peer_laptop", "peer_laptop"},
		{"peer99", "peer99"},
	}
	for _, tc := range tests {
		if got := ResolvePeerID(tc.input); got != tc.expected {
			t.Errorf("ResolvePeerID(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestResolvePeerID_PathTraversal(t *testing.T) {
	tests := []struct {
		input string
		safe  bool // result must not contain ".." or "/"
	}{
		{"peer../../etc", true},
		{"peer../server", true},
		{"peer_../server", true},
		{"../../../etc/passwd", true},
	}
	for _, tc := range tests {
		t.Run(tc.input, func(t *testing.T) {
			got := ResolvePeerID(tc.input)
			if strings.Contains(got, "..") {
				t.Errorf("ResolvePeerID(%q) = %q contains '..'", tc.input, got)
			}
			if strings.Contains(got, "/") {
				t.Errorf("ResolvePeerID(%q) = %q contains '/'", tc.input, got)
			}
		})
	}
}

func TestResolvePeerID_Sanitization(t *testing.T) {
	// Special chars should be stripped
	got := ResolvePeerID("my phone!")
	if got != "peer_myphone" {
		t.Errorf("ResolvePeerID with special chars = %q, want peer_myphone", got)
	}
}

func TestResolvePeerID_Empty(t *testing.T) {
	got := ResolvePeerID("")
	if got != "peer_" {
		t.Errorf("ResolvePeerID(\"\") = %q, want peer_", got)
	}
}

func TestPeerDisplayName(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"peer1", "1"},
		{"peer42", "42"},
		{"peer_laptop", "laptop"},
		{"peer_my-phone", "my-phone"},
	}
	for _, tc := range tests {
		if got := peerDisplayName(tc.input); got != tc.expected {
			t.Errorf("peerDisplayName(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestExtractAddressFromConf(t *testing.T) {
	tmpDir := t.TempDir()
	confPath := filepath.Join(tmpDir, "test.conf")

	os.WriteFile(confPath, []byte(
		"[Interface]\n"+
			"Address = 10.13.13.2\n"+
			"PrivateKey = SOME_KEY\n",
	), 0644)

	addr := extractAddressFromConf(confPath)
	if addr != "10.13.13.2" {
		t.Errorf("expected 10.13.13.2, got %q", addr)
	}
}

func TestExtractAddressFromConf_NotFound(t *testing.T) {
	tmpDir := t.TempDir()
	confPath := filepath.Join(tmpDir, "test.conf")

	os.WriteFile(confPath, []byte("[Peer]\nPublicKey = ABC\n"), 0644)

	addr := extractAddressFromConf(confPath)
	if addr != "" {
		t.Errorf("expected empty string, got %q", addr)
	}
}

func TestExtractAddressFromConf_MissingFile(t *testing.T) {
	addr := extractAddressFromConf("/nonexistent/path")
	if addr != "" {
		t.Errorf("expected empty string for missing file, got %q", addr)
	}
}

func TestReadAWGParams(t *testing.T) {
	tmpDir := t.TempDir()
	origConfigDir := configDir
	configDir = tmpDir
	defer func() { configDir = origConfigDir }()

	serverDir := filepath.Join(tmpDir, "server")
	os.MkdirAll(serverDir, 0755)
	os.WriteFile(filepath.Join(serverDir, "awg_params"), []byte(
		"# comment\n"+
			"AWG_VERSION=2.0\n"+
			"AWG_JC=5\n"+
			"AWG_I1=<b 0xc3><b 0x00000001>=extra\n"+
			"\n",
	), 0644)

	params := readAWGParams()

	if params["version"] != "2.0" {
		t.Errorf("version = %q, want 2.0", params["version"])
	}
	if params["jc"] != "5" {
		t.Errorf("jc = %q, want 5", params["jc"])
	}
	// I1 has = signs in value — must use cut on first = only
	if params["i1"] != "<b 0xc3><b 0x00000001>=extra" {
		t.Errorf("i1 = %q, want value with = preserved", params["i1"])
	}
}

func TestReadAWGParams_MissingFile(t *testing.T) {
	origConfigDir := configDir
	configDir = "/nonexistent"
	defer func() { configDir = origConfigDir }()

	params := readAWGParams()
	if len(params) != 0 {
		t.Errorf("expected empty params for missing file, got %v", params)
	}
}

func TestListPeers(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	peers, err := ListPeers()
	if err != nil {
		t.Fatalf("ListPeers error: %v", err)
	}
	if len(peers) != 2 {
		t.Fatalf("expected 2 peers, got %d", len(peers))
	}

	// Find peer1
	var peer1, peerLaptop *PeerInfo
	for i := range peers {
		switch peers[i].ID {
		case "peer1":
			peer1 = &peers[i]
		case "peer_laptop":
			peerLaptop = &peers[i]
		}
	}

	if peer1 == nil {
		t.Fatal("peer1 not found")
	}
	if peer1.Name != "1" {
		t.Errorf("peer1 name = %q, want 1", peer1.Name)
	}
	if peer1.PublicKey != "Peer1PublicKeyBase64===" {
		t.Errorf("peer1 public key = %q", peer1.PublicKey)
	}
	if peer1.Address != "10.13.13.2" {
		t.Errorf("peer1 address = %q", peer1.Address)
	}
	if !peer1.HasConfig {
		t.Error("peer1 should have config")
	}
	if !peer1.HasQR {
		t.Error("peer1 should have QR")
	}

	if peerLaptop == nil {
		t.Fatal("peer_laptop not found")
	}
	if peerLaptop.Name != "laptop" {
		t.Errorf("peer_laptop name = %q, want laptop", peerLaptop.Name)
	}
	if peerLaptop.HasQR {
		t.Error("peer_laptop should NOT have QR")
	}
}

func TestListPeers_EmptyConfig(t *testing.T) {
	tmpDir := t.TempDir()
	setupTestPaths(t, tmpDir)

	peers, err := ListPeers()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(peers) != 0 {
		t.Errorf("expected 0 peers, got %d", len(peers))
	}
}

func TestGetPeerDetail(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	mockTunnelStats(t)

	detail, err := GetPeerDetail("peer1")
	if err != nil {
		t.Fatalf("GetPeerDetail error: %v", err)
	}

	if detail.ID != "peer1" {
		t.Errorf("id = %q", detail.ID)
	}
	if detail.Address != "10.13.13.2" {
		t.Errorf("address = %q", detail.Address)
	}
	if detail.Config == "" {
		t.Error("config should not be empty")
	}
	if !detail.HasConfig {
		t.Error("should have config")
	}
	if !detail.HasQR {
		t.Error("should have QR")
	}
	// Stats should be populated from mock
	if detail.Stats == nil {
		t.Fatal("stats should not be nil")
	}
	if detail.Stats.Endpoint != "1.2.3.4:51820" {
		t.Errorf("stats endpoint = %q", detail.Stats.Endpoint)
	}
	if detail.Stats.TransferRx != 123456 {
		t.Errorf("stats rx = %d", detail.Stats.TransferRx)
	}
}

func TestGetPeerDetail_NotFound(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	_, err := GetPeerDetail("peer99")
	if err == nil {
		t.Fatal("expected error for missing peer")
	}
	if !os.IsNotExist(err) {
		t.Errorf("expected os.IsNotExist, got: %v", err)
	}
}

func TestGetServerInfo(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	info, err := GetServerInfo()
	if err != nil {
		t.Fatalf("GetServerInfo error: %v", err)
	}

	if info.Mode != "server" {
		t.Errorf("mode = %q, want server", info.Mode)
	}
	if info.Uptime != "3600.50s" {
		t.Errorf("uptime = %q", info.Uptime)
	}
	if info.ServerURL != "vpn.example.com" {
		t.Errorf("server_url = %q", info.ServerURL)
	}
	if info.ServerPort != "51820" {
		t.Errorf("server_port = %q", info.ServerPort)
	}
	if info.Subnet != "10.13.13.0" {
		t.Errorf("subnet = %q", info.Subnet)
	}
	if info.PublicKey != "ServerPublicKeyBase64==" {
		t.Errorf("public_key = %q", info.PublicKey)
	}
	if info.Version["amneziawg_tools"] != "v1.0.20260223" {
		t.Errorf("tools version = %q", info.Version["amneziawg_tools"])
	}
	if info.Version["amneziawg_go"] != "v0.2.18" {
		t.Errorf("go version = %q", info.Version["amneziawg_go"])
	}
	if len(info.Tunnels) == 0 {
		t.Error("expected at least one tunnel from activeconfs")
	} else if info.Tunnels[0] != "wg0" {
		t.Errorf("tunnels[0] = %q, want wg0", info.Tunnels[0])
	}
	if info.AWGParams["version"] != "2.0" {
		t.Errorf("awg version = %q", info.AWGParams["version"])
	}
	if info.AWGParams["jc"] != "5" {
		t.Errorf("awg jc = %q", info.AWGParams["jc"])
	}
}

func TestGetServerInfo_ClientMode(t *testing.T) {
	tmpDir := t.TempDir()
	setupTestPaths(t, tmpDir)
	// No peer dirs → client mode

	info, err := GetServerInfo()
	if err != nil {
		t.Fatalf("GetServerInfo error: %v", err)
	}
	if info.Mode != "client" {
		t.Errorf("mode = %q, want client", info.Mode)
	}
}
