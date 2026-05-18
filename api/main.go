package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
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
	port := os.Getenv("API_PORT")
	if port == "" {
		port = "8081"
	}

	token := os.Getenv("API_TOKEN")
	if token == "" {
		log.Fatal("API_TOKEN environment variable is required")
	}

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.SetTrustedProxies(nil)
	r.Use(gin.Recovery())
	r.Use(gin.LoggerWithConfig(gin.LoggerConfig{
		SkipPaths: []string{"/health"},
	}))

	// Health check — no auth
	r.GET("/health", handleHealth)

	// Swagger UI — no auth
	r.GET("/swagger/*any", ginSwagger.WrapHandler(swaggerFiles.Handler))

	// Authenticated API routes
	v1 := r.Group("/api/v1")
	v1.Use(BearerAuth(token))
	{
		v1.GET("/server", handleServer)
		v1.GET("/tunnels", handleTunnels)
		v1.GET("/peers", handlePeers)
		v1.GET("/peers/:id", handlePeer)
		v1.GET("/peers/:id/config", handlePeerConfig)
		v1.GET("/peers/:id/qr", handlePeerQR)
	}

	// WebSocket — auth via query param
	hub := NewHub()
	hubCtx, hubCancel := context.WithCancel(context.Background())
	defer hubCancel()
	go hub.Run(hubCtx)

	r.GET("/api/v1/ws/stats", func(c *gin.Context) {
		wsToken := c.Query("token")
		if wsToken == "" || !constantTimeTokenMatch(wsToken, token) {
			c.JSON(http.StatusUnauthorized, ErrorResponse("UNAUTHORIZED", "Invalid or missing token"))
			return
		}
		HandleWebSocket(hub, c)
	})

	srv := &http.Server{
		Addr:              "0.0.0.0:" + port,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("AmneziaWG API listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("API server error: %v", err)
		}
	}()

	// Graceful shutdown on SIGTERM/SIGINT
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
	<-quit

	log.Println("Shutting down API server...")
	hubCancel()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("Server shutdown error: %v", err)
	}
	fmt.Println("API server stopped")
}
