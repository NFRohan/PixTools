resource "aws_s3_bucket" "images" {
  bucket        = local.images_bucket_name
  force_destroy = true

  tags = {
    Name        = "${local.name_prefix}-images"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.images.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    id     = "expire-raw-24h"
    status = "Enabled"
    filter {
      prefix = "raw/"
    }
    expiration {
      days = 1
    }
  }

  rule {
    id     = "expire-processed-24h"
    status = "Enabled"
    filter {
      prefix = "processed/"
    }
    expiration {
      days = 1
    }
  }

  rule {
    id     = "expire-archives-24h"
    status = "Enabled"
    filter {
      prefix = "archives/"
    }
    expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket" "manifests" {
  bucket        = local.manifests_bucket_name
  force_destroy = true

  tags = {
    Name        = "${local.name_prefix}-manifests"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "manifests" {
  bucket                  = aws_s3_bucket.manifests.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "manifests" {
  bucket = aws_s3_bucket.manifests.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "manifests" {
  bucket = aws_s3_bucket.manifests.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

