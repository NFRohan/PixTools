output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = [for subnet in aws_subnet.public : subnet.id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = [for subnet in aws_subnet.private : subnet.id]
}

output "k3s_asg_name" {
  description = "K3s Auto Scaling Group name."
  value       = aws_autoscaling_group.k3s.name
}

output "k3s_node_security_group_id" {
  description = "K3s node security group ID."
  value       = aws_security_group.k3s_node.id
}

output "alb_security_group_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}

output "rds_endpoint" {
  description = "RDS endpoint hostname."
  value       = aws_db_instance.main.address
}

output "rds_db_name" {
  description = "Application database name."
  value       = var.rds_db_name
}

output "k3s_datastore_db_name" {
  description = "K3s datastore database name."
  value       = var.rds_k3s_db_name
}

output "images_bucket_name" {
  description = "S3 bucket for raw/processed/archive images."
  value       = aws_s3_bucket.images.bucket
}

output "manifests_bucket_name" {
  description = "S3 bucket for rendered Kubernetes manifests."
  value       = aws_s3_bucket.manifests.bucket
}

output "ecr_api_repository_url" {
  description = "ECR API repository URL."
  value       = aws_ecr_repository.api.repository_url
}

output "ecr_worker_repository_url" {
  description = "ECR worker repository URL."
  value       = aws_ecr_repository.worker.repository_url
}

output "ssm_parameter_prefix" {
  description = "SSM parameter prefix used by app runtime."
  value       = local.ssm_prefix
}

output "alerts_sns_topic_arn" {
  description = "SNS topic ARN for infrastructure and runtime alarms."
  value       = aws_sns_topic.alerts.arn
}

output "ingress_alb_arn" {
  description = "Detected AWS Load Balancer Controller ALB ARN (if present)."
  value       = local.ingress_alb_arn
}
