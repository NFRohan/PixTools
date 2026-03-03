package models

import (
	"database/sql/driver"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// JobStatus matches the Python enum
type JobStatus string

const (
	StatusPending               JobStatus = "PENDING"
	StatusProcessing            JobStatus = "PROCESSING"
	StatusCompleted             JobStatus = "COMPLETED"
	StatusFailed                JobStatus = "FAILED"
	StatusCompletedWebhookError JobStatus = "COMPLETED_WEBHOOK_FAILED"
)

// StringArray is a custom type to handle PostgreSQL string arrays properly in GORM
type StringArray []string

func (a *StringArray) Scan(value interface{}) error {
	bytes, ok := value.([]byte)
	if !ok {
		return nil
	}
	return json.Unmarshal(bytes, a)
}

func (a StringArray) Value() (driver.Value, error) {
	if a == nil {
		return nil, nil
	}
	return json.Marshal(a)
}

// JSONMap is a custom type to handle JSONB columns
type JSONMap map[string]interface{}

func (m *JSONMap) Scan(value interface{}) error {
	bytes, ok := value.([]byte)
	if !ok {
		return nil
	}
	return json.Unmarshal(bytes, m)
}

func (m JSONMap) Value() (driver.Value, error) {
	if m == nil {
		return nil, nil
	}
	return json.Marshal(m)
}

// ResultKeys is a custom type specifically for string->string maps in JSONB
type ResultKeys map[string]string

func (m *ResultKeys) Scan(value interface{}) error {
	bytes, ok := value.([]byte)
	if !ok {
		return nil
	}
	return json.Unmarshal(bytes, m)
}

func (m ResultKeys) Value() (driver.Value, error) {
	if m == nil {
		return nil, nil
	}
	return json.Marshal(m)
}

// Job represents the database schema for the jobs table
type Job struct {
	ID               uuid.UUID   `gorm:"type:uuid;primaryKey"`
	Status           JobStatus   `gorm:"type:varchar;not null"`
	Operations       StringArray `gorm:"type:jsonb;not null"` // Using JSONB for the array is safer across dialects
	S3RawKey         string      `gorm:"type:varchar;not null"`
	OriginalFilename string      `gorm:"type:varchar"`
	WebhookURL       string      `gorm:"type:varchar"`
	ResultKeys       ResultKeys  `gorm:"type:jsonb"`
	ResultURLs       JSONMap     `gorm:"type:jsonb"` // TTL urls, optional
	ExifMetadata     JSONMap     `gorm:"type:jsonb"`
	ErrorMessage     string      `gorm:"type:varchar"`

	CreatedAt time.Time      `gorm:"autoCreateTime"`
	UpdatedAt time.Time      `gorm:"autoUpdateTime"`
	DeletedAt gorm.DeletedAt `gorm:"index"`
}
