# Replaces the `schedule: - cron: ...` blocks in auto-log-predictions.yml
# and record-outcomes.yml.
#
# GitHub Actions cron is 5-field POSIX cron (UTC). EventBridge Scheduler
# cron is 6-field: minute hour day-of-month month day-of-week year.
# Exactly one of day-of-month / day-of-week must be "?" — "* * ? *"
# below means "every day," same semantics as Actions' bare "* *".
#
# Each distinct GitHub Actions `cron:` line becomes its own
# aws_scheduler_schedule resource (Scheduler doesn't support multiple
# trigger times in one schedule the way Actions' YAML list does).

resource "aws_iam_role" "eventbridge_scheduler_ecs" {
  name = "mlb-engine-eventbridge-scheduler-ecs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_scheduler_run_task" {
  name = "run-ecs-task"
  role = aws_iam_role.eventbridge_scheduler_ecs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunEcsTask"
        Effect   = "Allow"
        Action   = "ecs:RunTask"
        Resource = [
          aws_ecs_task_definition.auto_log_predictions.arn,
          aws_ecs_task_definition.record_outcomes_morning.arn,
          aws_ecs_task_definition.record_outcomes_afternoon.arn,
        ]
        Condition = {
          ArnLike = {
            "ecs:cluster" = aws_ecs_cluster.mlb_engine.arn
          }
        }
      },
      {
        Sid      = "PassEcsRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [
          aws_iam_role.mlb_engine_ecs_task_role.arn,
          aws_iam_role.mlb_engine_ecs_execution_role.arn,
        ]
      }
    ]
  })
}

locals {
  # Reused by every schedule target below — private subnets across both
  # AZs, ECS security group, no public IP (matches how RDS/bastion are
  # already set up: private-only, NAT for outbound).
  ecs_subnets         = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  ecs_security_groups = [aws_security_group.ecs.id]
}

# ---------------------------------------------------------------------
# auto_log_predictions — 5x daily, same task definition/command for all
# five (only the manual workflow_dispatch path used --iterations /
# --skip-existing; all scheduled passes just run the script plain).
#
# Five runs, timed to cover the full first-pitch spread across time
# zones with a ~2-3hr lineup-to-first-pitch lead:
#   9:00 AM ET  - baseline/early check
#   11:00 AM ET - day games (~1:05-1:40 PM ET first pitch)
#   2:00 PM ET  - safety-net pass (cheap, idempotent, catches stragglers)
#   5:30 PM ET  - the bulk of the schedule: East/Central evening games
#                 (~7:05-8:35 PM ET first pitch)
#   8:00 PM ET  - West Coast night games (~10:05-10:15 PM ET first pitch)
#
# All runs are safe to overlap/repeat — auto_log_predictions.py skips
# games with no lineups yet and skips games already logged, so an
# "extra" run on a day with a lighter slate just does nothing.
# ---------------------------------------------------------------------

resource "aws_scheduler_schedule" "auto_log_predictions_morning" {
  name                = "mlb-engine-auto-log-predictions-morning" # 13:00 UTC / 9:00 AM ET
  schedule_expression = "cron(0 13 * * ? *)"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_ecs_cluster.mlb_engine.arn
    role_arn = aws_iam_role.eventbridge_scheduler_ecs.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.auto_log_predictions.arn
      launch_type          = "FARGATE"
      network_configuration {
        subnets          = local.ecs_subnets
        security_groups  = local.ecs_security_groups
        assign_public_ip = false
      }
    }
  }
}

resource "aws_scheduler_schedule" "auto_log_predictions_midday" {
  name                = "mlb-engine-auto-log-predictions-midday" # 15:00 UTC / 11:00 AM ET
  schedule_expression = "cron(0 15 * * ? *)"

  # Closes a gap that existed even before the AWS migration (the same
  # 3-run cadence was in the original GitHub Actions cron): the 9:00 AM
  # ET run is too early for lineups on games with a ~12:00-1:40 PM ET
  # first pitch, and the 2:00 PM ET run lands after those games have
  # already started. 11:00 AM ET sits in the window where day-game
  # lineups are typically posted (roughly 2-3 hours before first pitch)
  # but well before first pitch itself.

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_ecs_cluster.mlb_engine.arn
    role_arn = aws_iam_role.eventbridge_scheduler_ecs.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.auto_log_predictions.arn
      launch_type          = "FARGATE"
      network_configuration {
        subnets          = local.ecs_subnets
        security_groups  = local.ecs_security_groups
        assign_public_ip = false
      }
    }
  }
}

