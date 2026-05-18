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

// Cadences and timeouts.
const (
	statsPollInterval    = 2 * time.Second
	wsLogsWriteTimeout   = 10 * time.Second
	wsClientSendBuffer   = 16
	hubRegisterBuffer    = 64
	wsCloseTryAgainLater = 1013 // RFC 6585 status 503 / RFC 6455 — "Try Again Later"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true // Non-browser clients (curl, etc.)
		}
		host := r.Host
		for _, prefix := range []string{"https://", "http://"} {
			if len(origin) > len(prefix) && origin[:len(prefix)] == prefix {
				origin = origin[len(prefix):]
				break
			}
		}
		return origin == host
	},
}

// --- Stats Hub ---

// statsClient is one connected WebSocket subscriber to the stats feed.
type statsClient struct {
	conn *websocket.Conn
	send chan []byte
	done chan struct{}
	once sync.Once
}

func (c *statsClient) close() {
	c.once.Do(func() { close(c.done) })
}

// Hub manages stats WebSocket connections and broadcasts the latest tunnel
// snapshot to each on a fixed cadence. Per-client send goroutines let one
// slow consumer fall behind without stalling the rest, and the snapshot is
// gathered outside the lock so the awg-show exec never blocks accept.
type Hub struct {
	register   chan *statsClient
	unregister chan *statsClient

	mu      sync.RWMutex
	clients map[*statsClient]struct{}
}

// NewHub creates a new stats Hub.
func NewHub() *Hub {
	return &Hub{
		register:   make(chan *statsClient, hubRegisterBuffer),
		unregister: make(chan *statsClient, hubRegisterBuffer),
		clients:    map[*statsClient]struct{}{},
	}
}

// Run drives the broadcast loop. It returns when ctx is cancelled, at which
// point every connected client's send channel is closed (the per-client
// write goroutine then drains and closes the underlying conn).
func (h *Hub) Run(ctx context.Context) {
	ticker := time.NewTicker(statsPollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			h.mu.Lock()
			for c := range h.clients {
				close(c.send)
				delete(h.clients, c)
			}
			h.mu.Unlock()
			return

		case client := <-h.register:
			h.mu.Lock()
			h.clients[client] = struct{}{}
			h.mu.Unlock()

			// Initial snapshot — gathered here so a slow first client can't
			// stall accept (it's already registered and has its own write
			// goroutine).
			snapshot := GetTunnelStatsSnapshot()
			if data, err := json.Marshal(snapshot); err == nil {
				select {
				case client.send <- data:
				default:
				}
			} else {
				log.Printf("stats: initial snapshot marshal failed: %v", err)
			}

		case client := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				close(client.send)
			}
			h.mu.Unlock()

		case <-ticker.C:
			// 1. Snapshot is built OUTSIDE the lock so exec.Command never
			//    blocks register/unregister.
			snapshot := GetTunnelStatsSnapshot()
			data, err := json.Marshal(snapshot)
			if err != nil {
				log.Printf("stats: snapshot marshal failed: %v", err)
				continue
			}

			// 2. Snapshot the client set under read lock.
			h.mu.RLock()
			clients := make([]*statsClient, 0, len(h.clients))
			for c := range h.clients {
				clients = append(clients, c)
			}
			h.mu.RUnlock()

			// 3. Non-blocking send to each. A full buffer means the client
			//    is too slow — request unregister, the writer goroutine
			//    will notice via close(send) and tear the conn down.
			for _, c := range clients {
				select {
				case c.send <- data:
				case <-c.done:
				default:
					select {
					case h.unregister <- c:
					default:
					}
				}
			}
		}
	}
}

// HandleWebSocket upgrades the connection, registers it with the hub, and
// runs the per-connection read + write loops until either side disconnects.
func HandleWebSocket(hub *Hub, c *gin.Context) {
	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("stats WebSocket upgrade error: %v", err)
		return
	}

	client := &statsClient{
		conn: conn,
		send: make(chan []byte, wsClientSendBuffer),
		done: make(chan struct{}),
	}

	// Register — but don't block if the hub is down (shutdown) or the request
	// is already cancelled.
	select {
	case hub.register <- client:
	case <-c.Request.Context().Done():
		_ = conn.Close()
		return
	}

	// Write goroutine. Exits when send is closed (unregistered) or done is
	// signalled (client read errored).
	writeDone := make(chan struct{})
	go func() {
		defer close(writeDone)
		defer conn.Close()
		for {
			select {
			case data, ok := <-client.send:
				if !ok {
					return
				}
				_ = conn.SetWriteDeadline(time.Now().Add(wsLogsWriteTimeout))
				if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
					return
				}
			case <-client.done:
				return
			}
		}
	}()

	// Read loop on the calling goroutine: any error (client close, network
	// drop) ends the connection.
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			break
		}
	}

	// Tell the writer to stop, then queue unregister.
	client.close()
	select {
	case hub.unregister <- client:
	default:
	}
	<-writeDone
}

// --- Logs WebSocket ---

// HandleLogsWebSocket upgrades the connection, subscribes to store, and
// forwards matching log lines to the client. Server-side filter pushdown
// (level, source) avoids shipping irrelevant lines. The connection closes
// on client disconnect, on store backpressure (WS close 1013), or when the
// request context cancels (graceful shutdown).
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

	// Read pump: any read error (incl. client close) ends the loop.
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}()

	ctx := c.Request.Context()

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
				log.Printf("logs: line marshal failed: %v", err)
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

		case <-ctx.Done():
			return
		}
	}
}
