resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB ingress SG restricted to allowlist CIDRs."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Demo ingress allowlist on HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name_prefix}-alb-sg"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_security_group" "k3s_node" {
  name        = "${local.name_prefix}-k3s-node-sg"
  description = "K3s node security group."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "ALB to NodePort range (AWS LBC instance mode)"
    from_port       = 30000
    to_port         = 32767
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Self-reference: Allow all internal traffic between nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name_prefix}-k3s-node-sg"
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS SG allowing PostgreSQL from k3s nodes only."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from k3s nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.k3s_node.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name_prefix}-rds-sg"
    Project     = var.project
    Environment = var.environment
  }
}

