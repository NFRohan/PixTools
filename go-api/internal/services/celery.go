package services

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/streadway/amqp"
)

const defaultQueueName = "default_queue"
const deadLetterQueueName = "dead_letter"
const deadLetterExchangeName = "dlx"

type celeryTaskMessage struct {
	ID      string                 `json:"id"`
	Task    string                 `json:"task"`
	Args    []interface{}          `json:"args"`
	Kwargs  map[string]interface{} `json:"kwargs"`
	Retries int                    `json:"retries"`
	ETA     *string                `json:"eta"`
	Expires *time.Time             `json:"expires"`
}

type CeleryService struct {
	conn *amqp.Connection
	mu   sync.Mutex
}

type publishSpec struct {
	taskName string
	kwargs   map[string]interface{}
}

// NewCeleryService creates an AMQP publisher compatible with the Python Celery workers.
func NewCeleryService(rabbitmqURL string) (*CeleryService, error) {
	conn, err := amqp.Dial(rabbitmqURL)
	if err != nil {
		return nil, fmt.Errorf("failed to dial rabbitmq: %w", err)
	}

	return &CeleryService{conn: conn}, nil
}

// PublishJobTasks publishes the router/metadata tasks for a single API request.
func (s *CeleryService) PublishJobTasks(
	jobID,
	s3RawKey string,
	operations []string,
	operationParams map[string]interface{},
	metadataRequested bool,
	requestID string,
	enqueuedAt time.Time,
) error {
	specs := buildPublishSpecs(jobID, s3RawKey, operations, operationParams, metadataRequested, requestID, enqueuedAt)
	return s.publishBatch(defaultQueueName, specs)
}

func buildPublishSpecs(
	jobID,
	s3RawKey string,
	operations []string,
	operationParams map[string]interface{},
	metadataRequested bool,
	requestID string,
	enqueuedAt time.Time,
) []publishSpec {
	specs := make([]publishSpec, 0, 2)
	enqueueAt := formatEnqueuedAt(enqueuedAt)

	if len(operations) > 0 {
		specs = append(specs, publishSpec{
			taskName: "app.tasks.router.start_pipeline",
			kwargs: map[string]interface{}{
				"job_id":           jobID,
				"s3_raw_key":       s3RawKey,
				"operations":       operations,
				"operation_params": operationParams,
				"request_id":       requestID,
				"enqueued_at":      enqueueAt,
			},
		})
	}

	if metadataRequested {
		specs = append(specs, publishSpec{
			taskName: "app.tasks.metadata.extract_metadata",
			kwargs: map[string]interface{}{
				"job_id":         jobID,
				"s3_raw_key":     s3RawKey,
				"mark_completed": len(operations) == 0,
				"request_id":     requestID,
				"enqueued_at":    enqueueAt,
			},
		})
	}

	return specs
}

func formatEnqueuedAt(enqueuedAt time.Time) string {
	return fmt.Sprintf("%.6f", float64(enqueuedAt.UnixNano())/float64(time.Second))
}

func newCeleryTaskMessage(spec publishSpec) celeryTaskMessage {
	return celeryTaskMessage{
		ID:      uuid.NewString(),
		Task:    spec.taskName,
		Args:    []interface{}{},
		Kwargs:  spec.kwargs,
		Retries: 0,
		ETA:     nil,
		Expires: nil,
	}
}

func (s *CeleryService) publishBatch(queueName string, specs []publishSpec) error {
	if len(specs) == 0 {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	ch, err := s.conn.Channel()
	if err != nil {
		return fmt.Errorf("failed to open rabbitmq channel: %w", err)
	}
	defer ch.Close()

	if err := ch.ExchangeDeclare(
		deadLetterExchangeName,
		"direct",
		true,
		false,
		false,
		false,
		nil,
	); err != nil {
		return fmt.Errorf("failed to declare dead letter exchange: %w", err)
	}

	if _, err := ch.QueueDeclare(
		deadLetterQueueName,
		true,
		false,
		false,
		false,
		nil,
	); err != nil {
		return fmt.Errorf("failed to declare dead letter queue: %w", err)
	}

	if err := ch.QueueBind(
		deadLetterQueueName,
		deadLetterQueueName,
		deadLetterExchangeName,
		false,
		nil,
	); err != nil {
		return fmt.Errorf("failed to bind dead letter queue: %w", err)
	}

	_, err = ch.QueueDeclare(
		queueName,
		true,
		false,
		false,
		false,
		amqp.Table{
			"x-dead-letter-exchange":    deadLetterExchangeName,
			"x-dead-letter-routing-key": deadLetterQueueName,
		},
	)
	if err != nil {
		return fmt.Errorf("failed to declare queue %s: %w", queueName, err)
	}

	if err := ch.Tx(); err != nil {
		return fmt.Errorf("failed to start rabbitmq transaction: %w", err)
	}

	for _, spec := range specs {
		message := newCeleryTaskMessage(spec)

		body, err := json.Marshal(message)
		if err != nil {
			_ = ch.TxRollback()
			return fmt.Errorf("failed to marshal celery task: %w", err)
		}

		if err := ch.Publish(
			"",
			queueName,
			false,
			false,
			amqp.Publishing{
				DeliveryMode: amqp.Persistent,
				Timestamp:    time.Now().UTC(),
				ContentType:  "application/json",
				Body:         body,
			},
		); err != nil {
			_ = ch.TxRollback()
			return fmt.Errorf("failed to publish celery task to %s: %w", queueName, err)
		}
	}

	if err := ch.TxCommit(); err != nil {
		_ = ch.TxRollback()
		return fmt.Errorf("failed to commit rabbitmq publish transaction: %w", err)
	}

	return nil
}
