package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"

	"github.com/gin-gonic/gin"
)

// logStore holds the in-memory log buffer. It's a package-level variable so
// handlers can pick it up without a router-construction time injection, which
// mirrors the existing pattern for configDir, getTunnelStatsFunc, etc.
var logStore *LogStore

// --- Response helpers ---

type apiResponse struct {
	Data interface{} `json:"data,omitempty"`
}

type apiError struct {
	Error errorDetail `json:"error"`
}

type errorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func SuccessResponse(data interface{}) apiResponse {
	return apiResponse{Data: data}
}

func ErrorResponse(code, message string) apiError {
	return apiError{Error: errorDetail{Code: code, Message: message}}
}

func internalError(c *gin.Context, err error) {
	log.Printf("internal error: %v", err)
	c.JSON(http.StatusInternalServerError, ErrorResponse("INTERNAL_ERROR", "Internal server error"))
}

// --- Handlers ---

// handleHealth godoc
// @Summary Health check
// @Description Returns API health status. No authentication required.
// @Tags infrastructure
// @Produce json
// @Success 200 {object} map[string]string
// @Router /health [get]
func handleHealth(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// handleServer godoc
// @Summary Get server information
// @Description Returns server mode, active tunnels, uptime, version, network config, and AWG obfuscation parameters.
// @Tags server
// @Produce json
// @Security BearerAuth
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Failure 500 {object} apiError
// @Router /api/v1/server [get]
func handleServer(c *gin.Context) {
	info, err := GetServerInfo()
	if err != nil {
		internalError(c, err)
		return
	}
	c.JSON(http.StatusOK, SuccessResponse(info))
}

// handleVersion godoc
// @Summary Get version info
// @Description Returns just the upstream component versions and build date. Lightweight alternative to /api/v1/server for "is there a new image" probes.
// @Tags server
// @Produce json
// @Security BearerAuth
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Router /api/v1/version [get]
func handleVersion(c *gin.Context) {
	info, err := GetServerInfo()
	if err != nil {
		internalError(c, err)
		return
	}
	c.JSON(http.StatusOK, SuccessResponse(info.Version))
}

// handleSystem godoc
// @Summary Get host system metrics
// @Description Returns CPU load averages, memory usage, disk usage of /config, and host uptime. Designed for the panel's health badge polling every 5–10s.
// @Tags server
// @Produce json
// @Security BearerAuth
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Failure 500 {object} apiError
// @Router /api/v1/system [get]
func handleSystem(c *gin.Context) {
	info, err := GetSystemInfo()
	if err != nil {
		internalError(c, err)
		return
	}
	c.JSON(http.StatusOK, SuccessResponse(info))
}

// handleServices godoc
// @Summary List s6-overlay service statuses
// @Description Returns up/down state and uptime for the container's known s6 services. Returns an empty list when s6 runtime state isn't reachable (e.g. running outside the container).
// @Tags server
// @Produce json
// @Security BearerAuth
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Router /api/v1/services [get]
func handleServices(c *gin.Context) {
	services, err := GetServiceStatuses()
	if err != nil {
		internalError(c, err)
		return
	}
	c.JSON(http.StatusOK, SuccessResponse(services))
}

// handleTunnels godoc
// @Summary Get live tunnel statistics
// @Description Returns parsed output of `awg show all dump` with per-peer transfer, handshake, and endpoint data.
// @Tags tunnels
// @Produce json
// @Security BearerAuth
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Failure 500 {object} apiError
// @Router /api/v1/tunnels [get]
func handleTunnels(c *gin.Context) {
	tunnels, err := GetTunnelStats()
	if err != nil {
		internalError(c, err)
		return
	}
	c.JSON(http.StatusOK, SuccessResponse(tunnels))
}

// handleTunnel godoc
// @Summary Get one tunnel's live statistics
// @Description Returns parsed `awg show` data for a single tunnel by name. 404 if the tunnel isn't active.
// @Tags tunnels
// @Produce json
// @Param name path string true "Tunnel name (e.g. wg0)"
// @Security BearerAuth
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Failure 404 {object} apiError
// @Failure 500 {object} apiError
// @Router /api/v1/tunnels/{name} [get]
func handleTunnel(c *gin.Context) {
	name := c.Param("name")
	tunnels, err := GetTunnelStats()
	if err != nil {
		internalError(c, err)
		return
	}
	for _, t := range tunnels {
		if t.Name == name {
			c.JSON(http.StatusOK, SuccessResponse(t))
			return
		}
	}
	c.JSON(http.StatusNotFound, ErrorResponse("NOT_FOUND", fmt.Sprintf("Tunnel %s not found", name)))
}

// handlePeers godoc
// @Summary List all peers
// @Description Returns a list of configured peers with their IDs, public keys, addresses, and availability flags.
// @Tags peers
// @Produce json
// @Security BearerAuth
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Failure 500 {object} apiError
// @Router /api/v1/peers [get]
func handlePeers(c *gin.Context) {
	peers, err := ListPeers()
	if err != nil {
		internalError(c, err)
		return
	}
	c.JSON(http.StatusOK, SuccessResponse(peers))
}

// handlePeer godoc
// @Summary Get single peer details
// @Description Returns detailed info for a specific peer including config text and live tunnel stats.
// @Tags peers
// @Produce json
// @Param id path string true "Peer ID (e.g. peer1, peer_laptop)"
// @Security BearerAuth
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Failure 404 {object} apiError
// @Failure 500 {object} apiError
// @Router /api/v1/peers/{id} [get]
func handlePeer(c *gin.Context) {
	id := c.Param("id")
	peerID := ResolvePeerID(id)

	peer, err := GetPeerDetail(peerID)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, ErrorResponse("NOT_FOUND", fmt.Sprintf("Peer %s not found", id)))
			return
		}
		internalError(c, err)
		return
	}
	c.JSON(http.StatusOK, SuccessResponse(peer))
}

