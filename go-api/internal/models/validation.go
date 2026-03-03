package models

import (
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
)

// JobRequest represents the multipart form payload for POST /api/process.
type JobRequest struct {
	File            *multipart.FileHeader `form:"file" binding:"required"`
	Operations      string                `form:"operations" binding:"required"`
	IdempotencyKey  string                `header:"Idempotency-Key"`
	OperationParams string                `form:"operation_params"`
	WebhookURL      string                `form:"webhook_url"`
}

// ParamsResize maps to resize settings for a single operation.
type ParamsResize struct {
	Width  *int `json:"width"`
	Height *int `json:"height"`
}

// ParamsOp maps to settings for a single operation.
type ParamsOp struct {
	Quality *int          `json:"quality"`
	Resize  *ParamsResize `json:"resize"`
}

// OperationType is equivalent to the Python enum.
type OperationType string

const (
	OpJpg      OperationType = "jpg"
	OpPng      OperationType = "png"
	OpWebp     OperationType = "webp"
	OpAvif     OperationType = "avif"
	OpDenoise  OperationType = "denoise"
	OpMetadata OperationType = "metadata"
)

var extToFormat = map[string]OperationType{
	"jpg":  OpJpg,
	"jpeg": OpJpg,
	"png":  OpPng,
	"webp": OpWebp,
	"avif": OpAvif,
}

var qualitySupportedOps = map[OperationType]struct{}{
	OpJpg:  {},
	OpWebp: {},
}

var resizeSupportedOps = map[OperationType]struct{}{
	OpJpg:     {},
	OpPng:     {},
	OpWebp:    {},
	OpAvif:    {},
	OpDenoise: {},
}

func (o OperationType) IsValid() bool {
	switch o {
	case OpJpg, OpPng, OpWebp, OpAvif, OpDenoise, OpMetadata:
		return true
	default:
		return false
	}
}

func ParseOperations(raw string) ([]OperationType, error) {
	var values []string
	if err := json.Unmarshal([]byte(raw), &values); err != nil {
		return nil, fmt.Errorf("invalid operations: %w", err)
	}
	if len(values) == 0 {
		return nil, fmt.Errorf("at least one operation is required")
	}

	ops := make([]OperationType, 0, len(values))
	for _, value := range values {
		op := OperationType(value)
		if !op.IsValid() {
			return nil, fmt.Errorf("invalid operation: %s", value)
		}
		ops = append(ops, op)
	}
	return ops, nil
}

func ValidateWebhookURL(raw string) (string, error) {
	if raw == "" {
		return "", nil
	}

	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("webhook_url must be a valid http(s) URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("webhook_url must be a valid http(s) URL")
	}
	return raw, nil
}

func ValidateSourceTargetFormats(filename string, ops []OperationType) error {
	ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(filename)), ".")
	if ext == "" {
		return nil
	}

	sourceFormat, ok := extToFormat[ext]
	if !ok {
		return nil
	}

	for _, op := range ops {
		if op == OpDenoise || op == OpMetadata {
			continue
		}
		if op == sourceFormat {
			return fmt.Errorf(
				"cannot convert %s to %s - source and target formats are the same",
				ext,
				op,
			)
		}
	}

	return nil
}

func ParseOperationParams(raw string, ops []OperationType) (map[string]map[string]interface{}, error) {
	if raw == "" {
		return map[string]map[string]interface{}{}, nil
	}

	var parsed map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return nil, fmt.Errorf("invalid operation_params JSON: %w", err)
	}

	allowed := make(map[string]struct{}, len(ops))
	for _, op := range ops {
		allowed[string(op)] = struct{}{}
	}

	normalized := make(map[string]map[string]interface{})
	for opName, rawParams := range parsed {
		if _, ok := allowed[opName]; !ok {
			continue
		}

		var fields map[string]json.RawMessage
		if err := json.Unmarshal(rawParams, &fields); err != nil {
			return nil, fmt.Errorf("operation_params['%s'] must be an object", opName)
		}

		op := OperationType(opName)
		out := make(map[string]interface{})

		if qualityRaw, ok := fields["quality"]; ok {
			if _, supported := qualitySupportedOps[op]; !supported {
				return nil, fmt.Errorf(
					"operation_params['%s'].quality is only supported for jpg/webp",
					opName,
				)
			}

			quality, err := decodeFlexibleInt(qualityRaw)
			if err != nil {
				return nil, fmt.Errorf(
					"operation_params['%s'].quality must be an integer",
					opName,
				)
			}
			if quality < 1 || quality > 100 {
				return nil, fmt.Errorf(
					"operation_params['%s'].quality must be 1..100",
					opName,
				)
			}
			out["quality"] = quality
		}

		if resizeRaw, ok := fields["resize"]; ok {
			if _, supported := resizeSupportedOps[op]; !supported {
				return nil, fmt.Errorf(
					"operation_params['%s'].resize is only supported for jpg/png/webp/avif/denoise",
					opName,
				)
			}

			var resizeFields map[string]json.RawMessage
			if err := json.Unmarshal(resizeRaw, &resizeFields); err != nil {
				return nil, fmt.Errorf(
					"operation_params['%s'].resize must be an object",
					opName,
				)
			}

			resizeOut := make(map[string]int)
			if widthRaw, ok := resizeFields["width"]; ok {
				width, err := decodeFlexibleInt(widthRaw)
				if err != nil {
					return nil, fmt.Errorf(
						"operation_params['%s'].resize.width must be an integer",
						opName,
					)
				}
				if width <= 0 {
					return nil, fmt.Errorf(
						"operation_params['%s'].resize.width must be > 0",
						opName,
					)
				}
				resizeOut["width"] = width
			}

			if heightRaw, ok := resizeFields["height"]; ok {
				height, err := decodeFlexibleInt(heightRaw)
				if err != nil {
					return nil, fmt.Errorf(
						"operation_params['%s'].resize.height must be an integer",
						opName,
					)
				}
				if height <= 0 {
					return nil, fmt.Errorf(
						"operation_params['%s'].resize.height must be > 0",
						opName,
					)
				}
				resizeOut["height"] = height
			}

			if len(resizeOut) == 0 {
				return nil, fmt.Errorf(
					"operation_params['%s'].resize requires width or height",
					opName,
				)
			}
			out["resize"] = resizeOut
		}

		if len(out) > 0 {
			normalized[opName] = out
		}
	}

	return normalized, nil
}

func decodeFlexibleInt(raw json.RawMessage) (int, error) {
	var intValue int
	if err := json.Unmarshal(raw, &intValue); err == nil {
		return intValue, nil
	}

	var stringValue string
	if err := json.Unmarshal(raw, &stringValue); err == nil {
		parsed, parseErr := strconv.Atoi(stringValue)
		if parseErr != nil {
			return 0, parseErr
		}
		return parsed, nil
	}

	var floatValue float64
	if err := json.Unmarshal(raw, &floatValue); err == nil {
		intCast := int(floatValue)
		if float64(intCast) != floatValue {
			return 0, fmt.Errorf("not an integer")
		}
		return intCast, nil
	}

	return 0, fmt.Errorf("unsupported integer encoding")
}
