# PixTools Benchmark Playbook

This folder turns PixTools from a demo into a measured system.

## Goal

Produce defensible metrics in 7-10 days:
- sustained jobs/min
- API p95 latency under load
- retry/idempotency behavior under storm
- worker crash recovery time
- queue starvation impact before vs after ML queue isolation

## Prerequisites

- Deployed PixTools endpoint (or local stack):
  - `BASE_URL=http://...` where `/api/process`, `/api/jobs/{id}`, `/metrics` exist
- **API key**: set `PIXTOOLS_API_KEY` env var or pass `-ApiKey` to `run-k6.ps1`
- k6 installed locally
- Grafana Cloud receiving metrics/logs
- A `test_image.png` file in the repo root (used by k6 as the upload payload)

## Custom Metrics Added

These are emitted by the app/workers and can be queried in Grafana:

- `pixtools_api_request_latency_seconds` (Histogram)
- `pixtools_rabbitmq_queue_depth` (Gauge by queue)
- `pixtools_rabbitmq_queue_consumers` (Gauge by queue)
- `pixtools_worker_task_processing_seconds` (Histogram by task)
- `pixtools_job_queue_wait_seconds` (Histogram by task)
- `pixtools_job_end_to_end_seconds` (Histogram)
- `pixtools_job_status_total` (Counter by final status)
- `pixtools_task_retry_total` (Counter by task)
- `pixtools_task_failure_total` (Counter by task)
- `pixtools_webhook_circuit_transition_total` (Counter)
- `pixtools_webhook_delivery_total` (Counter)

## Load Scenarios

## 1. Baseline

Target: steady throughput and stable queue depth.

```powershell
.\bench\run-k6.ps1 -Scenario baseline -BaseUrl "http://<ALB_DNS>" -ApiKey "<key>" -ExtraEnv @("VUS=30", "DURATION=5m")
```

Optional completion polling:

```powershell
.\bench\run-k6.ps1 -Scenario baseline -BaseUrl "http://<ALB_DNS>" -ApiKey "<key>" -ExtraEnv @("VUS=20", "DURATION=5m", "POLL_COMPLETION=true")
```

## 2. High Concurrency Spike

Target: observe latency and queue buildup at high fan-in.

```powershell
.\bench\run-k6.ps1 -Scenario spike -BaseUrl "http://<ALB_DNS>" -ApiKey "<key>" -ExtraEnv @("VUS=200", "DURATION=2m")
```

## 3. Retry Storm

Target: verify idempotency under client retry pressure.

```powershell
.\bench\run-k6.ps1 -Scenario retry_storm -BaseUrl "http://<ALB_DNS>" -ApiKey "<key>" -ExtraEnv @("VUS=100", "DURATION=3m", "MAX_CLIENT_ATTEMPTS=3", "REQUEST_TIMEOUT=2s")
```

Primary counters:
- `client_retries_total`
- `duplicate_processing_signals_total`
- server-side `pixtools_task_retry_total`

## 4. Queue Starvation Mix

Target: quantify impact of heavy denoise jobs on lightweight conversions.

```powershell
.\bench\run-k6.ps1 -Scenario starvation_mix -BaseUrl "http://<ALB_DNS>" -ApiKey "<key>" -ExtraEnv @("HEAVY_RPS=5", "LIGHT_RPS=2", "DURATION=4m")
```

Run twice:
- with `ML_QUEUE_ISOLATION_ENABLED=false` (temporary test config)
- with `ML_QUEUE_ISOLATION_ENABLED=true` (current design)

Compare lightweight latency:
- `http_req_duration{workload="light"} p95`
- `pixtools_job_queue_wait_seconds{task_name="app.tasks.image_ops.convert_webp"}`

## Automated Server-Side Metric Collection

After each k6 run, collect backend metrics directly from Grafana Cloud Prometheus:

```powershell
$env:GRAFANA_PROMETHEUS_URL = "https://prometheus-<stack>.grafana.net"
$env:GRAFANA_PROMETHEUS_USER = "<metrics_instance_id>"
$env:GRAFANA_PROMETHEUS_API_KEY = "<grafana_api_key_with_metrics:read>"

.\bench\collect-grafana-metrics.ps1 `
  -Scenario baseline `
  -Environment dev `
  -BaseUrl "http://<ALB_DNS>" `
  -CommitSha "<git_sha>" `
  -WindowMinutes 10 `
  -WriteMarkdownReport
```

Outputs:
- `bench/results/<scenario>-server-metrics.json` (Prometheus-derived metrics + PromQL used)
- `bench/results/<scenario>-auto-report.md` (quick report draft if `-WriteMarkdownReport` set)

## Grafana Query Starter Set

Use the same time window as each test.

API p95 latency:

```promql
histogram_quantile(
  0.95,
  sum(rate(pixtools_api_request_latency_seconds_bucket[5m])) by (le)
)
```

Throughput (accepted jobs/sec):

```promql
rate(pixtools_job_status_total[5m])
```

Queue depth:

```promql
max_over_time(pixtools_rabbitmq_queue_depth[5m])
```

Worker processing p95:

```promql
histogram_quantile(
  0.95,
  sum(rate(pixtools_worker_task_processing_seconds_bucket[5m])) by (le, task_name)
)
```

Queue wait p95:

```promql
histogram_quantile(
  0.95,
  sum(rate(pixtools_job_queue_wait_seconds_bucket[5m])) by (le, task_name)
)
```

## 7-10 Day Execution Plan

Day 1-2:
- verify `/metrics` scrape and log fields
- dry-run baseline (`VUS=10`)

Day 3-4:
- baseline + spike runs
- record p50/p95, queue depth, CPU/memory snapshots

Day 5-6:
- retry storm
- chaos tests: kill worker during load, Redis interruption test

Day 7:
- queue starvation A/B (isolation off/on)
- compute latency reduction

Day 8-10:
- sanitize charts
- publish README benchmark section and resume bullets with measured values

## Data Capture Guidance

For each run, archive:
- k6 summary JSON from `bench/results/`
- Grafana screenshots (latency, queue depth, retries)
- one markdown note (start from `bench/templates/benchmark-report-template.md`) containing:
  - test parameters
  - timestamp window
  - 5 key metrics
  - pass/fail observations
