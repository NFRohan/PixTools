variable "project" {
  description = "Project name prefix for resources."
  type        = string
  default     = "pixtools"
}

variable "environment" {
  description = "Environment name (dev/prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "Primary VPC CIDR."
  type        = string
  default     = "10.40.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Two public subnet CIDRs for ALB and node placement."
  type        = list(string)
  default     = ["10.40.1.0/24", "10.40.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Two private subnet CIDRs for RDS."
  type        = list(string)
  default     = ["10.40.11.0/24", "10.40.12.0/24"]
}

variable "allowed_ingress_cidrs" {
  description = "CIDR allowlist for ALB ingress (demo lock-down)."
  type        = list(string)
}

# --- Infra node (on-demand, K3s server + RabbitMQ/Redis/Beat) ---

variable "infra_instance_type" {
  description = "Instance type for the always-on K3s server / infra node."
  type        = string
  default     = "t3.small"
}

variable "infra_volume_size_gb" {
  description = "Infra node root volume size in GiB."
  type        = number
  default     = 20
}

# --- Workload node(s) (spot, K3s agent + API/workers) ---

variable "workload_instance_type" {
  description = "Primary spot instance type for K3s workload agents."
  type        = string
  default     = "m7i-flex.large"
}

variable "workload_fallback_instance_types" {
  description = "Spot fallback types for workload ASG. Empty pins to workload_instance_type."
  type        = list(string)
  default     = []
}

variable "workload_volume_size_gb" {
  description = "Workload node root volume size in GiB."
  type        = number
  default     = 40
}

variable "workload_asg_min" {
  description = "Workload ASG minimum size."
  type        = number
  default     = 1
}

variable "workload_asg_max" {
  description = "Workload ASG maximum size. Set > 1 to allow horizontal scaling under load."
  type        = number
  default     = 3
}

variable "workload_asg_desired" {
  description = "Workload ASG desired capacity."
  type        = number
  default     = 1
}

variable "rds_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_engine_version" {
  description = "RDS Postgres major/minor version target."
  type        = string
  default     = "16"
}

variable "rds_allocated_storage" {
  description = "RDS allocated storage (GiB)."
  type        = number
  default     = 20
}

variable "rds_db_name" {
  description = "Application database name."
  type        = string
  default     = "pixtools"
}

variable "rds_k3s_db_name" {
  description = "K3s external datastore database name."
  type        = string
  default     = "k3s_state"
}

variable "rds_master_username" {
  description = "RDS master username."
  type        = string
  default     = "pixtools_admin"
}

variable "manifest_s3_prefix" {
  description = "Manifest prefix synced by bootstrap and CD pipeline."
  type        = string
  default     = "manifests/dev"
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch Logs retention for demo cluster logs."
  type        = number
  default     = 14
}

variable "idempotency_ttl_seconds" {
  description = "Idempotency key TTL."
  type        = number
  default     = 86400
}

variable "webhook_cb_fail_threshold" {
  description = "Webhook circuit breaker fail threshold."
  type        = number
  default     = 5
}

variable "webhook_cb_reset_timeout" {
  description = "Webhook circuit breaker reset timeout in seconds."
  type        = number
  default     = 60
}

variable "api_key" {
  description = "Demo API key value exposed to frontend/backend flow."
  type        = string
  default     = "pixtools-demo-key"
}

variable "grafana_cloud_stack_id" {
  description = "Grafana Cloud stack/user ID used for basic auth."
  type        = string
  default     = ""
}

variable "grafana_cloud_logs_user" {
  description = "Grafana Cloud Loki basic-auth username override. Falls back to grafana_cloud_stack_id when empty."
  type        = string
  default     = ""
}

variable "grafana_cloud_metrics_user" {
  description = "Grafana Cloud Prometheus basic-auth username override. Falls back to grafana_cloud_stack_id when empty."
  type        = string
  default     = ""
}

variable "grafana_cloud_traces_user" {
  description = "Grafana Cloud OTLP basic-auth username override. Falls back to grafana_cloud_stack_id when empty."
  type        = string
  default     = ""
}

variable "grafana_cloud_api_key" {
  description = "Grafana Cloud API key/token with logs/metrics/traces ingest scopes."
  type        = string
  default     = ""
}

variable "grafana_cloud_logs_url" {
  description = "Grafana Cloud Loki push endpoint URL."
  type        = string
  default     = ""
}

variable "grafana_cloud_metrics_url" {
  description = "Grafana Cloud Prometheus remote_write endpoint URL."
  type        = string
  default     = ""
}

variable "grafana_cloud_traces_url" {
  description = "Grafana Cloud OTLP traces endpoint URL."
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Optional email endpoint for CloudWatch alarm notifications."
  type        = string
  default     = ""
}

variable "alarm_alb_5xx_threshold" {
  description = "ALB 5XX alarm threshold (sum per 60s period)."
  type        = number
  default     = 5
}

variable "alarm_asg_inservice_min" {
  description = "Minimum in-service ASG instances before alarm."
  type        = number
  default     = 1
}

variable "alarm_rds_cpu_threshold_percent" {
  description = "RDS CPU alarm threshold percentage."
  type        = number
  default     = 80
}

variable "alarm_rds_free_storage_min_bytes" {
  description = "Minimum free RDS storage before alarm."
  type        = number
  default     = 2147483648 # 2 GiB
}
