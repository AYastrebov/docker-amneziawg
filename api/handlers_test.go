package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// --- Health endpoint ---

func TestHealthEndpoint(t *testing.T) {
	r := setupTestRouter(t)

	w := doRequest(r, "GET", "/health", nil)
	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var body map[string]string
	mustUnmarshal(t, w.Body.Bytes(), &body)
	if body["status"] != "ok" {
		t.Errorf("expected status=ok, got %v", body)
	}
}

func TestHealthEndpoint_NoAuthRequired(t *testing.T) {
	r := setupTestRouter(t)

	w := doRequest(r, "GET", "/health", nil)
	if w.Code != http.StatusOK {
		t.Errorf("health should not require auth, got %d", w.Code)
	}
}

// --- Server endpoint ---

func TestServerEndpoint(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	w := doRequest(r, "GET", "/api/v1/server", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data ServerInfo `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)

	if resp.Data.Mode != "server" {
		t.Errorf("mode = %q", resp.Data.Mode)
	}
	if resp.Data.PublicKey != "ServerPublicKeyBase64==" {
		t.Errorf("public_key = %q", resp.Data.PublicKey)
	}
	if resp.Data.ServerURL != "vpn.example.com" {
		t.Errorf("server_url = %q", resp.Data.ServerURL)
	}
}

func TestServerEndpoint_Unauthorized(t *testing.T) {
	r := setupTestRouter(t)

	w := doRequest(r, "GET", "/api/v1/server", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

// --- Tunnels endpoint ---

func TestTunnelsEndpoint(t *testing.T) {
	r := setupTestRouter(t)
	mockTunnelStats(t)

	w := doRequest(r, "GET", "/api/v1/tunnels", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data []TunnelInfo `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)

	if len(resp.Data) != 1 {
		t.Fatalf("expected 1 tunnel, got %d", len(resp.Data))
	}
	if resp.Data[0].Name != "wg0" {
		t.Errorf("tunnel name = %q", resp.Data[0].Name)
	}
	if len(resp.Data[0].Peers) != 2 {
		t.Errorf("expected 2 peers, got %d", len(resp.Data[0].Peers))
	}
	if resp.Data[0].Peers[0].TransferRx != 123456 {
		t.Errorf("peer1 rx = %d", resp.Data[0].Peers[0].TransferRx)
	}
}

