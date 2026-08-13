# ---------------------------------------------------------------------------
# IAM role for the bastion — grants only what's needed to register with
# Systems Manager. No S3, no other AWS permissions attached.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "bastion_ssm" {
  name = "mlb-engine-bastion-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "mlb-engine-bastion-ssm-role"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "mlb-engine-bastion-profile"
  role = aws_iam_role.bastion_ssm.name
}

# ---------------------------------------------------------------------------
# Security group — bastion has NO inbound rules at all (SSM doesn't need
# any open port; it works over an outbound-only agent connection).
# Outbound is limited to the RDS port, plus HTTPS for the SSM agent itself.
# ---------------------------------------------------------------------------
resource "aws_security_group" "bastion" {
  name        = "mlb-engine-bastion-sg"
  description = "SSM-only bastion - no inbound, outbound limited to RDS and HTTPS"
  vpc_id      = aws_vpc.main.id

  egress {
    description     = "To RDS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds.id]
  }

  egress {
    description = "HTTPS for SSM agent"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "mlb-engine-bastion-sg"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

# Allow the bastion in on 5432 — RDS SG currently only allows the ECS SG,
# so we add the bastion as a second allowed source, temporarily, for migration.
resource "aws_security_group_rule" "rds_from_bastion" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.bastion.id
}

# ---------------------------------------------------------------------------
# The bastion itself — smallest free-tier-eligible instance, Amazon Linux
# 2023 (SSM agent pre-installed, no extra setup needed). No key pair, no
# public IP needed for SSH since we're not using SSH at all.
# ---------------------------------------------------------------------------
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type           = "t3.micro"
  subnet_id               = aws_subnet.private_a.id   # private subnet - reaches SSM via the NAT Gateway, no public IP needed or possible
  vpc_security_group_ids  = [aws_security_group.bastion.id]
  iam_instance_profile    = aws_iam_instance_profile.bastion.name

  tags = {
    Name        = "mlb-engine-bastion"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }

  # data.aws_ami.al2023 uses most_recent = true, which re-resolves to
  # whatever AWS's newest AL2023 image is on every single `terraform
  # plan` — AWS ships new AMIs often enough that this drifts almost
  # every time, forcing an unwanted destroy-and-recreate that would
  # generate a brand new instance ID and break every hardcoded
  # reference to i-0d94f8464dfb20878 (SSM tunnel commands, docs, etc).
  # Ignore drift on `ami` here; bump it deliberately (remove this line
  # temporarily, or taint the resource) if the bastion ever genuinely
  # needs a fresh image, e.g. for a security patch.
  lifecycle {
    ignore_changes = [ami]
  }
}


