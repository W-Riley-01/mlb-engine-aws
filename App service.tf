# =============================================================================
#  Weekend 6 — Streamlit app as a standing ECS service behind an HTTPS ALB
# =============================================================================
#  Separate from ecs.tf's batch-job task definitions (Weekend 5). This is a
#  long-running service, not a one-shot scheduled task: desired_count = 1,
#  registered behind an Application Load Balancer, fronted by ACM/TLS.
#
#  Domain: diamondmetrics.dev, registered + hosted directly in Route 53
#  (registered manually via console — Route 53 domain registration can't be
#  fully driven by Terraform in one apply since the registration itself
#  takes real-world time to complete). The hosted zone already exists as a
#  result of that registration; we look it up via data source rather than
#  managing it as a resource, so Terraform doesn't try to "own" (and
#  potentially destroy) a zone it didn't create.
# =============================================================================

# ---------------------------------------------------------------------------
# Hosted zone lookup (created automatically by Route 53 domain registration,
# not by this Terraform config)
# ---------------------------------------------------------------------------
data "aws_route53_zone" "primary" {
  name         = "diamondmetrics.dev."
  private_zone = false
}

# ---------------------------------------------------------------------------
# ACM certificate — DNS validated via Route 53
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "app" {
  domain_name       = "app.diamondmetrics.dev"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "diamondmetrics-app-cert"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

# ACM generates one CNAME per domain name on the cert (just one here, since
# there's a single domain_name and no SANs) — Terraform creates it in
# Route 53 automatically via for_each over domain_validation_options.
resource "aws_route53_record" "app_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.primary.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks until ACM confirms it can see the validation CNAME resolve —
# downstream resources (the HTTPS listener) depend on this, not on the raw
# certificate, so nothing tries to attach an unvalidated cert.
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# ALB security group — public-facing, 80 + 443 from the internet
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "mlb-engine-alb-sg"
  description = "Public ALB for the Streamlit app - inbound 80/443 from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet (redirected to HTTPS by the listener)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "To ECS tasks on the Streamlit port"
    from_port       = 8501
    to_port         = 8501
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  tags = {
    Name        = "mlb-engine-alb-sg"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

# mlb-engine-ecs-sg (network.tf) was egress-only up through Weekend 5, since
# it only fronted batch jobs with no inbound traffic. This is the first
# ingress rule it's ever needed — scoped to the ALB SG only, not the world.
resource "aws_security_group_rule" "ecs_from_alb" {
  type                     = "ingress"
  from_port                = 8501
  to_port                  = 8501
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs.id
  source_security_group_id = aws_security_group.alb.id
}

# ---------------------------------------------------------------------------
# Application Load Balancer, target group, listeners
# ---------------------------------------------------------------------------
resource "aws_lb" "app" {
  name               = "mlb-engine-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = {
    Name        = "mlb-engine-alb"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

resource "aws_lb_target_group" "app" {
  name        = "mlb-engine-app-tg"
  port        = 8501
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # required for Fargate awsvpc networking - EC2/instance targets don't apply here

  health_check {
    path                = "/_stcore/health" # Streamlit's built-in health endpoint (>=1.x)
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name        = "mlb-engine-app-tg"
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

# Port 80 exists only to redirect to 443 - no plaintext traffic ever reaches
# the target group.
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# DNS — alias record pointing app.diamondmetrics.dev at the ALB
# ---------------------------------------------------------------------------
# Alias (not CNAME) because it's the apex-friendly, AWS-native way to point
# a record at an ALB - resolves to the ALB's current IPs directly, no extra
# DNS hop, and (per Route 53 pricing) alias queries to an ALB are free.
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "app.diamondmetrics.dev"
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# ECS service + task definition for the Streamlit app itself
# ---------------------------------------------------------------------------
# Reuses the same execution/task IAM roles from iam_ecs.tf and the same
# ECR image (local.container_image, defined in ecs.tf) as the batch jobs -
# the Streamlit app is dispatched via the same entrypoint.sh, just with a
# different command. No new IAM policy needed: the task role already has
# S3 read (parquet) and Secrets Manager read (RDS creds), and app.py only
# needs the latter since it doesn't import bootstrap_data.
resource "aws_cloudwatch_log_group" "mlb_engine_app" {
  name              = "/ecs/mlb-engine-app"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "app" {
  family                   = "mlb-engine-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"  # 0.5 vCPU - read-only DB viewer, no sim/parquet load
  memory                   = "1024" # 1 GB
  execution_role_arn       = aws_iam_role.mlb_engine_ecs_execution_role.arn
  task_role_arn             = aws_iam_role.mlb_engine_ecs_task_role.arn

  container_definitions = jsonencode([{
    name      = "mlb-engine-app"
    image     = local.container_image
    essential = true
    command   = ["streamlit_app"] # see entrypoint.sh - new case added for this

    portMappings = [{
      containerPort = 8501
      protocol      = "tcp"
    }]

    environment = local.common_environment

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mlb_engine_app.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = "mlb-engine-app"
  cluster         = aws_ecs_cluster.mlb_engine.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Streamlit boots fast (no parquet bootstrap), so a short grace period is
  # fine - gives it room for cold-start + first RDS connection without
  # letting a genuinely broken deploy hang around.
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "mlb-engine-app"
    container_port   = 8501
  }

  # Don't attach to the target group before the HTTPS listener exists -
  # avoids a brief window where the ALB has a target group but nothing
  # listening to forward traffic to it.
  depends_on = [aws_lb_listener.https]
}

# ---------------------------------------------------------------------------
# Useful outputs
# ---------------------------------------------------------------------------
output "app_url" {
  value = "https://app.diamondmetrics.dev"
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}
