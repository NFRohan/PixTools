package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// HealthCheck provides dependency readiness probes
func (s *Server) HealthCheck(c *gin.Context) {
	// Simple connection checks to dependencies
	sqlDB, err := s.DB.DB()
	dbStatus := "OK"
	if err != nil || sqlDB.Ping() != nil {
		dbStatus = "DOWN"
	}

	// Idempotency check implies Redis Ping
	redisStatus := "OK"
	if _, err := s.Idempotency.CheckIdempotency(c.Request.Context(), "ping"); err != nil {
		redisStatus = "DOWN"
	}

	status := http.StatusOK
	if dbStatus == "DOWN" || redisStatus == "DOWN" {
		status = http.StatusServiceUnavailable
	}

	c.JSON(status, gin.H{
		"status": "OK",
		"checks": gin.H{
			"db":    dbStatus,
			"redis": redisStatus,
		},
	})
}
