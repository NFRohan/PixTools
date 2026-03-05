# Infra Bootstrap

This folder provisions the AWS baseline for PixTools cloud deployment.

## 1) Create Terraform remote state backend

```bash
cd infra/bootstrap
terraform init
terraform apply
```

Use outputs to fill `infra/backend.hcl`.

## 2) Configure backend

Create `infra/backend.hcl` from `infra/backend.hcl.example`, then:

```bash
cd infra
terraform init -backend-config=backend.hcl
```

## 3) Plan/apply dev

Create `dev.tfvars` from `dev.tfvars.example` and set `allowed_ingress_cidrs`.
If you want alarm notifications, also set `alarm_email`.

```bash
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

## Notes

- Compute is split by role:
  - infra/server ASG is fixed on-demand (`min=max=desired=1`)
  - workload/agent ASG is spot-backed and autoscaled
- Default instance class is `m7i-flex.large` for both infra and workload templates.
- RDS is single-AZ `db.t4g.micro`.
- K3s uses external datastore in RDS (`k3s_state` DB).
- Manifests are pulled from S3 prefix `manifests/dev`.
- Bootstrap and CD run `scripts/deploy/reconcile-cluster.sh`, which pulls runtime secrets from SSM and converges workloads.
- Workload ASG is tagged for Cluster Autoscaler auto-discovery.
- Monitoring creates:
  - SNS topic for alerts
  - ALB 5XX CloudWatch alarm (auto-discovered ALB by Kubernetes tags)
  - ASG in-service instance alarm
  - RDS CPU and free-storage alarms
  - Lightweight Alloy collector deployment via manifests (`k8s/monitoring/*`)
