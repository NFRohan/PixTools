resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.environment}/app"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