// handlePeerConfig godoc
// @Summary Download (or view) peer config file
// @Description Returns the raw .conf file for a peer. Sends Content-Disposition: attachment by default; pass `inline=1` to omit it so the panel can render the conf inline.
// @Tags peers
// @Produce text/plain
// @Param id path string true "Peer ID (e.g. peer1, peer_laptop)"
// @Param inline query int false "Set 1 to omit the attachment header and let the browser render the file inline"
// @Security BearerAuth
// @Success 200 {string} string
// @Failure 401 {object} apiError
// @Failure 404 {object} apiError
// @Router /api/v1/peers/{id}/config [get]
func handlePeerConfig(c *gin.Context) {
	id := c.Param("id")
	peerID := ResolvePeerID(id)

	confPath := filepath.Join(configDir, peerID, peerID+".conf")
	data, err := os.ReadFile(confPath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, ErrorResponse("NOT_FOUND", fmt.Sprintf("Config for peer %s not found", id)))
			return
		}
		internalError(c, err)
		return
	}

	if c.Query("inline") != "1" {
		c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.conf"`, peerID))
	}
	c.Data(http.StatusOK, "text/plain; charset=utf-8", data)
}

// handlePeerQR godoc
// @Summary Get peer QR code
// @Description Returns the QR code PNG image for a peer's config.
// @Tags peers
// @Produce image/png
// @Param id path string true "Peer ID (e.g. peer1, peer_laptop)"
// @Security BearerAuth
// @Success 200 {file} binary
// @Failure 401 {object} apiError
// @Failure 404 {object} apiError
// @Router /api/v1/peers/{id}/qr [get]
func handlePeerQR(c *gin.Context) {
	id := c.Param("id")
	peerID := ResolvePeerID(id)

	pngPath := filepath.Join(configDir, peerID, peerID+".png")
	data, err := os.ReadFile(pngPath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, ErrorResponse("NOT_FOUND", fmt.Sprintf("QR code for peer %s not found", id)))
			return
		}
		internalError(c, err)
		return
	}

	c.Data(http.StatusOK, "image/png", data)
}

// handlePeerQRHead godoc
// @Summary Probe peer QR existence
// @Description Returns 200 with no body when the QR PNG exists, 404 otherwise. Lets the panel preflight a QR URL without pulling the PNG bytes.
// @Tags peers
// @Param id path string true "Peer ID"
// @Security BearerAuth
// @Success 200 {string} string ""
// @Failure 401 {object} apiError
// @Failure 404 {object} apiError
// @Router /api/v1/peers/{id}/qr [head]
func handlePeerQRHead(c *gin.Context) {
	id := c.Param("id")
	peerID := ResolvePeerID(id)

	pngPath := filepath.Join(configDir, peerID, peerID+".png")
	if _, err := os.Stat(pngPath); err != nil {
		if os.IsNotExist(err) {
			c.Status(http.StatusNotFound)
			return
		}
		internalError(c, err)
		return
	}
	c.Header("Content-Type", "image/png")
	c.Status(http.StatusOK)
}

// handleLogs godoc
// @Summary Get recent log lines
// @Description Returns a paginated tail of recent structured log lines, newest first. Sensitive fields (PrivateKey, PreSharedKey, bearer tokens) are scrubbed before lines enter the store.
// @Tags logs
// @Produce json
// @Security BearerAuth
// @Param limit query int false "Max lines to return (default 200, max 1000)"
// @Param before query string false "Cursor for older pages: ULID line id or RFC3339 timestamp"
// @Param level query string false "Comma-separated levels to include (debug,info,warn,error)"
// @Param source query string false "Comma-separated sources to include (awg, api, ...)"
// @Success 200 {object} apiResponse
// @Failure 401 {object} apiError
// @Router /api/v1/logs [get]
func handleLogs(c *gin.Context) {
	if logStore == nil {
		internalError(c, fmt.Errorf("log store not initialized"))
		return
	}

	limit := 200
	if raw := c.Query("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			limit = n
		}
	}

	lines, next := logStore.Query(LogQuery{
		Limit:  limit,
		Before: c.Query("before"),
		Filter: LogFilter{
			Levels:  parseCSV(c.Query("level")),
			Sources: parseCSV(c.Query("source")),
		},
	})

	c.JSON(http.StatusOK, SuccessResponse(gin.H{
		"lines": lines,
		"next":  next,
	}))
}
