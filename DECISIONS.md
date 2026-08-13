# Architecture Decisions

Real tradeoffs made during the MLB Market Engine AWS migration, not
just "AWS best practice" statements - each one reflects a constraint
or judgment call specific to this project.

---

## Database: RDS PostgreSQL vs Aurora Serverless v2 vs staying on Supabase

Chose: RDS PostgreSQL, db.t4g.micro, single-AZ, Secrets Manager-managed
master credentials.

Why: The schema is relational with foreign keys across four tables
(game_predictions, player_predictions, game_outcomes,
player_outcomes) - standard Postgres fits directly, no
denormalization needed. Aurora Serverless v2's minimum capacity (0.5
ACU) costs meaningfully more than a t4g.micro at this workload size,
for no real benefit given traffic is low and predictable (a handful of
scheduled batch writes per day, occasional read traffic from the
Streamlit app). Supabase worked fine functionally, but the migration's
purpose was to build and demonstrate a self-hosted AWS stack, so
staying on a managed third-party Postgres wasn't on the table.

Revisit when: Traffic patterns change significantly, or genuine
high-availability requirements emerge (this is a portfolio project, not
a paid production service - single-AZ is an acceptable risk here).

---

## Compute: ECS Fargate vs Lambda vs EC2

Chose: ECS Fargate for everything - both the scheduled batch jobs
(auto_log_predictions.py, record_outcomes.py) and the standing
Streamlit app service.

Why: The original plan split these - Lambda + EventBridge for
scheduled jobs, ECS Fargate + ALB for the standing app - mainly because
that split covered more distinct AWS services for exam-study purposes.
Once the exam track was dropped, that justification went away, and
Fargate-for-everything won out on its own merits: one container image,
one IAM role/task role setup, one entrypoint.sh dispatch pattern
shared across scheduled jobs and the standing service. Lambda would
have meant a second packaging/deployment path for no functional gain,
and the batch jobs' actual runtime (loading ~260MB of parquet, running
Monte Carlo simulations) sits closer to Fargate's comfort zone than
Lambda's default memory/time constraints anyway.

Revisit when: If job frequency or duration patterns ever favored
true pay-per-invocation pricing over Fargate's per-task billing.

---

## Scheduled jobs: EventBridge Scheduler vs GitHub Actions cron

Chose: EventBridge Scheduler triggering ECS Fargate tasks directly.

Why: The project started on GitHub Actions cron (inherited from the
original Streamlit Cloud + Supabase setup). That schedule had a real,
pre-existing gap - the original 3x-daily cadence structurally missed
any game with a ~12-1:30 PM ET first pitch - which surfaced during the
migration and got fixed by moving to EventBridge Scheduler with 5
runs/day. Moving off GitHub Actions cron also meant credentials and
network access could be scoped entirely to AWS-native IAM roles instead
of long-lived secrets in GitHub, and job execution no longer depended
on GitHub Actions' shared runner availability/timing.

Revisit when: N/A - this is working well and has no known
limitations at current scale.

---

## Local DB access: EC2 bastion (SSM-only) vs public RDS vs no direct access

Chose: A permanent, standing EC2 bastion, SSM Session Manager only
- no inbound security group rules, no public IP, no SSH, no key pair.

Why: RDS is fully private (no public accessibility) by design -
that's not up for debate given this handles real credentials and
(eventually) real usage data. The bastion was originally built as a
migration aid and was briefly decommissioned once the migration itself
was "done," then deliberately restored: local DBeaver/SQL access is a
standing need for ongoing calibration analysis and general SQL/DB
administration practice, not a one-time migration task. Cost is
negligible (t3.micro, SSM-only, no elastic IP), and the security
posture (zero inbound rules, IAM role scoped to only
AmazonSSMManagedInstanceCore) means there's no meaningful attack
surface added by keeping it running.

Revisit when: If local DB access is no longer needed at all, or if
a lower-cost/lower-maintenance alternative (e.g. RDS Data API) becomes
a better fit for the actual access pattern.

---

## IaC: Terraform vs CDK vs CloudFormation vs console-only

Chose: Terraform, remote state in S3 with DynamoDB locking.

Why: More portable across employers/job postings than CDK, syntax
maps closely to existing sysadmin config file experience, and AI-assisted
generation/review of Terraform is mature and reliable. Remote state was
a deliberate fix partway through the project after discovering the
Terraform source itself had never actually been pushed to GitHub for a
period - remote state plus a properly tracked repo closes that
single-point-of-failure risk.

Revisit when: N/A.

---

## Secrets: AWS Secrets Manager (RDS-managed) vs environment variables vs .tfvars

Chose: RDS-managed master credentials via Secrets Manager
(manage_master_user_password = true in rds.tf) - Terraform, the
state file, and the person running apply never see the plaintext
password at any point.

Why: Removes an entire class of accidental-exposure risk (no
password ever appears in shell history, .tfvars, environment
variables, or CI logs). The tradeoff: the secret's ARN is not stable -
toggling credential management off/on to force a resync creates a
new secret with a new ARN, which has caused real friction (every
place referencing the old ARN - ecs.tf, iam_ecs.tf,
prediction_logger.py - needs updating when that happens). Worth it
regardless, since the alternative (a stable but self-managed password)
reintroduces the exposure risk this pattern exists to avoid.

Learned the hard way: any RDS credential reset while the standing
mlb-engine-app ECS service is already running requires an explicit
aws ecs update-service --force-new-deployment afterward - the running
container's cached DB connection doesn't self-heal from a credential
change.

Revisit when: N/A - the ARN-instability tradeoff is annoying but
not worth trading away the security benefit.
