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
