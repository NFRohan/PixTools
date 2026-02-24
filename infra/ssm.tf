resource "random_password" "rabbitmq_password" {
  length  = 24
  special = false
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "aws_ssm_parameter" "database_url" {
  name  = "${local.ssm_prefix}/database_url"
  type  = "SecureString"
  tier  = "Standard"
  value = "postgresql+asyncpg://${var.rds_master_username}:${random_password.rds_master_password.result}@${aws_db_instance.main.address}:5432/${var.rds_db_name}"
}

resource "aws_ssm_parameter" "redis_url" {
  name  = "${local.ssm_prefix}/redis_url"
  type  = "String"
  tier  = "Standard"
  value = "redis://redis.pixtools.svc.cluster.local:6379/0"
}

resource "aws_ssm_parameter" "rabbitmq_url" {
  name  = "${local.ssm_prefix}/rabbitmq_url"
  type  = "SecureString"
  tier  = "Standard"
  value = "amqp://${local.rabbitmq_username}:${random_password.rabbitmq_password.result}@rabbitmq.pixtools.svc.cluster.local:5672//"
}

resource "aws_ssm_parameter" "rabbitmq_username" {
  name  = "${local.ssm_prefix}/rabbitmq_username"
  type  = "String"
  tier  = "Standard"
  value = local.rabbitmq_username
}

resource "aws_ssm_parameter" "rabbitmq_password" {
  name  = "${local.ssm_prefix}/rabbitmq_password"
  type  = "SecureString"
  tier  = "Standard"
  value = random_password.rabbitmq_password.result
}

resource "aws_ssm_parameter" "aws_s3_bucket" {
  name  = "${local.ssm_prefix}/aws_s3_bucket"
  type  = "String"
  tier  = "Standard"
  value = aws_s3_bucket.images.bucket
}

resource "aws_ssm_parameter" "aws_region" {
  name  = "${local.ssm_prefix}/aws_region"
  type  = "String"
  tier  = "Standard"
  value = var.aws_region
}

resource "aws_ssm_parameter" "idempotency_ttl_seconds" {
  name  = "${local.ssm_prefix}/idempotency_ttl_seconds"
  type  = "String"
  tier  = "Standard"
  value = tostring(var.idempotency_ttl_seconds)
}

resource "aws_ssm_parameter" "webhook_cb_fail_threshold" {
  name  = "${local.ssm_prefix}/webhook_cb_fail_threshold"
  type  = "String"
  tier  = "Standard"
  value = tostring(var.webhook_cb_fail_threshold)
}

resource "aws_ssm_parameter" "webhook_cb_reset_timeout" {
  name  = "${local.ssm_prefix}/webhook_cb_reset_timeout"
  type  = "String"
  tier  = "Standard"
  value = tostring(var.webhook_cb_reset_timeout)
}

resource "aws_ssm_parameter" "api_key" {
  name  = "${local.ssm_prefix}/api_key"
  type  = "SecureString"
  tier  = "Standard"
  value = var.api_key
}

resource "aws_ssm_parameter" "grafana_cloud_stack_id" {
  count = var.grafana_cloud_stack_id != "" ? 1 : 0

  name  = "${local.ssm_prefix}/grafana_cloud_stack_id"
  type  = "String"
  tier  = "Standard"
  value = var.grafana_cloud_stack_id
}

resource "aws_ssm_parameter" "grafana_cloud_api_key" {
  count = var.grafana_cloud_api_key != "" ? 1 : 0

  name  = "${local.ssm_prefix}/grafana_cloud_api_key"
  type  = "SecureString"
  tier  = "Standard"
  value = var.grafana_cloud_api_key
}

resource "aws_ssm_parameter" "grafana_cloud_logs_url" {
  count = var.grafana_cloud_logs_url != "" ? 1 : 0

  name  = "${local.ssm_prefix}/grafana_cloud_logs_url"
  type  = "String"
  tier  = "Standard"
  value = var.grafana_cloud_logs_url
}

resource "aws_ssm_parameter" "grafana_cloud_metrics_url" {
  count = var.grafana_cloud_metrics_url != "" ? 1 : 0

  name  = "${local.ssm_prefix}/grafana_cloud_metrics_url"
  type  = "String"
  tier  = "Standard"
  value = var.grafana_cloud_metrics_url
}

resource "aws_ssm_parameter" "grafana_cloud_traces_url" {
  count = var.grafana_cloud_traces_url != "" ? 1 : 0

  name  = "${local.ssm_prefix}/grafana_cloud_traces_url"
  type  = "String"
  tier  = "Standard"
  value = var.grafana_cloud_traces_url
}
