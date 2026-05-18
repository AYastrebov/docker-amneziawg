package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/gin-gonic/gin"
)

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
// @Summary Download peer config file
// @Description Returns the raw .conf file for a peer as a downloadable text file.
// @Tags peers
// @Produce text/plain
// @Param id path string true "Peer ID (e.g. peer1, peer_laptop)"
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

	c.Header("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.conf"`, peerID))
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
