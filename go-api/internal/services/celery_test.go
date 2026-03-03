package services

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestBuildPublishSpecsPipelineAndMetadata(t *testing.T) {
	enqueuedAt := time.Unix(1739990400, 123456000).UTC()

	specs := buildPublishSpecs(
		"job-123",
		"raw/job-123/input.png",
		[]string{"webp", "avif"},
		map[string]interface{}{
			"webp": map[string]interface{}{"quality": 80},
		},
		true,
		"req-123",
		enqueuedAt,
	)

	if len(specs) != 2 {
		t.Fatalf("expected 2 publish specs, got %d", len(specs))
	}

	router := specs[0]
	if router.taskName != "app.tasks.router.start_pipeline" {
		t.Fatalf("expected router task, got %q", router.taskName)
	}
	if router.kwargs["job_id"] != "job-123" {
		t.Fatalf("expected router job_id to be preserved")
	}
	if router.kwargs["s3_raw_key"] != "raw/job-123/input.png" {
		t.Fatalf("expected router s3_raw_key to be preserved")
	}
	if router.kwargs["request_id"] != "req-123" {
		t.Fatalf("expected router request_id to be preserved")
	}
	if router.kwargs["enqueued_at"] != "1739990400.123456" {
		t.Fatalf("unexpected router enqueued_at: %v", router.kwargs["enqueued_at"])
	}

	ops, ok := router.kwargs["operations"].([]string)
	if !ok {
		t.Fatalf("expected operations to be []string, got %T", router.kwargs["operations"])
	}
	if len(ops) != 2 || ops[0] != "webp" || ops[1] != "avif" {
		t.Fatalf("unexpected operations payload: %#v", ops)
	}

	params, ok := router.kwargs["operation_params"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected operation_params to be map[string]interface{}, got %T", router.kwargs["operation_params"])
	}
	if _, ok := params["webp"]; !ok {
		t.Fatalf("expected webp params to be present")
	}

	metadata := specs[1]
	if metadata.taskName != "app.tasks.metadata.extract_metadata" {
		t.Fatalf("expected metadata task, got %q", metadata.taskName)
	}
	if metadata.kwargs["mark_completed"] != false {
		t.Fatalf("expected metadata mark_completed=false when pipeline ops exist")
	}
	if metadata.kwargs["enqueued_at"] != "1739990400.123456" {
		t.Fatalf("unexpected metadata enqueued_at: %v", metadata.kwargs["enqueued_at"])
	}
}

func TestBuildPublishSpecsMetadataOnlyMarksCompleted(t *testing.T) {
	specs := buildPublishSpecs(
		"job-456",
		"raw/job-456/input.png",
		nil,
		nil,
		true,
		"req-456",
		time.Unix(1740000000, 0).UTC(),
	)

	if len(specs) != 1 {
		t.Fatalf("expected 1 publish spec for metadata-only request, got %d", len(specs))
	}
	if specs[0].taskName != "app.tasks.metadata.extract_metadata" {
		t.Fatalf("expected metadata task, got %q", specs[0].taskName)
	}
	if specs[0].kwargs["mark_completed"] != true {
		t.Fatalf("expected metadata-only job to mark completed")
	}
}

func TestNewCeleryTaskMessageBuildsSerializableEnvelope(t *testing.T) {
	message := newCeleryTaskMessage(publishSpec{
		taskName: "app.tasks.router.start_pipeline",
		kwargs: map[string]interface{}{
			"job_id":      "job-789",
			"request_id":  "req-789",
			"enqueued_at": "1740000000.000000",
		},
	})

	if message.Task != "app.tasks.router.start_pipeline" {
		t.Fatalf("unexpected task name: %q", message.Task)
	}
	if len(message.Args) != 0 {
		t.Fatalf("expected empty args slice, got %#v", message.Args)
	}
	if message.Retries != 0 {
		t.Fatalf("expected retries=0, got %d", message.Retries)
	}
	if message.Kwargs["job_id"] != "job-789" {
		t.Fatalf("expected job_id to be preserved")
	}
	if _, err := uuid.Parse(message.ID); err != nil {
		t.Fatalf("expected valid UUID message id, got %q: %v", message.ID, err)
	}
}
