package main

import (
	"encoding/json"
	"net/http"
	"testing"
)

// installMockServices replaces the per-service query func with a static map.
func installMockServices(t *testing.T, byName map[string]ServiceStatus) {
	t.Helper()
	orig := serviceQueryFunc
	serviceQueryFunc = func(name string) ServiceStatus {
		if s, ok := byName[name]; ok {
			s.Name = name
			return s
		}
		return ServiceStatus{Name: name, Status: "unknown"}
	}
	t.Cleanup(func() { serviceQueryFunc = orig })
}

func TestServicesHandlerReturnsKnownList(t *testing.T) {
	installMockServices(t, map[string]ServiceStatus{
		"svc-amneziawg": {Status: "up", UptimeSeconds: 3600},
		"svc-coredns":   {Status: "down", UptimeSeconds: 12},
		"svc-awg-api":   {Status: "up", UptimeSeconds: 3600},
	})

	r := setupTestRouter(t)
	w := doRequest(r, http.MethodGet, "/api/v1/services", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data []ServiceStatus `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)

	if len(resp.Data) != len(knownServices) {
		t.Fatalf("expected %d services, got %d", len(knownServices), len(resp.Data))
	}

	byName := map[string]ServiceStatus{}
	for _, s := range resp.Data {
		byName[s.Name] = s
	}
	if byName["svc-amneziawg"].Status != "up" {
		t.Errorf("svc-amneziawg should be up, got %+v", byName["svc-amneziawg"])
	}
	if byName["svc-coredns"].Status != "down" {
		t.Errorf("svc-coredns should be down, got %+v", byName["svc-coredns"])
	}
}

func TestServicesHandlerUnauthenticated(t *testing.T) {
	r := setupTestRouter(t)
	w := doRequest(r, http.MethodGet, "/api/v1/services", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestServiceQueryRealMissingBinary(t *testing.T) {
	// Force a binary that surely doesn't exist on PATH.
	orig := s6SvstatBinary
	s6SvstatBinary = "/nonexistent/binary/s6-svstat-bogus"
	t.Cleanup(func() { s6SvstatBinary = orig })

	st := serviceQueryReal("svc-amneziawg")
	if st.Status != "unknown" {
		t.Errorf("expected 'unknown' when binary missing, got %q", st.Status)
	}
}

// Confirm the svstat-line regex behaves on the two real-world formats.
func TestSvstatLineRegex(t *testing.T) {
	cases := []struct {
		in         string
		wantStatus string
		wantUptime string
	}{
		{"up (pid 123) 3601 seconds", "up", "3601"},
		{"down 14 seconds, normally up, want up, ready 14 seconds", "down", "14"},
		{"up (pid 1) 0 seconds, ready 0 seconds", "up", "0"},
	}
	for _, tc := range cases {
		m := svstatLineRe.FindStringSubmatch(tc.in)
		if len(m) != 3 {
			t.Errorf("no match for %q", tc.in)
			continue
		}
		if m[1] != tc.wantStatus || m[2] != tc.wantUptime {
			t.Errorf("for %q: got (%q, %q), want (%q, %q)", tc.in, m[1], m[2], tc.wantStatus, tc.wantUptime)
		}
	}
}

// Verify zero-value JSON for the unknown case.
func TestServiceStatusUnknownSerialization(t *testing.T) {
	data, err := json.Marshal(ServiceStatus{Name: "svc-x", Status: "unknown"})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"name":"svc-x","status":"unknown","uptime_seconds":0}`
	if string(data) != want {
		t.Errorf("got %s, want %s", data, want)
	}
}
