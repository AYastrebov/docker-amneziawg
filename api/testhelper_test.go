package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
)

const testToken = "test-secret-token-12345"

// setupTestRouter creates a Gin router identical to production but in test mode.
// The hub goroutine is cleaned up when the test ends.
func setupTestRouter(t *testing.T) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)

	r := gin.New()
	r.SetTrustedProxies(nil)
	r.Use(gin.Recovery())

	r.GET("/health", handleHealth)

	v1 := r.Group("/api/v1")
	v1.Use(BearerAuth(testToken))
	{
		v1.GET("/server", handleServer)
		v1.GET("/system", handleSystem)
		v1.GET("/version", handleVersion)
		v1.GET("/services", handleServices)
		v1.GET("/tunnels", handleTunnels)
		v1.GET("/tunnels/:name", handleTunnel)
		v1.GET("/peers", handlePeers)
		v1.GET("/peers/:id", handlePeer)
		v1.GET("/peers/:id/config", handlePeerConfig)
		v1.GET("/peers/:id/qr", handlePeerQR)
		v1.HEAD("/peers/:id/qr", handlePeerQRHead)
		v1.GET("/logs", handleLogs)
	}

	// Fresh log store for each test, restored on cleanup so tests that
	// don't use logs don't observe a populated buffer.
	origLogStore := logStore
	logStore = NewLogStore(100)
	t.Cleanup(func() { logStore = origLogStore })

	// WebSocket with auth — hub stopped via context on test cleanup
	hub := NewHub()
	ctx, cancel := context.WithCancel(context.Background())
	go hub.Run(ctx)
	t.Cleanup(cancel)

	r.GET("/api/v1/ws/stats", func(c *gin.Context) {
		wsToken := c.Query("token")
		if wsToken == "" || !constantTimeTokenMatch(wsToken, testToken) {
			c.JSON(http.StatusUnauthorized, ErrorResponse("UNAUTHORIZED", "Invalid or missing token"))
			return
		}
		HandleWebSocket(hub, c)
	})

	r.GET("/api/v1/ws/logs", func(c *gin.Context) {
		wsToken := c.Query("token")
		if wsToken == "" || !constantTimeTokenMatch(wsToken, testToken) {
			c.JSON(http.StatusUnauthorized, ErrorResponse("UNAUTHORIZED", "Invalid or missing token"))
			return
		}
		HandleLogsWebSocket(logStore, c)
	})

	return r
}

// setupTestConfig creates a temporary config directory with test peer data.
func setupTestConfig(t *testing.T) string {
	t.Helper()
	tmpDir := t.TempDir()

	// Server directory
	serverDir := filepath.Join(tmpDir, "server")
	if err := os.MkdirAll(serverDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(serverDir, "publickey-server"), []byte("ServerPublicKeyBase64==\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(serverDir, "awg_params"), []byte(
		"AWG_VERSION=2.0\n"+
			"AWG_JC=5\n"+
			"AWG_JMIN=50\n"+
			"AWG_JMAX=200\n"+
			"AWG_S1=86\n"+
			"AWG_S2=12\n"+
			"AWG_H1=90666522-140666522\n"+
			"AWG_H2=536870912-586870912\n",
	), 0644); err != nil {
		t.Fatal(err)
	}

	// Peer1
	peer1Dir := filepath.Join(tmpDir, "peer1")
	if err := os.MkdirAll(peer1Dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(peer1Dir, "publickey-peer1"), []byte("Peer1PublicKeyBase64===\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(peer1Dir, "peer1.conf"), []byte(
		"[Interface]\n"+
			"Address = 10.13.13.2\n"+
			"PrivateKey = PRIVATE_KEY_HERE\n"+
			"DNS = 10.13.13.1\n"+
			"\n"+
			"[Peer]\n"+
			"PublicKey = ServerPublicKeyBase64==\n"+
			"Endpoint = vpn.example.com:51820\n"+
			"AllowedIPs = 0.0.0.0/0\n",
	), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(peer1Dir, "peer1.png"), []byte("FAKE_PNG_DATA"), 0644); err != nil {
		t.Fatal(err)
	}

	// Peer_laptop (named peer)
	peerLaptopDir := filepath.Join(tmpDir, "peer_laptop")
	if err := os.MkdirAll(peerLaptopDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(peerLaptopDir, "publickey-peer_laptop"), []byte("LaptopPublicKeyBase64=\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(peerLaptopDir, "peer_laptop.conf"), []byte(
		"[Interface]\n"+
			"Address = 10.13.13.3\n"+
			"PrivateKey = LAPTOP_PRIVATE_KEY\n"+
			"\n"+
			"[Peer]\n"+
			"PublicKey = ServerPublicKeyBase64==\n"+
			"Endpoint = vpn.example.com:51820\n"+
			"AllowedIPs = 0.0.0.0/0\n",
	), 0644); err != nil {
		t.Fatal(err)
	}
	// No QR for this peer

	// wg_confs directory (not a peer dir — should be ignored)
	if err := os.MkdirAll(filepath.Join(tmpDir, "wg_confs"), 0755); err != nil {
		t.Fatal(err)
	}

	// coredns directory (not a peer dir — should be ignored)
	if err := os.MkdirAll(filepath.Join(tmpDir, "coredns"), 0755); err != nil {
		t.Fatal(err)
	}

	return tmpDir
}

