# K8s Manifests

Manifests under this directory are rendered by `scripts/deploy/render-manifests.sh`.

## Placeholder Tokens

- `__API_IMAGE__`
- `__WORKER_IMAGE__`
- `__ALLOWED_INGRESS_CIDRS__`
- `__ALB_SECURITY_GROUP_ID__`
- `__K3S_CLUSTER_NAME__`

These are replaced in CI/CD before sync to S3.

## Deployment Model

- AWS Load Balancer Controller handles ALB ingress.
- API service is `NodePort` to support ALB target type `instance`.
- Runtime secret/config (`pixtools-runtime`, `pixtools-config`, `grafana-cloud`, `rabbitmq-auth`) is reconciled from SSM by `scripts/deploy/reconcile-cluster.sh`.
- Workloads use explicit node selectors:
  - app pods: `pixtools-workload-app=true`
  - infra pods: `pixtools-workload-infra=true`
- Queue-driven worker autoscaling is managed through KEDA:
  - KEDA itself is installed by `scripts/deploy/reconcile-cluster.sh`
  - in-repo scaler specs live under `k8s/autoscaling/`
- Durable infra storage is provided through the AWS EBS CSI driver:
  - installed by `scripts/deploy/reconcile-cluster.sh`
  - in-repo storage manifests live under `k8s/storage/`
- Node autoscaling is managed by Cluster Autoscaler:
  - autodiscovers only the workload ASG via AWS tags
  - runs on the fixed infra node
  - never manages the infra/server ASG
- CD uploads rendered manifests + reconcile script to S3, then executes reconcile over SSM.

## Capacity Classes

- Infra class:
  - node label: `pixtools-workload-infra=true`
  - priority class: `pixtools-infra-critical`
  - workloads: `rabbitmq`, `redis`, `pixtools-beat`, `celery-exporter`, Cluster Autoscaler, KEDA control plane
- Standard app class:
  - node label: `pixtools-workload-app=true`
  - priority class: `pixtools-app-standard`
  - workloads: `pixtools-api`, `pixtools-worker-standard`
  - standard workers prefer to spread across app nodes and avoid co-locating with ML workers when another app node is available
- ML app class:
  - node label: `pixtools-workload-app=true`
  - priority class: `pixtools-app-ml`
  - workloads: `pixtools-worker-ml`
  - ML remains on the general app pool for now; a dedicated ML node class is deferred until real contention or cost pressure justifies the extra ASG and scheduling complexity

This means infra workloads never drift onto spot-backed app nodes, while app workloads still share the elastic pool in a controlled way.

## Storage

- `rabbitmq` should use the dedicated `gp3` StorageClass backed by the AWS EBS CSI driver.
- Existing `local-path` RabbitMQ claims are not migrated automatically by CD because deleting them is destructive.
- The one-time migration should be done during a controlled maintenance window by recreating the old `local-path` PVC/PV and letting the StatefulSet rebind on `gp3`.
- The repo includes a one-shot helper for that maintenance window: `scripts/deploy/migrate-rabbitmq-to-gp3.sh`.

## Monitoring Components

`k8s/monitoring/` deploys a lightweight Grafana Cloud collector path:

- Grafana Alloy collector
- OTLP receive endpoint (`alloy.pixtools.svc.cluster.local:4318`)
- Kubernetes log discovery and export to Grafana Cloud Loki
- Prometheus scrape/remote-write to Grafana Cloud Metrics
- OTLP trace export to Grafana Cloud Tempo

## Scaling Safety Guardrails

Sprint 4 guardrails are documented in:

- `docs/scaling_guardrails.md` for panel queries, alert conditions, and benchmark gates
- `docs/runbooks/` for incident handling playbooks

Operational notes:

- `pixtools-api` HPA and KEDA worker scaling include stabilization behavior to reduce flapping.
- `pixtools-api` and `pixtools-worker-standard` use rolling strategies (`maxUnavailable: 0`) so autoscaling and rollouts do not force avoidable downtime.
- `pixtools-beat` remains `Recreate` by design to avoid duplicate periodic task scheduling.
