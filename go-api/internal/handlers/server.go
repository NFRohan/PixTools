package handlers

import (
	"net/http"

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

func (s *Server) apiKeyMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if s.Config.APIKey == "" {
			c.Next()
			return
		}

		key := c.GetHeader("X-API-Key")
		if key == "" {
			// Fallback to query param if needed, or keep it strict
			key = c.Query("api_key")
		}

		if key != s.Config.APIKey {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"detail": "Invalid or missing API Key"})
			return
		}
		c.Next()
	}
}

func (s *Server) setupRoutes() {
	// Public routes
	s.Router.GET("/api/health", s.HealthCheck)

	api := s.Router.Group("/api")
	if s.Config.APIKey != "" {
		api.Use(s.apiKeyMiddleware())
	}
	{
		api.POST("/process", s.CreateJob)
		api.GET("/jobs/:id", s.GetJob)
	}

	// Serve static files
	s.Router.Static("/static", "./static")

	// Root redirect/serving
	s.Router.GET("/", func(c *gin.Context) {
		c.File("./static/index.html")
	})
}
