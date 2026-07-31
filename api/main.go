// Package main is the docker-amneziawg REST API service. It exposes a
// read-only HTTP/WebSocket surface for the panel and Telegram bot to monitor
// the container: server info, tunnel and peer state, host metrics, s6
// service status, and a structured log feed. Authentication is a single
// bearer token loaded from API_TOKEN; the swagger annotations on each
// handler document the contract.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	_ "awg-api/docs"

	"github.com/gin-gonic/gin"
	swaggerFiles "github.com/swaggo/files"
	ginSwagger "github.com/swaggo/gin-swagger"
)

// @title AmneziaWG API
// @version 1.0
// @description REST API for managing and monitoring AmneziaWG VPN peers and tunnels.
// @host localhost:8081
// @BasePath /
// @securityDefinitions.apikey BearerAuth
// @in header
// @name Authorization
// @description Bearer token authentication. Use "Bearer <token>" format.

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	port := os.Getenv("API_PORT")
	if port == "" {
		port = "8081"
	}

	token := os.Getenv("API_TOKEN")
	if token == "" {
		slog.Error("API_TOKEN environment variable is required")
		os.Exit(1)
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	_ = r.SetTrustedProxies(nil)
	r.Use(gin.Recovery())
	r.Use(gin.LoggerWithConfig(gin.LoggerConfig{
		// WS paths are skipped because the deprecated ?token= form would
		// otherwise be written to the access log verbatim.
		SkipPaths: []string{"/health", "/api/v1/ws/stats", "/api/v1/ws/logs"},
	}))

	// Health check — no auth
	r.GET("/health", handleHealth)

	// Swagger UI is opt-in via API_SWAGGER (default off). It is mounted
	// outside the authenticated route group, so keeping it off by default
	// avoids leaking the API surface to unauthenticated callers behind a
	// public reverse proxy. Set API_SWAGGER=true to enable it.
	if swaggerEnabled() {
		r.GET("/swagger/*any", ginSwagger.WrapHandler(swaggerFiles.Handler))
	}

	// Authenticated API routes
	v1 := r.Group("/api/v1")
	v1.Use(BearerAuth(token))
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

	// Log store + AWG event poller. Started before WS hubs so existing
	// tunnels are seeded into baseline state immediately.
	logStore = NewLogStore(5000)
	bgCtx, bgCancel := context.WithCancel(context.Background())
	defer bgCancel()
	go runAWGEventLoop(bgCtx, logStore, 0)

	// WebSocket — auth via query param
	hub := NewHub()
	go hub.Run(bgCtx)

	r.GET("/api/v1/ws/stats", func(c *gin.Context) {
		presented := wsToken(c)
		if presented == "" || !constantTimeTokenMatch(presented, token) {
			c.JSON(http.StatusUnauthorized, ErrorResponse("UNAUTHORIZED", "Invalid or missing token"))
			return
		}
		HandleWebSocket(hub, c)
	})

	r.GET("/api/v1/ws/logs", func(c *gin.Context) {
		presented := wsToken(c)
		if presented == "" || !constantTimeTokenMatch(presented, token) {
			c.JSON(http.StatusUnauthorized, ErrorResponse("UNAUTHORIZED", "Invalid or missing token"))
			return
		}
		HandleLogsWebSocket(logStore, c)
	})

	srv := &http.Server{
		Addr:              "0.0.0.0:" + port,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		slog.Info("api listening", "port", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("api server error", "err", err)
			os.Exit(1)
		}
	}()

	// Graceful shutdown on SIGTERM/SIGINT
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
	<-quit

	slog.Info("shutting down api server")
	bgCancel()
	logStore.Close()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("server shutdown error", "err", err)
	}
	slog.Info("api server stopped")
}

// swaggerEnabled reports whether the Swagger UI should be mounted. The UI sits
// outside the authenticated route group, so it is opt-in: only "1", "true",
// "yes", or "on" (case-insensitive) enable it. Unset or anything else keeps it
// off, which is the safe default for a sidecar reachable through a public
// reverse proxy.
func swaggerEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("API_SWAGGER"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
