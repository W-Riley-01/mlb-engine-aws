# MLB Market Engine — AWS Infrastructure

Terraform-managed AWS infrastructure for a Monte Carlo MLB prediction and
outcome-tracking system. Originally built on Streamlit Cloud + Supabase;
migrated to a fully self-managed AWS stack.

**Live app:** https://app.diamondmetrics.dev

## What this repo contains

Infrastructure-as-code only. Application code, the simulation engine, and
CI workflows live in the companion repo,
[`mlb-market-engine`](https://github.com/W-Riley-01/mlb-market-engine).

## Architecture

- **VPC** — 2 AZs, public + private subnets, NAT gateway for private egress
- **RDS PostgreSQL 17.9** — private subnet only, AWS-managed master credentials
  (password never touches application code or Terraform state)
- **ECS Fargate (scheduled)** — three containerized batch jobs (prediction
  logging, outcome recording) triggered by EventBridge Scheduler
- **ECS Fargate (standing service)** — the Streamlit app, behind an
  Application Load Balancer
- **Secrets Manager** — RDS credentials, fetched live at container start
- **EC2 bastion (SSM Session Manager only)** — zero inbound rules; used for
  local DB administration via port-forwarded tunnel
- **Route 53 + ACM** — custom domain, DNS-validated TLS
- **GitHub Actions → ECR** — builds and pushes the application image,
  automatically forces a new ECS deployment on push

## Status

Live and stable. Scheduled batch jobs and the standing web service have
both been verified running unattended via real scheduled triggers, not
just manual test runs.

## State management

Remote state in S3, with a DynamoDB lock table to prevent concurrent
`apply` conflicts.
