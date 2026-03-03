package handlers

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/streadway/amqp"
)

func (s *Server) Livez(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "alive"})
}

func (s *Server) Readyz(c *gin.Context) {
	dependencies := map[string]string{
		"database": "ok",
		"redis":    "ok",
		"rabbitmq": "ok",
	}

	if !s.checkDatabase(c.Request.Context()) {
		dependencies["database"] = "unreachable"
	}
	if !s.checkRedis(c.Request.Context()) {
		dependencies["redis"] = "unreachable"
	}
	if !s.checkRabbitMQ() {
		dependencies["rabbitmq"] = "unreachable"
	}

	s.respondHealth(c, dependencies)
}

// HealthCheck provides deep dependency readiness probes.
func (s *Server) HealthCheck(c *gin.Context) {
	dependencies := map[string]string{
		"database": "ok",
		"redis":    "ok",
		"rabbitmq": "ok",
		"s3":       "ok",
	}

	if !s.checkDatabase(c.Request.Context()) {
		dependencies["database"] = "unreachable"
	}
	if !s.checkRedis(c.Request.Context()) {
		dependencies["redis"] = "unreachable"
	}
	if !s.checkRabbitMQ() {
		dependencies["rabbitmq"] = "unreachable"
	}
	if !s.checkS3(c.Request.Context()) {
		dependencies["s3"] = "unreachable"
	}

	s.respondHealth(c, dependencies)
}

func (s *Server) respondHealth(c *gin.Context, dependencies map[string]string) {
	healthy := true
	for _, state := range dependencies {
		if state != "ok" {
			healthy = false
			break
		}
	}

	payload := gin.H{
		"status":       "healthy",
		"dependencies": dependencies,
	}
	if !healthy {
		payload["status"] = "unhealthy"
		c.JSON(http.StatusServiceUnavailable, payload)
		return
	}

	c.JSON(http.StatusOK, payload)
}

func (s *Server) checkDatabase(ctx context.Context) bool {
	sqlDB, err := s.DB.DB()
	if err != nil {
		return false
	}

	healthCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	return sqlDB.PingContext(healthCtx) == nil
}

func (s *Server) checkRedis(ctx context.Context) bool {
	healthCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	return s.Idempotency.Ping(healthCtx) == nil
}

func (s *Server) checkRabbitMQ() bool {
	conn, err := amqp.DialConfig(s.Config.RabbitMQURL, amqp.Config{
		Heartbeat: 5 * time.Second,
		Locale:    "en_US",
		Dial:      amqp.DefaultDial(2 * time.Second),
	})
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

func (s *Server) checkS3(ctx context.Context) bool {
	healthCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	return s.S3.CheckBucket(healthCtx) == nil
}
