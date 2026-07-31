package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestLogsHandlerEmptyStore(t *testing.T) {
	r := setupTestRouter(t)
	w := doRequest(r, http.MethodGet, "/api/v1/logs", authHeader())

	if w.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data struct {
			Lines []LogLine `json:"lines"`
			Next  string    `json:"next"`
		} `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if len(resp.Data.Lines) != 0 {
		t.Errorf("expected 0 lines, got %d", len(resp.Data.Lines))
	}
	if resp.Data.Next != "" {
		t.Errorf("expected empty next, got %q", resp.Data.Next)
	}
}

func TestLogsHandlerUnauthenticated(t *testing.T) {
	r := setupTestRouter(t)
	w := doRequest(r, http.MethodGet, "/api/v1/logs", nil)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestLogsHandlerReturnsAppendedLines(t *testing.T) {
	r := setupTestRouter(t)

	logStore.Append(LogLevelInfo, LogSourceAWG, "peer laptop handshake completed")
	logStore.Append(LogLevelError, LogSourceAPI, "internal explosion")

	w := doRequest(r, http.MethodGet, "/api/v1/logs", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("status %d, body %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data struct {
			Lines []LogLine `json:"lines"`
		} `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)

	if len(resp.Data.Lines) != 2 {
		t.Fatalf("expected 2 lines, got %d", len(resp.Data.Lines))
	}
	// Newest first.
	if resp.Data.Lines[0].Msg != "internal explosion" {
		t.Errorf("expected newest first, got %q", resp.Data.Lines[0].Msg)
	}
	if resp.Data.Lines[1].Source != LogSourceAWG {
		t.Errorf("expected awg source, got %q", resp.Data.Lines[1].Source)
	}
}

func TestLogsHandlerLevelFilter(t *testing.T) {
	r := setupTestRouter(t)

	logStore.Append(LogLevelDebug, LogSourceAWG, "debug-msg")
	logStore.Append(LogLevelWarn, LogSourceAWG, "warn-msg")
	logStore.Append(LogLevelError, LogSourceAWG, "error-msg")

	w := doRequest(r, http.MethodGet, "/api/v1/logs?level=warn,error", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}

	var resp struct {
		Data struct {
			Lines []LogLine `json:"lines"`
		} `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if len(resp.Data.Lines) != 2 {
		t.Fatalf("expected 2 lines, got %d", len(resp.Data.Lines))
	}
	for _, l := range resp.Data.Lines {
		if l.Level != LogLevelWarn && l.Level != LogLevelError {
			t.Errorf("level %q leaked through filter", l.Level)
		}
	}
}

func TestLogsHandlerScrubsSecrets(t *testing.T) {
	r := setupTestRouter(t)
	logStore.Append(LogLevelInfo, LogSourceAWG, "applied PrivateKey = SHOULD_NOT_LEAK")

	w := doRequest(r, http.MethodGet, "/api/v1/logs", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}

	if strings.Contains(w.Body.String(), "SHOULD_NOT_LEAK") {
		t.Errorf("scrubber failed; body=%s", w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "REDACTED") {
		t.Errorf("REDACTED marker missing; body=%s", w.Body.String())
	}
}

func TestLogsHandlerPaginationWithBeforeCursor(t *testing.T) {
	r := setupTestRouter(t)

	for i := 0; i < 5; i++ {
		time.Sleep(2 * time.Millisecond)
		logStore.Append(LogLevelInfo, LogSourceAWG, "msg")
	}

	// Page 1: limit 2.
	w := doRequest(r, http.MethodGet, "/api/v1/logs?limit=2", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("page1 status %d", w.Code)
	}
	var page1 struct {
		Data struct {
			Lines []LogLine `json:"lines"`
			Next  string    `json:"next"`
		} `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &page1)
	if len(page1.Data.Lines) != 2 || page1.Data.Next == "" {
		t.Fatalf("page1 unexpected: %+v", page1)
	}

	// Page 2: limit 2, before=next1.
	w = doRequest(r, http.MethodGet, "/api/v1/logs?limit=2&before="+url.QueryEscape(page1.Data.Next), authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("page2 status %d", w.Code)
	}
	var page2 struct {
		Data struct {
			Lines []LogLine `json:"lines"`
			Next  string    `json:"next"`
		} `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &page2)
	if len(page2.Data.Lines) != 2 {
		t.Fatalf("page2 unexpected: %+v", page2)
	}
	// Pages should not overlap.
	if page2.Data.Lines[0].ID >= page1.Data.Next {
		t.Errorf("page2 leaked into page1 territory: first id %s >= cursor %s",
			page2.Data.Lines[0].ID, page1.Data.Next)
	}
}

func TestLogsHandlerInvalidLimitFallsBackToDefault(t *testing.T) {
	r := setupTestRouter(t)
	for i := 0; i < 5; i++ {
		logStore.Append(LogLevelInfo, LogSourceAWG, "msg")
	}

	// Non-numeric limit → ignored, default 200 applied.
	w := doRequest(r, http.MethodGet, "/api/v1/logs?limit=notanumber", authHeader())
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
	var resp struct {
		Data struct {
			Lines []LogLine `json:"lines"`
		} `json:"data"`
	}
	mustUnmarshal(t, w.Body.Bytes(), &resp)
	if len(resp.Data.Lines) != 5 {
		t.Errorf("expected all 5 lines (default limit), got %d", len(resp.Data.Lines))
	}
}

// --- WebSocket tests ---

func TestLogsWebSocketStreamsAppendedLines(t *testing.T) {
	r := setupTestRouter(t)
	srv := httptest.NewServer(r)
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws/logs?token=" + testToken
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	// Give the server time to register the subscriber before we append.
	time.Sleep(50 * time.Millisecond)
	logStore.Append(LogLevelInfo, LogSourceAWG, "streamed event")

	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, data, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	var line LogLine
	if err := json.Unmarshal(data, &line); err != nil {
		t.Fatalf("unmarshal: %v (raw=%s)", err, data)
	}
	if line.Msg != "streamed event" || line.Level != LogLevelInfo || line.Source != LogSourceAWG {
		t.Errorf("unexpected line: %+v", line)
	}
}

func TestLogsWebSocketFiltersBySource(t *testing.T) {
	r := setupTestRouter(t)
	srv := httptest.NewServer(r)
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") +
		"/api/v1/ws/logs?token=" + testToken + "&source=api"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	time.Sleep(50 * time.Millisecond)
	// This should be filtered out.
	logStore.Append(LogLevelInfo, LogSourceAWG, "awg-event")
	// This should pass through.
	logStore.Append(LogLevelInfo, LogSourceAPI, "api-event")

	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, data, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	var line LogLine
	if err := json.Unmarshal(data, &line); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if line.Source != LogSourceAPI || line.Msg != "api-event" {
		t.Errorf("filter leaked; got %+v", line)
	}
}

func TestLogsWebSocketRejectsBadToken(t *testing.T) {
	r := setupTestRouter(t)
	srv := httptest.NewServer(r)
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws/logs?token=wrong"
	_, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err == nil {
		t.Fatal("expected dial to fail on bad token")
	}
	if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expected 401, got %v", resp)
	}
}
