package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/NFRohan/PixTools/go-api/internal/models"
)

// CreateJob handles the POST /api/process endpoint
func (s *Server) CreateJob(c *gin.Context) {
	// Parse multipart form (handled by the binding)
	var req models.JobRequest
	if err := c.ShouldBind(&req); err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"detail": fmt.Sprintf("invalid form data: %v", err)})
		return
	}

	// 1. Validate File Size
	if req.File.Size > s.Config.MaxUploadBytes {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"detail": fmt.Sprintf("File exceeds %dMB limit", s.Config.MaxUploadBytes/(1024*1024))})
		return
	}

	// 2. Validate Mime Type
	contentType := req.File.Header.Get("Content-Type")
	validMime := false
	for _, mime := range s.Config.AcceptedMimeTypes {
		if contentType == mime {
			validMime = true
			break
		}
	}
	if !validMime {
		c.JSON(http.StatusBadRequest, gin.H{"detail": fmt.Sprintf("Unsupported file type: %s. Accepted: %v", contentType, s.Config.AcceptedMimeTypes)})
		return
	}

	// 3. Parse Operations JSON
	var ops []string
	if err := json.Unmarshal([]byte(req.Operations), &ops); err != nil || len(ops) == 0 {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"detail": "Invalid or empty operations array"})
		return
	}

	// 4. Parse Operation Params JSON (Optional)
	var opParams map[string]interface{}
	if req.OperationParams != "" {
		if err := json.Unmarshal([]byte(req.OperationParams), &opParams); err != nil {
			c.JSON(http.StatusUnprocessableEntity, gin.H{"detail": fmt.Sprintf("Invalid operation_params JSON: %v", err)})
			return
		}
	} else {
		opParams = make(map[string]interface{})
	}

	// 5. Check Idempotency Cache
	if req.IdempotencyKey != "" {
		existingJobID, err := s.Idempotency.CheckIdempotency(c.Request.Context(), req.IdempotencyKey)
		if err != nil {
			// Log error but continue
			fmt.Printf("Idempotency read error: %v\n", err)
		} else if existingJobID != "" {
			c.JSON(http.StatusAccepted, gin.H{"job_id": existingJobID, "status": "PENDING"})
			return
		}
	}

	// 6. Synchronous S3 Upload (Do not Goroutine this!)
	file, err := req.File.Open()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "failed to open uploaded file"})
		return
	}
	defer file.Close()

	fileBytes, err := io.ReadAll(file)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "failed to read uploaded file"})
		return
	}

	jobID := uuid.New()

	// Blocking network call to AWS
	s3RawKey, err := s.S3.UploadRaw(c.Request.Context(), fileBytes, req.File.Filename, jobID.String())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "failed to upload to storage layer"})
		return
	}

	// 7. Write to Postgres
	job := models.Job{
		ID:               jobID,
		Status:           models.StatusPending,
		Operations:       ops,
		S3RawKey:         s3RawKey,
		OriginalFilename: req.File.Filename,
		WebhookURL:       req.WebhookURL,
	}

	if err := s.DB.Create(&job).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "failed to write job to database"})
		return
	}

	// 8. Write to Idempotency Cache
	if req.IdempotencyKey != "" {
		// Fire and forget cache write
		go func() {
			_ = s.Idempotency.SetIdempotency(context.Background(), req.IdempotencyKey, jobID.String())
		}()
	}

	// 9. Dispatch to Celery RabbitMQ Pipeline Router
	requestID := c.GetHeader("X-Request-ID")
	enqueuedAt := time.Now()

	// Does it need metadata extraction?
	metadataRequested := false
	var pipelineOps []string
	for _, op := range ops {
		if op == string(models.OpMetadata) {
			metadataRequested = true
		} else {
			pipelineOps = append(pipelineOps, op)
		}
	}

	if len(pipelineOps) > 0 {
		err = s.Celery.SubmitDAGRouterTask(jobID.String(), s3RawKey, pipelineOps, opParams, requestID, enqueuedAt)
		if err != nil {
			// Job created in DB, but failed to enqueue. Let background sweep recover it or return error
			fmt.Printf("failed to publish DAG router: %v\n", err)
		}
	}

	if metadataRequested {
		err = s.Celery.SubmitMetadataTask(jobID.String(), s3RawKey, len(pipelineOps) == 0)
		if err != nil {
			fmt.Printf("failed to publish metadata task: %v\n", err)
		}
	}

	c.JSON(http.StatusAccepted, gin.H{"job_id": jobID.String(), "status": "PENDING"})
}

// GetJob handles the GET /api/jobs/:id endpoint
func (s *Server) GetJob(c *gin.Context) {
	idParam := c.Param("id")
	jobID, err := uuid.Parse(idParam)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"detail": "invalid job ID format"})
		return
	}

	var job models.Job
	if err := s.DB.First(&job, "id = ?", jobID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": fmt.Sprintf("Job %s not found", idParam)})
		return
	}

	// Check if we need to regenerate presigned URLs (since they expire)
	resultURLs := make(map[string]interface{})
	for k, v := range job.ResultURLs {
		resultURLs[k] = v
	}

	var archiveURLStr *string

	if (job.Status == models.StatusCompleted || job.Status == models.StatusCompletedWebhookError) && len(job.ResultKeys) > 0 {
		freshURLs := make(map[string]interface{})
		originalBase := "image"
		parts := strings.Split(job.OriginalFilename, ".")
		if len(parts) > 1 {
			originalBase = strings.Join(parts[:len(parts)-1], ".")
		} else if len(parts) == 1 {
			originalBase = parts[0]
		}

		ctx := c.Request.Context()
		for op, s3Key := range job.ResultKeys {
			keyParts := strings.Split(s3Key, ".")
			ext := keyParts[len(keyParts)-1]
			dlName := fmt.Sprintf("pixtools_%s_%s.%s", op, originalBase, ext)

			if url, err := s.S3.GeneratePresignedURL(ctx, s3Key, dlName); err == nil {
				freshURLs[op] = url
			}
		}
		resultURLs = freshURLs

		// Check for bundle zip
		archiveKey := s.S3.GetArchiveKey(job.ID.String())
		if s.S3.ObjectExists(ctx, archiveKey) {
			archiveName := fmt.Sprintf("pixtools_bundle_%s.zip", originalBase)
			if url, err := s.S3.GeneratePresignedURL(ctx, archiveKey, archiveName); err == nil {
				archiveURLStr = &url
			}
		}
	}

	createdAtIso := ""
	if !job.CreatedAt.IsZero() {
		createdAtIso = job.CreatedAt.UTC().Format(time.RFC3339)
	}

	// Build the response explicitly mapping DB fields to JSON
	metadata := job.ExifMetadata
	if metadata == nil {
		metadata = make(models.JSONMap)
	}

	c.JSON(http.StatusOK, gin.H{
		"job_id":        job.ID.String(),
		"status":        job.Status,
		"operations":    job.Operations,
		"result_urls":   resultURLs,
		"archive_url":   archiveURLStr,
		"metadata":      metadata,
		"error_message": job.ErrorMessage,
		"created_at":    createdAtIso,
	})
}
