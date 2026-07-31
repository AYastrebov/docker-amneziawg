package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"go.uber.org/goleak"
)

func TestWebSocket_AuthRequired(t *testing.T) {
	r := setupTestRouter(t)

	// No token
	w := doRequest(r, "GET", "/api/v1/ws/stats", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 without token, got %d", w.Code)
	}

	// Wrong token
	w = doRequest(r, "GET", "/api/v1/ws/stats?token=wrong", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 with wrong token, got %d", w.Code)
	}
}

func TestWebSocket_Connection(t *testing.T) {
	r := setupTestRouter(t)
	mockTunnelStats(t)

	server := httptest.NewServer(r)
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") +
		"/api/v1/ws/stats?token=" + testToken

	conn, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("WebSocket dial error: %v", err)
	}
	defer conn.Close()

	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Errorf("expected 101, got %d", resp.StatusCode)
	}

	// Should receive initial snapshot immediately
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, msg, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read error: %v", err)
	}

	var snapshot StatsSnapshot
	if err := json.Unmarshal(msg, &snapshot); err != nil {
		t.Fatalf("JSON parse error: %v", err)
	}

	if snapshot.Timestamp == "" {
		t.Error("snapshot missing timestamp")
	}
	if len(snapshot.Data) != 1 {
		t.Errorf("expected 1 tunnel in snapshot, got %d", len(snapshot.Data))
	}
}

func TestWebSocket_WrongToken(t *testing.T) {
	r := setupTestRouter(t)

	server := httptest.NewServer(r)
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") +
		"/api/v1/ws/stats?token=invalid"

	_, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err == nil {
		t.Error("expected error for wrong token")
	}
	if resp != nil && resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", resp.StatusCode)
	}
}

func TestHub_InitialState(t *testing.T) {
	hub := NewHub()
	ctx, cancel := context.WithCancel(context.Background())
	go hub.Run(ctx)
	t.Cleanup(cancel)

	hub.mu.Lock()
	count := len(hub.clients)
	hub.mu.Unlock()
	if count != 0 {
		t.Errorf("expected 0 clients, got %d", count)
	}
}

func TestHub_Shutdown(t *testing.T) {
	hub := NewHub()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		hub.Run(ctx)
		close(done)
	}()

	cancel()

	select {
	case <-done:
		// Hub stopped as expected
	case <-time.After(2 * time.Second):
		t.Fatal("hub did not stop after context cancellation")
	}
}

func TestHub_NoGoroutineLeakOnClientDisconnect(t *testing.T) {
	defer goleak.VerifyNone(t,
		// httptest leaves a background goroutine; not our concern.
		goleak.IgnoreTopFunction("net/http.(*persistConn).writeLoop"),
		goleak.IgnoreTopFunction("internal/poll.runtime_pollWait"),
		// Hub.Run is cancelled by t.Cleanup which fires after this deferred
		// check; we trust other tests to catch hub leakage on shutdown.
		goleak.IgnoreTopFunction("awg-api.(*Hub).Run"),
	)

	r := setupTestRouter(t)
	mockTunnelStats(t)
	server := httptest.NewServer(r)
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") +
		"/api/v1/ws/stats?token=" + testToken
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	// Read initial snapshot so we know the server-side goroutines are up.
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := conn.ReadMessage(); err != nil {
		t.Fatalf("read: %v", err)
	}

	_ = conn.Close()
	// Give the server side time to notice and tear down.
	time.Sleep(200 * time.Millisecond)
}

func TestWSToken_PrecedenceAndFallbacks(t *testing.T) {
	gin.SetMode(gin.TestMode)

	newCtx := func(target string, headers map[string]string) *gin.Context {
		req := httptest.NewRequest(http.MethodGet, target, nil)
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		c, _ := gin.CreateTestContext(httptest.NewRecorder())
		c.Request = req
		return c
	}

	tests := []struct {
		name    string
		target  string
		headers map[string]string
		want    string
	}{
		{
			name:    "subprotocol wins",
			target:  "/api/v1/ws/stats?token=fromquery",
			headers: map[string]string{"Sec-WebSocket-Protocol": "bearer, fromproto"},
			want:    "fromproto",
		},
		{
			name:    "authorization header used when no subprotocol",
			target:  "/api/v1/ws/stats?token=fromquery",
			headers: map[string]string{"Authorization": "Bearer fromheader"},
			want:    "fromheader",
		},
		{
			name:   "query string still works (deprecated)",
			target: "/api/v1/ws/stats?token=fromquery",
			want:   "fromquery",
		},
		{
			name:   "nothing supplied",
			target: "/api/v1/ws/stats",
			want:   "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := wsToken(newCtx(tt.target, tt.headers)); got != tt.want {
				t.Errorf("wsToken() = %q, want %q", got, tt.want)
			}
		})
	}
}
