# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "mlb-engine-vpc"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

# ---------------------------------------------------------------------------
# Subnets — 2 public, 2 private, across 2 AZs
# ---------------------------------------------------------------------------
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = { Name = "mlb-engine-public-a", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = { Name = "mlb-engine-public-b", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "us-east-1a"

  tags = { Name = "mlb-engine-private-a", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "us-east-1b"

  tags = { Name = "mlb-engine-private-b", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

# ---------------------------------------------------------------------------
# Internet Gateway — for public subnets
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "mlb-engine-igw", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

# ---------------------------------------------------------------------------
# NAT Gateway — lets private subnets reach the internet outbound
# (single NAT for cost; both private subnets route through it)
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "mlb-engine-nat-eip", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id  # NAT must sit in a public subnet

  tags = { Name = "mlb-engine-nat", Project = "mlb-engine", Environment = "dev", Owner = "william" }

  depends_on = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "mlb-engine-public-rt", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "mlb-engine-private-rt", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "mlb-engine-rds-sg"
  description = "Allow Postgres access from the ECS security group only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "mlb-engine-rds-sg", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

resource "aws_security_group" "ecs" {
  name        = "mlb-engine-ecs-sg"
  description = "Future ECS service - outbound only for now"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "mlb-engine-ecs-sg", Project = "mlb-engine", Environment = "dev", Owner = "william" }
}

# RDS SG allows inbound Postgres (5432) only from the ECS SG — not the world
resource "aws_security_group_rule" "rds_from_ecs" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.ecs.id
}