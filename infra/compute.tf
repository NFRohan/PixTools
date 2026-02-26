# --- AMI ---
data "aws_ssm_parameter" "amazon_linux_2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# ============================================================
# INFRA NODE — on-demand K3s server (control plane + state)
# ============================================================

resource "aws_launch_template" "k3s_server" {
  name_prefix   = "${local.name_prefix}-k3s-server-"
  image_id      = data.aws_ssm_parameter.amazon_linux_2023_ami.value
  instance_type = var.infra_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.k3s_node.name
  }

  vpc_security_group_ids = [aws_security_group.k3s_node.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.infra_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/k3s_server_user_data.sh.tftpl", {
    aws_region      = var.aws_region
    project         = var.project
    environment     = var.environment
    cluster_name    = "${local.name_prefix}-k3s"
    manifest_bucket = aws_s3_bucket.manifests.bucket
    manifest_prefix = var.manifest_s3_prefix
    k3s_token       = random_password.k3s_token.result
    rds_address     = aws_db_instance.main.address
    rds_username    = var.rds_master_username
    rds_password    = random_password.rds_master_password.result
    app_db_name     = var.rds_db_name
    k3s_db_name     = var.rds_k3s_db_name
    ssm_prefix      = local.ssm_prefix
    vpc_id          = aws_vpc.main.id
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.name_prefix}-k3s-server"
      Project     = var.project
      Environment = var.environment
      Role        = "k3s-server"
    }
  }
}

resource "aws_autoscaling_group" "k3s_server" {
  name                      = "${local.name_prefix}-k3s-server"
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  health_check_type         = "EC2"
  health_check_grace_period = 300
  vpc_zone_identifier       = [for subnet in aws_subnet.public : subnet.id]

  launch_template {
    id      = aws_launch_template.k3s_server.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-k3s-server"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "k3s-server"
    propagate_at_launch = true
  }

  depends_on = [
    aws_ssm_parameter.database_url,
    aws_ssm_parameter.redis_url,
    aws_ssm_parameter.rabbitmq_url,
    aws_ssm_parameter.aws_s3_bucket,
    aws_ssm_parameter.api_key,
    aws_ssm_parameter.rabbitmq_username,
    aws_ssm_parameter.rabbitmq_password,
  ]
}

# ============================================================
# WORKLOAD NODE(S) — spot K3s agents (API + Celery workers)
# ============================================================

resource "aws_launch_template" "k3s_agent" {
  name_prefix   = "${local.name_prefix}-k3s-agent-"
  image_id      = data.aws_ssm_parameter.amazon_linux_2023_ami.value
  instance_type = var.workload_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.k3s_node.name
  }

  vpc_security_group_ids = [aws_security_group.k3s_node.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.workload_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/k3s_agent_user_data.sh.tftpl", {
    aws_region   = var.aws_region
    project      = var.project
    environment  = var.environment
    cluster_name = "${local.name_prefix}-k3s"
    k3s_token    = random_password.k3s_token.result
    ssm_prefix   = local.ssm_prefix
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.name_prefix}-k3s-agent"
      Project     = var.project
      Environment = var.environment
      Role        = "k3s-agent"
    }
  }
}

resource "aws_autoscaling_group" "k3s_agent" {
  name                      = "${local.name_prefix}-k3s-agent"
  min_size                  = var.workload_asg_min
  max_size                  = var.workload_asg_max
  desired_capacity          = var.workload_asg_desired
  health_check_type         = "EC2"
  health_check_grace_period = 300
  vpc_zone_identifier       = [for subnet in aws_subnet.public : subnet.id]

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.k3s_agent.id
        version            = "$Latest"
      }

      override {
        instance_type = var.workload_instance_type
      }

      dynamic "override" {
        for_each = var.workload_fallback_instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-k3s-agent"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "k3s-agent"
    propagate_at_launch = true
  }

  depends_on = [
    aws_autoscaling_group.k3s_server,
  ]
}
