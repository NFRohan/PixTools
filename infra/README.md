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

```bash
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

## Notes

- Compute is spot-only (`m7i-flex.large` primary).
- RDS is single-AZ `db.t4g.micro`.
- K3s uses external datastore in RDS (`k3s_state` DB).
- Manifests are pulled from S3 prefix `manifests/dev`.

