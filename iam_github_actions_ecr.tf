# Extends git-actions-mlb-engine (the existing least-privilege IAM user
# used by both workflows) with permission to push to the new ECR repo.
# Its role narrows going forward: build image -> push to ECR only. It no
# longer needs (and after this change, should no longer have) any
# RDS/Secrets Manager access, since ECS tasks — not Actions — will be
# the ones talking to RDS.
#
# Note: the actual IAM user name is "git-actions-mlb-engine" (no "hub"),
# confirmed via `aws iam list-users` — differs from how it's referred to
# in project notes/memory. Worth fixing that reference wherever else it
# appears (docs, other Terraform comments) so it doesn't cause the same
# confusion again.

data "aws_iam_user" "github_actions" {
  user_name = "git-actions-mlb-engine"
}

data "aws_iam_policy_document" "github_actions_ecr_push" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this specific action does not support resource-level scoping
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.mlb_engine_jobs.arn]
  }

  # Added Weekend 6 — the standing mlb-engine-app ECS service doesn't
  # pick up a freshly-pushed :latest image on its own (unlike the batch
  # jobs, which pull fresh on every scheduled run). This lets the
  # workflow trigger a redeploy right after a successful image push,
  # closing the "pushed but not actually live" gap that required a
  # manual `aws ecs update-service --force-new-deployment` today.
  # Scoped to exactly one service — this identity still can't touch
  # any other ECS service, task definition, or cluster-level action.
  statement {
    sid       = "RedeployAppService"
    actions   = ["ecs:UpdateService"]
    resources = [aws_ecs_service.app.id]
  }
}

resource "aws_iam_policy" "github_actions_ecr_push" {
  name   = "mlb-engine-github-actions-ecr-push"
  policy = data.aws_iam_policy_document.github_actions_ecr_push.json
}

resource "aws_iam_user_policy_attachment" "github_actions_ecr_push" {
  user       = data.aws_iam_user.github_actions.user_name
  policy_arn = aws_iam_policy.github_actions_ecr_push.arn
}