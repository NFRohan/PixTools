package main

import (
	"context"
	"fmt"
	"log"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"github.com/NFRohan/PixTools/go-api/internal/config"
	"github.com/NFRohan/PixTools/go-api/internal/handlers"
	"github.com/NFRohan/PixTools/go-api/internal/models"
	"github.com/NFRohan/PixTools/go-api/internal/services"
	"github.com/NFRohan/PixTools/go-api/internal/telemetry"
)

func main() {
	// 1. Load config
	cfg, err := config.LoadConfig()
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// 2. Connect to Database (GORM)
	db, err := gorm.Open(postgres.Open(cfg.DatabaseURL), &gorm.Config{})
	if err != nil {
		log.Fatalf("Failed to connect to postgres: %v", err)
	}

	// GORM AutoMigrate (takes over from Python's Alembic)
	log.Println("Running database migrations...")
	if err := db.AutoMigrate(&models.Job{}); err != nil {
		log.Fatalf("Failed to explicitly run automigrate: %v", err)
	}

	// 3. Connect to Redis
	idemSvc, err := services.NewIdempotencyService(cfg.RedisURL)
	if err != nil {
		log.Fatalf("Failed to connect to redis: %v", err)
	}

	// 4. Connect to RabbitMQ (Celery)
	celerySvc, err := services.NewCeleryService(cfg.RabbitMQURL)
	if err != nil {
		log.Fatalf("Failed to start celery client: %v", err)
	}

	// 5. Connect to S3
	s3Svc, err := services.NewS3Service(
		context.Background(),
		cfg.AWSRegion,
		cfg.S3EndpointURL,
		cfg.AWSAccessKeyID,
		cfg.AWSSecretAccessKey,
		cfg.S3BucketName,
	)
	if err != nil {
		log.Fatalf("Failed to configure S3 client: %v", err)
	}

	// 6. Initialize OpenTelemetry
	tracerProvider, err := telemetry.InitTracer(context.Background(), cfg)
	if err != nil {
		log.Printf("Warning: Failed to initialize OpenTelemetry: %v", err)
	} else if tracerProvider != nil {
		log.Println("OpenTelemetry enabled and configured")
		defer func() {
			if err := tracerProvider.Shutdown(context.Background()); err != nil {
				log.Printf("Error shutting down tracer provider: %v", err)
			}
		}()
	}

	// 7. Tie it all together with explicit injection
	server := handlers.NewServer(cfg, db, celerySvc, s3Svc, idemSvc)

	// 8. Start listening
	port := "8000"
	log.Printf("Starting Go API on :%s", port)
	if err := server.Router.Run(fmt.Sprintf(":%s", port)); err != nil {
		log.Fatalf("Server exited with error: %v", err)
	}
}
