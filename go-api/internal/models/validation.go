package models

import "mime/multipart"

// JobRequest represents the multipart form payload for POST /api/process
type JobRequest struct {
	File            *multipart.FileHeader `form:"file" binding:"required"`
	Operations      string                `form:"operations" binding:"required"` // JSON array string e.g. ["webp", "denoise"]
	IdempotencyKey  string                `header:"Idempotency-Key"`
	OperationParams string                `form:"operation_params"` // JSON string object e.g. {"webp": {"quality": 75}}
	WebhookURL      string                `form:"webhook_url" binding:"omitempty,url,http_url"`
}

// ParamsResize maps to the specific dimensions requested
type ParamsResize struct {
	Width  *int `json:"width"`
	Height *int `json:"height"`
}

// ParamsOp maps to the specific settings for a single operation
type ParamsOp struct {
	Quality *int          `json:"quality"`
	Resize  *ParamsResize `json:"resize"`
}

// OperationType is equivalent to the Python enum
type OperationType string

const (
	OpJpg      OperationType = "jpg"
	OpPng      OperationType = "png"
	OpWebp     OperationType = "webp"
	OpAvif     OperationType = "avif"
	OpDenoise  OperationType = "denoise"
	OpMetadata OperationType = "metadata"
)
