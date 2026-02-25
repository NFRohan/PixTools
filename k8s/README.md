# K8s Manifests

Manifests under this directory are rendered by `scripts/deploy/render-manifests.sh`.

## Placeholder Tokens

- `__API_IMAGE__`
- `__WORKER_IMAGE__`
- `__ALLOWED_INGRESS_CIDRS__`
- `__ALB_SECURITY_GROUP_ID__`

These are replaced in CI/CD before sync to S3.

## Deployment Model

- AWS Load Balancer Controller handles ALB ingress.
- API service is `NodePort` to support ALB target type `instance`.
- Runtime secret/config (`pixtools-runtime`, `pixtools-config`, `grafana-cloud`, `rabbitmq-auth`) is reconciled from SSM by `scripts/deploy/reconcile-cluster.sh`.
- Workloads use explicit node selectors:
  - app pods: `pixtools-workload-app=true`
  - infra pods: `pixtools-workload-infra=true`
- CD uploads rendered manifests + reconcile script to S3, then executes reconcile over SSM.

## Monitoring Components

`k8s/monitoring/` deploys a lightweight Grafana Cloud collector path:

- Grafana Alloy collector
- OTLP receive endpoint (`alloy.pixtools.svc.cluster.local:4318`)
- Kubernetes log discovery and export to Grafana Cloud Loki
- Prometheus scrape/remote-write to Grafana Cloud Metrics
- OTLP trace export to Grafana Cloud Tempo
