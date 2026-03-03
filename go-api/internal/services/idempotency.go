package services

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

type IdempotencyService struct {
	client *redis.Client
}

// NewIdempotencyService initializes a Redis client connection
func NewIdempotencyService(redisURL string) (*IdempotencyService, error) {
	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse redis URL: %w", err)
	}

	client := redis.NewClient(opts)
	// Ping to ensure connection is valid
	if err := client.Ping(context.Background()).Err(); err != nil {
		return nil, fmt.Errorf("failed to connect to redis: %w", err)
	}

	return &IdempotencyService{client: client}, nil
}

// CheckIdempotency checks if a key exists in Redis. Returns the JobID if found, empty string otherwise.
func (s *IdempotencyService) CheckIdempotency(ctx context.Context, key string) (string, error) {
	redisKey := fmt.Sprintf("idempotency:%s", key)
	val, err := s.client.Get(ctx, redisKey).Result()
	if err == redis.Nil {
		return "", nil // cache miss
	} else if err != nil {
		return "", fmt.Errorf("redis get failed: %w", err)
	}
	return val, nil // cache hit
}

// Ping verifies Redis reachability for health checks.
func (s *IdempotencyService) Ping(ctx context.Context) error {
	if err := s.client.Ping(ctx).Err(); err != nil {
		return fmt.Errorf("redis ping failed: %w", err)
	}
	return nil
}

// SetIdempotency sets a key in Redis with a 24-hour TTL
func (s *IdempotencyService) SetIdempotency(ctx context.Context, key, jobID string) error {
	redisKey := fmt.Sprintf("idempotency:%s", key)
	err := s.client.Set(ctx, redisKey, jobID, 24*time.Hour).Err()
	if err != nil {
		return fmt.Errorf("redis set failed: %w", err)
	}
	return nil
}

// DeleteIdempotency removes a key from Redis after failed job creation/enqueue.
func (s *IdempotencyService) DeleteIdempotency(ctx context.Context, key string) error {
	redisKey := fmt.Sprintf("idempotency:%s", key)
	if err := s.client.Del(ctx, redisKey).Err(); err != nil {
		return fmt.Errorf("redis delete failed: %w", err)
	}
	return nil
}
