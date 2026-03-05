# Scaling Guardrails

This document defines active scaling safety rails for autoscaling behavior, alerting signals, and benchmark gate checks.

## Scope

- API HPA stability
- KEDA-backed worker scaling stability
- cluster capacity saturation visibility
- production-suite error-shape visibility (`500` and transport-level failures)
- benchmark pass/fail gates

## Dashboard Panels

Use these panel queries in Grafana. Keep the time window aligned with the benchmark run window.

## 1. Worker Saturation (`pixtools-worker-standard`)

```promql
max(kube_deployment_status_replicas{namespace="pixtools",deployment="pixtools-worker-standard"})
/
max(kube_deployment_spec_replicas{namespace="pixtools",deployment="pixtools-worker-standard"})
```

Interpretation:
- `1.0` means worker pool is pinned at max desired replicas.

## 2. RabbitMQ Backlog (`default_queue`)

```promql
max_over_time(pixtools_rabbitmq_queue_depth{queue="default_queue"}[5m])
```

Interpretation:
- sustained non-dropping backlog while workers are saturated means scaling or throughput bottleneck.

## 3. Node Saturation via Pending Pods

```promql
sum(
  kube_pod_status_phase{namespace="pixtools",phase="Pending"}
)
```

Supplement with events/logs for root cause (`Insufficient cpu`, `Insufficient memory`, affinity mismatch).

## 4. Failed Node Scale-up Indicators

```promql
sum(rate(cluster_autoscaler_failed_scale_ups_total[5m]))
```

If this metric is unavailable in your scrape pipeline, use cluster-autoscaler logs and ASG activity as fallback telemetry.

## 5. API Latency p95 (In-Region Benchmark)

```promql
histogram_quantile(
  0.95,
  sum(rate(pixtools_api_request_latency_seconds_bucket[5m])) by (le)
)
```

## 6. Queue Wait p95 (Task-Level)

```promql
histogram_quantile(
  0.95,
  sum(rate(pixtools_job_queue_wait_seconds_bucket[5m])) by (le, task_name)
)
```

## 7. API Error Shape

```promql
sum(rate(pixtools_api_requests_total{status=~"5.."}[5m]))
```

Supplement this with k6 status-code histograms for transport-level `0` failures (timeouts/connection-level errors), because those do not appear as HTTP 5xx server responses.

## Alert Conditions

## A1: Worker Saturation Too Long

Trigger when:
- worker replicas are at max for `>=10m`
- and backlog is not draining

Suggested condition:
- panel 1 `== 1.0` for 10m
- panel 2 above steady-state threshold for 10m

## A2: Sustained Queue Backlog

Trigger when:
- `default_queue` backlog above `50` for `>=10m`

Tune threshold based on expected throughput and concurrency.

## A3: Pending Pods Due to Capacity

Trigger when:
- Pending pods in `pixtools` persist for `>2m`
- with scheduler events showing `Insufficient cpu` or `Insufficient memory`

## A4: Node Scale-up Failures

Trigger when:
- Cluster Autoscaler reports failed scale-up attempts
- or ASG activity repeatedly fails launch

## A5: API p95 Regression

Trigger when:
- in-region API p95 exceeds `700ms` for `>=5m` during baseline load

## A6: Overload Error Regression

Trigger when:
- 5xx rate rises above expected baseline for `>=5m`
- or transport-level failures appear in in-region benchmark output

## Benchmark Gates (Pass/Fail)

A benchmark run passes only if all gates pass:

1. Queue drain time (P95) after load stop: `<= 180s`
2. Failed job ratio (`FAILED + COMPLETED_WEBHOOK_FAILED` / terminal jobs): `<= 1.0%`
3. API p95 latency for in-region run: `<= 700ms`
4. Worker saturation at max replicas: `<= 10m` continuous
5. Pending pods from CPU/memory pressure: none sustained beyond `2m`
6. Overload error shape remains bounded:
   - no sustained transport-level failure bursts
   - 5xx rate remains within benchmark acceptance envelope

If any gate fails:
- mark the run FAIL
- execute the corresponding runbook in `docs/runbooks/`
- do not promote benchmark claims until rerun passes