resource "aws_scheduler_schedule" "auto_log_predictions_afternoon" {
  name                = "mlb-engine-auto-log-predictions-afternoon" # 18:00 UTC / 2:00 PM ET
  schedule_expression = "cron(0 18 * * ? *)"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_ecs_cluster.mlb_engine.arn
    role_arn = aws_iam_role.eventbridge_scheduler_ecs.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.auto_log_predictions.arn
      launch_type          = "FARGATE"
      network_configuration {
        subnets          = local.ecs_subnets
        security_groups  = local.ecs_security_groups
        assign_public_ip = false
      }
    }
  }
}

resource "aws_scheduler_schedule" "auto_log_predictions_pre_first_pitch" {
  name                = "mlb-engine-auto-log-predictions-pre-first-pitch" # 21:30 UTC / 5:30 PM ET
  schedule_expression = "cron(30 21 * * ? *)"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_ecs_cluster.mlb_engine.arn
    role_arn = aws_iam_role.eventbridge_scheduler_ecs.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.auto_log_predictions.arn
      launch_type          = "FARGATE"
      network_configuration {
        subnets          = local.ecs_subnets
        security_groups  = local.ecs_security_groups
        assign_public_ip = false
      }
    }
  }
}

resource "aws_scheduler_schedule" "auto_log_predictions_west_coast" {
  name                = "mlb-engine-auto-log-predictions-west-coast" # 00:00 UTC / 8:00 PM ET
  schedule_expression = "cron(0 0 * * ? *)"

  # Catches West Coast night-game lineups (typical first pitch 10:05-
  # 10:15 PM ET / 7:05-7:15 PM PT). The 5:30 PM ET pre-first-pitch run
  # above is timed for East/Central evening games and is too early for
  # these — West Coast lineups typically post ~2-3 hours before their
  # (later) first pitch, i.e. around 7-8 PM ET.
  #
  # Note the UTC hour: 00:00 UTC is 8:00 PM ET only during EDT (summer,
  # i.e. the regular MLB season). During EST (winter), 00:00 UTC is
  # 7:00 PM ET instead — worth knowing if this ever runs during spring
  # training in March, though not a concern during the regular season.

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_ecs_cluster.mlb_engine.arn
    role_arn = aws_iam_role.eventbridge_scheduler_ecs.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.auto_log_predictions.arn
      launch_type          = "FARGATE"
      network_configuration {
        subnets          = local.ecs_subnets
        security_groups  = local.ecs_security_groups
        assign_public_ip = false
      }
    }
  }
}

# ---------------------------------------------------------------------
# record_outcomes — 2x daily, DIFFERENT task definitions (see ecs.tf —
# morning uses --retry-pending, afternoon adds --all-unresolved)
# ---------------------------------------------------------------------

resource "aws_scheduler_schedule" "record_outcomes_morning" {
  name                = "mlb-engine-record-outcomes-morning" # 13:00 UTC / 8:00 AM CT
  schedule_expression = "cron(0 13 * * ? *)"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_ecs_cluster.mlb_engine.arn
    role_arn = aws_iam_role.eventbridge_scheduler_ecs.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.record_outcomes_morning.arn
      launch_type          = "FARGATE"
      network_configuration {
        subnets          = local.ecs_subnets
        security_groups  = local.ecs_security_groups
        assign_public_ip = false
      }
    }
  }
}

resource "aws_scheduler_schedule" "record_outcomes_afternoon" {
  name                = "mlb-engine-record-outcomes-afternoon" # 23:00 UTC / 6:00 PM CT
  schedule_expression = "cron(0 23 * * ? *)"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_ecs_cluster.mlb_engine.arn
    role_arn = aws_iam_role.eventbridge_scheduler_ecs.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.record_outcomes_afternoon.arn
      launch_type          = "FARGATE"
      network_configuration {
        subnets          = local.ecs_subnets
        security_groups  = local.ecs_security_groups
        assign_public_ip = false
      }
    }
  }
}