// setupTestPaths overrides all package-level paths for testing.
func setupTestPaths(t *testing.T, cfgDir string) {
	t.Helper()

	origConfigDir := configDir
	origActiveConfs := activeConfsPath
	origUptime := uptimePath
	origBuildVersion := buildVersionPath
	origS6Env := s6EnvDir

	configDir = cfgDir
	activeConfsPath = filepath.Join(cfgDir, "activeconfs")
	uptimePath = filepath.Join(cfgDir, "uptime")
	buildVersionPath = filepath.Join(cfgDir, "build_version")
	s6EnvDir = filepath.Join(cfgDir, "s6env")

	// Create s6 env dir
	if err := os.MkdirAll(s6EnvDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s6EnvDir, "SERVERURL"), []byte("vpn.example.com"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s6EnvDir, "SERVERPORT"), []byte("51820"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s6EnvDir, "INTERNAL_SUBNET"), []byte("10.13.13.0"), 0644); err != nil {
		t.Fatal(err)
	}

	// Create uptime
	if err := os.WriteFile(uptimePath, []byte("3600.50 7200.00\n"), 0644); err != nil {
		t.Fatal(err)
	}

	// Create build_version
	if err := os.WriteFile(buildVersionPath, []byte(
		"AmneziaWG version: 1.0\n"+
			"Build-date: 2026-01-01\n"+
			"amneziawg-tools: v1.0.20260223\n"+
			"amneziawg-go: v0.2.18\n",
	), 0644); err != nil {
		t.Fatal(err)
	}

	// Create activeconfs
	if err := os.WriteFile(activeConfsPath, []byte(
		`declare -a ACTIVECONFS=([0]="/config/wg_confs/wg0.conf")`+"\n",
	), 0644); err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		configDir = origConfigDir
		activeConfsPath = origActiveConfs
		uptimePath = origUptime
		buildVersionPath = origBuildVersion
		s6EnvDir = origS6Env
	})
}

// mockTunnelStats sets up a mock for GetTunnelStats.
func mockTunnelStats(t *testing.T) {
	t.Helper()
	orig := getTunnelStatsFunc
	getTunnelStatsFunc = func() ([]TunnelInfo, error) {
		return []TunnelInfo{
			{
				Name: "wg0",
				Interface: IfaceInfo{
					PublicKey:  "ServerPublicKeyBase64==",
					ListenPort: 51820,
				},
				Peers: []PeerStat{
					{
						PublicKey:       "Peer1PublicKeyBase64===",
						Endpoint:        "1.2.3.4:51820",
						AllowedIPs:      "10.13.13.2/32",
						LatestHandshake: "2026-05-18T10:30:00Z",
						TransferRx:      123456,
						TransferTx:      789012,
					},
					{
						PublicKey:       "LaptopPublicKeyBase64=",
						Endpoint:        "5.6.7.8:51820",
						AllowedIPs:      "10.13.13.3/32",
						LatestHandshake: "2026-05-18T10:25:00Z",
						TransferRx:      5000,
						TransferTx:      10000,
					},
				},
			},
		}, nil
	}
	t.Cleanup(func() { getTunnelStatsFunc = orig })
}

// mockTunnelStatsError makes GetTunnelStats return an error.
func mockTunnelStatsError(t *testing.T) {
	t.Helper()
	orig := getTunnelStatsFunc
	getTunnelStatsFunc = func() ([]TunnelInfo, error) {
		return nil, errors.New("awg not available")
	}
	t.Cleanup(func() { getTunnelStatsFunc = orig })
}

// authHeader returns a valid Authorization header for tests.
func authHeader() http.Header {
	h := http.Header{}
	h.Set("Authorization", "Bearer "+testToken)
	return h
}

// doRequest performs an HTTP request against the test router.
func doRequest(r *gin.Engine, method, path string, headers http.Header) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	if headers != nil {
		req.Header = headers
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// mustUnmarshal unmarshals JSON or fails the test.
func mustUnmarshal(t *testing.T, data []byte, v interface{}) {
	t.Helper()
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatalf("JSON unmarshal error: %v\nbody: %s", err, data)
	}
}
