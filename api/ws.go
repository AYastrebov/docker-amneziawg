package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

const statsPollInterval = 2 * time.Second

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true // Non-browser clients (curl, etc.)
		}
		// Accept if Origin host matches the request Host header
		host := r.Host
		// Strip scheme from origin to compare hosts
		for _, prefix := range []string{"https://", "http://"} {
			if len(origin) > len(prefix) && origin[:len(prefix)] == prefix {
				origin = origin[len(prefix):]
				break
			}
		}
		return origin == host
	},
}

// Hub manages WebSocket connections and broadcasts stats.
type Hub struct {
	clients    map[*websocket.Conn]struct{}
	mu         sync.Mutex
	register   chan *websocket.Conn
	unregister chan *websocket.Conn
}

// NewHub creates a new WebSocket hub.
func NewHub() *Hub {
	return &Hub{
		clients:    make(map[*websocket.Conn]struct{}),
		register:   make(chan *websocket.Conn),
		unregister: make(chan *websocket.Conn),
	}
}

// Run starts the hub's event loop and stats polling.
// It returns when ctx is cancelled.
func (h *Hub) Run(ctx context.Context) {
	ticker := time.NewTicker(statsPollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			h.mu.Lock()
			for conn := range h.clients {
				conn.Close()
				delete(h.clients, conn)
			}
			h.mu.Unlock()
			return

		case conn := <-h.register:
			h.mu.Lock()
			h.clients[conn] = struct{}{}
			h.mu.Unlock()

			// Send initial snapshot immediately
			snapshot := GetTunnelStatsSnapshot()
			if data, err := json.Marshal(snapshot); err == nil {
				_ = conn.WriteMessage(websocket.TextMessage, data)
			}

		case conn := <-h.unregister:
			h.mu.Lock()
			delete(h.clients, conn)
			h.mu.Unlock()
			conn.Close()

		case <-ticker.C:
			h.mu.Lock()
			if len(h.clients) == 0 {
				h.mu.Unlock()
				continue
			}

			snapshot := GetTunnelStatsSnapshot()
			data, err := json.Marshal(snapshot)
			h.mu.Unlock()

			if err != nil {
				continue
			}

			h.mu.Lock()
			for conn := range h.clients {
				if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
					delete(h.clients, conn)
					conn.Close()
				}
			}
			h.mu.Unlock()
		}
	}
}

// HandleWebSocket upgrades the connection and registers it with the hub.
func HandleWebSocket(hub *Hub, c *gin.Context) {
	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("WebSocket upgrade error: %v", err)
		return
	}

	hub.register <- conn

	// Read loop — just wait for close
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			hub.unregister <- conn
			break
		}
	}
}

// wsCloseTryAgainLater is the WebSocket close code we send when a subscriber
// can't keep up with the broadcast rate. RFC 6455 reserves 1013 for "Try
// Again Later" — clients should reconnect with backoff.
const wsCloseTryAgainLater = 1013

// wsLogsWriteTimeout caps how long a single WS write can block before we drop
// the connection. Keeps stuck clients from holding goroutines forever.
const wsLogsWriteTimeout = 10 * time.Second

// HandleLogsWebSocket upgrades the connection, subscribes to store, and forwards
// matching log lines to the client until the client disconnects or falls behind.
//
// Filters (level, source) are parsed from query params and applied server-side
// so chatty sources don't waste bandwidth.
func HandleLogsWebSocket(store *LogStore, c *gin.Context) {
	filter := LogFilter{
		Levels:  parseCSV(c.Query("level")),
		Sources: parseCSV(c.Query("source")),
	}

	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("logs WebSocket upgrade error: %v", err)
		return
	}
	defer conn.Close()

	sub := store.Subscribe(128)
	defer store.Unsubscribe(sub)

	lineCh, overflowCh, doneCh := sub.Recv()

	// Read pump: any read error (incl. client close) cancels the write loop.
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}()

	for {
		select {
		case line, ok := <-lineCh:
			if !ok {
				return
			}
			if !filter.Matches(line) {
				continue
			}
			data, err := json.Marshal(line)
			if err != nil {
				continue
			}
			_ = conn.SetWriteDeadline(time.Now().Add(wsLogsWriteTimeout))
			if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
				return
			}

		case <-overflowCh:
			msg := websocket.FormatCloseMessage(wsCloseTryAgainLater, "client too slow")
			_ = conn.WriteControl(websocket.CloseMessage, msg, time.Now().Add(time.Second))
			return

		case <-doneCh:
			return

		case <-readDone:
			return
		}
	}
}
