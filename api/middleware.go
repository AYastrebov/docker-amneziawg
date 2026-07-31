package main

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// BearerAuth returns middleware that validates the Authorization: Bearer <token> header.
func BearerAuth(expectedToken string) gin.HandlerFunc {
	expected := []byte(expectedToken)
	return func(c *gin.Context) {
		auth := c.GetHeader("Authorization")
		if auth == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, ErrorResponse("UNAUTHORIZED", "Missing Authorization header"))
			return
		}

		parts := strings.SplitN(auth, " ", 2)
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") ||
			subtle.ConstantTimeCompare([]byte(parts[1]), expected) != 1 {
			c.AbortWithStatusJSON(http.StatusUnauthorized, ErrorResponse("UNAUTHORIZED", "Invalid token"))
			return
		}

		c.Next()
	}
}

// constantTimeTokenMatch compares a token against the expected value in constant time.
func constantTimeTokenMatch(got, expected string) bool {
	return subtle.ConstantTimeCompare([]byte(got), []byte(expected)) == 1
}
