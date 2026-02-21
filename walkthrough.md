# PixTools — Final Project Walkthrough

PixTools is a high-performance, distributed image processing pipeline with a focus on hybrid-cloud scalability and ML-powered enhancements.

## 🚀 Accomplishments

### 🎨 Neobrutalist Frontend
- **Design**: Implemented a bold, high-contrast Neobrutalist UI with custom CSS.
- **Experience**: Support for drag-and-drop uploads, real-time polling for job status, and persistent result cards with intuitive download naming.
- **Media**:
![Frontend Preview](file:///C:/Users/User/.gemini/antigravity/brain/5dd85fed-935c-483c-9f89-9a2651aa106e/ui_neobrutalism_preview_1771683949321.webp)

### 🧠 DnCNN ML Integration
- **Model**: Integrated a 20-layer `DnCNN` (Denoising Convolutional Neural Network) using CDnCNN-B weights.
- **Isolation**: Dedicated `ml_inference_queue` on a specialized worker with `concurrency=1` and `pool=solo` to prevent PyTorch deadlocks.
- **Optimization**: Restricted to 4 CPU threads for balanced performance and memory stability on CPU-only infrastructure.

### 🛡️ Production Hardening
- **Observability**: Structured JSON logging across all services using `python-json-logger`.
- **Correlation**: End-to-end tracing using `X-Request-ID` and `ContextVars`.
- **Resilience**: **Circuit Breaker** protection for webhooks (`pybreaker`) and Dead Letter Queues (DLQ) for task reliability.
- **Monitoring**: Deep health check endpoint `/api/health` validating DB, Redis, and S3 status.

## 🧪 Verification Results

### End-to-End Flow
1. **Request**: `POST /api/process` with an `X-Request-ID`.
2. **DAG**: Tasks dispatched to standard and ML workers.
3. **Execution**: Workers log progress in JSON format:
```json
{"timestamp": "2026-02-21T16:13:57Z", "level": "INFO", "name": "app.tasks.ml_ops", "message": "Inference complete", "request_id": "final-test", "job_id": "..."}
```
4. **Finalization**: `finalize_job` updates the DB and returns pre-signed URLs with user-friendly filenames.

### Health Check Output
```json
{
  "status": "healthy",
  "dependencies": {
    "database": "ok",
    "redis": "ok",
    "s3": "ok"
  }
}
```

## 🏁 Future Roadmap
- **Autoscaling**: Implement KEDA scaling based on RabbitMQ queue depth.
- **GPU Acceleration**: Deploy ML workers to GPU-equipped nodes with CUDA support.
- **Auth**: Add API key authentication for the `/api` prefix.
