package handlers

import (
	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"
	"gorm.io/gorm"

	"github.com/NFRohan/PixTools/go-api/internal/config"
	"github.com/NFRohan/PixTools/go-api/internal/services"
)

// Server holds all dependencies for API routes (Explicit Dependency Injection)
type Server struct {
	Config      *config.Config
	DB          *gorm.DB
	Celery      *services.CeleryService
	S3          *services.S3Service
	Idempotency *services.IdempotencyService
	Router      *gin.Engine
}

// NewServer initializes the struct and maps all HTTP routes
func NewServer(cfg *config.Config, db *gorm.DB, celery *services.CeleryService, s3Svc *services.S3Service, idem *services.IdempotencyService) *Server {
	router := gin.Default()

	if cfg.ObservabilityEnabled {
		// Adds OpenTelemetry middleware to all routes
		router.Use(otelgin.Middleware(cfg.OtelServiceName))
	}

	srv := &Server{
		Config:      cfg,
		DB:          db,
		Celery:      celery,
		S3:          s3Svc,
		Idempotency: idem,
		Router:      router,
	}

	srv.setupRoutes()
	return srv
}

func (s *Server) setupRoutes() {
	api := s.Router.Group("/api")
	{
		api.GET("/health", s.HealthCheck)
		api.POST("/process", s.CreateJob)
		api.GET("/jobs/:id", s.GetJob)
	}
}
