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

variable "spot_instance_type" {
  description = "Primary spot instance type for K3s compute."
  type        = string
  default     = "m7i-flex.large"
}

variable "spot_fallback_instance_types" {
  description = "Spot fallback types. Still spot-only, no on-demand fallback."
  type        = list(string)
  default     = ["c7i-flex.large", "m6i.large"]
}

variable "asg_min_size" {
  description = "ASG min size."
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "ASG max size."
  type        = number
  default     = 1
}

variable "asg_desired_capacity" {
  description = "ASG desired capacity."
  type        = number
  default     = 1
}

variable "root_volume_size_gb" {
  description = "EC2 root volume size in GiB."
  type        = number
  default     = 40
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

