package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --- O_NOFOLLOW symlink defense (H4) ---

func TestPeerConfigRefusesSymlink(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	// Replace peer1's .conf with a symlink to a sensitive file outside /config.
	confPath := filepath.Join(cfgDir, "peer1", "peer1.conf")
	if err := os.Remove(confPath); err != nil {
		t.Fatal(err)
	}
	// Target doesn't have to exist for the symlink — but using /etc/hostname
	// keeps the test deterministic across distros where it does exist.
	if err := os.Symlink("/etc/hostname", confPath); err != nil {
		t.Fatal(err)
	}

	r := setupTestRouter(t)
	w := doRequest(r, http.MethodGet, "/api/v1/peers/1/config", authHeader())
	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for symlinked conf, got %d: %s", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), "/etc/hostname") || w.Body.Len() > 200 {
		t.Errorf("response leaked symlink target: %s", w.Body.String())
	}
}

func TestPeerQRRefusesSymlink(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	pngPath := filepath.Join(cfgDir, "peer1", "peer1.png")
	if err := os.Remove(pngPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc/hostname", pngPath); err != nil {
		t.Fatal(err)
	}

	r := setupTestRouter(t)

	w := doRequest(r, http.MethodGet, "/api/v1/peers/1/qr", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("GET expected 404 for symlinked qr, got %d", w.Code)
	}

	w = doRequest(r, http.MethodHead, "/api/v1/peers/1/qr", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("HEAD expected 404 for symlinked qr, got %d", w.Code)
	}
}

// --- GET /api/v1/tunnels/:name ---

func TestTunnelSingleFound(t *testing.T) {
	mockTunnelStats(t)
	r := setupTestRouter(t)

	w := doRequest(r, http.MethodGet, "/api/v1/tunnels/wg0", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data TunnelInfo `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if resp.Data.Name != "wg0" {
		t.Errorf("got tunnel %q, want wg0", resp.Data.Name)
	}
	if len(resp.Data.Peers) == 0 {
		t.Errorf("expected peers populated, got 0")
	}
}

func TestTunnelSingleNotFound(t *testing.T) {
	mockTunnelStats(t)
	r := setupTestRouter(t)

	w := doRequest(r, http.MethodGet, "/api/v1/tunnels/wg99", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d (%s)", w.Code, w.Body.String())
	}
}

func TestTunnelSingleStatsError(t *testing.T) {
	mockTunnelStatsError(t)
	r := setupTestRouter(t)

	w := doRequest(r, http.MethodGet, "/api/v1/tunnels/wg0", authHeader())
	if w.Code != http.StatusInternalServerError {
		t.Errorf("expected 500, got %d", w.Code)
	}
}

// --- GET /api/v1/version ---

func TestVersionHandler(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)

	r := setupTestRouter(t)
	w := doRequest(r, http.MethodGet, "/api/v1/version", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data map[string]string `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if resp.Data["amneziawg_tools"] == "" {
		t.Errorf("expected amneziawg_tools populated, got %+v", resp.Data)
	}
	if resp.Data["amneziawg_go"] == "" {
		t.Errorf("expected amneziawg_go populated, got %+v", resp.Data)
	}
}

func TestVersionHandlerUnauthenticated(t *testing.T) {
	r := setupTestRouter(t)
	w := doRequest(r, http.MethodGet, "/api/v1/version", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

// --- inline=1 query for peer config ---

func TestPeerConfigInlineQueryDropsAttachmentHeader(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	r := setupTestRouter(t)

	// Default behavior: Content-Disposition attachment present.
	w := doRequest(r, http.MethodGet, "/api/v1/peers/1/config", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("default status %d", w.Code)
	}
	if cd := w.Header().Get("Content-Disposition"); !strings.Contains(cd, "attachment") {
		t.Errorf("default mode: expected attachment header, got %q", cd)
	}

	// inline=1: header omitted.
	w = doRequest(r, http.MethodGet, "/api/v1/peers/1/config?inline=1", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("inline status %d", w.Code)
	}
	if cd := w.Header().Get("Content-Disposition"); cd != "" {
		t.Errorf("inline mode: expected no attachment header, got %q", cd)
	}
	if !strings.Contains(w.Body.String(), "[Interface]") {
		t.Errorf("inline body missing conf content: %s", w.Body.String())
	}
}

// --- HEAD /api/v1/peers/:id/qr ---

func TestPeerQRHeadFound(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	r := setupTestRouter(t)

	w := doRequest(r, http.MethodHead, "/api/v1/peers/1/qr", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "image/png" {
		t.Errorf("expected image/png, got %q", ct)
	}
	if w.Body.Len() != 0 {
		t.Errorf("HEAD response should have empty body, got %d bytes", w.Body.Len())
	}
}

func TestPeerQRHeadNotFound(t *testing.T) {
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	r := setupTestRouter(t)

	// peer_laptop has no PNG (per testhelper setup).
	w := doRequest(r, http.MethodHead, "/api/v1/peers/laptop/qr", authHeader())
	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", w.Code)
	}
}

func TestPeerQRHeadUnauthenticated(t *testing.T) {
	r := setupTestRouter(t)
	w := doRequest(r, http.MethodHead, "/api/v1/peers/1/qr", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}
