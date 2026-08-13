# ECR repository for the shared image running all three scheduled scripts.

resource "aws_ecr_repository" "mlb_engine_jobs" {
  name                 = "mlb-engine-jobs"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = "mlb-engine"
  }
}

# Keeps old/untagged images from accumulating cost indefinitely.
resource "aws_ecr_lifecycle_policy" "mlb_engine_jobs" {
  repository = aws_ecr_repository.mlb_engine_jobs.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.mlb_engine_jobs.repository_url
  description = "Push images here from the simplified GitHub Actions build workflow."
}