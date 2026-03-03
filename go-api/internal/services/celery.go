package services

import (
	"fmt"
	"time"

	"github.com/gocelery/gocelery"
	"github.com/gomodule/redigo/redis"
)

type CeleryService struct {
	client *gocelery.CeleryClient
}

// NewCeleryService creates a Celery client that publishes to our RabbitMQ instance
func NewCeleryService(rabbitmqURL, redisURL string) (*CeleryService, error) {
	// 1. Initialize Redis Backend (Celery store results in Redis)
	redisPool := &redis.Pool{
		MaxIdle:     3,
		IdleTimeout: 240 * time.Second,
		Dial: func() (redis.Conn, error) {
			return redis.DialURL(redisURL)
		},
	}
	celeryBackend := gocelery.NewRedisBackend(redisPool)

	// 2. Initialize AMQP Broker with custom exchange settings to match Python
	// Python Celery uses Exchange("default", type="direct", auto_delete=False)
	celeryBroker := gocelery.NewAMQPCeleryBroker(rabbitmqURL)

	// Manually configure exchange and queue to avoid the PRECONDITION_FAILED (406) error
	// gocelery defaults auto_delete to true, which conflicts with Celery's default of false.
	celeryBroker.Exchange = &gocelery.AMQPExchange{
		Name:       "default",
		Type:       "direct",
		Durable:    true,
		AutoDelete: false, // Match Python!
	}
	celeryBroker.Queue = &gocelery.AMQPQueue{
		Name:       "default", // This is the routing key/queue name used by default for task emission
		Durable:    true,
		AutoDelete: false,
	}

	client, err := gocelery.NewCeleryClient(celeryBroker, celeryBackend, 1)
	if err != nil {
		return nil, fmt.Errorf("failed to init celery client: %w", err)
	}

	return &CeleryService{client: client}, nil
}

// SubmitDAGRouterTask sends the orchestration message to the Python router task
// Using the exact import path required by Python's `@app.task`
func (s *CeleryService) SubmitDAGRouterTask(jobID, s3RawKey string, operations []string, operationParams map[string]interface{}, requestID string, enqueuedAt time.Time) error {
	// Our python function:
	// @app.task(name="app.tasks.router.start_pipeline")
	// def start_pipeline(job_id: str, s3_raw_key: str, operations: list[str], params: dict)

	taskName := "app.tasks.router.start_pipeline"

	// Convert kwargs properly
	kwargs := map[string]interface{}{
		"job_id":           jobID,
		"s3_raw_key":       s3RawKey,
		"operations":       operations,
		"operation_params": operationParams,
	}

	// Because gocelery.Delay doesn't natively support setting specific AMQP headers (like X-Request-ID)
	// easily, we'll pass standard kwargs and let Python handle it. If we absolutely need headers,
	// we will construct the backend message manually in the future.
	_, err := s.client.DelayKwargs(taskName, kwargs)
	if err != nil {
		return fmt.Errorf("failed to publish celery task: %w", err)
	}

	return nil
}

// SubmitMetadataTask submits the standalone metadata extraction task directly
func (s *CeleryService) SubmitMetadataTask(jobID, s3RawKey string, markCompleted bool) error {
	taskName := "app.tasks.metadata.extract_metadata"

	kwargs := map[string]interface{}{
		"job_id":         jobID,
		"s3_raw_key":     s3RawKey,
		"mark_completed": markCompleted,
	}

	_, err := s.client.DelayKwargs(taskName, kwargs)
	if err != nil {
		return fmt.Errorf("failed to publish metadata celery task: %w", err)
	}

	return nil
}
