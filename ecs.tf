resource "aws_ecs_cluster" "mlb_engine" {
  name = "mlb-engine-cluster"
}

resource "aws_cloudwatch_log_group" "mlb_engine_jobs" {
  name              = "/ecs/mlb-engine-jobs"
  retention_in_days = 14
}

locals {
  container_image = "${aws_ecr_repository.mlb_engine_jobs.repository_url}:latest"

  # Same env vars all three scripts already read via os.environ.get(...)
  # with fallbacks baked into the Python — passing them explicitly here
  # anyway keeps the task definition self-documenting and makes future
  # endpoint/region changes a Terraform-only change, no code touch needed.
  common_environment = [
    { name = "AWS_DEFAULT_REGION", value = "us-east-1" },
    { name = "RDS_SECRET_ARN", value = "arn:aws:secretsmanager:us-east-1:687050094462:secret:rds!db-16e1cf61-de84-4850-9d01-7315eaa97bcf-65Fnln" },
    { name = "RDS_ENDPOINT", value = "mlb-engine-db.cyzm64iqm3q4.us-east-1.rds.amazonaws.com" },
    { name = "RDS_PORT", value = "5432" },
    { name = "RDS_DB_NAME", value = "mlb_engine" },
  ]
}

# auto_log_predictions.py loads the resolver + ~260MB of parquet
# (contact_matrix_env, master_physics_vault, pitch_matrix, etc.) plus
# runs Monte Carlo sims — needs real memory/CPU headroom. Sizes below
# are a reasonable starting point; watch CloudWatch after the first few
# real runs and adjust (Weekend 9's observability work will make this
# easy to see).
resource "aws_ecs_task_definition" "auto_log_predictions" {
  family                   = "mlb-engine-auto-log-predictions"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024" # 1 vCPU
  memory                   = "3072" # 3 GB
  execution_role_arn       = aws_iam_role.mlb_engine_ecs_execution_role.arn
  task_role_arn            = aws_iam_role.mlb_engine_ecs_task_role.arn

  container_definitions = jsonencode([{
    name        = "auto-log-predictions"
    image       = local.container_image
    essential   = true
    command     = ["auto_log_predictions"]
    environment = local.common_environment
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mlb_engine_jobs.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "auto-log-predictions"
      }
    }
  }])
}

# record_outcomes.py is comparatively light — a handful of MLB Stats
# API calls plus small SQL writes, no parquet/simulation involved.
#
# Two task definitions, not one — the real workflow YAML runs this
# script with different arguments depending on time of day:
#   morning pass (13:00 UTC):   --retry-pending
#   afternoon pass (23:00 UTC): --retry-pending --all-unresolved
# ECS task definitions bake the command in at the container-definition
# level, so each distinct argument set needs its own family.

resource "aws_ecs_task_definition" "record_outcomes_morning" {
  family                   = "mlb-engine-record-outcomes-morning"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"  # 0.5 vCPU
  memory                   = "1024" # 1 GB
  execution_role_arn       = aws_iam_role.mlb_engine_ecs_execution_role.arn
  task_role_arn            = aws_iam_role.mlb_engine_ecs_task_role.arn

  container_definitions = jsonencode([{
    name        = "record-outcomes-morning"
    image       = local.container_image
    essential   = true
    command     = ["record_outcomes", "--retry-pending"]
    environment = local.common_environment
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mlb_engine_jobs.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "record-outcomes-morning"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "record_outcomes_afternoon" {
  family                   = "mlb-engine-record-outcomes-afternoon"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.mlb_engine_ecs_execution_role.arn
  task_role_arn            = aws_iam_role.mlb_engine_ecs_task_role.arn

  container_definitions = jsonencode([{
    name        = "record-outcomes-afternoon"
    image       = local.container_image
    essential   = true
    command     = ["record_outcomes", "--retry-pending", "--all-unresolved"]
    environment = local.common_environment
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mlb_engine_jobs.name
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "record-outcomes-afternoon"
      }
    }
  }])
}
