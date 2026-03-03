package config

import (
	"os"
	"strconv"
	"strings"

	"github.com/joho/godotenv"
)

type Config struct {
	Environment          string
	DatabaseURL          string
	RedisURL             string
	RabbitMQURL          string
	RabbitMQUser         string
	RabbitMQPass         string
	AWSDefaultRegion     string
	AWSRegion            string
	S3BucketName         string
	S3EndpointURL        string
	AWSAccessKeyID       string
	AWSSecretAccessKey   string
	MaxUploadBytes       int64
	AcceptedMimeTypes    []string
	ObservabilityEnabled bool
	OtelEndpoint         string
	OtelServiceName      string
}

func LoadConfig() (*Config, error) {
	_ = godotenv.Load() // Ignore error, env might be set by Docker/K8s

	maxUploadStr := getEnvOrDefault("MAX_UPLOAD_BYTES", "52428800") // 50MB default
	maxUpload, err := strconv.ParseInt(maxUploadStr, 10, 64)
	if err != nil {
		maxUpload = 52428800
	}

	mimeTypesStr := getEnvOrDefault("ACCEPTED_MIME_TYPES", "image/jpeg,image/png,image/webp,image/avif")
	mimeTypes := strings.Split(mimeTypesStr, ",")

	obsEnabledStr := strings.ToLower(getEnvOrDefault("OBSERVABILITY_ENABLED", "false"))
	obsEnabled := obsEnabledStr == "true" || obsEnabledStr == "1"

	return &Config{
		Environment:          getEnvOrDefault("ENVIRONMENT", "local"),
		DatabaseURL:          getEnvOrDefault("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/pixtools"),
		RedisURL:             getEnvOrDefault("REDIS_URL", "redis://localhost:6379/0"),
		RabbitMQURL:          getEnvOrDefault("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/"),
		RabbitMQUser:         getEnvOrDefault("RABBITMQ_DEFAULT_USER", "guest"),
		RabbitMQPass:         getEnvOrDefault("RABBITMQ_DEFAULT_PASS", "guest"),
		AWSDefaultRegion:     getEnvOrDefault("AWS_DEFAULT_REGION", "us-east-1"),
		AWSRegion:            getEnvOrDefault("AWS_REGION", "us-east-1"),
		S3BucketName:         getEnvOrDefault("S3_BUCKET_NAME", "pixtools-local-bucket"),
		S3EndpointURL:        os.Getenv("S3_ENDPOINT_URL"), // Empty is fine for real AWS
		AWSAccessKeyID:       getEnvOrDefault("AWS_ACCESS_KEY_ID", "test"),
		AWSSecretAccessKey:   getEnvOrDefault("AWS_SECRET_ACCESS_KEY", "test"),
		MaxUploadBytes:       maxUpload,
		AcceptedMimeTypes:    mimeTypes,
		ObservabilityEnabled: obsEnabled,
		OtelEndpoint:         getEnvOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
		OtelServiceName:      getEnvOrDefault("OTEL_SERVICE_NAME_API", "pixtools-api"),
	}, nil
}

func getEnvOrDefault(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}
