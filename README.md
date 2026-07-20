# MLB Engine AWS Migration

Terraform-managed AWS infrastructure for migrating the MLB prediction engine 
(originally on Streamlit Cloud + Supabase) to a fully AWS-native stack.

## Purpose
This repo is both a real infrastructure migration and a hands-on AWS SAA-C03 
study project — each phase maps to services covered on the exam.

## Target architecture
- S3 — static assets / parquet data storage
- RDS (PostgreSQL) — replaces Supabase Postgres
- ECS Fargate — containerized app hosting (replaces Streamlit Cloud)
- Lambda + EventBridge — scheduled jobs (replaces GitHub Actions cron)
- Secrets Manager — credentials and API keys
- CloudWatch — logging and monitoring

## Status
In progress — foundational AWS account setup complete (IAM, CloudTrail, 
budgets). Terraform modules not yet written.