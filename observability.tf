# ---------------------------------------------------------------------------
# Observability — SNS alert topic, CloudWatch alarms, monthly budget.
# Closes the last gap from the original migration plan (Weekend 9):
# no health or cost alerting existed prior to this file, only ECS log
# shipping. Scope is deliberately small — enough to know if something's
# actually broken or the bill is creeping up, not full Container Insights.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "mlb-engine-alerts"

  tags = {
    Project     = "mlb-engine"
    Environment = "dev"
    Owner       = "william"
  }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "william.e.rileyjr@gmail.com"
  # AWS sends a confirmation email on first apply — alarms will fire
  # silently (no delivery) until that link is clicked once.
}

# ---------------------------------------------------------------------------
# RDS health
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "mlb-engine-rds-cpu-high"
  alarm_description   = "RDS CPU utilization above 80% for 10 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }
  statistic           = "Average"
  period              = 300 # 5 min
  evaluation_periods  = 2   # 2 consecutive periods = 10 min sustained
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "mlb-engine-rds-storage-low"
  alarm_description   = "RDS free storage below 2GB (20GB allocated, free-tier ceiling)"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648 # 2 GiB in bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# App health (ALB / target group) — catches the standing Streamlit
# service going unhealthy or throwing server errors.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "app_unhealthy_hosts" {
  alarm_name          = "mlb-engine-app-unhealthy-hosts"
  alarm_description   = "One or more ECS tasks failing ALB health checks"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.app.arn_suffix
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3 # 3 minutes sustained, avoids alerting on a single failed check during deploys
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "app_5xx_errors" {
  alarm_name          = "mlb-engine-app-5xx-errors"
  alarm_description   = "5+ server errors from the app in a 5-minute window"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.app.arn_suffix
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# Cost control — mirrors the $30/month budget the original plan called
# for at Day Zero. Belt-and-suspenders if that was ever set up manually
# in the console; codifying it here means it survives account changes
# and shows up in the Terraform state like everything else.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "mlb-engine-monthly-budget"
  budget_type  = "COST"
  limit_amount = "30"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type              = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["william.e.rileyjr@gmail.com"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type              = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["william.e.rileyjr@gmail.com"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type              = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = ["william.e.rileyjr@gmail.com"]
  }
}