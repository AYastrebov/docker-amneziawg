package main

import (
	"net/http"
	"testing"
)

func TestBearerAuth_ValidToken(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	mockTunnelStats(t)

	w := doRequest(r, "GET", "/api/v1/peers", authHeader())
	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
}

func TestBearerAuth_MissingHeader(t *testing.T) {
	r := setupTestRouter(t)

	w := doRequest(r, "GET", "/api/v1/peers", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}

	var resp apiError
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if resp.Error.Code != "UNAUTHORIZED" {
		t.Errorf("expected UNAUTHORIZED, got %s", resp.Error.Code)
	}
	if resp.Error.Message != "Missing Authorization header" {
		t.Errorf("unexpected message: %s", resp.Error.Message)
	}
}

func TestBearerAuth_InvalidToken(t *testing.T) {
	r := setupTestRouter(t)

	h := http.Header{}
	h.Set("Authorization", "Bearer wrong-token")
	w := doRequest(r, "GET", "/api/v1/peers", h)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}

	var resp apiError
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if resp.Error.Code != "UNAUTHORIZED" {
		t.Errorf("expected UNAUTHORIZED, got %s", resp.Error.Code)
	}
	if resp.Error.Message != "Invalid token" {
		t.Errorf("unexpected message: %s", resp.Error.Message)
	}
}

func TestBearerAuth_MalformedHeader(t *testing.T) {
	r := setupTestRouter(t)

	tests := []struct {
		name   string
		header string
	}{
		{"no bearer prefix", testToken},
		{"basic auth", "Basic dXNlcjpwYXNz"},
		{"empty bearer", "Bearer "},
		{"bearer only", "Bearer"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			h := http.Header{}
			h.Set("Authorization", tc.header)
			w := doRequest(r, "GET", "/api/v1/peers", h)
			if w.Code != http.StatusUnauthorized {
				t.Errorf("expected 401, got %d for header %q", w.Code, tc.header)
			}
		})
	}
}

func TestBearerAuth_CaseInsensitiveBearer(t *testing.T) {
	r := setupTestRouter(t)
	cfgDir := setupTestConfig(t)
	setupTestPaths(t, cfgDir)
	mockTunnelStats(t)

	h := http.Header{}
	h.Set("Authorization", "bearer "+testToken)
	w := doRequest(r, "GET", "/api/v1/peers", h)
	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for lowercase 'bearer', got %d", w.Code)
	}
}
