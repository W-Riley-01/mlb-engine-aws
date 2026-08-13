# MLB Engine AWS Infrastructure

Terraform-managed AWS infrastructure for the MLB prediction engine -
migrated from Streamlit Cloud + Supabase + GitHub Actions to a fully
self-hosted AWS stack.

## Purpose

This repo is a real, in-production infrastructure build and a data
architecture / data analysis portfolio piece. It started alongside AWS
SAA-C03 certification study; that certification track has since been
dropped, but the migration itself continued in full. App code lives in
the separate mlb-market-engine repo (https://github.com/W-Riley-01/mlb-market-engine)
- this repo is Terraform source only.

## Live architecture

| Component | Service |
|---|---|
| Database | RDS PostgreSQL 17.9, private subnets, Secrets Manager-managed master credentials |
| Data storage | S3 (parquet files) |
| Scheduled batch jobs | ECS Fargate, triggered by EventBridge Scheduler (5x daily predictions, 2x daily outcome resolution) |
| Standing web app | ECS Fargate service (Streamlit) behind an Application Load Balancer |
| TLS / domain | ACM certificate + Route 53 (diamondmetrics.dev), DNS-validated |
| Container registry | ECR |
| CI/CD | GitHub Actions - builds/pushes image, auto-redeploys the app service on push |
| Local DB access | EC2 bastion (SSM Session Manager only - no inbound rules, no public IP, no SSH); standing infrastructure kept intentionally for DBeaver/SQL admin work |

Scheduled jobs and the standing app service share one ECR image,
dispatched via entrypoint.sh based on the command passed in each ECS
task definition.

## Status

All of the above is live and serving real predictions at
https://app.diamondmetrics.dev. Originally planned to use Lambda +
EventBridge for scheduled jobs - that was superseded during the build
by ECS Fargate + EventBridge Scheduler for all compute, scheduled and
standing alike, since it let both share one container image and IAM
role setup rather than maintaining a separate Lambda packaging path.

See DECISIONS.md for architecture tradeoffs and the app repo's
README.md for current backlog and session history.
