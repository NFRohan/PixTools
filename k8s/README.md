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
- Runtime secret/config (`pixtools-runtime`, `pixtools-config`) is created by EC2 bootstrap from SSM.

## Monitoring Components

`k8s/monitoring/` deploys a lightweight Grafana Cloud collector path:

- Grafana Alloy collector
- OTLP receive endpoint (`alloy.pixtools.svc.cluster.local:4318`)
- Kubernetes log discovery and export to Grafana Cloud Loki
- Prometheus scrape/remote-write to Grafana Cloud Metrics
- OTLP trace export to Grafana Cloud Tempo