func TestTunnelsEndpoint_Unauthorized(t *testing.T) {
	r := setupTestRouter(t)

	w := doRequest(r, "GET", "/api/v1/tunnels", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestTunnelsEndpoint_Error(t *testing.T) {
	r := setupTestRouter(t)
	mockTunnelStatsError(t)

	w := doRequest(r, "GET", "/api/v1/tunnels", authHeader())
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", w.Code, w.Body.String())
	}

	var resp apiError
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if resp.Error.Code != "INTERNAL_ERROR" {
		t.Errorf("error code = %q", resp.Error.Code)
	}
	// Should NOT leak internal error details
	if strings.Contains(resp.Error.Message, "awg not available") {
		t.Error("internal error details should not be exposed to client")
	}
}

// --- Peers list endpoint ---

func TestPeersEndpoint(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	mockTunnelStats(t)

	w := doRequest(r, "GET", "/api/v1/peers", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data []PeerInfo `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)

	if len(resp.Data) != 2 {
		t.Fatalf("expected 2 peers, got %d", len(resp.Data))
	}

	ids := map[string]bool{}
	for _, p := range resp.Data {
		ids[p.ID] = true
	}
	if !ids["peer1"] {
		t.Error("peer1 not found in response")
	}
	if !ids["peer_laptop"] {
		t.Error("peer_laptop not found in response")
	}
}

func TestPeersEndpoint_Empty(t *testing.T) {
	r := setupTestRouter(t)
	emptyDir := t.TempDir()
	setupTestPaths(t, emptyDir)

	w := doRequest(r, "GET", "/api/v1/peers", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	var resp struct {
		Data []PeerInfo `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if len(resp.Data) != 0 {
		t.Errorf("expected empty array, got %d peers", len(resp.Data))
	}
}

// --- Single peer endpoint ---

func TestPeerEndpoint_ByNumericID(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	mockTunnelStats(t)

	w := doRequest(r, "GET", "/api/v1/peers/1", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data PeerDetail `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)

	if resp.Data.ID != "peer1" {
		t.Errorf("id = %q", resp.Data.ID)
	}
	if resp.Data.Address != "10.13.13.2" {
		t.Errorf("address = %q", resp.Data.Address)
	}
	if resp.Data.Config == "" {
		t.Error("config should not be empty")
	}
	if resp.Data.Stats == nil {
		t.Error("stats should be populated")
	}
	if resp.Data.Stats != nil && resp.Data.Stats.TransferRx != 123456 {
		t.Errorf("stats rx = %d", resp.Data.Stats.TransferRx)
	}
}

func TestPeerEndpoint_ByFullID(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	mockTunnelStats(t)

	w := doRequest(r, "GET", "/api/v1/peers/peer_laptop", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data PeerDetail `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)

	if resp.Data.ID != "peer_laptop" {
		t.Errorf("id = %q", resp.Data.ID)
	}
	if resp.Data.Name != "laptop" {
		t.Errorf("name = %q", resp.Data.Name)
	}
}

func TestPeerEndpoint_ByNameShorthand(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	mockTunnelStats(t)

	w := doRequest(r, "GET", "/api/v1/peers/laptop", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 for name shorthand, got %d: %s", w.Code, w.Body.String())
	}
}

func TestPeerEndpoint_NotFound(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	w := doRequest(r, "GET", "/api/v1/peers/99", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", w.Code)
	}

	var resp apiError
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if resp.Error.Code != "NOT_FOUND" {
		t.Errorf("error code = %q", resp.Error.Code)
	}
}

func TestPeerEndpoint_Unauthorized(t *testing.T) {
	r := setupTestRouter(t)

	w := doRequest(r, "GET", "/api/v1/peers/1", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

// --- Path traversal ---

func TestPeerEndpoint_PathTraversal(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	payloads := []string{
		"peer../../etc",
		"peer../server",
		"peer_../server",
		"../server",
		"..%2Fserver",
	}

	for _, payload := range payloads {
		t.Run(payload, func(t *testing.T) {
			w := doRequest(r, "GET", "/api/v1/peers/"+payload, authHeader())
			// Must be 404, never 200 or 500 with path leak
			if w.Code != http.StatusNotFound {
				t.Errorf("path traversal payload %q: expected 404, got %d: %s", payload, w.Code, w.Body.String())
			}
		})
	}
}

func TestPeerConfigEndpoint_PathTraversal(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	w := doRequest(r, "GET", "/api/v1/peers/peer../../etc/config", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", w.Code)
	}
}

// --- Peer config endpoint ---

func TestPeerConfigEndpoint(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	w := doRequest(r, "GET", "/api/v1/peers/1/config", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	contentType := w.Header().Get("Content-Type")
	if !strings.HasPrefix(contentType, "text/plain") {
		t.Errorf("content-type = %q, want text/plain", contentType)
	}

	disposition := w.Header().Get("Content-Disposition")
	if !strings.Contains(disposition, "peer1.conf") {
		t.Errorf("content-disposition = %q, want peer1.conf", disposition)
	}

	body := w.Body.String()
	if !strings.Contains(body, "[Interface]") {
		t.Error("config body should contain [Interface]")
	}
	if !strings.Contains(body, "Address = 10.13.13.2") {
		t.Error("config body should contain Address")
	}
}

func TestPeerConfigEndpoint_NotFound(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	w := doRequest(r, "GET", "/api/v1/peers/99/config", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", w.Code)
	}
}

// --- Peer QR endpoint ---

func TestPeerQREndpoint(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	w := doRequest(r, "GET", "/api/v1/peers/1/qr", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	contentType := w.Header().Get("Content-Type")
	if contentType != "image/png" {
		t.Errorf("content-type = %q, want image/png", contentType)
	}

	if w.Body.String() != "FAKE_PNG_DATA" {
		t.Errorf("unexpected QR body: %q", w.Body.String())
	}
}

func TestPeerQREndpoint_NotFound(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	// peer_laptop has no QR
	w := doRequest(r, "GET", "/api/v1/peers/laptop/qr", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", w.Code)
	}
}

func TestPeerQREndpoint_PeerNotFound(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	w := doRequest(r, "GET", "/api/v1/peers/99/qr", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", w.Code)
	}
}

// --- Response format ---

func TestSuccessResponseFormat(t *testing.T) {
	resp := SuccessResponse("test")
	data, _ := json.Marshal(resp)
	if !strings.Contains(string(data), `"data":"test"`) {
		t.Errorf("unexpected format: %s", data)
	}
}

func TestErrorResponseFormat(t *testing.T) {
	resp := ErrorResponse("NOT_FOUND", "thing not found")
	data, _ := json.Marshal(resp)
	if !strings.Contains(string(data), `"code":"NOT_FOUND"`) {
		t.Errorf("missing code: %s", data)
	}
	if !strings.Contains(string(data), `"message":"thing not found"`) {
		t.Errorf("missing message: %s", data)
	}
}
