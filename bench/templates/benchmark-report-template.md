# Benchmark Report Template

## Run Metadata

- Date (UTC):
- Environment: `dev` / `prod`
- Base URL:
- Commit SHA:
- Scenario: `baseline` / `spike` / `retry_storm` / `starvation_mix`
- Load Settings:
  - VUs / RPS:
  - Duration:
  - Poll completion: `true` / `false`
- ML queue isolation: `true` / `false`

## System Snapshot

- **Infra node**: m7i-flex.large on-demand (K3s server, RabbitMQ, Redis, Beat)
- **Workload node(s)**: m7i-flex.large spot x___ (K3s agents)
- API replicas (HPA):
- Standard worker replicas + concurrency:
- ML worker replicas + pool:
- RabbitMQ queue depths before run:

## Pass/Fail Gates

- Queue drain time after load stop (P95 target): `<= 180s`
- Failed job ratio (`FAILED + COMPLETED_WEBHOOK_FAILED` / total terminal jobs): `<= 1.0%`
- API latency p95 target (in-region): `<= 700ms`
- Worker saturation (`pixtools-worker-standard` at max replicas): `<= 10m` continuous
- Pending pods due to `Insufficient cpu|memory`: `0` sustained > `2m`

Gate result summary:

- PASS / FAIL:
- Failed gates:
- Mitigation required before next benchmark? `yes/no`

## Key Results

- Accepted jobs per minute:
- API latency p50:
- API latency p95:
- Queue wait p95 (light tasks):
- Worker processing p95 (heavy tasks):
- Retry rate:
- Failure rate:
- Duplicate processing count:
- Crash/Recovery time (if chaos run):

## PromQL Evidence

```promql
# API p95
histogram_quantile(0.95, sum(rate(pixtools_api_request_latency_seconds_bucket[5m])) by (le))
```

```promql
# Queue wait p95 by task
histogram_quantile(0.95, sum(rate(pixtools_job_queue_wait_seconds_bucket[5m])) by (le, task_name))
```

```promql
# Worker processing p95 by task
histogram_quantile(0.95, sum(rate(pixtools_worker_task_processing_seconds_bucket[5m])) by (le, task_name))
```

## Observations

- What behaved as expected:
- Bottlenecks observed:
- Unexpected failures:
- Recovery behavior:

## Comparison (for A/B or repeated runs)

- Baseline reference run:
- Current run delta:
  - Throughput delta:
  - API p95 delta:
  - Queue wait delta:

## Resume-Ready Claim Draft

- Example:
  - "Sustained ___ jobs/min at ___ concurrent clients with API p95 under ___ ms."

## Artifacts

- k6 summary JSON:
- Grafana dashboard links/screenshots:
- Relevant logs/traces:
