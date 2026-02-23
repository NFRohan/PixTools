# PixTools Cloud Deployment Sprint Plan

## Objective
Ship PixTools to AWS with production-grade deployment, reliability, and security controls while preserving the current architecture goals:
- Stateful services managed on AWS (RDS, S3)
- Compute on EC2 + K3s + Celery
- Cost-aware operation with spot where it is safe

## Sprint Cadence
- Sprint length: 1 week
- Team assumption: 1 engineer (you) + AI support
- Exit rule: every sprint must end with deployable state on `main`

## Definition of Done (Global)
- CI green (`quality_and_tests`, `devsecops`, image build)
- Infra changes validated with `terraform validate`
- Deployment documented and reproducible from repo
- Runbook updated for any new operational component

## Architecture Freeze (v1 Proposed Defaults)
Use these defaults unless explicitly overridden during sprint execution.

### Compute and Orchestration
- K3s runs on EC2 spot via ASG: `min=1`, `max=1`, `desired=1`
- Primary instance type: `m7i-flex.large` (spot)
- Spot fallback overrides: `c7i-flex.large`, `m6i.large`
- On-demand fallback: disabled (`on_demand_base_capacity=0`, `on_demand_percentage_above_base_capacity=0`)
- Root EBS volume: `40 GiB gp3`
- AMI: Amazon Linux 2023 (x86_64)
- K3s server/worker on same node for v1 cost profile
- Worker split: `default_queue` concurrency `5`, `ml_inference_queue` concurrency `1`

### Data and Storage
- RDS engine: PostgreSQL 16
- RDS instance: `db.t4g.micro`
- RDS storage: `20 GiB gp3`, single-AZ for v1
- S3 bucket strategy: `pixtools-images-<account>-<region>` (app assets/results), `pixtools-manifests-<account>-<region>` (bootstrap manifests)
- S3 lifecycle: `raw/`, `processed/`, `archives/` expire after 1 day
- Optional transition for long-lived artifacts: disabled for v1

### Networking and Exposure
- AWS region default: `us-east-1`
- VPC CIDR: `10.40.0.0/16`
- Subnets: 2 public (ALB), 2 private (EC2 + RDS)
- ALB count: 1 ALB for `dev` (single ingress point)
- Public API exposure: ALB DNS hostname (no custom domain in v1 demo)
- Ingress path: HTTP for v1 demo (no ACM cert without owned domain)
- ALB security group ingress: allowlist only (your public IP/CIDR)
- SSH access: disabled by default; use SSM Session Manager

### Messaging and Caching
- RabbitMQ and Redis remain in-cluster on K3s for v1
- RabbitMQ queues must be durable
- Redis configured with eviction policy `allkeys-lru`

### Secrets and Identity
- Runtime secrets source: AWS SSM Parameter Store (SecureString)
- EC2 IAM role grants app access to S3 + SSM + CloudWatch Logs
- GitHub Actions deploy auth: OIDC role assumption (preferred)
- Temporary fallback allowed: static AWS keys in GitHub secrets for bootstrap only

### Release and Environments
- Environments: `dev` then `prod`
- Container registry: ECR (`pixtools-api`, `pixtools-worker`)
- Deployable artifact: immutable image digest
- Deployment trigger: merge to `main` deploys `dev`; manual approval for `prod`

### Observability Baseline
- Structured JSON logs shipped to CloudWatch Logs
- CloudWatch log retention: 14 days
- Prometheus + Grafana in-cluster for service metrics
- Minimum alert set: API health check failing 5m, queue depth above threshold 10m, worker count zero, RDS CPU > 80% for 10m

---

## Locked Decisions (2026-02-23)
- Region: `us-east-1`
- Domain/DNS: no custom domain for v1 demo; use AWS-provided ALB DNS hostname
- Ingress controller: AWS Load Balancer Controller
- Ingress exposure control: ALB security group allowlist
- Spot policy: spot-only compute (no on-demand fallback)
- RDS availability: single-AZ
- K3s datastore: external Postgres in RDS (`k3s_state`)
- Secrets backend: SSM Parameter Store
- Deployment model: GitHub Actions push deploy through SSM on EC2
- Access posture: API not intended for public use outside dedicated frontend flow
- RabbitMQ/Redis ownership: self-hosted in K3s
- Log retention: 14 days in CloudWatch
- Rollback policy: redeploy previous image digest
- FastAPI docs: keep `/docs` and `/redoc` enabled for demo exploration
- Budget policy: uncapped for now; existing AWS budget alert currently around `$20`

