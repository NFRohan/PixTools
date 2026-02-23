locals {
  name_prefix = "${var.project}-${var.environment}"
  ssm_prefix  = "/${var.project}/${var.environment}"

  images_bucket_name    = "${var.project}-images-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  manifests_bucket_name = "${var.project}-manifests-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  public_subnet_map = {
    for idx, cidr in var.public_subnet_cidrs :
    format("public-%02d", idx) => {
      cidr = cidr
      az   = data.aws_availability_zones.available.names[idx]
    }
  }

  private_subnet_map = {
    for idx, cidr in var.private_subnet_cidrs :
    format("private-%02d", idx) => {
      cidr = cidr
      az   = data.aws_availability_zones.available.names[idx]
    }
  }

  rabbitmq_username = "pixtools"
}

