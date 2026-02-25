data "aws_ssm_parameter" "amazon_linux_2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

resource "aws_launch_template" "k3s" {
  name_prefix   = "${local.name_prefix}-k3s-"
  image_id      = data.aws_ssm_parameter.amazon_linux_2023_ami.value
  instance_type = var.spot_instance_type

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
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/k3s_user_data.sh.tftpl", {
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
      Name        = "${local.name_prefix}-k3s"
      Project     = var.project
      Environment = var.environment
      Role        = "k3s-node"
    }
  }
}

resource "aws_autoscaling_group" "k3s" {
  name                      = "${local.name_prefix}-k3s"
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
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
        launch_template_id = aws_launch_template.k3s.id
        version            = "$Latest"
      }

      override {
        instance_type = var.spot_instance_type
      }

      dynamic "override" {
        for_each = var.spot_fallback_instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-k3s"
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