### Access-Control Implementation Notes (for Sprint 2)
- Serve frontend and API from the same ALB host to avoid cross-origin browser calls.
- Apply strict CORS allowlist (single origin: same host).
- Use ALB security group allowlist as the primary edge guard for demo safety.
- Keep FastAPI docs enabled for interview/demo walkthrough.

---

## Remaining Decisions (Post-v1)
1. Add custom domain + ACM TLS later, or keep ALB DNS for demo lifecycle.
2. Move to multi-AZ RDS later for stronger uptime.
3. Consider managed RabbitMQ/Redis if ops overhead grows.
4. Set formal budget cap and daily alarm thresholds after first full-cost measurement.
5. Migrate CI deploy auth fully to OIDC if static keys are used during bootstrap.

---

## Sprint 1 - Release Foundation (P0)
Goal: Create a real cloud release path from commit to deployable artifact.

### Backlog
1. Terraform remote state
- Create S3 backend bucket + DynamoDB lock table
- Configure `infra` to use remote backend
- Add `dev` tfvars/environment split

2. Container registry and immutable image flow
- Create ECR repositories (`api`, optionally `worker`)
- Update CI to build and push image on `main`
- Deploy by image digest, not mutable tags

3. CI split and guardrails
- Keep PR workflow for checks only
- Add CD workflow for `main` (build/push/deploy)
- Add environment protection for production deploy job

4. Config boundaries
- Separate local `.env` usage from cloud runtime config
- Document env contract per environment (dev/stage/prod)

5. Bootstrap foundation files (currently missing in repo)
- Add Terraform module/files under `infra/` for VPC, ASG, RDS, S3, IAM, outputs
- Add K8s manifests under `k8s/` for namespace, api, workers, rabbitmq, redis, ingress
- Add deployment scripts/docs for first cluster bootstrap

### Sprint 1 Concrete Implementation Details
1. Terraform state bootstrap resources
- `infra/bootstrap/backend_setup.tf`: S3 backend bucket `pixtools-tfstate-<account>-us-east-1`
- `infra/bootstrap/backend_setup.tf`: DynamoDB lock table `pixtools-tf-locks`
- `infra/backend.hcl.example`: backend config template for `dev`

2. Core Terraform layout under `infra/`
- `infra/providers.tf`: AWS provider, region `us-east-1`
- `infra/variables.tf`: environment, CIDRs, instance types, retention, allowed ingress CIDR
- `infra/main.tf`: VPC, subnets, route tables, NAT/IGW baseline
- `infra/security_groups.tf`: ALB SG (allowlisted ingress), EC2 SG, RDS SG
- `infra/iam.tf`: EC2 role/profile for S3, SSM, CloudWatch logs; GitHub OIDC role for deploy
- `infra/ecr.tf`: `pixtools-api` and `pixtools-worker` repositories
- `infra/s3.tf`: app buckets and lifecycle rules (`raw/processed/archives` 1-day expiry)
- `infra/rds.tf`: PostgreSQL 16, `db.t4g.micro`, single-AZ, 20GiB gp3
- `infra/asg.tf`: K3s EC2 launch template + spot-only mixed instances policy
- `infra/alb.tf`: single ALB, listener, target group, and allowlisted ingress SG rules
- `infra/outputs.tf`: ALB DNS, RDS endpoint, ECR URLs, SSM parameter prefixes
- `infra/dev.tfvars`: concrete dev values including your allowlisted public CIDR

3. SSM parameter contract (dev)
- `/pixtools/dev/database_url`
- `/pixtools/dev/redis_url`
- `/pixtools/dev/rabbitmq_url`
- `/pixtools/dev/aws_s3_bucket`
- `/pixtools/dev/webhook_cb_fail_threshold`
- `/pixtools/dev/webhook_cb_reset_timeout`

4. K8s manifest set under `k8s/`
- `k8s/namespace.yaml`: namespace `pixtools`
- `k8s/api/deployment.yaml` and `k8s/api/service.yaml`
- `k8s/workers/worker-standard.yaml`
- `k8s/workers/worker-ml.yaml`
- `k8s/rabbitmq/deployment.yaml` and `k8s/rabbitmq/service.yaml`
- `k8s/redis/deployment.yaml` and `k8s/redis/service.yaml`
- `k8s/ingress/ingress.yaml`: AWS LBC ingress definition targeting API service
- `k8s/config/configmap.yaml` and `k8s/config/secrets-provider.yaml` for SSM-backed runtime config

5. CI/CD implementation files
- `.github/workflows/ci.yaml`: PR checks only (already in place)
- `.github/workflows/cd-dev.yaml`: on `main`, build/push to ECR and deploy to dev K3s
- `.github/workflows/cd-prod.yaml`: manual trigger, same flow with environment approval
- `scripts/deploy/render-manifests.sh`: inject immutable image digest into manifests
- `scripts/deploy/run-on-ssm.sh`: execute deploy commands on EC2 host via SSM Run Command
- `scripts/deploy/kubeconfig-from-ssm.sh`: optional helper if direct kubeconfig retrieval is needed

