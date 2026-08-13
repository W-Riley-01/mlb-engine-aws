# Two distinct roles — this distinction trips people up, worth being
# explicit about it:
#
#   - EXECUTION role: used by the ECS *agent itself* to pull the image
#     from ECR and ship container logs to CloudWatch. Your application
#     code never touches this role directly.
#   - TASK role: assumed by your actual running code (boto3 calls from
#     inside prediction_logger.py / bootstrap_data.py). This is the
#     least-privilege one — same shape as mlb-engine-bootstrap-readonly,
#     just attached to the ECS task instead of the GitHub Actions user.

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------
# Task role — least-privilege app permissions
# ---------------------------------------------------------------------
resource "aws_iam_role" "mlb_engine_ecs_task_role" {
  name               = "mlb-engine-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

data "aws_iam_policy_document" "mlb_engine_ecs_task_permissions" {
  statement {
    sid       = "S3ParquetRead"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::mlb-engine-data-4462",
      "arn:aws:s3:::mlb-engine-data-4462/parquet/*",
    ]
  }

  statement {
    sid       = "RDSSecretRead"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:us-east-1:687050094462:secret:rds!db-e3e1711b-71a6-4339-9ebb-79ace00465a4-hT3Uzj",
    ]
  }
}

resource "aws_iam_policy" "mlb_engine_ecs_task_permissions" {
  name   = "mlb-engine-ecs-task-permissions"
  policy = data.aws_iam_policy_document.mlb_engine_ecs_task_permissions.json
}

resource "aws_iam_role_policy_attachment" "mlb_engine_ecs_task_permissions" {
  role       = aws_iam_role.mlb_engine_ecs_task_role.name
  policy_arn = aws_iam_policy.mlb_engine_ecs_task_permissions.arn
}

# ---------------------------------------------------------------------
# Execution role — AWS-managed policy covers ECR pull + CloudWatch Logs
# ---------------------------------------------------------------------
resource "aws_iam_role" "mlb_engine_ecs_execution_role" {
  name               = "mlb-engine-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "mlb_engine_ecs_execution_role" {
  role       = aws_iam_role.mlb_engine_ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
