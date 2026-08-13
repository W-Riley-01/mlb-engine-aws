# ---------------------------------------------------------------------------
# DB subnet group — tells RDS which subnets it's allowed to launch into.
# Both private subnets, spanning both AZs, per the Weekend 3 networking build.
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "mlb-engine-db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = {
    Name        = "mlb-engine-db-subnet-group"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL instance
# ---------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier     = "mlb-engine-db"
  engine         = "postgres"
  engine_version = "17.9" # Was 17.6 at initial provisioning; AWS applied a
  # minor-version auto-upgrade at some point after Weekend 4. Config now
  # matches reality instead of fighting an unwanted downgrade on every apply.

  instance_class    = "db.t4g.micro"   # free tier eligible
  allocated_storage = 20                # GB — free tier ceiling
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "mlb_engine"
  username = "mlb_engine_admin"

  # RDS generates and manages the master password itself, storing it
  # directly in Secrets Manager. Terraform, the state file, and we
  # ourselves never see the plaintext password at any point.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az = false   # single-AZ to stay in free tier; revisit for prod

  backup_retention_period = 0   # free tier restriction on this account currently caps this at 0; revisit once eligible
  skip_final_snapshot     = true   # dev project - fine for now; reconsider before anything resembling prod

  tags = {
    Name        = "mlb-engine-db"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

# ---------------------------------------------------------------------------
# Useful outputs — the endpoint and the Secrets Manager ARN holding the
# password. prediction_logger.py will use the secret ARN to fetch
# credentials at runtime instead of reading a connection string from .env.
# ---------------------------------------------------------------------------
output "rds_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "rds_secret_arn" {
  value = aws_db_instance.main.master_user_secret[0].secret_arn
}