6. Rollback mechanism
- Store prior successful image digest in deployment metadata
- Rollback action updates manifest image digest and reapplies via GitHub Actions

7. Observability sequencing (LGTM)
- Do not block cloud rollout on full LGTM stack.
- Phase 1 (`Sprint 1-2`): CloudWatch logs + existing metrics baseline.
- Phase 2 (`Sprint 4+`): introduce Loki/Grafana/Tempo/Mimir with trace correlation.

### Acceptance Criteria
- `main` push produces image in ECR
- K8s manifests consume pinned image digest
- Terraform state is remote and locked
- New engineer can follow README and deploy dev environment
- `infra/` and `k8s/` are no longer placeholder directories

---

## Sprint 2 - Security and Platform Hardening (P0/P1)
Goal: Remove fragile secret/config handling and harden external exposure.

### Backlog
1. Secrets management
- Store app secrets in AWS Secrets Manager or SSM Parameter Store
- Use IAM role on EC2/K3s nodes for secret access
- Remove cloud secret dependency on committed/local `.env`

2. Ingress and transport security
- Add ALB ingress hardening for demo exposure model
- If custom domain is added later: enable ACM TLS termination
- Restrict CORS to known origins
- Add API rate limiting at ingress layer

3. Storage and IAM hardening
- Enforce S3 block public access
- Enforce SSE encryption (SSE-S3 or KMS)
- Reduce IAM policies to least privilege

4. Broker durability baseline
- Set RabbitMQ durable queues and persistence
- Validate queue survives restart scenario

### Acceptance Criteria
- No cloud secrets loaded from repo files
- Public endpoint follows selected exposure model (v1: ALB DNS + restricted access)
- S3 and IAM pass security review checklist
- RabbitMQ restart does not lose durable messages

---

## Sprint 3 - Reliability and Failure Recovery (P1)
Goal: Make failure modes predictable and recoverable.

### Backlog
1. Stuck job reconciliation
- Add periodic task to mark stale `PROCESSING` jobs as failed/retryable
- Add UI/UX behavior for recovered stale jobs

2. Webhook reliability upgrade
- HMAC-sign webhook payloads
- Add retry with exponential backoff + jitter
- Persist webhook attempt history (status, timestamp, error)

3. DLQ operations
- Add tooling or admin endpoint for dead-letter inspection/replay
- Add runbook for poison message handling

4. Spot interruption game day
- Run controlled interruption test during active queue load
- Record recovery timeline and message durability outcomes

### Acceptance Criteria
- Stale jobs are auto-resolved without manual DB edits
- Webhook retries are observable and auditable
- DLQ replay process is documented and tested
- Spot recovery test report exists in repo

---

## Sprint 4 - Observability and Launch Readiness (P1/P2)
Goal: Add measurable SLOs, alerting, and operational readiness artifacts.

### Backlog
1. SLOs and dashboards
- Define SLOs: API availability, job success rate, P95 end-to-end processing latency, webhook success rate
- Build Grafana dashboards for each SLO

2. Alerting
- Add Alertmanager or CloudWatch alarm routing
- Alerts for queue depth, task failure spikes, API error rate, worker down

3. Capacity and cost checks
- Load test representative workloads
- Capture worker utilization and queue behavior
- Produce monthly cost estimate and budget alarms

4. Operational documentation
- Incident response runbook
- Deployment rollback procedure
- On-call quick checks (health, queues, workers, DB)

### Acceptance Criteria
- Alerts fire and route to tested destination
- SLO dashboard is live and usable
- Load test baseline and cost report committed
- Runbooks are complete enough for handoff

---

## Sequencing Dependencies
1. Sprint 1 must finish before Sprint 2 (artifact and env model first)
2. Sprint 2 should finish before Sprint 3 (security baselines before resilience tuning)
3. Sprint 3 and Sprint 4 can overlap partially once telemetry exists

## Recommended PR Breakdown
1. `infra`: remote state + env split
2. `ci/cd`: ECR build/push + deploy workflow
3. `security`: secrets manager + IAM + ingress hardening
4. `messaging`: durable RabbitMQ config
5. `reliability`: stale job reconciler + webhook hardening
6. `ops`: DLQ replay tooling + runbooks + dashboards/alerts

## Tracking Template (Copy Per Sprint)
```md
### Sprint X Status
- Goal:
- Planned stories:
- In progress:
- Blockers:
- Demo evidence:
- Retro notes:
```
